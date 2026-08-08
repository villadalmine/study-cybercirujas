#!/usr/bin/env bash
# ============================================================================
# CNPA — Certified Cloud Native Platform Engineering Associate
# Domain 6.1 — Platform Efficiency, Product Value, and Team Productivity  (weight 4.0)
# Exam version: 2025-04-01
# Source (official curriculum):
#   https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#
# BREAK & FIX LAB  —  "The golden path lost its guardrails"
# ----------------------------------------------------------------------------
# WHY THIS MAPS TO 6.1
#   Platform engineering treats the platform as a PRODUCT. Its value is not the
#   YAML it emits but the outcomes it buys the org:
#     * Efficiency    -> workloads that bin-pack, respect quota and fair-share
#                        because every service ships resource requests/limits.
#     * Product value -> a paved "golden path" that encodes best practice as the
#                        DEFAULT, so reliability is inherited, not rediscovered.
#     * Productivity  -> self-service with guardrails-as-code, so a developer
#                        provisions a compliant service in seconds without
#                        holding the whole platform in their head (low cognitive
#                        load), and lead time / deployment frequency stay high.
#   This lab ships a miniature Internal Developer Platform (IDP): a template, a
#   self-service CLI (platformctl) that refuses to emit non-compliant manifests,
#   and a scorecard that measures the golden path the way a platform team would
#   measure a product. Then it breaks the template and lets you feel the blast
#   radius on the value metrics.
#
# SAFETY
#   100% self-contained. Writes ONLY under $LAB_DIR (default: $HOME/cnpa-lab/6.1).
#   No sudo, no cluster, no system packages, no network. Designed for a
#   disposable lab VM; deletes and rebuilds only its own sandbox.
#   Dependencies: bash, coreutils, sed, awk, grep (all standard).
# ============================================================================

set -uo pipefail

LAB_DIR="${LAB_DIR:-$HOME/cnpa-lab/6.1}"
BIN="$LAB_DIR/bin"
TMPL_DIR="$LAB_DIR/platform/templates"
TEMPLATE="$TMPL_DIR/service.yaml.tmpl"

say() { printf '%s\n' "$*"; }
hr()  { printf -- '----------------------------------------------------------------------\n'; }

# ----------------------------------------------------------------------------
# provision(): stand up the fully-working platform (the "before" state).
# ----------------------------------------------------------------------------
provision() {
  mkdir -p "$BIN" "$TMPL_DIR" "$LAB_DIR/services"

  # ---- The golden-path template (single source of truth for every service) ----
  # Placeholders are rendered by platformctl. The resources block is fenced by
  # markers so the platform team can audit the efficiency guardrail at a glance.
  cat > "$TEMPLATE" <<'TMPL'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
  labels:
    app.kubernetes.io/name: ${SERVICE_NAME}
    app.kubernetes.io/managed-by: platformctl
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${SERVICE_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${SERVICE_NAME}
    spec:
      containers:
        - name: ${SERVICE_NAME}
          image: ${IMAGE}
          ports:
            - containerPort: ${PORT}
          readinessProbe:
            httpGet:
              path: /healthz
              port: ${PORT}
            initialDelaySeconds: 5
            periodSeconds: 10
          # >>> guardrail:resources (platform efficiency policy — keep in sync with validate)
          resources:
            requests:
              cpu: "${CPU_REQUEST}"
              memory: "${MEM_REQUEST}"
            limits:
              cpu: "${CPU_LIMIT}"
              memory: "${MEM_LIMIT}"
          # <<< guardrail:resources
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  labels:
    app.kubernetes.io/name: ${SERVICE_NAME}
spec:
  selector:
    app.kubernetes.io/name: ${SERVICE_NAME}
  ports:
    - port: 80
      targetPort: ${PORT}
TMPL

  # ---- platformctl: the self-service CLI with guardrails-as-code ----
  cat > "$BIN/platformctl" <<'PLATFORMCTL'
#!/usr/bin/env bash
# platformctl — the paved road. Renders a service from the platform template and
# ENFORCES the golden-path guardrails before anything is written. A developer
# never hand-writes a Deployment; they inherit compliant defaults for free.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/platform/templates/service.yaml.tmpl"
SERVICES_DIR="$ROOT/services"

usage() {
  cat <<USAGE
usage: platformctl <command> <service>
  new <name>        Provision a service via the golden path (refuses if non-compliant)
  render <name>     Print the rendered manifest to stdout (no guardrail gate)
  check <name>      Render + validate quietly; exit 0 if compliant, 1 otherwise
  validate <file>   Run the golden-path guardrails against an existing manifest

Overridable defaults (env): IMAGE PORT REPLICAS CPU_REQUEST CPU_LIMIT MEM_REQUEST MEM_LIMIT
USAGE
}

render() {
  local name="$1"
  local image="${IMAGE:-ghcr.io/acme/${name}:1.0.0}"
  local port="${PORT:-8080}"
  local replicas="${REPLICAS:-2}"
  local cpu_request="${CPU_REQUEST:-100m}"
  local cpu_limit="${CPU_LIMIT:-500m}"
  local mem_request="${MEM_REQUEST:-128Mi}"
  local mem_limit="${MEM_LIMIT:-256Mi}"
  sed -e "s|\${SERVICE_NAME}|${name}|g" \
      -e "s|\${IMAGE}|${image}|g" \
      -e "s|\${PORT}|${port}|g" \
      -e "s|\${REPLICAS}|${replicas}|g" \
      -e "s|\${CPU_REQUEST}|${cpu_request}|g" \
      -e "s|\${CPU_LIMIT}|${cpu_limit}|g" \
      -e "s|\${MEM_REQUEST}|${mem_request}|g" \
      -e "s|\${MEM_LIMIT}|${mem_limit}|g" \
      "$TEMPLATE"
}

# The golden-path guardrails. Each maps to a 6.1 pillar and is the reason the
# platform is worth more than a wiki page of copy-paste YAML.
validate() {
  local manifest="$1"
  local -a v=()
  local replicas image

  # HA (product value): a single replica is not a service, it is an incident.
  replicas="$(awk '$1=="replicas:"{print $2; exit}' "$manifest")"
  if ! [[ "${replicas:-}" =~ ^[0-9]+$ ]] || [ "${replicas:-0}" -lt 2 ]; then
    v+=("HA           : replicas must be an integer >= 2 (got '${replicas:-<none>}')")
  fi

  # EFFICIENCY: no requests/limits => scheduler cannot bin-pack, quota and
  # fair-share break, cluster cost drifts. This is the heart of 6.1.
  if ! grep -Eq '^[[:space:]]+resources:' "$manifest"; then
    v+=("EFFICIENCY   : container has no resources block; requests/limits are required for bin-packing, quota and fair-share")
  else
    grep -Eq '^[[:space:]]+requests:' "$manifest" || v+=("EFFICIENCY   : resources.requests missing")
    grep -Eq '^[[:space:]]+limits:'   "$manifest" || v+=("EFFICIENCY   : resources.limits missing")
  fi

  # RELIABILITY: no readiness probe => traffic to not-ready pods on every rollout.
  grep -Eq 'readinessProbe:' "$manifest" || v+=("RELIABILITY  : readinessProbe missing (unsafe rollouts)")

  # REPRODUCIBILITY: unpinned/':latest' images make deployments non-deterministic.
  image="$(awk '$1=="image:"{print $2; exit}' "$manifest")"
  if [[ -z "${image:-}" || "$image" != *:* || "$image" == *:latest ]]; then
    v+=("REPRODUCIBLE : image must be pinned to an explicit tag (got '${image:-<none>}')")
  fi

  if [ "${#v[@]}" -gt 0 ]; then
    printf '  GUARDRAIL VIOLATION -> %s\n' "${v[@]}" >&2
    return 1
  fi
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  render)
    render "${1:?service name required}"
    ;;
  validate)
    manifest="${1:?manifest path required}"
    if validate "$manifest"; then
      echo "  PASS: $manifest satisfies every golden-path guardrail"
    else
      exit 1
    fi
    ;;
  check)
    name="${1:?service name required}"
    tmp="$(mktemp)"; render "$name" > "$tmp"
    if validate "$tmp" 2>/dev/null; then rm -f "$tmp"; exit 0; else rm -f "$tmp"; exit 1; fi
    ;;
  new)
    name="${1:?service name required}"
    tmp="$(mktemp)"; render "$name" > "$tmp"
    echo "platformctl: provisioning '$name' via the golden path ..."
    if validate "$tmp"; then
      dest="$SERVICES_DIR/$name"; mkdir -p "$dest"; mv "$tmp" "$dest/manifest.yaml"
      echo "  OK: golden path emitted $dest/manifest.yaml (all guardrails satisfied)"
    else
      rm -f "$tmp"
      echo "  REFUSED: the golden path will not emit a non-compliant manifest." >&2
      echo "  This is guardrails-as-code: fix the PLATFORM TEMPLATE so every"     >&2
      echo "  developer inherits compliant defaults — do not patch per service."  >&2
      exit 1
    fi
    ;;
  *)
    usage; exit 2 ;;
esac
PLATFORMCTL

  # ---- scorecard: measure the golden path the way a product team would ----
  cat > "$BIN/scorecard" <<'SCORECARD'
#!/usr/bin/env bash
# scorecard — turns "is the platform valuable?" into a number. It exercises the
# golden path for a set of canary services and reports the metrics a platform-
# as-a-product team lives by. Exit 0 only when the paved road is 100% healthy,
# so it can gate a pipeline (a value SLO, not a vibe).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORMCTL="$ROOT/bin/platformctl"
CANARIES=(payments orders search)

pass=0; total=${#CANARIES[@]}; fails=()
for s in "${CANARIES[@]}"; do
  if "$PLATFORMCTL" check "$s" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fails+=("$s")
  fi
done

rate=$(( pass * 100 / total ))
filled=$(( rate / 10 ))
bar=""
for ((i = 0; i < 10; i++)); do
  if (( i < filled )); then bar+="#"; else bar+="."; fi
done

health="RED";   verdict="guardrails FAILING — self-service is blocked, lead time is climbing"
if (( rate == 100 )); then health="GREEN"; verdict="paved road healthy — developers self-serve compliant services in seconds"; fi

echo "=================================================================="
echo " Platform Value Scorecard  —  Golden Path (domain 6.1)"
echo "=================================================================="
printf ' Self-Service Success Rate : %3d%%   [%s]  %d/%d canaries compliant\n' "$rate" "$bar" "$pass" "$total"
printf ' Golden Path Health        : %s\n' "$health"
printf ' Guardrails Enforced       : HA, EFFICIENCY(requests/limits), RELIABILITY, REPRODUCIBILITY\n'
if [ "${#fails[@]}" -gt 0 ]; then
  printf ' Blocked services          : %s\n' "${fails[*]}"
fi
printf ' Verdict                   : %s\n' "$verdict"
echo "------------------------------------------------------------------"
echo " DORA lens: every blocked canary is a Deployment Frequency of 0 and"
echo " an unbounded Lead Time for Changes. Platform value is the metric,"
echo " not the manifest."
echo "=================================================================="

if (( rate == 100 )); then exit 0; else exit 1; fi
SCORECARD

  chmod +x "$BIN/platformctl" "$BIN/scorecard"
}

# ----------------------------------------------------------------------------
# break_template(): inject the fault. A well-meaning edit removed the efficiency
# guardrail block "to reduce template noise". The template still renders valid
# YAML, so it silently passed casual review — but the paved road now ships
# services with no resource requests/limits.
# ----------------------------------------------------------------------------
break_template() {
  awk '
    /# >>> guardrail:resources/ { drop = 1 }
    !drop { print }
    /# <<< guardrail:resources/ { drop = 0 }
  ' "$TEMPLATE" > "$TEMPLATE.broken" && mv "$TEMPLATE.broken" "$TEMPLATE"
}

# ============================================================================
# MAIN
# ============================================================================
if [ -z "$LAB_DIR" ] || [ "$LAB_DIR" = "/" ]; then
  echo "Refusing to run: LAB_DIR is unsafe ('$LAB_DIR')." >&2; exit 1
fi
if [ -e "$LAB_DIR/.lab-active" ] && [ "${LAB_RESET:-0}" != "1" ]; then
  echo "Lab already provisioned at $LAB_DIR."
  echo "Keep working on your fix, or set LAB_RESET=1 to rebuild the broken state from scratch."
  exit 0
fi
rm -rf "$LAB_DIR"

hr
say "CNPA 6.1  Break & Fix — The golden path lost its guardrails"
hr
say "STEP 1/3  Provisioning the internal developer platform (template + platformctl + scorecard) ..."
provision
say "Provisioned at: $LAB_DIR"
say ""
say "STEP 2/3  Baseline — the paved road is HEALTHY before the break:"
hr
"$BIN/scorecard" || true
hr
say ""
say "STEP 3/3  Injecting the fault into the platform template ..."
break_template
touch "$LAB_DIR/.lab-active"
say "Done. The template has been modified."
say ""

hr
say "SYMPTOM (what you will observe)"
hr
say "The Platform Value Scorecard has gone RED and self-service is blocked:"
say ""
"$BIN/scorecard" || true
say ""
say "And the golden path now REFUSES to provision new services:"
say ""
"$BIN/platformctl" new payments || true
say ""
hr
say "OBJECTIVE (what you must achieve)"
hr
cat <<OBJECTIVE
Restore the golden path so that:
  1. platformctl check payments   -> exit 0 (compliant)
  2. platformctl new payments     -> writes services/payments/manifest.yaml
  3. scorecard                    -> GREEN, Self-Service Success Rate 100%

RULES OF THE EXERCISE (this is the 6.1 lesson):
  * Fix the PLATFORM TEMPLATE, not individual services. The value of the paved
    road is that ONE fix repairs EVERY current and future service. Patching each
    manifest by hand is exactly the toil the platform exists to eliminate.
  * The fault removed the platform's efficiency guardrail; the manifest still
    renders as valid YAML, which is why it slipped through. "Parses" is not
    "compliant".

WHERE THINGS LIVE
  Template : $TEMPLATE
  CLI      : $BIN/platformctl
  Scorecard: $BIN/scorecard

TRY IT
  export PATH="$BIN:\$PATH"
  platformctl render payments      # inspect what the paved road emits today
  platformctl check payments       # exit code is your pass/fail signal
  scorecard                        # your value SLO

Reset the broken state at any time with:  LAB_RESET=1 $0
OBJECTIVE
hr
exit 0

# ============================================================================
# ============================  SOLUTION (spoiler)  ==========================
# ============================================================================
# Everything below is commented. Read it only after attempting the fix.
#
# STEP 0 — Reproduce and read the signal
#   export PATH="$LAB_DIR/bin:$PATH"
#   scorecard
#     -> Self-Service Success Rate: 0%  (0/3), Golden Path Health: RED
#   platformctl new payments
#     -> GUARDRAIL VIOLATION -> EFFICIENCY : container has no resources block ...
#        REFUSED: the golden path will not emit a non-compliant manifest.
#
# STEP 1 — Localize the root cause (template, not service)
#   The CLI told you the class of defect (EFFICIENCY / resources). Inspect the
#   rendered output to confirm the template is the source:
#     platformctl render payments | sed -n '/containers:/,/---/p'
#   You will see the container ends at the readinessProbe: there is NO
#   'resources:' block. Every service the paved road produces is affected ->
#   the defect is upstream in the template, exactly one place:
#     $TEMPLATE
#
# STEP 2 — Fix the template (re-add the efficiency guardrail block)
#   Open the template and, immediately AFTER the readinessProbe's
#   'periodSeconds: 10' line (10-space indent, sibling of image/ports/
#   readinessProbe), restore:
#
#           # >>> guardrail:resources (platform efficiency policy — keep in sync with validate)
#           resources:
#             requests:
#               cpu: "${CPU_REQUEST}"
#               memory: "${MEM_REQUEST}"
#             limits:
#               cpu: "${CPU_LIMIT}"
#               memory: "${MEM_LIMIT}"
#           # <<< guardrail:resources
#
#   One-liner that inserts it deterministically (single match on the probe line):
#
#     awk '1; /periodSeconds: 10/{
#       print "          # >>> guardrail:resources (platform efficiency policy — keep in sync with validate)";
#       print "          resources:";
#       print "            requests:";
#       print "              cpu: \"${CPU_REQUEST}\"";
#       print "              memory: \"${MEM_REQUEST}\"";
#       print "            limits:";
#       print "              cpu: \"${CPU_LIMIT}\"";
#       print "              memory: \"${MEM_LIMIT}\"";
#       print "          # <<< guardrail:resources"
#     }' "$TEMPLATE" > "$TEMPLATE.fixed" && mv "$TEMPLATE.fixed" "$TEMPLATE"
#
# STEP 3 — Verify against the value SLO (not by eyeballing YAML)
#   platformctl check payments   ; echo "exit=$?"   # expect exit=0
#   platformctl new payments                        # expect: OK, writes manifest
#   cat "$LAB_DIR/services/payments/manifest.yaml"  # resources block present
#   scorecard                                       # expect GREEN, 100% (3/3)
#
#   The single template fix repaired payments, orders and search at once — that
#   is the productivity multiplier of a paved road, and why platform efficiency
#   is a product property, not a per-team chore.
#
# WHY THIS IS THE 6.1 POINT
#   * Efficiency    : resource requests/limits are what let the scheduler bin-pack
#                     and let quotas/fair-share hold; without them cost and noisy-
#                     neighbor risk drift silently.
#   * Product value : the guardrail lives in the golden path, so reliability and
#                     efficiency are DEFAULTS inherited by every service, not
#                     tribal knowledge rediscovered per team.
#   * Productivity  : guardrails-as-code let developers self-serve safely with low
#                     cognitive load; the scorecard makes the platform's value
#                     measurable (self-service success rate, and by extension DORA
#                     deployment frequency / lead time).
#
# Reference: CNCF CNPA Curriculum, Domain 6 (Platform Engineering as a Product):
#   https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ============================================================================