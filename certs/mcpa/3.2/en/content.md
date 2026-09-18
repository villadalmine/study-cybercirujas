# MCPA 3.2 — Error Handling

**Certification:** Model Context Protocol Associate (MCPA) · Exam version 2026-07-28
**Domain weight:** 6.5
**Profile:** Principal Platform Architect / Senior SRE

> **Protocol revision note.** Everything below is anchored to the `2025-06-18` protocol revision, which is the revision whose error semantics the exam objectives describe in detail. MCP revisions are date-stamped strings negotiated at `initialize`, and error-relevant behaviour *has* changed between revisions (JSON-RPC batching was added in `2025-03-26` and removed in `2025-06-18`; the `MCP-Protocol-Version` HTTP header became mandatory in `2025-06-18`). Whenever this material states a numeric code or an HTTP status, verify it against the revision your deployment actually negotiates — that verification habit is itself an exam objective.

---

## 1. Motivation: the production problem error handling solves

### 1.1 MCP has two consumers of every failure, and they need different things

A conventional RPC system has one consumer of an error: the calling program. MCP has two, and they sit on opposite sides of a trust and competence boundary:

| Consumer | What it is | What it needs from a failure | What kills it |
|---|---|---|---|
| **The host/client runtime** | Deterministic code — connection manager, session store, retry logic | A stable machine code, a clear retryability signal, no natural language | Ambiguity; a failure it cannot classify without parsing prose |
| **The model** | A non-deterministic language model holding the tool call in its context window | Prose it can reason over: what went wrong, what to change, whether to try again | Stack traces (token burn), opaque codes, silence |

The architectural consequence is the single most important design decision in MCP error handling, and the one the exam tests hardest:

> **A protocol error terminates the request. A tool error is a successful request whose result says "this failed."**

If a database tool hits a missing table and the server returns JSON-RPC `-32603 Internal error`, the model never sees it. The client runtime catches it, and from the model's perspective the tool call simply evaporated — so the model retries verbatim, forever, burning context and quota. If instead the server returns a **successful** `CallToolResult` with `isError: true` and the text `relation "users" does not exist; the analytics replica exposes schema "analytics"`, the model rewrites the query to `analytics.users` and succeeds on the second call. Same failure, opposite outcomes, and the difference is entirely which error plane you chose.

### 1.2 The failure domains you are actually operating

A remote MCP server in a Kubernetes cluster fails on at least six planes simultaneously. An on-call engineer who cannot name the plane cannot route the page:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │ 6. SEMANTIC   the tool succeeded and returned a wrong answer      │  ← no protocol signal
  ├──────────────────────────────────────────────────────────────────┤
  │ 5. APPLICATION  tool executed, business logic failed              │  ← CallToolResult.isError
  ├──────────────────────────────────────────────────────────────────┤
  │ 4. AUTHORIZATION  token absent / wrong audience / scope too low   │  ← HTTP 401 / 403
  ├──────────────────────────────────────────────────────────────────┤
  │ 3. PROTOCOL   method unknown, params invalid, capability absent   │  ← JSON-RPC error object
  ├──────────────────────────────────────────────────────────────────┤
  │ 2. SESSION    Mcp-Session-Id unknown or expired                   │  ← HTTP 404 / 400
  ├──────────────────────────────────────────────────────────────────┤
  │ 1. TRANSPORT  process died, TCP reset, stream closed, parse error │  ← -32700 / HTTP 5xx / EOF
  └──────────────────────────────────────────────────────────────────┘
```

Plane 6 has no protocol representation at all — it is an evaluation problem, not an error-handling one. Do not let anyone tell you MCP error handling addresses it.

### 1.3 Three production incidents that are all "error handling"

These are the shapes you will be asked to recognise:

1. **stdout poisoning.** A Python MCP server adds a dependency that prints a deprecation banner at import time. Every client connection now dies with a parse error before `initialize` completes. The server logs look perfect, because the corruption *is* on the channel the logs were never supposed to use.
2. **The session-affinity storm.** A stateful Streamable HTTP server is scaled from 1 to 3 replicas behind a round-robin Service. Two out of three requests now hit a replica that has never heard of the client's `Mcp-Session-Id`, return HTTP `404`, and the client — correctly following the spec — re-initializes. Session creation rate goes to thousands per minute; nothing is "down."
3. **The retry amplifier.** A gateway is configured with a generic `retryOn: 5xx, attempts: 3` policy. An MCP `tools/call` that writes a row times out at 30 s at the gateway but completes at 45 s on the server. The gateway retries twice. Three rows are written. The tool was never idempotent and nobody claimed it was.

---

## 2. The three error planes, compared

### 2.1 Structural comparison

| Property | Transport error | Protocol error (JSON-RPC `error`) | Tool error (`isError: true`) |
|---|---|---|---|
| Carried in | TCP/HTTP/process state | JSON-RPC response `error` member | JSON-RPC response `result` member |
| JSON-RPC classification | none — there may be no message | failure | **success** |
| Visible to the model | No | No (host may paraphrase) | **Yes, verbatim** |
| Visible to the host runtime | Yes | Yes | Only if it inspects `isError` |
| Correlated by `id` | Sometimes impossible | Always | Always |
| Typical cause | crash, reset, TLS, stdout corruption | contract violation, capability mismatch | business/runtime failure inside a valid call |
| Correct client action | reconnect / re-initialize | fix the caller; do not retry blindly | hand back to the model, bounded |
| Correct SLO treatment | availability | **integration-quality**, not availability | product metric, not availability |
| Retry-safe by default | sometimes (if not delivered) | no | no (model decides) |

The SLO row is where most teams get it wrong. A spike in `-32602 Invalid params` is not a server availability event — the server behaved exactly as specified. It is an *integration* event: some client shipped a bad build. Putting it in the same error budget as HTTP 503 makes both signals useless.

### 2.2 The error object, and the code registry

Every protocol failure is a JSON-RPC 2.0 error object: a mandatory integer `code`, a mandatory single-sentence `message`, and an optional `data` member of any shape.

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "error": {
    "code": -32602,
    "message": "Invalid params for tool run_query",
    "data": {
      "tool": "run_query",
      "violations": [
        {
          "path": "/timeoutSeconds",
          "constraint": "maximum",
          "limit": 60,
          "received": 600
        }
      ],
      "protocolVersion": "2025-06-18"
    }
  }
}
```

Note what is *not* there: no stack trace, no SQL, no hostname, no token. `data` is attacker-reachable output; treat it as a public API surface.

| Code | Name | Origin | Meaning in MCP | Retryable |
|---|---|---|---|---|
| `-32700` | Parse error | JSON-RPC | Bytes on the wire were not valid JSON — almost always framing or stdout corruption | No |
| `-32600` | Invalid Request | JSON-RPC | Valid JSON, invalid JSON-RPC envelope. Also what a `2025-06-18` server returns for a **batch array** | No |
| `-32601` | Method not found | JSON-RPC | Method unknown, or belongs to a capability that was never negotiated | No |
| `-32602` | Invalid params | JSON-RPC | Schema violation, **unknown tool name**, invalid prompt name, missing required prompt argument, bad pagination cursor | Only by the model, with corrected args |
| `-32603` | Internal error | JSON-RPC | Unexpected server-side fault in the dispatch layer | At most once, idempotent only |
| `-32002` | Resource not found | MCP | `resources/read` on a URI the server does not serve; `data` carries `uri` | No — re-`resources/list` first |
| `-32001` | Request timeout | SDK convention | Client-side: the local deadline fired. Not sent by a server | Conditional — cancel first |
| `-32000` | Connection closed | SDK convention | Client-side: the peer vanished mid-request | Yes, after reconnect |
| `-32000`…`-32099` | Server-defined | JSON-RPC reserve | Your domain codes live here | Depends |

**Exam traps in this table:** an *unknown tool name* is `-32602`, not `-32601` — the method `tools/call` exists, its parameters were wrong. And `-32000`/`-32001` are SDK-level conventions from the reference implementations, not codes a spec-compliant peer is required to emit; never write a client that branches only on those two.

### 2.3 The decision: protocol error or `isError`?

```
                      tools/call arrives
                              │
             ┌────────────────┴────────────────┐
             │  Can the server even dispatch?  │
             └────────────────┬────────────────┘
                   no │                 │ yes
       ┌──────────────┘                 └──────────────┐
       ▼                                               ▼
 PROTOCOL ERROR                                 execute the tool
 • tool name unknown ............ -32602               │
 • args fail the inputSchema .... -32602    ┌──────────┴──────────┐
 • tools capability not          │          │ Did it produce a    │
   negotiated ................... -32601    │ result the model    │
 • malformed JSON ............... -32700    │ can act on?         │
 • dispatcher blew up ........... -32603    └──────────┬──────────┘
                                             yes │           │ no
                                   ┌─────────────┘           └───────────┐
                                   ▼                                     ▼
                          result, isError: false            TOOL ERROR — result,
                                                            isError: true, with prose:
                                                            • what failed
                                                            • why
                                                            • what to change
```

The rule in one line: **if the model could plausibly fix it by calling differently, it must reach the model — therefore `isError: true`.**

A conforming tool error:

```json
{
  "jsonrpc": "2.0",
  "id": 43,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "QUERY_FAILED (retryable=false): relation \"users\" does not exist.\nThis connection is the analytics replica; user tables live in the schema \"analytics\".\nRetry with a schema-qualified name, for example: SELECT * FROM analytics.dim_users LIMIT 10"
      }
    ],
    "isError": true
  }
}
```

Three properties make it production-grade: a **stable machine-readable prefix** (`QUERY_FAILED`) that your log pipeline can aggregate on, an explicit **retryability** hint so the model does not loop, and a **concrete corrected call**. Compare against the anti-pattern that ships in most first drafts:

| Anti-pattern | Why it costs you | Fix |
|---|---|---|
| `text: "<traceback, 40 lines>"` | 600+ tokens of context per failure, leaks file paths and library versions | Log the traceback to stderr/OTel; return one sentence plus remediation |
| `text: "Error: 500"` | The model has nothing to act on and will retry identically | Name the failure class and the corrective action |
| `isError: true` for "no rows matched" | Not a failure; the model treats an empty result set as a bug | `isError: false`, content `"0 rows"` |
| Returning `-32603` for a tool runtime fault | Model blind; host cannot distinguish it from a server bug | `isError: true` |
| Echoing untrusted upstream text raw | Third-party content becomes an **injection vector** into the model's context | Truncate, delimit, and label as untrusted data |

That last row is a security control, not a style preference. Anything you place in an `isError` payload is read by the model as instructions-adjacent input.

---

## 3. Transport-specific failure semantics

### 3.1 stdio

stdio is deceptively simple and therefore the source of the most production incidents.

| Stream | Ownership | Rule |
|---|---|---|
| `stdin` | client → server | Newline-delimited JSON-RPC messages. Messages **MUST NOT** contain embedded newlines |
| `stdout` | server → client | **Only** valid JSON-RPC messages. Nothing else, ever, including at import time |
| `stderr` | server → client (out of band) | Free-form logging. The client MAY capture, forward, or discard it |

Failure modes and their signatures:

| Failure | Client-visible symptom | Root cause |
|---|---|---|
| stdout poisoning | `-32700` or `Unexpected token 'L'` before handshake completes | `print()`, a library banner, a progress bar, `pdb`, buffered `warnings` |
| Non-zero exit at spawn | Connection closed before `initialize` result | Missing env var, import failure, wrong interpreter |
| Server hangs, no output | Client timeout, then `-32001` | Server blocked on its own stdin read, or waiting on a TTY prompt |
| Output buffering | Sporadic multi-second latency; responses arrive in bursts | stdout is block-buffered when not a TTY — you must flush or set unbuffered mode |
| Zombie on shutdown | Orphan processes accumulate on the host | Client must close stdin, then `SIGTERM`, then `SIGKILL` |

The client-side shutdown ladder is normative and worth memorising: **close stdin → wait → `SIGTERM` → wait → `SIGKILL`.**

### 3.2 Streamable HTTP

Streamable HTTP (introduced in `2025-03-26`, superseding the older HTTP+SSE transport) puts a second, independent error vocabulary underneath JSON-RPC: HTTP status codes. Both can fire for the same logical call, and they mean different things.

| Status | When the server returns it | Body | Correct client reaction |
|---|---|---|---|
| `200` | Request(s) answered — `application/json` or `text/event-stream` | JSON-RPC response(s) | Parse; a JSON-RPC `error` inside a `200` is still a protocol error |
| `202` | POST contained **only** notifications/responses | empty | Nothing. Do not wait for a body |
| `400` | Missing/invalid `Mcp-Session-Id`, unsupported `MCP-Protocol-Version`, malformed body | may carry a JSON-RPC error | Fix the request. Do not retry unchanged |
| `401` | No/expired credential; `WWW-Authenticate` points to protected-resource metadata | JSON | Discover the AS, obtain a token, retry **once** |
| `403` | Authenticated but scope/audience insufficient | JSON | Do **not** retry. Escalate to a human/consent flow |
| `404` | Session ID unknown or expired | — | **Start a new session by re-sending `initialize`.** Do not replay non-idempotent work |
| `405` | GET when the server offers no server-initiated SSE stream, or DELETE when client termination is not allowed | — | Degrade to POST-only operation. Not an error condition |
| `406` | `Accept` did not include both `application/json` and `text/event-stream` | — | Client bug; fix headers |
| `429` | Rate limited | may carry `Retry-After` | Honour `Retry-After`; back off |
| `5xx` | Server/infra fault | varies | Retry only if you can prove the request was not delivered |

Header contract for the `2025-06-18` revision:

| Header | Direction | Requirement | Failure if omitted |
|---|---|---|---|
| `Accept` | client → server | POST must list `application/json, text/event-stream` | `406` |
| `Content-Type` | client → server | `application/json` on POST | `400` |
| `MCP-Protocol-Version` | client → server | Required on every request **after** `initialize` | Server SHOULD assume `2025-03-26`; `400` if the value is unsupported |
| `Mcp-Session-Id` | server → client on init, then client → server | Required once assigned | `400` if missing, `404` if unknown |
| `Origin` | client → server | Server MUST validate (DNS-rebinding defence) | `403` |
| `Last-Event-ID` | client → server on reconnect | Enables stream resumption | Server replays from the last delivered event, or restarts the stream |

**Resumption is the error-handling feature most often missed.** When the server emits SSE events with an `id` field, a client that loses the stream reconnects with `Last-Event-ID: <last id>` and the server resumes from that point — no duplicate tool executions, no lost final response. Without event IDs, every TCP blip on a long-running `tools/call` is an ambiguous failure.

### 3.3 Transport trade-offs from an error-handling standpoint

| Dimension | stdio | Streamable HTTP |
|---|---|---|
| Failure blast radius | One user, one process | Every session on the replica |
| Error vocabulary | Process exit code + `-32700` | HTTP status + JSON-RPC error + SSE stream state |
| Observability | stderr, if the host captures it | Full L7: access logs, traces, metrics, status codes |
| Resumable after a network fault | N/A (no network) | Yes, with SSE event IDs + `Last-Event-ID` |
| Authorization errors | Out of scope (inherits process credentials) | First-class: `401`/`403` + OAuth 2.1 discovery |
| Horizontal scaling hazard | None | **Session affinity** — the dominant production failure |
| Hardest bug to find | stdout poisoning | Ambiguous timeout: delivered-or-not on a non-idempotent call |
| Correct retry owner | The host (respawn) | The client, never the gateway (for `tools/call`) |

---

## 4. Lifecycle, capability and negotiation errors

Errors during `initialize` are structurally different: there is no negotiated contract yet, so almost nothing is recoverable in place.

**Version negotiation.** The client sends the latest revision it supports. If the server supports it, it echoes it. If not, the server responds with a revision it *does* support. The client then either accepts that revision or **disconnects** — it must not proceed on a version it cannot speak. An unsupported version over HTTP surfaces as `400`.

**Capability gating.** Capabilities declared in the `initialize` exchange define the legal method set for the whole session. Calling `resources/list` on a server that never declared `resources` is `-32601 Method not found` — and it is a *client* bug, because the client had the capability object in hand.

| Declared by | Capability | Methods it unlocks | Error if used without it |
|---|---|---|---|
| Server | `tools` | `tools/list`, `tools/call` | `-32601` |
| Server | `resources` | `resources/list`, `resources/read`, `resources/templates/list` | `-32601` |
| Server | `resources.subscribe` | `resources/subscribe`, `resources/unsubscribe` | `-32601` |
| Server | `prompts` | `prompts/list`, `prompts/get` | `-32601` |
| Server | `logging` | `logging/setLevel`; server may emit `notifications/message` | `-32601` |
| Server | `completions` | `completion/complete` | `-32601` |
| Client | `sampling` | server → client `sampling/createMessage` | `-32601` from the client |
| Client | `roots` | server → client `roots/list` | `-32601` from the client |
| Client | `elicitation` | server → client `elicitation/create` | `-32601` from the client |

**Ordering rules that produce real bugs.** After receiving the `initialize` result the client MUST send the `notifications/initialized` notification; before that, the only legal traffic is `ping` and logging. A server that starts serving normal requests before `initialized` arrives has a race with clients that are still setting up handlers. The only client request permitted before the `initialize` response is `ping`.

**Elicitation is not an error channel.** `elicitation/create` has three terminal actions — `accept`, `decline`, `cancel`. `decline` (the user said no) and `cancel` (the user dismissed) are *successful* responses, not JSON-RPC errors. A server that treats a decline as `-32603` will spam the user with retries. This distinction is directly analogous to `isError` versus a protocol error, and it is examinable.

---

## 5. Timeouts, cancellation and progress

These three utilities are one mechanism. Getting them wrong is how you get duplicated writes.

### 5.1 The normative rules

- Implementations **SHOULD** set a timeout on every request they send, so a peer never hangs forever.
- On timeout the issuer **SHOULD** send `notifications/cancelled` and stop waiting.
- Receiving `notifications/progress` **MAY** reset the timeout clock — that is how you support a 20-minute job without a 20-minute blind deadline.
- Implementations **SHOULD ALWAYS** enforce a maximum total timeout regardless of progress, or a misbehaving server pins a client slot forever.
- `ping` exists precisely so a peer can distinguish "slow" from "dead" without a request in flight.

### 5.2 Cancellation semantics and its race

A request that opted into progress carries a token in `params._meta`:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "run_query",
    "arguments": {
      "sql": "SELECT count(*) FROM analytics.fct_events"
    },
    "_meta": {
      "progressToken": "q-7"
    }
  }
}
```

Cancelling it:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/cancelled",
  "params": {
    "requestId": 7,
    "reason": "client deadline exceeded after 30s"
  }
}
```

| Rule | Consequence if you break it |
|---|---|
| Only the side that **issued** the request may cancel it | The peer ignores the notification; your request keeps running |
| The `initialize` request **MUST NOT** be cancelled by clients | Undefined session state |
| The receiver **SHOULD** stop work and **SHOULD NOT** send a response for a cancelled request | A late response arrives for an `id` the issuer has already freed |
| The issuer **MUST** be prepared for a response that crossed the cancellation in flight, and ignore it | Response routed to the wrong request, or a crash on unknown `id` |
| Unknown or already-completed `requestId` → **ignore silently** | A cancellation storm answered with errors |
| Malformed cancellation → **ignore** | Error loops between peers |

**Cancellation is a request to stop, not a guarantee that nothing happened.** This is the crux: if the tool writes, cancelling it does not roll it back. Any tool whose cancellation is observable externally needs an idempotency key supplied by the caller, or a compensating action.

### 5.3 Timeout layers must be ordered, not merely configured

The number one cause of duplicated tool executions is a client deadline that is shorter than the gateway's, which is shorter than the server's. Enforce a strict inequality outward-in:

```
  tool internal deadline   <   server request deadline
        (25s)                        (30s)
                                       <   gateway backendRequest timeout
                                                    (120s)
                                                      <   client max total timeout
                                                                  (180s)
```

If the gateway times out before the server does, the gateway will report a failure for a call that is still running — and if it also retries, the call runs twice.

---

## 6. Authorization errors

For HTTP transports, MCP authorization builds on OAuth 2.1 with the MCP server acting as an OAuth **resource server**. The error surface is almost entirely defined by three RFCs, and the discovery chain is driven *by the 401 itself*.

| Status | `WWW-Authenticate` | Meaning | Client action |
|---|---|---|---|
| `401` | `Bearer resource_metadata="https://…/.well-known/oauth-protected-resource"` | No token, expired token, or wrong audience | Fetch protected-resource metadata → discover the authorization server → obtain a token for **this** resource → retry once |
| `401` | `Bearer error="invalid_token", error_description="…"` | Token rejected | Refresh once; on a second `401`, fail hard |
| `403` | `Bearer error="insufficient_scope", scope="mcp:tools:execute"` | Authenticated, not authorised | **Never retry.** Request the named scope via a new consent flow |
| `400` | — | Malformed Authorization header or request | Client bug |

Two failure modes dominate:

1. **Audience confusion.** The client presents a token minted for a different resource. The server is right to reject it with `401`, and the naive client loops: refresh → same token → `401` → refresh. The fix is RFC 8707 resource indicators — the client must request the token *for* the MCP server's canonical resource URI, and the server must validate `aud`. A client that retries a `401` more than once without a *different* token is a defect.
2. **Retrying a `403`.** Insufficient scope is not transient. Backoff will not create permission. Surface it to the user.

---

## 7. Retry policy: the SRE core

### 7.1 Retryability matrix

| Condition | Plane | Retry? | Strategy | Owner |
|---|---|---|---|---|
| TCP connection refused / DNS failure | transport | Yes | Exponential backoff + full jitter, ≤3 attempts | client |
| TLS handshake failure | transport | No | Config/cert fault — page | operator |
| HTTP `429` | transport | Yes | Honour `Retry-After` exactly; never faster | client |
| HTTP `503` / `502` | transport | Only if not delivered | Envoy `reset-before-request`, or idempotent calls only | client/gateway |
| HTTP `504` at the gateway | transport | **No** | Ambiguous — the call may have committed | never auto-retry |
| HTTP `404` with a session ID | session | Yes, as **re-initialize** | New session, then replay only idempotent requests | client |
| HTTP `400` missing session | session | No | Client bug | client |
| HTTP `401` | authz | Once, with a *new* token | Full discovery + token exchange | client |
| HTTP `403` | authz | **No** | Consent / scope escalation | human |
| `-32700` | protocol | No | Framing bug or stdout poisoning | developer |
| `-32600` | protocol | No | Envelope/batching/version mismatch | developer |
| `-32601` | protocol | No | Capability not negotiated | developer |
| `-32602` | protocol | No by the client; **yes by the model** with corrected arguments | Return to the model | model |
| `-32603` | protocol | At most once, idempotent only | Single retry with jitter | client |
| `-32002` | protocol | No | `resources/list` again, then read | client |
| SDK `-32001` request timeout | client | Conditional | Send `notifications/cancelled` **first**, then retry only if idempotent | client |
| SDK `-32000` connection closed | transport | Yes | Reconnect, re-initialize, replay idempotent only | client |
| `isError: true` | application | Model decides, **bounded** | Per-tool consecutive-failure cap | host |

### 7.2 Where retries must *not* live

| Layer | Retry `tools/call`? | Why |
|---|---|---|
| Service mesh / Envoy / Gateway | **No** — except `reset-before-request` | The mesh cannot know whether a tool is idempotent; MCP carries no `Idempotency-Key` convention |
| Ingress / L7 LB | No | Same, plus it will happily retry a POST that opened an SSE stream |
| MCP client library | Yes, for transport and session faults | Only it knows the session state and can re-initialize |
| Host application | Yes, for the model loop | Only it holds the tool-call budget |
| Tool implementation | Yes, for its own downstreams | Inside the server's deadline, and only there |

`reset-before-request` (Envoy) is the one gateway retry condition that is always safe: it fires only when the stream was reset *before the request was sent upstream*, which means the request provably did not execute.

### 7.3 Breaking the model's error loop

A model that receives `isError: true` will usually retry. Left unbounded, that is an outage of your token budget. Host-side controls, in increasing severity:

1. **Per-tool consecutive-failure cap** (typically 3). On the cap, stop returning the tool result and inject a terminal instruction instead.
2. **Identical-error deduplication.** If the error text is byte-identical to the previous one, the model is not learning; escalate immediately.
3. **Global tool-call budget per turn.** A hard ceiling independent of which tool is failing.
4. **Circuit breaker per (server, tool).** After N failures in a window, remove the tool from the advertised list for that session and tell the model it is unavailable — that is far cheaper than letting it keep trying.

---

## 8. Reference implementation: error-correct MCP server

### 8.1 Python — the error boundary, explicitly

```python
"""db-tools MCP server: an explicit three-plane error boundary."""

from __future__ import annotations

import asyncio
import logging
import sys
from dataclasses import dataclass

import asyncpg
from mcp.server.fastmcp import Context, FastMCP
from mcp.shared.exceptions import McpError
from mcp.types import INVALID_PARAMS, ErrorData

# ---------------------------------------------------------------------------
# stdio contract: stdout belongs to the protocol. Every byte of logging goes to
# stderr. Configure this BEFORE importing anything that might print a banner.
# ---------------------------------------------------------------------------
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger("mcp.db_tools")

mcp = FastMCP("db-tools")

TOOL_DEADLINE_SECONDS = 25  # strictly less than the server request deadline (30s)
MAX_ROWS = 500


@dataclass(frozen=True)
class ToolFailure:
    """A failure the *model* must see and can act on."""

    code: str
    detail: str
    remediation: str
    retryable: bool

    def render(self) -> str:
        return (
            f"{self.code} (retryable={str(self.retryable).lower()}): {self.detail}\n"
            f"{self.remediation}"
        )


def _classify(exc: BaseException) -> ToolFailure:
    """Map a driver exception onto a model-actionable failure. No tracebacks escape."""
    if isinstance(exc, asyncio.TimeoutError):
        return ToolFailure(
            code="QUERY_TIMEOUT",
            detail=f"the query exceeded the {TOOL_DEADLINE_SECONDS}s tool deadline",
            remediation=(
                "Narrow the query: add a WHERE clause on event_date, or aggregate "
                "server-side instead of selecting raw rows."
            ),
            retryable=False,
        )
    if isinstance(exc, asyncpg.UndefinedTableError):
        return ToolFailure(
            code="UNKNOWN_RELATION",
            detail=str(exc).splitlines()[0],
            remediation=(
                'This connection is the analytics replica; user-facing tables live in '
                'the schema "analytics". Retry with a schema-qualified name, e.g. '
                "SELECT * FROM analytics.dim_users LIMIT 10"
            ),
            retryable=False,
        )
    if isinstance(exc, asyncpg.InsufficientPrivilegeError):
        return ToolFailure(
            code="PERMISSION_DENIED",
            detail="the read-only role may not access that relation",
            remediation="Query a table under the analytics schema, or ask an operator for access.",
            retryable=False,
        )
    if isinstance(exc, (asyncpg.TooManyConnectionsError, ConnectionError)):
        return ToolFailure(
            code="BACKEND_UNAVAILABLE",
            detail="the analytics replica refused the connection",
            remediation="Wait a few seconds and issue the same query again.",
            retryable=True,
        )
    # Unknown: log the full detail to stderr/OTel, return a bounded summary.
    log.exception("unclassified tool failure")
    return ToolFailure(
        code="INTERNAL_TOOL_ERROR",
        detail="the tool failed for an unexpected reason; operators have been notified",
        remediation="Do not retry this call. Report the failure to the user.",
        retryable=False,
    )


@mcp.tool()
async def run_query(sql: str, row_limit: int = 100, ctx: Context | None = None) -> str:
    """Execute a single read-only SELECT against the analytics replica."""
    # --- Plane 3: contract violations the model must not be allowed to "fix" by
    # retrying with the same intent. These are genuine protocol errors.
    if row_limit < 1 or row_limit > MAX_ROWS:
        raise McpError(
            ErrorData(
                code=INVALID_PARAMS,
                message=f"row_limit must be between 1 and {MAX_ROWS}",
                data={"received": row_limit, "maximum": MAX_ROWS},
            )
        )

    # --- Plane 5: an executable call whose outcome the model must see.
    statement = sql.strip().rstrip(";")
    if not statement.lower().startswith("select"):
        failure = ToolFailure(
            code="READ_ONLY_VIOLATION",
            detail="only SELECT statements are accepted by this tool",
            remediation="Rewrite the request as a SELECT, or use the write-path tool if you hold the scope.",
            retryable=False,
        )
        raise RuntimeError(failure.render())

    try:
        async with asyncio.timeout(TOOL_DEADLINE_SECONDS):
            if ctx is not None:
                await ctx.report_progress(progress=0.1, total=1.0, message="acquiring connection")
            rows = await _execute(statement, row_limit, ctx)
    except BaseException as exc:  # noqa: BLE001 - deliberate boundary
        failure = _classify(exc)
        log.warning("tool_error code=%s retryable=%s", failure.code, failure.retryable)
        # The reference SDK turns a raised exception in a tool handler into a
        # CallToolResult with isError: true — which is exactly the plane we want.
        raise RuntimeError(failure.render()) from None

    if not rows:
        # NOT an error. An empty result set is a successful answer.
        return "0 rows matched."
    return _format(rows)


async def _execute(statement: str, row_limit: int, ctx: Context | None) -> list[asyncpg.Record]:
    pool = mcp_state_pool()
    async with pool.acquire() as conn:
        if ctx is not None:
            await ctx.report_progress(progress=0.5, total=1.0, message="executing")
        return await conn.fetch(f"SELECT * FROM ({statement}) AS q LIMIT {int(row_limit)}")
```

Two decisions in that file carry the whole lesson. `row_limit` out of range is a **protocol error** — the *caller* violated the declared schema, and returning it to the model would invite an argument-fuzzing loop. A missing relation is a **tool error** — the model wrote a plausible query against a schema it had guessed wrong, and one sentence of remediation lets it self-correct.

### 8.2 TypeScript — shaping errors the model can consume

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { McpError, ErrorCode } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

const server = new McpServer({ name: "db-tools", version: "1.8.3" });

const MAX_ROWS = 500;

function toolFailure(code: string, detail: string, remediation: string, retryable: boolean) {
  return {
    isError: true as const,
    content: [
      {
        type: "text" as const,
        text: `${code} (retryable=${retryable}): ${detail}\n${remediation}`,
      },
    ],
    structuredContent: { ok: false, errorCode: code, retryable },
  };
}

server.registerTool(
  "run_query",
  {
    title: "Run a read-only SQL query",
    description: "Executes a single SELECT against the analytics replica.",
    inputSchema: {
      sql: z.string().min(1).describe("A single SELECT statement, no trailing semicolon"),
      rowLimit: z.number().int().min(1).max(MAX_ROWS).default(100),
    },
    outputSchema: {
      ok: z.boolean(),
      rowCount: z.number().int().optional(),
      errorCode: z.string().optional(),
      retryable: z.boolean().optional(),
    },
  },
  async ({ sql, rowLimit }, extra) => {
    // Plane 3 — a contract violation the dispatcher should never have passed on.
    if (!Number.isInteger(rowLimit)) {
      throw new McpError(ErrorCode.InvalidParams, "rowLimit must be an integer", {
        received: rowLimit,
      });
    }

    // Honour cancellation: extra.signal is aborted when the client sends
    // notifications/cancelled, or when the client's transport dies.
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    extra.signal.addEventListener("abort", onAbort, { once: true });
    const deadline = setTimeout(() => controller.abort(), 25_000);

    try {
      const rows = await executeQuery(sql, rowLimit, controller.signal);
      return {
        content: [{ type: "text", text: renderTable(rows) }],
        structuredContent: { ok: true, rowCount: rows.length },
      };
    } catch (err) {
      if (controller.signal.aborted && !extra.signal.aborted) {
        return toolFailure(
          "QUERY_TIMEOUT",
          "the query exceeded the 25s tool deadline",
          "Narrow the query with a WHERE clause on event_date, or aggregate server-side.",
          false,
        );
      }
      if (extra.signal.aborted) {
        // The client cancelled. Per spec, do not send a response for a cancelled
        // request — let the SDK drop it rather than fabricating a result.
        throw err;
      }
      return classify(err);
    } finally {
      clearTimeout(deadline);
      extra.signal.removeEventListener("abort", onAbort);
    }
  },
);
```

The `extra.signal` handling is the part reviewers miss. When the client cancels, the correct behaviour is **no response at all** — synthesising a `isError: true` result for a cancelled request puts a response on the wire for an `id` the client has already released.

---

## 9. Production infrastructure

### 9.1 Namespace and configuration

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp
  labels:
    pod-security.kubernetes.io/enforce: "restricted"
    pod-security.kubernetes.io/enforce-version: "latest"
    pod-security.kubernetes.io/audit: "restricted"
    pod-security.kubernetes.io/warn: "restricted"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mcp-server-config
  namespace: mcp
data:
  # Quoted: an unquoted 2025-06-18 is a YAML timestamp, not a string, and a
  # ConfigMap data value must be a string. This is a real deployment failure.
  MCP_PROTOCOL_VERSION: "2025-06-18"
  MCP_TRANSPORT: "streamable-http"
  # Deadline ladder. Each layer must be strictly shorter than the one outside it.
  MCP_TOOL_DEADLINE_SECONDS: "25"
  MCP_REQUEST_DEADLINE_SECONDS: "30"
  MCP_MAX_TOTAL_DEADLINE_SECONDS: "180"
  MCP_PROGRESS_RESETS_DEADLINE: "true"
  MCP_SESSION_TTL_SECONDS: "900"
  MCP_SESSION_STORE_KIND: "redis"
  # A wildcard value MUST be quoted: bare *.example.com is a YAML alias node.
  MCP_ALLOWED_ORIGINS: "https://host.example.com,https://*.internal.example.com"
  MCP_RESOURCE_IDENTIFIER: "https://mcp.example.com/mcp"
  MCP_LOG_LEVEL: "info"
  # Never return internal exception detail to the model or the wire.
  MCP_MASK_INTERNAL_ERRORS: "true"
  MCP_MAX_ERROR_TEXT_CHARS: "1200"
  OTEL_TRACES_SAMPLER: "parentbased_traceidratio"
  OTEL_TRACES_SAMPLER_ARG: "0.05"
```

### 9.2 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-db-tools
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-db-tools
    app.kubernetes.io/component: mcp-server
    app.kubernetes.io/part-of: agent-platform
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
      app.kubernetes.io/name: mcp-db-tools
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-db-tools
        app.kubernetes.io/component: mcp-server
    spec:
      serviceAccountName: mcp-db-tools
      automountServiceAccountToken: false
      # Must exceed the longest in-flight tools/call so a rolling update does
      # not turn graceful shutdown into a batch of ambiguous client timeouts.
      terminationGracePeriodSeconds: 90
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-db-tools
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: server
          image: registry.example.com/mcp/db-tools:1.8.3
          imagePullPolicy: IfNotPresent
          args:
            - "--transport"
            - "streamable-http"
            - "--host"
            - "0.0.0.0"
            - "--port"
            - "8080"
            - "--enable-sse-resumability"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9464
              protocol: TCP
          envFrom:
            - configMapRef:
                name: mcp-server-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: MCP_SESSION_STORE_URL
              valueFrom:
                secretKeyRef:
                  name: mcp-session-store
                  key: url
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: mcp-analytics-dsn
                  key: dsn
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: OTEL_SERVICE_NAME
              value: "mcp-db-tools"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=mcp,deployment.environment=production"
            # Unbuffered stdio: block buffering on a pipe delays every response.
            - name: PYTHONUNBUFFERED
              value: "1"
          startupProbe:
            httpGet:
              path: /healthz/started
              port: http
            periodSeconds: 3
            timeoutSeconds: 2
            failureThreshold: 20
          readinessProbe:
            # Must fail when the session store or the database pool is gone,
            # otherwise the replica keeps accepting sessions it cannot serve.
            httpGet:
              path: /healthz/ready
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 3
          livenessProbe:
            # Deliberately shallow: only "is the event loop alive". A deep
            # liveness probe restarts the pod for a downstream outage.
            httpGet:
              path: /healthz/live
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          lifecycle:
            preStop:
              exec:
                command:
                  - "/bin/sh"
                  - "-c"
                  - "sleep 15"
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "512Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
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
```

### 9.3 Service, disruption budget, autoscaling

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mcp-db-tools
  namespace: mcp
  labels:
    app.kubernetes.io/name: mcp-db-tools
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mcp-db-tools
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
  name: mcp-db-tools
  namespace: mcp
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-db-tools
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: mcp-db-tools
  namespace: mcp
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: mcp-db-tools
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
          averageValue: "150"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
    scaleDown:
      # Long window: scaling in evicts live sessions and manufactures 404s.
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 180
```

### 9.4 Network policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mcp-db-tools
  namespace: mcp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-db-tools
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
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 9464
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
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: data
          podSelector:
            matchLabels:
              app.kubernetes.io/name: analytics-replica
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: data
          podSelector:
            matchLabels:
              app.kubernetes.io/name: session-store
      ports:
        - protocol: TCP
          port: 6379
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

### 9.5 Gateway: timeouts that do not manufacture ambiguity

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-db-tools
  namespace: mcp
spec:
  parentRefs:
    - name: public-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - "mcp.example.com"
  rules:
    # 1. The server-initiated SSE stream. Long-lived by design: any finite
    #    request timeout here shows up as a periodic, inexplicable disconnect.
    - matches:
        - path:
            type: Exact
            value: /mcp
          method: GET
      timeouts:
        request: 0s
      backendRefs:
        - name: mcp-db-tools
          port: 80
    # 2. Session teardown.
    - matches:
        - path:
            type: Exact
            value: /mcp
          method: DELETE
      timeouts:
        request: 10s
        backendRequest: 10s
      backendRefs:
        - name: mcp-db-tools
          port: 80
    # 3. Every JSON-RPC request. 120s > the 30s server deadline, so the server
    #    always wins the race and the client receives a real JSON-RPC error
    #    instead of an ambiguous gateway 504.
    - matches:
        - path:
            type: Exact
            value: /mcp
          method: POST
      timeouts:
        request: 120s
        backendRequest: 120s
      backendRefs:
        - name: mcp-db-tools
          port: 80
```

Session affinity, without which horizontal scaling produces a `404` storm:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: mcp-db-tools
  namespace: mcp
spec:
  host: mcp-db-tools.mcp.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpHeaderName: Mcp-Session-Id
    connectionPool:
      tcp:
        maxConnections: 512
        connectTimeout: 3s
      http:
        http2MaxRequests: 2048
        http1MaxPendingRequests: 512
        # 0 = unlimited. A finite value tears down live SSE streams.
        maxRequestsPerConnection: 0
        idleTimeout: 900s
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

> Consistent hashing is a mitigation, not a fix. The durable answer is a **stateless** server with the session in Redis (`MCP_SESSION_STORE_KIND: redis` above), so any replica can serve any `Mcp-Session-Id`. Affinity alone still loses every session held by an evicted pod.

Retries, scoped to the one condition that is provably safe:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mcp-db-tools
  namespace: mcp
spec:
  hosts:
    - mcp-db-tools.mcp.svc.cluster.local
  http:
    - match:
        - uri:
            exact: /mcp
          method:
            exact: POST
      route:
        - destination:
            host: mcp-db-tools.mcp.svc.cluster.local
            port:
              number: 80
      timeout: 120s
      retries:
        attempts: 2
        perTryTimeout: 60s
        # reset-before-request fires ONLY when the stream was reset before the
        # request reached the upstream — the only condition under which retrying
        # a non-idempotent tools/call cannot duplicate work.
        retryOn: "connect-failure,refused-stream,reset-before-request"
    - match:
        - uri:
            exact: /mcp
          method:
            exact: GET
      route:
        - destination:
            host: mcp-db-tools.mcp.svc.cluster.local
            port:
              number: 80
      timeout: 0s
```

### 9.6 Observability

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mcp-db-tools
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-db-tools
  namespaceSelector:
    matchNames:
      - mcp
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      honorLabels: false
---
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mcp-access-logs
  namespace: mcp
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-db-tools
  accessLogging:
    - providers:
        - name: otel
      filter:
        expression: "response.code >= 400 || response.flags != ''"
```

The instrumentation contract the alerts below assume:

| Metric | Type | Labels | Records |
|---|---|---|---|
| `mcp_requests_total` | counter | `method`, `transport`, `outcome` | `outcome` ∈ `ok`, `protocol_error`, `tool_error` |
| `mcp_jsonrpc_errors_total` | counter | `method`, `code` | One per emitted JSON-RPC error object |
| `mcp_tool_errors_total` | counter | `tool`, `error_code`, `retryable` | One per `isError: true` result |
| `mcp_request_duration_seconds` | histogram | `method` | Server-side handling latency |
| `mcp_sessions_active` | gauge | — | Live sessions on this replica |
| `mcp_session_not_found_total` | counter | — | Every HTTP 404 for an unknown session |
| `mcp_cancellations_total` | counter | `method`, `origin` | `notifications/cancelled` received |
| `mcp_stdout_violations_total` | counter | — | Non-JSON bytes intercepted on stdout (stdio builds) |

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-db-tools-errors
  namespace: mcp
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp.availability
      interval: 30s
      rules:
        - alert: MCPInternalErrorBudgetBurn
          expr: |
            (
              sum(rate(mcp_jsonrpc_errors_total{code="-32603"}[5m]))
              /
              clamp_min(sum(rate(mcp_requests_total[5m])), 0.001)
            ) > 0.01
          for: 10m
          labels:
            severity: critical
            team: agent-platform
          annotations:
            summary: "MCP internal errors (-32603) above 1% for 10m"
            description: "The server is faulting in its own dispatch layer, not in tool logic. Check pod logs and the session store."
            runbook_url: "https://runbooks.example.com/mcp/internal-error"

        - alert: MCPRequestLatencyP99High
          expr: |
            histogram_quantile(
              0.99,
              sum by (le, method) (rate(mcp_request_duration_seconds_bucket[5m]))
            ) > 25
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "p99 MCP request latency is inside the 30s deadline margin"
            description: "Requests are approaching the server deadline; clients will begin timing out and cancelling."

    - name: mcp.sessions
      interval: 30s
      rules:
        - alert: MCPSessionNotFoundStorm
          expr: |
            sum(rate(mcp_session_not_found_total[5m]))
            /
            clamp_min(sum(rate(mcp_requests_total[5m])), 0.001)
            > 0.02
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "More than 2% of MCP requests hit an unknown session"
            description: "Session affinity is broken or the shared session store is unreachable. Clients are re-initializing in a loop."
            runbook_url: "https://runbooks.example.com/mcp/session-404"

        - alert: MCPSessionChurnAnomaly
          expr: |
            sum(rate(mcp_requests_total{method="initialize"}[5m]))
            >
            5 * sum(rate(mcp_requests_total{method="initialize"}[1h] offset 1h))
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Session creation rate is 5x the trailing hour"
            description: "Almost always a re-initialize loop caused by 404s or token expiry, not real traffic growth."

    - name: mcp.integration
      interval: 30s
      rules:
        # NOT an availability alert. -32601/-32602 mean a CLIENT is broken.
        - alert: MCPClientContractViolations
          expr: |
            sum by (code) (rate(mcp_jsonrpc_errors_total{code=~"-32600|-32601|-32602"}[15m]))
            > 0.2
          for: 15m
          labels:
            severity: warning
            team: agent-platform
            page: "false"
          annotations:
            summary: "Sustained client contract violations ({{ $labels.code }})"
            description: "A client build is calling methods or passing arguments this protocol revision does not accept. Check for a batched request or an un-negotiated capability."

        - alert: MCPParseErrors
          expr: sum(rate(mcp_jsonrpc_errors_total{code="-32700"}[5m])) > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "JSON-RPC parse errors — the message stream is corrupted"
            description: "On stdio this is almost certainly stdout poisoning. On HTTP, check for a proxy rewriting bodies or injecting an error page."

    - name: mcp.tools
      interval: 30s
      rules:
        - alert: MCPToolErrorRateHigh
          expr: |
            sum by (tool) (rate(mcp_tool_errors_total[10m]))
            /
            clamp_min(sum by (tool) (rate(mcp_requests_total{method="tools/call"}[10m])), 0.001)
            > 0.30
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Tool {{ $labels.tool }} is failing on more than 30% of calls"
            description: "Either a downstream dependency is degraded, or the tool description misleads the model into malformed calls."

        - alert: MCPStdoutProtocolViolation
          expr: increase(mcp_stdout_violations_total[15m]) > 0
          labels:
            severity: critical
          annotations:
            summary: "Non-protocol bytes were written to stdout"
            description: "A dependency is printing to stdout. Every stdio client of this build is broken. Find the writer and redirect it to stderr."
```

---

## 10. Verification and failure diagnosis

### 10.1 Layer 1 — is stdout clean? (stdio servers)

```
$ ./mcp-db-tools --transport stdio </dev/null 2>/dev/null | head -c 300
[2026-09-17 09:12:44] INFO  loading driver registry (postgres, mysql, duckdb)
/opt/venv/lib/python3.12/site-packages/oldlib/__init__.py:14: DeprecationWarning: pkg_resources is deprecated
```

That output is a total outage for every stdio client. A CI gate that catches it:

```
$ INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.1.0"}}}'
$ printf '%s\n' "$INIT" | ./mcp-db-tools --transport stdio 2>/dev/null \
    | while IFS= read -r line; do
        printf '%s' "$line" | jq -e 'has("jsonrpc")' >/dev/null 2>&1 \
          || { printf 'FAIL non-protocol bytes on stdout: %s\n' "$line"; exit 1; }
      done && echo "PASS stdout is pure JSON-RPC"
FAIL non-protocol bytes on stdout: [2026-09-17 09:12:44] INFO  loading driver registry (postgres, mysql, duckdb)
```

After redirecting the offending writer to stderr:

```
$ printf '%s\n' "$INIT" | ./mcp-db-tools --transport stdio 2>/dev/null | jq -c '.result.serverInfo, .result.protocolVersion'
{"name":"db-tools","version":"1.8.3"}
"2025-06-18"
```

### 10.2 Layer 2 — the handshake, end to end

```
$ npx -y @modelcontextprotocol/inspector --cli ./mcp-db-tools --transport stdio --method tools/list
{
  "tools": [
    {
      "name": "run_query",
      "title": "Run a read-only SQL query",
      "description": "Executes a single SELECT against the analytics replica.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "sql": { "type": "string", "minLength": 1 },
          "rowLimit": { "type": "integer", "minimum": 1, "maximum": 500, "default": 100 }
        },
        "required": ["sql"]
      }
    }
  ]
}
```

Deliberately provoke each plane and confirm you get the plane you expect:

```
$ npx -y @modelcontextprotocol/inspector --cli ./mcp-db-tools --transport stdio \
    --method tools/call --tool-name does_not_exist
Error: MCP error -32602: Unknown tool: does_not_exist

$ npx -y @modelcontextprotocol/inspector --cli ./mcp-db-tools --transport stdio \
    --method tools/call --tool-name run_query --tool-arg rowLimit=9999 --tool-arg sql="SELECT 1"
Error: MCP error -32602: row_limit must be between 1 and 500

$ npx -y @modelcontextprotocol/inspector --cli ./mcp-db-tools --transport stdio \
    --method tools/call --tool-name run_query --tool-arg sql="SELECT * FROM users"
{
  "content": [
    {
      "type": "text",
      "text": "UNKNOWN_RELATION (retryable=false): relation \"users\" does not exist\nThis connection is the analytics replica; user-facing tables live in the schema \"analytics\". Retry with a schema-qualified name, e.g. SELECT * FROM analytics.dim_users LIMIT 10"
    }
  ],
  "isError": true
}

$ npx -y @modelcontextprotocol/inspector --cli ./mcp-db-tools --transport stdio --method resources/list
Error: MCP error -32601: Method not found
```

Read that last one correctly: the server never declared a `resources` capability, so `-32601` is the **correct** answer, not a defect. Confirm before you file a bug:

```
$ printf '%s\n' "$INIT" | ./mcp-db-tools --transport stdio 2>/dev/null | jq '.result.capabilities'
{
  "tools": {
    "listChanged": true
  },
  "logging": {}
}
```

### 10.3 Layer 3 — the HTTP transport

```
$ export TOKEN="$(cat /run/secrets/mcp-token)"
$ curl -sS -D /tmp/h -o /tmp/b \
    -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-probe","version":"0.1.0"}}}'
$ cat /tmp/h
HTTP/2 200
content-type: application/json
mcp-session-id: 4f8c2b1e-9a77-4c31-b0a2-1d5e7f3a9c44
mcp-protocol-version: 2025-06-18
x-envoy-upstream-service-time: 34

$ export SID="$(awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' /tmp/h | tr -d '\r')"
$ echo "$SID"
4f8c2b1e-9a77-4c31-b0a2-1d5e7f3a9c44
```

Now walk the negative cases. Each should produce a *different* status:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
400

$ curl -sS -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -c .
{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Missing Mcp-Session-Id header"}}

$ curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: 00000000-0000-0000-0000-000000000000" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
404

$ curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":4,"method":"tools/list"}'
406

$ curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 1999-01-01' \
    -d '{"jsonrpc":"2.0","id":5,"method":"tools/list"}'
400
```

Batching, to confirm the revision boundary:

```
$ curl -sS -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '[{"jsonrpc":"2.0","id":6,"method":"tools/list"},{"jsonrpc":"2.0","id":7,"method":"ping"}]' | jq -c .
{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"JSON-RPC batching was removed in protocol revision 2025-06-18"}}
```

A streamed `tools/call` with progress, watched live:

```
$ curl -sS -N -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -d '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"run_query","arguments":{"sql":"SELECT count(*) FROM analytics.fct_events"},"_meta":{"progressToken":"q-8"}}}'
event: message
id: 1042
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"q-8","progress":0.1,"total":1.0,"message":"acquiring connection"}}

event: message
id: 1043
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"q-8","progress":0.5,"total":1.0,"message":"executing"}}

event: message
id: 1044
data: {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"count\n-----\n48211903"}],"structuredContent":{"ok":true,"rowCount":1},"isError":false}}
```

Verify resumption actually works — drop the stream and reconnect from the last event you saw:

```
$ curl -sS -N -X GET https://mcp.example.com/mcp \
    -H 'Accept: text/event-stream' \
    -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID" \
    -H 'MCP-Protocol-Version: 2025-06-18' \
    -H 'Last-Event-ID: 1043'
event: message
id: 1044
data: {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"count\n-----\n48211903"}],"structuredContent":{"ok":true,"rowCount":1},"isError":false}}
```

If that returns the stream from event `1` instead of `1044`, resumability is not implemented and every network blip will cost you a duplicated tool call.

### 10.4 Layer 4 — authorization

```
$ curl -sS -D - -o /dev/null -X POST https://mcp.example.com/mcp \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0.1.0"}}}'
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"
content-type: application/json

$ curl -sS https://mcp.example.com/.well-known/oauth-protected-resource | jq .
{
  "resource": "https://mcp.example.com/mcp",
  "authorization_servers": [
    "https://auth.example.com"
  ],
  "scopes_supported": [
    "mcp:tools:read",
    "mcp:tools:execute"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

Diagnosing the `401` refresh loop — decode what the client is actually sending:

```
$ python3 -c 'import base64,json,sys; p=sys.argv[1].split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))), indent=2))' "$TOKEN"
{
  "iss": "https://auth.example.com",
  "aud": "https://api.example.com",
  "sub": "agent-runtime-7",
  "scope": "mcp:tools:read",
  "exp": 1789412400
}
```

`aud` is `https://api.example.com`; the protected-resource metadata says the resource is `https://mcp.example.com/mcp`. **Audience mismatch** — the client is requesting tokens without an RFC 8707 `resource` parameter. Refreshing will mint the same wrong audience forever. The `scope` also lacks `mcp:tools:execute`, so even after fixing the audience, `tools/call` will return `403`.

### 10.5 Layer 5 — the cluster

```
$ kubectl -n mcp get pods -l app.kubernetes.io/name=mcp-db-tools -o wide
NAME                            READY   STATUS    RESTARTS      AGE     IP            NODE
mcp-db-tools-6d4f7c9b8f-2xk9p   1/1     Running   0             3h12m   10.42.1.87    node-a
mcp-db-tools-6d4f7c9b8f-8wqrt   1/1     Running   4 (6m ago)    3h12m   10.42.2.103   node-b
mcp-db-tools-6d4f7c9b8f-jl4mn   0/1     Running   0             3h12m   10.42.3.55    node-c

$ kubectl -n mcp describe pod mcp-db-tools-6d4f7c9b8f-jl4mn | sed -n '/Events:/,$p'
Events:
  Type     Reason     Age                    From     Message
  ----     ------     ----                   ----     -------
  Warning  Unhealthy  2m17s (x38 over 3h11m) kubelet  Readiness probe failed: HTTP probe failed with statuscode: 503

$ kubectl -n mcp logs mcp-db-tools-6d4f7c9b8f-jl4mn --tail=5 | jq -r '.msg'
session store unreachable: dial tcp 10.43.7.21:6379: i/o timeout
readiness: degraded (session_store=down, database=up)

$ kubectl -n mcp logs mcp-db-tools-6d4f7c9b8f-8wqrt --previous --tail=3 | jq -r '.msg'
liveness handler did not respond within 2s
received SIGTERM, draining 41 active sessions
```

Confirm the session-404 hypothesis directly from the metrics rather than by inference:

```
$ kubectl -n mcp port-forward svc/mcp-db-tools 9464:9464 >/dev/null 2>&1 &
$ sleep 1 && curl -sS localhost:9464/metrics | grep -E '^mcp_(session_not_found_total|sessions_active|requests_total\{method="initialize")'
mcp_session_not_found_total 18422
mcp_sessions_active 3
mcp_requests_total{method="initialize",transport="streamable-http",outcome="ok"} 18519
```

18 519 initializes against 3 live sessions is the signature of a re-initialize loop, not of traffic.

### 10.6 Symptom → plane → cause → next command

| Symptom | Plane | Most likely cause | First command |
|---|---|---|---|
| `Unexpected token 'L', "Loading mo"… is not valid JSON` | transport | stdout poisoning | `./server --transport stdio </dev/null 2>/dev/null \| head -c 200` |
| Client hangs forever at startup | lifecycle | Server never answered `initialize`, or blocked on a TTY prompt | `printf '%s\n' "$INIT" \| ./server` with a `timeout 5` wrapper |
| `-32601 Method not found` for a method you implemented | protocol | Capability not declared in the `initialize` result | `jq '.result.capabilities'` on the handshake |
| `-32602` on every `tools/call` | protocol | Tool name typo, or `inputSchema` stricter than the model's call | `--method tools/list` and diff the schema |
| HTTP `400 Missing Mcp-Session-Id` | session | Client dropped the header, or `initialize` was never completed | `curl -D -` and check the init response headers |
| HTTP `404` mid-session, intermittently | session | Replica fan-out without affinity or a shared store | `kubectl get endpoints` + the affinity `DestinationRule` |
| HTTP `404` after a deploy, all clients | session | In-memory session store lost on rollout | `MCP_SESSION_STORE_KIND` and pod restart count |
| `401` → refresh → `401` loop | authz | Token audience mismatch (missing RFC 8707 `resource`) | decode the JWT `aud`, compare to protected-resource metadata |
| `403` that retries never clear | authz | Insufficient scope | compare `scope` claim to `scopes_supported` |
| `-32600` on a perfectly valid request | protocol | Client sent a **batch** to a `2025-06-18` server | check whether the body starts with `[` |
| Duplicated writes after a timeout | retry | Gateway timeout shorter than the server deadline, plus a retry policy | compare `backendRequest` vs `MCP_REQUEST_DEADLINE_SECONDS` |
| SSE stream dies every 60 s | transport | A proxy/LB idle timeout on a long-lived GET | gateway `timeouts.request` on the GET rule, mesh `idleTimeout` |
| Model retries the same tool 20 times | application | Error text has no remediation, or no per-tool failure cap in the host | read the `isError` text as the model sees it |
| Empty results reported as failures | application | `isError: true` used for "no rows" | inspect the tool's success path |
| Latency spikes with no error rate change | transport | stdout block buffering on a pipe | `PYTHONUNBUFFERED=1` / explicit flush |

### 10.7 A pre-production error-handling checklist

1. Every tool returns `isError: true` — never a JSON-RPC error — for runtime failures, and every such payload names a corrective action.
2. Unknown tool name yields `-32602`; un-negotiated capability yields `-32601`. Both verified by a negative test in CI.
3. No traceback, hostname, DSN, SQL, token or internal path appears in any `error.data` or `isError` text. Verified by grepping the negative-test corpus.
4. stdout purity is a CI gate, not a convention.
5. The deadline ladder is strictly ordered — tool < server < gateway < client — and each value is asserted in a test, not just written in a ConfigMap.
6. Cancellation aborts real work (`extra.signal` / `asyncio` cancellation reaches the driver), and no response is emitted for a cancelled request.
7. Long-running tools emit `notifications/progress` and the client resets its deadline on receipt, under a hard maximum.
8. Sessions live in a shared store; affinity is a performance optimisation, not a correctness dependency.
9. SSE events carry `id` and the server honours `Last-Event-ID`.
10. No gateway or mesh retries `tools/call` on anything but `reset-before-request`.
11. `401` triggers at most one token refresh; `403` triggers none.
12. Protocol errors (`-32600`/`-32601`/`-32602`) alert an integrations channel, not the availability pager.
13. The host enforces a per-tool consecutive-failure cap and a per-turn tool-call budget.
14. `terminationGracePeriodSeconds` exceeds the longest tool deadline, and a `preStop` sleep covers endpoint propagation.

---

## 11. Exam-focused summary

| Question shape | Answer |
|---|---|
| Tool executed but failed — what does the server return? | A **successful** `CallToolResult` with `isError: true` |
| Tool name does not exist — what does the server return? | JSON-RPC `-32602 Invalid params` |
| Method belongs to an un-negotiated capability | `-32601 Method not found` |
| Bytes on the wire are not valid JSON | `-32700 Parse error` |
| `resources/read` on an unknown URI | `-32002 Resource not found`, `data.uri` set |
| Batch array sent to a `2025-06-18` server | `-32600 Invalid Request` — batching was removed |
| What may an stdio server write to stdout? | Only valid JSON-RPC messages. Logs go to stderr |
| HTTP `404` on a request carrying `Mcp-Session-Id` | The session is gone; the client must re-`initialize` |
| HTTP `405` on GET `/mcp` | The server offers no server-initiated SSE stream. Not an error |
| HTTP `202` | The POST contained only notifications/responses; there is no body to await |
| Which request must never be cancelled? | `initialize` |
| A response arrives for a request you already cancelled | Ignore it — the race is explicitly permitted |
| May receiving `notifications/progress` reset a timeout? | Yes, MAY — but a maximum total timeout SHOULD always apply |
| A user declines an elicitation | `action: "decline"` — a **success**, not an error |
| `WWW-Authenticate` on a `401` points where? | The protected-resource metadata document (RFC 9728) |
| Is `403 insufficient_scope` retryable? | No |

---

## 12. References

**Official MCP specification (revision `2025-06-18`)**

- Specification index — https://modelcontextprotocol.io/specification/2025-06-18
- Lifecycle and version negotiation — https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- Transports (stdio, Streamable HTTP, session and header rules) — https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Authorization (OAuth 2.1, protected-resource metadata, 401/403) — https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Cancellation — https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation
- Progress — https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
- Ping — https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/ping
- Tools (`isError`, protocol errors, structured output) — https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Resources (`-32002`) — https://modelcontextprotocol.io/specification/2025-06-18/server/resources
- Prompts — https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
- Logging (RFC 5424 levels, `logging/setLevel`) — https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/logging
- Elicitation — https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- Revision changelog (batching removal, `MCP-Protocol-Version` header) — https://modelcontextprotocol.io/specification/2025-06-18/changelog

**Base protocol and authorization standards**

- JSON-RPC 2.0 Specification (error object, reserved code ranges) — https://www.jsonrpc.org/specification
- RFC 6750 — Bearer Token Usage (`WWW-Authenticate`, `invalid_token`, `insufficient_scope`) — https://datatracker.ietf.org/doc/html/rfc6750
- RFC 8707 — Resource Indicators for OAuth 2.0 (audience binding) — https://datatracker.ietf.org/doc/html/rfc8707
- RFC 9728 — OAuth 2.0 Protected Resource Metadata — https://datatracker.ietf.org/doc/html/rfc9728
- RFC 5424 — The Syslog Protocol (severity levels) — https://datatracker.ietf.org/doc/html/rfc5424
- HTML Living Standard — Server-Sent Events (`id`, `Last-Event-ID`, reconnection) — https://html.spec.whatwg.org/multipage/server-sent-events.html

**Reference implementations and tooling**

- MCP Python SDK — https://github.com/modelcontextprotocol/python-sdk
- MCP TypeScript SDK — https://github.com/modelcontextprotocol/typescript-sdk
- MCP Inspector (including `--cli` mode) — https://github.com/modelcontextprotocol/inspector

**Platform and operations**

- Kubernetes — Configure Liveness, Readiness and Startup Probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod Lifecycle and termination — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes — Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Gateway API — HTTPRoute (timeouts, retries) — https://gateway-api.sigs.k8s.io/api-types/httproute/
- Istio — DestinationRule (consistent hashing, outlier detection) — https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — VirtualService (retries, `retryOn`) — https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Envoy — Router `x-envoy-retry-on` policies — https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter
- Prometheus Operator — PrometheusRule and ServiceMonitor — https://prometheus-operator.dev/docs/api-reference/api/
- OpenTelemetry — RPC semantic conventions (`rpc.system`, `rpc.jsonrpc.error_code`) — https://opentelemetry.io/docs/specs/semconv/rpc/
- Google SRE Workbook — Addressing Cascading Failures and retry budgets — https://sre.google/sre-book/addressing-cascading-failures/

**Certification**

- Linux Foundation — Model Context Protocol Associate (MCPA) — https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/