#!/usr/bin/env bash
#
# ============================================================================
#  MCPA 3.1 - Interaction Patterns & Response Handling
#  BREAK & FIX laboratory  (exam version 2026-07-28, topic weight 6.5)
#
#  Certification: Model Context Protocol Associate (MCPA)
#  https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#  Protocol reference: https://modelcontextprotocol.io/specification/2025-06-18
#  JSON-RPC 2.0 reference: https://www.jsonrpc.org/specification
#
#  WHAT THIS SCRIPT DOES
#    1. Installs a tiny, dependency-free MCP server (Streamable HTTP, bound to
#       127.0.0.1:8931) plus a conformance harness, under /opt/mcp-lab.
#    2. Injects four controlled defects into the server's RESPONSE HANDLING.
#    3. Shows you the symptoms and leaves you to repair /opt/mcp-lab/server.py.
#
#  SAFETY / SCOPE
#    * Run this ONLY on a disposable lab VM. It creates a system user, a unit
#      file and a directory tree; `--uninstall` removes exactly those.
#    * Nothing leaves the host: the server binds to loopback, the tools are
#      read-only samples (load average, uptime, `statvfs` on a path).
#    * No existing service is touched. Nothing outside the paths listed by
#      `--what-it-touches` is created, modified or deleted.
#
#  USAGE
#    sudo ./mcpa-3.1-break-fix.sh            # install, break, brief, show symptoms
#    sudo ./mcpa-3.1-break-fix.sh --verify   # re-run the harness
#    sudo ./mcpa-3.1-break-fix.sh --restore  # ANSWER KEY: restore the correct server
#    sudo ./mcpa-3.1-break-fix.sh --uninstall
#
#  The full step-by-step solution is at the bottom of this file, commented out.
# ============================================================================

set -Eeuo pipefail

LAB_DIR="/opt/mcp-lab"
STATE_DIR="${LAB_DIR}/state"
MARKER="${LAB_DIR}/.mcp-lab-marker"
ANSWER_DIR="/root/.mcp-lab-answer-key"
UNIT_FILE="/etc/systemd/system/mcp-lab.service"
DISPATCH="/usr/local/bin/mcp-lab"
LAB_USER="mcplab"
LAB_PORT="8931"

if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi

trap 'echo "${R}[error]${N} aborted at line ${LINENO}" >&2' ERR

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
die()  { printf '%s[fatal]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

what_it_touches() {
  cat <<EOF
This script creates or replaces, and nothing else:

  ${LAB_DIR}/                 server.py, verify.py, state/
  ${ANSWER_DIR}/              pristine copy of server.py (mode 0600)
  ${UNIT_FILE}
  ${DISPATCH}
  system user '${LAB_USER}'   (--system, no home, nologin shell)
  TCP 127.0.0.1:${LAB_PORT}        (loopback only)
EOF
}

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root on a disposable lab VM (sudo $0)"; }

preflight() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required (standard library only, no pip packages)"
  python3 - <<'PYEOF' || die "python3 >= 3.9 is required"
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PYEOF
  if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :${LAB_PORT}" 2>/dev/null | grep -q ":${LAB_PORT}"; then
    if [ ! -e "$MARKER" ]; then
      die "TCP ${LAB_PORT} is already in use by something that is not this lab. Free it or edit LAB_PORT."
    fi
  fi
}

confirm_disposable() {
  [ "${MCP_LAB_I_UNDERSTAND:-0}" = "1" ] && return 0
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  head1 "Disposable-VM check"
  what_it_touches
  printf '\nType %sLAB%s to continue: ' "$B" "$N"
  read -r answer
  [ "$answer" = "LAB" ] || die "not confirmed - nothing was changed"
}

# ---------------------------------------------------------------------------
# The MCP server, written CORRECT. The defects are injected afterwards, so the
# pristine copy in ${ANSWER_DIR} is the real answer key.
# ---------------------------------------------------------------------------
write_server() {
  cat > "${LAB_DIR}/server.py" <<'PYEOF'
#!/usr/bin/env python3
"""
mcp-lab - a deliberately small MCP server: Streamable HTTP, loopback only.

It implements the slice of the protocol that MCPA topic 3.1 is about:

  initialize              version negotiation and capability announcement
  tools/list              cursor pagination over a listing
  tools/call              structured output and the two distinct error channels
  notifications/progress  out-of-band progress, streamed over an SSE response
  resources/list, read    the other half of the listing pattern

Reference: https://modelcontextprotocol.io/specification/2025-06-18
"""
from __future__ import annotations

import base64
import json
import os
import platform
import shutil
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER_NAME = "mcp-lab"
SERVER_VERSION = "1.0.0"
SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26"]
LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0]

BIND_HOST = os.environ.get("MCP_LAB_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("MCP_LAB_PORT", "8931"))
PAGE_SIZE = 2

# JSON-RPC 2.0 reserved codes, plus the MCP-specific "resource not found".
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
RESOURCE_NOT_FOUND = -32002

SESSIONS = set()


class RpcError(Exception):
    """A PROTOCOL failure: the request was malformed, unknown or unroutable.

    This is the channel for "the call never happened". A tool that ran and
    failed does NOT belong here - see _tool_failure().
    """

    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def _tool_failure(message):
    """An EXECUTION failure: a normal result carrying isError, not an RpcError.

    The model on the other side reads this, understands what went wrong and can
    retry. A JSON-RPC error would instead surface as a transport fault and kill
    the turn.
    """
    return {"content": [{"type": "text", "text": message}], "isError": True}


def _progress_notification(token, done, total, message):
    """notifications/progress MUST echo the token the caller sent in _meta."""
    return {
        "jsonrpc": "2.0",
        "method": "notifications/progress",
        "params": {"progressToken": token, "progress": done, "total": total, "message": message},
    }


# --------------------------------------------------------------------------
# Cursor pagination. Cursors are opaque to the client: encode whatever the
# server needs, and advertise nextCursor ONLY while another page exists.
# --------------------------------------------------------------------------
def _encode_cursor(offset):
    return base64.urlsafe_b64encode(f"offset:{offset}".encode()).decode().rstrip("=")


def _decode_cursor(cursor):
    if cursor is None:
        return 0
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        return int(base64.urlsafe_b64decode(padded).decode().split(":", 1)[1])
    except Exception:
        raise RpcError(INVALID_PARAMS, f"invalid cursor: {cursor!r}")


def paginate(items, key, cursor):
    offset = _decode_cursor(cursor)
    page = items[offset:offset + PAGE_SIZE]
    result = {key: page}
    next_offset = offset + PAGE_SIZE
    if next_offset < len(items):
        result["nextCursor"] = _encode_cursor(next_offset)
    return result


# --------------------------------------------------------------------------
# Tool catalogue
# --------------------------------------------------------------------------
TOOLS = [
    {
        "name": "sys_metrics",
        "title": "Host metrics",
        "description": "Sample the 1-minute load average and the uptime of the lab host.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "outputSchema": {
            "type": "object",
            "properties": {
                "host": {"type": "string"},
                "load1": {"type": "number"},
                "uptime_s": {"type": "integer"},
            },
            "required": ["host", "load1", "uptime_s"],
            "additionalProperties": False,
        },
    },
    {
        "name": "disk_usage",
        "title": "Disk usage",
        "description": "Report total/used/free bytes of the filesystem holding a path.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Absolute path to inspect."}},
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    {
        "name": "slow_scan",
        "title": "Slow scan",
        "description": "Long-running scan that reports progress while it works.",
        "inputSchema": {
            "type": "object",
            "properties": {"steps": {"type": "integer", "minimum": 1, "maximum": 10}},
            "additionalProperties": False,
        },
    },
    {
        "name": "whoami",
        "title": "Server identity",
        "description": "Identify the server process answering this session.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]

RESOURCES = [
    {"uri": "mcp-lab://limits", "name": "limits", "title": "Lab limits", "mimeType": "application/json"},
    {"uri": "mcp-lab://runbook", "name": "runbook", "title": "Lab runbook", "mimeType": "text/markdown"},
]

RESOURCE_BODIES = {
    "mcp-lab://limits": ("application/json", json.dumps({"page_size": PAGE_SIZE, "max_scan_steps": 10}, indent=2)),
    "mcp-lab://runbook": ("text/markdown", "# mcp-lab\n\nControl: `mcp-lab restart`, `mcp-lab logs`, `mcp-lab verify`.\n"),
}


def _uptime_seconds():
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as handle:
            return int(float(handle.read().split()[0]))
    except OSError:
        return int(time.monotonic())


def tool_sys_metrics(_arguments):
    load1 = os.getloadavg()[0]
    uptime_s = _uptime_seconds()
    payload = {"host": platform.node(), "load1": round(load1, 2), "uptime_s": uptime_s}
    # A tool that declares outputSchema returns structuredContent AND mirrors it
    # as serialized JSON in a text block, for clients that ignore structured output.
    return {"content": [{"type": "text", "text": json.dumps(payload, indent=2)}], "structuredContent": payload, "isError": False}


def tool_disk_usage(arguments):
    path = arguments.get("path")
    if not isinstance(path, str) or not path:
        # Malformed arguments: the tool never ran -> protocol channel.
        raise RpcError(INVALID_PARAMS, "disk_usage: 'path' must be a non-empty string")
    if not os.path.exists(path):
        # The tool ran and failed -> result channel, so the model can recover.
        return _tool_failure(f"disk_usage: no such path: {path}")
    usage = shutil.disk_usage(path)
    text = f"{path}: total={usage.total} used={usage.used} free={usage.free}"
    return {"content": [{"type": "text", "text": text}], "isError": False}


def tool_slow_scan(arguments, progress):
    steps = arguments.get("steps", 3)
    if not isinstance(steps, int) or isinstance(steps, bool):
        raise RpcError(INVALID_PARAMS, "slow_scan: 'steps' must be an integer")
    steps = max(1, min(steps, 10))
    for index in range(1, steps + 1):
        time.sleep(0.2)
        progress(index, steps, f"scanning shard {index}/{steps}")
    return {"content": [{"type": "text", "text": f"scan complete: {steps} shards"}], "isError": False}


def tool_whoami(_arguments):
    text = (f"{SERVER_NAME} {SERVER_VERSION} pid={os.getpid()} uid={os.getuid()} "
            f"host={platform.node()} protocol={LATEST_PROTOCOL_VERSION}")
    return {"content": [{"type": "text", "text": text}], "isError": False}


HANDLERS = {
    "sys_metrics": tool_sys_metrics,
    "disk_usage": tool_disk_usage,
    "slow_scan": None,  # streamed separately, see _stream_slow_scan
    "whoami": tool_whoami,
}


def read_resource(params):
    uri = params.get("uri")
    if uri not in RESOURCE_BODIES:
        raise RpcError(RESOURCE_NOT_FOUND, f"resource not found: {uri}", {"uri": uri})
    mime, text = RESOURCE_BODIES[uri]
    return {"contents": [{"uri": uri, "mimeType": mime, "text": text}]}


# --------------------------------------------------------------------------
# Streamable HTTP transport
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = f"{SERVER_NAME}/{SERVER_VERSION}"

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {fmt % args}", flush=True)

    def _send_json(self, payload, status=200, extra_headers=None):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_error_object(self, req_id, code, message, data=None):
        error = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        status = 404 if code == RESOURCE_NOT_FOUND else 200
        self._send_json({"jsonrpc": "2.0", "id": req_id, "error": error}, status=200 if status == 200 else 200)

    def _require_session(self):
        session = self.headers.get("Mcp-Session-Id")
        if not session or session not in SESSIONS:
            raise RpcError(INVALID_REQUEST, "missing or unknown Mcp-Session-Id: call initialize first")

    def do_GET(self):
        self.send_error(405, "mcp-lab does not open a server-initiated stream")

    def do_DELETE(self):
        session = self.headers.get("Mcp-Session-Id")
        SESSIONS.discard(session)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path.split("?")[0] != "/mcp":
            self.send_error(404, "unknown endpoint, use /mcp")
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            message = json.loads(raw)
        except json.JSONDecodeError as exc:
            self._send_json({"jsonrpc": "2.0", "id": None,
                             "error": {"code": PARSE_ERROR, "message": f"parse error: {exc}"}}, status=400)
            return
        if not isinstance(message, dict):
            self._send_json({"jsonrpc": "2.0", "id": None,
                             "error": {"code": INVALID_REQUEST, "message": "expected a single JSON-RPC object"}})
            return

        method = message.get("method")
        req_id = message.get("id")
        params = message.get("params") or {}

        if req_id is None:
            # A notification carries no id and gets no response body.
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        try:
            if method == "initialize":
                result = self._handle_initialize(params)
                session = uuid.uuid4().hex
                SESSIONS.add(session)
                self._send_json({"jsonrpc": "2.0", "id": req_id, "result": result},
                                extra_headers={"Mcp-Session-Id": session})
                return

            self._require_session()

            if method == "ping":
                result = {}
            elif method == "tools/list":
                result = paginate(TOOLS, "tools", params.get("cursor"))
            elif method == "resources/list":
                result = paginate(RESOURCES, "resources", params.get("cursor"))
            elif method == "resources/read":
                result = read_resource(params)
            elif method == "tools/call":
                self._handle_tools_call(req_id, params)
                return
            else:
                raise RpcError(METHOD_NOT_FOUND, f"unknown method: {method}")
        except RpcError as exc:
            error = {"code": exc.code, "message": exc.message}
            if exc.data is not None:
                error["data"] = exc.data
            self._send_json({"jsonrpc": "2.0", "id": req_id, "error": error})
            return
        except Exception as exc:  # never leak a traceback onto the wire
            self._send_json({"jsonrpc": "2.0", "id": req_id,
                             "error": {"code": INTERNAL_ERROR, "message": f"internal error: {exc}"}})
            return

        self._send_json({"jsonrpc": "2.0", "id": req_id, "result": result})

    def _handle_initialize(self, params):
        requested = params.get("protocolVersion")
        negotiated = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else LATEST_PROTOCOL_VERSION
        return {
            "protocolVersion": negotiated,
            "capabilities": {
                "tools": {"listChanged": False},
                "resources": {"subscribe": False, "listChanged": False},
                "logging": {},
            },
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION, "title": "MCPA 3.1 lab server"},
            "instructions": "Lab server for MCPA topic 3.1. All tools are read-only samples of the lab host.",
        }

    def _handle_tools_call(self, req_id, params):
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name not in HANDLERS:
            # Unknown tool: nothing executed -> protocol channel.
            raise RpcError(INVALID_PARAMS, f"unknown tool: {name}")
        if name == "slow_scan":
            self._stream_slow_scan(req_id, params, arguments)
            return
        result = HANDLERS[name](arguments)
        self._send_json({"jsonrpc": "2.0", "id": req_id, "result": result})

    def _stream_slow_scan(self, req_id, params, arguments):
        token = (params.get("_meta") or {}).get("progressToken")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(payload):
            self.wfile.write(b"event: message\n")
            self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
            self.wfile.flush()

        def progress(done, total, message):
            if token is None:
                return  # the client did not opt in: stay silent
            emit(_progress_notification(token, done, total, message))

        try:
            result = tool_slow_scan(arguments, progress)
        except RpcError as exc:
            emit({"jsonrpc": "2.0", "id": req_id, "error": {"code": exc.code, "message": exc.message}})
            return
        except BrokenPipeError:
            return
        emit({"jsonrpc": "2.0", "id": req_id, "result": result})


class LabServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    httpd = LabServer((BIND_HOST, BIND_PORT), Handler)
    print(f"{SERVER_NAME} {SERVER_VERSION} listening on http://{BIND_HOST}:{BIND_PORT}/mcp", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
PYEOF
  chmod 0644 "${LAB_DIR}/server.py"
}

# ---------------------------------------------------------------------------
# The harness. This is your instrument: it is read-only for the exercise.
# ---------------------------------------------------------------------------
write_verify() {
  cat > "${LAB_DIR}/verify.py" <<'PYEOF'
#!/usr/bin/env python3
"""
mcp-lab conformance harness - MCPA 3.1 Interaction Patterns & Response Handling.

Five checks, each one asserting a rule of the protocol that a real client relies
on. Exit status is the number of failing checks.

  mcp-lab verify
  mcp-lab rpc tools/list '{"cursor": null}'
"""
from __future__ import annotations

import http.client
import json
import os
import socket
import sys

HOST = os.environ.get("MCP_LAB_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_LAB_PORT", "8931"))
ENDPOINT = "/mcp"
PROTOCOL = "2025-06-18"

ISATTY = sys.stdout.isatty()
BOLD = "\033[1m" if ISATTY else ""
RED = "\033[31m" if ISATTY else ""
GREEN = "\033[32m" if ISATTY else ""
DIM = "\033[2m" if ISATTY else ""
OFF = "\033[0m" if ISATTY else ""


class Fail(Exception):
    pass


def read_sse(response):
    """Collect the JSON-RPC messages carried by an SSE response body."""
    messages, data = [], []
    while True:
        try:
            line = response.readline()
        except (socket.timeout, TimeoutError):
            raise Fail("the SSE stream stalled: no further frames before the timeout")
        if not line:
            break
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        if text == "":
            if data:
                try:
                    messages.append(json.loads("\n".join(data)))
                except json.JSONDecodeError:
                    raise Fail(f"an SSE frame is not valid JSON: {'|'.join(data)[:160]!r}")
                data = []
            continue
        if text.startswith("data:"):
            data.append(text[5:].lstrip())
    if data:
        messages.append(json.loads("\n".join(data)))
    return messages


class Client:
    def __init__(self):
        self.session = None
        self._id = 0

    def _headers(self):
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
            headers["MCP-Protocol-Version"] = PROTOCOL
        return headers

    def _open(self, body, timeout):
        connection = http.client.HTTPConnection(HOST, PORT, timeout=timeout)
        try:
            connection.request("POST", ENDPOINT, json.dumps(body), self._headers())
            return connection, connection.getresponse()
        except ConnectionRefusedError:
            raise Fail(f"nothing is listening on {HOST}:{PORT} - run `mcp-lab start`")

    def request(self, method, params=None, meta=None, timeout=15):
        self._id += 1
        req_id = self._id
        body = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None or meta is not None:
            payload = dict(params or {})
            if meta is not None:
                payload["_meta"] = meta
            body["params"] = payload

        connection, response = self._open(body, timeout)
        session = response.getheader("Mcp-Session-Id")
        if session and not self.session:
            self.session = session
        content_type = (response.getheader("Content-Type") or "").split(";")[0].strip()
        try:
            if content_type == "text/event-stream":
                return req_id, read_sse(response)
            raw = response.read()
        finally:
            connection.close()
        if not raw:
            raise Fail(f"{method}: empty body with HTTP {response.status}")
        try:
            return req_id, [json.loads(raw)]
        except json.JSONDecodeError:
            raise Fail(f"{method}: body is not JSON (HTTP {response.status}): {raw[:200]!r}")

    def notify(self, method, params=None):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        connection, response = self._open(body, 10)
        response.read()
        connection.close()


def find_response(messages, req_id):
    """A response matches only if the id is equal AND of the same JSON type."""
    for message in messages:
        if "id" in message and message["id"] == req_id and type(message["id"]) is type(req_id):
            return message
    return None


def expect_result(messages, req_id, label):
    message = find_response(messages, req_id)
    if message is None:
        seen = [repr(m.get("id")) for m in messages if "id" in m] or ["<none>"]
        raise Fail(f"{label}: no response carrying id {req_id!r} ({type(req_id).__name__}); "
                   f"ids on the wire: {', '.join(seen)}")
    if "error" in message:
        error = message["error"]
        raise Fail(f"{label}: JSON-RPC error {error.get('code')}: {error.get('message')}")
    if "result" not in message:
        raise Fail(f"{label}: the response has neither result nor error")
    return message["result"]


def type_ok(value, expected):
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    return True


def validate(instance, schema, path="$"):
    """Enough JSON Schema to police an outputSchema contract, no dependencies."""
    expected = schema.get("type")
    if expected and not type_ok(instance, expected):
        return [f"{path}: expected {expected}, got {type(instance).__name__} ({instance!r})"]
    problems = []
    if expected == "object":
        for key in schema.get("required", []):
            if key not in instance:
                problems.append(f"{path}.{key}: required property missing")
        properties = schema.get("properties", {})
        for key, value in instance.items():
            if key in properties:
                problems += validate(value, properties[key], f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                problems.append(f"{path}.{key}: additional property not allowed")
    return problems


def collect_tools(client, max_pages=8):
    """Walk the listing defensively: never trust it to terminate."""
    tools, cursor = {}, None
    for _ in range(max_pages):
        req_id, messages = client.request("tools/list", {} if cursor is None else {"cursor": cursor})
        result = expect_result(messages, req_id, "tools/list")
        for tool in result.get("tools", []):
            tools.setdefault(tool["name"], tool)
        cursor = result.get("nextCursor")
        if cursor is None:
            break
    return tools


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------
def check_handshake(client):
    req_id, messages = client.request("initialize", {
        "protocolVersion": PROTOCOL,
        "capabilities": {},
        "clientInfo": {"name": "mcp-lab-verify", "version": "1.0.0"},
    })
    result = expect_result(messages, req_id, "initialize")
    negotiated = result.get("protocolVersion")
    if not isinstance(negotiated, str):
        raise Fail("initialize did not return a protocolVersion")
    capabilities = result.get("capabilities") or {}
    if "tools" not in capabilities:
        raise Fail("the server does not advertise the 'tools' capability")
    info = result.get("serverInfo") or {}
    client.notify("notifications/initialized")
    return f"protocol {negotiated}, server {info.get('name')} {info.get('version')}"


def check_pagination(client):
    names, cursors, cursor, pages = [], [], None, 0
    for pages in range(1, 9):
        req_id, messages = client.request("tools/list", {} if cursor is None else {"cursor": cursor})
        result = expect_result(messages, req_id, "tools/list")
        page = [tool["name"] for tool in result.get("tools", [])]
        names += page
        cursor = result.get("nextCursor")
        if cursor is None:
            break
        if not page:
            raise Fail("tools/list returned an EMPTY page and still advertised nextCursor: "
                       "the client keeps asking for a page that does not exist")
        if cursor in cursors:
            raise Fail(f"tools/list repeated the cursor {cursor!r}: the listing never terminates")
        cursors.append(cursor)
    else:
        raise Fail("tools/list still advertised nextCursor after 8 pages: the listing never terminates")
    if len(set(names)) != len(names):
        raise Fail(f"the listing served duplicate tools across pages: {names}")
    if len(names) < 4:
        raise Fail(f"expected 4 tools across the listing, walked {len(names)}: {names}")
    return f"{len(names)} tools over {pages} page(s), cursor omitted on the last one"


def check_structured_output(client):
    tools = collect_tools(client)
    if "sys_metrics" not in tools:
        raise Fail("sys_metrics is not in the listing")
    schema = tools["sys_metrics"].get("outputSchema")
    if not schema:
        raise Fail("sys_metrics no longer declares an outputSchema")

    req_id, messages = client.request("tools/call", {"name": "sys_metrics", "arguments": {}})
    result = expect_result(messages, req_id, "tools/call sys_metrics")
    problems = []

    structured = result.get("structuredContent")
    if not isinstance(structured, dict):
        problems.append("no structuredContent although the tool declares an outputSchema")
    else:
        for problem in validate(structured, schema):
            problems.append(f"structuredContent violates the declared outputSchema: {problem}")

    blocks = [b for b in (result.get("content") or []) if b.get("type") == "text"]
    if not blocks:
        problems.append("no text content block: a tool with structured output must also return the "
                        "serialized JSON as text, for clients that ignore structuredContent")
    elif isinstance(structured, dict):
        try:
            mirrored = json.loads(blocks[0].get("text", ""))
        except json.JSONDecodeError:
            mirrored = None
            problems.append("the text block is not the serialized form of structuredContent")
        if mirrored is not None and mirrored != structured:
            problems.append("the text block and structuredContent disagree")

    if problems:
        raise Fail(" | ".join(problems))
    return f"structuredContent validates, mirrored as text ({', '.join(sorted(structured))})"


def check_error_channels(client):
    missing = f"/nonexistent-lab-path-{os.getpid()}"
    req_id, messages = client.request("tools/call", {"name": "disk_usage", "arguments": {"path": missing}})
    message = find_response(messages, req_id)
    if message is None:
        raise Fail("tools/call disk_usage: no correlatable response")
    if "error" in message:
        raise Fail(f"a tool that RAN AND FAILED was reported as a JSON-RPC error "
                   f"(code {message['error'].get('code')}): the model never sees the reason and the "
                   f"turn aborts. Execution failures belong in the result, as isError:true")
    result = message["result"]
    if result.get("isError") is not True:
        raise Fail("the failing tool call did not set isError:true in its result")
    if not result.get("content"):
        raise Fail("the isError result carries no content block explaining the failure")

    req_id, messages = client.request("tools/call", {"name": "no_such_tool", "arguments": {}})
    message = find_response(messages, req_id)
    if message is None:
        raise Fail("tools/call no_such_tool: no correlatable response")
    if "error" not in message:
        raise Fail("an unknown tool name must be a JSON-RPC error (-32602), not an isError result")
    code = message["error"].get("code")
    if code not in (-32602, -32601):
        raise Fail(f"unknown tool reported with code {code}, expected -32602 (invalid params)")
    return "execution failure -> isError result, unknown tool -> JSON-RPC error"


def check_progress_and_correlation(client):
    token = f"probe-{os.getpid()}"
    req_id, messages = client.request(
        "tools/call", {"name": "slow_scan", "arguments": {"steps": 3}},
        meta={"progressToken": token}, timeout=30)

    final = find_response(messages, req_id)
    if final is None:
        seen = [f"{m['id']!r} ({type(m['id']).__name__})" for m in messages if "id" in m] or ["<none>"]
        raise Fail(f"no response carrying id {req_id!r} ({type(req_id).__name__}); ids on the stream: "
                   f"{', '.join(seen)}. A JSON-RPC response MUST echo the request id unchanged - a real "
                   f"client leaves the call pending until it times out")
    if "error" in final:
        raise Fail(f"slow_scan failed: {final['error']}")

    notifications = [m for m in messages if m.get("method") == "notifications/progress"]
    if not notifications:
        raise Fail("no notifications/progress although the request carried _meta.progressToken")
    wrong = [n.get("params", {}).get("progressToken") for n in notifications
             if n.get("params", {}).get("progressToken") != token]
    if wrong:
        raise Fail(f"progress notifications carry {wrong[0]!r} instead of the caller's token {token!r}: "
                   f"the client cannot attribute them to this request")
    values = [n.get("params", {}).get("progress") for n in notifications]
    if any(b <= a for a, b in zip(values, values[1:])):
        raise Fail(f"progress is not strictly increasing: {values}")
    return f"{len(notifications)} progress notifications on token {token}, response correlated"


CHECKS = [
    ("handshake", check_handshake,
     "initialize must negotiate a protocolVersion and advertise capabilities"),
    ("pagination", check_pagination,
     "a listing terminates by OMITTING nextCursor on the last page; cursors are opaque and advance"),
    ("structured-output", check_structured_output,
     "structuredContent must satisfy the declared outputSchema and be mirrored as a text block"),
    ("tool-error-channel", check_error_channels,
     "tool execution failures -> result with isError:true; protocol faults -> JSON-RPC error"),
    ("progress-correlation", check_progress_and_correlation,
     "echo the caller's progressToken, and echo the request id unchanged in the response"),
]


def run_checks():
    print(f"{BOLD}mcp-lab conformance harness{OFF} - MCPA 3.1 Interaction Patterns & Response Handling")
    print(f"target: http://{HOST}:{PORT}{ENDPOINT}\n")
    client = Client()
    failures = 0
    for name, function, hint in CHECKS:
        try:
            detail = function(client)
            print(f"[{GREEN}PASS{OFF}] {name:<22} {detail}")
        except Fail as exc:
            failures += 1
            print(f"[{RED}FAIL{OFF}] {name:<22} {exc}")
            print(f"       {DIM}rule: {hint}{OFF}")
            if name == "handshake":
                print(f"       {DIM}the remaining checks need a session; fix this first{OFF}")
                return len(CHECKS) - 1 + failures
    print()
    if failures:
        print(f"{RED}{failures} of {len(CHECKS)} checks failed{OFF}")
    else:
        print(f"{GREEN}all {len(CHECKS)} checks passed{OFF}")
    return failures


def rpc_mode(argv):
    if not argv:
        print("usage: mcp-lab rpc <method> [json-params]", file=sys.stderr)
        return 2
    method = argv[0]
    params = json.loads(argv[1]) if len(argv) > 1 else {}
    client = Client()
    try:
        req_id, messages = client.request("initialize", {
            "protocolVersion": PROTOCOL, "capabilities": {},
            "clientInfo": {"name": "mcp-lab-rpc", "version": "1.0.0"}})
        expect_result(messages, req_id, "initialize")
        client.notify("notifications/initialized")
        req_id, messages = client.request(method, params, timeout=30)
    except Fail as exc:
        print(f"{RED}{exc}{OFF}", file=sys.stderr)
        return 1
    print(f"{DIM}# request id {req_id!r}{OFF}")
    for message in messages:
        print(json.dumps(message, indent=2))
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--rpc"]:
        sys.exit(rpc_mode(sys.argv[2:]))
    sys.exit(min(run_checks(), 125))
PYEOF
  chmod 0444 "${LAB_DIR}/verify.py"
}

write_dispatcher() {
  cat > "$DISPATCH" <<'SHEOF'
#!/usr/bin/env bash
# mcp-lab - control the MCPA 3.1 laboratory
set -euo pipefail
LAB=/opt/mcp-lab
PIDFILE="$LAB/state/server.pid"
LOGFILE="$LAB/state/server.log"

have_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

start_plain() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then return 0; fi
  runner=(python3 "$LAB/server.py")
  if command -v runuser >/dev/null 2>&1 && id mcplab >/dev/null 2>&1; then
    runner=(runuser -u mcplab -- python3 "$LAB/server.py")
  fi
  PYTHONUNBUFFERED=1 setsid "${runner[@]}" >>"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 1
}

stop_plain() {
  [ -f "$PIDFILE" ] || return 0
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
}

case "${1:-help}" in
  start)   have_systemd && systemctl start mcp-lab || start_plain ;;
  stop)    have_systemd && systemctl stop mcp-lab || stop_plain ;;
  restart) if have_systemd; then systemctl restart mcp-lab; else stop_plain; start_plain; fi; sleep 1 ;;
  status)  if have_systemd; then systemctl --no-pager --full status mcp-lab || true
           else [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && echo "running pid $(cat "$PIDFILE")" || echo "stopped"; fi ;;
  logs)    if have_systemd; then journalctl -u mcp-lab -n "${2:-40}" --no-pager; else tail -n "${2:-40}" "$LOGFILE"; fi ;;
  verify)  exec python3 "$LAB/verify.py" ;;
  rpc)     shift; exec python3 "$LAB/verify.py" --rpc "$@" ;;
  edit)    exec "${EDITOR:-vi}" "$LAB/server.py" ;;
  *)       cat <<USAGE
mcp-lab <command>

  start | stop | restart     control the lab MCP server
  status | logs [n]          is it up, what did it say
  verify                     run the conformance harness (exit = failing checks)
  rpc <method> [json]        send one raw JSON-RPC request and print every frame
  edit                       open /opt/mcp-lab/server.py in \$EDITOR
USAGE
           ;;
esac
SHEOF
  chmod 0755 "$DISPATCH"
}

write_unit() {
  command -v systemctl >/dev/null 2>&1 || return 0
  [ -d /run/systemd/system ] || return 0
  local nologin="/sbin/nologin"
  [ -x /usr/sbin/nologin ] && nologin="/usr/sbin/nologin"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=mcp-lab - MCP server for MCPA topic 3.1 (break & fix)
Documentation=https://modelcontextprotocol.io/specification/2025-06-18
After=network-online.target

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
WorkingDirectory=${LAB_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/env python3 ${LAB_DIR}/server.py
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${STATE_DIR}
RestrictAddressFamilies=AF_INET AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
  unset nologin
  systemctl daemon-reload
  systemctl enable mcp-lab >/dev/null 2>&1 || true
}

ensure_user() {
  id "$LAB_USER" >/dev/null 2>&1 && return 0
  local nologin="/sbin/nologin"
  [ -x /usr/sbin/nologin ] && nologin="/usr/sbin/nologin"
  useradd --system --no-create-home --shell "$nologin" "$LAB_USER" 2>/dev/null || true
}

install_lab() {
  head1 "Installing the lab into ${LAB_DIR}"
  mkdir -p "$LAB_DIR" "$STATE_DIR" "$ANSWER_DIR"
  chmod 0700 "$ANSWER_DIR"
  : > "$MARKER"
  ensure_user
  write_server
  write_verify
  write_dispatcher
  write_unit
  cp -f "${LAB_DIR}/server.py" "${ANSWER_DIR}/server.py"
  chmod 0600 "${ANSWER_DIR}/server.py"
  chown -R "${LAB_USER}:${LAB_USER}" "$STATE_DIR" 2>/dev/null || true
  say "  server   ${LAB_DIR}/server.py        (you edit this)"
  say "  harness  ${LAB_DIR}/verify.py        (read-only, do not weaken it)"
  say "  control  ${DISPATCH}"
}

# ---------------------------------------------------------------------------
# Controlled breakage. Each defect is one exact, single-line substitution, so
# the injector fails loudly instead of half-corrupting the file.
# ---------------------------------------------------------------------------
inject_faults() {
  head1 "Injecting the defects"
  python3 - "$LAB_DIR/server.py" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

FAULTS = [
    ("F1", "execution failure escalated to the protocol channel",
     r'''        return _tool_failure(f"disk_usage: no such path: {path}")''',
     r'''        raise RpcError(INTERNAL_ERROR, f"disk_usage: no such path: {path}")'''),

    ("F2a", "structured output breaks its own outputSchema",
     r'''    payload = {"host": platform.node(), "load1": round(load1, 2), "uptime_s": uptime_s}''',
     r'''    payload = {"host": platform.node(), "load1": str(round(load1, 2)), "uptime_s": uptime_s}'''),

    ("F2b", "structured output is no longer mirrored as text",
     r'''    return {"content": [{"type": "text", "text": json.dumps(payload, indent=2)}], "structuredContent": payload, "isError": False}''',
     r'''    return {"structuredContent": payload, "isError": False}'''),

    ("F3", "the listing never stops advertising a next page",
     r'''    if next_offset < len(items):''',
     r'''    if True:'''),

    ("F4a", "progress notifications invent their own token",
     r'''            emit(_progress_notification(token, done, total, message))''',
     r'''            emit(_progress_notification("scan-" + str(os.getpid()), done, total, message))'''),

    ("F4b", "the response id is not echoed with the type it arrived as",
     r'''        emit({"jsonrpc": "2.0", "id": req_id, "result": result})''',
     r'''        emit({"jsonrpc": "2.0", "id": str(req_id), "result": result})'''),
]

for fault_id, description, old, new in FAULTS:
    count = source.count(old)
    if count != 1:
        sys.exit(f"injector aborted: anchor for {fault_id} matched {count} times, expected exactly 1")
    source = source.replace(old, new)
    print(f"  {fault_id}  {description}")

open(path, "w", encoding="utf-8").write(source)

import py_compile, tempfile
py_compile.compile(path, cfile=tempfile.mktemp(), doraise=True)
print("  the broken server still compiles: the defects are semantic, not syntactic")
PYEOF
}

restore_lab() {
  [ -f "${ANSWER_DIR}/server.py" ] || die "no answer key at ${ANSWER_DIR}/server.py - run the installer first"
  head1 "Restoring the correct server (this is the answer key)"
  cp -f "${ANSWER_DIR}/server.py" "${LAB_DIR}/server.py"
  chmod 0644 "${LAB_DIR}/server.py"
  "$DISPATCH" restart
  "$DISPATCH" verify || true
}

uninstall_lab() {
  head1 "Removing the lab"
  [ -e "$MARKER" ] || die "${LAB_DIR} does not carry this lab's marker file - refusing to delete it"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl disable --now mcp-lab >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
  else
    "$DISPATCH" stop 2>/dev/null || true
  fi
  rm -rf "$LAB_DIR" "$ANSWER_DIR"
  rm -f "$DISPATCH"
  userdel "$LAB_USER" 2>/dev/null || true
  say "removed: ${LAB_DIR}, ${ANSWER_DIR}, ${UNIT_FILE}, ${DISPATCH}, user ${LAB_USER}"
}

briefing() {
  cat <<EOF

${B}================================================================${N}
${B} MCPA 3.1 - BREAK & FIX: Interaction Patterns & Response Handling${N}
${B}================================================================${N}

A study agent is wired to the MCP server on ${C}http://127.0.0.1:${LAB_PORT}/mcp${N}.
Since the last deploy the integration misbehaves in four different ways. The
server process is ${G}up${N} and ${G}healthy${N} - nothing crashes, nothing logs an error.
Every defect lives in how the server ${B}shapes its responses${N}.

${B}SYMPTOMS THE STUDENT-FACING CLIENT REPORTS${N}

 ${Y}S1${N}  The agent asks for the disk usage of a path that does not exist.
     Instead of the model reading "no such path" and retrying with a good one,
     the whole turn dies with a transport-level failure and the user sees
     "the tool is broken". A wrong argument should be recoverable, not fatal.

 ${Y}S2${N}  The agent calls the metrics tool. The client rejects the answer with a
     schema violation, and clients that do not understand structured output at
     all get nothing readable to show the model.

 ${Y}S3${N}  Tool discovery never finishes. The client walks the catalogue page by
     page and keeps being handed another cursor, forever, eventually serving
     empty pages. In production this is an infinite request loop against the
     server.

 ${Y}S4${N}  The long scan appears to hang. Progress arrives on the wire, but the
     client can attribute none of it to the call it made, and the call itself
     never completes as far as the client is concerned - it sits pending until
     the request times out.

${B}YOUR MISSION${N}

  Repair ${C}${LAB_DIR}/server.py${N} until:

      ${C}mcp-lab verify${N}     ->  5 of 5 PASS, exit status 0

  Rules of engagement:
    * Fix the ${B}server${N}. ${LAB_DIR}/verify.py is your instrument, not your
      patient - it is mode 0444 and weakening it is not a fix.
    * Every defect is semantic. The file compiles and the service starts.
    * Restart after each edit: ${C}mcp-lab restart${N}

${B}INSTRUMENTS${N}

  ${C}mcp-lab verify${N}                      run the five conformance checks
  ${C}mcp-lab rpc tools/list${N}              see the raw JSON-RPC frames
  ${C}mcp-lab rpc tools/call '{"name":"disk_usage","arguments":{"path":"/nope"}}'${N}
  ${C}mcp-lab logs 40${N}                     server log / journal
  ${C}mcp-lab status${N} | ${C}mcp-lab restart${N} | ${C}mcp-lab edit${N}

${B}THE FOUR RULES BEING VIOLATED${N} (this is the exam material, not a hint sheet)

  1. Two error channels, never interchangeable. A malformed or unroutable
     request is a JSON-RPC ${B}error object${N} (-32602, -32601, ...). A tool that
     ran and failed is a normal ${B}result${N} with "isError": true and a content
     block explaining why - because that text goes back to the model, which can
     then correct itself.
  2. A tool that declares an outputSchema must return structuredContent that
     ${B}validates${N} against it, and must also mirror it as serialized JSON in a
     text block for clients that ignore structured output.
  3. A paginated listing terminates by ${B}omitting${N} nextCursor on the last page.
     Cursors are opaque to the client and must advance.
  4. Correlation is sacred: a response echoes the request ${B}id${N} exactly as it
     arrived (same value, same JSON type), and a progress notification echoes
     the ${B}progressToken${N} the caller put in _meta. Anything else is an orphan
     message the client cannot route.

  Spec: https://modelcontextprotocol.io/specification/2025-06-18
  JSON-RPC 2.0: https://www.jsonrpc.org/specification

${B}Answer key${N} (after you have tried): ${C}sudo $0 --restore${N}
${B}Clean up${N}: ${C}sudo $0 --uninstall${N}

EOF
}

main() {
  case "${1:-}" in
    --help|-h)
      sed -n '2,40p' "$0"; exit 0 ;;
    --what-it-touches)
      what_it_touches; exit 0 ;;
    --verify)
      require_root; exec "$DISPATCH" verify ;;
    --restore)
      require_root; restore_lab; exit 0 ;;
    --uninstall)
      require_root; uninstall_lab; exit 0 ;;
    --yes|-y)
      ASSUME_YES=1 ;;
    "") : ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac

  require_root
  preflight
  confirm_disposable
  install_lab
  inject_faults

  head1 "Starting the service"
  "$DISPATCH" restart
  "$DISPATCH" status | sed -n '1,6p' || true

  briefing

  head1 "Current state of the integration"
  set +e
  "$DISPATCH" verify
  failures=$?
  set -e
  say ""
  say "${B}${failures} checks are failing. Go fix ${LAB_DIR}/server.py.${N}"
  exit 0
}

main "$@"

# ============================================================================
# ============================================================================
#  SOLUTION - STEP BY STEP
#  (Everything below is commented out. Read it only after your own attempt.)
# ============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 - Establish the facts before touching anything
# ---------------------------------------------------------------------------
#
#   mcp-lab status          # the unit is active (running): this is not an outage
#   mcp-lab logs 40         # no tracebacks: the defects are in response SHAPE
#   mcp-lab verify          # four red checks, each naming the rule it broke
#
# Expected output of `mcp-lab verify` before the repair:
#
#   [PASS] handshake             protocol 2025-06-18, server mcp-lab 1.0.0
#   [FAIL] pagination            tools/list returned an EMPTY page and still advertised nextCursor...
#   [FAIL] structured-output     structuredContent violates the declared outputSchema: $.load1: expected
#                                number, got str ('0.14') | no text content block: ...
#   [FAIL] tool-error-channel    a tool that RAN AND FAILED was reported as a JSON-RPC error (code -32603)...
#   [FAIL] progress-correlation  progress notifications carry 'scan-1417' instead of the caller's token...
#
# Look at the wire yourself - this is the habit the exam is testing:
#
#   mcp-lab rpc tools/call '{"name":"disk_usage","arguments":{"path":"/nope"}}'
#   mcp-lab rpc tools/call '{"name":"sys_metrics","arguments":{}}'
#   mcp-lab rpc tools/list '{}'
#
# ---------------------------------------------------------------------------
# STEP 1 - S1 / tool-error-channel: put execution failures back in the result
# ---------------------------------------------------------------------------
#
# In /opt/mcp-lab/server.py, function tool_disk_usage():
#
#   -        raise RpcError(INTERNAL_ERROR, f"disk_usage: no such path: {path}")
#   +        return _tool_failure(f"disk_usage: no such path: {path}")
#
# Why. MCP deliberately splits failure into two channels:
#   * JSON-RPC error object -> the request could not be processed at all
#     (unknown method -32601, unknown tool or bad arguments -32602, transport
#     faults). The client treats this as a protocol fault and aborts the call.
#   * result with "isError": true plus a content block -> the tool executed and
#     failed. The content is handed to the model, which reads "no such path" and
#     retries with a valid one. That self-correction loop is the entire point.
# Note the contrast left intact two lines above: arguments of the wrong shape
# still raise RpcError(INVALID_PARAMS, ...), because there the tool never ran.
#
#   mcp-lab restart && mcp-lab verify   # tool-error-channel turns green
#
# ---------------------------------------------------------------------------
# STEP 2 - S2 / structured-output: honour the contract you published
# ---------------------------------------------------------------------------
#
# Two edits in tool_sys_metrics():
#
#   -    payload = {"host": platform.node(), "load1": str(round(load1, 2)), "uptime_s": uptime_s}
#   +    payload = {"host": platform.node(), "load1": round(load1, 2), "uptime_s": uptime_s}
#
#   -    return {"structuredContent": payload, "isError": False}
#   +    return {"content": [{"type": "text", "text": json.dumps(payload, indent=2)}], "structuredContent": payload, "isError": False}
#
# Why. The tool's outputSchema declares load1 as "number"; "0.14" is a string,
# so a validating client rejects the whole result - the data was right and the
# type was wrong, which is the most common structured-output bug in the field.
# The second edit restores the compatibility mirror: a tool returning
# structuredContent SHOULD also return the same object serialized in a
# TextContent block, so clients (and models) that ignore structured output still
# receive something they can read. Confirm the contract and the answer agree:
#
#   mcp-lab rpc tools/list '{}' | grep -A12 outputSchema
#   mcp-lab rpc tools/call '{"name":"sys_metrics","arguments":{}}'
#
# ---------------------------------------------------------------------------
# STEP 3 - S3 / pagination: a listing has to be able to end
# ---------------------------------------------------------------------------
#
# In paginate():
#
#   -    if True:
#   +    if next_offset < len(items):
#            result["nextCursor"] = _encode_cursor(next_offset)
#
# Why. nextCursor is not "the next offset", it is "there is more". Present means
# keep going; absent means the listing is complete. Advertising it
# unconditionally turns every client's `while cursor:` loop into an unbounded
# request loop against your server - a self-inflicted denial of service that
# scales with the number of connected agents. The same rule governs
# resources/list, prompts/list and resources/templates/list; the cursor stays
# opaque to the client, which must never parse or synthesise one.
#
#   mcp-lab rpc tools/list '{}'        # page 1: 2 tools + nextCursor
#   # feed that cursor back and the second page must come back WITHOUT a cursor
#
# ---------------------------------------------------------------------------
# STEP 4 - S4 / progress-correlation: never orphan a message
# ---------------------------------------------------------------------------
#
# Two edits in Handler._stream_slow_scan():
#
#   -            emit(_progress_notification("scan-" + str(os.getpid()), done, total, message))
#   +            emit(_progress_notification(token, done, total, message))
#
#   -        emit({"jsonrpc": "2.0", "id": str(req_id), "result": result})
#   +        emit({"jsonrpc": "2.0", "id": req_id, "result": result})
#
# Why, first edit. A progress notification is not addressed to a request - it
# carries the progressToken the CALLER supplied in params._meta.progressToken.
# Invent your own and the client receives progress it cannot attribute to any
# in-flight call: it is dropped, and the user stares at a frozen spinner.
# Sending progress when no token was supplied is equally wrong - that is why the
# `if token is None: return` guard stays.
#
# Why, second edit. JSON-RPC 2.0 correlates responses to requests by id, and the
# id MUST be echoed unchanged - the integer 7 and the string "7" are different
# ids. The response does reach the client here; it simply matches nothing in the
# pending-request table, so the call stays open until the client's timeout fires
# and reports a hang that the server logs will never explain. That is exactly
# what the harness means by "ids on the stream: '7' (str)".
#
# ---------------------------------------------------------------------------
# STEP 5 - Verify, and understand what green means
# ---------------------------------------------------------------------------
#
#   mcp-lab restart
#   mcp-lab verify ; echo "exit=$?"
#
#   [PASS] handshake             protocol 2025-06-18, server mcp-lab 1.0.0
#   [PASS] pagination            4 tools over 2 page(s), cursor omitted on the last one
#   [PASS] structured-output     structuredContent validates, mirrored as text (host, load1, uptime_s)
#   [PASS] tool-error-channel    execution failure -> isError result, unknown tool -> JSON-RPC error
#   [PASS] progress-correlation  3 progress notifications on token probe-1417, response correlated
#   all 5 checks passed
#   exit=0
#
# Compare your repair against the pristine server if you want:
#
#   diff -u /root/.mcp-lab-answer-key/server.py /opt/mcp-lab/server.py
#
# ---------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM
# ---------------------------------------------------------------------------
#
#   * isError:true is for the model; a JSON-RPC error is for the client. Choosing
#     the wrong one either hides a recoverable mistake or kills a live turn.
#   * An outputSchema is a promise. Publishing one and returning something else
#     is worse than publishing none, and the mirror text block is what keeps
#     older clients working.
#   * nextCursor means "there is more", not "here is the offset". Absent ends the
#     listing. Cursors are opaque: never parse, never fabricate.
#   * id and progressToken are the routing fabric of the session. Echo them
#     byte-for-byte and type-for-type, or the message is unroutable - and an
#     unroutable message looks to everyone like a hang, not like a bug.
#   * Diagnose at the protocol layer: `mcp-lab rpc ...` shows the frames. A
#     healthy process with malformed responses is the normal failure mode of an
#     MCP integration, and no amount of `systemctl status` will reveal it.
#
# ============================================================================