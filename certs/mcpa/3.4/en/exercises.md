# Topic 3.4 — Protocol Primitives

## Guided exercises

**Exam weight:** 6.5 · **Certification:** Model Context Protocol Associate (MCPA), exam version 2026-07-28 · **Reference syllabus:** <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>

### What you will be able to do at the end

- Name the three **server primitives** (`tools`, `resources`, `prompts`) and the three **client primitives** (`roots`, `sampling`, `elicitation`), and state who controls each one.
- Read and write the raw JSON-RPC 2.0 messages for every primitive, without an SDK in the way.
- Explain why a failing tool returns `isError: true` inside a **successful** JSON-RPC response, and when a JSON-RPC `error` is the correct answer instead.
- Diagnose the failure modes that an SDK normally hides: undeclared capabilities, opaque cursors, unpaginated listings, `resources/templates/list` invisibility, and stdout pollution on the stdio transport.

### Prerequisites

- Python 3.12 (standard library only — **no dependencies are installed in this lab**).
- `jq` for reading the wire, and Node.js if you want to run the official MCP Inspector.
- Working knowledge of JSON-RPC 2.0 (<https://www.jsonrpc.org/specification>) and of the MCP lifecycle (`initialize` → `notifications/initialized` → operation → shutdown).

Specification pages used throughout, all under `https://modelcontextprotocol.io/specification/2025-06-18/`:
`basic/lifecycle`, `basic/transports`, `server/tools`, `server/resources`, `server/prompts`, `server/utilities/completion`, `server/utilities/logging`, `client/roots`, `client/sampling`, `client/elicitation`, `basic/utilities/pagination`, `basic/utilities/progress`, `basic/utilities/cancellation`.

> **Why we hand-write the server.** Every MCP SDK generates these messages for you and validates them on the way in and out. That is the right thing in production and the wrong thing while you are learning the primitives, because the field that the exam asks about is the field the SDK filled in silently. This lab writes the JSON itself, so the wire *is* the curriculum.

---

## Exercise 0 — Build the lab

### Steps

1. Create the lab directory and confirm the toolchain:

```bash
mkdir -p ~/mcp-primitives-lab && cd ~/mcp-primitives-lab
python3 --version
jq --version
```

2. Create `primitives_server.py` with the following content. This one file implements all six server-side surfaces you will probe: tools (with pagination, structured output, annotations, resource links, progress and logging), resources (direct, templated and subscribable), prompts, and argument completion. It also *calls back* into the client to exercise `roots/list`, `sampling/createMessage` and `elicitation/create`.

```python
#!/usr/bin/env python3
"""primitives_server.py - a dependency-free MCP server over stdio.

Every message is written by hand so that each protocol primitive is visible on
the wire. Single-threaded, no auth, no persistence: a lab instrument, not a
production server.
"""

import base64
import json
import sys

PROTOCOL_VERSION = "2025-06-18"
PAGE_SIZE = 3

SERVER_INFO = {
    "name": "primitives-lab",
    "title": "Protocol Primitives Lab",
    "version": "0.1.0",
}

# A capability that is not declared here MUST NOT be used during the session.
SERVER_CAPABILITIES = {
    "tools": {"listChanged": True},
    "resources": {"subscribe": True, "listChanged": True},
    "prompts": {"listChanged": True},
    "completions": {},
    "logging": {},
}

TOOLS = [
    {
        "name": "sum_series",
        "title": "Sum a numeric series",
        "description": "Adds a list of numbers and reports how many were added.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "values": {"type": "array", "items": {"type": "number"}},
            },
            "required": ["values"],
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "total": {"type": "number"},
                "count": {"type": "integer"},
            },
            "required": ["total", "count"],
        },
        "annotations": {
            "readOnlyHint": True,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "restart_service",
        "title": "Restart a systemd unit",
        "description": "Restarts a unit on the lab host. Stubbed: changes nothing real.",
        "inputSchema": {
            "type": "object",
            "properties": {"unit": {"type": "string"}},
            "required": ["unit"],
        },
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": True,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
    {
        "name": "open_incident",
        "title": "Open an incident record",
        "description": "Creates an incident and returns a link to its resource.",
        "inputSchema": {
            "type": "object",
            "properties": {"summary": {"type": "string"}},
            "required": ["summary"],
        },
    },
    {
        "name": "draft_summary",
        "title": "Draft an incident summary",
        "description": "Asks the client's model to summarise an incident.",
        "inputSchema": {
            "type": "object",
            "properties": {"incident_id": {"type": "string"}},
            "required": ["incident_id"],
        },
    },
    {
        "name": "show_roots",
        "title": "Show the client's roots",
        "description": "Lists the filesystem boundaries the client exposed.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "slow_scan",
        "title": "Scan hosts slowly",
        "description": "Emits progress and log notifications while it works.",
        "inputSchema": {
            "type": "object",
            "properties": {"steps": {"type": "integer", "minimum": 1, "maximum": 10}},
        },
    },
]

RESOURCES = {
    "file:///lab/runbooks/oncall.md": {
        "name": "oncall-runbook",
        "title": "On-call runbook",
        "description": "Escalation path for the lab cluster.",
        "mimeType": "text/markdown",
        "text": "# On-call\n\n1. Check the dashboard.\n2. Page the secondary after 15 minutes.\n",
        "annotations": {"audience": ["user", "assistant"], "priority": 0.8},
    },
    "lab://metrics/cpu": {
        "name": "cpu-utilisation",
        "title": "CPU utilisation",
        "description": "Busy ratio of the lab node, 0.0 to 1.0.",
        "mimeType": "text/plain",
        "text": "cpu_busy_ratio 0.41\n",
        "annotations": {"audience": ["assistant"], "priority": 0.3},
    },
}

# RFC 6570 URI templates. These are NOT returned by resources/list.
RESOURCE_TEMPLATES = [
    {
        "uriTemplate": "lab://incident/{id}",
        "name": "incident",
        "title": "Incident record",
        "description": "One incident, by numeric id.",
        "mimeType": "application/json",
    },
]

PROMPTS = [
    {
        "name": "postmortem",
        "title": "Draft a postmortem",
        "description": "Builds a postmortem request with the runbook attached.",
        "arguments": [
            {
                "name": "incident_id",
                "description": "Numeric incident id, for example 77.",
                "required": True,
            },
            {
                "name": "tone",
                "description": "blameless | terse | executive",
                "required": False,
            },
        ],
    },
]

SUBSCRIPTIONS = set()
CLIENT_CAPABILITIES = {}
LOG_LEVELS = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
LOG_LEVEL = "info"
_next_server_id = 1
_pending = []


def send(message):
    """stdout carries protocol messages only - one JSON object per line."""
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def trace(text):
    """Diagnostics go to stderr. Writing them to stdout corrupts the session."""
    print(text, file=sys.stderr, flush=True)


def reply(rid, result):
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def fail(rid, code, message, data=None):
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    send({"jsonrpc": "2.0", "id": rid, "error": error})


def notify(method, params=None):
    message = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        message["params"] = params
    send(message)


def next_message():
    """Read one message straight from stdin. None at EOF."""
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            fail(None, -32700, "Parse error")


def read_message():
    if _pending:
        return _pending.pop(0)
    return next_message()


def call_client(method, params):
    """Server-initiated request. Ids are per-sender, so ours are namespaced."""
    global _next_server_id
    rid = "s%d" % _next_server_id
    _next_server_id += 1
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    while True:
        message = next_message()
        if message is None:
            return None
        if message.get("id") == rid and "method" not in message:
            return message
        _pending.append(message)


def encode_cursor(offset):
    return base64.urlsafe_b64encode(("offset:%d" % offset).encode()).decode()


def decode_cursor(cursor):
    try:
        raw = base64.urlsafe_b64decode(cursor.encode()).decode()
        return int(raw.split(":", 1)[1])
    except Exception:
        return None


def h_initialize(rid, params):
    global CLIENT_CAPABILITIES
    CLIENT_CAPABILITIES = params.get("capabilities") or {}
    trace("client asked for protocolVersion=%s" % params.get("protocolVersion"))
    trace("client capabilities: %s" % json.dumps(CLIENT_CAPABILITIES))
    reply(rid, {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": SERVER_CAPABILITIES,
        "serverInfo": SERVER_INFO,
        "instructions": "Lab server. Read lab://metrics/cpu before restarting anything.",
    })


def h_ping(rid, params):
    reply(rid, {})


def h_tools_list(rid, params):
    cursor = params.get("cursor")
    offset = 0
    if cursor is not None:
        offset = decode_cursor(cursor)
        if offset is None:
            fail(rid, -32602, "Invalid cursor", {"cursor": cursor})
            return
    page = TOOLS[offset:offset + PAGE_SIZE]
    result = {"tools": page}
    if offset + PAGE_SIZE < len(TOOLS):
        result["nextCursor"] = encode_cursor(offset + PAGE_SIZE)
    reply(rid, result)


def t_sum_series(rid, args, token):
    values = args.get("values")
    numeric = isinstance(values, list) and all(
        isinstance(v, (int, float)) and not isinstance(v, bool) for v in values
    )
    if not numeric:
        # The tool ran and rejected its input: in-band error, so the model sees it.
        reply(rid, {
            "content": [{"type": "text", "text": "values must be an array of numbers"}],
            "isError": True,
        })
        return
    payload = {"total": sum(values), "count": len(values)}
    reply(rid, {
        "content": [{"type": "text", "text": json.dumps(payload)}],
        "structuredContent": payload,
    })


def t_restart_service(rid, args, token):
    unit = args.get("unit", "")
    if "elicitation" in CLIENT_CAPABILITIES:
        response = call_client("elicitation/create", {
            "message": "Restart %s on the lab host?" % unit,
            "requestedSchema": {
                "type": "object",
                "properties": {
                    "confirm": {
                        "type": "boolean",
                        "title": "Confirm restart",
                        "description": "The unit will be stopped and started.",
                    },
                    "reason": {
                        "type": "string",
                        "title": "Change ticket",
                        "description": "Ticket id recorded in the audit log.",
                    },
                },
                "required": ["confirm"],
            },
        })
        payload = (response or {}).get("result") or {}
        action = payload.get("action")
        confirmed = (payload.get("content") or {}).get("confirm") is True
        if action != "accept" or not confirmed:
            reply(rid, {
                "content": [{"type": "text",
                             "text": "Restart not performed (action=%s)." % action}],
                "isError": True,
            })
            return
    RESOURCES["lab://metrics/cpu"]["text"] = "cpu_busy_ratio 0.07\n"
    if "lab://metrics/cpu" in SUBSCRIPTIONS:
        notify("notifications/resources/updated", {"uri": "lab://metrics/cpu"})
    reply(rid, {"content": [{"type": "text", "text": "Restarted %s." % unit}]})


def t_open_incident(rid, args, token):
    incident_id = "77"
    reply(rid, {"content": [
        {"type": "text", "text": "Opened incident %s." % incident_id},
        {
            "type": "resource_link",
            "uri": "lab://incident/%s" % incident_id,
            "name": "incident-%s" % incident_id,
            "mimeType": "application/json",
            "description": args.get("summary", ""),
        },
    ]})


def t_draft_summary(rid, args, token):
    if "sampling" not in CLIENT_CAPABILITIES:
        reply(rid, {
            "content": [{"type": "text",
                         "text": "This tool needs the client sampling capability."}],
            "isError": True,
        })
        return
    response = call_client("sampling/createMessage", {
        "messages": [{
            "role": "user",
            "content": {
                "type": "text",
                "text": "Summarise incident %s in two sentences." % args.get("incident_id"),
            },
        }],
        "modelPreferences": {
            "hints": [{"name": "claude-sonnet"}],
            "intelligencePriority": 0.8,
            "speedPriority": 0.3,
            "costPriority": 0.2,
        },
        "systemPrompt": "You are an SRE writing an incident summary.",
        "includeContext": "thisServer",
        "maxTokens": 300,
    })
    payload = (response or {}).get("result") or {}
    text = (payload.get("content") or {}).get("text", "(no completion)")
    reply(rid, {"content": [{
        "type": "text",
        "text": "model=%s stopReason=%s\n%s" % (
            payload.get("model"), payload.get("stopReason"), text),
    }]})


def t_show_roots(rid, args, token):
    if "roots" not in CLIENT_CAPABILITIES:
        reply(rid, {
            "content": [{"type": "text", "text": "Client declared no roots capability."}],
            "isError": True,
        })
        return
    response = call_client("roots/list", {})
    roots = ((response or {}).get("result") or {}).get("roots", [])
    listing = "\n".join(
        "%s (%s)" % (r.get("uri"), r.get("name", "unnamed")) for r in roots
    ) or "(none)"
    reply(rid, {"content": [{"type": "text", "text": listing}]})


def t_slow_scan(rid, args, token):
    steps = int(args.get("steps", 3))
    for i in range(1, steps + 1):
        if token is not None:
            notify("notifications/progress", {
                "progressToken": token,
                "progress": i,
                "total": steps,
                "message": "scanned %d of %d hosts" % (i, steps),
            })
        if LOG_LEVELS.index("info") >= LOG_LEVELS.index(LOG_LEVEL):
            notify("notifications/message", {
                "level": "info",
                "logger": "scanner",
                "data": {"host": "node-%d" % i, "status": "ok"},
            })
    reply(rid, {"content": [{"type": "text", "text": "Scanned %d hosts." % steps}]})


TOOL_IMPLS = {
    "sum_series": t_sum_series,
    "restart_service": t_restart_service,
    "open_incident": t_open_incident,
    "draft_summary": t_draft_summary,
    "show_roots": t_show_roots,
    "slow_scan": t_slow_scan,
}


def h_tools_call(rid, params):
    name = params.get("name")
    args = params.get("arguments") or {}
    token = (params.get("_meta") or {}).get("progressToken")
    implementation = TOOL_IMPLS.get(name)
    if implementation is None:
        # Unknown tool is a protocol error, not a tool failure.
        fail(rid, -32602, "Unknown tool: %s" % name)
        return
    implementation(rid, args, token)


def h_resources_list(rid, params):
    listing = []
    for uri, meta in RESOURCES.items():
        entry = {"uri": uri, "name": meta["name"], "mimeType": meta["mimeType"]}
        for key in ("title", "description", "annotations"):
            if key in meta:
                entry[key] = meta[key]
        entry["size"] = len(meta["text"].encode("utf-8"))
        listing.append(entry)
    reply(rid, {"resources": listing})


def h_resource_templates_list(rid, params):
    reply(rid, {"resourceTemplates": RESOURCE_TEMPLATES})


def h_resources_read(rid, params):
    uri = params.get("uri", "")
    if uri in RESOURCES:
        meta = RESOURCES[uri]
        reply(rid, {"contents": [{
            "uri": uri,
            "name": meta["name"],
            "mimeType": meta["mimeType"],
            "text": meta["text"],
        }]})
        return
    if uri.startswith("lab://incident/"):
        incident_id = uri.rsplit("/", 1)[1]
        body = json.dumps({"id": incident_id, "state": "open", "severity": 2}, indent=2)
        reply(rid, {"contents": [{
            "uri": uri,
            "mimeType": "application/json",
            "text": body,
        }]})
        return
    fail(rid, -32002, "Resource not found", {"uri": uri})


def h_resources_subscribe(rid, params):
    SUBSCRIPTIONS.add(params.get("uri"))
    reply(rid, {})


def h_resources_unsubscribe(rid, params):
    SUBSCRIPTIONS.discard(params.get("uri"))
    reply(rid, {})


def h_prompts_list(rid, params):
    reply(rid, {"prompts": PROMPTS})


def h_prompts_get(rid, params):
    name = params.get("name")
    args = params.get("arguments") or {}
    if name != "postmortem":
        fail(rid, -32602, "Unknown prompt: %s" % name)
        return
    if "incident_id" not in args:
        fail(rid, -32602, "Missing required argument: incident_id")
        return
    tone = args.get("tone", "blameless")
    runbook = RESOURCES["file:///lab/runbooks/oncall.md"]
    reply(rid, {
        "description": "Postmortem draft for incident %s" % args["incident_id"],
        "messages": [
            {
                "role": "user",
                "content": {
                    "type": "text",
                    "text": "Write a %s postmortem for incident %s." % (
                        tone, args["incident_id"]),
                },
            },
            {
                "role": "user",
                "content": {
                    "type": "resource",
                    "resource": {
                        "uri": "file:///lab/runbooks/oncall.md",
                        "mimeType": "text/markdown",
                        "text": runbook["text"],
                    },
                },
            },
        ],
    })


def h_completion_complete(rid, params):
    ref = params.get("ref") or {}
    argument = params.get("argument") or {}
    prefix = argument.get("value", "")
    candidates = []
    if ref.get("type") == "ref/prompt" and ref.get("name") == "postmortem":
        if argument.get("name") == "tone":
            candidates = ["blameless", "terse", "executive"]
        elif argument.get("name") == "incident_id":
            candidates = ["41", "42", "77"]
    elif ref.get("type") == "ref/resource" and ref.get("uri") == "lab://incident/{id}":
        candidates = ["41", "42", "77"]
    values = [c for c in candidates if c.startswith(prefix)]
    reply(rid, {"completion": {
        "values": values[:100],
        "total": len(values),
        "hasMore": False,
    }})


def h_logging_set_level(rid, params):
    global LOG_LEVEL
    level = params.get("level")
    if level not in LOG_LEVELS:
        fail(rid, -32602, "Unknown log level: %s" % level)
        return
    LOG_LEVEL = level
    reply(rid, {})


HANDLERS = {
    "initialize": h_initialize,
    "ping": h_ping,
    "tools/list": h_tools_list,
    "tools/call": h_tools_call,
    "resources/list": h_resources_list,
    "resources/templates/list": h_resource_templates_list,
    "resources/read": h_resources_read,
    "resources/subscribe": h_resources_subscribe,
    "resources/unsubscribe": h_resources_unsubscribe,
    "prompts/list": h_prompts_list,
    "prompts/get": h_prompts_get,
    "completion/complete": h_completion_complete,
    "logging/setLevel": h_logging_set_level,
}


def dispatch(message):
    method = message.get("method")
    if method is None:
        trace("unmatched response: %s" % json.dumps(message))
        return
    rid = message.get("id")
    params = message.get("params") or {}
    handler = HANDLERS.get(method)
    if handler is None:
        if method.startswith("notifications/"):
            trace("notification ignored: %s" % method)
            return
        fail(rid, -32601, "Method not found: %s" % method)
        return
    handler(rid, params)


def main():
    while True:
        message = read_message()
        if message is None:
            break
        dispatch(message)


if __name__ == "__main__":
    main()
```

3. Smoke-test it. The stdio transport is newline-delimited JSON, so you can drive it with a pipe:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pipe","version":"0"}}}' \
  | python3 primitives_server.py 2>/dev/null | jq -c .
```

Expected:

```
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"prompts":{"listChanged":true},"completions":{},"logging":{}},"serverInfo":{"name":"primitives-lab","title":"Protocol Primitives Lab","version":"0.1.0"},"instructions":"Lab server. Read lab://metrics/cpu before restarting anything."}}
```

4. Run it once *without* discarding stderr and note where the `trace()` output lands:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"pipe","version":"0"}}}' \
  | python3 primitives_server.py > /dev/null
```

Expected:

```
client asked for protocolVersion=2025-06-18
client capabilities: {"roots": {"listChanged": true}}
```

**Q0.1** — The stdio transport frames messages as one JSON object per line. What framing does the Language Server Protocol use instead, and what would happen to this server if a client sent LSP-style framing?

**Q0.2** — Step 4 proves that `trace()` writes to stderr. State the exact rule the specification places on a stdio server's **stdout**, and describe the concrete failure a stray `print("starting…")` would cause in a real client.

**Q0.3** — The `initialize` response advertises `"resources": {"subscribe": true, "listChanged": true}`. If you deleted `"subscribe": true` but left `resources/subscribe` implemented, would the server still be spec-compliant when a client called it? Who is at fault in that exchange?

---

## Exercise 1 — Capability negotiation: which primitives exist at all

Before any primitive can be used, both sides declare what they support. A primitive that was not declared does not exist for that session.

### Steps

1. Write the handshake to a reusable file so you stop retyping it:

```bash
cat > init.jsonl <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{}},"clientInfo":{"name":"lab","title":"Lab client","version":"0.1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
EOF
```

2. Extract only the server's capability map:

```bash
cat init.jsonl | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==1) | .result.capabilities'
```

Expected:

```
{"tools":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"prompts":{"listChanged":true},"completions":{},"logging":{}}
```

3. Ask for a protocol version the server does not implement, and watch what it answers:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{},"clientInfo":{"name":"lab","version":"0"}}}' \
  | python3 primitives_server.py 2>/dev/null | jq -r '.result.protocolVersion'
```

Expected:

```
2025-06-18
```

4. Call a method that does not exist, to see the JSON-RPC error shape:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==9)'
{"jsonrpc":"2.0","id":9,"method":"tools/describe","params":{}}
EOF
```

Expected:

```
{"jsonrpc":"2.0","id":9,"error":{"code":-32601,"message":"Method not found: tools/describe"}}
```

**Q1.1** — List the three server primitives and the three client primitives, and for each one name the party that is *in control* of invoking it (the model, the application, or the user).

**Q1.2** — In step 3 the server answered `2025-06-18` to a client that asked for `2099-01-01`. That is the correct server behaviour. What is the client now obliged to do, and what must it **not** do?

**Q1.3** — `notifications/initialized` carries no parameters and gets no response. What state transition does it mark, and what is the client allowed to send *before* it — during the window between sending `initialize` and receiving the result?

**Q1.4** — The error in step 4 is `-32601`. Which errors in this lab are `-32602` instead, and what is the difference in kind between the two?

---

## Exercise 2 — Tools: the model-controlled primitive

### Steps

1. List the tools, one line per name:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -r 'select(.id==2) | .result.tools[].name'
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
```

Expected:

```
sum_series
restart_service
open_incident
```

2. Six tools are defined but three came back. Look at the full result:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==2) | {names: [.result.tools[].name], nextCursor: .result.nextCursor}'
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
```

Expected:

```
{"names":["sum_series","restart_service","open_incident"],"nextCursor":"b2Zmc2V0OjM="}
```

3. Follow the cursor to the second page:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==3) | {names: [.result.tools[].name], nextCursor: .result.nextCursor}'
{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"cursor":"b2Zmc2V0OjM="}}
EOF
```

Expected:

```
{"names":["draft_summary","show_roots","slow_scan"],"nextCursor":null}
```

**Q2.1** — A client implementation decodes that cursor (it is base64 for `offset:3`), adds 3 itself and sends `offset:6` re-encoded. It works against this server. Why is that client broken anyway, and which sentence of the pagination specification does it violate?

**Q2.2** — How does a client know it has reached the last page? Name the precise condition, and explain why "the page came back with fewer than `PAGE_SIZE` items" is not it.

4. Call a tool that declares an `outputSchema`:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==4) | .result'
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"sum_series","arguments":{"values":[1,2,3.5]}}}
EOF
```

Expected:

```
{"content":[{"type":"text","text":"{\"total\": 6.5, \"count\": 3}"}],"structuredContent":{"total":6.5,"count":3}}
```

**Q2.3** — The same data appears twice: once serialised inside `content[0].text` and once as `structuredContent`. Which of the two is mandatory when `outputSchema` is present, why is the other one sent as well, and what MUST the client do with `structuredContent` before trusting it?

5. Now provoke two different kinds of failure. First, a tool that exists but rejects its input; second, a tool that does not exist:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==5 or .id==6)'
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"sum_series","arguments":{"values":"1,2,3"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"sum_serie","arguments":{"values":[1]}}}
EOF
```

Expected:

```
{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"values must be an array of numbers"}],"isError":true}}
{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"Unknown tool: sum_serie"}}
```

**Q2.4** — Both calls failed, but one returned `result` and the other `error`. State the rule that decides which is correct, and explain the design reason in terms of *who is meant to read the failure*.

**Q2.5** — Suppose `sum_series` called a remote API and got HTTP 503. Which of the two shapes should the server use, and why is that the answer even though "the network is broken" feels like a protocol-level problem?

6. Inspect the annotations on the destructive tool:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==7) | .result.tools[] | select(.name=="restart_service") | .annotations'
{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}
EOF
```

Expected:

```
{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}
```

**Q2.6** — A client developer proposes: "if `readOnlyHint` is true we skip the user confirmation dialog." Quote the constraint the specification places on tool annotations and explain the attack this shortcut enables.

**Q2.7** — What does `openWorldHint: false` assert about `restart_service`, and how does it differ from `readOnlyHint: false`?

7. Call the tool that returns a link instead of the bytes:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==8) | .result.content[1]'
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"open_incident","arguments":{"summary":"kubelet flapping"}}}
EOF
```

Expected:

```
{"type":"resource_link","uri":"lab://incident/77","name":"incident-77","mimeType":"application/json","description":"kubelet flapping"}
```

**Q2.8** — Name the content block types a tool result may carry, and state the difference between `resource_link` and an embedded `resource` block. Which one costs context window, and which one costs a round trip?

**Q2.9** — `lab://incident/77` does not appear in `resources/list`. Is the server broken? What must the client be prepared to do with a `resource_link` whose URI it has never seen?

---

## Exercise 3 — Resources: the application-controlled primitive

### Steps

1. List the resources with their metadata:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==2) | .result.resources[] | {uri, mimeType, size, annotations}'
{"jsonrpc":"2.0","id":2,"method":"resources/list","params":{}}
EOF
```

Expected:

```
{"uri":"file:///lab/runbooks/oncall.md","mimeType":"text/markdown","size":88,"annotations":{"audience":["user","assistant"],"priority":0.8}}
{"uri":"lab://metrics/cpu","mimeType":"text/plain","size":22,"annotations":{"audience":["assistant"],"priority":0.3}}
```

**Q3.1** — What are `audience` and `priority` for, and who acts on them? Give one concrete client behaviour that should differ between the two resources above.

2. Ask for the templates. They are a **separate** method:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==3) | .result.resourceTemplates[]'
{"jsonrpc":"2.0","id":3,"method":"resources/templates/list","params":{}}
EOF
```

Expected:

```
{"uriTemplate":"lab://incident/{id}","name":"incident","title":"Incident record","description":"One incident, by numeric id.","mimeType":"application/json"}
```

**Q3.2** — A client only ever calls `resources/list` and concludes the server exposes two resources. What has it missed, which RFC defines the `{id}` syntax, and why can a template not be expanded into a list?

3. Read a direct resource and a templated one:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==4 or .id==5) | .result.contents[0] | {uri, mimeType, text}'
{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"file:///lab/runbooks/oncall.md"}}
{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"lab://incident/42"}}
EOF
```

Expected:

```
{"uri":"file:///lab/runbooks/oncall.md","mimeType":"text/markdown","text":"# On-call\n\n1. Check the dashboard.\n2. Page the secondary after 15 minutes.\n"}
{"uri":"lab://incident/42","mimeType":"application/json","text":"{\n  \"id\": \"42\",\n  \"state\": \"open\",\n  \"severity\": 2\n}"}
```

**Q3.3** — The result field is `contents`, an **array**, even though we asked for one URI. Why is it an array? Give a realistic case where a single `resources/read` legitimately returns more than one entry.

**Q3.4** — The incident body is JSON, and it arrives in a `text` field as an escaped string, not as a nested JSON object. Why does the protocol transport it that way? What field would be used instead if the resource were a PNG?

4. Read a URI that does not exist:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==6)'
{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"lab://metrics/memory"}}
EOF
```

Expected:

```
{"jsonrpc":"2.0","id":6,"error":{"code":-32002,"message":"Resource not found","data":{"uri":"lab://metrics/memory"}}}
```

**Q3.5** — `-32002` is outside the JSON-RPC reserved range for pre-defined errors. Why is that legal, and why is "resource not found" an `error` here while "tool input invalid" was `isError: true` in Exercise 2?

5. Subscribe, then cause a change from a different primitive and watch the notification arrive:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==7 or .id==8 or .method=="notifications/resources/updated")'
{"jsonrpc":"2.0","id":7,"method":"resources/subscribe","params":{"uri":"lab://metrics/cpu"}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"restart_service","arguments":{"unit":"kubelet.service"}}}
EOF
```

Expected:

```
{"jsonrpc":"2.0","id":7,"result":{}}
{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"lab://metrics/cpu"}}
{"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"Restarted kubelet.service."}]}}
```

**Q3.6** — `notifications/resources/updated` carries the URI but not the new content. Why is the payload deliberately empty of data, and what is the client's next move?

**Q3.7** — Distinguish `notifications/resources/updated` from `notifications/resources/list_changed`. Which capability flag gates each one, and which one did this session use?

**Q3.8** — The notification arrived *before* the response to request id 8, even though the subscribe (id 7) and the call (id 8) were sent in that order. Is that a protocol violation? What does JSON-RPC guarantee about message ordering, and what does it not?

---

## Exercise 4 — Prompts and argument completion: the user-controlled primitive

### Steps

1. List the prompts and their declared arguments:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==2) | .result.prompts[] | {name, arguments: [.arguments[] | {name, required}]}'
{"jsonrpc":"2.0","id":2,"method":"prompts/list","params":{}}
EOF
```

Expected:

```
{"name":"postmortem","arguments":[{"name":"incident_id","required":true},{"name":"tone","required":null}]}
```

2. Retrieve the prompt with arguments filled in:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==3) | .result.messages[] | {role, type: .content.type}'
{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"postmortem","arguments":{"incident_id":"77","tone":"terse"}}}
EOF
```

Expected:

```
{"role":"user","type":"text"}
{"role":"user","type":"resource"}
```

**Q4.1** — Prompt messages accept only two role values. Name them, and explain what a server author must do when they want to set a system instruction, given that the missing third role is not available here.

**Q4.2** — The second message embeds the runbook as a `resource` content block rather than as plain text. What does the client gain from the `uri` and `mimeType` that a pasted string would not give it?

**Q4.3** — MCP calls prompts "user-controlled". Concretely, what does that mean about how a prompt is invoked in a chat client, and why is it wrong for the model to select and execute a prompt on its own the way it selects a tool?

3. Omit a required argument:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==4)'
{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"postmortem","arguments":{"tone":"terse"}}}
EOF
```

Expected:

```
{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Missing required argument: incident_id"}}
```

**Q4.4** — Compare this with the `sum_series` bad-input case from Exercise 2, which returned `isError: true` instead. Why do the two use different mechanisms even though both are "the caller supplied bad arguments"?

4. Drive the completion primitive — this is what powers the drop-down while the user types:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==5 or .id==6) | .result.completion'
{"jsonrpc":"2.0","id":5,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"postmortem"},"argument":{"name":"tone","value":""}}}
{"jsonrpc":"2.0","id":6,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"postmortem"},"argument":{"name":"tone","value":"t"}}}
EOF
```

Expected:

```
{"values":["blameless","terse","executive"],"total":3,"hasMore":false}
{"values":["terse"],"total":1,"hasMore":false}
```

5. Complete against a **resource template** instead of a prompt:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==7) | .result.completion'
{"jsonrpc":"2.0","id":7,"method":"completion/complete","params":{"ref":{"type":"ref/resource","uri":"lab://incident/{id}"},"argument":{"name":"id","value":"4"}}}
EOF
```

Expected:

```
{"values":["41","42"],"total":2,"hasMore":false}
```

**Q4.6** — Which two `ref` types does `completion/complete` accept, and which server capability must be declared for a client to call it at all?

**Q4.7** — The response has `values`, `total` and `hasMore`. What is the hard ceiling on `values` in a single response, and what do `total` and `hasMore` let a UI say that `values` alone cannot?

**Q4.8** — A prompt takes `region` and then `availability_zone`, where the valid zones depend on the region already chosen. Which field of the `completion/complete` params carries the already-resolved `region` so the server can narrow the zone list?

---

## Exercise 5 — Client primitives: roots, sampling, elicitation

The three primitives above all flow client → server. These flow **server → client**, which is why a one-way pipe cannot test them: something must answer. Build a minimal client.

### Steps

1. Create `driver.py`:

```python
#!/usr/bin/env python3
"""driver.py - a dependency-free MCP client that answers server-initiated requests."""

import json
import subprocess
import sys

PROTOCOL_VERSION = "2025-06-18"
CLIENT_INFO = {"name": "lab-driver", "title": "Lab driver", "version": "0.1.0"}
CLIENT_CAPABILITIES = {
    "roots": {"listChanged": True},
    "sampling": {},
    "elicitation": {},
}
ROOTS = [{"uri": "file:///lab/workspace", "name": "Lab workspace"}]

proc = subprocess.Popen(
    [sys.executable, "primitives_server.py"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def send(message):
    print("-> " + json.dumps(message))
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()


def recv():
    line = proc.stdout.readline()
    if not line:
        return None
    print("<- " + line.strip())
    return json.loads(line)


def answer(request):
    """Serve a server-initiated request.

    A production client would show UI here: a root picker, a sampling approval
    dialog, an elicitation form. The human stays in the loop at these three
    points and nowhere else.
    """
    method = request["method"]
    if method == "roots/list":
        return {"roots": ROOTS}
    if method == "sampling/createMessage":
        return {
            "role": "assistant",
            "content": {"type": "text", "text": "Stub completion from the driver."},
            "model": "lab-stub-1",
            "stopReason": "endTurn",
        }
    if method == "elicitation/create":
        return {"action": "accept", "content": {"confirm": True, "reason": "CHG-1042"}}
    return None


def notify(method, params=None):
    message = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        message["params"] = params
    send(message)


def rpc(rid, method, params=None):
    message = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        message["params"] = params
    send(message)
    while True:
        received = recv()
        if received is None:
            raise SystemExit("server closed the stream")
        if received.get("id") == rid and "method" not in received:
            return received
        if "method" in received and "id" in received:
            result = answer(received)
            if result is None:
                send({"jsonrpc": "2.0", "id": received["id"],
                      "error": {"code": -32601,
                                "message": "Method not found: %s" % received["method"]}})
            else:
                send({"jsonrpc": "2.0", "id": received["id"], "result": result})


def main():
    rpc(1, "initialize", {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": CLIENT_CAPABILITIES,
        "clientInfo": CLIENT_INFO,
    })
    notify("notifications/initialized")
    rpc(2, "resources/subscribe", {"uri": "lab://metrics/cpu"})
    rpc(3, "tools/call", {"name": "show_roots", "arguments": {}})
    rpc(4, "tools/call", {"name": "restart_service",
                          "arguments": {"unit": "kubelet.service"}})
    rpc(5, "tools/call", {"name": "draft_summary", "arguments": {"incident_id": "77"}})
    proc.stdin.close()
    proc.wait()


if __name__ == "__main__":
    main()
```

2. Run it:

```bash
python3 driver.py 2>/dev/null
```

Abridged expected output (`->` is client to server, `<-` is server to client):

```
-> {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "show_roots", "arguments": {}}}
<- {"jsonrpc": "2.0", "id": "s1", "method": "roots/list", "params": {}}
-> {"jsonrpc": "2.0", "id": "s1", "result": {"roots": [{"uri": "file:///lab/workspace", "name": "Lab workspace"}]}}
<- {"jsonrpc": "2.0", "id": 3, "result": {"content": [{"type": "text", "text": "file:///lab/workspace (Lab workspace)"}]}}
```

**Q5.1** — Request id `3` is still open when the server sends request `s1` on the same connection. What does this prove about the MCP message model, and why did the server namespace its ids with an `s` prefix — which rule makes that unnecessary but wise?

3. Look at the `restart_service` exchange in the output:

```
-> {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "restart_service", "arguments": {"unit": "kubelet.service"}}}
<- {"jsonrpc": "2.0", "id": "s2", "method": "elicitation/create", "params": {"message": "Restart kubelet.service on the lab host?", "requestedSchema": {"type": "object", "properties": {"confirm": {"type": "boolean", "title": "Confirm restart", "description": "The unit will be stopped and started."}, "reason": {"type": "string", "title": "Change ticket", "description": "Ticket id recorded in the audit log."}}, "required": ["confirm"]}}}
-> {"jsonrpc": "2.0", "id": "s2", "result": {"action": "accept", "content": {"confirm": true, "reason": "CHG-1042"}}}
<- {"jsonrpc": "2.0", "method": "notifications/resources/updated", "params": {"uri": "lab://metrics/cpu"}}
<- {"jsonrpc": "2.0", "id": 4, "result": {"content": [{"type": "text", "text": "Restarted kubelet.service."}]}}
```

**Q5.2** — `elicitation/create` returns an `action` field. Name the three legal values and explain the semantic difference between the two that are not `accept` — why does the protocol insist on distinguishing them?

**Q5.3** — `requestedSchema` here is a flat object of primitives. State the structural restriction the specification places on it, and the reason: what would a client have to build if arbitrary nesting were allowed?

**Q5.4** — A server author adds `{"api_key": {"type": "string"}}` to `requestedSchema` so the user can paste a token into the dialog. Which explicit prohibition does that break, and what is the correct channel for that secret?

4. Now the sampling exchange:

```
-> {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "draft_summary", "arguments": {"incident_id": "77"}}}
<- {"jsonrpc": "2.0", "id": "s3", "method": "sampling/createMessage", "params": {"messages": [{"role": "user", "content": {"type": "text", "text": "Summarise incident 77 in two sentences."}}], "modelPreferences": {"hints": [{"name": "claude-sonnet"}], "intelligencePriority": 0.8, "speedPriority": 0.3, "costPriority": 0.2}, "systemPrompt": "You are an SRE writing an incident summary.", "includeContext": "thisServer", "maxTokens": 300}}
-> {"jsonrpc": "2.0", "id": "s3", "result": {"role": "assistant", "content": {"type": "text", "text": "Stub completion from the driver."}, "model": "lab-stub-1", "stopReason": "endTurn"}}
<- {"jsonrpc": "2.0", "id": 5, "result": {"content": [{"type": "text", "text": "model=lab-stub-1 stopReason=endTurn\nStub completion from the driver."}]}}
```

**Q5.5** — The server asked for `claude-sonnet` and got `lab-stub-1`. Was the client wrong? Explain the status of `modelPreferences.hints` and of the three priority values, and say who holds the final decision on model, provider and cost.

**Q5.6** — What does `includeContext: "thisServer"` request, what are the other two legal values, and why is the client — not the server — the one that resolves this field?

**Q5.7** — Sampling lets a server borrow the client's model. Name the control the specification requires around every `sampling/createMessage`, and describe the prompt-injection scenario it exists to contain.

5. Break the negotiation on purpose. Edit `driver.py` and change `CLIENT_CAPABILITIES` to `{"roots": {"listChanged": True}}`, then re-run:

```bash
python3 driver.py 2>/dev/null | grep -E '"id": (4|5),.*result'
```

Expected:

```
<- {"jsonrpc": "2.0", "id": 5, "result": {"content": [{"type": "text", "text": "This tool needs the client sampling capability."}], "isError": true}}
```

**Q5.8** — With `elicitation` withdrawn, `restart_service` restarted the unit *without asking*. Read `t_restart_service` again: is that a protocol bug or a design bug, and what should a server that genuinely requires confirmation do when the client cannot elicit?

6. Restore the capabilities. Then consider roots:

**Q5.9** — What are roots *for*? The server received `file:///lab/workspace` — what is it obliged to do with that boundary, and what enforces the boundary in reality?

**Q5.10** — A user opens a second folder in their editor. Which notification does the client send, which capability flag must it have declared to be allowed to send it, and what does the server do on receipt?

---

## Exercise 6 — Cross-cutting utilities: progress, logging, cancellation, ping

These are not primitives in their own right, but every primitive is wrapped in them.

### Steps

1. Call a long-running tool **without** a progress token, then **with** one. The token lives in `_meta` of the request params:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.method=="notifications/progress" or .id==3) | {m: .method, p: .params.progress, t: .params.total, id: .id}'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":3}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":3},"_meta":{"progressToken":"scan-abc"}}}
EOF
```

Expected:

```
{"m":"notifications/progress","p":1,"t":3,"id":null}
{"m":"notifications/progress","p":2,"t":3,"id":null}
{"m":"notifications/progress","p":3,"t":3,"id":null}
{"m":null,"p":null,"t":null,"id":3}
```

**Q6.1** — Request id 2 produced no progress notifications at all. Why is that correct behaviour rather than a missing feature? What exactly does the presence of `_meta.progressToken` signal?

**Q6.2** — A progress token is not the same thing as a request id, though both identify the same operation. Give the two properties the `progress` value must have, and say what `total` being absent means for a client's UI.

2. Watch the logging primitive, then raise the threshold:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.method=="notifications/message") | {level: .params.level, host: .params.data.host}'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2}}}
{"jsonrpc":"2.0","id":3,"method":"logging/setLevel","params":{"level":"error"}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2}}}
EOF
```

Expected:

```
{"level":"info","host":"node-1"}
{"level":"info","host":"node-2"}
```

**Q6.3** — Where does the severity scale `debug … emergency` come from, and what is the filtering rule a server applies once `logging/setLevel` sets `error`?

**Q6.4** — Compare `notifications/message` with the `trace()` calls in Exercise 0 step 4. When should a server use the structured logging primitive, and when is stderr the right destination? For an HTTP-transported server, is stderr still an option for anything the *user* needs to see?

3. Cancellation. Send a request and immediately cancel it:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==2)'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2}}}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"user pressed stop"}}
EOF
```

Expected:

```
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Scanned 2 hosts."}]}}
```

**Q6.5** — The response for id 2 arrived anyway. Given the inherent race, what is the sender of `notifications/cancelled` required to do with a response that arrives after it cancels? And which single request can never be cancelled this way?

**Q6.6** — Why is cancellation a *notification* and not a request with a response? What would a response to it actually be able to promise?

4. Liveness:

```bash
cat init.jsonl - <<'EOF' | python3 primitives_server.py 2>/dev/null | jq -c 'select(.id==2)'
{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}
EOF
```

Expected:

```
{"jsonrpc":"2.0","id":2,"result":{}}
```

**Q6.7** — `ping` is a request with an empty result. Which side may send it, what does a timeout entitle the sender to do, and why is it one of the only two things allowed on the wire before initialization completes?

---

## Exercise 7 — Diagnosis: three broken servers

Each scenario below is a real failure pattern. Reproduce it, then name the primitive rule it breaks.

### Steps

1. **Scenario A — the polluted stream.** Add this line at the very top of `main()` in `primitives_server.py`, right inside the function:

```python
    print("primitives-lab starting up")
```

Re-run the smoke test from Exercise 0:

```bash
cat init.jsonl | python3 primitives_server.py 2>/dev/null | jq -c .
```

Expected:

```
parse error: Invalid numeric literal at line 1, column 11
```

**Q7.1** — Name the rule that was broken and the one-character change that fixes the `print` call. Why does this bug not appear at all under the Streamable HTTP transport?

2. Remove that line again. **Scenario B — the unpaginated list.** Set `PAGE_SIZE = 100` and re-run Exercise 2 step 2.

**Q7.2** — With six tools the result now fits in one page and `nextCursor` disappears. The server is still compliant. At what point does this become an operational problem, and what is the correct fix — in the server, in the client, or in both?

3. Restore `PAGE_SIZE = 3`. **Scenario C — the lying capability.** In `SERVER_CAPABILITIES`, change `"resources"` to `{"listChanged": True}` (drop `subscribe`), then run Exercise 3 step 5 again.

**Q7.3** — The subscribe still works, because this server does not check. Which side of a compliant session should have refused, at which moment, and what is the operational risk of a server whose declared capabilities are narrower than its implementation?

4. Restore the capability. Finally, confirm the whole surface against the reference client. With Node.js available:

```bash
npx @modelcontextprotocol/inspector python3 primitives_server.py
```

Open the URL it prints, connect, and walk the **Tools**, **Resources** and **Prompts** tabs.

**Q7.4** — The Inspector shows `lab://incident/{id}` under resource templates but offers no "read" button until you type an id, while `lab://metrics/cpu` is readable immediately. Explain that difference in terms of the two listing methods, and say which primitive fills the id field as you type.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** — LSP frames each message with a `Content-Length: <n>` header, a blank line, and then the payload. MCP's stdio transport does not: messages are UTF-8 JSON objects delimited by newlines, and they **MUST NOT** contain embedded newlines. If a client sent LSP framing, the first line this server reads would be `Content-Length: 128`, which is not JSON, so it would answer `-32700 Parse error` and then try to parse the blank line and the body. The session never initializes. This is one of the most common mistakes when porting an LSP client to MCP.

**A0.2** — On stdio, the server **MUST NOT** write anything to stdout that is not a valid MCP message; anything else it wants to emit goes to stderr. A stray `print("starting…")` puts a non-JSON line on the stream, and the client's parser either errors out or, worse, resynchronises silently and loses the first real message — producing a hang on `initialize` with no visible error. See Scenario A in Exercise 7.

**A0.3** — It would not be compliant on the *server's* side to keep offering behaviour it did not declare, but the specification's binding requirement falls on the caller: a client **MUST NOT** use a capability the peer did not declare. The client is at fault for calling `resources/subscribe`. Both sides being sloppy is how a server ends up depending on undeclared behaviour that breaks against a strict client — see Scenario C.

### Exercise 1

**A1.1** —

| Primitive | Direction | Controlled by |
|---|---|---|
| `tools` | client → server | **the model** — the LLM chooses to call them, usually with a human approval step |
| `resources` | client → server | **the application** — the host decides what context to attach and when |
| `prompts` | client → server | **the user** — surfaced as slash commands, menu entries, buttons |
| `roots` | server → client | **the client** — it decides which boundaries to expose |
| `sampling` | server → client | **the client** — it owns the model, the cost and the approval |
| `elicitation` | server → client | **the user** — they fill in or refuse the form |

**A1.2** — If the client does not support the version the server answered with, it **MUST** disconnect. What it must not do is proceed and hope: continuing on a mismatched revision is how a client ends up sending fields the server will reject, or missing required ones. Note the negotiation is a single exchange — the server replies with the requested version if it supports it, otherwise with the latest one it does support; there is no back-and-forth.

**A1.3** — It marks the end of initialization: from that point the session is operational and both sides may use the negotiated capabilities freely. Before it — that is, while `initialize` is still in flight — the client **SHOULD NOT** send anything except `ping`, and the server **SHOULD NOT** send anything except `ping` and logging notifications.

**A1.4** — `-32601` is *method not found*: the method name itself is not implemented. `-32602` is *invalid params*: the method exists but its arguments are wrong — in this lab, an unknown tool name (`tools/call` exists, the `name` param is bad), an unknown prompt name, a missing required prompt argument, an invalid cursor. The distinction matters because a client can retry a `-32602` with corrected arguments; a `-32601` means the capability is simply absent.

### Exercise 2

**A2.1** — Cursors are **opaque**. The specification states that clients MUST treat them as opaque tokens and MUST NOT attempt to parse, construct or modify them, and must not assume any particular format or persistence. This client happens to work against a base64-offset server and will break the day the server moves to a keyset cursor, an encrypted token or a database snapshot id — and it may break *silently*, skipping or repeating entries.

**A2.2** — The last page is the one whose result has **no `nextCursor`** field. Page size is entirely at the server's discretion and may vary between pages, so a short page proves nothing: a server is free to return two items on one page and five on the next while still having more to give.

**A2.3** — When a tool declares `outputSchema`, the result **MUST** include `structuredContent` conforming to that schema. The serialised copy in a `text` content block is sent for backwards compatibility with clients that do not implement structured output — they still see the data. The client **MUST** validate `structuredContent` against the declared `outputSchema` before relying on it; the schema is a contract, and an unvalidated one is only a suggestion.

**A2.4** — The rule: failures *of the tool's own execution* are reported in-band, as a normal JSON-RPC `result` with `isError: true` and the explanation inside `content`. Failures *of the protocol* — unknown tool, malformed request, method absent — are JSON-RPC `error` responses. The reason is the intended reader. An in-band error is passed back to the model, which can read "values must be an array of numbers" and retry correctly. A JSON-RPC error is consumed by the client's transport layer and typically never reaches the model at all, so a tool that reports its business failures that way makes the agent blind and unable to self-correct.

**A2.5** — `isError: true` in a normal result. The distinction is not "was the cause local or remote" but "did the tool run". The tool was found, the arguments were valid, the call proceeded and the operation failed — that outcome is information the model should have, so that it can retry, back off, or tell the user the upstream is down.

**A2.6** — Tool annotations are **hints**: clients **MUST** consider them untrusted unless the server is a trusted one. They come from the same server that supplies the tool, so a malicious or compromised server simply labels its data-exfiltration tool `readOnlyHint: true` and the client waves it through. Annotations exist to improve UI presentation and ordering, never to make a security decision.

**A2.7** — `openWorldHint: false` says the tool operates over a **closed, enumerable domain** — here, the units on one known host — as opposed to something like a web search whose domain is the open internet. `readOnlyHint: false` says the tool **modifies its environment**. They are independent axes: a database `DELETE` is closed-world and destructive; a web search is open-world and read-only.

**A2.8** — A tool result may carry `text`, `image`, `audio`, `resource_link`, and embedded `resource` blocks. A `resource_link` is a *reference*: URI plus metadata, no bytes. An embedded `resource` carries the content inline. The embedded form costs context window immediately; the link costs a `resources/read` round trip but lets the client (or the user) decide whether the content is worth loading at all. For large or optional artefacts, the link is the right default.

**A2.9** — Not broken. A `resource_link` returned by a tool is explicitly not guaranteed to appear in `resources/list` — the listing is the server's advertised catalogue, not an index of every URI it can serve. The client must be prepared to `resources/read` a URI it has only ever seen inside a tool result, and to handle `-32002` if the server declines.

### Exercise 3

**A3.1** — `audience` says who the content is intended for (`user`, `assistant`, or both) and `priority` ranks importance from 0.0 to 1.0, where 1.0 is "effectively required". The **client** acts on them, not the model. Concretely: the runbook (`audience: [user, assistant]`, priority 0.8) is a good candidate to show in the resource picker *and* to auto-attach to context; the CPU metric (`audience: [assistant]`, priority 0.3) should be available to the model when relevant but need not clutter the user's UI.

**A3.2** — It has missed every **resource template**, which are returned only by `resources/templates/list`. The `{id}` syntax is RFC 6570 URI Templates (<https://datatracker.ietf.org/doc/html/rfc6570>). A template cannot be expanded into a list because its parameter space is unbounded or unknown to the server — there may be millions of incidents, or the set may live in a system the server only queries on demand. That is precisely why the completion primitive exists: to suggest values without enumerating them.

**A3.3** — `contents` is an array because one URI may legitimately resolve to several items. The classic case is a directory-like or collection URI — reading `file:///lab/runbooks/` returns an entry per file — and the second is a single logical resource with multiple representations. Clients must iterate; assuming `contents[0]` is the whole answer is a real bug.

**A3.4** — Every resource content entry carries its bytes in exactly one of two fields: `text` for UTF-8 text, or `blob` for base64-encoded binary. JSON is text, so it travels in `text`, escaped, with `mimeType: application/json` telling the client how to interpret it. This keeps the protocol's handling uniform and means a client never has to guess whether a payload is structured. A PNG would use `blob`, with `mimeType: image/png`.

**A3.5** — JSON-RPC reserves `-32768` to `-32000` for pre-defined errors and allows the range to be used for implementation-defined server errors; `-32002` is MCP's "resource not found" within that space. The reason it is an error rather than an in-band `isError` is that `resources/read` is not a tool: there is no model-facing result channel to put an explanation into. Resources are application-controlled, and the application — not the LLM — is the one that must handle the failure.

**A3.6** — The notification says only *that* a resource changed, with its URI. The payload deliberately omits the content so the server does not push data the client may not want, may already have, or may not be able to afford in context. The client's next move is a `resources/read` of that URI, if and when it decides the update matters.

**A3.7** — `resources/updated` means "the contents of *this* subscribed URI changed" and requires the server to have declared `resources.subscribe`. `resources/list_changed` means "the set of available resources changed — re-run `resources/list`" and requires `resources.listChanged`. This session used `updated`, following an explicit `resources/subscribe`.

**A3.8** — Not a violation. JSON-RPC guarantees that every request receives exactly one response bearing the same id; it guarantees nothing about the ordering of unrelated messages. Notifications may be interleaved with responses, and responses to concurrent requests may arrive out of order. A client that assumes reply-order equals send-order will break as soon as a server does any concurrency — correlate strictly by id.

### Exercise 4

**A4.1** — Only `user` and `assistant`. There is no `system` role in prompt messages. A server that wants to set framing instructions puts them in the text of the first `user` message, or relies on the client's own system prompt; in the sampling direction the server does get a dedicated `systemPrompt` field, but that is a different primitive and the client may modify or ignore it.

**A4.2** — The `uri` gives the content stable identity: the client can deduplicate it against context it already holds, show it as an attachment chip rather than a wall of text, let the user click through to the source, and re-read it later for a fresh copy. The `mimeType` lets it render as Markdown rather than as a literal blob. A pasted string has none of that — it is anonymous text the moment it lands.

**A4.3** — User-controlled means the prompt is surfaced in the UI as something the human explicitly picks: a slash command, a menu item, an attachment button. The user chooses it and supplies the arguments. It is wrong for the model to select and run one autonomously because a prompt is a *template for what the user wants to ask*, not a capability to be exercised — and because prompts frequently inject resources into context, which is an application-level decision, not a model-level one. Tools are the model's surface; prompts are the user's.

**A4.4** — `prompts/get` has no in-band error channel. Its result type is a message list destined for the model's context, not a tool result the model reads and reacts to; there is no `isError` field to set. A missing required argument is therefore an invalid-params protocol error, and the client — which built the form in the first place — is the one that must fix it. `tools/call`, by contrast, has a result shape designed exactly so the model can see the failure and retry.

**A4.5** — *(no question 4.5; numbering continues at 4.6)*

**A4.6** — `ref/prompt`, identified by `name`, and `ref/resource`, identified by the template `uri`. The server must declare the `completions` capability; without it the client must not call `completion/complete` at all.

**A4.7** — A single response carries **at most 100** values. `total` is the full number of matches — which may be far larger than 100 — and `hasMore` states whether more exist beyond what was returned. Together they let a UI say "showing 100 of 4,312, keep typing to narrow", which `values` alone cannot express: a list of exactly 100 items is otherwise indistinguishable from a complete result.

**A4.8** — `context.arguments` — a map of the argument names already resolved, sent alongside `ref` and `argument`. The server reads `context.arguments.region` and returns only the zones in that region. Without it, completion for interdependent arguments is guesswork.

### Exercise 5

**A5.1** — It proves MCP is **bidirectional and asynchronous**: both peers are full JSON-RPC endpoints that may originate requests at any time, including while another request is outstanding. Request ids are unique **per sender** within a session, so the server reusing `3` would be legal — client ids and server ids live in separate spaces. Namespacing them anyway is good practice because it makes a captured log unambiguous at a glance and catches the classic bug where an implementation keys one shared table by id and cross-matches the two directions.

**A5.2** — `accept`, `decline`, `cancel`. `decline` is an explicit refusal — the user read the request and said no. `cancel` is dismissal without a decision — they closed the dialog, hit escape, navigated away. The distinction matters because the server should react differently: a decline is a final answer to record and respect, while a cancel may warrant re-asking later or falling back to a different path. Collapsing them loses the user's intent. Only `accept` carries `content`.

**A5.3** — `requestedSchema` is restricted to a **flat object with primitive properties only**: string, number, integer, boolean, and enums, with optional `title`, `description`, `format` and constraints. No nested objects, no arrays of objects. The reason is that the client must render this as a form without any server-supplied code — a flat primitive schema maps onto a finite set of widgets, whereas arbitrary JSON Schema would require the client to implement a general schema-form engine, and every client would do it differently.

**A5.4** — Servers **MUST NOT** use elicitation to request sensitive information: passwords, API keys, tokens. The elicitation form is server-driven UI, so a hostile or compromised server can phish credentials through a dialog the user reasonably trusts because their own client drew it. Secrets belong in the client's own configuration or the transport's authorization layer — for HTTP transports, the OAuth flow — never in a server-specified form field.

**A5.5** — The client was not wrong. `modelPreferences.hints` are **advisory**: the names are treated as substrings to be matched flexibly, may be mapped to an equivalent model from another provider, and may be ignored entirely. `costPriority`, `speedPriority` and `intelligencePriority` are normalized 0–1 weights, also advisory. The client holds the final decision on model, provider and spend, because the client is the one paying the bill and holding the credentials.

**A5.6** — `includeContext` asks the client to attach context to the sampling request: `"thisServer"` means context from the requesting server only, `"allServers"` means from all connected MCP servers, and `"none"` means attach nothing. The client resolves it because only the client knows what other servers are connected, what the user has consented to share, and what is already in the conversation — the server can see none of that, and letting it reach across into other servers' context would be a cross-server data leak.

**A5.7** — Human-in-the-loop approval. The specification requires that users be able to review and approve — and edit or reject — both the prompt being sampled and the completion before it is returned to the server. Without it, a server that has injected text into the conversation can use the user's model and budget to generate content, then read the result back: an exfiltration and prompt-injection amplifier where the server both writes the input and reads the output.

**A5.8** — A design bug in the server. The protocol behaviour is correct — the server checked `CLIENT_CAPABILITIES` and did not call an undeclared primitive — but the *policy* is wrong: it treated confirmation as optional decoration. A server whose operation genuinely requires confirmation and finds no `elicitation` capability should refuse: return `isError: true` explaining that the client cannot confirm destructive actions. Never degrade a safety gate into a no-op because the channel for it is missing.

**A5.9** — Roots tell the server which filesystem boundaries the client has made available — typically the open project folders. The server **SHOULD** respect them: operate within them, and not reach outside. What actually enforces the boundary is the operating system and the server's own implementation, not the protocol. Roots are a *declaration of scope*, not a sandbox; a server that ignores them is misbehaving, not blocked. Root URIs are `file://` URIs in the current specification.

**A5.10** — `notifications/roots/list_changed`, which the client may send only if it declared `roots: {listChanged: true}` during initialization. On receipt the server calls `roots/list` again and refreshes its view; it must not assume the previous list is still valid, and must not cache roots indefinitely.

### Exercise 6

**A6.1** — Progress notifications are opt-in per request. A receiver may send `notifications/progress` **only** if the original request included `_meta.progressToken`; the token is the caller saying "I have a UI for this, send me updates and here is the handle to correlate them with". Request 2 sent none, so silence is exactly right — and it saves a client with no progress UI from processing traffic it would discard.

**A6.2** — `progress` MUST **increase** with each notification for a given token, and it need not be a percentage — it can be bytes, records, hosts, any monotonically rising measure. If `total` is absent the progress is **indeterminate**: the UI can show activity and a raw count, but not a percentage or an ETA, so it should render a spinner rather than a bar. The token is chosen by the request sender, must be unique among active tokens, and may be a string or an integer.

**A6.3** — The scale is RFC 5424, the syslog severity levels: `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`. After `logging/setLevel` with `error`, the server sends `notifications/message` only for messages at that severity **or higher** — `error`, `critical`, `alert`, `emergency` — and drops `debug` through `warning`.

**A6.4** — `notifications/message` is for anything the **user or the client application** should be able to see: operational events, structured diagnostics surfaced in the client's log pane, anything that belongs to the session. stderr is for the server process's **own** debugging — startup traces, stack traces, anything you would read with `journalctl`. For an HTTP-transported server stderr still exists as a process log on the server host, but it is invisible to the user entirely; over HTTP the logging primitive is the only channel that reaches them.

**A6.5** — The sender **MUST** ignore any response to a request it has cancelled, because the race is unavoidable: the response may already have been serialised and put on the wire before the cancellation was read. `initialize` **MUST NOT** be cancelled by either side — cancelling it would leave the session in an undefined state with no agreed protocol version.

**A6.6** — Because there is nothing meaningful to respond. By the time the notification is processed the operation has already finished, is finishing, or is not cancellable, and none of those outcomes changes what the sender does — it ignores the late response either way. Making it a request would add a round trip, a timeout and an error path to buy a promise that cannot be kept. The receiver **SHOULD** stop work and **MUST NOT** send a response for the cancelled request, but that is best-effort by design.

**A6.7** — Either side may send `ping` at any time. If no response arrives within a reasonable timeout the sender **MAY** consider the connection stale, terminate it and attempt reconnection. It is allowed before initialization completes — alongside logging notifications from the server — precisely because it carries no semantics that depend on the negotiated version or capabilities: it only asks "are you there".

### Exercise 7

**A7.1** — The rule is that on stdio, the server MUST NOT write anything to stdout that is not a valid MCP message. The fix is one keyword: `print("primitives-lab starting up", file=sys.stderr)`. Under Streamable HTTP the bug vanishes because protocol messages travel in HTTP request and response bodies, not on the process's file descriptors — stdout goes to the container log where it is harmless. That is exactly why this class of bug survives development and appears only when someone runs the server over stdio in a desktop client.

**A7.2** — It becomes an operational problem when the listing outgrows what one response can carry comfortably: hundreds of tools, thousands of resources, a large `resources/list` on a catalogue server. The symptom is a slow or oversized response, sometimes a transport-level size limit. The fix is **both sides**. A server SHOULD paginate any listing that can grow unbounded; a client MUST follow `nextCursor` until it is absent, because it cannot know the server's page size and will silently show a truncated catalogue if it reads only the first page. Servers that never paginate and clients that never follow cursors both work perfectly right up to the day they do not.

**A7.3** — The **client** should have refused, at the moment it was about to call `resources/subscribe`: using a capability the peer did not declare is prohibited, and a correct client checks the capability map it received from `initialize`. The risk of an over-implementing server is that its behaviour becomes load-bearing for permissive clients while being invisible to strict ones — the feature works in testing with one client and disappears in production with another, with no error to point at. Declare exactly what you implement, and implement exactly what you declare.

**A7.4** — `lab://metrics/cpu` came from `resources/list`: a concrete URI, immediately readable. `lab://incident/{id}` came from `resources/templates/list`: an RFC 6570 template with an unbound variable, which cannot be read until the variable is expanded, so the UI must collect `id` first. The primitive that suggests values for that field as you type is `completion/complete` with a `ref/resource` reference carrying the template URI — the same mechanism used for prompt arguments in Exercise 4.

</details>

---

## Sources

- Linux Foundation, *Model Context Protocol Associate (MCPA)* — <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>
- MCP specification 2025-06-18, *Lifecycle* — <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- MCP specification 2025-06-18, *Transports* — <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- MCP specification 2025-06-18, *Tools* — <https://modelcontextprotocol.io/specification/2025-06-18/server/tools>
- MCP specification 2025-06-18, *Resources* — <https://modelcontextprotocol.io/specification/2025-06-18/server/resources>
- MCP specification 2025-06-18, *Prompts* — <https://modelcontextprotocol.io/specification/2025-06-18/server/prompts>
- MCP specification 2025-06-18, *Completion* — <https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/completion>
- MCP specification 2025-06-18, *Logging* — <https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/logging>
- MCP specification 2025-06-18, *Roots* — <https://modelcontextprotocol.io/specification/2025-06-18/client/roots>
- MCP specification 2025-06-18, *Sampling* — <https://modelcontextprotocol.io/specification/2025-06-18/client/sampling>
- MCP specification 2025-06-18, *Elicitation* — <https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation>
- MCP specification 2025-06-18, *Pagination* — <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/pagination>
- MCP specification 2025-06-18, *Progress* — <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress>
- MCP specification 2025-06-18, *Cancellation* — <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation>
- JSON-RPC 2.0 Specification — <https://www.jsonrpc.org/specification>
- RFC 6570, *URI Template* — <https://datatracker.ietf.org/doc/html/rfc6570>
- RFC 5424, *The Syslog Protocol* (severity levels) — <https://datatracker.ietf.org/doc/html/rfc5424>
- MCP Inspector — <https://github.com/modelcontextprotocol/inspector>