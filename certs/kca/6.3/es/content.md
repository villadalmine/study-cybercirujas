# Métricas de Kyverno

**KCA Dominio 6 — Monitoring, Reporting & Troubleshooting · Competencia 6.3 · Peso en el examen 3.33%**

---

## 1. El problema en producción: un admission controller está en la ruta de escritura

Cualquier otro componente que monitorizás en Kubernetes es *adyacente* al plano de control. Kyverno está *adentro*.

Cuando un `ValidatingWebhookConfiguration` apunta a `kyverno-svc.kyverno.svc:443`, el `kube-apiserver` no va a persistir un objeto que haga match hasta que Kyverno responda. Ese solo hecho determina cada decisión sobre métricas que sigue:

| Propiedad | Consecuencia para la observabilidad |
|---|---|
| Kyverno es síncrono en la ruta de la petición a la API | Su latencia se **suma** a cada `CREATE`/`UPDATE` que haga match. La latencia es un SLI del *clúster*, no de Kyverno. |
| `failurePolicy: Fail` | Si Kyverno está lento o caído, el API server **rechaza las escrituras**. Una caída de Kyverno se convierte en una caída del clúster. |
| `failurePolicy: Ignore` | Si Kyverno está lento o caído, el API server **admite todo silenciosamente**. Tus políticas están apagadas y nada en las métricas del propio Kyverno te lo va a decir — la petición nunca llegó. |
| `webhookTimeoutSeconds` (por defecto 10, máximo 30) | Hay un presupuesto de latencia rígido. Un p99 que se le acerca es una señal previa al incidente. |
| El background scan y las reglas `generate` son asíncronos | Sus fallos son invisibles para los usuarios hasta que hay una auditoría. Necesitan una señal *separada* de la de admisión. |

De ahí se derivan dos modos de fallo, y son la razón por la que existe esta competencia:

1. **Brownout fail-closed.** Una política agrega una llamada a la API (`context.apiCall`), una consulta a un registry (`verifyImages`) o un `foreach` costoso sobre una lista grande. La latencia p99 de admisión sube de 12 ms a 4 s. Nada está "caído". Después un rollout de un Deployment con 200 pods golpea el webhook de forma concurrente, el pool de conexiones se satura, la latencia cruza los 10 s y el API server empieza a devolver `Internal error occurred: failed calling webhook "validate.kyverno.svc-fail": context deadline exceeded`. El clúster deja de aceptar cargas de trabajo.
2. **Silencio fail-open.** El mismo brownout con `failurePolicy: Ignore` produce cero errores, cero rechazos y una brecha de cumplimiento durante todo ese tiempo. El único lugar donde queda registrado es en `apiserver_admission_webhook_fail_open_count` del **API server** — no en las métricas de Kyverno, porque Kyverno nunca vio la petición.

Las métricas son el único instrumento que cubre ambos casos. Los policy reports te dicen el estado *actual* del clúster; las métricas te dicen la *tasa de cambio*, la *latencia* y el *costo*.

### 1.1 Dónde encajan las métricas entre las señales de Kyverno

| Señal | Tipo | Responde | Retención/semántica | Costo |
|---|---|---|---|---|
| **Métricas** (`/metrics`, OTel) | Series temporales | "¿Qué tan rápido? ¿Con qué frecuencia? ¿Hacia dónde tiende?" | Retención de Prometheus; agregado, baja fidelidad por evento | Barato por evento, la cardinalidad es el riesgo |
| **PolicyReport / ClusterPolicyReport** | Objetos de Kubernetes | "¿Qué recursos concretos violan qué regla *ahora mismo*?" | Estado actual reconciliado; se borra junto con el recurso | Objetos en etcd, uno por owner del recurso |
| **Eventos de Kubernetes** | Objetos, con TTL | "¿Qué decidió Kyverno sobre este objeto en particular, hace poco?" | TTL de ~1 h por defecto | Ruidoso; Kyverno omite algunos por defecto (`--omitEvents`) |
| **Logs** (`-v=2..6`) | Líneas no estructuradas/estructuradas | "¿Por qué esta evaluación concreta se comportó así?" | Backend de logs | Caro con verbosidad alta |
| **Respuesta de admisión al usuario** | Mensaje síncrono | "¿Por qué fue rechazado mi `kubectl apply`?" | Ninguna | — |

La distinción relevante para el examen: **un report responde "qué está roto", una métrica responde "qué tan roto, qué tan rápido y desde cuándo".** No podés alertar de forma útil sobre reports (no tienen tasa); no podés auditar un recurso concreto desde una métrica (no tiene nombre de recurso — deliberadamente, para acotar la cardinalidad).

---

## 2. Arquitectura del pipeline de métricas

### 2.1 OpenTelemetry adentro, Prometheus u OTLP afuera

Kyverno no se instrumenta directamente con la librería cliente de Prometheus. Usa el **SDK de OpenTelemetry** como API de instrumentación interna, y después selecciona un exporter al arrancar:

```
  ┌────────────────────────────────────────────────────────┐
  │ Kyverno controller process                             │
  │                                                        │
  │  engine ──► metrics recorders (pkg/metrics)            │
  │  webhook ──►      │                                    │
  │  clients ──►      ▼                                    │
  │             OTel Meter Provider                        │
  │                   │                                    │
  │       ┌───────────┴────────────┐                       │
  │       ▼                        ▼                       │
  │  prometheus exporter      OTLP/gRPC exporter           │
  │  (pull, :8000/metrics)    (push, --otelCollector)      │
  └───────┬────────────────────────┬───────────────────────┘
          │ scrape                 │ OTLP
          ▼                        ▼
     Prometheus              OTel Collector ──► anything
```

La selección se hace con `--otelConfig`:

| `--otelConfig` | Comportamiento | Endpoint `/metrics` | Uso típico |
|---|---|---|---|
| `prometheus` (por defecto) | Registra un exporter de Prometheus y sirve `:{--metricsPort}/metrics` | **Sí**, HTTP en texto plano | Pull desde Prometheus / VictoriaMetrics / Thanos |
| `grpc` | Empuja OTLP sobre gRPC hacia `--otelCollector` | **No** | Backends de proveedores, fan-in multi-clúster, entornos solo-mTLS |
| *(métricas deshabilitadas)* vía `--disableMetrics=true` | Sin meter provider, sin endpoint | No | Solo para restricciones extremas de cardinalidad/latencia |

Compromisos:

| Dimensión | `prometheus` (pull) | `grpc` (push a un OTel Collector) |
|---|---|---|
| Descubrimiento | El SD de Prometheus encuentra el pod; un pod muerto es `up == 0` — **la comprobación de vida sale gratis** | El collector no puede distinguir "callado" de "muerto"; necesitás un chequeo de disponibilidad aparte |
| Dirección de red | Prometheus → Kyverno (necesita ingress en una NetworkPolicy sobre el 8000) | Kyverno → Collector (egress); más amable con namespaces cerrados |
| Seguridad del transporte | Texto plano por defecto; TLS solo si le ponés algo delante | `--transportCreds` para TLS; soporte nativo de mTLS |
| Agregación | Instantánea por scrape, contadores monótonos entre reinicios | Delta/acumulativo según la configuración del SDK; el collector puede agrupar y reexportar |
| Backpressure | Ninguno — el scrape tiene éxito o falla | El exporter encola; un collector lento puede sumar presión de memoria a Kyverno |
| Fan-in multi-tenant | Un Prometheus por clúster, federar después | Natural: un collector, N clústeres, un backend |
| Simplicidad operativa | Alta — un flag, un ServiceMonitor | Menor — un segundo componente que hay que correr y monitorizar |

**Valor por defecto y respuesta de examen: `prometheus`, puerto `8000`, ruta `/metrics`, HTTP en texto plano.**

### 2.2 Cuatro controladores, cuatro endpoints de métricas — el error de producción más frecuente

Desde Kyverno 1.10 el monolito está dividido en cuatro Deployments. Cada uno es un proceso separado con su **propio** meter provider de OTel y su **propio** endpoint `/metrics`. Hacer scrape solo de `kyverno-svc-metrics` te da datos de admisión y nada más.

| Controlador | Deployment | Service de métricas | Emite (principalmente) |
|---|---|---|---|
| **Admission** | `kyverno-admission-controller` | `kyverno-svc-metrics` | `kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds`, `kyverno_policy_results_total{rule_execution_cause="admission_request"}`, `kyverno_policy_execution_duration_seconds`, `kyverno_policy_changes_total`, `kyverno_policy_rule_info_total` |
| **Background** | `kyverno-background-controller` | `kyverno-background-controller-metrics` | resultados de `generate` y `mutateExisting` (procesamiento de UpdateRequest), métricas de controlador |
| **Reports** | `kyverno-reports-controller` | `kyverno-reports-controller-metrics` | `kyverno_policy_results_total{rule_execution_cause="background_scan"}`, métricas de controlador de la reconciliación de reports |
| **Cleanup** | `kyverno-cleanup-controller` | `kyverno-cleanup-controller-metrics` | `kyverno_cleanup_controller_deletedobjects_total`, métricas de controlador |

Los cuatro exportan además las familias compartidas: `kyverno_controller_*`, `kyverno_client_queries_total`, más las series del runtime de Go (`go_*`) y del proceso (`process_*`).

> **Consecuencia de diseño:** el mismo nombre de métrica aparece en varios endpoints con distintos valores de etiqueta. Cualquier PromQL que escribas tiene que agregar entre jobs *o* seleccionar uno deliberadamente — `sum by (policy_name)(rate(kyverno_policy_results_total[5m]))` mezcla silenciosamente resultados de admisión y de background scan salvo que filtres por `rule_execution_cause`.

### 2.3 El intervalo de refresco — contadores que no son monótonos para siempre

`metricsRefreshInterval` (ConfigMap `kyverno-metrics`) **reinicia** periódicamente el registro de Prometheus. Esto es un límite deliberado de cardinalidad/memoria: sin él, una serie de un namespace que se borró hace seis meses se seguiría exportando en cada scrape, para siempre.

Consecuencias que tenés que interiorizar:

- Nunca construyas dashboards sobre el valor **crudo** del contador. `kyverno_policy_results_total` no es un total de por vida.
- Usá siempre `rate()`, `irate()` o `increase()`. Prometheus detecta los reinicios de contador y los compensa, así que estos siguen siendo correctos a través de un refresco.
- `increase(...[7d])` sobre una ventana más larga que el intervalo de refresco sigue siendo correcto en Prometheus, pero cualquier sistema externo que lea el valor crudo no lo es.
- Ponerlo en `0` deshabilita el reinicio — hacelo solo con `namespaces.exclude` y `metricsExposure` bien ajustados, o la cantidad de series crece sin límite.

---

## 3. El catálogo de métricas

Los nombres de métricas y los conjuntos de etiquetas son **específicos de cada versión**. La sección 8.1 muestra cómo enumerar exactamente lo que expone tu build; tratá las tablas de abajo como la línea base de 1.11–1.14 y verificá.

### 3.1 Inventario de políticas — `kyverno_policy_rule_info_total`

**Tipo:** Gauge (valor `1` por cada regla existente, `0`/ausente cuando se elimina)

| Etiqueta | Valores | Notas |
|---|---|---|
| `policy_name` | p. ej. `require-run-as-nonroot` | |
| `policy_namespace` | namespace, o `-` para `ClusterPolicy` | |
| `policy_type` | `cluster` \| `namespaced` | |
| `policy_validation_mode` | `enforce` \| `audit` | **La señal del rollout** |
| `policy_background_mode` | `true` \| `false` | `spec.background` |
| `rule_name` | identificador de la regla | |
| `rule_type` | `validate` \| `mutate` \| `generate` \| `imageVerify` | |
| `status_ready` | `true` \| `false` | Política compilada y webhook conectado |

**Para qué sirve:** es la única métrica que describe *configuración* en lugar de *tráfico*. Responde "¿la política que apliqué está realmente cargada y lista?" y "¿cuántas reglas siguen en audit?" — una política que existe en etcd pero nunca llega a `status_ready="true"` es invisible en todas las demás métricas, porque nunca se evalúa.

```promql
# Rules that failed to become ready — a hard alert
kyverno_policy_rule_info_total{status_ready="false"} == 1

# Enforcement posture over time: what fraction of rules actually block?
sum(kyverno_policy_rule_info_total{policy_validation_mode="enforce"})
  /
sum(kyverno_policy_rule_info_total)
```

### 3.2 Veredictos — `kyverno_policy_results_total`

**Tipo:** Counter. La métrica caballo de batalla.

| Etiqueta | Valores |
|---|---|
| `policy_name`, `policy_namespace`, `policy_type`, `policy_validation_mode`, `policy_background_mode` | como arriba |
| `rule_name`, `rule_type` | como arriba |
| `rule_result` | `pass` \| `fail` \| `warn` \| `error` \| `skip` |
| `rule_execution_cause` | `admission_request` \| `background_scan` |
| `resource_kind` | `Pod`, `Deployment`, … |
| `resource_namespace` | **la etiqueta de mayor cardinalidad** |
| `resource_request_operation` | `create` \| `update` \| `delete` |

**`rule_result` es el núcleo semántico de toda esta competencia:**

| Valor | Significado | De quién es la culpa | Acción |
|---|---|---|---|
| `pass` | El recurso satisfizo la regla | — | Línea base para los ratios |
| `fail` | El recurso **violó** la regla | El autor de la carga de trabajo | Tráfico esperado; alertá sobre *picos*, no sobre su presencia |
| `warn` | Violación reportada sin bloquear (semántica de audit) | El autor de la carga de trabajo | Telemetría del rollout |
| `error` | La regla **no se pudo evaluar** — JMESPath incorrecto, `context.apiCall` fallido, registry inalcanzable, fallo en la sustitución de variables | **Vos, el autor de la política** | Alertá siempre. Es un defecto del lado de Kyverno. |
| `skip` | Las precondiciones/`match` no aplicaron, o hubo match con una excepción | — | Útil para detectar un `PolicyException` demasiado amplio |

> Confundir `fail` con `error` es la mala lectura más común de todas. `fail` es el sistema funcionando. `error` es el sistema roto, y bajo `failurePolicy: Ignore` un `error` admite el recurso silenciosamente.

### 3.3 Latencia por regla — `kyverno_policy_execution_duration_seconds`

**Tipo:** Histogram (`_bucket`, `_sum`, `_count`). Etiquetas: el conjunto completo de `kyverno_policy_results_total`.

Este es el tiempo de motor **por regla** — excluye el handshake TLS del webhook, el decodificado de JSON, la generación de patches y la ruta de red. Usalo para atribuir una regresión de latencia a una regla concreta.

### 3.4 Tráfico de admisión — `kyverno_admission_requests_total`

**Tipo:** Counter. Etiquetas: `resource_kind`, `resource_namespace`, `resource_request_operation`.

Cuenta las peticiones AdmissionReview que **llegaron** a Kyverno. Compará contra la visión del API server: una divergencia significa que la configuración del webhook está mal o que el API server está fallando en abierto antes de contactar a Kyverno.

### 3.5 Latencia de admisión de punta a punta — `kyverno_admission_review_duration_seconds`

**Tipo:** Histogram. Etiquetas: `resource_kind`, `resource_namespace`, `resource_request_operation`.

**Este es el SLI.** Mide el manejo completo de un AdmissionReview dentro de Kyverno, y es lo que tiene que mantenerse bien por debajo de `webhookTimeoutSeconds`.

Límites de bucket por defecto (configurables, ver §4):

```
0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 15, 20, 25, 30
```

Fijate en la cola deliberada hasta los 30 s — el timeout máximo legal de un webhook. Si tus buckets se cortan en 10 s no podés distinguir "lento" de "expirado".

### 3.6 Ciclo de vida de las políticas — `kyverno_policy_changes_total`

**Tipo:** Counter. Etiquetas: el conjunto de identidad de la política más `policy_change_type` ∈ `created` | `updated` | `deleted`.

Oro puro para correlacionar: superponé esto sobre un gráfico de latencia y la mayoría de las regresiones se explican solas. Es además una señal rudimentaria de manipulación — un `deleted` inesperado sobre una política de cumplimiento merece un aviso.

### 3.7 Presión sobre el API server — `kyverno_client_queries_total`

**Tipo:** Counter. Etiquetas: `operation` (`Get`/`List`/`Watch`/`Create`/`Update`/`Patch`/`Delete`), `client_type` (`dynamic`, `kubeclient`, `kyvernoclient`, …), `resource_kind`, `resource_namespace`.

Kyverno es un cliente pesado de la API: informers, escrituras de reports, objetivos de las reglas `generate`, consultas de `context.apiCall`. En clústeres grandes Kyverno puede convertirse en el mayor consumidor de la capacidad de priority-and-fairness del API server. Esta métrica es cómo lo demostrás — o cómo lo exonerás.

### 3.8 Controladores internos — `kyverno_controller_*`

| Métrica | Tipo | Etiquetas | Significado |
|---|---|---|---|
| `kyverno_controller_reconcile_total` | Counter | `controller_name` | Trabajo procesado |
| `kyverno_controller_requeue_total` | Counter | `controller_name` | Reintentos — un crecimiento sostenido significa un objeto atascado |
| `kyverno_controller_drop_total` | Counter | `controller_name` | Ítem **abandonado** tras los reintentos máximos — pérdida permanente de datos para esa reconciliación |
| `kyverno_controller_reconcile_duration_seconds` | Histogram | `controller_name` | Latencia por reconciliación |

`kyverno_controller_drop_total > 0` significa que un report nunca se escribió o que un objetivo de `generate` nunca se creó. Es silencioso en todos los demás lugares.

### 3.9 Cleanup — `kyverno_cleanup_controller_deletedobjects_total`

**Tipo:** Counter. Etiquetas: `policy_type`, `policy_namespace`, `policy_name`, `resource_group`, `resource_version`, `resource_kind`, `resource_namespace`.

Que Kyverno borre objetos es lo de mayor radio de impacto que hace. Esta métrica más una alerta de tasa es la barrera contra una `CleanupPolicy` cuyo bloque `match` es más amplio de lo previsto.

### 3.10 Referencia rápida

| Pregunta | Métrica |
|---|---|
| ¿Están mis políticas cargadas y listas? | `kyverno_policy_rule_info_total` |
| ¿Kyverno está agregando latencia al clúster? | `kyverno_admission_review_duration_seconds` |
| ¿Qué regla está lenta? | `kyverno_policy_execution_duration_seconds` |
| ¿Cuánto tráfico ve Kyverno? | `kyverno_admission_requests_total` |
| ¿Quién viola qué, y a qué velocidad? | `kyverno_policy_results_total{rule_result="fail"}` |
| ¿Están rotas mis políticas? | `kyverno_policy_results_total{rule_result="error"}` |
| ¿Alguien cambió una política? | `kyverno_policy_changes_total` |
| ¿Kyverno está martillando el API server? | `kyverno_client_queries_total` |
| ¿Se están descartando reconciliaciones asíncronas? | `kyverno_controller_drop_total` |
| ¿El cleanup está borrando más de lo esperado? | `kyverno_cleanup_controller_deletedobjects_total` |
| **¿Se está evitando el webhook?** | **`apiserver_admission_webhook_fail_open_count` (API server, no Kyverno)** |

---

## 4. Configuración

### 4.1 El ConfigMap `kyverno-metrics` — completo

Este ConfigMap se lee al arrancar **y** se observa; la mayoría de las claves aplican sin reiniciar, pero tratá el reinicio como el camino seguro cuando cambiés `metricsRefreshInterval` o los límites de bucket.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno-metrics
  namespace: kyverno
  labels:
    app.kubernetes.io/name: kyverno
    app.kubernetes.io/part-of: kyverno
data:
  # ------------------------------------------------------------------
  # Namespace filter. Applies to the *resource_namespace* label of the
  # resource being evaluated, not to Kyverno's own namespace.
  #   include: [] + exclude: []          -> every namespace is reported
  #   include: ["a","b"]                 -> ONLY a and b are reported
  #   exclude: ["kube-system","x-*"]     -> everything except those
  # include takes precedence: if include is non-empty, exclude is moot.
  # ------------------------------------------------------------------
  namespaces: |
    {
      "include": [],
      "exclude": ["kube-system", "kube-public", "kube-node-lease", "kyverno"]
    }

  # ------------------------------------------------------------------
  # Registry reset period. Bounds unbounded series growth from churny
  # namespaces. "0" disables the reset (use only with tight filters).
  # All PromQL must use rate()/increase(); raw values are not lifetime.
  # ------------------------------------------------------------------
  metricsRefreshInterval: 24h

  # ------------------------------------------------------------------
  # Default histogram buckets for every Kyverno histogram, in seconds.
  # Keep a bucket at and beyond your webhookTimeoutSeconds, or you
  # cannot distinguish "slow" from "timed out" in histogram_quantile.
  # ------------------------------------------------------------------
  bucketBoundaries: 0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5,5,10,15,20,25,30

  # ------------------------------------------------------------------
  # Per-metric exposure control. Three independent knobs per metric:
  #   enabled                 -> emit this metric family at all
  #   disabledLabelDimensions -> drop these labels AT THE SOURCE
  #                              (values are aggregated together)
  #   bucketBoundaries        -> per-histogram override of the default
  # Dropping a label here is strictly cheaper than dropping it in
  # Prometheus with metric_relabel_configs: the series is never built,
  # never serialised, and never transferred.
  # ------------------------------------------------------------------
  metricsExposure: |
    kyverno_policy_results_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_request_operation
    kyverno_policy_execution_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_kind
      bucketBoundaries: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
    kyverno_admission_review_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
      bucketBoundaries: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 20, 25, 30]
    kyverno_admission_requests_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
    kyverno_client_queries_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
```

> **No elimines `rule_result`, `rule_execution_cause` ni `policy_validation_mode`.** Todas las alertas y todas las compuertas de rollout de §6 y §7 dependen de ellas. Eliminá `resource_namespace` primero — es el mayor multiplicador y el menos útil, porque un PolicyReport ya te dice el namespace y el recurso exactos.

### 4.2 Valores de Helm — completos, los cuatro controladores

```yaml
# values-metrics.yaml — apply with:
#   helm upgrade --install kyverno kyverno/kyverno \
#     -n kyverno --create-namespace -f values-metrics.yaml
---
# ====================================================================
# The kyverno-metrics ConfigMap, rendered by the chart.
# ====================================================================
metricsConfig:
  create: true
  namespaces:
    include: []
    exclude:
      - kube-system
      - kube-public
      - kube-node-lease
      - kyverno
  metricsRefreshInterval: 24h
  bucketBoundaries:
    - 0.005
    - 0.01
    - 0.025
    - 0.05
    - 0.1
    - 0.25
    - 0.5
    - 1
    - 2.5
    - 5
    - 10
    - 15
    - 20
    - 25
    - 30
  metricsExposure:
    kyverno_policy_results_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_request_operation
    kyverno_policy_execution_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
        - resource_kind
    kyverno_admission_review_duration_seconds:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace
    kyverno_client_queries_total:
      enabled: true
      disabledLabelDimensions:
        - resource_namespace

# ====================================================================
# Admission controller — the one on the write path.
# ====================================================================
admissionController:
  replicas: 3
  webhookTimeoutSeconds: 10
  metering:
    disabled: false          # -> --disableMetrics=false
    config: prometheus       # -> --otelConfig=prometheus
    port: 8000               # -> --metricsPort=8000
    collector: ''            # -> --otelCollector=   (grpc mode only)
    creds: ''                # -> --transportCreds=  (grpc mode only)
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 25s
    secure: false            # metrics endpoint is plaintext HTTP
    additionalLabels:
      release: kube-prometheus-stack
    relabelings: []
    metricRelabelings:
      # Second line of defence against cardinality. The first is
      # disabledLabelDimensions above — prefer that.
      - sourceLabels: [__name__]
        regex: 'go_gc_.*|go_memstats_.*_bytes_total'
        action: drop
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 1Gi

# ====================================================================
# Background controller — generate / mutateExisting.
# ====================================================================
backgroundController:
  replicas: 2
  metering:
    disabled: false
    config: prometheus
    port: 8000
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 25s
    additionalLabels:
      release: kube-prometheus-stack

# ====================================================================
# Reports controller — background scans and report aggregation.
# Highest series volume: it evaluates every policy against every
# existing resource on resync.
# ====================================================================
reportsController:
  replicas: 2
  metering:
    disabled: false
    config: prometheus
    port: 8000
  serviceMonitor:
    enabled: true
    interval: 60s            # coarser: background scan is not latency-critical
    scrapeTimeout: 50s
    additionalLabels:
      release: kube-prometheus-stack

# ====================================================================
# Cleanup controller — deletions. Low volume, high blast radius.
# ====================================================================
cleanupController:
  replicas: 2
  metering:
    disabled: false
    config: prometheus
    port: 8000
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 25s
    additionalLabels:
      release: kube-prometheus-stack

# ====================================================================
# Ship the bundled Grafana dashboard as a ConfigMap with the sidecar
# label, so kube-prometheus-stack's grafana sidecar imports it.
# ====================================================================
grafana:
  enabled: true
  namespace: monitoring
  configMapName: kyverno-grafana-dashboard
  annotations: {}
  labels:
    grafana_dashboard: "1"
```

> **`additionalLabels` es la causa más frecuente de un target que falta silenciosamente.** `kube-prometheus-stack` instala un CR `Prometheus` cuyo `serviceMonitorSelector` hace match con `release: <serviceMonitorSelector>`... — por defecto con `release: <nombre-del-release-del-stack>`. Un ServiceMonitor sin esa etiqueta es válido, está sano y es completamente ignorado. Verificá el selector antes de suponer que tu ServiceMonitor está mal (§8.4).

### 4.3 Modo push: OTLP hacia un OpenTelemetry Collector

```yaml
# Helm override for gRPC/OTLP push mode.
admissionController:
  metering:
    disabled: false
    config: grpc
    collector: 'otel-collector.observability.svc.cluster.local:4317'
    creds: ''       # empty = insecure gRPC; set to a CA cert path for TLS
  serviceMonitor:
    enabled: false  # there is NO /metrics endpoint in grpc mode
```

El Collector correspondiente, completo y desplegable:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317

    processors:
      batch:
        timeout: 10s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 5s
        limit_percentage: 80
        spike_limit_percentage: 25
      # Collector-side cardinality control: aggregate away the
      # resource_namespace dimension for the two hottest families.
      metricstransform:
        transforms:
          - include: kyverno_policy_results_total
            match_type: strict
            action: update
            operations:
              - action: aggregate_labels
                label_set: [policy_name, rule_name, rule_result, rule_execution_cause, policy_validation_mode]
                aggregation_type: sum
      attributes/cluster:
        actions:
          - key: cluster
            value: prod-eu-west-1
            action: insert

    exporters:
      prometheus:
        endpoint: 0.0.0.0:9464
        resource_to_telemetry_conversion:
          enabled: true
      debug:
        verbosity: basic

    service:
      telemetry:
        logs:
          level: info
        metrics:
          level: detailed
          address: 0.0.0.0:8888
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, attributes/cluster, metricstransform, batch]
          exporters: [prometheus]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: otel-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: otel-collector
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.111.0
          args: ["--config=/conf/config.yaml"]
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: prom
              containerPort: 9464
            - name: self-metrics
              containerPort: 8888
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 200m
              memory: 400Mi
            limits:
              memory: 800Mi
          volumeMounts:
            - name: config
              mountPath: /conf
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app.kubernetes.io/name: otel-collector
spec:
  selector:
    app.kubernetes.io/name: otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
    - name: prom
      port: 9464
      targetPort: prom
    - name: self-metrics
      port: 8888
      targetPort: self-metrics
```

---

## 5. Infraestructura de scrape

### 5.1 Un único ServiceMonitor para los cuatro controladores

En lugar de cuatro objetos, seleccioná por la etiqueta compartida `part-of`. Verificá primero la etiqueta y el nombre del puerto (§8.2) — dependen de la versión del chart.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kyverno
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # MUST match Prometheus.spec.serviceMonitorSelector
spec:
  namespaceSelector:
    matchNames: ["kyverno"]
  selector:
    matchLabels:
      app.kubernetes.io/part-of: kyverno
  # Only Services that actually expose the metrics port will match an
  # endpoint; kyverno-svc (443/webhook) is selected but yields nothing.
  endpoints:
    - port: metrics-port
      path: /metrics
      scheme: http
      interval: 30s
      scrapeTimeout: 25s
      honorLabels: false
      relabelings:
        # Keep the controller identity as a first-class label so you can
        # slice by which process produced a series.
        - sourceLabels: [__meta_kubernetes_service_label_app_kubernetes_io_component]
          targetLabel: kyverno_controller
          action: replace
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
          action: replace
      metricRelabelings:
        # Drop Go GC histogram noise — large and rarely actionable here.
        - sourceLabels: [__name__]
          regex: 'go_gc_duration_seconds.*|go_memstats_.*'
          action: drop
        # Emergency cardinality valve: uncomment to collapse namespaces.
        # - regex: 'resource_namespace'
        #   action: labeldrop
```

### 5.2 Prometheus a secas (sin Operator)

```yaml
scrape_configs:
  - job_name: kyverno
    scheme: http
    metrics_path: /metrics
    scrape_interval: 30s
    scrape_timeout: 25s
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [kyverno]
    relabel_configs:
      # Keep only the metrics ports of Kyverno services.
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_part_of]
        regex: kyverno
        action: keep
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        regex: metrics-port
        action: keep
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_component]
        target_label: kyverno_controller
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'go_memstats_.*|go_gc_.*'
        action: drop
```

### 5.3 NetworkPolicy — el clásico fallo silencioso

Si el namespace `kyverno` tiene una política de ingress con denegación por defecto, los scrapes fallan con `connection refused`/`i/o timeout` y el target aparece `DOWN` sin ni una sola línea de log del lado de Kyverno.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: kyverno
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/part-of: kyverno
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 8000
```

---

## 6. Recetario de PromQL

### 6.1 El SLI: latencia de admisión

```promql
# p99 end-to-end admission handling, per operation, across ALL admission pods
histogram_quantile(0.99,
  sum by (le, resource_request_operation) (
    rate(kyverno_admission_review_duration_seconds_bucket[5m])
  )
)

# Latency budget burn: fraction of reviews slower than 1s
1 - (
  sum(rate(kyverno_admission_review_duration_seconds_bucket{le="1"}[5m]))
  /
  sum(rate(kyverno_admission_review_duration_seconds_count[5m]))
)

# Headroom against the webhook timeout (webhookTimeoutSeconds: 10)
histogram_quantile(0.99,
  sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
) / 10
```

### 6.2 Atribuir una regresión a una regla

```promql
# Top 10 slowest rules by p95 engine time
topk(10,
  histogram_quantile(0.95,
    sum by (le, policy_name, rule_name) (
      rate(kyverno_policy_execution_duration_seconds_bucket{rule_execution_cause="admission_request"}[5m])
    )
  )
)

# Mean engine time per rule — cheaper and often enough to spot the outlier
sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_sum[5m]))
  /
sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_count[5m]))
```

### 6.3 Políticas rotas (no violaciones)

```promql
# Rules that cannot be evaluated. Non-zero = defect.
sum by (policy_name, rule_name, rule_type) (
  rate(kyverno_policy_results_total{rule_result="error"}[5m])
) > 0

# Error ratio per policy
sum by (policy_name) (rate(kyverno_policy_results_total{rule_result="error"}[10m]))
  /
sum by (policy_name) (rate(kyverno_policy_results_total[10m]))
```

### 6.4 La compuerta de rollout de audit → enforce

El sentido entero del modo `Audit` es reunir este número antes de pasar a `Enforce`.

```promql
# Violations a policy WOULD have blocked in the last 24h, per policy.
# Promote to Enforce only when this is 0 (or an accepted list).
sort_desc(
  sum by (policy_name, rule_name) (
    increase(kyverno_policy_results_total{
      rule_result="fail",
      policy_validation_mode="audit",
      rule_execution_cause="admission_request"
    }[24h])
  )
)

# Which kinds would break — the blast-radius preview
sum by (policy_name, resource_kind) (
  increase(kyverno_policy_results_total{rule_result="fail", policy_validation_mode="audit"}[7d])
)
```

### 6.5 Impacto de la aplicación (post-promoción)

```promql
# Requests actually blocked, per minute
sum by (policy_name, rule_name) (
  rate(kyverno_policy_results_total{
    rule_result="fail",
    policy_validation_mode="enforce",
    rule_execution_cause="admission_request"
  }[5m])
) * 60
```

### 6.6 Background scan frente a admisión

```promql
# Split the workload by origin — proves whether reports-controller is scraped
sum by (rule_execution_cause) (rate(kyverno_policy_results_total[5m]))

# Existing-fleet debt: violations found by scanning, not by admission
sum by (policy_name) (
  rate(kyverno_policy_results_total{rule_result="fail", rule_execution_cause="background_scan"}[15m])
)
```

### 6.7 Costo para el plano de control

```promql
topk(10,
  sum by (client_type, operation, resource_kind) (rate(kyverno_client_queries_total[5m]))
)

# Reconcile health
sum by (controller_name) (rate(kyverno_controller_drop_total[5m])) > 0
sum by (controller_name) (rate(kyverno_controller_requeue_total[5m]))
histogram_quantile(0.95,
  sum by (le, controller_name) (rate(kyverno_controller_reconcile_duration_seconds_bucket[5m])))
```

### 6.8 Autoauditoría de cardinalidad

```promql
topk(15, count by (__name__) ({__name__=~"kyverno_.+"}))
count({__name__=~"kyverno_.+"})
count(count by (resource_namespace) (kyverno_policy_results_total))
topk(5, sum by (job) (scrape_samples_scraped))
```

---

## 7. Alertas — `PrometheusRule` completo

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    # ================================================================
    # Availability of the admission path.
    # ================================================================
    - name: kyverno.availability
      rules:
        - alert: KyvernoTargetDown
          expr: up{job=~".*kyverno.*"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno metrics target down ({{ $labels.pod }})"
            description: >-
              Prometheus cannot scrape {{ $labels.job }}/{{ $labels.pod }}.
              If failurePolicy is Fail, the cluster may be rejecting writes;
              if Ignore, policies are being bypassed. Check the pod and the
              NetworkPolicy on the kyverno namespace.

        - alert: KyvernoNoAdmissionTraffic
          # Webhook is configured but Kyverno sees nothing: broken
          # webhook configuration, wrong CA bundle, or Service mismatch.
          expr: |
            sum(rate(kyverno_admission_requests_total[15m])) == 0
            and on() (sum(kyverno_policy_rule_info_total) > 0)
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno has policies loaded but receives zero admission requests"
            description: >-
              Policies exist and are ready, yet no AdmissionReview reached
              Kyverno in 15 minutes. Inspect the ValidatingWebhookConfiguration
              rules/objectSelector and the caBundle.

    # ================================================================
    # Latency — the cluster-wide SLI.
    # ================================================================
    - name: kyverno.latency
      rules:
        - alert: KyvernoAdmissionLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Kyverno p99 admission latency > 1s"
            description: "p99 is {{ $value | humanizeDuration }}; every matched write pays this."

        - alert: KyvernoAdmissionLatencyNearWebhookTimeout
          # 70% of a 10s webhookTimeoutSeconds. Adjust the divisor if you
          # changed the timeout.
          expr: |
            histogram_quantile(0.99,
              sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
            ) > 7
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno p99 latency is approaching webhookTimeoutSeconds"
            description: >-
              p99 = {{ $value | humanizeDuration }} against a 10s timeout.
              With failurePolicy=Fail this becomes cluster-wide write
              rejection; with Ignore it becomes silent policy bypass.

    # ================================================================
    # Correctness of the policies themselves.
    # ================================================================
    - name: kyverno.policy-health
      rules:
        - alert: KyvernoRuleExecutionErrors
          expr: |
            sum by (policy_name, rule_name) (
              rate(kyverno_policy_results_total{rule_result="error"}[10m])
            ) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Rule {{ $labels.policy_name }}/{{ $labels.rule_name }} is erroring"
            description: >-
              rule_result=error means the rule could NOT be evaluated (bad
              JMESPath, failed context.apiCall, unreachable registry). This is
              a policy defect, not a workload violation. Under
              failurePolicy=Ignore the resource is admitted unchecked.

        - alert: KyvernoPolicyNotReady
          expr: kyverno_policy_rule_info_total{status_ready="false"} == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Policy {{ $labels.policy_name }} rule {{ $labels.rule_name }} is not ready"

        - alert: KyvernoEnforceDenialSpike
          expr: |
            sum by (policy_name, rule_name) (
              rate(kyverno_policy_results_total{
                rule_result="fail", policy_validation_mode="enforce",
                rule_execution_cause="admission_request"}[5m])
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.policy_name }} is blocking >1 request/s"
            description: "Either a bad deploy or an over-broad policy. Check PolicyReports for the offending resources."

        - alert: KyvernoPolicyDeleted
          expr: increase(kyverno_policy_changes_total{policy_change_type="deleted"}[10m]) > 0
          labels:
            severity: info
          annotations:
            summary: "Policy {{ $labels.policy_name }} was deleted"

    # ================================================================
    # Asynchronous work and blast radius.
    # ================================================================
    - name: kyverno.background
      rules:
        - alert: KyvernoControllerDroppingWork
          expr: sum by (controller_name) (rate(kyverno_controller_drop_total[10m])) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Controller {{ $labels.controller_name }} is dropping items"
            description: >-
              Items abandoned after max retries. Reports may be stale and
              generate/mutateExisting targets may never be created.

        - alert: KyvernoCleanupDeletionSpike
          expr: |
            sum by (policy_name, resource_kind) (
              increase(kyverno_cleanup_controller_deletedobjects_total[10m])
            ) > 50
          labels:
            severity: critical
          annotations:
            summary: "CleanupPolicy {{ $labels.policy_name }} deleted >50 {{ $labels.resource_kind }} in 10m"

    # ================================================================
    # The API server's own view. NOT Kyverno metrics — and the only
    # place a fail-open bypass is ever recorded.
    # ================================================================
    - name: kyverno.apiserver-view
      rules:
        - alert: KyvernoWebhookFailingOpen
          expr: |
            increase(apiserver_admission_webhook_fail_open_count{name=~".*kyverno.*"}[10m]) > 0
          labels:
            severity: critical
          annotations:
            summary: "API server is failing OPEN on webhook {{ $labels.name }}"
            description: >-
              Requests are being admitted WITHOUT policy evaluation because
              the webhook (failurePolicy=Ignore) errored or timed out. This
              is a live compliance gap and is invisible in Kyverno's metrics.

        - alert: KyvernoWebhookApiserverLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le, name) (
                rate(apiserver_admission_webhook_admission_duration_seconds_bucket{name=~".*kyverno.*"}[5m])
              )
            ) > 2
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "API server measures p99 {{ $value | humanizeDuration }} for {{ $labels.name }}"
            description: >-
              Compare with kyverno_admission_review_duration_seconds. A large
              gap is network/TLS/queueing outside the Kyverno process.
```

### 7.1 Por qué dos puntos de observación son obligatorios

| Medido desde | Métrica | Incluye | Ciego a |
|---|---|---|---|
| **Dentro de Kyverno** | `kyverno_admission_review_duration_seconds` | Motor, evaluación de políticas, generación de patches | Peticiones que nunca llegaron; handshake TLS; red; encolado del lado del API server |
| **Desde el API server** | `apiserver_admission_webhook_admission_duration_seconds{name=~".*kyverno.*"}` | Todo, incluidos red y TLS | Qué política/regla fue la responsable |
| **Desde el API server** | `apiserver_admission_webhook_rejection_count{name=~".*kyverno.*"}` | Denegaciones y errores, con `rejection_code` y `error_type` | Atribución a la regla |
| **Desde el API server** | `apiserver_admission_webhook_fail_open_count{name=~".*kyverno.*"}` | **Bypasses silenciosos** | Todo lo demás |

Los nombres de webhook de Kyverno, útiles como selectores de etiqueta: `validate.kyverno.svc-fail`, `validate.kyverno.svc-ignore`, `mutate.kyverno.svc-fail`, `mutate.kyverno.svc-ignore`.

---

## 8. Verificación y diagnóstico de fallos

Las transcripciones de terminal de abajo son de un clúster representativo (kind, Kyverno instalado con el chart `kyverno/kyverno` en el namespace `kyverno`). Los valores exactos van a diferir; lo que importa es la **forma** de la salida y el razonamiento.

### 8.1 Probar que el endpoint existe y enumerar lo que expone

```bash
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    3/3     3            3           4d2h
kyverno-background-controller   2/2     2            2           4d2h
kyverno-cleanup-controller      2/2     2            2           4d2h
kyverno-reports-controller      2/2     2            2           4d2h

$ kubectl -n kyverno get svc
NAME                                    TYPE        CLUSTER-IP       PORT(S)     AGE
kyverno-background-controller-metrics   ClusterIP   10.96.121.44     8000/TCP    4d2h
kyverno-cleanup-controller              ClusterIP   10.96.9.201      443/TCP     4d2h
kyverno-cleanup-controller-metrics      ClusterIP   10.96.55.180     8000/TCP    4d2h
kyverno-reports-controller-metrics      ClusterIP   10.96.203.17     8000/TCP    4d2h
kyverno-svc                             ClusterIP   10.96.180.22     443/TCP     4d2h
kyverno-svc-metrics                     ClusterIP   10.96.44.108     8000/TCP    4d2h
```

Cuatro Services `*-metrics`. Si ves solo uno, estás en Kyverno < 1.10 (monolito) o hay controladores deshabilitados.

Confirmá el modo del exporter desde los argumentos en ejecución — nunca de memoria:

```bash
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' \
    | grep -E 'otel|metrics|disableMetrics'
--disableMetrics=false
--otelConfig=prometheus
--metricsPort=8000
--otelCollector=
--transportCreds=
```

Hacele scrape directamente:

```bash
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
[1] 24815

$ curl -s localhost:8000/metrics | grep -c '^kyverno_'
1476

# Enumerate the metric FAMILIES this build exposes — the authoritative list
$ curl -s localhost:8000/metrics | grep '^# TYPE kyverno_' | sort
# TYPE kyverno_admission_requests_total counter
# TYPE kyverno_admission_review_duration_seconds histogram
# TYPE kyverno_client_queries_total counter
# TYPE kyverno_controller_drop_total counter
# TYPE kyverno_controller_reconcile_total counter
# TYPE kyverno_controller_requeue_total counter
# TYPE kyverno_policy_changes_total counter
# TYPE kyverno_policy_execution_duration_seconds histogram
# TYPE kyverno_policy_results_total counter
# TYPE kyverno_policy_rule_info_total gauge

# Inspect the real label set of one family
$ curl -s localhost:8000/metrics | grep '^kyverno_policy_results_total' | head -3
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-run-as-nonroot",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="run-as-non-root",rule_result="pass",rule_type="validate"} 1184
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-run-as-nonroot",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="run-as-non-root",rule_result="fail",rule_type="validate"} 37
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="disallow-host-path",policy_namespace="-",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="host-path",rule_result="fail",rule_type="validate"} 9
```

Fijate que `resource_namespace` no está — eso es `disabledLabelDimensions` de §4.1 funcionando. Fijate en `otel_scope_name` — lo agrega el exporter de Prometheus de OpenTelemetry; no te sorprendas y no hagas `sum by ()` de una forma que lo divida accidentalmente.

### 8.2 Descubrir el nombre del puerto y las etiquetas que tiene que usar tu ServiceMonitor

```bash
$ kubectl -n kyverno get svc -l app.kubernetes.io/part-of=kyverno \
    -o custom-columns='NAME:.metadata.name,PORTNAME:.spec.ports[*].name,COMPONENT:.metadata.labels.app\.kubernetes\.io/component'
NAME                                    PORTNAME       COMPONENT
kyverno-background-controller-metrics   metrics-port   background-controller
kyverno-cleanup-controller              https          cleanup-controller
kyverno-cleanup-controller-metrics      metrics-port   cleanup-controller
kyverno-reports-controller-metrics      metrics-port   reports-controller
kyverno-svc                             https          admission-controller
kyverno-svc-metrics                     metrics-port   admission-controller
```

El ServiceMonitor de §5.1 selecciona `app.kubernetes.io/part-of: kyverno` y el endpoint `metrics-port` — confirmado por esta salida. Nunca copies el nombre de un puerto de un blog; leelo del clúster.

### 8.3 Generar tráfico y ver moverse un contador

Las familias de métricas de Kyverno se crean de forma perezosa. Una instalación recién hecha sin tráfico que haga match expone legítimamente solo `go_*`/`process_*` más `kyverno_policy_rule_info_total`.

```bash
$ cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Pods must carry the label 'team'."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
clusterpolicy.kyverno.io/require-team-label created

$ kubectl get clusterpolicy require-team-label
NAME                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-team-label   true        true         Audit             True    12s   Ready

$ curl -s localhost:8000/metrics \
  | grep 'kyverno_policy_rule_info_total.*require-team-label'
kyverno_policy_rule_info_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="audit",rule_name="check-team-label",rule_type="validate",status_ready="true"} 1

$ kubectl run probe-nolabel --image=nginx:1.27-alpine --restart=Never
pod/probe-nolabel created

$ curl -s localhost:8000/metrics \
  | grep 'kyverno_policy_results_total.*require-team-label'
kyverno_policy_results_total{otel_scope_name="kyverno",policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="fail",rule_type="validate"} 1
```

`rule_result="fail"` con `policy_validation_mode="audit"` y el Pod creado: exactamente la señal de rollout en modo audit de §6.4. Pasalo a `Enforce` y el mismo contador se incrementa mientras el Pod es rechazado:

```bash
$ kubectl patch clusterpolicy require-team-label --type=merge \
    -p '{"spec":{"validationFailureAction":"Enforce"}}'
clusterpolicy.kyverno.io/require-team-label patched

$ kubectl run probe-nolabel-2 --image=nginx:1.27-alpine --restart=Never
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/probe-nolabel-2 was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: Pods must carry the label ''team''. rule
    check-team-label failed at path /metadata/labels/team/'

$ curl -s localhost:8000/metrics | grep 'kyverno_policy_changes_total'
kyverno_policy_changes_total{otel_scope_name="kyverno",policy_background_mode="true",policy_change_type="updated",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="enforce"} 1
```

Limpieza:

```bash
$ kubectl delete pod probe-nolabel --ignore-not-found
$ kubectl delete clusterpolicy require-team-label
```

### 8.4 Verificación del lado de Prometheus

```bash
$ kubectl -n monitoring get servicemonitor kyverno -o yaml | yq '.spec'
namespaceSelector:
  matchNames: [kyverno]
selector:
  matchLabels:
    app.kubernetes.io/part-of: kyverno
endpoints:
  - port: metrics-port
    path: /metrics
    interval: 30s

# THE check that catches the silent-ignore failure: does Prometheus even
# look at ServiceMonitors with your labels?
$ kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'; echo
{"matchLabels":{"release":"kube-prometheus-stack"}}

$ kubectl -n monitoring get servicemonitor kyverno --show-labels
NAME      AGE   LABELS
kyverno   3d    release=kube-prometheus-stack
```

Si esos dos no coinciden, el ServiceMonitor es inerte y no se registra ningún error en ninguna parte.

Después confirmá que los targets están realmente arriba — los cuatro:

```bash
$ kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/dev/null 2>&1 &

$ curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("kyverno"))
           | [.labels.job, .labels.kyverno_controller, .health, .lastError] | @tsv'
kyverno-svc-metrics                     admission-controller    up
kyverno-background-controller-metrics   background-controller   up
kyverno-reports-controller-metrics      reports-controller      up
kyverno-cleanup-controller-metrics      cleanup-controller      up

$ curl -sG 'localhost:9090/api/v1/query' \
    --data-urlencode 'query=sum by (rule_execution_cause) (rate(kyverno_policy_results_total[5m]))' \
  | jq -r '.data.result[] | "\(.metric.rule_execution_cause)\t\(.value[1])"'
admission_request       2.4666666666666663
background_scan         0.8333333333333334
```

Ambas causas presentes ⇒ se está haciendo scrape de los controladores de admisión **y** de reports. Si falta `background_scan`, tenés el error de §2.2.

Validá las reglas antes de publicarlas:

```bash
$ promtool check rules kyverno-rules.yaml
Checking kyverno-rules.yaml
  SUCCESS: 12 rules found
```

### 8.5 Matriz de diagnóstico

| Síntoma | Causa más probable | Confirmar con | Solución |
|---|---|---|---|
| `curl :8000/metrics` → connection refused | `--disableMetrics=true`, o `--otelConfig=grpc` (no hay endpoint HTTP en modo push), o `--metricsPort` incorrecto | `kubectl -n kyverno get deploy … -o jsonpath='{…args}'` | Poné `metering.disabled: false`, `metering.config: prometheus` |
| El endpoint responde pero **solo** con `go_*`/`process_*` | Todavía no hubo tráfico de admisión que haga match — las familias se registran de forma perezosa | `kubectl run` de un recurso que haga match (§8.3) | Ninguna; es el comportamiento correcto |
| `kyverno_policy_results_total` presente, `kyverno_admission_requests_total` en 0 | El webhook no está conectado: `caBundle` incorrecto, `objectSelector` erróneo o Service que no coincide | `kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o yaml` | Reiniciá el admission controller para que se vuelva a registrar; revisá los endpoints de `kyverno-svc` |
| Falta una familia de métricas entera en `/metrics` | `metricsExposure.<metric>.enabled: false` | `kubectl -n kyverno get cm kyverno-metrics -o yaml` | Volvé a habilitarla, reiniciá el controlador |
| Falta una etiqueta donde la documentación dice que existe | `disabledLabelDimensions`, o un `labeldrop` en `metricRelabelings` | El mismo ConfigMap; después el ServiceMonitor | Quitá el drop — lo más barato es en el origen |
| Todos los namespaces colapsan en una sola serie | Filtro `namespaces.include`/`exclude` | El mismo ConfigMap | Ajustá el filtro |
| Los contadores caen a cero de forma programada | Reinicio por `metricsRefreshInterval` | Valor del ConfigMap | Es lo esperado. Usá `rate()`/`increase()`, nunca valores crudos |
| Target de Prometheus `DOWN`, `context deadline exceeded` | NetworkPolicy bloqueando el 8000, o `scrapeTimeout` < duración del scrape | `kubectl -n kyverno get netpol`; `lastError` del target | Aplicá §5.3; subí el `scrapeTimeout` |
| El ServiceMonitor existe, no aparece ningún target | `Prometheus.spec.serviceMonitorSelector` no coincide con sus etiquetas; o `namespaceSelector` erróneo; o nombre de puerto incorrecto | §8.4 | Agregá la etiqueta `release:`; corregí el nombre del puerto a `metrics-port` |
| Solo métricas de admisión, sin datos de background/reports | Solo se hace scrape de `kyverno-svc-metrics` | `sum by (rule_execution_cause)(...)` devuelve una sola serie | Seleccioná por `app.kubernetes.io/part-of: kyverno` (§5.1) |
| La misma serie duplicada con distinto `pod` | Varias réplicas — correcto y esperado | `count by (pod)(...)` | Hacé siempre `sum by (…)` entre pods; nunca grafiques una sola réplica |
| `histogram_quantile` devuelve `+Inf` | El p99 cae más allá del mayor bucket finito | `curl … \| grep '_bucket{le="+Inf"'` | Extendé `bucketBoundaries` más allá de `webhookTimeoutSeconds` |
| La memoria de Prometheus sube tras habilitar Kyverno | Explosión de `resource_namespace` × `resource_kind` × `policy` × `rule` | `topk(15, count by (__name__)({__name__=~"kyverno_.+"}))` | `disabledLabelDimensions: [resource_namespace]` |
| p99 de latencia alto, ninguna regla destaca | El costo está fuera del motor: TLS, llamadas a la API, registry | `kyverno_client_queries_total`; comparar con `apiserver_admission_webhook_admission_duration_seconds` | Cachear con `enableConfigMapCaching`, reducir `context.apiCall`, agregar réplicas |
| `rule_result="error"` sostenido | JMESPath incorrecto, registry inalcanzable, `apiCall` fallido, hueco de RBAC para una consulta de `context` | `kubectl -n kyverno logs deploy/kyverno-admission-controller \| grep -i "failed to"` | Corregí la regla; probala con `kyverno apply` en CI |
| Escrituras rechazadas en todo el clúster, las métricas de Kyverno se ven bien | Timeouts — Kyverno nunca registró la petición | `apiserver_admission_webhook_rejection_count{error_type="calling_webhook_error"}` | Escalá horizontalmente, subí el timeout, o poné `failurePolicy: Ignore` en los webhooks no críticos |
| No se detectan violaciones, pero los reports las muestran | Bypass fail-open en el API server | `apiserver_admission_webhook_fail_open_count{name=~".*kyverno.*"}` | Arreglá la disponibilidad; reconsiderá el `failurePolicy` |

### 8.6 Presupuesto de cardinalidad — hacé la aritmética antes de desplegar

Cantidad de series en el peor caso para `kyverno_policy_results_total`:

```
policies × rules_per_policy × resource_kinds × namespaces
        × resource_request_operations(3) × rule_results(5) × rule_execution_causes(2)
```

Un parque modesto — 25 políticas × 3 reglas × 8 kinds × 300 namespaces × 3 × 5 × 2 — son **5,4 millones** de series, de una sola métrica, por clúster. Sumale el histograma (`_bucket` multiplica por la cantidad de límites + 2) y ya estás más allá de lo que la mayoría de los despliegues de Prometheus va a sobrevivir.

Mitigación, en orden de preferencia:

| Palanca | Dónde | Efecto | Costo |
|---|---|---|---|
| `disabledLabelDimensions: [resource_namespace]` | ConfigMap de Kyverno | ÷ 300 | Perdés la atribución de namespace en las métricas (los PolicyReports la siguen teniendo) |
| `namespaces.exclude` | ConfigMap de Kyverno | Elimina el ruido de los namespaces de sistema | Esos namespaces se vuelven invisibles |
| `disabledLabelDimensions: [resource_request_operation]` | ConfigMap de Kyverno | ÷ 3 | No podés separar create de update |
| `bucketBoundaries` más cortos en `policy_execution_duration` | ConfigMap de Kyverno | ÷ ~2 en ese histograma | Cuantiles de latencia más gruesos |
| `metricsExposure.<metric>.enabled: false` | ConfigMap de Kyverno | Elimina una familia | Perdés esa señal por completo |
| `metricRelabelings` / `labeldrop` | ServiceMonitor | La misma reducción de series en la TSDB | Kyverno igual las construye y las serializa — **CPU y ancho de banda desperdiciados** |
| `metricsRefreshInterval` | ConfigMap de Kyverno | Acota las series muertas acumuladas | Los contadores se reinician |

**Regla práctica:** eliminá en el origen (`disabledLabelDimensions`) en lugar de en el scraper (`metricRelabelings`); el drop del lado del scraper paga el costo completo de producción y solo ahorra almacenamiento.

---

## 9. Repaso enfocado al examen

- Puerto de métricas por defecto: **8000**, ruta **`/metrics`**, esquema **HTTP** (texto plano).
- Flags: `--otelConfig` (`prometheus` | `grpc`), `--metricsPort`, `--otelCollector`, `--transportCreds`, `--disableMetrics`.
- ConfigMap de configuración: **`kyverno-metrics`** en el namespace de Kyverno. Claves: `namespaces`, `metricsRefreshInterval`, `bucketBoundaries`, `metricsExposure`.
- SDK de instrumentación: **OpenTelemetry**, exportado como endpoint pull de Prometheus o empujado vía OTLP/gRPC.
- **Cuatro controladores ⇒ cuatro Services de métricas** desde la 1.10.
- Valores de `rule_result`: `pass`, `fail`, `warn`, `error`, `skip`. `fail` = violación; **`error` = la regla no se pudo ejecutar**.
- `rule_execution_cause`: `admission_request` frente a `background_scan`.
- Los contadores se reinician con `metricsRefreshInterval` ⇒ usá siempre `rate()`/`increase()`.
- Métricas ≠ reports: las métricas tienen tasas y latencia, sin nombres de recursos; los reports tienen nombres de recursos, sin historial.
- Los bypasses fail-open aparecen únicamente en **`apiserver_admission_webhook_fail_open_count`**, nunca en las métricas de Kyverno.

---

## 10. Referencias

**Kyverno — documentación oficial**
- Monitoring and metrics: https://kyverno.io/docs/monitoring/
- Installation and configuration: https://kyverno.io/docs/installation/
- Configuring Kyverno (ConfigMaps, flags): https://kyverno.io/docs/installation/customization/
- Container flags reference: https://kyverno.io/docs/installation/customization/#container-flags
- High availability and controller split: https://kyverno.io/docs/high-availability/
- Policy reports: https://kyverno.io/docs/policy-reports/
- Troubleshooting: https://kyverno.io/docs/troubleshooting/
- Cleanup policies: https://kyverno.io/docs/policy-types/cleanup-policy/

**Kyverno — código fuente y chart**
- Repository: https://github.com/kyverno/kyverno
- Metrics implementation (`pkg/metrics`): https://github.com/kyverno/kyverno/tree/main/pkg/metrics
- Helm chart values (`metering`, `serviceMonitor`, `metricsConfig`, `grafana`): https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml
- Helm chart README: https://github.com/kyverno/kyverno/blob/main/charts/kyverno/README.md
- Releases and version-specific metric changes: https://github.com/kyverno/kyverno/releases

**Kubernetes — el punto de observación del API server**
- Dynamic admission control (webhooks, `failurePolicy`, `timeoutSeconds`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes system metrics: https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Metrics reference (`apiserver_admission_webhook_*`): https://kubernetes.io/docs/reference/instrumentation/metrics/
- API Priority and Fairness: https://kubernetes.io/docs/concepts/cluster-administration/flow-control/

**Prometheus y el Operator**
- Metric types: https://prometheus.io/docs/concepts/metric_types/
- Querying basics and functions (`rate`, `increase`, `histogram_quantile`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Configuration (`scrape_configs`, `relabel_configs`, `metric_relabel_configs`): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Cardinality guidance (naming and labels): https://prometheus.io/docs/practices/naming/
- Prometheus Operator API (`ServiceMonitor`, `PrometheusRule`): https://prometheus-operator.dev/docs/api-reference/api/
- kube-prometheus-stack chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

**OpenTelemetry**
- Collector documentation: https://opentelemetry.io/docs/collector/
- Prometheus exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/prometheusexporter
- Metrics transform processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/metricstransformprocessor

**Certificación**
- KCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- CNCF curriculum repository: https://github.com/cncf/curriculum