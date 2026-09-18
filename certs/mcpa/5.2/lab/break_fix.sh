#!/usr/bin/env bash
#
# ==========================================================================
#  MCPA — Topic 5.2: Operational Use Cases
#  BREAK & FIX LAB: "the on-call agent lost its hands"
# ==========================================================================
#
#  Scenario
#  --------
#  Your platform team runs `mcp-ops`, an MCP server over the Streamable HTTP
#  transport that gives the on-call assistant a bounded set of operational
#  capabilities against a service called payments-api: read-only triage
#  (status, logs, disk) plus exactly one remediation action (restart).
#  This is the canonical operational use case for MCP: the model does not get
#  a shell, it gets a contract.
#
#  Release 1.4.0 went out this afternoon. Since then the assistant reports
#  that it "cannot see any tools on mcp-ops", while the service is up and
#  `curl` against the endpoint appears to work. You are on call.
#
#  WARNING — DISPOSABLE LAB VM ONLY
#  This script installs and enables systemd units, writes under /opt and
#  /var/log, binds 127.0.0.1:8931, and deliberately deploys a server with
#  real defects (including a command-injection path reachable only from
#  localhost). Never run it on a machine you care about.
#
#  Official sources
#   - MCPA certification page:
#     https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#   - MCP lifecycle (initialize / capability negotiation):
#     https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#   - MCP transports (Streamable HTTP, Mcp-Session-Id):
#     https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#   - MCP tools (inputSchema, annotations, isError):
#     https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#   - systemctl(1):
#     https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
#
#  The step-by-step solution is at the bottom of this file, commented out.
#  Re-running this script re-injects the faults, so you can retry the lab.
# ==========================================================================

set -euo pipefail

LAB_DIR=/opt/mcp-ops
LOG_DIR=/var/log/payments-api
PORT=8931
MARKER=/tmp/mcp-lab-INJECTION-PROVED

say() { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[lab] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "run as root on a disposable lab VM."
[[ -d /run/systemd/system ]] || die "systemd is required (this lab manages units)."
command -v python3 >/dev/null 2>&1 || die "python3 is required (standard library only)."
command -v systemctl >/dev/null 2>&1 || die "systemctl not found."

if [[ "${1:-}" != "--yes" ]]; then
  cat <<'EOF'
This will BREAK an MCP server on this machine on purpose.
It installs two systemd units (mcp-ops.service, payments-api.service),
writes to /opt/mcp-ops and /var/log/payments-api, and binds 127.0.0.1:8931.

Only continue on a throwaway lab VM.
EOF
  read -r -p "Type 'break it' to continue: " answer
  [[ "${answer}" == "break it" ]] || die "aborted."
fi

say "preparing lab tree under ${LAB_DIR}"
install -d -m 0755 "${LAB_DIR}" "${LOG_DIR}"
rm -f "${MARKER}"

# --------------------------------------------------------------------------
# Fixture: the workload the on-call agent is supposed to operate
# --------------------------------------------------------------------------
cat > "${LAB_DIR}/payments-api.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Lab fixture. Stands in for the real payments-api: it just breathes and logs.
set -euo pipefail
LOG=/var/log/payments-api/app.log
mkdir -p "$(dirname "${LOG}")"
printf '%s payments-api INFO starting pid=%s\n' "$(date -Is)" "$$" >> "${LOG}"
while true; do
  printf '%s payments-api INFO heartbeat rps=%s p99_ms=%s\n' \
    "$(date -Is)" "$(( RANDOM % 40 + 10 ))" "$(( RANDOM % 120 + 30 ))" >> "${LOG}"
  sleep 5
done
FIXTURE
chmod 0755 "${LAB_DIR}/payments-api.sh"

cat > /etc/systemd/system/payments-api.service <<'UNIT'
[Unit]
Description=payments-api (MCPA lab fixture workload)
After=network.target

[Service]
Type=simple
ExecStart=/opt/mcp-ops/payments-api.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT

# --------------------------------------------------------------------------
# The MCP server, as shipped in the bad release 1.4.0
# --------------------------------------------------------------------------
cat > "${LAB_DIR}/ops_server.py" <<'SERVER'
#!/usr/bin/env python3
"""mcp-ops - incident-response MCP server (Streamable HTTP transport).

Gives the on-call assistant three read-only triage tools and one remediation
action against payments-api. Standard library only, single endpoint /mcp.

Spec: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
"""

import json
import os
import subprocess
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "mcp-ops"
SERVER_VERSION = "1.4.0"
BIND_HOST = "127.0.0.1"
BIND_PORT = 8931

LOG_DIR = "/var/log/payments-api"
MANAGED_UNITS = ("payments-api.service",)

SESSIONS = set()
SESSIONS_LOCK = threading.Lock()


# --------------------------------------------------------------------------
# Result helpers - every tool returns one of these two shapes
# --------------------------------------------------------------------------
def text_result(text, structured=None):
    result = {"content": [{"type": "text", "text": text}], "isError": False}
    if structured is not None:
        result["structuredContent"] = structured
    return result


def error_result(message):
    """A tool-level failure. It is a normal result with isError set, NOT a
    JSON-RPC error: the model has to be able to read it and recover."""
    return {"content": [{"type": "text", "text": message}], "isError": True}


def rpc_error(request_id, code, message, data=None):
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def run(command, timeout=60):
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout)


# --------------------------------------------------------------------------
# Tool implementations
# --------------------------------------------------------------------------
def tool_service_status(arguments):
    unit = arguments.get("unit", "payments-api.service")
    if unit not in MANAGED_UNITS:
        return error_result(
            "unit %r is not managed by this server; allowed: %s"
            % (unit, ", ".join(MANAGED_UNITS))
        )
    proc = run(
        [
            "systemctl",
            "show",
            unit,
            "--property=ActiveState",
            "--property=SubState",
            "--property=NRestarts",
            "--property=ExecMainStartTimestamp",
        ]
    )
    if proc.returncode != 0:
        return error_result("systemctl show failed: %s" % proc.stderr.strip())
    props = dict(
        line.split("=", 1) for line in proc.stdout.splitlines() if "=" in line
    )
    structured = {
        "unit": unit,
        "active_state": props.get("ActiveState", "unknown"),
        "sub_state": props.get("SubState", "unknown"),
        "restarts": int(props.get("NRestarts") or 0),
        "started_at": props.get("ExecMainStartTimestamp", ""),
    }
    return text_result(json.dumps(structured, indent=2), structured)


def tool_tail_logs(arguments):
    unit = arguments.get("unit", "payments-api.service")
    if unit not in MANAGED_UNITS:
        return error_result(
            "unit %r is not managed by this server; allowed: %s"
            % (unit, ", ".join(MANAGED_UNITS))
        )
    lines = int(arguments.get("lines", 20))
    lines = max(1, min(lines, 200))
    path = os.path.join(LOG_DIR, "app.log")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            tail = handle.readlines()[-lines:]
    except OSError as exc:
        return error_result("cannot read %s: %s" % (path, exc.strerror))
    return text_result("".join(tail) or "(log file is empty)")


def tool_disk_report(arguments):
    path = arguments.get("path", "/")
    if not path.startswith("/") or ".." in path:
        return error_result("path %r is not an absolute, normalised path" % path)
    proc = run(["df", "-hP", path])
    if proc.returncode != 0:
        return error_result("df failed: %s" % proc.stderr.strip())
    return text_result(proc.stdout.strip())


def tool_restart_service(arguments):
    unit = arguments.get("unit", "")
    proc = subprocess.run(
        "systemctl restart " + unit,
        shell=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        return error_result("restart failed: %s" % (proc.stderr.strip() or "unknown"))
    return text_result("restarted %s" % unit)


TOOL_IMPLS = {
    "service_status": tool_service_status,
    "tail_logs": tool_tail_logs,
    "disk_report": tool_disk_report,
    "restart_service": tool_restart_service,
}

TOOLS = [
    {
        "name": "service_status",
        "title": "Service status",
        "description": "Report ActiveState, SubState and restart count for a managed unit.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "unit": {
                    "type": "string",
                    "description": "systemd unit name, e.g. payments-api.service",
                }
            },
            "required": [],
        },
        "outputSchema": {
            "type": "object",
            "properties": {
                "unit": {"type": "string"},
                "active_state": {"type": "string"},
                "sub_state": {"type": "string"},
                "restarts": {"type": "integer"},
                "started_at": {"type": "string"},
            },
            "required": ["unit", "active_state", "sub_state", "restarts"],
        },
        "annotations": {
            "title": "Service status",
            "readOnlyHint": True,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "tail_logs",
        "title": "Tail application logs",
        "description": "Return the last N lines of the payments-api application log.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "unit": {"type": "string"},
                "lines": {"type": "integer", "minimum": 1, "maximum": 200},
            },
            "required": [],
        },
        "annotations": {
            "title": "Tail application logs",
            "readOnlyHint": True,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "disk_report",
        "title": "Disk usage report",
        "description": "Human-readable df output for the filesystem holding a path.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": [],
        },
        "annotations": {
            "title": "Disk usage report",
            "readOnlyHint": True,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "restart_service",
        "title": "Restart service",
        "description": "Restart a systemd unit on this host.",
        "inputSchema": {
            "type": "object",
            "properties": {"unit": {"type": "string"}},
            "required": ["unit"],
        },
        "annotations": {
            "title": "Restart service",
            "readOnlyHint": True,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
]


# --------------------------------------------------------------------------
# Streamable HTTP transport
# --------------------------------------------------------------------------
class MCPHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "%s/%s" % (SERVER_NAME, SERVER_VERSION)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def reply(self, status, payload, extra_headers=None):
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        # No server-initiated stream in this deployment.
        self.reply(405, rpc_error(None, -32600, "SSE stream not supported"))

    def do_DELETE(self):
        sid = self.headers.get("Mcp-Session-Id")
        with SESSIONS_LOCK:
            SESSIONS.discard(sid)
        self.reply(204, None)

    def do_POST(self):
        if self.path.split("?")[0] != "/mcp":
            self.reply(404, rpc_error(None, -32600, "unknown endpoint"))
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            message = json.loads(raw)
        except ValueError:
            self.reply(400, rpc_error(None, -32700, "parse error"))
            return
        if isinstance(message, list):
            self.reply(400, rpc_error(None, -32600, "JSON-RPC batches are not supported"))
            return

        method = message.get("method")
        request_id = message.get("id")

        if request_id is None:
            # Notification: acknowledge with 202 and no body.
            self.reply(202, None)
            return

        if method == "initialize":
            self.handle_initialize(request_id)
            return

        sid = self.headers.get("Mcp-Session-Id")
        if not sid:
            self.reply(400, rpc_error(request_id, -32600,
                                      "Mcp-Session-Id header is required"))
            return
        with SESSIONS_LOCK:
            known = sid in SESSIONS
        if not known:
            self.reply(404, rpc_error(request_id, -32600,
                                      "unknown session; re-initialize"))
            return

        if method == "ping":
            self.reply(200, {"jsonrpc": "2.0", "id": request_id, "result": {}})
        elif method == "tools/list":
            self.reply(200, {"jsonrpc": "2.0", "id": request_id,
                             "result": {"tools": TOOLS}})
        elif method == "tools/call":
            self.handle_tool_call(request_id, message.get("params") or {})
        else:
            self.reply(200, rpc_error(request_id, -32601,
                                      "method not found: %s" % method))

    def handle_initialize(self, request_id):
        sid = uuid.uuid4().hex
        with SESSIONS_LOCK:
            SESSIONS.add(sid)
        result = {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": (
                "Triage payments-api with the read-only tools before taking "
                "any remediation action."
            ),
            "_meta": {"sessionId": sid},
        }
        self.reply(200, {"jsonrpc": "2.0", "id": request_id, "result": result})

    def handle_tool_call(self, request_id, params):
        name = params.get("name")
        arguments = params.get("arguments") or {}
        impl = TOOL_IMPLS.get(name)
        if impl is None:
            self.reply(200, rpc_error(request_id, -32602, "unknown tool: %s" % name))
            return
        try:
            result = impl(arguments)
        except Exception as exc:  # never leak a traceback to the model
            result = error_result("%s failed: %s" % (name, exc))
        self.reply(200, {"jsonrpc": "2.0", "id": request_id, "result": result})


def main():
    httpd = ThreadingHTTPServer((BIND_HOST, BIND_PORT), MCPHandler)
    sys.stderr.write(
        "%s %s listening on http://%s:%d/mcp (protocol %s)\n"
        % (SERVER_NAME, SERVER_VERSION, BIND_HOST, BIND_PORT, PROTOCOL_VERSION)
    )
    sys.stderr.flush()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
SERVER
chmod 0755 "${LAB_DIR}/ops_server.py"

cat > /etc/systemd/system/mcp-ops.service <<'UNIT'
[Unit]
Description=mcp-ops incident-response MCP server (Streamable HTTP)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /opt/mcp-ops/ops_server.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

# --------------------------------------------------------------------------
# mcp-probe: a stock, spec-shaped MCP host. Treat it as read-only.
# --------------------------------------------------------------------------
cat > "${LAB_DIR}/mcp_probe.py" <<'PROBE'
#!/usr/bin/env python3
"""mcp-probe - a minimal MCP host, used to see mcp-ops the way the agent sees it.

It behaves like a compliant client and nothing more:
  1. POST initialize
  2. POST notifications/initialized
  3. tools/list ONLY if the server advertised a tools capability
  4. tools/call, applying the host approval policy from the tool annotations

This probe is stock software. The change that caused the incident was the
mcp-ops 1.4.0 deploy, not this file.
"""

import json
import sys
import urllib.error
import urllib.request

ENDPOINT = "http://127.0.0.1:8931/mcp"
PROTOCOL_VERSION = "2025-06-18"


def die(message, code=1):
    print(message)
    sys.exit(code)


def post(payload, session=None):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(ENDPOINT, data=data, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json, text/event-stream")
    request.add_header("MCP-Protocol-Version", PROTOCOL_VERSION)
    if session:
        request.add_header("Mcp-Session-Id", session)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
            parsed = json.loads(body) if body.strip() else None
            return response.status, dict(response.headers), parsed
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        try:
            parsed = json.loads(body)
        except ValueError:
            parsed = body
        return exc.code, dict(exc.headers), parsed
    except urllib.error.URLError as exc:
        die("[host] transport error talking to %s: %s" % (ENDPOINT, exc.reason), 2)


def handshake(verbose=True):
    status, headers, body = post(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mcp-probe", "version": "1.0.0"},
            },
        }
    )
    if verbose:
        print("[host] initialize -> HTTP %s" % status)
        print("[host] response headers:")
        for key in sorted(headers):
            print("         %s: %s" % (key, headers[key]))
        print("[host] response body:")
        print(json.dumps(body, indent=2))
    if status != 200 or not isinstance(body, dict) or "result" not in body:
        die("[host] initialize failed; the agent has no session.", 1)

    # Spec: the session id is carried in the Mcp-Session-Id RESPONSE HEADER.
    session = headers.get("Mcp-Session-Id") or headers.get("mcp-session-id")
    capabilities = body["result"].get("capabilities", {})
    if verbose:
        print("[host] session id from header: %s" % (session or "<none returned>"))
        print("[host] advertised capabilities: %s"
              % (", ".join(sorted(capabilities)) or "<none>"))

    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session)
    return session, capabilities


def list_tools(session, capabilities, verbose=True):
    if "tools" not in capabilities:
        print("[host] the server did not advertise a 'tools' capability.")
        print("[host] 0 tools available - the agent will not call tools/list.")
        return []
    status, _, body = post(
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, session
    )
    if status != 200 or not isinstance(body, dict) or "result" not in body:
        print("[host] tools/list -> HTTP %s" % status)
        print(json.dumps(body, indent=2) if isinstance(body, dict) else str(body))
        die("[host] 0 tools available.", 1)
    return body["result"]["tools"]


def approval(tool):
    """Host policy: a tool the server calls read-only runs without asking."""
    annotations = tool.get("annotations") or {}
    if annotations.get("readOnlyHint") is True and not annotations.get("destructiveHint"):
        return "auto"
    return "human"


def cmd_handshake(_argv):
    handshake(verbose=True)


def cmd_tools(_argv):
    session, capabilities = handshake(verbose=True)
    tools = list_tools(session, capabilities)
    print()
    for tool in tools:
        annotations = tool.get("annotations") or {}
        print("  %-16s  approval=%-6s  annotations=%s"
              % (tool["name"], approval(tool), json.dumps(annotations)))
    print("\n[host] %d tool(s) available." % len(tools))


def cmd_call(argv):
    approved = "--yes" in argv
    argv = [item for item in argv if item != "--yes"]
    if not argv:
        die("usage: mcp-probe call <tool> ['<json-arguments>'] [--yes]")
    name = argv[0]
    arguments = json.loads(argv[1]) if len(argv) > 1 else {}

    session, capabilities = handshake(verbose=False)
    tools = list_tools(session, capabilities, verbose=False)
    match = next((tool for tool in tools if tool["name"] == name), None)
    if match is None:
        die("[host] %r is not offered by this server; the agent cannot call it." % name)

    if approval(match) == "auto":
        print("[host] auto-approved: annotations say this tool is read-only.")
    elif approved:
        print("[host] human approval recorded (--yes).")
    else:
        die("[host] BLOCKED: this tool is not read-only. Re-run with --yes to "
            "simulate a human approving it.")

    status, _, body = post(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
        session,
    )
    print("[host] tools/call -> HTTP %s" % status)
    print(json.dumps(body, indent=2))


def cmd_raw(argv):
    if not argv:
        die("usage: mcp-probe raw '<json-rpc message>' [session-id]")
    message = json.loads(argv[0])
    session = argv[1] if len(argv) > 1 else None
    status, headers, body = post(message, session)
    print("HTTP %s" % status)
    for key in sorted(headers):
        print("  %s: %s" % (key, headers[key]))
    print(json.dumps(body, indent=2) if body is not None else "(empty body)")


COMMANDS = {
    "handshake": cmd_handshake,
    "tools": cmd_tools,
    "call": cmd_call,
    "raw": cmd_raw,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die("usage: mcp-probe {handshake|tools|call|raw} [args...]")
    COMMANDS[sys.argv[1]](sys.argv[2:])
PROBE
chmod 0755 "${LAB_DIR}/mcp_probe.py"

printf '#!/usr/bin/env bash\nexec python3 /opt/mcp-ops/mcp_probe.py "$@"\n' > /usr/local/bin/mcp-probe
chmod 0755 /usr/local/bin/mcp-probe

# --------------------------------------------------------------------------
# mcp-lab-verify: independent grader. It does NOT use mcp-probe.
# --------------------------------------------------------------------------
cat > "${LAB_DIR}/verify.py" <<'VERIFY'
#!/usr/bin/env python3
"""Independent grader for the MCPA 5.2 break & fix lab.

Talks to mcp-ops directly over HTTP; it does not import or trust mcp-probe.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ENDPOINT = "http://127.0.0.1:8931/mcp"
PROTOCOL_VERSION = "2025-06-18"
MARKER = "/tmp/mcp-lab-INJECTION-PROVED"
INJECTION = "payments-api.service ; touch " + MARKER

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, ok, detail))


def post(payload, session=None):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(ENDPOINT, data=data, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json, text/event-stream")
    request.add_header("MCP-Protocol-Version", PROTOCOL_VERSION)
    if session:
        request.add_header("Mcp-Session-Id", session)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
            return response.status, dict(response.headers), (
                json.loads(body) if body.strip() else None
            )
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        try:
            parsed = json.loads(body)
        except ValueError:
            parsed = body
        return exc.code, dict(exc.headers), parsed
    except urllib.error.URLError as exc:
        print("cannot reach %s: %s" % (ENDPOINT, exc.reason))
        sys.exit(2)


def call(session, name, arguments):
    status, _, body = post(
        {
            "jsonrpc": "2.0",
            "id": 99,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
        session,
    )
    return status, body


def main():
    if os.path.exists(MARKER):
        os.unlink(MARKER)

    status, headers, body = post(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mcp-lab-verify", "version": "1.0.0"},
            },
        }
    )
    ok_init = status == 200 and isinstance(body, dict) and "result" in body
    check("initialize returns a JSON-RPC result", ok_init, "HTTP %s" % status)
    if not ok_init:
        report()
        return

    session = headers.get("Mcp-Session-Id") or headers.get("mcp-session-id")
    check("initialize returns the Mcp-Session-Id response header",
          bool(session), "header %s" % ("present" if session else "MISSING"))

    capabilities = body["result"].get("capabilities", {})
    check("initialize advertises the 'tools' capability",
          isinstance(capabilities.get("tools"), dict),
          "capabilities = %s" % json.dumps(capabilities))

    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session)

    status, _, listing = post(
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, session
    )
    ok_list = status == 200 and isinstance(listing, dict) and "result" in listing
    check("tools/list succeeds with the header-supplied session", ok_list,
          "HTTP %s" % status)
    if not ok_list:
        report()
        return

    tools = {tool["name"]: tool for tool in listing["result"]["tools"]}
    restart = tools.get("restart_service", {})
    annotations = restart.get("annotations") or {}
    check("restart_service is not annotated readOnlyHint: true",
          annotations.get("readOnlyHint") is not True,
          "readOnlyHint = %r" % annotations.get("readOnlyHint"))
    check("restart_service is annotated destructiveHint: true",
          annotations.get("destructiveHint") is True,
          "destructiveHint = %r" % annotations.get("destructiveHint"))

    status, injected = call(session, "restart_service", {"unit": INJECTION})
    result = (injected or {}).get("result", {})
    rejected = result.get("isError") is True
    check("restart_service rejects an unmanaged/injected unit name", rejected,
          "isError = %r" % result.get("isError"))
    check("no shell injection ran (%s absent)" % MARKER,
          not os.path.exists(MARKER),
          "marker %s" % ("PRESENT" if os.path.exists(MARKER) else "absent"))

    status, happy = call(session, "restart_service", {"unit": "payments-api.service"})
    result = (happy or {}).get("result", {})
    check("restart_service still restarts payments-api.service",
          result.get("isError") is False,
          json.dumps(result.get("content", []))[:120])

    active = subprocess.run(
        ["systemctl", "is-active", "payments-api.service"],
        capture_output=True, text=True,
    ).stdout.strip()
    check("payments-api.service is active after the restart",
          active == "active", "is-active = %s" % active)

    status, logs = call(session, "tail_logs", {"lines": 5})
    result = (logs or {}).get("result", {})
    check("tail_logs still works", result.get("isError") is False,
          "isError = %r" % result.get("isError"))

    status, denied = call(session, "tail_logs", {"unit": "sshd.service"})
    payload = denied or {}
    result = payload.get("result", {})
    check("tail_logs denies an unmanaged unit as a tool error, not -32601/-32603",
          "error" not in payload and result.get("isError") is True,
          json.dumps(payload.get("error", result.get("isError"))))

    report()


def report():
    print()
    failures = 0
    for name, ok, detail in RESULTS:
        flag = "PASS" if ok else "FAIL"
        if not ok:
            failures += 1
        print(" [%s] %-62s %s" % (flag, name, detail))
    print()
    if failures:
        print("%d check(s) failing. Keep going." % failures)
        sys.exit(1)
    print("All checks pass. The on-call agent has its hands back.")


if __name__ == "__main__":
    main()
VERIFY
chmod 0755 "${LAB_DIR}/verify.py"

printf '#!/usr/bin/env bash\nexec python3 /opt/mcp-ops/verify.py "$@"\n' > /usr/local/bin/mcp-lab-verify
chmod 0755 /usr/local/bin/mcp-lab-verify

# --------------------------------------------------------------------------
# Deploy the broken release
# --------------------------------------------------------------------------
say "reloading systemd and starting the units"
systemctl daemon-reload
systemctl enable --now payments-api.service >/dev/null 2>&1
systemctl restart mcp-ops.service 2>/dev/null || systemctl enable --now mcp-ops.service >/dev/null 2>&1
systemctl restart mcp-ops.service

sleep 2
if ! systemctl is-active --quiet mcp-ops.service; then
  journalctl -u mcp-ops.service -n 20 --no-pager || true
  die "mcp-ops failed to start; the lab did not install cleanly."
fi

say "mcp-ops is active on 127.0.0.1:${PORT} — and that is exactly the problem"

# --------------------------------------------------------------------------
# Briefing
# --------------------------------------------------------------------------
cat <<'BRIEF'

==========================================================================
 INCIDENT  #4471 — "the on-call agent lost its hands"
 MCPA 5.2 — Operational Use Cases
==========================================================================

WHAT IS RUNNING
  payments-api.service   the workload being operated (lab fixture)
  mcp-ops.service        MCP server, Streamable HTTP, http://127.0.0.1:8931/mcp
                         source: /opt/mcp-ops/ops_server.py   (release 1.4.0)
  mcp-probe              a stock MCP host — how the agent sees the server
  mcp-lab-verify         the grader; it talks to the server directly

SYMPTOMS YOU WILL SEE
  1. `mcp-probe tools` completes the initialize call with HTTP 200, and then
     every following request fails with:
         HTTP 400 ... "Mcp-Session-Id header is required"
     The server is up. The endpoint answers. The session is still lost.

  2. Once requests stop being rejected, the host reports:
         [host] the server did not advertise a 'tools' capability.
         [host] 0 tools available - the agent will not call tools/list.
     ...even though a hand-written `tools/list` over `mcp-probe raw` returns
     all four tools. "But curl works" is the trap in this incident.

  3. When the tools finally show up, look at how the host treats them:
         mcp-probe call restart_service '{"unit":"payments-api.service"}'
     runs with NO human approval. Then try:
         mcp-probe call restart_service \
           '{"unit":"payments-api.service ; touch /tmp/mcp-lab-INJECTION-PROVED"}'
     and check whether /tmp/mcp-lab-INJECTION-PROVED now exists.

YOUR GOAL
  Make `mcp-lab-verify` report all checks PASS, by fixing
  /opt/mcp-ops/ops_server.py only. Specifically:

  a) The agent can complete a session and list tools without hand-crafted
     requests — the client learns the session the way the spec says it does.
  b) The server honestly declares what it can do during capability
     negotiation.
  c) `restart_service` is described to the host as what it is: a
     non-read-only, destructive action that a human must approve.
  d) `restart_service` can only ever touch a unit this server manages, and a
     unit name can never become extra shell commands. The legitimate restart
     of payments-api.service must keep working.

RULES
  - Do not edit /opt/mcp-ops/mcp_probe.py or /opt/mcp-ops/verify.py. The host
    is stock software and the grader is the exam; the defect shipped in 1.4.0.
  - Do not weaken the three read-only tools. They are your reference for the
    correct patterns already present in the file (allow-list, isError).
  - Reload after every edit:  systemctl restart mcp-ops.service
  - Watch the server:         journalctl -u mcp-ops.service -f

USEFUL COMMANDS
  mcp-probe handshake
  mcp-probe tools
  mcp-probe call tail_logs '{"lines": 5}'
  mcp-probe raw '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}' <session-id>
  mcp-lab-verify

  Re-running this script re-injects every fault, so you can retry the lab.

==========================================================================
BRIEF

exit 0

# ==========================================================================
#  SOLUTION — read only after you have tried it
# ==========================================================================
#
#  There are four defects, in three different layers. Diagnose them in the
#  order the handshake happens: transport, then negotiation, then the tool
#  contract. That order is the point of the exercise — an MCP failure is
#  almost never "the server is down", it is "the server is up and lying about
#  itself at some layer of the handshake".
#
#  --------------------------------------------------------------------
#  FAULT A — the session id never reaches the client (transport)
#  --------------------------------------------------------------------
#  Diagnosis:
#      mcp-probe handshake
#  initialize returns HTTP 200 and the body contains
#      "_meta": {"sessionId": "8f3c..."}
#  but the response HEADERS contain no Mcp-Session-Id. The Streamable HTTP
#  transport says a server that assigns a session MUST return it in the
#  Mcp-Session-Id HTTP response header, and the client MUST echo it back on
#  every later request. A session id buried in the result body is invisible
#  to every compliant client, which is why a hand-written curl that copies it
#  out by eye "works" while the real host cannot.
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#
#  Fix, in handle_initialize():
#
#      def handle_initialize(self, request_id):
#          sid = uuid.uuid4().hex
#          with SESSIONS_LOCK:
#              SESSIONS.add(sid)
#          result = {
#              "protocolVersion": PROTOCOL_VERSION,
#              "capabilities": {"tools": {"listChanged": False}, "logging": {}},
#              "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
#              "instructions": (
#                  "Triage payments-api with the read-only tools before taking "
#                  "any remediation action."
#              ),
#          }
#          self.reply(
#              200,
#              {"jsonrpc": "2.0", "id": request_id, "result": result},
#              extra_headers={"Mcp-Session-Id": sid},
#          )
#
#  (The "_meta" sessionId can go away entirely; it was never the contract.)
#
#      systemctl restart mcp-ops.service
#      mcp-probe handshake      # header now present
#
#  --------------------------------------------------------------------
#  FAULT B — capabilities lied during negotiation
#  --------------------------------------------------------------------
#  Diagnosis: initialize returned "capabilities": {}. Capability negotiation
#  is the contract for the whole session: a client that was told the server
#  has no tools capability will never send tools/list, no matter how many
#  tools the server would happily return. This is the single most common
#  "the model can't see my tools" bug in production MCP servers, and it looks
#  like a client bug from the outside.
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#
#  Fix: already applied above —
#      "capabilities": {"tools": {"listChanged": False}, "logging": {}},
#  Declare listChanged only if you really emit notifications/tools/list_changed;
#  here the tool set is static, so False is the honest value.
#
#      systemctl restart mcp-ops.service
#      mcp-probe tools          # four tools listed
#
#  --------------------------------------------------------------------
#  FAULT C1 — a destructive tool annotated as read-only
#  --------------------------------------------------------------------
#  Diagnosis: `mcp-probe tools` shows
#      restart_service   approval=auto   annotations={"readOnlyHint": true, ...}
#  Annotations are untrusted hints, but they are exactly what hosts use to
#  decide what runs unattended. Labelling a restart read-only hands an
#  autonomous agent production remediation with no human in the loop. This is
#  the operational-use-case lesson: in MCP the blast radius of a tool is set
#  by its declaration, not by its implementation.
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#
#  Fix, in the restart_service entry of TOOLS:
#
#      "annotations": {
#          "title": "Restart service",
#          "readOnlyHint": False,
#          "destructiveHint": True,
#          "idempotentHint": False,
#          "openWorldHint": False,
#      },
#
#  Also tighten the schema so the contract itself is narrow:
#
#      "inputSchema": {
#          "type": "object",
#          "properties": {
#              "unit": {
#                  "type": "string",
#                  "enum": list(MANAGED_UNITS),
#                  "description": "systemd unit to restart; must be managed by this server",
#              }
#          },
#          "required": ["unit"],
#          "additionalProperties": False,
#      },
#
#  After this, the host blocks the call until a human approves:
#      mcp-probe call restart_service '{"unit":"payments-api.service"}'
#      -> [host] BLOCKED ... re-run with --yes
#
#  --------------------------------------------------------------------
#  FAULT C2 — the unit name reaches a shell
#  --------------------------------------------------------------------
#  Diagnosis:
#      mcp-probe call restart_service \
#        '{"unit":"payments-api.service ; touch /tmp/mcp-lab-INJECTION-PROVED"}' --yes
#      ls -l /tmp/mcp-lab-INJECTION-PROVED
#  The file exists. `subprocess.run("systemctl restart " + unit, shell=True)`
#  turns a tool argument into a command line. Tool arguments come from a model,
#  and a model's input comes from logs, tickets and alert payloads — content an
#  attacker can write. Schema validation is a usability feature; the server
#  must re-validate, and must never build a shell string.
#
#  Fix — mirror the pattern the read-only tools already use:
#
#      def tool_restart_service(arguments):
#          unit = arguments.get("unit", "")
#          if unit not in MANAGED_UNITS:
#              return error_result(
#                  "unit %r is not managed by this server; allowed: %s"
#                  % (unit, ", ".join(MANAGED_UNITS))
#              )
#          proc = run(["systemctl", "restart", unit])     # list form, no shell
#          if proc.returncode != 0:
#              return error_result(
#                  "restart of %s failed: %s" % (unit, proc.stderr.strip() or "unknown")
#              )
#          return text_result("restarted %s" % unit)
#
#  Two independent things changed: the allow-list (authorisation) and the list
#  form of subprocess.run (no shell metacharacter interpretation). Keep both —
#  either alone still leaves a hole the day MANAGED_UNITS grows a wildcard.
#
#  --------------------------------------------------------------------
#  VERIFY
#  --------------------------------------------------------------------
#      rm -f /tmp/mcp-lab-INJECTION-PROVED
#      systemctl restart mcp-ops.service
#      mcp-probe tools
#      mcp-probe call restart_service '{"unit":"payments-api.service"}' --yes
#      mcp-lab-verify
#
#  Expected:
#      [PASS] initialize returns a JSON-RPC result
#      [PASS] initialize returns the Mcp-Session-Id response header
#      [PASS] initialize advertises the 'tools' capability
#      [PASS] tools/list succeeds with the header-supplied session
#      [PASS] restart_service is not annotated readOnlyHint: true
#      [PASS] restart_service is annotated destructiveHint: true
#      [PASS] restart_service rejects an unmanaged/injected unit name
#      [PASS] no shell injection ran (/tmp/mcp-lab-INJECTION-PROVED absent)
#      [PASS] restart_service still restarts payments-api.service
#      [PASS] payments-api.service is active after the restart
#      [PASS] tail_logs still works
#      [PASS] tail_logs denies an unmanaged unit as a tool error, not -32601/-32603
#      All checks pass. The on-call agent has its hands back.
#
#  --------------------------------------------------------------------
#  TEARDOWN
#  --------------------------------------------------------------------
#      systemctl disable --now mcp-ops.service payments-api.service
#      rm -f /etc/systemd/system/mcp-ops.service /etc/systemd/system/payments-api.service
#      systemctl daemon-reload
#      rm -rf /opt/mcp-ops /var/log/payments-api /usr/local/bin/mcp-probe \
#             /usr/local/bin/mcp-lab-verify /tmp/mcp-lab-INJECTION-PROVED
#
#  --------------------------------------------------------------------
#  WHAT TO CARRY INTO THE EXAM
#  --------------------------------------------------------------------
#  - An operational MCP server fails silently at three distinct layers:
#    transport/session, capability negotiation, and the tool contract. "The
#    process is running" proves none of them.
#  - The session id lives in the Mcp-Session-Id header, not the result body.
#  - capabilities in the initialize result is a contract: anything not
#    declared there does not exist for the client, however well implemented.
#  - Annotations (readOnlyHint, destructiveHint, idempotentHint,
#    openWorldHint) drive host approval policy. Mis-annotating a remediation
#    tool is an authorisation bug, not a documentation bug.
#  - Validate tool arguments server-side and never interpolate them into a
#    shell. inputSchema constrains a cooperative client; the server is what
#    enforces it.
#  - Tool failures belong in the result as isError: true, so the model can
#    read and recover from them; JSON-RPC errors are for protocol faults.
# ==========================================================================