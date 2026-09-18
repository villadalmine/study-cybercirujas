#!/usr/bin/env bash
#
# =============================================================================
#  MCPA — Model Context Protocol Associate (exam version 2026-07-28)
#  Domain 3, Topic 3.3: Tool Invocation Lifecycle  (exam weight 6.5)
#
#  BREAK & FIX LAB — "the server has two tools and the host can invoke none"
#
#  What this script does:
#    1. Builds a self-contained MCP stdio server (pure Python 3, no deps, no
#       network) plus a strict lifecycle driver that plays the role of the host.
#    2. Plants FIVE controlled faults, one per stage of the tool invocation
#       lifecycle: transport framing -> capability negotiation -> tool
#       discovery -> argument binding -> result and error shaping.
#    3. Hands you a verifier. You edit ONE file (server.py) until the verifier
#       reports a healthy lifecycle.
#
#  SAFETY: everything lives under a single disposable directory (default
#  ~/mcpa-lab-3.3). It installs nothing, opens no sockets, touches no system
#  file, needs no root and no internet. Intended for a throwaway lab VM.
#
#  Reference material:
#    - https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    - https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    - https://modelcontextprotocol.io/specification/2025-06-18/basic/index
#
#  The full step-by-step solution is at the bottom of this file, commented out.
#  Read it only after you have tried:  sed -n '/^# ==== SOLUTION/,$p' "$0"
# =============================================================================

set -euo pipefail

LAB_DIR="${MCPA_LAB_DIR:-$HOME/mcpa-lab-3.3}"
MARKER=".mcpa-lab-3.3"
ASSUME_YES=0
RESET=0

usage() {
    cat <<'USAGE'
Usage: break-and-fix-3.3.sh [--yes] [--reset] [--help]

  --yes     do not ask for interactive confirmation
  --reset   re-plant the faults in an existing lab directory (sandbox kept)
  --help    this text

Environment:
  MCPA_LAB_DIR   lab directory (default: $HOME/mcpa-lab-3.3)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1 ;;
        --reset)  RESET=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --- preflight ---------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || {
    echo "FATAL: python3 is required (3.8+). Install it and re-run." >&2
    exit 1
}
python3 - <<'PY' || { echo "FATAL: need Python 3.8 or newer." >&2; exit 1; }
import sys
sys.exit(0 if sys.version_info >= (3, 8) else 1)
PY

if [ -e "$LAB_DIR" ] && [ ! -e "$LAB_DIR/$MARKER" ]; then
    echo "FATAL: $LAB_DIR exists and is not a lab directory of this script." >&2
    echo "       Refusing to touch it. Set MCPA_LAB_DIR to a free path." >&2
    exit 1
fi

if [ -e "$LAB_DIR/$MARKER" ] && [ "$RESET" -eq 0 ]; then
    echo "NOTE: lab already present at $LAB_DIR"
    echo "      Re-run with --reset to plant the faults again from scratch."
    echo "      To verify your current fix:  $LAB_DIR/verify.sh"
    exit 0
fi

echo
echo "This lab writes only inside: $LAB_DIR"
echo "It installs nothing, needs no root and makes no network calls."
if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    printf 'Proceed? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# --- lay out the lab ---------------------------------------------------------

mkdir -p "$LAB_DIR/sandbox"
: > "$LAB_DIR/$MARKER"

cat > "$LAB_DIR/sandbox/welcome.txt" <<'NOTE'
lab note: MCPA-3.3-OK
The tool invocation lifecycle has five stages the host walks in order.
If any one of them lies about the others, the tool is simply not callable.
Fix server.py, never client.py.
NOTE

cat > "$LAB_DIR/sandbox/runbook.md" <<'NOTE'
# Runbook
tools/list is a contract. tools/call is the enforcement of that contract.
NOTE

# --- the MCP server: this is the ONLY file you are allowed to edit ------------

cat > "$LAB_DIR/server.py" <<'SERVER_PY'
#!/usr/bin/env python3
"""lab-fileops: a minimal MCP server over stdio (JSON-RPC 2.0, newline framed).

Implements the server half of the tool invocation lifecycle:
    initialize -> notifications/initialized -> tools/list -> tools/call

Two tools are exposed over a sandboxed directory. Something in here is wrong.
"""
import json
import os
import sys

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "lab-fileops", "version": "0.1.0"}

BASE = os.path.dirname(os.path.abspath(__file__))
SANDBOX = os.path.join(BASE, "sandbox")

print("lab-fileops: starting, sandbox=%s" % SANDBOX)

TOOLS = [
    {
        "name": "read_note",
        "title": "Read a note",
        "description": "Read a UTF-8 text note from the lab sandbox.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Note file name, relative to the sandbox.",
                }
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    {
        "name": "count_lines",
        "title": "Count lines",
        "description": "Count the lines of a note in the lab sandbox.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Note file name, relative to the sandbox.",
                }
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
]


def log(text):
    """Diagnostics channel. On stdio transport, stderr is the only safe one."""
    sys.stderr.write("[server] %s\n" % text)
    sys.stderr.flush()


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def result(message_id, payload):
    return {"jsonrpc": "2.0", "id": message_id, "result": payload}


def error(message_id, code, message):
    return {"jsonrpc": "2.0", "id": message_id,
            "error": {"code": code, "message": message}}


def safe_path(name):
    """Keep every tool call inside the sandbox. Do not weaken this."""
    root = os.path.realpath(SANDBOX)
    candidate = os.path.realpath(os.path.join(root, name))
    if candidate != root and not candidate.startswith(root + os.sep):
        raise ValueError("path escapes the sandbox: %r" % name)
    return candidate


def tool_read_note(arguments):
    target = safe_path(arguments["file_path"])
    with open(target, "r", encoding="utf-8") as handle:
        text = handle.read()
    return {"content": [{"type": "text", "text": text}], "isError": False}


def tool_count_lines(arguments):
    target = safe_path(arguments["path"])
    with open(target, "r", encoding="utf-8") as handle:
        total = sum(1 for _ in handle)
    return {"content": "%d" % total}


HANDLERS = {
    "read_note": tool_read_note,
    "count_lines": tool_count_lines,
}


def handle_initialize(params):
    log("initialize from %s" % (params.get("clientInfo") or {}).get("name"))
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {
            "logging": {},
        },
        "serverInfo": SERVER_INFO,
    }


def handle(message):
    method = message.get("method")
    message_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        return result(message_id, handle_initialize(params))

    if method == "notifications/initialized":
        log("client finished the handshake")
        return None

    if method == "ping":
        return result(message_id, {})

    if method == "tools/list":
        return result(message_id, {"tools": TOOLS})

    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        handler = HANDLERS.get(name)
        if handler is None:
            return error(message_id, -32602, "unknown tool: %r" % name)
        log("tools/call %s %s" % (name, json.dumps(arguments)))
        try:
            return result(message_id, handler(arguments))
        except Exception as exc:
            return error(message_id, -32603, "tool failed: %s" % exc)

    if message_id is None:
        return None
    return error(message_id, -32601, "method not found: %r" % method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            send(error(None, -32700, "parse error: %s" % exc))
            continue
        reply = handle(message)
        if reply is not None:
            send(reply)


if __name__ == "__main__":
    main()
SERVER_PY

# --- the host: DO NOT EDIT. It is the exam. -----------------------------------

cat > "$LAB_DIR/client.py" <<'CLIENT_PY'
#!/usr/bin/env python3
"""Strict MCP host: drives the full tool invocation lifecycle over stdio.

Every check below maps to one stage of the lifecycle. This file is the
specification made executable - do not edit it, fix server.py instead.
"""
import json
import os
import select
import subprocess
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(BASE, "server.py")
SANDBOX = os.path.join(BASE, "sandbox")
PROTOCOL_VERSION = "2025-06-18"
READ_TIMEOUT = 10.0

FAILURES = []


def ok(stage, text):
    print("  [ ok ] %-10s %s" % (stage, text))


def fail(stage, text):
    FAILURES.append((stage, text))
    print("  [FAIL] %-10s %s" % (stage, text))


def warn(stage, text):
    print("  [warn] %-10s %s  (bonus, not required)" % (stage, text))


def die(stage, symptom):
    print("")
    print("SYMPTOM ---------------------------------------------------------")
    print(symptom)
    print("")
    print("The lifecycle stopped at stage '%s'. Later stages never ran." % stage)
    print("Fix server.py and re-run ./verify.sh")
    sys.exit(1)


class Noise(Exception):
    """Something that is not a JSON-RPC message arrived on the wire."""


class Hang(Exception):
    """No reply, or the server died."""


class Server(object):
    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, "-u", SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        self._id = 0

    def _write(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def request(self, method, params=None):
        self._id += 1
        self._write({"jsonrpc": "2.0", "id": self._id,
                     "method": method, "params": params or {}})
        return self._read()

    def _read(self):
        while True:
            ready, _, _ = select.select([self.proc.stdout], [], [], READ_TIMEOUT)
            if not ready:
                raise Hang("no reply within %.0fs" % READ_TIMEOUT)
            line = self.proc.stdout.readline()
            if line == "":
                raise Hang("server closed stdout (exit code %s)" % self.proc.poll())
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                raise Noise(line)

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def check_arguments(schema, arguments):
    """What a conformant host does before it puts anything on the wire."""
    problems = []
    schema = schema or {}
    properties = schema.get("properties") or {}
    for key in schema.get("required") or []:
        if key not in arguments:
            problems.append("missing required argument %r" % key)
    if schema.get("additionalProperties") is False:
        for key in arguments:
            if key not in properties:
                problems.append("argument %r is not declared in the schema" % key)
    return problems


def text_of(payload):
    blocks = payload.get("content")
    if not isinstance(blocks, list):
        return None
    parts = []
    for block in blocks:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text") or "")
    return "\n".join(parts)


def run(srv):
    print("")
    print("=== stage 1/5: initialize (handshake) ===========================")
    try:
        reply = srv.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "mcpa-lab-host", "version": "1.0.0"},
        })
    except Noise as exc:
        fail("transport", "first line on stdout is not JSON-RPC: %s" % str(exc)[:90])
        die("transport",
            "The host reads newline-delimited JSON-RPC from the server's stdout\n"
            "and the very first line it got was human prose. On the stdio\n"
            "transport stdout IS the wire: one stray byte desynchronises the\n"
            "whole session and no tool can ever be invoked.\n"
            "GOAL: make the server's stdout carry MCP messages and nothing else.")
    except Hang as exc:
        fail("transport", str(exc))
        die("transport", "The server never answered initialize.")

    if "error" in reply:
        fail("handshake", "initialize returned an error: %s" % reply["error"])
        die("handshake", "The session cannot start.")

    payload = reply.get("result") or {}
    if payload.get("protocolVersion") != PROTOCOL_VERSION:
        fail("handshake", "protocolVersion is %r, host speaks %r"
             % (payload.get("protocolVersion"), PROTOCOL_VERSION))
    else:
        ok("handshake", "protocolVersion %s agreed" % PROTOCOL_VERSION)

    info = payload.get("serverInfo") or {}
    if info.get("name"):
        ok("handshake", "serverInfo: %s %s" % (info.get("name"), info.get("version")))
    else:
        fail("handshake", "initialize result carries no serverInfo.name")

    srv.notify("notifications/initialized")
    ok("handshake", "notifications/initialized sent")

    print("")
    print("=== stage 2/5: capability negotiation ===========================")
    capabilities = payload.get("capabilities") or {}
    print("        server declared capabilities: %s" % (sorted(capabilities) or "[]"))
    if "tools" not in capabilities:
        fail("capability", "no 'tools' object in the declared capabilities")
        die("capability",
            "The handshake succeeded, yet the server never declares that it\n"
            "offers tools. A conformant host therefore does NOT call\n"
            "tools/list, and the user is told 'this server exposes no tools'\n"
            "even though server.py defines two of them and would answer\n"
            "tools/list perfectly well if asked.\n"
            "GOAL: make the server advertise the tools capability at initialize.")
    ok("capability", "tools capability advertised: %s" % json.dumps(capabilities["tools"]))

    print("")
    print("=== stage 3/5: tool discovery (tools/list) ======================")
    reply = srv.request("tools/list")
    if "error" in reply:
        fail("discovery", "tools/list returned %s" % reply["error"])
        die("discovery", "The host cannot build its tool catalogue.")
    tools = (reply.get("result") or {}).get("tools")
    if not isinstance(tools, list) or not tools:
        fail("discovery", "tools/list returned no tool array")
        die("discovery", "Empty catalogue: nothing is callable.")
    catalogue = {}
    for tool in tools:
        name = tool.get("name")
        schema = tool.get("inputSchema")
        if not name or not isinstance(schema, dict) or schema.get("type") != "object":
            fail("discovery", "malformed tool entry: %s" % json.dumps(tool)[:90])
            continue
        catalogue[name] = tool
        ok("discovery", "%-12s required=%s" % (name, schema.get("required")))
    for expected in ("read_note", "count_lines"):
        if expected not in catalogue:
            fail("discovery", "tool %r missing from the catalogue" % expected)
            die("discovery", "The catalogue is incomplete.")

    print("")
    print("=== stage 4/5: invocation, happy path (tools/call) =============")
    schema = catalogue["read_note"]["inputSchema"]
    arguments = {"path": "welcome.txt"}
    problems = check_arguments(schema, arguments)
    if problems:
        fail("binding", "host-side validation refused the call: %s" % problems)
        die("binding", "The host will not send arguments its schema rejects.")
    ok("binding", "arguments %s validate against the declared schema" % arguments)

    reply = srv.request("tools/call", {"name": "read_note", "arguments": arguments})
    if "error" in reply:
        err = reply["error"]
        fail("invocation", "tools/call -> JSON-RPC error %s: %s"
             % (err.get("code"), err.get("message")))
        die("invocation",
            "tools/list advertises read_note with a required argument named\n"
            "'path'. The host sent exactly that - and the call blew up inside\n"
            "the server. The catalogue and the handler disagree about the\n"
            "argument contract, so the tool is undialable by any host that\n"
            "trusts the schema, which is every host.\n"
            "GOAL: make the handler bind the argument the schema promises,\n"
            "      then look again at HOW that failure was reported.")
    payload = reply.get("result") or {}
    body = text_of(payload)
    if body is None:
        fail("invocation", "result.content is %r, expected a list of content blocks"
             % type(payload.get("content")).__name__)
    elif "MCPA-3.3-OK" not in body:
        fail("invocation", "content does not carry the note text")
    else:
        ok("invocation", "read_note returned %d chars of text content" % len(body))
    if payload.get("isError"):
        fail("invocation", "a successful call is flagged isError=true")
    else:
        ok("invocation", "isError is false on the success path")

    print("")
    print("=== stage 5/5: error semantics and result shape =================")
    reply = srv.request("tools/call",
                        {"name": "read_note", "arguments": {"path": "does-not-exist.txt"}})
    if "error" in reply:
        fail("errors", "a failing TOOL was reported as a PROTOCOL error %s: %s"
             % (reply["error"].get("code"), reply["error"].get("message")))
        print("        the model never sees a JSON-RPC error - the host swallows it,")
        print("        so the agent cannot read the failure, explain it or retry.")
    else:
        payload = reply.get("result") or {}
        body = text_of(payload)
        if payload.get("isError") is True and body:
            ok("errors", "tool failure returned as result with isError=true")
        else:
            fail("errors", "expected result{isError:true, content:[...]}, got %s"
                 % json.dumps(payload)[:90])

    reply = srv.request("tools/call", {"name": "no_such_tool", "arguments": {}})
    if "error" in reply:
        ok("errors", "unknown tool is a protocol error %s" % reply["error"].get("code"))
    else:
        fail("errors", "an unknown tool must be a JSON-RPC error, not a result")

    expected_lines = sum(1 for _ in open(os.path.join(SANDBOX, "welcome.txt")))
    reply = srv.request("tools/call",
                        {"name": "count_lines", "arguments": {"path": "welcome.txt"}})
    if "error" in reply:
        fail("shape", "count_lines -> JSON-RPC error %s" % reply["error"].get("code"))
    else:
        payload = reply.get("result") or {}
        body = text_of(payload)
        if body is None:
            fail("shape", "count_lines result.content is %r, not a list of blocks"
                 % payload.get("content"))
            print("        the host cannot render this: content MUST be an array of")
            print("        typed blocks, even when the answer is a single number.")
        elif body.strip() != str(expected_lines):
            fail("shape", "count_lines said %r, sandbox/welcome.txt has %d lines"
                 % (body.strip(), expected_lines))
        else:
            ok("shape", "count_lines returned %s as a text block" % body.strip())

    reply = srv.request("tools/call", {"name": "count_lines", "arguments": {}})
    if "error" in reply and reply["error"].get("code") == -32602:
        ok("errors", "missing required argument rejected as -32602")
    else:
        warn("errors", "a call missing a required argument should be -32602 "
                       "invalid params")


def main():
    print("MCPA 3.3 - tool invocation lifecycle verifier")
    srv = Server()
    try:
        run(srv)
    finally:
        srv.close()
    print("")
    if FAILURES:
        print("VERDICT: %d check(s) failing. The lifecycle is still broken."
              % len(FAILURES))
        for stage, text in FAILURES:
            print("   - [%s] %s" % (stage, text))
        sys.exit(1)
    print("VERDICT: initialize -> initialized -> tools/list -> tools/call all")
    print("         conform. Lab solved.")
    sys.exit(0)


if __name__ == "__main__":
    main()
CLIENT_PY

cat > "$LAB_DIR/verify.sh" <<'VERIFY_SH'
#!/usr/bin/env bash
# Run the lifecycle verifier. Exit 0 only when every stage conforms.
set -uo pipefail
cd "$(dirname "$0")"
if ! python3 -m py_compile server.py; then
    echo "server.py does not even compile - fix the syntax first." >&2
    exit 2
fi
rm -rf __pycache__
python3 client.py
VERIFY_SH
chmod +x "$LAB_DIR/verify.sh"
chmod +x "$LAB_DIR/server.py" "$LAB_DIR/client.py"

cat > "$LAB_DIR/MISSION.txt" <<MISSION
MCPA 3.3 - TOOL INVOCATION LIFECYCLE - BREAK & FIX
==================================================

THE SCENE
  lab-fileops is an MCP server exposing two tools over a sandbox directory:
  read_note and count_lines. The code that does the actual work is correct:
  both handlers open the right file and compute the right answer. And yet
  no MCP host on earth can successfully invoke either of them.

  The bugs are not in the business logic. They are in the five stages the
  host and the server walk together every time a model decides to call a
  tool:

      1. transport framing      what is allowed on stdout
      2. capability negotiation what the server says it can do
      3. tool discovery         the schema published by tools/list
      4. argument binding       the handler honouring that schema
      5. result and error shape content blocks, isError, protocol errors

YOUR GOAL
  Edit ONLY \$LAB_DIR/server.py until this prints a clean verdict:

      $LAB_DIR/verify.sh

  Success looks like:
      VERDICT: initialize -> initialized -> tools/list -> tools/call all
               conform. Lab solved.

RULES
  - Do not edit client.py. It is the host, and the host is the exam.
  - Do not edit sandbox/. The content is the fixture.
  - Do not weaken safe_path(). A tool that escapes its sandbox is a finding,
    not a fix.
  - Fix the faults one at a time and re-run the verifier after each: the
    lifecycle is sequential, so each fix reveals the next symptom.

HOW TO WATCH THE WIRE
  The server logs to stderr, so you can see both sides at once:

      cd $LAB_DIR && python3 client.py

  To inspect a single exchange by hand, feed the server raw JSON-RPC:

      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | python3 server.py

RESET
  Re-run the lab script with --reset to restore the broken server.
MISSION

# --- show the first symptom ---------------------------------------------------

cat <<BANNER

=============================================================================
 LAB READY: $LAB_DIR
=============================================================================
 files:
   server.py    the MCP server         <- the ONLY file you may edit
   client.py    the MCP host / grader  <- do not touch
   verify.sh    run the grader
   sandbox/     fixture notes
   MISSION.txt  the full briefing

 Five faults are planted, one per lifecycle stage:
   transport framing, capability negotiation, tool discovery contract,
   argument binding, result & error shaping.

 Running the verifier now to show you symptom #1:
=============================================================================
BANNER

"$LAB_DIR/verify.sh" || true

cat <<BANNER

=============================================================================
 WHAT YOU MUST ACHIEVE
=============================================================================
 Make $LAB_DIR/verify.sh exit 0, editing server.py only.

 When it is solved the verifier prints, in order:
   - protocolVersion 2025-06-18 agreed, serverInfo present
   - tools capability advertised
   - read_note and count_lines discovered with required=['path']
   - read_note returns text content, isError false
   - a missing file returns result{isError:true}, NOT a JSON-RPC error
   - an unknown tool DOES return a JSON-RPC error
   - count_lines returns the line count as a text block

 Hints, in increasing order of spoiler:
   1. Run  python3 server.py </dev/null  and look at what lands on stdout.
   2. Read the initialize result: does the host have any reason to call
      tools/list?
   3. Diff the inputSchema of read_note against the handler's first line.
   4. There are two kinds of failure in MCP. Which one is "the file does not
      exist", and which one is "there is no such tool"?
   5. What is the declared type of the 'content' field of a tools/call result?

 Solution (read after trying):
     sed -n '/^# ==== SOLUTION/,\$p' "$0"
=============================================================================

BANNER

exit 0

# =============================================================================
# ==== SOLUTION - step by step ================================================
# =============================================================================
#
# There are five faults, one per stage. Fix them in order; each fix makes the
# verifier advance one stage further, which is the point of the exercise: the
# tool invocation lifecycle is a chain, and a host can only observe the first
# broken link.
#
# -----------------------------------------------------------------------------
# FAULT 1 - transport framing: prose on stdout
# -----------------------------------------------------------------------------
# Symptom: "first line on stdout is not JSON-RPC: lab-fileops: starting, ..."
#          The host cannot parse the reply to initialize; the session never
#          begins.
#
# Location: server.py, module level, just under SANDBOX = ...
#
#     print("lab-fileops: starting, sandbox=%s" % SANDBOX)
#
# Why it is fatal: on the stdio transport the server's stdout is the message
# stream itself - newline-delimited JSON-RPC, one message per line, nothing
# else. The spec is explicit that the server MUST NOT write anything to stdout
# that is not a valid MCP message, and that it MAY write freely to stderr.
# Any library, any host, any language: a banner, a warning, a stray print() in
# a handler, a progress bar - all of them desynchronise the stream.
#
# Fix: delete the line, or route it to the diagnostics channel that already
# exists in the file:
#
#     -print("lab-fileops: starting, sandbox=%s" % SANDBOX)
#
# or, if you want to keep the message:
#
#     +log("starting, sandbox=%s" % SANDBOX)
#
# (log() writes to stderr, which is exactly what stderr is for. Note it must
# be defined before the call if you move it to module level - simplest is to
# put the log() call as the first statement inside main().)
#
# Ref: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#
# -----------------------------------------------------------------------------
# FAULT 2 - capability negotiation: the server never declares "tools"
# -----------------------------------------------------------------------------
# Symptom: the handshake succeeds, the verifier prints
#          "server declared capabilities: ['logging']" and stops with
#          "no 'tools' object in the declared capabilities".
#
# Location: server.py, handle_initialize()
#
#     "capabilities": {
#         "logging": {},
#     },
#
# Why it is fatal: initialize is a negotiation, not a formality. Each side
# declares what it supports, and from that moment on neither is allowed to use
# what the other did not declare. A host that never sees a "tools" object has
# no reason to issue tools/list - so the two perfectly good handlers below are
# dead code, and the user is told the server has no tools. This is the single
# most common "my tools do not show up" bug in the field, and it is invisible
# in the server logs because nothing fails: the request simply never arrives.
#
# Fix:
#
#     "capabilities": {
#         "logging": {},
#         "tools": {"listChanged": False},
#     },
#
# "listChanged": False means "my catalogue is static, I will never send
# notifications/tools/list_changed". Declare True only if you actually emit
# that notification when the catalogue changes - declaring a capability you do
# not honour is the mirror image of this same bug.
#
# Ref: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#
# -----------------------------------------------------------------------------
# FAULT 3 - argument binding: the handler ignores its own published schema
# -----------------------------------------------------------------------------
# Symptom: tools/list advertises read_note with required=['path'], the host
#          sends {"path": "welcome.txt"}, and the call comes back as
#          "JSON-RPC error -32603: tool failed: 'file_path'".
#
# Location: server.py, tool_read_note()
#
#     target = safe_path(arguments["file_path"])
#
# Why it is fatal: inputSchema is a contract, and it is the ONLY thing the
# model sees. The LLM chooses arguments from that JSON Schema; the host
# validates against that JSON Schema; the handler is the one party that can
# quietly disagree with it. When it does, the tool is undialable - no amount
# of prompting will make the model guess an argument name that is not
# published. This is why the schema and the handler signature must be
# generated from one source of truth (a decorator, a dataclass, a codegen
# step) in any server you ship.
#
# Fix:
#
#     -    target = safe_path(arguments["file_path"])
#     +    target = safe_path(arguments["path"])
#
# -----------------------------------------------------------------------------
# FAULT 4 - error semantics: tool failures reported as protocol errors
# -----------------------------------------------------------------------------
# Symptom: with fault 3 fixed, the happy path works; then
#          read_note("does-not-exist.txt") comes back as
#          "a failing TOOL was reported as a PROTOCOL error -32603".
#
# Location: server.py, handle(), the tools/call branch
#
#     try:
#         return result(message_id, handler(arguments))
#     except Exception as exc:
#         return error(message_id, -32603, "tool failed: %s" % exc)
#
# Why it matters: MCP splits failure into two categories on purpose.
#
#   * PROTOCOL errors - JSON-RPC error objects: the request itself is
#     invalid. Unknown tool (-32602), malformed params (-32602), unknown
#     method (-32601), server bug (-32603). These are consumed by the HOST.
#     The model never sees them.
#   * TOOL errors - a normal result with "isError": true and the explanation
#     inside the content blocks: the request was valid, the execution failed.
#     "File not found", "HTTP 503 from upstream", "permission denied".
#     These are handed to the MODEL, which is the whole point: the agent reads
#     the message, corrects the path, and retries.
#
# Collapsing the second into the first turns a recoverable situation into a
# dead end for the agent, and it is how you end up with a model that loops on
# the same broken call because it was never told why it failed.
#
# Fix - keep the unknown-tool check OUTSIDE the try (it is a protocol error),
# and convert execution failures into an isError result:
#
#         handler = HANDLERS.get(name)
#         if handler is None:
#             return error(message_id, -32602, "unknown tool: %r" % name)
#         log("tools/call %s %s" % (name, json.dumps(arguments)))
#         try:
#             return result(message_id, handler(arguments))
#         except Exception as exc:
#             return result(message_id, {
#                 "content": [{
#                     "type": "text",
#                     "text": "%s failed: %s: %s" % (name, type(exc).__name__, exc),
#                 }],
#                 "isError": True,
#             })
#
# Note the verifier still requires that an UNKNOWN tool stays a JSON-RPC
# error: that check is what catches an over-correction that wraps everything.
#
# Ref: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#      (section "Error Handling")
#
# -----------------------------------------------------------------------------
# FAULT 5 - result shape: content is not a list of content blocks
# -----------------------------------------------------------------------------
# Symptom: "count_lines result.content is '4', not a list of blocks".
#
# Location: server.py, tool_count_lines()
#
#     return {"content": "%d" % total}
#
# Why it is fatal: the result of tools/call is
#
#     { "content": [ <content block>, ... ], "isError": <bool>, ... }
#
# content is ALWAYS an array of typed blocks - text, image, audio, resource,
# resource_link - even when the answer is a single number. A bare string
# type-checks nowhere: strict hosts reject the message, lenient ones render
# nothing, and the model receives an empty tool result with no error to
# explain it. Same trap as returning a bare dict "because it is JSON".
#
# Fix:
#
#     -    return {"content": "%d" % total}
#     +    return {
#     +        "content": [{"type": "text", "text": "%d" % total}],
#     +        "isError": False,
#     +    }
#
# If you also want machine-readable output, 2025-06-18 adds structuredContent
# alongside (not instead of) content, and outputSchema on the tool definition
# to describe it:
#
#          return {
#              "content": [{"type": "text", "text": "%d" % total}],
#              "structuredContent": {"lines": total},
#              "isError": False,
#          }
#
# The text block stays: it is the backwards-compatible channel every host can
# render.
#
# -----------------------------------------------------------------------------
# BONUS (the [warn] line) - validate arguments server-side
# -----------------------------------------------------------------------------
# A call that omits a required argument currently reaches the handler and
# raises a KeyError, which after fault 4 becomes an isError result. The spec
# treats invalid arguments as a PROTOCOL error: the request was malformed, not
# the execution. Never trust the host to have validated - it may be buggy, or
# not the only client you will ever have.
#
#     def validate(tool, arguments):
#         schema = tool["inputSchema"]
#         for key in schema.get("required", []):
#             if key not in arguments:
#                 raise ValueError("missing required argument %r" % key)
#         if schema.get("additionalProperties") is False:
#             for key in arguments:
#                 if key not in schema["properties"]:
#                     raise ValueError("unexpected argument %r" % key)
#
# and in the tools/call branch, before the try:
#
#         spec = next((t for t in TOOLS if t["name"] == name), None)
#         try:
#             validate(spec, arguments)
#         except ValueError as exc:
#             return error(message_id, -32602, "invalid params: %s" % exc)
#
# In a real server use a JSON Schema library (jsonschema, pydantic) rather
# than hand-rolling this.
#
# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
#     ~/mcpa-lab-3.3/verify.sh; echo "exit=$?"
#
# Expected tail:
#     VERDICT: initialize -> initialized -> tools/list -> tools/call all
#              conform. Lab solved.
#     exit=0
#
# -----------------------------------------------------------------------------
# EXAM TAKEAWAYS - the lifecycle as a chain of contracts
# -----------------------------------------------------------------------------
#  1. stdio transport: stdout is the wire, stderr is for humans. One print()
#     kills a session.
#  2. initialize: capabilities are a promise. Undeclared means unusable;
#     declared-but-not-implemented is equally broken.
#  3. notifications/initialized: sent by the client after it receives the
#     initialize result, before any other request. It is a notification, so it
#     carries no id and MUST NOT be answered.
#  4. tools/list: inputSchema is the only description the model gets. It is a
#     contract with the handler, not documentation.
#  5. tools/call: the handler binds exactly the published names; the result is
#     content blocks; execution failures are isError results for the model;
#     malformed requests are JSON-RPC errors for the host.
#
# Sources:
#   https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#   https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#   https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#   https://modelcontextprotocol.io/specification/2025-06-18/server/tools
# =============================================================================