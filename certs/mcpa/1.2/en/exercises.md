# Topic 1.2 — Core MCP Concepts

## Guided exercises

These exercises are built around one idea: **MCP is a wire protocol, not an SDK.** Everything the exam asks about — primitives, lifecycle, capabilities, transports — is observable as JSON on a pipe or a socket. So you will spend the first half of this lab talking to a real MCP server *by hand*, with `printf` and `curl`, before you let any convenience layer hide the frames from you.

You will build one server (`ops-copilot`, a small SRE assistant), drive it from three different clients (a shell, a Python client you write, and the Inspector), and over two transports.

**Time:** ~90 minutes. **Prerequisites:** Python 3.10+, Node.js 20+ (for the Inspector only), `jq`, `curl`.

> **A note on versions.** The protocol revision is a date string. This lab pins `2025-06-18` in every handshake so the outputs are reproducible. Before the exam, open <https://modelcontextprotocol.io/specification> and check which revision is current — what is examinable is the *negotiation mechanism*, not the date. Likewise, SDK helper names move between releases; the JSON they put on the wire is what you are being tested on.

---

## Exercise 0 — Lab setup

### Steps

1. Create the lab tree and a virtual environment:

```bash
mkdir -p ~/mcpa-lab/servers ~/mcpa-lab/clients && cd ~/mcpa-lab
python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet "mcp[cli]>=1.9" anyio
```

2. Record the exact versions you are running, so that later output differences are explainable rather than mysterious:

```bash
.venv/bin/python -c "import mcp, sys; print('mcp', mcp.__version__ if hasattr(mcp,'__version__') else 'n/a'); print('python', sys.version.split()[0])"
.venv/bin/pip show mcp | grep -E '^(Name|Version)'
```

Expected (your version numbers will differ):

```
Name: mcp
Version: 1.13.1
```

3. Confirm `jq` and `curl` are present:

```bash
jq --version && curl --version | head -1
```

### Check your understanding

**Q1.** The `mcp` Python package is one of several official SDKs (TypeScript, Python, Java, Kotlin, C#, Go, Rust…). If a Java client and a Python server interoperate correctly, what is the *only* thing they actually agree on? Name the two layers of that agreement.

**Q2.** You installed `mcp[cli]`, not plain `mcp`. Conceptually, what part of MCP is "the CLI" — is it part of the protocol, or something else?

---

## Exercise 1 — The wire: JSON-RPC 2.0 over stdio

MCP's base layer is JSON-RPC 2.0. Over the stdio transport, messages are **newline-delimited JSON on stdout/stdin** — one complete JSON object per line, no framing headers. This is the single most common point of confusion for people arriving from LSP, which uses `Content-Length:` headers.

### Steps

1. Create `servers/ops_server.py`:

```python
"""ops-copilot: a minimal but complete MCP server used for the MCPA 1.2 lab."""

from __future__ import annotations

import anyio
from mcp.server.fastmcp import Context, FastMCP

mcp = FastMCP(
    "ops-copilot",
    instructions=(
        "Read-only SRE assistant for the 'checkout' platform. "
        "Use get_service_status before proposing any remediation."
    ),
    host="127.0.0.1",
    port=8765,
)

# --- in-memory fixtures, so the lab has no external dependencies -------------

_SERVICES: dict[str, dict[str, object]] = {
    "checkout-api": {"replicas": 3, "ready": 3, "version": "2.14.0", "sli_ok": True},
    "payments-worker": {"replicas": 5, "ready": 4, "version": "1.9.3", "sli_ok": False},
}

_RUNBOOKS: dict[str, str] = {
    "checkout-api": "# Runbook: checkout-api\n\n1. Check /healthz\n2. Check upstream payments-worker\n",
    "payments-worker": "# Runbook: payments-worker\n\n1. Drain the queue\n2. Verify DLQ depth\n",
}


# --- TOOL: model-controlled ---------------------------------------------------

@mcp.tool()
def get_service_status(service: str) -> str:
    """Return the current rollout status of a service in the checkout platform."""
    svc = _SERVICES.get(service)
    if svc is None:
        raise ValueError(f"unknown service: {service}")
    return (
        f"{service}: {svc['ready']}/{svc['replicas']} ready, "
        f"version {svc['version']}, SLI {'ok' if svc['sli_ok'] else 'BREACHED'}"
    )


# --- RESOURCE: application-controlled ----------------------------------------

@mcp.resource("ops://services/index", mime_type="text/plain")
def services_index() -> str:
    """The list of services this server knows about."""
    return "\n".join(sorted(_SERVICES))


@mcp.resource("ops://runbook/{service}", mime_type="text/markdown")
def runbook(service: str) -> str:
    """The runbook for a given service."""
    if service not in _RUNBOOKS:
        raise ValueError(f"no runbook for: {service}")
    return _RUNBOOKS[service]


# --- PROMPT: user-controlled --------------------------------------------------

@mcp.prompt(title="Incident review")
def incident_review(service: str, severity: str = "SEV3") -> str:
    """A structured post-incident review starter for a given service."""
    return (
        f"You are running a blameless post-incident review for {service} ({severity}).\n"
        "Produce: timeline, contributing factors, detection gap, and two action items."
    )


if __name__ == "__main__":
    mcp.run()  # stdio transport by default
```

2. Now perform a complete handshake **by hand**. Do not use a client library:

```bash
cd ~/mcpa-lab
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"handshake-by-hand","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 1
} | .venv/bin/python servers/ops_server.py
```

Expected output — three lines, but only **two** of them are responses (elided, and re-wrapped here for width):

```
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{},"prompts":{"listChanged":false},"resources":{"subscribe":false,"listChanged":false},"tools":{"listChanged":false},"logging":{}},"serverInfo":{"name":"ops-copilot","version":"1.13.1"},"instructions":"Read-only SRE assistant …"}}
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"get_service_status","description":"Return the current rollout status …","inputSchema":{"properties":{"service":{"title":"Service","type":"string"}},"required":["service"],"title":"get_service_statusArguments","type":"object"}}]}}
```

3. Re-run it through `jq` so the structure is legible:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"handshake-by-hand","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c '{id, keys: (. | keys)}'
```

```
{"id":1,"keys":["id","jsonrpc","result"]}
{"id":2,"keys":["id","jsonrpc","result"]}
```

4. Break the handshake on purpose. Send a request **before** `initialize`:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/list"}'
  sleep 1
} | .venv/bin/python servers/ops_server.py
```

You get an error object rather than a result. The exact code and wording are SDK-specific (commonly `-32602`, "Received request before initialization was complete"); what matters is the **shape**:

```
{"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"Received request before initialization was complete"}}
```

### Check your understanding

**Q3.** Exactly one of the three messages you sent in step 2 produced no line of output. Which one, and why is that not a bug?

**Q4.** In the JSON-RPC layer, what is the structural difference between a *request* and a *notification*? Give the field that decides it.

**Q5.** The stdio transport says the server writes messages to stdout. Your server also has logging. Where must log lines go, and what breaks if a library prints a banner to stdout at import time?

**Q6.** A colleague ports a client from LSP and prepends `Content-Length: 214\r\n\r\n` to every message. The server hangs. Explain precisely why, in terms of the transport definition.

**Q7.** Can a JSON-RPC response carry both `result` and `error`? What does the `id` of a response have to equal, and what is the one legal `id` value that MCP forbids?

---

## Exercise 2 — Lifecycle and capability negotiation

The `initialize` exchange is not a greeting. It is a **negotiation with a required result**: both sides learn the protocol revision in force and the exact feature set the other side will honour for the rest of the connection.

### Steps

1. Ask for a protocol version the server cannot possibly support:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"time-traveller","version":"0.1.0"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c '.result.protocolVersion'
```

```
"2025-06-18"
```

The server did **not** error. It answered with a version it *does* support, and the decision to continue or disconnect is now the client's.

2. Extract just the negotiated capabilities from a normal handshake:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cap-probe","version":"0.1.0"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq '.result.capabilities'
```

```
{
  "experimental": {},
  "prompts": { "listChanged": false },
  "resources": { "subscribe": false, "listChanged": false },
  "tools": { "listChanged": false },
  "logging": {}
}
```

3. Now change the server so it declares a capability it previously did not. Delete (or comment out) the `@mcp.prompt()`-decorated `incident_review` function, re-run step 2, and diff the capability object:

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cap-probe","version":"0.1.0"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq '.result.capabilities | has("prompts")'
```

```
false
```

Restore the prompt before continuing.

4. A host application declares *its* capabilities in the same message. This is the config a host like Claude Desktop or an IDE would use to launch your server — note that this JSON describes **how to start the process**, not the protocol itself:

```json
{
  "mcpServers": {
    "ops-copilot": {
      "command": "/home/you/mcpa-lab/.venv/bin/python",
      "args": ["/home/you/mcpa-lab/servers/ops_server.py"],
      "env": { "OPS_ENV": "staging" }
    }
  }
}
```

### Check your understanding

**Q8.** Draw the lifecycle as a sequence: which side sends what, in what order, before the first `tools/list` is legal? Name all three phases.

**Q9.** In step 1 the server answered `2025-06-18` to a request for `1999-01-01`. State the rule the server followed, and state what the *client* is now obliged to do if it cannot speak `2025-06-18`.

**Q10.** `resources` came back as `{"subscribe": false, "listChanged": false}`. What are those two sub-capabilities each promising, and what must a well-behaved client refrain from doing given these values?

**Q11.** Your server advertises `tools` but not `sampling`. Why is that not an omission? Which direction does each capability describe?

**Q12.** A client sends `capabilities: {}` (as yours did all lab). What follows for a server that would like to ask the LLM a question mid-tool-call?

---

## Exercise 3 — The three server primitives and who controls them

MCP's server side exposes exactly three primitives, and the exam leans hard on the **control model** that distinguishes them:

| Primitive | Controlled by | Typical trigger |
|---|---|---|
| **Prompts** | the **user** | an explicit choice — slash command, menu item |
| **Resources** | the **application** (host) | the host decides what context to attach |
| **Tools** | the **model** | the LLM decides to invoke it during a turn |

### Steps

1. Build a reusable handshake prelude so you stop retyping it:

```bash
cat > clients/prelude.sh <<'EOF'
init_line() {
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab-shell","version":"0.1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}
EOF
chmod +x clients/prelude.sh
```

2. List resources and resource *templates* — they are two different methods:

```bash
cd ~/mcpa-lab && source clients/prelude.sh
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"resources/list"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"resources/templates/list"}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==2 or .id==3) | .result'
```

```
{"resources":[{"uri":"ops://services/index","name":"services_index","description":"The list of services this server knows about.","mimeType":"text/plain"}]}
{"resourceTemplates":[{"uriTemplate":"ops://runbook/{service}","name":"runbook","description":"The runbook for a given service.","mimeType":"text/markdown"}]}
```

3. Read a concrete resource and a template instantiation:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"ops://services/index"}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"ops://runbook/payments-worker"}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==3) | .result.contents[0]'
```

```
{"uri":"ops://runbook/payments-worker","mimeType":"text/markdown","text":"# Runbook: payments-worker\n\n1. Drain the queue\n2. Verify DLQ depth\n"}
```

4. Fetch a prompt. Note that `prompts/list` returns *arguments*, and `prompts/get` returns **messages**, not a string:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"prompts/list"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"incident_review","arguments":{"service":"payments-worker","severity":"SEV2"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==3) | .result.messages'
```

```
[{"role":"user","content":{"type":"text","text":"You are running a blameless post-incident review for payments-worker (SEV2).\nProduce: timeline, contributing factors, detection gap, and two action items."}}]
```

5. Call a tool:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_service_status","arguments":{"service":"checkout-api"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==2) | .result'
```

```
{"content":[{"type":"text","text":"checkout-api: 3/3 ready, version 2.14.0, SLI ok"}],"isError":false}
```

6. Compare the three list methods side by side:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"resources/list"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"prompts/list"}'
  sleep 1
} | .venv/bin/python servers/ops_server.py \
  | jq -r 'select(.id>=2) | .result | to_entries[0] | "\(.key): \(.value | length) item(s)"'
```

```
tools: 1 item(s)
resources: 1 item(s)
prompts: 1 item(s)
```

### Check your understanding

**Q13.** `resources/list` returned one entry, but the server clearly serves two runbooks. Why were the runbooks absent, and which method exposes them?

**Q14.** `ops://runbook/{service}` — what specification defines that `{service}` placeholder syntax, and what is the practical consequence for a client that wants to enumerate every runbook?

**Q15.** Both a resource read and a tool call can return the text of a runbook. State the design rule that decides which primitive should expose it in a production server. Consider side effects, caching, and who picks.

**Q16.** `prompts/get` returned a list of `messages` with a `role`. Why is a prompt a list of messages rather than a string, and what does this let a prompt author do that a plain template cannot?

**Q17.** A host wires all three primitives into its UI. Sketch where each one shows up: which becomes a slash command, which becomes an "@-mention"/attachment picker, and which is never shown to the user at all?

---

## Exercise 4 — Tool results: the two kinds of failure

This is the highest-yield distinction in the whole topic. A tool can fail in two structurally different ways, and conflating them is a real production bug: it makes the model unable to self-correct.

### Steps

1. Trigger a **protocol error** — call a tool that does not exist:

```bash
cd ~/mcpa-lab && source clients/prelude.sh
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nonexistent_tool","arguments":{}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==2)'
```

```
{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Unknown tool: nonexistent_tool"}}
```

2. Trigger a **tool execution error** — call a real tool with an argument it rejects at runtime:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_service_status","arguments":{"service":"ghost-service"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==2)'
```

```
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Error executing tool get_service_status: unknown service: ghost-service"}],"isError":true}}
```

Look carefully: **the second one is a `result`, not an `error`.** It succeeded at the protocol level and failed at the domain level.

3. Trigger a **schema validation error** — omit a required argument:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_service_status","arguments":{}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==2) | if .error then {kind:"protocol", code:.error.code} else {kind:"result", isError:.result.isError} end'
```

```
{"kind":"result","isError":true}
```

4. Add a tool with **structured output**. Insert this above the `if __name__` block in `servers/ops_server.py`:

```python
from pydantic import BaseModel, Field


class ErrorBudget(BaseModel):
    """Remaining error budget for a service over the current 28-day window."""

    service: str
    slo_target: float = Field(description="Objective as a ratio, e.g. 0.999")
    consumed_ratio: float = Field(description="Fraction of the budget already burnt")
    burn_rate_1h: float
    exhausted_in_hours: float | None = None


@mcp.tool()
def get_error_budget(service: str) -> ErrorBudget:
    """Compute the remaining error budget and current burn rate for a service."""
    if service not in _SERVICES:
        raise ValueError(f"unknown service: {service}")
    burn = 14.2 if not _SERVICES[service]["sli_ok"] else 0.4
    consumed = 0.87 if burn > 1 else 0.11
    return ErrorBudget(
        service=service,
        slo_target=0.999,
        consumed_ratio=consumed,
        burn_rate_1h=burn,
        exhausted_in_hours=round((1 - consumed) / burn * 28 * 24, 1) if burn > 1 else None,
    )
```

5. Inspect the declared output schema and the returned result:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_error_budget","arguments":{"service":"payments-worker"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py \
  | jq -c 'select(.id==2) | .result.tools[] | select(.name=="get_error_budget") | .outputSchema.required'
```

```
["service","slo_target","consumed_ratio","burn_rate_1h"]
```

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_error_budget","arguments":{"service":"payments-worker"}}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq 'select(.id==3) | .result'
```

```
{
  "content": [
    {
      "type": "text",
      "text": "{\"service\":\"payments-worker\",\"slo_target\":0.999,\"consumed_ratio\":0.87,\"burn_rate_1h\":14.2,\"exhausted_in_hours\":6.1}"
    }
  ],
  "structuredContent": {
    "service": "payments-worker",
    "slo_target": 0.999,
    "consumed_ratio": 0.87,
    "burn_rate_1h": 14.2,
    "exhausted_in_hours": 6.1
  },
  "isError": false
}
```

The same data appears twice, on purpose.

### Check your understanding

**Q18.** State the rule for choosing between a JSON-RPC `error` object and `isError: true` inside a `result`. Give one concrete example of each from a production server that shells out to `kubectl`.

**Q19.** A server author "cleans up" by converting every tool failure into a JSON-RPC `error` with code `-32603`. Describe the behavioural regression this causes in the model's turn.

**Q20.** In step 5, `structuredContent` and `content[0].text` carry the same payload. Why does the spec require the server to emit both? Which consumer reads which?

**Q21.** `exhausted_in_hours` is `float | None` and is absent from `required`. A client validates `structuredContent` against `outputSchema` and the tool returns `null` for it. Should validation pass? What does this tell you about modelling optional fields?

**Q22.** Besides `text`, name the other content block types a tool result may contain, and explain the difference between embedding a resource in a result and returning a link to one.

---

## Exercise 5 — Tool annotations are hints, not guarantees

### Steps

1. Add an annotated, genuinely destructive tool. Insert above the `if __name__` block:

```python
from mcp.types import ToolAnnotations


@mcp.tool(
    annotations=ToolAnnotations(
        title="Rolling restart",
        readOnlyHint=False,
        destructiveHint=True,
        idempotentHint=False,
        openWorldHint=False,
    )
)
async def rolling_restart(service: str, replicas: int, ctx: Context) -> str:
    """Restart the replicas of a service one at a time. Disruptive."""
    if service not in _SERVICES:
        raise ValueError(f"unknown service: {service}")
    for i in range(replicas):
        await ctx.report_progress(
            progress=i + 1, total=replicas, message=f"restarting replica {i + 1}/{replicas}"
        )
        await anyio.sleep(1)
    return f"restarted {replicas} replicas of {service}"
```

2. Also annotate the read-only tool. Change the `get_service_status` decorator to:

```python
@mcp.tool(
    annotations=ToolAnnotations(
        title="Service status", readOnlyHint=True, openWorldHint=False
    )
)
```

3. Read the annotations off the wire:

```bash
cd ~/mcpa-lab && source clients/prelude.sh
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 1
} | .venv/bin/python servers/ops_server.py \
  | jq -r 'select(.id==2) | .result.tools[] | "\(.name)\tro=\(.annotations.readOnlyHint // "unset")\tdestructive=\(.annotations.destructiveHint // "unset")"'
```

```
get_service_status	ro=true	destructive=unset
get_error_budget	ro=unset	destructive=unset
rolling_restart	ro=false	destructive=true
```

### Check your understanding

**Q23.** `get_error_budget` shows `ro=unset`. According to the spec's defaults, how should a client treat a tool whose `readOnlyHint` is absent — as read-only or as potentially mutating? Why is that the safe default?

**Q24.** The spec calls these *hints* and states explicitly that clients must not rely on them for security. Where does the trust boundary actually sit? Answer in terms of who wrote the server and who runs it.

**Q25.** `idempotentHint=False` on `rolling_restart`. What client behaviour does this specifically rule out, and how would that behaviour differ if it were `True`?

**Q26.** Write the one-sentence policy a host should implement from `destructiveHint=true`. Should it block the call, or do something else?

---

## Exercise 6 — Utilities: progress, logging, cancellation, pagination

These are the "cross-cutting" parts of the base protocol. They do not belong to any one primitive.

### Steps

1. Call the slow tool **without** a progress token, and time it:

```bash
cd ~/mcpa-lab && source clients/prelude.sh
time {
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rolling_restart","arguments":{"service":"checkout-api","replicas":3}}}'
  sleep 5
} | .venv/bin/python servers/ops_server.py | jq -c '.method // ("response id=" + (.id|tostring))'
```

```
response id=1
response id=2
```

Three seconds of silence, then one response. The client had nothing to show the user.

2. Now call it **with** a progress token, by adding `_meta.progressToken` to the request params:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rolling_restart","arguments":{"service":"checkout-api","replicas":3},"_meta":{"progressToken":"restart-1"}}}'
  sleep 5
} | .venv/bin/python servers/ops_server.py | jq -c 'if .method then {n:.method, p:.params.progress, t:.params.total, m:.params.message} else {resp:.id} end'
```

```
{"resp":1}
{"n":"notifications/progress","p":1,"t":3,"m":"restarting replica 1/3"}
{"n":"notifications/progress","p":2,"t":3,"m":"restarting replica 2/3"}
{"n":"notifications/progress","p":3,"t":3,"m":"restarting replica 3/3"}
{"resp":2}
```

Same tool, same code path — the only difference is that the client *opted in*.

3. Cancel an in-flight request. Send the call, wait, then send `notifications/cancelled`:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rolling_restart","arguments":{"service":"checkout-api","replicas":10},"_meta":{"progressToken":"restart-2"}}}'
  sleep 2.5
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"operator aborted the rollout"}}'
  sleep 3
} | .venv/bin/python servers/ops_server.py | jq -c 'if .method then .params.progress else {resp:.id} end'
```

```
{"resp":1}
1
2
3
```

Progress stops, and **no response with `id: 7` is ever emitted**.

4. Now send a cancellation with the id as a *string*:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rolling_restart","arguments":{"service":"checkout-api","replicas":6}}}'
  sleep 2
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"7","reason":"typed as a string"}}'
  sleep 6
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==7) | {resp:.id}'
```

```
{"resp":7}
```

The work ran to completion. The cancellation was silently ineffective.

5. Look for pagination on a list method:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==2) | {count: (.result.tools|length), nextCursor: (.result.nextCursor // null)}'
```

```
{"count":3,"nextCursor":null}
```

6. Send a cursor the server never issued:

```bash
{
  init_line
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"cursor":"page-2"}}'
  sleep 1
} | .venv/bin/python servers/ops_server.py | jq -c 'select(.id==2) | (.error // .result | keys)'
```

### Check your understanding

**Q27.** In step 1 and step 2 the server code was identical. State the rule governing when a server is permitted to emit `notifications/progress`.

**Q28.** `progress` must increase on every notification, but `total` is optional. What should a client render when `total` is absent, and why would a server legitimately omit it?

**Q29.** Step 3 produced no response for `id: 7`. Contrast this with returning `isError: true`. Why does the spec prefer silence here, and what must a client do with a late response that arrives anyway for a request it already cancelled?

**Q30.** Explain the step 4 failure in one sentence, in terms of JSON-RPC id semantics.

**Q31.** `nextCursor` was absent. What does its absence mean, and what would a correct client do differently if it were present? Name the one thing a client must never do with a cursor value.

**Q32.** Cancellation is a notification, not a request. Name the race condition this creates and say who is responsible for tolerating it.

---

## Exercise 7 — Client primitives: roots, sampling, elicitation

So far every request has flowed client → server. The client primitives invert that: the **server** issues requests to the **client**. This is what makes MCP bidirectional rather than a plain RPC API, and it is why the same JSON-RPC session carries both directions.

### Steps

1. Add three server-side features that exercise the client. Insert above the `if __name__` block in `servers/ops_server.py`:

```python
from mcp import types
from pydantic import BaseModel as _BaseModel


@mcp.tool()
async def list_workspace_roots(ctx: Context) -> str:
    """Report the filesystem roots the host has granted to this server."""
    result = await ctx.session.list_roots()
    if not result.roots:
        return "the client granted no roots"
    return "\n".join(f"{r.name or '(unnamed)'} -> {r.uri}" for r in result.roots)


@mcp.tool()
async def summarize_incident(raw_timeline: str, ctx: Context) -> str:
    """Summarise a raw incident timeline by asking the client's model to do it."""
    result = await ctx.session.create_message(
        messages=[
            types.SamplingMessage(
                role="user",
                content=types.TextContent(
                    type="text",
                    text=f"Summarise this incident timeline in three bullets:\n\n{raw_timeline}",
                ),
            )
        ],
        max_tokens=300,
        system_prompt="You are a terse SRE. No preamble.",
    )
    return result.content.text if result.content.type == "text" else "<non-text sampling result>"


class RestartApproval(_BaseModel):
    """Operator confirmation for a disruptive action."""

    confirm: bool
    change_ticket: str


@mcp.tool()
async def guarded_restart(service: str, ctx: Context) -> str:
    """Restart a service, but ask the human first via elicitation."""
    result = await ctx.elicit(
        message=f"Restart {service}? This drops in-flight requests.",
        schema=RestartApproval,
    )
    if result.action != "accept" or result.data is None:
        return f"aborted: operator responded '{result.action}'"
    if not result.data.confirm:
        return "aborted: operator declined at the confirmation field"
    return f"restarted {service} under change {result.data.change_ticket}"
```

2. Write a client that actually implements those three callbacks — `clients/full_client.py`:

```python
"""A client that declares roots, sampling and elicitation, so the server can use them."""

from __future__ import annotations

import asyncio

from mcp import ClientSession, StdioServerParameters, types
from mcp.client.stdio import stdio_client
from mcp.shared.context import RequestContext
from pydantic import FileUrl


async def list_roots_callback(ctx: RequestContext) -> types.ListRootsResult:
    """The host decides what the server is allowed to see. Here: two fixed roots."""
    return types.ListRootsResult(
        roots=[
            types.Root(uri=FileUrl("file:///srv/checkout-api"), name="checkout-api"),
            types.Root(uri=FileUrl("file:///srv/payments-worker"), name="payments-worker"),
        ]
    )


async def sampling_callback(
    ctx: RequestContext, params: types.CreateMessageRequestParams
) -> types.CreateMessageResult:
    """Stand-in for 'ask the host's LLM'. A real host inserts human approval here."""
    prompt = params.messages[0].content
    incoming = prompt.text if isinstance(prompt, types.TextContent) else "<non-text>"
    print(f"[client] server asked the model for a completion ({len(incoming)} chars)")
    return types.CreateMessageResult(
        role="assistant",
        content=types.TextContent(
            type="text",
            text="- 14:02 deploy 1.9.3\n- 14:09 DLQ depth alarm\n- 14:31 rollback complete",
        ),
        model="stub-model-0",
        stopReason="endTurn",
    )


async def elicitation_callback(
    ctx: RequestContext, params: types.ElicitRequestParams
) -> types.ElicitResult:
    """Stand-in for 'show the user a form'. Auto-accepts, for reproducibility."""
    print(f"[client] server is eliciting: {params.message}")
    print(f"[client] requested schema: {params.requestedSchema}")
    return types.ElicitResult(
        action="accept", content={"confirm": True, "change_ticket": "CHG-4471"}
    )


async def main() -> None:
    params = StdioServerParameters(command=".venv/bin/python", args=["servers/ops_server.py"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(
            read,
            write,
            list_roots_callback=list_roots_callback,
            sampling_callback=sampling_callback,
            elicitation_callback=elicitation_callback,
        ) as session:
            init = await session.initialize()
            print(f"[client] connected to {init.serverInfo.name} on {init.protocolVersion}")

            for name, args in (
                ("list_workspace_roots", {}),
                ("summarize_incident", {"raw_timeline": "14:02 deploy; 14:09 alarm; 14:31 rollback"}),
                ("guarded_restart", {"service": "payments-worker"}),
            ):
                result = await session.call_tool(name, args)
                block = result.content[0]
                text = block.text if isinstance(block, types.TextContent) else "<non-text>"
                print(f"\n=== {name} ===\n{text}")


if __name__ == "__main__":
    asyncio.run(main())
```

3. Run it from the lab root:

```bash
cd ~/mcpa-lab && .venv/bin/python clients/full_client.py
```

```
[client] connected to ops-copilot on 2025-06-18

=== list_workspace_roots ===
checkout-api -> file:///srv/checkout-api
payments-worker -> file:///srv/payments-worker
[client] server asked the model for a completion (78 chars)

=== summarize_incident ===
- 14:02 deploy 1.9.3
- 14:09 DLQ depth alarm
- 14:31 rollback complete
[client] server is eliciting: Restart payments-worker? This drops in-flight requests.
[client] requested schema: {'type': 'object', 'properties': {'confirm': {'title': 'Confirm', 'type': 'boolean'}, 'change_ticket': {'title': 'Change Ticket', 'type': 'string'}}, 'required': ['confirm', 'change_ticket']}

=== guarded_restart ===
restarted payments-worker under change CHG-4471
```

4. Now remove the capabilities and watch the same tools fail. Comment out `sampling_callback=...` and `list_roots_callback=...` in the `ClientSession(...)` construction, re-run, and observe:

```
=== list_workspace_roots ===
Error executing tool list_workspace_roots: Method not found
```

5. Prove that a declared capability is visible on the wire. Add this line right after `init = await session.initialize()` and re-run with the callbacks restored:

```python
            print("[client] my own declared capabilities were sent in `initialize`")
```

Then confirm from the server's side by capturing the client's `initialize` params — in a production server, that is what `ctx.session.client_params.capabilities` holds.

### Check your understanding

**Q33.** In step 4 the failure surfaced as a tool execution error rather than a crash. Trace the actual chain: which side sent `roots/list`, which side answered "Method not found", and why did the *tool* end up reporting it?

**Q34.** Sampling is the server asking the client's LLM to complete something. Name the two reasons the spec puts this on the client side rather than letting the server call an LLM API itself.

**Q35.** The spec says a host SHOULD put a human in the loop on sampling, in two places. Which two moments are those, and what is the risk each one mitigates?

**Q36.** Roots are a *client* capability, but the server is the one that benefits. What is the security property roots provide, and why is "the server just reads what it likes" not equivalent?

**Q37.** Your `RestartApproval` schema used only a `bool` and a `str`. The spec constrains elicitation schemas to flat objects of primitive types. Give the design reason, and say what a server must do instead if it needs nested or conditional input.

**Q38.** Elicitation has three possible actions: `accept`, `decline`, `cancel`. Your tool collapses two of them into one path. In a production server, why must `decline` and `cancel` be distinguishable, and what must a server never do with elicited data?

---

## Exercise 8 — Transports: stdio versus Streamable HTTP

### Steps

1. Create `servers/http_main.py`:

```python
"""Run the same ops-copilot server over the Streamable HTTP transport."""

from ops_server import mcp

if __name__ == "__main__":
    mcp.run(transport="streamable-http")
```

2. Start it, bound to loopback:

```bash
cd ~/mcpa-lab/servers && ../.venv/bin/python http_main.py
```

```
INFO:     Started server process [48213]
INFO:     Uvicorn running on http://127.0.0.1:8765 (Press CTRL+C to quit)
```

Leave it running; use a second terminal for the rest.

3. Initialize over HTTP and capture the session id. Note the `Accept` header carrying **two** media types:

```bash
cd ~/mcpa-lab
curl -sS -D /tmp/hdr.txt -o /tmp/body.txt http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-client","version":"0.1.0"}}}'
grep -iE '^(HTTP/|content-type|mcp-session-id)' /tmp/hdr.txt
cat /tmp/body.txt
```

```
HTTP/1.1 200 OK
content-type: text/event-stream
mcp-session-id: 6f2b1c8e4a7d4f1b9c0e5a3d7b6f8e21

event: message
data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{…},"serverInfo":{"name":"ops-copilot","version":"1.13.1"},"instructions":"…"}}
```

4. Store the session id and complete the handshake. The `initialized` notification has no response, so expect **202**:

```bash
SID=$(grep -i '^mcp-session-id:' /tmp/hdr.txt | tr -d '\r' | awk '{print $2}')
echo "session: $SID"
curl -sS -D- -o /dev/null http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SID" \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' | head -3
```

```
HTTP/1.1 202 Accepted
date: Thu, 17 Sep 2026 11:04:22 GMT
server: uvicorn
```

5. Call a tool over the session:

```bash
curl -sS http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SID" \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_service_status","arguments":{"service":"payments-worker"}}}' \
  | sed -n 's/^data: //p' | jq -c '.result.content[0].text'
```

```
"payments-worker: 4/5 ready, version 1.9.3, SLI BREACHED"
```

6. Break it three ways, and record each status code:

```bash
# (a) no session id
curl -sS -o /dev/null -w 'no-session: %{http_code}\n' http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'

# (b) incomplete Accept header
curl -sS -o /dev/null -w 'bad-accept: %{http_code}\n' http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/list"}'

# (c) a session id the server never issued
curl -sS -o /dev/null -w 'stale-session: %{http_code}\n' http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'Mcp-Session-Id: deadbeefdeadbeefdeadbeefdeadbeef' \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/list"}'
```

```
no-session: 400
bad-accept: 406
stale-session: 404
```

7. Open the server→client stream with `GET`, then terminate the session with `DELETE`:

```bash
timeout 3 curl -sS -N -D- http://127.0.0.1:8765/mcp \
  -H 'Accept: text/event-stream' \
  -H "Mcp-Session-Id: $SID" \
  -H 'MCP-Protocol-Version: 2025-06-18' | head -4

curl -sS -o /dev/null -w 'delete: %{http_code}\n' -X DELETE http://127.0.0.1:8765/mcp \
  -H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18'
```

```
HTTP/1.1 200 OK
cache-control: no-store, no-transform
content-type: text/event-stream
mcp-session-id: 6f2b1c8e4a7d4f1b9c0e5a3d7b6f8e21

delete: 200
```

8. Production hardening. If you ever run this as a service, it binds loopback and runs unprivileged — a remote MCP server on `0.0.0.0` with no `Origin` check is a DNS-rebinding target:

```ini
[Unit]
Description=ops-copilot MCP server (Streamable HTTP)
After=network-online.target

[Service]
Type=exec
User=mcp
Group=mcp
WorkingDirectory=/opt/ops-copilot/servers
ExecStart=/opt/ops-copilot/.venv/bin/python http_main.py
Environment=MCP_HOST=127.0.0.1
Environment=MCP_PORT=8765
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_UNIX
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### Check your understanding

**Q39.** In step 3 you POSTed one JSON-RPC request and got back `content-type: text/event-stream`. Why is a single response delivered as a stream, and under what circumstance would the same endpoint answer `application/json` instead?

**Q40.** Step 6(b) returned **406** for `Accept: application/json` alone. Explain what the server is protecting itself from by refusing the request outright rather than just answering with JSON.

**Q41.** 400, 404 and 406 in step 6 mean three different things. Map each to the client bug that causes it, and say which one a client should recover from by re-running `initialize`.

**Q42.** What is the `GET /mcp` stream *for*? Name two message kinds that can only reach the client that way when the client has no request in flight.

**Q43.** Compare stdio and Streamable HTTP on four axes: process lifetime, authentication, who can reach the server, and multi-client support. Which transport would you choose for a server that reads the developer's local git checkout, and why?

**Q44.** The `MCP-Protocol-Version` header appears on HTTP requests but there is no equivalent on stdio. Why does HTTP need it when the version was already negotiated in `initialize`?

**Q45.** stdio servers inherit the parent process's environment. State the supply-chain risk this creates for a server distributed as `npx some-package`, and one mitigation available at the host-config level.

---

## Exercise 9 — Inspector as a diagnostic instrument

### Steps

1. Stop the HTTP server (`Ctrl-C`) and launch the Inspector against the stdio server:

```bash
cd ~/mcpa-lab
npx @modelcontextprotocol/inspector .venv/bin/python servers/ops_server.py
```

It prints a URL with a pre-filled session token. Open it, click **Connect**, then walk the **Tools**, **Resources** and **Prompts** tabs. Watch the **History** pane on every click: every UI action is a JSON-RPC message you have already sent by hand.

2. Use the non-interactive CLI mode, which is what belongs in CI:

```bash
npx @modelcontextprotocol/inspector --cli .venv/bin/python servers/ops_server.py --method tools/list \
  | jq -r '.tools[] | .name'
```

```
get_service_status
get_error_budget
rolling_restart
list_workspace_roots
summarize_incident
guarded_restart
```

3. Call a tool through the CLI:

```bash
npx @modelcontextprotocol/inspector --cli .venv/bin/python servers/ops_server.py \
  --method tools/call --tool-name get_error_budget --tool-arg service=checkout-api \
  | jq -c '.structuredContent'
```

```
{"service":"checkout-api","slo_target":0.999,"consumed_ratio":0.11,"burn_rate_1h":0.4,"exhausted_in_hours":null}
```

4. Try `summarize_incident` from the Inspector UI and observe what happens in the **Sampling** tab.

### Check your understanding

**Q46.** In step 4, `summarize_incident` behaves differently in the Inspector than under your `full_client.py`. What does the Inspector do with an incoming `sampling/createMessage` request, and what does that tell you about the Inspector's role — is it a host?

**Q47.** You now have three ways to exercise the server: raw `printf`, `full_client.py`, and the Inspector. For each of these failures, pick the tool you would reach for first and justify it in one line: (a) a tool returns valid JSON that the model consistently misuses; (b) the server dies during `initialize`; (c) `resources/read` returns the wrong `mimeType`.

---

## Cleanup

```bash
cd ~/mcpa-lab
pkill -f 'servers/http_main.py' || true
```

---

## Sources

- Linux Foundation — *Model Context Protocol Associate (MCPA)* certification: <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>
- MCP specification index (check here for the current revision): <https://modelcontextprotocol.io/specification>
- Lifecycle, capability negotiation and version negotiation: <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- Transports (stdio and Streamable HTTP): <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- Server primitives — tools: <https://modelcontextprotocol.io/specification/2025-06-18/server/tools>
- Server primitives — resources: <https://modelcontextprotocol.io/specification/2025-06-18/server/resources>
- Server primitives — prompts: <https://modelcontextprotocol.io/specification/2025-06-18/server/prompts>
- Client primitives — sampling: <https://modelcontextprotocol.io/specification/2025-06-18/client/sampling>
- Client primitives — roots: <https://modelcontextprotocol.io/specification/2025-06-18/client/roots>
- Client primitives — elicitation: <https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation>
- JSON-RPC 2.0 specification: <https://www.jsonrpc.org/specification>
- URI Template (RFC 6570): <https://datatracker.ietf.org/doc/html/rfc6570>
- Official Python SDK: <https://github.com/modelcontextprotocol/python-sdk>
- MCP Inspector: <https://github.com/modelcontextprotocol/inspector>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A1.** They agree on (1) the **base protocol** — JSON-RPC 2.0 message shapes, lifecycle and capability negotiation — and (2) the **transport** framing that carries those messages (newline-delimited JSON over stdio, or HTTP POST/GET with SSE for Streamable HTTP). Nothing else is shared: no runtime, no serialization library, no object model. The SDKs are conveniences that happen to emit conformant frames; two conformant implementations in any languages interoperate.

**A2.** "The CLI" is not part of the protocol at all. `mcp[cli]` pulls in developer tooling (`mcp dev`, `mcp run`, Typer/Rich dependencies) for running and inspecting servers locally. This distinction matters for the exam: MCP has no command-line interface in its specification — it has methods, messages and transports.

### Exercise 1

**A3.** `notifications/initialized` produced no output. It is a **notification**, and JSON-RPC forbids responding to notifications. This is not an error condition and not a silent failure — the absence of a response *is* the correct behaviour.

**A4.** The presence of `id`. A request has an `id` and the receiver MUST eventually answer with a response carrying the same `id`. A notification has **no `id` field at all** and MUST NOT be answered. Note that `"id": null` is not the same as absent — it is a malformed MCP message.

**A5.** Logs must go to **stderr**, never stdout. Under stdio, stdout is the message channel and the client parses it line by line as JSON. A library that prints a banner, a progress bar, or a deprecation warning to stdout injects a non-JSON line into the stream, and most clients will fail the parse and tear down the connection. This is the single most common cause of "my MCP server won't connect" — and it often appears only after a dependency upgrade.

**A6.** The stdio transport defines messages as **newline-delimited JSON**: each message is exactly one line of UTF-8 JSON, terminated by `\n`, containing no embedded newlines. There is no header framing. The server's reader sees `Content-Length: 214` as a line and fails to parse it as JSON; depending on implementation it either errors or discards, and the actual message body never gets interpreted as a request — so no response ever comes and the client blocks. LSP uses `Content-Length` headers; MCP deliberately does not.

**A7.** No — a response carries `result` **or** `error`, never both, and never neither. The `id` must equal the `id` of the request it answers, with the same JSON type. MCP forbids `null` as an id (JSON-RPC 2.0 permits it for certain error cases; MCP tightens this), and an id must not be reused within a session by the same sender.

### Exercise 2

**A8.** Three phases:

1. **Initialization.** Client → `initialize` request, carrying `protocolVersion`, its own `capabilities`, and `clientInfo`. Server → `initialize` response, carrying the version it will actually use, its `capabilities`, `serverInfo`, and optional `instructions`. Client → `notifications/initialized`.
2. **Operation.** Normal request/response/notification traffic, restricted to the capabilities both sides negotiated.
3. **Shutdown.** No protocol-level message; it is transport-specific — closing stdin and waiting for exit on stdio, `DELETE` on the session endpoint for Streamable HTTP.

Before `notifications/initialized` is sent, the client should issue no requests other than pings, and the server should issue none other than pings and logging.

**A9.** The rule: if the server does not support the client's requested version, it **responds with the latest version it does support** rather than erroring. The negotiation is then resolved on the client side — if the client cannot speak the version the server offered, the client MUST disconnect. Version mismatch is not an error response; it is a counter-offer.

**A10.** `subscribe: false` means the server will not honour `resources/subscribe` — the client cannot register for `notifications/resources/updated` on individual resource URIs. `listChanged: false` means the server will never emit `notifications/resources/list_changed`, so the resource list is static for the session. A well-behaved client must therefore not call `resources/subscribe`, and must not wait for a list-changed notification before refreshing — if it wants freshness it has to poll `resources/list` itself.

**A11.** Capabilities are **directional**. Server capabilities (`tools`, `resources`, `prompts`, `logging`, `completions`) declare what the server offers to the client. Client capabilities (`sampling`, `roots`, `elicitation`) declare what the client offers to the server. A server never declares `sampling` because sampling is something it *consumes*, not something it provides.

**A12.** It cannot ask. With `capabilities: {}` the client has declared no `sampling` support, so the server MUST NOT send `sampling/createMessage`. If it does anyway, the client answers "Method not found" (`-32601`). A correct server inspects the negotiated client capabilities at initialization and either hides the sampling-dependent tool from `tools/list` entirely or degrades gracefully — it does not offer a tool it knows will fail.

### Exercise 3

**A13.** `resources/list` returns only **concrete, directly addressable resources**. The runbooks are exposed through a **resource template** (`ops://runbook/{service}`), which is a parameterised family, not an enumeration. Templates are returned by `resources/templates/list`, a separate method.

**A14.** RFC 6570 (URI Template). The practical consequence: a template is **not enumerable** by the client — there is no method that expands it into the set of valid URIs. If the client needs to know which runbooks exist, the server must provide that separately, which is exactly what `ops://services/index` does here. A common production pattern is to pair every template with a concrete index resource, or with a completion handler (`completion/complete`) so the host can offer argument autocompletion.

**A15.** Use a **resource** when the operation is a read with no side effects, is idempotent, is cacheable, and the *application* should choose whether to include it in context. Use a **tool** when the operation has side effects, when the arguments are open-ended enough that the model needs to decide them at inference time, or when the *model* should choose whether to invoke it. Fetching a runbook by name is a read of a stable document → resource. Searching runbooks by free-text query, or writing a postmortem back, → tool. Note the practical asymmetry: resources require host support to be useful at all, and several hosts implement tools far more completely than resources — so production servers often expose a read-only tool *in addition to* the resource, for reach.

**A16.** Because a prompt's job is to seed a **conversation**, not to produce a string. A message list lets the author supply multi-turn scaffolding — a user turn, a pre-filled assistant turn demonstrating the expected format, another user turn — and lets individual messages carry non-text content, including an embedded resource. That is not expressible in a flat template.

**A17.** Prompts surface as user-invoked affordances: slash commands, a "/" menu, a template picker — the user explicitly selects one. Resources surface as attachable context: an "@-mention" picker, a file-tree-like browser, a "add to context" list the application (or the user via the application) chooses from. Tools are normally invisible: they are injected into the model's tool list and invoked by the model mid-turn; the user typically sees only an approval prompt and the result, never a menu of them.

### Exercise 4

**A18.** A **JSON-RPC `error`** means the request could not be processed *as a protocol message*: the tool name is unknown, the params are malformed, the method does not exist, the server is not initialized. The model never sees this as a tool result — it is a client-level failure. **`isError: true` in a `result`** means the tool ran and the *operation* failed: the target does not exist, the API returned 503, the command exited non-zero. This is returned to the model as part of the conversation so it can adapt.

For a `kubectl` wrapper: calling `kubect1_get` (typo, no such tool) → JSON-RPC `-32602`. Calling `kubectl_get` with `namespace: "prod"` when the service account has no RBAC there → `isError: true` with the "Error from server (Forbidden)" text in `content`, so the model can try a namespace it is allowed to read.

**A19.** The model stops being able to self-correct. Tool execution errors returned as `isError: true` are handed back into the model's context as the tool's output, so the model sees "unknown service: ghost-service" and retries with a valid name. Converted to a JSON-RPC `error`, the failure is intercepted by the client's transport layer; depending on the host, the model either sees nothing, sees a generic "the tool call failed", or the turn aborts. Retry loops that previously converged now dead-end, and the user gets "I was unable to complete that" instead of an answer.

**A20.** They serve two different consumers. `content` is the **unstructured, human- and model-readable** rendering — it is what gets put in the model's context and what a host displays. `structuredContent` is the **machine-readable** payload that a client validates against the tool's `outputSchema` and that downstream code can consume programmatically without parsing prose. The spec requires backwards-compatible servers to emit both so that clients predating structured output still work, and the serialized JSON in `content` is the conventional way to do that.

**A21.** Validation should **pass**. `exhausted_in_hours` is typed `float | None`, which the schema expresses as a union including `"null"`; it is optional in the sense of not being in `required`, but an explicit `null` is a valid value of its declared type. The lesson: "absent" and "present but null" are different in JSON Schema, and you must decide which you mean. If a field should be omitted when unknown, exclude nulls at serialization time; if it should be present-and-null, make sure the schema's type union admits `null`. Clients that validate strictly will reject the mismatch, and this is a common interop failure.

**A22.** Besides `text`: **`image`** and **`audio`** (both base64 `data` plus `mimeType`), **`resource_link`** (a `uri` pointing at a resource the client may fetch later), and **`resource`** (an *embedded* resource, with its `uri`, `mimeType` and inline `text` or `blob`). The difference: an embedded resource ships the bytes inside the result — self-contained, costs context immediately, guaranteed available. A `resource_link` ships only the pointer — cheap, lets the host decide whether to spend context on it, but the client must be able and permitted to read that URI, and the content may have changed by the time it does.

### Exercise 5

**A23.** As **potentially mutating**. All annotation hints default conservatively: an absent `readOnlyHint` must be treated as `false`. The safe default matters because annotations drive consent UX — if an unannotated tool were assumed read-only, every server that simply never set annotations would bypass the host's confirmation prompts.

**A24.** The trust boundary is between the **host** and the **server**, and annotations are on the untrusted side of it. They are metadata the *server author* wrote about their own tool; a malicious or merely careless server can label a `DROP TABLE` wrapper `readOnlyHint: true`. They exist to let an honest server give the host better UX, not to let the host make a security decision. Real enforcement has to come from somewhere the host controls: sandboxing, credentials scoped at issuance, network policy, and human approval.

**A25.** `idempotentHint: false` rules out **automatic retry**. A client that would otherwise re-issue a timed-out or failed call must not, because a second rolling restart is a second real outage. With `idempotentHint: true`, repeating the call with identical arguments has no additional effect, so a client may safely retry on transport failure or ambiguous timeout.

**A26.** *"A tool with `destructiveHint: true` requires explicit, per-invocation human confirmation showing the tool name and the exact arguments, and must not be eligible for auto-approval or 'always allow' for the session."* Not blocked — surfaced. Blocking would make the tool useless; the point is to move the decision to the human with enough information to make it.

### Exercise 6

**A27.** A server may send `notifications/progress` **only if the original request included a `progressToken` in its `params._meta`**, and each notification must carry that same token. No token means the client did not ask for progress, and unsolicited progress notifications have nothing to correlate against. The opt-in is per request, not per session or per capability.

**A28.** With no `total`, the client must render **indeterminate** progress — a spinner or an activity indicator — not a percentage bar, since `progress` is an unbounded increasing number with no denominator. Servers legitimately omit `total` when the work size is unknown in advance: streaming a log until EOF, paginating an upstream API that does not report a count, crawling until a condition is met. Fabricating a `total` to get a nicer bar produces a progress bar that jumps or stalls at 99%.

**A29.** Silence is correct because the request was **cancelled, not answered** — there is no result, not even a failed one, and `isError: true` would be a lie: it would tell the model the operation was attempted and failed, when in fact it was aborted by the operator and may have partially completed. A client that receives a late response for a request it already cancelled must **ignore it**: the race is expected, since the cancellation and the response can cross on the wire.

**A30.** JSON-RPC ids are typed, and `"7"` (string) is not the same id as `7` (number), so the server found no in-flight request matching the cancellation and — correctly, since cancellations for unknown ids must be ignored — did nothing.

**A31.** Absence of `nextCursor` means **this is the last page**; the client has the complete list and must stop. If present, the client repeats the same method with `params.cursor` set to that exact value and concatenates results until `nextCursor` is absent. The thing a client must never do is **interpret the cursor**: it is an opaque token. Parsing it, decoding it, incrementing it, or persisting it across sessions are all invalid — the server may encode an offset, a keyset, a snapshot id, or an encrypted blob, and it may change the encoding at any time.

**A32.** The race: the response to the request may already be in flight, or the request may already have completed, when the cancellation arrives. Both sides must tolerate it — the **receiver** of the cancellation must ignore it if the id is unknown or already finished, and the **sender** must ignore a response that arrives after it cancelled. Neither may treat the situation as an error. The corollary for tool authors: cancellation does not roll anything back, so a partially-completed side-effecting tool leaves partial state behind.

### Exercise 7

**A33.** The **server** sent `roots/list` to the client (server → client direction). The client's `ClientSession`, with no `list_roots_callback` registered and therefore no `roots` capability declared, answered with JSON-RPC error `-32601` "Method not found". Inside the server, that error surfaced as an exception raised by `ctx.session.list_roots()` in the body of `list_workspace_roots`; FastMCP caught the exception at the tool boundary and converted it to a tool result with `isError: true`. So a *client-side* protocol error was correctly re-expressed as a *tool-level* failure — which is right, because from the model's point of view the tool is what failed.

**A34.** First, **credentials and cost**: the server would otherwise need its own API key, its own billing relationship and its own model choice; sampling lets the server borrow the host's existing model access, so a server ships with no secrets. Second, **control and consent**: the host owns the conversation, the context window, the model selection policy and the user relationship. Putting completion on the client side keeps the human in the loop and prevents a server from silently driving an LLM on the user's account.

**A35.** (1) Before the request is sent to the model — the user should be able to see and edit the prompt the server wants to send, and refuse it. (2) Before the completion is returned to the server — the user should be able to see and edit what is being handed back. The first mitigates prompt injection and data exfiltration through the prompt (a server crafting a prompt that extracts context it was never given). The second mitigates the server using the user's model as a general-purpose oracle and receiving content the user would not have released.

**A36.** Roots provide **explicit, host-granted scope**: the server learns which filesystem or URI boundaries it is authorised to operate within, and the host can enforce that boundary independently. "The server just reads what it likes" is not equivalent because a stdio server runs as the user with the user's full filesystem access — there is no technical boundary at all. Roots make the intended boundary *declarative* and *negotiated*, so the host can both inform the server and enforce it, and the user can see and change the grant. Note that roots are a coordination mechanism: a server that ignores them is not stopped by the protocol, only by whatever sandboxing the host applies.

**A37.** The constraint exists so that **any host can render the request as a form** without implementing a JSON Schema UI engine. A flat object of strings, numbers, booleans and enums maps to text inputs, number inputs, checkboxes and dropdowns — a host can support elicitation completely in a few dozen lines. Nested or conditional schemas would make full support a research project and partial support a compatibility minefield. If a server needs complex input, it must decompose it: several sequential elicitations, each flat, branching on the previous answer.

**A38.** `decline` means the user considered the request and said no — a deliberate answer. `cancel` means the user dismissed the interaction without answering — closed the dialog, hit Escape, navigated away. A server should treat `decline` as a final negative (do not re-ask; possibly tell the model the user refused) and `cancel` as "no decision was made" (it may be reasonable to re-prompt later, or to report that the operation is still pending). Collapsing them produces servers that nag after an explicit refusal, or that give up permanently on an accidental dismissal. What a server must **never** do is use elicitation to request sensitive credentials — passwords, API keys, tokens. The spec prohibits it, and the reason is that a form rendered by the host on behalf of an arbitrary server is an ideal phishing surface.

### Exercise 8

**A39.** Because Streamable HTTP lets a server answer a POST with *more than one message*: progress notifications, logging, and server-initiated requests such as `sampling/createMessage` or `elicitation/create` all have to reach the client while the original request is still being processed. SSE is the mechanism for that, so the server opens a stream, writes whatever it needs, and ends with the response. The server **may** reply `application/json` with a single body instead when it knows there is nothing else to send — which is why the client must accept both and must not hard-code either.

**A40.** The server refuses because it cannot know in advance whether it will need the stream. If it accepted `Accept: application/json` and then a tool turned out to need elicitation or wanted to emit progress, it would have no channel to deliver those messages and would have to fail mid-request or silently drop them. Rejecting at the header check turns an unpredictable runtime failure into a deterministic, immediately diagnosable one — `406 Not Acceptable` at connect time, with no side effects performed.

**A41.**
- **400 Bad Request** — the client omitted `Mcp-Session-Id` on a session-bearing server. Client bug: it did not capture the header from the `initialize` response. Not recoverable by retry; fix the client.
- **404 Not Found** — the session id is unknown or expired (server restart, idle timeout, prior `DELETE`). This is the one where the client **must start a new session**: re-run `initialize`, capture the new id, and replay. A client that retries the same id forever after a server restart is the classic bug here.
- **406 Not Acceptable** — the `Accept` header did not include both `application/json` and `text/event-stream`. Client bug, fix the header.

**A42.** The `GET /mcp` stream is the **server→client channel for unsolicited messages** — anything the server wants to send when there is no open POST to attach it to. Two kinds that need it: server-initiated **requests** (`sampling/createMessage`, `elicitation/create`, `roots/list`) triggered by something other than the current call, and **notifications** such as `notifications/tools/list_changed`, `notifications/resources/updated` or `notifications/message`. Without the GET stream, a stateful HTTP server can only talk when spoken to.

**A43.**

| | stdio | Streamable HTTP |
|---|---|---|
| Process lifetime | Child of the host; dies with it; one process per client | Independent service; outlives any client |
| Authentication | Implicit — same user, same machine, inherited env | Explicit — the spec defines OAuth 2.1 for HTTP-based transports |
| Reachability | Local only, via pipes; not addressable | Network-addressable; needs `Origin` validation and loopback binding in dev |
| Multi-client | One client per process | Many concurrent clients, distinguished by session id |

For a server that reads the developer's local git checkout: **stdio**. The data never leaves the machine, the server inherits exactly the developer's own filesystem permissions so there is no separate authorization model to build, there is no port to expose or authenticate, and lifetime tied to the editor is the correct semantics. Choosing HTTP there would mean building auth and access control to re-derive a property stdio gives for free.

**A44.** Because HTTP is stateless per request and requests can be routed independently — through a proxy, a load balancer, or to a different backend instance than the one that handled `initialize`. The header carries the negotiated version forward so that any receiving component can interpret the message correctly without having seen the handshake. Over stdio there is a single persistent connection to a single process that performed the handshake itself, so there is nothing to re-establish. (A server receiving an HTTP request with no `MCP-Protocol-Version` after the handshake should assume `2025-03-26` for backwards compatibility.)

**A45.** The server process inherits the host's entire environment, which on a developer machine routinely includes `AWS_*`, `GITHUB_TOKEN`, `KUBECONFIG`, `OPENAI_API_KEY` and SSH agent sockets — so a compromised or typosquatted `npx` package gets all of it on first run, plus arbitrary code execution as the user, with no install step to audit. Mitigations at the host-config level: pin exact versions rather than floating tags (`some-package@1.4.2`, and prefer a lockfile or a vendored install over `npx`), and use the config's `env` block to pass an explicit minimal environment rather than relying on inheritance. Beyond the config, run the server in a container or sandbox with only the mounts it needs.

### Exercise 9

**A46.** The Inspector intercepts `sampling/createMessage` and **shows it to you for manual handling** — it displays the prompt the server wants completed and lets you type a response by hand, rather than calling a model. This tells you the Inspector is a **debugging client, not a host**: it implements the client half of the protocol faithfully so you can exercise a server, but it has no model, no conversation, and no agent loop. It is the right tool for asking "does my server speak the protocol correctly", and the wrong tool for asking "does the model use my tool well".

**A47.**
- **(a) the model misuses valid JSON** — none of these three; this is not a protocol problem. The Inspector will show a perfectly valid result. The fix is in the tool's `description`, its `inputSchema` field descriptions, and its output shape, and you evaluate it in a real host with a real model. That the Inspector shows nothing wrong is itself the diagnostic.
- **(b) the server dies during `initialize`** — raw `printf` into stdio. It is the only one that shows you the exact bytes on both sides with nothing in between; stray stdout output and malformed `initialize` params are both immediately visible, and there is no client library to misattribute the failure.
- **(c) wrong `mimeType` on `resources/read`** — the Inspector. It renders resources and shows the raw response side by side, so a `text/plain` that should be `text/markdown` is one click to confirm, and the History pane gives you the exact JSON to paste into a bug report.

</details>