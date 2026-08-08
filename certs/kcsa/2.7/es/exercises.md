# Guía de Estudio KCSA: Dominio 2.7 - Pod Security

**Examen**: CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio**: Kubernetes Security / Workload Security  
**Tema**: 2.7 Pod  
**Ponderación**: 2.0%  
**Referencia oficial**: [CNCF KCSA Curriculum (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)  
**Documentación oficial**:
- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kubernetes Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Linux Capabilities Manual (capabilities(7))](https://man7.org/linux/man-pages/man7/capabilities.7.html)

---

## Technical Deep-Dive y Visión General de la Arquitectura

En la arquitectura de seguridad de Kubernetes, un **Pod** no es un binario en tiempo de ejecución en sí mismo, sino una abstracción sobre un grupo de contenedores Linux que comparten namespaces del kernel de Linux, cgroups y volúmenes de almacenamiento. Los límites de seguridad para los Pods dependen directamente de la configuración de los primitivos del runtime de contenedores y de las políticas de admission control a nivel de API.

```
+-----------------------------------------------------------------------------------------+
|                                    KUBERNETES NODE                                       |
|                                                                                         |
|  +-----------------------------------------------------------------------------------+  |
|  |                                  POD BOUNDARY                                     |  |
|  |  [ Pause Container ] ---> Holds shared Network, IPC, and UTS Namespaces           |  |
|  |                                                                                   |  |
|  |  +-------------------------------------+  +------------------------------------+  |  |
|  |  | App Container                       |  | Sidecar Container                  |  |  |
|  |  |  - Mount Namespace (OverlayFS)      |  |  - Mount Namespace (OverlayFS)     |  |  |
|  |  |  - PID Namespace (isolated/shared)  |  |  - PID Namespace (isolated/shared) |  |  |
|  |  |  - SecurityContext (Capabilities,   |  |  - SecurityContext                 |  |  |
|  |  |    Seccomp, UID/GID, no_new_privs)  |  |                                    |  |  |
|  +--+-------------------------------------+--+------------------------------------+--+  |
|                                                                                         |
|  Kernel Enforcement Layer:                                                              |
|  - Cgroups v2 (CPU, Memory, PIDs isolation)                                             |
|  - Seccomp BPF (Syscall filtering)                                                      |
|  - AppArmor / SELinux (Mandatory Access Control)                                        |
|  - Capability Bounding Set (Kernel Privileges Bitmask)                                  |
+-----------------------------------------------------------------------------------------+
```

### 1. Primitivos de Aislamiento del Kernel de Linux en Kubernetes

- **Namespaces**: Proporcionan aislamiento de recursos. Por defecto, los Pods comparten namespaces `net` (Network), `ipc` (Inter-Process Communication) y `uts` (Hostname) a través del contenedor infra/pause. Los namespaces `mnt` (Mount) y `pid` (Process ID) están aislados por contenedor por defecto a menos que se configure `shareProcessNamespace: true` o `hostPID: true`.
- **Linux Capabilities**: Privilegios a nivel de hilo (thread) que dividen el poder de root en unidades distintas (por ejemplo, `CAP_NET_BIND_SERVICE`, `CAP_SYS_ADMIN`). Establecer `capabilities.drop: ["ALL"]` elimina todas las 41+ capacidades del kernel del conjunto de capacidades del proceso (`CapPrm`, `CapEff`, `CapBnd`).
- **`allowPrivilegeEscalation: false`**: Invoca la llamada al sistema de Linux `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` durante la creación del contenedor. Esto evita que los binarios setuid (por ejemplo, `/usr/bin/sudo` o binarios setuid personalizados) adquieran permisos elevados a través de llamadas de ejecución `execve()`.
- **`readOnlyRootFilesystem: true`**: Monta el sistema de archivos raíz overlayfs del contenedor como solo lectura (`ro`). Modificar binarios, colocar WebShells o editar `/etc` falla con `Read-only file system (errno 30)`.
- **Seccomp (Secure Computing Mode)**: Restringe las llamadas al sistema ejecutables mediante filtros eBPF. Configurar `seccompProfile.type: RuntimeDefault` habilita perfiles del runtime de contenedores (Containerd/CRI-O) que bloquean syscalls peligrosas como `unshare`, `kexec_load`, `sys_ptrace` y `reboot`.

### 2. Pod Security Admission (PSA) y Pod Security Standards (PSS)

Pod Security Admission (PSA) nativo de Kubernetes aplica Pod Security Standards (PSS) a nivel de namespace a través de etiquetas estándar.

| Nivel | Propósito | Características Prohibidas |
| :--- | :--- | :--- |
| **Privileged** | Ejecución sin restricciones. Infraestructura operativa (CNIs, drivers de almacenamiento). | Ninguna (posible acceso completo al nodo). |
| **Baseline** | Cargas de trabajo predeterminadas sin privilegios. Previene escaladas de privilegios conocidas. | `hostNetwork`, `hostPID`, `hostIPC`, `hostPort`, `privileged: true`, capacidades peligrosas (`CAP_SYS_ADMIN`), `sysctls` personalizados, volúmenes `hostPath`. |
| **Restricted** | Cargas de trabajo endurecidas siguiendo las mejores prácticas. Aplica el principio de menor privilegio. | Requiere `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile` definido (`RuntimeDefault`/`Localhost`), restringe los tipos de volúmenes a config/secret/emptyDir estándar. |

PSA evalúa los Pods utilizando tres **modos** operativos:
1. `enforce`: Rechaza inmediatamente la creación en la API de Pods que no cumplan la normativa.
2. `audit`: Permite la creación pero registra las violaciones en el audit log de la API de Kubernetes.
3. `warn`: Permite la creación pero devuelve encabezados de advertencia orientados al usuario a `kubectl` o clientes.

---

## Instrucciones para la Configuración del Laboratorio

Ejecutá todos los comandos en un cluster de Kubernetes v1.26+ en ejecución (por ejemplo, `kind`, `minikube` o un control plane en la nube).

```bash
# Verify cluster connection and node readiness
kubectl get nodes -o wide
```

Salida esperada:
```text
NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
kind-control-plane   Ready    control-plane   5m    v1.30.0   172.18.0.2    <none>        Ubuntu 22.04.4 LTS   5.15.0-101-generic   containerd://1.7.15
```

---

## Ejercicio Guiado 1: Endurecimiento de la Arquitectura de SecurityContext del Pod

En este ejercicio, construirás un manifiesto de Pod totalmente conforme con el Pod Security Standard **Restricted**, lo aplicarás al cluster e inspeccionarás los parámetros del kernel del contenedor desde el interior del contexto de ejecución.

### Paso 1.1: Crear el Manifiesto del Pod Endurecido

Creá un manifiesto llamado `hardened-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  namespace: default
  labels:
    app.kubernetes.io/name: secure-workload
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: web-app
    image: cimg/base:2024.01
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
        add:
        - NET_BIND_SERVICE
    volumeMounts:
    - name: tmp-dir
      mountPath: /tmp
  volumes:
  - name: tmp-dir
    emptyDir: {}
```

### Paso 1.2: Aplicar y Verificar el Contexto de Ejecución

Desplegá el manifiesto e inspeccioná los parámetros de ejecución del contenedor.

```bash
# Apply the manifest
kubectl apply -f hardened-pod.yaml

# Wait for Pod to enter Running state
kubectl wait --for=condition=Ready pod/secure-workload --timeout=30s
```

Salida esperada:
```text
pod/secure-workload created
pod/secure-workload condition met
```

### Paso 1.3: Inspeccionar las Máscaras de Bits de Privilegios del Kernel y las Restricciones del Sistema de Archivos

Ejecutá comandos de diagnóstico dentro del contenedor para verificar el UID, los conjuntos de delimitación de capacidades (capability bounding sets) y las protecciones de escritura del sistema de archivos raíz.

```bash
# Verify execution identity (UID/GID)
kubectl exec -it secure-workload -- id

# Test write protection on root filesystem
kubectl exec -it secure-workload -- touch /etc/test-write

# Test write permissions on explicit emptyDir mount
kubectl exec -it secure-workload -- touch /tmp/test-write

# Inspect process capabilities bitmask in /proc/1/status
kubectl exec -it secure-workload -- grep -E 'Cap(Inh|Prm|Eff|Bnd)' /proc/1/status
```

Salida esperada:
```text
uid=10001 gid=10001 groups=10001
touch: cannot touch '/etc/test-write': Read-only file system
CapInh: 0000000000000000
CapPrm: 0000000000000400
CapEff: 0000000000000400
CapBnd: 0000000000000400
```

> **Detalle del Kernel**: `0000000000000400` representa la máscara de bits en hexadecimal para `CAP_NET_BIND_SERVICE` (bit 10). Todas las demás capacidades de Linux (`CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE`, etc.) se han eliminado por completo.

---

### Preguntas (Bloque 1)

1. ¿Por qué se debe montar explícitamente un volumen `emptyDir` en `/tmp` en `hardened-pod.yaml` cuando está configurado `readOnlyRootFilesystem: true`?
2. ¿Qué llamada específica al kernel se realiza al configurar `allowPrivilegeEscalation: false`, y qué vector de seguridad previene?

---

## Ejercicio Guiado 2: Aplicación de Pod Security Admission (PSA) a Nivel de Namespace

En este ejercicio, configurarás los estándares de Pod Security Admission utilizando etiquetado de namespaces, evaluarás cómo PSA aplica el cumplimiento y analizarás los mensajes de rechazo del API server.

### Paso 2.1: Preparar Namespaces con Etiquetas PSS

Creá dos namespaces separados: uno configurado con los modos `warn` y `audit`, y otro con el modo estricto `enforce`.

```bash
# Create namespaces
kubectl create namespace psa-warn-lab
kubectl create namespace psa-enforce-lab

# Label psa-warn-lab to trigger warnings and audit records for non-restricted Pods
kubectl label --overwrite namespace psa-warn-lab \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest

# Label psa-enforce-lab to hard-reject non-restricted Pods
kubectl label --overwrite namespace psa-enforce-lab \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Verificá las etiquetas aplicadas:

```bash
kubectl get ns --show-labels | grep psa-
```

Salida esperada:
```text
psa-enforce-lab   Active   20s   kubernetes.io/metadata.name=psa-enforce-lab,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/enforce-version=latest
psa-warn-lab      Active   25s   kubernetes.io/metadata.name=psa-warn-lab,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/audit-version=latest,pod-security.kubernetes.io/warn=restricted,pod-security.kubernetes.io/warn-version=latest
```

### Paso 2.2: Probar el Envío de Cargas de Trabajo contra el Modo Warn de PSA

Creá un manifiesto de carga de trabajo no conforme llamado `unsecure-deployment.yaml`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-nginx
  namespace: psa-warn-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-nginx
  template:
    metadata:
      labels:
        app: legacy-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
```

Desplegá en el namespace `psa-warn-lab` y monitoreá la salida de la terminal:

```bash
kubectl apply -f unsecure-deployment.yaml
```

Salida esperada:
```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), uncontrolled capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/legacy-nginx created
```

Observá que el Deployment fue **creado**, pero el API server emitió una respuesta de advertencia detallada especificando cada fallo de regla bajo el estándar `restricted`.

### Paso 2.3: Probar el Envío de Cargas de Trabajo contra el Modo Enforce de PSA

Ahora intentá crear el recurso Pod idéntico no conforme directamente en el namespace `psa-enforce-lab`.

```bash
# Attempt direct Pod creation in enforcement namespace
kubectl run test-unsecure --image=nginx:1.25 -n psa-enforce-lab
```

Salida esperada:
```text
Error from server (Forbidden): pods "test-unsecure" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), uncontrolled capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### Paso 2.4: Analizar el Comportamiento del Controlador (Deployments vs Pods Directos)

Ahora intentá desplegar el manifiesto `unsecure-deployment.yaml` dentro de `psa-enforce-lab`.

```bash
# Modify namespace target to psa-enforce-lab and apply
sed 's/namespace: psa-warn-lab/namespace: psa-enforce-lab/' unsecure-deployment.yaml | kubectl apply -f -

# Inspect the Deployment status
kubectl get deployment legacy-nginx -n psa-enforce-lab

# Inspect the ReplicaSet events
kubectl get rs -n psa-enforce-lab
kubectl describe rs -n psa-enforce-lab
```

Salida esperada para `kubectl get rs -n psa-enforce-lab`:
```text
NAME                            DESIRED   CURRENT   READY   AGE
legacy-nginx-7854ff8877         1         0         0       12s
```

Fragmento de salida esperada para `kubectl describe rs -n psa-enforce-lab`:
```text
Events:
  Type     Reason        Age        From                   Message
  ----     ------        ----       ----                   -------
  Warning  FailedCreate  4s (x4 over 12s)  replicaset-controller  (combined from similar events): Failed create pod pod-template-7854ff8877-xxxxx: pods "legacy-nginx-7854ff8877-xxxxx" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
```

---

### Preguntas (Bloque 2)

3. ¿Por qué `kubectl apply -f unsecure-deployment.yaml` devolvió `deployment.apps/legacy-nginx created` con éxito en `psa-enforce-lab`, pero nunca se ejecutó ningún Pod? ¿En qué lugar del flujo de trabajo del control plane de Kubernetes ocurrió el fallo de aplicación de políticas?
4. ¿En qué se diferencia configurar `pod-security.kubernetes.io/enforce-version: v1.28` de configurar `pod-security.kubernetes.io/enforce-version: latest`? ¿Qué riesgo operacional en producción introduce `latest` durante las actualizaciones del cluster?

---

## Ejercicio Guiado 3: Diagnóstico de Bajo Nivel del Nodo e Inspección del Contenedor en Tiempo de Ejecución

En este ejercicio, inspeccionarás los primitivos de aislamiento de contenedores de bajo nivel directamente en el nodo worker utilizando `crictl`, introspección del sistema de archivos `/proc` y verificaciones de límites de seguridad con `sysctl`.

### Paso 3.1: Localizar el Container ID en el Nodo Worker

Identificá el ID del contenedor en tiempo de ejecución del Pod `secure-workload` creado en el Ejercicio 1.

```bash
# Obtain Pod container ID via JSONPath
POD_CID=$(kubectl get pod secure-workload -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
echo "Container Runtime ID: ${POD_CID}"
```

Salida esperada:
```text
Container Runtime ID: 7f8a9b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a
```

### Paso 3.2: Inspeccionar la Configuración de Seccomp y Namespaces a Nivel de Nodo mediante `crictl`

Si estás utilizando `kind`, abrí una shell dentro del nodo control-plane/worker:

```bash
# SSH / Exec into the node (kind example)
docker exec -it kind-control-plane bash

# Inside the node: Inspect container runtime status using crictl
crictl inspect <CONTAINER_ID> | grep -A 15 "security_context"
```

Fragmento de salida esperada:
```json
        "security_context": {
          "privileged": false,
          "readonly_rootfs": true,
          "capabilities": {
            "add": [
              "CAP_NET_BIND_SERVICE"
            ]
          },
          "seccomp": {
            "profile_type": "RuntimeDefault"
          },
          "run_as_user": {
            "value": 10001
          },
          "run_as_group": {
            "value": 10001
          }
        }
```

### Paso 3.3: Verificar el Modo Seccomp del Proceso en el Kernel del Host

Encontrá el Host PID (HPID) de la carga de trabajo y revisá `/proc/<HPID>/status`.

```bash
# Inside the node: Find Host PID of the process sleeping in the container
HPID=$(crictl inspect <CONTAINER_ID> | grep '"pid":' | head -n 1 | awk '{print $2}' | tr -d ',')
echo "Host PID: ${HPID}"

# Check Seccomp mode in kernel process table
grep -E 'Seccomp|NoNewPrivs' /proc/${HPID}/status
```

Salida esperada:
```text
NoNewPrivs:     1
Seccomp:        2
Seccomp_filters:        1
```

> **Nota Técnica del Kernel**: 
> - `NoNewPrivs: 1` confirma que `prctl(PR_SET_NO_NEW_PRIVS)` está activo.
> - `Seccomp: 2` indica que `SECCOMP_MODE_FILTER` está habilitado (llamadas al sistema restringidas mediante filtro BPF). El modo `0` significa deshabilitado, el modo `1` significa estricto.

---

### Preguntas (Bloque 3)

5. Si un proceso de un contenedor intenta invocar una llamada al sistema prohibida (por ejemplo, `unshare` o `kexec_load`) bajo `Seccomp: 2` con `RuntimeDefault`, ¿qué señal o acción del kernel se entrega al proceso por defecto?
6. En un escenario de nodo multitenant (multi-inquilino), ¿qué vulnerabilidad de seguridad surge si un manifiesto de Pod establece `hostIPC: true` o `hostPID: true`, y cómo previene esto el perfil `baseline` de Pod Security Standard?

---

<details>
<summary><strong>Hacé clic para desplegar la Clave de Soluciones y Respuestas Técnicas Exhaustivas</strong></summary>

### Clave de Respuestas del Ejercicio 1

#### 1. ¿Por qué se debe montar explícitamente un volumen `emptyDir` en `/tmp` en `hardened-pod.yaml` cuando está configurado `readOnlyRootFilesystem: true`?
* **Explicación**: Cuando se establece `readOnlyRootFilesystem: true` en el `securityContext` del contenedor, el runtime de contenedores monta el overlayfs raíz como solo lectura (`ro`). Las aplicaciones, las librerías en tiempo de ejecución y las utilidades estándar de Linux frecuentemente requieren escribir archivos temporales, archivos de bloqueo (lockfiles) o archivos de socket en ubicaciones predeterminadas como `/tmp`, `/var/tmp` o `/run`. Si estos directorios son de solo lectura, los procesos de las aplicaciones fallan inmediatamente con `Errno 30 (Read-only file system)`.
* Montar un volumen `emptyDir` sobre `/tmp` crea un volumen escribible dedicado y efímero (respaldado por el disco del nodo o RAM si se especifica `medium: Memory`) anclado específicamente en `/tmp`. Esto mantiene la inmutabilidad de los binarios de la imagen del contenedor y los archivos del sistema, al tiempo que proporciona un espacio aislado en memoria/disco para las escrituras temporales legítimas de la aplicación.

#### 2. ¿Qué llamada específica al kernel se realiza al configurar `allowPrivilegeEscalation: false`, y qué vector de seguridad previene?
* **Explicación**: Configurar `allowPrivilegeEscalation: false` le indica al runtime de contenedores que emita la llamada al sistema de Linux `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` antes de ejecutar el proceso del punto de entrada (entrypoint) del contenedor.
* **Vector de Seguridad Mitigado**: Evita que los bits de binarios set-user-ID (SUID) y set-group-ID (SGID) y las capacidades de archivos otorguen privilegios elevados a través de llamadas al sistema `execve()`. Si un atacante obtiene ejecución de shell o aprovecha una vulnerabilidad local dentro del contenedor, no puede explotar binarios con el bit de atributo `s` (como `/usr/bin/sudo`, `/bin/mount` o binarios SUID personalizados) para elevar los privilegios de ejecución a `root` (UID 0).

---

### Clave de Respuestas del Ejercicio 2

#### 3. ¿Por qué `kubectl apply -f unsecure-deployment.yaml` devolvió `deployment.apps/legacy-nginx created` con éxito en `psa-enforce-lab`, pero nunca se ejecutó ningún Pod? ¿En qué lugar del flujo de trabajo del control plane de Kubernetes ocurrió el fallo de aplicación de políticas?
* **Explicación**: En Kubernetes, un `Deployment` es un recurso de alto nivel administrado de forma asíncrona por el `deployment-controller` dentro de `kube-controller-manager`. 
* Cuando enviás un manifiesto de Deployment, el `kube-apiserver` valida el objeto Deployment en sí. Pod Security Admission (PSA) valida especificaciones de **Pod**, no especificaciones de Deployment directamente. Por lo tanto, el API server acepta y persiste el objeto Deployment en `etcd`.
* Posteriormente, el `deployment-controller` crea un `ReplicaSet`. El `replicaset-controller` luego intenta crear instancias individuales de `Pod`. Cuando el ReplicaSet envía la solicitud de creación del `Pod` hijo al API server, el webhook de admisión `PodSecurity` del API server intercepta la solicitud de creación del Pod. Debido a que `psa-enforce-lab` tiene `pod-security.kubernetes.io/enforce=restricted`, el plugin de admisión evalúa la especificación del Pod, detecta violaciones de políticas (`runAsNonRoot`, `allowPrivilegeEscalation`, `capabilities`, `seccompProfile`) y **rechaza** la solicitud de creación del Pod con un error de API `403 Forbidden`.
* El fallo se registra como un evento `FailedCreate` en el objeto `ReplicaSet`.

#### 4. ¿En qué se diferencia configurar `pod-security.kubernetes.io/enforce-version: v1.28` de configurar `pod-security.kubernetes.io/enforce-version: latest`? ¿Qué riesgo operacional en producción introduce `latest` durante las actualizaciones del cluster?
* **Explicación**: 
  - Especificar una versión fija (por ejemplo, `v1.28`) bloquea las reglas de evaluación de Pod Security Standards a las definiciones de políticas compiladas en Kubernetes versión 1.28.
  - Especificar `latest` le indica al controlador de Pod Security Admission que evalúe los Pods según las reglas de PSS más recientes soportadas por el `kube-apiserver` en ejecución actual.
* **Riesgo Operacional en Producción**: A medida que Kubernetes evoluciona, se pueden agregar nuevos controles de seguridad, comprobaciones o reglas más estrictas a los perfiles `baseline` o `restricted` de PSS en versiones menores más recientes de Kubernetes. Si un namespace está fijado a `latest`, actualizar el control plane (por ejemplo, de `v1.28` a `v1.30`) puede causar repentinamente que cargas de trabajo de Pods previamente conformes existentes o nuevos despliegues de Deployment fallen en el control de admisión si una comprobación de política recién introducida invalida la configuración actual de su manifiesto. Las versiones fijadas garantizan una admisión de cargas de trabajo determinista a lo largo de las actualizaciones de versión del cluster.

---

### Clave de Respuestas del Ejercicio 3

#### 5. Si un proceso de un contenedor intenta invocar una llamada al sistema prohibida (por ejemplo, `unshare` o `kexec_load`) bajo `Seccomp: 2` con `RuntimeDefault`, ¿qué señal o acción del kernel se entrega al proceso por defecto?
* **Explicación**: Cuando el filtrado de Seccomp está activo en modo 2 (`SECCOMP_MODE_FILTER`), el kernel de Linux evalúa cada syscall realizada por el hilo contra el programa de filtro BPF cargado.
* Para las llamadas al sistema bloqueadas por el perfil `RuntimeDefault`, la regla de acción seccomp por defecto devuelve `-EPERM` (Operación no permitida, `errno 1` o `errno 13`) o dispara una señal `SIGSYS` (Llamada al sistema errónea) al hilo del proceso.
* La mayoría de los runtimes de contenedores configuran la acción por defecto `SECCOMP_RET_ERRNO` (devolviendo `-EPERM`). El proceso que intenta la syscall prohibida recibe un error de permiso inmediato sin que la llamada al sistema llegue al subsistema del kernel del host subyacente, neutralizando exploits de escalada de privilegios del kernel y de escape del contenedor.

#### 6. En un escenario de nodo multitenant (multi-inquilino), ¿qué vulnerabilidad de seguridad surge si un manifiesto de Pod establece `hostIPC: true` o `hostPID: true`, y cómo previene esto el perfil `baseline` de Pod Security Standard?
* **Explicación**:
  - `hostPID: true` hace que el proceso del contenedor comparta el namespace principal de Process ID del nodo host. Un usuario dentro del contenedor puede ver todos los procesos ejecutándose en el nodo host (incluyendo procesos daemon del host como `kubelet`, `containerd` y procesos de otros Pods ejecutándose en el mismo nodo). Pueden enviar señales (`SIGKILL`, `SIGTERM`), inspeccionar la memoria a través de `/proc/<PID>/mem` o adjuntar depuradores (`ptrace`) a procesos a nivel del host.
  - `hostIPC: true` comparte el namespace de Inter-Process Communication del host. Esto permite que el proceso del contenedor acceda a mecanismos de IPC System V y segmentos de memoria compartida POSIX (`/dev/shm`) utilizados por los procesos del host u otros Pods ubicados en el mismo nodo, exponiendo datos de memoria compartida a accesos o manipulaciones no autorizados.
* **Prevención en PSS Baseline**: El Pod Security Standard `baseline` prohíbe explícitamente los campos `spec.hostPID: true` y `spec.hostIPC: true`. Cuando la aplicación de `baseline` está activa, el plugin de admisión de PSA intercepta cualquier especificación de Pod que solicite `hostPID` o `hostIPC` y rechaza la creación inmediatamente en el límite del API server.

</details>