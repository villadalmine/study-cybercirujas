#!/usr/bin/env bash
#
# =============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 5 · Topic 5.6 — VerifyImage Rules            (exam weight: 2.91 %)
#  Lab format: BREAK & FIX — destructive. Disposable lab cluster ONLY.
# =============================================================================
#
#  WHAT THIS SCRIPT DOES
#    1. Builds a known-good supply-chain admission gate based on a Kyverno
#       `verifyImages` rule and PROVES it works before touching anything.
#    2. Injects THREE independent, controlled defects into that gate.
#    3. Prints the symptoms you will observe and the objective you must reach.
#    4. Grades you: `$0 check` runs behavioural assertions, not text matching.
#    The full step-by-step solution lives at the bottom of this file, commented.
#
#  WHY THE FAULTS CASCADE (this is the pedagogical point)
#    Defect #1 masks defects #2 and #3. A gate that is not enforcing looks
#    "healthy" in `kubectl get pods` — every workload runs. The moment you turn
#    enforcement on, the two hidden misconfigurations surface at once and the
#    namespace stops accepting workloads. That sequence — silent control, then
#    self-inflicted outage on enablement — is the single most common way image
#    verification is rolled out badly in production.
#
#  SAFETY MODEL (read this before running)
#    * Everything lives in ONE disposable namespace plus ONE ClusterPolicy whose
#      `match` block is pinned to that namespace. That pin is what makes the
#      deliberately over-broad `imageReferences: "*"` fault safe: it cannot
#      block kube-system, Kyverno's own controllers, or any other workload.
#      In a real cluster the same fault deadlocks the control plane, because
#      Kyverno ends up trying to verify the images of the very pods that must
#      run for verification to work.
#    * The script refuses to run unless the current kube-context looks like a
#      throwaway lab (kind-*, k3d-*, minikube, *lab*, *test*) or you export
#      KCA_LAB_CONFIRM=yes.
#    * Nothing outside $NS, the lab ClusterPolicy and $LAB_DIR is created,
#      patched or deleted. The Kyverno installation itself is never modified.
#    * Network requirement: the Kyverno admission controller needs egress to
#      ghcr.io, and the nodes need registry.k8s.io. Signature verification is a
#      registry operation performed by the admission controller, not by kubectl.
#
#  SOURCES
#    * KCA curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    * Verify images:  https://kyverno.io/docs/writing-policies/verify-images/
#    * Policy reports: https://kyverno.io/docs/policy-reports/
#    * Installation:   https://kyverno.io/docs/installation/
#    * cosign verify:  https://docs.sigstore.dev/cosign/verifying/verify/
#    The signed/unsigned test images and the public key below are the ones
#    published by the Kyverno project for exactly this purpose.
#
#  USAGE
#    $0 break      # baseline + inject faults + briefing   (default)
#    $0 baseline   # build the known-good gate only, no faults
#    $0 check      # grade the current state (self-assessment)
#    $0 hint [1-4] # progressive hints, no spoilers
#    $0 cleanup    # remove every object this lab created
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------- 
# Configuration
# -----------------------------------------------------------------------------
NS="${KCA_LAB_NS:-kca-56-verifyimages}"
POLICY="kca-56-verify-image-signatures"
LAB_DIR="${KCA_LAB_DIR:-$HOME/.kca-labs/5.6}"

SIGNED_IMAGE="ghcr.io/kyverno/test-verify-image:signed"
UNSIGNED_IMAGE="ghcr.io/kyverno/test-verify-image:unsigned"
# Neutral, unrelated workload. registry.k8s.io/pause is used instead of a
# Docker Hub image on purpose: no anonymous pull-rate limits in a lab.
NEUTRAL_IMAGE="registry.k8s.io/pause:3.9"

PROTECTED_GLOB="ghcr.io/kyverno/test-verify-image*"
BROKEN_GLOB="*"

KYVERNO_NS=""
KYVERNO_DEPLOY=""
KYVERNO_IMAGE=""
FEAT_RULE_ACTION="no"
FEAT_SPEC_ACTION="no"

TMPDIR_LAB="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LAB"' EXIT

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

hr()      { printf '%s\n' "-------------------------------------------------------------------------------"; }
section() { printf '\n%s\n%s%s%s\n%s\n' "$(hr)" "$C_BLD" "$1" "$C_RST" "$(hr)"; }
log()     { printf '%s[ .. ]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()      { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()     { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*"; }
die()     { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
guard_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "no current kube-context; point KUBECONFIG at your lab cluster"
  log "kube-context: ${C_BLD}${ctx}${C_RST}"
  case "$ctx" in
    kind-*|k3d-*|minikube|*lab*|*test*|*sandbox*|*dev*) return 0 ;;
  esac
  if [[ "${KCA_LAB_CONFIRM:-no}" == "yes" ]]; then
    warn "context does not look like a lab, but KCA_LAB_CONFIRM=yes was set"
    return 0
  fi
  cat <<EOF

${C_RED}${C_BLD}REFUSING TO RUN.${C_RST}
Context "${ctx}" does not look like a disposable lab cluster.
This script deliberately misconfigures an admission webhook. Run it against a
kind/k3d/minikube cluster you can throw away. If this really is a lab cluster:

    KCA_LAB_CONFIRM=yes $0 ${1:-break}

EOF
  exit 1
}

detect_kyverno() {
  kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 || cat <<EOF && true
EOF
  if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
    cat <<EOF

${C_RED}Kyverno is not installed in this cluster.${C_RST}
Install it (docs: https://kyverno.io/docs/installation/) and re-run:

    kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
    kubectl -n kyverno rollout status deploy --timeout=180s

EOF
    exit 1
  fi

  KYVERNO_NS="$(kubectl get deploy -A -l app.kubernetes.io/part-of=kyverno \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [[ -n "$KYVERNO_NS" ]] || KYVERNO_NS="$(kubectl get deploy -A -l app.kubernetes.io/name=kyverno \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [[ -n "$KYVERNO_NS" ]] || KYVERNO_NS="kyverno"

  # 1.10+ splits the controllers; older releases ship a single "kyverno" deploy.
  KYVERNO_DEPLOY="$(kubectl -n "$KYVERNO_NS" get deploy -o name 2>/dev/null \
      | grep -E 'admission-controller|/kyverno$' | head -1 || true)"
  [[ -n "$KYVERNO_DEPLOY" ]] || die "found the Kyverno CRDs but no Kyverno deployment in ns/$KYVERNO_NS"

  KYVERNO_IMAGE="$(kubectl -n "$KYVERNO_NS" get "$KYVERNO_DEPLOY" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)"

  log "kyverno: ${KYVERNO_DEPLOY} in ns/${KYVERNO_NS}"
  log "image:   ${KYVERNO_IMAGE}"
  kubectl -n "$KYVERNO_NS" rollout status "$KYVERNO_DEPLOY" --timeout=180s >/dev/null \
    || die "the Kyverno admission controller is not Available; fix that first"
  ok "Kyverno admission controller is Available"
}

# The exam does not tell you which Kyverno version you are on, and the field
# that carries the enforcement action MOVED: <=1.12 uses spec.validationFailureAction,
# 1.13+ moved it next to the rule. Never assume — interrogate the CRD schema.
# Same idea as `kubectl explain clusterpolicy.spec.rules.verifyImages`.
crd_probe() {
  local path="$1" jp out
  jp="$(printf '{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.%s}' "$path")"
  out="$(kubectl get crd clusterpolicies.kyverno.io -o jsonpath="$jp" 2>/dev/null || true)"
  [[ -n "$out" ]]
}

detect_features() {
  if crd_probe 'properties.rules.items.properties.verifyImages.items.properties.failureAction'; then
    FEAT_RULE_ACTION="yes"
  fi
  if crd_probe 'properties.validationFailureAction'; then
    FEAT_SPEC_ACTION="yes"
  fi
  [[ "$FEAT_RULE_ACTION" == "yes" || "$FEAT_SPEC_ACTION" == "yes" ]] \
    || die "this ClusterPolicy CRD exposes neither verifyImages[].failureAction nor spec.validationFailureAction"
  log "enforcement field: rule-level=${FEAT_RULE_ACTION} spec-level=${FEAT_SPEC_ACTION}"
}

preflight() {
  need kubectl
  need openssl
  need sed
  kubectl version -o json >/dev/null 2>&1 || die "cannot reach the API server"
  guard_context "${1:-break}"
  detect_kyverno
  detect_features
  command -v cosign >/dev/null 2>&1 \
    && ok "cosign found — you can verify the images outside the cluster" \
    || warn "cosign not installed (optional, but it is the fastest way to establish ground truth)"
}

# -----------------------------------------------------------------------------
# Key material
# -----------------------------------------------------------------------------
write_keys() {
  mkdir -p "$LAB_DIR"

  # The genuine cosign public key published by the Kyverno project for
  # ghcr.io/kyverno/test-verify-image:signed.
  # https://kyverno.io/docs/writing-policies/verify-images/
  cat > "$LAB_DIR/cosign.pub" <<'PEM'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8nXRh950IZbRj8Ra/N9sbqOPZrfM
5/KAQN0/KjHcorm/J5yctVd7iEcnessRQjU917hmKO6JWVGHpDguIyakZA==
-----END PUBLIC KEY-----
PEM

  # The decoy: a *syntactically valid* P-256 key that simply is not the one the
  # image was signed with. Generated locally so the failure is a real signature
  # mismatch ("no matching signatures"), not a PEM parse error — those two look
  # nothing alike in the controller logs and you must learn to tell them apart.
  if [[ ! -s "$LAB_DIR/decoy.pub" ]]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$LAB_DIR/decoy.key" 2>/dev/null
    openssl ec -in "$LAB_DIR/decoy.key" -pubout -out "$LAB_DIR/decoy.pub" 2>/dev/null
    chmod 600 "$LAB_DIR/decoy.key"
  fi
  ok "key material in $LAB_DIR (cosign.pub = genuine, decoy.pub = generated)"
}

# -----------------------------------------------------------------------------
# Policy rendering
# -----------------------------------------------------------------------------
render_policy() {
  # $1 = good|broken   $2 = with_rekor (yes|no)
  local mode="$1" with_rekor="$2"
  local action glob keyfile spec_action rule_action pem rekor_block

  if [[ "$mode" == "good" ]]; then
    action="Enforce"; glob="$PROTECTED_GLOB"; keyfile="$LAB_DIR/cosign.pub"
  else
    action="Audit";   glob="$BROKEN_GLOB";    keyfile="$LAB_DIR/decoy.pub"
  fi

  spec_action=""; rule_action=""
  if [[ "$FEAT_RULE_ACTION" == "yes" ]]; then
    rule_action="          failureAction: ${action}"
  else
    spec_action="  validationFailureAction: ${action}"
  fi

  pem="$(sed 's/^/                      /' "$keyfile")"

  rekor_block=""
  if [[ "$with_rekor" == "yes" ]]; then
    # The test image is signed with a key and its signature is not required to
    # be in the transparency log; asking Kyverno to ignore the tlog makes the
    # lab deterministic and offline-friendly. In production you normally do the
    # opposite: keep tlog verification on.
    rekor_block=$'                    rekor:\n                      ignoreTlog: true'
  fi

  cat <<YAML
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY}
  labels:
    kca-lab: "5.6"
  annotations:
    policies.kyverno.io/title: Verify image signatures (KCA 5.6 lab)
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
spec:
${spec_action}
  background: false
  failurePolicy: Fail
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-protected-repository
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS}
      verifyImages:
        - imageReferences:
            - "${glob}"
${rule_action}
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
${pem}
${rekor_block}
YAML
}

apply_policy() {
  # Tries the richest form first and degrades if the installed CRD is older.
  local mode="$1" rekor f
  f="$TMPDIR_LAB/policy.yaml"
  for rekor in yes no; do
    render_policy "$mode" "$rekor" > "$f"
    if kubectl apply --dry-run=server -f "$f" >/dev/null 2>"$TMPDIR_LAB/apply.err"; then
      kubectl apply -f "$f" >/dev/null
      cp "$f" "$LAB_DIR/policy-${mode}.yaml"
      log "applied ${mode} policy (rekor block: ${rekor})"
      return 0
    fi
  done
  err "could not apply the ${mode} policy:"
  sed 's/^/       /' "$TMPDIR_LAB/apply.err" >&2
  exit 1
}

wait_policy_ready() {
  kubectl wait --for=condition=Ready "clusterpolicy/$POLICY" --timeout=60s >/dev/null 2>&1 || sleep 5
}

# Admission webhook configurations are reconciled asynchronously after a policy
# change. Never assert immediately after `kubectl apply` — poll for the effect.
wait_for_gate() {
  # $1 = reject|admit  (expected outcome for the UNSIGNED image)
  local want="$1" i rc
  for i in $(seq 1 18); do
    rc=0
    kubectl -n "$NS" run "gate-probe-$i" --image="$UNSIGNED_IMAGE" \
      --restart=Never --dry-run=server -o name >/dev/null 2>&1 || rc=$?
    if [[ "$want" == "reject" && $rc -ne 0 ]]; then return 0; fi
    if [[ "$want" == "admit"  && $rc -eq 0 ]]; then return 0; fi
    sleep 5
  done
  return 1
}

# -----------------------------------------------------------------------------
# Workloads
# -----------------------------------------------------------------------------
ensure_ns() {
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null
  kubectl label ns "$NS" kca-lab=5.6 --overwrite >/dev/null
}

create_pod() {
  # $1 = name, $2 = image ; stdout+stderr of the API call go to $TMPDIR_LAB/last.out
  local name="$1" image="$2"
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait >/dev/null 2>&1 || true
  cat <<YAML | kubectl apply -f - >"$TMPDIR_LAB/last.out" 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    app: ${name}
    kca-lab: "5.6"
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: ${image}
YAML
}

create_neutral_deploy() {
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unrelated-app
  namespace: ${NS}
  labels:
    kca-lab: "5.6"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unrelated-app
  template:
    metadata:
      labels:
        app: unrelated-app
        kca-lab: "5.6"
    spec:
      containers:
        - name: app
          image: ${NEUTRAL_IMAGE}
YAML
}

recycle_neutral_pods() {
  # Admission control only runs at admission time: already-running pods survive
  # any policy change. Deleting them is what re-tests the gate.
  kubectl -n "$NS" delete pod -l app=unrelated-app --ignore-not-found --wait >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 12); do
    [[ "$(kubectl -n "$NS" get pod -l app=unrelated-app -o name 2>/dev/null | wc -l)" -ge 1 ]] && return 0
    sleep 5
  done
  return 1
}

pod_image() {
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Phase 1 — baseline (prove the gate works before breaking it)
# -----------------------------------------------------------------------------
baseline() {
  section "PHASE 1 — building and PROVING the known-good gate"
  write_keys
  ensure_ns
  apply_policy good
  wait_policy_ready

  log "waiting for the admission webhook to take effect ..."
  wait_for_gate reject || die "the gate never became effective — check: kubectl -n $KYVERNO_NS logs $KYVERNO_DEPLOY"
  ok "gate is live and enforcing"

  log "T1 signed image must be ADMITTED and rewritten to a digest"
  create_pod signed-app "$SIGNED_IMAGE" \
    || { sed 's/^/       /' "$TMPDIR_LAB/last.out"; die "baseline broken: the signed image was rejected (no egress to ghcr.io from the Kyverno controller?)"; }
  local img; img="$(pod_image signed-app)"
  [[ "$img" == *"@sha256:"* ]] \
    || die "baseline broken: mutateDigest did not rewrite the tag (image=$img)"
  ok "signed-app admitted as: $img"

  log "T2 unsigned image must be REJECTED"
  if create_pod unsigned-app "$UNSIGNED_IMAGE"; then
    die "baseline broken: the unsigned image was admitted"
  fi
  ok "unsigned-app rejected at admission"

  log "T3 unrelated workload must be UNAFFECTED"
  create_neutral_deploy
  recycle_neutral_pods || die "baseline broken: the neutral deployment could not create a pod"
  ok "unrelated-app pods are being created normally"

  kubectl -n "$NS" delete pod signed-app --ignore-not-found --wait >/dev/null 2>&1 || true
  section "BASELINE GREEN — the gate is correct. Now it gets broken."
}

# -----------------------------------------------------------------------------
# Phase 2 — the break
# -----------------------------------------------------------------------------
break_it() {
  section "PHASE 2 — injecting three controlled defects"
  apply_policy broken
  wait_policy_ready
  log "waiting for the (now degraded) webhook to settle ..."
  wait_for_gate admit || warn "the unsigned image is still being rejected; give it a few more seconds"

  create_pod signed-app   "$SIGNED_IMAGE"   || true
  create_pod unsigned-app "$UNSIGNED_IMAGE" || true
  recycle_neutral_pods >/dev/null 2>&1 || true
  ok "defects applied and workloads re-admitted through the degraded gate"

  section "OBSERVED STATE"
  kubectl -n "$NS" get pods -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase' || true
  printf '\n'
  kubectl -n "$NS" get policyreport 2>/dev/null || kubectl -n "$NS" get polr 2>/dev/null || warn "no PolicyReport objects yet"
}

# -----------------------------------------------------------------------------
# Briefing
# -----------------------------------------------------------------------------
briefing() {
  cat <<EOF

$(hr)
${C_BLD}INCIDENT BRIEFING — KCA 5.6 VerifyImage Rules${C_RST}
$(hr)

The cluster runs a supply-chain admission gate: ClusterPolicy/${POLICY}, a
\`verifyImages\` rule that is supposed to allow ONLY cosign-signed images from
the protected repository ghcr.io/kyverno/test-verify-image into namespace
${NS}, rewriting each verified tag to an immutable digest.

Three independent defects were introduced. THEY CASCADE: the first one hides
the other two, and fixing it will make the namespace look far worse before it
looks better. That is expected. Work through them in order.

${C_BLD}SYMPTOMS YOU CAN SEE RIGHT NOW${C_RST}

  S1  ${C_RED}The control is not blocking anything.${C_RST}
      Pod/unsigned-app exists and was accepted by the API server, even though
      ${UNSIGNED_IMAGE}
      carries no signature at all. A gate that admits an unsigned image is not
      a gate — it is a logging facility.

  S2  ${C_RED}The protected image is not being verified either.${C_RST}
      Look at Pod/signed-app: its \`.spec.containers[0].image\` still ends in
      the tag ":signed". In a healthy state Kyverno rewrites it to
      "...@sha256:<digest>". No digest rewrite means verification did NOT
      succeed for that image — it was merely tolerated.

  S3  ${C_RED}The gate is inspecting images it has no business inspecting.${C_RST}
      The PolicyReport in ${NS} contains failing results for
      ${NEUTRAL_IMAGE}, an image that belongs to a completely
      unrelated workload and to no protected repository.

${C_BLD}WHAT YOU MUST ACHIEVE${C_RST}

  G1  Pod ${SIGNED_IMAGE}
      is ADMITTED, and its container image is rewritten to an @sha256 digest.
  G2  Pod ${UNSIGNED_IMAGE}
      is REJECTED at admission with an explicit signature failure.
  G3  Deployment/unrelated-app (${NEUTRAL_IMAGE}) creates pods normally,
      including pods created AFTER your fix.
  G4  ClusterPolicy/${POLICY} still exists, still enforces, and still verifies
      the whole protected repository with a keyed attestor.

${C_BLD}RULES${C_RST}
  Allowed:   editing the ClusterPolicy, re-applying it, deleting/recreating
             workloads, reading Kyverno logs and reports, using cosign.
  Forbidden: deleting or disabling the policy, dropping it to Audit, uninstalling
             Kyverno, adding ${NS} to Kyverno's resourceFilters ConfigMap, or
             editing the ValidatingWebhookConfiguration/MutatingWebhookConfiguration
             by hand. \`$0 check\` detects all of these.

${C_BLD}A FACT YOU WILL NEED${C_RST}
  Admission control runs at admission time only. Changing a policy never
  re-evaluates pods that are already running. After every change, delete and
  recreate the test workloads — otherwise you are grading yesterday's decision.

${C_BLD}USEFUL COMMANDS${C_RST}
  kubectl get cpol ${POLICY} -o yaml
  kubectl explain clusterpolicy.spec.rules.verifyImages --recursive | head -50
  kubectl -n ${NS} get polr -o wide
  kubectl -n ${NS} describe polr
  kubectl -n ${NS} get pod signed-app -o jsonpath='{.spec.containers[0].image}'; echo
  kubectl -n ${NS} run probe --image=${SIGNED_IMAGE} --restart=Never --dry-run=server -o yaml
  kubectl -n ${KYVERNO_NS} logs ${KYVERNO_DEPLOY} --tail=200 | grep -iE 'verify|signature|cosign'
  cosign verify --key ${LAB_DIR}/cosign.pub ${SIGNED_IMAGE} --insecure-ignore-tlog=true

  ${C_BLD}\`--dry-run=server\`${C_RST} is your fastest feedback loop: it runs the full
  admission chain (so Kyverno really verifies the signature) without persisting
  a pod, and it shows you the MUTATED object, digest included.

${C_BLD}LAB CONTROLS${C_RST}
  $0 check        grade yourself
  $0 hint 1..4    progressive hints
  $0 cleanup      remove everything this lab created

$(hr)
EOF
}

# -----------------------------------------------------------------------------
# Grader
# -----------------------------------------------------------------------------
current_action() {
  local a
  a="$(kubectl get cpol "$POLICY" -o jsonpath='{.spec.rules[0].verifyImages[0].failureAction}' 2>/dev/null || true)"
  [[ -n "$a" ]] || a="$(kubectl get cpol "$POLICY" -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)"
  printf '%s' "$a"
}

check() {
  section "GRADING — KCA 5.6 VerifyImage Rules"
  local pass=0 fail=0
  _p() { ok "$1"; pass=$((pass+1)); }
  _f() { err "$1"; fail=$((fail+1)); }

  # C1 — the policy still exists and still enforces
  if kubectl get cpol "$POLICY" >/dev/null 2>&1; then
    local action; action="$(current_action)"
    if [[ "$action" == "Enforce" ]]; then
      _p "C1 policy exists and the action is Enforce"
    else
      _f "C1 policy action is '${action:-<unset>}', expected Enforce"
    fi
  else
    _f "C1 ClusterPolicy/$POLICY does not exist (deleting it is not a fix)"
  fi

  # C2 — structural integrity: keyed attestor, no bare wildcard
  local refs keys
  refs="$(kubectl get cpol "$POLICY" -o jsonpath='{.spec.rules[0].verifyImages[0].imageReferences[*]}' 2>/dev/null || true)"
  keys="$(kubectl get cpol "$POLICY" -o jsonpath='{.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys}' 2>/dev/null || true)"
  if [[ "$refs" == *"*"* && "$refs" != "*" && "$refs" == *"test-verify-image"* && -n "$keys" ]]; then
    _p "C2 rule scoped to the protected repository with a keyed attestor (imageReferences: $refs)"
  else
    _f "C2 imageReferences='${refs:-<none>}' / keyed attestor present=$([[ -n "$keys" ]] && echo yes || echo no)"
  fi

  # C3 — anti-cheat: the namespace must not be filtered out of Kyverno
  local filters
  filters="$(kubectl -n "$KYVERNO_NS" get cm kyverno -o jsonpath='{.data.resourceFilters}' 2>/dev/null || true)"
  if [[ -n "$filters" && "$filters" == *"$NS"* ]]; then
    _f "C3 namespace $NS was excluded via Kyverno resourceFilters — that bypasses the gate, it does not fix it"
  else
    _p "C3 no resourceFilters bypass detected"
  fi

  # C4 — behaviour: signed image admitted AND digest-mutated
  if create_pod signed-app "$SIGNED_IMAGE"; then
    local img; img="$(pod_image signed-app)"
    if [[ "$img" == *"@sha256:"* ]]; then
      _p "C4 signed image admitted and mutated to a digest: $img"
    else
      _f "C4 signed image admitted but NOT digest-mutated (image=$img) — verification did not actually succeed"
    fi
  else
    _f "C4 signed image was rejected:"
    sed 's/^/       /' "$TMPDIR_LAB/last.out"
  fi

  # C5 — behaviour: unsigned image rejected
  if create_pod unsigned-app "$UNSIGNED_IMAGE"; then
    _f "C5 unsigned image was ADMITTED — the gate is not closed"
  else
    _p "C5 unsigned image rejected at admission"
  fi

  # C6 — behaviour: no collateral damage
  create_neutral_deploy
  if recycle_neutral_pods; then
    _p "C6 unrelated workload can still create pods"
  else
    _f "C6 unrelated workload cannot create pods — the rule's blast radius is too wide"
    kubectl -n "$NS" describe rs -l app=unrelated-app 2>/dev/null | grep -A3 -i 'events' | sed 's/^/       /' || true
  fi

  printf '\n'
  if [[ $fail -eq 0 ]]; then
    printf '%sRESULT: %d/%d — lab solved.%s\n\n' "$C_GRN$C_BLD" "$pass" "$((pass+fail))" "$C_RST"
    return 0
  fi
  printf '%sRESULT: %d passed, %d failed. Keep going — try `%s hint 1`.%s\n\n' \
    "$C_YEL$C_BLD" "$pass" "$fail" "$0" "$C_RST"
  return 1
}

# -----------------------------------------------------------------------------
# Hints
# -----------------------------------------------------------------------------
hints() {
  case "${1:-1}" in
    1) cat <<'EOF'
HINT 1 — Ask the right first question.
An admission control that never says "no" is either not matching your resources
or not configured to block. Dump the policy and find the single field that
decides whether a failed verifyImages check REJECTS the request or merely
records it in a report. Remember that this field lives in a different place
depending on the Kyverno version; `kubectl explain` will tell you where.
EOF
    ;;
    2) cat <<'EOF'
HINT 2 — Expect the situation to get worse, and read that as progress.
Once the rule actually blocks, re-create the workloads. If EVERY pod in the
namespace is now denied — including one whose image has nothing to do with the
protected repository — then the rule is being applied to images it should never
have matched. Look at the list that selects which images a verifyImages rule
applies to. `"*"` is a legal value and it means literally every image.
EOF
    ;;
    3) cat <<'EOF'
HINT 3 — Separate "the signature is bad" from "the key is wrong".
When only the protected image is still denied, stop trusting the cluster and
establish ground truth outside it:

    cosign verify --key ~/.kca-labs/5.6/cosign.pub \
        ghcr.io/kyverno/test-verify-image:signed --insecure-ignore-tlog=true

If that passes locally but the cluster still reports "no matching signatures",
the material the policy is verifying against is not the material that signed
the image. Compare the key embedded in the policy with the one you just used:

    kubectl get cpol kca-56-verify-image-signatures \
      -o jsonpath='{.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys}'
EOF
    ;;
    4) cat <<'EOF'
HINT 4 — Prove the fix the way the grader does.
Success is not "no error on apply". Success is:
  * the signed pod's .spec.containers[0].image ends in @sha256:<digest>
    (mutateDigest only rewrites the tag AFTER verification succeeds, so the
     digest is your receipt that the signature was actually checked);
  * the unsigned pod is rejected by the mutating webhook;
  * a NEWLY created pod of the unrelated deployment is admitted.
Delete and recreate all three before you judge anything — policy changes never
re-evaluate running pods.
EOF
    ;;
    *) echo "hints available: 1 2 3 4" ;;
  esac
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
cleanup() {
  section "CLEANUP"
  kubectl delete cpol "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  ok "removed ClusterPolicy/$POLICY, namespace/$NS and $LAB_DIR"
  ok "the Kyverno installation itself was never touched"
}

usage() {
  sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
  printf '\nUsage: %s [break|baseline|check|hint N|cleanup]\n' "$0"
}

# -----------------------------------------------------------------------------
main() {
  case "${1:-break}" in
    break)    preflight break;    baseline; break_it; briefing ;;
    baseline) preflight baseline; baseline ;;
    check)    preflight check;    ensure_ns; check ;;
    hint)     hints "${2:-1}" ;;
    cleanup)  need kubectl; guard_context cleanup; detect_kyverno >/dev/null 2>&1 || true; cleanup ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"

# =============================================================================
#  S O L U T I O N   —   do not read until you have tried
# =============================================================================
#
#  THE THREE DEFECTS
#
#    D1  Enforcement action set to Audit
#        (spec.validationFailureAction, or verifyImages[].failureAction on
#        Kyverno 1.13+). Every verification still runs and still fails, but the
#        result is only written to a PolicyReport. Nothing is blocked, and —
#        the detail most people miss — nothing is MUTATED either: a failed
#        verification produces no digest rewrite, which is why signed-app kept
#        its ":signed" tag. That missing digest is the fingerprint of D1+D3.
#
#    D2  imageReferences: "*"
#        The rule was scoped to every image in the namespace instead of to the
#        protected repository. In Audit this is invisible except as junk in the
#        reports; in Enforce it denies every pod whose image is not signed by
#        the configured key — which, for a cluster-wide policy, includes
#        registry.k8s.io/pause, CNI, CoreDNS and Kyverno's own images. That is
#        how image verification takes a production cluster down, and why the
#        `match` block in this lab is pinned to a single namespace.
#
#    D3  Wrong public key
#        A syntactically valid P-256 key that never signed anything. cosign
#        reports "no matching signatures" — an authentication failure, NOT a
#        parse failure. Learn both messages: a malformed PEM fails earlier and
#        differently ("failed to load public key" / "invalid public key").
#
#  STEP-BY-STEP FIX
#
#  0) Establish ground truth OUTSIDE the cluster first. If the image itself is
#     unverifiable, no policy edit will help:
#
#       cosign verify --key ~/.kca-labs/5.6/cosign.pub \
#         ghcr.io/kyverno/test-verify-image:signed --insecure-ignore-tlog=true
#       # => "Verified OK"
#       cosign verify --key ~/.kca-labs/5.6/cosign.pub \
#         ghcr.io/kyverno/test-verify-image:unsigned --insecure-ignore-tlog=true
#       # => error: no signatures found   (this is the expected failure)
#
#  1) Read the policy and locate the enforcement field for THIS Kyverno version:
#
#       kubectl get cpol kca-56-verify-image-signatures -o yaml
#       kubectl explain clusterpolicy.spec.rules.verifyImages --recursive | head -50
#       kubectl explain clusterpolicy.spec.validationFailureAction
#
#     <=1.12:  spec.validationFailureAction: Audit|Enforce
#     1.13+ :  spec.rules[].verifyImages[].failureAction (spec-level deprecated)
#
#  2) Fix D1 — turn the gate on:
#
#       kubectl patch cpol kca-56-verify-image-signatures --type=merge \
#         -p '{"spec":{"validationFailureAction":"Enforce"}}'
#       # or, on 1.13+:
#       kubectl patch cpol kca-56-verify-image-signatures --type=json \
#         -p '[{"op":"replace","path":"/spec/rules/0/verifyImages/0/failureAction","value":"Enforce"}]'
#
#     Re-create the workloads — running pods are not re-evaluated:
#
#       kubectl -n kca-56-verifyimages delete pod --all
#       kubectl -n kca-56-verifyimages rollout restart deploy/unrelated-app
#
#     Expected NEW symptom (this is progress, not a regression): every pod is
#     now denied, including unrelated-app. The evidence lives on the ReplicaSet,
#     not on the Deployment — a classic diagnostic trap:
#
#       kubectl -n kca-56-verifyimages get deploy,rs,pod
#       kubectl -n kca-56-verifyimages describe rs -l app=unrelated-app
#       # Events: FailedCreate ... admission webhook "mutate.kyverno.svc-fail"
#       #         denied the request: ... failed to verify image
#       #         registry.k8s.io/pause:3.9 ... no matching signatures
#
#  3) Fix D2 — restore the blast radius to the protected repository only:
#
#       kubectl patch cpol kca-56-verify-image-signatures --type=json -p \
#         '[{"op":"replace","path":"/spec/rules/0/verifyImages/0/imageReferences/0",
#            "value":"ghcr.io/kyverno/test-verify-image*"}]'
#
#       kubectl -n kca-56-verifyimages rollout restart deploy/unrelated-app
#       # unrelated-app pods are created again; the unsigned image is now denied;
#       # the signed image is STILL denied -> one defect left.
#
#  4) Fix D3 — replace the attestor key. Do NOT hand-patch a PEM into a live
#     object; re-apply the whole manifest, the way you would from Git:
#
#       cat <<'EOF' | kubectl apply -f -
#       apiVersion: kyverno.io/v1
#       kind: ClusterPolicy
#       metadata:
#         name: kca-56-verify-image-signatures
#       spec:
#         validationFailureAction: Enforce     # 1.13+: move to the rule as failureAction
#         background: false
#         failurePolicy: Fail
#         webhookTimeoutSeconds: 30
#         rules:
#           - name: verify-protected-repository
#             match:
#               any:
#                 - resources:
#                     kinds:
#                       - Pod
#                     namespaces:
#                       - kca-56-verifyimages
#             verifyImages:
#               - imageReferences:
#                   - "ghcr.io/kyverno/test-verify-image*"
#                 mutateDigest: true
#                 verifyDigest: true
#                 required: true
#                 attestors:
#                   - count: 1
#                     entries:
#                       - keys:
#                           publicKeys: |-
#                             -----BEGIN PUBLIC KEY-----
#                             MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8nXRh950IZbRj8Ra/N9sbqOPZrfM
#                             5/KAQN0/KjHcorm/J5yctVd7iEcnessRQjU917hmKO6JWVGHpDguIyakZA==
#                             -----END PUBLIC KEY-----
#                           rekor:
#                             ignoreTlog: true
#       EOF
#
#       kubectl wait --for=condition=Ready cpol/kca-56-verify-image-signatures --timeout=60s
#
#  5) Verify the three goals, then let the grader confirm:
#
#       kubectl -n kca-56-verifyimages delete pod --all
#       kubectl -n kca-56-verifyimages run signed-app   --image=ghcr.io/kyverno/test-verify-image:signed   --restart=Never
#       kubectl -n kca-56-verifyimages get pod signed-app -o jsonpath='{.spec.containers[0].image}'; echo
#       # ghcr.io/kyverno/test-verify-image@sha256:b31bfb4d0213f254d361e0079deaaebefa4f82ba7aa76ef82e90b4935ad5b105
#       kubectl -n kca-56-verifyimages run unsigned-app --image=ghcr.io/kyverno/test-verify-image:unsigned --restart=Never
#       # Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
#       #   resource Pod/kca-56-verifyimages/unsigned-app was blocked due to the following policies
#       #   kca-56-verify-image-signatures:
#       #     verify-protected-repository: 'failed to verify image
#       #       ghcr.io/kyverno/test-verify-image:unsigned: .attestors[0].entries[0].keys:
#       #       no signatures found'
#       kubectl -n kca-56-verifyimages rollout restart deploy/unrelated-app
#       ./<this-script> check
#
#  WHY THE DIGEST IS THE REAL PROOF
#    mutateDigest rewrites tag -> digest only after a successful verification.
#    A tag is a mutable pointer: verifying ":signed" and then letting the kubelet
#    resolve ":signed" again at pull time is a time-of-check/time-of-use gap the
#    registry owner can drive a truck through. verifyDigest additionally refuses
#    images that end up without a digest. Treat "still shows a tag" as "was
#    never verified".
#
#  PRODUCTION NOTES (exam-relevant and job-relevant)
#    * failurePolicy: Fail + webhookTimeoutSeconds: 30 means a registry outage
#      becomes an admission outage for the matched resources. That is the correct
#      default for a security gate — but you must scope `match` narrowly and
#      exclude the namespaces that host your own platform components, or you
#      cannot recover the cluster after a restart.
#    * Never let a verifyImages rule match the namespace Kyverno runs in.
#    * Private registries: `imageRegistryCredentials` (or the controller's
#      imagePullSecrets) — verification pulls the manifest with the controller's
#      identity, not the workload's ServiceAccount. Registry auth failures show
#      up as 401/403 in the controller log, not as signature failures.
#    * Keyless verification replaces `keys` with `certificate`/`keyless`
#      attestors (issuer + subject, optionally a regex), which is what CI-signed,
#      OIDC-identity images use.
#    * `attestors[].count` implements m-of-n trust; `attestations` verifies
#      in-toto predicates (SBOM, provenance) and can gate on their contents.
#    * Kyverno caches successful verifications (default TTL 60 min). If a fix
#      seems not to take effect, remember the cache and the fact that the cache
#      key includes the policy — bumping the policy invalidates it.
#    * Kyverno 1.14+ introduces the dedicated ImageValidatingPolicy CRD; the
#      ClusterPolicy verifyImages rule shown here remains supported and is what
#      the KCA curriculum exercises.
#
#  REFERENCES
#    https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    https://kyverno.io/docs/writing-policies/verify-images/
#    https://kyverno.io/docs/policy-reports/
#    https://kyverno.io/docs/installation/
#    https://docs.sigstore.dev/cosign/verifying/verify/
# =============================================================================