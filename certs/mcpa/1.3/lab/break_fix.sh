#!/usr/bin/env bash
#
# ============================================================================
#  BREAK & FIX LAB — MCPA (Model Context Protocol Associate), exam 2026-07-28
#  Domain 1, Topic 1.3: Interoperability & Value   (exam weight 5.33%)
# ============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  MCP's entire value proposition is arithmetic: M hosts x N servers becomes
#  M + N integrations, but ONLY at the point of conformance. A server that is
#  "95% conformant" is 0% interoperable with any client that validates instead
#  of guessing. This lab ships one MCP server and two clients — an in-house
#  tolerant one that papers over protocol violations, and a spec-conformant
#  probe that does not — then breaks the server's contract in four realistic
#  ways. The in-house client keeps working. Every other client on earth stops.
#
#  REFERENCES (official)
#    - https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    - https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    - https://www.jsonrpc.org/specification
#
#  BLAST RADIUS
#  ------------
#  Everything happens inside one directory (default: $HOME/mcp-interop-lab).
#  No root, no package installs, no systemd units, no network, no changes to
#  anything outside that directory. Still: run it on a disposable lab VM.
#  Requires python3 (>= 3.8) and nothing else.
#
#  USAGE
#    ./break-fix-mcpa-1.3.sh            # set up, prove it green, then break it
#    ./break-fix-mcpa-1.3.sh verify     # grade your fix
#    ./break-fix-mcpa-1.3.sh hint [1-3] # progressive hints
#    ./break-fix-mcpa-1.3.sh reset      # re-break from scratch (discards edits)
#    ./break-fix-mcpa-1.3.sh clean      # delete the lab directory
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there first.
# ============================================================================

set -euo pipefail

LAB_DIR="${MCP_LAB_DIR:-$HOME/mcp-interop-lab}"
MARKER="$LAB_DIR/.mcp-lab-marker"
SERVER="$LAB_DIR/server.py"
PROBE="$LAB_DIR/mcp_probe.py"
VENDOR="$LAB_DIR/vendor_client.py"
SUMS="$LAB_DIR/.client-checksums"

if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; Z=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; Z=""
fi

die() { printf '%s\n' "${R}error:${Z} $*" >&2; exit 1; }
rule() { printf '%s\n' "${C}------------------------------------------------------------------------${Z}"; }
sha() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

preflight() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found in PATH."
  python3 - <<'PY' || die "python3 3.8 or newer is required."
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PY
  if [ -e "$LAB_DIR" ] && [ ! -e "$MARKER" ]; then
    die "$LAB_DIR already exists and is not a lab directory created by this script. Refusing to touch it. Set MCP_LAB_DIR to a free path."
  fi
}

confirm_lab_vm() {
  [ "${ASSUME_LAB:-0}" = "1" ] && return 0
  if [ ! -t 0 ]; then
    die "Non-interactive shell. Re-run with ASSUME_LAB=1 if this really is a disposable lab VM."
  fi
  printf '%s\n' "${Y}This lab writes only inside:${Z} $LAB_DIR"
  printf '%s\n' "${Y}It installs nothing, needs no root, and touches no service.${Z}"
  read -r -p "Proceed on this machine? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) printf '%s\n' "Aborted, nothing written."; exit 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Lab assets
# ---------------------------------------------------------------------------

write_server() {
  cat > "$SERVER" <<'PY'
#!/usr/bin/env python3
"""mcp-lab-server: a minimal MCP server on the stdio transport.

Contract, in three lines:
  * stdout carries JSON-RPC 2.0 messages and nothing else, one per line,
    no embedded newlines;
  * diagnostics go to stderr;
  * the lifecycle is initialize -> notifications/initialized -> normal use.

Spec: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
"""

import json
import sys

SERVER_NAME = "mcp-lab-server"
SERVER_VERSION = "1.4.0"
SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]
PREFERRED_PROTOCOL_VERSION = "2025-06-18"

TOOLS = [
    {
        "name": "convert_temperature",
        "description": "Convert a temperature between Celsius and Fahrenheit.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "value": {"type": "number", "description": "Numeric temperature."},
                "from_unit": {"type": "string", "enum": ["C", "F"]},
                "to_unit": {"type": "string", "enum": ["C", "F"]},
            },
            "required": ["value", "from_unit", "to_unit"],
        },
    }
]


def log(text: str) -> None:
    """Diagnostics belong on stderr. stdout is the wire."""
    print("[" + SERVER_NAME + "] " + text, file=sys.stderr, flush=True)


def send(message: dict) -> None:
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(req_id, result: dict) -> None:
    send({"jsonrpc": "2.0", "id": req_id, "result": result})


def respond_error(req_id, code: int, message: str) -> None:
    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def negotiate(requested: str) -> str:
    """Echo the client's version when we speak it, else offer our preferred one."""
    if requested in SUPPORTED_PROTOCOL_VERSIONS:
        return requested
    return PREFERRED_PROTOCOL_VERSION


def handle_initialize(req_id, params: dict) -> None:
    requested = params.get("protocolVersion", "")
    agreed = negotiate(requested)
    log("initialize: client asked " + repr(requested) + ", agreed " + repr(agreed))
    respond(req_id, {
        "protocolVersion": agreed,
        "capabilities": {"tools": {"listChanged": False}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        "instructions": "Temperature helper for the MCPA interoperability lab.",
    })


def handle_tools_list(req_id, _params: dict) -> None:
    respond(req_id, {"tools": TOOLS})


def convert(value: float, from_unit: str, to_unit: str) -> float:
    if from_unit == to_unit:
        return value
    if from_unit == "C" and to_unit == "F":
        return value * 9.0 / 5.0 + 32.0
    if from_unit == "F" and to_unit == "C":
        return (value - 32.0) * 5.0 / 9.0
    raise ValueError("unsupported conversion " + from_unit + " -> " + to_unit)


def handle_tools_call(req_id, params: dict) -> None:
    name = params.get("name")
    args = params.get("arguments") or {}
    if name != "convert_temperature":
        respond_error(req_id, -32602, "Unknown tool: " + str(name))
        return
    try:
        value = float(args["value"])
        from_unit = str(args["from_unit"]).upper()
        to_unit = str(args["to_unit"]).upper()
        result = convert(value, from_unit, to_unit)
    except (KeyError, TypeError, ValueError) as exc:
        # A tool that fails reports it INSIDE the result, so the model can see it.
        respond(req_id, {
            "content": [{"type": "text", "text": "invalid arguments: " + str(exc)}],
            "isError": True,
        })
        return
    log("tools/call convert_temperature -> ok")
    respond(req_id, {
        "content": [{"type": "text", "text": "%g %s = %g %s" % (value, from_unit, result, to_unit)}],
        "isError": False,
    })


def main() -> None:
    log("listening on stdio")
    while True:
        line = sys.stdin.readline()
        if line == "":
            log("client closed stdin, exiting")
            return
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log("dropping unparsable line from client")
            continue
        method = msg.get("method")
        req_id = msg.get("id")
        if req_id is None:
            log("notification: " + str(method))
            continue
        if method == "initialize":
            handle_initialize(req_id, msg.get("params") or {})
        elif method == "tools/list":
            handle_tools_list(req_id, msg.get("params") or {})
        elif method == "tools/call":
            handle_tools_call(req_id, msg.get("params") or {})
        elif method == "ping":
            respond(req_id, {})
        else:
            respond_error(req_id, -32601, "Method not found: " + str(method))


if __name__ == "__main__":
    main()
PY
}

write_probe() {
  cat > "$PROBE" <<'PY'
#!/usr/bin/env python3
"""mcp-probe: a spec-conformant MCP client. It validates instead of guessing.

This stands in for every real MCP host (Claude Desktop, IDE agents, gateways).
It runs the documented lifecycle and asserts the documented shapes. Nine checks,
fail-fast: fix one, the next one surfaces.

DO NOT EDIT THIS FILE. The grader checksums it.
"""

import json
import os
import select
import subprocess
import sys
import time

CLIENT_PROTOCOL_VERSION = "2025-06-18"
CLIENT_SUPPORTED = ("2025-06-18", "2025-03-26", "2024-11-05")
TOTAL = 9
TIMEOUT = 8.0


class ProbeFailure(Exception):
    pass


def ok(num, text):
    print("  [ OK ]  %d/%d  %s" % (num, TOTAL, text))


def fail(num, text, observed, expected, ref, note=None):
    print("  [FAIL]  %d/%d  %s" % (num, TOTAL, text))
    print("          observed: %s" % observed)
    print("          expected: %s" % expected)
    if note:
        print("          note:     %s" % note)
    print("          spec:     %s" % ref)
    raise ProbeFailure()


def start_server(cmd, log_path):
    errlog = open(log_path, "wb")
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errlog, bufsize=0
    )
    return proc, errlog


def send(proc, message):
    proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
    proc.stdin.flush()


def read_line(proc, phase):
    """Read one newline-terminated line from stdout, or explain why we could not."""
    deadline = time.monotonic() + TIMEOUT
    buf = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail(1, "transport framing: no complete message arrived",
                 "nothing newline-terminated within %.0fs while %s; partial bytes: %r"
                 % (TIMEOUT, phase, bytes(buf)[:120]),
                 "one JSON-RPC message per line, terminated by \\n",
                 "https://modelcontextprotocol.io/specification/2025-06-18/basic/transports")
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            continue
        chunk = proc.stdout.read(1)
        if chunk == b"":
            fail(1, "transport framing: the server closed stdout",
                 "EOF while %s (check the stderr log for a traceback)" % phase,
                 "the server stays alive for the whole session",
                 "https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle")
        if chunk == b"\n":
            return bytes(buf)
        buf += chunk


def read_message(proc, phase):
    raw = read_line(proc, phase)
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        fail(1, "transport framing: stdout carried something that is not a message",
             "%r  (%s)" % (raw[:120], exc),
             "every single line on stdout parses as a JSON-RPC 2.0 message",
             "https://modelcontextprotocol.io/specification/2025-06-18/basic/transports",
             "seen while %s. The rule holds for the entire life of the process, "
             "not just at startup. Logging goes to stderr." % phase)


def expect_response(proc, req_id, num, label, phase):
    msg = read_message(proc, phase)
    if msg.get("jsonrpc") != "2.0":
        fail(num, label, "jsonrpc=%r" % msg.get("jsonrpc"), 'jsonrpc="2.0"',
             "https://www.jsonrpc.org/specification")
    if msg.get("id") != req_id:
        fail(num, label, "id=%r" % msg.get("id"), "id=%r (the id we sent)" % req_id,
             "https://www.jsonrpc.org/specification",
             "a response id that does not match usually means the server answered a "
             "notification, which it must never do.")
    return msg


def run_checks(proc):
    # --- lifecycle: initialize -------------------------------------------------
    send(proc, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": CLIENT_PROTOCOL_VERSION,
            "capabilities": {"roots": {"listChanged": True}},
            "clientInfo": {"name": "mcp-probe", "version": "1.0.0"},
        },
    })
    msg = read_message(proc, "waiting for the initialize response")
    ok(1, "transport framing: stdout carried a JSON-RPC message, nothing else")

    if msg.get("jsonrpc") != "2.0" or msg.get("id") != 1:
        fail(2, "JSON-RPC envelope on the initialize response",
             "jsonrpc=%r id=%r" % (msg.get("jsonrpc"), msg.get("id")),
             'jsonrpc="2.0" and id=1',
             "https://www.jsonrpc.org/specification")
    if "error" in msg:
        fail(2, "initialize was refused", json.dumps(msg["error"]),
             "a result object",
             "https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle")
    result = msg.get("result")
    if not isinstance(result, dict):
        fail(2, "initialize result", repr(result), "an object",
             "https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle")
    ok(2, "JSON-RPC 2.0 envelope: version and correlated id are right")

    version = result.get("protocolVersion")
    if version not in CLIENT_SUPPORTED:
        fail(3, "version negotiation", "server offered protocolVersion=%r" % version,
             "one of %s" % (", ".join(CLIENT_SUPPORTED)),
             "https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle",
             "MCP protocol versions are dates (YYYY-MM-DD), not semver. A conformant "
             "client MUST disconnect when the offered version is one it cannot speak, "
             "which is exactly what this probe is about to do.")
    ok(3, "version negotiation: agreed on protocol %s" % version)

    caps = result.get("capabilities")
    if not isinstance(caps, dict) or not isinstance(caps.get("tools"), dict):
        fail(4, "capability negotiation", "capabilities=%s" % json.dumps(caps),
             'capabilities.tools present, e.g. {"tools": {"listChanged": false}}',
             "https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle",
             "a client that does not see the tools capability will never call tools/list.")
    ok(4, "capability negotiation: the server declares the tools capability")

    info = result.get("serverInfo")
    if not isinstance(info, dict) or not info.get("name") or not info.get("version"):
        fail(5, "server identity", "serverInfo=%s" % json.dumps(info),
             "serverInfo with a non-empty name and version",
             "https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle")
    ok(5, "server identity: %s %s" % (info["name"], info["version"]))

    send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

    # --- discovery -------------------------------------------------------------
    send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    msg = expect_response(proc, 2, 6, "tools/list response envelope",
                          "waiting for the tools/list response")
    tools = (msg.get("result") or {}).get("tools")
    if not isinstance(tools, list) or not tools:
        fail(6, "tool discovery", "tools=%s" % json.dumps(tools),
             "a non-empty array of tool descriptors",
             "https://modelcontextprotocol.io/specification/2025-06-18/server/tools")
    for tool in tools:
        name = tool.get("name")
        if not name:
            fail(6, "tool discovery", json.dumps(tool), "every tool has a name",
                 "https://modelcontextprotocol.io/specification/2025-06-18/server/tools")
        if not tool.get("description"):
            fail(6, "tool discovery: tool %r has no description" % name,
                 "keys present: %s" % ", ".join(sorted(tool)),
                 "a human-readable description",
                 "https://modelcontextprotocol.io/specification/2025-06-18/server/tools",
                 "the description is what the model reads to decide whether to call it. "
                 "No description means the tool is effectively invisible.")
        schema = tool.get("inputSchema")
        if not isinstance(schema, dict) or schema.get("type") != "object":
            fail(6, "tool discovery: tool %r has no usable inputSchema" % name,
                 "keys present: %s" % ", ".join(sorted(tool)),
                 'inputSchema: a JSON Schema object with "type": "object"',
                 "https://modelcontextprotocol.io/specification/2025-06-18/server/tools",
                 "the key is inputSchema. A schema under any other key does not exist "
                 "as far as a conformant client is concerned.")
    ok(6, "tool discovery: %d tool(s), each with name, description and inputSchema"
       % len(tools))

    # --- invocation ------------------------------------------------------------
    send(proc, {
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {
            "name": "convert_temperature",
            "arguments": {"value": 100, "from_unit": "C", "to_unit": "F"},
        },
    })
    msg = expect_response(proc, 3, 7, "tools/call response envelope",
                          "waiting for the tools/call response")
    result = msg.get("result")
    if not isinstance(result, dict):
        fail(7, "tool result shape", repr(result), "a result object",
             "https://modelcontextprotocol.io/specification/2025-06-18/server/tools")
    content = result.get("content")
    if not isinstance(content, list) or not content:
        fail(7, "tool result shape", "result=%s" % json.dumps(result),
             'result.content: a non-empty array of content blocks, e.g. '
             '[{"type": "text", "text": "..."}]',
             "https://modelcontextprotocol.io/specification/2025-06-18/server/tools",
             "a bespoke payload shape is unreadable to every client that did not "
             "negotiate it privately. content blocks are the common currency.")
    for block in content:
        if not isinstance(block, dict) or not block.get("type"):
            fail(7, "tool result shape", json.dumps(block),
                 'each block is an object carrying a "type" discriminator',
                 "https://modelcontextprotocol.io/specification/2025-06-18/server/tools")
    text = " ".join(b.get("text", "") for b in content if b.get("type") == "text")
    if "212" not in text:
        fail(7, "tool result value", "text=%r" % text,
             "100 C converted to F, i.e. 212",
             "https://modelcontextprotocol.io/specification/2025-06-18/server/tools")
    ok(7, "tool invocation: content array returned %r" % text.strip())

    # --- error semantics -------------------------------------------------------
    send(proc, {"jsonrpc": "2.0", "id": 4, "method": "does/not/exist", "params": {}})
    msg = expect_response(proc, 4, 8, "unknown-method response envelope",
                          "waiting for the unknown-method response")
    err = msg.get("error")
    if not isinstance(err, dict) or err.get("code") != -32601:
        fail(8, "protocol error semantics",
             "error=%s result=%s" % (json.dumps(err), json.dumps(msg.get("result"))),
             "a JSON-RPC error with code -32601 (Method not found)",
             "https://www.jsonrpc.org/specification",
             "protocol errors travel in error; tool failures travel in "
             "result.isError. Conflating them hides tool failures from the model.")
    ok(8, "protocol error semantics: unknown method answered with -32601")


def shutdown(proc):
    try:
        proc.stdin.close()
    except Exception:
        pass
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()


def main():
    if len(sys.argv) < 2:
        print("usage: mcp_probe.py <server-command> [args...]", file=sys.stderr)
        return 2
    cmd = sys.argv[1:]
    log_path = os.environ.get("MCP_PROBE_STDERR", "server.stderr.log")
    print("mcp-probe . conformant MCP client . client protocol %s"
          % CLIENT_PROTOCOL_VERSION)
    print("launching: %s" % " ".join(cmd))
    print("server stderr -> %s" % log_path)
    print("")
    proc, errlog = start_server(cmd, log_path)
    failed = False
    try:
        run_checks(proc)
    except ProbeFailure:
        failed = True
    finally:
        shutdown(proc)
        errlog.close()

    if failed:
        print("")
        print("RESULT: NOT INTEROPERABLE. Fix the check above and run me again.")
        return 1

    try:
        size = os.path.getsize(log_path)
    except OSError:
        size = 0
    if size == 0:
        print("  [FAIL]  9/%d  observability: the server logged nothing to stderr" % TOTAL)
        print("          observed: %s is empty" % log_path)
        print("          expected: diagnostics on stderr, messages on stdout")
        print("          note:     the fix is to MOVE logging to stderr, not to delete it.")
        print("")
        print("RESULT: NOT INTEROPERABLE.")
        return 1
    ok(9, "observability: diagnostics reached stderr (%d bytes), stdout stayed clean" % size)
    print("")
    print("RESULT: INTEROPERABLE. All %d checks pass." % TOTAL)
    print("This server now works with every conformant MCP host, with zero")
    print("per-client code. That is the whole value argument of MCP.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
}

write_vendor() {
  cat > "$VENDOR" <<'PY'
#!/usr/bin/env python3
"""vendor_client.py: the in-house client, written before anybody read the spec.

It is deliberately tolerant: it skips junk on stdout, ignores the negotiated
protocol version, and accepts whatever shape the tool result happens to have.
That tolerance is why nobody noticed the server drifting off-spec.

DO NOT EDIT THIS FILE. The grader checksums it. It must keep working after
your fix: a conformant server serves the sloppy client AND the strict one.
"""

import json
import subprocess
import sys


def main():
    cmd = sys.argv[1:] or ["python3", "server.py"]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def call(payload):
        proc.stdin.write(json.dumps(payload) + "\n")
        proc.stdin.flush()
        while True:                      # "just skip anything that isn't JSON"
            line = proc.stdout.readline()
            if line == "":
                print("vendor-client: server died", file=sys.stderr)
                sys.exit(1)
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue

    hello = call({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "vendor-client", "version": "0.9"}}})
    info = (hello.get("result") or {}).get("serverInfo") or {}
    print("vendor-client: connected to %s %s (protocol field ignored on purpose)"
          % (info.get("name", "?"), info.get("version", "?")))

    proc.stdin.write(json.dumps({"jsonrpc": "2.0",
                                 "method": "notifications/initialized"}) + "\n")
    proc.stdin.flush()

    listed = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    tools = (listed.get("result") or {}).get("tools") or []
    for tool in tools:                   # "schema could be under either key"
        schema = tool.get("inputSchema") or tool.get("parameters") or {}
        print("vendor-client: tool %s, %d parameter(s)"
              % (tool.get("name"), len(schema.get("properties") or {})))

    called = call({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                   "params": {"name": "convert_temperature",
                              "arguments": {"value": 100, "from_unit": "C",
                                            "to_unit": "F"}}})
    result = called.get("result") or {}
    if isinstance(result.get("content"), list):          # spec shape
        text = " ".join(b.get("text", "") for b in result["content"])
    else:                                                # our private shape
        text = "%s %s" % (result.get("output", "?"), result.get("unit", ""))
    print("vendor-client: 100 C -> %s" % text.strip())
    print("vendor-client: OK, works on my machine.")

    proc.stdin.close()
    proc.wait(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
}

write_wrappers() {
  cat > "$LAB_DIR/probe.sh" <<'EOF'
#!/usr/bin/env bash
# The strict, spec-conformant client. This is the one that must pass.
cd "$(dirname "$0")"
exec python3 mcp_probe.py python3 server.py
EOF
  cat > "$LAB_DIR/vendor.sh" <<'EOF'
#!/usr/bin/env bash
# The tolerant in-house client. This is the one that lies to you.
cd "$(dirname "$0")"
exec python3 vendor_client.py python3 server.py
EOF
  chmod +x "$LAB_DIR/probe.sh" "$LAB_DIR/vendor.sh"
}

# ---------------------------------------------------------------------------
# The controlled breakage
# ---------------------------------------------------------------------------

break_server() {
  local patcher
  patcher="$(mktemp "${TMPDIR:-/tmp}/mcp-lab-patch.XXXXXX.py")"
  trap 'rm -f "$patcher"' RETURN
  cat > "$patcher" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text()

PATCHES = [
    ("release tag", 'SERVER_VERSION = "1.4.0"\n', 'SERVER_VERSION = "1.5.0"\n'),
    ("startup banner",
     '    log("listening on stdio")\n',
     '    print(SERVER_NAME + " " + SERVER_VERSION + " ready", flush=True)\n'),
    ("per-request trace",
     '        method = msg.get("method")\n',
     '        print("DEBUG method=" + str(msg.get("method")), flush=True)\n'
     '        method = msg.get("method")\n'),
    ("version handling",
     '    if requested in SUPPORTED_PROTOCOL_VERSIONS:\n'
     '        return requested\n'
     '    return PREFERRED_PROTOCOL_VERSION\n',
     '    return "1.0"\n'),
    ("tool descriptor: description",
     '        "description": "Convert a temperature between Celsius and Fahrenheit.",\n',
     ''),
    ("tool descriptor: schema key",
     '        "inputSchema": {\n',
     '        "parameters": {\n'),
    ("tool result payload",
     '    respond(req_id, {\n'
     '        "content": [{"type": "text", "text": "%g %s = %g %s" % (value, from_unit, result, to_unit)}],\n'
     '        "isError": False,\n'
     '    })\n',
     '    respond(req_id, {\n'
     '        "output": "%g" % result,\n'
     '        "unit": to_unit,\n'
     '        "isError": False,\n'
     '    })\n'),
]

for label, old, new in PATCHES:
    if src.count(old) != 1:
        sys.stderr.write("patch anchor missing or ambiguous: %s\n" % label)
        sys.exit(1)
    src = src.replace(old, new)

path.write_text(src)
PY
  python3 "$patcher" "$SERVER" || die "failed to apply the lab breakage; nothing is half-written, re-run with 'reset'."
  python3 -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$SERVER" \
    || die "the broken server is not valid Python; that is a bug in this lab script."
}

# ---------------------------------------------------------------------------
# Flows
# ---------------------------------------------------------------------------

setup() {
  mkdir -p "$LAB_DIR"
  date -u '+created %Y-%m-%dT%H:%M:%SZ by break-fix-mcpa-1.3.sh' > "$MARKER"
  write_server
  write_probe
  write_vendor
  write_wrappers
  { sha "$PROBE"; sha "$VENDOR"; } > "$SUMS"
}

baseline() {
  rule
  printf '%s\n' "${B}STEP 1 - baseline: the server as it shipped in 1.4.0${Z}"
  rule
  ( cd "$LAB_DIR" && ./probe.sh ) || die "the baseline should be green but is not; your python3 may be unusual. Report this."
  printf '\n'
}

briefing() {
  rule
  printf '%s\n' "${B}STEP 2 - a teammate refactored the server and tagged 1.5.0${Z}"
  rule
  printf '\n'
  ( cd "$LAB_DIR" && ./vendor.sh ) || true
  printf '\n'
  printf '%s\n' "${G}The in-house client is perfectly happy. Now the strict one:${Z}"
  printf '\n'
  ( cd "$LAB_DIR" && ./probe.sh ) || true
  printf '\n'
  cat <<TXT
$(rule)
${B}SYMPTOM${Z}
  "It works here." The in-house vendor client connects, lists the tool and gets
  the right answer from mcp-lab-server 1.5.0. Every other MCP host - the IDE
  agent, the desktop app, the gateway in staging - now fails to start the
  server, or starts it and sees no tools, or calls the tool and renders nothing.
  The conformant probe above shows you exactly where the first wall is.

${B}YOUR MISSION${Z}
  Make "./probe.sh" print all 9 checks OK, and keep "./vendor.sh" working.

  Rules of the exercise:
    * edit ONLY $LAB_DIR/server.py
    * mcp_probe.py and vendor_client.py are checksummed; changing them fails
      the grade instantly
    * do not delete the server's logging - move it where it belongs. Check 9
      fails if stderr goes silent
    * the probe fails fast: one check at a time. There are four distinct
      contract violations behind those nine checks. Expect to iterate.

${B}WHY THIS IS TOPIC 1.3 - INTEROPERABILITY & VALUE${Z}
  MCP's payoff is M + N integrations instead of M x N, and it is entirely
  conditional on conformance. Every fault in this lab is something a team can
  ship on a Friday without breaking their own client - a startup banner, a
  version string "simplified" to 1.0, a schema key renamed, a "cleaner" result
  payload. Each one silently drops the server out of the ecosystem it was
  written to join. Tolerant clients are what let that drift survive to
  production; a validating client is what makes the value real.

${B}COMMANDS${Z}
  cd $LAB_DIR
  ./probe.sh                    # the strict client: your test suite
  ./vendor.sh                   # the tolerant client: must keep working
  cat server.stderr.log         # where diagnostics are supposed to end up
  python3 server.py < /dev/null # what does the server say with no client at all?

  $0 verify        # grade the fix
  $0 hint 1        # progressive hints (1, 2, 3)
  $0 reset         # start the exercise over
  $0 clean         # delete $LAB_DIR

  Full solution: commented at the bottom of this script. Try first.
$(rule)
TXT
}

verify() {
  [ -e "$MARKER" ] || die "no lab found at $LAB_DIR. Run '$0' first."
  local expected actual
  expected="$(cat "$SUMS")"
  actual="$( { sha "$PROBE"; sha "$VENDOR"; } )"
  if [ "$expected" != "$actual" ]; then
    printf '%s\n' "${R}GRADE: FAIL${Z} - mcp_probe.py or vendor_client.py was modified."
    printf '%s\n' "Restore them with '$0 reset' (this also re-breaks the server)."
    exit 1
  fi
  rule
  printf '%s\n' "${B}GRADING${Z}"
  rule
  local strict=0 tolerant=0
  ( cd "$LAB_DIR" && ./probe.sh ) || strict=1
  printf '\n'
  ( cd "$LAB_DIR" && ./vendor.sh ) || tolerant=1
  printf '\n'
  if [ "$strict" -eq 0 ] && [ "$tolerant" -eq 0 ]; then
    printf '%s\n' "${G}GRADE: PASS${Z} - one server, two very different clients, zero per-client code."
    printf '%s\n' "That is the M + N argument, demonstrated rather than asserted."
    exit 0
  fi
  [ "$strict" -eq 1 ] && printf '%s\n' "${R}GRADE: FAIL${Z} - the conformant probe is still rejecting the server."
  [ "$tolerant" -eq 1 ] && printf '%s\n' "${R}GRADE: FAIL${Z} - you broke the in-house client. A conformant server must serve both."
  exit 1
}

hints() {
  case "${1:-1}" in
    1) cat <<'TXT'
HINT 1/3
  Ask what the server says when nobody is talking to it:

      cd LAB_DIR && python3 server.py < /dev/null

  A conformant stdio server writes NOTHING to stdout until a client asks it
  something. Anything else on that stream is, to the client, a malformed
  message - the transport is newline-delimited JSON-RPC and nothing else.
  Spec: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
TXT
       ;;
    2) cat <<'TXT'
HINT 2/3
      grep -n 'print(' server.py

  Every hit on that list writes to stdout. The file already has a log()
  helper that sends text to stderr, which is where diagnostics belong.
  Note there are two offenders: one at startup, one per request - so the
  framing check can fail twice, at different moments of the session.
TXT
       ;;
    3) cat <<'TXT'
HINT 3/3
  Three contract breaks hide behind the framing one. Read these three pages
  and compare them to server.py line by line:

    * lifecycle - what MUST the server put in result.protocolVersion?
      MCP versions are dates, not semver, and the client disconnects on a
      version it does not speak.
      https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle

    * tools - under which key does a tool publish its JSON Schema, and what
      other field does the model need in order to pick the tool at all?
      https://modelcontextprotocol.io/specification/2025-06-18/server/tools

    * tools, result section - a tools/call result carries an array of typed
      content blocks. A private payload shape is invisible to every client
      that did not agree to it in advance.
TXT
       ;;
    *) die "hint must be 1, 2 or 3." ;;
  esac
}

clean() {
  [ -e "$MARKER" ] || die "$LAB_DIR is not a lab directory created by this script. Refusing to delete it."
  if [ "${ASSUME_LAB:-0}" != "1" ]; then
    [ -t 0 ] || die "Non-interactive shell; re-run with ASSUME_LAB=1 to confirm deletion."
    printf '%s\n' "About to delete: $LAB_DIR"
    read -r -p "Type the word delete to confirm: " answer
    [ "$answer" = "delete" ] || { printf '%s\n' "Aborted, nothing deleted."; exit 0; }
  fi
  rm -rf "$LAB_DIR"
  printf '%s\n' "Removed $LAB_DIR"
}

usage() {
  cat <<TXT
break-fix-mcpa-1.3.sh - MCPA topic 1.3, Interoperability & Value

  $0            set the lab up, prove it green, then break it
  $0 verify     grade your fix
  $0 hint [N]   progressive hints (1, 2, 3)
  $0 reset      rebuild the lab and re-break it (discards your edits)
  $0 clean      delete $LAB_DIR

Environment: MCP_LAB_DIR (default $HOME/mcp-interop-lab), ASSUME_LAB=1 to skip prompts.
TXT
}

main() {
  case "${1:-start}" in
    start)
      preflight
      [ -e "$MARKER" ] && die "a lab already exists at $LAB_DIR. Use '$0 verify', '$0 reset' or '$0 clean'."
      confirm_lab_vm
      setup
      baseline
      break_server
      briefing
      ;;
    reset)
      preflight
      [ -e "$MARKER" ] || die "no lab at $LAB_DIR. Run '$0' first."
      if [ "${ASSUME_LAB:-0}" != "1" ] && [ -t 0 ]; then
        read -r -p "Rebuild the lab and discard your edits to server.py? [y/N] " a
        case "$a" in [yY]|[yY][eE][sS]) ;; *) printf '%s\n' "Aborted."; exit 0 ;; esac
      fi
      setup
      break_server
      printf '%s\n' "${Y}Lab reset and re-broken.${Z}"
      briefing
      ;;
    verify) verify ;;
    hint)   hints "${2:-1}" ;;
    clean)  clean ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"

# ============================================================================
# ============================================================================
#  SOLUTION - four contract violations, nine checks. Stop reading if you have
#  not tried yet. Every path below is relative to the lab directory.
# ============================================================================
#
#  DIAGNOSIS FIRST
#  ---------------
#  # 1. What does the server put on the wire when no client is talking to it?
#  #      python3 server.py < /dev/null
#  #    Output: "mcp-lab-server 1.5.0 ready" on STDOUT. That single line is
#  #    already a fatal protocol violation: the stdio transport says stdout
#  #    carries JSON-RPC messages, one per line, and nothing else.
#  #
#  # 2. What does a conformant client see?
#  #      ./probe.sh
#  #    Check 1 fails with a JSONDecodeError on that banner. Fail-fast means
#  #    you will uncover the remaining faults one at a time.
#  #
#  # 3. Why did nobody notice? Read vendor_client.py: it skips every line that
#  #    does not start with "{", ignores protocolVersion, reads the schema from
#  #    inputSchema OR parameters, and falls back to result["output"]. Four
#  #    private workarounds. That is the M x N world MCP exists to delete.
#
#  FAULT A - stdout is not a log stream (checks 1 and 9)
#  ----------------------------------------------------
#  # grep -n 'print(' server.py   ->  two offenders.
#  # Move both to stderr via the log() helper that is already in the file.
#  # Do not simply delete them: check 9 requires the server to keep logging.
#  #
#  #   sed -i 's|^    print(SERVER_NAME + " " + SERVER_VERSION + " ready", flush=True)$|    log("listening on stdio")|' server.py
#  #   sed -i 's|^        print("DEBUG method=" + str(msg.get("method")), flush=True)$|        log("method=" + str(msg.get("method")))|' server.py
#  #
#  # Rule to remember: in stdio transport the server MUST NOT write anything
#  # to stdout that is not a valid MCP message, and messages MUST NOT contain
#  # embedded newlines. Logging goes to stderr - or to the client through
#  # notifications/message, once logging capability is negotiated.
#  # https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#
#  FAULT B - protocol version is a date, not a semver (check 3)
#  -----------------------------------------------------------
#  # negotiate() was flattened to `return "1.0"`. Restore real negotiation:
#  # the server echoes the client's version when it supports it, otherwise it
#  # answers with a version it does support and lets the client decide.
#  #
#  #   python3 - <<'PY'
#  #   import pathlib
#  #   p = pathlib.Path("server.py"); s = p.read_text()
#  #   s = s.replace(
#  #       '    return "1.0"\n',
#  #       '    if requested in SUPPORTED_PROTOCOL_VERSIONS:\n'
#  #       '        return requested\n'
#  #       '    return PREFERRED_PROTOCOL_VERSION\n')
#  #   p.write_text(s)
#  #   PY
#  #
#  # A client that receives an unsupported version MUST disconnect - that is
#  # conformant behaviour, not a bug in the client.
#  # https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#
#  FAULT C - the tool descriptor (check 6)
#  ---------------------------------------
#  # Two edits inside the TOOLS list:
#  #   a) the JSON Schema key is inputSchema, not parameters:
#  #        sed -i 's|^        "parameters": {$|        "inputSchema": {|' server.py
#  #   b) restore the description, which is what the model reads to decide
#  #      whether the tool applies at all. Add back, above the schema:
#  #        "description": "Convert a temperature between Celsius and Fahrenheit.",
#  #
#  #      python3 - <<'PY'
#  #      import pathlib
#  #      p = pathlib.Path("server.py"); s = p.read_text()
#  #      s = s.replace('        "name": "convert_temperature",\n',
#  #                    '        "name": "convert_temperature",\n'
#  #                    '        "description": "Convert a temperature between Celsius and Fahrenheit.",\n')
#  #      p.write_text(s)
#  #      PY
#  # https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#
#  FAULT D - the tool result shape (check 7)
#  -----------------------------------------
#  # handle_tools_call returned {"output": "212", "unit": "F"} - a private
#  # shape. A tools/call result carries content: an array of typed blocks.
#  #
#  #   python3 - <<'PY'
#  #   import pathlib
#  #   p = pathlib.Path("server.py"); s = p.read_text()
#  #   s = s.replace(
#  #       '        "output": "%g" % result,\n        "unit": to_unit,\n',
#  #       '        "content": [{"type": "text", "text": "%g %s = %g %s" % (value, from_unit, result, to_unit)}],\n')
#  #   p.write_text(s)
#  #   PY
#  #
#  # Keep isError where it is: tool-level failures belong in the result so the
#  # model can see and recover from them, while protocol-level failures use the
#  # JSON-RPC error object (-32601, -32602, ...). Check 8 guards that split.
#
#  VERIFY
#  ------
#  #   ./probe.sh         -> 9/9 OK
#  #   ./vendor.sh        -> still prints "100 C -> 100 C = 212 F"
#  #   ../break-fix-mcpa-1.3.sh verify   -> GRADE: PASS
#  #
#  # The point to carry into the exam: nothing here was a "hard" bug. Each
#  # fault was a small local convenience that cost nothing inside the team and
#  # removed the server from the entire ecosystem. Interoperability is not a
#  # property of the protocol; it is a property of the implementation, and it
#  # is only worth the M + N arithmetic while it is enforced - by validating
#  # clients, by conformance checks in CI, by refusing to be tolerant.
# ============================================================================