# Tema 1.2 — Convenciones semánticas

> **Peso en el examen: 4.5** · Dominio 1 (Fundamentos de la Observabilidad / OpenTelemetry)
> Perfil: SRE / Arquitecto de Plataforma — profundidad de nivel productivo.

Las convenciones semánticas son la parte más subestimada de la especificación de OpenTelemetry y, en la práctica, la diferencia entre una telemetría que *se federa* a lo largo de una flota y una telemetría que es un dialecto por equipo que nadie puede consultar. Este capítulo las trata como un contrato, no como una guía de estilo.

---

## 1. Motivación y el problema de arquitectura en producción

### 1.1 El problema que las convenciones semánticas realmente resuelven

OpenTelemetry desacopla tres cosas que antes venían soldadas en un único agente de proveedor:

1. **Instrumentación** — el código que *produce* señales (traces, metrics, logs).
2. **Transporte** — OTLP sobre gRPC/HTTP.
3. **Análisis** — el backend que almacena y consulta los datos (Tempo, Jaeger, Prometheus, un SaaS, etc.).

Desacoplar el formato de cable (OTLP) es necesario pero **no suficiente**. OTLP garantiza la *forma* de un span — tiene un nombre, un tiempo de inicio, un kind y una bolsa de atributos clave/valor. No dice nada sobre *cómo se llaman las claves ni qué significan los valores*. Dos equipos que instrumentan el mismo framework HTTP pueden ambos emitir OTLP perfectamente válido y aun así ser mutuamente ilegibles:

```text
Team A span attributes          Team B span attributes
------------------------        --------------------------------
method:  "GET"                  http.verb:        "get"
status:  200                    response.code:    "200"
path:    "/orders/42"           endpoint:         "/orders/{id}"
host:    "api.shop"             upstream.host:    "api.shop:443"
```

Ahora cada dashboard del backend, cada alerta, cada consulta de SLO y cada correlación trace-a-metric tiene que conocer ambos dialectos. La cardinalidad explota, las consultas `PromQL`/`TraceQL`/`LogQL` se bifurcan por equipo, y los traces entre servicios se rompen en el límite porque el padre y el hijo describen la misma llamada HTTP con vocabularios distintos.

**Las convenciones semánticas son el vocabulario compartido.** Son un registro versionado de nombres de atributos, sus tipos de valor, sus valores permitidos (enums), sus unidades y su *nivel de requerimiento*, publicado por el proyecto OpenTelemetry. Cuando todo productor emite `http.request.method`, un único dashboard, una única alerta y una única consulta de SLO funcionan a lo largo de toda la flota — sin importar el lenguaje, el framework o el proveedor.

### 1.2 Por qué esto es una preocupación *arquitectónica*, no una nimiedad de nomenclatura

En una plataforma de cualquier tamaño el rédito se compone:

- **Portabilidad del análisis.** Los dashboards agnósticos del backend se despachan como código porque los nombres de los campos están fijos. Podés reemplazar Jaeger por Tempo sin reescribir consultas.
- **Correlación entre señales.** Los exemplars vinculan un bucket de métrica a un trace, y un trace a logs, *solo* si `service.name`, `trace_id` y `service.instance.id` significan lo mismo en todas partes. La correlación es un join, y un join necesita una clave compartida.
- **Control de costos.** La cardinalidad es una línea de facturación en todo backend de métricas. Las convenciones prescriben atributos de *baja cardinalidad* para las dimensiones de métricas (`http.route`, no `url.path`) — la palanca más efectiva contra un recuento de series temporales desbocado.
- **La autoinstrumentación solo es útil si es uniforme.** El valor de la instrumentación sin código (agente Java, eBPF, autoinyección del OTel Operator) colapsa si cada librería inventa sus propias claves. Las convenciones son lo que permite que un agente Java y un SDK Go produzcan un span que un backend renderiza de forma idéntica.
- **Gobernanza a escala.** Un registro contra el cual podés hacer lint (ver Weaver, §4) convierte "por favor usá los nombres correctos" de una súplica de code review en un gate de CI.

### 1.3 Las cuatro superficies que cubren las convenciones

Las convenciones semánticas se aplican a cuatro planos distintos. Confundirlos es una trampa habitual del examen.

| Plano | Qué describe | Se transporta en | Ejemplos canónicos |
|---|---|---|---|
| **Resource** | La *entidad* que produce telemetría (inmutable durante la vida del proceso) | `Resource` (adjuntado una vez por SDK/exporter) | `service.name`, `service.version`, `service.instance.id`, `k8s.pod.name`, `cloud.region`, `host.arch` |
| **Trace / Span** | Una única operación | Atributos del span + nombre del span + kind del span | `http.request.method`, `db.query.text`, `messaging.system` |
| **Metric** | Una medición a lo largo del tiempo | Nombre del instrumento + unidad + atributos | `http.server.request.duration` (unidad `s`), dimensión `http.route` |
| **Log** | Un registro de log | Atributos/campos del LogRecord | `exception.type`, `code.function.name`, `log.file.path` |

Un `Resource` se *adjunta a* spans, metrics y logs — no es una señal en sí mismo. Por eso `service.name` se fija una sola vez y aparece en cada señal que un proceso emite.

---

## 2. Las reglas del registro (y comparaciones de trade-offs técnicos)

### 2.1 Reglas de nomenclatura de atributos

La especificación es precisa, y el examen la evalúa:

- **Los namespaces se separan por puntos**, formando una jerarquía: `http.request.method`, `db.collection.name`. El prefijo con puntos es el namespace; el último segmento es la hoja.
- **Los segmentos usan `snake_case`** (minúsculas, `_` entre palabras *dentro* de un segmento): `service.instance.id`, `http.request.method_original`.
- **Solo minúsculas.** Nada de camelCase, nada de PascalCase.
- **Nunca reutilizar un nombre entre tipos incompatibles.** Un nombre queda ligado a exactamente un tipo para siempre.
- **`.` es un separador de namespace, nunca parte del nombre de una hoja.** Los exporters de Prometheus reemplazan `.` por `_` al exportar (`http_server_request_duration_seconds`); esa es una transformación en el momento de exportar, no el nombre de origen.
- **Las enumeraciones** (como `http.request.method`) tienen un conjunto fijo de miembros pero usualmente `allow_custom_values: true`, de modo que un método desconocido (`QUERY`) se pasa tal cual en `http.request.method_original` mientras `http.request.method` se fija en `_OTHER`.

### 2.2 Niveles de requerimiento

Cada atributo del registro lleva un **nivel de requerimiento**. Este es un campo normativo, no una sugerencia.

| Nivel | Significado para un autor de instrumentación | Significado para un backend/consumidor |
|---|---|---|
| **Required** | DEBE emitirse, siempre. La ausencia es una violación de la especificación. | Seguro asumir que está presente. |
| **Conditionally Required** | DEBE emitirse *cuando se cumple la condición indicada* (p. ej. `http.route` cuando existe una ruta; `error.type` cuando la solicitud falló). | Presente si y solo si la condición se cumplió; la ausencia es significativa. |
| **Recommended** | DEBERÍA emitirse a menos que haya una razón para no hacerlo (costo, privacidad). | Puede estar ausente incluso en una implementación correcta. |
| **Opt-In** | Se emite *solo* cuando el operador lo activa explícitamente (usualmente de alto costo o sensible, p. ej. `db.query.text` completo con parámetros). | Presente solo bajo configuración explícita. |

**Consecuencia de diseño:** las dimensiones de métricas deben construirse a partir de atributos `Required`/`Conditionally Required`, de *baja cardinalidad* únicamente. `url.path` es `Recommended` en un span pero **nunca** debe convertirse en una dimensión de métrica — es cardinalidad no acotada.

### 2.3 Niveles de estabilidad

Las convenciones en sí mismas atraviesan un ciclo de vida. Esto gobierna si podés construir dashboards duraderos sobre ellas.

| Estabilidad | Garantía | Postura operativa |
|---|---|---|
| **Stable** | Compatibilidad hacia atrás garantizada; no será renombrado ni cambiado de tipo. | Seguro para hard-codear en dashboards, alertas, SLOs. |
| **Development** (antes *Experimental*) | Puede cambiar o ser renombrado en cualquier release. | Usar detrás de un feature flag; esperar cambios; fijar un schema URL. |
| **Deprecated** | Reemplazado; se mantiene solo para migración, será eliminado. | Migrar fuera; usar dual-emit durante la transición. |

El evento del mundo real más conocido: las **convenciones semánticas de HTTP se estabilizaron en semconv v1.23.0** (2023), lo cual *renombró* casi todos los atributos HTTP. `http.method` → `http.request.method`, `http.status_code` → `http.response.status_code`, `http.url` → `url.full`, y toda la familia `net.*` colapsó en `network.*`, `server.*`, `client.*`, `url.*`. Esta ruptura es el caso de estudio canónico para la mecánica de migración de la §3.

### 2.4 Convenciones HTTP: viejas (deprecated) vs nuevas (stable)

Vale la pena memorizar esta tabla; el renombrado es un tema favorito del examen.

| Concepto | Viejo (deprecated, ≤ 1.20) | Nuevo (stable, ≥ 1.23) |
|---|---|---|
| Método de la solicitud | `http.method` | `http.request.method` |
| Estado de la respuesta | `http.status_code` | `http.response.status_code` |
| URL completa | `http.url` | `url.full` |
| Ruta | `http.target` (path+query) | `url.path` + `url.query` |
| Esquema | `http.scheme` | `url.scheme` |
| Ruta (baja cardinalidad) | `http.route` | `http.route` *(sin cambios)* |
| Versión de protocolo | `http.flavor` | `network.protocol.version` |
| User agent | `http.user_agent` | `user_agent.original` |
| Host/puerto del servidor | `net.host.name` / `net.host.port` | `server.address` / `server.port` |
| Peer del cliente | `net.peer.name` / `net.peer.port` | `client.address` / `network.peer.address` |
| Métrica del servidor | `http.server.duration` (unidad `ms`) | `http.server.request.duration` (unidad `s`, histograma) |

Notá que la **métrica cambió tanto su nombre como su unidad** (`ms` → `s`) *y* la expectativa de su tipo (histograma de buckets explícitos con un conjunto de límites de buckets recomendado). Una migración que solo renombra atributos pero olvida el cambio de unidad de la métrica producirá silenciosamente dashboards desviados por un factor de 1000×.

### 2.5 Trade-offs de la estrategia de migración

Cuando las convenciones se rompen (HTTP, y más tarde DB y messaging), tenés tres opciones arquitectónicas para la transición. Elegir correctamente es una decisión de SRE.

| Estrategia | Dónde corre | Pros | Contras | Usar cuando |
|---|---|---|---|---|
| **SDK dual-emit** (`OTEL_SEMCONV_STABILITY_OPT_IN=http/dup`) | In-process, en la instrumentación | Se emiten tanto los viejos como los nuevos; el backend puede migrar los dashboards a su propio ritmo; sin pérdida de datos | ~2× el volumen de atributos en los spans afectados; solo para los dominios que el SDK soporta; requiere redespliegue de la app | Controlás los despliegues de la app y querés un corte limpio y escalonado |
| **`transform` del Collector (OTTL)** | Central, en el pipeline del Collector | Sin redespliegue de la app; una política para toda la flota; puede agregar/renombrar/descartar claves | Debés mantener las reglas OTTL; corre en cada span (CPU); fácil olvidar una clave | No podés redesplegar cada servicio, o tenés productores políglotas/legacy |
| **Procesador `schema` del Collector** | Central, dirigido por archivos de telemetry-schema | Declarativo, traducción versión-a-versión definida por los propios archivos de schema del proyecto OTel | Solo cubre las transformaciones expresadas en el schema publicado; menos flexible que OTTL | Querés traducción sancionada por la especificación y fijada por versión sin escribir reglas a mano |

El patrón maduro es **híbrido**: activar `http/dup` en los servicios recién desplegados, y correr una etapa `transform` (o `schema`) del Collector para normalizar la cola larga de productores legacy a los nombres nuevos — de modo que el backend solo vea un vocabulario.

---

## 3. Manifiestos completos e infraestructura

### 3.1 Fijar el Resource (contrato de variables de entorno)

El Resource es donde viven `service.name` y compañía. La especificación define variables de entorno que el SDK lee al arrancar — esta es la forma portable y agnóstica del lenguaje de fijarlo.

```bash
# service.name is REQUIRED. If unset, SDKs fall back to "unknown_service" (+ process name),
# which is a fleet-wide anti-pattern — everything collapses into one bucket.
export OTEL_SERVICE_NAME="checkout"

# Additional Resource attributes as a W3C Baggage-style comma list.
# OTEL_SERVICE_NAME wins over any service.name here if both are set.
export OTEL_RESOURCE_ATTRIBUTES="service.namespace=shop,service.version=1.4.2,deployment.environment.name=prod"

# Standard exporter wiring (OTLP/gRPC to a local Collector).
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.observability.svc:4317"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
```

`service.instance.id` debería ser **único por instancia en ejecución** (es lo que desambigua dos pods del mismo Deployment). En Kubernetes, derivalo del pod UID en lugar del hostname.

### 3.2 Kubernetes: inyectar atributos del Resource de la forma correcta

El patrón de abajo alimenta la identidad del pod hacia el SDK vía la Downward API. Esta es la forma correcta en producción de poblar `service.instance.id`, `k8s.pod.name`, etc., sin depender de detección de mejor esfuerzo.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 3
  selector:
    matchLabels: { app: checkout }
  template:
    metadata:
      labels:
        app: checkout
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "1.4.2"
    spec:
      containers:
        - name: checkout
          image: registry.example.com/shop/checkout:1.4.2
          env:
            - name: OTEL_SERVICE_NAME
              value: "checkout"
            # Pod UID is the stable, unique per-instance identifier.
            - name: K8S_POD_UID
              valueFrom:
                fieldRef: { fieldPath: metadata.uid }
            - name: K8S_POD_NAME
              valueFrom:
                fieldRef: { fieldPath: metadata.name }
            - name: K8S_NAMESPACE
              valueFrom:
                fieldRef: { fieldPath: metadata.namespace }
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
            # Compose the Resource. service.instance.id MUST be unique per instance.
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: >-
                service.namespace=shop,
                service.version=1.4.2,
                deployment.environment.name=prod,
                service.instance.id=$(K8S_POD_UID),
                k8s.namespace.name=$(K8S_NAMESPACE),
                k8s.pod.name=$(K8S_POD_NAME),
                k8s.node.name=$(K8S_NODE_NAME)
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://$(K8S_NODE_NAME):4317"   # DaemonSet Collector on the node
```

> **Gotcha:** los valores de atributo inyectados vía `OTEL_RESOURCE_ATTRIBUTES` solo se expanden porque referencian *otras* variables de entorno declaradas antes en la misma lista; Kubernetes realiza la sustitución `$(VAR)` de izquierda a derecha, así que `K8S_POD_UID` debe declararse **antes** de la línea que lo usa.

### 3.3 Collector: detección de recursos (rellenar lo que la app no puede saber)

La app conoce `service.*`; no conoce de forma confiable la nube/host en la que corre. El procesador `resourcedetection` enriquece el Resource con `cloud.*`, `host.*`, `k8s.*` a partir de los endpoints de metadatos de la plataforma.

```yaml
processors:
  resourcedetection:
    detectors: [env, system, ec2, eks]
    timeout: 2s
    override: false          # do NOT clobber attributes the SDK already set
    system:
      resource_attributes:
        host.name:   { enabled: true }
        host.id:     { enabled: true }
        os.type:     { enabled: true }
    ec2:
      resource_attributes:
        cloud.region:            { enabled: true }
        cloud.availability_zone: { enabled: true }
        host.type:               { enabled: true }

  # k8sattributes decorates telemetry with pod/namespace metadata by matching source IP.
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.deployment.name
        - k8s.node.name
      labels:
        - tag_name: service.version
          key: app.kubernetes.io/version
          from: pod
```

`override: false` es la configuración que sostiene todo: el `service.name` del SDK debe ganar siempre por sobre la conjetura de un detector.

### 3.4 Collector: migración de semconv HTTP con `transform` OTTL

Esto normaliza los productores legacy (nombres viejos `http.*`/`net.*`) al vocabulario stable de v1.23+ para que el backend vea un solo dialecto. Es la implementación concreta de la fila "transform del Collector" de la §2.5.

```yaml
processors:
  transform/http_semconv_migration:
    error_mode: ignore          # a missing key must not drop the span
    trace_statements:
      - context: span
        statements:
          # Rename request method.
          - set(attributes["http.request.method"], attributes["http.method"]) where attributes["http.method"] != nil
          # Rename response status (already an Int, no cast needed).
          - set(attributes["http.response.status_code"], attributes["http.status_code"]) where attributes["http.status_code"] != nil
          # Full URL and scheme.
          - set(attributes["url.full"], attributes["http.url"]) where attributes["http.url"] != nil
          - set(attributes["url.scheme"], attributes["http.scheme"]) where attributes["http.scheme"] != nil
          # Protocol version and user agent.
          - set(attributes["network.protocol.version"], attributes["http.flavor"]) where attributes["http.flavor"] != nil
          - set(attributes["user_agent.original"], attributes["http.user_agent"]) where attributes["http.user_agent"] != nil
          # net.* -> server.* / network.*
          - set(attributes["server.address"], attributes["net.host.name"]) where attributes["net.host.name"] != nil
          - set(attributes["server.port"], attributes["net.host.port"]) where attributes["net.host.port"] != nil
          # Drop the deprecated keys once copied, to avoid double storage.
          - delete_key(attributes, "http.method")
          - delete_key(attributes, "http.status_code")
          - delete_key(attributes, "http.url")
          - delete_key(attributes, "http.scheme")
          - delete_key(attributes, "http.flavor")
          - delete_key(attributes, "http.user_agent")
          - delete_key(attributes, "net.host.name")
          - delete_key(attributes, "net.host.port")

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [k8sattributes, resourcedetection, transform/http_semconv_migration, batch]
      exporters: [otlp/tempo]
```

### 3.5 Collector: la alternativa dirigida por la especificación — el procesador `schema`

En lugar de escribir OTTL a mano, el procesador `schema` usa los archivos de **telemetry schema** de OpenTelemetry (los mismos schemas `1.x.y` publicados en `opentelemetry.io/schemas/…`) para traducir señales a una versión objetivo. Lee el `schema_url` de los datos entrantes y aplica las transformaciones registradas.

```yaml
processors:
  schema:
    # Translate everything to these target schema versions.
    targets:
      - https://opentelemetry.io/schemas/1.27.0

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [schema, batch]
      exporters: [otlp/tempo]
```

Esto es declarativo y fijado por versión: el conjunto de transformaciones es lo que el proyecto OTel registró en el archivo de schema entre la versión del productor y `1.27.0`. No puede expresar reglas arbitrarias como lo hace OTTL, pero nunca se desvía del historial oficial de renombrados.

### 3.6 Un archivo de *modelo* de convención semántica (la fuente de verdad del registro)

Las convenciones están definidas ellas mismas como YAML en `open-telemetry/semantic-conventions`. Los equipos de plataforma extienden el registro con su **propio** namespace de compañía (p. ej. `com.shop.*`) usando el mismo schema, y luego generan/hacen lint contra él con Weaver (§4). Un grupo personalizado mínimo:

```yaml
groups:
  - id: registry.shop.checkout
    type: attribute_group
    display_name: Shop Checkout Attributes
    brief: >
      Company-specific attributes for the checkout domain. All names are
      namespaced under `shop.` to avoid collision with upstream conventions.
    attributes:
      - id: shop.cart.id
        type: string
        stability: stable
        requirement_level: required
        brief: Opaque identifier of the shopping cart.
        examples: ["cart_9f8b3c"]
      - id: shop.payment.provider
        type:
          allow_custom_values: true
          members:
            - id: stripe
              value: "stripe"
              stability: stable
            - id: adyen
              value: "adyen"
              stability: stable
        stability: stable
        requirement_level:
          conditionally_required: "when a payment was attempted"
        brief: The payment gateway used for this transaction.
      - id: shop.cart.total_minor
        type: int
        stability: development
        requirement_level: recommended
        brief: Cart total in the minor currency unit (cents).
        note: Pair with `shop.currency` for interpretation.
```

Los campos `stability`, `requirement_level` y los `members` tipados aquí son exactamente los campos legibles por máquina que describieron las §2.2/§2.3 — este archivo es lo que convierte la gobernanza en un chequeo de CI.

---

## 4. CLI y salida real de terminal

### 4.1 Validar el registro con OpenTelemetry Weaver

`weaver` es la herramienta oficial para resolver, chequear, generar a partir de, y hacer live-check de registros de convenciones semánticas. Es cómo se hacen cumplir las convenciones en CI.

**Hacer lint de un registro (chequeos estructurales + de política):**

```console
$ weaver registry check -r model/
✔ Loaded 1 registry (model/) — 214 groups, 1180 attributes
✔ Semantic Convention Registry resolution
✔ Attribute name format (snake_case, dotted namespaces)
✔ No duplicate attribute ids
✔ Every attribute declares `stability`
✖ Policy violation: attribute `shop.cartId` is not snake_case (did you mean `shop.cart_id`?)
✖ Policy violation: group `registry.shop.checkout` attribute `shop.payment.provider`
    has requirement_level `conditionally_required` but no condition text
2 error(s), 0 warning(s)
exit status 1
```

**Resolver el registro a un único documento aplanado y desreferenciado** (lo que consumen las herramientas y la generación de código):

```console
$ weaver registry resolve -r model/ --format json -o resolved.json
✔ Resolved registry written to resolved.json (1180 attributes, 96 metrics, 41 spans)
```

**Hacer live-check de telemetría real contra el registro** (¿el sistema en ejecución realmente emite datos conformes?):

```console
$ weaver registry live-check -r model/ --input otlp://0.0.0.0:4317
Listening for OTLP on 0.0.0.0:4317 …
── span "GET /products/:id" (scope: otelhttp 0.54.0) ──────────────
  ✔ http.request.method = "GET"           [stable, required]  OK
  ✔ http.route          = "/products/:id" [stable, cond-req]  OK
  ✔ http.response.status_code = 200        [stable, cond-req] OK
  ⚠ http.method         = "GET"           DEPRECATED → use http.request.method
  ✖ url.full            MISSING           [recommended]  (advisory)
  ✖ cart.id             = "cart_9f8b3c"   UNKNOWN attribute — not in registry
Summary: 3 conforming, 1 deprecated, 1 unknown, 1 advisory
```

`weaver registry live-check` es el bucle de retroalimentación de producción: te dice *empíricamente* si la instrumentación coincide con el contrato, atrapando el `http.method` deprecated que un servicio todavía está emitiendo.

### 4.2 Ver las convenciones en el cable vía el exporter `debug` del Collector

La forma más rápida de inspeccionar los atributos emitidos es un Collector con el exporter `debug` en verbosidad `detailed`.

```yaml
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
```

```console
$ otelcol-contrib --config debug.yaml
2026-08-10T14:22:01.334Z  info  service@v0.121.0  Everything is ready. Begin running and processing data.
2026-08-10T14:22:07.902Z  info  Traces  {"resource spans": 1, "spans": 1}
2026-08-10T14:22:07.902Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> service.namespace: Str(shop)
     -> service.version: Str(1.4.2)
     -> service.instance.id: Str(2f1c9a44-...-pod-uid)
     -> deployment.environment.name: Str(prod)
     -> k8s.pod.name: Str(checkout-7d9f-abc12)
     -> telemetry.sdk.name: Str(opentelemetry)
     -> telemetry.sdk.language: Str(go)
     -> telemetry.sdk.version: Str(1.34.0)
ScopeSpans #0
ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.27.0
InstrumentationScope go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp 0.54.0
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      : 00f067aa0ba902b7
    ID             : 00f067aa0ba90200
    Name           : GET /products/:id
    Kind           : Server
    Start time     : 2026-08-10 14:22:07.81 +0000 UTC
    Status code    : Unset
    Attributes:
         -> http.request.method: Str(GET)
         -> url.path: Str(/products/42)
         -> url.scheme: Str(https)
         -> url.query: Str(ref=home)
         -> server.address: Str(checkout.shop.svc)
         -> server.port: Int(443)
         -> http.route: Str(/products/:id)
         -> http.response.status_code: Int(200)
         -> network.protocol.version: Str(1.1)
         -> user_agent.original: Str(curl/8.6.0)
```

Leé esta salida como una checklist: `Name` es el nombre de span de baja cardinalidad `{method} {http.route}` (`GET /products/:id`, **no** `/products/42`); `Kind: Server`; el `ScopeSpans SchemaURL` fija la versión de semconv; y todo atributo usa los nombres stable de v1.23+. La **ausencia** de cualquier clave `http.method`/`http.url`/`net.*` confirma que el productor está en convenciones nuevas.

### 4.3 Confirmar la convención de nombre/unidad de la métrica

```console
$ curl -s http://checkout:9464/metrics | grep http_server_request_duration
# HELP http_server_request_duration_seconds Duration of inbound HTTP requests.
# TYPE http_server_request_duration_seconds histogram
http_server_request_duration_seconds_bucket{http_request_method="GET",http_route="/products/:id",http_response_status_code="200",le="0.005"} 812
http_server_request_duration_seconds_bucket{http_request_method="GET",http_route="/products/:id",http_response_status_code="200",le="0.01"}  1190
http_server_request_duration_seconds_sum{http_request_method="GET",http_route="/products/:id",http_response_status_code="200"} 6.42
http_server_request_duration_seconds_count{http_request_method="GET",http_route="/products/:id",http_response_status_code="200"} 2043
```

Aquí se ven dos hechos de convención:
- El nombre OTel `http.server.request.duration` (unidad `s`) exporta a Prometheus como `http_server_request_duration_seconds` — puntos → underscores, sufijo de unidad agregado.
- Las dimensiones son `http_route` (acotada), **no** `url_path`. Esa es la regla de baja cardinalidad (§2.2) que la convención hace cumplir.

### 4.4 El opt-in de migración en acción

```console
# Legacy default: old attribute names only.
$ OTEL_SEMCONV_STABILITY_OPT_IN= ./checkout
   -> http.method: Str(GET)
   -> http.status_code: Int(200)

# Dual emit: both old AND new, for a staged backend cutover.
$ OTEL_SEMCONV_STABILITY_OPT_IN=http/dup ./checkout
   -> http.method: Str(GET)
   -> http.request.method: Str(GET)
   -> http.status_code: Int(200)
   -> http.response.status_code: Int(200)

# New only: stable v1.23+ names, old names gone.
$ OTEL_SEMCONV_STABILITY_OPT_IN=http ./checkout
   -> http.request.method: Str(GET)
   -> http.response.status_code: Int(200)
```

Los dominios tienen tokens independientes (`http`, `http/dup`; `database`, `database/dup`) y la variable acepta una lista separada por comas: `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup,database/dup`.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Una escalera de verificación (el chequeo más barato primero)

| Pregunta | Cómo responderla | Costo |
|---|---|---|
| ¿Los nombres de atributos siguen las reglas de formato? | `weaver registry check -r model/` | gratis, CI |
| ¿El sistema en ejecución emite datos conformes? | `weaver registry live-check --input otlp://…` | un collector, en vivo |
| ¿Qué hay realmente en el cable *ahora mismo*? | Exporter `debug` del Collector, `verbosity: detailed` | gratis, en vivo |
| ¿`service.name` está fijado en toda la flota (no `unknown_service`)? | Consultar al backend por `service.name="unknown_service*"` | gratis |
| ¿Una dimensión de métrica es de alta cardinalidad? | Contar series por métrica en Prometheus/backend | gratis |
| ¿En qué versión de semconv está un productor? | Inspeccionar el `ScopeSpans SchemaURL` en la salida de debug | gratis |

### 5.2 Catálogo de fallas

**Síntoma: todo aparece como `unknown_service` (o `unknown_service:java`).**
`service.name` nunca se fijó. Se activó el valor por defecto del SDK. Solución: fijar `OTEL_SERVICE_NAME` (o `service.name` vía `OTEL_RESOURCE_ATTRIBUTES`). Diagnóstico:

```console
$ curl -s $BACKEND/api/services | jq -r '.[].name' | grep unknown
unknown_service:java
```

**Síntoma: dos pods del mismo Deployment colapsan en una sola instancia en el backend.**
`service.instance.id` falta o es idéntico (p. ej. hard-codeado, o todos los pods comparten un hostname detrás de un headless service). Solución: derivarlo del pod UID (§3.2). Es lo que desambigua las réplicas.

**Síntoma: la cardinalidad de las métricas explota / el backend de métricas se queda sin memoria (OOM).**
Un atributo de alta cardinalidad se filtró en una dimensión de métrica — casi siempre `url.path`/`url.full` (ruta cruda con IDs) usado donde corresponde `http.route` (parametrizado). Diagnosticá el recuento de series ofensivo:

```console
$ curl -s 'http://prometheus:9090/api/v1/query?query=count(count%20by(url_path)(http_server_request_duration_seconds_count))'
{"status":"success","data":{"result":[{"value":[1.7e9,"48213"]}]}}
```

48 213 valores distintos de `url_path` son la prueba irrefutable. Solución: quitar `url.path` de la vista de la métrica (nunca debió ser una dimensión); asegurarse de que el router fijó `http.route`. En el Collector, un `transform` en el pipeline de métricas puede eliminarlo:
`delete_key(attributes, "url.path")`.

**Síntoma: los traces entre servicios se rompen en el límite HTTP; el padre y el hijo discrepan sobre la operación.**
El productor y el consumidor están en versiones distintas de semconv (uno emite `http.method`, el otro `http.request.method`), así que las consultas del backend que filtran por un nombre pierden la mitad de los spans. Diagnosticá chequeando el `ScopeSpans SchemaURL` de cada lado. Solución: normalizá con `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` durante la transición, más una etapa `transform`/`schema` del Collector (§3.4/§3.5) para que el backend solo vea un dialecto.

**Síntoma: los dashboards de latencia HTTP marcan 1000× de más (o de menos) después de una actualización.**
La métrica se movió de `http.server.duration` (unidad `ms`) a `http.server.request.duration` (unidad `s`) y un panel todavía asume milisegundos. Esta es la trampa del cambio de unidad de la §2.4. Solución: actualizá la consulta a la métrica basada en segundos y dividí/escalá los paneles en consecuencia; verificá con la razón `_sum/_count` contra una solicitud conocida.

**Síntoma: `weaver registry check` pasa pero la telemetría real todavía tiene nombres malos.**
`check` valida el *modelo*, no los *datos emitidos*. Un modelo limpio no prueba que la instrumentación lo obedezca. Usá `weaver registry live-check` (§4.1) o el exporter `debug` para verificar lo que realmente se produce. Este es el análogo directo de "la citación resuelve ≠ la citación dice lo que se afirma": *la convención existe* y *el código la emite* son peldaños distintos.

**Síntoma: datos sensibles (parámetros de consulta, SQL completo con valores) aparecen en los spans.**
Un atributo `Opt-In` (p. ej. `db.query.text` completo con valores de parámetros, o `url.query` conteniendo tokens) se emitió donde debería requerir activación explícita. Solución: confirmá que el nivel de requerimiento del atributo es `Opt-In` y que solo se habilita deliberadamente; de lo contrario, depuralo con un procesador `transform`/`redaction` del Collector.

### 5.3 Señales de oro de una flota conforme

Una plataforma de producción es "conforme" cuando se cumplen todos los siguientes, y cada uno es verificable por máquina:

1. Cero servicios reportan un `service.name` que empiece con `unknown_service`.
2. Toda dimensión de métrica se extrae de un atributo `Required`/`Conditionally Required`, de baja cardinalidad; `weaver registry live-check` reporta **0 unknown** atributos en las métricas.
3. Cada `ScopeSpans`/`ScopeMetrics` lleva un `SchemaURL`, y la flota está dentro de una versión menor de semconv de un único objetivo.
4. No aparecen atributos `Deprecated` en la salida de live-check (o están presentes a sabiendas solo durante una ventana de dual-emit con una fecha de fin).
5. Todos los atributos personalizados de la compañía viven bajo un namespace reservado (p. ej. `shop.*` / `com.shop.*`) y pasan `weaver registry check` en CI.

---

## 6. Referencias

- OpenTelemetry Semantic Conventions (hogar de la especificación): https://opentelemetry.io/docs/specs/semconv/
- Reglas generales de nomenclatura de atributos: https://opentelemetry.io/docs/specs/semconv/general/naming/
- Niveles de requerimiento de atributos: https://opentelemetry.io/docs/specs/semconv/general/attribute-requirement-level/
- Convenciones semánticas de Resource (`service.*`, `telemetry.sdk.*`): https://opentelemetry.io/docs/specs/semconv/resource/
- Convenciones semánticas de HTTP (spans y metrics): https://opentelemetry.io/docs/specs/semconv/http/
- Convenciones semánticas de bases de datos: https://opentelemetry.io/docs/specs/semconv/database/
- Convenciones semánticas generales de metrics y nomenclatura: https://opentelemetry.io/docs/specs/semconv/general/metrics/
- Estabilidad y migración (`OTEL_SEMCONV_STABILITY_OPT_IN`): https://opentelemetry.io/docs/specs/semconv/non-normative/http-migration/
- Variables de entorno del SDK (`OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`): https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- Telemetry Schemas (schema URLs, transformaciones de versión): https://opentelemetry.io/docs/specs/otel/schemas/
- Registro fuente `semantic-conventions` (modelo YAML): https://github.com/open-telemetry/semantic-conventions
- OpenTelemetry Weaver (registry check / resolve / generate / live-check): https://github.com/open-telemetry/weaver
- Procesador `resourcedetection` del Collector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourcedetectionprocessor
- Procesador `k8sattributes` del Collector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- Procesador `transform` del Collector y OTTL: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor
- Procesador `schema` del Collector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/schemaprocessor
- UCUM (códigos de unidad usados por las convenciones de metrics): https://ucum.org/
- Certificación OTCA y currículum: https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/ · https://github.com/cncf/curriculum