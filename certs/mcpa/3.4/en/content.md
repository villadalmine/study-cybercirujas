# 3.4 Protocol Primitives

**Certification:** Model Context Protocol Associate (MCPA) — exam version 2026-07-28
**Exam weight:** 6.5
**Reference specification revision:** `2025-06-18` (with explicit notes on `2025-03-26` and `2024-11-05` behaviour where the wire format differs)

---

## 1. Motivation: the architectural problem the primitives solve

### 1.1 The framing everybody gets wrong

The popular summary of MCP is "it solves the N×M integration problem": *N* models times *M* tools becomes *N* + *M* if everyone speaks one protocol. That is true, and it is also the least interesting thing about the protocol. Plain HTTP + OpenAPI already solves N×M. If integration arity were the whole problem, MCP would be a thin JSON-RPC skin over OpenAPI and there would be nothing to certify.

The real problem MCP addresses is **control-plane semantics**: *who* is allowed to decide that a given capability fires, and therefore *who* is accountable when it fires wrongly.

In a naive "function calling" architecture every capability collapses into one bucket: a JSON-schema-described function that the model may call at will. That single bucket is an operational disaster in production, because it forces three incompatible policies into one code path:

| Capability | Who should decide it fires | Failure mode when the model decides | Blast radius |
|---|---|---|---|
| `POST /refunds` | The human, or a policy engine | Model hallucinates a refund | Money leaves the company |
| `GET /runbooks/db-failover.md` | The host application, deterministically, as context | Model "forgets" to fetch it and improvises | Wrong remediation during an incident |
| "Summarise this incident in our postmortem format" | The user, explicitly | Model invents its own format | Inconsistent corpus, useless retrospectives |

Every one of those is "a function with a JSON schema" to a function-calling API. MCP refuses that collapse. It defines **distinct primitives with distinct control domains**, and the control domain is part of the protocol contract, not a convention in your prompt.

### 1.2 The control-domain triad

This is the single most exam-relevant idea in the topic, and the single most load-bearing idea in production:

- **Tools are *model*-controlled.** The model chooses, from the advertised list, which tool to invoke and with what arguments. The host is expected to interpose human approval, but the *initiative* is the model's.
- **Resources are *application*-controlled.** The host application decides which resources are pulled into context, when, and in what order. The model does not summon a resource; the application attaches it. (A host *may* expose resource selection to the model, but the protocol's default posture is application-driven.)
- **Prompts are *user*-controlled.** They surface as explicit user gestures — slash commands, menu entries, buttons. Neither the model nor the application invokes a prompt behind the user's back.

Read that triad as an **authorisation lattice**, because that is what it is operationally. When you are asked to onboard a new capability onto an MCP platform, the design question is not "what does the API look like" — it is "which of these three actors is accountable for each invocation." Getting that wrong is how you end up with an agent that quietly deletes a namespace because somebody modelled `kubectl delete` as a tool with `readOnlyHint` unset and no approval gate.

### 1.3 The inverse direction: why the client also exposes primitives

The second architectural move is **inversion of control**. A server that needs an LLM completion — to summarise a 400 KB log file before returning it, say — has two options:

1. Hold its own model API key, its own quota, its own egress path, its own vendor contract.
2. Ask the *client* to run the completion on its behalf.

Option 1 multiplies your secret sprawl by the number of MCP servers you run, fragments your spend telemetry, and puts an unaudited LLM egress path inside every sidecar. Option 2 is `sampling/createMessage`. Together with `roots/list` (filesystem/URI boundary declaration) and `elicitation/create` (structured mid-flight user input), it makes the client a capability provider too.

That is why the primitive set is **bidirectional**, and why "MCP is a client-server protocol" is an incomplete answer on the exam. It is a *peer* protocol built on JSON-RPC 2.0, with asymmetric but non-empty capability sets on both sides.

---

## 2. The complete primitive taxonomy

### 2.1 Server-offered primitives

| Primitive | Control domain | Capability key | Discovery | Invocation | Change notification |
|---|---|---|---|---|---|
| **Tools** | Model | `tools` | `tools/list` | `tools/call` | `notifications/tools/list_changed` |
| **Resources** | Application | `resources` | `resources/list`, `resources/templates/list` | `resources/read` | `notifications/resources/list_changed`, `notifications/resources/updated` |
| **Prompts** | User | `prompts` | `prompts/list` | `prompts/get` | `notifications/prompts/list_changed` |

### 2.2 Client-offered primitives

| Primitive | Consumer | Capability key | Method | Introduced |
|---|---|---|---|---|
| **Sampling** | Server requests an LLM turn from the client | `sampling` | `sampling/createMessage` | `2024-11-05` |
| **Roots** | Server discovers filesystem/URI boundaries | `roots` | `roots/list` + `notifications/roots/list_changed` | `2024-11-05` |
| **Elicitation** | Server requests structured input from the user | `elicitation` | `elicitation/create` | `2025-06-18` |

### 2.3 Utilities (cross-cutting, not primitives, but examinable)

| Utility | Direction | Methods / notifications | Capability gate |
|---|---|---|---|
| Ping | Either | `ping` | none — always available |
| Cancellation | Either | `notifications/cancelled` | none |
| Progress | Either | `notifications/progress` (opt-in via `_meta.progressToken`) | none |
| Logging | Server → client | `logging/setLevel`, `notifications/message` | `logging` (server) |
| Completion | Client → server | `completion/complete` | `completions` (server) |
| Pagination | Client → server | `cursor` / `nextCursor` on all `*/list` methods | none |

**Memorise the asymmetry:** `logging` is declared by the *server* even though the client is the one that calls `logging/setLevel`; the capability declares "I emit log notifications and I honour level changes." `completions` is likewise a server capability, declared explicitly as of `2025-06-18` (before that revision it was implicit).

---

## 3. The wire substrate: JSON-RPC 2.0 and the lifecycle

Every primitive is expressed as JSON-RPC 2.0. Three message shapes exist, and the exam will test that you can tell them apart:

- **Request** — has `id`, expects exactly one response. The `id` MUST NOT be `null` and MUST NOT be reused within a session (this is stricter than base JSON-RPC).
- **Response** — has the same `id`, and exactly one of `result` or `error`.
- **Notification** — has **no** `id`, and MUST NOT be answered.

> **Removed in `2025-06-18`:** JSON-RPC *batching* (an array of messages in one payload) was supported in `2025-03-26` and **removed** in `2025-06-18`. A client that emits a JSON array to a `2025-06-18` server will get a parse/validation failure. This is a very common real-world upgrade break and a plausible exam distractor.

### 3.1 The initialize handshake

Capability negotiation happens exactly once, before any primitive is usable. The client sends `initialize`:

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
      "name": "sre-copilot",
      "title": "SRE Copilot",
      "version": "4.2.1"
    }
  }
}
```

The server replies with the revision it will actually speak and its own capabilities:

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
      "name": "prod-observability-mcp",
      "title": "Production Observability",
      "version": "1.9.0"
    },
    "instructions": "Query Prometheus, Loki and the incident registry. All write operations require an approved change ticket ID."
  }
}
```

The client then sends the notification that opens the session:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}
```

### 3.2 Version negotiation semantics

`protocolVersion` is a **date string**, compared as an opaque identifier, not semver:

1. The client proposes the latest revision it supports.
2. If the server supports it, it echoes it. **Negotiation is complete.**
3. If not, the server responds with the latest revision *it* supports.
4. The client either accepts that revision or **disconnects**. There is no third round.

Before `initialize` completes, the only legal traffic is `initialize` itself and `ping`. The `initialize` request specifically **MUST NOT** be cancelled via `notifications/cancelled`.

### 3.3 Capability gating is a hard contract

If a server did not declare `resources`, a `resources/list` call MUST fail with `-32601 Method not found`. If a client did not declare `sampling`, the server MUST NOT call `sampling/createMessage`. "Declare everything and 501 the unimplemented ones" is a bug, not defensive programming: the client uses the capability set to decide what UI to render and what to put in the system prompt.

| Sub-capability | Meaning if `true` | Meaning if absent/`false` |
|---|---|---|
| `tools.listChanged` | Server will emit `notifications/tools/list_changed` | Client must treat the tool list as static for the session, or re-poll on its own schedule |
| `resources.subscribe` | Client may call `resources/subscribe` for per-URI change events | Client must poll `resources/read` |
| `resources.listChanged` | Server will emit `notifications/resources/list_changed` | Resource *inventory* is static for the session |
| `roots.listChanged` | Client will emit `notifications/roots/list_changed` | Server must call `roots/list` once and assume stability |

---

## 4. Tools — the model-controlled primitive

### 4.1 Anatomy of a tool definition

```json
{
  "name": "query_prometheus_range",
  "title": "Prometheus Range Query",
  "description": "Execute a PromQL range query against the production Prometheus federation endpoint. Returns downsampled series suitable for narrative analysis, never raw scrape resolution.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "PromQL expression. Must include a job or namespace selector."
      },
      "start": {
        "type": "string",
        "format": "date-time",
        "description": "RFC 3339 inclusive start of the range."
      },
      "end": {
        "type": "string",
        "format": "date-time",
        "description": "RFC 3339 inclusive end of the range."
      },
      "step": {
        "type": "string",
        "pattern": "^[0-9]+(ms|s|m|h)$",
        "default": "60s"
      }
    },
    "required": ["query", "start", "end"],
    "additionalProperties": false
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "resultType": {
        "type": "string",
        "enum": ["matrix", "vector", "scalar", "string"]
      },
      "seriesCount": {
        "type": "integer",
        "minimum": 0
      },
      "series": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "metric": {
              "type": "object",
              "additionalProperties": {
                "type": "string"
              }
            },
            "min": { "type": "number" },
            "max": { "type": "number" },
            "mean": { "type": "number" },
            "last": { "type": "number" }
          },
          "required": ["metric", "min", "max", "mean", "last"]
        }
      },
      "truncated": { "type": "boolean" }
    },
    "required": ["resultType", "seriesCount", "series", "truncated"]
  },
  "annotations": {
    "title": "Prometheus Range Query",
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": true
  }
}
```

### 4.2 Annotations are hints, and hints are untrusted

| Annotation | Default when omitted | Meaning | Only meaningful when |
|---|---|---|---|
| `readOnlyHint` | `false` | Tool does not mutate its environment | always |
| `destructiveHint` | `true` | Mutation may be non-additive (delete/overwrite) | `readOnlyHint` is `false` |
| `idempotentHint` | `false` | Repeat calls with identical args have no additional effect | `readOnlyHint` is `false` |
| `openWorldHint` | `true` | Tool touches an external, unbounded entity (web, third-party API) | always |

Note the defaults: **omitting annotations is the most dangerous declaration**, because the implied state is "mutating, destructive, non-idempotent, open world." That is deliberate — fail-closed.

The specification is explicit that these are **hints from an untrusted source**. A malicious or simply sloppy server can label `drop_database` as `readOnlyHint: true`. Annotations may drive *UX affordances* (badge colour, whether to pre-expand the approval dialog) but they MUST NOT be the sole basis of an authorisation decision. In production, authorisation belongs in a gateway that maps `(server identity, tool name)` to a policy, independent of anything the server says about itself.

### 4.3 The two error channels — the highest-yield distinction in the topic

MCP has **two** ways for a `tools/call` to go wrong, and they mean completely different things:

| | Protocol error | Tool execution error |
|---|---|---|
| Wire shape | JSON-RPC `error` object | JSON-RPC `result` with `isError: true` |
| Examples | Unknown tool name, malformed args, server not initialised | API returned 503, file not found, query timed out, division by zero |
| Codes | `-32601`, `-32602`, `-32603`, `-32700`, `-32600` | none — the detail is in `content` |
| Who sees it | The **host application** — plumbing failure | The **model** — it is fed back as context |
| Correct model behaviour | Nothing; the call never semantically happened | Read the message, adapt, retry or choose another approach |

Collapsing tool failures into JSON-RPC errors is the most common server-implementation bug in the wild. It blinds the model: it never learns that the API was rate-limited, so it cannot back off, cannot try the cached variant, cannot tell the user *why*. Conversely, returning `isError: true` for "you called a tool that does not exist" hides a genuine plumbing defect inside the model's context window, where your SLO dashboards will never see it.

Protocol error:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "error": {
    "code": -32602,
    "message": "Invalid params: 'step' does not match pattern ^[0-9]+(ms|s|m|h)$",
    "data": {
      "tool": "query_prometheus_range",
      "field": "step",
      "received": "1 minute"
    }
  }
}
```

Tool execution error:

```json
{
  "jsonrpc": "2.0",
  "id": 43,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Prometheus returned HTTP 422: expanding series: query processing would load too many samples into memory in query execution. Narrow the range or increase 'step'."
      }
    ],
    "isError": true
  }
}
```

### 4.4 Structured output and the dual-encoding rule

When a tool declares `outputSchema`, its results MUST include `structuredContent` that validates against that schema. For backward compatibility with clients that predate `2025-06-18` or that simply do not validate, the server SHOULD **also** return the same payload serialised as a `text` content block:

```json
{
  "jsonrpc": "2.0",
  "id": 44,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"resultType\":\"matrix\",\"seriesCount\":2,\"series\":[{\"metric\":{\"pod\":\"api-7d9f\"},\"min\":0.11,\"max\":0.94,\"mean\":0.38,\"last\":0.42},{\"metric\":{\"pod\":\"api-b31c\"},\"min\":0.09,\"max\":0.71,\"mean\":0.31,\"last\":0.29}],\"truncated\":false}"
      }
    ],
    "structuredContent": {
      "resultType": "matrix",
      "seriesCount": 2,
      "series": [
        {
          "metric": { "pod": "api-7d9f" },
          "min": 0.11,
          "max": 0.94,
          "mean": 0.38,
          "last": 0.42
        },
        {
          "metric": { "pod": "api-b31c" },
          "min": 0.09,
          "max": 0.71,
          "mean": 0.31,
          "last": 0.29
        }
      ],
      "truncated": false
    },
    "isError": false
  }
}
```

The duplication is not waste from the model's perspective — the text block is what lands in the context window; `structuredContent` is what your host code parses for charting, caching or policy checks without re-parsing prose.

### 4.5 Content block types

| `type` | Payload fields | Production use |
|---|---|---|
| `text` | `text` | Default. Everything the model must reason over. |
| `image` | `data` (base64), `mimeType` | Screenshots, rendered graphs. Expensive in tokens — gate behind an explicit tool. |
| `audio` | `data` (base64), `mimeType` | Voice transcription pipelines. |
| `resource_link` | `uri`, `name`, `mimeType`, `description` | **The scalability answer.** Return a pointer, not 40 MB of log. Client fetches via `resources/read` only if needed. |
| `resource` | `resource.uri` + (`text` \| `blob`), `mimeType` | Embedded resource. Inline the content *and* keep its URI identity for provenance. |

`resource_link` is the primitive that makes large-payload tools viable. A `fetch_pod_logs` tool that returns 200 000 tokens of log is an outage generator; one that returns three `resource_link` blocks with `description: "api-7d9f, 14:02–14:07 UTC, 12 MB"` lets the application decide what to actually pay for.

> A `resource_link` is **not** guaranteed to appear in `resources/list`. Tools may mint ephemeral, unlisted URIs. Do not assume list-membership implies readability or vice versa.

---

## 5. Resources — the application-controlled primitive

### 5.1 URI identity and templates

Every resource is identified by a URI. The scheme carries meaning to the host:

```
file:///srv/runbooks/db-failover.md
https://wiki.internal/ops/slo-definitions
git://repo/main/deploy/values-prod.yaml
prometheus://prod/alerts/active
incident://2026-09-14/INC-4471/timeline
```

Custom schemes are legal and common. `file://` and `https://` carry host-specific handling (a client may refuse to read `file://` outside its declared roots).

Direct resources are enumerated by `resources/list`. **Parameterised** resources are declared as RFC 6570 URI templates via `resources/templates/list`:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "resourceTemplates": [
      {
        "uriTemplate": "incident://{date}/{incident_id}/timeline",
        "name": "incident_timeline",
        "title": "Incident Timeline",
        "description": "Reconstructed timeline for one incident, merging alerts, deploys and chat.",
        "mimeType": "text/markdown",
        "annotations": {
          "audience": ["assistant"],
          "priority": 0.9
        }
      },
      {
        "uriTemplate": "prometheus://{cluster}/alerts/{state}",
        "name": "prometheus_alerts",
        "title": "Prometheus Alerts",
        "description": "Alerts in a given state (firing, pending, inactive) for one cluster.",
        "mimeType": "application/json"
      }
    ]
  }
}
```

Templates are **not** a hidden tool-call surface. There is no argument validation handshake, no approval dialog, no `isError`. They exist so a host can build a URI deterministically from state it already has. If your "template" needs the model to guess values, you have modelled a tool as a resource.

### 5.2 Reading

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "resources/read",
  "params": {
    "uri": "incident://2026-09-14/INC-4471/timeline"
  }
}
```

A single read may return **multiple** contents — a directory URI legitimately expands to its children:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "contents": [
      {
        "uri": "incident://2026-09-14/INC-4471/timeline",
        "name": "INC-4471 timeline",
        "title": "INC-4471 — checkout latency regression",
        "mimeType": "text/markdown",
        "text": "# INC-4471\n\n- 13:58Z deploy checkout@v2.14.0 to prod-eu\n- 14:02Z HighLatency firing (p99 2.4s)\n- 14:09Z rollback initiated\n- 14:14Z p99 back to 210ms\n"
      }
    ]
  }
}
```

Binary resources use `blob` (base64) instead of `text`. A content object carries exactly one of the two.

### 5.3 Resource annotations drive context budgeting

| Field | Type | Operational use |
|---|---|---|
| `audience` | array of `"user"` \| `"assistant"` | `["user"]` means: render in the UI, do **not** spend context tokens on it |
| `priority` | number, 0.0–1.0 | 1.0 = effectively required; 0.0 = entirely optional. The host's context packer sorts on this |
| `lastModified` | ISO 8601 timestamp | Cache validation, staleness warnings, and "this runbook was last touched in 2023" flags |

On a host with a 200 K context and a server exposing 4 000 resources, `priority` is the difference between a working agent and one that fills its window with changelogs.

### 5.4 Subscriptions

Two *different* notifications exist and they are routinely confused:

| Notification | Gated by | Fires when | Payload |
|---|---|---|---|
| `notifications/resources/list_changed` | `resources.listChanged` | The **inventory** changes — a resource appeared or disappeared | none |
| `notifications/resources/updated` | `resources.subscribe` + an explicit `resources/subscribe` call | The **contents** of one subscribed URI changed | `{ "uri": ... }` |

`notifications/resources/updated` carries only the URI — **not** the new content. The client must call `resources/read` to fetch it. That is deliberate: it keeps the notification cheap and lets the client decide whether the update is worth the tokens.

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/resources/updated",
  "params": {
    "uri": "prometheus://prod-eu/alerts/firing"
  }
}
```

### 5.5 Trade-off: subscribe vs. poll

| Dimension | `resources/subscribe` | Client-side polling |
|---|---|---|
| Latency to detect change | Near-zero | Half the poll interval on average |
| Server state | Per-connection subscription table — **must** be reaped on disconnect | Stateless |
| Horizontal scaling | Requires sticky sessions or a shared pub/sub bus | Trivially scalable |
| Failure mode | Silent: subscription dies, client believes data is fresh | Loud: poll fails, client knows |
| Cost at rest | One long-lived stream per client | One request per interval per resource |

**Production guidance:** subscribe for a small set of high-value, fast-moving URIs (active alerts, incident state). Poll for everything else. A 3 000-resource subscription table behind a load balancer without sticky routing is an incident waiting to happen — and the failure is *silent*, which is the worst class.

### 5.6 Trade-off: should this be a Tool or a Resource?

The same underlying read can be modelled either way. Choose deliberately.

| Criterion | Model it as a **Resource** | Model it as a **Tool** |
|---|---|---|
| Who initiates | Application, deterministically | Model, opportunistically |
| Addressing | Stable URI; same URI → same thing | Arguments; no identity |
| Idempotence | Assumed | Declared via `idempotentHint` |
| Side effects | None, ever | Permitted |
| Approval UX | None — application already decided | Human-in-the-loop expected |
| Cacheable by URI | Yes, with `lastModified` | Not by the protocol |
| Search / query semantics | Poor — templates are not a query language | Natural |
| Discovery cost | `resources/list` can be huge; needs pagination | Tool list is small and curated |

Heuristic: **if the model must supply a value it has to think about, it is a tool.** `get_file(path)` where the path comes from a `roots/list` walk is a resource. `search_logs(query, since)` is a tool. Exposing a search engine as a URI template is a classic anti-pattern — you lose approval gating, error semantics and argument validation in one move.

---

## 6. Prompts — the user-controlled primitive

Prompts are parameterised, server-authored message templates surfaced as explicit user gestures.

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "prompts": [
      {
        "name": "postmortem_draft",
        "title": "Draft Postmortem",
        "description": "Produce a blameless postmortem draft in the company template from an incident ID.",
        "arguments": [
          {
            "name": "incident_id",
            "description": "Incident identifier, e.g. INC-4471",
            "required": true
          },
          {
            "name": "depth",
            "description": "One of: summary, standard, deep",
            "required": false
          }
        ]
      }
    ]
  }
}
```

`prompts/get` returns fully-rendered messages, and those messages may **embed resources**:

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "description": "Blameless postmortem draft for INC-4471",
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "Draft a blameless postmortem for INC-4471 using the company template. Contributing factors must be phrased as system properties, never as individual actions."
        }
      },
      {
        "role": "user",
        "content": {
          "type": "resource",
          "resource": {
            "uri": "incident://2026-09-14/INC-4471/timeline",
            "mimeType": "text/markdown",
            "text": "# INC-4471\n\n- 13:58Z deploy checkout@v2.14.0 to prod-eu\n- 14:02Z HighLatency firing (p99 2.4s)\n- 14:09Z rollback initiated\n- 14:14Z p99 back to 210ms\n"
          }
        }
      }
    ]
  }
}
```

**Why this primitive exists at all:** it is the only mechanism by which the *server* — the team that owns the domain — can ship expertise as a versioned, deployable artefact. The alternative is every user reinventing the prompt, and your postmortem corpus becoming unqueryable because no two entries share a structure. Treat prompts as code: they live in the repo, they get reviewed, they get a version, and `notifications/prompts/list_changed` tells running clients that the catalogue moved.

### 6.1 Argument completion

`completion/complete` gives the user a real autocomplete surface rather than free-text guessing:

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "completion/complete",
  "params": {
    "ref": {
      "type": "ref/prompt",
      "name": "postmortem_draft"
    },
    "argument": {
      "name": "incident_id",
      "value": "INC-44"
    },
    "context": {
      "arguments": {
        "depth": "deep"
      }
    }
  }
}
```

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {
    "completion": {
      "values": ["INC-4471", "INC-4472", "INC-4448"],
      "total": 3,
      "hasMore": false
    }
  }
}
```

The `ref` may also be `{"type": "ref/resource", "uri": "incident://{date}/{incident_id}/timeline"}` to complete a URI-template variable. `values` is capped at 100 entries per response; `total` reports the true count. The `context.arguments` field (added in `2025-06-18`) lets completion depend on already-resolved arguments — completing `incident_id` differently once `cluster` is known.

---

## 7. Client primitives

### 7.1 Sampling — inverted LLM access

```json
{
  "jsonrpc": "2.0",
  "id": 21,
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "Compress the following 8000 log lines into the five distinct error signatures present, with counts and first/last timestamps. Output JSON only."
        }
      }
    ],
    "modelPreferences": {
      "hints": [
        { "name": "claude-haiku" },
        { "name": "claude" }
      ],
      "costPriority": 0.9,
      "speedPriority": 0.8,
      "intelligencePriority": 0.2
    },
    "systemPrompt": "You are a log-reduction function. You never speculate about causes.",
    "includeContext": "thisServer",
    "maxTokens": 1200,
    "temperature": 0.0,
    "stopSequences": ["\n\n---"]
  }
}
```

| Field | Semantics that trip people up |
|---|---|
| `modelPreferences.hints` | **Advisory substrings**, evaluated in order. `"claude-haiku"` may match any provider's nearest equivalent. The client is free to ignore hints entirely. |
| `costPriority` / `speedPriority` / `intelligencePriority` | Each 0.0–1.0, **independent** — they do not need to sum to 1. They express a preference surface, not a budget split. |
| `includeContext` | `"none"` (default posture), `"thisServer"`, `"allServers"`. The **client** decides what that actually means and may downgrade it. `"allServers"` is a cross-server information-flow decision; treat it as a privilege. |
| `maxTokens` | A request, not a guarantee. Check `stopReason`. |

The response tells you which model actually ran:

```json
{
  "jsonrpc": "2.0",
  "id": 21,
  "result": {
    "role": "assistant",
    "content": {
      "type": "text",
      "text": "{\"signatures\":[{\"pattern\":\"connection reset by peer\",\"count\":4412,\"first\":\"14:02:11Z\",\"last\":\"14:08:59Z\"}]}"
    },
    "model": "claude-haiku-4-5-20251001",
    "stopReason": "endTurn"
  }
}
```

**The human-in-the-loop requirement is normative.** The specification states that clients SHOULD present sampling requests for human review — both the outgoing prompt and the returned completion. A server that assumes uninterrupted sampling throughput will deadlock behind an approval dialog. Design sampling calls to be *few, chunky and explainable*, never a per-item loop.

### 7.2 Roots — boundary declaration, not enforcement

```json
{
  "jsonrpc": "2.0",
  "id": 31,
  "result": {
    "roots": [
      {
        "uri": "file:///home/sre/workspaces/platform-infra",
        "name": "platform-infra"
      },
      {
        "uri": "file:///home/sre/workspaces/runbooks",
        "name": "runbooks"
      }
    ]
  }
}
```

Two hard facts that get tested:

1. `file://` URIs are what the specification calls out, but roots are **not restricted** to `file://` — an HTTP root scoping a server to one API prefix is legal.
2. **Roots are informational.** The protocol grants no enforcement. A malicious server will read outside them anyway. Real containment is a sandbox, a container filesystem, a seccomp profile, a mount namespace — not a JSON array. Roots exist so that a *well-behaved* server can scope its own indexing and avoid asking about paths that do not exist.

`notifications/roots/list_changed` fires when the user opens a different project; the server re-calls `roots/list` in response.

### 7.3 Elicitation — structured mid-flight input

Introduced in `2025-06-18`. A server mid-operation discovers it needs input the model does not have and should not invent:

```json
{
  "jsonrpc": "2.0",
  "id": 41,
  "method": "elicitation/create",
  "params": {
    "message": "Rolling back checkout to v2.13.4 in prod-eu requires an approved change ticket. Provide it to continue.",
    "requestedSchema": {
      "type": "object",
      "properties": {
        "change_ticket": {
          "type": "string",
          "title": "Change ticket",
          "description": "CHG-nnnnn identifier from the change registry",
          "pattern": "^CHG-[0-9]{5}$"
        },
        "drain_connections": {
          "type": "boolean",
          "title": "Drain connections first",
          "description": "Wait for in-flight requests before terminating pods",
          "default": true
        },
        "blast_radius": {
          "type": "string",
          "title": "Blast radius",
          "enum": ["single-pod", "single-az", "whole-region"],
          "enumNames": ["One pod", "One availability zone", "Entire region"]
        }
      },
      "required": ["change_ticket", "blast_radius"]
    }
  }
}
```

The schema is deliberately **flat and primitive-only**: `string` (with `format` such as `email`/`uri`/`date`/`date-time`, plus `minLength`/`maxLength`/`pattern`), `number`/`integer` (with `minimum`/`maximum`), `boolean`, and `enum`. **No nested objects, no arrays.** That restriction is not laziness — it guarantees any client can render the request as a plain form without shipping a JSON-Schema form engine. If your elicitation needs an array, you have designed a wizard; split it into successive elicitations.

The response is a three-state union, and conflating the last two is a real bug class:

```json
{
  "jsonrpc": "2.0",
  "id": 41,
  "result": {
    "action": "accept",
    "content": {
      "change_ticket": "CHG-88213",
      "drain_connections": true,
      "blast_radius": "single-az"
    }
  }
}
```

| `action` | Meaning | `content` present | Correct server behaviour |
|---|---|---|---|
| `accept` | User explicitly submitted | yes | Validate against your own schema anyway, then proceed |
| `decline` | User explicitly refused | no | Abort **this** operation; report refusal to the model as a tool result |
| `cancel` | User dismissed without deciding (closed the dialog, timeout) | no | Abort; do **not** treat as refusal, do **not** retry automatically |

Normative security rule: **servers MUST NOT use elicitation to request secrets** — passwords, API keys, tokens. The elicitation payload traverses the client and lands in an application whose logging you do not control. Credentials belong in the transport's auth layer (OAuth 2.1 for HTTP), never in a primitive payload.

---

## 8. Utilities in production

### 8.1 Pagination

Every `*/list` method is cursor-paginated. Cursors are **opaque** — never parse one, never construct one, never persist one across sessions.

```json
{
  "jsonrpc": "2.0",
  "id": 51,
  "method": "resources/list",
  "params": {
    "cursor": "eyJvZmZzZXQiOjUwMCwic25hcCI6IjIwMjYtMDktMTdUMDk6MTQ6MDBaIn0"
  }
}
```

The absence of `nextCursor` in a result means the end of the collection. A page may legitimately be empty and still carry a `nextCursor`; "empty page" does not mean "done."

### 8.2 Progress

Opt-in per request, via `_meta.progressToken`:

```json
{
  "jsonrpc": "2.0",
  "id": 61,
  "method": "tools/call",
  "params": {
    "name": "reindex_runbook_corpus",
    "arguments": {
      "root": "file:///home/sre/workspaces/runbooks"
    },
    "_meta": {
      "progressToken": "reindex-2026-09-17-a41f"
    }
  }
}
```

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/progress",
  "params": {
    "progressToken": "reindex-2026-09-17-a41f",
    "progress": 340,
    "total": 1275,
    "message": "Embedding runbooks/networking/bgp-flap.md"
  }
}
```

`total` is optional; when absent the client shows an indeterminate spinner. `progress` MUST increase monotonically. Progress notifications MUST stop after the request completes — a server that keeps emitting for a finished token is leaking a work handle.

### 8.3 Cancellation

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/cancelled",
  "params": {
    "requestId": 61,
    "reason": "User aborted the reindex."
  }
}
```

Cancellation is **advisory and racy**. The response may already be in flight; the receiver must tolerate a response for a request it cancelled, and simply ignore it. `initialize` MUST NOT be cancelled.

### 8.4 Logging

Levels follow RFC 5424: `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`.

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/message",
  "params": {
    "level": "warning",
    "logger": "prometheus-client",
    "data": {
      "event": "query_retry",
      "attempt": 2,
      "endpoint": "https://prom-federate.prod.internal/api/v1/query_range",
      "latency_ms": 9812
    }
  }
}
```

`data` is any JSON value — an object is far more useful than a string once these land in Loki. Normative: log messages MUST NOT contain credentials, secrets or PII. On stdio transport this is doubly important because **`stdout` is the protocol channel**: all human-readable logging on stdio servers goes to `stderr` or nowhere. A stray `print()` in a stdio server corrupts the JSON-RPC stream and produces the single most confusing failure mode in MCP.

---

## 9. Transport trade-offs (where primitives actually live)

| Dimension | `stdio` | Streamable HTTP (`2025-03-26`+) | HTTP+SSE (`2024-11-05`, deprecated) |
|---|---|---|---|
| Endpoints | none — pipes | one (`POST`/`GET`/`DELETE` on `/mcp`) | two (`/sse` + `/messages`) |
| Server→client push | Always available over the pipe | `GET` with `Accept: text/event-stream`, or SSE on a `POST` response | Dedicated SSE endpoint |
| Session identity | Process lifetime | `Mcp-Session-Id` header | Endpoint-embedded session |
| Horizontal scale | 1:1 with client | Yes, with session affinity or shared state | Poor |
| Auth | Inherited from process/env | OAuth 2.1, `Authorization: Bearer` | Ad hoc |
| Resumability | None — restart | SSE `id:` + `Last-Event-ID` header | Limited |
| Observability | Hard — no L7 hop | Standard HTTP telemetry | Standard HTTP telemetry |
| Right for | Desktop hosts, local filesystem/git access | Anything multi-tenant or remote | Nothing new |

Mandatory HTTP details as of `2025-06-18`:

- Client `POST` MUST send `Accept: application/json, text/event-stream`.
- After initialisation, every HTTP request MUST carry `MCP-Protocol-Version: <negotiated>`. A server that receives no such header SHOULD assume `2025-03-26` for backwards compatibility.
- Servers MUST validate the `Origin` header (DNS-rebinding defence) and SHOULD bind to `127.0.0.1` when running locally.
- `Mcp-Session-Id`, if issued, MUST be echoed on every subsequent request. HTTP `404` on a session-bearing request means "session gone" — the client MUST re-`initialize`.
- Servers MUST validate that a bearer token was issued *for them* (RFC 8707 resource indicators). Blindly accepting an upstream token is the confused-deputy vulnerability the spec calls out by name.

---

## 10. Production infrastructure

A complete, deployable manifest set for a Streamable-HTTP MCP server on Kubernetes. Session affinity, correct probes (health endpoints separate from `/mcp`, which requires POST), egress lockdown, and alerting on the primitive-level SLIs that actually matter.

### 10.1 Namespace, configuration and secrets

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-platform
  labels:
    app.kubernetes.io/part-of: mcp-platform
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: obs-mcp-config
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: obs-mcp
data:
  MCP_TRANSPORT: "streamable-http"
  MCP_HTTP_PATH: "/mcp"
  MCP_HTTP_PORT: "8080"
  MCP_HEALTH_PORT: "8081"
  MCP_PROTOCOL_VERSIONS: "2025-06-18,2025-03-26"
  MCP_SESSION_TTL_SECONDS: "1800"
  MCP_MAX_CONCURRENT_TOOL_CALLS: "16"
  MCP_TOOL_TIMEOUT_SECONDS: "45"
  MCP_RESOURCE_SUBSCRIPTION_LIMIT: "64"
  MCP_LOG_LEVEL: "info"
  MCP_ALLOWED_ORIGINS: "https://copilot.internal,https://copilot-staging.internal"
  PROMETHEUS_URL: "https://prom-federate.prod.internal"
  LOKI_URL: "https://loki-gateway.prod.internal"
  primitives.yaml: |
    tools:
      - name: query_prometheus_range
        enabled: true
        annotations:
          readOnlyHint: true
          destructiveHint: false
          idempotentHint: true
          openWorldHint: true
        timeout_seconds: 45
        rate_limit_per_minute: 30
      - name: query_loki
        enabled: true
        annotations:
          readOnlyHint: true
          destructiveHint: false
          idempotentHint: true
          openWorldHint: true
        timeout_seconds: 60
        rate_limit_per_minute: 20
      - name: silence_alert
        enabled: true
        annotations:
          readOnlyHint: false
          destructiveHint: false
          idempotentHint: true
          openWorldHint: false
        timeout_seconds: 15
        rate_limit_per_minute: 5
        requires_elicitation: true
    resources:
      list_changed: true
      subscribe: true
      templates:
        - uriTemplate: "incident://{date}/{incident_id}/timeline"
          mimeType: "text/markdown"
        - uriTemplate: "prometheus://{cluster}/alerts/{state}"
          mimeType: "application/json"
    prompts:
      list_changed: true
      catalogue:
        - postmortem_draft
        - slo_burn_analysis
        - alert_triage
    logging:
      enabled: true
      default_level: info
---
apiVersion: v1
kind: Secret
metadata:
  name: obs-mcp-secrets
  namespace: mcp-platform
type: Opaque
stringData:
  PROMETHEUS_TOKEN: "REPLACE_VIA_EXTERNAL_SECRETS"
  LOKI_TOKEN: "REPLACE_VIA_EXTERNAL_SECRETS"
  OAUTH_INTROSPECTION_SECRET: "REPLACE_VIA_EXTERNAL_SECRETS"
```

### 10.2 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: obs-mcp
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: obs-mcp
    app.kubernetes.io/component: mcp-server
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
      app.kubernetes.io/name: obs-mcp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: obs-mcp
        app.kubernetes.io/component: mcp-server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8081"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: obs-mcp
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      terminationGracePeriodSeconds: 45
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: obs-mcp
      containers:
        - name: server
          image: registry.internal/mcp/obs-mcp:1.9.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: mcp
              containerPort: 8080
              protocol: TCP
            - name: health
              containerPort: 8081
              protocol: TCP
          envFrom:
            - configMapRef:
                name: obs-mcp-config
            - secretRef:
                name: obs-mcp-secrets
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: OTEL_SERVICE_NAME
              value: "obs-mcp"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
          volumeMounts:
            - name: config
              mountPath: /etc/mcp
              readOnly: true
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet:
              path: /healthz
              port: health
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet:
              path: /readyz
              port: health
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: health
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 4
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
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
      volumes:
        - name: config
          configMap:
            name: obs-mcp-config
            items:
              - key: primitives.yaml
                path: primitives.yaml
        - name: tmp
          emptyDir:
            sizeLimit: 128Mi
```

The `preStop` sleep is not cargo cult: Streamable HTTP holds long-lived SSE streams, and terminating a pod the instant it leaves the endpoint list drops those streams mid-`notifications/progress`. Fifteen seconds of grace lets in-flight `tools/call` requests drain and lets the client observe a clean stream close rather than a reset.

### 10.3 Service, session affinity and ingress

```yaml
apiVersion: v1
kind: Service
metadata:
  name: obs-mcp
  namespace: mcp-platform
  labels:
    app.kubernetes.io/name: obs-mcp
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: obs-mcp
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 1800
  ports:
    - name: mcp
      port: 80
      targetPort: mcp
      protocol: TCP
    - name: health
      port: 8081
      targetPort: health
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: obs-mcp
  namespace: mcp-platform
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/upstream-hash-by: "$http_mcp_session_id"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header X-Accel-Buffering no;
      proxy_http_version 1.1;
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - "mcp.prod.internal"
      secretName: obs-mcp-tls
  rules:
    - host: "mcp.prod.internal"
      http:
        paths:
          - path: /mcp
            pathType: Prefix
            backend:
              service:
                name: obs-mcp
                port:
                  name: mcp
```

Three settings here exist purely because of MCP primitive semantics:

- `proxy-buffering: "off"` and `X-Accel-Buffering: no` — without them nginx buffers the SSE stream and `notifications/progress` arrives in one burst at the end, which is worse than useless.
- `upstream-hash-by: "$http_mcp_session_id"` — routes by the `Mcp-Session-Id` header, which is stricter and more correct than `ClientIP` affinity when clients sit behind a NAT. Resource subscriptions and session state live on one replica.
- `proxy-read-timeout: "3600"` — a `GET`-opened server→client stream is idle by design between notifications.

### 10.4 Egress lockdown

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: obs-mcp-egress
  namespace: mcp-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: obs-mcp
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
          port: 8081
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
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9090
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
          podSelector:
            matchLabels:
              app.kubernetes.io/name: loki-gateway
      ports:
        - protocol: TCP
          port: 3100
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
          podSelector:
            matchLabels:
              app.kubernetes.io/name: otel-collector
      ports:
        - protocol: TCP
          port: 4317
```

This is the containment layer that `roots` cannot give you. An MCP server whose declared tools are all `readOnlyHint: true` and whose egress policy permits only Prometheus and Loki is *actually* read-only; one that merely says so is not.

### 10.5 Alerting on primitive-level SLIs

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: obs-mcp
  namespace: mcp-platform
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: obs-mcp
  namespaceSelector:
    matchNames:
      - mcp-platform
  endpoints:
    - port: health
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: obs-mcp-primitives
  namespace: mcp-platform
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp.primitives
      interval: 30s
      rules:
        - alert: MCPToolExecutionErrorRateHigh
          expr: |
            sum by (mcp_server, tool) (rate(mcp_tool_calls_total{outcome="tool_error"}[5m]))
            /
            clamp_min(sum by (mcp_server, tool) (rate(mcp_tool_calls_total[5m])), 0.001)
            > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Tool {{ $labels.tool }} is returning isError above 5%"
            description: "Execution errors reach the model as context, not as HTTP failures. Check the upstream this tool wraps."
        - alert: MCPProtocolErrorsPresent
          expr: |
            sum by (mcp_server, method, code) (rate(mcp_protocol_errors_total[5m]))
            > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "JSON-RPC protocol errors on {{ $labels.method }} (code {{ $labels.code }})"
            description: "Protocol errors mean a plumbing defect: bad capability gating, schema drift or an uninitialised session. This is never the model's fault."
        - alert: MCPToolCallLatencyP99High
          expr: |
            histogram_quantile(
              0.99,
              sum by (le, mcp_server, tool) (rate(mcp_tool_call_duration_seconds_bucket[5m]))
            )
            > 30
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "p99 tools/call latency above 30s for {{ $labels.tool }}"
            description: "Approaching MCP_TOOL_TIMEOUT_SECONDS. Emit notifications/progress or split the tool."
        - alert: MCPResourceSubscriptionLeak
          expr: |
            sum by (pod) (mcp_resource_subscriptions_active)
            >
            on() group_left() (max(mcp_sessions_active) * 64)
          for: 15m
          labels:
            severity: warning
            runbook: "https://wiki.internal/ops/mcp-subscription-leak"
          annotations:
            summary: "Resource subscriptions exceed the per-session ceiling"
            description: "Subscriptions are not being reaped on disconnect. Clients will believe stale data is fresh."
        - alert: MCPSessionNotFoundSpike
          expr: |
            sum by (mcp_server) (rate(mcp_http_responses_total{status="404"}[5m]))
            > 0.5
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Clients are hitting expired or misrouted sessions"
            description: "Either session affinity broke at the ingress, or session TTL is shorter than real conversations."
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: obs-mcp
  namespace: mcp-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: obs-mcp
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
          name: mcp_sessions_active
        target:
          type: AverageValue
          averageValue: "80"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
```

The 600-second `scaleDown` stabilisation window is deliberate: scaling in a stateful MCP replica destroys its session table and every resource subscription on it. Prefer slow, conservative scale-in.

### 10.6 A stdio server under systemd (the local case)

```ini
[Unit]
Description=Local MCP filesystem server
After=network.target

[Service]
Type=simple
User=mcp
Group=mcp
ExecStart=/usr/local/bin/mcp-fs-server --root /srv/runbooks
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/srv/runbooks
CapabilityBoundingSet=
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
```

Note `StandardOutput=journal`: under systemd the child's stdout is *not* the protocol channel — a supervised stdio server must be launched by the MCP **host**, which owns the pipes. A systemd unit is appropriate only for an stdio server fronted by a local socket bridge, never for one the host spawns directly. The hardening directives are the real containment for a server whose only declared boundary is a `roots` array.

---

## 11. CLI verification

### 11.1 Enumerating primitives with the MCP Inspector

```
$ npx @modelcontextprotocol/inspector --cli \
    --transport http \
    --server-url https://mcp.prod.internal/mcp \
    --method tools/list
```

```
{
  "tools": [
    {
      "name": "query_prometheus_range",
      "title": "Prometheus Range Query",
      "description": "Execute a PromQL range query against the production Prometheus federation endpoint.",
      "inputSchema": { "type": "object", "properties": { ... }, "required": ["query","start","end"] },
      "outputSchema": { "type": "object", "properties": { ... } },
      "annotations": { "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
    },
    {
      "name": "query_loki",
      "title": "Loki Log Query",
      "inputSchema": { "type": "object", "properties": { ... }, "required": ["selector","since"] },
      "annotations": { "readOnlyHint": true, "idempotentHint": true }
    },
    {
      "name": "silence_alert",
      "title": "Silence an Alert",
      "inputSchema": { "type": "object", "properties": { ... }, "required": ["alertname","duration"] },
      "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
    }
  ]
}
```

```
$ npx @modelcontextprotocol/inspector --cli \
    --transport http --server-url https://mcp.prod.internal/mcp \
    --method tools/call \
    --tool-name query_prometheus_range \
    --tool-arg query='sum by (pod) (rate(http_requests_total{job="checkout"}[5m]))' \
    --tool-arg start=2026-09-14T13:50:00Z \
    --tool-arg end=2026-09-14T14:20:00Z \
    --tool-arg step=60s
```

```
{
  "content": [
    {
      "type": "text",
      "text": "{\"resultType\":\"matrix\",\"seriesCount\":2,\"series\":[...],\"truncated\":false}"
    }
  ],
  "structuredContent": {
    "resultType": "matrix",
    "seriesCount": 2,
    "truncated": false
  },
  "isError": false
}
```

Resources and prompts:

```
$ npx @modelcontextprotocol/inspector --cli --transport http \
    --server-url https://mcp.prod.internal/mcp --method resources/templates/list
```

```
{
  "resourceTemplates": [
    { "uriTemplate": "incident://{date}/{incident_id}/timeline", "name": "incident_timeline", "mimeType": "text/markdown" },
    { "uriTemplate": "prometheus://{cluster}/alerts/{state}", "name": "prometheus_alerts", "mimeType": "application/json" }
  ]
}
```

```
$ npx @modelcontextprotocol/inspector --cli --transport http \
    --server-url https://mcp.prod.internal/mcp \
    --method resources/read --uri "incident://2026-09-14/INC-4471/timeline"
```

```
{
  "contents": [
    {
      "uri": "incident://2026-09-14/INC-4471/timeline",
      "mimeType": "text/markdown",
      "text": "# INC-4471\n\n- 13:58Z deploy checkout@v2.14.0 to prod-eu\n- 14:02Z HighLatency firing (p99 2.4s)\n..."
    }
  ]
}
```

For a local stdio server, the same CLI drives the process directly:

```
$ npx @modelcontextprotocol/inspector --cli node ./build/index.js --method prompts/list
```

### 11.2 Raw Streamable HTTP with curl

This is what you reach for when the Inspector says "it works" and the production client does not. It exercises the exact headers.

```
$ curl -sS -D /tmp/init.hdr https://mcp.prod.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    -H 'Origin: https://copilot.internal' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{}},"clientInfo":{"name":"curl-probe","version":"1.0.0"}}}' \
  | tee /tmp/init.json | jq -r '.result.protocolVersion, .result.serverInfo.name'
```

```
2025-06-18
prod-observability-mcp
```

```
$ grep -i '^mcp-session-id' /tmp/init.hdr
```

```
mcp-session-id: 3f9a1c72-0b64-4f1d-9a6e-0c5b2e7d8811
```

```
$ export SID=$(awk 'BEGIN{IGNORECASE=1} /^mcp-session-id:/ {print $2}' /tmp/init.hdr | tr -d '\r')
$ curl -sS https://mcp.prod.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SID}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' -o /dev/null -w '%{http_code}\n'
```

```
202
```

`202 Accepted` with an empty body is the correct response to a notification — there is nothing to return. Anything else (a `200` with a JSON-RPC envelope, in particular) means the server is treating a notification as a request.

```
$ curl -sS https://mcp.prod.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SID}" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq -r '.result.tools[] | [.name, (.annotations.readOnlyHint // false), (.annotations.destructiveHint // true)] | @tsv'
```

```
query_prometheus_range	true	false
query_loki	true	false
silence_alert	false	false
```

Observing the server→client stream:

```
$ curl -sS -N https://mcp.prod.internal/mcp \
    -H 'Accept: text/event-stream' \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SID}"
```

```
event: message
id: 17
data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"subscriptions","data":{"event":"subscribed","uri":"prometheus://prod-eu/alerts/firing"}}}

event: message
id: 18
data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"prometheus://prod-eu/alerts/firing"}}

event: message
id: 19
data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
```

Resuming after a drop — this is what `Last-Event-ID` is for:

```
$ curl -sS -N https://mcp.prod.internal/mcp \
    -H 'Accept: text/event-stream' \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SID}" \
    -H 'Last-Event-ID: 18'
```

```
event: message
id: 19
data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
```

Terminating cleanly:

```
$ curl -sS -X DELETE https://mcp.prod.internal/mcp \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SID}" -o /dev/null -w '%{http_code}\n'
```

```
204
```

### 11.3 A conformance gate for CI

Schema drift in `inputSchema` is the defect that reaches production most often, because nothing at runtime validates it until a model sends arguments. Gate it:

```bash
#!/usr/bin/env bash
# ci/verify-mcp-primitives.sh — fail the build on primitive contract drift.
set -euo pipefail

ENDPOINT="${1:?usage: verify-mcp-primitives.sh <url>}"
HDR=$(mktemp) ; TOOLS=$(mktemp)
trap 'rm -f "$HDR" "$TOOLS"' EXIT

curl -fsS -D "$HDR" "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Origin: https://copilot.internal' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"0"}}}' \
  > /dev/null

SID=$(awk 'BEGIN{IGNORECASE=1} /^mcp-session-id:/ {print $2}' "$HDR" | tr -d '\r')
[ -n "$SID" ] || { echo "FAIL: server issued no Mcp-Session-Id"; exit 1; }

auth=(-H "MCP-Protocol-Version: 2025-06-18" -H "Mcp-Session-Id: ${SID}")

curl -fsS "$ENDPOINT" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' "${auth[@]}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null

curl -fsS "$ENDPOINT" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' "${auth[@]}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' > "$TOOLS"

fail=0

# 1. Every inputSchema must be an object schema with explicit properties.
bad=$(jq -r '[.result.tools[] | select(.inputSchema.type != "object" or (.inputSchema.properties | type) != "object") | .name] | join(",")' "$TOOLS")
[ -z "$bad" ] || { echo "FAIL: non-object inputSchema on: $bad"; fail=1; }

# 2. Every declared outputSchema must be a valid JSON Schema draft fragment.
jq -c '.result.tools[] | select(has("outputSchema")) | {name, schema: .outputSchema}' "$TOOLS" |
while read -r row; do
  name=$(printf '%s' "$row" | jq -r .name)
  printf '%s' "$row" | jq .schema > /tmp/schema.json
  if ! npx --yes ajv-cli compile -s /tmp/schema.json > /dev/null 2>&1; then
    echo "FAIL: outputSchema of '${name}' is not a compilable JSON Schema"
    exit 1
  fi
done || fail=1

# 3. Any mutating tool must carry explicit annotations — no silent defaults.
bad=$(jq -r '[.result.tools[] | select((.annotations.readOnlyHint // false) == false) | select((.annotations | has("destructiveHint")) == false) | .name] | join(",")' "$TOOLS")
[ -z "$bad" ] || { echo "FAIL: mutating tools without explicit destructiveHint: $bad"; fail=1; }

# 4. Descriptions must be substantive — the model reads these, not the code.
bad=$(jq -r '[.result.tools[] | select((.description // "") | length < 40) | .name] | join(",")' "$TOOLS")
[ -z "$bad" ] || { echo "FAIL: descriptions under 40 chars: $bad"; fail=1; }

curl -fsS -X DELETE "$ENDPOINT" "${auth[@]}" > /dev/null || true

[ "$fail" -eq 0 ] && echo "OK: $(jq '.result.tools | length' "$TOOLS") tools passed the primitive contract gate"
exit "$fail"
```

```
$ ./ci/verify-mcp-primitives.sh https://mcp.staging.internal/mcp
```

```
OK: 3 tools passed the primitive contract gate
```

```
$ ./ci/verify-mcp-primitives.sh https://mcp.dev.internal/mcp
```

```
FAIL: mutating tools without explicit destructiveHint: purge_cache,rotate_credentials
FAIL: descriptions under 40 chars: purge_cache
```

---

## 12. Verification and failure diagnosis

### 12.1 The diagnostic ladder

Work down this list in order; each rung eliminates a class of cause.

1. **Is the session alive?** `ping` must round-trip. `404` on a session-bearing request = expired or misrouted session.
2. **Was negotiation successful?** Compare the `protocolVersion` in the `initialize` response with what the client proposed. A downgrade silently disables `outputSchema`, `resource_link` and `elicitation`.
3. **Is the capability declared?** `-32601` on a primitive method almost always means capability gating, not a missing handler.
4. **Is the failure protocol-level or execution-level?** `error` vs `isError`. They have different owners.
5. **Does the payload validate?** Run `inputSchema` against the arguments the model actually sent, offline.
6. **Is the transport mangling the stream?** Buffering proxies, stdout pollution, missing `Accept` header.

### 12.2 Failure catalogue

| Symptom | Most likely cause | Confirm with | Fix |
|---|---|---|---|
| Server exits immediately, client shows "connection closed" on stdio | A library wrote to **stdout** (a `print`, a banner, a progress bar) | Run the binary manually and pipe stdout to `cat -v`; any non-JSON line is the culprit | Route every human-readable byte to `stderr`; use `notifications/message` for structured logs |
| `-32601 Method not found` on `resources/list` | Server did not declare the `resources` capability in `initialize` | `jq '.result.capabilities' /tmp/init.json` | Add the capability; do not "just implement the handler" |
| Model never calls an obviously relevant tool | `description` is too thin, or the tool is on page 2 of a paginated `tools/list` the client never fetched | Count tools returned vs `nextCursor` presence | Write descriptions for the model, not for humans; ensure the client drains pagination |
| Model calls a tool, gets a result, then calls it again identically, forever | Tool returns `isError: true` with a message the model cannot act on ("Error") | Read the actual `content[0].text` | Make execution errors *actionable*: what failed, why, what to try instead |
| Tool failures never appear on your dashboards | Server maps execution failures to JSON-RPC `error` | `mcp_protocol_errors_total` non-zero with business-looking codes | Convert to `isError: true` results; reserve JSON-RPC errors for plumbing |
| `notifications/progress` arrives all at once at the end | Buffering proxy in front of the SSE stream | `curl -N` direct to the pod vs through ingress | `proxy-buffering off`, `X-Accel-Buffering: no` |
| Client believes a resource is fresh, it is not | Subscription was silently dropped (pod rescheduled, LB re-routed) | `mcp_resource_subscriptions_active` dropped without a matching session drop | Session-affinity by `Mcp-Session-Id`; client-side subscription heartbeat and re-subscribe on reconnect |
| Intermittent `404` under load | Session affinity broken; requests reaching a replica that never saw `initialize` | `MCPSessionNotFoundSpike` alert; correlate `pod` label | `upstream-hash-by: $http_mcp_session_id`, or externalise session state |
| `structuredContent` absent although `outputSchema` is declared | Negotiated down to `2025-03-26` | Check `protocolVersion` in the init response | Upgrade the server, or have the client parse `content[0].text` as JSON fallback |
| Client sends a JSON array and the server rejects it | JSON-RPC batching removed in `2025-06-18` | Payload starts with `[` | Send one message per request |
| Server hangs waiting on `sampling/createMessage` | Client is showing a human-approval dialog; nobody is at the keyboard | Elapsed time on the outstanding request id | Bound sampling calls with a timeout; degrade gracefully to a non-sampling path |
| Elicitation dialog never resolves | Server treats `cancel` as "retry" and re-elicits | Loop of `elicitation/create` with the same message | Distinguish `decline` from `cancel`; abort on both, retry on neither |
| `tools/call` succeeds locally, `-32602` in production | Schema drift between the deployed server and the client's cached tool list | Diff `tools/list` output across environments | Emit `notifications/tools/list_changed` on deploy; run the CI conformance gate |
| Tokens accepted that were issued for another service | No audience validation — confused deputy | Decode the JWT `aud` claim | Validate RFC 8707 resource indicators; reject tokens not minted for this server |

### 12.3 Reproducing a protocol error on purpose

Knowing what a *correct* failure looks like is half of diagnosis:

```
$ curl -sS https://mcp.prod.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SID}" \
    -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"query_prometheus_range","arguments":{"query":"up","start":"yesterday","end":"now"}}}' \
  | jq .
```

```
{
  "jsonrpc": "2.0",
  "id": 9,
  "error": {
    "code": -32602,
    "message": "Invalid params: 'start' must match format date-time",
    "data": {
      "tool": "query_prometheus_range",
      "errors": [
        { "field": "start", "keyword": "format", "expected": "date-time", "received": "yesterday" },
        { "field": "end", "keyword": "format", "expected": "date-time", "received": "now" }
      ]
    }
  }
}
```

And an execution error, which must *not* look like the above:

```
$ curl -sS https://mcp.prod.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SID}" \
    -d '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"query_loki","arguments":{"selector":"{job=\"checkout\"}","since":"720h"}}}' \
  | jq '{isError: .result.isError, text: .result.content[0].text}'
```

```
{
  "isError": true,
  "text": "Loki returned HTTP 400: the query time range exceeds the maximum allowed (168h). Retry with since<=168h, or query the long-term store via the 'query_thanos' tool."
}
```

That message is what a good execution error looks like: the constraint, the actual limit, and the alternative. The model can act on it in one turn.

### 12.4 Expired session, and the correct recovery

```
$ curl -sS -o /dev/null -w '%{http_code}\n' https://mcp.prod.internal/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H 'Mcp-Session-Id: 00000000-dead-beef-0000-000000000000' \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
```

```
404
```

The client MUST respond to `404` by starting a **new** `initialize` handshake without a session ID — not by retrying, not by reusing the old ID. Any resource subscriptions on the old session are gone and must be re-established; any pending `progressToken` is dead.

---

## 13. Exam-relevant distinctions, condensed

| Question | Answer |
|---|---|
| Which primitive is model-controlled? | Tools |
| Which is application-controlled? | Resources |
| Which is user-controlled? | Prompts |
| Which primitives does the *client* expose? | Sampling, Roots, Elicitation |
| Where do tool *execution* failures go? | `result.isError: true`, never a JSON-RPC `error` |
| What does `notifications/resources/updated` carry? | Only the `uri` — the client must re-read |
| Default of `destructiveHint` when omitted? | `true` |
| Default of `readOnlyHint` when omitted? | `false` |
| Are tool annotations trustworthy? | No — untrusted hints, never an authorisation basis |
| Can elicitation request a nested object? | No — flat primitives, enums, no arrays or objects |
| Can elicitation request a password? | No — normatively prohibited |
| Do roots enforce access? | No — informational only |
| Which revision added elicitation, `outputSchema`/`structuredContent`, `resource_link`? | `2025-06-18` |
| Which revision removed JSON-RPC batching? | `2025-06-18` |
| Which revision introduced Streamable HTTP? | `2025-03-26` |
| What must every post-init HTTP request carry? | `MCP-Protocol-Version`, plus `Mcp-Session-Id` when one was issued |
| What does HTTP `404` on `/mcp` mean? | Session expired — re-`initialize` from scratch |
| What is the response to a notification over HTTP? | `202 Accepted`, empty body |
| Which stream does an stdio server log to? | `stderr` — `stdout` is the protocol |
| How many negotiation rounds does `initialize` allow? | One: server proposes its best, client accepts or disconnects |

---

## Referencias

**Official specification and protocol documentation**

- Model Context Protocol — specification index: https://modelcontextprotocol.io/specification
- Specification revision `2025-06-18`: https://modelcontextprotocol.io/specification/2025-06-18
- Architecture overview: https://modelcontextprotocol.io/specification/2025-06-18/architecture
- Lifecycle and capability negotiation: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Transports (stdio, Streamable HTTP): https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Authorization (OAuth 2.1): https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Server primitive — Tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Server primitive — Resources: https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- Server primitive — Prompts: https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- Client primitive — Sampling: https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- Client primitive — Roots: https://modelcontextprotocol.io/specification/2025-06-18/client/roots
- Client primitive — Elicitation: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- Utilities — Pagination: https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/pagination
- Utilities — Completion: https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/completion
- Utilities — Logging: https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/logging
- Utilities — Progress: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
- Utilities — Cancellation: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation
- Utilities — Ping: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/ping
- Security best practices: https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
- Revision changelog: https://modelcontextprotocol.io/specification/2025-06-18/changelog
- Prior revision `2025-03-26`: https://modelcontextprotocol.io/specification/2025-03-26
- Machine-readable schema (TypeScript source of truth): https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-06-18/schema.ts

**Tooling**

- MCP Inspector: https://github.com/modelcontextprotocol/inspector
- Reference server implementations: https://github.com/modelcontextprotocol/servers
- Python SDK: https://github.com/modelcontextprotocol/python-sdk
- TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk

**Underlying standards**

- JSON-RPC 2.0 specification: https://www.jsonrpc.org/specification
- RFC 6570 — URI Template: https://www.rfc-editor.org/rfc/rfc6570
- RFC 5424 — The Syslog Protocol (severity levels): https://www.rfc-editor.org/rfc/rfc5424
- RFC 8414 — OAuth 2.0 Authorization Server Metadata: https://www.rfc-editor.org/rfc/rfc8414
- RFC 8707 — Resource Indicators for OAuth 2.0: https://www.rfc-editor.org/rfc/rfc8707
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://www.rfc-editor.org/rfc/rfc9728
- JSON Schema specification: https://json-schema.org/specification
- HTML Living Standard — Server-Sent Events: https://html.spec.whatwg.org/multipage/server-sent-events.html

**Certification**

- Linux Foundation — Model Context Protocol Associate (MCPA): https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/

**Kubernetes and observability references used in the manifests**

- Kubernetes Services — session affinity: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Horizontal Pod Autoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Prometheus Operator API (`ServiceMonitor`, `PrometheusRule`): https://prometheus-operator.dev/docs/api-reference/api/
- NGINX Ingress Controller annotations: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/