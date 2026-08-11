# Tema 2.6 — Context Propagation

**Certificación:** OpenTelemetry Certified Associate (OTCA) · **Peso en el examen:** 6.57%

> Estos ejercicios guiados te llevan desde el context *in-process* (cómo un único proceso recuerda "¿dentro de qué span estoy ahora mismo?") hasta la propagación *cross-process* (cómo esa identidad sobrevive a un salto de red), pasando por Baggage, la selección de propagator y, finalmente, el diagnóstico de un **snapped trace** — el incidente de producción más común en este dominio.
>
> **Prerrequisitos.** Python 3.9+, y un virtualenv temporal:
> ```bash
> python -m venv .venv && source .venv/bin/activate
> pip install "opentelemetry-api==1.*" "opentelemetry-sdk==1.*"
> ```
> Los mecanismos que observás acá son independientes del lenguaje — la *especificación* de OpenTelemetry define Context, Propagators y Baggage con independencia de cualquier SDK. Se usa Python porque su salida es fácil de leer.
>
> **Fuentes referenciadas a lo largo del documento:**
> - Concepto de context propagation — https://opentelemetry.io/docs/concepts/context-propagation/
> - Especificación de Context — https://opentelemetry.io/docs/specs/otel/context/
> - API de Propagators — https://opentelemetry.io/docs/specs/otel/context/api-propagators/
> - API de Baggage — https://opentelemetry.io/docs/specs/otel/baggage/api/
> - W3C Trace Context — https://www.w3.org/TR/trace-context/
> - W3C Baggage — https://www.w3.org/TR/baggage/
> - Configuración del SDK (`OTEL_PROPAGATORS`) — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/

---

## Ejercicio 1 — El objeto Context: inmutable y *no* thread-local por accidente

El `Context` es un contenedor clave/valor **inmutable**. Cada "mutación" devuelve un *nuevo* Context; el Context "current" es lo que le permite a `start_as_current_span` conocer a su parent. Vas a demostrar ambas propiedades.

1. Creá `ex1_context.py`:

    ```python
    from opentelemetry import context, baggage

    # 1. Context is immutable: set_baggage returns a NEW context,
    #    it does not modify the one you passed in.
    root = context.get_current()
    ctx_a = baggage.set_baggage("tenant", "acme", context=root)
    ctx_b = baggage.set_baggage("tenant", "globex", context=root)

    print("root  :", baggage.get_all(context=root))
    print("ctx_a :", baggage.get_all(context=ctx_a))
    print("ctx_b :", baggage.get_all(context=ctx_b))

    # 2. The "current" context is separate from any local variable.
    print("current (before attach):", baggage.get_all())
    token = context.attach(ctx_a)          # attach makes ctx_a current
    print("current (after attach) :", baggage.get_all())
    context.detach(token)                  # detach restores the previous current
    print("current (after detach) :", baggage.get_all())
    ```

2. Ejecutalo:

    ```bash
    python ex1_context.py
    ```

    Salida esperada:

    ```
    root  : {}
    ctx_a : {'tenant': 'acme'}
    ctx_b : {'tenant': 'globex'}
    current (before attach): {}
    current (after attach) : {'tenant': 'acme'}
    current (after detach) : {}
    ```

3. Ahora **olvidate del token** para ver por qué existe `detach`. Agregá un segundo `attach` sin hacer detach en el medio, y después hacé detach en el orden incorrecto:

    ```python
    t1 = context.attach(baggage.set_baggage("layer", "one"))
    t2 = context.attach(baggage.set_baggage("layer", "two"))
    context.detach(t1)   # detaching t1 first — out of order
    print("out-of-order current:", baggage.get_all())
    ```

    Observá que esto o bien emite un warning o bien deja un valor que no esperabas — `attach`/`detach` se comportan como una **stack**, y deben desapilarse en orden Last-In-First-Out.

**Comprobá lo que entendiste**

- Q1.1 — `ctx_a` y `ctx_b` se derivaron ambos de `root`. ¿Por qué modificar uno nunca afecta al otro, y por qué esa propiedad es esencial para el manejo concurrente de requests?
- Q1.2 — `context.attach()` devuelve un *token*. ¿Para qué sirve el token, y qué se rompe si nunca llamás a `detach()` con él?
- Q1.3 — En el paso 3, ¿por qué `attach`/`detach` deben desapilarse en orden Last-In-First-Out?
- Q1.4 — En un servidor `async`/con threads, ¿qué mecanismo subyacente usa el SDK de Python para que el "current context" sea correcto por tarea, y no compartido globalmente? (Nombrá el concepto que exige la especificación.)

---

## Ejercicio 2 — Diseccionando el `traceparent` de W3C

La propagación cross-process es, físicamente, apenas HTTP headers. El estándar W3C Trace Context define `traceparent` (campos obligatorios) y `tracestate` (datos de vendor). Vas a generar uno y decodificar cada byte.

1. Creá `ex2_traceparent.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("ex2")

    carrier = {}
    with tracer.start_as_current_span("checkout") as span:
        sc = span.get_span_context()
        print("trace_id   :", format(sc.trace_id, "032x"))
        print("span_id    :", format(sc.span_id, "016x"))
        print("trace_flags:", format(int(sc.trace_flags), "02x"))
        inject(carrier)                       # serialize CURRENT context into carrier

    print("carrier    :", carrier)
    ```

2. Ejecutalo (los valores son aleatorios en cada corrida):

    ```bash
    python ex2_traceparent.py
    ```

    Salida de ejemplo:

    ```
    trace_id   : 4bf92f3577b34da6a3ce929d0e0e4736
    span_id    : 00f067aa0ba902b7
    trace_flags: 01
    carrier    : {'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'}
    ```

3. Mapeá el string `traceparent` a sus cuatro campos separados por guiones:

    ```
    00 - 4bf92f3577b34da6a3ce929d0e0e4736 - 00f067aa0ba902b7 - 01
    │    │                                  │                  │
    │    │                                  │                  └─ trace-flags (1 byte): bit 0 = sampled
    │    │                                  └─ parent-id / span-id (8 bytes, 16 hex)
    │    └─ trace-id (16 bytes, 32 hex) — globally unique per trace
    └─ version (1 byte) — currently 00
    ```

4. Confirmá la regla de "todo-en-cero es inválido". Un `trace-id` de 32 ceros o un `span-id` de 16 ceros está definido como inválido por la spec y DEBE ser rechazado. Alimentá al extractor con un header malformado y observá cómo lo rechaza:

    ```python
    from opentelemetry.propagate import extract
    from opentelemetry import trace

    bad = {"traceparent": "00-00000000000000000000000000000000-00f067aa0ba902b7-01"}
    ctx = extract(bad)
    sc = trace.get_current_span(ctx).get_span_context()
    print("is_valid:", sc.is_valid)          # False — invalid trace-id rejected
    ```

**Comprobá lo que entendiste**

- Q2.1 — ¿Cuántos *bytes* (no caracteres hex) tienen el `trace-id` y el `span-id`, y por qué importa la longitud para las garantías de unicidad a lo largo de una flota?
- Q2.2 — El `traceparent` que generaste terminaba en `-01`. ¿Qué significa el byte `01`, y qué le diría `-00` a un servicio downstream respecto de si debe registrar (record)?
- Q2.3 — Un servicio downstream recibe el byte de `version` `cc` (una versión futura que no entiende). Según la spec de W3C, ¿debe descartar el header o puede usarlo igual? Explicá la regla de compatibilidad hacia adelante (forward-compatibility).
- Q2.4 — ¿Para qué sirve `tracestate`, y por qué es un header separado de `traceparent` en lugar de más campos dentro de él?

---

## Ejercicio 3 — inject / extract manual: cosiendo dos procesos juntos

Las bibliotecas de instrumentación llaman a `inject`/`extract` por vos. Acá lo hacés a mano cruzando una frontera de socket real para que puedas *ver* cómo la trace sobrevive al salto.

1. Creá el **caller** `ex3_client.py`:

    ```python
    import http.client, json
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("client")

    with tracer.start_as_current_span("client.request") as span:
        headers = {}
        inject(headers)                                  # <-- writes traceparent
        print("CLIENT trace_id:", format(span.get_span_context().trace_id, "032x"))
        print("CLIENT sending headers:", headers)
        conn = http.client.HTTPConnection("localhost", 8080)
        conn.request("GET", "/", headers=headers)
        conn.getresponse().read()
    ```

2. Creá el **callee** `ex3_server.py`:

    ```python
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import extract

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("server")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            ctx = extract(dict(self.headers))            # <-- reads traceparent
            with tracer.start_as_current_span("server.handle", context=ctx) as span:
                sc = span.get_span_context()
                parent = getattr(span, "parent", None)
                print("SERVER trace_id  :", format(sc.trace_id, "032x"))
                print("SERVER parent set:", parent is not None)
            self.send_response(200); self.end_headers()

    HTTPServer(("localhost", 8080), Handler).serve_forever()
    ```

3. En la terminal A iniciá el server, en la terminal B ejecutá el client:

    ```bash
    # terminal A
    python ex3_server.py
    # terminal B
    python ex3_client.py
    ```

    Salida esperada (el trace_id es idéntico en ambos lados — ese es el punto entero):

    ```
    # client
    CLIENT trace_id: 9c8f1e2a...d31b
    CLIENT sending headers: {'traceparent': '00-9c8f1e2a...d31b-a1b2...-01'}
    # server
    SERVER trace_id  : 9c8f1e2a...d31b
    SERVER parent set: True
    ```

4. Ahora **rompelo** a propósito: comentá la línea `inject(headers)` en el client y volvé a ejecutar. El server imprime un `trace_id` *distinto* y `SERVER parent set: False` — sin context entrante, `extract` devuelve un context vacío y el span del server se convierte en un nuevo **root**. Esto es un snapped trace, reproducido en una sola línea.

**Comprobá lo que entendiste**

- Q3.1 — Del lado del server, ¿por qué `start_as_current_span(..., context=ctx)` hizo que el span del server fuera un *child* en lugar de un root? ¿Qué llevaba `ctx` que el context por defecto (current) no tenía?
- Q3.2 — En el paso 4, con `inject` removido, `extract` igual devolvió *algo*. ¿Qué devolvió, y por qué eso causó un nuevo root span en lugar de un error?
- Q3.3 — `extract` toma un "carrier" (acá `dict(self.headers)`). ¿Qué interfaz debe satisfacer un carrier para un `TextMapPropagator`, y por qué esa abstracción (Getter/Setter) es importante para transportes no-HTTP como Kafka?
- Q3.4 — ¿En qué parte de un servicio real normalmente *no* escribirías `inject`/`extract` vos mismo, y qué componente lo hace por vos?

---

## Ejercicio 4 — Baggage: llevando business context a lo largo de todo el call graph

`traceparent` propaga *identidad*. **Baggage** propaga *datos clave/valor arbitrarios* (por ejemplo `user.tier=premium`) para que cada servicio downstream pueda leerlos. Vas a setear baggage, observar cómo se serializa en su propio header, y leerlo tres saltos después.

1. Creá `ex4_baggage.py`:

    ```python
    from opentelemetry import baggage, context
    from opentelemetry.propagate import inject, extract

    # Set two baggage entries on a fresh context.
    ctx = baggage.set_baggage("user.tier", "premium")
    ctx = baggage.set_baggage("cart.experiment", "checkout-v3", context=ctx)

    carrier = {}
    inject(carrier, context=ctx)
    print("wire headers:", carrier)

    # Simulate the next service extracting from the same carrier.
    downstream = extract(carrier)
    print("downstream tier      :", baggage.get_baggage("user.tier", downstream))
    print("downstream experiment:", baggage.get_baggage("cart.experiment", downstream))
    print("downstream all       :", baggage.get_all(downstream))
    ```

2. Ejecutalo:

    ```bash
    python ex4_baggage.py
    ```

    Salida esperada:

    ```
    wire headers: {'baggage': 'user.tier=premium,cart.experiment=checkout-v3'}
    downstream tier      : premium
    downstream experiment: checkout-v3
    downstream all        : {'user.tier': 'premium', 'cart.experiment': 'checkout-v3'}
    ```

3. Observá el URL-encoding. Los valores de baggage con caracteres reservados se codifican con percent-encoding en el cable según W3C Baggage:

    ```python
    from opentelemetry import baggage
    from opentelemetry.propagate import inject
    ctx = baggage.set_baggage("server.node", "DF 28")   # value contains a space
    carrier = {}
    inject(carrier, context=ctx)
    print(carrier)          # {'baggage': 'server.node=DF%2028'}
    ```

4. Entendé el **costo**. Baggage viaja en *cada* request saliente de la trace. Agregá un valor grande y notá cómo infla cada header en cada salto:

    ```python
    big = "x" * 4000
    ctx = baggage.set_baggage("dump", big)
    carrier = {}
    inject(carrier, context=ctx)
    print("header bytes:", len(carrier.get("baggage", "")))   # ~4008
    ```

**Comprobá lo que entendiste**

- Q4.1 — Baggage y `traceparent` son *ambos* formas de context propagado, pero responden preguntas distintas. Enunciá en una sola oración la diferencia de propósito.
- Q4.2 — El valor `"DF 28"` apareció en el cable como `DF%2028`. ¿Qué especificación exige esta codificación, y qué se rompería si el espacio se enviara crudo?
- Q4.3 — Un desarrollador guarda el JWT completo de un cliente en baggage para que cada servicio pueda autorizar. Dá **dos** razones distintas por las que esto es un anti-patrón serio (pista: una es sobre bytes, otra es sobre trust/PII).
- Q4.4 — Por defecto, ¿una entrada en Baggage se convierte automáticamente en un attribute en tus spans? ¿Qué tenés que hacer explícitamente para registrar baggage en un span, y por qué esa separación es deliberada?

---

## Ejercicio 5 — Eligiendo propagators: composite, B3 y `OTEL_PROPAGATORS`

El propagator es *configurable*. Si dos servicios no coinciden en el formato del cable, el context no cruza. Vas a cambiar de formato con una sola variable de entorno.

1. Confirmá el valor por defecto. Sin configuración, el propagator global es el **composite** `tracecontext,baggage`. Creá `ex5_default.py`:

    ```python
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject

    trace.set_tracer_provider(TracerProvider())
    tracer = trace.get_tracer("ex5")

    carrier = {}
    with tracer.start_as_current_span("op"):
        inject(carrier)
    print("headers:", sorted(carrier))
    ```

    ```bash
    python ex5_default.py
    # headers: ['traceparent']         (and 'baggage' too, if any baggage is set)
    ```

2. Instalá y seleccioná **B3 multi-header** (el formato de Zipkin), vía `OTEL_PROPAGATORS`:

    ```bash
    pip install opentelemetry-propagator-b3
    OTEL_PROPAGATORS=b3multi python ex5_default.py
    ```

    Salida esperada — el formato del cable cambia por completo, sin necesidad de editar código:

    ```
    headers: ['x-b3-sampled', 'x-b3-spanid', 'x-b3-traceid']
    ```

3. Seleccioná **B3 single-header** e inspeccioná su forma empaquetada:

    ```bash
    OTEL_PROPAGATORS=b3 python - <<'PY'
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject
    trace.set_tracer_provider(TracerProvider())
    with trace.get_tracer("x").start_as_current_span("op"):
        c = {}; inject(c); print(c)
    PY
    # {'b3': '<traceid>-<spanid>-1'}     # trace-span-sampled packed in one header
    ```

4. **Interoperá.** Una flota que migra de Zipkin a W3C corre ambos formatos durante el cutover. Emití *ambos* listando múltiples propagators — el composite inyecta cada uno y extrae el que llegue:

    ```bash
    OTEL_PROPAGATORS=tracecontext,b3multi,baggage python ex5_default.py
    # headers: ['traceparent', 'x-b3-sampled', 'x-b3-spanid', 'x-b3-traceid']
    ```

**Comprobá lo que entendiste**

- Q5.1 — ¿Cuál es el valor por defecto de `OTEL_PROPAGATORS` según la especificación de OpenTelemetry, y qué dos propagators contiene?
- Q5.2 — El Servicio A está configurado con `OTEL_PROPAGATORS=b3multi`; el Servicio B queda en el valor por defecto. A llama a B. Describí exactamente qué produce el paso de extract de B y qué le pasa a la trace.
- Q5.3 — En el paso 4 seteaste `tracecontext,b3multi,baggage`. En la *extracción*, si un request entrante lleva **ambos** un `traceparent` y headers B3 que no coinciden, ¿cómo resuelve el conflicto un composite propagator? (Pensá en el ordenamiento / last-writer.)
- Q5.4 — ¿Por qué poner la interoperabilidad en la capa del *propagator* (variable de entorno) — en lugar de bifurcar tu código de instrumentación — es el diseño correcto durante una migración de vendor?

---

## Ejercicio 6 — Diagnosticando un snapped trace (escenario de producción)

Estás de guardia (on-call). Una trace que debería abarcar `gateway → orders → payments` aparece en el backend como **dos** traces desconectadas: `gateway` sola, y `orders → payments`. El link entre el gateway y orders desapareció. Trabajá el diagnóstico.

1. Reproducí la falla. Simulá que el gateway emite **solo B3** mientras orders extrae **solo W3C**:

    ```bash
    # gateway injects b3multi
    OTEL_PROPAGATORS=b3multi python - <<'PY'
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import inject
    trace.set_tracer_provider(TracerProvider())
    with trace.get_tracer("gw").start_as_current_span("gateway"):
        c = {}; inject(c)
    import json; print(json.dumps(c))     # save these headers
    PY
    ```

    Obtenés, por ejemplo: `{"x-b3-traceid": "...", "x-b3-spanid": "...", "x-b3-sampled": "1"}`

2. Alimentá esos headers exactos a un servicio configurado para **solo W3C** y observá cómo se corta el link:

    ```bash
    OTEL_PROPAGATORS=tracecontext python - <<'PY'
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.propagate import extract
    trace.set_tracer_provider(TracerProvider())
    incoming = {"x-b3-traceid": "8f2e...", "x-b3-spanid": "aa11...", "x-b3-sampled": "1"}
    ctx = extract(incoming)
    with trace.get_tracer("orders").start_as_current_span("orders", context=ctx) as s:
        p = getattr(s, "parent", None)
        print("parent linked:", p is not None)      # False -> NEW ROOT -> snapped
    PY
    ```

    Salida: `parent linked: False`. El extractor `tracecontext` nunca mira los headers `x-b3-*`, así que devuelve un context vacío y `orders` inicia una trace nueva.

3. Recorré la escalera de diagnóstico, de arriba hacia abajo, deteniéndote en el primer "no":

    1. **¿Está el header en el cable, siquiera?** `curl -v` o un access log de proxy — confirmá que un header `traceparent` (o `b3`) efectivamente sale del gateway.
    2. **¿Ambos lados coinciden en el formato?** Compará `OTEL_PROPAGATORS` en cada servicio. (Esta es la falla acá.)
    3. **¿Un proxy lo eliminó?** Algunas configuraciones de ingress/WAF descartan headers desconocidos — revisá la allow-list.
    4. **¿Está instrumentado el client?** Un client HTTP sin instrumentar nunca llama a `inject`; el header simplemente está ausente.

4. **Arreglalo** alineando los propagators. Configurá ambos servicios con un superconjunto que cubra la migración:

    ```bash
    OTEL_PROPAGATORS=tracecontext,b3multi
    ```

    Volvé a ejecutar el paso 2 con este valor y confirmá `parent linked: True`.

**Comprobá lo que entendiste**

- Q6.1 — El síntoma fue "un request lógico aparece como dos traces". ¿Cuál es la causa raíz precisa, en términos de lo que `extract` devolvió?
- Q6.2 — Ordená las comprobaciones de diagnóstico del paso 3 de la más barata a la más cara de verificar, y justificá por qué "comparar `OTEL_PROPAGATORS`" vale la pena hacerlo temprano aunque no sea la primera.
- Q6.3 — El arreglo seteó `tracecontext,b3multi` en *ambos* servicios. Explicá por qué listar *ambos* propagators es seguro (sin doble conteo de spans) y qué hace ahora cada lado en el inject y en el extract.
- Q6.4 — Dá una clase de falla de snapped-trace que alinear `OTEL_PROPAGATORS` **no** arreglaría, y nombrá la capa donde mirarías en su lugar.

---

<details>
<summary><strong>Clave de respuestas — expandí después de intentar todos los ejercicios</strong></summary>

### Ejercicio 1 — El objeto Context

- **A1.1** — El `Context` es **inmutable**: `set_baggage` (y toda escritura) devuelve un Context completamente nuevo que no comparte nada mutable con su parent, así que `ctx_a` y `ctx_b` son snapshots independientes de `root`. Esto es esencial para la concurrencia porque miles de requests en vuelo tienen cada uno su propio Context; si una escritura en el context de un request pudiera filtrarse al de otro, obtendrías corrupción de traces cruzada entre requests (un span del request X parentado bajo el request Y). La inmutabilidad hace que compartir context entre tareas sea seguro por construcción. (Spec: https://opentelemetry.io/docs/specs/otel/context/)
- **A1.2** — `attach()` establece un nuevo Context *current* y devuelve un **token** que representa el context que era current *antes* del attach. `detach(token)` restaura ese context previo. Si nunca hacés detach, el context nunca se desapila: las operaciones subsiguientes en esa unidad de ejecución heredan baggage/parent spans obsoletos, produciendo spans mal parentados y baggage filtrado. El token es el handle de deshacer (undo) del SDK.
- **A1.3** — `attach`/`detach` modelan una **stack**. Cada `attach` apila (push); cada `detach` debería desapilar (pop) la cima. Hacer detach de un token más bajo primero (`t1` antes que `t2`) deja la stack inconsistente — el runtime no puede restaurar correctamente los estados intermedios, así que obtenés un warning y/o un context "current" que no coincide con lo que esperás. Desapilá siempre en orden Last-In-First-Out (que los bloques `with` y try/finally te dan gratis).
- **A1.4** — La especificación exige que el Context se propague **implícitamente por unidad de ejecución** sin filtrarse entre unidades. En Python esto se implementa con **`contextvars.ContextVar`**, que es consciente de coroutines/threads: cada tarea async y thread ve su propio context current. (Otros lenguajes usan el equivalente: Go pasa `context.Context` explícitamente, Java usa thread-locals / Scope.)

### Ejercicio 2 — `traceparent` de W3C

- **A2.1** — El `trace-id` tiene **16 bytes** (128 bits → 32 caracteres hex); el `span-id` tiene **8 bytes** (64 bits → 16 caracteres hex). El trace-id de 128 bits es lo suficientemente grande como para que los ids generados aleatoriamente a lo largo de una flota global tengan una probabilidad de colisión despreciable, así que dos servicios cualesquiera pueden acuñar ids de forma independiente y aun así esperar unicidad — sin necesidad de un coordinador central. (Spec: https://www.w3.org/TR/trace-context/#trace-id)
- **A2.2** — `01` es `trace-flags` con el **bit 0 (el flag `sampled`) activado**, lo que significa que el caller registró/sampleó esta trace y le está señalando al downstream que haga lo mismo. `-00` significa *no sampleado*: el upstream no la registró, y un downstream que honre el flag tampoco la registraría — manteniendo una trace consistentemente sampleada o no sampleada de punta a punta. (Nota: los flags son una *sugerencia*; las decisiones de sampling dependen en última instancia del sampler configurado, por ejemplo `ParentBased`.)
- **A2.3** — Debe **usarlo igual**. La spec de W3C exige compatibilidad hacia adelante: una `version` superior desconocida se parsea como si fuera la versión más alta que la implementación entiende; el receptor lee los campos conocidos (trace-id, parent-id, flags) e ignora todo lo que venga después, en lugar de descartar el header. Descartarlo cortaría traces innecesariamente cada vez que el estándar evolucione. (Spec: https://www.w3.org/TR/trace-context/#versioning-of-traceparent)
- **A2.4** — `tracestate` lleva **información de posición específica de vendor / multi-vendor** como una lista ordenada de pares `key=value` (por ejemplo el propio span id de un vendor en su formato). Es un header separado de `traceparent` porque `traceparent` es una estructura fija, obligatoria y universalmente entendida, mientras que `tracestate` es de longitud variable, opcional y por vendor — mezclarlos rompería el parse simple y forward-compatible de `traceparent`. Además, `tracestate` sobrevive incluso cuando un salto no entiende la entrada de un vendor dado.

### Ejercicio 3 — inject / extract manual

- **A3.1** — `ctx` fue construido por `extract` a partir de los headers entrantes y por lo tanto contenía el **SpanContext remoto** (el trace-id y span-id del client) como su "current span". Pasarlo como `context=ctx` le indicó a `start_as_current_span` que usara ese span remoto como el **parent**, así que el nuevo span del server heredó el trace-id del client y apuntó su `parent` al span del client. El context current por defecto (un proceso fresco sin span activo) no tenía tal parent, y por eso omitir `context=ctx` produce un root.
- **A3.2** — `extract` devolvió un **Context vacío (root)** — específicamente un context cuyo current span es el span inválido/no-op. No es un error: la ausencia de un header `traceparent` es un caso legítimo y común (el primer servicio de una cadena, o un caller sin instrumentar). Sin un SpanContext parent válido, `start_as_current_span` correctamente inicia un nuevo root de trace. Devolver un error haría fallar a todo servicio de entrada (entry-point).
- **A3.3** — Un `TextMapPropagator` lee vía un **Getter** (`get(carrier, key)`, `keys(carrier)`) y escribe vía un **Setter** (`set(carrier, key, value)`). Cualquier carrier que pueda adaptarse a esas operaciones funciona — un mapa de HTTP headers, los headers de un record de Kafka, un objeto de metadata de gRPC, un mensaje AMQP. Este desacople es la razón por la que el *mismo* propagator serializa context sobre HTTP y sobre una cola de mensajes: el formato (traceparent) es fijo; solo el Getter/Setter cambia por transporte. (Spec: https://opentelemetry.io/docs/specs/otel/context/api-propagators/)
- **A3.4** — En un servicio real casi nunca llamás a `inject`/`extract` a mano — las **bibliotecas de instrumentación** lo hacen: el middleware del lado del server (por ejemplo la instrumentación de ASGI/WSGI/Flask/gRPC) llama a `extract` sobre el request entrante, y el **client** instrumentado de HTTP/gRPC/messaging llama a `inject` sobre el request saliente. Las llamadas manuales solo hacen falta para transportes custom o no soportados.

### Ejercicio 4 — Baggage

- **A4.1** — `traceparent` propaga **identidad de trace** (de qué trace/span formo parte — se usa para coser spans entre sí); **Baggage** propaga **datos clave/valor arbitrarios de la aplicación** (por ejemplo `user.tier`, `experiment.id`) para que los servicios downstream puedan leer business context. Identidad vs. datos.
- **A4.2** — La especificación **W3C Baggage** (https://www.w3.org/TR/baggage/) exige el percent-encoding de los caracteres que no están permitidos en el valor del header (espacios, comas, `=`, caracteres de control, etc.). Enviar un espacio o una coma crudos corrompería el parsing — las comas separan miembros de la lista y `=` separa la clave del valor, así que un valor sin codificar podría partirse en entradas espurias o truncarse.
- **A4.3** — (1) **Costo en bytes / rendimiento**: el baggage se agrega a *cada* header de request saliente durante el resto de la trace; un JWT de varios KB multiplica el ancho de banda y puede exceder los límites de tamaño de header de proxy/server (causando errores 431/400), y se paga en cada salto. (2) **Seguridad / PII y trust**: el baggage es texto plano, se reenvía a *cada* servicio downstream incluyendo los que están fuera de tu trust boundary o vendors de terceros, y se loguea con facilidad; poner credenciales o PII ahí las filtra ampliamente y puede habilitar token replay. El baggage debería contener únicamente pistas pequeñas y no sensibles de routing/experimentos.
- **A4.4** — **No.** Las entradas de Baggage *no* se copian automáticamente a los spans. Para registrarlas tenés que leer el baggage explícitamente y llamar a `span.set_attribute(...)`, típicamente vía un **`BaggageSpanProcessor`** o código manual. La separación es deliberada por privacidad y control de costos: dado que el baggage cruza trust boundaries y puede contener datos que *no* querés persistir en tu backend de telemetría, la spec hace de la escritura hacia los spans un acto explícito y opt-in en lugar de una filtración automática.

### Ejercicio 5 — Eligiendo propagators

- **A5.1** — El valor por defecto de la especificación para `OTEL_PROPAGATORS` es **`tracecontext,baggage`** — el propagator de W3C Trace Context más el propagator de W3C Baggage. (Ref: https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- **A5.2** — El extractor `tracecontext` de B busca únicamente un header `traceparent`. A envió solo headers `x-b3-*`, así que extract no encuentra ningún `traceparent`, devuelve un **context vacío**, y el span de entrada de B se convierte en un **nuevo root** — la trace se corta en dos traces desconectadas. No se lanza ningún error; el corte es silencioso.
- **A5.3** — Un composite propagator corre sus extractores **en el orden de la lista, cada uno escribiendo en el context**, así que un propagator *posterior* que encuentre un valor válido **sobrescribe** lo que uno anterior seteó (last-writer-wins para el current span). Con `tracecontext,b3multi,baggage`, si tanto `traceparent` como B3 están presentes y no coinciden, **gana el resultado de B3** porque `b3multi` corre después de `tracecontext`. La guía práctica: listá tu formato canónico **al final** para que tenga precedencia durante una migración.
- **A5.4** — Porque el formato del cable es una **preocupación transversal de transporte** (cross-cutting), no lógica de negocio. Moverlo a la capa del propagator significa que cambiás una variable de entorno por servicio para agregar/quitar un formato, desplegás el cambio gradualmente, y corrés ambos formatos simultáneamente durante el cutover — con cero cambios en la instrumentación o el código de la aplicación, y reversible al instante. Bifurcar el código de instrumentación acoplaría el formato a la lógica, requeriría redeploys para cambiar, y sería mucho más difícil de revertir.

### Ejercicio 6 — Diagnosticando un snapped trace

- **A6.1** — Causa raíz: **desajuste de formato de propagator**. El gateway inyectó headers B3 (`x-b3-*`), pero `orders` estaba configurado solo con `tracecontext`, cuyo extractor ignora los `x-b3-*`. Por lo tanto `extract` devolvió un **context vacío** (sin SpanContext parent válido), así que `orders` inició un **nuevo root span** y su trace-id divergió del gateway — un request lógico renderizado como dos traces.
- **A6.2** — De la más barata a la más cara: (1) **Comparar `OTEL_PROPAGATORS`** en ambos servicios — un diff de config/env, sin necesidad de tráfico, y explica directamente un corte *silencioso y consistente*, razón por la cual vale la pena revisarlo muy temprano. (2) **Revisar el header en el cable** (`curl -v` / log de proxy) — necesita un request pero es rápido. (3) **Revisar si un proxy elimina el header** — necesita acceso a la config del proxy y posiblemente un request de prueba. (4) **Verificar que el client esté instrumentado** — puede requerir inspección de código/deploy. El diff de config y la revisión en el cable son ambos casi gratis; poné el diff de config temprano porque un desajuste se reproduce el 100% de las veces mientras que un header eliminado ocasionalmente no.
- **A6.3** — Listar `tracecontext,b3multi` en ambos lados **no** crea spans duplicados, porque los propagators solo **serializan/deserializan context** — nunca inician spans. En el **inject**, cada lado escribe *ambos* un header `traceparent` y headers `x-b3-*` (mismo trace-id, apenas dos codificaciones). En el **extract**, cada lado prueba ambos extractores y enlaza la trace a partir del header que esté presente, así que un caller que hable cualquiera de los dos dialectos es entendido. Este es exactamente el superconjunto seguro para una flota mixta durante la migración.
- **A6.4** — Alinear los propagators **no** arregla un corte donde el header **nunca sale del caller** o es **eliminado en tránsito** — por ejemplo un client HTTP sin instrumentar que nunca llama a `inject`, o un proxy de ingress/WAF/service-mesh que descarta headers desconocidos de su allow-list. Ahí el trace-id está ausente en el cable sin importar el formato, así que mirás la **capa de instrumentación** (¿está instrumentada la biblioteca del client y se está llamando a `inject`?) o la **capa de red/proxy** (allow-list de headers, config de propagación de headers del mesh), no `OTEL_PROPAGATORS`.

</details>