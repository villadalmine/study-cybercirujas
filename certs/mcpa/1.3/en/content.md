# 1.3 Interoperability & Value

> **Exam weight: 5.33.** This objective is not about writing an MCP server — it is about being able to argue, in front of an architecture review board, *why* a protocol boundary belongs between an agent and its context sources, and *what it costs you* when that boundary is drawn badly. Everything below is written from the operator's seat: what breaks in production, what you measure, and what you type when it breaks.

---

## 1. The production problem: the M×N integration matrix

### 1.1 The shape of the pain

A platform team at a mid-size company typically ends up with several *agent surfaces* — a desktop assistant, a coding agent in the IDE, a CI remediation bot, a Slack responder, an internal RAG application, a customer-facing support agent. Call that **M**.

That same company has internal systems the agent must read or act on — the incident tracker, the CMDB, the observability backend, the feature-flag service, the runbook wiki, Kubernetes itself, the billing ledger, the on-call schedule. Call that **N**.

Without a protocol boundary, the integration cost is **M × N**. Each surface re-implements each system: its own auth handling, its own pagination, its own schema dialect, its own error mapping, its own retry policy, its own redaction rules.

```
             Incident   CMDB   Metrics   Flags   Runbooks   K8s
Desktop         A1       A2      A3       A4       A5       A6
IDE agent       B1       B2      B3       B4       B5       B6
CI bot          C1       C2      C3       C4       C5       C6
Slack bot       D1       D2      D3       D4       D5       D6
Support agent   E1       E2      E3       E4       E5       E6

30 adapters. 30 places a credential lives. 30 audit gaps.
```

The failure mode is not that the adapters are hard to write — an adapter is a weekend. The failure mode is **operational**:

| Consequence | Concrete manifestation |
|---|---|
| Credential sprawl | The CMDB token exists in 5 different secret stores, rotated at 5 different cadences. One of them is in a developer's `~/.config`. |
| Divergent behaviour | The IDE agent's `search_incidents` paginates at 50; the Slack bot's paginates at 20 and silently truncates. The same question yields different answers depending on the surface. |
| No single audit point | "Which agent read customer 4471's billing record on Tuesday?" requires correlating 5 log formats. |
| Ownership ambiguity | The adapter is owned by the agent team, but it breaks when the *platform* team changes the CMDB API. Neither is on call for it. |
| Non-portable investment | 18 months of hardening the incident adapter is worth zero when the company adopts a sixth agent surface. |

### 1.2 The reframing MCP performs

The Model Context Protocol inverts the matrix into **M + N**. A *server* exposes capabilities once, over a versioned wire format; any compliant *client* consumes them. The official documentation frames it as "a USB-C port for AI applications" — a single physical and logical contract that decouples the peripheral from the host.

```
Desktop ─┐                          ┌─ Incident server
IDE     ─┤                          ├─ CMDB server
CI bot  ─┼── MCP (JSON-RPC 2.0) ────┼─ Metrics server
Slack   ─┤                          ├─ Flags server
Support ─┘                          └─ K8s server

5 clients + 5 servers = 10 artifacts, not 25.
```

This is the *same* problem shape the Language Server Protocol solved for editors (M editors × N languages), and MCP borrows LSP's foundation deliberately: JSON-RPC 2.0 messages, an `initialize` handshake, explicit capability negotiation, and server→client notifications. If you already operate language servers, the operational model transfers almost unchanged.

### 1.3 The value argument, stated as an SRE would state it

Interoperability is not an aesthetic preference. It buys four measurable things:

1. **Amortised hardening.** Rate limiting, redaction, tenant scoping and audit logging are implemented once, in the server, and every surface inherits them. A new agent surface inherits a *hardened* integration on day one.
2. **A single enforcement point.** The server is where you put the policy: "this tool is read-only", "this tool requires a scope", "this tool never returns PII". You cannot enforce that inside N client codebases you do not own.
3. **Substitutability of the host.** If the agent framework of choice changes next year — and it will — the servers survive. The protocol boundary is the hedge against model- and vendor-churn.
4. **Bounded blast radius.** A misbehaving server degrades one capability. A misbehaving in-process adapter can take down the agent surface itself.

The cost side, stated honestly: you add a network hop (for HTTP transports) or a process boundary (for stdio), you add a version-negotiation surface that can fail, and you add a serialization tax. Sections 3 and 6 quantify both.

---

## 2. What MCP actually standardises

Interoperability is only real at the layers the specification pins down. Know exactly where the contract ends.

### 2.1 The layers

| Layer | Standardised? | Notes for the architect |
|---|---|---|
| Message envelope | **Yes** — JSON-RPC 2.0 | Requests, responses, notifications. Errors use the JSON-RPC error object. |
| Lifecycle | **Yes** — `initialize` → `notifications/initialized` → operation → shutdown | Protocol version and capabilities are agreed here and nowhere else. |
| Capability negotiation | **Yes** | A client that lacks `sampling` still works with a server that offers it; features are opt-in on both sides. |
| Server primitives | **Yes** — `tools`, `resources`, `prompts` | Model-controlled, application-controlled and user-controlled respectively. |
| Client primitives | **Yes** — `roots`, `sampling`, `elicitation` | Let the server ask the *client* for a filesystem boundary, a model completion, or user input. |
| Transports | **Yes, two** — stdio and Streamable HTTP | Custom transports are permitted; only these two are guaranteed interoperable. |
| Authorization | **Yes, for HTTP** — OAuth 2.1 based | stdio servers take credentials from the environment; the spec says so explicitly. |
| Tool *semantics* | **No** | Nothing forces your `search_incidents` to behave like anyone else's. |
| Discovery/registry | **Partially** — an official registry exists | Not required for a server to be valid. |
| Health/liveness endpoints | **No** | Purely a deployment concern. You invent `/healthz`; the spec does not. |
| Multi-tenancy model | **No** | Yours to design. See §4. |

The last four rows are where "it speaks MCP" stops being a guarantee. A conformant server can still be operationally unusable.

### 2.2 Protocol versions are dates, and negotiation can fail

Protocol revisions are date strings, not semver. The ones that matter historically:

| Revision | What interoperability gained or lost |
|---|---|
| `2024-11-05` | The original revision. stdio and HTTP+SSE transports. |
| `2025-03-26` | **Streamable HTTP** replaces the two-endpoint HTTP+SSE transport; OAuth 2.1-based authorization framework; tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`); JSON-RPC batching added. |
| `2025-06-18` | JSON-RPC **batching removed**; structured tool output (`outputSchema` + `structuredContent`); **elicitation**; servers formally classified as OAuth 2.0 Resource Servers, with Protected Resource Metadata (RFC 9728) and Resource Indicators (RFC 8707); the `MCP-Protocol-Version` header becomes required on HTTP requests after initialization. |

Later revisions exist; the specification site publishes the authoritative list and changelog per revision, and you should read the changelog of the revision your fleet pins rather than trusting any summary, including this one.

The negotiation rule you must be able to recite:

- The client sends the **latest** version it supports in `initialize`.
- If the server supports it, it echoes the same version. Agreement reached.
- If not, the server responds with a version it *does* support.
- If the client does not support the server's counter-offer, the client **SHOULD disconnect**.

This is why a fleet-wide version pin is a platform decision, not a per-team one. A server that only speaks `2025-06-18` will refuse a year-old desktop client, and the failure surfaces to the user as "the connector stopped working".

### 2.3 The context-budget dimension of interoperability

A subtle and heavily under-appreciated point, and a real production constraint: **every tool definition a client exposes is serialized into the model's context on every turn.** A tool with a rich JSON Schema costs 150–400 tokens. Mount eight servers averaging six tools each and you have spent 10–20k tokens of every request on menu, before the user has said anything.

Interoperability makes it *easy* to mount many servers. That is exactly why fleets degrade: tool-selection accuracy falls as the menu grows, names collide across servers, and latency and cost rise on every turn. The architectural answer is curation — a gateway that exposes a role-scoped subset, and `notifications/tools/list_changed` to swap the menu as the task changes. Design for this before you have twelve servers, not after.

---

## 3. Comparative analysis

### 3.1 Integration strategies

| Dimension | Bespoke per-host adapter | OpenAPI spec + native function calling | Framework tool registry (in-process) | MCP server |
|---|---|---|---|---|
| Unit of reuse | None — per host | The spec document | Per framework, per language | The running server |
| Runtime discovery | No — compiled in | Partial (spec fetched, not live) | No | **Yes** — `tools/list`, live, with `listChanged` |
| Server→client push | No | No | No | **Yes** — notifications, subscriptions, progress |
| Stateful session | Host-defined | Stateless by design | In-process | **Yes** — session lifecycle is part of the protocol |
| Human-in-the-loop primitives | Hand-rolled | None | Framework-specific | **Yes** — elicitation, sampling, roots |
| Credential location | Every host | Every host | Every host | **The server only** |
| Language coupling | Host's language | None | **Framework's language** | None — process boundary |
| Transport choice | N/A | HTTP only | In-process only | stdio **or** Streamable HTTP, swappable |
| Auth model | Ad hoc | Whatever the API uses | Ad hoc | OAuth 2.1 profile (HTTP) |
| Versioning story | None | Spec version, unenforced | Package semver | **Negotiated at handshake** |
| Ops burden | M×N components | Low, but capability-poor | Low, but non-portable | M+N components, one on-call owner each |
| Blast radius of a bug | Can crash the host | Low | Can crash the host | Isolated process/pod |
| Best fit | Never, at scale | Read-only public REST, one surface | Single-app prototype | Multi-surface production fleets |

**The honest counter-case:** if you have exactly one agent surface and three read-only REST APIs, MCP is overhead. Direct function calling against an OpenAPI spec is fewer moving parts and fewer failure modes. MCP starts paying at the second surface and dominates at the third.

### 3.2 Transports

| Dimension | stdio | Streamable HTTP |
|---|---|---|
| Topology | One server subprocess **per client** | One server, **many clients** |
| Who runs it | The end user's machine | Your platform |
| Auth | Environment / files; no protocol-level auth | OAuth 2.1, bearer tokens, mTLS at the edge |
| Horizontal scaling | N/A (process per client) | HPA, but see session affinity |
| Upgrade/rollback | Requires the user to update the binary | Deploy once, everyone gets it |
| Observability | Client-side logs; stderr only | Centralised metrics, traces, access logs |
| Latency | Lowest — no network | One hop + TLS |
| Multi-tenancy | Trivially isolated | **You must build it** |
| Secrets exposure | Credentials sit on the user's laptop | Credentials stay server-side |
| Classic failure | **stdout pollution** corrupts the stream | Session affinity lost on scale-out |
| Use when | Local filesystem/git access, air-gapped, per-user identity is the point | Shared enterprise systems, centrally governed capability |

The rule that follows: **stdio for capabilities that are intrinsically local; Streamable HTTP for capabilities that are intrinsically shared.** A CMDB server on stdio means the CMDB token is on every laptop — an interoperability win and a security regression at the same time.

### 3.3 MCP and agent-to-agent protocols

A frequent exam-adjacent confusion. They solve orthogonal problems and compose:

| | MCP | Agent-to-agent protocols (e.g. A2A) |
|---|---|---|
| Connects | An agent ↔ tools, data, prompts | An agent ↔ another **autonomous agent** |
| Counterparty | Deterministic capability provider | Opaque peer with its own model and goals |
| Unit of exchange | Tool call, resource read, prompt | Task delegation, negotiated outcome |
| Trust model | You own or vet the server | Cross-organisational, adversarial-capable |
| Relationship | **Complementary** — an A2A peer typically uses MCP internally to reach its own tools |

Say it this way in a design review: *MCP is the agent's southbound interface; agent-to-agent protocols are its east–west interface.*

### 3.4 Where interoperability actually breaks

| Hazard | Why it bites | Mitigation |
|---|---|---|
| JSON Schema dialect drift | Clients support different subsets; `$ref`, `oneOf`, `allOf` and remote refs are unevenly honoured | Keep `inputSchema` **flat, self-contained, `$ref`-free**; validate server-side regardless |
| Tool name collisions | Two servers both expose `search` | Namespace at the gateway (`incident.search`); never rely on client-side prefixing |
| Error-channel confusion | Protocol errors vs tool errors are surfaced differently | Tool failures → `isError: true` in the result; protocol violations → JSON-RPC error. See §6.3 |
| Capability assumption | Client assumes `resources/subscribe` exists | Read the `capabilities` object from `initialize`; never assume |
| Version pin skew | Old client, new server | Fleet-wide pin + `mcp_initialize_total` by `client_protocol_version` |
| Annotation trust | `readOnlyHint` is a **hint**, untrusted | Enforce read-only in the server's authz layer, not via annotations |
| Description drift | The description *is* the API for the model | Treat description changes as API changes; review them |

---

## 4. Production manifests

A single shared MCP server — `incident-context` — deployed once over Streamable HTTP and consumed by every agent surface. Complete and unabridged.

### 4.1 Namespace, service account, configuration

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: incident-context
  namespace: mcp-platform
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: incident-context-config
  namespace: mcp-platform
data:
  MCP_TRANSPORT: "http"
  MCP_HTTP_PATH: "/mcp"
  MCP_BIND_ADDRESS: "0.0.0.0:8080"
  MCP_PROTOCOL_VERSION_MIN: "2025-03-26"
  MCP_PROTOCOL_VERSION_PREFERRED: "2025-06-18"
  MCP_SESSION_MODE: "stateless"
  MCP_ALLOWED_ORIGINS: "https://agents.acme.internal,https://ide.acme.internal"
  MCP_LOG_FORMAT: "json"
  MCP_LOG_DESTINATION: "stderr"
  MCP_TOOL_TIMEOUT_SECONDS: "30"
  MCP_MAX_PAGE_SIZE: "50"
  UPSTREAM_INCIDENT_API: "https://incidents.acme.internal/api/v2"
  OAUTH_ISSUER: "https://idp.acme.internal/realms/platform"
  OAUTH_RESOURCE_IDENTIFIER: "https://mcp.acme.internal/incident-context/mcp"
```

Note `MCP_SESSION_MODE: "stateless"`. In the TypeScript SDK this corresponds to constructing `StreamableHTTPServerTransport` with `sessionIdGenerator: undefined`; the server then issues no `Mcp-Session-Id` and every POST is self-contained. This is the single highest-leverage decision for horizontal scaling — it removes the affinity requirement entirely, at the cost of losing server-side session state and resource subscriptions.

### 4.2 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: incident-context
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: incident-context
    app.kubernetes.io/component: mcp-server
    app.kubernetes.io/part-of: agent-platform
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
      app.kubernetes.io/name: incident-context
  template:
    metadata:
      labels:
        app.kubernetes.io/name: incident-context
        app.kubernetes.io/component: mcp-server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: incident-context
      automountServiceAccountToken: false
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
              app.kubernetes.io/name: incident-context
      containers:
        - name: server
          image: registry.acme.internal/mcp/incident-context:1.4.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          envFrom:
            - configMapRef:
                name: incident-context-config
          env:
            - name: UPSTREAM_INCIDENT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: incident-context-upstream
                  key: token
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              cpu: "1"
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
            timeoutSeconds: 3
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

`/healthz` and `/readyz` are **not** part of MCP. They are paths your implementation must expose alongside `/mcp`, because Kubernetes has no concept of a successful `initialize`. Do not point a probe at `/mcp`: a bare `GET` on the MCP endpoint is a legitimate SSE-stream request in the Streamable HTTP transport and may be answered with `405` by a server that does not offer server-initiated streams — which your probe would read as failure.

### 4.3 Service, disruption budget, autoscaling

```yaml
apiVersion: v1
kind: Service
metadata:
  name: incident-context
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: incident-context
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: incident-context
  ports:
    - name: http
      port: 80
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
  name: incident-context
  namespace: mcp-platform
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: incident-context
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: incident-context
  namespace: mcp-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: incident-context
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
```

### 4.4 Ingress

Two variants. Use the first with `MCP_SESSION_MODE: "stateless"`; use the second only when you genuinely need server-side sessions.

**Stateless (preferred):**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: incident-context
  namespace: mcp-platform
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-body-size: "2m"
    cert-manager.io/cluster-issuer: acme-internal-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - mcp.acme.internal
      secretName: mcp-acme-internal-tls
  rules:
    - host: mcp.acme.internal
      http:
        paths:
          - path: /incident-context
            pathType: Prefix
            backend:
              service:
                name: incident-context
                port:
                  name: http
```

**Session-affine variant** — add these annotations and set `MCP_SESSION_MODE: "stateful"`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: incident-context-affine
  namespace: mcp-platform
  annotations:
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/affinity-mode: "persistent"
    nginx.ingress.kubernetes.io/session-cookie-name: "mcp-affinity"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"
    nginx.ingress.kubernetes.io/session-cookie-path: "/incident-context"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - mcp.acme.internal
      secretName: mcp-acme-internal-tls
  rules:
    - host: mcp.acme.internal
      http:
        paths:
          - path: /incident-context
            pathType: Prefix
            backend:
              service:
                name: incident-context
                port:
                  name: http
```

`proxy-buffering: "off"` and the long read timeout are mandatory for SSE. The default 60-second read timeout is the single most common cause of "the agent hangs halfway through a long tool call".

### 4.5 Network policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: incident-context
  namespace: mcp-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: incident-context
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
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

An MCP server is an egress amplifier: it turns a model's decision into an authenticated call against internal systems. Default-deny egress, allow-list the upstreams, and never let it reach the internet unless a tool genuinely requires it.

### 4.6 Observability

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: incident-context
  namespace: mcp-platform
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: incident-context
  namespaceSelector:
    matchNames:
      - mcp-platform
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: incident-context
  namespace: mcp-platform
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp-interoperability
      rules:
        - alert: MCPHandshakeFailureRate
          expr: |
            sum by (server) (
              rate(mcp_initialize_failures_total[5m])
            )
            /
            clamp_min(
              sum by (server) (rate(mcp_initialize_total[5m])),
              0.001
            )
            > 0.01
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Protocol negotiation is failing for {{ $labels.server }}"
            description: "More than 1% of initialize calls fail. Check for a client/server protocol-version pin skew."
        - alert: MCPDeprecatedProtocolVersionInUse
          expr: |
            sum by (client_protocol_version) (
              rate(mcp_initialize_total{client_protocol_version="2024-11-05"}[30m])
            )
            > 0
          for: 1h
          labels:
            severity: info
          annotations:
            summary: "A client is still negotiating 2024-11-05"
            description: "Identify the surface and schedule its upgrade before the next server-side minimum bump."
        - alert: MCPToolErrorRatioHigh
          expr: |
            sum by (tool) (
              rate(mcp_tool_calls_total{outcome="error"}[5m])
            )
            /
            clamp_min(
              sum by (tool) (rate(mcp_tool_calls_total[5m])),
              0.001
            )
            > 0.20
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Tool {{ $labels.tool }} is failing for more than 20% of calls"
        - alert: MCPSessionNotFoundSpike
          expr: |
            sum by (server) (
              rate(mcp_http_responses_total{status="404"}[5m])
            )
            > 0.5
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Sessions are being lost on {{ $labels.server }}"
            description: "Typically a scale event with broken affinity. Consider stateless mode."
```

### 4.7 Client-side configuration — the same server, three surfaces

The whole point of the objective: one deployment, consumed unchanged by heterogeneous hosts.

Project-scoped config committed to the repository, consumed by a coding agent:

```json
{
  "mcpServers": {
    "incident-context": {
      "type": "http",
      "url": "https://mcp.acme.internal/incident-context/mcp",
      "headers": {
        "Authorization": "Bearer ${ACME_MCP_TOKEN}"
      }
    }
  }
}
```

A desktop host reaching the same capability through a local stdio bridge, because the desktop application runs outside the corporate network:

```json
{
  "mcpServers": {
    "incident-context": {
      "command": "/usr/local/bin/acme-mcp-bridge",
      "args": [
        "--upstream",
        "https://mcp.acme.internal/incident-context/mcp",
        "--transport",
        "stdio",
        "--log-level",
        "info"
      ],
      "env": {
        "ACME_MCP_TOKEN_FILE": "/etc/acme/mcp-token"
      }
    }
  }
}
```

A registry entry, so any host in the organisation can discover it:

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-07-09/server.schema.json",
  "name": "internal.acme/incident-context",
  "description": "Read-only access to the ACME incident tracker: search, timeline reconstruction and postmortem retrieval.",
  "version": "1.4.0",
  "repository": {
    "url": "https://git.acme.internal/platform/mcp-incident-context",
    "source": "gitlab"
  },
  "remotes": [
    {
      "type": "streamable-http",
      "url": "https://mcp.acme.internal/incident-context/mcp"
    }
  ]
}
```

Verify the `$schema` value against the registry's current published schema before committing; the registry pins its schema by date and it moves.

---

## 5. CLI: driving the protocol by hand

### 5.1 The handshake, over stdio, with no SDK

The most valuable diagnostic skill for this objective is being able to speak MCP with `printf` and `jq`. Nothing about the protocol requires a client library.

```
$ printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"conformance-probe","version":"0.4.1"}}}' \
  | node build/index.js 2>/dev/null | jq .
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": {
        "listChanged": true
      },
      "resources": {
        "subscribe": true,
        "listChanged": true
      },
      "prompts": {
        "listChanged": false
      },
      "logging": {}
    },
    "serverInfo": {
      "name": "acme-incident-context",
      "version": "1.4.0"
    },
    "instructions": "Use search_incidents before reconstruct_timeline. All results are scoped to the caller's team."
  }
}
```

Read that response like an operator:

- `protocolVersion` echoed unchanged → negotiation succeeded at the requested revision.
- `capabilities.tools.listChanged: true` → the server will push `notifications/tools/list_changed`; a client that ignores it will drift.
- `capabilities.sampling` absent → the server never asks the client for completions.
- `instructions` → free-form guidance the host is expected to place in the system prompt. It is part of the contract in practice even though nothing validates it.

A full session needs the `initialized` notification before any other request:

```
$ printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.4.1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | node build/index.js 2>/dev/null | tail -n 1 | jq '.result.tools[] | {name, title: .title, readOnly: .annotations.readOnlyHint}'
{
  "name": "search_incidents",
  "title": "Search incidents",
  "readOnly": true
}
{
  "name": "reconstruct_timeline",
  "title": "Reconstruct incident timeline",
  "readOnly": true
}
{
  "name": "acknowledge_incident",
  "title": "Acknowledge an incident",
  "readOnly": false
}
```

The full descriptor of one tool, which is what the model actually sees:

```
$ ... | jq '.result.tools[] | select(.name=="search_incidents")'
{
  "name": "search_incidents",
  "title": "Search incidents",
  "description": "Search the ACME incident tracker. Returns at most 50 incidents ordered by most recent update. Scoped to the caller's team; does not search other teams' incidents.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Free-text search over title and summary."
      },
      "severity": {
        "type": "string",
        "enum": ["sev1", "sev2", "sev3", "sev4"],
        "description": "Optional severity filter."
      },
      "since": {
        "type": "string",
        "format": "date-time",
        "description": "Only incidents updated at or after this RFC 3339 timestamp."
      },
      "limit": {
        "type": "integer",
        "minimum": 1,
        "maximum": 50,
        "default": 20
      }
    },
    "required": ["query"],
    "additionalProperties": false
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "incidents": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "title": { "type": "string" },
            "severity": { "type": "string" },
            "status": { "type": "string" },
            "updated_at": { "type": "string" }
          },
          "required": ["id", "title", "severity", "status", "updated_at"]
        }
      },
      "truncated": { "type": "boolean" }
    },
    "required": ["incidents", "truncated"]
  },
  "annotations": {
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  }
}
```

Note the schema is **flat and `$ref`-free**. That is deliberate portability engineering: it is the subset every client handles.

A call, showing the dual output required for interoperability with both old and new clients:

```
$ ... '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_incidents","arguments":{"query":"etcd latency","severity":"sev2","limit":2}}}' ...
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "2 incidents matched.\n- INC-4471 (sev2, resolved) etcd p99 latency above 500ms in eu-west-1, updated 2026-09-14T08:12:04Z\n- INC-4502 (sev2, monitoring) etcd defrag caused apiserver timeouts, updated 2026-09-16T21:40:11Z"
      }
    ],
    "structuredContent": {
      "incidents": [
        {
          "id": "INC-4471",
          "title": "etcd p99 latency above 500ms in eu-west-1",
          "severity": "sev2",
          "status": "resolved",
          "updated_at": "2026-09-14T08:12:04Z"
        },
        {
          "id": "INC-4502",
          "title": "etcd defrag caused apiserver timeouts",
          "severity": "sev2",
          "status": "monitoring",
          "updated_at": "2026-09-16T21:40:11Z"
        }
      ],
      "truncated": false
    },
    "isError": false
  }
}
```

When a server declares an `outputSchema`, it **must** return `structuredContent` conforming to it, and it should also return a text `content` block carrying the same information — clients that predate structured output only read `content`. Emitting both is the price of interoperating across a mixed fleet.

### 5.2 The same server over Streamable HTTP

```
$ curl -sS -D- -o /tmp/init.json \
    -X POST https://mcp.acme.internal/incident-context/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'Authorization: Bearer '"$ACME_MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.4.1"}}}'
HTTP/2 200
content-type: application/json
mcp-session-id: 0f6b1c42-6a7e-4f0d-9a3c-2b5b8f1d77aa
mcp-protocol-version: 2025-06-18
cache-control: no-store
date: Thu, 17 Sep 2026 09:14:33 GMT
```

Three headers matter here:

- `Accept` **must** list both `application/json` and `text/event-stream` on a POST. A server is entitled to reject the request otherwise, and this is the number one cause of a hand-rolled client getting `406`.
- `Mcp-Session-Id`, when present, must be echoed on every subsequent request in this session.
- `MCP-Protocol-Version` must be sent by the client on all requests *after* initialization. If it is absent, a server should assume `2025-03-26` — which is how a client that thinks it negotiated `2025-06-18` silently ends up being served `2025-03-26` semantics.

```
$ curl -sS -N \
    -X POST https://mcp.acme.internal/incident-context/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H 'Mcp-Session-Id: 0f6b1c42-6a7e-4f0d-9a3c-2b5b8f1d77aa' \
    -H 'Authorization: Bearer '"$ACME_MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"reconstruct_timeline","arguments":{"incident_id":"INC-4502"}},"_meta":{"progressToken":"p-4"}}'
event: message
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p-4","progress":1,"total":4,"message":"fetching incident record"}}

event: message
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p-4","progress":3,"total":4,"message":"correlating deploy events"}}

event: message
data: {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"Timeline for INC-4502 (14 events, 2026-09-16T20:51Z to 2026-09-16T21:40Z)..."}],"isError":false}}
```

Closing the session cleanly:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -X DELETE https://mcp.acme.internal/incident-context/mcp \
    -H 'Mcp-Session-Id: 0f6b1c42-6a7e-4f0d-9a3c-2b5b8f1d77aa' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H 'Authorization: Bearer '"$ACME_MCP_TOKEN"
204
```

### 5.3 The Inspector in CLI mode — scriptable conformance

```
$ npx @modelcontextprotocol/inspector --cli \
    https://mcp.acme.internal/incident-context/mcp \
    --transport http \
    --method tools/list
{
  "tools": [
    { "name": "search_incidents", "title": "Search incidents", "...": "..." },
    { "name": "reconstruct_timeline", "title": "Reconstruct incident timeline", "...": "..." },
    { "name": "acknowledge_incident", "title": "Acknowledge an incident", "...": "..." }
  ]
}
```

```
$ npx @modelcontextprotocol/inspector --cli node build/index.js \
    --method tools/call \
    --tool-name search_incidents \
    --tool-arg query="etcd latency" \
    --tool-arg limit=2
```

The `--cli` flag is what makes the Inspector usable in CI: the same tool that gives you the interactive UI during development becomes a gate in the pipeline.

### 5.4 Registering the server with a host

```
$ claude mcp add --transport http incident-context https://mcp.acme.internal/incident-context/mcp
Added HTTP MCP server incident-context to local config

$ claude mcp list
Checking MCP server health...

incident-context: https://mcp.acme.internal/incident-context/mcp (HTTP) - ✓ Connected
code-graph: .venv/bin/graphify mcp - ✓ Connected
```

### 5.5 Cluster-side verification of the deployment

```
$ kubectl -n mcp-platform rollout status deploy/incident-context --timeout=120s
deployment "incident-context" successfully rolled out

$ kubectl -n mcp-platform get pods -l app.kubernetes.io/name=incident-context -o wide
NAME                                READY   STATUS    RESTARTS   AGE   IP           NODE
incident-context-7c9f4b8d5-4xk2p    1/1     Running   0          92s   10.42.3.17   worker-a
incident-context-7c9f4b8d5-9vmzq    1/1     Running   0          78s   10.42.5.41   worker-b
incident-context-7c9f4b8d5-t8hn6    1/1     Running   0          64s   10.42.7.22   worker-c

$ kubectl -n mcp-platform logs deploy/incident-context --tail=3 | jq -c '{ts,level,msg,protocol_version}'
{"ts":"2026-09-17T09:14:33.101Z","level":"info","msg":"session initialized","protocol_version":"2025-06-18"}
{"ts":"2026-09-17T09:14:33.418Z","level":"info","msg":"tools/list served","protocol_version":"2025-06-18"}
{"ts":"2026-09-17T09:14:41.882Z","level":"info","msg":"tools/call completed","protocol_version":"2025-06-18"}
```

---

## 6. Verification and failure diagnosis

### 6.1 The verification ladder

Each rung proves strictly more than the one below it. Claiming a rung you have not run is how interoperability regressions ship.

| Rung | Question | How you prove it | Cost |
|---|---|---|---|
| 0 | Does the process start and stay up? | `kubectl rollout status`, or run the binary | free |
| 1 | Does it negotiate? | `initialize` by hand; check the echoed `protocolVersion` | free |
| 2 | Does it declare what you think it declares? | Diff the `capabilities` object against the expected baseline | free |
| 3 | Does it list? | `tools/list`, `resources/list`, `prompts/list` | free |
| 4 | Are the schemas portable? | Validate each `inputSchema`; reject `$ref`, remote refs, exotic keywords | free |
| 5 | Does it execute? | `tools/call` with a known-good fixture; assert against `outputSchema` | free |
| 6 | **Does it behave identically across two different clients?** | Run the same fixture through two hosts and diff | free |
| 7 | Does it survive an ops event? | Call across a rolling restart and a scale-down | free |
| 8 | Is the *answer* correct? | Nothing automated proves this. A human reviews the fixture output. | human |

Rung 6 is the actual interoperability test, and it is the one teams skip. A server that works in the Inspector and fails in a production host is the normal outcome of stopping at rung 5.

### 6.2 A portable conformance probe

```bash
#!/usr/bin/env bash
# mcp-conformance.sh — rungs 1 through 5 against a Streamable HTTP endpoint.
set -euo pipefail

ENDPOINT="${1:?usage: mcp-conformance.sh <endpoint-url>}"
VERSION="${MCP_VERSION:-2025-06-18}"
TOKEN="${ACME_MCP_TOKEN:-}"
HDR=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
[ -n "$TOKEN" ] && HDR+=(-H "Authorization: Bearer ${TOKEN}")

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Rung 1 — negotiate.
init_body=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"%s","capabilities":{},"clientInfo":{"name":"conformance","version":"1.0.0"}}}' "$VERSION")
headers=$(mktemp); trap 'rm -f "$headers"' EXIT
init=$(curl -sS -D "$headers" -X POST "$ENDPOINT" "${HDR[@]}" -d "$init_body")

negotiated=$(jq -r '.result.protocolVersion // empty' <<<"$init")
[ -n "$negotiated" ] || fail "no protocolVersion in initialize result: $init"
printf 'rung 1 OK: negotiated %s (requested %s)\n' "$negotiated" "$VERSION"
[ "$negotiated" = "$VERSION" ] || printf 'WARN: server down-negotiated to %s\n' "$negotiated" >&2

session=$(grep -i '^mcp-session-id:' "$headers" | tr -d '\r' | awk '{print $2}' || true)
SESS=()
[ -n "$session" ] && SESS=(-H "Mcp-Session-Id: ${session}")
PROTO=(-H "MCP-Protocol-Version: ${negotiated}")

curl -sS -o /dev/null -X POST "$ENDPOINT" "${HDR[@]}" "${SESS[@]}" "${PROTO[@]}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Rung 2 — capabilities baseline.
jq -e '.result.capabilities.tools' <<<"$init" >/dev/null \
  || fail "server does not declare the tools capability"
printf 'rung 2 OK: capabilities %s\n' "$(jq -c '.result.capabilities' <<<"$init")"

# Rung 3 — listing.
tools=$(curl -sS -X POST "$ENDPOINT" "${HDR[@]}" "${SESS[@]}" "${PROTO[@]}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
count=$(jq '.result.tools | length' <<<"$tools")
[ "$count" -gt 0 ] || fail "tools/list returned no tools"
printf 'rung 3 OK: %s tools\n' "$count"

# Rung 4 — schema portability.
if jq -e '[.result.tools[].inputSchema | tostring] | join(" ") | test("\\$ref")' <<<"$tools" >/dev/null; then
  fail 'an inputSchema contains $ref — not portable across clients'
fi
jq -e '[.result.tools[] | select((.description // "") | length < 20)] | length == 0' <<<"$tools" >/dev/null \
  || fail "a tool has a description shorter than 20 characters; the model cannot select it reliably"
printf 'rung 4 OK: schemas are flat and described\n'

# Rung 5 — execution against a fixture.
call=$(curl -sS -X POST "$ENDPOINT" "${HDR[@]}" "${SESS[@]}" "${PROTO[@]}" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_incidents","arguments":{"query":"conformance-canary","limit":1}}}')
jq -e '.error | not' <<<"$call" >/dev/null || fail "tools/call returned a JSON-RPC error: $(jq -c .error <<<"$call")"
jq -e '.result.isError != true' <<<"$call" >/dev/null || fail "tools/call reported isError: $(jq -c .result.content <<<"$call")"
printf 'rung 5 OK: fixture call succeeded\n'

[ -n "$session" ] && curl -sS -o /dev/null -X DELETE "$ENDPOINT" "${SESS[@]}" "${PROTO[@]}" \
  -H "Authorization: Bearer ${TOKEN:-}" || true
printf 'conformance PASS against %s\n' "$ENDPOINT"
```

```
$ ./mcp-conformance.sh https://mcp.acme.internal/incident-context/mcp
rung 1 OK: negotiated 2025-06-18 (requested 2025-06-18)
rung 2 OK: capabilities {"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"prompts":{"listChanged":false},"logging":{}}
rung 3 OK: 3 tools
rung 4 OK: schemas are flat and described
rung 5 OK: fixture call succeeded
conformance PASS against https://mcp.acme.internal/incident-context/mcp
```

Wired into the cluster as a gate:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: incident-context-conformance
  namespace: mcp-platform
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: incident-context-conformance
    spec:
      restartPolicy: Never
      serviceAccountName: incident-context
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe
          image: registry.acme.internal/platform/curl-jq:1.2.0
          command:
            - /bin/bash
            - /probe/mcp-conformance.sh
            - http://incident-context.mcp-platform.svc.cluster.local/mcp
          env:
            - name: MCP_VERSION
              value: "2025-06-18"
            - name: ACME_MCP_TOKEN
              valueFrom:
                secretKeyRef:
                  name: incident-context-probe
                  key: token
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: probe
              mountPath: /probe
      volumes:
        - name: probe
          configMap:
            name: incident-context-probe-script
            defaultMode: 493
```

### 6.3 Error channels — get this wrong and the agent cannot recover

Two distinct channels, with different consequences:

**Protocol-level error** — the request itself was invalid. The run usually aborts.

```
{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"Invalid params: unknown tool 'incidnet_search'"}}
```

**Tool-level error** — the request was well-formed, the operation failed. The model sees the text and can retry differently.

```
{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"Upstream incident API returned 503 after 3 retries (last attempt 2026-09-17T09:21:04Z). The tool is temporarily unavailable; retry in ~60s or ask the user to check https://status.acme.internal."}],"isError":true}}
```

The rule: **a failure inside your tool's own logic belongs in `isError: true`, never in a JSON-RPC error.** Servers that raise `-32603` for an upstream timeout turn a recoverable situation into a dead agent turn, and the symptom ("the assistant just stops") is reported as a client bug for weeks before anyone looks at the server.

### 6.4 Symptom → cause → probe → fix

| Symptom | Probable cause | Probe | Fix |
|---|---|---|---|
| stdio server "disconnects immediately" | **stdout pollution** — a library, banner or `print()` wrote non-JSON to fd 1 | `node build/index.js < /dev/null 1>/tmp/out 2>/dev/null; head -c 200 /tmp/out` — anything that is not JSON-RPC is the bug | Route **all** logging to stderr. On stdio, stdout is the wire. |
| Client disconnects right after `initialize` | Version negotiation failed; the server's counter-offer is unsupported | Compare requested vs echoed `protocolVersion` in §5.1 | Align the fleet pin; widen the server's supported range during migration |
| `406 Not Acceptable` on POST | `Accept` header missing `text/event-stream` | `curl -D-` and inspect the request headers | Send `Accept: application/json, text/event-stream` |
| `400 Bad Request` on every call after init | `MCP-Protocol-Version` header absent | Header dump on the second request | Send the negotiated version on every subsequent HTTP request |
| `404` mid-conversation, worked a minute ago | Session unknown to the replica that received the request (scale event, or no affinity) | `mcp_http_responses_total{status="404"}`; correlate with HPA events | Stateless mode, or cookie affinity per §4.4 |
| Long tool calls hang at ~60 s | Ingress `proxy-read-timeout` default kills the SSE stream | `kubectl -n ingress-nginx logs ... \| grep upstream_response_time` | `proxy-read-timeout: "3600"` **and** `proxy-buffering: "off"` |
| Works in the Inspector, fails in a real host | Schema uses `$ref`/`oneOf` the host does not support | Rung 4 of the probe | Flatten the schema; inline every definition |
| Server lists tools, model never calls them | Bad descriptions, name collision, or too many tools mounted | Count total tools across all mounted servers; grep for duplicate names | Namespace at the gateway; curate per role; rewrite descriptions to state *when* to use the tool |
| Agent aborts instead of retrying a transient failure | Tool failure returned as a JSON-RPC error | Inspect whether `.error` or `.result.isError` is set | Move operational failures to `isError: true` with actionable text |
| `401` with `WWW-Authenticate` on first call | The client has no token for this resource | `curl -D- ... \| grep -i www-authenticate` | The client must read `resource_metadata`, fetch `/.well-known/oauth-protected-resource`, and run the OAuth flow |
| Token accepted by the wrong server | No audience restriction | Decode the JWT `aud` claim | Require RFC 8707 resource indicators; reject tokens whose audience is not this server's canonical URI |
| Capability silently missing after upgrade | Server dropped a capability; client cached the old list | Diff `capabilities` before/after | Treat the capability object as a versioned contract; alert on diffs |

### 6.5 The security consequence of interoperability

Making a capability universally consumable also makes it universally reachable. Two spec-mandated defences you are expected to know:

1. **Origin validation.** HTTP servers **must** validate the `Origin` header to prevent DNS-rebinding attacks from a browser on the user's machine. Local servers should bind to `127.0.0.1`, not `0.0.0.0`.
2. **Token audience binding.** A server must **never** accept a token that was not issued for it. Passing a client's token through to an upstream API ("token passthrough") is explicitly forbidden — it destroys the audit chain and lets a compromised server replay credentials elsewhere.

And one that is yours alone: **tool annotations are hints, not enforcement.** `readOnlyHint: true` is advice to the host's confirmation UI. If your `acknowledge_incident` tool must not be callable without a scope, the check lives in the server's authorization code. A hostile or buggy client will call it anyway.

---

## 7. What to carry into the exam

- The value proposition is **M×N → M+N**, and the operational payoff is one credential store, one audit point, one hardening effort, one on-call owner per capability.
- Interoperability is guaranteed only at the layers the spec pins: envelope, lifecycle, capabilities, primitives, the two transports, and the HTTP authorization profile. Tool *semantics*, health endpoints and multi-tenancy are yours.
- Protocol versions are **dates**, negotiated in `initialize`, and negotiation is allowed to fail — the client disconnects if it cannot accept the counter-offer.
- stdio for intrinsically local capabilities; Streamable HTTP for intrinsically shared ones. On stdio, stdout is the wire — log to stderr.
- Stateless Streamable HTTP is the default for scale; session affinity is a cost you pay only for features that need it.
- MCP is the agent's southbound interface; agent-to-agent protocols are east–west. They compose.
- Portability discipline: flat `$ref`-free schemas, both `content` and `structuredContent`, operational failures in `isError`, and a conformance probe that actually runs against two different clients.

---

## References

- Linux Foundation — *Model Context Protocol Associate (MCPA)* certification page: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
- Model Context Protocol — official documentation and introduction: https://modelcontextprotocol.io/
- Model Context Protocol — specification index and revision list: https://modelcontextprotocol.io/specification/
- Model Context Protocol — architecture overview: https://modelcontextprotocol.io/docs/learn/architecture
- Model Context Protocol — transports (stdio and Streamable HTTP): https://modelcontextprotocol.io/docs/concepts/transports
- Model Context Protocol — tools, resources and prompts: https://modelcontextprotocol.io/docs/concepts/tools
- Model Context Protocol — authorization specification: https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Model Context Protocol — security best practices: https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
- Model Context Protocol — organisation and reference SDKs on GitHub: https://github.com/modelcontextprotocol
- MCP Inspector — developer and CLI tool: https://github.com/modelcontextprotocol/inspector
- MCP Registry — official server registry: https://github.com/modelcontextprotocol/registry
- JSON-RPC 2.0 Specification: https://www.jsonrpc.org/specification
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://datatracker.ietf.org/doc/html/rfc9728
- RFC 8707 — Resource Indicators for OAuth 2.0: https://datatracker.ietf.org/doc/html/rfc8707
- Language Server Protocol Specification (the design precedent MCP follows): https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- Kubernetes — Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- ingress-nginx — annotations reference (session affinity, proxy timeouts, buffering): https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/