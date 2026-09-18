# MCPA 3.2 — Error Handling

## Guided Exercises

**Exam weight: 6.5%.** Every question in this domain reduces to one discipline: *knowing which of the two error channels a failure belongs to, and what the receiver is contractually allowed to do about it.* MCP is JSON-RPC 2.0 on a transport, and it deliberately splits failures into **protocol errors** (a JSON-RPC `error` object — the *host/client* handles it) and **tool execution errors** (a successful JSON-RPC `result` carrying `isError: true` — the *model* handles it). Collapsing those two into one is the single most common production defect in MCP servers: it makes agents silently give up on recoverable work, or retry things that will never succeed.

You will build a wire-level stdio server, a Streamable HTTP endpoint, and a client with a deadline, and then break each of them on purpose.

---

### Lab prerequisites

```bash
python3 --version          # 3.10 or newer
jq --version               # 1.6 or newer
curl --version | head -1
mkdir -p ~/mcp-errors-lab && cd ~/mcp-errors-lab
```

No SDK, no network, no API keys: everything is stdlib, so the wire format stays visible. That is the point — SDKs hide exactly the framing this topic examines.

---

## Exercise 1 — The two error channels

### Step 1.1 — Build the server

Create `errors_server.py`:

```python
#!/usr/bin/env python3
"""MCP-shaped stdio server, stdlib only: newline-delimited JSON-RPC 2.0.

Deliberately minimal so the wire format stays visible. Nothing but JSON-RPC
messages is ever written to stdout; all diagnostics go to stderr.
"""
import json
import sys

PROTOCOL_VERSION = "2025-06-18"

TOOLS = [
    {
        "name": "divide",
        "description": "Divide numerator by denominator. Returns the quotient.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "numerator": {"type": "number"},
                "denominator": {"type": "number"},
            },
            "required": ["numerator", "denominator"],
        },
    },
]

RESOURCES = {
    "file:///reports/q3.txt": "Q3 revenue: 4.2M\n",
}


def log(text):
    print(text, file=sys.stderr, flush=True)


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def ok(req_id, payload):
    return {"jsonrpc": "2.0", "id": req_id, "result": payload}


def fail(req_id, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": req_id, "error": err}


def tool_error(req_id, text):
    """A tool that ran and failed: a SUCCESSFUL result with isError=True."""
    return ok(req_id, {"content": [{"type": "text", "text": text}], "isError": True})


def call_tool(req_id, params):
    name = params.get("name")
    args = params.get("arguments") or {}
    if name != "divide":
        return fail(req_id, -32602, f"Unknown tool: {name}")

    num, den = args.get("numerator"), args.get("denominator")
    for key, value in (("numerator", num), ("denominator", den)):
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            return fail(req_id, -32602, f"Invalid params: '{key}' must be a number")

    if den == 0:
        return tool_error(
            req_id,
            "Division by zero: 'denominator' was 0. Retry with a non-zero denominator.",
        )
    return ok(req_id, {
        "content": [{"type": "text", "text": str(num / den)}],
        "structuredContent": {"quotient": num / den},
        "isError": False,
    })


def handle(msg):
    req_id = msg.get("id")
    method = msg.get("method")
    params = msg.get("params") or {}

    if method is None:
        return fail(req_id, -32600, "Invalid Request: missing 'method'")
    if req_id is None:
        log(f"notification received, no response will be sent: {method}")
        return None

    if method == "initialize":
        return ok(req_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}, "resources": {}},
            "serverInfo": {"name": "errors-lab", "version": "0.1.0"},
        })
    if method == "tools/list":
        return ok(req_id, {"tools": TOOLS})
    if method == "tools/call":
        return call_tool(req_id, params)
    if method == "resources/read":
        uri = params.get("uri")
        if uri not in RESOURCES:
            return fail(req_id, -32002, "Resource not found", {"uri": uri})
        return ok(req_id, {"contents": [
            {"uri": uri, "mimeType": "text/plain", "text": RESOURCES[uri]},
        ]})
    return fail(req_id, -32601, f"Method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            send(fail(None, -32700, "Parse error", {"detail": str(exc)}))
            continue
        try:
            response = handle(msg)
        except Exception as exc:                 # never let it escape the loop
            log(f"unhandled: {type(exc).__name__}: {exc}")
            send(fail(msg.get("id"), -32603, "Internal error"))
            continue
        if response is not None:
            send(response)


if __name__ == "__main__":
    main()
```

### Step 1.2 — Drive a session of five messages

```bash
cat > s1.jsonl <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"divide","arguments":{"numerator":10,"denominator":4}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"divide","arguments":{"numerator":10,"denominator":0}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"multiply","arguments":{"a":2,"b":3}}}
EOF

python3 errors_server.py < s1.jsonl 2>/dev/null \
  | jq -c '{id, ok: has("result"), isError: .result.isError, code: .error.code}'
```

Expected:

```
{"id":1,"ok":true,"isError":null,"code":null}
{"id":2,"ok":true,"isError":false,"code":null}
{"id":3,"ok":true,"isError":true,"code":null}
{"id":4,"ok":false,"isError":null,"code":-32602}
```

Now look at the full payloads for ids 3 and 4:

```bash
python3 errors_server.py < s1.jsonl 2>/dev/null | sed -n '3,4p' | jq .
```

**Questions**

- **Q1.1** Five messages went in and four came out. Which one produced no output, and which clause of JSON-RPC 2.0 makes that mandatory rather than an optimisation?
- **Q1.2** Request `3` (divide by zero) and request `4` (unknown tool) are both "the call did not work". Why does one come back as `result.isError` and the other as an `error` object? State the rule in terms of *who is expected to act on it*.
- **Q1.3** A teammate proposes returning `-32603 Internal error` for the divide-by-zero case "because it is cleaner". Describe the concrete behavioural regression this causes in an agent loop.
- **Q1.4** Request `2` returned `"isError": false` explicitly. Is that field required on a successful call? What does a client have to assume when it is absent?

---

## Exercise 2 — The JSON-RPC code space, end to end

### Step 2.1 — Send five malformed or impossible messages

The first line below is truncated on purpose (no closing brace), and the last has no `method`.

```bash
cat > s2.jsonl <<'EOF'
{"jsonrpc":"2.0","id":10,"method":"tools/list"
{"jsonrpc":"2.0","id":11,"method":"tools/liste"}
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"divide","arguments":{"numerator":10,"denominator":"four"}}}
{"jsonrpc":"2.0","id":13,"method":"resources/read","params":{"uri":"file:///reports/q4.txt"}}
{"jsonrpc":"2.0"}
EOF

python3 errors_server.py < s2.jsonl 2>/dev/null \
  | jq -c '[.id, .error.code, .error.message]'
```

Expected:

```
[null,-32700,"Parse error"]
[11,-32601,"Method not found: tools/liste"]
[12,-32602,"Invalid params: 'denominator' must be a number"]
[13,-32002,"Resource not found"]
[null,-32600,"Invalid Request: missing 'method'"]
```

### Step 2.2 — Inspect the `data` member

```bash
python3 errors_server.py < s2.jsonl 2>/dev/null | sed -n '4p' | jq '.error.data'
```

```
{
  "uri": "file:///reports/q4.txt"
}
```

**Questions**

- **Q2.1** Two responses carry `"id": null`. Why can the server not echo `10` for the first one, and what does JSON-RPC require when the id cannot be determined?
- **Q2.2** `-32002` is not one of the JSON-RPC pre-defined codes. Which range does it fall in, who owns that range, and what does MCP use it for?
- **Q2.3** The server rejected `"denominator": "four"` with `-32602` but rejected `0` with `isError`. Both are "bad input from the model's perspective". Justify the split using the tool's `inputSchema`.
- **Q2.4** Which of `code`, `message`, `data` are mandatory in a JSON-RPC error object, and what constrains what you may put in `data`?
- **Q2.5** A server returns `{"jsonrpc":"2.0","id":7,"result":{...},"error":{...}}`. Why is this invalid, and what should a strict client do with it?

---

## Exercise 3 — Writing tool errors a model can actually recover from

### Step 3.1 — Compare two messages for the same failure

```bash
python3 - <<'EOF' | jq .
import json

bad = {"content": [{"type": "text", "text": "Error"}], "isError": True}

good = {
    "content": [{"type": "text", "text":
        "rate_limited: the upstream billing API returned 429. "
        "Quota resets in 47s. Retry the same call after waiting, "
        "or call list_invoices with page_size<=50 to stay under the limit."}],
    "structuredContent": {"reason": "rate_limited", "retryAfterSeconds": 47,
                          "retryable": True},
    "isError": True,
}
print(json.dumps({"bad": bad, "good": good}))
EOF
```

### Step 3.2 — Prove that `structuredContent` does not replace `content`

Add a second tool to `errors_server.py` that returns *only* `structuredContent` on failure, then reason about what a text-only client renders.

**Questions**

- **Q3.1** A tool error message is placed into the model's context window. List the three properties an error string must have to be useful there, and say which one `"Error"` fails first.
- **Q3.2** Why must a tool result keep a human-readable `content` block even when `structuredContent` is present? What does the spec say about the relationship between the two?
- **Q3.3** Your tool calls an internal service that fails with `psycopg2.OperationalError: FATAL: password authentication failed for user "svc_mcp"`. Should that string be the tool error text? Give the reason in terms of both security and agent behaviour.
- **Q3.4** An agent calls `divide` with `denominator: 0`, reads the error, and retries with `denominator: 0` again — three times. Which side of the boundary is responsible for stopping this, and what mechanism stops it?

---

## Exercise 4 — Resource errors, and the trap of raising protocol errors from handlers

### Step 4.1 — Read a resource that exists, then one that does not

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":20,"method":"resources/read","params":{"uri":"file:///reports/q3.txt"}}' \
 '{"jsonrpc":"2.0","id":21,"method":"resources/read","params":{"uri":"file:///etc/shadow"}}' \
 | python3 errors_server.py 2>/dev/null | jq -c '[.id, (.error.code // "result")]'
```

```
[20,"result"]
[21,-32002]
```

### Step 4.2 — Ask the same question through a tool

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"read_report","arguments":{"uri":"file:///reports/q4.txt"}}}' \
 | python3 errors_server.py 2>/dev/null | jq -c '[.id, (.error.code // "result")]'
```

```
[22,-32602]
```

(The tool does not exist in this server — that is `-32602 Unknown tool`. Now imagine it did exist and its body did `raise ResourceNotFound(...)`.)

**Questions**

- **Q4.1** `resources/read` on a missing URI is a protocol error, but a *tool* that reads the same missing file should return `isError`. Why does the same underlying condition land on different channels?
- **Q4.2** A developer writes a tool handler that raises an exception on a missing file, and the SDK converts any uncaught exception into `-32603`. What does the agent lose compared to an `isError` result?
- **Q4.3** `file:///etc/shadow` got `-32002 Resource not found` rather than a permission error. Argue both sides: when is returning "not found" for a forbidden resource the right call, and when is it a deception that costs you debugging time?
- **Q4.4** Which MCP notification tells a client that the resource list changed, and why does a client that ignores it generate avoidable `-32002` responses?

---

## Exercise 5 — On stdio, stdout *is* the wire

### Step 5.1 — Build a client that matches responses by id

Create `probe_client.py`:

```python
#!/usr/bin/env python3
"""Tiny stdio client: one request, a hard deadline, cancellation on timeout."""
import json
import selectors
import subprocess
import sys
import time

TIMEOUT_S = 3.0


def main(server_cmd, request):
    proc = subprocess.Popen(server_cmd, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True, bufsize=1)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)

    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    deadline = time.monotonic() + TIMEOUT_S

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not sel.select(timeout=remaining):
            print(f"TIMEOUT after {TIMEOUT_S}s (-32001); sending notifications/cancelled")
            proc.stdin.write(json.dumps({
                "jsonrpc": "2.0", "method": "notifications/cancelled",
                "params": {"requestId": request["id"], "reason": "client deadline"},
            }) + "\n")
            proc.stdin.flush()
            break
        line = proc.stdout.readline()
        if not line:
            print("TRANSPORT CLOSED before a response arrived (-32000)")
            break
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            print("NOT JSON-RPC ON STDOUT (-32700):", line.rstrip())
            continue
        if msg.get("id") == request["id"]:
            print("MATCHED:", json.dumps(msg)[:120])
            break
        print("UNMATCHED, still waiting:", json.dumps(msg)[:120])

    proc.terminate()


if __name__ == "__main__":
    cmd = sys.argv[1:] or [sys.executable, "errors_server.py"]
    main(cmd, {"jsonrpc": "2.0", "id": 7, "method": "tools/list"})
```

```bash
python3 probe_client.py
```

```
MATCHED: {"jsonrpc": "2.0", "id": 7, "result": {"tools": [{"name": "divide", ...
```

### Step 5.2 — Add one innocent `print()`

```bash
cat > noisy_server.py <<'EOF'
#!/usr/bin/env python3
import errors_server

print("[boot] errors-lab ready, 1 tool loaded")   # goes to stdout: corrupts the stream
errors_server.main()
EOF

python3 probe_client.py python3 noisy_server.py
```

```
NOT JSON-RPC ON STDOUT (-32700): [boot] errors-lab ready, 1 tool loaded
MATCHED: {"jsonrpc": "2.0", "id": 7, "result": {"tools": [{"name": "divide", ...
```

### Step 5.3 — Fix it two ways

```bash
sed -i 's/^print("\[boot\]/print("[boot]/; s/1 tool loaded")$/1 tool loaded", file=__import__("sys").stderr)/' noisy_server.py
python3 probe_client.py python3 noisy_server.py
```

**Questions**

- **Q5.1** State the two stdio transport rules about stdout and stderr, exactly as the specification phrases them.
- **Q5.2** Our lab client *skipped* the junk line and kept going. Real clients often tear the session down instead. Which behaviour is safer, and why is "skip and continue" dangerous at the framing level?
- **Q5.3** Name three realistic sources of accidental stdout writes in a Python MCP server that a code review will not catch.
- **Q5.4** If the server wants the client to *see* that message rather than just log it locally, which MCP mechanism should it use, and what does that require during `initialize`?

---

## Exercise 6 — Streamable HTTP failure modes: 406, 400, 401, 404, 202

### Step 6.1 — Build the endpoint

Create `http_errors_server.py`:

```python
#!/usr/bin/env python3
"""Streamable HTTP endpoint reduced to its transport-level failure modes.

Not a full MCP server: just enough transport to make 406/400/401/404/202
reproducible from curl. `initialize` is intentionally left unauthenticated so
you can obtain a session id without running an OAuth flow.
"""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT = "127.0.0.1", 8931
SUPPORTED_VERSIONS = {"2025-06-18", "2025-03-26"}
DEFAULT_VERSION = "2025-03-26"        # assumed when the header is absent
SESSIONS = set()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[server] " + (fmt % args), file=sys.stderr, flush=True)

    def _reply(self, status, body=None, headers=None):
        payload = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        if payload:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        accept = self.headers.get("Accept", "")
        if "application/json" not in accept or "text/event-stream" not in accept:
            self._reply(406, {"error": "Accept must offer both application/json "
                                       "and text/event-stream"})
            return

        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            self._reply(400, {"jsonrpc": "2.0", "id": None,
                              "error": {"code": -32700, "message": "Parse error"}})
            return

        if msg.get("method") == "initialize":
            sid = uuid.uuid4().hex
            SESSIONS.add(sid)
            self.log_message("new session %s", sid)
            self._reply(200, {"jsonrpc": "2.0", "id": msg.get("id"), "result": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "http-errors-lab", "version": "0.1.0"}}},
                headers={"Mcp-Session-Id": sid})
            return

        version = self.headers.get("MCP-Protocol-Version") or DEFAULT_VERSION
        self.log_message("applying protocol version %s", version)
        if version not in SUPPORTED_VERSIONS:
            self._reply(400, {"error": "unsupported MCP-Protocol-Version",
                              "supported": sorted(SUPPORTED_VERSIONS)})
            return

        sid = self.headers.get("Mcp-Session-Id")
        if sid is None:
            self._reply(400, {"error": "Mcp-Session-Id header is required"})
            return
        if sid not in SESSIONS:
            self._reply(404, {"error": "session terminated or unknown"})
            return

        if not self.headers.get("Authorization"):
            self._reply(401, {"error": "invalid_token"}, headers={
                "WWW-Authenticate": 'Bearer resource_metadata='
                f'"http://{HOST}:{PORT}/.well-known/oauth-protected-resource"'})
            return

        if msg.get("id") is None:
            self._reply(202)
            return

        self._reply(200, {"jsonrpc": "2.0", "id": msg.get("id"),
                          "result": {"tools": []}})

    def do_DELETE(self):
        SESSIONS.discard(self.headers.get("Mcp-Session-Id"))
        self._reply(204)


if __name__ == "__main__":
    print(f"listening on http://{HOST}:{PORT}/mcp", file=sys.stderr)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
```

```bash
python3 http_errors_server.py &
sleep 1
```

### Step 6.2 — Forget the `Accept` header

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"0"}}}'
```

```
406
```

### Step 6.3 — Initialize correctly and capture the session id

```bash
SID=$(curl -sS -D - -o /dev/null -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab","version":"0"}}}' \
  | tr -d '\r' | awk -F': ' '/^Mcp-Session-Id:/ {print $2}')
echo "session=$SID"
```

### Step 6.4 — Walk the failure ladder

```bash
call() {   # $1 = label, rest = extra curl args
  local label="$1"; shift
  printf '%-34s -> %s\n' "$label" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8931/mcp \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        "$@" \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
}

call "no session header"        -H 'MCP-Protocol-Version: 2025-06-18'
call "unsupported version"      -H 'MCP-Protocol-Version: 2024-01-01' -H "Mcp-Session-Id: $SID"
call "no Authorization"         -H 'MCP-Protocol-Version: 2025-06-18' -H "Mcp-Session-Id: $SID"
call "authorized"               -H 'MCP-Protocol-Version: 2025-06-18' -H "Mcp-Session-Id: $SID" -H 'Authorization: Bearer lab-token'
call "version header omitted"   -H "Mcp-Session-Id: $SID" -H 'Authorization: Bearer lab-token'
```

```
no session header                  -> 400
unsupported version                -> 400
no Authorization                   -> 401
authorized                         -> 200
version header omitted             -> 200
```

Read the server's stderr for the last two lines — it logs which version it applied.

### Step 6.5 — Read the `WWW-Authenticate` challenge

```bash
curl -sS -D - -o /dev/null -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' | tr -d '\r' | grep -i '^www-authenticate'
```

```
WWW-Authenticate: Bearer resource_metadata="http://127.0.0.1:8931/.well-known/oauth-protected-resource"
```

### Step 6.6 — A notification over HTTP, then kill the session

```bash
curl -sS -o /dev/null -w 'notification  -> %{http_code}\n' -X POST http://127.0.0.1:8931/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-06-18' -H "Mcp-Session-Id: $SID" -H 'Authorization: Bearer lab-token' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

curl -sS -o /dev/null -w 'DELETE        -> %{http_code}\n' -X DELETE http://127.0.0.1:8931/mcp \
  -H "Mcp-Session-Id: $SID"

call "after termination"        -H 'MCP-Protocol-Version: 2025-06-18' -H "Mcp-Session-Id: $SID" -H 'Authorization: Bearer lab-token'
```

```
notification  -> 202
DELETE        -> 204
after termination                  -> 404
```

Stop the server when finished:

```bash
kill %1
```

**Questions**

- **Q6.1** Why is `400` correct for a missing `Mcp-Session-Id` but `404` correct for a session id the server no longer knows? What must the client do differently in each case?
- **Q6.2** Omitting `MCP-Protocol-Version` returned `200`, not an error. Explain the rule behind that, and why this "successful" outcome is the more dangerous of the two.
- **Q6.3** The notification returned `202 Accepted` with an empty body. Connect this to what you observed in Exercise 1, Step 1.2.
- **Q6.4** Trace what a spec-compliant client does after receiving the `WWW-Authenticate` header above. Name the document it fetches and the RFC that defines it.
- **Q6.5** `401` and `403` both mean "you may not do this". Which one should a client retry after refreshing a token, and which one should it surface to the user immediately?
- **Q6.6** Why does the transport return HTTP `400` for a JSON parse failure while carrying a `-32700` object in the body? Which layer is each status speaking to?

---

## Exercise 7 — Timeouts, cancellation, and id matching

### Step 7.1 — A server that never answers

```bash
python3 probe_client.py python3 -c 'import sys,time; sys.stdin.readline(); time.sleep(60)'
```

```
TIMEOUT after 3.0s (-32001); sending notifications/cancelled
```

### Step 7.2 — A server that answers with the wrong id *type*

```bash
sed -i 's/"id": req_id, "result": payload/"id": str(req_id), "result": payload/' errors_server.py
python3 probe_client.py
```

```
UNMATCHED, still waiting: {"jsonrpc": "2.0", "id": "7", "result": {"tools": [{"name": "divide", ...
TIMEOUT after 3.0s (-32001); sending notifications/cancelled
```

Revert:

```bash
sed -i 's/"id": str(req_id), "result": payload/"id": req_id, "result": payload/' errors_server.py
python3 probe_client.py
```

### Step 7.3 — Observe that a cancelled request may still complete

Add a print to the server's notification branch and re-run Step 7.1 against a server that logs both the cancellation and the eventual completion.

**Questions**

- **Q7.1** In Step 7.2 the server *did* reply, correctly, within milliseconds — and the call still failed. State the JSON-RPC id rule that was violated and why a JSON-agnostic proxy that "normalises" ids breaks every MCP session it touches.
- **Q7.2** `notifications/cancelled` carries `requestId` and `reason`. What is the receiver allowed to do about it, and what MUST the initiator do if a response for that id arrives anyway?
- **Q7.3** Which single request MUST NOT be cancelled by a client, and why would cancelling it leave the session in an undefined state?
- **Q7.4** MCP allows a client to reset its timeout clock when a progress notification arrives. What abuse does this enable, and which additional rule closes it?
- **Q7.5** `-32000` and `-32001` are used by the reference SDKs for "connection closed" and "request timeout". Are these protocol-defined MCP codes or implementation choices, and what follows from the answer for a client that hardcodes them?

---

## Exercise 8 — Classify before you retry

### Step 8.1 — Build the decision function

Create `retry.py`:

```python
#!/usr/bin/env python3
"""Classify an MCP failure, then retry only what is safe to retry."""
import random
import time

TRANSIENT_JSONRPC = {-32000, -32001}                       # closed, timed out
TERMINAL_JSONRPC = {-32700, -32600, -32601, -32602, -32002}
TRANSIENT_HTTP = {408, 429, 502, 503, 504}
TERMINAL_HTTP = {400, 401, 403, 404, 406, 422}


def is_retryable(code=None, status=None):
    """Protocol/transport failures only. A tool error (isError=true) is NOT a
    transport failure: it is a result, and the model decides what to do next."""
    if status in TRANSIENT_HTTP or code in TRANSIENT_JSONRPC:
        return True
    if status in TERMINAL_HTTP or code in TERMINAL_JSONRPC:
        return False
    return code == -32603          # internal error: bounded retry, once


def backoff(attempt, base=0.25, cap=8.0):
    """Exponential backoff with full jitter: sleep in [0, min(cap, base*2^n))."""
    return random.uniform(0, min(cap, base * 2 ** attempt))


class CircuitBreaker:
    def __init__(self, threshold=5, cooldown=30.0):
        self.threshold, self.cooldown = threshold, cooldown
        self.failures, self.opened_at = 0, None

    def allow(self):
        if self.opened_at is None:
            return True
        if time.monotonic() - self.opened_at >= self.cooldown:
            self.opened_at, self.failures = None, 0        # half-open: one probe
            return True
        return False

    def record(self, succeeded):
        if succeeded:
            self.failures, self.opened_at = 0, None
            return
        self.failures += 1
        if self.failures >= self.threshold:
            self.opened_at = time.monotonic()


if __name__ == "__main__":
    cases = [
        ("tools/call timed out",        dict(code=-32001)),
        ("unknown tool",                dict(code=-32602)),
        ("server restarted mid-call",   dict(code=-32000)),
        ("server internal error",       dict(code=-32603)),
        ("HTTP 429 from the gateway",   dict(status=429)),
        ("HTTP 401 expired token",      dict(status=401)),
        ("HTTP 404 session terminated", dict(status=404)),
    ]
    for label, kwargs in cases:
        print(f"{label:30} retryable={is_retryable(**kwargs)}")
    print("\nfull-jitter schedule:",
          [round(backoff(n), 3) for n in range(6)])
```

```bash
python3 retry.py
```

```
tools/call timed out           retryable=True
unknown tool                   retryable=False
server restarted mid-call      retryable=True
server internal error          retryable=True
HTTP 429 from the gateway      retryable=True
HTTP 401 expired token         retryable=False
HTTP 404 session terminated    retryable=False

full-jitter schedule: [0.203, 0.409, 0.717, 1.688, 3.106, 5.51]
```

### Step 8.2 — Run it twice and compare the schedules

```bash
python3 retry.py | tail -1
python3 retry.py | tail -1
```

**Questions**

- **Q8.1** `401` and `404` are marked non-retryable, yet both have a well-defined recovery in MCP. Describe the recovery for each, and explain why "not retryable" is still the correct classification for a blind retry loop.
- **Q8.2** Why does the schedule differ between runs, and what failure mode does that randomness prevent when 400 agent sessions lose the same upstream at the same instant?
- **Q8.3** `-32603` is treated as retryable-once. Defend that choice, then give the case where it is wrong and the retry causes real damage.
- **Q8.4** The circuit breaker goes half-open and lets exactly one request through. What breaks if it lets all queued requests through at once?
- **Q8.5** A `429` response carries `Retry-After: 47`. Which wins, that header or `backoff()`? Why?
- **Q8.6** Your `tools/call` invokes `create_refund`. The transport times out with `-32001`. Is retrying safe? What must the tool provide before it is?

---

## Exercise 9 — Error hygiene: what must never travel in a message

### Step 9.1 — Two payloads for one exception

```bash
cat > leak_demo.py <<'EOF'
#!/usr/bin/env python3
"""Same failure, two error payloads: one leaks, one does not."""
import sys
import traceback
import uuid

DSN = "postgresql://svc_mcp:S3cr3t-p4ss@db.internal:5432/billing?sslmode=require"


def connect(dsn):
    raise ConnectionRefusedError(f"could not connect to server: {dsn}")


def naive():
    try:
        connect(DSN)
    except Exception as exc:
        return {"code": -32603, "message": str(exc),
                "data": {"traceback": traceback.format_exc()}}


def safe():
    try:
        connect(DSN)
    except Exception:
        incident = uuid.uuid4().hex[:12]
        print(f"[incident {incident}] {traceback.format_exc()}",
              file=sys.stderr, end="")
        return {"code": -32603, "message": "Internal error reaching the billing store",
                "data": {"incidentId": incident, "retryable": True}}


if __name__ == "__main__":
    print("NAIVE:", naive()["message"])
    print("SAFE :", safe()["message"])
EOF

python3 leak_demo.py 2>/dev/null
```

```
NAIVE: could not connect to server: postgresql://svc_mcp:S3cr3t-p4ss@db.internal:5432/billing?sslmode=require
SAFE : Internal error reaching the billing store
```

### Step 9.2 — See where the detail actually went

```bash
python3 leak_demo.py 1>/dev/null
```

**Questions**

- **Q9.1** List every party that can read the `NAIVE` message once it is returned over MCP. Include the ones that are not human.
- **Q9.2** Why is a traceback inside `error.data` worse in an MCP server than in a plain REST API? Frame the answer around prompt injection and context exfiltration.
- **Q9.3** The `SAFE` variant returns `incidentId`. What operational capability does that preserve, and what must exist on the server side for it to be worth anything?
- **Q9.4** `"retryable": true` is machine-readable and sits in `data`. Who consumes it — the model, the client, or both? Justify.
- **Q9.5** Apply the same question to a *tool* error (`isError: true`). Does the hygiene rule change, and if so, in which direction?

---

## Reference tables

### Error code space

| Code | Name | Origin | Typical MCP trigger |
|---|---|---|---|
| `-32700` | Parse error | JSON-RPC | Non-JSON on the wire; stray stdout write on stdio |
| `-32600` | Invalid Request | JSON-RPC | Missing `method`, missing `jsonrpc`, malformed envelope |
| `-32601` | Method not found | JSON-RPC | Method the server does not implement or did not advertise |
| `-32602` | Invalid params | JSON-RPC | Unknown tool name; arguments that violate `inputSchema` |
| `-32603` | Internal error | JSON-RPC | Uncaught exception in the server |
| `-32002` | Resource not found | MCP, server range | `resources/read` on an unknown URI |
| `-32000`…`-32099` | Server-defined | JSON-RPC reserves; implementation assigns | SDK conventions: `-32000` connection closed, `-32001` request timeout |

### Which channel?

| Condition | Channel | Who acts |
|---|---|---|
| Malformed message, unknown method, unknown tool, schema violation | JSON-RPC `error` | Client / host |
| Missing or forbidden resource via `resources/read` | JSON-RPC `error` (`-32002`) | Client / host |
| Tool executed and the *operation* failed (API 500, no results, business rule) | `result` with `isError: true` | The model |
| Tool executed and returned nothing useful but validly | `result`, `isError` absent/false | The model |
| Transport died, deadline expired | JSON-RPC `error` (`-32000`/`-32001`) or transport-level | Client / host |

### Streamable HTTP statuses

| Status | Meaning | Correct client reaction |
|---|---|---|
| `202` | Notification or response accepted, no body | Continue; expect nothing back |
| `400` | Missing session id when required; unsupported `MCP-Protocol-Version`; unparseable body | Fix the request; do not retry unchanged |
| `401` | No or invalid token; carries `WWW-Authenticate` | Discover the authorization server, obtain a token, retry once |
| `403` | Valid token, insufficient scope | Do not retry; surface to the user |
| `404` | Session terminated or unknown | Re-`initialize` **without** a session id, then replay |
| `405` | Server does not allow client-initiated `DELETE`/`GET` | Accept it; do not treat as an error |
| `406` | `Accept` did not offer both `application/json` and `text/event-stream` | Fix the header |
| `429` | Rate limited | Honour `Retry-After`, then jittered backoff |

---

## Sources

- Model Context Protocol specification, Base protocol: <https://modelcontextprotocol.io/specification/2025-06-18/basic>
- MCP Transports (stdio and Streamable HTTP, session and header rules): <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- MCP Lifecycle (version negotiation, initialization): <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>
- MCP Server features — Tools (`isError`, protocol vs execution errors): <https://modelcontextprotocol.io/specification/2025-06-18/server/tools>
- MCP Server features — Resources (`-32002`): <https://modelcontextprotocol.io/specification/2025-06-18/server/resources>
- MCP Utilities — Cancellation: <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation>
- MCP Utilities — Progress: <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress>
- MCP Server utilities — Logging (`notifications/message`, RFC 5424 levels): <https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/logging>
- MCP Authorization: <https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization>
- JSON-RPC 2.0 Specification (error object, id rules, notifications): <https://www.jsonrpc.org/specification>
- RFC 9728, OAuth 2.0 Protected Resource Metadata: <https://datatracker.ietf.org/doc/html/rfc9728>
- RFC 6750, OAuth 2.0 Bearer Token Usage (`WWW-Authenticate`, `invalid_token`, `insufficient_scope`): <https://datatracker.ietf.org/doc/html/rfc6750>
- Amazon Builders' Library, *Timeouts, retries and backoff with jitter*: <https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/>
- Linux Foundation, Model Context Protocol Associate (MCPA): <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Q1.1** `notifications/initialized` produced no output. In JSON-RPC 2.0 a *notification* is a request object without an `id` member, and the specification states the server MUST NOT reply to it — *not even with an error*. This is not an optimisation: a response carrying `"id": null` would be indistinguishable from a real error response to an unidentifiable request, and the client has no pending entry to correlate it with. Every MCP notification (`notifications/initialized`, `notifications/cancelled`, `notifications/progress`, `notifications/message`, `notifications/*/list_changed`) obeys this.

**Q1.2** The rule is *who is expected to act on it*.
- **Unknown tool** is a contract violation: the client asked for something that was never advertised in `tools/list`. The model cannot repair it — the tool does not exist. That belongs to the client/host, so it is a JSON-RPC `error` (`-32602`).
- **Division by zero** is the tool doing its job and reporting a domain failure. The model *can* repair it by supplying a different denominator. It must therefore reach the model, which means it must survive as a *successful* JSON-RPC result — `result.isError = true` with explanatory `content`. The specification is explicit that this exists "so the LLM can see that an error occurred and potentially take corrective action".

**Q1.3** A `-32603` never reaches the model. The client sees a protocol error, marks the tool call as failed at the transport layer, and typically either aborts the step or surfaces a generic failure to the user. The agent loses the one piece of information that would have let it self-correct — *which argument was wrong and why* — so a task that a competent agent finishes in two turns becomes a dead end. In production this shows up as agents that abandon multi-step workflows on the first recoverable input mistake.

**Q1.4** `isError` is optional in `CallToolResult`. Absent means `false`. A client MUST treat a missing `isError` as a success; it must never infer failure from the *content* of the text. Emitting it explicitly, as this server does, is defensive but not required.

### Exercise 2

**Q2.1** The first line is truncated JSON, so the server cannot parse it at all — it never learns that the id was `10`. JSON-RPC requires that when the id cannot be determined because of a parse or invalid-request error, the response's `id` MUST be `null`. The last message has no `method`; our handler answers `-32600` with `id: null` because the message is not a valid request object.

**Q2.2** `-32002` is inside `-32000` to `-32099`, the range JSON-RPC reserves for *implementation-defined server errors*. MCP claims it for "resource not found" on `resources/read`. That it is a convention and not a JSON-RPC pre-defined code matters: a generic JSON-RPC client will not recognise it, and any code outside the pre-defined set must be interpreted with knowledge of the protocol on top.

**Q2.3** `"four"` violates the declared `inputSchema` — `denominator` is `{"type": "number"}`. A schema violation means the *call itself* was never valid, so it never reaches tool logic; that is a protocol error, `-32602`. `0` is a perfectly valid `number`: it satisfies the schema, enters the tool, and the tool's domain logic rejects it. Schema-valid input that fails at execution is always the `isError` channel. A useful heuristic: *if a correct client with the advertised schema could not have prevented it, it is a tool error.*

**Q2.4** `code` (integer) and `message` (string, a single concise sentence) are mandatory. `data` is optional and may be any JSON value — primitive or structured. The constraint is not syntactic but operational: `data` is transmitted to the client and, for tool-adjacent failures, may end up in model context, so it must contain no secrets, no credentials, no internal hostnames and no stack traces. Put correlation ids there, not evidence.

**Q2.5** JSON-RPC requires `result` and `error` to be mutually exclusive — exactly one MUST be present. A response containing both is not a valid response object. A strict client should reject it as a protocol violation rather than guessing; guessing means a server bug silently becomes a client-side data-integrity bug.

### Exercise 3

**Q3.1** A useful tool error must be (1) **identified** — a stable machine-readable reason code the model and your metrics can both key on; (2) **causal** — what actually failed, in the vocabulary of the tool's own arguments; (3) **actionable** — the next concrete move, including whether retrying is pointless. `"Error"` fails (1) first and then all three: the model has nothing to reason about, so it either retries identically or abandons the task.

**Q3.2** `structuredContent` is machine-readable and validated against the tool's `outputSchema`; `content` is what a client renders and what every model reliably reads. The specification's compatibility rule is that a tool returning structured content SHOULD also return functionally equivalent unstructured content — typically the JSON serialised into a text block. Clients that predate structured output, or that do not implement it, would otherwise display an empty result.

**Q3.3** No. Security: the string names an internal service account (`svc_mcp`) and confirms the authentication mechanism — reconnaissance handed to anything that reads the conversation, including a downstream tool with network access. Behaviour: the model cannot act on it either. It has no credentials and no ability to fix database authentication, so the string is pure noise that consumes context and may provoke pointless "fix-it" attempts. Return `"The billing store is unavailable (incident a1b2c3). This is not caused by your arguments; do not retry."` and log the real exception to stderr.

**Q3.4** The **client/host** is responsible. `isError` deliberately hands control to the model, and a model with no external constraint will loop. The mechanisms are host-side: a per-tool call budget, a max-iterations cap on the agent loop, and duplicate-call detection (same tool, same arguments, within the same turn). The server can help by making the error text state the constraint explicitly — "retrying with the same arguments will fail identically" — but it cannot enforce it.

### Exercise 4

**Q4.1** `resources/read` is a *protocol method with a defined contract*: the client asked the server for a URI the server's own resource list should have contained. The failure is in the client's model of the server, so it goes to the client — `-32002`. A tool is a *capability the model invokes*; a missing file encountered inside it is an outcome of the operation the model requested, and the model may be able to choose another path or file. Same condition, different contract, different channel.

**Q4.2** Everything. `-32603 Internal error` carries no reason code, no filename, no hint of recoverability, and by convention no detail at all (because detail leaks). The agent cannot distinguish "the file is missing" from "the disk is full" from "you passed a malformed URI", so it cannot choose between retrying, changing arguments, or giving up. This is the most common defect in SDK-based servers: handlers that let exceptions escape get a uniform `-32603` for free and never notice what they lost.

**Q4.3** *For:* returning "not found" for a resource the caller is not authorised to see prevents existence disclosure — the classic argument against confirming that `/etc/shadow`, or customer record 4471, exists. In a multi-tenant MCP server exposed to an untrusted model, that is usually right. *Against:* it destroys diagnosability. An operator debugging "the agent cannot read the report" cannot tell a typo from a missing ACL, and this costs hours. The production reconciliation: return the opaque error on the wire, log the discriminating reason with a correlation id on the server, and put that id in `error.data`.

**Q4.4** `notifications/resources/list_changed`, sent by servers that declared the `resources.listChanged` capability during `initialize`. A client that ignores it keeps serving a stale resource list to the model — which then requests URIs that have been removed or renamed, producing `-32002` responses that are entirely the client's own fault. The same reasoning applies to `notifications/tools/list_changed` and `-32602 Unknown tool`.

### Exercise 5

**Q5.1** The server MUST NOT write anything to its stdout that is not a valid MCP JSON-RPC message; the client likewise MUST NOT write anything to the server's stdin that is not a valid message. The server MAY write UTF-8 strings to stderr for logging purposes, and the client MAY capture, forward or ignore that stream. Messages on stdio are newline-delimited and MUST NOT themselves contain embedded newlines.

**Q5.2** Tearing down is safer. Junk on stdout means the stream framing can no longer be trusted: the write that produced it may have been interleaved with a partial JSON-RPC message from another thread, so the *next* line may be a valid-looking fragment of a message whose remainder was lost. Skipping and continuing means a client can silently process a truncated `tools/list` — accepting corrupted state — instead of failing loudly. Recovering from a lost session is cheap; recovering from silently wrong tool definitions is not.

**Q5.3** (1) A `print()` left in a library you import, executing at import time, before your own code runs. (2) `logging.basicConfig()` with no handler argument — on some configurations logging lands on stdout, and any dependency calling it hijacks your transport. (3) A subprocess launched by a tool that inherits the parent's stdout (`subprocess.run(...)` without capturing), so the *child's* output goes straight onto the MCP wire. Honourable mentions: warnings written by C extensions, and progress bars.

**Q5.4** `notifications/message`, the MCP logging utility: a structured log notification with an RFC 5424 severity (`debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`), an optional `logger` name, and arbitrary JSON `data`. The server must declare the `logging` capability during `initialize`; clients may then set a minimum level with `logging/setLevel`. This is the only correct way to send log output *through* the protocol rather than around it — and it works identically on stdio and HTTP.

### Exercise 6

**Q6.1** A missing `Mcp-Session-Id` is a malformed request: the client omitted something the server requires, and no amount of retrying will fix it — that is `400 Bad Request`, and the client must fix its request construction. A *known-shaped but unrecognised* session id means the resource being addressed (the session) no longer exists — `404 Not Found`. The spec then mandates a specific recovery: on `404` in response to a request carrying a session id, the client MUST start a new session by sending a fresh `InitializeRequest` **without** a session id, and only then replay.

**Q6.2** The spec says that if the server receives a request without `MCP-Protocol-Version` and cannot otherwise identify the version, it SHOULD assume `2025-03-26` for backwards compatibility. So omission is not an error — it is a **silent downgrade**. It is more dangerous than the `400` because everything appears to work while the server applies older semantics: different tool-result shapes, different authorization expectations, batching rules that changed between revisions. Failures then surface far from their cause. Always send the header explicitly and assert on it server-side in staging.

**Q6.3** Identical rule, different layer. Over stdio, a notification simply produces no response line. Over Streamable HTTP, the POST still needs an HTTP status, so the server returns `202 Accepted` with **no body** — the HTTP-level acknowledgement that the message was received, carrying no JSON-RPC response, because a notification has no id to respond to. A client that expects a JSON body after every POST breaks on every notification it sends.

**Q6.4** The client parses the `resource_metadata` parameter from the challenge, fetches the **OAuth 2.0 Protected Resource Metadata** document at that URL (`/.well-known/oauth-protected-resource`), reads `authorization_servers` from it, fetches that authorization server's own metadata, and runs an OAuth 2.0 authorization code flow with PKCE — registering dynamically if the server supports it. The protected-resource metadata document is defined by **RFC 9728**; the challenge header format comes from RFC 6750. MCP additionally requires the token to be audience-bound to this resource, so tokens are not replayable against other MCP servers.

**Q6.5** `401` (`invalid_token`) means the credential is missing, expired or malformed — refresh and retry once; that is the normal token-expiry path and must not surface to the user. `403` (`insufficient_scope`) means the credential is valid but does not carry the authority; retrying with the same token is guaranteed to fail, so it must surface immediately, ideally naming the missing scope from the challenge. Conflating them produces either infinite refresh loops or spurious re-authentication prompts.

**Q6.6** They speak to different layers and both are correct. HTTP `400` tells the *HTTP client* — including every proxy, load balancer and metrics collector in the path — that the request was malformed, so it is counted and logged correctly by infrastructure that knows nothing about JSON-RPC. The `-32700` object in the body tells the *MCP client* precisely what went wrong in protocol terms. Returning `200` with a JSON-RPC error would hide the failure from every layer of your observability stack.

### Exercise 7

**Q7.1** JSON-RPC requires that the response `id` MUST be the same as the request `id`, *including its type* — `7` and `"7"` are different ids. The client's pending-request map is keyed on the exact value, so `"7"` matches nothing and the request stays outstanding until the deadline. A proxy that re-serialises JSON and coerces numeric ids to strings (or, worse, rounds large integers through a float) silently destroys correlation for every in-flight request while leaving the messages superficially intact — the hardest class of MCP bug to find, because the server logs show success.

**Q7.2** The receiver SHOULD stop processing the cancelled request and free its resources, and SHOULD NOT send a response for it. But cancellation and completion race by nature: the response may already be in flight. The initiator MUST therefore ignore any response that arrives for a request it has cancelled. The receiver must also tolerate cancellations for unknown or already-completed ids without erroring — and since `notifications/cancelled` is a notification, it is never itself acknowledged.

**Q7.3** The `initialize` request. Cancelling it leaves the two peers disagreeing about whether negotiation happened: the client does not know the agreed protocol version or the server's capabilities, and the server may have already committed session state. There is no defined recovery, so the specification forbids it outright — if you need to abandon initialization, drop the transport.

**Q7.4** A misbehaving or compromised server can hold a request open indefinitely by emitting `notifications/progress` just under the timeout, pinning client resources — a slow-resource-exhaustion vector, and a way to keep an agent stuck on one step forever. The closing rule: implementations SHOULD *always* enforce a maximum total timeout regardless of progress notifications. Progress may extend the idle clock; it must not extend the wall-clock ceiling.

**Q7.5** They are implementation choices within the `-32000`…`-32099` server-defined range, adopted by the reference SDKs (`ConnectionClosed`, `RequestTimeout`) — not codes the MCP specification assigns. A client that hardcodes them is coupling to an SDK, not to the protocol: a server written against a different SDK, or in another language, may use entirely different codes for the same conditions. Classify transport failures from transport state (socket closed, deadline expired) and treat the numeric code as a hint.

### Exercise 8

**Q8.1** `401`: refresh or re-acquire the token following the `WWW-Authenticate` challenge, then retry the request **once**. `404`: send a new `initialize` **without** a session id, obtain a new session, then replay. Both are non-retryable for a blind loop because repeating the *identical* request is guaranteed to reproduce the identical failure — the recovery requires changing something (a new token, a new session) before the retry. Marking them retryable in the generic classifier produces a hot loop that hammers the server and never succeeds.

**Q8.2** `backoff()` uses **full jitter**: the sleep is drawn uniformly from `[0, min(cap, base·2ⁿ))` rather than being the deterministic exponential. When many clients fail simultaneously — the classic case, an upstream restart — deterministic backoff makes all of them retry at the same instants, producing synchronised thundering-herd waves that keep the recovering service down. Full jitter spreads the retries uniformly over the window, which both reduces peak load and shortens total recovery time.

**Q8.3** *For:* `-32603` is generic by design — it is what every uncaught server exception becomes — and a large share of those are genuinely transient (a connection pool exhausted for a second, a dependency restarting). One bounded retry recovers them at negligible cost. *Against:* `-32603` gives you no idempotency information. If the failing call is `create_refund` and the exception happened *after* the refund was written but before the response was serialised, the retry issues a second refund. The rule: retry `-32603` only for operations you know are idempotent or that carry an idempotency key.

**Q8.4** The half-open probe exists to test the hypothesis "the dependency has recovered" with exactly one unit of load. Releasing the whole queue re-applies full production traffic to a service that is, at best, cold — empty caches, unfilled pools — which usually knocks it straight back down and re-opens the breaker. The result is a sustained oscillation between open and overloaded that can outlast the original outage. One probe, promote on success, re-open on failure.

**Q8.5** `Retry-After` wins, always, and your backoff is the floor beneath it: sleep `max(retry_after, backoff(attempt))`. The server is the only party that knows when its quota window actually resets; your exponential curve is a guess. Ignoring the header means retrying before the window rolls over, which on most gateways *extends* the penalty. Honour the header, keep the jitter so that clients sharing a reset instant do not fire simultaneously, and still cap total attempts.

**Q8.6** Not safe. `-32001` means *you* stopped waiting — it says nothing about whether the server processed the call. The refund may well have been issued. It becomes safe when the tool accepts an **idempotency key** in its arguments that the client generates once per logical operation and reuses across retries, with the server deduplicating on it and returning the original result. Without that, a timeout on a mutating tool must be surfaced, not retried — and the tool's description should say so, so the model does not retry it either.

### Exercise 9

**Q9.1** The MCP client process and its logs; the host application and *its* logs and telemetry pipeline; the **model**, since protocol errors are commonly summarised into the conversation and tool errors go into context verbatim; the model **provider's** infrastructure, because that context is transmitted for inference and may be retained; any other tool the agent subsequently calls, because the credential is now in context and can be passed as an argument; and the end user, on screen. One `str(exc)` moved a production database password across five trust boundaries.

**Q9.2** A REST API's stack trace is read by a developer who must first find it. An MCP error is injected into an autonomous agent's context, where it becomes *input to a system that takes actions*. Two compounding risks: the model may helpfully include the connection string in a later tool call or summary (exfiltration by cooperation), and an attacker who can influence tool input can deliberately provoke errors to harvest infrastructure detail — turning your error handler into a read primitive. Errors in an agentic system are not diagnostics, they are untrusted data flowing toward an actor with capabilities.

**Q9.3** It preserves the ability to correlate a user-visible failure with the full server-side evidence — the real exception, the traceback, the DSN, the upstream request id — without any of that crossing the boundary. For it to be worth anything the server must actually emit the incident id into a log store that is retained, searchable and joinable on that id, and support must be able to look it up. An incident id that nobody can resolve is decoration that costs a UUID.

**Q9.4** Primarily the **client**, which uses it to decide whether to retry or escalate, exactly as in Exercise 8 — `error.data` is a protocol-layer field and a well-behaved client consumes it before the model sees anything. The model may also benefit if the client surfaces it, since "do not retry" is precisely the guidance that stops the loop in Q3.4. The rule of thumb: put retry semantics in `data` for the client and restate them in plain language in tool-error `content` for the model. The two audiences need the same fact in two encodings.

**Q9.5** The rule does not change — it **tightens**. A protocol error may be intercepted by the client and never reach the model; a tool error with `isError: true` is *designed* to reach the model and is placed in context by construction. So the exposure is certain rather than probable. Tool error text should name the reason code, the failing argument and the next action, and nothing about your infrastructure: no hostnames, no credentials, no internal ids beyond an opaque incident reference, no stack traces. If you would not paste it into a public issue tracker, it does not belong in `content`.

</details>