# 352.1 Container Virtualization Concepts

> **Exam:** LPIC-3 305-300 (version 3.0) · **Topic weight:** 11.67
> **Profile:** SRE / Platform Architect — mecánica interna de nivel productivo, compensaciones y diagnóstico.

---

## 1. El problema en producción: qué virtualiza realmente la "container virtualization"

Un container **no es una VM liviana**. Ese modelo mental se rompe en el momento en que tenés que depurar una falla de kernel compartido a las 03:00. La formulación precisa es:

> Un container es un **proceso (o árbol de procesos) cuya visión del sistema está restringida** por características del kernel — namespaces, control groups, capabilities y control de acceso obligatorio — mientras sigue ejecutándose **directamente sobre el kernel del host**, sin emulación de hardware y sin un kernel invitado.

Todo en este tema es una consecuencia de esa única oración. No hay hypervisor, no hay guest OS, no hay vCPU. `docker run`, `podman run`, `lxc-start` y un Pod de Kubernetes terminan todos llamando a las mismas syscalls del kernel: `clone()`/`unshare()` (namespaces), `write()` en un filesystem de cgroup, `capset()` (capabilities), `prctl(PR_SET_SECCOMP, …)` (seccomp) y un hook LSM (SELinux/AppArmor).

### 1.1 El espectro de aislamiento

```
weaker isolation ──────────────────────────────────────────► stronger isolation
 process        chroot          namespaces+cgroups        gVisor / Kata        full VM (KVM)
 (shared FS,    (FS root only)  ("the container")         (userspace kernel /  (separate guest
  shared PID)                                              microVM)             kernel + vCPUs)
```

La decisión arquitectónica que toma el equipo de plataforma es *dónde en este espectro se ubica una carga de trabajo*, y esa decisión está impulsada por el **threat model y el objetivo de densidad**, no por la moda.

### 1.2 Containers vs máquinas virtuales — la compensación que define el tema

| Dimensión | Containers (kernel compartido) | Máquinas virtuales (KVM/Xen) |
|---|---|---|
| Frontera de aislamiento | Superficie de syscalls del kernel (~350 syscalls) | Virtualización de hardware (VT-x/AMD-V), superficie de hypercalls estrecha |
| Kernel | **Compartido** con el host — una CVE del kernel = radio de impacto compartido | Kernel invitado independiente por VM |
| Tiempo de arranque / inicio | 10–100 ms (fork + configuración de namespace) | segundos a decenas de segundos (firmware → bootloader → kernel → init) |
| Sobrecarga de memoria | ~MB (sin kernel invitado, page cache compartida) | ~cientos de MB por invitado (kernel invitado + duplicación de page cache) |
| Densidad (por host) | Cientos a miles | Decenas |
| Live migration | Inmadura (CRIU, checkpoint/restore) | Madura (KVM live migration) |
| Versión de kernel por carga de trabajo | **Imposible** — todos comparten el kernel del host | Cada VM elige su propio kernel |
| Superficie de ataque para escape | Toda la superficie de syscalls + `/proc` + `/sys` + drivers del kernel | Modelo de dispositivos del VMM + ABI de hypercalls |
| Adecuado cuando… | Densidad, escalado rápido, necesidades de kernel homogéneo, apps 12-factor | Aislamiento multi-tenant fuerte, kernels distintos, código no confiable |

**La consecuencia en producción:** un escape de container es una **escalada de privilegios en el kernel**. Dirty COW (CVE-2016-5195), la CVE-2019-5736 de `runc` (sobrescribir el binario `runc` del host vía `/proc/self/exe`) y la CVE-2017-5123 de `waitid()` permiten todas que un container alcance el host precisamente porque hay un único kernel. *Por eso* existe el resto de este tema — los namespaces por sí solos no son una frontera de seguridad; la postura de seguridad es la **combinación en capas** de namespaces + capabilities descartadas + seccomp + un LSM. Los runtimes con sandbox (gVisor, Kata Containers) existen específicamente para reintroducir una frontera más fuerte para tenants no confiables mientras conservan la UX del container.

---

## 2. Las primitivas del kernel

### 2.1 Namespaces — *lo que un proceso puede ver*

Un namespace envuelve un recurso global del sistema en una abstracción de modo que los procesos dentro del namespace tienen su propia instancia aislada. Hay **ocho** tipos de namespace en los kernels modernos (5.6+):

| Namespace | flag de `clone`/`unshare` | Aísla | Introducido | Relevancia para containers |
|---|---|---|---|---|
| **Mount** (`mnt`) | `CLONE_NEWNS` | Puntos de montaje del filesystem | 2.4.19 | rootfs privado, `/proc`, `/sys`, tmpfs |
| **UTS** | `CLONE_NEWUTS` | Hostname, dominio NIS | 2.6.19 | `hostname` por container |
| **IPC** | `CLONE_NEWIPC` | System V IPC, colas de mensajes POSIX | 2.6.19 | Memoria compartida / semáforos aislados |
| **PID** | `CLONE_NEWPID` | IDs de proceso | 2.6.24 | El container tiene su propio PID 1; no puede ver los PIDs del host |
| **Network** (`net`) | `CLONE_NEWNET` | Interfaces, routing, `iptables`, puertos, `/proc/net` | 2.6.29 | Stack de red por container (veth, loopback) |
| **User** | `CLONE_NEWUSER` | Mapeos de UID/GID, capabilities | 3.8 | **Rootless containers** — UID 0 adentro mapea a un UID no privilegiado afuera |
| **Cgroup** | `CLONE_NEWCGROUP` | Vista del directorio raíz de cgroup | 4.6 | Oculta las rutas de cgroup del host al container |
| **Time** | `CLONE_NEWTIME` | Offsets de `CLOCK_MONOTONIC`, `CLOCK_BOOTTIME` | 5.6 | Offset de reloj por container (restore de CRIU, testing) |

El **user namespace** es la pieza clave de la seguridad moderna de containers. Es el único namespace que un usuario no privilegiado puede crear, y es lo que hace que el UID 0 dentro de un container mapee, digamos, al UID 100000 en el host — de modo que un "root" de container que escapa no posee nada.

#### Inspeccionar namespaces en un sistema en vivo

Cada proceso expone su membresía de namespace como symlinks mágicos bajo `/proc/<pid>/ns/`. Dos procesos en el mismo namespace comparten el mismo número de inode.

```console
$ ls -l /proc/self/ns/
total 0
lrwxrwxrwx 1 user user 0 Jun 14 10:22 cgroup -> 'cgroup:[4026531835]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 ipc -> 'ipc:[4026531839]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 mnt -> 'mnt:[4026531841]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 net -> 'net:[4026531840]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 pid -> 'pid:[4026531836]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 time -> 'time:[4026531834]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 user -> 'user:[4026531837]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 uts -> 'uts:[4026531838]'
```

La herramienta `lsns` enumera los namespaces y los procesos vinculados a ellos:

```console
$ sudo lsns --type net
        NS TYPE NPROCS   PID USER   NETNSID NSFS                           COMMAND
4026531840 net     241     1 root unassigned                                /sbin/init
4026532297 net       3  8912 root         0 /run/docker/netns/1a2b3c4d5e6f /pause
```

Creá un container "a mano" con `unshare` para probar que no hay magia — esto es lo que hace un runtime por debajo:

```console
$ sudo unshare --pid --fork --mount-proc --uts --net --ipc --mount /bin/bash
root@host:/# hostname isolated-demo
root@host:/# hostname
isolated-demo
root@host:/# ps aux
USER   PID %CPU %MEM    VSZ   RSS TTY  STAT START  TIME COMMAND
root     1  0.0  0.0  10236  3200 pts/0 S   10:31 0:00 /bin/bash
root     9  0.0  0.0  11container 3400 pts/0 R+  10:31 0:00 ps aux
root@host:/# ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
```

Nota: el PID 1 es `bash`, el hostname es privado, y el network namespace tiene *solamente* un loopback caído — sin interfaces, sin rutas. Ese net namespace vacío es exactamente lo que un plugin CNI puebla después.

Entrá en los namespaces de un container existente con `nsenter` — el truco canónico "necesito un shell de depuración dentro de un container en ejecución que no tiene shell":

```console
$ CPID=$(docker inspect --format '{{.State.Pid}}' web)
$ sudo nsenter --target "$CPID" --mount --uts --ipc --net --pid --cgroup /bin/sh
/ # ip -br addr
lo               UNKNOWN        127.0.0.1/8
eth0@if12        UP             172.17.0.2/16
```

### 2.2 Control groups (cgroups) — *lo que un proceso puede consumir*

Los namespaces controlan la *visibilidad*; **los cgroups controlan la contabilidad de recursos y los límites** — CPU, memoria, block I/O, PIDs, dispositivos. Sin cgroups un container podría hacer un fork-bomb o dejar sin memoria (OOM) a todo el host; los namespaces felizmente aislarían su *vista* mientras consume hasta la última página de RAM.

#### cgroup v1 vs cgroup v2 — una decisión de migración real

| Aspecto | cgroup v1 | cgroup v2 (unified) |
|---|---|---|
| Jerarquía | **Múltiples** jerarquías, una por controller (`/sys/fs/cgroup/memory`, `/cpu`, …) | **Una única jerarquía unificada** (`/sys/fs/cgroup`) |
| Un proceso puede estar en… | Diferentes cgroups para diferentes controllers (incoherente) | Exactamente un cgroup, todos los controllers | 
| Habilitación de controllers | Implícita | Explícita vía `cgroup.subtree_control` |
| Contabilidad de memoria+swap | `memory.memsw.limit_in_bytes` | `memory.max` + `memory.swap.max` (separados) |
| Pressure stall info (PSI) | ✗ | ✓ (`cpu.pressure`, `memory.pressure`, `io.pressure`) |
| rootless / delegación | Pobre | Diseñado para delegación segura a usuarios no privilegiados |
| Activado por defecto en | Distros legadas | Fedora 31+, RHEL 9, Debian 11+, Ubuntu 22.04+ |

Las plataformas modernas deberían estar en **cgroup v2**. Kubernetes lo requiere para varias características (por ejemplo `MemoryQoS`, comportamiento OOM correcto), y el Podman rootless lo necesita para la delegación de CPU/memoria.

Verificá qué versión ejecuta un host:

```console
$ stat -fc %T /sys/fs/cgroup/
cgroup2fs           # cgroup v2 unified hierarchy
# ("tmpfs" would indicate cgroup v1 or hybrid)

$ mount | grep cgroup
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot)
```

Inspeccioná el cgroup en el que vive un container de Docker (cgroup v2 + driver systemd):

```console
$ systemd-cgls --no-pager | grep -A3 docker
│ └─docker-1a2b3c4d5e6f7890abcdef.scope …
│   ├─8912 /pause
│   └─8977 nginx: master process nginx -g daemon off;

$ cat /sys/fs/cgroup/system.slice/docker-1a2b3c4d5e6f7890abcdef.scope/memory.max
536870912          # 512 MiB hard limit (from `docker run -m 512m`)

$ cat /sys/fs/cgroup/system.slice/docker-1a2b3c4d5e6f7890abcdef.scope/memory.current
41947136           # ~40 MiB currently in use

$ cat /sys/fs/cgroup/system.slice/docker-1a2b3c4d5e6f7890abcdef.scope/cpu.max
50000 100000       # 50 ms quota per 100 ms period → 0.5 CPU
```

**Diagnóstico que importa en producción — el OOM kill.** Cuando un container supera `memory.max`, el OOM-killer del kernel termina un proceso *dentro de ese cgroup*, no a nivel de todo el host. La carga de trabajo ve el código de salida 137 (128 + SIGKILL 9):

```console
$ dmesg | tail -3
[91234.5] Memory cgroup out of memory: Killed process 8977 (nginx) total-vm:...
[91234.5] oom_reaper: reaped process 8977 (nginx), now anon-rss:0kB...

$ docker inspect web --format '{{.State.OOMKilled}} {{.State.ExitCode}}'
true 137
```

### 2.3 Capabilities — *dividir el root monolítico*

UNIX tradicional tiene un modelo de privilegios binario: el UID 0 (root) omite todas las comprobaciones de permisos del kernel, todos los demás no. Las **capabilities** fragmentan ese monolito en ~40 privilegios distintos (`CAP_*`) que pueden otorgarse o descartarse independientemente. Esto es central para el hardening de containers: un container debería ejecutarse con el **conjunto mínimo de capabilities**, no con root completo.

Las capabilities más relevantes para containers:

| Capability | Otorga | Riesgo en el container si se mantiene |
|---|---|---|
| `CAP_SYS_ADMIN` | El "nuevo root" — mount, `setns`, `pivot_root`, muchas otras | Vector de escape casi total; **descartala** |
| `CAP_NET_ADMIN` | Configurar interfaces, routing, `iptables` | Manipular la red del host si el `net` ns está compartido |
| `CAP_NET_RAW` | Sockets raw/packet (`ping`, ARP spoofing) | L2 spoofing en redes compartidas |
| `CAP_SYS_PTRACE` | `ptrace()` a otros procesos | Inspeccionar/inyectar en procesos del host si el `pid` ns está compartido |
| `CAP_SYS_MODULE` | `init_module()` — cargar módulos del kernel | Compromiso inmediato del host; **nunca la otorgues** |
| `CAP_DAC_OVERRIDE` | Omitir comprobaciones de permisos de lectura/escritura/ejecución | Leer cualquier archivo del host si hay fugas de montajes |
| `CAP_SETUID`/`CAP_SETGID` | Cambios arbitrarios de UID/GID | Pivoteos de privilegios |
| `CAP_MKNOD` | Crear nodos de dispositivo | Crear acceso de dispositivo a los discos del host |
| `CAP_CHOWN` | Cambiar la propiedad de archivos | — |
| `CAP_KILL` | Enviar señales a cualquier proceso | — |

Los **descartes por defecto** de Docker eliminan la mayoría de las capabilities peligrosas y retienen un conjunto pequeño y acotado (`CAP_CHOWN`, `CAP_NET_BIND_SERVICE`, `CAP_SETUID`, `CAP_SETGID`, `CAP_NET_RAW`, etc.). Notablemente descarta `CAP_SYS_ADMIN`, `CAP_SYS_MODULE` y `CAP_SYS_PTRACE`.

Inspeccioná y manipulá las capabilities de un container:

```console
$ docker run --rm alpine grep Cap /proc/self/status
CapInh: 0000000000000000
CapPrm: 00000000a80425fb
CapEff: 00000000a80425fb
CapBnd: 00000000a80425fb     # bounding set — the ceiling of what can ever be held
CapAmb: 0000000000000000

$ capsh --decode=00000000a80425fb
0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,
cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,
cap_mknod,cap_audit_write,cap_setfcap
```

Patrón de hardening — **descartá todo, volvé a agregar solo lo necesario**:

```console
$ docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE alpine \
    grep CapEff /proc/self/status
CapEff: 0000000000000400     # only CAP_NET_BIND_SERVICE (bit 10)
```

Kubernetes expresa la misma intención de forma declarativa en el `securityContext` de un Pod (ver el manifiesto de §7).

### 2.4 seccomp — *restringir la superficie de syscalls*

Los namespaces, cgroups y capabilities restringen *qué recursos* toca un proceso. **seccomp** (secure computing mode) restringe *qué llamadas al sistema puede emitir en absoluto*, filtrando por número de syscall y valores de argumentos vía un programa BPF (`SECCOMP_MODE_FILTER`). Esta es la mayor reducción individual de la superficie de ataque del kernel disponible para un container.

El kernel de Linux expone ~350 syscalls. El **perfil seccomp por defecto** de Docker bloquea ~44 peligrosas (`reboot`, `swapon`, `mount`, `init_module`, `kexec_load`, `bpf`, `ptrace` bajo algunas configuraciones, operaciones de keyring, etc.) y permite el resto — un modelo deny-by-exception ajustado para compatibilidad.

Verificá que seccomp esté activo en un container (`Seccomp: 2` = modo filter; `0` = deshabilitado):

```console
$ docker run --rm alpine grep Seccomp /proc/self/status
Seccomp:	2
Seccomp_filters:	1

$ docker run --rm --security-opt seccomp=unconfined alpine grep Seccomp /proc/self/status
Seccomp:	0            # DANGER: no syscall filtering
```

Un perfil personalizado mínimo (JSON seccomp de OCI) con una postura default-deny:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "brk", "capget", "capset", "chdir",
        "clock_gettime", "close", "connect", "epoll_create1", "epoll_ctl",
        "epoll_pwait", "execve", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "listen", "mmap", "mprotect",
        "munmap", "nanosleep", "openat", "read", "recvfrom", "rt_sigaction",
        "rt_sigprocmask", "sendto", "set_robust_list", "set_tid_address",
        "setgid", "setgroups", "setuid", "socket", "stat", "write"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

```console
$ docker run --rm --security-opt seccomp=./minimal.json myapp:latest
# any syscall not in the allowlist returns EPERM (errno 1) to the workload
```

**Diagnóstico:** una carga de trabajo que falla misteriosamente con `Operation not permitted` en una operación de apariencia inocua frecuentemente es una denegación de seccomp. Rastrealo:

```console
$ strace -f -e trace=all myapp 2>&1 | grep EPERM
mount("/dev/sdb", "/mnt", ...) = -1 EPERM (Operation not permitted)
```

### 2.5 Mandatory Access Control — SELinux y AppArmor (LSM)

Las capabilities y seccomp son controles del kernel adyacentes a DAC. **SELinux** y **AppArmor** son **Linux Security Modules (LSM)** que implementan control de acceso *mandatorio* (obligatorio): política que el proceso no puede anular ni siquiera como root. Son la capa de contención más externa y la diferencia entre "el container escapó de los namespaces" y "el escape chocó contra una pared de `avc: denied`."

| | SELinux | AppArmor |
|---|---|---|
| Modelo | **Label/type enforcement** — cada proceso, archivo, puerto lleva un security context | Perfiles **basados en rutas** (path-based) |
| Configuración | Lenguaje de política complejo; transiciones de tipo | Perfiles por-binario más simples |
| Distro por defecto | RHEL/Fedora/CentOS Stream | Ubuntu/Debian/SUSE |
| Integración con containers | Tipo `container_t`, categorías MCS (`s0:c123,c456`) por container | Perfil `docker-default` |
| Granularidad | Muy fina (tipos, categorías, booleanos) | Orientada a rutas/capabilities |
| Firma de falla | `avc: denied` en el log de auditoría | `apparmor="DENIED"` en dmesg |

**SELinux para containers** usa Multi-Category Security (MCS): cada container obtiene un par de categorías único, de modo que el container A (`s0:c1,c2`) no puede tocar los archivos del container B (`s0:c3,c4`) aunque haya una fuga de montaje — las etiquetas no coinciden.

```console
$ ps -eZ | grep -i container
system_u:system_r:container_t:s0:c123,c456  8977 ?  00:00:01 nginx

$ ls -Z /var/lib/docker/volumes/data/_data
system_u:object_r:container_file_t:s0:c123,c456  index.html

# Diagnose a denial (the classic "permission denied despite correct UNIX perms"):
$ sudo ausearch -m avc -ts recent
type=AVC msg=audit(...): avc:  denied  { read } for  pid=8977 comm="nginx"
  name="secret.txt" dev="dm-0" ino=12345
  scontext=system_u:system_r:container_t:s0:c123,c456
  tcontext=unconfined_u:object_r:admin_home_t:s0 tclass=file permissive=0
```

Ese desajuste `tcontext=admin_home_t` es por qué un archivo del host montado con bind devuelve "Permission denied" dentro de un container aun con `chmod 777` — el arreglo es `:Z`/`:z` (relabel) en el montaje o un `chcon` explícito, **no** `chmod`.

Equivalente en **AppArmor**:

```console
$ docker run --rm --security-opt apparmor=docker-default alpine touch /etc/x
touch: /etc/x: Permission denied
$ dmesg | grep apparmor | tail -1
audit: apparmor="DENIED" operation="mknod" profile="docker-default"
  name="/etc/x" pid=9123 comm="touch" requested_mask="c" denied_mask="c"
```

**Resumen de defensa en capas** — un container endurecido es la *intersección* de los cinco controles:

```
        ┌─────────────── Host kernel (shared) ───────────────┐
Namespaces │  restrict what the process SEES                  │
Cgroups    │  restrict what the process CONSUMES              │
Capabilities│ restrict which ROOT PRIVILEGES it holds         │
Seccomp    │  restrict which SYSCALLS it may issue            │
SELinux/AA │  restrict via MANDATORY policy (cannot override) │
        └─────────────────────────────────────────────────────┘
```

---

## 3. System containers vs application containers

El examen distingue explícitamente las dos *filosofías* de container. Usan primitivas del kernel idénticas pero presentan abstracciones opuestas.

| | **Application container** | **System container** |
|---|---|---|
| Ejecuta | Un único servicio/proceso (PID 1 = la app) | Un userspace completo / sistema de init (systemd/OpenRC) — se comporta como una VM liviana |
| Init | Usualmente ninguno (o un reaper mínimo `tini`/`dumb-init`) | init real que gestiona muchos servicios |
| Ciclo de vida | Efímero, inmutable, se reconstruye en vez de parcharse | Larga vida, tipo "mascota", actualizado in situ |
| Imagen | En capas (imagen OCI), mínima (`scratch`, `alpine`, `distroless`) | rootfs de distro completa |
| Herramientas canónicas | **Docker, Podman**, containerd | **LXC, LXD/Incus**, systemd-nspawn |
| Filesystem | Imagen en capas OverlayFS | A menudo un árbol de directorios completo o dispositivo de bloque |
| Modelo mental | "Un proceso con una vista privada" | "Una máquina sin su propio kernel" |
| Encaja en | Microservicios 12-factor, CI, functions | Apps legadas multi-servicio, sandboxes de desarrollo, runners de CI que necesitan systemd |

**Cómo cada uno aprovecha las primitivas del kernel:**

- **LXC** (system) crea todos los namespaces, aplica un cgroup, descarta capabilities y arranca el init de la distro adentro. `lxc.conf` expone directamente `lxc.cgroup2.*`, `lxc.cap.drop`, `lxc.seccomp.profile`, `lxc.apparmor.profile` — configurás las primitivas uno a uno.
- **Docker/Podman** (application) hacen lo mismo pero lo envuelven detrás de una imagen + filesystem en capas + un entrypoint de un solo proceso, y agregan encima los formatos de imagen/distribución OCI.

```console
# System container (LXC) — a whole Debian userspace
$ sudo lxc-create -n sysbox -t download -- -d debian -r bookworm -a amd64
$ sudo lxc-start -n sysbox
$ sudo lxc-attach -n sysbox -- ps aux | head
USER  PID  … COMMAND
root    1  … /sbin/init                    # <-- real systemd as PID 1
root  142  … /lib/systemd/systemd-journald
root  178  … /usr/sbin/sshd -D
message+ 201 … /usr/bin/dbus-daemon --system
$ sudo lxc-ls -f
NAME    STATE   AUTOSTART GROUPS IPV4       IPV6
sysbox  RUNNING 0         -      10.0.3.42  -

# Application container (Docker) — one process
$ docker run -d --name web nginx:1.27-alpine
$ docker top web
UID   PID    CMD
root  9101   nginx: master process nginx -g daemon off;   # <-- app is PID 1
101   9140   nginx: worker process
```

El modelo rootless y daemonless de Podman es la respuesta moderna de application-container al daemon root de Docker: se ejecuta enteramente en un **user namespace**, no necesita un daemon privilegiado, e integra con systemd vía Quadlet — importante para el objetivo arquitectónico de "reducir la superficie de ataque de root".

---

## 4. El stack de runtime OCI — de `docker run` a un proceso en ejecución

Este es el corazón de los objetivos de 352.1 sobre "el principio de runc / CRI-O / containerd / OCI". Las plataformas de container modernas están **en capas**, y cada capa es un componente definido por especificación e intercambiable.

### 4.1 La Open Container Initiative (OCI)

La OCI es un proyecto de la Linux Foundation que estandariza los formatos de container para que el ecosistema no quede atado a Docker. Tres especificaciones:

| Especificación OCI | Define | Concretamente |
|---|---|---|
| **runtime-spec** | El **bundle** en disco (un `config.json` + un `rootfs/`) y el ciclo de vida que un runtime debe implementar (`create`, `start`, `kill`, `delete`) | Lo que consume `runc` |
| **image-spec** | El formato de **imagen**: tarballs en capas, el manifest, el config, digests direccionables por contenido (`sha256:…`) | Lo que produce `docker build`, lo que almacenan los registries |
| **distribution-spec** | La **API HTTP del registry** para push/pull (`/v2/…`) | Cómo `docker pull` habla con Docker Hub / Quay / ECR |

Un **runtime bundle** OCI es asombrosamente simple — esto es lo que toda la herramienta finalmente fabrica:

```console
$ mkdir -p bundle/rootfs && cd bundle
$ docker export $(docker create alpine) | tar -C rootfs -xf -
$ runc spec                    # generates a default config.json
$ ls
config.json  rootfs
```

Extracto del `config.json` generado (el objeto runtime-spec) mostrando las primitivas de §2 codificadas declarativamente:

```json
{
  "ociVersion": "1.2.0",
  "process": {
    "terminal": true,
    "user": { "uid": 0, "gid": 0 },
    "args": ["sh"],
    "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "cwd": "/",
    "capabilities": {
      "bounding":  ["CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_AUDIT_WRITE"],
      "effective": ["CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_AUDIT_WRITE"],
      "permitted": ["CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_AUDIT_WRITE"]
    },
    "noNewPrivileges": true
  },
  "root": { "path": "rootfs", "readonly": true },
  "hostname": "runc-demo",
  "linux": {
    "namespaces": [
      { "type": "pid" }, { "type": "network" }, { "type": "ipc" },
      { "type": "uts" }, { "type": "mount" }, { "type": "cgroup" }
    ],
    "maskedPaths":   ["/proc/kcore", "/proc/keys", "/sys/firmware"],
    "readonlyPaths": ["/proc/sys", "/proc/sysrq-trigger", "/proc/irq"],
    "resources": {
      "memory": { "limit": 536870912 },
      "cpu": { "quota": 50000, "period": 100000 }
    },
    "seccomp": { "defaultAction": "SCMP_ACT_ERRNO", "syscalls": [ /* … */ ] }
  }
}
```

### 4.2 runc — el runtime OCI de referencia

`runc` es el pequeño binario de Go (extraído de Docker en 2015) que convierte un bundle en un proceso en ejecución realizando las llamadas reales al kernel. Es **la implementación de referencia de la runtime-spec**. Hace *una* sola cosa: crear, iniciar y recolectar (reap) un container a partir de un bundle, y luego salir — no es un daemon.

```console
$ sudo runc run mycontainer
/ # cat /etc/hostname
runc-demo
/ # exit

# Lifecycle can be driven explicitly:
$ sudo runc create mycontainer
$ sudo runc list
ID            PID    STATUS   BUNDLE          CREATED             OWNER
mycontainer   9312   created  /root/bundle    2026-06-14T…Z       root
$ sudo runc start mycontainer
$ sudo runc ps mycontainer
UID   PID    CMD
0     9312   sh
$ sudo runc kill mycontainer KILL
$ sudo runc delete mycontainer
```

**crun** es una implementación en C más rápida de la misma runtime-spec (por defecto en Podman/CRI-O en muchas distros) — menor memoria y latencia de inicio, y mejor soporte de cgroup v2. Como ambos honran la runtime-spec de OCI, son **intercambiables drop-in** — este es todo el punto de OCI.

### 4.3 containerd y CRI-O — los runtimes de alto nivel

`runc` es demasiado de bajo nivel para construir una plataforma encima: no tiene gestión de imágenes, ni pull, ni snapshots, ni API, ni networking. Ese es el trabajo de un **runtime de alto nivel**:

| | **containerd** | **CRI-O** |
|---|---|---|
| Origen | CNCF (graduado), extraído de Docker | Red Hat, construido específicamente para Kubernetes |
| Alcance | Propósito general: imágenes, snapshots, content store, API gRPC; usado por Docker, Kubernetes, runtimes de nube | **Solo Kubernetes** — implementa exactamente la CRI, nada más |
| Gestión de imágenes | Sí (pull/push, content store, snapshotters) | Sí (vía containers/image + containers/storage) |
| Runtime de bajo nivel | `runc` (por defecto), un shim por container | `runc`/`crun` vía OCI |
| CRI | Vía plugin CRI incorporado | Es *solo* una implementación de CRI |
| CLI extra | `ctr` (debug), `nerdctl` (estilo Docker) | `crictl` (debug de CRI) |

Ambos se ubican **entre** el orquestador y `runc`, y ambos usan un proceso **shim** (`containerd-shim-runc-v2`) por container de modo que la vida del container quede desacoplada de la del daemon — podés reiniciar containerd sin matar los containers en ejecución (esta es precisamente la arquitectura que arregló el viejo problema de Docker de "reiniciás el daemon, matás todos los containers").

```console
# containerd's low-level debug CLI (namespace-scoped)
$ sudo ctr --namespace k8s.io containers list
CONTAINER       IMAGE                              RUNTIME
1a2b3c...       docker.io/library/nginx:1.27       io.containerd.runc.v2

$ sudo ctr --namespace k8s.io tasks list
TASK        PID     STATUS
1a2b3c...   9887    RUNNING

# The shim, per container, reparented to PID 1 — survives containerd restarts:
$ ps -ef | grep containerd-shim
root  9860  1  containerd-shim-runc-v2 -namespace k8s.io -id 1a2b3c... -address /run/...
```

### 4.4 La Container Runtime Interface (CRI)

Kubernetes **no** habla con `runc` ni siquiera con Docker directamente. El **kubelet** habla la **CRI** — una API gRPC (`RuntimeService` + `ImageService`) — con el runtime que la implemente (containerd vía su plugin CRI, o CRI-O). Por eso **"Dockershim" fue removido en Kubernetes 1.24**: Docker nunca habló CRI nativamente, así que el kubelet necesitaba un shim; una vez que containerd (que el propio Docker usa) habló CRI directamente, el shim quedó redundante.

```
┌────────────┐   CRI (gRPC)   ┌───────────────┐   OCI runtime-spec   ┌──────┐   syscalls   ┌────────┐
│  kubelet   │───────────────►│ containerd /  │─────────────────────►│ runc │─────────────►│ kernel │
│ (K8s node) │                │    CRI-O      │  (shim per container) │/crun │  namespaces  │ (host) │
└────────────┘                └───────────────┘                       └──────┘  cgroups…    └────────┘
                                     │
                                     ▼ pulls via OCI distribution-spec, unpacks OCI image-spec
                               ┌───────────┐
                               │ registry  │
                               └───────────┘
```

`crictl` es la herramienta de depuración a nivel CRI — neutral respecto al proveedor, tanto para containerd como para CRI-O:

```console
$ sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps
CONTAINER     IMAGE          CREATED         STATE    NAME    POD ID        POD
7f3a9b2c1d…   nginx:1.27     3 minutes ago   Running  web     a1b2c3d4e5…   web-pod
$ sudo crictl pods
POD ID        CREATED         STATE    NAME       NAMESPACE   ATTEMPT   RUNTIME
a1b2c3d4e5…   3 minutes ago   Ready    web-pod    default     0         (default)
$ sudo crictl inspect 7f3a9b2c1d | jq '.info.runtimeSpec.linux.namespaces'
```

---

## 5. Container networking — awareness de CNI

El examen requiere *awareness* (conocimiento) de la **Container Network Interface (CNI)** — una especificación de la CNCF que desacopla el runtime de la implementación de red. Un plugin CNI es un ejecutable que el runtime invoca con los comandos `ADD`/`DEL`/`CHECK` y una config JSON, y cuyo trabajo es cablear el network namespace (vacío) del container dentro de una red.

El modelo `bridge` por defecto de docker ilustra las primitivas; CNI lo generaliza:

```
Container netns                Host
┌──────────────┐              ┌────────────────────────────────┐
│ eth0         │──veth pair──►│ vethXXXX ── docker0 (bridge) ──►│── NAT (iptables MASQUERADE) ──► uplink
│ 172.17.0.2/16│              │              172.17.0.1/16      │
└──────────────┘              └────────────────────────────────┘
```

```console
$ docker run -d --name web nginx:alpine
$ docker exec web ip -br addr
lo        UNKNOWN 127.0.0.1/8
eth0@if14 UP      172.17.0.2/16
$ ip -br link | grep veth
veth9a1b2c@if13 UP  ...      # host end of the veth pair
$ bridge link | grep veth
14: veth9a1b2c … master docker0 state forwarding

# The host-side NAT rule that gives the container egress:
$ sudo iptables -t nat -L POSTROUTING -n | grep 172.17
MASQUERADE  all  --  172.17.0.0/16   0.0.0.0/0
```

**Modelos de red CNI — tabla de awareness:**

| Modelo | Mecanismo | Plugins de ejemplo |
|---|---|---|
| **Bridge / veth** | Bridge L2 + pares veth (un solo host) | `bridge`, por defecto de Docker |
| **Overlay (encapsulación)** | Túneles VXLAN/Geneve entre hosts | Flannel (VXLAN), Cilium (VXLAN/Geneve) |
| **Routed / BGP (L3)** | Subredes de Pod anunciadas vía BGP, sin encapsulación | Calico |
| **eBPF datapath** | eBPF del kernel reemplaza iptables para routing/policy/LB | Cilium |
| **macvlan/ipvlan** | El container obtiene una dirección directamente en la L2 física | `macvlan`, `ipvlan` |

Una config CNI mínima (el JSON que el runtime entrega al plugin):

```json
{
  "cniVersion": "1.0.0",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "10.22.0.0/16",
    "routes": [{ "dst": "0.0.0.0/0" }]
  }
}
```

Kubernetes también coloca **NetworkPolicy** encima de CNI (aplicada por plugins conscientes de políticas como Calico/Cilium) para segmentar el tráfico este-oeste — el equivalente de un firewall para containers.

---

## 6. Orquestación y service mesh — awareness

La **orquestación** resuelve el problema que los containers crudos no resuelven: scheduling a través de una flota, self-healing, actualizaciones progresivas (rolling updates), service discovery, estado deseado declarativo y escalado horizontal. Kubernetes es el estándar de facto; la unidad desplegable más pequeña es un **Pod** (uno o más containers que comparten los namespaces net + IPC + UTS vía un container `pause` que mantiene los namespaces abiertos).

| Preocupación | Container crudo | Orquestador (Kubernetes) |
|---|---|---|
| Scheduling | Manual, un host | Bin-packing entre nodos (scheduler) |
| Healing | Ninguno | Reinicio, re-scheduling ante pérdida de nodo |
| Escalado | Manual | HPA / replicas, declarativo |
| Networking | Por-host | Red plana a nivel de cluster + Services + DNS |
| Config/secrets | Env/archivos | Objetos ConfigMap / Secret |
| Estado deseado | Imperativo | Loop de reconciliación declarativo |

Un **service mesh** (Istio, Linkerd, Cilium Service Mesh) aborda las preocupaciones *servicio-a-servicio* que la orquestación deja abiertas: cifrado mutual-TLS, gestión de tráfico L7 (canary, retries, timeouts, circuit breaking) y observabilidad profunda. Los meshes clásicos inyectan un **sidecar proxy** (Envoy) en cada Pod; el proxy intercepta todo el tráfico de forma transparente. Los diseños más nuevos (Istio ambient, Cilium) mueven el datapath a una capa eBPF/proxy por-nodo para evitar el impuesto del sidecar por-Pod.

```
Pod A                          Pod B
┌───────────────┐              ┌───────────────┐
│ app ─► sidecar│◄─── mTLS ───►│sidecar ◄─ app │      control plane (istiod) programs the sidecars:
│      (Envoy)  │   (L7: retry,│ (Envoy)       │      routing, mTLS certs, policy, telemetry
└───────────────┘    canary,   └───────────────┘
                     circuit-break)
```

Compensación para internalizar: un mesh compra mTLS/observabilidad/traffic-shaping uniformes **pero** agrega latencia (hops extra), memoria (un proxy por Pod) y complejidad operativa. Adoptalo cuando tengas suficientes servicios como para que resolver estas preocupaciones por-app deje de escalar — no antes.

---

## 7. Verificación y diagnóstico de fallas

Un manifiesto trabajado y representativo de producción que ejercita las primitivas, seguido de un playbook de diagnóstico.

### 7.1 Un Pod de Kubernetes endurecido (todas las primitivas, declarativamente)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-web
  namespace: prod
  labels:
    app: web
    tier: frontend
  annotations:
    container.apparmor.security.beta.kubernetes.io/web: runtime/default
spec:
  # ---- Pod-level security posture ----
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault          # apply the runtime's default seccomp filter
    supplementalGroups: [10001]
  automountServiceAccountToken: false
  containers:
    - name: web
      image: registry.example.com/web@sha256:9f2c...e1  # pin by digest (OCI image-spec)
      imagePullPolicy: IfNotPresent
      ports:
        - containerPort: 8080
          name: http
      # ---- Container-level hardening ----
      securityContext:
        allowPrivilegeEscalation: false     # sets no_new_privs — blocks setuid escalation
        readOnlyRootFilesystem: true        # immutable rootfs; writes go to tmpfs volumes
        privileged: false
        capabilities:
          drop: ["ALL"]                     # drop the monolithic root
          add:  ["NET_BIND_SERVICE"]        # add back only what's needed (bind :80/:443)
      # ---- cgroup limits (map to memory.max / cpu.max) ----
      resources:
        requests:
          cpu: "250m"
          memory: "128Mi"
        limits:
          cpu: "500m"                       # → cpu.max 50000 100000
          memory: "512Mi"                   # → memory.max 536870912; exceed => OOMKilled (137)
      livenessProbe:
        httpGet: { path: /healthz, port: http }
        initialDelaySeconds: 5
        periodSeconds: 10
      readinessProbe:
        httpGet: { path: /ready, port: http }
        periodSeconds: 5
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
  volumes:
    - name: tmp
      emptyDir: { medium: Memory, sizeLimit: 64Mi }
    - name: cache
      emptyDir: { sizeLimit: 128Mi }
```

`NetworkPolicy` complementaria (default-deny, luego allow) — el firewall aplicado por CNI:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow
  namespace: prod
spec:
  podSelector:
    matchLabels: { app: web }
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - podSelector: { matchLabels: { tier: gateway } }
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
      ports:
        - protocol: UDP
          port: 53                  # DNS only
```

### 7.2 Escalera de verificación

```console
# 1. Confirm the security posture actually took effect (don't trust the manifest — verify the process)
$ kubectl exec -n prod hardened-web -- grep -E 'Cap(Eff|Bnd)|Seccomp|NoNewPrivs' /proc/1/status
CapEff:   0000000000000400          # only CAP_NET_BIND_SERVICE
CapBnd:   0000000000000400
NoNewPrivs: 1
Seccomp:  2                         # filter mode active

# 2. Confirm the effective UID and read-only rootfs
$ kubectl exec -n prod hardened-web -- id
uid=10001 gid=10001 groups=10001
$ kubectl exec -n prod hardened-web -- touch /etc/x
touch: /etc/x: Read-only file system

# 3. Confirm the cgroup limits landed
$ kubectl exec -n prod hardened-web -- cat /sys/fs/cgroup/memory.max
536870912

# 4. Confirm namespaces are distinct from the host
$ NODE_PID=$(crictl inspect $(crictl ps -q --name web) | jq .info.pid)
$ sudo readlink /proc/$NODE_PID/ns/net /proc/1/ns/net
net:[4026532501]        # container
net:[4026531840]        # host  → different inode ⇒ isolated
```

### 7.3 Tabla de diagnóstico de modos de falla

| Síntoma | Causa probable | Confirmar con | Arreglo |
|---|---|---|---|
| Código de salida **137**, `OOMKilled: true` | Se superó el límite de memoria | `dmesg \| grep -i oom`, `kubectl describe pod` | Subir `memory.limit`, arreglar leak |
| Salida **125** (Docker) | Error de CLI/runtime de Docker antes de iniciar el container | stderr de `docker run`, `journalctl -u docker` | Flag / imagen / runtime incorrectos |
| Salida **126** | Comando encontrado pero no ejecutable | entrypoint de `docker inspect`; verificar `+x` | Arreglar permisos / shebang |
| Salida **127** | Comando no encontrado en la imagen | `docker run --rm img ls -l /path` | Ruta incorrecta / binario faltante |
| `Operation not permitted` en una syscall | Denegación de seccomp o capability descartada | `strace -f … \| grep EPERM`; `grep Seccomp /proc/…/status` | Agregar cap / ajustar perfil seccomp |
| `Permission denied` en un bind-mount a pesar de `chmod 777` | Desajuste de etiqueta SELinux | `ausearch -m avc -ts recent` | Montar con `:Z`/`:z`, o `chcon -Rt container_file_t` |
| `apparmor="DENIED"` en dmesg | Perfil AppArmor bloqueó la operación | `dmesg \| grep apparmor` | Ajustar/aflojar el perfil |
| El container arranca y luego se reinicia en loop | Liveness probe fallando / PID 1 que no recolecta (reap) | `kubectl logs --previous`, `crictl logs` | Arreglar el probe, agregar `tini` como init |
| `pull access denied` / `manifest unknown` | Auth del registry / tag incorrecto (distribution-spec) | `crictl pull`, `docker pull` verbose | Arreglar credenciales / tag / digest |
| Pod atascado en `ContainerCreating` | El plugin CNI falló al cablear el netns | `kubectl describe pod`, `/var/log/cni`, `journalctl -u kubelet` | Arreglar config / binario del plugin CNI |
| `fork/exec … no space left` bajo memoria | Límite de cgroup de PID alcanzado (`pids.max`) | `cat /sys/fs/cgroup/…/pids.current` | Subir `pids.limit` |
| El container no puede `mount`/`modprobe` | Falta `CAP_SYS_ADMIN`/`CAP_SYS_MODULE` (por diseño) | `capsh --print` adentro | Rearquitecturar; **no** otorgar a ciegas |

### 7.4 One-liners de forensia en vivo de namespace/cgroup

```console
# Which container owns host PID 9887?
$ sudo grep -l 9887 /sys/fs/cgroup/**/cgroup.procs 2>/dev/null | head
# → path reveals the docker-<id>.scope or kubepods slice

# What is a container's per-controller cgroup path?
$ cat /proc/9887/cgroup
0::/system.slice/docker-1a2b3c….scope

# Compare two containers' user-namespace UID mappings (rootless verification)
$ cat /proc/9887/uid_map
         0     100000      65536      # container UID 0 → host UID 100000

# Enumerate every namespace and the process count in each
$ sudo lsns
```

---

## 8. Referencias

- LPI — Exam 305 Objectives (305-300, v3.0): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Página de manual de Linux `namespaces(7)`: <https://man7.org/linux/man-pages/man7/namespaces.7.html>
- Página de manual de Linux `cgroups(7)`: <https://man7.org/linux/man-pages/man7/cgroups.7.html>
- Página de manual de Linux `capabilities(7)`: <https://man7.org/linux/man-pages/man7/capabilities.7.html>
- Página de manual de Linux `seccomp(2)`: <https://man7.org/linux/man-pages/man2/seccomp.2.html>
- Página de manual de Linux `user_namespaces(7)`: <https://man7.org/linux/man-pages/man7/user_namespaces.7.html>
- Documentación del kernel de cgroup v2: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- SELinux Project — política de containers: <https://github.com/containers/container-selinux>
- Documentación de AppArmor: <https://gitlab.com/apparmor/apparmor/-/wikis/Documentation>
- Open Container Initiative (OCI): <https://opencontainers.org/>
- OCI Runtime Specification: <https://github.com/opencontainers/runtime-spec>
- OCI Image Specification: <https://github.com/opencontainers/image-spec>
- OCI Distribution Specification: <https://github.com/opencontainers/distribution-spec>
- runc: <https://github.com/opencontainers/runc>
- crun: <https://github.com/containers/crun>
- containerd: <https://containerd.io/> · docs: <https://github.com/containerd/containerd/tree/main/docs>
- CRI-O: <https://cri-o.io/>
- Kubernetes Container Runtime Interface (CRI): <https://kubernetes.io/docs/concepts/architecture/cri/>
- Kubernetes — remoción de Dockershim: <https://kubernetes.io/dockershim/>
- Container Network Interface (CNI): <https://www.cni.dev/> · spec: <https://github.com/containernetworking/cni/blob/main/SPEC.md>
- Documentación de LXC / LXD: <https://linuxcontainers.org/lxc/documentation/>
- Perfiles de seguridad seccomp de Docker: <https://docs.docker.com/engine/security/seccomp/>
- Privilegios de runtime y Linux capabilities de Docker: <https://docs.docker.com/engine/containers/run/#runtime-privilege-and-linux-capabilities>
- Kubernetes — Configure a Security Context for a Pod: <https://kubernetes.io/docs/tasks/configure-pod-container/security-context/>
- Arquitectura del service mesh Istio: <https://istio.io/latest/docs/ops/deployment/architecture/>