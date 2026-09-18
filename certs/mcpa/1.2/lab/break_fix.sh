#!/usr/bin/env bash
# =============================================================================
#  MCPA — Model Context Protocol Associate (exam version 2026-07-28)
#  Topic 1.2 — Core MCP Concepts        (exam weight: 5.33)
#
#  BREAK & FIX LAB — "the handshake that never completes"
#
#  What this lab teaches, by breaking it:
#    * the stdio transport contract  (stdout carries newline-delimited
#      JSON-RPC 2.0 and NOTHING else; diagnostics belong on stderr)
#    * the initialization lifecycle  (initialize -> negotiated protocolVersion
#      -> notifications/initialized -> normal operation)
#    * JSON-RPC message types        (request / response / notification, and
#      the id correlation that ties a response to its request)
#    * capability negotiation        (a client may only use what the server
#      declared in the initialize result)
#
#  Reference sources:
#    - https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    - https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    - https://modelcontextprotocol.io/specification/2025-06-18/server/resources
#    - https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
#    - https://www.jsonrpc.org/specification
#
#  SAFETY
#    Runs entirely inside one directory (default: $HOME/mcp-lab-1-2), as the
#    invoking user, with no sudo, no package installs, no network, no systemd
#    units and no changes to anything outside that directory.  It still assumes
#    a disposable lab VM: it leaves a deliberately broken program on disk.
#    Requirement: python3 >= 3.8 (standard library only).
#
#  USAGE
#    ./mcpa-1.2-breakfix.sh            set up, prove the lab healthy, break it
#    ./mcpa-1.2-breakfix.sh check      run the conformance client (use while fixing)
#    ./mcpa-1.2-breakfix.sh brief      print the student brief again
#    ./mcpa-1.2-breakfix.sh reset      rebuild from scratch and break it again
#    ./mcpa-1.2-breakfix.sh clean      remove the lab directory
#
#    MCP_LAB_TRACE=1 ./mcpa-1.2-breakfix.sh check    print every JSON-RPC frame
# =============================================================================

set -Eeuo pipefail

LAB_DIR="${MCP_LAB_DIR:-$HOME/mcp-lab-1-2}"
MARKER="$LAB_DIR/.mcpa-lab-1-2"
SERVER="$LAB_DIR/server.py"
CLIENT="$LAB_DIR/conformance_client.py"

if [ -t 1 ]; then
    B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
    B=""; R=""; G=""; Y=""; C=""; N=""
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
die()  { printf '%sERROR%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Guards
# -----------------------------------------------------------------------------
preflight() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found in PATH."
    python3 - <<'PYVER' || die "python3 >= 3.8 is required."
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PYVER

    case "$LAB_DIR" in
        "/"|"$HOME"|"$HOME/"|"") die "refusing to use '$LAB_DIR' as the lab directory." ;;
    esac
}

confirm() {
    [ "${MCP_LAB_CONFIRM:-}" = "yes" ] && return 0
    [ ! -t 0 ] && die "non-interactive run: set MCP_LAB_CONFIRM=yes to confirm this is a disposable lab VM."
    say ""
    say "${Y}This lab writes a deliberately broken MCP server under:${N} $LAB_DIR"
    say "Nothing outside that directory is touched, and sudo is never used."
    printf 'Type %sBREAK%s to continue: ' "$B" "$N"
    read -r answer
    [ "$answer" = "BREAK" ] || die "aborted by the student."
}

# -----------------------------------------------------------------------------
# The lab files
# -----------------------------------------------------------------------------
write_lab() {
    mkdir -p "$LAB_DIR"
    : > "$MARKER"

    cat > "$SERVER" <<'SERVER_PY'
#!/usr/bin/env python3
"""inventory-mcp: a minimal MCP server for the MCPA 1.2 lab.

Transport: stdio.  Every message is one JSON-RPC 2.0 object on a single line
of stdout.  Nothing else may ever reach stdout -- diagnostics go to stderr.
See https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
"""

import json
import sys

SERVER_NAME = "inventory-mcp"
SERVER_VERSION = "1.0.0"

# MCP protocol revisions this server speaks, newest first.  Revisions are
# dates, not semantic versions.
SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26"]

INVENTORY_URI = "inventory://warehouse/eu-west/summary"

STOCK = {"SKU-1001": 42, "SKU-1002": 0, "SKU-2117": 7}

TOOLS = [
    {
        "name": "stock_lookup",
        "title": "Stock lookup",
        "description": "Return the units on hand for a warehouse SKU.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sku": {"type": "string", "description": "SKU code, e.g. SKU-1001"}
            },
            "required": ["sku"],
        },
    }
]

RESOURCES = [
    {
        "uri": INVENTORY_URI,
        "name": "EU-West inventory summary",
        "description": "Units on hand for every SKU in the EU-West warehouse.",
        "mimeType": "text/plain",
    }
]

PROMPTS = [
    {
        "name": "restock_report",
        "description": "Draft a restock request for a SKU that ran out.",
        "arguments": [{"name": "sku", "description": "SKU code", "required": True}],
    }
]


def log(message):
    """Diagnostics go to stderr.  stdout belongs to the transport."""
    print("[%s] %s" % (SERVER_NAME, message), file=sys.stderr, flush=True)


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def send_result(request_id, payload):
    send({"jsonrpc": "2.0", "id": request_id, "result": payload})


def send_error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id,
          "error": {"code": code, "message": message}})


def summary_text():
    rows = ["%s: %d units" % (sku, units) for sku, units in sorted(STOCK.items())]
    return "EU-West warehouse\n" + "\n".join(rows)


def handle_initialize(params):
    requested = params.get("protocolVersion")
    negotiated = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
    log(f"client requested {requested}, negotiated {negotiated}")
    return {
        "protocolVersion": negotiated,
        "capabilities": {
            "tools": {"listChanged": False},
            "resources": {"subscribe": False, "listChanged": False},
            "prompts": {"listChanged": False},
            "logging": {},
        },
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        "instructions": "Warehouse inventory. Use stock_lookup to read units on hand.",
    }


def handle_tools_call(params):
    name = params.get("name")
    arguments = params.get("arguments") or {}
    if name != "stock_lookup":
        return {"content": [{"type": "text", "text": f"Unknown tool: {name}"}],
                "isError": True}
    sku = arguments.get("sku", "")
    if sku not in STOCK:
        # A tool that fails is a RESULT with isError, not a JSON-RPC error:
        # the model is meant to see the failure and react to it.
        return {"content": [{"type": "text", "text": f"SKU {sku} not found"}],
                "isError": True}
    return {"content": [{"type": "text",
                         "text": f"{sku}: {STOCK[sku]} units on hand"}],
            "isError": False}


def handle_notification(method, params):
    # A notification has no id and therefore MUST NOT be answered.
    log(f"notification received: {method}")


def dispatch(message):
    method = message.get("method")
    params = message.get("params") or {}

    if "id" not in message:
        handle_notification(method, params)
        return

    request_id = message["id"]

    if method == "initialize":
        send_result(request_id, handle_initialize(params))
    elif method == "ping":
        send_result(request_id, {})
    elif method == "tools/list":
        send_result(request_id, {"tools": TOOLS})
    elif method == "tools/call":
        send_result(request_id, handle_tools_call(params))
    elif method == "resources/list":
        send_result(request_id, {"resources": RESOURCES})
    elif method == "resources/read":
        uri = params.get("uri")
        if uri == INVENTORY_URI:
            send_result(request_id, {"contents": [
                {"uri": uri, "mimeType": "text/plain", "text": summary_text()}
            ]})
        else:
            # Protocol-level failure: invalid params, not a tool result.
            send_error(request_id, -32602, f"Unknown resource: {uri}")
    elif method == "prompts/list":
        send_result(request_id, {"prompts": PROMPTS})
    elif method == "prompts/get":
        sku = (params.get("arguments") or {}).get("sku", "UNKNOWN")
        send_result(request_id, {
            "description": "Restock request draft",
            "messages": [{"role": "user", "content": {
                "type": "text",
                "text": f"Draft a restock request for {sku}."}}],
        })
    else:
        send_error(request_id, -32601, f"Method not found: {method}")


def main():
    log(f"{SERVER_NAME} {SERVER_VERSION} listening on stdio")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            send_error(None, -32700, "Parse error")
            continue
        dispatch(message)


if __name__ == "__main__":
    main()
SERVER_PY

    cat > "$CLIENT" <<'CLIENT_PY'
#!/usr/bin/env python3
"""A deliberately strict MCP host: it drives the client half of the lifecycle
and refuses anything the specification does not allow.

This file is the lab's oracle -- do not edit it.  Fix server.py instead.
Lifecycle: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
"""

import json
import os
import select
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")
ERRLOG = os.path.join(HERE, "server.err")
TRACE = os.environ.get("MCP_LAB_TRACE") == "1"

# Protocol revisions this host speaks, newest first.
CLIENT_SUPPORTED = ["2025-11-25", "2025-06-18", "2025-03-26"]

_tty = sys.stdout.isatty()
B = "\033[1m" if _tty else ""
R = "\033[31m" if _tty else ""
G = "\033[32m" if _tty else ""
C = "\033[36m" if _tty else ""
N = "\033[0m" if _tty else ""


def step(text):
    print(f"{C}>>{N} {text}")


def ok(text):
    print(f"   {G}ok{N}  {text}")


def fail(step_name, symptom, concept, hint):
    print()
    print(f"{R}{B}FAIL{N} [{step_name}] {symptom}")
    print(f"     concept : {concept}")
    print(f"     hint    : {hint}")
    print(f"     stderr  : tail -n 20 {ERRLOG}")
    print()
    sys.exit(1)


class Conn:
    """Newline-delimited JSON-RPC over the child process' stdio."""

    def __init__(self, proc):
        self.proc = proc
        self.fd = proc.stdout.fileno()
        self.buf = b""

    def send(self, message):
        if TRACE:
            print(f"   {C}->{N} {json.dumps(message)}")
        try:
            self.proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            self.proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            fail("transport",
                 "the server closed its stdin: the process is gone.",
                 "stdio transport: the server lives as long as the session does.",
                 "read server.err -- the server probably crashed on the last message.")

    def read_line(self, timeout=5.0):
        while b"\n" not in self.buf:
            ready, _, _ = select.select([self.fd], [], [], timeout)
            if not ready:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        text = line.decode("utf-8", "replace")
        if TRACE:
            print(f"   {C}<-{N} {text}")
        return text

    def has_pending(self, timeout=0.6):
        if b"\n" in self.buf:
            return True
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return False
        chunk = os.read(self.fd, 65536)
        if not chunk:
            return False
        self.buf += chunk
        return b"\n" in self.buf


def expect_response(conn, request_id, method):
    raw = conn.read_line()
    if raw is None:
        fail("transport",
             f"no answer to {method!r} within 5s (or stdout hit EOF).",
             "every JSON-RPC request gets exactly one response.",
             "is the server still running? does it handle this method?")
    try:
        message = json.loads(raw)
    except json.JSONDecodeError:
        fail("transport",
             f"the server wrote a line to stdout that is not JSON: {raw!r}",
             "stdio transport: stdout carries newline-delimited JSON-RPC and "
             "nothing else. Banners, prints and tracebacks corrupt the stream.",
             "find what writes to stdout in server.py and move it to stderr.")
    if message.get("jsonrpc") != "2.0":
        fail("framing",
             f"message without jsonrpc=\"2.0\": {raw!r}",
             "JSON-RPC 2.0 envelope.",
             "every message carries the version string.")
    if message.get("id") != request_id:
        fail("correlation",
             f"expected a response with id={request_id} to {method!r}, "
             f"received id={message.get('id')!r}: {raw!r}",
             "requests and responses are paired by id; notifications have no "
             "id and must never be answered. One stray message desynchronises "
             "the whole session.",
             "count the messages the server emits per message it receives.")
    if "error" in message:
        err = message["error"]
        fail("protocol error",
             f"{method!r} returned error {err.get('code')}: {err.get('message')}",
             "JSON-RPC error object.",
             "the method is missing or rejected the params.")
    result = message.get("result")
    if not isinstance(result, dict):
        fail("framing",
             f"{method!r} returned no result object: {raw!r}",
             "a response carries exactly one of result or error.",
             "check the shape of what the server sends.")
    return result


def main():
    print()
    print(f"{B}MCP conformance client -- MCPA 1.2 (Core MCP Concepts){N}")
    print(f"   server under test: {SERVER}")
    print()

    errfh = open(ERRLOG, "wb")
    proc = subprocess.Popen([sys.executable, SERVER],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=errfh, bufsize=0)
    conn = Conn(proc)

    try:
        # --- 1. initialize -------------------------------------------------
        step("1/6  lifecycle: initialize")
        conn.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {
                       "protocolVersion": CLIENT_SUPPORTED[0],
                       "capabilities": {"roots": {"listChanged": True},
                                        "sampling": {},
                                        "elicitation": {}},
                       "clientInfo": {"name": "mcpa-lab-host", "version": "1.2"}}})
        init = expect_response(conn, 1, "initialize")

        negotiated = init.get("protocolVersion")
        if negotiated not in CLIENT_SUPPORTED:
            fail("version negotiation",
                 f"the server answered protocolVersion={negotiated!r}; this host "
                 f"speaks {CLIENT_SUPPORTED}.",
                 "initialize negotiates ONE revision: the server answers the "
                 "revision the client asked for if it supports it, otherwise "
                 "another one it does support. Revisions are dates.",
                 "the client asked for "
                 f"{CLIENT_SUPPORTED[0]!r} -- look at what the server does with it.")
        ok(f"negotiated protocol revision {negotiated}")

        server_info = init.get("serverInfo") or {}
        ok(f"serverInfo {server_info.get('name')} {server_info.get('version')}")

        caps = init.get("capabilities")
        if not isinstance(caps, dict):
            fail("capabilities",
                 "the initialize result carries no capabilities object.",
                 "capability negotiation: the client may only use what the "
                 "server declares here.",
                 "the result needs a capabilities dict.")

        # --- 2. initialized notification -----------------------------------
        step("2/6  lifecycle: notifications/initialized")
        conn.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        if conn.has_pending():
            stray = conn.read_line(timeout=1.0)
            fail("message types",
                 f"the server answered a notification: {stray!r}",
                 "JSON-RPC message types: a request has an id and gets exactly "
                 "one response; a notification has NO id and must never be "
                 "answered. The stray message shifts every later response by one.",
                 "look at how the server decides whether to reply.")
        ok("notification accepted in silence (as it must be)")

        # --- 3. tools -------------------------------------------------------
        step("3/6  primitive: tools")
        if "tools" not in caps:
            fail("capabilities",
                 f"the server did not declare the tools capability "
                 f"(declared: {sorted(caps)}).",
                 "capability negotiation: a compliant client will not call "
                 "tools/list on a server that never advertised tools -- the "
                 "tools become invisible even though the handler exists.",
                 "compare the declared capabilities with the methods the "
                 "server actually implements.")
        tools = expect_response(conn, 2, "tools/list") if conn.send(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}) is None else None
        listed = tools.get("tools")
        if not isinstance(listed, list) or not listed:
            fail("tools", "tools/list returned no tools.",
                 "a tool is model-controlled: it is discovered through tools/list.",
                 "check the TOOLS list and the tools/list branch.")
        for tool in listed:
            if "name" not in tool or not isinstance(tool.get("inputSchema"), dict):
                fail("tools",
                     f"tool without name or inputSchema: {tool!r}",
                     "every tool declares a JSON Schema for its arguments.",
                     "the model cannot call what it cannot type-check.")
        ok(f"tools/list -> {', '.join(t['name'] for t in listed)}")

        conn.send({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                   "params": {"name": "stock_lookup",
                              "arguments": {"sku": "SKU-1001"}}})
        call = expect_response(conn, 3, "tools/call")
        content = call.get("content")
        if not isinstance(content, list) or not content:
            fail("tools", f"tools/call returned no content blocks: {call!r}",
                 "a tool result is a list of content blocks plus isError.",
                 "check handle_tools_call.")
        text = content[0].get("text", "")
        if call.get("isError") or "42" not in text:
            fail("tools", f"tools/call returned {text!r} (isError={call.get('isError')})",
                 "tool failures are results with isError=true, not JSON-RPC errors.",
                 "SKU-1001 holds 42 units.")
        ok(f"tools/call stock_lookup -> {text}")

        # --- 4. resources ---------------------------------------------------
        step("4/6  primitive: resources")
        if "resources" in caps:
            conn.send({"jsonrpc": "2.0", "id": 4, "method": "resources/list"})
            res = expect_response(conn, 4, "resources/list")
            uris = [r.get("uri") for r in res.get("resources", [])]
            if not uris:
                fail("resources", "resources/list returned nothing while the "
                     "capability is declared.",
                     "resources are application-controlled context, addressed by URI.",
                     "declare only what you serve.")
            conn.send({"jsonrpc": "2.0", "id": 5, "method": "resources/read",
                       "params": {"uri": uris[0]}})
            read = expect_response(conn, 5, "resources/read")
            if not read.get("contents"):
                fail("resources", "resources/read returned no contents.",
                     "resources/read answers with a contents array.",
                     "check the resources/read branch.")
            ok(f"resources/read {uris[0]} -> {len(read['contents'])} block(s)")
        else:
            ok("resources capability not declared -- skipped")

        # --- 5. prompts -----------------------------------------------------
        step("5/6  primitive: prompts")
        if "prompts" in caps:
            conn.send({"jsonrpc": "2.0", "id": 6, "method": "prompts/list"})
            pr = expect_response(conn, 6, "prompts/list")
            names = [p.get("name") for p in pr.get("prompts", [])]
            ok(f"prompts/list -> {', '.join(n for n in names if n) or '(none)'}")
        else:
            ok("prompts capability not declared -- skipped")

        # --- 6. ping --------------------------------------------------------
        step("6/6  utility: ping")
        conn.send({"jsonrpc": "2.0", "id": 7, "method": "ping"})
        expect_response(conn, 7, "ping")
        ok("session alive")

        print()
        print(f"{G}{B}PASS{N}  the MCP session completed end to end.")
        print(f"      revision {negotiated} | capabilities: {', '.join(sorted(caps))}")
        print(f"      {len(listed)} tool(s) discovered and invoked.")
        print()
        return 0
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=3)
        except Exception:
            proc.kill()
        errfh.close()


if __name__ == "__main__":
    sys.exit(main())
CLIENT_PY

    chmod +x "$SERVER" "$CLIENT"
}

# -----------------------------------------------------------------------------
# Baseline: the lab must be provably healthy before it is broken
# -----------------------------------------------------------------------------
verify_healthy() {
    head1 "[1/3] Proving the lab is healthy before breaking it"
    if python3 "$CLIENT" > "$LAB_DIR/baseline.log" 2>&1; then
        say "      ${G}baseline ok${N} -- the full MCP session works (log: $LAB_DIR/baseline.log)"
    else
        say "${R}The baseline run failed. This is an environment problem, not the lab.${N}"
        cat "$LAB_DIR/baseline.log"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# The controlled breakage: four faults, one per core concept
# -----------------------------------------------------------------------------
apply_faults() {
    head1 "[2/3] Breaking it (four faults, all inside server.py)"
    python3 - "$SERVER" <<'BREAK_PY'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

FAULTS = [
    (
        "F1 transport: a startup banner on stdout",
        '    log(f"{SERVER_NAME} {SERVER_VERSION} listening on stdio")\n',
        '    print(f"{SERVER_NAME} {SERVER_VERSION} listening on stdio", flush=True)\n',
    ),
    (
        "F2 lifecycle: protocolVersion hardcoded to an invented value",
        '    requested = params.get("protocolVersion")\n'
        '    negotiated = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]\n',
        '    requested = params.get("protocolVersion")\n'
        '    negotiated = "1.0"\n',
    ),
    (
        "F3 message types: notifications get answered",
        '    if "id" not in message:\n'
        '        handle_notification(method, params)\n'
        '        return\n',
        '    if "id" not in message:\n'
        '        handle_notification(method, params)\n'
        '        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {}})\n'
        '        return\n',
    ),
    (
        "F4 capabilities: tools implemented but never declared",
        '            "tools": {"listChanged": False},\n',
        '',
    ),
]

for label, old, new in FAULTS:
    if source.count(old) != 1:
        sys.exit(f"fault injection aborted: anchor not found exactly once for {label}")
    source = source.replace(old, new, 1)
    print(f"      injected  {label}")

open(path, "w", encoding="utf-8").write(source)
BREAK_PY

    if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$SERVER"; then
        say "      server.py still parses -- the faults are protocol faults, not syntax errors."
    fi

    if python3 "$CLIENT" > "$LAB_DIR/broken.log" 2>&1; then
        die "the lab did not break as expected -- check $LAB_DIR/broken.log"
    fi
    say "      ${R}the MCP session no longer completes.${N}"
}

# -----------------------------------------------------------------------------
# The student brief
# -----------------------------------------------------------------------------
brief() {
    head1 "[3/3] Student brief -- MCPA 1.2 Core MCP Concepts"
    cat <<BRIEF

  ${B}The scenario${N}
  An MCP host (${C}conformance_client.py${N}) launches a local MCP server
  (${C}server.py${N}) over the ${B}stdio transport${N} and tries to open a session:
  initialize, then the initialized notification, then discovery and use of the
  server's primitives -- tools, resources, prompts.

  Yesterday it worked. After a "small cleanup" commit to the server, the host
  cannot get a session at all.

  ${B}The symptom you will see${N}
  Run the check and the host stops at the very first step, reporting that what
  arrived on stdout is not JSON-RPC at all. Fix that and it stops a little
  further on, with a different complaint. There are ${B}four independent faults${N}
  in server.py and the client fails fast, so you peel them one at a time:

    1. the transport carries something that is not a protocol message
    2. the negotiated protocol revision is one the host cannot speak
    3. the message count does not match the message types
    4. a primitive that is implemented is never discovered

  Each failure prints the ${C}concept${N} it violates and a ${C}hint${N} -- read them,
  they are the lesson.

  ${B}Your objective${N}
  ${G}python3 $CLIENT${N} exits 0 with ${G}PASS${N}, having negotiated a date-based
  protocol revision, sent the initialized notification, and listed and called
  the stock_lookup tool (SKU-1001 -> 42 units on hand).

  ${B}Rules${N}
    * fix ${C}server.py${N} only -- ${C}conformance_client.py${N} is the oracle, do not edit it
    * do not delete functionality: all three primitives must stay served
    * the server must keep logging to stderr; silencing the logs is not a fix

  ${B}Tools for the job${N}
    ${C}$0 check${N}                 run the conformance client
    ${C}MCP_LAB_TRACE=1 $0 check${N} print every JSON-RPC frame in both directions
    ${C}tail -n 20 $LAB_DIR/server.err${N}   the server's own stderr log

    Drive the server by hand -- the whole protocol is text on a pipe:

      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"by-hand","version":"0"}}}' \\
        | python3 $SERVER 2>/dev/null

  ${B}Questions to answer for yourself before you look at the solution${N}
    * why can a single stray print() to stdout take down a whole MCP session,
      while the same print() on stderr is harmless?
    * what exactly does the client do with the protocolVersion it gets back,
      and why are MCP revisions dates instead of semantic versions?
    * a response carries the id of its request; what does a notification carry
      instead, and what happens to the session if one gets answered?
    * the tools/list handler was never removed in fault 4 -- why do the tools
      still become unusable?

BRIEF
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_setup() {
    preflight
    confirm
    write_lab
    verify_healthy
    apply_faults
    brief
}

cmd_check() {
    preflight
    [ -f "$CLIENT" ] || die "lab not found at $LAB_DIR -- run '$0' first."
    python3 "$CLIENT"
}

cmd_clean() {
    [ -f "$MARKER" ] || die "$LAB_DIR does not look like this lab (marker file missing) -- refusing to delete."
    rm -rf -- "$LAB_DIR"
    say "removed $LAB_DIR"
}

case "${1:-setup}" in
    setup|"")  cmd_setup ;;
    check)     cmd_check ;;
    brief)     preflight; brief ;;
    reset)     preflight; confirm; write_lab; verify_healthy; apply_faults; brief ;;
    clean)     cmd_clean ;;
    -h|--help|help)
        sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *) die "unknown command: $1 (try: setup | check | brief | reset | clean)" ;;
esac

# =============================================================================
#  SOLUTION -- read only after you have tried it
# =============================================================================
#
#  All four faults live in server.py. The client fails fast, so the order below
#  is the order the symptoms appear. After each fix, re-run:
#
#      ./mcpa-1.2-breakfix.sh check
#
#  -------------------------------------------------------------------------
#  FAULT 1 -- transport: a banner on stdout
#  -------------------------------------------------------------------------
#  Symptom:
#      FAIL [transport] the server wrote a line to stdout that is not JSON:
#      'inventory-mcp 1.0.0 listening on stdio'
#
#  Diagnosis:
#      In the stdio transport the child's stdout IS the protocol channel: one
#      JSON-RPC message per line, nothing else. The client reads the first line
#      expecting the initialize response and gets a human-readable banner, so
#      json.loads fails before the session ever starts. This is the single most
#      common bug in hand-written MCP servers, and a `print()` left in for
#      debugging -- or an uncaught traceback printed to stdout by a framework --
#      does it every time. The server is not "down"; it is unreadable.
#
#      Find it mechanically:  grep -n 'print(' server.py   and check which
#      calls lack file=sys.stderr.
#
#  Fix, in main():
#      -    print(f"{SERVER_NAME} {SERVER_VERSION} listening on stdio", flush=True)
#      +    log(f"{SERVER_NAME} {SERVER_VERSION} listening on stdio")
#
#      (log() already writes to sys.stderr. Any diagnostics -- startup banners,
#      progress, tracebacks -- go to stderr, which the host collects as logs.
#      Structured logging for the *model* has its own channel instead:
#      notifications/message under the logging capability.)
#
#  -------------------------------------------------------------------------
#  FAULT 2 -- lifecycle: an invented protocolVersion
#  -------------------------------------------------------------------------
#  Symptom:
#      FAIL [version negotiation] the server answered protocolVersion='1.0';
#      this host speaks ['2025-11-25', '2025-06-18', '2025-03-26']
#
#  Diagnosis:
#      initialize is a negotiation, not a greeting. The client sends the newest
#      revision it supports; the server answers with that same revision if it
#      supports it, otherwise with another revision it does support, and the
#      client then either continues on that revision or disconnects. MCP
#      revisions are dates (YYYY-MM-DD), so "1.0" is not a revision at all --
#      any conformant host disconnects. The server's own SUPPORTED_PROTOCOLS
#      list was already correct; the handler simply stopped consulting it.
#
#  Fix, in handle_initialize():
#           requested = params.get("protocolVersion")
#      -    negotiated = "1.0"
#      +    negotiated = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
#
#      Note the fallback: answering with your own newest supported revision when
#      you do not speak the client's is the correct behaviour -- it gives the
#      client the chance to downgrade instead of guessing. (Over Streamable HTTP
#      the same negotiated value then travels on every request in the
#      MCP-Protocol-Version header; over stdio it is session state.)
#
#  -------------------------------------------------------------------------
#  FAULT 3 -- message types: a notification that gets answered
#  -------------------------------------------------------------------------
#  Symptom:
#      FAIL [message types] the server answered a notification:
#      '{"jsonrpc":"2.0","id":null,"result":{}}'
#
#  Diagnosis:
#      JSON-RPC 2.0 has exactly three message shapes, and MCP uses all three:
#        * request      -- has method and id, MUST get exactly one response
#        * response     -- has the id of its request and exactly one of
#                          result or error
#        * notification -- has method and NO id, MUST NOT be answered
#      notifications/initialized is a notification: it tells the server the
#      client finished initializing. Answering it puts one extra message into
#      the stream, and from that moment every response the client reads is the
#      previous one: it sends tools/list as id 2 and reads id=null, then the
#      id 2 answer arrives when it is waiting for id 3. The session desyncs
#      permanently. This is why the client checks the id rather than trusting
#      arrival order -- and why it is worth testing with a server that emits
#      progress notifications while a request is in flight.
#
#  Fix, in dispatch():
#           if "id" not in message:
#               handle_notification(method, params)
#      -        send({"jsonrpc": "2.0", "id": message.get("id"), "result": {}})
#               return
#
#      Note that `"id" not in message` is the right test, not `not
#      message.get("id")`: id 0 and id "" are perfectly legal request ids.
#
#  -------------------------------------------------------------------------
#  FAULT 4 -- capability negotiation: an undeclared primitive
#  -------------------------------------------------------------------------
#  Symptom:
#      FAIL [capabilities] the server did not declare the tools capability
#      (declared: ['logging', 'prompts', 'resources'])
#
#  Diagnosis:
#      What a server can do is what it declares in the initialize result, once,
#      for the whole session. The tools/list and tools/call handlers are still
#      there and still work if you poke them by hand -- but a conformant host
#      never calls them, because the server said it has no tools. The tools are
#      invisible: no error, no crash, just a model that suddenly "has no tools".
#      The sub-flags matter too: {"listChanged": true} promises you will send
#      notifications/tools/list_changed when the set changes, and a client may
#      cache the list on that promise. Declare only what you implement.
#
#  Fix, in handle_initialize(), inside "capabilities":
#           "capabilities": {
#      +        "tools": {"listChanged": False},
#               "resources": {"subscribe": False, "listChanged": False},
#               "prompts": {"listChanged": False},
#               "logging": {},
#           },
#
#  -------------------------------------------------------------------------
#  VERIFICATION
#  -------------------------------------------------------------------------
#      ./mcpa-1.2-breakfix.sh check
#
#      >> 1/6  lifecycle: initialize
#         ok  negotiated protocol revision 2025-11-25
#         ok  serverInfo inventory-mcp 1.0.0
#      >> 2/6  lifecycle: notifications/initialized
#         ok  notification accepted in silence (as it must be)
#      >> 3/6  primitive: tools
#         ok  tools/list -> stock_lookup
#         ok  tools/call stock_lookup -> SKU-1001: 42 units on hand
#      >> 4/6  primitive: resources
#         ok  resources/read inventory://warehouse/eu-west/summary -> 1 block(s)
#      >> 5/6  primitive: prompts
#         ok  prompts/list -> restock_report
#      >> 6/6  utility: ping
#         ok  session alive
#
#      PASS  the MCP session completed end to end.
#
#  And by hand, with the protocol visible:
#      MCP_LAB_TRACE=1 ./mcpa-1.2-breakfix.sh check
#
#  -------------------------------------------------------------------------
#  WHAT TO CARRY INTO THE EXAM
#  -------------------------------------------------------------------------
#  * Architecture: a host holds one client per server; one client speaks to
#    exactly one server, over stdio (local child process) or Streamable HTTP
#    (remote). Transport changes the plumbing, never the messages.
#  * Wire format: JSON-RPC 2.0 -- requests (id), responses (same id, result XOR
#    error), notifications (no id, never answered).
#  * Lifecycle: initialize -> negotiated date-based revision + capabilities ->
#    notifications/initialized -> operation. Nothing but initialize and ping
#    belongs before that notification.
#  * Capabilities are the contract: undeclared is unusable, even if implemented.
#  * Server primitives: tools (model-controlled), resources (application-
#    controlled, URI-addressed), prompts (user-controlled). Client primitives
#    face the other way: sampling, roots, elicitation.
#  * Two error channels, not one: JSON-RPC errors (-32700 parse, -32600 invalid
#    request, -32601 method not found, -32602 invalid params) mean the protocol
#    failed; a tool result with isError=true means the tool ran and failed, and
#    that one is meant to reach the model.
#
#  Sources:
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    https://modelcontextprotocol.io/specification/2025-06-18/server/resources
#    https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
#    https://www.jsonrpc.org/specification
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
# =============================================================================