#!/usr/bin/env bash
#
# ============================================================================
#  KCA 3.3 — `jp` (JMESPath evaluation with the Kyverno CLI)   [weight 3.0]
#  Break & Fix laboratory — DISPOSABLE LAB VM / DISPOSABLE CLUSTER ONLY
# ============================================================================
#
#  What this script does
#  ---------------------
#  It installs a namespace-scoped Kyverno ClusterPolicy that contains THREE
#  deliberately seeded JMESPath faults, then proves the symptom to you by
#  running server-side dry-run admission probes. Your job is to repair the
#  JMESPath expressions using ONLY the `kyverno jp` sub-commands
#  (`jp function`, `jp parse`, `jp query`) plus kubectl.
#
#  Blast radius is bounded on purpose:
#    * the policy `match` block is pinned to the namespace kca-jp-lab, so a
#      broken expression with failurePolicy=Fail cannot wedge admission for
#      the rest of the cluster (this is the single most important production
#      habit in this domain);
#    * every probe uses `kubectl apply --dry-run=server`, which exercises the
#      webhook without creating workloads and without pulling any image;
#    * `--cleanup` removes everything the script created.
#
#  Reference sources
#    * KCA curriculum ....... https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    * kyverno jp ........... https://kyverno.io/docs/kyverno-cli/usage/jp/
#    * JMESPath in Kyverno .. https://kyverno.io/docs/writing-policies/jmespath/
#    * JMESPath spec ........ https://jmespath.org/specification.html
#    * Kyverno releases ..... https://github.com/kyverno/kyverno/releases
#
#  Usage
#    ./kca-3.3-jp-break-fix.sh            # break the lab (asks for confirmation)
#    ./kca-3.3-jp-break-fix.sh --yes      # break without prompting
#    ./kca-3.3-jp-break-fix.sh --verify   # grade your fix
#    ./kca-3.3-jp-break-fix.sh --cleanup  # remove policy, namespace and lab dir
#
# ============================================================================

set -euo pipefail

readonly NS="kca-jp-lab"
readonly POLICY="kca-jp-lab-image-guard"
readonly LAB_DIR="${KCA_LAB_DIR:-$HOME/kca-3.3-jp-lab}"
readonly KYVERNO_MANIFEST="${KYVERNO_MANIFEST:-https://github.com/kyverno/kyverno/releases/latest/download/install.yaml}"

ASSUME_YES=0
MODE="break"
KYVERNO_NS="kyverno"
KYVERNO_MINOR=13
PROBE_OUT=""

# ---------------------------------------------------------------- helpers --
say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)     ASSUME_YES=1 ;;
      --verify)     MODE="verify" ;;
      --cleanup)    MODE="cleanup" ;;
      -h|--help)    MODE="help" ;;
      *)            die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

print_help() {
  sed -n '3,40p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
}

# --------------------------------------------------------------- guardrails --
guard_context() {
  local ctx nodes
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [ -n "$ctx" ] || die "no current kubectl context; point KUBECONFIG at your lab cluster"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
    || die "cannot reach the API server with context '$ctx'"

  case "$ctx" in
    kind-*|k3d-*|minikube|minikube-*) ;;
    *)
      warn "context '$ctx' does not look like a throwaway lab cluster (kind/k3d/minikube)."
      ;;
  esac

  say "Target cluster"
  info "context ......... $ctx"
  info "nodes ........... $nodes"
  info "lab namespace ... $NS   (policy match is pinned to this namespace)"

  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\n    This will INSTALL A BROKEN POLICY in the cluster above. Continue? [type: break] '
    local answer=""
    read -r answer </dev/tty || true
    [ "$answer" = "break" ] || die "aborted by the operator"
  fi
}

# ------------------------------------------------------------------ kyverno --
detect_kyverno() {
  local img ver minor ns
  ns="$(kubectl get deploy -A \
        -l app.kubernetes.io/part-of=kyverno,app.kubernetes.io/component=admission-controller \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [ -n "$ns" ] && KYVERNO_NS="$ns"

  img="$(kubectl -n "$KYVERNO_NS" get deploy \
         -l app.kubernetes.io/component=admission-controller \
         -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [ -n "$img" ] || return 1

  ver="${img##*:}"; ver="${ver#v}"
  minor="$(printf '%s' "$ver" | cut -d. -f2)"
  case "$minor" in ''|*[!0-9]*) minor=13 ;; esac
  KYVERNO_MINOR="$minor"
  info "kyverno ......... $img  (treating API as 1.${KYVERNO_MINOR})"
  return 0
}

ensure_kyverno() {
  if detect_kyverno; then return 0; fi
  say "Kyverno is not installed in this cluster — installing it"
  info "manifest: $KYVERNO_MANIFEST"
  kubectl apply --server-side --force-conflicts -f "$KYVERNO_MANIFEST" >/dev/null
  kubectl -n "$KYVERNO_NS" rollout status deploy -l app.kubernetes.io/part-of=kyverno --timeout=300s \
    || kubectl -n "$KYVERNO_NS" wait --for=condition=Available deploy --all --timeout=300s
  detect_kyverno || die "Kyverno install did not converge; inspect namespace $KYVERNO_NS"
}

ensure_kyverno_cli() {
  if command -v kyverno >/dev/null 2>&1; then
    info "kyverno CLI ..... $(kyverno version 2>/dev/null | awk '/[Vv]ersion/{print $NF; exit}')"
    return 0
  fi
  cat >&2 <<'HINT'

[fatal] The `kyverno` CLI is missing, and this whole lab is about `kyverno jp`.
        Install it with ONE of:

          kubectl krew install kyverno

          # pick a release tag from https://github.com/kyverno/kyverno/releases
          VER=<version>            # e.g. v1.14.x
          curl -fsSL -o kyverno-cli.tar.gz \
            "https://github.com/kyverno/kyverno/releases/download/${VER}/kyverno-cli_${VER}_linux_x86_64.tar.gz"
          tar -xzf kyverno-cli.tar.gz kyverno && sudo install -m 0755 kyverno /usr/local/bin/kyverno

          go install github.com/kyverno/kyverno/cmd/cli/kubectl-kyverno@latest

        Keep the CLI minor version aligned with the cluster: the JMESPath
        function catalogue is versioned together with the admission controller.
HINT
  exit 1
}

# ---------------------------------------------------------------- lab files --
write_lab_files() {
  mkdir -p "$LAB_DIR"

  cat > "$LAB_DIR/pod-good.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: good-app
  namespace: kca-jp-lab
  labels:
    app.kubernetes.io/name: good-app
spec:
  containers:
    - name: web
      image: ghcr.io/nginxinc/nginx-unprivileged:1.27-alpine
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
YAML

  cat > "$LAB_DIR/pod-bad-registry.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: bad-registry
  namespace: kca-jp-lab
spec:
  containers:
    - name: web
      image: docker.io/library/nginx:1.27
      ports:
        - containerPort: 80
YAML

  cat > "$LAB_DIR/pod-bad-tag.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: bad-tag
  namespace: kca-jp-lab
spec:
  containers:
    - name: web
      image: ghcr.io/nginxinc/nginx-unprivileged:1.27-alpine
      ports:
        - containerPort: 8080
    - name: sidecar
      image: registry.k8s.io/git-sync/git-sync:latest
YAML

  info "lab files ....... $LAB_DIR/{pod-good.yaml,pod-bad-registry.yaml,pod-bad-tag.yaml}"
}

# ------------------------------------------------------------ broken policy --
render_broken_policy() {
  local fa_spec="" fa_rule=""
  if [ "$KYVERNO_MINOR" -ge 13 ]; then
    fa_rule="        failureAction: Enforce"
  else
    fa_spec="  validationFailureAction: Enforce"
  fi

  cat <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY}
  annotations:
    policies.kyverno.io/title: "KCA 3.3 jp lab - SEEDED FAULTS, DO NOT COPY TO PRODUCTION"
    policies.kyverno.io/subject: "Pod"
spec:
  background: false
${fa_spec}
  rules:
    - name: approved-registry
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS}
      validate:
${fa_rule}
        message: >-
          Container images must come from ghcr.io or registry.k8s.io.
          Images in this Pod: {{ request.object.spec.containers[*].image | join(', ', @) }}
        deny:
          conditions:
            all:
              - key: "{{ request.object.spec.containers[?regex_match(image, '^(ghcr[.]io|registry[.]k8s[.]io)/')] | length(@) }}"
                operator: LessThan
                value: "{{ request.object.spec.containers | length(@) }}"
    - name: disallow-latest-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS}
      validate:
${fa_rule}
        message: >-
          The ':latest' tag is not allowed; pin an immutable tag or a digest.
        deny:
          conditions:
            all:
              - key: '{{ request.object.spec.containers[0].image | split(@, ":") | [-1] }}'
                operator: Equals
                value: latest
EOF
}

apply_broken_policy() {
  say "Seeding the fault"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" kca-lab=3.3-jp --overwrite >/dev/null

  render_broken_policy > "$LAB_DIR/policy-broken.yaml"
  kubectl apply -f "$LAB_DIR/policy-broken.yaml" >/dev/null \
    || die "the API server rejected the policy itself — read the error above, that is already a finding"
  kubectl wait --for=condition=Ready "clusterpolicy/$POLICY" --timeout=60s >/dev/null 2>&1 || true
  info "policy .......... clusterpolicy/$POLICY (source kept at $LAB_DIR/policy-broken.yaml)"
}

# ---------------------------------------------------------------- probing ----
probe() { # $1 = manifest path; returns 0 when the Pod is ADMITTED
  local rc=0
  PROBE_OUT="$(kubectl -n "$NS" apply --dry-run=server -f "$1" 2>&1)" || rc=$?
  return "$rc"
}

wait_for_symptom() {
  local i
  for i in $(seq 1 30); do
    if ! probe "$LAB_DIR/pod-good.yaml"; then return 0; fi
    sleep 2
  done
  warn "the webhook never reacted; check 'kubectl -n $KYVERNO_NS logs deploy -l app.kubernetes.io/component=admission-controller'"
  return 1
}

show_symptom() {
  say "Observed symptom (this is what you must make go away)"
  printf '\n    $ kubectl -n %s apply --dry-run=server -f pod-good.yaml\n' "$NS"
  printf '%s\n' "$PROBE_OUT" | sed 's/^/    | /'
}

# ----------------------------------------------------------------- briefing --
print_briefing() {
  local brief="$LAB_DIR/BRIEFING.txt"
  cat > "$brief" <<BRIEF
KCA 3.3 - jp (JMESPath with the Kyverno CLI)          BREAK & FIX BRIEFING
==========================================================================

SCENARIO
  The platform team ships ClusterPolicy/${POLICY}, which enforces two
  supply-chain rules for every Pod in namespace ${NS}:
    R1  every container image must come from ghcr.io or registry.k8s.io
    R2  no container may use the ':latest' tag
  The policy was written straight into the cluster, without ever being
  evaluated offline. It contains THREE JMESPath faults.

SYMPTOM YOU WILL SEE NOW
  1. Every Pod in ${NS} is rejected - including the perfectly compliant
     pod-good.yaml. The admission error names the policy, and one of the
     rules fails with a variable-substitution / JMESPath evaluation error
     rather than a clean policy message.
  2. Once you make compliant Pods pass again, a second, quieter failure is
     waiting for you: a Pod whose SECOND container uses ':latest' is
     admitted without complaint. A validation rule that silently returns
     "no violation" is more dangerous than one that crashes.

YOUR MISSION
  Make all three probes behave, using only fixes inside the JMESPath
  expressions of the policy:
    pod-good.yaml          -> ADMITTED
    pod-bad-registry.yaml  -> DENIED  by rule approved-registry
    pod-bad-tag.yaml       -> DENIED  by rule disallow-latest-tag

OUT OF BOUNDS (these "fix" the symptom and destroy the control)
  - deleting the policy or the rules
  - switching failureAction/validationFailureAction to Audit
  - relaxing the match block, or excluding the test Pods
  - editing the test Pod manifests

TOOLS FOR THIS TOPIC - debug JMESPath OFFLINE, never in the webhook
  kyverno jp function                    # list every built-in + Kyverno function
  kyverno jp function regex_match        # exact signature and argument order
  kyverno jp parse "<expression>"        # print the AST: literal vs field, precedence
  kyverno jp query -i <file.yaml> "<expression>"
  kyverno jp query -i <file.yaml> -q <query-file>

  Rooting hint: inside the policy the expressions are rooted at
  request.object, so 'request.object.spec.containers' in the policy is
  'spec.containers' when you feed a bare Pod manifest to 'jp query -i'.

WORKING FILES        $LAB_DIR
GRADE YOUR FIX       $0 --verify
TEAR DOWN THE LAB    $0 --cleanup
BRIEF
  cat "$brief"
}

# ------------------------------------------------------------------ verify ---
verify() {
  local fails=0 live
  say "Grading"

  if ! kubectl get "clusterpolicy/$POLICY" >/dev/null 2>&1; then
    printf '    [FAIL] clusterpolicy/%s does not exist - deleting the control is not a fix\n' "$POLICY"
    exit 1
  fi

  live="$(kubectl get "clusterpolicy/$POLICY" -o yaml)"

  if printf '%s' "$live" | grep -qiE 'failureAction: *Audit|validationFailureAction: *Audit'; then
    printf '    [FAIL] the policy was downgraded to Audit; it must stay in Enforce\n'; fails=$((fails+1))
  fi
  if [ "$(printf '%s' "$live" | grep -c 'name: approved-registry\|name: disallow-latest-tag')" -lt 2 ]; then
    printf '    [FAIL] one of the two rules is missing\n'; fails=$((fails+1))
  fi
  if ! printf '%s' "$live" | grep -q "namespaces:" ; then
    printf '    [FAIL] the match block no longer pins the lab namespace\n'; fails=$((fails+1))
  fi

  if probe "$LAB_DIR/pod-good.yaml"; then
    printf '    [PASS] compliant Pod is admitted\n'
  else
    printf '    [FAIL] compliant Pod is still rejected:\n%s\n' "$(printf '%s' "$PROBE_OUT" | sed 's/^/           /')"
    fails=$((fails+1))
  fi

  if probe "$LAB_DIR/pod-bad-registry.yaml"; then
    printf '    [FAIL] docker.io image was ADMITTED - rule approved-registry is not catching it\n'
    fails=$((fails+1))
  else
    printf '    [PASS] non-approved registry is denied\n'
  fi

  if probe "$LAB_DIR/pod-bad-tag.yaml"; then
    printf '    [FAIL] ":latest" on the second container was ADMITTED - the expression only inspects containers[0]\n'
    fails=$((fails+1))
  else
    printf '    [PASS] ":latest" is denied even outside the first container\n'
  fi

  if [ "$fails" -eq 0 ]; then
    say "RESULT: PASS - three faults repaired, control intact"
    exit 0
  fi
  say "RESULT: $fails check(s) failing - keep going ('kyverno jp parse' is your friend)"
  exit 1
}

# ----------------------------------------------------------------- cleanup ---
cleanup() {
  say "Removing the lab"
  kubectl delete "clusterpolicy/$POLICY" --ignore-not-found >/dev/null
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null
  rm -rf "$LAB_DIR"
  info "clusterpolicy/$POLICY, namespace/$NS and $LAB_DIR are gone"
  info "Kyverno itself was left installed; remove it with:"
  info "  kubectl delete -f $KYVERNO_MANIFEST"
}

# -------------------------------------------------------------------- main ---
main() {
  parse_args "$@"
  [ "$MODE" = "help" ] && { print_help; exit 0; }

  require_cmd kubectl
  case "$MODE" in
    cleanup) cleanup; exit 0 ;;
    verify)  ensure_kyverno_cli; [ -f "$LAB_DIR/pod-good.yaml" ] || die "lab files missing; run the script without flags first"; verify ;;
  esac

  ensure_kyverno_cli
  guard_context
  ensure_kyverno
  write_lab_files
  apply_broken_policy
  wait_for_symptom || true
  show_symptom
  print_briefing
}

main "$@"

# ============================================================================
#                                 S O L U T I O N
#          (read only after you have burned some time on `kyverno jp`)
# ============================================================================
#
# STEP 0 - Reproduce deterministically, without creating anything
# ---------------------------------------------------------------------------
#   cd ~/kca-3.3-jp-lab
#   kubectl -n kca-jp-lab apply --dry-run=server -f pod-good.yaml
#
#   Expected (abbreviated):
#     Error from server: error when creating "pod-good.yaml": admission webhook
#     "validate.kyverno.svc-fail" denied the request:
#     resource Pod/kca-jp-lab/good-app was blocked due to the following policies
#     kca-jp-lab-image-guard:
#       approved-registry: 'Container images must come from ghcr.io or registry.k8s.io...'
#       disallow-latest-tag: 'failed to evaluate ... variable substitution failed ...'
#
#   Two different failure modes in one request: rule 1 denies a legitimate Pod
#   (a logic fault), rule 2 cannot even be evaluated (a syntax/typing fault).
#
# STEP 1 - Read the expressions that actually run in the cluster
# ---------------------------------------------------------------------------
#   kubectl get clusterpolicy kca-jp-lab-image-guard -o yaml | grep -n 'key:\|value:'
#
#   Never debug these against the live webhook. Copy them into `kyverno jp`,
#   where evaluation is instantaneous, offline, and produces real error text.
#
# STEP 2 - FAULT #1: swapped arguments in regex_match  (rule approved-registry)
# ---------------------------------------------------------------------------
#   The policy says:  regex_match(image, '^(ghcr[.]io|registry[.]k8s[.]io)/')
#   Ask the CLI what the signature really is:
#
#     kyverno jp function regex_match
#
#   Expected (abbreviated):
#     Name: regex_match
#       Signature: regex_match(string, string) bool
#       Note: first string is the regular expression which is compared with
#             second input string
#
#   So the REGEX comes first. Prove the impact offline - `spec.containers` here
#   because `jp query` is fed a bare Pod, while the policy is rooted at
#   `request.object`:
#
#     kyverno jp query -i pod-good.yaml \
#       "spec.containers[?regex_match(image, '^(ghcr[.]io|registry[.]k8s[.]io)/')] | length(@)"
#     # -> 0        (wrong: zero "approved" containers, so 0 < 1 and the Pod is denied)
#
#     kyverno jp query -i pod-good.yaml \
#       "spec.containers[?regex_match('^(ghcr[.]io|registry[.]k8s[.]io)/', image)] | length(@)"
#     # -> 1        (correct)
#
#   Why the bug is silent-but-deadly: 'ghcr.io/nginxinc/...' is itself a VALID
#   regular expression, so the swapped call never errors - it just always
#   returns false. Note also the '[.]' character classes: they mean the same as
#   '\.' but survive YAML, shell and JMESPath raw-string quoting untouched.
#
# STEP 3 - FAULT #2: a quoted identifier where a string literal was meant
# ---------------------------------------------------------------------------
#   The policy says:  split(@, ":")
#   In JMESPath, "..." is a QUOTED IDENTIFIER (a field name); a string literal
#   is '...'. Let the parser show you the difference:
#
#     kyverno jp parse "split(@, \":\")"
#     # ASTFunctionExpression { value: "split"
#     #   children: { ASTCurrentNode {}   ASTField { value: ":" } } }
#
#     kyverno jp parse "split(@, ':')"
#     # ASTFunctionExpression { value: "split"
#     #   children: { ASTCurrentNode {}   ASTLiteral { value: ":" } } }
#
#   ASTField means "look up a key named ':' on the current node". The current
#   node is a string, so the lookup yields null, and split() gets null where it
#   demands a string - hence the evaluation error at admission time:
#
#     kyverno jp query -i pod-bad-tag.yaml "spec.containers[0].image | split(@, \":\")"
#     # Error: ... invalid type for: <nil>, expected: string
#
#     kyverno jp query -i pod-bad-tag.yaml "spec.containers[0].image | split(@, ':')"
#     # [ "ghcr.io/nginxinc/nginx-unprivileged", "1.27-alpine" ]
#
# STEP 4 - FAULT #3: index instead of projection (the silent one)
# ---------------------------------------------------------------------------
#   With the quoting repaired the rule evaluates - and still admits pod-bad-tag,
#   because it only ever inspects containers[0]:
#
#     kyverno jp query -i pod-bad-tag.yaml "spec.containers[0].image"
#     # "ghcr.io/nginxinc/nginx-unprivileged:1.27-alpine"     <- compliant
#
#     kyverno jp query -i pod-bad-tag.yaml "spec.containers[*].image"
#     # [ "ghcr.io/nginxinc/nginx-unprivileged:1.27-alpine",
#     #   "registry.k8s.io/git-sync/git-sync:latest" ]         <- the violator
#
#   Build the counting expression the rule needs, and confirm both directions:
#
#     kyverno jp query -i pod-bad-tag.yaml \
#       "spec.containers[*].image | [?ends_with(@, ':latest')] | length(@)"
#     # -> 1
#     kyverno jp query -i pod-good.yaml \
#       "spec.containers[*].image | [?ends_with(@, ':latest')] | length(@)"
#     # -> 0
#
#   `[0]` is an index expression; `[*]` is a list projection. Anything that must
#   hold for EVERY container has to be written as a projection plus a filter and
#   a count - an index is a policy that inspects one container and blesses the rest.
#
# STEP 5 - Apply the corrected policy
# ---------------------------------------------------------------------------
#   (Kyverno 1.13+ syntax: per-rule `validate.failureAction`. On Kyverno < 1.13
#   delete both `failureAction` lines and put `validationFailureAction: Enforce`
#   directly under `spec:` instead.)
#
#   cat <<'EOF' | kubectl apply -f -
#   apiVersion: kyverno.io/v1
#   kind: ClusterPolicy
#   metadata:
#     name: kca-jp-lab-image-guard
#   spec:
#     background: false
#     rules:
#       - name: approved-registry
#         match:
#           any:
#             - resources:
#                 kinds:
#                   - Pod
#                 namespaces:
#                   - kca-jp-lab
#         validate:
#           failureAction: Enforce
#           message: >-
#             Container images must come from ghcr.io or registry.k8s.io.
#             Images in this Pod: {{ request.object.spec.containers[*].image | join(', ', @) }}
#           deny:
#             conditions:
#               all:
#                 - key: "{{ request.object.spec.containers[?regex_match('^(ghcr[.]io|registry[.]k8s[.]io)/', image)] | length(@) }}"
#                   operator: LessThan
#                   value: "{{ request.object.spec.containers | length(@) }}"
#       - name: disallow-latest-tag
#         match:
#           any:
#             - resources:
#                 kinds:
#                   - Pod
#                 namespaces:
#                   - kca-jp-lab
#         validate:
#           failureAction: Enforce
#           message: >-
#             The ':latest' tag is not allowed; pin an immutable tag or a digest.
#           deny:
#             conditions:
#               all:
#                 - key: "{{ request.object.spec.containers[*].image | [?ends_with(@, ':latest')] | length(@) }}"
#                   operator: GreaterThan
#                   value: 0
#   EOF
#
#   Note on rule 1: when a `value:` (or `key:`) is exactly one variable, Kyverno
#   substitutes the TYPED JSON value, so `length(@)` arrives as an integer and
#   LessThan performs a numeric comparison - not a string one.
#
# STEP 6 - Verify
# ---------------------------------------------------------------------------
#   kubectl -n kca-jp-lab apply --dry-run=server -f pod-good.yaml
#   # pod/good-app created (server dry run)
#
#   kubectl -n kca-jp-lab apply --dry-run=server -f pod-bad-registry.yaml
#   # ... denied the request: ... approved-registry: 'Container images must come
#   #     from ghcr.io or registry.k8s.io. Images in this Pod: docker.io/library/nginx:1.27'
#
#   kubectl -n kca-jp-lab apply --dry-run=server -f pod-bad-tag.yaml
#   # ... denied the request: ... disallow-latest-tag: 'The ':latest' tag is not allowed...'
#
#   ./kca-3.3-jp-break-fix.sh --verify      # -> RESULT: PASS
#
# PRODUCTION NOTES - what this lab policy still gets wrong on purpose
# ---------------------------------------------------------------------------
#   * It inspects `spec.containers` only. A real control must also cover
#     `spec.initContainers` and `spec.ephemeralContainers`; a debug container
#     injected with `kubectl debug` is an unvalidated image otherwise.
#   * `ends_with(@, ':latest')` misses the implicit case: `nginx` with no tag
#     resolves to `:latest` at pull time. Prefer Kyverno's pre-parsed image
#     context, which normalises registry/path/tag/digest for you:
#         {{ images.containers.*.tag }}       <- object projection with `.*`,
#                                                NOT `[*]`: containers is a map
#                                                keyed by container name.
#     See https://kyverno.io/docs/writing-policies/variables/
#   * Enforcing a digest (`images.containers.*.digest`) is strictly stronger
#     than banning one tag name.
#   * Matching only Pods leaves the parent controllers reporting success while
#     their Pods are refused; match the workload kinds too, or run the rule in
#     Audit first and read the PolicyReports.
#   * `failurePolicy: Fail` (Kyverno's default) means a broken expression turns
#     into an outage for everything the policy matches. That is exactly why this
#     lab pinned `namespaces: [kca-jp-lab]` - scope first, then widen.
#   * The whole point of domain 3.3: every expression above was debuggable with
#     `kyverno jp` in milliseconds, offline. Put those queries in a `kyverno test`
#     suite in CI so a swapped argument never reaches a webhook again.
# ============================================================================