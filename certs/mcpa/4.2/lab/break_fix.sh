#!/usr/bin/env bash
#
# ============================================================================
#  MCPA — Model Context Protocol Associate (exam version 2026-07-28)
#  Domain 4.2 — Permissions & Consent   (exam weight: 6.0)
#
#  BREAK & FIX LAB — run this on a DISPOSABLE lab VM.
#
#  What this script does
#  ---------------------
#  1. Builds a small, self-contained MCP lab under a single directory:
#     a stdio MCP server ("notes-server"), a host that holds the user's
#     consent, and an acceptance script.
#  2. Proves the lab is GREEN (every acceptance check passes).
#  3. Injects four controlled faults, one per permission gate.
#  4. Tells the student the symptom and the objective — not the fix.
#
#  Blast radius: everything lives under ${MCPA_LAB_DIR:-$HOME/mcpa-lab-4.2}.
#  No packages are installed, no service is enabled, no system file is
#  touched, no network call is made. Removing that directory removes the lab.
#
#  Why these four faults: the MCP specification makes the *host* the trust
#  boundary. It must obtain explicit user consent before invoking a tool, keep
#  that consent per tool, confine the server to declared roots, and — for
#  HTTP-based transports — present an access token that is audience-bound to
#  the server it is talking to, never a token minted for somebody else.
#    https://modelcontextprotocol.io/specification/2025-06-18
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
#    https://modelcontextprotocol.io/specification/2025-06-18/client/roots
#    https://datatracker.ietf.org/doc/html/rfc8707
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#
#  Usage:
#    ./mcpa-4.2-break-fix.sh            build, verify, then break (asks first)
#    ./mcpa-4.2-break-fix.sh --force    same, without the confirmation prompt
#    ./mcpa-4.2-break-fix.sh --reset    rebuild the GREEN state and stop
#    ./mcpa-4.2-break-fix.sh --verify   only run the acceptance checks
#
#  NOTE: re-running without --verify rebuilds the lab from scratch, so any
#  partial fix the student made is lost. Use --verify while working.
# ============================================================================

set -Eeuo pipefail

LAB="${MCPA_LAB_DIR:-$HOME/mcpa-lab-4.2}"
MODE="break"
FORCE="no"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }
expand() { sed "s|@LAB@|$LAB|g"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)  FORCE="yes" ;;
    --reset)     MODE="reset" ;;
    --verify)    MODE="verify" ;;
    -h|--help)   sed -n '2,45p' "$0"; exit 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------- preflight --
command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found"
python3 - <<'PY' || die "python3 >= 3.9 is required (Path.is_relative_to)"
import sys
raise SystemExit(0 if sys.version_info >= (3, 9) else 1)
PY

if [ -e "$LAB" ] && [ ! -e "$LAB/.mcpa-lab" ]; then
  die "$LAB already exists and was not created by this lab; refusing to touch it"
fi

if [ "$MODE" = "verify" ]; then
  [ -x "$LAB/verify.sh" ] || die "no lab at $LAB — run this script without --verify first"
  exec "$LAB/verify.sh"
fi

if [ "$MODE" = "break" ] && [ "$FORCE" != "yes" ]; then
  if [ ! -t 0 ]; then die "stdin is not a terminal; re-run with --force"; fi
  printf 'This rebuilds %s from scratch and then breaks it on purpose. Continue? [y/N] ' "$LAB"
  read -r reply || reply=""
  case "$reply" in y|Y|yes|YES) ;; *) say "aborted."; exit 0 ;; esac
fi

# ------------------------------------------------------------- build the lab --
say ""
rule
say "  building the lab in $LAB"
rule

rm -rf "$LAB"
mkdir -p "$LAB/config" "$LAB/workspace/notes" "$LAB/workspace/archive"
: > "$LAB/.mcpa-lab"

# --- the MCP server ----------------------------------------------------------
cat > "$LAB/server.py" <<'SERVER_PY'
#!/usr/bin/env python3
"""notes-server — a minimal MCP-style stdio server for the MCPA 4.2 lab.

It speaks newline-delimited JSON-RPC 2.0 over stdin/stdout, the same framing an
MCP stdio server uses. It is deliberately tiny: this lab is about the host's
permission logic, not about the wire format.

Two authorization responsibilities live here, and only these two:
  * the resource server validates the access token it is presented with
    (audience + scope), and
  * it refuses any path outside its own data directory (defence in depth).
Everything else — user consent, policy, roots — belongs to the host.

Honest caveats, so nothing here is learned wrong:
  * OAuth 2.1 authorization is specified for HTTP-based transports; stdio
    servers take credentials from the environment. This lab carries the token
    in `_meta.authorization` purely as a stand-in for the `Authorization:
    Bearer` header, so the audience lesson can be practised locally.
  * A real resource server validates a *signed* token and never trusts claims
    handed to it by the client. Here the claims are read straight from JSON.
Spec: https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
"""

import json
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent
NOTES_DIR = (BASE / "workspace" / "notes").resolve()

# The canonical resource identifier of this server. An access token is only
# acceptable if it was issued *for this resource* (RFC 8707 resource indicators).
RESOURCE = "https://notes.mcpa.lab/mcp"
PROTOCOL_VERSION = "2025-06-18"

TOOLS = [
    {
        "name": "notes.list",
        "title": "List notes",
        "description": "List the notes stored in the workspace.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
        "scope": "notes:read",
    },
    {
        "name": "notes.read",
        "title": "Read a note",
        "description": "Return the contents of one note.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Absolute path of the note"}},
            "required": ["path"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
        "scope": "notes:read",
    },
    {
        "name": "notes.delete",
        "title": "Delete a note",
        "description": "Delete one note. Irreversible.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Absolute path of the note"}},
            "required": ["path"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": False},
        "scope": "notes:write",
    },
]


def tool_by_name(name):
    for tool in TOOLS:
        if tool["name"] == name:
            return tool
    return None


def result(rid, text, is_error=False):
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "result": {"isError": is_error, "content": [{"type": "text", "text": text}]},
    }


def error(rid, code, message, data=None):
    err = {"code": code, "message": message}
    if data:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": rid, "error": err}


def check_token(token, required_scope):
    """Return (reason, detail) when the presented token is unacceptable."""
    if not isinstance(token, dict) or not token.get("access_token"):
        return ("invalid_token", "no bearer token was presented")
    expires_at = float(token.get("expires_at") or 0)
    if expires_at and expires_at < time.time():
        return ("invalid_token", "the presented token has expired")
    audience = token.get("aud")
    if audience != RESOURCE:
        return (
            "invalid_token",
            'token audience "%s" is not this server ("%s"); a token issued for another '
            "resource must never be accepted or forwarded" % (audience, RESOURCE),
        )
    scopes = str(token.get("scope", "")).split()
    if required_scope not in scopes:
        return ("insufficient_scope", 'token scope %s does not include "%s"' % (scopes, required_scope))
    return None


def handle(request):
    rid = request.get("id")
    method = request.get("method")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "notes-server", "version": "1.0.0", "resource": RESOURCE},
            },
        }

    if method == "tools/list":
        listed = []
        for tool in TOOLS:
            entry = {k: v for k, v in tool.items() if k != "scope"}
            entry["_meta"] = {"requiredScope": tool["scope"]}
            listed.append(entry)
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": listed}}

    if method == "tools/call":
        params = request.get("params") or {}
        tool = tool_by_name(params.get("name", ""))
        if tool is None:
            return error(rid, -32602, 'unknown tool "%s"' % params.get("name", ""))

        meta = params.get("_meta") or {}
        problem = check_token(meta.get("authorization"), tool["scope"])
        if problem:
            reason, detail = problem
            return error(
                rid,
                -32001,
                detail,
                {
                    "code": "MCPA-401" if reason == "invalid_token" else "MCPA-403",
                    "reason": reason,
                    "resource": RESOURCE,
                    "requiredScope": tool["scope"],
                },
            )

        args = params.get("arguments") or {}
        try:
            if tool["name"] == "notes.list":
                names = sorted(p.name for p in NOTES_DIR.glob("*.md"))
                return result(rid, "\n".join(names) if names else "(no notes)")

            target = Path(str(args.get("path", ""))).expanduser().resolve()
            if not target.is_relative_to(NOTES_DIR):
                return error(
                    rid,
                    -32001,
                    "%s is outside the data directory this server owns (%s)" % (target, NOTES_DIR),
                    {"code": "MCPA-403", "reason": "resource_boundary"},
                )
            if tool["name"] == "notes.read":
                return result(rid, target.read_text(encoding="utf-8"))
            target.unlink()
            return result(rid, "deleted %s" % target.name)
        except OSError as exc:
            return result(rid, str(exc), is_error=True)

    if rid is None:
        return None
    return error(rid, -32601, 'method not found: "%s"' % method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(request)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
SERVER_PY

# --- the MCP host ------------------------------------------------------------
cat > "$LAB/host.py" <<'HOST_PY'
#!/usr/bin/env python3
"""mcpa-lab-host — the component that holds the user's consent.

In MCP the host is the trust boundary. The server *offers* capabilities; the
host decides whether the user actually agreed to any given invocation. This
host keeps four independent pieces of state under config/, and a tool call must
clear all four gates:

  gate 1  policy.json    operator policy    — what is permitted at all; deny beats allow
  gate 2  consent.json   the consent ledger — what the user granted, per tool, with scope and expiry
  gate 3  roots.json     declared roots     — the filesystem boundary handed to the server
  gate 4  token.json     access token       — audience-bound credential, checked by the server

Policy and consent are separate on purpose. The allow list says what the
operator tolerates; the ledger records what the human actually approved, when,
for which scope, and until when. Being on the allow list is necessary and not
sufficient — that is the whole idea behind "explicit user consent".

  https://modelcontextprotocol.io/specification/2025-06-18
  https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
  https://modelcontextprotocol.io/specification/2025-06-18/client/roots
  https://datatracker.ietf.org/doc/html/rfc8707
"""

import argparse
import fnmatch
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

BASE = Path(__file__).resolve().parent
CFG = BASE / "config"
SERVER_CMD = [sys.executable, str(BASE / "server.py")]
SERVER_ID = "notes-server"
PROTOCOL_VERSION = "2025-06-18"
CLIENT_INFO = {"name": "mcpa-lab-host", "version": "1.0.0"}

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_HOST_DENY = 3
EXIT_SERVER_DENY = 4


def fail(message):
    print("CONFIG ERROR: %s" % message, file=sys.stderr)
    raise SystemExit(EXIT_ERROR)


def load(name):
    path = CFG / name
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail("missing config file: %s" % path)
    except json.JSONDecodeError as exc:
        fail("%s is not valid JSON: %s" % (path, exc))


def save(name, doc):
    (CFG / name).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def stamp(epoch):
    epoch = float(epoch or 0)
    if not epoch:
        return "never"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def declared_roots():
    """Roots are file:// URIs, as handed to a server by roots/list."""
    paths = []
    for entry in load("roots.json").get("roots", []):
        uri = entry.get("uri", "") if isinstance(entry, dict) else str(entry)
        if not uri.startswith("file://"):
            continue
        paths.append(Path(unquote(urlparse(uri).path)).resolve())
    return paths


class Denial:
    def __init__(self, code, reason, detail, hint=""):
        self.code = code
        self.reason = reason
        self.detail = detail
        self.hint = hint


class Server:
    """Spawns the stdio server and speaks JSON-RPC to it."""

    def __init__(self):
        self.proc = subprocess.Popen(
            SERVER_CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )
        self._id = 0
        self.info = self.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"roots": {"listChanged": False}},
                "clientInfo": CLIENT_INFO,
            },
        ).get("result", {})
        self.notify("notifications/initialized")

    def _send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params=None):
        self._id += 1
        message = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)
        line = self.proc.stdout.readline()
        if not line:
            fail("the server closed the connection")
        return json.loads(line)

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)

    def tools(self):
        return self.request("tools/list").get("result", {}).get("tools", [])

    @property
    def resource(self):
        return self.info.get("serverInfo", {}).get("resource", "")

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def authorize(tool_name, required_scope, arguments, trace):
    """Run gates 1-3. Returns a Denial, or None when the call may be forwarded."""

    # --- gate 1: operator policy. A deny rule always wins over an allow rule.
    policy = load("policy.json")
    for pattern in policy.get("deny", []):
        if fnmatch.fnmatchcase(tool_name, pattern):
            return Denial(
                "MCPA-403",
                "policy_denied",
                'policy.json rule deny:"%s" matches "%s"' % (pattern, tool_name),
                "deny always wins over allow; that precedence is the point of a deny list",
            )
    matched = [p for p in policy.get("allow", []) if fnmatch.fnmatchcase(tool_name, p)]
    default_action = policy.get("default_action", "ask")
    if not matched and default_action == "deny":
        return Denial(
            "MCPA-403",
            "policy_default_deny",
            'no allow rule matches "%s" and default_action is "deny"' % tool_name,
            "",
        )
    trace.append(
        "gate 1/4 policy    OK   %s"
        % ('allow rule "%s"' % matched[0] if matched else "default_action=%s" % default_action)
    )

    # --- gate 2: the consent ledger. Consent is per tool, scoped, and expires.
    grants = load("consent.json").get("grants", [])
    grant = next(
        (g for g in grants if g.get("server") == SERVER_ID and g.get("tool") == tool_name), None
    )
    if grant is None:
        return Denial(
            "MCPA-401",
            "consent_missing",
            'the consent ledger holds no grant for "%s"' % tool_name,
            'consent is per tool: record one with "host.py grant <tool> --scope <scope>"',
        )
    expires_at = float(grant.get("expires_at") or 0)
    if expires_at and expires_at < time.time():
        return Denial(
            "MCPA-401",
            "consent_expired",
            'the grant for "%s" expired on %s' % (tool_name, stamp(expires_at)),
            "expiring consent is deliberate: the user re-approves instead of approving once forever",
        )
    if required_scope not in grant.get("scopes", []):
        return Denial(
            "MCPA-403",
            "consent_scope_insufficient",
            '"%s" needs scope "%s"; the grant carries %s'
            % (tool_name, required_scope, grant.get("scopes", [])),
            "",
        )
    trace.append(
        "gate 2/4 consent   OK   granted %s until %s" % (grant.get("scopes", []), stamp(expires_at))
    )

    # --- gate 3: roots. The boundary the host promised the user.
    roots = declared_roots()
    path = arguments.get("path")
    if path is None:
        trace.append("gate 3/4 roots     n/a  this call carries no filesystem argument")
        return None
    if not roots:
        return Denial(
            "MCPA-403", "roots_missing", "roots.json declares no root at all", "", 
        )
    target = Path(str(path)).expanduser().resolve()
    if not any(target == root or target.is_relative_to(root) for root in roots):
        return Denial(
            "MCPA-403",
            "roots_violation",
            "%s is outside every declared root: %s" % (target, ", ".join(str(r) for r in roots)),
            "widening a root to / is not a fix; point it at the directory the user meant to share",
        )
    trace.append("gate 3/4 roots     OK   %s is inside a declared root" % target)
    return None


def cmd_list_tools(args):
    server = Server()
    try:
        print("server   : %s" % server.info.get("serverInfo", {}).get("name"))
        print("resource : %s" % server.resource)
        print()
        print("%-14s %-12s %s" % ("tool", "scope", "annotations (server hints, NOT a security control)"))
        for tool in server.tools():
            scope = (tool.get("_meta") or {}).get("requiredScope", "")
            ann = tool.get("annotations", {})
            flags = "readOnly=%s destructive=%s" % (
                ann.get("readOnlyHint", False),
                ann.get("destructiveHint", False),
            )
            print("%-14s %-12s %s" % (tool["name"], scope, flags))
        print()
        print("Tool descriptions and annotations come from the server. Treat them as")
        print("untrusted input: the host, not the server, decides what may run.")
    finally:
        server.close()
    return EXIT_OK


def cmd_call(args):
    server = Server()
    try:
        catalog = {t["name"]: t for t in server.tools()}
        tool = catalog.get(args.tool)
        if tool is None:
            print(
                "unknown tool: %s (known: %s)" % (args.tool, ", ".join(sorted(catalog))),
                file=sys.stderr,
            )
            return EXIT_ERROR
        required_scope = (tool.get("_meta") or {}).get("requiredScope", "")

        arguments = {}
        if args.path is not None:
            arguments["path"] = args.path

        trace = []
        denial = authorize(args.tool, required_scope, arguments, trace)
        if args.explain:
            for line in trace:
                print(line)
        if denial is not None:
            if args.explain:
                print("gate %s BLOCKED %s" % (len(trace) + 1, denial.reason))
            print(
                "BLOCKED [%s %s] %s: %s" % (denial.code, denial.reason, args.tool, denial.detail),
                file=sys.stderr,
            )
            if denial.hint:
                print("        hint: %s" % denial.hint, file=sys.stderr)
            return EXIT_HOST_DENY

        token = load("token.json")
        reply = server.request(
            "tools/call",
            {"name": args.tool, "arguments": arguments, "_meta": {"authorization": token}},
        )
        if "error" in reply:
            err = reply["error"]
            data = err.get("data") or {}
            if args.explain:
                print("gate 4/4 token     FAIL %s" % data.get("reason", "server_error"))
            print(
                "REJECTED [%s %s] %s: %s"
                % (
                    data.get("code", "MCPA-400"),
                    data.get("reason", "server_error"),
                    args.tool,
                    err.get("message"),
                ),
                file=sys.stderr,
            )
            if data.get("resource"):
                print(
                    '        this resource server only accepts tokens whose audience is "%s"'
                    % data["resource"],
                    file=sys.stderr,
                )
            return EXIT_SERVER_DENY

        if args.explain:
            print("gate 4/4 token     OK   audience accepted by the resource server")
        payload = reply.get("result", {})
        for block in payload.get("content", []):
            print(block.get("text", ""))
        return EXIT_ERROR if payload.get("isError") else EXIT_OK
    finally:
        server.close()


def cmd_doctor(args):
    server = Server()
    try:
        policy = load("policy.json")
        token = load("token.json")
        print("host      : %s (protocol %s)" % (CLIENT_INFO["name"], PROTOCOL_VERSION))
        print("server    : %s" % server.info.get("serverInfo", {}).get("name"))
        print("resource  : %s" % server.resource)
        print(
            "policy    : default_action=%s allow=%s deny=%s"
            % (policy.get("default_action"), policy.get("allow", []), policy.get("deny", []))
        )
        roots = declared_roots()
        print("roots     : %s" % (", ".join(str(r) for r in roots) if roots else "(none)"))
        print(
            'token     : aud="%s" scope="%s" expires %s'
            % (token.get("aud"), token.get("scope"), stamp(token.get("expires_at")))
        )
        print("consent   :")
        grants = load("consent.json").get("grants", [])
        if not grants:
            print("  (the ledger is empty)")
        for grant in grants:
            expires_at = float(grant.get("expires_at") or 0)
            state = "EXPIRED" if expires_at and expires_at < time.time() else "active "
            print(
                "  %s %-14s scopes=%-16s until %s"
                % (state, grant.get("tool"), ",".join(grant.get("scopes", [])), stamp(expires_at))
            )
        print()
        sample = str(BASE / "workspace" / "notes" / "welcome.md")
        print("%-14s %-12s %s" % ("tool", "scope", "host decision"))
        for tool in server.tools():
            scope = (tool.get("_meta") or {}).get("requiredScope", "")
            properties = (tool.get("inputSchema") or {}).get("properties") or {}
            arguments = {"path": sample} if "path" in properties else {}
            denial = authorize(tool["name"], scope, arguments, [])
            verdict = (
                "forwarded to the server"
                if denial is None
                else "%s %s" % (denial.code, denial.reason)
            )
            print("%-14s %-12s %s" % (tool["name"], scope, verdict))
        print()
        print("(the decision column assumes path=%s)" % sample)
    finally:
        server.close()
    return EXIT_OK


def cmd_audit_token(args):
    server = Server()
    try:
        resource = server.resource
    finally:
        server.close()

    token = load("token.json")
    problems = []
    if not token.get("access_token"):
        problems.append("token.json carries no access_token")
    audience = token.get("aud")
    if audience != resource:
        problems.append(
            'audience "%s" is not this server\'s canonical resource "%s" (RFC 8707 resource indicators)'
            % (audience, resource)
        )
    expires_at = float(token.get("expires_at") or 0)
    if expires_at and expires_at < time.time():
        problems.append("the token expired on %s" % stamp(expires_at))

    token_scopes = set(str(token.get("scope", "")).split())
    consented = set()
    for grant in load("consent.json").get("grants", []):
        grant_expiry = float(grant.get("expires_at") or 0)
        if grant_expiry and grant_expiry < time.time():
            continue
        consented.update(grant.get("scopes", []))
    if not token_scopes:
        problems.append("the token carries no scope at all")
    extra = sorted(token_scopes - consented)
    if extra:
        problems.append(
            "the token carries scope(s) %s that no active consent grant covers (least privilege)"
            % extra
        )

    print("resource server : %s" % resource)
    print("token audience  : %s" % audience)
    print("token scope     : %s" % (" ".join(sorted(token_scopes)) or "(none)"))
    print("consented scope : %s" % (" ".join(sorted(consented)) or "(none)"))
    if problems:
        for problem in problems:
            print("  PROBLEM: %s" % problem, file=sys.stderr)
        return EXIT_SERVER_DENY
    print("TOKEN AUDIT OK")
    return EXIT_OK


def cmd_mint_token(args):
    server = Server()
    try:
        resource = server.resource
    finally:
        server.close()

    audience = args.aud or resource
    now = int(time.time())
    token = {
        "access_token": "lab-" + secrets.token_hex(12),
        "token_type": "Bearer",
        "aud": audience,
        "scope": " ".join(args.scope),
        "issued_at": now,
        "expires_at": now + args.ttl,
        "note": "lab stand-in for an OAuth 2.1 access token; a real one is signed and validated by the resource server",
    }
    save("token.json", token)
    print(
        'minted a token for audience "%s" with scope "%s", valid for %ds'
        % (audience, token["scope"], args.ttl)
    )
    if audience != resource:
        print(
            'WARNING: that audience is not this server ("%s"). It will be refused — and reusing '
            "another server's token is exactly the confused-deputy problem the spec forbids."
            % resource,
            file=sys.stderr,
        )
    else:
        print("(the audience defaulted to the resource this server advertises)")
    return EXIT_OK


def cmd_grant(args):
    doc = load("consent.json")
    now = int(time.time())
    grants = [
        g
        for g in doc.get("grants", [])
        if not (g.get("server") == SERVER_ID and g.get("tool") == args.tool)
    ]
    grants.append(
        {
            "server": SERVER_ID,
            "tool": args.tool,
            "scopes": args.scope,
            "granted_by": os.environ.get("USER", "lab-user"),
            "granted_at": now,
            "expires_at": now + args.ttl,
        }
    )
    doc["grants"] = sorted(grants, key=lambda g: g["tool"])
    save("consent.json", doc)
    print(
        "recorded consent: %s scopes=%s valid for %ds (until %s)"
        % (args.tool, args.scope, args.ttl, stamp(now + args.ttl))
    )
    return EXIT_OK


def cmd_revoke(args):
    doc = load("consent.json")
    before = len(doc.get("grants", []))
    doc["grants"] = [
        g
        for g in doc.get("grants", [])
        if not (g.get("server") == SERVER_ID and g.get("tool") == args.tool)
    ]
    save("consent.json", doc)
    print("revoked %d grant(s) for %s" % (before - len(doc["grants"]), args.tool))
    return EXIT_OK


def build_parser():
    parser = argparse.ArgumentParser(description="MCPA 4.2 lab host: consent, policy, roots, tokens")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("list-tools", help="discover the tools the server offers")
    p.set_defaults(func=cmd_list_tools)

    p = sub.add_parser("call", help="invoke a tool through every permission gate")
    p.add_argument("tool")
    p.add_argument("--path", default=None, help="absolute path argument, when the tool takes one")
    p.add_argument("--explain", action="store_true", help="print the decision trace, gate by gate")
    p.set_defaults(func=cmd_call)

    p = sub.add_parser("doctor", help="print all four gates and the decision for every tool")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("audit-token", help="check the access token's audience, expiry and scope")
    p.set_defaults(func=cmd_audit_token)

    p = sub.add_parser("mint-token", help="issue a fresh access token for this server")
    p.add_argument("--aud", default=None, help="audience (defaults to the resource the server advertises)")
    p.add_argument("--scope", nargs="+", default=["notes:read"])
    p.add_argument("--ttl", type=int, default=3600)
    p.set_defaults(func=cmd_mint_token)

    p = sub.add_parser("grant", help="record the user's consent for one tool")
    p.add_argument("tool")
    p.add_argument("--scope", nargs="+", required=True)
    p.add_argument("--ttl", type=int, default=86400)
    p.set_defaults(func=cmd_grant)

    p = sub.add_parser("revoke", help="drop the consent grant for one tool")
    p.add_argument("tool")
    p.set_defaults(func=cmd_revoke)

    return parser


if __name__ == "__main__":
    parsed = build_parser().parse_args()
    raise SystemExit(parsed.func(parsed))
HOST_PY

# --- acceptance checks -------------------------------------------------------
cat > "$LAB/verify.sh" <<'VERIFY_SH'
#!/usr/bin/env bash
# MCPA 4.2 lab — acceptance checks.
# Exit 0 only when every gate behaves: the allowed calls work AND the refusals
# still refuse, for the right reason. Weakening a gate does not pass.
set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST=(python3 "$BASE/host.py")
NOTE="$BASE/workspace/notes/welcome.md"
pass=0
fail=0

check() { # check <description> <expected-rc> <expected-substring> <host args...>
  local desc="$1" want_rc="$2" want_sub="$3"
  shift 3
  local out rc
  out="$("${HOST[@]}" "$@" 2>&1)"
  rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_sub"; then
    printf '  PASS  %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$desc"
    printf '        expected rc=%s containing "%s", got rc=%s:\n' "$want_rc" "$want_sub" "$rc"
    printf '%s\n' "$out" | sed 's/^/        | /'
    fail=$((fail + 1))
  fi
}

echo ""
echo "MCPA 4.2 — acceptance checks"
echo ""

check "notes.list is allowed and returns the catalogue" \
      0 "welcome.md" call notes.list

check "notes.read returns the note's contents" \
      0 "MCPA-4.2-OK" call notes.read --path "$NOTE"

check "notes.delete is still refused BY THE POLICY DENY RULE" \
      3 "policy_denied" call notes.delete --path "$NOTE"

check "a path outside the declared roots is still refused" \
      3 "roots_violation" call notes.read --path /etc/hostname

check "the access token is audience-bound and least-privilege" \
      0 "TOKEN AUDIT OK" audit-token

if [ -f "$NOTE" ]; then
  printf '  PASS  %s\n' "the sample note was never deleted"
  pass=$((pass + 1))
else
  printf '  FAIL  %s\n' "the sample note is gone — a destructive tool ran"
  fail=$((fail + 1))
fi

echo ""
echo "  $pass passed, $fail failed"
echo ""
[ "$fail" -eq 0 ]
VERIFY_SH

# --- lab data ----------------------------------------------------------------
cat > "$LAB/workspace/notes/welcome.md" <<'NOTE_MD'
# Welcome

MCPA-4.2-OK

This note exists so that a successful notes.read has something to return.
If you can read this through the host, gates 1 to 4 all said yes.
NOTE_MD

cat > "$LAB/workspace/notes/rfc8707.md" <<'NOTE_MD'
# Resource indicators, in one paragraph

An access token is issued *for* a specific resource. The client names that
resource when it asks for the token, and the resource server refuses any token
whose audience is somebody else. Without that binding, a server you talk to can
take the token you handed it and spend it against a different API in your name
— the confused deputy. Source: https://datatracker.ietf.org/doc/html/rfc8707
NOTE_MD

cat > "$LAB/workspace/archive/retired.md" <<'NOTE_MD'
# Retired note

Left over from an old migration. It lives outside the notes directory the
server owns, which is why even a correct root pointing here would not help.
NOTE_MD

# --- green configuration -----------------------------------------------------
NOW="$(date +%s)"
YEAR=$((NOW + 31536000))

cat > "$LAB/config/policy.json" <<EOF
{
  "_comment": "Operator policy. A deny rule always wins over an allow rule.",
  "default_action": "ask",
  "allow": ["notes.list", "notes.read"],
  "deny": ["notes.delete"]
}
EOF

cat > "$LAB/config/consent.json" <<EOF
{
  "_comment": "The consent ledger: what the user approved, per tool, with scope and expiry.",
  "grants": [
    {
      "server": "notes-server",
      "tool": "notes.list",
      "scopes": ["notes:read"],
      "granted_by": "lab-user",
      "granted_at": $NOW,
      "expires_at": $YEAR
    },
    {
      "server": "notes-server",
      "tool": "notes.read",
      "scopes": ["notes:read"],
      "granted_by": "lab-user",
      "granted_at": $NOW,
      "expires_at": $YEAR
    }
  ]
}
EOF

cat > "$LAB/config/roots.json" <<EOF
{
  "_comment": "Roots handed to the server: the only part of the filesystem it may touch.",
  "roots": [
    { "uri": "file://$LAB/workspace", "name": "notes workspace" }
  ]
}
EOF

cat > "$LAB/config/token.json" <<EOF
{
  "access_token": "lab-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')",
  "token_type": "Bearer",
  "aud": "https://notes.mcpa.lab/mcp",
  "scope": "notes:read",
  "issued_at": $NOW,
  "expires_at": $YEAR,
  "note": "lab stand-in for an OAuth 2.1 access token; a real one is signed and validated by the resource server"
}
EOF

chmod +x "$LAB/server.py" "$LAB/host.py" "$LAB/verify.sh"

# ----------------------------------------------------- prove the green state --
say ""
say "  checking the lab is green BEFORE breaking anything"
if ! "$LAB/verify.sh"; then
  die "the freshly built lab does not pass its own checks; nothing was broken"
fi

if [ "$MODE" = "reset" ]; then
  say ""
  rule
  say "  GREEN state restored in $LAB — nothing is broken."
  rule
  say ""
  exit 0
fi

# ------------------------------------------------------------ inject faults --
python3 - "$LAB" <<'BREAK_PY'
import json
import sys
import time
from pathlib import Path

cfg = Path(sys.argv[1]) / "config"


def edit(name, mutate):
    path = cfg / name
    doc = json.loads(path.read_text(encoding="utf-8"))
    mutate(doc)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


# Fault 1 — policy precedence: a broad deny rule was added "temporarily" during
# an incident and never removed. Deny beats allow, so it shadows everything.
def fault_policy(doc):
    doc["deny"] = ["notes.*", "notes.delete"]


# Fault 2 — consent lifecycle: the grant for notes.read has expired.
def fault_consent(doc):
    for grant in doc.get("grants", []):
        if grant.get("tool") == "notes.read":
            grant["expires_at"] = int(time.time()) - 3600


# Fault 3 — roots: the declared root was re-pointed at the archive during a
# migration, so the notes directory now sits outside the shared boundary.
def fault_roots(doc):
    for root in doc.get("roots", []):
        root["uri"] = root["uri"].rstrip("/") + "/archive"
        root["name"] = "archive (migration leftover)"


# Fault 4 — token audience: somebody pasted the calendar server's token into
# token.json, and widened its scope while they were at it.
def fault_token(doc):
    doc["aud"] = "https://calendar.mcpa.lab/mcp"
    doc["scope"] = "notes:read notes:write calendar:read"


edit("policy.json", fault_policy)
edit("consent.json", fault_consent)
edit("roots.json", fault_roots)
edit("token.json", fault_token)
BREAK_PY

# ---------------------------------------------------------------- briefing --
cat <<'BRIEF' | expand

======================================================================
  MCPA 4.2 — Permissions & Consent — the lab is now BROKEN on purpose
======================================================================

  Lab directory : @LAB@
  Blast radius  : that directory only. Delete it and the lab is gone.

SCENARIO

  A host application talks to one MCP server, "notes-server", over stdio.
  Yesterday a student could list and read notes through it. Today every tool
  call is refused. Nothing crashed: there is no traceback, no stack, no
  connection error. The server starts, the handshake succeeds, and the tool
  catalogue still lists three tools. Discovery works; invocation does not.

  Four independent gates stand between an intent and an invocation, and each
  one of them refuses differently:

    gate 1  policy.json    what the operator permits at all
    gate 2  consent.json   what the user actually granted, per tool, with expiry
    gate 3  roots.json     which part of the filesystem the server may touch
    gate 4  token.json     the credential the resource server will accept

SYMPTOM — what you will see

  Run the calls and read the codes. Depending on which gate you clear first,
  you will meet some of these, in roughly this order:

    BLOCKED  [MCPA-403 policy_denied]              notes.list / notes.read / notes.delete
    REJECTED [MCPA-401 invalid_token]              notes.list
    BLOCKED  [MCPA-401 consent_expired]            notes.read
    BLOCKED  [MCPA-403 roots_violation]            notes.read

  BLOCKED means the host stopped the call: the user's agent refused to act.
  REJECTED means the host forwarded it and the resource server refused the
  credential. Which of the two you get tells you which side of the trust
  boundary the problem is on. That distinction is the exam-relevant part.

OBJECTIVE — what you must achieve

  ./verify.sh prints 6 passed, 0 failed.

  It will not accept a fix that simply opens everything up. Specifically:

    * notes.delete must remain refused with the code policy_denied — blocked
      by an explicit deny rule, not merely because nobody consented to it.
      Emptying the deny list changes the code and fails the check.
    * reading /etc/hostname must remain refused with roots_violation.
      Declaring / as a root fails the check.
    * the access token must be audience-bound to this server and carry no
      scope that an active consent grant does not cover. Disabling the audit,
      or minting a token with notes:write "just in case", fails the check.

  In other words: restore the service without widening the permission surface.
  That is the whole discipline of this domain.

DIAGNOSE WITH

    cd @LAB@
    python3 host.py doctor                    # all four gates, and the verdict per tool
    python3 host.py list-tools                # what the server claims it offers
    python3 host.py call notes.list --explain            # the decision trace, gate by gate
    python3 host.py call notes.read --path @LAB@/workspace/notes/welcome.md --explain
    python3 host.py audit-token               # audience, expiry, scope vs consent
    ./verify.sh                               # the acceptance checks

  The configuration is four small JSON files under config/. Read them. The
  host also has commands that write them correctly — "host.py grant",
  "host.py revoke", "host.py mint-token" — which is how a real host records
  the answer to a consent prompt.

  Re-running this script rebuilds the lab and breaks it again, losing your
  work. While fixing, use  ./verify.sh  or  this-script --verify.

  Reference material:
    https://modelcontextprotocol.io/specification/2025-06-18
    https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
    https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
    https://modelcontextprotocol.io/specification/2025-06-18/client/roots
    https://datatracker.ietf.org/doc/html/rfc8707
    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/

======================================================================

BRIEF

exit 0

# ============================================================================
#  SOLUTION — do not read until you have tried it
# ============================================================================
#
#  STEP 0 — see all four gates at once
#  -----------------------------------
#    cd "$HOME/mcpa-lab-4.2"
#    python3 host.py doctor
#
#  doctor prints, in one screen: the policy, the roots, the token's audience
#  and scope, every grant with its expiry, and the resulting decision per tool.
#  Four things are wrong in it, and each maps to one gate. The lesson before
#  any editing: a permission failure has a *location*. Find it before guessing.
#
#
#  STEP 1 — gate 1, policy precedence
#  ----------------------------------
#  Symptom:
#    BLOCKED [MCPA-403 policy_denied] notes.list: policy.json rule deny:"notes.*"
#
#  Cause: config/policy.json grew a broad rule:
#      "deny": ["notes.*", "notes.delete"]
#  A deny rule always wins over an allow rule, so "notes.*" shadows the entire
#  allow list. This is the single most common self-inflicted outage in any
#  allow/deny system: a wildcard added during an incident and never removed.
#
#  Fix — remove ONLY the wildcard, keep the rule that is doing real work:
#      python3 - <<'PY'
#      import json, pathlib
#      p = pathlib.Path("config/policy.json")
#      d = json.loads(p.read_text())
#      d["deny"] = [r for r in d["deny"] if r != "notes.*"]
#      p.write_text(json.dumps(d, indent=2) + "\n")
#      PY
#
#  policy.json must end up as:
#      "default_action": "ask", "allow": ["notes.list","notes.read"], "deny": ["notes.delete"]
#
#  Why not just empty the deny list: notes.delete would then be refused only by
#  the absence of a grant (consent_missing). That is a weaker, accidental
#  refusal — one "grant" command away from deleting the student's notes. The
#  acceptance check asserts the code is policy_denied precisely to catch this.
#
#  Verify:  python3 host.py call notes.list --explain
#           -> gate 1 now passes; the next failure is further down the chain.
#
#
#  STEP 2 — gate 2, consent lifecycle
#  ----------------------------------
#  Symptom:
#    BLOCKED [MCPA-401 consent_expired] notes.read: the grant expired on <date>
#
#  Cause: the ledger entry for notes.read has expires_at in the past. Consent
#  in MCP is not a one-time switch: it is per tool, scoped, and revocable. An
#  expiry is what forces the human back into the loop.
#
#  Fix — re-consent. Let the host write the record; do not hand-edit a
#  timestamp, and above all do not delete the expires_at field:
#      python3 host.py grant notes.read --scope notes:read --ttl 86400
#
#  Check the ledger afterwards:
#      python3 host.py doctor    # both grants must read "active"
#
#  Note what you did NOT do: you did not grant notes:write, and you did not
#  grant notes.delete. Re-consent restores exactly what expired.
#
#
#  STEP 3 — gate 3, roots
#  ----------------------
#  Symptom:
#    BLOCKED [MCPA-403 roots_violation] notes.read:
#      .../workspace/notes/welcome.md is outside every declared root:
#      .../workspace/archive
#
#  Cause: config/roots.json points at workspace/archive, a leftover from a
#  migration. Roots are the boundary the host promises the user — "this server
#  sees this directory and nothing else". A root pointing at the wrong place
#  does not fail open; it fails closed, which is the correct behaviour.
#
#  Fix — point the root back at the workspace:
#      python3 - <<'PY'
#      import json, os, pathlib
#      lab = pathlib.Path.cwd()
#      p = lab / "config/roots.json"
#      d = json.loads(p.read_text())
#      d["roots"] = [{"uri": "file://%s/workspace" % lab, "name": "notes workspace"}]
#      p.write_text(json.dumps(d, indent=2) + "\n")
#      PY
#
#  Do NOT "fix" it with file:/// . That makes the symptom disappear and hands
#  the server the whole filesystem; the acceptance check reads /etc/hostname
#  through the host for exactly that reason and must still be refused.
#
#  Verify:  python3 host.py call notes.read --path "$PWD/workspace/notes/welcome.md" --explain
#           -> gates 1-3 pass; the call now reaches the server.
#
#
#  STEP 4 — gate 4, token audience (RFC 8707)
#  ------------------------------------------
#  Symptom:
#    REJECTED [MCPA-401 invalid_token] notes.list:
#      token audience "https://calendar.mcpa.lab/mcp" is not this server
#      ("https://notes.mcpa.lab/mcp")
#
#  Cause: config/token.json holds the calendar server's token, with its scope
#  widened to "notes:read notes:write calendar:read". Two separate mistakes:
#
#    (a) Token reuse across servers. An access token is issued for one
#        resource. Presenting it to another — or letting a server forward the
#        one you gave it — is the confused-deputy problem: that server can now
#        act as you against an API you never pointed it at. This is why the
#        spec requires clients to name the resource when requesting a token and
#        forbids token passthrough.
#    (b) Scope inflation. notes:write is in the token although no consent grant
#        covers it. A credential must not be stronger than the consent behind it.
#
#  Fix — mint a token for THIS resource, with only the scope actually granted:
#      python3 host.py mint-token --scope notes:read --ttl 3600
#
#  With no --aud, the audience defaults to the canonical resource the server
#  advertises at initialize. In a real deployment that value comes from the
#  protected-resource metadata the server publishes, not from a value typed by
#  hand — same principle, discovered rather than guessed.
#
#  Verify:  python3 host.py audit-token     # -> TOKEN AUDIT OK
#
#
#  STEP 5 — full acceptance
#  ------------------------
#      ./verify.sh
#
#  Expected:
#      PASS  notes.list is allowed and returns the catalogue
#      PASS  notes.read returns the note's contents
#      PASS  notes.delete is still refused BY THE POLICY DENY RULE
#      PASS  a path outside the declared roots is still refused
#      PASS  the access token is audience-bound and least-privilege
#      PASS  the sample note was never deleted
#      6 passed, 0 failed
#
#
#  WHY THE SHORTCUTS FAIL (each one is an exam distractor)
#  -------------------------------------------------------
#    "deny": []                      -> notes.delete now fails as consent_missing,
#                                       not policy_denied. Check 3 fails: an
#                                       explicit refusal was replaced by an
#                                       accidental one.
#    "default_action": "allow"       -> does not help at all; the ledger is a
#                                       separate gate, and the deny rule still
#                                       wins. Loosening policy never substitutes
#                                       for consent.
#    root = file:///                 -> check 4 fails. The roots mechanism exists
#                                       to be narrow; a root of / is the same as
#                                       no root.
#    grant --scope notes:read notes:write
#                                    -> check 5 fails only if the token also
#                                       carries notes:write, but you have now
#                                       consented to a destructive capability
#                                       nobody asked for. Grant what is used.
#    mint-token --aud <the calendar resource>
#                                    -> the server refuses it and prints the
#                                       audience it does accept. Read the error;
#                                       the resource server is telling you the
#                                       answer.
#    editing server.py to skip check_token
#                                    -> the server is not yours to weaken. In
#                                       this lab it is a file; in production it
#                                       is somebody else's API, and the audit
#                                       still fails.
#
#
#  WHAT TO CARRY INTO THE EXAM
#  ---------------------------
#    * The host is the trust boundary. It obtains and holds user consent; the
#      server never decides what the user agreed to.
#    * Consent is per tool, scoped, and expires. "Approved once" is not a
#      permission model.
#    * Policy and consent are different questions — what is permitted at all,
#      versus what this user actually approved. Both must say yes.
#    * Deny beats allow. Always. Wildcards in a deny list are outage-shaped.
#    * Roots are a promise about the filesystem, enforced by the host before
#      the call is forwarded — and re-checked by the server for itself.
#    * Tokens are audience-bound. Never reuse one across servers, never pass a
#      received token through to a third party, never carry scope beyond the
#      consent behind it.
#    * Tool names, descriptions and annotations come from the server and are
#      untrusted input. readOnlyHint is a hint, not a control.
#
#  Clean up:  rm -rf "$HOME/mcpa-lab-4.2"
# ============================================================================