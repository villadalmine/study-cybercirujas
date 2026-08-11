# OTCA 2.5 — SDK Pipelines

> **Ruta de la señal en una sola frase:** la **API** de OpenTelemetry produce telemetría, el **pipeline del SDK** decide *si conservarla, cómo darle forma, cómo agruparla en lotes y a dónde enviarla*, y el **exporter** la entrega a un backend o al Collector. El tema 2.5 trata sobre todo lo que ocurre entre el instrumento y el cable.

---

## 1. Motivación: el problema de producción que resuelve el pipeline del SDK

La **API** de OTel es deliberadamente tonta. Cuando llamás a `tracer.Start(ctx, "GET /checkout")` o `counter.Add(ctx, 1)`, la API registra una intención. *No* tiene ninguna opinión sobre sampling, batching, reintentos, backpressure, cardinalidad ni transporte. Si la API hiciera todo eso, cada binding de lenguaje lo reimplementaría, y no podrías inyectar una implementación no-op dentro de una biblioteca sin arrastrar detrás una pila de red.

El **SDK** es donde viven esas opiniones, y en producción son decisiones que soportan carga:

- **Throughput vs. pérdida.** Un servicio ocupado emite decenas de miles de spans/seg. Exportar cada uno de forma síncrona al finalizar el span (`SimpleSpanProcessor`) bloquea la ruta de la petición con la latencia de red y colapsa bajo carga. Necesitás un pipeline acotado, asíncrono y por lotes — y una cola acotada *va* a descartar datos cuando el exporter se atasca. El pipeline es donde elegís *cómo* se degrada.
- **Costo vs. fidelidad.** El head sampling al 100% es inasequible a escala e inútil sin él. El **Sampler** se ubica al frente del pipeline de traces y su decisión debe propagarse a los hijos vía `traceparent`, o terminás con traces rotos donde un padre está sampleado y los hijos no.
- **Cardinalidad vs. resolución.** En métricas, un `Histogram` indexado por `http.route` está bien; indexado por `user.id` es una bomba de memoria y una factura de tu TSDB. Las **Views** y el filtrado de atributos en el pipeline de métricas son la única barrera de protección in-process.
- **Memoria vs. semántica.** La **temporality** delta vs. acumulativa no es una preferencia — Prometheus quiere acumulativa, muchos sistemas de push quieren delta, y elegir mal significa o bien rates incorrectos o bien memoria del SDK sin límite.
- **Reproducibilidad.** Todo lo anterior debe ser configurable desde **variables de entorno o configuración declarativa**, para que la misma imagen se comporte distinto en dev, staging y prod sin recompilar.

El pipeline tiene la misma forma para las tres señales — **Provider → (Sampler para traces / View para métricas) → Processor/Reader → Exporter → OTLP con el Resource estampado** — pero las piezas móviles difieren por señal. Dominá la forma una vez; especializate tres veces.

```
                          ┌──────────────── Resource (service.name, k8s.*, host.*) ─── stamped on all ──┐
                          │                                                                              │
  API (Tracer)  ──span──▶ TracerProvider ─▶ Sampler ─▶ SpanProcessor(s) ─▶ SpanExporter ─▶ OTLP ─▶ Collector/Backend
  API (Meter)   ──meas──▶ MeterProvider  ─▶ View ────▶ MetricReader ─────▶ MetricExporter ─▶ OTLP ─┘
  API (Logger)  ──rec───▶ LoggerProvider ─────────────▶ LogRecordProcessor ▶ LogRecordExporter ▶ OTLP
```

---

## 2. Anatomía de cada pipeline

### 2.1 Componentes del pipeline de traces

| Etapa | Contrato | Notas para producción |
|---|---|---|
| **TracerProvider** | Contiene Resource, Sampler, SpanProcessors, SpanLimits, IdGenerator. Raíz del pipeline. | Uno por proceso. Debe hacerse **shut down** al salir para hacer flush. Se instala un provider no-op hasta que definís uno. |
| **Sampler** | `ShouldSample(ctx, traceID, name, kind, attrs, links) -> Decision` que devuelve `DROP`, `RECORD_ONLY` o `RECORD_AND_SAMPLE`. | Se invoca **una vez, al iniciar el span**, en la ruta de decisión de la *raíz*. `RECORD_ONLY` conserva el span in-process (visible para `IsRecording()`) pero fija `sampled=0` para que no se exporte. |
| **SpanProcessor** | Hooks `OnStart(span, parentCtx)` y `OnEnd(readableSpan)`. También `ForceFlush()` y `Shutdown()`. | Varios processors se ejecutan en orden de registro. `OnEnd` solo se dispara para spans que son `RECORD_AND_SAMPLE` o `RECORD_ONLY`. |
| **SpanExporter** | `Export(batch) -> SUCCESS|FAILURE`, más `Shutdown()`. | Sin estado respecto al pipeline; el processor es dueño del batching/retry. El exporter debe ser **seguro de llamar sin bloquear** desde un hilo en segundo plano. |
| **SpanLimits** | Limita cantidad/longitud de atributos, events, links. | Evita que un único span patológico haga OOM al exporter. |

### 2.2 Componentes del pipeline de métricas

| Etapa | Contrato | Notas para producción |
|---|---|---|
| **MeterProvider** | Contiene Resource, Views, MetricReaders. | Los instrumentos se crean vía `Meter`; el provider los conecta a los readers. |
| **View** | Selecciona instrumentos (por nombre/kind/meter) y reescribe: name, description, **aggregation**, **allow-list de atributos**, o los descarta. | El único lugar para corregir la cardinalidad y elegir histograma de bucket explícito vs. exponencial *sin tocar código*. |
| **Aggregation** | `Sum`, `LastValue`, `ExplicitBucketHistogram`, `ExponentialHistogram`, `Drop`, `Default`. | El default depende del instrumento (Counter→Sum, Gauge→LastValue, Histogram→ExplicitBucketHistogram). |
| **MetricReader** | Extrae puntos agregados del SDK. `PeriodicExportingMetricReader` (push, con un timer) o un pull reader (por ej., scrape de Prometheus). | Es dueño de la **temporality** y del intervalo. Cada reader tiene su propio estado de aggregation. |
| **MetricExporter** | `Export(resourceMetrics)`, declara la **temporality** y **aggregation** preferidas por tipo de instrumento. | El exporter OTLP usa acumulativa por default a menos que `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`. |

### 2.3 Componentes del pipeline de logs

El SDK de Logs es intencionalmente el más delgado. La premisa de diseño es que enrutás los frameworks de logging existentes (log4j, logback, `logging` de Python, zap/logrus) hacia el `LoggerProvider` de OTel vía un bridge/appender — rara vez llamás a la API de Logs directamente en el código de la aplicación.

| Etapa | Contrato |
|---|---|
| **LoggerProvider** | Contiene Resource y LogRecordProcessors. |
| **LogRecordProcessor** | `OnEmit(record, ctx)`, `ForceFlush`, `Shutdown`. Simple o Batch, misma semántica que los spans. |
| **LogRecordExporter** | `Export(batch)`, `Shutdown`. OTLP es el estándar. |

---

## 3. Tablas comparativas de trade-offs

### 3.1 SimpleSpanProcessor vs. BatchSpanProcessor

| Dimensión | SimpleSpanProcessor | BatchSpanProcessor (BSP) |
|---|---|---|
| Disparador de export | Síncrono en **cada** `OnEnd` | Por timer (`scheduleDelay`) **o** cuando el lote alcanza `maxExportBatchSize` |
| Modelo de hilos | Exporta en el hilo que finaliza (a menudo el hilo de la petición) | Un worker dedicado en segundo plano drena una cola acotada |
| Impacto en latencia | Suma el RTT del exporter a la ruta de la petición | ≈ cero en la ruta de la petición (solo encola) |
| Modo de pérdida de datos | Pierde datos solo si el export falla | **Descarta con la cola llena** (`maxQueueSize`) cuando el exporter no da abasto |
| Orden | Estricto | Por lotes, se preserva el orden dentro del lote |
| Memoria | Mínima | Hasta `maxQueueSize` spans en buffer |
| Cuándo usarlo | Tests, CLIs de vida corta, debugging con `ConsoleExporter` | **Todo en producción** |
| Variables de entorno que lo gobiernan | — | `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_EXPORT_TIMEOUT`, `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` |

**Defaults del BSP (spec):** `scheduleDelay=5000ms`, `exportTimeout=30000ms`, `maxQueueSize=2048`, `maxExportBatchSize=512`. Invariante a respetar: `maxExportBatchSize ≤ maxQueueSize`.

### 3.2 Samplers

| Sampler | Base de la decisión | ¿Consciente del padre? | Uso típico |
|---|---|---|---|
| `AlwaysOn` | Samplea todo | No | Dev; servicios de bajo volumen |
| `AlwaysOff` | Descarta todo | No | Kill switch |
| `TraceIdRatioBased(p)` | Hash determinista del traceID < p | No | Head sampling uniforme |
| **`ParentBased(root=…)`** | Respeta el flag `sampled` entrante; usa el sampler `root` solo cuando no hay padre | **Sí** | **Default de producción** — mantiene los traces enteros |
| Custom / composite | Basado en reglas (por nombre, atributo, rate limit) | Depende | Lógica de head tirando a tail; guiada por SLO |

> **Trampa:** usar un `TraceIdRatioBased` pelado (no envuelto en `ParentBased`) hace que cada servicio vuelva a tirar los dados, produciendo traces parciales. El head sampling pertenece a `ParentBased(root=TraceIdRatioBased(p))`; el verdadero **tail sampling** no es una funcionalidad del SDK — vive en el processor `tail_sampling` del Collector porque necesita el trace completo ensamblado primero.

### 3.3 Temporality de métricas

| Aspecto | Acumulativa | Delta |
|---|---|---|
| Valor del punto | Total acumulado desde el inicio del proceso | Cambio desde el último export |
| Memoria del SDK | Mantiene estado durante toda la vida de la serie | Puede reiniciar/olvidar la serie tras el export |
| Comportamiento en reinicio | El counter se reinicia → el consumidor debe detectar la caída | Se reinicia naturalmente en cada intervalo |
| Backend preferido | Prometheus, cualquier cosa que haga `rate()` | Estilo Statsd, algunos ingesters SaaS |
| Default de OTLP | **Acumulativa** | Opt-in vía `…_TEMPORALITY_PREFERENCE=delta` |
| Rotación de cardinalidad | Peor (debe retener todas las series) | Mejor (puede descartar series inactivas) |

### 3.4 Transporte OTLP

| | gRPC (`grpc`) | HTTP/protobuf (`http/protobuf`) | HTTP/JSON (`http/json`) |
|---|---|---|---|
| Puerto por default | 4317 | 4318 | 4318 |
| Framing | streams HTTP/2 | POST por lote | POST por lote |
| Compresión | gzip | gzip | gzip |
| Amigabilidad con proxy/L7 | Necesita un LB consciente de HTTP/2 | Funciona a través de cualquier proxy HTTP | Funciona, payloads más grandes |
| Valor de la env var | `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` | `=http/protobuf` | `=http/json` |
| Ruta específica por señal | — | `/v1/traces`, `/v1/metrics`, `/v1/logs` | igual |

---

## 4. Manifiestos y código completos — nada recortado

### 4.1 Go SDK — bootstrap completo del pipeline de tres señales

Este es el setup canónico, con forma de producción: exporters OTLP/gRPC, sampler de ratio `ParentBased`, `BatchSpanProcessor`, un `PeriodicExportingMetricReader` con una View que limita la cardinalidad, propagators W3C, y un shutdown limpio que hace flush.

```go
// otel.go — call setupOTel(ctx) from main, defer the returned shutdown.
package main

import (
	"context"
	"errors"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func setupOTel(ctx context.Context) (shutdown func(context.Context) error, err error) {
	var shutdownFuncs []func(context.Context) error
	shutdown = func(ctx context.Context) error {
		var e error
		for _, fn := range shutdownFuncs {
			e = errors.Join(e, fn(ctx))
		}
		shutdownFuncs = nil
		return e
	}

	// ---- Resource: identity stamped on every span/metric/log ----
	res, err := resource.New(ctx,
		resource.WithFromEnv(),   // absorbs OTEL_RESOURCE_ATTRIBUTES / OTEL_SERVICE_NAME
		resource.WithHost(),
		resource.WithAttributes(
			semconv.ServiceName("checkout"),
			semconv.ServiceVersion("2.4.1"),
			semconv.DeploymentEnvironment("prod"),
			attribute.String("service.namespace", "shop"),
		),
	)
	if err != nil {
		return nil, err
	}

	// ---- W3C context propagation (traceparent + baggage) ----
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// ================= TRACE pipeline =================
	traceExp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint("otel-collector.observability.svc:4317"),
		otlptracegrpc.WithInsecure(), // in-cluster; use TLS at the mesh edge
	)
	if err != nil {
		return nil, err
	}
	tp := trace.NewTracerProvider(
		trace.WithResource(res),
		trace.WithSampler(
			trace.ParentBased(trace.TraceIDRatioBased(0.10)), // 10% head sampling, parent wins
		),
		trace.WithBatcher(traceExp, // BatchSpanProcessor with explicit tuning
			trace.WithMaxQueueSize(4096),
			trace.WithMaxExportBatchSize(512),
			trace.WithBatchTimeout(3*time.Second),
			trace.WithExportTimeout(30*time.Second),
		),
		trace.WithRawSpanLimits(trace.SpanLimits{
			AttributeCountLimit: 128,
			EventCountLimit:     128,
			LinkCountLimit:      128,
		}),
	)
	otel.SetTracerProvider(tp)
	shutdownFuncs = append(shutdownFuncs, tp.Shutdown)

	// ================= METRIC pipeline =================
	metricExp, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithEndpoint("otel-collector.observability.svc:4317"),
		otlpmetricgrpc.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}

	// View: bound latency histogram cardinality by keeping only route + status.
	latencyView := metric.NewView(
		metric.Instrument{Name: "http.server.duration"},
		metric.Stream{
			Aggregation: metric.AggregationExplicitBucketHistogram{
				Boundaries: []float64{5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000},
			},
			AttributeFilter: attribute.NewAllowKeysFilter(
				"http.route", "http.response.status_code",
			),
		},
	)

	mp := metric.NewMeterProvider(
		metric.WithResource(res),
		metric.WithView(latencyView),
		metric.WithReader(metric.NewPeriodicReader(metricExp,
			metric.WithInterval(30*time.Second),
			metric.WithTimeout(15*time.Second),
		)),
	)
	otel.SetMeterProvider(mp)
	shutdownFuncs = append(shutdownFuncs, mp.Shutdown)

	return shutdown, nil
}
```

Conectándolo en `main`:

```go
func main() {
	ctx := context.Background()
	shutdown, err := setupOTel(ctx)
	if err != nil {
		log.Fatalf("otel init: %v", err)
	}
	// Critical: flush the BSP queue + last metric collection on the way out.
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := shutdown(ctx); err != nil {
			log.Printf("otel shutdown: %v", err)
		}
	}()
	runServer(ctx)
}
```

### 4.2 Python SDK — pipeline equivalente (traces + métricas)

```python
# otel_setup.py
from opentelemetry import trace, metrics
from opentelemetry.sdk.resources import Resource, SERVICE_NAME, SERVICE_VERSION
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import View, ExplicitBucketHistogramAggregation
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.baggage.propagation import W3CBaggagePropagator

ENDPOINT = "otel-collector.observability.svc:4317"

def setup_otel() -> None:
    resource = Resource.create({
        SERVICE_NAME: "checkout",
        SERVICE_VERSION: "2.4.1",
        "deployment.environment": "prod",
        "service.namespace": "shop",
    })

    set_global_textmap(CompositePropagator([
        TraceContextTextMapPropagator(),
        W3CBaggagePropagator(),
    ]))

    # ---- TRACES ----
    tp = TracerProvider(
        resource=resource,
        sampler=ParentBased(root=TraceIdRatioBased(0.10)),
    )
    tp.add_span_processor(BatchSpanProcessor(
        OTLPSpanExporter(endpoint=ENDPOINT, insecure=True),
        max_queue_size=4096,
        max_export_batch_size=512,
        schedule_delay_millis=3000,
        export_timeout_millis=30000,
    ))
    trace.set_tracer_provider(tp)

    # ---- METRICS ----
    latency_view = View(
        instrument_name="http.server.duration",
        aggregation=ExplicitBucketHistogramAggregation(
            boundaries=[5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]),
        attribute_keys={"http.route", "http.response.status_code"},
    )
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=ENDPOINT, insecure=True),
        export_interval_millis=30000,
        export_timeout_millis=15000,
    )
    metrics.set_meter_provider(MeterProvider(
        resource=resource, metric_readers=[reader], views=[latency_view],
    ))
```

### 4.3 Configuración declarativa por archivo (config-first, cero cambios de código)

Desde OTel v1.x el SDK incluye **configuración declarativa**: apuntá `OTEL_EXPERIMENTAL_CONFIG_FILE` a un archivo YAML y el SDK construye exactamente los mismos objetos del pipeline. Este es el camino amigable con GitOps — el pipeline vive en un ConfigMap, no en un binario compilado.

```yaml
# otel-sdk-config.yaml  — consumed via OTEL_EXPERIMENTAL_CONFIG_FILE
file_format: "0.4"

resource:
  attributes:
    - name: service.name
      value: checkout
    - name: service.version
      value: "2.4.1"
    - name: deployment.environment
      value: prod

propagator:
  composite: [tracecontext, baggage]

tracer_provider:
  sampler:
    parent_based:
      root:
        trace_id_ratio_based:
          ratio: 0.10
  span_limits:
    attribute_count_limit: 128
    event_count_limit: 128
    link_count_limit: 128
  processors:
    - batch:
        schedule_delay: 3000
        export_timeout: 30000
        max_queue_size: 4096
        max_export_batch_size: 512
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
            insecure: true

meter_provider:
  views:
    - selector:
        instrument_name: http.server.duration
      stream:
        aggregation:
          explicit_bucket_histogram:
            boundaries: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
        attribute_keys: [http.route, http.response.status_code]
  readers:
    - periodic:
        interval: 30000
        timeout: 15000
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
            temporality_preference: cumulative
            insecure: true

logger_provider:
  processors:
    - batch:
        exporter:
          otlp:
            protocol: grpc
            endpoint: http://otel-collector.observability.svc:4317
            insecure: true
```

### 4.4 Cableado en Kubernetes — configuración del mismo pipeline por variables de entorno

Para los SDKs donde *no* adoptaste la config declarativa, el pipeline se maneja enteramente por variables de entorno. Acá el conjunto completo como un overlay de Deployment, más el archivo de config montado para el camino declarativo.

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
      labels: { app: checkout }
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:2.4.1
          env:
            # --- identity ---
            - name: OTEL_SERVICE_NAME
              value: "checkout"
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.version=2.4.1,deployment.environment=prod,k8s.pod.name=$(POD_NAME),k8s.node.name=$(NODE_NAME)"
            # --- transport (shared) ---
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc:4317"
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: "grpc"
            # --- trace pipeline ---
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.10"
            - name: OTEL_BSP_SCHEDULE_DELAY
              value: "3000"
            - name: OTEL_BSP_MAX_QUEUE_SIZE
              value: "4096"
            - name: OTEL_BSP_MAX_EXPORT_BATCH_SIZE
              value: "512"
            - name: OTEL_BSP_EXPORT_TIMEOUT
              value: "30000"
            # --- metric pipeline ---
            - name: OTEL_METRIC_EXPORT_INTERVAL
              value: "30000"
            - name: OTEL_METRIC_EXPORT_TIMEOUT
              value: "15000"
            - name: OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE
              value: "cumulative"
            # --- propagation ---
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"
          # Declarative-config path (mutually exclusive with the vars above):
          # - name: OTEL_EXPERIMENTAL_CONFIG_FILE
          #   value: /etc/otel/otel-sdk-config.yaml
          volumeMounts:
            - name: otel-config
              mountPath: /etc/otel
              readOnly: true
      volumes:
        - name: otel-config
          configMap:
            name: otel-sdk-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-sdk-config
  namespace: shop
data:
  otel-sdk-config.yaml: |
    file_format: "0.4"
    resource:
      attributes:
        - { name: service.name, value: checkout }
    tracer_provider:
      processors:
        - batch:
            exporter:
              otlp: { protocol: grpc, endpoint: http://otel-collector.observability.svc:4317, insecure: true }
```

---

## 5. Comandos CLI y salida real de terminal

### 5.1 Inspeccionar el entorno efectivo (lo que el SDK realmente lee)

```console
$ env | grep -E '^OTEL_' | sort
OTEL_BSP_MAX_EXPORT_BATCH_SIZE=512
OTEL_BSP_MAX_QUEUE_SIZE=4096
OTEL_BSP_SCHEDULE_DELAY=3000
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_METRIC_EXPORT_INTERVAL=30000
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_RESOURCE_ATTRIBUTES=service.version=2.4.1,deployment.environment=prod
OTEL_SERVICE_NAME=checkout
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.10
```

### 5.2 Probar el pipeline de extremo a extremo con el console exporter (sin backend)

Cambiá el endpoint OTLP por stdout para ver exactamente qué emite el processor. En Python:

```console
$ export OTEL_TRACES_EXPORTER=console
$ export OTEL_TRACES_SAMPLER=always_on
$ opentelemetry-instrument python app.py
{
    "name": "GET /checkout",
    "context": {
        "trace_id": "0x7b5e3f9c2a1d4e8f0b6c9a2d5e8f1b3c",
        "span_id": "0x1a2b3c4d5e6f7a8b",
        "trace_state": "[]"
    },
    "kind": "SpanKind.SERVER",
    "parent_id": null,
    "start_time": "2026-08-10T12:04:33.129482Z",
    "end_time":   "2026-08-10T12:04:33.171904Z",
    "status": { "status_code": "OK" },
    "attributes": {
        "http.request.method": "GET",
        "http.route": "/checkout",
        "http.response.status_code": 200
    },
    "resource": {
        "attributes": {
            "service.name": "checkout",
            "service.version": "2.4.1",
            "deployment.environment": "prod"
        }
    }
}
```

Lo clave que esta salida *verifica*: el **Resource** está estampado (bloque inferior), el **Sampler** conservó el span (se imprimió), y el span lleva `trace_id` para la propagación. Fijar `OTEL_TRACES_SAMPLER=always_off` y volver a ejecutar no imprime **nada** — eso es la etapa del sampler haciendo su trabajo al frente del pipeline.

### 5.3 Confirmar que los bytes salen del proceso (capa de transporte)

```console
$ export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
$ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
$ curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST http://localhost:4318/v1/traces \
    -H "Content-Type: application/x-protobuf" --data-binary @/dev/null
200
```

Un `200` en un POST vacío prueba que el receptor OTLP/HTTP está levantado y que la ruta (`/v1/traces`) es correcta — aislando "el SDK no exporta" de "el collector no escucha".

### 5.4 Emitir un span sintético con `otel-cli` para probar el collector independiente de la app

```console
$ otel-cli span \
    --service checkout \
    --name "manual smoke" \
    --endpoint localhost:4317 \
    --protocol grpc \
    --verbose
# trace_id: 4f2c8b1e9d3a5c7f0e2b4d6a8c1f3e5b
# span_id:  9a1b2c3d4e5f6a7b
# sent OTLP span to localhost:4317 (grpc) in 8ms
```

### 5.5 Observar al collector confirmar la recepción (debug exporter del lado del Collector)

```console
$ kubectl -n observability logs deploy/otel-collector | tail -n 20
2026-08-10T12:05:02.744Z  info  TracesExporter  {"kind": "exporter",
  "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 1}
2026-08-10T12:05:02.744Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> service.version: Str(2.4.1)
     -> deployment.environment: Str(prod)
ScopeSpans #0
Span #0
    Trace ID       : 4f2c8b1e9d3a5c7f0e2b4d6a8c1f3e5b
    Name           : manual smoke
    Kind           : Internal
    Status code    : Unset
```

La coincidencia entre el trace_id de `otel-cli` (5.4) y el log del collector (5.5) es la prueba definitiva de extremo a extremo de que el pipeline está intacto.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Una escalera de diagnóstico por capas (aislar la etapa que falla)

| Síntoma | Etapa probable | Chequeo | Solución |
|---|---|---|---|
| No hay spans en ningún lado | Provider no instalado / no-op | El console exporter no imprime nada ni con `always_on` | Asegurate de que `SetTracerProvider`/la instrumentación corrieron antes del primer span |
| El console imprime, el collector vacío | Exporter/transporte | `curl /v1/traces` → distinto de 200, o error de handshake TLS | Corregí el endpoint, el protocolo (`grpc` vs `http/protobuf`), `insecure`, puerto 4317 vs 4318 |
| Faltan algunos servicios en un trace | Sampler | El hijo tiene `sampled=0` mientras el padre tiene `sampled=1` | Envolvé el ratio sampler en `ParentBased`; verificá `OTEL_PROPAGATORS=tracepcontext` |
| Los spans llegan pero con lag/ráfagas y luego se detienen | Overflow de la cola del BSP | El SDK auto-loguea "dropped spans"; cola llena | Subí `MAX_QUEUE_SIZE`, bajá `SCHEDULE_DELAY`, o escalá el collector |
| Se pierden datos al salir el pod | Sin shutdown/flush | El último lote falta en SIGTERM | Llamá a `provider.Shutdown()`/`ForceFlush()`; fijá `terminationGracePeriodSeconds` ≥ export timeout |
| Explosión de cardinalidad de métricas / OOM | Falta una View | Cantidad de series por instrumento enorme | Agregá una View con allow-list de `attribute_keys` o aggregation `Drop` |
| Los rates se ven mal en Prometheus | Desajuste de temporality | El exporter envía delta a un almacén cumulative | Fijá `…_TEMPORALITY_PREFERENCE=cumulative` |
| El histograma de latencia inutilizable | Límites de bucket | Todo cae en un solo bucket | Ajustá los boundaries del `ExplicitBucketHistogram` o cambiá a exponencial |

### 6.2 Activar los propios auto-diagnósticos del SDK

El pipeline reporta sus errores internos a través del manejador de errores del SDK — activalo antes de culpar a la red.

```console
$ export OTEL_LOG_LEVEL=debug          # supported by several SDKs / autoinstrumentation
$ export OTEL_TRACES_EXPORTER=otlp
$ ./checkout
2026-08-10T12:07:11Z DEBUG bsp: enqueued span (queue=1/4096)
2026-08-10T12:07:14Z DEBUG bsp: export batch size=1 timeout=30s
2026-08-10T12:07:14Z ERROR exporter: rpc error: code = Unavailable
    desc = connection error: desc = "transport: Error while dialing:
    dial tcp 10.96.4.12:4317: connect: connection refused"
2026-08-10T12:07:19Z WARN  bsp: dropped 0 spans (queue not full, retrying)
```

Ese `connection refused` ubica la falla directamente en la etapa de transporte, no en el sampling ni en el batching — sin necesidad de tocar la app.

### 6.3 Verificar la decisión del sampler de forma determinista

`TraceIdRatioBased` es determinista sobre el trace ID, así que podés probar el rate sin estadística:

```console
$ for i in $(seq 1 10000); do otel-cli span --tp-print --name t$i \
    --endpoint /dev/null 2>/dev/null; done | \
  grep -c 'sampled=01'
1004
```

≈1004/10000 sampleados confirma que el ratio `0.10` es honrado por el pipeline dentro del margen de ruido.

### 6.4 Backpressure y shutdown — los dos asesinos de producción

- **Backpressure:** un collector lento/no disponible llena la cola del BSP; una vez llena, el processor **descarta** nuevos spans (nunca bloquea la app — eso es por diseño). Alertá sobre el contador de dropped-span del SDK, y dale al collector holgura o una cola propia. El pipeline del SDK es *lossy por contrato*; la garantía de durabilidad vive aguas abajo en el `sending_queue` + almacenamiento persistente del Collector, no en el SDK.
- **Shutdown:** el último lote vive solo en memoria. En `SIGTERM`, Kubernetes otorga `terminationGracePeriodSeconds`; si `Shutdown()`/`ForceFlush()` no está cableado en tu manejador de señales, o el período de gracia es más corto que `OTEL_BSP_EXPORT_TIMEOUT`, se pierden los spans finales de cada petición en vuelo. Fijá el período de gracia ≥ export timeout y siempre llamá a shutdown.

---

## 7. Referencias

- OpenTelemetry Trace SDK specification — <https://opentelemetry.io/docs/specs/otel/trace/sdk/>
- OpenTelemetry Metrics SDK specification (Views, Readers, Aggregation, Temporality) — <https://opentelemetry.io/docs/specs/otel/metrics/sdk/>
- OpenTelemetry Logs SDK specification — <https://opentelemetry.io/docs/specs/otel/logs/sdk/>
- SDK configuration & environment variables — <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/>
- Declarative (file-based) configuration — <https://opentelemetry.io/docs/specs/otel/configuration/>
- Sampling concepts — <https://opentelemetry.io/docs/concepts/sampling/>
- OTLP protocol specification — <https://opentelemetry.io/docs/specs/otlp/>
- OTLP Exporter configuration — <https://opentelemetry.io/docs/specs/otel/protocol/exporter/>
- Language SDK guides (Go/Python/Java setup) — <https://opentelemetry.io/docs/languages/>
- Resource semantic conventions — <https://opentelemetry.io/docs/specs/semconv/resource/>
- Collector `tail_sampling` processor (why tail sampling is not an SDK feature) — <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor>
- `otel-cli` tool — <https://github.com/equinix-labs/otel-cli>
- OTCA curriculum — <https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf>