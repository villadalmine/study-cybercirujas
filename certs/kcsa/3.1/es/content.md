# Pod Security Standards (KCSA — Dominio: Kubernetes Security Fundamentals, Tema 3.1)

## 1. Motivación y problema arquitectónico de producción

En Kubernetes el aislamiento entre un contenedor y el nodo que lo ejecuta es **cooperativo, no hermético**. Un Pod y el `kubelet` comparten el mismo kernel Linux; la frontera de seguridad la construyen namespaces del kernel (PID, NET, MNT, UTS, IPC), cgroups, capabilities, seccomp, LSM (AppArmor/SELinux) y el usuario efectivo del proceso. Cuando un Pod se ejecuta con `privileged: true`, `hostPID: true` o montando `hostPath: /`, esa frontera desaparece: un atacante que logre RCE dentro del contenedor obtiene, en la práctica, **control del nodo** y, por extensión, de todos los Pods que ahí corren (incluyendo tokens de ServiceAccount montados de otros tenants).

El problema arquitectónico es que, por defecto, **la API de Pod es peligrosamente permisiva**. Un `spec.securityContext` vacío produce un contenedor que corre como UID 0, con `allowPrivilegeEscalation` implícito en `true`, con el set completo de capabilities por defecto del runtime y sin perfil seccomp. Un cluster sin controles de admisión acepta felizmente:

```yaml
# El Pod que compromete el nodo — aceptado en un cluster sin PSA
apiVersion: v1
kind: Pod
metadata:
  name: node-escape
spec:
  hostPID: true
  containers:
  - name: shell
    image: busybox
    command: ["nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--", "bash"]
    securityContext:
      privileged: true
    volumeMounts:
    - { name: host, mountPath: /host }
  volumes:
  - name: host
    hostPath: { path: / }
```

Históricamente esto se contenía con **PodSecurityPolicy (PSP)**, deprecado en Kubernetes v1.21 y **eliminado en v1.25**. PSP falló por diseño: era un objeto cluster-scoped acoplado a RBAC (la política aplicable dependía de qué `ServiceAccount` creaba el Pod, no de dónde iba a correr), tenía semántica de "primera política que autoriza gana" imposible de razonar, y **mutaba** los Pods, generando divergencia entre lo aplicado y lo declarado.

Su reemplazo built-in es **Pod Security Admission (PSA)**, un admission controller de tipo *validating* habilitado por defecto y **GA desde v1.25**, que implementa los tres perfiles definidos por los **Pod Security Standards (PSS)**. La decisión de diseño clave: PSA es **namespace-scoped, declarativo por labels, y no muta** — valida y rechaza, pero nunca reescribe el Pod. Esto lo hace auditable y determinista, a costa de granularidad (es un control grueso; para políticas finas se combina con Kyverno u OPA Gatekeeper — ver §2).

> **Punto de examen KCSA:** distinguir **Pod Security Standards** (las tres *políticas/perfiles* — una especificación) de **Pod Security Admission** (el *mecanismo de enforcement* que las aplica). Los PSS son texto normativo; PSA es el controller que los evalúa.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Los tres perfiles (Pod Security Standards)

| Perfil | Intención | Caso de uso | Efecto de seguridad |
|---|---|---|---|
| **Privileged** | Sin restricciones. Escalada de privilegios permitida. | CNI, CSI, agentes de nodo, componentes de infraestructura que *necesitan* el host. | Ninguno — es el default abierto. Reservar para namespaces de sistema. |
| **Baseline** | Mínimamente restrictivo. Previene escaladas de privilegio *conocidas*. | Aplicaciones que aún no están endurecidas; punto de partida de una migración. | Bloquea `privileged`, host namespaces, `hostPath`, capabilities peligrosas. Un Pod "por defecto" (securityContext vacío) **pasa** Baseline. |
| **Restricted** | Endurecimiento agresivo, best-practices actuales. | Cargas multi-tenant, producción sensible, cumplimiento (PCI, CIS). | Exige non-root, drop de ALL capabilities, seccomp, sin privilege escalation. Un Pod por defecto **NO pasa** Restricted. |

### 2.2 Baseline vs Restricted — control por control

Restricted es un superconjunto estricto de Baseline. Todo lo que Baseline restringe, Restricted lo hereda y añade:

| Control | Baseline | Restricted (además) |
|---|---|---|
| **Privileged** | `securityContext.privileged` debe ser `false`/unset | (heredado) |
| **Host Namespaces** | `hostNetwork`, `hostPID`, `hostIPC` = `false`/unset | (heredado) |
| **HostPath volumes** | Prohibidos | (heredado) |
| **Host Ports** | Prohibidos (o lista vacía) | (heredado) |
| **HostProcess (Windows)** | `windowsOptions.hostProcess` = false | (heredado) |
| **`/proc` mount** | `procMount` = `Default`/unset | (heredado) |
| **AppArmor** | Solo `RuntimeDefault`/`Localhost`/unset | (heredado) |
| **SELinux** | `type` ∈ {container_t, container_init_t, container_kvm_t}; `user`/`role` unset | (heredado) |
| **Sysctls** | Solo subset seguro (p.ej. `net.ipv4.ip_local_port_range`) | (heredado) |
| **Capabilities** | No añadir fuera de una allowlist (CHOWN, NET_BIND_SERVICE, KILL, SETUID…) | Debe **`drop: ["ALL"]`**; solo puede **`add: ["NET_BIND_SERVICE"]`** |
| **Seccomp** | No debe ser `Unconfined` | **Obligatorio** `RuntimeDefault` o `Localhost` |
| **Run as Non-root** | — | `runAsNonRoot: true` obligatorio |
| **Run as non-root user** | — | Si `runAsUser` está seteado, ≠ `0` |
| **Privilege Escalation** | — | `allowPrivilegeEscalation: false` obligatorio |
| **Volume types** | Cualquiera salvo `hostPath` | Allowlist estricta: `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret` |

> **Nota de precisión:** `readOnlyRootFilesystem: true` es best-practice de endurecimiento **pero NO forma parte del perfil Restricted**. No lo exige PSA; lo incluimos en los manifiestos como defensa adicional, no para cumplir el estándar.

### 2.3 Los tres modos de PSA

Cada perfil se aplica en uno o varios de tres modos, independientes y combinables por namespace:

| Modo | Efecto ante violación | Momento | Uso típico |
|---|---|---|---|
| **enforce** | El Pod es **rechazado** (`Forbidden`). | Solo sobre el recurso **Pod** (no sobre Deployments). | Política dura en producción. |
| **audit** | Se permite; se anota `pod-security.kubernetes.io/audit-violations` en el **audit log**. | Pod y **workload controllers**. | Observabilidad sin bloquear. |
| **warn** | Se permite; se devuelve un **`Warning:`** al cliente (`kubectl`). | Pod y **workload controllers**. | Feedback al desarrollador antes de endurecer. |

**Trampa operacional crítica:** `enforce` se evalúa **solo sobre el Pod**, no sobre los workload controllers (Deployment, StatefulSet, Job…). Un Deployment con un template que viola Restricted **se crea sin error**; son sus Pods, generados por el ReplicaSet, los que se rechazan silenciosamente. El síntoma es `replicas: 0/3` con eventos `FailedCreate`. Por eso `warn` y `audit` **sí** inspeccionan el template del controller: son la red que atrapa el problema en el momento del `apply`.

### 2.4 PSA vs. Policy Engines externos

| Dimensión | Pod Security Admission (built-in) | Kyverno / OPA Gatekeeper |
|---|---|---|
| Instalación | Nativo, cero dependencias | Deploy + webhooks + mantenimiento |
| Granularidad | 3 perfiles fijos, namespace-scoped | Reglas arbitrarias por campo/label/imagen |
| Mutación | No (solo valida) | Sí (defaults, sidecars) |
| Alcance | Solo Pods | Cualquier recurso |
| Enforcement en controllers | Solo warn/audit | Enforce completo |
| Failure mode | Sin punto único de fallo | Webhook caído ⇒ `failurePolicy` decide (Fail bloquea el cluster) |

**Regla de arquitectura:** usar PSA como *baseline universal barato y sin riesgo operacional*, y añadir Kyverno/Gatekeeper solo para lo que PSA no cubre (registries permitidos, límites obligatorios, drop de capabilities específicas). No son excluyentes; se apilan.

---

## 3. Manifiestos completos

### 3.1 Namespace con etiquetado progresivo (patrón recomendado)

El patrón de rollout seguro: **`enforce: baseline`** (piso duro que no rompe cargas normales) mientras **`warn`/`audit: restricted`** avisan de todo lo que falta para el objetivo final.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod-payments
  labels:
    # Piso duro aplicado ahora
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.25
    # Objetivo futuro: se avisa y audita, todavía no se bloquea
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.25
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.25
```

> **Version pinning:** fijar `*-version: v1.25` en vez de `latest` garantiza que un upgrade del cluster que endurezca un perfil no rompa cargas de golpe. `latest` sigue la definición del release en curso; `v1.25` la congela. En producción se pinnea siempre y se sube la versión de forma controlada.

### 3.2 Deployment 100% compatible con Restricted

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: prod-payments
  labels: { app: web }
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      # securityContext a nivel de Pod: cubre TODOS los contenedores de una vez
      securityContext:
        runAsNonRoot: true          # Restricted: obligatorio
        runAsUser: 10001            # ≠ 0 (Restricted)
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault      # Restricted: obligatorio (o Localhost)
      containers:
      - name: web
        # Imagen que YA corre como usuario no-root (puerto 8080, no 80)
        image: nginxinc/nginx-unprivileged:1.27-alpine
        ports:
        - { containerPort: 8080 }
        securityContext:
          allowPrivilegeEscalation: false   # Restricted: obligatorio
          readOnlyRootFilesystem: true      # Hardening extra (no exigido por PSS)
          capabilities:
            drop: ["ALL"]                    # Restricted: obligatorio
            # add: ["NET_BIND_SERVICE"]      # única capability permitida en Restricted
        resources:
          requests: { cpu: 50m, memory: 64Mi }
          limits:   { cpu: 250m, memory: 128Mi }
        volumeMounts:                        # rootfs de solo lectura ⇒ escrituras a emptyDir
        - { name: tmp,   mountPath: /tmp }
        - { name: cache, mountPath: /var/cache/nginx }
        - { name: run,   mountPath: /var/run }
      volumes:                               # todos en la allowlist de Restricted
      - { name: tmp,   emptyDir: {} }
      - { name: cache, emptyDir: {} }
      - { name: run,   emptyDir: {} }
```

### 3.3 Configuración cluster-wide vía AdmissionConfiguration

Para fijar **defaults globales** (aplicados a *todo namespace sin labels propias*) y **exenciones**, se configura el plugin `PodSecurity` del `kube-apiserver`. Esto es lo que convierte a PSA en "secure-by-default" a nivel de cluster.

`/etc/kubernetes/pss/admission.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1   # GA en v1.25
    kind: PodSecurityConfiguration
    defaults:
      enforce: "baseline"
      enforce-version: "latest"
      audit: "restricted"
      audit-version: "latest"
      warn: "restricted"
      warn-version: "latest"
    exemptions:
      # Las exenciones OMITEN por completo la evaluación de PSA
      usernames: []                      # p.ej. controladores de sistema
      runtimeClasses: []                 # p.ej. gVisor / Kata que ya aíslan
      namespaces: ["kube-system"]        # componentes de plano de control
```

Flag del `kube-apiserver` (en `/etc/kubernetes/manifests/kube-apiserver.yaml` en clusters kubeadm):

```yaml
    - --admission-control-config-file=/etc/kubernetes/pss/admission.yaml
```

> **Advertencia de seguridad:** las `exemptions` son un bypass total, no una relajación. Un namespace exento no recibe *ningún* control PSA en *ningún* modo. Mantener la lista mínima y auditada — es la superficie de ataque de la política misma.

---

## 4. Comandos CLI y salidas reales

### 4.1 Etiquetar y previsualizar impacto antes de aplicar

```console
$ kubectl create namespace prod-payments
namespace/prod-payments created

# Previsualización con server dry-run: reporta qué Pods EXISTENTES violarían
# el nuevo nivel — sin aplicar nada. Imprescindible antes de endurecer.
$ kubectl label --dry-run=server --overwrite namespace prod-payments \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "prod-payments" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-api-6c9f7d-abcde: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/prod-payments labeled (server dry run)

# Aplicación real del patrón progresivo
$ kubectl label namespace prod-payments \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/enforce-version=v1.25 \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/audit=restricted
namespace/prod-payments labeled
```

### 4.2 Enforce rechazando un Pod violatorio

```console
$ kubectl label --overwrite namespace prod-payments pod-security.kubernetes.io/enforce=restricted

$ kubectl -n prod-payments run nginx --image=nginx:1.27
Error from server (Forbidden): pods "nginx" is forbidden: violates PodSecurity "restricted:v1.25": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 4.3 Warn: se permite pero avisa (feedback al desarrollador)

```console
$ kubectl -n staging run nginx --image=nginx:1.27   # namespace con warn=restricted
Warning: would violate PodSecurity "restricted:v1.25": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/nginx created
```

### 4.4 El manifiesto compatible pasa limpio

```console
$ kubectl -n prod-payments apply -f web-deployment.yaml
deployment.apps/web created

$ kubectl -n prod-payments get pods
NAME                   READY   STATUS    RESTARTS   AGE
web-7d4b9c6f8-2xk9p    1/1     Running   0          14s
web-7d4b9c6f8-4mn2t    1/1     Running   0          14s
web-7d4b9c6f8-9qhz7    1/1     Running   0          14s
```

### 4.5 Auditoría de labels en todos los namespaces

```console
$ kubectl get namespaces \
    -L pod-security.kubernetes.io/enforce \
    -L pod-security.kubernetes.io/warn
NAME              STATUS   AGE   ENFORCE      WARN
default           Active   40d
kube-system       Active   40d
prod-payments     Active   6m    restricted   restricted
staging           Active   40d   baseline     restricted
```

### 4.6 La entrada de audit log (modo audit)

```console
$ jq 'select(.annotations["pod-security.kubernetes.io/audit-violations"])' /var/log/kubernetes/audit.log
```
```json
{
  "kind": "Event",
  "verb": "create",
  "objectRef": { "resource": "pods", "namespace": "prod-payments", "name": "legacy-api" },
  "annotations": {
    "pod-security.kubernetes.io/audit-violations": "would violate PodSecurity \"restricted:v1.25\": allowPrivilegeEscalation != false (container \"api\" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true, seccompProfile",
    "authorization.k8s.io/decision": "allow"
  }
}
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Decodificar el mensaje `Forbidden`

Cada cláusula del error mapea 1:1 a un campo faltante. Tabla de traducción para Restricted:

| Fragmento del mensaje | Campo a corregir |
|---|---|
| `allowPrivilegeEscalation != false` | `containers[*].securityContext.allowPrivilegeEscalation: false` |
| `unrestricted capabilities` | `containers[*].securityContext.capabilities.drop: ["ALL"]` |
| `runAsNonRoot != true` | `securityContext.runAsNonRoot: true` (Pod o contenedor) |
| `runAsUser=0` | `securityContext.runAsUser: <≠0>` |
| `seccompProfile` | `securityContext.seccompProfile.type: RuntimeDefault` |
| `privileged != false` | `securityContext.privileged: false` |
| `host namespaces` | quitar `hostNetwork`/`hostPID`/`hostIPC` |
| `hostPath volumes` | reemplazar `hostPath` por `emptyDir`/`csi`/`pvc` |
| `restricted volume types` | usar solo la allowlist de Restricted (§2.2) |

### 5.2 El fallo que PSA **no** atrapa: `runAsNonRoot` + imagen root

Trampa clásica de producción. El Pod **pasa PSA** (declara `runAsNonRoot: true`), pero el `kubelet` lo mata al crear el contenedor porque la imagen tiene `USER root`/UID 0 en el Dockerfile. PSA valida la *declaración*, no la *imagen*.

```console
$ kubectl -n prod-payments get pod web-root-image-xxxx
NAME                   READY   STATUS                       RESTARTS   AGE
web-root-image-xxxx    0/1     CreateContainerConfigError   0          9s

$ kubectl -n prod-payments describe pod web-root-image-xxxx
Events:
  Type     Reason  Age               From     Message
  ----     ------  ----              ----     -------
  Warning  Failed  3s (x3 over 20s)  kubelet  Error: container has runAsNonRoot and image will run as root
```
**Solución:** o `runAsUser: <UID no-root>` explícito en el `securityContext`, o (mejor) una imagen construida con `USER 10001` en el Dockerfile. `CreateContainerConfigError` con ese mensaje ⇒ imagen que insiste en root.

### 5.3 El Deployment "verde" con 0 réplicas (enforce solo sobre Pods)

```console
$ kubectl -n prod-payments apply -f legacy-deployment.yaml
deployment.apps/legacy created        # ← ningún error, aunque el template viola Restricted

$ kubectl -n prod-payments get deploy legacy
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
legacy   0/3     0            0           30s

$ kubectl -n prod-payments describe rs legacy-6c9f7d
Events:
  Type     Reason        Age   From                   Message
  ----     ------        ----  ----                   -------
  Warning  FailedCreate  12s   replicaset-controller  Error creating: pods "legacy-6c9f7d-" is forbidden: violates PodSecurity "restricted:v1.25": ...
```
**Diagnóstico:** un Deployment que "aplica bien" pero nunca escala ⇒ mirar eventos del **ReplicaSet**, no del Deployment. Prevención: mantener `warn=restricted` para que el mensaje aparezca en el `kubectl apply`.

### 5.4 Checklist de verificación (comandos idempotentes)

```console
# 1. ¿Qué política tiene realmente cada namespace?
$ kubectl get ns -o custom-columns=\
'NS:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'

# 2. Simular una carga contra la política sin crearla
$ kubectl -n prod-payments apply --dry-run=server -f candidate-pod.yaml

# 3. Confirmar que la config cluster-wide está cargada en el apiserver
$ kubectl -n kube-system get pod kube-apiserver-$(hostname) -o yaml \
    | grep admission-control-config-file

# 4. ¿Hay violaciones auditadas en la última hora?
$ grep audit-violations /var/log/kubernetes/audit.log | jq -r \
    '.objectRef.namespace + "/" + .objectRef.name'
```

> **Namespaces que PSA NO cubre:** los **static Pods** (creados por el `kubelet` desde `/etc/kubernetes/manifests/`, no vía API) y los Pods creados directamente por un `kubelet` **omiten PSA por completo**, porque el admission controller vive en el `kube-apiserver`. No confiar en PSA para endurecer componentes de plano de control desplegados como static Pods — ahí el control es el acceso al filesystem del nodo.

---

## 6. Referencias

- Pod Security Standards (definición de los tres perfiles): https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Enforcing Pod Security Standards (Pod Security Admission): https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Enforce Pod Security Standards with Namespace Labels: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Configure the Admission Controller (AdmissionConfiguration cluster-wide): https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller: https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/
- PodSecurityPolicy Deprecation: Past, Present, and Future (blog): https://kubernetes.io/blog/2021/04/06/podsecuritypolicy-deprecation-past-present-and-future/
- Configure a Security Context for a Pod or Container: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- KCSA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf