#!/usr/bin/env bash
#
# ============================================================================
#  MCPA 2.2 - MCP Hosts, Clients and Servers
#  Break & fix lab  |  exam version 2026-07-28  |  exam weight 4.67
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#    It builds a complete, self-contained MCP deployment under a single lab
#    directory: one host application, two clients, two servers (one local over
#    stdio, one remote over Streamable HTTP on 127.0.0.1), and then injects
#    three faults - one in each architectural role. Your job is to diagnose and
#    repair the chain host -> client -> server until the host can open a
#    session with both servers, enumerate their tools and call them.
#
#  SAFETY - read before running
#    * Run this ONLY on a disposable lab VM or container.
#    * Everything lives under $HOME/mcp-lab-2.2 (override with MCP_LAB_HOME).
#      No system file, no package, no unit file and no network interface is
#      touched. The only resource outside the lab directory is TCP port 8931
#      bound to the loopback address (override with MCP_WEATHER_PORT).
#    * `--clean` removes the lab directory and kills the lab server, nothing
#      else, and refuses to do it unless the lab marker file is present.
#    * No root required. Do not run it as root.
#
#  REQUIREMENTS
#    bash 4+, python3 >= 3.9, sed, grep. curl and ss are useful but optional.
#
#  USAGE
#    ./mcpa-2.2-break-fix.sh            build the lab and inject the faults
#    ./mcpa-2.2-break-fix.sh --reset    rebuild from scratch and re-inject
#    ./mcpa-2.2-break-fix.sh --status   show lab state
#    ./mcpa-2.2-break-fix.sh --clean    stop the server and delete the lab
#
#  OFFICIAL SOURCES
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    https://modelcontextprotocol.io/specification/2025-06-18/architecture
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#
#  The full step-by-step solution is at the bottom of this file, commented out.
#  Do not read it until you have spent real time with the diagnostics.
# ============================================================================

set -Eeuo pipefail

LAB_HOME="${MCP_LAB_HOME:-$HOME/mcp-lab-2.2}"
LAB_MARKER="${LAB_HOME}/.mcpa-2.2-lab"
BIN_DIR="${LAB_HOME}/bin"
SRV_DIR="${LAB_HOME}/servers"
DATA_DIR="${LAB_HOME}/data"
LOG_DIR="${LAB_HOME}/logs"
RUN_DIR="${LAB_HOME}/run"
STATE_DIR="${LAB_HOME}/state"
CONFIG_FILE="${LAB_HOME}/hosts.json"
PID_FILE="${RUN_DIR}/weather.pid"

WEATHER_PORT="${MCP_WEATHER_PORT:-8931}"
WRONG_PORT="8999"

PY="$(command -v python3 || true)"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_OFF=$'\033[0m'
else
    C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[ .. ]%s %s\n' "$C_CYAN" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

trap 'die "aborted at line $LINENO"' ERR

# ---------------------------------------------------------------------------
# Preflight and guards
# ---------------------------------------------------------------------------
preflight() {
    [[ -n "$PY" ]] || die "python3 is required and was not found in PATH"
    "$PY" - <<'PY' || die "python3 >= 3.9 is required"
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
    command -v sed  >/dev/null || die "sed is required"
    command -v grep >/dev/null || die "grep is required"

    if [[ "$(id -u)" -eq 0 && "${MCP_LAB_ALLOW_ROOT:-0}" != "1" ]]; then
        die "refusing to run as root. Use an unprivileged user, or set MCP_LAB_ALLOW_ROOT=1 if this VM only has root."
    fi

    case "$LAB_HOME" in
        ""|"/"|"/usr"|"/etc"|"/var"|"/home") die "unsafe MCP_LAB_HOME: '$LAB_HOME'" ;;
    esac

    if [[ -e "$LAB_HOME" && ! -e "$LAB_MARKER" ]]; then
        die "$LAB_HOME exists and is not a lab directory (no marker file). Point MCP_LAB_HOME somewhere else."
    fi
}

confirm_disposable() {
    [[ "${MCP_LAB_ASSUME_YES:-0}" == "1" ]] && return 0
    [[ -t 0 ]] || return 0
    rule
    say "${C_BOLD}This script writes a lab under ${LAB_HOME} and binds 127.0.0.1:${WEATHER_PORT}.${C_OFF}"
    say "It is meant for a disposable VM. Nothing outside that directory is modified."
    rule
    local answer=""
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { say "Nothing was done."; exit 0; }
}

port_is_free() {
    "$PY" - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# Lab construction
# ---------------------------------------------------------------------------
make_tree() {
    mkdir -p "$BIN_DIR" "$SRV_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR"
    printf 'MCPA 2.2 break & fix lab, created %s\n' "$(date -Is)" > "$LAB_MARKER"

    cat > "${DATA_DIR}/README.txt" <<'TXT'
Sample corpus exposed by the 'files' MCP server.
The server root is pinned to this directory through the MCP_FILES_ROOT
environment variable set by the host in hosts.json.
TXT
    cat > "${DATA_DIR}/runbook.md" <<'TXT'
# Runbook: node drain
1. Cordon the node.
2. Drain with a PodDisruptionBudget-aware timeout.
3. Verify no pod is left in Terminating for more than 120s.
TXT
    cat > "${DATA_DIR}/inventory.csv" <<'TXT'
host,role,region
node-01,control-plane,eu-central
node-02,worker,eu-central
node-03,worker,eu-west
TXT
}

write_stdio_server() {
    cat > "${SRV_DIR}/server_files.py" <<'PY'
#!/usr/bin/env python3
"""Lab MCP SERVER - stdio transport.

Architectural role: a server exposes capabilities (here: tools) to exactly one
client over one connection. It is spawned as a subprocess by the host and it
never reaches other servers.

Transport contract for stdio (spec 2025-06-18, basic/transports):
  * stdout carries newline-delimited JSON-RPC 2.0 messages and NOTHING else;
  * every message is a single line, with no embedded newline;
  * diagnostics go to stderr, which the host may capture or discard.
"""
import json
import os
import pathlib
import sys

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "files", "title": "Lab file server", "version": "1.2.0"}
ROOT = pathlib.Path(os.environ.get("MCP_FILES_ROOT", "/tmp")).resolve()

TOOLS = [
    {
        "name": "list_dir",
        "title": "List a directory",
        "description": "List the entries of a directory below the server root.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path relative to the server root"}
            },
            "required": [],
        },
    },
    {
        "name": "read_head",
        "title": "Read the head of a file",
        "description": "Return the first N lines of a text file below the server root.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path relative to the server root"},
                "lines": {"type": "integer", "description": "How many lines, default 10"},
            },
            "required": ["path"],
        },
    },
]

STATE = {"initialized": False}


def log(message):
    """Diagnostics MUST go to stderr: stdout is the JSON-RPC channel."""
    print(f"[files] {message}", file=sys.stderr, flush=True)


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def result(mid, payload):
    return {"jsonrpc": "2.0", "id": mid, "result": payload}


def error(mid, code, message):
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


def resolve(raw):
    target = (ROOT / (raw or ".")).resolve()
    if target != ROOT and ROOT not in target.parents:
        raise ValueError(f"path escapes the server root: {raw!r}")
    return target


def call_tool(name, args):
    if name == "list_dir":
        target = resolve(args.get("path"))
        if not target.is_dir():
            raise ValueError(f"not a directory: {target}")
        rows = []
        for entry in sorted(target.iterdir()):
            kind = "dir " if entry.is_dir() else "file"
            size = entry.stat().st_size if entry.is_file() else 0
            rows.append(f"{kind} {size:>8}  {entry.name}")
        return "\n".join(rows) or "(empty directory)"
    if name == "read_head":
        target = resolve(args.get("path"))
        if not target.is_file():
            raise ValueError(f"not a file: {target}")
        count = int(args.get("lines", 10))
        with target.open("r", encoding="utf-8", errors="replace") as handle:
            head = [next(handle, None) for _ in range(count)]
        return "".join(line for line in head if line is not None).rstrip("\n")
    raise ValueError(f"unknown tool: {name!r}")


def handle(msg):
    mid = msg.get("id")
    method = msg.get("method")
    params = msg.get("params") or {}

    if method == "initialize":
        client = (params.get("clientInfo") or {}).get("name", "unknown")
        log(f"initialize from client={client!r} requested={params.get('protocolVersion')!r}")
        return result(mid, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}, "logging": {}},
            "serverInfo": SERVER_INFO,
            "instructions": "Call list_dir before read_head.",
        })

    if method == "notifications/initialized":
        STATE["initialized"] = True
        log("session initialized: the client confirmed the handshake")
        return None

    if method == "ping":
        return result(mid, {})

    if not STATE["initialized"]:
        log(f"rejecting {method!r}: the lifecycle is not complete")
        return error(mid, -32002,
                     "server not initialized: the client never sent notifications/initialized")

    if method == "tools/list":
        log(f"tools/list -> {len(TOOLS)} tools")
        return result(mid, {"tools": TOOLS})

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        log(f"tools/call name={name!r} arguments={args!r}")
        try:
            text = call_tool(name, args)
        except Exception as exc:
            return result(mid, {
                "content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}],
                "isError": True,
            })
        return result(mid, {"content": [{"type": "text", "text": text}], "isError": False})

    return error(mid, -32601, f"method not found: {method!r}")


def main():
    log(f"starting, root={ROOT}, protocol={PROTOCOL_VERSION}")  # BANNER
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            log(f"dropping malformed frame from the client: {exc}")
            continue
        reply = handle(msg)
        if reply is not None and msg.get("id") is not None:
            send(reply)
    log("stdin closed, exiting")


if __name__ == "__main__":
    main()
PY
    chmod +x "${SRV_DIR}/server_files.py"
}

write_http_server() {
    cat > "${SRV_DIR}/server_weather.py" <<'PY'
#!/usr/bin/env python3
"""Lab MCP SERVER - Streamable HTTP transport, loopback only.

Architectural role: the same server role as the stdio one, reached over HTTP
instead of a pipe. The session is carried by the Mcp-Session-Id header that the
server mints on initialize; the client must echo it on every later request.
"""
import json
import os
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "weather", "title": "Lab weather server", "version": "0.4.1"}
BIND = os.environ.get("MCP_WEATHER_BIND", "127.0.0.1")
PORT = int(os.environ.get("MCP_WEATHER_PORT", "8931"))

SESSIONS = {}

FORECASTS = {
    "rosario": "18C / 27C, scattered clouds, wind 14 km/h NE",
    "berlin": "9C / 15C, light rain, wind 22 km/h W",
    "tokyo": "21C / 29C, clear, wind 8 km/h S",
}

TOOLS = [
    {
        "name": "forecast",
        "title": "City forecast",
        "description": "Return a 24 hour forecast for a city known to the lab dataset.",
        "inputSchema": {
            "type": "object",
            "properties": {"city": {"type": "string", "description": "City name"}},
            "required": ["city"],
        },
    },
    {
        "name": "station_status",
        "title": "Station status",
        "description": "Return the health of the weather station feed.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
]


def call_tool(name, args):
    if name == "forecast":
        city = str(args.get("city", "")).strip()
        if not city:
            raise ValueError("argument 'city' is required")
        return FORECASTS.get(city.lower(), f"no station data for {city!r}; known: "
                                           + ", ".join(sorted(FORECASTS)))
    if name == "station_status":
        return f"feed=ok stations={len(FORECASTS)} sessions={len(SESSIONS)}"
    raise ValueError(f"unknown tool: {name!r}")


class Handler(BaseHTTPRequestHandler):
    server_version = "lab-mcp-weather/0.4.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[weather] %s - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()

    def _respond(self, status, payload, extra=None):
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") == "/healthz":
            self._respond(200, {"status": "ok", "port": PORT,
                                "endpoint": "/mcp", "sessions": len(SESSIONS)})
            return
        self._respond(405, {"error": "this lab server only accepts POST on /mcp"})

    def do_POST(self):
        if self.path.rstrip("/") != "/mcp":
            self._respond(404, {"jsonrpc": "2.0", "id": None, "error": {
                "code": -32601, "message": f"no MCP endpoint at {self.path!r}, use /mcp"}})
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            msg = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            self._respond(400, {"jsonrpc": "2.0", "id": None, "error": {
                "code": -32700, "message": f"parse error: {exc}"}})
            return

        mid = msg.get("id")
        method = msg.get("method")
        params = msg.get("params") or {}
        sid = self.headers.get("Mcp-Session-Id")

        if method == "initialize":
            new_sid = uuid.uuid4().hex
            SESSIONS[new_sid] = {"initialized": False}
            self.log_message("initialize -> session %s", new_sid[:8])
            self._respond(200, {"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
            }}, {"Mcp-Session-Id": new_sid})
            return

        session = SESSIONS.get(sid or "")
        if session is None:
            self._respond(404, {"jsonrpc": "2.0", "id": mid, "error": {
                "code": -32001,
                "message": "unknown or expired session: resend the Mcp-Session-Id returned by initialize"}})
            return

        if method == "notifications/initialized":
            session["initialized"] = True
            self.log_message("session %s initialized", (sid or "")[:8])
            self._respond(202, None)
            return

        if method == "ping":
            self._respond(200, {"jsonrpc": "2.0", "id": mid, "result": {}})
            return

        if not session["initialized"]:
            self.log_message("rejecting %s: lifecycle incomplete", method)
            self._respond(200, {"jsonrpc": "2.0", "id": mid, "error": {
                "code": -32002,
                "message": "server not initialized: the client never sent notifications/initialized"}})
            return

        if method == "tools/list":
            self._respond(200, {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
            return

        if method == "tools/call":
            name = params.get("name")
            args = params.get("arguments") or {}
            try:
                text = call_tool(name, args)
            except Exception as exc:
                self._respond(200, {"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}],
                    "isError": True}})
                return
            self._respond(200, {"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text", "text": text}], "isError": False}})
            return

        self._respond(200, {"jsonrpc": "2.0", "id": mid, "error": {
            "code": -32601, "message": f"method not found: {method!r}"}})


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True
    sys.stderr.write(f"[weather] listening on http://{BIND}:{PORT}/mcp "
                     f"(health: http://{BIND}:{PORT}/healthz) protocol={PROTOCOL_VERSION}\n")
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
PY
    chmod +x "${SRV_DIR}/server_weather.py"
}

write_host() {
    cat > "${BIN_DIR}/host.py" <<'PY'
#!/usr/bin/env python3
"""Lab MCP HOST.

Architectural roles, as the specification defines them:

  HOST    the application the user interacts with. It owns the configuration,
          the trust decisions and the lifecycle of every connection. It is the
          only component that sees all the servers at once.
  CLIENT  a connector created BY the host, one per server, holding exactly one
          stateful session. Clients are isolated from each other by design:
          server A never sees the traffic of server B.
  SERVER  a separate process or service that exposes tools, resources and
          prompts over a transport (stdio here, Streamable HTTP there).

This host reads hosts.json, builds one client per entry, runs the lifecycle
(initialize -> notifications/initialized), enumerates tools and probes one
tool call, then writes state/report.json.
"""
import json
import os
import pathlib
import select
import subprocess
import sys
import time
import urllib.error
import urllib.request

LAB = pathlib.Path(__file__).resolve().parent.parent
CONFIG = LAB / "hosts.json"
LOGS = LAB / "logs"
STATE = LAB / "state"
SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26"]
CLIENT_INFO = {"name": "mcp-lab-host", "title": "MCPA 2.2 lab host", "version": "1.0.0"}
CLIENT_CAPABILITIES = {"roots": {"listChanged": True}, "sampling": {}}
TIMEOUT = 8.0


class TransportError(Exception):
    """The bytes never made it, or they were not JSON-RPC at all."""


class ProtocolError(Exception):
    """The bytes arrived and were valid JSON-RPC, and said no."""


class StdioClient:
    transport = "stdio"

    def __init__(self, name, spec):
        self.name = name
        self.spec = spec
        self.proc = None
        self.errlog = None
        self.protocol_version = None
        self._next_id = 0
        self.log_path = LOGS / f"server-{name}.log"

    def describe(self):
        return " ".join([self.spec.get("command", "?")] + list(self.spec.get("args", [])))

    def connect(self):
        command = [self.spec["command"], *self.spec.get("args", [])]
        env = dict(os.environ)
        env.update(self.spec.get("env", {}))
        self.errlog = open(self.log_path, "ab")
        try:
            self.proc = subprocess.Popen(
                command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.errlog, env=env, bufsize=0,
            )
        except FileNotFoundError as exc:
            raise TransportError(f"cannot spawn {command[0]!r}: {exc}") from None
        except PermissionError as exc:
            raise TransportError(f"cannot execute {command[0]!r}: {exc}") from None

    def _write(self, message):
        blob = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
        try:
            self.proc.stdin.write(blob)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            code = self.proc.poll()
            raise TransportError(
                f"the server process is gone (exit code {code}); see {self.log_path}"
            ) from None

    def _read_frame(self):
        deadline = time.monotonic() + TIMEOUT
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TransportError("timed out waiting for a JSON-RPC frame on stdout")
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            raw = self.proc.stdout.readline()
            if not raw:
                code = self.proc.poll()
                raise TransportError(f"the server closed stdout (exit code {code}); "
                                     f"see {self.log_path}")
            text = raw.decode("utf-8", "replace").strip()
            if not text:
                continue
            try:
                return json.loads(text)
            except json.JSONDecodeError as exc:
                raise TransportError(
                    f"stdout is not a JSON-RPC frame ({exc}); the line was {text[:90]!r}"
                ) from None

    def request(self, method, params=None):
        self._next_id += 1
        mid = self._next_id
        self._write({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}})
        while True:
            frame = self._read_frame()
            if frame.get("id") != mid:
                continue
            if "error" in frame:
                err = frame["error"]
                raise ProtocolError(f"{method} rejected: [{err.get('code')}] {err.get('message')}")
            return frame.get("result", {})

    def notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def close(self):
        if self.proc:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=2)
            except Exception:
                self.proc.kill()
        if self.errlog:
            self.errlog.close()


class HttpClient:
    transport = "streamable-http"

    def __init__(self, name, spec):
        self.name = name
        self.spec = spec
        self.url = spec["url"]
        self.session_id = None
        self.protocol_version = None
        self._next_id = 0

    def describe(self):
        return self.url

    def connect(self):
        return None

    def _post(self, payload):
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        if self.protocol_version:
            headers["MCP-Protocol-Version"] = self.protocol_version
        request = urllib.request.Request(self.url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                body = response.read().decode("utf-8", "replace")
                status = response.status
                session = response.headers.get("Mcp-Session-Id")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            status = exc.code
            session = exc.headers.get("Mcp-Session-Id") if exc.headers else None
        except urllib.error.URLError as exc:
            raise TransportError(f"cannot reach {self.url}: {exc.reason}") from None
        if session:
            self.session_id = session
        if status == 202 or not body.strip():
            return None
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            raise TransportError(
                f"HTTP {status} from {self.url}: the body is not JSON-RPC: {body[:90]!r}"
            ) from None

    def request(self, method, params=None):
        self._next_id += 1
        mid = self._next_id
        frame = self._post({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}})
        if frame is None:
            raise TransportError(f"{method}: empty body where a JSON-RPC response was expected")
        if "error" in frame:
            err = frame["error"]
            raise ProtocolError(f"{method} rejected: [{err.get('code')}] {err.get('message')}")
        return frame.get("result", {})

    def notify(self, method, params=None):
        self._post({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def close(self):
        return None


def build_client(name, spec):
    if "url" in spec:
        return HttpClient(name, spec)
    if "command" in spec:
        return StdioClient(name, spec)
    raise ProtocolError(f"server {name!r}: the entry has neither 'command' nor 'url'")


def open_session(client):
    """Run the MCP lifecycle. Both steps are mandatory, not one and a half."""
    client.connect()
    init = client.request("initialize", {
        "protocolVersion": SUPPORTED_PROTOCOLS[0],
        "capabilities": CLIENT_CAPABILITIES,
        "clientInfo": CLIENT_INFO,
    })
    version = init.get("protocolVersion")
    if version not in SUPPORTED_PROTOCOLS:
        raise ProtocolError(
            f"protocol negotiation failed: the server answered {version!r}, "
            f"this host supports {SUPPORTED_PROTOCOLS}")
    client.protocol_version = version
    client.notify("notifications/initialized")  # LIFECYCLE
    return init


def inspect(name, spec):
    entry = {
        "name": name,
        "transport": "streamable-http" if "url" in spec else "stdio",
        "endpoint": spec.get("url") or " ".join(
            [spec.get("command", "?")] + list(spec.get("args", []))),
        "status": "error",
        "protocolVersion": None,
        "serverInfo": None,
        "capabilities": None,
        "tools": [],
        "probe": None,
        "error": None,
    }
    client = None
    try:
        client = build_client(name, spec)
        init = open_session(client)
        entry["protocolVersion"] = init.get("protocolVersion")
        entry["serverInfo"] = init.get("serverInfo")
        entry["capabilities"] = init.get("capabilities", {})

        if "tools" not in (entry["capabilities"] or {}):
            entry["status"] = "degraded"
            entry["error"] = "the server did not advertise a 'tools' capability, skipping tools/list"
            return entry

        listing = client.request("tools/list")
        entry["tools"] = [tool.get("name") for tool in listing.get("tools", [])]

        probe = spec.get("probe")
        if probe:
            call = client.request("tools/call", {
                "name": probe["tool"], "arguments": probe.get("arguments", {})})
            text = " ".join(
                block.get("text", "") for block in call.get("content", [])
                if block.get("type") == "text").strip()
            entry["probe"] = {
                "tool": probe["tool"],
                "ok": not call.get("isError", False),
                "preview": text.splitlines()[0][:70] if text else "",
            }
        entry["status"] = "ok"
    except (TransportError, ProtocolError) as exc:
        entry["error"] = f"{type(exc).__name__}: {exc}"
    except Exception as exc:  # noqa: BLE001 - a lab host reports, it does not crash
        entry["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        if client:
            try:
                client.close()
            except Exception:
                pass
    return entry


def main():
    if not CONFIG.exists():
        print(f"host configuration not found: {CONFIG}", file=sys.stderr)
        return 2
    try:
        config = json.loads(CONFIG.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"host configuration is not valid JSON: {exc}", file=sys.stderr)
        return 2

    servers = config.get("mcpServers") or {}
    if not servers:
        print("host configuration declares no servers under 'mcpServers'", file=sys.stderr)
        return 2

    STATE.mkdir(parents=True, exist_ok=True)
    report = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "servers": []}

    print()
    print("MCP host report - one client per server, one session per client")
    print("=" * 70)
    for name in sorted(servers):
        entry = inspect(name, servers[name])
        report["servers"].append(entry)

        mark = {"ok": "[ ok ]", "degraded": "[warn]", "error": "[fail]"}[entry["status"]]
        server_info = entry["serverInfo"] or {}
        print(f"{mark} {name:<9} transport={entry['transport']}")
        print(f"       endpoint   {entry['endpoint']}")
        if entry["protocolVersion"]:
            print(f"       negotiated protocol={entry['protocolVersion']} "
                  f"server={server_info.get('name')} v{server_info.get('version')}")
            print(f"       capabilities {', '.join(sorted(entry['capabilities'] or {})) or '(none)'}")
        if entry["tools"]:
            print(f"       tools      {len(entry['tools'])}: {', '.join(entry['tools'])}")
        if entry["probe"]:
            state = "ok" if entry["probe"]["ok"] else "tool error"
            print(f"       probe      {entry['probe']['tool']}() -> {state}: "
                  f"{entry['probe']['preview']}")
        if entry["error"]:
            print(f"       problem    {entry['error']}")
        print("-" * 70)

    (STATE / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    broken = [s["name"] for s in report["servers"] if s["status"] != "ok"]
    if broken:
        print(f"{len(broken)} of {len(report['servers'])} servers are not usable: "
              f"{', '.join(broken)}")
        print(f"report written to {STATE / 'report.json'}")
        return 1
    print(f"all {len(report['servers'])} servers are connected and usable")
    print(f"report written to {STATE / 'report.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
    chmod +x "${BIN_DIR}/host.py"
}

write_verifier() {
    cat > "${BIN_DIR}/verify.py" <<'PY'
#!/usr/bin/env python3
"""Lab grader: reads state/report.json and applies the acceptance criteria."""
import json
import pathlib
import sys

LAB = pathlib.Path(__file__).resolve().parent.parent
REPORT = LAB / "state" / "report.json"

EXPECTED = {
    "files": {"transport": "stdio", "tools": {"list_dir", "read_head"}},
    "weather": {"transport": "streamable-http", "tools": {"forecast", "station_status"}},
}
SUPPORTED_PROTOCOLS = {"2025-06-18", "2025-03-26"}


def main():
    if not REPORT.exists():
        print("[fail] no report found - run 'mcpctl run' first")
        return 1
    report = json.loads(REPORT.read_text(encoding="utf-8"))
    servers = {entry["name"]: entry for entry in report.get("servers", [])}
    failures = []

    for name, expected in EXPECTED.items():
        entry = servers.get(name)
        if entry is None:
            failures.append(f"{name}: the host configuration does not declare this server")
            continue
        if entry["transport"] != expected["transport"]:
            failures.append(f"{name}: transport is {entry['transport']}, "
                            f"expected {expected['transport']}")
        if entry["status"] != "ok":
            failures.append(f"{name}: status={entry['status']} - {entry.get('error')}")
            continue
        if entry.get("protocolVersion") not in SUPPORTED_PROTOCOLS:
            failures.append(f"{name}: negotiated protocol {entry.get('protocolVersion')!r}")
        missing = expected["tools"] - set(entry.get("tools") or [])
        if missing:
            failures.append(f"{name}: tools missing from tools/list: {', '.join(sorted(missing))}")
        probe = entry.get("probe")
        if not probe or not probe.get("ok"):
            failures.append(f"{name}: the tools/call probe did not succeed")

    print()
    if failures:
        print("RESULT: NOT FIXED YET")
        for item in failures:
            print(f"  [fail] {item}")
        print()
        print("Re-run 'mcpctl run' after each change and read the 'problem' line.")
        return 1
    print("RESULT: PASSED")
    print("  [ ok ] both sessions negotiated a supported protocol version")
    print("  [ ok ] both servers advertise tools and answer tools/list")
    print("  [ ok ] a real tools/call round-trips on each transport")
    print()
    print("You repaired the three roles: host configuration, client lifecycle,")
    print("server transport hygiene. Now read the solution at the bottom of the")
    print("break & fix script and compare it with what you did.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
    chmod +x "${BIN_DIR}/verify.py"
}

write_config() {
    cat > "$CONFIG_FILE" <<EOF
{
  "mcpServers": {
    "files": {
      "transport": "stdio",
      "command": "${PY}",
      "args": ["${SRV_DIR}/server_files.py"],
      "env": {
        "MCP_FILES_ROOT": "${DATA_DIR}"
      },
      "probe": {
        "tool": "list_dir",
        "arguments": {
          "path": "."
        }
      }
    },
    "weather": {
      "transport": "streamable-http",
      "url": "http://127.0.0.1:${WEATHER_PORT}/mcp",
      "probe": {
        "tool": "forecast",
        "arguments": {
          "city": "Rosario"
        }
      }
    }
  }
}
EOF
}

write_mcpctl() {
    cat > "${BIN_DIR}/mcpctl" <<EOF
#!/usr/bin/env bash
# Lab control plane for the MCPA 2.2 break & fix exercise.
set -Eeuo pipefail
LAB="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PY}"
PORT="${WEATHER_PORT}"
EOF
    cat >> "${BIN_DIR}/mcpctl" <<'EOF'
PID_FILE="${LAB}/run/weather.pid"

usage() {
    cat <<USAGE
mcpctl <command>

  run          run the host: connect every configured server and report
  verify       grade the lab against the acceptance criteria
  config       print the host configuration (hosts.json)
  status       show the weather server process and the listening socket
  logs [name]  tail a server log: files | weather | all (default: all)
  start        start the weather server
  stop         stop the weather server
  restart      stop then start the weather server
USAGE
}

weather_pid() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid; pid="$(cat "$PID_FILE")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && { printf '%s' "$pid"; return 0; }
    return 1
}

start_weather() {
    if weather_pid >/dev/null; then
        echo "weather server already running (pid $(weather_pid))"
        return 0
    fi
    MCP_WEATHER_PORT="$PORT" nohup "$PY" "${LAB}/servers/server_weather.py" \
        >> "${LAB}/logs/server-weather.log" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 0.7
    if weather_pid >/dev/null; then
        echo "weather server started (pid $(weather_pid)) on 127.0.0.1:${PORT}"
    else
        echo "weather server failed to start, see ${LAB}/logs/server-weather.log" >&2
        return 1
    fi
}

stop_weather() {
    if ! weather_pid >/dev/null; then
        echo "weather server is not running"
        rm -f "$PID_FILE"
        return 0
    fi
    local pid; pid="$(weather_pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "weather server stopped"
}

cmd="${1:-}"
case "$cmd" in
    run)     exec "$PY" "${LAB}/bin/host.py" ;;
    verify)  "$PY" "${LAB}/bin/host.py" >/dev/null 2>&1 || true
             exec "$PY" "${LAB}/bin/verify.py" ;;
    config)  exec cat "${LAB}/hosts.json" ;;
    start)   start_weather ;;
    stop)    stop_weather ;;
    restart) stop_weather; start_weather ;;
    status)
        if weather_pid >/dev/null; then
            echo "weather server: running, pid $(weather_pid)"
        else
            echo "weather server: NOT running"
        fi
        echo "configured endpoint: $(grep -o 'http://[^"]*' "${LAB}/hosts.json" || echo '(none)')"
        if command -v ss >/dev/null; then
            echo "listening sockets owned by this user:"
            ss -lntp 2>/dev/null | grep -E '127\.0\.0\.1:(89|85|80)[0-9][0-9]' || echo "  (none matched)"
        fi
        echo "health check:"
        "$PY" - "$PORT" <<'PYEOF'
import json, sys, urllib.request, urllib.error
port = sys.argv[1]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=3) as r:
        print("  ", r.read().decode().strip())
except Exception as exc:
    print(f"   127.0.0.1:{port} -> {exc}")
PYEOF
        ;;
    logs)
        target="${2:-all}"
        case "$target" in
            files)   tail -n 30 "${LAB}/logs/server-files.log" 2>/dev/null || echo "(no log yet)" ;;
            weather) tail -n 30 "${LAB}/logs/server-weather.log" 2>/dev/null || echo "(no log yet)" ;;
            all)
                for f in "${LAB}"/logs/*.log; do
                    [[ -e "$f" ]] || continue
                    echo "==> $f <=="
                    tail -n 20 "$f"
                    echo
                done ;;
            *) usage; exit 2 ;;
        esac ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac
EOF
    chmod +x "${BIN_DIR}/mcpctl"
}

# ---------------------------------------------------------------------------
# Fault injection - three faults, one per architectural role
# ---------------------------------------------------------------------------
inject_fault_server_transport() {
    local target="${SRV_DIR}/server_files.py"
    sed -i 's|^    log(f"starting.*# BANNER$|    print(f"[files] starting, root={ROOT}, protocol={PROTOCOL_VERSION}", flush=True)  # BANNER|' "$target"
    grep -q 'print(f"\[files\] starting' "$target" \
        || die "fault injection failed in $target (server transport)"
    info "fault injected in the SERVER role"
}

inject_fault_client_lifecycle() {
    local target="${BIN_DIR}/host.py"
    sed -i 's|^    client.notify("notifications/initialized")  # LIFECYCLE$|    # client.notify("notifications/initialized")  # LIFECYCLE|' "$target"
    grep -q '^    # client.notify("notifications/initialized")' "$target" \
        || die "fault injection failed in $target (client lifecycle)"
    info "fault injected in the CLIENT role"
}

inject_fault_host_config() {
    sed -i "s|http://127.0.0.1:${WEATHER_PORT}/mcp|http://127.0.0.1:${WRONG_PORT}/mcp|" "$CONFIG_FILE"
    grep -q "127.0.0.1:${WRONG_PORT}/mcp" "$CONFIG_FILE" \
        || die "fault injection failed in $CONFIG_FILE (host configuration)"
    info "fault injected in the HOST role"
}

# ---------------------------------------------------------------------------
# Lifecycle of the lab itself
# ---------------------------------------------------------------------------
stop_weather_server() {
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.3
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

start_weather_server() {
    MCP_WEATHER_PORT="$WEATHER_PORT" nohup "$PY" "${SRV_DIR}/server_weather.py" \
        >> "${LOG_DIR}/server-weather.log" 2>&1 &
    echo $! > "$PID_FILE"
    local pid; pid="$(cat "$PID_FILE")"
    local i
    for i in $(seq 25); do
        if "$PY" - "$WEATHER_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/healthz", timeout=1).read()
PY
        then
            ok "weather server is up on http://127.0.0.1:${WEATHER_PORT}/mcp (pid ${pid})"
            return 0
        fi
        sleep 0.2
    done
    die "the weather server did not come up; see ${LOG_DIR}/server-weather.log"
}

briefing() {
    rule
    say "${C_BOLD}MCPA 2.2 - MCP Hosts, Clients and Servers | BREAK & FIX${C_OFF}"
    rule
    cat <<EOF

THE DEPLOYMENT YOU JUST GOT

  HOST      ${BIN_DIR}/host.py
            Reads ${CONFIG_FILE}, creates one CLIENT per entry,
            and each client owns exactly ONE session against ONE server.

  SERVER 1  ${SRV_DIR}/server_files.py
            Transport: stdio. Spawned by the host as a child process. Tools:
            list_dir, read_head, rooted at ${DATA_DIR}.

  SERVER 2  ${SRV_DIR}/server_weather.py
            Transport: Streamable HTTP on 127.0.0.1:${WEATHER_PORT}/mcp, already
            running as a separate process. Tools: forecast, station_status.

  CONTROL   ${BIN_DIR}/mcpctl  (run | verify | config | status | logs | restart)

WHAT WAS BROKEN

  Three faults were injected, one in each architectural role: the host layer,
  the client layer and the server layer. Each fault fails in a different place
  of the connection, which is exactly the point of the exercise - "the MCP
  server does not work" is never a diagnosis.

THE SYMPTOMS YOU WILL SEE

  Run:   ${BIN_DIR}/mcpctl run

  1. Server 'files' never reaches a usable state. The host reports that what
     came back on stdout is not a JSON-RPC frame, and prints the offending
     line. The process is alive; the channel is polluted.

  2. Server 'weather' is unreachable: connection refused. The server process is
     running and healthy - check it yourself - so the fault is not in the
     server.

  3. Once a session does open, the server answers requests with JSON-RPC error
     -32002, "server not initialized". The handshake started and was never
     finished. This one is in the client, and it affects BOTH servers.

  The three faults overlap: fixing one uncovers the next. Work top-down through
  the report after every change.

WHAT YOU MUST ACHIEVE

  ${BIN_DIR}/mcpctl verify   must print   RESULT: PASSED

  which means, for both servers: a session negotiated at a supported protocol
  version, tools/list returning the two expected tools, and a real tools/call
  that round-trips without isError.

RULES OF ENGAGEMENT

  * Only files under ${LAB_HOME} may be edited.
  * Do not rewrite the servers to skip the lifecycle, and do not remove the
    -32002 check: that check is correct behaviour and the fix is elsewhere.
  * Restarting the weather server is allowed: mcpctl restart

USEFUL DIAGNOSTICS

  ${BIN_DIR}/mcpctl run                  the host report, your main instrument
  ${BIN_DIR}/mcpctl status               process, socket and /healthz
  ${BIN_DIR}/mcpctl logs files           stderr of the stdio server
  ${BIN_DIR}/mcpctl logs weather         stderr and access log of the HTTP server
  ${BIN_DIR}/mcpctl config               the host configuration as the host sees it

  Drive the stdio server by hand, the way the client does - if the first line
  that comes back is not JSON, you found fault number one:

    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}' \\
      | MCP_FILES_ROOT=${DATA_DIR} ${PY} ${SRV_DIR}/server_files.py

  Drive the HTTP server by hand and read the response headers, the session id
  lives there:

    curl -isS http://127.0.0.1:${WEATHER_PORT}/mcp \\
      -H 'Content-Type: application/json' \\
      -H 'Accept: application/json, text/event-stream' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

  Reference for the three roles, the lifecycle and the transport rules:
    https://modelcontextprotocol.io/specification/2025-06-18/architecture
    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

  The step-by-step solution is at the bottom of this script, commented out.
  Open it only after you have worked the three symptoms.

EOF
    rule
}

do_status() {
    [[ -e "$LAB_MARKER" ]] || die "no lab found at $LAB_HOME - run this script with no arguments first"
    exec "${BIN_DIR}/mcpctl" status
}

do_clean() {
    [[ -e "$LAB_MARKER" ]] || die "refusing to delete $LAB_HOME: the lab marker file is not there"
    stop_weather_server
    rm -rf "${LAB_HOME:?}"
    ok "lab removed: $LAB_HOME"
}

do_build() {
    preflight
    confirm_disposable

    if [[ -e "$LAB_MARKER" ]]; then
        info "an existing lab was found, rebuilding it from scratch"
        stop_weather_server
        rm -rf "${LAB_HOME:?}"
    fi

    if ! port_is_free "$WEATHER_PORT"; then
        die "127.0.0.1:${WEATHER_PORT} is already in use. Re-run with MCP_WEATHER_PORT=<free port>."
    fi

    info "building the lab under ${LAB_HOME}"
    make_tree
    write_stdio_server
    write_http_server
    write_host
    write_verifier
    write_config
    write_mcpctl
    ok "host, two servers, configuration and tooling written"

    start_weather_server

    info "injecting three faults, one per architectural role"
    inject_fault_server_transport
    inject_fault_client_lifecycle
    inject_fault_host_config
    ok "the lab is broken and ready"

    briefing
}

main() {
    case "${1:-}" in
        ""|--break|--reset) do_build ;;
        --status)           do_status ;;
        --clean)            do_clean ;;
        -h|--help)
            sed -n '2,45p' "$0"
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
}

main "${@:-}"

# ===========================================================================
# ===========================================================================
#
#                          S O L U T I O N
#
#   Stop here unless you have already worked the three symptoms.
#
# ===========================================================================
# ===========================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 - Get the whole picture before touching anything
# ---------------------------------------------------------------------------
#
#   $LAB/bin/mcpctl run
#
# Expected output, before any fix:
#
#   [fail] files     transport=stdio
#          endpoint   /usr/bin/python3 .../servers/server_files.py
#          problem    TransportError: stdout is not a JSON-RPC frame (Expecting
#                     value: line 1 column 1 (char 0)); the line was
#                     '[files] starting, root=..., protocol=2025-06-18'
#   ----------------------------------------------------------------------
#   [fail] weather   transport=streamable-http
#          endpoint   http://127.0.0.1:8999/mcp
#          problem    TransportError: cannot reach http://127.0.0.1:8999/mcp:
#                     [Errno 111] Connection refused
#
# Two different failures. Read them as coordinates, not as verdicts:
#   * 'files'   failed AFTER the process started - it is a transport/framing
#               problem inside the server.
#   * 'weather' failed BEFORE any MCP message was sent - it is a reachability
#               problem, i.e. the host's map is wrong or the server is down.
#
#
# ---------------------------------------------------------------------------
# STEP 1 - Fault in the SERVER role: stdout pollution on the stdio transport
# ---------------------------------------------------------------------------
#
# Diagnosis. Drive the server the way a client does:
#
#   printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}' \
#     | MCP_FILES_ROOT=$LAB/data python3 $LAB/servers/server_files.py 2>/dev/null
#
# The first line on stdout is:
#
#   [files] starting, root=/home/you/mcp-lab-2.2/data, protocol=2025-06-18
#
# That is a log line on the JSON-RPC channel. Note the '2>/dev/null': the line
# survives it, which proves it is on stdout and not on stderr. Per the stdio
# transport rules, the server MUST NOT write anything to stdout that is not a
# valid JSON-RPC message; anything it wants to log goes to stderr.
#
# Fix - in $LAB/servers/server_files.py, inside main(), the banner line:
#
#   -    print(f"[files] starting, root={ROOT}, protocol={PROTOCOL_VERSION}", flush=True)  # BANNER
#   +    log(f"starting, root={ROOT}, protocol={PROTOCOL_VERSION}")  # BANNER
#
# The log() helper already writes to stderr, which is where the host is
# capturing it (logs/server-files.log). One-liner, if you prefer:
#
#   sed -i 's|^    print(f"\[files\] starting.*# BANNER$|    log(f"starting, root={ROOT}, protocol={PROTOCOL_VERSION}")  # BANNER|' \
#     $LAB/servers/server_files.py
#
# Verify the channel is clean now - the only stdout line must be JSON:
#
#   printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}' \
#     | MCP_FILES_ROOT=$LAB/data python3 $LAB/servers/server_files.py 2>/dev/null \
#     | python3 -m json.tool
#
#   $LAB/bin/mcpctl run
#
# 'files' now negotiates protocol 2025-06-18 and fails one step later, with
# [-32002] "server not initialized". Progress: the transport is fixed, the
# lifecycle is not. That is STEP 3.
#
#
# ---------------------------------------------------------------------------
# STEP 2 - Fault in the HOST role: the configuration points at the wrong port
# ---------------------------------------------------------------------------
#
# Diagnosis. First establish whether the server is actually down:
#
#   $LAB/bin/mcpctl status
#
#   weather server: running, pid 12345
#   configured endpoint: http://127.0.0.1:8999/mcp
#   listening sockets owned by this user:
#     LISTEN 0 5 127.0.0.1:8931 0.0.0.0:* users:(("python3",pid=12345,fd=3))
#   health check:
#     {"status": "ok", "port": 8931, "endpoint": "/mcp", "sessions": 0}
#
# The server is healthy on 8931; the host is dialling 8999. The server log says
# the same thing:
#
#   $LAB/bin/mcpctl logs weather | head -1
#   [weather] listening on http://127.0.0.1:8931/mcp (health: .../healthz) protocol=2025-06-18
#
# This is the host's job and nothing else's: the host owns the connection
# inventory. A client cannot discover a server it was never pointed at.
#
# Fix - in $LAB/hosts.json, entry "weather":
#
#   -      "url": "http://127.0.0.1:8999/mcp"
#   +      "url": "http://127.0.0.1:8931/mcp"
#
#   sed -i 's|127.0.0.1:8999/mcp|127.0.0.1:8931/mcp|' $LAB/hosts.json
#   python3 -m json.tool $LAB/hosts.json > /dev/null && echo "config still valid JSON"
#
# Verify:
#
#   $LAB/bin/mcpctl run
#
# 'weather' now reaches the server and fails with the same [-32002] as 'files'.
# Both clients are now failing identically - a strong hint that the remaining
# fault is not in either server but in the code they share: the client.
#
#
# ---------------------------------------------------------------------------
# STEP 3 - Fault in the CLIENT role: an unfinished lifecycle
# ---------------------------------------------------------------------------
#
# Diagnosis. The MCP lifecycle has three messages, not two:
#
#   client -> server   initialize                 (request, expects a response)
#   server -> client   InitializeResult           (protocol version + capabilities)
#   client -> server   notifications/initialized  (notification, no response)
#
# Only after the third message is the session operational; before it, a server
# is entitled to reject every other request. Both lab servers implement that
# check, and both are returning the same error, with the reason spelled out:
#
#   [-32002] server not initialized: the client never sent notifications/initialized
#
# Confirm it end to end against the HTTP server, where you can see the session:
#
#   SID=$(curl -isS http://127.0.0.1:8931/mcp \
#          -H 'Content-Type: application/json' \
#          -H 'Accept: application/json, text/event-stream' \
#          -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}' \
#          | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tr -d '\r')
#
#   # tools/list without the notification -> -32002
#   curl -sS http://127.0.0.1:8931/mcp -H 'Content-Type: application/json' \
#     -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $SID" \
#     -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
#
#   # send the missing notification (HTTP 202, empty body), then retry
#   curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8931/mcp \
#     -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
#     -H "Mcp-Session-Id: $SID" \
#     -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
#
#   curl -sS http://127.0.0.1:8931/mcp -H 'Content-Type: application/json' \
#     -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $SID" \
#     -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' | python3 -m json.tool
#
# The second tools/list returns the two tools. So the servers are right and the
# host's client is skipping a step. Find it:
#
#   grep -n 'notifications/initialized' $LAB/bin/host.py
#
# Fix - in $LAB/bin/host.py, function open_session(), uncomment the line:
#
#   -    # client.notify("notifications/initialized")  # LIFECYCLE
#   +    client.notify("notifications/initialized")  # LIFECYCLE
#
#   sed -i 's|^    # client.notify("notifications/initialized")  # LIFECYCLE$|    client.notify("notifications/initialized")  # LIFECYCLE|' \
#     $LAB/bin/host.py
#
# Note that the fix is in ONE place and repairs BOTH connections: the client
# logic is transport-agnostic, which is precisely what the transport abstraction
# buys you. Note too that the notification is fire-and-forget - it has no "id",
# so there is no response to wait for, and a client that waits for one hangs.
#
#
# ---------------------------------------------------------------------------
# STEP 4 - Final verification
# ---------------------------------------------------------------------------
#
#   $LAB/bin/mcpctl run
#
#   [ ok ] files     transport=stdio
#          negotiated protocol=2025-06-18 server=files v1.2.0
#          capabilities logging, tools
#          tools      2: list_dir, read_head
#          probe      list_dir() -> ok: file      112  README.txt
#   ----------------------------------------------------------------------
#   [ ok ] weather   transport=streamable-http
#          negotiated protocol=2025-06-18 server=weather v0.4.1
#          capabilities tools
#          tools      2: forecast, station_status
#          probe      forecast() -> ok: 18C / 27C, scattered clouds, wind 14 km/h NE
#
#   $LAB/bin/mcpctl verify
#   RESULT: PASSED
#
#
# ---------------------------------------------------------------------------
# WHAT THIS EXERCISE IS ACTUALLY TEACHING
# ---------------------------------------------------------------------------
#
# 1. The three roles fail in three different places, and the error tells you
#    which one:
#      - it never connected            -> the HOST's configuration (its map)
#      - it connected and was rejected -> the CLIENT's session handling
#      - it connected and the bytes were garbage -> the SERVER's transport
#
# 2. Isolation is structural, not incidental. Each client holds one session
#    with one server; 'weather' being misconfigured cannot break 'files', and
#    the stdio server never learns that an HTTP server exists. The only
#    component with a view of all servers is the host - which is also the only
#    component that can leak data between them, and the reason the host is
#    where consent and trust decisions belong.
#
# 3. stdout on a stdio server is a protocol channel, not a console. Any library
#    that prints - a deprecation warning, a progress bar, a debug print left in
#    a handler - corrupts the stream. Route logging to stderr and keep it that
#    way in CI: this is the single most common failure in real MCP servers.
#
# 4. initialize is a negotiation, not a greeting. The response carries the
#    protocol version the session will actually use and the capabilities that
#    make tools/list, resources/list or prompts/list legal at all. A client
#    that calls a method for a capability the server never advertised is out of
#    spec even when the server happens to answer.
#
# 5. notifications/initialized is the third leg of the handshake. Omit it and
#    you get a connection that looks established and rejects everything -
#    exactly the class of bug that reads like "the server is broken" and is not.
#
# ---------------------------------------------------------------------------
# Tear the lab down when you are done:   ./mcpa-2.2-break-fix.sh --clean
# Rebuild it broken to practise again:   ./mcpa-2.2-break-fix.sh --reset
# ---------------------------------------------------------------------------