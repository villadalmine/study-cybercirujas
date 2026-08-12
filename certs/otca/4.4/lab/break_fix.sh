#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 4: Maintaining and Debugging Observability Pipelines
#  Topic 4.4: Schema Management            (exam weight: 2.5)
#
#  BREAK & FIX LAB — OpenTelemetry Telemetry Schema files and the Collector
#  `schema` (schemaprocessor) transformation processor.
# ============================================================================
#
#  WHY THIS TOPIC MATTERS
#    OpenTelemetry decouples the *semantic conventions* a producer emits from
#    the ones a consumer expects by stamping every Resource and every
#    Instrumentation Scope with a `schema_url`. A Telemetry Schema file, hosted
#    at that URL, declares an ordered history of versions and the mechanical
#    transformations (rename_attributes, rename_metrics, split, ...) that carry
#    telemetry from one version to another. The Collector's `schema` processor
#    fetches those files and rewrites in-flight telemetry to a target version.
#    A malformed or inconsistent schema file silently poisons that pipeline:
#    the processor cannot load it, and every span/metric/log that should have
#    been up-converted flows through untransformed — or the Collector refuses
#    to start at all. Reading the file format rules correctly is the skill.
#
#  OFFICIAL REFERENCES
#    OTCA curriculum ...... https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#    Telemetry Schemas .... https://opentelemetry.io/docs/specs/otel/schemas/
#    File format v1.1.0 ... https://opentelemetry.io/docs/specs/otel/schemas/file_format_v1.1.0/
#    schemaprocessor ...... https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/schemaprocessor
#
#  WHAT THIS SCRIPT DOES (no args == full run)
#    1. Builds a self-contained, disposable lab under $LAB_DIR.
#    2. Serves a VALID telemetry schema file over loopback HTTP.
#    3. Wires an OpenTelemetry Collector `schema` processor that prefetches it.
#    4. Proves the baseline loads cleanly (stdlib linter + real Collector if present).
#    5. Injects ONE controlled defect into the schema file.
#    6. Prints the symptom you will see and the objective you must reach.
#
#  SAFETY GUARANTEES
#    - Writes ONLY under $LAB_DIR (default: $HOME/otca-4.4-schema-lab).
#    - Binds every listener to 127.0.0.1 exclusively.
#    - No root, no package installs, no system files touched.
#    - Fully reversible:  `reset` restores the known-good schema,
#                         `destroy` stops the server and deletes the lab dir.
#    - Refuses to run unless you confirm this is a throwaway VM.
#
#  USAGE
#    ./break-fix-4.4-schema.sh            # setup -> baseline -> break -> symptom
#    ./break-fix-4.4-schema.sh status     # re-run the diagnostics (use while fixing)
#    ./break-fix-4.4-schema.sh reset      # restore the known-good schema file
#    ./break-fix-4.4-schema.sh destroy    # tear the whole lab down
#    DEFECT=2 ./break-fix-4.4-schema.sh   # force a specific defect (1|2|3), else random
# ============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
LAB_DIR="${LAB_DIR:-$HOME/otca-4.4-schema-lab}"
SCHEMAS_DIR="$LAB_DIR/schemas"
SCHEMA_FILE="$SCHEMAS_DIR/1.9.0"          # served at /schemas/1.9.0 (family latest URL)
CONFIG_FILE="$LAB_DIR/collector.yaml"
PORTFILE="$LAB_DIR/.port"
PIDFILE="$LAB_DIR/.server.pid"
DEFECTFILE="$LAB_DIR/.defect"
RUNLOG="$LAB_DIR/collector-run.log"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  \033[36m•\033[0m %s\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()   { printf '  \033[31m�’\033[0m %s\n' "$*" >&2; }
rule()  { printf '\033[2m%s\033[0m\n' "----------------------------------------------------------------------"; }

# --------------------------------------------------------------------------- #
# Guards & dependencies
# --------------------------------------------------------------------------- #
guard_disposable() {
  if [ "${OTCA_LAB_DISPOSABLE:-}" = "yes" ]; then return 0; fi
  bold "SAFETY CHECK"
  warn "This lab deliberately breaks a schema pipeline. Run it ONLY on a"
  warn "disposable lab VM you can throw away."
  printf '  Type EXACTLY "yes" to confirm this is a throwaway VM: '
  read -r reply
  [ "$reply" = "yes" ] || { err "Not confirmed. Aborting."; exit 1; }
}

require_deps() {
  command -v python3 >/dev/null 2>&1 || { err "python3 is required (schema server + linter)."; exit 1; }
  command -v curl    >/dev/null 2>&1 || { err "curl is required (to probe the schema URL)."; exit 1; }
  if command -v otelcol-contrib >/dev/null 2>&1; then
    HAVE_COLLECTOR=1
  else
    HAVE_COLLECTOR=0
  fi
}

pick_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# --------------------------------------------------------------------------- #
# Schema file generation (good baseline + the three controlled defects)
# --------------------------------------------------------------------------- #
# Baseline rules encoded here (all mandated by the v1.1.0 file format spec):
#   - file_format MUST be a version the Collector understands (1.0.0 / 1.1.0).
#   - versions MUST be listed newest-first, strictly descending, full semver.
#   - schema_url's version segment MUST equal the newest declared version.
write_schema() {
  local variant="$1" port ff topver lastver
  port="$(cat "$PORTFILE")"
  ff="1.1.0"; topver="1.9.0"; lastver="1.7.0"
  case "$variant" in
    good) : ;;
    d1)   ff="1.4.0"    ;;   # unsupported file_format
    d2)   lastver="1.7" ;;   # invalid (non-semver) version identifier
    d3)   topver="1.9.1";;   # newest version no longer matches schema_url
    *)    err "unknown schema variant: $variant"; exit 1 ;;
  esac
  cat > "$SCHEMA_FILE" <<EOF
file_format: ${ff}
schema_url: http://127.0.0.1:${port}/schemas/1.9.0
versions:
  ${topver}:
    all:
      changes:
        - rename_attributes:
            attribute_map:
              browser.user_agent: user_agent.original
  1.8.0:
    spans:
      changes:
        - rename_attributes:
            attribute_map:
              db.cassandra.keyspace: db.name
              db.hbase.namespace: db.name
  ${lastver}:
EOF
  echo "$variant" > "$DEFECTFILE"
}

write_collector_config() {
  local port; port="$(cat "$PORTFILE")"
  cat > "$CONFIG_FILE" <<EOF
# OpenTelemetry Collector (contrib) — minimal schema-transform pipeline.
# 'prefetch' forces the schema file to be fetched and parsed at startup, so a
# broken schema surfaces immediately instead of on first matching telemetry.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
processors:
  schema:
    prefetch:
      - http://127.0.0.1:${port}/schemas/1.9.0
    targets:
      - http://127.0.0.1:${port}/schemas/1.9.0
exporters:
  debug:
    verbosity: detailed
service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [schema]
      exporters:  [debug]
EOF
}

# --------------------------------------------------------------------------- #
# Stdlib-only schema linter — deterministic symptom, no PyYAML/Collector needed.
# It enforces exactly the file-format rules the Collector's loader enforces.
# --------------------------------------------------------------------------- #
run_linter() {
  python3 - "$SCHEMA_FILE" <<'PY'
import sys, re
path = sys.argv[1]
SUPPORTED = {"1.0.0", "1.1.0"}

def fail(msg):
    print("SCHEMA ERROR: " + msg)
    sys.exit(1)

lines = open(path, encoding="utf-8").read().splitlines()

file_format = schema_url = None
for ln in lines:
    m = re.match(r'^file_format:\s*"?([^"\s#]+)"?\s*$', ln)
    if m: file_format = m.group(1)
    m = re.match(r'^schema_url:\s*"?(\S+?)"?\s*$', ln)
    if m: schema_url = m.group(1)

if file_format is None:
    fail("missing required top-level key 'file_format'")
if file_format not in SUPPORTED:
    fail("unsupported schema file format %r (Collector accepts: %s)"
         % (file_format, ", ".join(sorted(SUPPORTED))))
if schema_url is None:
    fail("missing required top-level key 'schema_url'")

in_versions = False
versions = []
for ln in lines:
    if re.match(r'^versions:\s*$', ln):
        in_versions = True
        continue
    if in_versions and re.match(r'^\S', ln):
        in_versions = False
    if in_versions:
        m = re.match(r'^  ([^\s:]+):\s*$', ln)   # 2-space indent == a version key
        if m: versions.append(m.group(1))

if not versions:
    fail("no versions defined under 'versions:'")

semver = re.compile(r'^\d+\.\d+\.\d+$')
for v in versions:
    if not semver.match(v):
        fail("invalid version identifier %r (must be full semver MAJOR.MINOR.PATCH)" % v)

key = lambda v: tuple(int(x) for x in v.split('.'))
for a, b in zip(versions, versions[1:]):
    if key(a) <= key(b):
        fail("versions must be newest-first and strictly descending; "
             "%r is not greater than %r" % (a, b))

top = versions[0]
url_ver = schema_url.rstrip('/').split('/')[-1]
if url_ver != top:
    fail("schema_url version %r must equal the newest declared version %r" % (url_ver, top))

print("SCHEMA OK: file_format=%s  latest=%s  versions=[%s]"
      % (file_format, top, ", ".join(versions)))
PY
}

# --------------------------------------------------------------------------- #
# HTTP server for the schema family URL (loopback only)
# --------------------------------------------------------------------------- #
start_server() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    return 0
  fi
  local port; port="$(cat "$PORTFILE")"
  ( cd "$LAB_DIR" && exec python3 -m http.server "$port" --bind 127.0.0.1 ) \
      >"$LAB_DIR/.http.log" 2>&1 &
  echo $! > "$PIDFILE"
  local url="http://127.0.0.1:${port}/schemas/1.9.0"
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then ok "schema server up on 127.0.0.1:${port}"; return 0; fi
    sleep 0.2
  done
  warn "schema server did not answer in time (check $LAB_DIR/.http.log)"
}

stop_server() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

# --------------------------------------------------------------------------- #
# Optional real-Collector probe (only if otelcol-contrib is installed)
# --------------------------------------------------------------------------- #
collector_probe() {
  [ "${HAVE_COLLECTOR:-0}" = "1" ] || { info "otelcol-contrib not found — skipping live Collector probe (linter is authoritative)."; return 0; }
  : > "$RUNLOG"
  timeout 8s otelcol-contrib --config "$CONFIG_FILE" >"$RUNLOG" 2>&1 &
  local cpid=$!
  sleep 6
  kill "$cpid" 2>/dev/null || true
  wait "$cpid" 2>/dev/null || true
  if grep -iEq 'schema|unmarshal|invalid|failed to (load|parse)|error' "$RUNLOG"; then
    warn "Collector reported an issue while loading the schema:"
    grep -iE 'schema|unmarshal|invalid|failed|error' "$RUNLOG" | head -n 6 | sed 's/^/      /'
  else
    ok "Collector started and prefetched the schema without complaint."
  fi
}

# --------------------------------------------------------------------------- #
# Diagnostics the student re-runs while fixing
# --------------------------------------------------------------------------- #
status() {
  local port; port="$(cat "$PORTFILE")"
  bold "DIAGNOSTICS"
  rule
  info "1) Does the schema URL resolve?"
  if curl -fsS -o /dev/null "http://127.0.0.1:${port}/schemas/1.9.0"; then
    ok "GET /schemas/1.9.0 -> 200"
  else
    err "GET /schemas/1.9.0 failed (is the server up? try: $0 setup)"
  fi
  echo
  info "2) Is the schema file well-formed per the v1.1.0 spec?"
  if run_linter; then :; fi
  echo
  info "3) Live Collector behaviour:"
  collector_probe
  rule
}

# --------------------------------------------------------------------------- #
# Symptom briefing shown after the break
# --------------------------------------------------------------------------- #
show_symptom() {
  local defect port; defect="$(cat "$DEFECTFILE")"; port="$(cat "$PORTFILE")"
  echo
  bold "############################################################"
  bold "#  BREAK INJECTED — your turn                              #"
  bold "############################################################"
  echo
  bold "SYMPTOM"
  case "$defect" in
    d1) info "The schema processor refuses to load the schema. Logs / linter report an"
        info "UNSUPPORTED file_format. Telemetry is never up-converted; with 'prefetch'"
        info "the Collector fails at startup instead of serving the traces pipeline." ;;
    d2) info "Schema loading fails with an INVALID VERSION IDENTIFIER. One entry under"
        info "'versions:' is not a full semver, so the processor cannot build the"
        info "version graph and every transformation is skipped." ;;
    d3) info "The schema loads structurally but is rejected as INCONSISTENT: the newest"
        info "declared version no longer matches the version segment of 'schema_url'."
        info "Consumers keying off schema_url and the file disagree about 'latest'." ;;
  esac
  echo
  bold "WHAT YOU CAN SEE IT WITH"
  info "curl  -s http://127.0.0.1:${port}/schemas/1.9.0        # inspect what is served"
  info "$0 status                                            # linter + live Collector verdict"
  [ "${HAVE_COLLECTOR:-0}" = "1" ] && info "tail -n 40 $RUNLOG                                    # raw Collector log"
  echo
  bold "YOUR OBJECTIVE"
  info "Edit ONLY the schema file:"
  info "  $SCHEMA_FILE"
  info "Make it satisfy the OpenTelemetry Telemetry Schema v1.1.0 rules so that"
  info "'$0 status' prints 'SCHEMA OK' and the Collector prefetches it cleanly."
  info "Do NOT touch collector.yaml — the pipeline config is already correct."
  echo
  info "Rules to satisfy (spec):"
  info "  - file_format is one the Collector supports (1.0.0 or 1.1.0)."
  info "  - every key under 'versions:' is full semver MAJOR.MINOR.PATCH."
  info "  - versions are newest-first and strictly descending."
  info "  - the version in 'schema_url' equals the newest declared version."
  echo
  warn "When you are done, verify with:  $0 status"
  warn "Give up / clean up with:         $0 destroy"
  echo
}

# --------------------------------------------------------------------------- #
# Lifecycle
# --------------------------------------------------------------------------- #
setup() {
  mkdir -p "$SCHEMAS_DIR"
  [ -f "$PORTFILE" ] || pick_free_port > "$PORTFILE"
  write_schema good
  write_collector_config
  start_server
  ok "Lab ready under $LAB_DIR (schema served on 127.0.0.1:$(cat "$PORTFILE"))."
}

baseline() {
  bold "BASELINE — the schema pipeline is healthy before we break it"
  rule
  run_linter && ok "Baseline schema passes the linter."
  collector_probe
  rule
}

do_break() {
  local defect="${DEFECT:-}"
  if [ -z "$defect" ]; then defect=$(( (RANDOM % 3) + 1 )); fi
  case "$defect" in
    1|d1) write_schema d1 ;;
    2|d2) write_schema d2 ;;
    3|d3) write_schema d3 ;;
    *)    write_schema d1 ;;
  esac
  warn "Controlled defect injected into the schema file."
}

reset() {
  [ -f "$PORTFILE" ] || { err "No lab found. Run: $0 setup"; exit 1; }
  write_schema good
  ok "Known-good schema restored. Verify with: $0 status"
}

destroy() {
  stop_server
  rm -rf "$LAB_DIR"
  ok "Lab destroyed: $LAB_DIR removed, schema server stopped."
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
case "${1:-run}" in
  setup)   require_deps; setup ;;
  status)  require_deps; status ;;
  reset)   require_deps; reset ;;
  destroy) destroy ;;
  run|"")  guard_disposable; require_deps; setup; baseline; do_break; show_symptom ;;
  *)       err "Unknown command: $1"; echo "Usage: $0 [setup|status|reset|destroy]"; exit 1 ;;
esac

# ===========================================================================
# ============================  SOLUTION (spoiler)  =========================
# ===========================================================================
#
# Do not read this until you have tried. The break is always in the schema
# file — never in collector.yaml. Which of the three defects you got is
# recorded in .defect, but you should diagnose it from the symptom, not the file.
#
# ---------------------------------------------------------------------------
# STEP 0 — Reproduce and read the evidence
# ---------------------------------------------------------------------------
#   ./break-fix-4.4-schema.sh status
#   PORT=$(cat "$HOME/otca-4.4-schema-lab/.port")
#   curl -s "http://127.0.0.1:${PORT}/schemas/1.9.0"
#
#   The linter prints a single "SCHEMA ERROR: ..." line naming the exact
#   violated rule. If otelcol-contrib is installed, the same defect appears in
#   collector-run.log as a schema-load failure. Trust the message: schema
#   problems are mechanically detectable, so the tool tells you the rule.
#
# ---------------------------------------------------------------------------
# DEFECT 1 — "unsupported schema file format 1.4.0"
# ---------------------------------------------------------------------------
#   Cause: the `file_format:` field advertises a version of the *file schema*
#          (not the telemetry version) that the Collector's loader does not
#          implement. As of the v1.1.0 spec the accepted values are 1.0.0 and
#          1.1.0. A wrong value makes the whole file unparseable up front.
#   Fix:   set it back to a supported format.
#       sed -i 's/^file_format: .*/file_format: 1.1.0/' \
#           "$HOME/otca-4.4-schema-lab/schemas/1.9.0"
#   Ref:   https://opentelemetry.io/docs/specs/otel/schemas/file_format_v1.1.0/
#
# ---------------------------------------------------------------------------
# DEFECT 2 — "invalid version identifier '1.7' ..."
# ---------------------------------------------------------------------------
#   Cause: every key under `versions:` is a telemetry schema version and MUST
#          be a full semver MAJOR.MINOR.PATCH. `1.7` is not — the processor
#          cannot order it in the version graph, so no transformation chain can
#          be built and up-conversion silently stops.
#   Fix:   restore the missing patch component.
#       sed -i 's/^  1\.7:\s*$/  1.7.0:/' \
#           "$HOME/otca-4.4-schema-lab/schemas/1.9.0"
#   Ref:   https://opentelemetry.io/docs/specs/otel/schemas/#schema-version-number
#
# ---------------------------------------------------------------------------
# DEFECT 3 — "schema_url version '1.9.0' must equal the newest declared version '1.9.1'"
# ---------------------------------------------------------------------------
#   Cause: the file is served at .../schemas/1.9.0, and its own `schema_url:`
#          says 1.9.0, but the newest key under `versions:` is 1.9.1. The spec
#          requires the version segment of schema_url to equal the latest
#          version defined in the file — otherwise a consumer that read
#          schema_url=1.9.0 and a producer stamping 1.9.1 disagree on "latest".
#   Fix (Option A — the file really is the 1.9.0 family): renumber the top
#       version key back to 1.9.0 so it matches schema_url and the served path.
#         sed -i '0,/^  1\.9\.1:/s//  1.9.0:/' \
#             "$HOME/otca-4.4-schema-lab/schemas/1.9.0"
#   Fix (Option B — you genuinely published 1.9.1): bump schema_url AND serve
#       the file at the new family URL, then point the processor's prefetch/
#       targets at .../schemas/1.9.1. In this lab, Option A is the intended fix
#       because the served path and processor config both say 1.9.0.
#   Ref:   https://opentelemetry.io/docs/specs/otel/schemas/#schema_url
#
# ---------------------------------------------------------------------------
# STEP N — Verify and clean up
# ---------------------------------------------------------------------------
#   ./break-fix-4.4-schema.sh status     # expect "SCHEMA OK" + clean Collector
#   ./break-fix-4.4-schema.sh destroy    # remove the lab when finished
#
#   Shortcut if you get stuck:  ./break-fix-4.4-schema.sh reset  (restores good schema)
#
# ---------------------------------------------------------------------------
# WHAT TO INTERNALISE FOR THE EXAM
#   - schema_url lives on Resource and on each Instrumentation Scope; it is the
#     pointer that makes schema-aware translation possible.
#   - The schema FILE is versioned history + transformations, governed by its
#     own `file_format`; do not confuse that with the telemetry versions inside.
#   - The Collector `schema` processor converts telemetry toward `targets`;
#     `prefetch` only changes WHEN files load, turning lazy failures into loud
#     startup failures — a deliberate operability choice.
#   - Every schema-file failure mode is mechanical and detectable: unsupported
#     format, non-semver version, non-descending order, url/version mismatch,
#     unreachable URL. That is why schema management is testable and automatable.
# ===========================================================================