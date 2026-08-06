#!/usr/bin/env bash
#
# =============================================================================
#  KCSA · Domain 1 · Topic 1.1 — The 4Cs of Cloud Native Security
#  BREAK & FIX LAB — "payments-api"
# =============================================================================
#
#  The 4Cs model (Cloud → Cluster → Container → Code) is a defence-in-depth
#  layering: each layer inherits the weaknesses of the layer that contains it,
#  so a hardened container running on an unhardened cluster is not hardened.
#  This lab plants ONE class of defect in EACH of the four layers of the same
#  application, then asks you to remediate all four WITHOUT taking the
#  application down. Fixing the workload while breaking availability is not a
#  fix — that is the trade-off the exam actually tests.
#
#  Reference: CNCF KCSA Curriculum
#    https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#  Upstream primary sources used to build this lab:
#    https://kubernetes.io/docs/concepts/security/overview/
#    https://kubernetes.io/docs/concepts/security/pod-security-standards/
#    https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#    https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
#    https://kubernetes.io/docs/concepts/services-networking/network-policies/
#
# -----------------------------------------------------------------------------
#  !! DISPOSABLE LAB VM ONLY !!
#  This script deliberately weakens host file permissions, the container
#  runtime socket, the kubelet authentication configuration and cluster RBAC.
#  Run it ONLY against a throwaway kind / k3s / minikube cluster on a VM you
#  can delete. It refuses to run against an unknown kubectl context unless you
#  export KCSA_LAB_I_UNDERSTAND=yes.
# -----------------------------------------------------------------------------
#
#  USAGE
#    ./4cs-break-and-fix.sh break     # plant the defects (default)
#    ./4cs-break-and-fix.sh verify    # score your remediation (exit 0 = solved)
#    ./4cs-break-and-fix.sh clean     # tear the lab down and restore the host
#
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------- 
# Lab constants
# -----------------------------------------------------------------------------
NS="kcsa-4c-lab"
DEPLOY="payments-api"
APP_LABEL="payments-api"
SA_NAME="payments-api"
SVC="payments-api"
CLIENT_OK="checkout"          # legitimate consumer, must keep working
CLIENT_BAD="intruder"         # must NOT be able to reach payments-api
SENTINEL="kcsa-lab-Pr0d-DB-P4ssw0rd-DO-NOT-REUSE"
CRB_ANON_ADMIN="kcsa-4c-lab-anonymous-cluster-admin"
CRB_ANON_KUBELET="kcsa-4c-lab-anonymous-kubelet-api"
CRB_SA_ADMIN="kcsa-4c-lab-sa-cluster-admin"
FW_TAG="kcsa-4c-lab"
STATE_DIR="/var/tmp/kcsa-4c-lab"
STATE_FILE="${STATE_DIR}/state.env"
STRAY_KUBECONFIG="/tmp/kubeconfig-lab-copy.yaml"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_CYA=$'\033[36m'; C_DIM=$'\033[2m'
else
  C_RST=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYA=""; C_DIM=""
fi

hr()    { printf '%s\n' "${C_DIM}$(printf '─%.0s' {1..78})${C_RST}"; }
title() { printf '\n%s\n' "${C_B}${C_BLU}▐ $*${C_RST}"; hr; }
info()  { printf '%s\n' "  $*"; }
ok()    { printf '%s\n' "  ${C_GRN}✔${C_RST} $*"; }
warn()  { printf '%s\n' "  ${C_YEL}▲${C_RST} $*"; }
bad()   { printf '%s\n' "  ${C_RED}✘${C_RST} $*"; }
die()   { printf '\n%s\n\n' "${C_RED}${C_B}FATAL:${C_RST} $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Privilege / environment discovery
# -----------------------------------------------------------------------------
SUDO=""
HOST_PRIV=0
detect_privileges() {
  if [[ "${EUID}" -eq 0 ]]; then
    HOST_PRIV=1
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"; HOST_PRIV=1
  fi
}

kubeconfig_path() {
  if [[ -n "${KUBECONFIG:-}" ]]; then
    printf '%s' "${KUBECONFIG%%:*}"
  else
    printf '%s' "${HOME}/.kube/config"
  fi
}

runtime_socket() {
  for s in /var/run/docker.sock /run/docker.sock /run/containerd/containerd.sock; do
    [[ -S "$s" ]] && { printf '%s' "$s"; return 0; }
  done
  return 1
}

node_internal_ip() {
  kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
}

kind_node_container() {
  local ctx cluster name
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$ctx" == kind-* ]] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  cluster="${ctx#kind-}"
  name="${cluster}-control-plane"
  docker inspect "$name" >/dev/null 2>&1 || return 1
  printf '%s' "$name"
}

# -----------------------------------------------------------------------------
# Safety guard: never touch a cluster that is not obviously disposable
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version -o yaml >/dev/null 2>&1 || die "kubectl cannot reach any cluster."

  local ctx safe=0
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  case "$ctx" in
    kind-*|k3d-*|minikube|k3s|k3s-*|default|docker-desktop) safe=1 ;;
  esac

  title "Preflight"
  info "kubectl context : ${C_B}${ctx}${C_RST}"
  info "server nodes    : $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  info "host privileges : $([[ $HOST_PRIV -eq 1 ]] && echo 'root/sudo (Cloud-layer breaks ENABLED)' || echo 'unprivileged (Cloud-layer breaks partially SKIPPED)')"

  if [[ $safe -eq 0 && "${KCSA_LAB_I_UNDERSTAND:-}" != "yes" ]]; then
    die "Context '${ctx}' does not look like a disposable lab cluster.
       If this really is a throwaway VM cluster, re-run with:
         KCSA_LAB_I_UNDERSTAND=yes $0 ${1:-break}"
  fi
}

confirm_break() {
  [[ "${KCSA_LAB_ASSUME_YES:-}" == "yes" ]] && return 0
  [[ -t 0 ]] || return 0
  local answer
  printf '\n%s' "  Type ${C_B}BREAK${C_RST} to deliberately weaken this cluster and host: "
  read -r answer
  [[ "$answer" == "BREAK" ]] || die "Aborted by user."
}

# =============================================================================
#  BREAK
# =============================================================================

break_cloud_layer() {
  title "C1 · CLOUD — weakening the infrastructure the cluster runs on"

  local kcfg sock nodec
  kcfg="$(kubeconfig_path)"

  # (a) Cluster admin credentials left world-readable, plus a stray copy in /tmp.
  #     This is the single most common real-world "cloud layer" finding: the
  #     control-plane is perfectly hardened and the credentials to it are 0644.
  if [[ -f "$kcfg" ]]; then
    echo "KCFG_ORIG_MODE=$(stat -c '%a' "$kcfg")" >>"$STATE_FILE"
    chmod 0644 "$kcfg"
    cp -f "$kcfg" "$STRAY_KUBECONFIG" 2>/dev/null || true
    chmod 0644 "$STRAY_KUBECONFIG" 2>/dev/null || true
    bad "admin kubeconfig is now mode 0644 and copied to ${STRAY_KUBECONFIG}"
  else
    warn "no kubeconfig file found at ${kcfg} — skipping credential exposure"
  fi

  # (b) Container runtime socket world-writable. Write access to this socket is
  #     unconditional root on the node: you can start a privileged container
  #     that mounts /.
  if sock="$(runtime_socket)"; then
    if [[ $HOST_PRIV -eq 1 ]]; then
      echo "SOCK_PATH=${sock}"            >>"$STATE_FILE"
      echo "SOCK_ORIG_MODE=$(stat -c '%a' "$sock")" >>"$STATE_FILE"
      $SUDO chmod 0666 "$sock"
      bad "container runtime socket ${sock} is now mode 0666 (root for everyone)"
    else
      warn "no root/sudo — skipping runtime socket exposure"
    fi
  fi

  # (c) Host firewall opened for the control-plane and kubelet ports from
  #     anywhere. In a managed cloud this is the security group / NSG rule.
  if [[ $HOST_PRIV -eq 1 ]] && command -v iptables >/dev/null 2>&1; then
    if $SUDO iptables -I INPUT -p tcp -m multiport --dports 6443,10250,10255 \
         -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; then
      echo "FW_BREAK=1" >>"$STATE_FILE"
      bad "iptables INPUT now ACCEPTs 0.0.0.0/0 → tcp/6443,10250,10255 (tag ${FW_TAG})"
    else
      warn "could not insert iptables rule — skipping firewall exposure"
    fi
  else
    warn "no root/sudo or no iptables — skipping firewall exposure"
  fi

  # (d) Kubelet anonymous authentication + read-only port. The kubelet is a
  #     second, fully independent API on every node; it is a Cloud/Node-layer
  #     control, not a Cluster-layer one.
  if nodec="$(kind_node_container)"; then
    docker exec "$nodec" cp -n /var/lib/kubelet/config.yaml \
      /var/lib/kubelet/config.yaml.kcsa-4c.bak 2>/dev/null || true
    docker exec "$nodec" sed -i '/^  anonymous:/{n;s/enabled: false/enabled: true/}' \
      /var/lib/kubelet/config.yaml
    docker exec "$nodec" sh -c \
      'grep -q "^readOnlyPort:" /var/lib/kubelet/config.yaml \
        && sed -i "s/^readOnlyPort:.*/readOnlyPort: 10255/" /var/lib/kubelet/config.yaml \
        || echo "readOnlyPort: 10255" >> /var/lib/kubelet/config.yaml'
    docker exec "$nodec" systemctl restart kubelet
    echo "NODE_CONTAINER=${nodec}" >>"$STATE_FILE"
    echo "KUBELET_BREAK=1"         >>"$STATE_FILE"
    bad "kubelet on ${nodec}: anonymous auth ENABLED, readOnlyPort 10255 OPEN"
    info "${C_DIM}waiting for the node to become Ready again...${C_RST}"
    kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1 || true
  else
    warn "not a kind cluster (or docker unavailable) — kubelet break SKIPPED"
  fi
}

break_cluster_layer() {
  title "C2 · CLUSTER — weakening authorisation, admission and network policy"

  # Namespace with Pod Security Admission pinned wide open. `privileged` is the
  # unrestricted PSS level: it permits hostPath, hostPID, privileged, root.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    kcsa.lab/topic: "4cs"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF
  bad "namespace ${NS} enforces Pod Security level 'privileged' (no admission control)"

  # Anonymous requests bound to cluster-admin. Every unauthenticated request to
  # the API server maps to the user system:anonymous / group system:unauthenticated.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB_ANON_ADMIN}
  labels: { kcsa.lab/topic: "4cs" }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects:
  - kind: User
    name: system:anonymous
    apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB_ANON_KUBELET}
  labels: { kcsa.lab/topic: "4cs" }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: system:kubelet-api-admin }
subjects:
  - kind: User
    name: system:anonymous
    apiGroup: rbac.authorization.k8s.io
EOF
  bad "system:anonymous is bound to cluster-admin AND system:kubelet-api-admin"

  # Workload identity with far more authority than the workload needs.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB_SA_ADMIN}
  labels: { kcsa.lab/topic: "4cs" }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${NS}
EOF
  bad "ServiceAccount ${NS}/${SA_NAME} is cluster-admin"

  # No NetworkPolicy at all: the namespace is flat, every pod in the cluster can
  # open a socket to payments-api:8080.
  kubectl -n "$NS" delete networkpolicy --all >/dev/null 2>&1 || true
  bad "no NetworkPolicy in ${NS} — East-West traffic is unrestricted (allow-all)"
}

break_code_and_container_layers() {
  title "C3 · CONTAINER + C4 · CODE — deploying the vulnerable workload"

  # CODE layer: credentials committed into configuration, injected as plain
  # environment variables. They are now visible to anyone with `get configmap`,
  # to `kubectl describe pod`, to the node's process table and to every crash
  # dump and log line the app ever writes.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-api-config
  namespace: ${NS}
data:
  APP_ENV: "production"
  APP_DB_HOST: "postgres.payments.svc.cluster.local"
  APP_DB_USER: "payments_rw"
  APP_DB_PASSWORD: "${SENTINEL}"
  APP_API_TOKEN: "tok_live_4c5a_kcsa_lab_do_not_reuse"
EOF

  # CONTAINER layer: privileged, root, host namespaces, host filesystem, mutable
  # root fs, floating tag, no resource limits, API token auto-mounted.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels: { app: ${APP_LABEL} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${APP_LABEL} }
  template:
    metadata:
      labels: { app: ${APP_LABEL} }
    spec:
      serviceAccountName: ${SA_NAME}
      automountServiceAccountToken: true
      hostPID: true
      hostIPC: true
      terminationGracePeriodSeconds: 2
      containers:
        - name: api
          image: busybox:latest
          imagePullPolicy: IfNotPresent
          command: ["sh","-c"]
          args:
            - 'echo "payments-api v1 (kcsa 4c lab)" > /tmp/index.html; exec httpd -f -p 8080 -h /tmp'
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef: { name: payments-api-config }
          env:
            - name: APP_SIGNING_SECRET
              value: "${SENTINEL}"
          securityContext:
            privileged: true
            runAsUser: 0
            allowPrivilegeEscalation: true
          volumeMounts:
            - name: hostroot
              mountPath: /host
              readOnly: true
      volumes:
        - name: hostroot
          hostPath: { path: /, type: Directory }
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
spec:
  selector: { app: ${APP_LABEL} }
  ports:
    - name: http
      port: 8080
      targetPort: 8080
EOF
  bad "Deployment ${NS}/${DEPLOY}: privileged, uid 0, hostPID/hostIPC, hostPath /, busybox:latest"
  bad "ConfigMap payments-api-config carries the production DB password in clear text"

  deploy_clients
  kubectl -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=180s >/dev/null 2>&1 \
    || warn "rollout did not converge in time — check 'kubectl -n ${NS} get pods'"
}

# Both client pods are already Pod-Security-'restricted' compliant on purpose:
# they must survive the namespace being tightened, because PSA is an ADMISSION
# control — it never evicts pods that are already running.
deploy_clients() {
  local p
  for p in "$CLIENT_OK" "$CLIENT_BAD"; do
    kubectl -n "$NS" get pod "$p" >/dev/null 2>&1 && continue
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${p}
  namespace: ${NS}
  labels: { app: ${p} }
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sh","-c","sleep 86400"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources:
        requests: { cpu: "10m", memory: "16Mi" }
        limits:   { cpu: "100m", memory: "64Mi" }
EOF
  done
  kubectl -n "$NS" wait --for=condition=Ready "pod/${CLIENT_OK}" --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "$NS" wait --for=condition=Ready "pod/${CLIENT_BAD}" --timeout=120s >/dev/null 2>&1 || true
}

prove_the_break() {
  title "PROOF — the symptoms you are expected to observe"
  local pod ip

  info "${C_CYA}\$ kubectl auth can-i '*' '*' --as=system:anonymous${C_RST}"
  info "  → $(kubectl auth can-i '*' '*' --as=system:anonymous 2>&1 || true)   ${C_RED}(unauthenticated = cluster-admin)${C_RST}"

  pod="$(kubectl -n "$NS" get pods -l "app=${APP_LABEL}" \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
  if [[ -n "$pod" ]]; then
    info ""
    info "${C_CYA}\$ kubectl -n ${NS} exec ${pod} -- head -2 /host/etc/shadow${C_RST}"
    kubectl -n "$NS" exec "$pod" -- head -2 /host/etc/shadow 2>/dev/null | sed 's/^/    /' || true
    info ""
    info "${C_CYA}\$ kubectl -n ${NS} exec ${pod} -- sh -c 'ps -o pid,args | head -4'${C_RST}"
    kubectl -n "$NS" exec "$pod" -- sh -c 'ps -o pid,args 2>/dev/null | head -4' 2>/dev/null | sed 's/^/    /' || true
    info "    ${C_RED}↑ those are the NODE's processes: hostPID punches through the container${C_RST}"
    info ""
    info "${C_CYA}\$ kubectl -n ${NS} exec ${pod} -- env | grep -E 'PASSWORD|TOKEN|SECRET'${C_RST}"
    kubectl -n "$NS" exec "$pod" -- sh -c 'env | grep -E "PASSWORD|TOKEN|SECRET"' 2>/dev/null | sed 's/^/    /' || true
  fi

  ip="$(node_internal_ip)"
  if [[ -n "$ip" ]] && command -v curl >/dev/null 2>&1; then
    info ""
    info "${C_CYA}\$ curl -sk https://${ip}:10250/pods | head -c 90${C_RST}"
    info "    $(curl -sk -m 5 "https://${ip}:10250/pods" 2>/dev/null | head -c 90 || echo '<no answer>')"
    info "${C_CYA}\$ curl -s http://${ip}:10255/pods | head -c 90${C_RST}"
    info "    $(curl -s -m 5 "http://${ip}:10255/pods" 2>/dev/null | head -c 90 || echo '<no answer>')"
    info "    ${C_RED}↑ the kubelet API answers WITHOUT credentials${C_RST}"
  fi
}

print_mission() {
  cat <<BRIEF

$(hr)
${C_B}  MISSION — restore the 4Cs without an outage${C_RST}
$(hr)

  ${C_B}Symptoms you will see now${C_RST}

    • ${C_YEL}kubectl auth can-i '*' '*' --as=system:anonymous${C_RST} answers ${C_RED}yes${C_RST}: anyone
      who can reach tcp/6443 owns the cluster, with no credential at all.
    • ${C_YEL}kubectl -n ${NS} exec deploy/${DEPLOY} -- cat /host/etc/shadow${C_RST} works.
      The container is a shell on the node, not a sandbox.
    • ${C_YEL}curl -sk https://<node-ip>:10250/pods${C_RST} and ${C_YEL}http://<node-ip>:10255/pods${C_RST}
      return the node's pod inventory to an anonymous caller.
    • ${C_YEL}kubectl -n ${NS} get cm payments-api-config -o yaml${C_RST} prints the production
      database password; so does ${C_YEL}describe pod${C_RST} and any log scraper.
    • The pod carries a cluster-admin ServiceAccount token at
      /var/run/secrets/kubernetes.io/serviceaccount/token — one RCE in the app
      and the Code layer becomes a Cluster compromise.
    • Every pod in the cluster can open ${C_YEL}payments-api:8080${C_RST}. Nothing stops
      lateral movement.

  ${C_B}What you must achieve${C_RST} — 14 graded checks, run ${C_CYA}$0 verify${C_RST}

   ${C_B}CLOUD${C_RST}
    1. The admin kubeconfig is 0600/0400 and the stray copy in /tmp is gone.
    2. The container runtime socket is not world-accessible.
    3. The kubelet rejects anonymous requests (401) and the read-only port
       10255 is closed.
    4. The blanket iptables ACCEPT rule tagged '${FW_TAG}' is removed.

   ${C_B}CLUSTER${C_RST}
    5. system:anonymous holds no privilege: cluster-admin, kubelet-api-admin
       and secret access are all revoked.
    6. The workload ServiceAccount cannot list secrets cluster-wide and is not
       cluster-admin.
    7. Namespace ${NS} enforces Pod Security Standard 'restricted'.
    8. A default-deny ingress NetworkPolicy exists AND an explicit policy
       allows ONLY app=${CLIENT_OK} to reach app=${APP_LABEL} on 8080.

   ${C_B}CONTAINER${C_RST}
    9. No privileged, no hostPID/hostIPC/hostNetwork, no hostPath volume.
   10. runAsNonRoot, allowPrivilegeEscalation=false, capabilities drop ALL,
       readOnlyRootFilesystem, seccompProfile RuntimeDefault.
   11. Image pinned to an immutable tag/digest (never :latest), CPU+memory
       requests and limits set, ServiceAccount token NOT auto-mounted.

   ${C_B}CODE${C_RST}
   12. No credential in any ConfigMap and no secret value inline in the pod
       spec; the app receives them from a Secret reference.

   ${C_B}AVAILABILITY (non-negotiable)${C_RST}
   13. Deployment ${DEPLOY} is Available with >=1 ready replica.
   14. Pod ${CLIENT_OK} can still fetch http://${SVC}:8080/ .

  ${C_DIM}Keep the label app=${APP_LABEL} — the Service and the NetworkPolicy select on it.
  Hint: readOnlyRootFilesystem breaks the app until you give it a writable /tmp.
  Hint: PSA is admission-time only; tightening the namespace does not evict the
  running privileged pod, you must roll the Deployment.${C_RST}

$(hr)

BRIEF
}

do_break() {
  preflight break
  confirm_break
  mkdir -p "$STATE_DIR"
  : >"$STATE_FILE"
  echo "KCFG_PATH=$(kubeconfig_path)" >>"$STATE_FILE"
  echo "NODE_IP=$(node_internal_ip)"  >>"$STATE_FILE"
  break_cloud_layer
  break_cluster_layer
  break_code_and_container_layers
  prove_the_break
  print_mission
}

# =============================================================================
#  VERIFY
# =============================================================================

PASS_N=0; FAIL_N=0; SKIP_N=0
DETAIL=""
POD=""

load_state() { [[ -f "$STATE_FILE" ]] && . "$STATE_FILE" || true; }

running_pod() {
  kubectl -n "$NS" get pods -l "app=${APP_LABEL}" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | head -1 || true
}

jp() { kubectl -n "$NS" get "$1" "$2" -o jsonpath="$3" 2>/dev/null || true; }

run_check() {
  local id="$1" text="$2" fn="$3" hint="${4:-}" rc=0
  DETAIL=""
  if "$fn"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) PASS_N=$((PASS_N+1)); printf '  %s[PASS]%s %-4s %s\n' "$C_GRN" "$C_RST" "$id" "$text" ;;
    2) SKIP_N=$((SKIP_N+1)); printf '  %s[SKIP]%s %-4s %s %s\n' "$C_YEL" "$C_RST" "$id" "$text" "${C_DIM}(${DETAIL})${C_RST}" ;;
    *) FAIL_N=$((FAIL_N+1)); printf '  %s[FAIL]%s %-4s %s\n' "$C_RED" "$C_RST" "$id" "$text"
       [[ -n "$DETAIL" ]] && printf '         %s↳ %s%s\n' "$C_DIM" "$DETAIL" "$C_RST"
       [[ -n "$hint"   ]] && printf '         %s↳ hint: %s%s\n' "$C_DIM" "$hint" "$C_RST" ;;
  esac
}

# --- CLOUD -------------------------------------------------------------------
chk_kubeconfig_perms() {
  local kcfg mode; kcfg="${KCFG_PATH:-$(kubeconfig_path)}"
  [[ -f "$kcfg" ]] || { DETAIL="no kubeconfig file on this host"; return 2; }
  mode="$(stat -c '%a' "$kcfg")"
  if [[ -e "$STRAY_KUBECONFIG" ]]; then
    DETAIL="stray credential copy still present at ${STRAY_KUBECONFIG}"; return 1
  fi
  case "$mode" in 600|400) return 0 ;; esac
  DETAIL="${kcfg} is mode ${mode}, expected 600 or 400"; return 1
}

chk_socket_perms() {
  local sock mode; sock="${SOCK_PATH:-}"
  [[ -n "$sock" ]] || sock="$(runtime_socket || true)"
  [[ -n "$sock" && -S "$sock" ]] || { DETAIL="no container runtime socket on this host"; return 2; }
  mode="$(stat -c '%a' "$sock")"
  [[ "${mode: -1}" == "0" ]] && return 0
  DETAIL="${sock} is mode ${mode}; the 'other' bits must be 0"; return 1
}

chk_kubelet_authn() {
  [[ "${KUBELET_BREAK:-0}" == "1" ]] || { DETAIL="kubelet was never modified by this lab"; return 2; }
  command -v curl >/dev/null 2>&1 || { DETAIL="curl not installed"; return 2; }
  local ip code; ip="${NODE_IP:-$(node_internal_ip)}"
  [[ -n "$ip" ]] || { DETAIL="cannot resolve node InternalIP"; return 2; }
  code="$(curl -sk -m 6 -o /dev/null -w '%{http_code}' "https://${ip}:10250/pods" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    DETAIL="kubelet https://${ip}:10250/pods still answers 200 to an anonymous caller"; return 1
  fi
  if curl -s -m 5 -o /dev/null "http://${ip}:10255/pods" 2>/dev/null; then
    DETAIL="kubelet read-only port ${ip}:10255 is still open"; return 1
  fi
  return 0
}

chk_firewall() {
  [[ "${FW_BREAK:-0}" == "1" ]] || { DETAIL="no lab firewall rule was installed"; return 2; }
  [[ $HOST_PRIV -eq 1 ]] || { DETAIL="need root/sudo to read iptables"; return 2; }
  if $SUDO iptables -S INPUT 2>/dev/null | grep -q -- "$FW_TAG"; then
    DETAIL="iptables INPUT still contains the permissive rule tagged ${FW_TAG}"; return 1
  fi
  return 0
}

# --- CLUSTER -----------------------------------------------------------------
chk_anonymous_rbac() {
  local a b c
  a="$(kubectl auth can-i '*' '*' --as=system:anonymous 2>/dev/null || true)"
  b="$(kubectl auth can-i get nodes/proxy --as=system:anonymous 2>/dev/null || true)"
  c="$(kubectl auth can-i list secrets -A --as=system:unauthenticated 2>/dev/null || true)"
  if [[ "$a" == "yes" || "$b" == "yes" || "$c" == "yes" ]]; then
    DETAIL="anonymous can-i: '*/*'=${a:-?} nodes/proxy=${b:-?} secrets(unauth)=${c:-?}"; return 1
  fi
  return 0
}

chk_sa_rbac() {
  local sa a b
  sa="$(jp deploy "$DEPLOY" '{.spec.template.spec.serviceAccountName}')"
  [[ -n "$sa" ]] || sa="default"
  a="$(kubectl auth can-i '*' '*' --as="system:serviceaccount:${NS}:${sa}" 2>/dev/null || true)"
  b="$(kubectl auth can-i list secrets -A --as="system:serviceaccount:${NS}:${sa}" 2>/dev/null || true)"
  if [[ "$a" == "yes" || "$b" == "yes" ]]; then
    DETAIL="SA ${sa}: '*/*'=${a} list-secrets-cluster-wide=${b}"; return 1
  fi
  return 0
}

chk_psa() {
  local enf ver
  enf="$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
  ver="$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce-version}' 2>/dev/null || true)"
  if [[ "$enf" != "restricted" ]]; then
    DETAIL="namespace enforce level is '${enf:-<unset>}', expected 'restricted'"; return 1
  fi
  DETAIL="enforce-version=${ver:-latest}"
  return 0
}

chk_netpol() {
  local n sel types rules app deny=0 allow=0
  for n in $(kubectl -n "$NS" get networkpolicy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    sel="$(jp networkpolicy "$n" '{.spec.podSelector.matchLabels}{.spec.podSelector.matchExpressions}')"
    types="$(jp networkpolicy "$n" '{.spec.policyTypes[*]}')"
    rules="$(jp networkpolicy "$n" '{range .spec.ingress[*]}R{end}')"
    app="$(jp networkpolicy "$n" '{.spec.podSelector.matchLabels.app}')"
    [[ -z "$sel" && "$types" == *Ingress* && -z "$rules" ]] && deny=1
    [[ "$app" == "$APP_LABEL" && -n "$rules" ]] && allow=1
  done
  if [[ $deny -eq 1 && $allow -eq 1 ]]; then return 0; fi
  DETAIL="default-deny-ingress=$([[ $deny -eq 1 ]] && echo yes || echo NO), explicit-allow-for-${APP_LABEL}=$([[ $allow -eq 1 ]] && echo yes || echo NO)"
  return 1
}

# --- CONTAINER ---------------------------------------------------------------
chk_host_escapes() {
  [[ -n "$POD" ]] || { DETAIL="no Running pod for app=${APP_LABEL}"; return 1; }
  local priv hpid hipc hnet hpath problems=""
  priv="$(jp pod "$POD" '{.spec.containers[*].securityContext.privileged}')"
  hpid="$(jp pod "$POD" '{.spec.hostPID}')"
  hipc="$(jp pod "$POD" '{.spec.hostIPC}')"
  hnet="$(jp pod "$POD" '{.spec.hostNetwork}')"
  hpath="$(jp pod "$POD" '{.spec.volumes[*].hostPath.path}')"
  [[ "$priv" == *true*  ]] && problems+="privileged "
  [[ "$hpid" == "true"  ]] && problems+="hostPID "
  [[ "$hipc" == "true"  ]] && problems+="hostIPC "
  [[ "$hnet" == "true"  ]] && problems+="hostNetwork "
  [[ -n "$hpath"        ]] && problems+="hostPath(${hpath}) "
  [[ -z "$problems" ]] && return 0
  DETAIL="still present: ${problems}"; return 1
}

chk_security_context() {
  [[ -n "$POD" ]] || { DETAIL="no Running pod for app=${APP_LABEL}"; return 1; }
  local nonroot ape rofs caps sec problems=""
  nonroot="$(jp pod "$POD" '{.spec.securityContext.runAsNonRoot}{.spec.containers[0].securityContext.runAsNonRoot}')"
  ape="$(jp pod "$POD" '{.spec.containers[0].securityContext.allowPrivilegeEscalation}')"
  rofs="$(jp pod "$POD" '{.spec.containers[0].securityContext.readOnlyRootFilesystem}')"
  caps="$(jp pod "$POD" '{.spec.containers[0].securityContext.capabilities.drop[*]}')"
  sec="$(jp pod "$POD" '{.spec.securityContext.seccompProfile.type}{.spec.containers[0].securityContext.seccompProfile.type}')"
  [[ "$nonroot" == *true* ]]           || problems+="runAsNonRoot!=true "
  [[ "$ape" == "false" ]]              || problems+="allowPrivilegeEscalation!=false "
  [[ "$rofs" == "true" ]]              || problems+="readOnlyRootFilesystem!=true "
  grep -qw "ALL" <<<"$caps"            || problems+="capabilities.drop!=[ALL] "
  [[ "$sec" == *RuntimeDefault* || "$sec" == *Localhost* ]] || problems+="seccompProfile unset "
  [[ -z "$problems" ]] && return 0
  DETAIL="${problems}"; return 1
}

chk_supply_chain() {
  [[ -n "$POD" ]] || { DETAIL="no Running pod for app=${APP_LABEL}"; return 1; }
  local img lim req vols problems=""
  img="$(jp pod "$POD" '{.spec.containers[0].image}')"
  lim="$(jp pod "$POD" '{.spec.containers[0].resources.limits.memory}')"
  req="$(jp pod "$POD" '{.spec.containers[0].resources.requests.cpu}')"
  vols="$(jp pod "$POD" '{.spec.volumes[*].name}')"
  [[ "$img" == *:latest || "$img" != *[:@]* ]] && problems+="unpinned image (${img}) "
  [[ -n "$lim" ]] || problems+="no memory limit "
  [[ -n "$req" ]] || problems+="no cpu request "
  grep -q "kube-api-access" <<<"$vols" && problems+="ServiceAccount token auto-mounted "
  [[ -z "$problems" ]] && return 0
  DETAIL="${problems}"; return 1
}

# --- CODE --------------------------------------------------------------------
chk_secret_handling() {
  [[ -n "$POD" ]] || { DETAIL="no Running pod for app=${APP_LABEL}"; return 1; }
  local cms envs refs problems=""
  cms="$(kubectl -n "$NS" get configmap -o yaml 2>/dev/null || true)"
  grep -qF "$SENTINEL" <<<"$cms" && problems+="credential still stored in a ConfigMap "
  envs="$(jp pod "$POD" '{range .spec.containers[*].env[*]}{.name}={.value}{"\n"}{end}')"
  grep -qiE '^[A-Z0-9_]*(PASSWORD|TOKEN|SECRET|API_?KEY)[A-Z0-9_]*=.+' <<<"$envs" \
    && problems+="secret value inlined in the pod spec "
  refs="$(jp pod "$POD" '{.spec.containers[*].envFrom[*].secretRef.name}')$(jp pod "$POD" '{.spec.containers[*].env[*].valueFrom.secretKeyRef.name}')"
  [[ -n "$refs" ]] || problems+="no Secret reference (the app lost its credentials) "
  [[ -z "$problems" ]] && return 0
  DETAIL="${problems}"; return 1
}

# --- AVAILABILITY ------------------------------------------------------------
chk_available() {
  local ready
  ready="$(jp deploy "$DEPLOY" '{.status.readyReplicas}')"
  [[ "${ready:-0}" -ge 1 ]] && return 0
  DETAIL="readyReplicas=${ready:-0}; $(kubectl -n "$NS" get pods -l app=${APP_LABEL} --no-headers 2>/dev/null | head -3 | tr '\n' ';')"
  return 1
}

chk_reachable() {
  deploy_clients >/dev/null 2>&1 || true
  local out
  if out="$(kubectl -n "$NS" exec "$CLIENT_OK" -- \
        wget -q -T 6 -O- "http://${SVC}:8080/" 2>&1)"; then
    grep -q "payments-api" <<<"$out" && return 0
  fi
  DETAIL="pod/${CLIENT_OK} cannot fetch http://${SVC}:8080/ — you denied the legitimate path"
  return 1
}

# --- informational: is the NetworkPolicy actually enforced? -------------------
netpol_enforcement_note() {
  local out
  if out="$(kubectl -n "$NS" exec "$CLIENT_BAD" -- \
        wget -q -T 5 -O- "http://${SVC}:8080/" 2>&1)"; then
    if grep -q "payments-api" <<<"$out"; then
      warn "INFO: pod/${CLIENT_BAD} still reaches ${SVC}:8080 despite the policy."
      info "      ${C_DIM}Your CNI is not a NetworkPolicy provider (kind's default kindnetd and"
      info "      minikube's default bridge are not). The API object is accepted and stored,"
      info "      and enforces nothing. This is a Cluster-layer lesson worth more than the"
      info "      check itself: a NetworkPolicy without an enforcing CNI is a comment.${C_RST}"
      return 0
    fi
  fi
  ok "INFO: pod/${CLIENT_BAD} is blocked — your CNI enforces NetworkPolicy."
}

do_verify() {
  preflight verify
  load_state
  kubectl get ns "$NS" >/dev/null 2>&1 || die "namespace ${NS} not found — run '$0 break' first."
  POD="$(running_pod)"

  title "SCORECARD — 4Cs of Cloud Native Security"

  printf '\n  %sCLOUD%s\n' "$C_B" "$C_RST"
  run_check "1"  "admin kubeconfig is not world-readable and no stray copy exists" chk_kubeconfig_perms \
            "chmod 600 \$(kubeconfig); rm -f ${STRAY_KUBECONFIG}"
  run_check "2"  "container runtime socket is not world-accessible"                chk_socket_perms \
            "chmod 660 /var/run/docker.sock"
  run_check "3"  "kubelet rejects anonymous auth and read-only port is closed"     chk_kubelet_authn \
            "authentication.anonymous.enabled=false and readOnlyPort=0 in /var/lib/kubelet/config.yaml, then restart kubelet"
  run_check "4"  "no blanket firewall ACCEPT for 6443/10250/10255"                 chk_firewall \
            "iptables -D INPUT ... (the rule tagged ${FW_TAG})"

  printf '\n  %sCLUSTER%s\n' "$C_B" "$C_RST"
  run_check "5"  "system:anonymous holds no privileges"                            chk_anonymous_rbac \
            "kubectl delete clusterrolebinding ${CRB_ANON_ADMIN} ${CRB_ANON_KUBELET}"
  run_check "6"  "workload ServiceAccount is least-privilege"                      chk_sa_rbac \
            "kubectl delete clusterrolebinding ${CRB_SA_ADMIN}"
  run_check "7"  "namespace enforces Pod Security Standard 'restricted'"           chk_psa \
            "kubectl label ns ${NS} pod-security.kubernetes.io/enforce=restricted --overwrite"
  run_check "8"  "default-deny ingress + an explicit allow for the real consumer"  chk_netpol \
            "one NetworkPolicy with podSelector {} and no ingress rules, plus one selecting app=${APP_LABEL}"

  printf '\n  %sCONTAINER%s\n' "$C_B" "$C_RST"
  run_check "9"  "no privileged, host namespaces or hostPath volumes"              chk_host_escapes \
            "remove privileged/hostPID/hostIPC/hostPath from the pod template"
  run_check "10" "hardened securityContext (restricted profile)"                   chk_security_context \
            "runAsNonRoot, allowPrivilegeEscalation=false, drop ALL caps, readOnlyRootFilesystem, seccompProfile RuntimeDefault"
  run_check "11" "pinned image, resource limits, no auto-mounted SA token"         chk_supply_chain \
            "busybox:1.36 (or a digest), requests+limits, automountServiceAccountToken: false"

  printf '\n  %sCODE%s\n' "$C_B" "$C_RST"
  run_check "12" "credentials come from a Secret, never a ConfigMap or inline env" chk_secret_handling \
            "kubectl create secret generic payments-api-credentials --from-literal=... and use envFrom.secretRef"

  printf '\n  %sAVAILABILITY%s\n' "$C_B" "$C_RST"
  run_check "13" "deployment ${DEPLOY} has at least one ready replica"             chk_available \
            "kubectl -n ${NS} describe pod -l app=${APP_LABEL} — read the admission/CrashLoop reason"
  run_check "14" "pod/${CLIENT_OK} can still consume http://${SVC}:8080/"          chk_reachable \
            "your allow-policy must match app=${CLIENT_OK} as ingress source on port 8080"

  hr
  printf '  %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
    "$C_GRN" "$PASS_N" "$C_RST" "$C_RED" "$FAIL_N" "$C_RST" "$C_YEL" "$SKIP_N" "$C_RST"
  hr
  netpol_enforcement_note || true

  if [[ $FAIL_N -eq 0 ]]; then
    printf '\n  %s%s4Cs RESTORED — the workload is hardened AND still serving.%s\n\n' "$C_B" "$C_GRN" "$C_RST"
    return 0
  fi
  printf '\n  %sStill broken. Fix the FAIL lines above and run "%s verify" again.%s\n\n' "$C_YEL" "$0" "$C_RST"
  return 1
}

# =============================================================================
#  CLEAN
# =============================================================================
do_clean() {
  detect_privileges
  load_state
  title "Tearing the lab down and restoring the host"

  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true
  kubectl delete clusterrolebinding "$CRB_ANON_ADMIN" "$CRB_ANON_KUBELET" "$CRB_SA_ADMIN" \
    --ignore-not-found >/dev/null 2>&1 || true
  ok "cluster objects removed"

  local kcfg="${KCFG_PATH:-$(kubeconfig_path)}"
  [[ -f "$kcfg" ]] && chmod "${KCFG_ORIG_MODE:-600}" "$kcfg" && ok "kubeconfig restored to ${KCFG_ORIG_MODE:-600}"
  rm -f "$STRAY_KUBECONFIG" 2>/dev/null || true

  if [[ -n "${SOCK_PATH:-}" && $HOST_PRIV -eq 1 ]]; then
    $SUDO chmod "${SOCK_ORIG_MODE:-660}" "$SOCK_PATH" && ok "runtime socket restored to ${SOCK_ORIG_MODE:-660}"
  fi

  if [[ "${FW_BREAK:-0}" == "1" && $HOST_PRIV -eq 1 ]]; then
    while $SUDO iptables -S INPUT 2>/dev/null | grep -q -- "$FW_TAG"; do
      $SUDO iptables -D INPUT -p tcp -m multiport --dports 6443,10250,10255 \
        -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null || break
    done
    ok "firewall rule removed"
  fi

  if [[ "${KUBELET_BREAK:-0}" == "1" && -n "${NODE_CONTAINER:-}" ]]; then
    docker exec "$NODE_CONTAINER" sh -c \
      'test -f /var/lib/kubelet/config.yaml.kcsa-4c.bak && cp -f /var/lib/kubelet/config.yaml.kcsa-4c.bak /var/lib/kubelet/config.yaml' 2>/dev/null || true
    docker exec "$NODE_CONTAINER" systemctl restart kubelet 2>/dev/null || true
    ok "kubelet configuration restored on ${NODE_CONTAINER}"
  fi

  rm -rf "$STATE_DIR"
  ok "lab state cleared"
}

usage() {
  cat <<USAGE
KCSA 1.1 — The 4Cs of Cloud Native Security · break & fix lab

  $0 break    plant one defect in each of the 4 layers (default)
  $0 verify   score your remediation; exit 0 only when all checks pass
  $0 clean    delete the lab and restore every host change

Environment:
  KCSA_LAB_I_UNDERSTAND=yes   allow a non kind/k3s/minikube context
  KCSA_LAB_ASSUME_YES=yes     skip the interactive confirmation
USAGE
}

main() {
  detect_privileges
  case "${1:-break}" in
    break)          do_break ;;
    verify|check)   do_verify ;;
    clean|cleanup)  do_clean ;;
    -h|--help|help) usage ;;
    *)              usage; exit 2 ;;
  esac
}

main "$@"

# =============================================================================
#  ██  SOLUTION — do not read until you have tried  ██
# =============================================================================
#
#  The order matters. Fix the Cloud layer first: a hardened pod on a node whose
#  kubelet answers anonymously is decoration. Then Cluster, then Container, then
#  Code — outside-in, exactly the way the 4Cs model is drawn.
#
# -----------------------------------------------------------------------------
#  STEP 1 — CLOUD: node and credential hygiene
# -----------------------------------------------------------------------------
#
#  1.1 Credentials
#      chmod 600 ~/.kube/config
#      rm -f /tmp/kubeconfig-lab-copy.yaml
#      # Rationale: kubeconfig for cluster-admin is a bearer credential. Anyone
#      # who can read the file is cluster-admin; file mode IS the access control.
#
#  1.2 Container runtime socket
#      sudo chmod 660 /var/run/docker.sock
#      # Write access to the runtime socket == root on the node, because you can
#      # ask the daemon to start a privileged container that bind-mounts /.
#
#  1.3 Host firewall
#      sudo iptables -S INPUT | grep kcsa-4c-lab
#      sudo iptables -D INPUT -p tcp -m multiport --dports 6443,10250,10255 \
#           -m comment --comment kcsa-4c-lab -j ACCEPT
#      # In a managed cloud this is the security group / NSG: the control-plane
#      # and kubelet ports must never be reachable from 0.0.0.0/0.
#
#  1.4 Kubelet authentication (run on the node; on kind, inside the container)
#      NODE=$(kubectl config current-context); NODE=${NODE#kind-}-control-plane
#      docker exec -it "$NODE" bash
#        vi /var/lib/kubelet/config.yaml
#        # authentication:
#        #   anonymous:
#        #     enabled: false        <-- was true
#        #   webhook:
#        #     enabled: true
#        # authorization:
#        #   mode: Webhook           <-- never AlwaysAllow
#        # readOnlyPort: 0           <-- was 10255
#        systemctl restart kubelet
#        exit
#      kubectl wait --for=condition=Ready node --all --timeout=120s
#      # Verify from the host:
#      #   curl -sk -o /dev/null -w '%{http_code}\n' https://<node-ip>:10250/pods  -> 401
#      #   curl -s  -m 5 http://<node-ip>:10255/pods                               -> refused
#      # The kubelet is a second API server on every node. anonymous+AlwaysAllow
#      # there gives /exec on every pod, which is cluster-admin by another route.
#      # https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
#
# -----------------------------------------------------------------------------
#  STEP 2 — CLUSTER: RBAC, admission, network segmentation
# -----------------------------------------------------------------------------
#
#  2.1 Revoke anonymous authority
#      kubectl auth can-i '*' '*' --as=system:anonymous            # -> yes (bad)
#      kubectl get clusterrolebinding -o json | \
#        jq -r '.items[] | select(.subjects[]?.name |
#               test("system:anonymous|system:unauthenticated")) | .metadata.name'
#      kubectl delete clusterrolebinding kcsa-4c-lab-anonymous-cluster-admin \
#                                        kcsa-4c-lab-anonymous-kubelet-api
#      kubectl auth can-i '*' '*' --as=system:anonymous            # -> no
#      # Keep system:public-info-viewer — that default binding only exposes
#      # /version and /healthz to system:unauthenticated.
#
#  2.2 Least privilege for the workload identity
#      kubectl delete clusterrolebinding kcsa-4c-lab-sa-cluster-admin
#      kubectl auth can-i list secrets -A \
#        --as=system:serviceaccount:kcsa-4c-lab:payments-api        # -> no
#      # payments-api serves HTTP; it needs ZERO Kubernetes API permissions.
#      # If a workload needs none, do not give it a token at all (step 3.3).
#
#  2.3 Pod Security Admission at the 'restricted' level, version-pinned
#      kubectl label ns kcsa-4c-lab \
#        pod-security.kubernetes.io/enforce=restricted \
#        pod-security.kubernetes.io/enforce-version=v1.31 \
#        pod-security.kubernetes.io/audit=restricted \
#        pod-security.kubernetes.io/warn=restricted --overwrite
#      # PSA is ADMISSION-time only: the already-running privileged pod keeps
#      # running. That is why step 3 must roll the Deployment, and why 'label the
#      # namespace' is never by itself a remediation.
#      # https://kubernetes.io/docs/concepts/security/pod-security-standards/
#
#  2.4 Default-deny plus one explicit allow
#      cat <<'YAML' | kubectl apply -f -
#      apiVersion: networking.k8s.io/v1
#      kind: NetworkPolicy
#      metadata:
#        name: default-deny-ingress
#        namespace: kcsa-4c-lab
#      spec:
#        podSelector: {}
#        policyTypes: ["Ingress"]
#      ---
#      apiVersion: networking.k8s.io/v1
#      kind: NetworkPolicy
#      metadata:
#        name: allow-checkout-to-payments-api
#        namespace: kcsa-4c-lab
#      spec:
#        podSelector:
#          matchLabels: { app: payments-api }
#        policyTypes: ["Ingress"]
#        ingress:
#          - from:
#              - podSelector:
#                  matchLabels: { app: checkout }
#            ports:
#              - protocol: TCP
#                port: 8080
#      YAML
#      # NetworkPolicies are additive and there is no 'deny' rule: you deny by
#      # selecting pods with no matching allow. Two caveats the exam likes:
#      #   * the policy is enforced by the CNI — kindnetd and the minikube bridge
#      #     accept the object and enforce nothing (Calico/Cilium/k3s do enforce);
#      #   * NetworkPolicy does not apply to hostNetwork pods, which is one more
#      #     reason step 3 removes host namespaces.
#      # https://kubernetes.io/docs/concepts/services-networking/network-policies/
#
# -----------------------------------------------------------------------------
#  STEP 3 — CODE first, then CONTAINER (the Secret must exist before the roll)
# -----------------------------------------------------------------------------
#
#  3.1 Move the credentials out of configuration
#      kubectl -n kcsa-4c-lab create secret generic payments-api-credentials \
#        --from-literal=APP_DB_PASSWORD='kcsa-lab-Pr0d-DB-P4ssw0rd-DO-NOT-REUSE' \
#        --from-literal=APP_API_TOKEN='tok_live_4c5a_kcsa_lab_do_not_reuse' \
#        --from-literal=APP_SIGNING_SECRET='kcsa-lab-Pr0d-DB-P4ssw0rd-DO-NOT-REUSE'
#      kubectl -n kcsa-4c-lab create configmap payments-api-config \
#        --from-literal=APP_ENV=production \
#        --from-literal=APP_DB_HOST=postgres.payments.svc.cluster.local \
#        --from-literal=APP_DB_USER=payments_rw \
#        --dry-run=client -o yaml | kubectl apply -f -
#      # A Secret is base64, NOT encryption. Two follow-ups that belong to the
#      # Cluster and Cloud layers respectively, and that the exam expects you to
#      # name: EncryptionConfiguration for secrets at rest in etcd, and RBAC that
#      # keeps 'get secrets' off ordinary roles. Better still, an external store
#      # (Vault / cloud KMS) via the Secrets Store CSI driver, so the value never
#      # lands in etcd at all. In the real world you would also ROTATE this
#      # credential — it was in a ConfigMap, therefore it is burned.
#      # https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
#
#  3.2 Rewrite the workload to the 'restricted' profile
#      cat <<'YAML' | kubectl apply -f -
#      apiVersion: apps/v1
#      kind: Deployment
#      metadata:
#        name: payments-api
#        namespace: kcsa-4c-lab
#        labels: { app: payments-api }
#      spec:
#        replicas: 1
#        selector:
#          matchLabels: { app: payments-api }
#        template:
#          metadata:
#            labels: { app: payments-api }
#          spec:
#            serviceAccountName: payments-api
#            automountServiceAccountToken: false     # the app never calls the API
#            terminationGracePeriodSeconds: 2
#            securityContext:
#              runAsNonRoot: true
#              runAsUser: 10001
#              runAsGroup: 10001
#              fsGroup: 10001
#              seccompProfile: { type: RuntimeDefault }
#            containers:
#              - name: api
#                image: busybox:1.36                 # pinned; prefer a digest
#                imagePullPolicy: IfNotPresent
#                command: ["sh","-c"]
#                args:
#                  - 'echo "payments-api v1 (kcsa 4c lab)" > /tmp/index.html; exec httpd -f -p 8080 -h /tmp'
#                ports:
#                  - containerPort: 8080
#                envFrom:
#                  - configMapRef: { name: payments-api-config }
#                  - secretRef:    { name: payments-api-credentials }
#                securityContext:
#                  allowPrivilegeEscalation: false
#                  readOnlyRootFilesystem: true
#                  capabilities: { drop: ["ALL"] }
#                resources:
#                  requests: { cpu: "50m",  memory: "32Mi" }
#                  limits:   { cpu: "200m", memory: "128Mi" }
#                volumeMounts:
#                  - name: tmp
#                    mountPath: /tmp
#            volumes:
#              - name: tmp
#                emptyDir: { sizeLimit: 8Mi }        # required by readOnlyRootFilesystem
#      YAML
#      kubectl -n kcsa-4c-lab rollout status deploy/payments-api --timeout=180s
#      # What each field buys you:
#      #   privileged/hostPID/hostIPC/hostPath removed -> the container is a
#      #     namespace boundary again, not a shell on the node.
#      #   runAsNonRoot + runAsUser 10001 -> a container escape lands as an
#      #     unprivileged uid; uid 0 in the container is uid 0 on the host unless
#      #     user namespaces are enabled.
#      #   allowPrivilegeEscalation=false -> sets no_new_privs; setuid binaries
#      #     inside the image can no longer raise privilege.
#      #   drop ALL -> removes even the default capability set (NET_RAW enables
#      #     ARP spoofing of the whole node network).
#      #   readOnlyRootFilesystem -> the attacker cannot drop a binary or patch
#      #     the app; it also makes the filesystem diff a real IoC signal.
#      #   seccompProfile RuntimeDefault -> ~44 dangerous syscalls blocked; PSS
#      #     'restricted' requires it explicitly.
#      #   limits -> a compromised pod cannot starve the node (DoS is a security
#      #     property, and a pod with no requests/limits is BestEffort, first to
#      #     be evicted and easiest to weaponise).
#      #   automountServiceAccountToken: false -> nothing to steal from
#      #     /var/run/secrets/... The Code layer can no longer reach the Cluster layer.
#
#  3.3 Confirm the escape routes are closed
#      POD=$(kubectl -n kcsa-4c-lab get pod -l app=payments-api -o name | head -1)
#      kubectl -n kcsa-4c-lab exec $POD -- id                     # uid=10001, not 0
#      kubectl -n kcsa-4c-lab exec $POD -- ls /host                # no such file
#      kubectl -n kcsa-4c-lab exec $POD -- ls /var/run/secrets/kubernetes.io  # no such file
#      kubectl -n kcsa-4c-lab exec $POD -- touch /etc/x            # read-only file system
#
# -----------------------------------------------------------------------------
#  STEP 4 — prove the service survived, then score
# -----------------------------------------------------------------------------
#      kubectl -n kcsa-4c-lab exec checkout  -- wget -qO- http://payments-api:8080/   # works
#      kubectl -n kcsa-4c-lab exec intruder  -- wget -qO- -T 5 http://payments-api:8080/  # times out (with a real CNI)
#      ./4cs-break-and-fix.sh verify        # 14/14, exit 0
#      ./4cs-break-and-fix.sh clean
#
# -----------------------------------------------------------------------------
#  WHY THIS IS ONE EXERCISE AND NOT FOUR
# -----------------------------------------------------------------------------
#  Trace the kill chain you just dismantled, and notice that every link crosses a
#  layer boundary — which is the entire point of the 4Cs model:
#
#    CODE      a credential in a ConfigMap leaks through any log, describe or
#              crash dump                                     →
#    CONTAINER the same pod runs as root with hostPath / and hostPID, so leaking
#              is not even necessary: read the node's filesystem directly →
#    CLUSTER   the auto-mounted token belongs to a cluster-admin ServiceAccount,
#              and no NetworkPolicy limits who can talk to the pod in the first
#              place                                          →
#    CLOUD     the kubelet accepts anonymous calls and the firewall lets the
#              whole internet reach it, so an attacker never needed the pod.
#
#  Each layer only constrains what it contains. Hardening the innermost layer
#  while the outermost is open just moves the cheapest path, it does not close
#  it — and hardening the outermost while the innermost is open only means the
#  attacker has to get in once. Defence in depth means all four, and the graded
#  availability checks are there because a control that takes production down is
#  a control that gets disabled on Monday.
#
#  Sources:
#    CNCF KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
#    Kubernetes Security Overview (the 4C model) —
#      https://kubernetes.io/docs/concepts/security/overview/
#    Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
#    RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#    Kubelet authn/authz — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
#    NetworkPolicy — https://kubernetes.io/docs/concepts/services-networking/network-policies/
#    Encrypting secret data at rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
# =============================================================================