# 701.1 — Modern Software Development

**Certification:** LPI DevOps Tools Engineer · **Exam:** 701-100 (version 2.0.0) · **Topic weight:** 10.0

> **Scope of this objective.** You are expected to *design* software components that survive being distributed: service-based decomposition, API contracts, state and configuration handling, containerisation, cloud deployment models, the risk profile of migrating a legacy monolith, and the common application security failure classes. This is a design objective, not a tooling objective — but every design decision below is written with the production failure it prevents, and with the commands you will actually type when it fails anyway.

---

## 1. The architectural problem this objective exists to solve

### 1.1 The failure mode of the deployment-coupled monolith

A single deployable unit containing the entire business domain is not, by itself, a defect. Monoliths are simpler to reason about, have no network in the middle of a function call, and give you real ACID transactions for free. The defect appears when the *organisation* scales and the *deployment unit* does not.

Consider a concrete production shape — a retail platform: catalogue, cart, checkout, payments, invoicing, search, notifications. One WAR file, one database schema, 38 engineers, one release train every two weeks.

The measurable pathologies:

| Symptom | Mechanism | Metric that degrades |
|---|---|---|
| Release cadence collapses | Any team's unmerged change blocks the train; the integration branch is a global lock | Deployment frequency, lead time for change |
| Blast radius is total | A memory leak in the PDF invoice renderer OOM-kills the process serving checkout | Availability, MTTR |
| Scaling is undifferentiated | Search needs 32 GB of heap; notifications need 256 MB. You buy 32 GB × N replicas | Cost per request, resource efficiency |
| Change failure rate rises | The regression surface of a release is the union of 38 people's changes | Change failure rate |
| Technology is frozen | The whole artefact must move JVM versions together | Time-to-adopt, hiring |

These four — deployment frequency, lead time, change failure rate, time to restore — are the DORA metrics. The point of "modern software development" in the LPI sense is that *architecture is the primary lever on those metrics*, and the architecture that moves them is one where **the unit of deployment matches the unit of ownership**.

### 1.2 The cost you are buying with

Decomposition does not delete complexity; it relocates it from the compiler to the network. The classic enumeration (Deutsch/Gosling, "Fallacies of Distributed Computing") is the exam-relevant list of things that stop being true the moment a method call becomes an HTTP call:

1. The network is reliable — it is not; every call needs a timeout, a retry policy, and an idempotency story.
2. Latency is zero — a 200 µs in-process call becomes a 2–20 ms RPC; a chatty refactor of a loop becomes an outage.
3. Bandwidth is infinite — N+1 query patterns across a service boundary saturate links.
4. The network is secure — you now need mTLS, authN/authZ on every hop, and network policy.
5. Topology doesn't change — pods are rescheduled continuously; never cache an IP.
6. There is one administrator — ownership is distributed; so is on-call.
7. Transport cost is zero — serialisation, TLS handshakes, and egress bytes are real money.
8. The network is homogeneous — MTU, proxies, HTTP/2 vs HTTP/1.1, and L7 middleboxes differ per hop.

**Design rule:** every synchronous call across a service boundary must declare, in code, a connect timeout, a read timeout, a retry budget (with jitter), and a fallback. A call without a timeout is an availability bug that has not fired yet.

### 1.3 Loose coupling is the actual objective

"Microservices" is a deployment topology. **Loose coupling** is the property you are after, and you can fail to get it at any topology. A system is loosely coupled when a change in one component does not force a coordinated change in another. The couplings to hunt down:

| Coupling type | How it manifests | Removal technique |
|---|---|---|
| Deployment coupling | Services must be released together in a fixed order | Backward/forward-compatible contracts, expand-contract migrations |
| Schema coupling | Two services write the same table | Database-per-service; one writer, others read via API or events |
| Temporal coupling | Caller blocks until callee answers | Asynchronous messaging, event-carried state transfer |
| Runtime coupling | Callee down ⇒ caller down | Circuit breaker, bulkhead, cached/degraded fallback |
| Semantic coupling | Callee's internal domain model leaks into caller | Anti-corruption layer, published contract ≠ internal model |
| Technology coupling | Shared library that pins a language/runtime version | Contract over the wire (HTTP/gRPC/AMQP), not shared binaries |

A "microservice" that shares a database table with three siblings is a distributed monolith: you paid the full network cost and bought none of the independence.

---

## 2. Service granularity: monolith → SOA → microservices

### 2.1 Comparative trade-off table

| Dimension | Modular monolith | SOA (classic, ESB-centric) | Microservices | Serverless / FaaS |
|---|---|---|---|---|
| Deployment unit | One artefact | Few coarse services + ESB | Many fine services | One function |
| Communication | In-process call | SOAP/XML over ESB, orchestration in the bus | REST/gRPC/events, dumb pipes, smart endpoints | Event triggers, HTTP gateway |
| Data ownership | One schema | Often one shared enterprise DB | One store per service | External stores only |
| Transactions | ACID | ACID within, XA across (fragile) | Saga / eventual consistency | Saga / eventual consistency |
| Failure isolation | None (shared process) | Partial (ESB is an SPOF) | High, if bulkheaded | High |
| Independent scaling | No | Coarse | Per service | Per invocation |
| Operational burden | Low | High (ESB is a specialist product) | High (needs platform: CI/CD, observability, service discovery) | Low infra, high vendor coupling |
| Latency profile | Best | Poor (bus hop + XML) | Medium, tail-latency sensitive | Cold starts |
| Right for | <15 engineers, single domain, unproven product | Enterprise integration of heterogeneous legacy systems | Multiple autonomous teams, differentiated scaling | Spiky, event-driven, stateless workloads |
| Primary failure mode | Release-train gridlock | The ESB becomes the monolith | Distributed monolith; observability debt | Vendor lock-in, cost surprise at steady load |

**Exam-relevant distinction between SOA and microservices:** SOA puts intelligence in the integration layer (the Enterprise Service Bus performs orchestration, transformation, routing); microservices push intelligence to the endpoints and keep the transport dumb. The consequence is organisational: an ESB requires a central integration team, which re-creates the coordination bottleneck that decomposition was supposed to remove.

### 2.2 Choosing boundaries

Boundaries drawn along technical layers (a "controller service", a "DAO service") produce maximal coupling — every feature crosses every service. Boundaries drawn along **business capabilities** (Order, Payment, Inventory) produce changes that land inside one service.

Two heuristics that survive production:

- **Conway's Law**: the system will mirror the communication structure of the organisation. If you want three independent services, you need three teams with independent roadmaps; otherwise the boundaries will erode.
- **The two-transaction test**: if a single user-visible operation requires an atomic write across two candidate services, the boundary is probably wrong. Either merge them, or accept a saga with explicit compensating actions and make eventual consistency visible in the UX ("payment pending").

### 2.3 Distributed data: saga instead of 2PC

Two-phase commit across services couples availability multiplicatively (a 99.9 % service times three ⇒ 99.7 %) and holds locks across the network. The production pattern is a **saga**: a sequence of local transactions, each publishing an event, with an explicit compensating transaction per step.

```
Order placed  ──▶ Payment authorised ──▶ Stock reserved ──▶ Shipment created
     │                    │                     │
     │                    │                     └─ compensate: release stock
     │                    └─ compensate: void authorisation
     └─ compensate: cancel order, notify customer
```

The non-negotiable implementation details:

- **Idempotency**: every consumer must tolerate duplicate delivery. Message brokers give at-least-once; exactly-once end-to-end does not exist without an idempotent sink. Persist a processed-message table keyed by message ID, or make the write naturally idempotent (`UPDATE ... WHERE state = 'PENDING'`).
- **Transactional outbox**: writing to the database and publishing to the broker are two systems. Write the event into an `outbox` table *inside the same local transaction*, and relay it asynchronously (change-data-capture or a poller). Otherwise a crash between the two produces a lost or phantom event.
- **Ordering**: only guaranteed per partition/key. Partition by aggregate ID (order ID), never round-robin, if order matters.

---

## 3. The Twelve-Factor App as an operational contract

The twelve-factor methodology is the canonical checklist for "software designed to be run in containers and deployed to a cloud service". Read it as a set of *constraints the platform requires*, not as style advice.

| # | Factor | Platform requirement it satisfies | Failure if violated |
|---|---|---|---|
| I | Codebase — one repo, many deploys | Traceability of an artefact to a commit | Cannot answer "what is running in prod?" |
| II | Dependencies — explicitly declared and isolated | Reproducible builds | "Works on my machine"; implicit system packages vanish in a slim base image |
| III | Config — in the environment | Same image promoted dev→stage→prod | Rebuild per environment; secrets baked into the image |
| IV | Backing services — attached resources | DB/cache/broker swappable by URL | Hard-coded host names; no failover, no local testing |
| V | Build, release, run — strictly separated | Immutable, re-deployable releases | Hot-patching a running container; drift |
| VI | Processes — stateless, share-nothing | Any replica serves any request | Sticky sessions required; scale-in drops user data |
| VII | Port binding — export via a port | The app is self-contained, no external app server | Needs a preinstalled container/servlet runtime |
| VIII | Concurrency — scale out via the process model | Horizontal autoscaling | Vertical-only scaling; single-process bottleneck |
| IX | Disposability — fast start, graceful shutdown | Rescheduling, preemption, autoscaling, rolling updates | 502s on every deploy; 30 s pod termination stalls |
| X | Dev/prod parity | Bugs surface before prod | SQLite in dev, PostgreSQL in prod ⇒ prod-only failures |
| XI | Logs — event streams to stdout | Centralised collection by the platform | Logs die with the container; no rotation inside the image |
| XII | Admin processes — one-off, same release | Migrations run with the deployed code | Schema drift between code and DB |

### 3.1 Factor III in practice — configuration, not secrets, and never both in the image

Three tiers, and they must be distinguished:

| Tier | Example | Mechanism | Rotation |
|---|---|---|---|
| Build-time constants | Compiler flags, base image | Dockerfile / build args | New image |
| Runtime configuration | Log level, feature flags, upstream URLs, pool sizes | Env vars / mounted ConfigMap | Restart, or hot-reload on file change |
| Secrets | DB password, API keys, TLS private keys | Secret store, mounted as file (preferably projected/short-lived) | Rotate without rebuild |

**Environment variables vs mounted files** — this comes up in the exam and in every incident review:

| Property | Env var | Mounted file |
|---|---|---|
| Visible in `/proc/<pid>/environ` | Yes | No |
| Leaks into crash dumps, error trackers, `docker inspect` | Yes, frequently | Rarely |
| Hot update without restart | No — the environment is fixed at `execve()` | Yes — kubelet updates the volume (ConfigMap/Secret volumes; not `subPath` mounts) |
| Size limit | ~2 MB argv+env (ARG_MAX) | Practically unlimited |
| Suitable for certificates / multi-line | No | Yes |

**Rule:** configuration in env vars is fine; secrets belong in files with mode `0400`, and ideally short-lived credentials issued at runtime rather than long-lived strings.

### 3.2 Factor IX — disposability is code, not configuration

The container runtime sends `SIGTERM`, waits `terminationGracePeriodSeconds`, then sends `SIGKILL`. Two things break here in practice:

1. **PID 1 does not have default signal handlers.** In the Linux kernel, PID 1 ignores signals for which it has not installed a handler. If your app is PID 1 and never registers a `SIGTERM` handler, `SIGTERM` is discarded and every shutdown takes the full grace period and then a hard kill — mid-request.
2. **Shell-form `CMD` makes `/bin/sh` PID 1**, and `sh` does not forward signals to its child. Use exec form: `CMD ["./server"]`, or `ENTRYPOINT ["/usr/bin/tini", "--"]` when you genuinely need a reaper for multi-process images.

Correct shutdown sequence — order matters:

```go
// main.go — graceful shutdown that actually drains
func main() {
	srv := &http.Server{Addr: ":8080", Handler: router()}

	// readiness flips to false first, so the endpoint controller
	// removes this pod from the Service before the listener closes.
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	ready.Store(false)                    // 1. fail the readiness probe
	time.Sleep(5 * time.Second)           // 2. let endpoint propagation catch up

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil { // 3. drain in-flight requests
		log.Printf("forced shutdown: %v", err)
	}
	db.Close()                            // 4. release backing services
	log.Print("exited cleanly")
}
```

The `time.Sleep` is not superstition: pod deletion sends `SIGTERM` and removes the endpoint **concurrently**, and kube-proxy/ingress data planes converge asynchronously. Closing the listener the instant `SIGTERM` arrives produces connection-refused errors for several hundred milliseconds to seconds of traffic. The equivalent declarative form is a `preStop` `sleep` hook (shown in §6.4).

### 3.3 Factor XI — logs as an event stream

Write to `stdout`/`stderr`, unbuffered, one event per line, structured. Do not open log files, do not configure rotation inside the container, do not ship logs from the application to the aggregator directly (that couples your app's availability to the logging backend).

Structured is the operative word: a line the collector can index without regex.

```
{"ts":"2026-09-18T09:14:22.418Z","level":"error","service":"orders","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","event":"payment_authorise_failed","order_id":"ord_01J8X","upstream":"payments","status":502,"latency_ms":3021,"retry":2}
```

The `trace_id` must be propagated from the inbound `traceparent` header (W3C Trace Context) — without it, correlating a user-visible 500 across seven services is manual archaeology. Logs, metrics and traces are the three signals; the design requirement is that all three carry the same correlation ID.

---

## 4. API concepts and standards

### 4.1 REST, and what "RESTful" actually constrains

REST is an architectural style (Fielding, 2000) with concrete constraints: client–server, **statelessness**, cacheability, uniform interface, layered system, and optional code-on-demand. The constraint that matters operationally is statelessness: *each request contains all information needed to service it*. That is what permits a load balancer to route any request to any replica, which is what permits horizontal scaling and rolling updates.

The Richardson Maturity Model is the usual scale:

| Level | Characteristic | Practical note |
|---|---|---|
| 0 | One URI, one verb (POST), RPC over HTTP | SOAP-style; no HTTP semantics used |
| 1 | Resources — many URIs | `/orders/42`, `/customers/7` |
| 2 | HTTP verbs and status codes | GET is safe & cacheable, PUT/DELETE idempotent, 201/404/409/422 used correctly |
| 3 | Hypermedia controls (HATEOAS) | Rare in practice; valuable for long-lived public APIs |

Level 2 is the realistic production target. The semantics that the exam and the CDN both care about:

| Method | Safe | Idempotent | Cacheable | Typical use |
|---|---|---|---|---|
| GET | Yes | Yes | Yes | Read |
| HEAD | Yes | Yes | Yes | Metadata / existence |
| PUT | No | **Yes** | No | Full replace at a known URI |
| DELETE | No | **Yes** | No | Removal (repeat ⇒ 404 or 204) |
| POST | No | **No** | Rarely | Create at a server-chosen URI, non-CRUD action |
| PATCH | No | No | No | Partial update (RFC 7396 merge-patch or RFC 6902 JSON Patch) |

**Because POST is not idempotent, a retry after a timeout can double-charge a customer.** The standard mitigation is an `Idempotency-Key` request header: the server stores the key with the response for a TTL and replays the stored response on a repeat. Any API that moves money or creates resources over an unreliable network needs this.

### 4.2 JSON and the media type discipline

JSON (RFC 8259) is the default representation: UTF-8, no comments, no trailing commas, no NaN/Infinity. The production hazards:

- **Number precision.** JSON numbers are IEEE-754 doubles in most parsers; integers above 2^53 lose precision. Serialise 64-bit IDs and monetary amounts as strings, or use minor units (integer cents) — never floats for money.
- **Dates.** Always RFC 3339 / ISO 8601 with an explicit offset (`2026-09-18T09:14:22Z`). Never a locale-formatted string, never a bare epoch without documenting the unit.
- **Unknown fields.** Consumers must ignore fields they do not know (tolerant reader). This is what makes additive changes non-breaking.
- **Errors.** Use `application/problem+json` (RFC 9457) instead of inventing an error envelope per team.

A problem response, which is a single JSON document:

```json
{
  "type": "https://api.example.com/problems/insufficient-funds",
  "title": "Insufficient funds",
  "status": 409,
  "detail": "Account acc_8812 has a balance of 24.50 EUR; the authorisation requires 89.90 EUR.",
  "instance": "/orders/ord_01J8X/payments",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "balance_minor_units": 2450,
  "required_minor_units": 8990
}
```

### 4.3 The contract is a file, and it is versioned

An API without a machine-readable contract cannot be validated in CI, cannot generate clients, and cannot be diffed for breaking changes. OpenAPI is the standard for HTTP APIs.

```yaml
openapi: 3.1.0
info:
  title: Orders API
  version: 2.3.0
  description: "Order lifecycle: creation, authorisation and cancellation."
  contact:
    name: Platform Team
    url: "https://internal.example.com/teams/platform"
servers:
  - url: "https://api.example.com/v2"
    description: Production
  - url: "https://api.staging.example.com/v2"
    description: Staging
security:
  - bearerAuth: []
paths:
  /orders:
    get:
      summary: List orders
      operationId: listOrders
      parameters:
        - name: cursor
          in: query
          required: false
          description: "Opaque cursor returned by the previous page."
          schema:
            type: string
        - name: limit
          in: query
          required: false
          schema:
            type: integer
            minimum: 1
            maximum: 200
            default: 50
      responses:
        "200":
          description: A page of orders
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/OrderPage"
        "429":
          $ref: "#/components/responses/RateLimited"
    post:
      summary: Create an order
      operationId: createOrder
      parameters:
        - name: Idempotency-Key
          in: header
          required: true
          description: "Client-generated UUIDv4; replays return the original response."
          schema:
            type: string
            format: uuid
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/OrderCreate"
      responses:
        "201":
          description: Created
          headers:
            Location:
              description: "URI of the created order."
              schema:
                type: string
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
        "409":
          description: Idempotency key reused with a different payload
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
  /orders/{orderId}:
    parameters:
      - name: orderId
        in: path
        required: true
        schema:
          type: string
    get:
      summary: Fetch a single order
      operationId: getOrder
      responses:
        "200":
          description: The order
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
        "404":
          description: No such order
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
  responses:
    RateLimited:
      description: Too many requests
      headers:
        Retry-After:
          description: "Seconds to wait before retrying."
          schema:
            type: integer
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
  schemas:
    OrderCreate:
      type: object
      required:
        - customerId
        - lines
      properties:
        customerId:
          type: string
        lines:
          type: array
          minItems: 1
          items:
            $ref: "#/components/schemas/OrderLine"
    OrderLine:
      type: object
      required:
        - sku
        - quantity
      properties:
        sku:
          type: string
        quantity:
          type: integer
          minimum: 1
        unitPriceMinor:
          type: integer
          description: "Price in minor units, for example cents. Never a float."
    Order:
      type: object
      required:
        - id
        - status
        - createdAt
      properties:
        id:
          type: string
        status:
          type: string
          enum:
            - pending
            - authorised
            - shipped
            - cancelled
        createdAt:
          type: string
          format: date-time
        totalMinor:
          type: integer
        currency:
          type: string
          example: EUR
    OrderPage:
      type: object
      required:
        - items
      properties:
        items:
          type: array
          items:
            $ref: "#/components/schemas/Order"
        nextCursor:
          type: string
          nullable: true
    Problem:
      type: object
      properties:
        type:
          type: string
        title:
          type: string
        status:
          type: integer
        detail:
          type: string
        instance:
          type: string
```

Validate it in CI — a contract that is not validated is documentation, and documentation drifts:

```
$ redocly lint openapi.yaml
validating openapi.yaml...
openapi.yaml: validated in 84ms

Woohoo! Your API description is valid. 🎉

$ oasdiff breaking https://api.example.com/v2/openapi.yaml ./openapi.yaml
1 breaking changes: 1 error, 0 warning
error   [response-property-removed] at ./openapi.yaml
        in API GET /orders/{orderId}
                removed the response property 'discountMinor' from the response with the '200' status
```

### 4.4 Versioning strategies

| Strategy | Example | Pros | Cons |
|---|---|---|---|
| URI path | `/v2/orders` | Trivially visible, cache-friendly, easy routing at the gateway | Violates "one resource, one URI"; forces client code changes |
| Media type | `Accept: application/vnd.example.order+json;version=2` | Purest REST, per-resource evolution | Harder to test by hand; proxies/CDNs must vary on `Accept` |
| Query parameter | `/orders?version=2` | Simple | Easy to forget; pollutes cache keys |
| Header | `X-API-Version: 2` | Clean URIs | Invisible in logs/browsers unless explicitly logged |
| **No version — additive only** | — | No fan-out of implementations | Requires strict discipline: only add optional fields, never remove or re-type |

Production guidance: version the *major* contract in the path for public APIs, and inside the major version allow only backward-compatible change (add optional fields, add enum values only if clients are documented to tolerate unknown values, never change a field's type or semantics). Internally, prefer no version plus consumer-driven contract tests.

### 4.5 REST vs the alternatives

| | REST/JSON over HTTP/1.1 | gRPC (HTTP/2 + protobuf) | GraphQL | Async messaging (AMQP/Kafka) |
|---|---|---|---|---|
| Contract | OpenAPI (optional) | `.proto` (mandatory, compiled) | SDL schema (mandatory) | Schema registry (Avro/Protobuf/JSON Schema) |
| Payload | Text, verbose, human-readable | Binary, compact | JSON | Binary or JSON |
| Typical latency overhead | Baseline | 30–60 % lower; multiplexed streams | Baseline + resolver fan-out | Decoupled — not comparable |
| Browser support | Native | Needs grpc-web + proxy | Native | Via WebSocket bridge |
| Streaming | SSE / WebSocket bolt-on | Native bidirectional | Subscriptions | Native |
| Caching | HTTP caching (ETag, Cache-Control, CDN) | None standard | Hard (single POST endpoint) | N/A |
| Over/under-fetching | Common | Common | Solved by design | N/A |
| Temporal coupling | Synchronous | Synchronous | Synchronous | **Removed** |
| Debuggability | `curl` | `grpcurl`, needs reflection | GraphiQL | Broker CLI + DLQ inspection |
| Best fit | Public APIs, CRUD, anything a browser calls | Internal east-west, high QPS, polyglot | Aggregation for heterogeneous clients (mobile/web) | Events, work queues, fan-out, buffering |
| Main hazard | Chatty N+1 across boundaries | Opaque on the wire; version skew in generated stubs | A single query can DoS the backend (needs depth/complexity limits) | At-least-once duplicates; ordering only per partition |

**Design rule of thumb:** synchronous request/response for queries a user is waiting on; asynchronous events for state propagation between services. If service A calls B calls C calls D synchronously to serve one request, your availability is the product of four services and your p99 is the sum of four p99s.

### 4.6 CORS — the same-origin policy and its controlled relaxation

Browsers enforce the **same-origin policy**: a document from origin `https://app.example.com` may not read a response from `https://api.example.com`. An origin is the triple *(scheme, host, port)* — `https://app.example.com` and `https://app.example.com:8443` are different origins, as are `http://` and `https://` variants.

**CORS (Cross-Origin Resource Sharing)** is the mechanism by which the *server* tells the browser to relax that restriction. Three points that are constantly misunderstood:

1. CORS is enforced **by the browser**, not by the server. `curl` ignores it entirely — a request that fails in Chrome and succeeds in `curl` is a CORS problem, always.
2. CORS is **not** a server-side security control. It does not protect the API; it protects the *user's* browser session from being read by a hostile page. Your API still needs authentication and authorisation.
3. A failed CORS check does not stop the request from reaching the server on a simple request — it stops the *response from being read*. Side effects may already have happened, which is why CSRF protection is still required.

**Simple vs preflighted requests.** A request is "simple" (no preflight) only if the method is `GET`, `HEAD` or `POST`, the headers are limited to the CORS-safelisted set, and `Content-Type` is one of `application/x-www-form-urlencoded`, `multipart/form-data` or `text/plain`. **`Content-Type: application/json` therefore always triggers a preflight** — which is why nearly every REST API must handle `OPTIONS`.

The preflight exchange, observed:

```
$ curl -i -X OPTIONS https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,authorization,idempotency-key'
HTTP/2 204
access-control-allow-origin: https://app.example.com
access-control-allow-methods: GET, POST, PUT, DELETE, PATCH, OPTIONS
access-control-allow-headers: content-type,authorization,idempotency-key
access-control-allow-credentials: true
access-control-max-age: 600
vary: Origin
date: Fri, 18 Sep 2026 09:22:41 GMT
```

Then the actual request:

```
$ curl -i -X POST https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer eyJhbGciOi...' \
    -H 'Idempotency-Key: 6f1c2a3e-9b4d-4f2a-8c11-77d0f5a1b2c3' \
    -d '{"customerId":"cus_7","lines":[{"sku":"SKU-1","quantity":2}]}'
HTTP/2 201
location: /v2/orders/ord_01J8X
access-control-allow-origin: https://app.example.com
access-control-expose-headers: Location, X-Request-Id
access-control-allow-credentials: true
vary: Origin
content-type: application/json
```

Header reference:

| Header | Direction | Meaning |
|---|---|---|
| `Origin` | Request | The requesting document's origin; set by the browser, not forgeable by page JS |
| `Access-Control-Request-Method` | Preflight | Method the real request will use |
| `Access-Control-Request-Headers` | Preflight | Non-safelisted headers the real request will send |
| `Access-Control-Allow-Origin` | Response | Allowed origin, or `*` |
| `Access-Control-Allow-Methods` | Preflight response | Permitted methods |
| `Access-Control-Allow-Headers` | Preflight response | Permitted request headers |
| `Access-Control-Allow-Credentials` | Response | `true` permits cookies/TLS client certs; **incompatible with `*`** |
| `Access-Control-Expose-Headers` | Response | Response headers JS may read (by default only the safelisted six) |
| `Access-Control-Max-Age` | Preflight response | Seconds the browser may cache the preflight |
| `Vary: Origin` | Response | **Mandatory** when the allowed origin is computed — otherwise a shared cache serves origin A's headers to origin B |

The four CORS bugs you will actually meet:

1. `Access-Control-Allow-Origin: *` together with `Access-Control-Allow-Credentials: true` — the browser rejects the combination outright. With credentials you must echo the exact origin (from an allowlist) and emit `Vary: Origin`.
2. Reflecting `Origin` without validating it — this allows any site to read authenticated responses. Always match against an explicit allowlist.
3. The `OPTIONS` route requires authentication — the browser sends no credentials on a preflight, so it gets 401 and the real request never happens. Preflight must be answered before the auth middleware.
4. A missing `Vary: Origin` behind a CDN — intermittent, origin-dependent failures that "only happen for some users".

---

## 5. Data storage, state and configuration

### 5.1 Stateless is a property of the process, not of the system

State does not disappear; it moves to a purpose-built backing service. The design target is that **any replica can serve any request**, and that killing a replica loses nothing but in-flight work.

| State category | Wrong home | Right home |
|---|---|---|
| User session | Process memory | Redis/Memcached, or a signed token held by the client |
| Uploaded files | Container filesystem | Object storage (S3-compatible) |
| Cache | Per-replica map (inconsistent across replicas) | Shared cache, or per-replica with a short TTL and accepted inconsistency |
| Scheduled jobs / leader | "The first pod" | Leader election via the platform (Lease object), or a queue |
| In-flight work | Local queue in memory | Durable broker with visibility timeout |
| Business data | Local SQLite in the container | Managed/operator-run database with backups |

### 5.2 Session handling: sticky sessions vs externalised state vs tokens

| Approach | How it works | Scale-in behaviour | Failure mode |
|---|---|---|---|
| **In-memory + sticky sessions** | LB pins a client to a replica by cookie or source IP hash | Users on the terminated replica lose their session | Uneven load; rolling updates log everyone out; blocks autoscaling |
| **External session store** | Session ID cookie; state in Redis with TTL | Seamless | Redis is now on the critical path — needs HA, and a latency budget |
| **Client-side token (JWT)** | Signed claims in the cookie/header; server verifies the signature | Seamless, no server state | **Revocation is hard**; token size grows; claims are stale until expiry |
| **Hybrid** | Short-lived (5–15 min) access token + server-side refresh token | Seamless | Best practical trade-off; revoke by invalidating the refresh token |

Sticky sessions in Kubernetes are `service.spec.sessionAffinity: ClientIP` (L4, coarse, breaks behind NAT) or an ingress cookie annotation (L7). Treat both as a migration crutch for legacy apps, not a design.

**JWT specifics that cause incidents:** validate `alg` against an allowlist (reject `none` and reject algorithm confusion between HMAC and RSA), validate `iss`, `aud`, `exp` and `nbf`, keep expiry short, and never put anything secret in the payload — a JWT is signed, not encrypted, and is trivially base64-decoded by anyone holding it.

### 5.3 Choosing a data store

| Store type | Model | Consistency | Scales by | Use it for | Do not use it for |
|---|---|---|---|---|---|
| Relational (PostgreSQL, MySQL) | Tables, joins, constraints | Strong, ACID | Vertical + read replicas; sharding is manual | Transactional business data, anything with invariants | Blobs; unbounded write throughput |
| Key-value (Redis, Memcached) | `key → value` | Typically last-write-wins | Horizontal (sharding) | Cache, sessions, rate limiters, locks | System of record (unless persistence is configured and understood) |
| Document (MongoDB, CouchDB) | JSON documents | Per-document atomic; tunable | Horizontal | Aggregates read as a whole, flexible schemas | Cross-document transactional invariants |
| Wide-column (Cassandra, ScyllaDB) | Partition + clustering keys | Tunable (quorum) | Horizontal, linear | Massive write throughput, time series | Ad-hoc queries; the query shape must be known first |
| Search (OpenSearch, Elasticsearch) | Inverted index | Near-real-time | Horizontal | Full-text, aggregations | System of record |
| Object storage (S3-compatible) | Bucket/key → blob | Read-after-write for new objects | Effectively unlimited | Files, backups, artefacts, static assets | Anything needing a query engine |
| Message broker (Kafka, RabbitMQ) | Log / queue | At-least-once | Partitions / queues | Decoupling, buffering, event streams | Random-access storage |
| Time series (Prometheus, VictoriaMetrics) | Labelled series | Eventually consistent | Sharding/federation | Metrics | Events needing exact retention/audit |

**CAP and PACELC in one paragraph.** Under a network **P**artition you must choose **C**onsistency or **A**vailability; partitions are not optional, so CAP is really a CP/AP choice. PACELC adds the rest of the time: **E**lse, choose **L**atency or **C**onsistency. A synchronously replicated database buys consistency with write latency; an asynchronous replica buys latency with a window of staleness and possible data loss on failover. Make that choice explicitly per data set — an order ledger and a "recently viewed" list do not need the same guarantee.

---

## 6. Designing software to run in containers

### 6.1 Container design rules

1. **One concern per container.** Not "one process" — a web server with a worker pool is fine — but one reason to be restarted, one lifecycle, one scaling dimension. Sidecars (proxy, log shipper) belong in the same pod, not the same container.
2. **The image is immutable and environment-agnostic.** Exactly one image is built per commit and promoted through environments. If you build `myapp:prod`, you have not tested what you deploy.
3. **Pin by digest in production.** Tags are mutable: `image: registry/orders@sha256:…` is reproducible; `orders:v2.3.0` is a promise someone can break.
4. **Small base, non-root, read-only rootfs.** Every binary in the image is attack surface and CVE-scan noise.
5. **PID 1 handles signals** (§3.2).
6. **No secrets in layers.** A `RUN` that curls with a token leaves the token in the layer forever, even if a later layer deletes the file. Use build secrets mounts.
7. **Expose health endpoints** that are cheap and honest (§6.3).

### 6.2 A complete, production-shaped multi-stage build

```dockerfile
# syntax=docker/dockerfile:1.7

########## Stage 1 — build ##########
FROM golang:1.23-bookworm AS build
WORKDIR /src

# Dependency layer: cached unless go.mod/go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
ARG VERSION=dev
ARG COMMIT=unknown
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/orders ./cmd/orders

########## Stage 2 — test (fails the build, not the pipeline afterwards) ##########
FROM build AS test
RUN CGO_ENABLED=0 go vet ./... && go test -count=1 ./...

########## Stage 3 — runtime ##########
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
# distroless/static:nonroot runs as UID/GID 65532 and ships CA certificates
# and /etc/passwd, but no shell, no package manager, no busybox.
COPY --from=build /out/orders /usr/local/bin/orders

USER 65532:65532
EXPOSE 8080
ENV GOMAXPROCS=0 \
    OTEL_SERVICE_NAME=orders

# Exec form: the binary is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["/usr/local/bin/orders"]
```

Build and inspect:

```
$ docker buildx build \
    --build-arg VERSION=2.3.0 \
    --build-arg COMMIT=$(git rev-parse --short HEAD) \
    --target runtime \
    --provenance=true --sbom=true \
    -t registry.example.com/orders:2.3.0 --push .
[+] Building 41.7s (18/18) FINISHED
 => [build 5/6] RUN --mount=type=cache ... go build                     28.4s
 => [test 1/1] RUN go vet ./... && go test -count=1 ./...                9.1s
 => exporting to image                                                   1.2s
 => => pushing manifest for registry.example.com/orders:2.3.0@sha256:9f2c...

$ docker image ls registry.example.com/orders:2.3.0
REPOSITORY                         TAG     IMAGE ID       CREATED          SIZE
registry.example.com/orders        2.3.0   3b1f8e0c7a55   12 seconds ago   14.8MB

$ docker run --rm registry.example.com/orders:2.3.0 --version
orders 2.3.0 (commit 8c41d0a, go1.23.4)
```

Verify the process really is PID 1 and really dies on `SIGTERM`:

```
$ docker run -d --name orders-t registry.example.com/orders:2.3.0
c81f2a44e19b
$ docker top orders-t
UID    PID    PPID   C   STIME   TTY   TIME       CMD
65532  41207  41185  0   09:31   ?     00:00:00   /usr/local/bin/orders
$ time docker stop orders-t
orders-t

real    0m0.412s
```

`real 0m0.4s` proves the handler ran. A `real 0m10.0s` here means `SIGTERM` was ignored and the runtime fell back to `SIGKILL` — the single most common containerisation defect.

### 6.3 Health endpoints: three distinct questions

| Probe | Question | Failure action | Must NOT check |
|---|---|---|---|
| **Startup** | Has initialisation finished? | Keeps liveness/readiness suspended until it passes | — |
| **Liveness** | Is this process wedged beyond recovery? | **Restart the container** | Dependencies. A liveness probe that checks the database restarts every pod when the DB blips — a self-inflicted outage |
| **Readiness** | Can this replica serve traffic *right now*? | Remove from the Service endpoints (no restart) | Anything slow or expensive |

`/livez` should be a constant-time answer from the HTTP handler — if it responds, the event loop is alive. `/readyz` may check the connection pool and the caches it cannot serve without, and must flip to failing on `SIGTERM`. Both must be excluded from authentication and from access logs, and neither should be exposed through the ingress.

### 6.4 Complete Kubernetes manifest set

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders
  namespace: shop
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: orders-config
  namespace: shop
data:
  LOG_LEVEL: info
  LOG_FORMAT: json
  HTTP_PORT: "8080"
  PAYMENTS_BASE_URL: "http://payments.shop.svc.cluster.local:8080"
  PAYMENTS_TIMEOUT: 2s
  PAYMENTS_RETRIES: "2"
  DB_POOL_MAX_CONNS: "20"
  DB_POOL_MAX_CONN_LIFETIME: 30m
  CORS_ALLOWED_ORIGINS: "https://app.example.com,https://admin.example.com"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
---
apiVersion: v1
kind: Secret
metadata:
  name: orders-secrets
  namespace: shop
type: Opaque
stringData:
  DATABASE_URL: "postgres://orders_app:S3cr3t-Pa55@postgres-rw.shop.svc.cluster.local:5432/orders?sslmode=verify-full"
  JWT_PUBLIC_KEY_PEM: |
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0vx7agoebGcQSuuPiLJX
    ZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tS
    oc_TRUNCATED_FOR_BREVITY_REPLACE_WITH_REAL_KEY
    -----END PUBLIC KEY-----
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
  namespace: shop
  labels:
    app.kubernetes.io/name: orders
    app.kubernetes.io/version: 2.3.0
    app.kubernetes.io/part-of: shop
spec:
  replicas: 4
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders
        app.kubernetes.io/version: 2.3.0
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: orders
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders
      containers:
        - name: orders
          image: "registry.example.com/orders@sha256:9f2c4d1b8ae0a7c3f5d69b21c0e4a7f8d3b6c19e25aa70fd1c8b4e39a6d2f701"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          envFrom:
            - configMapRef:
                name: orders-config
            - secretRef:
                name: orders-secrets
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: NODE_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['topology.kubernetes.io/zone']
            - name: GOMEMLIMIT
              valueFrom:
                resourceFieldRef:
                  resource: limits.memory
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /startupz
              port: http
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command:
                  - /usr/local/bin/orders
                  - drain
                  - --wait=10s
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: orders
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: orders
  ports:
    - name: http
      port: 8080
      targetPort: http
    - name: metrics
      port: 9090
      targetPort: metrics
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: orders
  namespace: shop
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: orders
  namespace: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: orders
  minReplicas: 4
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
    - type: Pods
      pods:
        metric:
          name: http_requests_inflight
        target:
          type: AverageValue
          averageValue: "25"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 8
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: orders
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: orders
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: payments
      ports:
        - protocol: TCP
          port: 8080
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: postgres
      ports:
        - protocol: TCP
          port: 5432
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: orders
  namespace: shop
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.example.com"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-headers: "Content-Type, Authorization, Idempotency-Key, traceparent"
    nginx.ingress.kubernetes.io/cors-expose-headers: "Location, X-Request-Id"
    nginx.ingress.kubernetes.io/cors-allow-credentials: "true"
    nginx.ingress.kubernetes.io/cors-max-age: "600"
    nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.example.com
      secretName: api-example-com-tls
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /v2/orders
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  name: http
```

Notes an architect should be able to defend in a review:

- **`maxUnavailable: 0`** — during a rolling update capacity never drops below `replicas`; the surge pod must be schedulable, so leave headroom.
- **No CPU limit, memory limit set** — CPU limits cause CFS throttling and p99 latency cliffs; memory is incompressible, so it needs a limit to protect the node. `GOMEMLIMIT` from the limit keeps the Go GC under the cgroup ceiling instead of getting OOMKilled.
- **`terminationGracePeriodSeconds: 45` > preStop drain (10 s) + shutdown timeout (25 s)** — if the grace period is shorter than the drain, the kernel kills the process mid-request.
- **`topologySpreadConstraints` on zones with `DoNotSchedule`** — this is what makes "multi-AZ" real rather than aspirational; without it the scheduler may place all four replicas in one zone.
- **`automountServiceAccountToken: false`** — an application that does not call the Kubernetes API has no business holding a token that can.
- **Default-deny egress** — the NetworkPolicy above is a full allowlist; note that DNS must be explicitly permitted or every name resolution fails, which presents as random connection errors, not as a policy error.

---

## 7. Cloud deployment models, elasticity and immutability

### 7.1 Responsibility split

| Model | You manage | Provider manages | Unit of scaling | Typical lock-in |
|---|---|---|---|---|
| **On-premises** | Everything | Nothing | Rack | None |
| **IaaS** | OS, runtime, app, data | Virtualisation, hardware, network fabric | VM | Low (images, networking) |
| **CaaS** (managed Kubernetes) | Container image, manifests, app, data | Control plane, node lifecycle | Pod | Medium (portable via Kubernetes API) |
| **PaaS** | App code + config | OS, runtime, scaling, patching | App instance | High (buildpacks, proprietary services) |
| **FaaS** | Function code | Everything else | Invocation | Very high (event model, runtime limits) |
| **SaaS** | Data and configuration | The entire application | Seat/usage | Very high (data export is the only exit) |

The exam framing: IaaS ⇒ you still patch the OS; PaaS ⇒ you push code, not machines; SaaS ⇒ you consume, you do not deploy.

### 7.2 Regions, availability zones, and what they actually protect against

- **Availability Zone**: an independent failure domain within a region — separate power, cooling and network, but low-latency (typically <2 ms) interconnect. Protects against a datacentre-level failure. Cheap to use: synchronous replication across AZs is viable.
- **Region**: a geographically distinct location. Protects against a regional outage and satisfies data-residency requirements. Cross-region replication is asynchronous in practice (speed of light), so it comes with an RPO > 0.

| Failure to survive | Minimum topology | Cost | Data consistency |
|---|---|---|---|
| Single node/VM | ≥2 replicas, anti-affinity | Negligible | Unaffected |
| Rack / power domain | Spread over hosts | Negligible | Unaffected |
| Availability zone | ≥3 replicas over ≥3 AZs; quorum-based datastore | Cross-AZ traffic charges | Strong, synchronous |
| Region | Active/passive or active/active multi-region | High (double footprint, egress) | Eventual; define RPO/RTO explicitly |

**Elasticity vs scalability** — scalability is the ability to handle more load by adding resources; elasticity is doing that *automatically and bidirectionally* in response to demand. Elasticity requires statelessness (§5.1), fast startup (factor IX), and a metric that leads demand rather than lagging it. CPU utilisation lags; queue depth and in-flight requests lead — which is why the HPA above uses both.

### 7.3 Immutable infrastructure

| | Mutable ("pet") servers | Immutable ("cattle") servers |
|---|---|---|
| Change mechanism | SSH, config management run in place | Build a new image, replace the instance |
| Drift | Accumulates silently; snowflake servers | Structurally impossible |
| Rollback | Re-run an older config and hope | Redeploy the previous image/digest |
| Debugging a live incident | Log in and poke | Reproduce from the same image locally |
| Provisioning time | Minutes (config run) | Minutes (image bake) + seconds (boot) |
| Compliance evidence | Inventory scans | The image digest *is* the evidence |
| Weak point | "It worked last time we ran Ansible" | Requires a real build pipeline and artefact store |

Containers make immutability the default. On VMs, the equivalent is image baking (Packer) plus a replace-not-patch deployment. In both cases the discipline is the same: **no interactive changes to running infrastructure** — if you `kubectl exec` and edit a file, the next reschedule silently reverts it, and you have invented a bug that reproduces only sometimes.

Infrastructure as code, declared and reviewable:

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  backend "s3" {
    bucket         = "example-tfstate-prod"
    key            = "shop/orders/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

variable "image_digest" {
  description = "Immutable image reference promoted from staging."
  type        = string
}

resource "aws_db_instance" "orders" {
  identifier                   = "orders-prod"
  engine                       = "postgres"
  engine_version               = "16.4"
  instance_class               = "db.r6g.xlarge"
  allocated_storage            = 200
  storage_encrypted            = true
  multi_az                     = true # synchronous standby in a second AZ
  backup_retention_period      = 14
  performance_insights_enabled = true
  deletion_protection          = true
  apply_immediately            = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Service     = "orders"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

```
$ terraform plan -out=orders.tfplan
Terraform used the selected providers to generate the following execution plan.
Resource actions are indicated with the following symbols:
  ~ update in-place

Terraform will perform the following actions:

  # aws_db_instance.orders will be updated in-place
  ~ resource "aws_db_instance" "orders" {
        id                      = "orders-prod"
      ~ backup_retention_period = 7 -> 14
        # (48 unchanged attributes hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

### 7.4 Deployment strategies

| Strategy | Mechanism | Downtime | Extra capacity | Rollback speed | Detects bad releases by |
|---|---|---|---|---|---|
| **Recreate** | Stop all, start new | Yes | None | Redeploy (slow) | Users complaining |
| **Rolling** | Replace N at a time | No | `maxSurge` | Roll back = another rolling update | Probes + post-hoc metrics |
| **Blue-green** | Two full environments, switch the router | No | **100 %** | Instant (flip back) | Smoke tests on green before the flip |
| **Canary** | Small % of live traffic to the new version, ramp up | No | Small | Fast (shift traffic back) | Real production metrics on real traffic |
| **A/B testing** | Route by user attribute (header/cookie) | No | Small | Fast | Business metrics, not just errors |
| **Shadow / mirror** | Duplicate traffic to the new version, discard responses | No | Full duplicate of the new version | N/A (never serves users) | Comparison, with zero user risk |

Blue-green and canary both require **backward-compatible data**: during the transition, two code versions read and write the same database. This is the expand-contract (parallel change) pattern:

1. **Expand** — add the new nullable column/table; deploy code that writes both old and new and reads old.
2. **Migrate** — backfill the new column; deploy code that writes both and reads new.
3. **Contract** — deploy code that writes and reads only new; drop the old column in a later release.

Never combine a schema change and a code change that depends on it in the same deployment. That is what makes rollback impossible, and rollback is the only reliable incident mitigation.

A canary with automated analysis, so the rollback decision is not a human staring at a dashboard at 03:00:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: orders
  namespace: shop
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders
    spec:
      containers:
        - name: orders
          image: "registry.example.com/orders@sha256:9f2c4d1b8ae0a7c3f5d69b21c0e4a7f8d3b6c19e25aa70fd1c8b4e39a6d2f701"
          ports:
            - name: http
              containerPort: 8080
  strategy:
    canary:
      canaryService: orders-canary
      stableService: orders-stable
      trafficRouting:
        nginx:
          stableIngress: orders
      analysis:
        templates:
          - templateName: orders-success-rate
        startingStep: 2
        args:
          - name: service-name
            value: orders-canary
      steps:
        - setWeight: 5
        - pause:
            duration: 5m
        - setWeight: 20
        - pause:
            duration: 10m
        - setWeight: 50
        - pause:
            duration: 10m
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: orders-success-rate
  namespace: shop
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 60s
      count: 20
      successCondition: "result[0] >= 0.995"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            sum(rate(http_requests_total{service="{{args.service-name}}",code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{service="{{args.service-name}}"}[2m]))
    - name: latency-p99
      interval: 60s
      count: 20
      successCondition: "result[0] <= 0.750"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            histogram_quantile(
              0.99,
              sum by (le) (
                rate(http_request_duration_seconds_bucket{service="{{args.service-name}}"}[2m])
              )
            )
```

Observed during a rollout:

```
$ kubectl argo rollouts get rollout orders -n shop --watch
Name:            orders
Namespace:       shop
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          3/7
  SetWeight:     20
  ActualWeight:  20
Images:          registry.example.com/orders@sha256:9f2c... (canary)
                 registry.example.com/orders@sha256:1a7e... (stable)
Replicas:
  Desired:       10
  Current:       10
  Updated:       2
  Ready:         10
  Available:     10

NAME                                 KIND         STATUS     AGE   INFO
⟳ orders                             Rollout      ॥ Paused   6d
├──# revision:12
│  └──⧉ orders-7c9f6d4bb8            ReplicaSet   ✔ Healthy  4m    canary
│     ├──□ orders-7c9f6d4bb8-2xk9d   Pod          ✔ Running  4m    ready:1/1
│     └──□ orders-7c9f6d4bb8-9wq4p   Pod          ✔ Running  4m    ready:1/1
│  └──α orders-7c9f6d4bb8-2          AnalysisRun  ✔ Success  4m    ✔ 4
└──# revision:11
   └──⧉ orders-6b4d7c9f55            ReplicaSet   ✔ Healthy  6d    stable
```

And a failing canary aborting itself:

```
$ kubectl argo rollouts status orders -n shop
Error: The rollout is in a degraded state with message: RolloutAborted: Rollout aborted update to revision 13

$ kubectl describe analysisrun orders-8f6c2a1dd9-4 -n shop | tail -12
Status:
  Phase:  Failed
  Metric Results:
    Name:   success-rate
    Phase:  Failed
    Measurements:
      Value:  0.9713   Phase: Failed
      Value:  0.9688   Phase: Failed
      Value:  0.9702   Phase: Failed
Events:
  Type     Reason         Age   From                 Message
  Warning  MetricFailed   90s   rollouts-controller  metric 'success-rate' failure limit exceeded (2)
```

---

## 8. Migrating and integrating a monolithic legacy system

### 8.1 Risk register

| Risk | Why it bites | Control |
|---|---|---|
| Big-bang rewrite | Two systems to maintain, feature freeze for 18 months, no incremental value | Strangler fig — incremental, always shippable |
| Shared database persists | Extracted service still writes the monolith's tables ⇒ distributed monolith | One writer per table; read via API or replicated events |
| Lost transactional guarantees | An operation that was one `COMMIT` now spans two services | Saga + compensation, or keep it inside one boundary |
| Legacy domain model leaks | New services inherit 15 years of accidental semantics | Anti-corruption layer translating at the boundary |
| Undocumented behaviour | The monolith's bugs are load-bearing for downstream consumers | Shadow traffic / parallel run and diff the outputs |
| No tests | Refactoring is unverifiable | Characterisation tests: capture current behaviour before changing it |
| Latency regression | An in-process call becomes a network call in a hot loop | Measure first; coarsen the API; batch |
| Stateful assumptions | In-memory session, local file writes, singleton schedulers | Externalise state before containerising (§5) |
| Big-bang cutover risk | No rollback path | Dual-run with a feature flag; route a % of traffic; keep the old path warm |

### 8.2 The strangler fig, concretely

Place a facade (ingress, API gateway, reverse proxy) in front of the monolith on day one. It initially routes 100 % to the monolith. Each extracted capability becomes a new route.

```
            ┌───────────────┐
  client ──▶│  API gateway  │
            └───┬───────┬───┘
   /v2/orders   │       │   everything else
                ▼       ▼
        ┌─────────────┐  ┌────────────────────┐
        │   orders    │  │  legacy monolith   │
        │  (new svc)  │  │                    │
        └──────┬──────┘  └─────────┬──────────┘
               │                   │
               ▼                   ▼
        ┌─────────────┐  ┌────────────────────┐
        │ orders DB   │  │   legacy schema    │
        └─────────────┘  └────────────────────┘
                ▲                  │
                └── CDC / events ◀──┘  (one-way, during transition)
```

Ingress-level routing making the extraction invisible to clients:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-facade
  namespace: shop
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  ingressClassName: nginx
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /v2/orders
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  name: http
          - path: /
            pathType: Prefix
            backend:
              service:
                name: legacy-monolith
                port:
                  number: 8080
```

**Branch by abstraction** is the in-code analogue when the seam is not an HTTP route: introduce an interface in the monolith, implement it twice (legacy path and remote-call path), select at runtime by feature flag, ramp, then delete the legacy implementation. It keeps trunk always releasable, which is the prerequisite for continuous delivery.

---

## 9. Application security risks and mitigations

### 9.1 OWASP Top 10 (2021 edition) in a cloud-native context

> The OWASP Top 10 is periodically revised; the 2021 edition is the one most commonly referenced by exam objectives and by tooling. Check `https://owasp.org/www-project-top-ten/` for the currently published edition before quoting category numbers in an audit.

| ID | Category | Cloud-native manifestation | Mitigation you can implement |
|---|---|---|---|
| A01 | Broken Access Control | IDOR (`GET /orders/{id}` without ownership check); service-to-service calls trusted because "they're inside the cluster" | Authorise on every request against the subject, not the network location; deny by default; NetworkPolicy + mTLS as defence in depth, never as the control |
| A02 | Cryptographic Failures | TLS terminated at the ingress and plaintext inside the mesh; secrets in Git; unencrypted backups | TLS everywhere (mTLS in-mesh), encryption at rest, HSTS, no self-rolled crypto |
| A03 | Injection | SQL/NoSQL/command/LDAP injection; template injection | Parameterised queries only; never build SQL by concatenation; validate/allowlist input; avoid `shell=True`-style execution |
| A04 | Insecure Design | No threat model; no rate limiting; unbounded queries | Threat-model each new boundary; design abuse cases; quotas and limits as requirements |
| A05 | Security Misconfiguration | `privileged: true`, root containers, debug endpoints exposed, default credentials, permissive CORS | Pod Security Admission `restricted`; admission policy in CI; config scanning (`kubescape`, `trivy config`) |
| A06 | Vulnerable and Outdated Components | A base image with 180 CVEs; a transitive dependency with a known RCE | SBOM per build, scanning in CI *and* continuously in the registry, automated dependency updates |
| A07 | Identification and Authentication Failures | Long-lived tokens, no MFA, `alg: none` accepted, session fixation | Short-lived tokens, strict JWT validation, rotate on privilege change, MFA for admin paths |
| A08 | Software and Data Integrity Failures | Unsigned images, CI pulling `latest` from an unpinned registry, insecure deserialisation | Sign artefacts (Sigstore/cosign), verify signatures in an admission controller, pin by digest, provenance attestations (SLSA) |
| A09 | Security Logging and Monitoring Failures | Auth failures not logged; no alert on a spike of 401/403; logs without correlation IDs | Log security events structurally; alert on anomalies; retain per policy; never log secrets or tokens |
| A10 | Server-Side Request Forgery | A service fetching a user-supplied URL reaches the cloud metadata endpoint and steals instance credentials | Allowlist outbound destinations; block link-local `169.254.169.254` by NetworkPolicy; enforce IMDSv2; validate the URL after DNS resolution |

### 9.2 Secrets: the layered answer

| Layer | Practice | Anti-pattern it replaces |
|---|---|---|
| Source | Secrets never in Git; pre-commit scanning (`gitleaks`) | `config/prod.yaml` with a password |
| Build | BuildKit secret mounts (`--mount=type=secret`) | `ARG TOKEN` — visible in image history forever |
| Storage | External manager (Vault, cloud KMS-backed store), or at minimum etcd encryption at rest | Base64 in a manifest — base64 is encoding, not encryption |
| Delivery | Mounted files, short TTL, auto-rotated (CSI Secrets Store / External Secrets Operator) | A `Secret` created by hand two years ago |
| Runtime | Read at startup or on file change; never log; redact in error handlers | Printing the config struct on boot |
| Rotation | Automated, tested, no redeploy required | "We rotate on offboarding" |

```
$ gitleaks detect --source . --redact --no-banner
Finding:     DATABASE_URL="postgres://orders:REDACTED@db.internal:5432/orders"
Secret:      REDACTED
RuleID:      generic-api-key
File:        deploy/overlays/prod/env.properties
Line:        12
Commit:      8c41d0aa9f1e2b3c4d5e6f708192a3b4c5d6e7f8

1 leak found
```

### 9.3 Supply chain: SBOM, scan, sign, verify

```
$ syft registry.example.com/orders:2.3.0 -o spdx-json > sbom.spdx.json
 ✔ Parsed image      sha256:9f2c4d1b8ae0
 ✔ Cataloged contents
   ├── ✔ Packages           [37 packages]
   └── ✔ Executables        [1 executables]

$ grype sbom:sbom.spdx.json --fail-on high
NAME                  INSTALLED  FIXED-IN  TYPE    VULNERABILITY   SEVERITY
golang.org/x/net      v0.28.0    v0.33.0   go-mod  GHSA-w32m-9786  Medium
stdlib                go1.23.2   go1.23.5  go-mod  CVE-2024-45341  Medium

2 vulnerabilities found (0 critical, 0 high, 2 medium, 0 low)

$ cosign sign --yes registry.example.com/orders@sha256:9f2c4d1b8ae0...
tlog entry created with index: 148820417

$ cosign verify \
    --certificate-identity-regexp 'https://github.com/example/orders/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/orders@sha256:9f2c4d1b8ae0... | jq '.[0].optional.Subject'
Verification for registry.example.com/orders@sha256:9f2c4d1b8ae0... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
"https://github.com/example/orders/.github/workflows/release.yml@refs/tags/v2.3.0"
```

---

## 10. Build automation and the CI/CD pipeline

Build automation tools (Maven, Gradle, npm/pnpm, Make, Bazel, Cargo, Go modules) exist to make the build **declarative, reproducible and dependency-aware**. Their operational contribution:

| Property | Why it matters in production |
|---|---|
| Declared dependencies with a lockfile | The build is reproducible six months later and on a different machine (factor II) |
| Deterministic dependency resolution | `npm ci` from `package-lock.json`, not `npm install` — otherwise CI and prod differ |
| A dependency graph | Incremental builds; only what changed is rebuilt and retested |
| Standard lifecycle phases | `compile → test → package → verify` is the same verb in every repo |
| Artefact publication with coordinates | An immutable, addressable artefact (GAV, semver + digest) is what gets promoted |

A pipeline that enforces the design rules above, end to end:

```yaml
name: release
on:
  push:
    tags:
      - "v*"

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Secret scan
        run: |
          docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
            detect --source /repo --redact --no-banner

      - name: Contract lint and breaking-change gate
        run: |
          npx @redocly/cli@latest lint openapi.yaml
          docker run --rm -v "$PWD:/w" -w /w tufin/oasdiff:latest \
            breaking "https://api.example.com/v2/openapi.yaml" openapi.yaml

      - name: Build, test and push
        id: build
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          IMAGE="registry.example.com/orders"
          docker buildx build \
            --build-arg "VERSION=${VERSION}" \
            --build-arg "COMMIT=${GITHUB_SHA::7}" \
            --target runtime \
            --provenance=true --sbom=true \
            --tag "${IMAGE}:${VERSION}" \
            --push .
          DIGEST=$(docker buildx imagetools inspect "${IMAGE}:${VERSION}" \
            --format '{{ "{{" }}.Manifest.Digest{{ "}}" }}')
          echo "ref=${IMAGE}@${DIGEST}" >> "$GITHUB_OUTPUT"

      - name: Vulnerability gate
        run: |
          docker run --rm aquasec/trivy:latest image \
            --exit-code 1 --severity CRITICAL,HIGH --ignore-unfixed \
            "${{ steps.build.outputs.ref }}"

      - name: Sign
        run: cosign sign --yes "${{ steps.build.outputs.ref }}"

      - name: Promote by digest
        run: |
          yq -i '.spec.template.spec.containers[0].image = strenv(REF)' \
            deploy/overlays/prod/deployment.yaml
        env:
          REF: ${{ steps.build.outputs.ref }}
```

The design principles encoded here: build once and promote the **digest**; gate on contract compatibility before anything reaches an environment; fail the build on secrets and on fixable high-severity CVEs; and sign the artefact so the cluster can refuse anything unsigned.

---

## 11. Verification and failure diagnosis

### 11.1 Pre-deployment verification ladder

| Question | Command | Cost |
|---|---|---|
| Is the YAML valid and schema-correct? | `kubeconform -strict -summary -kubernetes-version 1.31.0 deploy/` | Free |
| Does it violate security policy? | `trivy config deploy/` · `kubescape scan framework nsa deploy/` | Free |
| Does the container run as non-root with a read-only root FS? | `docker run --rm --read-only <img> id` | Free |
| Does PID 1 handle SIGTERM? | `time docker stop <container>` (expect < 1 s) | Free |
| Is the API contract backward-compatible? | `oasdiff breaking <old> <new>` | Free |
| Do the probes answer correctly? | `curl -sf localhost:8080/readyz` | Free |
| Does the app start with only its declared config? | `docker run --env-file env.prod.example <img>` | Free |
| Does it survive a dependency being down? | Chaos: scale the dependency to 0, watch error rate and fallback | Cheap |

```
$ kubeconform -strict -summary -kubernetes-version 1.31.0 deploy/base/
Summary: 8 resources found parsing 8 files - Valid: 8, Invalid: 0, Errors: 0, Skipped: 0

$ trivy config --severity HIGH,CRITICAL deploy/base/
deploy/base/deployment.yaml (kubernetes)
Tests: 128 (SUCCESSES: 127, FAILURES: 1)
Failures: 1 (HIGH: 1, CRITICAL: 0)

HIGH: Container 'orders' of Deployment 'orders' should set 'resources.limits.cpu'
════════════════════════════════════════════════════════════════════════════════
Enforcing a CPU limit prevents DoS by a runaway container.
See https://avd.aquasec.com/misconfig/ksv011
```

*(That specific finding is one to override deliberately — see §6.4 on CFS throttling. Document the exception rather than silencing the scanner globally.)*

### 11.2 Failure catalogue

#### A. `CrashLoopBackOff` immediately after deploy

```
$ kubectl get pods -n shop -l app.kubernetes.io/name=orders
NAME                      READY   STATUS             RESTARTS      AGE
orders-7c9f6d4bb8-2xk9d   0/1     CrashLoopBackOff   4 (38s ago)   2m14s

$ kubectl logs -n shop orders-7c9f6d4bb8-2xk9d --previous
{"ts":"2026-09-18T09:41:02.117Z","level":"fatal","event":"config_invalid","error":"required environment variable DATABASE_URL is not set"}

$ kubectl get deploy orders -n shop -o jsonpath='{.spec.template.spec.containers[0].envFrom}' | jq .
[
  {
    "configMapRef": {
      "name": "orders-config"
    }
  }
]
```

Root cause: the `secretRef` entry was dropped in a merge. **Diagnostic value of the design:** the app fails fast and loudly on missing configuration at boot rather than at the first request — validate configuration in `main()`, before binding the port.

#### B. Rolling update produces 502s

```
$ kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=5
10.244.2.9 - - [18/Sep/2026:09:52:11 +0000] "POST /v2/orders HTTP/2.0" 502 150 "-" 0.002 [shop-orders-http] 10.244.3.41:8080 - - 502

$ kubectl get events -n shop --sort-by=.lastTimestamp | tail -5
2m    Normal   Killing   pod/orders-6b4d7c9f55-kk29x   Stopping container orders
2m    Normal   Started   pod/orders-7c9f6d4bb8-2xk9d   Started container orders

$ kubectl get deploy orders -n shop -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
30
$ kubectl exec -n shop orders-7c9f6d4bb8-2xk9d -- sh -c 'echo $SHUTDOWN_TIMEOUT'
60s
```

Root cause: the application's own shutdown timeout (60 s) exceeds `terminationGracePeriodSeconds` (30 s), so the kubelet `SIGKILL`s mid-drain; and there is no `preStop` delay, so the listener closes before the endpoint is withdrawn from every data plane. Fix both: grace period > preStop + shutdown timeout, and add the preStop drain (§6.4).

#### C. "It works in `curl` but not in the browser"

```
$ curl -s -o /dev/null -w '%{http_code}\n' https://api.example.com/v2/orders
200

$ curl -i -X OPTIONS https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type' | head -8
HTTP/2 401
www-authenticate: Bearer realm="api"
content-type: application/problem+json
```

Root cause: authentication middleware runs before CORS handling, so the preflight — which carries no credentials by design — is rejected with 401 and the browser never issues the real request. The `OPTIONS` handler must be registered ahead of the auth middleware. Second variant of the same class:

```
$ curl -sI https://api.example.com/v2/orders -H 'Origin: https://app.example.com' \
  | grep -i -E 'access-control|vary'
access-control-allow-origin: *
access-control-allow-credentials: true
```

Root cause: `*` with credentials is rejected outright by every browser. Echo the validated origin and add `Vary: Origin`.

#### D. Session loss after scale-in

```
$ kubectl get hpa orders -n shop
NAME     REFERENCE           TARGETS            MINPODS   MAXPODS   REPLICAS   AGE
orders   Deployment/orders   31%/65%, 4/25      4         40        4          19d

$ kubectl logs -n shop -l app.kubernetes.io/name=orders --tail=200 \
  | jq -r 'select(.event=="session_not_found") | .session_id' | wc -l
1184

$ kubectl exec -n shop orders-7c9f6d4bb8-2xk9d -- sh -c 'echo $SESSION_STORE'
memory
```

Root cause: violation of factor VI — session state in process memory. The HPA scaled in from 12 to 4 and evicted eight replicas' worth of sessions. Fix: externalise to a shared store, or move to signed short-lived tokens (§5.2). Sticky sessions would mask the symptom and permanently cripple elasticity.

#### E. `OOMKilled` under load

```
$ kubectl get pod orders-7c9f6d4bb8-9wq4p -n shop -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq .
{
  "exitCode": 137,
  "finishedAt": "2026-09-18T10:04:51Z",
  "reason": "OOMKilled",
  "startedAt": "2026-09-18T09:58:12Z"
}

$ kubectl top pod -n shop -l app.kubernetes.io/name=orders
NAME                      CPU(cores)   MEMORY(bytes)
orders-7c9f6d4bb8-2xk9d   243m         498Mi
orders-7c9f6d4bb8-9wq4p   251m         511Mi
```

Exit code 137 = 128 + 9 (`SIGKILL`), reason `OOMKilled`: the cgroup memory limit was hit. Distinguish two root causes before raising the limit — a genuine leak (memory grows monotonically across hours regardless of load) versus an undersized limit (memory tracks request rate and plateaus). For a runtime with its own GC, also verify the heap ceiling is derived from the cgroup limit (`GOMEMLIMIT`, `-XX:MaxRAMPercentage`); otherwise the collector never feels pressure and the kernel kills the process first.

#### F. Intermittent `connection refused` to a sibling service

```
$ kubectl exec -n shop deploy/orders -- nslookup payments.shop.svc.cluster.local
;; connection timed out; no servers could be reached

$ kubectl get networkpolicy orders -n shop -o jsonpath='{.spec.egress[*].ports[*].port}'
8080 5432
```

Root cause: a default-deny egress policy without an explicit allowance for DNS (UDP/TCP 53 to `kube-dns`). The symptom is not "policy denied" — it is DNS resolution timing out, which surfaces as connection errors with multi-second latency. Every default-deny egress policy needs the DNS rule shown in §6.4.

#### G. Thundering retries amplify a partial outage

```
$ kubectl logs -n shop -l app.kubernetes.io/name=payments --tail=3
{"level":"warn","event":"pool_exhausted","waiters":412,"max_conns":20}

$ curl -s "http://prometheus.monitoring.svc:9090/api/v1/query" \
    --data-urlencode 'query=sum(rate(http_client_requests_total{service="orders",upstream="payments"}[1m]))' \
  | jq -r '.data.result[0].value[1]'
3184.6
```

Root cause: retry amplification. Three retries with no jitter and no budget turned a 1 000 rps upstream blip into 3 000+ rps. Controls, in order of effectiveness: a **retry budget** (cap retries at ~10 % of base traffic), **exponential backoff with full jitter**, a **circuit breaker** that fails fast while the upstream is unhealthy, and **never retry non-idempotent operations without an idempotency key**.

### 11.3 A twelve-factor audit you can run on any service

```
$ kubectl get deploy orders -n shop -o yaml > /tmp/d.yaml

# III  — config from the environment, not baked in
$ yq '.spec.template.spec.containers[0].envFrom' /tmp/d.yaml
# VI   — no persistent volumes, no local state
$ yq '.spec.template.spec.volumes' /tmp/d.yaml
# VII  — port binding
$ yq '.spec.template.spec.containers[0].ports' /tmp/d.yaml
# IX   — disposability: grace period and preStop present
$ yq '.spec.template.spec | {"grace": .terminationGracePeriodSeconds, "preStop": .containers[0].lifecycle.preStop}' /tmp/d.yaml
# V    — immutable release: image pinned by digest
$ yq '.spec.template.spec.containers[0].image' /tmp/d.yaml | grep -q '@sha256:' \
    && echo "pinned by digest" || echo "MUTABLE TAG — not a reproducible release"
# XI   — logs go to stdout only
$ kubectl exec -n shop deploy/orders -- ls -l /proc/1/fd/1 /proc/1/fd/2
```

```
pinned by digest
l-wx------ 1 65532 65532 64 Sep 18 10:11 /proc/1/fd/1 -> pipe:[418822]
l-wx------ 1 65532 65532 64 Sep 18 10:11 /proc/1/fd/2 -> pipe:[418823]
```

---

## 12. Exam-focused summary

- **Loose coupling** is the goal; microservices are one means. A service that shares a database table with another service is not loosely coupled.
- **SOA** puts orchestration in the bus; **microservices** put it in the endpoints and keep the pipes dumb.
- **REST** constraints that matter: statelessness, uniform interface, cacheability. GET/PUT/DELETE are idempotent; **POST is not**.
- **JSON**: UTF-8, no comments, RFC 3339 dates, money in integer minor units.
- **CORS** is enforced by the browser and relaxes the same-origin policy; `Content-Type: application/json` always triggers a preflight `OPTIONS`; `Allow-Origin: *` is incompatible with `Allow-Credentials: true`; always send `Vary: Origin`.
- **Twelve-factor**: config in the environment, processes stateless, logs to stdout, fast startup and graceful shutdown, strict separation of build/release/run.
- **Containers**: one concern, non-root, read-only rootfs, PID 1 handles `SIGTERM`, exec-form `CMD`, pinned by digest, no secrets in layers.
- **Probes**: liveness restarts and must not test dependencies; readiness gates traffic and must fail on shutdown; startup covers slow initialisation.
- **State** lives in backing services (factor IV), attached by URL; sticky sessions are a legacy crutch that blocks elasticity.
- **IaaS/PaaS/SaaS**: who patches the OS is the distinguishing question. **AZ** protects against a datacentre; **region** against a geography.
- **Immutable servers**: replace, never patch. Rollback is redeploying the previous digest.
- **Blue-green** needs double capacity and gives an instant flip; **canary** ramps real traffic and detects problems with production signals. Both need backward-compatible schemas (expand–contract).
- **Legacy migration**: strangler fig behind a facade, anti-corruption layer at the boundary, characterisation tests first, never a big-bang rewrite.
- **Security**: OWASP Top 10 as the risk taxonomy; secrets never in Git or in image layers; sign and verify artefacts; SSRF reaches the metadata endpoint unless you block it.

---

## 13. References

**Official exam objectives**
- LPI — Exam 701 Objectives (DevOps Tools Engineer, 701-100): https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI — DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Architecture and methodology**
- The Twelve-Factor App: https://12factor.net/
- Fielding, R. T., *Architectural Styles and the Design of Network-based Software Architectures*, Ch. 5 (REST): https://ics.uci.edu/~fielding/pubs/dissertation/rest_arch_style.htm
- CNCF Cloud Native Definition v1.1: https://github.com/cncf/toc/blob/main/DEFINITION.md
- CNCF Cloud Native Landscape: https://landscape.cncf.io/
- NIST SP 800-145, *The NIST Definition of Cloud Computing* (IaaS/PaaS/SaaS): https://csrc.nist.gov/pubs/sp/800/145/final
- NIST SP 800-190, *Application Container Security Guide*: https://csrc.nist.gov/pubs/sp/800/190/final

**APIs and web standards**
- RFC 9110 — HTTP Semantics: https://www.rfc-editor.org/rfc/rfc9110.html
- RFC 8259 — The JavaScript Object Notation (JSON) Data Interchange Format: https://www.rfc-editor.org/rfc/rfc8259.html
- RFC 9457 — Problem Details for HTTP APIs: https://www.rfc-editor.org/rfc/rfc9457.html
- RFC 3339 — Date and Time on the Internet: https://www.rfc-editor.org/rfc/rfc3339.html
- RFC 7396 — JSON Merge Patch: https://www.rfc-editor.org/rfc/rfc7396.html
- RFC 6902 — JavaScript Object Notation (JSON) Patch: https://www.rfc-editor.org/rfc/rfc6902.html
- RFC 7519 — JSON Web Token (JWT): https://www.rfc-editor.org/rfc/rfc7519.html
- WHATWG Fetch Standard (CORS protocol): https://fetch.spec.whatwg.org/#http-cors-protocol
- MDN — Cross-Origin Resource Sharing (CORS): https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS
- MDN — Same-origin policy: https://developer.mozilla.org/en-US/docs/Web/Security/Same-origin_policy
- OpenAPI Specification 3.1.0: https://spec.openapis.org/oas/v3.1.0.html
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- gRPC documentation: https://grpc.io/docs/
- GraphQL specification: https://spec.graphql.org/

**Containers and orchestration**
- OCI Image Format Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Runtime Specification: https://github.com/opencontainers/runtime-spec/blob/main/spec.md
- Dockerfile reference: https://docs.docker.com/reference/dockerfile/
- Docker — Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Docker — Build secrets: https://docs.docker.com/build/building/secrets/
- Kubernetes — Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod Lifecycle (termination): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes — Configure a Pod to Use a ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- Kubernetes — Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Argo Rollouts — Canary strategy: https://argo-rollouts.readthedocs.io/en/stable/features/canary/
- Argo Rollouts — Analysis and progressive delivery: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/

**Security and supply chain**
- OWASP Top 10: https://owasp.org/www-project-top-ten/
- OWASP Application Security Verification Standard (ASVS): https://owasp.org/www-project-application-security-verification-standard/
- OWASP Cheat Sheet Series: https://cheatsheetseries.owasp.org/
- OWASP Kubernetes Top Ten: https://owasp.org/www-project-kubernetes-top-ten/
- SLSA — Supply-chain Levels for Software Artifacts: https://slsa.dev/spec/v1.0/
- Sigstore / cosign documentation: https://docs.sigstore.dev/
- SPDX specification: https://spdx.dev/use/specifications/
- CycloneDX specification: https://cyclonedx.org/specification/overview/

**Infrastructure as code and build automation**
- Terraform documentation: https://developer.hashicorp.com/terraform/docs
- HashiCorp Packer documentation: https://developer.hashicorp.com/packer/docs
- Apache Maven — Build lifecycle reference: https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html
- Gradle user manual: https://docs.gradle.org/current/userguide/userguide.html
- npm CLI — `npm ci`: https://docs.npmjs.com/cli/v10/commands/npm-ci
- GitHub Actions documentation: https://docs.github.com/en/actions
- GitLab CI/CD documentation: https://docs.gitlab.com/ee/ci/