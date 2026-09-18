#!/usr/bin/env bash
#
# MCPA 3.4 - Protocol Primitives - break & fix lab
#
# Exam: MCPA (Model Context Protocol Associate), version 2026-07-28
# Topic 3.4 - Protocol Primitives (exam weight 6.5)
#
# WHAT THIS SCRIPT DOES
#   It plants a small, self-contained MCP server in a disposable lab
#   directory. The server speaks JSON-RPC 2.0 over the stdio transport and
#   advertises the three server primitives - tools, resources, prompts -
#   plus the lifecycle handshake. It is deliberately non-conformant in
#   seven places spread over four areas of the protocol. A conformance
#   checker reports the symptoms; the student repairs server.py.
#
# SAFETY
#   Nothing outside the lab directory is touched: no package is installed,
#   no service is started or stopped, no port is opened, no file outside
#   $MCP_LAB_DIR is written, and --clean only removes a directory that
#   carries this lab's marker file. Python 3 standard library only.
#   Still, run it on a disposable lab VM, as a normal user.
#
# OFFICIAL SOURCES
#   https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#   https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#   https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#   https://modelcontextprotocol.io/specification/2025-06-18/server/resources
#   https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
#   https://www.jsonrpc.org/specification
#
set -euo pipefail

LAB_DIR="${MCP_LAB_DIR:-$HOME/mcpa-lab-3.4}"
MARKER_FILE=".mcpa-lab-3.4"
SELF="${BASH_SOURCE[0]}"

usage() {
    cat <<EOF_USAGE
usage: $(basename "$0") [setup|verify|reset|clean|solution]

  setup      (default) create the lab and print the briefing
  verify     run the protocol conformance checker
  reset      restore the broken server, discarding your edits
  clean      remove the lab directory (only if it carries the lab marker)
  solution   print the commented step-by-step solution

environment:
  MCP_LAB_DIR   lab directory (default: \$HOME/mcpa-lab-3.4)
EOF_USAGE
}

require_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "error: python3 is required and was not found in PATH" >&2
        exit 1
    fi
    python3 - <<'EOF_PYCHECK'
import sys
if sys.version_info < (3, 9):
    sys.exit("error: python 3.9+ is required for this lab")
EOF_PYCHECK
}

warn_if_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        echo "warning: running as root. This lab needs no privileges; a normal user is safer." >&2
    fi
}

write_server() {
    cat >"$LAB_DIR/server.py" <<'EOF_SERVER'
#!/usr/bin/env python3
"""
mcp-lab-primitives - a minimal MCP server on the stdio transport.

One JSON-RPC 2.0 message per line on stdin/stdout. It opens no socket and
writes no file: shutil.disk_usage() is the only syscall that leaves the
process. Intended for a disposable lab VM.
"""
import json
import shutil
import sys

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "mcp-lab-primitives", "version": "0.3.4"}


class ToolFailure(Exception):
    """Raised by a tool implementation when the work itself fails."""


TOOLS = [
    {
        "name": "disk_usage",
        "title": "Disk usage",
        "description": "Report total, used and free bytes for a mounted filesystem path.",
        "inputSchema": {
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute path of a mount point, for example /var.",
                }
            },
            "required": ["path"],
        },
    },
    {
        "name": "echo_context",
        "title": "Echo context",
        "description": "Echo a short string back to the caller, for transport checks.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Text to echo back."}
            },
            "required": ["text"],
        },
    },
]

RESOURCES = {
    "lab://inventory/nodes.json": {
        "name": "cluster-inventory",
        "title": "Lab cluster inventory",
        "description": "Static node inventory used by the lab exercises.",
        "mimeType": "application/json",
        "text": json.dumps(
            {
                "nodes": [
                    {"name": "node-a", "role": "control-plane", "zone": "eu-central-1a"},
                    {"name": "node-b", "role": "worker", "zone": "eu-central-1b"},
                ]
            },
            indent=2,
        ),
    },
    "lab://runbook/failover.md": {
        "name": "failover-runbook",
        "title": "Failover runbook",
        "description": "First-pass failover procedure for the lab service.",
        "mimeType": "text/markdown",
        "text": (
            "# Failover runbook\n\n"
            "1. Confirm the symptom against the dashboard, not against the alert.\n"
            "2. Drain the affected node before you cordon anything else.\n"
            "3. Fail over only after the replica reports a caught-up log offset.\n"
        ),
    },
}

PROMPTS = [
    {
        "name": "triage_incident",
        "title": "Triage an incident",
        "description": "Walk an on-call engineer through a first-pass incident triage.",
        "arguments": [
            {
                "name": "service",
                "description": "Name of the service showing the symptom.",
                "required": True,
            },
            {
                "name": "severity",
                "description": "Declared severity, sev1 through sev4.",
                "required": False,
            },
        ],
    }
]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(request_id, payload):
    send({"jsonrpc": "2.0", "id": request_id, "result": payload})


def fail(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def impl_disk_usage(arguments):
    path = arguments.get("path")
    if not isinstance(path, str) or not path:
        raise ToolFailure("disk_usage: 'path' is required and must be a string")
    try:
        usage = shutil.disk_usage(path)
    except OSError as exc:
        raise ToolFailure("disk_usage: cannot stat %s: %s" % (path, exc))
    gib = 1024 ** 3
    return (
        "%s\n  total %.1f GiB\n  used  %.1f GiB\n  free  %.1f GiB"
        % (path, usage.total / gib, usage.used / gib, usage.free / gib)
    )


def impl_echo_context(arguments):
    text = arguments.get("text")
    if not isinstance(text, str):
        raise ToolFailure("echo_context: 'text' is required and must be a string")
    return text


TOOL_IMPLS = {
    "disk_usage": impl_disk_usage,
    "echo_context": impl_echo_context,
}


def call_tool(name, arguments):
    """Return a tools/call result payload, or None if the tool is unknown."""
    handler = TOOL_IMPLS.get(name)
    if handler is None:
        return None
    try:
        text = handler(arguments)
    except ToolFailure as exc:
        return {"content": [{"type": "text", "text": str(exc)}], "isError": True}
    return {"output": text}


def resource_descriptors():
    return [
        {
            "uri": uri,
            "name": entry["name"],
            "title": entry["title"],
            "description": entry["description"],
            "mimeType": entry["mimeType"],
        }
        for uri, entry in RESOURCES.items()
    ]


def dispatch(message):
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        reply(
            request_id,
            {
                "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
                "capabilities": {
                    "tools": {"listChanged": False},
                    "resources": {"subscribe": False, "listChanged": False},
                    "prompts": {"listChanged": False},
                },
                "serverInfo": SERVER_INFO,
            },
        )
        return

    if method == "notifications/initialized":
        reply(request_id, {})
        return

    if method == "ping":
        reply(request_id, {})
        return

    if method == "tools/list":
        reply(request_id, {"tools": TOOLS})
        return

    if method == "tools/call":
        name = params.get("name")
        outcome = call_tool(name, params.get("arguments") or {})
        if outcome is None:
            fail(request_id, -32602, "unknown tool: %s" % name)
            return
        reply(request_id, outcome)
        return

    if method == "resource/list":
        reply(request_id, {"resources": resource_descriptors()})
        return

    if method == "resources/read":
        uri = params.get("uri")
        entry = RESOURCES.get(uri)
        if entry is None:
            fail(request_id, -32002, "resource not found: %s" % uri)
            return
        reply(
            request_id,
            {"contents": [{"mimeType": entry["mimeType"], "text": entry["text"]}]},
        )
        return

    if method == "prompts/list":
        reply(request_id, {"prompts": PROMPTS})
        return

    if method == "prompts/get":
        name = params.get("name")
        spec = None
        for candidate in PROMPTS:
            if candidate["name"] == name:
                spec = candidate
                break
        if spec is None:
            fail(request_id, -32602, "unknown prompt: %s" % name)
            return
        arguments = params.get("arguments") or {}
        missing = [
            argument["name"]
            for argument in spec["arguments"]
            if argument.get("required") and not arguments.get(argument["name"])
        ]
        if missing:
            fail(
                request_id,
                -32602,
                "missing required prompt arguments: %s" % ", ".join(missing),
            )
            return
        service = arguments["service"]
        severity = arguments.get("severity", "sev3")
        reply(
            request_id,
            {
                "description": spec["description"],
                "messages": [
                    {
                        "role": "system",
                        "content": "You are an SRE on call. Be concise and cite evidence.",
                    },
                    {
                        "role": "user",
                        "content": (
                            "Triage %s, declared %s. State the blast radius, the first "
                            "three commands you would run, and the rollback you would "
                            "prepare before touching anything." % (service, severity)
                        ),
                    },
                ],
            },
        )
        return

    if request_id is not None:
        fail(request_id, -32601, "method not found: %s" % method)


def main():
    while True:
        line = sys.stdin.readline()
        if not line:
            return 0
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": "parse error: %s" % exc},
                }
            )
            continue
        dispatch(message)


if __name__ == "__main__":
    sys.exit(main())
EOF_SERVER
    chmod +x "$LAB_DIR/server.py"
}

write_verifier() {
    cat >"$LAB_DIR/verify.py" <<'EOF_VERIFY'
#!/usr/bin/env python3
"""
Protocol conformance checker for the MCPA 3.4 lab server.

Acts as an MCP client: spawns server.py on stdio, runs the lifecycle
handshake and then exercises every declared primitive, asserting the
wire shapes the specification requires. Exits 0 only when every check
passes.
"""
import json
import os
import select
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")
CLIENT_PROTOCOL = "2025-06-18"
KNOWN_VERSIONS = {"2024-11-05", "2025-03-26", "2025-06-18"}
BOGUS_VERSION = "1999-01-01"
FALLBACK_RESOURCE = "lab://inventory/nodes.json"

if sys.stdout.isatty():
    GREEN, RED, DIM, RESET = "\033[32m", "\033[31m", "\033[2m", "\033[0m"
else:
    GREEN = RED = DIM = RESET = ""

CHECKS = []


def check(ok, name, detail=""):
    ok = bool(ok)
    CHECKS.append((ok, name, detail))
    mark = GREEN + "PASS" + RESET if ok else RED + "FAIL" + RESET
    print("  [%s] %s" % (mark, name))
    if not ok and detail:
        for chunk in detail.split("\n"):
            print("         %s%s%s" % (DIM, chunk, RESET))
    return ok


def brief(value, limit=200):
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    return text if len(text) <= limit else text[:limit] + " ..."


class Peer:
    """A line-delimited JSON-RPC peer over the child process pipes."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        self.buffer = b""
        self.next_id = 0
        self.stray = []

    def _write(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def _read_line(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                return None
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                return None
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return line.decode("utf-8", "replace")

    def read(self, timeout=5.0):
        line = self._read_line(timeout)
        if line is None:
            return None
        line = line.strip()
        if not line:
            return self.read(timeout)
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            return {"_malformed": line, "_parse_error": str(exc)}

    def request(self, method, params=None, timeout=5.0):
        self.next_id += 1
        request_id = self.next_id
        self._write(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params or {},
            }
        )
        while True:
            message = self.read(timeout)
            if message is None:
                return {
                    "error": {
                        "code": -1,
                        "message": "no response to %s within %.1fs" % (method, timeout),
                    }
                }
            if message.get("id") == request_id:
                return message
            self.stray.append(message)

    def notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()


def check_lifecycle(peer):
    print("lifecycle  (basic/lifecycle)")
    answer = peer.request(
        "initialize",
        {
            "protocolVersion": BOGUS_VERSION,
            "capabilities": {"roots": {"listChanged": True}},
            "clientInfo": {"name": "mcpa-lab-checker", "version": "1.0"},
        },
    )
    result = answer.get("result") or {}
    negotiated = result.get("protocolVersion")
    check(
        negotiated in KNOWN_VERSIONS,
        "initialize negotiates a version the server actually supports",
        "the client offered the non-existent version %s and the server answered %r.\n"
        "A server must answer with a version it supports, so the client can decide\n"
        "whether to continue or disconnect." % (BOGUS_VERSION, negotiated),
    )
    check(
        (result.get("serverInfo") or {}).get("name"),
        "initialize returns serverInfo.name",
        "result was %s" % brief(result),
    )
    capabilities = result.get("capabilities") or {}
    declared = [k for k in ("tools", "resources", "prompts") if k in capabilities]
    print("  %sdeclared capabilities: %s%s" % (DIM, ", ".join(declared) or "none", RESET))

    peer.notify("notifications/initialized")
    answer = peer.read(timeout=0.8)
    check(
        answer is None,
        "notifications/initialized is not answered",
        "the server sent %s.\nA JSON-RPC notification carries no id and MUST NOT be\n"
        "responded to; a response with \"id\": null cannot be correlated by the client."
        % brief(answer),
    )
    return declared


def check_tools(peer):
    print("\ntools  (server/tools)")
    answer = peer.request("tools/list")
    tools = (answer.get("result") or {}).get("tools")
    if check(
        isinstance(tools, list) and tools,
        "tools/list returns a non-empty tools array",
        "answer was %s" % brief(answer),
    ):
        offenders = [
            t.get("name")
            for t in tools
            if (t.get("inputSchema") or {}).get("type") != "object"
        ]
        check(
            not offenders,
            'every tool inputSchema is an object schema ({"type": "object"})',
            "tools missing type:object in inputSchema: %s\n"
            "A host validates arguments against this schema and many refuse to expose\n"
            "a tool whose schema has no declared type." % offenders,
        )
        offenders = [t.get("name") for t in tools if not t.get("description")]
        check(not offenders, "every tool carries a description", "without description: %s" % offenders)

    answer = peer.request("tools/call", {"name": "disk_usage", "arguments": {"path": "/"}})
    result = answer.get("result") or {}
    content = result.get("content")
    shaped = isinstance(content, list) and content and all(
        isinstance(block, dict) and block.get("type") for block in content
    )
    check(
        shaped,
        "a successful tools/call returns result.content as content blocks",
        "result keys were %s.\nA tool result is {\"content\": [{\"type\": \"text\", \"text\": ...}],\n"
        "\"isError\": false}. Anything else is dropped by the host, so the model never\n"
        "sees the output even though the call 'succeeded'." % sorted(result.keys()),
    )
    if shaped:
        check(
            all(block.get("text") for block in content if block.get("type") == "text"),
            "each text content block carries a text field",
            "content was %s" % brief(content),
        )
    check(
        result.get("isError", False) is False,
        "a successful tools/call is not flagged isError",
        "result was %s" % brief(result),
    )

    answer = peer.request("tools/call", {"name": "disk_usage", "arguments": {}})
    result = answer.get("result") or {}
    check(
        result.get("isError") is True and isinstance(result.get("content"), list),
        "a failing tool reports isError:true in the result, not a JSON-RPC error",
        "answer was %s.\nTool execution failures belong in the result so the model can\n"
        "read them and retry; JSON-RPC errors are for protocol failures." % brief(answer),
    )


def check_resources(peer):
    print("\nresources  (server/resources)")
    answer = peer.request("resources/list")
    error = answer.get("error")
    listed = (answer.get("result") or {}).get("resources")
    served = check(
        error is None and isinstance(listed, list),
        "resources/list is served (the capability was declared in initialize)",
        "the server answered %s.\nDeclaring a capability in initialize is a promise that its\n"
        "methods exist. -32601 means the dispatcher never matched that method name."
        % brief(error or answer),
    )
    if served:
        check(
            all(r.get("uri") and r.get("name") for r in listed),
            "every listed resource has a uri and a name",
            "resources were %s" % brief(listed),
        )
        uris = [r.get("uri") for r in listed if r.get("uri")]
    else:
        uris = [FALLBACK_RESOURCE]
        print("  %sfalling back to the documented URI %s%s" % (DIM, FALLBACK_RESOURCE, RESET))

    for uri in uris[:2]:
        answer = peer.request("resources/read", {"uri": uri})
        contents = (answer.get("result") or {}).get("contents")
        if not check(
            isinstance(contents, list) and contents,
            "resources/read %s returns a contents array" % uri,
            "answer was %s" % brief(answer),
        ):
            continue
        entry = contents[0]
        check(
            entry.get("uri") == uri,
            "resources/read %s: the entry echoes its own uri" % uri,
            "entry keys were %s.\nA read may return several entries, and a client attaches each\n"
            "one to the conversation by URI. Without it the payload cannot be tracked back\n"
            "to its source." % sorted(entry.keys()),
        )
        check(
            entry.get("mimeType"),
            "resources/read %s: the entry declares a mimeType" % uri,
            "entry was %s" % brief(entry),
        )
        check(
            ("text" in entry) or ("blob" in entry),
            "resources/read %s: the entry carries text or blob" % uri,
            "entry was %s" % brief(entry),
        )


def check_prompts(peer):
    print("\nprompts  (server/prompts)")
    answer = peer.request("prompts/list")
    prompts = (answer.get("result") or {}).get("prompts")
    if check(
        isinstance(prompts, list) and prompts,
        "prompts/list returns a non-empty prompts array",
        "answer was %s" % brief(answer),
    ):
        check(
            all(isinstance(p.get("arguments", []), list) for p in prompts),
            "prompt arguments are declared as a list of argument descriptors",
            "prompts were %s" % brief(prompts),
        )

    answer = peer.request(
        "prompts/get",
        {"name": "triage_incident", "arguments": {"service": "checkout", "severity": "sev2"}},
    )
    result = answer.get("result") or {}
    messages = result.get("messages")
    if check(
        isinstance(messages, list) and messages,
        "prompts/get returns a messages array",
        "answer was %s" % brief(answer),
    ):
        roles = set(m.get("role") for m in messages)
        check(
            roles <= {"user", "assistant"},
            "every prompt message role is user or assistant",
            "found roles %s.\nThe prompt primitive has no system role: server guidance goes\n"
            "into the first user message, because the host owns the system prompt."
            % sorted(r for r in roles if r),
        )
        offenders = [
            type(m.get("content")).__name__
            for m in messages
            if not isinstance(m.get("content"), dict)
        ]
        check(
            not offenders,
            "every prompt message content is a content block object, not a bare string",
            "found content of type %s.\nPromptMessage.content is one content block -\n"
            "{\"type\": \"text\", \"text\": ...} - so a prompt can also carry an image or an\n"
            "embedded resource." % offenders,
        )
        check(
            all(
                (m.get("content") or {}).get("type")
                for m in messages
                if isinstance(m.get("content"), dict)
            ),
            "every prompt content block declares its type",
            "messages were %s" % brief(messages),
        )

    answer = peer.request(
        "prompts/get", {"name": "triage_incident", "arguments": {"severity": "sev2"}}
    )
    check(
        (answer.get("error") or {}).get("code") == -32602,
        "prompts/get rejects a missing required argument with -32602",
        "answer was %s" % brief(answer),
    )


def main():
    if not os.path.exists(SERVER):
        print("error: %s not found; run the lab script with 'setup' first" % SERVER)
        return 2
    print("MCPA 3.4 - protocol primitive conformance run against %s\n" % SERVER)
    peer = Peer()
    try:
        check_lifecycle(peer)
        check_tools(peer)
        check_resources(peer)
        check_prompts(peer)
    finally:
        peer.close()

    if peer.stray:
        print(
            "\n%sstray messages the client had to discard: %d%s"
            % (DIM, len(peer.stray), RESET)
        )

    failed = [c for c in CHECKS if not c[0]]
    print("\n%d/%d checks passed" % (len(CHECKS) - len(failed), len(CHECKS)))
    if failed:
        print("still broken:")
        for _, name, _ in failed:
            print("  - %s" % name)
        return 1
    print("Every protocol-primitive check passes. Lab complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_VERIFY
    chmod +x "$LAB_DIR/verify.py"
}

write_probe() {
    cat >"$LAB_DIR/probe.sh" <<'EOF_PROBE'
#!/usr/bin/env bash
# Send hand-written JSON-RPC frames to the lab server and print the raw answers.
#
#   ./probe.sh                  handshake + one call of each primitive
#   ./probe.sh '<json line>'    handshake, then your own request
#
# Reading the wire is the diagnostic technique this topic is about: the shape
# of the answer is the contract, not the fact that an answer arrived.
set -euo pipefail
cd "$(dirname "$0")"

init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"probe","version":"1.0"}}}'
inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'

if [[ $# -gt 0 ]]; then
    printf '%s\n%s\n%s\n' "$init" "$inited" "$1" | python3 server.py
    exit 0
fi

printf '%s\n' \
    "$init" \
    "$inited" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"disk_usage","arguments":{"path":"/"}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"resources/list","params":{}}' \
    '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"lab://inventory/nodes.json"}}' \
    '{"jsonrpc":"2.0","id":6,"method":"prompts/list","params":{}}' \
    '{"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":"triage_incident","arguments":{"service":"checkout","severity":"sev2"}}}' \
    | python3 server.py
EOF_PROBE
    chmod +x "$LAB_DIR/probe.sh"
}

print_briefing() {
    cat <<EOF_BRIEF

======================================================================
 MCPA 3.4 - Protocol Primitives - break & fix
======================================================================

An MCP server has been planted in:

    $LAB_DIR

It speaks JSON-RPC 2.0 over stdio, advertises all three server
primitives - tools, resources and prompts - and completes the lifecycle
handshake. It starts, it never crashes, and a quick read of the source
looks reasonable. It is nevertheless non-conformant in SEVEN places
spread over FOUR areas of the protocol. None of them are marked with a
comment, and grepping for TODO will not help: they are ordinary code
that answers the wrong shape.

THE SYMPTOM
  A host application connected to this server behaves like this:

    * the handshake "succeeds" even when the client offers a protocol
      version that does not exist anywhere;
    * right after the client sends notifications/initialized, its log
      shows an unsolicited message carrying "id": null that it cannot
      correlate with any request;
    * one tool is never exposed by the host at all, and for the tool
      that is exposed every SUCCESSFUL call arrives empty in the model's
      context - while every FAILING call displays perfectly;
    * the resource browser is empty and the client log shows
      -32601 Method not found, even though the server told the client
      during initialize that it has resources;
    * a resource does read when asked for by URI, but the client cannot
      attach the payload to the conversation because nothing in the
      answer says which resource it came from;
    * the prompt shows up in the prompt picker, and expanding it throws
      in the client.

YOUR GOAL
  Edit ONLY $LAB_DIR/server.py until every
  check passes:

      cd $LAB_DIR && python3 verify.py

  Success is "0 failed" and exit status 0. Do not edit verify.py, and do
  not special-case the checker: each check asserts a shape the MCP
  specification requires, and a real host enforces the same ones.

FILES
  server.py   the broken MCP server            <- the only file you edit
  verify.py   the conformance checker (an MCP client over stdio)
  probe.sh    raw JSON-RPC frames, for diagnosis

HOW TO WORK IT
  1. Run the checker and read the FAIL detail lines: each one names the
     wire shape that was expected and why a host depends on it.
  2. Reproduce the same failure by hand with ./probe.sh, so you see the
     actual frame rather than the checker's summary. For a single
     request:  ./probe.sh '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}'
  3. Fix one area at a time and re-run. Two useful habits for the exam:
       - every capability declared in initialize must have a handler
         reachable under its EXACT method name;
       - when one code path in a method is correct and another is not,
         compare them side by side - the correct one is the template.
  4. Diff your work against the original at any time:
       $(basename "$0") reset    # restores the broken server, discarding edits
       $(basename "$0") solution # the commented step-by-step fix

SOURCES
  https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
  https://modelcontextprotocol.io/specification/2025-06-18/server/resources
  https://modelcontextprotocol.io/specification/2025-06-18/server/prompts
  https://www.jsonrpc.org/specification
  https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/

======================================================================

EOF_BRIEF
}

do_setup() {
    require_python
    warn_if_root
    if [[ -e "$LAB_DIR" && ! -f "$LAB_DIR/$MARKER_FILE" ]]; then
        echo "error: $LAB_DIR exists and is not a lab directory (no $MARKER_FILE)." >&2
        echo "       Set MCP_LAB_DIR to an unused path and run again." >&2
        exit 1
    fi
    mkdir -p "$LAB_DIR"
    printf 'MCPA 3.4 protocol primitives lab - safe to delete\ncreated: %s\n' \
        "$(date -Iseconds)" >"$LAB_DIR/$MARKER_FILE"
    if [[ -f "$LAB_DIR/server.py" ]]; then
        echo "note: $LAB_DIR/server.py already exists; your edits were kept."
        echo "      Run '$(basename "$0") reset' to start over."
    else
        write_server
    fi
    write_verifier
    write_probe
    print_briefing
}

do_verify() {
    require_python
    if [[ ! -f "$LAB_DIR/verify.py" ]]; then
        echo "error: lab not set up; run '$(basename "$0") setup' first" >&2
        exit 1
    fi
    cd "$LAB_DIR"
    set +e
    python3 verify.py
    status=$?
    set -e
    exit "$status"
}

do_reset() {
    require_python
    if [[ ! -f "$LAB_DIR/$MARKER_FILE" ]]; then
        echo "error: $LAB_DIR is not a lab directory; nothing was reset" >&2
        exit 1
    fi
    write_server
    write_verifier
    write_probe
    echo "server.py restored to its broken state in $LAB_DIR"
}

do_clean() {
    if [[ ! -e "$LAB_DIR" ]]; then
        echo "nothing to clean: $LAB_DIR does not exist"
        exit 0
    fi
    if [[ ! -f "$LAB_DIR/$MARKER_FILE" ]]; then
        echo "refusing to remove $LAB_DIR: it carries no $MARKER_FILE marker" >&2
        exit 1
    fi
    rm -rf -- "$LAB_DIR"
    echo "removed $LAB_DIR"
}

do_solution() {
    if [[ -r "$SELF" ]]; then
        sed -n '/^# === SOLUTION BEGIN/,/^# === SOLUTION END/p' "$SELF" | sed -e 's/^#\{1,\} \{0,1\}//'
    else
        echo "error: cannot read this script to extract the solution block" >&2
        exit 1
    fi
}

main() {
    case "${1:-setup}" in
        setup|--setup|"") do_setup ;;
        verify|--verify) do_verify ;;
        reset|--reset) do_reset ;;
        clean|--clean) do_clean ;;
        solution|--solution) do_solution ;;
        -h|--help|help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
exit 0

# === SOLUTION BEGIN ==========================================================
#
# MCPA 3.4 - Protocol Primitives - step-by-step solution
# Seven defects in four areas. All edits are in server.py.
#
# Step 0 - reproduce before you touch anything
#
#     cd "$MCP_LAB_DIR"   # default: $HOME/mcpa-lab-3.4
#     python3 verify.py
#     ./probe.sh | python3 -c 'import sys;[print(l.rstrip()) for l in sys.stdin]'
#
#   Expect 8 failing checks on a fresh lab. Work top-down: the lifecycle
#   defects distort everything below them.
#
# ---------------------------------------------------------------------------
# AREA 1 - LIFECYCLE (2 defects)
# ---------------------------------------------------------------------------
#
# Defect A - initialize echoes the client's protocolVersion.
#
#   In dispatch(), under `if method == "initialize":`
#
#     -        "protocolVersion": params.get("protocolVersion", PROTOCOL_VERSION),
#     +        "protocolVersion": PROTOCOL_VERSION,
#
#   Why: version negotiation is a statement of what the SERVER supports.
#   The client proposes, the server answers with a version it can actually
#   speak - if it does not match what the client offered, the client decides
#   whether to continue or disconnect. Echoing the client's string turns the
#   negotiation into a mirror: a client speaking a version the server has
#   never implemented is told "agreed", and the failure surfaces much later
#   as a malformed field, which is far harder to diagnose.
#   A server that supports several versions should answer with the requested
#   one if it is in its supported set, and otherwise with its latest.
#
#   Verify:
#     ./probe.sh '{"jsonrpc":"2.0","id":9,"method":"ping","params":{}}' | head -1
#
# Defect B - the server answers a notification.
#
#   In dispatch():
#
#        if method == "notifications/initialized":
#     -      reply(request_id, {})
#            return
#
#   Why: in JSON-RPC 2.0 a notification is precisely a request WITHOUT an id,
#   and it must not be answered. `reply(None, {})` puts `"id": null` on the
#   wire; a client correlates responses by id, so it can match this to
#   nothing. Strict clients treat it as a protocol violation and drop the
#   connection; lenient ones log it and leak one queued reader per
#   notification. The same rule applies to every notifications/* method:
#   cancelled, progress, roots/list_changed, resources/updated.
#
#   Note the guard at the bottom of dispatch(): `if request_id is not None`
#   before fail(...). That is the same rule applied to unknown methods -
#   an unknown NOTIFICATION is silently ignored, an unknown REQUEST gets
#   -32601. Keep it.
#
# ---------------------------------------------------------------------------
# AREA 2 - TOOLS (2 defects)
# ---------------------------------------------------------------------------
#
# Defect C - disk_usage.inputSchema is not an object schema.
#
#   In the TOOLS list, first entry:
#
#         "inputSchema": {
#     +       "type": "object",
#             "properties": {
#                 "path": {"type": "string", "description": "..."}
#             },
#             "required": ["path"],
#         },
#
#   Why: inputSchema is a JSON Schema describing the ARGUMENTS OBJECT of the
#   call. Without "type": "object" the schema is unconstrained, so the host
#   cannot validate arguments before dispatching and the model has no
#   reliable signal about the parameter shape. Hosts routinely refuse to
#   expose such a tool - which is why one tool was missing from the picker
#   while echo_context, whose schema is correct, showed up. Compare the two
#   entries in TOOLS: the second is the template.
#
# Defect D - a successful tools/call returns the wrong result shape.
#
#   In call_tool():
#
#         except ToolFailure as exc:
#             return {"content": [{"type": "text", "text": str(exc)}], "isError": True}
#     -   return {"output": text}
#     +   return {"content": [{"type": "text", "text": text}], "isError": False}
#
#   Why: a tool result is always a list of content blocks - text, image,
#   audio or embedded resource - plus the boolean isError. The transport
#   succeeded, so the client sees no error at all; it just finds no `content`
#   key, renders nothing, and the model receives an empty tool result. That
#   is the worst failure mode in this topic: silent, and it looks like the
#   model ignored the tool.
#
#   Observe that the ERROR path in the same function was already correct.
#   That asymmetry is the diagnostic clue and it is also the lesson:
#   execution failures belong INSIDE the result with isError:true, so the
#   model can read the message and retry; JSON-RPC errors (-32602 for an
#   unknown tool, -32601 for an unknown method) are reserved for protocol
#   failures the model cannot act on. Both halves must be shaped alike.
#
#   Verify:
#     ./probe.sh '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"disk_usage","arguments":{"path":"/"}}}' | tail -1
#
# ---------------------------------------------------------------------------
# AREA 3 - RESOURCES (2 defects)
# ---------------------------------------------------------------------------
#
# Defect E - the list handler is registered under the wrong method name.
#
#   In dispatch():
#
#     -   if method == "resource/list":
#     +   if method == "resources/list":
#             reply(request_id, {"resources": resource_descriptors()})
#             return
#
#   Why: initialize declared `"resources": {...}` in capabilities, which is a
#   promise that resources/list, resources/read and (only if subscribe is
#   true) resources/subscribe are reachable. The dispatcher matches on an
#   exact string, so a singular typo makes the method unreachable and every
#   call falls through to -32601 Method not found. The pairing is the point:
#   a declared capability with no handler is the single most common
#   server-side conformance bug, and -32601 on a method you "know you
#   implemented" should send you straight to the dispatch table rather than
#   to the handler body.
#
#   While you are there, keep the discipline honest: the server declares
#   "subscribe": false, and it implements no resources/subscribe. That pair
#   is correct. Do not declare true unless you implement it.
#
# Defect F - resources/read omits the uri of each entry.
#
#   In dispatch(), under `if method == "resources/read":`
#
#         reply(
#             request_id,
#     -       {"contents": [{"mimeType": entry["mimeType"], "text": entry["text"]}]},
#     +       {
#     +           "contents": [
#     +               {
#     +                   "uri": uri,
#     +                   "name": entry["name"],
#     +                   "mimeType": entry["mimeType"],
#     +                   "text": entry["text"],
#     +               }
#     +           ]
#     +       },
#         )
#
#   Why: contents is a LIST because one read may legitimately expand into
#   several items (a directory-like URI, a template expansion). Each entry
#   therefore identifies itself with its own uri, and carries either `text`
#   for textual data or `blob` (base64) for binary - never both. Without the
#   uri, a client that just read three resources cannot tell which payload is
#   which, cannot attach it to the conversation with a citation, and cannot
#   invalidate it when notifications/resources/updated arrives for one URI.
#
#   Keep -32002 for a URI that does not exist: that is the resource-specific
#   "not found" code, distinct from -32602 (invalid params).
#
# ---------------------------------------------------------------------------
# AREA 4 - PROMPTS (1 defect, two symptoms)
# ---------------------------------------------------------------------------
#
# Defect G - prompts/get returns a system role and bare-string content.
#
#   In dispatch(), under `if method == "prompts/get":`
#
#             "messages": [
#     -           {
#     -               "role": "system",
#     -               "content": "You are an SRE on call. Be concise and cite evidence.",
#     -           },
#     -           {
#     -               "role": "user",
#     -               "content": ("Triage %s, declared %s. ..." % (service, severity)),
#     -           },
#     +           {
#     +               "role": "user",
#     +               "content": {
#     +                   "type": "text",
#     +                   "text": (
#     +                       "You are an SRE on call. Be concise and cite evidence.\n\n"
#     +                       "Triage %s, declared %s. State the blast radius, the first "
#     +                       "three commands you would run, and the rollback you would "
#     +                       "prepare before touching anything." % (service, severity)
#     +                   ),
#     +               },
#     +           },
#             ],
#
#   Why, two independent reasons:
#
#     * Roles. A PromptMessage role is "user" or "assistant" only. There is
#       no system role in this primitive: the system prompt belongs to the
#       HOST, and a server that could inject one would be able to override
#       the host's instructions through a menu entry the user merely clicked.
#       Server guidance goes into the first user message - visible, and
#       subject to the host's own policy. This is a security boundary, not a
#       formatting preference.
#
#     * Content. PromptMessage.content is ONE content block object, the same
#       union the tool result uses - {"type": "text", "text": ...},
#       {"type": "image", "data": ..., "mimeType": ...}, or
#       {"type": "resource", "resource": {...}} to embed a resource by URI.
#       A bare string has no type discriminator, so a client that switches on
#       content["type"] raises - which is exactly the crash on expanding the
#       prompt. Note the shape rhyme across primitives: tools return content
#       blocks, prompts carry content blocks, resources embed as one.
#       Learn the block, and three primitives become one shape.
#
#   The argument validation in this handler was already correct and is worth
#   copying: prompts/list declares `arguments` with name/description/required,
#   and prompts/get rejects a missing required argument with -32602 (invalid
#   params) instead of silently substituting a default. A prompt is a
#   user-controlled, parameterised template - the contract it publishes in
#   prompts/list is the contract it must enforce in prompts/get.
#
# ---------------------------------------------------------------------------
# Step 5 - confirm
#
#     python3 verify.py; echo "exit=$?"
#
#   Expected: every check PASS, "exit=0", and the final line
#   "Every protocol-primitive check passes."
#
#   Then re-read the raw wire once more with ./probe.sh and notice what a
#   conformant server looks like: initialize answers with its own version,
#   the notification produces silence, every tools/call - success and failure
#   alike - carries content blocks, every resources/read entry names its own
#   URI, and every prompt message is a user/assistant turn holding a typed
#   content block.
#
# Step 6 - tear down
#
#     "$0" clean     # removes the lab directory (marker-guarded)
#
# === SOLUTION END ============================================================