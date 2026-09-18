# MCPA 3.1 — Interaction Patterns & Response Handling

**Guided exercises.** Exam weight: 6.5. Authoring language: English.

Everything in this topic is one question asked repeatedly: *when a message crosses the boundary between a client and a server, what exactly is on the wire, who is allowed to answer, and what does the receiver do with what comes back?* You will not learn that from a client UI that hides the traffic. So the first half of this lab builds a ~200-line MCP server with **no SDK at all**, drives it with hand-written JSON-RPC lines, and reads the bytes. The second half moves to a real SDK over Streamable HTTP, where the transport adds its own response-handling rules on top.

Reference sources used throughout (cite these, not this document):

- MCPA exam page — <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>
- Base protocol — <https://modelcontextprotocol.io/specification/2025-06-18/basic>
- Lifecycle — <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- Transports — <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- Progress / Cancellation / Ping — <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress>, `/cancellation`, `/ping`
- Tools — <https://modelcontextprotocol.io/specification/2025-06-18/server/tools>
- Pagination / Logging — <https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/pagination>, `/logging`
- Sampling / Elicitation / Roots — <https://modelcontextprotocol.io/specification/2025-06-18/client/sampling>, `/elicitation`, `/roots`
- Schema reference — <https://modelcontextprotocol.io/specification/2025-06-18/schema>
- JSON-RPC 2.0 — <https://www.jsonrpc.org/specification>

> **Revision awareness.** These exercises target the `2025-06-18` revision, which is what the server below advertises. MCP is a dated-revision protocol: the revision is negotiated in `initialize`, and features appear and disappear between revisions (JSON-RPC **batching existed in `2025-03-26` and was removed in `2025-06-18`**; elicitation and `structuredContent` were *added* there; later revisions add long-running task augmentation). Whenever a question here says "the spec says", the honest reading is "the spec revision you negotiated says" — check the `protocolVersion` in the `initialize` result before you argue with a server.

---

## Exercise 0 — Build the lab

### Steps

1. Create a working directory and a virtual environment. Only the HTTP exercises need a dependency; the stdio exercises run on the standard library.

```bash
mkdir -p ~/mcpa-3.1 && cd ~/mcpa-3.1
python3 -m venv .venv
.venv/bin/pip install --quiet "mcp[cli]"
.venv/bin/python -c 'import mcp, sys; print("python", sys.version.split()[0], "| mcp", mcp.__version__ if hasattr(mcp,"__version__") else "installed")'
```

2. Write the server. Read it once before running it — every rule the rest of this lab tests is implemented in these lines.

```python
#!/usr/bin/env python3
"""tiny_server.py - a deliberately small MCP server over stdio.

No SDK on purpose: every byte that crosses the transport is written here, so
the interaction patterns stay visible. This is a microscope, not production code.
"""
import base64
import json
import sys
import threading
import time

PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_VERSIONS = ("2025-06-18", "2025-03-26")
PAGE_SIZE = 2
LEVELS = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]

_stdout_lock = threading.Lock()
_state_lock = threading.Lock()
_cancelled = set()          # request ids the client told us to abandon
_pending = {}               # id -> callback, for requests THIS server sent
_client_capabilities = {}
_log_level = "debug"
_next_server_id = 1000


def send(message):
    """Exactly one JSON object per line on stdout - and nothing else, ever."""
    with _stdout_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def trace(text):
    """Human-facing logging goes to stderr, where it cannot corrupt the stream."""
    print(f"[server] {text}", file=sys.stderr, flush=True)


def reply(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def fail(request_id, code, message, data=None):
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    send({"jsonrpc": "2.0", "id": request_id, "error": error})


def notify(method, params=None):
    message = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        message["params"] = params
    send(message)


def log_message(level, logger, data):
    with _state_lock:
        threshold = LEVELS.index(_log_level)
    if LEVELS.index(level) < threshold:
        return
    notify("notifications/message", {"level": level, "logger": logger, "data": data})


def ask_client(method, params, on_response):
    """Server -> client request. The server is a JSON-RPC peer, not a slave."""
    global _next_server_id
    with _state_lock:
        _next_server_id += 1
        request_id = _next_server_id
        _pending[request_id] = on_response
    send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})


def encode_cursor(offset):
    return base64.urlsafe_b64encode(json.dumps({"offset": offset}).encode()).decode()


def decode_cursor(cursor):
    return json.loads(base64.urlsafe_b64decode(cursor.encode()))["offset"]


TOOLS = [
    {
        "name": "echo",
        "title": "Echo",
        "description": "Return the text it was given, optionally after a delay.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "delay_ms": {"type": "integer", "minimum": 0, "maximum": 5000},
            },
            "required": ["text"],
        },
    },
    {
        "name": "divide",
        "title": "Divide",
        "description": "Divide two numbers. Fails at runtime when the divisor is zero.",
        "inputSchema": {
            "type": "object",
            "properties": {"numerator": {"type": "number"}, "denominator": {"type": "number"}},
            "required": ["numerator", "denominator"],
        },
    },
    {
        "name": "disk_report",
        "title": "Disk report",
        "description": "Filesystem usage for one mount point, as structured output.",
        "inputSchema": {
            "type": "object",
            "properties": {"mount": {"type": "string"}},
            "required": ["mount"],
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "mount": {"type": "string"},
                "used_percent": {"type": "integer"},
                "inodes_free": {"type": "integer"},
            },
            "required": ["mount", "used_percent", "inodes_free"],
        },
    },
    {
        "name": "slow_scan",
        "title": "Slow scan",
        "description": "Long-running scan that reports progress and honours cancellation.",
        "inputSchema": {
            "type": "object",
            "properties": {"steps": {"type": "integer", "minimum": 1, "maximum": 20}},
            "required": ["steps"],
        },
    },
    {
        "name": "confirm_restart",
        "title": "Confirm restart",
        "description": "Asks the human, through the client, before pretending to restart anything.",
        "inputSchema": {
            "type": "object",
            "properties": {"service": {"type": "string"}},
            "required": ["service"],
        },
    },
]


def do_initialize(request_id, params):
    global _client_capabilities
    asked = params.get("protocolVersion")
    negotiated = asked if asked in SUPPORTED_VERSIONS else PROTOCOL_VERSION
    with _state_lock:
        _client_capabilities = params.get("capabilities") or {}
    client = params.get("clientInfo") or {}
    trace(f"initialize from {client.get('name')} {client.get('version')} (asked for {asked})")
    reply(request_id, {
        "protocolVersion": negotiated,
        "capabilities": {"tools": {"listChanged": True}, "logging": {}},
        "serverInfo": {"name": "tiny-mcp", "title": "Tiny MCP Server", "version": "1.0.0"},
        "instructions": "Demo server for MCPA topic 3.1. Every tool is a fake.",
    })


def do_tools_list(request_id, params):
    cursor = params.get("cursor")
    try:
        offset = decode_cursor(cursor) if cursor is not None else 0
    except Exception:
        fail(request_id, -32602, "Invalid cursor", {"cursor": cursor})
        return
    window = TOOLS[offset:offset + PAGE_SIZE]
    result = {"tools": window}
    if offset + PAGE_SIZE < len(TOOLS):
        result["nextCursor"] = encode_cursor(offset + PAGE_SIZE)
    reply(request_id, result)


def run_slow_scan(request_id, arguments, meta):
    token = meta.get("progressToken")
    steps = int(arguments["steps"])

    def worker():
        for i in range(1, steps + 1):
            time.sleep(0.5)
            with _state_lock:
                if request_id in _cancelled:
                    trace(f"id {request_id} was cancelled at step {i}: sending no response at all")
                    return
            log_message("debug", "scanner", {"step": i, "shard": f"shard-{i}"})
            if token is not None:
                notify("notifications/progress", {
                    "progressToken": token,
                    "progress": i,
                    "total": steps,
                    "message": f"scanned {i}/{steps} shards",
                })
        reply(request_id, {
            "content": [{"type": "text", "text": f"scan finished: {steps} shards, 0 findings"}],
            "isError": False,
        })

    threading.Thread(target=worker, daemon=True).start()


def run_confirm_restart(request_id, arguments):
    service = arguments["service"]
    with _state_lock:
        can_elicit = "elicitation" in _client_capabilities
    if not can_elicit:
        reply(request_id, {
            "content": [{"type": "text",
                         "text": "This tool needs the elicitation capability, which this client did not declare."}],
            "isError": True,
        })
        return

    def on_answer(message):
        if "error" in message:
            reply(request_id, {
                "content": [{"type": "text", "text": f"the client refused to ask: {message['error']['message']}"}],
                "isError": True,
            })
            return
        answer = message.get("result") or {}
        action = answer.get("action")
        if action != "accept":
            reply(request_id, {"content": [{"type": "text",
                                            "text": f"{service} left running; the human answered '{action}'"}]})
            return
        content = answer.get("content") or {}
        if not content.get("confirm"):
            reply(request_id, {"content": [{"type": "text",
                                            "text": f"{service} left running; the form returned confirm=false"}]})
            return
        reply(request_id, {"content": [{"type": "text",
                                        "text": f"restarted {service}; reason on record: {content.get('reason', 'none given')}"}]})

    ask_client("elicitation/create", {
        "message": f"Restart {service}? This drops in-flight connections.",
        "requestedSchema": {
            "type": "object",
            "properties": {
                "confirm": {"type": "boolean", "title": "Confirm restart"},
                "reason": {"type": "string", "title": "Change reason", "maxLength": 120},
            },
            "required": ["confirm"],
        },
    }, on_answer)


def do_tools_call(request_id, params):
    name = params.get("name")
    arguments = params.get("arguments") or {}
    meta = params.get("_meta") or {}
    tool = next((t for t in TOOLS if t["name"] == name), None)
    if tool is None:
        fail(request_id, -32602, "Unknown tool", {"tool": name})
        return
    missing = [k for k in tool["inputSchema"].get("required", []) if k not in arguments]
    if missing:
        fail(request_id, -32602, "Missing required arguments", {"missing": missing})
        return

    if name == "echo":
        time.sleep(int(arguments.get("delay_ms", 0)) / 1000)
        reply(request_id, {"content": [{"type": "text", "text": arguments["text"]}], "isError": False})
    elif name == "divide":
        try:
            value = arguments["numerator"] / arguments["denominator"]
        except ZeroDivisionError:
            reply(request_id, {
                "content": [{"type": "text",
                             "text": "Division by zero. Pass a non-zero denominator and call me again."}],
                "isError": True,
            })
            return
        reply(request_id, {"content": [{"type": "text", "text": str(value)}], "isError": False})
    elif name == "disk_report":
        payload = {"mount": arguments["mount"], "used_percent": 87, "inodes_free": 120493}
        reply(request_id, {
            "content": [{"type": "text", "text": json.dumps(payload)}],
            "structuredContent": payload,
            "isError": False,
        })
    elif name == "slow_scan":
        run_slow_scan(request_id, arguments, meta)
    elif name == "confirm_restart":
        run_confirm_restart(request_id, arguments)


def do_set_level(request_id, params):
    global _log_level
    level = params.get("level")
    if level not in LEVELS:
        fail(request_id, -32602, "Unknown log level", {"level": level, "known": LEVELS})
        return
    with _state_lock:
        _log_level = level
    trace(f"log level is now {level}")
    reply(request_id, {})


def handle_request(request_id, method, params):
    if method == "initialize":
        do_initialize(request_id, params)
    elif method == "ping":
        reply(request_id, {})
    elif method == "tools/list":
        do_tools_list(request_id, params)
    elif method == "tools/call":
        do_tools_call(request_id, params)
    elif method == "logging/setLevel":
        do_set_level(request_id, params)
    else:
        fail(request_id, -32601, "Method not found", {"method": method})


def handle_notification(method, params):
    if method == "notifications/initialized":
        trace("client reports it is initialized")
    elif method == "notifications/cancelled":
        with _state_lock:
            _cancelled.add(params.get("requestId"))
        trace(f"cancellation for id {params.get('requestId')}: {params.get('reason')}")
    else:
        trace(f"ignoring unknown notification {method} (a notification is never answered)")


def handle_response(message):
    with _state_lock:
        callback = _pending.pop(message.get("id"), None)
    if callback is None:
        trace(f"response for unknown id {message.get('id')} - dropping it")
        return
    callback(message)


def dispatch(message):
    method = message.get("method")
    if method is None:                 # no method -> it answers something WE sent
        handle_response(message)
    elif "id" not in message:          # method, no id key at all -> notification
        handle_notification(method, message.get("params") or {})
    else:
        handle_request(message.get("id"), method, message.get("params") or {})


def main():
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(None, -32700, "Parse error", {"detail": str(exc)})
            continue
        threading.Thread(target=dispatch, args=(message,), daemon=True).start()


if __name__ == "__main__":
    main()
```

3. Write the driver. It spawns the server, feeds it the lines you wrote by hand, and timestamps both directions plus stderr.

```python
#!/usr/bin/env python3
"""drive.py - feed hand-written JSON-RPC lines to an MCP stdio server.

  WAIT=6 .venv/bin/python drive.py tiny_server.py 00-init.txt 05-progress.txt

A line starting with '#' is a comment. A line 'sleep 1.5' pauses the sender.
"""
import os
import subprocess
import sys
import threading
import time

START = time.monotonic()


def stamp(prefix, text):
    print(f"{time.monotonic() - START:6.2f}s {prefix} {text}", flush=True)


def pump(stream, prefix):
    for line in stream:
        stamp(prefix, line.rstrip())


def main():
    server, scripts = sys.argv[1], sys.argv[2:]
    proc = subprocess.Popen(
        [sys.executable, server],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )
    threading.Thread(target=pump, args=(proc.stdout, "<--"), daemon=True).start()
    threading.Thread(target=pump, args=(proc.stderr, "err"), daemon=True).start()

    for path in scripts:
        with open(path) as handle:
            for raw in handle:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("sleep "):
                    time.sleep(float(line.split()[1]))
                    continue
                stamp("-->", line)
                proc.stdin.write(line + "\n")
                proc.stdin.flush()

    time.sleep(float(os.environ.get("WAIT", "2")))
    proc.terminate()


if __name__ == "__main__":
    main()
```

4. Write the handshake script. **Every later exercise starts by replaying this file**, because a fresh process is a fresh, uninitialized session.

```bash
cat > 00-init.txt <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"elicitation":{},"sampling":{},"roots":{"listChanged":true}},"clientInfo":{"name":"drive.py","version":"0.1.0"}}}
sleep 0.2
{"jsonrpc":"2.0","method":"notifications/initialized"}
sleep 0.2
EOF
```

### Questions — 0

1. `trace()` writes to stderr while `send()` writes to stdout. On the stdio transport, why is that separation not a style preference but a protocol requirement?
2. `main()` hands every inbound message to a new thread. What property of JSON-RPC makes that legal, and which field makes it survivable?
3. The server declares `"capabilities": {"tools": {"listChanged": true}, "logging": {}}` but implements no `resources/*` method. What is a well-behaved client supposed to conclude, and when is it supposed to conclude it?

---

## Exercise 1 — The three shapes on the wire

There are exactly three kinds of message in MCP, and every interaction pattern in this topic is built from them.

### Steps

1. Run the handshake plus three probes:

```bash
cat > 01-shapes.txt <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"ping"}
sleep 0.2
{"jsonrpc":"2.0","method":"notifications/some/thing/we/invented"}
sleep 0.2
{"jsonrpc":"2.0","id":3,"method":"resources/list"}
EOF

WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 01-shapes.txt
```

2. Expected output (abridged; your timestamps will differ by milliseconds):

```
  0.00s --> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
  0.01s err [server] initialize from drive.py 0.1.0 (asked for 2025-06-18)
  0.01s <-- {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {"listChanged": true}, "logging": {}}, "serverInfo": {"name": "tiny-mcp", "title": "Tiny MCP Server", "version": "1.0.0"}, "instructions": "Demo server for MCPA topic 3.1. Every tool is a fake."}}
  0.20s --> {"jsonrpc":"2.0","method":"notifications/initialized"}
  0.20s err [server] client reports it is initialized
  0.40s --> {"jsonrpc":"2.0","id":2,"method":"ping"}
  0.40s <-- {"jsonrpc": "2.0", "id": 2, "result": {}}
  0.60s --> {"jsonrpc":"2.0","method":"notifications/some/thing/we/invented"}
  0.60s err [server] ignoring unknown notification notifications/some/thing/we/invented (a notification is never answered)
  0.80s --> {"jsonrpc":"2.0","id":3,"method":"resources/list"}
  0.80s <-- {"jsonrpc": "2.0", "id": 3, "error": {"code": -32601, "message": "Method not found", "data": {"method": "resources/list"}}}
```

3. Change the client's requested version to something the server does not know, and watch negotiation instead of rejection:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2199-01-01","capabilities":{},"clientInfo":{"name":"time-traveller","version":"0.0.1"}}}' > 01-badversion.txt
WAIT=1 .venv/bin/python drive.py tiny_server.py 01-badversion.txt
```

The server answers `"protocolVersion": "2025-06-18"` — a counter-offer, not an error.

### Questions — 1

1. Three messages went out with a `method` field. Only two came back with an answer. State the structural rule, in one sentence, that decides which is which.
2. `ping` returned `"result": {}`. Why is an empty object a *success* and not a malformed response, and what would `"result": null` have meant?
3. The server answered an unsupported `protocolVersion` with its own instead of an error. Who is responsible for deciding the session cannot continue, and what should that party do?
4. `notifications/initialized` carries no `params`. What is the client forbidden from doing before it sends that notification, and what is the server forbidden from doing before it receives it?

---

## Exercise 2 — Correlation: ids, ordering, and the classic falsy-zero bug

### Steps

1. Fire a slow request and a fast one back to back, then probe two pathological ids:

```bash
cat > 02-correlation.txt <<'EOF'
{"jsonrpc":"2.0","id":"a1","method":"tools/call","params":{"name":"echo","arguments":{"text":"first request, slow","delay_ms":800}}}
{"jsonrpc":"2.0","id":"a2","method":"tools/call","params":{"name":"echo","arguments":{"text":"second request, fast"}}}
sleep 1.5
{"jsonrpc":"2.0","id":0,"method":"ping"}
{"jsonrpc":"2.0","id":null,"method":"ping"}
EOF

WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 02-correlation.txt
```

2. Expected output (handshake lines omitted):

```
  0.40s --> {"jsonrpc":"2.0","id":"a1","method":"tools/call","params":{"name":"echo","arguments":{"text":"first request, slow","delay_ms":800}}}
  0.40s --> {"jsonrpc":"2.0","id":"a2","method":"tools/call","params":{"name":"echo","arguments":{"text":"second request, fast"}}}
  0.40s <-- {"jsonrpc": "2.0", "id": "a2", "result": {"content": [{"type": "text", "text": "second request, fast"}], "isError": false}}
  1.20s <-- {"jsonrpc": "2.0", "id": "a1", "result": {"content": [{"type": "text", "text": "first request, slow"}], "isError": false}}
  1.90s --> {"jsonrpc":"2.0","id":0,"method":"ping"}
  1.90s <-- {"jsonrpc": "2.0", "id": 0, "result": {}}
  1.90s --> {"jsonrpc":"2.0","id":null,"method":"ping"}
  1.90s <-- {"jsonrpc": "2.0", "id": null, "result": {}}
```

3. Now break the dispatcher on purpose. In `dispatch()`, replace the notification test with the naive version and re-run the same script:

```python
    elif not message.get("id"):        # WRONG on purpose
```

```bash
WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 02-correlation.txt
```

`id: 0` and `id: null` now produce `err [server] ignoring unknown notification ping ...` and no response at all. **Revert the change before continuing.**

### Questions — 2

1. `a2` answered before `a1`. Is that a bug, a race, or conformant behaviour — and what is the client's only legitimate way to know which answer belongs to which call?
2. Over how long must a request id stay unique, and unique *per what*? Give the failure that occurs when an implementation reuses an id too early.
3. `id: null` got an answer here. What does the MCP base-protocol specification say about a null id in a request, and where is `"id": null` legitimate?
4. Explain, in terms of the dispatch rule, exactly why `if not message.get("id")` silently swallowed two requests, and why a client written with the same bug would eventually hang rather than error.

---

## Exercise 3 — Two kinds of failure, and never confusing them

This is the single highest-value idea in the topic. A protocol error means *the call did not happen*. A tool error means *the call happened and went badly* — and that outcome belongs to the model, not to the client's exception handler.

### Steps

1. Walk the whole ladder in one run:

```bash
cat > 03-failures.txt <<'EOF'
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"divide","arguments":{"numerator":10,"denominator":0}}}
sleep 0.2
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"divide","arguments":{"numerator":10}}}
sleep 0.2
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"dividee","arguments":{}}}
sleep 0.2
{"jsonrpc":"2.0","id":13,"method":"tools/kall","params":{}}
sleep 0.2
{"jsonrpc":"2.0" "id":14,"method":"ping"}
sleep 0.2
{"jsonrpc":"2.0","id":15,"method":"ping"}
EOF

WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 03-failures.txt
```

2. Expected output (handshake omitted):

```
  0.40s <-- {"jsonrpc": "2.0", "id": 10, "result": {"content": [{"type": "text", "text": "Division by zero. Pass a non-zero denominator and call me again."}], "isError": true}}
  0.60s <-- {"jsonrpc": "2.0", "id": 11, "error": {"code": -32602, "message": "Missing required arguments", "data": {"missing": ["denominator"]}}}
  0.80s <-- {"jsonrpc": "2.0", "id": 12, "error": {"code": -32602, "message": "Unknown tool", "data": {"tool": "dividee"}}}
  1.00s <-- {"jsonrpc": "2.0", "id": 13, "error": {"code": -32601, "message": "Method not found", "data": {"method": "tools/kall"}}}
  1.20s <-- {"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error", "data": {"detail": "Expecting ',' delimiter: line 1 column 19 (char 18)"}}}
  1.40s <-- {"jsonrpc": "2.0", "id": 15, "result": {}}
```

3. Note what id `14` got: nothing with its own id. The malformed line is unparseable, so there is no id to answer with — and the session survives anyway, which id `15` proves.

4. Fix the standard reference table in your notes:

| Code | Name | Raised when |
|---|---|---|
| `-32700` | Parse error | The bytes are not JSON. Answered with `"id": null`. |
| `-32600` | Invalid Request | Valid JSON, not a valid JSON-RPC object (`jsonrpc` missing/wrong). |
| `-32601` | Method not found | The **method** name is unknown or not offered by this peer. |
| `-32602` | Invalid params | Params fail validation — including `tools/call` with an **unknown tool name** or arguments that violate `inputSchema`. |
| `-32603` | Internal error | The receiver broke while handling a well-formed request. |
| `-32000` … `-32099` | Server error | Reserved JSON-RPC implementation-defined range. |
| above `-32000` | Application-defined | Free for SDKs and applications (for example `-32002` in some SDKs for "resource not found"). |

### Questions — 3

1. `divide` by zero returned HTTP-style success: a `result` with `isError: true`. Justify that design in terms of what the *model* needs to do next.
2. `dividee` is not a tool, and got `-32602`, not `-32601`. Why is "unknown tool" a params problem rather than a method problem?
3. A server author wraps every tool body in `try/except` and converts all exceptions into `-32603`. Name two concrete things that breaks.
4. The parse error was answered with `"id": null` and the session continued. Under what circumstance would a client be right to tear the session down instead?
5. Which of these five failures should a client surface to the *user* and which to the *model*?

---

## Exercise 4 — What a result may actually contain

### Steps

1. Call the structured tool and read both halves of the answer:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"disk_report","arguments":{"mount":"/var/lib/containers"}}}' > 04-structured.txt
WAIT=1 .venv/bin/python drive.py tiny_server.py 00-init.txt 04-structured.txt
```

```
  0.40s <-- {"jsonrpc": "2.0", "id": 20, "result": {"content": [{"type": "text", "text": "{\"mount\": \"/var/lib/containers\", \"used_percent\": 87, \"inodes_free\": 120493}"}], "structuredContent": {"mount": "/var/lib/containers", "used_percent": 87, "inodes_free": 120493}, "isError": false}}
```

2. Confirm the declaration that makes that legal — `disk_report` is the only tool in the list that carries an `outputSchema`:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":21,"method":"tools/list","params":{"cursor":"eyJvZmZzZXQiOiAyfQ=="}}' > 04-schema.txt
WAIT=1 .venv/bin/python drive.py tiny_server.py 00-init.txt 04-schema.txt | grep -o '"outputSchema".*' | head -c 400; echo
```

3. Study the full vocabulary of content blocks. This is one complete `CallToolResult`, showing every block type a `2025-06-18` tool result may carry:

```json
{
  "content": [
    {
      "type": "text",
      "text": "Node worker-7 is NotReady. Kubelet last heartbeat 4m12s ago.",
      "annotations": { "audience": ["assistant"], "priority": 0.9 }
    },
    {
      "type": "image",
      "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
      "mimeType": "image/png"
    },
    {
      "type": "audio",
      "data": "UklGRiQAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQAAAAA=",
      "mimeType": "audio/wav"
    },
    {
      "type": "resource_link",
      "uri": "file:///var/log/kubelet/worker-7.log",
      "name": "worker-7 kubelet log",
      "description": "Full kubelet journal for the failing node",
      "mimeType": "text/plain"
    },
    {
      "type": "resource",
      "resource": {
        "uri": "cluster://worker-7/conditions",
        "mimeType": "application/json",
        "text": "{\"Ready\":\"False\",\"MemoryPressure\":\"False\",\"DiskPressure\":\"True\"}"
      }
    }
  ],
  "structuredContent": {
    "node": "worker-7",
    "ready": false,
    "conditions": ["DiskPressure"]
  },
  "isError": false
}
```

### Questions — 4

1. `disk_report` sent the same data twice — once as JSON inside a `text` block, once as `structuredContent`. Is the duplication a bug? What breaks if you drop the `text` block?
2. What contract does `outputSchema` create, who is expected to enforce it, and what error results from a violation?
3. Distinguish `resource_link` from an embedded `resource` block. Name the operational consideration that decides which one a server should return for a 40 MB log file.
4. The first block carries `"audience": ["assistant"]`. What is a client meant to do with that hint, and is it binding?
5. Why can a `CallToolResult` be `isError: true` and still legally contain `structuredContent`?

---

## Exercise 5 — Progress notifications

### Steps

1. Run a long call *with* a progress token and one *without*:

```bash
cat > 05-progress.txt <<'EOF'
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":3},"_meta":{"progressToken":"scan-30"}}}
sleep 2.5
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2}}}
EOF

WAIT=3 .venv/bin/python drive.py tiny_server.py 00-init.txt 05-progress.txt
```

2. Expected output (handshake omitted):

```
  0.40s --> {"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":3},"_meta":{"progressToken":"scan-30"}}}
  0.90s <-- {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "debug", "logger": "scanner", "data": {"step": 1, "shard": "shard-1"}}}
  0.90s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "scan-30", "progress": 1, "total": 3, "message": "scanned 1/3 shards"}}
  1.40s <-- {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "debug", "logger": "scanner", "data": {"step": 2, "shard": "shard-2"}}}
  1.40s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "scan-30", "progress": 2, "total": 3, "message": "scanned 2/3 shards"}}
  1.90s <-- {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "debug", "logger": "scanner", "data": {"step": 3, "shard": "shard-3"}}}
  1.90s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "scan-30", "progress": 3, "total": 3, "message": "scanned 3/3 shards"}}
  1.90s <-- {"jsonrpc": "2.0", "id": 30, "result": {"content": [{"type": "text", "text": "scan finished: 3 shards, 0 findings"}], "isError": false}}
  2.90s --> {"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2}}}
  3.40s <-- {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "debug", "logger": "scanner", "data": {"step": 1, "shard": "shard-1"}}}
  3.90s <-- {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "debug", "logger": "scanner", "data": {"step": 2, "shard": "shard-2"}}}
  3.90s <-- {"jsonrpc": "2.0", "id": 31, "result": {"content": [{"type": "text", "text": "scan finished: 2 shards, 0 findings"}], "isError": false}}
```

3. Confirm the token is opaque by using a number instead of a string, and confirm the server echoes it verbatim:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2},"_meta":{"progressToken":991}}}' > 05-numeric.txt
WAIT=3 .venv/bin/python drive.py tiny_server.py 00-init.txt 05-numeric.txt | grep progressToken
```

### Questions — 5

1. Two notification types are interleaved above. Point at the structural difference that lets a client route one to a progress bar and the other to a log pane — without string-matching the method name twice.
2. Call `31` produced no progress at all. Whose decision was that, and where in the request was it expressed?
3. Why does progress travel on a *token* supplied by the requester rather than on the request `id`?
4. `total` is optional. What must a client render when `progress` arrives without `total`, and what invariant must `progress` still satisfy across notifications?
5. A server sends `notifications/progress` for a token belonging to a request that already returned its result. What should the receiver do?

---

## Exercise 6 — Cancellation

### Steps

1. Start a ten-step scan, abandon it mid-flight, then prove the session is still healthy:

```bash
cat > 06-cancel.txt <<'EOF'
{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":10},"_meta":{"progressToken":"scan-40"}}}
sleep 1.6
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":40,"reason":"user closed the panel"}}
sleep 1.5
{"jsonrpc":"2.0","id":41,"method":"ping"}
EOF

WAIT=3 .venv/bin/python drive.py tiny_server.py 00-init.txt 06-cancel.txt
```

2. Expected output (log notifications and handshake omitted for brevity):

```
  0.40s --> {"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":10},"_meta":{"progressToken":"scan-40"}}}
  0.90s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "scan-40", "progress": 1, "total": 10, "message": "scanned 1/10 shards"}}
  1.40s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "scan-40", "progress": 2, "total": 10, "message": "scanned 2/10 shards"}}
  1.90s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "scan-40", "progress": 3, "total": 10, "message": "scanned 3/10 shards"}}
  2.00s --> {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":40,"reason":"user closed the panel"}}
  2.00s err [server] cancellation for id 40: user closed the panel
  2.40s err [server] id 40 was cancelled at step 4: sending no response at all
  3.50s --> {"jsonrpc":"2.0","id":41,"method":"ping"}
  3.50s <-- {"jsonrpc": "2.0", "id": 41, "result": {}}
```

3. Now cancel an id that already finished, and one that never existed:

```bash
cat > 06-races.txt <<'EOF'
{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"echo","arguments":{"text":"done instantly"}}}
sleep 0.3
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42,"reason":"too late"}}
{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9999,"reason":"never existed"}}
sleep 0.3
{"jsonrpc":"2.0","id":43,"method":"ping"}
EOF

WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 06-races.txt
```

Both cancellations are absorbed silently; `43` still answers.

### Questions — 6

1. Request `40` never received a response — not a result, not an error. Is the server broken? What must the client do with the id it allocated?
2. Cancellation is a notification, not a request. Name the direct consequence for the sender, and one thing the sender therefore cannot assume.
3. Which single request is it forbidden to cancel, and why does that restriction exist?
4. A cancelled request's result arrives anyway, because the cancellation crossed it in flight. What is the receiver required to do?
5. How do timeouts and cancellation interact? Specifically: may a progress notification extend a client's timeout, and what must the client still guarantee?

---

## Exercise 7 — Pagination and opaque cursors

### Steps

1. Walk the tool list to the end:

```bash
cat > 07-pages.txt <<'EOF'
{"jsonrpc":"2.0","id":50,"method":"tools/list"}
sleep 0.3
{"jsonrpc":"2.0","id":51,"method":"tools/list","params":{"cursor":"eyJvZmZzZXQiOiAyfQ=="}}
sleep 0.3
{"jsonrpc":"2.0","id":52,"method":"tools/list","params":{"cursor":"eyJvZmZzZXQiOiA0fQ=="}}
sleep 0.3
{"jsonrpc":"2.0","id":53,"method":"tools/list","params":{"cursor":"page-2"}}
EOF

WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 07-pages.txt | sed 's/"description":[^,]*,//g'
```

2. Expected shape (tool bodies trimmed by the `sed`):

```
  0.40s <-- {"jsonrpc": "2.0", "id": 50, "result": {"tools": [{"name": "echo", ...}, {"name": "divide", ...}], "nextCursor": "eyJvZmZzZXQiOiAyfQ=="}}
  0.70s <-- {"jsonrpc": "2.0", "id": 51, "result": {"tools": [{"name": "disk_report", ...}, {"name": "slow_scan", ...}], "nextCursor": "eyJvZmZzZXQiOiA0fQ=="}}
  1.00s <-- {"jsonrpc": "2.0", "id": 52, "result": {"tools": [{"name": "confirm_restart", ...}]}}
  1.30s <-- {"jsonrpc": "2.0", "id": 53, "error": {"code": -32602, "message": "Invalid cursor", "data": {"cursor": "page-2"}}}
```

3. Decode a cursor you were never supposed to decode, to see why the rule exists:

```bash
echo 'eyJvZmZzZXQiOiAyfQ==' | base64 -d; echo
```

```
{"offset": 2}
```

4. Write the loop the way a client must write it, and notice it never mentions page size:

```python
def list_all_tools(call):
    """call(method, params) -> result dict. Walk every page, trusting nothing but nextCursor."""
    tools, cursor = [], None
    while True:
        params = {"cursor": cursor} if cursor is not None else {}
        result = call("tools/list", params)
        tools.extend(result["tools"])
        cursor = result.get("nextCursor")
        if cursor is None:
            return tools
```

### Questions — 7

1. Page 3 came back with no `nextCursor` at all. Why is that the correct end-of-list signal, and what would an empty-string cursor have implied instead?
2. You just base64-decoded a cursor and found an offset. Why is a client that relies on that observation guaranteed to break eventually?
3. Which side chooses the page size, and may it change between pages of the same walk?
4. An invalid cursor produced `-32602`. Why that code rather than an empty result page?
5. Which MCP list operations follow this same cursor pattern? What must a client do when `notifications/tools/list_changed` arrives halfway through a paginated walk?

---

## Exercise 8 — The reverse direction: server-initiated requests

A server is a peer, not a responder. It may send *requests* to the client — `elicitation/create` for a human, `sampling/createMessage` for the model, `roots/list` for the workspace. Handling those is response handling in the other direction.

### Steps

1. Call the tool and answer the server's question yourself. The server allocates its own ids starting at `1001`, so the reply can be scripted:

```bash
cat > 08-elicit.txt <<'EOF'
{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"confirm_restart","arguments":{"service":"nginx"}}}
sleep 0.5
{"jsonrpc":"2.0","id":1001,"result":{"action":"accept","content":{"confirm":true,"reason":"maintenance window 02:00"}}}
sleep 0.5
{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"confirm_restart","arguments":{"service":"postgres"}}}
sleep 0.5
{"jsonrpc":"2.0","id":1002,"result":{"action":"decline"}}
EOF

WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 08-elicit.txt
```

2. Expected output (handshake omitted):

```
  0.40s --> {"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"confirm_restart","arguments":{"service":"nginx"}}}
  0.40s <-- {"jsonrpc": "2.0", "id": 1001, "method": "elicitation/create", "params": {"message": "Restart nginx? This drops in-flight connections.", "requestedSchema": {"type": "object", "properties": {"confirm": {"type": "boolean", "title": "Confirm restart"}, "reason": {"type": "string", "title": "Change reason", "maxLength": 120}}, "required": ["confirm"]}}}
  0.90s --> {"jsonrpc":"2.0","id":1001,"result":{"action":"accept","content":{"confirm":true,"reason":"maintenance window 02:00"}}}
  0.90s <-- {"jsonrpc": "2.0", "id": 60, "result": {"content": [{"type": "text", "text": "restarted nginx; reason on record: maintenance window 02:00"}]}}
  1.40s <-- {"jsonrpc": "2.0", "id": 1002, "method": "elicitation/create", "params": {"message": "Restart postgres? This drops in-flight connections.", "requestedSchema": {...}}}
  1.90s --> {"jsonrpc":"2.0","id":1002,"result":{"action":"decline"}}
  1.90s <-- {"jsonrpc": "2.0", "id": 61, "result": {"content": [{"type": "text", "text": "postgres left running; the human answered 'decline'"}]}}
```

3. Now re-run the same tool call from a client that declared no capabilities:

```bash
cat > 00-init-nocaps.txt <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bare-client","version":"0.1.0"}}}
sleep 0.2
{"jsonrpc":"2.0","method":"notifications/initialized"}
sleep 0.2
EOF

printf '%s\n' '{"jsonrpc":"2.0","id":62,"method":"tools/call","params":{"name":"confirm_restart","arguments":{"service":"redis"}}}' > 08-nocaps.txt
WAIT=1 .venv/bin/python drive.py tiny_server.py 00-init-nocaps.txt 08-nocaps.txt
```

```
  0.40s <-- {"jsonrpc": "2.0", "id": 62, "result": {"content": [{"type": "text", "text": "This tool needs the elicitation capability, which this client did not declare."}], "isError": true}}
```

4. Study the other reversal. A server that wants the *model* to do something sends this, and the client answers with a `role`/`content`/`model`/`stopReason` object:

```json
{
  "jsonrpc": "2.0",
  "id": 1003,
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": { "type": "text", "text": "Summarise this kubelet log in three bullets." }
      }
    ],
    "systemPrompt": "You are an SRE assistant. Be terse.",
    "includeContext": "thisServer",
    "modelPreferences": {
      "hints": [{ "name": "claude-sonnet" }],
      "intelligencePriority": 0.8,
      "speedPriority": 0.4,
      "costPriority": 0.3
    },
    "maxTokens": 300,
    "temperature": 0.2
  }
}
```

### Questions — 8

1. Line 2 of the output is a message from the server that carries both an `id` and a `method`. Which of the three message shapes is it, and what does that force the client to do?
2. `decline` and `cancel` are both non-acceptances. What does each one mean to the user, and why does the protocol separate them from an `error` response?
3. The `requestedSchema` is a flat object of primitives. Why does elicitation restrict the schema that way, when `inputSchema` on a tool has no such restriction?
4. Step 3 returned `isError: true` rather than a JSON-RPC error. Was that the right call by the server author? What earlier message made the outcome predictable?
5. In `modelPreferences`, `hints` are hints. Who picks the actual model, and what human-in-the-loop expectation does the specification place on sampling?
6. Why must a server never put credentials or private data in `sampling/createMessage` params without thinking hard first?

---

## Exercise 9 — Response handling over Streamable HTTP

Over stdio the transport is a pipe and every response looks alike. Over HTTP the transport has opinions: status codes, content negotiation, sessions, and two different ways to deliver the same JSON-RPC response.

### Steps

1. Write and start an SDK-based HTTP server:

```python
#!/usr/bin/env python3
"""http_server.py - the same ideas, over the Streamable HTTP transport."""
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("http-demo", host="127.0.0.1", port=8931)


@mcp.tool()
def add(a: int, b: int) -> int:
    """Add two integers."""
    return a + b


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
```

```bash
.venv/bin/python http_server.py &
sleep 2
```

2. POST an `initialize` with the wrong `Accept` header. The transport rejects it before any JSON-RPC handling happens:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"8"}}}'
```

```
406
```

3. Do it correctly and keep the session id. Note both `Accept` types:

```bash
SESSION=$(curl -s -N -D /tmp/h.txt -o /tmp/b.txt -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"8"}}}' \
  ; awk -F': ' 'tolower($1)=="mcp-session-id" {print $2}' /tmp/h.txt | tr -d '\r')
grep -iE '^(HTTP/|content-type|mcp-session-id)' /tmp/h.txt; echo "SESSION=$SESSION"; cat /tmp/b.txt
```

Expected shape (exact header casing and the uuid vary):

```
HTTP/1.1 200 OK
content-type: text/event-stream
mcp-session-id: 3f6c1a5e9b7d4c02a1e8f5d3c9b7a6e4
SESSION=3f6c1a5e9b7d4c02a1e8f5d3c9b7a6e4
event: message
data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{},"tools":{"listChanged":false}},"serverInfo":{"name":"http-demo","version":"1.x.y"}}}
```

4. Send the `initialized` notification and read the status code, not the body:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

```
202
```

5. Call the tool and watch the response arrive as an SSE event rather than a JSON body:

```bash
curl -s -N -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23}}}'
```

```
event: message
data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"42"}],"structuredContent":{"result":42},"isError":false}}
```

6. Break the session on purpose, three ways:

```bash
# a) claim a protocol revision the server does not support
curl -s -o /dev/null -w 'bad version   -> %{http_code}\n' -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" -H 'MCP-Protocol-Version: 1999-01-01' \
  -d '{"jsonrpc":"2.0","id":3,"method":"ping"}'

# b) drop the session header entirely
curl -s -o /dev/null -w 'no session    -> %{http_code}\n' -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":4,"method":"ping"}'

# c) terminate the session, then try to keep using it
curl -s -o /dev/null -w 'delete        -> %{http_code}\n' -X DELETE http://127.0.0.1:8931/mcp \
  -H "Mcp-Session-Id: $SESSION" -H 'MCP-Protocol-Version: 2025-06-18'
curl -s -o /dev/null -w 'after delete  -> %{http_code}\n' -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":5,"method":"ping"}'
```

Expected shape (`4xx` values are what matters; the precise code for *(b)* is implementation-dependent and the wording of the error bodies varies by SDK version):

```
bad version   -> 400
no session    -> 400
delete        -> 200
after delete  -> 404
```

7. Stop the server: `kill %1`.

### Questions — 9

1. Step 2 returned `406` with no JSON-RPC error object anywhere. Which layer rejected the call, and what exactly must a client's `Accept` header contain?
2. Step 4 returned `202` and an empty body. Derive that from the content of the POST — what property of the payload makes a body impossible?
3. Step 5's answer came back as `event: message` / `data: {...}`. Under the Streamable HTTP transport, what are the two legal ways to return that same JSON-RPC response, and who chooses?
4. `Mcp-Session-Id` appeared on the `initialize` response and had to be echoed on every later request. What is a client required to do when it gets `404` for a session id it believes is valid — and what must it *not* do?
5. Why did the `2025-06-18` revision add a `MCP-Protocol-Version` HTTP header when the version is already negotiated inside `initialize`?
6. SSE events carry an `id:` field. Which header resumes a dropped stream, and what does the server owe the client about the events it replays?
7. A colleague proposes binding this server to `0.0.0.0` so teammates can use it. Name two things that must be in place first.

---

## Exercise 10 — Breaking it on purpose: production diagnostics

Every failure below has been seen in a real MCP deployment. Reproduce each one, then read the symptom as a client author would.

### Steps

1. **Poison stdout.** Add a stray `print()` inside `do_tools_call` in `tiny_server.py`, just after the `tool is None` check:

```python
    print(f"DEBUG calling {name}")   # WRONG on purpose: this is the MCP stream
```

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":70,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}' > 10-poison.txt
WAIT=1 .venv/bin/python drive.py tiny_server.py 00-init.txt 10-poison.txt
```

```
  0.40s --> {"jsonrpc":"2.0","id":70,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}
  0.40s <-- DEBUG calling echo
  0.40s <-- {"jsonrpc": "2.0", "id": 70, "result": {"content": [{"type": "text", "text": "hello"}], "isError": false}}
```

A real client reads line 1, fails to parse it, and — depending on its hardening — either logs a parse error or kills the connection. **Remove the `print` before continuing.**

2. **Embed a newline in a message.** Send one logical message split across two lines:

```bash
cat > 10-newline.txt <<'EOF'
{"jsonrpc":"2.0","id":71,
"method":"ping"}
{"jsonrpc":"2.0","id":72,"method":"ping"}
EOF

WAIT=1 .venv/bin/python drive.py tiny_server.py 00-init.txt 10-newline.txt
```

Two parse errors, then `72` answers normally.

3. **Silence.** Comment out the `reply(...)` call at the end of `run_slow_scan`'s `worker()`, and call it:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2},"_meta":{"progressToken":"t"}}}' > 10-silent.txt
WAIT=4 .venv/bin/python drive.py tiny_server.py 00-init.txt 10-silent.txt
```

Progress arrives, the result never does, and the process sits there forever. **Restore the `reply(...)` call.**

4. **Turn the volume down.** Use the logging utility to suppress the debug chatter, and confirm progress is unaffected:

```bash
cat > 10-loglevel.txt <<'EOF'
{"jsonrpc":"2.0","id":74,"method":"logging/setLevel","params":{"level":"warning"}}
sleep 0.3
{"jsonrpc":"2.0","id":75,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2},"_meta":{"progressToken":"quiet"}}}
sleep 1.5
{"jsonrpc":"2.0","id":76,"method":"logging/setLevel","params":{"level":"loud"}}
EOF

WAIT=2 .venv/bin/python drive.py tiny_server.py 00-init.txt 10-loglevel.txt
```

```
  0.40s <-- {"jsonrpc": "2.0", "id": 74, "result": {}}
  0.70s --> {"jsonrpc":"2.0","id":75,"method":"tools/call","params":{"name":"slow_scan","arguments":{"steps":2},"_meta":{"progressToken":"quiet"}}}
  1.20s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "quiet", "progress": 1, "total": 2, "message": "scanned 1/2 shards"}}
  1.70s <-- {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "quiet", "progress": 2, "total": 2, "message": "scanned 2/2 shards"}}
  1.70s <-- {"jsonrpc": "2.0", "id": 75, "result": {"content": [{"type": "text", "text": "scan finished: 2 shards, 0 findings"}], "isError": false}}
  2.20s <-- {"jsonrpc": "2.0", "id": 76, "error": {"code": -32602, "message": "Invalid cursor", ...}}
```

(The last line's exact error is `-32602 Unknown log level` — read your own output.)

5. **Use the real tool.** Point the MCP Inspector at the same server and compare its traffic pane to what you have been reading by hand:

```bash
npx @modelcontextprotocol/inspector .venv/bin/python tiny_server.py
```

And the non-interactive form, useful in CI:

```bash
npx @modelcontextprotocol/inspector --cli .venv/bin/python tiny_server.py --method tools/list
```

### Questions — 10

1. A user reports: "the server works when I run it in the terminal, but the client shows no tools at all." Given step 1, what is the first thing you check, and where should that server's diagnostics have gone?
2. Step 2 produced two parse errors from one intended message. State the stdio framing rule that was violated, in terms of both newlines and encoding.
3. In step 3 the client hung. Name the two mechanisms that exist to stop that from being an infinite hang, and say which side owns each.
4. Progress notifications survived `logging/setLevel warning` while `notifications/message` did not. Explain why one is filterable by level and the other is not.
5. Both `logging/setLevel` and a tool failure can produce `-32602`. In a client's code, what distinguishes "the user typed a bad level" from "the tool blew up"?
6. The Inspector shows you the same JSON you have been reading. Name one thing it gives you that `drive.py` structurally cannot.

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Answers — 0

1. **stdio has exactly one channel for protocol messages: the server's stdout.** The transport specification states that the server MUST NOT write anything to stdout that is not a valid MCP message, and that it MAY use stderr for logging. A `print()` to stdout is indistinguishable from a protocol frame: the client's line reader will try to parse it as JSON and fail. stderr is out of band and is normally captured to the client's own log. This is the single most common way a working server appears broken.

2. JSON-RPC 2.0 has **no ordering guarantee** — a receiver may process requests concurrently and respond in any order, which is why concurrency is legal. What makes it survivable is the **`id` field**: the response carries back the id of the request it answers, so the requester can correlate regardless of arrival order. Without the id, concurrency would be unusable.

3. Capabilities are the **contract for what may be called**, agreed once during `initialize`. A client that sees no `resources` capability must not call `resources/list`, `resources/read` or `resources/subscribe` at all — not "try and handle the error". It concludes this at the moment it receives the `initialize` result, before it sends any other request. The `listChanged: true` sub-capability additionally tells the client that this server will send `notifications/tools/list_changed`, so the client should not poll.

### Answers — 1

1. **A message with a `method` and an `id` is a request and MUST be answered exactly once; a message with a `method` and no `id` is a notification and MUST NEVER be answered.** `initialize`, `ping` and `resources/list` had ids; `notifications/initialized` and the invented notification did not.

2. A JSON-RPC response is a success if and only if it has a `result` member (and no `error`). `{}` is a perfectly good `result` — it is the *empty success* that `ping` is specified to return. `"result": null` would also technically be a success in JSON-RPC, but MCP result types are objects, so a client expecting an object could break on `null`; `{}` is the conformant form. What matters for the exam: **the presence of `result` versus `error` decides success, not the contents of `result`.**

3. **The client decides.** Per the lifecycle spec, the server responds with a version it supports (either the one requested, or its own latest). If the client does not support the version the server came back with, the client SHOULD disconnect. The server is not obliged to error out — offering a version it can actually speak is the more useful answer.

4. Before sending `notifications/initialized`, the client MUST NOT send requests other than pings (and may not treat the session as usable); before receiving it, the server MUST NOT send requests other than pings and logging notifications. `initialize` → `initialize` result → `notifications/initialized` is a three-step handshake, and the third step has no response precisely because it is the client asserting readiness, not asking anything.

### Answers — 2

1. **Conformant.** JSON-RPC explicitly permits out-of-order responses, and MCP inherits that. The client's only legitimate correlation mechanism is the `id` it chose: it keeps a map from id to pending call and resolves on arrival. Correlating by arrival order, by method name, or by "the last thing I sent" is a bug that only shows up under concurrency — which is exactly when it matters.

2. The id must be unique **for the lifetime of the session, per requester direction** — the client's id space and the server's id space are independent, which is why `tiny_server.py` can use `1001` for its own requests while the client uses `60`. Reuse too early and the receiver sees a duplicate id: a conformant receiver rejects the second request, and a sloppy one resolves the wrong pending call, delivering one call's result to a different call's continuation. That is a silent data-correctness bug, not a crash.

3. **MCP forbids `null` as a request id** (the base-protocol spec states the id MUST NOT be `null`, tightening plain JSON-RPC). `tiny_server.py` answered it because it is a toy; a conformant server should reject it. `"id": null` is legitimate in exactly one place: an **error response to a message that could not be parsed or whose id could not be determined** — the `-32700` case from Exercise 3.

4. The dispatcher decided "notification" from the *truthiness* of the id rather than the *presence of the key*. In JSON, `0`, `""` and `null` are all falsy but all present, so a request with `id: 0` was routed to the notification handler and never answered. A client with the same bug behaves worse: it sees an incoming response whose id is `0`, treats it as "no id", can't match it to a pending call, and drops it — the caller's promise never resolves, so the symptom is a hang, not an error. Always test **key presence** (`"id" in message`), never truthiness.

### Answers — 3

1. Because the model, not the client, is the one that can fix it. A `-32603` would be caught by the client's transport layer and surfaced as an infrastructure failure the model never sees. `isError: true` with a human-readable `content` block is delivered **into the conversation**: the model reads "division by zero, pass a non-zero denominator", and retries with a corrected argument. The rule: **errors that the model can act on are tool results; errors that mean the call never happened are protocol errors.**

2. The method *is* `tools/call`, and it exists and is offered. What is wrong is the value of `params.name`. That is a parameter validation failure, so `-32602` (Invalid params) is the right code; `-32601` would falsely tell the client that `tools/call` itself is unsupported, which could make the client stop using tools entirely. The tools specification names unknown-tool explicitly as a protocol error of this kind.

3. Two things break. (a) **The model is blinded** — it never learns that the tool failed or why, so it cannot self-correct; the client sees a transport-level fault instead. (b) **Legitimate protocol errors become indistinguishable from business failures** — a genuinely malformed request and a failing API call both arrive as `-32603`, so retry logic, telemetry and user messaging can no longer be differentiated. In practice you also lose the difference between "retry this" and "never retry this".

4. Only if the stream can no longer be resynchronized — for example, a framing violation where the client cannot tell where the next message begins, or repeated parse errors suggesting the peer is writing non-protocol data to the stream (the stdout-poisoning case). A single bad frame on a line-delimited transport is recoverable, and the session should continue; a client should also apply a sanity limit so a peer spewing garbage cannot keep it busy forever.

5. To the **model**: the `divide` by-zero result — it is a normal step in a tool-use loop. To the **user** (and the logs): `-32601`, `-32602` on an unknown tool, and `-32700`, because they indicate a broken or mismatched client/server pair that the model cannot fix by rewording arguments. `-32602` for bad *arguments* is the ambiguous one — a good client surfaces it to the model too, because the model generated those arguments and can correct them.

### Answers — 4

1. **Not a bug — it is what the specification asks for.** For backwards compatibility, a tool that returns `structuredContent` SHOULD also return the serialized JSON in a `text` content block, because clients written before structured output existed only read `content`. Drop the `text` block and an older client renders an empty result; drop `structuredContent` and a schema-aware client loses the typed value. Keep both.

2. `outputSchema` declares that this tool's `structuredContent` will conform to that JSON Schema. **Servers MUST produce conforming output and clients SHOULD validate it.** A violation is the server's fault, so it is reported as a protocol error (`-32602` in many implementations, or an SDK-defined code) — not as a tool result, because there is nothing the model could rewrite to fix it.

3. `resource_link` is a *pointer*: the URI of something the client may fetch later with `resources/read`, subject to the client's own access rules. An embedded `resource` block carries the bytes **inline, in this response**. For a 40 MB log, return a `resource_link`: an embedded resource would have to be base64-encoded into the response, would blow the context window, and would be paid for whether or not anyone looks at it. Embed small, immediately relevant payloads only.

4. `annotations.audience` is a hint about who the block is for — `"user"`, `"assistant"`, or both — alongside `priority` (0 to 1) and `lastModified`. A client uses it to decide what to render in the UI versus what to feed the model. It is **advisory, not binding**: a client may ignore it, so a server must never rely on `audience` for anything security-relevant.

5. Because `isError` describes the *outcome of the tool*, not the shape of the payload. A tool can fail and still have well-formed structured data to report about the failure (an error code, a retry-after, the partial results it did gather). Note the reverse asymmetry: a client that only checks `isError` and ignores `content` gives the model nothing to act on.

### Answers — 5

1. The **`method` name** differs, but the routable difference is inside `params`: a progress notification is keyed by `progressToken` and carries the numeric `progress`/`total` pair, so it is correlated back to a specific in-flight request. `notifications/message` carries `level`, `logger` and free-form `data` and is **not tied to any request at all** — it is ambient server logging. One updates a specific operation's UI; the other goes to a log.

2. **The client's**, by omitting `_meta.progressToken` from the request. Progress is opt-in per request: a server MUST NOT send progress notifications for a request that did not supply a token. This is deliberate — it keeps servers from flooding clients that have nowhere to display progress.

3. Because the token is chosen by the requester and is deliberately decoupled from id allocation: it is an opaque `string` or `integer` the client picks (`"scan-30"` or `991`, both valid, both echoed verbatim). That lets the client route progress to a UI element without exposing or entangling its id-allocation scheme, keeps the token stable if the client retries under a new id, and keeps the ephemeral request id out of longer-lived UI state.

4. Without `total` the client must render **indeterminate** progress — a spinner or a rising counter, never a percentage, because there is no denominator. The invariant that still holds: **`progress` MUST increase with every notification** for a given token, even when `total` is unknown. A client that sees progress go backwards is talking to a non-conformant server.

5. Ignore it. The specification is permissive on the receiving side: a receiver MAY ignore progress for unknown or already-completed tokens. It must not crash, must not resurrect a completed operation's UI, and must not treat it as a protocol violation worth ending the session over.

### Answers — 6

1. **Not broken — that is the specified behaviour.** Once a request is cancelled, the receiver SHOULD stop processing and SHOULD NOT send a response for it. The client must **release the id and its pending-call entry** as part of sending the cancellation, because nothing will ever arrive to release it. A client that only frees pending calls on response leaks one entry per cancellation.

2. A notification gets no response, so the sender **receives no acknowledgement that the cancellation was seen or honoured**. It therefore cannot assume the work stopped: the receiver may have already finished, may be in an uninterruptible section, or may ignore the cancellation entirely. Cancellation is best-effort by construction, and the client must design its UI for "probably stopping" rather than "stopped".

3. **The `initialize` request.** Cancelling it would leave the session in an undefined state — neither initialized nor cleanly failed — with no agreed protocol version under which to interpret anything that follows. The cancellation utility calls this out explicitly.

4. **Ignore it.** The sender of a cancellation MUST ignore any response that arrives afterwards for that request id. The race is unavoidable on an asynchronous transport, so the rule makes it harmless: the late result does not resolve a promise the client already abandoned, and it certainly does not get injected into the conversation.

5. They are complementary and both are the requester's responsibility. Implementations SHOULD set timeouts on every request; on expiry the client SHOULD issue `notifications/cancelled` and stop waiting. A client **MAY reset its timeout when a progress notification arrives** for that request — that is one of the purposes of progress — but it **SHOULD still enforce a maximum total timeout** regardless of activity, so a server that emits progress forever cannot pin a client's resources indefinitely.

### Answers — 7

1. **`nextCursor` absent means there are no more pages.** That is the specified end condition, and it is unambiguous: the field is either there or it isn't. An empty string would be a *present* cursor, so a conformant client would dutifully request the next page with `"cursor": ""` — an infinite loop or a `-32602`, depending on the server. Never signal end-of-list with a falsy cursor value.

2. Because **cursors are opaque by contract**: clients MUST NOT parse, construct, or make assumptions about them. This server encodes an offset today; tomorrow it may encode a keyset, a snapshot id with an expiry, or a signed token. A client that decodes and increments offsets silently breaks on the next server release — and, worse, may skip or duplicate entries in the interim. The only legal operation on a cursor is handing it straight back.

3. **The server**, and yes — page size is server-determined and may vary between pages, even within the same walk. That is why the client loop in step 4 never mentions a limit: it terminates on `nextCursor`, not on a count.

4. An invalid cursor means the *client sent a parameter the server cannot interpret* — a client bug, or an expired/foreign cursor. `-32602` says so. Returning an empty page would tell the client "you have reached the end", which is a lie that silently truncates the list; the client would show a partial tool set with no error anywhere.

5. `tools/list`, `resources/list`, `resources/templates/list`, and `prompts/list` all use the same `cursor`/`nextCursor` pattern. If `notifications/tools/list_changed` arrives mid-walk, the safest response is to **abandon the walk and restart from no cursor**: the existing cursor may reference a snapshot that no longer exists, and continuing risks a mix of stale and fresh entries. The notification exists so the client re-lists rather than polls.

### Answers — 8

1. It is a **request — from the server to the client**. MCP is symmetric: both peers may originate requests. The client is therefore obliged to answer it exactly once, with a `result` or an `error`, carrying the same id (`1001`). A client implemented as a pure request-sender, with no inbound request dispatch, will hang the server's tool call forever.

2. **`decline`** means the human saw the request and said no — a deliberate refusal that the model should treat as a real answer and adapt to. **`cancel`** means the human dismissed the prompt without deciding — closed the dialog, navigated away — which is not a "no" and may be worth re-asking later in a different form. Neither is an `error`, because nothing went wrong at the protocol level: the elicitation succeeded, and its outcome is the information. Reserve `error` for "I could not ask at all".

3. Because the **client** has to render the schema as a form, in its own UI, without knowing anything about the server. The specification restricts `requestedSchema` to a flat object of primitive properties (string, number, integer, boolean, enum) precisely so every client can render it with a handful of standard widgets. A tool's `inputSchema` has no such limit because its consumer is a language model, which needs no widgets. Nesting, `oneOf`, arrays of objects — all out.

4. **Yes, correct.** The capability is missing, so the elicitation can never happen — but that is a fact about the environment that the model should know, so it can pick a different path (say, report what it would have done rather than doing it). A JSON-RPC error would hide that from the model. It was predictable from the `initialize` params: `"capabilities": {}` declared no `elicitation`, and capabilities are the contract. A well-written server checks capabilities before advertising or attempting a feature, rather than firing a request the peer cannot answer.

5. **The client picks the model.** `hints` are advisory name substrings the client maps onto whatever it actually has; `costPriority`, `speedPriority` and `intelligencePriority` are normalized 0–1 weights that express the server's preference, and the client balances them against its own policy and billing. The specification's human-in-the-loop expectation is that clients SHOULD show the user the prompt before sending it and the completion before returning it, with the ability to modify or reject both. Practically: **a server cannot silently spend the user's tokens.**

6. Because the `messages`, `systemPrompt` and any `includeContext` data are sent to the client, which forwards them to a **third-party model provider**. Anything in there leaves the trust boundary — and `includeContext: "allServers"` widens that further by asking the client to attach context from *other* MCP servers the user has connected. Treat the sampling payload as published data, and keep credentials, tokens and personal data out of it.

### Answers — 9

1. The **HTTP transport layer** rejected it during content negotiation, before any JSON-RPC parsing — which is exactly why there is no JSON-RPC error object: there is no request to attach it to. On Streamable HTTP, a client's POST MUST include an `Accept` header listing **both `application/json` and `text/event-stream`**, because the server chooses between them per response and the client must be able to handle either.

2. The POST contained **only a notification** — no request, therefore no id, therefore no possible response to correlate. The spec says that when the input consists solely of responses or notifications, the server returns `202 Accepted` with no body. A client that waits for a JSON body after posting a notification will wait forever.

3. Either a single `Content-Type: application/json` body containing the JSON-RPC response, or a `Content-Type: text/event-stream` SSE stream that eventually delivers it as a `data:` event. **The server chooses**, per response — which is why the client must accept both. SSE is what makes it possible to interleave progress notifications, log messages, and server-to-client requests *before* the final result for the same call.

4. When it receives `404` for a session id, the client **MUST start a new session by sending a fresh `initialize` request** (and must not reuse the dead id). What it must *not* do is retry the same request with the same session id, or assume the server is down — `404` here means "this session no longer exists", which is a normal outcome after a server restart or an idle expiry. Note the session id must also be visible ASCII and is chosen by the server.

5. Because HTTP is stateless per request and requests can be routed to different processes, load-balanced, replayed, or proxied. The server handling request *n* may not be the one that ran `initialize`, so the negotiated version has to travel with each request. The `2025-06-18` rules: the client MUST send `MCP-Protocol-Version` on all requests after initialization; if the header is absent the server SHOULD assume `2025-03-26` for backwards compatibility; if it is present but unsupported, the server MUST respond `400 Bad Request`.

6. **`Last-Event-ID`.** A client that loses an SSE connection reconnects with `Last-Event-ID: <id of the last event it saw>`, and the server resumes by replaying the messages that would have been sent after that point **on that stream only** — it must not replay messages that belonged to a different stream. Event ids must therefore be globally unique per session per stream. This is the mechanism that makes a long-running tool call survive a flaky network.

7. At minimum: **`Origin` header validation** on every incoming request (to block DNS-rebinding attacks from a browser on someone's machine), and **authentication/authorization** on the endpoint — the transport spec says servers SHOULD implement proper auth and MUST validate `Origin`; the default guidance is to bind to `127.0.0.1` precisely because neither is present by default. A local MCP server exposed on `0.0.0.0` is a remote code execution surface with tool calls as the API.

### Answers — 10

1. Check whether the server writes anything to **stdout** that is not a protocol message — `print()`, a banner, a progress bar, a library that logs to stdout by default, a stray `console.log`. Those diagnostics belong on **stderr** (or, better for the client's benefit, in `notifications/message` once the session is initialized). The reason "it works in the terminal" is that a human reading the terminal happily ignores the extra line; a line-oriented JSON parser cannot.

2. On stdio, messages are **newline-delimited and a single message MUST NOT contain embedded newlines** — the newline *is* the frame delimiter, so a message split across lines becomes two invalid fragments. Messages are also UTF-8 encoded. If you need multi-line data (a log excerpt, a YAML manifest), put it inside a JSON string, where the newline is escaped as `\n` — JSON encoding handles this correctly for free, which is why `json.dumps` is safe and hand-built strings are not.

3. **Client-side timeouts** (the client SHOULD time out every request and then send `notifications/cancelled`) and **`ping`** (either peer may probe liveness and treat repeated failures as a dead connection, terminating and reconnecting). The client owns both of those — which is the point: a hung server cannot rescue you, so the requester must be the one holding the clock.

4. `logging/setLevel` sets a threshold that applies to `notifications/message`, whose `level` field comes from the syslog severity set (`debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`). **Progress notifications have no severity** — they are operational state belonging to one in-flight request, not log output — so there is nothing for a level filter to compare against. The correct way to stop receiving progress is to stop sending a `progressToken`.

5. The **request id**. `-32602` is a response to a specific request: id `76` was the `logging/setLevel` call, so the client's pending-call entry already knows which operation failed and can present it accordingly. This is the practical payoff of correlation from Exercise 2 — error codes are not self-describing, and the id is what gives them context. A tool blowing up, by contrast, usually arrives as a `result` with `isError: true`, not as `-32602` at all.

6. It exercises the parts of the protocol that require a **real client implementation** rather than a scripted one: it answers server-initiated requests (sampling, elicitation, `roots/list`) with an actual UI, it manages sessions and reconnection over Streamable HTTP, it performs the OAuth flow for authenticated remote servers, and it enforces capability negotiation honestly. `drive.py` can only send lines you wrote in advance — it can fake a response to `elicitation/create` only because you knew the id would be `1001`.

</details>