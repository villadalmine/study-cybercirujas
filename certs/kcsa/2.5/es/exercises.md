# KCSA Dominio 2.5: Seguridad y Endurecimiento del Container Runtime

**Peso del Dominio:** 2.0  
**Certificación Objetivo:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Fuentes de Referencia:**
- CNCF KCSA Curriculum: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- Kubernetes Container Runtimes Architecture: [https://kubernetes.io/docs/setup/production-environment/container-runtimes/](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- Kubernetes RuntimeClass API Specification: [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- Open Container Initiative (OCI) Runtime Specification: [https://github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
- CNCF containerd Architecture & Hardening: [https://containerd.io/docs/](https://containerd.io/docs/)
- gVisor Sandbox Architecture: [https://gvisor.dev/docs/architecture_guide/](https://gvisor.dev/docs/architecture_guide/)

---

## 1. Análisis Arquitectónico Profundo: El Stack del Container Runtime

En los clusters de Kubernetes modernos, el pipeline de ejecución de contenedores está desacoplado en distintas capas a través de las especificaciones **Container Runtime Interface (CRI)** y **Open Container Initiative (OCI)**. Comprender esta arquitectura es vital para asegurar el nodo host y aplicar límites de aislamiento.

```
+-------------------------------------------------------------------------------+
|                                Kubelet                                        |
+-------------------------------------------------------------------------------+
                                   |
                       gRPC over Unix Domain Socket
               (/run/containerd/containerd.sock or /run/crio/crio.sock)
                                   v
+-------------------------------------------------------------------------------+
| Higher-Level CRI Runtime (containerd / CRI-O)                                |
|  - Image pull & unpacking                                                     |
|  - Storage management (snapshotters/overlayfs)                                |
|  - Cgroup lifecycle & network namespace orchestration                         |
+-------------------------------------------------------------------------------+
                                   |
                         OCI Runtime Spec Execution
                                   v
+-------------------------------------------------------------------------------+
| OCI Runtime Shim (containerd-shim-runc-v2 / containerd-shim-runsc-v1)         |
+-------------------------------------------------------------------------------+
                                   |
                Direct Kernel Syscall Interception / Execution
                                   v
  +--------------------------+    +--------------------------+    +--------------------------+
  |      Standard OCI        |    |     User-Space Kernel    |    |     MicroVM Sandbox      |
  |     (runc / crun)        |    |     (gVisor / runsc)     |    |    (Kata Containers)     |
  | Shared Host Kernel       |    | Syscall Interception     |    | Dedicated Guest Kernel   |
  | Namespaces + Cgroups     |    | Sentry/Gofer Isolation   |    | QEMU/Cloud-Hypervisor    |
  +--------------------------+    +--------------------------+    +--------------------------+
```

### Componentes Clave y Mecánica
1. **CRI Runtime (`containerd` / `CRI-O`)**: Gestiona el ciclo de vida del Pod, el estado del contenedor, la descarga de imágenes (image pulling) y la vinculación de namespaces. Se comunica con el Kubelet a través de un socket de dominio Unix local utilizando endpoints gRPC estándar definidos en la API de CRI (`RuntimeService` e `ImageService`).
2. **OCI Runtime (`runc`, `crun`)**: Herramienta de CLI ligera que interpreta la especificación estándar `config.json` de OCI para configurar namespaces de Linux (`pid`, `net`, `mnt`, `ipc`, `uts`, `user`, `cgroup`), cgroups (v1 o v2), capabilities, filtros seccomp y binarios de ejecución.
3. **OCI Shim (`containerd-shim-v2`)**: Un proceso sin demonio (daemonless) vinculado a cada Pod/contenedor en ejecución que mantiene descriptores de archivo (`stdio`), rastrea el estado de salida del proceso y aisla los reinicios de `containerd` de los procesos del contenedor en ejecución.
4. **Sandboxed Runtimes (`gVisor`, `Kata Containers`)**:
   - **gVisor (`runsc`)**: Implementa un kernel en espacio de usuario dentro del proceso ("Sentry") escrito en Go que intercepta las syscalls del contenedor. Evita que el código de aplicaciones no confiables llegue directamente al kernel Linux del host subyacente.
   - **Kata Containers**: Ejecuta cada Pod de Kubernetes dentro de una Máquina Virtual ligera dedicada (MicroVM) utilizando virtualización asistida por hardware (KVM). Proporciona un fuerte aislamiento en el límite del hipervisor con un kernel Linux guest dedicado.

---

## 2. Ejercicios Guiados de Producción

---

### Ejercicio 1: Intercepción de Comunicación CRI y Endurecimiento del Motor

**Objetivo:** Inspeccionar operaciones gRPC CRI en bruto usando `crictl`, configurar reglas de aislamiento del plugin de containerd y analizar los comportamientos por defecto del OCI runtime.

#### Paso 1.1: Inspeccionar el socket CRI local y listar los Pods activos del runtime
Ejecutar `crictl` directamente contra el socket de dominio Unix del nodo para inspeccionar los componentes internos del motor de contenedores sin pasar por la abstracción de la API de Kubelet.

```bash
# Set the default runtime endpoint for crictl
export CONTAINER_RUNTIME_ENDPOINT="unix:///run/containerd/containerd.sock"

# Verify CRI system info and status
sudo crictl info
```

**Salida Esperada:**
```json
{
  "status": {
    "conditions": [
      {
        "type": "RuntimeReady",
        "status": true
      },
      {
        "type": "NetworkReady",
        "status": true
      }
    ]
  },
  "cniselfservice": "true",
  "config": {
    "containerd": {
      "defaultRuntimeName": "runc"
    }
  }
}
```

#### Paso 1.2: Inspeccionar el árbol de procesos del contenedor y la asociación con el shim
Localizar un proceso de contenedor en ejecución en el SO host y observar cómo `containerd-shim-runc-v2` es el proceso padre del proceso del contenedor.

```bash
# Get PID of a running container via crictl
CONTAINER_ID=$(sudo crictl ps --state Running -q | head -n 1)
HOST_PID=$(sudo crictl inspect $CONTAINER_ID | jq '.info.pid')

echo "Container ID: ${CONTAINER_ID} mapped to Host PID: ${HOST_PID}"

# Trace process tree hierarchy on host
pstree -ps ${HOST_PID}
```

**Salida Esperada:**
```
systemd(1)---containerd(1240)---containerd-shim(8920)---nginx(9102)---nginx(9145)
```

#### Paso 1.3: Auditar la configuración de seguridad de containerd para los flags OCI por defecto
Inspeccionar `/etc/containerd/config.toml` para verificar si los manejadores de seguridad estándar y los cgroup drivers están configurados en systemd.

```bash
# View containerd CRI plugin configuration
sudo containerd config dump | grep -A 15 "\[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc\]"
```

**Salida Esperada:**
```toml
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          base_runtime_spec = ""
          cgroup_writable = false
          container_annotations = []
          pod_annotations = []
          privileged_without_host_devices = false
          runtime_engine = ""
          runtime_path = ""
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            BinaryName = ""
            CgroupParent = ""
            CriuPath = ""
            EnableTty = false
            NoPivotRoot = false
            NoNewKeyring = false
            SystemdCgroup = true
```

---

#### Preguntas de Verificación (Ejercicio 1)

1. **Pregunta:** ¿Cuál es el peligro crítico de seguridad de configurar `NoPivotRoot = true` en las opciones del OCI runtime dentro de `/etc/containerd/config.toml`?
2. **Pregunta:** ¿Por qué `containerd` genera un binario `containerd-shim-runc-v2` único para cada sandbox de Pod en lugar de hacer que el demonio principal de `containerd` sea el proceso padre de los procesos del contenedor directamente?

---

### Ejercicio 2: Implementación de Sandboxing de MicroVM y Espacio de Usuario mediante `RuntimeClass`

**Objetivo:** Configurar `containerd` para soportar `gVisor` (`runsc`) como manejador de runtime secundario, declarar una `RuntimeClass` de Kubernetes y desplegar un workload para verificar el aislamiento de syscalls.

#### Paso 2.1: Agregar el manejador de runtime gVisor (`runsc`) a la configuración de containerd
Crear un snippet de configuración o anexar la definición del manejador `runsc` a `/etc/containerd/config.toml`.

```bash
# Append runsc configuration to containerd config
sudo tee -a /etc/containerd/config.toml << 'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
  runtime_type = "io.containerd.runsc.v1"
EOF

# Restart containerd service to apply runtime registration
sudo systemctl restart containerd
```

#### Paso 2.2: Crear el manifiesto de `RuntimeClass` de Kubernetes
Aplicar el recurso `RuntimeClass` de ámbito de cluster apuntando al manejador registrado en `containerd`.

```yaml
# File: runtime-class-gvisor.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
scheduling:
  nodeSelector:
    sandbox.type/gvisor: "true"
tolerations:
  - key: "sandbox.type/gvisor"
    operator: "Exists"
    effect: "NoSchedule"
---
```

Aplicar manifiesto:
```bash
kubectl apply -f runtime-class-gvisor.yaml
```

#### Paso 2.3: Desplegar un Pod asignado a la `RuntimeClass` con sandbox
Desplegar un workload no confiable que solicite el runtime `gvisor`.

```yaml
# File: sandboxed-workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-workload
  namespace: default
spec:
  runtimeClassName: gvisor
  containers:
  - name: untrusted-app
    image: alpine:3.19
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop:
        - ALL
```

Aplicar manifiesto:
```bash
kubectl apply -f sandboxed-workload.yaml
```

#### Paso 2.4: Validar el aislamiento del Kernel dentro del contenedor con sandbox
Ejecutar `uname -a` e inspeccionar los logs de dmesg dentro del contenedor para confirmar la redirección del kernel por parte de gVisor Sentry.

```bash
# Execute uname inside standard pod vs gvisor pod
kubectl exec untrusted-workload -- uname -a
```

**Salida Esperada:**
```
Linux untrusted-workload 4.4.0-gVisor #1 SMP Sun Jan 1 00:00:00 2017 x86_64 Linux
```
*(Observe la versión de kernel falsa y estática `4.4.0-gVisor` devuelta por Sentry, lo que demuestra que el workload está desacoplado de los detalles de la versión del kernel del host)*.

---

#### Preguntas de Verificación (Ejercicio 2)

1. **Pregunta:** Si una aplicación que se ejecuta dentro de un Pod con sandbox de gVisor intenta ejecutar una syscall de Linux no soportada, ¿qué sucede a nivel de arquitectura?
2. **Pregunta:** ¿Cuáles son los principales compromisos (trade-offs) de rendimiento al seleccionar un kernel en espacio de usuario (gVisor `runsc`) frente a una MicroVM por hardware (Kata Containers) frente al OCI por defecto (`runc`)?

---

### Ejercicio 3: Restricción Avanzada de Syscalls mediante Perfiles Personalizados de Seccomp

**Objetivo:** Escribir un perfil personalizado y restrictivo de Seccomp en JSON, instalarlo en los nodos del cluster, adjuntarlo usando el `securityContext` de Kubernetes y verificar la ejecución bloqueada usando `strace` / `bpftrace`.

#### Paso 3.1: Crear un perfil JSON personalizado y restrictivo de Seccomp
Guardar este perfil personalizado en el directorio raíz de Kubelet en el nodo: `/var/lib/kubelet/seccomp/profiles/fine-grained-restrictive.json`.

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
        "write",
        "writev",
        "read",
        "close",
        "fstat",
        "mmap",
        "mprotect",
        "munmap",
        "brk",
        "rt_sigaction",
        "rt_sigprocmask",
        "execve",
        "arch_prctl"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Copiar el archivo a la ubicación de destino:
```bash
sudo mkdir -p /var/lib/kubelet/seccomp/profiles/
sudo cp fine-grained-restrictive.json /var/lib/kubelet/seccomp/profiles/fine-grained-restrictive.json
```

#### Paso 3.2: Desplegar un Pod que haga referencia al Perfil Seccomp Localhost
Crear un manifiesto que aplique el perfil seccomp personalizado.

```yaml
# File: hardened-seccomp-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-seccomp-pod
  namespace: default
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/fine-grained-restrictive.json
  containers:
  - name: hardened-container
    image: alpine:3.19
    command: ["/bin/sh", "-c", "echo Application Started; sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 10002
      capabilities:
        drop:
        - ALL
```

Aplicar manifiesto:
```bash
kubectl apply -f hardened-seccomp-pod.yaml
```

#### Paso 3.3: Verificar el fallo de ejecución en syscalls no autorizadas
Intentar ejecutar un binario dentro del Pod que emita syscalls no permitidas (por ejemplo, `mkdir` o `chown`).

```bash
# Attempt unauthorized syscall
kubectl exec hardened-seccomp-pod -- mkdir /tmp/test-dir
```

**Salida Esperada:**
```
command terminated with exit code 1
mkdir: cannot create directory '/tmp/test-dir': Operation not permitted
```

#### Paso 3.4: Diagnosticar la syscall bloqueada a través de los Logs de Auditoría del Kernel
Inspeccionar los logs de auditoría del sistema host para identificar el número exacto de la syscall bloqueada.

```bash
# Query auditd / dmesg logs for audit SECCOMP events
sudo journalctl -k --grep="SECCOMP" | tail -n 5
```

**Salida Esperada:**
```
Audit: type=1326 audit(1710001200.412:981): auid=4294967295 uid=10002 gid=10002 ses=4294967295 pid=14201 comm="mkdir" exe="/bin/mkdir" sig=0 arch=c000003e syscall=83 compat=0 ip=0x7f8a1012a417 code=0x050000
```
*(Aquí `syscall=83` corresponde a `mkdir` en x86_64, el cual fue denegado con `SCMP_ACT_ERRNO`)*.

---

#### Preguntas de Verificación (Ejercicio 3)

1. **Pregunta:** ¿Cuál es la diferencia entre `defaultAction: "SCMP_ACT_ERRNO"` y `defaultAction: "SCMP_ACT_KILL"` en el diseño de seguridad de Seccomp para producción?
2. **Pregunta:** ¿Cómo mapea Kubelet la ruta definida en `localhostProfile: profiles/fine-grained-restrictive.json` a la ruta del sistema de archivos del host?

---

### Ejercicio 4: Control de Acceso Obligatorio (MAC) mediante la Aplicación de Perfiles de AppArmor

**Objetivo:** Escribir, cargar y aplicar un perfil de AppArmor en los nodos host para restringir el acceso al sistema de archivos del contenedor, los sockets de red y los privilegios de ejecución.

#### Paso 4.1: Escribir un Perfil de Seguridad de AppArmor en el Nodo
Definir un perfil de AppArmor que evite el acceso de escritura a `/etc` y restrinja la ejecución de binarios.

```apparmor
# File: /etc/apparmor.d/k8s-deny-etc-write
#include <tunables/global>

profile k8s-deny-etc-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Allow read access to standard system paths
  /usr/bin/* ix,
  /bin/* ix,
  /lib/* mr,
  /lib64/* mr,

  # Explicitly deny write access to /etc directory and subpaths
  deny /etc/** w,

  # Allow read access to /etc
  /etc/** r,
}
```

#### Paso 4.2: Cargar el perfil en el motor AppArmor del Kernel de Linux
Analizar y cargar el perfil utilizando `apparmor_parser`.

```bash
# Load profile into kernel
sudo apparmor_parser -q -r /etc/apparmor.d/k8s-deny-etc-write

# Verify profile is active in kernel memory
sudo aa-status | grep k8s-deny-etc-write
```

**Salida Esperada:**
```
   k8s-deny-etc-write
```

#### Paso 4.3: Desplegar un Pod aplicando el Perfil de AppArmor personalizado
Adjuntar el perfil a través del `securityContext` estándar de Kubernetes (`appArmorProfile`).

```yaml
# File: apparmor-restricted-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-restricted-pod
  namespace: default
spec:
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-etc-write
  containers:
  - name: restricted-app
    image: alpine:3.19
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
```

Aplicar manifiesto:
```bash
kubectl apply -f apparmor-restricted-pod.yaml
```

#### Paso 4.4: Validar la aplicación del control de acceso obligatorio
Intentar escribir en `/etc/test.conf` desde el interior del Pod.

```bash
kubectl exec apparmor-restricted-pod -- touch /etc/test.conf
```

**Salida Esperada:**
```
touch: /etc/test.conf: Permission denied
```

---

#### Preguntas de Verificación (Ejercicio 4)

1. **Pregunta:** ¿Cuál es la diferencia funcional entre el modo enforce y el modo complain de AppArmor, y cómo los equipos de SRE despliegan de forma segura nuevos perfiles de AppArmor en workloads de producción de alto tráfico?
2. **Pregunta:** En un cluster de Kubernetes multinodo, ¿qué mecanismo garantiza que un Pod que especifica `localhostProfile: k8s-deny-etc-write` se programe únicamente en nodos donde el perfil ya esté cargado en el espacio del kernel?

---

## 3. Respuestas de Verificación y Explicaciones de Diagnóstico

<details>
<summary><strong>Haga clic para ver las Respuestas y Explicaciones Técnicas</strong></summary>

### Respuestas del Ejercicio 1

1. **Respuesta (Peligro de seguridad de NoPivotRoot):**
   - **Mecánica:** En los OCI runtimes (`runc`), `pivot_root` cambia el namespace de montaje raíz del proceso del contenedor para que no pueda ver ni recorrer el sistema de archivos del sistema host. Configurar `NoPivotRoot = true` fuerza a `runc` a usar `chroot` en lugar de `pivot_root`.
   - **Riesgo de Seguridad:** `chroot` no modifica la tabla de montaje ni aísla completamente el namespace de montaje. Un proceso dentro del contenedor con `CAP_SYS_CHROOT` o capacidades de root puede escapar de `chroot` utilizando descriptores de archivo abiertos que apunten fuera de `chroot` (por ejemplo, bucles de exploit `fchdir` estándar), lo que lleva al compromiso total del sistema de archivos del host.

2. **Respuesta (Justificación de la arquitectura Shim):**
   - **Mecánica:** El demonio `containerd-shim-v2` actúa como un supervisor ligero para un único sandbox de Pod.
   - **Justificación:**
     1. **Mantenimiento sin Demonio:** Si el demonio principal de `containerd` se bloquea o sufre una actualización binaria sin tiempo de inactividad, los procesos del contenedor permanecen en ejecución sin interrupción porque su proceso padre es el shim, no `containerd`.
     2. **Aislamiento de Descriptores de Archivo:** Mantiene abiertas las tuberías de `stdin`, `stdout` y `stderr` del contenedor a través de los reinicios del demonio.
     3. **Propagación del Código de Salida:** Captura los códigos de salida del contenedor y los reporta de forma asíncrona de vuelta a CRI a petición.

---

### Respuestas del Ejercicio 2

1. **Respuesta (Comportamiento de syscall no soportada en gVisor):**
   - **Mecánica:** Cuando una aplicación ejecuta una syscall no soportada o no implementada en gVisor, la llamada es interceptada por el proceso **Sentry** en espacio de usuario.
   - **Comportamiento:** El Sentry no reenvía la llamada al kernel del host. En su lugar, devuelve directamente `ENOSYS` (Función no implementada) o `EPERM` al proceso del contenedor dentro del espacio de usuario. Esto evita exploits de kernel de día cero a través de rutas de código de kernel no examinadas.

2. **Respuesta (Análisis de Compromisos/Trade-offs del Runtime):**

| Característica | OCI por Defecto (`runc` / `crun`) | Kernel en Espacio de Usuario (`gVisor`) | MicroVM (`Kata Containers`) |
| :--- | :--- | :--- | :--- |
| **Límite de Aislamiento** | Kernel Linux Compartido (Namespaces + Cgroups) | Intercepción de Syscalls en Espacio de Usuario (Sentry) | Virtualización por Hardware Dedicada (Kernel Guest KVM) |
| **Superficie de Ataque** | Alta (Acceso directo a ~350+ syscalls del host) | Mínima (Syscalls del host reducidas a ~50) | Mínima (El límite del hipervisor protege el kernel del host) |
| **Sobrecarga de Inicio** | Extremadamente Baja (~10ms) | Baja (~50-100ms) | Moderada a Alta (~500ms - 2s) |
| **Huella de Memoria** | Mínima (~5-10MB de sobrecarga) | Baja (~15-30MB de memoria de Sentry) | Mayor (~100MB+ para Kernel Guest + QEMU) |
| **Rendimiento de E/S y Red** | Velocidad casi nativa | Sobrecarga moderada (Cambios de contexto en Go Sentry) | Casi nativo con vhost-user / pasarela SR-IOV |
| **Caso de Uso Principal en Producción** | Workloads internos de confianza | Microservicios / Webhooks multitenant no confiables | SaaS multitenant, ejecución de código no confiable |

---

### Respuestas del Ejercicio 3

1. **Respuesta (`SCMP_ACT_ERRNO` frente a `SCMP_ACT_KILL`):**
   - **`SCMP_ACT_ERRNO`:** Devuelve un código de error (como `EPERM`) al proceso solicitante cuando ocurre una syscall restringida. El proceso captura el error y puede fallar de forma elegante, registrar un mensaje de error o tomar rutas de ejecución alternativas. Recomendado para pruebas iniciales y aplicaciones de producción resilientes.
   - **`SCMP_ACT_KILL` / `SCMP_ACT_KILL_PROCESS`:** Termina inmediatamente todo el hilo o grupo de procesos a nivel de kernel sin devolver un error.
   - **Compromiso de Diseño en Producción:** `SCMP_ACT_KILL` proporciona una seguridad de tolerancia cero absoluta (deteniendo a un atacante en pleno exploit), pero puede provocar bloqueos inesperados de la aplicación o bucles de reinicio (crash loops) si se invoca una syscall legítima poco común.

2. **Respuesta (Mapeo de Rutas de Seccomp en Kubelet):**
   - **Mecánica:** Kubelet resuelve las rutas relativas del perfil de seccomp en relación con su directorio raíz de seccomp configurado: `--seccomp-profile-root` (que por defecto es `/var/lib/kubelet/seccomp`).
   - Por lo tanto, `localhostProfile: profiles/fine-grained-restrictive.json` se expande strictly en el sistema de archivos del nodo a `/var/lib/kubelet/seccomp/profiles/fine-grained-restrictive.json`. El recorrido de rutas fuera de este directorio raíz utilizando `..` es bloqueado por Kubelet.

---

### Respuestas del Ejercicio 4

1. **Respuesta (Estrategia de Despliegue de AppArmor):**
   - **Modo Enforce:** Bloquea acciones no autorizadas que coincidan con reglas `deny` o que carezcan de reglas `allow`, registrando las violaciones en auditd.
   - **Modo Complain:** Permite acciones no autorizadas pero registra una advertencia en el log del kernel (`dmesg` / `auditd`).
   - **Estrategia de Despliegue Seguro de SRE:**
     1. Desplegar el perfil en **Modo Complain** (`aa-complain /etc/apparmor.d/k8s-profile`).
     2. Ejecutar pruebas de integración completas y tráfico sintético de producción contra el workload.
     3. Recopilar y analizar los logs de auditoría usando `aa-logprof` para descubrir todos los eventos legítimos de ejecución de binarios y sistema de archivos.
     4. Refinar las reglas y convertir el perfil a **Modo Enforce** (`aa-enforce`) en producción.

2. **Respuesta (Aplicación de Programación en el Cluster para Perfiles):**
   - **Problema:** Si un Pod solicita un perfil de AppArmor que no existe en el nodo seleccionado por `kube-scheduler`, el motor de contenedores falla al iniciar el contenedor (`CreateContainerError`).
   - **Solución:** El `kube-scheduler` nativo de Kubernetes no comprueba automáticamente la presencia del perfil en los nodos. Las plataformas de producción aplican la alineación de programación utilizando:
     1. Etiquetado de Nodos (Node Labeling) + `nodeSelector` / `nodeAffinity` (como se muestra en el Ejercicio 2 para las RuntimeClasses).
     2. DaemonSets que garantizan la distribución del perfil en el 100% de los nodos del cluster antes de programar los workloads (por ejemplo, utilizando el **Security Profiles Operator**).
     3. Admission Controllers (como Kyverno u OPA Gatekeeper) que validan la preparación del nodo o mutan la afinidad del nodo según los perfiles de seguridad solicitados.

</details>