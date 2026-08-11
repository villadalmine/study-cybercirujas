# Tema 2.2 — Componibilidad y extensión

**Ejercicios guiados · OTCA · Dominio: The OpenTelemetry API and SDK**

OpenTelemetry no es un agente monolítico: es un conjunto de **interfaces con implementaciones intercambiables**. La componibilidad es la propiedad que te permite ensamblar un pipeline de telemetría a partir de partes pequeñas y reemplazables de forma independiente (processors, samplers, exporters, propagators, resource detectors, componentes del Collector); la extensión es la capacidad de escribir tu *propia* implementación de cualquiera de esas interfaces sin hacer un fork del proyecto. Estos ejercicios te guían por los puntos de extensión concretos, desde la frontera del SDK hasta la construcción de una distribución personalizada del Collector.

> Temario de referencia: OTCA Curriculum — *The OpenTelemetry API and SDK* (`https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf`).

### Requisitos previos

- Go 1.22+ (`go version`)
- `go.opentelemetry.io/otel` v1.28+ y los módulos `sdk` correspondientes
- El OpenTelemetry Collector Builder (`ocb`/`builder`) para el Ejercicio 5 — instalalo con
  `go install go.opentelemetry.io/collector/cmd/builder@latest`
- Un módulo de prueba: `mkdir otca-22 && cd otca-22 && go mod init example.com/otca22`

---

## Ejercicio 1 — La frontera API/SDK: por qué OpenTelemetry es componible en primer lugar

La decisión de diseño más importante de OpenTelemetry es que **la instrumentación depende solo de la API**, y el **SDK lo conecta la aplicación en el arranque**. Si no hay ningún SDK registrado, la API es un no-op. Esto es lo que permite instrumentar una librería una sola vez y usarla en *cualquier* aplicación, sin importar qué exporter o sampler elija esa aplicación.

### Pasos

1. Creá `main.go` con instrumentación que importe **solo la API** (sin `sdk/*`):

    ```go
    package main

    import (
        "context"
        "fmt"

        "go.opentelemetry.io/otel"
        "go.opentelemetry.io/otel/attribute"
    )

    func doWork(ctx context.Context) {
        // A library would write exactly this and nothing else.
        tracer := otel.Tracer("example.com/otca22")
        _, span := tracer.Start(ctx, "doWork")
        defer span.End()
        span.SetAttributes(attribute.String("work.kind", "demo"))

        fmt.Printf("recording=%v  spanID=%s\n",
            span.IsRecording(), span.SpanContext().SpanID())
    }

    func main() {
        doWork(context.Background())
    }
    ```

2. Ejecutalo **sin ningún SDK registrado**:

    ```console
    $ go run .
    recording=false  spanID=0000000000000000
    ```

    El `TracerProvider` global es por defecto un **no-op**: los spans no graban, el span ID es todo ceros, no se emite nada. El código es válido, seguro y casi no cuesta nada.

3. Ahora, **sin tocar `doWork`**, agregá el SDK en `main`:

    ```go
    import (
        sdktrace "go.opentelemetry.io/otel/sdk/trace"
        "go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
    )

    func main() {
        exp, _ := stdouttrace.New(stdouttrace.WithPrettyPrint())
        tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
        otel.SetTracerProvider(tp)            // <-- the wiring happens ONCE, here
        defer tp.Shutdown(context.Background())

        doWork(context.Background())
    }
    ```

4. Ejecutá de nuevo:

    ```console
    $ go run .
    recording=true  spanID=8f2a1c...
    {
      "Name": "doWork",
      "SpanContext": { "TraceID": "…", "SpanID": "8f2a1c…" },
      "Attributes": [ { "Key": "work.kind", "Value": { "Type": "STRING", "Value": "demo" } } ]
      ...
    }
    ```

    El **mismo código de instrumentación** ahora está activo — porque el SDK, no la API, decidió qué pasa.

### Comprobá lo que entendiste

- **1a.** ¿Por qué `span.IsRecording()` devuelve `false` en el paso 2 aunque `Start`/`End`/`SetAttributes` se ejecutaron todos correctamente?
- **1b.** Una librería HTTP de terceros se instrumenta a sí misma con `otel.Tracer(...)`. ¿Por qué es un error de diseño que esa librería importe `go.opentelemetry.io/otel/sdk/trace` o llame a `otel.SetTracerProvider`?
- **1c.** ¿Cuál es el beneficio práctico de que `IsRecording()` sea barato cuando no hay ningún SDK instalado?

---

## Ejercicio 2 — Extender el pipeline con un `SpanProcessor` personalizado

Un `SpanProcessor` es el hook por-span del SDK. El `BatchSpanProcessor` incorporado agrupa spans en lotes hacia un exporter; podés escribir el tuyo para enriquecer, filtrar o redactar. La interfaz tiene cuatro métodos, y el detalle crucial es la **asimetría lectura/escritura**: `OnStart` recibe un span **ReadWrite** (mutable), `OnEnd` recibe un span **ReadOnly** (inmutable).

### Pasos

1. Agregá un processor que estampe un tenant ID (extraído del context) en cada span:

    ```go
    package main

    import (
        "context"

        "go.opentelemetry.io/otel/attribute"
        sdktrace "go.opentelemetry.io/otel/sdk/trace"
    )

    type tenantKey struct{}

    type tenantProcessor struct{}

    func (tenantProcessor) OnStart(parent context.Context, s sdktrace.ReadWriteSpan) {
        if t, ok := parent.Value(tenantKey{}).(string); ok {
            s.SetAttributes(attribute.String("tenant.id", t)) // mutation allowed here
        }
    }
    func (tenantProcessor) OnEnd(s sdktrace.ReadOnlySpan)  {}
    func (tenantProcessor) Shutdown(context.Context) error { return nil }
    func (tenantProcessor) ForceFlush(context.Context) error { return nil }
    ```

2. Registralo **junto** al batch exporter. Los processors se componen en orden de registro:

    ```go
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithSpanProcessor(tenantProcessor{}),   // 1st: enrich
        sdktrace.WithBatcher(exp),                       // 2nd: export
    )
    ```

3. Pasá un tenant a través del context y ejecutá:

    ```go
    ctx := context.WithValue(context.Background(), tenantKey{}, "acme")
    doWork(ctx)
    ```

    ```console
    $ go run .
    {
      "Name": "doWork",
      "Attributes": [
        { "Key": "work.kind", "Value": { "Type": "STRING", "Value": "demo" } },
        { "Key": "tenant.id", "Value": { "Type": "STRING", "Value": "acme" } }
      ]
      ...
    }
    ```

4. **Rompelo a propósito.** Mové la llamada a `SetAttributes` dentro de `OnEnd` (donde el argumento es `ReadOnlySpan`) e intentá compilar:

    ```console
    $ go build .
    ./main.go:XX:4: s.SetAttributes undefined (type trace.ReadOnlySpan has no field or method SetAttributes)
    ```

    El sistema de tipos impone *cuándo* es legal mutar — un span solo es escribible mientras está vivo.

### Comprobá lo que entendiste

- **2a.** ¿Por qué el enriquecimiento del span debe ocurrir en `OnStart` y no en `OnEnd`? ¿Qué cambio real demostró el paso 4?
- **2b.** Registrás `tenantProcessor{}` **después** de `WithBatcher(exp)` en lugar de antes. ¿El exporter sigue viendo `tenant.id`? Explicá en términos de qué callback se ejecuta y cuándo.
- **2c.** Nombrá una tarea que genuinamente corresponde a `OnEnd` y no a `OnStart`.

---

## Ejercicio 3 — Componer samplers con `ParentBased`

El sampling es un punto de extensión *y* un punto de composición. `Sampler` tiene dos métodos (`ShouldSample`, `Description`), y el sampler `ParentBased` incorporado es en sí mismo un **compuesto** que delega según la decisión del padre. Vos escribís un sampler "raíz"; `ParentBased` decide cuándo consultarlo.

### Pasos

1. Escribí un sampler que conserve solo un conjunto de operaciones raíz críticas para el negocio:

    ```go
    package main

    import (
        sdktrace "go.opentelemetry.io/otel/sdk/trace"
        "go.opentelemetry.io/otel/trace"
    )

    type criticalOps struct{ names map[string]struct{} }

    func (c criticalOps) ShouldSample(p sdktrace.SamplingParameters) sdktrace.SamplingResult {
        psc := trace.SpanContextFromContext(p.ParentContext)
        decision := sdktrace.Drop
        if _, ok := c.names[p.Name]; ok {
            decision = sdktrace.RecordAndSample
        }
        return sdktrace.SamplingResult{
            Decision:   decision,
            Tracestate: psc.TraceState(), // propagate upstream tracestate unchanged
        }
    }
    func (criticalOps) Description() string { return "CriticalOps" }
    ```

2. **Componelo** con `ParentBased` para que los hijos aguas abajo respeten la decisión de la raíz en lugar de volver a samplear:

    ```go
    root := criticalOps{names: map[string]struct{}{"checkout": {}, "payment": {}}}

    sampler := sdktrace.ParentBased(
        root,
        sdktrace.WithRemoteParentSampled(sdktrace.AlwaysSample()),
        sdktrace.WithRemoteParentNotSampled(sdktrace.NeverSample()),
    )

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithSampler(sampler),
        sdktrace.WithBatcher(exp),
    )
    ```

3. Emití un span raíz llamado `login` (no crítico) y otro llamado `checkout` (crítico):

    ```console
    $ go run .            # login: Drop → nothing exported
    $ go run .            # checkout: RecordAndSample → span exported
    {
      "Name": "checkout",
      "SpanContext": { "TraceFlags": "01" }   # sampled bit set
      ...
    }
    ```

4. Ahora compará contra el equivalente por **variable de entorno** — la spec del SDK también define una gramática de samplers componible:

    ```console
    $ export OTEL_TRACES_SAMPLER=parentbased_traceidratio
    $ export OTEL_TRACES_SAMPLER_ARG=0.25
    ```

    `parentbased_*` es la misma composición de `ParentBased`, declarada mediante configuración en lugar de código.

### Comprobá lo que entendiste

- **3a.** Un servicio remoto ya decidió que un trace está sampleado (flag `traceparent` = `01`) y llama a tu servicio. Con la configuración de `ParentBased` del paso 2, ¿tu sampler raíz `criticalOps` siquiera se ejecuta para el span hijo? ¿Por qué es ese el comportamiento deseado en un trace distribuido?
- **3b.** ¿Por qué `ShouldSample` devuelve el `Tracestate` del padre en el resultado en lugar de uno vacío?
- **3c.** Si hubieras usado el sampler `criticalOps` pelado como sampler *global* (sin `ParentBased`), ¿qué inconsistencia podría aparecer dentro de un mismo trace distribuido?

---

## Ejercicio 4 — Propagators compuestos: interoperar entre servicios

La propagación de context es enchufable y **componible por diseño**: el propagator global suele ser un *compuesto* que inyecta/extrae varios formatos a la vez. Los propagators que no coinciden entre dos servicios son la causa clásica de los "traces rotos" — spans que nunca se unen en un mismo trace.

### Pasos

1. Configurá un compuesto de W3C Trace Context **y** Baggage:

    ```go
    import "go.opentelemetry.io/otel/propagation"

    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, // traceparent / tracestate headers
        propagation.Baggage{},      // baggage header
    ))
    ```

2. Confirmá los headers inyectados en un carrier de request saliente:

    ```go
    carrier := propagation.MapCarrier{}
    otel.GetTextMapPropagator().Inject(ctx, carrier)
    fmt.Println(carrier) // map[baggage:... traceparent:00-<trace>-<span>-01 ...]
    ```

3. Hacé que el propagator sea **controlado por configuración** en lugar de estar hardcodeado, usando el helper de autoconfig de contrib que lee `OTEL_PROPAGATORS`:

    ```go
    import "go.opentelemetry.io/contrib/propagators/autoprop"

    otel.SetTextMapPropagator(autoprop.NewTextMapPropagator())
    ```

    ```console
    $ export OTEL_PROPAGATORS=tracecontext,baggage,b3
    $ go run .
    # traceparent + baggage + X-B3-* all injected
    ```

4. **Reproducí un trace roto.** Configurá el servicio A con `OTEL_PROPAGATORS=b3` y el servicio B con `OTEL_PROPAGATORS=tracecontext`. Observá que B no extrae ningún padre de los headers `X-B3-*` de A y arranca un trace raíz completamente nuevo.

### Comprobá lo que entendiste

- **4a.** En el paso 4, ¿por qué B crea un trace raíz nuevo aunque A envió headers B3 perfectamente válidos?
- **4b.** ¿Qué te da agregar `propagation.Baggage{}` que `TraceContext{}` por sí solo no da?
- **4c.** ¿Por qué un propagator *compuesto* (en lugar de un único formato) es el valor por defecto seguro cuando no controlás todos los servicios de la malla?

---

## Ejercicio 5 — Componer y extender el Collector (pipelines, connectors, OCB)

El Collector es la componibilidad hecha física: un pipeline es `receivers → processors → exporters`, y los **connectors** puentean la salida de un pipeline hacia la entrada de otro pipeline a través de distintos tipos de señal. El **OpenTelemetry Collector Builder (OCB)** extiende esto al binario en sí — componés una distribución personalizada con exactamente los módulos que necesitás.

### Pasos

1. Escribí una config que use el **connector** `spanmetrics` para derivar métricas a partir de traces — un componente que actúa como *exporter* en el pipeline de traces y como *receiver* en el pipeline de metrics:

    ```yaml
    # config.yaml
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }

    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 512
      batch: {}

    connectors:
      spanmetrics: {}

    exporters:
      otlp/traces:
        endpoint: tempo:4317
        tls: { insecure: true }
      prometheus:
        endpoint: 0.0.0.0:8889

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [memory_limiter, batch]
          exporters:  [otlp/traces, spanmetrics]   # connector as exporter
        metrics/spanmetrics:
          receivers:  [spanmetrics]                # same connector as receiver
          processors: [batch]
          exporters:  [prometheus]
    ```

2. Validá la composición sin arrancar tráfico:

    ```console
    $ otelcol-contrib validate --config config.yaml
    # (no output, exit 0 == valid)
    ```

3. Ahora **extendé el binario en sí**. Escribí un manifiesto de OCB que incluya solo los componentes que usás:

    ```yaml
    # builder-config.yaml
    dist:
      name: otelcol-otca
      description: Minimal custom OTCA distribution
      output_path: ./_build
      otelcol_version: 0.116.0

    receivers:
      - gomod: go.opentelemetry.io/collector/receiver/otlpreceiver v0.116.0
    processors:
      - gomod: go.opentelemetry.io/collector/processor/batchprocessor v0.116.0
    exporters:
      - gomod: go.opentelemetry.io/collector/exporter/debugexporter v0.116.0
    connectors:
      - gomod: go.opentelemetry.io/collector/connector/forwardconnector v0.116.0
    ```

4. Construí e inspeccioná el resultado:

    ```console
    $ builder --config builder-config.yaml
    ...
    2026-... info  Compiling
    2026-... info  Compiled  {"binary": "./_build/otelcol-otca"}

    $ ./_build/otelcol-otca components
    # lists ONLY otlp, batch, debug, forward — nothing else is in the binary
    ```

### Comprobá lo que entendiste

- **5a.** ¿Qué hace que un *connector* sea fundamentalmente distinto de un processor o un exporter? ¿Qué demostró el ejemplo de `spanmetrics` que un processor no podría?
- **5b.** El pipeline de traces lista `[memory_limiter, batch]` en ese orden. ¿Por qué `memory_limiter` va primero, y cambiaría el comportamiento reordenarlos bajo presión de memoria?
- **5c.** Dá dos razones operativas (más allá del tamaño del binario) para construir una distribución personalizada recortada con OCB en lugar de enviar `otelcol-contrib`.
- **5d.** Tanto la cadena de `SpanProcessor` del SDK del Ejercicio 2 como el pipeline del Collector acá son "componer componentes pequeños en orden". Enunciá la diferencia clave en *dónde* se ejecuta cada uno y *qué* puede hacer cada uno en consecuencia.

---

## Respuestas

<details>
<summary><strong>Mostrar respuestas (Ejercicios 1–5)</strong></summary>

### Ejercicio 1 — La frontera API/SDK
- **1a.** El `TracerProvider` global es por defecto el **no-op provider**. `Tracer`, `Start`, `End` y `SetAttributes` son todas llamadas válidas de la API que se resuelven a implementaciones no-op: devuelven un span que no graba (`IsRecording()==false`), un `SpanID` todo ceros, y no emiten nada. El éxito de la llamada no dice nada sobre grabar — grabar es tarea del SDK, y no se registró ningún SDK.
- **1b.** Porque la separación API/SDK es lo que hace que la librería sea **portable**. Una librería que importe `sdk/trace` o llame a `SetTracerProvider` impondría *su* elección de processors/exporters/sampler a toda aplicación que la use, y podría pisar el propio provider global de la aplicación. Las librerías dependen solo de la API; **la aplicación** es dueña del cableado del SDK, exactamente una vez, en el arranque.
- **1c.** Instrumentación de costo cero cuando está deshabilitada. Las librerías pueden instrumentarse con generosidad; si la app que las consume no instala ningún SDK (o todavía no lo hizo), el overhead son unas pocas llamadas no-op y un guard barato de `IsRecording()`, así que enviar instrumentación es seguro por defecto.

### Ejercicio 2 — SpanProcessor personalizado
- **2a.** Un span solo puede mutarse mientras está **vivo**. `OnStart` te entrega un `ReadWriteSpan`; para cuando llega `OnEnd` el span está terminado y es inmutable (`ReadOnlySpan`), porque puede que ya esté encolado/serializado para exportar. El paso 4 lo demostró a *nivel de tipos*: `ReadOnlySpan` no tiene `SetAttributes`, así que el compilador rechaza la mutación tardía — el invariante se impone, no solo se documenta.
- **2b.** Sí. El orden de registro controla la secuencia de callbacks `OnStart`/`OnEnd`, **pero el exporter lee el span en `OnEnd`**, que se ejecuta después de toda la vida del span. Como `tenant.id` se seteó en `OnStart` (durante la vida del span), está presente en el span terminado sin importar si `tenantProcessor` se registró antes o después del batcher. El orden importa cuando los efectos secundarios de dos processors dependen entre sí, no para este caso de enriquecer-y-luego-exportar.
- **2c.** Cualquier cosa que necesite el span *completado*: exportarlo/agruparlo en lote, computar métricas basadas en duración, registrar el estado final, o tomar una decisión de sampling/tail sobre el span terminado. Estas leen el estado final y deben ejecutarse en `OnEnd`.

### Ejercicio 3 — Composición de samplers
- **3a.** No — tu sampler raíz `criticalOps` **no** se ejecuta para ese hijo. `ParentBased` ve un padre *remoto y sampleado* y aplica `WithRemoteParentSampled(AlwaysSample())`, así que el hijo se samplea para coincidir con el padre. Esto es deseable porque las decisiones de sampling deben ser **consistentes en todo un trace distribuido**: si la raíz se conservó, descartar un hijo aguas abajo produciría un trace roto y parcial.
- **3b.** Para preservar `tracestate`, el estado específico de proveedor de W3C que viaja con el trace (p. ej. metadata de sampling de otros sistemas). Devolver un `Tracestate` vacío descartaría silenciosamente el estado aguas arriba; un sampler que se comporta bien pasa el `tracestate` del padre sin tocarlo salvo que deliberadamente agregue una entrada.
- **3c.** Cada span se samplearía **de forma independiente** por nombre, ignorando la decisión del padre. Un mismo trace podría entonces tener una raíz conservada y spans intermedios descartados (o viceversa), produciendo traces huérfanos/parciales. `ParentBased` existe precisamente para que la decisión de la raíz sea autoritativa para el resto del trace.

### Ejercicio 4 — Propagators compuestos
- **4a.** El propagator de B es `tracecontext`, que solo lee `traceparent`/`tracestate`. A envió el context como `X-B3-*` (formato B3). B nunca mira esos headers, no extrae ningún `SpanContext` y, por lo tanto, arranca un **trace raíz nuevo**. La propagación solo funciona cuando el inyector y el extractor coinciden en el formato de cable.
- **4b.** `Baggage{}` propaga el header `baggage` de W3C — pares clave/valor arbitrarios a nivel de aplicación (tenant, clase de request, feature flags) que viajan junto con el request y pueden ser leídos por cualquier servicio aguas abajo o adjuntados a spans. `TraceContext{}` solo lleva los IDs de trace/span y los flags; no mueve datos de usuario.
- **4c.** Un compuesto inyecta/extrae **múltiples formatos simultáneamente**, así un servicio puede *entender* cualquier formato que haya enviado un upstream (p. ej. aceptar tanto `tracecontext` como `b3` durante una migración) y emitir el formato que necesitan sus downstreams. En una malla heterogénea donde no controlás cada salto, esto maximiza la probabilidad de que el context sobreviva a través de las fronteras.

### Ejercicio 5 — Componibilidad del Collector
- **5a.** Un **connector** es simultáneamente un exporter para un pipeline y un receiver para otro — *une* pipelines, y puede cruzar tipos de señal (traces → metrics). Un processor solo transforma datos *dentro* de un pipeline y no puede emitir hacia un pipeline distinto o una señal distinta. `spanmetrics` produjo un flujo de **metrics** a partir de datos de **traces**, algo que ningún processor o exporter por sí solo puede hacer.
- **5b.** `memory_limiter` debe ejecutarse **primero** para poder rechazar/aplicar backpressure a los datos entrantes antes de que el processor `batch` los acumule en memoria. Si `batch` corriera primero, los lotes ya estarían buffereados antes de que el limiter tuviera la chance de proteger el proceso — bajo presión de memoria el reordenamiento anularía el guard y arriesgaría un OOM. El orden en un pipeline del Collector es significativo.
- **5c.** Dos cualesquiera de: (1) **Menor superficie de ataque/CVE** — menos módulos significa menos dependencias que parchear y auditar. (2) **Control de cadena de suministro / cumplimiento** — fijás exactamente qué componentes (y versiones) se envían, nada inesperado. (3) **Arranque más rápido y menor memoria** al no cargar componentes que no se usan. (4) **Capacidad de incluir componentes privados/internos** que no están presentes en `-contrib`.
- **5d.** Ambos son cadenas ordenadas de componentes pequeños y componibles, pero se ejecutan en **lugares distintos con distinto alcance**. El `SpanProcessor` del SDK se ejecuta **en el proceso de la aplicación**, así que ve un context en-proceso rico (valores del context del request, `ReadWriteSpan` vivo, memoria de la app) pero solo la telemetría de esa única app. El pipeline del Collector se ejecuta **fuera de proceso** como infraestructura compartida: ve telemetría de *muchos* servicios y señales y puede hacer trabajo transversal (tail sampling, connectors entre señales, fan-out hacia múltiples backends), pero no tiene acceso al context en-proceso de la aplicación de origen.

</details>