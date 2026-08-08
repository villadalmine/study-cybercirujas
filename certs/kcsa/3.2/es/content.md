# Pod Security Admission (PSA)
## KCSA — Tema 3.2 · Kubernetes Security Fundamentals

---

## 1. Motivación y el problema arquitectónico de producción

En un cluster multi-tenant real, el `SecurityContext` de un Pod es el límite entre "un contenedor comprometido" y "un nodo comprometido". Un Pod que corre `privileged: true`, monta `hostPath: /`, o comparte `hostPID: true` no está aislado del kernel del host: puede leer los secrets de cualquier otro Pod del nodo, escribir en el filesystem del kubelet, o pivotar hacia el runtime del contenedor (`containerd`/`CRI-O`). El `kube-apiserver`, por defecto, **no impone ninguna restricción** sobre estos campos — acepta cualquier Pod sintácticamente válido. Ese es el hueco que Pod Security Admission (PSA) cierra.

El problema de gobernanza es concreto: no se puede confiar en que cada equipo escriba un `SecurityContext` correcto en cada manifiesto. Se necesita un control **centralizado, declarativo y evaluado en el admission path**, antes de que el objeto se persista en `etcd`, que rechace configuraciones peligrosas independientemente de quién las envíe.

### Genealogía: por qué PSA y no PodSecurityPolicy (PSP)

PSP fue el mecanismo original (in-tree admission controller) y fue un fracaso operativo: su modelo dependía del RBAC (`use` verb sobre el recurso `PodSecurityPolicy`), lo que producía un comportamiento contraintuitivo — el binding al `ServiceAccount` correcto determinaba qué política aplicaba, y con múltiples PSP el orden de selección era opaco y difícil de auditar. PSP fue **deprecado en v1.21 y removido en v1.25**.

PSA es su reemplazo built-in. Es un **admission plugin in-process** del `kube-apiserver` (`ValidatingAdmissionPlugin` llamado `PodSecurity`), estable (GA) desde **v1.25** y habilitado por defecto desde v1.23 (beta). No es un webhook externo: no hay latencia de red, no hay un Deployment que mantener, no hay fallo por `failurePolicy`. Corre dentro del apiserver.

### Los dos ejes conceptuales

PSA combina dos dimensiones ortogonales:

**a) Pod Security Standards (PSS)** — *qué tan estricta* es la política. Tres niveles fijos:

| Nivel | Filosofía | Uso típico |
|---|---|---|
| `privileged` | Sin restricciones. Permite todo intencionalmente. | Workloads de infraestructura (CNI, CSI, agentes de nodo). |
| `baseline` | Mínimamente restrictivo. Bloquea escalaciones de privilegio *conocidas*, permite la configuración por defecto de un Pod. | Aplicaciones legacy que no toleran hardening completo. |
| `restricted` | Sigue las best practices actuales de hardening. Fuertemente restrictivo. | Objetivo para toda carga de aplicación en producción. |

**b) Modes** — *qué hace* PSA cuando detecta una violación:

| Mode | Efecto | Se aplica a |
|---|---|---|
| `enforce` | Rechaza el Pod (HTTP 403 Forbidden). | **Solo Pods.** No bloquea Deployments/otros controllers. |
| `audit` | Permite el Pod, pero añade una annotation al audit log. | Pods **y** los pod templates de workload resources. |
| `warn` | Permite el Pod, pero devuelve un `Warning:` al cliente. | Pods **y** los pod templates de workload resources. |

Los tres modes son **independientes y combinables**. El patrón de rollout canónico es `enforce: baseline` + `warn: restricted` + `audit: restricted`: se impone lo mínimo viable mientras se recoge telemetría de qué rompería si se subiera el enforce a `restricted`.

> **Detalle arquitectónico crítico para el examen:** `enforce` actúa **únicamente sobre el objeto `Pod`**. Si aplicás un `Deployment` que genera Pods no conformes, el `Deployment` se crea sin error — el rechazo ocurre después, cuando el `ReplicaSet` controller intenta crear el Pod, y aparece como evento del ReplicaSet (no como fallo del `kubectl apply`). En cambio `warn` y `audit` **sí** evalúan el pod template embebido en el workload resource, por eso ves el `Warning:` al momento del `apply`. Esta asimetría es deliberada y es una fuente habitual de confusión en producción.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Controles por profile (mecánica interna del chequeo)

PSA evalúa el **valor efectivo** de cada campo (pod-level `securityContext` heredado por los containers salvo override a nivel container). Estos son los controles que evalúa:

| Control | `baseline` | `restricted` |
|---|---|---|
| `hostNetwork` / `hostPID` / `hostIPC` | debe ser `false`/unset | igual que baseline |
| `securityContext.privileged` | `false`/unset | igual |
| `securityContext.capabilities.add` | solo lista permitida¹ | **solo** `NET_BIND_SERVICE` |
| `capabilities.drop` | sin requisito | **debe** incluir `ALL` |
| `hostPath` volumes | prohibido | prohibido |
| `hostPort` | `0`/unset | igual |
| `procMount` | `Default` | igual |
| `seccompProfile.type` | no puede ser `Unconfined` | **debe** ser `RuntimeDefault` o `Localhost` (explícito) |
| Windows `hostProcess` | `false`/unset | igual |
| SELinux `seLinuxOptions` type/user/role | valores restringidos | igual |
| `sysctls` | solo set seguro | igual |
| `allowPrivilegeEscalation` | sin requisito | **debe** ser `false` |
| `runAsNonRoot` | sin requisito | **debe** ser `true` |
| `runAsUser` | sin requisito | no puede ser `0` |
| Volume types | cualquiera | **solo** lista segura² |

¹ Lista permitida en baseline para `add`: `AUDIT_WRITE, CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, MKNOD, NET_BIND_SERVICE, SETFCAP, SETGID, SETPCAP, SETUID, SYS_CHROOT`.
² Volume types seguros en restricted: `configMap, csi, downwardAPI, emptyDir, ephemeral, persistentVolumeClaim, projected, secret`.

> **No lo confundas:** `restricted` **no** exige `readOnlyRootFilesystem: true` ni `resources.limits`. Son best practices de hardening, pero PSA no las evalúa. Si necesitás imponerlas, hace falta un policy engine (§2.3).

### 2.2 Version pinning: `latest` vs versión fija

Cada mode acepta un `-version` (`enforce-version`, etc.). Define *qué iteración* del PSS aplicar.

| Estrategia | Ventaja | Riesgo |
|---|---|---|
| `latest` | Adoptás controles nuevos automáticamente al upgradear el cluster. | Un upgrade de Kubernetes puede endurecer un profile y romper Pods que antes pasaban — cambio de comportamiento silencioso. |
| Fija (ej. `v1.28`) | Comportamiento estable y reproducible entre upgrades. | Te perdés controles nuevos hasta que subas la versión a mano. |

En producción regulada, **fijá la versión** y subila deliberadamente con un cambio revisado. `latest` es aceptable en entornos donde el churn es tolerable.

### 2.3 PSA vs policy engines (Kyverno / OPA Gatekeeper)

| Dimensión | Pod Security Admission | Kyverno / Gatekeeper |
|---|---|---|
| Instalación | Built-in en el apiserver | Webhook externo a desplegar y operar |
| Granularidad | 3 profiles fijos, a nivel namespace | Reglas arbitrarias, por recurso/label/campo |
| Mutación (defaulting) | **No** puede mutar | Sí (mutating webhooks) |
| Alcance | Solo Pods y sus templates | Cualquier recurso (Ingress, límites de registry, quotas…) |
| Latencia / disponibilidad | In-process, sin red | Depende del webhook (`failurePolicy`, timeout) |
| Exenciones | Por username / runtimeClass / namespace | Expresiones arbitrarias |
| Curva operativa | Baja (labels) | Alta (CRDs, lenguaje de políticas) |

**Trade-off de arquitectura:** PSA es el *piso* — barato, siempre disponible, imposible de tumbar. Los policy engines son la *capa fina* para lo que PSA no cubre (forzar registries confiables, exigir `resources.limits`, bloquear `latest` tag, etc.). En un cluster serio conviven: PSA impone `restricted` a nivel namespace, y Kyverno cubre el resto. No son competidores, son capas.

---

## 3. Manifiestos e infraestructura completos

### 3.1 Etiquetado de namespace (los tres modes combinados)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod-payments
  labels:
    # enforce: rechaza Pods no conformes con baseline
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.28
    # audit + warn a restricted: telemetría sin romper nada
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.28
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.28
```

El formato de la label es fijo: `pod-security.kubernetes.io/<MODE>` y `pod-security.kubernetes.io/<MODE>-version`. Un namespace sin labels usa los defaults cluster-wide (§3.3).

### 3.2 Pod conforme con `restricted` (todos los campos requeridos)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: restricted-compliant
  namespace: prod-payments
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault          # requerido por restricted
  containers:
  - name: api
    image: registry.example.com/payments/api:1.7.3
    ports:
    - containerPort: 8443
    securityContext:
      allowPrivilegeEscalation: false   # requerido por restricted
      privileged: false
      runAsNonRoot: true
      readOnlyRootFilesystem: true       # hardening extra (NO exigido por PSA)
      capabilities:
        drop:
        - ALL                            # requerido por restricted
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 500m, memory: 256Mi }
    volumeMounts:
    - name: tmp
      mountPath: /tmp
  volumes:
  - name: tmp
    emptyDir: {}                         # volume type seguro
```

### 3.3 Defaults cluster-wide vía `AdmissionConfiguration`

Cuando querés una postura por defecto para *todos* los namespaces sin etiquetar (por ejemplo, `warn: restricted` global), se configura en el apiserver:

```yaml
# /etc/kubernetes/admission/pod-security.yaml
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
      # las exenciones aplican a TODOS los modes
      usernames: []
      runtimeClasses: []
      namespaces:
      - kube-system      # imponer restricted aquí rompe CNI/CSI/DNS
```

Y se referencia en el manifiesto del `kube-apiserver` (static pod en `/etc/kubernetes/manifests/kube-apiserver.yaml`):

```yaml
    - --admission-control-config-file=/etc/kubernetes/admission/pod-security.yaml
    # ...y montar el archivo:
    volumeMounts:
    - name: admission-config
      mountPath: /etc/kubernetes/admission
      readOnly: true
  volumes:
  - name: admission-config
    hostPath:
      path: /etc/kubernetes/admission
      type: DirectoryOrCreate
```

> **Precedencia:** una label en el namespace **siempre gana** sobre el default cluster-wide para ese mode. Las `exemptions` son globales y bypasean *todos* los modes — usalas con cuidado; una exención de `username` mal puesta es un agujero de seguridad, no una conveniencia.

---

## 4. Comandos CLI y salidas reales

### 4.1 Etiquetar e inspeccionar

```console
$ kubectl label namespace prod-payments \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.28 --overwrite
namespace/prod-payments labeled

$ kubectl get ns prod-payments --show-labels
NAME            STATUS   AGE   LABELS
prod-payments   Active   12d   kubernetes.io/metadata.name=prod-payments,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/enforce-version=v1.28
```

### 4.2 Rechazo por `enforce` (el mensaje enumera cada control violado)

```console
$ kubectl run nginx --image=nginx -n prod-payments
Error from server (Forbidden): pods "nginx" is forbidden: violates PodSecurity "restricted:v1.28": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

El mensaje es exhaustivo: lista **cada** control violado con el path exacto del campo a corregir. Leerlo entero es el 90% del diagnóstico.

### 4.3 `warn` sobre un workload resource (se crea igual)

```console
$ kubectl apply -f deployment.yaml
Warning: would violate PodSecurity "restricted:v1.28": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), ...
deployment.apps/legacy-app created
```

El `Deployment` se crea (warn no bloquea), pero el operador ve la advertencia. Con `enforce: restricted`, el Deployment igual se crearía, pero los Pods fallarían — ver §4.4.

### 4.4 Enforce sobre un controller: el fallo aparece en el ReplicaSet

```console
$ kubectl apply -f deployment.yaml        # enforce=restricted en el ns
deployment.apps/legacy-app created         # ¡se crea sin error!

$ kubectl get deploy legacy-app
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
legacy-app   0/3     0            0           20s      # 0 réplicas, nunca arranca

$ kubectl get events --field-selector reason=FailedCreate
LAST SEEN   TYPE      REASON         OBJECT                          MESSAGE
15s         Warning   FailedCreate   replicaset/legacy-app-6c9f...   Error creating: pods "legacy-app-6c9f..." is forbidden: violates PodSecurity "restricted:v1.28": ...
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Server-side dry-run: la técnica de rollout segura

Antes de subir `enforce` en un namespace con cargas existentes, **simulá** el cambio con `--dry-run=server`. PSA evalúa todos los Pods vivos contra la política propuesta y te dice cuáles romperían — sin aplicar nada:

```console
$ kubectl label --dry-run=server --overwrite ns prod-payments \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "prod-payments" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-app-6c9f8b7d4-abcde: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
Warning: batch-worker-77c5-xyz12: privileged, hostPath volumes
namespace/prod-payments labeled (server dry run)
```

Este es el paso obligatorio antes de cualquier `enforce` en producción. Si la salida está limpia, el enforce real es seguro.

### 5.2 Árbol de diagnóstico cuando un Pod no arranca

1. **¿El Pod fue rechazado o creado?**
   - `Error from server (Forbidden): ... violates PodSecurity` → rechazo directo de `enforce` sobre un Pod.
   - El Deployment existe pero `READY 0/N` → enforce actuó en el ReplicaSet; mirá `kubectl get events --field-selector reason=FailedCreate`.

2. **¿Qué política está activa en el namespace?**
   ```console
   $ kubectl get ns prod-payments -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security
   "pod-security.kubernetes.io/enforce":"restricted"
   "pod-security.kubernetes.io/enforce-version":"v1.28"
   ```
   Si no hay labels, la política viene del default cluster-wide (`AdmissionConfiguration`).

3. **¿Qué controles exactos viola?** Leé el mensaje de Forbidden/Warning entero — cada cláusula nombra el campo (`container "X" must set securityContext.Y=Z`).

4. **Verificá el efecto tras corregir** volviendo a aplicar; ausencia de `Warning:` y Pod en `Running` confirma conformidad.

### 5.3 Auditar todo el cluster con `audit` mode

Habilitá `audit: restricted` cluster-wide y consultá el audit log del apiserver por la annotation que PSA inyecta:

```console
$ grep 'pod-security.kubernetes.io/audit-violations' /var/log/kubernetes/audit.log \
    | jq -r '.objectRef.namespace + "/" + .objectRef.name + " → " + (.annotations["pod-security.kubernetes.io/audit-violations"])'
prod-payments/legacy-app-6c9f... → would violate PodSecurity "restricted:v1.28": allowPrivilegeEscalation != false, ...
default/debug-shell → would violate PodSecurity "restricted:v1.28": privileged, hostPID=true
```

La annotation es `pod-security.kubernetes.io/audit-violations`. Esto da inventario cluster-wide de deuda de seguridad sin romper ninguna carga — el insumo para planificar el enforce.

### 5.4 Checklist de verificación pre-enforce en producción

- [ ] `warn` y `audit` en `restricted` corriendo ≥1 ciclo de deploy completo.
- [ ] `kubectl label --dry-run=server` limpio en el namespace objetivo.
- [ ] Namespaces de infraestructura (`kube-system`, CNI, CSI) exentos o en `privileged` explícito.
- [ ] Versión **fija** (no `latest`) en `enforce-version`.
- [ ] Plan documentado de qué policy engine cubre lo que PSA no evalúa (registries, límites, `readOnlyRootFilesystem`).

---

## 6. Referencias

- Pod Security Admission — concepto y configuración: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards (definición de `privileged`/`baseline`/`restricted` control por control): https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Enforcing Pod Security Standards con namespace labels: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Configurar el Admission Controller (`AdmissionConfiguration` / `PodSecurityConfiguration`): https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-plugin/
- Migración desde PodSecurityPolicy a Pod Security Admission: https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/
- Mapear PSP a Pod Security Standards: https://kubernetes.io/docs/reference/access-authn-authz/psp-to-pod-security-standards/
- KCSA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf