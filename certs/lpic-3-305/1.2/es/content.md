# Examen LPIC-3 305-300: Tema 352 — Container Virtualization (Guía de Arquitectura de Plataforma y SRE en Producción)

---

## 1. Motivación en Producción y Declaración del Problema Arquitectónico

En entornos de producción de alta densidad, la virtualización de hardware tradicional (Hypervisors Tipo-1/Tipo-2) introduce una sobrecarga (overhead) de rendimiento sustancial. Cada Máquina Virtual (VM) exige un sistema operativo guest dedicado, una capa de programación (scheduling) de CPU virtual, preasignación completa de memoria y emulación de dispositivos PCI virtuales. Esta arquitectura incurre en un desperdicio significativo de recursos:
- **Overhead de Memory Footprint:** Los kernels de Guest OS y los demonios base del sistema consumen entre 500 MiB y 2 GiB por VM antes de ejecutar las cargas de trabajo de las aplicaciones.
- **Penalizaciones de Latencia y CPU:** La programación en dos niveles (Host Hypervisor Scheduler $\rightarrow$ Guest OS Scheduler) y la virtualización de instrucciones de CPU (nested page tables, traducción de MMU vía EPT/NPT) añaden penalizaciones de latencia de cola (tail-latency).
- **Tiempo de Cold Boot:** La inicialización completa de los sistemas init del guest OS (systemd, pruebas de autodiagnóstico del kernel, enumeración del árbol de dispositivos de hardware) requiere de 10 a 60 segundos, lo que imposibilita el autoscaling horizontal en menos de un segundo.

**Container Virtualization** resuelve estos cuellos de botella arquitectónicos proporcionando **virtualización a nivel de SO (OS-level virtualization)**. Múltiples instancias aisladas de espacio de usuario (containers) se ejecutan directamente en un único kernel host Linux compartido. El aislamiento se logra sin capas de hypervisor a través de primitivas nativas del kernel Linux: **Namespaces** (para el aislamiento de visibilidad de recursos), **Control Groups (cgroups)** (para contabilidad y límites de consumo de recursos) y **Security Profiles** (Seccomp, Capabilities, LSMs).

### Trade-offs Arquitectónicos: VM vs. Container

```
+------------------------------------+  +------------------------------------+
|         App A        |    App B    |  |   App A   |   App B   |    App C   |
+----------------------+-------------+  +-----------+-----------+------------+
|      Guest OS        |  Guest OS   |  |        Container Runtime           |
+----------------------+-------------+  +------------------------------------+
|             Hypervisor             |  |      Linux Host Kernel             |
+------------------------------------+  | (Namespaces, cgroups, Seccomp)     |
|      Host Operating System         |  +------------------------------------+
+------------------------------------+  |           Bare Metal Hardware      |
|        Bare Metal Hardware         |  +------------------------------------+
+------------------------------------+
       HYPERVISOR VIRTUALIZATION                   CONTAINER VIRTUALIZATION
```

1. **Aislamiento de Seguridad:** Los containers comparten el contexto de ejecución del kernel del host. Una vulnerabilidad de elevación de privilegios en una syscall del kernel (por ejemplo, dirty COW, buffer overflows en drivers del kernel) compromete todo el nodo host y todos los containers adyacentes coubicados. Los hypervisors imponen un límite rígido mediante modos de CPU asistidos por hardware (operación VMX root vs. non-root).
2. **Heterogeneidad del Kernel:** Los containers no pueden ejecutar sistemas operativos que no sean Linux ni versiones del kernel que difieran del kernel host (por ejemplo, ejecutar de forma nativa el kernel de Windows Server o FreeBSD en un host Linux).
3. **Control de Noisy Neighbor:** cgroups de containers débilmente configurados pueden desencadenar cascadas de CPU throttling, I/O starvation o contención de bloqueos en la page-cache del kernel a través de containers de diferentes inquilinos no relacionados.

---

## 2. Arquitectura Técnica y Mecánica Interna

La virtualización de containers se basa en cuatro subsistemas distintos de seguridad y aislamiento del kernel Linux.

### 2.1 Namespaces del Kernel Linux

Los Namespaces envuelven recursos globales del sistema en abstracciones aisladas. Un proceso que opera dentro de un namespace percibe únicamente los recursos asignados a su división (slice) específica.

| Namespace | Kernel Flag | Recurso Aislado | Ruta en `/proc/[pid]/ns/` |
| :--- | :--- | :--- | :--- |
| **Mount (mnt)** | `CLONE_NEWNS` | Puntos de montaje del sistema de archivos y estructura del árbol de archivos | `/proc/[pid]/ns/mnt` |
| **Process ID (pid)** | `CLONE_NEWPID` | IDs de procesos, árbol de procesos padre-hijo | `/proc/[pid]/ns/pid` |
| **Network (net)** | `CLONE_NEWNET` | Dispositivos de red, tablas de enrutamiento IP, reglas de firewall, puertos socket | `/proc/[pid]/ns/net` |
| **Inter-Process (ipc)** | `CLONE_NEWIPC` | Objetos IPC System V, memoria compartida System V, colas de mensajes POSIX | `/proc/[pid]/ns/ipc` |
| **UNIX Timesharing (uts)** | `CLONE_NEWUTS` | Hostname y nombre de dominio NIS | `/proc/[pid]/ns/uts` |
| **User (user)** | `CLONE_NEWUSER` | Mapeos de User IDs (UID) y Group IDs (GID) | `/proc/[pid]/ns/user` |
| **Control Group (cgroup)** | `CLONE_NEWCGROUP` | Vista de la estructura de directorios del cgroup raíz | `/proc/[pid]/ns/cgroup` |
| **Time (time)** | `CLONE_NEWTIME` | Relojes del sistema monotónicos y de arranque (boot) | `/proc/[pid]/ns/time` |

#### Mecánica de Namespaces a través de `clone()` y `unshare()`
Los namespaces se instancian a través de la llamada al sistema `clone(..., CLONE_NEWPID | CLONE_NEWNET | ...)` durante la creación del proceso hijo, o se adjuntan retroactivamente utilizando `unshare(flags)` o `setns(fd, nstype)`.

---

### 2.2 Control Groups (cgroups v1 vs. cgroups v2)

Los Control groups aplican medición de recursos, priorización y límites estrictos (CPU, Memoria, Block I/O, Red, PIDs) para grupos de procesos.

#### Cambio Arquitectónico: cgroups v1 vs. cgroups v2
- **cgroups v1 (Multi-Jerarquía):** Cada controlador (memory, cpu, blkio, pids) opera independientemente en una jerarquía separada montada bajo `/sys/fs/cgroup/<controller>/`. Un proceso puede pertenecer a `memory/groupA` pero a `cpu/groupB`. Este modelo multijerárquico provocaba condiciones de carrera durante la migración de procesos, una atribución de I/O defectuosa en el writeback de la page-cache y bloqueos mutuos (deadlocks) irresolubles.
- **cgroups v2 (Jerarquía Unificada):** Montado como un único árbol unificado en `/sys/fs/cgroup/`. Todos los procesos existen en una sola jerarquía. Los controladores se habilitan explícitamente aguas abajo mediante `cgroup.subtree_control`. Los procesos solo pueden residir en nodos hoja ("no internal process constraint").

```
cgroups v1 (Split Trees)              cgroups v2 (Unified Tree)
/sys/fs/cgroup/                      /sys/fs/cgroup/
├── cpu/                              ├── cgroup.controllers
│   └── docker/<id>/                  ├── cgroup.subtree_control (+cpu +memory)
└── memory/                           └── system.slice/
    └── docker/<id>/                      └── docker-<id>.scope/
                                              ├── cgroup.procs
                                              ├── memory.max
                                              └── cpu.max
```

#### Pressure Stall Information (PSI) en cgroups v2
cgroups v2 introduce contadores PSI (`memory.pressure`, `cpu.pressure`, `io.pressure`) que proporcionan telemetría de alerta temprana sobre el desabastecimiento de recursos (resource starvation) antes de que ocurran eventos de Out-Of-Memory (OOM) killer:
- **some:** Porcentaje de tiempo durante el cual al menos una tarea estuvo bloqueada (stalled) por un recurso.
- **full:** Porcentaje de tiempo durante el cual *todas* las tareas no inactivas estuvieron bloqueadas simultáneamente.

---

### 2.3 Capas de Endurecimiento de Seguridad (Security Hardening)

1. **Linux Capabilities (`capabilities(7)`):** Divide el todopoderoso conjunto de privilegios de `root` UID 0 en 41 unidades de grano fino distintas (por ejemplo, `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, `CAP_CHOWN`). Los containers descartan capacidades críticas (como `CAP_SYS_ADMIN`, `CAP_SYS_RAWIO`, `CAP_NET_RAW`) por defecto para evitar la toma de control del host.
2. **Secure Computing Mode (Seccomp BPF):** Filtra las llamadas al sistema emitidas por los procesos del container al kernel host. Un programa BPF evalúa los números de las llamadas al sistema y sus argumentos. Si un container invoca una llamada al sistema en la lista negra (por ejemplo, `reboot()`, `kexec_load()`, `init_module()`), el kernel emite `EPERM` o termina inmediatamente el proceso con `SIGSYS`.
3. **Linux Security Modules (LSM - AppArmor / SELinux):** Motor de Control de Acceso Obligatorio (MAC).
   - **AppArmor:** Perfil de aislamiento basado en rutas que restringe a qué rutas de archivos, capacidades y protocolos de red puede acceder un container.
   - **SELinux:** Etiquetado de Type Enforcement y Multi-Category Security (MCS) (`system_u:object_r:container_file_t:s0:c123,c456`). Evita que la etiqueta del proceso del container `container_t` acceda a rutas del host no etiquetadas.

---

### 2.4 Estándares de la Open Container Initiative (OCI) y Jerarquía del Runtime

La pila de runtime del container opera en una arquitectura desacoplada por capas gobernada por las especificaciones OCI:

```
+-------------------------------------------------------------------------+
| High-Level Orchestrator (Kubernetes kubelet / Docker CLI / Podman)     |
+-------------------------------------------------------------------------+
                                    | (gRPC / CRI)
                                    v
+-------------------------------------------------------------------------+
| High-Level Container Runtime (containerd / CRI-O)                       |
| - Image Pulling / Unpacking (OCI Image Spec)                            |
| - Storage Layer Assembly (Overlay2)                                     |
| - Execution State Management                                            |
+-------------------------------------------------------------------------+
                                    | (CLI invocation / OCI Spec JSON)
                                    v
+-------------------------------------------------------------------------+
| Low-Level OCI Runtime (runc / crun / kata-runtime)                      |
| - Executes 'clone()' with namespace flags                               |
| - Configures /sys/fs/cgroup nodes                                       |
| - Applies Seccomp BPF filters & Capabilities                            |
| - Execs container entrypoint process                                    |
+-------------------------------------------------------------------------+
                                    | (Linux Syscalls)
                                    v
+-------------------------------------------------------------------------+
| Linux Host Kernel                                                       |
+-------------------------------------------------------------------------+
```

1. **OCI Image Specification:** Define el formato de los manifiestos de imágenes de container, los tarballs de capas del sistema de archivos (`tar+gzip`) y los archivos de configuración JSON (comando, entorno, entrypoint, IDs de diferencias de capa).
2. **OCI Runtime Specification (`spec`):** Define el formato de estado, el entorno de ejecución y los ganchos del ciclo de vida (lifecycle hooks: `prestart`, `createRuntime`, `createContainer`, `startContainer`, `poststop`) controlados por un archivo de configuración estándar llamado `config.json`.

---

## 3. Comparativas Técnicas y Análisis de Trade-Offs

### 3.1 System Containers vs. Application Containers vs. MicroVMs

| Dimensión | System Containers (LXC/LXD) | Application Containers (Docker/Podman) | MicroVMs (Kata / Firecracker) |
| :--- | :--- | :--- | :--- |
| **Enfoque Principal** | Reemplazo completo del espacio de usuario del SO (ejecuta `systemd`, `sshd`, múltiples servicios) | Ejecución de un único proceso entrypoint de microservicio | Aislamiento de hardware por hypervisor con velocidad similar a un container |
| **Proceso Init** | `/sbin/init` o `systemd` (PID 1 dentro del container) | Binario de aplicación (por ejemplo, `node`, `nginx`, `go-app`) | Init del kernel guest minimalista personalizado (`kata-agent`) |
| **Límite de Aislamiento** | Namespaces, cgroups, Seccomp, AppArmor | Namespaces, cgroups, Seccomp, AppArmor | Virtualización de Hardware KVM (VMX root/non-root) |
| **Contexto del Kernel** | Kernel Host Compartido | Kernel Host Compartido | Kernel Linux Guest Dedicado |
| **Latencia de Arranque** | 1.0s – 3.0s | 10ms – 200ms | 100ms – 500ms |
| **Memory Footprint**| ~50 MiB base por container | ~5 MiB – 30 MiB base | ~30 MiB – 100 MiB base |
| **Caso de Uso** | Migración de aplicaciones monolíticas heredadas, entornos de desarrollo | Microservicios cloud-native, builds de CI/CD | Ejecución de código no confiable en entornos multi-tenant (Serverless/FaaS) |

---

### 3.2 Matriz de Trade-Offs de Drivers de Almacenamiento

| Storage Driver | Mecánica Arquitectónica | Rendimiento de Lectura/Escritura | Utilización del Espacio en Disco | Idoneidad y Requisitos en Producción |
| :--- | :--- | :--- | :--- | :--- |
| **Overlay2** | Union filesystem que superpone `lowerdir` (capas de solo lectura) y `upperdir` (capa de lectura y escritura del container) mediante overlayfs del kernel. | Excelente lectura; rendimiento de escritura casi nativo. Modificar archivos existentes de gran tamaño incurre en latencia Copy-on-Write (CoW). | Alta eficiencia gracias a la compartición de page-cache entre capas inferiores idénticas. | **Estándar por Defecto en Producción.** Requiere soporte de `d_type=true` en el sistema de archivos subyacente (xfs, ext4). |
| **Btrfs** | Subvolúmenes y copy-on-write a nivel de bloque/extent soportados nativamente por el sistema de archivos Btrfs. | Moderado; alta amplificación de escritura bajo cargas de trabajo pesadas de I/O aleatorio. | Alta eficiencia; soporta snapshotting nativo. | Requiere que todo `/var/lib/docker` o la ruta de almacenamiento esté formateada como Btrfs. |
| **ZFS** | Clones de datasets e integración con ARC (Adaptive Replacement Cache). | Alto rendimiento de lectura; alto uso de RAM para la caché ARC. | Alto; compresión de bloques integrada (zstd/lz4) y deduplicación. | Despliegues especializados de almacenamiento empresarial. Requiere módulos del kernel ZFS (`zfs.ko`). |
| **DeviceMapper** | Snapshotting de aprovisionamiento ligero LVM a nivel de bloque plano (raw block). | Deficiente rendimiento de I/O aleatorio en modo `loop-lvm`; aceptable en `direct-lvm`. | Moderado; asigna fragmentos de bloques por adelantado. | **Obsoleto (Deprecated).** No utilizar en despliegues modernos de producción. |

---

### 3.3 Matriz de Trade-Offs de Runtimes OCI

| OCI Runtime | Lenguaje de Implementación | Paradigma de Aislamiento | Sobrecarga (Overhead) de Rendimiento | Postura de Seguridad |
| :--- | :--- | :--- | :--- | :--- |
| **runc** | Go | Namespaces y cgroups estándar de Linux | Casi cero (velocidad de syscall nativa) | Aislamiento estándar de container. Vulnerable a exploits del kernel host. |
| **crun** | C | Namespaces y cgroups estándar de Linux | Memory footprint mínimo (~unos pocos KB); arranque más rápido que runc | Igual que runc, optimizado para dispositivos edge con recursos limitados. |
| **gVisor (`runsc`)** | Go | Kernel en espacio de usuario (`Sentry`) que intercepta syscalls | Sobrecarga de CPU moderada a alta para aplicaciones con un uso intensivo de syscalls | Alta. Intercepta e implementa más de 300 syscalls de Linux en espacio de usuario. |
| **Kata Containers** | Go / Rust | Envoltorio microVM de hypervisor KVM por hardware | Baja sobrecarga de CPU; asignación fija de RAM por microVM | Máxima. Fuerte límite de virtualización por hardware alrededor de cada pod. |

---

## 4. Manifiestos de Configuración para Entornos de Producción

### 4.1 Archivo de Configuración de LXC Unprivileged Container

La siguiente configuración define un LXC system container sin privilegios (unprivileged) ejecutándose con namespaces de usuario mapeados, límites de recursos cgroup v2, red veth personalizada y capacidades restringidas.

```ini
# Location: /var/lib/lxc/sre-production-app/config
# LXC 3.0+ Unprivileged System Container Configuration

# Container Architecture and Type
lxc.arch = amd64
lxc.uts.name = sre-production-app

# User Namespace UID/GID Mapping (Unprivileged Execution)
# Maps container root (0-65536) to unprivileged host range (100000-165536)
lxc.idmap = u 0 100000 65536
lxc.idmap = g 0 100000 65536

# Root Filesystem Path and Storage Settings
lxc.rootfs.path = dir:/var/lib/lxc/sre-production-app/rootfs
lxc.rootfs.managed = 1

# Systemd Compatibility and Mount Points
lxc.mount.auto = proc:mixed sys:ro cgroup:mixed
lxc.autodev = 1

# Network Configuration (veth bridge attachment)
lxc.net.0.type = veth
lxc.net.0.flags = up
lxc.net.0.link = lxcbr0
lxc.net.0.name = eth0
lxc.net.0.hwaddr = 00:16:3e:7a:9b:12
lxc.net.0.ipv4.address = 10.0.3.150/24
lxc.net.0.ipv4.gateway = 10.0.3.1

# Resource Controls (cgroup v2 limits)
lxc.cgroup2.memory.max = 2147483648
lxc.cgroup2.memory.high = 1879048192
lxc.cgroup2.cpu.max = 200000 100000
lxc.cgroup2.pids.max = 1024

# Security Hardening & Dropped Capabilities
lxc.cap.drop = sys_admin sys_rawio sys_module audit_control
lxc.seccomp.profile = /var/lib/lxc/sre-production-app/seccomp.profile
```

---

### 4.2 Especificación del Runtime OCI de Bajo Nivel (`config.json`)

Especificación OCI sintácticamente válida utilizada directamente por `runc` o `crun` para lanzar un application container de bajo nivel.

```json
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": false,
    "user": {
      "uid": 1000,
      "gid": 1000
    },
    "args": [
      "/usr/bin/node",
      "/app/server.js"
    ],
    "env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "NODE_ENV=production"
    ],
    "cwd": "/app",
    "capabilities": {
      "bounding": [
        "CAP_NET_BIND_SERVICE",
        "CAP_SETUID",
        "CAP_SETGID"
      ],
      "effective": [
        "CAP_NET_BIND_SERVICE"
      ],
      "inheritable": [],
      "permitted": [
        "CAP_NET_BIND_SERVICE",
        "CAP_SETUID",
        "CAP_SETGID"
      ]
    },
    "rlimits": [
      {
        "type": "RLIMIT_NOFILE",
        "hard": 65536,
        "soft": 32768
      }
    ],
    "noNewPrivileges": true
  },
  "root": {
    "path": "rootfs",
    "readonly": true
  },
  "hostname": "production-api-node",
  "mounts": [
    {
      "destination": "/proc",
      "type": "proc",
      "source": "proc"
    },
    {
      "destination": "/dev",
      "type": "tmpfs",
      "source": "tmpfs",
      "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]
    },
    {
      "destination": "/tmp",
      "type": "tmpfs",
      "source": "tmpfs",
      "options": ["nosuid", "nodev", "noexec", "size=67108864"]
    }
  ],
  "linux": {
    "namespaces": [
      { "type": "pid" },
      { "type": "network" },
      { "type": "ipc" },
      { "type": "uts" },
      { "type": "mount" },
      { "type": "cgroup" }
    ],
    "resources": {
      "memory": {
        "limit": 1073741824,
        "reservation": 536870912
      },
      "cpu": {
        "quota": 100000,
        "period": 100000
      },
      "pids": {
        "limit": 500
      }
    }
  }
}
```

---

### 4.3 Configuración del Demonio de Docker en Producción (`/etc/docker/daemon.json`)

Configuración de producción para `dockerd` que incorpora la alineación nativa con cgroup v2 de systemd, aislamiento del demonio, rotación de logs, verificación de overlay2 y aplicación predeterminada de seccomp.

```json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5",
    "compress": "true"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "default-shm-size": "128M",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 32768
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 4096,
      "Soft": 2048
    }
  },
  "icc": false,
  "cgroup-parent": "/system.slice/docker.service",
  "seccomp-profile": "/etc/docker/defaults/production-seccomp.json"
}
```

---

### 4.4 Unidad de Servicio Podman Quadlet sin Demonio (Daemonless) (`sre-api.container`)

Ejecución moderna de containers integrada con systemd y sin demonio (daemonless) utilizando Podman Quadlet (generador de systemd).

```ini
# Location: /etc/containers/systemd/sre-api.container
[Unit]
Description=SRE Production API Workload (Daemonless Podman)
After=network-online.target
Wants=network-online.target

[Container]
Image=quay.io/sre_ops/api-service:v2.4.1
ContainerName=sre-api-production
Exec=/usr/local/bin/api-server --port=8080
PublishPort=8080:8080
User=1000
Group=1000
ReadOnlyRootfs=true
VolatileTmp=true
DropCapability=ALL
AddCapability=CAP_NET_BIND_SERVICE
MemoryLimit=1G
CPUQuota=150%
PidsLimit=250
Environment=NODE_ENV=production
Network=bridge

[Install]
WantedBy=multi-user.target default.target
```

---

## 5. Ejecución en Línea de Comandos y Salidas Reales de Terminal

### 5.1 Inspección y Ciclo de Vida de LXC / LXD

#### Creación y Arranque de un Container LXC
```bash
$ sudo lxc-create -n production-lxc -t download -- -d ubuntu -r noble -a amd64
```
```output
Setting up the installation environment
Downloading the image index...
Downloading the instance image...
Unpacking the image metadata...
The image cache is now ready
Unpacking the image template...
Done creating container production-lxc
```

#### Arranque y Verificación del Estado de LXC
```bash
$ sudo lxc-start -n production-lxc
$ sudo lxc-info -n production-lxc
```
```output
Name:           production-lxc
State:          RUNNING
PID:            14230
IP:             10.0.3.184
CPU use:        0.42 seconds
BlkIO use:      12.44 MiB
Memory use:     24.18 MiB
KMem use:       3.12 MiB
Link:           veth1001_veth
 Bytes received: 1.84 KiB
 Bytes sent:     842 B
```

#### Conexión (Attach) al Contexto de Ejecución del Container
```bash
$ sudo lxc-attach -n production-lxc -- id
```
```output
uid=0(root) gid=0(root) groups=0(root)
```

---

### 5.2 Flujo de Trabajo de Ejecución del Runtime OCI de Bajo Nivel (`runc`)

Ejecución de un container OCI directamente utilizando binarios de bajo nivel sin un demonio.

```bash
$ mkdir -p /tmp/oci-demo/rootfs
$ cd /tmp/oci-demo
# Export filesystem layer from standard image
$ podman export $(podman create alpine:latest) | tar -C rootfs -xf -
# Generate standard OCI spec bundle (config.json)
$ runc spec
$ ls -la
```
```output
total 12
drwxr-xr-x 3 root root 4096 Aug  6 16:00 .
drwxrwxrwt 1 root root 4096 Aug  6 16:00 ..
-rw-r--r-- 1 root root 2841 Aug  6 16:00 config.json
drwxr-xr-x 2 root root 4096 Aug  6 16:00 rootfs
```

#### Ejecución de la Instancia del Container de Bajo Nivel
```bash
$ sudo runc run --bundle /tmp/oci-demo container-test-01 &
$ sudo runc list
```
```output
ID                  PID         STATUS      BUNDLE          CREATED                          OWNER
container-test-01   18924       running     /tmp/oci-demo   2026-08-06T16:02:11.412891102Z   root
```

---

### 5.3 Inspección de Docker Engine en Producción y Verificación de Recursos

#### Verificación del Cgroup Driver y la Pila de Almacenamiento del Engine
```bash
$ docker info --format 'Cgroup Driver: {{.CgroupDriver}} | Cgroup Version: {{.CgroupVersion}} | Driver: {{.Driver}}'
```
```output
Cgroup Driver: systemd | Cgroup Version: 2 | Driver: overlay2
```

#### Lanzamiento de Container Endurecido (Hardened) con Límites de Recursos
```bash
$ docker run -d --name secure-nginx \
  --memory="512m" \
  --cpus="1.5" \
  --pids-limit=100 \
  --read-only \
  --cap-drop=ALL \
  --cap-add=CAP_NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  nginx:alpine
```
```output
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

#### Inspección de los Controles del Perfil de Seguridad del Container
```bash
$ docker inspect secure-nginx --format '{{json .HostConfig.CapDrop}} | ReadOnly: {{.HostConfig.ReadOnlyRootfs}}'
```
```output
["ALL"] | ReadOnly: true
```

---

### 5.4 Operaciones Sin Demonio (Daemonless): Podman y User Namespaces

#### Verificación de Rangos de SubUID/SubGID en el Host para Ejecución Rootless
```bash
$ cat /etc/subuid /etc/subgid
```
```output
/etc/subuid:
sreuser:100000:65536
/etc/subgid:
sreuser:100000:65536
```

#### Ejecución de Container Rootless y Verificación del Mapeo de Usuarios
```bash
$ podman run --rm alpine id
```
```output
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
```

#### Inspección del Mapeo Real de PID a través de la Tabla de Procesos del Host
```bash
$ podman run -d --name rootless-sleep alpine sleep 9999
$ podman top rootless-sleep user huser pid hpid
```
```output
USER        HUSER       PID         HPID        
root        100000      1           21045       
```
*(Observe que el `UID 0` de root dentro del container corresponde a `UID 100000` en el host físico).*

---

### 5.5 Inspección de Bajo Nivel de Containers en el Kernel Linux

#### Listado de Todos los Namespaces del Host a través de `lsns`
```bash
$ sudo lsns -t net
```
```output
        NS TYPE NET-PATH                   NPROCS   PID USER     COMMAND
4026531840 net  /proc/1/ns/net                140     1 root     /sbin/init
4026532418 net  /proc/21045/ns/net              2 21045 100000   sleep 9999
```

#### Lectura del Nodo Cgroup v2 del Proceso del Container
```bash
$ cat /proc/21045/cgroup
```
```output
0::/user.slice/user-1000.slice/user@1000.service/app.slice/podman-21045.scope
```

#### Inspección de las Capabilities Efectivas del Kernel de un Proceso Host
```bash
$ grep Cap /proc/21045/status
```
```output
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000400
CapAmb:	0000000000000000
```
*(Decodificar `CapEff: 0000000000000000` demuestra que todas las capacidades de root fueron despojadas por completo por el motor de containers).*

---

## 6. Guía Integral de Verificación y Resolución de Fallas (Troubleshooting)

### 6.1 Escenario de Diagnóstico 1: Depuración de Eventos de Containers OOMKilled

#### Mecánica de la Causa Raíz
El proceso del container solicitó una asignación de memoria que superaba el límite `memory.max` de cgroup v2. El controlador de memoria de cgroup del kernel activó una recuperación sincrónica (synchronous reclaim). Al no poder liberar suficiente memoria anónima/page cache, el kernel invocó a `oom-killer` apuntando al proceso con la puntuación `oom_score` más alta dentro del cgroup.

#### Flujo de Trabajo de Diagnóstico y Comandos

##### Paso 1: Consultar el Buffer del Kernel del Sistema para Invocaciones de OOM
```bash
$ dmesg -T | grep -i -E "oom|out of memory|killed process"
```
```output
[Thu Aug  6 16:15:22 2026] Memory cgroup out of memory: Killed process 24512 (node) total-vm:1845120kB, anon-rss:1048100kB, file-rss:4120kB, shmem-rss:0kB, uid:1000 pgtables:3712kB oom_score_adj:0
[Thu Aug  6 16:15:22 2026] oom_reaper: reaped process 24512 (node), now anon-rss:0kB, file-rss:0kB, shmem-rss:0kB
```

##### Paso 2: Inspeccionar Eventos de Contadores de Memoria en cgroup v2
```bash
$ CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' secure-nginx)
$ CGROUP_PATH=$(cat /proc/$CONTAINER_PID/cgroup | cut -d: -f3)
$ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.events
```
```output
low 0
high 142
max 1
oom 1
oom_kill 1
oom_group_kill 0
```

##### Paso 3: Analizar PSI (Pressure Stall Information) para Cuellos de Botella de Memoria
```bash
$ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.pressure
```
```output
some avg10=24.12 avg60=15.41 avg300=4.10 total=48120412
full avg10=18.04 avg60=10.12 avg300=2.01 total=32104100
```
*Resolución:* Aumentar `memory.max` o resolver las fugas de memoria (memory leaks) de la aplicación identificadas por valores elevados de presión PSI `full`.

---

### 6.2 Escenario de Diagnóstico 2: Resolución de Problemas de Conectividad de Red y Pérdida de Paquetes

#### Mecánica de la Causa Raíz
El container no puede alcanzar endpoints externos o containers adyacentes debido a parámetros mal configurados en el par de ethernet virtual (`veth`), interfaces de bridge del host rotas o cadenas de reenvío de paquetes (`FORWARD`) de `iptables`/`nftables` del host bloqueadas.

```
+-----------------------------------------------------------------------+
| HOST NETWORKING NAMESPACE                                             |
|                                                                       |
|   +---------------+      veth Pair Generation                         |
|   |    docker0    |<========================+                         |
|   | (Bridge: IP)  |                         |                         |
|   +---------------+                         |                         |
+---------------------------------------------|-------------------------+
                                              | (Traverses Net NS Boundary)
+---------------------------------------------|-------------------------+
| CONTAINER NETWORKING NAMESPACE              v                         |
|                                     +---------------+                 |
|                                     |  eth0 (veth)  |                 |
|                                     +---------------+                 |
+-----------------------------------------------------------------------+
```

#### Flujo de Trabajo de Diagnóstico y Comandos

##### Paso 1: Identificar el NetNS Objetivo y PID del Container
```bash
$ TARGET_PID=$(docker inspect --format '{{.State.Pid}}' secure-nginx)
$ echo $TARGET_PID
```
```output
24110
```

##### Paso 2: Ejecutar Comandos dentro del Network Namespace del Container a través de `nsenter`
```bash
$ sudo nsenter -t $TARGET_PID -n ip addr show dev eth0
```
```output
12: eth0@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
```

##### Paso 3: Verificar la Interfaz Par en el Motor Host
```bash
$ ip link show dev veth* | grep -B 1 "link-netnsid 0"
```
```output
13: veth4a81bc9@if12: <BROADCAST,MULTICAST,UP,LOWER_UP> master docker0 state UP mode DEFAULT group default 
    link/ether f2:88:14:1c:c9:82 brd ff:ff:ff:ff:ff:ff
```

##### Paso 4: Comprobar Enrutamiento IP (IP Forwarding) y Reglas de Filtro en el Host
```bash
$ sysctl net.ipv4.ip_forward
```
```output
net.ipv4.ip_forward = 1
```
```bash
$ sudo iptables -L FORWARD -n -v --line-numbers
```
```output
Chain FORWARD (policy DROP 0 packets, 0 bytes)
num   pkts bytes target     prot opt in     out     source               destination         
1     1240 102K  DOCKER-USER  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
2     1240 102K  DOCKER-ISOLATION-STAGE-1  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
3      812  64K  ACCEPT     all  --  *      docker0  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
4      428  38K  DOCKER     all  --  docker0 !docker0 0.0.0.0/0            0.0.0.0/0           
```
*Resolución:* Si faltan las reglas 3 o 4 o la política es DROP sin reglas ACCEPT, ejecute `sudo iptables -A FORWARD -i docker0 -j ACCEPT`.

---

### 6.3 Escenario de Diagnóstico 3: Fallas de Permisos por Mapeo de UID/GID en User Namespaces

#### Mecánica de la Causa Raíz
Un proceso de container rootless que se ejecuta bajo namespaces de usuario no logra abrir un volumen montado desde una ruta del host, mostrando `EACCES (Permission denied)`. El UID del propietario del directorio host no se encuentra dentro del bloque de mapeo SubUID asignado y definido en `/etc/subuid`.

#### Flujo de Trabajo de Diagnóstico y Comandos

##### Paso 1: Rastrear los UIDs del Proceso a través de los Namespaces
```bash
$ podman unshare cat /proc/self/uid_map
```
```output
         0       1000          1
         1     100000      65536
```

##### Paso 2: Inspeccionar los Permisos del Directorio del Volumen en el Host
```bash
$ ls -ld /srv/app/data
```
```output
drwxr-x--- 2 root root 4096 Aug  6 15:30 /srv/app/data
```

##### Paso 3: Corregir la Propiedad en el Host utilizando `podman unshare chown`
```bash
# Safely maps container UID 0 (which translates to host 100000) as owner of the host directory
$ podman unshare chown -R 0:0 /srv/app/data
$ ls -ld /srv/app/data
```
```output
drwxr-x--- 2 100000 100000 4096 Aug  6 15:30 /srv/app/data
```

---

### 6.4 Escenario de Diagnóstico 4: Depuración del Bloqueo de Syscalls por Seccomp a través de Logs de Auditoría

#### Mecánica de la Causa Raíz
Un application container falla inesperadamente con el código de salida 159 (`SIGSYS`) o registra `Operation not permitted`. El filtro Seccomp predeterminado interceptó una llamada al sistema del kernel no autorizada emitida por el binario.

#### Flujo de Trabajo de Diagnóstico y Comandos

##### Paso 1: Monitorear el Log de Auditoría del Sistema para Rechazos de Seccomp
```bash
$ sudo tail -f /var/log/audit/audit.log | grep -E "type=SECCOMP"
```
```output
type=SECCOMP msg=audit(1722961022.412:941): auid=4294967295 uid=1000 gid=1000 ses=4294967295 pid=28114 comm="custom-agent" exe="/usr/local/bin/custom-agent" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f9a8412b321 code=0x0
```

##### Paso 2: Convertir el ID Hexadecimal de Syscall a Nombre
```bash
$ ausyscall x86_64 165
```
```output
mount
```
*(La traza demuestra que el proceso `custom-agent` intentó la llamada al sistema `mount()` [syscall #165], la cual está bloqueada por los perfiles seccomp estándar de los containers).*

##### Paso 3: Verificar mediante Conexión de `strace` al Proceso en Vivo
```bash
$ sudo strace -p 28114 -e trace=mount
```
```output
strace: Process 28114 attached
mount("none", "/tmp", "tmpfs", 0, NULL) = -1 EPERM (Operation not permitted)
--- SIGSYS {si_signo=SIGSYS, si_code=SYS_SECCOMP, si_call_addr=0x7f9a8412b321, si_syscall=__NR_mount, si_arch=AUDIT_ARCH_X86_64} ---
+++ killed by SIGSYS (core dumped) +++
```
*Resolución:* Modificar el perfil JSON de Seccomp del container para incluir explícitamente en la lista blanca la syscall requerida (`mount`) o refactorizar la lógica de la aplicación para eliminar la ejecución de syscalls privilegiadas.

---

## 7. Referencias

- **Objetivos del examen LPIC-3 305-300:** [https://www.lpi.org/our-certifications/lpic-3-305-overview/](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
- **Documentación de Namespaces del Kernel Linux (`namespaces(7)`):** [https://man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- **Documentación de Control Groups v2 de Linux (`cgroups(7)`):** [https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- **Especificación del Runtime de la Open Container Initiative (OCI):** [https://github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
- **Especificación de Imagen de la Open Container Initiative (OCI):** [https://github.com/opencontainers/image-spec](https://github.com/opencontainers/image-spec)
- **Documentación del Proyecto LXC / LXD:** [https://linuxcontainers.org/lxc/documentation/](https://linuxcontainers.org/lxc/documentation/)
- **Referencia del Demonio y Arquitectura de Docker Engine:** [https://docs.docker.com/engine/reference/commandline/dockerd/](https://docs.docker.com/engine/reference/commandline/dockerd/)
- **Guía de Integración de Podman Quadlet:** [https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)