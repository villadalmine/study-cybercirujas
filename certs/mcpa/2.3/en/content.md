# 2.3 Model Interaction Flow

**Certification:** MCPA — Model Context Protocol Associate (Linux Foundation)
**Exam version:** 2026-07-28 · **Domain weight:** 4.67 %
**Audience profile:** Platform Architect / SRE operating MCP hosts and servers in production

---

## 1. Motivation: what actually breaks in production

The Model Context Protocol is frequently taught as a *catalogue* problem — "how do I expose a tool to a model". That framing survives exactly one demo. In production the hard problem is not the catalogue, it is the **flow**: the ordered, partially non-deterministic, multi-party message exchange that starts at a user prompt and ends at a grounded answer, crossing at least three trust domains and two distinct protocols on the way.

Consider the failure that motivates this whole objective. A platform team ships an internal agent. It exposes 9 MCP servers — Jira, GitHub, Prometheus, a Postgres read replica, an internal deploy API, Slack, PagerDuty, an S3 document store, and a feature-flag service. Aggregate: 74 tools. Symptoms reported over the first six weeks:

| # | Symptom | Where in the flow it lives |
|---|---|---|
| 1 | p95 latency for a one-sentence answer jumps from 2.1 s to 19 s | Every turn ships 74 tool schemas; prompt cache never warms |
| 2 | The model "forgets" the deploy tool exists after a server restarts | `notifications/tools/list_changed` not handled; host caches a stale list |
| 3 | Two servers both export `search` → wrong server gets the call | No namespacing in the host's tool-name → session map |
| 4 | A 40 MB Prometheus range query result blows the context window | Tool result marshalled verbatim into the message array |
| 5 | Pod restart → "Session not found", conversation dies mid-turn | Streamable HTTP session state held in pod memory; no affinity |
| 6 | An agent loops 30 times calling `list_incidents` and never answers | No turn budget, no loop-detection on the host's agent loop |
| 7 | Cancelled requests keep running, DB connections leak | `notifications/cancelled` sent but server never wired it to a context |

Not one of these is a bug in a tool implementation. All seven are **interaction-flow** defects. MCP's value proposition is that it turns the M hosts × N integrations problem into M + N — but it only collects that dividend if the host implements the flow correctly, because the protocol deliberately leaves policy (which tools to expose, when to ask a human, how to budget turns) to the host.

The second, subtler motivation: **the model is the scheduler.** In a classic distributed system a deterministic orchestrator decides what runs next. Here, the next RPC is chosen by a stochastic process whose input is natural-language text you only partially control. Every property you normally get for free — bounded fan-out, termination, idempotency, retry safety — must be re-established by the host as an explicit control loop. That control loop is what "Model Interaction Flow" names.

---

## 2. The participants and the ownership boundary

MCP is a **1:1 client-to-server** protocol embedded in a **1:N host-to-client** application. Collapsing those two layers is the single most common conceptual error on the exam and in code review.

```
                       ┌──────────────────────────────────────────────┐
                       │  HOST  (the application — IDE, agent, chat)   │
                       │                                              │
   user ──prompt──────▶│  ┌────────────────────────────────────────┐  │
                       │  │ Agent loop / context assembler         │  │
                       │  │  · turn budget       · approval policy │  │
   answer ◀────────────│  │  · tool-name registry· result shaping  │  │
                       │  └───┬─────────┬──────────┬───────────────┘  │
                       │      │         │          │                  │
                       │  ┌───▼───┐ ┌───▼───┐  ┌───▼───┐              │
                       │  │Client1│ │Client2│  │Client3│  (1 per svr) │
                       │  └───┬───┘ └───┬───┘  └───┬───┘              │
                       └──────┼─────────┼──────────┼──────────────────┘
                              │ JSON-RPC 2.0 over stdio / Streamable HTTP
                    ┌─────────▼──┐  ┌───▼────────┐  ┌▼────────────┐
                    │ MCP Server │  │ MCP Server │  │ MCP Server  │
                    │  (github)  │  │   (prom)   │  │  (postgres) │
                    └─────┬──────┘  └─────┬──────┘  └──────┬──────┘
                          │               │                │
                      GitHub API      Prometheus       PG replica

        ── separate protocol, separate direction ──
   HOST ──── HTTPS / Messages API ────▶ Model provider (inference)
```

| Participant | Owns | Does **not** own | Failure blast radius |
|---|---|---|---|
| **Host** | The agent loop, conversation state, model credentials, the tool-name registry, approval UX, turn/token budgets, result truncation policy | Business logic of any integration | Total — every conversation |
| **Client** | One MCP session: handshake, capability record, request IDs, progress/cancel plumbing, transport reconnection | What the model decides | One integration |
| **Server** | Primitives (`tools`, `resources`, `prompts`), their side effects, upstream auth to the real system | Model choice, prompt content, whether its tool gets called | One integration |
| **Model API** | Token-level decision to emit `tool_use` | Executing anything | Quality, not availability |

**Architectural consequence:** the MCP server never talks to the model, and the model never talks to the MCP server. Every byte crosses the host. The host is therefore the only place where a security boundary, a rate limit, a redaction rule or an audit record can be enforced — and the only place where they can be forgotten.

---

## 3. Anatomy of one interaction — the eleven steps

The canonical single-tool turn. Memorise the ordering; the exam tests ordering and ownership more than payload shapes.

| Step | Actor | Action | Protocol |
|---|---|---|---|
| 1 | Host → Server | `initialize` (once per session, at startup) | MCP |
| 2 | Server → Host | `InitializeResult` + capabilities | MCP |
| 3 | Host → Server | `notifications/initialized` | MCP |
| 4 | Host → Server | `tools/list` (and `resources/list`, `prompts/list`) | MCP |
| 5 | Host | Namespace, filter, translate MCP schemas → provider tool schemas | local |
| 6 | Host → Model | `POST /v1/messages` with `tools` + conversation | Provider API |
| 7 | Model → Host | `stop_reason: "tool_use"` + one or more `tool_use` blocks | Provider API |
| 8 | Host | Resolve tool name → session; apply approval policy | local |
| 9 | Client → Server | `tools/call` | MCP |
| 10 | Server → Client | `CallToolResult` (content, `structuredContent`, `isError`) | MCP |
| 11 | Host → Model | `tool_result` blocks in a **single** user message; loop to step 6 | Provider API |

Steps 6 → 11 repeat until `stop_reason` is `end_turn` (or the host's budget trips). Steps 1–4 happen **once per session**, not per turn — a host that re-runs `tools/list` on every user message is paying an avoidable round trip *and* risking cache invalidation (§ 5.3).

### 3.1 Handshake on the wire

Client → server:

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
      "name": "acme-platform-agent",
      "title": "Acme Platform Agent",
      "version": "3.4.1"
    }
  }
}
```

Server → client:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": { "listChanged": true },
      "resources": { "subscribe": true, "listChanged": true },
      "prompts": { "listChanged": true },
      "logging": {},
      "completions": {}
    },
    "serverInfo": {
      "name": "prometheus-mcp",
      "title": "Prometheus MCP Server",
      "version": "1.9.2"
    },
    "instructions": "Query Prometheus. Always call list_metrics before writing a PromQL expression. Range queries are capped at 11000 points."
  }
}
```

Then, unanswered (a notification has no `id`):

```json
{ "jsonrpc": "2.0", "method": "notifications/initialized" }
```

Three operationally decisive details in that exchange:

1. **`protocolVersion` negotiation is a downgrade, not a handshake failure.** The client proposes; the server replies with a version it supports. If the client cannot live with the server's answer it must close the transport. A server that echoes a version the client never proposed is out of spec, and a host that ignores the reply will send fields the peer cannot parse.
2. **Capabilities are the flow's feature flags.** `sampling` and `elicitation` are declared by the **client**, because those are reverse-direction calls (§ 8). A server that issues `sampling/createMessage` against a client that did not declare `sampling` must be answered with a JSON-RPC error, not a crash.
3. **`instructions` is free text injected into the model's context by the host.** It is server-controlled text that lands in your system prompt. Treat it as untrusted input: length-cap it, and never let it arrive after your own operator instructions in the rendered prompt.

### 3.2 The HTTP envelope (Streamable HTTP)

After initialization, every request carries the negotiated version as a header — mandatory since revision `2025-06-18`:

```
POST /mcp HTTP/1.1
Host: prometheus-mcp.mcp-system.svc.cluster.local:8080
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-06-18
Mcp-Session-Id: 8f2b1c4e-53a9-4d10-9f7e-6a1b0d3c2e55
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
```

`Mcp-Session-Id` is assigned by the server in the `initialize` response headers and echoed by the client thereafter. **It is the sharding key for the entire deployment** (§ 11.2). Its absence on a stateless server is legal; its presence plus a load balancer without affinity is the #5 failure in §1.

---

## 4. Trade-off: transport selection

| Dimension | **stdio** | **Streamable HTTP** | (legacy) HTTP+SSE |
|---|---|---|---|
| Spec status in 2025-06-18 | Current | Current | Deprecated since 2025-03-26 |
| Process model | One server subprocess per client | Shared, N clients | Shared |
| Auth | Inherited from the host process (env, files) | OAuth 2.1 Resource Server, RFC 9728 metadata | Bearer, ad hoc |
| Multi-tenancy | None — one tenant per process | Native, via session + token | Native |
| Server-initiated messages | Trivially (same pipe) | Via SSE on the POST response or a `GET /mcp` stream | Separate SSE endpoint |
| Resumption after a network blip | N/A (no network) | `Last-Event-ID` replay on the SSE stream | Fragile |
| Horizontal scale | Scale the host | Scale the server, needs session affinity or shared state | Same |
| Cold-start cost | Process spawn, 50–800 ms | Connection only, ~1–5 ms | Same |
| Observability | stderr only; **stdout is the wire** | Standard HTTP tracing, `traceparent` propagates | Standard |
| Blast radius of a crash | One user | All sessions on the pod | All sessions |
| Best fit | Desktop hosts, local filesystem/git access, per-user credentials | Platform-hosted servers, shared SaaS integrations, anything behind a Gateway | Migration only |

**SRE rule of thumb:** if the server needs a credential that is *not* the end user's, it belongs on Streamable HTTP behind an authorization server. If it needs the end user's local machine, it belongs on stdio. Mixing — a stdio server holding a shared production credential in `env` — is how a per-user integration becomes a shared privilege escalation path.

---

## 5. Step 4–6: discovery and the translation into a model-visible surface

### 5.1 What `tools/list` returns

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "query_range",
        "title": "Prometheus range query",
        "description": "Evaluate a PromQL expression over a time range. Returns a matrix of samples. Use list_metrics first to discover valid metric names.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "expr": {
              "type": "string",
              "description": "PromQL expression, e.g. rate(http_requests_total[5m])"
            },
            "start": { "type": "string", "format": "date-time" },
            "end": { "type": "string", "format": "date-time" },
            "step": {
              "type": "string",
              "description": "Resolution step, Go duration, e.g. 30s",
              "default": "60s"
            }
          },
          "required": ["expr", "start", "end"],
          "additionalProperties": false
        },
        "outputSchema": {
          "type": "object",
          "properties": {
            "resultType": { "type": "string", "enum": ["matrix"] },
            "seriesCount": { "type": "integer" },
            "truncated": { "type": "boolean" }
          },
          "required": ["resultType", "seriesCount"]
        },
        "annotations": {
          "title": "Prometheus range query",
          "readOnlyHint": true,
          "destructiveHint": false,
          "idempotentHint": true,
          "openWorldHint": true
        }
      }
    ],
    "nextCursor": "eyJvZmZzZXQiOjF9"
  }
}
```

Note `nextCursor`: **`tools/list` is paginated.** A host that reads page one and stops silently hides tools — and the model then confidently reports the capability does not exist. Always drain the cursor.

`annotations` are **hints, not enforcement**. They come from the server, which is exactly the party you might not trust. Their legitimate use is host-side *policy input*: `destructiveHint: true` → require human approval; `readOnlyHint: true` → eligible for automatic execution. Their illegitimate use is as a security control.

### 5.2 Mapping MCP tool → provider tool definition

The host is a translator. For the Claude Messages API the mapping is nearly one-to-one, which is not an accident — MCP tool schemas are JSON Schema, as are provider tool schemas.

| MCP `Tool` field | Claude Messages API `tools[]` field | Notes |
|---|---|---|
| `name` | `name` | Must be namespaced by the host if >1 server (§ 6.1) |
| `title` | — | Host UI only; never sent to the model |
| `description` | `description` | The single highest-leverage field for call accuracy |
| `inputSchema` | `input_schema` | Verbatim JSON Schema |
| `inputSchema.additionalProperties: false` + `required` | enables `strict: true` | Guarantees the arguments validate |
| `outputSchema` | — | Host-side validation of the result; not sent to the model |
| `annotations` | — | Host policy input |

```python
# host/translate.py — MCP tool descriptors to Claude tool definitions.
def to_claude_tools(server_alias: str, mcp_tools: list[dict]) -> list[dict]:
    """Namespace and translate one server's tools into Messages API shape."""
    out = []
    for t in mcp_tools:
        schema = t["inputSchema"]
        strict = (
            schema.get("additionalProperties") is False
            and "required" in schema
        )
        out.append({
            "name": f"{server_alias}__{t['name']}",   # see § 6.1
            "description": t.get("description", ""),
            "input_schema": schema,
            **({"strict": True} if strict else {}),
        })
    return out
```

```python
# host/turn.py — one model call in the loop.
response = client.messages.create(
    model="claude-opus-5",
    max_tokens=16000,
    thinking={"type": "adaptive"},
    output_config={"effort": "high"},
    system=[{
        "type": "text",
        "text": SYSTEM_PROMPT + server_instructions_block,
        "cache_control": {"type": "ephemeral"},   # freeze the prefix
    }],
    tools=all_tools,          # deterministic order — § 5.3
    messages=conversation,
)
```

An alternative worth knowing for the architecture exam: the provider can hold the MCP client itself. With Claude's MCP connector the host declares the remote server and never runs a client at all — the loop moves inside the provider:

```python
response = client.beta.messages.create(
    model="claude-opus-5",
    max_tokens=16000,
    betas=["mcp-client-2025-11-20"],
    mcp_servers=[{
        "type": "url",
        "url": "https://prometheus-mcp.example.com/mcp",
        "name": "prom",
    }],
    tools=[{"type": "mcp_toolset", "mcp_server_name": "prom"}],
    messages=[{"role": "user", "content": "What is the 5xx rate for checkout?"}],
)
```

| | Host-side MCP client | Provider-side MCP connector |
|---|---|---|
| Who runs the loop | You | Provider |
| Approval gates / human-in-the-loop | Yours to implement, fully | Limited to what the provider exposes |
| Server reachability | Private network OK (stdio, cluster-internal) | Must be publicly reachable + authenticated |
| Redaction of tool results before they hit the model | Possible | Not possible |
| Audit record of every `tools/call` | Yours | Provider's |
| Code you maintain | Loop, registry, budgets, retries | Almost none |
| Latency | +1 network hop per call (host in the middle) | Fewer hops |

For a regulated platform, host-side wins on the redaction and audit rows alone. For an internal productivity bot, the connector removes the loop you would otherwise get wrong.

### 5.3 The token economics of the tool surface

Every tool definition is re-sent on **every request of every turn**. This is the cost most teams discover in the invoice rather than the design review.

Worked example, measured — not estimated — with `client.messages.count_tokens` against the real tool array:

```python
base = client.messages.count_tokens(
    model="claude-opus-5", messages=msgs, system=SYSTEM,
).input_tokens
with_tools = client.messages.count_tokens(
    model="claude-opus-5", messages=msgs, system=SYSTEM, tools=all_tools,
).input_tokens
print(f"tool surface = {with_tools - base} tokens")
```

| Exposure strategy | Tool defs per request | Typical added input tokens | Accuracy effect | When to use |
|---|---|---|---|---|
| **Eager — all servers, all tools** | 74 | ~14 000 | Degrades past ~30–40 tools: near-duplicate names get confused | ≤ 15 tools total |
| **Static per-route filter** (route → server subset) | 8–12 | ~2 400 | Best accuracy; brittle when the router mis-routes | Known task taxonomy |
| **Deferred loading + tool search** (`defer_loading: true` + `tool_search_tool_bm25_20251119`) | 2 resident + on-demand | ~600 resident | One extra search round trip, ~300 ms | Large, open tool surfaces |
| **Hierarchical / meta-tool** (one `call_server` tool, server chosen in args) | 1 | ~200 | Worst — the model loses schema-level guidance for arguments | Rarely justified |
| **Progressive disclosure by phase** (planning tools, then execution tools) | varies | varies | Good, complex to implement | Long agentic sessions |

Two hard rules that fall out of caching:

- **Order the tool array deterministically.** Prompt caching is a prefix match, and the render order is `tools` → `system` → `messages`. A `dict` iteration order that varies between processes, or a server whose `tools/list` returns a different order after restart, invalidates the entire cached prefix on every request. Sort by namespaced name before sending.
- **`notifications/tools/list_changed` is a cache-invalidation event, not just a refresh.** When a server announces a changed tool list, the host must re-run `tools/list`, rebuild the array, and accept that the next request is a full cache write. Handle it — but do not let a chatty server emit it per request, or your cache hit rate is structurally zero. Verify with `usage.cache_read_input_tokens`; a sustained zero across a conversation means something upstream of the last breakpoint is moving.

---

## 6. Steps 7–9: the decision point and routing

The model's reply when it wants a tool:

```json
{
  "id": "msg_01XcQ8vN3pKrT6y2LmWb9aZd",
  "type": "message",
  "role": "assistant",
  "model": "claude-opus-5",
  "stop_reason": "tool_use",
  "content": [
    {
      "type": "text",
      "text": "I'll pull the 5xx rate for checkout over the last hour."
    },
    {
      "type": "tool_use",
      "id": "toolu_01A9k2ZpQ4mR7nX3vB6cH8dY",
      "name": "prom__query_range",
      "input": {
        "expr": "sum(rate(http_requests_total{job=\"checkout\",code=~\"5..\"}[5m]))",
        "start": "2026-09-17T09:00:00Z",
        "end": "2026-09-17T10:00:00Z",
        "step": "60s"
      }
    }
  ],
  "usage": {
    "input_tokens": 3184,
    "cache_read_input_tokens": 11420,
    "output_tokens": 196
  }
}
```

### 6.1 Namespacing: the registry is the host's responsibility

MCP guarantees tool-name uniqueness **within one server**. It guarantees nothing across servers, and a production host aggregates many. Collisions are not hypothetical — `search`, `list`, `get`, `query` and `run` collide constantly.

```python
# host/registry.py
import re

_SAFE = re.compile(r"[^a-zA-Z0-9_-]")

class ToolRegistry:
    """Maps the model-visible tool name back to (session, original name)."""

    def __init__(self) -> None:
        self._by_public_name: dict[str, tuple[str, str]] = {}

    def register(self, server_alias: str, tool_name: str) -> str:
        alias = _SAFE.sub("_", server_alias)
        public = f"{alias}__{tool_name}"[:128]
        if public in self._by_public_name:
            raise ValueError(f"tool name collision after namespacing: {public}")
        self._by_public_name[public] = (server_alias, tool_name)
        return public

    def resolve(self, public: str) -> tuple[str, str]:
        try:
            return self._by_public_name[public]
        except KeyError:
            raise LookupError(f"model called unknown tool: {public}") from None
```

A model that hallucinates a tool name must produce a `tool_result` with `is_error: true` and a message naming the valid tools — **never an exception that kills the turn**. The model recovers from an error block; it cannot recover from a 500 in your host.

### 6.2 Parallel tool use and the single-message rule

One assistant message may contain several `tool_use` blocks. Execute them concurrently, then return **all** `tool_result` blocks in **one** user message. Splitting them across messages is silently punished: the model learns your host does not support parallelism and stops emitting parallel calls, and your p95 doubles.

```python
# host/execute.py
import asyncio

async def run_tool_uses(blocks, registry, sessions, approvals) -> list[dict]:
    async def one(b):
        alias, name = registry.resolve(b.name)
        if not await approvals.allow(alias, name, b.input):
            return {"type": "tool_result", "tool_use_id": b.id,
                    "content": "Denied by operator policy.", "is_error": True}
        try:
            res = await sessions[alias].call_tool(name, b.input, timeout=30)
        except TimeoutError:
            return {"type": "tool_result", "tool_use_id": b.id,
                    "content": f"{name} timed out after 30s.", "is_error": True}
        except Exception as exc:                       # transport / protocol error
            return {"type": "tool_result", "tool_use_id": b.id,
                    "content": f"{name} failed: {exc}", "is_error": True}
        return to_tool_result(b.id, res)               # § 7.2

    uses = [b for b in blocks if b.type == "tool_use"]
    results = await asyncio.gather(*(one(b) for b in uses))
    return list(results)                               # one user message, all blocks
```

### 6.3 The `tools/call` request

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "query_range",
    "arguments": {
      "expr": "sum(rate(http_requests_total{job=\"checkout\",code=~\"5..\"}[5m]))",
      "start": "2026-09-17T09:00:00Z",
      "end": "2026-09-17T10:00:00Z",
      "step": "60s"
    },
    "_meta": {
      "progressToken": "toolu_01A9k2ZpQ4mR7nX3vB6cH8dY"
    }
  }
}
```

Note that the namespace prefix is **stripped** — `prom__query_range` is a host-side fiction; the server only knows `query_range`. Reusing the provider's `tool_use.id` as the `progressToken` is a cheap trick that makes progress notifications trivially correlatable back to the model's call.

---

## 7. Step 10–11: results, and the two error channels

### 7.1 The result

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "resultType=matrix seriesCount=1 truncated=false\nt=2026-09-17T09:00:00Z v=0.0132\nt=2026-09-17T09:01:00Z v=0.0128\nt=2026-09-17T09:02:00Z v=0.0411\n... 58 more samples elided ..."
      },
      {
        "type": "resource_link",
        "uri": "prom://query/8f2b1c4e/full.json",
        "name": "full-result.json",
        "mimeType": "application/json",
        "description": "Complete 61-point matrix, 18 KB"
      }
    ],
    "structuredContent": {
      "resultType": "matrix",
      "seriesCount": 1,
      "truncated": false
    },
    "isError": false
  }
}
```

Three flow-critical mechanics here:

- **`content` is what the model reads.** It is a list of blocks: `text`, `image`, `audio`, `resource_link`, and embedded `resource`. It is the only part that costs tokens.
- **`structuredContent` is what your code reads.** When the tool declared an `outputSchema`, the host validates `structuredContent` against it. A mismatch is a *server* bug and should be surfaced to operators, not to the model.
- **`resource_link` is the pressure-release valve for failure #4 in §1.** The server returns a *pointer* plus a summary instead of 40 MB of samples. If the model needs the detail it calls `resources/read` — an explicit, budgeted second step, not an accidental context bomb.

### 7.2 Two error channels, and why confusing them breaks the loop

This is the most commonly mis-implemented rule in the entire objective.

| | **Protocol error** (JSON-RPC `error`) | **Tool execution error** (`isError: true`) |
|---|---|---|
| Shape | `{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"..."}}` | `{"result":{"content":[...],"isError":true}}` |
| Means | The request was malformed, the method/tool does not exist, the caller is unauthorized | The tool ran and failed — query syntax error, 404 upstream, permission denied by the target system |
| Who should learn about it | The **host**: it is a bug or a config problem | The **model**: it can adapt and retry |
| Correct host action | Log, alert, surface to the operator; do **not** paste the raw error at the model as if it were data | Marshal into `tool_result` with `is_error: true` and let the loop continue |
| Consequence of confusing them | Model retries a call that can never succeed until the turn budget trips | Operator never sees a real outage; the model invents a workaround |

Standard JSON-RPC codes you will see: `-32700` parse error, `-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal error. MCP adds implementation-defined codes above `-32000`.

A tool execution error from the server:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "PromQL parse error at char 34: unexpected character '}' — check for an unclosed label matcher."
      }
    ],
    "isError": true
  }
}
```

That text is *for the model*. It is deliberately diagnostic and actionable, because the model's next move depends on it. Compare with a server that returns `"error"` — the model has nothing to work with and will either retry identically or give up.

### 7.3 Feeding results back

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A9k2ZpQ4mR7nX3vB6cH8dY",
      "content": [
        {
          "type": "text",
          "text": "resultType=matrix seriesCount=1 truncated=false\nt=2026-09-17T09:00:00Z v=0.0132\n..."
        }
      ],
      "is_error": false
    }
  ]
}
```

Host-side shaping policy — the difference between a stable agent and one that dies at turn nine:

| Policy | Rule | Rationale |
|---|---|---|
| Hard byte cap | Truncate any single `tool_result` at N tokens (e.g. 4 000), append an explicit `[truncated: 132 of 4800 rows shown]` marker | Silent truncation makes the model confidently wrong about totals |
| Offload | Above the cap, persist the full payload and return a `resource_link` | Detail stays retrievable without being resident |
| Redact | Apply DLP/PII rules **before** the block enters the message array | Once it is in the history it is re-sent every turn, forever |
| Never drop | A failed parallel call still gets its `tool_result` block | A missing `tool_use_id` is a 400 from the provider |
| Age out | Use context editing (`clear_tool_uses_20250919`) to clear stale tool results in long sessions | Bounded growth without summarisation loss |

---

## 8. Reverse flows: the server calls the model

This is what distinguishes MCP from a plain function-calling convention, and it is disproportionately represented in exam questions because it inverts the direction everyone has internalised.

### 8.1 Sampling — `sampling/createMessage`

The server asks the **client** to run an LLM completion on its behalf. The server never holds a model API key.

Server → client:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "Summarise this incident timeline in three bullets:\n09:02 checkout 5xx 4%\n09:06 rollback initiated\n09:11 error rate normal"
        }
      }
    ],
    "systemPrompt": "You are a terse SRE incident summariser.",
    "modelPreferences": {
      "hints": [{ "name": "claude-sonnet" }],
      "costPriority": 0.8,
      "speedPriority": 0.6,
      "intelligencePriority": 0.3
    },
    "maxTokens": 512,
    "includeContext": "thisServer"
  }
}
```

`modelPreferences` are **advisory**. The client owns model selection — it may map `costPriority: 0.8` onto `claude-haiku-4-5`, or refuse entirely. Never design a server that depends on a specific model being honoured.

Production hazards, in order of how often they bite:

| Hazard | Mechanism | Mitigation |
|---|---|---|
| **Unbounded recursion** | Model calls tool → server samples → sampled model calls a tool → … | Per-conversation recursion depth counter in the host; hard cap (3 is generous) |
| **Cost exfiltration** | A server can spend the host's inference budget at will | Per-session token budget on sampling, enforced host-side; meter it separately from user-driven turns |
| **Prompt injection** | `systemPrompt` and `messages` are server-supplied | Human approval on the sampling request, or a strict allow-list of servers permitted to sample |
| **Latency amplification** | Each nested sample adds a full inference round trip inside a tool call | Timeout the `tools/call` shorter than the sampling call can plausibly take, and surface it as a tool error |

The spec's own guidance is that sampling **SHOULD** be human-in-the-loop: the user sees the prompt before it runs and the completion before it is returned. Most hosts implement approval on the prompt and auto-approve the completion; that is the defensible minimum.

### 8.2 Elicitation — `elicitation/create`

Added in `2025-06-18`. The server asks the **user** for structured input mid-flow, without terminating the tool call.

```json
{
  "jsonrpc": "2.0",
  "id": 43,
  "method": "elicitation/create",
  "params": {
    "message": "Rolling back checkout to v2.18.3 will drop in-flight carts. Confirm the change window.",
    "requestedSchema": {
      "type": "object",
      "properties": {
        "confirm": {
          "type": "boolean",
          "title": "Proceed with rollback",
          "default": false
        },
        "change_ticket": {
          "type": "string",
          "title": "Change ticket",
          "pattern": "^CHG-[0-9]{6}$"
        }
      },
      "required": ["confirm", "change_ticket"]
    }
  }
}
```

The client responds with one of three actions — and all three must be handled:

```json
{
  "jsonrpc": "2.0",
  "id": 43,
  "result": {
    "action": "accept",
    "content": { "confirm": true, "change_ticket": "CHG-481502" }
  }
}
```

| `action` | Meaning | Server must |
|---|---|---|
| `accept` | User submitted data | Validate `content` against `requestedSchema` again — never trust it |
| `decline` | User explicitly said no | Abort the operation, return a non-error `CallToolResult` explaining the abort |
| `cancel` | User dismissed without deciding | Treat as decline; do **not** retry the elicitation in a loop |

The `requestedSchema` is restricted to **flat objects of primitives** (string, number, boolean, enum) precisely so hosts can render a generic form without executing server-supplied layout. A server requesting nested objects is asking the client to do something it is not required to support.

Sampling and elicitation are frequently confused. The distinction is one word:

| | **Sampling** | **Elicitation** |
|---|---|---|
| Server asks for | Model inference | Human input |
| Declared capability | Client's `sampling` | Client's `elicitation` |
| Costs | Tokens | Wall-clock and user attention |
| Blocks the tool call | Yes | Yes |
| Injection risk | High (server writes the prompt) | Moderate (server writes the question) |

### 8.3 Roots — `roots/list`

The client tells the server which filesystem or URI boundaries it may operate within. The server calls `roots/list`; the client replies with `file://` URIs (or others). `notifications/roots/list_changed` fires when the user opens a different project.

This is a **scoping hint, not a sandbox.** A filesystem server that consults roots but does not itself enforce path containment is one `../../../etc/shadow` away from an incident. Enforce server-side, in the server, with a resolved-realpath prefix check.

---

## 9. The control plane: progress, cancellation, timeouts, logging

A tool call that takes 90 s looks identical to a hung one unless the flow carries liveness signals.

**Progress** (server → client, requires the caller to have sent `_meta.progressToken`):

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/progress",
  "params": {
    "progressToken": "toolu_01A9k2ZpQ4mR7nX3vB6cH8dY",
    "progress": 37,
    "total": 120,
    "message": "Scanned 37 of 120 series"
  }
}
```

**Cancellation** (either direction):

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/cancelled",
  "params": {
    "requestId": 7,
    "reason": "User aborted the turn"
  }
}
```

**Logging** (server → client, gated by `logging/setLevel`):

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/message",
  "params": {
    "level": "warning",
    "logger": "prometheus-mcp.query",
    "data": {
      "msg": "range query exceeded 11000 points; step coerced",
      "requested_step": "1s",
      "applied_step": "60s"
    }
  }
}
```

The operational rules that make this a control plane rather than decoration:

1. **Cancellation is advisory and racy.** The response may already be in flight. The client MUST ignore a late response for a cancelled request; the server MUST NOT be assumed to have stopped. If the underlying work holds a DB connection or an external write, wire the cancellation to a real `context.CancelFunc` / `asyncio.Task.cancel()`, or you have built a resource leak with a nice JSON envelope.
2. **`initialize` gets its own, shorter timeout.** A server that does not complete the handshake in ~5 s is broken; do not let it consume the 30 s tool timeout.
3. **Progress notifications reset the idle timer, not the total deadline.** Otherwise a chatty server can keep a call alive forever. Enforce both an idle timeout and an absolute deadline.
4. **On stdio, logging goes to stderr — never stdout.** A single `print()` in a Python stdio server corrupts the JSON-RPC framing and the client sees a parse error with no useful context. This is the #1 stdio incident.

### 9.1 Turn budget and loop control

Nothing in MCP terminates the agent loop. The host must.

```python
# host/loop.py
MAX_TURNS = 12
MAX_WALL_SECONDS = 180

async def run_turn(client, conversation, tools, registry, sessions, approvals):
    deadline = time.monotonic() + MAX_WALL_SECONDS
    for turn in range(MAX_TURNS):
        if time.monotonic() > deadline:
            conversation.append(_budget_stop("wall-clock budget exhausted"))
            break

        resp = await client.messages.create(
            model="claude-opus-5",
            max_tokens=16000,
            thinking={"type": "adaptive"},
            output_config={
                "effort": "high",
                "task_budget": {"type": "tokens", "total": 64000},
            },
            betas=["task-budgets-2026-03-13"],
            tools=tools,
            messages=conversation,
        )
        conversation.append({"role": "assistant", "content": resp.content})

        if resp.stop_reason != "tool_use":
            return resp

        results = await run_tool_uses(
            resp.content, registry, sessions, approvals
        )
        conversation.append({"role": "user", "content": results})

        if _repeating(conversation, window=3):       # identical call 3x running
            conversation.append(_budget_stop("loop detected"))
            break
    return await _force_final_answer(client, conversation)
```

`task_budget` is advisory-to-the-model (it paces itself and wraps up gracefully); `MAX_TURNS` and `MAX_WALL_SECONDS` are enforced-by-you. You need both: the first prevents an abrupt cut-off mid-thought, the second prevents an unbounded bill.

---

## 10. Trade-off: where the loop should run

| Property | Manual loop in the host | SDK tool runner | Provider MCP connector | Managed agent platform |
|---|---|---|---|---|
| Code you own | All of it | Tool handlers + hooks | Server registration | Agent config |
| Per-call approval gate | Full control | Per-turn hooks | Provider-limited | Policy-based (`always_ask` / `auto`) |
| Redact before the model sees a result | Yes | Yes (result-modify hook) | No | Partial |
| MCP servers on a private network | Yes | Yes | No — must be public | Depends on platform egress |
| Turn/wall budgets | Yours | Yours | Provider's | Platform-enforced session budgets |
| Resumability after host crash | You persist conversation | You persist conversation | Stateless per request | Platform-managed sessions |
| Time to first working agent | Days | Hours | Minutes | Hours |
| Best fit | Regulated, audited, private-network | Most custom agents | Public SaaS MCP servers | Long-running, scheduled, stateful |

---

## 11. Production deployment

### 11.1 The remote MCP server

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-mcp-config
  namespace: mcp-system
data:
  MCP_TRANSPORT: "streamable-http"
  MCP_BIND_ADDR: "0.0.0.0:8080"
  MCP_PROTOCOL_VERSION: "2025-06-18"
  MCP_SESSION_TTL_SECONDS: "1800"
  MCP_SESSION_STORE: "redis"
  MCP_REDIS_ADDR: "mcp-session-redis.mcp-system.svc.cluster.local:6379"
  MCP_MAX_CONCURRENT_CALLS: "64"
  MCP_CALL_TIMEOUT_SECONDS: "25"
  MCP_MAX_RESULT_BYTES: "262144"
  MCP_RESOURCE_LINK_BASE: "https://prom-mcp.example.com/artifacts"
  PROMETHEUS_URL: "http://prometheus-k8s.monitoring.svc.cluster.local:9090"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
  OTEL_SERVICE_NAME: "prometheus-mcp"
  LOG_LEVEL: "info"
  LOG_FORMAT: "json"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-mcp
  namespace: mcp-system
  labels:
    app.kubernetes.io/name: prometheus-mcp
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
      app.kubernetes.io/name: prometheus-mcp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus-mcp
        app.kubernetes.io/component: mcp-server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: prometheus-mcp
      automountServiceAccountToken: false
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
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus-mcp
      terminationGracePeriodSeconds: 60
      containers:
        - name: server
          image: registry.example.com/mcp/prometheus-mcp:1.9.2
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
                name: prometheus-mcp-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=mcp-system,deployment.environment=prod"
            - name: OIDC_ISSUER
              value: "https://auth.example.com/realms/platform"
            - name: OIDC_AUDIENCE
              value: "https://prom-mcp.example.com/mcp"
            - name: PROMETHEUS_BEARER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: prometheus-mcp-upstream
                  key: bearer-token
          resources:
            requests:
              cpu: 150m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 768Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          startupProbe:
            httpGet:
              path: /healthz
              port: metrics
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /healthz
              port: metrics
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: metrics
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "sleep 15"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: artifacts
              mountPath: /var/lib/mcp/artifacts
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: artifacts
          emptyDir:
            sizeLimit: 1Gi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-mcp
  namespace: mcp-system
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-mcp
  namespace: mcp-system
  labels:
    app.kubernetes.io/name: prometheus-mcp
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: prometheus-mcp
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
  name: prometheus-mcp
  namespace: mcp-system
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus-mcp
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: prometheus-mcp
  namespace: mcp-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: prometheus-mcp
  minReplicas: 3
  maxReplicas: 12
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
          value: 100
          periodSeconds: 30
  metrics:
    - type: Pods
      pods:
        metric:
          name: mcp_active_sessions
        target:
          type: AverageValue
          averageValue: "150"
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prometheus-mcp
  namespace: mcp-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: prometheus-mcp
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: gateway-system
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
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-session-redis
      ports:
        - protocol: TCP
          port: 6379
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 4317
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

The egress policy is the important half. An MCP server is, by construction, a credentialed bridge into a real system. A default-allow egress policy on that pod means a prompt-injection chain that reaches a tool implementation gets arbitrary outbound network. Deny by default, allow the three destinations it actually needs.

### 11.2 Session affinity — the failure that looks like a model bug

`Mcp-Session-Id` binds a conversation to server-side state. With three replicas and round-robin load balancing, two-thirds of requests land on a pod that has never seen the session:

```
HTTP/1.1 404 Not Found
Content-Type: application/json

{"jsonrpc":"2.0","id":9,"error":{"code":-32001,"message":"Session not found"}}
```

Two valid answers, and one that only looks valid:

| Approach | Mechanism | Survives pod restart | Survives scale-down | Complexity |
|---|---|---|---|---|
| **Externalised session state** (recommended) | Session records in Redis; any pod can serve any session | Yes | Yes | Medium — serialise session state |
| **Header-based session persistence at the Gateway** | Route on `Mcp-Session-Id` | No | No | Low |
| `Service.spec.sessionAffinity: ClientIP` | Hash the source IP | No | No | Trivial — **and wrong**: every request arrives from the gateway's IP, so all sessions pin to one pod |

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: prometheus-mcp
  namespace: mcp-system
spec:
  parentRefs:
    - name: platform-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - "prom-mcp.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      sessionPersistence:
        sessionName: Mcp-Session-Id
        type: Header
        absoluteTimeout: 1800s
        idleTimeout: 300s
      timeouts:
        request: 0s
        backendRequest: 0s
      backendRefs:
        - name: prometheus-mcp
          port: 8080
          weight: 100
```

`timeouts.request: 0s` disables the request timeout — mandatory for the `GET /mcp` SSE stream and for POSTs that return an SSE response, both of which are long-lived by design. Leaving the gateway default in place is the second-most-common remote-MCP incident: streams cut at 30 s or 60 s, the client reconnects, and the flow appears to "randomly restart". Gateway API session persistence by header is a GEP-1619 feature — confirm your controller implements it before relying on it, and prefer externalised state if it does not.

### 11.3 Observability of the flow

The unit of observability is not the HTTP request, it is the **turn** — one user prompt through N model calls and M tool calls. Propagate `traceparent` from the host through the MCP client into `tools/call`, and the trace shows the whole loop.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        timeout: 5s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 2s
        limit_percentage: 75
        spike_limit_percentage: 20
      attributes/redact:
        actions:
          - key: gen_ai.prompt
            action: delete
          - key: gen_ai.completion
            action: delete
          - key: mcp.tool.arguments
            action: delete
      resource/env:
        attributes:
          - key: deployment.environment
            value: prod
            action: upsert
    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s, 10s, 30s, 60s]
        dimensions:
          - name: mcp.server.name
          - name: mcp.tool.name
          - name: mcp.method
          - name: gen_ai.request.model
    exporters:
      otlphttp/tempo:
        endpoint: http://tempo.observability.svc.cluster.local:4318
      prometheusremotewrite:
        endpoint: http://prometheus-k8s.monitoring.svc.cluster.local:9090/api/v1/write
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, attributes/redact, resource/env, batch]
          exporters: [otlphttp/tempo, spanmetrics]
        metrics:
          receivers: [otlp, spanmetrics]
          processors: [memory_limiter, resource/env, batch]
          exporters: [prometheusremotewrite]
```

The `attributes/redact` processor is not optional. Tool arguments routinely contain customer identifiers, and prompts contain whatever the user pasted. A trace backend is rarely inside the same data-handling boundary as the application.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-interaction-flow
  namespace: mcp-system
  labels:
    role: alert-rules
spec:
  groups:
    - name: mcp-tool-loop
      interval: 30s
      rules:
        - record: mcp:tool_call_error_ratio:rate5m
          expr: |
            sum by (mcp_server, mcp_tool) (rate(mcp_tool_calls_total{outcome="error"}[5m]))
            /
            clamp_min(sum by (mcp_server, mcp_tool) (rate(mcp_tool_calls_total[5m])), 0.001)

        - alert: MCPToolErrorRatioHigh
          expr: |
            mcp:tool_call_error_ratio:rate5m > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "MCP tool error ratio above 5%"
            description: "Tool {{ $labels.mcp_tool }} on server {{ $labels.mcp_server }} is failing for {{ $value | humanizePercentage }} of calls."

        - alert: MCPToolLatencyP95High
          expr: |
            histogram_quantile(
              0.95,
              sum by (le, mcp_server, mcp_tool) (rate(mcp_tool_call_duration_seconds_bucket[5m]))
            ) > 10
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "MCP tool p95 latency above 10s"
            description: "Server {{ $labels.mcp_server }}, tool {{ $labels.mcp_tool }}."

        - alert: MCPSessionNotFoundSpike
          expr: |
            sum by (mcp_server) (rate(mcp_requests_total{jsonrpc_error_code="-32001"}[5m])) > 0.5
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Session affinity is broken"
            description: "Clients are hitting replicas that do not hold their Mcp-Session-Id. Check the HTTPRoute sessionPersistence or the Redis session store."

        - alert: MCPAgentLoopTurnsSaturated
          expr: |
            sum(rate(agent_turns_exhausted_total[15m]))
            /
            clamp_min(sum(rate(agent_conversations_total[15m])), 0.001)
            > 0.02
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Agent loops are hitting the turn budget"
            description: "More than 2% of conversations exhausted MAX_TURNS — likely a tool returning unusable errors, or a loop."

        - alert: MCPPromptCacheColdSustained
          expr: |
            sum(rate(gen_ai_cache_read_input_tokens_total[10m]))
            /
            clamp_min(sum(rate(gen_ai_input_tokens_total[10m])), 1)
            < 0.2
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Prompt cache hit rate below 20%"
            description: "Something before the last cache breakpoint is varying — check tool array ordering and tools/list_changed churn."
```

**SLI set for the flow**, which is what you should actually page on:

| SLI | Definition | Starting SLO |
|---|---|---|
| Turn success rate | Turns ending in `end_turn` without a budget stop | ≥ 99 % |
| Turn latency p95 | User prompt → final answer, whole loop | ≤ 12 s |
| Tool call success rate | `tools/call` not returning `isError` and not a protocol error | ≥ 99.5 % |
| Tool calls per turn p95 | Loop efficiency; a rise means degrading tool descriptions | ≤ 4 |
| Cache read ratio | `cache_read_input_tokens / input_tokens` | ≥ 0.6 in steady state |
| Session continuity | Turns without a `-32001` / reconnect | ≥ 99.9 % |

---

## 12. CLI: driving and observing the flow by hand

### 12.1 The Inspector

```
$ npx -y @modelcontextprotocol/inspector --cli \
    --transport http \
    --server-url https://prom-mcp.example.com/mcp \
    --header "Authorization: Bearer $MCP_TOKEN" \
    --method tools/list
{
  "tools": [
    {
      "name": "list_metrics",
      "title": "List metric names",
      "description": "Return metric names matching an optional prefix.",
      "annotations": { "readOnlyHint": true, "idempotentHint": true }
    },
    {
      "name": "instant_query",
      "title": "Prometheus instant query",
      "description": "Evaluate a PromQL expression at a single point in time.",
      "annotations": { "readOnlyHint": true, "idempotentHint": true }
    },
    {
      "name": "query_range",
      "title": "Prometheus range query",
      "description": "Evaluate a PromQL expression over a time range.",
      "annotations": { "readOnlyHint": true, "idempotentHint": true, "openWorldHint": true }
    }
  ]
}
```

```
$ npx -y @modelcontextprotocol/inspector --cli \
    --transport http \
    --server-url https://prom-mcp.example.com/mcp \
    --header "Authorization: Bearer $MCP_TOKEN" \
    --method tools/call \
    --tool-name instant_query \
    --tool-arg 'expr=up{job="checkout"}'
{
  "content": [
    {
      "type": "text",
      "text": "resultType=vector seriesCount=4\nup{job=\"checkout\",instance=\"10.4.2.11:8080\"} = 1\nup{job=\"checkout\",instance=\"10.4.2.19:8080\"} = 1\nup{job=\"checkout\",instance=\"10.4.3.7:8080\"} = 0\nup{job=\"checkout\",instance=\"10.4.3.22:8080\"} = 1"
    }
  ],
  "structuredContent": { "resultType": "vector", "seriesCount": 4 },
  "isError": false
}
```

### 12.2 Raw HTTP — the handshake, by hand

```
$ curl -sS -D /tmp/h.txt https://prom-mcp.example.com/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{}},"clientInfo":{"name":"curl-probe","version":"0.1"}}}'
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"logging":{}},"serverInfo":{"name":"prometheus-mcp","title":"Prometheus MCP Server","version":"1.9.2"},"instructions":"Query Prometheus. Always call list_metrics before writing a PromQL expression."}}

$ grep -i '^mcp-session-id' /tmp/h.txt
mcp-session-id: 8f2b1c4e-53a9-4d10-9f7e-6a1b0d3c2e55

$ export SID=8f2b1c4e-53a9-4d10-9f7e-6a1b0d3c2e55

$ curl -sS -o /dev/null -w '%{http_code}\n' https://prom-mcp.example.com/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
202
```

`202 Accepted` with an empty body is the correct answer to a notification — there is no `id`, so there is nothing to respond to. A server returning `200` with a JSON-RPC result here is out of spec.

Now the negative test that catches the most common remote-MCP misconfiguration:

```
$ curl -sS -i https://prom-mcp.example.com/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
HTTP/1.1 400 Bad Request
content-type: application/json

{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Missing required header MCP-Protocol-Version"}}
```

And the unauthenticated probe, which must advertise where to authenticate (RFC 9728):

```
$ curl -sS -i https://prom-mcp.example.com/mcp -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer realm="mcp", resource_metadata="https://prom-mcp.example.com/.well-known/oauth-protected-resource"

$ curl -sS https://prom-mcp.example.com/.well-known/oauth-protected-resource | jq .
{
  "resource": "https://prom-mcp.example.com/mcp",
  "authorization_servers": [
    "https://auth.example.com/realms/platform"
  ],
  "scopes_supported": [
    "mcp:tools:read",
    "mcp:tools:invoke"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

### 12.3 The server-initiated stream

```
$ curl -sS -N https://prom-mcp.example.com/mcp \
    -H "Accept: text/event-stream" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: $SID"
event: message
id: 1
data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"prometheus-mcp","data":{"msg":"session attached"}}}

event: message
id: 2
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"toolu_01A9k2","progress":37,"total":120,"message":"Scanned 37 of 120 series"}}

event: message
id: 3
data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
```

To resume after a disconnect, replay from the last event you processed:

```
$ curl -sS -N https://prom-mcp.example.com/mcp \
    -H "Accept: text/event-stream" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: $SID" \
    -H "Last-Event-ID: 2"
event: message
id: 3
data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
```

A client that reconnects **without** `Last-Event-ID` silently loses everything that happened while it was disconnected — including the `tools/list_changed` that would have told it the tool surface moved. That is failure #2 from §1.

### 12.4 Driving a stdio server directly

```
$ printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./filesystem-mcp --root /srv/projects 2>/tmp/server.err
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},"resources":{}},"serverInfo":{"name":"filesystem-mcp","version":"2.1.0"}}}
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"read_file","description":"Read a UTF-8 text file within an allowed root.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}},{"name":"write_file","description":"Write a UTF-8 text file within an allowed root.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":true}}]}}

$ cat /tmp/server.err
{"ts":"2026-09-17T10:14:02Z","level":"info","msg":"roots configured","roots":["file:///srv/projects"]}
```

Diagnostic value: the entire flow is two newline-delimited JSON streams. `stdout` is protocol; `stderr` is logs. If `stdout` ever contains anything else, the client's parser dies.

### 12.5 Cluster-side checks

```
$ kubectl -n mcp-system get pods -l app.kubernetes.io/name=prometheus-mcp -o wide
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE
prometheus-mcp-6d9c7f4b58-4rjkq   1/1     Running   0          4h    10.244.1.37  node-a1
prometheus-mcp-6d9c7f4b58-9wxtn   1/1     Running   0          4h    10.244.2.19  node-b2
prometheus-mcp-6d9c7f4b58-p2ldc   1/1     Running   0          4h    10.244.3.55  node-c1

$ kubectl -n mcp-system exec deploy/prometheus-mcp -c server -- \
    wget -qO- http://127.0.0.1:9090/metrics | grep -E '^mcp_(active_sessions|tool_calls_total)'
mcp_active_sessions 142
mcp_tool_calls_total{tool="list_metrics",outcome="ok"} 8841
mcp_tool_calls_total{tool="instant_query",outcome="ok"} 21904
mcp_tool_calls_total{tool="query_range",outcome="ok"} 4417
mcp_tool_calls_total{tool="query_range",outcome="error"} 233

$ kubectl -n mcp-system logs deploy/prometheus-mcp -c server --since=5m \
    | jq -r 'select(.level=="error") | "\(.ts) \(.tool) \(.msg)"' | head
2026-09-17T10:11:44Z query_range promql parse error: unexpected "}"
2026-09-17T10:12:01Z query_range exceeded max resolution: 11000 points
2026-09-17T10:13:37Z query_range upstream 503 from prometheus-k8s
```

---

## 13. Verification and failure diagnosis

### 13.1 The verification ladder

Run these in order. Each rung assumes the one below it passed.

| Rung | Question | Command | Pass criterion |
|---|---|---|---|
| 0 | Is the process/endpoint up? | `curl -o /dev/null -w '%{http_code}' .../healthz` | `200` |
| 1 | Does `initialize` complete? | § 12.2 | Result with a `protocolVersion` you accept |
| 2 | Is the negotiated version what you expect? | compare request vs response | Equal, or an acceptable downgrade |
| 3 | Does `tools/list` drain fully? | loop on `nextCursor` | No cursor left, count matches expectation |
| 4 | Does every `inputSchema` parse as JSON Schema? | `jq` + a schema validator in CI | All valid |
| 5 | Does a read-only tool call succeed end-to-end? | § 12.1 | `isError: false` |
| 6 | Does the model actually select the tool? | eval harness, 20 scripted prompts | ≥ 90 % correct selection |
| 7 | Does the loop terminate? | run the eval with `MAX_TURNS` instrumented | 0 budget stops on the happy path |
| 8 | Does cancellation free resources? | cancel mid-call, check upstream connections | Connection count returns to baseline |
| 9 | Does the flow survive a pod restart? | `kubectl rollout restart` mid-conversation | Conversation continues |

Rung 6 is the one teams skip, and it is the only one that tests the *model* side of the interaction flow. Codify it:

```python
# tests/test_tool_selection.py
CASES = [
    ("What's the 5xx rate for checkout right now?",      "prom__instant_query"),
    ("Plot checkout error rate for the last hour",        "prom__query_range"),
    ("Which metrics start with kube_pod?",                "prom__list_metrics"),
    ("Open a ticket for the checkout errors",             "jira__create_issue"),
]

@pytest.mark.parametrize("prompt,expected", CASES)
def test_selects_expected_tool(client, all_tools, prompt, expected):
    resp = client.messages.create(
        model="claude-opus-5",
        max_tokens=4000,
        tools=all_tools,
        messages=[{"role": "user", "content": prompt}],
    )
    called = [b.name for b in resp.content if b.type == "tool_use"]
    assert expected in called, f"{prompt!r} selected {called}, expected {expected}"
```

This test is what catches "someone added a 75th tool whose description overlaps with `query_range`" **before** it reaches users. Treat tool descriptions as production configuration under test, because that is what they are.

### 13.2 Failure catalogue

| Symptom | Layer | Probable cause | Diagnostic | Fix |
|---|---|---|---|---|
| Client hangs at startup, no error | Transport (stdio) | Server wrote non-JSON to stdout (a banner, a `print`) | `./server < /dev/null \| head -c 200` | Route all logging to stderr; add a CI test asserting first stdout byte is `{` |
| `-32601 Method not found` on `tools/call` | Capability | Server never declared `tools` in `initialize` | Inspect the `InitializeResult` | Declare the capability; do not rely on the client probing |
| `400 Missing required header MCP-Protocol-Version` | HTTP envelope | Client omits the header on post-initialize requests | § 12.2 | Send the **negotiated** version on every request |
| `404 Session not found` intermittently, ~2/3 of requests | Routing | No session affinity behind N replicas | `MCPSessionNotFoundSpike` alert | Externalise session state, or header-based `sessionPersistence` |
| SSE stream dies every 60 s, client reconnects | Gateway | Default `backendRequest` timeout on a long-lived stream | `kubectl logs` on the gateway | `timeouts.request: 0s` on the HTTPRoute |
| Notifications lost after a reconnect | Transport | Client reconnects without `Last-Event-ID` | Compare event ids before/after | Persist the last seen id; send it on reconnect |
| Model calls a tool that no longer exists | Discovery | `tools/list_changed` ignored | Count `list_changed` received vs `tools/list` issued | Subscribe to the notification, re-list, rebuild the tool array |
| Wrong server receives a call | Registry | Unnamespaced tool names collide | Log `(public_name, resolved_alias)` on every call | Namespace `alias__tool`; fail startup on collision |
| Latency doubled, cost tripled, no code change | Caching | Tool array order non-deterministic, or a new volatile field in the system prompt | `usage.cache_read_input_tokens == 0` | Sort tools; move volatile content after the last breakpoint |
| Context overflow mid-conversation | Result shaping | Unbounded `tool_result` | Token-count the largest result block | Cap + `resource_link` offload + context editing |
| Agent loops on the same call | Loop control | Tool returns an unhelpful error; model retries identically | Trace shows N identical `tools/call` | Improve the `isError` text; add loop detection on `(name, args)` |
| Tool "succeeds" but the model reports failure | Error channel | Server returns a protocol `error` for a business failure | Wire capture | Return `isError: true` with a diagnostic message instead |
| Cancelled turns keep burning DB connections | Control plane | `notifications/cancelled` received, not wired to cancellation | Upstream connection count after cancel | Bind the request id to a cancellable context |
| Server's sampling request fails | Capability | Client never declared `sampling` | `InitializeResult` from the client side | Declare it, or make the server degrade gracefully |
| Inference bill spikes with no user growth | Reverse flow | A server samples aggressively | Per-server token metrics | Budget and meter sampling separately; require approval |
| `tools/list` returns 12 tools, UI shows 12, server has 30 | Discovery | `nextCursor` ignored | Compare with `--method tools/list` repeated with cursor | Drain the cursor |

### 13.3 The diagnostic reflex

When a flow misbehaves, establish **which of the three legs** is broken before touching anything:

1. **Host ↔ Server.** Reproduce with `curl` or the Inspector, no model involved. If this fails, it is an MCP/infra problem.
2. **Host ↔ Model.** Replay the exact `messages` + `tools` array against the provider API with a fixed conversation. If the model picks the wrong tool here, it is a prompt/description problem.
3. **The loop itself.** Both legs work individually but the conversation misbehaves — budget, ordering, result shaping, cache.

Nine times out of ten a ticket that reads "the AI is broken" is leg 1 with a model-shaped symptom.

---

## 14. Exam-relevant summary

- MCP is **1:1 client-to-server**, embedded in a **1:N host-to-client** application. The host owns the loop; the client owns one session; the server owns one integration.
- Lifecycle: `initialize` → `InitializeResult` → `notifications/initialized` → operation → shutdown. Capabilities are negotiated once, in `initialize`, in both directions.
- The negotiated `protocolVersion` must travel as the `MCP-Protocol-Version` header on every subsequent HTTP request.
- Discovery (`tools/list`) is **paginated** and can change at runtime (`notifications/tools/list_changed`).
- The model never talks to a server. The host translates MCP tool descriptors into provider tool definitions, and translates `tool_use` back into `tools/call`.
- Two error channels: JSON-RPC `error` (for the host) and `isError: true` inside a successful result (for the model). Confusing them breaks recovery or hides outages.
- Reverse flows exist: **sampling** (server → client → model) and **elicitation** (server → client → human), both gated by client-declared capabilities, both requiring human-in-the-loop by design.
- The control plane is `notifications/progress`, `notifications/cancelled`, and `notifications/message`. Cancellation is advisory and racy.
- Nothing in the protocol terminates the agent loop or bounds the tool surface — turn budgets, namespacing, result truncation, and approval policy are host responsibilities.
- Streamable HTTP servers are stateful via `Mcp-Session-Id`; scaling them requires session affinity or externalised session state, and gateway timeouts disabled for streams.

---

## Referencias

**Certification**

- MCPA — Model Context Protocol Associate, Linux Foundation: https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/

**Model Context Protocol — specification and documentation**

- MCP specification index and revisions: https://modelcontextprotocol.io/specification
- Architecture overview: https://modelcontextprotocol.io/docs/learn/architecture
- Lifecycle (initialization, capability negotiation, shutdown): https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Transports (stdio, Streamable HTTP, session management, resumability): https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Tools (`tools/list`, `tools/call`, annotations, structured output, errors): https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Resources and `resource_link`: https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- Prompts: https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- Sampling (`sampling/createMessage`): https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- Elicitation (`elicitation/create`): https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- Roots: https://modelcontextprotocol.io/specification/2025-06-18/client/roots
- Utilities — progress, cancellation, logging, pagination: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
- Authorization (OAuth 2.1 Resource Server): https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Security best practices: https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
- MCP Inspector: https://github.com/modelcontextprotocol/inspector

**Base protocols and standards**

- JSON-RPC 2.0 specification: https://www.jsonrpc.org/specification
- JSON Schema: https://json-schema.org/specification
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://datatracker.ietf.org/doc/html/rfc9728
- RFC 8707 — Resource Indicators for OAuth 2.0: https://datatracker.ietf.org/doc/html/rfc8707
- HTML Living Standard, Server-Sent Events (`Last-Event-ID`): https://html.spec.whatwg.org/multipage/server-sent-events.html

**Model provider — tool-use loop and token accounting**

- Anthropic tool use overview: https://docs.claude.com/en/docs/agents-and-tools/tool-use/overview
- Messages API reference: https://docs.claude.com/en/api/messages
- MCP connector (provider-hosted MCP client): https://docs.claude.com/en/docs/agents-and-tools/mcp-connector
- Prompt caching: https://docs.claude.com/en/docs/build-with-claude/prompt-caching
- Token counting: https://docs.claude.com/en/docs/build-with-claude/token-counting
- Context editing and compaction: https://docs.claude.com/en/docs/build-with-claude/context-editing

**Platform and observability**

- Kubernetes Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Kubernetes Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes HorizontalPodAutoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Gateway API HTTPRoute: https://gateway-api.sigs.k8s.io/api-types/httproute/
- Gateway API session persistence (GEP-1619): https://gateway-api.sigs.k8s.io/geps/gep-1619/
- OpenTelemetry generative-AI semantic conventions: https://opentelemetry.io/docs/specs/semconv/gen-ai/
- OpenTelemetry Collector configuration: https://opentelemetry.io/docs/collector/configuration/
- Prometheus Operator PrometheusRule: https://prometheus-operator.dev/docs/api-reference/api/
- Prometheus querying basics (PromQL): https://prometheus.io/docs/prometheus/latest/querying/basics/