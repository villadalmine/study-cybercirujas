# Topic 3.3 — Tool Invocation Lifecycle

**Certification:** Model Context Protocol Associate (MCPA) · Exam version 2026-07-28
**Domain weight:** 6.5
**Audience level:** Platform Architect / SRE — production operation of MCP servers

---

## 1. Motivation: the architectural problem a tool call actually creates

A tool call is the only point in the Model Context Protocol where a **non-deterministic
producer** (a language model) triggers a **deterministic, side-effecting consumer** (your
code, your database, your cloud account). Every other MCP primitive is comparatively
benign: `resources/*` is a read, `prompts/*` is a template fetch. `tools/call` is the one
that can delete a bucket.

That asymmetry is what makes the lifecycle an operational concern rather than an API
detail. Four properties of the call path have no analogue in a normal RPC system:

**The caller cannot be held to a contract.** A conventional client is code you shipped;
if it sends a malformed request, you fix the client. Here the caller is a model whose
argument generation is probabilistic. It will send `{"replicas": "three"}`, it will
hallucinate a tool name that does not exist, and it will call the same tool twice because
it did not notice the first result. Schema validation is not defensive hygiene at the edge
— it is the *only* type system in the pipeline.

**Failure has two distinct audiences.** A tool that fails because the upstream API
returned HTTP 503 must report that failure *to the model*, because the model is the entity
that can retry, back off, or choose a different tool. A tool call that fails because the
tool does not exist must report *to the client host*, because the model cannot fix a
protocol violation. Collapsing these two into one error channel is the single most common
production defect in hand-rolled MCP servers, and it manifests as an agent that silently
stops making progress: it asked for something, got a transport-level exception the host
swallowed, and has no token in its context explaining why.

**Duration is unbounded and unknown in advance.** `list_pods` returns in 40 ms.
`run_migration` returns in eleven minutes. Both arrive on the same JSON-RPC method, over
the same connection, and the client has one timeout knob. Without progress notifications
the client must choose between killing legitimate long work and hanging forever on a
deadlocked server.

**The result re-enters the model's context as trusted text.** Whatever your tool returns
is concatenated into the prompt of the next inference pass. A tool that echoes attacker-
controlled content — an issue title, a log line, a webhook payload — is an injection
vector with a direct line into the agent's instruction stream. The lifecycle's final
phase is therefore a sanitisation boundary, not just a serialisation step.

### 1.1 The production failure this topic exists to prevent

The canonical incident: an agent-backed runbook calls a `scale_deployment` tool. The
server takes 90 s because the cluster API is slow. The client's default 60 s timeout
fires, the client emits `notifications/cancelled`, and the host tells the model "the tool
call failed." The model retries. The server — which never implemented cancellation
handling — is now executing the scale twice. Neither call is observable as related to the
other because nobody propagated a trace context. The deployment ends up at the wrong
replica count and the post-mortem blames "the AI."

Every element of that incident is a lifecycle defect: no progress notification to extend
the deadline, no cancellation handling to stop the first execution, no idempotency hint to
tell the client that retrying was unsafe, no correlation identifier to reconstruct what
happened. The rest of this topic is the set of mechanisms that each of those defects maps
onto.

---

## 2. The lifecycle, phase by phase

MCP's tool invocation lifecycle has seven phases. Only two of them (`tools/list` and
`tools/call`) are wire methods; the other five are obligations placed on one side or the
other and are where implementations diverge.

```
 CLIENT / HOST                                          SERVER
      │                                                    │
 (0)  │  initialize  { capabilities, protocolVersion }      │
      │ ─────────────────────────────────────────────────> │
      │  <───── result { capabilities: { tools: {…} } } ─── │
      │  notifications/initialized ─────────────────────>   │
      │                                                    │
 (1)  │  tools/list  { cursor? }                           │  DISCOVERY
      │ ─────────────────────────────────────────────────> │
      │  <── result { tools: [...], nextCursor? } ───────── │
      │                                                    │
 (2)  │  [host] normalise names, pin definitions,          │  REGISTRATION
      │         translate schemas into model tool defs     │
      │                                                    │
 (3)  │  [model] emits a tool call                         │  SELECTION
      │  [host]  validate args against inputSchema         │  VALIDATION
      │  [host]  human-in-the-loop / policy gate           │  AUTHORIZATION
      │                                                    │
 (4)  │  tools/call { name, arguments, _meta.progressToken }│  INVOCATION
      │ ─────────────────────────────────────────────────> │
      │                                                    │ ┌─ execute
      │  <── notifications/progress { progress, total } ─── │ │  (may emit
      │  <── sampling/createMessage  (server → client) ───> │ │   nested
      │  <── elicitation/create      (server → client) ───> │ │   requests)
      │                                                    │ └─
      │  notifications/cancelled { requestId } ──────────>  │  (optional)
      │                                                    │
 (5)  │  <── result { content[], structuredContent?,        │  COMPLETION
      │              isError } ──────────────────────────── │
      │        OR error { code, message, data }            │
      │                                                    │
 (6)  │  [host] validate outputSchema, sanitise, budget,   │  INGESTION
      │         inject into model context                  │
      │                                                    │
 (*)  │  <── notifications/tools/list_changed ───────────── │  INVALIDATION
      │  tools/list (re-discover) ──────────────────────>   │
```

### 2.1 Phase 0 — capability negotiation gates everything

A server that does not declare `tools` in its `initialize` result must never receive a
`tools/call`. A client that does not declare `sampling` must never receive a
`sampling/createMessage` from inside a tool execution. This is the cheapest bug class to
eliminate and the one most often skipped, because both SDKs are permissive in development
and strict under a different transport.

The `listChanged` sub-capability is separate and matters for cache correctness:

```json
{
  "protocolVersion": "2025-06-18",
  "capabilities": {
    "tools": {
      "listChanged": true
    },
    "logging": {},
    "completions": {}
  },
  "serverInfo": {
    "name": "cluster-ops-mcp",
    "version": "2.4.1",
    "title": "Cluster Operations"
  },
  "instructions": "Read-only cluster inspection tools plus two gated mutation tools. Always call describe_workload before any scale or restart operation."
}
```

If `listChanged` is absent or `false`, the client is entitled to cache `tools/list`
forever. If your server's tool surface varies with the authenticated principal — a common
and correct design — and you did not declare `listChanged`, clients will serve a stale
tool set across a permission change. Declare it, and emit
`notifications/tools/list_changed` whenever the effective set for that session changes.

### 2.2 Phase 1 — discovery and the pagination trap

`tools/list` is paginated with an opaque cursor. The opacity is normative: clients must
treat `nextCursor` as a bearer token for "the rest of the list," not parse it, not
persist it across sessions, and not assume stability.

```
$ npx @modelcontextprotocol/inspector --cli \
    --transport http --server-url https://mcp.example.internal/mcp \
    --header "Authorization: Bearer $MCP_TOKEN" \
    --method tools/list

{
  "tools": [
    {
      "name": "list_workloads",
      "title": "List workloads",
      "description": "List Deployments, StatefulSets and DaemonSets in a namespace, with replica counts and rollout status.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "namespace": { "type": "string", "pattern": "^[a-z0-9-]{1,63}$" },
          "kind": { "type": "string", "enum": ["Deployment", "StatefulSet", "DaemonSet"] }
        },
        "required": ["namespace"],
        "additionalProperties": false
      },
      "annotations": {
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false
      }
    }
  ],
  "nextCursor": "eyJvIjoxMDB9"
}
```

The production failure mode here is silent truncation: a host that issues one
`tools/list`, ignores `nextCursor`, and presents page one to the model. The model then
"cannot find" tools that exist. There is no error anywhere in the system — the symptom is
purely behavioural, which is why it survives to production. Assert on it in CI: count the
tools the server registers, count the tools the client ends up with, fail if they differ.

### 2.3 Phase 2 — registration, name collisions and definition pinning

The host takes the union of tool lists from every connected server and must produce a flat
namespace for the model. Two servers exposing `search` is not a hypothetical; it is the
normal case once a user connects both a docs server and a ticketing server.

| Collision strategy | Model-visible name | Breaks on | Verdict |
|---|---|---|---|
| Last writer wins | `search` | Silently shadows a tool; unattributable | Never |
| First writer wins | `search` | Same, inverted | Never |
| Server-prefixed | `docs__search` | Prefix eats the model's name budget | **Default** |
| Prefixed on collision only | `search`, `jira__search` | Name changes when a second server connects → breaks prompt caching and few-shot examples | Acceptable if names are pinned per session |
| User-assigned alias | `wiki_search` | Requires configuration | Best for curated deployments |

Prefix with a separator the model will not mangle and that survives the host's own name
constraints (many model APIs restrict tool names to `^[a-zA-Z0-9_-]{1,64}$` — a `.` or `/`
separator is rejected, `__` is safe).

**Definition pinning** addresses the *rug pull*: a server presents a benign tool, the user
approves it, and the server later changes the description to embed instructions or changes
the schema to exfiltrate data. Because approval is granted against a definition the user
read once, the host must detect drift:

```python
import hashlib
import json


def tool_fingerprint(tool: dict) -> str:
    """Stable hash of everything a user's approval was granted against.

    Covers the fields that reach the model or the user: name, description and
    the full input schema. A change in any of them re-opens the consent gate.
    """
    material = json.dumps(
        {
            "name": tool["name"],
            "title": tool.get("title"),
            "description": tool.get("description", ""),
            "inputSchema": tool["inputSchema"],
            "outputSchema": tool.get("outputSchema"),
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()
```

Store the fingerprint alongside the grant. On every `tools/list` — including the one
triggered by `notifications/tools/list_changed` — recompute and compare. A mismatch
revokes the grant and requires re-consent. Note that `annotations` are deliberately
excluded from the pin in some designs and included in others; including them is stricter
and is the recommendation, because a flip from `readOnlyHint: true` to `false` is exactly
the drift you want to catch.

### 2.4 Phase 3 — validation and the authorization gate

Three checks run before a byte goes on the wire, in this order:

1. **Existence.** Is the name in the current, pinned tool set? A hallucinated name must
   not become a network round trip.
2. **Schema.** Do the arguments validate against `inputSchema` under a real JSON Schema
   validator, with `additionalProperties: false` honoured? Client-side validation is not a
   substitute for server-side validation — it is a latency and cost optimisation that
   turns a 300 ms round trip into a 1 ms local rejection the model can immediately correct.
3. **Policy.** Does the caller — the human behind the session, not the model — permit this
   invocation?

The specification is explicit that tool invocation **SHOULD** be behind human approval,
and that clients **SHOULD** show the user what will be executed. In an SRE context, "human
in the loop on every call" does not survive contact with a 40-step runbook. The workable
pattern is a **tiered gate driven by annotations plus server-side policy**, with
annotations treated as untrusted input:

| Tier | Condition | Gate |
|---|---|---|
| Auto | `readOnlyHint: true` AND server is in the trusted registry AND `openWorldHint: false` | None; audit log only |
| Session-approved | `readOnlyHint: true`, any server | Approve once per session per tool |
| Per-call | `destructiveHint: true` OR `readOnlyHint` absent | Confirm each call, rendering full arguments |
| Blocked | Tool fingerprint drifted, or server unauthenticated | Refuse, re-consent required |

The critical sentence in the specification about annotations: they are **hints**, and
clients **MUST NOT** make security decisions based on annotations received from an
untrusted server. Read that as: annotations may *narrow* a gate for a server you already
trust by configuration; they may never *widen* one. A malicious server sets
`readOnlyHint: true` on `delete_everything`. Your host-side registry of which servers are
trusted is the actual control.

### 2.5 Phase 4 — invocation

```
→ POST /mcp
{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"scale_workload","arguments":{"namespace":"payments","name":"api","replicas":6},"_meta":{"progressToken":"call-42"}}}
```

Three things about this frame carry operational weight.

**`id` is the correlation key for the entire call.** It must be unique within the session
and must never be `null`. It is what `notifications/cancelled` references, it is what the
response is matched against, and it is what you should attach to every log line and span
emitted while the call runs.

**`_meta.progressToken` is opt-in and client-supplied.** If the client does not send one,
the server MUST NOT send progress notifications for that request. Servers that emit
progress unconditionally will be talking to a client that has no idea what the token
refers to. Conversely, a client that never sends a progress token has permanently opted
out of deadline extension, which is a choice, not a default to drift into.

**JSON-RPC batching is not available.** The 2025-06-18 revision removed it. Concurrency is
achieved by multiple in-flight requests with distinct `id`s on the same connection, not by
arrays. Any code path in your implementation that constructs a JSON array at the top level
of an MCP message is a bug against the current protocol.

### 2.6 Phase 5 — completion, and the error dichotomy that defines this topic

This is the highest-value concept in the domain and it is routinely examined.

```
┌──────────────────────────────────────────────────────────────────────┐
│  PROTOCOL ERROR                  │  TOOL EXECUTION ERROR             │
│  JSON-RPC `error` object         │  JSON-RPC `result` with           │
│                                  │  isError: true                    │
├──────────────────────────────────┼───────────────────────────────────┤
│  "The request was not valid MCP" │  "The request was valid; the      │
│                                  │   work failed"                    │
├──────────────────────────────────┼───────────────────────────────────┤
│  Unknown tool name        -32602 │  Upstream API returned 503        │
│  Arguments fail schema    -32602 │  File not found                   │
│  Unknown method           -32601 │  Insufficient quota               │
│  Malformed JSON           -32700 │  Validation failed on a business  │
│  Server bug / panic       -32603 │    rule the schema cannot express │
│  Unauthorized       -32001 (impl)│  Timeout calling a dependency     │
├──────────────────────────────────┼───────────────────────────────────┤
│  Consumed by: the HOST           │  Consumed by: the MODEL           │
│  Model typically never sees it   │  Enters context as tool output    │
│  Model cannot correct it         │  Model can retry, adapt, escalate │
└──────────────────────────────────┴───────────────────────────────────┘
```

A successful invocation whose work failed:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Scale rejected: deployment payments/api is governed by a HorizontalPodAutoscaler (payments/api-hpa) with minReplicas=8. Setting replicas=6 would be reverted within 15s. Adjust the HPA bounds with update_hpa, or pass force=true to scale anyway."
      }
    ],
    "isError": true
  }
}
```

That text is doing real work. It names the obstruction, names the remedy, and names the
tool that implements the remedy. The model can act on it in the next turn without a human.
Compare the same condition returned as a protocol error:

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "error": {
    "code": -32603,
    "message": "Internal error"
  }
}
```

The host now has an exception. Most hosts surface this to the user, not the model. The
agent's context contains nothing. It either stalls or retries identically forever.

**The operational rule:** an exception escaping your tool handler must be caught at the
handler boundary and converted to `isError: true` with a message written for a reader who
has no access to your logs. Reserve the JSON-RPC `error` channel for things that are
genuinely the *caller's* protocol fault, and — critically — make sure your framework is
not converting your exceptions into `-32603` behind your back. Most SDKs do exactly that
by default.

```python
from mcp.server.fastmcp import FastMCP
from mcp.types import TextContent, CallToolResult

mcp = FastMCP("cluster-ops-mcp")


@mcp.tool()
async def scale_workload(namespace: str, name: str, replicas: int) -> CallToolResult:
    """Scale a Deployment. Returns isError for any operational failure so the
    model can choose a remedy; only protocol-level faults propagate as JSON-RPC
    errors."""
    try:
        hpa = await k8s.find_hpa(namespace, name)
        if hpa and replicas < hpa.min_replicas:
            return CallToolResult(
                isError=True,
                content=[
                    TextContent(
                        type="text",
                        text=(
                            f"Scale rejected: {namespace}/{name} is governed by "
                            f"HPA {hpa.name} with minReplicas={hpa.min_replicas}. "
                            f"Use update_hpa to lower the floor first."
                        ),
                    )
                ],
            )
        result = await k8s.scale(namespace, name, replicas)
        return CallToolResult(
            content=[TextContent(type="text", text=result.summary)],
            structuredContent=result.as_dict(),
        )
    except k8s.Forbidden as exc:
        return CallToolResult(
            isError=True,
            content=[
                TextContent(
                    type="text",
                    text=(
                        "Permission denied. The server's service account lacks "
                        f"patch on deployments/scale in {namespace}. This cannot "
                        "be resolved by retrying; escalate to a cluster admin. "
                        f"({exc.reason})"
                    ),
                )
            ],
        )
    except TimeoutError:
        return CallToolResult(
            isError=True,
            content=[
                TextContent(
                    type="text",
                    text=(
                        "The Kubernetes API did not respond within 20s. The scale "
                        "may or may not have been applied. Call describe_workload "
                        "to determine current state before retrying."
                    ),
                )
            ],
        )
```

Note the timeout branch. It tells the model the operation is in an *unknown* state and
names the tool that resolves the ambiguity. "Timed out, please retry" would be actively
dangerous on a non-idempotent operation.

### 2.7 Content types in a result

`content` is an ordered array. Each element is one of:

| `type` | Payload | Use when |
|---|---|---|
| `text` | `text` | Default. Anything the model should read directly |
| `image` | `data` (base64), `mimeType` | Screenshots, rendered graphs. Costly in tokens; gate behind a flag |
| `audio` | `data` (base64), `mimeType` | Transcription pipelines |
| `resource_link` | `uri`, `name`, `mimeType`, `description` | **Large results.** Return a pointer; let the client fetch via `resources/read` only if needed |
| `resource` | embedded `resource` object with `uri` + `text`/`blob` | Small results where a round trip is not worth it, and the URI matters for provenance |

`resource_link` is the production answer to the context-budget problem. A tool that dumps
80 000 tokens of logs into `content` has destroyed the session. A tool that returns a
`resource_link` to `logs://payments/api/2026-09-17T14:00Z` plus a 200-token summary lets
the host decide. Note the specification's caveat: resource links returned by a tool are
not guaranteed to appear in `resources/list`, and the client's ability to read them
depends on the server exposing that URI.

### 2.8 Structured output: `outputSchema` and `structuredContent`

Introduced in revision 2025-06-18. A tool may declare an `outputSchema`; when it does, it
**MUST** return `structuredContent` conforming to that schema, and clients **SHOULD**
validate it. For backwards compatibility, servers returning `structuredContent` should
also return a serialised text representation in `content`, so that clients on older
revisions still get something usable.

```json
{
  "name": "describe_workload",
  "title": "Describe workload",
  "description": "Return rollout status, replica counts and the most recent failure condition for a workload.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "namespace": { "type": "string" },
      "name": { "type": "string" }
    },
    "required": ["namespace", "name"],
    "additionalProperties": false
  },
  "outputSchema": {
    "type": "object",
    "properties": {
      "desiredReplicas": { "type": "integer", "minimum": 0 },
      "readyReplicas": { "type": "integer", "minimum": 0 },
      "rolloutComplete": { "type": "boolean" },
      "lastFailureReason": { "type": ["string", "null"] },
      "images": { "type": "array", "items": { "type": "string" } }
    },
    "required": ["desiredReplicas", "readyReplicas", "rolloutComplete"],
    "additionalProperties": false
  },
  "annotations": {
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  }
}
```

| Property | Unstructured (`content` only) | Structured (`outputSchema`) |
|---|---|---|
| Model consumption | Parses prose; brittle | Receives typed fields; still usually serialised into the prompt |
| Programmatic consumption by the host | Regex; unmaintainable | Direct field access; enables deterministic chaining |
| Contract testing | Assert on substrings | Validate against schema in CI |
| Token cost | Lower if well written | Higher — JSON is verbose |
| Failure detection | None | Schema violation is a detectable server bug |
| Backwards compatibility | Universal | Older clients ignore `structuredContent` unless you also fill `content` |

Architectural guidance: declare `outputSchema` for tools whose results feed other tools or
host-side logic. Skip it for tools whose result is genuinely narrative (a summary, an
explanation). A schema on a narrative tool forces you into `{"answer": "<prose>"}`, which
is pure overhead.

---

## 3. Time: timeouts, progress, and cancellation

### 3.1 The three clocks

Every tool call is racing three independent deadlines, and most production hangs are a
disagreement between them.

| Clock | Owner | Typical default | Effect on expiry |
|---|---|---|---|
| Client request timeout | MCP client | 60 s (SDK-dependent) | Emits `notifications/cancelled`, surfaces failure to host |
| Server-side execution timeout | Your handler | None unless you add one | Nothing — the handler runs forever |
| Transport / infrastructure timeout | Ingress, proxy, LB | 30–60 s idle | Connection torn down; client sees a transport error, not a tool error |

The infrastructure clock is the one that gets forgotten. An Envoy/nginx ingress with a
default 60 s `stream_idle_timeout` will kill a Streamable HTTP SSE stream that has been
silent for 60 s, even though the server is happily working on an eleven-minute migration.
The symptom is a tool call that "fails at exactly 60 seconds" regardless of client
configuration. Progress notifications incidentally fix this too, because they keep the
stream non-idle — which is a real reason to emit them on a heartbeat even when you have no
meaningful progress to report.

### 3.2 Progress notifications

The client opts in by putting a `progressToken` in `_meta`. The server then sends
unsolicited notifications correlated by that token.

```
← event: message
← data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"call-42","progress":3,"total":12,"message":"Draining node worker-3 (3/12)"}}
```

Normative constraints worth memorising:

- `progress` **MUST** increase with each notification for a given token, even if `total` is
  unknown.
- `total` is optional. Omit it rather than guessing — a shrinking or lying `total` is worse
  than none.
- `message` is an optional human-readable string; it is for the *user's* progress UI, not
  for the model.
- Notifications **MUST** stop once the response is sent.
- Implementations **SHOULD** rate-limit progress to avoid flooding.

Progress and timeouts interact: implementations **MAY** reset the request timeout on
receipt of a progress notification, but **SHOULD** always enforce a maximum total
timeout regardless. Without that ceiling, a server that emits progress forever holds the
client hostage indefinitely — a trivially available denial of service. Configure both: a
per-message idle timeout and an absolute wall-clock cap.

### 3.3 Cancellation

```
→ {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42,"reason":"User aborted the runbook"}}
```

Rules that determine whether your implementation is correct:

- `requestId` **MUST** refer to a request previously issued *in the same direction* on the
  same session.
- The `initialize` request **MUST NOT** be cancelled by clients.
- The receiver **SHOULD** stop processing and **SHOULD NOT** send a response for the
  cancelled request.
- The receiver **MAY** ignore the notification entirely — the request may already be
  complete, may be unknown, or cancellation may be unsupported for that operation.
- Both sides **MUST** tolerate a race: a response that crosses a cancellation in flight is
  normal, and the client **SHOULD** ignore it.

The SRE consequence: **cancellation is advisory, and delivery of the notification does not
mean the side effect was prevented.** Treat a cancelled mutating call exactly like a timed-
out one — state unknown, verify before retrying. Design mutating tools so that this is
survivable:

| Technique | Mechanism | Cost |
|---|---|---|
| Idempotency key | Client-supplied key in arguments; server deduplicates for a TTL | Requires a shared store; key must be model-stable |
| Conditional write | `resourceVersion` / ETag / `If-Match` precondition in arguments | Only works where upstream supports it; cheapest and strongest |
| Two-phase tool pair | `plan_scale` returns a signed plan id; `apply_plan` consumes it once | Two round trips; excellent audit trail; natural approval point |
| Declarative target | Tool sets desired state (`replicas=6`), never a delta (`replicas+=1`) | Free. **Do this always** |

The last row is the one that costs nothing and prevents the most damage. A tool whose
semantics are "set to N" is inherently safe to repeat; a tool whose semantics are "add one"
is not. Design tool surfaces declaratively and most of the retry problem disappears.

### 3.4 Nested requests during execution: sampling, elicitation, and deadlock

A server may, mid-execution, send requests *back* to the client — `sampling/createMessage`
to ask the model something, `elicitation/create` to ask the user something, `roots/list` to
learn the workspace boundaries.

```
CLIENT                                    SERVER
  │  tools/call id=42 ─────────────────────>│
  │                                         │ handler begins
  │ <──── elicitation/create id=s1 ──────── │ "Which cluster? prod or staging"
  │  [blocks on human]                      │ handler awaits
  │  ──── result { action: "accept", … } ──>│
  │                                         │ handler resumes
  │ <──── result id=42 ──────────────────── │
```

Two production hazards live here:

**Deadlock by timeout asymmetry.** The server is blocked awaiting `elicitation/create`,
which is blocked awaiting a human. The client's timeout on request `42` is 60 s. The human
takes four minutes. The client cancels `42`; the server is still blocked on `s1`, which the
client may never answer. Both sides leak a pending operation. Mitigation: servers must
apply their own timeout to outbound requests and must handle cancellation of the parent
call by cancelling every nested request derived from it.

**Capability violation.** If the client did not declare `elicitation` at `initialize`, the
server must not send it. A server that assumes the capability will hang against every
client that lacks it. Check `initialize` results; degrade to a required argument on the
tool instead.

Elicitation carries a hard normative restriction that is frequently examined: servers
**MUST NOT** use elicitation to request sensitive information such as passwords, API keys
or tokens. Credentials belong to the authorization layer, not the tool lifecycle.

---

## 4. Transport-level lifecycle

The lifecycle above is transport-agnostic, but the failure modes are not.

| Concern | stdio | Streamable HTTP |
|---|---|---|
| Session identity | The process | `Mcp-Session-Id` header, issued at `initialize` |
| Concurrency | Multiplexed over one pipe pair | Multiple POSTs, optional standalone SSE via GET |
| Server→client messages | Interleaved on stdout | SSE stream on the POST response, or the GET stream |
| Resumability | None; process restart = session loss | `Last-Event-ID` replay on a per-stream basis |
| Horizontal scale | N/A (one process per client) | Requires session affinity or externalised state |
| Termination | Close stdin → SIGTERM → SIGKILL | HTTP `DELETE` to the endpoint; 405 if unsupported |
| Primary hazard | Anything written to stdout that is not a JSON-RPC message corrupts the stream | Session pinned to a pod that gets evicted mid-call |

**The stdio rule that breaks the most servers:** the server **MUST NOT** write anything to
stdout that is not a valid MCP message. A stray `print()`, a library's banner, a
progress bar, a warning from a transitive dependency — all of them corrupt the frame and
the client disconnects with a parse error that names a line of JSON you never wrote.
Logging goes to stderr, always, and you should assert this in tests by piping stdout
through a JSON-lines validator.

**The Streamable HTTP rules that break the most deployments:**

- The client **MUST** send `Accept: application/json, text/event-stream` on POST. A server
  that wants to answer with SSE cannot if the client only accepts JSON.
- From revision 2025-06-18, the client **MUST** send `MCP-Protocol-Version` on every
  request after initialization. Servers that do not see it should assume `2025-03-26` for
  compatibility; servers that see an unsupported value **MUST** respond `400`.
- Servers **MUST** validate the `Origin` header to prevent DNS rebinding, and local servers
  **SHOULD** bind to `127.0.0.1`, not `0.0.0.0`.
- A POST carrying only notifications or responses gets `202 Accepted` with no body.
- A `404` on a request carrying `Mcp-Session-Id` means the session expired; the client
  **MUST** re-initialize.

### 4.1 Raw wire exchange

```
$ curl -sS -N https://mcp.example.internal/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: 1f5c8a2e-7b31-4d09-9f2c-6a0d3e8b1c44" \
    -d '{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"drain_node","arguments":{"node":"worker-3","gracePeriodSeconds":120},"_meta":{"progressToken":"call-42"}}}'

event: message
id: 8f31a0
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"call-42","progress":1,"total":4,"message":"Cordoning worker-3"}}

event: message
id: 8f31a1
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"call-42","progress":2,"total":4,"message":"Evicting 14 pods"}}

event: message
id: 8f31a2
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"call-42","progress":3,"total":4,"message":"Waiting for PodDisruptionBudget payments/api"}}

event: message
id: 8f31a3
data: {"jsonrpc":"2.0","id":42,"result":{"content":[{"type":"text","text":"Node worker-3 drained. 14 pods evicted, 0 remaining. Node is cordoned; run uncordon_node to return it to service."}],"structuredContent":{"node":"worker-3","evicted":14,"remaining":0,"cordoned":true},"isError":false}}
```

Observe that the response to request `42` arrives **on the SSE stream opened by the POST
for request 42**. The specification requires that a server's response to a request be sent
on the stream that carried it — this is what makes `Last-Event-ID` resumption meaningful
and what makes a load balancer that breaks affinity catastrophic rather than merely slow.

Resuming after a dropped stream:

```
$ curl -sS -N https://mcp.example.internal/mcp \
    -H "Accept: text/event-stream" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: 1f5c8a2e-7b31-4d09-9f2c-6a0d3e8b1c44" \
    -H "Last-Event-ID: 8f31a1"

event: message
id: 8f31a2
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"call-42","progress":3,"total":4,"message":"Waiting for PodDisruptionBudget payments/api"}}

event: message
id: 8f31a3
data: {"jsonrpc":"2.0","id":42,"result":{"content":[{"type":"text","text":"Node worker-3 drained. 14 pods evicted, 0 remaining. Node is cordoned; run uncordon_node to return it to service."}],"structuredContent":{"node":"worker-3","evicted":14,"remaining":0,"cordoned":true},"isError":false}}
```

Terminating the session explicitly:

```
$ curl -sS -i -X DELETE https://mcp.example.internal/mcp \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: 1f5c8a2e-7b31-4d09-9f2c-6a0d3e8b1c44"

HTTP/2 204
mcp-session-id: 1f5c8a2e-7b31-4d09-9f2c-6a0d3e8b1c44
date: Thu, 17 Sep 2026 14:22:07 GMT
```

A `405 Method Not Allowed` here is legal and means the server does not permit client-driven
session termination.

---

## 5. Production infrastructure

The manifests below deploy an MCP server over Streamable HTTP in a way that does not break
the tool invocation lifecycle. The design decisions that matter are called out inline.

### 5.1 Namespace, configuration and workload

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcp-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-ops-mcp-config
  namespace: mcp-system
data:
  MCP_TRANSPORT: "http"
  MCP_BIND_ADDRESS: "0.0.0.0"
  MCP_PORT: "8080"
  MCP_ENDPOINT_PATH: "/mcp"
  MCP_PROTOCOL_VERSION: "2025-06-18"
  MCP_ALLOWED_ORIGINS: "https://console.example.com,https://ide.example.com"
  MCP_SESSION_STORE: "redis"
  MCP_SESSION_REDIS_URL: "redis://mcp-session-store.mcp-system.svc.cluster.local:6379/0"
  MCP_SESSION_TTL_SECONDS: "3600"
  MCP_EVENT_LOG_RETENTION_SECONDS: "900"
  MCP_TOOL_TIMEOUT_SECONDS: "600"
  MCP_TOOL_PROGRESS_INTERVAL_SECONDS: "10"
  MCP_TOOL_MAX_CONCURRENCY: "16"
  MCP_UPSTREAM_TIMEOUT_SECONDS: "20"
  MCP_LOG_LEVEL: "info"
  MCP_LOG_DESTINATION: "stderr"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
  OTEL_SERVICE_NAME: "cluster-ops-mcp"
  OTEL_TRACES_SAMPLER: "parentbased_traceidratio"
  OTEL_TRACES_SAMPLER_ARG: "0.1"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-ops-mcp
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "namespaces", "events", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["patch", "update"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-ops-mcp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-ops-mcp
subjects:
  - kind: ServiceAccount
    name: cluster-ops-mcp
    namespace: mcp-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
  labels:
    app.kubernetes.io/name: cluster-ops-mcp
    app.kubernetes.io/component: mcp-server
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: cluster-ops-mcp
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cluster-ops-mcp
        app.kubernetes.io/component: mcp-server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: cluster-ops-mcp
      # Must exceed MCP_TOOL_TIMEOUT_SECONDS plus the preStop drain, or an
      # in-flight tools/call is SIGKILLed and the client sees a transport
      # error instead of a tool error it could reason about.
      terminationGracePeriodSeconds: 660
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
              app.kubernetes.io/name: cluster-ops-mcp
      containers:
        - name: server
          image: registry.example.com/mcp/cluster-ops-mcp:2.4.1
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
                name: cluster-ops-mcp-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=mcp,deployment.environment=production"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 1Gi
          startupProbe:
            httpGet:
              path: /healthz
              port: metrics
            periodSeconds: 5
            failureThreshold: 24
          readinessProbe:
            httpGet:
              path: /readyz
              port: metrics
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: metrics
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                # Fail readiness first so the Endpoints controller removes this
                # pod, then let existing tool calls finish before SIGTERM.
                command:
                  - /bin/sh
                  - -c
                  - "touch /tmp/drain && sleep 15"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
```

### 5.2 Service, disruption budget and autoscaling

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
  labels:
    app.kubernetes.io/name: cluster-ops-mcp
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: cluster-ops-mcp
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
  name: cluster-ops-mcp
  namespace: mcp-system
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: cluster-ops-mcp
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cluster-ops-mcp
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Pods
      pods:
        metric:
          name: mcp_tool_calls_in_flight
        target:
          type: AverageValue
          averageValue: "8"
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
    scaleDown:
      # Long window: scaling down evicts pods holding live MCP sessions and
      # in-flight tool calls. Prefer paying for idle capacity.
      stabilizationWindowSeconds: 900
      policies:
        - type: Pods
          value: 1
          periodSeconds: 300
```

Scaling on `mcp_tool_calls_in_flight` rather than CPU is deliberate. MCP servers are
overwhelmingly I/O-bound proxies onto other APIs; a pod can be at 4% CPU while holding
sixty blocked tool executions and being completely unable to accept another. CPU-only
autoscaling on an MCP server will never fire before the server starts timing out.

### 5.3 Session affinity — and why you should not need it

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
spec:
  host: cluster-ops-mcp.mcp-system.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpHeaderName: Mcp-Session-Id
    connectionPool:
      http:
        h2UpgradePolicy: UPGRADE
        maxRequestsPerConnection: 0
        idleTimeout: 900s
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 60s
      maxEjectionPercent: 33
```

| Approach | Correct under pod loss? | Correct under scale-down? | Complexity |
|---|---|---|---|
| Consistent hash on `Mcp-Session-Id`, in-memory state | No — session is gone, client gets `404`, must re-initialize | No — rehashing moves live sessions | Low |
| `sessionAffinity: ClientIP` on the Service | No, and breaks entirely behind NAT or a shared egress | No | Lowest |
| Externalised session + event log (Redis) | **Yes** — any pod can serve any session and replay `Last-Event-ID` | **Yes** | Medium |
| Stateless server, no sessions (server returns no `Mcp-Session-Id`) | Trivially yes | Yes | Lowest, but forfeits resumability and server-initiated messages |

Architectural recommendation: externalise session state and the per-stream event log, keep
consistent hashing as a *latency* optimisation rather than a correctness requirement, and
verify correctness by killing the pod a session is pinned to during a long tool call. If
your server genuinely has no per-session state and no server-initiated messages, the
stateless mode is legitimate and simplest — do not build session infrastructure you do not
need.

`maxRequestsPerConnection: 0` (unlimited) and a long `idleTimeout` are both required: SSE
streams are long-lived and a connection-recycling policy will sever them mid-call.

### 5.4 Ingress with lifecycle-aware timeouts

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
spec:
  parentRefs:
    - name: external-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - mcp.example.internal
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      timeouts:
        # Must exceed the longest tool execution. A gateway timeout shorter
        # than MCP_TOOL_TIMEOUT_SECONDS produces the classic "always fails at
        # exactly 60s" symptom that no client-side setting can fix.
        request: 660s
        backendRequest: 660s
      backendRefs:
        - name: cluster-ops-mcp
          port: 80
          weight: 100
```

### 5.5 Network isolation

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: cluster-ops-mcp
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
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: mcp-session-store
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
        - ipBlock:
            cidr: 10.96.0.1/32
      ports:
        - protocol: TCP
          port: 443
```

The last egress rule is the point of the whole policy: an MCP server whose tools reach the
Kubernetes API should reach *only* the Kubernetes API. `openWorldHint: false` on a tool is
a hint to the model; this NetworkPolicy is the enforcement. If a tool's description says it
only reads cluster state, the network should make that true.

### 5.6 Observability: metrics and alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cluster-ops-mcp
  namespace: mcp-system
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cluster-ops-mcp
  namespaceSelector:
    matchNames:
      - mcp-system
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: mcp-tool-lifecycle
  namespace: mcp-system
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mcp.tool.lifecycle.recording
      interval: 30s
      rules:
        - record: mcp:tool_call_error_ratio:rate5m
          expr: |
            sum by (namespace, service, tool) (
              rate(mcp_tool_calls_total{outcome="tool_error"}[5m])
            )
            /
            clamp_min(
              sum by (namespace, service, tool) (
                rate(mcp_tool_calls_total[5m])
              ),
              0.001
            )
        - record: mcp:protocol_error_ratio:rate5m
          expr: |
            sum by (namespace, service, tool) (
              rate(mcp_tool_calls_total{outcome="protocol_error"}[5m])
            )
            /
            clamp_min(
              sum by (namespace, service, tool) (
                rate(mcp_tool_calls_total[5m])
              ),
              0.001
            )
        - record: mcp:tool_call_duration_p99:5m
          expr: |
            histogram_quantile(
              0.99,
              sum by (le, namespace, service, tool) (
                rate(mcp_tool_call_duration_seconds_bucket[5m])
              )
            )
    - name: mcp.tool.lifecycle.alerts
      rules:
        - alert: MCPToolProtocolErrorsHigh
          expr: |
            mcp:protocol_error_ratio:rate5m > 0.02
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Protocol errors on {{ $labels.tool }} exceed 2%"
            description: >-
              More than 2% of calls to {{ $labels.tool }} in
              {{ $labels.namespace }} return a JSON-RPC error rather than a
              tool result. The model cannot see these and cannot self-correct.
              Usual causes: a schema the model cannot satisfy, a tool
              description that does not match the schema, or exceptions
              escaping the handler and being coerced to -32603.
            runbook_url: "https://runbooks.example.com/mcp/protocol-errors"
        - alert: MCPToolCallsTimingOut
          expr: |
            sum by (namespace, service, tool) (
              rate(mcp_tool_calls_total{outcome="timeout"}[5m])
            ) > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Tool {{ $labels.tool }} is timing out"
            description: >-
              Check the three clocks: client timeout, server
              MCP_TOOL_TIMEOUT_SECONDS, and the gateway request timeout. A
              timeout floor at exactly 60s across every client indicates the
              gateway, not the server.
        - alert: MCPCancellationsWithoutAbort
          expr: |
            sum by (namespace, service, tool) (
              rate(mcp_cancellations_received_total[5m])
            )
            -
            sum by (namespace, service, tool) (
              rate(mcp_executions_aborted_total[5m])
            )
            > 0
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Cancellations are not aborting execution in {{ $labels.tool }}"
            description: >-
              The server received notifications/cancelled but the handler ran
              to completion. On a mutating tool this means side effects are
              applied after the client believed the call was aborted, and a
              client retry will double-apply them.
        - alert: MCPToolInFlightSaturation
          expr: |
            max by (namespace, service) (
              mcp_tool_calls_in_flight
              /
              mcp_tool_calls_max_concurrency
            ) > 0.9
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "MCP server near tool concurrency limit"
            description: >-
              New tools/call requests will queue or be rejected. CPU will look
              idle because the work is I/O bound; scale on
              mcp_tool_calls_in_flight, not CPU.
        - alert: MCPSessionsLostDuringCalls
          expr: |
            sum by (namespace, service) (
              rate(mcp_session_not_found_total[5m])
            ) > 0.01
          for: 10m
          labels:
            severity: warning
            annotations_note: "sessions returning 404 force clients to re-initialize"
          annotations:
            summary: "Clients are receiving 404 on Mcp-Session-Id"
            description: >-
              Sessions are being lost. If this correlates with pod restarts,
              session state is in-process and is not surviving rescheduling.
```

The `MCPCancellationsWithoutAbort` alert is unusual and worth building. It is the only
signal that distinguishes "we handle cancellation" from "we receive cancellation," and the
gap between those two is where duplicated side effects live.

### 5.7 Tracing the lifecycle end to end

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-mcp
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
          http:
            endpoint: "0.0.0.0:4318"
    processors:
      batch:
        timeout: 5s
        send_batch_size: 512
      memory_limiter:
        check_interval: 2s
        limit_percentage: 75
        spike_limit_percentage: 15
      attributes/redact_tool_arguments:
        actions:
          - key: mcp.tool.arguments
            action: delete
          - key: mcp.tool.result.text
            action: delete
      resource/mcp:
        attributes:
          - key: service.namespace
            value: mcp
            action: upsert
    exporters:
      otlp/tempo:
        endpoint: "tempo-distributor.observability.svc.cluster.local:4317"
        tls:
          insecure: true
      prometheus:
        endpoint: "0.0.0.0:8889"
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, attributes/redact_tool_arguments, resource/mcp, batch]
          exporters: [otlp/tempo]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, resource/mcp, batch]
          exporters: [prometheus]
```

The redaction processor is not optional. Tool arguments routinely contain namespace names,
ticket bodies, user identifiers and occasionally credentials the model copied from
somewhere it should not have. A tracing backend is not an appropriate store for them.

Span layout for one call, following the OpenTelemetry GenAI conventions:

```
Trace 4bf92f3577b34da6a3ce929d0e0e4736
│
├─ execute_tool scale_workload                              1.84s   [client host]
│    gen_ai.operation.name    = execute_tool
│    gen_ai.tool.name         = cluster-ops__scale_workload
│    gen_ai.tool.call.id      = call_9xKd2
│    mcp.request.id           = 42
│    mcp.server.name          = cluster-ops-mcp
│    mcp.session.id           = 1f5c8a2e-…
│    mcp.transport            = streamable-http
│
└──── mcp.tools/call scale_workload                         1.79s   [mcp server]
      │  mcp.method             = tools/call
      │  mcp.request.id         = 42
      │  mcp.tool.name          = scale_workload
      │  mcp.result.is_error    = false
      │
      ├─ hpa.lookup payments/api-hpa                        0.11s
      ├─ k8s.patch deployments/scale payments/api           1.42s
      │    http.response.status_code = 200
      └─ progress.emit ×3                                   0.01s
```

Propagate W3C `traceparent` as an HTTP header on Streamable HTTP. For stdio, there is no
header channel — carry it in `_meta` on the request, which is exactly what `_meta` is for.
Without this, a slow tool call is a black box and you will be reduced to correlating by
timestamp.

---

## 6. Verification and failure diagnosis

### 6.1 The verification ladder

Run these in order. Each rung assumes the ones below it pass.

**Rung 1 — the server speaks MCP at all.**

```
$ npx @modelcontextprotocol/inspector --cli \
    --transport http --server-url https://mcp.example.internal/mcp \
    --header "Authorization: Bearer $MCP_TOKEN" \
    --method tools/list | jq '.tools | length'
17
```

**Rung 2 — stdout is clean (stdio servers only).** The single most common stdio bug.

```
$ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | ./cluster-ops-mcp --transport stdio 2>/dev/null \
  | while IFS= read -r line; do
      printf '%s' "$line" | jq -e 'has("jsonrpc")' >/dev/null \
        || { echo "NON-MCP LINE ON STDOUT: $line"; exit 1; }
    done && echo "stdout clean"

stdout clean
```

**Rung 3 — every tool's schema is a schema the model can actually satisfy.**

```
$ npx @modelcontextprotocol/inspector --cli \
    --transport http --server-url https://mcp.example.internal/mcp \
    --header "Authorization: Bearer $MCP_TOKEN" \
    --method tools/list \
  | jq -r '.tools[] | select(
      (.description // "" | length) < 40
      or (.inputSchema.type != "object")
      or (.inputSchema.additionalProperties != false)
      or (.annotations.readOnlyHint == null)
    ) | .name'

restart_workload
purge_cache
```

Two tools flagged: they lack `additionalProperties: false` or an explicit `readOnlyHint`.
A missing `readOnlyHint` defaults to "not read-only," which is the safe default but pushes
every call through the per-call consent gate — usually not what the author intended.

**Rung 4 — errors land in the right channel.** Invoke a tool with arguments that must
fail, and check which channel carries the failure.

```
$ npx @modelcontextprotocol/inspector --cli \
    --transport http --server-url https://mcp.example.internal/mcp \
    --header "Authorization: Bearer $MCP_TOKEN" \
    --method tools/call --tool-name describe_workload \
    --tool-arg namespace=payments --tool-arg name=does-not-exist

{
  "content": [
    {
      "type": "text",
      "text": "No workload named 'does-not-exist' in namespace 'payments'. Closest matches: api, api-worker, api-scheduler. Call list_workloads with namespace=payments to enumerate."
    }
  ],
  "isError": true
}
```

Correct: `isError: true` inside a result, with a message the model can act on, including
the near-miss suggestions. Now the protocol-fault case:

```
$ npx @modelcontextprotocol/inspector --cli \
    --transport http --server-url https://mcp.example.internal/mcp \
    --header "Authorization: Bearer $MCP_TOKEN" \
    --method tools/call --tool-name totally_made_up

Error: MCP error -32602: Unknown tool: totally_made_up
```

Correct: a JSON-RPC error, because no schema-conformant invocation of a nonexistent tool
exists and the model cannot repair it by changing arguments.

**Rung 5 — progress and cancellation actually work.** This needs a real client, because
the CLI will not cancel for you.

```
$ python3 scripts/mcp_cancel_probe.py \
    --url https://mcp.example.internal/mcp \
    --tool drain_node --arg node=worker-9 \
    --cancel-after 2.0

14:31:02.118  → tools/call id=1 progressToken=probe-1
14:31:02.611  ← progress 1/4  Cordoning worker-9
14:31:04.118  → notifications/cancelled id=1 reason="probe"
14:31:04.119  [waiting 30s for any late response to id=1]
14:31:34.120  ✔ no response received for id=1   (spec-compliant)
14:31:34.121  [verifying side effects]
14:31:34.402  ✔ node worker-9 is cordoned       (phase 1 applied)
14:31:34.680  ✔ 0 evictions in progress          (phase 2 aborted)

VERDICT: cancellation honoured; partial side effects present as expected.
```

The verdict line is the honest one. Cancellation stopped further work; it did not undo
what had already happened. That is correct behaviour and it is why the tool's description
must tell the model that `drain_node` is resumable and that `uncordon_node` exists.

**Rung 6 — the lifecycle survives infrastructure.** Kill the pod serving a session
mid-call and confirm the client recovers.

```
$ kubectl -n mcp-system get pods -l app.kubernetes.io/name=cluster-ops-mcp -o wide
NAME                                READY   STATUS    RESTARTS   AGE    IP            NODE
cluster-ops-mcp-7d9f4c6b8d-4kq2n    1/1     Running   0          3h12m  10.244.2.31   worker-1
cluster-ops-mcp-7d9f4c6b8d-8vxlp    1/1     Running   0          3h12m  10.244.3.17   worker-2
cluster-ops-mcp-7d9f4c6b8d-mz7rt    1/1     Running   0          3h12m  10.244.1.44   worker-3

$ python3 scripts/mcp_resume_probe.py --url https://mcp.example.internal/mcp --tool slow_report &
[1] 48213

$ sleep 3 && kubectl -n mcp-system delete pod cluster-ops-mcp-7d9f4c6b8d-8vxlp
pod "cluster-ops-mcp-7d9f4c6b8d-8vxlp" deleted

$ wait %1
14:40:11.004  → tools/call id=1  (session 1f5c8a2e-…, pod 10.244.3.17)
14:40:11.552  ← progress 1/5  id=evt-0001
14:40:13.118  ✖ stream closed by peer
14:40:13.120  → GET /mcp  Last-Event-ID: evt-0001
14:40:13.402  ← progress 2/5  id=evt-0002   (pod 10.244.1.44)
14:40:19.887  ← result id=1  isError=false

VERDICT: session survived pod deletion; stream resumed from evt-0001 on a
         different pod; no duplicate events; no lost result.
```

If instead you see `HTTP 404` and a forced re-initialize, your session state is in-process
and the `mcp:session_not_found` alert will eventually page you at a worse time.

### 6.2 Failure decision tree

```
Tool call failed. Start here.
│
├─ Did the model receive ANY tool output?
│  │
│  ├─ NO ─────────────────────────────────────────────────────────┐
│  │                                                              │
│  │  ├─ Host logs show JSON-RPC error -32602?                    │
│  │  │    → Unknown tool name  → discovery/namespacing bug:      │
│  │  │      check pagination (nextCursor ignored?), check        │
│  │  │      prefixing, check listChanged cache staleness.        │
│  │  │    → Invalid params    → the model cannot satisfy the     │
│  │  │      schema. Read the description as the model sees it.   │
│  │  │      Usually: required field the description never        │
│  │  │      mentions, or an enum with unguessable values.        │
│  │  │                                                           │
│  │  ├─ JSON-RPC error -32603 Internal error?                    │
│  │  │    → An exception escaped the handler and the framework   │
│  │  │      coerced it. This is the #1 defect. Wrap the handler; │
│  │  │      convert to isError with an actionable message.       │
│  │  │                                                           │
│  │  ├─ Transport error / stream closed / ECONNRESET?            │
│  │  │    → Check the THREE clocks. Does it always fail at the   │
│  │  │      same round number of seconds across every client?    │
│  │  │      That is the gateway, not your code.                  │
│  │  │    → stdio: is anything writing to stdout? Run rung 2.    │
│  │  │    → HTTP: did the pod restart? kubectl get pods; check   │
│  │  │      terminationGracePeriodSeconds vs tool duration.      │
│  │  │                                                           │
│  │  ├─ HTTP 404 with Mcp-Session-Id present?                    │
│  │  │    → Session expired or the pod holding it is gone.       │
│  │  │      Client must re-initialize. Externalise session state.│
│  │  │                                                           │
│  │  ├─ HTTP 400 "unsupported protocol version"?                 │
│  │  │    → MCP-Protocol-Version header mismatch after a         │
│  │  │      server upgrade. Check the negotiated version from    │
│  │  │      initialize against what the client sends.            │
│  │  │                                                           │
│  │  ├─ HTTP 401 / 403?                                          │
│  │  │    → Authorization, not lifecycle. Check the token's      │
│  │  │      audience: a token minted for another service that    │
│  │  │      your server forwards upstream is the confused        │
│  │  │      deputy pattern and is forbidden.                     │
│  │  │                                                           │
│  │  └─ Nothing at all, call just hangs?                         │
│  │       → Server blocked on a nested request (sampling /       │
│  │         elicitation) the client never answers, or the client │
│  │         lacks that capability. Check initialize capabilities.│
│  │       → Concurrency limit reached: mcp_tool_calls_in_flight  │
│  │         at max. CPU will look idle. Scale on in-flight.      │
│  │                                                              │
│  └─ YES, it got a result ──────────────────────────────────────┘
│     │
│     ├─ isError: true, and the message is actionable?
│     │    → Working as designed. If the model still fails to
│     │      recover, the message is not naming the remedy tool.
│     │
│     ├─ isError: true with an opaque message ("Error", a stack
│     │  trace, a raw 500 body)?
│     │    → The channel is right, the payload is useless. Rewrite
│     │      for a reader with no log access.
│     │
│     ├─ isError: false but the content is wrong/empty?
│     │    → Tool returned success on a no-op. Distinguish "found
│     │      nothing" from "succeeded with nothing to report" in
│     │      the text; the model cannot tell them apart otherwise.
│     │
│     ├─ structuredContent missing while outputSchema declared?
│     │    → Spec violation. Client SHOULD reject. Fix the server.
│     │
│     └─ Result correct but the agent then did something wrong?
│          → Injection check: does the content contain text from
│            an untrusted third party (issue body, log line,
│            webhook)? Wrap it, label its provenance, and never
│            let it look like an instruction.
```

### 6.3 The diagnostic commands you will actually reach for

```
$ kubectl -n mcp-system logs -l app.kubernetes.io/name=cluster-ops-mcp \
    --since=15m --prefix \
  | grep -E '"mcp\.(request_id|tool)"' \
  | jq -rc 'select(.level=="error") | [.ts, .["mcp.tool"], .["mcp.request_id"], .msg] | @tsv'

2026-09-17T14:31:44Z  scale_workload   118  handler raised: KubeApiTimeout after 20.0s
2026-09-17T14:33:02Z  scale_workload   131  handler raised: KubeApiTimeout after 20.0s
2026-09-17T14:33:09Z  drain_node       134  cancellation received but handler not abortable
```

```
$ kubectl -n mcp-system exec deploy/cluster-ops-mcp -c server -- \
    wget -qO- http://localhost:9090/metrics \
  | grep -E '^mcp_(tool_calls_in_flight|tool_calls_total|cancellations|sessions_active)'

mcp_tool_calls_in_flight 14
mcp_tool_calls_max_concurrency 16
mcp_tool_calls_total{tool="list_workloads",outcome="ok"} 8412
mcp_tool_calls_total{tool="scale_workload",outcome="ok"} 219
mcp_tool_calls_total{tool="scale_workload",outcome="tool_error"} 31
mcp_tool_calls_total{tool="scale_workload",outcome="protocol_error"} 0
mcp_tool_calls_total{tool="scale_workload",outcome="timeout"} 7
mcp_cancellations_received_total{tool="drain_node"} 12
mcp_executions_aborted_total{tool="drain_node"} 4
mcp_sessions_active 63
```

Read that output as an SRE: `in_flight` is 14 of 16 — saturation is imminent and the HPA
should already be scaling. `scale_workload` has zero protocol errors, which means the
schema is satisfiable and the error handling is landing in the right channel. But
`cancellations_received` is 12 against `executions_aborted` of 4: eight cancellations ran
to completion anyway. On a mutating tool, that is the incident from section 1.1 waiting to
happen, and it is the highest-priority fix on this server.

### 6.4 Pre-production checklist

| # | Check | Passes when |
|---|---|---|
| 1 | Every tool has a description ≥ 40 chars naming preconditions and the remedy tools | Rung 3 returns empty |
| 2 | Every `inputSchema` is `type: object` with `additionalProperties: false` | Rung 3 returns empty |
| 3 | Every tool carries all four annotations explicitly | Rung 3 returns empty |
| 4 | No exception can escape a handler as `-32603` | Fault-injection suite shows `isError` for every injected fault |
| 5 | Mutating tools are declarative (set-state, not delta) or carry an idempotency mechanism | Design review |
| 6 | stdout carries only MCP frames (stdio) | Rung 2 |
| 7 | `progressToken` honoured; progress emitted at least every `MCP_TOOL_PROGRESS_INTERVAL_SECONDS` for tools > 30 s | Rung 5 |
| 8 | `notifications/cancelled` aborts execution; no response sent afterwards | Rung 5; `cancellations_received == executions_aborted` |
| 9 | Gateway timeout > server tool timeout > upstream timeout, and `terminationGracePeriodSeconds` > all of them | Manifest review + a long-tool rollout test |
| 10 | `Origin` validated; server not bound to `0.0.0.0` when local | Request with a forged `Origin` returns 403 |
| 11 | Session survives pod deletion | Rung 6 |
| 12 | Tool definitions fingerprinted; drift revokes consent | Change a description, confirm re-consent |
| 13 | Tool arguments and results redacted before leaving the trace pipeline | Collector config review + a trace inspection |
| 14 | Untrusted text in results is delimited and provenance-labelled | Injection test corpus |

---

## 7. Exam-focused summary

The claims most likely to be tested, stated without qualification:

- A tool that fails during execution returns a **successful JSON-RPC result** with
  `isError: true`, so the model can see and react. JSON-RPC `error` objects are for
  protocol-level faults the model cannot repair.
- Progress notifications require a client-supplied `progressToken` in the request's
  `_meta`. `progress` must increase; `total` is optional.
- Timeouts **MAY** be reset by progress notifications but there **SHOULD** always be a
  maximum.
- `notifications/cancelled` names a `requestId`; the receiver **SHOULD** stop work and
  **SHOULD NOT** send a response; `initialize` cannot be cancelled; races are expected and
  must be tolerated.
- Tool annotations are **hints**. Clients **MUST NOT** base security decisions on
  annotations from untrusted servers.
- Declaring `outputSchema` obliges the server to return conforming `structuredContent`,
  and clients **SHOULD** validate it.
- `notifications/tools/list_changed` requires the `tools.listChanged` capability and
  obliges the client to re-run `tools/list`.
- JSON-RPC batching was removed in revision 2025-06-18.
- Streamable HTTP clients must accept both `application/json` and `text/event-stream`, must
  send `MCP-Protocol-Version` after initialization, and must re-initialize on `404` for a
  session id.
- Tool invocation **SHOULD** be behind human approval, and servers **MUST NOT** use
  elicitation to request credentials.

---

## Referencias

- Model Context Protocol Associate (MCPA) — certification page, Linux Foundation:
  https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
- MCP specification — Server Tools (discovery, `tools/call`, results, error handling,
  annotations, structured output, security):
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- MCP specification — Lifecycle (initialization, capability negotiation, shutdown,
  timeouts): https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- MCP specification — Utilities: Progress:
  https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
- MCP specification — Utilities: Cancellation:
  https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation
- MCP specification — Transports (stdio, Streamable HTTP, sessions, resumability,
  `Origin` validation):
  https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- MCP specification — Client: Sampling:
  https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
- MCP specification — Client: Elicitation:
  https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- MCP specification — Authorization:
  https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- MCP specification — Security Best Practices (confused deputy, token passthrough,
  session hijacking):
  https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
- MCP specification — Revision history / changelog:
  https://modelcontextprotocol.io/specification/versioning
- MCP Inspector — developer tool:
  https://github.com/modelcontextprotocol/inspector
- JSON-RPC 2.0 Specification (error code ranges and semantics):
  https://www.jsonrpc.org/specification
- JSON Schema — Draft 2020-12 core and validation vocabularies:
  https://json-schema.org/draft/2020-12/release-notes
- Kubernetes — Pod lifecycle, termination and container hooks:
  https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes — Horizontal Pod Autoscaling:
  https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Network Policies:
  https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Gateway API — HTTPRoute timeouts:
  https://gateway-api.sigs.k8s.io/api-types/httproute/
- Istio — DestinationRule traffic policy and consistent hashing:
  https://istio.io/latest/docs/reference/config/networking/destination-rule/
- OpenTelemetry — Semantic conventions for generative AI agent and tool spans:
  https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/
- W3C — Trace Context recommendation:
  https://www.w3.org/TR/trace-context/
- HTML Living Standard — Server-Sent Events (`Last-Event-ID`, reconnection):
  https://html.spec.whatwg.org/multipage/server-sent-events.html
- Prometheus — Alerting rules and recording rules:
  https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/