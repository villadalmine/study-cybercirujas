#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# MCPA - Model Context Protocol Associate
# Domain 2, topic 2.3: Model Interaction Flow  (exam weight 4.67)
#
# break & fix lab
#
# What this is
#   A disposable, offline lab that stands up a real MCP server over stdio and
#   a host-side probe that walks the full model-interaction flow:
#
#       initialize -> InitializeResult -> notifications/initialized
#       -> tools/list -> tools/call -> sampling/createMessage -> CallToolResult
#
#   The server is shipped broken in five places, one per layer of that flow.
#   The probe stops at the first layer that misbehaves and tells you the
#   symptom a student would see in a real client (Claude Desktop, an IDE
#   agent, an SDK host) and what has to become true for that layer to pass.
#
# Safety
#   Nothing outside the lab directory is touched. No root, no package
#   installs, no systemd units, no network, no changes to any MCP client you
#   may already have configured. The only dependency is python3 (>= 3.8) from
#   the base image. Everything lives under $MCP_LAB_DIR (default
#   ~/mcp-flow-lab) and "clean" deletes exactly that directory, and only if it
#   carries this lab's marker file.
#
# Usage
#   ./mcpa-2.3-break-fix.sh            # write the lab, break it, show symptom 1
#   ./mcpa-2.3-break-fix.sh probe      # re-run the probe (your oracle)
#   ./mcpa-2.3-break-fix.sh hint       # the five layers, without the answers
#   ./mcpa-2.3-break-fix.sh reset      # restore the broken build (destroys edits)
#   ./mcpa-2.3-break-fix.sh clean      # remove the lab directory
#
# Official sources
#   Linux Foundation MCPA certification
#     https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#   MCP specification, revision 2025-06-18
#     https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#     https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#     https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#     https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
#
# The step-by-step solution is at the end of this file, commented out.
# ---------------------------------------------------------------------------

set -euo pipefail

LAB_DIR="${MCP_LAB_DIR:-$HOME/mcp-flow-lab}"
MARKER="$LAB_DIR/.mcpa-2.3-lab"
SERVER_FILE="$LAB_DIR/weather_mcp.py"
PROBE_FILE="$LAB_DIR/flow_probe.py"
SELF="$0"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    B="$(tput bold)"; R="$(tput setaf 1)"; G="$(tput setaf 2)"; Y="$(tput setaf 3)"; C="$(tput setaf 6)"; N="$(tput sgr0)"
else
    B=""; R=""; G=""; Y=""; C=""; N=""
fi

die() { printf '%s\n' "${R}error:${N} $*" >&2; exit 2; }

check_python() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found in PATH"
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
        || die "python3 >= 3.8 is required (found $(python3 -V 2>&1))"
}

confirm_disposable_vm() {
    [ "${MCP_LAB_CONFIRM:-}" = "yes" ] && return 0
    if [ ! -t 0 ]; then
        die "not a terminal; re-run with MCP_LAB_CONFIRM=yes if this really is a throwaway VM"
    fi
    cat <<EOF

${B}This lab writes files under:${N} $LAB_DIR
It does not need root, does not reach the network, and does not modify any
MCP client configuration. Run it on a disposable lab VM anyway: that is the
habit you want when a lab tells you it is going to break something.

EOF
    printf 'Type %sBREAK%s to continue: ' "$B" "$N"
    read -r reply
    [ "$reply" = "BREAK" ] || { echo "aborted."; exit 2; }
}

# ---------------------------------------------------------------------------
# The server under test: shipped broken, five faults, marked LAB-FAULT-n
# ---------------------------------------------------------------------------
write_server() {
    cat > "$SERVER_FILE" <<'PY'
#!/usr/bin/env python3
"""weather-mcp - a minimal MCP server over stdio (lab build).

It speaks the slice of the protocol that topic 2.3 is about:

    client                                     server
      | ---- initialize (request) --------------> |
      | <--- InitializeResult ------------------- |
      | ---- notifications/initialized ---------> |
      | ---- tools/list ------------------------> |
      | <--- ListToolsResult -------------------- |
      | ---- tools/call ------------------------> |
      | <--- sampling/createMessage (request) --- |   server asks the host's model
      | ---- CreateMessageResult ---------------> |
      | <--- CallToolResult --------------------- |

Note the direction reversal in the middle: on a single session the server is
also a JSON-RPC client. That is what makes MCP a flow and not a REST API.

THIS BUILD IS DELIBERATELY BROKEN in five places, each marked LAB-FAULT-n,
one per layer of the flow. The fixes are not in this file.

Specification, revision 2025-06-18:
  https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
  https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
  https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
"""

import json
import os
import select
import sys
import time

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "weather-mcp", "version": "0.4.1"}

FORECASTS = {
    "rosario": {"station": "SAAR", "temp_c": 21.4, "wind_kph": 34, "sky": "broken clouds"},
    "cordoba": {"station": "SACO", "temp_c": 18.9, "wind_kph": 12, "sky": "clear"},
    "ushuaia": {"station": "SAWH", "temp_c": 3.2, "wind_kph": 58, "sky": "snow showers"},
}

ALERTS = {
    "litoral": [
        {"id": "AL-4471", "kind": "severe-thunderstorm", "valid_h": 6, "hail_mm": 20},
        {"id": "AL-4472", "kind": "wind", "gust_kph": 92, "valid_h": 3},
    ],
    "patagonia": [
        {"id": "AL-5108", "kind": "snow", "accum_cm": 25, "valid_h": 12},
    ],
}

TOOLS = [
    {
        "name": "get_forecast",
        "title": "Get forecast",
        "description": "Return the next 24 h forecast for a city from the station network.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "City name, e.g. Rosario"},
            },
            "required": ["city"],
            "additionalProperties": False,
        },
    },
    {
        "name": "summarize_alerts",
        "title": "Summarize alerts",
        "description": "Turn the raw alert records for a region into one paragraph, "
                       "using the host's model through sampling.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "region": {"type": "string", "enum": ["litoral", "patagonia"]},
            },
            "required": ["region"],
            "additionalProperties": False,
        },
    },
]

_seq = 100
_inbox = []
_stdin_buffer = b""


def next_id():
    """Ids the server itself originates, for server -> client requests."""
    global _seq
    _seq += 1
    return _seq


def log(message):
    # ----------------------------------------------------------- LAB-FAULT-1
    sys.stdout.write("[weather-mcp] %s\n" % message)
    sys.stdout.flush()
    # -------------------------------------------------------------------


def send(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def respond(request_id, result):
    # ----------------------------------------------------------- LAB-FAULT-2
    send({"jsonrpc": "2.0", "id": next_id(), "result": result})
    # -------------------------------------------------------------------


def respond_error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id,
          "error": {"code": code, "message": message}})


def read_line(timeout=None):
    """One line off fd 0. Returns "" on EOF, None on timeout.

    Framing is deliberately explicit here: a stdio transport is newline
    delimited, so the reader owns the buffer and never lets a second message
    hide inside a stale one.
    """
    global _stdin_buffer
    deadline = None if timeout is None else time.monotonic() + timeout
    while True:
        cut = _stdin_buffer.find(b"\n")
        if cut >= 0:
            line = _stdin_buffer[:cut]
            _stdin_buffer = _stdin_buffer[cut + 1:]
            return line.decode("utf-8", "replace")
        if deadline is None:
            wait = None
        else:
            wait = deadline - time.monotonic()
            if wait <= 0:
                return None
        ready, _, _ = select.select([0], [], [], wait)
        if not ready:
            return None
        chunk = os.read(0, 65536)
        if not chunk:
            if _stdin_buffer:
                line = _stdin_buffer.decode("utf-8", "replace")
                _stdin_buffer = b""
                return line
            return ""
        _stdin_buffer += chunk


def await_response(request_id, timeout=30.0):
    """Block until the client answers `request_id`; queue anything else.

    Helper for server-originated requests (sampling, roots/list, elicitation).
    A peer may interleave its own traffic with our answer, so correlation is
    by id, never by arrival order.
    """
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            log("timed out waiting for response to id=%s" % request_id)
            return None
        line = read_line(timeout=remaining)
        if line is None or line == "":
            return None
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if "method" not in message and message.get("id") == request_id:
            return message
        _inbox.append(message)


def handle_initialize(params):
    client = (params.get("clientInfo") or {}).get("name", "unknown")
    log("initialize from %s, protocolVersion=%s"
        % (client, params.get("protocolVersion")))
    return {
        "protocolVersion": PROTOCOL_VERSION,
        # ------------------------------------------------------- LAB-FAULT-3
        "capabilities": {},
        # ---------------------------------------------------------------
        "serverInfo": SERVER_INFO,
        "instructions": "Call get_forecast before answering any weather question; "
                        "never answer from the model's own recollection.",
    }


def call_get_forecast(arguments):
    city = str(arguments.get("city") or "").strip()
    data = FORECASTS.get(city.lower())
    if data is None:
        return {
            "content": [{"type": "text",
                         "text": "No station data for %r. Known: %s."
                                 % (city, ", ".join(sorted(FORECASTS)))}],
            "isError": True,
        }
    payload = dict(data, city=city)
    # ----------------------------------------------------------- LAB-FAULT-4
    return payload
    # -------------------------------------------------------------------


def request_summary(region, alerts):
    """Ask the host to run its model over data only the server has."""
    params = {
        "messages": [{
            "role": "user",
            "content": {
                "type": "text",
                "text": "Summarize these weather alerts for %s in one short "
                        "paragraph for a duty officer:\n%s"
                        % (region, json.dumps(alerts, indent=2)),
            },
        }],
        "systemPrompt": "You are a duty meteorologist. One paragraph, no preamble.",
        "includeContext": "thisServer",
        "maxTokens": 300,
        "modelPreferences": {
            "hints": [{"name": "claude-3-5-haiku"}],
            "speedPriority": 0.8,
            "intelligencePriority": 0.4,
        },
    }
    # ----------------------------------------------------------- LAB-FAULT-5
    send({"jsonrpc": "2.0", "method": "sampling/createMessage", "params": params})
    return "(no summary: the host never answered)"
    # -------------------------------------------------------------------


def call_summarize_alerts(arguments):
    region = str(arguments.get("region") or "litoral")
    alerts = ALERTS.get(region)
    if alerts is None:
        return {"content": [{"type": "text", "text": "Unknown region %r." % region}],
                "isError": True}
    text = request_summary(region, alerts)
    return {"content": [{"type": "text", "text": text}], "isError": False}


HANDLERS = {
    "get_forecast": call_get_forecast,
    "summarize_alerts": call_summarize_alerts,
}


def dispatch(message):
    method = message.get("method")
    if method is None:
        return  # a response nobody is waiting for
    message_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        respond(message_id, handle_initialize(params))
    elif method == "notifications/initialized":
        log("client completed the handshake; session is open")
    elif method == "ping":
        respond(message_id, {})
    elif method == "tools/list":
        log("tools/list -> %d tool(s)" % len(TOOLS))
        respond(message_id, {"tools": TOOLS})
    elif method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        handler = HANDLERS.get(name)
        log("tools/call name=%s arguments=%s" % (name, json.dumps(arguments)))
        if handler is None:
            respond_error(message_id, -32602, "unknown tool: %s" % name)
            return
        respond(message_id, handler(arguments))
    elif method.startswith("notifications/"):
        pass
    elif message_id is not None:
        respond_error(message_id, -32601, "method not found: %s" % method)


def main():
    log("starting, transport=stdio, pid=%d" % os.getpid())
    while True:
        while _inbox:
            dispatch(_inbox.pop(0))
        line = read_line()
        if line == "":
            log("stdin closed, shutting down")
            return 0
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            log("dropping non-JSON input: %.80r" % line)
            continue
        if isinstance(message, dict):
            dispatch(message)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
PY
    chmod +x "$SERVER_FILE"
}

# ---------------------------------------------------------------------------
# The probe: plays the host, walks the flow, names the first broken layer
# ---------------------------------------------------------------------------
write_probe() {
    cat > "$PROBE_FILE" <<'PY'
#!/usr/bin/env python3
"""flow_probe.py - walk the MCP model-interaction flow and name what breaks.

The probe plays the host. It owns the transport, the session and the model,
which is why it is also the peer that must answer sampling/createMessage.
It stops at the first stage that does not behave and prints the symptom, the
reason, and the condition that has to hold for that stage to pass.

exit 0  every stage passed
exit 1  a stage failed
exit 2  the probe could not run at all
"""

import json
import os
import select
import subprocess
import sys
import textwrap
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "weather_mcp.py")
STDERR_LOG = os.path.join(HERE, "server.stderr.log")
PROTOCOL_VERSION = "2025-06-18"
READ_TIMEOUT = 6.0
TTY = sys.stdout.isatty()


def paint(code, text):
    return "\033[%sm%s\033[0m" % (code, text) if TTY else text


def field(label, text):
    print(textwrap.fill(text, width=78,
                        initial_indent="  %-11s" % label,
                        subsequent_indent=" " * 13))


def stage(number, layer, criterion):
    print()
    print("  " + paint("1;36", "STAGE %d/5" % number) + "  " + paint("1;37", layer))
    print("             pass condition: %s" % criterion)


def passed(detail):
    print("  " + paint("1;32", "  ok     ") + "  " + detail)


def note(detail):
    print("             " + paint("0;90", detail))


def tail_log(limit=12):
    if not os.path.exists(STDERR_LOG):
        return []
    with open(STDERR_LOG, "r", errors="replace") as handle:
        lines = [line.rstrip("\n") for line in handle if line.strip()]
    return lines[-limit:]


def failed(number, layer, evidence, symptom, why, goal, spec):
    print()
    print("  " + paint("1;31", "  FAIL   ") + "  stage %d - %s" % (number, layer))
    print()
    for line in evidence:
        print("             " + paint("0;33", line))
    print()
    field("SYMPTOM", symptom)
    print()
    field("WHY", why)
    print()
    field("YOUR GOAL", goal)
    print()
    field("SPEC", spec)
    log_lines = tail_log()
    if log_lines:
        print()
        print("  server stderr (%s):" % STDERR_LOG)
        for line in log_lines:
            print("             " + paint("0;90", line))
    print()
    print("  Edit %s, then run the probe again." % SERVER)
    print()
    raise SystemExit(1)


class Flow(object):
    """One MCP session over stdio, driven from the host side."""

    MARKER = "[lab-stub-model]"

    def __init__(self):
        self.log_handle = open(STDERR_LOG, "wb")
        self.proc = subprocess.Popen(
            [sys.executable, "-u", SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log_handle,
            cwd=HERE,
        )
        self.fd = self.proc.stdout.fileno()
        self.buffer = b""
        self.eof = False
        self.counter = 0
        self.sampling = None      # None | "notification" | "request"
        self.trace = []

    # -- transport ---------------------------------------------------------
    def read_raw(self, deadline):
        while True:
            cut = self.buffer.find(b"\n")
            if cut >= 0:
                line = self.buffer[:cut]
                self.buffer = self.buffer[cut + 1:]
                text = line.decode("utf-8", "replace").strip()
                if not text:
                    continue
                return text
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                self.eof = True
                leftover = self.buffer.decode("utf-8", "replace").strip()
                self.buffer = b""
                return leftover or None
            self.buffer += chunk

    def send(self, payload):
        self.proc.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    # -- JSON-RPC ----------------------------------------------------------
    def request(self, method, params=None):
        self.counter += 1
        request_id = self.counter
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.trace.append("host   -> server  %-24s id=%s" % (method, request_id))
        self.send(message)
        return request_id, self.await_response(request_id)

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.trace.append("host   -> server  %-24s (notification)" % method)
        self.send(message)

    def await_response(self, request_id):
        deadline = time.monotonic() + READ_TIMEOUT
        while True:
            raw = self.read_raw(deadline)
            if raw is None:
                return {"kind": "eof" if self.eof else "timeout"}
            try:
                message = json.loads(raw)
            except ValueError:
                return {"kind": "garbage", "raw": raw}
            if not isinstance(message, dict):
                return {"kind": "garbage", "raw": raw}
            if "method" in message:
                self.handle_incoming(message)
                continue
            if message.get("id") != request_id:
                return {"kind": "mismatch", "sent": request_id,
                        "got": message.get("id"), "raw": raw}
            self.trace.append("host   <- server  %-24s id=%s"
                              % ("response", request_id))
            return {"kind": "response", "message": message}

    # -- server -> host direction -----------------------------------------
    def handle_incoming(self, message):
        method = message.get("method")
        message_id = message.get("id")
        if method == "sampling/createMessage":
            if message_id is None:
                self.sampling = "notification"
                self.trace.append("host   <- server  %-24s NO id - unanswerable"
                                  % "sampling/createMessage")
                return
            self.sampling = "request"
            self.trace.append("host   <- server  %-24s id=%s"
                              % ("sampling/createMessage", message_id))
            self.send({
                "jsonrpc": "2.0",
                "id": message_id,
                "result": {
                    "role": "assistant",
                    "content": {"type": "text",
                                "text": self.model_answer(message.get("params") or {})},
                    "model": "lab-stub-model",
                    "stopReason": "endTurn",
                },
            })
            self.trace.append("host   -> server  %-24s id=%s"
                              % ("CreateMessageResult", message_id))
            return
        if method == "ping" and message_id is not None:
            self.send({"jsonrpc": "2.0", "id": message_id, "result": {}})
            return
        self.trace.append("host   <- server  %-24s (ignored)" % method)

    def model_answer(self, params):
        blob = ""
        for entry in params.get("messages") or []:
            content = entry.get("content")
            if isinstance(content, dict):
                blob += content.get("text") or ""
        records = blob.count('"id"')
        return ("Stub summary of %d alert record(s): conditions are deteriorating; "
                "act on the highest-severity item first. %s" % (records, self.MARKER))

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=2)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        try:
            self.log_handle.close()
        except Exception:
            pass


SPEC_LIFECYCLE = "https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle"
SPEC_TRANSPORT = "https://modelcontextprotocol.io/specification/2025-06-18/basic/transports"
SPEC_TOOLS = "https://modelcontextprotocol.io/specification/2025-06-18/server/tools"
SPEC_SAMPLING = "https://modelcontextprotocol.io/specification/2025-06-18/client/sampling"


def run(flow):
    # ---------------------------------------------------------- stage 1 ---
    stage(1, "transport framing",
          "every line the server writes on stdout is one JSON-RPC message")
    _, outcome = flow.request("initialize", {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {"sampling": {}, "roots": {"listChanged": True}},
        "clientInfo": {"name": "flow-probe", "version": "1.0.0"},
    })

    if outcome["kind"] == "garbage":
        failed(1, "transport framing",
               ["first bytes read on the server's stdout:",
                "    %s" % outcome["raw"],
                "json.loads() on that line: ValueError"],
               "The session never starts. A real client shows 'server "
               "disconnected', 'failed to parse message' or 'MCP error -32700: "
               "parse error' the instant it launches the server, and the tools "
               "never appear in the model's tool list.",
               "In the stdio transport stdout is the wire. The server has "
               "written a human-readable diagnostic on it, so the very first "
               "thing the client parses is not JSON-RPC and the framing is "
               "lost before initialize is ever answered.",
               "Make stdout carry JSON-RPC messages and nothing else, one per "
               "line, no embedded newlines. The server may log all it wants, "
               "but to stderr (or to a file, or via notifications/message once "
               "the session is up). Look at the log function in weather_mcp.py.",
               SPEC_TRANSPORT)
    if outcome["kind"] == "eof":
        failed(1, "transport framing",
               ["the server closed stdout before answering initialize"],
               "The client reports the server exited immediately.",
               "The process died during startup; the stderr log below usually "
               "carries the traceback.",
               "Get the server to stay alive and answer initialize on stdout.",
               SPEC_TRANSPORT)
    passed("initialize was answered with a parseable JSON-RPC message")

    # ---------------------------------------------------------- stage 2 ---
    stage(2, "request / response correlation",
          "a response echoes the exact id of the request it answers")
    if outcome["kind"] == "mismatch":
        failed(2, "request / response correlation",
               ["sent:     {\"jsonrpc\": \"2.0\", \"id\": %s, \"method\": \"initialize\", ...}"
                % outcome["sent"],
                "received: %s" % outcome["raw"],
                "id sent = %s   id received = %s" % (outcome["sent"], outcome["got"])],
               "The handshake appears to hang: the server clearly replied, "
               "yet the client sits there until it times out and reports "
               "'initialize timed out' or 'request failed after 60000 ms'. "
               "Every later call would hang the same way.",
               "JSON-RPC 2.0 has no ordering guarantee: a peer may answer "
               "several in-flight requests out of order, so the id is the only "
               "thing that ties a response to its request. A response carrying "
               "a fresh server-side id matches no pending promise, so the "
               "client discards it and keeps waiting forever.",
               "Make every response echo the id of the request that caused it, "
               "unchanged and of the same JSON type. Ids the server originates "
               "belong only to requests the server itself sends (sampling, "
               "roots/list, elicitation). Only notifications have no id. Look "
               "at the respond function in weather_mcp.py.",
               SPEC_LIFECYCLE)
    if outcome["kind"] == "timeout":
        failed(2, "request / response correlation",
               ["no response to initialize within %.0f s" % READ_TIMEOUT],
               "The client hangs on startup and gives up.",
               "The server read the request but never wrote a response.",
               "Answer initialize, echoing the request id.",
               SPEC_LIFECYCLE)

    message = outcome["message"]
    if "error" in message:
        failed(2, "request / response correlation",
               ["initialize returned an error: %s" % json.dumps(message["error"])],
               "The client refuses to open the session.",
               "The server rejected the handshake.",
               "Accept the handshake and return an InitializeResult.",
               SPEC_LIFECYCLE)
    result = message.get("result")
    if not isinstance(result, dict):
        failed(2, "request / response correlation",
               ["response had no result object: %s" % json.dumps(message)],
               "The client cannot open the session.",
               "A JSON-RPC response must carry exactly one of result or error.",
               "Return an InitializeResult object in result.",
               SPEC_LIFECYCLE)
    passed("response id matched the request id")
    note("serverInfo: %s" % json.dumps(result.get("serverInfo")))
    if result.get("protocolVersion") != PROTOCOL_VERSION:
        note("warning: server negotiated protocolVersion=%r, host offered %r"
             % (result.get("protocolVersion"), PROTOCOL_VERSION))

    # ---------------------------------------------------------- stage 3 ---
    stage(3, "capability negotiation and discovery",
          "the server advertises tools, and tools/list returns usable definitions")
    capabilities = result.get("capabilities")
    if not isinstance(capabilities, dict) or "tools" not in capabilities:
        failed(3, "capability negotiation and discovery",
               ["InitializeResult.capabilities = %s" % json.dumps(capabilities),
                "expected a \"tools\" member, e.g. {\"tools\": {\"listChanged\": false}}"],
               "The worst symptom in this lab, because nothing looks broken: "
               "the server connects, the client shows it as healthy, and the "
               "model answers weather questions anyway - from its own training "
               "data, confidently, with invented temperatures. No tool is ever "
               "called and no error is ever printed.",
               "Capabilities are the contract negotiated during initialize. A "
               "conformant host only calls tools/list on a server that declared "
               "a tools capability, so an unadvertised tool is an absent tool: "
               "it never enters the tool list handed to the model, and the "
               "model cannot request what it cannot see.",
               "Advertise in the InitializeResult every capability the server "
               "actually implements, and only those. Look at handle_initialize "
               "in weather_mcp.py. Advertising a capability you do not "
               "implement is the mirror-image bug: it produces -32601 method "
               "not found at the first call.",
               SPEC_LIFECYCLE)
    passed("capabilities advertise tools: %s" % json.dumps(capabilities["tools"]))

    flow.notify("notifications/initialized")
    _, listing = flow.request("tools/list")
    if listing["kind"] != "response" or "result" not in listing.get("message", {}):
        failed(3, "capability negotiation and discovery",
               ["tools/list outcome: %s" % json.dumps(listing.get("raw", listing["kind"]))],
               "The client shows the server connected but with zero tools.",
               "tools/list did not return a ListToolsResult.",
               "Return {\"tools\": [...]} from tools/list.",
               SPEC_TOOLS)
    tools = listing["message"]["result"].get("tools")
    if not isinstance(tools, list) or not tools:
        failed(3, "capability negotiation and discovery",
               ["tools/list returned: %s" % json.dumps(listing["message"]["result"])],
               "The model has no tools attached and answers from memory.",
               "An empty tool list is a valid response, so nothing errors.",
               "Return the tool definitions from tools/list.",
               SPEC_TOOLS)
    for tool in tools:
        for key in ("name", "description", "inputSchema"):
            if key not in tool:
                failed(3, "capability negotiation and discovery",
                       ["tool %r has no %r" % (tool.get("name"), key)],
                       "The model either does not see the tool or calls it with "
                       "the wrong arguments.",
                       "name, description and inputSchema are what the host "
                       "turns into the tool definition the model is prompted with.",
                       "Give every tool a name, a description and a JSON Schema "
                       "inputSchema.",
                       SPEC_TOOLS)
    passed("%d tool(s) discovered: %s"
           % (len(tools), ", ".join(tool["name"] for tool in tools)))

    # ---------------------------------------------------------- stage 4 ---
    stage(4, "tool result -> model handoff",
          "CallToolResult carries a content array the host can hand back to the model")
    _, call = flow.request("tools/call",
                           {"name": "get_forecast", "arguments": {"city": "Rosario"}})
    if call["kind"] != "response":
        failed(4, "tool result -> model handoff",
               ["tools/call outcome: %s" % json.dumps(call.get("raw", call["kind"]))],
               "The tool call never returns.",
               "No CallToolResult arrived.",
               "Answer tools/call with a CallToolResult.",
               SPEC_TOOLS)
    if "error" in call["message"]:
        failed(4, "tool result -> model handoff",
               ["tools/call returned a protocol error: %s"
                % json.dumps(call["message"]["error"])],
               "The client shows a red protocol error and the turn aborts.",
               "A protocol-level error means the call could not be dispatched. "
               "A tool that ran and failed is a different thing: that is a "
               "normal result with isError true, which the model can read and "
               "recover from.",
               "Reserve JSON-RPC errors for protocol failures; report tool "
               "failures inside the result.",
               SPEC_TOOLS)
    payload = call["message"].get("result")
    content = payload.get("content") if isinstance(payload, dict) else None
    if not isinstance(content, list) or not content:
        failed(4, "tool result -> model handoff",
               ["result received for tools/call get_forecast:",
                "    %s" % json.dumps(payload),
                "expected: {\"content\": [{\"type\": \"text\", \"text\": \"...\"}], \"isError\": false}"],
               "The call is reported as successful and the model still says it "
               "could not get the forecast, or silently invents one. In a real "
               "client the tool-result block renders empty: a green check with "
               "nothing under it.",
               "The host does not forward the raw result object to the model. "
               "It converts content[] into the tool-result message of the "
               "conversation. A result without content[] converts to an empty "
               "message: the tool ran, the data existed, and none of it reached "
               "the model. This is the single most common MCP server bug.",
               "Return a CallToolResult: content[] with typed blocks (text, "
               "image, audio, resource_link, embedded resource), isError for a "
               "tool-level failure, and optionally structuredContent for the "
               "machine-readable copy. Look at call_get_forecast in "
               "weather_mcp.py.",
               SPEC_TOOLS)
    text_blocks = [block for block in content
                   if isinstance(block, dict) and block.get("type") == "text"]
    if not text_blocks:
        failed(4, "tool result -> model handoff",
               ["content[] has no block of type text: %s" % json.dumps(content)],
               "The model receives a tool result it cannot read.",
               "Every content block needs a type the host knows how to render.",
               "Include at least one text block.",
               SPEC_TOOLS)
    passed("CallToolResult carried %d content block(s), isError=%s"
           % (len(content), payload.get("isError", False)))
    note("text[0]: %s" % text_blocks[0]["text"].replace("\n", " ")[:68])
    if "structuredContent" in payload:
        note("structuredContent also present (machine-readable copy)")

    # ---------------------------------------------------------- stage 5 ---
    stage(5, "server-initiated model call (sampling)",
          "the server asks the host's model with a request, waits, and uses the answer")
    _, summary = flow.request("tools/call",
                              {"name": "summarize_alerts",
                               "arguments": {"region": "litoral"}})
    if summary["kind"] != "response":
        failed(5, "server-initiated model call (sampling)",
               ["tools/call summarize_alerts outcome: %s" % summary["kind"]],
               "The tool call hangs.",
               "The server most likely blocked waiting for a sampling response "
               "that it never made answerable.",
               "Send sampling/createMessage as a request with an id, and wait "
               "for the response that echoes it.",
               SPEC_SAMPLING)
    result_text = ""
    blocks = (summary["message"].get("result") or {}).get("content") or []
    for block in blocks:
        if isinstance(block, dict) and block.get("type") == "text":
            result_text += block.get("text") or ""

    if flow.sampling is None:
        failed(5, "server-initiated model call (sampling)",
               ["no sampling/createMessage was ever received by the host",
                "tool text: %s" % result_text[:70]],
               "summarize_alerts returns a placeholder instead of a summary.",
               "The server never used the reverse direction of the session, so "
               "no model was ever consulted.",
               "Have the tool ask the host for a completion through "
               "sampling/createMessage.",
               SPEC_SAMPLING)
    if flow.sampling == "notification":
        failed(5, "server-initiated model call (sampling)",
               ["the host received:",
                "    {\"jsonrpc\": \"2.0\", \"method\": \"sampling/createMessage\", \"params\": {...}}",
                "with no \"id\" member - that is a notification, not a request",
                "tool text returned to the model: %s" % result_text[:70]],
               "The tool answers instantly with '(no summary: the host never "
               "answered)'. Nothing errors, no client log line appears, and the "
               "model happily relays the placeholder to the student as if it "
               "were the report.",
               "MCP runs bidirectionally over one session: the server is also a "
               "JSON-RPC client. A notification is fire-and-forget and by "
               "definition cannot be answered, so the host has nowhere to send "
               "the completion back to. The server then builds its "
               "CallToolResult from a value it never received.",
               "Send sampling/createMessage as a request: give it a "
               "server-originated id, keep reading the transport until the "
               "response with that id arrives (queuing anything else that "
               "shows up meanwhile), and build the tool result from "
               "result.content.text. Handle the refusal too: the host is "
               "allowed to deny or modify a sampling request, that is the "
               "human-in-the-loop guarantee. Look at request_summary and the "
               "await_response helper in weather_mcp.py.",
               SPEC_SAMPLING)
    if Flow.MARKER not in result_text:
        failed(5, "server-initiated model call (sampling)",
               ["the host answered sampling/createMessage, but its text never "
                "came back in the tool result",
                "tool text: %s" % result_text[:70]],
               "The summary the student reads is not the one the model produced.",
               "The server asked, got an answer, and then dropped it.",
               "Read result.content.text out of the CreateMessageResult and put "
               "it in the CallToolResult content[].",
               SPEC_SAMPLING)
    passed("sampling round trip closed; the model's text reached the tool result")
    note(result_text.replace("\n", " ")[:72])

    print()
    print("  " + paint("1;32", "ALL FIVE STAGES PASSED") + " - the model interaction flow is intact.")
    print()
    print("  observed sequence:")
    for line in flow.trace:
        print("    " + paint("0;90", line))
    print()


def main():
    if not os.path.exists(SERVER):
        print("probe: %s is missing; run the lab script again" % SERVER)
        return 2
    print()
    print("  " + paint("1;37", "MCP model-interaction flow probe") + "   (host side)")
    print("  server under test: %s" % SERVER)
    flow = Flow()
    try:
        run(flow)
    finally:
        flow.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
    chmod +x "$PROBE_FILE"
}

write_lab() {
    mkdir -p "$LAB_DIR"
    write_server
    write_probe
    : > "$LAB_DIR/server.stderr.log"
    cat > "$MARKER" <<EOF
mcpa topic 2.3 - model interaction flow - break & fix lab
created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
}

briefing() {
    cat <<EOF

${B}=========================================================================${N}
${B} MCPA 2.3 - Model Interaction Flow : break & fix${N}
${B}=========================================================================${N}

${C}The scenario${N}
  weather-mcp is an MCP server that a study platform exposes to its tutor
  agent over stdio. It worked last week. After a refactor the students report
  that the assistant "answers weather questions but the numbers are made up",
  and the on-call engineer reports that the server "connects fine".

  The server has been damaged in ${B}five${N} places, one per layer of the model
  interaction flow, from the wire up to the reverse direction of the session:

      1  transport framing        stdout must be JSON-RPC, nothing else
      2  request / response       correlation is by id, not by arrival order
      3  capability negotiation   an unadvertised tool is an absent tool
      4  tool result -> model     content[] is what reaches the model
      5  server-initiated model   sampling is a request, not a notification

  All five faults are inside a single file, ${B}weather_mcp.py${N}, each one or two
  lines long, each marked with a ${B}LAB-FAULT-n${N} comment. The probe is your
  oracle: it plays the host, walks the flow in order, and stops at the first
  layer that misbehaves.

${C}What you will see${N}
  Run the probe now and stage 1 fails immediately: the first thing the client
  reads on the server's stdout is not JSON. Fix that, run it again, and the
  next layer's symptom appears. Symptoms get quieter as you climb - the last
  two produce no error at all, only wrong material in front of a student.

${C}What you must achieve${N}
  ${B}$SELF probe${N} exits 0 with all five stages green,
  without changing flow_probe.py and without rewriting the server: every fix
  is a local edit at a LAB-FAULT marker.

${C}Files${N}
  server under test   $SERVER_FILE
  probe (do not edit) $PROBE_FILE
  server stderr       $LAB_DIR/server.stderr.log

${C}Commands${N}
  $SELF probe     run the probe
  $SELF hint      the five layers, no answers
  $SELF reset     restore the broken build (destroys your edits)
  $SELF clean     delete $LAB_DIR

EOF
}

hints() {
    cat <<EOF

${B}Hints - the five layers, in flow order. No answers here.${N}

  ${C}1  transport framing${N}
     A stdio MCP server has exactly one thing it may put on stdout. Anything
     else on that stream is not a log line, it is corruption of the wire.
     https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

  ${C}2  request / response correlation${N}
     JSON-RPC 2.0 permits out-of-order answers. Ask what, then, lets a client
     match an answer to the question it asked - and which messages are
     allowed to have no id at all.
     https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle

  ${C}3  capability negotiation${N}
     Read the InitializeResult the server sends and ask what a conformant host
     is permitted to call next, given only that document.
     https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle

  ${C}4  tool result -> model handoff${N}
     The host does not hand the model your result object. Find, in the tools
     specification, the exact shape it does convert into a tool-result
     message, and which member is mandatory.
     https://modelcontextprotocol.io/specification/2025-06-18/server/tools

  ${C}5  server-initiated model call${N}
     On one MCP session both peers may originate requests. A message with no
     id cannot be answered. Trace where the summary text is supposed to come
     from, and whether anything could ever deliver it.
     https://modelcontextprotocol.io/specification/2025-06-18/client/sampling

EOF
}

run_probe() {
    [ -f "$PROBE_FILE" ] || die "no lab at $LAB_DIR - run '$SELF' first"
    set +e
    python3 "$PROBE_FILE"
    status=$?
    set -e
    return $status
}

case "${1:-break}" in
    break|setup|"")
        check_python
        if [ -f "$MARKER" ]; then
            printf '%s\n' "${Y}note:${N} a lab already exists at $LAB_DIR; leaving your edits alone."
            printf '%s\n' "      use '$SELF reset' to restore the broken build."
        else
            confirm_disposable_vm
            write_lab
        fi
        briefing
        printf '%s\n' "${B}Running the probe once, so you can see the first symptom:${N}"
        run_probe || true
        ;;
    probe|verify|check)
        check_python
        run_probe
        ;;
    hint|hints)
        hints
        ;;
    reset|rebreak)
        check_python
        [ -f "$MARKER" ] || die "no lab at $LAB_DIR - run '$SELF' first"
        if [ "${MCP_LAB_CONFIRM:-}" != "yes" ]; then
            [ -t 0 ] || die "refusing to overwrite your edits non-interactively"
            printf 'This overwrites %s and discards your fixes.\nType RESET to continue: ' "$SERVER_FILE"
            read -r reply
            [ "$reply" = "RESET" ] || { echo "aborted."; exit 2; }
        fi
        write_lab
        printf '%s\n' "${G}lab restored to the broken build.${N}"
        ;;
    clean|destroy)
        if [ ! -f "$MARKER" ]; then
            printf '%s\n' "nothing to clean: $LAB_DIR is not a lab created by this script."
            exit 0
        fi
        if [ "${MCP_LAB_CONFIRM:-}" != "yes" ]; then
            [ -t 0 ] || die "refusing to delete non-interactively"
            printf 'Delete %s and everything in it?\nType CLEAN to continue: ' "$LAB_DIR"
            read -r reply
            [ "$reply" = "CLEAN" ] || { echo "aborted."; exit 2; }
        fi
        rm -rf -- "$LAB_DIR"
        printf '%s\n' "${G}removed $LAB_DIR${N}"
        ;;
    *)
        cat <<EOF
usage: $SELF [break|probe|hint|reset|clean]

  break   write the lab, break it, show the first symptom (default)
  probe   run the probe; exits 0 only when all five stages pass
  hint    the five layers of the flow, without the answers
  reset   restore the broken build (destroys your edits)
  clean   delete $LAB_DIR
EOF
        exit 2
        ;;
esac

# ===========================================================================
#  S O L U T I O N   -   stop here if you have not finished the lab
# ===========================================================================
#
#  All five edits are in weather_mcp.py, at the LAB-FAULT-n markers. Nothing
#  in flow_probe.py needs to change. After each edit, run:
#
#      ./mcpa-2.3-break-fix.sh probe
#
#  and confirm that exactly one more stage turns green. Fixing them in flow
#  order is the point of the exercise: a lower layer that lies makes every
#  diagnosis above it worthless.
#
# ---------------------------------------------------------------------------
#  FIX 1  -  LAB-FAULT-1, function log()   [stage 1, transport framing]
# ---------------------------------------------------------------------------
#
#  Replace:
#
#      def log(message):
#          sys.stdout.write("[weather-mcp] %s\n" % message)
#          sys.stdout.flush()
#
#  with:
#
#      def log(message):
#          sys.stderr.write("[weather-mcp] %s\n" % message)
#          sys.stderr.flush()
#
#  Why: in the stdio transport, the server's stdout IS the JSON-RPC wire and
#  the client's stdin IS its receive buffer. Messages are newline delimited,
#  so the client splits on "\n" and parses each piece. One print() of a banner
#  and the first "message" the client parses is
#  "[weather-mcp] starting, transport=stdio, pid=1234" - a parse error before
#  initialize is even answered. The spec is explicit: the server MUST NOT
#  write anything to stdout that is not a valid MCP message, and MAY write
#  UTF-8 logs to stderr. This is why print() debugging is the classic way to
#  destroy a working stdio server - and why the equivalent bug does not exist
#  over Streamable HTTP, where the transport frames for you.
#
#  Once the session is up there is also a protocol-native channel for logs:
#  declare a "logging" capability and emit notifications/message. Do not
#  declare it here - see fix 3 for why advertising what you do not implement
#  is its own bug.
#
#  Verify: stage 1 passes, stage 2 now fails.
#          tail -f ~/mcp-flow-lab/server.stderr.log  is now useful.
#
# ---------------------------------------------------------------------------
#  FIX 2  -  LAB-FAULT-2, function respond()   [stage 2, correlation]
# ---------------------------------------------------------------------------
#
#  Replace:
#
#      def respond(request_id, result):
#          send({"jsonrpc": "2.0", "id": next_id(), "result": result})
#
#  with:
#
#      def respond(request_id, result):
#          send({"jsonrpc": "2.0", "id": request_id, "result": result})
#
#  Why: JSON-RPC 2.0 gives no ordering guarantee, and MCP leans on that - a
#  host may have several requests in flight on one session. The id is the only
#  link between a response and its request; the client keeps a map from id to
#  pending promise. A response carrying a freshly minted server-side id
#  resolves nothing, so the client drops it and the call times out. Note the
#  shape of the failure: the server looks healthy (it answered, promptly, with
#  correct data) while the client reports a timeout. Whenever those two
#  accounts disagree, suspect correlation.
#
#  Three rules fall out of this, all exam-relevant:
#    - a response echoes the request id unchanged, including its JSON type:
#      id 7 and id "7" are different ids;
#    - the id must be unique per sender per session, and MUST NOT be null;
#    - ids the server generates itself belong to requests the SERVER sends -
#      sampling/createMessage, roots/list, elicitation/create - which is
#      exactly what next_id() is for, and what fix 5 uses it for;
#    - notifications (initialized, cancelled, progress, resources/updated)
#      carry no id at all, and MUST NOT be answered.
#
#  Verify: stage 2 passes, stage 3 now fails.
#
# ---------------------------------------------------------------------------
#  FIX 3  -  LAB-FAULT-3, handle_initialize()   [stage 3, capabilities]
# ---------------------------------------------------------------------------
#
#  Replace:
#
#      "capabilities": {},
#
#  with:
#
#      "capabilities": {"tools": {"listChanged": False}},
#
#  Why: initialize is a negotiation, not a greeting. Each side declares what
#  it supports, and the rest of the session is bounded by that declaration. A
#  conformant host only calls tools/list on a server that advertised a tools
#  capability, so an unadvertised tool never enters the tool list attached to
#  the model's context - and a model cannot call what it cannot see. The
#  student then gets a fluent, confident, entirely invented forecast, with no
#  error anywhere in the stack. This is the quietest failure in the lab and
#  the one worth remembering: "the server connects fine" is not evidence that
#  the model can use it.
#
#  listChanged: False is an honest declaration - this server's tool list is
#  static, so it will never emit notifications/tools/list_changed. Set it True
#  only if you actually send that notification. The mirror-image bug is just
#  as real: advertise {"resources": {}} without implementing resources/list
#  and the first call comes back -32601 method not found.
#
#  Also note what the server returns alongside: "instructions". The host is
#  free to place that text in the model's system prompt, which is how a server
#  influences when its tools get used ("call get_forecast before answering any
#  weather question"). Tool descriptions and instructions are prompt surface,
#  not documentation - untrusted servers reach the model through them, which
#  is why hosts are expected to show the user what a server exposes.
#
#  Verify: stage 3 passes (two tools discovered), stage 4 now fails.
#
# ---------------------------------------------------------------------------
#  FIX 4  -  LAB-FAULT-4, call_get_forecast()   [stage 4, result -> model]
# ---------------------------------------------------------------------------
#
#  Replace:
#
#      payload = dict(data, city=city)
#      return payload
#
#  with:
#
#      payload = dict(data, city=city)
#      return {
#          "content": [{"type": "text", "text": json.dumps(payload, indent=2)}],
#          "structuredContent": payload,
#          "isError": False,
#      }
#
#  Why: the host does not forward your result object to the model. It takes
#  CallToolResult.content[] and converts it into the tool-result message of
#  the conversation. Any member outside content[] that the host does not know
#  about is dropped on that path. Returning {"station": "SAAR", ...} therefore
#  produces a successful call whose tool-result message is empty: the tool
#  ran, the data existed, the model received nothing, and - having been told
#  a tool was called - it fills the gap. This single mistake accounts for most
#  "the tool works but the model ignores it" reports.
#
#  The pieces of a CallToolResult:
#    content[]          required; typed blocks: text, image, audio,
#                       resource_link, resource. This is what the model reads.
#    structuredContent  optional; the machine-readable copy for the host. If
#                       the tool declares an outputSchema, this member becomes
#                       required and must validate against it - and servers
#                       SHOULD also mirror it as text in content[] for
#                       backward compatibility, which is what we do above.
#    isError            false, or true for a tool-level failure.
#
#  Keep the two kinds of failure apart, because they flow to different places:
#    - unknown city, API down, bad argument -> a normal response with
#      isError: true and the reason in content[]. It reaches the MODEL, which
#      can read it and retry with a different city. That is the whole point.
#    - unknown tool, malformed params, server exploded -> a JSON-RPC error
#      object. It reaches the HOST, aborts the call, and the model gets a
#      protocol failure it cannot reason about.
#  The already-correct "No station data" branch above the fault is the first
#  kind; compare the two shapes side by side in the file.
#
#  Verify: stage 4 passes, stage 5 now fails.
#
# ---------------------------------------------------------------------------
#  FIX 5  -  LAB-FAULT-5, request_summary()   [stage 5, sampling]
# ---------------------------------------------------------------------------
#
#  Replace:
#
#      send({"jsonrpc": "2.0", "method": "sampling/createMessage", "params": params})
#      return "(no summary: the host never answered)"
#
#  with:
#
#      request_id = next_id()
#      send({"jsonrpc": "2.0", "id": request_id,
#            "method": "sampling/createMessage", "params": params})
#      reply = await_response(request_id, timeout=30.0)
#      if reply is None:
#          return "(no summary: the host did not answer in time)"
#      if "error" in reply:
#          return "(no summary: the host declined the sampling request: %s)" \
#                 % reply["error"].get("message", "no reason given")
#      content = (reply.get("result") or {}).get("content") or {}
#      return content.get("text") or "(the host returned an empty message)"
#
#  Why: MCP is bidirectional over a single session. The server is a JSON-RPC
#  server for tools/resources/prompts and simultaneously a JSON-RPC client for
#  sampling, roots and elicitation. Sampling is how a server borrows the
#  host's model without owning an API key, a bill, or a model choice - the
#  host keeps all three, plus the human in the loop.
#
#  A message without an id is a notification: fire-and-forget, unanswerable by
#  definition. The host receives it, has nowhere to send a completion back to,
#  and drops it; the server meanwhile builds a CallToolResult out of a value
#  that was never going to arrive. Nothing errors, and a placeholder string is
#  delivered to the student as if it were the report. Same class of bug as
#  fix 3: silence where you wanted an answer.
#
#  What the corrected version demonstrates:
#    - next_id() gives the request an id in the server's OWN id space. Both
#      peers number independently; ids only need to be unique per sender.
#    - await_response() keeps reading the transport until the response with
#      that id arrives and queues anything else in _inbox for the main loop.
#      You cannot assume the next line is your answer: the host may send a
#      notifications/cancelled, a ping, or another tools/call while you wait.
#    - the timeout is mandatory in practice. The host may sit on the request
#      for as long as a human takes to approve it.
#    - the error branch is not decoration. The host is allowed to reject or
#      modify a sampling request - that is the human-in-the-loop guarantee
#      the specification asks for, and a server that treats refusal as an
#      impossible case will hang or lie.
#    - modelPreferences (hints, speedPriority, intelligencePriority) is a
#      request, not a command: the host chooses the model. A server never
#      names the model it will get.
#
#  Verify: all five stages pass, exit 0, and the probe prints the full
#  observed sequence - including the direction reversal in the middle, which
#  is the shape of the model interaction flow you are being examined on.
#
# ---------------------------------------------------------------------------
#  What to take to the exam
# ---------------------------------------------------------------------------
#
#    layer          the invariant                      symptom when broken
#    -----------    -------------------------------    ---------------------
#    transport      stdout is the wire; logs to        parse error, server
#                   stderr                             "disconnected"
#    JSON-RPC       responses echo the request id;     client hangs while the
#                   notifications have none            server looks healthy
#    lifecycle      capabilities bound the session     tools silently absent;
#                                                      model invents answers
#    tools          content[] is what reaches the      empty tool result;
#                   model; isError is model-facing     model fills the gap
#    sampling       server -> client model calls are   placeholder text
#                   requests, and may be refused       served as fact
#
#  The two loud failures are at the bottom of the stack and the two dangerous
#  ones are at the top: as you climb the flow, a broken layer stops producing
#  errors and starts producing plausible content. That asymmetry - not the
#  message formats - is what makes this topic worth its weight on the exam.
#
#  Sources
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    https://modelcontextprotocol.io/specification/2025-06-18/client/sampling
# ===========================================================================