# 5.1 Roles, Responsibilities & Adoption

**Certification:** Model Context Protocol Associate (MCPA) — exam version 2026-07-28
**Domain weight:** 6.67 %

---

## 1. The production problem: an integration protocol with no owner is an outage with no owner

MCP solves the N×M problem — *N* agentic applications × *M* internal systems collapses from N×M bespoke connectors to N+M protocol implementations. That is the part everyone quotes. The part that breaks in production is the second-order effect: **the connector that used to live inside one team's codebase is now a network-reachable service that executes side effects on behalf of a non-deterministic caller.**

Consider the failure that motivates this entire objective. A platform team stands up an MCP server exposing `finance.post_journal_entry`. Three different hosts connect to it: an internal chat assistant, a CI bot, and a partner-facing agent. At 03:00 the tool starts returning `-32603` for 40 % of calls.

* The host team says the server is broken.
* The server team says the upstream ERP is throttling.
* The security team observes that the server has been accepting the *host's* user token and replaying it upstream — so the ERP sees one identity for three trust domains and cannot attribute anything.
* Nobody can answer "who approved exposing a write-capable tool to a partner-facing host", because the approval lived in a Slack thread.

Every one of those is a **role boundary** failure, not a protocol failure. MCP's own specification is unusually explicit about this: it defines not just wire format but a set of *trust and safety principles* that it deliberately declines to enforce in the protocol, assigning them instead to implementors. Knowing which participant owes which guarantee is the difference between an MCP deployment you can operate and one you can only apologise for.

Three distinct taxonomies collide in this objective, and the exam tests all three:

| Taxonomy | Members | Defined by |
|---|---|---|
| **Protocol participants** | Host, Client, Server | MCP specification (architecture) |
| **Security principals** | Resource Owner, Client, Authorization Server, Resource Server | OAuth 2.1 / RFC 9728, as profiled by MCP authorization |
| **Organisational roles** | Server owner, host/agent owner, platform engineering, security, data steward, SRE | Your organisation — MCP says nothing, which is exactly why it is on you |

Confusing the first two is the single most common conceptual error: **the MCP server is an OAuth *Resource Server*, never an Authorization Server by default, and the MCP client is the *OAuth client*, not the resource owner.**

---

## 2. Protocol roles: normative responsibilities

### 2.1 The three participants

```
┌──────────────────────── Host process (trust anchor) ─────────────────────────┐
│                                                                              │
│   User consent UI · conversation state · LLM access · credential storage     │
│                                                                              │
│   ┌────────────┐      ┌────────────┐      ┌────────────┐                     │
│   │  Client A  │      │  Client B  │      │  Client C  │   1 client : 1 server│
│   └─────┬──────┘      └─────┬──────┘      └─────┬──────┘                     │
└─────────┼───────────────────┼───────────────────┼────────────────────────────┘
          │ stdio             │ Streamable HTTP   │ Streamable HTTP
          ▼                   ▼                   ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │ Server:     │     │ Server:     │     │ Server:     │
   │ filesystem  │     │ ticketing   │     │ finance     │
   │ (local)     │     │ (remote)    │     │ (remote)    │
   └─────────────┘     └──────┬──────┘     └──────┬──────┘
                              ▼                   ▼
                        Jira REST API      ERP / ledger DB
```

**Host** — the LLM application itself (an IDE, a desktop assistant, an agent runtime). It owns the model, the conversation, the user relationship, and therefore **consent**. It instantiates and supervises clients, aggregates context across servers, and enforces the security policy that the protocol declines to encode. If your architecture diagram shows the model talking directly to a server, it is wrong.

**Client** — a connector *inside* the host, maintaining a **stateful 1:1 session with exactly one server**. It performs capability negotiation, routes JSON-RPC messages, and maintains the isolation boundary: a client must not leak one server's context into another's session. This 1:1 property is why "the client" is not a shared singleton and why per-server credentials are natural rather than awkward.

**Server** — exposes capabilities through three server-side primitives, and consumes three client-side ones:

| Primitive | Direction | Controlled by | Typical production owner |
|---|---|---|---|
| **Tools** | server → client (`tools/list`, `tools/call`) | model-controlled, host-gated | Domain/service team |
| **Resources** | server → client (`resources/list`, `resources/read`) | application-controlled | Data steward |
| **Prompts** | server → client (`prompts/list`, `prompts/get`) | user-controlled | Domain team + UX |
| **Sampling** | server → client request (`sampling/createMessage`) | host-controlled, human-gated | Host/agent team |
| **Roots** | client → server (`roots/list`) | client-controlled | Host/agent team |
| **Elicitation** | server → client request (`elicitation/create`) | host-controlled, user-answered | Host/agent team |

The control column is the examinable content. *Model-controlled* means the LLM decides when to invoke; *application-controlled* means the host decides what to attach; *user-controlled* means a human explicitly selects it. Sampling and elicitation invert the usual direction — the **server asks the client for something** — and both are gated by the host, never auto-approved. A server that depends on sampling being granted is a server that will fail against hosts which do not implement it, which is why you must read the negotiated capabilities rather than assume.

### 2.2 Who owes what — the normative duty table

| Duty | Host | Client | Server | Notes |
|---|:--:|:--:|:--:|:--:|
| Obtain explicit user consent before tool invocation | **MUST** | — | — | Spec assigns consent to the host UI |
| Present tool descriptions as **untrusted** unless the server is trusted | **MUST** | — | — | Tool-poisoning defence |
| Maintain 1:1 session, isolate server contexts | — | **MUST** | — | No cross-server context bleed |
| Negotiate `protocolVersion` and capabilities in `initialize` | — | **MUST** | **MUST** | Never hardcode a version |
| Send `MCP-Protocol-Version` header on every subsequent HTTP request | — | **MUST** | validates | HTTP transport only |
| Validate that a bearer token's audience is **this** server | — | — | **MUST** | Anti-confused-deputy |
| Never forward a received token upstream ("token passthrough") | — | — | **MUST NOT** | Explicitly forbidden |
| Validate `Origin` on HTTP; bind local listeners to `127.0.0.1` | — | — | **MUST** | DNS-rebinding defence |
| Use cryptographically secure, non-deterministic session IDs | — | — | **MUST** | Bind to user identity: `<user>:<random>` |
| Obtain human approval before honouring `sampling/createMessage` | **SHOULD** | — | — | Human in the loop |
| Declare tool side effects via annotations | — | — | **SHOULD** | Hints, *not* security controls |
| Treat tool annotations as untrusted hints | **MUST** | — | — | A hostile server can lie |

The last two rows deserve emphasis because they look contradictory and are not. `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint` are **advisory metadata a server is responsible for publishing honestly**, and which a host is **responsible for never trusting as a security boundary**. Annotations drive UX (how loud is the confirmation dialog); authorization drives security (does this token carry `finance:write`).

### 2.3 The handshake is where responsibility is declared

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "roots": { "listChanged": true },
      "sampling": {},
      "elicitation": {}
    },
    "clientInfo": {
      "name": "acme-agent-runtime",
      "title": "ACME Agent Runtime",
      "version": "4.2.1"
    }
  }
}
```

The server replies with the version it will actually speak — which may differ from the one requested — plus its own capabilities and an optional `instructions` string. If the client cannot support the returned version, **the client's responsibility is to disconnect**, not to proceed optimistically.

```
$ curl -sS -X POST https://mcp.acme.internal/finance/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${MCP_ACCESS_TOKEN}" \
    -d @initialize.json -D - | sed -n '1,30p'
HTTP/2 200
content-type: application/json
mcp-session-id: 7f3c1a9e4b8d2f60a1c5e7d9b3f1a842
mcp-protocol-version: 2025-06-18

{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18",
"capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true,
"listChanged":true},"prompts":{"listChanged":false},"logging":{}},
"serverInfo":{"name":"com.acme/finance","title":"ACME Finance","version":"1.8.0"},
"instructions":"Read-only ledger queries are unrestricted. Write tools require
an approved change ticket referenced in the `ticket` argument."}}
```

Three operational facts fall out of that response and each maps to an owner:

1. `mcp-session-id` is returned → the server is **stateful**; the platform team now owns session affinity, session expiry (`404` on an expired ID, to which the client must respond by re-initializing), and the `DELETE` termination path.
2. `resources.subscribe: true` → the server owes `notifications/resources/updated`; the SRE owns the long-lived SSE stream's idle timeouts at every proxy hop.
3. `instructions` is server-authored text injected into model context → the **security team** owns reviewing it, because it is a prompt-injection surface signed by nobody.

And the unauthenticated case, which is the shape every MCP resource server must produce:

```
$ curl -sS -i -X POST https://mcp.acme.internal/finance/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d @initialize.json | head -8
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://mcp.acme.internal/finance/.well-known/oauth-protected-resource"
content-type: application/json

{"error":"invalid_token","error_description":"missing bearer token"}

$ curl -sS https://mcp.acme.internal/finance/.well-known/oauth-protected-resource | jq .
```

```json
{
  "resource": "https://mcp.acme.internal/finance/mcp",
  "authorization_servers": [
    "https://login.acme.com/realms/workforce"
  ],
  "bearer_methods_supported": [
    "header"
  ],
  "scopes_supported": [
    "finance:read",
    "finance:write"
  ],
  "resource_documentation": "https://backstage.acme.com/catalog/default/component/mcp-finance"
}
```

That document is the machine-readable statement of the role split: *this* server is a resource server, *that* IdP is the authorization server, and the client must request a token whose audience (`resource` parameter, RFC 8707) is this canonical URI. A platform that does not publish it forces every client into hardcoded IdP configuration — the adoption anti-pattern that guarantees you can never rotate an IdP.

---

## 3. Organisational roles: the RACI that has to exist before the second server ships

Protocol roles are assigned by the specification. Organisational roles are not, and the absence is felt around the third or fourth server, when the question "may this host call this tool?" stops having an obvious answer.

| Responsibility | Server owner (domain team) | Host/agent owner | Platform engineering | Security / IAM | Data steward | SRE on-call |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Tool naming, schemas, `outputSchema` | **R/A** | C | C | I | C | I |
| Honest tool annotations | **R/A** | C | I | C | I | I |
| Upstream credential custody (server → ERP) | **R/A** | I | C | **C** | C | I |
| Token audience validation | **R** | I | C | **A** | I | I |
| Scope definition and mapping to tools | C | C | C | **R/A** | C | I |
| Consent UX and approval dialogs | I | **R/A** | C | C | I | I |
| Which servers a host may connect to (allow-list) | I | C | **R** | **A** | I | I |
| Resource exposure / classification review | C | I | I | C | **R/A** | I |
| Runtime: gateway, TLS, mTLS, network policy | I | I | **R/A** | C | I | C |
| Registry / catalog entry accuracy | **R** | I | **A** | I | C | I |
| SLOs, dashboards, alert routing | C | C | **R** | I | I | **A** |
| Deprecating or renaming a tool | **R** | **C** | **A** | I | I | I |
| Incident command for a tool-caused data incident | C | C | C | **A** | C | **R** |

R = responsible, A = accountable, C = consulted, I = informed.

Two cells are load-bearing and worth defending in a design review:

**Token audience validation is accountable to security, responsible to the server team.** The server team writes the five lines of JWT validation; security owns the standard those five lines must meet, and owns the audit that proves every server does it. Split it the other way and you get twelve servers with twelve interpretations of "validate the token".

**Tool deprecation is accountable to platform, not to the server owner.** This is counter-intuitive and it is the most expensive lesson in MCP adoption. Renaming `search_tickets` to `tickets_search` is, for a normal REST API, a versioning problem with a compatibility window. For MCP it is worse: agent prompts, evaluation suites, and cached tool-selection behaviour all key on the *name and description text*. A rename silently degrades tool-selection accuracy across every host, with no 404 to alert on. The platform team owns the change window because only they can see all consumers.

### 3.1 Encoding ownership so it survives the people who wrote it

Ownership that lives in a wiki decays. Put it in the admission controller.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-mcp-server-ownership
  annotations:
    policies.kyverno.io/title: "Require ownership metadata on MCP servers"
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Every workload labelled as an MCP server must declare an owning team, a
      data classification and a registry identity. Unowned servers cannot be
      paged on, reviewed or deprecated.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: ownership-labels-present
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
              selector:
                matchLabels:
                  app.kubernetes.io/component: mcp-server
      validate:
        message: >-
          MCP server workloads require the labels acme.com/owner,
          acme.com/data-classification and acme.com/mcp-name.
        pattern:
          metadata:
            labels:
              acme.com/owner: "?*"
              acme.com/data-classification: "public | internal | confidential | restricted"
              acme.com/mcp-name: "?*"
    - name: write-tools-need-security-review
      match:
        any:
          - resources:
              kinds:
                - Deployment
              selector:
                matchLabels:
                  acme.com/mcp-has-write-tools: "true"
      validate:
        message: >-
          Servers exposing write-capable tools must record an approved security
          review in the annotation acme.com/security-review.
        pattern:
          metadata:
            annotations:
              acme.com/security-review: "SEC-*"
```

Note the quoting discipline: `"?*"` and `"SEC-*"` are quoted because a bare leading `*` is a YAML alias; `"public | internal | ..."` is a Kyverno *anyPattern* alternation, quoted so YAML does not have to guess.

---

## 4. Adoption topologies and their trade-offs

The question "where do MCP servers run" is really "who is accountable when one misbehaves". Four topologies, ordered by increasing centralisation of responsibility:

| | **A. Local stdio** | **B. Remote per-team** | **C. Central gateway** | **D. Sidecar per host** |
|---|---|---|---|---|
| Transport | stdio | Streamable HTTP | Streamable HTTP | stdio or loopback HTTP |
| Runs where | End-user machine | Team's namespace | Platform namespace, fronts N servers | Same pod as the host/agent |
| AuthN to server | Process trust (parent owns env) | OAuth 2.1 bearer, audience-bound | OAuth at the edge, mTLS inward | Pod identity |
| Credential custody | **User's own machine** | Team's secret store | Platform's secret store | Workload identity (SPIFFE/IRSA) |
| Blast radius of a bad tool | One user | One team's consumers | **Every consumer** | One agent instance |
| Central policy enforcement | None — client-side only | Per-namespace | **Strong** | Per-deployment |
| Observability | Local logs, hard to aggregate | Per-service | **Single choke point** | Per-pod |
| Tool-name collisions | Host must namespace | Registry namespacing | Gateway rewrites | Host must namespace |
| Latency | Lowest (no network) | +1 hop | +2 hops | Lowest |
| Fits | Dev laptops, filesystem/git | Default for internal domains | Regulated / partner-facing | High-security agents, no shared state |
| Main failure mode | "Works on my machine", unreviewable config | N ad-hoc auth implementations | Gateway is a SPOF and a policy bottleneck | Version sprawl, N copies to patch |

The honest recommendation for a platform team: **B as the default, C as an overlay for anything crossing a trust boundary, A only for genuinely local capabilities (filesystem, local git checkout) where moving the server would defeat the point.** D is correct when the agent must not share a session store with anything else, and is otherwise an operational tax.

A second decision, orthogonal and frequently botched — **tool exposure strategy**:

| Strategy | Tools visible to model | Selection accuracy | Ownership cost | When |
|---|---|---|---|---|
| Expose everything | 200+ | Degrades sharply | Low | Never past pilot |
| Per-host allow-list | 15–40 | Good | Medium — host team curates | Default |
| Task-scoped dynamic loading | 5–15 | Best | High — needs a router | Large tool estates |
| Gateway-side filtering by scope | Varies by token | Good | Medium — one place | Multi-tenant |

Tool count is a *context budget* problem, not just a UX one: every tool definition consumes context on every turn and every near-duplicate description raises mis-selection probability. Deciding who owns the allow-list — host team, with platform veto — is part of this objective.

---

## 5. Reference deployment: a remote MCP server with ownership encoded end to end

### 5.1 Namespace, identity, configuration

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-finance
  labels:
    acme.com/owner: team-finance-platform
    acme.com/data-classification: confidential
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-finance
  namespace: mcp-finance
  annotations:
    acme.com/purpose: "Workload identity for the finance MCP server; grants ERP read/write via OIDC federation"
automountServiceAccountToken: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-finance-config
  namespace: mcp-finance
data:
  MCP_SERVER_NAME: com.acme/finance
  MCP_CANONICAL_RESOURCE: "https://mcp.acme.internal/finance/mcp"
  MCP_AUTH_ISSUER: "https://login.acme.com/realms/workforce"
  MCP_AUTH_JWKS_URI: "https://login.acme.com/realms/workforce/protocol/openid-connect/certs"
  MCP_REQUIRED_SCOPES_READ: finance:read
  MCP_REQUIRED_SCOPES_WRITE: finance:write
  MCP_SESSION_TTL_SECONDS: "3600"
  MCP_LOG_LEVEL: info
  MCP_ALLOWED_ORIGINS: "https://agents.acme.com,https://ide.acme.com"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
  OTEL_SERVICE_NAME: mcp-finance
```

`MCP_CANONICAL_RESOURCE` is not decoration. It is the value the server compares the `aud` claim against, and the value clients must send as the RFC 8707 `resource` parameter. One string, three systems, one owner.

### 5.2 Workload

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-finance
  namespace: mcp-finance
  labels:
    app.kubernetes.io/name: mcp-finance
    app.kubernetes.io/component: mcp-server
    app.kubernetes.io/version: 1.8.0
    acme.com/owner: team-finance-platform
    acme.com/data-classification: confidential
    acme.com/mcp-name: com.acme.finance
    acme.com/mcp-has-write-tools: "true"
  annotations:
    acme.com/security-review: SEC-2026-0418
    acme.com/oncall-rotation: "https://acme.pagerduty.com/schedules/PFINPLT"
    acme.com/runbook: "https://backstage.acme.com/docs/default/component/mcp-finance/runbook"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-finance
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-finance
        app.kubernetes.io/component: mcp-server
        acme.com/owner: team-finance-platform
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: mcp-finance
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-finance
      containers:
        - name: server
          image: registry.acme.com/mcp/finance:1.8.0@sha256:9c1b5e2f7a4d08b36e5f1c9a2d4b7e08f3a6c1d9b2e5f8a0c3d6b9e2f5a8c1d4
          imagePullPolicy: IfNotPresent
          args:
            - --transport=streamable-http
            - --path=/mcp
            - --port=8080
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          envFrom:
            - configMapRef:
                name: mcp-finance-config
          env:
            - name: ERP_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: mcp-finance-upstream
                  key: erp_client_id
            - name: ERP_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: mcp-finance-upstream
                  key: erp_client_secret
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 150m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 3
            failureThreshold: 20
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
      terminationGracePeriodSeconds: 45
```

`maxUnavailable: 0` and a 45-second grace period are deliberate: Streamable HTTP sessions are stateful and SSE streams are long-lived, so a rollout that evicts a pod mid-stream produces client-visible `404 session not found`. The server owner is responsible for draining; the SRE is accountable for noticing when they do not.

### 5.3 Service, exposure, and the network boundary

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mcp-finance
  namespace: mcp-finance
  labels:
    app.kubernetes.io/name: mcp-finance
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mcp-finance
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
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-finance
  namespace: mcp-finance
spec:
  parentRefs:
    - name: acme-internal
      namespace: platform-gateway
      sectionName: https
  hostnames:
    - "mcp.acme.internal"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /finance/mcp
        - path:
            type: Exact
            value: /finance/.well-known/oauth-protected-resource
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              - name: Cache-Control
                value: "no-store"
      backendRefs:
        - name: mcp-finance
          port: 8080
          weight: 100
      timeouts:
        request: 0s
        backendRequest: 0s
      sessionPersistence:
        sessionName: Mcp-Session-Id
        type: Header
        absoluteTimeout: 3600s
```

`request: 0s` disables the gateway request timeout — mandatory for SSE, and the single most common cause of "the server works with curl but streams die after 60 seconds behind the ingress". `sessionPersistence` keyed on `Mcp-Session-Id` is what makes a replicated stateful server viable without a shared session store.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mcp-finance-default-deny
  namespace: mcp-finance
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mcp-finance-allow
  namespace: mcp-finance
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-finance
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: platform-gateway
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
          podSelector:
            matchLabels:
              k8s-app: kube-dns
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
          port: 443
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 4317
```

The egress `ipBlock` is the ERP. This is the platform team's mechanical answer to "prove the finance MCP server cannot reach the HR database" — a question the security team will ask, and which no amount of application-level code review answers as convincingly.

### 5.4 SLOs and alert routing — responsibility that pages

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-finance-slo
  namespace: mcp-finance
  labels:
    prometheus: platform
    role: alert-rules
spec:
  groups:
    - name: mcp-finance.rules
      interval: 30s
      rules:
        - alert: MCPToolErrorRateHigh
          expr: |
            sum by (mcp_server, tool) (rate(mcp_tool_calls_total{mcp_server="com.acme.finance",outcome="error"}[5m]))
            /
            sum by (mcp_server, tool) (rate(mcp_tool_calls_total{mcp_server="com.acme.finance"}[5m]))
            > 0.05
          for: 10m
          labels:
            severity: page
            owner: team-finance-platform
            routing_key: PFINPLT
          annotations:
            summary: "Tool {{ $labels.tool }} error rate above 5% on {{ $labels.mcp_server }}"
            description: >-
              More than 5% of calls to this tool have failed for 10 minutes.
              Check upstream ERP availability before blaming the transport.
            runbook_url: "https://backstage.acme.com/docs/default/component/mcp-finance/runbook#tool-errors"
        - alert: MCPUnauthorizedSpike
          expr: |
            sum by (mcp_server) (rate(mcp_http_responses_total{mcp_server="com.acme.finance",code="401"}[5m]))
            >
            10
          for: 5m
          labels:
            severity: page
            owner: platform-security
            routing_key: PSECOPS
          annotations:
            summary: "Sustained 401 rate on {{ $labels.mcp_server }}"
            description: >-
              Either an IdP key rotation invalidated live tokens, or a client is
              presenting tokens minted for a different audience. Compare the aud
              claim in rejected tokens against MCP_CANONICAL_RESOURCE.
            runbook_url: "https://backstage.acme.com/docs/default/component/mcp-finance/runbook#auth"
        - alert: MCPSessionChurnHigh
          expr: |
            sum by (mcp_server) (rate(mcp_sessions_terminated_total{reason="expired"}[10m]))
            >
            sum by (mcp_server) (rate(mcp_sessions_created_total[10m])) * 0.5
          for: 15m
          labels:
            severity: ticket
            owner: team-finance-platform
          annotations:
            summary: "More than half of {{ $labels.mcp_server }} sessions expire rather than close"
            description: >-
              Clients are abandoning sessions without DELETE, or the gateway is
              dropping SSE streams. Verify HTTPRoute timeouts are 0s.
```

Every alert carries an `owner` label and a distinct `routing_key`. `MCPUnauthorizedSpike` pages **security**, not the domain team, because its two causes — IdP rotation and audience mismatch — are both security-owned. Encoding that in the label is how a RACI table stops being a document and becomes behaviour at 03:00.

---

## 6. Publishing and discovery: the registry as the ownership ledger

Adoption fails quietly when discovery is informal. A developer copies an `mcp.json` snippet from a colleague, that snippet pins an old package version, and six months later nobody knows how many hosts are running it.

The MCP ecosystem's answer is the **registry**: a metadata catalog where a server is published under a **namespaced name** whose prefix must be proven. `io.github.<user>/<server>` is proven by GitHub OAuth; `com.acme/<server>` is proven by DNS or HTTP challenge on `acme.com`. That namespace authentication *is* the responsibility mechanism — the name asserts who stands behind the server, and it cannot be forged.

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-07-09/server.schema.json",
  "name": "com.acme/finance",
  "description": "Read and post entries against the ACME general ledger, with change-ticket enforcement on writes.",
  "version": "1.8.0",
  "websiteUrl": "https://backstage.acme.com/catalog/default/component/mcp-finance",
  "repository": {
    "url": "https://github.com/acme/mcp-finance",
    "source": "github"
  },
  "remotes": [
    {
      "type": "streamable-http",
      "url": "https://mcp.acme.internal/finance/mcp",
      "headers": [
        {
          "name": "Authorization",
          "description": "Bearer token issued by login.acme.com with audience https://mcp.acme.internal/finance/mcp",
          "isRequired": true,
          "isSecret": true
        }
      ]
    }
  ],
  "packages": [
    {
      "registryType": "oci",
      "identifier": "registry.acme.com/mcp/finance",
      "version": "1.8.0",
      "transport": {
        "type": "streamable-http",
        "url": "http://localhost:8080/mcp"
      }
    }
  ]
}
```

Confirm the current `$schema` revision against the registry documentation before publishing; the registry pins a dated schema and rejects entries validated against a stale one.

```
$ mcp-publisher login dns --domain acme.com --private-key "${MCP_NS_KEY}"
✓ Resolving _mcp-registry.acme.com TXT
✓ Signature verified for namespace com.acme
✓ Token stored in ~/.mcp-publisher/credentials (expires in 1h)

$ mcp-publisher publish
✓ server.json validated against schema 2025-07-09
✓ Namespace com.acme authorized
✓ Published com.acme/finance@1.8.0
  id:        0199f4a1-3c7e-7b21-9d08-5c2e1b4a6f30
  status:    active
  published: 2026-09-17T09:14:22Z

$ curl -sS "https://registry.modelcontextprotocol.io/v0/servers?search=com.acme" \
    | jq -r '.servers[] | [.name, .version, .status] | @tsv'
com.acme/finance        1.8.0   active
com.acme/ticketing      2.3.1   active
com.acme/observability  0.9.4   deprecated
```

For internal estates, run a **private registry** and mirror only vetted public entries into it. The complement is a **software catalog** entry that ties the server to a team, a rotation and a lifecycle stage — ownership that an SRE can query during an incident:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: mcp-finance
  title: Finance MCP Server
  description: "MCP server exposing general-ledger read and write tools to approved agent hosts."
  annotations:
    backstage.io/kubernetes-id: mcp-finance
    pagerduty.com/service-id: PFINPLT
    acme.com/mcp-registry-name: com.acme/finance
    acme.com/mcp-canonical-resource: "https://mcp.acme.internal/finance/mcp"
  tags:
    - mcp-server
    - confidential
    - write-capable
  links:
    - url: "https://backstage.acme.com/docs/default/component/mcp-finance/runbook"
      title: Runbook
      icon: docs
spec:
  type: mcp-server
  lifecycle: production
  owner: group:default/team-finance-platform
  system: system:default/agent-platform
  providesApis:
    - mcp-finance-tools
  dependsOn:
    - component:default/erp-ledger-api
```

And the host-side configuration that consumes it — note that the host stores *no long-lived secret*; it holds an OAuth client registration and obtains audience-bound tokens at connect time:

```json
{
  "mcpServers": {
    "finance": {
      "type": "http",
      "url": "https://mcp.acme.internal/finance/mcp",
      "authorization": {
        "type": "oauth2",
        "resource": "https://mcp.acme.internal/finance/mcp",
        "scopes": ["finance:read"]
      },
      "toolAllowList": [
        "list_accounts",
        "get_trial_balance",
        "search_journal_entries"
      ],
      "requireApproval": "always"
    },
    "ticketing": {
      "type": "http",
      "url": "https://mcp.acme.internal/ticketing/mcp",
      "authorization": {
        "type": "oauth2",
        "resource": "https://mcp.acme.internal/ticketing/mcp",
        "scopes": ["tickets:read", "tickets:write"]
      },
      "requireApproval": "onWrite"
    }
  }
}
```

Exact key names vary by host implementation; read your host's documentation. The architecture does not: **allow-list and approval policy are host-side configuration, owned by the host team, and are the enforcement point the server cannot provide.** Requesting only `finance:read` here is the host team exercising least privilege even though the server supports writes — the scope you *do not* request is as much a design decision as the one you do.

### 6.1 Ownership in the repository, not only the cluster

```
# CODEOWNERS — MCP finance server
# Tool surface changes require both the domain team and the platform reviewers,
# because renaming or removing a tool breaks agents with no HTTP error to alert on.

*                              @acme/team-finance-platform
/src/tools/                    @acme/team-finance-platform @acme/agent-platform-reviewers
/src/tools/write/              @acme/team-finance-platform @acme/platform-security
/server.json                   @acme/agent-platform-reviewers
/deploy/networkpolicy.yaml     @acme/platform-security
/docs/runbook.md               @acme/team-finance-platform @acme/sre-agent-platform
```

---

## 7. Verification and failure diagnosis

### 7.1 The verification ladder

Run these in order. Each rung assumes the one below it passed; skipping rungs is how a transport problem gets misdiagnosed as a model problem.

**Rung 0 — the workload is healthy**

```
$ kubectl -n mcp-finance rollout status deploy/mcp-finance --timeout=120s
deployment "mcp-finance" successfully rolled out

$ kubectl -n mcp-finance get pods -l app.kubernetes.io/name=mcp-finance -o wide
NAME                           READY   STATUS    RESTARTS   AGE   IP           NODE
mcp-finance-7d4c9b8f65-2xk4p   1/1     Running   0          14m   10.42.3.71   node-a3
mcp-finance-7d4c9b8f65-9vbqn   1/1     Running   0          14m   10.42.5.18   node-b1
mcp-finance-7d4c9b8f65-lm7zt   1/1     Running   0          13m   10.42.7.44   node-c2
```

**Rung 1 — the protocol layer answers** (in-cluster, bypassing the gateway)

```
$ kubectl -n mcp-finance run mcp-probe --rm -it --restart=Never \
    --image=curlimages/curl:8.11.1 -- \
    curl -sS -X POST http://mcp-finance:8080/mcp \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H 'MCP-Protocol-Version: 2025-06-18' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"prompts":{"listChanged":false},"logging":{}},"serverInfo":{"name":"com.acme/finance","title":"ACME Finance","version":"1.8.0"}}}
pod "mcp-probe" deleted
```

**Rung 2 — the tool surface is what the registry claims**

```
$ npx -y @modelcontextprotocol/inspector --cli \
    https://mcp.acme.internal/finance/mcp \
    --transport http \
    --header "Authorization: Bearer ${MCP_ACCESS_TOKEN}" \
    --method tools/list | jq -r '.tools[] | [.name, (.annotations.readOnlyHint // false), (.annotations.destructiveHint // false)] | @tsv'
list_accounts            true    false
get_trial_balance        true    false
search_journal_entries   true    false
post_journal_entry       false   false
void_journal_entry       false   true
```

Diff that output against the previous release in CI. An unannounced change to this list is a broken contract with every host, and it is the server owner's responsibility to gate it behind a release note.

**Rung 3 — authorization actually discriminates**

```
$ MCP_READ_TOKEN=$(acme-idp token --resource https://mcp.acme.internal/finance/mcp --scope finance:read)

$ npx -y @modelcontextprotocol/inspector --cli \
    https://mcp.acme.internal/finance/mcp --transport http \
    --header "Authorization: Bearer ${MCP_READ_TOKEN}" \
    --method tools/call --tool-name post_journal_entry \
    --tool-arg account=4100 --tool-arg amount=-250.00 --tool-arg ticket=CHG-9912
{"jsonrpc":"2.0","id":3,"error":{"code":-32001,"message":"insufficient_scope","data":{"required":"finance:write","present":["finance:read"]}}}
```

A read token that can write is the finding that ends a pilot. Make this an automated conformance test, owned by security, run against every server on every release.

**Rung 4 — the audience boundary holds** (the confused-deputy test)

```
$ TICKETING_TOKEN=$(acme-idp token --resource https://mcp.acme.internal/ticketing/mcp --scope tickets:read)

$ curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://mcp.acme.internal/finance/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Authorization: Bearer ${TICKETING_TOKEN}" \
    -d @initialize.json
401
```

Anything other than `401` here is a **critical** finding: the finance server is accepting tokens minted for a different resource, which is precisely the condition the specification forbids.

### 7.2 Symptom → owner → probe → fix

| Symptom | Most likely cause | Accountable role | First probe | Resolution |
|---|---|---|---|---|
| `404` mid-conversation, client re-initializes in a loop | Session expired or landed on a different replica | Platform | `kubectl -n mcp-finance logs -l app... \| grep session` | Enable `sessionPersistence` on `Mcp-Session-Id`; or externalise session state |
| SSE stream dies at exactly 60 s | Gateway/proxy request timeout | Platform | `kubectl get httproute mcp-finance -o yaml` | Set `timeouts.request: 0s` and `backendRequest: 0s` |
| `401` for every client after an IdP change | Signing-key rotation; stale JWKS cache | Security | `curl $MCP_AUTH_JWKS_URI \| jq '.keys[].kid'` | Shorten JWKS cache TTL; verify `kid` present |
| `401` for one client only | Token minted for the wrong `resource` | Host team | Decode `aud` from the rejected token | Send RFC 8707 `resource` matching `MCP_CANONICAL_RESOURCE` |
| Model stops calling a tool that used to work | Tool renamed or description rewritten | Server owner (platform accountable) | Diff `tools/list` against last release | Restore the name; deprecate with an alias and a window |
| Agent picks the wrong tool as the estate grows | Too many tools / near-duplicate descriptions | Host team | Count tools in the negotiated surface | Per-host allow-list; sharpen descriptions; task-scoped loading |
| `-32601 Method not found` on `sampling/createMessage` | Host did not declare the `sampling` capability | Host team | Inspect `initialize` params | Declare the capability, or make the server degrade gracefully |
| Server reaches a system it should not | Missing or over-broad NetworkPolicy | Platform / security | `kubectl -n mcp-finance get netpol` | Default-deny plus an explicit egress `ipBlock` |
| Upstream logs show one identity for all users | Token passthrough / shared service credential | Security | Read upstream access log principals | Exchange for a per-user upstream token; never replay the inbound one |
| Nobody can say who owns a server | No registry or catalog entry | Platform | Query the registry by name | Enforce the ownership admission policy; backfill catalog entries |

### 7.3 A worked diagnosis

Symptom: `post_journal_entry` intermittently returns `-32603` while `get_trial_balance` is unaffected.

```
$ kubectl -n mcp-finance logs -l app.kubernetes.io/name=mcp-finance --since=15m \
    | grep -E 'tool=(post_journal_entry)' | tail -5
2026-09-17T09:41:02Z WARN  tool=post_journal_entry session=7f3c…a842 upstream=erp status=429 retry_after=30 msg="upstream throttled"
2026-09-17T09:41:33Z WARN  tool=post_journal_entry session=91be…2c07 upstream=erp status=429 retry_after=30 msg="upstream throttled"
2026-09-17T09:41:35Z ERROR tool=post_journal_entry session=91be…2c07 code=-32603 msg="internal error" cause="upstream rate limit exceeded"

$ kubectl -n mcp-finance exec deploy/mcp-finance -- \
    wget -qO- http://localhost:9090/metrics | grep -E '^mcp_tool_calls_total'
mcp_tool_calls_total{tool="get_trial_balance",outcome="ok"} 18422
mcp_tool_calls_total{tool="post_journal_entry",outcome="ok"} 2910
mcp_tool_calls_total{tool="post_journal_entry",outcome="error"} 418
```

Read-only traffic is healthy; the write path is throttled upstream. Three separate responsibilities follow, and assigning them correctly is the whole point:

* **Server owner** — the server is mapping a `429` to `-32603` ("internal error"), which tells the model nothing actionable and invites an immediate retry storm. Return a structured tool error with `isError: true` and a retry hint, so the model can back off or tell the user.
* **Host team** — the agent is retrying immediately on failure. Add backoff to the tool-invocation loop.
* **Platform** — no per-host rate limit exists at the gateway, so one misbehaving agent exhausts the shared ERP budget for everyone. Add one.

Note that *none* of the three fixes is "raise the ERP quota". That is the reflex answer, and it is the one that lets the same incident recur at a higher volume.

---

## 8. Adoption: a staged rollout with explicit exit criteria

| Stage | Duration | Who is accountable | Exit criteria |
|---|---|---|---|
| **0 — Evaluate** | 2–4 weeks | Architecture | Spec revision pinned; transport decision made; one throwaway server built and discarded |
| **1 — Pilot** | 4–8 weeks | One volunteer domain team | 1 read-only remote server; OAuth working end to end; audience test passes; runbook exists |
| **2 — Golden path** | 4–8 weeks | Platform | Scaffold template, CI conformance suite, private registry, admission policy enforcing ownership, dashboards by default |
| **3 — Scale out** | Ongoing | Domain teams, platform-enabled | ≥ 5 servers on the golden path with zero bespoke auth code; per-host allow-lists in force |
| **4 — Write capability** | Gated | Security | Scope separation verified; approval UX reviewed; audit log correlating user → host → tool → upstream change |
| **5 — Third-party / partner** | Gated | Security + legal | Egress-controlled; tool descriptions reviewed as untrusted input; supply-chain policy for external servers |

Anti-patterns that reliably cost a quarter:

1. **Starting at stage 4.** Write tools before audit correlation means the first incident is unanswerable.
2. **One giant server per team.** Sixty tools in one process is one blast radius, one deploy cadence, one scope. Split by data classification, not by org chart.
3. **Adopting third-party servers with no review.** A server's tool descriptions and `instructions` string enter model context. That is an untrusted input channel with the trust level of a dependency you `npm install`ed — pin, review, and mirror.
4. **Treating annotations as authorization.** `readOnlyHint: true` is a claim by the server. Scopes are a claim by your IdP. Only one of them is enforceable.
5. **No deprecation policy.** The first tool rename without a window teaches every team that the tool surface is not a contract.

### 8.1 Adoption metrics that mean something

| Metric | Why it is the right one | Owner |
|---|---|---|
| Servers on the golden-path template / total servers | Measures platform leverage, not activity | Platform |
| Median time from `git init` to a registered, authenticated server | The real adoption barrier | Platform |
| % of servers with an owner label and a runbook link | Operability floor | Platform |
| Tool-selection accuracy on the host's eval suite | Detects estate bloat before users do | Host team |
| % of tool calls with a complete user → host → tool → upstream audit trail | Regulatory readiness | Security |
| Count of servers accepting non-audience-bound tokens | Should be zero, forever | Security |

Counting servers is not an adoption metric; it is an inventory. A platform with forty unowned servers is in a worse position than one with six owned ones.

---

## 9. Exam-focused summary

* **Host owns consent, the model, and the trust anchor.** Client owns one isolated session with one server. Server owns capabilities and its own upstream credentials.
* **The MCP server is an OAuth Resource Server.** It validates that the token's audience is itself, and **must not** forward that token upstream.
* Tools are model-controlled, resources are application-controlled, prompts are user-controlled. Sampling, roots and elicitation flow the other way and are host-controlled.
* **Tool annotations are untrusted hints.** Hosts must treat descriptions and annotations from untrusted servers as adversarial input.
* Capability negotiation happens once, in `initialize`; the negotiated `protocolVersion` is a date string and must never be hardcoded. Over HTTP, subsequent requests carry `MCP-Protocol-Version`.
* Registry namespaces (`io.github.*`, `com.example/*`) are proven, not claimed — that proof is the ecosystem's ownership mechanism.
* Organisational role assignment is not in the specification. That is deliberate, and it means an MCP deployment without an explicit RACI has an undefined answer to every incident question.

---

## References

- Model Context Protocol Associate (MCPA) — certification overview, domains and weights: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
- MCP specification index and revision list: https://modelcontextprotocol.io/specification
- MCP architecture — hosts, clients, servers and their responsibilities: https://modelcontextprotocol.io/docs/learn/architecture
- MCP security best practices — confused deputy, token passthrough, session hijacking: https://modelcontextprotocol.io/specification/draft/basic/security_best_practices
- MCP authorization specification: https://modelcontextprotocol.io/specification/draft/basic/authorization
- MCP transports — stdio and Streamable HTTP: https://modelcontextprotocol.io/specification/draft/basic/transports
- MCP server concepts — tools, resources, prompts: https://modelcontextprotocol.io/docs/learn/server-concepts
- MCP client concepts — sampling, roots, elicitation: https://modelcontextprotocol.io/docs/learn/client-concepts
- MCP Registry — publishing, namespace authentication, `server.json`: https://github.com/modelcontextprotocol/registry
- MCP Inspector — interactive and CLI testing: https://github.com/modelcontextprotocol/inspector
- JSON-RPC 2.0 specification: https://www.jsonrpc.org/specification
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://datatracker.ietf.org/doc/html/rfc9728
- RFC 8707 — Resource Indicators for OAuth 2.0: https://datatracker.ietf.org/doc/html/rfc8707
- RFC 7591 — OAuth 2.0 Dynamic Client Registration: https://datatracker.ietf.org/doc/html/rfc7591
- OAuth 2.1 draft: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- Kubernetes Gateway API — HTTPRoute timeouts and session persistence: https://gateway-api.sigs.k8s.io/api-types/httproute/
- Kubernetes Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kyverno policy documentation: https://kyverno.io/docs/writing-policies/
- Prometheus Operator — PrometheusRule CRD: https://prometheus-operator.dev/docs/api-reference/api/
- Backstage software catalog — `catalog-info.yaml` descriptor format: https://backstage.io/docs/features/software-catalog/descriptor-format