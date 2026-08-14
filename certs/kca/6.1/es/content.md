# KCA 6.1 — Policy Reports

> **Dominio 6 · Peso 3.33** — Kyverno Certified Associate
> Nivel: Principal Platform Architect / Senior SRE

---

## 1. El problema arquitectónico: el admission control es un veredicto sin estado, la gobernanza es una pregunta con estado

Un admission webhook responde exactamente una pregunta, una sola vez, para un `AdmissionReview`:

> *«¿Debería permitirse esta petición a la API?»*

Ese veredicto es transitorio. Existe durante el tiempo de un round trip HTTP entre el API server y el webhook, se entrega a quien haya ejecutado `kubectl apply`, y después desaparece. Nada en Kubernetes lo persiste.

Esto está bien para la aplicación (enforcement). Es inútil para la gobernanza. Las preguntas que un equipo de plataforma recibe realmente en producción son todas *con estado* y *retrospectivas*:

| Pregunta formulada en producción | ¿Puede responderla un admission webhook? |
|---|---|
| «¿Cuáles de los 340 workloads violan actualmente `require-run-as-non-root`?» | **No** — nunca los vio; fueron creados antes de que existiera la política. |
| «Si el lunes cambio esta política de `Audit` a `Enforce`, ¿qué se rompe?» | **No** — las decisiones de enforcement no se registran. |
| «El equipo `payments` es dueño de 12 namespaces. ¿Cuál es su puntaje de cumplimiento este sprint?» | **No** — no hay agregación, no hay dimensión de propiedad. |
| «El auditor quiere evidencia de que los namespaces bajo alcance PCI estaban conformes el 2026-07-01.» | **No** — no hay historial, no hay artefacto de evidencia. |
| «¿Este Deployment dejó de violar la política, o alguien agregó una excepción?» | **No** — no hay diff, no hay estado por recurso. |

La brecha es estructural, y produce tres modos de falla extremadamente comunes en clústeres reales:

**Modo de falla 1 — la caída de «Enforce el día uno».** Un equipo escribe una política correcta, la pone en `Enforce` y la aplica a todo el clúster. Los workloads existentes quedan intactos (el admission control no es retroactivo), así que nada parece roto. Tres semanas después se drena un nodo, un ReplicaSet intenta recrear 200 Pods, y *todos y cada uno son rechazados*. La política nunca estuvo mal; el equipo simplemente no tenía ningún instrumento capaz de mostrar las violaciones preexistentes.

**Modo de falla 2 — el scraping de logs como base de datos de cumplimiento.** Los equipos hacen grep de los logs del admission controller, los envían a Loki y construyen dashboards sobre líneas de log. Esto «funciona» hasta que la retención de logs rota, un controlador se reinicia, las réplicas escalan, o el formato del log cambia entre versiones menores. El estado de cumplimiento derivado de logs no es reproducible, y un auditor lo va a decir.

**Modo de falla 3 — los Events de Kubernetes como fuente de verdad.** Kyverno puede emitir Events para los resultados de políticas, y los Events son objetos reales de la API — pero el `kube-apiserver` los recolecta como basura después de `--event-ttl` (por defecto **1 hora**) y son deliberadamente lossy bajo carga (la agregación de eventos y el rate limiting están integrados en el cliente). Los Events son un canal de *notificación*, no un canal de *estado*.

### La respuesta de diseño: un objeto de cumplimiento declarativo, por recurso, consultable y ligado al GC

El **Policy Working Group** de Kubernetes (wg-policy) resolvió esto definiendo una API abierta basada en CRDs — `PolicyReport` y `ClusterPolicyReport` — que almacena el *estado de evaluación actual* de cada recurso frente a cada política como objetos de Kubernetes de primera clase. Kyverno es el productor de referencia.

Como los reportes son objetos ordinarios de la API, heredan gratis todo el control plane de Kubernetes:

- **Consultables con `kubectl`**, RBAC, selectores de campo/etiqueta, y `-o jsonpath`/`jq`.
- **Observables (watchable)**, así que las UIs y los pipelines de alertado son dirigidos por eventos en lugar de hacer polling.
- **Con owner reference** al recurso que describen, de modo que el garbage collector del API server elimina el reporte en el instante en que se borra el workload — no hay que escribir un recolector de huérfanos, no hay cron de TTL.
- **Namespaced**, así que a un tenant se le puede otorgar `get/list/watch` sobre los reportes de sus propios namespaces y en ningún otro lado.
- **Neutrales respecto del proveedor**, así que Kyverno, Trivy Operator, Falco, kube-bench y Nirmata escriben todos en un mismo esquema que una sola UI puede renderizar.

El modelo mental que hay que llevar al examen y a producción:

```
Admission response   →  a VERDICT   (transient, per-request, blocking)
Kubernetes Event     →  a SIGNAL    (~1h TTL, lossy, human-facing)
Prometheus metric    →  a FLOW      (counters; rate of evaluations over time)
PolicyReport         →  the STOCK   (current compliance state, durable, per-resource)
Controller log       →  a TRACE     (debugging the engine, not the fleet)
```

**Las métricas te dicen cuántas evaluaciones fallaron la última hora. Los reportes te dicen qué está roto ahora mismo.** Son preguntas distintas y necesitás las dos.

---

## 2. La API: `wgpolicyk8s.io/v1alpha2`

Los Policy Reports **no son una API de Kyverno**. Son una especificación abierta mantenida por el SIG/WG Policy de Kubernetes (repositorio: `kubernetes-sigs/wg-policy-prototypes`). Kyverno distribuye y es dueño de los CRDs en su distribución, pero cualquier herramienta puede producirlos o consumirlos.

Dos kinds, divididos exactamente según la frontera namespaced/cluster-scoped del recurso que se describe:

| | `PolicyReport` | `ClusterPolicyReport` |
|---|---|---|
| Grupo/versión de la API | `wgpolicyk8s.io/v1alpha2` | `wgpolicyk8s.io/v1alpha2` |
| Nombre corto | `polr` | `cpolr` |
| Ámbito del objeto reporte | Namespaced | Cluster |
| Describe recursos de kind | Namespaced (`Pod`, `Deployment`, `Service`, `Ingress`, `Role`…) | Cluster-scoped (`Namespace`, `ClusterRole`, `PersistentVolume`, `CRD`, `Node`…) |
| Vive en | El mismo namespace que el recurso | Ámbito de clúster |
| Delegación de RBAC | Por tenant (`Role` en su namespace) | Solo el equipo de plataforma |

**Señal de examen:** si una pregunta muestra un `Namespace` o un `ClusterRole` en violación y pregunta dónde aparece el resultado, la respuesta es `ClusterPolicyReport` (`cpolr`), *no* `polr`. La división sigue el **ámbito del recurso evaluado**, nunca el ámbito de la política. Una `ClusterPolicy` que matchea Pods escribe en objetos `PolicyReport` namespaced.

### 2.1 Anatomía de un reporte — objeto completo, sin abreviar

```yaml
apiVersion: wgpolicyk8s.io/v1alpha2
kind: PolicyReport
metadata:
  # Kyverno 1.10+ names the report after the UID of the resource it describes.
  name: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913
  namespace: payments
  labels:
    app.kubernetes.io/managed-by: kyverno
  annotations:
    audit.kyverno.io/last-scan-time: "2026-08-14T09:41:07Z"
  # This ownerReference is the whole garbage-collection strategy.
  # Delete the Deployment -> the API server deletes this report. No reaper needed.
  ownerReferences:
    - apiVersion: apps/v1
      kind: Deployment
      name: checkout-api
      uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913
      controller: true
      blockOwnerDeletion: false

# 'scope' is the single resource this report describes. Kyverno 1.10+ writes
# one report per resource; older versions aggregated a whole namespace into
# 'polr-ns-<namespace>', which did not scale and produced etcd-sized objects.
scope:
  apiVersion: apps/v1
  kind: Deployment
  name: checkout-api
  namespace: payments
  uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

summary:
  pass: 4
  fail: 2
  warn: 1
  error: 1
  skip: 1

results:
  # --- 1. A clean pass -------------------------------------------------------
  - source: kyverno
    policy: require-labels
    rule: autogen-check-for-labels        # NOTE the autogen- prefix, see §5.3
    category: Best Practices
    severity: medium
    result: pass
    scored: true
    message: validation rule 'autogen-check-for-labels' passed.
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 2. A scored violation -------------------------------------------------
  - source: kyverno
    policy: require-run-as-nonroot
    rule: autogen-run-as-non-root
    category: Pod Security Standards (Restricted)
    severity: high
    result: fail
    scored: true
    message: >-
      validation error: Running as root is not allowed. The fields
      spec.securityContext.runAsNonRoot, spec.containers[*].securityContext.runAsNonRoot,
      spec.initContainers[*].securityContext.runAsNonRoot, and
      spec.ephemeralContainers[*].securityContext.runAsNonRoot must be `true`.
      rule autogen-run-as-non-root failed at path
      /spec/template/spec/containers/0/securityContext/runAsNonRoot/
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 3. A violation of an UNSCORED policy -> 'warn', not 'fail' ------------
  - source: kyverno
    policy: require-team-annotation
    rule: check-team
    category: Ownership
    severity: low
    result: warn
    scored: false                         # driven by policies.kyverno.io/scored: "false"
    message: 'validation error: annotation `owner.company.io/team` is recommended.'
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 4. Engine failure, NOT a compliance failure ---------------------------
  - source: kyverno
    policy: check-image-registry
    rule: validate-registry-allowlist
    category: Supply Chain
    severity: high
    result: error
    scored: true
    message: >-
      failed to evaluate rule: failed to load context: failed to execute APICall:
      configmaps "registry-allowlist" not found in namespace "kyverno"
    timestamp:
      seconds: 1786174867
      nanos: 0
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913

  # --- 5. Skipped by a PolicyException ---------------------------------------
  - source: kyverno
    policy: disallow-host-path
    rule: host-path
    category: Pod Security Standards (Baseline)
    severity: high
    result: skip
    scored: true
    message: rule skipped due to policy exception 'payments/exempt-legacy-storage'
    timestamp:
      seconds: 1786174867
      nanos: 0
    properties:
      exceptions: payments/exempt-legacy-storage
    resources:
      - apiVersion: apps/v1
        kind: Deployment
        name: checkout-api
        namespace: payments
        uid: 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913
```

### 2.2 Los cinco valores de `result` — semántica precisa

Esta tabla es la pieza de conocimiento de mayor rendimiento de todo este dominio. Confundir `warn` con `fail` o `error` con `fail` es el error de producción más común en los dashboards de cumplimiento, porque cambia silenciosamente el denominador de cada porcentaje de cumplimiento que publicás.

| `result` | Significado | Cómo se produce | ¿Cuenta como violación? | Acción del SRE |
|---|---|---|---|---|
| `pass` | La regla se evaluó; el recurso la satisface. | Evaluación normal. | No | Ninguna |
| `fail` | La regla se evaluó; el recurso la viola; la regla es **scored**. | Por defecto para una regla `validate` violada. | **Sí** | Remediar el workload u otorgar una excepción |
| `warn` | La regla se evaluó; el recurso la viola; la regla es **unscored**. | Anotación de política `policies.kyverno.io/scored: "false"`. | No — se excluye del conteo de fallas | Backlog consultivo |
| `error` | La regla **no pudo ser evaluada**. | Falla de sustitución de variables, falla al cargar el contexto de `apiCall`/`configMap`, denegación de RBAC, JMESPath malformado, registry inalcanzable para `imageVerify`. | **No — y esta es la trampa** | **Despertar a alguien.** Un `error` es un desconocido, no un pass. |
| `skip` | La regla no aplicaba a este recurso. | Las `preconditions` evaluaron falso, o una `PolicyException` matcheó. | No | Verificar que la excepción sea intencional y acotada en el tiempo |

> **Regla de producción:** nunca calcules el cumplimiento como `pass / (pass + fail)`. Un `error` es un recurso *no medido*. Un clúster donde el reports controller perdió RBAC sobre un CRD va a reportar alegremente 100% de cumplimiento mientras no mide nada. Alertá sobre `summary.error > 0` con la misma severidad que `summary.fail`.

> **Trampa de examen — `Audit` vs `Enforce` no cambia el valor de `result`.** `validationFailureAction` (Kyverno ≤1.12) / `validate.failureAction` (Kyverno 1.13+) controla **si se bloquea la admisión**, no lo que aparece en el reporte. Una violación en `Audit` se reporta como `fail`. El efecto real de segundo orden es más sutil y vale la pena internalizarlo:
>
> Bajo `Enforce`, un **create** en violación es rechazado — el recurso nunca existe, así que **no se escribe ningún reporte para él** (no hay nada que sea dueño del reporte). Por lo tanto, las entradas `fail` en un clúster sano bajo `Enforce` provienen casi exclusivamente de **background scans de recursos preexistentes**. Si cambiás una política a `Enforce` y tu conteo de `fail` cae a cero de un día para el otro, no arreglaste nada — dejaste de observar.

---

## 3. El pipeline de reportes de Kyverno: quién escribe qué, y cuándo

Desde Kyverno **1.10** el monolito está dividido en cuatro deployments escalables de forma independiente. Los reportes son responsabilidad de uno de ellos.

| Deployment | Responsabilidad | Relevancia para los reportes |
|---|---|---|
| `kyverno-admission-controller` | Sirve `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration` | Emite **reportes intermedios (efímeros)** por cada petición admitida |
| `kyverno-background-controller` | `generate` y `mutate` sobre recursos existentes | No es productor de reportes |
| `kyverno-cleanup-controller` | `CleanupPolicy` / borrado basado en TTL | No es productor de reportes |
| `kyverno-reports-controller` | **Background scanning + agregación en `polr`/`cpolr`** | **El único escritor de `PolicyReport`/`ClusterPolicyReport`** |

**Consecuencia arquitectónica:** si `reportsController.enabled=false` en el chart de Helm, el admission control sigue funcionando perfectamente y **jamás se produce ningún reporte**. Esta es la causa número uno de «mis políticas funcionan pero `kubectl get polr` está vacío». También es una decisión legítima de producción en clústeres muy grandes — ver §7.

### 3.1 Las dos rutas de evaluación independientes

```
                    ┌──────────────────────────────────────────────┐
  kubectl apply ──▶ │ kube-apiserver                               │
                    └───────────────┬──────────────────────────────┘
                                    │ AdmissionReview
                                    ▼
                    ┌──────────────────────────────────────────────┐
                    │ kyverno-admission-controller                 │
                    │  · evaluates matching rules                  │
                    │  · returns allow/deny  (the VERDICT)         │
                    │  · writes an EPHEMERAL/intermediate report   │
                    └───────────────┬──────────────────────────────┘
                                    │ ephemeralreports.reports.kyverno.io
                                    ▼
   every --backgroundScanInterval   ┌──────────────────────────────────────────┐
   (default 1h) ──────────────────▶ │ kyverno-reports-controller               │
   full re-evaluation of all        │  · BACKGROUND SCAN of existing resources │
   matched existing resources       │  · AGGREGATES ephemeral + scan results   │
                                    │  · reconciles on policy add/update/delete│
                                    └───────────────┬──────────────────────────┘
                                                    │
                                                    ▼
                          wgpolicyk8s.io/v1alpha2 PolicyReport / ClusterPolicyReport
                                     (one object per resource, owned by it)
```

| Dimensión | Resultados en tiempo de admisión | Resultados de background scan |
|---|---|---|
| Disparador | Una petición `CREATE`/`UPDATE` a la API | Temporizador (`--backgroundScanInterval`, por defecto `1h`) + eventos de cambio de política |
| Cubre | Solo recursos tocados desde que se instaló la política | **Todos** los recursos existentes que matchean |
| Latencia hasta aparecer en `polr` | Segundos (ciclo de agregación) | Hasta un intervalo completo |
| Ve `request.userInfo`, `request.operation`, `request.roles` | **Sí** | **No** — no hay AdmissionRequest |
| Se deshabilita con | `--admissionReports=false` | `spec.background: false` en la política, o `--backgroundScanInterval` |
| Respeta el ConfigMap `resourceFilters` | Siempre | Solo si `--skipResourceFilters=false` |
| Propósito | Feedback inmediato, drift en el momento en que ocurre | Verdad retroactiva, la respuesta a «qué se rompería» |

> **Señal de examen — la incompatibilidad `background` / `userInfo`.** Kyverno **rechaza en admisión** cualquier política con `background: true` (el valor por defecto) que referencie variables exclusivas del AdmissionRequest como `{{request.userInfo.username}}`, `{{request.roles}}`, `{{request.clusterRoles}}` o `{{request.operation}}`. El error se ve así:
>
> ```
> admission webhook "validate-policy.kyverno.svc" denied the request:
> path: spec.rules[0].validate.pattern: variables {{request.userInfo.username}}
> are not allowed
> ```
>
> El arreglo es `spec.background: false` — y el **precio** es que la política queda entonces limitada a admisión y **no produce resultados de background scan**, así que nunca puede contarte sobre violaciones preexistentes. Ese trade-off es una decisión de diseño, no un workaround.

### 3.2 Reportes intermedios — la capa que vas a encontrar durante el triage

Entre el admission controller y el `polr` final hay una capa de staging de vida corta. Su API fue evolucionando:

| Versión de Kyverno | Kinds de reportes intermedios | Grupo de API |
|---|---|---|
| ≤ 1.9 | ninguno (reportes escritos directamente, agregados por namespace como `polr-ns-<ns>`) | — |
| 1.10 | `AdmissionReport`, `ClusterAdmissionReport`, `BackgroundScanReport`, `ClusterBackgroundScanReport` | `kyverno.io/v1alpha2` |
| 1.11+ | consolidados en `EphemeralReport`, `ClusterEphemeralReport` | `reports.kyverno.io/v1` |

Estos objetos son un detalle de implementación: **no construyas tooling sobre ellos**, no son el contrato estable. Son extremadamente útiles para una sola cosa — probar *dónde* está trabado el pipeline:

```
$ kubectl get ephemeralreports.reports.kyverno.io -A --no-headers | wc -l
4
```

Un conteo de reportes efímeros **creciente y que no drena** significa que el bucle de agregación en el reports controller está fallando o está siendo throttleado. Un conteo que se mantiene cerca de cero mientras existen objetos `polr` significa que el pipeline está sano.

### 3.3 Matriz de evolución de la API (sabé en qué peldaño estás parado)

| Concepto | Respuesta estable / relevante para el examen | Notas |
|---|---|---|
| API de reportes | `wgpolicyk8s.io/v1alpha2`, kinds `PolicyReport`/`ClusterPolicyReport` | El objetivo del KCA. Propiedad del WG Policy de Kubernetes, no de Kyverno. |
| Nombres cortos | `polr`, `cpolr` | Memorizalos; el examen los usa. |
| Granularidad del reporte | Un reporte por recurso (Kyverno 1.10+) | Los clústeres pre-1.10 agregaban por namespace. |
| Productor de reportes | `kyverno-reports-controller` (1.10+) | Se habilita/deshabilita/escala por separado. |
| API sucesora | La API del WG Policy fue rebautizada como **OpenReports** (`openreports.io`, kinds `Report`/`ClusterReport`) | Las versiones más nuevas de Kyverno pueden emitirla; `wgpolicyk8s.io/v1alpha2` sigue siendo la línea base compatible. Confirmá qué sirve realmente tu clúster con `kubectl api-resources` antes de escribir tooling. |

---

## 4. Manifiestos completos, de calidad productiva

### 4.1 Una política diseñada *para* el reporting

El reporte es tan útil como los metadatos que carga la política. `category` y `severity` provienen **exclusivamente** de anotaciones — Kyverno las copia textualmente en cada resultado. Una política sin ellas produce reportes que no podés segmentar, priorizar ni enrutar.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-nonroot
  annotations:
    # --> Copied into results[].category. This is your dashboard's group-by key.
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    # --> Copied into results[].severity. Valid: critical | high | medium | low | info
    policies.kyverno.io/severity: high
    # --> 'true' keeps result=fail. Set "false" to downgrade violations to result=warn.
    policies.kyverno.io/scored: "true"
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/title: Require runAsNonRoot
    policies.kyverno.io/description: >-
      Containers must not run as the root user. Reported as `fail` in Audit mode
      so that pre-existing workloads are surfaced before enforcement is enabled.
spec:
  # background: true is REQUIRED for pre-existing resources to be scanned.
  # It is the default; it is written explicitly here because it is load-bearing.
  background: true

  # Kyverno 1.13+ moved failureAction under the rule. On <=1.12 use the
  # top-level `spec.validationFailureAction: Audit` instead.
  rules:
    - name: run-as-non-root
      match:
        any:
          - resources:
              kinds:
                - Pod
      # Exclude control-plane namespaces from BOTH admission and scanning.
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - kube-public
                - kyverno
      validate:
        failureAction: Audit            # Audit => report but do not block
        failureActionOverrides:
          - action: Enforce             # ...except here, where we already converged
            namespaces:
              - payments
              - identity
        message: >-
          Running as root is not allowed. Set
          spec.securityContext.runAsNonRoot=true or set it on every container.
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(runAsNonRoot): "true"
```

**La disciplina de las dos anotaciones.** No publiques ninguna política sin `category` y `severity`. Son gratis en el momento de autoría e imposibles de rellenar retroactivamente sobre un corpus de reportes existente sin regenerar cada reporte.

### 4.2 Una política unscored («consultiva») — la primitiva de rollout seguro

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-annotation
  annotations:
    policies.kyverno.io/category: Ownership
    policies.kyverno.io/severity: low
    # THIS is what turns fail -> warn. Violations stop polluting the failure
    # budget while the org backfills ownership metadata.
    policies.kyverno.io/scored: "false"
spec:
  background: true
  rules:
    - name: check-team
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet, DaemonSet, CronJob]
      validate:
        failureAction: Audit
        message: 'annotation `owner.company.io/team` is recommended.'
        pattern:
          metadata:
            annotations:
              owner.company.io/team: "?*"
```

**Escalera de rollout** — cada peldaño es un cambio distinto y reversible, con una firma distinta en los reportes:

| Etapa | `scored` | `failureAction` | Resultado en el reporte | Admisión | Propósito |
|---|---|---|---|---|---|
| 1. Descubrir | `false` | `Audit` | `warn` | permitida | Medir el radio de impacto sin ningún riesgo para los SLOs |
| 2. Comprometerse | `true` | `Audit` | `fail` | permitida | Las fallas ahora cuentan; llevar el conteo a cero |
| 3. Fijar por namespace | `true` | `Audit` + `failureActionOverrides: Enforce` | `fail` (solo legacy) | bloqueada en los namespaces convergidos | Prevenir regresiones donde ya ganaste |
| 4. Enforce en toda la flota | `true` | `Enforce` | conteo de `fail` → 0 | bloqueada | Estado estacionario |

Nunca saltes de la etapa 1 a la etapa 4. La etapa 2 existe precisamente para que el conteo de `fail` sea un burn-down honesto y monitoreable.

### 4.3 `PolicyException` — convertir un `fail` en un `skip` auditable

Una excepción es la forma correcta de retirar una violación que aceptaste conscientemente. A diferencia de borrar o restringir la política, es **acotada, declarativa, revisable y visible en el reporte** como `skip` con el nombre de la excepción en `properties`.

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-legacy-storage
  namespace: payments
  annotations:
    owner.company.io/team: payments-platform
    owner.company.io/ticket: PLAT-4471
    owner.company.io/expires: "2026-12-31"   # advisory; enforce with a CleanupPolicy
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames:
        - host-path
        - autogen-host-path          # ALWAYS list the autogen variants (see §5.3)
        - autogen-cronjob-host-path
  match:
    any:
      - resources:
          kinds:
            - Pod
            - Deployment
          namespaces:
            - payments
          names:
            - legacy-ledger-*
```

Las excepciones deben estar habilitadas en los controladores — están apagadas por defecto en algunas distribuciones:

```yaml
# Helm values
features:
  policyExceptions:
    enabled: true
    namespace: ""       # "" = any namespace; set to a single namespace to centralise
```

### 4.4 Valores de Helm: la superficie de control completa del reporting

```yaml
# values.yaml — Kyverno chart, reporting-relevant settings only
reportsController:
  enabled: true
  replicas: 1                 # leader-elected; >1 gives HA, not throughput
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 2Gi             # NO cpu limit: throttling here silently stalls scans
  # Escape hatch for any flag not surfaced by the chart:
  extraArgs:
    backgroundScanWorkers: 5

admissionController:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      memory: 2Gi

features:
  admissionReports:
    enabled: true             # false => admission results never reach polr;
                              #          background scan becomes the only source
  backgroundScan:
    enabled: true
    backgroundScanInterval: 1h
    backgroundScanWorkers: 5
    # false => background scans HONOUR the resourceFilters ConfigMap.
    # Default true means scans IGNORE those filters. See §7.2 — this is the
    # single most effective etcd-pressure lever in the chart.
    skipResourceFilters: false
  reporting:
    validate: true
    mutate: false             # mutation results are usually dashboard noise
    mutateExisting: false
    imageVerify: true
    generate: false
  policyExceptions:
    enabled: true
    namespace: ""
```

Flags de contenedor equivalentes, para clústeres no instalados vía Helm:

```yaml
# Deployment: kyverno-reports-controller
        args:
          - --backgroundScanInterval=1h
          - --backgroundScanWorkers=5
          - --skipResourceFilters=false
          - --enableReporting=validate,imageVerify
          - --v=2
```

### 4.5 RBAC — el productor silencioso de `result: error`

Los controladores de Kyverno usan **ClusterRoles agregados**. De fábrica pueden leer los kinds integrados. En el momento en que una política matchea un **CRD** — `Certificate`, `VirtualService`, `Rollout`, `ScaledObject` — el reports controller no puede hacer `list/watch` sobre él y cada evaluación en background se convierte en `result: error`, o no produce reporte alguno.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:custom-resources
  labels:
    # These aggregation labels are the extension point. Without them, this
    # ClusterRole is dead weight.
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
rules:
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "issuers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.istio.io"]
    resources: ["virtualservices", "gateways"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["argoproj.io"]
    resources: ["rollouts"]
    verbs: ["get", "list", "watch"]
```

### 4.6 Acceso de solo lectura a los reportes para un tenant

Los reportes son namespaced, así que los tenants pueden auto-servirse su propio estado de cumplimiento sin ver el de nadie más:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: policy-report-reader
  namespace: payments
rules:
  - apiGroups: ["wgpolicyk8s.io"]
    resources: ["policyreports"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-report-reader
  namespace: payments
roleBinding: {}
subjects:
  - kind: Group
    name: team-payments
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: policy-report-reader
  apiGroup: rbac.authorization.k8s.io
```

### 4.7 Scraping de las propias métricas de Kyverno

Cada controlador 1.10+ expone su propio servicio de métricas. Un solo `ServiceMonitor` los cubre a todos:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kyverno
  namespace: kyverno
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: [kyverno]
  selector:
    matchLabels:
      app.kubernetes.io/part-of: kyverno
  endpoints:
    - port: metrics-port
      interval: 30s
      scrapeTimeout: 25s
      honorLabels: true
```

Reglas de alertado que capturan los modos de falla descritos en §5 y §7:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-reporting
  namespace: kyverno
spec:
  groups:
    - name: kyverno.reporting
      rules:
        # An 'error' is an UNMEASURED resource, not a passing one.
        - alert: KyvernoRuleEvaluationErrors
          expr: sum(rate(kyverno_policy_results_total{rule_result="error"}[15m])) > 0
          for: 15m
          labels: {severity: critical}
          annotations:
            summary: Kyverno rules are erroring — compliance data is incomplete
            runbook: Check reports-controller RBAC and any apiCall/configMap context

        # If the reports controller dies, polr goes stale and looks compliant.
        - alert: KyvernoReportsControllerDown
          expr: absent(up{job=~".*reports-controller.*"} == 1)
          for: 10m
          labels: {severity: critical}
          annotations:
            summary: No reports controller is scraping — PolicyReports are frozen

        - alert: KyvernoPolicyFailuresRising
          expr: |
            sum by (policy_name) (
              rate(kyverno_policy_results_total{rule_result="fail"}[30m])
            ) > 0
          for: 30m
          labels: {severity: warning}
```

### 4.8 Policy Reporter — la capa de UI y ruteo

`kubectl` es la API; Policy Reporter (un proyecto de la organización Kyverno) es la capa de agregación, UI, exportador de métricas y enrutador de notificaciones por encima de los mismos CRDs. Como consume la API **abierta** `wgpolicyk8s.io`, renderiza los resultados de Kyverno, Trivy Operator y Falco en un solo panel.

```console
$ helm repo add policy-reporter https://kyverno.github.io/policy-reporter
"policy-reporter" has been added to your repositories

$ helm repo update
Update Complete. ⎈Happy Helming!⎈

$ helm install policy-reporter policy-reporter/policy-reporter \
    --namespace policy-reporter --create-namespace \
    --set ui.enabled=true \
    --set kyvernoPlugin.enabled=true \
    --set monitoring.enabled=true
NAME: policy-reporter
LAST DEPLOYED: Fri Aug 14 09:52:11 2026
NAMESPACE: policy-reporter
STATUS: deployed
REVISION: 1
```

> Los valores cambiaron entre versiones mayores del chart: v2 usa `kyvernoPlugin.enabled`, v3 usa `plugin.kyverno.enabled`. Ejecutá siempre `helm show values policy-reporter/policy-reporter` contra la versión del chart que realmente estás instalando, en lugar de copiar valores de un blog post.

```console
$ kubectl -n policy-reporter get pods
NAME                                  READY   STATUS    RESTARTS   AGE
policy-reporter-6b7d9f8c4-ktz9m       1/1     Running   0          61s
policy-reporter-kyverno-plugin-...    1/1     Running   0          61s
policy-reporter-ui-7c8d5b9f6-x2vqp    1/1     Running   0          61s

$ kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
Forwarding from 127.0.0.1:8082 -> 8080
```

Los destinos de notificación son declarativos — así es como un `fail` se convierte en un aviso al guardia en lugar de un dashboard que nadie abre:

```yaml
target:
  slack:
    channels:
      - webhook: https://hooks.slack.com/services/XXX/YYY/ZZZ
        minimumSeverity: high
        skipExistingOnStartup: true      # do NOT replay history on every restart
        filter:
          namespaces:
            exclude: ["kube-system", "kyverno"]
  loki:
    host: http://loki.observability:3100
    minimumSeverity: warning
```

---

## 5. Trabajando con la CLI

### 5.1 Descubrimiento y forma de los datos

```console
$ kubectl api-resources --api-group=wgpolicyk8s.io
NAME                   SHORTNAMES   APIVERSION                    NAMESPACED   KIND
clusterpolicyreports   cpolr        wgpolicyk8s.io/v1alpha2       false        ClusterPolicyReport
policyreports          polr         wgpolicyk8s.io/v1alpha2       true         PolicyReport
```

```console
$ kubectl get polr -A
NAMESPACE   NAME                                   KIND         NAME             PASS   FAIL   WARN   ERROR   SKIP   AGE
default     1c0d4e8b-2a6f-4d17-8b3e-9f0a5c2d7e41   Pod          nginx            3      1      0      0       0      12m
payments    7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913   Deployment   checkout-api     4      2      1      1       1      12m
payments    a4b8c1d2-3e5f-4071-92a3-6b7c8d9e0f11   ReplicaSet   checkout-api-…   4      2      1      1       1      12m
payments    e2f5a7c9-1b3d-4e6f-8a09-2c4d6e8f0a13   Pod          checkout-api-…   4      2      1      1       1      12m
identity    9d1e3f5a-7b9c-4d0e-a2f4-6b8d0f2a4c61   Deployment   authn-gateway    6      0      0      0       0      12m

$ kubectl get cpolr
NAME                                   KIND        NAME          PASS   FAIL   WARN   ERROR   SKIP   AGE
b3c5d7e9-0f2a-4b6c-8d0e-1f3a5b7c9d02   Namespace   payments      1      1      0      0       0      12m
c4d6e8f0-1a3b-4c5d-9e0f-2a4b6c8d0e13   Namespace   identity      2      0      0      0       0      12m
```

**Leé las columnas con cuidado.** El primer `NAME` es el objeto reporte (un UID). El segundo `NAME` (con `KIND`) es `scope` — el recurso realmente evaluado. Esta duplicación confunde a la gente constantemente.

Notá también que `checkout-api` aparece **tres veces**: `Deployment`, `ReplicaSet`, `Pod`. La funcionalidad de **auto-generación** de Kyverno expande una regla sobre Pod en reglas equivalentes para los controladores de Pod, así que una única violación lógica se reporta una vez por cada objeto de la cadena de propiedad. Todo conteo a nivel de flota que calcules debe decidir qué capa está contando — ver §5.3.

### 5.2 Triage dirigido

Ranking de fallas a nivel de flota — la consulta a ejecutar primero en cualquier clúster nuevo:

```console
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[] | select(.result=="fail")
           | [.severity, .policy, .rule] | @tsv' \
  | sort | uniq -c | sort -rn
     84	high	require-run-as-nonroot	autogen-run-as-non-root
     41	high	disallow-privilege-escalation	autogen-privilege-escalation
     28	medium	require-requests-limits	autogen-validate-resources
     12	high	disallow-host-path	autogen-host-path
      6	medium	require-labels	autogen-check-for-labels
```

Qué namespaces cargan con la deuda:

```console
$ kubectl get polr -A -o json \
  | jq -r '.items[] | select(.summary.fail > 0)
           | "\(.metadata.namespace)\t\(.scope.kind)/\(.scope.name)\t\(.summary.fail)"' \
  | sort -k3 -rn | head
payments	Deployment/checkout-api	2
payments	ReplicaSet/checkout-api-7d9c8b5f4	2
payments	Pod/checkout-api-7d9c8b5f4-x2mlq	2
legacy	  Deployment/ledger-batch	2
```

**Encontrar cada `error` — la superficie no medida:**

```console
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[] | select(.result=="error")
           | "\(.policy)/\(.rule): \(.message)"' | sort -u
check-image-registry/validate-registry-allowlist: failed to evaluate rule: failed to load context: failed to execute APICall: configmaps "registry-allowlist" not found in namespace "kyverno"
require-cert-issuer/check-issuer: failed to evaluate rule: cert-manager.io/v1, Kind=Certificate is forbidden: User "system:serviceaccount:kyverno:kyverno-reports-controller" cannot list resource "certificates"
```

Ambas líneas son accionables y ninguna aparecería en un dashboard ingenuo de «% de cumplimiento».

Drill-down sobre un único recurso — el comando estilo examen:

```console
$ kubectl -n payments get polr -o json \
  | jq -r '.items[] | select(.scope.kind=="Deployment" and .scope.name=="checkout-api")
           | .results[] | "\(.result)\t\(.policy)/\(.rule)\t\(.message)"'
pass	require-labels/autogen-check-for-labels	validation rule 'autogen-check-for-labels' passed.
fail	require-run-as-nonroot/autogen-run-as-non-root	validation error: Running as root is not allowed...
warn	require-team-annotation/check-team	validation error: annotation `owner.company.io/team` is recommended.
error	check-image-registry/validate-registry-allowlist	failed to evaluate rule: failed to load context...
skip	disallow-host-path/host-path	rule skipped due to policy exception 'payments/exempt-legacy-storage'
```

Kyverno etiqueta los reportes según el controlador que los gestiona, lo que te permite separar productores cuando varias herramientas escriben `polr`:

```console
$ kubectl get polr -A -l app.kubernetes.io/managed-by=kyverno --no-headers | wc -l
1247
```

### 5.3 El prefijo `autogen-` — una fuente garantizada de confusión

Una regla que matchea `kind: Pod` es auto-expandida por Kyverno en reglas equivalentes llamadas `autogen-<rule>` para Deployment/StatefulSet/DaemonSet/Job/ReplicaSet/ReplicationController, y `autogen-cronjob-<rule>` para CronJob. Consecuencias que tenés que contemplar en el diseño:

| Síntoma | Causa | Respuesta correcta |
|---|---|---|
| Una violación aparece 3× (Deployment, ReplicaSet, Pod) | Autogen + cadena de propiedad, cada objeto obtiene su propio reporte | Contá en **una sola** capa. Para «cuántos workloads están rotos», filtrá `scope.kind` a los controladores; para «cuánto cómputo en ejecución no cumple», filtrá a `Pod`. |
| Una `PolicyException` no tiene efecto | Solo se listó el nombre de la regla base | Agregá cada variante `autogen-*` a `spec.exceptions[].ruleNames` |
| El nombre de `rule` en el reporte no coincide con el YAML de la política | Autogen la renombró | Es lo esperado; sacá el prefijo al correlacionar |

Inspeccioná qué generó realmente Kyverno:

```console
$ kubectl get clusterpolicy require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}'
autogen-run-as-non-root autogen-cronjob-run-as-non-root
```

Para deshabilitar autogen en una política (y obtener una sola entrada de reporte, solo por Pod):

```yaml
metadata:
  annotations:
    pod-policies.kyverno.io/autogen-controllers: none
```

### 5.4 `kyverno apply --policy-report` — reportes sin clúster

La CLI de Kyverno evalúa políticas contra manifiestos de forma offline y emite un `ClusterPolicyReport` real. Este es el gate correcto en CI: hace fallar un pull request *antes* de que el recurso llegue siquiera a un clúster, con el mismo esquema que usan tus dashboards en runtime.

```console
$ kyverno version
Version: v1.13.2
Time: 2026-03-11T14:22:07Z
Git commit ID: 9c1d4f8

$ kyverno apply ./policies/ --resource ./manifests/ --policy-report

Applying 8 policy rule(s) to 3 resource(s)...

policy require-run-as-nonroot -> resource payments/Deployment/checkout-api failed:
1. autogen-run-as-non-root: validation error: Running as root is not allowed. The
fields spec.securityContext.runAsNonRoot, spec.containers[*].securityContext.runAsNonRoot
must be `true`. rule autogen-run-as-non-root failed at path
/spec/template/spec/containers/0/securityContext/runAsNonRoot/

----------------------------------------------------------------------
POLICY REPORT:
----------------------------------------------------------------------
apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: merged
results:
- message: validation rule 'autogen-check-for-labels' passed.
  policy: require-labels
  resources:
  - apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
    namespace: payments
  result: pass
  rule: autogen-check-for-labels
  scored: true
  source: kyverno
- message: 'validation error: Running as root is not allowed...'
  policy: require-run-as-nonroot
  resources:
  - apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
    namespace: payments
  result: fail
  rule: autogen-run-as-non-root
  scored: true
  source: kyverno
summary:
  error: 0
  fail: 1
  pass: 5
  skip: 2
  warn: 0

pass: 5, fail: 1, warn: 0, error: 0, skip: 2
```

```console
$ echo $?
1
```

**El código de salida distinto de cero ante una falla es lo que convierte esto en un gate.** Un job mínimo de CI:

```yaml
# .github/workflows/policy-gate.yml
name: policy-gate
on: [pull_request]
jobs:
  kyverno-apply:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Kyverno CLI
        run: |
          curl -sSL -o kyverno.tar.gz \
            https://github.com/kyverno/kyverno/releases/download/v1.13.2/kyverno-cli_v1.13.2_linux_x86_64.tar.gz
          tar -xzf kyverno.tar.gz && sudo mv kyverno /usr/local/bin/
      - name: Evaluate policies against rendered manifests
        run: |
          helm template ./chart > /tmp/rendered.yaml
          kyverno apply ./policies/ \
            --resource /tmp/rendered.yaml \
            --policy-report \
            --audit-warn > /tmp/report.yaml
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: policy-report
          path: /tmp/report.yaml
```

`--audit-warn` reporta las fallas en modo `Audit` como `warn` en lugar de `fail`, así que un PR solo se bloquea por políticas que ya te comprometiste a aplicar. La misma escalera de §4.2, aplicada a la izquierda del clúster.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Escalera de salud — ejecutar en orden, detenerse en el primer peldaño que falle

```console
# Rung 1 — do the CRDs exist at all?
$ kubectl get crd | grep -E 'policyreport|reports.kyverno'
clusterpolicyreports.wgpolicyk8s.io          2026-05-02T11:03:44Z
policyreports.wgpolicyk8s.io                 2026-05-02T11:03:44Z
clusterephemeralreports.reports.kyverno.io   2026-05-02T11:03:45Z
ephemeralreports.reports.kyverno.io          2026-05-02T11:03:45Z

# Rung 2 — is the ONLY writer of polr actually running?
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    3/3     3            3           104d
kyverno-background-controller   1/1     1            1           104d
kyverno-cleanup-controller      1/1     1            1           104d
kyverno-reports-controller      1/1     1            1           104d

# Rung 3 — is it configured to report at all?
$ kubectl -n kyverno get deploy kyverno-reports-controller \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
["--backgroundScanInterval=1h"
"--backgroundScanWorkers=5"
"--skipResourceFilters=false"
"--enableReporting=validate,imageVerify"
"--v=2"]

# Rung 4 — is the policy eligible for background scanning?
$ kubectl get cpol require-run-as-nonroot -o jsonpath='{.spec.background}{"\n"}'
true

# Rung 5 — is the policy ready and its webhook configured?
$ kubectl get cpol
NAME                     ADMISSION   BACKGROUND   READY   AGE   MESSAGE
require-run-as-nonroot   true        true         True    9d    Ready
require-labels           true        true         True    9d    Ready
require-team-annotation  true        true         True    2d    Ready

# Rung 6 — is the intermediate layer draining?
$ kubectl get ephemeralreports.reports.kyverno.io -A --no-headers | wc -l
3

# Rung 7 — do final reports exist and are they fresh?
$ kubectl get polr -A --no-headers | wc -l
1247
$ kubectl get polr -A -o json \
  | jq -r '[.items[].metadata.annotations["audit.kyverno.io/last-scan-time"]] | max'
"2026-08-14T09:41:07Z"
```

### 6.2 Catálogo de fallas

#### `kubectl get polr -A` no devuelve nada

| Verificación | Comando | Arreglo |
|---|---|---|
| El reports controller no existe | `kubectl -n kyverno get deploy kyverno-reports-controller` | `--set reportsController.enabled=true` |
| El reports controller está en CrashLoop | `kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=100` | Normalmente OOMKilled — subí el límite de memoria |
| Reporting deshabilitado para ese tipo de regla | inspeccioná `--enableReporting` | Agregá `validate` (y `imageVerify` si se usa) |
| Ninguna política es elegible para background | `kubectl get cpol -o custom-columns=NAME:.metadata.name,BG:.spec.background` | Sacá las variables de la familia `request.userInfo` para que `background: true` sea legal |
| Todos los recursos están filtrados | `kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}'` | Achicá los filtros, o poné `--skipResourceFilters=true` |
| El primer scan todavía no corrió | `--backgroundScanInterval=1h` y Kyverno reinició hace 5 min | Esperá, o forzá un rescan (§6.3) |

```console
$ kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=20
I0814 09:41:07.223  reports-controller  "msg"="starting background scan" "interval"="1h0m0s" "workers"=5
I0814 09:41:09.881  reports-controller  "msg"="background scan completed" "resources"=4123 "duration"="2.658s"
E0814 09:41:09.902  reports-controller  "msg"="failed to list resource" "gvk"="cert-manager.io/v1, Kind=Certificate" "error"="certificates.cert-manager.io is forbidden: User \"system:serviceaccount:kyverno:kyverno-reports-controller\" cannot list resource \"certificates\" in API group \"cert-manager.io\" at the cluster scope"
```

Esa última línea es §4.5 — aplicá el `ClusterRole` agregado.

#### Los reportes existen pero muestran cero `fail` aunque las violaciones son obvias

| Causa | Cómo confirmarlo | Razonamiento |
|---|---|---|
| La política está en `Enforce`, así que los **creates** en violación son rechazados y nunca se persisten | `kubectl get events -A --field-selector reason=PolicyViolation` | Sin objeto ⇒ sin reporte. La ausencia de `fail` bajo `Enforce` es lo esperado, no una prueba de cumplimiento. |
| La política es unscored | `kubectl get cpol X -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/scored}'` | Las violaciones caen en `warn`, no en `fail` |
| Matcheó una `PolicyException` | buscá en el reporte `result: skip` y `properties.exceptions` | Funciona según lo previsto; verificá que la excepción siga estando justificada |
| `spec.background: false` | `kubectl get cpol X -o jsonpath='{.spec.background}'` | Los recursos preexistentes nunca se escanean |
| Un bloque `exclude` o un namespaceSelector saca al namespace | leé `spec.rules[].exclude` | La regla genuinamente no aplica |

Verificá el RBAC directamente en vez de adivinar:

```console
$ kubectl auth can-i list certificates.cert-manager.io \
    --as=system:serviceaccount:kyverno:kyverno-reports-controller
no
```

#### Los reportes están desactualizados

```console
$ kubectl get polr -A -o json | jq -r '
    .items[] | "\(.metadata.annotations["audit.kyverno.io/last-scan-time"])\t\(.metadata.namespace)/\(.scope.name)"' \
  | sort | head -3
2026-08-13T02:14:51Z	legacy/ledger-batch
2026-08-13T02:14:51Z	legacy/ledger-cron
2026-08-14T09:41:07Z	payments/checkout-api
```

Un timestamp de 31 horas de antigüedad contra un intervalo de 1 hora significa que el reports controller no está completando los scans. Causas ordenadas:

1. **Throttling por límite de CPU.** El background scanning está limitado por CPU. Revisá `container_cpu_cfs_throttled_seconds_total`. Sacá el límite de CPU; mantené el de memoria.
2. **Workers insuficientes.** Subí `--backgroundScanWorkers`.
3. **Rate limiting del API server.** Buscá `client-side throttling` en los logs y subí `--clientRateLimitQPS` / `--clientRateLimitBurst`.
4. **Una única regla costosa.** La carga de contexto basada en `apiCall` contra un endpoint lento serializa el scan.

#### Los reportes sobreviven a sus recursos

```console
$ kubectl -n payments get polr 7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913 \
    -o jsonpath='{.metadata.ownerReferences}' | jq .
[
  {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "name": "checkout-api",
    "uid": "7f3a1c92-4d5e-4b1a-9c8f-2e6b0d47a913",
    "controller": true,
    "blockOwnerDeletion": false
  }
]
```

Si `ownerReferences` está vacío, el GC no puede funcionar y el reporte va a quedar huérfano. Si está poblado y el reporte igual sobrevive a su dueño, el garbage collector del `kube-controller-manager` del clúster está degradado — eso es un problema del control plane, no de Kyverno.

### 6.3 Forzar un rescan sin esperar una hora

Un background scan se dispara por eventos de cambio de política, no solo por el temporizador. Tocar el spec de una política fuerza la reevaluación inmediata de todo lo que matchea:

```console
$ kubectl annotate cpol require-run-as-nonroot \
    ops.company.io/rescan="$(date -u +%FT%TZ)" --overwrite
clusterpolicy.kyverno.io/require-run-as-nonroot annotated

$ sleep 20 && kubectl -n payments get polr -o json \
  | jq -r '.items[0].metadata.annotations["audit.kyverno.io/last-scan-time"]'
"2026-08-14T10:07:33Z"
```

El instrumento más contundente — reiniciar el controlador, lo que dispara un scan completo al arrancar:

```console
$ kubectl -n kyverno rollout restart deploy/kyverno-reports-controller
deployment.apps/kyverno-reports-controller restarted
$ kubectl -n kyverno rollout status deploy/kyverno-reports-controller
deployment "kyverno-reports-controller" successfully rolled out
```

En un clúster grande esto programa un re-scan completo de cada recurso matcheado. No lo hagas durante un incidente en el API server.

---

## 7. Escala: los reportes son objetos de etcd, y etcd es finito

Acá es donde los Policy Reports dejan de ser una funcionalidad y empiezan a ser un problema de planificación de capacidad. También es la diferencia entre una respuesta de nivel KCA y una de nivel Platform Architect.

### 7.1 La aritmética

Los reportes se almacenan en etcd como todo lo demás. Dos presiones independientes:

**Cantidad de objetos.** Un reporte por recurso matcheado. Un clúster con 4.000 Pods + 900 Deployments + 900 ReplicaSets + 2.000 otros objetos matcheados ≈ **7.800 objetos reporte**, sin importar cuántas políticas ejecutes.

**Tamaño de los objetos.** Cada reporte lleva una entrada en `results[]` por cada regla matcheada, cada una con un mensaje completo y una referencia al recurso (~350–600 bytes). Treinta reglas ⇒ aproximadamente 12–20 KB por reporte.

```console
$ kubectl get polr,cpolr -A -o json | jq '
    {objects: (.items|length),
     bytes: ([.items[] | (.|tostring|length)] | add),
     mib: (([.items[] | (.|tostring|length)] | add) / 1048576 | .*100|round/100)}'
{
  "objects": 7812,
  "bytes": 96428813,
  "mib": 91.96
}
```

92 MiB es cómodo frente a una cuota de etcd por defecto de 2 GiB — pero no es el único consumidor, y el número más peligroso es la **amplificación de escrituras**, no el tamaño. Cada `UPDATE` a un recurso matcheado dispara admisión → reporte efímero → agregación → una escritura de `PolicyReport`. Un clúster que corre CronJobs que crean 500 Pods por minuto genera 500 ciclos de create/delete de reportes por minuto, cada uno una escritura completa en etcd más un fan-out de watch a cada consumidor de reportes.

Notá también el techo duro: **etcd rechaza cualquier objeto individual mayor a ~1,5 MiB** (por defecto de `--max-request-bytes`). Los reportes por recurso (Kyverno 1.10+) hacen esto casi inalcanzable; el viejo modelo agregado por namespace lo golpeaba rutinariamente en namespaces grandes, que es exactamente por qué cambió el modelo.

### 7.2 Perillas de tuning y sus trade-offs honestos

| Perilla | Efecto | Costo de moverla |
|---|---|---|
| `--skipResourceFilters=false` | Los background scans respetan el ConfigMap `resourceFilters` — la mayor reducción individual disponible | Los recursos filtrados son **invisibles** para el reporting de cumplimiento. Documentá exactamente qué dejaste ciego. |
| `resourceFilters` en el ConfigMap `kyverno` | Excluir `Event`, `kube-system`, node-lease y kinds de alta rotación | Igual que arriba |
| `--backgroundScanInterval` (↑ a `4h`/`24h`) | Menos reevaluaciones completas | Datos más viejos; el drift persiste más tiempo antes de ser detectado |
| `--backgroundScanWorkers` (↑) | Los scans terminan más rápido | Más QPS al API server y más CPU del controlador |
| Solo `--enableReporting=validate` | Descarta resultados de mutate/generate/imageVerify | Se pierde visibilidad de mutación y verificación de imágenes |
| `--admissionReports=false` | Sin reportes por admisión; el background scan pasa a ser la única fuente | Se pierde la detección de drift casi en tiempo real; la frescura cae al intervalo de scan |
| `spec.background: false` por política | Esa política nunca escanea recursos existentes | No puede responder «qué se rompería»; es obligatorio si la regla usa `request.userInfo` |
| `reportsController.enabled=false` | Ningún reporte; el admission control no se ve afectado | Pérdida total del estado de cumplimiento. Legítimo solo cuando un sistema externo es dueño del reporting. |
| Autogen apagado (`pod-policies.kyverno.io/autogen-controllers: none`) | ~3× menos entradas de reporte para reglas con forma de Pod | Los controladores ya no se evalúan en admisión — las violaciones se detectan solo en la creación del Pod, es decir después de que el Deployment fue aceptado |

Una configuración inicial concreta y segura para un clúster multi-tenant grande:

```yaml
# kyverno ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno
  namespace: kyverno
data:
  resourceFilters: >-
    [Event,*,*]
    [*,kube-system,*]
    [*,kube-public,*]
    [*,kube-node-lease,*]
    [Node,*,*]
    [Node/*,*,*]
    [APIService,*,*]
    [APIService/*,*,*]
    [TokenReview,*,*]
    [SubjectAccessReview,*,*]
    [SelfSubjectAccessReview,*,*]
    [Binding,*,*]
    [ReplicaSet,*,*]
    [EndpointSlice,*,*]
    [Endpoints,*,*]
    [ClusterRole,*,kyverno:*]
    [ClusterRoleBinding,*,kyverno:*]
    [ServiceAccount,kyverno,kyverno*]
    [ConfigMap,kyverno,kyverno]
  webhooks: '[{"namespaceSelector":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["kyverno","kube-system"]}]}}]'
```

Filtrar solo `ReplicaSet` elimina una capa redundante entera de la cadena de propiedad de autogen (§5.3) — aproximadamente un tercio de los objetos reporte en un clúster con muchos Deployments — sin perder ninguna información única de cumplimiento, porque tanto el Deployment como el Pod se siguen evaluando.

### 7.3 Reportes vs métricas — no sustituyas uno por el otro

```promql
# FLOW: rate of failing rule evaluations. Says nothing about how many
# resources are currently broken — a stable violation with no writes
# produces no admission evaluations at all.
sum by (policy_name) (rate(kyverno_policy_results_total{rule_result="fail"}[5m]))

# STOCK: current number of failing resources. Only available from the
# report objects (exported as metrics by Policy Reporter).
sum by (policy) (policy_report_result{status="fail"})
```

Un dashboard construido únicamente sobre `kyverno_policy_results_total` va a mostrar una hermosa línea plana en cero para un clúster donde 340 workloads llevan seis meses violando una política, porque nadie los actualizó y por lo tanto no se evaluó ninguna petición de admisión. **El reporte es el stock; la métrica es el flujo.** Las preguntas de gobernanza siempre son sobre el stock.

---

## 8. Interoperabilidad: un esquema, muchos productores

Como `wgpolicyk8s.io` es una API abierta, Kyverno es un productor entre varios. Por esto valió la pena estandarizar la abstracción:

| Productor | Qué reporta | Kind de reporte |
|---|---|---|
| **Kyverno** | Validación de políticas, verificación de imágenes, resultados de mutación | `PolicyReport` / `ClusterPolicyReport` |
| **Trivy Operator** (vía adapter/plugin) | Vulnerabilidades, misconfiguración, secretos expuestos | CRDs nativos, expuestos a través de la misma UI |
| **Falco** (adapter de wg-policy) | Eventos de seguridad en runtime | `PolicyReport` |
| **kube-bench** (adapter de wg-policy) | Resultados del CIS Kubernetes Benchmark | `ClusterPolicyReport` |
| **`ValidatingAdmissionPolicy` de Kubernetes** | Resultados de admisión basados en CEL, reportados por Kyverno cuando él gestiona la VAP | `PolicyReport` con un `source` distintivo |
| **Policy Reporter** | *Consumidor* — UI, exportador de Prometheus, ruteo a Slack/Teams/Loki/S3/Elasticsearch | — |

`results[].source` es el campo que los mantiene separados. Filtrá siempre por él cuando un clúster corre más de un productor:

```console
$ kubectl get polr,cpolr -A -o json \
  | jq -r '.items[].results[].source' | sort | uniq -c
   3891 kyverno
    412 falco
     87 kube-bench
```

---

## 9. Resumen enfocado al examen

1. **API**: `wgpolicyk8s.io/v1alpha2` — `PolicyReport` (`polr`, namespaced) y `ClusterPolicyReport` (`cpolr`, cluster-scoped). Propiedad del **WG Policy de Kubernetes**, no de Kyverno.
2. **¿Qué kind?** Lo determina el **ámbito del recurso evaluado**, nunca el ámbito de la política. Una `ClusterPolicy` que matchea Pods escribe `polr` namespaced.
3. **Productor**: `kyverno-reports-controller` (un deployment separado desde Kyverno 1.10). Deshabilitalo y el admission control sigue funcionando mientras los reportes desaparecen por completo.
4. **Cinco resultados**: `pass`, `fail`, `warn`, `error`, `skip`. `warn` ⇐ `policies.kyverno.io/scored: "false"`. `skip` ⇐ preconditions o una `PolicyException`. `error` ⇐ la regla no pudo ser evaluada — es un *desconocido*, no un pass.
5. **`Audit` vs `Enforce` no cambia el valor del resultado** — cambia si la admisión bloquea. Bajo `Enforce`, los creates en violación son rechazados y por lo tanto nunca producen un reporte.
6. **`spec.background: true`** (por defecto) es lo que hace visibles los recursos preexistentes. Es **incompatible** con las variables `request.userInfo`/`request.roles`/`request.operation`; esas fuerzan `background: false` y reporting solo de admisión.
7. **`category` y `severity`** provienen únicamente de las anotaciones `policies.kyverno.io/category` y `policies.kyverno.io/severity`.
8. **Nombrado y GC**: un reporte por recurso, nombrado según el UID del recurso, con una `ownerReference` a él — el borrado lo maneja el garbage collector de Kubernetes.
9. **El intervalo de background scan por defecto es `1h`** (`--backgroundScanInterval`). Forzá un rescan anticipado modificando una política.
10. **Reporting offline**: `kyverno apply <policies> --resource <manifests> --policy-report` emite un `ClusterPolicyReport` llamado `merged` y sale con código distinto de cero ante fallas — el gate de CI.
11. **Los nombres de regla con prefijo `autogen-`** aparecen en los reportes para los kinds de controladores de Pod y **deben** listarse en `PolicyException.spec.exceptions[].ruleNames`.
12. **Policy Reporter** es la UI/exportador/enrutador de notificaciones construido sobre estos CRDs; es un consumidor, no un productor.

---

## 10. Referencias

**Certificación y currículum**
- Currículum del KCA (CNCF): https://github.com/cncf/curriculum
- Kyverno Certified Associate (Linux Foundation): https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/

**Policy Reports — documentación oficial de Kyverno**
- Policy Reports: https://kyverno.io/docs/policy-reports/
- Raíz de la documentación de Kyverno: https://kyverno.io/docs/
- Instalación y flags de contenedor / personalización: https://kyverno.io/docs/installation/customization/
- Monitoreo y métricas: https://kyverno.io/docs/monitoring/
- CLI de Kyverno (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Biblioteca de políticas (uso canónico de anotaciones): https://kyverno.io/policies/

**Código fuente y definiciones de API**
- Repositorio fuente de Kyverno: https://github.com/kyverno/kyverno
- WG Policy de Kubernetes — prototipos y adapters de la Policy Report API: https://github.com/kubernetes-sigs/wg-policy-prototypes
- Referencia de valores del Helm chart de Kyverno: https://artifacthub.io/packages/helm/kyverno/kyverno

**Ecosistema de reporting**
- Documentación de Policy Reporter: https://kyverno.github.io/policy-reporter/
- Código fuente de Policy Reporter: https://github.com/kyverno/policy-reporter

**Upstream de Kubernetes**
- Dynamic admission control: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Garbage collection y owner references: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Uso de la autorización RBAC (ClusterRoles agregados): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Custom Resource Definitions: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/