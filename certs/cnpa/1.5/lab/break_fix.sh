#!/usr/bin/env bash
#
# break_fix.sh — CNPA Topic 1.5: Platform Engineering Goals, Objectives, and Strategic Approaches
#
# Scenario: "When the paved road cracks, developers go off-road."
#
# This lab builds a miniature Internal Developer Platform (IDP) on a disposable
# Kubernetes lab cluster (kind / k3d / minikube / k3s), then breaks it in a
# controlled, reversible way. The break is NOT a workload bug — it is a
# *platform* defect, and the whole point of Topic 1.5 is that you learn to fix
# it at the platform level, not by patching one team's Deployment.
#
# Concepts exercised (CNPA curriculum, domain 1):
#   - Platform as a Product: the golden path is a product; its outage has users.
#   - Golden paths / paved roads: one command scaffolds a compliant workload.
#   - Self-service with guardrails: ResourceQuota enforces limits, LimitRange
#     injects sane defaults so product teams never think about quota mechanics.
#   - Cognitive load reduction: the platform absorbs complexity; when a
#     guardrail silently disappears, that load lands back on every dev team.
#   - Config drift vs. source of truth: the break simulates a live "hotfix"
#     deletion in the cluster that diverged from the platform repo (why mature
#     platforms run GitOps reconciliation — Maturity Model, "Operations" aspect).
#
# Sources:
#   - CNPA Curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   - CNCF Platforms Whitepaper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
#   - CNCF Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
#   - Kubernetes LimitRange: https://kubernetes.io/docs/concepts/policy/limit-range/
#   - Kubernetes ResourceQuota: https://kubernetes.io/docs/concepts/policy/resource-quotas/
#   - Team Topologies (platform team pattern): https://teamtopologies.com/key-concepts
#
# Safety: everything lives in two dedicated namespaces (platform-system,
# team-checkout) plus one directory ($LAB_DIR). `./break_fix.sh reset` removes
# every trace. No host-level or cluster-wide resources are touched.
#
# Usage:
#   ./break_fix.sh            # setup the platform, then break it (default)
#   ./break_fix.sh status     # dashboard of the current symptom
#   ./break_fix.sh verify     # grade your fix (exit 0 = solved)
#   ./break_fix.sh reset      # remove everything the lab created
#
set -euo pipefail

LAB_DIR="${LAB_DIR:-${HOME}/cnpa-1.5-lab}"
PLATFORM_NS="platform-system"
TENANT_NS="team-checkout"
PLATFORMCTL="${LAB_DIR}/bin/platformctl"
PASS_COUNT=0
FAIL_COUNT=0

banner() { printf '\n==== %s ====\n' "$*"; }
note()   { printf '  -> %s\n' "$*"; }
pass()   { printf '  [PASS] %s\n' "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()   { printf '  [FAIL] %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

need_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH." >&2; exit 1; }
  kubectl get nodes -o name >/dev/null 2>&1 || { echo "ERROR: no reachable Kubernetes cluster (kubectl get nodes failed)." >&2; exit 1; }
  assert_lab_context
}

# Guardrail for the guardrail lab: refuse to run against anything that does not
# look like a disposable cluster, unless the student explicitly overrides.
assert_lab_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  case "$ctx" in
    kind-*|k3d-*|minikube|default|lab-*) ;;
    *)
      if [ "${I_KNOW_THIS_IS_A_LAB:-0}" != "1" ]; then
        echo "REFUSING: current kubectl context is '${ctx}', which does not look like a lab cluster." >&2
        echo "If this really is a disposable VM, re-run with: I_KNOW_THIS_IS_A_LAB=1 $0 $*" >&2
        exit 1
      fi
      ;;
  esac
}

setup() {
  banner "SETUP: building the miniature Internal Developer Platform"
  mkdir -p "${LAB_DIR}/bin" "${LAB_DIR}/platform"

  kubectl get ns "$PLATFORM_NS" >/dev/null 2>&1 || kubectl create ns "$PLATFORM_NS"
  kubectl get ns "$TENANT_NS"   >/dev/null 2>&1 || kubectl create ns "$TENANT_NS"
  kubectl label ns "$TENANT_NS" platform.cnpa.dev/tenant=checkout --overwrite >/dev/null

  # --- Platform source of truth (in real life: the platform team's git repo,
  # --- reconciled by Argo CD / Flux; here: files on disk).
  cat > "${LAB_DIR}/platform/quota.yaml" <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: team-checkout
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
EOF

  cat > "${LAB_DIR}/platform/limitrange.yaml" <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: platform-defaults
  namespace: team-checkout
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 256Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
EOF

  cat > "${LAB_DIR}/platform/golden-path-template.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: golden-path-template
  namespace: platform-system
  labels:
    platform.cnpa.dev/component: golden-path
data:
  workload.yaml: |
    # Golden-path workload template.
    # 'resources:' is intentionally omitted: the platform's LimitRange injects
    # sane defaults at admission time, so product teams never have to reason
    # about quota mechanics. That omission is a DESIGN DECISION with a
    # DEPENDENCY: it is only safe while the LimitRange exists.
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: __APP__
      labels:
        app.kubernetes.io/name: __APP__
        platform.cnpa.dev/team: __TEAM__
        platform.cnpa.dev/scaffolded: "true"
    spec:
      replicas: 2
      selector:
        matchLabels:
          app.kubernetes.io/name: __APP__
      template:
        metadata:
          labels:
            app.kubernetes.io/name: __APP__
            platform.cnpa.dev/team: __TEAM__
        spec:
          containers:
            - name: app
              image: registry.k8s.io/pause:3.9
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: __APP__
      labels:
        app.kubernetes.io/name: __APP__
        platform.cnpa.dev/team: __TEAM__
    spec:
      selector:
        app.kubernetes.io/name: __APP__
      ports:
        - port: 80
          targetPort: 80
EOF

  kubectl apply -f "${LAB_DIR}/platform/quota.yaml" >/dev/null
  kubectl apply -f "${LAB_DIR}/platform/limitrange.yaml" >/dev/null
  kubectl apply -f "${LAB_DIR}/platform/golden-path-template.yaml" >/dev/null
  note "Guardrails applied: ResourceQuota 'team-quota' + LimitRange 'platform-defaults' in ${TENANT_NS}"

  # --- The self-service CLI: one command from idea to running, compliant workload.
  cat > "$PLATFORMCTL" <<'EOF'
#!/usr/bin/env bash
# platformctl — minimal golden-path scaffolder for the CNPA 1.5 lab.
set -euo pipefail
if [ "$#" -ne 3 ] || [ "$1" != "scaffold" ]; then
  echo "usage: platformctl scaffold <team> <app>" >&2
  exit 1
fi
team="$2"; app="$3"; ns="team-${team}"
kubectl get ns "$ns" >/dev/null 2>&1 || { echo "ERROR: tenant namespace '$ns' is not provisioned." >&2; exit 1; }
tpl="$(kubectl -n platform-system get configmap golden-path-template -o jsonpath='{.data.workload\.yaml}')"
printf '%s\n' "$tpl" | sed -e "s/__APP__/${app}/g" -e "s/__TEAM__/${team}/g" | kubectl -n "$ns" apply -f -
echo "[platformctl] scaffolded '${app}' for team '${team}' on the golden path."
EOF
  chmod +x "$PLATFORMCTL"
  note "Self-service CLI installed at ${PLATFORMCTL}"

  # --- Prove the golden path works: the checkout team ships 'orders'.
  "$PLATFORMCTL" scaffold checkout orders >/dev/null
  if kubectl -n "$TENANT_NS" rollout status deploy/orders --timeout=120s >/dev/null 2>&1; then
    note "Baseline healthy: 'orders' scaffolded via golden path is 2/2 Ready."
  else
    echo "WARNING: 'orders' did not become Ready in 120s (slow image pull?). Continuing anyway." >&2
  fi
}

break_it() {
  banner "BREAK: injecting the platform defect"
  kubectl -n "$PLATFORM_NS" get configmap golden-path-template >/dev/null 2>&1 || setup

  # The "incident": during a live troubleshooting session weeks ago, someone
  # deleted the LimitRange directly in the cluster and never reconciled the
  # change back. Nothing failed at that moment — running pods keep their
  # resources — so the drift went unnoticed. Classic latent platform failure.
  kubectl -n "$TENANT_NS" delete limitrange platform-defaults --ignore-not-found >/dev/null
  note "A platform guardrail has silently disappeared from ${TENANT_NS} (existing pods unaffected... for now)."

  # Today, two routine things happen:
  # 1) the checkout team scaffolds a new service, 'payments', on the golden path:
  "$PLATFORMCTL" scaffold checkout payments >/dev/null 2>&1 || true
  # 2) a routine redeploy of the existing 'orders' service:
  kubectl -n "$TENANT_NS" rollout restart deploy/orders >/dev/null
  note "Routine activity replayed: new service scaffolded + existing service redeployed."
  note "Run './break_fix.sh status' to see the symptom."
}

briefing() {
  cat <<'EOF'

================================================================================
 CNPA 1.5 BREAK & FIX — "The golden path must be the easiest path"
================================================================================

 THE PLATFORM YOU INHERITED
   * platform-system : holds the golden-path template (ConfigMap).
   * team-checkout   : a tenant namespace with a ResourceQuota guardrail.
   * platformctl     : self-service CLI ($LAB_DIR/bin/platformctl scaffold <team> <app>).
   * Design decision : templates carry NO 'resources:' block; a LimitRange in
     the tenant namespace injects defaults at admission time. The platform
     absorbs that cognitive load so product teams do not have to.

 WHAT YOU WILL SEE (the symptom)
   $ kubectl get deploy -n team-checkout
   NAME       READY   UP-TO-DATE   AVAILABLE   AGE
   orders     2/2     0            2           6m
   payments   0/2     0            0           40s

   'payments' never starts. Worse: 'orders' LOOKS healthy (2/2) but its
   UP-TO-DATE column is 0 — the team can no longer ship a new version of a
   service that is currently serving traffic. The platform is degraded in the
   most dangerous way: quietly.

   $ kubectl get events -n team-checkout --sort-by=.lastTimestamp | tail -n 5
   Warning  FailedCreate  replicaset/payments-7c9d55f6b  Error creating: pods
   "payments-7c9d55f6b-xxxxx" is forbidden: failed quota: team-quota: must
   specify limits.cpu for: app; limits.memory for: app; requests.cpu for: app;
   requests.memory for: app

 WHY THIS IS A TOPIC-1.5 PROBLEM, NOT A KUBERNETES TRIVIA PROBLEM
   The goal of a platform is self-service with guardrails and reduced cognitive
   load (CNCF Platforms Whitepaper). Today every checkout developer suddenly
   needs to understand ResourceQuota admission semantics — the exact cognitive
   load the platform existed to remove. The outage of a golden path is a
   product outage: treat it with product urgency (Platform as a Product).

 YOUR MISSION
   Restore self-service for EVERY team and EVERY future workload.
   * Fixing it by editing the 'payments' or 'orders' Deployments (adding a
     resources: block by hand) is the ANTI-PATTERN: it fixes one instance,
     leaves the platform broken, and the verifier will catch you.
   * Think: which platform component made the template's missing 'resources:'
     safe? Where is its source of truth? What does "reconcile drift" mean here?

 TOOLS THAT WILL HELP
   kubectl get events -n team-checkout --sort-by=.lastTimestamp
   kubectl describe rs -n team-checkout
   kubectl get resourcequota,limitrange -n team-checkout
   ls $HOME/cnpa-1.5-lab/platform/        # the platform team's "repo"

 DONE WHEN
   ./break_fix.sh verify   exits 0 (it also scaffolds a brand-new canary app —
   the only honest test of self-service is a fresh golden-path run).

 The step-by-step solution is commented at the bottom of this script.
 Do not read it until you have genuinely tried.
================================================================================
EOF
}

show_status() {
  banner "STATUS: platform health dashboard"
  echo "Context: $(kubectl config current-context)"
  echo
  echo "-- Deployments in ${TENANT_NS} (READY vs UP-TO-DATE is the tell):"
  kubectl get deploy -n "$TENANT_NS" 2>/dev/null || true
  echo
  echo "-- Guardrails present in ${TENANT_NS}:"
  kubectl get resourcequota,limitrange -n "$TENANT_NS" 2>/dev/null || true
  echo
  echo "-- Last warning events:"
  kubectl get events -n "$TENANT_NS" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n 8 || true
}

do_verify() {
  banner "VERIFY: grading the fix"

  if kubectl -n "$TENANT_NS" get limitrange platform-defaults >/dev/null 2>&1; then
    pass "LimitRange 'platform-defaults' exists again in ${TENANT_NS}"
  else
    fail "LimitRange 'platform-defaults' is still missing — the guardrail was not restored"
  fi

  local d
  for d in orders payments; do
    if kubectl -n "$TENANT_NS" rollout status "deploy/${d}" --timeout=180s >/dev/null 2>&1; then
      pass "Deployment '${d}' fully rolled out and Ready"
    else
      fail "Deployment '${d}' still cannot complete its rollout"
    fi
  done

  # Anti-pattern detector: the fix must be platform-level. If the Deployment
  # spec now carries a hand-added resources: block, the instance was patched
  # while the platform stayed broken for everyone else.
  for d in orders payments; do
    local res
    res="$(kubectl -n "$TENANT_NS" get "deploy/${d}" -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null || echo missing)"
    if [ -z "$res" ] || [ "$res" = "{}" ]; then
      pass "Deployment '${d}' spec still has no hardcoded resources (platform-level fix)"
    else
      fail "Deployment '${d}' was patched directly (resources: ${res}) — that is the instance-level anti-pattern"
    fi
  done

  # The only honest test of self-service: a brand-new golden-path run.
  kubectl -n "$TENANT_NS" delete deploy/verify-canary svc/verify-canary --ignore-not-found >/dev/null 2>&1
  if "$PLATFORMCTL" scaffold checkout verify-canary >/dev/null 2>&1 \
     && kubectl -n "$TENANT_NS" rollout status deploy/verify-canary --timeout=120s >/dev/null 2>&1; then
    pass "Fresh golden-path scaffold ('verify-canary') works end to end — self-service restored"
  else
    fail "A fresh golden-path scaffold still fails — the platform is not actually fixed"
  fi
  kubectl -n "$TENANT_NS" delete deploy/verify-canary svc/verify-canary --ignore-not-found >/dev/null 2>&1

  echo
  echo "Result: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "SOLVED. You fixed the platform, not the symptom. That distinction is Topic 1.5."
    exit 0
  else
    echo "Not there yet. Hint: 'must specify limits.cpu' means the quota demands values nothing is defaulting anymore."
    exit 1
  fi
}

do_reset() {
  banner "RESET: removing everything the lab created"
  kubectl delete ns "$TENANT_NS" "$PLATFORM_NS" --ignore-not-found
  rm -rf "$LAB_DIR"
  note "Namespaces and ${LAB_DIR} removed."
}

usage() {
  echo "usage: $0 [break|status|verify|reset]"
  exit 1
}

main() {
  need_kubectl
  case "${1:-break}" in
    break)  setup; break_it; briefing ;;
    status) show_status ;;
    verify) do_verify ;;
    reset)  do_reset ;;
    *)      usage ;;
  esac
}

main "$@"

# ==============================================================================
# SOLUTION — step by step (do not read until you have genuinely tried)
# ==============================================================================
#
# 1. Start from the symptom, not from a guess:
#      kubectl get deploy -n team-checkout
#    'payments' is 0/2 and 'orders' shows READY 2/2 but UP-TO-DATE 0. A READY
#    deployment that cannot roll out is a controller-level failure: the
#    Deployment created a new ReplicaSet, and that ReplicaSet cannot create pods.
#
# 2. Ask the controllers why:
#      kubectl get events -n team-checkout --sort-by=.lastTimestamp | tail
#      kubectl describe rs -n team-checkout | grep -A2 FailedCreate
#    The event is explicit:
#      pods "payments-..." is forbidden: failed quota: team-quota: must specify
#      limits.cpu for: app; limits.memory for: app; requests.cpu ...
#    Mechanics: when a ResourceQuota constrains requests.*/limits.*, the quota
#    admission plugin REJECTS any pod that does not declare those values
#    (https://kubernetes.io/docs/concepts/policy/resource-quotas/).
#
# 3. But the golden-path template never declared resources — so why did it ever
#    work? Because something was defaulting them at admission time:
#      kubectl get limitrange -n team-checkout
#      -> No resources found in team-checkout namespace.
#    Root cause: the LimitRange 'platform-defaults' (the mutating defaulter,
#    https://kubernetes.io/docs/concepts/policy/limit-range/) was deleted
#    directly in the cluster. Running pods kept their values, so the drift was
#    invisible until the next scaffold/redeploy. The template's design carried
#    a hidden dependency on that guardrail.
#
# 4. Fix at the platform level — reconcile from the source of truth:
#      kubectl apply -f "$HOME/cnpa-1.5-lab/platform/limitrange.yaml"
#    (Adjust the path if you overrode LAB_DIR.) This is exactly what a GitOps
#    reconciler would have done automatically within minutes — which is why
#    drift detection is an "Operations" trait in the CNCF Platform Engineering
#    Maturity Model.
#
# 5. Recovery is automatic but backoff-delayed: the ReplicaSet controller
#    retries failed pod creations with exponential backoff. To converge
#    immediately instead of waiting:
#      kubectl -n team-checkout rollout restart deploy orders payments
#    (A restart only stamps a template annotation; it does not add resources,
#    so the anti-pattern detector still passes.)
#
# 6. Prove it:
#      ./break_fix.sh verify
#    The verifier re-runs the golden path with a fresh app. That is the real
#    platform SLO: "a new team, with zero Kubernetes quota knowledge, can go
#    from nothing to Running through the paved road."
#
# What NOT to do — and why it matters for the exam:
#    kubectl -n team-checkout set resources deploy/payments --requests=cpu=100m...
#    unblocks ONE deployment, leaves every future scaffold broken, splits the
#    fleet into snowflakes, and hides the platform defect. Instance patches
#    treat the platform's users as the maintenance crew — the inverse of
#    Platform as a Product (https://tag-app-delivery.cncf.io/whitepapers/platforms/).
# ==============================================================================