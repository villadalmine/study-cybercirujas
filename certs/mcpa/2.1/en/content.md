# 2.1 Schemas & Structured Data

**Certification:** Model Context Protocol Associate (MCPA) · **Exam version:** 2026-07-28 · **Domain weight:** 4.67

---

## 1. The architectural problem

An MCP server is not an API for a program. It is an API for a *non-deterministic caller* — a language model that decides, at inference time, whether to call your tool, with what arguments, and what to do with the answer. That inverts every assumption you carry from REST or gRPC:

| Assumption in a normal service | What actually happens in MCP |
|---|---|
| The caller was compiled against your contract | The caller reads your contract at runtime, in prose, and guesses |
| A wrong field is a bug someone fixes | A wrong field is a sampling outcome that recurs stochastically |
| The contract costs nothing to publish | The contract is injected into the context window and is billed per token, per turn |
| Output shape matters only to the client code | Output shape decides whether downstream automation can consume the result at all, without re-parsing prose |

This is why schemas in MCP occupy two distinct roles simultaneously, and conflating them is the single most common production failure:

1. **A validation contract** — machine-checkable, enforced at the boundary, rejecting malformed calls with a JSON-RPC error.
2. **A prompt** — the `description`, the property names, the `enum` values and the `default`s are read *by the model* as instructions. A schema that validates perfectly can still be functionally broken if the model cannot infer intent from it.

The production symptom of getting this wrong looks like this: a tool with a flawless `inputSchema` that the model calls correctly 94% of the time. The 6% failures burn a tool-call round trip, a retry, and often a hallucinated recovery. At 40 tools and thousands of sessions per day, that is measurable latency, measurable spend, and an on-call page whose root cause is a two-word `description`.

The second production problem is the return path. Before structured tool output existed, every MCP tool returned prose or a JSON string embedded in a text block. Any automation downstream of the model had to re-parse it — which means a regex over LLM-adjacent output, which means an incident. Structured output (`outputSchema` + `structuredContent`, introduced in protocol revision **2025-06-18**) exists to give the *client program*, not the model, a typed value it can validate and route.

---

## 2. The four schema planes

MCP stacks four independent contract layers. Failures are diagnosable only if you know which plane broke.

| Plane | Defined by | Validated by | Failure mode | Who consumes it |
|---|---|---|---|---|
| **Transport framing** | HTTP/SSE or stdio line framing | Transport layer | Connection drop, malformed SSE event | Runtime |
| **JSON-RPC 2.0 envelope** | `jsonrpc`, `id`, `method`, `params` / `result` / `error` | Protocol layer | `-32700`, `-32600`, `-32601` | Runtime |
| **MCP message schema** | `schema.ts` of the negotiated revision | SDK | Missing `protocolVersion`, bad capability object | SDK |
| **Payload schema** | Your `inputSchema` / `outputSchema` / `requestedSchema` | Server handler, client validator | `-32602`, output-validation failure | **Model and application** |

Only the fourth plane is yours to author. The exam — and production — concentrate there.

### 2.1 The envelope you do not write

Every MCP message is JSON-RPC 2.0. A request:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tools/call",
  "params": {
    "name": "slo_error_budget",
    "arguments": {
      "service": "checkout-api",
      "window": "P28D",
      "include_burn_rate": true
    }
  }
}
```

Three envelope rules MCP adds on top of plain JSON-RPC, each of which has bitten somebody:

- **`id` MUST NOT be null.** Plain JSON-RPC allows a null id; MCP forbids it.
- **`id` MUST be unique within a session** for the lifetime of that session, not merely unique among in-flight requests. Reusing ids after completion is a conformance violation even though most SDKs tolerate it.
- **Notifications carry no `id`** and MUST NOT be answered. `notifications/initialized`, `notifications/tools/list_changed`, `notifications/cancelled` are all fire-and-forget.

JSON-RPC **batching** (an array of requests in one payload) was present in revision 2025-03-26 and **removed** in 2025-06-18. Code that emits batches against a modern server gets a parse-level rejection, not a graceful degrade.

### 2.2 Protocol errors vs. tool errors — the distinction the exam tests

This is the most frequently misunderstood point in the whole domain.

| | Protocol error | Tool error |
|---|---|---|
| Wire shape | `{"jsonrpc":"2.0","id":N,"error":{...}}` | `{"jsonrpc":"2.0","id":N,"result":{"isError":true,"content":[...]}}` |
| Meaning | The request was not executable | The request executed and the operation failed |
| Examples | Unknown tool name, arguments fail `inputSchema`, server not initialised | Prometheus timed out, service not in the SLO catalogue, permission denied upstream |
| Does the model see it? | Usually not, or only as an opaque client-side failure | **Yes** — it is a normal `result`, so the model reads the text and can retry or adapt |
| Does it count as a failed call? | Yes, in client metrics | No, in protocol metrics — which is why your dashboards lie if you only scrape one |

The rule to memorise: **schema violations are protocol errors (`-32602`); business failures are `isError: true` inside a successful result.** Returning a JSON-RPC error for "the service has no SLO defined" hides the information from the model and guarantees it cannot recover.

Standard codes in play:

| Code | Name | Typical MCP cause |
|---|---|---|
| `-32700` | Parse error | Malformed JSON, stray log line on stdout in a stdio server |
| `-32600` | Invalid Request | Missing `jsonrpc`, null `id` |
| `-32601` | Method not found | Tool listed but handler unregistered; capability not advertised |
| `-32602` | Invalid params | **Arguments failed `inputSchema`** |
| `-32603` | Internal error | Unhandled exception in the handler (leaks stack traces if you let it) |

> **stdio servers:** anything written to stdout that is not a framed JSON-RPC message produces `-32700` at the client. Every log line must go to stderr. This is the number one "server works locally, dies under the supervisor" cause.

---

## 3. `inputSchema` — the contract the model reads

`tools/list` returns an array of tool definitions. Each carries an `inputSchema`, which is a JSON Schema object (`"type": "object"`), and optionally an `outputSchema` and `annotations`.

A complete, production-shaped definition:

```json
{
  "name": "slo_error_budget",
  "title": "SLO Error Budget",
  "description": "Return the remaining error budget for a service SLO over a rolling window. Read-only; queries the SLO catalogue and Prometheus. Use this before approving a risky deploy, or when asked how much reliability budget a service has left. Does not modify anything.",
  "inputSchema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "service": {
        "type": "string",
        "description": "Kubernetes Service name exactly as registered in the SLO catalogue, e.g. checkout-api. Not a URL, not a namespace-qualified name.",
        "pattern": "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$",
        "maxLength": 63
      },
      "window": {
        "type": "string",
        "description": "Rolling evaluation window as an ISO-8601 duration. P28D is the standard compliance window.",
        "enum": ["P1D", "P7D", "P28D"],
        "default": "P28D"
      },
      "include_burn_rate": {
        "type": "boolean",
        "description": "Include multi-window burn-rate figures (5m/1h and 30m/6h). Adds roughly 400ms.",
        "default": false
      }
    },
    "required": ["service"],
    "additionalProperties": false
  },
  "outputSchema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "service": {"type": "string"},
      "window": {"type": "string"},
      "objective": {"type": "number", "minimum": 0, "maximum": 1},
      "achieved": {"type": "number", "minimum": 0, "maximum": 1},
      "budget_remaining_ratio": {"type": "number"},
      "budget_remaining_seconds": {"type": "integer"},
      "burn_rate": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "window": {"type": "string"},
            "rate": {"type": "number"},
            "alerting": {"type": "boolean"}
          },
          "required": ["window", "rate", "alerting"],
          "additionalProperties": false
        }
      },
      "evaluated_at": {"type": "string", "format": "date-time"}
    },
    "required": ["service", "window", "objective", "achieved", "budget_remaining_ratio", "evaluated_at"]
  },
  "annotations": {
    "title": "SLO Error Budget",
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  }
}
```

### 3.1 Display name precedence

Revision 2025-06-18 added a top-level `title` alongside the pre-existing `annotations.title`. Resolution order for what a human sees:

```
title  →  annotations.title  →  name
```

`name` remains the programmatic identifier and must be unique per server. Do not put spaces or capitals in `name` expecting it to render nicely; that is what `title` is for.

### 3.2 Annotations are hints, not enforcement

| Annotation | Default | Meaning | Security weight |
|---|---|---|---|
| `readOnlyHint` | `false` | Tool does not modify its environment | **None.** Untrusted servers can lie |
| `destructiveHint` | `true` | Updates may be irreversible (only meaningful when not read-only) | None |
| `idempotentHint` | `false` | Repeat calls with identical args have no additional effect | None |
| `openWorldHint` | `true` | Interacts with entities outside a closed set (the open internet) | None |

Clients use these to decide whether to auto-approve, batch, or retry. They are **untrusted metadata from the server** — a host that grants elevated permission on the strength of `readOnlyHint: true` has built a privilege-escalation primitive. Treat annotations as UX, gate on policy.

### 3.3 The dialect problem — what clients actually support

This is where theory and production diverge hardest. The spec says JSON Schema. The practical reality is that your schema is transformed by the client, then transformed again by the model provider's function-calling layer, and **unsupported keywords are silently dropped**, not rejected.

| Keyword | Universally honoured? | Notes |
|---|---|---|
| `type`, `properties`, `required`, `description` | Yes | The irreducible core |
| `enum` | Yes | Strongest single steering device available |
| `default` | Mostly | Read by the model as a hint; do **not** assume the client injects it. Apply defaults server-side |
| `additionalProperties: false` | Mostly | Some provider layers require it; others strip it |
| `minimum` / `maximum` / `minLength` / `maxLength` | Partially | Often dropped from the model-facing copy. Always re-check server-side |
| `pattern` | Partially | Almost never enforced by the model; enforce yourself |
| `format` | **Annotation only** | In JSON Schema, `format` does not assert by default. `ajv` needs `ajv-formats`; Python `jsonschema` needs `format_checker=` |
| `oneOf` / `anyOf` / `allOf` | Risky | Frequently flattened or rejected by provider layers |
| `$ref` / `$defs` | **Risky** | The top production trap — see below |
| `if` / `then` / `else`, `dependentRequired` | No | Assume dropped |

**Three rules that follow directly:**

1. **Inline everything. No `$ref`.** Pydantic and most codegen emit `$defs` + `$ref` for nested models automatically. If the client flattens naively, the nested constraints vanish and the model receives an untyped object.
2. **`format` is documentation, not validation.** A `format: "date-time"` field will happily accept `"yesterday"` unless you wired a format assertion into your validator.
3. **Validate server-side regardless.** The model-facing schema is a best-effort prompt. The server-side check is the only enforcement that exists.

### 3.4 The token budget — the constraint nobody plans for

Every tool's full definition — name, description, and the entire serialised `inputSchema` — is placed in the model's context on **every turn** of the conversation. Not once: every turn.

```
$ curl -s -X POST http://127.0.0.1:8080/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SESSION}" \
    -d '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}' \
  | sed -n 's/^data: //p' \
  | jq -r '.result.tools[] | "\(.name)\t\((.description + (.inputSchema|tostring))|length)"' \
  | sort -k2 -n -r | head -12

fleet_rollout_plan            3184
incident_timeline_build       2907
slo_error_budget              1642
k8s_manifest_diff             1455
prom_instant_query            1203
log_search                    1106
runbook_fetch                  884
oncall_who                     312
...

$ curl -s ... -d '{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}' \
  | sed -n 's/^data: //p' | jq -c '.result.tools' | wc -c
41863
```

At the conventional heuristic of ≈4 characters per token for English-plus-JSON, 41 863 bytes is roughly **10 000 tokens of fixed overhead per turn**, before the system prompt, before the conversation, before any tool result. Three servers of that size and you have surrendered a third of a 100 k window to schema boilerplate — and you pay it on every single request.

Mitigations, in order of effectiveness:

| Technique | Saving | Cost |
|---|---|---|
| Trim descriptions to the decision-relevant sentence | 20–40% | Slight accuracy loss if overdone |
| Replace free-text strings with `enum` where the domain is closed | 10–20% | **Improves** accuracy; strongly recommended |
| Expose fewer tools per session (host-side filtering / tool-set profiles) | 50–90% | Requires the host to know the task |
| Flatten deep objects into a few scalar parameters | 15–30% | Also dodges the `$ref` trap |
| Move rarely-used parameters out of the tool and into a second, specialised tool | Varies | More tools; may backfire |

Note what does **not** help: `tools/list` pagination via `cursor`. Pagination changes how many round trips fetch the catalogue, not how much of it lands in the context — clients page through everything and concatenate.

---

## 4. `outputSchema` and `structuredContent`

### 4.1 The dual-channel rule

Since revision 2025-06-18, a `tools/call` result may carry **two representations of the same answer**:

```json
{
  "content": [
    {
      "type": "text",
      "text": "checkout-api over P28D: objective 99.90%, achieved 99.94%, 62.1% of the error budget remains (about 15h 38m of allowable downtime). Burn rate is nominal in all windows."
    }
  ],
  "structuredContent": {
    "service": "checkout-api",
    "window": "P28D",
    "objective": 0.999,
    "achieved": 0.99938,
    "budget_remaining_ratio": 0.621,
    "budget_remaining_seconds": 56290,
    "burn_rate": [
      {"window": "5m/1h", "rate": 0.42, "alerting": false},
      {"window": "30m/6h", "rate": 0.61, "alerting": false}
    ],
    "evaluated_at": "2026-09-17T08:14:22Z"
  },
  "isError": false
}
```

The normative rules:

- If a tool declares an `outputSchema`, its results **MUST** include `structuredContent` conforming to that schema (except when `isError: true`).
- Servers **SHOULD** also emit a `content` block — serialised JSON or a prose rendering — as a **backward-compatibility mirror** for clients that negotiated an older revision or simply do not implement structured output.
- Clients **SHOULD** validate `structuredContent` against the declared `outputSchema` and treat a mismatch as a server fault.

The dual channel is not redundancy for its own sake. It is deliberate audience separation:

| Channel | Audience | Optimised for |
|---|---|---|
| `content` | The model, and the human reading the transcript | Comprehension, brevity, units spelled out |
| `structuredContent` | The client application and everything downstream of it | Exactness, machine types, no ambiguity |

Writing the mirror as `JSON.stringify(payload)` is legal and is what the SDKs do by default, but it doubles the token cost of every result and hands the model raw JSON to interpret. On high-volume tools, a hand-written prose mirror is both cheaper and more accurate.

### 4.2 Trade-offs: declare an `outputSchema` or not

| | No `outputSchema` | `outputSchema` declared |
|---|---|---|
| Client can route results programmatically | No — must parse prose | Yes |
| Contract drift detectable | No | Yes, at the client, per call |
| Token cost in `tools/list` | Lower | +200–800 tokens per tool |
| Old clients (pre-2025-06-18) | Work | Work **only if** you keep the text mirror |
| Server free to change output shape | Yes | No — it is now a versioned contract |
| Suitable for narrative tools (summaries, explanations) | **Yes** | No — do not force prose into a schema |

Rule of thumb: declare `outputSchema` when a *program* consumes the result (dashboards, approval gates, ticket creation, further tool chaining). Omit it when only the *model* consumes it.

### 4.3 SDK behaviour you must know

**Python (`mcp` / FastMCP):** `outputSchema` is derived from the function's **return type annotation**. If the return type is not an object — `str`, `int`, `list[...]` — the SDK wraps it, producing:

```json
{
  "type": "object",
  "properties": {
    "result": {"type": "array", "items": {"type": "string"}}
  },
  "required": ["result"]
}
```

and `structuredContent` becomes `{"result": [...]}`. Clients that expect your bare array will break. Return an explicit model if the shape matters.

**TypeScript (`@modelcontextprotocol/sdk`):** `inputSchema` and `outputSchema` in `registerTool` take a **Zod raw shape** (a plain object of Zod validators), not a `z.object(...)`. Passing `z.object({...})` is a common type error. The SDK converts the shape to JSON Schema and validates results against the output shape before they leave the process.

---

## 5. Content blocks — the payload type system

`content` is an array of typed blocks. The type tag is the discriminator; unknown types must be tolerated by clients.

| `type` | Required fields | Encoding | Use it for |
|---|---|---|---|
| `text` | `text` | UTF-8 | Prose, serialised JSON mirror, logs |
| `image` | `data`, `mimeType` | base64 | Screenshots, rendered graphs |
| `audio` | `data`, `mimeType` | base64 | Transcription inputs (added 2025-03-26) |
| `resource_link` | `uri`, `name` | — | **Reference** to a resource without inlining it (added 2025-06-18) |
| `resource` | `resource.uri` + `text` or `blob` | inline | Embedding a resource's contents directly |

`resource_link` is the production-relevant addition: it lets a tool return "here are the 340 pods that matched" as 340 cheap links the client may fetch on demand, rather than 340 inlined documents that blow the context window. It is a pointer, and a client is not obliged to have access to what it points at.

```json
{
  "content": [
    {"type": "text", "text": "3 runbooks match this alert."},
    {
      "type": "resource_link",
      "uri": "runbook://checkout-api/error-budget-exhausted",
      "name": "Error budget exhausted",
      "mimeType": "text/markdown",
      "description": "Freeze procedure and rollback criteria."
    }
  ],
  "isError": false
}
```

### 5.1 Resources: structured data at rest

`resources/read` returns a `contents` array. Each entry carries a `uri`, an optional `mimeType`, and **exactly one of** `text` (UTF-8) or `blob` (base64). There is no `outputSchema` for resources — the contract is carried by `mimeType`. A resource serving `application/json` is making a structural promise the protocol will not check for you; if that matters, publish the JSON Schema as a sibling resource and reference it.

**Resource templates** are the URI-level schema: RFC 6570 URI Templates, e.g. `runbook://{service}/{alert}`. Argument completion for the template variables is served by `completion/complete`, which is how a client offers type-ahead without you inventing a bespoke listing endpoint.

### 5.2 Prompts: where schemas deliberately stop

Prompt arguments are **not** JSON Schema. They are a flat list:

```json
{
  "name": "postmortem_draft",
  "title": "Draft a postmortem",
  "description": "Produce a blameless postmortem skeleton from an incident id.",
  "arguments": [
    {"name": "incident_id", "description": "Incident identifier, e.g. INC-2026-0914.", "required": true},
    {"name": "severity", "description": "SEV1 through SEV4.", "required": false}
  ]
}
```

All values are strings. No types, no enums, no constraints. This asymmetry is intentional — prompts are human-triggered templates, so the human is the validator — and it is a favourite exam question. If you need typed, constrained input, you need a tool, not a prompt.

---

## 6. Elicitation: the deliberately restricted subset

`elicitation/create` (2025-06-18) lets a **server ask the user** for structured input mid-execution — a missing parameter, a confirmation, a choice. Because the client must render this as a form without executing arbitrary schema logic, the permitted schema is a hard subset:

- Top level must be `{"type": "object", ...}` with **flat** primitive properties.
- Permitted property types: `string`, `number`, `integer`, `boolean`, and string `enum`.
- **No nested objects. No arrays.** If you need one, decompose into several elicitations or a tool call.
- String refinements: `minLength`, `maxLength`, `format` (`email`, `uri`, `date`, `date-time`).
- Numeric refinements: `minimum`, `maximum`.
- `enum` may be paired with `enumNames` for display labels.

```json
{
  "jsonrpc": "2.0",
  "id": 91,
  "method": "elicitation/create",
  "params": {
    "message": "checkout-api has 4.2% of its error budget left. Confirm the rollout target before I proceed.",
    "requestedSchema": {
      "type": "object",
      "properties": {
        "strategy": {
          "type": "string",
          "enum": ["canary_1pct", "canary_10pct", "abort"],
          "enumNames": ["Canary 1%", "Canary 10%", "Abort the rollout"],
          "description": "Rollout strategy given the remaining budget."
        },
        "change_ticket": {
          "type": "string",
          "description": "Change ticket authorising the deploy.",
          "minLength": 6,
          "maxLength": 32
        },
        "acknowledge_budget_risk": {
          "type": "boolean",
          "description": "I understand this may exhaust the 28-day error budget.",
          "default": false
        }
      },
      "required": ["strategy", "change_ticket", "acknowledge_budget_risk"]
    }
  }
}
```

The response carries a **three-state action**, and collapsing it to two is a real security bug:

| `action` | Meaning | Correct server behaviour |
|---|---|---|
| `accept` | User submitted the form | Validate `content` against your own schema anyway, then proceed |
| `decline` | User explicitly said no | Do not proceed. Return a tool error explaining the refusal |
| `cancel` | User dismissed without deciding | Do not proceed. **Not** the same as `decline` — do not record it as a denial |

```json
{
  "jsonrpc": "2.0",
  "id": 91,
  "result": {
    "action": "accept",
    "content": {
      "strategy": "canary_1pct",
      "change_ticket": "CHG-114520",
      "acknowledge_budget_risk": true
    }
  }
}
```

Security rule: elicitation **must never** be used to collect credentials, tokens, or passwords. The spec is explicit, and the reason is structural — the server that receives the answer is the party you are being asked to trust.

---

## 7. `_meta`: the extension point

Any MCP object may carry a `_meta` field for out-of-band metadata that the protocol itself ignores. Key naming is constrained: an optional prefix of dot-separated labels terminated by `/`, followed by the name. Prefixes in the `modelcontextprotocol.io/` space are reserved for the protocol.

```json
{
  "name": "slo_error_budget",
  "title": "SLO Error Budget",
  "description": "Return the remaining error budget for a service SLO.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
  "_meta": {
    "platform.example.com/owner": "sre-reliability",
    "platform.example.com/schema-version": "1.7.3",
    "platform.example.com/data-classification": "internal",
    "platform.example.com/cost-tier": "cheap"
  }
}
```

Use it for what your platform needs and the protocol does not define: ownership, schema versioning, cost tiers, data classification for a policy gateway. Do **not** use it for anything the model must read — the model is shown the description and the schema, not your `_meta`.

---

## 8. Schema evolution — the compatibility matrix

Once a tool is in production, its schema is a versioned interface with two independent consumers. "Wire-compatible" means old peers do not error; "model-compatible" means the model's learned calling behaviour still works.

| Change | Wire-compatible | Model-compatible | Notes |
|---|---|---|---|
| Add **optional** property to `inputSchema` | Yes | Yes | The safe default. Always ship with a server-side default |
| Add **required** property to `inputSchema` | **No** | No | Old callers omit it → `-32602` on every call. Ship as optional, backfill, then promote in a later release |
| Remove a property from `inputSchema` | No, if `additionalProperties: false` | Yes | Accept-and-ignore for one release, then remove |
| Rename a property | **No** | No | Treat as add + remove across two releases |
| Widen an `enum` | Yes | Risky | Prompt caches and few-shot examples still reference the old set |
| **Narrow** an `enum` | **No** | No | Removed values arrive from live sessions for hours afterwards |
| Loosen `pattern` / raise `maximum` | Yes | Yes | Safe |
| Tighten `pattern` / lower `maximum` | **No** | No | Rejects previously valid calls |
| Change a property's `type` | **No** | No | Always a new property name |
| Change only `description` | Yes | **Behaviour change** | Silently alters model routing. Re-run your eval set |
| Add a property to `outputSchema` | Yes | Yes | Unless the client enforces `additionalProperties: false` |
| Add a **required** property to `outputSchema` | No | — | Breaks clients pinned to the old schema mid-rollout |
| Add `outputSchema` where there was none | Yes | Yes | Provided the `content` text mirror is retained |
| **Remove** `outputSchema` | **No** | — | Clients validating structured output now fail |
| Set `additionalProperties: false` on an existing `outputSchema` | **No** | — | Converts every future field addition into a breaking change |

Operational corollary: **`additionalProperties: false` on `inputSchema` is defensive and good** — it rejects hallucinated parameters loudly rather than silently ignoring them. **`additionalProperties: false` on `outputSchema` is a trap** — it freezes your response shape forever. The reference definition in §3 reflects exactly this asymmetry.

When a breaking change is unavoidable, do not version the schema — **version the tool name** (`slo_error_budget` → `slo_error_budget_v2`), run both, and emit `notifications/tools/list_changed` so connected clients refresh. Schema-embedded version fields are invisible to the model; a distinct tool name is not.

---

## 9. Reference implementations

### 9.1 Python — FastMCP with Pydantic

```python
"""MCP server exposing SLO error-budget data with a strict output contract."""

from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Annotated, Literal

import jsonref
from pydantic import BaseModel, Field
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("slo-server")

SERVICE_NAME = Annotated[
    str,
    Field(
        pattern=r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$",
        max_length=63,
        description=(
            "Kubernetes Service name exactly as registered in the SLO "
            "catalogue, e.g. checkout-api. Not a URL, not namespace-qualified."
        ),
    ),
]

Window = Literal["P1D", "P7D", "P28D"]


class BurnRate(BaseModel):
    window: str = Field(description="Short/long window pair, e.g. 5m/1h.")
    rate: float = Field(description="Budget consumption multiple. 1.0 exhausts the budget exactly on schedule.")
    alerting: bool


class ErrorBudget(BaseModel):
    service: str
    window: Window
    objective: float = Field(ge=0.0, le=1.0)
    achieved: float = Field(ge=0.0, le=1.0)
    budget_remaining_ratio: float
    budget_remaining_seconds: int
    burn_rate: list[BurnRate] = Field(default_factory=list)
    evaluated_at: datetime


class SLONotDefined(Exception):
    """Raised when the service has no SLO in the catalogue."""


@mcp.tool(
    annotations={
        "title": "SLO Error Budget",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    }
)
def slo_error_budget(
    service: SERVICE_NAME,
    window: Window = "P28D",
    include_burn_rate: bool = False,
) -> ErrorBudget:
    """Return the remaining error budget for a service SLO over a rolling window.

    Read-only; queries the SLO catalogue and Prometheus. Use this before
    approving a risky deploy, or when asked how much reliability budget a
    service has left. Does not modify anything.
    """
    objective = _catalogue_objective(service)  # raises SLONotDefined
    achieved = _query_achieved(service, window)
    consumed = (1.0 - achieved) / (1.0 - objective) if objective < 1.0 else 0.0
    remaining = max(0.0, 1.0 - consumed)

    return ErrorBudget(
        service=service,
        window=window,
        objective=objective,
        achieved=achieved,
        budget_remaining_ratio=round(remaining, 4),
        budget_remaining_seconds=int(remaining * (1.0 - objective) * _window_seconds(window)),
        burn_rate=_burn_rates(service) if include_burn_rate else [],
        evaluated_at=datetime.now(timezone.utc),
    )


def flat_schema(model: type[BaseModel]) -> dict:
    """Return a schema with every $ref inlined and $defs dropped.

    Pydantic emits $defs/$ref for nested models. Several MCP clients and
    provider function-calling layers flatten schemas naively and lose the
    referenced constraints entirely, so the nested object arrives untyped.
    Inline before publishing.
    """
    resolved = jsonref.replace_refs(model.model_json_schema(), proxies=False)
    return {k: v for k, v in resolved.items() if k != "$defs"}


if __name__ == "__main__":
    mcp.settings.host = os.environ.get("MCP_HOST", "0.0.0.0")
    mcp.settings.port = int(os.environ.get("MCP_PORT", "8080"))
    mcp.run(transport="streamable-http")
```

Two things to internalise from this file:

1. `-> ErrorBudget` is what produces the `outputSchema`. Change the annotation and you have changed a published contract.
2. `flat_schema` exists because Pydantic's default output contains `$defs`. Confirm what your server actually publishes rather than what you believe it publishes — §10.2 shows the check.

### 9.2 TypeScript — Zod raw shapes

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const server = new McpServer({ name: "slo-server", version: "1.7.3" });

const BurnRateShape = {
  window: z.string().describe("Short/long window pair, e.g. 5m/1h."),
  rate: z.number().describe("Budget consumption multiple."),
  alerting: z.boolean(),
};

server.registerTool(
  "slo_error_budget",
  {
    title: "SLO Error Budget",
    description:
      "Return the remaining error budget for a service SLO over a rolling window. " +
      "Read-only; queries the SLO catalogue and Prometheus. Use this before approving " +
      "a risky deploy, or when asked how much reliability budget a service has left.",
    // NOTE: a ZodRawShape, not z.object({...}). Passing z.object() is a type error.
    inputSchema: {
      service: z
        .string()
        .regex(/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/)
        .max(63)
        .describe("Kubernetes Service name as registered in the SLO catalogue."),
      window: z.enum(["P1D", "P7D", "P28D"]).default("P28D"),
      include_burn_rate: z.boolean().default(false),
    },
    outputSchema: {
      service: z.string(),
      window: z.string(),
      objective: z.number().min(0).max(1),
      achieved: z.number().min(0).max(1),
      budget_remaining_ratio: z.number(),
      budget_remaining_seconds: z.number().int(),
      burn_rate: z.array(z.object(BurnRateShape)),
      evaluated_at: z.string(),
    },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    },
  },
  async ({ service, window, include_burn_rate }) => {
    try {
      const payload = await computeBudget(service, window, include_burn_rate);
      return {
        // Prose mirror for the model and for pre-2025-06-18 clients.
        content: [
          {
            type: "text",
            text:
              `${payload.service} over ${payload.window}: objective ` +
              `${(payload.objective * 100).toFixed(2)}%, achieved ` +
              `${(payload.achieved * 100).toFixed(3)}%, ` +
              `${(payload.budget_remaining_ratio * 100).toFixed(1)}% of the error budget remains.`,
          },
        ],
        structuredContent: payload,
      };
    } catch (err) {
      // Business failure: isError inside a successful result, so the model
      // can read it and adapt. NOT a JSON-RPC error.
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: `Could not compute the error budget for "${service}": ${(err as Error).message}`,
          },
        ],
      };
    }
  },
);

const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => crypto.randomUUID() });
await server.connect(transport);
```

---

## 10. Production manifests

### 10.1 Deployment, Service and schema policy

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-schema-policy
  namespace: mcp-system
data:
  policy.yaml: |
    # Enforced by the server at startup and by CI on every merge request.
    # A violation at startup is fatal; a violation in CI blocks the merge.
    dialect: "https://json-schema.org/draft/2020-12/schema"
    input:
      require_additional_properties_false: true
      require_description_on_every_property: true
      forbid_ref: true
      forbid_keywords: ["if", "then", "else", "dependentRequired", "$dynamicRef"]
      max_description_chars: 600
      max_nesting_depth: 2
    output:
      require_for_tools_matching: ["^prom_", "^slo_", "^k8s_"]
      forbid_additional_properties_false: true
      require_text_mirror: true
    budget:
      max_serialized_bytes_per_tool: 2400
      max_serialized_bytes_total: 24000
    validation:
      assert_formats: true
      on_input_violation: "reject"
      on_output_violation: "reject_and_alert"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-slo-server
  namespace: mcp-system
  labels:
    app.kubernetes.io/name: mcp-slo-server
    app.kubernetes.io/component: mcp-server
    app.kubernetes.io/version: "1.7.3"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-slo-server
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-slo-server
        app.kubernetes.io/version: "1.7.3"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: mcp-slo-server
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: server
          image: "registry.internal/mcp/slo-server:1.7.3"
          imagePullPolicy: IfNotPresent
          args:
            - "--transport=streamable-http"
            - "--host=0.0.0.0"
            - "--port=8080"
            - "--metrics-port=9090"
            - "--schema-policy=/etc/mcp/policy.yaml"
            - "--validate-input=strict"
            - "--validate-output=strict"
            - "--assert-formats"
          env:
            - name: MCP_PROTOCOL_VERSION
              value: "2025-06-18"
            - name: MCP_SERVER_NAME
              value: "slo-server"
            - name: PROMETHEUS_URL
              value: "http://prometheus-operated.monitoring.svc.cluster.local:9090"
            - name: LOG_LEVEL
              value: "info"
            - name: LOG_DESTINATION
              value: "stderr"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          resources:
            requests:
              cpu: "100m"
              memory: "192Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 3
            failureThreshold: 20
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: schema-policy
              mountPath: /etc/mcp
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: schema-policy
          configMap:
            name: mcp-schema-policy
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-slo-server
  namespace: mcp-system
  labels:
    app.kubernetes.io/name: mcp-slo-server
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mcp-slo-server
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
```

### 10.2 Conformance Job — the schema gate that runs in-cluster

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: mcp-schema-conformance
  namespace: mcp-system
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-schema-conformance
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: conformance
          image: "registry.internal/mcp/schema-conformance:2.4.0"
          args:
            - "--endpoint=http://mcp-slo-server.mcp-system.svc.cluster.local:8080/mcp"
            - "--protocol-version=2025-06-18"
            - "--policy=/etc/mcp/policy.yaml"
            - "--fail-on=ref,missing-description,budget-exceeded,output-mismatch"
            - "--report=/dev/stdout"
          resources:
            requests:
              cpu: "50m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: schema-policy
              mountPath: /etc/mcp
              readOnly: true
      volumes:
        - name: schema-policy
          configMap:
            name: mcp-schema-policy
```

### 10.3 Alerting on schema health

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-schema-health
  namespace: mcp-system
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp-schema
      interval: 30s
      rules:
        - alert: MCPOutputSchemaViolation
          expr: |
            sum by (mcp_server, tool) (
              rate(mcp_tool_output_validation_failures_total[5m])
            )
            /
            clamp_min(
              sum by (mcp_server, tool) (
                rate(mcp_tool_calls_total[5m])
              ),
              0.001
            )
            > 0.01
          for: 10m
          labels:
            severity: warning
            team: sre-reliability
          annotations:
            summary: "structuredContent does not match the declared outputSchema"
            description: "{{ $labels.mcp_server }}/{{ $labels.tool }} is returning structured output that fails its own outputSchema for more than 1% of calls. The server contract has drifted from its declaration; clients validating results are failing."
            runbook_url: "https://runbooks.internal/mcp/output-schema-violation"
        - alert: MCPInvalidParamsSustained
          expr: |
            sum by (mcp_server, tool) (
              rate(mcp_jsonrpc_errors_total{code="-32602"}[15m])
            )
            /
            clamp_min(
              sum by (mcp_server, tool) (
                rate(mcp_tool_calls_total[15m])
              ),
              0.001
            )
            > 0.05
          for: 15m
          labels:
            severity: warning
            team: sre-reliability
          annotations:
            summary: "The model repeatedly fails to satisfy inputSchema"
            description: "More than 5% of calls to {{ $labels.mcp_server }}/{{ $labels.tool }} are rejected with -32602. This is a schema legibility problem, not a client bug: review the property descriptions, add enums for closed domains, and check whether a constraint is being dropped by the client's schema transformation."
        - alert: MCPToolSchemaBudgetExceeded
          expr: |
            sum by (mcp_server) (
              mcp_tool_catalogue_serialized_bytes
            )
            > 24000
          for: 5m
          labels:
            severity: info
            team: sre-reliability
          annotations:
            summary: "Tool catalogue exceeds its context budget"
            description: "{{ $labels.mcp_server }} publishes a tool catalogue larger than 24000 bytes (roughly 6000 tokens), charged to every turn of every session. Trim descriptions or split the server."
```

### 10.4 CI gate

```yaml
stages:
  - lint
  - conformance

variables:
  MCP_PROTOCOL_VERSION: "2025-06-18"

schema-lint:
  stage: lint
  image: "registry.internal/ci/python:3.12"
  script:
    - pip install --no-cache-dir check-jsonschema jsonref
    - python scripts/dump_schemas.py --out artefacts/
    - check-jsonschema --check-metaschema artefacts/*.json
    - python scripts/schema_policy.py --policy deploy/policy.yaml --dir artefacts/
  artifacts:
    when: always
    paths:
      - artefacts/
    expire_in: 7 days

schema-compat:
  stage: lint
  image: "registry.internal/ci/python:3.12"
  script:
    - git fetch origin "$CI_DEFAULT_BRANCH"
    - python scripts/dump_schemas.py --out artefacts/head/
    - git checkout "origin/$CI_DEFAULT_BRANCH" -- src/
    - python scripts/dump_schemas.py --out artefacts/base/
    - python scripts/schema_compat.py --base artefacts/base/ --head artefacts/head/ --fail-on breaking
  allow_failure: false

live-conformance:
  stage: conformance
  image: "registry.internal/ci/node:22"
  services:
    - name: "registry.internal/mcp/slo-server:${CI_COMMIT_SHORT_SHA}"
      alias: mcp
  script:
    - npx --yes @modelcontextprotocol/inspector --cli http://mcp:8080/mcp --method tools/list > tools.json
    - node scripts/assert-every-tool-round-trips.mjs tools.json
```

---

## 11. CLI verification

### 11.1 Handshake and session

Streamable HTTP requires both content types in `Accept`, and the server returns the session id in a response header.

```
$ SESSION=$(curl -sD - -o /tmp/init.out -X POST http://127.0.0.1:8080/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
          "protocolVersion":"2025-06-18",
          "capabilities":{"elicitation":{}},
          "clientInfo":{"name":"curl-probe","version":"0.1.0"}}}' \
  | awk 'BEGIN{IGNORECASE=1} /^mcp-session-id:/ {print $2}' | tr -d '\r')

$ echo "$SESSION"
0f41b2c8-6d3a-4e19-9a77-8c5e0b2f1d44

$ sed -n 's/^data: //p' /tmp/init.out | jq '.result | {protocolVersion, serverInfo, tools: .capabilities.tools}'
{
  "protocolVersion": "2025-06-18",
  "serverInfo": {
    "name": "slo-server",
    "title": "SLO Error Budget Server",
    "version": "1.7.3"
  },
  "tools": {
    "listChanged": true
  }
}

$ curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8080/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SESSION}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
202
```

> Note the `protocolVersion` the **server** returned. If it downgraded you to `2025-03-26`, `structuredContent` will not be honoured and your structured output silently disappears. Always assert the negotiated value; never assume the one you requested.

A small helper for the rest of this section:

```bash
mcpx() {
  curl -s -X POST http://127.0.0.1:8080/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H "Mcp-Session-Id: ${SESSION}" \
    -d "$1" \
  | sed -n 's/^data: //p'
}
```

### 11.2 Auditing the catalogue

```
$ mcpx '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | jq -r '.result.tools[] | [
      .name,
      (.outputSchema != null),
      (.inputSchema.additionalProperties == false),
      ((.description + (.inputSchema|tostring)) | length)
    ] | @tsv' \
  | column -t -N 'TOOL,OUT_SCHEMA,CLOSED_IN,BYTES'

TOOL                    OUT_SCHEMA  CLOSED_IN  BYTES
slo_error_budget        true        true       1642
prom_instant_query      true        true       1203
runbook_fetch           false       true        884
oncall_who              false       false       312
fleet_rollout_plan      true        false      3184
```

`fleet_rollout_plan` fails the byte budget and does not close its input schema. `oncall_who` accepts arbitrary extra properties — a hallucinated argument will be silently swallowed instead of rejected.

Hunt for the `$ref` trap explicitly:

```
$ mcpx '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' \
  | jq -r '.result.tools[]
           | select((.inputSchema|tostring|test("\\$ref")) or ((.outputSchema//{})|tostring|test("\\$ref")))
           | .name'
fleet_rollout_plan
incident_timeline_build
```

Two tools publish `$ref`. Both are candidates for silent constraint loss at the client.

### 11.3 A call, and validating the result independently

```
$ mcpx '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{
    "name":"slo_error_budget",
    "arguments":{"service":"checkout-api","window":"P28D","include_burn_rate":true}}}' \
  | tee /tmp/call.json | jq '.result.structuredContent'
{
  "service": "checkout-api",
  "window": "P28D",
  "objective": 0.999,
  "achieved": 0.99938,
  "budget_remaining_ratio": 0.621,
  "budget_remaining_seconds": 56290,
  "burn_rate": [
    {"window": "5m/1h", "rate": 0.42, "alerting": false},
    {"window": "30m/6h", "rate": 0.61, "alerting": false}
  ],
  "evaluated_at": "2026-09-17T08:14:22Z"
}
```

Now validate it against the server's own declaration, from outside the server — this is the check that catches contract drift:

```
$ mcpx '{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}}' \
  | jq '.result.tools[] | select(.name=="slo_error_budget") | .outputSchema' > /tmp/out.schema.json

$ jq '.result.structuredContent' /tmp/call.json > /tmp/out.instance.json

$ npx --yes ajv-cli validate --spec=draft2020 -c ajv-formats \
    -s /tmp/out.schema.json -d /tmp/out.instance.json
/tmp/out.instance.json valid
```

The same check with the Python toolchain, which is what the CI gate runs:

```
$ check-jsonschema --schemafile /tmp/out.schema.json /tmp/out.instance.json
ok -- validation done
```

And the metaschema check — is your schema even a legal schema?

```
$ check-jsonschema --check-metaschema /tmp/out.schema.json
ok -- validation done
```

### 11.4 Proving that `format` does not assert

The trap, demonstrated:

```
$ cat > /tmp/ts.schema.json <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {"evaluated_at": {"type": "string", "format": "date-time"}},
  "required": ["evaluated_at"]
}
EOF

$ echo '{"evaluated_at": "yesterday afternoon"}' > /tmp/ts.bad.json

$ npx --yes ajv-cli validate --spec=draft2020 -s /tmp/ts.schema.json -d /tmp/ts.bad.json
/tmp/ts.bad.json valid

$ npx --yes ajv-cli validate --spec=draft2020 -c ajv-formats -s /tmp/ts.schema.json -d /tmp/ts.bad.json
/tmp/ts.bad.json invalid
[
  {
    "instancePath": "/evaluated_at",
    "schemaPath": "#/properties/evaluated_at/format",
    "keyword": "format",
    "params": {"format": "date-time"},
    "message": "must match format \"date-time\""
  }
]
```

Identical schema, identical instance, opposite verdicts. **`format` is inert unless a format assertion package is loaded.** If your validator does not load one, `format` in your published schema is documentation for the model and nothing more.

### 11.5 Inspector CLI

```
$ npx @modelcontextprotocol/inspector --cli http://127.0.0.1:8080/mcp --method tools/list \
  | jq -r '.tools[].name'
slo_error_budget
prom_instant_query
runbook_fetch
oncall_who
fleet_rollout_plan

$ npx @modelcontextprotocol/inspector --cli http://127.0.0.1:8080/mcp \
    --method tools/call --tool-name slo_error_budget \
    --tool-arg service=checkout-api --tool-arg window=P7D
{
  "content": [
    {
      "type": "text",
      "text": "checkout-api over P7D: objective 99.90%, achieved 99.97%, 70.4% of the error budget remains."
    }
  ],
  "structuredContent": {
    "service": "checkout-api",
    "window": "P7D",
    "objective": 0.999,
    "achieved": 0.9997,
    "budget_remaining_ratio": 0.704,
    "budget_remaining_seconds": 426,
    "burn_rate": [],
    "evaluated_at": "2026-09-17T08:16:05Z"
  },
  "isError": false
}
```

### 11.6 Negative tests — what a violation actually looks like

Missing a required property:

```
$ mcpx '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{
    "name":"slo_error_budget","arguments":{"window":"P28D"}}}' | jq
{
  "jsonrpc": "2.0",
  "id": 6,
  "error": {
    "code": -32602,
    "message": "Invalid arguments for tool slo_error_budget",
    "data": {
      "validationErrors": [
        {"path": "", "keyword": "required", "message": "'service' is a required property"}
      ]
    }
  }
}
```

A hallucinated property, rejected because `additionalProperties: false`:

```
$ mcpx '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{
    "name":"slo_error_budget",
    "arguments":{"service":"checkout-api","namespace":"prod","window":"P28D"}}}' | jq -c '.error'
{"code":-32602,"message":"Invalid arguments for tool slo_error_budget","data":{"validationErrors":[{"path":"","keyword":"additionalProperties","message":"additional property 'namespace' not allowed"}]}}
```

A value outside the enum:

```
$ mcpx '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{
    "name":"slo_error_budget",
    "arguments":{"service":"checkout-api","window":"30d"}}}' | jq -c '.error.data.validationErrors'
[{"path":"/window","keyword":"enum","message":"must be equal to one of: \"P1D\", \"P7D\", \"P28D\""}]
```

A **business** failure — note it is a `result`, not an `error`:

```
$ mcpx '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{
    "name":"slo_error_budget","arguments":{"service":"legacy-batch"}}}' | jq
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Could not compute the error budget for \"legacy-batch\": no SLO is defined for this service in the catalogue. Run slo_catalogue_list to see which services have SLOs."
      }
    ],
    "isError": true
  }
}
```

The model reads that sentence, sees the suggested next tool, and recovers on its own turn. Had this been returned as `-32603`, the model would have received an opaque failure and the session would have stalled.

---

## 12. Failure diagnosis

| Symptom | Plane | Root cause | Command that proves it |
|---|---|---|---|
| `-32700 Parse error` on a stdio server | Transport | A log line, banner or `print()` reached stdout | `python server.py <<< '{}' \| head -3` — anything not JSON-RPC is the culprit |
| `-32602` on ~every call to one tool | Payload | Model cannot satisfy the schema; ambiguous `description`, open-ended string where an `enum` belongs | Read `error.data.validationErrors`; check which property recurs |
| `-32601 Method not found` for a listed tool | MCP | Handler not registered, or the capability was never advertised in `initialize` | `jq '.result.capabilities' /tmp/init.out` |
| `structuredContent` sent, client ignores it | MCP | Negotiated revision predates 2025-06-18 | `jq -r '.result.protocolVersion' /tmp/init.out` |
| Client rejects a valid-looking result | Payload | Server output drifted from the declared `outputSchema` | §11.3 — validate the instance against the server's own published schema |
| Client shows an empty result | Payload | Only `structuredContent` was sent; the text mirror was dropped | `jq '.result.content \| length' /tmp/call.json` |
| A constraint you published is not enforced anywhere | Payload | `format` without a format assertion, or a keyword the client stripped | §11.4 — run ajv with and without `-c ajv-formats` |
| Nested object arrives untyped at the model | Payload | `$ref`/`$defs` flattened by the client's schema transformation | §11.2 — grep the published schema for `$ref` |
| Model picks a value that was removed from an `enum` | Payload | Narrowed enum; cached prompt or in-flight session still holds the old set | Compare published enum against `-32602` rejection rate |
| First token latency grows with every added server | Payload | Tool catalogue token budget | §3.4 — measure serialised catalogue bytes |
| Elicitation form never renders | MCP | Client did not declare the `elicitation` capability, or the schema used a nested object/array | `jq '.params.capabilities.elicitation' <initialize>`; flatten the `requestedSchema` |
| A denial is recorded as an approval | Payload | `cancel` collapsed into `decline`, or `decline` treated as `accept` with empty content | Inspect the handler's branch on `action` — all three states must be explicit |
| Tool works in one client, fails in another | Payload | Dialect subset differences between client schema transformations | Diff the schema each client actually transmits to its provider |
| Old callers break right after a release | Evolution | A property was promoted to `required`, or an `enum` was narrowed | §8 matrix; run the `schema-compat` CI job against the previous tag |

### 12.1 Diagnostic order

1. **What revision is negotiated?** Half of all structured-output bugs end here. `jq -r '.result.protocolVersion' /tmp/init.out`.
2. **Is it an error or a result?** `jq 'has("error")'` separates plane 2 from plane 4 immediately.
3. **What does the server actually publish?** Not your source, not your Pydantic models — the bytes on the wire from `tools/list`.
4. **Does the instance validate against that published schema, outside the server?** If the server says yes and an external validator says no, the server's validator is misconfigured (typically formats).
5. **Which keywords survive to the model?** Compare the published schema against what the client forwards upstream. Anything missing is unenforced from the model's point of view and must be enforced by you.

---

## 13. Exam-relevant summary

- MCP messages are **JSON-RPC 2.0**; `id` must be non-null and unique per session; batching was removed in **2025-06-18**.
- **Schema violations → JSON-RPC error `-32602`. Business failures → `isError: true` inside a successful `result`**, so the model can read and recover.
- `inputSchema` is both a validation contract and a prompt. `enum` and `description` are the strongest steering devices available.
- `outputSchema` (2025-06-18) requires conforming `structuredContent`; servers **SHOULD** also emit a `content` text mirror for backward compatibility.
- `additionalProperties: false` belongs on `inputSchema` (rejects hallucinated args), not on `outputSchema` (freezes the response shape).
- Content blocks: `text`, `image`, `audio`, `resource_link` (a reference), `resource` (embedded).
- Resources carry `uri` + `mimeType` and **exactly one of** `text` or `blob`; templates are RFC 6570 URI Templates.
- **Prompt arguments are not JSON Schema** — a flat `{name, description, required}` list of strings. Need types? Use a tool.
- Elicitation schemas are a **flat subset**: primitives and string enums only, no nesting, no arrays. Three actions — `accept`, `decline`, `cancel` — and they are three, not two. Never elicit credentials.
- Tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) are **untrusted hints**, not a security boundary.
- Display precedence: `title` → `annotations.title` → `name`.
- `_meta` carries platform metadata the protocol ignores; `modelcontextprotocol.io/` prefixes are reserved.
- Schemas cost tokens on **every turn**. Adding a required property or narrowing an enum are breaking changes; version the **tool name**, not the schema.

---

## Referencias / References

**Certification**

- Linux Foundation — Model Context Protocol Associate (MCPA): <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>

**Protocol specification**

- MCP Specification 2025-06-18 (index): <https://modelcontextprotocol.io/specification/2025-06-18>
- Base protocol, lifecycle and `_meta`: <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- Transports (stdio, Streamable HTTP, `MCP-Protocol-Version` header): <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- Server — Tools (`inputSchema`, `outputSchema`, `structuredContent`, annotations, `isError`): <https://modelcontextprotocol.io/specification/2025-06-18/server/tools>
- Server — Resources (`contents`, `text`/`blob`, `mimeType`, templates): <https://modelcontextprotocol.io/specification/2025-06-18/server/resources>
- Server — Prompts (argument list, `completion/complete`): <https://modelcontextprotocol.io/specification/2025-06-18/server/prompts>
- Client — Elicitation (restricted schema subset, `accept`/`decline`/`cancel`): <https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation>
- Canonical TypeScript schema definitions: <https://github.com/modelcontextprotocol/modelcontextprotocol/tree/main/schema>

**Underlying standards**

- JSON-RPC 2.0 Specification (error codes, notifications, batching): <https://www.jsonrpc.org/specification>
- JSON Schema draft 2020-12 — Core: <https://json-schema.org/draft/2020-12/json-schema-core.html>
- JSON Schema draft 2020-12 — Validation (including `format` as annotation): <https://json-schema.org/draft/2020-12/json-schema-validation.html>
- Understanding JSON Schema: <https://json-schema.org/understanding-json-schema>
- RFC 6570 — URI Template: <https://datatracker.ietf.org/doc/html/rfc6570>
- RFC 4648 — Base16/32/64 Data Encodings (`blob`, `image`, `audio`): <https://datatracker.ietf.org/doc/html/rfc4648>

**SDKs and tooling**

- MCP Python SDK: <https://github.com/modelcontextprotocol/python-sdk>
- MCP TypeScript SDK: <https://github.com/modelcontextprotocol/typescript-sdk>
- MCP Inspector (GUI and `--cli` mode): <https://github.com/modelcontextprotocol/inspector>
- Ajv — JSON Schema validator: <https://ajv.js.org/>
- ajv-formats — format assertion package: <https://github.com/ajv-validator/ajv-formats>
- check-jsonschema: <https://check-jsonschema.readthedocs.io/en/latest/>
- Pydantic — JSON Schema generation (`$defs`/`$ref` behaviour): <https://docs.pydantic.dev/latest/concepts/json_schema/>
- Zod: <https://zod.dev/>

**Platform**

- Kubernetes — Configure a Pod to use a ConfigMap: <https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/>
- Kubernetes — Pod Security Standards: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Prometheus Operator — PrometheusRule API: <https://prometheus-operator.dev/docs/api-reference/api/>
- Prometheus — Alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>