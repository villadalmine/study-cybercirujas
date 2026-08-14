# Configuraciones Comunes de Políticas para Reglas de Kyverno

> **Dominio 4 del Examen KCA — Aplicando Políticas de Kyverno · Tema 4.3 (peso 3.33)**
> Línea de Kyverno objetivo: **1.11 → 1.13**. Donde un campo se movió o quedó obsoleto a lo largo de ese rango, se señala en línea. Si tu imagen de examen fija una versión más antigua, preferí la ubicación a nivel de política; la ubicación moderna por regla es la opción estratégica de aquí en adelante.

---

## 1. El problema de producción: una política es un webhook, y sus *configuraciones* son los controles del radio de impacto

Una `ClusterPolicy` / `Policy` de Kyverno no es un linter pasivo. Cuando ejecutás `kubectl apply` sobre una política, el controlador de Kyverno **reconfigura la ruta de admisión del clúster** escribiendo entradas en los objetos `ValidatingWebhookConfiguration` y `MutatingWebhookConfiguration`. Desde ese instante, una porción de cada `CREATE`/`UPDATE`/`DELETE` sobre los kinds coincidentes es enviada de ida y vuelta a través del Pod del controlador de admisión de Kyverno *antes* de que el objeto sea persistido en etcd.

Ese es el peso arquitectónico de las "configuraciones comunes de políticas". Son las perillas que deciden:

- **¿Una caída de Kyverno se lleva al API server con ella?** → `failurePolicy` + `webhookTimeoutSeconds`
- **¿La política bloquea los deployments, o solo informa sobre ellos?** → `validationFailureAction` / `validate.failureAction`
- **¿La política escanea los 40.000 objetos que ya están en etcd, o solo las nuevas admisiones?** → `background`
- **¿Evaluás todas las reglas o hacés cortocircuito en la primera?** → `applyRules`
- **¿El autor de un `Deployment` necesita saber que Kyverno inspecciona `Pods`?** → autogen (`pod-policies.kyverno.io/autogen-controllers`)

Un SRE que despliega una política con `failurePolicy: Fail` (el valor por defecto), un timeout de webhook ajustado, y una instalación de Kyverno de una sola réplica ha acoplado la disponibilidad de *cada creación de workload* a la disponibilidad de un solo Pod. Este tema trata fundamentalmente sobre **desacoplar la correctitud de la disponibilidad**, y sobre acotar una política de forma lo suficientemente estricta como para que nunca se dispare donde no debería.

Estas configuraciones se dividen en dos altitudes, y el examen espera que sepas cuál vive dónde:

| Altitud | Dónde | Ejemplos |
|---|---|---|
| **A nivel de política** (`spec.*`) | Aplica a todas las reglas de la política | `background`, `admission`, `applyRules`, `failurePolicy`, `webhookTimeoutSeconds`, `schemaValidation`, `webhookConfiguration`, `generateExisting`, `mutateExistingOnPolicyUpdate` |
| **Por regla** (`spec.rules[].*`) | Acota / ajusta una regla | `match`, `exclude`, `preconditions`, `context`, y (moderno) `validate.failureAction`, `validate.failureActionOverrides`, `validate.allowExistingViolations` |

---

## 2. Las configuraciones, una por una — mecánica y compensaciones

### 2.1 `validationFailureAction` — Audit vs Enforce

La configuración más determinante en una política validate. Decide si una violación **bloquea** la solicitud o simplemente se **registra** en un reporte de política.

> **Nota de versión.** Hasta Kyverno 1.10 esto vivía en `spec.validationFailureAction` (valores `audit`/`enforce`, luego capitalizados `Audit`/`Enforce`). Desde **1.11** está obsoleto a nivel de spec y se movió **por regla** a `spec.rules[].validate.failureAction`, con overrides por namespace en `spec.rules[].validate.failureActionOverrides`. Ambas formas todavía se parsean en 1.11–1.13; el CRD emite una advertencia de obsolescencia para la forma a nivel de spec.

| | `Audit` (por defecto) | `Enforce` |
|---|---|---|
| Solicitud en caso de violación | **Admitida**, violación escrita en `PolicyReport` | **Denegada** en admisión |
| Webhook conectado para validate | Sí (sigue en la ruta de admisión) | Sí |
| Radio de impacto de una política defectuosa | Bajo — nada se bloquea | Alto — puede trabar todos los deploys |
| Adecuado para | Políticas nuevas, medir deriva, canary/soak | Requisitos estrictos después del soak |
| Observabilidad | `kubectl get polr,cpolr -A` | Mensaje de denegación devuelto a `kubectl` |

**Patrón de producción:** desplegá cada nuevo requisito estricto como `Audit`, observá los conteos de `fail` en `PolicyReport` a lo largo de un ciclo de deploy completo, *luego* promové a `Enforce`. Usá `failureActionOverrides` para mantener los namespaces `dev`/`sandbox` en `Audit` permanentemente mientras `prod` aplica el enforce.

### 2.2 `failurePolicy` — Fail vs Ignore (la perilla de disponibilidad)

`failurePolicy` se pasa directamente al objeto webhook de Kubernetes. Gobierna lo que el **API server** hace cuando el webhook de Kyverno da error, agota el tiempo, o es inalcanzable.

| | `Fail` (por defecto) | `Ignore` |
|---|---|---|
| Kyverno caído / con timeout | Las solicitudes coincidentes son **rechazadas** por el API server | Las solicitudes coincidentes son **admitidas** sin verificar |
| Garantías | La política es fail-closed (sin bypass) | Disponibilidad de la ruta del workload |
| Riesgo | Caída de Kyverno ⇒ caída de admisión a nivel de clúster | Bypass silencioso de política durante caídas |
| Se combina con | Aplicar invariantes de seguridad, Kyverno HA (≥3 réplicas) | Políticas de mejor esfuerzo / audit |

**La compensación en una oración:** `Fail` protege el *invariante*; `Ignore` protege la *capacidad del clúster de desplegar*. Para una política `Enforce` genuinamente crítica en seguridad generalmente querés `Fail` **más** un Kyverno de alta disponibilidad (`replicaCount: 3`, PDB, anti-afinidad) para que la postura fail-closed no se convierta en una caída autoinfligida.

### 2.3 `webhookTimeoutSeconds`

Rango **1–30**, por defecto **10**. Esta es la paciencia del API server para una única respuesta de Kyverno. Combinado con `failurePolicy: Fail`, un timeout demasiado ajustado bajo carga convierte la latencia en rechazos de solicitud directos. Aumentalo para políticas que hacen trabajo costoso (llamadas a API en `context`, verificación de imágenes), pero nunca por encima de lo que tu presupuesto de solicitudes del API server tolere — un webhook lento agrega latencia a *cada* admisión coincidente.

### 2.4 `background`

Por defecto **true**. Controla si la política participa en los **escaneos en segundo plano** — la reconciliación periódica de Kyverno de los recursos *ya existentes en etcd*, independiente de la admisión.

| | `background: true` (por defecto) | `background: false` |
|---|---|---|
| Evalúa recursos preexistentes | Sí (informa sobre todo el clúster) | No — solo admisión |
| Puede usar contexto exclusivo de admisión | **No** | Sí |
| Los reportes reflejan el estado actual de objetos viejos | Sí | Solo aparecen los objetos recién admitidos |

**El detalle que al examen le encanta:** los escaneos en segundo plano **no tienen solicitud de admisión**, por lo que cualquier regla que referencie variables exclusivas de admisión — `request.userInfo`, `request.roles`, `request.clusterRoles`, `serviceAccountName`, `request.operation` — es **incompatible con `background: true`**. Kyverno rechaza tal política en el momento de la creación con un error de validación. La solución es `background: false`.

### 2.5 `admission`

Por defecto **true**. Si la política se evalúa en la ruta de admisión en absoluto. Configuralo en `false` para construir una política **solo-reporte / solo-escaneo-en-segundo-plano** que nunca toca el webhook (latencia de admisión cero, reporte de deriva puro). Configurar tanto `admission: false` como `background: false` produce una política que no hace nada.

### 2.6 `applyRules` — All vs One

| | `All` (por defecto) | `One` |
|---|---|---|
| Reglas evaluadas | Cada regla coincidente en `spec.rules` | Se detiene después de que la **primera** regla coincidente tenga éxito |
| Caso de uso | Verificaciones independientes | Fallbacks ordenados / exclusión mutua (p. ej. gana el primer mutate coincidente) |

### 2.7 `schemaValidation`

Por defecto **true**. Kyverno valida tu `pattern`/`overlay` contra el esquema OpenAPI del objetivo en el momento de aplicar la política, detectando rutas de campo mal escritas temprano. Deshabilitalo solo para CRDs cuyo esquema Kyverno no puede resolver.

### 2.8 `webhookConfiguration` (unificado, 1.12+)

Kyverno más nuevo consolida las perillas del webhook — y agrega **`matchConditions` de CEL** para que el propio API server pueda pre-filtrar solicitudes *antes* de que siquiera lleguen a Kyverno (recortando carga y evitando bucles propios como el kubelet o la propia SA de Kyverno):

```yaml
spec:
  webhookConfiguration:
    failurePolicy: Ignore
    timeoutSeconds: 15
    matchConditions:
      - name: exclude-kubelet-updates
        expression: "request.userInfo.username != 'system:node:*'"
```

> Preferí `spec.webhookConfiguration.failurePolicy`/`timeoutSeconds` en 1.12+; los de nivel superior `spec.failurePolicy`/`spec.webhookTimeoutSeconds` permanecen por compatibilidad.

### 2.9 `generateExisting` / `mutateExistingOnPolicyUpdate`

Por defecto, las reglas `generate` y `mutate` actúan solo sobre admisiones **futuras**. Estos dos booleanos habilitan a la política a actuar sobre recursos que **ya existen** en el momento de aplicar/actualizar la política — p. ej. inyectar una etiqueta en cada Namespace existente, o clonar un ConfigMap en todos los namespaces actuales. Poderoso y peligroso: una política con `mutateExistingOnPolicyUpdate: true` parchea objetos de producción vivos en el momento en que la aplicás. Relacionado: `validate.allowExistingViolations` (por defecto `true`) decide si los infractores preexistentes son tolerados en lugar de reportados como errores bloqueantes durante background/mutate-existing.

---

## 3. Configuraciones comunes por regla: `match`, `exclude`, `preconditions`, autogen

### 3.1 `match` / `exclude` — el selector de recursos

Cada regla necesita un `match`; `exclude` lo acota. Ambos toman `any` (OR lógico entre bloques) o `all` (AND lógico entre bloques). Aquí es donde acotás el radio de impacto con precisión.

```yaml
match:
  any:
    - resources:
        kinds: [Pod]
        namespaceSelector:
          matchExpressions:
            - key: kubernetes.io/metadata.name
              operator: NotIn
              values: [kube-system, kyverno]
exclude:
  any:
    - subjects:
        - kind: ServiceAccount
          name: system:serviceaccount:kyverno:kyverno-admission-controller
    - clusterRoles: [cluster-admin]
```

**Siempre excluí los namespaces del sistema** (`kube-system`, `kube-node-lease`, el propio namespace de Kyverno) de las políticas `Enforce`. Una política que bloquea Pods en `kube-system` puede impedir que los componentes del plano de control se programen — una traba de clúster autoinfligida clásica.

### 3.2 `preconditions`

Filtrado de grano fino *después* de `match`, evaluado contra JMESPath (o CEL) sobre la solicitud de admisión. Usalos para condiciones que el selector grueso no puede expresar — "solo cuando `spec.hostNetwork == true`", "solo en `CREATE`".

```yaml
preconditions:
  all:
    - key: "{{ request.operation || 'BACKGROUND' }}"
      operator: AnyIn
      value: [CREATE, UPDATE]
```

> El idiom `|| 'BACKGROUND'` es esencial cuando `background: true`: `request.operation` está vacío durante los escaneos, por lo que este valor por defecto mantiene la precondición evaluable en ambos contextos.

### 3.3 Autogen para controladores de Pod

Cuando una regla coincide con `Pod`, Kyverno **autogenera** reglas equivalentes para `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`, `ReplicaSet`, `ReplicationController` — para que la verificación se dispare a nivel del *controlador*, donde el autor realmente recibe el feedback. Controlalo con la anotación:

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: "Deployment,StatefulSet,Job"   # subset
    # pod-policies.kyverno.io/autogen-controllers: "none"                        # disable
```

Autogen es la razón por la que una política `Enforce` que coincide con `Pod` bloquea un `Deployment` defectuoso en el momento de aplicarlo, en lugar de fallar silenciosamente más tarde en la creación del Pod.

---

## 4. Una ClusterPolicy completa y de nivel de producción ejercitando las configuraciones comunes

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
  annotations:
    policies.kyverno.io/title: Require Team Label
    policies.kyverno.io/category: Governance
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet,Job,CronJob
spec:
  # ---- policy-wide common settings ----
  admission: true                 # evaluate on the admission path
  background: true                # also scan pre-existing resources
  applyRules: All                 # evaluate every matching rule
  schemaValidation: true          # validate patterns against target schema
  webhookConfiguration:
    failurePolicy: Fail           # fail-closed: no bypass on Kyverno outage
    timeoutSeconds: 10            # API server patience for the webhook
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - kyverno
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      validate:
        failureAction: Enforce                     # per-rule (1.11+) action
        failureActionOverrides:
          - action: Audit                          # keep non-prod in report mode
            namespaces:
              - "dev-*"
              - "sandbox-*"
        allowExistingViolations: true              # don't error on legacy Pods
        message: >-
          The label 'team' is required on all Pods so ownership and cost
          allocation can be attributed. Found: {{ request.object.metadata.labels || '{}' }}
        pattern:
          metadata:
            labels:
              team: "?*"                            # must be present and non-empty
```

**Equivalente con namespace** (misma spec, acotada a un namespace — notá `kind: Policy`):

```yaml
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: require-team-label
  namespace: payments
spec:
  background: true
  webhookConfiguration:
    failurePolicy: Fail
    timeoutSeconds: 10
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        failureAction: Enforce
        message: "The label 'team' is required."
        pattern:
          metadata:
            labels:
              team: "?*"
```

---

## 5. CLI: aplicar, inspeccionar, y probar que las configuraciones surtieron efecto

```console
$ kubectl apply -f require-team-label.yaml
clusterpolicy.kyverno.io/require-team-label created

$ kubectl get cpol
NAME                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-team-label   true        true         Enforce           True    9s    Ready
```

Las columnas `READY=True` / `MESSAGE=Ready` confirman que el controlador terminó de conectar el webhook. Verificá el objeto webhook que Kyverno realmente escribió:

```console
$ kubectl get validatingwebhookconfigurations | grep kyverno
kyverno-resource-validating-webhook-cfg    2    41s

$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"  failurePolicy="}{.failurePolicy}{"  timeout="}{.timeoutSeconds}{"\n"}{end}'
validate.kyverno.svc-fail    failurePolicy=Fail    timeout=10
validate.kyverno.svc-ignore  failurePolicy=Ignore  timeout=10
```

> Kyverno mantiene **dos** entradas de webhook — `...svc-fail` y `...svc-ignore` — y enruta cada regla a la que coincide con su `failurePolicy`. Ver tu kind bajo `svc-fail` prueba que `failurePolicy: Fail` está activo.

**Enforce se dispara** — el mensaje de denegación se devuelve directamente al cliente:

```console
$ kubectl run nginx --image=nginx -n payments
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/payments/nginx was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: The label ''team'' is required on all Pods
    so ownership and cost allocation can be attributed. Found: {}. rule check-team-label
    failed at path /metadata/labels/team/'
```

**Autogen se prueba a sí mismo** — la misma política bloquea un `Deployment`, porque Kyverno autogeneró una regla de Deployment:

```console
$ kubectl create deployment web --image=nginx -n payments
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail"
denied the request:

resource Deployment/payments/web was blocked due to the following policies

require-team-label:
  autogen-check-team-label: 'validation error: The label ''team'' is required ...'
```

**El override funciona** — el mismo objeto en un namespace `dev-*` es admitido y solo *reportado*:

```console
$ kubectl run nginx --image=nginx -n dev-alice
pod/nginx created

$ kubectl get polr -n dev-alice
NAME                                   KIND   NAME    PASS   FAIL   WARN   ERROR   SKIP   AGE
5f0b...-require-team-label             Pod    nginx   0      1      0      0       0      6s
```

**Inspeccioná la entrada del reporte generado:**

```console
$ kubectl get polr -n dev-alice -o jsonpath='{.items[0].results[0]}' | jq
{
  "message": "validation error: The label 'team' is required ...",
  "policy": "require-team-label",
  "rule": "check-team-label",
  "result": "fail",
  "scored": true,
  "severity": "medium",
  "source": "kyverno"
}
```

**Kyverno CLI — validá las configuraciones offline, antes de que siquiera toquen el clúster** (este es el fallar-rápido que el examen premia):

```console
$ kyverno apply require-team-label.yaml --resource bad-pod.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy require-team-label -> resource default/Pod/nginx failed:
1. check-team-label: validation error: The label 'team' is required ...

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

---

## 6. Verificación y diagnóstico de fallos

**A) "Mi política se aplicó pero nada se bloquea."** Recorré la escalera de configuraciones:

```console
# 1) Is the action actually Enforce (not the Audit default)?
$ kubectl get cpol require-team-label -o jsonpath='{.spec.rules[0].validate.failureAction}{"\n"}'
Enforce

# 2) Is the webhook wired for the right kind?
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[0].rules[*].resources}{"\n"}'
["pods","deployments","statefulsets", ... ]

# 3) Is the target namespace being excluded/overridden?
$ kubectl get cpol require-team-label -o jsonpath='{.spec.rules[0].validate.failureActionOverrides}{"\n"}'
```

Causa más común: la regla todavía está en el valor por defecto `Audit`, o el namespace coincide con un bloque `failureActionOverrides`/`exclude`.

**B) "La política no se crea — error de variable exclusiva de admisión."**

```console
$ kubectl apply -f uses-userinfo.yaml
The ClusterPolicy "check-creator" is invalid: spec.rules[0]: variable
'request.userInfo.username' is not allowed in background mode; set spec.background=false
```

Solución: `spec.background: false` (esa regla solo puede correr en admisión de todas formas).

**C) "Los pods de Kyverno están caídos y ahora no se pueden crear Pods."** Esto es `failurePolicy: Fail` haciendo exactamente lo que le dijiste. Confirmá y, si es una emergencia, cambiá a `Ignore` (o escalá Kyverno de nuevo hacia arriba):

```console
$ kubectl get pods -n kyverno
NAME                                         READY   STATUS             RESTARTS   AGE
kyverno-admission-controller-7d8...          0/1     CrashLoopBackOff   6          4m

$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].failurePolicy}{"\n"}'
Fail Ignore
```

Lección: combiná `Fail` con **Kyverno HA** (`replicaCount: 3`, PodDisruptionBudget, anti-afinidad de nodos) para que fail-closed nunca signifique fail-cluster.

**D) "Admisiones lentas / denegaciones intermitentes bajo carga."** El webhook está agotando el tiempo; con `Fail`, los timeouts se convierten en rechazos. Inspeccioná y aumentá el presupuesto:

```console
$ kubectl get cpol require-team-label -o jsonpath='{.spec.webhookConfiguration.timeoutSeconds}{"\n"}'
10
$ kubectl logs -n kyverno deploy/kyverno-admission-controller | grep -i "webhook.*timeout"
```

**E) Confirmá que los escaneos en segundo plano están corriendo** (para políticas `Audit`/reporte):

```console
$ kubectl get cpolr,polr -A
NAMESPACE   NAME                              PASS   FAIL   WARN   ERROR   SKIP   AGE
default     polr-ns-default                   118    3      0      0       2      12m
            cpolr                              402    9      0      0       5      12m
```

Reportes obsoletos o ausentes para objetos viejos ⇒ verificá que `spec.background` sea `true` y que la regla no referencie contexto exclusivo de admisión.

---

## 7. Referencia rápida — las configuraciones comunes de un vistazo

| Configuración | Ubicación | Por defecto | Controla |
|---|---|---|---|
| `validationFailureAction` / `validate.failureAction` | `spec` (dep.) → `rules[].validate` (1.11+) | `Audit` | Bloquear vs reportar en caso de violación |
| `validationFailureActionOverrides` / `validate.failureActionOverrides` | igual | – | Overrides de acción por namespace |
| `failurePolicy` | `spec` / `spec.webhookConfiguration` | `Fail` | Comportamiento del API server ante error/timeout del webhook |
| `webhookTimeoutSeconds` / `webhookConfiguration.timeoutSeconds` | `spec` | `10` (1–30) | Presupuesto de respuesta del webhook |
| `background` | `spec` | `true` | Participar en escaneos en segundo plano de recursos existentes |
| `admission` | `spec` | `true` | Evaluar en la ruta de admisión |
| `applyRules` | `spec` | `All` | Evaluar todas las reglas vs detenerse tras la primera coincidencia |
| `schemaValidation` | `spec` | `true` | Validar patrones contra el esquema del objetivo |
| `generateExisting` | `spec` | `false` | Aplicar reglas generate a recursos preexistentes |
| `mutateExistingOnPolicyUpdate` | `spec` | `false` | Mutar recursos existentes en la actualización de la política |
| `match` / `exclude` | `rules[]` | – | Selección de recursos (`any`/`all`) |
| `preconditions` | `rules[]` | – | Filtrado de grano fino JMESPath/CEL |
| `pod-policies.kyverno.io/autogen-controllers` | `metadata.annotations` | todos los controladores | Alcance de autogen para reglas que coinciden con Pod |

---

## Referencias

- Kyverno — Common / Policy Settings: https://kyverno.io/docs/writing-policies/policy-settings/
- Kyverno — Writing Policies (overview): https://kyverno.io/docs/writing-policies/
- Kyverno — Selecting Resources (`match`/`exclude`): https://kyverno.io/docs/writing-policies/match-exclude/
- Kyverno — Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — Auto-Gen Rules for Pod Controllers: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — Validate rules (`failureAction`, patterns): https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Mutate / Generate existing resources: https://kyverno.io/docs/writing-policies/mutate/ · https://kyverno.io/docs/writing-policies/generate/
- Kyverno CLI (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Kubernetes — Dynamic Admission Control (`failurePolicy`, `timeoutSeconds`, `matchConditions`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- CNCF KCA Curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf