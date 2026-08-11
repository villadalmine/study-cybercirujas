# OTCA · Tema 2.3 — Configuración (Ejercicios Guiados)

> Dominio 2 · *La API y el SDK de OpenTelemetry* — Configuración (peso en el examen ≈ 6.57%)
>
> Estos laboratorios ejercitan la competencia que el examen evalúa con más dureza aquí: **cómo se configura el mismo SDK de tres maneras distintas — variables de entorno, programática (en código) y configuración declarativa por archivo — y cómo esas capas se sobrescriben entre sí.** Vas a ejecutar un servicio real instrumentado y observar cómo cada perilla cambia la telemetría emitida.
>
> **Prerrequisitos**
> - Python 3.9+ y `pip`
> - Docker (para ejecutar un Collector descartable como sumidero)
> - Una shell donde puedas hacer `export` de variables
>
> **Configuración inicial (una sola vez)** — una app mínima más un Collector que simplemente imprime lo que recibe, para que puedas *ver* el efecto de cada cambio de configuración.

```bash
mkdir otca-23-config && cd otca-23-config
python3 -m venv .venv && source .venv/bin/activate

pip install \
  opentelemetry-distro \
  opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
```

```python
# app.py
from flask import Flask
from opentelemetry import trace

app = Flask(__name__)
tracer = trace.get_tracer("dice.tracer")

@app.route("/rolldice")
def roll():
    with tracer.start_as_current_span("do_roll") as span:
        span.set_attribute("dice.result", 4)
        return "4"

if __name__ == "__main__":
    app.run(port=8080)
```

```yaml
# collector-config.yaml  — a sink that logs everything it receives
receivers:
  otlp:
    protocols:
      grpc:  { endpoint: 0.0.0.0:4317 }
      http:  { endpoint: 0.0.0.0:4318 }
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers:  [otlp]
      exporters:  [debug]
```

```bash
docker run --rm --name otelcol -p 4317:4317 -p 4318:4318 \
  -v "$(pwd)/collector-config.yaml:/etc/otelcol-contrib/config.yaml" \
  otel/opentelemetry-collector-contrib:0.104.0
```

Dejá el Collector corriendo en una terminal. Hacé los ejercicios en una segunda terminal (con el venv activado).

*Fuente: [SDK configuration](https://opentelemetry.io/docs/languages/sdk-configuration/), [Zero-code Python](https://opentelemetry.io/docs/zero-code/python/).*

---

## Ejercicio 1 — Configuración zero-code mediante variables de entorno

La afirmación central del examen: **podés configurar por completo el resource, el exporter y el protocolo sin tocar código.** El wrapper `opentelemetry-instrument` lee las variables estándar `OTEL_*` y construye los providers por vos.

1. Configurá el SDK enteramente a través del entorno y lanzá la app auto-instrumentada:

   ```bash
   export OTEL_SERVICE_NAME="dice-server"
   export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=staging,service.version=1.4.2,team=payments"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
   export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
   export OTEL_TRACES_EXPORTER="otlp"

   opentelemetry-instrument python app.py
   ```

2. En una tercera terminal, generá un trace:

   ```bash
   curl -s http://localhost:8080/rolldice
   ```

3. Observá la terminal del **Collector**. Deberías ver un bloque `Resource` y dos spans (`GET /rolldice` de la auto-instrumentación, `do_roll` de tu código):

   ```text
   Resource attributes:
        -> service.name: Str(dice-server)
        -> service.version: Str(1.4.2)
        -> deployment.environment: Str(staging)
        -> team: Str(payments)
        -> telemetry.sdk.language: Str(python)
        -> telemetry.sdk.name: Str(opentelemetry)
   ScopeSpans #0
   Span #0
       Name           : GET /rolldice
       Kind           : Server
   Span #1
       Name           : do_roll
       Kind           : Internal
   ```

**Verificá tu comprensión**

- **Q1.1** — `OTEL_SERVICE_NAME` y `OTEL_RESOURCE_ATTRIBUTES` alimentan ambos el Resource. Si definís `OTEL_SERVICE_NAME=dice-server` *y* `OTEL_RESOURCE_ATTRIBUTES=service.name=other`, ¿qué valor gana para `service.name`, y por qué?
- **Q1.2** — Definís `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` y `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`. ¿A qué URL completa hará el SDK realmente el POST de los spans, y de dónde viene el path extra?
- **Q1.3** — Nada en `app.py` menciona un Resource, un exporter ni un processor. ¿Qué componente creó todos ellos, y en qué punto del ciclo de vida del proceso?

---

## Ejercicio 2 — Precedencia de protocolo y endpoint (la clásica trampa gRPC-vs-HTTP)

El detalle de configuración que más se falla en el examen es **cómo difiere el endpoint general del endpoint por-señal** bajo cada protocolo.

1. Cambiá a gRPC. Notá el cambio de puerto y que gRPC no necesita **ningún path**:

   ```bash
   export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   Los spans siguen llegando al Collector — esta vez por su receiver gRPC en el `4317`.

2. Ahora definí un endpoint **específico de señal** sobre HTTP. Cometé el error a propósito primero — apuntalo al host base sin *ningún* path:

   ```bash
   kill %1 2>/dev/null
   export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
   unset OTEL_EXPORTER_OTLP_ENDPOINT
   export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://localhost:4318"   # missing /v1/traces
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   El Collector registra un `404` por el path mal formado (espera `/v1/traces`). Corregilo suministrando el path **completo**, porque el SDK *no* agrega un sufijo a un endpoint específico de señal:

   ```bash
   kill %1 2>/dev/null
   export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://localhost:4318/v1/traces"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

**Verificá tu comprensión**

- **Q2.1** — Con `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, ¿por qué el SDK agrega `/v1/traces` al valor del `OTEL_EXPORTER_OTLP_ENDPOINT` **general** pero *no* al `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` **por-señal**?
- **Q2.2** — Para gRPC, ¿cuáles son el puerto por defecto y el path por defecto? ¿Por qué no hay ningún path por-señal?
- **Q2.3** — Si están definidos tanto `OTEL_EXPORTER_OTLP_ENDPOINT` como `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, ¿cuál gobierna la exportación de traces?

---

## Ejercicio 3 — Configuración de sampling (head sampling)

El sampling es una cuestión de configuración que cambia *cuánto* emitís. Lo configurás con exactamente dos variables.

1. Definí un ratio de 0% para probar que el sampler está conectado — ningún span debería llegar al Collector:

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_SAMPLER="parentbased_traceidratio"
   export OTEL_TRACES_SAMPLER_ARG="0.0"
   opentelemetry-instrument python app.py &
   for i in $(seq 1 10); do curl -s http://localhost:8080/rolldice > /dev/null; done
   ```

   La terminal del Collector permanece en silencio: 0 de 10 requests son registrados.

2. Subí a 50% y volvé a ejecutar 10 requests. Aproximadamente la mitad de los traces aparecen ahora (el conteo es probabilístico, basado en el `trace_id`):

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_SAMPLER_ARG="0.5"
   opentelemetry-instrument python app.py &
   for i in $(seq 1 10); do curl -s http://localhost:8080/rolldice > /dev/null; done
   ```

3. Confirmá el valor por defecto. Hacé `unset` de ambas variables, reiniciá, y notá que **todos** los traces se exportan:

   ```bash
   kill %1 2>/dev/null
   unset OTEL_TRACES_SAMPLER OTEL_TRACES_SAMPLER_ARG
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

**Verificá tu comprensión**

- **Q3.1** — ¿Cuál es el sampler por defecto cuando `OTEL_TRACES_SAMPLER` no está definido, y qué implica su nombre sobre cómo trata un span entrante que ya trae una decisión de sampling?
- **Q3.2** — Con `parentbased_traceidratio` y arg `0.5`, llega un request que trae un `traceparent` W3C cuyo flag de sampled es `01`. ¿Se muestrea el span local? ¿Y si el flag fuera `00`?
- **Q3.3** — ¿Por qué `traceidratio` es determinista — es decir, por qué reproducir el *mismo* trace ID siempre da el mismo resultado de muestreado/descartado en cada servicio del camino del request?

---

## Ejercicio 4 — Ajuste del Batch Span Processor

El processor se ubica entre el SDK y el exporter y decide *cuándo* hacer el flush. Sus valores por defecto están afinados para throughput, no para latencia; el examen espera que conozcas las cuatro perillas.

1. Forzá una exportación casi inmediata reduciendo el batch y el schedule delay, luego observá cómo los spans llegan casi al instante:

   ```bash
   kill %1 2>/dev/null
   export OTEL_BSP_SCHEDULE_DELAY="200"          # ms between flushes (default 5000)
   export OTEL_BSP_MAX_EXPORT_BATCH_SIZE="1"     # export as soon as 1 span is queued (default 512)
   export OTEL_BSP_MAX_QUEUE_SIZE="2048"         # drop threshold (default 2048)
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

2. Volvé a los valores por defecto y observá la pausa de ~5 s antes de que aparezca un trace de un solo request (el schedule delay domina cuando el batch nunca se llena):

   ```bash
   kill %1 2>/dev/null
   unset OTEL_BSP_SCHEDULE_DELAY OTEL_BSP_MAX_EXPORT_BATCH_SIZE OTEL_BSP_MAX_QUEUE_SIZE
   opentelemetry-instrument python app.py &
   time curl -s http://localhost:8080/rolldice   # response is instant; the *export* waits for the schedule delay
   ```

**Verificá tu comprensión**

- **Q4.1** — Nombrá las dos condiciones que disparan el flush del Batch Span Processor, y dá el valor por defecto de cada una.
- **Q4.2** — `OTEL_BSP_MAX_QUEUE_SIZE` es 2048 por defecto. ¿Qué le pasa a un span que se crea cuando la cola ya está llena, y en qué se diferencia eso del `SimpleSpanProcessor`?
- **Q4.3** — Tu servicio exporta bien con carga liviana pero pierde spans silenciosamente durante picos de tráfico. ¿Qué dos variables del BSP cambiarías primero, y en qué dirección?

---

## Ejercicio 5 — Configuración de propagadores

Los propagadores se configuran por separado de los exporters; deciden el *formato de cable* del contexto que se pasa entre servicios.

1. Restringí la app a la propagación B3 multi-header y confirmá que *lee* los headers B3 que le inyectás. Iniciá la app, luego enviá un request que lleva un contexto B3 pre-armado:

   ```bash
   kill %1 2>/dev/null
   export OTEL_PROPAGATORS="b3multi"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice \
     -H "X-B3-TraceId: 80f198ee56343ba864fe8b2a57d3eff7" \
     -H "X-B3-SpanId: e457b5a2e4d86bd1" \
     -H "X-B3-Sampled: 1"
   ```

   En la salida del Collector, el `Trace ID` del server span es `80f198ee56343ba864fe8b2a57d3eff7` — el contexto entrante fue respetado.

2. Enviá el *mismo* request pero con un `traceparent` W3C en su lugar. Como deshabilitaste `tracecontext`, es **ignorado** y comienza un nuevo trace:

   ```bash
   curl -s http://localhost:8080/rolldice \
     -H "traceparent: 00-11111111111111111111111111111111-2222222222222222-01"
   ```

3. Restaurá el default interoperable y verificá que `traceparent` vuelve a ser respetado:

   ```bash
   kill %1 2>/dev/null
   export OTEL_PROPAGATORS="tracecontext,baggage"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice \
     -H "traceparent: 00-11111111111111111111111111111111-2222222222222222-01"
   ```

**Verificá tu comprensión**

- **Q5.1** — ¿Cuál es el valor por defecto de `OTEL_PROPAGATORS`, y qué transporta cada una de sus dos entradas?
- **Q5.2** — En el paso 2, ¿por qué el `traceparent` entrante produjo un trace *nuevo* y desconectado en lugar de un error?
- **Q5.3** — Dos servicios en el mismo camino de request están configurados con `OTEL_PROPAGATORS=b3multi` y `OTEL_PROPAGATORS=tracecontext` respectivamente. ¿Cuál es el síntoma observable en tus traces, y es un bug de código?

---

## Ejercicio 6 — Configuración programática y precedencia

Las variables de entorno son convenientes, pero el SDK en última instancia se construye en código. Acá configurás el *mismo* pipeline en Python y observás cómo las variables de entorno todavía lo influyen.

1. Salteá el wrapper de auto-instrumentación y construí el provider vos mismo:

   ```python
   # manual_setup.py
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.sdk.trace.sampling import ParentBasedTraceIdRatio
   from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

   provider = TracerProvider(
       resource=Resource.create({"service.name": "dice-server-manual"}),
       sampler=ParentBasedTraceIdRatio(0.25),
   )
   provider.add_span_processor(
       BatchSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4318/v1/traces"))
   )
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("manual.tracer")
   with tracer.start_as_current_span("manual_roll") as span:
       span.set_attribute("dice.result", 6)
   provider.shutdown()   # flush before exit
   ```

   ```bash
   kill %1 2>/dev/null
   python manual_setup.py
   ```

   El Collector muestra `service.name: dice-server-manual` y un span `manual_roll`.

2. Ahora probá la precedencia. `Resource.create()` todavía *mergea* atributos suministrados por el entorno. Definí un atributo por entorno y volvé a ejecutar — aparece **junto** al `service.name` definido en código:

   ```bash
   export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=prod"
   python manual_setup.py
   ```

   La salida ahora lleva tanto `service.name=dice-server-manual` **como** `deployment.environment=prod`.

**Verificá tu comprensión**

- **Q6.1** — En el paso 2, el código codifica `service.name` de forma fija pero `deployment.environment` vino del entorno. ¿Qué regla de precedencia aplica `Resource.create()` cuando el Resource del código y el Resource de `OTEL_RESOURCE_ATTRIBUTES` se mergean?
- **Q6.2** — ¿Por qué es importante el `provider.shutdown()` explícito (o un `force_flush`) en un script de corta vida, dado lo que aprendiste sobre el Batch Span Processor en el Ejercicio 4?
- **Q6.3** — Llamás a `trace.set_tracer_provider(provider)` dos veces con dos providers distintos. ¿Qué hace el SDK en la segunda llamada, y por qué importa para librerías que tomaron un tracer temprano?

---

## Ejercicio 7 — Configuración declarativa (basada en archivo)

La superficie de configuración más nueva y relevante para el examen es un **único archivo YAML** que describe todo el SDK, referenciado por `OTEL_EXPERIMENTAL_CONFIG_FILE`. Reemplaza las variables de entorno individuales y soporta sustitución `${ENV}`.

1. Escribí una config declarativa que reproduzca el pipeline de los ejercicios anteriores — resource, batch OTLP exporter y un sampler parent-based del 25%:

   ```yaml
   # sdk-config.yaml
   file_format: "0.3"
   disabled: false
   resource:
     attributes:
       - name: service.name
         value: dice-server-declarative
       - name: deployment.environment
         value: ${DEPLOY_ENV}          # substituted from the environment at load time
   propagator:
     composite: [tracecontext, baggage]
   tracer_provider:
     sampler:
       parent_based:
         root:
           trace_id_ratio_based:
             ratio: 0.25
     processors:
       - batch:
           exporter:
             otlp:
               protocol: http/protobuf
               endpoint: http://localhost:4318
   ```

2. Apuntá el SDK al archivo y ejecutá. Notá que el `OTEL_SERVICE_NAME` que exportaste antes ahora es **ignorado** — el archivo es autoritativo:

   ```bash
   kill %1 2>/dev/null
   export DEPLOY_ENV="prod"
   export OTEL_SERVICE_NAME="this-value-is-ignored"
   export OTEL_EXPERIMENTAL_CONFIG_FILE="$(pwd)/sdk-config.yaml"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   El Collector muestra `service.name: dice-server-declarative` y `deployment.environment: prod` — el archivo ganó; solo la referencia `${DEPLOY_ENV}` alcanzó el entorno.

3. Activá el kill-switch global sin borrar el archivo, y confirmá que el SDK no emite nada:

   ```bash
   kill %1 2>/dev/null
   sed -i 's/disabled: false/disabled: true/' sdk-config.yaml
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice        # no spans reach the Collector
   ```

**Verificá tu comprensión**

- **Q7.1** — Con `OTEL_EXPERIMENTAL_CONFIG_FILE` definido, ¿qué pasa con variables sueltas como `OTEL_SERVICE_NAME`, `OTEL_TRACES_SAMPLER` o `OTEL_EXPORTER_OTLP_ENDPOINT`? ¿Qué mecanismo de variable de entorno *sí* sigue funcionando?
- **Q7.2** — Contrastá `disabled: true` en el archivo con la variable `OTEL_SDK_DISABLED=true`. ¿Qué tienen en común y en qué difieren en alcance?
- **Q7.3** — ¿Por qué existe el campo de nivel superior `file_format`, y qué debería hacer una herramienta si no reconoce la versión?

---

## Ejercicio 8 — Diagnóstico de una mala configuración

Los bugs de configuración suelen ser silenciosos — sin telemetría, sin error. Este es el ejercicio de diagnóstico que la mentalidad de "Mantenimiento y Depuración" del examen premia.

1. Introducí una falla realista: un exporter apuntado a un puerto muerto.

   ```bash
   kill %1 2>/dev/null
   unset OTEL_EXPERIMENTAL_CONFIG_FILE
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4999"   # nothing listening here
   export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

   La app responde `4` normalmente — la falla de telemetría es invisible desde afuera.

2. Activá los diagnósticos propios del SDK y volvé a ejecutar. Python expone los errores del exporter en el logger interno:

   ```bash
   kill %1 2>/dev/null
   export OTEL_LOG_LEVEL="debug"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   # In the app terminal you now see, e.g.:
   #   Transient error ConnectionError ... Failed to export ... to http://localhost:4999/v1/traces
   ```

3. Probá tu pipeline en aislamiento cambiando el exporter de red por el exporter de **consola** — esto elimina la red de la ecuación por completo:

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_EXPORTER="console"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   # Spans are now printed as JSON to stdout — the SDK, resource, and sampler are all fine;
   # the only thing broken was the endpoint.
   ```

4. Arreglá el endpoint y restaurá OTLP:

   ```bash
   kill %1 2>/dev/null
   export OTEL_TRACES_EXPORTER="otlp"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
   opentelemetry-instrument python app.py &
   curl -s http://localhost:8080/rolldice
   ```

**Verificá tu comprensión**

- **Q8.1** — ¿Por qué un endpoint de exporter roto *no* rompe las respuestas propias de la aplicación instrumentada? ¿Qué te dice eso sobre dónde corre la exportación de telemetría?
- **Q8.2** — Dá una receta ordenada de troubleshooting (qué variable / qué exporter) para distinguir "el SDK no está produciendo spans" de "el SDK produce spans pero no puede enviarlos".
- **Q8.3** — Un colega reporta *cero* telemetría y ningún log de error en absoluto, incluso con `OTEL_LOG_LEVEL=debug`. ¿Qué única variable de entorno chequearías primero, y por qué explicaría el silencio total?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

- **A1.1** — Gana `OTEL_SERVICE_NAME`. La spec le da a `OTEL_SERVICE_NAME` **mayor prioridad** que a un `service.name` suministrado dentro de `OTEL_RESOURCE_ATTRIBUTES`; la variable dedicada se trata como autoritativa para esa clave.
- **A1.2** — `http://localhost:4318/v1/traces`. Bajo `http/protobuf`, el SDK trata a `OTEL_EXPORTER_OTLP_ENDPOINT` como una URL *base* y agrega el path por-señal (`/v1/traces` para spans, `/v1/metrics`, `/v1/logs`).
- **A1.3** — El agente de auto-instrumentación `opentelemetry-instrument`. Al arranque (antes de que el `main`/imports de tu app corran del todo) lee las variables `OTEL_*`, construye el `TracerProvider`, el `Resource`, el `BatchSpanProcessor` y el exporter OTLP, y los registra como globales — todo sin cambios de código.

**Ejercicio 2**

- **A2.1** — El endpoint general está definido como una *base* a la que el SDK agrega el path de señal; el endpoint por-señal está definido como la URL *completa* y se usa tal cual. Así `OTEL_EXPORTER_OTLP_ENDPOINT=http://host:4318` se convierte en `…/v1/traces`, pero `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` ya debe contener `/v1/traces`.
- **A2.2** — El puerto gRPC por defecto es **4317**, y **no hay path** — el método del servicio OTLP/gRPC (`Export`) identifica la señal, así que no se agrega nada ni para la forma general ni para la por-señal.
- **A2.3** — El **específico de señal** (`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) tiene precedencia sobre el `OTEL_EXPORTER_OTLP_ENDPOINT` general para los traces.

**Ejercicio 3**

- **A3.1** — El default es `parentbased_always_on`. "Parent-based" significa que **respeta una decisión de sampling upstream** si el span tiene un parent remoto, y solo cae a su delegado raíz (aquí `always_on`) para un span raíz sin parent — esto mantiene un trace todo-muestreado-o-todo-descartado de punta a punta.
- **A3.2** — Flag `01` (parent muestreado) → el span **sí** se muestrea, porque `parentbased_*` respeta la decisión del parent sin importar el ratio. Flag `00` (parent no muestreado) → el span se **descarta**. El ratio `0.5` solo aplica a spans *raíz* sin parent.
- **A3.3** — `traceidratio` deriva la decisión de mantener/descartar de los bits del trace ID comparados contra un umbral, no de una tirada aleatoria. Como cada servicio del camino comparte el mismo trace ID, todos computan la misma comparación de umbral y llegan a la misma decisión — sin necesidad de coordinación.

**Ejercicio 4**

- **A4.1** — Hace flush cuando **el conteo de spans encolados alcanza `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` (default 512)** *o* cuando transcurre **`OTEL_BSP_SCHEDULE_DELAY` (default 5000 ms)** desde la última exportación, lo que ocurra primero.
- **A4.2** — Una vez que la cola alcanza `OTEL_BSP_MAX_QUEUE_SIZE` (2048), los nuevos spans se **descartan** (con el batch processor emitiendo un warning/métrica interna). El `SimpleSpanProcessor` no tiene cola — exporta cada span sincrónicamente cuando termina, por eso solo se recomienda para depuración/testing.
- **A4.3** — Subir `OTEL_BSP_MAX_QUEUE_SIZE` (más margen antes de descartar) y, si el exporter es el cuello de botella, subir `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` y/o bajar `OTEL_BSP_SCHEDULE_DELAY` para que la cola se drene más rápido.

**Ejercicio 5**

- **A5.1** — El default es `tracecontext,baggage`. `tracecontext` transporta el `traceparent`/`tracestate` W3C (los IDs de span/trace activos y los flags); `baggage` transporta el header `baggage` W3C de pares clave/valor arbitrarios del usuario.
- **A5.2** — Con solo `b3multi` configurado, el propagador `tracecontext` **no fue instalado**, así que el SDK nunca parseó el header `traceparent`. Sin un contexto parent extraído, el server span se volvió un nuevo root — comportamiento legítimo, no un error.
- **A5.3** — **Traces rotos**: el servicio downstream no puede extraer el contexto del upstream (formato de header distinto), así que inicia un trace nuevo y las dos mitades del request aparecen como **dos traces desconectados**. Es una **desconfiguración**, no un bug de código — alineá `OTEL_PROPAGATORS` en todos los servicios.

**Ejercicio 6**

- **A6.1** — `Resource.create()` **mergea** el Resource del SDK/entorno con los atributos suministrados; ante una colisión de clave, los valores pasados explícitamente (código) tienen precedencia, pero las claves **no conflictivas** de `OTEL_RESOURCE_ATTRIBUTES` se preservan — por eso `deployment.environment` sobrevivió junto al `service.name` del código.
- **A6.2** — El `BatchSpanProcessor` bufferea spans y solo exporta en el schedule delay o con un batch lleno. Un script que sale de inmediato terminaría antes del flush de ~5 s, perdiendo el span. `shutdown()` (o `force_flush()`) fuerza una exportación final sincrónica.
- **A6.3** — El SDK **ignora** la segunda llamada a `set_tracer_provider` y registra un warning — el provider global solo puede definirse una vez. Cualquier librería que ya llamó a `get_tracer()` tiene una referencia atada al *primer* provider (o al default no-op si corrió antes de la configuración), por eso el provider debe instalarse lo más temprano posible.

**Ejercicio 7**

- **A7.1** — Cuando `OTEL_EXPERIMENTAL_CONFIG_FILE` está definido, el archivo es autoritativo y las variables de configuración `OTEL_*` individuales son **ignoradas**. El mecanismo que sí sigue funcionando es la **sustitución `${ENV_VAR}` dentro del archivo**, para que parametrices el archivo desde el entorno en lugar de sobrescribirlo.
- **A7.2** — Ambos son kill-switches globales que vuelven al SDK un no-op (no se producen spans/métricas/logs). `disabled: true` vive dentro del archivo declarativo (usado cuando la config por archivo está activa); `OTEL_SDK_DISABLED=true` es el equivalente en variable de entorno suelta, usado cuando se configura por variables. Mismo efecto, superficie de configuración distinta.
- **A7.3** — `file_format` declara la **versión del esquema de configuración** contra el que se escribió el archivo, para que los parsers puedan validar y evolucionar de forma compatible. Una herramienta que no reconozca la versión declarada debería **fallar ruidosamente** (negarse a cargar) en lugar de ignorar silenciosamente campos que no entiende.

**Ejercicio 8**

- **A8.1** — La exportación de telemetría corre en un **camino de fondo** (el worker del Batch Span Processor), desacoplado del manejo de requests. Una exportación fallida se captura y registra internamente; nunca se propaga al camino de código de la aplicación, así que las respuestas siguen en verde mientras la telemetría falla silenciosamente — la razón por la que las caídas de observabilidad son tan fáciles de pasar por alto.
- **A8.2** — (1) Definir `OTEL_TRACES_EXPORTER=console` — si los spans se imprimen, el SDK/resource/sampler están bien y la falla está downstream (endpoint/red). (2) Si la consola tampoco muestra nada, el problema está upstream: chequeá `OTEL_SDK_DISABLED`, el sampler (`OTEL_TRACES_SAMPLER=always_off`/ratio `0`), o que la instrumentación esté realmente cargada. (3) Con la consola probada, volvé a OTLP y activá `OTEL_LOG_LEVEL=debug` para leer el error de conexión del exporter.
- **A8.3** — `OTEL_SDK_DISABLED` (o `disabled: true` en un archivo declarativo). Cuando se define en `true` el SDK es un no-op: no se produce ningún span, así que no hay nada para exportar y por lo tanto ningún error de exporter — silencio total con un log limpio es su firma. (Un sampler con ratio `0` produce el mismo silencio para los traces y es lo segundo a chequear.)

</details>

---

*Fuentes primarias (oficiales):*
- *[OTEL SDK configuration (env vars)](https://opentelemetry.io/docs/languages/sdk-configuration/) y la [SDK environment variable spec](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/) normativa*
- *[OTLP exporter configuration](https://opentelemetry.io/docs/specs/otel/protocol/exporter/) — precedencia de endpoint/protocolo/path*
- *[Trace SDK — Sampling](https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling) y [Batch Span Processor](https://opentelemetry.io/docs/specs/otel/trace/sdk/#batching-processor)*
- *[Context propagation](https://opentelemetry.io/docs/concepts/context-propagation/) y [W3C Trace Context](https://www.w3.org/TR/trace-context/)*
- *[Declarative configuration](https://opentelemetry.io/docs/specs/otel/configuration/) y el [opentelemetry-configuration schema](https://github.com/open-telemetry/opentelemetry-configuration)*
- *[OTCA Curriculum](https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf)*