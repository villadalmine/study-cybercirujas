#!/usr/bin/env bash
# =============================================================================
#  MCPA — Model Context Protocol Associate (exam version 2026-07-28)
#  Topic 2.1 — Schemas & Structured Data (exam weight 4.67)
#
#  BREAK & FIX LAB — self-contained, offline, non-destructive.
#
#  WHAT THIS SCRIPT DOES
#    It writes a small MCP server (stdio transport, newline-delimited
#    JSON-RPC 2.0, Python standard library only) into a disposable lab
#    directory, with five deliberate defects in the *schema layer*: the tool
#    `inputSchema`, the tool `outputSchema`, the `structuredContent` the
#    handlers return, and the JSON payload of a resource whose `mimeType`
#    claims `application/json`. It then runs a strict MCP client probe
#    against it so you see exactly what a real host sees.
#
#  SAFETY
#    - Everything lives under a single lab directory (default
#      "$HOME/mcpa-lab-2.1", override with MCPA_LAB_DIR).
#    - No sudo, no package installs, no network, no systemd units, no writes
#      outside the lab directory. `clean` only removes that directory.
#    - Intended for a throwaway lab VM/container. Requires python3 (>= 3.8).
#
#  USAGE
#    ./mcpa-2.1-break-fix.sh            # build the broken lab and show the symptom
#    ./mcpa-2.1-break-fix.sh verify     # re-run the probe: your grading command
#    ./mcpa-2.1-break-fix.sh trace      # same, dumping every JSON-RPC frame
#    ./mcpa-2.1-break-fix.sh hint [1-3] # progressive hints
#    ./mcpa-2.1-break-fix.sh reset      # restore the broken server.py
#    ./mcpa-2.1-break-fix.sh solution   # full worked solution (spoiler)
#    ./mcpa-2.1-break-fix.sh clean      # delete the lab directory
#
#  REFERENCES
#    https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#    https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#    https://modelcontextprotocol.io/specification/2025-06-18/server/resources
#    https://json-schema.org/understanding-json-schema/reference/type
# =============================================================================

set -euo pipefail

LAB_DIR="${MCPA_LAB_DIR:-$HOME/mcpa-lab-2.1}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    CYAN=$'\e[36m'; DIM=$'\e[2m'; OFF=$'\e[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; OFF=''
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

require_python() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found in PATH."
    python3 - <<'PY' || die "python3 >= 3.8 is required."
import sys
raise SystemExit(0 if sys.version_info >= (3, 8) else 1)
PY
}

# -----------------------------------------------------------------------------
# write_server — the component under test. It is deliberately broken; the
# defects are NOT marked, because locating them is the exercise.
# -----------------------------------------------------------------------------
write_server() {
    cat > "$LAB_DIR/server.py" <<'SERVER_PY'
#!/usr/bin/env python3
"""weather-lab: a minimal MCP server over the stdio transport.

Transport: newline-delimited JSON-RPC 2.0 on stdin/stdout. Nothing but the
Python standard library. Log lines, if any, go to stderr — stdout carries
protocol frames only.
"""

import json
import sys

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "weather-lab", "title": "Weather Lab", "version": "0.1.0"}

# --- the station catalogue this server exposes -------------------------------

STATIONS = [
    {"id": "SAEZ", "name": "Ezeiza", "temperature_c": 21.5, "conditions": "few clouds"},
    {"id": "SABE", "name": "Aeroparque", "temperature_c": 22.1, "conditions": "clear"},
    {"id": "SACO", "name": "Cordoba", "temperature_c": 26.0, "conditions": "haze"},
]

# --- tool definitions --------------------------------------------------------

GET_FORECAST = {
    "name": "get_forecast",
    "title": "Get forecast",
    "description": "Return the current forecast for one weather station.",
    "inputSchema": {
        "type": "Object",
        "properties": {
            "station": {
                "type": "string",
                "description": "ICAO station id, for example SAEZ",
            },
            "unit": {
                "type": "string",
                "description": "Temperature unit to report",
                "enum": ["c", "f"],
            },
        },
        "required": ["station", "units"],
    },
    "outputSchema": {
        "type": "object",
        "properties": {
            "station": {"type": "string"},
            "temperature_c": {"type": "number"},
            "conditions": {"type": "string"},
        },
        "required": ["station", "temperature_c", "conditions"],
    },
}

LIST_STATIONS = {
    "name": "list_stations",
    "title": "List stations",
    "description": "Return every station id this server knows about.",
    "inputSchema": {
        "type": "object",
        "properties": {},
    },
    "outputSchema": {
        "type": "object",
        "properties": {
            "stations": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["stations"],
    },
}

TOOLS = [GET_FORECAST, LIST_STATIONS]

# --- resource definitions ----------------------------------------------------

STATION_CATALOGUE = """{
  "stations": [
    {"id": "SAEZ", "name": "Ezeiza"},
    {"id": "SABE", "name": "Aeroparque"},
    {"id": "SACO", "name": "Cordoba"},
  ]
}
"""

RESOURCES = [
    {
        "uri": "weather://stations.json",
        "name": "stations",
        "title": "Station catalogue",
        "description": "Every station id and its human readable name.",
        "mimeType": "application/json",
    }
]

# --- tool handlers -----------------------------------------------------------


def handle_get_forecast(args):
    station_id = (args.get("station") or "SAEZ").upper()
    row = next((s for s in STATIONS if s["id"] == station_id), None)
    if row is None:
        return {
            "content": [{"type": "text", "text": "unknown station: %s" % station_id}],
            "isError": True,
        }

    text = "%s: %s C, %s" % (row["id"], row["temperature_c"], row["conditions"])
    return {
        "content": [{"type": "text", "text": text}],
        "structuredContent": {
            "station": row["id"],
            "temperature": str(row["temperature_c"]),
            "conditions": row["conditions"],
        },
    }


def handle_list_stations(args):
    ids = [s["id"] for s in STATIONS]
    return {
        "content": [{"type": "text", "text": ", ".join(ids)}],
    }


HANDLERS = {
    "get_forecast": handle_get_forecast,
    "list_stations": handle_list_stations,
}

# --- JSON-RPC plumbing -------------------------------------------------------


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(request_id, payload):
    send({"jsonrpc": "2.0", "id": request_id, "result": payload})


def fail(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def dispatch(request):
    method = request.get("method")
    request_id = request.get("id")

    # Requests without an id are notifications: never answer them.
    if request_id is None:
        return

    if method == "initialize":
        reply(request_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}, "resources": {}},
            "serverInfo": SERVER_INFO,
        })
    elif method == "tools/list":
        reply(request_id, {"tools": TOOLS})
    elif method == "tools/call":
        params = request.get("params") or {}
        name = params.get("name")
        handler = HANDLERS.get(name)
        if handler is None:
            fail(request_id, -32602, "unknown tool: %s" % name)
        else:
            reply(request_id, handler(params.get("arguments") or {}))
    elif method == "resources/list":
        reply(request_id, {"resources": RESOURCES})
    elif method == "resources/read":
        uri = (request.get("params") or {}).get("uri")
        if uri != "weather://stations.json":
            fail(request_id, -32002, "resource not found: %s" % uri)
        else:
            reply(request_id, {"contents": [{
                "uri": uri,
                "mimeType": "application/json",
                "text": STATION_CATALOGUE,
            }]})
    elif method == "ping":
        reply(request_id, {})
    else:
        fail(request_id, -32601, "method not found: %s" % method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            continue
        dispatch(request)


if __name__ == "__main__":
    main()
SERVER_PY
    chmod +x "$LAB_DIR/server.py"
}

# -----------------------------------------------------------------------------
# write_probe — a strict MCP client. This is the grader. Do not edit it.
# -----------------------------------------------------------------------------
write_probe() {
    cat > "$LAB_DIR/probe.py" <<'PROBE_PY'
#!/usr/bin/env python3
"""Strict MCP client probe for MCPA topic 2.1 (Schemas & Structured Data).

Speaks the stdio transport to ./server.py and audits the schema contract the
way a conservative host does: it refuses tools whose inputSchema is not a
usable JSON Schema object, it validates structuredContent against the
declared outputSchema, and it parses any resource that claims to be JSON.

Exit code 0 only when every check passes. MCPA_TRACE=1 dumps the frames.
"""

import json
import os
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")
PROTOCOL_VERSION = "2025-06-18"
TRACE = os.environ.get("MCPA_TRACE") == "1"

JSON_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def json_type_of(value):
    for name, test in JSON_TYPES.items():
        if name != "integer" and test(value):
            return name
    return "unknown"


class Client(object):
    """Minimal stdio JSON-RPC client."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            universal_newlines=True,
            bufsize=1,
        )
        self._next_id = 0

    def _write(self, message):
        blob = json.dumps(message)
        if TRACE:
            sys.stderr.write("--> %s\n" % blob)
        self.proc.stdin.write(blob + "\n")
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)

    def request(self, method, params=None):
        self._next_id += 1
        message = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout while answering %s" % method)
            line = line.strip()
            if not line:
                continue
            if TRACE:
                sys.stderr.write("<-- %s\n" % line)
            response = json.loads(line)
            if response.get("id") == message["id"]:
                return response

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


# --- JSON Schema subset: enough to police an MCP tool contract ---------------


def lint_schema(schema, label, root_must_be_object=True):
    """Structural audit of a declared schema. Returns a list of problems."""
    problems = []
    if not isinstance(schema, dict):
        return ["%s is not a JSON Schema object (got %s)" % (label, json_type_of(schema))]

    declared = schema.get("type")
    if declared is None:
        problems.append("%s.type is absent; MCP requires the root schema to declare a type"
                        % label)
    elif not isinstance(declared, str) or declared not in JSON_TYPES:
        problems.append('%s.type is %r; JSON Schema type names are lowercase '
                        '(object, array, string, number, integer, boolean, null)'
                        % (label, declared))
    elif root_must_be_object and declared != "object":
        problems.append('%s.type is "%s"; an MCP tool schema root must be "object"'
                        % (label, declared))

    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        problems.append("%s.properties must be an object mapping names to schemas" % label)
        properties = {}

    for name, sub in properties.items():
        if not isinstance(sub, dict):
            problems.append("%s.properties.%s is not a schema object" % (label, name))
            continue
        sub_type = sub.get("type")
        if sub_type is None:
            problems.append("%s.properties.%s declares no type" % (label, name))
        elif not isinstance(sub_type, str) or sub_type not in JSON_TYPES:
            problems.append("%s.properties.%s.type is %r, which is not a JSON Schema type"
                            % (label, name, sub_type))
        enum = sub.get("enum")
        if enum is not None:
            if not isinstance(enum, list) or not enum:
                problems.append("%s.properties.%s.enum must be a non-empty array"
                                % (label, name))
            elif isinstance(sub_type, str) and sub_type in JSON_TYPES:
                bad = [v for v in enum if not JSON_TYPES[sub_type](v)]
                if bad:
                    problems.append("%s.properties.%s.enum holds values that violate its own "
                                    "type %s: %r" % (label, name, sub_type, bad))

    required = schema.get("required", [])
    if not isinstance(required, list):
        problems.append("%s.required must be an array of property names" % label)
    else:
        for name in required:
            if name not in properties:
                problems.append('%s.required lists "%s", which is not in %s.properties; '
                                "no caller can ever satisfy this schema"
                                % (label, name, label))
    return problems


def validate(instance, schema, path="$"):
    """Validate an instance against the schema subset. Returns a list of errors."""
    errors = []
    if not isinstance(schema, dict):
        return errors

    declared = schema.get("type")
    if isinstance(declared, str) and declared in JSON_TYPES:
        if not JSON_TYPES[declared](instance):
            errors.append("%s: expected %s, got %s (%r)"
                          % (path, declared, json_type_of(instance), instance))
            return errors

    if isinstance(instance, dict):
        for name in schema.get("required", []) or []:
            if name not in instance:
                errors.append('%s: required property "%s" is missing' % (path, name))
        for name, sub in (schema.get("properties") or {}).items():
            if name in instance:
                errors.extend(validate(instance[name], sub, "%s.%s" % (path, name)))

    if isinstance(instance, list):
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(instance):
                errors.extend(validate(item, item_schema, "%s[%d]" % (path, index)))

    enum = schema.get("enum")
    if isinstance(enum, list) and enum and instance not in enum:
        errors.append("%s: %r is not one of %r" % (path, instance, enum))
    return errors


# --- check bookkeeping -------------------------------------------------------

RESULTS = []


def record(cid, title, ok, detail="", why="", warn_only=False):
    status = "PASS" if ok else ("WARN" if warn_only else "FAIL")
    RESULTS.append({
        "id": cid, "title": title, "status": status,
        "detail": "" if ok else detail,
        "why": "" if ok else why,
    })
    return ok


def on_timeout(signum, frame):
    raise RuntimeError("the server did not answer within 30 s")


def run():
    client = Client()
    try:
        init = client.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "mcpa-2.1-probe", "version": "1.0.0"},
        })
        result = init.get("result") or {}
        record("C1", "initialize handshake completes",
               bool(result.get("serverInfo")) and bool(result.get("protocolVersion")),
               detail="initialize returned %r" % init,
               why="without a handshake no capability, tool or schema is negotiated at all")
        client.notify("notifications/initialized")

        listing = (client.request("tools/list").get("result") or {})
        tools = {}
        for tool in listing.get("tools") or []:
            if isinstance(tool, dict) and "name" in tool:
                tools[tool["name"]] = tool
        have_both = record("C2", "tools/list advertises get_forecast and list_stations",
                           set(["get_forecast", "list_stations"]).issubset(set(tools)),
                           detail="tools/list returned: %s" % sorted(tools),
                           why="the lab contract is these two tools; deleting one is not a fix")
        if not have_both:
            return

        forecast = tools["get_forecast"]
        stations = tools["list_stations"]

        record("C3", "get_forecast declares both inputSchema and outputSchema",
               isinstance(forecast.get("inputSchema"), dict)
               and isinstance(forecast.get("outputSchema"), dict),
               detail="inputSchema=%s outputSchema=%s"
                      % (type(forecast.get("inputSchema")).__name__,
                         type(forecast.get("outputSchema")).__name__),
               why="dropping the outputSchema would silence the probe but throws away the "
                   "typed contract this topic is about")

        in_problems = lint_schema(forecast.get("inputSchema"), "get_forecast.inputSchema")
        record("C4", "get_forecast.inputSchema is a usable JSON Schema object",
               not in_problems,
               detail="; ".join(in_problems),
               why="a host that validates the advertised schema drops the tool, so the model "
                   "never sees it — the tool simply 'does not exist' at runtime")

        out_problems = lint_schema(forecast.get("outputSchema"), "get_forecast.outputSchema")
        out_problems += lint_schema(stations.get("outputSchema"), "list_stations.outputSchema")
        record("C5", "declared outputSchemas are structurally sound",
               not out_problems,
               detail="; ".join(out_problems),
               why="the outputSchema is the promise the server makes about structuredContent")

        call = client.request("tools/call", {
            "name": "get_forecast",
            "arguments": {"station": "SAEZ", "unit": "c"},
        })
        payload = call.get("result") or {}
        structured = payload.get("structuredContent")
        has_structured = record(
            "C6", "get_forecast returns structuredContent (outputSchema is declared)",
            isinstance(structured, dict),
            detail="result keys: %s" % sorted(payload),
            why="when a tool declares an outputSchema it MUST return structuredContent; "
                "text alone forces the host back into string parsing")

        if has_structured:
            errors = validate(structured, forecast.get("outputSchema") or {},
                              "structuredContent")
            record("C7", "get_forecast.structuredContent conforms to its outputSchema",
                   not errors,
                   detail="; ".join(errors) + "  |  returned: %s" % json.dumps(structured),
                   why="a mismatch is a broken contract: the host rejects the call or hands "
                       "the model a value of the wrong type (\"21.5\" is a string, 21.5 is a "
                       "number — only one of them can be compared or averaged)")

        blocks = payload.get("content") or []
        mirror_ok = False
        if has_structured and blocks and isinstance(blocks[0], dict):
            try:
                mirror_ok = json.loads(blocks[0].get("text") or "") == structured
            except ValueError:
                mirror_ok = False
        record("C8", "the text content block mirrors structuredContent as serialized JSON",
               mirror_ok,
               detail="content[0] = %s" % json.dumps(blocks[0] if blocks else None),
               why="SHOULD, not MUST: older hosts that ignore structuredContent still need "
                   "the same data in the text block",
               warn_only=True)

        call = client.request("tools/call", {"name": "list_stations", "arguments": {}})
        payload = call.get("result") or {}
        structured = payload.get("structuredContent")
        if record("C9", "list_stations returns structuredContent (outputSchema is declared)",
                  isinstance(structured, dict),
                  detail="result keys: %s" % sorted(payload),
                  why="same MUST as C6: declaring an outputSchema obliges the handler"):
            errors = validate(structured, stations.get("outputSchema") or {},
                              "structuredContent")
            if not errors and "SAEZ" not in (structured.get("stations") or []):
                errors = ["structuredContent.stations does not contain the SAEZ station"]
            record("C10", "list_stations.structuredContent conforms to its outputSchema",
                   not errors,
                   detail="; ".join(errors) + "  |  returned: %s" % json.dumps(structured),
                   why="an array of strings is a contract the model can iterate; a comma "
                       "separated sentence is not")

        resources = ((client.request("resources/list").get("result") or {}).get("resources")
                     or [])
        catalogue = next((r for r in resources
                          if r.get("uri") == "weather://stations.json"), None)
        if record("C11", "the station catalogue resource is advertised with a mimeType",
                  bool(catalogue) and bool(catalogue.get("mimeType")),
                  detail="resources/list returned: %s" % json.dumps(resources),
                  why="the mimeType is how a host decides whether to parse or to display"):
            read = (client.request("resources/read",
                                   {"uri": "weather://stations.json"}).get("result") or {})
            contents = (read.get("contents") or [{}])[0]
            text = contents.get("text") or ""
            detail = ""
            parsed = None
            try:
                parsed = json.loads(text)
            except ValueError as exc:
                detail = "json.loads() failed: %s" % exc
            if parsed is not None and not isinstance(parsed.get("stations"), list):
                parsed = None
                detail = 'parsed, but the document has no "stations" array'
            record("C12", 'a resource declared "application/json" parses as JSON',
                   parsed is not None,
                   detail=detail + "  |  payload was: %s" % json.dumps(text),
                   why="the mimeType is a claim about the bytes; when the bytes disagree, "
                       "every consumer downstream fails at parse time, far from the cause")
    finally:
        client.close()


def main():
    if hasattr(signal, "SIGALRM"):
        signal.signal(signal.SIGALRM, on_timeout)
        signal.alarm(30)
    try:
        run()
    except Exception as exc:
        record("C0", "the probe completed", False, detail=str(exc),
               why="the server crashed, hung, or wrote non-protocol noise to stdout")

    width = max(len(r["title"]) for r in RESULTS)
    print("")
    print("=== MCP schema probe: weather-lab ===")
    for r in RESULTS:
        print("[%s] %s  %s" % (r["status"], r["id"].ljust(3), r["title"].ljust(width)))
        if r["detail"]:
            print("        -> %s" % r["detail"].strip())
        if r["why"]:
            print("        why: %s" % r["why"])
    failed = [r for r in RESULTS if r["status"] == "FAIL"]
    warned = [r for r in RESULTS if r["status"] == "WARN"]
    passed = [r for r in RESULTS if r["status"] == "PASS"]
    print("")
    print("%d failing, %d warning, %d passing" % (len(failed), len(warned), len(passed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
PROBE_PY
    chmod +x "$LAB_DIR/probe.py"
}

# -----------------------------------------------------------------------------

lab_exists() { [[ -f "$LAB_DIR/server.py" && -f "$LAB_DIR/probe.py" ]]; }

cmd_setup() {
    require_python
    mkdir -p "$LAB_DIR"
    write_server
    write_probe

    head1 "MCPA 2.1 — Schemas & Structured Data — break & fix"
    say "Lab directory : ${CYAN}$LAB_DIR${OFF}"
    say "Under test    : ${CYAN}$LAB_DIR/server.py${OFF}   (edit this file — only this file)"
    say "Grader        : ${DIM}$LAB_DIR/probe.py${OFF}      (do not edit)"

    head1 "The scenario"
    cat <<'SCENARIO'
You have inherited an MCP server, `weather-lab`, that exposes two tools
(`get_forecast`, `list_stations`) and one resource (`weather://stations.json`).
It starts, it answers `initialize`, it answers `tools/list`, and running it by
hand "looks fine". Yet in the host application the model never calls
`get_forecast`, and the agent that consumes `list_stations` fails with type
errors instead of a list of stations.

Nothing is wrong with the transport. Everything that is wrong lives in the
schema layer: what the server PROMISES about its inputs and outputs, versus
what it actually accepts and returns.
SCENARIO

    head1 "What the strict client sees right now"
    local rc=0
    ( cd "$LAB_DIR" && python3 probe.py ) || rc=$?

    head1 "Your mission"
    cat <<MISSION
Make every check pass (warnings are allowed to remain, but fixing C8 is part of
a good answer) by editing ONLY:

    $LAB_DIR/server.py

Grade yourself with:

    $SELF verify

Rules of the exercise:
  * Do not delete a tool, a resource, or an outputSchema to silence a check.
    The probe fails you for that (C2, C3). The point is a correct contract,
    not a smaller one.
  * Do not edit probe.py. It is the host; you do not get to patch the host.
  * \`$SELF trace\` replays the same session dumping every JSON-RPC frame — use
    it to read the raw \`tools/list\` and \`tools/call\` payloads.
  * \`$SELF reset\` puts the broken server back if you paint yourself into a
    corner; \`$SELF hint 1\` gives you a nudge.

What you should be able to explain when you are done, in exam terms:
  * why an MCP tool \`inputSchema\` root must be \`"object"\` and why JSON Schema
    type names are case sensitive;
  * why a \`required\` entry with no matching property is unsatisfiable rather
    than merely strict;
  * what obligation a declared \`outputSchema\` places on the handler, and the
    difference between \`content\` and \`structuredContent\`;
  * why a number returned as a string breaks a consumer that a human reader
    would never notice;
  * why a \`mimeType\` of \`application/json\` is a claim about the bytes, and why
    hand-written JSON strings are the wrong way to make that claim.
MISSION
    return 0
}

cmd_verify() {
    require_python
    lab_exists || die "no lab found at $LAB_DIR — run '$SELF' first."
    local rc=0
    ( cd "$LAB_DIR" && python3 probe.py ) || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '\n%sLAB PASSED%s — 0 failing checks. The schema contract holds end to end.\n' \
               "$GREEN$BOLD" "$OFF"
        printf 'Compare your patch with %s%s solution%s.\n' "$CYAN" "$SELF" "$OFF"
    else
        printf '\n%sLAB NOT PASSED%s — keep going. Edit %s and re-run %s verify.\n' \
               "$RED$BOLD" "$OFF" "$LAB_DIR/server.py" "$SELF"
    fi
    return $rc
}

cmd_trace() {
    require_python
    lab_exists || die "no lab found at $LAB_DIR — run '$SELF' first."
    say "${DIM}--> frames sent by the client, <-- frames sent by the server${OFF}"
    ( cd "$LAB_DIR" && MCPA_TRACE=1 python3 probe.py ) || true
}

cmd_hint() {
    case "${1:-1}" in
        1)
            head1 "Hint 1 — where to look"
            cat <<'H1'
Five defects, in three places:
  * two in the tool DEFINITIONS (the dicts named GET_FORECAST / LIST_STATIONS);
  * two in the tool HANDLERS (handle_get_forecast / handle_list_stations);
  * one in the RESOURCE payload (STATION_CATALOGUE).

Read each schema out loud as a promise — "I accept an object with these
properties, I return an object with these properties" — and then read the
handler as the fulfilment of that promise. Every defect is a promise the
server cannot keep.
H1
            ;;
        2)
            head1 "Hint 2 — sharper"
            cat <<'H2'
  * JSON Schema type names are lowercase. "Object" is not "object": it is an
    unknown type, and a validating host rejects the whole schema.
  * `required` can only name properties that exist in `properties`. Check the
    singular/plural of the unit parameter.
  * Declaring `outputSchema` obliges the handler to return `structuredContent`
    that validates against it — by key name AND by JSON type. `"21.5"` is a
    string; the schema says `number`. One handler returns no structuredContent
    at all.
  * For backwards compatibility, serialize the same object into the text
    content block (`json.dumps`), do not hand-write a prose sentence.
  * The catalogue resource claims `application/json`, but its payload is a
    hand-written Python string with a trailing comma after the last array
    element. JSON has no trailing commas. Do not fix the comma — stop
    hand-writing JSON and serialize the real data structure.
H2
            ;;
        3)
            head1 "Hint 3 — the exact commands"
            cat <<H3
  $ cd "$LAB_DIR"
  $ python3 -c 'import json,server; print(json.dumps(server.GET_FORECAST, indent=2))'
  $ python3 -c 'import json,server; print(json.dumps(server.handle_get_forecast({"station":"SAEZ"}), indent=2))'
  $ python3 -c 'import json,server; json.loads(server.STATION_CATALOGUE)'
  $ $SELF trace   # read the tools/list and tools/call frames as the host sees them

Put those three outputs side by side with the outputSchema. Every failing
check is visible in that comparison.
H3
            ;;
        *) die "hints are 1, 2 or 3" ;;
    esac
}

cmd_reset() {
    require_python
    mkdir -p "$LAB_DIR"
    write_server
    write_probe
    say "${YELLOW}Restored the broken server.py and the probe in $LAB_DIR.${OFF}"
}

cmd_solution() {
    sed -n '/^# === SOLUTION/,$p' "$SELF"
}

cmd_clean() {
    if [[ ! -d "$LAB_DIR" ]]; then
        say "Nothing to remove: $LAB_DIR does not exist."
        return 0
    fi
    say "About to remove ${CYAN}$LAB_DIR${OFF} and everything in it:"
    ls -la "$LAB_DIR"
    read -r -p "Type 'yes' to confirm: " answer
    [[ "$answer" == "yes" ]] || { say "Aborted; nothing was removed."; return 0; }
    rm -rf -- "$LAB_DIR"
    say "${GREEN}Removed $LAB_DIR.${OFF}"
}

cmd_help() {
    sed -n '2,40p' "$SELF"
}

main() {
    case "${1:-setup}" in
        setup|"")   cmd_setup ;;
        verify)     cmd_verify ;;
        trace)      cmd_trace ;;
        hint)       cmd_hint "${2:-1}" ;;
        reset)      cmd_reset ;;
        solution)   cmd_solution ;;
        clean)      cmd_clean ;;
        help|-h|--help) cmd_help ;;
        *)          die "unknown command: $1 (try: setup verify trace hint reset solution clean)" ;;
    esac
}

main "$@"
exit $?

# =============================================================================
# === SOLUTION — MCPA 2.1, Schemas & Structured Data ==========================
# =============================================================================
#
# Five defects, all in $LAB_DIR/server.py. Fix them in this order; each step
# turns one probe check green, so you can verify incrementally with
# `./mcpa-2.1-break-fix.sh verify` after every edit.
#
# -----------------------------------------------------------------------------
# STEP 0 — Reproduce and read the evidence, do not guess
# -----------------------------------------------------------------------------
#   $ cd ~/mcpa-lab-2.1
#   $ ../mcpa-2.1-break-fix.sh trace 2>&1 | less
#
# In the trace, find the `tools/list` response and the two `tools/call`
# responses. Everything you need is in those three frames: the advertised
# schemas and the actual payloads. The transport is healthy — `initialize`
# succeeds (C1) and both tools are listed (C2), so the fault is entirely in
# the schema layer.
#
# Useful one-liners (the server is an importable module, so inspect it directly):
#   $ python3 -c 'import json,server; print(json.dumps(server.GET_FORECAST, indent=2))'
#   $ python3 -c 'import json,server; print(json.dumps(server.handle_get_forecast({"station":"SAEZ"}), indent=2))'
#   $ python3 -c 'import json,server; json.loads(server.STATION_CATALOGUE)'
#     Traceback ... json.decoder.JSONDecodeError: Expecting value: line 6 column 3 (char 129)
#
# -----------------------------------------------------------------------------
# STEP 1 — C4: the inputSchema root type (GET_FORECAST["inputSchema"]["type"])
# -----------------------------------------------------------------------------
# Symptom: the model never calls get_forecast. A validating host loads
# tools/list, fails to resolve the schema, and silently drops the tool — from
# the model's point of view the tool does not exist. Nothing is logged as an
# error at the protocol level, which is exactly why this one is expensive.
#
#   BEFORE:   "type": "Object",
#   AFTER:    "type": "object",
#
# Two rules in one line. JSON Schema type names are lowercase and case
# sensitive — "Object" is not a misspelling the validator tolerates, it is an
# unknown type. And MCP requires a tool's inputSchema root to be an object
# schema specifically, because tool arguments are always passed as a named
# map (`params.arguments`), never as a bare scalar or array.
#   https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#   https://json-schema.org/understanding-json-schema/reference/type
#
# -----------------------------------------------------------------------------
# STEP 2 — C4: required names a property that does not exist
# -----------------------------------------------------------------------------
# Symptom: even after step 1, a strict host reports the schema as
# unsatisfiable, and a permissive host lets the model guess: it invents a
# `units` key the server ignores, or it refuses to call at all because it
# cannot fill a required parameter that has no description, no type and no
# enum.
#
#   BEFORE:   "required": ["station", "units"],
#   AFTER:    "required": ["station"],
#
# The property is `unit` (singular), and it is genuinely optional: the handler
# defaults it. So the fix is to drop it from `required`, not to rename the
# entry. If you want it required instead, rename it to "unit" — but then the
# handler must stop defaulting and must reject a call without it. Either is
# defensible; what is never defensible is a `required` entry with no matching
# property, because no caller on earth can satisfy it.
#
# Keep the `enum` on `unit`: an enum is the cheapest way to stop a model from
# inventing "celsius", "C", "metric". Enums are part of the contract, not
# documentation.
#
# -----------------------------------------------------------------------------
# STEP 3 — C7 and C8: structuredContent must match the declared outputSchema
# -----------------------------------------------------------------------------
# Symptom: the call succeeds and the text block reads perfectly to a human —
# "SAEZ: 21.5 C, few clouds" — yet the consumer fails. The outputSchema
# promises `temperature_c` as a `number`; the handler returns `temperature` as
# a `string`. Wrong key, wrong type. Anything downstream that compares,
# averages or thresholds that value breaks, and the probe reports both:
#     structuredContent: required property "temperature_c" is missing
#
# Rewrite handle_get_forecast so the structured object is built once and the
# text block is its serialization:
#
#   def handle_get_forecast(args):
#       station_id = (args.get("station") or "SAEZ").upper()
#       row = next((s for s in STATIONS if s["id"] == station_id), None)
#       if row is None:
#           return {
#               "content": [{"type": "text", "text": "unknown station: %s" % station_id}],
#               "isError": True,
#           }
#
#       structured = {
#           "station": row["id"],
#           "temperature_c": row["temperature_c"],   # number, not str(...)
#           "conditions": row["conditions"],
#       }
#       return {
#           "content": [{"type": "text", "text": json.dumps(structured)}],
#           "structuredContent": structured,
#       }
#
# Three things happened there, and each is exam-relevant:
#   * the key now matches the schema (`temperature_c`);
#   * the value keeps its JSON type (`21.5`, not `"21.5"`) — str() is how a
#     float silently becomes a string, and JSON has a number type precisely so
#     you do not have to re-parse it;
#   * `content` is now derived from `structuredContent` instead of being written
#     by hand. That is the general rule: ONE source of truth, serialized. The
#     text block exists for backwards compatibility with hosts that ignore
#     structuredContent, and it SHOULD carry the same data (probe check C8).
#
# Note `isError: true` for the unknown-station path: a tool-level failure is
# reported inside the result so the model can see it and retry, NOT as a
# JSON-RPC error object, which is reserved for protocol-level faults
# (unknown method, malformed request, unknown tool name).
#
# -----------------------------------------------------------------------------
# STEP 4 — C9 and C10: declaring an outputSchema obliges the handler
# -----------------------------------------------------------------------------
# Symptom: list_stations returns a comma-separated sentence. The agent tries to
# iterate it and gets characters, or splits it on ", " and hopes. The tool
# declares an outputSchema, so returning no structuredContent at all is a
# contract violation, not a style choice.
#
#   def handle_list_stations(args):
#       structured = {"stations": [s["id"] for s in STATIONS]}
#       return {
#           "content": [{"type": "text", "text": json.dumps(structured)}],
#           "structuredContent": structured,
#       }
#
# The schema says `"items": {"type": "string"}`, and station ids are strings —
# the shapes agree. If you had returned the full station dicts, C10 would fail
# with `structuredContent.stations[0]: expected string, got object`. When that
# happens the answer is a decision, not a cast: either the schema describes
# objects (`"items": {"type": "object", "properties": {...}}`) or the handler
# returns ids. Never coerce the data to fit a schema you did not mean.
#
# -----------------------------------------------------------------------------
# STEP 5 — C12: a mimeType is a claim about the bytes
# -----------------------------------------------------------------------------
# Symptom: the resource is advertised as `application/json`, the host reads it
# and calls json.loads(), and it explodes on the trailing comma after the last
# array element. JSON, unlike Python, allows no trailing comma — and no
# comments either, which is the other way hand-written JSON dies.
#
# The tempting fix is to delete the comma. The correct fix is to stop writing
# JSON by hand, because the same class of bug will come back the moment anyone
# edits the catalogue:
#
#   BEFORE:
#       STATION_CATALOGUE = """{
#         "stations": [
#           {"id": "SAEZ", "name": "Ezeiza"},
#           ...
#         ]
#       }
#       """
#
#   AFTER (delete the string constant entirely and serialize the real data):
#       def station_catalogue():
#           return json.dumps(
#               {"stations": [{"id": s["id"], "name": s["name"]} for s in STATIONS]},
#               indent=2,
#           )
#
#   ... and in the resources/read branch of dispatch():
#       reply(request_id, {"contents": [{
#           "uri": uri,
#           "mimeType": "application/json",
#           "text": station_catalogue(),
#       }]})
#
# Now the payload cannot drift from the data and cannot be syntactically
# invalid, and the catalogue stays in sync with the STATIONS list that feeds
# the tools. Serializers exist so that structured data is produced by a
# machine that cannot forget a comma.
#
# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
#   $ ./mcpa-2.1-break-fix.sh verify
#
#   === MCP schema probe: weather-lab ===
#   [PASS] C1  initialize handshake completes
#   [PASS] C2  tools/list advertises get_forecast and list_stations
#   [PASS] C3  get_forecast declares both inputSchema and outputSchema
#   [PASS] C4  get_forecast.inputSchema is a usable JSON Schema object
#   [PASS] C5  declared outputSchemas are structurally sound
#   [PASS] C6  get_forecast returns structuredContent (outputSchema is declared)
#   [PASS] C7  get_forecast.structuredContent conforms to its outputSchema
#   [PASS] C8  the text content block mirrors structuredContent as serialized JSON
#   [PASS] C9  list_stations returns structuredContent (outputSchema is declared)
#   [PASS] C10 list_stations.structuredContent conforms to its outputSchema
#   [PASS] C11 the station catalogue resource is advertised with a mimeType
#   [PASS] C12 a resource declared "application/json" parses as JSON
#
#   0 failing, 0 warning, 12 passing
#   LAB PASSED — 0 failing checks. The schema contract holds end to end.
#
# -----------------------------------------------------------------------------
# WHAT TO CARRY INTO PRODUCTION (and into the exam)
# -----------------------------------------------------------------------------
#   * A tool's inputSchema is not documentation. Hosts read it to decide whether
#     the tool is usable at all, and a malformed schema removes the tool from
#     the model's world with no error anyone will notice.
#   * `type` values are lowercase; `required` may only name declared properties;
#     `enum` is the cheapest guard against invented arguments.
#   * `outputSchema` is a promise. If you declare it, `structuredContent` is
#     mandatory and must validate — key by key, type by type. If you are not
#     going to honour it, do not declare it.
#   * `content` is for humans and legacy hosts; `structuredContent` is for
#     programs. Build the structured object first and serialize it into the text
#     block, so the two can never disagree.
#   * Never hand-write JSON into a string literal. `json.dumps` cannot produce a
#     trailing comma, a comment, or an unquoted key.
#   * Validate your own schemas in CI. Everything the probe does here —
#     lint the advertised schema, call the tool, validate the response against
#     the schema the server itself published — is a few dozen lines and catches
#     this entire class of defect before a student, or a model, ever sees it.
#
# SOURCES
#   Linux Foundation, MCPA certification:
#     https://training.linuxfoundation.org/certification/model-context-protocol-associate-mcpa/
#   MCP specification 2025-06-18, Tools (inputSchema, outputSchema,
#   structuredContent, isError):
#     https://modelcontextprotocol.io/specification/2025-06-18/server/tools
#   MCP specification 2025-06-18, Resources (uri, mimeType, contents):
#     https://modelcontextprotocol.io/specification/2025-06-18/server/resources
#   JSON Schema, type keyword:
#     https://json-schema.org/understanding-json-schema/reference/type
#   RFC 8259, The JavaScript Object Notation (JSON) Data Interchange Format:
#     https://www.rfc-editor.org/rfc/rfc8259
# =============================================================================