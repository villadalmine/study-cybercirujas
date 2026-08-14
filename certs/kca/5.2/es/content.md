# Tema 5.2 — Preconditions

**Certificación:** KCA (Kyverno Certified Associate) · **Peso en el examen:** 2.91 %
**Prerrequisitos conceptuales:** anatomía de `ClusterPolicy` / `Policy`, `match`/`exclude`, variables y JMESPath, ciclo de admisión de Kubernetes.

---

## 1. Motivación: el problema arquitectónico

### 1.1 Dónde falla `match` en producción

Un `match` block de Kyverno es un **selector estructural**: GVK, nombres, namespaces, `namespaceSelector`, `selector` (labels del objeto), `subjects`, `roles`, `clusterRoles`, `operations`. Es declarativo, barato y — esto es lo importante — **es lo que Kyverno usa para generar dinámicamente las reglas del `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`**. Si un recurso no cae dentro de un `match`, el kube-apiserver ni siquiera abre la conexión TLS hacia Kyverno.

Lo que `match` **no** puede expresar:

- Lógica entre campos del mismo objeto: *"solo si `spec.replicas` es menor que el valor anterior"*.
- Aritmética o comparación de cantidades: *"solo si el request de memoria supera 4Gi"*.
- Comparaciones temporales: *"solo si el namespace tiene más de 7 días"*.
- Decisiones que dependen de **datos externos**: un ConfigMap de allowlist, una llamada a la API, metadata de un registry OCI.
- Lógica booleana compuesta arbitraria (`(A ∨ B) ∧ ¬C`) sobre campos que no son labels.

El caso típico de producción: una plataforma multi-tenant donde una policy de FinOps debe exigir el label `cost-center` **solo** en workloads de namespaces `tier=production`, **solo** en operaciones `CREATE`/`UPDATE`, **excepto** cuando el creador es el service account del cluster-autoscaler, y **solo** si el workload realmente va a consumir recursos (`replicas > 0`). Los dos primeros criterios son `match`; los dos últimos, no.

`preconditions` es el **gate programable a nivel de regla**: una expresión booleana evaluada sobre el `AdmissionReview` completo y sobre el `context` de la regla, que decide si el cuerpo de la regla (`validate` / `mutate` / `generate` / `verifyImages`) se ejecuta o se **saltea**.

### 1.2 El pipeline de evaluación — y por qué el orden cuesta dinero

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 1. kube-apiserver                                                        │
│    Selecciona webhooks a partir de rules/namespaceSelector/objectSelector│
│    generados por Kyverno desde los match/exclude de TODAS las policies.  │
│    ── Filtrar acá cuesta 0 ms de red. ────────────────────────────────── │
└───────────────────────────────┬──────────────────────────────────────────┘
                                │ AdmissionReview (HTTP/TLS)
┌───────────────────────────────▼──────────────────────────────────────────┐
│ 2. Kyverno admission controller — engine                                 │
│    2a. Filtrado de recursos globales (resourceFilters en el ConfigMap)   │
│    2b. Por cada policy: spec.applyRules (One | All)                      │
│    2c. Por cada rule: evaluación de match / exclude   ← en proceso, µs   │
│    2d. Carga de context entries (configMap, apiCall, imageRegistry,      │
│        variable, globalReference)              ← puede ser E/S de red    │
│    2e. preconditions                           ← ESTE TEMA              │
│    2f. Cuerpo de la regla: validate / mutate / generate / verifyImages   │
└──────────────────────────────────────────────────────────────────────────┘
```

Consecuencias operativas que se evalúan en el examen y duelen en producción:

| Decisión | Efecto en el apiserver | Efecto en Kyverno | Efecto en latencia p99 de admisión |
|---|---|---|---|
| Filtrar en `match` / `namespaceSelector` | El webhook **no se invoca** | Nada | Cero |
| Filtrar en `preconditions` | El webhook **sí se invoca** | Deserializa, evalúa context y preconditions | Round-trip completo + JMESPath |
| Filtrar en `validate.deny.conditions` | Se invoca | Ejecuta todo el cuerpo | Igual que precondition, pero el resultado es `fail`, no `skip` |

**Regla de arquitectura:** todo lo que se pueda expresar en `match`/`exclude` va en `match`/`exclude`. `preconditions` es para lo que no se puede. Un precondition no reduce tráfico de webhook — solo reduce trabajo dentro de Kyverno y mantiene los policy reports limpios.

**Segunda regla:** los `context` entries se resuelven en el paso 2d. Un `apiCall` que alimenta un precondition se paga en cada request de admisión que llega hasta esa regla. Las versiones modernas de Kyverno difieren la carga del context hasta la primera referencia real, pero si el precondition **es** quien referencia el context, no hay diferimiento posible. Las dos mitigaciones reales son: (a) mover el filtro a `namespaceSelector`, y (b) usar `GlobalContextEntry` (Kyverno ≥ 1.11), que cachea el resultado de la llamada a la API con un `refreshInterval` y lo comparte entre todas las policies.

---

## 2. Anatomía de un precondition

### 2.1 Estructura canónica

```yaml
spec:
  rules:
    - name: mi-regla
      match: { ... }
      exclude: { ... }
      context: [ ... ]
      preconditions:
        all:                       # AND lógico entre todas las entradas
          - key: <valor o variable>
            operator: <Operador>
            value: <valor o variable>
        any:                       # OR lógico entre todas las entradas
          - key: ...
            operator: ...
            value: ...
      validate: { ... }            # o mutate / generate / verifyImages
```

### 2.2 Tabla de verdad de `any` / `all`

| `all` presente | `any` presente | Regla se ejecuta si… |
|---|---|---|
| Sí | No | **Todas** las condiciones de `all` son verdaderas |
| No | Sí | **Al menos una** condición de `any` es verdadera |
| Sí | Sí | `(OR de any)` **AND** `(AND de all)` — ambos bloques deben satisfacerse |
| No | No | Siempre (no hay gate) |

> La forma legacy `preconditions:` como lista plana (sin `any`/`all`) equivale a un `all` implícito. Está deprecada desde Kyverno 1.4; en policies nuevas es un error de estilo y en revisiones de código debe rechazarse.

### 2.3 Catálogo completo de operadores

| Operador | Tipo de `key` | Tipo de `value` | Semántica | Wildcards |
|---|---|---|---|---|
| `Equals` | escalar, objeto, array | mismo tipo | igualdad (profunda para objetos/arrays) | sí (`*`, `?`) en strings |
| `NotEquals` | ídem | ídem | negación de `Equals` | sí |
| `AnyIn` | escalar o array | array | **al menos un** elemento de `key` ∈ `value` | sí |
| `AllIn` | escalar o array | array | **todos** los elementos de `key` ∈ `value` | sí |
| `AnyNotIn` | escalar o array | array | **al menos un** elemento de `key` ∉ `value` | sí |
| `AllNotIn` | escalar o array | array | **ningún** elemento de `key` ∈ `value` | sí |
| `GreaterThan` | número o quantity | mismo | `key > value` | no |
| `GreaterThanOrEquals` | número o quantity | mismo | `key >= value` | no |
| `LessThan` | número o quantity | mismo | `key < value` | no |
| `LessThanOrEquals` | número o quantity | mismo | `key <= value` | no |
| `DurationGreaterThan` | duración o segundos | mismo | `key > value` | no |
| `DurationGreaterThanOrEquals` | ídem | ídem | `key >= value` | no |
| `DurationLessThan` | ídem | ídem | `key < value` | no |
| `DurationLessThanOrEquals` | ídem | ídem | `key <= value` | no |

Notas de tipos que producen incidentes reales:

- **Quantities.** Los operadores numéricos aceptan strings con formato `resource.Quantity` de Kubernetes: `"4Gi"`, `"500m"`, `"1.5"`. Es lo que permite `key: "{{ request.object.spec.containers[0].resources.limits.memory }}"` con `operator: GreaterThan` y `value: "4Gi"` sin conversión manual.
- **Duraciones.** Formato Go (`"30m"`, `"1h30m"`, `"168h"`) o número entero interpretado como segundos.
- **Coerción.** Si `key` resuelve a `"10"` (string) y `value` es `10` (número YAML), Kyverno intenta la conversión, pero el comportamiento es más frágil que forzarlo explícitamente. En comparaciones numéricas sobre campos que pueden venir como string, usar `to_number()`:
  `key: "{{ to_number(request.object.metadata.annotations.\"example.com/tier\" || '0') }}"`.
- **`In` / `NotIn` fueron removidos.** Migración mecánica:

| Legacy | Reemplazo | Motivo |
|---|---|---|
| `In` | `AnyIn` | la semántica de `In` sobre arrays era ambigua |
| `NotIn` | `AnyNotIn` (o `AllNotIn` según intención) | ídem |

### 2.4 Variables disponibles en un precondition

| Variable | Disponible en admisión | Disponible en background scan | Notas |
|---|---|---|---|
| `request.operation` | sí (`CREATE`/`UPDATE`/`DELETE`/`CONNECT`) | **no** | usar siempre `\|\| 'BACKGROUND'` |
| `request.object` | sí (`null` en `DELETE`) | sí | en `DELETE` el objeto vive en `oldObject` |
| `request.oldObject` | sí (solo `UPDATE`/`DELETE`) | no | |
| `request.namespace`, `request.name` | sí | parcial | |
| `request.kind.{group,version,kind}` | sí | sí | |
| `request.subResource` | sí | no | `scale`, `status`, `exec`… |
| `request.dryRun` | sí | no | útil para excluir server-side dry-run |
| `request.userInfo.{username,groups,uid,extra}` | sí | **no** | fuerza `background: false` |
| `request.roles`, `request.clusterRoles` | sí | **no** | ídem |
| `serviceAccountName`, `serviceAccountNamespace` | sí | **no** | ídem |
| `images.{containers,initContainers,ephemeralContainers}` | sí | sí | mapa con `registry`, `path`, `name`, `tag`, `digest`, `reference` |
| `element`, `elementIndex` | solo dentro de `foreach` | ídem | |
| `<nombre del context entry>` | sí | sí (salvo que dependa de admission-only) | |

**Restricción de background mode:** si un precondition referencia `request.userInfo`, `request.roles`, `request.clusterRoles`, `serviceAccountName` o `request.operation` sin default, la policy **debe** declarar `background: false`. El webhook de validación de policies de Kyverno rechaza la creación en caso contrario.

### 2.5 El patrón de no-existencia (la causa #1 de `result: error`)

JMESPath devuelve `null` para una ruta ausente, pero Kyverno trata la **falla de sustitución de variable** como error de regla, y con `failurePolicy: Fail` eso **bloquea la operación**. Un precondition sin defaults es una bomba de tiempo.

```yaml
# MAL — si el Pod no tiene labels, la regla falla con error, no con skip
- key: "{{ request.object.metadata.labels.team }}"
  operator: Equals
  value: platform

# BIEN — default explícito con el operador || de JMESPath
- key: "{{ request.object.metadata.labels.team || '' }}"
  operator: Equals
  value: platform

# BIEN — literales JSON con backticks para no-strings
- key: "{{ request.object.spec.replicas || `0` }}"
  operator: GreaterThan
  value: 0

- key: "{{ request.object.spec.hostNetwork || `false` }}"
  operator: Equals
  value: false

# BIEN — claves con puntos o barras deben ir entre comillas dobles dentro del JMESPath
- key: "{{ request.object.metadata.labels.\"app.kubernetes.io/name\" || 'unknown' }}"
  operator: NotEquals
  value: unknown

# BIEN — conteo en vez de comparación de objetos ausentes
- key: "{{ length(request.object.spec.containers[?securityContext.runAsNonRoot == `true`]) }}"
  operator: LessThan
  value: "{{ length(request.object.spec.containers) }}"
```

### 2.6 Dónde más aparece el mismo motor de condiciones

El bloque `key/operator/value` con `any`/`all` es un tipo compartido en toda la API de Kyverno:

| Ubicación | Campo | Momento de evaluación | Resultado si falso |
|---|---|---|---|
| Regla (cualquier tipo) | `spec.rules[*].preconditions` | antes del cuerpo de la regla | `skip` |
| Validate | `spec.rules[*].validate.deny.conditions` | dentro del cuerpo | `pass` (si es falso) / `fail` (si es verdadero) |
| Validate foreach | `spec.rules[*].validate.foreach[*].preconditions` | por iteración | se saltea **ese elemento** |
| Mutate foreach | `spec.rules[*].mutate.foreach[*].preconditions` | por iteración | no muta ese elemento |
| Cleanup policies | `spec.conditions` (variable `target`) | en cada tick del `schedule` | no borra |

---

## 3. Comparativas técnicas y trade-offs

### 3.1 ¿Dónde poner el filtro?

| Mecanismo | Expresividad | Costo | Resultado en el report | Se aplica en background scan | Cuándo usarlo |
|---|---|---|---|---|---|
| `match` / `exclude` | GVK, nombres, namespaces, label selectors, subjects/roles, operations | **Nulo** (filtra en el apiserver) | el recurso no aparece | sí | Siempre que alcance |
| `match.resources.namespaceSelector` | labels del Namespace | Nulo (selector nativo del webhook) | no aparece | sí | Segmentación por tenant/tier |
| `preconditions` | JMESPath arbitrario sobre request + context | Round-trip + evaluación | `skip` + `preconditions not met` | sí (con defaults) | Lógica cruzada, aritmética, datos externos |
| `validate.deny.conditions` | igual que preconditions | igual | `pass` o `fail` | sí | Cuando la condición **es** la decisión |
| `PolicyException` (CRD aparte) | match del recurso + policy/rule a exceptuar | Nulo extra | `skip` | sí | Excepciones gestionadas por el equipo dueño del workload, con su propio RBAC y ciclo de vida |
| `matchConditions` (CEL nativo, ValidatingAdmissionPolicy) | CEL sobre `object`/`oldObject`/`request`/`authorizer` | **Nulo de red** (in-process en el apiserver) | no genera evento | N/A | Cuando no se necesitan datos externos y se busca latencia mínima |

**Trade-off central `preconditions` vs `matchConditions` de CEL:**

| Dimensión | Kyverno `preconditions` | K8s `matchConditions` (VAP) |
|---|---|---|
| Lenguaje | JMESPath + funciones custom de Kyverno | CEL |
| Ejecución | Fuera del apiserver (webhook) | Dentro del apiserver |
| Latencia añadida | 1 round-trip TLS + evaluación | microsegundos |
| Datos externos (ConfigMap, API, registry OCI) | **Sí** | No (solo `paramRef` a un CRD) |
| Firma de imágenes / attestations | Sí (`verifyImages`) | No |
| Mutación | Sí | Sólo con `MutatingAdmissionPolicy` (más nuevo) |
| Reportes agregados | PolicyReport / ClusterPolicyReport | Eventos + `auditAnnotations` |
| Disponibilidad ante caída del componente | depende de `failurePolicy` | siempre disponible |

En una plataforma madura el patrón ganador es **híbrido**: las verificaciones puramente estructurales y de alto volumen (por ejemplo, "todo Pod debe tener `runAsNonRoot`") se empujan a VAP/CEL o a Pod Security Admission; Kyverno conserva las que necesitan contexto externo, generación o verificación de imágenes — que es exactamente donde `preconditions` gana su lugar. Kyverno ≥ 1.11 puede además **generar** `ValidatingAdmissionPolicy` a partir de policies compatibles, y la conversión sólo es posible cuando los preconditions se pueden traducir a CEL sin datos externos.

### 3.2 `preconditions` vs `deny.conditions`: no son intercambiables

```yaml
# A) preconditions — "esta situación no me incumbe"
preconditions:
  all:
    - key: "{{ request.operation || 'BACKGROUND' }}"
      operator: Equals
      value: UPDATE
# → si no es UPDATE: result=skip, no bloquea, no cuenta como fallo
```

```yaml
# B) deny.conditions — "esta situación es exactamente lo que prohíbo"
validate:
  deny:
    conditions:
      all:
        - key: "{{ request.userInfo.username }}"
          operator: AnyNotIn
          value: [ "system:serviceaccount:platform-release:release-bot" ]
# → si se cumple: result=fail, bloquea con validationFailureAction=Enforce
```

| | `preconditions` | `deny.conditions` |
|---|---|---|
| Polaridad | verdadero ⇒ **continuar** | verdadero ⇒ **denegar** |
| Resultado en PolicyReport | `skip` | `fail` |
| Cuenta para SLO de compliance | no | sí |
| Emite evento `PolicyViolation` | no | sí |
| Afecta métrica `rule_result` | `skip` | `fail` |

Confundirlos produce un anti-patrón muy común: dashboards que muestran 100 % de compliance porque todas las reglas están en `skip`.

---

## 4. Manifiestos completos

### 4.1 Gate de operación + gate numérico (validate)

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-cost-center
  annotations:
    policies.kyverno.io/title: Require cost-center label on production workloads
    policies.kyverno.io/category: FinOps
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Deployment, StatefulSet
    policies.kyverno.io/description: >-
      Exige el label finops.example.com/cost-center en workloads de namespaces
      etiquetados tier=production. La regla se saltea en DELETE y en workloads
      escalados a cero, porque no generan costo de cómputo.
spec:
  validationFailureAction: Enforce   # >=1.13: spec.rules[*].validate.failureAction
  background: true
  admission: true
  failurePolicy: Fail
  rules:
    - name: check-cost-center
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
              operations:
                - CREATE
                - UPDATE
              namespaceSelector:
                matchLabels:
                  tier: production
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
          - subjects:
              - kind: ServiceAccount
                name: cluster-autoscaler
                namespace: kube-system
      preconditions:
        all:
          # 1) Nunca evaluar borrados; 'BACKGROUND' cubre el scan periódico.
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
              - BACKGROUND
          # 2) Un workload escalado a cero no consume presupuesto.
          - key: "{{ request.object.spec.replicas || `0` }}"
            operator: GreaterThan
            value: 0
          # 3) Los workloads marcados como experimento tienen 30 días de gracia,
          #    gestionados por otra policy.
          - key: "{{ request.object.metadata.labels.\"finops.example.com/experiment\" || 'false' }}"
            operator: NotEquals
            value: "true"
      validate:
        message: >-
          El label finops.example.com/cost-center es obligatorio en namespaces
          tier=production. Valor recibido:
          {{ request.object.metadata.labels."finops.example.com/cost-center" || 'ninguno' }}
        pattern:
          metadata:
            labels:
              finops.example.com/cost-center: "cc-?*"
```

### 4.2 Mutación condicional opt-in (y el efecto del autogen)

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-egress-proxy-env
  annotations:
    policies.kyverno.io/title: Inject egress proxy environment variables
    policies.kyverno.io/category: Networking
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet,Job,CronJob
spec:
  background: false
  admission: true
  rules:
    - name: add-proxy-env
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: NotEquals
            value: DELETE
          # Opt-in explícito: la plataforma no inyecta nada sin consentimiento.
          - key: "{{ request.object.metadata.annotations.\"net.example.com/egress-proxy\" || 'disabled' }}"
            operator: Equals
            value: enabled
          # hostNetwork rompe la resolución del Service del proxy.
          - key: "{{ request.object.spec.hostNetwork || `false` }}"
            operator: Equals
            value: false
          # No inyectar en Pods que ya traen la variable definida por el usuario.
          - key: "{{ length(request.object.spec.containers[?env[?name=='HTTPS_PROXY']]) }}"
            operator: Equals
            value: 0
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                env:
                  - name: HTTPS_PROXY
                    value: http://egress-proxy.netsec.svc.cluster.local:3128
                  - name: HTTP_PROXY
                    value: http://egress-proxy.netsec.svc.cluster.local:3128
                  - name: NO_PROXY
                    value: .svc,.cluster.local,localhost,127.0.0.1,10.0.0.0/8,169.254.169.254
```

**Autogen y preconditions — el footgun clásico.** Como la regla hace `match` sobre `Pod`, Kyverno genera automáticamente reglas espejo para los controllers listados en la anotación, y **reescribe las rutas de las variables** dentro del cuerpo de la regla *y de los preconditions*:

| En la regla original (Pod) | En la regla autogenerada (Deployment) |
|---|---|
| `request.object.metadata.annotations` | `request.object.spec.template.metadata.annotations` |
| `request.object.spec.hostNetwork` | `request.object.spec.template.spec.hostNetwork` |
| `request.object.spec.containers` | `request.object.spec.template.spec.containers` |

Un precondition que referencia metadata que **no** vive dentro del `podTemplate` (por ejemplo `request.object.spec.replicas`, que sólo existe en el Deployment) queda roto en una de las dos variantes. Cuando la regla necesita mirar campos del controller, hay que escribir reglas separadas con `match` sobre el controller y desactivar el autogen con `pod-policies.kyverno.io/autogen-controllers: none`.

### 4.3 Precondition sobre estado previo + `deny.conditions` sobre identidad

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-prod-scale-down
  annotations:
    policies.kyverno.io/title: Restrict scale-down of production workloads
    policies.kyverno.io/category: Reliability
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: false          # obligatorio: se usa request.userInfo
  admission: true
  failurePolicy: Fail
  rules:
    - name: only-release-bot-scales-down
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
              operations:
                - UPDATE
              namespaceSelector:
                matchLabels:
                  tier: production
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: Equals
            value: UPDATE
          # El gate: sólo importa si el nuevo replicas es MENOR que el anterior.
          - key: "{{ request.object.spec.replicas || `0` }}"
            operator: LessThan
            value: "{{ request.oldObject.spec.replicas || `0` }}"
          # Escalar a cero se maneja como decommission, con otro flujo.
          - key: "{{ request.object.spec.replicas || `0` }}"
            operator: GreaterThan
            value: 0
          # Los server-side dry-run de `kubectl diff` no se bloquean.
          - key: "{{ request.dryRun || `false` }}"
            operator: Equals
            value: false
      validate:
        message: >-
          Reducir réplicas de {{ request.oldObject.spec.replicas }} a
          {{ request.object.spec.replicas }} en un workload de producción está
          restringido al release bot. Solicitante: {{ request.userInfo.username }}
        deny:
          conditions:
            all:
              - key: "{{ request.userInfo.username }}"
                operator: AnyNotIn
                value:
                  - system:serviceaccount:platform-release:release-bot
                  - system:serviceaccount:kube-system:horizontal-pod-autoscaler
              - key: "{{ request.userInfo.groups }}"
                operator: AllNotIn
                value:
                  - system:masters
                  - sre-oncall
```

Lectura: `preconditions` define **la situación** (un scale-down real, no un dry-run, no un decommission); `deny.conditions` define **la prohibición** (quién no puede hacerlo). Separarlos hace que el PolicyReport distinga *"no aplicaba"* de *"aplicaba y falló"*.

### 4.4 `preconditions` dentro de un `foreach`

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: third-party-image-hardening
  annotations:
    policies.kyverno.io/title: Non-root enforcement for third-party images
    policies.kyverno.io/category: Pod Security
spec:
  validationFailureAction: Audit
  background: true
  admission: true
  rules:
    - name: non-root-for-external-images
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: NotEquals
            value: DELETE
      validate:
        message: >-
          El container '{{ element.name }}' usa la imagen externa
          '{{ element.image }}' y debe declarar securityContext.runAsNonRoot=true.
        foreach:
          - list: "request.object.spec.containers"
            preconditions:
              all:
                # Las imágenes del registry interno ya se construyen sin root.
                - key: "{{ element.image }}"
                  operator: NotEquals
                  value: "registry.internal.example.com/*"
                # Los sidecars de la malla de servicio los gestiona otro equipo.
                - key: "{{ element.name }}"
                  operator: AllNotIn
                  value:
                    - istio-proxy
                    - linkerd-proxy
            pattern:
              securityContext:
                runAsNonRoot: true
```

Un precondition falso dentro de `foreach` saltea **ese elemento**, no la regla completa: los demás containers se siguen evaluando. Es la diferencia entre un `continue` y un `return`.

### 4.5 Precondition con datos externos y `GlobalContextEntry`

```yaml
---
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: tenant-registry-allowlist
spec:
  apiCall:
    urlPath: "/api/v1/namespaces/platform-config/configmaps/registry-allowlist"
    refreshInterval: 5m
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-registry-allowlist
spec:
  validationFailureAction: Enforce
  background: true
  admission: true
  rules:
    - name: images-from-allowed-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
      context:
        - name: allowlist
          globalReference:
            name: tenant-registry-allowlist
            jmesPath: "data.registries | split(@, ',')"
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: NotEquals
            value: DELETE
          # Gate barato: si TODOS los registries ya están permitidos, no hay
          # nada que validar y la regla se saltea antes del foreach.
          - key: "{{ images.containers.*.registry }}"
            operator: AnyNotIn
            value: "{{ allowlist }}"
      validate:
        message: >-
          El registry '{{ element.registry }}' no está en la allowlist
          ({{ allowlist }}).
        foreach:
          - list: "images.containers.*"
            deny:
              conditions:
                all:
                  - key: "{{ element.registry }}"
                    operator: AllNotIn
                    value: "{{ allowlist }}"
```

Sin `GlobalContextEntry`, el `apiCall` al ConfigMap se ejecutaría en cada admisión de Pod del cluster. Con él, se resuelve una vez cada 5 minutos y se comparte. En clusters con alta rotación de Pods (batch, CI) la diferencia en p99 de admisión es de un orden de magnitud.

### 4.6 Preconditions en una regla `generate`

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-network-isolation
spec:
  background: true
  admission: true
  rules:
    - name: generate-default-deny-ingress
      match:
        any:
          - resources:
              kinds:
                - Namespace
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.\"platform.example.com/managed\" || 'false' }}"
            operator: Equals
            value: "true"
          - key: "{{ request.object.metadata.name }}"
            operator: NotEquals
            value: "kube-*"
          - key: "{{ request.object.metadata.labels.\"platform.example.com/network-policy\" || 'default' }}"
            operator: NotEquals
            value: "opt-out"
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          metadata:
            labels:
              app.kubernetes.io/managed-by: kyverno
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
```

**Advertencia operativa:** con `synchronize: true`, el recurso downstream está atado al ciclo de vida del trigger. Cambiar un label del Namespace de modo que el precondition pase a ser falso puede provocar que Kyverno reconcilie y **elimine** la NetworkPolicy generada. Un cambio de precondition en una policy de `generate` nunca se aplica directo a producción: se prueba en staging observando los `UpdateRequest` (`kubectl get updaterequests -n kyverno`).

### 4.7 El mismo motor en una CleanupPolicy

```yaml
---
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-stale-preview-namespaces
spec:
  schedule: "0 3 * * *"
  match:
    any:
      - resources:
          kinds:
            - Namespace
          selector:
            matchLabels:
              platform.example.com/env: preview
  conditions:
    all:
      - key: "{{ time_since('', target.metadata.creationTimestamp, '') }}"
        operator: DurationGreaterThan
        value: 168h
      - key: "{{ target.metadata.annotations.\"platform.example.com/pinned\" || 'false' }}"
        operator: Equals
        value: "false"
```

En `CleanupPolicy` el objeto se llama `target`, no `request.object`, y el campo se llama `conditions` en lugar de `preconditions` — pero los operadores, la estructura `any`/`all` y la semántica de defaults son idénticos.

---

## 5. Comandos, salidas y verificación

> Las cadenas exactas de logs y mensajes varían entre versiones de Kyverno. Lo estable, y lo que conviene usar como aserción en CI, es el campo `result` del PolicyReport y la razón `preconditions not met`.

### 5.1 Preparación del entorno

```console
$ kind create cluster --name kca-52 --image kindest/node:v1.30.0
Creating cluster "kca-52" ...
Set kubectl context to "kind-kca-52"

$ helm repo add kyverno https://kyverno.github.io/kyverno/
"kyverno" has been added to your repositories

$ helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace
NAME: kyverno
LAST DEPLOYED: Thu Aug 13 09:12:44 2026
NAMESPACE: kyverno
STATUS: deployed

$ kubectl -n kyverno get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
kyverno-admission-controller     reg.kyverno.io/kyverno/kyverno:v1.12.5
kyverno-background-controller    reg.kyverno.io/kyverno/background-controller:v1.12.5
kyverno-cleanup-controller       reg.kyverno.io/kyverno/cleanup-controller:v1.12.5
kyverno-reports-controller       reg.kyverno.io/kyverno/reports-controller:v1.12.5

$ kubectl create ns prod-payments && kubectl label ns prod-payments tier=production
namespace/prod-payments created
namespace/prod-payments labeled
```

### 5.2 Aplicar y verificar el estado de la policy

```console
$ kubectl apply -f 01-require-cost-center.yaml
clusterpolicy.kyverno.io/require-cost-center created

$ kubectl get cpol require-cost-center
NAME                  ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-cost-center   true        true         Enforce           True    9s    Ready
```

`READY=True` significa que Kyverno registró la regla en el webhook. Si queda en `False`, el problema es de la policy, no del precondition:

```console
$ kubectl get cpol require-cost-center -o jsonpath='{.status.conditions}' | jq
[
  {
    "message": "Ready",
    "reason": "Succeeded",
    "status": "True",
    "type": "Ready"
  }
]
```

### 5.3 Camino 1 — el precondition se cumple, la validación bloquea

```console
$ kubectl -n prod-payments create deployment web --image=registry.internal.example.com/web:1.4.2
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Deployment/prod-payments/web was blocked due to the following policies

require-cost-center:
  check-cost-center: 'validation error: El label finops.example.com/cost-center es
    obligatorio en namespaces tier=production. Valor recibido: ninguno. rule
    check-cost-center failed at path /metadata/labels/finops.example.com/cost-center/'
```

### 5.4 Camino 2 — el precondition NO se cumple, la regla se saltea

```console
$ cat batch-worker.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: batch-worker
  namespace: prod-payments
spec:
  replicas: 0
  selector:
    matchLabels:
      app: batch-worker
  template:
    metadata:
      labels:
        app: batch-worker
    spec:
      containers:
        - name: worker
          image: registry.internal.example.com/batch-worker:0.9.1

$ kubectl apply -f batch-worker.yaml
deployment.apps/batch-worker created
```

Se creó sin el label obligatorio: el precondition `replicas > 0` fue falso. La evidencia está en el PolicyReport:

```console
$ kubectl -n prod-payments get policyreport -o wide
NAME                                   KIND         NAME           PASS   FAIL   WARN   ERROR   SKIP   AGE
9d51e5b4-8f4a-4c0e-9c8f-1c2a3b4d5e6f   Deployment   batch-worker   0      0      0      0       1      14s

$ kubectl -n prod-payments get polr 9d51e5b4-8f4a-4c0e-9c8f-1c2a3b4d5e6f \
    -o jsonpath='{.results[0]}' | jq
{
  "message": "preconditions not met",
  "policy": "require-cost-center",
  "result": "skip",
  "rule": "check-cost-center",
  "scored": true,
  "source": "kyverno",
  "timestamp": {
    "nanos": 0,
    "seconds": 1755086014
  }
}
```

`message: preconditions not met` es **la firma inequívoca** de que el gate se evaluó y dio falso. Si en cambio el mensaje habla de sustitución de variables, el precondition está roto, no cumplido.

### 5.5 Verificación offline con el CLI (lo que se pide en el examen)

```console
$ kyverno version
Version: v1.12.5
Time: 2026-06-18T10:31:02Z
Git commit ID: 8a3f21b

$ kyverno apply 01-require-cost-center.yaml --resource batch-worker.yaml

Applying 1 policy rule(s) to 1 resource(s)...

pass: 0, fail: 0, warn: 0, error: 0, skip: 1
```

Con reporte estructurado, útil para pipelines:

```console
$ kyverno apply 01-require-cost-center.yaml --resource batch-worker.yaml --policy-report
Applying 1 policy rule(s) to 1 resource(s)...
----------------------------------------------------------------------
POLICY REPORT:
----------------------------------------------------------------------
apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: merged
results:
- message: preconditions not met
  policy: require-cost-center
  resources:
  - apiVersion: apps/v1
    kind: Deployment
    name: batch-worker
    namespace: prod-payments
  result: skip
  rule: check-cost-center
  scored: true
  source: kyverno
summary:
  error: 0
  fail: 0
  pass: 0
  skip: 1
  warn: 0
```

#### Simular `request.operation`, `oldObject` y `userInfo`

El CLI no reconstruye un `AdmissionReview` real. Los preconditions que dependen de `request.operation`, `request.oldObject` o `request.userInfo` requieren archivos auxiliares.

```console
$ cat values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: simulate-scale-down
spec:
  globalValues:
    request.operation: UPDATE
    request.dryRun: false
  policies:
    - name: restrict-prod-scale-down
      resources:
        - name: web
          values:
            request.oldObject.spec.replicas: 6

$ cat dev-user.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: UserInfo
metadata:
  name: dev-user
spec:
  clusterRoles:
    - view
  userInfo:
    username: alice@example.com
    groups:
      - developers
      - system:authenticated

$ kyverno apply 03-restrict-prod-scale-down.yaml \
    --resource web-scaled-to-2.yaml \
    --values-file values.yaml \
    --userinfo dev-user.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy restrict-prod-scale-down -> resource prod-payments/Deployment/web failed:
1. only-release-bot-scales-down: Reducir réplicas de 6 a 2 en un workload de
   producción está restringido al release bot. Solicitante: alice@example.com

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

#### Aserción del `skip` en CI con `kyverno test`

```console
$ cat kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: preconditions-gate
policies:
  - 01-require-cost-center.yaml
resources:
  - resources.yaml
variables: values.yaml
results:
  # replicas > 0 y sin label -> la regla se aplica y falla
  - policy: require-cost-center
    rule: check-cost-center
    kind: Deployment
    resources:
      - web
    result: fail
  # replicas == 0 -> precondition falso -> skip
  - policy: require-cost-center
    rule: check-cost-center
    kind: Deployment
    resources:
      - batch-worker
    result: skip
  # label experiment=true -> precondition falso -> skip
  - policy: require-cost-center
    rule: check-cost-center
    kind: Deployment
    resources:
      - spike-arima
    result: skip

$ kyverno test .

Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 3 resources ...
  Checking results ...

│───│─────────────────────│───────────────────│──────────────────────────────────│────────│
│ # │ POLICY              │ RULE              │ RESOURCE                         │ RESULT │
│───│─────────────────────│───────────────────│──────────────────────────────────│────────│
│ 1 │ require-cost-center │ check-cost-center │ apps/v1/Deployment/web           │ Pass   │
│ 2 │ require-cost-center │ check-cost-center │ apps/v1/Deployment/batch-worker  │ Pass   │
│ 3 │ require-cost-center │ check-cost-center │ apps/v1/Deployment/spike-arima   │ Pass   │
│───│─────────────────────│───────────────────│──────────────────────────────────│────────│

Test Summary: 3 tests passed and 0 tests failed
```

La columna `RESULT` dice `Pass` cuando **el resultado observado coincide con el esperado**; el resultado esperado del test 2 y 3 era `skip`. Esta distinción se pregunta.

---

## 6. Diagnóstico de fallas

### 6.1 Tabla síntoma → causa → acción

| Síntoma observado | Causa raíz probable | Comando de confirmación |
|---|---|---|
| El recurso ni aparece en el PolicyReport | El webhook no se invocó: `match`, `namespaceSelector` o `resourceFilters` global | `kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o yaml` / `kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}'` |
| `result: skip`, `message: preconditions not met` | El precondition es falso — **esperado**, o bien un path JMESPath mal escrito que devuelve `null` | `kubectl -n <ns> get polr <uid> -o yaml` |
| `result: error`, `Unknown key "x" in path` | Variable sin default; el campo no existe en ese recurso | agregar `\|\| ''` / `` \|\| `0` `` |
| Todo bloqueado, incluso lo que debería saltearse | `failurePolicy: Fail` + error de sustitución en el precondition | `kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller \| grep -i "substitut"` |
| La policy es rechazada al aplicarla | `background: true` con variables admission-only | ver §6.2 |
| Funciona con Pods, se ignora en Deployments (o al revés) | El autogen reescribió las rutas del precondition | `kubectl get cpol <name> -o jsonpath='{.status.autogen}' \| jq` |
| El precondition evalúa bien en admisión y mal en el scan de fondo | `request.operation` sin `\|\| 'BACKGROUND'` | `kubectl -n kyverno logs -l app.kubernetes.io/component=background-controller` |
| Latencia p99 de admisión disparada | `context.apiCall` resuelto antes del precondition en cada request | métricas §6.4 + migrar a `GlobalContextEntry` |
| `GreaterThan` compara mal | tipos mixtos string/número | envolver con `to_number()` |
| Todas las reglas en `skip` y el dashboard dice 100 % compliant | Lógica que debía ir en `deny.conditions` puesta en `preconditions` | `kubectl get polr -A -o json \| jq '[.items[].results[].result] \| group_by(.) \| map({(.[0]): length}) \| add'` |

### 6.2 Rechazo por background mode

```console
$ kubectl apply -f 03-restrict-prod-scale-down.yaml
Error from server: error when creating "03-restrict-prod-scale-down.yaml":
admission webhook "validate-policy.kyverno.svc" denied the request:
spec.rules[0].preconditions: variable "request.userInfo.username" is not allowed.
Set spec.background=false to disable background mode for this policy rule.
```

Corrección: `spec.background: false`. Consecuencia arquitectónica que hay que aceptar conscientemente — esa policy **no** generará PolicyReports para recursos preexistentes, sólo actuará en admisión. Si se necesitan ambas cosas, se parten en dos policies: una con `background: false` que usa `userInfo`, y otra con `background: true` sobre los mismos criterios estructurales.

### 6.3 Inspeccionar las reglas autogeneradas

```console
$ kubectl get cpol inject-egress-proxy-env -o jsonpath='{.status.autogen.rules}' | \
    jq '.[] | {name, preconditions}'
{
  "name": "autogen-add-proxy-env",
  "preconditions": {
    "all": [
      { "key": "{{ request.operation || 'BACKGROUND' }}", "operator": "NotEquals", "value": "DELETE" },
      { "key": "{{ request.object.spec.template.metadata.annotations.\"net.example.com/egress-proxy\" || 'disabled' }}",
        "operator": "Equals", "value": "enabled" },
      { "key": "{{ request.object.spec.template.spec.hostNetwork || `false` }}",
        "operator": "Equals", "value": false }
    ]
  }
}
{
  "name": "autogen-cronjob-add-proxy-env",
  "preconditions": {
    "all": [
      { "key": "{{ request.operation || 'BACKGROUND' }}", "operator": "NotEquals", "value": "DELETE" },
      { "key": "{{ request.object.spec.jobTemplate.spec.template.metadata.annotations.\"net.example.com/egress-proxy\" || 'disabled' }}",
        "operator": "Equals", "value": "enabled" },
      { "key": "{{ request.object.spec.jobTemplate.spec.template.spec.hostNetwork || `false` }}",
        "operator": "Equals", "value": false }
    ]
  }
}
```

Verificar esta salida es obligatorio en cualquier policy con `match` sobre `Pod` y preconditions no triviales.

### 6.4 Métricas y logs

```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &

$ curl -s localhost:8000/metrics | grep 'kyverno_policy_results_total' | grep 'rule_result="skip"'
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-cost-center",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce",resource_kind="Deployment",resource_namespace="prod-payments",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-cost-center",rule_result="skip",rule_type="validate"} 1483

$ curl -s localhost:8000/metrics | grep 'kyverno_policy_execution_duration_seconds_sum' | grep require-cost-center
kyverno_policy_execution_duration_seconds_sum{policy_name="require-cost-center",rule_name="check-cost-center",rule_type="validate"} 4.812
```

Una relación `skip / (pass+fail+skip)` cercana a 1 con `execution_duration` alto es la firma de un filtro mal ubicado: se está pagando el costo completo de la regla para descartarla. La corrección es mover el criterio a `match`/`namespaceSelector`.

Para ver la decisión del engine paso a paso:

```console
$ kubectl -n kyverno patch deploy kyverno-admission-controller --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"-v=4"}]'
deployment.apps/kyverno-admission-controller patched

$ kubectl -n kyverno rollout status deploy/kyverno-admission-controller
deployment "kyverno-admission-controller" successfully rolled out

$ kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller --tail=100 \
    | grep -i precondition
I0813 14:22:07.113455  1 validation.go:118] engine.validate "msg"="skip rule" "kind"="Deployment" "name"="batch-worker" "namespace"="prod-payments" "policy"="require-cost-center" "rule"="check-cost-center" "reason"="preconditions not met"
```

Revertir siempre la verbosidad al terminar — `-v=4` en un cluster con tráfico alto satura el backend de logs:

```console
$ kubectl -n kyverno patch deploy kyverno-admission-controller --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/args/-"}]'
deployment.apps/kyverno-admission-controller patched
```

### 6.5 Checklist de revisión de código para cualquier precondition

1. ¿Este criterio se puede expresar en `match`/`exclude`/`namespaceSelector`? Si sí, movelo.
2. ¿Toda variable tiene un default (`|| ''`, `` || `0` ``, `` || `false` ``, `|| 'BACKGROUND'`)?
3. ¿`request.operation` está protegido contra el background scan?
4. ¿Se usa `request.userInfo`/`roles`/`serviceAccountName`? Entonces `background: false` explícito y documentado.
5. ¿La regla hace `match` sobre `Pod`? Revisar `.status.autogen.rules`.
6. ¿La condición describe **la situación** (precondition) o **la prohibición** (`deny.conditions`)?
7. ¿Hay `context.apiCall` referenciado desde el precondition? Migrar a `GlobalContextEntry`.
8. ¿Existe un caso de test en `kyverno-test.yaml` que asserte `result: skip` para la rama negativa? Sin él, el gate no está cubierto.

---

## 7. Referencias

- **Preconditions (documentación oficial de Kyverno)** — https://kyverno.io/docs/writing-policies/preconditions/
- **Variables y sustitución** — https://kyverno.io/docs/writing-policies/variables/
- **JMESPath en Kyverno y funciones custom (`to_number`, `time_since`, `semver_compare`, `regex_match`)** — https://kyverno.io/docs/writing-policies/jmespath/
- **Match / Exclude** — https://kyverno.io/docs/writing-policies/match-exclude/
- **Validate: `pattern`, `deny.conditions`, `foreach`** — https://kyverno.io/docs/writing-policies/validate/
- **Mutate** — https://kyverno.io/docs/writing-policies/mutate/
- **Generate** — https://kyverno.io/docs/writing-policies/generate/
- **Auto-Gen Rules para Pod controllers** — https://kyverno.io/docs/writing-policies/autogen/
- **External Data Sources: `configMap`, `apiCall`, `imageRegistry`, `globalReference`** — https://kyverno.io/docs/writing-policies/external-data-sources/
- **Cleanup Policies (`spec.conditions`, variable `target`)** — https://kyverno.io/docs/writing-policies/cleanup/
- **Policy Exceptions** — https://kyverno.io/docs/writing-policies/exceptions/
- **Policy Reports** — https://kyverno.io/docs/policy-reports/
- **Kyverno CLI — `apply` (`--values-file`, `--userinfo`, `--policy-report`)** — https://kyverno.io/docs/kyverno-cli/usage/apply/
- **Kyverno CLI — `test` (aserción de `result: skip`)** — https://kyverno.io/docs/kyverno-cli/usage/test/
- **Monitoring y métricas (`kyverno_policy_results_total`, `kyverno_policy_execution_duration_seconds`)** — https://kyverno.io/docs/monitoring/
- **Código fuente del engine (evaluación de condiciones y operadores)** — https://github.com/kyverno/kyverno/tree/main/pkg/engine
- **Especificación JMESPath** — https://jmespath.org/specification.html
- **Kubernetes — Dynamic Admission Control (webhooks, `failurePolicy`, selectors)** — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **Kubernetes — Validating Admission Policy (`matchConditions` en CEL)** — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- **Kubernetes — Referencia de CEL** — https://kubernetes.io/docs/reference/using-api/cel/
- **CNCF — Currículum oficial KCA** — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- **CNCF Curriculum (repositorio)** — https://github.com/cncf/curriculum