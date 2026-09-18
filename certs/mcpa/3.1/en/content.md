# 3.1 — Interaction Patterns & Response Handling

**Certification:** MCPA — Model Context Protocol Associate (exam version 2026-07-28)
**Exam weight:** 6.5
**Profile:** Principal Platform Architect / Senior SRE
**Prerequisites:** Topic 1.x (protocol fundamentals, JSON-RPC framing), Topic 2.x (lifecycle and capability negotiation)

---

## 1. Motivation: the architectural problem this topic exists to solve

### 1.1 MCP is a session protocol wearing HTTP clothes

The single most expensive misconception in production MCP deployments is treating an MCP server as a REST API. It is not. It is a **stateful, bidirectional, long-lived session** whose message layer happens to be JSON-RPC 2.0 and whose transport *may* be HTTP. Every operational assumption you inherit from REST is wrong in at least one important way:

| REST assumption | MCP reality | Operational consequence |
|---|---|---|
| Request → response, one round trip | Requests flow in **both directions** over one session; the server can call the client (`sampling/createMessage`, `elicitation/create`, `roots/list`) | A gateway that models MCP as request/response silently drops server-initiated traffic |
| Responses arrive in request order | JSON-RPC guarantees **no ordering**; correlation is by `id` only | A client that pops a FIFO queue on each inbound message will hand tool A's result to tool B |
| Any replica can serve any request | The session (`Mcp-Session-Id`) holds negotiated capabilities, subscriptions, and pending server→client requests | Round-robin load balancing produces `404` storms and orphaned requests |
| HTTP status conveys the outcome | `200 OK` is normal for a JSON-RPC error; `202 Accepted` is normal for a successful notification | Alerting on 5xx rates measures your proxy, not your MCP server |
| Errors are errors | MCP has **two distinct error channels** with opposite audiences | Returning the wrong one either hides failures from the model or crashes the agent loop |
| Idle connections are cheap to reap | Server→client streams are idle by design between events | Any LB idle timeout below your keepalive interval tears down healthy sessions |

### 1.2 The failure mode that defines this topic

A tool call fails. There are exactly two ways to report it, and they are **not** interchangeable:

1. **Protocol error** — a JSON-RPC `error` object. Audience: the *client runtime*. Meaning: "this request was not executable." The model never sees it; the agent loop typically raises.
2. **Tool execution error** — a normal JSON-RPC `result` carrying `isError: true`. Audience: the *model*. Meaning: "I ran, and here is what went wrong." The model reads it and can correct itself.

Ship a server that returns `-32603 Internal error` whenever a downstream API returns 500, and you have built an agent that cannot retry, cannot degrade, and cannot explain itself. Ship one that returns `isError: true` for a malformed tool name, and you have built an agent that hallucinates plausible arguments forever. **Response handling is where the model's autonomy is either enabled or destroyed**, and it is decided by which of these two shapes you emit.

### 1.3 Why it matters at platform scale

At one server and one client on stdio, none of this bites. At a fleet — dozens of MCP servers behind an ingress, hundreds of concurrent agent sessions, tools that call databases and cloud APIs — the interaction pattern *is* the reliability envelope:

- A synchronous tool with no progress notifications and a 30-second client timeout becomes an unbounded retry amplifier against your backend.
- A non-idempotent tool plus SSE stream resumption becomes duplicate writes.
- A server that logs to `stdout` on the stdio transport corrupts the frame and takes down the session with `-32700`.
- A sampling request that the client auto-approves is a confused-deputy vector: the server now drives *your* model, on *your* budget, with *your* context.

---

## 2. The message layer: JSON-RPC 2.0 as MCP constrains it

MCP uses JSON-RPC 2.0 but narrows it. Know the narrowing — it is directly examinable.

### 2.1 The three message shapes

| Shape | Required fields | Forbidden / constrained | Response expected |
|---|---|---|---|
| **Request** | `jsonrpc:"2.0"`, `id`, `method` | `id` MUST NOT be `null`; MUST NOT have been used before in the same session by the same sender; `params` optional | Yes, exactly one |
| **Response** | `jsonrpc:"2.0"`, `id` | MUST set **either** `result` **or** `error`, never both; `id` MUST match the request | It *is* the response |
| **Notification** | `jsonrpc:"2.0"`, `method` | MUST NOT include `id` | No — never |

Two consequences SREs get wrong:

- **`id` reuse is a protocol violation, not a style issue.** A client that resets its counter on reconnect while reusing a session will collide with in-flight requests. Use a monotonic counter scoped to the session, or a UUID.
- **`id` may be a string or a number.** A receiver that coerces `"1"` to `1` (or vice versa) will fail correlation against a peer that does not. Compare by type-preserving equality.

### 2.2 Batching: removed, and the exam knows it

| Revision | Batching | Notes |
|---|---|---|
| `2024-11-05` | Not specified | Original release |
| `2025-03-26` | **Supported** (JSON-RPC batch arrays) | Added alongside Streamable HTTP, audio content, progress `message` |
| `2025-06-18` | **Removed** | Batching support was dropped; a top-level JSON array is no longer a valid MCP message |
| Later revisions | Still removed | Verify the exact revision your deployment negotiates |

If you maintain a gateway that coalesces messages into arrays for efficiency, it is protocol-non-compliant against `2025-06-18` and later. Negotiate the version explicitly during `initialize` and branch on it rather than assuming.

### 2.3 A minimal, valid exchange

Request (single JSON document):

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tools/call",
  "params": {
    "name": "query_postgres",
    "arguments": {
      "dsn_alias": "billing-ro",
      "sql": "SELECT count(*) FROM invoices WHERE status = 'OVERDUE'"
    },
    "_meta": {
      "progressToken": "tc-42-9f3a"
    }
  }
}
```

Successful result:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "count\n-----\n  1372\n(1 row)"
      }
    ],
    "structuredContent": {
      "rows": [{ "count": 1372 }],
      "row_count": 1,
      "elapsed_ms": 84
    },
    "isError": false
  }
}
```

Note the shape: `content` is the model-facing rendering, `structuredContent` is the machine-facing payload, and `isError` is the execution verdict. All three are part of one `result`.

---

## 3. Taxonomy of interaction patterns

Every MCP message in production falls into one of these seven patterns. Memorise the direction and the response obligation.

| # | Pattern | Direction | Example methods | Response | Failure if mishandled |
|---|---|---|---|---|---|
| 1 | Client-initiated request | C → S | `initialize`, `tools/list`, `tools/call`, `resources/read`, `prompts/get`, `resources/subscribe`, `completion/complete` | Required | Hang; client timeout |
| 2 | Server-initiated request | **S → C** | `sampling/createMessage`, `elicitation/create`, `roots/list`, `ping` | Required | Server blocks; gateway drops it entirely |
| 3 | Client notification | C → S | `notifications/initialized`, `notifications/cancelled`, `notifications/roots/list_changed`, `notifications/progress` | **None** | Server replies with an `id` → client raises "unknown response" |
| 4 | Server notification | S → C | `notifications/message`, `notifications/progress`, `notifications/resources/updated`, `notifications/tools/list_changed`, `notifications/prompts/list_changed`, `notifications/resources/list_changed`, `notifications/cancelled` | **None** | Stale tool cache; missed logs |
| 5 | Progress streaming | either | `notifications/progress` keyed by `progressToken` | None | Client timeout on a healthy long job |
| 6 | Cancellation | either | `notifications/cancelled` | None (best-effort) | Orphaned work; budget burn |
| 7 | Liveness | either | `ping` | Required, empty result `{}` | Idle LB reaps the session |

### 3.1 Direction is a capability question, not a wiring question

Patterns 2 and 4 are only legal if the corresponding capability was declared during `initialize`. A server that issues `sampling/createMessage` to a client that never advertised `capabilities.sampling` must expect `-32601`. This is the most common source of "method not found" tickets: the method exists in the SDK, but the negotiation never authorised it.

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
      "name": "platform-agent-gateway",
      "title": "Platform Agent Gateway",
      "version": "3.4.1"
    }
  }
}
```

An empty object (`"sampling": {}`) means *supported with no sub-features*. Omitting the key means **not supported**. That distinction is exam material.

---

## 4. Response handling: the two-channel error model

### 4.1 The decision table

This is the single most important table in the topic.

| Situation | Channel | Shape | Rationale |
|---|---|---|---|
| Malformed JSON on the wire | Protocol | `-32700 Parse error` | The model cannot act on a framing bug |
| Message is not valid JSON-RPC | Protocol | `-32600 Invalid Request` | — |
| Method unknown, or capability not negotiated | Protocol | `-32601 Method not found` | The client's tool registry is wrong, not the model's reasoning |
| **Unknown tool name** in `tools/call` | Protocol | `-32602 Invalid params` | The tool does not exist; the model must re-read `tools/list` |
| Arguments violate the tool's `inputSchema` | Protocol | `-32602 Invalid params` | Schema validation is a client-runtime contract |
| Invalid / expired pagination cursor | Protocol | `-32602 Invalid params` | — |
| Resource URI not found (`resources/read`) | Protocol | `-32002 Resource not found` (implementation-defined range) | Spec-illustrated code for this case |
| Unhandled server exception | Protocol | `-32603 Internal error` | Genuinely not the model's problem |
| **Tool ran; upstream API returned 429** | **Execution** | `result` + `isError: true` | The model can back off, or pick another tool |
| Tool ran; SQL syntax error in model-authored query | **Execution** | `result` + `isError: true` | The model can rewrite the query |
| Tool ran; file not found at a model-supplied path | **Execution** | `result` + `isError: true` | The model can list the directory and retry |
| Tool ran; permission denied for the requested action | **Execution** | `result` + `isError: true` | The model can explain the limit to the user |

**Heuristic:** if the model could plausibly *do something different next turn* given the information, it belongs in `isError: true`. If the fix belongs to an engineer, it is a protocol error.

### 4.2 Execution error — the correct shape

```json
{
  "jsonrpc": "2.0",
  "id": 43,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "query_postgres failed: relation \"invoice\" does not exist (SQLSTATE 42P01). Did you mean \"invoices\"? Available tables in schema billing: invoices, invoice_lines, customers, payments."
      }
    ],
    "isError": true
  }
}
```

Notice what makes this *good* rather than merely correct: the message names the tool, gives the machine-readable error class (`42P01`), and supplies the information the model needs to self-correct. An `isError: true` whose text is `"Error"` is functionally equivalent to a protocol error — it terminates progress.

### 4.3 Protocol error — the correct shape

```json
{
  "jsonrpc": "2.0",
  "id": 43,
  "error": {
    "code": -32602,
    "message": "Unknown tool: query_postgress",
    "data": {
      "requested": "query_postgress",
      "available": ["query_postgres", "explain_query", "list_tables"]
    }
  }
}
```

The `data` member is free-form and is where you put anything an operator needs in a log. Do **not** put secrets, DSNs with credentials, or internal hostnames there — `data` routinely ends up in client-side telemetry you do not control.

### 4.4 Reserved and conventional error codes

| Code | Name | Origin | Notes |
|---|---|---|---|
| `-32700` | Parse error | JSON-RPC 2.0 | Framing corruption; on stdio, almost always stray `stdout` writes |
| `-32600` | Invalid Request | JSON-RPC 2.0 | Missing `jsonrpc`, `method`, or a `null` `id` |
| `-32601` | Method not found | JSON-RPC 2.0 | Also used for un-negotiated capabilities |
| `-32602` | Invalid params | JSON-RPC 2.0 | Schema violations, unknown tool, bad cursor |
| `-32603` | Internal error | JSON-RPC 2.0 | Catch-all server fault |
| `-32000` to `-32099` | Server error | JSON-RPC 2.0 reserved range | Implementation-defined |
| `-32002` | Resource not found | MCP spec example | Used in `resources/read` |
| `-32001` | Request timeout | SDK convention (TypeScript SDK `ErrorCode.RequestTimeout`) | Not a spec-mandated code — do not rely on cross-SDK portability |
| `-32000` | Connection closed | SDK convention (TypeScript SDK `ErrorCode.ConnectionClosed`) | Same caveat |

**Architectural rule:** never define your own codes outside `-32000..-32099`, and never assume a peer's non-standard code means what your SDK thinks it means.

### 4.5 Reference client-side response handler

```python
"""Correlation, timeout and cancellation for an MCP client session.

Demonstrates the two-channel model: protocol errors raise, execution errors
are returned to the caller (and therefore to the model) as data.
"""
from __future__ import annotations

import asyncio
import contextlib
import itertools
import time
from dataclasses import dataclass, field
from typing import Any

PROTOCOL_ERROR_IS_FATAL = {-32700, -32600, -32603}


class McpProtocolError(RuntimeError):
    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(f"[{code}] {message}")
        self.code, self.message, self.data = code, message, data


@dataclass
class ToolOutcome:
    """What the agent loop hands back to the model."""
    content: list[dict[str, Any]]
    structured: dict[str, Any] | None
    is_error: bool


@dataclass
class Pending:
    future: asyncio.Future
    method: str
    deadline: float
    progress_token: str | None = None
    last_progress: float = field(default_factory=time.monotonic)


class Session:
    """One MCP session. Correlation is by `id` only -- never by arrival order."""

    # Hard ceiling regardless of how much progress the server reports.
    MAX_TOTAL_SECONDS = 900.0
    IDLE_SECONDS = 60.0

    def __init__(self, transport) -> None:
        self._transport = transport
        self._ids = itertools.count(1)
        self._pending: dict[int, Pending] = {}
        self._progress_index: dict[str, int] = {}

    async def request(self, method: str, params: dict | None = None,
                      *, progress: bool = False) -> dict:
        req_id = next(self._ids)
        params = dict(params or {})
        token = None
        if progress:
            token = f"{method.replace('/', '-')}-{req_id}"
            params.setdefault("_meta", {})["progressToken"] = token
            self._progress_index[token] = req_id

        now = time.monotonic()
        pending = Pending(
            future=asyncio.get_running_loop().create_future(),
            method=method,
            deadline=now + self.MAX_TOTAL_SECONDS,
            progress_token=token,
        )
        self._pending[req_id] = pending

        await self._transport.send({
            "jsonrpc": "2.0", "id": req_id, "method": method, "params": params,
        })

        try:
            return await self._await_with_idle_timeout(pending)
        except asyncio.TimeoutError:
            # Cancellation is a NOTIFICATION: no id, no response, best effort.
            await self._transport.send({
                "jsonrpc": "2.0",
                "method": "notifications/cancelled",
                "params": {"requestId": req_id, "reason": "client timeout"},
            })
            raise
        finally:
            self._pending.pop(req_id, None)
            if token:
                self._progress_index.pop(token, None)

    async def _await_with_idle_timeout(self, pending: Pending) -> dict:
        """Progress notifications reset the idle clock, never the hard ceiling."""
        while True:
            budget = min(self.IDLE_SECONDS,
                         pending.deadline - time.monotonic())
            if budget <= 0:
                raise asyncio.TimeoutError("total request budget exhausted")
            with contextlib.suppress(asyncio.TimeoutError):
                return await asyncio.wait_for(
                    asyncio.shield(pending.future), timeout=budget)
            if time.monotonic() - pending.last_progress >= self.IDLE_SECONDS:
                raise asyncio.TimeoutError("no progress within idle window")

    def on_message(self, msg: dict) -> None:
        """Single entry point for every inbound frame."""
        if "id" not in msg:
            self._on_notification(msg)
            return
        if "method" in msg:
            # Server-initiated request (sampling / elicitation / roots / ping).
            asyncio.create_task(self._on_server_request(msg))
            return

        pending = self._pending.get(msg["id"])
        if pending is None:
            # Late response to a cancelled request: the spec allows the sender
            # to have already emitted it. Drop it; do not raise.
            return
        if "error" in msg:
            err = msg["error"]
            pending.future.set_exception(
                McpProtocolError(err["code"], err.get("message", ""),
                                 err.get("data")))
        else:
            pending.future.set_result(msg["result"])

    def _on_notification(self, msg: dict) -> None:
        if msg.get("method") == "notifications/progress":
            token = msg["params"]["progressToken"]
            req_id = self._progress_index.get(token)
            if req_id is not None and req_id in self._pending:
                self._pending[req_id].last_progress = time.monotonic()

    async def _on_server_request(self, msg: dict) -> None:
        ...  # sampling / elicitation handling -- see section 8

    async def call_tool(self, name: str, arguments: dict) -> ToolOutcome:
        result = await self.request(
            "tools/call", {"name": name, "arguments": arguments}, progress=True)
        return ToolOutcome(
            content=result.get("content", []),
            structured=result.get("structuredContent"),
            is_error=bool(result.get("isError", False)),
        )
```

The important detail is `_on_message`'s three-way branch: **no `id` → notification; `id` + `method` → server request; `id` without `method` → response.** Implementations that branch only on `"method" in msg` will treat server-initiated requests as notifications and never answer them, hanging the server.

---

## 5. Result shapes: content blocks, structured content, resource links

### 5.1 Content block types

| `type` | Required fields | Introduced | Production notes |
|---|---|---|---|
| `text` | `text` | `2024-11-05` | The only universally supported block; always include one |
| `image` | `data` (base64), `mimeType` | `2024-11-05` | Base64 inflates payload ~33%; large images belong behind a `resource_link` |
| `audio` | `data` (base64), `mimeType` | `2025-03-26` | Same size caveat |
| `resource_link` | `uri`, `name`; optional `mimeType`, `description`, `title` | `2025-06-18` | A *pointer*, not content. Not guaranteed to appear in `resources/list`, and not guaranteed subscribable |
| `resource` (embedded) | `resource: { uri, mimeType, text \| blob }` | `2024-11-05` | Inlines the resource; use when the model must see it this turn |

All blocks may carry `annotations` (`audience: ["user"\|"assistant"]`, `priority: 0.0–1.0`, `lastModified`). Clients are free to ignore annotations — treat them as hints for rendering and context-budget decisions, never as an access control mechanism.

### 5.2 Structured content and the backwards-compatibility rule

When a tool declares an `outputSchema`, the result **must** include `structuredContent` that validates against it. The rule that trips implementers: for compatibility with clients that do not understand `structuredContent`, servers **SHOULD also** return the serialised structured data inside a `text` content block. The two are not alternatives — you emit both.

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"cluster\":\"prod-eu-1\",\"unhealthy_nodes\":2,\"nodes\":[{\"name\":\"ip-10-4-2-91\",\"condition\":\"DiskPressure\"},{\"name\":\"ip-10-4-3-17\",\"condition\":\"NotReady\"}]}"
      }
    ],
    "structuredContent": {
      "cluster": "prod-eu-1",
      "unhealthy_nodes": 2,
      "nodes": [
        { "name": "ip-10-4-2-91", "condition": "DiskPressure" },
        { "name": "ip-10-4-3-17", "condition": "NotReady" }
      ]
    },
    "isError": false
  }
}
```

Clients **SHOULD** validate `structuredContent` against the declared `outputSchema`. A validation failure on the client side is a *protocol*-class problem (the server broke its own contract), not something to hand to the model as `isError`.

### 5.3 Trade-off: inline vs. linked results

| Strategy | Latency | Token cost | Resumability | When to use |
|---|---|---|---|---|
| Inline `text` | Lowest | Proportional to size | N/A | Results under a few KB |
| Inline `image`/`audio` base64 | High on large payloads | Very high (vision tokens) | N/A | Small, model must *see* it |
| Embedded `resource` | Medium | Full content in context | N/A | Model must reason over the document now |
| `resource_link` | Lowest | Near zero | Client fetches on demand | Large artefacts, logs, reports |
| `structuredContent` only | Low | Low if client renders compactly | N/A | Downstream code consumes it, not the model |

At fleet scale the `resource_link` pattern is what keeps context budgets survivable: a `kubectl logs` tool that inlines 40 MB of logs will blow the context window on the first call; one that writes to object storage and returns a link plus a 20-line summary will not.

---

## 6. Long-running work: progress, timeouts, cancellation

### 6.1 Progress notifications

Progress is opt-in **by the requester**. The requester places a `progressToken` in `params._meta`; the receiver may then emit `notifications/progress` referencing it. No token means no progress notifications are permitted for that request.

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/progress",
  "params": {
    "progressToken": "tools-call-42",
    "progress": 340,
    "total": 1024,
    "message": "Scanning namespace 12/38 (payments-prod)"
  }
}
```

Rules that are directly examinable:

- `progressToken` MUST be a string or an integer, and MUST be unique across active requests from that sender.
- `progress` MUST increase with each notification; `total` is optional and `progress` is **not** required to be a percentage.
- `message` (a human-readable status string) was added in `2025-03-26`.
- Receivers MUST NOT send progress for a token they were not given.
- Implementations SHOULD rate-limit progress notifications — an unthrottled tight loop is a self-inflicted DoS on the stream.

### 6.2 Timeouts

The spec's guidance is precise and frequently misread:

> Implementations **SHOULD** establish timeouts for all sent requests. They **MAY** reset the timeout clock when they receive a progress notification, but **SHOULD** always enforce a maximum timeout regardless of progress.

That is exactly two clocks — an **idle** clock reset by progress, and a **hard ceiling** that is not. The reference handler in §4.5 implements both. A client that resets only the idle clock can be held open indefinitely by a server that emits progress forever; a client with only a hard ceiling kills legitimate 20-minute migrations.

### 6.3 Cancellation

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/cancelled",
  "params": {
    "requestId": 42,
    "reason": "User aborted the agent run"
  }
}
```

The semantics are best-effort and racy by design:

- Cancellation is a **notification** — no `id`, no response, no acknowledgement.
- The `requestId` MUST refer to a request previously issued **in the same direction**.
- Clients **MUST NOT** cancel the `initialize` request.
- The receiver **SHOULD** stop work and **SHOULD NOT** send a response for that request — but a response already in flight is legal and the sender **MUST** tolerate it (drop it silently; see `on_message` above).
- Both sides **MUST** ignore cancellations for unknown IDs. Do not log these at `error`; they are expected under race.

**Side-effect warning:** cancellation does not roll anything back. If your tool has begun a non-idempotent write, cancellation does not undo it. Tools that mutate state should accept an idempotency key in their arguments and record it before the first write.

### 6.4 Strategies for work longer than a request

| Strategy | Client complexity | Survives disconnect | Cancellation fidelity | Good fit |
|---|---|---|---|---|
| Block synchronously | Trivial | No | Timeout only | Sub-second tools |
| Progress notifications + idle reset | Low | No (stream-bound) | Best-effort | Seconds to a few minutes; the default |
| Return a handle; poll via a second tool | Medium | **Yes** | Explicit cancel tool | Minutes to hours; migrations, scans, builds |
| Return a `resource_link` + `resources/subscribe` | Medium | Yes | Unsubscribe | Artefacts produced asynchronously |
| Protocol-level long-running task primitives | SDK-dependent | Yes | Native | Revision-gated — see below |

**Revision caveat, stated honestly:** later spec revisions (from `2025-11-25` onward) introduce first-class primitives for long-running operations so that a request can be handed off and polled at the protocol level rather than through a hand-rolled handle-and-poll tool pair. Feature availability and method names differ by revision and by SDK maturity. **Do not design against it from memory** — read the revision your `initialize` actually negotiates at `https://modelcontextprotocol.io/specification/` and confirm the capability is advertised before depending on it. The handle-and-poll pattern in row three works on every revision and is the safe default for the exam and for production.

### 6.5 Ping

```json
{ "jsonrpc": "2.0", "id": "ping-1758067200", "method": "ping" }
```

The response is an empty result — `{"jsonrpc":"2.0","id":"ping-1758067200","result":{}}`. Either side may ping. If a ping goes unanswered within a reasonable window the sender **MAY** consider the connection stale and terminate it.

Operationally: **set your ping interval below the smallest idle timeout on the path.** With an ingress at 60 s and a cloud LB at 350 s, ping every 25–30 s. Excessive pinging is explicitly discouraged by the spec and costs you nothing but noise — but too-rare pinging costs you sessions.

---

## 7. Pagination and list-change invalidation

### 7.1 Cursor semantics

`resources/list`, `resources/templates/list`, `prompts/list`, and `tools/list` are cursor-paginated. The cursor is an **opaque string**. Clients MUST NOT parse, construct, guess, or persist assumptions about it.

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "tools": [
      {
        "name": "query_postgres",
        "title": "Query PostgreSQL (read-only)",
        "description": "Run a read-only SQL statement against an allow-listed DSN alias.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "dsn_alias": { "type": "string", "enum": ["billing-ro", "analytics-ro"] },
            "sql": { "type": "string", "maxLength": 8192 }
          },
          "required": ["dsn_alias", "sql"]
        }
      }
    ],
    "nextCursor": "eyJvIjoxMDAsInMiOiJ0b29scy12MTQifQ"
  }
}
```

- **Absence** of `nextCursor` means the end of the list. An empty-string cursor is not a terminator.
- An invalid or expired cursor **SHOULD** yield `-32602 Invalid params`.
- Page size is server-determined. Clients must not assume it is stable across pages.

### 7.2 The invalidation race

```
tools/list        -> page 1 + nextCursor C1
notifications/tools/list_changed   <-- server's tool set changed
tools/list?cursor=C1  -> -32602 Invalid params
```

Correct client behaviour: on any `*/list_changed` notification, **discard the in-flight pagination and restart from page one.** Attempting to continue with a stale cursor is at best inconsistent and at worst an error loop. Servers SHOULD treat cursors as generation-stamped and reject stale ones rather than silently returning a torn view.

| Notification | Invalidates | Client action |
|---|---|---|
| `notifications/tools/list_changed` | Tool registry + tool schemas | Re-list; re-publish tool definitions to the model |
| `notifications/prompts/list_changed` | Prompt catalogue | Re-list |
| `notifications/resources/list_changed` | Resource catalogue | Re-list |
| `notifications/resources/updated` | One resource's **content** (by `uri`) | Re-`resources/read` that URI only |
| `notifications/roots/list_changed` (C → S) | Server's view of client roots | Server re-issues `roots/list` |

Note the asymmetry in the fourth row: `resources/updated` names a single URI and does **not** invalidate the list. Re-listing on every content update is a common and expensive bug.

---

## 8. Server-initiated requests: sampling and elicitation

These are the two patterns that break naive gateways, and the two that carry the sharpest security requirements.

### 8.1 Sampling — the server asks the client's model for a completion

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
          "text": "Classify this alert as one of: noise, degradation, outage.\n\nALERT: KubePodCrashLooping ns=payments pod=checkout-7f9 restarts=143"
        }
      }
    ],
    "modelPreferences": {
      "hints": [{ "name": "claude-sonnet" }],
      "costPriority": 0.7,
      "speedPriority": 0.8,
      "intelligencePriority": 0.3
    },
    "systemPrompt": "You are a triage classifier. Answer with one word.",
    "includeContext": "thisServer",
    "maxTokens": 16
  }
}
```

Result:

```json
{
  "jsonrpc": "2.0",
  "id": 91,
  "result": {
    "role": "assistant",
    "content": { "type": "text", "text": "degradation" },
    "model": "claude-sonnet-4-5",
    "stopReason": "endTurn"
  }
}
```

Key points:

- `modelPreferences.hints` are **advisory substrings**, not model IDs. The client maps them to whatever it actually has and reports the real model in `result.model`. A server that assumes it got the hinted model is wrong.
- The three priority values are independent `0.0–1.0` floats, not a distribution that must sum to 1.
- `includeContext` is one of `none`, `thisServer`, `allServers`. `allServers` is a genuine cross-server data-flow decision — in a multi-tenant gateway it is the setting that leaks tenant A's context into tenant B's server. Default it to `none` and require explicit allow-listing.
- The spec is explicit that clients **SHOULD** implement human-in-the-loop approval: users should be able to review and modify the prompt before it is sent, and review the completion before it is returned.

**Threat model:** sampling inverts the trust direction. The server is typically the less-trusted party, and sampling lets it drive your model with your credentials and your budget. Treat auto-approval as a deliberate, audited configuration — never a default.

### 8.2 Elicitation — the server asks the client's *user* for input

```json
{
  "jsonrpc": "2.0",
  "id": 92,
  "method": "elicitation/create",
  "params": {
    "message": "Confirm the target cluster for this rollout.",
    "requestedSchema": {
      "type": "object",
      "properties": {
        "cluster": {
          "type": "string",
          "title": "Cluster",
          "enum": ["prod-eu-1", "prod-us-1", "staging-eu-1"]
        },
        "confirm": {
          "type": "boolean",
          "title": "I understand this is a production change",
          "default": false
        }
      },
      "required": ["cluster", "confirm"]
    }
  }
}
```

Constraints that are exam-relevant:

- `requestedSchema` is a **flat object with primitive properties only** — `string`, `number`/`integer`, `boolean`, and `enum`. No nesting, no arrays of objects. This exists so clients can auto-render a form without executing arbitrary schema logic.
- The result carries an `action` that is exactly one of `accept`, `decline`, `cancel`:

```json
{
  "jsonrpc": "2.0",
  "id": 92,
  "result": {
    "action": "accept",
    "content": { "cluster": "prod-eu-1", "confirm": true }
  }
}
```

  - `accept` — user submitted; `content` present.
  - `decline` — user explicitly refused; `content` absent.
  - `cancel` — user dismissed without deciding; `content` absent.

  Servers **must** distinguish `decline` from `cancel`. Retrying after a `decline` is a spec violation in spirit and a UX disaster in practice.
- Servers **MUST NOT** use elicitation to request secrets, tokens, or passwords. Clients **SHOULD** make the requesting server's identity visible in the prompt and allow the user to decline at any time.

### 8.3 Sampling vs. server-side inference

| Dimension | `sampling/createMessage` | Server calls an LLM itself |
|---|---|---|
| Who pays | The client/user | The server operator |
| Credential location | Client only | Server needs its own API key |
| Model consistency | Client's model, reported in `result.model` | Server's choice |
| Human-in-the-loop | Supported by design | Impossible |
| Requires client capability | Yes (`capabilities.sampling`) | No |
| Works over a request/response-only gateway | **No** | Yes |
| Auditability | Client-side, full prompt visible | Opaque to the client |

The last row is why sampling is preferable when it is available: the client sees exactly what the server wanted the model to do. The sixth row is why many production deployments cannot use it — see §9.

---

## 9. Transport-level response handling

### 9.1 stdio vs. Streamable HTTP

| Dimension | stdio | Streamable HTTP |
|---|---|---|
| Framing | Newline-delimited JSON on `stdin`/`stdout` | HTTP body (`application/json`) or SSE (`text/event-stream`) |
| Server→client requests | Native (same pipe) | Requires an open SSE stream |
| Session identity | The process | `Mcp-Session-Id` header |
| Multi-client | One client per process | Many sessions per server |
| Auth | Inherited from the process/user | HTTP layer (OAuth 2.1 / bearer) |
| Horizontal scaling | N/A | Requires session affinity or shared session state |
| Resumability | None (process death = session death) | `Last-Event-ID` replay on the SSE stream |
| Logging | **`stderr` only** | Normal HTTP logging |
| Deployment shape | Sidecar / local subprocess | Deployment + Service + Ingress |
| Primary failure mode | Stray `stdout` write → `-32700` | Proxy buffering, sticky-session loss, idle timeouts |

**The stdio rule that catches everyone:** messages MUST NOT contain embedded newlines, and the server MUST NOT write anything to `stdout` that is not a valid MCP message. A single `print()` left in a handler, a library that logs to stdout by default, a Python warning — any of these corrupts the frame. Route all diagnostics to `stderr`.

### 9.2 Streamable HTTP mechanics

One endpoint (conventionally `/mcp`) supporting `POST`, `GET`, and `DELETE`.

| Verb | Client `Accept` | Server response | Meaning |
|---|---|---|---|
| `POST` (contains a request) | `application/json, text/event-stream` | `200` with `Content-Type: application/json` **or** `text/event-stream` | Single JSON response, or an SSE stream carrying the response plus related notifications/requests |
| `POST` (only notifications/responses) | as above | `202 Accepted`, empty body | Nothing to return |
| `GET` | `text/event-stream` | `200` SSE stream, or `405` | The server→client channel for unsolicited messages |
| `DELETE` | — | `200`/`204`, or `405` | Explicit session termination |
| Any, with expired `Mcp-Session-Id` | — | `404 Not Found` | Client MUST start a new session with `initialize` |
| `POST`/`GET` missing required `Accept` | — | `406 Not Acceptable` | Client bug |

Other requirements:

- If the server assigns `Mcp-Session-Id` on `initialize`, the client **MUST** echo it on every subsequent request.
- From `2025-06-18`, clients **MUST** send `MCP-Protocol-Version: <negotiated>` on every request after initialization. A server receiving no such header **SHOULD** assume `2025-03-26` for backwards compatibility; an invalid value **SHOULD** yield `400 Bad Request`.
- Servers **MUST** validate the `Origin` header to prevent DNS-rebinding attacks, and local servers **SHOULD** bind to `127.0.0.1` rather than `0.0.0.0`.
- SSE events **SHOULD** carry an `id`; a reconnecting client sends `Last-Event-ID` and the server **MUST** replay only the messages that would have followed on **that** stream.

### 9.3 The three platform-level traps

**Trap 1 — Session affinity.** The `Mcp-Session-Id` binds to in-memory state on one replica. Round-robin routing sends request *n+1* to a replica that has never heard of the session → `404` → the client re-initializes → the tool call is lost. `Service.sessionAffinity: ClientIP` does **not** fix this behind an ingress controller, because every packet arrives from an ingress pod's IP. You need **L7 cookie affinity at the ingress**, or an externalised session store.

**Trap 2 — Proxy buffering.** SSE requires the proxy to forward bytes as they arrive. Default `proxy_buffering on` in NGINX holds events until the buffer fills or the response ends, which for a long-lived stream means "forever". The symptom is pathognomonic: everything works, slowly, and then all events arrive at once at the end.

**Trap 3 — Idle timeouts.** `proxy_read_timeout` defaults to 60 s. An SSE stream with no events for 61 s is closed as dead. Fix both ends: raise the proxy timeout **and** keep the ping interval below it.

---

## 10. Complete infrastructure manifests

A production Streamable HTTP MCP server on Kubernetes, correct for the three traps above. Nothing here is elided.

### 10.1 Namespace and configuration

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp
  labels:
    app.kubernetes.io/part-of: agent-platform
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-postgres-config
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-postgres
data:
  server.yaml: |
    transport:
      kind: streamable-http
      bind: "0.0.0.0:8080"
      endpoint: /mcp
      # DNS-rebinding protection: the spec requires Origin validation.
      allowed_origins:
        - "https://agents.example.com"
        - "https://console.example.com"
    protocol:
      # Highest revision this build implements; the negotiated value may be lower.
      preferred_version: "2025-06-18"
      minimum_version: "2025-03-26"
    session:
      # Must exceed the ingress read timeout so the proxy never outlives us.
      idle_ttl_seconds: 1800
      absolute_ttl_seconds: 14400
      ping_interval_seconds: 25
      # Replayable SSE backlog for Last-Event-ID resumption.
      event_buffer_size: 512
    responses:
      # Execution failures are returned as isError results, never JSON-RPC errors.
      tool_errors_as_is_error: true
      max_inline_bytes: 65536
      overflow_strategy: resource_link
      redact_patterns:
        - "(?i)password=[^\\s]+"
        - "(?i)authorization:\\s*bearer\\s+[^\\s]+"
    progress:
      enabled: true
      min_interval_ms: 500
      max_notifications_per_request: 240
    limits:
      max_request_bytes: 1048576
      max_concurrent_tool_calls_per_session: 4
      tool_hard_timeout_seconds: 600
    logging:
      # stdout is reserved for MCP framing on stdio; on HTTP we still use stderr.
      sink: stderr
      format: json
      default_level: info
```

### 10.2 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-postgres
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-postgres
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
      app.kubernetes.io/name: mcp-postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-postgres
        app.kubernetes.io/component: mcp-server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      # Long enough to drain in-flight SSE sessions instead of cutting them.
      terminationGracePeriodSeconds: 150
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
              app.kubernetes.io/name: mcp-postgres
      containers:
        - name: server
          image: registry.example.com/agent-platform/mcp-postgres:1.9.3
          imagePullPolicy: IfNotPresent
          args:
            - --config=/etc/mcp/server.yaml
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          env:
            - name: MCP_LOG_LEVEL
              value: info
            - name: OTEL_SERVICE_NAME
              value: mcp-postgres
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc:4317"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: mcp-postgres-dsn
                  key: password
          # Probes hit /healthz and /readyz -- NEVER /mcp. A bare GET on the MCP
          # endpoint without a session is not a health signal.
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
                # Fail readiness first, let the ingress stop sending new sessions,
                # then let in-flight streams finish inside the grace period.
                command:
                  - /bin/sh
                  - -c
                  - "/usr/local/bin/mcp-drain --deadline=120s"
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
          volumeMounts:
            - name: config
              mountPath: /etc/mcp
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: mcp-postgres-config
        - name: tmp
          emptyDir:
            sizeLimit: 128Mi
```

### 10.3 Service, PodDisruptionBudget, autoscaling

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mcp-postgres
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-postgres
spec:
  type: ClusterIP
  # ClientIP affinity is useless behind an ingress controller (every packet
  # arrives from an ingress pod). Real affinity is the cookie in the Ingress.
  sessionAffinity: None
  selector:
    app.kubernetes.io/name: mcp-postgres
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
  name: mcp-postgres
  namespace: mcp
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-postgres
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: mcp-postgres
  namespace: mcp
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: mcp-postgres
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
          averageValue: "120"
  behavior:
    scaleDown:
      # Sessions are sticky and long-lived; scaling down fast evicts them.
      stabilizationWindowSeconds: 900
      policies:
        - type: Pods
          value: 1
          periodSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
```

### 10.4 Ingress — the three traps, fixed

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mcp-postgres
  namespace: mcp
  annotations:
    # Trap 1: L7 cookie affinity pins a session to one replica.
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/affinity-mode: "persistent"
    nginx.ingress.kubernetes.io/session-cookie-name: "mcp_affinity"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "14400"
    nginx.ingress.kubernetes.io/session-cookie-expires: "14400"
    nginx.ingress.kubernetes.io/session-cookie-samesite: "Lax"
    # Trap 2: buffering holds SSE events until the response ends.
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Connection "";
      proxy_http_version 1.1;
      chunked_transfer_encoding off;
    # Trap 3: idle SSE streams look dead to a 60s read timeout.
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "10"
    nginx.ingress.kubernetes.io/proxy-body-size: "1m"
    cert-manager.io/cluster-issuer: "letsencrypt-production"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - "mcp.example.com"
      secretName: mcp-example-com-tls
  rules:
    - host: "mcp.example.com"
      http:
        paths:
          - path: /mcp
            pathType: Prefix
            backend:
              service:
                name: mcp-postgres
                port:
                  name: http
```

> `chunked_transfer_encoding off` applies to the response NGINX generates toward the client; the upstream SSE stream is proxied unbuffered because of `proxy-buffering: "off"`. Applications behind other proxies (Envoy, HAProxy, cloud ALBs) need the equivalent knobs: Envoy `stream_idle_timeout` and no response buffering filter; HAProxy `timeout tunnel`; ALB idle timeout above your ping interval. Many application frameworks also emit `X-Accel-Buffering: no` on SSE responses, which NGINX honours — belt and braces.

### 10.5 Observability

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mcp-postgres
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - mcp
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-postgres
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-response-handling
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp.response-handling
      interval: 30s
      rules:
        - alert: MCPProtocolErrorRatioHigh
          expr: |
            sum by (server, code) (
              rate(mcp_jsonrpc_responses_total{outcome="error"}[5m])
            )
            /
            sum by (server) (
              rate(mcp_jsonrpc_responses_total[5m])
            )
            > 0.02
          for: 10m
          labels:
            severity: warning
            team: agent-platform
          annotations:
            summary: "MCP protocol errors above 2% on {{ $labels.server }}"
            description: "{{ $labels.server }} is returning JSON-RPC code {{ $labels.code }} for {{ $value | humanizePercentage }} of responses. Protocol errors are client-runtime faults, not tool failures: check capability negotiation and inputSchema validation."
            runbook_url: "https://runbooks.example.com/mcp/protocol-errors"

        - alert: MCPToolErrorRatioHigh
          expr: |
            sum by (server, tool) (
              rate(mcp_tool_calls_total{is_error="true"}[15m])
            )
            /
            sum by (server, tool) (
              rate(mcp_tool_calls_total[15m])
            )
            > 0.25
          for: 15m
          labels:
            severity: warning
            team: agent-platform
          annotations:
            summary: "Tool {{ $labels.tool }} failing for a quarter of calls"
            description: "isError=true on {{ $value | humanizePercentage }} of calls to {{ $labels.tool }}. The model is being told it failed; check the upstream dependency before the agent loop burns budget retrying."

        - alert: MCPSessionNotFoundSpike
          expr: |
            sum by (server) (
              rate(mcp_http_responses_total{status="404"}[5m])
            )
            > 1
          for: 5m
          labels:
            severity: critical
            team: agent-platform
          annotations:
            summary: "Mcp-Session-Id 404s on {{ $labels.server }}"
            description: "Requests are reaching replicas that do not own the session. Verify ingress cookie affinity (mcp_affinity) survived the last rollout, and that session TTL exceeds the affinity cookie lifetime."

        - alert: MCPStreamStallNoProgress
          expr: |
            histogram_quantile(
              0.99,
              sum by (le, server) (
                rate(mcp_request_duration_seconds_bucket{method="tools/call"}[10m])
              )
            )
            > 300
          for: 10m
          labels:
            severity: warning
            team: agent-platform
          annotations:
            summary: "p99 tools/call latency over 5 minutes on {{ $labels.server }}"
            description: "Long tool calls without progress notifications will hit client idle timeouts. Confirm the tool emits notifications/progress and that clients pass a progressToken."

        - alert: MCPPingUnanswered
          expr: |
            sum by (server) (
              increase(mcp_ping_timeouts_total[10m])
            )
            > 5
          for: 10m
          labels:
            severity: warning
            team: agent-platform
          annotations:
            summary: "Unanswered MCP pings on {{ $labels.server }}"
            description: "Keepalives are not round-tripping. Compare the ping interval against every idle timeout on the path: ingress proxy-read-timeout, cloud LB idle timeout, and any service mesh stream_idle_timeout."
```

### 10.6 Egress policy for a server that uses sampling

A server that issues `sampling/createMessage` needs **no outbound LLM access** — that is the point. Enforce it:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mcp-postgres-egress
  namespace: mcp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-postgres
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
    # DNS
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
    # The one allow-listed database
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: data
          podSelector:
            matchLabels:
              app.kubernetes.io/name: postgres-billing
      ports:
        - protocol: TCP
          port: 5432
    # Telemetry
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 4317
  # No egress to the public internet: sampling goes back over the MCP session.
```

---

## 11. Verification and failure diagnosis

### 11.1 Streamable HTTP: the full handshake by hand

```
$ curl -sS -D- -o /tmp/init.out -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'Origin: https://agents.example.com' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"sampling":{},"elicitation":{},"roots":{"listChanged":true}},"clientInfo":{"name":"curl-probe","version":"0.1.0"}}}'
HTTP/2 200
content-type: text/event-stream
mcp-session-id: 0f6d5c2e-9a41-4b7f-8e33-1c0d4a7b5e90
cache-control: no-cache, no-transform
x-accel-buffering: no
date: Thu, 17 Sep 2026 09:14:02 GMT

$ cat /tmp/init.out
event: message
id: 1
data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"logging":{},"completions":{}},"serverInfo":{"name":"mcp-postgres","title":"PostgreSQL (read-only)","version":"1.9.3"},"instructions":"Use query_postgres for read-only SQL. DSN aliases are allow-listed."}}
```

Capture the session id and complete initialization. Note the `202` — a notification has nothing to return:

```
$ SID=0f6d5c2e-9a41-4b7f-8e33-1c0d4a7b5e90
$ curl -sS -D- -o /dev/null -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
HTTP/2 202
date: Thu, 17 Sep 2026 09:14:03 GMT
content-length: 0
```

List tools:

```
$ curl -sS -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | sed -n 's/^data: //p' | jq '.result.tools[].name'
"query_postgres"
"explain_query"
"list_tables"
```

Open the server→client stream in a second terminal. `-N` disables curl's own buffering:

```
$ curl -sS -N -X GET https://mcp.example.com/mcp \
    -H 'Accept: text/event-stream' \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18'
: keepalive

event: message
id: 17
data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"pool","data":"connection pool warm: 8/8"}}

event: message
id: 18
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"tools-call-3","progress":1,"total":3,"message":"planning query"}}

event: message
id: 19
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"tools-call-3","progress":3,"total":3,"message":"streaming rows"}}
```

Terminate the session explicitly rather than abandoning it:

```
$ curl -sS -D- -o /dev/null -X DELETE https://mcp.example.com/mcp \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18'
HTTP/2 204
date: Thu, 17 Sep 2026 09:22:41 GMT

$ curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":9,"method":"tools/list"}'
404
```

That `404` is correct and is the signal for a client to re-`initialize`.

### 11.2 Proving the two error channels

Execution error — `200 OK`, `result`, `isError: true`:

```
$ curl -sS -D- -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query_postgres","arguments":{"dsn_alias":"billing-ro","sql":"SELECT * FROM invoice LIMIT 1"}}}' \
  | tail -n1 | sed -n 's/^data: //p' | jq .
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "query_postgres failed: relation \"invoice\" does not exist (SQLSTATE 42P01). Tables available in schema billing: invoices, invoice_lines, customers, payments."
      }
    ],
    "isError": true
  }
}
```

Protocol error — still `200 OK` at the HTTP layer, but an `error` member:

```
$ curl -sS -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_postgress","arguments":{}}}' \
  | sed -n 's/^data: //p' | jq .
{
  "jsonrpc": "2.0",
  "id": 5,
  "error": {
    "code": -32602,
    "message": "Unknown tool: query_postgress",
    "data": {
      "requested": "query_postgress",
      "available": ["query_postgres", "explain_query", "list_tables"]
    }
  }
}
```

**If both of these return the same shape, the server is broken** — regardless of which shape it chose.

### 11.3 Negative probes that should fail

```
$ curl -sS -o /dev/null -w 'no-accept:      %{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":6,"method":"ping"}'
no-accept:      406

$ curl -sS -o /dev/null -w 'bad-origin:     %{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'Origin: https://evil.example.net' -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":7,"method":"ping"}'
bad-origin:     403

$ curl -sS -o /dev/null -w 'bad-version:    %{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 1999-01-01' -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":8,"method":"ping"}'
bad-version:    400

$ curl -sS -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18' \
    --data-raw '{"jsonrpc":"2.0","id":9,"method":' | sed -n 's/^data: //p'
{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
```

The last one is the only legitimate use of `"id": null` in MCP: a parse error where the id could not be recovered.

### 11.4 stdio: smoke test without any client

```
$ printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./mcp-postgres --stdio 2>/tmp/server.err
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"mcp-postgres","version":"1.9.3"}}}
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"query_postgres","title":"Query PostgreSQL (read-only)","inputSchema":{"type":"object","properties":{"dsn_alias":{"type":"string"},"sql":{"type":"string"}},"required":["dsn_alias","sql"]}}]}}
```

Now the test that finds the classic bug — **every line on stdout must be valid JSON**:

```
$ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  | ./mcp-postgres --stdio 2>/dev/null \
  | while IFS= read -r line; do
      printf '%s' "$line" | jq -e . >/dev/null 2>&1 \
        || { printf 'NOT JSON ON STDOUT: %s\n' "$line"; exit 1; }
    done && echo "stdout framing OK"
NOT JSON ON STDOUT: [pool] connected to billing-ro in 42ms
```

That stray log line is a `-32700` waiting to happen. Fix: route it to `stderr`.

### 11.5 MCP Inspector CLI

```
$ npx @modelcontextprotocol/inspector --cli ./mcp-postgres --stdio --method tools/list
{
  "tools": [
    {
      "name": "query_postgres",
      "title": "Query PostgreSQL (read-only)",
      "description": "Run a read-only SQL statement against an allow-listed DSN alias.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "dsn_alias": { "type": "string", "enum": ["billing-ro", "analytics-ro"] },
          "sql": { "type": "string", "maxLength": 8192 }
        },
        "required": ["dsn_alias", "sql"]
      }
    }
  ]
}

$ npx @modelcontextprotocol/inspector --cli ./mcp-postgres --stdio \
    --method tools/call \
    --tool-name query_postgres \
    --tool-arg dsn_alias=billing-ro \
    --tool-arg "sql=SELECT count(*) FROM invoices WHERE status = 'OVERDUE'"
{
  "content": [
    { "type": "text", "text": "count\n-----\n  1372\n(1 row)" }
  ],
  "structuredContent": { "rows": [{ "count": 1372 }], "row_count": 1, "elapsed_ms": 84 },
  "isError": false
}

$ npx @modelcontextprotocol/inspector --cli https://mcp.example.com/mcp \
    --transport http --method tools/list
```

The CLI mode is what belongs in CI. Wire it into a contract test that asserts, for every tool: (a) `tools/list` returns a valid `inputSchema`; (b) a known-bad argument yields `-32602`; (c) a known-failing invocation yields `isError: true` and **not** a JSON-RPC error.

### 11.6 Failure diagnosis matrix

| # | Symptom | Most likely cause | Check | Fix |
|---|---|---|---|---|
| 1 | Client hangs forever on `tools/call`, no error | Server never responds; no progress; no client timeout | `curl -N` the GET stream — any traffic? | Enforce idle + hard timeouts (§4.5); emit `notifications/progress` |
| 2 | Intermittent `404` on POST mid-session | Request routed to a replica that does not own the session | `kubectl logs -l app.kubernetes.io/name=mcp-postgres \| grep 'unknown session'` across pods | Ingress cookie affinity (§10.4), or externalise session state |
| 3 | All SSE events arrive at once, at the end | Proxy buffering | `curl -sSI` the endpoint for `x-accel-buffering`; check `proxy-buffering` annotation | `proxy-buffering: "off"` + emit `X-Accel-Buffering: no` |
| 4 | Stream dies after exactly 60 s of quiet | Proxy idle timeout below the ping interval | Compare `proxy-read-timeout` with the server's `ping_interval_seconds` | Raise the timeout; ping every 25–30 s |
| 5 | `-32601 Method not found` for a method the SDK has | Capability never negotiated in `initialize` | Inspect the `initialize` result's `capabilities` | Declare the capability on both sides |
| 6 | Model never learns the tool failed; agent loop raises | Server returns JSON-RPC `error` for execution failures | Run the §11.2 pair — do both return `error`? | Convert execution failures to `isError: true` |
| 7 | Model hallucinates arguments in a loop | Unknown-tool failures returned as `isError` instead of `-32602` | Same probe, inverted | Unknown tool / schema violation → protocol error |
| 8 | Duplicate writes after a network blip | SSE replay via `Last-Event-ID` re-delivered a request, and the tool is not idempotent | Correlate `mcp_tool_calls_total` against upstream write counts | Idempotency keys recorded before first write; deduplicate replayed event ids |
| 9 | `-32700 Parse error` on stdio, always | Something writes to `stdout` that is not MCP | Run the §11.4 framing check | Route all logs to `stderr` |
| 10 | `-32602` on page 2 of `tools/list` | Cursor invalidated by `notifications/tools/list_changed` | Check for a `list_changed` between the two calls | Restart pagination on any `*/list_changed` |
| 11 | Client raises "response for unknown id" | Peer reused an `id`, or a late response to a cancelled request | Log id allocation per session | Monotonic per-session ids; silently drop late responses |
| 12 | Rolling update drops live agent runs | Grace period shorter than the longest tool call | `terminationGracePeriodSeconds` vs `tool_hard_timeout_seconds` | `maxUnavailable: 0`, preStop drain, grace > longest call |
| 13 | Server's sampling requests are never answered | Gateway models MCP as request/response and discards server→client traffic | Does the client hold a GET SSE stream open? | Use a real MCP-aware proxy, or stop depending on sampling |
| 14 | Costs spike with no traffic increase | Auto-approved `sampling/createMessage` with `includeContext: "allServers"` | Audit sampling volume per server | Human-in-the-loop approval; default `includeContext` to `none` |
| 15 | `406 Not Acceptable` on every POST | Missing `text/event-stream` in `Accept` | `curl -v` and read the request headers | Send `Accept: application/json, text/event-stream` |

### 11.7 Draining a replica correctly

```
$ kubectl -n mcp get pods -l app.kubernetes.io/name=mcp-postgres \
    -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready'
NAME                            NODE            READY
mcp-postgres-7d8f4c9b6-4jx2k    ip-10-4-2-91    true
mcp-postgres-7d8f4c9b6-p9wqt    ip-10-4-3-17    true
mcp-postgres-7d8f4c9b6-zt6mn    ip-10-4-1-45    true

$ kubectl -n mcp exec mcp-postgres-7d8f4c9b6-4jx2k -- \
    wget -qO- http://127.0.0.1:9090/metrics | grep '^mcp_active_sessions'
mcp_active_sessions 87

$ kubectl -n mcp rollout restart deployment/mcp-postgres
deployment.apps/mcp-postgres restarted

$ kubectl -n mcp rollout status deployment/mcp-postgres --timeout=10m
Waiting for deployment "mcp-postgres" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "mcp-postgres" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "mcp-postgres" successfully rolled out
```

With `maxUnavailable: 0`, a 150 s grace period, and a preStop drain that fails readiness first, the ingress stops issuing the affinity cookie for a terminating pod while its existing streams finish. Without the drain hook, all 87 sessions are severed the instant the pod enters `Terminating`.

---

## 12. Exam-focused summary

- **Two error channels.** `error` = the client runtime's problem. `result` + `isError: true` = the model's problem. Unknown tool and schema violations are `-32602`; upstream failures inside a tool that ran are `isError: true`.
- **Notifications never carry `id` and never get a response.** `notifications/cancelled` and `notifications/progress` are notifications, not requests.
- **Correlation is by `id`, never by order.** Ids must be unique per session and never `null` (except in an unrecoverable parse error).
- **Batching was added in `2025-03-26` and removed in `2025-06-18`.**
- **Progress requires a `progressToken` supplied by the requester** in `params._meta`. `progress` must increase; `total` is optional.
- **Timeouts:** progress MAY reset the clock; a maximum SHOULD always be enforced anyway.
- **Cancellation is best-effort and racy.** Never cancel `initialize`. Ignore unknown `requestId`. Tolerate a response that arrives anyway.
- **Cursors are opaque.** No `nextCursor` = end of list. Invalid cursor = `-32602`. Restart pagination on `*/list_changed`.
- **`resources/updated` names one URI** and does not invalidate the list; `resources/list_changed` does.
- **Server→client requests** (`sampling/createMessage`, `elicitation/create`, `roots/list`) require the client capability and, over HTTP, an open SSE stream.
- **Elicitation schemas are flat with primitive properties**, and the three actions are `accept` / `decline` / `cancel`. Never request secrets.
- **Streamable HTTP:** `202` for notification-only POSTs, `404` for expired sessions (→ re-initialize), `406` for a bad `Accept`, `400` for a bad `MCP-Protocol-Version`. Validate `Origin`. Resume with `Last-Event-ID`.
- **stdio:** newline-delimited, no embedded newlines, `stdout` is reserved for MCP frames, logs go to `stderr`.
- **Platform reality:** sticky sessions, buffering off, idle timeouts above the ping interval, graceful drain. Those four settings are the difference between a demo and a service.

---

## Referencias

**Official specification and protocol**

- Model Context Protocol — Specification index (revision list and current revision): https://modelcontextprotocol.io/specification/
- Base protocol, message shapes and error handling (`2025-06-18`): https://modelcontextprotocol.io/specification/2025-06-18/basic
- Lifecycle and capability negotiation: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Transports (stdio, Streamable HTTP, sessions, resumability): https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Utilities — Progress: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
- Utilities — Cancellation: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation
- Utilities — Ping: https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/ping
- Server features — Tools (`content`, `structuredContent`, `isError`, `outputSchema`): https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Server features — Resources (subscriptions, `resources/updated`): https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- Server features — Prompts: https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- Server utilities — Pagination: https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/pagination
- Server utilities — Logging (`notifications/message`): https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/logging
- Client features — Sampling: https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- Client features — Elicitation: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- Client features — Roots: https://modelcontextprotocol.io/specification/2025-06-18/client/roots
- Protocol versioning policy: https://modelcontextprotocol.io/specification/versioning
- Canonical schema (`schema.ts`, the normative type definitions): https://github.com/modelcontextprotocol/modelcontextprotocol/tree/main/schema
- Specification repository (changelog and revision history): https://github.com/modelcontextprotocol/modelcontextprotocol

**Underlying standards**

- JSON-RPC 2.0 Specification (message shapes, reserved error codes): https://www.jsonrpc.org/specification
- HTML Living Standard — Server-Sent Events (`event`, `id`, `Last-Event-ID`): https://html.spec.whatwg.org/multipage/server-sent-events.html
- RFC 5424 — The Syslog Protocol (severity levels used by `logging/setLevel`): https://datatracker.ietf.org/doc/html/rfc5424
- JSON Schema specification (used by `inputSchema`, `outputSchema`, `requestedSchema`): https://json-schema.org/specification

**Tooling and SDKs**

- MCP Inspector (GUI and `--cli` mode): https://github.com/modelcontextprotocol/inspector
- TypeScript SDK (`ErrorCode` enum, transport implementations): https://github.com/modelcontextprotocol/typescript-sdk
- Python SDK: https://github.com/modelcontextprotocol/python-sdk
- Go SDK: https://github.com/modelcontextprotocol/go-sdk

**Infrastructure references used in this topic**

- Kubernetes — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — Pod lifecycle and termination (`preStop`, grace period): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes — Horizontal Pod Autoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Ingress NGINX — Annotations reference (affinity, buffering, timeouts): https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- Prometheus Operator — API reference (`ServiceMonitor`, `PrometheusRule`): https://prometheus-operator.dev/docs/api-reference/api/
- Prometheus — Alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

**Certification**

- Linux Foundation — Model Context Protocol Associate (MCPA): https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/