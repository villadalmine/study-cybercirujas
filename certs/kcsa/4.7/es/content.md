# Material de estudio KCSA: Dominio 4.7 – Escalación de privilegios

**Examen**: Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio**: Workload Security  
**Tema**: 4.7 Privilege Escalation  
**Peso del dominio**: 2,29%  

---

## 1. Motivación y problema arquitectónico en producción

### 1.1 Mecánica de bajo nivel del kernel de Linux: `PR_SET_NO_NEW_PRIVS`
En la ejecución de procesos de Linux, la escalación de privilegios ocurre típicamente cuando un proceso invoca `execve()` sobre un archivo con permisos `setuid` (Set User ID) o `setgid` (Set Group ID), o cuando se adjuntan capabilities binarias a un archivo ejecutable (mediante `setcap`).

Cuando un proceso ejecuta un binario `setuid` (como `/usr/bin/sudo` o `/bin/mount`), el kernel transiciona el Effective User ID (`euid`) del proceso desde el ID de usuario sin privilegios al ID del propietario del archivo (típicamente `root`, UID `0`). 

Para evitar que aplicaciones contenedorizadas sin privilegios obtengan permisos elevados de root en el host o contenedor, el kernel de Linux 3.5 introdujo la bit flag `PR_SET_NO_NEW_PRIVS`, controlable a través de la llamada al sistema `prctl(2)`:

```c
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
```

Cuando `PR_SET_NO_NEW_PRIVS` está configurado en `1`:
- El kernel garantiza que el proceso y cualquiera de sus procesos hijos creados mediante `fork()` o `execve()` nunca puedan adquirir privilegios que no pudieran ser otorgados por el proceso emisor sin `execve()`.
- Las bit flags Setuid (`S_ISUID`) y Setgid (`S_ISGID`) en los ejecutables se ignoran explícitamente durante `execve()`.
- Las capabilities del sistema de archivos (por ejemplo, `setcap cap_net_raw+ep /usr/bin/ping`) se suprimen y no se transfieren al conjunto de capabilities efectivas (`CapEff`).
- Los Linux Security Modules (LSMs) como AppArmor o SELinux no pueden transicionar a dominios de ejecución que otorguen más permisos que el dominio padre.

En Kubernetes, la propiedad `allowPrivilegeEscalation` de `securityContext` del pod controla directamente si los runtimes de contenedores (como `containerd` a través de `runc`) invocan `prctl(PR_SET_NO_NEW_PRIVS, 1, ...)` antes de ejecutar el proceso entrypoint del contenedor.

```
+---------------------------------------------------------------------------------------+
| Container Process (UID 1000) execution of /usr/bin/sudo                               |
+---------------------------------------------------------------------------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
   allowPrivilegeEscalation: true               allowPrivilegeEscalation: false
   (PR_SET_NO_NEW_PRIVS = 0)                    (PR_SET_NO_NEW_PRIVS = 1)
                    |                                             |
     Kernel evaluates S_ISUID bit                  Kernel ignores S_ISUID bit
                    |                                             |
   euid transitions: 1000 -> 0                   euid remains: 1000
   Effective Capabilities = FULL                 Effective Capabilities = NONE
                    |                                             |
    [Root Privilege Escalation]                   [EPERM: Operation Not Permitted]
```

### 1.2 Escalación de privilegios en la API de Kubernetes: Mecanismos RBAC
La escalación de privilegios no se limita al kernel de Linux; se extiende al control-loop del Control Plane de Kubernetes a través del Control de Acceso Basado en Roles (RBAC).

En Kubernetes, la escalación de privilegios en la API ocurre cuando una identidad (ServiceAccount, User o Group) puede otorgarse a sí misma o a otra identidad permisos superiores a los que tiene asignados actualmente. Kubernetes mitiga esto mediante dos reglas de cumplimiento específicas dentro del módulo de autorización del API Server:

1. **Restricción de escalación de roles (verbo `escalate`)**:
   Un subject solo puede crear o actualizar un `Role` o `ClusterRole` si el subject ya posee *todos* los permisos contenidos en ese rol, **O** si el subject posee permiso explícito para realizar el verbo `escalate` en `roles` o `clusterroles` dentro del grupo de API `rbac.authorization.k8s.io`.

2. **Restricción de vinculación de roles (verbo `bind`)**:
   Un subject solo puede crear o actualizar un `RoleBinding` o `ClusterRoleBinding` si el subject ya posee todos los permisos presentes en el rol de destino, **O** si el subject posee permiso explícito para realizar el verbo `bind` en el `Role` o `ClusterRole` de destino.

Si un administrador desconfigura RBAC otorgando `verbs: ["*"]` o `verbs: ["create", "update"]` en `roles` o `rolebindings` sin darse cuenta de los vectores de escalación implícitos, un atacante que comprometa el token del ServiceAccount de un Pod puede escalar privilegios instantáneamente a `cluster-admin`.

---

## 2. Comparativas técnicas y tablas de compensaciones

### 2.1 Matriz de vectores de escalación de privilegios en contenedores

| Vector de escalación | Causa raíz | Primitiva principal del kernel/API | Mecanismo de explotación | Impacto / Radio de alcance | Estrategia de mitigación |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Abuso de binarios Setuid** | `allowPrivilegeEscalation: true` | `PR_SET_NO_NEW_PRIVS = 0` | Invocación de binarios con el bit `S_ISUID` (p. ej., binarios locales desconfigurados o montajes de binarios del host) | Ejecución como root dentro del namespace del contenedor | Configurar `allowPrivilegeEscalation: false` |
| **Contenedor privilegiado** | `privileged: true` | Deshabilita Namespaces de Linux, Cgroups, LSMs y descarta las máscaras CapBnd | Acceso directo a dispositivos del host (`/dev/*`), `/sys`, `/proc`, cgroups | Compromiso total del host (Container Breakout) | Perfil `Restricted` de PodSecurityAdmission |
| **Capabilities retenidas** | El conjunto de capabilities por defecto no ha sido descartado | `CapEff` contiene `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE` | Explotación de llamadas al sistema permitidas por máscaras de capabilities excesivas | Escape de namespace, manipulación directa de red (raw network), sobreescritura de archivos | Configurar `capabilities.drop: ["ALL"]` |
| **Abuso de `escalate` / `bind` en RBAC** | Definiciones de reglas de `ClusterRole` inseguras | Bypass de verificación de autorización en `rbac.authorization.k8s.io` | Creación de Roles de alto privilegio o vinculación de roles `cluster-admin` existentes a ServiceAccount controlados | Toma de control completa del Control Plane de Kubernetes | Auditoría estricta de verbos RBAC (`bind`, `escalate`, `impersonate`) |
| **Abuso de montajes HostPath** | Montaje de `/`, `/etc` o `/var/run/docker.sock` | Permisos DAC del sistema de archivos en los archivos del host | Modificación de cron jobs del host, claves SSH o emisión de comandos al socket del runtime de contenedores | Acceso completo de lectura/escritura en el host y toma de control del host | Restringir volúmenes `hostPath` mediante Admission Control |

### 2.2 Matriz de compensaciones de controles de seguridad

| Mecanismo de control | Sobrecarga de rendimiento | Fricción para el desarrollador | Eficacia de seguridad | Complejidad operativa |
| :--- | :--- | :--- | :--- | :--- |
| **`allowPrivilegeEscalation: false`** | Cero sobrecarga (una única syscall `prctl` al inicio) | Baja (solo interrumpe aplicaciones heredadas que requieren `sudo`/`ping`) | Alta (detiene la escalación de binarios setuid/setcap) | Baja (campo YAML simple) |
| **`readOnlyRootFilesystem: true`** | Cero sobrecarga | Media/Alta (requiere montajes `tmpfs` explícitos para `/tmp`) | Muy alta (evita la escritura de payloads setuid maliciosos) | Media (requiere refactorización del almacenamiento de la aplicación) |
| **Capabilities `drop: ["ALL"]`** | Cero sobrecarga | Media (requiere mapear las capabilities necesarias por workload) | Alta (reduce drásticamente la superficie de ataque del kernel) | Media (requiere descubrimiento de capabilities) |
| **PodSecurityAdmission (Restricted)** | Sobrecarga casi nula (evaluación in-tree en el API Server) | Alta (rechaza manifiestos no conformes a nivel de API) | Alta (aplica seguridad base a nivel de todo el clúster) | Baja (etiquetado a nivel de namespace) |

---

## 3. Manifiestos de producción y configuraciones de infraestructura

### 3.1 Manifiesto de Pod vulnerable (valores por defecto inseguros)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable-workload
  namespace: production-apps
  labels:
    app.kubernetes.io/name: vulnerable-workload
    app.kubernetes.io/component: API
spec:
  containers:
  - name: web-app
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "sleep 3600"]
    securityContext:
      # CRITICAL SECURITY RISK: Allows setuid/setgid binaries to escalate privileges
      allowPrivilegeEscalation: true
      # CRITICAL SECURITY RISK: Running as root UID 0 inside container
      runAsUser: 0
      # CRITICAL SECURITY RISK: Retains Linux capabilities (e.g., CAP_NET_RAW, CAP_SYS_ADMIN if set)
      capabilities:
        add:
        - NET_ADMIN
        - SYS_ADMIN
      readOnlyRootFilesystem: false
```

### 3.2 Manifiesto de Pod endurecido (grado de producción / conforme con KCSA)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-workload
  namespace: production-apps
  labels:
    app.kubernetes.io/name: hardened-workload
    app.kubernetes.io/component: api
spec:
  securityContext:
    # Enforce non-root execution at Pod level
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    # Standardize Seccomp profile to RuntimeDefault across all containers
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: web-app
    image: cgr.dev/chainguard/static:latest
    securityContext:
      # ENFORCES PR_SET_NO_NEW_PRIVS = 1 via container runtime (runc/containerd)
      allowPrivilegeEscalation: false
      # Prevent container root execution
      runAsNonRoot: true
      runAsUser: 10001
      runAsGroup: 10001
      # Prevent writing malicious executables to container filesystem
      readOnlyRootFilesystem: true
      # Drop ALL kernel capabilities
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - name: tmp-volume
      mountPath: /tmp
  volumes:
  # Provide isolated ephemeral storage for applications requiring temporary file access
  - name: tmp-volume
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

### 3.3 Aplicación de políticas a nivel de Namespace con Pod Security Admission (PSA)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-apps
  labels:
    # Enforces the Restricted Pod Security Standard profile strictly
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    # Generates warnings in API client responses for non-compliant pods
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    # Logs audit events for non-compliant pods
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
```

### 3.4 Definiciones RBAC inseguras vs. seguras

#### Role inseguro que permite la escalación de privilegios
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production-apps
  name: insecure-app-manager
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
# DANGEROUS: Allows granting any role permission to arbitrary ServiceAccounts
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["create", "update", "escalate", "bind"]
```

#### Role seguro endurecido
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production-apps
  name: secure-app-manager
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update"]
# Explicitly omitting rbac.authorization.k8s.io resources eliminates RBAC privilege escalation
```

---

## 4. Comandos CLI reales y salidas de terminal

### 4.1 Verificación de `PR_SET_NO_NEW_PRIVS` a través del sistema de archivos `/proc` del contenedor

Despliegue el pod endurecido e inspeccione el archivo `/proc/1/status` dentro del proceso del contenedor para verificar las bit flags del kernel.

```bash
$ kubectl apply -f hardened-workload.yaml
pod/hardened-workload created

$ kubectl exec -it hardened-workload -n production-apps -- cat /proc/1/status | grep -E "NoNewPrivs|Cap"
NoNewPrivs:	1
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
```

Contraste esta salida con un pod ejecutándose con `allowPrivilegeEscalation: true`:

```bash
$ kubectl exec -it vulnerable-workload -n production-apps -- cat /proc/1/status | grep -E "NoNewPrivs|Cap"
NoNewPrivs:	0
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000100
CapAmb:	0000000000000000
```

### 4.2 Pruebas de fallo en la ejecución de binarios Setuid bajo `allowPrivilegeEscalation: false`

El intento de ejecutar un binario setuid dentro de un contenedor configurado con `allowPrivilegeEscalation: false` produce un rechazo explícito de la operación por parte del kernel:

```bash
$ kubectl exec -it hardened-workload -n production-apps -- /usr/bin/sudo -u root whoami
sudo: error in /etc/sudo.conf, line 0 while loading plugin "sudoers_policy"
sudo: unable to initialize policy plugin
sudo: PERM_ROOT: setresuid(0, -1, -1): Operation not permitted
```

### 4.3 Auditoría de verbos de escalación de privilegios RBAC mediante `kubectl`

Ejecute consultas de autorización para detectar si un ServiceAccount o usuario específico puede escalar privilegios:

```bash
$ kubectl auth can-i escalate roles -n production-apps --as=system:serviceaccount:production-apps:default
no

$ kubectl auth can-i bind clusterroles --as=system:serviceaccount:production-apps:default
no

$ kubectl auth can-i create rolebindings -n production-apps --as=system:serviceaccount:production-apps:default
no
```

Consultando una cuenta con excesivos privilegios:

```bash
$ kubectl auth can-i escalate clusterroles --as=dev-admin
yes
```

### 4.4 Pruebas del cumplimiento de Pod Security Admission (PSA) a nivel de API

Al aplicar un manifiesto de pod no conforme en un namespace etiquetado con `pod-security.kubernetes.io/enforce: restricted`:

```bash
$ kubectl apply -f vulnerable-workload.yaml -n production-apps
Error from server (Forbidden): error when creating "vulnerable-workload.yaml": pods "vulnerable-workload" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "web-app" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container "web-app" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "web-app" must not set runAsUser=0), unrestricted capabilities (container "web-app" must set securityContext.capabilities.drop=["ALL"])
```

---

## 5. Guía de verificación y diagnóstico de fallos

### 5.1 Flujo de trabajo de diagnóstico para problemas de escalación de privilegios

```
+-------------------------------------------------------------------------------+
|                      Pod Deployment / Security Audit                          |
+-------------------------------------------------------------------------------+
                                       |
                                       v
               +-----------------------------------------------+
               | Does namespace enforce Restricted PSA profile? |
               +-----------------------------------------------+
                                /             \
                              YES              NO
                              /                 \
                             v                   v
      +------------------------------+   +------------------------------+
      | API Server checks PodSpec    |   | Pod Created on Worker Node   |
      | - allowPrivilegeEscalation   |   +------------------------------+
      | - runAsNonRoot               |                  |
      | - capabilities.drop: ["ALL"] |                  v
      +------------------------------+   +------------------------------+
             /                \          | Container runtime (containerd|
          PASS                FAIL       | / runc) receives OCI spec    |
           /                    \        +------------------------------+
          v                      v                      |
  +---------------+      +---------------+              v
  | Pod Accepted  |      | API Rejection |     +------------------+
  +---------------+      | (403 Forbidden|     | Reads field:     |
                         +---------------+     | allowPrivilege-  |
                                               | Escalation       |
                                               +------------------+
                                                        |
                                        +---------------+---------------+
                                        |                               |
                                      FALSE                           TRUE
                                        |                               |
                                        v                               v
                              +--------------------+          +--------------------+
                              | Executes syscall:  |          | Skips prctl flag.  |
                              | prctl(PR_SET_NO_   |          | Setuid binaries    |
                              | NEW_PRIVS, 1, ...) |          | functional.        |
                              +--------------------+          +--------------------+
                                        |                               |
                                        v                               v
                              +--------------------+          +--------------------+
                              | /proc/1/status     |          | /proc/1/status     |
                              | NoNewPrivs: 1      |          | NoNewPrivs: 0      |
                              +--------------------+          +--------------------+
```

### 5.2 Errores comunes en producción y soluciones

#### Problema 1: La aplicación falla con `EPERM` u `Operation not permitted` después de configurar `allowPrivilegeEscalation: false`
* **Causa raíz**: El ejecutable de la aplicación o un script auxiliar interno utiliza setuid/setgid o requiere capabilities específicas (por ejemplo, `CAP_NET_BIND_SERVICE` o `CAP_NET_RAW`).
* **Diagnóstico**:
  1. Inspeccione los logs del contenedor: `kubectl logs <pod-name> -n <namespace>`.
  2. Inspeccione los atributos del binario dentro del objetivo de construcción del contenedor: `ls -la /path/to/binary` (verifique la presencia de `-rwsr-xr-x`).
  3. Inspeccione los requerimientos de capabilities: `getcap /path/to/binary`.
* **Resolución**:
  - Elimine los bits setuid del binario durante la construcción de la imagen: `RUN chmod u-s,g-s /path/to/binary`.
  - Para la vinculación de puertos inferiores a 1024, utilice el sysctl `net.ipv4.ip_unprivileged_port_start=80` en lugar de `CAP_NET_BIND_SERVICE` o wrappers root setuid.
  - Otorgue capabilities mínimas específicas a través de `capabilities.add` de forma explícita manteniendo `allowPrivilegeEscalation: false` si se necesitan capabilities del sistema (no binarios setuid). Nota: bajo las reglas del kernel de Linux, agregar capabilities a archivos binarios aún requiere `allowPrivilegeEscalation: true` si se ejecuta como no-root; utilice concesiones explícitas de capabilities a nivel de proceso a través del runtime del motor de contenedores en su lugar.

#### Problema 2: Fallo de autorización RBAC durante el pipeline de despliegue automatizado
* **Causa raíz**: El ServiceAccount que ejecuta el despliegue posee permiso `create` en `RoleBindings` pero carece de `bind` en el `ClusterRole` de destino, o carece de los permisos exactos contenidos dentro del Role que intenta crear.
* **Diagnóstico**:
  1. Inspeccione los logs de auditoría de la API en busca de códigos de estado `403 Forbidden`.
  2. Ejecute `kubectl auth can-i` con suplantación `--as` coincidente con el ServiceAccount del controlador de despliegue.
* **Resolución**:
  - Otorgue explícitamente permisos `bind` o `escalate` únicamente a ServiceAccounts de gestión administrativa (por ejemplo, controladores GitOps como ArgoCD/Flux que se ejecuten en namespaces seguros). Nunca los otorgue a ServiceAccounts de workloads.

---

## 6. Referencias

* **Kubernetes Documentation – Security Context**:  
  https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
* **Kubernetes Documentation – Pod Security Standards (Restricted Profile)**:  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted
* **Kubernetes Documentation – Pod Security Admission**:  
  https://kubernetes.io/docs/concepts/security/pod-security-admission/
* **Kubernetes Documentation – RBAC Authorization (Privilege Escalation Prevention)**:  
  https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping
* **Linux Kernel Documentation – `prctl(2)` and `PR_SET_NO_NEW_PRIVS`**:  
  https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html
* **CNCF KCSA Exam Curriculum**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **NIST SP 800-190 – Application Container Security Guide**:  
  https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf