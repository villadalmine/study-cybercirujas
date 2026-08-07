#!/usr/bin/env bash
#
# ==============================================================================
#  CNPA · Certified Cloud Native Platform Engineering Associate
#  Exam version: 2025-04-01
#  Domain 3 · Topic 3.5 — CI/CD Relationship Fundamentals and Integration
#  (exam weight: 2.3)
#
#  break & fix lab — self-contained GitOps CI/CD simulator
#
#  This script models the relationship between Continuous Integration (CI) and
#  Continuous Delivery (CD) on a platform, using four planes that map 1:1 to a
#  real setup:
#
#     CI  ── builds & pushes an immutable artifact ─────────►  Artifact Registry
#     CI  ── commits the new desired image tag ─────────────►  Git (source of truth)
#     CD  ── pulls Git, reconciles the cluster toward it ───►  Live cluster state
#
#  Everything lives inside a throwaway lab directory under your $HOME. It needs
#  no root, no network, no Kubernetes cluster and touches no system files, so it
#  is safe to run on any disposable lab VM. Tear it down at any time with
#  './break_fix.sh reset'.
#
#  Reference sources (official):
#    - CNPA Curriculum ...... https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#    - OpenGitOps principles  https://opengitops.dev/
#    - Argo CD docs ......... https://argo-cd.readthedocs.io/en/stable/
#    - Flux docs ............ https://fluxcd.io/flux/concepts/
#    - GitOps WG docs ....... https://github.com/open-gitops/documents
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Paths (override the lab location with CNPA_LAB_DIR=/path ./break_fix.sh ...)
# ------------------------------------------------------------------------------
SAFE_BASE="${HOME}/cnpa-lab"
LAB="${CNPA_LAB_DIR:-${SAFE_BASE}/3.5}"
REPO="${LAB}/app-config"                              # Git: the source of truth
MANIFEST="${REPO}/deploy/web-deployment.yaml"         # desired state (a real k8s Deployment)
REG_FILE="${LAB}/registry/registry.local_web.tags"    # artifact registry (one tag per line)
CI_LOG="${LAB}/ci/build-log.txt"                       # CI provenance / build records
LIVE="${LAB}/cluster/live-state.txt"                   # live cluster state (what is actually running)

BAD_TAG="v1.5.0"        # the tag CI committed to Git but never pushed to the registry
GOOD_TAG="v1.4.2"       # the last artifact that actually exists in the registry

# ------------------------------------------------------------------------------
# Pretty output
# ------------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
  C_B=$'\033[1;34m'; C_D=$'\033[2m'
else
  C_RST=''; C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''
fi
log()  { printf '%s[+]%s %s\n' "$C_G" "$C_RST" "$*"; }
info() { printf '%s[i]%s %s\n' "$C_B" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_RST" "$*" >&2; }
hr()   { printf '%s%s%s\n' "$C_D" "----------------------------------------------------------------------" "$C_RST"; }

need() { command -v "$1" >/dev/null 2>&1 || { err "missing dependency: $1"; exit 3; }; }

# ------------------------------------------------------------------------------
# Registry helpers  (models a container registry; CI is the only writer)
# ------------------------------------------------------------------------------
registry_has() { grep -qxF "$1" "$REG_FILE" 2>/dev/null; }

digest_of() { printf 'sha256:%s' "$(printf 'registry.local/web:%s' "$1" | sha256sum | cut -c1-16)"; }

ci_push() {   # models CI's "build & push" stage: publish an immutable artifact
  local tag="${1:-}"
  [ -n "$tag" ] || { err "usage: $0 ci-push <tag>   (e.g. $0 ci-push ${BAD_TAG})"; return 2; }
  ensure_setup
  if registry_has "$tag"; then
    info "registry already contains registry.local/web:${tag} — nothing to push"
    return 0
  fi
  printf '%s\n' "$tag" >> "$REG_FILE"
  printf 'build=push tag=%s digest=%s\n' "$tag" "$(digest_of "$tag")" >> "$CI_LOG"
  log "CI: built and pushed registry.local/web:${tag} ($(digest_of "$tag"))"
}

# ------------------------------------------------------------------------------
# Git / desired-state helpers  (the source of truth)
# ------------------------------------------------------------------------------
git_repo() { git -C "$REPO" "$@"; }

write_manifest() {   # (re)write the Deployment with a given image tag
  local tag="$1"
  mkdir -p "$(dirname "$MANIFEST")"
  cat > "$MANIFEST" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: storefront
  labels:
    app: web
    app.kubernetes.io/managed-by: gitops
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: registry.local/web:${tag}
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
YAML
}

# Read the desired tag from Git HEAD — only what is COMMITTED is desired state.
# (Uncommitted edits in the working tree are invisible to the reconciler, by design.)
desired_tag() {
  git_repo show HEAD:deploy/web-deployment.yaml 2>/dev/null \
    | awk -F'web:' '/image: registry\.local\/web:/{gsub(/[[:space:]]/,"",$2); print $2; exit}'
}

live_tag() { cat "$LIVE" 2>/dev/null || true; }

# ------------------------------------------------------------------------------
# CD reconciler  (models one Argo CD / Flux reconcile loop — pull based)
# ------------------------------------------------------------------------------
reconcile() {
  ensure_setup
  local d rev
  d="$(desired_tag)"; rev="$(git_repo rev-parse --short HEAD)"
  [ -n "$d" ] || { err "reconciler could not read desired image from Git"; return 1; }
  echo "[reconcile] app=web  repo=app-config  revision=${rev}"
  echo "[reconcile] desired image (Git HEAD): registry.local/web:${d}"
  if registry_has "$d"; then
    echo "[reconcile] pull registry.local/web:${d} ... OK ($(digest_of "$d"))"
    printf '%s\n' "$d" > "$LIVE"
    echo "[reconcile] apply -> namespace/storefront deployment/web ... 3/3 replicas Ready"
    echo "${C_G}[reconcile] result: Sync=Synced  Health=Healthy  (live registry.local/web:${d})${C_RST}"
    return 0
  fi
  echo "[reconcile] pull registry.local/web:${d} ... ${C_R}NOT FOUND${C_RST} (ErrImagePull -> ImagePullBackOff)"
  echo "[reconcile] live state left unchanged (a reconciler never deploys an artifact it cannot pull)"
  echo "${C_R}[reconcile] result: Sync=OutOfSync  Health=Degraded  (live registry.local/web:$(live_tag))${C_RST}"
  return 1
}

# ------------------------------------------------------------------------------
# Status — the diagnostic the student uses to see the four planes at once
# ------------------------------------------------------------------------------
status() {
  ensure_setup
  local d l img_ok sync health reason regtags
  d="$(desired_tag)"; l="$(live_tag)"
  regtags="$(tr '\n' ' ' < "$REG_FILE" 2>/dev/null || true)"
  if registry_has "$d"; then img_ok=1; else img_ok=0; fi
  if [ "$l" = "$d" ]; then sync="Synced"; else sync="OutOfSync"; fi
  if [ "$img_ok" -eq 0 ]; then
    health="Degraded"; reason="ErrImagePull: registry.local/web:${d} not present in registry"
  elif [ "$sync" = "Synced" ]; then
    health="Healthy"; reason="live == desired == registry.local/web:${d}"
  else
    health="Progressing"; reason="artifact exists; run 'reconcile' to converge"
  fi
  hr
  printf '  %sApplication:%s web   %sNamespace:%s storefront\n' "$C_B" "$C_RST" "$C_B" "$C_RST"
  printf '  %-22s %s\n' "CI last build:"      "$(tail -n1 "$CI_LOG" 2>/dev/null || echo '(none)')"
  printf '  %-22s %s\n' "Artifact registry:"  "registry.local/web -> ${regtags}"
  printf '  %-22s %s\n' "Git desired (truth):" "registry.local/web:${d}  @ $(git_repo rev-parse --short HEAD)"
  printf '  %-22s %s\n' "Live cluster state:" "registry.local/web:${l}"
  if [ "$health" = "Healthy" ]; then
    printf '  %-22s %sSync=%s  Health=%s%s\n' "Status:" "$C_G" "$sync" "$health" "$C_RST"
  else
    printf '  %-22s %sSync=%s  Health=%s%s\n' "Status:" "$C_R" "$sync" "$health" "$C_RST"
  fi
  printf '  %-22s %s\n' "Reason:" "$reason"
  hr
}

# ------------------------------------------------------------------------------
# Setup — build a healthy, converged lab (idempotent)
# ------------------------------------------------------------------------------
ensure_setup() {
  [ -f "$MANIFEST" ] && [ -d "$REPO/.git" ] && return 0
  need git
  info "provisioning lab in ${LAB}"
  mkdir -p "$LAB" "$REPO/deploy" "$(dirname "$REG_FILE")" "$(dirname "$CI_LOG")" "$(dirname "$LIVE")"

  # A tiny artifact registry that already holds a few immutable, released tags.
  printf 'v1.4.0\nv1.4.1\n%s\n' "$GOOD_TAG" > "$REG_FILE"
  printf 'build=push tag=v1.4.0 digest=%s\n' "$(digest_of v1.4.0)"  > "$CI_LOG"
  printf 'build=push tag=v1.4.1 digest=%s\n' "$(digest_of v1.4.1)" >> "$CI_LOG"
  printf 'build=push tag=%s digest=%s\n' "$GOOD_TAG" "$(digest_of "$GOOD_TAG")" >> "$CI_LOG"

  # The GitOps source-of-truth repository, pinned to a real, released artifact.
  git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO"; git_repo checkout -q -b main; }
  git_repo config user.email "ci-bot@cnpa.local"
  git_repo config user.name  "CNPA CI Bot"
  git_repo config commit.gpgsign false
  write_manifest "$GOOD_TAG"
  git_repo add deploy/web-deployment.yaml
  git_repo commit -q -m "platform: seed web Deployment pinned to ${GOOD_TAG}"

  # Reconcile once so the cluster starts converged and Healthy.
  reconcile >/dev/null
  log "lab ready — starting state is Synced/Healthy on registry.local/web:${GOOD_TAG}"
}

# ------------------------------------------------------------------------------
# BREAK — inject the incident
# ------------------------------------------------------------------------------
break_lab() {
  ensure_setup
  # Idempotent: if already broken, just re-surface the symptom.
  if [ "$(desired_tag)" = "$BAD_TAG" ] && ! registry_has "$BAD_TAG"; then
    warn "incident already injected — re-showing the symptom"
  else
    # CI build #4207: the 'bump-manifest' stage committed a new desired tag to
    # Git, but the preceding 'build-and-push' stage failed, so the artifact was
    # never published. The broken CI/CD handoff is now committed to the truth.
    write_manifest "$BAD_TAG"
    git_repo add deploy/web-deployment.yaml
    git_repo commit -q -m "ci: bump web image to ${BAD_TAG} (build #4207) [skip-push glitch]"
    printf 'build=FAILED stage=build-and-push tag=%s (image NOT pushed)\n' "$BAD_TAG" >> "$CI_LOG"
  fi

  echo
  reconcile || true          # surface the failing reconcile in the output
  echo

  hr
  printf '%s              INCIDENT INJECTED — Topic 3.5 CI/CD Integration%s\n' "$C_R" "$C_RST"
  hr
  cat <<TXT
WHAT JUST HAPPENED (the break)
  CI pipeline 'web' ran build #4207. Its manifest-bump stage committed a new
  desired image tag (${BAD_TAG}) into the app-config Git repo — the source of
  truth your GitOps controller reconciles from — but the build-and-push stage
  that should have published that image FAILED. CI is "green", Git says
  ${BAD_TAG}, and the artifact does not exist in the registry.

SYMPTOM YOU WILL SEE  (run: ${0##*/} status)
  * Git desired image : registry.local/web:${BAD_TAG}   (source of truth)
  * Registry          : v1.4.0 v1.4.1 ${GOOD_TAG}        (NO ${BAD_TAG})
  * Live cluster      : registry.local/web:${GOOD_TAG}   (frozen at the old rev)
  * Sync=OutOfSync  Health=Degraded  reason=ErrImagePull -> ImagePullBackOff
  This is the textbook "the pipeline is green but production never moved"
  incident. CI and CD are two decoupled systems; the handoff between them broke.

YOUR OBJECTIVE (the fix)
  Drive the application back to Sync=Synced / Health=Healthy with
  Live == Desired AND the desired image actually present in the registry.
  Fix it the CI/CD way — through the artifact registry and/or the Git source of
  truth — then let the reconciler apply it. Do NOT hand-edit the live state:
  an out-of-band imperative change is configuration drift, and a reconcile will
  revert it (go ahead, edit ${LIVE} and run reconcile to prove it to yourself).

  Tools on the bench:
    ${0##*/} status          # inspect all four planes + Sync/Health
    ${0##*/} ci-push <tag>   # CI's other half: publish an artifact
    ${0##*/} reconcile       # run one GitOps reconcile loop (CD)
    git -C ${REPO} log|revert|show   # the source of truth is a real git repo

  Grade yourself:
    ${0##*/} verify
TXT
  hr
}

# ------------------------------------------------------------------------------
# VERIFY — did the student converge the system correctly?
# ------------------------------------------------------------------------------
verify() {
  ensure_setup
  local d
  d="$(desired_tag)"
  echo "Desired (Git source of truth): registry.local/web:${d}"
  if ! registry_has "$d"; then
    err "FAIL: registry.local/web:${d} does not exist in the registry."
    err "      The reconciler cannot pull it -> ImagePullBackOff; the app stays Degraded/OutOfSync."
    err "      Either publish that artifact (ci-push) or re-pin the truth to a released tag (git revert),"
    err "      then reconcile. Do not edit live state by hand."
    return 1
  fi
  reconcile >/dev/null
  if [ "$(live_tag)" = "$d" ]; then
    log "PASS: Sync=Synced  Health=Healthy — live == desired == registry.local/web:${d}, artifact present."
    return 0
  fi
  err "FAIL: after reconcile, live ($(live_tag)) != desired (${d})."
  return 1
}

# ------------------------------------------------------------------------------
# RESET — remove the lab (guarded so it can only delete inside the lab base)
# ------------------------------------------------------------------------------
reset_lab() {
  case "$LAB" in
    "${SAFE_BASE}"/*|/tmp/*) : ;;
    *) err "refusing to delete '${LAB}' — not under ${SAFE_BASE} or /tmp"; exit 4 ;;
  esac
  [ -n "$LAB" ] && [ "$LAB" != "/" ] || { err "unsafe lab path"; exit 4; }
  rm -rf "$LAB"
  log "removed ${LAB}"
}

usage() {
  cat <<TXT
CNPA 3.5 — CI/CD Relationship Fundamentals and Integration — break & fix

Usage: ${0##*/} <command>

  (no args) | run   provision the lab, inject the incident, print the briefing
  setup             provision a healthy, converged lab only
  break             inject the incident (idempotent)
  status            show CI / registry / Git / live planes + Sync & Health
  reconcile         run one CD (GitOps) reconcile loop
  ci-push <tag>     run CI's build-and-push stage: publish an artifact
  verify            check whether you converged the system correctly
  reset             delete the lab directory (${LAB})
  help              this text
TXT
}

main() {
  case "${1:-run}" in
    run|"")     ensure_setup; break_lab ;;
    setup)      ensure_setup ;;
    break)      break_lab ;;
    status)     status ;;
    reconcile)  reconcile ;;
    ci-push)    shift; ci_push "${1:-}" ;;
    verify)     verify ;;
    reset|clean) reset_lab ;;
    help|-h|--help) usage ;;
    *) err "unknown command: $1"; usage; exit 2 ;;
  esac
}

main "$@"
exit $?

# ==============================================================================
#  SOLUTION — step by step (commented; do not read until you have tried)
# ==============================================================================
#
#  DIAGNOSIS
#  ---------
#  1. Look at all four planes at once:
#
#         ./break_fix.sh status
#
#     You will see Git desired = registry.local/web:v1.5.0, but the registry
#     only lists v1.4.0 v1.4.1 v1.4.2, and Live is still v1.4.2. Status is
#     Sync=OutOfSync / Health=Degraded with reason ErrImagePull.
#
#  2. Confirm the reconciler is behaving correctly (it is — a CD controller must
#     never deploy an artifact it cannot pull):
#
#         ./break_fix.sh reconcile
#         # -> pull registry.local/web:v1.5.0 ... NOT FOUND (ErrImagePull)
#
#  3. Read the source of truth's history to see what CI did:
#
#         git -C ~/cnpa-lab/3.5/app-config log --oneline
#         # ci: bump web image to v1.5.0 (build #4207) [skip-push glitch]
#         # platform: seed web Deployment pinned to v1.4.2
#
#     Root cause: CI committed the desired-state change (image bump) but its
#     build-and-push stage failed, so v1.5.0 was never published. The CI->CD
#     handoff is inconsistent: Git points at an artifact that does not exist.
#
#  FIX — choose ONE of the two legitimate GitOps remediations:
#
#  Option A — ROLL FORWARD (finish what CI started; keep v1.5.0):
#     Re-run CI's build-and-push stage to actually publish the artifact Git
#     already asks for, then reconcile:
#
#         ./break_fix.sh ci-push v1.5.0
#         ./break_fix.sh reconcile
#         ./break_fix.sh verify
#         # -> PASS: Sync=Synced Health=Healthy on registry.local/web:v1.5.0
#
#  Option B — ROLL BACK (re-pin the truth to the last good, released artifact):
#     Revert the bad commit in Git so the desired tag is v1.4.2 again (which
#     exists), then reconcile:
#
#         git -C ~/cnpa-lab/3.5/app-config revert --no-edit HEAD
#         ./break_fix.sh reconcile
#         ./break_fix.sh verify
#         # -> PASS: Sync=Synced Health=Healthy on registry.local/web:v1.4.2
#
#  WHY NOT just edit the live state?
#     Editing ~/cnpa-lab/3.5/cluster/live-state.txt (the equivalent of
#     `kubectl set image ...` out of band) is an imperative change that bypasses
#     Git. It creates drift: the next reconcile compares live against the Git
#     source of truth and reverts your change. In GitOps you always fix the
#     source of truth (or the artifact it references), never the running system.
#
#  KEY TAKEAWAYS (CNPA 3.5)
#     * CI and CD are decoupled systems; their handoff is the artifact registry
#       plus the Git desired-state repo. Order matters: publish the immutable
#       artifact BEFORE (or atomically with) committing the tag that references
#       it — otherwise "green pipeline, stale production".
#     * CD is pull-based reconciliation toward a declared desired state; Git is
#       the single source of truth (OpenGitOps: declarative, versioned &
#       immutable, pulled automatically, continuously reconciled).
#     * Recover by roll-forward (publish the artifact) or rollback (revert the
#       commit) — both act on the source of truth, never on the live cluster.
#
#  CLEANUP
#         ./break_fix.sh reset
# ==============================================================================