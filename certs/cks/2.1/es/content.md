# 2.1 Use appropriate Pod Security Standards

## ¿Qué son los Pod Security Standards?

Los **Pod Security Standards (PSS)** son un conjunto de tres políticas predefinidas por upstream Kubernetes que definen niveles de restricción de seguridad para las specs de un Pod. Reemplazan al extinto `PodSecurityPolicy` (removido en Kubernetes 1.25) y se aplican mediante un admission controller integrado en el `kube-apiserver` llamado **Pod Security Admission (PSA)**.

A diferencia de PodSecurityPolicy, que era extremadamente flexible y complejo de administrar (cada policy se ligaba a RBAC mediante ClusterRoles/Bindings), los PSS son **no configurables**: solo se elige un nivel (`privileged`, `baseline` o `restricted`) y un modo de aplicación por namespace, vía labels. Si se necesita una política granular y a medida, corresponde usar un admission controller externo (OPA Gatekeeper, Kyverno) en lugar de, o en combinación con, PSS.

## Los tres niveles

| Nivel | Descripción | Uso típico |
|---|---|---|
| **Privileged** | Sin restricciones. Permite escalamientos de privilegios conocidos. | Componentes de sistema/infraestructura (CNI, storage drivers, `kube-system`) |
| **Baseline** | Mínimamente restrictivo. Previene escalamientos de privilegios conocidos, pero permite la configuración por defecto de un Pod. | Cargas de trabajo genéricas, no necesariamente hardened |
| **Restricted** | Fuertemente restrictivo, sigue las current best practices de pod hardening. Puede romper workloads que no fueron diseñados para correr sin privilegios. | Cargas de trabajo sensibles, requisito típico en producción y en el examen CKS |

### Controles que impone `baseline`

- **Host Namespaces**: `hostNetwork`, `hostPID`, `hostIPC` deben ser `false`.
- **Privileged Containers**: `securityContext.privileged` debe ser `false`.
- **Capabilities**: solo se permite agregar capabilities dentro de un set seguro (`AUDIT_WRITE`, `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `KILL`, `MKNOD`, `NET_BIND_SERVICE`, `SETFCAP`, `SETGID`, `SETPCAP`, `SETUID`, `SYS_CHROOT`).
- **HostPath Volumes**: prohibidos.
- **Host Ports**: prohibidos (o restringidos a un rango conocido).
- **AppArmor / SELinux**: perfiles restringidos a valores por defecto o conocidos.
- **Seccomp**: no se permite `Unconfined`.
- **Sysctls**: solo un subconjunto "seguro" (`kernel.shm_rmid_forced`, `net.ipv4.ip_local_port_range`, etc.).
- **`/proc` Mount Type**: debe ser `Default`.

### Controles adicionales que impone `restricted` (sobre baseline)

- **Volume Types**: solo tipos "core" seguros — `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret`.
- **Privilege Escalation**: `allowPrivilegeEscalation: false` obligatorio.
- **Running as Non-root**: `runAsNonRoot: true` obligatorio (a nivel Pod o de cada container).
- **Running as Non-root user**: `runAsUser` no puede ser `0`.
- **Seccomp**: `seccompProfile.type` debe ser `RuntimeDefault` o `Localhost` (más estricto que baseline).
- **Capabilities**: se debe hacer `drop: ["ALL"]`; solo se permite volver a agregar `NET_BIND_SERVICE`.

## Pod Security Admission (PSA)

PSA es un **admission controller built-in** (no requiere instalar nada) habilitado por defecto desde Kubernetes 1.25. Evalúa cada Pod (y los pod templates de Deployments, StatefulSets, Jobs, etc., vía sus controllers) contra el nivel configurado en el **namespace**, usando labels.

### Labels de namespace

```
pod-security.kubernetes.io/<MODE>: <LEVEL>
pod-security.kubernetes.io/<MODE>-version: <VERSION>
```

- `<MODE>` puede ser:
  - `enforce`: rechaza el Pod si viola el nivel (falla real, hard block).
  - `audit`: permite el Pod, pero agrega una anotación al audit log del `kube-apiserver`.
  - `warn`: permite el Pod, pero devuelve un warning visible al cliente (`kubectl`).
- `<LEVEL>`: `privileged` | `baseline` | `restricted`.
- `<VERSION>` (opcional): fija el comportamiento a una versión específica (`v1.34`) o `latest`. Útil porque los controles de cada nivel pueden endurecerse entre versiones de Kubernetes.

Los tres modos son independientes y pueden combinarse — un patrón muy común en migraciones progresivas es dejar `enforce=baseline` mientras se prueba `warn=restricted` y `audit=restricted` para medir impacto antes de subir el enforce.

## Ejemplo práctico: namespace con `restricted`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: secure-apps
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

También se puede aplicar sobre un namespace existente con `kubectl label`:

```console
$ kubectl label --overwrite ns secure-apps \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.34
namespace/secure-apps labeled
```

### Probar el impacto antes de aplicar (`--dry-run=server`)

Un truco muy útil para el examen: hacer el `label` con `--dry-run=server` fuerza a PSA a evaluar todos los Pods **ya existentes** en el namespace contra el nivel propuesto, y devuelve warnings sin modificar nada:

```console
$ kubectl label --dry-run=server --overwrite ns secure-apps \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "secure-apps" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-app (and 1 other pod): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/secure-apps labeled (server dry run)
```

## Ejemplo: Pod que viola `restricted`

```console
$ kubectl run bad-pod --image=nginx -n secure-apps
Error from server (Forbidden): pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest": 
allowPrivilegeEscalation != false (container "bad-pod" must set securityContext.allowPrivilegeEscalation=false), 
unrestricted capabilities (container "bad-pod" must set securityContext.capabilities.drop=["ALL"]), 
runAsNonRoot != true (pod or container "bad-pod" must set securityContext.runAsNonRoot=true), 
seccompProfile (pod or container "bad-pod" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

## Ejemplo: Pod compliant con `restricted`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
  namespace: secure-apps
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 3000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: nginx:1.27
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true
      ports:
        - containerPort: 8080
```

```console
$ kubectl apply -f good-pod.yaml
pod/good-pod created
```

> Nota: la imagen `nginx` estándar escucha en el puerto 80 y necesita bind a un puerto privilegiado o escribir en `/var/cache/nginx`, lo cual falla con `readOnlyRootFilesystem` + non-root. En un caso real conviene usar una imagen ya adaptada a correr unprivileged (ej. `nginxinc/nginx-unprivileged`) o montar `emptyDir` en los paths que la app necesita escribir.

## Configurar el nivel por defecto a nivel de clúster

Para no depender de que cada namespace tenga las labels correctas (y cubrir namespaces nuevos automáticamente), se puede definir un default a nivel de `kube-apiserver` con un `AdmissionConfiguration`:

```yaml
# /etc/kubernetes/podsecurity.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: ["kube-system"]
```

Y referenciarlo en el manifest estático del API server:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
spec:
  containers:
    - command:
        - kube-apiserver
        - --admission-control-config-file=/etc/kubernetes/podsecurity.yaml
        # ...resto de flags
      volumeMounts:
        - mountPath: /etc/kubernetes/podsecurity.yaml
          name: podsecurity-config
          readOnly: true
  volumes:
    - name: podsecurity-config
      hostPath:
        path: /etc/kubernetes/podsecurity.yaml
        type: File
```

Al ser un static pod, `kubelet` reinicia automáticamente el `kube-apiserver` al detectar el cambio del manifest.

Es buena práctica exentar `kube-system` (y otros namespaces de infraestructura como los de CNI o CSI drivers) porque esos componentes suelen necesitar `hostNetwork`, `hostPath` o `privileged`, y forzarlos a `restricted` rompe el clúster.

## PSS vs PodSecurityPolicy (contexto)

- `PodSecurityPolicy` (PSP) fue **deprecado en 1.21** y **removido en 1.25**. Requería definir objetos `PodSecurityPolicy` y ligarlos a usuarios/ServiceAccounts vía RBAC — flexible, pero propenso a errores de configuración y difícil de auditar.
- PSS/PSA simplifica esto a tres niveles fijos aplicados por namespace, a costa de perder granularidad. Si un clúster todavía corre en una versión con PSP, el path de migración recomendado por upstream es: habilitar PSA en modo `audit`/`warn` en paralelo a PSP, revisar el impacto, y luego migrar a `enforce`.

## PSS vs OPA Gatekeeper / Kyverno

PSS cubre únicamente los campos de `securityContext` y algunos campos relacionados a host access definidos en las tres policies fijas. Para reglas custom (ej. "toda imagen debe venir de un registry interno", "todo Pod debe tener labels de `team`", cuotas de `resources`, etc.) hace falta un admission controller de policy-as-code como **OPA Gatekeeper** o **Kyverno**, que se pueden usar en conjunto con PSS (PSS para el baseline de seguridad de Pods, Gatekeeper/Kyverno para reglas de negocio adicionales).

## Tips para el examen

- Memorizar la sintaxis exacta de las labels: `pod-security.kubernetes.io/<enforce|audit|warn>[-version]`.
- Saber aplicar la label directamente con `kubectl label ns <name> pod-security.kubernetes.io/enforce=restricted --overwrite` — es más rápido que editar YAML bajo presión de tiempo.
- Recordar que `enforce` bloquea, `warn`/`audit` no — si el ejercicio pide "que se vea afectado el cliente pero no se bloquee", es `warn`.
- Si un Pod falla contra `restricted`, el mensaje de error de PSA lista **todos** los campos faltantes de una — usarlo como checklist en lugar de adivinar.
- Los campos clave de `restricted` a memorizar de memoria: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault`.
- Namespaces de sistema (`kube-system`) casi siempre deben quedar exentos o en `privileged` — no intentar aplicarles `restricted`.

## Referencias

- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Enforce Pod Security Standards with Namespace Labels — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Admission Control (AdmissionConfiguration) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf