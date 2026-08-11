# Tema 1.3 — Instrumentación · Ejercicios Guiados

> **Dominio 1 — Fundamentos de la Observabilidad.** La *instrumentación* es el acto de hacer que un sistema emita telemetría (traces, métricas, logs). En OpenTelemetry ocurre por dos caminos que tenés que saber diferenciar en el examen:
>
> - **Instrumentación basada en código (manual)** — llamás a la **API** de OpenTelemetry en tu propio código fuente para crear spans, registrar métricas, establecer atributos.
> - **Instrumentación sin código (automática)** — un agente o inyector conecta la telemetría para las bibliotecas y frameworks soportados *sin editar el código fuente de la aplicación*.
>
> Una distinción de fondo que sostiene a ambas: la **API** define la superficie que llamás; el **SDK** es la implementación que efectivamente produce y exporta los datos. Con la API presente pero sin un SDK configurado, cada llamada es un **no-op**. Tené esto presente — tres de los cuatro ejercicios dependen de ello.
>
> Referencia: OpenTelemetry — concepto *Instrumentation* (https://opentelemetry.io/docs/concepts/instrumentation/), *Zero-code* (https://opentelemetry.io/docs/concepts/instrumentation/zero-code/), *Code-based* (https://opentelemetry.io/docs/concepts/instrumentation/code-based/).

Los ejercicios usan Python porque sus dos caminos de instrumentación son los más claros para correr localmente, más un ejercicio de Kubernetes con el OpenTelemetry Operator. Tené Python 3.9+ y (para el Ejercicio 4) un cluster con acceso vía `kubectl`.

---

## Ejercicio 1 — Instrumentación sin código de un servicio en ejecución

**Objetivo:** emitir traces y métricas desde una app Flask sin modificar, usando `opentelemetry-instrument`, y leer los spans exportados.

1. Creá un entorno aislado y una app web mínima y **sin instrumentar**:

   ```bash
   mkdir otca-13 && cd otca-13
   python3 -m venv .venv && source .venv/bin/activate
   pip install flask
   ```

   ```python
   # app.py  — note: NOT one line of OpenTelemetry code
   from flask import Flask
   from random import randint

   app = Flask(__name__)

   @app.route("/rolldice")
   def roll():
       return str(randint(1, 6))
   ```

2. Instalá el **distro** de OpenTelemetry (API + SDK + el lanzador de auto-instrumentación) y el exportador OTLP:

   ```bash
   pip install opentelemetry-distro opentelemetry-exporter-otlp
   ```

3. Dejá que el bootstrapper detecte las bibliotecas instaladas y traiga las **instrumentation libraries** que correspondan:

   ```bash
   opentelemetry-bootstrap -a install
   ```

   Esperado (abreviado) — descubre Flask e instala su bridge:

   ```
   ...
   Installing opentelemetry-instrumentation-flask
   Installing opentelemetry-instrumentation-requests
   Installing opentelemetry-instrumentation-dbapi
   ...
   ```

4. Corré la app **a través** del lanzador, enviando la telemetría a la consola para poder leerla:

   ```bash
   OTEL_SERVICE_NAME=dice-service \
   opentelemetry-instrument \
     --traces_exporter console \
     --metrics_exporter console \
     --logs_exporter none \
     flask run -p 8080
   ```

5. En otra terminal, generá una petición:

   ```bash
   curl http://localhost:8080/rolldice
   # -> 4
   ```

6. Mirá la terminal del lanzador. Se creó un span **SERVER** para el handler HTTP sin ningún cambio de código de tu parte (los valores son representativos):

   ```json
   {
       "name": "GET /rolldice",
       "context": {
           "trace_id": "0x9c4f1e2a7b3d5f6081a2b3c4d5e6f7a8",
           "span_id": "0x1a2b3c4d5e6f7a8b",
           "trace_state": "[]"
       },
       "kind": "SpanKind.SERVER",
       "parent_id": null,
       "start_time": "2026-08-10T14:03:11.402193Z",
       "end_time":   "2026-08-10T14:03:11.404517Z",
       "status": { "status_code": "UNSET" },
       "attributes": {
           "http.request.method": "GET",
           "url.path": "/rolldice",
           "http.response.status_code": 200,
           "server.address": "localhost",
           "server.port": 8080
       },
       "resource": {
           "attributes": {
               "service.name": "dice-service",
               "telemetry.sdk.language": "python",
               "telemetry.sdk.name": "opentelemetry"
           }
       }
   }
   ```

   > Las claves exactas de los atributos dependen de la versión de la convención semántica de la instrumentation library instalada (por ejemplo, `http.request.method` frente al más antiguo `http.method`); lo que importa acá es la *presencia* del span.

Referencia: *Python — Zero-code / Automatic* (https://opentelemetry.io/docs/zero-code/python/), *Getting Started* (https://opentelemetry.io/docs/languages/python/getting-started/).

**Verificá tu comprensión — Bloque 1**

1. No escribiste ningún código de OpenTelemetry y, sin embargo, apareció un span. ¿Qué componente lo creó realmente y cómo se cargó en el proceso?
2. ¿Cuál es la tarea de `opentelemetry-bootstrap -a install`? ¿Por qué no alcanza con solo hacer `pip install opentelemetry-distro`?
3. `OTEL_SERVICE_NAME` estableció `service.name` en el **resource**, no en el span. ¿Por qué importa esa distinción para un backend?
4. Nombrá una clase de telemetría que la instrumentación sin código por sí sola típicamente **no** capturará sin que vos agregues código.

---

## Ejercicio 2 — Instrumentación basada en código: tus propios spans

**Objetivo:** producir un span desde el código de la aplicación y demostrar que falla en silencio sin un SDK.

1. En el mismo venv, escribí un script que use **solo la API** — sin configuración del SDK:

   ```python
   # manual_noop.py
   from opentelemetry import trace

   tracer = trace.get_tracer("dice.tracer")

   with tracer.start_as_current_span("roll-dice") as span:
       span.set_attribute("dice.count", 3)
       print("span type:", type(span).__name__)
   ```

   ```bash
   python manual_noop.py
   ```

   Esperado:

   ```
   span type: NonRecordingSpan
   ```

   No se exporta nada. La API devolvió un **no-op** porque no se registró ningún `TracerProvider` del SDK.

2. Ahora conectá el **SDK** explícitamente y creá el mismo span:

   ```python
   # manual.py
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       BatchSpanProcessor,
       ConsoleSpanExporter,
   )
   from opentelemetry.trace import Status, StatusCode

   # 1) Resource: who is emitting this telemetry
   resource = Resource.create({"service.name": "dice-service"})

   # 2) Provider + processor + exporter pipeline
   provider = TracerProvider(resource=resource)
   provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # 3) Acquire a tracer from the *global* provider
   tracer = trace.get_tracer("dice.tracer")

   def roll(count):
       # parent span
       with tracer.start_as_current_span("roll-dice") as parent:
           parent.set_attribute("dice.count", count)
           results = []
           for i in range(count):
               # child span, nested by "current span" context
               with tracer.start_as_current_span("roll-one") as child:
                   value = (i * 7 + 3) % 6 + 1   # deterministic for the demo
                   child.set_attribute("dice.value", value)
                   child.add_event("die rolled", {"index": i})
                   results.append(value)
           if sum(results) == 0:
               parent.set_status(Status(StatusCode.ERROR, "impossible roll"))
           return results

   print(roll(2))
   provider.shutdown()   # flush the BatchSpanProcessor before exit
   ```

   ```bash
   python manual.py
   ```

   Esperado — dos spans, el hijo cargando tu **evento**, el padre con `parent_id: null` y el hijo apuntando de vuelta a él (representativo):

   ```json
   {
       "name": "roll-one",
       "context": { "trace_id": "0x7f...", "span_id": "0xaa..." },
       "kind": "SpanKind.INTERNAL",
       "parent_id": "0xbb...",
       "attributes": { "dice.value": 3 },
       "events": [
           { "name": "die rolled", "attributes": { "index": 0 } }
       ]
   }
   {
       "name": "roll-dice",
       "context": { "trace_id": "0x7f...", "span_id": "0xbb..." },
       "kind": "SpanKind.INTERNAL",
       "parent_id": null,
       "attributes": { "dice.count": 2 }
   }
   ```

   Fijate en el **`trace_id` compartido** y en que `roll-one.parent_id` es igual a `roll-dice.span_id` — el anidamiento salió gratis de `start_as_current_span`, que estableció al hijo como el span *actual* dentro del bloque `with`.

Referencia: *Python — Instrumentation / Manual* (https://opentelemetry.io/docs/languages/python/instrumentation/), Span/Status API en el glosario de la spec (https://opentelemetry.io/docs/specs/otel/glossary/).

**Verificá tu comprensión — Bloque 2**

1. En `manual_noop.py` el tipo era `NonRecordingSpan`. ¿Qué regla arquitectónica de OpenTelemetry demuestra eso y por qué es *deliberado* en lugar de un bug?
2. ¿Cuál es la diferencia entre `start_span()` y `start_as_current_span()`? ¿Cuál hizo funcionar el anidamiento en `manual.py`?
3. ¿Por qué el código llama a `provider.shutdown()` al final? ¿Qué arriesga el `BatchSpanProcessor` si lo omitís?
4. Agregaste `add_event(...)` a un span en lugar de crear un nuevo span. ¿Cuándo elegirías un **evento** por sobre un **span** hijo?

---

## Ejercicio 3 — Instrumentation libraries vs. instrumentación nativa

**Objetivo:** habilitar una instrumentation library a mano (no vía el lanzador) y verla producir spans contra el SDK que configuraste en el Ejercicio 2 — esta es la costura entre la instrumentación basada en código y la sin código.

1. Instalá la instrumentation library de `requests` y `requests` en sí:

   ```bash
   pip install requests opentelemetry-instrumentation-requests
   ```

2. Reutilizá la configuración del SDK, luego activá la instrumentation library **una vez** al arrancar:

   ```python
   # lib_instrumented.py
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
   from opentelemetry.instrumentation.requests import RequestsInstrumentor
   import requests

   provider = TracerProvider()
   provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # Monkey-patch the requests library so every call emits a CLIENT span
   RequestsInstrumentor().instrument()

   requests.get("https://opentelemetry.io", timeout=10)
   provider.shutdown()
   ```

   ```bash
   python lib_instrumented.py
   ```

   Esperado — un span **CLIENT** que nunca creaste explícitamente, emitido por el bridge de la biblioteca (representativo):

   ```json
   {
       "name": "GET",
       "kind": "SpanKind.CLIENT",
       "attributes": {
           "http.request.method": "GET",
           "url.full": "https://opentelemetry.io/",
           "http.response.status_code": 200,
           "server.address": "opentelemetry.io"
       }
   }
   ```

3. Demostrá que la biblioteca es solo un bridge — deshabilitá el SDK *no* registrando un provider (comentá las tres líneas del provider) y volvé a correr. No se imprime ningún span: la instrumentation library llama a la **API**, que hace no-op sin un SDK, exactamente como en el Ejercicio 2.

Referencia: *Instrumentation — libraries* (https://opentelemetry.io/docs/concepts/instrumentation/libraries/), *Python — using instrumentation libraries* (https://opentelemetry.io/docs/zero-code/python/#configuring-instrumentation).

**Verificá tu comprensión — Bloque 3**

1. Definí una **instrumentation library** en una oración. ¿En qué se diferencia de una biblioteca que está **instrumentada de forma nativa**?
2. En el Ejercicio 1 nunca llamaste a `RequestsInstrumentor().instrument()`, y sin embargo se trazó Flask. ¿Qué hizo `opentelemetry-instrument` que este ejercicio hizo a mano?
3. El span de `requests` tenía `kind: CLIENT` mientras que el span de Flask en el Ejercicio 1 tenía `kind: SERVER`. ¿Qué comunica `SpanKind` a un backend de tracing y por qué importa para un trace distribuido?
4. ¿Una biblioteca instrumentada **de forma nativa** seguiría emitiendo telemetría si quitaras el SDK de OpenTelemetry del proceso? Explicá.

---

## Ejercicio 4 — Instrumentación sin código en Kubernetes con el OpenTelemetry Operator

**Objetivo:** inyectar auto-instrumentación en un pod con una sola anotación — sin reconstruir la imagen, sin cambio de código — y confirmar la inyección inspeccionando el pod.

1. Instalá los prerrequisitos y el operator (el operator necesita cert-manager para sus webhooks):

   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
   kubectl wait --for=condition=Available deploy --all -n cert-manager --timeout=120s

   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   kubectl wait --for=condition=Available deploy/opentelemetry-operator -n opentelemetry-operator-system --timeout=120s
   ```

2. Creá un custom resource **`Instrumentation`**. Esto le dice al operator *qué* inyectar y *adónde va la telemetría* — no instrumenta nada por sí solo:

   ```yaml
   # instrumentation.yaml
   apiVersion: opentelemetry.io/v1alpha1
   kind: Instrumentation
   metadata:
     name: dice-instrumentation
   spec:
     exporter:
       endpoint: http://otel-collector:4318   # Python auto-instr defaults to OTLP/HTTP
     propagators:
       - tracecontext
       - baggage
     sampler:
       type: parentbased_traceidratio
       argument: "1"                            # sample everything in the lab
     python:
       env:
         - name: OTEL_EXPORTER_OTLP_PROTOCOL
           value: http/protobuf
   ```

   ```bash
   kubectl apply -f instrumentation.yaml
   kubectl get instrumentation
   ```

3. Desplegá una app Python común y **habilitala** con la anotación de inyección en la **plantilla del pod** (no en la metadata del Deployment):

   ```yaml
   # deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: dice
   spec:
     replicas: 1
     selector: { matchLabels: { app: dice } }
     template:
       metadata:
         labels: { app: dice }
         annotations:
           instrumentation.opentelemetry.io/inject-python: "true"   # <- the switch
       spec:
         containers:
           - name: dice
             image: python:3.12-slim
             command: ["python", "-c", "import time; time.sleep(3600)"]
   ```

   ```bash
   kubectl apply -f deploy.yaml
   kubectl rollout status deploy/dice
   ```

4. Inspeccioná el pod creado y confirmá que el operator lo mutó:

   ```bash
   kubectl get pod -l app=dice -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo
   ```

   Esperado:

   ```
   opentelemetry-auto-instrumentation-python
   ```

5. Confirmá el entorno inyectado y el volumen compartido:

   ```bash
   kubectl describe pod -l app=dice | grep -E 'PYTHONPATH|OTEL_|opentelemetry-auto'
   ```

   Esperado (abreviado):

   ```
   PYTHONPATH:                     /otel-auto-instrumentation-python/opentelemetry/instrumentation/auto_instrumentation:/otel-auto-instrumentation-python
   OTEL_SERVICE_NAME:              dice
   OTEL_EXPORTER_OTLP_ENDPOINT:    http://otel-collector:4318
   OTEL_TRACES_EXPORTER:           otlp
   ...
   opentelemetry-auto-instrumentation-python   (volume mounted at /otel-auto-instrumentation-python)
   ```

   El mutating webhook del operator agregó un **init container** que copia la auto-instrumentación en un volumen `emptyDir` compartido, lo montó en tu contenedor de aplicación y estableció `PYTHONPATH` para que el agente se cargue al arrancar el intérprete — el mismo mecanismo que `opentelemetry-instrument` en el Ejercicio 1, entregado por la plataforma en lugar de por tu Dockerfile.

Referencia: *Kubernetes — Operator, auto-instrumentation injection* (https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/), *Instrumentation CR spec* (https://github.com/open-telemetry/opentelemetry-operator/blob/main/docs/api.md).

**Verificá tu comprensión — Bloque 4**

1. El CR `Instrumentation` existía *antes* de que cualquier pod fuera inyectado, y la inyección solo ocurrió después de que agregaste la anotación. ¿Cuál de los dos es el disparador real y cuál es el rol del CR?
2. Un compañero pone la anotación en `Deployment.metadata.annotations` en lugar de `spec.template.metadata.annotations` y reporta que "no se inyecta nada". ¿Por qué importa la ubicación?
3. Explicá el propósito del **init container** y el volumen `emptyDir` compartido. ¿Por qué el operator los usa en lugar de incorporar el agente en la imagen?
4. La inyección de Python usa por defecto el puerto **4318** para su endpoint OTLP, mientras que la auto-instrumentación de Java comúnmente usa **4317**. ¿Qué diferencia subyacente refleja eso y dónde mirarías primero si los spans nunca llegan al collector?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1 — Instrumentación sin código

1. La **instrumentation library de Flask** (`opentelemetry-instrumentation-flask`) creó el span; el provider/exporter del SDK lo convirtió en salida por consola. Se cargó porque `opentelemetry-instrument` corre tu programa como un hijo e inyecta la auto-instrumentación antes de que se ejecute tu código (en Python antepone el agente a `PYTHONPATH`/`sitecustomize`), aplicando monkey-patch a Flask en el momento del import. Nunca referenciaste OpenTelemetry en `app.py`.
2. `opentelemetry-bootstrap -a install` escanea los paquetes ya instalados en el entorno e instala las **instrumentation libraries que correspondan** (Flask → `opentelemetry-instrumentation-flask`, etc.). `opentelemetry-distro` solo trae la API, el SDK y el lanzador; sin los bridges por biblioteca el lanzador no tiene nada que parchear, así que correría pero emitiría pocos spans o ninguno.
3. `service.name` en el **resource** identifica al *productor* de toda la telemetría de ese proceso; se adjunta una sola vez y aplica a cada span, métrica y log. Los backends agrupan, nombran y enrutan los datos por resource (este es el "service" en un mapa de servicios). Ponerlo en un span lo acotaría a ese único span y rompería la agregación.
4. Tu propia **lógica de negocio / spans personalizados, atributos y métricas de dominio**. La instrumentación sin código cubre los frameworks y bibliotecas soportados (HTTP, DB, mensajería), pero no puede saber qué significa "checkout completed" o "risk score = 0.8" — eso requiere instrumentación basada en código. (Los logs también suelen ser opt-in.)

### Bloque 2 — Instrumentación basada en código

1. Muestra la **separación API/SDK** de OpenTelemetry: la API siempre devuelve un objeto válido, pero sin un SDK registrado ese objeto es un **no-op** (`NonRecordingSpan`). Esto es deliberado para que las bibliotecas puedan llamar a la API incondicionalmente y sigan siendo **seguras y livianas en dependencias** incluso en un proceso donde la aplicación eligió no instalar/configurar un SDK — la instrumentación nunca crashea ni fuerza telemetría en un host que no la quiere.
2. `start_span()` crea un span pero **no** lo convierte en el span actual — tenés que gestionar el contexto vos mismo. `start_as_current_span()` crea el span **y** lo establece como el span activo durante el bloque `with`, así que cualquier span iniciado adentro se vuelve su hijo automáticamente. Este último es el que produjo el anidamiento padre/hijo.
3. `BatchSpanProcessor` **bufferea** los spans y los exporta de forma asíncrona en lotes. Sin `shutdown()` (o `force_flush()`) al salir del proceso, los spans bufferizados pueden no exportarse nunca — perderías la cola de tu telemetría. `shutdown()` vacía la cola y detiene el worker de forma limpia.
4. Usá un **evento** para una anotación puntual *dentro* de una operación que no tiene una duración significativa ni un tiempo independiente (un marcador tipo log: "cache miss", "retry #2"). Usá un **span hijo** cuando la suboperación tiene su propia **duración**, estado y atributos que querés medir y ver como un nodo distinto en el trace (por ejemplo, una llamada downstream).

### Bloque 3 — Instrumentation libraries

1. Una **instrumentation library** es un paquete separado que envuelve/parchea una biblioteca *de terceros* que no es OTel-aware por sí misma, traduciendo sus operaciones en llamadas a la API de OpenTelemetry. Una biblioteca **instrumentada de forma nativa** llama a la API de OpenTelemetry directamente desde su propio código fuente — no necesita un paquete bridge.
2. `opentelemetry-instrument` descubrió cada instrumentation library instalada y llamó a sus hooks `instrument()` automáticamente al arrancar (además de configurar el SDK a partir de variables de entorno). El Ejercicio 3 hizo esa misma activación manualmente para una biblioteca — el lanzador es esencialmente "auto-activar todos los bridges + auto-configurar el SDK".
3. `SpanKind` describe el **rol del span en un flujo de petición**: `SERVER` recibe una petición, `CLIENT` hace una llamada saliente, más `PRODUCER`/`CONSUMER`/`INTERNAL`. En un trace distribuido, un span `CLIENT` en un servicio y el span `SERVER` que dispara en otro se emparejan para reconstruir el grafo de llamadas y calcular el tiempo de red vs. el de servidor. Acertar el kind es lo que le permite a un backend dibujar la topología correcta.
4. Sí — pero solo llamadas no-op. Una biblioteca instrumentada de forma nativa igual llama a la API, y sin un SDK esas llamadas se vuelven `NonRecordingSpan`s, así que **no se exporta telemetría**. La instrumentación nativa elimina la necesidad de un paquete bridge; **no** elimina la necesidad de un SDK configurado.

### Bloque 4 — OpenTelemetry Operator

1. La **anotación en el pod** es el disparador; el mutating webhook del operator solo actúa sobre los pods que llevan `instrumentation.opentelemetry.io/inject-<lang>`. El CR `Instrumentation` es **configuración** que el webhook lee cuando se dispara — endpoint del exportador, propagators, sampler, env por lenguaje — pero no inyecta nada por sí solo.
2. El webhook muta **pods**, y los pods se crean a partir de `spec.template`. Una anotación en `Deployment.metadata` nunca se copia al pod, así que el webhook ve un pod sin anotación y lo saltea. La anotación tiene que estar en `spec.template.metadata.annotations`.
3. El **init container** transporta el agente del lenguaje y lo copia en un volumen **`emptyDir`** compartido que también se monta en el contenedor de la aplicación; env como `PYTHONPATH` luego apunta el runtime a ese volumen para que el agente se cargue al arrancar. Esto mantiene la **imagen de la aplicación sin cambios y agnóstica al lenguaje** — podés agregar, actualizar o quitar instrumentación editando el CR/anotación, sin reconstruir y sin ninguna dependencia de OTel incorporada en la app.
4. Refleja el **transporte OTLP** por defecto que la auto-instrumentación de cada lenguaje selecciona: la inyección del operator para Python usa por defecto **OTLP/HTTP** (`http/protobuf`, puerto **4318**), mientras que Java comúnmente usa por defecto **OTLP/gRPC** (puerto **4317**). Si los spans nunca llegan, verificá primero que el **puerto y protocolo del endpoint del exportador** del `Instrumentation` coincidan (4318↔http/protobuf vs 4317↔grpc) y que el collector realmente tenga ese receiver/puerto abierto — un desajuste de protocolo/puerto es la falla silenciosa más común.

</details>