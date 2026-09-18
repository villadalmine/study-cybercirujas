# Topic 1.2 — Core MCP Concepts

**Certification:** Linux Foundation *Model Context Protocol Associate* (MCPA) — exam version 2026-07-28
**Domain weight:** 5.33
**Audience profile:** Platform Architect / SRE operating MCP servers as first-class production services

---

## 1. The architectural problem MCP exists to solve

### 1.1 The N×M integration surface

Before MCP, every LLM-powered application that needed access to an external system re-implemented the same three layers by hand:

1. A **schema layer** — describing the capability to the model (function/tool JSON Schema).
2. A **transport layer** — how the application actually reaches the system (HTTP client, DB driver, SDK).
3. A **trust layer** — credentials, scoping, audit, and the decision of *when* invocation is permitted.

With `N` host applications and `M` backend systems, you build `N × M` bespoke adapters. Worse, each adapter is coupled to one vendor's function-calling dialect, so migrating a model provider means rewriting the integration layer, not just the API call.

MCP collapses this into `N + M`: every host speaks one client protocol, every backend exposes one server protocol.

```
        Without MCP                            With MCP

  Host A ──┬── Jira adapter            Host A ──┐
           ├── Postgres adapter                 ├── MCP client ──┬── Jira MCP server
           └── K8s adapter                      │                ├── Postgres MCP server
  Host B ──┬── Jira adapter            Host B ──┘                └── K8s MCP server
           ├── Postgres adapter
           └── K8s adapter                  N + M connectors
      N × M connectors
```

### 1.2 Why this is an SRE concern, not just a developer convenience

The moment an MCP server becomes the path through which a production agent reads your inventory database or restarts a Deployment, it acquires the operational profile of a **tier-1 service with an unusually hostile input channel**: its parameters are chosen by a stochastic model that can be influenced by attacker-controlled text. Concretely, MCP forces four production properties into the open:

| Production property | What MCP standardises | What you still own |
|---|---|---|
| **Discovery** | `tools/list`, `resources/list`, `prompts/list` + `notifications/*/list_changed` | Keeping the advertised surface small and versioned |
| **Capability negotiation** | `initialize` handshake, date-stamped protocol revisions | Pinning revisions and handling downgrade |
| **Session semantics** | `Mcp-Session-Id`, resumable SSE streams | Session storage, affinity, expiry, horizontal scale |
| **Trust boundary** | OAuth 2.1 resource-server model, audience-bound tokens | Token issuance, scope design, audit, blast-radius control |

The protocol gives you a wire contract. It does **not** give you a safe system: `tools/list` output is untrusted content that reaches the model's context, and tool annotations are *hints from the server*, never enforcement.

---

## 2. The participant model: Host, Client, Server

MCP defines exactly three roles. Getting these precise is the single highest-yield item in this topic — a large fraction of MCPA questions hinge on "which participant does X".

```
┌──────────────────────────────────────────────────────┐
│ HOST  (the LLM application: IDE, chat app, agent)    │
│   · owns the model and the context window            │
│   · owns the user consent / approval UX              │
│   · aggregates capabilities from many servers        │
│                                                      │
│   ┌────────────┐  ┌────────────┐  ┌────────────┐     │
│   │  CLIENT 1  │  │  CLIENT 2  │  │  CLIENT 3  │     │
│   └─────┬──────┘  └─────┬──────┘  └─────┬──────┘     │
└─────────┼───────────────┼───────────────┼────────────┘
          │ 1:1 stateful  │               │
          │ session       │               │
     ┌────▼────┐     ┌────▼────┐     ┌────▼────┐
     │ SERVER  │     │ SERVER  │     │ SERVER  │
     │ (files) │     │ (jira)  │     │ (k8s)   │
     └─────────┘     └─────────┘     └─────────┘
```

| Role | Cardinality | Responsibilities | Explicitly NOT its job |
|---|---|---|---|
| **Host** | 1 per application process | Model invocation, context assembly, consent prompts, aggregating servers, security policy | Speaking the wire protocol directly |
| **Client** | 1 per server connection, created by the host | Protocol conformance, lifecycle, capability negotiation, message correlation, **isolation between servers** | Deciding policy; it enforces what the host decides |
| **Server** | 1 per connected client session | Exposing tools/resources/prompts, executing them, emitting notifications | Seeing other servers' data, seeing the whole conversation, reaching the model directly |

**The isolation invariant:** one client connects to exactly one server, and a server never sees the full conversation or the other servers connected to the same host. A server only ever sees the arguments the host chose to send it. This is what makes an MCP host composable — and it is why "server A reads server B's tokens" is a host bug, not a protocol feature.

**Sampling inverts the direction but not the boundary.** When a server needs model inference (`sampling/createMessage`), it asks the *client*, which asks the *host*, which may ask the *user*. The server never holds a model API key and never reaches the provider. Same for `elicitation/create` (structured user input) and `roots/list` (filesystem boundaries).

---

## 3. The base protocol: JSON-RPC 2.0

MCP is **JSON-RPC 2.0 over a transport**. Nothing more exotic. All messages are UTF-8 encoded JSON.

### 3.1 The three message shapes

A **request** — has an `id`, expects exactly one response. `id` MUST be a string or number, MUST NOT be `null`, and MUST NOT be reused within a session by the same side.

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tools/call",
  "params": {
    "name": "restart_deployment",
    "arguments": {
      "namespace": "payments",
      "name": "checkout-api"
    }
  }
}
```

A **response** — success carries `result`, failure carries `error`. Never both.

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "error": {
    "code": -32602,
    "message": "Invalid params: 'namespace' must match ^[a-z0-9-]{1,63}$",
    "data": {
      "field": "namespace",
      "received": "Payments/"
    }
  }
}
```

A **notification** — no `id`, no response, no retry semantics.

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/tools/list_changed"
}
```

### 3.2 Bidirectionality

Unlike classic client-server RPC, **both sides issue requests**. The server calls `sampling/createMessage`, `elicitation/create` and `roots/list` on the client; the client calls everything else on the server. Any conformant implementation therefore needs a request router and a pending-request table *on both ends*.

### 3.3 Batching

JSON-RPC 2.0 array batching was permitted in the `2025-03-26` revision and **removed in `2025-06-18`**. Post-`2025-06-18` a single POST body carries exactly one JSON-RPC message. If you still see `[{...},{...}]` on the wire, you are talking to an implementation pinned to an older revision — that is a compatibility signal worth alerting on.

### 3.4 Error taxonomy — the distinction that matters operationally

There are **two entirely different failure channels**, and conflating them is the most common design bug in home-grown servers.

| | Protocol error | Tool execution error |
|---|---|---|
| Wire shape | `error` object on the JSON-RPC response | `result` with `"isError": true` and error text in `content` |
| Examples | Unknown method, malformed params, auth failure, unknown tool name | API returned 503, record not found, rate limited, validation failed inside the tool |
| Who consumes it | The **client/host** — surfaced as a connection or protocol fault | The **model** — it reads the text and can retry or change approach |
| SLO impact | Counts as a server availability failure | Is normal business flow; must not page you |

Standard codes: `-32700` parse error, `-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal error. MCP adds implementation-specific codes above `-32000`; the specification uses `-32002` for "resource not found" in its examples.

A tool that returns `-32603` because a downstream API 500'd has just made the model blind to a recoverable condition and has polluted your protocol-error SLI. Return `isError: true` instead.

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Deployment restart refused: PodDisruptionBudget payments/checkout-api allows 0 more disruptions. Retry after the current rollout completes."
      }
    ],
    "isError": true
  }
}
```

---

## 4. Lifecycle and capability negotiation

### 4.1 The three phases

```
  CLIENT                                            SERVER
    │                                                  │
    │  ── initialize (id=1) ──────────────────────────▶ │   INITIALIZATION
    │      protocolVersion, capabilities, clientInfo   │
    │  ◀──────────────────── initialize result ─────── │
    │      protocolVersion, capabilities, serverInfo,  │
    │      instructions?                               │
    │  ── notifications/initialized ─────────────────▶ │
    │                                                  │
    │  ═══════════ normal operation ═══════════════════ │   OPERATION
    │  ── tools/list, resources/read, tools/call ────▶ │
    │  ◀── notifications/message, .../progress ─────── │
    │  ◀── sampling/createMessage, elicitation/create  │
    │                                                  │
    │  ─ transport close / DELETE session ───────────▶ │   SHUTDOWN
```

**Hard rules for the initialization phase:**

- The client MUST NOT send any request other than `ping` before receiving the `initialize` result.
- The server MUST NOT send any request other than `ping` and `notifications/message` (logging) before receiving `notifications/initialized`.
- `initialize` MUST NOT be part of a batch (relevant only on revisions where batching existed).
- The client SHOULD apply a timeout to `initialize` and tear the connection down on expiry.

### 4.2 Protocol version negotiation

Versions are **dates**, not semver. The client offers the newest version it supports; if the server supports it, it echoes it back. If not, the server responds with the newest version *it* supports. The client then either proceeds on that version or disconnects.

| Revision | Headline changes relevant to operations |
|---|---|
| `2024-11-05` | Initial public revision. stdio + HTTP with a separate SSE endpoint. |
| `2025-03-26` | **Streamable HTTP** replaces the two-endpoint SSE transport; OAuth 2.1 authorization framework; tool annotations; `audio` content type; `completions` capability; progress messages. |
| `2025-06-18` | JSON-RPC **batching removed**; **structured tool output** (`outputSchema` / `structuredContent`); **elicitation**; `resource_link` content; `MCP-Protocol-Version` HTTP header becomes required after initialization; RFC 8707 Resource Indicators mandated for clients; servers formally classified as OAuth 2.1 **resource servers**. |

> Revisions are published on a rolling date-stamped cadence. Before an exam sitting or a production rollout, re-read the changelog at `https://modelcontextprotocol.io/specification` and pin the revision your fleet negotiates rather than accepting whatever a server offers.

**Operational consequence:** version negotiation is a silent-downgrade vector. A server that only supports `2025-03-26` will negotiate a client down from `2025-06-18`, and the client loses elicitation and structured output *without any error*. Instrument the negotiated version as a metric label and alert on downgrades.

### 4.3 The capability handshake, in full

Complete `initialize` request from a host that supports all three client primitives:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "roots": {
        "listChanged": true
      },
      "sampling": {},
      "elicitation": {}
    },
    "clientInfo": {
      "name": "platform-agent",
      "title": "Platform Agent",
      "version": "3.4.1"
    }
  }
}
```

Complete `initialize` result from a fully featured server:

```json
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
        "listChanged": true
      },
      "logging": {},
      "completions": {}
    },
    "serverInfo": {
      "name": "inventory-server",
      "title": "Fleet Inventory",
      "version": "1.7.3"
    },
    "instructions": "Use search_hosts before get_host_detail. Host identifiers are FQDNs, not short names. Write operations require an approved change ticket in the 'change_id' argument."
  }
}
```

### 4.4 Capability reference

| Capability | Declared by | Sub-flags | Unlocks |
|---|---|---|---|
| `tools` | Server | `listChanged` | `tools/list`, `tools/call` |
| `resources` | Server | `subscribe`, `listChanged` | `resources/list`, `resources/templates/list`, `resources/read`, `resources/subscribe` |
| `prompts` | Server | `listChanged` | `prompts/list`, `prompts/get` |
| `logging` | Server | — | `logging/setLevel`, `notifications/message` |
| `completions` | Server | — | `completion/complete` (argument autocomplete) |
| `roots` | Client | `listChanged` | `roots/list` |
| `sampling` | Client | — | `sampling/createMessage` |
| `elicitation` | Client | — | `elicitation/create` |
| `experimental` | Either | free-form | Non-standard extensions |

**A capability not declared MUST NOT be used.** A server calling `sampling/createMessage` against a client that did not declare `sampling` is a protocol violation, and the correct client response is `-32601`. The `instructions` string is optional free text injected into the model's system context by the host — treat it as part of your prompt surface and review it in code review, because it is a direct channel into the model.

---

## 5. Transports

MCP defines two standard transports. Everything else is a custom transport that must still carry newline-free JSON-RPC messages.

### 5.1 stdio

The client spawns the server as a subprocess and speaks over stdin/stdout, one JSON-RPC message per line.

Non-negotiable rules:

- Messages are delimited by `\n` and **MUST NOT contain embedded newlines**.
- The server **MUST NOT** write anything to `stdout` that is not a valid MCP message. A stray `print()` or a dependency's banner corrupts the stream and kills the session.
- The server **MAY** write logs to `stderr`; the client may capture or discard them.
- Shutdown: the client closes stdin, waits, then `SIGTERM`, then `SIGKILL`.

### 5.2 Streamable HTTP

A single HTTP endpoint (conventionally `/mcp`) that accepts `POST` and optionally `GET`.

**POST** — client sends one JSON-RPC message. The client MUST send `Accept: application/json, text/event-stream`.

- Body was a notification or a response → server returns `202 Accepted`, empty body.
- Body was a request → server returns either `Content-Type: application/json` with a single response, **or** `Content-Type: text/event-stream` with an SSE stream that may carry progress notifications, server-initiated requests, and finally the response.

**GET** — client opens a long-lived SSE stream for server-initiated messages. A server that does not support this returns `405 Method Not Allowed`.

**Sessions.** The server MAY assign `Mcp-Session-Id` on the `initialize` response. If it does, the client MUST echo it on every subsequent request. A `404` on a request carrying a session ID means the session is gone and the client MUST re-run `initialize`. The client SHOULD send `DELETE` to terminate a session explicitly.

**Version header.** From `2025-06-18`, every HTTP request after initialization MUST carry `MCP-Protocol-Version: <negotiated>`. If it is absent, the server SHOULD assume `2025-03-26`.

**Resumability.** SSE events carry an `id`. On reconnect the client sends `Last-Event-ID`, and the server replays what was missed on that stream. This is what makes a 45-second tool call survive a load-balancer hiccup.

**Security.** Servers MUST validate the `Origin` header (DNS rebinding defence) and local servers SHOULD bind to `127.0.0.1`, not `0.0.0.0`.

### 5.3 Trade-off table

| Dimension | stdio | Streamable HTTP (stateful) | Streamable HTTP (stateless) | Legacy HTTP+SSE (`2024-11-05`) |
|---|---|---|---|---|
| Deployment | Subprocess on the host | Network service | Network service | Network service |
| Auth model | OS process identity, env vars | OAuth 2.1 resource server | OAuth 2.1 resource server | Ad hoc / bearer |
| Horizontal scale | N/A (1:1 with host) | Needs sticky sessions or shared session store | Trivial — any replica serves any request | Poor — SSE pinned to one replica |
| Server→client requests (sampling, elicitation) | Native, full duplex | Yes, via SSE on POST or GET stream | Limited — no GET stream, only within a POST's SSE | Yes, via the dedicated SSE endpoint |
| Resumability | N/A | `Last-Event-ID` replay | N/A | None |
| Network exposure | None | Full ingress surface | Full ingress surface | Full ingress surface, two endpoints |
| LB/proxy hazards | None | Idle timeouts, response buffering | Minimal | Idle timeouts, buffering, endpoint pairing |
| Best fit | Local dev tools, filesystem, git, per-user credentials | Shared platform servers needing subscriptions and sampling | High-fan-out read-only tool servers behind an API gateway | **Deprecated — migrate** |

**The decision rule:** if the server needs per-user OS credentials or touches the local filesystem, it is stdio. If it is a shared platform capability with its own identity and its own SLO, it is Streamable HTTP. Wrapping a stdio server in a network proxy to "make it remote" is how you end up with one process shared by every user and no per-user authorization at all.

---

## 6. Server primitives

### 6.1 The control model — the concept the exam tests hardest

| Primitive | Control | Who chooses to invoke | Closest web analogy | Consent model |
|---|---|---|---|---|
| **Tools** | Model-controlled | The LLM decides, from the tool description | `POST /resource` — has side effects | Per-call user approval (default) |
| **Resources** | Application-controlled | The host app decides what to attach to context | `GET /resource` — no side effects | Host policy / user selection |
| **Prompts** | User-controlled | The user picks it explicitly | A slash command or template | Explicit by construction |

The design intent: **resources must be side-effect free**, because the host may fetch them speculatively. A "resource" whose read mutates state is a protocol abuse that will produce non-reproducible incidents.

### 6.2 Tools

`tools/list` returns definitions; `tools/call` executes one. A complete definition with structured output and annotations:

```json
{
  "name": "restart_deployment",
  "title": "Restart Deployment",
  "description": "Triggers a rolling restart of a Kubernetes Deployment by patching its pod template annotation. Requires an approved change ticket. Does not scale, delete, or modify the Deployment spec.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "namespace": {
        "type": "string",
        "pattern": "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$",
        "maxLength": 63,
        "description": "Kubernetes namespace"
      },
      "name": {
        "type": "string",
        "pattern": "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$",
        "maxLength": 253,
        "description": "Deployment name"
      },
      "change_id": {
        "type": "string",
        "pattern": "^CHG[0-9]{7}$",
        "description": "Approved change ticket identifier"
      }
    },
    "required": ["namespace", "name", "change_id"],
    "additionalProperties": false
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "restarted_at": {
        "type": "string",
        "format": "date-time"
      },
      "observed_generation": {
        "type": "integer"
      },
      "replicas_updated": {
        "type": "integer"
      }
    },
    "required": ["restarted_at", "observed_generation"]
  },
  "annotations": {
    "title": "Restart Deployment",
    "readOnlyHint": false,
    "destructiveHint": false,
    "idempotentHint": false,
    "openWorldHint": false
  }
}
```

**Annotation semantics and defaults** — these are *hints for UX*, not enforcement:

| Annotation | Default | Meaning |
|---|---|---|
| `readOnlyHint` | `false` | Tool does not modify its environment |
| `destructiveHint` | `true` | Updates may be destructive; meaningful only when `readOnlyHint` is `false` |
| `idempotentHint` | `false` | Repeat calls with identical arguments have no additional effect |
| `openWorldHint` | `true` | Tool touches an open external world (the internet) rather than a closed system |

> **Security rule, stated in the specification:** clients MUST consider tool annotations to be untrusted unless the server is trusted. A malicious server declares `readOnlyHint: true` on `rm -rf`. Enforcement lives in the host's policy engine and in the server's own authorization checks — never in the hint.

**Structured output.** When `outputSchema` is present, the server returns `structuredContent` that MUST validate against it, and SHOULD *also* return the same payload serialised as a text content block for clients that do not understand structured content:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"restarted_at\":\"2026-09-17T11:04:22Z\",\"observed_generation\":19,\"replicas_updated\":3}"
      }
    ],
    "structuredContent": {
      "restarted_at": "2026-09-17T11:04:22Z",
      "observed_generation": 19,
      "replicas_updated": 3
    }
  }
}
```

**Content block types** available in tool results and prompt messages: `text`, `image` (base64 `data` + `mimeType`), `audio` (base64 `data` + `mimeType`), `resource` (embedded resource contents, inlined), and `resource_link` (a URI pointer the client may later `resources/read`). `resource_link` is the context-window-friendly option: return a link to a 4 MB log bundle, not the bundle.

### 6.3 Resources

Resources are addressed by **URI**. Common schemes are `file://`, `https://`, `git://`, plus server-defined custom schemes.

Two listing methods:

- `resources/list` — concrete, enumerable resources (paginated).
- `resources/templates/list` — **RFC 6570 URI templates** for parameterised resources that cannot be enumerated.

```json
{
  "uriTemplate": "inventory://hosts/{fqdn}/facts",
  "name": "host-facts",
  "title": "Host Facts",
  "description": "Structured facts for a single host, as collected by the CMDB agent.",
  "mimeType": "application/json"
}
```

`resources/read` returns one or more contents entries, each either text (`text` field) or binary (base64 `blob` field).

**Subscriptions.** If the server declared `resources: {subscribe: true}`, the client may `resources/subscribe` to a URI and receive `notifications/resources/updated` when it changes. Note the semantics carefully: the notification says *"this URI changed"*, it does **not** carry the new content. The client must re-read. This keeps notification volume bounded and avoids pushing megabytes into a stream — but it means a hot resource under rapid change generates a notification storm. Debounce server-side.

### 6.4 Prompts

Pre-authored, parameterised message templates that the **user** selects. `prompts/get` expands the arguments and returns the message list.

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "description": "Structured incident triage for a firing alert",
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "Triage alert HighErrorRate for service checkout-api. Retrieve the last 30 minutes of error-rate and latency series, correlate with deploys in the same window, and state the three most probable causes ranked by evidence."
        }
      },
      {
        "role": "user",
        "content": {
          "type": "resource",
          "resource": {
            "uri": "runbook://checkout-api/high-error-rate",
            "mimeType": "text/markdown",
            "text": "# Runbook: checkout-api HighErrorRate\n\n## Immediate checks\n..."
          }
        }
      }
    ]
  }
}
```

Prompts are where a platform team encodes institutional knowledge — runbook entry points, review checklists, standard triage flows — as a versioned, testable artifact instead of tribal copy-paste. `completion/complete` gives the user argument autocomplete when the server declares `completions`.

---

## 7. Client primitives

These are the inversion: the **server** makes the request, the **client** serves it.

### 7.1 Sampling — `sampling/createMessage`

The server asks the host to run a model completion on its behalf. This lets a server implement agentic behaviour (summarise, classify, decide) without holding a model API key or knowing which provider the host uses.

```json
{
  "jsonrpc": "2.0",
  "id": 91,
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "Classify this log line as one of: transient, config-error, capacity, unknown. Answer with the single word.\n\nOct 17 11:04:22 node-14 kubelet[1284]: E1017 11:04:22.881 eviction_manager.go:600] eviction manager: pod checkout-api-7f9c failed to evict timeout waiting for pod to be cleaned up"
        }
      }
    ],
    "modelPreferences": {
      "hints": [
        {
          "name": "claude-haiku"
        }
      ],
      "costPriority": 0.9,
      "speedPriority": 0.8,
      "intelligencePriority": 0.2
    },
    "systemPrompt": "You are a log classifier. Respond with exactly one word.",
    "maxTokens": 16
  }
}
```

`modelPreferences.hints` are **advisory substring hints**, not model identifiers — the host maps them to whatever it actually has, and is free to ignore them entirely. The three priority values are `0.0`–`1.0` and let the host arbitrate. The specification states clients SHOULD keep a human in the loop: the user should be able to review and edit both the prompt the server sent and the completion before it is returned.

### 7.2 Roots — `roots/list`

The client declares the URI boundaries the server is allowed to operate within — typically filesystem directories, but any URI. The server calls `roots/list`; the client may emit `notifications/roots/list_changed` when the workspace changes.

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "roots": [
      {
        "uri": "file:///srv/runbooks",
        "name": "Runbooks"
      },
      {
        "uri": "file:///srv/postmortems",
        "name": "Postmortems"
      }
    ]
  }
}
```

Roots are **a scoping mechanism, not a sandbox**. The server is expected to respect them; nothing in the protocol prevents a hostile server from reading outside them. Real confinement is a container with a read-only bind mount, a `seccomp` profile and a `NetworkPolicy`.

### 7.3 Elicitation — `elicitation/create`

Introduced in `2025-06-18`. Mid-execution, the server asks the user for structured input — a missing parameter, a confirmation, a disambiguation.

```json
{
  "jsonrpc": "2.0",
  "id": 55,
  "method": "elicitation/create",
  "params": {
    "message": "Three Deployments match 'checkout'. Which one should be restarted?",
    "requestedSchema": {
      "type": "object",
      "properties": {
        "deployment": {
          "type": "string",
          "title": "Deployment",
          "enum": ["checkout-api", "checkout-worker", "checkout-migrator"]
        },
        "confirm": {
          "type": "boolean",
          "title": "Confirm restart",
          "default": false
        }
      },
      "required": ["deployment", "confirm"]
    }
  }
}
```

The response carries an `action` of `"accept"` (with `content`), `"decline"` (user said no), or `"cancel"` (user dismissed). Those three are semantically distinct and a server MUST NOT treat `cancel` as `decline`.

**Specification constraint:** `requestedSchema` is restricted to a **flat object of primitive properties** — string, number, boolean, enum, with the usual format/constraint keywords. No nesting, no arrays of objects. This is deliberate: clients must be able to render a generic form without implementing a JSON Schema UI engine.

**Security rule:** servers MUST NOT use elicitation to request passwords, API keys or other secrets. Clients SHOULD make the requesting server's identity unmistakable in the UI, because elicitation is a phishing surface pointed directly at your user.

---

## 8. Cross-cutting utilities

| Utility | Direction | Mechanism | Operational note |
|---|---|---|---|
| **Ping** | Either | `ping` request → empty result | Your liveness probe *inside* the session; distinct from an HTTP `/healthz` |
| **Progress** | Either | `_meta.progressToken` on the request → `notifications/progress` | `progress` MUST increase; `total` optional. Without it, a 5-minute tool looks like a hang |
| **Cancellation** | Either | `notifications/cancelled` with `requestId` | Best-effort. Races are expected; the receiver MAY have already responded, and the initiator MUST ignore a late response. `initialize` MUST NOT be cancelled by the client |
| **Logging** | Server → client | `logging/setLevel` + `notifications/message` | RFC 5424 levels: `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency` |
| **Pagination** | Client → server | Opaque `cursor` / `nextCursor` | Applies to `tools/list`, `resources/list`, `resources/templates/list`, `prompts/list`. Cursors are **opaque** — never parse, construct or persist them across sessions |
| **Completion** | Client → server | `completion/complete` | Autocomplete for prompt and resource-template arguments |

A progress-annotated request:

```json
{
  "jsonrpc": "2.0",
  "id": 77,
  "method": "tools/call",
  "params": {
    "name": "collect_node_diagnostics",
    "arguments": {
      "node": "node-14.fleet.example.com"
    },
    "_meta": {
      "progressToken": "diag-77"
    }
  }
}
```

The matching notification:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/progress",
  "params": {
    "progressToken": "diag-77",
    "progress": 3,
    "total": 7,
    "message": "Collecting kubelet journal (3/7)"
  }
}
```

---

## 9. Production deployment

The following manifests deploy a remote Streamable HTTP MCP server on Kubernetes with the operational properties the transport actually requires: session affinity, disabled proxy buffering, long read timeouts, egress restriction and metrics scraping.

### 9.1 Namespace, ServiceAccount, config

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-inventory-server
  namespace: mcp
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-inventory-config
  namespace: mcp
data:
  server.yaml: |
    protocol:
      pinnedVersion: "2025-06-18"
      rejectDowngradeBelow: "2025-06-18"
    transport:
      kind: streamable-http
      endpoint: /mcp
      allowedOrigins:
        - "https://chat.internal.example.com"
        - "https://ide.internal.example.com"
      sessionTtlSeconds: 3600
      sseKeepaliveSeconds: 15
    authorization:
      mode: oauth2-resource-server
      issuer: "https://idp.internal.example.com/realms/platform"
      audience: "https://mcp.internal.example.com/mcp"
      requireResourceIndicator: true
      rejectTokenPassthrough: true
    capabilities:
      tools:
        listChanged: true
      resources:
        subscribe: true
        listChanged: true
      prompts:
        listChanged: true
      logging: {}
    limits:
      maxConcurrentToolCalls: 32
      toolCallTimeoutSeconds: 120
      maxRequestBytes: 1048576
```

### 9.2 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-inventory-server
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-inventory-server
    app.kubernetes.io/component: mcp-server
    app.kubernetes.io/part-of: agent-platform
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory-server
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-inventory-server
        app.kubernetes.io/component: mcp-server
      annotations:
        checksum/config: "replaced-by-ci-with-sha256-of-configmap"
    spec:
      serviceAccountName: mcp-inventory-server
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 90
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
              app.kubernetes.io/name: mcp-inventory-server
      containers:
        - name: server
          image: registry.internal.example.com/mcp/inventory-server:1.7.3
          imagePullPolicy: IfNotPresent
          args:
            - "--config=/etc/mcp/server.yaml"
            - "--bind=0.0.0.0:8080"
            - "--metrics-bind=0.0.0.0:9464"
            - "--session-store=redis://mcp-sessions.mcp.svc.cluster.local:6379/0"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9464
              protocol: TCP
          env:
            - name: MCP_LOG_LEVEL
              value: "info"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: OTEL_SERVICE_NAME
              value: "mcp-inventory-server"
            - name: INVENTORY_DB_DSN
              valueFrom:
                secretKeyRef:
                  name: mcp-inventory-db
                  key: dsn
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mcp-sessions-auth
                  key: password
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            privileged: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "2"
              memory: 1Gi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 3
            failureThreshold: 20
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "sleep 15"
          volumeMounts:
            - name: config
              mountPath: /etc/mcp
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: mcp-inventory-config
        - name: tmp
          emptyDir:
            sizeLimit: 128Mi
```

The `preStop` sleep plus `terminationGracePeriodSeconds: 90` is not boilerplate: open SSE streams must be allowed to drain, and a tool call that takes 60 s must not be severed by a rolling update. Size the grace period above `limits.toolCallTimeoutSeconds`.

### 9.3 Service, PDB, HPA

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mcp-inventory-server
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-inventory-server
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mcp-inventory-server
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9464
      targetPort: metrics
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mcp-inventory-server
  namespace: mcp
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory-server
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: mcp-inventory-server
  namespace: mcp
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: mcp-inventory-server
  minReplicas: 3
  maxReplicas: 12
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: mcp_active_sessions
        target:
          type: AverageValue
          averageValue: "200"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
```

The long `scaleDown.stabilizationWindowSeconds` matters because scaling in evicts pods holding live SSE streams; with a shared Redis session store the client can resume, but each eviction still costs a reconnect.

### 9.4 Ingress — the SSE-specific configuration

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mcp-inventory-server
  namespace: mcp
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "1m"
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/affinity-mode: "persistent"
    nginx.ingress.kubernetes.io/session-cookie-name: "mcp-affinity"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"
    nginx.ingress.kubernetes.io/enable-cors: "false"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header X-Accel-Buffering no;
      proxy_set_header Connection "";
      chunked_transfer_encoding off;
    cert-manager.io/cluster-issuer: internal-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - "mcp.internal.example.com"
      secretName: mcp-inventory-tls
  rules:
    - host: "mcp.internal.example.com"
      http:
        paths:
          - path: /mcp
            pathType: Prefix
            backend:
              service:
                name: mcp-inventory-server
                port:
                  name: http
```

Three of those annotations are the difference between "works" and "mysteriously hangs":

- `proxy-buffering: "off"` — with buffering on, nginx accumulates the SSE stream and the client sees nothing until the response completes, so progress notifications are useless and the connection looks hung.
- `proxy-read-timeout: "3600"` — the default 60 s silently kills the long-lived `GET` SSE stream every minute.
- `affinity: "cookie"` — required only if your server keeps session state in process memory. If you back sessions with Redis (as configured above), you can drop affinity and get true stateless load balancing.

Wildcard hosts must be quoted — YAML reads a bare leading `*` as an alias:

```yaml
spec:
  tls:
    - hosts:
        - "*.mcp.internal.example.com"
      secretName: mcp-wildcard-tls
```

### 9.5 NetworkPolicy — bounding the blast radius

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mcp-inventory-server
  namespace: mcp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory-server
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
          port: 9464
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
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-sessions
      ports:
        - protocol: TCP
          port: 6379
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: data
          podSelector:
            matchLabels:
              app.kubernetes.io/name: inventory-postgres
      ports:
        - protocol: TCP
          port: 5432
```

An MCP server is, by construction, a machine that executes model-chosen actions. A default-deny egress policy is the control that turns "the model was prompt-injected into exfiltrating the inventory" from an incident into a denied connection.

### 9.6 Metrics scraping and alerting

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mcp-inventory-server
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-inventory-server
  namespaceSelector:
    matchNames:
      - mcp
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-inventory-server
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp-protocol
      rules:
        - alert: MCPProtocolErrorRateHigh
          expr: |
            sum(rate(mcp_jsonrpc_errors_total{job="mcp-inventory-server"}[5m]))
              /
            sum(rate(mcp_jsonrpc_requests_total{job="mcp-inventory-server"}[5m]))
              > 0.02
          for: 10m
          labels:
            severity: page
          annotations:
            summary: "MCP protocol error rate above 2 percent"
            description: "Protocol-level JSON-RPC errors, not tool execution errors. Check auth, schema validation and version negotiation."
        - alert: MCPProtocolVersionDowngrade
          expr: |
            sum by (negotiated_version) (
              rate(mcp_sessions_initialized_total{job="mcp-inventory-server",negotiated_version!="2025-06-18"}[15m])
            ) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Clients negotiating a protocol revision below the pinned baseline"
            description: "Structured tool output and elicitation are unavailable on this session. Identify the client and upgrade it."
        - alert: MCPSessionChurnHigh
          expr: |
            sum(rate(mcp_sessions_terminated_total{job="mcp-inventory-server",reason="expired"}[10m]))
              > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "MCP sessions expiring faster than expected"
            description: "Check ingress idle timeouts, Redis TTL and load-balancer affinity."
```

Every line of a block scalar — including the bare `/` operator in the PromQL — carries the same indentation. A single less-indented line closes the scalar and the manifest stops parsing.

### 9.7 Host-side client configuration

A host that consumes both a remote server and two local stdio servers:

```json
{
  "mcpServers": {
    "inventory": {
      "type": "http",
      "url": "https://mcp.internal.example.com/mcp",
      "headers": {
        "Authorization": "Bearer ${MCP_INVENTORY_TOKEN}"
      }
    },
    "runbooks": {
      "command": "/usr/local/bin/mcp-server-filesystem",
      "args": ["/srv/runbooks", "/srv/postmortems"],
      "env": {
        "MCP_LOG_LEVEL": "warn"
      }
    },
    "git": {
      "command": "/usr/local/bin/uvx",
      "args": ["mcp-server-git", "--repository", "/srv/platform-config"],
      "env": {
        "GIT_CONFIG_GLOBAL": "/etc/mcp/gitconfig"
      }
    }
  }
}
```

Config-file key names vary by host application — verify the exact schema in your host's documentation. What does not vary is the split between `command`/`args`/`env` (stdio) and `url`/`headers` (HTTP).

---

## 10. CLI verification

### 10.1 Probing a Streamable HTTP server by hand

Sample terminal output; identifiers and timings will differ in your environment.

```
$ export MCP_URL=https://mcp.internal.example.com/mcp
$ export MCP_TOKEN=$(cat ~/.config/mcp/inventory.token)

$ curl -sS -D /tmp/hdr.txt -o /tmp/init.sse \
    -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{}},"clientInfo":{"name":"curl-probe","version":"0.1.0"}}}'

$ cat /tmp/hdr.txt
HTTP/2 200
content-type: text/event-stream
mcp-session-id: 1868a90c-9c9a-4d0b-9e4a-3f0a6b2d51c7
cache-control: no-cache, no-transform
x-accel-buffering: no
date: Thu, 17 Sep 2026 11:02:04 GMT

$ cat /tmp/init.sse
event: message
id: 1
data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"prompts":{"listChanged":true},"logging":{},"completions":{}},"serverInfo":{"name":"inventory-server","title":"Fleet Inventory","version":"1.7.3"},"instructions":"Use search_hosts before get_host_detail."}}
```

Capture the session ID and complete the handshake:

```
$ export SID=$(awk -F': ' '/^mcp-session-id:/ {print $2}' /tmp/hdr.txt | tr -d '\r')
$ echo "$SID"
1868a90c-9c9a-4d0b-9e4a-3f0a6b2d51c7

$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
202
```

`202` with an empty body is the correct answer for a notification. Anything else — `200` with a JSON-RPC response, or `400` — is a server conformance bug.

### 10.2 Enumerating the tool surface

```
$ curl -sS -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | sed -n 's/^data: //p' \
  | jq -r '.result.tools[] | [.name, (.annotations.readOnlyHint // false | tostring), (.annotations.destructiveHint // true | tostring), (.outputSchema != null | tostring)] | @tsv' \
  | column -t -N NAME,READONLY,DESTRUCTIVE,STRUCTURED

NAME                       READONLY  DESTRUCTIVE  STRUCTURED
search_hosts               true      true         true
get_host_detail            true      true         true
list_deployments           true      true         true
restart_deployment         false     false        true
drain_node                 false     true         false
collect_node_diagnostics   true      true         true
```

Read that `DESTRUCTIVE` column carefully: `destructiveHint` defaults to `true` and is **meaningless when `readOnlyHint` is `true`**, which is why every read-only tool shows `true` here. A frequent misreading. What is genuinely actionable is the `drain_node` row: not read-only, destructive, and with no `outputSchema` — that is the tool that deserves a hard approval gate in the host policy.

Audit the total context cost of the surface, since every tool description is injected into the model's context on every turn:

```
$ curl -sS -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $MCP_TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' \
  | sed -n 's/^data: //p' \
  | jq '{tools: (.result.tools | length), bytes: (.result.tools | tojson | length), paginated: (.result.nextCursor != null)}'
{
  "tools": 6,
  "bytes": 4187,
  "paginated": false
}
```

### 10.3 Executing a tool and reading the result

```
$ curl -sS -N -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $MCP_TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"collect_node_diagnostics","arguments":{"node":"node-14.fleet.example.com"},"_meta":{"progressToken":"diag-4"}}}'

event: message
id: 1
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"diag-4","progress":1,"total":4,"message":"Querying kubelet"}}

event: message
id: 2
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"diag-4","progress":3,"total":4,"message":"Collecting journal"}}

event: message
id: 3
data: {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"resource_link","uri":"inventory://diagnostics/node-14/2026-09-17T11-06-41Z","name":"node-14 diagnostics bundle","mimeType":"application/gzip"}],"structuredContent":{"node":"node-14.fleet.example.com","collected_at":"2026-09-17T11:06:41Z","bundle_bytes":4718592,"checks_passed":3,"checks_failed":1}}}
```

Note the `-N` flag: without it curl buffers and the progress notifications appear only at the end, which will make you misdiagnose a working server as hung.

### 10.4 Session teardown, and what expiry looks like

```
$ curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$MCP_URL" \
    -H "Authorization: Bearer $MCP_TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18'
204

$ curl -sS -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $MCP_TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}}' \
  -o /dev/null -w '%{http_code}\n'
404
```

`404` on a request that carries a session ID is the protocol's signal that the session is gone and the client must re-run `initialize` from scratch. A client that retries the same request on `404` will loop forever.

### 10.5 Driving a stdio server directly

No network, no inspector — just pipe JSON-RPC into the process:

```
$ printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | /usr/local/bin/mcp-server-filesystem /srv/runbooks 2>/tmp/server.err \
  | jq -c 'if .id == 1 then {phase:"init", version:.result.protocolVersion, server:.result.serverInfo.name} else {phase:"tools", names:[.result.tools[].name]} end'

{"phase":"init","version":"2025-06-18","server":"filesystem"}
{"phase":"tools","names":["read_file","read_multiple_files","write_file","edit_file","create_directory","list_directory","move_file","search_files","get_file_info","list_allowed_directories"]}

$ head -2 /tmp/server.err
Secure MCP Filesystem Server running on stdio
Allowed directories: [ '/srv/runbooks' ]
```

That `2>/tmp/server.err` redirect is the whole point: those two human-readable lines go to **stderr**. Had the server written them to stdout, the first `jq` parse would have failed and the session would be dead.

### 10.6 MCP Inspector

The reference interactive debugger, useful for exploring an unfamiliar server:

```
$ npx @modelcontextprotocol/inspector /usr/local/bin/mcp-server-filesystem /srv/runbooks
Starting MCP inspector...
Proxy server listening on 127.0.0.1:6277
MCP Inspector is up and running at http://127.0.0.1:6274
```

It supports both transports and a CLI mode for scripting. Run it against a **staging** instance: the inspector executes real tool calls with whatever credentials you hand it.

### 10.7 A conformance smoke test for CI

```bash
#!/usr/bin/env bash
# mcp-smoke.sh — post-deploy conformance gate for a Streamable HTTP MCP server.
set -euo pipefail

URL="${1:?usage: mcp-smoke.sh <endpoint-url>}"
VERSION="${MCP_VERSION:-2025-06-18}"
TOKEN="${MCP_TOKEN:?MCP_TOKEN is required}"
HDR=$(mktemp) ; BODY=$(mktemp)
trap 'rm -f "$HDR" "$BODY"' EXIT

post() {
  curl -sS --fail-with-body -D "$HDR" -o "$BODY" -X POST "$URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" \
    ${SID:+-H "Mcp-Session-Id: $SID"} \
    -H "MCP-Protocol-Version: $VERSION" \
    -d "$1"
}

payload() { sed -n 's/^data: //p' "$BODY" | tail -n1 ; }

SID=""
post "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$VERSION\",\"capabilities\":{},\"clientInfo\":{\"name\":\"ci-smoke\",\"version\":\"1.0.0\"}}}"

NEGOTIATED=$(payload | jq -r '.result.protocolVersion')
[ "$NEGOTIATED" = "$VERSION" ] || { echo "FAIL: negotiated $NEGOTIATED, wanted $VERSION"; exit 1; }
echo "ok  protocol version $NEGOTIATED"

SID=$(awk -F': ' 'tolower($1)=="mcp-session-id" {print $2}' "$HDR" | tr -d '\r')
[ -n "$SID" ] || echo "warn: stateless server, no Mcp-Session-Id"

post '{"jsonrpc":"2.0","method":"notifications/initialized"}'
CODE=$(awk 'NR==1 {print $2}' "$HDR")
[ "$CODE" = "202" ] || { echo "FAIL: notification returned $CODE, expected 202"; exit 1; }
echo "ok  notification accepted with 202"

post '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
COUNT=$(payload | jq '.result.tools | length')
[ "$COUNT" -gt 0 ] || { echo "FAIL: tools/list returned no tools"; exit 1; }
echo "ok  tools/list returned $COUNT tools"

# Every non-read-only tool must declare an explicit destructiveHint.
UNANNOTATED=$(payload | jq -r '
  [ .result.tools[]
    | select((.annotations.readOnlyHint // false) == false)
    | select(.annotations.destructiveHint == null)
    | .name ] | join(",")')
[ -z "$UNANNOTATED" ] || { echo "FAIL: mutating tools without destructiveHint: $UNANNOTATED"; exit 1; }
echo "ok  all mutating tools carry an explicit destructiveHint"

post '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"__nonexistent__","arguments":{}}}' || true
payload | jq -e '.error.code == -32602 or .error.code == -32601' >/dev/null \
  || { echo "FAIL: unknown tool did not produce -32601/-32602"; exit 1; }
echo "ok  unknown tool rejected at the protocol layer"

[ -n "$SID" ] && curl -sS -o /dev/null -X DELETE "$URL" \
  -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID" \
  -H "MCP-Protocol-Version: $VERSION"
echo "PASS"
```

```
$ ./mcp-smoke.sh https://mcp.internal.example.com/mcp
ok  protocol version 2025-06-18
ok  notification accepted with 202
ok  tools/list returned 6 tools
ok  all mutating tools carry an explicit destructiveHint
ok  unknown tool rejected at the protocol layer
PASS
```

---

## 11. Failure diagnosis

### 11.1 Symptom → cause → check → fix

| Symptom | Most probable cause | Check | Fix |
|---|---|---|---|
| Server "connects" then immediately dies (stdio) | Server wrote non-MCP text to stdout | `2>/dev/null` the server and look for prose on stdout | Move all logging to stderr |
| `404` on every request after a working `initialize` | Session ID not echoed, or expired | `grep -i mcp-session-id` on the response headers; check server session TTL | Echo `Mcp-Session-Id`; on `404`, re-`initialize` |
| Random `404` under load, works with one replica | In-memory sessions + no affinity | Compare `mcp_active_sessions` per pod | Shared session store, or enable cookie affinity |
| Tool call returns after 60 s with a truncated stream | Proxy `proxy-read-timeout` default | `kubectl -n ingress-nginx logs ...` for upstream timeout | Raise `proxy-read-timeout`, disable buffering |
| No progress notifications reach the client | Response buffering in the proxy, or client not streaming | `curl -N` bypasses client buffering; if it then works, it is the client | `proxy-buffering: "off"` + `X-Accel-Buffering: no` |
| `-32601 Method not found` on `sampling/createMessage` | Client never declared the `sampling` capability | Inspect the `initialize` request params | Declare the capability, or remove the server-side dependency on it |
| Elicitation and structured output silently missing | Protocol downgrade during negotiation | Log `result.protocolVersion`; alert on it | Upgrade the server; pin a minimum revision |
| `401` with `WWW-Authenticate` on every call | Missing or wrong-audience token | Decode the JWT `aud` claim | Request a token with the correct `resource` indicator (RFC 8707) |
| `403` on a token that authenticates fine | Token issued for a different resource; server correctly refusing passthrough | Compare `aud` against the server's configured audience | Mint a token bound to this server |
| Model never selects a tool that clearly exists | Description too vague, or context blown out by a huge tool surface | Count `tools/list` bytes (§10.2) | Rewrite descriptions; split into focused servers |
| Model calls the same tool repeatedly | Error returned as `-32603` so the model cannot see it | Inspect the wire response | Return `isError: true` with actionable text |
| Client hangs forever on `initialize` | No timeout applied | Wire capture | Apply an initialize timeout and disconnect on expiry |
| Cancelled request still executes | Cancellation is best-effort; server had already started | Server-side trace | Implement cooperative cancellation in the tool handler |

### 11.2 Diagnosing the trust boundary

Two failure classes have no protocol error code because they are not protocol failures.

**Confused deputy.** The MCP server holds a credential (a static OAuth client, a service-account token) and acts on behalf of whoever asks. A user who should reach only namespace `dev` gets namespace `prod` because the server authorizes with its own identity, not theirs.

Detect it by comparing the identity in the inbound token against the identity used in the outbound call:

```
$ kubectl -n mcp logs deploy/mcp-inventory-server --since=15m \
  | jq -r 'select(.event == "tool_call")
           | [.subject, .tool, .downstream_identity, .namespace] | @tsv' \
  | sort | uniq -c | sort -rn | head

     41  alice@example.com   list_deployments     mcp-inventory-server-sa   payments
     18  bob@example.com     list_deployments     mcp-inventory-server-sa   payments
      3  bob@example.com     restart_deployment   mcp-inventory-server-sa   payments
```

Every row shows the same `downstream_identity` regardless of `subject` — that is the confused deputy, in production, right now. The fix is token exchange or impersonation so the downstream call carries the *user's* authority, plus per-user consent for dynamically registered clients.

**Token passthrough.** The specification forbids an MCP server from accepting a token that was not issued *for it* and forwarding it downstream. Verify with an audience mismatch probe:

```
$ TOKEN_FOR_OTHER_SERVICE=$(get-token --resource https://tickets.internal.example.com/api)
$ curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN_FOR_OTHER_SERVICE" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"aud-probe","version":"0.1.0"}}}'
401
```

`401` is the pass condition. A `200` means your server accepts any valid token from the issuer and is one prompt injection away from being a lateral-movement primitive.

Confirm the discovery chain is correct:

```
$ curl -sS -D- -o /dev/null -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"anon","version":"0.1.0"}}}' \
  | grep -i 'www-authenticate'
www-authenticate: Bearer resource_metadata="https://mcp.internal.example.com/.well-known/oauth-protected-resource"

$ curl -sS https://mcp.internal.example.com/.well-known/oauth-protected-resource | jq
{
  "resource": "https://mcp.internal.example.com/mcp",
  "authorization_servers": [
    "https://idp.internal.example.com/realms/platform"
  ],
  "scopes_supported": [
    "inventory.read",
    "inventory.write"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

That is the RFC 9728 Protected Resource Metadata document the client uses to find the authorization server. Without it, a `2025-06-18` client cannot complete authorization discovery at all.

### 11.3 The golden signals for an MCP server

| Signal | Metric | Why it is MCP-specific |
|---|---|---|
| Handshake success | `mcp_sessions_initialized_total` by `negotiated_version`, `outcome` | A downgrade is a silent capability loss, invisible to HTTP-level SLIs |
| Protocol error rate | `mcp_jsonrpc_errors_total` by `code`, `method` | Must exclude `isError` tool failures, which are normal |
| Tool call latency | `mcp_tool_call_duration_seconds` by `tool` | Per-tool, not aggregate: one slow tool poisons the agent loop |
| Tool error rate | `mcp_tool_errors_total` by `tool` | Business-level; drives description and schema improvements |
| Active sessions | `mcp_active_sessions` | The real capacity unit for a stateful transport, not RPS |
| Stream lifetime | `mcp_sse_stream_duration_seconds` | A bimodal distribution with a spike near your proxy timeout is the proxy killing streams |
| Surface size | `mcp_tools_advertised` and `mcp_tools_list_bytes` | Context-window cost, charged on every model turn |
| Consent outcomes | `mcp_elicitation_total` by `action` | `decline` vs `cancel` vs `accept` tells you whether the agent design is working |

---

## 12. Exam-focused summary

- Three participants: **host** (owns model and consent), **client** (one per server, protocol conformance and isolation), **server** (exposes capabilities). One client, one server, one session.
- The base protocol is **JSON-RPC 2.0**, bidirectional. Batching existed in `2025-03-26` and was **removed in `2025-06-18`**.
- Lifecycle: `initialize` → `notifications/initialized` → operation → shutdown. Versions are dates; the server may downgrade the client.
- **A capability not declared MUST NOT be used.**
- Server primitives and their control model: **tools** = model-controlled, **resources** = application-controlled and side-effect free, **prompts** = user-controlled.
- Client primitives: **sampling** (server asks for inference), **roots** (client declares URI boundaries), **elicitation** (server asks the user for flat structured input — never secrets).
- Two transports: **stdio** (subprocess, newline-delimited, stdout is protocol-only) and **Streamable HTTP** (single endpoint, POST + optional GET SSE, `Mcp-Session-Id`, `MCP-Protocol-Version`, `Last-Event-ID` resumption, `Origin` validation).
- Two error channels: **protocol errors** in `error` (client-facing) versus **tool errors** in `result.isError` (model-facing). Never confuse them.
- **Tool annotations are untrusted hints**, not enforcement. Defaults: `readOnlyHint` false, `destructiveHint` true, `idempotentHint` false, `openWorldHint` true.
- MCP servers are **OAuth 2.1 resource servers**: audience-bound tokens, PKCE mandatory, RFC 8707 resource indicators, RFC 9728 metadata discovery, and **no token passthrough**.
- Pagination cursors are **opaque** — never parse or persist them.

---

## Referencias

**Certification**

- MCPA certification page, Linux Foundation — https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/

**Specification**

- MCP specification index (all revisions) — https://modelcontextprotocol.io/specification
- Revision `2025-06-18` — https://modelcontextprotocol.io/specification/2025-06-18
- Architecture — https://modelcontextprotocol.io/specification/2025-06-18/architecture
- Base protocol — https://modelcontextprotocol.io/specification/2025-06-18/basic
- Lifecycle — https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Transports — https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Authorization — https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Security best practices — https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
- Utilities (ping, progress, cancellation, pagination) — https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/ping
- Server: tools — https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Server: resources — https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- Server: prompts — https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- Client: sampling — https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- Client: roots — https://modelcontextprotocol.io/specification/2025-06-18/client/roots
- Client: elicitation — https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- Specification changelog — https://modelcontextprotocol.io/specification/2025-06-18/changelog
- Schema and specification source repository — https://github.com/modelcontextprotocol/modelcontextprotocol

**Tooling**

- MCP Inspector — https://github.com/modelcontextprotocol/inspector
- Reference server implementations — https://github.com/modelcontextprotocol/servers
- SDK index — https://modelcontextprotocol.io/docs/sdk

**Underlying standards**

- JSON-RPC 2.0 Specification — https://www.jsonrpc.org/specification
- RFC 6570 — URI Template — https://www.rfc-editor.org/rfc/rfc6570
- RFC 7591 — OAuth 2.0 Dynamic Client Registration — https://www.rfc-editor.org/rfc/rfc7591
- RFC 8414 — OAuth 2.0 Authorization Server Metadata — https://www.rfc-editor.org/rfc/rfc8414
- RFC 8707 — Resource Indicators for OAuth 2.0 — https://www.rfc-editor.org/rfc/rfc8707
- RFC 9728 — OAuth 2.0 Protected Resource Metadata — https://www.rfc-editor.org/rfc/rfc9728
- RFC 5424 — The Syslog Protocol (logging severity levels) — https://www.rfc-editor.org/rfc/rfc5424
- HTML Living Standard, Server-Sent Events — https://html.spec.whatwg.org/multipage/server-sent-events.html

**Kubernetes and ingress references used in the manifests**

- Kubernetes NetworkPolicy — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Ingress NGINX annotations — https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- Prometheus Operator API — https://prometheus-operator.dev/docs/api-reference/api/