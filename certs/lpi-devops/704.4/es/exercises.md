# Tema 704.4 — Trazado (Tracing)
### Ejercicios guiados — LPI DevOps Tools Engineer, examen 701-100 (v2.0.0) · peso del examen 3.33

> **Qué construís.** Un plano completo de trazado distribuido: un backend Jaeger, un gateway OpenTelemetry Collector y una aplicación Python de dos servicios cuyo contexto de traza se propaga sobre HTTP. Vas a armar payloads OTLP a mano con `curl`, decodificar cabeceras `traceparent` byte a byte, configurar muestreo head-based y tail-based, correlacionar logs con trazas y diagnosticar una regresión de latencia únicamente a partir de los tiempos de los spans.
>
> **Programa de referencia:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

---

## 0. Prerrequisitos del laboratorio

1. Verificá tu herramental. Todos los ejercicios de abajo asumen que esto está en el `PATH`:

   ```bash
   docker --version && docker compose version
   python3 --version
   jq --version
   curl --version | head -1
   openssl version
   ```

   Esperado (las versiones van a diferir):

   ```
   Docker version 27.3.1, build ce12230
   Docker Compose version v2.30.3
   Python 3.12.7
   jq-1.7.1
   curl 8.9.1 (x86_64-pc-linux-gnu) libcurl/8.9.1 OpenSSL/3.3.2 ...
   OpenSSL 3.3.2 3 Sep 2024
   ```

2. Creá el árbol del laboratorio:

   ```bash
   mkdir -p ~/otel-lab/{frontend,backend,collector}
   cd ~/otel-lab
   ```

3. Creá el virtualenv de Python e instalá la distro de OpenTelemetry:

   ```bash
   python3 -m venv .venv
   . .venv/bin/activate
   pip install --quiet "flask==3.0.*" "requests==2.32.*" \
       "opentelemetry-distro==0.50b0" "opentelemetry-exporter-otlp==1.29.0"
   opentelemetry-bootstrap -a install
   ```

   `opentelemetry-bootstrap` escanea las bibliotecas que tenés instaladas y descarga los paquetes de instrumentación correspondientes (`opentelemetry-instrumentation-flask`, `-requests`, `-wsgi`, `-logging`, …). Confirmá:

   ```bash
   pip list 2>/dev/null | grep -E 'opentelemetry-(instrumentation-(flask|requests|logging)|sdk|exporter-otlp-proto-http)\b'
   ```

   ```
   opentelemetry-exporter-otlp-proto-http     1.29.0
   opentelemetry-instrumentation-flask        0.50b0
   opentelemetry-instrumentation-logging      0.50b0
   opentelemetry-instrumentation-requests     0.50b0
   opentelemetry-sdk                          1.29.0
   ```

> **Q0.1** — `opentelemetry-distro` y `opentelemetry-sdk` llevan números de versión distintos (`0.50b0` vs `1.29.0`) y sin embargo deben instalarse juntos. ¿Cuál es la regla de versionado del proyecto OpenTelemetry para Python, y qué se rompe si los mezclás?
>
> **Q0.2** — ¿Por qué la auto-instrumentación se distribuye como un paquete *por biblioteca* (`-flask`, `-requests`) en lugar de un paquete para el lenguaje?

---

## Ejercicio 1 — Decodificar W3C Trace Context a mano

El formato de cable es el contrato entre servicios escritos en lenguajes distintos por equipos distintos. Aprendelo antes de dejar que un SDK lo genere por vos.

1. Tomá la cabecera canónica de la especificación y separala:

   ```bash
   TP='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
   IFS='-' read -r VERSION TRACE_ID PARENT_ID FLAGS <<<"$TP"
   printf 'version   = %s\ntrace-id  = %s (%d hex chars)\nparent-id = %s (%d hex chars)\nflags     = %s -> sampled=%d\n' \
     "$VERSION" "$TRACE_ID" "${#TRACE_ID}" "$PARENT_ID" "${#PARENT_ID}" "$FLAGS" "$(( 0x$FLAGS & 1 ))"
   ```

   ```
   version   = 00
   trace-id  = 4bf92f3577b34da6a3ce929d0e0e4736 (32 hex chars)
   parent-id = 00f067aa0ba902b7 (16 hex chars)
   flags     = 01 -> sampled=1
   ```

2. Generá un par nuevo y válido de identificadores tal como lo hace un SDK — 16 bytes aleatorios para la traza, 8 para el span:

   ```bash
   openssl rand -hex 16   # trace-id
   openssl rand -hex 8    # span-id
   ```

   ```
   9f2b7c0e4a6d18335e7b1c9d0a4f6e21
   3c81f0a97b2d4e65
   ```

3. Inspeccioná las dos cabeceras acompañantes. Creálas a mano y notá la diferencia estructural:

   ```bash
   TRACESTATE='vendorA=t61rcWkgMzE,vendorB=00f067aa0ba902b7'
   BAGGAGE='userId=alice,tier=gold,region=eu-west-1'
   echo "$TRACESTATE" | tr ',' '\n' | nl
   echo "$BAGGAGE"    | tr ',' '\n' | nl
   ```

   ```
        1  vendorA=t61rcWkgMzE
        2  vendorB=00f067aa0ba902b7
        1  userId=alice
        2  tier=gold
        3  region=eu-west-1
   ```

4. Demostrá que el formato se valida, no solo se parsea. Construí tres cabeceras malformadas y razoná sobre cada una *antes* de que ninguna herramienta las vea:

   ```bash
   printf '%s\n' \
     '00-00000000000000000000000000000000-00f067aa0ba902b7-01' \
     '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01' \
     '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01'
   ```

> **Q1.1** — ¿Cuántos bytes ocupan el `trace-id` y el `span-id`, y cómo se codifican en el cable? ¿Por qué se usa un trace-id de 128 bits cuando uno de 64 bits produciría cabeceras mucho más cortas?
>
> **Q1.2** — Cada una de las tres cabeceras del paso 4 es inválida. Indicá el defecto de cada una y describí qué debe hacer un receptor conforme cuando recibe una.
>
> **Q1.3** — `trace-flags` vale `01`. ¿Qué bit es ese, qué significa, y un valor de `00` significa "no propagar la cabecera"?
>
> **Q1.4** — `tracestate` y `baggage` son ambas listas de clave/valor separadas por comas que viajan con cada request. ¿Cuál es la diferencia semántica, y cuál de las dos usarías para llevar `userId=alice` a un servicio downstream?
>
> **Q1.5** — Tu equipo de plataforma quiere poner el e-mail del cliente en `baggage` para que todos los servicios puedan loguearlo. Dá las dos razones independientes para rechazarlo.

---

## Ejercicio 2 — Un backend de trazado, y OTLP sin SDK

2. Escribí el archivo compose del backend:

   ```bash
   cat > ~/otel-lab/compose.yaml <<'EOF'
   name: otel-lab

   services:
     jaeger:
       image: jaegertracing/all-in-one:1.62.0
       container_name: jaeger
       environment:
         COLLECTOR_OTLP_ENABLED: "true"
         SPAN_STORAGE_TYPE: memory
       ports:
         - "16686:16686"   # Jaeger UI + query API
         - "14269:14269"   # admin / health
         - "4317:4317"     # OTLP gRPC
         - "4318:4318"     # OTLP HTTP
   EOF
   ```

   > Jaeger v2 (`jaegertracing/jaeger:2.x`) es el sucesor y está construido sobre el propio OpenTelemetry Collector; expone el mismo puerto de UI `16686` y los mismos puertos OTLP, así que todo lo que sigue se traslada sin cambios. La imagen all-in-one v1 se fija acá porque sus flags son estables y están bien documentadas.

3. Arrancalo y confirmá la salud:

   ```bash
   cd ~/otel-lab && docker compose up -d
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:16686/
   curl -s http://localhost:14269/ | jq '.status'
   ```

   ```
   200
   "Server available"
   ```

4. Confirmá que el almacén está vacío — todavía no hay ningún servicio registrado:

   ```bash
   curl -s 'http://localhost:16686/api/services' | jq
   ```

   ```json
   {
     "data": null,
     "total": 0,
     "limit": 0,
     "offset": 0,
     "errors": null
   }
   ```

5. Emití un span a mano sobre **OTLP/HTTP con codificación JSON** — sin SDK, sin agente, solo `curl`:

   ```bash
   TRACE_ID=$(openssl rand -hex 16)
   SPAN_ID=$(openssl rand -hex 8)
   START=$(date +%s%N)
   END=$(( START + 250000000 ))   # +250 ms

   curl -i -X POST http://localhost:4318/v1/traces \
     -H 'Content-Type: application/json' \
     -d @- <<EOF
   {
     "resourceSpans": [{
       "resource": {
         "attributes": [
           { "key": "service.name",                "value": { "stringValue": "curl-demo" } },
           { "key": "service.version",             "value": { "stringValue": "0.1.0" } },
           { "key": "deployment.environment.name", "value": { "stringValue": "lab" } }
         ]
       },
       "scopeSpans": [{
         "scope": { "name": "manual/curl", "version": "1.0.0" },
         "spans": [{
           "traceId": "$TRACE_ID",
           "spanId": "$SPAN_ID",
           "name": "GET /checkout",
           "kind": 2,
           "startTimeUnixNano": "$START",
           "endTimeUnixNano": "$END",
           "attributes": [
             { "key": "http.request.method",      "value": { "stringValue": "GET" } },
             { "key": "url.path",                 "value": { "stringValue": "/checkout" } },
             { "key": "http.response.status_code","value": { "intValue": "200" } }
           ],
           "status": { "code": 1 }
         }]
       }]
     }]
   }
   EOF
   ```

   ```
   HTTP/1.1 200 OK
   Content-Type: application/json
   Content-Length: 21

   {"partialSuccess":{}}
   ```

6. Agregá un span **hijo** a la misma traza. Reutilizá `$TRACE_ID`, referenciá `$SPAN_ID` como padre y marcalo como `kind: 3` (CLIENT):

   ```bash
   CHILD_ID=$(openssl rand -hex 8)
   CSTART=$(( START + 40000000 ))
   CEND=$(( START + 210000000 ))

   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4318/v1/traces \
     -H 'Content-Type: application/json' \
     -d @- <<EOF
   {
     "resourceSpans": [{
       "resource": { "attributes": [
         { "key": "service.name", "value": { "stringValue": "curl-demo" } } ] },
       "scopeSpans": [{
         "scope": { "name": "manual/curl" },
         "spans": [{
           "traceId": "$TRACE_ID",
           "spanId": "$CHILD_ID",
           "parentSpanId": "$SPAN_ID",
           "name": "SELECT inventory",
           "kind": 3,
           "startTimeUnixNano": "$CSTART",
           "endTimeUnixNano": "$CEND",
           "attributes": [
             { "key": "db.system.name",     "value": { "stringValue": "postgresql" } },
             { "key": "db.collection.name", "value": { "stringValue": "inventory" } }
           ],
           "status": { "code": 0 }
         }]
       }]
     }]
   }
   EOF
   ```

7. Recuperá la traza a través de la API HTTP de Jaeger:

   ```bash
   curl -s 'http://localhost:16686/api/services' | jq -c '.data'
   curl -s "http://localhost:16686/api/traces/${TRACE_ID}" \
     | jq '.data[0].spans[] | {spanID, operationName, duration, refs: [.references[]?.spanID]}'
   ```

   ```
   ["curl-demo"]
   ```
   ```json
   {
     "spanID": "b3d1e4a70c295f18",
     "operationName": "GET /checkout",
     "duration": 250000,
     "refs": []
   }
   {
     "spanID": "6c2a90f4d5e11b73",
     "operationName": "SELECT inventory",
     "duration": 170000,
     "refs": ["b3d1e4a70c295f18"]
   }
   ```

8. Abrí <http://localhost:16686/>, buscá el servicio `curl-demo` y abrí la traza. Deberías ver una cascada de dos niveles, con el hijo desplazado 40 ms respecto del inicio del padre.

> **Q2.1** — En el payload JSON, `startTimeUnixNano` e `intValue` son strings entrecomillados mientras que `kind` es un número pelado. ¿Por qué? ¿Qué haría un collector estricto si mandaras `"startTimeUnixNano": 1735689600000000000` sin comillas?
>
> **Q2.2** — La respuesta fue `200` con el cuerpo `{"partialSuccess":{}}`. ¿Qué significa un `partialSuccess` vacío, y cómo se vería uno *no vacío*? ¿Por qué esto es mejor que un `200` pelado?
>
> **Q2.3** — `service.name` va bajo `resource`, mientras que `http.request.method` va bajo el span. ¿Cuál es la regla que decide dónde corresponde un atributo, y qué muestra un backend cuando `service.name` falta por completo?
>
> **Q2.4** — Pusiste `"kind": 2` en el padre y `"kind": 3` en el hijo. Mapeá los valores numéricos 0–5 a sus nombres, y explicá por qué el span kind — y no solo el vínculo padre/hijo — es lo que le permite a un backend dibujar un grafo de dependencias de servicios.
>
> **Q2.5** — El padre tenía `"status": {"code": 1}` y el hijo `{"code": 0}`. ¿Cuáles son los tres códigos de estado, y por qué `UNSET` es el default correcto en lugar de `OK`?
>
> **Q2.6** — `duration` volvió como `250000`, no `250000000`. ¿Qué unidad usa la API de Jaeger, y qué clase de bug provoca este desajuste de unidades cuando la gente escribe dashboards contra APIs mezcladas?

---

## Ejercicio 3 — Auto-instrumentación y propagación de contexto a través de un límite de proceso

1. Escribí el servicio downstream. Loguea el `traceparent` entrante para que la propagación sea visible sin una UI:

   ```bash
   cat > ~/otel-lab/backend/app.py <<'EOF'
   import logging
   import random
   import time

   from flask import Flask, abort, jsonify, request

   logging.basicConfig(level=logging.INFO)
   app = Flask(__name__)


   @app.get("/inventory")
   def inventory():
       app.logger.info(
           "inbound traceparent=%s baggage=%s",
           request.headers.get("traceparent"),
           request.headers.get("baggage"),
       )
       time.sleep(random.uniform(0.02, 0.08))
       if random.random() < 0.25:
           abort(503, description="warehouse unreachable")
       return jsonify({"sku": "SKU-42", "available": 7})
   EOF
   ```

2. Escribí el servicio upstream:

   ```bash
   cat > ~/otel-lab/frontend/app.py <<'EOF'
   import logging
   import os

   import requests
   from flask import Flask, jsonify

   logging.basicConfig(level=logging.INFO)
   app = Flask(__name__)
   BACKEND = os.environ.get("BACKEND_URL", "http://127.0.0.1:8081")


   @app.get("/checkout")
   def checkout():
       response = requests.get(f"{BACKEND}/inventory", timeout=5)
       response.raise_for_status()
       return jsonify({"status": "ok", "inventory": response.json()})
   EOF
   ```

3. Arrancá el backend bajo auto-instrumentación, en su propia terminal:

   ```bash
   cd ~/otel-lab/backend && . ../.venv/bin/activate
   export OTEL_SERVICE_NAME=backend
   export OTEL_RESOURCE_ATTRIBUTES='service.namespace=shop,deployment.environment.name=lab'
   export OTEL_TRACES_EXPORTER=otlp
   export OTEL_METRICS_EXPORTER=none
   export OTEL_LOGS_EXPORTER=none
   export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
   export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
   export OTEL_PROPAGATORS=tracecontext,baggage
   opentelemetry-instrument flask --app app run --port 8081
   ```

4. Arrancá el frontend de la misma manera en una segunda terminal, cambiando solo el nombre del servicio:

   ```bash
   cd ~/otel-lab/frontend && . ../.venv/bin/activate
   export OTEL_SERVICE_NAME=frontend
   export OTEL_RESOURCE_ATTRIBUTES='service.namespace=shop,deployment.environment.name=lab'
   export OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none
   export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
   export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
   export OTEL_PROPAGATORS=tracecontext,baggage
   export BACKEND_URL=http://127.0.0.1:8081
   opentelemetry-instrument flask --app app run --port 8080
   ```

5. Generá tráfico y mirá la terminal del backend:

   ```bash
   for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8080/checkout; done; echo
   ```

   ```
   200 200 500 200 200 200 200 500 200 200
   ```

   Log del backend:

   ```
   INFO:app:inbound traceparent=00-7d1f0c4a9b2e8536ad0e5f731c4b9a02-4f61b0c2d3a97e15-01 baggage=None
   INFO:werkzeug:127.0.0.1 - - [03/Sep/2026 11:42:07] "GET /inventory HTTP/1.1" 200 -
   ```

   Ni una línea de código de aplicación menciona tracing, y sin embargo la cabecera está ahí.

6. Confirmá que la traza abarca ambos servicios:

   ```bash
   curl -s 'http://localhost:16686/api/services' | jq -c '.data'
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=5m&limit=1' \
     | jq '.data[0].spans[] | {svc: .processID, operationName, duration, kind: (.tags[] | select(.key=="span.kind") | .value)}'
   ```

   ```
   ["backend","curl-demo","frontend"]
   ```
   ```json
   { "svc": "p1", "operationName": "GET /checkout",  "duration": 71204, "kind": "server" }
   { "svc": "p1", "operationName": "GET",            "duration": 66980, "kind": "client" }
   { "svc": "p2", "operationName": "GET /inventory", "duration": 61533, "kind": "server" }
   ```

7. Ahora *sumate* a una traza existente desde afuera. Proporcioná tu propio `traceparent` y confirmá que la aplicación lo adopta:

   ```bash
   MYTRACE=$(openssl rand -hex 16)
   curl -s -o /dev/null -H "traceparent: 00-${MYTRACE}-$(openssl rand -hex 8)-01" \
        -H 'baggage: userId=alice,tier=gold' http://127.0.0.1:8080/checkout
   sleep 3
   curl -s "http://localhost:16686/api/traces/${MYTRACE}" | jq '.data[0].spans | length'
   ```

   ```
   3
   ```

8. Rompé la propagación deliberadamente. Reiniciá **solo el frontend** con un propagador incompatible y repetí el paso 5:

   ```bash
   # frontend terminal: Ctrl-C, then
   export OTEL_PROPAGATORS=b3multi
   opentelemetry-instrument flask --app app run --port 8080
   ```

   ```
   INFO:app:inbound traceparent=None baggage=None
   ```

   Buscá la traza en la UI: en lugar de una traza de tres spans ahora tenés dos trazas desconectadas.

> **Q3.1** — Ninguna línea de `frontend/app.py` importa OpenTelemetry, y sin embargo una cabecera `traceparent` llegó al backend. Nombrá las dos instrumentaciones distintas involucradas e indicá con precisión cuál inyectó la cabecera.
>
> **Q3.2** — En el paso 6 el frontend produjo *dos* spans para un solo request (`server` y después `client`) mientras que el backend produjo uno. ¿Por qué el span client no es redundante con el span server del backend? ¿Qué mide la diferencia entre sus duraciones?
>
> **Q3.3** — En el paso 8 el frontend emitió cabeceras B3 y el backend solo leía `traceparent`. El backend igual produjo spans válidos y la aplicación igual devolvió `200`. Explicá por qué un desajuste de propagadores es una falla *silenciosa*, y nombrá dos maneras de detectarlo en producción.
>
> **Q3.4** — `OTEL_EXPORTER_OTLP_ENDPOINT` está en `http://localhost:4318` sin path, pero las trazas OTLP/HTTP se reciben en `/v1/traces`. ¿Qué hace el SDK, y en qué se diferencia esto de `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`? ¿Cuál es el valor equivalente cuando `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`?
>
> **Q3.5** — `OTEL_PROPAGATORS=tracecontext,baggage` lista dos valores. ¿Es una cadena de fallback o un compuesto? ¿Cuál es el efecto sobre el request saliente, y qué configurarías durante una migración desde una flota Zipkin/B3 heredada?
>
> **Q3.6** — En el paso 7 la traza continuó a partir de un ID que inventaste en la línea de comandos. ¿Cuál es el valor operativo de esto, y cuál es la consecuencia de seguridad de aceptar `traceparent` de un cliente no confiable en el borde?

---

## Ejercicio 4 — Instrumentación manual: spans personalizados, atributos, eventos, errores

La auto-instrumentación te da la cañería. El significado de negocio hay que escribirlo.

1. Reescribí el frontend para agregar un span de dominio alrededor de un chequeo de fraude:

   ```bash
   cat > ~/otel-lab/frontend/app.py <<'EOF'
   import logging
   import os
   import random

   import requests
   from flask import Flask, jsonify
   from opentelemetry import trace
   from opentelemetry.trace import SpanKind, Status, StatusCode

   logging.basicConfig(level=logging.INFO)
   app = Flask(__name__)
   tracer = trace.get_tracer("shop.frontend", "0.2.0")
   BACKEND = os.environ.get("BACKEND_URL", "http://127.0.0.1:8081")


   def fraud_check(order_id: str) -> bool:
       with tracer.start_as_current_span("fraud.check", kind=SpanKind.INTERNAL) as span:
           span.set_attribute("shop.order.id", order_id)
           span.set_attribute("shop.rule_set.version", "2026-08")
           span.add_event("rules.loaded", {"shop.rule.count": 47})
           score = random.random()
           span.set_attribute("shop.fraud.score", score)
           if score > 0.9:
               span.set_status(Status(StatusCode.ERROR, "fraud score above threshold"))
               return False
           return True


   @app.get("/checkout")
   def checkout():
       span = trace.get_current_span()
       order_id = f"ord-{random.randint(1000, 9999)}"
       span.set_attribute("shop.order.id", order_id)

       if not fraud_check(order_id):
           span.set_status(Status(StatusCode.ERROR, "order rejected"))
           return jsonify({"status": "rejected", "order": order_id}), 402

       try:
           response = requests.get(f"{BACKEND}/inventory", timeout=5)
           response.raise_for_status()
       except requests.RequestException as exc:
           span.record_exception(exc)
           span.set_status(Status(StatusCode.ERROR, "inventory lookup failed"))
           raise

       return jsonify({"status": "ok", "order": order_id, "inventory": response.json()})
   EOF
   ```

2. Reiniciá el frontend (con `OTEL_PROPAGATORS=tracecontext,baggage` restaurado) y generá tráfico hasta obtener tanto un `402` como un `500`:

   ```bash
   for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8080/checkout; done; echo
   ```

   ```
   200 200 500 200 402 200 200 200 500 200 200 200 200 402 200 ...
   ```

3. Recuperá una traza con error e inspeccioná el portador del error:

   ```bash
   curl -s 'http://localhost:16686/api/traces?service=frontend&tags=%7B%22error%22%3A%22true%22%7D&lookback=10m&limit=1' \
     | jq '.data[0].spans[] | {operationName,
             tags: [.tags[] | select(.key|test("otel.status|error|shop\\.")) | {key, value}],
             logs: [.logs[]? | {fields: [.fields[] | {key, value}]}]}'
   ```

   ```json
   {
     "operationName": "fraud.check",
     "tags": [
       { "key": "shop.order.id", "value": "ord-7741" },
       { "key": "shop.rule_set.version", "value": "2026-08" },
       { "key": "shop.fraud.score", "value": 0.9634 },
       { "key": "otel.status_code", "value": "ERROR" },
       { "key": "otel.status_description", "value": "fraud score above threshold" },
       { "key": "error", "value": true }
     ],
     "logs": [
       { "fields": [ { "key": "event", "value": "rules.loaded" },
                     { "key": "shop.rule.count", "value": 47 } ] }
     ]
   }
   ```

4. Inspeccioná un span que lleva una excepción registrada (el camino del `500`):

   ```bash
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=10m&limit=20' \
     | jq -r '.data[].spans[].logs[]?.fields[] | select(.key=="exception.type") | .value' | sort -u
   ```

   ```
   requests.exceptions.HTTPError
   ```

5. Contá cuántos nombres de operación distintos reporta ahora el frontend:

   ```bash
   curl -s 'http://localhost:16686/api/operations?service=frontend' | jq -c '.data'
   ```

   ```
   ["GET","GET /checkout","fraud.check"]
   ```

> **Q4.1** — `shop.order.id` se estableció como *atributo* del span, mientras que `rules.loaded` se registró como *evento* del span. Dá la regla que decide entre los dos, y explicá por qué un evento de span no es lo mismo que una línea de log aunque Jaeger lo renderice bajo `logs`.
>
> **Q4.2** — Los nombres de operación se mantuvieron en tres (paso 5) aunque pasaron miles de IDs de orden distintos. ¿Qué habría pasado si `fraud.check` se hubiese llamado `f"fraud.check {order_id}"`, y cuál es el nombre general de esta falla?
>
> **Q4.3** — `set_status(StatusCode.ERROR)` produjo `otel.status_code=ERROR` *y* `error=true` en Jaeger. ¿Cuál de los dos es el concepto de OpenTelemetry y cuál es la convención propia del backend? ¿Por qué importa esta distinción cuando escribís consultas de alertado?
>
> **Q4.4** — En el camino de falla se llamó tanto a `record_exception()` como a `set_status(ERROR)`. ¿Alguno implica al otro? ¿Qué perdés si llamás solo a uno?
>
> **Q4.5** — Todo atributo personalizado lleva el prefijo `shop.`. ¿Cuál es la regla de nomenclatura de las convenciones semánticas de OpenTelemetry, y por qué nunca hay que inventar un atributo bajo los prefijos `http.`, `db.` u `otel.`?
>
> **Q4.6** — La orden se procesa asincrónicamente por un worker que consume un mensaje de cola escrito durante este request. Ahí una referencia padre/hijo es incorrecta. ¿Qué construcción de span expresa "causado por, pero no anidado dentro", y por qué la necesita un consumidor por lotes?

---

## Ejercicio 5 — El OpenTelemetry Collector como gateway

Las aplicaciones no deberían conocer la dirección de tu proveedor de observabilidad, ni reintentar en su nombre, ni ser depositarias de la confianza para redactar PII.

1. Escribí la configuración del collector:

   ```bash
   cat > ~/otel-lab/collector/config.yaml <<'EOF'
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     memory_limiter:
       check_interval: 1s
       limit_percentage: 75
       spike_limit_percentage: 15

     attributes/scrub:
       actions:
         - key: http.request.header.authorization
           action: delete
         - key: shop.order.id
           action: hash

     resource/env:
       attributes:
         - key: deployment.environment.name
           value: lab
           action: upsert
         - key: k8s.cluster.name
           value: lab-local
           action: insert

     batch:
       timeout: 5s
       send_batch_size: 512
       send_batch_max_size: 1024

   exporters:
     otlp/jaeger:
       endpoint: jaeger:4317
       tls:
         insecure: true
       retry_on_failure:
         enabled: true
         initial_interval: 5s
         max_elapsed_time: 300s
       sending_queue:
         enabled: true
         queue_size: 5000
     debug:
       verbosity: normal

   extensions:
     health_check:
       endpoint: 0.0.0.0:13133

   service:
     extensions: [health_check]
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, resource/env, attributes/scrub, batch]
         exporters: [otlp/jaeger, debug]
     telemetry:
       logs:
         level: info
   EOF
   ```

2. Agregá el collector a compose y quitale los puertos OTLP a Jaeger, para que el único ingreso sea el gateway:

   ```bash
   cat > ~/otel-lab/compose.yaml <<'EOF'
   name: otel-lab

   services:
     jaeger:
       image: jaegertracing/all-in-one:1.62.0
       container_name: jaeger
       environment:
         COLLECTOR_OTLP_ENABLED: "true"
         SPAN_STORAGE_TYPE: memory
       ports:
         - "16686:16686"
         - "14269:14269"

     otel-collector:
       image: otel/opentelemetry-collector-contrib:0.115.0
       container_name: otel-collector
       command: ["--config=/etc/otelcol/config.yaml"]
       volumes:
         - ./collector/config.yaml:/etc/otelcol/config.yaml:ro
       ports:
         - "4317:4317"
         - "4318:4318"
         - "13133:13133"
       depends_on:
         - jaeger
   EOF
   ```

3. Validá la configuración *antes* de desplegarla — el collector puede chequear una config sin arrancar un pipeline:

   ```bash
   docker run --rm -v ~/otel-lab/collector/config.yaml:/etc/otelcol/config.yaml:ro \
     otel/opentelemetry-collector-contrib:0.115.0 validate --config=/etc/otelcol/config.yaml
   echo "exit=$?"
   ```

   ```
   exit=0
   ```

4. Desplegalo y chequeá la salud:

   ```bash
   cd ~/otel-lab && docker compose up -d
   sleep 3
   curl -s http://localhost:13133/ | jq -c '{status, upSince}'
   docker compose logs otel-collector | grep -E 'Everything is ready|Starting GRPC|Starting HTTP'
   ```

   ```json
   {"status":"Server available","upSince":"2026-09-03T11:58:02.114Z"}
   ```
   ```
   otel-collector  | info otlpreceiver@v0.115.0/otlp.go:102 Starting GRPC server {"endpoint": "0.0.0.0:4317"}
   otel-collector  | info otlpreceiver@v0.115.0/otlp.go:152 Starting HTTP server {"endpoint": "0.0.0.0:4318"}
   otel-collector  | info service@v0.115.0/service.go:261 Everything is ready. Begin running and processing data.
   ```

5. Las aplicaciones **no necesitan cambio alguno** — ya apuntan a `localhost:4318`. Mandá tráfico y observá el exporter `debug` del collector:

   ```bash
   for i in $(seq 1 5); do curl -s -o /dev/null http://127.0.0.1:8080/checkout; done
   docker compose logs --tail=20 otel-collector | grep -A3 'TracesExporter'
   ```

   ```
   otel-collector  | info TracesExporter {"resource spans": 2, "spans": 5}
   ```

6. Confirmá que el scrubbing efectivamente ocurrió — `shop.order.id` ya no debe ser legible:

   ```bash
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=2m&limit=1' \
     | jq -r '.data[0].spans[].tags[] | select(.key=="shop.order.id" or .key=="k8s.cluster.name") | "\(.key)=\(.value)"' | sort -u
   ```

   ```
   k8s.cluster.name=lab-local
   shop.order.id=9f18b4d0e4a1a0d1e8c3b6f2a7d59c4e2b1f0a7c...
   ```

7. Demostrá que lo que importa es el pipeline, no la definición. Quitá `attributes/scrub` de la lista `processors:` bajo `service.pipelines.traces` (dejá el bloque definido más arriba), reiniciá y volvé a correr el paso 6:

   ```bash
   sed -i 's/\[memory_limiter, resource\/env, attributes\/scrub, batch\]/[memory_limiter, resource\/env, batch]/' collector/config.yaml
   docker compose restart otel-collector && sleep 3
   for i in $(seq 1 3); do curl -s -o /dev/null http://127.0.0.1:8080/checkout; done; sleep 6
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=1m&limit=1' \
     | jq -r '.data[0].spans[].tags[] | select(.key=="shop.order.id") | .value' | sort -u
   ```

   ```
   ord-4188
   ```

   Restauralo antes de continuar:

   ```bash
   sed -i 's/\[memory_limiter, resource\/env, batch\]/[memory_limiter, resource\/env, attributes\/scrub, batch]/' collector/config.yaml
   docker compose restart otel-collector
   ```

> **Q5.1** — El paso 7 mostró un procesador `attributes/scrub` completamente definido y sintácticamente válido sin hacer nada. Enunciá la regla que esto demuestra, y explicá por qué el collector no te advirtió.
>
> **Q5.2** — `memory_limiter` va primero en la lista de procesadores y `batch` va último. Justificá cada posición. ¿Qué sale mal si ponés `batch` antes de `memory_limiter`?
>
> **Q5.3** — Los nombres son `otlp/jaeger`, `attributes/scrub`, `resource/env`. ¿Cuál es la sintaxis antes y después de la barra, y por qué el sufijo es obligatorio acá pero no para `batch`?
>
> **Q5.4** — La imagen es `opentelemetry-collector-**contrib**`, no `opentelemetry-collector`. ¿Cuál es la diferencia, qué componentes de esta config obligan al build contrib, y cuál es la alternativa de producción a distribuir contrib?
>
> **Q5.5** — Ahora las aplicaciones envían a un collector en lugar de directo a Jaeger. Enumerá cuatro capacidades que ganaste. ¿Cuáles de ellas *no* podrían haberse implementado en el SDK?
>
> **Q5.6** — Distinguí el despliegue del collector como **agent** (sidecar / DaemonSet) del despliegue como **gateway** (Deployment autónomo). ¿Cuál está corriendo acá, y qué te aporta una topología de dos niveles agent→gateway?
>
> **Q5.7** — `sending_queue` está habilitada con `queue_size: 5000` y es en memoria. ¿Qué pasa con esos spans cuando el pod del collector es desalojado, y cuál es la perilla de configuración que cambia esto?

---

## Ejercicio 6 — Muestreo: head-based, después tail-based

Trazar el 100% a volumen de producción es una factura de almacenamiento, no una estrategia.

1. Establecé una línea base. Reiniciá el **frontend** con un sampler explícito de siempre-activo y mandá 40 requests:

   ```bash
   # frontend terminal: Ctrl-C, then
   export OTEL_TRACES_SAMPLER=parentbased_always_on
   opentelemetry-instrument flask --app app run --port 8080
   ```
   ```bash
   for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:8080/checkout; done; sleep 8
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=1m&limit=500' | jq '.data | length'
   ```

   ```
   40
   ```

2. Cambiá a un sampler head-based de ratio 10% y repetí:

   ```bash
   # frontend terminal: Ctrl-C, then
   export OTEL_TRACES_SAMPLER=parentbased_traceidratio
   export OTEL_TRACES_SAMPLER_ARG=0.1
   opentelemetry-instrument flask --app app run --port 8080
   ```
   ```bash
   for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:8080/checkout; done; sleep 8
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=1m&limit=500' | jq '.data | length'
   ```

   ```
   5
   ```

3. Observá qué le pasa a la *cabecera* en un request no muestreado. Mirá la terminal del backend mientras fluye el tráfico:

   ```
   INFO:app:inbound traceparent=00-2c9a71f4e0b3d85617ff02a1c6e4d739-9a01c7d2f4e6b385-00 baggage=None
   INFO:app:inbound traceparent=00-8f4b13c7a92e60d5b1c0774e2a3f9d68-13c7e0a94f28b6d1-01 baggage=None
   ```

   Notá el `00` final versus el `01`.

4. Verificá que el backend **no** anula la decisión del frontend. Confirmá el sampler del backend:

   ```bash
   # backend terminal — this is the default, shown explicitly
   echo "$OTEL_TRACES_SAMPLER"
   ```

   ```
   parentbased_always_on
   ```

5. Ahora movés la decisión al collector. Reemplazá el muestreo head-based por tail-based: volvé a poner el frontend en `parentbased_always_on` (reinicialo) y después agregá el procesador:

   ```bash
   cat > ~/otel-lab/collector/config.yaml <<'EOF'
   receivers:
     otlp:
       protocols:
         grpc: { endpoint: 0.0.0.0:4317 }
         http: { endpoint: 0.0.0.0:4318 }

   processors:
     memory_limiter:
       check_interval: 1s
       limit_percentage: 75
       spike_limit_percentage: 15

     tail_sampling:
       decision_wait: 10s
       num_traces: 50000
       expected_new_traces_per_sec: 100
       policies:
         - name: keep-all-errors
           type: status_code
           status_code:
             status_codes: [ERROR]
         - name: keep-slow-requests
           type: latency
           latency:
             threshold_ms: 150
         - name: keep-vip-tenants
           type: string_attribute
           string_attribute:
             key: shop.tier
             values: [gold, platinum]
         - name: baseline-sample
           type: probabilistic
           probabilistic:
             sampling_percentage: 10

     batch:
       timeout: 5s
       send_batch_size: 512

   exporters:
     otlp/jaeger:
       endpoint: jaeger:4317
       tls: { insecure: true }
     debug:
       verbosity: normal

   extensions:
     health_check: { endpoint: 0.0.0.0:13133 }

   service:
     extensions: [health_check]
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, tail_sampling, batch]
         exporters: [otlp/jaeger, debug]
     telemetry:
       logs: { level: info }
   EOF

   docker compose restart otel-collector && sleep 4
   curl -s http://localhost:13133/ | jq -c '.status'
   ```

   ```
   "Server available"
   ```

6. Mandá 40 requests, esperá a que pase `decision_wait` y contá qué sobrevivió — separado por resultado:

   ```bash
   for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:8080/checkout; done
   sleep 20
   echo -n "total kept:  "; curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=2m&limit=500' | jq '.data | length'
   echo -n "with errors: "; curl -s 'http://localhost:16686/api/traces?service=frontend&tags=%7B%22error%22%3A%22true%22%7D&lookback=2m&limit=500' | jq '.data | length'
   ```

   ```
   total kept:  17
   with errors: 11
   ```

   Se retuvo cada falla; los éxitos se adelgazaron a aproximadamente el 10%.

> **Q6.1** — En el paso 2 configuraste el sampler **solo en el frontend**, y sin embargo los spans del backend desaparecieron para esas mismas trazas. Explicá el mecanismo. ¿Qué habrías visto en cambio si hubieras usado `traceidratio` en lugar de `parentbased_traceidratio` en el backend?
>
> **Q6.2** — En el paso 3 el request no muestreado igual llevaba un `traceparent`, con flags `00`. ¿Por qué enviar una cabecera para una traza que nadie va a almacenar? ¿Qué es un span *non-recording*?
>
> **Q6.3** — `parentbased_traceidratio` deriva su decisión del trace-id, no de un sorteo aleatorio por span. ¿Qué propiedad garantiza esto entre servicios desplegados independientemente, y por qué `random.random() < 0.1` en cada servicio sería catastrófico?
>
> **Q6.4** — Enunciá la compensación fundamental entre muestreo head-based y tail-based en una oración cada uno, en términos de *cuándo* se toma la decisión y *qué información* está disponible en ese momento.
>
> **Q6.5** — `decision_wait: 10s` es la razón por la que tuviste que hacer `sleep 20` en el paso 6. ¿Qué está haciendo exactamente el collector durante esa ventana, cuánta memoria cuesta, y qué le pasa a una traza cuyo último span llega en el segundo 11?
>
> **Q6.6** — Escalás el gateway del collector a 3 réplicas detrás de un Service round-robin, manteniendo esta misma config de `tail_sampling`. Describí la falla que aparece, y nombrá el exporter específico que la arregla y la clave de ruteo que debe usar.
>
> **Q6.7** — Las cuatro políticas se evalúan en conjunto, no en orden. Si una traza es rápida, exitosa y de un inquilino `bronze`, ¿cuál es la probabilidad de que se conserve — y agregar una quinta política `always_sample` cambiaría la respuesta?

---

## Ejercicio 7 — Correlacionar trazas con logs

Una traza te dice *cuál* request fue lento. Un log te dice *por qué*. Solo son útiles juntos si comparten un identificador.

1. Habilitá la correlación de logs en ambos servicios y reinicialos:

   ```bash
   # in BOTH terminals, before relaunching
   export OTEL_PYTHON_LOG_CORRELATION=true
   opentelemetry-instrument flask --app app run --port 8081   # backend
   opentelemetry-instrument flask --app app run --port 8080   # frontend
   ```

2. Mandá un request y leé el log del backend:

   ```bash
   curl -s -o /dev/null http://127.0.0.1:8080/checkout
   ```

   ```
   2026-09-03 12:19:44,081 INFO [app] [app.py:12] [trace_id=6b0f2a94c1e37d58b2ac09ff41e6d370 span_id=7d41c9a0e28b6f13 resource.service.name=backend trace_sampled=True] - inbound traceparent=00-6b0f2a94c1e37d58b2ac09ff41e6d370-4e19c73da05b8f26-01 baggage=None
   ```

3. Realizá la operación que harías a las 03:00 durante un incidente — pasar de una línea de log a la traza distribuida completa:

   ```bash
   TID=6b0f2a94c1e37d58b2ac09ff41e6d370      # copied from the log line
   curl -s "http://localhost:16686/api/traces/${TID}" \
     | jq -r '.data[0].spans[] | "\(.operationName)\t\(.duration)us"'
   ```

   ```
   GET /checkout	74812us
   fraud.check	1104us
   GET	70330us
   GET /inventory	64977us
   ```

4. Y la dirección inversa — a partir de un trace ID encontrado en la UI, grepeá cada línea de log del request en todos los servicios:

   ```bash
   # with both services' stdout redirected to files in a real deployment:
   grep -h "trace_id=${TID}" /var/log/shop/*.log
   ```

5. Inspeccioná el formato que produjo esto y notá que es configurable:

   ```bash
   python3 - <<'EOF'
   from opentelemetry.instrumentation.logging import LoggingInstrumentor
   print(LoggingInstrumentor()._get_log_format() if hasattr(LoggingInstrumentor(), "_get_log_format") else "")
   from opentelemetry.instrumentation.logging.constants import DEFAULT_LOGGING_FORMAT
   print(DEFAULT_LOGGING_FORMAT)
   EOF
   ```

   ```
   %(asctime)s %(levelname)s [%(name)s] [%(filename)s:%(lineno)d] [trace_id=%(otelTraceID)s span_id=%(otelSpanID)s resource.service.name=%(otelServiceName)s trace_sampled=%(otelTraceSampled)s] - %(message)s
   ```

> **Q7.1** — La línea de log lleva `trace_id`, `span_id` *y* `trace_sampled`. ¿Por qué `trace_sampled=False` es un campo crítico para loguear y no una curiosidad?
>
> **Q7.2** — `OTEL_PYTHON_LOG_CORRELATION=true` inyectó IDs en el pipeline de logging existente; `OTEL_LOGS_EXPORTER=otlp` enviaría los logs mismos a través de OTLP. Son dos funcionalidades distintas — describí cada una y decí cuándo usarías solo la primera.
>
> **Q7.3** — Este es el tercer pilar del triángulo de correlación. ¿Cuál es el mecanismo del lado de las métricas que vincula un bucket de histograma de Prometheus con una traza específica, y a qué te permite saltar desde un gráfico de latencia?
>
> **Q7.4** — El `span_id` de la línea de log se refiere al span actualmente activo. Si logueás dentro de un bloque `with tracer.start_as_current_span(...)`, ¿qué span ID aparece? ¿Qué aparece si el log se emite desde un hilo en segundo plano sin contexto activo?

---

## Ejercicio 8 — Diagnosticar una regresión de latencia solo con spans

1. Introducí una patología realista — un bucle síncrono de llamadas pequeñas (el clásico N+1):

   ```bash
   cat > ~/otel-lab/frontend/app.py <<'EOF'
   import logging
   import os
   import random

   import requests
   from flask import Flask, jsonify
   from opentelemetry import trace
   from opentelemetry.trace import SpanKind

   logging.basicConfig(level=logging.INFO)
   app = Flask(__name__)
   tracer = trace.get_tracer("shop.frontend", "0.3.0")
   BACKEND = os.environ.get("BACKEND_URL", "http://127.0.0.1:8081")


   @app.get("/cart")
   def cart():
       span = trace.get_current_span()
       item_count = random.randint(5, 9)
       span.set_attribute("shop.cart.item_count", item_count)

       with tracer.start_as_current_span("cart.enrich", kind=SpanKind.INTERNAL) as enrich:
           enrich.set_attribute("shop.cart.item_count", item_count)
           results = []
           for _ in range(item_count):
               response = requests.get(f"{BACKEND}/inventory", timeout=5)
               if response.ok:
                   results.append(response.json())
       return jsonify({"items": len(results)})
   EOF
   ```

   Reiniciá el frontend y generá tráfico:

   ```bash
   for i in $(seq 1 8); do curl -s -o /dev/null http://127.0.0.1:8080/cart; done; sleep 20
   ```

2. Encontrá la traza más lenta sin abrir un navegador:

   ```bash
   curl -s 'http://localhost:16686/api/traces?service=frontend&operation=GET%20%2Fcart&lookback=5m&limit=50' \
     | jq -r '[.data[] | {traceID, root: (.spans[] | select((.references|length)==0) | .duration)}]
              | sort_by(-.root) | .[0] | "\(.traceID)\t\(.root/1000)ms"'
   ```

   ```
   0c73e5a1f92b46d8ae0157cc3b9f2d40	512.804ms
   ```

3. Descomponé esa traza por operación — cantidad y tiempo total, que es lo que realmente identifica un N+1:

   ```bash
   TID=0c73e5a1f92b46d8ae0157cc3b9f2d40
   curl -s "http://localhost:16686/api/traces/${TID}" \
     | jq -r '.data[0].spans
              | group_by(.operationName)
              | map({op: .[0].operationName, count: length, total_ms: ((map(.duration)|add)/1000)})
              | sort_by(-.total_ms)[]
              | "\(.op)\tn=\(.count)\ttotal=\(.total_ms)ms"'
   ```

   ```
   GET /cart	n=1	total=512.804ms
   cart.enrich	n=1	total=509.117ms
   GET	n=8	total=486.221ms
   GET /inventory	n=8	total=452.930ms
   ```

4. Confirmá que las llamadas son secuenciales y no concurrentes, comparando la suma de los hijos contra el tiempo de reloj del padre:

   ```bash
   curl -s "http://localhost:16686/api/traces/${TID}" \
     | jq -r '.data[0].spans as $s
              | ($s[] | select(.operationName=="cart.enrich") | .duration) as $parent
              | ([$s[] | select(.operationName=="GET") | .duration] | add) as $children
              | "parent=\($parent/1000)ms  sum(children)=\($children/1000)ms  ratio=\(($children/$parent*100)|floor)%"'
   ```

   ```
   parent=509.117ms  sum(children)=486.221ms  ratio=95%
   ```

5. Revisá el grafo de dependencias de servicios que el backend derivó de los span kinds:

   ```bash
   NOW_MS=$(( $(date +%s) * 1000 ))
   curl -s "http://localhost:16686/api/dependencies?endTs=${NOW_MS}&lookback=3600000" | jq -c '.data'
   ```

   ```
   [{"parent":"frontend","child":"backend","callCount":64}]
   ```

> **Q8.1** — El paso 4 mostró `sum(children) ≈ 95%` de la duración del padre. ¿Qué te dice una relación cercana al 100%, y qué te diría en cambio una relación cercana al 12% con 8 hijos?
>
> **Q8.2** — La traza muestra `n=8` spans `GET /inventory` idénticos. Nombrá el anti-patrón y dá las dos remediaciones estándar. ¿Cuál de ellas *confirmaría* la traza que funcionó, y cómo se vería la nueva cascada?
>
> **Q8.3** — Abrís una traza y un span hijo parece empezar 4 ms *antes* que su padre. Las trazas no pueden violar la causalidad. ¿Cuál es la causa, y qué hacen Jaeger y otras UIs al respecto?
>
> **Q8.4** — Llega una traza que contiene solamente el span `GET /inventory` del backend, con un `parentSpanId` que apunta a un span que no está en el almacén. Dá tres causas distintas para este huérfano, y decí cómo las distinguirías.
>
> **Q8.5** — El grafo de dependencias del paso 5 fue *derivado*, no configurado. ¿Qué campo del span hace posible esa derivación, y por qué el grafo estaría vacío si todos los spans fueran `kind: INTERNAL`?
>
> **Q8.6** — La duración por sí sola no te dijo adónde se fue el tiempo; el desglose por operación sí. Definí la **ruta crítica** de una traza y explicá por qué optimizar un span que *no* está en ella no produce ninguna mejora para el usuario final.

---

## Ejercicio 9 — Desmontaje

1. Detené los dos procesos Flask con `Ctrl-C` en sus terminales.
2. Eliminá los contenedores, la red y los volúmenes:

   ```bash
   cd ~/otel-lab && docker compose down -v
   docker compose ps -a
   ```

   ```
   NAME      IMAGE     COMMAND   SERVICE   CREATED   STATUS    PORTS
   ```

3. Confirmá que nada sigue escuchando en los puertos OTLP:

   ```bash
   ss -ltnp 2>/dev/null | grep -E ':(4317|4318|16686)' || echo "all clear"
   ```

   ```
   all clear
   ```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1** — El proyecto Python versiona la **API/SDK** estable como `1.x.y` y todo lo que sigue en desarrollo — el `distro`, todos los paquetes `opentelemetry-instrumentation-*` y el paquete de convenciones semánticas — como `0.NNbM`. Las dos líneas se publican juntas y el emparejamiento es fijo: SDK `1.29.0` ↔ instrumentación `0.50b0`. Mezclarlas típicamente falla en tiempo de importación o, peor, en tiempo de ejecución con un `AttributeError` sobre un interno del SDK, porque los paquetes de instrumentación acceden a superficies no públicas del SDK (span processors, context managers). Fijá ambos, y actualizá ambos en el mismo cambio.

**A0.2** — La instrumentación es monkey-patching específico de cada biblioteca: el paquete de Flask envuelve `Flask.wsgi_app` para abrir un span SERVER, el paquete de `requests` envuelve `Session.send` para abrir un span CLIENT e inyectar cabeceras. Separarlos significa que (a) instalás solo lo que usás, manteniendo chicas la superficie de dependencias y el costo de arranque, (b) cada uno puede versionarse contra el rango soportado de *su* biblioteca, y (c) podés deshabilitar una única instrumentación que se porte mal con `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS` sin perder el resto. `opentelemetry-bootstrap` existe precisamente para resolver "cuál de estos necesito" a partir del conjunto de dependencias instaladas.

### Ejercicio 1

**A1.1** — El `trace-id` es de **16 bytes / 128 bits**, el `span-id` es de **8 bytes / 64 bits**, ambos en base-16 (hex) en minúsculas, o sea 32 y 16 caracteres respectivamente. Se necesitan 128 bits porque los trace IDs los generan independientemente miles de procesos sin coordinación ni asignador central; con 64 bits la cota del cumpleaños vuelve realistas las colisiones a alto volumen, y una colisión fusiona dos requests no relacionados en una traza sin sentido — un bug de corrupción silenciosa de datos que es casi imposible de diagnosticar. Los span IDs se quedan en 64 bits porque solo necesitan ser únicos *dentro* de una única traza.

**A1.2** —
1. El `trace-id` es todo ceros — explícitamente inválido; el valor todo-ceros es el centinela reservado de "inválido".
2. El `parent-id` (span-id) es todo ceros — inválido por la misma razón.
3. El `trace-id` tiene 31 caracteres hex, no 32 — longitud incorrecta.

Un receptor conforme debe **descartar la cabecera `traceparent` completa y comenzar una traza nueva** (pasa a ser un span raíz). *No* debe intentar reparar la cabecera, y no debe rechazar el request — no se le permite al tracing romper la aplicación. Notá la asimetría: un `traceparent` inválido significa además que el `tracestate` que lo acompaña debe descartarse.

**A1.3** — `trace-flags` es un campo de 8 bits; el bit 0 (valor `0x01`) es la bandera **sampled**, que significa "el llamador registró esta traza y vos también deberías". Todos los demás bits están actualmente reservados y deben ignorarse, no asumirse en cero, así que probá con una máscara de bits (`flags & 0x01`), nunca con igualdad de strings contra `"01"`. Un valor de `00` **no** significa dejar de propagar: la cabecera igual debe reenviarse para que la identidad de la traza sobreviva, permitiendo que sistemas downstream con su propia lógica de muestreo tomen una decisión coherente y manteniendo el ID disponible para la correlación de logs.

**A1.4** — `tracestate` lleva **estado del sistema de trazado**: información de posición específica de cada proveedor, indexada por proveedor, para que en un camino multi-proveedor cada uno pueda rastrear su propio span padre. La escribe y la lee la implementación de tracing, está ordenada (el más a la izquierda = el modificado más recientemente) y está acotada (máximo 32 miembros de lista; las implementaciones deberían mantener la cabecera por debajo de 512 caracteres). **`baggage`** (una especificación W3C separada) lleva **contexto clave/valor de nivel de aplicación** — datos arbitrarios de usuario propagados para beneficio del desarrollador. `userId=alice` son datos de aplicación, así que corresponden a `baggage`.

**A1.5** — (1) **Privacidad/seguridad**: baggage se envía como cabecera HTTP en texto plano a *cada* salto downstream, incluyendo APIs de terceros y cualquier proxy o CDN en el camino, y comúnmente termina en los logs de acceso. Poner PII ahí es un canal de exfiltración de datos sin control. (2) **Costo y corrección**: baggage infla el tamaño de cabecera de absolutamente cada request a lo largo de toda la profundidad del grafo de llamadas, y las cabeceras están sujetas a límites de tamaño en los proxies — un baggage sobredimensionado provoca fallas `431`/`400` que aparecen solo en caminos específicos. Además, baggage *no* se copia automáticamente sobre los spans; asumir que va a aparecer en tus trazas requiere un baggage span processor explícito.

### Ejercicio 2

**A2.1** — OTLP/JSON sigue el **mapeo JSON de proto3**, en el cual los campos enteros de 64 bits (`int64`, `uint64`, `fixed64`) se codifican como **strings**, porque los doubles IEEE-754 — que es lo que son los números JSON — no pueden representar exactamente enteros por encima de 2^53. `startTimeUnixNano` es un `fixed64` e `intValue` es un `int64`, así que ambos van entrecomillados. `kind` es un enum, mapeado a un número simple (o al string de su nombre). Enviar un timestamp en nanosegundos sin comillas arriesga pérdida silenciosa de precisión en el rango de los microsegundos; los parsers estrictos lo rechazan directamente. Notá una desviación deliberada de OTLP respecto de proto3 JSON: `traceId`/`spanId` son campos `bytes`, que proto3 JSON codificaría en base64, pero OTLP exige **hex en minúsculas** para que coincidan con la cabecera `traceparent`.

**A2.2** — `ExportTraceServiceResponse.partial_success` es la manera en que OTLP reporta una aceptación *parcial*. Vacío significa que todo fue aceptado. Uno no vacío se ve así: `{"partialSuccess":{"rejectedSpans":"3","errorMessage":"span attribute limit exceeded"}}` — el servidor aceptó el lote pero descartó 3 spans y te dijo por qué. Esto es estrictamente mejor que un `200` pelado porque sin ello un cliente no puede distinguir "todo almacenado" de "descartado silenciosamente el 90% por una cuota"; los clientes están obligados a loguear un `partialSuccess` no vacío como advertencia pero **no** deben reintentar, ya que reintentar duplicaría los spans aceptados.

**A2.3** — Un **resource** describe la *entidad que produce la telemetría* — es idéntico para cada span de ese proceso y por lo tanto se saca fuera del span para evitar repetirlo miles de veces en el cable. Un **atributo de span** describe *esta única operación*. Regla práctica: si el valor puede cambiar entre dos spans del mismo proceso, es un atributo de span. `service.name` es el único atributo de resource que OTLP exige; cuando está ausente, los SDKs y backends caen a `unknown_service` (a menudo `unknown_service:python`), y te queda una pila innavegable de spans bajo un único servicio sin sentido.

**A2.4** — `0 = UNSPECIFIED`, `1 = INTERNAL`, `2 = SERVER`, `3 = CLIENT`, `4 = PRODUCER`, `5 = CONSUMER`. El span kind codifica la *remotidad y la dirección* del límite. Un span CLIENT y el span SERVER que dispara son los dos extremos de un mismo salto de red, así que un backend puede colapsarlos en una arista dirigida `llamador → llamado` y agregar esas aristas en un grafo de dependencias. El vínculo padre/hijo por sí solo no puede hacerlo: un par padre/hijo dentro de un mismo proceso (INTERNAL) no es una arista, y los pares PRODUCER/CONSUMER se vinculan asincrónicamente sin ningún padre síncrono. El span kind también es lo que le dice a la UI dónde esperar latencia de red (la brecha entre la duración CLIENT y la duración SERVER).

**A2.5** — `0 = UNSET`, `1 = OK`, `2 = ERROR`. `UNSET` es el default porque el estado está pensado para establecerse solo cuando la instrumentación tiene *información* sobre el resultado. Si `OK` fuera el default, cada span afirmaría éxito — incluyendo spans de caminos de código que nunca verificaron nada — y `OK` no llevaría señal alguna. Además, por convención las bibliotecas de instrumentación deberían dejar el estado en `UNSET` para las operaciones exitosas y reservar el `OK` explícito para el código de aplicación que deliberadamente anula lo que sería un error (p. ej. un `404` que es esperado). Por eso los backends tratan `UNSET` y `OK` de forma idéntica para las tasas de error y solo alertan sobre `ERROR`.

**A2.6** — La API de Jaeger reporta `duration` en **microsegundos**; los timestamps de OTLP están en **nanosegundos**. Prometheus, en cambio, usa convencionalmente **segundos** (floats). Mezclarlos produce errores de factor 1000 que son invisibles en una revisión de código y generan dashboards que afirman p99 de menos de un milisegundo o latencias medianas de 15 minutos. Afirmá siempre la unidad en el límite — esta es exactamente la razón por la que las convenciones semánticas de OpenTelemetry exigen que las unidades formen parte de la definición de la métrica/atributo en lugar de quedar implícitas.

### Ejercicio 3

**A3.1** — Dos instrumentaciones. `opentelemetry-instrumentation-flask` envolvió el punto de entrada WSGI: **extrajo** el contexto del request entrante e inició un span `SERVER`. `opentelemetry-instrumentation-requests` envolvió el cliente HTTP saliente: inició un span `CLIENT` e **inyectó** la cabecera `traceparent` en el request saliente a partir del contexto actual. La inyección la hizo la instrumentación de `requests`, no Flask. Quitá `opentelemetry-instrumentation-requests` y el backend igual traza — pero como una raíz desconectada.

**A3.2** — El span CLIENT mide la llamada tal como la experimenta el *llamador*: DNS, establecimiento TCP/TLS, serialización del request, tránsito de red en ambos sentidos, espera del pool de conexiones y reintentos del lado cliente. El span SERVER mide solamente el tiempo que el *llamado* pasó dentro de su propio handler. La diferencia (acá ~5,4 ms) es exactamente la sobrecarga de red + encolamiento + serialización invisible para cualquiera de los dos por separado. Esta brecha es el número más valioso de una traza distribuida: un servicio sano con una brecha enorme apunta a la red, al balanceador de carga o a inanición de conexiones del lado cliente — no al servicio.

**A3.3** — El tracing está diseñado para fallar abierto: la instrumentación nunca debe romper el request. Cuando el backend no encontró un `traceparent`, simplemente inició una traza raíz nueva, exactamente como lo haría para un request de punto de entrada legítimo. Cada código de respuesta, latencia y log se mantuvo normal — solo se perdieron las *uniones*, y se pierden en silencio. Detección: (1) **monitorear la proporción de spans raíz por servicio** — un servicio que nunca debería ser punto de entrada reportando de golpe una proporción alta de spans sin padre es la firma; (2) **chequeos sintéticos** que inyecten un `traceparent` conocido en el borde y verifiquen que la traza tenga la cantidad de spans y el conjunto de servicios esperados, como en el paso 7; (3) en el collector, una vista `spanmetrics`/`count` de trazas huérfanas por servicio.

**A3.4** — Con `OTEL_EXPORTER_OTLP_ENDPOINT` (la variable *agnóstica de señal*) y `http/protobuf`, el SDK **agrega el path de la señal**, así que hace POST a `http://localhost:4318/v1/traces` (y `/v1/metrics`, `/v1/logs` para las otras señales). Con `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (la variable *específica de señal*) el valor se usa **tal cual**, path incluido — tenés que escribir `http://localhost:4318/v1/traces` vos mismo, y una falla común es poner en la variable específica un host pelado y obtener `404`. Para gRPC el endpoint no lleva path en ninguno de los dos casos: `http://localhost:4317`.

**A3.5** — Es un **compuesto**, no una cadena de fallback. Al **extraer**, corren todos los propagadores listados y sus resultados se fusionan (así que un request que lleva tanto `traceparent` como `baggage` produce ambos). Al **inyectar**, todos los propagadores listados escriben sus cabeceras, así que el request saliente recibe `traceparent` *y* `baggage`. Durante una migración desde B3 ponés `OTEL_PROPAGATORS=tracecontext,baggage,b3multi` en **todos** los servicios: los servicios recién migrados emiten ambos formatos y aceptan cualquiera, de modo que la flota permanece conectada sin importar el orden de migración; sacás `b3multi` solo cuando desaparece el último servicio heredado.

**A3.6** — El valor está en que convierte al contexto de traza en una **entrada inyectable**: generadores de carga, monitores sintéticos, tests end-to-end de CI y reproducciones manuales con `curl` pueden todos fijar un trace ID conocido y después verificar la traza resultante — volviendo al tracing algo testeable en lugar de algo que esperás que funcione. La consecuencia de seguridad es que un `traceparent` provisto por el cliente es **entrada no confiable**: un atacante puede forzar `sampled=1` en cada request para inflar tu factura de ingesta (una denegación-de-billetera barata), puede colisionar trace IDs para envenenar las trazas de otros usuarios, o puede meter `tracestate`/`baggage` sobredimensionados. En el borde, o bien despojá y regenerá el contexto de traza, o aceptalo solo de llamadores internos autenticados, y aplicá siempre rate limiting y límites de tamaño de cabecera.

### Ejercicio 4

**A4.1** — Un **atributo** describe al span como un todo y es cierto durante toda su duración (`shop.order.id`); un **evento** es un *punto en el tiempo dentro* del span, con su propio timestamp (`rules.loaded` en t+2 ms). Usá un evento cuando importa *cuándo ocurrió* dentro de la operación. Un evento de span no es una línea de log: está estructuralmente ligado al span (no hace falta correlación aparte), hereda la decisión de muestreo del span, tiene un límite duro de cardinalidad/cantidad por span, y no puede existir fuera del tiempo de vida de un span. Los logs son registros independientes que sobreviven cuando no hay ningún span activo y pueden llevar volumen ilimitado. Jaeger renderiza los eventos bajo `logs` por razones históricas — eso es un artefacto del modelo de datos de Jaeger, no el concepto de OpenTelemetry.

**A4.2** — La lista de operaciones habría crecido en una entrada por orden — miles, después millones. Esto es **alta cardinalidad en el nombre del span**, y es destructivo: el índice de operaciones del backend explota, "buscar por operación" se vuelve inusable, agregaciones como "p99 de `fraud.check`" se vuelven imposibles porque no hay dos spans que compartan nombre, y cualquier métrica derivada de nombres de span (p. ej. el conector `spanmetrics`) genera un conjunto ilimitado de series temporales que va a tumbar el almacén de métricas. La regla: **los nombres de span deben ser de baja cardinalidad**; los identificadores van en atributos, que los backends indexan de otra manera y pueden descartar o hashear.

**A4.3** — `otel.status_code` / `otel.status_description` son el `Status` de **OpenTelemetry** traducido fielmente. `error=true` es una convención **específica de Jaeger** (heredada de OpenTracing) que la capa de traducción sintetiza para que la propia UI y la búsqueda de Jaeger puedan marcar el span. Esto importa porque una consulta escrita contra `error=true` no es portable a nada más — mudate a Tempo, Zipkin o a un proveedor y silenciosamente devuelve cero resultados. Escribí el alertado y los dashboards contra la semántica de OpenTelemetry (`status.code = ERROR`, `error.type`) y tratá los tags específicos del backend solo como comodidades de la UI.

**A4.4** — Ninguno implica al otro, y responden preguntas distintas. `record_exception()` agrega un **evento** (`exception.type`, `exception.message`, `exception.stacktrace`) — dice "esta excepción ocurrió acá", lo cual es compatible con una excepción que fue capturada y manejada exitosamente. `set_status(ERROR)` marca el **resultado del span** como fallido, que es sobre lo que se apoyan las tasas de error, el alertado y el tail sampling. Registrá solo la excepción y tus dashboards de tasa de error muestran cero mientras se acumulan los stack traces. Establecé solo el estado y sabés que el request falló pero no tenés stack trace sobre el cual actuar. En un camino de falla genuino, hacé las dos cosas.

**A4.5** — Las convenciones semánticas reservan un conjunto de espacios de nombres de primer nivel (`http.`, `db.`, `rpc.`, `messaging.`, `net.`, `url.`, `k8s.`, `cloud.`, `otel.`, `service.`, `error.`, …) para la especificación. Los atributos específicos de la aplicación deben usar tu propio espacio de nombres — un prefijo de empresa o dominio como `shop.` — con segmentos en minúsculas separados por puntos. Inventar `http.order_priority` es una bomba de compatibilidad futura: una versión posterior de la especificación puede definir esa clave con semántica diferente o de otro tipo, momento en el cual tus datos colisionan con los estándar, los backends que tratan `http.*` de forma especial lo malinterpretan, y cualquier procesador que haga transformaciones basadas en convenciones lo corrompe.

**A4.6** — Un **span link**. Un link referencia otro contexto de span (trace ID + span ID, opcionalmente con atributos) sin establecer una relación padre/hijo, de modo que expresa asociación causal a través de límites de traza. Un consumidor por lotes lo necesita precisamente porque un único span de consumidor procesa *N* mensajes originados en *N* trazas distintas: no hay un único padre al cual adjuntarse, y forzar uno o bien fusionaría trazas no relacionadas o descartaría la conexión por completo. El span del consumidor enlaza a los *N* contextos productores, y la UI te permite saltar del lote a cualquiera de los requests originantes.

### Ejercicio 5

**A5.1** — **Un componente solo corre si está listado en un pipeline bajo `service.pipelines`.** Los bloques de primer nivel `receivers:`/`processors:`/`exporters:` son *definiciones*; `service:` es el *cableado*. El collector no advirtió porque en el momento en que se diseñó este comportamiento, definir componentes sin usar era un patrón legítimo (configs de staging, fragmentos generados). Las versiones modernas del collector sí loguean al arranque que un componente definido no se usa, pero es de nivel `info` y fácil de pasar por alto — que es exactamente por qué el subcomando `validate` del paso 3 es necesario pero *no suficiente*: una config puede ser perfectamente válida y no hacer nada. Verificá el *efecto* (paso 6), no la sintaxis.

**A5.2** — `memory_limiter` debe ir **primero** para poder rechazar datos en el punto más temprano posible: su propósito es proteger al collector de un OOM, y lo hace devolviendo un error reintentable al receiver, que propaga contrapresión hacia el emisor. Cualquier procesador antes de él hace trabajo sobre datos que igual pueden descartarse y — peor — esos datos ya están bufferizados en memoria, que es justo lo que intentabas evitar. `batch` debe ir **último** porque el batching se trata de egreso eficiente: debería agrupar los datos que efectivamente sobrevivieron a todo el filtrado, muestreo y enriquecimiento. Poner `batch` antes de `memory_limiter` significa que el limitador ve grandes bloques agregados en lugar de un flujo parejo, así que reacciona en pasos gruesos, el pico de memoria ocurre *dentro* del batcher donde el limitador no puede verlo, y la contrapresión hacia el receiver se retrasa un timeout de lote completo.

**A5.3** — La sintaxis es `tipo/nombre`: la parte antes de la barra es el **tipo de componente** (debe coincidir con un componente compilado como `otlp`, `attributes`, `resource`), y la parte después es un **nombre de instancia** arbitrario usado solo para desambiguar. El sufijo es obligatorio siempre que necesites **dos o más instancias del mismo tipo** en una config — acá hay un solo bloque `attributes`, pero llamarlo `attributes/scrub` documenta la intención y deja lugar para un segundo; `otlp/jaeger` colisionaría con el nombre del *receiver* `otlp` en la cabeza de quien lo lea si no fuera por el sufijo. `batch` no necesita sufijo porque hay exactamente uno.

**A5.4** — `opentelemetry-collector` (**core**) contiene solamente los componentes mantenidos en el repositorio central — receiver/exporter OTLP, batch, memory_limiter y unos pocos más. **`-contrib`** además empaqueta los varios cientos de componentes de la comunidad: `tail_sampling`, `spanmetrics`, `loadbalancing`, `prometheus`, `filelog`, todos los exporters de proveedores. Esta config necesita contrib por `tail_sampling` (Ejercicio 6); el procesador `attributes` y el exporter `debug` están en core. La alternativa de producción a distribuir contrib es el **OpenTelemetry Collector Builder (`ocb`)**: declarás exactamente los componentes que necesitás en un manifiesto y compila una distribución a medida. Esto reduce el binario de cientos de MB a decenas y — la razón de fondo — elimina la superficie de ataque y la exposición a CVEs de cientos de componentes que nunca usás.

**A5.5** — Ganaste: (1) **desacoplamiento** — la dirección del backend, el protocolo y las credenciales cambian en un solo lugar, no en cada despliegue; (2) **bufferización, reintento y contrapresión** en nombre de clientes livianos, incluyendo sobrevivir a una caída del backend sin que la aplicación se bloquee; (3) **enriquecimiento** con metadatos de entorno/infraestructura que el proceso no puede conocer (`k8s.cluster.name`, nodo, región, y vía `k8sattributes` el pod/namespace/owner); (4) **redacción y aplicación de políticas** aplicadas uniformemente, en configuración controlada por operaciones, sin importar lo que haga el SDK de cada equipo. De estas, (3) y (4) son las que el SDK genuinamente *no puede* hacer: la aplicación no tiene una vista confiable de su propio contexto de infraestructura y — crítico — la redacción impuesta en el código de la aplicación es una política inaplicable, ya que depende de que cada equipo lo haga bien en cada servicio. El scrubbing centralizado es la única forma auditable.

**A5.6** — **Agent**: un collector por host o por pod (DaemonSet o sidecar), alcanzado por `localhost` o por la IP del nodo. Descarga al SDK de inmediato, enriquece con metadatos de host/pod que solo un proceso local puede ver, y sobrevive a los reinicios de la aplicación. **Gateway**: un Deployment autónomo y escalable de forma independiente detrás de un Service, que recibe de muchos agents o aplicaciones. Hace el trabajo caro y a nivel flota: tail sampling, agregación, egreso hacia proveedores, custodia de credenciales. Este laboratorio corre un **gateway** (una única instancia compartida a la que apuntan las aplicaciones). Una topología de dos niveles agent→gateway te da: enriquecimiento local más un primer salto corto y confiable para la aplicación; un único punto de egreso que guarda las credenciales del proveedor; la capacidad de escalar el gateway, intensivo en CPU, con independencia de la cantidad de nodos; y — requisito para el tail sampling — un lugar donde todos los spans de una traza pueden reunirse.

**A5.7** — Se **pierden permanentemente**. `sending_queue` es en memoria por defecto, así que un desalojo, un OOM-kill, un drenaje de nodo o un despliegue progresivo descartan lo que esté encolado. La perilla es **`file_storage`**: habilitá la extensión `file_storage` y referenciala como `sending_queue.storage`, lo que persiste la cola en disco para que sobreviva a un reinicio. En Kubernetes esto requiere un volumen real, lo que a su vez te empuja hacia un StatefulSet para el gateway — un costo operativo genuino. La compensación habitual: aceptar la pérdida en memoria para las trazas (datos muestreados, individualmente prescindibles) y usar colas persistentes donde cada registro importa.

### Ejercicio 6

**A6.1** — El frontend es la **raíz** de la traza, así que su sampler toma la decisión y la codifica en la bandera `sampled` del `traceparent`. El sampler por defecto del backend es `parentbased_always_on`, cuyo envoltorio *parent-based* significa: **si hay un contexto padre, obedecé su bandera sampled**; solo aplicá el sampler delegado (`always_on`) cuando no hay padre. Así que el backend descartó fielmente el 90% que el frontend marcó como no muestreado. Con `traceidratio` a secas en el backend — sin el envoltorio parent-based — el backend ignoraría la bandera entrante y haría su propio sorteo independiente, produciendo **trazas rotas**: aproximadamente el 10% de los spans del backend se conservarían para trazas cuyos spans de frontend fueron descartados (huérfanos) y a ~90% de las trazas muestreadas del frontend les faltaría su mitad de backend. Las trazas parciales son peores que ninguna traza, porque te llevan a conclusiones falsas.

**A6.2** — Porque la cabecera no es solo una señal de muestreo, es la **identidad del request**. Propagarla cuando no está muestreada preserva: la correlación de logs (Ejercicio 7 — podés seguir grepeando por trace ID aunque no haya traza almacenada), la capacidad de un servicio downstream de aplicar su propia política (un inquilino marcado para debug, un camino de error que eleva la decisión), y un comportamiento consistente si más tarde un tail sampler decide conservar la traza. Un span **non-recording** es el objeto que el SDK devuelve para una traza no muestreada: lleva un `SpanContext` válido (así que `inject` funciona y el `trace_id` está disponible para los loggers) pero descarta todos los atributos, eventos y estado sin asignar memoria, y nunca se exporta. Es el mecanismo que hace que el trazado no muestreado sea casi gratis.

**A6.3** — Derivar la decisión determinísticamente del trace ID significa que **cada servicio computa la misma respuesta para la misma traza, sin comunicarse**. Esto es lo que hace posible el muestreo consistente entre servicios desplegados de forma independiente y configurados distinto, y es por eso que el trace ID debe ser uniformemente aleatorio. `random.random() < 0.1` por servicio convertiría cada salto en una moneda independiente: para una traza de 4 servicios al 10% cada uno, la probabilidad de que sobreviva una traza *completa* es 0,1⁴ = 0,01% — mientras seguís pagando por almacenar ~35% de las trazas como fragmentos inútiles. Obtendrías costo máximo y valor mínimo simultáneamente.

**A6.4** — **Head-based**: la decisión se toma en la raíz, *antes* de que el request se ejecute — barata, sin estado, efectiva de inmediato para reducir la carga en cada salto downstream y en la red, pero tomada **sin ningún conocimiento del resultado**, así que descarta errores y requests lentos a la misma tasa que los éxitos aburridos. **Tail-based**: la decisión se toma después de haber observado la traza completa — puede conservar exactamente las trazas interesantes (errores, alta latencia, inquilinos específicos), pero requiere **transportar y bufferizar el 100% de los spans** hacia un componente con estado primero, así que pagás el costo completo de red y de collector y solo ganás en almacenamiento.

**A6.5** — Durante `decision_wait` el collector **bufferiza en memoria cada span de cada traza en vuelo**, indexado por trace ID, esperando a que la traza esté "suficientemente completa" para evaluar las políticas contra ella. El costo es aproximadamente `throughput × decision_wait × tamaño medio de span`, acotado por `num_traces` (la caché LRU de trace IDs) — por eso existen ambas perillas y por eso un gateway que hace tail sampling es voraz en memoria y debe dimensionarse deliberadamente. Un span que llega en el segundo 11 llega **demasiado tarde**: la decisión ya fue tomada y emitida, así que un span tardío o bien llega al backend como fragmento de una traza que por lo demás fue descartada, o se descarta directamente. Por lo tanto `decision_wait` debe exceder la duración p99 de tu *traza*, no la p99 de tu request — las trazas de larga duración quedan sistemáticamente mal muestreadas.

**A6.6** — Con balanceo round-robin, los spans de una única traza quedan **repartidos entre las 3 réplicas**. Cada réplica evalúa entonces las políticas contra el fragmento que le tocó tener: una réplica que recibió solo el span exitoso del frontend no ve error y lo descarta, mientras que la réplica que tiene el span con error del backend lo conserva. El resultado son sistemáticamente **trazas rotas más decisiones equivocadas** — precisamente la falla que el tail sampling existe para evitar. La solución es el **exporter `loadbalancing`** en un primer nivel de collectors, configurado con **`routing_key: traceID`**, que hashea el trace ID para elegir el collector de destino, de modo que todos los spans de una traza aterrizan en la misma réplica de tail sampling. (Para el caso de uso de `spanmetrics` la clave es `service` en su lugar.) Por esto el tail sampling fuerza una topología de collector de dos niveles.

**A6.7** — Las políticas se combinan con **OR**: una traza se conserva si *cualquier* política dice conservar. Una traza rápida, exitosa y `bronze` no coincide con ninguna de las tres primeras, así que solo aplica `baseline-sample` — se conserva con probabilidad del **10%**. Agregar una política `always_sample` llevaría la tasa efectiva de muestreo al **100% para toda traza**, porque esa política sola coincidiría con todo y el OR volvería irrelevantes a las demás — una mala configuración común y cara. Para expresar "conservar el 10% del tráfico normal *y solo eso*", tenés que componer con el tipo de política `and` o expresar la exclusión dentro del conjunto de políticas; en tail sampling no hay "else".

### Ejercicio 7

**A7.1** — Porque te dice **si seguir el trace ID te va a llevar a alguna parte**. En una flota muestreada, la mayoría de las líneas de log llevan un trace ID cuya traza nunca fue almacenada. Sin `trace_sampled`, alguien de ingeniería hace clic, obtiene "traza no encontrada" y razonablemente concluye que el pipeline de tracing está roto — una falsa alarma que erosiona la confianza en todo el sistema. Con él, "no encontrada" es esperado y correcto para `trace_sampled=False`, y genuinamente alarmante para `True`. Además te da una medida barata, derivada de los logs, de tu tasa de muestreo realmente alcanzada, independiente de lo que configuraste.

**A7.2** — La **correlación de logs** (`OTEL_PYTHON_LOG_CORRELATION=true`) inyecta `otelTraceID`/`otelSpanID` en el `LogRecord` de la biblioteca estándar y cambia el string de formato por defecto para imprimirlos. Tus logs siguen yendo adonde siempre fueron — stdout, archivos, `journald`, un pipeline existente de Fluent Bit/Loki. La **exportación de logs** (`OTEL_LOGS_EXPORTER=otlp`) además convierte los registros de log en registros de log OTLP y los envía a través del pipeline de OpenTelemetry, dándote los procesadores del collector y un único punto de egreso. Usá solo la correlación cuando ya tenés un pipeline de logs maduro y confiable que no querés reemplazar: obtenés todo el beneficio de la correlación por una variable de entorno y cero riesgo de migración, que es el caso de producción abrumadoramente más común.

**A7.3** — Los **exemplars**. Un exemplar de Prometheus/OpenMetrics adjunta un trace ID (y un timestamp) a una observación individual dentro de un bucket de histograma, de modo que una muestra registrada apunta a la traza que la produjo. Requiere el formato de exposición OpenMetrics y debe habilitarse tanto del lado de la instrumentación como del lado del scrape. La recompensa es el flujo de trabajo que hace de los tres pilares un sistema en lugar de tres herramientas: ves un pico de latencia p99 en un panel de Grafana, hacés clic en el punto del exemplar en el bucket afectado y aterrizás directamente en una traza de uno de los requests lentos reales — en lugar de adivinar un rango temporal y buscar.

**A7.4** — Aparece el **span activo más interno**, porque la instrumentación de logging lee `trace.get_current_span()` del contexto activo en el momento en que se crea el registro — así que dentro de `with tracer.start_as_current_span("fraud.check")` se loguea el span ID de `fraud.check`, no el del span HTTP que lo envuelve. Desde un hilo en segundo plano sin contexto activo, `get_current_span()` devuelve el **span inválido**, y los campos se renderizan todos en ceros: `trace_id=00000000000000000000000000000000 span_id=0000000000000000`, con `trace_sampled=False`. Esto es en sí mismo un diagnóstico útil — IDs todo-ceros en los logs significan que se perdió el contexto al cruzar un hilo, un executor o un límite asíncrono, y es la firma estándar de una propagación de contexto faltante en pools de workers.

### Ejercicio 8

**A8.1** — Una relación cercana al 100% significa que los hijos corrieron **estrictamente en secuencia** y dan cuenta de esencialmente todo el tiempo del padre — el padre no hace trabajo propio significativo, solo espera llamadas una tras otra. Por lo tanto la solución está en el *patrón de llamadas*, no en el código del padre. Una relación cercana al 12% con 8 hijos (≈ 100%/8) significa que los hijos corrieron **completamente en paralelo**: el tiempo total de CPU/reloj de los hijos es 8× el tiempo transcurrido del padre porque se solaparon, y la duración del padre está acotada por el hijo *más lento*. En ese caso no hay nada que ganar con concurrencia — tenés que hacer más rápido al hijo más lento.

**A8.2** — El anti-patrón **N+1 de consultas/requests**. Remediaciones: (1) **batch** — reemplazar las N llamadas por un único endpoint masivo (`GET /inventory?sku=a,b,c`), que es la solución correcta porque además elimina N× la sobrecarga por request; (2) **paralelizar** — emitir las N llamadas concurrentemente, lo que acota la latencia a la llamada más lenta pero mantiene la carga sobre el llamado. La traza confirma cuál desplegaste: después de agrupar en lote, la cascada muestra **un** span hijo (`n=1`) y el padre colapsa a aproximadamente la duración de una sola llamada; después de paralelizar, sigue mostrando **ocho** spans hijos pero se dibujan apilados y *solapados*, con la duración del padre cercana al hijo individual más largo en vez de a su suma.

**A8.3** — **Desfase de reloj** entre los dos hosts. Los timestamps vienen del reloj de pared de cada proceso, y máquinas disciplinadas por NTP igual difieren rutinariamente en milisegundos de un solo dígito; los contenedores, la migración en vivo de VMs y los relojes virtualizados lo empeoran. La traza no se equivoca sobre la causalidad — los relojes están en desacuerdo. Jaeger aplica un **ajuste de desfase de reloj**: usa el par de spans CLIENT/SERVER como referencia (el span server debe estar contenido dentro del span client) para calcular un desplazamiento, corre los timestamps del hijo y anota el span ajustado con una advertencia como `clock skew adjustment disabled; not applying calculated delta` o una nota del delta aplicado. Las consecuencias prácticas: nunca calcules una duración restando timestamps tomados en hosts *distintos*, y tratá como ruido los tiempos entre servicios de menos de 10 ms salvo que tengas relojes de grado PTP.

**A8.4** — Tres causas: (1) **El padre fue descartado por muestreo** — p. ej. un upstream con muestreo head-based tomó una decisión distinta, o un tail sampler lo descartó mientras se filtraba un span tardío. (2) **La propagación está rota aguas arriba** — no, en este caso el ID del padre *sí* está presente, así que más precisamente: el servicio padre no está instrumentado para exportar, o su exporter está fallando (cola llena, backend inalcanzable, credenciales vencidas), de modo que propaga el contexto correctamente pero nunca envía sus propios spans. (3) **Los spans del padre no llegaron o se perdieron en tránsito** — un reinicio del collector, un desborde de `sending_queue`, o simplemente una carrera en la que consultaste antes de que el lote del padre se vaciara. Cómo distinguirlas: chequeá si `trace_sampled` en los logs del upstream era `False` (causa 1); chequeá el `otelcol_exporter_send_failed_spans` del collector del upstream y las métricas de spans descartados del propio SDK (causa 2); volvé a consultar después de un intervalo de lote y chequeá `otelcol_processor_dropped_spans` y los contadores de rechazo del receiver (causa 3). Si el servicio upstream no aparece en absoluto en `/api/services`, es la causa 2.

**A8.5** — **`span.kind`** — específicamente el apareamiento CLIENT/SERVER (y PRODUCER/CONSUMER), emparejado por trace ID y relación padre/hijo, combinado con el `service.name` del resource de cada span. El backend recorre cada traza, encuentra cada lugar donde un span de un servicio es el padre de un span de otro, y emite una arista. Si todos los spans fueran `kind: INTERNAL`, no habría señal de que se cruzó un límite — los vínculos padre/hijo seguirían existiendo, pero serían indistinguibles del anidamiento ordinario dentro de un proceso, así que no podría inferirse ninguna arista y el grafo de dependencias estaría vacío. Esta es la razón concreta y estructural por la que el span kind no es decoración opcional.

**A8.6** — La **ruta crítica** es la cadena de spans que efectivamente determina la duración total de la traza: partiendo del fin de la raíz, en cada nivel el hijo cuya finalización estaba esperando el padre, recursivamente. El trabajo que corre concurrentemente con la ruta crítica — y termina antes que ella — no aporta nada a la latencia del usuario final. Optimizar un span fuera de la ruta crítica produce cero mejora visible para el usuario porque el request nunca estuvo esperándolo: lográs que una rama paralela termine en 10 ms en lugar de 40 ms mientras el request sigue esperando 500 ms por la rama que condiciona la respuesta. Por eso "el span más lento" es el objetivo equivocado y "el span en la ruta crítica con el mayor tiempo exclusivo" es el correcto — y por eso una vista de cascada, que hace visible el solapamiento, le gana a cualquier lista ordenada de duraciones.

</details>

---

## Fuentes

- LPI — Objetivos del examen 701: <https://www.lpi.org/our-certifications/exam-701-objectives/>
- W3C — Trace Context (Recomendación): <https://www.w3.org/TR/trace-context/>
- W3C — Baggage: <https://www.w3.org/TR/baggage/>
- OpenTelemetry — Conceptos de trazas: <https://opentelemetry.io/docs/concepts/signals/traces/>
- OpenTelemetry — Muestreo: <https://opentelemetry.io/docs/concepts/sampling/>
- OpenTelemetry — Especificación OTLP: <https://opentelemetry.io/docs/specs/otlp/>
- OpenTelemetry — Convenciones semánticas: <https://opentelemetry.io/docs/specs/semconv/>
- OpenTelemetry — Variables de entorno del SDK: <https://opentelemetry.io/docs/languages/sdk-configuration/general/> y <https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/>
- OpenTelemetry — Instrumentación automática en Python: <https://opentelemetry.io/docs/languages/python/automatic/>
- OpenTelemetry — Configuración del Collector: <https://opentelemetry.io/docs/collector/configuration/>
- OpenTelemetry — Patrones de despliegue del Collector: <https://opentelemetry.io/docs/collector/deployment/>
- OpenTelemetry Collector Contrib — `tailsamplingprocessor`: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor>
- OpenTelemetry Collector Contrib — `loadbalancingexporter`: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter>
- Jaeger — Primeros pasos: <https://www.jaegertracing.io/docs/latest/getting-started/>
- Jaeger — APIs: <https://www.jaegertracing.io/docs/latest/apis/>
- Zipkin — Modelo de datos: <https://zipkin.io/pages/data_model.html> · Propagación B3: <https://github.com/openzipkin/b3-propagation>