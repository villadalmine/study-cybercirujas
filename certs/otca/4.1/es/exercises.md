# Tema 4.1 — Propagación de Contexto: Ejercicios Guiados

> **Certificación:** OpenTelemetry Certified Associate (OTCA) — Dominio 4 (Instrumentación de Aplicaciones), Tema 4.1
> **Peso en el examen:** 2.5
> **Referencia:** [CNCF OTCA Curriculum](https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf) · [W3C Trace Context](https://www.w3.org/TR/trace-context/) · [W3C Baggage](https://www.w3.org/TR/baggage/) · [OpenTelemetry Context specification](https://opentelemetry.io/docs/specs/otel/context/) · [Propagators API](https://opentelemetry.io/docs/specs/otel/context/api-propagators/)

La propagación de contexto es el mecanismo que convierte spans aislados por servicio en un único trace distribuido. Tiene dos mitades que el examen separa de forma consistente:

- **Propagación in-process** — el objeto `Context` transporta el *span activo* (y el Baggage) de forma implícita a través de las llamadas a funciones dentro de un mismo proceso, sin que lo pases como argumento.
- **Propagación cross-process** — un `Propagator` serializa el `SpanContext` y el `Baggage` en un carrier (habitualmente headers HTTP) al salir, y los deserializa al entrar, de modo que el servicio downstream continúa el mismo trace.

Estos ejercicios son ejecutables de punta a punta con el SDK de Python, pero cada concepto (headers W3C, selección de propagador, Baggage, extracción/inyección) es agnóstico al lenguaje y mapea directamente a la especificación.

---

## Prerrequisitos

Necesitás Python 3.8+ y los paquetes de OpenTelemetry. Todo corre localmente; no se requiere ningún collector ni backend — imprimimos los spans en la consola.

```bash
python3 -m venv .otca && source .otca/bin/activate
pip install \
  opentelemetry-api==1.27.0 \
  opentelemetry-sdk==1.27.0 \
  opentelemetry-propagator-b3==1.27.0
python3 -c "import opentelemetry; print('otel', opentelemetry.version.__version__)"
```

Salida esperada:

```
otel 1.27.0
```

---

## Ejercicio 1 — Decodificar un header W3C `traceparent` a mano

El propagador por defecto de OpenTelemetry implementa **W3C Trace Context**. Antes de escribir cualquier código, tenés que ser capaz de leer el formato del cable, porque la mitad de la depuración de propagación de contexto consiste en mirar fijamente un header y decidir si está malformado.

### Pasos

1. Tomá este header capturado de una petición entrante real:

   ```
   traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
   ```

2. Dividilo por `-` en sus cuatro campos y etiquetá cada uno:

   ```bash
   echo "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" | tr '-' '\n'
   ```

   Salida esperada:

   ```
   00                                  # version
   4bf92f3577b34da6a3ce929d0e0e4736    # trace-id (16 bytes / 32 hex chars)
   00f067aa0ba902b7                    # parent-id / span-id (8 bytes / 16 hex chars)
   01                                  # trace-flags (1 byte)
   ```

3. Interpretá el byte `trace-flags`. Es un campo de 8 bits; solo el bit menos significativo (`0x01`, el flag **sampled**) está definido actualmente:

   ```bash
   python3 -c "print('sampled' if 0x01 & 0x01 else 'not sampled')"
   ```

   Salida esperada:

   ```
   sampled
   ```

4. Ahora inspeccioná un header complementario que puede estar presente o no:

   ```
   tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
   ```

   Notá que `tracestate` es una **lista ordenada, separada por comas, de entradas `key=value` de proveedor**, donde el más a la izquierda = el escrito más recientemente.

### Preguntas de verificación

- **Q1.1** — Un middlebox reenvía `traceparent: 00-00000000000000000000000000000000-00f067aa0ba902b7-01`. ¿Por qué un receptor debe tratar esto como inválido e iniciar un *nuevo* trace en lugar de continuar?
- **Q1.2** — ¿Cuál es la diferencia de propósito entre `traceparent` y `tracestate`? ¿Cuál transporta los identificadores que OpenTelemetry necesita para enlazar spans, y cuál es para datos específicos de proveedor?
- **Q1.3** — Un servicio downstream recibe `traceparent` pero el byte `trace-flags` es `00`. ¿Qué aprende el receptor sobre la decisión de sampling, y sigue estando obligado a propagar el header?
- **Q1.4** — Ves `version` = `01` en un header entrante, pero tu librería solo conoce la versión `00`. Según la spec, ¿rechazás la petición o parseás igual los primeros cuatro campos?

---

## Ejercicio 2 — Observar la propagación de contexto in-process (sin propagador involucrado)

Antes de que algo cruce una frontera de proceso, el *span activo* tiene que fluir a través de tu call stack. Esto es mecánica pura de `Context`: `start_as_current_span` muta el contexto implícito, y cualquier span iniciado por debajo de él se convierte automáticamente en hijo.

### Pasos

1. Guardá esto como `inproc.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       ConsoleSpanExporter,
       SimpleSpanProcessor,
   )

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("otca.inproc")

   def inner():
       # We do NOT pass any span or context in — it is read implicitly.
       current = trace.get_current_span()
       ctx = current.get_span_context()
       print(f"inner sees active span_id={ctx.span_id:016x} "
             f"trace_id={ctx.trace_id:032x}")
       with tracer.start_as_current_span("inner-work"):
           pass

   with tracer.start_as_current_span("outer") as outer:
       octx = outer.get_span_context()
       print(f"outer  span_id={octx.span_id:016x} "
             f"trace_id={octx.trace_id:032x}")
       inner()
   ```

2. Ejecutalo:

   ```bash
   python3 inproc.py
   ```

3. Leé primero las dos líneas de `print` (no los spans JSON). Confirmá que `inner` observó el **mismo** `trace_id` y el **mismo `span_id` activo** que `outer`, aunque no se pasó nada como argumento.

   Forma esperada (los IDs diferirán en cada ejecución):

   ```
   outer  span_id=a1b2c3d4e5f60718 trace_id=9f8e7d6c5b4a39281706f5e4d3c2b1a0
   inner sees active span_id=a1b2c3d4e5f60718 trace_id=9f8e7d6c5b4a39281706f5e4d3c2b1a0
   ```

4. Ahora inspeccioná los spans exportados. En el JSON del span `inner-work`, encontrá `parent_id` y confirmá que es igual al `span_id` de `outer`:

   ```
   "name": "inner-work",
   "parent_id": "0xa1b2c3d4e5f60718",
   "context": { "trace_id": "0x9f8e...", "span_id": "0x...." }
   ```

### Preguntas de verificación

- **Q2.1** — `inner()` no recibió ningún span ni argumento de contexto, y sin embargo vio correctamente a `outer` como el span activo. ¿Qué objeto de OpenTelemetry lo hizo posible, y dónde está almacenado?
- **Q2.2** — Si reemplazaras `start_as_current_span` por `start_span` (que inicia un span **sin** ponerlo como activo), ¿`inner-work` seguiría siendo hijo de `outer`? Explicá en términos del contexto activo.
- **Q2.3** — Lanzás `inner()` en un nuevo `threading.Thread`. ¿Seguiría viendo a `outer` como activo por defecto? ¿Qué te dice esto sobre cómo está scopeado el `Context` implícito en la mayoría de las implementaciones de lenguaje?

---

## Ejercicio 3 — Inyectar contexto en un carrier y extraerlo (ida y vuelta)

Esta es la mecánica cross-process central. Simulamos dos servicios inyectando en un `dict` plano (el "carrier") en el servicio A, y luego extrayendo de ese mismo `dict` en el servicio B — exactamente lo que hacen un cliente y un servidor HTTP con los headers.

### Pasos

1. Guardá esto como `roundtrip.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.propagate import inject, extract
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       ConsoleSpanExporter,
       SimpleSpanProcessor,
   )

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.roundtrip")

   # ---- Service A: create a span and inject into outbound headers ----
   carrier = {}
   with tracer.start_as_current_span("A: outgoing request"):
       inject(carrier)          # reads the CURRENT context implicitly
   print("A injected headers:", carrier)

   # ...network hop... the dict is what would travel as HTTP headers ...

   # ---- Service B: extract inbound context, start a child span ----
   parent_ctx = extract(carrier)   # returns a Context, NOT a span
   with tracer.start_as_current_span("B: handle request", context=parent_ctx):
       cur = trace.get_current_span().get_span_context()
       print(f"B running under trace_id={cur.trace_id:032x}")
   ```

2. Ejecutalo:

   ```bash
   python3 roundtrip.py
   ```

3. Mirá el carrier impreso. Debe contener una clave `traceparent` producida por el propagador W3C por defecto:

   ```
   A injected headers: {'traceparent': '00-<32 hex>-<16 hex>-01'}
   ```

4. Compará los tres trace IDs sobre los que ahora tenés visibilidad:
   - el `traceparent` en el carrier,
   - el `trace_id` del span `A: outgoing request` en el JSON de la consola,
   - la línea de print `B running under trace_id=...`.

   **Los tres deben ser idénticos.** Si lo son, la propagación funcionó; los dos spans son un único trace a través de una frontera de proceso (simulada).

5. Confirmá el enlace de parentesco: en el span exportado `B: handle request`, `parent_id` debe ser igual al `span_id` embebido en el `traceparent` inyectado.

### Preguntas de verificación

- **Q3.1** — `inject(carrier)` no tomó ningún argumento de span. ¿De dónde obtuvo los trace/span IDs que escribió en `traceparent`?
- **Q3.2** — `extract(carrier)` devuelve un `Context`, no un `Span`. ¿Por qué es ese el tipo de retorno correcto, y qué saldría mal si intentaras hacer `start_as_current_span` en el servicio B *sin* pasar ese contexto?
- **Q3.3** — Si el servicio B llama a `extract({})` sobre un carrier **vacío** (headers eliminados por un proxy), ¿qué obtiene de vuelta, y qué le pasa al span que luego inicia — es un error, o un nuevo trace raíz?
- **Q3.4** — ¿Por qué un `dict` plano es un carrier válido acá, pero los frameworks HTTP reales necesitan un *getter/setter* personalizado para leer los headers? (Pista: pensá en la insensibilidad a mayúsculas/minúsculas y en los headers con múltiples valores.)

---

## Ejercicio 4 — Propagar Baggage junto con el trace

**Baggage** es un conjunto separado de clave–valor que viaja en su propio header `baggage`. *No* se adjunta a un span automáticamente — esa es la idea equivocada más común sobre Baggage que el examen sondea.

### Pasos

1. Guardá esto como `baggage.py`:

   ```python
   from opentelemetry import baggage, trace
   from opentelemetry.context import attach, detach
   from opentelemetry.propagate import inject, extract

   # ---- Service A: set a baggage entry, then inject ----
   ctx = baggage.set_baggage("user.tier", "premium")
   carrier = {}
   inject(carrier, context=ctx)          # inject reads THIS context
   print("A injected:", carrier)

   # ---- Service B: extract, read baggage back ----
   incoming = extract(carrier)
   token = attach(incoming)              # make it the active context
   try:
       print("B sees user.tier =", baggage.get_baggage("user.tier"))
       print("B full baggage    =", dict(baggage.get_all()))
   finally:
       detach(token)
   ```

2. Ejecutalo:

   ```bash
   python3 baggage.py
   ```

   Salida esperada:

   ```
   A injected: {'traceparent': '00-...-...-00', 'baggage': 'user.tier=premium'}
   B sees user.tier = premium
   B full baggage    = {'user.tier': 'premium'}
   ```

   > Notá que el header `baggage` aparece **por separado** de `traceparent`. Son propagados por dos propagadores diferentes compuestos juntos (cubierto en el Ejercicio 5).

3. Ahora demostrá el punto de "Baggage no es un atributo del span". Agregá esto al final y volvé a ejecutar:

   ```python
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.baggage")

   token = attach(incoming)
   try:
       with tracer.start_as_current_span("B work") as span:
           # Baggage is available in context, but is NOT copied onto the span.
           span.set_attribute("user.tier", baggage.get_baggage("user.tier"))
   finally:
       detach(token)
   ```

   Inspeccioná el JSON del span `B work`: `user.tier` aparece bajo `attributes` **solo porque lo copiaste explícitamente**. Sin esa línea `set_attribute`, nunca aparecería en el span.

### Preguntas de verificación

- **Q4.1** — ¿Establecer Baggage en el servicio A hace que `user.tier` aparezca automáticamente como un atributo en los spans del servicio A o del servicio B? ¿Qué tenés que hacer para ponerlo en un span?
- **Q4.2** — El Baggage viaja en cada hop downstream y a menudo se escribe en los logs. Nombrá un riesgo de seguridad/privacidad que esto crea y una clase de datos que, por lo tanto, nunca deberías poner en Baggage.
- **Q4.3** — `baggage.set_baggage(...)` devuelve un **nuevo** `Context` en lugar de mutar en el lugar. ¿Por qué la Context API favorece semánticas inmutables, copy-on-write, acá?
- **Q4.4** — En el carrier inyectado, ¿por qué `traceparent` y `baggage` terminaron como dos claves de header independientes en lugar de un único header combinado?

---

## Ejercicio 5 — Configurar y componer propagadores (W3C vs B3, y ambos a la vez)

El propagador global de OpenTelemetry es configurable. Muchas mallas de producción todavía emiten headers **B3** (Zipkin), así que tenés que interoperar. Este ejercicio muestra cómo seleccionar un propagador, y cómo un propagador **composite** inyecta varios formatos a la vez para una migración gradual.

### Pasos

1. Primero, confirmá el valor por defecto. Guardá como `whichprop.py`:

   ```python
   from opentelemetry.propagate import get_global_textmap
   print(type(get_global_textmap()).__name__)
   ```

   ```bash
   python3 whichprop.py
   ```

   Salida esperada (el valor por defecto es W3C trace context + W3C baggage, compuestos):

   ```
   CompositePropagator
   ```

2. Ahora cambiá a **B3 multi-header** mediante la variable de entorno estándar `OTEL_PROPAGATORS` (sin cambio de código — así es como lo harías en producción):

   ```bash
   OTEL_PROPAGATORS=b3multi python3 - <<'PY'
   from opentelemetry import trace
   from opentelemetry.propagate import inject
   from opentelemetry.sdk.trace import TracerProvider
   provider = TracerProvider(); trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.b3")
   carrier = {}
   with tracer.start_as_current_span("out"):
       inject(carrier)
   print(carrier)
   PY
   ```

   Salida esperada — B3 multi emite headers **separados**, no `traceparent`:

   ```
   {'x-b3-traceid': '<32 hex>', 'x-b3-spanid': '<16 hex>', 'x-b3-sampled': '1'}
   ```

3. Ahora ejecutá un **composite** para que se inyecten tanto W3C como B3 — la forma segura de migrar una flota donde algunos servicios solo entienden un formato:

   ```bash
   OTEL_PROPAGATORS=tracecontext,baggage,b3multi python3 - <<'PY'
   from opentelemetry import trace
   from opentelemetry.propagate import inject
   from opentelemetry.sdk.trace import TracerProvider
   provider = TracerProvider(); trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.multi")
   carrier = {}
   with tracer.start_as_current_span("out"):
       inject(carrier)
   for k in sorted(carrier):
       print(k, "=", carrier[k])
   PY
   ```

   Salida esperada — ambos formatos presentes, transportando los **mismos** IDs:

   ```
   traceparent = 00-<32 hex>-<16 hex>-01
   x-b3-sampled = 1
   x-b3-spanid = <16 hex>
   x-b3-traceid = <32 hex>
   ```

4. Verificá la interoperabilidad: el valor `x-b3-traceid` y el campo trace-id dentro de `traceparent` deben ser byte a byte iguales. Un trace, dos formatos de cable.

### Preguntas de verificación

- **Q5.1** — ¿Cuál es el propósito exacto de un `CompositePropagator` en el lado de **inject** versus el lado de **extract**? (Considerá: en extract, ¿qué pasa cuando tanto `traceparent` como `x-b3-traceid` están presentes?)
- **Q5.2** — Estás migrando una flota de B3 a W3C. ¿Por qué `OTEL_PROPAGATORS=tracecontext,baggage,b3multi` es un paso intermedio más seguro que cambiar cada servicio de `b3multi` a `tracecontext` de una sola vez?
- **Q5.3** — `b3multi` produce `x-b3-traceid` / `x-b3-spanid` / `x-b3-sampled` como headers separados, mientras que `b3` (único) los empaqueta en un solo header `b3: {traceid}-{spanid}-{sampled}-{parentspanid}`. ¿Cuál es más amigable para los sistemas que limitan la cantidad de headers, y cuál es más fácil de grepear en los logs?
- **Q5.4** — `OTEL_PROPAGATORS` acepta una **lista ordenada separada por comas**. En la extracción, si la lista es `tracecontext,b3multi` y ambos conjuntos de headers existen pero no coinciden, ¿cuál gana, y por qué importa el orden?

---

## Ejercicio 6 — Diagnosticar un trace roto (el síntoma de "dos traces desconectados")

Los bugs de propagación de contexto en producción casi nunca lanzan un error. En cambio, obtenés **dos medios-traces con `trace_id`s diferentes** donde esperabas uno. Este ejercicio reproduce y arregla la causa clásica: inyectar con el contexto activo equivocado (o vacío).

### Pasos

1. Guardá esta versión **con bug** como `broken.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.propagate import inject, extract
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

   provider = TracerProvider()
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)
   tracer = trace.get_tracer("otca.debug")

   carrier = {}
   # BUG: inject is OUTSIDE the span's `with` block, so no span is active.
   with tracer.start_as_current_span("A: request") as a:
       print("A trace_id =", f"{a.get_span_context().trace_id:032x}")
   inject(carrier)                       # <-- runs after the span ended
   print("carrier:", carrier)

   ctx = extract(carrier)
   with tracer.start_as_current_span("B: handle", context=ctx) as b:
       print("B trace_id =", f"{b.get_span_context().trace_id:032x}")
   ```

2. Ejecutalo y observá la falla:

   ```bash
   python3 broken.py
   ```

   Salida esperada (con bug) — notá que `carrier` está **vacío** y los dos trace IDs **difieren**:

   ```
   A trace_id = 1111...aaaa
   carrier: {}
   B trace_id = 2222...bbbb        # different trace — B started a NEW root
   ```

3. Diagnóstico: el carrier está vacío porque en el momento en que corrió `inject`, no había ningún span activo válido en el contexto, así que el propagador W3C no tenía nada que escribir. `extract({})` luego devolvió un contexto vacío, por lo que B inició un nuevo trace raíz.

4. Arreglalo moviendo `inject(carrier)` **dentro** del bloque `with` (para que el span esté activo cuando inyectás):

   ```python
   with tracer.start_as_current_span("A: request") as a:
       print("A trace_id =", f"{a.get_span_context().trace_id:032x}")
       inject(carrier)                   # span is active here
   ```

5. Volvé a ejecutar. Ahora `carrier` contiene un `traceparent`, y los valores de `trace_id` de A y de B coinciden. Un trace restaurado.

### Preguntas de verificación

- **Q6.1** — En la ejecución con bug, ¿por qué el carrier estaba vacío en lugar de lanzar una excepción? ¿Qué te enseña esto sobre cómo suelen manifestarse las fallas de propagación?
- **Q6.2** — Dadas solo las dos salidas de consola (antes de ver el código), ¿qué único síntoma observable te dijo que la propagación había fallado?
- **Q6.3** — Inspeccionás un carrier en vivo y *sí* contiene `traceparent: 00-<id>-<id>-00`. El trace downstream igual parece "faltante" en tu backend. Dado el valor de `trace-flags`, ¿cuál es la explicación no-bug más probable, y cómo la confirmarías?
- **Q6.4** — Nombrá dos culpables reales de infraestructura (no código de aplicación) que eliminan o reescriben los headers `traceparent`/`x-b3-*` y producen exactamente este síntoma de "dos traces desconectados".

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas</summary>

### Ejercicio 1

- **A1.1** — El campo `trace-id` es todo ceros, lo cual la spec de W3C Trace Context define explícitamente como **inválido**. Un trace-id (o span-id) todo en ceros DEBE ser rechazado; un receptor conforme descarta el contexto entrante e inicia un nuevo trace/span raíz en lugar de adoptar un identificador inutilizable. Esto evita que IDs "envenenados" todo-ceros enlacen peticiones no relacionadas. (Ver [W3C Trace Context §3.2.2.3](https://www.w3.org/TR/trace-context/#trace-id).)
- **A1.2** — `traceparent` transporta los **identificadores estándar y obligatorios** — version, trace-id, parent span-id y trace-flags — que OpenTelemetry necesita para reconstruir los enlaces padre/hijo entre servicios. `tracestate` transporta datos **opcionales y específicos de proveedor** de tipo key=value (por ejemplo, el estado de sampling propio de un proveedor) y es una lista mutable y ordenada. Enlazar spans depende de `traceparent`; `tracestate` es auxiliar y puede descartarse sin romper el grafo del trace.
- **A1.3** — `trace-flags = 00` significa que el **bit sampled está sin activar**: el upstream indicó que este trace (probablemente) no fue muestreado. El receptor igual recibe trace/span IDs válidos y **sigue estando obligado a propagar `traceparent` sin cambios** downstream (y puede tomar su propia decisión de sampling según el sampler configurado, por ejemplo `ParentBased`). "No muestreado" ≠ "sin contexto"; propagación y sampling son preocupaciones independientes.
- **A1.4** — Lo **parseás igual**. La spec obliga a la compatibilidad hacia adelante: un receptor que soporta la versión `00` debe igual parsear los primeros cuatro campos conocidos de una versión superior que no entiende del todo, ignorando cualquier dato adicional al final, en lugar de rechazar la petición. Solo un header genuinamente malformado (longitudes de campo incorrectas, hex inválido, IDs todo-ceros) se rechaza.

### Ejercicio 2

- **A2.1** — El objeto **`Context`** (el contexto activo/actual), almacenado en una ubicación implícita y ambiente gestionada por el `ContextManager` — en Python eso es un `contextvars.ContextVar`. `start_as_current_span` empujó `outer` dentro de ese contexto, y `trace.get_current_span()` dentro de `inner()` lo leyó de vuelta sin pasar ningún argumento.
- **A2.2** — **No.** `start_span` crea el span pero **no** lo establece como el span activo en el contexto. Así que cuando `inner()` corre e inicia `inner-work`, el span activo sigue siendo el que fuera antes (potencialmente el contexto inválido/raíz), y `inner-work` *no* estaría emparentado con `outer`. Solo `start_as_current_span` (o un `attach` explícito) actualiza el contexto activo que leen los hijos.
- **A2.3** — Por defecto, **no** — un `threading.Thread` recién creado **no** hereda el contexto activo del thread padre en la mayoría de las implementaciones (cada thread tiene su propia copia de `contextvars` tomada en el momento de la creación, y los threads worker iniciados más tarde no la reciben automáticamente). Esto muestra que el `Context` implícito está **scopeado por unidad-de-ejecución** (por thread / por async task), que es exactamente por qué cruzar fronteras de thread, async o proceso requiere manejo explícito del contexto (`attach`, o inject/extract).

### Ejercicio 3

- **A3.1** — Del **contexto actual**. `inject(carrier)` sin un argumento de contexto explícito lee el `Context` globalmente activo, extrae de él el `SpanContext` del span activo, y serializa su trace-id/span-id/flags en `traceparent`. Como la llamada está dentro del bloque `with` del span, ese span es el activo.
- **A3.2** — `extract` devuelve un **`Context`** porque los datos remotos no son un objeto span vivo — son solo valores de `SpanContext` serializados que describen un *padre remoto*. El uso correcto es pasar ese `Context` a `start_as_current_span(..., context=parent_ctx)` de modo que el nuevo span local se convierta en hijo del span remoto. Si iniciaras el span de B **sin** pasar ese contexto, B ignoraría el padre entrante e iniciaría un **nuevo trace raíz** — los dos servicios aparecerían como dos traces desconectados.
- **A3.3** — `extract({})` devuelve efectivamente un **contexto vacío/raíz** (sin span remoto válido). El span que B luego inicia **no es un error** — simplemente se convierte en un **nuevo span raíz de un nuevo trace**. Este es el diseño de degradación elegante: los headers faltantes nunca crashean el servicio, solo rompen el enlace del trace de forma silenciosa.
- **A3.4** — Un `dict` plano funciona porque los getter/setter por defecto hacen búsquedas simples de clave. HTTP real requiere un getter/setter personalizado porque los nombres de los headers HTTP son **insensibles a mayúsculas/minúsculas** (`Traceparent` vs `traceparent`) y los headers pueden ser **multi-valuados** (una lista por clave). El getter del propagador específico del framework normaliza mayúsculas/minúsculas y sabe cómo devolver/agregar valores de lista correctamente.

### Ejercicio 4

- **A4.1** — **No.** El Baggage vive en el `Context` y se propaga en su propio header `baggage`, pero **nunca se copia automáticamente en los spans** de ninguno de los dos servicios. Para adjuntarlo a un span tenés que leerlo explícitamente (`baggage.get_baggage(...)`) y llamar a `span.set_attribute(...)` — como se muestra en el paso 3.
- **A4.2** — El Baggage se propaga a **todos** los servicios downstream y frecuentemente se loguea, por lo que es trivial filtrar accidentalmente datos sensibles a través de fronteras de confianza y hacia almacenes de logs. **Nunca pongas secretos, PII, tokens ni credenciales de autenticación en el Baggage** — tratalo como metadata de difusión, sin cifrar y potencialmente persistida.
- **A4.3** — Porque el `Context` de OpenTelemetry está especificado como **inmutable**: cada mutación (`set_baggage`, `attach`) devuelve un *nuevo* Context en lugar de editar estado compartido. Este modelo copy-on-write hace que el contexto sea seguro de compartir entre unidades de ejecución concurrentes — una task o thread hijo no puede corromper accidentalmente el contexto de un padre, y no hay data races sobre el contexto ambiente.
- **A4.4** — Porque el trace context y el Baggage son manejados por **dos propagadores diferentes** (`TraceContextTextMapPropagator` y `W3CBaggagePropagator`) compuestos en el `CompositePropagator` por defecto. Cada uno escribe en su propia clave de header según la respectiva spec de W3C (`traceparent`/`tracestate` vs `baggage`). Son preocupaciones ortogonales mantenidas en headers separados y parseables de forma independiente.

### Ejercicio 5

- **A5.1** — En **inject**, un `CompositePropagator` llama a cada propagador hijo por turno de modo que el carrier termina con **todos** los formatos (por ejemplo, tanto `traceparent` como `x-b3-*`). En **extract**, también llama a cada hijo en orden, y cada extractor sucesivo opera sobre el contexto producido por el anterior — así que con el ordenamiento por defecto el propagador **listado más tarde** puede sobrescribir el resultado de uno anterior. En la práctica los ordenás de modo que el formato en el que más confiás se aplique al final (gana) cuando hay múltiples conjuntos de headers presentes.
- **A5.2** — Porque durante la migración algunos servicios todavía solo leen B3 y otros solo leen W3C. Inyectar **ambos** formatos simultáneamente significa que *cada* servicio downstream encuentra un header que entiende, así que ningún trace se rompe a mitad de la migración. Si cambiaras los servicios a `tracecontext`-solo de a uno por vez, cualquier servicio B3-solo downstream de un servicio ya cambiado fallaría al extraer el contexto e iniciaría un nuevo trace raíz — produciendo traces desconectados hasta que toda la flota esté convertida.
- **A5.3** — El header único `b3` (un solo header `b3:`) es más amigable para los sistemas que **limitan la cantidad de headers** o donde cada header agrega overhead. El multi-header `b3multi` (`x-b3-traceid`, `x-b3-spanid`, `x-b3-sampled`) es **más fácil de grepear/inspeccionar** en los logs y proxies porque cada valor es su propio header nombrado en lugar de una cadena empaquetada delimitada por guiones.
- **A5.4** — Con `tracecontext,b3multi`, la extracción corre `tracecontext` primero, luego `b3multi`, y como el composite los aplica en secuencia el **último que encuentra datos válidos efectivamente gana** — acá `b3multi` sobrescribiría el contexto derivado de W3C si ambos están presentes y difieren. El orden importa porque resuelve de forma determinista los conflictos cuando llega una petición que transporta múltiples formatos de propagación en desacuerdo; listás tu formato autoritativo al final.

### Ejercicio 6

- **A6.1** — Porque la propagación está diseñada para **fallar silenciosamente / degradar de forma elegante**, nunca para lanzar una excepción. Cuando corrió `inject` no había ningún span activo válido, así que el propagador W3C simplemente no tenía nada que serializar y no escribió nada — un carrier vacío, no una excepción. La lección: los bugs de propagación de contexto se manifiestan como **traces faltantes o rotos en tu backend**, no como stack traces en tus logs, por lo que tenés que detectarlos observando la forma del trace.
- **A6.2** — Los dos valores de `trace_id` eran **diferentes** (`A trace_id` ≠ `B trace_id`). Cuando A y B pertenecen a la misma petición lógica pero reportan trace-ids diferentes, la propagación ha fallado y estás viendo dos raíces en lugar de un trace padre/hijo. (Una señal secundaria: el `carrier` inyectado estaba vacío.)
- **A6.3** — El byte `trace-flags` es `00`, es decir **sampled = false**. Esto muy probablemente **no es un bug**: el trace intencionalmente no fue muestreado, por lo que un sampler `ParentBased` downstream también lo descartó y nada llegó a tu backend. Confirmalo forzando/subiendo la tasa de sampling (o usando un sampler always-on) y reemitiendo la petición, y luego verificando si el trace ahora aparece con `trace-flags = 01`.
- **A6.4** — Culpables comunes de infraestructura: (1) **API gateways / reverse proxies / load balancers** (por ejemplo, NGINX, Envoy, ALB mal configurados) que eliminan o no reenvían headers personalizados/`traceparent`; (2) **service meshes** que emiten un formato de propagación *diferente* al que la app espera (mismatch B3 vs W3C); también CDNs, WAFs y message brokers que no transportan headers a través de una cola. Cualquiera de estos elimina o reescribe los headers de propagación y produce el síntoma de "dos traces desconectados".

</details>