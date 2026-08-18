#!/usr/bin/env bash
# =============================================================================
# CGOA — Domain 2, Topic 2.1: GitOps Principles & Practices (exam weight 25%)
# Break & Fix Lab: "The Friday Night Hotfix"
# =============================================================================
#
# WHAT THIS LAB TEACHES
#   The four OpenGitOps v1.0.0 principles, by making you live through their
#   violation and repair:
#     1. Declarative        — desired state is expressed declaratively
#     2. Versioned & Immutable — desired state is stored in Git (versioned,
#                              immutable, complete history)
#     3. Pulled Automatically — software agents PULL the desired state
#     4. Continuously Reconciled — agents continuously observe actual state
#                              and drive it towards desired state
#
#   Sources (official):
#     - https://opengitops.dev/  (principles v1.0.0)
#     - https://github.com/open-gitops/documents
#     - https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
#     - https://fluxcd.io/flux/concepts/          (real-world reconciler)
#     - https://argo-cd.readthedocs.io/en/stable/ (real-world reconciler)
#
# ARCHITECTURE OF THE LAB
#   To keep the mechanics fully visible (this topic is about PRINCIPLES, not a
#   specific tool), the GitOps agent here is a deliberately minimal ~30-line
#   pull-and-apply loop, playing the role of Flux's kustomize-controller or
#   Argo CD's application-controller:
#
#     $LAB_DIR/platform.git      -> bare repo, the "origin" (source of truth)
#     $LAB_DIR/dev-clone         -> your working clone (how changes are made)
#     $LAB_DIR/agent-checkout    -> the agent's private checkout (pull target)
#     $LAB_DIR/bin/reconciler.sh -> the agent: fetch -> reset --hard -> apply,
#                                   every 15 seconds, forever
#
# SAFETY
#   This script mutates a Kubernetes cluster. It refuses to run unless the
#   current kubectl context looks like a disposable lab cluster
#   (kind-*, k3d-*, minikube, k3s "default"). Run it ONLY in a throwaway VM.
#
# USAGE
#   ./cgoa-2.1-break-fix.sh run      # set everything up, then break it
#   ./cgoa-2.1-break-fix.sh status   # compare Git desired state vs live state
#   ./cgoa-2.1-break-fix.sh verify   # PASS/FAIL check of your fix
#   ./cgoa-2.1-break-fix.sh reset    # tear everything down
#
# The full step-by-step solution is COMMENTED AT THE END of this file.
# Do not read it until you have tried the exercise.
# =============================================================================

set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/cgoa-lab-2.1}"
NS="gitops-lab"
APP="webapp"
BARE="$LAB_DIR/platform.git"
CLONE="$LAB_DIR/dev-clone"
CHECKOUT="$LAB_DIR/agent-checkout"
RECONCILER="$LAB_DIR/bin/reconciler.sh"
PIDFILE="$LAB_DIR/reconciler.pid"
LOGFILE="$LAB_DIR/reconciler.log"
INTERVAL=15
CONVERGE_TIMEOUT=180

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight: tools, cluster reachability, and the lab-only safety gate
# -----------------------------------------------------------------------------
preflight() {
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
  kubectl cluster-info >/dev/null 2>&1 \
    || die "no reachable cluster. Create one first, e.g.: kind create cluster --name cgoa-lab"

  KCTX="$(kubectl config current-context)"
  case "$KCTX" in
    kind-*|k3d-*|minikube*|k3s*|default) : ;;
    *)
      if [ "${CGOA_LAB_UNSAFE_CONTEXT_OK:-0}" != "1" ]; then
        die "current context '$KCTX' does not look like a disposable lab cluster. Refusing. (Override only if you are SURE: CGOA_LAB_UNSAFE_CONTEXT_OK=1)"
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Phase 1 — Build a working GitOps loop (all four principles in action)
# -----------------------------------------------------------------------------
setup() {
  [ -e "$LAB_DIR" ] && die "$LAB_DIR already exists. Run '$0 reset' first."

  say "Creating source-of-truth repository (Principle 2: versioned & immutable)"
  mkdir -p "$LAB_DIR/bin"
  git init --bare -q -b main "$BARE" 2>/dev/null \
    || { git init --bare -q "$BARE"; git -C "$BARE" symbolic-ref HEAD refs/heads/main; }

  git clone -q "$BARE" "$CLONE"
  git -C "$CLONE" config user.email "student@lab.local"
  git -C "$CLONE" config user.name  "CGOA Student"
  git -C "$CLONE" checkout -q -b main

  mkdir -p "$CLONE/clusters/lab"

  cat > "$CLONE/README.md" <<'EOF'
# platform repo — single source of truth

All cluster changes happen through commits to this repository.
Humans do not run `kubectl apply`, `kubectl edit`, `kubectl scale` or
`kubectl set image` against the cluster. The reconciler does.
EOF

  cat > "$CLONE/clusters/lab/00-namespace.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: gitops-lab
  labels:
    app.kubernetes.io/managed-by: gitops-reconciler
EOF

  cat > "$CLONE/clusters/lab/10-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: gitops-lab
  labels:
    app: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: web
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
EOF

  cat > "$CLONE/clusters/lab/20-service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: webapp
  namespace: gitops-lab
spec:
  selector:
    app: webapp
  ports:
    - port: 80
      targetPort: 80
EOF

  git -C "$CLONE" add -A
  git -C "$CLONE" commit -q -m "feat: initial declarative desired state for webapp (Principle 1)"
  git -C "$CLONE" push -q -u origin main

  say "Installing the pull-based reconciler agent (Principles 3 & 4)"
  cat > "$RECONCILER" <<'RECON'
#!/usr/bin/env bash
# Minimal pull-based GitOps agent. Real-world equivalents: Flux's
# kustomize-controller, Argo CD's application-controller.
# It PULLS desired state from Git and CONTINUOUSLY drives the cluster
# towards it. It deliberately does NOT implement pruning, health gating,
# or event-driven sync — exactly the gaps real controllers close.
set -u
LAB_DIR="__LAB_DIR__"
KCTX="__KCTX__"
CHECKOUT="$LAB_DIR/agent-checkout"
LOG="$LAB_DIR/reconciler.log"
INTERVAL=__INTERVAL__

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

if [ ! -d "$CHECKOUT/.git" ]; then
  git clone -q "$LAB_DIR/platform.git" "$CHECKOUT" 2>>"$LOG"
fi

log "reconciler started (pid $$, interval ${INTERVAL}s)"
while true; do
  if git -C "$CHECKOUT" fetch -q origin 2>>"$LOG"; then
    DESIRED="$(git -C "$CHECKOUT" rev-parse origin/main)"
    git -C "$CHECKOUT" reset -q --hard "$DESIRED"
    if kubectl --context "$KCTX" apply -f "$CHECKOUT/clusters/lab/" >>"$LOG" 2>&1; then
      echo "$DESIRED" > "$LAB_DIR/last-applied-revision"
      log "reconciled cluster to revision ${DESIRED:0:12}"
    else
      log "ERROR: kubectl apply failed; retrying in ${INTERVAL}s"
    fi
  else
    log "ERROR: git fetch failed; retrying in ${INTERVAL}s"
  fi
  sleep "$INTERVAL"
done
RECON
  sed -i "s|__LAB_DIR__|$LAB_DIR|; s|__KCTX__|$KCTX|; s|__INTERVAL__|$INTERVAL|" "$RECONCILER"
  chmod +x "$RECONCILER"

  nohup "$RECONCILER" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  say "Reconciler running (pid $(cat "$PIDFILE")). Waiting for first convergence..."

  local waited=0
  until [ "$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" = "2" ]; do
    sleep 5; waited=$((waited + 5)); printf '.'
    [ "$waited" -ge "$CONVERGE_TIMEOUT" ] && die "cluster did not converge in ${CONVERGE_TIMEOUT}s — check $LOGFILE"
  done
  printf '\n'
  say "Converged: webapp 2/2 Ready on nginx:1.27, matching Git. GitOps loop is healthy."
}

# -----------------------------------------------------------------------------
# Phase 2 — The controlled break
# -----------------------------------------------------------------------------
break_it() {
  [ -f "$PIDFILE" ] || die "lab not set up — run '$0 run'"

  say "Simulating the incident..."

  # (a) Friday, 23:40 — an engineer under pressure STOPS the agent so it
  #     "won't interfere with my hotfix". Principles 3 & 4 die here.
  kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true
  # The stale pid file is left behind on purpose, as it would be in real life.

  # (b) Meanwhile, a teammate's approved change lands in Git (replicas 3,
  #     nginx 1.28)... but with the agent dead, nothing ever deploys it.
  sed -i 's/replicas: 2/replicas: 3/; s/nginx:1.27/nginx:1.28/' \
    "$CLONE/clusters/lab/10-deployment.yaml"
  git -C "$CLONE" commit -aq -m "feat: scale webapp for launch and roll to nginx 1.28"
  git -C "$CLONE" push -q origin main

  # (c) 23:55 — the imperative "hotfix" itself: a hand-typed image tag that
  #     does not exist, plus a panic scale-up. Neither is recorded anywhere.
  kubectl -n "$NS" set image deployment/"$APP" web=nginx:1.99-hotfix >/dev/null
  kubectl -n "$NS" scale deployment/"$APP" --replicas=5 >/dev/null

  briefing
}

briefing() {
  cat <<EOF

=============================================================================
 INCIDENT BRIEFING — read carefully, then put the phone down and diagnose
=============================================================================

 It is Saturday 00:10. You are on call. Monitoring pages you: "webapp rollout
 stuck". Last night someone attempted a manual hotfix. That is all you know.

 SYMPTOMS YOU WILL SEE
   - kubectl -n $NS get pods
       * several pods stuck in ImagePullBackOff / ErrImagePull
       * the Deployment reports 2/5 ready and the rollout never finishes
   - kubectl -n $NS get deploy $APP -o wide
       * running image is 'nginx:1.99-hotfix' — a tag that exists nowhere
   - git -C $BARE log --oneline main
       * Git says nginx:1.28 with 3 replicas — the cluster disagrees BOTH ways:
         it has drift that Git never approved, and Git has an approved change
         the cluster never received
   - $LOGFILE
       * the reconcile log went silent at the moment of the incident

 YOUR MISSION (in this order)
   1. Diagnose which of the four OpenGitOps principles were violated, and by
      which action. Be precise — the exam is.
   2. Restore the GitOps loop so the CLUSTER converges to GIT, not the other
      way around. You must NOT "fix" the Deployment with kubectl set image /
      scale / edit — that is exactly the anti-pattern that caused this.
   3. Prove convergence: '$0 verify' must show all checks PASS.
   4. Aftercare: make one more legitimate change (e.g. bump replicas) the
      GitOps way — commit in $CLONE, push, watch it roll out hands-off.

 RULES OF ENGAGEMENT
   - Allowed: reading anything; restarting the agent; git commits + pushes.
   - Forbidden: any kubectl verb that mutates the Deployment directly.

 USEFUL COMMANDS
   $0 status          # side-by-side: Git desired state vs live cluster state
   tail -f $LOGFILE
   kubectl -n $NS get pods -w

=============================================================================
EOF
}

# -----------------------------------------------------------------------------
# Diagnostics
# -----------------------------------------------------------------------------
status() {
  local pid="(none)" alive="DEAD" git_rev applied="(never)" dimg drep limg lrep ready
  [ -f "$PIDFILE" ] && pid="$(cat "$PIDFILE")"
  [ "$pid" != "(none)" ] && kill -0 "$pid" 2>/dev/null && alive="RUNNING"
  git_rev="$(git -C "$BARE" rev-parse --short=12 main 2>/dev/null || echo '?')"
  [ -f "$LAB_DIR/last-applied-revision" ] && applied="$(cut -c1-12 "$LAB_DIR/last-applied-revision")"
  dimg="$(git -C "$BARE" show main:clusters/lab/10-deployment.yaml 2>/dev/null | awk '/image:/ {print $2}')"
  drep="$(git -C "$BARE" show main:clusters/lab/10-deployment.yaml 2>/dev/null | awk '/replicas:/ {print $2}')"
  limg="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')"
  lrep="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
  ready="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"

  cat <<EOF

 RECONCILER   pid=$pid state=$alive log=$LOGFILE
 GIT (main)   revision=$git_rev image=$dimg replicas=$drep
 LAST APPLIED revision=$applied
 CLUSTER      image=$limg replicas=$lrep ready=${ready:-0}

EOF
  kubectl -n "$NS" get pods 2>/dev/null || true
}

verify() {
  local pass=0 fail=0
  check() { # $1 label, $2 actual, $3 expected
    if [ "$2" = "$3" ]; then printf ' [PASS] %s\n' "$1"; pass=$((pass+1))
    else printf ' [FAIL] %s (got: %s, want: %s)\n' "$1" "${2:-<empty>}" "$3"; fail=$((fail+1)); fi
  }
  local pid alive="no"
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive="yes"
  local git_rev applied dimg drep limg lrep ready
  git_rev="$(git -C "$BARE" rev-parse main)"
  applied="$(cat "$LAB_DIR/last-applied-revision" 2>/dev/null || true)"
  dimg="$(git -C "$BARE" show main:clusters/lab/10-deployment.yaml | awk '/image:/ {print $2}')"
  drep="$(git -C "$BARE" show main:clusters/lab/10-deployment.yaml | awk '/replicas:/ {print $2}')"
  limg="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  lrep="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ready="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"

  echo
  check "reconciler agent is running"                  "$alive"   "yes"
  check "agent applied the current Git revision"       "$applied" "$git_rev"
  check "cluster image matches Git desired state"      "$limg"    "$dimg"
  check "cluster replicas match Git desired state"     "$lrep"    "$drep"
  check "all desired replicas are Ready"               "${ready:-0}" "$drep"
  echo
  if [ "$fail" -eq 0 ]; then
    echo " ALL CHECKS PASS — the cluster once again converges to Git. Well done."
  else
    echo " $fail check(s) failing — Git and the cluster still disagree. Keep going."
    exit 1
  fi
}

reset() {
  if [ -f "$PIDFILE" ]; then kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true; fi
  kubectl delete namespace "$NS" --ignore-not-found --wait=false 2>/dev/null || true
  rm -rf "$LAB_DIR"
  say "Lab removed (namespace deletion continues in background)."
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
case "${1:-run}" in
  run)    preflight; setup; break_it ;;
  status) preflight; status ;;
  verify) preflight; verify ;;
  reset)  preflight; reset ;;
  *) die "usage: $0 {run|status|verify|reset}" ;;
esac
exit 0

# =============================================================================
# SOLUTION — step by step. Spoilers below. Attempt the lab first.
# =============================================================================
#
# STEP 0 — Name the violations (exam skill, do it before touching anything)
#   - Stopping the agent violated Principle 3 (Pulled Automatically) and
#     Principle 4 (Continuously Reconciled): no agent, no reconciliation loop.
#   - `kubectl set image` / `kubectl scale` violated Principle 1 (the change
#     was imperative, not declarative) and bypassed Principle 2 (it exists in
#     no versioned, immutable history — it cannot be reviewed, reproduced,
#     audited, or rolled back).
#   - Note the compound failure mode: the cluster drifted AWAY from Git while
#     an approved change in Git was never delivered TO the cluster. Divergence
#     is bidirectional once the loop is broken.
#
# STEP 1 — Observe the symptom from the cluster side
#   $ kubectl -n gitops-lab get pods
#     NAME                      READY   STATUS             RESTARTS   AGE
#     webapp-6f9d...-abcde      1/1     Running            0          25m
#     webapp-6f9d...-fghij      1/1     Running            0          25m
#     webapp-7c88...-klmno      0/1     ImagePullBackOff   0          6m
#     webapp-7c88...-pqrst      0/1     ImagePullBackOff   0          6m
#     ...
#   $ kubectl -n gitops-lab describe pod <one of the failing pods> | tail -n 6
#     -> "manifest for nginx:1.99-hotfix not found" — the tag does not exist.
#   The rollout is stuck: the Deployment respects maxUnavailable, so the old
#   ReplicaSet's healthy pods keep serving while the new ReplicaSet can never
#   become Ready. That is why the page said "rollout stuck", not "outage".
#
# STEP 2 — Observe the agent side
#   $ cat ~/cgoa-lab-2.1/reconciler.pid          # e.g. 41234
#   $ kill -0 41234; echo $?                     # non-zero -> process is dead
#   $ tail -n 3 ~/cgoa-lab-2.1/reconciler.log    # log stops at incident time
#   A stale pid file plus a silent log is the classic signature of a
#   suspended/paused reconciler (flux suspend, Argo CD sync disabled).
#
# STEP 3 — Establish what the source of truth actually says
#   $ git -C ~/cgoa-lab-2.1/platform.git log --oneline main
#     <sha> feat: scale webapp for launch and roll to nginx 1.28
#     <sha> feat: initial declarative desired state for webapp (Principle 1)
#   $ git -C ~/cgoa-lab-2.1/platform.git show main:clusters/lab/10-deployment.yaml
#     -> replicas: 3, image: nginx:1.28
#   Decision point, and the heart of GitOps: you do NOT reconcile Git to match
#   the cluster; you restore the machinery that reconciles the cluster to Git.
#
# STEP 4 — Restore reconciliation (the actual fix — two commands)
#   $ rm ~/cgoa-lab-2.1/reconciler.pid
#   $ nohup ~/cgoa-lab-2.1/bin/reconciler.sh >/dev/null 2>&1 & \
#       echo $! > ~/cgoa-lab-2.1/reconciler.pid
#   $ tail -f ~/cgoa-lab-2.1/reconciler.log
#     -> within 15s: "reconciled cluster to revision <sha of the launch commit>"
#
# STEP 5 — Watch convergence and understand WHY it works
#   $ kubectl -n gitops-lab get deploy webapp -w
#     -> image flips to nginx:1.28, replicas to 3, then 3/3 Ready.
#   `kubectl apply` re-asserts every field declared in the manifest, so the
#   phantom hotfix image and the panic scale-up are simply overwritten by the
#   declared state. Both pieces of drift vanish in one reconcile cycle, and
#   the approved-but-stranded commit ships at the same time. Real controllers
#   (Flux, Argo CD) additionally detect drift between intervals, prune
#   resources deleted from Git, run health checks, and emit drift events.
#
# STEP 6 — Prove it
#   $ ./cgoa-2.1-break-fix.sh verify
#     -> 5/5 [PASS]
#
# STEP 7 — Aftercare: make the next change the right way
#   $ cd ~/cgoa-lab-2.1/dev-clone
#   $ sed -i 's/replicas: 3/replicas: 4/' clusters/lab/10-deployment.yaml
#   $ git commit -am "feat: add capacity ahead of launch traffic" && git push
#   Within one interval the cluster runs 4/4 — and this time there is an
#   author, a diff, a timestamp, and a revert path (`git revert`). That
#   auditability is Principle 2 paying rent.
#
# PRODUCTION TAKEAWAYS
#   - Humans get read-only cluster access; only the reconciler's identity may
#     write. If kubectl-write is impossible, Friday-night hotfixes are too.
#   - Pausing reconciliation is sometimes legitimate (incident forensics,
#     migrations) but must be time-boxed, alarmed, and visible — an agent that
#     is down IS the incident, e.g. alert on Flux's `SuspendedReconciliation`
#     or a stale `.status.lastAppliedRevision`.
#   - "Fix forward through Git" beats "fix live, backport later": the second
#     one produced this exact lab.
# =============================================================================