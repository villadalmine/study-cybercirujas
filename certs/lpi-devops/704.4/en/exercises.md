# Topic 704.4 — Tracing
### Guided exercises — LPI DevOps Tools Engineer, exam 701-100 (v2.0.0) · exam weight 3.33

> **What you build.** A complete distributed-tracing plane: a Jaeger backend, an OpenTelemetry Collector gateway, and a two-service Python application whose trace context propagates over HTTP. You will craft OTLP payloads by hand with `curl`, decode `traceparent` headers byte by byte, configure head-based and tail-based sampling, correlate logs with traces, and diagnose a latency regression from span timings alone.
>
> **Reference syllabus:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

---

## 0. Lab prerequisites

1. Verify your tooling. Every exercise below assumes these are on `PATH`:

   ```bash
   docker --version && docker compose version
   python3 --version
   jq --version
   curl --version | head -1
   openssl version
   ```

   Expected (versions will differ):

   ```
   Docker version 27.3.1, build ce12230
   Docker Compose version v2.30.3
   Python 3.12.7
   jq-1.7.1
   curl 8.9.1 (x86_64-pc-linux-gnu) libcurl/8.9.1 OpenSSL/3.3.2 ...
   OpenSSL 3.3.2 3 Sep 2024
   ```

2. Create the lab tree:

   ```bash
   mkdir -p ~/otel-lab/{frontend,backend,collector}
   cd ~/otel-lab
   ```

3. Create the Python virtualenv and install the OpenTelemetry distro:

   ```bash
   python3 -m venv .venv
   . .venv/bin/activate
   pip install --quiet "flask==3.0.*" "requests==2.32.*" \
       "opentelemetry-distro==0.50b0" "opentelemetry-exporter-otlp==1.29.0"
   opentelemetry-bootstrap -a install
   ```

   `opentelemetry-bootstrap` scans your installed libraries and pulls the matching instrumentation packages (`opentelemetry-instrumentation-flask`, `-requests`, `-wsgi`, `-logging`, …). Confirm:

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

> **Q0.1** — `opentelemetry-distro` and `opentelemetry-sdk` carry different version numbers (`0.50b0` vs `1.29.0`) yet must be installed together. What is the versioning rule of the Python OpenTelemetry project, and what breaks if you mix them?
>
> **Q0.2** — Why does auto-instrumentation ship as one package *per library* (`-flask`, `-requests`) instead of one package for the language?

---

## Exercise 1 — Decoding W3C Trace Context by hand

The wire format is the contract between services written in different languages by different teams. Learn it before you let an SDK generate it for you.

1. Take the canonical header from the specification and split it:

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

2. Generate a fresh, valid pair of identifiers the way an SDK does — 16 random bytes for the trace, 8 for the span:

   ```bash
   openssl rand -hex 16   # trace-id
   openssl rand -hex 8    # span-id
   ```

   ```
   9f2b7c0e4a6d18335e7b1c9d0a4f6e21
   3c81f0a97b2d4e65
   ```

3. Inspect the two companion headers. Create them by hand and note the structural difference:

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

4. Prove that the format is validated, not merely parsed. Construct three malformed headers and reason about each *before* any tool sees them:

   ```bash
   printf '%s\n' \
     '00-00000000000000000000000000000000-00f067aa0ba902b7-01' \
     '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01' \
     '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01'
   ```

> **Q1.1** — How many bytes are the `trace-id` and the `span-id`, and how are they encoded on the wire? Why is a 128-bit trace-id used when a 64-bit one would produce far shorter headers?
>
> **Q1.2** — Each of the three headers in step 4 is invalid. State the defect in each, and describe what a compliant receiver must do when it gets one.
>
> **Q1.3** — `trace-flags` is `01`. Which bit is that, what does it mean, and does a value of `00` mean "do not propagate the header"?
>
> **Q1.4** — `tracestate` and `baggage` are both comma-separated key/value lists that travel with every request. What is the semantic difference, and which of the two would you use to carry `userId=alice` to a downstream service?
>
> **Q1.5** — Your platform team wants to put the customer's e-mail in `baggage` so every service can log it. Give the two independent reasons to reject this.

---

## Exercise 2 — A tracing backend, and OTLP without an SDK

2. Write the compose file for the backend:

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

   > Jaeger v2 (`jaegertracing/jaeger:2.x`) is the successor and is itself built on the OpenTelemetry Collector; it exposes the same UI port `16686` and the same OTLP ports, so everything below transfers unchanged. The v1 all-in-one image is pinned here because its flags are stable and well documented.

3. Start it and confirm health:

   ```bash
   cd ~/otel-lab && docker compose up -d
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:16686/
   curl -s http://localhost:14269/ | jq '.status'
   ```

   ```
   200
   "Server available"
   ```

4. Confirm the store is empty — there is no service registered yet:

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

5. Emit a span by hand over **OTLP/HTTP with JSON encoding** — no SDK, no agent, just `curl`:

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

6. Add a **child** span to the same trace. Reuse `$TRACE_ID`, reference `$SPAN_ID` as the parent, and mark it `kind: 3` (CLIENT):

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

7. Query the trace back through the Jaeger HTTP API:

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

8. Open <http://localhost:16686/>, search service `curl-demo`, and open the trace. You should see a two-level waterfall, the child inset 40 ms from the parent's start.

> **Q2.1** — In the JSON payload, `startTimeUnixNano` and `intValue` are quoted strings while `kind` is a bare number. Why? What would a strict collector do if you sent `"startTimeUnixNano": 1735689600000000000` unquoted?
>
> **Q2.2** — The response was `200` with the body `{"partialSuccess":{}}`. What does an empty `partialSuccess` mean, and what would a *non-empty* one look like? Why is this better than a bare `200`?
>
> **Q2.3** — `service.name` sits under `resource`, while `http.request.method` sits under the span. What is the rule that decides where an attribute belongs, and what does a backend display when `service.name` is missing entirely?
>
> **Q2.4** — You set `"kind": 2` on the parent and `"kind": 3` on the child. Map the numeric values 0–5 to their names, and explain why span kind — not just the parent/child link — is what lets a backend draw a service dependency graph.
>
> **Q2.5** — The parent had `"status": {"code": 1}` and the child `{"code": 0}`. What are the three status codes, and why is `UNSET` the correct default rather than `OK`?
>
> **Q2.6** — `duration` came back as `250000`, not `250000000`. What unit does the Jaeger API use, and what class of bug does this unit mismatch cause when people write dashboards against mixed APIs?

---

## Exercise 3 — Auto-instrumentation and context propagation across a process boundary

1. Write the downstream service. It logs the inbound `traceparent` so propagation is visible without a UI:

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

2. Write the upstream service:

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

3. Start the backend under auto-instrumentation, in its own terminal:

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

4. Start the frontend the same way in a second terminal, changing only the service name:

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

5. Drive traffic and watch the backend terminal:

   ```bash
   for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8080/checkout; done; echo
   ```

   ```
   200 200 500 200 200 200 200 500 200 200
   ```

   Backend log:

   ```
   INFO:app:inbound traceparent=00-7d1f0c4a9b2e8536ad0e5f731c4b9a02-4f61b0c2d3a97e15-01 baggage=None
   INFO:werkzeug:127.0.0.1 - - [03/Sep/2026 11:42:07] "GET /inventory HTTP/1.1" 200 -
   ```

   Not one line of application code mentions tracing, yet the header is there.

6. Confirm the trace spans both services:

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

7. Now *join* an existing trace from outside. Supply your own `traceparent` and confirm the application adopts it:

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

8. Break propagation deliberately. Restart **only the frontend** with a mismatched propagator and repeat step 5:

   ```bash
   # frontend terminal: Ctrl-C, then
   export OTEL_PROPAGATORS=b3multi
   opentelemetry-instrument flask --app app run --port 8080
   ```

   ```
   INFO:app:inbound traceparent=None baggage=None
   ```

   Look the trace up in the UI: instead of one three-span trace you now have two disconnected traces.

> **Q3.1** — No line of `frontend/app.py` imports OpenTelemetry, yet a `traceparent` header reached the backend. Name the two distinct instrumentations involved and state precisely which one injected the header.
>
> **Q3.2** — In step 6 the frontend produced *two* spans for one request (`server` then `client`) while the backend produced one. Why is the client span not redundant with the backend's server span? What does the gap between their durations measure?
>
> **Q3.3** — In step 8 the frontend emitted B3 headers and the backend read only `traceparent`. The backend still produced valid spans and the application still returned `200`. Explain why a propagator mismatch is a *silent* failure, and name two ways to detect it in production.
>
> **Q3.4** — `OTEL_EXPORTER_OTLP_ENDPOINT` is set to `http://localhost:4318` with no path, but OTLP/HTTP traces are received at `/v1/traces`. What does the SDK do, and how does this differ from `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`? What is the equivalent value when `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`?
>
> **Q3.5** — `OTEL_PROPAGATORS=tracecontext,baggage` lists two values. Is that a fallback chain or a composite? What is the effect on the outgoing request, and what would you set during a migration off a legacy Zipkin/B3 fleet?
>
> **Q3.6** — In step 7 the trace continued from an ID you invented on the command line. What is the operational value of this, and what is the security consequence of accepting `traceparent` from an untrusted client at the edge?

---

## Exercise 4 — Manual instrumentation: custom spans, attributes, events, errors

Auto-instrumentation gives you the plumbing. Business meaning has to be written.

1. Rewrite the frontend to add a domain span around a fraud check:

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

2. Restart the frontend (with `OTEL_PROPAGATORS=tracecontext,baggage` restored) and drive traffic until you get both a `402` and a `500`:

   ```bash
   for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8080/checkout; done; echo
   ```

   ```
   200 200 500 200 402 200 200 200 500 200 200 200 200 402 200 ...
   ```

3. Pull an errored trace back and inspect the error carrier:

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

4. Inspect a span that carries a recorded exception (the `500` path):

   ```bash
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=10m&limit=20' \
     | jq -r '.data[].spans[].logs[]?.fields[] | select(.key=="exception.type") | .value' | sort -u
   ```

   ```
   requests.exceptions.HTTPError
   ```

5. Count how many distinct operation names the frontend now reports:

   ```bash
   curl -s 'http://localhost:16686/api/operations?service=frontend' | jq -c '.data'
   ```

   ```
   ["GET","GET /checkout","fraud.check"]
   ```

> **Q4.1** — `shop.order.id` was set as a span *attribute*, while `rules.loaded` was recorded as a span *event*. Give the rule that decides between the two, and explain why a span event is not the same thing as a log line even though Jaeger renders it under `logs`.
>
> **Q4.2** — The operation names stayed at three (step 5) even though thousands of distinct order IDs flowed through. What would have happened had `fraud.check` been named `f"fraud.check {order_id}"`, and what is the general name for this failure?
>
> **Q4.3** — `set_status(StatusCode.ERROR)` produced `otel.status_code=ERROR` *and* `error=true` in Jaeger. Which of the two is the OpenTelemetry concept and which is the backend's own convention? Why does this distinction matter when you write alerting queries?
>
> **Q4.4** — `record_exception()` and `set_status(ERROR)` were both called on the failure path. Does either imply the other? What do you lose by calling only one?
>
> **Q4.5** — Every custom attribute is prefixed `shop.`. What is the naming rule from the OpenTelemetry semantic conventions, and why must you never invent an attribute under the `http.`, `db.` or `otel.` prefixes?
>
> **Q4.6** — The order is processed asynchronously by a worker that consumes a queue message written during this request. A parent/child reference is wrong there. What span construct expresses "caused by, but not nested within", and why does a batch consumer need it?

---

## Exercise 5 — The OpenTelemetry Collector as a gateway

Applications should not know the address of your observability vendor, nor retry on its behalf, nor be trusted to redact PII.

1. Write the collector configuration:

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

2. Add the collector to compose and take the OTLP ports away from Jaeger, so the only ingress is the gateway:

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

3. Validate the configuration *before* rolling it — the collector can check a config without starting a pipeline:

   ```bash
   docker run --rm -v ~/otel-lab/collector/config.yaml:/etc/otelcol/config.yaml:ro \
     otel/opentelemetry-collector-contrib:0.115.0 validate --config=/etc/otelcol/config.yaml
   echo "exit=$?"
   ```

   ```
   exit=0
   ```

4. Roll it out and check health:

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

5. The applications need **no change** — they already point at `localhost:4318`. Send traffic and watch the collector's `debug` exporter:

   ```bash
   for i in $(seq 1 5); do curl -s -o /dev/null http://127.0.0.1:8080/checkout; done
   docker compose logs --tail=20 otel-collector | grep -A3 'TracesExporter'
   ```

   ```
   otel-collector  | info TracesExporter {"resource spans": 2, "spans": 5}
   ```

6. Confirm the scrubbing actually happened — `shop.order.id` must no longer be readable:

   ```bash
   curl -s 'http://localhost:16686/api/traces?service=frontend&lookback=2m&limit=1' \
     | jq -r '.data[0].spans[].tags[] | select(.key=="shop.order.id" or .key=="k8s.cluster.name") | "\(.key)=\(.value)"' | sort -u
   ```

   ```
   k8s.cluster.name=lab-local
   shop.order.id=9f18b4d0e4a1a0d1e8c3b6f2a7d59c4e2b1f0a7c...
   ```

7. Prove the pipeline is what matters, not the definition. Remove `attributes/scrub` from the `processors:` list under `service.pipelines.traces` (leave the block defined above), restart, and re-run step 6:

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

   Restore it before continuing:

   ```bash
   sed -i 's/\[memory_limiter, resource\/env, batch\]/[memory_limiter, resource\/env, attributes\/scrub, batch]/' collector/config.yaml
   docker compose restart otel-collector
   ```

> **Q5.1** — Step 7 showed a fully defined, syntactically valid `attributes/scrub` processor doing nothing. State the rule this demonstrates, and explain why the collector did not warn you.
>
> **Q5.2** — `memory_limiter` is first in the processor list and `batch` is last. Justify each position. What goes wrong if you put `batch` before `memory_limiter`?
>
> **Q5.3** — The names are `otlp/jaeger`, `attributes/scrub`, `resource/env`. What is the syntax before and after the slash, and why is the suffix required here but not for `batch`?
>
> **Q5.4** — The image is `opentelemetry-collector-**contrib**`, not `opentelemetry-collector`. What is the difference, which components in this config force the contrib build, and what is the production alternative to shipping contrib?
>
> **Q5.5** — Applications now send to a collector rather than straight to Jaeger. List four capabilities you gained. Which of them could *not* have been implemented in the SDK?
>
> **Q5.6** — Distinguish the collector's **agent** (sidecar / DaemonSet) deployment from the **gateway** (standalone Deployment) deployment. Which one is running here, and what does a two-tier agent→gateway topology buy you?
>
> **Q5.7** — `sending_queue` is enabled with `queue_size: 5000` and it is in-memory. What happens to those spans when the collector pod is evicted, and what is the configuration knob that changes this?

---

## Exercise 6 — Sampling: head-based, then tail-based

100% tracing at production volume is a storage bill, not a strategy.

1. Establish a baseline. Restart the **frontend** with an explicit always-on sampler and send 40 requests:

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

2. Switch to a 10% head-based ratio sampler and repeat:

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

3. Observe what happens to the *header* on an unsampled request. Watch the backend terminal while traffic flows:

   ```
   INFO:app:inbound traceparent=00-2c9a71f4e0b3d85617ff02a1c6e4d739-9a01c7d2f4e6b385-00 baggage=None
   INFO:app:inbound traceparent=00-8f4b13c7a92e60d5b1c0774e2a3f9d68-13c7e0a94f28b6d1-01 baggage=None
   ```

   Note the trailing `00` versus `01`.

4. Verify that the backend does **not** override the frontend's decision. Confirm the backend's sampler:

   ```bash
   # backend terminal — this is the default, shown explicitly
   echo "$OTEL_TRACES_SAMPLER"
   ```

   ```
   parentbased_always_on
   ```

5. Now move the decision to the collector. Replace head-based sampling with tail-based: set the frontend back to `parentbased_always_on` (restart it), then add the processor:

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

6. Send 40 requests, wait past `decision_wait`, and count what survived — split by outcome:

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

   Every failure was retained; the successes were thinned to roughly 10%.

> **Q6.1** — In step 2 you set the sampler on the **frontend only**, yet backend spans disappeared for the same traces. Explain the mechanism. What would you have seen instead had you used `traceidratio` rather than `parentbased_traceidratio` on the backend?
>
> **Q6.2** — In step 3 the unsampled request still carried a `traceparent`, with flags `00`. Why send a header for a trace nobody will store? What is a *non-recording* span?
>
> **Q6.3** — `parentbased_traceidratio` derives its decision from the trace-id, not from a random draw per span. What property does this guarantee across independently deployed services, and why would `random.random() < 0.1` in each service be catastrophic?
>
> **Q6.4** — State the fundamental trade-off between head-based and tail-based sampling in one sentence each, in terms of *when* the decision is made and *what information* is available at that moment.
>
> **Q6.5** — `decision_wait: 10s` is the reason you had to `sleep 20` in step 6. What exactly is the collector doing during that window, what memory does it cost, and what happens to a trace whose last span arrives at second 11?
>
> **Q6.6** — You scale the collector gateway to 3 replicas behind a round-robin Service, keeping this same `tail_sampling` config. Describe the failure that appears, and name the specific exporter that fixes it and the routing key it must use.
>
> **Q6.7** — The four policies are evaluated together, not in order. If a trace is fast, successful, and from a `bronze` tenant, what is the probability it is kept — and would adding a fifth `always_sample` policy change the answer?

---

## Exercise 7 — Correlating traces with logs

A trace tells you *which* request was slow. A log tells you *why*. They are only useful together if they share an identifier.

1. Enable log correlation on both services and restart them:

   ```bash
   # in BOTH terminals, before relaunching
   export OTEL_PYTHON_LOG_CORRELATION=true
   opentelemetry-instrument flask --app app run --port 8081   # backend
   opentelemetry-instrument flask --app app run --port 8080   # frontend
   ```

2. Send one request and read the backend log:

   ```bash
   curl -s -o /dev/null http://127.0.0.1:8080/checkout
   ```

   ```
   2026-09-03 12:19:44,081 INFO [app] [app.py:12] [trace_id=6b0f2a94c1e37d58b2ac09ff41e6d370 span_id=7d41c9a0e28b6f13 resource.service.name=backend trace_sampled=True] - inbound traceparent=00-6b0f2a94c1e37d58b2ac09ff41e6d370-4e19c73da05b8f26-01 baggage=None
   ```

3. Perform the operation you would perform at 03:00 during an incident — go from a log line to the full distributed trace:

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

4. And the reverse direction — from a trace ID found in the UI, grep every log line of the request across all services:

   ```bash
   # with both services' stdout redirected to files in a real deployment:
   grep -h "trace_id=${TID}" /var/log/shop/*.log
   ```

5. Inspect the format that produced this and note it is configurable:

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

> **Q7.1** — The log line carries `trace_id`, `span_id` *and* `trace_sampled`. Why is `trace_sampled=False` a critical field to log rather than a curiosity?
>
> **Q7.2** — `OTEL_PYTHON_LOG_CORRELATION=true` injected IDs into the existing logging pipeline; `OTEL_LOGS_EXPORTER=otlp` would ship the logs themselves through OTLP. These are two different features — describe each and say when you would use only the first.
>
> **Q7.3** — This is the third pillar of the correlation triangle. What is the metrics-side mechanism that links a Prometheus histogram bucket to a specific trace, and what does that let you click through from a latency graph?
>
> **Q7.4** — The `span_id` in the log line refers to the currently active span. If you log inside a `with tracer.start_as_current_span(...)` block, which span ID appears? What appears if the log is emitted from a background thread with no active context?

---

## Exercise 8 — Diagnosing a latency regression from spans alone

1. Introduce a realistic pathology — a synchronous loop of small calls (the classic N+1):

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

   Restart the frontend and generate traffic:

   ```bash
   for i in $(seq 1 8); do curl -s -o /dev/null http://127.0.0.1:8080/cart; done; sleep 20
   ```

2. Find the slowest trace without opening a browser:

   ```bash
   curl -s 'http://localhost:16686/api/traces?service=frontend&operation=GET%20%2Fcart&lookback=5m&limit=50' \
     | jq -r '[.data[] | {traceID, root: (.spans[] | select((.references|length)==0) | .duration)}]
              | sort_by(-.root) | .[0] | "\(.traceID)\t\(.root/1000)ms"'
   ```

   ```
   0c73e5a1f92b46d8ae0157cc3b9f2d40	512.804ms
   ```

3. Break that trace down by operation — count and total time, which is what actually identifies an N+1:

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

4. Confirm the calls are sequential rather than concurrent, by comparing the sum of children against the parent's wall time:

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

5. Check the service dependency graph the backend derived from span kinds:

   ```bash
   NOW_MS=$(( $(date +%s) * 1000 ))
   curl -s "http://localhost:16686/api/dependencies?endTs=${NOW_MS}&lookback=3600000" | jq -c '.data'
   ```

   ```
   [{"parent":"frontend","child":"backend","callCount":64}]
   ```

> **Q8.1** — Step 4 showed `sum(children) ≈ 95%` of the parent's duration. What does a ratio near 100% tell you, and what would a ratio near 12% with 8 children tell you instead?
>
> **Q8.2** — The trace shows `n=8` identical `GET /inventory` spans. Name the anti-pattern and give the two standard remediations. Which one would the trace *confirm* had worked, and how would the new waterfall look?
>
> **Q8.3** — You open a trace and a child span appears to start 4 ms *before* its parent. Traces cannot violate causality. What is the cause, and what do Jaeger and other UIs do about it?
>
> **Q8.4** — A trace arrives containing only the backend's `GET /inventory` span, with a `parentSpanId` pointing at a span that is not in the store. Give three distinct causes for this orphan, and say how you would tell them apart.
>
> **Q8.5** — The dependency graph in step 5 was *derived*, not configured. What span field makes that derivation possible, and why would the graph be empty if every span were `kind: INTERNAL`?
>
> **Q8.6** — Duration alone did not tell you where the time went; the breakdown by operation did. Define the **critical path** of a trace and explain why optimising a span that is *not* on it produces no end-user improvement.

---

## Exercise 9 — Teardown

1. Stop the two Flask processes with `Ctrl-C` in their terminals.
2. Remove the containers, network and volumes:

   ```bash
   cd ~/otel-lab && docker compose down -v
   docker compose ps -a
   ```

   ```
   NAME      IMAGE     COMMAND   SERVICE   CREATED   STATUS    PORTS
   ```

3. Confirm nothing is still listening on the OTLP ports:

   ```bash
   ss -ltnp 2>/dev/null | grep -E ':(4317|4318|16686)' || echo "all clear"
   ```

   ```
   all clear
   ```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** — The Python project versions the stable **API/SDK** as `1.x.y` and everything still under development — the `distro`, all `opentelemetry-instrumentation-*` packages and the semantic-convention package — as `0.NNbM`. The two lines are released together and the pairing is fixed: SDK `1.29.0` ↔ instrumentation `0.50b0`. Mixing them typically fails at import time or, worse, at runtime with `AttributeError` on an SDK internal, because instrumentation packages reach into non-public SDK surfaces (span processors, context managers). Pin both, and upgrade both in the same change.

**A0.2** — Instrumentation is library-specific monkey-patching: the Flask package wraps `Flask.wsgi_app` to open a SERVER span, the `requests` package wraps `Session.send` to open a CLIENT span and inject headers. Separating them means (a) you install only what you use, keeping the dependency surface and startup cost small, (b) each can be versioned against the supported range of *its* library, and (c) you can disable a single misbehaving instrumentation with `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS` without losing the rest. `opentelemetry-bootstrap` exists precisely to resolve "which of these do I need" from the installed dependency set.

### Exercise 1

**A1.1** — `trace-id` is **16 bytes / 128 bits**, `span-id` is **8 bytes / 64 bits**, both lowercase base-16 (hex), so 32 and 16 characters respectively. 128 bits is needed because trace IDs are generated independently by thousands of uncoordinated processes with no central allocator; at 64 bits the birthday bound makes collisions realistic at high volume, and a collision merges two unrelated requests into one nonsensical trace — a silent data-corruption bug that is nearly impossible to diagnose. Span IDs stay at 64 bits because they only need to be unique *within* a single trace.

**A1.2** —
1. `trace-id` is all zeros — explicitly invalid; the all-zero value is the reserved "invalid" sentinel.
2. `parent-id` (span-id) is all zeros — invalid for the same reason.
3. `trace-id` is 31 hex characters, not 32 — wrong length.

A compliant receiver must **discard the entire `traceparent` header and start a new trace** (it becomes a root span). It must *not* attempt to repair the header, and it must not reject the request — tracing is not allowed to break the application. Note the asymmetry: an invalid `traceparent` also means the accompanying `tracestate` must be discarded.

**A1.3** — `trace-flags` is an 8-bit field; bit 0 (value `0x01`) is the **sampled** flag, meaning "the caller recorded this trace and you should too". All other bits are currently reserved and must be ignored, not assumed zero, so test with a bitmask (`flags & 0x01`), never with string equality against `"01"`. A value of `00` does **not** mean stop propagating: the header must still be forwarded so that the trace identity survives, allowing downstream systems with their own sampling logic to make a coherent decision and keeping the ID available for log correlation.

**A1.4** — `tracestate` carries **tracing-system state**: vendor-specific position information keyed by vendor, so that a multi-vendor path can each track its own parent span. It is written and read by the tracing implementation, ordered (leftmost = most recently modified), and capped (max 32 list members; implementations should keep the header under 512 characters). **`baggage`** (a separate W3C specification) carries **application-level key/value context** — arbitrary user data propagated for the developer's benefit. `userId=alice` is application data, so it belongs in `baggage`.

**A1.5** — (1) **Privacy/security**: baggage is sent as a plaintext HTTP header to *every* downstream hop, including third-party APIs and any proxy or CDN in the path, and it commonly ends up in access logs. Putting PII there is an uncontrolled data exfiltration channel. (2) **Cost and correctness**: baggage inflates every single request's header size for the whole depth of the call graph, and headers are subject to size limits at proxies — oversized baggage causes `431`/`400` failures that appear only under specific paths. Additionally, baggage is *not* automatically copied onto spans; assuming it will show up in your traces requires an explicit baggage span processor.

### Exercise 2

**A2.1** — OTLP/JSON follows the **proto3 JSON mapping**, in which 64-bit integer fields (`int64`, `uint64`, `fixed64`) are encoded as **strings**, because IEEE-754 doubles — what JSON numbers are — cannot represent integers above 2^53 exactly. `startTimeUnixNano` is a `fixed64` and `intValue` is an `int64`, so both are quoted. `kind` is an enum, mapped to a plain number (or its name string). Sending an unquoted nanosecond timestamp risks silent precision loss in the microsecond range; strict parsers reject it outright. Note one deliberate OTLP deviation from proto3 JSON: `traceId`/`spanId` are `bytes` fields, which proto3 JSON would base64-encode, but OTLP mandates **lowercase hex** so they match the `traceparent` header.

**A2.2** — `ExportTraceServiceResponse.partial_success` is how OTLP reports *partial* acceptance. Empty means everything was accepted. A non-empty one looks like `{"partialSuccess":{"rejectedSpans":"3","errorMessage":"span attribute limit exceeded"}}` — the server accepted the batch but dropped 3 spans and told you why. This is strictly better than a bare `200` because without it a client cannot distinguish "all stored" from "silently dropped 90% over a quota"; clients are required to log a non-empty `partialSuccess` as a warning but must **not** retry, since retrying would duplicate the accepted spans.

**A2.3** — A **resource** describes the *entity producing telemetry* — it is identical for every span from that process and is therefore hoisted out of the span to avoid repeating it thousands of times on the wire. A **span attribute** describes *this one operation*. Rule of thumb: if the value can change between two spans from the same process, it is a span attribute. `service.name` is the one resource attribute OTLP requires; when it is absent, SDKs and backends fall back to `unknown_service` (often `unknown_service:python`), and you get an unnavigable pile of spans under a single meaningless service.

**A2.4** — `0 = UNSPECIFIED`, `1 = INTERNAL`, `2 = SERVER`, `3 = CLIENT`, `4 = PRODUCER`, `5 = CONSUMER`. Span kind encodes the *remoteness and direction* of the boundary. A CLIENT span and the SERVER span it triggers are the two ends of one network hop, so a backend can collapse them into a directed edge `caller → callee` and aggregate those edges into a dependency graph. Parent/child alone cannot do this: a parent/child pair inside a single process (INTERNAL) is not an edge, and PRODUCER/CONSUMER pairs are linked asynchronously with no synchronous parent at all. Span kind is also what tells the UI where to expect network latency (the gap between CLIENT duration and SERVER duration).

**A2.5** — `0 = UNSET`, `1 = OK`, `2 = ERROR`. `UNSET` is the default because status is meant to be set only when the instrumentation has *information* about the outcome. If `OK` were the default, every span would assert success — including spans from code paths that never checked — and `OK` would carry no signal. Also, by convention instrumentation libraries should leave status `UNSET` for successful operations and reserve explicit `OK` for application code that deliberately overrides a would-be error (e.g. a `404` that is expected). Backends therefore treat `UNSET` and `OK` identically for error rates and alert only on `ERROR`.

**A2.6** — The Jaeger API reports `duration` in **microseconds**; OTLP timestamps are in **nanoseconds**. Prometheus, by contrast, conventionally uses **seconds** (floats). Mixing them produces off-by-1000 errors that are invisible in a code review and produce dashboards claiming sub-millisecond p99s or 15-minute median latencies. Always assert the unit at the boundary — this is exactly why OpenTelemetry semantic conventions require units to be part of the metric/attribute definition rather than implied.

### Exercise 3

**A3.1** — Two instrumentations. `opentelemetry-instrumentation-flask` wrapped the WSGI entry point: it **extracted** context from the inbound request and started a `SERVER` span. `opentelemetry-instrumentation-requests` wrapped the outgoing HTTP client: it started a `CLIENT` span and **injected** the `traceparent` header into the outbound request from the current context. The injection was done by the `requests` instrumentation, not by Flask. Remove `opentelemetry-instrumentation-requests` and the backend still traces — but as a disconnected root.

**A3.2** — The CLIENT span measures the call as the *caller* experiences it: DNS, TCP/TLS setup, request serialisation, network transit both ways, connection-pool wait, and client-side retries. The SERVER span measures only the time the *callee* spent inside its own handler. The difference (here ~5.4 ms) is exactly the network + queueing + serialisation overhead invisible to either side alone. This gap is the single most valuable number in a distributed trace: a healthy service with a huge gap points at the network, the load balancer, or client-side connection starvation — not at the service.

**A3.3** — Tracing is designed to fail open: instrumentation must never break the request. When the backend found no `traceparent` it simply started a new root trace, exactly as it would for a legitimate entry-point request. Every response code, latency and log stayed normal — only the *joins* were lost, and they are lost quietly. Detection: (1) **monitor the root-span ratio per service** — a service that should never be an entry point suddenly reporting a high proportion of spans with no parent is the signature; (2) **synthetic checks** that inject a known `traceparent` at the edge and assert the trace has the expected span count and service set, as in step 7; (3) at the collector, a `spanmetrics`/`count` view of orphan traces per service.

**A3.4** — With `OTEL_EXPORTER_OTLP_ENDPOINT` (the *signal-agnostic* variable) and `http/protobuf`, the SDK **appends the signal path**, so it POSTs to `http://localhost:4318/v1/traces` (and `/v1/metrics`, `/v1/logs` for the other signals). With `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (the *signal-specific* variable) the value is used **verbatim**, path and all — you must write `http://localhost:4318/v1/traces` yourself, and a common failure is setting the specific variable to a bare host and getting `404`. For gRPC the endpoint has no path in either case: `http://localhost:4317`.

**A3.5** — It is a **composite**, not a fallback chain. On **extract**, all listed propagators run and their results merge (so a request carrying both `traceparent` and `baggage` yields both). On **inject**, all listed propagators write their headers, so the outbound request gets `traceparent` *and* `baggage`. During a migration off B3 you set `OTEL_PROPAGATORS=tracecontext,baggage,b3multi` on **every** service: newly migrated services emit both formats and accept either, so the fleet stays connected regardless of migration order; you drop `b3multi` only once the last legacy service is gone.

**A3.6** — The value is that it makes trace context an **injectable input**: load generators, synthetic monitors, CI end-to-end tests and manual `curl` reproductions can all pin a known trace ID and then assert on the resulting trace — turning tracing into something testable rather than something you hope works. The security consequence is that a client-supplied `traceparent` is **untrusted input**: an attacker can force `sampled=1` on every request to drive up your ingest bill (a cheap denial-of-wallet), can collide trace IDs to poison other users' traces, or can stuff oversized `tracestate`/`baggage`. At the edge, either strip and regenerate trace context, or accept it only from authenticated internal callers, and always apply rate limiting and header-size limits.

### Exercise 4

**A4.1** — An **attribute** describes the span as a whole and is true for its entire duration (`shop.order.id`); an **event** is a *point in time within* the span, with its own timestamp (`rules.loaded` at t+2 ms). Use an event when *when it happened* inside the operation matters. A span event is not a log line: it is structurally bound to the span (no separate correlation needed), it inherits the span's sampling decision, it has a hard cardinality/count limit per span, and it cannot exist outside a span's lifetime. Logs are independent records that survive when no span is active and can carry unbounded volume. Jaeger renders events under `logs` for historical reasons — that is a Jaeger data-model artefact, not the OpenTelemetry concept.

**A4.2** — The operation list would have grown by one entry per order — thousands, then millions. This is **high cardinality in the span name**, and it is destructive: the backend's operation index explodes, "search by operation" becomes unusable, aggregations like "p99 of `fraud.check`" become impossible because no two spans share a name, and any metrics derived from span names (e.g. the `spanmetrics` connector) generate an unbounded time series set that will take down the metrics store. The rule: **span names must be low-cardinality**; identifiers go in attributes, which backends index differently and can drop or hash.

**A4.3** — `otel.status_code` / `otel.status_description` are the **OpenTelemetry** `Status` faithfully translated. `error=true` is a **Jaeger-specific** convention (inherited from OpenTracing) that the translation layer synthesises so Jaeger's own UI and search can flag the span. This matters because a query written against `error=true` is portable to nothing else — move to Tempo, Zipkin or a vendor and it silently returns zero results. Write alerting and dashboards against the OpenTelemetry semantics (`status.code = ERROR`, `error.type`) and treat backend-specific tags as UI conveniences only.

**A4.4** — Neither implies the other, and they answer different questions. `record_exception()` adds an **event** (`exception.type`, `exception.message`, `exception.stacktrace`) — it says "this exception occurred here", which is compatible with an exception that was caught and handled successfully. `set_status(ERROR)` marks the **span's outcome** as failed, which is what error rates, alerting and tail sampling key on. Record only the exception and your error-rate dashboards show zero while stack traces pile up. Set only the status and you know the request failed but have no stack trace to act on. On a genuine failure path, do both.

**A4.5** — Semantic conventions reserve a set of top-level namespaces (`http.`, `db.`, `rpc.`, `messaging.`, `net.`, `url.`, `k8s.`, `cloud.`, `otel.`, `service.`, `error.`, …) for the specification. Application-specific attributes must use your own namespace — a company or domain prefix such as `shop.` — with dot-separated lowercase segments. Inventing `http.order_priority` is a forward-compatibility bomb: a future version of the spec may define that key with different semantics or a different type, at which point your data collides with the standard one, backends that special-case `http.*` will misinterpret it, and any processor doing convention-based transformation will corrupt it.

**A4.6** — A **span link**. A link references another span context (trace ID + span ID, optionally with attributes) without establishing a parent/child relationship, so it expresses causal association across trace boundaries. A batch consumer needs it precisely because a single consumer span processes *N* messages originating from *N* different traces: there is no single parent to attach to, and forcing one would either merge unrelated traces or discard the connection entirely. The consumer span links to all *N* producer contexts, and the UI lets you jump from the batch to any originating request.

### Exercise 5

**A5.1** — **A component only runs if it is listed in a pipeline under `service.pipelines`.** The top-level `receivers:`/`processors:`/`exporters:` blocks are *definitions*; `service:` is the *wiring*. The collector did not warn because at the time this behaviour was designed, defining unused components was a legitimate pattern (staging configs, generated fragments). Modern collector versions do log at startup that a defined component is unused, but it is `info`-level and easy to miss — which is exactly why step 3's `validate` subcommand is necessary but *not sufficient*: a config can be perfectly valid and do nothing. Verify the *effect* (step 6), not the syntax.

**A5.2** — `memory_limiter` must be **first** so it can refuse data at the earliest possible point: its purpose is to protect the collector from OOM, and it does this by returning a retryable error to the receiver, which propagates backpressure to the sender. Any processor before it does work on data that may be dropped anyway, and — worse — that data is already buffered in memory, which is what you were trying to avoid. `batch` must be **last** because batching is about efficient egress: it should group the data that actually survived all filtering, sampling and enrichment. Putting `batch` before `memory_limiter` means the limiter sees large aggregated chunks instead of a smooth stream, so it reacts in coarse steps, the memory spike happens *inside* the batcher where the limiter cannot see it, and backpressure to the receiver is delayed by a full batch timeout.

**A5.3** — The syntax is `type/name`: the part before the slash is the **component type** (must match a compiled-in component such as `otlp`, `attributes`, `resource`), and the part after is an arbitrary **instance name** used only to disambiguate. The suffix is required whenever you need **two or more instances of the same type** in one config — here there is one `attributes` block, but naming it `attributes/scrub` documents intent and leaves room for a second; `otlp/jaeger` would collide with the `otlp` *receiver* name in a reader's mind without it. `batch` needs no suffix because there is exactly one.

**A5.4** — `opentelemetry-collector` (**core**) contains only the components maintained in the core repository — OTLP receiver/exporter, batch, memory_limiter, a handful more. **`-contrib`** additionally bundles the several hundred community components: `tail_sampling`, `spanmetrics`, `loadbalancing`, `prometheus`, `filelog`, every vendor exporter. This config needs contrib for `tail_sampling` (Exercise 6); the `attributes` processor and `debug` exporter are in core. The production alternative to shipping contrib is the **OpenTelemetry Collector Builder (`ocb`)**: you declare exactly the components you need in a manifest and it compiles a custom distribution. This cuts the binary from hundreds of MB to tens, and — the real reason — it eliminates the attack surface and CVE exposure of hundreds of components you never use.

**A5.5** — Gained: (1) **decoupling** — the backend address, protocol and credentials change in one place, not in every deployment; (2) **buffering, retry and backpressure** on behalf of thin clients, including surviving a backend outage without the application blocking; (3) **enrichment** with environment/infrastructure metadata the process cannot know (`k8s.cluster.name`, node, region, and via `k8sattributes` the pod/namespace/owner); (4) **redaction and policy enforcement** applied uniformly, in ops-controlled config, regardless of what any team's SDK does. Of these, (3) and (4) are the ones the SDK genuinely *cannot* do: the application has no reliable view of its own infrastructure context, and — critically — redaction enforced in application code is unenforceable policy, since it depends on every team getting it right in every service. Centralised scrubbing is the only auditable form.

**A5.6** — **Agent**: one collector per host or pod (DaemonSet or sidecar), reached over `localhost` or the node IP. It offloads the SDK immediately, enriches with host/pod-local metadata that only a local process can see, and survives application restarts. **Gateway**: a standalone, independently scalable Deployment behind a Service, receiving from many agents or applications. It does the expensive, fleet-wide work: tail sampling, aggregation, egress to vendors, credential holding. This lab runs a **gateway** (a single shared instance the applications point at). A two-tier agent→gateway topology gives you: local enrichment plus a short, reliable first hop for the application; a single egress point holding vendor credentials; the ability to scale the CPU-heavy gateway independently of node count; and — the requirement for tail sampling — a place where all spans of a trace can be brought together.

**A5.7** — They are **lost permanently**. `sending_queue` is in-memory by default, so eviction, OOM-kill, node drain or a rolling deploy discards whatever is queued. The knob is **`file_storage`**: enable the `file_storage` extension and reference it as `sending_queue.storage`, which persists the queue to disk so it survives a restart. In Kubernetes this requires a real volume, which in turn pushes you toward a StatefulSet for the gateway — a genuine operational cost. The usual trade-off: accept in-memory loss for traces (sampled data, individually expendable) and use persistent queues where each record matters.

### Exercise 6

**A6.1** — The frontend is the **root** of the trace, so its sampler makes the decision and encodes it in the `traceparent` `sampled` flag. The backend's default sampler is `parentbased_always_on`, whose *parent-based* wrapper means: **if there is a parent context, obey its sampled flag**; only apply the delegate sampler (`always_on`) when there is no parent. So the backend faithfully dropped the 90% the frontend marked unsampled. With plain `traceidratio` on the backend — no parent-based wrapper — the backend would ignore the incoming flag and make its own independent draw, producing **broken traces**: roughly 10% of backend spans would be kept for traces whose frontend spans were dropped (orphans) and ~90% of the frontend's sampled traces would be missing their backend half. Partial traces are worse than no traces, because they lead you to false conclusions.

**A6.2** — Because the header is not only a sampling signal, it is the **request's identity**. Propagating it when unsampled preserves: log correlation (Exercise 7 — you can still grep by trace ID even with no stored trace), the ability of a downstream service to apply its own policy (a debug-flagged tenant, an error path that upgrades the decision), and consistent behaviour if a tail sampler later decides to keep the trace. A **non-recording span** is the object the SDK returns for an unsampled trace: it carries a valid `SpanContext` (so `inject` works and `trace_id` is available to loggers) but discards all attributes, events and status without allocating, and is never exported. It is the mechanism that makes unsampled tracing nearly free.

**A6.3** — Deriving the decision deterministically from the trace ID means **every service computes the same answer for the same trace, without communicating**. This is what makes consistent sampling possible across independently deployed, differently-configured services, and it is why the trace ID must be uniformly random. `random.random() < 0.1` per service would make each hop an independent coin flip: for a 4-service trace at 10% each, the probability that a *complete* trace survives is 0.1⁴ = 0.01% — while you still pay to store ~35% of traces as useless fragments. You would get maximum cost and minimum value simultaneously.

**A6.4** — **Head-based**: the decision is made at the root, *before* the request executes — cheap, stateless, immediately effective at reducing load on every downstream hop and on the network, but made with **no knowledge of the outcome**, so it discards errors and slow requests at the same rate as boring successes. **Tail-based**: the decision is made after the whole trace has been observed — it can keep exactly the interesting traces (errors, high latency, specific tenants), but it requires **transporting and buffering 100% of spans** to a stateful component first, so you pay full network and collector cost and gain only on storage.

**A6.5** — During `decision_wait` the collector **buffers every span of every in-flight trace in memory**, keyed by trace ID, waiting for the trace to be "complete enough" to evaluate the policies against. The cost is roughly `throughput × decision_wait × average span size`, bounded by `num_traces` (the LRU cache of trace IDs) — this is why both knobs exist and why a gateway doing tail sampling is memory-hungry and must be sized deliberately. A span arriving at second 11 is **too late**: the decision has already been made and emitted, so a late span either arrives at the backend as a fragment of an otherwise-dropped trace or is discarded outright. `decision_wait` must therefore exceed your p99 *trace* duration, not your p99 request duration — long-running traces are systematically mis-sampled.

**A6.6** — With round-robin load balancing, the spans of a single trace are **spread across all 3 replicas**. Each replica then evaluates policies against the fragment it happens to hold: a replica that received only the successful frontend span sees no error and drops it, while the replica holding the errored backend span keeps it. The result is systematically **broken traces plus wrong decisions** — precisely the failure tail sampling exists to prevent. The fix is the **`loadbalancing` exporter** in a first collector tier, configured with **`routing_key: traceID`**, which hashes the trace ID to pick a backend collector so all spans of a trace land on the same tail-sampling replica. (For the `spanmetrics` use case the key is `service` instead.) This is why tail sampling forces a two-tier collector topology.

**A6.7** — The policies are **OR-combined**: a trace is kept if *any* policy says keep. A fast, successful, `bronze` trace matches none of the first three, so only `baseline-sample` applies — it is kept with probability **10%**. Adding an `always_sample` policy would set the effective sampling rate to **100% for every trace**, because that policy alone would match everything and OR would make the rest irrelevant — a common and expensive misconfiguration. To express "keep 10% of normal traffic *and only that*", you must instead compose with the `and` policy type or express the exclusion inside the policy set; there is no "else" in tail sampling.

### Exercise 7

**A7.1** — Because it tells you **whether following the trace ID will lead anywhere**. On a sampled fleet, most log lines carry a trace ID whose trace was never stored. Without `trace_sampled`, an engineer clicks through, gets "trace not found", and reasonably concludes the tracing pipeline is broken — a false alarm that erodes trust in the whole system. With it, "not found" is expected and correct for `trace_sampled=False`, and genuinely alarming for `True`. It also gives you a cheap, log-derived measure of your actual achieved sampling rate, independent of what you configured.

**A7.2** — **Log correlation** (`OTEL_PYTHON_LOG_CORRELATION=true`) injects `otelTraceID`/`otelSpanID` into the standard-library `LogRecord` and changes the default format string to print them. Your logs continue to go wherever they always went — stdout, files, `journald`, an existing Fluent Bit/Loki pipeline. **Log export** (`OTEL_LOGS_EXPORTER=otlp`) additionally converts log records into OTLP log records and ships them through the OpenTelemetry pipeline, giving you the collector's processors and a single egress. Use only correlation when you already have a mature, trusted log pipeline you do not want to replace: you get the entire correlation benefit for one environment variable and zero migration risk, which is the overwhelmingly common production case.

**A7.3** — **Exemplars**. A Prometheus/OpenMetrics exemplar attaches a trace ID (and timestamp) to an individual observation inside a histogram bucket, so a single recorded sample points at the trace that produced it. It requires the OpenMetrics exposition format and must be enabled on both the instrumentation and the scrape side. The payoff is the workflow that makes the three pillars a system rather than three tools: you see a p99 latency spike on a Grafana panel, click the exemplar dot in the affected bucket, and land directly in a trace of one of the actual slow requests — instead of guessing at a time range and searching.

**A7.4** — The **innermost currently-active span** appears, because the logging instrumentation reads `trace.get_current_span()` from the active context at the moment the record is created — so inside `with tracer.start_as_current_span("fraud.check")`, the `fraud.check` span ID is logged, not the enclosing HTTP span. From a background thread with no active context, `get_current_span()` returns the **invalid span**, and the fields render as all zeros: `trace_id=00000000000000000000000000000000 span_id=0000000000000000`, with `trace_sampled=False`. This is a useful diagnostic in itself — all-zero IDs in logs mean context was lost across a thread, an executor, or an async boundary, and it is the standard signature of a missing context propagation in worker pools.

### Exercise 8

**A8.1** — A ratio near 100% means the children ran **strictly sequentially** and account for essentially all of the parent's time — the parent is doing no meaningful work of its own, it is just waiting on calls one after another. The fix is therefore in the *call pattern*, not the parent's code. A ratio near 12% with 8 children (≈ 100%/8) means the children ran **fully in parallel**: total child CPU/wall time is 8× the parent's elapsed time because they overlapped, and the parent's duration is bounded by the *slowest* child. In that case there is nothing to gain from concurrency — you must make the slowest child faster.

**A8.2** — The **N+1 query/request** anti-pattern. Remediations: (1) **batch** — replace the N calls with one bulk endpoint (`GET /inventory?sku=a,b,c`), which is the correct fix because it also removes N× the per-request overhead; (2) **parallelise** — issue the N calls concurrently, which caps latency at the slowest call but keeps the load on the callee. The trace confirms which one you shipped: after batching, the waterfall shows **one** child span (`n=1`) and the parent collapses to roughly one call's duration; after parallelising, it still shows **eight** child spans but they are drawn stacked and *overlapping*, with the parent's duration close to the longest single child rather than to their sum.

**A8.3** — **Clock skew** between the two hosts. Timestamps come from each process's own wall clock, and NTP-disciplined machines still routinely differ by single-digit milliseconds; containers, VM live-migration and virtualised clocks make it worse. The trace is not wrong about causality — the clocks disagree. Jaeger applies a **clock-skew adjustment**: it uses the CLIENT/SERVER span pair as a reference (the server span must be contained within the client span) to compute an offset, shifts the child's timestamps, and annotates the adjusted span with a warning such as `clock skew adjustment disabled; not applying calculated delta` or a note of the delta applied. The practical consequences: never compute a duration by subtracting timestamps taken on *different* hosts, and treat sub-10 ms cross-service timings as noise unless you have PTP-grade clocks.

**A8.4** — Three causes: (1) **The parent was sampled away** — e.g. an upstream running head-based sampling made a different decision, or a tail sampler dropped it while a late span leaked through. (2) **Propagation is broken upstream** — no, in this case the parent ID *is* present, so more precisely: the parent service is not instrumented for export, or its exporter is failing (queue full, backend unreachable, credentials expired), so it propagates context correctly but never ships its own spans. (3) **The parent's spans have not arrived or were dropped in transit** — a collector restart, a `sending_queue` overflow, or simply a race where you queried before the parent's batch flushed. Telling them apart: check whether `trace_sampled` in the upstream's logs was `False` (cause 1); check the upstream collector's `otelcol_exporter_send_failed_spans` and the SDK's own dropped-span metrics (cause 2); re-query after a batch interval and check `otelcol_processor_dropped_spans` and receiver refusal counters (cause 3). If the upstream service does not appear in `/api/services` at all, it is cause 2.

**A8.5** — **`span.kind`** — specifically the CLIENT/SERVER (and PRODUCER/CONSUMER) pairing, matched by trace ID and parent/child relationship, combined with each span's resource `service.name`. The backend walks each trace, finds every place where a span of one service is the parent of a span of another, and emits an edge. If every span were `kind: INTERNAL`, there would be no signal that a boundary was crossed — the parent/child links would still exist, but they would be indistinguishable from ordinary in-process nesting, so no edges could be inferred and the dependency graph would be empty. This is the concrete, load-bearing reason span kind is not optional decoration.

**A8.6** — The **critical path** is the chain of spans that actually determines the trace's total duration: starting from the root's end, at each level the child whose completion the parent was waiting on, recursively. Work that runs concurrently with — and finishes before — the critical path contributes nothing to end-user latency. Optimising a span off the critical path produces zero user-visible improvement because the request was never waiting on it: you make a parallel branch finish in 10 ms instead of 40 ms while the request still waits 500 ms for the branch that gates the response. This is why "the slowest span" is the wrong target and "the span on the critical path with the largest exclusive time" is the right one — and why a waterfall view, which makes overlap visible, beats any sorted list of durations.

</details>

---

## Sources

- LPI — Exam 701 objectives: <https://www.lpi.org/our-certifications/exam-701-objectives/>
- W3C — Trace Context (Recommendation): <https://www.w3.org/TR/trace-context/>
- W3C — Baggage: <https://www.w3.org/TR/baggage/>
- OpenTelemetry — Traces concepts: <https://opentelemetry.io/docs/concepts/signals/traces/>
- OpenTelemetry — Sampling: <https://opentelemetry.io/docs/concepts/sampling/>
- OpenTelemetry — OTLP specification: <https://opentelemetry.io/docs/specs/otlp/>
- OpenTelemetry — Semantic conventions: <https://opentelemetry.io/docs/specs/semconv/>
- OpenTelemetry — SDK environment variables: <https://opentelemetry.io/docs/languages/sdk-configuration/general/> and <https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/>
- OpenTelemetry — Python automatic instrumentation: <https://opentelemetry.io/docs/languages/python/automatic/>
- OpenTelemetry — Collector configuration: <https://opentelemetry.io/docs/collector/configuration/>
- OpenTelemetry — Collector deployment patterns: <https://opentelemetry.io/docs/collector/deployment/>
- OpenTelemetry Collector Contrib — `tailsamplingprocessor`: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor>
- OpenTelemetry Collector Contrib — `loadbalancingexporter`: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter>
- Jaeger — Getting started: <https://www.jaegertracing.io/docs/latest/getting-started/>
- Jaeger — APIs: <https://www.jaegertracing.io/docs/latest/apis/>
- Zipkin — Data model: <https://zipkin.io/pages/data_model.html> · B3 propagation: <https://github.com/openzipkin/b3-propagation>