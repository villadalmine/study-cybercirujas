#!/usr/bin/env bash
#
# ==============================================================================
#  CKS 1.34 — Domain 6: Monitoring, Logging and Runtime Security
#  Topic 6.3 — Investigate and identify phases of attack and bad actors
#              within the environment
# ==============================================================================
#
#  BREAK & FIX lab.  This script SIMULATES a multi-stage cluster compromise so
#  that the student can practise incident investigation: enumerate the artifacts
#  a bad actor left behind, map each one to a phase of the attack lifecycle
#  (MITRE ATT&CK for Containers), and remediate surgically.
#
#  >>> RUN ONLY ON A DISPOSABLE, SINGLE-NODE KUBERNETES LAB VM <<<
#  (kubeadm / kind / minikube).  It creates privileged pods, a cluster-admin
#  binding, a kube-system CronJob and — if it can — a rogue static Pod manifest
#  on the node.  Nothing here beacons to the Internet or destroys host data:
#  the "malicious" workloads only write to /tmp inside their own containers and
#  mount the host filesystem to *demonstrate* a node-escape indicator.  Even so,
#  never point it at a cluster you care about.
#
#  Usage:
#     ./break_fix.sh break     # plant the attack + print the incident briefing
#     ./break_fix.sh verify     # self-grade: did you remediate every artifact?
#     ./break_fix.sh clean      # instructor reset (also IS the fix; see bottom)
#
#  Skip the interactive guard in automation with:  CONFIRM=yes ./break_fix.sh break
#
#  References (original summaries only; consult the sources directly):
#   - CKS Curriculum v1.34
#       https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#   - Kubernetes — Auditing
#       https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
#   - Kubernetes — Static Pods
#       https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
#   - Kubernetes — Security Checklist
#       https://kubernetes.io/docs/concepts/security/security-checklist/
#   - MITRE ATT&CK — Containers matrix
#       https://attack.mitre.org/matrices/enterprise/containers/
#   - Microsoft — Threat matrix for Kubernetes
#       https://www.microsoft.com/en-us/security/blog/2021/03/23/secure-containerized-environments-with-updated-threat-matrix-for-kubernetes/
#   - Falco — Runtime security
#       https://falco.org/docs/
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration — names of the artifacts the "bad actor" plants.
# ------------------------------------------------------------------------------
NS="dev"                                   # victim namespace (relabelled by attacker)
IMAGE="${IMAGE:-busybox:1.36}"             # override if your lab has no egress
LEGIT_DEPLOY="payment-api"                 # benign workload = noise, DO NOT delete
BEACHHEAD_POD="support-tools"              # malicious foothold pod
ATTACKER_SA="support-sa"                   # rogue ServiceAccount
ATTACKER_CRB="support-sa-cluster-admin"    # rogue cluster-admin binding
ATTACKER_CRON="metrics-collector"          # persistence CronJob in kube-system
EXFIL_SECRET="exfil-token"                 # stashed stolen credential
STATIC_POD="kube-proxy-audit"              # node-level static-pod persistence
MANIFEST_DIR="${MANIFEST_DIR:-/etc/kubernetes/manifests}"
STATIC_MANIFEST="${MANIFEST_DIR}/${STATIC_POD}.yaml"

# ------------------------------------------------------------------------------
# Pretty logging.
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
  R=$'\033[0m'; B=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
else
  R=""; B=""; RED=""; GRN=""; YEL=""; CYN=""
fi
info()  { printf '%s[*]%s %s\n' "$CYN" "$R" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$YEL" "$R" "$*"; }
die()   { printf '%s[x]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

kc() { kubectl "$@"; }

# ------------------------------------------------------------------------------
# Safety guards.
# ------------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kc cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster. Check your kubeconfig/context."

  local ctx; ctx="$(kc config current-context 2>/dev/null || echo unknown)"
  if printf '%s' "$ctx" | grep -qiE 'prod|production|live'; then
    die "Current context '$ctx' looks like PRODUCTION. Refusing to run. Switch contexts first."
  fi

  info "Target context: ${B}${ctx}${R}"
  if [ "${CONFIRM:-}" != "yes" ]; then
    if [ -t 0 ]; then
      read -r -p "This will DELIBERATELY compromise this cluster. Type 'break' to continue: " a
      [ "$a" = "break" ] || die "Aborted."
    else
      die "Non-interactive run: set CONFIRM=yes to acknowledge this is a disposable lab."
    fi
  fi
}

# ------------------------------------------------------------------------------
# BREAK — plant the multi-phase compromise.
# ------------------------------------------------------------------------------
plant() {
  preflight

  info "Phase 0 — staging: creating victim namespace and a legitimate workload (noise)."
  # Defense Evasion (T1610-ish): attacker weakens Pod Security so privileged
  # pods can be scheduled here, then hides malicious pods among legit ones.
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
    pod-security.kubernetes.io/audit: privileged
EOF

  cat <<EOF | kc apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${LEGIT_DEPLOY}
  namespace: ${NS}
  labels: { app: payment-api }
spec:
  replicas: 2
  selector: { matchLabels: { app: payment-api } }
  template:
    metadata: { labels: { app: payment-api } }
    spec:
      containers:
      - name: api
        image: ${IMAGE}
        command: ["/bin/sh","-c","while true; do sleep 3600; done"]
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 10001
EOF

  info "Phase 1 — Initial Access / Privilege Escalation: rogue ServiceAccount bound to cluster-admin."
  # Persistence + Privilege Escalation: a Secret-backed identity that survives
  # pod restarts and grants full cluster control.
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ATTACKER_SA}
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${ATTACKER_CRB}
  labels: { app.kubernetes.io/managed-by: support-tooling }
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: ${ATTACKER_SA}
  namespace: ${NS}
EOF

  info "Phase 2 — Execution / Node access: privileged, hostPID beachhead pod mounting the host root."
  # Execution (T1610 Deploy Container) + Escape to Host (T1611): privileged,
  # hostPID/hostNetwork, hostPath '/' mounted read-write. Labelled 'app=payment-api'
  # to blend in with the legitimate Deployment (Defense Evasion via masquerading).
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${BEACHHEAD_POD}
  namespace: ${NS}
  labels: { app: payment-api }
spec:
  serviceAccountName: ${ATTACKER_SA}
  hostPID: true
  hostNetwork: true
  containers:
  - name: shell
    image: ${IMAGE}
    command: ["/bin/sh","-c","while true; do echo \"beacon \$(date -u)\" >> /tmp/.beacon.log; sleep 30; done"]
    securityContext:
      privileged: true
      runAsUser: 0
    volumeMounts:
    - { name: hostroot, mountPath: /host }
  volumes:
  - name: hostroot
    hostPath: { path: /, type: Directory }
EOF

  info "Phase 3 — Credential Access: stolen token stashed as a Secret in ${NS}."
  # Collection/Credential Access: attacker parks an exfiltrated token in-cluster.
  kc -n "$NS" create secret generic "$EXFIL_SECRET" \
     --from-literal=stolen_sa_token="eyJhbGciOiJSUzI1NiIsImtpZCI6IkZBS0UtRVhGSUwtVE9LRU4ifQ.FAKE.FAKE" \
     --dry-run=client -o yaml | kc apply -f - >/dev/null

  info "Phase 4 — Persistence (scheduled): privileged CronJob hiding in kube-system."
  # Persistence (Scheduled Task/Job): re-establishes a privileged foothold every
  # minute, named to look like a platform component.
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${ATTACKER_CRON}
  namespace: kube-system
  labels: { k8s-app: metrics-collector }
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          hostPID: true
          restartPolicy: Never
          containers:
          - name: collector
            image: ${IMAGE}
            command: ["/bin/sh","-c","echo persistence beacon; sleep 20"]
            securityContext:
              privileged: true
              runAsUser: 0
            volumeMounts:
            - { name: hostroot, mountPath: /host }
          volumes:
          - name: hostroot
            hostPath: { path: / }
EOF

  info "Phase 5 — Persistence (node): attempting to plant a rogue static Pod manifest."
  # Persistence via static Pod: kubelet auto-runs any manifest in the manifests
  # dir; it survives 'kubectl delete' because the file, not the API server, is
  # the source of truth. Guarded — needs write access (root) to the node dir.
  if [ -d "$MANIFEST_DIR" ]; then
    local wrote=0
    if [ -w "$MANIFEST_DIR" ]; then
      write_static_pod | tee "$STATIC_MANIFEST" >/dev/null && wrote=1
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      write_static_pod | sudo tee "$STATIC_MANIFEST" >/dev/null && wrote=1
    fi
    if [ "$wrote" = 1 ]; then
      ok "Static Pod manifest written: ${STATIC_MANIFEST} (mirror Pod will appear in kube-system)."
    else
      warn "No write access to ${MANIFEST_DIR}; skipped node persistence. Re-run with sudo for the full lab."
    fi
  else
    warn "${MANIFEST_DIR} not present (not a kubeadm node?); skipped the static-Pod phase."
  fi

  briefing
}

write_static_pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${STATIC_POD}
  namespace: kube-system
  labels: { component: kube-proxy-audit, tier: node }
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
EOF
}

# ------------------------------------------------------------------------------
# Incident briefing shown to the student.
# ------------------------------------------------------------------------------
briefing() {
  cat <<'TXT'

================================================================================
                        SECURITY INCIDENT — BRIEFING
================================================================================
At 02:14 UTC your runtime sensor fired. A privileged container with hostPID was
observed reading the node filesystem, and RBAC changes were logged shortly
after. You are the on-call responder. The attacker is still assumed present.

WHAT YOU WILL SEE (the symptoms)
  - An unexpected Pod running privileged / hostPID / hostNetwork in a workload
    namespace, mounting the host root ('/') — a classic node-escape indicator.
  - A ClusterRoleBinding granting cluster-admin to a ServiceAccount that no
    platform component should own.
  - A CronJob in kube-system that spins up a privileged Pod every minute.
  - Possibly a Pod in kube-system whose name ends in your node's hostname but
    that has NO owning controller and cannot be deleted normally (static Pod).
  - A Secret in a workload namespace holding a stolen token.
  - A namespace whose Pod Security 'enforce' level was lowered to 'privileged'.

YOUR OBJECTIVES (what "fixed" means)
  1. INVESTIGATE. Reconstruct the kill chain and map each artifact to a phase:
     Initial Access -> Execution -> Privilege Escalation -> Credential Access
     -> Persistence -> Defense Evasion. Write down which object belongs where.
  2. CONTAIN & ERADICATE, SURGICALLY. Remove every attacker artifact:
       * the beachhead Pod, the rogue ServiceAccount and its cluster-admin CRB,
       * the kube-system CronJob, the stolen-token Secret,
       * the rogue static Pod (delete the MANIFEST FILE on the node, not just
         the mirror Pod), and
       * restore the namespace's Pod Security enforce level (baseline/restricted).
     Do NOT delete the legitimate 'payment-api' Deployment — a good responder
     removes the threat without taking down production.

Self-grade any time with:   ./break_fix.sh verify
Full walkthrough is at the bottom of this script (commented out) — try first.
================================================================================
TXT
}

# ------------------------------------------------------------------------------
# VERIFY — grade the student's remediation.
# ------------------------------------------------------------------------------
verify() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
  local fails=0

  check_absent() { # <desc> <kubectl get args...>
    local desc="$1"; shift
    if kc "$@" >/dev/null 2>&1; then
      printf '%s[FAIL]%s %s still present.\n' "$RED" "$R" "$desc"; fails=$((fails+1))
    else
      printf '%s[PASS]%s %s removed.\n' "$GRN" "$R" "$desc"
    fi
  }

  check_absent "Beachhead Pod ${NS}/${BEACHHEAD_POD}"      -n "$NS" get pod "$BEACHHEAD_POD"
  check_absent "Rogue ServiceAccount ${NS}/${ATTACKER_SA}" -n "$NS" get sa "$ATTACKER_SA"
  check_absent "cluster-admin binding ${ATTACKER_CRB}"     get clusterrolebinding "$ATTACKER_CRB"
  check_absent "kube-system CronJob ${ATTACKER_CRON}"      -n kube-system get cronjob "$ATTACKER_CRON"
  check_absent "Stolen-token Secret ${NS}/${EXFIL_SECRET}" -n "$NS" get secret "$EXFIL_SECRET"

  # Belt-and-suspenders: no ClusterRoleBinding may still bind our SA to admin.
  if kc get clusterrolebindings -o jsonpath="{range .items[?(@.roleRef.name=='cluster-admin')]}{.subjects[*].name}{'\n'}{end}" 2>/dev/null | grep -q "$ATTACKER_SA"; then
    printf '%s[FAIL]%s A cluster-admin binding still references %s.\n' "$RED" "$R" "$ATTACKER_SA"; fails=$((fails+1))
  else
    printf '%s[PASS]%s No cluster-admin binding references the rogue SA.\n' "$GRN" "$R"
  fi

  # Static Pod: the FILE is the source of truth; also confirm the mirror Pod is gone.
  if [ -e "$STATIC_MANIFEST" ]; then
    printf '%s[FAIL]%s Static Pod manifest %s still on the node.\n' "$RED" "$R" "$STATIC_MANIFEST"; fails=$((fails+1))
  elif kc -n kube-system get pods -o name 2>/dev/null | grep -q "/${STATIC_POD}-"; then
    printf '%s[FAIL]%s Static mirror Pod %s* still running (delete the manifest FILE).\n' "$RED" "$R" "$STATIC_POD"; fails=$((fails+1))
  else
    printf '%s[PASS]%s Node static-Pod persistence removed.\n' "$GRN" "$R"
  fi

  # Defense evasion undone: namespace must no longer enforce 'privileged'.
  local enf; enf="$(kc get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
  if [ "$enf" = "privileged" ]; then
    printf '%s[FAIL]%s Namespace %s still enforces Pod Security level "privileged".\n' "$RED" "$R" "$NS"; fails=$((fails+1))
  else
    printf '%s[PASS]%s Namespace %s Pod Security restored (enforce="%s").\n' "$GRN" "$R" "$NS" "${enf:-<none>}"
  fi

  # Surgical remediation: legit workload must survive.
  if kc -n "$NS" get deploy "$LEGIT_DEPLOY" >/dev/null 2>&1; then
    printf '%s[PASS]%s Legitimate workload %s/%s preserved.\n' "$GRN" "$R" "$NS" "$LEGIT_DEPLOY"
  else
    printf '%s[FAIL]%s You deleted the legitimate Deployment %s/%s — remediate surgically.\n' "$RED" "$R" "$NS" "$LEGIT_DEPLOY"; fails=$((fails+1))
  fi

  echo
  if [ "$fails" -eq 0 ]; then
    ok "ALL CHECKS PASSED — environment eradicated and hardened. Incident closed."
  else
    die "$fails check(s) failing. Keep investigating — the bad actor still has a foothold."
  fi
}

# ------------------------------------------------------------------------------
# CLEAN — instructor reset. This is exactly the remediation the student performs.
# ------------------------------------------------------------------------------
clean() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
  info "Eradicating attacker artifacts..."
  kc -n "$NS" delete pod "$BEACHHEAD_POD"         --ignore-not-found >/dev/null 2>&1 || true
  kc delete clusterrolebinding "$ATTACKER_CRB"    --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$NS" delete sa "$ATTACKER_SA"            --ignore-not-found >/dev/null 2>&1 || true
  kc -n kube-system delete cronjob "$ATTACKER_CRON" --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$NS" delete secret "$EXFIL_SECRET"       --ignore-not-found >/dev/null 2>&1 || true
  kc label ns "$NS" \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/warn=baseline \
     pod-security.kubernetes.io/audit=baseline --overwrite >/dev/null 2>&1 || true

  if [ -e "$STATIC_MANIFEST" ]; then
    if [ -w "$STATIC_MANIFEST" ] || [ -w "$MANIFEST_DIR" ]; then
      rm -f "$STATIC_MANIFEST"
    elif command -v sudo >/dev/null 2>&1; then
      sudo rm -f "$STATIC_MANIFEST"
    fi
    ok "Removed static Pod manifest ${STATIC_MANIFEST}."
  fi
  ok "Cleanup complete. Run './break_fix.sh verify' to confirm."
}

usage() {
  cat <<TXT
CKS 6.3 break & fix — investigate and identify phases of attack.

  ${0##*/} break     Plant the simulated compromise and print the briefing.
  ${0##*/} verify    Check whether every attacker artifact has been remediated.
  ${0##*/} clean     Reset the lab (this is also the reference remediation).

Env:  CONFIRM=yes  IMAGE=<img>  MANIFEST_DIR=/etc/kubernetes/manifests
TXT
}

main() {
  case "${1:-}" in
    break|"") plant ;;
    verify)   verify ;;
    clean)    clean ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: $1" ;;
  esac
}

main "$@"

# ==============================================================================
#  SOLUTION — step-by-step investigation and remediation (try before reading!)
# ==============================================================================
#
#  Mindset: you are reconstructing an attack from the evidence it left, exactly
#  as CKS 6.3 asks. Work outside-in: broad triage first, then confirm each
#  artifact, map it to a phase, and only then eradicate.
#
#  ------------------------------------------------------------------------------
#  STEP 1 — Triage: what is running that should not be?
#  ------------------------------------------------------------------------------
#    # Every Pod, everywhere, with the security-relevant columns exposed:
#    kubectl get pods -A -o wide
#    kubectl get pods -A -o custom-columns=\
#'NS:.metadata.namespace,POD:.metadata.name,'\
#'PRIV:.spec.containers[*].securityContext.privileged,'\
#'HOSTPID:.spec.hostPID,HOSTNET:.spec.hostNetwork,SA:.spec.serviceAccountName'
#
#    -> 'dev/support-tools' stands out: privileged=true, hostPID=true,
#       hostNetwork=true. That is your beachhead (Execution + Escape-to-Host).
#
#    # Confirm the node-escape indicator (hostPath '/' mounted into the pod):
#    kubectl -n dev get pod support-tools -o yaml | grep -A4 -iE 'hostPath|volumeMounts|privileged'
#
#  ------------------------------------------------------------------------------
#  STEP 2 — Who is the bad actor's identity? (Privilege Escalation)
#  ------------------------------------------------------------------------------
#    # The pod runs as 'support-sa'. Find what that identity can do:
#    kubectl get clusterrolebindings -o custom-columns=\
#'NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name' \
#      | grep -Ei 'cluster-admin|support-sa'
#
#    # Or, list every subject bound to cluster-admin (find the odd one out):
#    kubectl get clusterrolebinding -o jsonpath=\
#'{range .items[?(@.roleRef.name=="cluster-admin")]}{.metadata.name}{"\t"}{.subjects[*].name}{"\n"}{end}'
#
#    # Prove it from the attacker's point of view:
#    kubectl auth can-i '*' '*' -A \
#      --as=system:serviceaccount:dev:support-sa   # -> yes  (full cluster control)
#
#    -> 'support-sa-cluster-admin' binds dev/support-sa to cluster-admin.
#       That is Privilege Escalation + a Persistence identity.
#
#  ------------------------------------------------------------------------------
#  STEP 3 — Credential Access: what did they collect?
#  ------------------------------------------------------------------------------
#    kubectl -n dev get secrets
#    kubectl -n dev get secret exfil-token -o jsonpath='{.data.stolen_sa_token}' | base64 -d; echo
#    -> a stashed/stolen token. Treat any real token found this way as burned:
#       rotate/revoke it after the lab.
#
#  ------------------------------------------------------------------------------
#  STEP 4 — Persistence #1: scheduled re-entry
#  ------------------------------------------------------------------------------
#    kubectl get cronjobs -A
#    kubectl -n kube-system get cronjob metrics-collector -o yaml | grep -iE 'privileged|hostPID|schedule'
#    -> 'kube-system/metrics-collector' relaunches a privileged pod every minute.
#       Named to blend in (Defense Evasion) — but no real platform ships it.
#
#  ------------------------------------------------------------------------------
#  STEP 5 — Persistence #2: node-level static Pod (the sneaky one)
#  ------------------------------------------------------------------------------
#    # A static Pod has NO controller/ownerReferences and its name ends in the
#    # node hostname. 'kubectl delete' on the mirror Pod is undone by kubelet.
#    kubectl -n kube-system get pods -o wide | grep kube-proxy-audit
#    kubectl -n kube-system get pod <kube-proxy-audit-...> -o jsonpath='{.metadata.ownerReferences}'; echo
#    # The source of truth is a FILE on the node:
#    sudo ls -l /etc/kubernetes/manifests/
#    sudo cat /etc/kubernetes/manifests/kube-proxy-audit.yaml
#
#  ------------------------------------------------------------------------------
#  STEP 6 — Corroborate with the audit trail / runtime sensor (the "investigate")
#  ------------------------------------------------------------------------------
#    # If API-server auditing is enabled, the RBAC change and pod creation are logged:
#    sudo grep -E 'clusterrolebindings|support-sa|support-tools' \
#         /var/log/kubernetes/audit/audit.log | jq -r '.verb+" "+.objectRef.resource+"/"+(.objectRef.name//"")'
#    # (Docs: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
#    # If Falco is running, its alerts pin the timeline (privileged pod, host mount,
#    # sensitive-mount, shell-in-container). https://falco.org/docs/
#    # On the node, inspect what the beachhead actually did:
#    sudo crictl ps | grep support-tools
#    kubectl -n dev logs support-tools
#    kubectl -n dev exec support-tools -- cat /tmp/.beacon.log
#
#  ------------------------------------------------------------------------------
#  STEP 7 — Map the kill chain (this IS the deliverable of topic 6.3)
#  ------------------------------------------------------------------------------
#    Initial Access / Persistence : ClusterRoleBinding support-sa-cluster-admin
#    Execution / Escape to Host   : Pod dev/support-tools (privileged,hostPID,hostPath /)
#    Credential Access            : Secret dev/exfil-token
#    Persistence (scheduled)      : CronJob kube-system/metrics-collector
#    Persistence (node)           : static Pod /etc/kubernetes/manifests/kube-proxy-audit.yaml
#    Defense Evasion              : ns 'dev' relabelled PodSecurity enforce=privileged;
#                                   malicious pod labelled app=payment-api to masquerade
#
#  ------------------------------------------------------------------------------
#  STEP 8 — Eradicate (surgically — keep 'payment-api')
#  ------------------------------------------------------------------------------
#    kubectl -n dev delete pod support-tools
#    kubectl delete clusterrolebinding support-sa-cluster-admin
#    kubectl -n dev delete sa support-sa
#    kubectl -n kube-system delete cronjob metrics-collector
#    kubectl -n dev delete secret exfil-token
#    # Node persistence — remove the FILE, kubelet then tears down the mirror Pod:
#    sudo rm -f /etc/kubernetes/manifests/kube-proxy-audit.yaml
#
#  ------------------------------------------------------------------------------
#  STEP 9 — Harden / undo the defense evasion
#  ------------------------------------------------------------------------------
#    kubectl label ns dev \
#      pod-security.kubernetes.io/enforce=baseline \
#      pod-security.kubernetes.io/warn=baseline \
#      pod-security.kubernetes.io/audit=baseline --overwrite
#    # (Prefer 'restricted' if the real workloads tolerate it.)
#
#  ------------------------------------------------------------------------------
#  STEP 10 — Verify closure
#  ------------------------------------------------------------------------------
#    ./break_fix.sh verify        # every check must PASS
#    kubectl auth can-i '*' '*' -A --as=system:serviceaccount:dev:support-sa   # -> no
#    kubectl get pods -A -o custom-columns=NS:.metadata.namespace,\
#POD:.metadata.name,PRIV:.spec.containers[*].securityContext.privileged | grep true
#      # -> only your legitimate/system components remain.
#
#  Post-incident: rotate any real credentials the attacker could have read via
#  cluster-admin, enable/keep API-server auditing and a runtime sensor (Falco),
#  and enforce Pod Security so the initial privileged-pod step is blocked at the
#  admission layer next time.
# ==============================================================================