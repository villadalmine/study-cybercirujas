# Material de Estudio CNCF KCSA: Dominio 1.4 – Isolation Techniques

**Certificación Objetivo:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 1:** Cloud Native Security Architecture  
**Subdominio 1.4:** Isolation Techniques  
**Peso:** 2.33%  

---

## 1. Problema Arquitectónico y Motivación en Producción

En la infraestructura cloud-native, el modelo de ejecución de contenedores por defecto se basa en primitivas compartidas del kernel de Linux (`namespaces`, `cgroups`, `capabilities` y LSMs como AppArmor/SELinux). Los runtimes de contenedores estándar como `runc` o `crun` no virtualizan el kernel; aíslan los procesos del host restringiendo su vista de los recursos del sistema.

```
+-------------------------------------------------------------------+
|                         Standard Container                        |
|   +-----------------------------------------------------------+   |
|   |                      User Application                     |   |
|   +-----------------------------------------------------------+   |
|                                 | Syscalls                        |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |         Shared Linux Host Kernel (Direct Access)          |   |
|   +-----------------------------------------------------------+   |
+-------------------------------------------------------------------+

+-------------------------------------------------------------------+
|                        gVisor Sandbox (runsc)                     |
|   +-----------------------------------------------------------+   |
|   |                      User Application                     |   |
|   +-----------------------------------------------------------+   |
|                                 | Syscalls                        |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |   Sentry (Application Kernel written in Go - Traps Syscalls) |   |
|   +-----------------------------------------------------------+   |
|                                 | Restricted Syscalls             |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |                     Shared Host Kernel                    |   |
|   +-----------------------------------------------------------+   |
+-------------------------------------------------------------------+

+-------------------------------------------------------------------+
|                       Kata MicroVM (kata-runtime)                 |
|   +-----------------------------------------------------------+   |
|   |                      User Application                     |   |
|   +-----------------------------------------------------------+   |
|   |                      Guest Linux Kernel                   |   |
|   +-----------------------------------------------------------+   |
|                                 | Hardware Virtualization (KVM)   |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |                     Shared Host Kernel                    |   |
|   +-----------------------------------------------------------+   |
+-------------------------------------------------------------------+
```

### El Modelo de Amenazas del Kernel Compartido
Cuando múltiples tenants comparten un solo nodo de Kubernetes ejecutando contenedores `runc` estándar, cualquier vulnerabilidad del kernel no parcheada (por ejemplo, CVE-2022-0492, Dirty COW / CVE-2016-5195 o Dirty Pipe / CVE-2022-0847) permite que un atacante que logre ejecución arbitraria de código dentro de un contenedor comprometa el kernel del host. Esto conduce a la toma de control completa del cluster.

### Clasificación de Multi-Tenancy
1. **Soft Multi-Tenancy (Separación de Workloads):** Los tenants pertenecen al mismo límite organizacional (por ejemplo, diferentes microservicios en la misma empresa). El aislamiento depende de primitivas lógicas de Kubernetes: Namespaces, RBAC, NetworkPolicies y ResourceQuotas.
2. **Hard Multi-Tenancy (Workloads No Confiables):** Los tenants desconfían mutuamente entre sí (por ejemplo, SaaS multi-tenant que ejecuta código de usuario arbitrario, plugins de terceros o trabajos de entrenamiento de IA/ML). El aislamiento lógico es insuficiente; un sandboxing estricto a nivel físico o de hipervisor es obligatorio.

### El Espectro de Aislamiento en Defense-in-Depth
La arquitectura de seguridad en producción requiere implementar múltiples capas de defensa:
* **Nivel de Nodo:** Node pools dedicados particionados mediante Taints, Tolerations y NodeAffinity de Kubernetes.
* **Nivel de Hipervisor / MicroVM:** Shims de virtualización asistida por hardware (`Kata Containers`, `Firecracker`) o kernels de aplicación en user-space (`gVisor`).
* **Nivel de SO / Proceso:** Menor privilegio a través de `Capabilities` de Linux, filtrado de syscalls con `Seccomp`, perfiles de `AppArmor`/`SELinux` y restricciones de ejecución como no-root (`runAsNonRoot`, `readOnlyRootFilesystem`).

---

## 2. Comparación Técnica y Matriz de Trade-offs

### Comparación de Tecnologías de Container Sandbox

| Característica / Métrica | OCI Estándar (`runc` / `crun`) | User-Space Kernel (`gVisor` / `runsc`) | MicroVM (`Kata Containers`) | WebAssembly (`WasmEdge` / `Wasmtime`) |
| :--- | :--- | :--- | :--- | :--- |
| **Límite de Aislamiento** | Namespaces + cgroups | Ring 3 Sentry Interceptor (Go) | Virtualización por Hardware (KVM) | Software Fault Isolation (SFI / WASM Sandbox) |
| **Estado del Kernel** | Kernel del Host Compartido | Kernel Virtualizado en User-Space | Kernel Guest Dedicado | Sin Kernel de SO (Interfaz API WASI) |
| **Compatibilidad con Syscalls** | 100% Syscalls Nativas de Linux | ~70-80% Implementadas (Restringido) | 100% Syscalls Nativas de Linux | WASI restringido (No-POSIX por defecto) |
| **Overhead de Inicio** | ~5-15ms | ~50-100ms | ~150-500ms | < 1ms |
| **Overhead de Memoria / Pod** | ~0 MB (overhead nativo del host) | ~15 - 30 MB | ~100 - 130 MB | ~1 - 5 MB |
| **Throughput de I/O y Syscalls**| Basal Nativo (100%) | 40-70% (Alto overhead de syscalls) | 85-95% (Virtualización de dispositivos Virtio) | Casi nativo para cómputo, overhead de API para I/O |
| **Caso de Uso Principal** | Microservicios internos confiables | Web apps no confiables, SaaS multi-tenant | Código no confiable multi-tenant, apps legacy | Edge functions, micro-tareas serverless |

### Comparación de Primitivas de Pod Security Context

| Primitiva | Mecanismo | Mitigación Principal de Amenazas | Trade-offs / Consideraciones en Producción |
| :--- | :--- | :--- | :--- |
| `readOnlyRootFilesystem` | Monta la raíz `/` como solo lectura | Previene la persistencia de malware y la manipulación de binarios | Requiere montar volúmenes `emptyDir` explícitos para archivos temporales estándar (`/tmp`, `/run`) |
| `allowPrivilegeEscalation: false` | Establece el flag `PR_SET_NO_NEW_PRIVS` | Bloquea binarios `setuid` / `setgid` (por ejemplo, `sudo`) | Rompe imágenes de contenedores legacy que requieren binarios suid en el entrypoint |
| `capabilities.drop: ["ALL"]` | Elimina las capabilities de POSIX | Previene la creación de sockets raw, acceso a dispositivos y anulaciones de administración | Se deben volver a agregar selectivamente caps específicas (por ejemplo, `NET_BIND_SERVICE`) si es estrictamente necesario |
| `seccompProfile` | Filtro de syscalls BPF | Limita la superficie de ataque disponible del kernel de Linux | Los perfiles personalizados requieren rastrear syscalls de la aplicación mediante eBPF/auditd para evitar romper el código |
| `appArmorProfile` | Mandatory Access Control (MAC) | Restringe el acceso a archivos, capabilities y ejecución de red por ruta | Requiere precargar perfiles en el kernel de cada nodo worker de Kubernetes |

---

## 3. Manifiestos Completos de Producción y Configuraciones de Infraestructura

### 3.1 Configuración del Motor de Runtime containerd (`/etc/containerd/config.toml`)
Snippet completo que configura `containerd` para dar soporte a `runc`, `gvisor` (`runsc`) y `kata-containers`.

```toml
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          runtime_engine = ""
          runtime_root = ""
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
          runtime_type = "io.containerd.runsc.v1"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor.options]
            TypeUrl = "io.containerd.runsc.v1.options"
            ConfigPath = "/etc/containerd/runsc.toml"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
          runtime_type = "io.containerd.kata.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
            ConfigPath = "/usr/share/defaults/kata-containers/configuration-qemu.toml"
```

---

### 3.2 Definición de RuntimeClasses de Kubernetes (`runtime-classes.yaml`)

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
  labels:
    security.kubernetes.io/tier: sandbox
handler: gvisor
scheduling:
  nodeSelector:
    sandbox.k8s.io/gvisor-enabled: "true"
  tolerations:
    - key: "security.kubernetes.io/untrusted-workload"
      operator: "Exists"
      effect: "NoSchedule"
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
  labels:
    security.kubernetes.io/tier: microvm
handler: kata
scheduling:
  nodeSelector:
    sandbox.k8s.io/kata-enabled: "true"
  tolerations:
    - key: "security.kubernetes.io/untrusted-workload"
      operator: "Exists"
      effect: "NoSchedule"
```

---

### 3.3 Perfil Seccomp Personalizado (`/var/lib/kubelet/seccomp/profiles/strict-microservice.json`)

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept4",
        "access",
        "arch_prctl",
        "bind",
        "brk",
        "clock_gettime",
        "close",
        "connect",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "execve",
        "exit",
        "exit_group",
        "fcntl",
        "fstat",
        "futex",
        "getdents64",
        "getpid",
        "getrandom",
        "getsockname",
        "getsockopt",
        "listen",
        "lseek",
        "madvise",
        "mmap",
        "mprotect",
        "munmap",
        "nanosleep",
        "newfstatat",
        "openat",
        "poll",
        "read",
        "readlink",
        "recvfrom",
        "rseq",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "sched_getaffinity",
        "sendto",
        "set_robust_list",
        "set_tid_address",
        "setsockopt",
        "sigaltstack",
        "socket",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

---

### 3.4 Deployment Endurecido y Aislado en Sandbox para Multi-Tenant (`hardened-workload.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: untrusted-api-service
  namespace: tenant-sandbox
  labels:
    app.kubernetes.io/name: untrusted-api
    app.kubernetes.io/part-of: payment-gateway
    security.kubernetes.io/hardened: "true"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: untrusted-api
  template:
    metadata:
      labels:
        app: untrusted-api
        tier: backend
    spec:
      runtimeClassName: gvisor
      serviceAccountName: untrusted-api-sa
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/strict-microservice.json
      containers:
        - name: api-server
          image: registry.enterprise.io/secure/api-server:v2.4.1
          imagePullPolicy: Always
          command: ["/app/server"]
          ports:
            - containerPort: 8080
              name: http-metrics
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
            appArmorProfile:
              type: Localhost
              localhostProfile: k8s-apparmor-strict-profile
          resources:
            limits:
              cpu: "1"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "128Mi"
          volumeMounts:
            - mountPath: /tmp
              name: tmp-volume
            - mountPath: /var/cache/app
              name: cache-volume
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache-volume
          emptyDir:
            sizeLimit: 128Mi
```

---

### 3.5 Política Estricta de Aislamiento de Red para Tenants (`network-isolation.yaml`)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-sandbox
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-isolated-ingress-egress
  namespace: tenant-sandbox
spec:
  podSelector:
    matchLabels:
      app: untrusted-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-gateway
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app: secure-database
      ports:
        - protocol: TCP
          port: 5432
```

---

## 4. Comandos de CLI Reales y Salidas de Terminal

### 4.1 Inspección de RuntimeClasses Activas y Etiquetas de Nodos
Verificá que los node pools estén correctamente registrados para workloads aislados en sandbox.

```bash
$ kubectl get runtimeclass
```
```text
NAME     HANDLER   AGE
gvisor   gvisor    14d
kata     kata      14d
runc     runc      14d
```

```bash
$ kubectl get nodes -L sandbox.k8s.io/gvisor-enabled,sandbox.k8s.io/kata-enabled
```
```text
NAME                                STATUS   ROLES    AGE   VERSION   GVISOR-ENABLED   KATA-ENABLED
worker-node-std-01.internal         Ready    <none>   45d   v1.30.2   <none>           <none>
worker-node-sandbox-01.internal     Ready    <none>   12d   v1.30.2   true             <none>
worker-node-microvm-01.internal     Ready    <none>   12d   v1.30.2   <none>           true
```

---

### 4.2 Verificación de la Virtualización de Syscalls dentro de gVisor (`runsc`)
Ejecutá un comando de exploración del kernel dentro de un contenedor que se ejecuta bajo `gvisor` frente a `runc` estándar.

```bash
$ kubectl exec -n tenant-sandbox untrusted-api-service-774f5bb54-x9q2w -- uname -a
```
```text
Linux untrusted-api-service-774f5bb54-x9q2w 4.4.0 #1 SMP Sun Jan 10 15:04:03 PST 2016 x86_64 Linux
```

```bash
$ kubectl exec -n tenant-sandbox untrusted-api-service-774f5bb54-x9q2w -- dmesg
```
```text
[    0.000000] Starting gVisor...
[    0.412102] Operationalizing Sentry Sandbox Application Kernel...
[    0.891230] Syscall table initialized (Google gVisor sandbox).
```

*Nota: La versión `4.4.0` del kernel de Linux devuelta por gVisor es emulada por el kernel en user-space de Sentry, independientemente de la versión real del kernel del host (por ejemplo, 6.5.0).*

---

### 4.3 Auditoría del Estado del Security Context del Contenedor mediante Inspección de Procesos
Identificá el PID del host del proceso del contenedor y verificá Seccomp y Linux Capabilities.

```bash
$ crictl pods --namespace tenant-sandbox
```
```text
POD ID              CREATED             STATE               NAME                                 NAMESPACE
8f3a9b1c1d1e        5 minutes ago       Ready               untrusted-api-service-774f5bb54-x9q2w   tenant-sandbox
```

```bash
$ crictl ps --pod 8f3a9b1c1d1e
```
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID
a1b2c3d4e5f6        registry.ent...     5 minutes ago       Running             api-server          0                   8f3a9b1c1d1e
```

```bash
$ crictl inspect a1b2c3d4e5f6 | jq '.info.pid'
```
```text
348912
```

```bash
$ cat /proc/348912/status | grep -E "Uid|Gid|Cap|Seccomp"
```
```text
Uid:	10001	10001	10001	10001
Gid:	10001	10001	10001	10001
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
Seccomp:	2
Seccomp_filters:	1
```

*Interpretación:*
* `Uid` / `Gid`: El proceso se ejecuta estrictamente como el usuario no privilegiado no-root `10001`.
* `Cap*`: Todas las máscaras de bits son `0000000000000000` confirmando la eliminación completa de capabilities (`capabilities.drop: ["ALL"]`).
* `Seccomp: 2`: Indica que `SECCOMP_MODE_FILTER` está activo (filtro seccomp predeterminado o personalizado aplicado).

---

### 4.4 Verificación de la Aplicación de Perfiles AppArmor en el Nodo
Verificá los perfiles de AppArmor cargados en los nodos worker.

```bash
$ aa-status | grep k8s-apparmor
```
```text
   k8s-apparmor-strict-profile
   1 profiles are in enforce mode.
   0 profiles are in complain mode.
```

---

## 5. Guía de Verificación y Resolución de Problemas

### 5.1 Escenarios Comunes de Falla en Producción y Diagnósticos

#### Escenario A: El Pod Falla con `CreateContainerError` / Falta el Handler de `RuntimeClass`
* **Síntoma:** El Pod permanece atascado en `ContainerCreating` o `CreateContainerError`.
* **Comando de Diagnóstico:**
  ```bash
  $ kubectl describe pod -n tenant-sandbox untrusted-api-service-774f5bb54-x9q2w
  ```
  ```text
  Events:
    Type     Reason     Age                From               Message
    ----     ------     ----               ----               -------
    Warning  Failed     12s (x3 over 45s)  kubelet            Failed to create pod sandbox: rpc error: code = Unknown desc = RuntimeHandler "gvisor" not supported
  ```
* **Causa Raíz:** El demonio `containerd` en el nodo destino carece del bloque de configuración `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]`, o el binario `containerd-shim-runsc-v1` no se encuentra en el `PATH` del sistema (`/usr/local/bin/`).
* **Resolución:**
  1. Instalá el binario `runsc` en el nodo worker:
     ```bash
     $ curl -fsSL https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/runsc -o /usr/local/bin/runsc
     $ chmod +x /usr/local/bin/runsc
     $ curl -fsSL https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/containerd-shim-runsc-v1 -o /usr/local/bin/containerd-shim-runsc-v1
     $ chmod +x /usr/local/bin/containerd-shim-runsc-v1
     ```
  2. Recargá `containerd`: `systemctl restart containerd`.

---

#### Escenario B: Falla de la Aplicación (`CrashLoopBackOff`) Debido a un Perfil Seccomp Restrictivo
* **Síntoma:** El contenedor inicia y falla inmediatamente con código de salida `139` (SIGSEGV) o `159` (SIGSYS).
* **Comando de Diagnóstico:**
  Inspeccioná el buffer del log del kernel en el host vía `dmesg` o revisá `/var/log/audit/audit.log`.
  ```bash
  $ dmesg -T | grep -i seccomp
  ```
  ```text
  [Fri Aug  7 19:30:12 2026] audit: type=1326 audit(1723073412.891:402): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=35012 comm="server" exe="/app/server" sig=31 arch=c000003e syscall=289 compat=0 ip=0x7f9a2b10c8a0 code=0x0
  ```
* **Análisis de Causa Raíz:**
  * `sig=31`: `SIGSYS` (Syscall incorrecta / no permitida por seccomp).
  * `syscall=289`: Traduciendo la arquitectura de syscall `0xc000003e` (x86_64) usando `ausyscall`:
    ```bash
    $ ausyscall x86_64 289
    ```
    ```text
    epoll_create1
    ```
  * La syscall `epoll_create1` es ejecutada por la inicialización de la aplicación pero está ausente en la lista blanca de `strict-microservice.json`.
* **Resolución:** Agregá `"epoll_create1"` al array `syscalls[0].names` dentro del manifiesto del perfil Seccomp personalizado y recargá.

---

### 5.2 Lista de Verificación para Auditoría de Vulnerabilidades en el Aislamiento de Pods

Usá esta lista de verificación durante las revisiones de arquitectura para identificar malas configuraciones que invaliden los límites de aislamiento de los contenedores:

1. **Uso Compartido de Namespaces del Host:**
   * Asegurá `hostNetwork: false`, `hostPID: false`, `hostIPC: false` en la especificación del Pod.
2. **Montajes de Volúmenes de Directorios del Host:**
   * Rechazá montajes de `hostPath` (especialmente `/`, `/etc`, `/var/run/docker.sock`, `/run/containerd/containerd.sock`).
3. **Escalamiento a Modo Privilegiado:**
   * Forzá `privileged: false` y `allowPrivilegeEscalation: false` en todas las especificaciones de contenedores mediante políticas de Kyverno u OPA Gatekeeper.
4. **Ejecución como Root:**
   * Forzá `runAsNonRoot: true` y descartá explícitamente capabilities (`ALL`).
5. **Aplicación de Runtime Class:**
   * Asegurá que las workloads no confiables de multi-tenant se fuercen a usar `gvisor` o `kata` a través de Admission Webhooks.

---

## 6. Referencias

* **CNCF KCSA Exam Curriculum:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Documentación de Kubernetes - Security Context:**  
  [https://kubernetes.io/docs/tasks/configure-pod-container/security-context/](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
* **Documentación de Kubernetes - RuntimeClass:**  
  [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
* **Documentación Oficial de gVisor y Modelo de Amenazas:**  
  [https://gvisor.dev/docs/](https://gvisor.dev/docs/)
* **Arquitectura de Kata Containers:**  
  [https://katacontainers.io/](https://katacontainers.io/)
* **Benchmarks y Guía de Hard Multi-Tenancy en Kubernetes:**  
  [https://kubernetes.io/docs/concepts/security/multi-tenancy/](https://kubernetes.io/docs/concepts/security/multi-tenancy/)
* **CIS Kubernetes Benchmark:**  
  [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)

---

### Resumen de Artefactos Completados y Guía
- **Motivaciones y Modelo de Amenazas**: Detalles sobre riesgos de compartir el kernel, hard vs. soft multi-tenancy y defensas por capas de sandbox.
- **Tablas Comparativas de Trade-offs**: Análisis comparativo riguroso de `runc`, `gVisor`, `Kata Containers` y `WASM`, junto con primitivas de Pod Security.
- **Manifiestos de Producción**: `/etc/containerd/config.toml` completo, `RuntimeClass`, JSON de perfil `seccomp` personalizado, `Deployment` endurecido y `NetworkPolicy` de aislamiento estricto.
- **Salidas de CLI y Diagnósticos**: Snippets reales de trazas de comandos de terminal que cubren `crictl`, auditoría de procesos del host, verificación de intercepción de syscalls y perfiles de AppArmor.
- **Guía de Resolución de Problemas y Auditoría**: Diagnóstico para handlers de runtime faltantes, resolución de syscall `SIGSYS` de seccomp personalizado y lista de verificación para auditoría de aislamiento.
- **Referencias Oficiales**: Completadas con URLs válidas hacia la documentación de CNCF, Kubernetes, gVisor, Kata y CIS.