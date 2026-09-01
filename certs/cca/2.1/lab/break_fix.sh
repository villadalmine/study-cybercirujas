#!/usr/bin/env bash
#
# =============================================================================
#  CCA — Certified Cilium Associate
#  Domain 2: Cilium Architecture & Components  (exam weight: 20%)
#  Topic 2.1 — Break & Fix Lab: "The agent that lost its brain"
# =============================================================================
#
#  WHAT THIS SCRIPT IS
#  -------------------
#  A controlled fault-injection exercise. It breaks the Cilium control plane in
#  a way that is realistic, reversible, and instructive: it does NOT corrupt
#  data, does NOT touch anything outside the lab cluster, and every mutation it
#  performs is captured in a backup directory so you can always get back.
#
#  WHERE TO RUN IT
#  ---------------
#  A DISPOSABLE lab VM running a single-node kind/minikube/k3s cluster with
#  Cilium installed as the CNI. NEVER on a cluster you care about.
#  Requirements: kubectl (with admin kubeconfig), cilium CLI (optional but
#  recommended), jq, a Cilium install in namespace `kube-system`.
#
#  THE LEARNING GOAL
#  -----------------
#  Cilium is not one program. It is a set of cooperating components with very
#  different failure semantics, and the whole point of this lab is that you
#  learn to tell them apart under pressure:
#
#    cilium-agent (DaemonSet, one per node)
#        Owns the datapath on its node. Compiles and loads eBPF programs,
#        manages the BPF maps (endpoints, policy, connection tracking, NAT,
#        service/lb maps), programs identities into the policy map, and talks
#        to the kube-apiserver and to the KVStore/CRD backend. It is the ONLY
#        component that writes the datapath.
#
#    cilium-operator (Deployment, cluster-wide, usually 1-2 replicas)
#        Does the work that must happen once per cluster rather than once per
#        node: garbage collection of stale CiliumEndpoints and CiliumIdentities,
#        IPAM pool management in cluster-pool mode, CiliumNode synchronisation,
#        KVStore heartbeat, and (in some modes) CRD registration. The operator
#        does NOT sit in the packet path.
#
#    cilium CNI plugin (binary on the host, /opt/cni/bin/cilium-cni)
#        Invoked by the container runtime via CNI when a Pod sandbox is created
#        or destroyed. It is a short-lived process that talks to the local agent
#        over the agent's UNIX socket. No agent socket -> no Pod networking ->
#        Pods stuck in ContainerCreating.
#
#    Hubble (embedded in the agent + optional hubble-relay Deployment + UI)
#        Observability plane. Reads flow events from the agent's eBPF ring
#        buffer. If Hubble is down you lose visibility, NOT connectivity.
#
#    The identity/state backend (CRDs by default, or an external KVStore)
#        CiliumIdentity, CiliumEndpoint, CiliumNode, CiliumEndpointSlice.
#
#  The single most valuable architectural fact this lab teaches:
#
#      *** The eBPF datapath survives the agent. ***
#
#  eBPF programs and maps are pinned in the kernel (bpffs, /sys/fs/bpf/tc/globals
#  and friends). When cilium-agent dies, already-programmed traffic between
#  already-known endpoints KEEPS FLOWING. What you lose is the ability to
#  CHANGE anything: no new Pods get networking, no new identities are resolved,
#  no policy updates are applied, and DNS-based policy (which is proxied by the
#  agent) degrades. Engineers who do not know this waste outages chasing a
#  "network outage" that is actually a "control plane outage".
#
#  Official sources used for this lab:
#    - Cilium component overview:
#        https://docs.cilium.io/en/stable/overview/component-overview/
#    - Cilium architecture / eBPF datapath:
#        https://docs.cilium.io/en/stable/network/ebpf/
#    - Troubleshooting guide (cilium-dbg, status, endpoint list):
#        https://docs.cilium.io/en/stable/operations/troubleshooting/
#    - cilium-operator responsibilities and flags:
#        https://docs.cilium.io/en/stable/cmdref/cilium-operator/
#    - CCA curriculum:
#        https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
#
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly CILIUM_NS="${CILIUM_NS:-kube-system}"
readonly LAB_NS="${LAB_NS:-cca-lab-21}"
readonly BACKUP_DIR="${BACKUP_DIR:-/tmp/cca-lab-2.1-backup}"
readonly AGENT_DS="cilium"
readonly OPERATOR_DEPLOY="cilium-operator"

# Colours only when stdout is a TTY, so the output stays clean when piped.
if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
else
  readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

log()  { printf '%s[lab]%s %s\n'  "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()   { printf '%s[ ok]%s %s\n'  "${C_GREEN}"  "${C_RESET}" "$*"; }
warn() { printf '%s[!! ]%s %s\n'  "${C_YELLOW}" "${C_RESET}" "$*"; }
die()  { printf '%s[err]%s %s\n'  "${C_RED}"    "${C_RESET}" "$*" >&2; exit 1; }

hr() { printf '%s\n' "-------------------------------------------------------------------------------"; }

# -----------------------------------------------------------------------------
# Safety rails. This lab mutates a DaemonSet and a Deployment; refuse to run
# anywhere that looks like it might not be disposable.
# -----------------------------------------------------------------------------
preflight() {
  log "Running preflight checks..."

  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  command -v jq      >/dev/null 2>&1 || die "jq not found in PATH (needed to read component status)."

  kubectl version --request-timeout=10s >/dev/null 2>&1 \
    || die "Cannot reach the kube-apiserver. Fix your kubeconfig before starting."

  local ctx
  ctx="$(kubectl config current-context)"
  log "Current kube context: ${C_BOLD}${ctx}${C_RESET}"

  # Refuse to run against anything that is not obviously a throwaway cluster,
  # unless the student explicitly overrides. This is the one guard that stops a
  # tired engineer from breaking Cilium in staging at 23:40.
  if [[ "${I_KNOW_THIS_IS_A_LAB:-}" != "yes" ]]; then
    case "${ctx}" in
      kind-*|minikube|default|k3d-*|*lab*|*test*|*sandbox*)
        : ;;
      *)
        die "Context '${ctx}' does not look like a disposable lab cluster.
      If it really is, re-run with:  I_KNOW_THIS_IS_A_LAB=yes $0 break"
        ;;
    esac
  fi

  local nodes
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  [[ "${nodes}" -ge 1 ]] || die "No nodes found."
  if [[ "${nodes}" -gt 3 ]]; then
    warn "This cluster has ${nodes} nodes. The lab is designed for 1-3."
  fi

  kubectl -n "${CILIUM_NS}" get daemonset "${AGENT_DS}" >/dev/null 2>&1 \
    || die "DaemonSet ${CILIUM_NS}/${AGENT_DS} not found. Is Cilium installed as the CNI?"

  ok "Preflight passed. Cluster looks like a disposable Cilium lab."
}

# -----------------------------------------------------------------------------
# Baseline: prove the cluster is healthy BEFORE we break it, and capture the
# state we will need to restore. A break & fix exercise with no baseline teaches
# nothing, because you cannot tell "broken by the lab" from "broken already".
# -----------------------------------------------------------------------------
baseline() {
  mkdir -p "${BACKUP_DIR}"

  log "Capturing baseline state into ${BACKUP_DIR} ..."

  kubectl -n "${CILIUM_NS}" get daemonset "${AGENT_DS}" -o yaml \
    > "${BACKUP_DIR}/daemonset-cilium.yaml"
  kubectl -n "${CILIUM_NS}" get deployment "${OPERATOR_DEPLOY}" -o yaml \
    > "${BACKUP_DIR}/deployment-cilium-operator.yaml" 2>/dev/null || true

  # The exact original nodeSelector of the DaemonSet, so the fix can be verified
  # against ground truth rather than against a guess.
  kubectl -n "${CILIUM_NS}" get daemonset "${AGENT_DS}" \
    -o jsonpath='{.spec.template.spec.nodeSelector}' \
    > "${BACKUP_DIR}/original-nodeselector.json" 2>/dev/null || true
  echo >> "${BACKUP_DIR}/original-nodeselector.json"

  ok "Baseline saved."

  hr
  log "Baseline health (this is what 'good' looks like — read it now, you will"
  log "want to compare against it in ten minutes):"
  hr

  kubectl -n "${CILIUM_NS}" get pods -l k8s-app=cilium -o wide || true
  echo
  kubectl -n "${CILIUM_NS}" get pods -l "io.cilium/app=operator" -o wide || true
  echo

  if command -v cilium >/dev/null 2>&1; then
    log "cilium status (CLI):"
    cilium status --wait --wait-duration 60s || warn "cilium status reported problems already."
  else
    warn "cilium CLI not installed. You can still do this lab entirely with kubectl"
    warn "plus 'kubectl -n ${CILIUM_NS} exec ds/${AGENT_DS} -- cilium-dbg status'."
  fi
}

# -----------------------------------------------------------------------------
# Workload: two Pods that talk to each other. Their traffic is what proves the
# central lesson — the eBPF datapath outlives the agent.
# -----------------------------------------------------------------------------
deploy_workload() {
  log "Deploying the lab workload in namespace ${LAB_NS} ..."

  kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<'EOF' | kubectl apply -f - >/dev/null
---
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: cca-lab-21
  labels:
    app: server
    lab: cca-2-1
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
          name: http
      readinessProbe:
        httpGet:
          path: /
          port: 80
        initialDelaySeconds: 2
        periodSeconds: 5
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: server
  namespace: cca-lab-21
spec:
  selector:
    app: server
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: cca-lab-21
  labels:
    app: client
    lab: cca-2-1
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 128Mi
EOF

  log "Waiting for the workload to become Ready (this must succeed BEFORE we break anything)..."
  kubectl -n "${LAB_NS}" wait --for=condition=Ready pod/server --timeout=180s \
    || die "server Pod never became Ready. Fix your baseline cluster first."
  kubectl -n "${LAB_NS}" wait --for=condition=Ready pod/client --timeout=180s \
    || die "client Pod never became Ready. Fix your baseline cluster first."

  log "Proving connectivity through the eBPF datapath:"
  if kubectl -n "${LAB_NS}" exec client -- \
       curl -s -o /dev/null -w 'baseline HTTP status: %{http_code}\n' \
       --max-time 10 http://server.${LAB_NS}.svc.cluster.local ; then
    ok "Pod-to-Service connectivity works. Endpoints and service maps are programmed."
  else
    die "Baseline connectivity failed. Do not start the exercise on a broken cluster."
  fi
}

# =============================================================================
#  THE BREAK
# =============================================================================
#
#  What we actually do, and why it is safe:
#
#  1. We add an impossible nodeSelector to the cilium DaemonSet
#     (cca.lab/agent-scheduled=absolutely-not). Kubernetes reacts by
#     terminating every cilium-agent Pod, because no node matches. This is a
#     pure spec change: no files are deleted, no eBPF maps are wiped, no host
#     state is touched. Reverting the nodeSelector brings every agent back.
#
#     This models a real and very common production incident: a Helm values
#     change, an admission webhook, or a node-label cleanup that accidentally
#     makes the CNI DaemonSet unschedulable. The blast radius in the real world
#     is enormous, and the symptom is genuinely confusing, because...
#
#  2. ...existing traffic keeps working. That is not a bug in the lab. That is
#     the eBPF datapath doing its job from pinned programs and maps while its
#     control plane is gone.
#
#  3. We also scale cilium-operator to 0, so identity/endpoint garbage
#     collection and cluster-pool IPAM stop. This makes the "new Pod" symptom
#     unambiguous and teaches the agent-vs-operator distinction.
#
#  Nothing here writes to /sys/fs/bpf, /etc/cni/net.d, or any node filesystem.
#  Everything is a Kubernetes object mutation, and every original object is in
#  ${BACKUP_DIR}.
#
# =============================================================================
break_it() {
  hr
  warn "BREAKING THE CILIUM CONTROL PLANE NOW."
  hr

  log "Step 1/2 — making the cilium DaemonSet unschedulable (impossible nodeSelector)."
  kubectl -n "${CILIUM_NS}" patch daemonset "${AGENT_DS}" --type=strategic -p \
    '{"spec":{"template":{"spec":{"nodeSelector":{"cca.lab/agent-scheduled":"absolutely-not"}}}}}' \
    >/dev/null
  ok "DaemonSet patched."

  log "Step 2/2 — scaling cilium-operator to 0 replicas."
  if kubectl -n "${CILIUM_NS}" get deployment "${OPERATOR_DEPLOY}" >/dev/null 2>&1; then
    kubectl -n "${CILIUM_NS}" scale deployment "${OPERATOR_DEPLOY}" --replicas=0 >/dev/null
    ok "Operator scaled to 0."
  else
    warn "cilium-operator Deployment not found; skipping (some installs name it differently)."
  fi

  log "Waiting for the agents to terminate..."
  local waited=0
  while [[ "${waited}" -lt 120 ]]; do
    local running
    running="$(kubectl -n "${CILIUM_NS}" get pods -l k8s-app=cilium \
                 --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
    [[ "${running}" -eq 0 ]] && break
    sleep 3
    waited=$(( waited + 3 ))
  done

  # A new Pod is created here on purpose: it will hang, and that hang is the
  # loudest symptom in the whole exercise.
  log "Creating a NEW Pod while the control plane is down (this is the trap)..."
  kubectl -n "${LAB_NS}" run late-arrival \
    --image=curlimages/curl:8.10.1 \
    --labels=app=late,lab=cca-2-1 \
    --command -- sleep infinity >/dev/null 2>&1 || true

  ok "Break complete."
}

# -----------------------------------------------------------------------------
# The briefing handed to the student.
# -----------------------------------------------------------------------------
briefing() {
  cat <<EOF

$(hr)
${C_BOLD}CCA LAB 2.1 — INCIDENT BRIEFING${C_RESET}
$(hr)

${C_BOLD}The page you just received:${C_RESET}

  "Platform team: nobody can deploy. Every new Pod in the cluster is stuck in
   ContainerCreating. But the app is still serving traffic and our synthetic
   checks are green, so we are not sure this is even a network problem.
   Nothing was deployed today except a routine change to node labelling."

${C_BOLD}SYMPTOMS YOU WILL OBSERVE${C_RESET}

  1. ${C_YELLOW}No cilium-agent Pods are running.${C_RESET}
       kubectl -n ${CILIUM_NS} get pods -l k8s-app=cilium
     The DaemonSet reports DESIRED 0 — not "0 available out of N", but zero
     desired. That distinction is the whole diagnosis. A crash-looping agent
     shows DESIRED N / READY 0. An unschedulable one shows DESIRED 0, because
     the scheduler found no node matching the DaemonSet's nodeSelector.

  2. ${C_YELLOW}cilium-operator has 0 replicas.${C_RESET}
       kubectl -n ${CILIUM_NS} get deploy ${OPERATOR_DEPLOY}

  3. ${C_YELLOW}The new Pod 'late-arrival' is stuck in ContainerCreating.${C_RESET}
       kubectl -n ${LAB_NS} describe pod late-arrival
     Look at the Events. You will see a CNI failure from the kubelet, along the
     lines of:
       "failed to setup network for sandbox ...: plugin type=\"cilium-cni\" ...
        Is the agent running?"
     The CNI plugin binary is still on the node — it is invoked fine. It simply
     cannot reach the local cilium-agent over its UNIX socket
     (/var/run/cilium/cilium.sock), because there is no agent to answer.

  4. ${C_GREEN}And the confusing part: the EXISTING Pods still talk to each other.${C_RESET}
       kubectl -n ${LAB_NS} exec client -- curl -s -o /dev/null -w '%{http_code}\\n' \\
         --max-time 5 http://server.${LAB_NS}.svc.cluster.local
     This still returns 200. Understand exactly why before you touch anything:
     the eBPF programs and maps are pinned in the kernel under /sys/fs/bpf and
     attached to the interfaces. They do not need a userspace process to forward
     packets. cilium-agent is the CONTROL plane; the kernel is the DATA plane.
     Killing the agent freezes the datapath — it does not erase it.

  5. Hubble is gone too (${C_YELLOW}'cilium status' shows Hubble unavailable, relay Pods
     unhealthy${C_RESET}), because Hubble's flow source is the agent's ring buffer.
     Note what this means operationally: you lost your observability at the exact
     moment you needed it. Diagnose from kubectl and the kernel instead.

${C_BOLD}WHAT YOU MUST ACHIEVE${C_RESET}

  A. Explain, in one sentence each, which Cilium component owns:
       - programming the eBPF datapath on a node
       - answering the CNI plugin when a Pod sandbox is created
       - cluster-wide identity and endpoint garbage collection
       - flow observability
  B. Determine WHY the agents are not running, using only kubectl. Distinguish
     "not scheduled" from "scheduled and failing".
  C. Restore cilium-agent on every node and cilium-operator to its original
     replica count.
  D. Get 'late-arrival' to Running WITHOUT deleting the whole namespace.
     (Think: does the kubelet retry the CNI ADD? How long does that backoff get?
     What is the cheapest correct action once the agent is back?)
  E. Verify the repair at three levels, not one:
       - Kubernetes level: all agent Pods Ready
       - Cilium level: 'cilium status' healthy, and
         'kubectl -n ${CILIUM_NS} exec ds/${AGENT_DS} -- cilium-dbg status --verbose'
         showing Controller Status, IPAM, and KubeProxyReplacement
       - Datapath level: endpoints listed and in 'ready' state
         'kubectl -n ${CILIUM_NS} exec ds/${AGENT_DS} -- cilium-dbg endpoint list'
         and end-to-end curl from client to server.

${C_BOLD}RULES${C_RESET}

  - Do not reinstall Cilium. Do not 'helm upgrade'. Do not delete the DaemonSet.
    This is a repair, not a rebuild — and in production, reinstalling the CNI
    under load is how a control-plane incident becomes a data-plane outage.
  - Do not read the solution at the bottom of this script until you have either
    fixed it or spent 20 honest minutes on it.

${C_BOLD}USEFUL COMMANDS${C_RESET}

  kubectl -n ${CILIUM_NS} get ds ${AGENT_DS} -o wide
  kubectl -n ${CILIUM_NS} describe ds ${AGENT_DS}
  kubectl -n ${CILIUM_NS} get ds ${AGENT_DS} -o jsonpath='{.spec.template.spec.nodeSelector}'
  kubectl get nodes --show-labels
  kubectl -n ${LAB_NS} describe pod late-arrival
  kubectl -n ${CILIUM_NS} get events --sort-by=.lastTimestamp | tail -30
  cilium status --wait
  cilium sysdump            # collects everything for a real support ticket

  Backups of the original objects are in: ${BACKUP_DIR}
  When you are done (or stuck), run:  $0 verify     and     $0 restore

$(hr)
EOF
}

# -----------------------------------------------------------------------------
# Verification the student can run themselves. This grades the repair; it does
# not perform it.
# -----------------------------------------------------------------------------
verify() {
  local failures=0

  hr
  log "VERIFYING THE REPAIR"
  hr

  # 1. DaemonSet desired count must equal the number of schedulable nodes.
  local desired ready nodes
  desired="$(kubectl -n "${CILIUM_NS}" get ds "${AGENT_DS}" -o jsonpath='{.status.desiredNumberScheduled}')"
  ready="$(kubectl -n "${CILIUM_NS}" get ds "${AGENT_DS}" -o jsonpath='{.status.numberReady}')"
  nodes="$(kubectl get nodes --no-headers | wc -l)"

  if [[ "${desired}" -eq 0 ]]; then
    warn "FAIL (B/C): DaemonSet desiredNumberScheduled is 0 — the agent is still unschedulable."
    failures=$(( failures + 1 ))
  elif [[ "${ready}" -lt "${desired}" ]]; then
    warn "FAIL (C): ${ready}/${desired} agents Ready."
    failures=$(( failures + 1 ))
  else
    ok "PASS (C): cilium-agent Ready on ${ready}/${desired} scheduled nodes (${nodes} nodes total)."
  fi

  # 2. Operator restored.
  if kubectl -n "${CILIUM_NS}" get deployment "${OPERATOR_DEPLOY}" >/dev/null 2>&1; then
    local opready
    opready="$(kubectl -n "${CILIUM_NS}" get deploy "${OPERATOR_DEPLOY}" -o jsonpath='{.status.readyReplicas}')"
    opready="${opready:-0}"
    if [[ "${opready}" -ge 1 ]]; then
      ok "PASS (C): cilium-operator has ${opready} ready replica(s)."
    else
      warn "FAIL (C): cilium-operator has 0 ready replicas."
      failures=$(( failures + 1 ))
    fi
  fi

  # 3. The stuck Pod must be Running.
  local latephase
  latephase="$(kubectl -n "${LAB_NS}" get pod late-arrival -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
  if [[ "${latephase}" == "Running" ]]; then
    ok "PASS (D): 'late-arrival' is Running — the CNI ADD succeeded against a live agent."
  else
    warn "FAIL (D): 'late-arrival' is in phase '${latephase}'."
    failures=$(( failures + 1 ))
  fi

  # 4. Datapath end to end.
  local code
  code="$(kubectl -n "${LAB_NS}" exec client -- curl -s -o /dev/null -w '%{http_code}' \
            --max-time 10 "http://server.${LAB_NS}.svc.cluster.local" 2>/dev/null || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok "PASS (E): client -> Service -> server returns 200."
  else
    warn "FAIL (E): client -> Service returned '${code}'."
    failures=$(( failures + 1 ))
  fi

  # 5. Agent-level self-report.
  if kubectl -n "${CILIUM_NS}" exec ds/"${AGENT_DS}" -- cilium-dbg status --brief >/dev/null 2>&1; then
    ok "PASS (E): 'cilium-dbg status' answers from inside the agent."
    kubectl -n "${CILIUM_NS}" exec ds/"${AGENT_DS}" -- cilium-dbg status \
      | sed -n '1,25p' || true
  else
    warn "FAIL (E): cannot get a status answer from the agent."
    failures=$(( failures + 1 ))
  fi

  hr
  if [[ "${failures}" -eq 0 ]]; then
    ok "${C_BOLD}ALL CHECKS PASSED.${C_RESET} Cilium's control plane and datapath are both healthy."
  else
    warn "${failures} check(s) failed. Keep going — or read the solution at the end of this script."
  fi
  hr
  return 0
}

# -----------------------------------------------------------------------------
# Escape hatch. Restores from the backup taken at break time and cleans the lab
# namespace. Use it when you are done, or when you want to reset and retry.
# -----------------------------------------------------------------------------
restore() {
  hr
  log "RESTORING the cluster to its pre-lab state."
  hr

  log "Removing the injected nodeSelector from the ${AGENT_DS} DaemonSet..."
  # A JSON-merge patch with an explicit null is the correct way to delete a map
  # key; a strategic merge with {} would leave the key in place.
  kubectl -n "${CILIUM_NS}" patch daemonset "${AGENT_DS}" --type=merge -p \
    '{"spec":{"template":{"spec":{"nodeSelector":null}}}}' >/dev/null

  # Restore whatever nodeSelector the install genuinely had, if any.
  if [[ -s "${BACKUP_DIR}/original-nodeselector.json" ]]; then
    local orig
    orig="$(tr -d '\n' < "${BACKUP_DIR}/original-nodeselector.json")"
    if [[ -n "${orig}" && "${orig}" != "null" && "${orig}" != "{}" ]]; then
      log "Reapplying the original nodeSelector: ${orig}"
      kubectl -n "${CILIUM_NS}" patch daemonset "${AGENT_DS}" --type=merge -p \
        "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":${orig}}}}}" >/dev/null
    fi
  fi

  log "Scaling cilium-operator back to 1 replica..."
  kubectl -n "${CILIUM_NS}" scale deployment "${OPERATOR_DEPLOY}" --replicas=1 >/dev/null 2>&1 || true

  log "Waiting for the agent rollout..."
  kubectl -n "${CILIUM_NS}" rollout status daemonset/"${AGENT_DS}" --timeout=300s || true

  log "Deleting the lab namespace ${LAB_NS}..."
  kubectl delete namespace "${LAB_NS}" --wait=false >/dev/null 2>&1 || true

  ok "Restore finished. Run '$0 verify' if you want the checks, or 'cilium status --wait'."
}

usage() {
  cat <<EOF
CCA Lab 2.1 — Cilium Architecture & Components (break & fix)

Usage:
  $0 break     Run preflight, capture a baseline, deploy the workload, break it,
               and print the incident briefing.  <-- start here
  $0 verify    Grade your repair against the objectives.
  $0 restore   Undo everything and clean up.
  $0 briefing  Reprint the incident briefing.

Environment:
  CILIUM_NS=${CILIUM_NS}   LAB_NS=${LAB_NS}   BACKUP_DIR=${BACKUP_DIR}
  I_KNOW_THIS_IS_A_LAB=yes   bypass the context-name safety check
EOF
}

main() {
  case "${1:-}" in
    break)
      preflight
      baseline
      deploy_workload
      break_it
      briefing
      ;;
    verify)   verify   ;;
    restore)  restore  ;;
    briefing) briefing ;;
    *)        usage; exit 1 ;;
  esac
}

main "$@"

# =============================================================================
# =============================================================================
#
#   S O L U T I O N   —   stop reading unless you are done or stuck.
#
# =============================================================================
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Frame the problem before typing. Which plane is broken?
# ---------------------------------------------------------------------------
#
#   Two facts arrive together:
#     (a) new Pods cannot get networking,
#     (b) existing Pods still communicate.
#
#   Only one architecture explains both at once: the DATA plane is intact and
#   the CONTROL plane is dead. In Cilium the data plane is eBPF bytecode and
#   maps living in the kernel, pinned under /sys/fs/bpf and attached to tc
#   hooks / XDP on the interfaces. The control plane is cilium-agent, which
#   compiles, loads and updates all of that.
#
#   So: do NOT start by looking at routes, iptables or the CNI config on disk.
#   Start by asking whether cilium-agent is alive.
#
#     $ kubectl -n kube-system get pods -l k8s-app=cilium
#     No resources found in kube-system namespace.
#
# ---------------------------------------------------------------------------
# STEP 1 — Distinguish "not scheduled" from "scheduled and crashing"
# ---------------------------------------------------------------------------
#
#   This is the single most important diagnostic step, and it is one line:
#
#     $ kubectl -n kube-system get ds cilium
#     NAME     DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR                         AGE
#     cilium   0         0         0       0            0           cca.lab/agent-scheduled=absolutely-not  1h
#
#   Read those numbers carefully:
#
#     DESIRED 0  -> the DaemonSet controller decided that ZERO nodes should run
#                   this Pod. The kubelet never got involved. Nothing crashed.
#                   The cause is a scheduling constraint: nodeSelector, node
#                   affinity, taints without matching tolerations, or a
#                   ValidatingAdmissionWebhook rejecting the Pod.
#
#     DESIRED N, READY 0 -> a completely different failure: the Pods ARE placed
#                   and are failing (CrashLoopBackOff, ImagePullBackOff, failing
#                   to mount bpffs, unable to reach the apiserver...). That is
#                   when you go read agent logs.
#
#   Here the NODE SELECTOR column names the culprit outright. Confirm it:
#
#     $ kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.nodeSelector}'
#     {"cca.lab/agent-scheduled":"absolutely-not"}
#
#     $ kubectl get nodes --show-labels | grep -c 'cca.lab/agent-scheduled'
#     0
#
#   No node carries that label, so the DaemonSet controller correctly schedules
#   the agent nowhere. The cluster is behaving exactly as instructed — it was
#   instructed wrongly. (Real-world equivalents: a Helm values.yaml with a
#   stale `nodeSelector`, a `kubectl label node --overwrite` sweep, or a
#   cluster-autoscaler node template that lost a label.)
#
#   Also confirm the second half of the damage:
#
#     $ kubectl -n kube-system get deploy cilium-operator
#     NAME              READY   UP-TO-DATE   AVAILABLE   AGE
#     cilium-operator   0/0     0            0           1h
#
# ---------------------------------------------------------------------------
# STEP 2 — Confirm the CNI failure mode on the stuck Pod
# ---------------------------------------------------------------------------
#
#     $ kubectl -n cca-lab-21 describe pod late-arrival | tail -20
#     Events:
#       Type     Reason                  Age                 From     Message
#       ----     ------                  ----                ----     -------
#       Normal   Scheduled               3m                  default-scheduler  Successfully assigned ...
#       Warning  FailedCreatePodSandBox  2m (x8 over 3m)     kubelet  Failed to create pod sandbox:
#         rpc error: code = Unknown desc = failed to setup network for sandbox "a1b2c3...":
#         plugin type="cilium-cni" name="cilium" failed (add):
#         unable to connect to Cilium daemon: failed to create cilium agent client after 30.0 seconds
#         timeout: Get "http:///var/run/cilium/cilium.sock/v1/config": dial unix /var/run/cilium/cilium.sock:
#         connect: no such file or directory
#
#   Read the error literally, because it names the architecture:
#
#     - The kubelet DID call the CNI plugin. So /etc/cni/net.d and
#       /opt/cni/bin/cilium-cni are fine — this is not a CNI installation
#       problem.
#     - cilium-cni is a short-lived binary with no state of its own. Its whole
#       job is to ask the LOCAL agent, over the UNIX socket
#       /var/run/cilium/cilium.sock, to allocate an IP, create the endpoint,
#       and program the datapath for this new Pod.
#     - The socket does not exist because the agent that creates it is gone.
#
#   Note who is NOT at fault: the operator. In cluster-pool IPAM the operator
#   hands CIDR blocks to nodes, but the per-Pod allocation is the agent's job.
#   Restarting only the operator would fix nothing here.
#
# ---------------------------------------------------------------------------
# STEP 3 — Prove the datapath survived (the lesson worth remembering)
# ---------------------------------------------------------------------------
#
#     $ kubectl -n cca-lab-21 exec client -- curl -s -o /dev/null -w '%{http_code}\n' \
#         --max-time 5 http://server.cca-lab-21.svc.cluster.local
#     200
#
#   With zero cilium-agents running. If you have shell on the node:
#
#     $ sudo ls /sys/fs/bpf/tc/globals/
#     cilium_call_policy   cilium_calls_00123   cilium_ct4_global   cilium_ipcache
#     cilium_lb4_backends_v3  cilium_lb4_services_v2  cilium_lxc  cilium_policy_00123
#     ...
#     $ sudo bpftool net show
#     tc:
#     lxc1a2b3c4d5e6f(7) clsact/ingress cil_from_container id 245
#     ...
#
#   The programs are still attached and the maps still hold endpoints,
#   identities, connection-tracking entries and service backends. Forwarding
#   never needed userspace.
#
#   What you HAVE lost while the agent is down:
#     - new endpoint creation (new Pods)                -> hard failure
#     - identity allocation / label changes             -> frozen
#     - NetworkPolicy and CiliumNetworkPolicy updates   -> frozen at last state
#     - Service/backend updates from EndpointSlice      -> frozen (existing
#       services keep working with their last-known backends; a Pod that dies
#       stays in the lb map as a stale backend until an agent reconciles)
#     - L7 policy and toFQDNs                           -> degraded, because the
#       agent hosts the Envoy/DNS proxy that enforces them
#     - Hubble flow observability                       -> gone
#
#   That list is exactly why "the agent is down but traffic is fine" is a
#   P1, not a P3: you are running on frozen state that decays as the cluster
#   changes underneath it.
#
# ---------------------------------------------------------------------------
# STEP 4 — Repair. Remove the impossible constraint.
# ---------------------------------------------------------------------------
#
#   Delete the nodeSelector key. Use a JSON merge patch with an explicit null:
#   a strategic-merge patch of {} will NOT remove an existing map key.
#
#     $ kubectl -n kube-system patch daemonset cilium --type=merge \
#         -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
#     daemonset.apps/cilium patched
#
#   (The equally valid alternatives, and when each is right:
#      - JSON patch, surgical, fails loudly if the path is absent:
#          kubectl -n kube-system patch daemonset cilium --type=json \
#            -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/cca.lab~1agent-scheduled"}]'
#            ^ note ~1 — that is the JSON Pointer escape for "/" in a key.
#      - If the "right" answer is that the LABEL should exist rather than the
#        selector be dropped — which is the case in installs that genuinely
#        pin the CNI to a node pool — then label the nodes instead:
#          kubectl label nodes --all cca.lab/agent-scheduled=yes
#        Deciding which of these two is correct requires knowing the intended
#        install topology. In this lab the selector is the intruder, so remove it.
#      - In a Helm-managed install, the durable fix is `helm upgrade` with the
#        corrected values, because your kubectl patch will be reverted by the
#        next reconcile. Patch to stop the bleeding, then fix the source.)
#
#   Bring the operator back:
#
#     $ kubectl -n kube-system scale deployment cilium-operator --replicas=1
#     deployment.apps/cilium-operator scaled
#
#   Watch the agents return:
#
#     $ kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
#     daemon set "cilium" successfully rolled out
#
#     $ kubectl -n kube-system get pods -l k8s-app=cilium -o wide
#     NAME           READY   STATUS    RESTARTS   AGE   NODE
#     cilium-x7k2q   1/1     Running   0          48s   kind-control-plane
#
# ---------------------------------------------------------------------------
# STEP 5 — Recover the stuck Pod
# ---------------------------------------------------------------------------
#
#   The kubelet retries FailedCreatePodSandBox with exponential backoff, capped
#   at 5 minutes. So the honest answer is: wait, and it heals itself.
#
#     $ kubectl -n cca-lab-21 get pod late-arrival -w
#     late-arrival   0/1   ContainerCreating   0   6m
#     late-arrival   1/1   Running             0   7m
#
#   If you do not want to wait out a 5-minute backoff, delete the Pod so a new
#   sandbox is attempted immediately:
#
#     $ kubectl -n cca-lab-21 delete pod late-arrival --now
#
#   For a Deployment/StatefulSet the same idea applies at scale:
#     kubectl -n <ns> delete pod -l app=<x> --field-selector=status.phase=Pending
#   Never delete the namespace — you would destroy the evidence and the
#   workload along with the symptom.
#
# ---------------------------------------------------------------------------
# STEP 6 — Verify at three levels. One green check is not a verification.
# ---------------------------------------------------------------------------
#
#   Level 1, Kubernetes:
#
#     $ kubectl -n kube-system get ds cilium
#     NAME     DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
#     cilium   1         1         1       1            1           <none>          1h
#
#   Level 2, Cilium control plane:
#
#     $ cilium status --wait
#         /¯¯\
#      /¯¯\__/¯¯\    Cilium:             OK
#      \__/¯¯\__/    Operator:           OK
#      /¯¯\__/¯¯\    Envoy DaemonSet:    OK
#      \__/¯¯\__/    Hubble Relay:       OK
#         \__/       ClusterMesh:        disabled
#
#     Deployment        cilium-operator    Desired: 1, Ready: 1/1, Available: 1/1
#     DaemonSet         cilium             Desired: 1, Ready: 1/1, Available: 1/1
#     Containers:       cilium             Running: 1
#                       cilium-operator    Running: 1
#
#     $ kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | head -30
#     KVStore:                 Ok   Disabled
#     Kubernetes:              Ok   1.31 (v1.31.0) [linux/amd64]
#     KubeProxyReplacement:    True [eth0 172.18.0.2 fc00:c111::2 (Direct Routing)]
#     Host firewall:           Disabled
#     CNI Chaining:            none
#     Cilium:                  Ok   1.16.5 (v1.16.5-xxxxxxx)
#     NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
#     Cilium health daemon:    Ok
#     IPAM:                    IPv4: 4/254 allocated from 10.0.0.0/24,
#     Controller Status:       48/48 healthy
#     Proxy Status:            OK, ip 10.0.0.145, 0 redirects active on ports 10000-20000
#     Hubble:                  Ok   Current/Max Flows: 4095/4095 (100.00%)
#
#     Read three fields specifically:
#       Controller Status  — the agent's internal reconciliation controllers.
#                            Anything other than N/N healthy means it came back
#                            but is not reconciling cleanly.
#       IPAM               — proves per-node CIDR and per-Pod allocation work.
#       KubeProxyReplacement — proves the service datapath is programmed.
#
#   Level 3, the datapath itself:
#
#     $ kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
#     ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS                              IPv4          STATUS
#                ENFORCEMENT        ENFORCEMENT
#     291        Disabled           Disabled          4          reserved:health                     10.0.0.36     ready
#     628        Disabled           Disabled          12905      k8s:app=server                      10.0.0.211    ready
#     1443       Disabled           Disabled          19226      k8s:app=client                      10.0.0.87     ready
#     2011       Disabled           Disabled          31877      k8s:app=late                        10.0.0.145    ready
#     3455       Disabled           Disabled          1          reserved:host                                     ready
#
#     Every endpoint must be 'ready'. States like 'waiting-for-identity' or
#     'regenerating' that persist mean the agent is up but not converging —
#     usually an apiserver connectivity or identity-backend problem.
#
#     $ kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
#     ID   Frontend             Service Type   Backend
#     1    10.96.0.1:443        ClusterIP      1 => 172.18.0.2:6443 (active)
#     4    10.96.148.22:80      ClusterIP      1 => 10.0.0.211:80 (active)
#
#     $ kubectl -n cca-lab-21 exec client -- curl -s -o /dev/null -w '%{http_code}\n' \
#         http://server.cca-lab-21.svc.cluster.local
#     200
#
#     And the built-in end-to-end suite, which is what you would actually run
#     before declaring an incident closed:
#
#     $ cilium connectivity test --test-namespace cca-connectivity
#     ... ✅ All 48 tests (XXX actions) successful ...
#
# ---------------------------------------------------------------------------
# STEP 7 — Answers to objective A (component ownership)
# ---------------------------------------------------------------------------
#
#   Programming the eBPF datapath on a node
#     cilium-agent. It compiles/loads the BPF programs, attaches them to tc and
#     XDP hooks, and owns every BPF map (cilium_lxc, cilium_ipcache,
#     cilium_policy_*, cilium_ct4_global, cilium_lb4_services_v2, ...). One
#     agent per node, and it is authoritative only for its own node.
#
#   Answering the CNI plugin on Pod sandbox creation
#     cilium-agent again, via its REST API on the UNIX socket
#     /var/run/cilium/cilium.sock. The cilium-cni binary is a thin, stateless
#     client the kubelet execs; it holds no state and makes no decisions.
#
#   Cluster-wide identity and endpoint garbage collection
#     cilium-operator. It reaps stale CiliumIdentity and CiliumEndpoint objects,
#     manages cluster-pool IPAM CIDR allocation per CiliumNode, and performs
#     other once-per-cluster duties. It is off the packet path entirely: a dead
#     operator degrades the cluster slowly (identity leakage, no IPAM for new
#     nodes), it does not drop packets.
#
#   Flow observability
#     Hubble. The observation points are compiled into the agent's eBPF
#     programs; the agent exposes them locally, hubble-relay aggregates across
#     nodes, and hubble-ui / the `hubble` CLI consume the aggregate. Losing
#     Hubble costs visibility, never connectivity — which is precisely why it
#     goes dark exactly when you need it, as it did in this incident.
#
# ---------------------------------------------------------------------------
# STEP 8 — Reset the lab
# ---------------------------------------------------------------------------
#
#     $ ./cca-2.1-break-fix.sh restore
#
# ---------------------------------------------------------------------------
# References
#   https://docs.cilium.io/en/stable/overview/component-overview/
#   https://docs.cilium.io/en/stable/network/ebpf/
#   https://docs.cilium.io/en/stable/operations/troubleshooting/
#   https://docs.cilium.io/en/stable/cmdref/cilium-dbg_status/
#   https://docs.cilium.io/en/stable/cmdref/cilium-operator/
#   https://docs.cilium.io/en/stable/network/kubernetes/troubleshooting/
#   https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
#   https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
# ---------------------------------------------------------------------------