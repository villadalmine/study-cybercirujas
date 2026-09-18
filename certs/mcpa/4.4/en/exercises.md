# Topic 4.4 — Auditability & Observability

## Guided Exercises

> **Exam weight:** 6.0 · **Exam version:** 2026-07-28
> **Certification:** Model Context Protocol Associate (MCPA) — Linux Foundation
> <https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/>

### What you will be able to do when you finish

- Distinguish the three signal planes an MCP deployment produces — **protocol telemetry**, **operator logs**, and the **audit trail** — and explain why they must not share a transport.
- Instrument an MCP server so that every `tools/call` is traceable from the client's JSON-RPC `id` through to the downstream system it touched.
- Use the MCP `logging` capability (`logging/setLevel`, `notifications/message`) correctly, and state precisely what it is *not* good for.
- Read and reason about `isError: true` versus a JSON-RPC error object, and design metrics that do not lie about either.
- Carry W3C trace context across a boundary that has no HTTP headers (stdio) using `_meta`.
- Record identity in an audit event that survives a compliance review: subject, audience, issuer, and the limits of what a server can attest to.
- Diagnose the classic observability failures: a poisoned stdout stream, a dead session, and a notification gap after a reconnect.

### Prerequisites

- Python 3.12, `curl`, `jq`, and a POSIX shell.
- Familiarity with topics 2.x (transports and the lifecycle) and 3.x (tools, resources, prompts).
- No cluster required. Everything runs on localhost.

### Reference material used throughout

| Subject | Source |
|---|---|
| Logging utility (levels, `setLevel`, `notifications/message`) | <https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/logging> |
| Progress notifications and `progressToken` | <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress> |
| Cancellation | <https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/cancellation> |
| Transports (stdio rules, Streamable HTTP, resumability) | <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports> |
| Tools, `CallToolResult`, `isError` | <https://modelcontextprotocol.io/specification/2025-06-18/server/tools> |
| Authorization (OAuth 2.1 resource server) | <https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization> |
| Security best practices (token passthrough, confused deputy, sessions) | <https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices> |
| Lifecycle and capability negotiation | <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle> |
| Syslog severity levels | <https://www.rfc-editor.org/rfc/rfc5424#section-6.2.1> |
| W3C Trace Context (`traceparent`) | <https://www.w3.org/TR/trace-context/> |
| OpenTelemetry RPC semantic conventions | <https://opentelemetry.io/docs/specs/semconv/rpc/json-rpc/> |
| OpenTelemetry GenAI semantic conventions (still evolving) | <https://opentelemetry.io/docs/specs/semconv/gen-ai/> |
| Official Python SDK | <https://github.com/modelcontextprotocol/python-sdk> |
| MCP Inspector | <https://github.com/modelcontextprotocol/inspector> |
| OAuth 2.0 Resource Indicators | <https://www.rfc-editor.org/rfc/rfc8707> |
| OAuth 2.0 Protected Resource Metadata | <https://www.rfc-editor.org/rfc/rfc9728> |

---

## Exercise 0 — Lab setup

**Goal:** a working directory, an SDK, and a place to put an audit trail.

1. Create the lab and install the SDK.

```bash
mkdir -p ~/labs/mcpa-4.4 && cd ~/labs/mcpa-4.4
python3.12 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet "mcp[cli]" opentelemetry-api opentelemetry-sdk \
  opentelemetry-exporter-otlp-proto-http prometheus-client
.venv/bin/python -c "import mcp, sys; print('mcp', mcp.__version__ if hasattr(mcp,'__version__') else 'installed'); print(sys.version.split()[0])"
```

2. Create the audit directory. In this lab it is a local file; in production it is a separate, append-only volume.

```bash
mkdir -p audit
: > audit/audit.jsonl
chmod 0640 audit/audit.jsonl
ls -l audit/
```

Expected:

```
total 0
-rw-r----- 1 you you 0 Sep 17 10:04 audit.jsonl
```

3. Record the protocol revision you will pin for the whole lab. MCP revisions are date-stamped, and the revision is negotiated in `initialize`; over Streamable HTTP the client must then echo it in a header on every subsequent request.

```bash
export MCP_PROTOCOL_VERSION=2025-06-18
echo "$MCP_PROTOCOL_VERSION"
```

**Check your understanding**

- **Q1.** The audit file is created with mode `0640` before the server ever runs. Why is pre-creating it with restrictive permissions better than letting the server create it on first write?
- **Q2.** Why does an audit trail belong on a different filesystem — ideally a different host — from the MCP server's own working directory?

---

## Exercise 1 — Read what the protocol already gives you

Before adding a single line of instrumentation, find out what is observable for free. Every MCP session begins with a handshake that is itself a rich telemetry event.

1. Write a deliberately minimal server so the handshake is the only thing in the way.

```python
# baseline_server.py
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("baseline")


@mcp.tool()
def ping_db() -> str:
    """Return a fixed string. Placeholder for a real dependency check."""
    return "pong"


if __name__ == "__main__":
    mcp.run(transport="stdio")
```

2. Drive it by hand over stdio. The stdio transport is newline-delimited JSON, so a pipe is a perfectly valid client for a smoke test.

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-audit-lab","version":"0.1.0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| .venv/bin/python baseline_server.py 2>/dev/null
```

3. Read the two response lines. This is a stream of several JSON documents, one per line — not a single JSON document:

```
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{},"tools":{"listChanged":false}},"serverInfo":{"name":"baseline","version":"1.14.0"}}}
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"ping_db","description":"Return a fixed string. Placeholder for a real dependency check.","inputSchema":{"type":"object","properties":{},"title":"ping_dbArguments"}}]}}
```

4. Note what the `InitializeResult` told you without any instrumentation: the negotiated revision, the server's identity and version, and the exact capability set. Extract it as a structured fact:

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-audit-lab","version":"0.1.0"}}}' \
| .venv/bin/python baseline_server.py 2>/dev/null \
| head -n 1 \
| jq '{negotiated: .result.protocolVersion, server: .result.serverInfo, capabilities: (.result.capabilities | keys)}'
```

Expected:

```
{
  "negotiated": "2025-06-18",
  "server": {
    "name": "baseline",
    "version": "1.14.0"
  },
  "capabilities": [
    "experimental",
    "tools"
  ]
}
```

5. Now ask for a revision the server does not implement, and observe that the handshake still succeeds — with a different answer.

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"curl-audit-lab","version":"0.1.0"}}}' \
| .venv/bin/python baseline_server.py 2>/dev/null | jq -c '.result.protocolVersion'
```

Expected:

```
"2025-06-18"
```

**Check your understanding**

- **Q3.** The server did not reject the unknown `1999-01-01`; it answered with its own latest supported revision. Which side is now responsible for deciding whether the session can continue, and what must it do if the answer is no?
- **Q4.** `serverInfo.version` in the response above is `1.14.0` — the SDK version, not your server's. Why is that a real auditability defect, and what should the field carry in a production deployment?
- **Q5.** Name three fields from the `initialize` exchange that belong in a `session.opened` audit record, and say what question each one answers six months later during an incident review.

---

## Exercise 2 — The `logging` capability, end to end

MCP has a first-class logging utility. You will turn it on, drive it from the client side, and then establish exactly what it is for.

1. Replace the server with one that declares `logging` and emits at several severities. In the Python SDK, `Context` helpers (`debug`, `info`, `warning`, `error`) send `notifications/message`; declaring the capability is handled for you when a request context is present.

```python
# logging_server.py
from mcp.server.fastmcp import Context, FastMCP

mcp = FastMCP("logging-demo")


@mcp.tool()
async def reconcile(account: str, ctx: Context) -> str:
    """Reconcile one account and narrate the work to the client."""
    await ctx.debug(f"opening ledger cursor for {account}")
    await ctx.info("reconciliation started")
    await ctx.warning("ledger is 3 minutes stale; proceeding with cached snapshot")
    await ctx.log(level="error", message="1 orphan line item skipped", logger_name="ledger")
    return f"reconciled {account}: 41 matched, 1 skipped"


if __name__ == "__main__":
    mcp.run(transport="stdio")
```

2. Call it without setting a level first, and keep only the notifications:

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-audit-lab","version":"0.1.0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-77"}}}' \
| .venv/bin/python logging_server.py 2>/dev/null \
| jq -c 'select(.method == "notifications/message") | .params'
```

Representative output — again, JSON Lines, not one document:

```
{"level":"debug","logger":"reconcile","data":"opening ledger cursor for ACC-77"}
{"level":"info","logger":"reconcile","data":"reconciliation started"}
{"level":"warning","logger":"reconcile","data":"ledger is 3 minutes stale; proceeding with cached snapshot"}
{"level":"error","logger":"ledger","data":"1 orphan line item skipped"}
```

3. Now raise the threshold from the client side and repeat. `logging/setLevel` is a request, and it returns an empty result object.

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-audit-lab","version":"0.1.0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"logging/setLevel","params":{"level":"warning"}}' \
'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-77"}}}' \
| .venv/bin/python logging_server.py 2>/dev/null \
| jq -c 'select(.method == "notifications/message") | .params.level' | sort -u
```

Expected — `debug` and `info` are gone, because `warning` and everything more severe passes the filter:

```
"error"
"warning"
```

4. Write out the full severity ladder MCP inherits from RFC 5424, most severe first, and confirm that your server can address every rung:

```bash
for lvl in emergency alert critical error warning notice info debug; do
  printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"$lvl\"}}" \
  | .venv/bin/python logging_server.py 2>/dev/null \
  | jq -c --arg l "$lvl" 'select(.id == 2) | {level: $l, accepted: (has("result"))}'
done
```

Expected:

```
{"level":"emergency","accepted":true}
{"level":"alert","accepted":true}
{"level":"critical","accepted":true}
{"level":"error","accepted":true}
{"level":"warning","accepted":true}
{"level":"notice","accepted":true}
{"level":"info","accepted":true}
{"level":"debug","accepted":true}
```

5. Send `data` as a structured object rather than a string. The spec allows any JSON-serializable value, and structured `data` is the difference between a log you can query and a log you can only read.

```python
        await ctx.log(
            level="warning",
            message={
                "event": "ledger.stale",
                "staleness_seconds": 183,
                "snapshot_id": "snap-2026-09-17T10-04-11Z",
                "action": "proceeded_with_cache",
            },
            logger_name="ledger",
        )
```

**Check your understanding**

- **Q6.** In step 2 you received `debug` messages although no level had ever been set. Is that a bug in the server, a bug in the client, or permitted behaviour? Justify your answer from the lifecycle of the logging utility.
- **Q7.** `logging` is declared as a **server** capability, yet `logging/setLevel` is sent **by the client**. Explain the direction of each half and why the level is client-controlled.
- **Q8.** A colleague proposes shipping the compliance audit trail over `notifications/message`, arguing that it is standardised, already wired, and needs no extra infrastructure. Give three independent protocol-level reasons this fails an audit, referencing the mechanics you exercised in steps 2 and 3.
- **Q9.** Your server emits one `notifications/message` per row while streaming a 50 000-row export. What does the spec say you should do, and what is the concrete failure mode if you ignore it?

---

## Exercise 3 — stdout is the wire: build the two-sink logger

This is the exercise that separates people who have run an MCP server in production from people who have not.

1. Break it on purpose first. Add a plain `print()` to a tool — the single most common way a working stdio server is destroyed.

```python
# poisoned_server.py
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("poisoned")


@mcp.tool()
def reconcile(account: str) -> str:
    print(f"DEBUG: reconciling {account}")   # <-- this writes to stdout
    return f"reconciled {account}"


if __name__ == "__main__":
    mcp.run(transport="stdio")
```

2. Run the same driver as before and look at the raw stdout stream — do not pipe it through `jq` yet, or you will see only the error:

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-77"}}}' \
| .venv/bin/python poisoned_server.py 2>/dev/null
```

Expected — note the non-JSON line wedged into the middle of the framing:

```
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{},"tools":{"listChanged":false}},"serverInfo":{"name":"poisoned","version":"1.14.0"}}}
DEBUG: reconciling ACC-77
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"reconciled ACC-77"}],"structuredContent":{"result":"reconciled ACC-77"},"isError":false}}
```

3. Confirm the damage a real client would take. Every line on stdout must be a valid MCP message:

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-77"}}}' \
| .venv/bin/python poisoned_server.py 2>/dev/null \
| jq -c . 2>&1 | tail -n 2
```

Expected:

```
parse error: Invalid numeric literal at line 2, column 6
```

4. Now build the server you will keep for the rest of the lab. Three sinks, three audiences, three lifetimes.

```python
# audit_server.py
"""MCP server instrumented for audit and observability.

Three signal planes, deliberately separated:
  stdout  -> MCP protocol messages ONLY (stdio transport requirement)
  stderr  -> structured operator logs, ephemeral, for the on-call engineer
  audit/  -> append-only audit trail, durable, for the compliance reviewer
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Any

from mcp.server.fastmcp import Context, FastMCP

AUDIT_PATH = os.environ.get("MCP_AUDIT_LOG", "audit/audit.jsonl")
SERVICE_VERSION = os.environ.get("MCP_SERVICE_VERSION", "0.3.1")
DEPLOY_ENV = os.environ.get("MCP_ENV", "lab")

# --- operator log: structured, to stderr, never to stdout -------------------

_CONTEXT_FIELDS = ("session_id", "request_id", "tool", "principal", "trace_id")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, timezone.utc)
            .isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
            "service": "mcp-audit-demo",
            "service_version": SERVICE_VERSION,
            "env": DEPLOY_ENV,
        }
        for field in _CONTEXT_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[_handler], force=True)
log = logging.getLogger("mcp.audit_server")

# --- audit trail: append-only, fsynced, machine-readable --------------------

_REDACT_KEYS = {"password", "token", "secret", "authorization", "api_key", "ssn"}


def fingerprint(value: Any) -> str:
    """Stable digest of a value: proves what was passed without storing it."""
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def redact(arguments: dict[str, Any]) -> dict[str, Any]:
    """Keep shape and types; drop values that must never reach durable storage."""
    out: dict[str, Any] = {}
    for key, value in arguments.items():
        if key.lower() in _REDACT_KEYS:
            out[key] = "[redacted]"
        elif isinstance(value, dict):
            out[key] = redact(value)
        elif isinstance(value, str) and len(value) > 64:
            out[key] = f"[str len={len(value)} {fingerprint(value)}]"
        else:
            out[key] = value
    return out


def audit(event: str, **fields: Any) -> None:
    record = {
        "schema": "mcp.audit/v1",
        "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "event": event,
        "service": "mcp-audit-demo",
        "service_version": SERVICE_VERSION,
        "env": DEPLOY_ENV,
        **fields,
    }
    line = json.dumps(record, sort_keys=True, separators=(",", ":"), default=str)
    with open(AUDIT_PATH, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")
        handle.flush()
        os.fsync(handle.fileno())


# --- the instrumented tool --------------------------------------------------

mcp = FastMCP("audit-demo")

_LEDGER = {"ACC-77": 41, "ACC-12": 7}


@mcp.tool()
async def reconcile(account: str, ctx: Context) -> str:
    """Reconcile one account against the ledger."""
    started = time.monotonic()
    request_id = str(ctx.request_id)
    session_id = getattr(ctx.session, "session_id", None) or "stdio"
    common = {
        "session_id": session_id,
        "request_id": request_id,
        "tool": "reconcile",
        "arguments": redact({"account": account}),
        "arguments_digest": fingerprint({"account": account}),
    }

    audit("tool.call.started", **common)
    log.info("tool invoked", extra={"request_id": request_id,
                                    "session_id": session_id, "tool": "reconcile"})
    await ctx.info(f"reconciling {account}")

    try:
        if account not in _LEDGER:
            raise LookupError(f"no ledger for account {account}")
        matched = _LEDGER[account]
    except Exception as exc:
        duration_ms = round((time.monotonic() - started) * 1000, 2)
        audit("tool.call.finished", outcome="error",
              error_type=type(exc).__name__, duration_ms=duration_ms, **common)
        log.error("tool failed", exc_info=True,
                  extra={"request_id": request_id, "session_id": session_id,
                         "tool": "reconcile"})
        raise

    duration_ms = round((time.monotonic() - started) * 1000, 2)
    audit("tool.call.finished", outcome="ok", duration_ms=duration_ms,
          result_digest=fingerprint(matched), rows_matched=matched, **common)
    return f"reconciled {account}: {matched} matched"


if __name__ == "__main__":
    mcp.run(transport="stdio")
```

5. Exercise both paths and inspect each sink independently.

```bash
: > audit/audit.jsonl
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-77"}}}' \
'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-999"}}}' \
| .venv/bin/python audit_server.py 2>operator.log >protocol.out
```

6. Verify that **stdout is clean JSON on every single line** — this is the invariant that keeps the session alive:

```bash
awk 'NR{ if (system("echo " "'\''" $0 "'\''" " | jq -e . >/dev/null 2>&1")) print "BAD LINE " NR }' protocol.out ; echo "stdout check done"
jq -c 'if has("result") then {id, ok: true} elif has("error") then {id, code: .error.code} else {method} end' protocol.out
```

Expected:

```
stdout check done
{"id":1,"ok":true}
{"method":"notifications/message"}
{"id":2,"ok":true}
{"method":"notifications/message"}
{"id":3,"ok":true}
```

7. Read the operator log — human-oriented, ephemeral, safe to drop on the floor under load:

```bash
jq -c '{level, msg, tool, request_id}' operator.log
```

Expected:

```
{"level":"info","msg":"tool invoked","tool":"reconcile","request_id":"2"}
{"level":"info","msg":"tool invoked","tool":"reconcile","request_id":"3"}
{"level":"error","msg":"tool failed","tool":"reconcile","request_id":"3"}
```

8. Read the audit trail — machine-oriented, durable, never dropped:

```bash
jq -c '{event, request_id, outcome, tool, args: .arguments, dur: .duration_ms}' audit/audit.jsonl
```

Expected:

```
{"event":"tool.call.started","request_id":"2","outcome":null,"tool":"reconcile","args":{"account":"ACC-77"},"dur":null}
{"event":"tool.call.finished","request_id":"2","outcome":"ok","tool":"reconcile","args":{"account":"ACC-77"},"dur":0.08}
{"event":"tool.call.started","request_id":"3","outcome":null,"tool":"reconcile","args":{"account":"ACC-999"},"dur":null}
{"event":"tool.call.finished","request_id":"3","outcome":"error","tool":"reconcile","args":{"account":"ACC-999"},"dur":0.05}
```

**Check your understanding**

- **Q10.** State the stdio transport's rule about stdout in one sentence, and say what the transport permits on stderr.
- **Q11.** You are now running the same server binary over Streamable HTTP instead of stdio. Does the `print()` in `poisoned_server.py` still break the session? Does that make it acceptable to leave in?
- **Q12.** The audit writer calls `os.fsync()` on every record. Name the cost, name the guarantee it buys, and describe the production pattern that keeps most of the guarantee without paying the full cost on a hot path.
- **Q13.** `tool.call.started` is written *before* the work happens and `tool.call.finished` *after*. Why are two records strictly better than one record written at the end, for an audit reviewer?
- **Q14.** `redact()` preserves the *shape* of the arguments while replacing sensitive values, and `fingerprint()` stores a digest alongside. What investigative question can you answer with the digest that you could not answer with `"[redacted]"` alone?

---

## Exercise 4 — Correlate one tool call end to end

An audit record nobody can join to anything else is a diary entry. This exercise builds the join keys.

1. Start the same server over Streamable HTTP. Add the entry point:

```python
# run_http.py
from audit_server import mcp

if __name__ == "__main__":
    mcp.settings.host = "127.0.0.1"
    mcp.settings.port = 8000
    mcp.run(transport="streamable-http")
```

```bash
.venv/bin/python run_http.py 2>operator-http.log &
sleep 2
```

2. Initialize and capture the session identifier the server minted for you:

```bash
curl -sS -D /tmp/init.headers -o /tmp/init.body http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-audit-lab","version":"0.1.0"}}}'

grep -i -E '^(HTTP/|content-type|mcp-session-id)' /tmp/init.headers
SESSION=$(grep -i '^mcp-session-id:' /tmp/init.headers | tr -d '\r' | awk '{print $2}')
echo "session=$SESSION"
```

Representative output:

```
HTTP/1.1 200 OK
content-type: text/event-stream
mcp-session-id: 8f2c0a4e1d6b47a9b0e5c3f7a91d2e64
session=8f2c0a4e1d6b47a9b0e5c3f7a91d2e64
```

3. Complete the handshake. A notification carries no `id`, so the server has nothing to answer and returns `202 Accepted` with an empty body:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" \
  -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

Expected:

```
202
```

4. Now make the call that you want to be traceable. Three correlation keys travel with it: the JSON-RPC `id`, a `progressToken` in `_meta`, and a W3C `traceparent` carried in `_meta` under a namespace you own. This is a single JSON document:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "reconcile",
    "arguments": {
      "account": "ACC-77"
    },
    "_meta": {
      "progressToken": "pt-3",
      "com.example/traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }
  }
}
```

```bash
cat > /tmp/call.json <<'JSON'
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-77"},"_meta":{"progressToken":"pt-3","com.example/traceparent":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}}}
JSON

curl -sS -N http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" \
  -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  --data-binary @/tmp/call.json
```

Representative SSE response body — note the framing is `event:` / `data:` lines, not JSON:

```
event: message
data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"reconcile","data":"reconciling ACC-77"}}

event: message
data: {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"reconciled ACC-77: 41 matched"}],"structuredContent":{"result":"reconciled ACC-77: 41 matched"},"isError":false}}

```

5. Teach the server to extract both transports of trace context — the HTTP header when there is one, the `_meta` key when there is not. Add to `audit_server.py`:

```python
TRACEPARENT_META_KEY = "com.example/traceparent"


def extract_traceparent(ctx: Context) -> str | None:
    """W3C trace context from the HTTP header, falling back to request _meta.

    stdio has no headers, so `_meta` is the only channel. The spec reserves
    `modelcontextprotocol.io/` style prefixes for itself: namespace your own
    keys with a domain you control.
    """
    request_ctx = ctx.request_context
    http_request = getattr(request_ctx, "request", None)
    if http_request is not None:
        header = http_request.headers.get("traceparent")
        if header:
            return header
    meta = getattr(request_ctx, "meta", None)
    if meta is not None:
        extra = getattr(meta, "model_extra", None) or {}
        value = extra.get(TRACEPARENT_META_KEY)
        if isinstance(value, str):
            return value
    return None


def trace_id_of(traceparent: str | None) -> str | None:
    """`00-<32 hex trace-id>-<16 hex span-id>-<flags>` -> trace-id."""
    if not traceparent:
        return None
    parts = traceparent.split("-")
    return parts[1] if len(parts) == 4 and len(parts[1]) == 32 else None
```

6. Add progress reporting and include every correlation key in the audit record:

```python
@mcp.tool()
async def reconcile(account: str, ctx: Context) -> str:
    """Reconcile one account against the ledger."""
    started = time.monotonic()
    traceparent = extract_traceparent(ctx)
    common = {
        "session_id": getattr(ctx.session, "session_id", None) or "stdio",
        "request_id": str(ctx.request_id),
        "trace_id": trace_id_of(traceparent),
        "traceparent": traceparent,
        "tool": "reconcile",
        "arguments": redact({"account": account}),
        "arguments_digest": fingerprint({"account": account}),
    }
    audit("tool.call.started", **common)

    total = _LEDGER.get(account, 0)
    for index in range(1, total + 1, 10):
        await ctx.report_progress(progress=index, total=total,
                                  message=f"line {index}/{total}")
    ...
```

7. Prove the join works. Take one `trace_id` and pull every record that belongs to it, across both sinks:

```bash
TRACE=4bf92f3577b34da6a3ce929d0e0e4736
jq -c --arg t "$TRACE" 'select(.trace_id == $t) | {event, request_id, session_id, outcome}' audit/audit.jsonl
jq -c --arg t "$TRACE" 'select(.trace_id == $t) | {level, msg}' operator-http.log
```

**Check your understanding**

- **Q15.** The JSON-RPC `id` in this lab was `3`. Explain why `request_id` alone is useless as a correlation key across a fleet, and what it must be combined with to become unique.
- **Q16.** `progressToken` is supplied by the **client**, inside `params._meta`, not chosen by the server. What does that design buy the client, and what must the server never assume about the token's format?
- **Q17.** Over stdio there is no `traceparent` header, so trace context rides in `_meta`. Why must you namespace your `_meta` key with a domain you own rather than calling it `traceparent`?
- **Q18.** A single user turn in the host application fans out to four different MCP servers. Which of the five identifiers in play — host turn id, trace id, session id, request id, progress token — has the widest scope, and which the narrowest? Order all five.
- **Q19.** `notifications/progress` and `notifications/cancelled` both reference a request that is still in flight. What does a `tool.call.started` with no matching `tool.call.finished` and a `notifications/cancelled` for the same request id tell you, and what audit event should you be emitting to close that gap?

---

## Exercise 5 — `isError` versus a JSON-RPC error, and metrics that do not lie

MCP has two distinct failure channels, and conflating them produces dashboards that are confidently wrong.

1. Provoke a **tool execution error** — the tool ran, and it failed:

```bash
cat > /tmp/bad-arg.json <<'JSON'
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"reconcile","arguments":{"account":"ACC-999"}}}
JSON

curl -sS -N http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  --data-binary @/tmp/bad-arg.json | sed -n 's/^data: //p' | jq -c '{id, isError: .result.isError, text: .result.content[0].text}'
```

Expected:

```
{"id":10,"isError":true,"text":"Error executing tool reconcile: no ledger for account ACC-999"}
```

2. Provoke a **protocol error** — the request never reached a tool:

```bash
cat > /tmp/no-such-tool.json <<'JSON'
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}
JSON

curl -sS -N http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  --data-binary @/tmp/no-such-tool.json | sed -n 's/^data: //p' | jq -c '{id, code: .error.code, message: .error.message, isError: .result.isError}'
```

Representative:

```
{"id":11,"code":-32602,"message":"Unknown tool: does_not_exist","isError":null}
```

3. Provoke a **transport-layer** rejection — no valid MCP envelope at all:

```bash
curl -sS -o /dev/null -w 'status=%{http_code}\n' http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  -d '{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}'
```

Expected — the session header is missing, so the transport rejects it before JSON-RPC dispatch:

```
status=400
```

4. Record all three in the audit trail with a taxonomy that keeps them apart:

```python
def classify(outcome: str, *, jsonrpc_code: int | None = None,
            http_status: int | None = None) -> dict[str, Any]:
    """Three failure planes, never collapsed into one counter."""
    return {
        "outcome": outcome,                # ok | tool_error | protocol_error | transport_error
        "jsonrpc_error_code": jsonrpc_code,
        "http_status": http_status,
        "visible_to_model": outcome == "tool_error",
    }
```

5. Register the metrics. Note the label sets: bounded, and free of anything caller-supplied.

```python
from prometheus_client import Counter, Histogram, Gauge

TOOL_CALLS = Counter(
    "mcp_tool_calls_total",
    "Tool invocations by tool and outcome plane.",
    ["tool", "outcome"],
)
TOOL_DURATION = Histogram(
    "mcp_tool_duration_seconds",
    "Wall-clock duration of a tools/call handler.",
    ["tool"],
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60),
)
JSONRPC_ERRORS = Counter(
    "mcp_jsonrpc_errors_total",
    "JSON-RPC error responses by code.",
    ["code"],
)
SESSIONS_ACTIVE = Gauge(
    "mcp_sessions_active",
    "Streamable HTTP sessions currently held open.",
)
```

6. Write the alert that a wrong taxonomy would have made impossible. Every line of the block scalar sits at the same indentation, including the bare `/`:

```yaml
groups:
  - name: mcp-server
    interval: 30s
    rules:
      - record: mcp:tool_error_ratio:rate5m
        expr: |
          sum by (tool) (rate(mcp_tool_calls_total{outcome="tool_error"}[5m]))
          /
          clamp_min(sum by (tool) (rate(mcp_tool_calls_total[5m])), 0.001)

      - alert: MCPToolFailingForModel
        expr: mcp:tool_error_ratio:rate5m > 0.05
        for: 10m
        labels:
          severity: warning
          plane: tool
        annotations:
          summary: "Tool {{ $labels.tool }} returns isError to the model on over 5% of calls"
          runbook: "https://runbooks.example.com/mcp/tool-error-ratio"

      - alert: MCPProtocolErrorsSpiking
        expr: |
          sum(rate(mcp_jsonrpc_errors_total[5m]))
          >
          0.5
        for: 5m
        labels:
          severity: critical
          plane: protocol
        annotations:
          summary: "Clients are sending requests this server cannot dispatch"
```

**Check your understanding**

- **Q20.** In step 1 the HTTP status was `200` and the JSON-RPC response was a `result`, not an `error` — yet the call failed. Explain the design rationale for reporting tool failures inside a successful `CallToolResult`.
- **Q21.** Who is the intended consumer of an `isError: true` result, and who is the intended consumer of a `-32602`? Name a concrete remediation each consumer can perform that the other cannot.
- **Q22.** Your dashboard shows `mcp_tool_calls_total{outcome="tool_error"}` climbing steadily while `mcp_jsonrpc_errors_total` is flat at zero. Give the two most likely explanations and the query you would run against the audit trail to discriminate between them.
- **Q23.** The recording rule divides by `clamp_min(..., 0.001)` instead of the raw denominator. What failure does that prevent, and what artefact does it introduce that you must remember when reading the graph?
- **Q24.** A colleague adds `account` as a label on `mcp_tool_calls_total` "so we can see which customers are failing". Explain the operational consequence, and give the correct place to answer that question instead.

---

## Exercise 6 — Spans: make the call a distributed trace

1. Wire a tracer and wrap the handler. Attribute names follow the OpenTelemetry RPC conventions where they exist; `mcp.*` is a private namespace, because MCP-specific conventions are not yet stable.

```python
# tracing.py
from opentelemetry import trace
from opentelemetry.propagate import extract
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

resource = Resource.create({
    "service.name": "mcp-audit-demo",
    "service.version": "0.3.1",
    "deployment.environment.name": "lab",
})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("mcp.audit_server")
```

2. Open the span as a child of whatever context arrived, and close it with an explicit status:

```python
from opentelemetry.trace import SpanKind, Status, StatusCode
from opentelemetry.propagate import extract
from tracing import tracer


@mcp.tool()
async def reconcile(account: str, ctx: Context) -> str:
    """Reconcile one account against the ledger."""
    traceparent = extract_traceparent(ctx)
    parent = extract({"traceparent": traceparent}) if traceparent else None

    with tracer.start_as_current_span(
        "mcp.tools/call reconcile",
        context=parent,
        kind=SpanKind.SERVER,
        attributes={
            "rpc.system": "jsonrpc",
            "rpc.jsonrpc.version": "2.0",
            "rpc.method": "tools/call",
            "rpc.jsonrpc.request_id": str(ctx.request_id),
            "mcp.tool.name": "reconcile",
            "mcp.session.id": getattr(ctx.session, "session_id", None) or "stdio",
            "mcp.transport": "streamable-http",
            "mcp.protocol.version": "2025-06-18",
        },
    ) as span:
        span_ctx = span.get_span_context()
        started = time.monotonic()
        common = {
            "session_id": getattr(ctx.session, "session_id", None) or "stdio",
            "request_id": str(ctx.request_id),
            "trace_id": format(span_ctx.trace_id, "032x"),
            "span_id": format(span_ctx.span_id, "016x"),
            "tool": "reconcile",
            "arguments": redact({"account": account}),
            "arguments_digest": fingerprint({"account": account}),
        }
        audit("tool.call.started", **common)
        try:
            if account not in _LEDGER:
                raise LookupError(f"no ledger for account {account}")
            matched = _LEDGER[account]
        except Exception as exc:
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            span.record_exception(exc)
            span.set_attribute("mcp.tool.is_error", True)
            TOOL_CALLS.labels(tool="reconcile", outcome="tool_error").inc()
            audit("tool.call.finished",
                  duration_ms=round((time.monotonic() - started) * 1000, 2),
                  **classify("tool_error"), **common)
            raise

        duration = time.monotonic() - started
        span.set_attribute("mcp.tool.is_error", False)
        span.set_attribute("mcp.tool.rows_matched", matched)
        TOOL_DURATION.labels(tool="reconcile").observe(duration)
        TOOL_CALLS.labels(tool="reconcile", outcome="ok").inc()
        audit("tool.call.finished", duration_ms=round(duration * 1000, 2),
              result_digest=fingerprint(matched), **classify("ok"), **common)
        return f"reconciled {account}: {matched} matched"
```

3. Ship the audit trail as logs so traces and audit records join in the backend. An OpenTelemetry Collector tailing the JSONL file:

```yaml
receivers:
  filelog/mcp-audit:
    include:
      - /var/log/mcp/audit.jsonl
    start_at: end
    operators:
      - type: json_parser
        parse_from: body
        timestamp:
          parse_from: attributes.ts
          layout_type: gotime
          layout: "2006-01-02T15:04:05.999Z07:00"
      - type: trace_parser
        trace_id:
          parse_from: attributes.trace_id
        span_id:
          parse_from: attributes.span_id

processors:
  resource/mcp:
    attributes:
      - key: service.name
        value: mcp-audit-demo
        action: upsert
  batch:
    timeout: 5s
    send_batch_size: 512

exporters:
  otlphttp/observability:
    endpoint: "https://otel.example.com:4318"

service:
  pipelines:
    logs:
      receivers:
        - filelog/mcp-audit
      processors:
        - resource/mcp
        - batch
      exporters:
        - otlphttp/observability
```

4. Validate the collector config before shipping it:

```bash
otelcol-contrib validate --config=./otel-collector.yaml && echo "config OK"
```

5. Confirm the span attributes are what you think they are, without a backend, by swapping the exporter for a console one:

```bash
OTEL_TRACES_EXPORTER=console .venv/bin/python run_http.py 2>&1 | grep -A 20 '"name": "mcp.tools/call reconcile"' | head -n 25
```

**Check your understanding**

- **Q25.** The span is opened with `SpanKind.SERVER` and, when a `traceparent` arrives, as a child of the caller's context. What breaks in the backend if you open it as a root span instead — and what specifically do you lose when the caller is the host application?
- **Q26.** The audit record stores `trace_id` and `span_id` as lowercase hex strings, not as integers. Why does the format matter for the join?
- **Q27.** `mcp.tool.rows_matched` is set as a span attribute and also written into the audit record. Which of the two may be sampled away, and what does that imply about which one a compliance answer can be built on?
- **Q28.** The exercise sets `mcp.*` attributes rather than reusing `gen_ai.*`. Explain the reasoning, and say what you must do the day MCP semantic conventions stabilise.
- **Q29.** `BatchSpanProcessor` buffers spans in memory and flushes asynchronously. Name the scenario in which this silently loses the trace of the most interesting request of the day, and state why the same weakness does *not* apply to the `fsync`'d audit trail.

---

## Exercise 7 — Auditing identity: subject, audience, and the confused deputy

An audit record that says *what happened* but not *on whose authority* answers half the question.

1. Extract the authenticated principal. In the Python SDK, a validated token is available from the auth middleware context:

```python
try:
    from mcp.server.auth.middleware.auth_context import get_access_token
except ImportError:                                   # SDK built without auth
    get_access_token = None                           # type: ignore[assignment]


def principal(ctx: Context) -> dict[str, Any]:
    """Identity of the caller, as this server is entitled to assert it."""
    if get_access_token is None:
        return {"auth": "none", "reason": "auth_middleware_absent"}
    token = get_access_token()
    if token is None:
        return {"auth": "none", "reason": "unauthenticated_transport"}
    return {
        "auth": "oauth2",
        "client_id": getattr(token, "client_id", None),
        "scopes": sorted(getattr(token, "scopes", []) or []),
        "resource": getattr(token, "resource", None),
        "expires_at": getattr(token, "expires_at", None),
        "token_digest": fingerprint(getattr(token, "token", "")),
    }
```

2. Make an unauthenticated call against a server that requires a token, and read the challenge:

```bash
curl -sS -D - -o /dev/null http://127.0.0.1:8001/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | grep -i -E '^(HTTP/|www-authenticate)'
```

Representative:

```
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer resource_metadata="http://127.0.0.1:8001/.well-known/oauth-protected-resource"
```

3. Follow the discovery document the challenge pointed at:

```bash
curl -sS http://127.0.0.1:8001/.well-known/oauth-protected-resource | jq
```

Representative:

```
{
  "resource": "http://127.0.0.1:8001/mcp",
  "authorization_servers": [
    "https://auth.example.com"
  ],
  "scopes_supported": [
    "ledger.read"
  ],
  "bearer_methods_supported": [
    "header"
  ]
}
```

4. Write the authorization decision into the audit trail — **both** outcomes, not only the denials:

```python
def audit_authorization(ctx: Context, *, method: str, decision: str,
                        reason: str | None = None) -> None:
    audit(
        "authz.decision",
        method=method,
        decision=decision,               # allow | deny
        reason=reason,
        principal=principal(ctx),
        session_id=getattr(ctx.session, "session_id", None) or "stdio",
        request_id=str(ctx.request_id),
    )
```

5. Prove that the token's audience binds to *this* server. The security model forbids accepting a token that was not issued for you:

```python
EXPECTED_RESOURCE = os.environ.get("MCP_RESOURCE_URI", "https://mcp.example.com/mcp")


def assert_audience(token_resource: str | None) -> None:
    """Reject a token minted for a different resource. RFC 8707 audience binding."""
    if token_resource != EXPECTED_RESOURCE:
        raise PermissionError(
            f"token audience {token_resource!r} does not match {EXPECTED_RESOURCE!r}"
        )
```

6. Query the audit trail the way a reviewer would — "everything one principal did in one session":

```bash
jq -c 'select(.principal.client_id == "ide-client-9f2") |
       {ts, event, method, tool, decision, outcome, session_id}' audit/audit.jsonl
```

7. Now find the pattern that should alarm you — a token accepted with an audience that is not yours:

```bash
jq -c 'select(.event == "authz.decision" and .decision == "allow" and
              .principal.resource != "https://mcp.example.com/mcp") |
       {ts, client_id: .principal.client_id, resource: .principal.resource}' audit/audit.jsonl
```

**Check your understanding**

- **Q30.** The audit record stores `token_digest`, never the token. What investigative capability does the digest preserve, and which one does it deliberately destroy?
- **Q31.** Define *token passthrough* in the MCP context, state the spec's position on it, and explain precisely how it corrupts the audit trail of the downstream API — not just the MCP server's own.
- **Q32.** A reviewer asks: "can we use `Mcp-Session-Id` as the identity of the caller?" Answer, citing the security guidance, and say what a session id *is* legitimately good for in an audit record.
- **Q33.** Step 4 audits `allow` decisions as well as `deny`. Most teams only log denials. Give two questions that become unanswerable if you log only the denials.
- **Q34.** A static MCP server credential is shared by all users of the host application. The audit trail faithfully records `client_id` on every call. What is the residual gap, and where must it be closed?

---

## Exercise 8 — What a server-side audit trail cannot prove

The hardest part of this topic is knowing where your evidence stops.

1. Add a tool that asks the client to run an LLM completion on the server's behalf — `sampling/createMessage`. The server is now spending someone else's model budget, so it must be recorded:

```python
@mcp.tool()
async def summarize_ledger(account: str, ctx: Context) -> str:
    """Ask the client's model to summarize a ledger. Server-initiated sampling."""
    request_id = str(ctx.request_id)
    audit("sampling.requested",
          request_id=request_id,
          session_id=getattr(ctx.session, "session_id", None) or "stdio",
          tool="summarize_ledger",
          max_tokens=300,
          prompt_digest=fingerprint(f"summarize ledger for {account}"))
    try:
        result = await ctx.session.create_message(
            messages=[{
                "role": "user",
                "content": {"type": "text", "text": f"Summarize ledger {account}."},
            }],
            max_tokens=300,
        )
    except Exception as exc:
        audit("sampling.refused", request_id=request_id, error_type=type(exc).__name__)
        raise
    audit("sampling.completed",
          request_id=request_id,
          model=getattr(result, "model", None),
          stop_reason=getattr(result, "stopReason", None))
    return getattr(result.content, "text", "")
```

2. Call it from a client that does not declare the `sampling` capability and observe the failure:

```bash
printf '%s\n' \
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"summarize_ledger","arguments":{"account":"ACC-77"}}}' \
| .venv/bin/python audit_server.py 2>/dev/null | jq -c 'select(.id == 2) | {isError: .result.isError, text: .result.content[0].text}'
```

Representative:

```
{"isError":true,"text":"Error executing tool summarize_ledger: Client does not support sampling"}
```

3. Inspect what the audit trail now claims, and be precise about what it does and does not establish:

```bash
jq -c 'select(.event | startswith("sampling.")) | {event, model, stop_reason, error_type}' audit/audit.jsonl
```

4. Do the same reasoning for a destructive tool. Add the annotations the client uses to decide how to ask for consent:

```python
@mcp.tool(
    annotations={
        "title": "Void an invoice",
        "readOnlyHint": False,
        "destructiveHint": True,
        "idempotentHint": False,
        "openWorldHint": False,
    }
)
async def void_invoice(invoice_id: str, ctx: Context) -> str:
    """Void an invoice. Irreversible; requires host approval before invocation."""
    audit("tool.call.started",
          tool="void_invoice",
          destructive=True,
          consent_attested_by="client",
          consent_evidence=None,
          request_id=str(ctx.request_id),
          arguments=redact({"invoice_id": invoice_id}))
    ...
```

5. Note the deliberately null field. Run the query a compliance reviewer will actually run:

```bash
jq -c 'select(.destructive == true) |
       {ts, tool, request_id, consent_attested_by, consent_evidence}' audit/audit.jsonl
```

Expected:

```
{"ts":"2026-09-17T10:31:02.884+00:00","tool":"void_invoice","request_id":"7","consent_attested_by":"client","consent_evidence":null}
```

6. Check your retention and redaction posture against the material actually on disk:

```bash
grep -c -i -E '(bearer [A-Za-z0-9._-]{20,}|-----BEGIN|password"?\s*:\s*"[^"]+")' audit/audit.jsonl || echo "0 (no raw secrets found)"
jq -r '.arguments | tostring' audit/audit.jsonl | sort -u | head
```

**Check your understanding**

- **Q35.** `consent_evidence` is `null` and `consent_attested_by` is `"client"`. Explain in one paragraph why a server-side audit trail structurally cannot prove that a human approved a destructive tool call, and what the correct architecture is for an organisation that needs that proof.
- **Q36.** The tool annotations (`destructiveHint`, `readOnlyHint`) are described in the spec as **hints**. What does that word cost you if you build an authorization control on them, and where must the real control live?
- **Q37.** `sampling.completed` records `model` and `stopReason` returned by the client. Is the server entitled to treat those as true? What is the class of claim they belong to, and how should the audit schema mark that?
- **Q38.** Retention: the operator log holds full argument values for 7 days; the audit trail holds redacted arguments plus digests for 7 years. Give the two independent reasons this asymmetry is correct.
- **Q39.** Someone proposes reconstructing the exact ledger query from `arguments_digest` by brute-forcing a small argument space. Is that a flaw in the design? Under what conditions does it become one, and what is the mitigation?

---

## Exercise 9 — Diagnosis drill

Three failures that look identical from the client ("the server stopped responding") and are diagnosed entirely differently.

1. **Symptom A — the session died.** Reproduce it by restarting the server and reusing the old session id:

```bash
kill %1 2>/dev/null; sleep 1
.venv/bin/python run_http.py 2>operator-http.log & sleep 2

curl -sS -o /dev/null -w 'status=%{http_code}\n' http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  -d '{"jsonrpc":"2.0","id":20,"method":"tools/list","params":{}}'
```

Expected:

```
status=404
```

2. **Symptom B — the notification stream has a gap.** Open the server-to-client stream, interrupt it, and reconnect:

```bash
timeout 3 curl -N -sS http://127.0.0.1:8000/mcp \
  -H 'Accept: text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" \
  -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" | tee /tmp/stream1.sse

LAST_ID=$(sed -n 's/^id: //p' /tmp/stream1.sse | tail -n 1)
echo "last-event-id=${LAST_ID:-<none>}"

curl -N -sS http://127.0.0.1:8000/mcp \
  -H 'Accept: text/event-stream' \
  -H "Mcp-Session-Id: $SESSION" \
  -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  -H "Last-Event-ID: ${LAST_ID}" &
```

3. **Symptom C — the stream is fine but the client sees nothing.** Check the accept header the client sent:

```bash
curl -sS -o /dev/null -w 'status=%{http_code}\n' http://127.0.0.1:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H "Mcp-Session-Id: $SESSION" -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION" \
  -d '{"jsonrpc":"2.0","id":21,"method":"tools/list","params":{}}'
```

Representative:

```
status=406
```

4. Close the session cleanly and make sure the closure is auditable:

```bash
curl -sS -o /dev/null -w 'status=%{http_code}\n' -X DELETE http://127.0.0.1:8000/mcp \
  -H "Mcp-Session-Id: $SESSION" \
  -H "MCP-Protocol-Version: $MCP_PROTOCOL_VERSION"
```

5. Build the triage table for yourself, from the evidence each symptom leaves:

```bash
jq -c 'select(.event | test("^session\\.")) | {event, session_id, reason}' audit/audit.jsonl
grep -c '"level":"error"' operator-http.log
```

6. When the shell stops being enough, attach the Inspector, which speaks the protocol and shows you the raw message log:

```bash
npx @modelcontextprotocol/inspector .venv/bin/python audit_server.py
```

**Check your understanding**

- **Q40.** Symptom A returned `404` on a request that was syntactically perfect. What must a spec-conformant client do on receiving a `404` to a session-bearing request, and what must it *not* do?
- **Q41.** In step 2, `LAST_ID` was very likely empty. What does an SSE stream with no `id:` fields tell you about the server's resumability, and what is the consequence for any notification sent while a client is disconnected?
- **Q42.** Symptom C returned `406`. Which header caused it, and why does the transport insist on it even for a request that will in practice be answered with a single JSON object?
- **Q43.** You now have three failures — `404`, a silent notification gap, and `406` — none of which produced a JSON-RPC error object. Where, specifically, must you be instrumenting to see all three, and what does that tell you about instrumenting *only* the MCP handler layer?
- **Q44.** Rank these four evidence sources for diagnosing "a tool returned the wrong answer three hours ago": the Inspector's message log, the span in your tracing backend, the operator log on stderr, the audit trail. Justify the ordering.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A1.** If the server creates the file, the mode is determined by the process `umask` at whatever moment the first write happens — which varies by launcher (systemd, a container runtime, a shell, an IDE spawning a stdio server). Pre-creating it makes the permission a deliberate, reviewable artefact of deployment rather than an accident of the runtime. Second, it means the first audit record is never the record that also happened to create a world-readable file: there is no window in which the file exists with the wrong mode. In production the same reasoning extends to ownership — the audit file should be writable by the server user and readable by the log shipper, and by nobody else.

**A2.** An audit trail's job is to remain credible about a process that may itself be compromised or malfunctioning. If it lives on the server's own working volume, then (a) a bug that fills the disk takes the audit trail down at exactly the moment it is most needed, (b) anything that can write arbitrary files as the server user can rewrite history, and (c) the evidence dies with the host. The production pattern is: write locally append-only, ship continuously off-box to storage the server user cannot modify, and treat the local file as a buffer, not as the record of truth.

### Exercise 1

**A3.** The **client** decides. Per the lifecycle, the client sends the latest version it supports; if the server does not support it, the server responds with a version it *does* support. If the client cannot support the version the server returned, it MUST disconnect — it must not proceed to send `notifications/initialized` and start issuing requests. The handshake succeeding at the transport level is not the same as the session being usable. For observability this is a specific event worth recording: a `session.rejected` audit record with both the requested and offered versions tells you, months later, that a fleet upgrade left a cohort of old clients stranded.

**A4.** `serverInfo` is the only place a client — and therefore your telemetry — learns which build it is talking to. Reporting the SDK version means that when you find a bad answer in the audit trail, you cannot tell which deployment of your server produced it, so you cannot bound the blast radius or confirm a fix rolled out. It should carry your service's own version, ideally something traceable to a commit: `FastMCP("audit-demo", version=os.environ["MCP_SERVICE_VERSION"])`, with the value injected at build time from a git describe or image tag. The same string should appear on every audit record and as `service.version` on every span, so the three join.

**A5.** Any three of:
- **`protocolVersion` (negotiated)** — answers "was this session speaking the revision we think it was?", which determines which features were even available and how certain fields must be interpreted.
- **`clientInfo.name` / `clientInfo.version`** — answers "which client software did this?", the first question in any incident where one client population misbehaves.
- **`capabilities` (client side)** — answers "could this client have been asked to sample, or to elicit?", which bounds what the server was able to make the session do.
- **`Mcp-Session-Id`** — the join key that makes every later record in the session attributable to this handshake.
- **`serverInfo.version`** — answers "which build served it?"

### Exercise 2

**A6.** Permitted. The logging specification does not require a client to call `logging/setLevel` before receiving messages; if no level has been set, the server MAY send messages at whatever level it chooses, or define its own default. This is worth internalising because it means **the absence of `logging/setLevel` does not mean "log nothing"** — the volume and sensitivity of what you emit by default is your design decision, and defaulting to `debug` on a server that handles customer data is a disclosure bug, not a verbosity preference.

**A7.** The server declares `logging` in its `capabilities` during `initialize` because it is the party that *produces* log notifications — the capability advertises "I can emit `notifications/message`". The client sends `logging/setLevel` because it is the party that *consumes* them, and only it knows its context: an IDE in developer mode wants `debug`, the same IDE in a user's hands wants `warning`. Putting the control on the consumer side also means one server serving many clients can be verbose for one and quiet for another without redeploying. The filtering semantics are inclusive downward in severity: setting `warning` delivers `warning` and everything more severe, per RFC 5424 ordering.

**A8.** Three protocol-level reasons, any of which is disqualifying on its own:

1. **The audited party controls the filter.** The client sets the level. A client that sets `emergency` — or a malicious one that sets it deliberately — suppresses the record of its own actions. An audit control the subject can switch off is not a control.
2. **Delivery is not guaranteed and not acknowledged.** `notifications/message` is a JSON-RPC *notification*: no `id`, no response, no retry semantics. Over Streamable HTTP without an event store, anything emitted while the client is disconnected is simply gone (Exercise 9, Q41). There is no mechanism by which the server learns a record was lost.
3. **The record is addressed to the wrong party.** It goes to the client — the thing being audited — and to nowhere else. There is no path to independent, tamper-evident storage. A reviewer would have to obtain the evidence from the entity under review.

A fourth, practical reason: the spec explicitly directs that log messages should not contain credentials, PII, or sensitive internal state, precisely because they cross a trust boundary — which is the opposite of an audit trail's requirement to record exactly who did what to which record.

**A9.** The spec says servers SHOULD rate limit log messages. Ignoring it produces a specific and nasty failure: the notification stream saturates the same transport that carries responses. Over stdio you fill the pipe buffer and the server blocks on write, stalling the tool it was narrating; over Streamable HTTP you fill the SSE stream and hit backpressure in the session manager. Either way the symptom presented to the user is "the tool hung", and the cause is your logging. The correct instrumentation for a 50 000-row export is a small number of `notifications/progress` messages (which are designed for exactly this, carry a `total`, and can be sampled by the client) plus a single summary log at the end — with the per-row detail going to stderr or the audit sink, which are not on the protocol's critical path.

### Exercise 3

**A10.** The server MUST NOT write anything to stdout that is not a valid MCP message; the transport is a newline-delimited JSON-RPC stream and any other byte corrupts the framing. The server MAY write UTF-8 to stderr for logging, and the client MAY capture, forward, or ignore it. The practical corollary: on a stdio server, `print()`, a stray `pdb` prompt, a library that logs to stdout by default, and a shell wrapper that echoes a banner are all session-killing bugs — and they must be hunted in dependencies, not just in your own code. `logging.basicConfig(..., force=True)` with an explicit stderr handler, as in step 4, exists to defeat libraries that installed a stdout handler behind your back.

**A11.** No, the `print()` does not break a Streamable HTTP session — stdout is not the wire there, so the line goes to the process's stdout and is merely misfiled. It is still not acceptable, for three reasons. First, the same code must remain deployable over stdio; a server that only works on one transport has silently lost a deployment option. Second, the output is unstructured, unlabelled, and uncorrelated — it cannot be joined to a request, so it is of no diagnostic value at 3 a.m. Third, it bypasses every redaction and level control you built, so it is the exact mechanism by which a customer identifier ends up in a container log that ships to a different retention regime than the one you designed.

**A12.** The **cost** is a durability barrier per record: `fsync` forces the write through the page cache to stable storage, which on a spinning disk or a network volume can be single-digit milliseconds, and it serialises. On a hot tool at hundreds of calls per second this is the dominant latency term. The **guarantee** is that the record survives a process crash, an OOM kill, and a host power loss — which is the entire point of an audit trail: the interesting failures are exactly the ones where the process does not get to run its shutdown path. The **production pattern** is group commit: buffer records in memory and `fsync` once per small batch or per few milliseconds, whichever comes first, so that N records cost one barrier instead of N. You accept a bounded loss window (the batch interval) in exchange for amortised cost, and you make that window an explicit, documented number rather than an accident. For genuinely irreversible operations, take the full per-record `fsync` and write the record *before* the side effect.

**A13.** Because the interesting failures are the ones where `finished` never gets written. A single end-of-call record cannot distinguish between "the call never happened", "the call happened and the process was killed mid-flight", and "the call happened and hung". The started/finished pair turns all three into a detectable state: an unmatched `started` is positive evidence that work was initiated and its outcome is unknown, which is precisely what a reviewer needs to know about a destructive operation. It also gives you a real duration (rather than the handler's self-reported one) and lets you alert on in-flight calls that never close — the signature of a deadlock, a cancelled request, or a crash loop.

**A14.** The digest lets you answer **"was this the same call as that one?"** and **"is this the specific input we are investigating?"** without ever storing the input. Given a customer identifier from a support ticket, you compute its digest with the same canonicalisation and grep the trail: every matching record is a call on that customer. You can count how many times an argument recurred, detect replay, and correlate the same input across two services — all questions `"[redacted]"` makes impossible, because every redacted value is indistinguishable from every other. What the digest does not do is let you read a value you never stored, which is the point; and note the caveat in Q39 about low-entropy inputs.

### Exercise 4

**A15.** The JSON-RPC `id` is only required to be unique **within a single session**, and clients commonly restart it at 1 or use small integers. Across a fleet, `request_id: "3"` matches thousands of unrelated calls per minute. It becomes unique when combined with the **session id** — and, to survive a server restart that reissues session ids, with the **server instance identity and a timestamp**. The durable key most teams settle on is the trace id, with `(session_id, request_id)` retained as the protocol-level coordinates so you can point at a specific message in a captured stream.

**A16.** Placing the token in the client's hands means the client can correlate incoming progress notifications with whatever it already uses to track that operation — a UI spinner, a promise, a task row — without maintaining a mapping from a server-chosen value. It also lets the client scope and rotate tokens as it likes. The server must never assume the token's format or type: the spec allows a string **or** an integer, it must be unique among the sender's active requests, and it is opaque. Concretely: do not parse it, do not assume it is numeric, do not use it as a database key, and do not log it as if it were an identifier with meaning. Echo it back unchanged in `notifications/progress`, and if you want a server-side handle, mint your own.

**A17.** The MCP specification reserves `_meta` key prefixes for itself — names in the `modelcontextprotocol.io/` namespace and MCP-owned prefixes are reserved for protocol-defined meanings, and the spec may define new ones in future revisions. An unprefixed `traceparent` is squatting on a name the protocol may later assign different semantics to, which would turn your working deployment into a silent, version-dependent misinterpretation at the next revision bump. Using a prefix on a domain you control (`com.example/traceparent`) guarantees no collision, ever, and makes the ownership of the key self-documenting to the next engineer.

**A18.** Widest to narrowest:

1. **Host turn id** — one user interaction, potentially fanning out to several servers, several sessions, and many calls.
2. **Trace id** — one logical operation, spanning every service it touched; normally one per turn, but a turn can start more than one trace.
3. **Session id** — one client-to-server connection; long-lived, spanning many turns.
4. **Request id** — one JSON-RPC message within a session.
5. **Progress token** — one in-flight request's progress channel; narrowest, and it exists only for requests that opted in.

Note that trace id and session id are not nested — they cross-cut. A single session carries many traces, and a single trace touches many sessions. That is exactly why an audit record needs both: neither one alone can reconstruct both "everything this connection did" and "everything this user action caused".

**A19.** It tells you the client abandoned the request before the server finished: `notifications/cancelled` is the client saying "stop, I no longer want this result", and the missing `finished` means your handler either did not observe the cancellation or was killed mid-flight. That is an operationally important state, because **cancellation does not undo side effects** — the tool may well have already written to the downstream system. You should be emitting a `tool.call.cancelled` audit event carrying the request id and the spec's optional `reason`, plus a `tool.call.finished` with an `outcome` of `cancelled` once your handler actually unwinds, so that the started/finished invariant holds. Without it, an incident reviewer cannot distinguish "the user cancelled cleanly" from "the server crashed with the transaction half-applied".

### Exercise 5

**A20.** Because the two failures have different audiences and different remedies. A tool that fails for a domain reason — no such account, insufficient balance, the upstream API said no — has produced *information the model needs in order to do its job*: it should try a different account, ask the user for a correction, or report the problem. If that were returned as a JSON-RPC error, it would be handled by the client's transport layer and never reach the model, which would see only an opaque failure and could not recover. Returning it inside a successful `CallToolResult` with `isError: true` puts the failure text in the model's context where it can be reasoned about, while still marking it unambiguously as a failure so the client can style it differently and your metrics can count it correctly.

**A21.** `isError: true` is for the **model** (and, through it, the user). A JSON-RPC error is for the **client implementation** (and, through it, the developer and the operator). Remediations: the model can retry with corrected arguments — `ACC-999` was a typo for `ACC-99` — which the client's transport layer has no ability to reason about. The client implementation can re-run `tools/list` and rebuild its tool registry when it gets `-32602 Unknown tool`, or refresh a token on a `401`, which the model has no ability to do and should not be shown. Sending each to the wrong consumer produces the two classic failures: models that hallucinate around opaque errors, and clients that display a raw stack trace as if it were an answer.

**A22.** The two explanations are:

1. **A downstream dependency is failing.** Your tools run, call something, get errors, and correctly surface them as `isError`. Protocol errors stay flat because the protocol is fine.
2. **The model is calling your tools with bad arguments.** Schema-valid but semantically wrong — a nonexistent account, an out-of-range date. Also correctly `isError`, also leaves the protocol untouched. This often follows a tool description change or a model upgrade.

To discriminate, group the audit trail's failed calls by `error_type` and by the argument shape:

```bash
jq -c 'select(.outcome == "tool_error") | {error_type, args: .arguments}' audit/audit.jsonl \
  | sort | uniq -c | sort -rn | head
```

A concentration on one `error_type` from a dependency wrapper (`TimeoutError`, `ConnectionError`) with varied arguments points at (1). A spread of `LookupError`/`ValueError` over arguments that do not exist in your data points at (2). Cross-check against `mcp:tool_error_ratio` per `clientInfo.version` — if the spike aligns with one client cohort, it is a caller-side regression.

**A23.** It prevents **division by zero producing NaN** when a tool has received no calls in the window — which is the normal state for a low-traffic tool, and which would otherwise make the recording rule emit no series at all (or a NaN that silences the alert). The artefact is that at very low request rates the ratio is no longer a true ratio: with a denominator floored at 0.001/s, a single error in five minutes yields a value far above the real proportion, so the graph shows alarming spikes on tools nobody is calling. The standard mitigation is to gate the alert on volume as well as ratio — require `sum by (tool) (rate(mcp_tool_calls_total[5m])) > 0.05` in the alert expression — so you never page on a denominator of three requests.

**A24.** `account` is unbounded caller-supplied data. Prometheus creates one time series per unique label combination and holds them in memory; a metric labelled by account identifier will create a series per customer, per tool, per outcome, and keep it for the retention period. This is the canonical cardinality explosion: it degrades query performance, then ingestion, then takes the Prometheus server out of memory — and it takes your visibility into the outage with it. There is a second problem: you have now written customer identifiers into a metrics store that almost certainly has a different retention and access-control regime than the one you designed for PII.

The right place for that question is the **audit trail**, which is designed for high-cardinality, per-event, per-subject records and is queried on demand rather than scraped every 15 seconds:

```bash
jq -r 'select(.outcome == "tool_error") | .arguments.account' audit/audit.jsonl | sort | uniq -c | sort -rn
```

Metrics answer "is something wrong and how bad"; the audit trail answers "who exactly".

### Exercise 6

**A25.** If you open a root span, the backend records a trace containing only your server — correct in isolation, disconnected from everything else. You lose: the position of the MCP call within the user's overall operation, the latency contribution of your server relative to the whole turn, and the ability to see sibling calls to other MCP servers made for the same turn. When the caller is the host application specifically, you lose the single most valuable link in the whole picture: the connection between *the model decided to call this tool* and *this tool did this work*. That link is what turns "the assistant gave a wrong answer" into "the assistant called `reconcile` with `ACC-999`, got `isError`, and did not retry". `SpanKind.SERVER` is the correct kind because your process is the callee of a remote request; it tells the backend to treat the span as a service entry point for service-graph and RED-metric derivation.

**A26.** OpenTelemetry defines trace ids as 16-byte and span ids as 8-byte values, and every backend, every query UI, and the W3C `traceparent` header represent them as **lowercase hexadecimal**, zero-padded to 32 and 16 characters. Python's integer representation is an implementation detail of the SDK. If you write `span_ctx.trace_id` as an integer, the value in your audit record will not match the string in your tracing backend, the string in the `traceparent` header, or the string the log-correlation processor expects — so the join silently produces no results, which is worse than an error because it looks like "no data" rather than "wrong format". `format(value, "032x")` / `format(value, "016x")` is the canonical conversion; note the zero-padding matters, as a trace id with leading zero bytes would otherwise be short.

**A27.** The **span** may be sampled away. Head-based sampling decides at span creation whether to record, and a typical production configuration keeps 1–10% of traces; tail-based sampling keeps errors and slow requests and discards the rest. Either way, the majority of successful calls leave no span. The **audit record is written unconditionally and `fsync`'d**, so it exists for every call. Therefore any statement that must be complete — "show every call that touched this account", "prove this operation was or was not performed" — must be built on the audit trail. Traces are for diagnosis and for understanding shape and latency; they are a sample, and a sample cannot answer an existence question in the negative. The corollary for your schema: anything a compliance answer might depend on must be a field in the audit record, not only a span attribute.

**A28.** The `gen_ai.*` conventions describe interactions with a generative model — prompts, completions, token counts, model names. An MCP `tools/call` is not that: it is an RPC to a tool server, and modelling it as a GenAI operation would put it in the wrong place in every dashboard built on those conventions and would leave the fields you actually need (session id, tool name, transport) homeless. The RPC conventions (`rpc.system`, `rpc.method`, `rpc.jsonrpc.request_id`) *do* fit and are stable, so use them. MCP-specific fields go in a private `mcp.*` namespace, which is the documented way to carry attributes for which no convention exists yet. When MCP conventions stabilise, you migrate: emit both the old and new attribute names for one deprecation window so existing dashboards and alerts keep working, update the queries, then drop the private names. The `gen_ai.*` conventions are explicitly still evolving, so pin the version you targeted in a comment and re-check on upgrade.

**A29.** The scenario is a **crash or an OOM kill**. `BatchSpanProcessor` holds spans in a queue and flushes on a timer or when the batch fills; if the process dies, the queue dies with it. The request that caused the crash — the one you most want to see — is precisely the one whose span was still in the buffer. The same applies to a `SIGKILL` from a container runtime enforcing a memory limit, where no shutdown hook runs and `force_flush()` never happens. The `fsync`'d audit trail does not share this weakness because the durability barrier is taken **per record, before the call returns**: by the time the tool has done anything observable, the `tool.call.started` record is already on stable storage. This is the concrete reason the two sinks exist separately rather than being unified into "just send everything to the observability backend" — they have different durability contracts because they answer different kinds of question.

### Exercise 7

**A30.** The digest **preserves the ability to correlate**: you can tell that two calls, possibly in different services or different days, presented the same token; you can detect a token being replayed from an unexpected source; and given a token recovered during an incident, you can compute its digest and find every place it was used. It **destroys the ability to use the token**: nobody who reads the audit trail — including an attacker who exfiltrates it, and including your own engineers — can replay the credential. Storing the raw token would make the audit trail itself a credential store, i.e. a higher-value target than the system it audits. Add a per-deployment salt to the digest if the token space is guessable, and record `jti` instead when the token is a JWT and the authorization server issues one, since that is a purpose-built correlation identifier.

**A31.** *Token passthrough* is an MCP server accepting a bearer token from its client and forwarding that same token, unchanged, to an upstream API — rather than validating it for itself and obtaining its own credential for the upstream call. The specification's security best practices **explicitly forbid it**: an MCP server MUST NOT accept a token that was not issued for it, and MUST validate the audience.

The audit consequence is worse downstream than locally. The upstream API's logs will show the call arriving with a token whose audience is the upstream API, with the original client's identity — so the upstream's audit trail records *the user* as having made a call the user never made and never saw, made on their behalf by an intermediary that appears nowhere in the record. Every control the upstream built on those logs is now wrong: rate limits attribute to the wrong party, anomaly detection sees the user's pattern change for no reason, and an investigation of "who called this endpoint" produces a name with no way to discover the MCP server sat in the middle. The correct pattern is token exchange or a distinct service credential, with the MCP server recording both the calling principal and its own upstream identity, so the chain of delegation is explicit in both trails.

**A32.** **No.** The security guidance is unambiguous: servers MUST NOT use sessions for authentication. A session id is a routing and state-continuity handle, not a credential — it is not bound to a verified identity, it is not audience-restricted, it has no issuer, and it typically travels in a header that is easier to obtain than a bearer token. Authorization must be established per request from the validated access token.

What a session id **is** legitimately good for in an audit record is correlation: it groups every request from one connection, letting a reviewer reconstruct a coherent sequence of actions and detect a session that changes behaviour mid-stream. The spec also requires session ids to be secure and non-deterministic (a UUID or equivalent CSPRNG output) and recommends binding them to user-specific information — which makes them a *useful* forensic field precisely because they cannot be guessed or enumerated, without making them an *authoritative* one.

**A33.** Two of:
- **"What did this compromised account actually access?"** — the entire value of an incident investigation is the list of successful accesses. A deny-only log tells you what an attacker failed to do, which is the part you did not need to know.
- **"Is this permission still in use?"** — you cannot safely remove a scope or narrow a role without evidence that nothing is exercising it. Deny-only logs make every permission look removable and every removal a gamble.
- **"Was the baseline normal before the incident?"** — anomaly detection needs the normal case. With only denials, you have no distribution to compare against.
- **"Did the control work?"** — proving a control is *enforced* requires showing allows and denies flowing through the same decision point; a deny-only log is consistent with a control that is bypassed for most traffic.

**A34.** The residual gap is that **`client_id` identifies the application, not the human**. Every user of the host application produces identical audit records, so the trail can establish "this IDE did it" but never "this person did it" — and that is exactly the granularity a compliance review, an insider-threat investigation, or a data-subject request needs. It also breaks least privilege: the shared credential must hold the union of every user's permissions.

It must be closed at the **authorization layer**, not in the audit code — by having the host application perform a user-level OAuth flow so that the token presented to the MCP server carries a `sub` identifying the human, with scopes reflecting that user's entitlements. Trying to close it by having the client pass a user identifier in tool arguments or `_meta` does not work: that value is unauthenticated and self-asserted, so the audit trail would record a claim the server has no basis to believe, which is worse than recording nothing. If a user-level flow is genuinely impossible, the honest response is to mark the field as unattested in the schema rather than to invent it.

### Exercise 8

**A35.** The MCP server sits on the far side of a trust boundary from the human. It receives a `tools/call` message and nothing else; the protocol carries no attestation of consent, and even if the client sent one, the server would have no way to verify it — it would be a self-report from the party whose behaviour is in question. The specification places human-in-the-loop approval squarely in the **client/host**, which owns the UI, and the server is architecturally incapable of distinguishing "the user clicked Approve" from "the host auto-approved" from "a compromised host fabricated the call". Recording `consent_attested_by: "client"` with `consent_evidence: null` is the honest encoding of that: it states who the assertion comes from and admits there is no evidence.

An organisation that needs real proof must produce it where consent happens. Either the host emits its own audit record of the approval, into the same tamper-evident store, joined by trace id — so the reviewer sees the approval and the invocation as two independently-sourced records — or the host obtains a signed consent receipt (a short-lived, single-use token minted after the user approves, bound to the tool name and an argument digest) and passes it in `_meta`, which the server verifies and records. The second is stronger because the server can refuse to act without it; the first is far easier and is usually enough. What does not work is any scheme where the only evidence is the server believing what the client told it.

**A36.** The word "hints" means they are **untrusted metadata supplied by the server for the client's benefit**, and the spec is explicit that clients must not make security-critical decisions based on annotations received from a server unless that server is trusted. A server can label a destructive tool `readOnlyHint: true`, by mistake or by design. If you build authorization on them, you have built a control whose input is supplied by the thing being controlled — a tool can promote itself to harmless.

Their legitimate purpose is **user experience**: they let the client decide how to present the approval — a quiet inline confirmation for a read, a modal with the arguments spelled out for a destructive write. The real control lives in the **authorization layer inside the server**: scope checks and an explicit allow/deny evaluated against the validated token before any side effect, audited as in Exercise 7. The annotation and the control should agree, and a mismatch between them is itself worth alerting on.

**A37.** No, the server is not entitled to treat them as true. `model` and `stopReason` come back in the client's `CreateMessageResult`; the client is the party that chose the model and ran the completion, and the server has no independent way to verify either. They are **client-asserted claims**, not server-observed facts — the same category as `clientInfo.name` from the handshake.

The audit schema should mark that distinction structurally rather than by convention, because the difference is invisible once the records are in a search index and a reviewer will otherwise read every field as equally authoritative. Nest asserted values under a key that names their source and carries no implication of verification:

```python
audit("sampling.completed",
      request_id=request_id,
      asserted_by_client={
          "model": getattr(result, "model", None),
          "stop_reason": getattr(result, "stopReason", None),
      },
      observed_by_server={
          "duration_ms": duration_ms,
          "response_digest": fingerprint(text),
      })
```

The same discipline applies throughout: `principal` from a validated token is observed; anything from `clientInfo`, `_meta`, or a tool argument is asserted.

**A38.** Two independent reasons:

1. **They answer different questions with different time horizons.** The operator log exists to debug a live or recent incident, where you need the actual values to reproduce the failure — and nobody debugs a seven-day-old incident from raw arguments. The audit trail exists to answer questions asked years later by auditors, regulators, or litigation, where the question is "did X happen to record Y", which redacted fields plus digests answer completely.
2. **Data minimisation and the cost of a breach scale with retention.** A store holding full customer data for seven years is a seven-year-long liability and, under most privacy regimes, is very hard to justify for a purpose that a digest satisfies. Keeping the full values for seven days keeps the window in which a leak of the operator log is damaging to seven days, while losing nothing you would actually have used. It also makes erasure requests tractable: you cannot delete a customer's data from a digest, because it is not there.

**A39.** It is not a flaw as designed, but it becomes one under a specific condition: **when the argument space has low entropy**. `{"year": 2026}` has a few dozen plausible values; an attacker with the digest and the canonicalisation rule enumerates them in microseconds and recovers the input exactly. The same applies to a national identity number, a phone number, a postcode, or any short enumerable identifier. For a high-entropy value — a UUID, a long free-text string — brute force is infeasible and the digest is genuinely one-way.

The mitigation is a **keyed digest** rather than a plain hash: HMAC-SHA-256 with a per-deployment secret held outside the audit store, so an attacker who obtains the trail cannot compute candidate digests at all. Correlation still works — the same input yields the same value for anyone holding the key — while enumeration requires compromising the key as well as the log. A per-tenant key additionally prevents cross-tenant correlation. The cheap version, if key management is out of reach, is a long random salt stored in the same secret manager as your other credentials; it is weaker than HMAC in principle but defeats precomputation, which is the practical attack.

### Exercise 9

**A40.** On receiving `404` (or `404 Not Found`) in response to a request carrying an `Mcp-Session-Id`, the client MUST treat the session as terminated and start a **new session** by sending a fresh `initialize` request without the session id. What it must **not** do is retry the same request with the same session id — the server has no state for it and never will, so retries are pure load and produce a retry storm across a fleet after any rolling restart. It also must not silently swallow the failure and report a generic error: the distinction between "session expired, reconnecting" and "the server is broken" is the difference between a self-healing client and a support ticket. A correct client re-initializes, replays whatever state it needs (roots, log level), and reissues the request — and emits a `session.reinitialized` telemetry event so you can see restart-induced churn in your dashboards.

**A41.** An SSE stream with no `id:` fields means the server has **not implemented resumability** — it has no event store. The `id` on an SSE event is what a client echoes back in `Last-Event-ID` to ask the server to replay from that point; with no ids, there is nothing to resume from, and the `Last-Event-ID` header in step 2 is ignored. The consequence is that **every notification produced while the client was disconnected is permanently lost**: log messages, progress updates, and list-changed notifications simply do not exist for that client. A network blip of two seconds is enough. This is the mechanical proof behind Q8 — a channel that loses messages during a disconnection, with no acknowledgement and no way to detect the gap, cannot carry an audit trail. Note also that when a server *does* implement resumability, the event ids must be globally unique within a session (per stream), because that is the cursor the replay is computed from.

**A42.** The `Accept` header. The Streamable HTTP transport requires the client to list **both** `application/json` and `text/event-stream` on a POST, and a server that receives only one may reject with `406 Not Acceptable`. The transport insists even for a request that will in practice get a single JSON object because **the server, not the client, chooses the response mode**, and it chooses per request. The same `tools/call` may be answered with a plain JSON body today and with an SSE stream tomorrow — because the tool started emitting progress notifications, or because the server was reconfigured, or because this particular invocation triggered a server-initiated `sampling/createMessage` that must be interleaved. Requiring both up front means the server can upgrade to a stream whenever it needs to, without a renegotiation and without breaking a client that assumed otherwise. A client that sends only `application/json` is declaring it cannot receive notifications at all.

**A43.** All three are **transport-layer** failures: they are HTTP status codes and stream-framing behaviour, and none of them ever reaches the JSON-RPC dispatcher, so no MCP handler runs and no `notifications/message` is emitted. To see them you must instrument the **HTTP layer** — an ASGI middleware, the reverse proxy, or the ingress — capturing status code, path, the presence and validity of `Mcp-Session-Id` and `MCP-Protocol-Version`, the `Accept` header, and the response content type.

What it tells you is that instrumenting only the MCP handler layer gives you a blind spot covering the entire class of failures in which **the request never became an MCP request** — which includes every authentication failure, every session-lifetime problem, every protocol-version mismatch, every content-negotiation bug, and every rate limit. These are disproportionately the failures that take down a whole client population at once, precisely because they are structural rather than per-call. The practical rule: your RED metrics must be emitted at the outermost layer that sees the request, with the MCP-level metrics nested inside, so that `http_requests_total` and `mcp_tool_calls_total` diverging is itself a signal.

**A44.** For a failure three hours in the past:

1. **The audit trail.** It is the only source guaranteed to exist for that specific call — unsampled, durable, and retained. It gives you the arguments (redacted, with digests), the principal, the outcome, and the correlation keys with which to pull everything else. Every other source is conditional; this one is not. Start here.
2. **The span in your tracing backend.** If it survived sampling, it is the richest single artefact: the full call tree, latency breakdown, downstream calls, and exception detail. Conditional on sampling policy (Q27) and on the process not having died before flush (Q29) — but when present, it usually contains the answer.
3. **The operator log on stderr.** Still within a typical 7-day retention, and it holds the full unredacted values and the stack trace. Ranked below the span because it is unstructured relative to a trace, uncorrelated unless you propagated the ids properly, and frequently rate-limited or dropped under exactly the load that caused the incident.
4. **The Inspector's message log.** Last, because it is a **live, interactive** tool: it shows you traffic happening now, in a session you are driving. It cannot show you a call from three hours ago in a production session at all. It is the right tool for reproducing the failure once the first three have told you what to reproduce — and it is excellent for that — but it is not evidence of a past event.

The ordering encodes the general principle: for questions about the past, prefer sources whose existence is unconditional, then sources whose existence is probable, then sources you must recreate.

</details>