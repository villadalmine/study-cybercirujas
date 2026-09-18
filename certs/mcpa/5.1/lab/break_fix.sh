#!/usr/bin/env bash
#
# =============================================================================
#  MCPA 5.1 - Roles, Responsibilities & Adoption
#  Break & fix lab: "the server that adopted itself"
# =============================================================================
#
#  Certification : MCPA - Model Context Protocol Associate (exam version 2026-07-28)
#  Domain 5.1    : Roles, Responsibilities & Adoption (exam weight 6.67%)
#
#  Official sources
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    https://modelcontextprotocol.io/specification/2025-06-18
#    https://modelcontextprotocol.io/specification/2025-06-18/architecture
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools   (tool annotations)
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
#
#  WHY THIS LAB EXISTS
#    MCP names three protocol roles - host, client, server - but an adoption in a
#    real organisation is carried by five HUMAN roles, and every outage in this
#    area comes from one of them doing another one's job:
#
#      host application owner  owns the consent surface and what the model may be
#                              asked to approve on the user's behalf
#      server maintainer       owns the tool contract: names, inputSchema and,
#                              critically, truthful annotations
#      security reviewer       owns risk tiering and the approval of record;
#                              never the person who wrote the server
#      platform team           owns the registry, the derived allowlist and the
#                              runtime; the registry is the single source of truth
#      service owner / on-call owns the thing after adoption day - a server with
#                              no reachable pager is an unowned server
#
#    This script builds an offline replica of that pipeline and then breaks it in
#    five places, one per role. Diagnosis is the exercise: the symptom you see is
#    one refused connection, but the cause is spread across five artifacts owned
#    by five different people.
#
#  SAFETY - read before running
#    * Everything is created under one directory (default /opt/mcpa-lab/5.1-roles-adoption).
#      No systemd unit is touched, no package is installed, no network call is made,
#      no file outside the lab root is written.
#    * The lab is a simulation: no MCP server process is ever executed.
#    * 'clean' deletes only a directory that carries this lab's marker file.
#    * Still: run it on a disposable lab VM, not on a workstation you care about.
#
#  REQUIREMENTS
#    bash 4+, python3 (standard library only), sha256sum, write access to the lab root.
#
#  USAGE
#    ./mcpa-5.1-break-fix.sh break      # build the lab, break it, print the briefing (default)
#    ./mcpa-5.1-break-fix.sh verify     # grade your fix
#    ./mcpa-5.1-break-fix.sh briefing   # reprint the briefing
#    ./mcpa-5.1-break-fix.sh reset      # rebuild the broken state, discarding your edits
#    ./mcpa-5.1-break-fix.sh clean      # delete the lab
#
#    Confirm with MCPA_LAB_CONFIRM=1 in the environment or the --yes flag.
#    Relocate with MCPA_LAB_ROOT=/some/dir.
#
# =============================================================================

set -euo pipefail

LAB_ROOT="${MCPA_LAB_ROOT:-/opt/mcpa-lab/5.1-roles-adoption}"
MARKER=".mcpa-lab-marker"
CONFIRM="${MCPA_LAB_CONFIRM:-0}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; RST=$'\e[0m'
else
    BOLD=""; RED=""; GRN=""; YEL=""; CYA=""; RST=""
fi

die()  { printf '%s\n' "${RED}error:${RST} $*" >&2; exit 1; }
info() { printf '%s\n' "${CYA}==>${RST} $*"; }
warn() { printf '%s\n' "${YEL}warning:${RST} $*"; }
head2(){ printf '\n%s\n' "${BOLD}$*${RST}"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_confirmation() {
    [[ "$CONFIRM" == "1" ]] && return 0
    cat <<EOF
${BOLD}This script creates and then deliberately breaks a lab under:${RST}
    ${LAB_ROOT}

It writes nowhere else, but it is meant for a DISPOSABLE lab VM.
Re-run with --yes, or export MCPA_LAB_CONFIRM=1, to continue.
EOF
    exit 1
}

guard_lab_root() {
    if [[ -e "$LAB_ROOT" && ! -f "$LAB_ROOT/$MARKER" ]]; then
        die "$LAB_ROOT exists and is not one of this lab's directories; refusing to touch it"
    fi
}

# -----------------------------------------------------------------------------
# Scaffold: the pristine, correct adoption pipeline
# -----------------------------------------------------------------------------
scaffold() {
    guard_lab_root
    rm -rf "$LAB_ROOT"
    mkdir -p "$LAB_ROOT"/bin \
             "$LAB_ROOT"/platform/handovers \
             "$LAB_ROOT"/servers/finance-ops \
             "$LAB_ROOT"/servers/wiki-reader \
             "$LAB_ROOT"/hosts/atlas-desk \
             "$LAB_ROOT"/governance/approvals \
             "$LAB_ROOT"/governance/reviews \
             "$LAB_ROOT"/governance/adoption-requests

    printf 'mcpa-5.1-roles-adoption lab, created %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LAB_ROOT/$MARKER"

    # ---------------------------------------------------------------- platform
    cat > "$LAB_ROOT/platform/teams.json" <<'JSON'
{
  "schema": "mcp.teams/v1",
  "maintained_by": "team-platform",
  "teams": {
    "team-platform": {
      "charter": "runs the MCP runtime, owns platform/registry.json and the derived allowlist",
      "oncall": "platform-oncall@lab.internal"
    },
    "team-secops": {
      "charter": "security review, risk tiering and the approval of record for every MCP server",
      "oncall": "secops-oncall@lab.internal"
    },
    "team-workspace": {
      "charter": "owns the atlas-desk host application, its MCP clients and its consent UX",
      "oncall": "workspace-oncall@lab.internal"
    },
    "team-knowledge": {
      "charter": "builds and operates the wiki-reader MCP server",
      "oncall": "knowledge-oncall@lab.internal"
    },
    "team-fin-integrations": {
      "charter": "builds and operates the finance-ops MCP server",
      "oncall": "fin-oncall@lab.internal"
    }
  }
}
JSON

    cat > "$LAB_ROOT/platform/registry.json" <<'JSON'
{
  "schema": "mcp.registry/v1",
  "maintained_by": "team-platform",
  "servers": [
    {
      "id": "wiki-reader",
      "maintainer": "team-knowledge",
      "owner": "team-knowledge",
      "risk_tier": "low",
      "transport": "stdio",
      "data_classification": "internal",
      "approval": "SR-2104",
      "adopted_on": "2026-06-02"
    },
    {
      "id": "finance-ops",
      "maintainer": "team-fin-integrations",
      "owner": "team-fin-integrations",
      "risk_tier": "high",
      "transport": "stdio",
      "data_classification": "restricted",
      "approval": "SR-2291",
      "adopted_on": "2026-09-08"
    }
  ]
}
JSON

    cat > "$LAB_ROOT/platform/handovers/2026-08-31-team-atlas-legacy-dissolved.md" <<'MD'
# Ownership handover - team-atlas-legacy dissolved

Date: 2026-08-31
Filed by: team-platform

team-atlas-legacy was dissolved on 2026-08-31. Its pager rotation was deleted
the same day, so any registry entry still naming it has no reachable on-call.

Services transferred:

| service                | new owner      | new maintainer  |
|------------------------|----------------|-----------------|
| wiki-reader MCP server | team-knowledge | team-knowledge  |

An MCP server whose `owner` does not resolve to a team with a pager is an
unowned server: nobody is accountable for its tool contract, its credentials
or its incident response. The platform team must reconcile the registry.
MD

    # ----------------------------------------------------------------- servers
    cat > "$LAB_ROOT/servers/wiki-reader/server.json" <<'JSON'
{
  "schema": "mcp.server/v1",
  "name": "wiki-reader",
  "version": "3.1.2",
  "maintainer": "team-knowledge",
  "transport": "stdio",
  "capabilities": {
    "tools": {"listChanged": true},
    "resources": {"subscribe": false, "listChanged": true}
  }
}
JSON

    cat > "$LAB_ROOT/servers/wiki-reader/tools.json" <<'JSON'
{
  "schema": "mcp.tools/v1",
  "tools": [
    {
      "name": "search_wiki",
      "description": "Full text search over the internal wiki index.",
      "inputSchema": {
        "type": "object",
        "properties": {"query": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 50}},
        "required": ["query"],
        "additionalProperties": false
      },
      "annotations": {
        "title": "Search the wiki",
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false
      }
    },
    {
      "name": "fetch_page",
      "description": "Return the rendered markdown of one wiki page by slug.",
      "inputSchema": {
        "type": "object",
        "properties": {"slug": {"type": "string"}},
        "required": ["slug"],
        "additionalProperties": false
      },
      "annotations": {
        "title": "Fetch a wiki page",
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false
      }
    }
  ]
}
JSON

    cat > "$LAB_ROOT/servers/finance-ops/server.json" <<'JSON'
{
  "schema": "mcp.server/v1",
  "name": "finance-ops",
  "version": "1.4.0",
  "maintainer": "team-fin-integrations",
  "transport": "stdio",
  "capabilities": {
    "tools": {"listChanged": true},
    "resources": {"subscribe": false, "listChanged": false}
  }
}
JSON

    cat > "$LAB_ROOT/servers/finance-ops/tools.json" <<'JSON'
{
  "schema": "mcp.tools/v1",
  "tools": [
    {
      "name": "list_accounts",
      "description": "Return the ledger accounts the caller is entitled to see.",
      "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
      "annotations": {
        "title": "List ledger accounts",
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false
      }
    },
    {
      "name": "transfer_funds",
      "description": "Move money between two ledger accounts. Irreversible once settled.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "from": {"type": "string"},
          "to": {"type": "string"},
          "amount_cents": {"type": "integer", "minimum": 1}
        },
        "required": ["from", "to", "amount_cents"],
        "additionalProperties": false
      },
      "annotations": {
        "title": "Transfer funds between accounts",
        "readOnlyHint": false,
        "destructiveHint": true,
        "idempotentHint": false,
        "openWorldHint": false
      }
    }
  ]
}
JSON

    printf '#!/usr/bin/env bash\n# lab stub - never executed by this lab\necho "wiki-reader stdio server"\n' \
        > "$LAB_ROOT/servers/wiki-reader/run.sh"
    printf '#!/usr/bin/env bash\n# lab stub - never executed by this lab\necho "finance-ops stdio server"\n' \
        > "$LAB_ROOT/servers/finance-ops/run.sh"
    chmod 0644 "$LAB_ROOT"/servers/*/run.sh

    # -------------------------------------------------------------------- host
    cat > "$LAB_ROOT/hosts/atlas-desk/mcp.json" <<'JSON'
{
  "schema": "mcp.hostconfig/v1",
  "host": "atlas-desk",
  "owner": "team-workspace",
  "protocolVersion": "2025-06-18",
  "mcpServers": {
    "wiki-reader": {
      "transport": "stdio",
      "command": "servers/wiki-reader/run.sh",
      "args": [],
      "consent": "per-session",
      "sampling": "deny"
    },
    "finance-ops": {
      "transport": "stdio",
      "command": "servers/finance-ops/run.sh",
      "args": [],
      "consent": "per-call",
      "sampling": "deny"
    }
  }
}
JSON

    # -------------------------------------------------------------- governance
    cat > "$LAB_ROOT/governance/policy.json" <<'JSON'
{
  "schema": "mcp.governance.policy/v1",
  "owner": "team-secops",
  "protocol_version": "2025-06-18",
  "registry_required_fields": ["id", "maintainer", "owner", "risk_tier", "transport", "approval", "adopted_on"],
  "consent_rules": {"high": "per-call", "medium": "per-session", "low": "per-session"},
  "separation_of_duties": {
    "approver_role": "security-reviewer",
    "approver_must_differ_from_maintainer": true
  },
  "dangerous_verbs": ["transfer", "delete", "drop", "revoke", "purge", "wire", "rotate"],
  "required_tool_annotations": ["title", "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"]
}
JSON

    cat > "$LAB_ROOT/governance/reviews/SR-2104.json" <<'JSON'
{
  "schema": "mcp.review/v1",
  "id": "SR-2104",
  "server": "wiki-reader",
  "server_version": "3.1.2",
  "risk_tier": "low",
  "decision": "approved",
  "reviewer": {"name": "M. Okonjo", "team": "team-secops", "role": "security-reviewer"},
  "completed_on": "2026-06-01",
  "conditions": ["read-only tool surface", "no sampling capability granted to this server"],
  "notes": "Internal wiki content only. Prompt injection risk accepted: the host renders tool results as untrusted text."
}
JSON

    cat > "$LAB_ROOT/governance/reviews/SR-2291.json" <<'JSON'
{
  "schema": "mcp.review/v1",
  "id": "SR-2291",
  "server": "finance-ops",
  "server_version": "1.4.0",
  "risk_tier": "high",
  "decision": "approved",
  "reviewer": {"name": "M. Okonjo", "team": "team-secops", "role": "security-reviewer"},
  "completed_on": "2026-09-08",
  "conditions": [
    "per-call human consent for every tool call on this server",
    "no sampling capability granted to this server",
    "transfer_funds must carry readOnlyHint=false and destructiveHint=true",
    "adoption limited to host atlas-desk"
  ],
  "notes": "Review of record. An approval record filed against this review must be signed by team-secops, not by the maintainer of the server."
}
JSON

    cat > "$LAB_ROOT/governance/approvals/wiki-reader.json" <<'JSON'
{
  "schema": "mcp.approval/v1",
  "server": "wiki-reader",
  "server_version": "3.1.2",
  "risk_tier": "low",
  "decision": "approved",
  "review": "SR-2104",
  "approver": {"name": "M. Okonjo", "team": "team-secops", "role": "security-reviewer"},
  "approved_on": "2026-06-01",
  "scope": {"hosts": ["atlas-desk"], "consent": "per-session"}
}
JSON

    cat > "$LAB_ROOT/governance/approvals/finance-ops.json" <<'JSON'
{
  "schema": "mcp.approval/v1",
  "server": "finance-ops",
  "server_version": "1.4.0",
  "risk_tier": "high",
  "decision": "approved",
  "review": "SR-2291",
  "approver": {"name": "M. Okonjo", "team": "team-secops", "role": "security-reviewer"},
  "approved_on": "2026-09-08",
  "scope": {"hosts": ["atlas-desk"], "consent": "per-call"}
}
JSON

    cat > "$LAB_ROOT/governance/adoption-requests/wiki-reader.json" <<'JSON'
{
  "schema": "mcp.adoption-request/v1",
  "server": "wiki-reader",
  "host": "atlas-desk",
  "requested_by": "team-knowledge",
  "maintainer": "team-knowledge",
  "proposed_owner": "team-knowledge",
  "transport": "stdio",
  "data_classification": "internal",
  "review": "SR-2104",
  "submitted_on": "2026-05-20"
}
JSON

    cat > "$LAB_ROOT/governance/adoption-requests/finance-ops.json" <<'JSON'
{
  "schema": "mcp.adoption-request/v1",
  "server": "finance-ops",
  "host": "atlas-desk",
  "requested_by": "team-fin-integrations",
  "maintainer": "team-fin-integrations",
  "proposed_owner": "team-fin-integrations",
  "transport": "stdio",
  "data_classification": "restricted",
  "review": "SR-2291",
  "submitted_on": "2026-09-01"
}
JSON

    scaffold_tooling
    python3 "$LAB_ROOT/bin/mcp-sync-allowlist" >/dev/null
    write_manifest
}

# -----------------------------------------------------------------------------
# Scaffold: the tooling (governance-owned, checksummed, not yours to edit)
# -----------------------------------------------------------------------------
scaffold_tooling() {
    cat > "$LAB_ROOT/bin/mcpa_common.py" <<'PY'
"""Shared helpers for the MCPA 5.1 lab tooling. Governance-owned, checksummed."""

import json
import os
from pathlib import Path


def lab_root(script_file):
    return Path(os.environ.get("MCPA_LAB_ROOT", str(Path(script_file).resolve().parents[1])))


def try_json(root, rel):
    """Return (data, error_message). Never raises."""
    path = Path(root) / rel
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, "%s does not exist" % rel
    except json.JSONDecodeError as exc:
        return None, "%s is not valid JSON (%s)" % (rel, exc)


def approval_problems(root, entry, policy):
    """Reasons why this registry entry does not carry a usable approval.

    An empty list means: a security reviewer who is not the maintainer approved
    exactly the version of the server that is shipping, against a review of
    record that still says the same thing.
    """
    sid = entry.get("id", "?")
    sod = policy.get("separation_of_duties", {})
    problems = []

    server, err = try_json(root, "servers/%s/server.json" % sid)
    if err:
        problems.append(err)
        server = {}

    approval, err = try_json(root, "governance/approvals/%s.json" % sid)
    if err:
        problems.append("no usable approval record: %s" % err)
        return problems

    if approval.get("decision") != "approved":
        problems.append("approval decision is %r, not 'approved'" % approval.get("decision"))

    approver = approval.get("approver") or {}
    want_role = sod.get("approver_role", "security-reviewer")
    if approver.get("role") != want_role:
        problems.append("approver role is %r; policy requires %r"
                        % (approver.get("role"), want_role))
    if sod.get("approver_must_differ_from_maintainer", True) and \
            approver.get("team") == entry.get("maintainer"):
        problems.append("separation of duties: approver team %r is the maintainer of the server"
                        % approver.get("team"))

    shipped = server.get("version")
    if shipped and approval.get("server_version") != shipped:
        problems.append("approval covers version %r but servers/%s/server.json ships %r"
                        % (approval.get("server_version"), sid, shipped))

    if entry.get("risk_tier") and approval.get("risk_tier") != entry.get("risk_tier"):
        problems.append("registry risk tier %r does not match the approved tier %r"
                        % (entry.get("risk_tier"), approval.get("risk_tier")))

    review_id = approval.get("review")
    if not review_id:
        problems.append("approval record references no review of record ('review')")
        return problems

    if entry.get("approval") and entry.get("approval") != review_id:
        problems.append("registry entry cites approval %r but the approval record cites review %r"
                        % (entry.get("approval"), review_id))

    review, err = try_json(root, "governance/reviews/%s.json" % review_id)
    if err:
        problems.append("review of record %s: %s" % (review_id, err))
        return problems

    reviewer = review.get("reviewer") or {}
    if review.get("server") != sid:
        problems.append("review %s is about server %r, not %r" % (review_id, review.get("server"), sid))
    if review.get("decision") != "approved":
        problems.append("review %s decision is %r" % (review_id, review.get("decision")))
    if reviewer.get("team") != approver.get("team"):
        problems.append("approval is signed by %r but review %s was performed by %r"
                        % (approver.get("team"), review_id, reviewer.get("team")))
    if review.get("server_version") != approval.get("server_version"):
        problems.append("review %s covers version %r, approval claims %r"
                        % (review_id, review.get("server_version"), approval.get("server_version")))
    if review.get("risk_tier") != approval.get("risk_tier"):
        problems.append("review %s sets risk tier %r, approval claims %r"
                        % (review_id, review.get("risk_tier"), approval.get("risk_tier")))
    return problems
PY

    cat > "$LAB_ROOT/bin/mcp-sync-allowlist" <<'PY'
#!/usr/bin/env python3
"""Platform tool: regenerate platform/allowlist.json from the registry.

The allowlist is DERIVED, never hand written. A server reaches a host only when
the platform team holds an adoption record for it and governance holds a valid
approval on the version that is shipping.
"""

import datetime
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcpa_common import lab_root, try_json, approval_problems  # noqa: E402

ROOT = lab_root(__file__)

policy, perr = try_json(ROOT, "governance/policy.json")
if perr:
    print("cannot read the governance policy: %s" % perr)
    sys.exit(1)

registry, rerr = try_json(ROOT, "platform/registry.json")
if rerr:
    print("cannot read the registry: %s" % rerr)
    sys.exit(1)

allowed, skipped = [], []
for entry in registry.get("servers", []):
    if not isinstance(entry, dict) or not entry.get("id"):
        skipped.append(("<malformed entry>", ["registry entry has no 'id'"]))
        continue
    problems = approval_problems(ROOT, entry, policy)
    if problems:
        skipped.append((entry["id"], problems))
    else:
        allowed.append(entry["id"])

out = {
    "schema": "mcp.allowlist/v1",
    "generated_by": "bin/mcp-sync-allowlist",
    "generated_on": datetime.date.today().isoformat(),
    "servers": sorted(allowed),
}
(ROOT / "platform" / "allowlist.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")

for sid, problems in skipped:
    print("skipped %-14s %s" % (sid, problems[0]))
print("allowlist written: %s" % (", ".join(sorted(allowed)) or "(empty)"))
PY

    cat > "$LAB_ROOT/bin/mcp-host-sim" <<'PY'
#!/usr/bin/env python3
"""Simulator of the atlas-desk host application starting its MCP clients.

One client per server connection, as the MCP architecture prescribes. The host
resolves every declared server against the platform allowlist and the consent
policy BEFORE any initialize handshake: an unadopted server never gets a
process, and a high risk server never gets silent auto-approval.

Nothing is executed: the handshake is printed, not performed.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcpa_common import lab_root, try_json  # noqa: E402

ROOT = lab_root(__file__)
HOST = "atlas-desk"


def log(msg):
    print("[host %s] %s" % (HOST, msg))


host_cfg, err = try_json(ROOT, "hosts/%s/mcp.json" % HOST)
if err:
    log("fatal: %s" % err)
    sys.exit(2)

allowlist, aerr = try_json(ROOT, "platform/allowlist.json")
if aerr:
    log("fatal: %s" % aerr)
    sys.exit(2)

registry, _ = try_json(ROOT, "platform/registry.json")
policy, _ = try_json(ROOT, "governance/policy.json")
registry = registry or {"servers": []}
policy = policy or {}

allowed = set(allowlist.get("servers", []))
reg = {s.get("id"): s for s in registry.get("servers", []) if isinstance(s, dict)}
declared = host_cfg.get("mcpServers", {})

log("host application owner: %s" % host_cfg.get("owner"))
log("MCP protocol version  : %s" % host_cfg.get("protocolVersion"))
log("declared servers      : %s" % (", ".join(sorted(declared)) or "(none)"))

refused = 0
for n, sid in enumerate(sorted(declared), 1):
    conn = declared[sid]
    print("")
    log("client #%d -> server '%s' over %s" % (n, sid, conn.get("transport")))

    if sid not in allowed:
        log("  REFUSED: '%s' is not in platform/allowlist.json" % sid)
        log("  the platform team holds no adoption record for this server; no client is started")
        refused += 1
        continue

    entry = reg.get(sid, {})
    tier = entry.get("risk_tier", "high")
    required = (policy.get("consent_rules") or {}).get(tier)
    if required and conn.get("consent") != required:
        log("  REFUSED: consent mode %r violates the consent policy for risk tier %r (requires %r)"
            % (conn.get("consent"), tier, required))
        refused += 1
        continue

    server, serr = try_json(ROOT, "servers/%s/server.json" % sid)
    if serr:
        log("  REFUSED: %s" % serr)
        refused += 1
        continue

    caps = {}
    if conn.get("sampling") == "allow":
        caps["sampling"] = {}
    init = {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": host_cfg.get("protocolVersion"),
            "capabilities": caps,
            "clientInfo": {"name": "%s-client" % HOST, "version": "2.3.0"},
        },
    }
    result = {
        "jsonrpc": "2.0", "id": 1,
        "result": {
            "protocolVersion": host_cfg.get("protocolVersion"),
            "capabilities": server.get("capabilities", {}),
            "serverInfo": {"name": server.get("name"), "version": server.get("version")},
        },
    }
    log("  -> %s" % json.dumps(init, separators=(",", ":")))
    log("  <- %s" % json.dumps(result, separators=(",", ":")))
    log("  connected: owner=%s tier=%s consent=%s"
        % (entry.get("owner"), tier, conn.get("consent")))

    tools, terr = try_json(ROOT, "servers/%s/tools.json" % sid)
    if terr:
        log("  tools/list: %s" % terr)
        continue
    for tool in tools.get("tools", []):
        ann = tool.get("annotations") or {}
        log("  tools/list: %-16s readOnlyHint=%-5s destructiveHint=%-5s -> consent prompt: %s"
            % (tool.get("name"), ann.get("readOnlyHint"), ann.get("destructiveHint"),
               "silent" if ann.get("readOnlyHint") is True and conn.get("consent") != "per-call" else conn.get("consent")))

print("")
if refused:
    log("%d of %d declared servers refused. Host started degraded." % (refused, len(declared)))
    sys.exit(1)
log("all %d declared servers connected." % len(declared))
sys.exit(0)
PY

    cat > "$LAB_ROOT/bin/mcp-adoption-gate" <<'PY'
#!/usr/bin/env python3
"""MCP adoption gate - governance control owned by team-secops.

Every finding names the accountable role, because in this domain the fix is
almost never "change the file that complains": it is "the right role does the
thing only that role may do".

This file is listed in governance/MANIFEST.sha256. Editing the gate to make the
pipeline pass is detected by the lab's verify step, and by the control that
watches your policy bundle in a real shop.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcpa_common import lab_root, try_json, approval_problems  # noqa: E402

ROOT = lab_root(__file__)
FAILURES = []

CHECKS = [
    ("G1", "every server a host talks to has an adoption record in the registry"),
    ("G2", "every registry entry resolves to a team that exists and carries a pager"),
    ("G3", "every adopted server has a valid approval, signed by a reviewer who is not the maintainer"),
    ("G4", "host consent mode matches the risk tier the security review assigned"),
    ("G5", "tool annotations describe what the tool actually does"),
    ("G6", "the allowlist is derived from the registry, not hand edited"),
    ("G7", "approved servers are deployed on the host they were approved for"),
]


def fail(code, role, what, fix):
    FAILURES.append((code, role, what, fix))


def must(rel, role="platform team"):
    data, err = try_json(ROOT, rel)
    if err:
        fail("G0", role, err, "restore the file, or rebuild the lab with the 'reset' subcommand")
        return {}
    return data


policy = must("governance/policy.json", "security reviewer")
teams = must("platform/teams.json").get("teams", {})
registry = must("platform/registry.json")
allowlist = must("platform/allowlist.json")
host = must("hosts/atlas-desk/mcp.json", "host application owner")

reg = {s.get("id"): s for s in registry.get("servers", []) if isinstance(s, dict)}
declared = host.get("mcpServers", {}) or {}

# --- G1: adoption record ------------------------------------------------------
for sid in sorted(declared):
    if sid not in reg:
        fail("G1", "platform team + requesting team",
             "host 'atlas-desk' declares server '%s', which has no entry in platform/registry.json" % sid,
             "create the adoption record from governance/adoption-requests/%s.json and its review of record; "
             "wiring a server into a host config is not adoption" % sid)

for sid, entry in sorted(reg.items()):
    missing = [f for f in policy.get("registry_required_fields", []) if not entry.get(f)]
    if missing:
        fail("G1", "platform team",
             "registry entry '%s' is missing required field(s): %s" % (sid, ", ".join(missing)),
             "an entry without those fields cannot be audited; fill them from the adoption request and the review")

# --- G2: ownership resolves to a team with a pager ----------------------------
if host.get("owner") and host.get("owner") not in teams:
    fail("G2", "platform team",
         "host 'atlas-desk' names owner %r, which is not in platform/teams.json" % host.get("owner"),
         "a host application with no owning team has no one accountable for its consent surface")

for sid, entry in sorted(reg.items()):
    for field in ("maintainer", "owner"):
        team = entry.get(field)
        if not team:
            continue
        if team not in teams:
            fail("G2", "platform team / service owner",
                 "registry entry '%s' names %s %r, which does not exist in platform/teams.json" % (sid, field, team),
                 "reassign to the team that took the service over - see platform/handovers/")
        elif not (teams.get(team) or {}).get("oncall"):
            fail("G2", "platform team / service owner",
                 "team %r owns '%s' but has no on-call address" % (team, sid),
                 "an MCP server with no reachable pager is an unowned server")

# --- G3: approval and separation of duties ------------------------------------
for sid, entry in sorted(reg.items()):
    for problem in approval_problems(ROOT, entry, policy):
        fail("G3", "security reviewer (team-secops)",
             "%s: %s" % (sid, problem),
             "file the approval record from the review of record in governance/reviews/; "
             "the maintainer of a server may never be its approver")

# --- G4: consent binding ------------------------------------------------------
for sid in sorted(declared):
    entry = reg.get(sid)
    if not entry:
        continue
    tier = entry.get("risk_tier")
    required = (policy.get("consent_rules") or {}).get(tier)
    actual = declared[sid].get("consent")
    if required and actual != required:
        fail("G4", "host application owner (team-workspace)",
             "host declares consent %r for '%s', whose risk tier is %r and requires %r"
             % (actual, sid, tier, required),
             "the host owns the consent surface: set consent to %r in hosts/atlas-desk/mcp.json" % required)
    if declared[sid].get("sampling") == "allow":
        fail("G4", "host application owner (team-workspace)",
             "host grants the sampling capability to '%s'" % sid,
             "no review in this lab grants sampling; a server that can ask the host for completions can drive the model")

# --- G5: truthful tool annotations --------------------------------------------
verbs = [v.lower() for v in policy.get("dangerous_verbs", [])]
required_ann = policy.get("required_tool_annotations", [])
for sid in sorted(reg):
    tools, err = try_json(ROOT, "servers/%s/tools.json" % sid)
    if err:
        fail("G5", "server maintainer", err, "every adopted server must publish its tool contract")
        continue
    for tool in tools.get("tools", []):
        name = tool.get("name", "?")
        ann = tool.get("annotations") or {}
        missing = [a for a in required_ann if a not in ann]
        if missing:
            fail("G5", "server maintainer",
                 "%s: tool '%s' does not declare %s" % (sid, name, ", ".join(missing)),
                 "annotations are the only thing the host can render consent from; declare all of them")
        blob = ("%s %s" % (name, tool.get("description", ""))).lower()
        if any(v in blob for v in verbs):
            if ann.get("readOnlyHint") is True:
                fail("G5", "server maintainer",
                     "%s: tool '%s' claims readOnlyHint=true but its contract describes a state changing operation"
                     % (sid, name),
                     "set readOnlyHint=false; a false read-only hint makes the host skip the warning the user needed")
            if ann.get("destructiveHint") is False:
                fail("G5", "server maintainer",
                     "%s: tool '%s' claims destructiveHint=false for an irreversible operation" % (sid, name),
                     "set destructiveHint=true - see the conditions of the review of record")

# --- G6: the allowlist is derived ---------------------------------------------
expected = sorted(sid for sid, entry in reg.items() if not approval_problems(ROOT, entry, policy))
current = sorted(allowlist.get("servers", []))
if expected != current:
    fail("G6", "platform team",
         "platform/allowlist.json contains %s but the registry plus valid approvals imply %s"
         % (current or "[]", expected or "[]"),
         "regenerate it: python3 bin/mcp-sync-allowlist  (the allowlist is derived, never hand edited)")

# --- G7: approved scope is actually deployed ----------------------------------
req_dir = ROOT / "governance" / "adoption-requests"
for path in sorted(req_dir.glob("*.json")) if req_dir.is_dir() else []:
    req, err = try_json(ROOT, "governance/adoption-requests/%s" % path.name)
    if err:
        continue
    review, rerr = try_json(ROOT, "governance/reviews/%s.json" % req.get("review"))
    if rerr or (review or {}).get("decision") != "approved":
        continue
    sid = req.get("server")
    if sid not in reg:
        fail("G7", "adoption owner (requesting team + platform team)",
             "'%s' holds an approved review (%s) but no registry entry" % (sid, req.get("review")),
             "finish the adoption; an approved review is not an adoption record")
    if req.get("host") == host.get("host") and sid not in declared:
        fail("G7", "host application owner (team-workspace)",
             "'%s' was approved for host '%s' but is no longer declared in its config" % (sid, req.get("host")),
             "deleting the server from the host config is not a fix: adopt it through the pipeline")

# --- report -------------------------------------------------------------------
print("MCP adoption gate - lab root: %s" % ROOT)
print("")
if not FAILURES:
    for code, text in CHECKS:
        print("  PASS [%s] %s" % (code, text))
    print("")
    print("adoption gate: PASS")
    sys.exit(0)

print("adoption gate: FAIL - %d finding(s)" % len(FAILURES))
print("")
for i, (code, role, what, fix) in enumerate(FAILURES, 1):
    print("%2d. [%s] accountable role: %s" % (i, code, role))
    print("     what : %s" % what)
    print("     fix  : %s" % fix)
    print("")
sys.exit(1)
PY

    chmod 0755 "$LAB_ROOT"/bin/mcp-adoption-gate "$LAB_ROOT"/bin/mcp-host-sim "$LAB_ROOT"/bin/mcp-sync-allowlist
    chmod 0644 "$LAB_ROOT"/bin/mcpa_common.py
}

write_manifest() {
    ( cd "$LAB_ROOT" && sha256sum \
        bin/mcpa_common.py bin/mcp-adoption-gate bin/mcp-host-sim bin/mcp-sync-allowlist \
        governance/policy.json platform/teams.json \
        governance/reviews/*.json governance/adoption-requests/*.json \
        platform/handovers/*.md > governance/MANIFEST.sha256 )
}

# -----------------------------------------------------------------------------
# The break: five defects, one per accountable role
# -----------------------------------------------------------------------------
inject_faults() {
    python3 - "$LAB_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])


def load(rel):
    return json.loads((root / rel).read_text(encoding="utf-8"))


def save(rel, data):
    (root / rel).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


# F1 - platform team / requesting team:
#      finance-ops was wired straight into the host config by the team that wrote
#      it. The adoption record was never created, so nothing derived from the
#      registry knows the server exists.
reg = load("platform/registry.json")
reg["servers"] = [s for s in reg["servers"] if s.get("id") != "finance-ops"]

# F3 - service owner: the registry still points wiki-reader at a team that was
#      dissolved on 2026-08-31. The entry looks complete and is unowned.
for s in reg["servers"]:
    if s.get("id") == "wiki-reader":
        s["owner"] = "team-atlas-legacy"
save("platform/registry.json", reg)

# F2 - security reviewer: the approval record for finance-ops was filed by the
#      maintainer of finance-ops. Separation of duties is gone, and the approval
#      no longer matches the review of record it cites.
approval = load("governance/approvals/finance-ops.json")
approval["approver"] = {"name": "D. Rivas", "team": "team-fin-integrations", "role": "server-maintainer"}
save("governance/approvals/finance-ops.json", approval)

# F4 - host application owner: the host auto-approves tool calls for a high risk
#      server, so the human in front of the model never sees the transfer.
host = load("hosts/atlas-desk/mcp.json")
host["mcpServers"]["finance-ops"]["consent"] = "auto-approve"
save("hosts/atlas-desk/mcp.json", host)

# F5 - server maintainer: transfer_funds is annotated as read-only, which makes
#      every downstream consent decision wrong by construction.
tools = load("servers/finance-ops/tools.json")
for t in tools["tools"]:
    if t.get("name") == "transfer_funds":
        t["annotations"]["readOnlyHint"] = True
        t["annotations"]["destructiveHint"] = False
save("servers/finance-ops/tools.json", tools)
PY

    # The platform team's derived allowlist is regenerated over the broken state,
    # exactly as the nightly job would have done.
    python3 "$LAB_ROOT/bin/mcp-sync-allowlist" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Briefing
# -----------------------------------------------------------------------------
briefing() {
    cat <<EOF

${BOLD}=============================================================================${RST}
${BOLD} MCPA 5.1 - Roles, Responsibilities & Adoption : break & fix${RST}
${BOLD} scenario: "the server that adopted itself"${RST}
${BOLD}=============================================================================${RST}

Lab root: ${LAB_ROOT}

${BOLD}THE STORY${RST}
  atlas-desk is an MCP host application owned by team-workspace. It has run one
  MCP server for months: wiki-reader, adopted properly in June.

  Two weeks ago team-fin-integrations shipped finance-ops, an MCP server that
  exposes ledger tools including transfer_funds. It passed a real security
  review (SR-2291). Then the team was in a hurry, so instead of finishing the
  adoption they added the server to the host config themselves and filed the
  approval paperwork themselves.

  This morning the host starts degraded and the nightly adoption gate is red.

${BOLD}THE SYMPTOM YOU WILL SEE${RST}
  python3 ${LAB_ROOT}/bin/mcp-host-sim
      [host atlas-desk] client #1 -> server 'finance-ops' over stdio
      [host atlas-desk]   REFUSED: 'finance-ops' is not in platform/allowlist.json
      exit status 1

  python3 ${LAB_ROOT}/bin/mcp-adoption-gate
      adoption gate: FAIL - several findings, each naming a different role

  Read the gate output as a list of people, not a list of files. Five defects
  were injected and each one belongs to exactly one role:

    role                              owns
    --------------------------------  --------------------------------------------
    platform team                     platform/registry.json, the derived allowlist
    security reviewer (team-secops)   governance/approvals/, risk tiering
    service owner / on-call           the 'owner' field: a team that still exists
    host application owner            hosts/atlas-desk/mcp.json, the consent surface
    server maintainer                 servers/<id>/tools.json, truthful annotations

${BOLD}YOUR OBJECTIVE${RST}
  Make both of these exit 0:
      python3 ${LAB_ROOT}/bin/mcp-adoption-gate
      python3 ${LAB_ROOT}/bin/mcp-host-sim
  and then:
      $0 verify

${BOLD}RULES OF THE EXERCISE${RST}
  1. These artifacts are checksummed in governance/MANIFEST.sha256 and are NOT
     yours to edit - verify will catch it:
        bin/*                            (the gate, the host simulator, the sync tool)
        governance/policy.json           (owned by team-secops)
        governance/reviews/*.json        (the reviews of record)
        governance/adoption-requests/*   (what was actually requested)
        platform/teams.json              (the teams that exist)
        platform/handovers/*.md          (the ownership handover note)
  2. Do not make the problem disappear by deleting finance-ops from the host
     config: an approved adoption request must end up deployed (check G7).
  3. Do not hand write platform/allowlist.json. It is derived.
  4. Every value you need already exists somewhere in the lab. Nothing has to be
     invented: the review of record, the adoption request and the handover note
     contain the correct answers.

${BOLD}WHERE TO LOOK FIRST${RST}
  cat ${LAB_ROOT}/governance/reviews/SR-2291.json
  cat ${LAB_ROOT}/governance/adoption-requests/finance-ops.json
  cat ${LAB_ROOT}/platform/handovers/2026-08-31-team-atlas-legacy-dissolved.md
  cat ${LAB_ROOT}/governance/policy.json

${BOLD}THE EXAM POINT${RST}
  MCP defines host, client and server. Adoption defines who may change what.
  A host may not approve its own servers, a maintainer may not approve their own
  code, an allowlist may not be edited by whoever is blocked by it, and an
  annotation is a statement to the user, not a formality. Four of the five
  defects here are invisible to the protocol: every message on the wire is
  perfectly valid MCP.

  The step-by-step solution is at the end of this script, commented out.
  Try the diagnosis before you read it.

EOF
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
do_break() {
    require_confirmation
    need_cmd python3; need_cmd sha256sum
    info "building the pristine adoption pipeline under $LAB_ROOT"
    scaffold
    info "injecting five defects, one per accountable role"
    inject_faults
    briefing
    head2 "SYMPTOM 1 - the host application starts degraded"
    python3 "$LAB_ROOT/bin/mcp-host-sim" || true
    head2 "SYMPTOM 2 - the nightly adoption gate"
    python3 "$LAB_ROOT/bin/mcp-adoption-gate" || true
    printf '\n%s\n' "${YEL}The lab is broken and ready. Fix it, then run: $0 verify${RST}"
}

do_verify() {
    need_cmd python3; need_cmd sha256sum
    [[ -f "$LAB_ROOT/$MARKER" ]] || die "no lab at $LAB_ROOT - run: $0 break"

    head2 "1/3 integrity of the governance artifacts"
    if ( cd "$LAB_ROOT" && sha256sum -c --quiet governance/MANIFEST.sha256 ); then
        printf '%s\n' "${GRN}ok${RST} - policy, reviews, teams and tooling are untouched"
    else
        printf '%s\n' "${RED}TAMPERED${RST} - a checksummed artifact was modified."
        echo "Weakening the control is not fixing the adoption. Run '$0 reset' and try again."
        exit 2
    fi

    head2 "2/3 adoption gate"
    if ! python3 "$LAB_ROOT/bin/mcp-adoption-gate"; then
        printf '%s\n' "${RED}not yet${RST} - findings above, each one names the role that owns the fix"
        exit 1
    fi

    head2 "3/3 host application"
    if ! python3 "$LAB_ROOT/bin/mcp-host-sim"; then
        printf '%s\n' "${RED}not yet${RST} - the host still refuses at least one declared server"
        exit 1
    fi

    cat <<EOF

${GRN}${BOLD}SOLVED.${RST}

What you actually did, in role terms:
  platform team        created the adoption record and re-derived the allowlist
  security reviewer    filed the approval from the review of record, so the
                       approver is no longer the author of the code
  service owner        moved wiki-reader to a team that exists and has a pager
  host app owner       restored per-call consent for a high risk server
  server maintainer    told the truth in the tool annotations

Nothing you changed altered a single byte on the MCP wire. That is the lesson of
domain 5.1: adoption is a set of role boundaries around a protocol that has no
opinion about who is allowed to press which button.

EOF
}

do_reset() {
    require_confirmation
    need_cmd python3; need_cmd sha256sum
    info "rebuilding the broken state from scratch (your edits are discarded)"
    scaffold
    inject_faults
    info "done - run '$0 briefing' for the scenario"
}

do_clean() {
    require_confirmation
    if [[ -f "$LAB_ROOT/$MARKER" ]]; then
        rm -rf "$LAB_ROOT"
        info "removed $LAB_ROOT"
    else
        die "$LAB_ROOT does not carry this lab's marker file; refusing to delete it"
    fi
}

main() {
    local cmd="break"
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)                     CONFIRM=1 ;;
            break|verify|briefing|reset|clean) cmd="$arg" ;;
            -h|--help)                    sed -n '1,60p' "$0"; exit 0 ;;
            *)                            die "unknown argument: $arg" ;;
        esac
    done
    case "$cmd" in
        break)    do_break ;;
        verify)   do_verify ;;
        briefing) [[ -f "$LAB_ROOT/$MARKER" ]] || die "no lab at $LAB_ROOT - run: $0 break"; briefing ;;
        reset)    do_reset ;;
        clean)    do_clean ;;
    esac
}

main "$@"

# =============================================================================
#  SOLUTION - stop here if you have not tried the diagnosis yet
# =============================================================================
#
#  Set the lab root once:
#
#     LAB=/opt/mcpa-lab/5.1-roles-adoption      # or your MCPA_LAB_ROOT
#
#  -------------------------------------------------------------------------
#  STEP 0 - read the evidence before changing anything
#  -------------------------------------------------------------------------
#  The gate tells you WHAT is wrong; these four files tell you what the correct
#  value is. None of them may be edited - they are the record.
#
#     cat "$LAB/governance/reviews/SR-2291.json"
#     cat "$LAB/governance/adoption-requests/finance-ops.json"
#     cat "$LAB/platform/handovers/2026-08-31-team-atlas-legacy-dissolved.md"
#     cat "$LAB/governance/policy.json"
#
#  From them:
#     finance-ops : maintainer team-fin-integrations, risk tier high (SR-2291),
#                   transport stdio, data restricted, approved for atlas-desk,
#                   version 1.4.0, reviewer team-secops / M. Okonjo,
#                   conditions: per-call consent, no sampling,
#                   transfer_funds readOnlyHint=false destructiveHint=true
#     wiki-reader : owner moves from team-atlas-legacy to team-knowledge
#     policy      : high -> per-call, approver role security-reviewer,
#                   approver must differ from maintainer
#
#  -------------------------------------------------------------------------
#  STEP 1 - PLATFORM TEAM: create the adoption record that was never created
#  -------------------------------------------------------------------------
#  Fixes G1 (and the host refusal, indirectly: the allowlist is derived from
#  this file). Note that the platform team does not decide the risk tier - it
#  copies the tier the security review assigned.
#
#     python3 - <<'PY'
#     import json, pathlib
#     root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
#     p = root / "platform/registry.json"
#     d = json.loads(p.read_text())
#     ids = [s["id"] for s in d["servers"]]
#     if "finance-ops" not in ids:
#         d["servers"].append({
#             "id": "finance-ops",
#             "maintainer": "team-fin-integrations",
#             "owner": "team-fin-integrations",
#             "risk_tier": "high",
#             "transport": "stdio",
#             "data_classification": "restricted",
#             "approval": "SR-2291",
#             "adopted_on": "2026-09-17"
#         })
#     p.write_text(json.dumps(d, indent=2) + "\n")
#     PY
#
#  -------------------------------------------------------------------------
#  STEP 2 - SECURITY REVIEWER: file the approval from the review of record
#  -------------------------------------------------------------------------
#  Fixes G3. The defect was not a typo: the maintainer of the server signed its
#  own approval. The correct approval is a transcription of SR-2291, whose
#  reviewer is team-secops. Nothing about the server changes - only who says it
#  is acceptable, which is the entire point of separation of duties.
#
#     python3 - <<'PY'
#     import json, pathlib
#     root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
#     review = json.loads((root / "governance/reviews/SR-2291.json").read_text())
#     approval = {
#         "schema": "mcp.approval/v1",
#         "server": review["server"],
#         "server_version": review["server_version"],
#         "risk_tier": review["risk_tier"],
#         "decision": review["decision"],
#         "review": review["id"],
#         "approver": dict(review["reviewer"]),
#         "approved_on": review["completed_on"],
#         "scope": {"hosts": ["atlas-desk"], "consent": "per-call"}
#     }
#     (root / "governance/approvals/finance-ops.json").write_text(
#         json.dumps(approval, indent=2) + "\n")
#     PY
#
#  -------------------------------------------------------------------------
#  STEP 3 - SERVICE OWNER / PLATFORM: give wiki-reader an owner that exists
#  -------------------------------------------------------------------------
#  Fixes G2. team-atlas-legacy was dissolved on 2026-08-31 and its pager deleted;
#  the handover note assigns wiki-reader to team-knowledge. Do NOT re-add the
#  dead team to platform/teams.json - that is inventing an owner, and the file is
#  checksummed for exactly that reason.
#
#     python3 - <<'PY'
#     import json, pathlib
#     root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
#     p = root / "platform/registry.json"
#     d = json.loads(p.read_text())
#     for s in d["servers"]:
#         if s["id"] == "wiki-reader":
#             s["owner"] = "team-knowledge"
#     p.write_text(json.dumps(d, indent=2) + "\n")
#     PY
#
#  -------------------------------------------------------------------------
#  STEP 4 - HOST APPLICATION OWNER: restore the consent surface
#  -------------------------------------------------------------------------
#  Fixes G4. The host, not the server, owns what the user is asked to approve.
#  Policy maps risk tier high to per-call consent, and SR-2291 states it as a
#  condition of approval. auto-approve on a server carrying transfer_funds means
#  the model can move money with no human in the loop.
#
#     python3 - <<'PY'
#     import json, pathlib
#     root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
#     p = root / "hosts/atlas-desk/mcp.json"
#     d = json.loads(p.read_text())
#     d["mcpServers"]["finance-ops"]["consent"] = "per-call"
#     d["mcpServers"]["finance-ops"]["sampling"] = "deny"
#     p.write_text(json.dumps(d, indent=2) + "\n")
#     PY
#
#  -------------------------------------------------------------------------
#  STEP 5 - SERVER MAINTAINER: make the annotations true
#  -------------------------------------------------------------------------
#  Fixes G5. readOnlyHint and destructiveHint are the only signal the host has
#  for rendering a consent prompt. A destructive tool annotated read-only makes
#  every host downstream silently wrong, including hosts you do not operate.
#
#     python3 - <<'PY'
#     import json, pathlib
#     root = pathlib.Path("/opt/mcpa-lab/5.1-roles-adoption")
#     p = root / "servers/finance-ops/tools.json"
#     d = json.loads(p.read_text())
#     for t in d["tools"]:
#         if t["name"] == "transfer_funds":
#             t["annotations"]["readOnlyHint"] = False
#             t["annotations"]["destructiveHint"] = True
#             t["annotations"]["idempotentHint"] = False
#             t["annotations"]["openWorldHint"] = False
#     p.write_text(json.dumps(d, indent=2) + "\n")
#     PY
#
#  -------------------------------------------------------------------------
#  STEP 6 - PLATFORM TEAM: re-derive the allowlist
#  -------------------------------------------------------------------------
#  Fixes G6 and clears the original symptom. The allowlist is generated from the
#  registry plus valid approvals; the sync tool refuses anything that still has
#  an approval problem, which is why steps 1 and 2 had to come first.
#
#     python3 "$LAB/bin/mcp-sync-allowlist"
#         allowlist written: finance-ops, wiki-reader
#
#  -------------------------------------------------------------------------
#  STEP 7 - verify
#  -------------------------------------------------------------------------
#     python3 "$LAB/bin/mcp-adoption-gate"     # expect: adoption gate: PASS
#     python3 "$LAB/bin/mcp-host-sim"          # expect: all 2 declared servers connected
#     ./mcpa-5.1-break-fix.sh verify           # expect: SOLVED
#
#  Expected host output after the fix (abbreviated):
#     [host atlas-desk] client #1 -> server 'finance-ops' over stdio
#     [host atlas-desk]   -> {"jsonrpc":"2.0","id":1,"method":"initialize",...}
#     [host atlas-desk]   <- {"jsonrpc":"2.0","id":1,"result":{...,"serverInfo":{"name":"finance-ops","version":"1.4.0"}}}
#     [host atlas-desk]   connected: owner=team-fin-integrations tier=high consent=per-call
#     [host atlas-desk]   tools/list: transfer_funds  readOnlyHint=False destructiveHint=True -> consent prompt: per-call
#
#  -------------------------------------------------------------------------
#  WHAT THIS TEACHES, AND THE TRAPS
#  -------------------------------------------------------------------------
#  * The visible symptom (one refused connection) had five causes owned by five
#    roles. Fixing only the allowlist would have "restored service" while
#    shipping an unreviewed, auto-approved, mislabelled money-moving tool. That
#    is the failure mode this domain exists to prevent.
#  * Trap 1: editing platform/allowlist.json by hand. It is derived state; the
#    gate recomputes the expected value and the change is reverted by the next
#    sync run.
#  * Trap 2: adding team-atlas-legacy back to platform/teams.json. Ownership is
#    a claim about who answers the pager, not a string that must resolve.
#  * Trap 3: deleting finance-ops from the host config. G7 catches it: an
#    approved adoption request that is not deployed is an unfinished adoption,
#    not a clean state.
#  * Trap 4: editing governance/policy.json or bin/mcp-adoption-gate. The
#    checksum manifest catches it. Whoever is blocked by a control is never the
#    role that may change it.
#  * Order matters: the allowlist can only be re-derived after the registry
#    entry and the approval exist. Real adoption pipelines have the same
#    dependency, which is why "just restart it" does not work here either.
#
#  Further reading:
#    https://modelcontextprotocol.io/specification/2025-06-18/architecture
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
# =============================================================================