#!/usr/bin/env bash
#===============================================================================
# CGOA · Topic 1.1 — GitOps Fundamentals
# Break & Fix Lab: "The Paused Reconciler and the Midnight Hotfix"
#-------------------------------------------------------------------------------
# WHAT THIS LAB TEACHES
#   The four OpenGitOps v1.0.0 principles in the flesh:
#     1. Declarative        — desired state expressed as data (YAML in Git)
#     2. Versioned/immutable — Git is the single source of truth
#     3. Pulled automatically — an in-cluster agent (Flux) pulls, nothing pushes
#     4. Continuously reconciled — drift is detected and reverted, forever
#   This lab BREAKS principles 3 and 4 on purpose: a (simulated) colleague
#   suspended the reconciler during an incident and hand-patched the cluster
#   with kubectl — the classic "midnight hotfix" anti-pattern. Your job is to
#   restore the GitOps loop and let it heal the cluster, NOT to hand-patch
#   it back.
#
# SAFETY
#   Everything happens inside a dedicated, disposable kind cluster named
#   "cgoa-lab" on this lab VM. Every kubectl call pins --context kind-cgoa-lab,
#   so your real clusters are never touched. Destroy it all with:
#     ./gitops-fundamentals-breakfix.sh clean
#
# REQUIREMENTS (lab VM, internet access for images + GitHub)
#   docker, kind, kubectl, flux CLI  (install hints are printed if missing)
#
# USAGE
#   ./gitops-fundamentals-breakfix.sh          # setup + break + briefing
#   ./gitops-fundamentals-breakfix.sh status   # the views a responder would open
#   ./gitops-fundamentals-breakfix.sh verify   # check whether YOU actually fixed it
#   ./gitops-fundamentals-breakfix.sh clean    # delete the kind cluster
#
# SOURCES (official)
#   https://opengitops.dev/                                    (GitOps principles v1.0.0)
#   https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md
#   https://fluxcd.io/flux/components/kustomize/kustomizations/   (suspend, drift correction, SSA)
#   https://fluxcd.io/flux/components/source/gitrepositories/
#   https://fluxcd.io/flux/cmd/flux_resume_kustomization/
#   https://kubernetes.io/docs/reference/using-api/server-side-apply/  (field ownership)
#   https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
#===============================================================================
set -euo pipefail

CLUSTER="cgoa-lab"
CTX="kind-${CLUSTER}"
KC="kubectl --context ${CTX}"
APP_NS="podinfo"
FLUX_NS="flux-system"
BROKEN_IMAGE="ghcr.io/stefanprodan/podinfo:0.0.0-cgoa-broken"
STATE_DIR="/tmp/cgoa-111-lab"
STATE_IMAGE="${STATE_DIR}/good-image"

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[1;36m'; c_off=$'\033[0m'
say()  { printf '%s[lab]%s %s\n' "$c_cyn" "$c_off" "$*"; }
ok()   { printf '%s[ ok]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!!!]%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s[err]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  warn "missing dependency: $1"
  case "$1" in
    kind)    echo "  install: https://kind.sigs.k8s.io/docs/user/quick-start/#installation" ;;
    flux)    echo "  install: curl -s https://fluxcd.io/install.sh | sudo bash   (https://fluxcd.io/flux/installation/)" ;;
    kubectl) echo "  install: https://kubernetes.io/docs/tasks/tools/" ;;
    docker)  echo "  install: https://docs.docker.com/engine/install/" ;;
  esac
  return 1
}

check_deps() {
  local fail=0
  for bin in docker kind kubectl flux; do need "$bin" || fail=1; done
  [ "$fail" -eq 0 ] || die "install the missing tools on this lab VM, then re-run"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable (is your user in the docker group?)"
}

ensure_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    ok "kind cluster '${CLUSTER}' already exists (idempotent, reusing it)"
  else
    say "creating disposable kind cluster '${CLUSTER}' (this is the ONLY cluster the lab touches)"
    kind create cluster --name "${CLUSTER}" --wait 120s
  fi
  ${KC} cluster-info >/dev/null || die "context ${CTX} is not reachable"
}

ensure_flux() {
  if ${KC} -n "${FLUX_NS}" get deploy source-controller >/dev/null 2>&1; then
    ok "Flux controllers already installed"
  else
    say "installing Flux controllers (in-cluster pull agents — GitOps principle 3)"
    flux install --context "${CTX}" \
      --components=source-controller,kustomize-controller
  fi
  ${KC} -n "${FLUX_NS}" wait deploy --all --for=condition=Available --timeout=180s
}

ensure_workload() {
  say "declaring desired state: GitRepository (source of truth) + Kustomization (reconciler)"
  ${KC} get ns "${APP_NS}" >/dev/null 2>&1 || ${KC} create ns "${APP_NS}"
  cat <<'EOF' | ${KC} apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/stefanprodan/podinfo
  ref:
    branch: master
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 30s
  retryInterval: 20s
  targetNamespace: podinfo
  sourceRef:
    kind: GitRepository
    name: podinfo
  path: ./kustomize
  prune: true
  timeout: 2m
EOF
  say "waiting for the source artifact and the first reconciliation..."
  ${KC} -n "${FLUX_NS}" wait gitrepository/podinfo   --for=condition=Ready --timeout=180s
  ${KC} -n "${FLUX_NS}" wait kustomization/podinfo   --for=condition=Ready --timeout=180s
  local tries=0
  until ${KC} -n "${APP_NS}" get deploy podinfo >/dev/null 2>&1; do
    tries=$((tries+1)); [ "$tries" -le 30 ] || die "deployment ${APP_NS}/podinfo never appeared"
    sleep 2
  done
  ${KC} -n "${APP_NS}" rollout status deploy/podinfo --timeout=180s
  ok "baseline healthy: cluster state == state declared in Git"
}

do_break() {
  mkdir -p "${STATE_DIR}"
  local current
  current=$(${KC} -n "${APP_NS}" get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}')
  if [ "${current}" != "${BROKEN_IMAGE}" ]; then
    printf '%s\n' "${current}" > "${STATE_IMAGE}"
  fi
  say "BREAK step 1/2 — suspending the reconciler (kills principles 3 and 4)"
  ${KC} -n "${FLUX_NS}" patch kustomization podinfo --type merge -p '{"spec":{"suspend":true}}'
  say "BREAK step 2/2 — imperative 'midnight hotfix': kubectl set image with a tag that does not exist"
  ${KC} -n "${APP_NS}" set image deploy/podinfo podinfod="${BROKEN_IMAGE}"
  sleep 8
  ${KC} -n "${APP_NS}" get pods || true
}

briefing() {
  cat <<EOF

${c_yel}================================ INCIDENT BRIEFING ================================${c_off}
Scenario: during last night's on-call, someone "paused GitOps for a quick fix",
patched the podinfo Deployment by hand with kubectl, and went to bed. The change
references a container image tag that was never published.

${c_cyn}SYMPTOMS YOU WILL SEE${c_off}
  \$ kubectl --context ${CTX} -n ${APP_NS} get pods
      NAME                       READY   STATUS             RESTARTS   AGE
      podinfo-6f9d5f7b9c-xxxxx   1/1     Running            0          9m    <- old ReplicaSet, still serving
      podinfo-7c8b9d5db4-yyyyy   0/1     ImagePullBackOff   0          2m    <- the "hotfix" pod, stuck

  \$ kubectl --context ${CTX} -n ${APP_NS} rollout status deploy/podinfo
      ...hangs: "1 out of X new replicas have been updated"... then ProgressDeadlineExceeded

  The rollout is wedged mid-flight. The app is one pod eviction / node reboot away
  from an outage — and here is the fundamentals part: ${c_yel}Flux is NOT fixing it${c_off}.
  Normally drift is reverted within one interval (30s here). Minutes have passed.

  \$ flux --context ${CTX} get kustomizations
      NAME     REVISION             SUSPENDED   READY   MESSAGE
      podinfo  master@sha1:xxxxxxx  True        True    Applied revision: master@sha1:xxxxxxx
                                    ^^^^ the smoking gun

${c_cyn}YOUR GOAL${c_off}
  Restore the GitOps loop and let IT converge the cluster back to the state
  declared in Git. Success means ALL of:
    1. the Kustomization is no longer suspended and reconciles (READY True),
    2. the Deployment runs the image declared in Git, rollout complete,
    3. you did NOT hand-edit the Deployment. Fixing drift with more kubectl is
       the exact anti-pattern this incident started with — and this lab's
       'verify' will catch you, because a suspended reconciler means the next
       drift silently sticks again.

${c_cyn}INVESTIGATE WITH${c_off}
  flux --context ${CTX} get kustomizations
  flux --context ${CTX} events
  kubectl --context ${CTX} -n ${FLUX_NS} get kustomization podinfo -o jsonpath='{.spec.suspend}{"\n"}'
  kubectl --context ${CTX} -n ${APP_NS} describe pod -l app=podinfo

${c_cyn}WHEN YOU THINK IT IS FIXED${c_off}
  $0 verify

  Optional smoke test of the app itself:
  kubectl --context ${CTX} -n ${APP_NS} port-forward svc/podinfo 9898:9898 &
  curl -s localhost:9898 | grep version    # returns the podinfo JSON greeting

Full step-by-step solution: commented block at the bottom of this script.
${c_yel}===================================================================================${c_off}

EOF
}

status_view() {
  say "flux objects:"
  flux --context "${CTX}" get sources git || true
  flux --context "${CTX}" get kustomizations || true
  say "workload:"
  ${KC} -n "${APP_NS}" get deploy,rs,pods -o wide || true
  say "suspend flag:"
  ${KC} -n "${FLUX_NS}" get kustomization podinfo -o jsonpath='spec.suspend={.spec.suspend}{"\n"}' || true
}

verify_fix() {
  local pass=1 suspend image good ready
  suspend=$(${KC} -n "${FLUX_NS}" get kustomization podinfo -o jsonpath='{.spec.suspend}')
  image=$(${KC} -n "${APP_NS}" get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}')
  ready=$(${KC} -n "${FLUX_NS}" get kustomization podinfo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  good=$(cat "${STATE_IMAGE}" 2>/dev/null || echo "")

  if [ "${suspend}" = "true" ]; then
    warn "Kustomization is STILL suspended — the reconciliation loop is not restored."
    warn "Even if the pods look healthy (did you kubectl-patch them back? that is more drift,"
    warn "not a fix), the next unreviewed change will silently stick. Principles 3+4 still broken."
    pass=0
  else
    ok "Kustomization is not suspended (pull + reconcile loop restored)"
  fi
  if [ "${ready}" = "True" ]; then
    ok "Kustomization Ready=True (last reconciliation applied cleanly)"
  else
    warn "Kustomization Ready=${ready:-unknown} — reconciliation has not succeeded yet; give it one interval (30s) or run: flux --context ${CTX} reconcile kustomization podinfo --with-source"
    pass=0
  fi
  if [ "${image}" = "${BROKEN_IMAGE}" ]; then
    warn "Deployment still points at the broken image (${BROKEN_IMAGE}) — drift not yet reverted"
    pass=0
  else
    ok "Deployment image is ${image}$( [ -n "${good}" ] && [ "${image}" = "${good}" ] && echo ' (matches the Git-declared image captured at break time)' )"
  fi
  if ${KC} -n "${APP_NS}" rollout status deploy/podinfo --timeout=90s >/dev/null 2>&1; then
    ok "rollout complete, all replicas Ready"
  else
    warn "rollout not complete"
    pass=0
  fi

  if [ "${pass}" -eq 1 ]; then
    printf '\n%s*** FIXED. ***%s The reconciler pulled the declared state from Git and converged the\n' "$c_grn" "$c_off"
    printf 'cluster back to it — you never touched the Deployment. That loop, not any single\n'
    printf 'kubectl command, is what GitOps means.\n'
  else
    printf '\n%sNot fixed yet.%s Re-read the briefing: $0 status\n' "$c_red" "$c_off"
    exit 1
  fi
}

clean() {
  say "deleting kind cluster '${CLUSTER}' and lab state"
  kind delete cluster --name "${CLUSTER}" || true
  rm -rf "${STATE_DIR}"
  ok "lab removed"
}

case "${1:-run}" in
  run)    check_deps; ensure_cluster; ensure_flux; ensure_workload; do_break; briefing ;;
  status) status_view ;;
  verify) verify_fix ;;
  clean)  clean ;;
  *)      die "usage: $0 [run|status|verify|clean]" ;;
esac
exit 0

#===============================================================================
# SOLUTION — spoilers below. Attempt the fix yourself first.
#===============================================================================
#
# STEP 1 — Confirm the symptom is drift that is NOT being corrected.
#
#   $ kubectl --context kind-cgoa-lab -n podinfo get pods
#   NAME                       READY   STATUS             RESTARTS   AGE
#   podinfo-6f9d5f7b9c-k2m8p   1/1     Running            0          12m
#   podinfo-7c8b9d5db4-qx4jt   0/1     ImagePullBackOff   0          4m
#
#   ImagePullBackOff on a tag nobody published. In a healthy GitOps setup this
#   would self-revert within one reconciliation interval (spec.interval: 30s).
#   It has not. So the question is not "what is wrong with the pod" — it is
#   "why is the reconciler not reconciling".
#
# STEP 2 — Interrogate the reconciler, not the workload.
#
#   $ flux --context kind-cgoa-lab get kustomizations
#   NAME     REVISION             SUSPENDED   READY   MESSAGE
#   podinfo  master@sha1:a1b2c3d  True        True    Applied revision: master@sha1:a1b2c3d
#
#   SUSPENDED=True. Mechanically, spec.suspend=true tells kustomize-controller
#   to skip this object entirely in its reconcile loop — no pulls are acted on,
#   no server-side apply, no drift detection, no pruning. The cluster is
#   unmanaged while looking managed. Confirm at the API level:
#
#   $ kubectl --context kind-cgoa-lab -n flux-system \
#       get kustomization podinfo -o jsonpath='{.spec.suspend}{"\n"}'
#   true
#
# STEP 3 — Resume the reconciler. Do NOT touch the Deployment.
#
#   $ flux --context kind-cgoa-lab resume kustomization podinfo
#   ► resuming kustomization podinfo in flux-system namespace
#   ✔ kustomization resumed
#   ◎ waiting for Kustomization reconciliation
#   ✔ applied revision master@sha1:a1b2c3d
#
#   'flux resume' both clears spec.suspend and triggers an immediate
#   reconciliation. The declarative equivalent is:
#     kubectl -n flux-system patch kustomization podinfo \
#       --type merge -p '{"spec":{"suspend":false}}'
#   ...which waits up to one interval (30s), or force it right away with:
#     flux reconcile kustomization podinfo --with-source
#
# STEP 4 — Watch the loop heal the drift.
#
#   $ kubectl --context kind-cgoa-lab -n podinfo get pods -w
#   podinfo-7c8b9d5db4-qx4jt   0/1   Terminating   0   6m    <- broken "hotfix" RS scaled down
#   podinfo-6f9d5f7b9c-w9z2v   1/1   Running       0   5s    <- Git-declared spec restored
#
#   WHY this works: kustomize-controller applies manifests with Kubernetes
#   Server-Side Apply and takes ownership of the fields it manages, forcing
#   conflict resolution in its favor. 'kubectl set image' had stolen ownership
#   of .spec.template.spec.containers[0].image; on resume, the controller
#   re-applies the Git-declared value and reclaims the field. Manual drift
#   loses to declared state — by design, every 30 seconds, forever.
#   (SSA field ownership: kubernetes.io/docs/reference/using-api/server-side-apply/
#    drift correction: fluxcd.io/flux/components/kustomize/kustomizations/)
#
# STEP 5 — Prove it.
#
#   $ ./gitops-fundamentals-breakfix.sh verify
#   [ ok] Kustomization is not suspended (pull + reconcile loop restored)
#   [ ok] Kustomization Ready=True (last reconciliation applied cleanly)
#   [ ok] Deployment image is ghcr.io/stefanprodan/podinfo:6.x.y (matches the Git-declared image captured at break time)
#   [ ok] rollout complete, all replicas Ready
#   *** FIXED. ***
#
# THE ANTI-SOLUTION (what NOT to do, and why verify rejects it):
#   'kubectl set image' back to the good tag makes the pods green in seconds —
#   and fixes nothing. The reconciler is still suspended, so the cluster is
#   still unmanaged: the next bad hand-edit also sticks, prune is off, and Git
#   no longer predicts production. You would have treated the symptom (a pod)
#   and preserved the disease (a broken control loop). Suspend is a legitimate,
#   auditable tool for planned maintenance windows — the failure here was
#   combining it with imperative mutation and forgetting to resume.
#
# EXAM MAPPING (CGOA · GitOps Principles, 25% of the exam):
#   Principle 1 (declarative)  — the Kustomization + Git manifests, not scripts
#   Principle 2 (versioned)    — master@sha1:... is an immutable, auditable ref
#   Principle 3 (pulled)       — source-controller fetched Git; nothing pushed
#   Principle 4 (reconciled)   — the drift revert you watched in STEP 4
#   https://opengitops.dev/  ·  github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md
#===============================================================================