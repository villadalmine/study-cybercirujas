# 1.1 MCP Purpose & Scope

**Certification:** Model Context Protocol Associate (MCPA) · **Exam version:** 2026-07-28
**Domain weight:** 5.33 % — foundational. Nearly every later objective (transports, primitives, authorization, server authoring) assumes you can state precisely *what MCP is responsible for and what it deliberately refuses to be responsible for*. Scope questions are where candidates most often lose points, because the wrong answers are all plausible-sounding capabilities that belong to some adjacent layer.

---

## 1. The architectural problem MCP exists to solve

### 1.1 The M×N integration matrix

Before MCP, connecting an LLM application to an external system meant writing a bespoke adapter, per application, per system. The adapter had to solve five problems that have nothing to do with the system being integrated:

1. **Discovery** — how does the application learn what operations exist, right now?
2. **Schema** — how are arguments described so a model can fill them correctly?
3. **Invocation** — how is a call dispatched, and how are results framed for a model rather than for a program?
4. **Context exposure** — how is read-only material (a file, a row, a log excerpt) handed to the model without pretending it is a function call?
5. **Lifecycle & trust** — who authenticates, who consents, what happens when the connection dies mid-call?

With `M` host applications and `N` backend systems, you write `M × N` adapters. A platform team running 12 agentic surfaces (IDE assistant, incident copilot, ticket triage bot, internal chat, CI reviewer, …) against 40 internal systems (Jira, PagerDuty, Grafana, Postgres, S3, the service catalog, …) is staring at **480 adapters**, each with its own auth handling, its own retry semantics, its own schema drift.

MCP converts that into `M + N`: **12 clients + 40 servers = 52** components. That reduction is the entire economic argument for the protocol, and it is the answer the exam is looking for when it asks *why* MCP exists.

```
        WITHOUT A PROTOCOL                        WITH MCP
   host₁ ──┬──┬──┬── system₁              host₁ ──┐            ┌── system₁
   host₂ ──┼──┼──┼── system₂              host₂ ──┤            ├── system₂
   host₃ ──┼──┼──┼── system₃              host₃ ──┼── MCP ─────┼── system₃
     ⋮     ⋮  ⋮  ⋮      ⋮                   ⋮     │  (JSON-RPC)│      ⋮
   host_M ─┴──┴──┴── system_N              host_M ┘            └── system_N

        O(M × N) adapters                      O(M + N) components
```

### 1.2 Why "just use OpenAPI and function calling" is not the same answer

This is the most common objection, and the exam tests whether you can articulate the difference. Every serious platform team already has OpenAPI specs. So why a new protocol?

Because OpenAPI answers question 2 (schema) and part of question 3 (invocation), and *nothing else*:

- **Discovery is build-time, not runtime.** An OpenAPI spec is compiled into client stubs. When the backend adds a capability, every host must be rebuilt and redeployed. MCP's `tools/list` is a live call, and `notifications/tools/list_changed` pushes the delta into an already-running session.
- **Granularity is wrong.** REST endpoints are resource-shaped (`GET /incidents`, `PATCH /incidents/{id}`). Models need task-shaped operations (`acknowledge_incident_and_page_secondary`). Somebody has to write that shim — with OpenAPI, that somebody is you, `M` times.
- **Token cost.** Naively injecting a 400-endpoint OpenAPI document into a context window costs tens of thousands of tokens before the user has said anything. MCP defines pagination on every list operation precisely because the catalogue is expected to be large and the context window is expected to be the scarce resource.
- **No concept of read-only context.** OpenAPI has no way to say "this is material to *read*, not an action to *take*". MCP separates Resources from Tools for exactly this reason, and the separation carries a control-ownership semantic (see §2.3).
- **The channel is one-directional.** An HTTP API can never ask the calling application to run an LLM completion on its behalf, or to prompt the human for a missing field. MCP's `sampling/createMessage` and `elicitation/create` invert the call direction over the same session.

The honest summary: **OpenAPI describes an HTTP surface for programmers; MCP describes a capability surface for a model, with a live session and a bidirectional channel.** They are not competitors — a great many MCP servers are thin, task-shaped facades over an OpenAPI backend.

### 1.3 The production failure this prevents

A concrete pattern from real platform work. An incident-response copilot integrates PagerDuty through a hand-rolled adapter. PagerDuty adds a field to the incident payload. The adapter's hard-coded schema doesn't know about it, so the model never sees it. No test fails — the adapter still returns 200, still parses, still produces plausible summaries. The defect is *silent and semantic*: the copilot has been confidently omitting a field for six weeks.

Under MCP, the tool's `inputSchema` and `outputSchema` are served by the system that owns them, fetched at session start, and re-fetched on `list_changed`. Schema drift becomes a protocol event instead of an invisible degradation. This is the SRE-facing value of runtime discovery, and it is worth more in practice than the `M+N` arithmetic.

---

## 2. What MCP is, precisely

> **Definition.** MCP is an open protocol that standardises how LLM applications connect to external context and capabilities. It is a **JSON-RPC 2.0** protocol carried over a defined set of transports, organised as **stateful sessions** with explicit lifecycle and capability negotiation, between three participant roles.

MCP was published by Anthropic in November 2024 and is developed in the open at `modelcontextprotocol.io`; its stewardship has since moved under neutral, Linux Foundation–hosted governance, which is also the body that issues the MCPA certification. Its acknowledged design ancestor is the **Language Server Protocol (LSP)** — same JSON-RPC substrate, same "one protocol replaces an N×M editor/language matrix" thesis.

### 2.1 Participants

| Role | Runs where | Owns | Cardinality |
|---|---|---|---|
| **Host** | The LLM application process (IDE, desktop app, agent runtime) | The model connection, the user relationship, the **security boundary**, consent UX, aggregation of all connections | 1 |
| **Client** | Inside the host, one instance per server | One stateful protocol session; capability negotiation; isolation of one server from another | 1 per server |
| **Server** | Local subprocess or remote service | Exposure of Tools, Resources, Prompts; its own credentials to the backend it fronts | N |

The **1:1 client↔server rule** is examinable and load-bearing. A host that talks to six servers instantiates six clients. There is no multiplexing of servers over one session, and a server never learns that other servers exist. That isolation is how a malicious or compromised server is prevented from observing, or interfering with, another server's traffic.

```
┌─────────────────────────── Host process (trust boundary) ────────────────────────────┐
│                                                                                      │
│   User ⇄ UI           Agent loop            Model provider API (OUT of MCP scope)    │
│                           │                                                          │
│           ┌───────────────┼───────────────┐                                          │
│     ┌─────▼─────┐   ┌─────▼─────┐   ┌─────▼─────┐                                    │
│     │ Client A  │   │ Client B  │   │ Client C  │   one client ⇄ one server, 1:1     │
│     └─────┬─────┘   └─────┬─────┘   └─────┬─────┘                                    │
└───────────┼───────────────┼───────────────┼──────────────────────────────────────────┘
            │ stdio         │ Streamable    │ Streamable HTTP
            │               │ HTTP          │ + OAuth 2.1
      ┌─────▼─────┐   ┌─────▼─────┐   ┌─────▼──────┐
      │ fs server │   │ catalog   │   │ SaaS MCP   │
      │ (local)   │   │ (in-VPC)  │   │ (3rd party)│
      └───────────┘   └─────┬─────┘   └────────────┘
                            │
                      ┌─────▼─────┐
                      │ Postgres  │
                      └───────────┘
```

### 2.2 The session lifecycle

Three steps, in fixed order. Every diagnosis in §7 starts by asking which of the three failed.

1. **`initialize` request** (client → server): the client's proposed `protocolVersion`, its `capabilities`, its `clientInfo`.
2. **`initialize` result** (server → client): the version the server has *chosen*, the server's `capabilities`, `serverInfo`, and an optional free-text `instructions` string that the host may place in the system prompt.
3. **`notifications/initialized`** (client → server): a notification, no response. Only after this may normal operations begin.

Version negotiation is **server-chooses**: the client proposes, the server replies with either the same version or another one it supports. If the client does not support what came back, the client **MUST** disconnect. It does not downgrade silently. Before `initialized`, the only permitted traffic is `ping` and progress notifications.

### 2.3 Primitive taxonomy — and who controls each

This table is the single densest source of exam questions in the domain. The "controlled by" column is protocol *intent*, not enforcement.

| Primitive | Direction | Controlled by | Core methods | Change notification |
|---|---|---|---|---|
| **Tools** | server → client | **Model** — the model decides when to invoke | `tools/list`, `tools/call` | `notifications/tools/list_changed` |
| **Resources** | server → client | **Application** — the host decides what to attach | `resources/list`, `resources/read`, `resources/templates/list`, `resources/subscribe` | `notifications/resources/list_changed`, `notifications/resources/updated` |
| **Prompts** | server → client | **User** — surfaced as slash commands, menu entries | `prompts/list`, `prompts/get` | `notifications/prompts/list_changed` |
| **Sampling** | client → server *(inverted)* | Host, with human approval | `sampling/createMessage` | — |
| **Elicitation** | client → server *(inverted)* | User | `elicitation/create` | — |
| **Roots** | client → server *(inverted)* | Host | `roots/list` | `notifications/roots/list_changed` |

Plus cross-cutting **utilities**: `ping`, `$/progress` style progress notifications, `notifications/cancelled`, `logging/setLevel` + `notifications/message`, `completion/complete` (argument autocompletion), and cursor-based pagination on every `*/list`.

The three inverted primitives are what makes MCP a protocol rather than an RPC convention. **Sampling** lets a server request inference without holding a model API key or paying for tokens — the host pays, the host chooses the model, the host asks the human. **Elicitation** lets a server request structured input mid-call (a missing ticket ID, a confirmation) instead of failing. **Roots** let the client tell the server which filesystem or URI boundaries it is permitted to operate within.

### 2.4 Protocol revisions

Revisions are date-stamped strings, not semver. The ones every MCPA candidate should be able to place:

| Revision | Introduced | Removed / deprecated |
|---|---|---|
| `2024-11-05` | Initial public spec; stdio and HTTP+SSE (dual-endpoint) transports | — |
| `2025-03-26` | **Streamable HTTP** transport; OAuth 2.1 authorization framework; tool annotations; audio content type; JSON-RPC batching | HTTP+SSE deprecated |
| `2025-06-18` | **Elicitation**; structured tool output (`outputSchema` / `structuredContent`); resource links in tool results; mandatory `MCP-Protocol-Version` header on HTTP; RFC 8707 resource indicators; MCP server formally classified as an OAuth 2.0 **Resource Server** | JSON-RPC batching removed |

Later date-stamped revisions follow on the same cadence. **The durable lesson is mechanical, not historical: never hard-code a version — negotiate it, log the negotiated value, and alert on unexpected downgrades.** A fleet that silently negotiates down to `2025-03-26` loses structured tool output and elicitation, and the symptom will present as "the agent got worse", not as an error.

---

## 3. Scope: the boundary line

Everything in the left column is defined by the specification and is therefore interoperable. Everything in the right column is *your* problem, or another protocol's problem, and building it is a platform decision — not a protocol one.

| **In scope (the spec defines it)** | **Out of scope (you or another layer owns it)** |
|---|---|
| Session lifecycle: initialize → initialized → operation → shutdown | Model inference, prompt construction, context-window management |
| Capability negotiation | Agent planning, task decomposition, multi-step control flow |
| Tool / Resource / Prompt discovery and invocation | **Which** tool the model picks, and when — that is model + host policy |
| Server→client sampling, elicitation, roots | Choice of model, temperature, cost ceilings for sampling |
| Notifications: list-changed, resource-updated, progress, cancellation | Guaranteed delivery, ordering across reconnects beyond SSE resumability |
| Transports: stdio and Streamable HTTP | Service discovery, DNS, load balancing, mTLS, service mesh |
| Authorization framework for HTTP transports (OAuth 2.1, RFC 9728 / 8414 / 8707) | Authorization for **stdio** — credentials come from the environment |
| | RBAC, ABAC, per-tool policy, approval workflows |
| Error semantics: JSON-RPC errors *and* tool-level `isError` | Retry policy, backoff, circuit breaking, idempotency keys |
| Pagination, logging levels, completion | Rate limits, quotas, metering, billing |
| Content types: text, image, audio, embedded/linked resources | Data residency, retention, PII classification, redaction |
| Structured output via JSON Schema | Schema registry, versioning, compatibility guarantees |
| | **Health endpoints and metrics format** |
| | Server packaging, distribution, supply-chain attestation |
| | Server-to-server federation or composition |
| | Encryption beyond what the transport provides (TLS) |

### 3.1 Four non-goals worth stating out loud

**MCP is not an agent framework.** It gives an agent hands and eyes. It does not give it a plan. LangGraph, the Claude Agent SDK, and equivalents sit *above* MCP and call it. A question that describes "orchestrating a five-step workflow across three tools with retries" is describing an agent runtime, not MCP.

**MCP does not define a health check.** `ping` is an in-session JSON-RPC method — it requires an initialized session and a session ID. A kubelet cannot speak it. Every production HTTP server therefore ships a non-MCP `/healthz` and `/readyz` alongside `/mcp`. If you see a manifest whose `livenessProbe` points at the MCP endpoint, it is wrong.

**MCP does not define observability.** There is no standard metric name, no trace-context propagation rule, no required log format. The JSON-RPC `id` is your only native correlation handle, and it is only unique *within a session* — you must join it with the `Mcp-Session-Id` to get a globally unique key. Build this yourself, deliberately.

**MCP does not compose servers.** A server may itself be a client of another server, but that is an application pattern, not a protocol feature: there is no delegation, no capability forwarding, no transitive authorization. "MCP gateway" products implement this above the spec, and the security review of such a gateway is entirely on you.

### 3.2 Adjacent, not part of

- **The MCP Registry** (`registry.modelcontextprotocol.io`) and its `server.json` metadata format are a separate, complementary project for *discovering* servers. Discovery of servers is out of the protocol's scope; the registry fills the gap without being part of the wire protocol.
- **Agent2Agent (A2A)** addresses agent↔agent communication. MCP is vertical (agent → tools and context); A2A is horizontal (agent ↔ peer agent). They compose.

### 3.3 The trust-and-safety principles the spec does state

The specification does not *enforce* security, but it does state principles that the host is expected to implement, and these are examinable:

1. **User consent and control** — the user explicitly approves what data is shared and what actions are taken.
2. **Data privacy** — the host does not transmit user data to servers without consent.
3. **Tool safety** — tool descriptions are **untrusted input** unless the server is trusted. A tool description is fed to a model; a malicious description is a prompt-injection vector. Invocation requires explicit user consent.
4. **LLM sampling controls** — the user approves sampling requests and controls what of the conversation the server may see. A server never gets the full conversation by default.

Principle 3 is the one platform teams under-weight. **Adding an MCP server to a host is executing third-party text inside your model's prompt.** Treat the server catalogue with the rigour you apply to a package registry.

---

## 4. Comparative analysis

### 4.1 MCP vs LSP — the closest relative

| Dimension | LSP | MCP |
|---|---|---|
| Consumer of the data | An IDE — deterministic, parses exactly | An LLM — probabilistic, *interprets* |
| Wire format | JSON-RPC 2.0, `Content-Length` framed over pipes | JSON-RPC 2.0, newline-delimited (stdio) or HTTP/SSE |
| Discovery | Static capability object at initialize | Capabilities at initialize **plus** runtime `*/list` + `list_changed` |
| Server→client calls | `window/showMessage`, `workspace/applyEdit` | `sampling/createMessage`, `elicitation/create`, `roots/list` |
| Trust posture | Server is developer-installed tooling | Server may be third-party and adversarial *toward the model* |
| Descriptions | Human-facing strings | **Prompt input** — an injection surface |
| Remote operation | Rare, not a design goal | First-class (Streamable HTTP + OAuth 2.1) |

The decisive difference: in LSP, a malformed description is a cosmetic bug. In MCP, a description is executed by a language model, which makes documentation a security boundary.

### 4.2 MCP vs alternatives for tool integration

| Dimension | In-process SDK call | OpenAPI + hand-written shims | MCP |
|---|---|---|---|
| Coupling | Compile-time, same language | Build-time codegen | Runtime, language-agnostic |
| New capability reaches the host | Rebuild + redeploy host | Regenerate + redeploy host | `list_changed` notification, zero deploy |
| Process isolation | None — server code shares the host's memory and creds | Depends | Separate process or service; explicit trust boundary |
| Read-only context | Ad hoc | No concept | Resources, with subscriptions |
| Human-in-the-loop mid-call | Custom | Impossible | Elicitation |
| Server borrows the host's model | Trivially (and dangerously) | No | Sampling, mediated + consented |
| Cross-vendor portability | None | Per-vendor tool shim | Any MCP host |
| Latency overhead | ~0 | 1 HTTP RTT | 1 RTT + session setup (amortised) |
| Failure blast radius | Crashes the host | Isolated | Isolated; one client dies, others live |
| Operational surface | None | HTTP service | HTTP service **+ session state** ← the real cost |

The honest trade-off: **MCP buys portability and runtime discovery, and charges you a stateful network service to operate.** For a single application against a single backend, an in-process call is still the right engineering answer. MCP wins as soon as `M > 1` or `N` grows.

### 4.3 Transport trade-offs

| | **stdio** | **Streamable HTTP** | **HTTP+SSE (deprecated)** |
|---|---|---|---|
| Status | Current, required for local | Current, required for remote | Deprecated since `2025-03-26` |
| Endpoints | stdin / stdout | One (`POST` + `GET` on the same path) | Two (`/sse` for reads, `/messages` for writes) |
| Framing | Newline-delimited JSON, **stdout only** | `application/json` or `text/event-stream` | SSE |
| Server→client push | Interleaved on stdout | `GET` opens an SSE stream | `/sse` stream |
| Session identity | The process | `Mcp-Session-Id` header | Endpoint URL issued per connection |
| Resumability | None — restart the process | `Last-Event-ID` replay | Fragile |
| Auth | Environment variables / OS user | OAuth 2.1 + bearer token | Ad hoc |
| Scaling | 1 process per client | Horizontal, **with session affinity** | Poor |
| Network exposure | **None** | Full HTTP surface | Full HTTP surface |
| Ops complexity | Trivial | Real: LB timeouts, buffering, sticky routing, session GC | High |
| Classic failure | **Logging to stdout corrupts the stream** | Proxy buffers SSE; session hashed to the wrong replica | Endpoint churn |

**Rules that follow directly.** For stdio: the server MUST NOT write anything to stdout that is not a protocol message; logs go to stderr. For HTTP: validate the `Origin` header to prevent DNS rebinding, and bind local servers to `127.0.0.1`, never `0.0.0.0`.

### 4.4 Deployment topology trade-offs

| Topology | Isolation | Identity model | Scaling | Cost | Use when |
|---|---|---|---|---|---|
| **stdio subprocess on the user's machine** | Per-user OS process | The logged-in user | N/A | Zero marginal | Local files, local git, dev tooling |
| **Sidecar in the agent's pod** | Per-agent-instance | The pod's SA | Scales with the agent | 1 container per replica | Agent-specific, low fan-out |
| **Per-user pod (session-scoped)** | Strong, per tenant | End-user OAuth token | Poor — pod per user | High | Hard multi-tenancy, regulated data |
| **Shared multi-tenant service** | **Logical only** — enforced in your code | Per-request bearer token | Good, needs sticky sessions | Low per user | The default for internal platforms |
| **Vendor-hosted remote server** | Vendor's problem | OAuth to the vendor | Vendor's problem | Per-seat / per-call | SaaS you do not run |

The shared multi-tenant service is where most production incidents live, for one reason: **Streamable HTTP sessions are stateful, and stateless horizontal scaling is the default assumption of every Kubernetes deployment you have ever written.** §5 and §7 are about closing that gap.

---

## 5. Production manifests

### 5.1 Host-side client configuration

A host's server catalogue — one local stdio server, one remote HTTP server.

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/srv/data"],
      "env": {
        "FS_READ_ONLY": "true"
      }
    },
    "catalog": {
      "type": "http",
      "url": "https://mcp.internal.example.com/mcp",
      "headers": {
        "MCP-Protocol-Version": "2025-06-18"
      }
    }
  }
}
```

### 5.2 Namespace, service account, and server configuration

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp
  labels:
    kubernetes.io/metadata.name: mcp
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-catalog
  namespace: mcp
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-catalog-config
  namespace: mcp
data:
  server.yaml: |
    transport:
      kind: streamable-http
      bind: "0.0.0.0:8080"
      path: /mcp
      sse_keepalive: 15s
      session_ttl: 1800s
      max_body_bytes: 1048576
    protocol:
      supported_versions:
        - "2025-06-18"
        - "2025-03-26"
      instructions: >-
        Internal service catalog. Use search_services before get_service;
        service IDs are opaque ULIDs, never guess one.
    security:
      allowed_origins:
        - "https://console.internal.example.com"
      resource_identifier: "https://mcp.internal.example.com/mcp"
      require_bearer: true
    capabilities:
      tools:
        listChanged: true
      resources:
        subscribe: true
        listChanged: true
      prompts:
        listChanged: false
      logging: {}
    observability:
      log_format: json
      log_stream: stderr
      metrics_bind: "0.0.0.0:9090"
```

### 5.3 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-catalog
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-catalog
    app.kubernetes.io/component: mcp-server
spec:
  replicas: 3
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-catalog
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-catalog
        app.kubernetes.io/component: mcp-server
    spec:
      serviceAccountName: mcp-catalog
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 120
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-catalog
      containers:
        - name: server
          image: registry.internal.example.com/mcp/catalog:1.8.3
          imagePullPolicy: IfNotPresent
          args:
            - "--config=/etc/mcp/server.yaml"
          env:
            - name: MCP_AUTH_ISSUER
              value: "https://idp.internal.example.com/realms/agents"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: OTEL_SERVICE_NAME
              value: "mcp-catalog"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: CATALOG_DB_DSN
              valueFrom:
                secretKeyRef:
                  name: mcp-catalog-db
                  key: dsn
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "sleep 15"
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: "2"
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: config
              mountPath: /etc/mcp
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: mcp-catalog-config
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
```

Two decisions that are specific to MCP and not generic Kubernetes hygiene:

- `terminationGracePeriodSeconds: 120` with a `preStop` sleep. A pod may be holding open SSE streams and half-finished `tools/call` invocations. The default 30 s severs them mid-answer.
- Probes point at `/healthz` and `/readyz`, **not** `/mcp`. MCP defines no health check (§3.1).

### 5.4 Service, PDB, and scrape configuration

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mcp-catalog
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-catalog
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mcp-catalog
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mcp-catalog
  namespace: mcp
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-catalog
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mcp-catalog
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-catalog
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
```

### 5.5 Ingress — session affinity by `Mcp-Session-Id`

This is the part that generic Kubernetes experience does not prepare you for. `sessionAffinity: ClientIP` on the Service is the obvious reflex and it is **wrong**: every client behind a corporate NAT or an egress gateway shares a source IP and lands on one pod. Route on the protocol's own session identifier instead.

First, teach the ingress controller to derive a routing key, falling back to a per-request value when the header is absent (the `initialize` call, which has no session yet):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  proxy-buffering: "off"
  use-http2: "true"
  http-snippet: |
    map $http_mcp_session_id $mcp_route_key {
        ""      $request_id;
        default $http_mcp_session_id;
    }
```

Then bind the Ingress to it:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mcp-catalog
  namespace: mcp
  annotations:
    nginx.ingress.kubernetes.io/upstream-hash-by: "$mcp_route_key"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/proxy-body-size: "1m"
    cert-manager.io/cluster-issuer: internal-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - "mcp.internal.example.com"
      secretName: mcp-catalog-tls
  rules:
    - host: mcp.internal.example.com
      http:
        paths:
          - path: /mcp
            pathType: Prefix
            backend:
              service:
                name: mcp-catalog
                port:
                  number: 8080
          - path: /.well-known/oauth-protected-resource
            pathType: Exact
            backend:
              service:
                name: mcp-catalog
                port:
                  number: 8080
```

The `3600` timeouts exist because an SSE stream held open by `GET /mcp` is, to nginx, an idle upstream connection. At the default 60 s it is killed, and the symptom the user sees is "the assistant stops responding after a minute".

### 5.6 Egress containment — the real blast radius

The security question about an MCP server is never "what does it claim to do", it is "what can it reach".

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mcp-catalog
  namespace: mcp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-catalog
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
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 9090
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.64.12.0/24
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 4317
```

Note what is **not** allowed: general internet egress. A prompt-injected tool that tries to exfiltrate catalogue rows to an external host fails at the network layer, not at the model layer.

### 5.7 Alerting on protocol-level health

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-catalog
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp-catalog.protocol
      rules:
        - alert: MCPInitializeFailureRate
          expr: |
            sum(rate(mcp_jsonrpc_requests_total{job="mcp-catalog",method="initialize",outcome="error"}[5m]))
            /
            clamp_min(sum(rate(mcp_jsonrpc_requests_total{job="mcp-catalog",method="initialize"}[5m])), 0.001)
            > 0.05
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Over 5% of MCP initialize handshakes are failing"
            description: "Check version negotiation and the OAuth resource indicator before touching the backend."
            runbook_url: "https://runbooks.internal.example.com/mcp/initialize-failures"
        - alert: MCPProtocolDowngrade
          expr: |
            sum(rate(mcp_sessions_started_total{job="mcp-catalog",negotiated_version!="2025-06-18"}[15m]))
            > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Clients are negotiating a protocol revision below 2025-06-18"
            description: "Structured tool output and elicitation are unavailable on these sessions."
        - alert: MCPSessionNotFoundSpike
          expr: |
            sum(rate(mcp_http_responses_total{job="mcp-catalog",code="404"}[5m]))
            > 1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Sessions are being lost — affinity, TTL or a rollout"
            description: "A 404 on an established session forces the client to re-initialize."
        - alert: MCPToolCallSaturation
          expr: |
            histogram_quantile(
              0.99,
              sum by (le, tool) (rate(mcp_tool_call_duration_seconds_bucket{job="mcp-catalog"}[5m]))
            )
            > 30
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "p99 tool latency above 30s — emit progress notifications or the client will give up"
```

### 5.8 Bare-metal deployment

```ini
[Unit]
Description=MCP catalog server
Documentation=https://modelcontextprotocol.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mcp
Group=mcp
ExecStart=/usr/local/bin/mcp-catalog --config=/etc/mcp/server.yaml --bind=127.0.0.1:8080
Environment=MCP_AUTH_ISSUER=https://idp.internal.example.com/realms/agents
EnvironmentFile=-/etc/mcp/catalog.env
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=2
TimeoutStopSec=120
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/var/lib/mcp-catalog
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
MemoryMax=512M

[Install]
WantedBy=multi-user.target
```

`--bind=127.0.0.1:8080` is deliberate: a locally running MCP server must **not** listen on `0.0.0.0`. Combined with `Origin` validation, this is the spec's stated defence against DNS rebinding, where a malicious web page resolves a hostname to `127.0.0.1` and drives the user's local MCP server from the browser.

---

## 6. CLI walkthrough with real output

### 6.1 Driving a stdio server by hand

The fastest way to prove a stdio server speaks the protocol at all — no SDK, no inspector, no host.

```
$ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"sre-probe","version":"0.3.1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | npx -y @modelcontextprotocol/server-filesystem /srv/data 2>/tmp/fs.err \
  | jq -c '{id: .id, keys: ((.result // .error) | keys)}'
{"id":1,"keys":["capabilities","protocolVersion","serverInfo"]}
{"id":2,"keys":["tools"]}

$ head -2 /tmp/fs.err
Secure MCP Filesystem Server running on stdio
Allowed directories: [ '/srv/data' ]
```

Read the last two lines carefully — **the banner went to stderr, which is correct.** A server that prints that banner to stdout fails at `initialize` with a JSON parse error, and §7.1 covers the symptom.

### 6.2 The full Streamable HTTP handshake with curl

```
$ export MCP_URL=https://mcp.internal.example.com/mcp
$ curl -sS -D /tmp/h1 -o /tmp/b1 "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{}},"clientInfo":{"name":"sre-probe","title":"SRE Probe","version":"0.3.1"}}}'

$ cat /tmp/h1
HTTP/2 200
content-type: application/json
mcp-session-id: 0f2b9c41-7d3e-4a08-9f6b-2c5d81ee4410
mcp-protocol-version: 2025-06-18
cache-control: no-store
x-served-by: mcp-catalog-6c7f4b9d8f-2kx9p
date: Thu, 17 Sep 2026 09:14:02 GMT

$ jq -c .result.capabilities /tmp/b1
{"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"prompts":{"listChanged":false},"logging":{},"completions":{}}

$ jq -r '.result.serverInfo | "\(.name) \(.version)"' /tmp/b1
catalog 1.8.3

$ export SID=$(awk -F': ' '/^mcp-session-id/ {print $2}' /tmp/h1 | tr -d '\r')
```

Complete the handshake — a notification, so the correct status is `202`, not `200`:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: $SID" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
202
```

Now enumerate. This server answers on an SSE stream, so the payload arrives framed:

```
$ curl -sS -N "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: $SID" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
event: message
id: 41
data: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search_services","title":"Search services","description":"Full-text search over the service catalog.","inputSchema":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","default":20}},"required":["query"]},"annotations":{"readOnlyHint":true,"idempotentHint":true}},{"name":"get_service","title":"Get service","description":"Fetch one catalog entry by ULID.","inputSchema":{"type":"object","properties":{"id":{"type":"string","pattern":"^[0-9A-HJKMNP-TV-Z]{26}$"}},"required":["id"]},"outputSchema":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"tier":{"type":"string"},"owner":{"type":"string"}},"required":["id","name","tier","owner"]},"annotations":{"readOnlyHint":true}}],"nextCursor":"eyJvZmZzZXQiOjUwfQ=="}}
```

Two things to notice, both examinable. `annotations.readOnlyHint` is a *hint* to the host's consent UI, not an enforcement mechanism — a server can lie, and the host must not treat it as a security control. `nextCursor` means this is page one; a client that ignores it silently hides the rest of the catalogue from the model.

### 6.3 Discovering authorization the way a client does

Strip the token and read the challenge:

```
$ curl -sS -D - -o /dev/null -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.1.0"}}}'
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://mcp.internal.example.com/.well-known/oauth-protected-resource"
content-length: 0
date: Thu, 17 Sep 2026 09:16:44 GMT
```

That header is the whole discovery chain (RFC 9728). Follow it:

```
$ curl -sS https://mcp.internal.example.com/.well-known/oauth-protected-resource | jq .
```

```json
{
  "resource": "https://mcp.internal.example.com/mcp",
  "authorization_servers": ["https://idp.internal.example.com/realms/agents"],
  "bearer_methods_supported": ["header"],
  "scopes_supported": ["catalog.read", "catalog.write"],
  "resource_documentation": "https://docs.internal.example.com/mcp/catalog"
}
```

The `resource` value is what the client must send as the RFC 8707 `resource` parameter during the authorization and token requests. It binds the issued token to *this* server, which is how the spec prevents a malicious server from replaying a token against a different backend.

### 6.4 MCP Inspector — the reference debugging tool

```
$ npx -y @modelcontextprotocol/inspector
Starting MCP inspector...
⚙️ Proxy server listening on 127.0.0.1:6277
🔑 Session token: 8b41c0d9e7f3a25614bd0f92ac73e15d
🔗 Open inspector with token pre-filled:
   http://localhost:6274/?MCP_PROXY_AUTH_TOKEN=8b41c0d9e7f3a25614bd0f92ac73e15d
🚀 MCP Inspector is up and running at http://127.0.0.1:6274
```

Headless mode, which is what belongs in CI:

```
$ npx -y @modelcontextprotocol/inspector --cli "$MCP_URL" \
    --transport http --method tools/list \
  | jq -r '.tools[] | "\(.name)\t\(.annotations.readOnlyHint // false)"'
search_services	true
get_service	true
register_service	false
deprecate_service	false
```

A CI gate that fails the build when a tool changes from `readOnlyHint: true` to `false` without a corresponding review is cheap to write and catches a real class of accident.

### 6.5 Verifying the deployment

```
$ kubectl -n mcp get deploy,pod,svc -l app.kubernetes.io/name=mcp-catalog
NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/mcp-catalog   3/3     3            3           6d4h

NAME                               READY   STATUS    RESTARTS   AGE
pod/mcp-catalog-6c7f4b9d8f-2kx9p   1/1     Running   0          2d1h
pod/mcp-catalog-6c7f4b9d8f-7wq4n   1/1     Running   0          2d1h
pod/mcp-catalog-6c7f4b9d8f-p8f2t   1/1     Running   0          2d1h

NAME                  TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)             AGE
service/mcp-catalog   ClusterIP   10.43.118.204   <none>        8080/TCP,9090/TCP   6d4h
```

Confirm affinity actually works — twenty requests on one session must land on one pod:

```
$ for i in $(seq 1 20); do
    curl -sS -o /dev/null -D - "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H 'MCP-Protocol-Version: 2025-06-18' \
      -H "Mcp-Session-Id: $SID" \
      -H "Authorization: Bearer $MCP_TOKEN" \
      -d '{"jsonrpc":"2.0","id":99,"method":"ping"}' \
    | awk -F': ' '/^x-served-by/ {print $2}'
  done | sort | uniq -c
     20 mcp-catalog-6c7f4b9d8f-2kx9p
```

Three pod names in that output means the routing key is not being honoured, and every session is one unlucky hash away from a 404.

Protocol-level metrics:

```
$ kubectl -n mcp exec deploy/mcp-catalog -- \
    wget -qO- http://127.0.0.1:9090/metrics | grep -E '^mcp_(sessions|jsonrpc)' | head -8
mcp_sessions_active 214
mcp_sessions_started_total{negotiated_version="2025-06-18"} 18402
mcp_sessions_started_total{negotiated_version="2025-03-26"} 37
mcp_sessions_evicted_total{reason="ttl"} 1183
mcp_sessions_evicted_total{reason="shutdown"} 96
mcp_jsonrpc_requests_total{method="initialize",outcome="ok"} 18439
mcp_jsonrpc_requests_total{method="tools/list",outcome="ok"} 18355
mcp_jsonrpc_requests_total{method="tools/call",outcome="error"} 241
```

The 37 sessions on `2025-03-26` are a live finding: some client in the fleet is pinned to an old revision and is therefore not receiving structured tool output. That is the kind of drift `MCPProtocolDowngrade` exists to surface.

---

## 7. Verification and failure diagnosis

### 7.1 The diagnosis table

| Symptom | Root cause | Probe | Fix |
|---|---|---|---|
| stdio server "disconnects immediately"; client reports a JSON parse error | The server wrote a banner, warning or debug line to **stdout** | Run the server with `2>/dev/null` and read raw stdout — anything that is not JSON is the bug | Route **all** logging to stderr, or to the in-session `notifications/message` |
| `initialize` succeeds, then every call returns `-32601 Method not found` | The server never declared the capability in its `initialize` result | `jq .result.capabilities` on the initialize response | Declare `tools` / `resources` / `prompts` in the capabilities object |
| Client disconnects right after `initialize` | Version negotiation failed — the server chose a revision the client does not implement | Compare `params.protocolVersion` sent with `result.protocolVersion` returned | Add the revision to the server's supported list, or upgrade the client. Never patch by hard-coding |
| HTTP `400 Bad Request` on every call after initialize | `Mcp-Session-Id` not echoed on subsequent requests | Inspect the client's outbound headers | Capture the header from the `initialize` response and send it on every request |
| HTTP `404` on a session that worked a minute ago | Session evicted: TTL expiry, pod rollout, or the request hashed to a different replica | `mcp_sessions_evicted_total`, plus the `x-served-by` fan-out test in §6.5 | Session affinity on `Mcp-Session-Id`; and the **client MUST re-initialize on 404** — that is specified behaviour, not an error to retry |
| SSE stream delivers nothing until the request completes | A reverse proxy is buffering `text/event-stream` | `curl -N` direct to the pod vs. through the ingress; if direct streams and ingress does not, it is the proxy | `proxy-buffering: "off"`; have the server emit `X-Accel-Buffering: no` on SSE responses |
| Long tool calls die at exactly 60 s | LB/ingress idle timeout, not the server | The round number is the tell — server logs show the call still running | Raise `proxy-read-timeout`; emit progress notifications so the channel is never idle |
| `tools/call` returns a JSON-RPC `error` object for a business failure | Protocol errors and tool errors were conflated | Compare the response shape against the spec | Protocol failures → JSON-RPC `error`. Tool failures → `result` with `isError: true` and the message in `content`, **so the model can read it and retry** |
| Model ignores half the tools | The client never followed `nextCursor` | Check for `nextCursor` in the `tools/list` result | Implement pagination in the client |
| `401` even with a fresh token | Token was issued for a different audience/resource | Decode the JWT `aud` and compare to the `resource` in the protected-resource metadata | Send the RFC 8707 `resource` parameter at authorization and token time |
| A server reaches a backend it should not | Egress unrestricted; MCP defines no network policy | `kubectl exec` and try the connection | NetworkPolicy — §5.6. This is your layer, not the protocol's |
| Model behaves oddly after adding a server | Prompt injection via a tool description or resource content | Read the raw `description` fields with the inspector | Treat server text as untrusted input; review and pin server versions |

### 7.2 The verification ladder

Each rung proves strictly more than the one below it. Know which rung a claim rests on before you assert it in an incident review.

| Question | How | Cost |
|---|---|---|
| Is the process alive and reachable? | `/healthz`, `kubectl get pod` | Free — proves nothing about the protocol |
| Does it speak MCP at all? | Raw `initialize` via curl or a stdio pipe (§6.1, §6.2) | Free — proves framing and lifecycle |
| Which revision did it negotiate? | `result.protocolVersion` + `mcp_sessions_started_total` | Free — catches silent downgrades |
| What does it actually expose? | `tools/list`, `resources/list`, `prompts/list`, **all pages** | Free — catches capability drift |
| Do the schemas still match? | Diff `inputSchema` / `outputSchema` against a committed golden file in CI | Free — catches the §1.3 silent-degradation class |
| Is affinity real under load? | The `x-served-by` fan-out test (§6.5) | Free — the only way to know before an incident |
| Do the tools *do what they say*? | Contract tests against the real backend | Runs the backend — no free substitute |
| Are the descriptions safe to feed a model? | Human review of every `description` at version pin time | Human time — **and nothing else substitutes for it** |

That last row is the honest gap. Every automated check above it passes on a server whose tool description contains a well-crafted instruction to the model. There is no mechanical detector for a persuasive sentence, which is precisely why the specification places consent and review in the **host**, and why "MCP is a trust boundary, not a trust mechanism" is the correct one-line summary of its security scope.

### 7.3 A worked incident

**Report:** "The incident copilot stopped being able to look up services. Started around 14:20."

```
$ kubectl -n mcp get pod -l app.kubernetes.io/name=mcp-catalog
NAME                           READY   STATUS    RESTARTS   AGE
mcp-catalog-7d9c5f6b44-h2n8x   1/1     Running   0          12m
mcp-catalog-7d9c5f6b44-q4tzv   1/1     Running   0          11m
mcp-catalog-7d9c5f6b44-vk6dp   1/1     Running   0          11m
```

All healthy, all ~12 minutes old — a rollout at 14:20. Confirm:

```
$ kubectl -n mcp rollout history deploy/mcp-catalog | tail -3
4         image updated to 1.8.2
5         image updated to 1.8.3

$ kubectl -n mcp exec deploy/mcp-catalog -- \
    wget -qO- http://127.0.0.1:9090/metrics | grep mcp_http_responses_total | grep '404'
mcp_http_responses_total{code="404"} 2891
```

The diagnosis is now mechanical: the rollout discarded every in-memory session, and 2891 in-flight requests hit a replica that had never heard of their `Mcp-Session-Id`. The pods are fine; the *sessions* are gone. The copilot's client treated the 404 as a permanent tool failure instead of re-initializing.

Two fixes, at two different layers, and the exam-relevant point is that only one of them is an MCP concern:

- **Client (protocol correctness):** on `404`, discard the session ID and re-run `initialize`. This is specified behaviour.
- **Platform (operational):** externalise session state to Redis, or accept the churn and keep `maxUnavailable: 0` with a long grace period so the window is small.

Neither is a bug in the backend, and no amount of database tuning would have found it. That is the shape of MCP incidents: **stateful protocol semantics colliding with stateless infrastructure assumptions.**

---

## 8. Scope summary for the exam

Commit these five statements; the rest of the domain is elaboration.

1. **Purpose.** MCP standardises the connection between LLM applications and external context/capabilities, turning an `M × N` integration matrix into `M + N`, with **runtime** discovery rather than build-time coupling.
2. **Mechanism.** JSON-RPC 2.0, stateful sessions, explicit capability negotiation, three roles (host / client / server), **one client per server**, over stdio (local) or Streamable HTTP (remote).
3. **Primitives.** Server-side: Tools (model-controlled), Resources (application-controlled), Prompts (user-controlled). Client-side and inverted: Sampling, Elicitation, Roots.
4. **Boundary.** MCP defines *the connection*. It does not define inference, agent orchestration, tool-selection policy, RBAC, rate limiting, health checks, observability, server discovery, or server-to-server composition.
5. **Trust.** The **host** is the security boundary. Tool descriptions and resource content are untrusted input to a model. The protocol states principles — consent, privacy, tool safety, sampling control — and leaves enforcement to the implementation.

---

## References

**Primary — protocol and specification**

- Model Context Protocol — official site and documentation: https://modelcontextprotocol.io/
- MCP Specification (current revision index): https://modelcontextprotocol.io/specification/
- Specification revision `2025-06-18`: https://modelcontextprotocol.io/specification/2025-06-18
- Architecture overview: https://modelcontextprotocol.io/specification/2025-06-18/architecture
- Lifecycle (initialize, capability negotiation, shutdown): https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Transports (stdio, Streamable HTTP): https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Authorization (OAuth 2.1, RFC 9728 / 8414 / 8707): https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Server features — Tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Server features — Resources: https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- Server features — Prompts: https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- Client features — Sampling: https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- Client features — Elicitation: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- Client features — Roots: https://modelcontextprotocol.io/specification/2025-06-18/client/roots
- Security best practices: https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices

**Certification**

- Model Context Protocol Associate (MCPA) — Linux Foundation: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/

**Reference implementations and tooling**

- MCP organisation on GitHub: https://github.com/modelcontextprotocol
- Specification repository (including SEP proposals): https://github.com/modelcontextprotocol/modelcontextprotocol
- MCP Inspector: https://github.com/modelcontextprotocol/inspector
- Reference servers: https://github.com/modelcontextprotocol/servers
- MCP Registry: https://github.com/modelcontextprotocol/registry

**Underlying standards**

- JSON-RPC 2.0 Specification: https://www.jsonrpc.org/specification
- JSON Schema: https://json-schema.org/specification
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://www.rfc-editor.org/rfc/rfc9728.html
- RFC 8707 — Resource Indicators for OAuth 2.0: https://www.rfc-editor.org/rfc/rfc8707.html
- RFC 8414 — OAuth 2.0 Authorization Server Metadata: https://www.rfc-editor.org/rfc/rfc8414.html
- RFC 7636 — PKCE: https://www.rfc-editor.org/rfc/rfc7636.html
- HTML Living Standard — Server-Sent Events: https://html.spec.whatwg.org/multipage/server-sent-events.html

**Design ancestry and adjacent protocols**

- Language Server Protocol specification: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- Agent2Agent (A2A) protocol: https://a2a-protocol.org/

**Infrastructure references used in the manifests**

- Kubernetes — Services and session affinity: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Pod lifecycle and termination: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- ingress-nginx annotations reference: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- Prometheus Operator API (`ServiceMonitor`, `PrometheusRule`): https://prometheus-operator.dev/docs/api-reference/api/
- systemd.exec — sandboxing directives: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html