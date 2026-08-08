# Guía de Estudio KCSA: Tema 2.7 – Arquitectura de Seguridad y Fortalecimiento (Hardening) de Pods

**Certificación:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Tema 2.7:** Pod  
**Peso del examen:** 2.0%  

---

## 1. Motivación de Arquitectura en Producción y Modelo de Amenazas

En Kubernetes, el **Pod** es la unidad de ejecución desplegable más pequeña. Arquitectónicamente, un Pod no es un proceso único ni una máquina virtual a nivel de sistema operativo, sino un grupo co-ubicado de contenedores Linux que comparten namespaces del kernel y recursos IPC.

```
+-----------------------------------------------------------------------------------+
| Linux Worker Node (Host Kernel)                                                   |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  | Pod Isolation Boundary                                                      |  |
|  |                                                                             |  |
|  | Shared Namespaces: Network (netns), IPC (ipcns), UTS (utsns)                |  |
|  | Shared Storage: Volumes (Mount Points)                                      |  |
|  |                                                                             |  |
|  |  +---------------------------+       +-----------------------------------+  |  |
|  |  | Container A (App)         |       | Container B (Sidecar)             |  |  |
|  |  |                           |       |                                   |  |  |
|  |  | Isolated Namespaces:      |       | Isolated Namespaces:              |  |  |
|  |  | - Mount (mntns)           |       | - Mount (mntns)                   |  |  |
|  |  | - PID (pidns, default)    |       | - PID (pidns, default)            |  |  |
|  |  |                           |       |                                   |  |  |
|  |  | Linux Security Controls:  |       | Linux Security Controls:          |  |  |
|  |  | - seccomp, AppArmor       |       | - seccomp, AppArmor               |  |  |
|  |  | - Capabilities (dropped)  |       | - Capabilities (dropped)          |  |  |
|  |  | - cgroups v2 limits       |       | - cgroups v2 limits               |  |  |
|  |  +---------------------------+       +-----------------------------------+  |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### El Problema del Perímetro de Seguridad
Por defecto, las definiciones estándar de Pod heredan valores predeterminados permisivos de los runtimes de contenedores (`containerd`, `CRI-O`). Sin controles de seguridad explícitos, los contenedores que se ejecutan dentro de un Pod introducen severos riesgos de seguridad:

1. **Escalación de Privilegios y Extracción de Contenedores (Container Breakout)**: Ejecutarse como `root` (UID 0) dentro de un contenedor sin eliminar capacidades (capabilities) permite a los atacantes que logran la Ejecución Remota de Código (RCE) explotar vulnerabilidades del kernel o fallas en el runtime del contenedor (por ejemplo, CVE-2019-5736 en `runc`, CVE-2022-0492 en `cgroups v1`) para escapar al nodo host.
2. **Recorrido de Namespaces del Host y del Sistema de Archivos**: Los Pods mal configurados que montan rutas del host (`hostPath`) o se ejecutan con `hostNetwork: true`, `hostPID: true` o `hostIPC: true` vulneran por completo el límite del Pod, permitiendo que los procesos inspeccionen el tráfico de red del host, inspeccionen los procesos del host o sobrescriban binarios del nodo (`/usr/bin`, `/var/log`).
3. **Movimiento Lateral a través de Tokens de Service Account**: Kubernetes proyecta automáticamente el token JWT por defecto del ServiceAccount en `/var/run/secrets/kubernetes.io/serviceaccount/` a menos que se deshabilite explícitamente. Si un Pod se ve comprometido, un atacante puede usar este token para consultar el API Server e intentar un movimiento lateral dentro del cluster.
4. **Agotamiento de Recursos Compartidos (Noisy Neighbor / DoS)**: Los Pods sin límites pueden consumir toda la memoria del host, CPU o descriptores de archivo, causando pánicos de Out-Of-Memory (OOM) del kernel a nivel de nodo o la inanición de daemons críticos del sistema (`kubelet`, `containerd`).

---

## 2. Mecánica Técnica y Arquitectura

### Primitivas de Aislamiento del Kernel de Linux en Pods

Kubernetes se apoya en primitivas subyacentes del kernel de Linux configuradas por la implementación de la Container Runtime Interface (CRI):

*   **Namespaces (flags de `clone`)**:
    *   `CLONE_NEWNET`: Los contenedores del Pod comparten un único namespace de red por defecto (una sola IP por Pod, `localhost` compartido).
    *   `CLONE_NEWIPC`: System V IPC y colas de mensajes POSIX compartidas entre contenedores en el mismo Pod.
    *   `CLONE_NEWUTS`: Identificador de hostname compartido.
    *   `CLONE_NEWPID`: Aislado por contenedor por defecto, pero se puede compartir entre contenedores dentro del Pod si se define `shareProcessNamespace: true`.
    *   `CLONE_NEWNS` (Mount): Aislado por contenedor, lo que permite sistemas de archivos raíz únicos superpuestos a las capas de la imagen.
    *   `CLONE_NEWUSER`: Mapea UIDs/GIDs de contenedores a UIDs/GIDs no privilegiados del host (User Namespaces).
*   **Control Groups (`cgroups v2`)**: Aplica límites estrictos de memoria, ancho de banda de CPU (`cpu.max`), rendimiento de E/S (`io.max`) y cantidad de procesos (`pids.max`) para garantizar clases de QoS (`Guaranteed`, `Burstable`, `BestEffort`).
*   **POSIX Capabilities (`capabilities(7)`)**: Desglosa el privilegio monolítico de `root` en permisos distintos. Los Pods fortalecidos (hardened) eliminan (`drop`) **TODAS** las capacidades y retienen selectivamente solo aquellas necesarias (por ejemplo, `CAP_NET_BIND_SERVICE`).
*   **Filtrado de Llamadas al Sistema (`seccomp`)**: Restringe la interfaz de syscalls expuesta por el kernel de Linux al proceso del contenedor. El perfil `RuntimeDefault` bloquea syscalls de riesgo como `unshare`, `clone` con flags específicos, `keyctl` y `sys_ptrace`.

---

### Matriz Comparativa de Pod Security Standards (PSS)

Kubernetes define tres niveles de Pod Security Standards (PSS) aplicados nativamente por **Pod Security Admission (PSA)**:

| Característica / Control | `Privileged` | `Baseline` | `Restricted` (Estándar de Producción) |
| :--- | :--- | :--- | :--- |
| **Alcance Previsto** | Agentes de infraestructura (CNI, CSI, monitoreo del sistema). | Aplicaciones no fortalecidas (un-hardened), cargas de trabajo legadas. | Cargas de trabajo críticas de seguridad y producción general. |
| **Modo Privilegiado (`privileged`)** | Permitido (`true`) | Prohibido (`false`) | Prohibido (`false`) |
| **Namespaces del Host (`hostNetwork`, `hostPID`, `hostIPC`)** | Permitido | Prohibido | Prohibido |
| **Linux Capabilities** | Sin restricción | Restringe capacidades peligrosas (`SYS_ADMIN`, etc.) | Elimina **TODAS** las capacidades (`drop: ["ALL"]`); adición opcional de `NET_BIND_SERVICE`. |
| **UID de Ejecución (`runAsNonRoot`)** | Sin restricción (Permite `root`) | Sin restricción | **Obligatorio** (`runAsNonRoot: true`, `runAsUser` distinto de cero). |
| **Escalación de Privilegios (`allowPrivilegeEscalation`)** | Permitido | Permitido | **Prohibido** (`false`). |
| **Perfil Seccomp (`seccompProfile`)** | Sin restricción | Sin restricción | **Obligatorio** (`RuntimeDefault` o `Localhost`). |
| **Sistema de Archivos Raíz (`readOnlyRootFilesystem`)** | Con escritura | Con escritura | Recomendado / Requerido por políticas empresariales (`true`). |
| **Tipos de Volúmenes Permitidos** | Todos los tipos de volúmenes (`hostPath`, `secret`, etc.) | Restringe `hostPath` | Restringe `hostPath`; permite `configMap`, `secret`, `emptyDir`, `persistentVolumeClaim`. |

---

## 3. Manifiestos YAML Listos para Producción

### Manifiesto 1: Carga de Trabajo Fortalecida para Producción (Conforme a PSS `Restricted`)

Este manifiesto aplica un aislamiento completo del contenedor, inmutabilidad, cero capacidades, ejecución como usuario no-root y restricciones explícitas de recursos.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: e-commerce
    app.kubernetes.io/managed-by: argocd
    security.cncf.io/tier: restricted
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-processor
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-processor
    spec:
      # Block automatic API token mounting to mitigate lateral movement vectors
      automountServiceAccountToken: false
      
      # Pod-level SecurityContext
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        fsGroupChangePolicy: "OnRootMismatch"
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: app
          image: registry.enterprise.io/finance/payment-processor:v2.4.1
          imagePullPolicy: IfNotPresent

          # Container-level SecurityContext overrides/reinforcements
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL

          ports:
            - name: http-metrics
              containerPort: 8080
              protocol: TCP

          # Resource limits map to Linux cgroups v2
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"

          # Ephemeral writable mounts for applications requiring temporary storage
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: cache-volume
              mountPath: /var/cache/app

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

### Manifiesto 2: Configuración de Namespace para Pod Security Admission (PSA)

Aplica el estándar PSS `restricted` a nivel de admission controller del API server para todos los Pods creados en el namespace objetivo.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-workloads
  labels:
    # Pod Security Admission labels
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: "v1.30"
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: "v1.30"
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: "v1.30"
```

---

### Manifiesto 3: Pod Multicontenedor Seguro (Patrón Sidecar)

Demuestra el aislamiento de IPC y la comunicación mediante volúmenes compartidos entre un contenedor de aplicación y un sidecar de envío de logs bajo restricciones estrictas de seguridad.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app-with-sidecar
  namespace: production-workloads
spec:
  automountServiceAccountToken: false
  
  # Enable PID namespace sharing ONLY if explicitly required for process monitoring sidecars
  shareProcessNamespace: false

  securityContext:
    runAsNonRoot: true
    runAsUser: 20000
    runAsGroup: 20000
    fsGroup: 20000
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: primary-api
      image: registry.enterprise.io/apps/api-service:v1.1.0
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "200m"
          memory: "256Mi"
      volumeMounts:
        - name: shared-logs
          mountPath: /var/log/app

    - name: log-shipper
      image: registry.enterprise.io/ops/fluent-bit:v3.0.2
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "128Mi"
      volumeMounts:
        - name: shared-logs
          mountPath: /var/log/app
          readOnly: true
        - name: fluentbit-config
          mountPath: /fluent-bit/etc

  volumes:
    - name: shared-logs
      emptyDir:
        sizeLimit: 256Mi
    - name: fluentbit-config
      configMap:
        name: fluentbit-config
```

---

## 4. Comandos de CLI Reales y Salidas de Terminal ($)

### Comando 1: Verificación de la Aplicación de Políticas PSA mediante Dry-Run

Ejecución de `kubectl apply` con un Pod no fortalecido contra un namespace configurado con `pod-security.kubernetes.io/enforce: restricted`.

```bash
$ kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: unhardened-test-pod
  namespace: production-workloads
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF
```

**Salida Esperada:**

```text
Error from server (Forbidden): error when creating "STDIN": pods "unhardened-test-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### Comando 2: Inspección de Linux Capabilities de Bajo Nivel y Seccomp Dentro de un Pod

Ejecución de verificaciones internas de capacidades usando `capsh` y `/proc/1/status`.

```bash
$ kubectl exec -it payment-processor-65b8c9d4b5-x8z2l -n production-workloads -c app -- capsh --print
```

**Salida Esperada:**

```text
Current: =
Bounding set =
Securebits: 00000004/0x4/2 (secure-keep-caps)
 secure-noroot: no (setsuid/sgid permissions ignored when uids/gids are 0)
 secure-no-suid-fixup: yes (setsuid/sgid permissions ignored when uids/gids are 0)
 secure-keep-caps: yes (set keep capabilities when uids/gids are set to 0)
 secure-no-ambient-caps: no (ambient capabilities maintained across execve)
Supplementary groups = 10001
UID: 10001(appuser)
GID: 10001(appgroup)
```

Inspección directa de los bits de estado del kernel:

```bash
$ kubectl exec -it payment-processor-65b8c9d4b5-x8z2l -n production-workloads -c app -- grep -E 'Cap|Seccomp|Speculation' /proc/1/status
```

**Salida Esperada:**

```text
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1
Speculation_Store_Bypass:	thread vulnerable
```

> **Conclusión Clave para SRE**: `CapEff: 0000000000000000` demuestra que **todas** las Linux capabilities han sido eliminadas. `Seccomp: 2` indica que el filtrado de Seccomp está activo en modo `SECCOMP_MODE_FILTER` (configurado mediante `RuntimeDefault`). `NoNewPrivs: 1` confirma `allowPrivilegeEscalation: false`.

---

### Comando 3: Inspección de Contenedores CRI y Namespaces de Linux a Nivel de Nodo

Desde una shell de depuración de nodo para SRE/Arquitecto de Plataforma, inspeccione el estado del contenedor usando `crictl` y ubique sus namespaces subyacentes de Red y PID de Linux.

```bash
$ sudo crictl ps --name app --state Running
```

**Salida Esperada:**

```text
CONTAINER           IMAGE                                                               CREATED             STATE               NAME                ATTEMPTS            POD ID              DEFAULT-NAME
a1f2b3c4d5e61       registry.enterprise.io/finance/payment-processor@sha256:d8e7f...   10 minutes ago      Running             app                 0                   7f8e9d0c1b2a        payment-processor-65b8c9d4b5-x8z2l
```

Inspeccione la configuración del security context del contenedor en la capa de runtime:

```bash
$ sudo crictl inspect a1f2b3c4d5e61 | jq '.info.runtimeSpec.linux.securityContext'
```

**Salida Esperada:**

```json
{
  "readonlyPaths": [
    "/proc/asound",
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger"
  ],
  "seccomp": {
    "profileType": "RuntimeDefault"
  },
  "maskedPaths": [
    "/proc/acpi",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/sched_debug",
    "/sys/firmware",
    "/proc/scsi"
  ]
}
```

---

## 5. Guía de Verificación y Resolución de Problemas de Diagnóstico

Al aplicar fortalecimiento (hardening) en las configuraciones de seguridad de Pods, las cargas de trabajo con frecuencia experimentan errores en tiempo de ejecución. Los SREs deben diagnosticar sistemáticamente estas fallas.

```
+-----------------------------------------------------------------------------------+
| Pod Hardening Failure Diagnostic Workflow                                         |
+-----------------------------------------------------------------------------------+
                                          |
                                 [ Deploy Pod Manifest ]
                                          |
                                          v
                         /---------------------------------\
                        /  Is Deployment Accepted by API?   \
                        \---------------------------------/
                                 /                 \
                             NO /                   \ YES
                               v                     v
              +-------------------------------+  +----------------------------------+
              | Pod Security Admission (PSA)  |  | Container Enters CrashLoopBackOff|
              | Rejection (Forbidden 403)     |  | or Error Status                  |
              +-------------------------------+  +----------------------------------+
                               |                                  |
                               v                                  v
              [ Check PSA Label Rules ]           [ Check Kubelet Container Logs ]
              - Missing drop ALL caps?            - Read-only root FS write failure?
              - Missing runAsNonRoot?             - UID/GID mount EACCES permission?
              - Missing seccompProfile?           - Denied syscall (Seccomp EPERM)?
```

---

### Escenario de Falla 1: `CrashLoopBackOff` debido a `readOnlyRootFilesystem: true`

*   **Síntoma**: El contenedor falla repetidamente de forma inmediata tras el inicio.
*   **Extracción de Logs**:

```bash
$ kubectl logs payment-processor-65b8c9d4b5-x8z2l -n production-workloads --previous
```

*   **Salida de Error**:

```text
2026-08-07T23:14:02.102Z [FATAL] main: failed to initialize logger: open /var/log/app/execution.log: read-only file system
```

*   **Causa Raíz**: El código de la aplicación intenta crear o abrir un archivo en modo escritura (`O_WRONLY | O_CREAT`) en un directorio dentro del sistema de archivos raíz del contenedor que no ha sido montado explícitamente como un volumen con escritura (`emptyDir` o `PVC`).
*   **Remediación**: Actualice el manifiesto Deployment para agregar un volumen `emptyDir` y el correspondiente `volumeMount` en `/var/log/app`. **No** deshabilite `readOnlyRootFilesystem`.

---

### Escenario de Falla 2: Permiso de Volumen Denegado (`EACCES`) para UID No-Root

*   **Síntoma**: La aplicación falla al escribir en un Persistent Volume montado.
*   **Extracción de Logs**:

```bash
$ kubectl logs payment-processor-65b8c9d4b5-x8z2l -n production-workloads
```

*   **Salida de Error**:

```text
2026-08-07T23:18:44.891Z [ERROR] storage: unable to write lockfile to /mnt/data/lock: permission denied
```

*   **Causa Raíz**: El volumen pertenece a `root:root` (UID/GID 0) en el host o en el aprovisionador de almacenamiento, pero el contenedor se ejecuta como `runAsUser: 10001`.
*   **Verificación de Diagnóstico**:

```bash
$ kubectl get pod payment-processor-65b8c9d4b5-x8z2l -n production-workloads -o jsonpath='{.spec.securityContext}'
```

*   **Remediación**: Defina `fsGroup: 10001` y `fsGroupChangePolicy: "OnRootMismatch"` en el `securityContext` a **nivel de Pod**. Esto le indica a `kubelet` que aplique `chown`/`chgrp` de forma recursiva a los contenidos del volumen al GID `10001` al montar el volumen.

---

### Escenario de Falla 3: Syscall Bloqueada por Seccomp (`Operation not permitted` / `EPERM`)

*   **Síntoma**: La aplicación entra en pánico o termina abruptamente durante operaciones específicas (por ejemplo, al ejecutar subprocesos o realizar bindings de sockets de red).
*   **Diagnóstico a Nivel de Nodo (Logs de Auditoría del Kernel)**:

```bash
$ sudo journalctl -k --since "10 minutes ago" | grep -i seccomp
```

*   **Salida del Kernel**:

```text
Aug 07 23:22:10 node-01 kernel: audit: type=1326 audit(1723072930.412:984): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84921 comm="payment-proc" exe="/app/payment-proc" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f9a12c41b8a code=0x00000000
```

*   **Causa Raíz**: La syscall `165` (`mount`) fue invocada por el código de la aplicación, lo cual está explícitamente prohibido por el perfil seccomp `RuntimeDefault`.
*   **Remediación**: Audite las dependencias de la aplicación para eliminar llamadas al sistema del host, o construya un perfil seccomp personalizado en `securityContext.seccompProfile.type: Localhost` que permita la syscall auditada de forma segura.

---

## 6. Referencias

*   [Documentación Oficial de Kubernetes: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
*   [Documentación Oficial de Kubernetes: Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
*   [Documentación Oficial de Kubernetes: Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
*   [Documentación Oficial de Kubernetes: Pods Architecture](https://kubernetes.io/docs/concepts/workloads/pods/)
*   [CNCF KCSA Exam Curriculum Guide (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)