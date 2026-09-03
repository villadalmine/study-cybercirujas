#!/usr/bin/env bash
#===============================================================================
#  LPI DevOps Tools Engineer  --  Exam 701-100, version 2.0.0
#  Topic 703.1  --  Kubernetes Architecture and Usage   (exam weight: 6.67)
#
#  BREAK & FIX LAB : "The onion"  --  three layered faults, peeled from the
#  control plane outwards to the workload.
#
#      Layer 1 (architecture) : the API server static Pod cannot reach etcd
#      Layer 2 (scheduling)   : the only node carries an untolerated taint
#      Layer 3 (usage)        : the Service selector does not match the Pods
#
#  Each layer hides the next one. You cannot see the Pending Pods until the
#  API server answers again, and you cannot see the empty EndpointSlice until
#  the Pods are Running. That is exactly how a real incident unfolds.
#
#  !!  DISPOSABLE LAB VM ONLY  !!
#  This script mutates /etc/kubernetes/manifests, taints the node and creates a
#  namespace. It is written for a throwaway single-node kubeadm / minikube VM.
#  NEVER run it against a cluster you care about. Every change is backed up and
#  reversible with `--restore`, but do not rely on that in production.
#
#  Usage:
#      sudo ./703.1-break-and-fix.sh            # arm the lab (asks to confirm)
#      sudo ./703.1-break-and-fix.sh --brief    # reprint the mission briefing
#      sudo ./703.1-break-and-fix.sh --verify   # grade your fix, layer by layer
#      sudo ./703.1-break-and-fix.sh --restore  # give up / clean the VM
#
#  Non-interactive arming:  BREAKFIX_CONFIRM=BREAK sudo -E ./703.1-...sh
#
#  Official sources
#    LPI 701-100 objectives .. https://www.lpi.org/our-certifications/exam-701-objectives/
#    Cluster components ...... https://kubernetes.io/docs/concepts/overview/components/
#    Static Pods ............. https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
#    kubelet ................. https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
#    Taints and tolerations .. https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
#    Service & selectors ..... https://kubernetes.io/docs/concepts/services-networking/service/
#    EndpointSlices .......... https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
#    Troubleshooting clusters  https://kubernetes.io/docs/tasks/debug/debug-cluster/
#    crictl (debug runtime) .. https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
#===============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Constants
#------------------------------------------------------------------------------
NS="breakfix-703-1"
DEPLOY="web-703"
SVC="web-703"
GOOD_LABEL="web-703"
BAD_LABEL="web-7031"                       # the deliberate typo of Layer 3
TAINT_KEY="lpi.breakfix/703-1"
TAINT_VALUE="maintenance"
TAINT_EFFECT="NoSchedule"

STATE_DIR="/var/lib/lpi-breakfix-703-1"
STATE_FILE="$STATE_DIR/state.env"
BACKUP_DIR="$STATE_DIR/backup"

MANIFEST_DIR="/etc/kubernetes/manifests"
APISERVER_MANIFEST="$MANIFEST_DIR/kube-apiserver.yaml"

IMAGE="${BF_IMAGE:-nginx:1.27-alpine}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'
BLU=$'\033[0;34m'; BLD=$'\033[1m';    RST=$'\033[0m'

#------------------------------------------------------------------------------
# Small helpers
#------------------------------------------------------------------------------
log()  { printf '%s[ * ]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n' "$YEL" "$RST" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
die()  { fail "$*"; exit 1; }

rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

KUBECONFIG_FILE=""
kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=10s "$@"; }

detect_kubeconfig() {
    local c candidates=()
    [[ -n "${KUBECONFIG:-}" ]] && candidates+=( "${KUBECONFIG%%:*}" )
    if [[ -n "${SUDO_USER:-}" ]]; then
        candidates+=( "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.kube/config" )
    fi
    candidates+=( "$HOME/.kube/config" "/etc/kubernetes/admin.conf" )
    for c in "${candidates[@]}"; do
        [[ -n "$c" && -r "$c" ]] && { KUBECONFIG_FILE="$c"; return 0; }
    done
    die "no readable kubeconfig found (tried KUBECONFIG, ~/.kube/config, /etc/kubernetes/admin.conf)"
}

# api_reachable -> 0 if the API server answers /readyz through the kubeconfig
api_reachable() {
    kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=5s \
            get --raw='/readyz' >/dev/null 2>&1
}

# wait_api up|down <seconds>
wait_api() {
    local want="$1" timeout="${2:-90}" i=0
    while (( i < timeout )); do
        if api_reachable; then
            [[ "$want" == "up"   ]] && return 0
        else
            [[ "$want" == "down" ]] && return 0
        fi
        sleep 2; i=$(( i + 2 ))
    done
    return 1
}

#------------------------------------------------------------------------------
# Guard rails
#------------------------------------------------------------------------------
preflight() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo): the lab edits /etc/kubernetes and /var/lib"
    need kubectl
    detect_kubeconfig
    log "kubeconfig  : $KUBECONFIG_FILE"

    api_reachable || die "the API server is not reachable yet - fix the cluster before breaking it"

    NODE="$(kc get nodes -o jsonpath='{.items[0].metadata.name}')"
    local node_count
    node_count="$(kc get nodes --no-headers | wc -l)"
    local ctx server
    ctx="$(kc config current-context 2>/dev/null || echo '?')"
    server="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

    log "context     : $ctx"
    log "API server  : $server"
    log "nodes       : $node_count (first: $NODE)"

    if [[ "$node_count" -ne 1 && "${BREAKFIX_ALLOW_MULTINODE:-no}" != "yes" ]]; then
        die "this lab expects a single-node throwaway cluster (found $node_count nodes).
       Override only if you are certain: BREAKFIX_ALLOW_MULTINODE=yes"
    fi

    if [[ -f "$APISERVER_MANIFEST" ]] && grep -q -- '--etcd-servers=' "$APISERVER_MANIFEST"; then
        MODE="manifest"
    else
        MODE="kubeconfig"
        warn "no kubeadm static Pod manifest found -> Layer 1 will break the kubeconfig instead"
    fi
    log "layer-1 mode: $MODE"
}

confirm() {
    if [[ "${BREAKFIX_CONFIRM:-}" == "BREAK" ]]; then return 0; fi
    rule
    printf '%sYou are about to BREAK the cluster shown above.%s\n' "$BLD" "$RST"
    printf 'Only continue if this VM is disposable. Type BREAK to proceed: '
    local answer=""
    read -r answer || true
    [[ "$answer" == "BREAK" ]] || die "aborted - nothing was changed"
}

#------------------------------------------------------------------------------
# Arming the lab
#------------------------------------------------------------------------------
save_state() {
    install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
    {
        printf 'MODE=%s\n'            "$MODE"
        printf 'NODE=%s\n'            "$NODE"
        printf 'KUBECONFIG_FILE=%s\n' "$KUBECONFIG_FILE"
        printf 'NS=%s\n'              "$NS"
    } > "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

load_state() {
    [[ -r "$STATE_FILE" ]] || die "no lab state at $STATE_FILE - was the lab ever armed?"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

deploy_workload() {
    log "creating namespace $NS with a Deployment and a Service"
    kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

    kc apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels:
    app: ${GOOD_LABEL}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${GOOD_LABEL}
  template:
    metadata:
      labels:
        app: ${GOOD_LABEL}
    spec:
      containers:
        - name: web
          image: ${IMAGE}
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
spec:
  type: ClusterIP
  selector:
    app: ${BAD_LABEL}
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
YAML

    log "waiting for the rollout so the image is cached locally (the lab then works offline)"
    if ! kc -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1; then
        warn "the Deployment did not become Available in time"
        warn "check image pull connectivity for '$IMAGE' (override with BF_IMAGE=<image>)"
        die  "aborting before breaking anything else - run --restore to clean up"
    fi
    ok "workload is healthy (and deliberately mis-wired at the Service level)"
}

break_layer2_taint() {
    log "Layer 2: tainting node $NODE with ${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}"
    kc taint nodes "$NODE" "${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}" --overwrite >/dev/null
    # Recreate the Pods so the scheduler has to place them again and fails.
    kc -n "$NS" delete pods -l "app=${GOOD_LABEL}" --grace-period=5 >/dev/null 2>&1 || true
    sleep 5
    ok "Pods are now unschedulable"
}

break_layer1_manifest() {
    log "Layer 1: pointing the kube-apiserver static Pod at a dead etcd endpoint"
    cp -a "$APISERVER_MANIFEST" "$BACKUP_DIR/kube-apiserver.yaml.orig"
    sed -ri 's#(--etcd-servers=[^,[:space:]]+):([0-9]+)#\1:1\2#g' "$APISERVER_MANIFEST"
    if cmp -s "$APISERVER_MANIFEST" "$BACKUP_DIR/kube-apiserver.yaml.orig"; then
        cp -a "$BACKUP_DIR/kube-apiserver.yaml.orig" "$APISERVER_MANIFEST"
        die "could not rewrite --etcd-servers - manifest restored, nothing broken at layer 1"
    fi
    ok "manifest rewritten: $(grep -o -- '--etcd-servers=[^ ]*' "$APISERVER_MANIFEST" | head -1)"
    log "waiting for the kubelet to notice the file change and restart the API server..."
    wait_api down 120 || warn "the API server is still answering - it may take a few more seconds"
}

break_layer1_kubeconfig() {
    log "Layer 1: rewriting the server endpoint inside $KUBECONFIG_FILE"
    cp -a "$KUBECONFIG_FILE" "$BACKUP_DIR/kubeconfig.orig"
    sed -ri 's#(^[[:space:]]*server:[[:space:]]*https?://[^:]+):([0-9]+)#\1:1\2#' "$KUBECONFIG_FILE"
    if cmp -s "$KUBECONFIG_FILE" "$BACKUP_DIR/kubeconfig.orig"; then
        cp -a "$BACKUP_DIR/kubeconfig.orig" "$KUBECONFIG_FILE"
        die "could not rewrite the server URL - kubeconfig restored, nothing broken at layer 1"
    fi
    ok "client endpoint rewritten: $(grep -m1 'server:' "$KUBECONFIG_FILE" | tr -d ' ')"
    wait_api down 30 || warn "the API still answers - check whether another kubeconfig is in use"
}

#------------------------------------------------------------------------------
# Mission briefing
#------------------------------------------------------------------------------
briefing() {
    load_state 2>/dev/null || true
    rule
    printf '%s LPI 701-100 / 703.1  Kubernetes Architecture and Usage  --  BREAK & FIX%s\n' "$BLD" "$RST"
    rule
    cat <<'BRIEF'

SCENARIO
    A colleague "did some maintenance" on this single-node cluster and left.
    Nothing works. You own the incident. Three independent faults are stacked,
    and each one hides the next: fix the outermost, and a new symptom appears.

WHAT YOU WILL SEE FIRST
    $ kubectl get nodes
    The connection to the server <endpoint> was refused - did you specify the
    right host or port?

    kubectl is only an HTTP client. That message means the client could not
    complete a TCP/TLS conversation with kube-apiserver. It does NOT tell you
    whether the API server is down, listening elsewhere, or crash-looping.

YOUR MISSION
    Layer 1 - Get `kubectl get --raw='/readyz'` to answer "ok" again, WITHOUT
              reinstalling the cluster.
              Remember the architecture: on a kubeadm cluster the control plane
              runs as static Pods. No API server is needed to inspect or repair
              them - the kubelet reads them straight off the local disk, and the
              container runtime can be queried directly with crictl.

    Layer 2 - Get the two Pods of deployment/web-703 in namespace breakfix-703-1
              into Running/Ready. `kubectl describe pod` prints the scheduler's
              own reason for refusing - read it literally.
              Hint: `kubectl uncordon` alone will NOT be enough here.

    Layer 3 - Make service/web-703 actually serve traffic:
                  kubectl -n breakfix-703-1 exec deploy/web-703 -- \
                      wget -qO- --timeout=5 http://web-703
              must return the nginx welcome page. A Service does not "point at"
              a Deployment; the EndpointSlice controller fills it from a label
              selector. If that selector matches nothing, the Service resolves
              in DNS and still blackholes every packet.

TOOLBOX (all of it is fair game, and all of it is exam material)
    kubectl get/describe/logs/events/exec/patch/taint/edit --raw
    systemctl status kubelet ; journalctl -u kubelet -f
    crictl ps -a ; crictl logs <id>   (or: docker/podman ps, depending on the CRI)
    ls -l /etc/kubernetes/manifests/ ; less /etc/kubernetes/manifests/*.yaml
    ss -lntp | grep -E '6443|2379|10250'

RULES OF ENGAGEMENT
    * Do NOT run `kubeadm reset`, `minikube delete`, or reinstall anything.
      Rebuilding is not troubleshooting, and the exam will not accept it.
    * Change one thing at a time and re-observe. Write down each hypothesis
      before you test it.
    * Everything this lab touched is backed up under /var/lib/lpi-breakfix-703-1.

GRADE YOUR WORK
    sudo ./703.1-break-and-fix.sh --verify

GIVE UP / CLEAN THE VM
    sudo ./703.1-break-and-fix.sh --restore

BRIEF
    rule
    printf 'Estimated time: 25-40 min. The step-by-step solution is at the end\n'
    printf 'of this script, commented out. Read it only after you are stuck.\n'
    rule
}

#------------------------------------------------------------------------------
# Verification
#------------------------------------------------------------------------------
verify() {
    load_state
    detect_kubeconfig
    local score=0

    rule
    printf '%s VERIFY - topic 703.1 break & fix%s\n' "$BLD" "$RST"
    rule

    # ---- Layer 1 ------------------------------------------------------------
    if api_reachable; then
        ok "Layer 1: the API server answers /readyz through $KUBECONFIG_FILE"
        score=$(( score + 1 ))
    else
        fail "Layer 1: kubectl still cannot reach the API server"
        printf '        %s\n' "hint: who starts kube-apiserver on this node, and from which file?"
        rule
        printf 'Score: %s/3 - fix layer 1 before the rest can even be evaluated.\n' "$score"
        exit 1
    fi

    # ---- Layer 2 ------------------------------------------------------------
    local taints ready desired
    taints="$(kc get node "$NODE" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null || true)"
    ready="$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    desired="$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    ready="${ready:-0}"
    if [[ "$taints" == *"$TAINT_KEY"* ]]; then
        fail "Layer 2: node $NODE still carries the taint '$TAINT_KEY'"
        printf '        %s\n' "hint: kubectl taint nodes <node> <key>-   (note the trailing dash)"
    elif [[ "$ready" -ge "${desired:-2}" && "$ready" -gt 0 ]]; then
        ok "Layer 2: $ready/$desired Pods are Ready and the taint is gone"
        score=$(( score + 1 ))
    else
        fail "Layer 2: only $ready/${desired:-2} Pods are Ready"
        printf '        %s\n' "hint: kubectl -n $NS describe pod | sed -n '/Events/,\$p'"
    fi

    # ---- Layer 3 ------------------------------------------------------------
    local sel addrs
    sel="$(kc -n "$NS" get svc "$SVC" -o jsonpath='{.spec.selector}' 2>/dev/null || true)"
    addrs="$(kc -n "$NS" get endpointslices -l "kubernetes.io/service-name=$SVC" \
             -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null || true)"
    if [[ -n "${addrs// /}" ]]; then
        ok "Layer 3: EndpointSlice is populated -> ${addrs}"
        if kc -n "$NS" exec "deploy/$DEPLOY" -- \
              wget -qO- --timeout=5 "http://$SVC" 2>/dev/null | grep -qi 'welcome to nginx'; then
            ok "Layer 3: end-to-end HTTP through the ClusterIP works"
        else
            warn "Layer 3: endpoints exist but the in-cluster HTTP check did not return the page"
            warn "         (CNI or CoreDNS issue - the selector itself is correct)"
        fi
        score=$(( score + 1 ))
    else
        fail "Layer 3: service/$SVC has no ready endpoints (selector is $sel)"
        printf '        %s\n' "hint: compare it with 'kubectl -n $NS get pods --show-labels'"
    fi

    rule
    printf 'Score: %s%s/3%s\n' "$BLD" "$score" "$RST"
    if [[ "$score" -eq 3 ]]; then
        printf '%sCluster restored end to end. Run --restore to clean the lab objects.%s\n' "$GRN" "$RST"
        rule; return 0
    fi
    rule; return 1
}

#------------------------------------------------------------------------------
# Restore
#------------------------------------------------------------------------------
restore() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo)"
    load_state
    detect_kubeconfig

    if [[ -f "$BACKUP_DIR/kube-apiserver.yaml.orig" ]]; then
        log "restoring $APISERVER_MANIFEST"
        cp -a "$BACKUP_DIR/kube-apiserver.yaml.orig" "$APISERVER_MANIFEST"
    fi
    if [[ -f "$BACKUP_DIR/kubeconfig.orig" ]]; then
        log "restoring $KUBECONFIG_FILE"
        cp -a "$BACKUP_DIR/kubeconfig.orig" "$KUBECONFIG_FILE"
    fi

    log "waiting for the API server to come back..."
    if wait_api up 180; then ok "API server is ready"; else warn "API server still not ready - inspect with crictl/journalctl"; fi

    if api_reachable; then
        kc taint nodes "$NODE" "${TAINT_KEY}-" >/dev/null 2>&1 || true
        kc uncordon "$NODE" >/dev/null 2>&1 || true
        log "deleting namespace $NS"
        kc delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
    fi

    rm -rf "$STATE_DIR"
    ok "lab reverted. The VM is back to its pre-lab state."
}

#------------------------------------------------------------------------------
# Arm
#------------------------------------------------------------------------------
arm() {
    preflight
    [[ -f "$STATE_FILE" ]] && die "a lab is already armed. Run --verify or --restore first."
    confirm
    save_state
    deploy_workload
    break_layer2_taint
    if [[ "$MODE" == "manifest" ]]; then break_layer1_manifest; else break_layer1_kubeconfig; fi
    printf '\n'
    briefing
}

#------------------------------------------------------------------------------
# Entry point
#------------------------------------------------------------------------------
case "${1:---arm}" in
    --arm|arm)         arm ;;
    --brief|brief)     detect_kubeconfig; briefing ;;
    --verify|verify)   verify ;;
    --restore|restore) restore ;;
    -h|--help|help)    sed -n '1,40p' "$0" ;;
    *) die "unknown option '$1' (use --arm | --brief | --verify | --restore)" ;;
esac

#===============================================================================
#  SOLUTION  --  do not read until you have genuinely tried
#===============================================================================
#
# ---------------------------------------------------------------------------
# LAYER 1 : "The connection to the server 10.0.2.15:6443 was refused"
# ---------------------------------------------------------------------------
#
# STEP 1 - Separate the client from the server. What does the client believe?
#
#     $ kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
#     https://10.0.2.15:6443
#
#     $ ss -lntp | grep 6443
#     (no output)
#
#   Nothing is listening on 6443, so this is a server-side fault, not a bad
#   kubeconfig. If instead you HAD seen something listening on 6443 while the
#   kubeconfig said 16443, the fault would have been client-side and the fix
#   would be a one-line edit of ~/.kube/config (that is the fallback variant
#   this script uses on non-kubeadm clusters).
#
# STEP 2 - Remember who owns the control plane. On a kubeadm cluster,
#   kube-apiserver, kube-scheduler, kube-controller-manager and etcd are STATIC
#   PODS: the kubelet reads their manifests from /etc/kubernetes/manifests and
#   runs them directly against the CRI. They are not scheduled, they do not need
#   the API server to exist, and the kubelet re-reads that directory on every
#   file change. So the kubelet is your remaining working control plane.
#
#     $ systemctl is-active kubelet
#     active
#     $ journalctl -u kubelet -n 30 --no-pager | grep -i apiserver
#     ... "Failed to connect to apiserver" ... connection refused
#
#   The kubelet is alive and complaining that IT cannot reach the API server
#   either -> the API server process itself is the problem.
#
# STEP 3 - Ask the container runtime directly, bypassing Kubernetes entirely.
#
#     $ export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
#     $ crictl ps -a --name kube-apiserver
#     CONTAINER      IMAGE      CREATED          STATE      NAME             ATTEMPT
#     8f2c1a...      d4e...     10 seconds ago   Exited     kube-apiserver   7
#
#   ATTEMPT 7 and STATE Exited = a crash loop. The kubelet keeps restarting it.
#
# STEP 4 - Read the dying process's own words.
#
#     $ crictl logs "$(crictl ps -a --name kube-apiserver -q | head -1)" 2>&1 | tail -20
#     ...
#     "Failed to create storage backend" err="context deadline exceeded"
#     dial tcp 127.0.0.1:12379: connect: connection refused
#
#   Port 12379. etcd's client port is 2379 (2380 is peer traffic). Someone
#   changed the flag.
#
# STEP 5 - Confirm in the manifest and fix it.
#
#     $ grep -n 'etcd-servers' /etc/kubernetes/manifests/kube-apiserver.yaml
#     23:    - --etcd-servers=https://127.0.0.1:12379
#
#     $ cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/apiserver.bak
#     $ sed -i 's#--etcd-servers=\(https\?://[^:]*\):12379#--etcd-servers=\1:2379#' \
#           /etc/kubernetes/manifests/kube-apiserver.yaml
#
#   (Editing the file in place is the whole fix. Do NOT `systemctl restart
#   kubelet` hoping it helps: the kubelet's inotify watch on the manifest
#   directory already picked up the change and is recreating the Pod.)
#
# STEP 6 - Verify the recovery, at the right layer.
#
#     $ ss -lntp | grep 6443
#     LISTEN 0 4096 *:6443 *:*  users:(("kube-apiserver",pid=...))
#
#     $ kubectl get --raw='/readyz?verbose'
#     [+]ping ok
#     [+]etcd ok
#     ...
#     readyz check passed
#
#   Give the controller-manager and scheduler ~30 s to re-acquire their leader
#   election leases before judging anything else.
#
#
# ---------------------------------------------------------------------------
# LAYER 2 : Pods stay Pending forever
# ---------------------------------------------------------------------------
#
# STEP 1 - Observe.
#
#     $ kubectl -n breakfix-703-1 get pods -o wide
#     NAME                       READY   STATUS    RESTARTS   AGE   NODE
#     web-703-6c9f7c8d95-4kqxr   0/1     Pending   0          6m    <none>
#     web-703-6c9f7c8d95-t8v2n   0/1     Pending   0          6m    <none>
#
#   NODE is <none>: the kube-scheduler never bound them. This is a scheduling
#   problem, not an image or runtime problem.
#
# STEP 2 - The scheduler always explains itself in the Pod's events.
#
#     $ kubectl -n breakfix-703-1 describe pod -l app=web-703 | sed -n '/Events/,$p'
#     Events:
#       Type     Reason            Message
#       ----     ------            -------
#       Warning  FailedScheduling  0/1 nodes are available: 1 node(s) had
#                                  untolerated taint {lpi.breakfix/703-1:
#                                  maintenance}. preemption: 0/1 nodes are
#                                  available.
#
# STEP 3 - Confirm on the node object.
#
#     $ kubectl describe node "$(kubectl get nodes -o name | head -1 | cut -d/ -f2)" \
#           | grep -A3 Taints
#     Taints:  lpi.breakfix/703-1=maintenance:NoSchedule
#
#     $ kubectl get nodes
#     NAME     STATUS   ROLES           AGE   VERSION
#     lab-01   Ready    control-plane   14d   v1.31.4
#
#   STATUS is Ready and there is no "SchedulingDisabled" marker, so the node was
#   never cordoned - `kubectl uncordon` would remove only the built-in
#   node.kubernetes.io/unschedulable taint and would change nothing here.
#
# STEP 4 - Two legitimate fixes; pick the one that matches intent.
#
#   (a) The taint is spurious - remove it (trailing dash = delete):
#
#       $ kubectl taint nodes lab-01 lpi.breakfix/703-1-
#       node/lab-01 untainted
#
#   (b) The taint is real policy and this workload must run anyway - tolerate it:
#
#       $ kubectl -n breakfix-703-1 patch deploy web-703 --type=merge -p '{
#           "spec":{"template":{"spec":{"tolerations":[
#             {"key":"lpi.breakfix/703-1","operator":"Equal",
#              "value":"maintenance","effect":"NoSchedule"}]}}}}'
#
#   In this lab (a) is correct: nothing else on the node needed protecting.
#   Understand the difference - a taint repels Pods from a node; a toleration
#   only lets a Pod ignore that repulsion. Neither one attracts a Pod to a node;
#   that is what nodeSelector / nodeAffinity do.
#
# STEP 5 - Verify.
#
#     $ kubectl -n breakfix-703-1 rollout status deploy/web-703
#     deployment "web-703" successfully rolled out
#     $ kubectl -n breakfix-703-1 get pods -o wide
#     NAME                       READY   STATUS    RESTARTS   AGE   NODE
#     web-703-6c9f7c8d95-4kqxr   1/1     Running   0          8m    lab-01
#     web-703-6c9f7c8d95-t8v2n   1/1     Running   0          8m    lab-01
#
#
# ---------------------------------------------------------------------------
# LAYER 3 : the Service resolves but blackholes traffic
# ---------------------------------------------------------------------------
#
# STEP 1 - Reproduce from inside the cluster (a ClusterIP is not reachable from
#   the VM's host network namespace, so test from a Pod):
#
#     $ kubectl -n breakfix-703-1 exec deploy/web-703 -- wget -qO- --timeout=5 http://web-703
#     wget: download timed out
#     command terminated with exit code 1
#
#   DNS resolved (no "bad address"), so CoreDNS and the Service object are fine.
#   The packets simply have nowhere to go.
#
# STEP 2 - Look at the data plane of a Service: its EndpointSlices.
#
#     $ kubectl -n breakfix-703-1 get endpointslices -l kubernetes.io/service-name=web-703
#     NAME           ADDRESSTYPE   PORTS   ENDPOINTS   AGE
#     web-703-9xz4k  IPv4          <unset> <unset>     9m
#
#   Empty. kube-proxy programs its rules from these objects, so an empty slice
#   means "no backend exists" - iptables/IPVS drops the traffic.
#
# STEP 3 - Compare what the Service asks for with what the Pods actually carry.
#
#     $ kubectl -n breakfix-703-1 get svc web-703 -o jsonpath='{.spec.selector}'; echo
#     {"app":"web-7031"}
#
#     $ kubectl -n breakfix-703-1 get pods --show-labels
#     NAME                       READY  STATUS   LABELS
#     web-703-6c9f7c8d95-4kqxr   1/1    Running  app=web-703,pod-template-hash=6c9f7c8d95
#
#   web-7031 vs web-703. One stray character. This is the single most common
#   Service failure in production, and the reason `kubectl get endpoints[slices]`
#   belongs in your reflexes right after `kubectl get svc`.
#
# STEP 4 - Fix the Service, never the Pods. The Deployment's own
#   spec.selector.matchLabels is immutable after creation, and relabelling Pods
#   would orphan them from their ReplicaSet.
#
#     $ kubectl -n breakfix-703-1 patch svc web-703 --type=merge \
#           -p '{"spec":{"selector":{"app":"web-703"}}}'
#     service/web-703 patched
#
# STEP 5 - Verify end to end.
#
#     $ kubectl -n breakfix-703-1 get endpointslices -l kubernetes.io/service-name=web-703 -o wide
#     NAME           ADDRESSTYPE  PORTS  ENDPOINTS               READY
#     web-703-9xz4k  IPv4         80     10.244.0.14,10.244.0.15 true,true
#
#     $ kubectl -n breakfix-703-1 exec deploy/web-703 -- wget -qO- --timeout=5 http://web-703 | head -4
#     <!DOCTYPE html>
#     <html>
#     <head>
#     <title>Welcome to nginx!</title>
#
#     $ sudo ./703.1-break-and-fix.sh --verify
#     [ OK ] Layer 1: the API server answers /readyz
#     [ OK ] Layer 2: 2/2 Pods are Ready and the taint is gone
#     [ OK ] Layer 3: EndpointSlice is populated
#     Score: 3/3
#
#
# ---------------------------------------------------------------------------
# WHAT THIS EXERCISE ACTUALLY TAUGHT (the exam-relevant model)
# ---------------------------------------------------------------------------
#
#   * kubectl is a REST client. "Connection refused" is a statement about a
#     socket, never a diagnosis. Always ask next: which endpoint, and is anything
#     listening there?
#   * The control plane is made of ordinary processes. On kubeadm they are static
#     Pods owned by the kubelet, declared in /etc/kubernetes/manifests, and
#     debuggable with crictl even when the whole API is gone. That is the escape
#     hatch that makes a "dead" cluster repairable instead of disposable.
#   * etcd is the only stateful component. Every API server flag pointing at it
#     (--etcd-servers, --etcd-cafile, --etcd-certfile) is a single point of
#     failure for the entire cluster.
#   * Scheduling failures are declarative and self-documenting: the scheduler
#     writes its refusal into the Pod's events. Pending + NODE <none> means read
#     the events; CrashLoopBackOff means read the container logs. Different layer,
#     different tool.
#   * A Service is a label selector plus a virtual IP - it has no link to a
#     Deployment. The chain is: Service.spec.selector -> EndpointSlice controller
#     -> EndpointSlice -> kube-proxy -> iptables/IPVS. Any break in that chain
#     yields a name that resolves and traffic that vanishes.
#===============================================================================