#!/usr/bin/env bash
#
# ==============================================================================
#  CNPA 3.7 — GitOps for Multi-Environment Application Management
#  Break & Fix laboratory  (exam version 2025-04-01, domain weight 2.25)
# ==============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  A GitOps platform delivers ONE application to MANY environments (dev, staging,
#  prod) from a single declarative source of truth in Git. The canonical layout
#  is a Kustomize "base" (the app, shared by every environment) plus one "overlay"
#  per environment (namespace, replica count, image tag, hardening patches). A
#  GitOps reconciler — Argo CD or Flux — renders each overlay and drives the live
#  cluster toward the rendered manifests, per environment, independently.
#
#  The failure mode this lab reproduces is the single most common multi-env
#  GitOps incident: a change promoted into ONE overlay (prod) that renders
#  cleanly nowhere else, so the reconciler for that ONE environment stops while
#  the others stay green. The blast radius is contained (that is the point of
#  per-environment overlays), and the diagnosis lives entirely in Git + the
#  render step — never in a running Pod.
#
#  This script is SAFE and DISPOSABLE. It only:
#    * writes under a dedicated lab directory ($HOME/cnpa-3.7-gitops-lab)
#    * creates namespaces prefixed  cnpa37-  (dev/staging/prod)
#  It never touches any pre-existing workload. Tear everything down with:
#      ./break_fix.sh --cleanup
#
#  Reference sources (official):
#    * OpenGitOps principles ...... https://opengitops.dev/
#    * Argo CD .................... https://argo-cd.readthedocs.io/en/stable/
#    * Flux ...................... https://fluxcd.io/flux/
#    * Kustomize ................. https://kubectl.docs.kubernetes.io/references/kustomize/
#    * CNPA curriculum ........... https://github.com/cncf/curriculum
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
LAB_DIR="${CNPA_LAB_DIR:-$HOME/cnpa-3.7-gitops-lab}"
NS_PREFIX="cnpa37-"
ENVIRONMENTS=(dev staging prod)
APP="web"

# ------------------------------------------------------------------------------
# Pretty logging
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi
log()  { printf '%s[*]%s %s\n'  "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
rule() { printf '%s%s%s\n' "$C_BLD" "------------------------------------------------------------------------------" "$C_RST"; }

# ------------------------------------------------------------------------------
# Guard against operating on a dangerous path
# ------------------------------------------------------------------------------
case "$LAB_DIR" in
  ""|"/"|"$HOME") die "Refusing to use LAB_DIR='$LAB_DIR' — set CNPA_LAB_DIR to a dedicated path." ;;
esac

# ------------------------------------------------------------------------------
# Tooling detection
# ------------------------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git is required."

detect_kustomize() {
  if command -v kustomize >/dev/null 2>&1; then
    KBUILD=(kustomize build)
  elif command -v kubectl >/dev/null 2>&1; then
    # kubectl >=1.27 embeds kustomize v5 (supports labels/replicas/patches transformers)
    KBUILD=(kubectl kustomize)
  else
    die "Need either 'kustomize' or 'kubectl' on PATH to render overlays."
  fi
}

have_cluster() { command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# Cleanup subcommand
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" || "${1:-}" == "clean" ]]; then
  log "Tearing down the CNPA 3.7 lab..."
  if have_cluster; then
    for e in "${ENVIRONMENTS[@]}"; do
      kubectl delete namespace "${NS_PREFIX}${e}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    ok "Namespaces ${NS_PREFIX}{dev,staging,prod} scheduled for deletion."
  fi
  rm -rf "$LAB_DIR"
  ok "Removed $LAB_DIR"
  exit 0
fi

detect_kustomize

# ------------------------------------------------------------------------------
# Fresh scaffold (idempotent: recreated on every run for a clean start)
# ------------------------------------------------------------------------------
if [[ -d "$LAB_DIR" ]]; then
  warn "Existing lab dir found — recreating for a clean start: $LAB_DIR"
  rm -rf "$LAB_DIR"
fi
mkdir -p "$LAB_DIR"/{base,overlays/dev,overlays/staging,overlays/prod}

log "Scaffolding the GitOps monorepo (base + 3 environment overlays)..."

# ---- base: the application, shared by every environment -----------------------
cat > "$LAB_DIR/base/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
YAML

cat > "$LAB_DIR/base/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 1
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
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
YAML

cat > "$LAB_DIR/base/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: web
  labels:
    app: web
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
YAML

# ---- overlay: dev -------------------------------------------------------------
cat > "$LAB_DIR/overlays/dev/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpa37-dev
resources:
  - ../../base
labels:
  - pairs:
      env: dev
    includeSelectors: false
replicas:
  - name: web
    count: 1
YAML

# ---- overlay: staging ---------------------------------------------------------
cat > "$LAB_DIR/overlays/staging/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpa37-staging
resources:
  - ../../base
labels:
  - pairs:
      env: staging
    includeSelectors: false
replicas:
  - name: web
    count: 2
YAML

# ---- overlay: prod (base + replica bump + a "hardening" strategic-merge patch) -
cat > "$LAB_DIR/overlays/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpa37-prod
resources:
  - ../../base
labels:
  - pairs:
      env: prod
    includeSelectors: false
replicas:
  - name: web
    count: 3
patches:
  - path: hardening-patch.yaml
YAML

# GOOD version of the prod patch: metadata.name == "web" -> matches the base Deployment
cat > "$LAB_DIR/overlays/prod/hardening-patch.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  template:
    metadata:
      annotations:
        platform.cncf.io/hardened: "true"
    spec:
      containers:
        - name: web
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
YAML

# ------------------------------------------------------------------------------
# Initialise Git — the GitOps source of truth. The baseline commit is healthy.
# ------------------------------------------------------------------------------
git -C "$LAB_DIR" init -q
git -C "$LAB_DIR" config user.email "lab@cnpa.local"
git -C "$LAB_DIR" config user.name  "CNPA Lab"
git -C "$LAB_DIR" add -A
git -C "$LAB_DIR" commit -qm "platform: baseline app for dev/staging/prod (healthy)"
ok "Baseline commit created (all three environments render cleanly)."

# ------------------------------------------------------------------------------
# Sanity: prove the baseline is green before we break it
# ------------------------------------------------------------------------------
log "Verifying baseline renders for every environment..."
for e in "${ENVIRONMENTS[@]}"; do
  if "${KBUILD[@]}" "$LAB_DIR/overlays/$e" >/dev/null 2>&1; then
    ok "overlay/$e renders OK"
  else
    warn "overlay/$e failed to render at baseline — your kustomize may be too old (need v5 / kubectl >=1.27)."
  fi
done

# ==============================================================================
#  THE BREAK  (a realistic bad promotion, committed to Git like the real thing)
# ==============================================================================
#  Someone "promoted" a change to the PROD overlay only. During the promotion the
#  patched workload was accidentally renamed (web -> web-app) inside prod's
#  strategic-merge patch. The patch now targets a Deployment that does not exist
#  in the base, so Kustomize cannot find a unique target and refuses to render
#  the prod overlay. dev and staging are untouched and stay perfectly healthy.
# ------------------------------------------------------------------------------
log "Applying a bad promotion to the prod overlay only..."
cat > "$LAB_DIR/overlays/prod/hardening-patch.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app          # <-- WRONG: base Deployment is named "web", not "web-app"
spec:
  template:
    metadata:
      annotations:
        platform.cncf.io/hardened: "true"
    spec:
      containers:
        - name: web
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
YAML
git -C "$LAB_DIR" add -A
git -C "$LAB_DIR" commit -qm "prod: promote hardening patch v2 (resource limits)" >/dev/null
ok "Bad promotion committed as HEAD."

# ------------------------------------------------------------------------------
# Emit reconcile.sh — a tiny stand-in for the Argo CD / Flux reconciler. It
# renders every overlay and (if a cluster is reachable) syncs it, then prints an
# Argo-CD-style status table. The student re-runs THIS after each fix attempt.
# ------------------------------------------------------------------------------
cat > "$LAB_DIR/reconcile.sh" <<'RECONCILE'
#!/usr/bin/env bash
# Minimal GitOps reconciler: render each environment overlay from Git and drive
# the cluster toward it, independently per environment. Mirrors `argocd app sync`
# / `flux reconcile kustomization`. Exits non-zero if ANY environment is drifted.
set -uo pipefail
cd "$(dirname "$0")"

ENVIRONMENTS=(dev staging prod)
NS_PREFIX="cnpa37-"

if command -v kustomize >/dev/null 2>&1; then KBUILD=(kustomize build)
elif command -v kubectl >/dev/null 2>&1; then KBUILD=(kubectl kustomize)
else echo "Need kustomize or kubectl on PATH." >&2; exit 2; fi

HAVE_CLUSTER=0
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then HAVE_CLUSTER=1; fi

mkdir -p .render
FAIL=0
declare -A RENDER SYNC HEALTH
LAST_ERR=""

for e in "${ENVIRONMENTS[@]}"; do
  ns="${NS_PREFIX}${e}"
  if "${KBUILD[@]}" "overlays/$e" > ".render/$e.yaml" 2> ".render/$e.err"; then
    RENDER[$e]="OK"
    if [[ "$HAVE_CLUSTER" == "1" ]]; then
      kubectl create namespace "$ns" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 || true
      kubectl apply -f ".render/$e.yaml" >/dev/null 2>&1 || true
      if kubectl -n "$ns" rollout status deploy/web --timeout=90s >/dev/null 2>&1; then
        SYNC[$e]="Synced"; HEALTH[$e]="Healthy"
      else
        SYNC[$e]="Synced"; HEALTH[$e]="Progressing"
      fi
    else
      SYNC[$e]="Synced(dry)"; HEALTH[$e]="n/a"
    fi
  else
    RENDER[$e]="FAILED"; SYNC[$e]="OutOfSync"; HEALTH[$e]="Missing"; FAIL=1
    LAST_ERR="$(tr -d '\r' < ".render/$e.err")"
  fi
done

printf '\n%-10s  %-8s  %-12s  %-12s\n' "ENV" "RENDER" "SYNC" "HEALTH"
printf '%-10s  %-8s  %-12s  %-12s\n' "----------" "--------" "------------" "------------"
for e in "${ENVIRONMENTS[@]}"; do
  printf '%-10s  %-8s  %-12s  %-12s\n' "$e" "${RENDER[$e]}" "${SYNC[$e]}" "${HEALTH[$e]}"
done
echo

if [[ "$FAIL" == "1" ]]; then
  echo "ComparisonError — reconciliation is blocked for at least one environment."
  echo "Reconciler error (verbatim):"
  echo "--------------------------------------------------------------------------"
  echo "$LAST_ERR"
  echo "--------------------------------------------------------------------------"
  exit 1
fi
echo "All environments Synced. Fleet is converged with Git."
exit 0
RECONCILE
chmod +x "$LAB_DIR/reconcile.sh"

# ------------------------------------------------------------------------------
# Run the reconciler once so the student sees the symptom immediately
# ------------------------------------------------------------------------------
rule
log "Running the reconciler against the current Git HEAD..."
set +e
"$LAB_DIR/reconcile.sh"
set -e
rule

# ------------------------------------------------------------------------------
# Student briefing
# ------------------------------------------------------------------------------
cat <<BRIEF

${C_BLD}CNPA 3.7 — GitOps for Multi-Environment Application Management — BREAK & FIX${C_RST}

  Lab directory : $LAB_DIR
  GitOps repo   : base/ + overlays/{dev,staging,prod}/  (Kustomize)
  Reconciler    : $LAB_DIR/reconcile.sh   (stands in for Argo CD / Flux)
  Cluster       : $( have_cluster && echo "reachable — environments are synced to namespaces ${NS_PREFIX}*" || echo "not reachable — render-only mode (still fully diagnosable)" )

${C_BLD}SYMPTOM YOU WILL SEE${C_RST}
  * The reconciler status table shows dev=Synced/Healthy, staging=Synced/Healthy,
    but ${C_RED}prod=OutOfSync/Missing with RENDER=FAILED${C_RST}.
  * Re-running ./reconcile.sh prints a ComparisonError, NOT a crashing Pod:
        "no matches for Id apps_v1_Deployment|~X|web-app;
         failed to find unique target for patch"
  * With a live cluster:  kubectl get deploy -n ${NS_PREFIX}prod  ->  "No resources found".
    (prod never even got rendered, so nothing was applied — dev/staging are fine.)

${C_BLD}WHY IT MATTERS${C_RST}
  This is a manifest/render failure introduced by a bad promotion into a single
  overlay. In real Argo CD this surfaces as the Application "prod" going to
  Unknown/ComparisonError; in Flux as the Kustomization "prod" reporting
  BuildFailed. The other environments keep reconciling — that isolation is the
  whole reason each environment is its own overlay/Application.

${C_BLD}YOUR OBJECTIVE${C_RST}
  Make ./reconcile.sh exit 0 with ALL THREE environments Synced, WITHOUT
  weakening the other overlays, and following GitOps discipline — the fix must be
  a commit in Git, because Git is the source of truth. When you are done:
      * prod must render with 3 replicas AND keep the hardening patch
        (resource limits/requests) applied to the "web" Deployment
      * dev must still be 1 replica, staging still 2 replicas
      * git log must show your fix as a commit on top of the bad promotion

${C_BLD}INVESTIGATE WITH${C_RST}
      cd $LAB_DIR
      ./reconcile.sh                          # see the failing environment
      ${KBUILD[*]} overlays/prod              # reproduce the raw Kustomize error
      git -C . log --oneline                  # find the promotion commit
      git -C . show HEAD                       # read exactly what changed
      # (Argo CD equivalents: argocd app get prod ; argocd app diff prod)

BRIEF

ok "Lab is armed. Diagnose it, fix it in Git, then re-run ./reconcile.sh."
exit 0

# ==============================================================================
#  SOLUTION — do not read until you have tried it yourself
# ==============================================================================
#
#  STEP 0 — Confirm the blast radius is a single environment
#  --------------------------------------------------------
#    cd "$LAB_DIR"
#    ./reconcile.sh
#      ENV         RENDER    SYNC          HEALTH
#      dev         OK        Synced        Healthy
#      staging     OK        Synced        Healthy
#      prod        FAILED    OutOfSync     Missing
#
#    Only prod is broken. In a real platform this is your first, most important
#    read: dev and staging are Synced, so the base app and the reconciler are
#    fine — the fault is localised to something the prod overlay adds.
#
#  STEP 1 — Reproduce the raw render error (this is the ground truth)
#  -----------------------------------------------------------------
#    kustomize build overlays/prod          # or: kubectl kustomize overlays/prod
#
#    Error: trouble configuring builtin PatchTransformer ...
#      no matches for Id apps_v1_Deployment|~X|web-app;
#      failed to find unique target for patch apps/v1/Deployment/web-app
#
#    Translation: prod applies a strategic-merge patch whose target is a
#    Deployment named "web-app", but no such object exists in the base. Kustomize
#    derives the patch target from the patch's own kind + metadata.name when no
#    explicit `target:` is given, so the name MUST match a real resource.
#
#  STEP 2 — Find WHO introduced it and WHAT changed (Git is the audit log)
#  ----------------------------------------------------------------------
#    git log --oneline
#      <sha2> prod: promote hardening patch v2 (resource limits)   <- HEAD, suspect
#      <sha1> platform: baseline app for dev/staging/prod (healthy)
#
#    git show HEAD
#      -  name: web
#      +  name: web-app          # the accidental rename during promotion
#
#    Root cause: the promotion renamed the patch target from "web" to "web-app".
#    The base Deployment is "web"; the overlay must patch "web".
#
#  STEP 3 — Fix it. Two GitOps-valid options; pick ONE.
#  ----------------------------------------------------
#    Option A — targeted correction (keep the hardening patch, fix the name):
#        sed -i 's/name: web-app/name: web/' overlays/prod/hardening-patch.yaml
#        git commit -am "fix(prod): correct hardening patch target web-app -> web"
#
#    Option B — clean rollback of the bad promotion (pure GitOps revert):
#        git revert --no-edit HEAD
#      (Prefer this when the whole promotion is suspect. Note it also reverts the
#       intended hardening; if you want the limits kept, use Option A instead.)
#
#    Either way the fix is a COMMIT. Never hand-edit the live cluster to "make it
#    green" — the reconciler would just drift it back. Fix the source of truth.
#
#  STEP 4 — Reconcile and verify convergence
#  -----------------------------------------
#    ./reconcile.sh
#      ENV         RENDER    SYNC       HEALTH
#      dev         OK        Synced     Healthy
#      staging     OK        Synced     Healthy
#      prod        OK        Synced     Healthy
#      -> "All environments Synced. Fleet is converged with Git."   (exit 0)
#
#    Prove the environment-specific values are all still correct:
#      kustomize build overlays/dev     | grep -E 'replicas:'                 # 1
#      kustomize build overlays/staging | grep -E 'replicas:'                 # 2
#      kustomize build overlays/prod    | grep -E 'replicas:'                 # 3
#      kustomize build overlays/prod    | grep -A6 'resources:'               # limits present
#      kustomize build overlays/prod    | grep 'platform.cncf.io/hardened'    # patch applied
#
#    On a live cluster:
#      kubectl get deploy -n cnpa37-prod    # web now exists, 3/3 ready
#      kubectl get pods    -A -l env=prod
#
#  STEP 5 — Tear down
#  ------------------
#    ./break_fix.sh --cleanup
#
#  KEY TAKEAWAYS (exam-relevant)
#  -----------------------------
#    * Multi-env GitOps = one base + one overlay per environment; a bad change in
#      one overlay fails ONLY that environment. Read the fault as "which overlay",
#      not "which Pod".
#    * A ComparisonError / BuildFailed is a RENDER problem, upstream of the
#      cluster. `kustomize build <overlay>` (or `argocd app manifests`) reproduces
#      it deterministically without touching the cluster.
#    * Kustomize `patches` without an explicit `target:` match by kind+name; the
#      patch metadata.name must equal a real resource name in the accumulated set.
#    * The fix is always a Git commit (correct or revert). The live cluster is a
#      projection of Git; you never fix it by hand — the reconciler self-heals to
#      whatever Git says.
#    * Argo CD mapping: Application=ComparisonError -> argocd app get/diff/manifests
#      -> fix in Git -> app auto-syncs (or `argocd app sync prod`).
#      Flux mapping:   Kustomization=BuildFailed -> flux get kustomizations
#      -> fix in Git -> `flux reconcile kustomization prod --with-source`.
# ==============================================================================