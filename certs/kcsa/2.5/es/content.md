# Guía de estudio CNCF KCSA: Tema 2.5 – Seguridad de Container Runtime

**Certificación objetivo:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio:** 2.0 – Seguridad de contenedores  
**Subtema:** 2.5 Container Runtime  
**Peso:** 2.0  

---

## 1. Motivación en producción y problema arquitectónico

En las arquitecturas de contenedorización tradicionales, los contenedores no virtualizan hardware; aislan los recursos del sistema operativo utilizando primitivas del kernel de Linux, específicamente **namespaces** (`mnt`, `pid`, `net`, `ipc`, `uts`, `user`, `cgroup`) y **grupos de control (cgroups)**. Si bien este diseño produce una sobrecarga baja y una alta densidad, crea una superficie de ataque plana: **todos los contenedores que se ejecutan en un nodo host comparten el mismo kernel de Linux subyacente**.

```
+-----------------------------------------------------------------------+
|                         Host OS & Linux Kernel                        |
|   (Shared Syscall Table: sys_ptrace, sys_bpf, sys_unshare, etc.)       |
+-----------------------------------+-----------------------------------+
|     Standard Runtime (runc)       |      Sandboxed Runtime (runsc)    |
| +-------------------------------+ | +-------------------------------+ |
| | Pod A (Untrusted Workload)    | | | Pod B (Multi-tenant Tenant)  | |
| | - Direct kernel syscall pass  | | | - Intercepted syscalls (Go)   | |
| | - Vulnerable to kernel CVEs   | | | - Isolated Sentry / Gofer     | |
| +-------------------------------+ | +-------------------------------+ |
+-----------------------------------+-----------------------------------+
```

### La brecha de seguridad en producción
1. **Superficie de vulnerabilidad del kernel compartido**: Una vulnerabilidad de día cero (zero-day) en cualquiera de las ~350+ llamadas al sistema (syscalls) de Linux (por ejemplo, `CVE-2022-0492` en cgroups v1, `CVE-2022-0847` Dirty Pipe) permite que un atacante que logre ejecutar código dentro de un contenedor comprometa el kernel del host compartido, escape del límite del contenedor y comprometa todos los Pods adyacentes en el nodo.
2. **Acceso de llamadas al sistema de grano grueso**: De forma predeterminada, los runtimes estándar de bajo nivel presentan una interfaz de syscalls no curada a las cargas de trabajo (workloads). Incluso con los perfiles Seccomp predeterminados, más de 300 syscalls permanecen disponibles para los procesos contenedorizados.
3. **Separación inadecuada de responsabilidades**: Históricamente, los daemons monolíticos de contenedores se ejecutaban como un único proceso de fondo privilegiado. La arquitectura Cloud Native moderna exige la separación en **Runtimes de alto nivel** (implementaciones de CRI que gestionan el ciclo de vida, la distribución de imágenes y endpoints gRPC) y **Runtimes de bajo nivel** (binarios compatibles con OCI que ejecutan las transiciones de estado del contenedor).

---

## 2. Comparaciones técnicas y análisis profundo de la arquitectura

### Capas arquitectónicas: CRI vs. OCI

```
[ Kubelet ]
     |
     | gRPC (Container Runtime Interface - CRI)
     v
[ High-Level Runtime: containerd / CRI-O ]
     |
     | OCI Runtime Spec (JSON bundle & rootfs)
     v
[ Low-Level Runtime: runc / runsc / kata-runtime ]
     |
     v
[ Linux Kernel / MicroVM Sandbox ]
```

* **CRI (Container Runtime Interface)**: Una API gRPC definida por Kubernetes que permite a `kubelet` comunicarse con runtimes de contenedores de alto nivel (`containerd`, `CRI-O`) sin recompilar el binario de Kubernetes.
* **OCI (Open Container Initiative)**: Estándares que gobiernan las imágenes de contenedores (`image-spec`) y la ejecución de contenedores (`runtime-spec`). Los runtimes de bajo nivel consumen un bundle de OCI (un directorio que contiene `config.json` y un sistema de archivos raíz - rootfs) para generar contextos de ejecución aislados.

---

### Runtimes de alto nivel: containerd vs. CRI-O

| Característica | containerd | CRI-O |
| :--- | :--- | :--- |
| **Origen y gobernanza** | Graduado de la CNCF (originalmente Docker) | Graduado de la CNCF (Red Hat / comunidad de Kubernetes) |
| **Objetivo primario de diseño** | Motor de contenedores de propósito general que integra CRI mediante plugin | Runtime de CRI dedicado y ligero exclusivamente para Kubernetes |
| **Arquitectura** | Sistema de plugins modular (`io.containerd.grpc.v1.cri`) | Binario de propósito único adaptado estrictamente a las versiones de CRI de Kubernetes |
| **Gestión de imágenes** | Storage drivers integrados, distribución nativa de imágenes | Utiliza las librerías containers/image y containers/storage |
| **Archivo de configuración** | `/etc/containerd/config.toml` | `/etc/crio/crio.conf` |
| **Herramienta CLI de diagnóstico** | `ctr` (nativo), `crictl` (enfocado en CRI) | `crictl` (enfocado en CRI) |

---

### Runtimes de bajo nivel OCI: runc vs. gVisor (runsc) vs. Kata Containers

| Métrica técnica | `runc` (Predeterminado) | `gVisor` (`runsc`) | `Kata Containers` |
| :--- | :--- | :--- | :--- |
| **Mecanismo de aislamiento** | Kernel del host compartido (Namespaces + cgroups) | Kernel de aplicación en User Space (Sentry intercepta syscalls) | Virtualización asistida por hardware (MicroVM por Pod) |
| **Límite de seguridad** | Blando (Superficie de syscalls del kernel del host) | Duro (Sentry en User-space / Syscalls del host limitadas) | Duro (Hipervisor de hardware / VMX Root / Non-Root) |
| **Hipervisor / Kernel** | Ninguno (Kernel del host directo) | Sentry personalizado escrito en Go | QEMU / Cloud-Hypervisor / Firecracker |
| **Sobrecarga de latencia en syscalls** | Despreciable (~0%) | Moderada (~10–30% para tareas intensivas en E/S / syscalls) | Baja (~2–5% con dispositivos VIRTIO) |
| **Sobrecarga en consumo de memoria** | Mínima (~15–30 MB por contenedor) | Baja (~15–50 MB por sandbox) | Alta (~100–300 MB mínimo para el kernel guest de la VM) |
| **Latencia de inicio** | Instantánea (< 50ms) | Rápida (< 150ms) | Más lenta (300ms – 1.5s dependiendo del VMM) |
| **Compatibilidad** | 100% compatible con la API de Linux | ~70% (Bloquea sockets raw, módulos de kernel personalizados) | 100% compatible con la API de Linux |
| **Caso de uso en producción** | Cargas de trabajo internas de confianza | Microservicios multitenant sin confianza, ejecución de código de usuario | Código heredado sin confianza, límite duro multitenant |

---

### Límites de recursos: cgroups v1 vs. cgroups v2

```
cgroups v1 (Multi-Hierarchy):               cgroups v2 (Unified Hierarchy):
/sys/fs/cgroup/memory/kubepods/            /sys/fs/cgroup/kubepods.slice/
/sys/fs/cgroup/cpu/kubepods/               ├── cgroup.controllers
/sys/fs/cgroup/pids/kubepods/              ├── cgroup.procs
                                           └── memory.max, cpu.max, pids.max
```

1. **Jerarquía unificada**: cgroups v1 utiliza jerarquías independientes por subsistema (`memory`, `cpu`, `pids`), lo que genera condiciones de carrera (race conditions) y una contabilidad desarticulada de asignación de recursos. cgroups v2 utiliza un único árbol unificado donde los procesos residen únicamente en los nodos hoja.
2. **Pressure Stall Information (PSI)**: cgroups v2 introduce PSI para medir el thrashing de CPU, memoria y E/S antes de que ocurran eventos de out-of-memory (OOM) killer.
3. **Gestión de recursos sin root (Rootless)**: cgroups v2 permite de forma nativa que usuarios no root gestionen de forma segura subárboles de cgroups sin escalación de privilegios en el host.
4. **Control mejorado de OOM**: cgroups v2 permite la configuración de `memory.oom.group`, garantizando que todos los procesos dentro del sandbox del contenedor de un Pod se eliminen simultáneamente si ocurre un evento OOM, evitando estados de contenedores medio muertos.

---

## 3. Infraestructura y manifiestos en producción

### 3.1 Configuración de multi-runtime en containerd (`/etc/containerd/config.toml`)

Este fragmento de producción configura `containerd` con múltiples handlers de runtime OCI: el predeterminado `runc`, `gvisor` (`runsc`), y `kata-qemu`.

```toml
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"
    
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        
        # Standard default OCI runtime
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          runtime_engine = ""
          runtime_root = ""
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

        # Sandboxed Runtime: gVisor (runsc)
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
          runtime_type = "io.containerd.runsc.v1"
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor.options]
            TypeUrl = "io.containerd.runsc.v1.options"
            ConfigPath = "/etc/containerd/runsc.toml"

        # Sandboxed Runtime: Kata Containers (MicroVM)
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
          runtime_type = "io.containerd.kata.v2"
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
            ConfigPath = "/usr/share/defaults/kata-containers/configuration-qemu.toml"
```

---

### 3.2 Definiciones de RuntimeClass en Kubernetes

#### `runtime-class-gvisor.yaml`
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
  labels:
    security.cncf.io/tier: sandboxed
handler: gvisor
overhead:
  podFixed:
    memory: "50Mi"
    cpu: "100m"
scheduling:
  nodeSelector:
    container-runtime.cncf.io/gvisor-enabled: "true"
  tolerations:
    - key: "security.cncf.io/untrusted-workloads"
      operator: "Exists"
      effect: "NoSchedule"
```

#### `runtime-class-kata.yaml`
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
  labels:
    security.cncf.io/tier: microvm
handler: kata
overhead:
  podFixed:
    memory: "250Mi"
    cpu: "250m"
scheduling:
  nodeSelector:
    container-runtime.cncf.io/kata-enabled: "true"
```

---

### 3.3 Perfil Seccomp personalizado estricto (`/var/lib/kubelet/seccomp/profiles/strict-sec.json`)

Despliegue este perfil en todos los nodos worker en `/var/lib/kubelet/seccomp/profiles/strict-sec.json`.

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept4",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "exit",
        "exit_group",
        "futex",
        "getpid",
        "gettid",
        "read",
        "write",
        "mmap",
        "mprotect",
        "munmap",
        "brk",
        "rt_sigaction",
        "rt_sigprocmask",
        "sigaltstack",
        "version",
        "clock_gettime",
        "fstat",
        "close"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

---

### 3.4 Manifiesto de Pod endurecido en producción utilizando Sandboxed Runtime y Seccomp

#### `hardened-sandboxed-pod.yaml`
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-payment-processor
  namespace: production
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/tier: backend
spec:
  runtimeClassName: gvisor
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/strict-sec.json
  containers:
    - name: processor
      image: registry.enterprise.io/finance/payment-processor:v2.4.1
      imagePullPolicy: IfNotPresent
      command: ["/app/processor_binary"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          memory: "128Mi"
          cpu: "250m"
        limits:
          memory: "512Mi"
          cpu: "1000m"
      volumeMounts:
        - name: tmp-dir
          mountPath: /tmp
        - name: app-cache
          mountPath: /var/cache/app
  volumes:
    - name: tmp-dir
      emptyDir:
        medium: Memory
        sizeLimit: "64Mi"
    - name: app-cache
      emptyDir:
        sizeLimit: "128Mi"
```

---

## 4. Comandos CLI reales y salidas esperadas

### 4.1 Inspección del socket del runtime de alto nivel mediante `crictl`

```bash
$ crictl --runtime-endpoint unix:///run/containerd/containerd.sock info
```
```json
{
  "status": {
    "conditions": [
      {
        "type": "RuntimeReady",
        "status": true,
        "reason": "",
        "message": ""
      },
      {
        "type": "NetworkReady",
        "status": true,
        "reason": "",
        "message": ""
      }
    ]
  },
  "runtimeHandlers": {
    "gvisor": {
      "features": {
        "recursiveReadOnlyMounts": true
      }
    },
    "kata": {
      "features": {
        "recursiveReadOnlyMounts": false
      }
    },
    "runc": {
      "features": {
        "recursiveReadOnlyMounts": true
      }
    }
  },
  "config": {
    "containerd": {
      "defaultRuntimeName": "runc"
    }
  }
}
```

---

### 4.2 Listado de sandboxes de Pods en ejecución y handlers de runtime de bajo nivel

```bash
$ crictl pods --namespace production -o table
```
```
POD ID              CREATED             STATE               NAME                        NAMESPACE           ATTEMPT             RUNTIME GROUP
8f3a1b0c9e8d        10 minutes ago      Ready               secure-payment-processor    production          0                   gvisor
a2b3c4d5e6f7        2 hours ago         Ready               auth-service-7654321-x89    production          0                   runc
```

---

### 4.3 Inspección de árboles de procesos OCI de bajo nivel mediante `ctr`

```bash
$ ctr --namespace k8s.io task list
```
```
TASK                                    PID      STATUS    
secure-payment-processor-processor      48291    RUNNING
auth-service-7654321-x89-auth           51022    RUNNING
```

Ejecución de `pstree` en el host para verificar el aislamiento del sandbox de user-space de gVisor (`runsc`):

```bash
$ pstree -p 48291
```
```
containerd-shim-(48201)───runsc(48291)───runsc-sandbox(48310)───processor_binar(48350)
```

---

### 4.4 Verificación de la intercepción de llamadas al sistema del kernel (gVisor Sentry vs. Kernel del host)

Ejecutar `uname -a` dentro de un Pod `runc` devuelve la **versión del kernel del nodo host**:

```bash
$ kubectl exec -it auth-service-7654321-x89 -n production -- uname -a
```
```
Linux worker-node-01.infrastructure.internal 6.1.0-18-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 x86_64 GNU/Linux
```

Ejecutar `uname -a` dentro de un Pod `gvisor` devuelve la capa de emulación del **Kernel Virtual de gVisor (Sentry)**:

```bash
$ kubectl exec -it secure-payment-processor -n production -- uname -a
```
```
Linux secure-payment-processor 4.4.0 #1 SMP Sun Jan 10 00:00:00 2017 x86_64 GNU/Linux
```

---

## 5. Guía de verificación, endurecimiento y diagnóstico de fallos

```
                            [ Diagnosis Flow ]
                                    |
                    Is the Pod stuck in ContainerCreating?
                                   / \
                                 YES  NO
                                 /     \
    Check containerd logs via journalctl   Verify applied Seccomp status
    Filter by CRI runtime handler error     Inspect /proc/<PID>/status
```

### 5.1 Verificación del estado de Seccomp aplicado para un proceso
Para confirmar que un filtro seccomp está activo en un contenedor en ejecución sin confiar en las afirmaciones de las herramientas internas, busque el PID principal del contenedor en el host e inspeccione `/proc/<PID>/status`.

```bash
# Step 1: Find host PID of the target container
$ PID=$(crictl inspect --output go-template --template '{{.info.pid}}' <CONTAINER_ID>)

# Step 2: Query Seccomp field in kernel process status
$ grep -i "Seccomp" /proc/$PID/status
```
```
Seccomp:	2
Seccomp_filters:	1
```

> **Clave del estado de Seccomp:**
> * `0`: Deshabilitado (Sin aislamiento seccomp activo — **RIESGO CRÍTICO**)
> * `1`: Modo estricto (Permite solo `read`, `write`, `exit`, `sigreturn`)
> * `2`: Modo filtro (Perfil personalizado de `seccomp-bpf` activo o perfil `RuntimeDefault` aplicado)

---

### 5.2 Matriz de diagnóstico y fallos comunes en producción

#### Problema 1: Error `RuntimeHandlerNotSupported`
* **Síntoma**: El estado del Pod permanece en `ContainerCreating`. `kubectl describe pod <pod-name>` muestra:
  `Failed to create pod sandbox: rpc error: code = Unknown desc = RuntimeHandler "gvisor" not supported`
* **Causa raíz**: El nombre del handler de `RuntimeClass` especificado en el YAML (`handler: gvisor`) no coincide con ninguna entrada registrada bajo `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes]` en `/etc/containerd/config.toml`.
* **Remediación**:
  1. Actualice `/etc/containerd/config.toml` en todos los nodos afectados para definir la sección del handler de runtime objetivo.
  2. Recargue el daemon de containerd: `$ systemctl restart containerd`.

#### Problema 2: Violación de perfil Seccomp (`SIGSYS` / Código de salida 159)
* **Síntoma**: El contenedor falla repetidamente al iniciar con código de salida `159` o `139` (Terminado por `SIGSYS`).
* **Causa raíz**: El binario contenedorizado emitió una llamada al sistema bloqueada explícitamente por el perfil JSON personalizado de seccomp (`defaultAction: SCMP_ACT_ERRNO` o `SCMP_ACT_KILL`).
* **Procedimiento de diagnóstico**:
  Inspeccione los registros de auditoría del kernel del host (`dmesg` o `auditd`) para identificar el número de syscall bloqueada:
  ```bash
  $ dmesg -T | grep -i "seccomp"
  ```
  ```
  [Fri Aug  7 20:15:30 2026] audit: type=1326 audit(1723061730.412:98): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=48350 comm="processor_binary" exe="/app/processor_binary" sig=31 arch=c000003e syscall=257 compat=0 ip=0x7f9a12c4e10b code=0x0
  ```
  * `syscall=257`: Traduzca `257` usando `ausyscall x86_64 257` -> produce `openat`.
* **Remediación**: Agregue `"openat"` a la lista de nombres de syscalls permitidas dentro de `/var/lib/kubelet/seccomp/profiles/strict-sec.json` y vuelva a aplicar.

#### Problema 3: Asignación inválida de sobrecarga de runtime (Runtime Overhead)
* **Síntoma**: El cluster experimenta presión de nodo o pods desalojados sin programar debido al uso no contabilizado de recursos por parte de MicroVMs de Kata o daemons Sentry de gVisor.
* **Causa raíz**: Se creó `RuntimeClass` sin definir el campo `overhead`. La planificación de capacidad de Kubelet solo contabiliza las solicitudes/límites del contenedor, lo que provoca el agotamiento de memoria del host cuando los runtimes de bajo nivel consumen memoria fuera del límite cgroup del contenedor.
* **Remediación**: Aplique `overhead.podFixed` dentro de las especificaciones de `RuntimeClass` para todos los handlers de ejecución distintos de `runc`.

---

## 6. Referencias

* **CNCF KCSA Curriculum Repository**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Kubernetes Documentation – Container Runtimes**:  
  https://kubernetes.io/docs/setup/production-environment/container-runtimes/
* **Kubernetes Documentation – RuntimeClass**:  
  https://kubernetes.io/docs/concepts/containers/runtime-class/
* **Kubernetes Documentation – Restrict a Container's Syscalls with Seccomp**:  
  https://kubernetes.io/docs/tutorials/security/seccomp/
* **Open Container Initiative (OCI) Runtime Specification**:  
  https://github.com/opencontainers/runtime-spec
* **containerd Advanced Configuration & CRI Plugin**:  
  https://github.com/containerd/containerd/blob/main/docs/cri/config.md
* **gVisor Architecture & Security Model**:  
  https://gvisor.dev/docs/architecture/
* **Kata Containers Documentation & Architecture**:  
  https://katacontainers.io/docs/
* **Control Groups v2 (cgroups v2) Linux Kernel Documentation**:  
  https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html