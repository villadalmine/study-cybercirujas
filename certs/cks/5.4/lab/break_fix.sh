#!/usr/bin/env bash
# =============================================================================
#  CKS 1.34 — Domain 5: Microservice Vulnerabilities (weight of this topic: 2.5%)
#  Topic 5.4 — Appropriately use kernel hardening tools such as AppArmor, seccomp
#
#  BREAK & FIX LAB — "The node came back from the golden image"
#
#  WHAT THIS SCRIPT DOES
#    1. `stage`   builds a *healthy*, hardened baseline: one AppArmor-confined
#                 workload and two seccomp-confined workloads, all Running.
#    2. `break`   introduces three realistic node-level regressions and forces
#                 the pods to be recreated so the damage becomes visible.
#    3. `brief`   tells the student the SYMPTOMS and the ACCEPTANCE CRITERIA,
#                 not the root causes.
#    4. `hint`    three escalating hints (`hint 1`, `hint 2`, `hint 3`).
#    5. `verify`  machine-checks the repair, including anti-cheat assertions:
#                 stripping the hardening off the Pod spec is NOT a fix.
#    6. `cleanup` removes every artifact, including the kernel-level ones.
#
#  DANGER — READ BEFORE RUNNING
#    This script loads and unloads AppArmor profiles in the *host kernel* and
#    writes into the kubelet seccomp tree (<kubelet-root-dir>/seccomp). Both are
#    node-global, cluster-visible side effects that no `kubectl delete` can undo.
#    Run it ONLY on a disposable single-node lab VM that you are willing to
#    destroy. Never on a shared, staging or production node.
#
#  REQUIREMENTS
#    - Single-node Kubernetes >= 1.30 (the AppArmor Pod field is GA since 1.30;
#      the annotations `container.apparmor.security.beta.kubernetes.io/<c>` are
#      deprecated and are NOT used here). Verified against 1.34.
#    - A container runtime with AppArmor + seccomp support (containerd/CRI-O).
#    - An AppArmor-enabled kernel + userspace: `apparmor_parser` (Ubuntu/Debian
#      `apt-get install -y apparmor apparmor-utils`; openSUSE `apparmor-parser`).
#      RHEL/Fedora/Rocky ship SELinux instead — this lab will refuse to run.
#    - root on the node, `kubectl` with cluster-admin, and the image busybox:1.36.1
#      pullable (override with LAB_IMAGE=... for an air-gapped registry).
#
#  SOURCES (all statements below are traceable to these)
#    - CKS curriculum v1.34
#      https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#    - Restrict a Container's Access to Resources with AppArmor
#      https://kubernetes.io/docs/tutorials/security/apparmor/
#    - Restrict a Container's Syscalls with seccomp
#      https://kubernetes.io/docs/tutorials/security/seccomp/
#    - Pod API — securityContext.appArmorProfile / seccompProfile
#      https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context
#    - KEP-24 AppArmor support (GA in 1.30)
#      https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/24-apparmor
#    - KEP-2413 seccomp by default (GA in 1.27, kubelet --seccomp-default)
#      https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/2413-seccomp-by-default
#    - OCI runtime-spec, Linux seccomp object (actions, errnoRet, architectures)
#      https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#seccomp
#    - seccomp(2) — filter modes, SECCOMP_RET_* semantics
#      https://man7.org/linux/man-pages/man2/seccomp.2.html
#    - AppArmor profile language reference
#      https://gitlab.com/apparmor/apparmor/-/wikis/QuickProfileLanguage
#    - Security Profiles Operator (production-grade profile lifecycle)
#      https://github.com/kubernetes-sigs/security-profiles-operator
# =============================================================================

set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Configuration                                                               #
# --------------------------------------------------------------------------- #
LAB_ID="cks-5.4-kernel-hardening"
NS="${LAB_NS:-hardening-lab}"
IMAGE="${LAB_IMAGE:-busybox:1.36.1}"

AA_PROFILE="k8s-apparmor-example-deny-write"
AA_FILE="/etc/apparmor.d/${AA_PROFILE}"

SECCOMP_SUBDIR="profiles"          # relative to <kubelet-root-dir>/seccomp
AUDIT_PROFILE="audit.json"
SHIPPER_PROFILE="shipper.json"

KUBECTL="${KUBECTL:-kubectl}"
TIMEOUT="${LAB_TIMEOUT:-150s}"

# Filled in by detect_node()
NODE_NAME=""
NODE_EXEC_MODE="host"     # host | docker | podman
NODE_CTR=""
KUBELET_ROOT=""
SECCOMP_ROOT=""

# --------------------------------------------------------------------------- #
# Output helpers                                                              #
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_C=$'\033[36m'; C_M=$'\033[35m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_M=""
fi

log()   { printf '%s[ lab ]%s %s\n'  "$C_C" "$C_RST" "$*"; }
ok()    { printf '%s[ ok  ]%s %s\n'  "$C_G" "$C_RST" "$*"; }
warn()  { printf '%s[warn ]%s %s\n'  "$C_Y" "$C_RST" "$*"; }
fail()  { printf '%s[fail ]%s %s\n'  "$C_R" "$C_RST" "$*"; }
die()   { fail "$*"; exit 1; }
rule()  { printf '%s%s%s\n' "$C_M" "$(printf '─%.0s' $(seq 1 74))" "$C_RST"; }
head1() { rule; printf '%s%s%s\n' "$C_B" "$*" "$C_RST"; rule; }

trap 'rc=$?; [[ $rc -ne 0 ]] && fail "aborted at line $LINENO (exit $rc)"; exit $rc' ERR

# --------------------------------------------------------------------------- #
# Node access abstraction                                                     #
#   The kubelet seccomp tree lives on the NODE filesystem. On a bare VM that   #
#   is this host; on kind/minikube-docker it is inside the node container.     #
#   AppArmor profiles, in contrast, always live in the HOST kernel: the node   #
#   container shares that kernel and (by default) the root AppArmor namespace. #
# --------------------------------------------------------------------------- #
detect_node() {
  NODE_NAME="$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}')"
  if command -v docker >/dev/null 2>&1 && docker inspect "$NODE_NAME" >/dev/null 2>&1; then
    NODE_EXEC_MODE="docker"; NODE_CTR="$NODE_NAME"
  elif command -v podman >/dev/null 2>&1 && podman inspect "$NODE_NAME" >/dev/null 2>&1; then
    NODE_EXEC_MODE="podman"; NODE_CTR="$NODE_NAME"
  else
    NODE_EXEC_MODE="host"
  fi
  KUBELET_ROOT="$(kubelet_root_dir)"
  SECCOMP_ROOT="${KUBELET_ROOT}/seccomp"
}

node_exec() {   # node_exec '<sh command string>'
  case "$NODE_EXEC_MODE" in
    host)   sh -c "$1" ;;
    docker) docker exec -i "$NODE_CTR" sh -c "$1" ;;
    podman) podman exec -i "$NODE_CTR" sh -c "$1" ;;
  esac
}

node_put() {    # node_put <dest-path>   (file content arrives on stdin)
  local dest="$1"
  case "$NODE_EXEC_MODE" in
    host)   mkdir -p "$(dirname "$dest")"; cat > "$dest"; chmod 0644 "$dest" ;;
    docker) docker exec -i "$NODE_CTR" sh -c "mkdir -p \$(dirname '$dest') && cat > '$dest' && chmod 0644 '$dest'" ;;
    podman) podman exec -i "$NODE_CTR" sh -c "mkdir -p \$(dirname '$dest') && cat > '$dest' && chmod 0644 '$dest'" ;;
  esac
}

kubelet_root_dir() {
  # The seccomp root is <kubelet --root-dir>/seccomp. Most distributions use the
  # default /var/lib/kubelet, but k3s/RKE2 and hardened images relocate it, and a
  # wrong assumption here is the single most common reason a Localhost seccomp
  # profile "does not exist" for the kubelet while `ls` shows it just fine.
  local pid rd=""
  pid="$(node_exec "pgrep -x kubelet 2>/dev/null | head -n1" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    rd="$(node_exec "tr '\\0' '\\n' < /proc/${pid}/cmdline 2>/dev/null | sed -n 's|^--root-dir=||p' | head -n1" 2>/dev/null || true)"
  fi
  printf '%s\n' "${rd:-/var/lib/kubelet}"
}

# --------------------------------------------------------------------------- #
# Preflight                                                                   #
# --------------------------------------------------------------------------- #
confirm_disposable() {
  [[ "${LAB_YES:-}" == "1" ]] && return 0
  warn "This lab mutates NODE kernel state (AppArmor) and ${SECCOMP_ROOT}."
  warn "Use a throwaway VM. Type exactly: I UNDERSTAND"
  local answer=""
  read -r -p "> " answer || true
  [[ "$answer" == "I UNDERSTAND" ]] || die "confirmation not given — nothing was changed."
}

preflight() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root: apparmor_parser and ${SECCOMP_ROOT} require it."
  command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found in PATH."
  $KUBECTL version -o json >/dev/null 2>&1 || die "no reachable cluster (check KUBECONFIG)."

  command -v apparmor_parser >/dev/null 2>&1 \
    || die "apparmor_parser missing — install 'apparmor apparmor-utils' (Debian/Ubuntu). SELinux distros cannot run this lab."

  local aa_enabled=""
  aa_enabled="$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo N)"
  [[ "$aa_enabled" == "Y" ]] \
    || die "AppArmor is not enabled in this kernel (/sys/module/apparmor/parameters/enabled=${aa_enabled}). Boot with apparmor=1 security=apparmor."

  [[ -d /sys/kernel/security/apparmor ]] \
    || die "securityfs is not mounted: mount -t securityfs securityfs /sys/kernel/security"

  grep -q '^Seccomp' /proc/self/status \
    || die "this kernel reports no seccomp support (CONFIG_SECCOMP_FILTER=y is required)."

  local nodes
  nodes="$($KUBECTL get nodes --no-headers | wc -l)"
  if [[ "$nodes" -ne 1 && "${LAB_FORCE:-}" != "1" ]]; then
    die "found ${nodes} nodes. Node-local artifacts would only exist on one of them; pods would fail nondeterministically. Use a single-node lab, or set LAB_FORCE=1 if every node is prepared identically."
  fi

  detect_node
  ok "node=${NODE_NAME} access=${NODE_EXEC_MODE} kubelet-root=${KUBELET_ROOT}"
  ok "seccomp root = ${SECCOMP_ROOT}"
  [[ "$NODE_EXEC_MODE" != "host" ]] && warn "containerised node detected: AppArmor profiles are still loaded into the HOST kernel and shared with the node container."
  return 0
}

# --------------------------------------------------------------------------- #
# Artifacts                                                                   #
# --------------------------------------------------------------------------- #
write_apparmor_profile() {
  # Deny every filesystem write while still allowing the process to run and read.
  # `flags=(attach_disconnected)` prevents "disconnected path" denials for the
  # mount namespace the container lives in — a classic false positive when the
  # same profile is written for a plain host process and then reused in k8s.
  cat > "$AA_FILE" <<'AAPROFILE'
#include <tunables/global>

profile k8s-apparmor-example-deny-write flags=(attach_disconnected) {
  #include <abstractions/base>

  # Allow reads and executions anywhere ...
  file,

  # ... but deny every write, including creating and removing files.
  deny /** w,
  deny /** l,
  deny /** k,
}
AAPROFILE
  apparmor_parser -q -r "$AA_FILE"
  ok "AppArmor profile ${AA_PROFILE} loaded (enforce)"
}

write_audit_profile() {
  # SCMP_ACT_LOG: never blocks, logs every syscall not matched by a rule.
  # This is the safe first step of a real profiling campaign — you collect the
  # syscall set from production traffic before you dare deny anything.
  node_put "${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${AUDIT_PROFILE}" <<'JSON'
{
  "defaultAction": "SCMP_ACT_LOG"
}
JSON
  ok "seccomp profile ${SECCOMP_SUBDIR}/${AUDIT_PROFILE} written"
}

write_shipper_profile_good() {
  # Deliberately NO "architectures" key: when it is omitted, runc applies the
  # filter to the runtime's native architecture only. Hardcoding SCMP_ARCH_X86_64
  # silently disables the whole profile on an arm64 node — a very real outage.
  node_put "${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}" <<'JSON'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": [
        "kexec_load",
        "kexec_file_load",
        "init_module",
        "finit_module",
        "delete_module",
        "bpf",
        "perf_event_open",
        "ptrace",
        "process_vm_readv",
        "process_vm_writev",
        "mount",
        "umount2",
        "pivot_root",
        "reboot",
        "swapon",
        "swapoff"
      ],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
JSON
  ok "seccomp profile ${SECCOMP_SUBDIR}/${SHIPPER_PROFILE} written (healthy baseline)"
}

apply_workloads() {
  $KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
  $KUBECTL label namespace "$NS" \
      "pod-security.kubernetes.io/enforce=baseline" \
      "lab=${LAB_ID}" --overwrite >/dev/null

  cat <<YAML | $KUBECTL apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-web
  namespace: ${NS}
  labels: { app: secure-web, lab: ${LAB_ID} }
spec:
  replicas: 1
  selector: { matchLabels: { app: secure-web } }
  template:
    metadata:
      labels: { app: secure-web }
    spec:
      # Pod-level AppArmor: inherited by every container that does not override it.
      # GA field since v1.30; the beta annotations are gone in 1.34.
      securityContext:
        appArmorProfile:
          type: Localhost
          localhostProfile: ${AA_PROFILE}
      containers:
      - name: web
        image: ${IMAGE}
        command: ["/bin/sh","-c"]
        args:
          - |
            echo "[secure-web] AppArmor label: \$(cat /proc/self/attr/current 2>/dev/null || echo unknown)"
            while true; do sleep 10; done
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
        resources:
          requests: { cpu: "10m", memory: "16Mi" }
          limits:   { cpu: "100m", memory: "64Mi" }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: audit-agent
  namespace: ${NS}
  labels: { app: audit-agent, lab: ${LAB_ID} }
spec:
  replicas: 1
  selector: { matchLabels: { app: audit-agent } }
  template:
    metadata:
      labels: { app: audit-agent }
    spec:
      containers:
      - name: agent
        image: ${IMAGE}
        command: ["/bin/sh","-c"]
        args:
          - |
            echo "[audit-agent] seccomp mode: \$(grep -E '^Seccomp:' /proc/self/status)"
            while true; do sleep 10; done
        securityContext:
          # Path is relative to <kubelet-root-dir>/seccomp. A leading "/" or ".."
          # is rejected by the API server, not by the kubelet.
          seccompProfile:
            type: Localhost
            localhostProfile: ${SECCOMP_SUBDIR}/${AUDIT_PROFILE}
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
        resources:
          requests: { cpu: "10m", memory: "16Mi" }
          limits:   { cpu: "100m", memory: "64Mi" }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-shipper
  namespace: ${NS}
  labels: { app: log-shipper, lab: ${LAB_ID} }
spec:
  replicas: 1
  selector: { matchLabels: { app: log-shipper } }
  template:
    metadata:
      labels: { app: log-shipper }
    spec:
      containers:
      - name: shipper
        image: ${IMAGE}
        command: ["/bin/sh","-c"]
        args:
          - |
            SPOOL=/var/log/shipper/shipper.log
            : > "\$SPOOL"
            while true; do
              date -u '+%Y-%m-%dT%H:%M:%SZ shipped batch' >> "\$SPOOL"
              if ! chmod 0600 "\$SPOOL"; then
                echo "[log-shipper] FATAL: cannot enforce 0600 on the spool file" >&2
                exit 1
              fi
              sleep 5
            done
        securityContext:
          seccompProfile:
            type: Localhost
            localhostProfile: ${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
        volumeMounts:
        - { name: spool, mountPath: /var/log/shipper }
        resources:
          requests: { cpu: "10m", memory: "16Mi" }
          limits:   { cpu: "100m", memory: "64Mi" }
      volumes:
      - { name: spool, emptyDir: {} }
YAML
}

# --------------------------------------------------------------------------- #
# stage — healthy baseline                                                    #
# --------------------------------------------------------------------------- #
cmd_stage() {
  head1 "STAGE — building the hardened baseline"
  write_apparmor_profile
  write_audit_profile
  write_shipper_profile_good
  apply_workloads

  local d
  for d in secure-web audit-agent log-shipper; do
    log "waiting for deployment/${d} ..."
    $KUBECTL -n "$NS" rollout status "deploy/${d}" --timeout="$TIMEOUT" >/dev/null \
      || die "baseline failed for ${d}. Inspect: kubectl -n ${NS} describe deploy/${d}"
  done

  ok "baseline healthy — this is the state you must restore."
  echo
  log "Proof that the hardening is really active (not just declared):"
  echo "  \$ kubectl -n ${NS} exec deploy/secure-web  -- cat /proc/1/attr/current"
  $KUBECTL -n "$NS" exec deploy/secure-web -- cat /proc/1/attr/current 2>/dev/null || true
  echo "  \$ kubectl -n ${NS} exec deploy/audit-agent -- grep Seccomp /proc/1/status"
  $KUBECTL -n "$NS" exec deploy/audit-agent -- grep -E '^Seccomp' /proc/1/status 2>/dev/null || true
  echo
  echo "  (Seccomp: 2 == SECCOMP_MODE_FILTER. Seccomp: 0 means NO filter is attached —"
  echo "   which is exactly what you get if you 'fix' an outage by deleting the field.)"
}

# --------------------------------------------------------------------------- #
# break — three controlled regressions                                        #
# --------------------------------------------------------------------------- #
cmd_break() {
  head1 "BREAK — simulating a node rebuilt from a stale golden image"

  # Fault A — the AppArmor profile is gone from the kernel and from disk.
  apparmor_parser -q -R "$AA_FILE" 2>/dev/null || true
  rm -f "$AA_FILE"
  log "fault A injected"

  # Fault B — the referenced Localhost seccomp profile file no longer exists.
  node_exec "rm -f '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${AUDIT_PROFILE}'"
  log "fault B injected"

  # Fault C — a "security hotfix" widened a deny list without testing the app.
  node_put "${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}" <<'JSON'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": [
        "kexec_load",
        "kexec_file_load",
        "init_module",
        "finit_module",
        "delete_module",
        "bpf",
        "perf_event_open",
        "ptrace",
        "process_vm_readv",
        "process_vm_writev",
        "mount",
        "umount2",
        "pivot_root",
        "reboot",
        "swapon",
        "swapoff",
        "chmod",
        "fchmod",
        "fchmodat"
      ],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
JSON
  log "fault C injected"

  # Nothing above touches a running container: both AppArmor and seccomp are
  # applied by the runtime at container CREATE time. The drift is invisible
  # until the pods are recreated — so we recreate them, exactly like a reboot,
  # an eviction or a node autoscaler event would.
  $KUBECTL -n "$NS" delete pod --all --wait=false >/dev/null 2>&1 || true
  log "pods deleted — waiting ~40s for the runtime to try (and fail) to recreate them"
  sleep 40
  echo
  $KUBECTL -n "$NS" get pods -o wide || true
}

# --------------------------------------------------------------------------- #
# brief — symptoms and acceptance criteria (no root causes)                   #
# --------------------------------------------------------------------------- #
cmd_brief() {
  head1 "STUDENT BRIEF — CKS 5.4"
  cat <<BRIEF
${C_B}SCENARIO${C_RST}
  Node ${NODE_NAME} was reimaged overnight from a golden image that predates the
  kernel-hardening rollout. Nothing alerted at the time, because running
  containers are unaffected by node drift. This morning the pods were recreated
  and namespace ${C_B}${NS}${C_RST} fell over.

${C_B}SYMPTOMS YOU WILL SEE${C_RST}
  1) deploy/secure-web   0/1. The Pod is scheduled but the container never
                         starts. Events show a runtime error mentioning
                         'apparmor' — one of:
                            Error: failed to create containerd task: ... OCI
                            runtime create failed: unable to start container
                            process: apply apparmor profile: apparmor failed to
                            apply profile: write /proc/self/attr/apparmor/exec:
                            no such file or directory
                         or, on older kubelets, the Pod stays Pending with
                            Blocked: Cannot enforce AppArmor: profile "..." is not loaded
                         (Exact wording varies by runtime version — read YOUR event,
                          do not pattern-match mine.)

  2) deploy/audit-agent  0/1, container status ${C_B}CreateContainerError${C_RST}:
                            failed to generate spec: failed to generate seccomp
                            spec opts: open ${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${AUDIT_PROFILE}:
                            no such file or directory

  3) deploy/log-shipper  ${C_B}CrashLoopBackOff${C_RST}. This one is different: the container
                         STARTS, runs for a moment, then dies. Its log ends with
                            chmod: /var/log/shipper/shipper.log: Operation not permitted
                            [log-shipper] FATAL: cannot enforce 0600 on the spool file
                         'Operation not permitted' on an operation that root
                         should obviously be allowed to do is the fingerprint of
                         a syscall filter, not of file permissions.

${C_B}YOUR MISSION${C_RST}
  Restore all three Deployments to 1/1 Ready ${C_B}without weakening the security
  posture${C_RST}. Specifically, the verifier will reject your fix if you:
    - remove or change 'appArmorProfile' / 'seccompProfile' in the Pod spec,
    - switch any of them to type: Unconfined or type: RuntimeDefault,
    - replace shipper.json with a profile that denies nothing.
  The workloads must end up confined, provably, from inside the containers:
    - secure-web  : /proc/1/attr/current == "${AA_PROFILE} (enforce)"
                    and writing to /tmp must still be denied.
    - audit-agent : /proc/1/status must report Seccomp: 2 (filter mode).
    - log-shipper : running with a stable restart count, ptrace/init_module and
                    the rest of the dangerous set still blocked, chmod working.

${C_B}TOOLBOX${C_RST}
  kubectl -n ${NS} describe pod <pod> | tail -30
  kubectl -n ${NS} logs <pod> --previous
  aa-status | head -20        # or: cat /sys/kernel/security/apparmor/profiles
  apparmor_parser -q -r /etc/apparmor.d/<profile>
  ls -l ${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/
  dmesg -T | grep -iE 'apparmor|seccomp' | tail -20
  ausyscall <number>          # syscall number -> name, from the 'auditd' package
  grep -E '^Seccomp' /proc/<pid>/status

${C_B}COMMANDS${C_RST}
  $0 hint 1|2|3     progressive hints
  $0 status         current lab state
  $0 verify         grade your repair
  $0 cleanup        destroy every artifact (namespace + kernel + kubelet files)
BRIEF
}

# --------------------------------------------------------------------------- #
# hint                                                                        #
# --------------------------------------------------------------------------- #
cmd_hint() {
  case "${1:-1}" in
    1) cat <<'H'
HINT 1 — classify before you touch anything.
  Two of the three faults happen BEFORE the container's first instruction runs
  (the runtime refuses to create it). One happens AFTER (the process starts and
  then gets an error back from the kernel). That split tells you where to look:
  "container never created" => the profile the Pod REFERENCES cannot be resolved
  or applied on this node. "container ran then failed" => the profile resolved
  fine and is doing exactly what it was told to do.
H
;;
    2) cat <<'H'
HINT 2 — where each profile physically lives.
  * AppArmor Localhost profiles are NOT files that Kubernetes reads. They must
    already be loaded into the kernel of the node. List what is loaded:
        aa-status
        cat /sys/kernel/security/apparmor/profiles
    A profile is loaded with `apparmor_parser -r <file>`; persistence across
    reboot is the distro's job (/etc/apparmor.d + the apparmor unit), not
    Kubernetes' job.
  * seccomp Localhost profiles ARE files, read by the kubelet, resolved relative
    to <kubelet --root-dir>/seccomp. On this node that directory is printed by
    `$0 status`. The API server validates the *string*, never the file, so a
    missing file is only discovered at container creation time.
H
;;
    3) cat <<'H'
HINT 3 — for the crash-looping one, identify the syscall.
  seccomp with SCMP_ACT_ERRNO returns an errno to the caller; errnoRet 1 is
  EPERM, which userspace prints as "Operation not permitted". To find WHICH
  syscall was denied, either read the profile's deny list and match it against
  what the failing command does, or make the kernel tell you:
      # temporarily change that rule's action to SCMP_ACT_LOG, recreate the pod
      dmesg -T | grep -i seccomp | tail
      # or, with auditd installed:
      ausearch -m SECCOMP -ts recent
      ausyscall <syscall-number>
  Then remove ONLY that syscall family from the deny list — keep everything else
  denied. Remember: editing the JSON does nothing to a running container. The
  filter is installed by runc just before execve(). You must recreate the Pod.
H
;;
    *) die "hint levels are 1, 2 or 3" ;;
  esac
}

# --------------------------------------------------------------------------- #
# status                                                                      #
# --------------------------------------------------------------------------- #
cmd_status() {
  head1 "STATUS"
  echo "node            : ${NODE_NAME} (${NODE_EXEC_MODE})"
  echo "kubelet root    : ${KUBELET_ROOT}"
  echo "seccomp root    : ${SECCOMP_ROOT}"
  echo
  echo "--- AppArmor profiles loaded in the kernel (filtered) ---"
  grep -E "^(${AA_PROFILE}|cri-containerd|docker-default|runc)" /sys/kernel/security/apparmor/profiles 2>/dev/null || echo "(none matched)"
  echo
  echo "--- seccomp profile files on the node ---"
  node_exec "ls -l '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/' 2>/dev/null" || echo "(directory missing)"
  echo
  echo "--- workloads ---"
  $KUBECTL -n "$NS" get deploy,pods 2>/dev/null || echo "(namespace ${NS} absent)"
}

# --------------------------------------------------------------------------- #
# verify                                                                      #
# --------------------------------------------------------------------------- #
PASS=0; FAILED=0
check()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; PASS=$((PASS+1)); else fail "$1"; FAILED=$((FAILED+1)); fi; }
checkn() { if ! eval "$2" >/dev/null 2>&1; then ok "$1"; PASS=$((PASS+1)); else fail "$1"; FAILED=$((FAILED+1)); fi; }

cmd_verify() {
  head1 "VERIFY"
  local jp_aa jp_sc_audit jp_sc_ship

  # --- Availability -------------------------------------------------------- #
  local d
  for d in secure-web audit-agent log-shipper; do
    check "deployment/${d} is 1/1 Ready" \
      "[ \"\$($KUBECTL -n $NS get deploy $d -o jsonpath='{.status.readyReplicas}')\" = '1' ]"
  done

  # --- Anti-cheat: the declared posture must be unchanged ------------------- #
  jp_aa="$($KUBECTL -n "$NS" get deploy secure-web -o jsonpath='{.spec.template.spec.securityContext.appArmorProfile.type}/{.spec.template.spec.securityContext.appArmorProfile.localhostProfile}' 2>/dev/null || true)"
  check "secure-web still declares Localhost/${AA_PROFILE}" \
    "[ \"$jp_aa\" = \"Localhost/${AA_PROFILE}\" ]"

  jp_sc_audit="$($KUBECTL -n "$NS" get deploy audit-agent -o jsonpath='{.spec.template.spec.containers[0].securityContext.seccompProfile.type}/{.spec.template.spec.containers[0].securityContext.seccompProfile.localhostProfile}' 2>/dev/null || true)"
  check "audit-agent still declares Localhost/${SECCOMP_SUBDIR}/${AUDIT_PROFILE}" \
    "[ \"$jp_sc_audit\" = \"Localhost/${SECCOMP_SUBDIR}/${AUDIT_PROFILE}\" ]"

  jp_sc_ship="$($KUBECTL -n "$NS" get deploy log-shipper -o jsonpath='{.spec.template.spec.containers[0].securityContext.seccompProfile.type}/{.spec.template.spec.containers[0].securityContext.seccompProfile.localhostProfile}' 2>/dev/null || true)"
  check "log-shipper still declares Localhost/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}" \
    "[ \"$jp_sc_ship\" = \"Localhost/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}\" ]"

  # --- Enforcement really happening in the kernel --------------------------- #
  check "AppArmor profile ${AA_PROFILE} is loaded in enforce mode" \
    "grep -qE '^${AA_PROFILE} \\(enforce\\)\$' /sys/kernel/security/apparmor/profiles"

  check "secure-web PID 1 is labelled '${AA_PROFILE} (enforce)'" \
    "$KUBECTL -n $NS exec deploy/secure-web -- cat /proc/1/attr/current 2>/dev/null | grep -q '${AA_PROFILE} (enforce)'"

  checkn "secure-web still cannot write to /tmp (deny /** w is effective)" \
    "$KUBECTL -n $NS exec deploy/secure-web -- sh -c 'echo probe > /tmp/probe'"

  check "audit-agent runs in seccomp filter mode (Seccomp: 2)" \
    "$KUBECTL -n $NS exec deploy/audit-agent -- grep -qE '^Seccomp:[[:space:]]+2\$' /proc/1/status"

  check "audit profile file exists on the node" \
    "node_exec \"test -s '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${AUDIT_PROFILE}'\""

  check "log-shipper runs in seccomp filter mode (Seccomp: 2)" \
    "$KUBECTL -n $NS exec deploy/log-shipper -- grep -qE '^Seccomp:[[:space:]]+2\$' /proc/1/status"

  # --- The shipper profile must still be a real deny list ------------------- #
  check "shipper.json still denies ptrace" \
    "node_exec \"grep -q '\\\"ptrace\\\"' '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}'\""
  check "shipper.json still denies init_module" \
    "node_exec \"grep -q '\\\"init_module\\\"' '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}'\""
  checkn "shipper.json no longer denies the chmod family" \
    "node_exec \"grep -qE '\\\"(chmod|fchmod|fchmodat)\\\"' '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}'\""

  # --- Stability: the crash loop must really be over ------------------------ #
  local r1 r2
  r1="$($KUBECTL -n "$NS" get pods -l app=log-shipper -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo x)"
  log "sampling log-shipper restart count for 20s (was: ${r1}) ..."
  sleep 20
  r2="$($KUBECTL -n "$NS" get pods -l app=log-shipper -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo y)"
  check "log-shipper is stable (no restart during a 20s window: ${r1} -> ${r2})" "[ \"$r1\" = \"$r2\" ]"

  echo
  rule
  if [[ "$FAILED" -eq 0 ]]; then
    printf '%sRESULT: PASS — %d/%d checks. Cluster restored WITHOUT lowering the posture.%s\n' "$C_G" "$PASS" "$((PASS+FAILED))" "$C_RST"
  else
    printf '%sRESULT: FAIL — %d passed, %d failed.%s Re-read the failing lines; each one names the exact property that is missing.\n' "$C_R" "$PASS" "$FAILED" "$C_RST"
    return 1
  fi
}

# --------------------------------------------------------------------------- #
# cleanup                                                                     #
# --------------------------------------------------------------------------- #
cmd_cleanup() {
  head1 "CLEANUP"
  $KUBECTL delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  apparmor_parser -q -R "$AA_FILE" 2>/dev/null || true
  # If the file was already deleted, unload by name via the profile text.
  if grep -qE "^${AA_PROFILE} " /sys/kernel/security/apparmor/profiles 2>/dev/null; then
    printf 'profile %s {\n}\n' "$AA_PROFILE" | apparmor_parser -q -R /dev/stdin 2>/dev/null || true
  fi
  rm -f "$AA_FILE"
  node_exec "rm -f '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${AUDIT_PROFILE}' '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}/${SHIPPER_PROFILE}'" || true
  node_exec "rmdir '${SECCOMP_ROOT}/${SECCOMP_SUBDIR}' 2>/dev/null" || true
  ok "namespace, kernel profile and seccomp files removed"
}

# --------------------------------------------------------------------------- #
# main                                                                        #
# --------------------------------------------------------------------------- #
usage() {
  cat <<USAGE
${LAB_ID} — CKS 1.34 topic 5.4 break & fix

  sudo $0 start            preflight + stage + break + brief   (start here)
  sudo $0 stage            build the healthy baseline only
  sudo $0 break            inject the faults into a staged lab
  sudo $0 brief            reprint the student brief
  sudo $0 hint <1|2|3>     progressive hints
  sudo $0 status           show current node + cluster state
  sudo $0 verify           grade the repair
  sudo $0 cleanup          remove everything

Environment: LAB_NS, LAB_IMAGE, LAB_TIMEOUT, LAB_YES=1 (skip confirmation),
             LAB_FORCE=1 (allow multi-node), KUBECTL, KUBECONFIG
USAGE
}

main() {
  local cmd="${1:-start}"; shift || true
  case "$cmd" in
    start)   preflight; confirm_disposable; cmd_stage; cmd_break; cmd_brief ;;
    stage)   preflight; confirm_disposable; cmd_stage ;;
    break)   preflight; cmd_break; cmd_brief ;;
    brief)   detect_node; cmd_brief ;;
    hint)    cmd_hint "${1:-1}" ;;
    status)  detect_node; cmd_status ;;
    verify)  detect_node; cmd_verify ;;
    cleanup) detect_node; cmd_cleanup ;;
    -h|--help|help) usage ;;
    *)       usage; exit 1 ;;
  esac
}

main "$@"

# =============================================================================
# =============================================================================
#  SOLUTION — do not read until you have tried, or until `verify` passes.
# =============================================================================
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Triage: separate "never created" from "created then died"
# ---------------------------------------------------------------------------
#   kubectl -n hardening-lab get pods
#
#     NAME                           READY   STATUS                 RESTARTS
#     audit-agent-6c9f4d8b7-2xk4p    0/1     CreateContainerError   0
#     log-shipper-7f8b6c5d94-r8ttm   0/1     CrashLoopBackOff       4
#     secure-web-5d7c8b9f6-pq2vn     0/1     CreateContainerError   0
#
#   CreateContainerError / RunContainerError => the kubelet or the OCI runtime
#   refused to build the container. The workload's own code never ran; its logs
#   are empty. Look at EVENTS.
#   CrashLoopBackOff with a non-empty log => the container was built correctly,
#   the security profile applied cleanly, and the application is being told
#   "no" by the kernel at runtime. Look at LOGS.
#
#   This distinction is worth ~30 seconds in the exam and saves five minutes of
#   looking in the wrong place.
#
# ---------------------------------------------------------------------------
# FAULT A — secure-web: the AppArmor profile is not loaded on the node
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n hardening-lab describe pod -l app=secure-web | tail -25
#
#     Warning  Failed  ...  Error: failed to create containerd task: failed to
#     create shim task: OCI runtime create failed: unable to start container
#     process: error during container init: apply apparmor profile: apparmor
#     failed to apply profile: write /proc/self/attr/apparmor/exec:
#     no such file or directory: unknown
#
#   Confirm what the Pod is asking for, then what the kernel actually has:
#
#   kubectl -n hardening-lab get deploy secure-web \
#     -o jsonpath='{.spec.template.spec.securityContext.appArmorProfile}{"\n"}'
#     {"localhostProfile":"k8s-apparmor-example-deny-write","type":"Localhost"}
#
#   aa-status | head -5
#     apparmor module is loaded.
#     34 profiles are loaded.
#     34 profiles are in enforce mode.
#        ...
#   aa-status --profiled 2>/dev/null; grep k8s-apparmor /sys/kernel/security/apparmor/profiles
#     (no output)  <-- the profile the Pod demands does not exist in this kernel
#
#   KEY MENTAL MODEL: `type: Localhost` for AppArmor means "a profile already
#   present in this node's kernel, by name". Kubernetes never ships, compiles or
#   distributes AppArmor profiles. There is no AppArmor equivalent of the
#   kubelet seccomp directory. Getting the profile onto every node is an
#   infrastructure problem (config management, a DaemonSet with a privileged
#   loader, or the Security Profiles Operator's AppArmorProfile CRD).
#
# Fix — recreate the profile file and load it into the kernel:
#
#   cat > /etc/apparmor.d/k8s-apparmor-example-deny-write <<'EOF'
#   #include <tunables/global>
#
#   profile k8s-apparmor-example-deny-write flags=(attach_disconnected) {
#     #include <abstractions/base>
#     file,
#     deny /** w,
#     deny /** l,
#     deny /** k,
#   }
#   EOF
#
#   apparmor_parser -q -r /etc/apparmor.d/k8s-apparmor-example-deny-write
#   grep k8s-apparmor /sys/kernel/security/apparmor/profiles
#     k8s-apparmor-example-deny-write (enforce)
#
#   The `profile <name>` line, not the filename, is what Kubernetes matches
#   against localhostProfile. Renaming the file changes nothing; renaming the
#   profile breaks every Pod that references it.
#   `apparmor_parser -r` replaces an existing profile; `-a` adds and fails if it
#   already exists; `-R` removes it. In scripts always use `-r` for idempotency.
#
#   Now force a new container. Deleting the Pod is enough — the profile is read
#   at container create time, so no rollout of the Deployment is required:
#
#   kubectl -n hardening-lab delete pod -l app=secure-web
#   kubectl -n hardening-lab rollout status deploy/secure-web
#
# Verify the confinement is real, not merely declared:
#
#   kubectl -n hardening-lab exec deploy/secure-web -- cat /proc/1/attr/current
#     k8s-apparmor-example-deny-write (enforce)
#
#   kubectl -n hardening-lab exec deploy/secure-web -- sh -c 'echo x > /tmp/x'
#     sh: can't create /tmp/x: Permission denied
#     command terminated with exit code 1
#
#   dmesg -T | grep -i apparmor | tail -3
#     [...] audit: type=1400 apparmor="DENIED" operation="mknod"
#           profile="k8s-apparmor-example-deny-write" name="/tmp/x" ...
#           requested_mask="c" denied_mask="c" fsuid=0 ouid=0
#
#   Reading those DENIED lines is the core AppArmor debugging skill:
#   `operation` + `name` + `denied_mask` tell you exactly which rule to add.
#   Mask letters: r read, w write, a append, c create, l link, k lock, x execute,
#   m mmap-exec. `aa-logprof` / `aa-genprof` turn those log lines into rules
#   interactively; `aa-complain <profile>` switches a profile to complain mode,
#   where violations are logged but permitted — the AppArmor analogue of
#   SCMP_ACT_LOG, and the right first move when you must not cause an outage.
#
# PERSISTENCE (the part people forget): a profile loaded with apparmor_parser is
# gone after reboot unless the file lives in /etc/apparmor.d and the distro's
# apparmor service is enabled (`systemctl enable --now apparmor`). Because this
# lab's fault was "the golden image lost the file", the durable fix is the file
# on disk plus the enabled unit — not just the parser invocation.
#
# ---------------------------------------------------------------------------
# FAULT B — audit-agent: the Localhost seccomp profile file is missing
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n hardening-lab describe pod -l app=audit-agent | tail -15
#
#     Warning  Failed  ...  Error: failed to generate spec: failed to generate
#     seccomp spec opts: open /var/lib/kubelet/seccomp/profiles/audit.json:
#     no such file or directory
#
#   The error hands you the absolute path. Note how it was assembled:
#
#     <kubelet --root-dir>/seccomp  +  localhostProfile
#     /var/lib/kubelet/seccomp      +  profiles/audit.json
#
#   Confirm the root dir instead of assuming it (k3s, RKE2 and hardened images
#   move it, and then your `ls` of /var/lib/kubelet looks correctly empty):
#
#   ps -eo args= -C kubelet | tr ' ' '\n' | grep -- --root-dir
#   ls -l /var/lib/kubelet/seccomp/profiles/
#     total 4
#     -rw-r--r-- 1 root root 187 ... shipper.json      <-- audit.json is gone
#
#   Also note what did NOT happen: the API server accepted this Pod. It only
#   validates that localhostProfile is a relative path with no "..". Existence
#   is a node-local, create-time concern. This is why a Localhost seccomp
#   profile is a node prerequisite, exactly like an AppArmor profile, and why
#   admission control cannot protect you from this class of outage.
#
# Fix:
#   mkdir -p /var/lib/kubelet/seccomp/profiles
#   cat > /var/lib/kubelet/seccomp/profiles/audit.json <<'EOF'
#   {
#     "defaultAction": "SCMP_ACT_LOG"
#   }
#   EOF
#   chmod 0644 /var/lib/kubelet/seccomp/profiles/audit.json
#
#   kubectl -n hardening-lab delete pod -l app=audit-agent
#   kubectl -n hardening-lab rollout status deploy/audit-agent
#
#   kubectl -n hardening-lab exec deploy/audit-agent -- grep Seccomp /proc/1/status
#     Seccomp:        2
#     Seccomp_filters:        1
#
#   Seccomp: 0 = disabled, 1 = strict mode, 2 = filter mode (BPF). A container
#   that reports 0 has NO filter at all — if you ever "fix" a seccomp problem
#   and the value drops to 0, you did not fix it, you removed the control.
#
#   SCMP_ACT_LOG never blocks anything; it writes an audit record per unmatched
#   syscall. That is what makes audit.json safe to deploy everywhere and the
#   correct starting point for building a real allow-list. Harvest with:
#     ausearch -m SECCOMP -ts recent | ausyscall --dump
#   or read /var/log/audit/audit.log directly. Requires kernel >= 4.14 and
#   libseccomp >= 2.4; on older stacks the profile is rejected at create time.
#
# ---------------------------------------------------------------------------
# FAULT C — log-shipper: the seccomp profile denies a syscall the app needs
# ---------------------------------------------------------------------------
# Diagnose:
#   kubectl -n hardening-lab logs -l app=log-shipper --previous --tail=5
#     chmod: /var/log/shipper/shipper.log: Operation not permitted
#     [log-shipper] FATAL: cannot enforce 0600 on the spool file
#
#   "Operation not permitted" (EPERM) from root, on a file root owns, on a
#   writable emptyDir. Nothing about DAC, capabilities or the read-only root
#   filesystem explains that. Rule the alternatives out fast:
#
#     kubectl -n hardening-lab get pod -l app=log-shipper \
#       -o jsonpath='{.items[0].spec.containers[0].securityContext}{"\n"}'
#     # runAsUser 0, no readOnlyRootFilesystem, caps dropped but chmod on your
#     # own file needs no capability => not a capability problem.
#
#   Then read the profile the Pod points at:
#
#   kubectl -n hardening-lab get deploy log-shipper -o jsonpath=\
#     '{.spec.template.spec.containers[0].securityContext.seccompProfile}{"\n"}'
#     {"localhostProfile":"profiles/shipper.json","type":"Localhost"}
#
#   cat /var/lib/kubelet/seccomp/profiles/shipper.json
#     ... "names": [ ..., "chmod", "fchmod", "fchmodat" ],
#         "action": "SCMP_ACT_ERRNO", "errnoRet": 1
#
#   errnoRet 1 == EPERM == "Operation not permitted". The symptom and the
#   configuration match exactly.
#
#   If the deny list had been long or obfuscated, the empirical route is:
#     - change that rule's "action" to "SCMP_ACT_LOG" (or set the whole file to
#       {"defaultAction":"SCMP_ACT_LOG"}), recreate the Pod, reproduce, then:
#         dmesg -T | grep -i seccomp | tail
#         type=SECCOMP audit(...): auid=... pid=... comm="chmod" ...
#                                  syscall=268 compat=0 ip=0x... code=0x50000
#         ausyscall 268
#           fchmodat
#     - `code=0x50000` is SECCOMP_RET_ERRNO; 0x7ffc0000 is ALLOW,
#       0x00000000 is KILL_THREAD, 0x80000000 is KILL_PROCESS (which shows up as
#       a container exiting with SIGSYS / exit code 159, with NO log line at all
#       — the hardest seccomp failure to diagnose, and the reason ERRNO is
#       preferred over KILL in profiles you have not fully validated).
#
# Fix — remove only the offending family, keep the rest of the deny list:
#
#   cat > /var/lib/kubelet/seccomp/profiles/shipper.json <<'EOF'
#   {
#     "defaultAction": "SCMP_ACT_ALLOW",
#     "syscalls": [
#       {
#         "names": [
#           "kexec_load", "kexec_file_load",
#           "init_module", "finit_module", "delete_module",
#           "bpf", "perf_event_open",
#           "ptrace", "process_vm_readv", "process_vm_writev",
#           "mount", "umount2", "pivot_root",
#           "reboot", "swapon", "swapoff"
#         ],
#         "action": "SCMP_ACT_ERRNO",
#         "errnoRet": 1
#       }
#     ]
#   }
#   EOF
#
#   # THE STEP EVERYONE MISSES: the filter is installed by runc immediately
#   # before execve() of the entrypoint. Editing the JSON has zero effect on a
#   # container that already exists. You must create a new container.
#   kubectl -n hardening-lab delete pod -l app=log-shipper
#   kubectl -n hardening-lab rollout status deploy/log-shipper
#   kubectl -n hardening-lab logs -l app=log-shipper --tail=3
#     (no chmod error; the pod stays Running with a stable restart count)
#
#   Confirm the remaining denials still bite:
#   kubectl -n hardening-lab exec deploy/log-shipper -- sh -c \
#     'cat /proc/1/status | grep Seccomp'
#     Seccomp:        2
#
# ---------------------------------------------------------------------------
# FINAL CHECK
# ---------------------------------------------------------------------------
#   kubectl -n hardening-lab get deploy
#     NAME          READY   UP-TO-DATE   AVAILABLE
#     audit-agent   1/1     1            1
#     log-shipper   1/1     1            1
#     secure-web    1/1     1            1
#
#   sudo ./<this-script> verify
#
# ---------------------------------------------------------------------------
# WHY THIS LAB IS SHAPED THIS WAY — production notes worth internalising
# ---------------------------------------------------------------------------
# 1. Both mechanisms are NODE-LOCAL prerequisites, not cluster objects.
#    An AppArmor Localhost profile must be in the node's kernel; a seccomp
#    Localhost profile must be a file under <kubelet-root-dir>/seccomp. A Pod
#    referencing either will pass admission on any cluster and then fail to
#    start on precisely the nodes that lack it. In a heterogeneous cluster this
#    presents as "the Deployment works until it lands on node-7". Fix the fleet,
#    not the Pod: config management, a privileged loader DaemonSet, or the
#    Security Profiles Operator (which reconciles SeccompProfile and
#    AppArmorProfile CRDs onto every node and garbage-collects them).
#
# 2. Profiles are applied at container CREATE time.
#    Editing a profile does nothing to running workloads; unloading one breaks
#    nothing until the next reschedule. Node drift is therefore a LATENT
#    outage — it detonates on the next reboot, eviction, scale-up or image
#    update, hours or weeks after the change. This is why the golden-image
#    scenario is realistic and why "it worked yesterday" is not evidence.
#
# 3. The two symptom classes, memorised:
#      CreateContainerError / RunContainerError + 'apparmor'/'seccomp' in the
#        event text  -> the profile could not be RESOLVED or APPLIED. The node
#        is missing something, or the path/name is wrong.
#      Container starts, then EPERM / "Operation not permitted", or dies with
#        SIGSYS and no message -> the profile WAS applied and is working as
#        written. The profile is wrong, not missing.
#
# 4. Field syntax for CKS 1.34 (annotations are gone; do not write them):
#      spec.securityContext.appArmorProfile.{type,localhostProfile}       (Pod)
#      spec.containers[].securityContext.appArmorProfile.{...}      (container)
#        type: RuntimeDefault | Localhost | Unconfined
#      spec.securityContext.seccompProfile.{type,localhostProfile}        (Pod)
#      spec.containers[].securityContext.seccompProfile.{...}       (container)
#        type: RuntimeDefault | Localhost | Unconfined
#      Container-level overrides Pod-level. localhostProfile is REQUIRED when
#      type is Localhost and FORBIDDEN otherwise.
#
# 5. Reach for RuntimeDefault first. The runtime's built-in seccomp profile
#    blocks ~44 syscalls of the ~350 available and breaks almost nothing; it is
#    a one-line change per workload with a fraction of the operational cost of a
#    bespoke profile. Enable it fleet-wide with the kubelet flag
#    `--seccomp-default=true` (KEP-2413, GA in 1.27) so unannotated Pods are
#    confined by default, and reserve custom Localhost profiles for the few
#    workloads that justify the maintenance. Pod Security Admission's
#    `restricted` level requires a seccompProfile of RuntimeDefault or Localhost
#    and forbids Unconfined — which is the enforcement lever that keeps someone
#    from "fixing" the next incident the way this lab's verifier refuses to
#    accept.
#
# 6. Portability traps that produce exactly these symptoms in real clusters:
#    - Adding "architectures": ["SCMP_ARCH_X86_64"] to a profile silently
#      disables the entire filter on arm64 nodes. Omit the key unless you need
#      multi-arch compat entries, and never assume a mixed-arch fleet is x86.
#    - Unknown syscall names in a profile are skipped with a warning by runc, so
#      a typo'd deny rule fails OPEN, not closed. Validate profiles in CI.
#    - AppArmor exists on Debian/Ubuntu/SUSE; RHEL-family nodes use SELinux and
#      will reject Localhost AppArmor profiles outright. Mixed-distro node pools
#      need seLinuxOptions on one side and appArmorProfile on the other.
#    - `deny /** w` style profiles interact badly with anything that writes at
#      startup (log files, PID files, tmp scratch). Always develop a profile in
#      complain mode (`aa-complain`) under real traffic before enforcing.