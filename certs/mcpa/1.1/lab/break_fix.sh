#!/usr/bin/env bash
#
# ============================================================================
#  MCPA — Model Context Protocol Associate (exam version 2026-07-28)
#  Domain 1, Topic 1.1: MCP Purpose & Scope        | exam weight: 5.33
#  Lab type: BREAK & FIX (destructive only inside its own sandbox directory)
# ============================================================================
#
#  WHY THIS LAB BELONGS TO "PURPOSE & SCOPE"
#  -----------------------------------------
#  Topic 1.1 is not a coding topic, it is a boundary topic: it asks you to say
#  precisely what MCP is responsible for and what it deliberately leaves to
#  somebody else. The fastest way to internalise a boundary is to cross it and
#  watch the protocol break. This lab ships a real (tiny, stdlib-only) MCP
#  server over the stdio transport and a real MCP client used as the grader,
#  then violates three separate scope rules:
#
#    * MCP owns the stdout channel of a stdio server — it is a protocol bus,
#      not a place to print human-readable output.
#    * MCP negotiates a dated protocol revision during `initialize` — version
#      compatibility is in scope for the protocol, not for your application.
#    * MCP advertises capabilities, and capabilities are the contract — a host
#      must not invoke a feature that was never offered, even if the code for
#      that feature happens to exist on the server.
#
#  What MCP is NOT responsible for (and what this lab will never ask you to
#  configure): model inference, prompt templating strategy, agent loops, tool
#  selection heuristics, or business authorisation logic. Those live in the
#  host application. MCP standardises how context and callable capabilities
#  reach the model, not what the model does with them.
#
#  SOURCES (official, consulted for this lab)
#    - Linux Foundation, MCPA certification page:
#      https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    - MCP specification, lifecycle (initialize / initialized / shutdown):
#      https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    - MCP specification, transports (stdio framing rules):
#      https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    - MCP specification, server tools (capabilities and tools/*):
#      https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    - JSON-RPC 2.0 specification (envelope and error codes):
#      https://www.jsonrpc.org/specification
#
#  SAFETY
#    - Everything is created under a single sandbox directory (default
#      $HOME/mcpa-lab-1.1). No sudo, no package installs, no network calls, no
#      system services, no files touched outside that directory.
#    - Requires only python3 (>= 3.8) from the base image.
#    - Still: run it on a disposable lab VM, as a normal user.
#
#  USAGE
#      ./mcpa-1.1-break-fix.sh            # setup + prove green + break + brief
#      ./mcpa-1.1-break-fix.sh verify     # re-run the grader (your feedback loop)
#      ./mcpa-1.1-break-fix.sh hint       # progressive hints, no answers
#      ./mcpa-1.1-break-fix.sh reset      # back to the broken starting state
#      ./mcpa-1.1-break-fix.sh clean      # delete the sandbox directory
# ============================================================================

set -euo pipefail

LAB_ROOT="${MCPA_LAB_ROOT:-$HOME/mcpa-lab-1.1}"
MARKER="$LAB_ROOT/.mcpa-lab"
SERVER="$LAB_ROOT/server/mcp_echo_server.py"
PROBE="$LAB_ROOT/client/mcp_probe.py"
BROKEN_BASELINE="$LAB_ROOT/.baseline/mcp_echo_server.py.broken"
SERVER_LOG="$LAB_ROOT/logs/server.stderr.log"
PY="${PYTHON:-python3}"

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

preflight() {
    if [ "$(id -u)" -eq 0 ] && [ "${MCPA_LAB_ALLOW_ROOT:-0}" != "1" ]; then
        die "refusing to run as root. This lab needs no privileges. Re-run as a normal user, or set MCPA_LAB_ALLOW_ROOT=1 if your VM only has root."
    fi
    command -v "$PY" >/dev/null 2>&1 || die "python3 not found in PATH (set PYTHON=/path/to/python3)"
    "$PY" - <<'PYCHK' || die "python3 >= 3.8 required"
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PYCHK
    case "$LAB_ROOT" in
        /|/home|/root|/usr|/etc|/var) die "unsafe LAB_ROOT: $LAB_ROOT" ;;
    esac
}

# ---------------------------------------------------------------------------
# The MCP server under test (healthy version)
# ---------------------------------------------------------------------------
write_server_healthy() {
    mkdir -p "$LAB_ROOT/server"
    cat >"$SERVER" <<'PY'
#!/usr/bin/env python3
"""A minimal, dependency-free MCP server speaking JSON-RPC 2.0 over stdio.

Scope of this process (this is the whole point of topic 1.1):

  IN SCOPE  - framing JSON-RPC 2.0 messages, one per line, on stdout
            - the lifecycle handshake: initialize -> notifications/initialized
            - declaring a protocol revision and a capability set
            - exposing one tool (`echo`) with a JSON Schema for its arguments

  OUT OF SCOPE - running a model, choosing which tool to call, deciding whether
                 the caller is allowed to call it, or rendering anything for a
                 human. Those belong to the host application, not to MCP.

Transport rule that everything below depends on: on the stdio transport,
stdout carries protocol messages ONLY, newline-delimited, with no embedded
newlines. Diagnostics go to stderr.
See https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
"""

import json
import sys

# The MCP revision this server implements. MCP revisions are dates, not
# semantic versions; the client compares this against what it supports during
# the initialize exchange.
PROTOCOL_VERSION = "2025-06-18"

SERVER_INFO = {"name": "mcpa-lab-echo", "version": "1.1.0"}

# Capabilities ARE the contract. A host is entitled to call tools/* only
# because this object says the server has tools.
CAPABILITIES = {"tools": {"listChanged": False}}

TOOLS = [
    {
        "name": "echo",
        "title": "Echo",
        "description": "Return the text it was given. Scope demonstration only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Text to echo back."}
            },
            "required": ["text"],
        },
    }
]

STATE = {"initialized": False}


def log(message):
    """Diagnostics go to stderr. Never to stdout on a stdio transport."""
    print("[server] " + message, file=sys.stderr, flush=True)


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply_result(request_id, payload):
    send({"jsonrpc": "2.0", "id": request_id, "result": payload})


def reply_error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id,
          "error": {"code": code, "message": message}})


def handle(message):
    method = message.get("method")
    request_id = message.get("id")

    if method == "initialize":
        log("initialize from " + str((message.get("params") or {}).get("clientInfo")))
        reply_result(request_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": CAPABILITIES,
            "serverInfo": SERVER_INFO,
        })
        return

    if method == "notifications/initialized":
        STATE["initialized"] = True
        log("lifecycle: session initialized, server is now operational")
        return

    if request_id is None:
        # Any other notification: no response is ever sent for a notification.
        log("ignoring notification: " + str(method))
        return

    if not STATE["initialized"]:
        reply_error(request_id, -32002,
                    "server not initialized: '" + str(method) +
                    "' arrived before notifications/initialized")
        return

    if method == "tools/list":
        reply_result(request_id, {"tools": TOOLS})
        return

    if method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name != "echo":
            reply_error(request_id, -32602, "unknown tool: " + str(name))
            return
        text = arguments.get("text")
        if not isinstance(text, str):
            # A tool-level failure is a RESULT with isError, not a JSON-RPC
            # error: the model must be able to see and recover from it.
            reply_result(request_id, {
                "content": [{"type": "text",
                             "text": "missing required argument 'text'"}],
                "isError": True,
            })
            return
        reply_result(request_id, {
            "content": [{"type": "text", "text": text}],
            "isError": False,
        })
        return

    reply_error(request_id, -32601, "method not found: " + str(method))


def main():
    log("ready: reading newline-delimited JSON-RPC from stdin")
    while True:
        line = sys.stdin.readline()
        if line == "":
            log("stdin closed, exiting")
            return
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            send({"jsonrpc": "2.0", "id": None,
                  "error": {"code": -32700, "message": "parse error: " + str(exc)}})
            continue
        handle(message)


if __name__ == "__main__":
    main()
PY
    chmod +x "$SERVER"
}

# ---------------------------------------------------------------------------
# The grader: a real MCP client, and the only thing that decides pass/fail
# ---------------------------------------------------------------------------
write_probe() {
    mkdir -p "$LAB_ROOT/client" "$LAB_ROOT/logs"
    cat >"$PROBE" <<'PY'
#!/usr/bin/env python3
"""MCPA lab grader: a minimal MCP host/client driving the server under test.

It performs exactly what a conformant host does and reports where the
conversation stops being MCP. Do not edit this file: it is the exam.
"""

import json
import os
import queue
import subprocess
import sys
import threading

# Published MCP revisions this host speaks, newest first.
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
TIMEOUT = 8.0

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SERVER = os.path.join(ROOT, "server", "mcp_echo_server.py")
LOG = os.path.join(ROOT, "logs", "server.stderr.log")
SAMPLE = "MCP standardises how context reaches the model."


class Fail(Exception):
    pass


class Session:
    """One stdio MCP session: a child process plus a line-oriented reader."""

    def __init__(self):
        self.log = open(LOG, "ab", buffering=0)
        self.proc = subprocess.Popen(
            [sys.executable, SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
            bufsize=1,
        )
        self.lines = queue.Queue()
        threading.Thread(target=self._reader, daemon=True).start()
        self._next_id = 0

    def _reader(self):
        for line in self.proc.stdout:
            self.lines.put(line.rstrip("\n"))
        self.lines.put(None)

    def raw_line(self):
        try:
            line = self.lines.get(timeout=TIMEOUT)
        except queue.Empty:
            raise Fail("timeout: no bytes on stdout within %.0fs" % TIMEOUT)
        if line is None:
            raise Fail("the server closed stdout / exited; see logs/server.stderr.log")
        return line

    def message(self):
        line = self.raw_line()
        if not line.strip():
            raise Fail("an empty line was framed onto the stdio transport")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise Fail(
                "stdout carried a line that is not a JSON-RPC message: %r\n"
                "JSON decoder said: %s\n"
                "On stdio, stdout is the protocol bus; human output belongs on stderr."
                % (line[:160], exc)
            )

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params=None):
        self._next_id += 1
        request_id = self._next_id
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        reply = self.message()
        if reply.get("id") != request_id:
            raise Fail("response id mismatch: sent %r, received %r"
                       % (request_id, reply.get("id")))
        return reply

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def close(self):
        try:
            if self.proc.stdin and not self.proc.stdin.closed:
                self.proc.stdin.close()
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()
        finally:
            self.log.close()


def ok(name, detail=""):
    return (True, name, detail)


def bad(name, detail=""):
    return (False, name, str(detail))


def run():
    results = []
    session = Session()
    try:
        # --- 1. transport framing + JSON-RPC envelope -----------------------
        try:
            reply = session.request("initialize", {
                "protocolVersion": SUPPORTED_PROTOCOL_VERSIONS[0],
                "capabilities": {},
                "clientInfo": {"name": "mcpa-lab-probe", "version": "1.1.0"},
            })
        except Fail as exc:
            results.append(bad("stdio framing", exc))
            results.append(bad("protocol revision", "not reached: the transport is unusable"))
            results.append(bad("advertised capabilities", "not reached"))
            results.append(bad("tools/list", "not reached"))
            results.append(bad("tools/call round trip", "not reached"))
            return results
        results.append(ok("stdio framing", "the first stdout line parsed as JSON-RPC 2.0"))

        if "error" in reply:
            results.append(bad("initialize", "server answered initialize with an error: %s"
                               % reply["error"]))
            return results
        result = reply.get("result") or {}

        # --- 2. protocol revision negotiation -------------------------------
        offered = result.get("protocolVersion")
        if offered in SUPPORTED_PROTOCOL_VERSIONS:
            results.append(ok("protocol revision", "negotiated %s" % offered))
        else:
            results.append(bad(
                "protocol revision",
                "server offered %r; MCP revisions are dates (YYYY-MM-DD) and this "
                "host supports: %s" % (offered, ", ".join(SUPPORTED_PROTOCOL_VERSIONS))))

        # --- 3. capabilities are the contract -------------------------------
        capabilities = result.get("capabilities") or {}
        tools_offered = isinstance(capabilities.get("tools"), dict)
        if tools_offered:
            results.append(ok("advertised capabilities",
                              "initialize advertised: %s" % ", ".join(sorted(capabilities))))
        else:
            results.append(bad(
                "advertised capabilities",
                "initialize advertised %s: with no \"tools\" capability a conformant "
                "host must never call tools/list or tools/call, so this server exposes "
                "nothing to the model no matter what code it contains"
                % (json.dumps(capabilities) or "{}")))

        session.notify("notifications/initialized")

        # --- 4. tools/list ---------------------------------------------------
        note = "" if tools_offered else "  (reached only because the grader ignores the contract)"
        try:
            reply = session.request("tools/list")
            if "error" in reply:
                results.append(bad("tools/list", "error %s" % reply["error"]))
                tools = []
            else:
                tools = (reply.get("result") or {}).get("tools") or []
                names = [t.get("name") for t in tools]
                if "echo" in names:
                    results.append(ok("tools/list", "server exposes: %s%s"
                                      % (", ".join(map(str, names)), note)))
                else:
                    results.append(bad("tools/list", "expected a tool named 'echo', got %s" % names))
        except Fail as exc:
            results.append(bad("tools/list", exc))
            tools = []

        # --- 5. tools/call round trip ---------------------------------------
        try:
            reply = session.request("tools/call",
                                    {"name": "echo", "arguments": {"text": SAMPLE}})
            if "error" in reply:
                results.append(bad("tools/call round trip", "error %s" % reply["error"]))
            else:
                payload = reply.get("result") or {}
                content = payload.get("content") or []
                first = content[0] if content else {}
                if payload.get("isError"):
                    results.append(bad("tools/call round trip", "server reported isError=true"))
                elif first.get("type") == "text" and first.get("text") == SAMPLE:
                    results.append(ok("tools/call round trip",
                                      "text content returned unchanged%s" % note))
                else:
                    results.append(bad("tools/call round trip",
                                       "unexpected content block: %s" % json.dumps(content)[:160]))
        except Fail as exc:
            results.append(bad("tools/call round trip", exc))
    finally:
        session.close()

    # --- 6. lifecycle gate (regression guard) --------------------------------
    gate = Session()
    try:
        reply = gate.request("tools/list")
        if "error" in reply:
            results.append(ok("lifecycle gate",
                              "pre-handshake request refused: %s"
                              % reply["error"].get("message", "")))
        else:
            results.append(bad("lifecycle gate",
                               "the server served tools/list before the initialize "
                               "handshake had completed"))
    except Fail as exc:
        results.append(bad("lifecycle gate", exc))
    finally:
        gate.close()

    return results


def main():
    if not os.path.exists(SERVER):
        print("grader: server not found at %s" % SERVER)
        return 2
    open(LOG, "wb").close()
    results = run()
    print("")
    print("  MCP conformance probe -> %s" % os.path.relpath(SERVER, ROOT))
    print("  " + "-" * 68)
    for index, (good, name, detail) in enumerate(results, 1):
        tag = "[ OK ]" if good else "[FAIL]"
        lines = detail.splitlines() or [""]
        print("  %s %d. %-22s %s" % (tag, index, name, lines[0]))
        for extra in lines[1:]:
            print("  %s    %-22s %s" % (" " * 6, "", extra))
    passed = sum(1 for good, _, _ in results if good)
    total = len(results)
    print("  " + "-" * 68)
    print("  %d/%d checks passed" % (passed, total))
    print("  server stderr: %s" % os.path.relpath(LOG, ROOT))
    print("")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
PY
    chmod +x "$PROBE"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
run_probe() {
    local status=0
    "$PY" "$PROBE" || status=$?
    return "$status"
}

cmd_setup() {
    preflight
    mkdir -p "$LAB_ROOT/logs" "$LAB_ROOT/.baseline"
    printf 'mcpa topic 1.1 break-and-fix sandbox\n' >"$MARKER"
    write_server_healthy
    write_probe
    printf '\n>>> Sandbox created at %s\n' "$LAB_ROOT"
    printf '>>> Baseline check on the healthy server (this must be all green):\n'
    if ! run_probe; then
        die "the healthy baseline did not pass; your python3 build may be unusual. Nothing was broken."
    fi
}

cmd_break() {
    [ -f "$SERVER" ] || die "run '$0 setup' first"
    "$PY" - "$SERVER" <<'PATCH'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    source = handle.read()

faults = [
    # FAULT 1 - protocol scope: an invented, non-dated revision string.
    ('PROTOCOL_VERSION = "2025-06-18"',
     'PROTOCOL_VERSION = "1.0"'),
    # FAULT 2 - contract scope: the capability set no longer offers tools.
    ('CAPABILITIES = {"tools": {"listChanged": False}}',
     'CAPABILITIES = {}'),
    # FAULT 3 - transport scope: a diagnostic line written to the protocol bus.
    ('    log("ready: reading newline-delimited JSON-RPC from stdin")',
     '    print("ready: reading newline-delimited JSON-RPC from stdin")'),
]

for old, new in faults:
    if source.count(old) != 1:
        sys.exit("lab bug: anchor not found exactly once: %r" % old)
    source = source.replace(old, new)

with open(path, "w", encoding="utf-8") as handle:
    handle.write(source)
PATCH
    cp "$SERVER" "$BROKEN_BASELINE"
    printf '\n>>> Three scope violations injected into server/mcp_echo_server.py\n'
}

cmd_verify() {
    [ -f "$PROBE" ] || die "run '$0 setup' first"
    local status=0
    run_probe || status=$?
    if [ "$status" -eq 0 ]; then
        cat <<'DONE'
  ============================================================
   LAB PASSED. The server is inside the boundaries of MCP again:
     - stdout carries protocol messages only
     - a dated protocol revision is negotiated at initialize
     - the tools capability is advertised, so the host is
       contractually allowed to call tools/list and tools/call
  ============================================================
DONE
    else
        printf '  Not there yet. Fix server/mcp_echo_server.py and run: %s verify\n\n' "$0"
    fi
    return "$status"
}

cmd_hint() {
    cat <<'HINTS'

  HINT 1 (transport)
    Drive the server by hand and look at the very first line it writes:

      cd "$LAB_ROOT"
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand","version":"0"}}}' \
        | python3 server/mcp_echo_server.py

    Whatever is on stdout that is not a JSON-RPC message does not belong there.
    Where should a server's human-readable output go on the stdio transport?

  HINT 2 (revision)
    Read the initialize result. MCP does not use semantic versioning; every
    published revision is a date. What did the server claim to speak?

  HINT 3 (contract)
    The server still has a tools/list handler and it still works. Ask yourself
    why a conformant host would refuse to use it anyway. Look at what the
    initialize result reports under "capabilities".

HINTS
}

cmd_reset() {
    [ -f "$BROKEN_BASELINE" ] || die "no baseline saved; run '$0' from scratch"
    cp "$BROKEN_BASELINE" "$SERVER"
    printf '>>> server/mcp_echo_server.py restored to the broken starting state\n'
}

cmd_clean() {
    [ -f "$MARKER" ] || die "$LAB_ROOT does not look like this lab's sandbox; refusing to delete"
    rm -rf "$LAB_ROOT"
    printf '>>> removed %s\n' "$LAB_ROOT"
}

briefing() {
    cat <<BRIEF

========================================================================
 MCPA 1.1 - MCP Purpose & Scope | BREAK & FIX | exam weight 5.33
========================================================================

 SCENARIO
   A colleague "improved" the team's MCP server before going on holiday. The
   code still runs, the process stays up, no exception is raised, and the unit
   tests (which never speak the protocol) are green. But the assistant that
   consumes it now behaves as if the server did not exist.

 THE SYMPTOM YOU WILL SEE
   Run the grader and you get, in this order:

     [FAIL] 1. stdio framing        stdout carried a line that is not a
                                    JSON-RPC message: 'ready: reading ...'

   The very first check dies on the transport, so nothing after it can be
   judged. That is the realistic failure mode: in a real host the server shows
   up as "failed to connect" or "server disconnected" with no useful reason,
   because the host's JSON parser choked on the first line and gave up.
   Once you clear the transport, two further failures appear underneath it -
   they were always there, hidden behind the first one.

 YOUR OBJECTIVE
   Make all six checks pass:

     1. stdio framing            every line on stdout is a JSON-RPC message
     2. protocol revision        a revision this host supports is negotiated
     3. advertised capabilities  initialize offers the tools capability
     4. tools/list               'echo' is discoverable
     5. tools/call round trip    the text comes back unchanged
     6. lifecycle gate           pre-handshake requests are still refused

   Check 6 already passes. Do not break it while fixing the others: removing
   the initialize gate is not a fix, it is a fourth scope violation.

 RULES
   - Edit ONLY: $SERVER
   - Do not edit the grader (client/mcp_probe.py). It is the exam.
   - Do not delete checks, and do not make the server bypass the handshake.
   - Three edits are enough. Each one is a single line.

 COMMANDS
   $0 verify     re-run the grader (your feedback loop)
   $0 hint       progressive hints, no answers
   $0 reset      back to the broken starting state
   $0 clean      delete $LAB_ROOT

 FILES
   $SERVER
   $PROBE
   $SERVER_LOG   (the server's stderr - read it, it is where logs belong)

 EXAM ANGLE
   Every fault here is a sentence about scope. When you have fixed them, be
   able to say out loud: what does MCP own, and what does it explicitly hand
   back to the host application?

========================================================================
BRIEF
}

main() {
    case "${1:-all}" in
        all)
            cmd_setup
            cmd_break
            printf '\n>>> Post-break state (this is your starting point):\n'
            run_probe || true
            briefing
            ;;
        setup)  cmd_setup ;;
        break)  preflight; cmd_break; run_probe || true ;;
        verify) preflight; cmd_verify ;;
        hint)   cmd_hint ;;
        reset)  preflight; cmd_reset ;;
        clean)  cmd_clean ;;
        *)      die "unknown command: $1 (use: all|setup|break|verify|hint|reset|clean)" ;;
    esac
}

main "$@"

# ============================================================================
# ============================================================================
#  SOLUTION - stop reading if you have not finished the lab
# ============================================================================
# ============================================================================
#
#  STEP 0 - Reproduce, and read the failure in the right order
#  -----------------------------------------------------------
#      cd ~/mcpa-lab-1.1
#      ./mcpa-1.1-break-fix.sh verify
#
#  Expected (broken state):
#
#      [FAIL] 1. stdio framing        stdout carried a line that is not a JSON-RPC
#                                     message: 'ready: reading newline-delimited ...'
#      [FAIL] 2. protocol revision    not reached: the transport is unusable
#      [FAIL] 3. advertised capab...  not reached
#      [FAIL] 4. tools/list           not reached
#      [FAIL] 5. tools/call round...  not reached
#      [FAIL] 6. lifecycle gate       stdout carried a line that is not a JSON-RPC ...
#      0/6 checks passed
#
#  Diagnostic reflex for any stdio MCP server: the transport is the bottom of
#  the stack. Never chase a capability bug while the framing is broken - you
#  cannot see past it.
#
#
#  STEP 1 - FAULT 3 (transport scope): stdout is the protocol bus
#  --------------------------------------------------------------
#  Prove it by hand, exactly as a host would:
#
#      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand","version":"0"}}}' \
#        | python3 server/mcp_echo_server.py
#
#  Broken output (note the first line, which is not JSON):
#
#      ready: reading newline-delimited JSON-RPC from stdin
#      [server] initialize from {'name': 'hand', 'version': '0'}
#      {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "1.0", "capabilities": {}, "serverInfo": {...}}}
#
#  The "[server] ..." line is fine: it is on stderr, which is merged into your
#  terminal here but is a separate stream for the host. The bare "ready: ..."
#  line is on stdout, and it destroys the framing.
#
#  Fix - send the diagnostic to stderr, where the healthy code already sends
#  everything else:
#
#      sed -i 's/^    print("ready: reading newline-delimited JSON-RPC from stdin")$/    log("ready: reading newline-delimited JSON-RPC from stdin")/' \
#        server/mcp_echo_server.py
#
#  Verify that stdout is now clean (exactly one line, and it parses):
#
#      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand","version":"0"}}}' \
#        | python3 server/mcp_echo_server.py 2>/dev/null | python3 -m json.tool
#
#  Rule to memorise: on the stdio transport a server MUST NOT write anything to
#  stdout that is not a newline-delimited JSON-RPC message, and messages MUST
#  NOT contain embedded newlines. print() is the single most common way real
#  MCP servers die. See:
#  https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#
#  Re-run ./mcpa-1.1-break-fix.sh verify - now checks 1 and 6 pass, and the two
#  faults that were hidden behind the framing become visible.
#
#
#  STEP 2 - FAULT 1 (protocol scope): the revision is a date, not a semver
#  ----------------------------------------------------------------------
#  Now the grader can read the initialize result and says:
#
#      [FAIL] 2. protocol revision    server offered '1.0'; MCP revisions are dates
#                                     (YYYY-MM-DD) and this host supports:
#                                     2025-06-18, 2025-03-26, 2024-11-05
#
#  Version negotiation is inside MCP's scope: the client proposes a revision in
#  initialize, the server answers with the revision it will actually use, and if
#  the client cannot speak it the client MUST disconnect. "1.0" is not a
#  revision any host knows, so a conformant host drops the session here - which
#  looks, from the user's chair, exactly like "the server is broken".
#
#      sed -i 's/^PROTOCOL_VERSION = "1.0"$/PROTOCOL_VERSION = "2025-06-18"/' \
#        server/mcp_echo_server.py
#
#  Confirm what is negotiated:
#
#      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand","version":"0"}}}' \
#        | python3 server/mcp_echo_server.py 2>/dev/null \
#        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["protocolVersion"])'
#      2025-06-18
#
#  https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#
#
#  STEP 3 - FAULT 2 (contract scope): capabilities are the contract
#  ---------------------------------------------------------------
#  The remaining failure is the subtle one, and the reason this lab belongs to
#  "Purpose & Scope" rather than to a tools topic:
#
#      [FAIL] 3. advertised capabilities  initialize advertised {}: with no "tools"
#                                         capability a conformant host must never call
#                                         tools/list or tools/call ...
#
#  Nothing is wrong with the tool. tools/list still answers, tools/call still
#  echoes - the grader proves it, and says so ("reached only because the grader
#  ignores the contract"). A real host would never have asked. Capability
#  negotiation is how MCP keeps host and server independently versioned: the
#  server declares what it has, and the host restricts itself to that set.
#  Working code that is not advertised does not exist as far as the model is
#  concerned.
#
#      sed -i 's/^CAPABILITIES = {}$/CAPABILITIES = {"tools": {"listChanged": False}}/' \
#        server/mcp_echo_server.py
#
#  ("listChanged": False means: I will never send notifications/tools/list_changed,
#  so the host may cache my tool list for the session.)
#
#  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#
#
#  STEP 4 - Final verification
#  ---------------------------
#      ./mcpa-1.1-break-fix.sh verify
#
#      MCP conformance probe -> server/mcp_echo_server.py
#      --------------------------------------------------------------------
#      [ OK ] 1. stdio framing           the first stdout line parsed as JSON-RPC 2.0
#      [ OK ] 2. protocol revision       negotiated 2025-06-18
#      [ OK ] 3. advertised capabilities initialize advertised: tools
#      [ OK ] 4. tools/list              server exposes: echo
#      [ OK ] 5. tools/call round trip   text content returned unchanged
#      [ OK ] 6. lifecycle gate          pre-handshake request refused: server not
#                                        initialized: 'tools/list' arrived before
#                                        notifications/initialized
#      --------------------------------------------------------------------
#      6/6 checks passed
#
#
#  STEP 5 - The answer the exam actually wants
#  -------------------------------------------
#  Each fault was one sentence about the boundary:
#
#    transport      MCP owns the channel. On stdio that is stdout, exclusively,
#                   newline-delimited. Your logging is out of scope and goes to
#                   stderr (or to a file); on HTTP/SSE the equivalent rule is
#                   that only protocol events go on the event stream.
#
#    lifecycle      MCP owns version negotiation and session state: initialize,
#                   then notifications/initialized, then and only then normal
#                   operation. Your application does not invent its own
#                   handshake or its own version scheme.
#
#    capabilities   MCP owns the contract of what exists. A host may use only
#                   what was advertised. This is what lets any client talk to
#                   any server without prior knowledge of either - the actual
#                   purpose of the protocol.
#
#  And what MCP deliberately does NOT own, which is the other half of topic 1.1:
#  it does not run inference, does not choose which tool to invoke, does not
#  decide whether the caller is authorised for a business action, and does not
#  define the agent loop. The host application owns all of those. A question
#  that asks "which component decides to call the tool?" is answered by the
#  host, never by MCP.
#
#  Clean up the VM when done:
#      ./mcpa-1.1-break-fix.sh clean
# ============================================================================