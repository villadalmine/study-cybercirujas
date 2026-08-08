# Dominio KCSA 4.7: Privilege Escalation

## Documentación Oficial de Referencia
* [Kubernetes Security Context Documentation](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
* [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* [Kubernetes RBAC Privilege Escalation Prevention](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping)
* [Linux Kernel prctl(2) Documentation - PR_SET_NO_NEW_PRIVS](https://man7.org/linux/man-pages/man2/prctl.2.html)
* [Linux Capabilities Manual - capabilities(7)](https://man7.org/linux/man-pages/man7/capabilities.7.html)

---

## Análisis Arquitectónico Profundo y Mecánica Interna

La privilege escalation en Kubernetes ocurre en dos vectores principales: **Nivel de Nodo/Contenedor** (Mecánica de procesos del Kernel) y **Nivel de Control Plane** (API de Kubernetes y autorización RBAC).

```
                      +-------------------------------------------------------+
                      |               KUBERNETES API LAYER                    |
                      |                                                       |
                      |   [ User / SA ] --(Creates Pod/Binds Role)--> API     |
                      |                         |                             |
                      |              RBAC Admission Validation                |
                      |      Checks: 'bind', 'escalate', 'impersonate'        |
                      +-------------------------+-----------------------------+
                                                |
                                                v
                      +-------------------------------------------------------+
                      |            NODE / CONTAINER RUNTIME LAYER             |
                      |                                                       |
                      |               Kubelet -> OCI Runtime                  |
                      |                         |                             |
                      |              Translate SecurityContext                |
                      |                         |                             |
                      |                         v                             |
                      |           Linux Kernel Process Creation               |
                      |      +-----------------------------------------+      |
                      |      |  PR_SET_NO_NEW_PRIVS  (prctl)           |      |
                      |      |  Linux Capabilities   (CapEff/CapBnd)   |      |
                      |      |  Namespaces & Mounts  (hostPath/PID)    |      |
                      |      +-----------------------------------------+      |
                      +-------------------------------------------------------+
```

### 1. Mecánica de Privilege Escalation a Nivel de Nodo y Kernel
* **Setuid/Setgid y `PR_SET_NO_NEW_PRIVS`**: Cuando un proceso ejecuta un binario con el bit Set-User-ID (`SUID`) configurado (por ejemplo, `/usr/bin/passwd` o `/bin/su`), el kernel normalmente eleva el user ID efectivo del proceso (`eUID`) al ID del propietario del binario (típicamente `root`).
  * En Kubernetes, configurar `securityContext.allowPrivilegeEscalation: false` fuerza al runtime del contenedor (`containerd` o `CRI-O`) a emitir la llamada al sistema `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` antes de invocar `execve()` para el entrypoint del contenedor.
  * Una vez que `PR_SET_NO_NEW_PRIVS` se establece en `1`, es heredado por todos los procesos hijos y **no se puede borrar** (ni siquiera por `root`). Garantiza que `execve()` nunca otorgará privilegios que no le hayan sido otorgados ya al proceso que realiza la llamada, dejando ineficaces los bits `SUID`/`SGID` y los bits de file capability.

* **Linux Capabilities (`CapEff`, `CapBnd`, `CapInh`)**:
  * Los contenedores se ejecutan con un subconjunto de Linux capabilities. Agregar capabilities como `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, `CAP_NET_ADMIN`, o `CAP_DAC_OVERRIDE` elude las comprobaciones de DAC (Discretionary Access Control).
  * Si se establece `privileged: true`, el runtime del contenedor deshabilita los perfiles de seguridad (AppArmor, Seccomp), expone todos los nodos `/sys` y `/dev` del host, y otorga todas las capabilities en el bounding set del kernel de Linux (`CapBnd`).

* **Exposición de Host Namespace y Volúmenes**:
  * `hostPID: true`, `hostIPC: true`, `hostNetwork: true`, o montajes `hostPath` con permiso de escritura permiten a los procesos dentro de un contenedor escapar del aislamiento de namespace e interactuar directamente con los procesos del host o el filesystem del host (por ejemplo, modificando `/etc/shadow`, `/etc/kubernetes/manifests`, o inyectando código en la memoria de procesos del host a través de `ptrace`).

### 2. Mecánica de Privilege Escalation a Nivel de Control Plane y RBAC
* **Escalada por Role Binding**: Una identidad no puede crear ni actualizar un `Role` o `ClusterRole` con permisos que no posea previamente a menos que mantenga explícitamente el verbo `escalate` sobre `roles` o `clusterroles` en el grupo de API `rbac.authorization.k8s.io`.
* **Verbo Binding**: Para vincular un `ClusterRole` existente a un subject, la identidad debe poseer el verbo `bind` en el role/clusterrole objetivo o poseer reglas de permisos idénticas.
* **Escalada basada en Workloads**: Un usuario que tiene permisos de `create` en `pods`, `deployments`, o `daemonsets` dentro de un namespace puede crear un workload que monte un token de `ServiceAccount` de alto privilegio (o especificar `hostPath`/`privileged: true`), heredando efectivamente los derechos de `cluster-admin` o el acceso root del nodo.

---

## Ejercicios Guiados Prácticos

### Ejercicio 1: Mecánica Kernel de `allowPrivilegeEscalation` y Binarios SUID

En este ejercicio, desplegarás pods para analizar cómo el kernel de Linux maneja la ejecución de binarios SUID bajo diferentes configuraciones de `securityContext`.

#### Paso 1: Desplegar un Pod con `allowPrivilegeEscalation: true`
Crea un manifiesto llamado `pod-escalation-enabled.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: escalation-enabled-demo
  namespace: default
spec:
  containers:
  - name: security-test
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: true
      runAsUser: 1000
      runAsGroup: 1000
```

Aplica el manifiesto e inspecciona las flags de proceso del kernel:

```bash
kubectl apply -f pod-escalation-enabled.yaml
```

*Salida Esperada:*
```text
pod/escalation-enabled-demo created
```

Espera a que el pod esté en ejecución, luego inspecciona `/proc/1/status` dentro del contenedor:

```bash
kubectl exec escalation-enabled-demo -- grep -i nonewprivs /proc/1/status
```

*Salida Esperada:*
```text
NoNewPrivs:	0
```

Ahora ejecuta un binario SUID instalado dentro de la imagen (`/usr/bin/passwd` o `/bin/su`):

```bash
kubectl exec escalation-enabled-demo -- ls -l /usr/bin/passwd
```

*Salida Esperada:*
```text
-rwsr-xr-x 1 root root 63968 Feb  7  2023 /usr/bin/passwd
```

#### Paso 2: Desplegar un Pod con `allowPrivilegeEscalation: false`
Crea un manifiesto llamado `pod-escalation-disabled.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: escalation-disabled-demo
  namespace: default
spec:
  containers:
  - name: security-test
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsUser: 1000
      runAsGroup: 1000
```

Aplica el manifiesto:

```bash
kubectl apply -f pod-escalation-disabled.yaml
```

*Salida Esperada:*
```text
pod/escalation-disabled-demo created
```

Comprueba el estado del proceso para `NoNewPrivs`:

```bash
kubectl exec escalation-disabled-demo -- grep -i nonewprivs /proc/1/status
```

*Salida Esperada:*
```text
NoNewPrivs:	1
```

Prueba a ejecutar un binario SUID como usuario sin privilegios (UID 1000) cuando `NoNewPrivs` está activo:

```bash
kubectl exec escalation-disabled-demo -- su -
```

*Salida Esperada:*
```text
su: Authentication failure
(or su: System error / Permission denied)
```

#### Preguntas de Comprensión - Ejercicio 1
1. **Pregunta 1.1**: ¿Qué llamada al sistema específica del kernel de Linux invoca el runtime del contenedor cuando se configura `allowPrivilegeEscalation: false` en el manifiesto del pod?
2. **Pregunta 1.2**: Si un contenedor se ejecuta con `runAsUser: 0` (root), ¿qué impacto funcional tiene configurar `allowPrivilegeEscalation: false` sobre las capabilities otorgadas en la ejecución?

---

### Ejercicio 2: Node Breakout a través de Capabilities y Montajes del Host

En este ejercicio, simularás un escenario de privilege escalation de alta severidad donde el exceso de Linux capabilities combinado con el acceso a volúmenes del host permiten el escape del contenedor, y luego lo mitigarás usando Pod Security Standards.

#### Paso 1: Desplegar un Pod Maliciosamente Sobre-Privilegiado
Crea un manifiesto llamado `vulnerable-host-access.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: host-breakout-demo
  namespace: default
spec:
  hostPID: true
  containers:
  - name: attacker-container
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      privileged: false
      capabilities:
        add:
        - SYS_ADMIN
    volumeMounts:
    - name: host-root
      mountPath: /host
  volumes:
  - name: host-root
    hostPath:
      path: /
      type: Directory
```

Aplica el manifiesto:

```bash
kubectl apply -f vulnerable-host-access.yaml
```

*Salida Esperada:*
```text
pod/host-breakout-demo created
```

Inspecciona las capabilities efectivas del PID 1 dentro del contenedor:

```bash
kubectl exec host-breakout-demo -- grep CapEff /proc/1/status
```

*Salida Esperada:*
```text
CapEff:	0000000000200000
```
*(Nota: El bit 21 correspondiente a `CAP_SYS_ADMIN` está habilitado en la máscara de bits).*

Ejecuta un escape chroot al filesystem root del sistema host:

```bash
kubectl exec -it host-breakout-demo -- chroot /host /bin/bash -c "hostname; cat /etc/os-release | grep PRETTY_NAME"
```

*Salida Esperada:*
```text
<node-hostname>
PRETTY_NAME="Ubuntu 22.04.3 LTS" (or host OS equivalent)
```

#### Paso 2: Aplicar Seguridad a Nivel de Namespace con Pod Security Standards (PSS)
Etiqueta el namespace `default` para aplicar el perfil `restricted` de Pod Security Standard:

```bash
kubectl label --overwrite namespace default pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
```

*Salida Esperada:*
```text
namespace/default labeled
```

Intenta volver a aplicar el workload sobre-privilegiado:

```bash
kubectl delete pod host-breakout-demo --now
kubectl apply -f vulnerable-host-access.yaml
```

*Salida Esperada:*
```text
Error from server (Forbidden): error when creating "vulnerable-host-access.yaml": pods "host-breakout-demo" is forbidden: violates PodSecurity "restricted:latest": host namespaces (hostPID=true), allowPrivilegeEscalation != false (container "attacker-container" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "attacker-container" must set securityContext.capabilities.drop=["ALL"]; container "attacker-container" adds restricted capability "SYS_ADMIN"), hostPath volumes (volume "host-root")
```

#### Paso 3: Desplegar un Pod Hardened Totalmente Conforme
Crea un manifiesto llamado `hardened-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-workload
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: secure-app
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
```

Aplica el manifiesto conforme:

```bash
kubectl apply -f hardened-pod.yaml
```

*Salida Esperada:*
```text
pod/hardened-workload created
```

Verifica que las capabilities efectivas se hayan borrado por completo (`0x0`):

```bash
kubectl exec hardened-workload -- grep CapEff /proc/1/status
```

*Salida Esperada:*
```text
CapEff:	0000000000000000
```

#### Preguntas de Comprensión - Ejercicio 2
1. **Pregunta 2.1**: ¿Por qué se considera que `CAP_SYS_ADMIN` es equivalente al acceso `root` completo del host cuando se combina con montajes de volúmenes de contenedor o capabilities unshare?
2. **Pregunta 2.2**: En Pod Security Standards (PSS), ¿cuáles son las diferencias clave entre el perfil `Baseline` y el perfil `Restricted` con respecto a `allowPrivilegeEscalation` y las Linux capabilities?

---

### Ejercicio 3: Prevención de Privilege Escalation en RBAC del Control Plane

En este ejercicio, investigarás cómo el API server previene la privilege escalation en RBAC cuando un usuario intenta otorgar permisos más allá de su alcance de autorización asignado.

#### Paso 1: Crear un Role de Usuario Restringido y ServiceAccount
Crea un manifiesto llamado `rbac-escalation-setup.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: junior-dev-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader-role
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles"]
  verbs: ["create", "update", "get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: junior-dev-binding
  namespace: default
subjects:
- kind: ServiceAccount
  name: junior-dev-sa
  namespace: default
roleRef:
  kind: Role
  name: pod-reader-role
  apiGroup: rbac.authorization.k8s.io
```

Aplica el manifiesto de configuración:

```bash
kubectl apply -f rbac-escalation-setup.yaml
```

*Salida Esperada:*
```text
serviceaccount/junior-dev-sa created
role.rbac.authorization.k8s.io/pod-reader-role created
rolebinding.rbac.authorization.k8s.io/junior-dev-binding created
```

#### Paso 2: Probar Privilege Escalation mediante la Creación de Role (Impersonation)
Intenta crear un role de admin mientras suplantas la identidad (`impersonate`) de `junior-dev-sa` sin poseer el verbo `escalate`:

```bash
kubectl apply --as=system:serviceaccount:default:junior-dev-sa -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: unauthorized-admin-role
  namespace: default
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
EOF
```

*Salida Esperada:*
```text
Error from server (Forbidden): roles.rbac.authorization.k8s.io "unauthorized-admin-role" is forbidden: user "system:serviceaccount:default:junior-dev-sa" cannot create resource "roles" in API group "rbac.authorization.k8s.io" in the namespace "default": covers has #2 elements outside the permission boundary
```

#### Paso 3: Probar Privilege Escalation mediante RoleBinding
Intenta vincular un `ClusterRole` de alto privilegio existente (como `admin` o `cluster-admin`) a `junior-dev-sa` mientras suplantas la identidad de `junior-dev-sa`:

```bash
kubectl apply --as=system:serviceaccount:default:junior-dev-sa -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: escalate-to-admin
  namespace: default
subjects:
- kind: ServiceAccount
  name: junior-dev-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
EOF
```

*Salida Esperada:*
```text
Error from server (Forbidden): rolebindings.rbac.authorization.k8s.io "escalate-to-admin" is forbidden: user "system:serviceaccount:default:junior-dev-sa" cannot bind clusterrole "admin" in the namespace "default"
```

#### Paso 4: Validar Reglas de Autorización con `kubectl auth can-i`
Verifica si `junior-dev-sa` puede realizar los verbos `escalate` o `bind`:

```bash
kubectl auth can-i escalate roles --as=system:serviceaccount:default:junior-dev-sa -n default
```

*Salida Esperada:*
```text
no
```

```bash
kubectl auth can-i bind clusterroles/admin --as=system:serviceaccount:default:junior-dev-sa -n default
```

*Salida Esperada:*
```text
no
```

#### Preguntas de Comprensión - Ejercicio 3
1. **Pregunta 3.1**: ¿Qué condiciones específicas deben cumplirse en RBAC para que un usuario actualice o cree un `Role` que contenga permisos que el usuario no posee actualmente?
2. **Pregunta 3.2**: Si un usuario tiene permisos de `create` en `pods` y `serviceaccounts/token` en un namespace, ¿cómo puede lograr una privilege escalation indirecta incluso si RBAC le impide crear `RoleBindings` directamente?

---

## Referencia Rápida de Comandos de Diagnóstico

| Tarea | Comando de Diagnóstico | Indicador de Salida Esperada |
| :--- | :--- | :--- |
| Verificar `NoNewPrivs` del Kernel | `kubectl exec <pod> -- grep -i nonewprivs /proc/1/status` | `NoNewPrivs: 1` (Seguro) \| `0` (Inseguro) |
| Verificar Effective Capabilities | `kubectl exec <pod> -- grep CapEff /proc/1/status` | `CapEff: 0000000000000000` (Dropped All) |
| Verificar Derechos del Verbo `escalate` | `kubectl auth can-i escalate roles -n <namespace>` | `yes` o `no` |
| Verificar Derechos del Verbo `bind` | `kubectl auth can-i bind clusterrole/<name>` | `yes` o `no` |
| Decodificar Hexadecimal de CapEff | `capsh --decode=<CapEff_Hex_Value>` | Lista de nombres de capabilities (ej., `cap_sys_admin`) |

---

<details>
<summary><b>Haz clic aquí para desplegar la Clave de Respuestas y Explicaciones Detalladas</b></summary>

### Clave de Respuestas del Ejercicio 1

* **Respuesta 1.1**:
  El runtime del contenedor llama a `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`. Esto establece el atributo de proceso `PR_SET_NO_NEW_PRIVS` en la estructura `task_struct` del kernel de Linux. Esta flag garantiza que las operaciones durante `execve()` no otorguen privilegios que no hayan sido otorgados ya al proceso que realiza la llamada. Deshabilita explícitamente la ejecución de bits `SUID`/`SGID` e ignora las file capabilities en los binarios ejecutados.

* **Respuesta 1.2**:
  Incluso si un contenedor se ejecuta como `root` (UID 0), configurar `allowPrivilegeEscalation: false` evita que los procesos hijos creados dentro del contenedor obtengan capabilities adicionales a través de binarios `SUID` o file capabilities (`setcap`). Sin embargo, el UID 0 aún conserva cualquier conjunto de capabilities que se le haya otorgado en la inicialización del contenedor. Para contener completamente al UID 0, `allowPrivilegeEscalation: false` debe combinarse con la eliminación de todas las capabilities (`capabilities.drop: ["ALL"]`) y la aplicación de `runAsNonRoot: true`.

---

### Clave de Respuestas del Ejercicio 2

* **Respuesta 2.1**:
  `CAP_SYS_ADMIN` se suele llamar "el nuevo root" en Linux. Otorga permisos para realizar una amplia gama de operaciones administrativas, incluyendo:
  1. Montar y desmontar archivos de sistemas (`mount()`, `umount2()`).
  2. Ejecutar `chroot()` para cambiar el límite del filesystem root a montajes del host (`hostPath`).
  3. Acceder y configurar objetos IPC del kernel, interfaces de red y cgroups.
  4. Interactuar con dispositivos de bloques en bruto (`/dev/sdX`).
  Cuando se combina con un montaje de volumen `hostPath` de `/` o acceso a namespaces del host, `CAP_SYS_ADMIN` permite a un proceso dentro del contenedor montar la partición root del host, escapar de los namespaces del contenedor a través de `nsenter` o `chroot`, y tomar el control completo del nodo subyacente de Kubernetes.

* **Respuesta 2.2**:
  * **Perfil Baseline**: Una política de baja fricción que previene escaladas de privilegios conocidas. Permite capabilities por defecto y no requiere que `allowPrivilegeEscalation: false` se configure explícitamente. Permite host paths si no están restringidos por CRDs de terceros, pero restringe namespaces del host (`hostPID`, `hostIPC`, `hostNetwork`) y host ports.
  * **Perfil Restricted**: Una política strictly hardened siguiendo las mejores prácticas de hardening de pods. **Exige** que:
    1. `securityContext.allowPrivilegeEscalation` esté configurado explícitamente en `false`.
    2. Los contenedores eliminen todas las capabilities (`capabilities.drop: ["ALL"]`), permitiendo que solo capabilities seguras seleccionadas (como `NET_BIND_SERVICE`) se vuelvan a agregar explícitamente si es necesario.
    3. Los contenedores se ejecuten como no-root (`runAsNonRoot: true`).
    4. Se defina `seccompProfile` (`RuntimeDefault` o `Localhost`).
    5. Los volúmenes `hostPath` estén completamente prohibidos.

---

### Clave de Respuestas del Ejercicio 3

* **Respuesta 3.1**:
  Para crear o actualizar un `Role` o `ClusterRole` que contenga reglas que excedan los permisos actuales del usuario, el usuario debe poseer explícitamente el verbo `escalate` en `roles` o `clusterroles` en el grupo de API `rbac.authorization.k8s.io` dentro del alcance correspondiente (namespace o cluster-wide). Sin el verbo `escalate`, el hook de validación RBAC del API server impone comprobaciones de cobertura de reglas y bloquea cualquier solicitud que intente otorgar permisos más allá de los que el solicitante posee actualmente.

* **Respuesta 3.2**:
  Si un usuario tiene permisos de `create` en `pods` y puede generar tokens para una `ServiceAccount` de alto privilegio (o montar una `ServiceAccount` de alto privilegio existente como `cluster-admin`), puede lograr una privilege escalation indirecta al:
  1. Crear un pod que monte el token de una `ServiceAccount` privilegiada (ej., `system:serviceaccount:kube-system:generic-garbage-collector` o una SA admin personalizada).
  2. Extraer el token JWT de `/var/run/secrets/kubernetes.io/serviceaccount/token` dentro del pod.
  3. Usar ese token de ServiceAccount de alto privilegio para emitir solicitudes directas al API server de Kubernetes, eludiendo sus propios límites restringidos de RBAC.

</details>