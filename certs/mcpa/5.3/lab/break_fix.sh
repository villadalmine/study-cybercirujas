#!/usr/bin/env bash
#
# ============================================================================
#  MCPA - Model Context Protocol Associate
#  Topic 5.3: Ecosystem & Portability            (exam weight: 6.66%)
#  Exam version: 2026-07-28
#
#  break & fix lab: "it works on my machine" - an MCP server that is pinned
#  to the laptop it was written on, and refuses to run anywhere else.
#
#  References
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#
#  WHAT IT BUILDS
#    - server/notes_server.py : a real MCP server, stdio transport, no SDK,
#                               no network, ~150 lines of JSON-RPC 2.0.
#    - bin/notes-mcp          : the launcher that makes the server a portable
#                               command (the role npx / uvx play in the wild).
#    - client/mcp_probe.py    : a strict reference host. It implements only
#                               what the specification requires. It stands in
#                               for Claude Desktop, VS Code, or an agent
#                               framework, and it is NOT yours to edit.
#    - .mcp.json              : the server manifest you would commit to a repo.
#
#  SAFETY
#    Everything is written under $LAB_ROOT (default ~/mcp-portability-lab) and
#    ${XDG_DATA_HOME:-~/.local/share}/notes-mcp. No system files are touched,
#    no services, no package installs, no network access, no root required.
#    "$0 reset" deletes both. Run it on a disposable VM regardless.
#
#  USAGE
#    ./break_fix.sh          # plant the faults and print the briefing
#    ./break_fix.sh verify   # grade your repair (6 stages)
#    ./break_fix.sh reset    # remove the lab entirely
# ============================================================================

set -euo pipefail

LAB_ROOT="${LAB_ROOT:-$HOME/mcp-portability-lab}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/notes-mcp"
MARKER=".mcpa-5-3-lab"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$c_bld" "$*" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_yel" "$*" "$c_off"; }
die()  { printf '%s%s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
preflight() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found on PATH."

    if [ "$(id -u)" -eq 0 ] && [ "${MCPA_LAB_FORCE:-0}" != "1" ]; then
        die "This lab needs no privileges. Run it as a normal user, or set MCPA_LAB_FORCE=1."
    fi

    if [ -e "$LAB_ROOT" ] && [ ! -e "$LAB_ROOT/$MARKER" ]; then
        die "$LAB_ROOT already exists and was not created by this lab. Refusing to overwrite it."
    fi

    if [ -e "$DATA_DIR" ] && [ ! -e "$DATA_DIR/$MARKER" ]; then
        die "$DATA_DIR already exists and was not created by this lab. Refusing to overwrite it."
    fi
}

# ---------------------------------------------------------------------------
# The MCP server - planted with four portability defects
# ---------------------------------------------------------------------------
write_server() {
    mkdir -p "$LAB_ROOT/server"
    cat >"$LAB_ROOT/server/notes_server.py" <<'PYSERVER'
#!/usr/bin/env python3
"""notes-mcp - a minimal Model Context Protocol server on the stdio transport.

No SDK is used on purpose: the entire protocol surface exercised here is
JSON-RPC 2.0 messages, one per line, on stdin and stdout.
"""

import json
import os
import sys

SERVER_NAME = "notes-mcp"
SERVER_VERSION = "0.3.1"
SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")

TOOL = {
    "name": "notes_search",
    "title": "Search notes",
    "description": "Search the local runbook notes and return the matching titles.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Substring to look for."}
        },
        "required": ["query"],
    },
}


def data_dir():
    """Where the notes live. An explicit override wins; otherwise XDG."""
    explicit = os.environ.get("MCP_NOTES_DIR")
    if explicit:
        return explicit
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share"
    )
    return os.path.join(base, "notes-mcp")


def log(message):
    sys.stderr.write("[%s] %s\n" % (SERVER_NAME, message))
    sys.stderr.flush()


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def result(request_id, payload):
    send({"jsonrpc": "2.0", "id": request_id, "result": payload})


def error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id,
          "error": {"code": code, "message": message}})


def load_notes():
    root = data_dir()
    notes = []
    try:
        names = sorted(os.listdir(root))
    except OSError as exc:
        log("cannot list %s: %s" % (root, exc))
        return notes
    for name in names:
        if not name.endswith(".md"):
            continue
        try:
            with open(os.path.join(root, name), "r", encoding="utf-8") as handle:
                notes.append((name, handle.read()))
        except OSError as exc:
            log("cannot read %s: %s" % (name, exc))
    return notes


def notes_search(query):
    notes = load_notes()
    hits = [name for name, body in notes if query.lower() in (name + body).lower()]
    print("notes_search(%r): %d/%d note(s)" % (query, len(hits), len(notes)))
    if not hits:
        return "No note matches %r." % query
    return "\n".join("- " + name for name in hits)


def handle(message):
    method = message.get("method")
    request_id = message.get("id")

    if method == "initialize":
        result(request_id, {
            "protocolVersion": "2024-05-01",
            "capabilities": {"resources": {"subscribe": False, "listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })

    elif method == "notifications/initialized":
        log("client finished initialization")

    elif method == "ping":
        result(request_id, {})

    elif method == "tools/list":
        result(request_id, {"tools": [TOOL]})

    elif method == "tools/call":
        params = message.get("params") or {}
        if params.get("name") != TOOL["name"]:
            error(request_id, -32602, "unknown tool: %s" % params.get("name"))
            return
        query = (params.get("arguments") or {}).get("query", "")
        result(request_id, {
            "content": [{"type": "text", "text": notes_search(query)}],
            "isError": False,
        })

    elif request_id is not None:
        error(request_id, -32601, "method not found: %s" % method)


def main():
    try:
        os.makedirs(data_dir(), exist_ok=True)
    except OSError as exc:
        log("note store unavailable: %s" % exc)

    print("%s %s ready (notes: %s)" % (SERVER_NAME, SERVER_VERSION, data_dir()))
    log("listening on stdio, protocols: %s" % ", ".join(SUPPORTED_PROTOCOLS))

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            log("dropping malformed line: %.80s" % line)
            continue
        handle(message)


if __name__ == "__main__":
    main()
PYSERVER
    chmod 0644 "$LAB_ROOT/server/notes_server.py"
}

# ---------------------------------------------------------------------------
# The launcher - what turns a script into a portable command
# ---------------------------------------------------------------------------
write_launcher() {
    mkdir -p "$LAB_ROOT/bin"
    cat >"$LAB_ROOT/bin/notes-mcp" <<'PYLAUNCH'
#!/usr/bin/env bash
# notes-mcp - launcher for the notes MCP server.
# Resolves its own location so the package can be unpacked anywhere.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SERVER="$HERE/../server/notes_server.py"

echo "[notes-mcp] launching $SERVER"

if ! command -v python3 >/dev/null 2>&1; then
    echo "[notes-mcp] python3 not found on PATH" >&2
    exit 127
fi

exec python3 "$SERVER" "$@"
PYLAUNCH
    chmod 0755 "$LAB_ROOT/bin/notes-mcp"
}

# ---------------------------------------------------------------------------
# The reference host - graded, immutable
# ---------------------------------------------------------------------------
write_probe() {
    mkdir -p "$LAB_ROOT/client" "$LAB_ROOT/logs"
    cat >"$LAB_ROOT/client/mcp_probe.py" <<'PYPROBE'
#!/usr/bin/env python3
"""mcp_probe.py - a strict, minimal MCP host.

It implements exactly what the specification requires of a client and nothing
more. It stands in for the hosts your server will actually be dropped into.

DO NOT EDIT THIS FILE. Making the host tolerant of a non-portable server is
the precise mistake this exercise exists to teach you to stop making; the
grader checks its checksum.
"""

import json
import os
import select
import subprocess
import sys
import time

SUPPORTED = ["2025-06-18", "2025-03-26", "2024-11-05"]
PREFERRED = SUPPORTED[0]
TIMEOUT = 10.0
LOG_PATH = None
PASSED = 0


def ok(stage, detail):
    global PASSED
    PASSED += 1
    print("  [ OK ] %-26s %s" % (stage, detail))


def tail_log(lines=15):
    if not LOG_PATH or not os.path.exists(LOG_PATH):
        return
    with open(LOG_PATH, "r", encoding="utf-8", errors="replace") as handle:
        rows = handle.read().splitlines()
    if not rows:
        return
    print()
    print("  --- last %d line(s) of %s ---" % (min(lines, len(rows)), LOG_PATH))
    for row in rows[-lines:]:
        print("  | " + row)


def fail(stage, problem, hint):
    print("  [FAIL] %-26s %s" % (stage, problem))
    print()
    for line in hint.strip().splitlines():
        print("  %s" % line)
    tail_log()
    print()
    print("  stages passed: %d/6" % PASSED)
    sys.exit(1)


def read_message(proc, stage, hint, deadline=None):
    deadline = deadline or (time.time() + TIMEOUT)
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            fail(stage, "no reply within %.0fs" % TIMEOUT, hint)
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            continue
        line = proc.stdout.readline()
        if line == "":
            fail(stage,
                 "the server closed stdout (exit status %s)" % proc.poll(),
                 hint)
        stripped = line.strip()
        if not stripped:
            continue
        try:
            return json.loads(stripped)
        except ValueError:
            fail(stage,
                 "this line on stdout is not JSON-RPC: %r" % stripped[:100],
                 """
  The stdio transport is newline-delimited JSON: every single line the server
  writes to stdout MUST be one valid JSON-RPC message, and nothing else may
  ever be written there. Banners, progress notes and debug output belong on
  stderr, which the host captures for you (this log file is that capture).
  https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
""")


def send(proc, message):
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()


def main():
    global LOG_PATH

    config_path = sys.argv[1]
    lab = os.path.dirname(os.path.abspath(config_path))
    LOG_PATH = os.path.join(lab, "logs", "notes-mcp.stderr.log")
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)

    with open(config_path, "r", encoding="utf-8") as handle:
        config = json.load(handle)
    servers = config.get("mcpServers") or {}
    if len(servers) != 1:
        fail("0 manifest", "expected exactly one entry under mcpServers",
             "  Repair %s first." % config_path)
    name = sorted(servers)[0]
    entry = servers[name]

    env = dict(os.environ)
    for key, value in (entry.get("env") or {}).items():
        env[str(key)] = str(value)
    argv = [entry.get("command", "")] + [str(a) for a in (entry.get("args") or [])]

    logfile = open(LOG_PATH, "wb")
    try:
        proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=logfile,
            env=env, cwd=entry.get("cwd") or None, text=True, bufsize=1,
        )
    except OSError as exc:
        fail("1 spawn", "cannot execute %r: %s" % (argv[0], exc.strerror),
             """
  The host runs `command` plus `args` as a plain child process. It does not
  search your project, it does not guess an interpreter, and it will not
  rewrite a path that pointed somewhere on the author's machine.
  A portable manifest names a command the operating system can resolve on
  PATH - which is why the ecosystem ships servers as npx / uvx / console
  entry points instead of as file paths.
""")
    ok("1 spawn", "%s (pid %d)" % (name, proc.pid))

    send(proc, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": PREFERRED,
            "capabilities": {"roots": {"listChanged": True}},
            "clientInfo": {"name": "mcp-probe", "title": "MCPA 5.3 probe",
                           "version": "1.0.0"},
        },
    })

    framing_hint = """
  Stage 2 reads the very first line the server writes. On the stdio transport
  that line has to be the InitializeResult, because stdout is the wire.
"""
    message = read_message(proc, "2 initialize", framing_hint)
    if "result" not in message:
        fail("2 initialize", "initialize returned %s" % json.dumps(message)[:120],
             "  The server must answer initialize with a result, not an error.")
    result = message["result"]
    ok("2 initialize", "clean JSON-RPC framing on stdout")

    version = result.get("protocolVersion")
    if version not in SUPPORTED:
        fail("3 version negotiation",
             "server answered protocolVersion %r" % version,
             """
  This client offered %s and also accepts %s.
  The rule is: if the server supports the requested version it MUST echo that
  same version back; otherwise it MUST answer with another version it does
  support - and the client then disconnects if it cannot speak it, which is
  what just happened. A hardcoded version string is not negotiation, and it
  locks your server to the one host you happened to test.
  https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
""" % (PREFERRED, ", ".join(SUPPORTED[1:])))
    ok("3 version negotiation", "agreed on %s" % version)

    capabilities = result.get("capabilities") or {}
    if "tools" not in capabilities:
        fail("4 capability negotiation",
             "declared capabilities: %s" % (", ".join(sorted(capabilities)) or "none"),
             """
  A client MUST NOT use a capability the server did not declare, so this host
  will not call tools/list at all - to the user the server simply appears
  empty, with no error anywhere. Whatever your server implements, it has to
  say so in the InitializeResult.
  https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
""")
    ok("4 capability negotiation", "tools declared")

    send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
    send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    message = read_message(proc, "5 tools/list", framing_hint)
    tools = (message.get("result") or {}).get("tools") or []
    names = [t.get("name") for t in tools]
    if "notes_search" not in names:
        fail("5 tools/list", "tools advertised: %s" % (", ".join(names) or "none"),
             "  The server must advertise notes_search.")
    schema = [t for t in tools if t.get("name") == "notes_search"][0].get("inputSchema") or {}
    if schema.get("type") != "object":
        fail("5 tools/list", "notes_search has no object inputSchema",
             """
  Every tool needs a JSON Schema object so that any host, and any model behind
  it, can build a valid call without reading your source.
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
""")
    ok("5 tools/list", "%d tool(s), schema valid" % len(tools))

    send(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": "notes_search", "arguments": {"query": "backup"}}})
    message = read_message(proc, "6 tools/call", """
  A stray write to stdout is just as fatal in the middle of a session as it is
  at startup - and this one only surfaces once a tool is actually called,
  which is why it survives a smoke test and dies in front of a user.
""")
    payload = message.get("result") or {}
    text = "".join(part.get("text", "") for part in payload.get("content") or [])
    if "runbook-backup" not in text:
        fail("6 tools/call", "the tool ran but returned: %s" % (text.strip()[:90] or "nothing"),
             """
  The call succeeded, so the protocol is fine - the server is reading its data
  from a directory that does not exist on this machine. Check the stderr log
  below and the `env` block of the manifest: a path baked into configuration
  is exactly as non-portable as one baked into code. Derive the location at
  runtime (XDG_DATA_HOME, or the user's home) instead.
""")
    ok("6 tools/call", "notes_search returned %d match line(s)" % len(text.splitlines()))

    proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

    print()
    print("  stages passed: 6/6")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYPROBE
    chmod 0644 "$LAB_ROOT/client/mcp_probe.py"
    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "$LAB_ROOT" && sha256sum client/mcp_probe.py > .probe.sha256 )
    fi
}

# ---------------------------------------------------------------------------
# The grader: portability lint on the manifest, then the protocol run
# ---------------------------------------------------------------------------
write_verifier() {
    cat >"$LAB_ROOT/bin/lab-verify" <<'PYVERIFY'
#!/usr/bin/env bash
# lab-verify - grade the repair for MCPA 5.3.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LAB="$(cd -- "$HERE/.." && pwd -P)"
export PATH="$LAB/bin:$PATH"

red=$'\033[31m'; grn=$'\033[32m'; bld=$'\033[1m'; off=$'\033[0m'

printf '\n%s== stage 0: the manifest must be portable ==%s\n' "$bld" "$off"

if [ -f "$LAB/.probe.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    if ! ( cd "$LAB" && sha256sum -c --quiet .probe.sha256 ) 2>/dev/null; then
        printf '  %s[FAIL]%s client/mcp_probe.py was modified. The host is not yours to change; restore it.\n' "$red" "$off"
        exit 1
    fi
fi

python3 - "$LAB/.mcp.json" <<'PY'
import json, re, sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        config = json.load(handle)
except ValueError as exc:
    print("  [FAIL] %s is not valid JSON: %s" % (path, exc))
    sys.exit(1)

servers = config.get("mcpServers") or {}
bad = []
absolute = re.compile(r"^(/|~|[A-Za-z]:[\\/])")

for name, entry in servers.items():
    fields = [("command", entry.get("command", ""))]
    fields += [("args[%d]" % i, a) for i, a in enumerate(entry.get("args") or [])]
    if entry.get("cwd"):
        fields.append(("cwd", entry["cwd"]))
    fields += [("env.%s" % k, v) for k, v in (entry.get("env") or {}).items()]
    for field, value in fields:
        if isinstance(value, str) and absolute.match(value):
            bad.append("%s -> %s: %s" % (name, field, value))

if bad:
    print("  [FAIL] machine-specific paths in the manifest:")
    for row in bad:
        print("         %s" % row)
    print()
    print("  This file is meant to be committed and handed to somebody else.")
    print("  Nothing in it may name a path that only exists on your machine.")
    sys.exit(1)

print("  [ OK ] no absolute paths: this manifest travels")
PY
lint=$?
[ $lint -ne 0 ] && exit $lint

printf '\n%s== stages 1-6: the protocol run ==%s\n' "$bld" "$off"
if python3 "$LAB/client/mcp_probe.py" "$LAB/.mcp.json"; then
    printf '\n  %sLAB PASSED%s - the server is portable: no machine paths, clean stdio\n' "$grn" "$off"
    printf '  framing, negotiated protocol version, declared capabilities, working tool.\n\n'
    exit 0
fi
exit 1
PYVERIFY
    chmod 0755 "$LAB_ROOT/bin/lab-verify"
}

# ---------------------------------------------------------------------------
# The manifest, as it was committed by somebody who never left their laptop
# ---------------------------------------------------------------------------
write_manifest() {
    cat >"$LAB_ROOT/.mcp.json" <<'JSONCFG'
{
  "mcpServers": {
    "notes": {
      "command": "/usr/local/lib/mcp-runtime-3.12/bin/python3.12",
      "args": ["/home/builder/dev/mcp-notes/server/notes_server.py"],
      "env": {
        "MCP_NOTES_DIR": "/home/builder/dev/mcp-notes/data",
        "PYTHONPATH": "/home/builder/dev/mcp-notes/vendor"
      }
    }
  }
}
JSONCFG
}

seed_notes() {
    mkdir -p "$DATA_DIR"
    : >"$DATA_DIR/$MARKER"
    cat >"$DATA_DIR/runbook-backup.md" <<'MD'
# Runbook: nightly backup
Snapshot the volume at 02:00, verify the checksum, retain 14 days.
MD
    cat >"$DATA_DIR/runbook-restore.md" <<'MD'
# Runbook: restore from snapshot
Stop the writer, restore the newest verified snapshot, replay the WAL.
MD
    cat >"$DATA_DIR/onboarding.md" <<'MD'
# Onboarding
Request access, read the architecture note, shadow one on-call rotation.
MD
}

write_env_helper() {
    printf '# source this to put the lab launcher on PATH\nexport PATH="%s/bin:$PATH"\n' \
        "$LAB_ROOT" >"$LAB_ROOT/lab-env.sh"
}

# ---------------------------------------------------------------------------
# Break
# ---------------------------------------------------------------------------
do_break() {
    preflight
    mkdir -p "$LAB_ROOT"
    : >"$LAB_ROOT/$MARKER"
    write_server
    write_launcher
    write_probe
    write_verifier
    write_manifest
    write_env_helper
    seed_notes
    : >"$LAB_ROOT/logs/notes-mcp.stderr.log"

    head1 "MCPA 5.3 - Ecosystem & Portability :: break & fix"
    say "Lab root : $LAB_ROOT"
    say "Notes    : $DATA_DIR  (3 seeded markdown notes)"
    say "Logs     : $LAB_ROOT/logs/notes-mcp.stderr.log"

    head1 "THE SITUATION"
    cat <<'TXT'
A colleague wrote an MCP server, "notes-mcp". It exposes one tool,
notes_search, over the stdio transport. On their laptop it works perfectly -
they have the screen recording to prove it.

You have been handed the repository and told to make it run in any host: this
VM today, a teammate's machine tomorrow, a container next week. The only
client you get is client/mcp_probe.py, which implements the specification and
nothing else. You cannot negotiate with it, and you cannot patch it.
TXT

    head1 "THE SYMPTOM YOU WILL SEE"
    warn "  $ $LAB_ROOT/bin/lab-verify"
    cat <<'TXT'
    [FAIL] machine-specific paths in the manifest
    ...and once that is past:
    [FAIL] 1 spawn    cannot execute '/usr/local/lib/...': No such file or directory

  The failures are layered. Each repair takes you one stage further, and the
  next symptom is different in kind from the one before it: a process that
  will not start, a stream that is not parseable, a handshake that is refused,
  a server that connects and then looks empty, a tool that answers with
  nothing. All five are ordinary portability bugs. None of them is a bug in
  the protocol.
TXT

    head1 "YOUR MISSION"
    cat <<'TXT'
  Get all six stages green, under one hard constraint:

    .mcp.json must contain no absolute path of any kind.

  It has to be a file you could commit to the repository and hand to somebody
  on another operating system unchanged. That constraint is the whole lesson -
  it forces the fix into the package rather than into the configuration, the
  same way the ecosystem ships servers as `npx -y @scope/server` or
  `uvx some-server` instead of as a path into one person's home directory.

  You may edit:  .mcp.json, bin/notes-mcp, server/notes_server.py
  You may NOT edit: client/mcp_probe.py, bin/lab-verify  (checksummed)

  Read the stderr log. A correct MCP server is talkative there and silent on
  stdout; the host captures it for exactly this purpose, the way Claude
  Desktop keeps mcp-server-<name>.log.
TXT

    head1 "WORK LOOP"
    say "  source $LAB_ROOT/lab-env.sh     # puts the lab's bin/ on PATH"
    say "  \$EDITOR $LAB_ROOT/.mcp.json"
    say "  $LAB_ROOT/bin/lab-verify        # grade: stage 0 lint + stages 1-6"
    say ""
    say "  Done when lab-verify prints: LAB PASSED (6/6)."
    say "  Give up with: $0 reset"
    say ""
}

do_verify() {
    [ -x "$LAB_ROOT/bin/lab-verify" ] || die "No lab found at $LAB_ROOT. Run '$0' first."
    exec "$LAB_ROOT/bin/lab-verify"
}

do_reset() {
    if [ -e "$LAB_ROOT" ]; then
        [ -e "$LAB_ROOT/$MARKER" ] || die "$LAB_ROOT is not this lab's directory. Not deleting it."
        rm -rf -- "$LAB_ROOT"
        say "removed $LAB_ROOT"
    fi
    if [ -e "$DATA_DIR" ]; then
        [ -e "$DATA_DIR/$MARKER" ] || die "$DATA_DIR is not this lab's directory. Not deleting it."
        rm -rf -- "$DATA_DIR"
        say "removed $DATA_DIR"
    fi
    say "lab reset."
}

case "${1:-break}" in
    break|"")      do_break ;;
    verify|check)  do_verify ;;
    reset|clean)   do_reset ;;
    *)             die "usage: $0 [break|verify|reset]" ;;
esac

# ============================================================================
# SOLUTION - step by step. Stop reading if you still want the exercise.
# ============================================================================
#
# There are five defects, in three files. They are graded in the order the
# host meets them, so fix them in that order.
#
# ---------------------------------------------------------------------------
# STEP 0 - read the log before touching anything
# ---------------------------------------------------------------------------
#   cat ~/mcp-portability-lab/logs/notes-mcp.stderr.log
#
#   Empty on the first run: the process never started. That alone rules out
#   every protocol-level hypothesis and points at the manifest.
#
# ---------------------------------------------------------------------------
# DEFECT 1 - the manifest names paths that exist on one laptop only
#            (.mcp.json: command, args, env)
# ---------------------------------------------------------------------------
#   `command` pins an interpreter at /usr/local/lib/mcp-runtime-3.12/bin/...,
#   `args` points into /home/builder, and `env` hardcodes both the note store
#   and a PYTHONPATH. The host executes command+args as a plain child process:
#   it does not search, guess or rewrite anything.
#
#   The fix is not a better path - it is no path. The repository already
#   ships bin/notes-mcp, a launcher that resolves its own location, so the
#   manifest only has to name a command that PATH can resolve. Replace the
#   whole entry with:
#
#     {
#       "mcpServers": {
#         "notes": {
#           "command": "notes-mcp",
#           "args": []
#         }
#       }
#     }
#
#   Dropping MCP_NOTES_DIR is deliberate - see DEFECT 5. Then put the
#   launcher on PATH the way a real install would:
#
#     source ~/mcp-portability-lab/lab-env.sh
#
#   This is why published servers are invoked as `npx -y @modelcontextprotocol/
#   server-filesystem` or `uvx mcp-server-git`: the manifest carries a name the
#   runtime resolves, never a location.
#
# ---------------------------------------------------------------------------
# DEFECT 2 - two writes to stdout corrupt the wire
#            (bin/notes-mcp and server/notes_server.py)
# ---------------------------------------------------------------------------
#   Symptom: [FAIL] 2 initialize - "this line on stdout is not JSON-RPC:
#   '[notes-mcp] launching ...'".
#
#   On the stdio transport stdout IS the protocol connection: newline-
#   delimited JSON-RPC, one message per line, nothing else, ever. Every log
#   line goes to stderr, which the host captures for you.
#
#   In bin/notes-mcp:
#     -   echo "[notes-mcp] launching $SERVER"
#     +   echo "[notes-mcp] launching $SERVER" >&2
#
#   In server/notes_server.py, main():
#     -   print("%s %s ready (notes: %s)" % (SERVER_NAME, SERVER_VERSION, data_dir()))
#     +   log("%s %s ready (notes: %s)" % (SERVER_NAME, SERVER_VERSION, data_dir()))
#
#   (`log()` already writes to sys.stderr. In Python, also beware of anything
#   that prints on import, and of libraries that default to stdout logging.)
#
# ---------------------------------------------------------------------------
# DEFECT 3 - the protocol version is hardcoded instead of negotiated
#            (server/notes_server.py, handle(), "initialize")
# ---------------------------------------------------------------------------
#   Symptom: [FAIL] 3 version negotiation - server answered '2024-05-01',
#   a version this client - and every other one - has never heard of.
#
#   The lifecycle rule: the client sends the version it prefers; if the server
#   supports it, the server MUST echo that exact string back; otherwise it
#   answers with a version it does support, and the client disconnects if it
#   cannot speak it. SUPPORTED_PROTOCOLS is already declared at the top of the
#   file and was simply never used. Replace the initialize branch with:
#
#     if method == "initialize":
#         wanted = (message.get("params") or {}).get("protocolVersion")
#         agreed = wanted if wanted in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
#         result(request_id, {
#             "protocolVersion": agreed,
#             "capabilities": {"tools": {"listChanged": False}},
#             "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
#         })
#
#   That single block also fixes DEFECT 4.
#
# ---------------------------------------------------------------------------
# DEFECT 4 - the server implements tools and declares resources
#            (same initialize result)
# ---------------------------------------------------------------------------
#   Symptom: [FAIL] 4 capability negotiation - declared capabilities: resources.
#
#   A client MUST NOT use a capability the server did not declare, so a
#   specification-conformant host never calls tools/list and the server simply
#   appears empty - no error, no warning, nothing in any log. This is the
#   single most common "your server works in your client and not in mine"
#   report. Whatever you implement, declare it; whatever you declare,
#   implement it.
#
# ---------------------------------------------------------------------------
# DEFECT 5 - a debug print inside the tool, and a note store that moved
#            (server/notes_server.py, notes_search())
# ---------------------------------------------------------------------------
#   Symptom A: [FAIL] 6 tools/call - another non-JSON line on stdout. Same
#   class as DEFECT 2, but it only fires once a tool is actually called, which
#   is why it survives every smoke test and dies in front of a user.
#
#     -   print("notes_search(%r): %d/%d note(s)" % (query, len(hits), len(notes)))
#     +   log("notes_search(%r): %d/%d note(s)" % (query, len(hits), len(notes)))
#
#   Symptom B: the call succeeds and answers "No note matches 'backup'", with
#   "cannot list /home/builder/dev/mcp-notes/data" in the stderr log. If you
#   kept MCP_NOTES_DIR in the manifest, remove it now: data_dir() already
#   falls back to $XDG_DATA_HOME/notes-mcp, which resolves per user on every
#   machine. A path baked into configuration is exactly as non-portable as one
#   baked into code - the manifest just makes it look like a setting.
#
# ---------------------------------------------------------------------------
# VERIFY
# ---------------------------------------------------------------------------
#   source ~/mcp-portability-lab/lab-env.sh
#   ~/mcp-portability-lab/bin/lab-verify
#
#   Expected:
#     [ OK ] no absolute paths: this manifest travels
#     [ OK ] 1 spawn                   notes (pid ...)
#     [ OK ] 2 initialize              clean JSON-RPC framing on stdout
#     [ OK ] 3 version negotiation     agreed on 2025-06-18
#     [ OK ] 4 capability negotiation  tools declared
#     [ OK ] 5 tools/list              1 tool(s), schema valid
#     [ OK ] 6 tools/call              notes_search returned 2 match line(s)
#     LAB PASSED
#
# ---------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM AND INTO PRODUCTION
# ---------------------------------------------------------------------------
#   * Portability lives in the package, not in the configuration. If the
#     manifest contains a path, you have shipped a machine, not a server.
#   * stdout is the transport; stderr is the log. The host captures stderr
#     precisely so you never need stdout.
#   * Version and capabilities are negotiated per connection. Hardcode either
#     one and you have written a server for exactly one client.
#   * Declare what you implement. An undeclared capability is an invisible
#     one, and invisible failures cost the most time.
#   * Derive every filesystem location at runtime: XDG_DATA_HOME, the user's
#     home, an explicit argument - in that order of preference.
#
#   Sources:
#     https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
#     https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
#     https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#     https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
# ============================================================================