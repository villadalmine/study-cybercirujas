# 4.1 Propagación de Contexto

> **Dominio:** OpenTelemetry API & SDK · **Peso en el examen:** 2.5
> **Syllabus de referencia:** OTCA Curriculum (CNCF)

---

## 1. El problema en producción: por qué un trace muere en el límite del proceso

Un span es trivial de crear dentro de un mismo proceso. La parte difícil del tracing distribuido no es *emitir* spans — es lograr que el span emitido por `checkout` y el span emitido por `payment` pertenezcan al **mismo trace**, aunque corran en pods distintos, lenguajes distintos, equipos distintos, y nunca compartan memoria.

Considerá el recorrido de una petición en una tienda:

```
client ──► ingress ──► checkout ──► cart ──► payment ──► ledger
                            │            │
                            └──► shipping └──► inventory
```

Cada salto es un proceso de sistema operativo nuevo con su propio SDK, su propio generador de números aleatorios, y su propia idea de "el span actual". Si nada cruza el cable, cada servicio arranca un **nuevo root span con un nuevo `trace_id`**. El resultado en tu backend no es un trace con 40 spans — son **40 traces desconectados de un solo span (huérfanos)**. Perdés lo único que el tracing distribuido existe para darte: una vista causal, de extremo a extremo, de una sola petición.

La **Propagación de Contexto** es el mecanismo que arregla esto. Transporta dos cosas a través de cada límite:

1. **Span context** — `trace_id`, `span_id`, `trace_flags` (la decisión de sampling), `trace_state`. Esto es lo que cose los child spans a su parent remoto.
2. **Baggage** — pares clave/valor arbitrarios de la aplicación (`user.tier=gold`, `tenant=acme`) que viajan *junto* al trace para que los servicios downstream puedan leer contexto de negocio que nunca recibieron en el cuerpo de su propia petición.

La percepción arquitectónica para un SRE: **la propagación es una preocupación de la instrumentación/SDK, no del Collector.** El Collector recibe spans que *ya* llevan los IDs correctos y solo los transporta/enriquece. Si tus traces están rotos, el bug está casi siempre en el paso inject/extract del servicio que emite — nunca en el Collector. Depurar la capa equivocada aquí es la pérdida de tiempo más común.

---

## 2. El objeto Context y el modelo de propagación

OpenTelemetry divide la propagación en dos mitades ortogonales que el examen espera que tengas claras.

### 2.1 Propagación in-process — el `Context`

`Context` es un contenedor **inmutable**, con alcance de ejecución. Toda operación que "agrega" algo devuelve un *nuevo* `Context`; el anterior queda intacto. El contexto "actual" es lo que usa como parent un span recién iniciado.

Cómo se almacena "actual" depende del lenguaje, y aquí es donde nacen los bugs de asincronía:

| Lenguaje | Portador in-process | Async-safe por defecto | Trampa en producción |
|---|---|---|---|
| **Go** | argumento explícito `context.Context` | Sí (lo enhebrás manualmente) | Olvidar pasar `ctx` a una llamada downstream arranca silenciosamente un nuevo root → span huérfano |
| **Java** | `ThreadLocal` (`Context.current()`) | No | Los thread pools / reactivos (Reactor, RxJava) pierden el contexto; envolvé los executors con `Context.taskWrapping()` |
| **Python** | `contextvars` | Sí para `asyncio` | `ThreadPoolExecutor` **no** copia el contexto → usá `contextvars.copy_context()` |
| **Node.js** | `AsyncLocalStorage` (`async_hooks`) | Sí | Librerías que usan patrones viejos de callbacks o trucos con `process.nextTick` pueden cortar la cadena async |
| **.NET** | `AsyncLocal` / `Activity.Current` | Sí | Continuaciones manuales de `Task` sobre schedulers personalizados pueden perder el `Activity` |

### 2.2 Propagación cross-process — Propagators, Inject, Extract

Un **Propagator** (formalmente un `TextMapPropagator`) serializa/deserializa el contexto hacia un **carrier** (habitualmente headers HTTP o metadata de gRPC/message-queue):

- **`inject(context, carrier, setter)`** — escribe headers en el lado **saliente** (cliente).
- **`extract(carrier, context, getter)`** — lee headers en el lado **entrante** (servidor) y devuelve un contexto cuyo "parent remoto" queda establecido.

`Setter` y `Getter` abstraen *cómo* se escribe/lee el carrier, así el mismo propagator funciona para headers de `net/http`, metadata de gRPC, o los headers de un record de Kafka.

```
[checkout]                            [payment]
tracer.start_span ──► ctx             extract(req.headers) ──► ctx (remote parent)
inject(ctx, headers) ──► HTTP ───────► tracer.start_span(context=ctx)
   traceparent: 00-4bf9…-00f0…-01         └── child of checkout's span ✔
```

---

## 3. Propagators: formatos de cable y compromisos

### 3.1 W3C Trace Context (el default)

Dos headers. Este es el formato estándar de CNCF, neutral respecto del proveedor, y el default de OTel.

**`traceparent`** — un campo de longitud fija, delimitado por guiones:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
         version│         trace-id (16 B)        │  parent-id     │ trace-flags
          (00)  │          32 hex chars          │  (span-id,8 B) │  (2 hex)
                                                    16 hex chars
```

| Campo | Bytes | Regla |
|---|---|---|
| `version` | 1 | Actualmente `00`. Las versiones desconocidas se parsean de forma tolerante, nunca se rechazan de plano. |
| `trace-id` | 16 (128-bit) | 32 hex en minúscula. **Todo-cero es inválido** → reiniciá el trace. |
| `parent-id` | 8 (64-bit) | El `span_id` del llamador, se convierte en el parent de este span. **Todo-cero es inválido.** |
| `trace-flags` | 1 | Bit 0 = `sampled`. `01` = sampled, `00` = no. Solo el bit 0 está definido actualmente. |

**`tracestate`** — continuación de estado específica de proveedor, `key=value` separados por comas:

```
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

- Máximo **32** miembros de lista; keys/values restringidos; mantené el total por debajo de ~512 bytes.
- **El orden es significativo** — el proveedor que muta más recientemente antepone su entrada a la cabeza.
- Si `traceparent` está malformado, DEBÉS reiniciar el trace **y** descartar `tracestate` (no tiene sentido sin un parent válido).

### 3.2 W3C Baggage

Un header separado e independiente que transporta contexto de la aplicación:

```
baggage: userId=alice,tenant=acme,isProduction=false;metadata-key=value
```

- Los valores están **percent-encoded** (`,`, `;`, `=` y no-ASCII deben escaparse).
- Las **propiedades** opcionales por entrada siguen a un `;`.
- **El Baggage NO se copia automáticamente en los spans.** Si querés `tenant` como atributo de span, tenés que leer el baggage y setearlo explícitamente. Esto sorprende a la gente constantemente.
- **Advertencia de seguridad/costo (crítica para SRE):** el baggage se propaga a *cada* servicio downstream, incluidos terceros a los que llamás. Nunca pongas secretos ni PII en él, y limitá su tamaño — un header de baggage abultado se multiplica en cada salto y puede violar los límites de header del proxy (`431 Request Header Fields Too Large`).

### 3.3 Propagators alternativos

| Propagator | valor de `OTEL_PROPAGATORS` | Header(s) | Formato de cable | Cuándo lo necesitás |
|---|---|---|---|---|
| **W3C Trace Context** | `tracecontext` | `traceparent`, `tracestate` | `00-{trace}-{span}-{flags}` | Default; estándar interoperable |
| **W3C Baggage** | `baggage` | `baggage` | `k=v,k=v` | Llevar contexto de app downstream |
| **B3 Single** | `b3` | `b3` | `{trace}-{span}-{sampled}-{parent}` | Mallas Zipkin / Istio |
| **B3 Multi** | `b3multi` | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-Sampled`, `X-B3-ParentSpanId`, `X-B3-Flags` | un valor por header | Flotas legacy de Zipkin |
| **Jaeger** | `jaeger` | `uber-trace-id` | `{trace}:{span}:{parent}:{flags}` (`:` URL-encoded → `%3A`) | Instrumentación de cliente Jaeger existente |
| **OT Trace** | `ottrace` | `ot-tracer-traceid`, `ot-tracer-spanid`, `ot-tracer-sampled` | legacy de OpenTracing | Migrando desde OpenTracing |
| **AWS X-Ray** | `xray` | `X-Amzn-Trace-Id` | `Root=1-{ts}-{id};Parent=…;Sampled=1` | Nativo de AWS (contrib) |
| **None** | `none` | — | deshabilita la propagación | Solo casos de aislamiento/borde |

**Resumen de compromisos:**

| Preocupación | W3C Trace Context | B3 (single) | Jaeger |
|---|---|---|---|
| Estandarización | ✅ W3C Recommendation | De-facto (Zipkin) | Proveedor (Jaeger) |
| Cantidad de headers | 2 | 1 | 1 |
| Lleva estado de proveedor | ✅ `tracestate` | ❌ | ❌ |
| Soporte de service-mesh (Istio/Envoy) | ✅ (también emite B3) | ✅ nativo | parcial |
| Tamaño del header en la ruta caliente | pequeño | el más pequeño | mediano (URL-encoded) |
| Recomendación | **Default en todos lados** | Solo si la malla lo obliga | Solo para clientes legacy de Jaeger |

**Trampa de interoperabilidad con la malla:** Istio/Envoy propagan B3 por defecto y solo *reenvían* headers de trace — **no** crean el vínculo parent/child dentro de tu app. Tu aplicación igual debe hacer `extract` en el ingress e `inject` en el egress. Si tus servicios hablan `tracecontext` pero la malla solo reenvía `b3`, configurá **ambos**: `OTEL_PROPAGATORS=tracecontext,baggage,b3multi` para que la extracción tenga éxito sin importar qué header llegue. Un propagator compuesto prueba cada uno en orden y fusiona el resultado.

---

## 4. Manifiestos completos e infraestructura

### 4.1 Workload instrumentado — la configuración relevante para la propagación

El comportamiento de propagación de un servicio está gobernado enteramente por variables de entorno consumidas por el SDK. Nada de lo que sigue es opcional para un trace correcto.

```yaml
# checkout-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app: checkout
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      containers:
        - name: checkout
          image: registry.example.com/shop/checkout:1.8.2
          ports:
            - containerPort: 8080
          env:
            # --- identity ---
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=shop,deployment.environment=prod"

            # --- export target (the Collector) ---
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-collector.observability.svc:4318
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: http/protobuf

            # --- CONTEXT PROPAGATION: the heart of this topic ---
            # Extract/inject BOTH W3C headers AND B3 (mesh interop).
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage,b3multi"

            # --- sampling MUST be parent-based to honour the propagated flag ---
            # Without parentbased_*, a downstream service may drop spans whose
            # parent was sampled → half-populated ("gappy") traces.
            - name: OTEL_TRACES_SAMPLER
              value: parentbased_traceidratio
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.1"          # 10% head sampling for NEW roots only
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
```

> **Por qué `parentbased_traceidratio` es innegociable para la propagación:** el bit `sampled` en `traceparent` (`…-01`) es una *decisión tomada upstream*. Un sampler `ParentBased` dice "si mi parent remoto fue sampleado, yo también sampleo; solo si no hay parent tiro el dado del 10%." Un sampler `traceidratio` plano ignora al parent y vuelve a tirar el dado en cada salto — garantizando estadísticamente traces donde el root existe pero las hojas faltan. El sampling y la propagación están acoplados por el flag; tratalos como una sola decisión de diseño.

### 4.2 El Collector — transporte, no propagación

```yaml
# otel-collector-config.yaml
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
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 1024
      # Surfaces the propagated IDs so you can eyeball trace continuity:
      resource:
        attributes:
          - key: collector.received
            value: "true"
            action: upsert

    exporters:
      # 'debug' prints Trace ID / Parent ID / Span ID — your primary
      # verification tool for "did the parent link survive the wire?"
      debug:
        verbosity: detailed
      otlp/jaeger:
        endpoint: jaeger-collector.observability.svc:4317
        tls:
          insecure: true

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [resource, batch]
          exporters:  [debug, otlp/jaeger]
```

**El límite conceptual que evalúa el examen:** el Collector re-emite los spans con el `trace_id`/`span_id`/`parent_span_id` **exacto** que recibió. Nunca *re-propaga* entre tus servicios de negocio y nunca repara un vínculo parent roto. Si el parent está mal cuando llega al Collector, está mal para siempre. La propagación se arregla upstream, en el SDK.

---

## 5. Código de aplicación: inject y extract en la práctica

### 5.1 Go (contexto explícito — sin magia de thread-local)

```go
package main

import (
    "net/http"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

func init() {
    // Wire up the same composite as OTEL_PROPAGATORS.
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, // traceparent / tracestate
        propagation.Baggage{},      // baggage
    ))
}

// SERVER side: rebuild context from inbound headers.
func handler(w http.ResponseWriter, r *http.Request) {
    ctx := otel.GetTextMapPropagator().
        Extract(r.Context(), propagation.HeaderCarrier(r.Header))

    ctx, span := otel.Tracer("checkout").Start(ctx, "GET /api/checkout")
    defer span.End()

    callPayment(ctx) // MUST pass ctx or the child link is lost
}

// CLIENT side: stamp outbound headers.
func callPayment(ctx context.Context) {
    req, _ := http.NewRequestWithContext(ctx, "POST",
        "http://payment.shop.svc/charge", nil)
    otel.GetTextMapPropagator().
        Inject(ctx, propagation.HeaderCarrier(req.Header))
    http.DefaultClient.Do(req)
}
```

### 5.2 Python (contextvars — cuidado con el thread pool)

```python
from opentelemetry import trace, context, baggage
from opentelemetry.propagate import inject, extract

tracer = trace.get_tracer("checkout")

# SERVER: extract remote parent, attach it, start child span.
def handle(request):
    ctx = extract(request.headers)                 # dict-like carrier
    token = context.attach(ctx)
    try:
        with tracer.start_as_current_span("handle", context=ctx):
            ctx = baggage.set_baggage("tenant", "acme")  # returns NEW context
            call_payment(ctx)
    finally:
        context.detach(token)                      # always detach

# CLIENT: inject current context into outbound headers.
def call_payment(ctx):
    headers = {}
    inject(headers, context=ctx)                   # writes traceparent/baggage
    requests.post("http://payment.shop.svc/charge", headers=headers)
```

---

## 6. Comandos CLI y salida real de terminal

### 6.1 Confirmar que el SDK inyecta `traceparent` en el egress

Apuntá el servicio a un sink que hace echo de headers y leé lo que estampó:

```console
$ kubectl -n shop exec deploy/checkout -- \
    curl -s http://echo.shop.svc/headers | jq '.headers'
{
  "host": "echo.shop.svc",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-9f0e11c2a7b34d18-01",
  "tracestate": "shop=9f0e11c2a7b34d18",
  "baggage": "tenant=acme"
}
```

El sufijo `-01` confirma que el span fue **sampleado**; la presencia de `traceparent` confirma que la inyección funciona.

### 6.2 Sembrar un trace manualmente y seguirlo de extremo a extremo

```console
$ curl -s -o /dev/null -w '%{http_code}\n' \
    -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
    -H 'baggage: tenant=acme,tier=gold' \
    http://checkout.shop.svc:8080/api/checkout
200
```

### 6.3 Leer los vínculos parent desde el debug exporter del Collector

```console
$ kubectl -n observability logs deploy/otel-collector | grep -A6 "Span #"
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Parent ID      : 00f067aa0ba902b7          <-- the seed we curled with ✔
    ID             : 9f0e11c2a7b34d18
    Name           : GET /api/checkout
    Kind           : Server
Span #1
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736   <-- SAME trace ✔
    Parent ID      : 9f0e11c2a7b34d18          <-- child of checkout ✔
    ID             : c31d0a7742e88b90
    Name           : POST /charge  (payment)
    Kind           : Client
```

**Cómo leerlo:** cada span comparte `Trace ID 4bf9…4736`, y cada `Parent ID` apunta al `ID` del span anterior. Esa cadena **es** una propagación funcionando. Un `Trace ID` que no coincide = el cable se rompió en ese salto.

### 6.4 Generar un root y propagar a través de un comando de shell con `otel-cli`

`otel-cli exec` arranca un span y exporta `TRACEPARENT` al entorno del proceso hijo — la manera canónica de probar la propagación sin escribir código:

```console
$ otel-cli exec \
    --endpoint http://otel-collector.observability.svc:4318 \
    --service load-test --name "smoke" --tp-print \
    -- curl -s -H "traceparent: $TRACEPARENT" http://checkout.shop.svc:8080/api/checkout
# TRACEPARENT=00-1a2b3c4d5e6f70819a2b3c4d5e6f7081-a1b2c3d4e5f60718-01
```

---

## 7. Verificación y diagnóstico de fallas

### 7.1 El triaje de dos preguntas

1. **¿Comparten todos los saltos un mismo `trace_id`?** → No: la propagación está rota (Sección 7.2, filas 1–5).
2. **¿Comparten todos los saltos un mismo `trace_id` pero faltan spans?** → falta de coincidencia de sampling, no de propagación (fila 6).

### 7.2 Catálogo de fallas

| Síntoma | Causa raíz | Cómo confirmar | Arreglo |
|---|---|---|---|
| Cada servicio es su propio root; N traces huérfanos | Falta de coincidencia del propagator o no configurado | Comparar `OTEL_PROPAGATORS` entre servicios; revisar headers entrantes con 6.1 | Alinear propagators; agregar `b3multi` si hay una malla detrás |
| `traceparent` entrante presente, pero el span del servidor sigue siendo un root | El servidor nunca llama a `extract` (auto-instrumentación faltante/deshabilitada) | El debug exporter muestra `Parent ID` vacío pese a que el header llega | Habilitar la instrumentación del server HTTP / llamar a `extract` manualmente |
| El trace vincula pero faltan los leaf spans | El downstream usa un sampler no basado en parent | `OTEL_TRACES_SAMPLER` es `traceidratio`/`always_off` | Cambiar a `parentbased_traceidratio` |
| Contexto perdido tras un salto `ThreadPoolExecutor`/reactivo | Contexto in-process no transportado entre threads | Se reproduce bajo concurrencia; el parent span ID se resetea a mitad del servicio | Envolver el executor (`copy_context()`, `Context.taskWrapping()`, scheduler instrumentado) |
| Los headers desaparecen en el borde | El allowlist de headers del proxy/ingress elimina headers desconocidos | `curl` directo vs a través del proxy (6.2) | Agregar al allowlist `traceparent`, `tracestate`, `baggage`, `b3*` |
| `431 Request Header Fields Too Large` / baggage truncado | Baggage sobredimensionado acumulándose por salto | Inspeccionar la longitud del header `baggage` (6.1) | Limitar el baggage; nunca volcar mapas dentro de él |
| `tracestate` descartado pero el trace igual vincula | Un `traceparent` upstream malformado forzó un reinicio | El debug exporter muestra un `trace_id` fresco sin parent | Arreglar el emisor que produce un `traceparent` inválido |

### 7.3 Chequeos rápidos para tener en el runbook

```console
# 1. Is the propagator set the same everywhere?
$ kubectl -n shop get deploy -o \
    jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].env[?(@.name=="OTEL_PROPAGATORS")].value}{"\n"}{end}'
checkout    tracecontext,baggage,b3multi
payment     tracecontext,baggage,b3multi
cart        tracecontext,baggage            <-- MISMATCH: no b3multi ✗

# 2. Does a header actually arrive at the server?
$ kubectl -n shop exec deploy/payment -- sh -c \
    'printf "" | nc -l -p 9000 & curl -s -H "traceparent: 00-...-01" localhost:9000'

# 3. Prove parent linkage in the backend, not by eye:
$ kubectl -n observability logs deploy/otel-collector \
    | grep -E "Trace ID|Parent ID" | sort | uniq -c
```

La fila 1 de arriba es el bug de manual: `cart` omite `b3multi`, así que cuando Istio le entrega un header `b3` (y ningún `traceparent`), la extracción devuelve un contexto vacío y `cart` arranca un nuevo root — un salto roto que fragmenta cada trace que lo toca.

---

## 8. Referencias

- OTCA Curriculum (CNCF) — https://github.com/cncf/curriculum
- OpenTelemetry — Context propagation (concepts) — https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry — Propagators API (specification) — https://opentelemetry.io/docs/specs/otel/context/api-propagators/
- OpenTelemetry — Context (specification) — https://opentelemetry.io/docs/specs/otel/context/
- OpenTelemetry — Baggage (concepts) — https://opentelemetry.io/docs/concepts/signals/baggage/
- OpenTelemetry — SDK environment variables (`OTEL_PROPAGATORS`, samplers) — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry — Sampling (`ParentBased`) — https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling
- W3C — Trace Context Recommendation — https://www.w3.org/TR/trace-context/
- W3C — Baggage specification — https://www.w3.org/TR/baggage/
- OpenZipkin — B3 propagation — https://github.com/openzipkin/b3-propagation
- OpenTelemetry Collector — debug exporter — https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/debugexporter
- `otel-cli` — https://github.com/equinix-labs/otel-cli