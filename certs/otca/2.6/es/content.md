# 2.6 Propagación de contexto

> OTCA Dominio 2 — *Fundamentos de OpenTelemetry* · Peso en el examen: **6.57%**
> Idioma de autoría: English · Nivel: Principal Platform / SRE

---

## 1. El problema en producción: por qué una traza no vale nada sin propagación

Una única petición en una plataforma moderna no la sirve un solo proceso. Un POST de checkout llega a un ingress controller, se enruta a un pod `frontend`, que llama a `cart`, que llama a `pricing`, que lee de `redis` y publica un evento en Kafka que un consumidor `fulfilment` recoge 40 ms más tarde en un nodo completamente distinto. Eso son **seis o siete procesos independientes, tres saltos de red, un límite asíncrono**, y *nada* en el protocolo de transporte le dice a `pricing` que su trabajo pertenece a la misma operación lógica que la petición de ingress — a menos que vos lo pongas ahí.

La propagación de contexto es el mecanismo que transporta la identidad de la operación en curso *a través de cada uno de esos límites* de modo que los spans emitidos por siete procesos no relacionados se reensamblen en una única traza conectada. Quitala y no obtenés una traza degradada; obtenés siete trazas desconectadas de un solo span, cada una inútil para responder la única pregunta que importa en un incidente: *¿dónde ocurrió realmente la latencia / el error?*

Hay dos límites distintos, y OpenTelemetry los trata por separado:

| Límite | Ejemplo | Mecanismo |
|---|---|---|
| **In-process** | Una tarea asíncrona, un worker de un thread-pool, un callback que continúa la misma petición | El objeto `Context` + un `ContextManager` (thread-local implícito / `contextvars` / `context.Context` de Go) |
| **Cross-process** | Llamada HTTP, llamada gRPC, mensaje de Kafka/RabbitMQ, disparador cron | Un **Propagator** serializa el contexto en headers portadores (carrier) y lo deserializa del otro lado |

El modo de fallo arquitectónico sobre el que te están evaluando es la **traza rota**: un servicio hijo inicia una *nueva traza raíz* en lugar de continuar la del llamante, porque ambos lados no coincidieron en *cómo* se codifica el contexto en el transporte. Esto casi nunca es un bug en el tracer — es un desajuste de propagador, un salto sin instrumentar, o un contexto in-process perdido a través de un límite asíncrono. El resto de este tema es la mecánica necesaria para diagnosticar exactamente eso.

### Las dos cosas que se propagan

OpenTelemetry propaga dos cargas conceptualmente distintas a través del mismo contenedor `Context`:

1. **`SpanContext`** — la identidad *inmutable* del span activo: `trace_id`, `span_id`, `trace_flags` (el bit de sampled), `trace_state`, y un flag `is_remote`. Esto es lo que cose los spans en un árbol. Lo crea el SDK, nunca el usuario.
2. **`Baggage`** — pares clave/valor arbitrarios *definidos por el usuario* (`user.tier=premium`, `tenant.id=acme`) que acompañan a toda la petición para que cualquier servicio downstream pueda leerlos y, por ejemplo, agregarlos como atributos de span o impulsar una decisión de sampling. Baggage es dato de aplicación; SpanContext es plomería de telemetría.

Mantener esto claro es la trampa conceptual de examen más común: **Baggage no son atributos de span, y no es el trace context.** Se propaga; los atributos de span no.

---

## 2. Propagators: los formatos de transporte y sus compromisos

Un **propagator** implementa la interfaz `TextMapPropagator`, que tiene exactamente dos operaciones más un método de introspección `fields()`:

```
inject(context, carrier, setter)   // Context  -> headers  (client / producer side)
extract(carrier, context, getter)  // headers -> Context   (server / consumer side)
fields()                           // the header names this propagator writes
```

El `carrier` es cualquier cosa con forma de clave/valor — normalmente el mapa de headers HTTP. El `getter`/`setter` abstraen *cómo* leerlo/escribirlo, de modo que el mismo propagator funciona para headers de `net/http`, metadata de gRPC, o headers de records de Kafka.

### 2.1 W3C Trace Context — el formato por defecto, en la vía de estándares

Esta es la Recomendación IETF/W3C y el formato por defecto de OpenTelemetry. Define **dos headers**.

**`traceparent`** — una única cadena ASCII de formato fijo:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  │                                │                └─ trace-flags  (1 byte, 2 hex; bit 0 = sampled)
             │  │                                └─ parent-id / span-id (8 bytes, 16 hex, non-zero)
             │  └─ trace-id (16 bytes, 32 hex, non-zero)
             └─ version (1 byte, 2 hex; currently 00)
```

Reglas estrictas que el extractor aplica (conocelas — son el origen de "por qué está rota mi traza"):

- `trace-id` todo en cero (`000...0`) → **inválido**, header descartado.
- `span-id` todo en cero → **inválido**, header descartado.
- Longitudes de campo incorrectas, caracteres no hexadecimales, o número incorrecto de separadores `-` → descartado.
- El bit 0 de `trace-flags` puesto (`01`) significa que el *sampler upstream decidió registrar/samplear*. `00` significa que no lo hizo.

Cuando un `traceparent` se descarta, el receptor no tiene padre remoto, así que inicia una **nueva raíz** — la clásica traza rota.

**`tracestate`** — lista específica de proveedor, mutable y ordenada, de hasta **32** miembros, `key=value` separados por comas, recomendado ≤ 512 bytes en total:

```
tracestate: ot=th:0;p:8,rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

OpenTelemetry usa el miembro `ot=` para transportar datos a nivel de SDK como el umbral de sampling de probabilidad consistente (`th`). Cada proveedor antepone su propia clave; las entradas están ordenadas por LRU (la más recientemente mutada primero) y las entradas más antiguas se desalojan cuando se alcanza el límite de 32 miembros.

### 2.2 W3C Baggage

El baggage se propaga mediante un propagator *separado* que escribe el header **`baggage`** (valores codificados en porcentaje, propiedades opcionales delimitadas por `;`):

```
baggage: userId=alice,serverNode=DF%2028,isProduction=false,tenant=acme;ttl=30
```

Habilitalo explícitamente — es parte del conjunto por defecto de OTel (`tracecontext,baggage`) pero es un propagator distinto que podés quitar.

### 2.3 Las alternativas y cuándo te ves forzado a usarlas

| Formato | Headers | Único/Múltiple | Soporte de baggage | Lo necesitás cuando… |
|---|---|---|---|---|
| **W3C `tracecontext`** | `traceparent`, `tracestate` | Único | vía `baggage` separado | Por defecto. Greenfield, basado en estándares. |
| **`b3` (single)** | `b3` | Único | No | Interoperar con Zipkin / servicios Java legacy instrumentados con Brave. |
| **`b3multi`** | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-ParentSpanId`, `X-B3-Sampled`, `X-B3-Flags` | Múltiple | No | Meshes/proxies antiguos que solo reenvían el conjunto B3 multi-header. |
| **`jaeger`** | `uber-trace-id`, `uberctx-*` | Único | Sí (`uberctx-`) | Migrar una flota Jaeger-native antes de pasar a W3C. |
| **`xray`** | `X-Amzn-Trace-Id` | Único | No | Bordes terminados en AWS App Mesh / ALB / X-Ray. |
| **`ottrace`** | `ot-tracer-traceid`, `ot-tracer-spanid`, `ot-tracer-sampled`, `ot-baggage-*` | Múltiple | Sí (`ot-baggage-`) | Servicios legacy instrumentados con OpenTracing. |

Layout del **B3 single header** — memorizá el orden de los campos, relevante para el examen:

```
b3: {trace_id}-{span_id}-{sampling_state}-{parent_span_id}
b3: 80f198ee56343ba864fe8b2a57d3eff7-e457b5a2e4d86bd1-1-05e3ac9a4f6e3b90
```

`sampling_state`: `1`=sampled, `0`=not sampled, `d`=debug/force. `parent_span_id` es opcional.

Layout del `uber-trace-id` de **Jaeger** (separado por dos puntos, notá que el trace-id puede ser de 64 *o* 128 bits):

```
uber-trace-id: {trace-id}:{span-id}:{parent-span-id}:{flags}
uber-trace-id: 4bf92f3577b34da6a3ce929d0e0e4736:00f067aa0ba902b7:0:1
```

### 2.4 Propagators compuestos — la configuración real de producción

Rara vez ejecutás un solo propagator. Durante una migración debés **extraer** varios formatos (aceptar lo que sea que envíe el upstream) mientras **inyectás** un formato canónico de ahí en adelante. El `CompositeTextMapPropagator` (también llamado propagator compuesto/global) los encadena:

- En `extract`, prueba cada hijo en orden y fusiona resultados — el primero que produzca un `SpanContext` válido gana para el trace context; el baggage de todos se fusiona.
- En `inject`, **cada** hijo escribe sus headers, así que la petición saliente lleva `traceparent` *y* `b3` *y* `uber-trace-id` simultáneamente.

Compromiso: inyectar todos los formatos infla los headers (B3 multi + Jaeger + W3C pueden agregar más de 400 bytes por salto) y puede confundir a un downstream que extrae múltiples formatos en contextos conflictivos. Configurá el conjunto *mínimo* que cubra tu flota, y quitá los formatos de migración una vez que el cutover se complete.

### 2.5 In-process vs cross-process — no los confundas

| | Propagación in-process | Propagación cross-process |
|---|---|---|
| Carrier | El propio objeto `Context` | Headers HTTP/gRPC/Kafka |
| Mecanismo | `ContextManager` (thread-local / `contextvars` de Python / `context.Context` explícito de Go) | `TextMapPropagator.inject`/`extract` |
| Modo de fallo | Contexto perdido a través de un límite `async`/thread-pool/callback → el span hijo no tiene padre *dentro del mismo proceso* | Header eliminado/reescrito por un proxy, o desajuste de propagador → nueva traza raíz |
| Solución | Adjuntar/desadjuntar el contexto correctamente; usar las primitivas conscientes de contexto del runtime | Alinear `OTEL_PROPAGATORS`; asegurarse de que los proxies reenvíen los headers |

El objeto `Context` es **inmutable**: `context.with_value(key, value)` devuelve un *nuevo* contexto. La auto-instrumentación hace que el span actual sea implícito; cuando cruzás un límite que el SDK no puede ver (un thread que lanzaste, un mensaje que encolaste), *vos* sos responsable de capturar el contexto activo y re-adjuntarlo del otro lado.

---

## 3. Configuración, código e infraestructura (completo, sin abreviar)

### 3.1 Seleccionar propagators de forma declarativa

El control canónico y sin código es la variable de entorno. Separada por comas, el orden es significativo para la extracción:

```bash
# Default if unset:
OTEL_PROPAGATORS=tracecontext,baggage

# Accept W3C + legacy B3 + Jaeger during a migration, still carry baggage:
OTEL_PROPAGATORS=tracecontext,baggage,b3multi,jaeger

# Disable all propagation (e.g. a hard trust boundary that must start fresh traces):
OTEL_PROPAGATORS=none
```

Tokens válidos: `tracecontext`, `baggage`, `b3`, `b3multi`, `jaeger`, `xray`, `ottrace`, `none`. Un token no reconocido se registra y se omite — un typo silencioso (`traceparent` en lugar de `tracecontext`) es una causa real de "propagación configurada pero sin funcionar".

### 3.2 Un despliegue completo: dos servicios que coinciden en los propagators

```yaml
# ---------------------------------------------------------------------------
# frontend.yaml — Deployment + Service. Emits traceparent + baggage downstream.
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: shop
  labels: { app: frontend }
spec:
  replicas: 2
  selector:
    matchLabels: { app: frontend }
  template:
    metadata:
      labels: { app: frontend }
    spec:
      containers:
        - name: frontend
          image: registry.internal/shop/frontend:1.8.0
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: OTEL_SERVICE_NAME
              value: frontend
            # Both services MUST agree on this set or the trace breaks at the hop.
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability:4317"
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: "grpc"
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.10"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,deployment.environment=prod"
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: shop
spec:
  selector: { app: frontend }
  ports:
    - { name: http, port: 80, targetPort: http }
---
# ---------------------------------------------------------------------------
# pricing.yaml — the downstream. Same propagator set is non-negotiable.
# ---------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pricing
  namespace: shop
  labels: { app: pricing }
spec:
  replicas: 3
  selector:
    matchLabels: { app: pricing }
  template:
    metadata:
      labels: { app: pricing }
    spec:
      containers:
        - name: pricing
          image: registry.internal/shop/pricing:2.3.1
          ports:
            - { name: http, containerPort: 8090 }
          env:
            - name: OTEL_SERVICE_NAME
              value: pricing
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"   # identical to frontend
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability:4317"
            # parentbased sampler => it OBEYS the upstream sampled flag in traceparent.
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.10"
```

**Interacción crítica con el sampling:** el sampler `parentbased_*` lee el bit 0 de las `trace-flags` del `traceparent` entrante. Si el frontend sampleó la traza (`-01`), un servicio pricing `parentbased` lo respeta y también registra — la traza completa es consistente. Un sampler `traceidratio` (no basado en el padre) en pricing volvería a decidir de forma independiente y produciría trazas *parciales* con huecos. El sampling y la propagación están acoplados; esta es una intersección favorita del examen.

### 3.3 Propagación manual en código (el límite del SDK que debés manejar vos mismo)

**Lado cliente — inyectando en una petición saliente (Python):**

```python
from opentelemetry import trace, propagate
from opentelemetry.trace import SpanKind
import requests

tracer = trace.get_tracer("shop.frontend")

def call_pricing(sku: str) -> dict:
    with tracer.start_as_current_span("GET /price", kind=SpanKind.CLIENT) as span:
        span.set_attribute("shop.sku", sku)
        headers: dict[str, str] = {}
        # Serialize the ACTIVE context (span context + baggage) into the carrier.
        # Uses the globally configured composite propagator honoring OTEL_PROPAGATORS.
        propagate.inject(headers)
        # headers now contains e.g.:
        #   traceparent: 00-<trace_id>-<span_id>-01
        #   baggage:     tenant=acme,user.tier=premium
        resp = requests.get(f"http://pricing/price?sku={sku}", headers=headers, timeout=2)
        return resp.json()
```

**Lado servidor — extrayendo al contexto local (Python / manual, lo que la auto-instrumentación hace por vos):**

```python
from opentelemetry import trace, propagate
from opentelemetry.trace import SpanKind

tracer = trace.get_tracer("shop.pricing")

def handle_request(request):
    # Rebuild the remote context from the inbound headers.
    ctx = propagate.extract(request.headers)
    # Start the server span AS A CHILD of the remote context.
    with tracer.start_as_current_span(
        "GET /price", context=ctx, kind=SpanKind.SERVER
    ) as span:
        # span.parent is now the frontend's CLIENT span => trace is connected.
        ...
```

**Baggage — se define una vez, se lee en cualquier parte downstream:**

```python
from opentelemetry import baggage, context

# frontend: attach baggage to the current context
ctx = baggage.set_baggage("user.tier", "premium")
token = context.attach(ctx)
try:
    call_pricing("SKU-42")   # inject() will emit: baggage: user.tier=premium
finally:
    context.detach(token)

# pricing (downstream): read it back after extract()
tier = baggage.get_baggage("user.tier")   # -> "premium"
span.set_attribute("user.tier", tier)      # promote baggage -> attribute for querying
```

**Go — el contexto explícito es el vehículo de propagación:**

```go
import (
    "context"
    "net/http"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

// Install a composite global propagator once at startup.
func init() {
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, // W3C traceparent/tracestate
        propagation.Baggage{},      // W3C baggage
    ))
}

// Inject on the client side.
func callPricing(ctx context.Context, req *http.Request) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
    // req.Header now carries traceparent + baggage.
}

// Extract on the server side.
func handler(w http.ResponseWriter, r *http.Request) {
    ctx := otel.GetTextMapPropagator().Extract(r.Context(),
        propagation.HeaderCarrier(r.Header))
    ctx, span := tracer.Start(ctx, "GET /price") // child of remote span
    defer span.End()
}
```

### 3.4 Propagación asíncrona / de cola de mensajes (el salto que la instrumentación olvida)

HTTP está auto-instrumentado; **tus productores/consumidores de Kafka normalmente no lo están**. Debés inyectar y extraer de los headers del mensaje manualmente o la traza se rompe en el límite asíncrono:

```python
from opentelemetry import trace, propagate
from opentelemetry.trace import SpanKind
from confluent_kafka import Producer, Consumer

tracer = trace.get_tracer("shop.fulfilment")

# ---- Producer: inject into Kafka record headers ----
def publish(order_id: str, payload: bytes):
    with tracer.start_as_current_span("orders publish", kind=SpanKind.PRODUCER) as span:
        carrier: dict[str, str] = {}
        propagate.inject(carrier)                       # traceparent -> carrier
        kafka_headers = [(k, v.encode()) for k, v in carrier.items()]
        producer.produce("orders", value=payload, headers=kafka_headers)

# ---- Consumer: extract from Kafka record headers ----
def consume(msg):
    carrier = {k: v.decode() for k, v in (msg.headers() or [])}
    ctx = propagate.extract(carrier)                    # rebuild remote context
    with tracer.start_as_current_span(
        "orders process", context=ctx, kind=SpanKind.CONSUMER
    ) as span:
        span.set_attribute("messaging.system", "kafka")
        ...  # this span links back to the producer 40ms and one node away
```

### 3.5 El rol del Collector (y lo que *no* hace)

Una idea equivocada común: *el Collector propaga contexto.* **No lo hace.** No crea ni extrae headers en formato de transporte para tu telemetría — la propagación es una preocupación del SDK/instrumentación que ya ocurrió del lado de la aplicación. El Collector *recibe* spans completamente formados vía OTLP (que llevan los IDs de traza/span dentro del protobuf, no en los headers `traceparent`) y los procesa. La preocupación relevante del Collector es preservar la consistencia a nivel de traza durante el sampling:

```yaml
# otel-collector-config.yaml — tail sampling keeps whole traces intact.
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  batch:
    timeout: 5s
    send_batch_size: 512
  # Tail sampling needs ALL spans of a trace_id together -> only valid on a
  # single collecting instance (or after a trace-ID-aware load-balancing tier).
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    policies:
      - name: keep-errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: keep-slow
        type: latency
        latency: { threshold_ms: 500 }
      - name: baseline-probabilistic
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }

exporters:
  otlp/tempo:
    endpoint: tempo.observability:4317
    tls: { insecure: true }

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [tail_sampling, batch]
      exporters:  [otlp/tempo]
```

La implicación de propagación: **el tail sampling solo funciona si cada span de un `trace_id` llega al mismo Collector que toma la decisión**. Por eso las flotas anteponen al Collector un exporter `loadbalancing` que enruta por `trace_id` — de lo contrario, una traza bien propagada igual se divide entre réplicas del Collector y la mitad de sus spans se descartan.

---

## 4. CLI y terminal — observando la propagación en el transporte

### 4.1 Comprobar qué propagators cargó realmente un SDK

```console
$ OTEL_PROPAGATORS=tracecontext,baggage,b3 \
  OTEL_SERVICE_NAME=frontend \
  opentelemetry-instrument python -c "from opentelemetry import propagate; print(propagate.get_global_textmap().fields)"
{'traceparent', 'tracestate', 'baggage', 'b3'}
```

El conjunto `fields` es autoritativo — si `traceparent` falta acá, ningún cambio de código lo hará aparecer en el transporte.

### 4.2 Ver los headers que lleva una petición real

Ejecutá un target que haga eco de headers y hacé curl a través de tu cliente instrumentado, o inyectá a mano para simular un upstream:

```console
$ curl -s http://pricing.shop/price?sku=SKU-42 \
    -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
    -H 'baggage: tenant=acme,user.tier=premium' \
    -D - -o /dev/null
HTTP/1.1 200 OK
content-type: application/json
# server echoed its child span id back for correlation:
x-trace-id: 4bf92f3577b34da6a3ce929d0e0e4736
```

Confirmá que el downstream continuó la misma traza, no una nueva — el `trace-id` en la respuesta coincide con el `trace-id` que enviaste (`4bf92f35...`). Si difiere, el header fue eliminado o el propagator no coincidió.

### 4.3 Inspeccionar qué reenvía un proxy/mesh

```console
$ kubectl -n shop exec deploy/pricing -c pricing -- \
    sh -c 'cat /proc/1/environ | tr "\0" "\n" | grep OTEL_PROPAGATORS'
OTEL_PROPAGATORS=tracecontext,baggage

$ kubectl -n shop logs deploy/pricing -c pricing --tail=5 | grep -i traceparent
DEBUG otel.propagation extracted remote context trace_id=4bf92f3577b34da6a3ce929d0e0e4736 \
      span_id=00f067aa0ba902b7 sampled=true is_remote=true
```

`is_remote=true` es la prueba de que `extract` tuvo éxito y el span es una *continuación*, no una raíz.

### 4.4 Decodificar un traceparent a mano

```console
$ echo '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' | \
    awk -F- '{printf "version=%s\ntrace_id=%s (%d hex)\nspan_id=%s (%d hex)\nflags=%s sampled=%d\n", \
             $1,$2,length($2),$3,length($3),$4, ("0x"$4)%2}'
version=00
trace_id=4bf92f3577b34da6a3ce929d0e0e4736 (32 hex)
span_id=00f067aa0ba902b7 (16 hex)
flags=01 sampled=1
```

`length($2)==32` y `length($3)==16` son las comprobaciones de validez que realiza el extractor. Cualquier otra longitud → el header se rechaza y se inicia una nueva raíz.

### 4.5 Verificar la simetría de propagators en toda la flota de una sola vez

```console
$ for d in frontend cart pricing fulfilment; do
    printf '%-12s ' "$d"
    kubectl -n shop set env deploy/$d --list 2>/dev/null | grep '^OTEL_PROPAGATORS' || echo 'OTEL_PROPAGATORS=(default) tracecontext,baggage'
  done
frontend     OTEL_PROPAGATORS=tracecontext,baggage
cart         OTEL_PROPAGATORS=tracecontext,baggage
pricing      OTEL_PROPAGATORS=tracecontext,baggage
fulfilment   OTEL_PROPAGATORS=b3multi          # <-- MISMATCH: fulfilment won't read traceparent
```

Esa última línea es un incidente diagnosticado en un solo comando: `fulfilment` solo extrae B3, así que cada mensaje de Kafka que lleva `traceparent` se ignora y los spans de fulfilment inician raíces nuevas.

---

## 5. Verificación y diagnóstico de fallos

### 5.1 El árbol de decisión de la traza rota

**Síntoma: los spans downstream aparecen como trazas raíz separadas (sin padre).**

1. **¿Está instrumentado el salto en absoluto?**
   La auto-instrumentación cubre clientes HTTP/gRPC/DB; **las colas de mensajes, los protocolos personalizados y los threads/tareas asíncronas frecuentemente no lo están.** Confirmá que el cliente realmente está llamando a `inject` (verificá `fields` y capturá los headers salientes). Sin `traceparent` en el transporte → brecha de instrumentación, no un problema de propagador.

2. **¿Ambos lados listan el mismo propagator?**
   Compará `OTEL_PROPAGATORS` (§4.5). El desajuste W3C↔B3 es la causa n.º 1. El emisor emite `traceparent`; el receptor solo lee `b3` → header ignorado → nueva raíz.

3. **¿Hay un intermediario eliminando el header?**
   Los API gateways, WAFs y service meshes con listas de permitidos (allow-lists) descartan headers desconocidos. `traceparent`/`tracestate`/`baggage`/`b3`/`X-B3-*`/`uber-trace-id` deben estar en la allow-list de reenvío. Capturá los headers *tal como los recibe el servidor*, no como los envió el cliente.

4. **¿El `traceparent` es estructuralmente válido?**
   `trace-id`/`span-id` todo en cero, longitud incorrecta, o no hexadecimal → descartado silenciosamente (§4.4). Un injector artesanal con bugs es una fuente clásica.

5. **¿Sobrevivió el contexto in-process?**
   Si la traza se rompe *dentro de un proceso* (el padre y el hijo son el mismo servicio), el `Context` activo se perdió a través de un límite asíncrono/de thread. Capturá el contexto antes del límite y re-adjuntalo después (§3.4).

### 5.2 Síntoma: la traza conecta pero falta la mitad de los spans

Esto es un fallo de **consistencia de sampling**, no de propagación. Un downstream que usa un sampler no basado en el padre vuelve a decidir de forma independiente. Solución: poné `OTEL_TRACES_SAMPLER=parentbased_traceidratio` en todas partes para que los downstreams obedezcan el flag de sampled en `traceparent` (§3.2). Verificá que el flag realmente llegó:

```console
$ kubectl -n shop logs deploy/pricing | grep 'sampled=' | tail -1
DEBUG extracted remote context ... sampled=true is_remote=true
```

`sampled=true` presente pero el span igual se descarta → el sampler local no es `parentbased`.

### 5.3 Síntoma: el baggage está vacío downstream

- El propagator `baggage` no está en `OTEL_PROPAGATORS` en **ninguno** de los lados (es separado de `tracecontext`).
- El mesh eliminó el header `baggage` (allow-list).
- Definiste el baggage *después* de que la llamada saliente ya se despachó, o sobre un contexto que nunca `attach`aste. El baggage viaja en el contexto *activo* en el momento del `inject`.
- **El baggage no son automáticamente atributos de span** — lo leés y lo definís vos mismo (§3.3). Esperar poder hacer consultas sobre él sin promoverlo es la confusión habitual.

### 5.4 Checklist de validación antes de declarar la propagación sana

```console
# 1. Every service reports the same, correct propagator set
$ kubectl -n shop get deploy -o json | \
    jq -r '.items[] | .metadata.name as $n |
           (.spec.template.spec.containers[].env[]? | select(.name=="OTEL_PROPAGATORS") | "\($n)=\(.value)")'
frontend=tracecontext,baggage
cart=tracecontext,baggage
pricing=tracecontext,baggage
fulfilment=tracecontext,baggage        # fixed

# 2. End-to-end: one request produces ONE trace_id with N connected spans
$ curl -s -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
       http://frontend.shop/checkout >/dev/null
$ curl -s "http://tempo.observability:3200/api/traces/4bf92f3577b34da6a3ce929d0e0e4736" | \
    jq '[.batches[].scopeSpans[].spans[] | {name, kind, parent: .parentSpanId}] | length'
7                                       # 7 connected spans, one trace -> propagation OK
```

Si el paso 2 devuelve spans con `parentSpanId` vacío/ajeno a mitad del árbol, recorré el árbol hacia atrás hasta el primer huérfano — ese salto es donde se rompió la propagación, y §5.1 te dice cuál de las cinco causas es.

---

## 6. Referencias

- W3C — *Trace Context* (Recommendation): https://www.w3.org/TR/trace-context/
- W3C — *Baggage*: https://www.w3.org/TR/baggage/
- OpenTelemetry — *Context propagation* (concepts): https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry — *Propagators* (specification): https://opentelemetry.io/docs/specs/otel/context/api-propagators/
- OpenTelemetry — *Context* (specification): https://opentelemetry.io/docs/specs/otel/context/
- OpenTelemetry — *Baggage API* (specification): https://opentelemetry.io/docs/specs/otel/baggage/api/
- OpenTelemetry — *SDK environment variables* (`OTEL_PROPAGATORS`): https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry — *TraceState* / `tracestate` handling: https://opentelemetry.io/docs/specs/otel/trace/api/#tracestate
- OpenTelemetry — *Sampling* (parent-based samplers & the sampled flag): https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry Collector — *Tail Sampling Processor*: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- OpenTelemetry Collector — *Load-balancing exporter* (trace-ID routing): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- OpenZipkin — *B3 propagation* specification: https://github.com/openzipkin/b3-propagation
- Jaeger — *Trace context propagation format*: https://www.jaegertracing.io/docs/1.53/client-libraries/#propagation-format
- CNCF — *OTCA Curriculum*: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf