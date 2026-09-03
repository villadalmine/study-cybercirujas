#!/usr/bin/env bash
#
# ============================================================================
#  704.1 Cloud Native Security -- break & fix laboratory
#  LPI DevOps Tools Engineer, exam 701-100, syllabus version 2.0.0
#  Objective weight: 6.67
#  Objective source: https://www.lpi.org/our-certifications/exam-701-objectives/
# ============================================================================
#
#  WHAT THIS SCRIPT IS
#    A controlled failure injector plus a grader. It breaks three cloud native
#    security controls, prints the symptom you are about to see and the goal
#    you must reach, and then verifies your repair. It never tells you the root
#    cause at runtime -- the full solution is commented at the bottom of the
#    file, read it only after you have tried.
#
#    The pedagogical point of all three scenarios is the same one that shows up
#    in every real incident review: a security control that blocks a legitimate
#    workload has TWO fixes -- narrow the control, or delete the control. Only
#    the first one is a fix. The grader rejects the second one on purpose.
#
#  BLAST RADIUS (read this before running)
#    Creates ONLY:
#      - the directory /opt/lab-704-1 (all lab state, profiles and launchers)
#      - two containers named lab-704-1-keyserver / lab-704-1-edge
#      - two loopback-only published ports 127.0.0.1:18081 and 127.0.0.1:18082
#      - the Kubernetes namespace lab-704-1, if a cluster is reachable
#    It does NOT edit /etc, does NOT touch the host firewall, does NOT change
#    kernel sysctls, does NOT modify the container runtime configuration and
#    does NOT touch any container, namespace or file outside those names.
#    `restore` removes exactly what `break` created.
#
#  REQUIREMENTS
#    root, a DISPOSABLE lab VM, podman or docker, python3, curl, network access
#    to pull busybox. Kubernetes (k3s, kubeadm, minikube...) is optional: the
#    third scenario is skipped cleanly when no cluster answers.
#
#  USAGE
#    ./704.1-breakfix.sh break   [1|2|3|all]
#    ./704.1-breakfix.sh verify  [1|2|3|all]
#    ./704.1-breakfix.sh status
#    ./704.1-breakfix.sh restore
#
set -Eeuo pipefail

readonly LAB_ID="lab-704-1"
readonly LAB_DIR="/opt/lab-704-1"
readonly NS="lab-704-1"
readonly IMAGE="${LAB_IMAGE:-docker.io/library/busybox:1.36}"
readonly S1_CT="lab-704-1-keyserver"
readonly S2_CT="lab-704-1-edge"
readonly S1_PORT="18081"
readonly S2_PORT="18082"
readonly CONFIRM_TOKEN="I-AM-A-DISPOSABLE-LAB-VM"
readonly SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# Syscalls denied by the lab seccomp profile in scenario 1. Note that this list
# mixes genuinely dangerous syscalls with one family the workload needs. That is
# the fault, and finding it is the exercise.
readonly S1_DENIED=(add_key bpf chmod chroot fchmodat fchmodat2 init_module
                    kexec_load keyctl mount ptrace unshare)

RUNTIME=""
Z_SUFFIX=""
NNP_OPT=""
FAILS=0
CHECKS=0

C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
fi

log()  { printf '%s[ lab ]%s %s\n' "$C_B" "$C_0" "$*"; }
warn() { printf '%s[ warn ]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[ fail ]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$C_D" "----------------------------------------------------------------------" "$C_0"; }
section() { printf '\n%s== %s%s\n' "$C_B" "$*" "$C_0"; }
pass() { CHECKS=$((CHECKS+1)); printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$*"; }
fail() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*"; }
skip() { printf '  %sSKIP%s  %s\n' "$C_Y" "$C_0" "$*"; }

trap 'err "unexpected error at line ${LINENO} (command: ${BASH_COMMAND})"' ERR

# ---------------------------------------------------------------------------
# Safety and environment
# ---------------------------------------------------------------------------

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run me as root: sudo ${SELF} $*"
}

guard_lab_vm() {
  if [[ -e /etc/teach-plat-production ]]; then
    die "/etc/teach-plat-production exists -- this host is marked production. Refusing."
  fi
  if [[ "${LAB_CONFIRM:-}" == "${CONFIRM_TOKEN}" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "non-interactive run: export LAB_CONFIRM=${CONFIRM_TOKEN} to confirm this is a throwaway VM"
  fi
  hr
  printf '%sThis script injects real failures on THIS machine (%s).%s\n' "$C_Y" "$(hostname)" "$C_0"
  printf 'It only creates %s, the containers %s / %s and the namespace %s.\n' "$LAB_DIR" "$S1_CT" "$S2_CT" "$NS"
  printf 'Run it only on a disposable lab VM you can destroy.\n'
  hr
  local answer=""
  read -r -p "Type ${CONFIRM_TOKEN} to continue: " answer
  [[ "$answer" == "${CONFIRM_TOKEN}" ]] || die "not confirmed, nothing was changed"
}

detect_runtime() {
  if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
    NNP_OPT="--security-opt no-new-privileges"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
    NNP_OPT="--security-opt no-new-privileges:true"
  else
    die "neither podman nor docker found"
  fi
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    Z_SUFFIX=":Z"
  fi
}

preflight() {
  detect_runtime
  command -v python3 >/dev/null 2>&1 || die "python3 is required (JSON handling and grading)"
  command -v curl    >/dev/null 2>&1 || die "curl is required"
  if [[ "$RUNTIME" == "docker" ]] && ! docker info >/dev/null 2>&1; then
    die "the docker daemon is not answering"
  fi
  log "container runtime: ${RUNTIME}   SELinux relabel: ${Z_SUFFIX:-off}"
  if ! "$RUNTIME" image exists "$IMAGE" >/dev/null 2>&1 && \
     ! "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
    log "pulling ${IMAGE} ..."
    "$RUNTIME" pull "$IMAGE" >/dev/null || die "cannot pull ${IMAGE} -- check egress from this VM"
  fi
  local p
  for p in "$S1_PORT" "$S2_PORT"; do
    if ss -lnt 2>/dev/null | grep -q ":${p} "; then
      die "127.0.0.1:${p} is already in use -- free it or the lab cannot publish its workloads"
    fi
  done
}

kube_env() {
  if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi
}

kube_available() {
  command -v kubectl >/dev/null 2>&1 || return 1
  kube_env
  kubectl --request-timeout=10s get --raw='/readyz' >/dev/null 2>&1
}

ct_exists()  { "$RUNTIME" inspect "$1" >/dev/null 2>&1; }
ct_running() { [[ "$("$RUNTIME" inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]; }

# ---------------------------------------------------------------------------
# Scenario 1 -- seccomp: a syscall filter that also filters the application
# ---------------------------------------------------------------------------

write_seccomp_profile() {
  local out="$1"; shift
  python3 - "$out" "$@" <<'PY'
import json, sys
out, denied = sys.argv[1], sorted(set(sys.argv[2:]))
profile = {
    "defaultAction": "SCMP_ACT_ALLOW",
    "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32",
                      "SCMP_ARCH_AARCH64", "SCMP_ARCH_ARM"],
    "syscalls": [{"names": denied, "action": "SCMP_ACT_ERRNO", "errnoRet": 1}],
}
with open(out, "w") as fh:
    fh.write(json.dumps(profile, indent=2) + "\n")
PY
}

profile_loads() {
  "$RUNTIME" run --rm --security-opt seccomp="$1" "$IMAGE" true >/dev/null 2>&1
}

# Runs a shell snippet under the given profile. Exit status is the snippet's.
probe_under_profile() {
  "$RUNTIME" run --rm --security-opt seccomp="$1" "$IMAGE" sh -c "$2" >/dev/null 2>&1
}

break_s1() {
  section "Scenario 1 -- injecting"
  install -d -m 0755 "${LAB_DIR}/s1/data" "${LAB_DIR}/s1/www"
  printf 'lab-fake-api-key-not-a-real-secret\n' > "${LAB_DIR}/s1/data/app.key"
  chmod 0644 "${LAB_DIR}/s1/data/app.key"
  printf '<h1>keyserver</h1>\n' > "${LAB_DIR}/s1/www/index.html"
  chmod 0644 "${LAB_DIR}/s1/www/index.html"

  local denied=("${S1_DENIED[@]}")
  write_seccomp_profile "${LAB_DIR}/s1/seccomp.json" "${denied[@]}"
  if ! profile_loads "${LAB_DIR}/s1/seccomp.json"; then
    # Older libseccomp versions do not know fchmodat2 and reject the profile.
    warn "profile rejected by libseccomp, retrying without fchmodat2"
    denied=("${denied[@]/fchmodat2}")
    write_seccomp_profile "${LAB_DIR}/s1/seccomp.json" "${denied[@]}"
    profile_loads "${LAB_DIR}/s1/seccomp.json" || die "this runtime will not load the lab seccomp profile"
  fi

  cat > "${LAB_DIR}/s1/run.sh" <<EOF
#!/usr/bin/env bash
# Recreate the scenario 1 workload.
#
# IMPORTANT: the runtime snapshots the seccomp profile when the container is
# CREATED. Editing seccomp.json and running "${RUNTIME} restart" changes nothing.
# Edit the profile, then re-run THIS script.
set -Eeuo pipefail
${RUNTIME} rm -f ${S1_CT} >/dev/null 2>&1 || true
exec ${RUNTIME} run -d --name ${S1_CT} \\
  --restart=on-failure:5 \\
  --security-opt seccomp=${LAB_DIR}/s1/seccomp.json \\
  -v ${LAB_DIR}/s1/data:/data${Z_SUFFIX} \\
  -v ${LAB_DIR}/s1/www:/www${Z_SUFFIX} \\
  -p 127.0.0.1:${S1_PORT}:8080 \\
  ${IMAGE} \\
  sh -c 'set -e; echo "[entrypoint] hardening /data/app.key"; chmod 0600 /data/app.key; echo "[entrypoint] serving on :8080"; exec httpd -f -v -p 8080 -h /www'
EOF
  chmod 0755 "${LAB_DIR}/s1/run.sh"
  "${LAB_DIR}/s1/run.sh" >/dev/null
  sleep 3
  log "workload ${S1_CT} created"
}

verify_s1() {
  section "Scenario 1 -- grading"
  local prof="${LAB_DIR}/s1/seccomp.json"
  if [[ ! -f "$prof" ]]; then
    fail "${prof} is gone -- deleting the profile is not a fix, restore it and narrow it"
    return
  fi

  if ct_running "$S1_CT"; then
    pass "container ${S1_CT} is running"
  else
    fail "container ${S1_CT} is not running ($("$RUNTIME" inspect -f '{{.State.Status}}' "$S1_CT" 2>/dev/null || echo absent))"
  fi

  if curl -fsS --max-time 5 "http://127.0.0.1:${S1_PORT}/" >/dev/null 2>&1; then
    pass "workload answers on http://127.0.0.1:${S1_PORT}/"
  else
    fail "workload does not answer on http://127.0.0.1:${S1_PORT}/"
  fi

  local perms
  perms="$(stat -c '%a' "${LAB_DIR}/s1/data/app.key" 2>/dev/null || echo '???')"
  if [[ "$perms" == "600" ]]; then
    pass "the entrypoint completed its chmod (app.key is 0600)"
  else
    fail "app.key is ${perms}, expected 600 -- the entrypoint still cannot harden it"
  fi

  local secopts
  secopts="$("$RUNTIME" inspect -f '{{.HostConfig.SecurityOpt}}' "$S1_CT" 2>/dev/null || true)"
  if grep -qi 'unconfined' <<<"$secopts"; then
    fail "the container runs with seccomp=unconfined -- that removes the control instead of fixing it"
  elif grep -qi 'seccomp' <<<"$secopts"; then
    pass "a seccomp profile is still applied to the container"
  else
    warn "cannot read the applied profile from inspect; grading the on-disk profile only"
  fi

  if probe_under_profile "$prof" 'touch /tmp/probe && chmod 0600 /tmp/probe'; then
    pass "the profile now permits the chmod family"
  else
    fail "the profile still blocks the chmod family"
  fi

  if probe_under_profile "$prof" 'chroot / /bin/true'; then
    fail "the profile no longer blocks chroot -- you widened it too far, deny what the app does not use"
  else
    pass "the profile still blocks chroot (the filter was narrowed, not disabled)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 2 -- capabilities: a rootless container that wants a low port
# ---------------------------------------------------------------------------

break_s2() {
  section "Scenario 2 -- injecting"
  install -d -m 0755 "${LAB_DIR}/s2/www"
  printf '<h1>edge</h1>\n' > "${LAB_DIR}/s2/www/index.html"
  chmod 0644 "${LAB_DIR}/s2/www/index.html"

  cat > "${LAB_DIR}/s2/run.sh" <<EOF
#!/usr/bin/env bash
# Recreate the scenario 2 workload. Edit the flags below, then re-run.
# Hard requirements you may NOT relax: the container stays non-root, keeps
# --cap-drop=ALL and never becomes --privileged.
set -Eeuo pipefail
${RUNTIME} rm -f ${S2_CT} >/dev/null 2>&1 || true
exec ${RUNTIME} run -d --name ${S2_CT} \\
  --restart=on-failure:5 \\
  --user 10001:10001 \\
  --cap-drop=ALL \\
  ${NNP_OPT} \\
  -v ${LAB_DIR}/s2/www:/www${Z_SUFFIX} \\
  -p 127.0.0.1:${S2_PORT}:80 \\
  ${IMAGE} \\
  httpd -f -v -p 80 -h /www
EOF
  chmod 0755 "${LAB_DIR}/s2/run.sh"
  "${LAB_DIR}/s2/run.sh" >/dev/null
  sleep 3
  log "workload ${S2_CT} created"
}

verify_s2() {
  section "Scenario 2 -- grading"
  if ct_running "$S2_CT"; then
    pass "container ${S2_CT} is running"
  else
    fail "container ${S2_CT} is not running ($("$RUNTIME" inspect -f '{{.State.Status}}' "$S2_CT" 2>/dev/null || echo absent))"
  fi

  if curl -fsS --max-time 5 "http://127.0.0.1:${S2_PORT}/" >/dev/null 2>&1; then
    pass "the edge service answers on http://127.0.0.1:${S2_PORT}/"
  else
    fail "the edge service does not answer on http://127.0.0.1:${S2_PORT}/"
  fi

  local user priv
  user="$("$RUNTIME" inspect -f '{{.Config.User}}' "$S2_CT" 2>/dev/null || echo '')"
  case "$user" in
    ""|root|0|0:0) fail "the container runs as root (User='${user}') -- running as root is not a fix" ;;
    *)             pass "the container still runs as a non-root UID (User=${user})" ;;
  esac

  priv="$("$RUNTIME" inspect -f '{{.HostConfig.Privileged}}' "$S2_CT" 2>/dev/null || echo unknown)"
  if [[ "$priv" == "true" ]]; then
    fail "the container is --privileged -- that grants every capability to solve a one-port problem"
  else
    pass "the container is not privileged"
  fi

  local capeff
  capeff="$("$RUNTIME" exec "$S2_CT" cat /proc/1/status 2>/dev/null | awk '/^CapEff:/{print $2}' || true)"
  if [[ -z "$capeff" ]]; then
    skip "cannot read /proc/1/status (container not running)"
  elif (( 0x${capeff} & (1 << 21) )); then
    fail "PID 1 holds CAP_SYS_ADMIN (CapEff=${capeff}) -- far more than binding a port needs"
  else
    pass "PID 1 does not hold CAP_SYS_ADMIN (CapEff=${capeff})"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 3 -- Kubernetes: Pod Security admission + default-deny egress
# ---------------------------------------------------------------------------

break_s3() {
  section "Scenario 3 -- injecting"
  if ! kube_available; then
    skip "no Kubernetes API answers -- scenario 3 not injected"
    return 0
  fi
  install -d -m 0755 "${LAB_DIR}/s3"
  cat > "${LAB_DIR}/s3/manifests.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: ${NS}
  labels:
    app: orders-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
    spec:
      automountServiceAccountToken: false
      containers:
        - name: app
          image: ${IMAGE}
          command: ["/bin/sh", "-c"]
          args:
            - |
              until nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; do
                echo "[app] cluster DNS unreachable"
                sleep 5
              done
              touch /tmp/ready
              echo "[app] ready"
              exec sleep 86400
          readinessProbe:
            exec:
              command: ["cat", "/tmp/ready"]
            initialDelaySeconds: 5
            periodSeconds: 5
EOF
  kubectl apply -f "${LAB_DIR}/s3/manifests.yaml" >/dev/null
  log "namespace ${NS} created and workload applied"
}

verify_s3() {
  section "Scenario 3 -- grading"
  if ! kube_available; then
    skip "no Kubernetes API answers -- scenario 3 not graded"
    return 0
  fi
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    fail "namespace ${NS} does not exist -- deleting the namespace is not a fix"
    return
  fi

  local enforce
  enforce="$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
  if [[ "$enforce" == "restricted" ]]; then
    pass "the namespace still enforces the restricted Pod Security Standard"
  else
    fail "enforce label is '${enforce:-<none>}' -- lowering admission is not a fix"
  fi

  if kubectl -n "$NS" get deploy orders-api -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
spec = d["spec"]["template"]["spec"]
pod = spec.get("securityContext") or {}
c = spec["containers"][0]
cs = c.get("securityContext") or {}
missing = []
if (cs.get("runAsNonRoot", pod.get("runAsNonRoot"))) is not True:
    missing.append("runAsNonRoot=true")
if cs.get("allowPrivilegeEscalation") is not False:
    missing.append("allowPrivilegeEscalation=false")
drops = [x.upper() for x in ((cs.get("capabilities") or {}).get("drop") or [])]
if "ALL" not in drops:
    missing.append("capabilities.drop=[ALL]")
sp = (cs.get("seccompProfile") or pod.get("seccompProfile") or {}).get("type")
if sp not in ("RuntimeDefault", "Localhost"):
    missing.append("seccompProfile.type=RuntimeDefault")
if missing:
    sys.stderr.write("        missing: " + ", ".join(missing) + "\n")
    sys.exit(1)
'; then
    pass "the pod template satisfies the restricted profile"
  else
    fail "the pod template still violates the restricted profile (see missing fields above)"
  fi

  local avail
  avail="$(kubectl -n "$NS" get deploy orders-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [[ "${avail:-0}" -ge 1 ]]; then
    pass "deployment orders-api has ${avail} available replica(s)"
  else
    fail "deployment orders-api has no available replica"
  fi

  if kubectl -n "$NS" get networkpolicy -o json 2>/dev/null | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
deny = [p for p in items
        if not (p["spec"].get("podSelector") or {})
        and set(p["spec"].get("policyTypes") or []) >= {"Ingress", "Egress"}]
dns = []
for p in items:
    for rule in (p["spec"].get("egress") or []):
        for port in (rule.get("ports") or []):
            if str(port.get("port")) in ("53", "dns", "dns-tcp"):
                dns.append(p["metadata"]["name"])
problems = []
if not deny:
    problems.append("no default-deny policy (empty podSelector, Ingress+Egress) left in the namespace")
if not dns:
    problems.append("no policy grants egress to port 53")
if problems:
    sys.stderr.write("        " + "; ".join(problems) + "\n")
    sys.exit(1)
'; then
    pass "default-deny is intact and a narrow DNS egress exception exists"
  else
    fail "network policy state is wrong (see above) -- keep default-deny, add an exception"
  fi
}

# ---------------------------------------------------------------------------
# Briefings
# ---------------------------------------------------------------------------

briefing_s1() {
  cat <<EOF

${C_B}SCENARIO 1 -- the key server will not stay up${C_0}
  Workload : container ${S1_CT}, published on 127.0.0.1:${S1_PORT}
  Symptom  : the container never reaches a steady running state. It exits with
             status 1 a few seconds after every start, retries and finally
             stops as "Exited (1)". Its log ends on a permission error while
             the entrypoint is still preparing the filesystem, before the HTTP
             server is ever started. curl to the published port is refused.
  Goal     : the container runs, http://127.0.0.1:${S1_PORT}/ answers, and
             ${LAB_DIR}/s1/data/app.key ends up with mode 0600 -- WITHOUT
             disabling the confinement that is causing the failure.
  Forbidden: seccomp=unconfined, deleting the profile, --privileged.
  Start at : ${RUNTIME} ps -a --filter name=${S1_CT}
             ${RUNTIME} logs ${S1_CT}
             ${RUNTIME} inspect ${S1_CT} --format '{{.HostConfig.SecurityOpt}}'
  Note     : the launcher is ${LAB_DIR}/s1/run.sh -- read its header, it tells
             you why "restart" is not enough after a config change.
EOF
}

briefing_s2() {
  cat <<EOF

${C_B}SCENARIO 2 -- the edge service cannot open its socket${C_0}
  Workload : container ${S2_CT}, published on 127.0.0.1:${S2_PORT}
  Symptom  : the container exits immediately. Its log contains a single line
             about "Permission denied" while the HTTP server tries to open its
             listening socket. No process, no port, no service.
  Goal     : http://127.0.0.1:${S2_PORT}/ answers, while the container keeps
             running as UID 10001 with --cap-drop=ALL and stays unprivileged.
  Forbidden: --user root/0, --privileged, --cap-add=SYS_ADMIN, removing
             --cap-drop=ALL, changing host sysctls.
  Start at : ${RUNTIME} logs ${S2_CT}
             ${RUNTIME} inspect ${S2_CT} --format '{{.Config.User}} {{.HostConfig.CapDrop}}'
             cat ${LAB_DIR}/s2/run.sh
  Think    : which capability governs the operation that failed, and whether a
             capability is the cheapest way to make this particular need go away.
EOF
}

briefing_s3() {
  cat <<EOF

${C_B}SCENARIO 3 -- orders-api never becomes available${C_0}
  Workload : Deployment orders-api in namespace ${NS}
  Symptom  : two failures, one after the other.
             (a) "kubectl -n ${NS} get deploy" shows 0/1 and there is NO pod at
                 all -- not Pending, not CrashLoopBackOff, absent. The
                 ReplicaSet keeps emitting FailedCreate events.
             (b) once pods are created, the container logs repeat that cluster
                 DNS is unreachable and the readiness probe never succeeds.
  Goal     : the deployment reports at least one available replica, the
             namespace still enforces the restricted Pod Security Standard, the
             default-deny NetworkPolicy is still there, and the only thing you
             added is a narrow exception.
  Forbidden: relabelling the namespace to baseline/privileged, deleting the
             namespace, deleting default-deny.
  Start at : kubectl -n ${NS} get deploy,rs,pod
             kubectl -n ${NS} describe rs -l app=orders-api | tail -20
             kubectl -n ${NS} get events --sort-by=.lastTimestamp | tail -20
             kubectl -n ${NS} get netpol -o yaml
  Note     : if your CNI plugin does not enforce NetworkPolicy, symptom (b)
             will not appear -- the exception is still graded, because writing
             it is the exercise.
EOF
}

briefing() {
  hr
  printf '%s704.1 Cloud Native Security -- break & fix%s\n' "$C_B" "$C_0"
  printf 'Grade your work with:  %s verify all\n' "$SELF"
  printf 'Clean the VM with   :  %s restore\n' "$SELF"
  hr
}

# ---------------------------------------------------------------------------
# status / restore / dispatch
# ---------------------------------------------------------------------------

do_status() {
  detect_runtime
  section "containers"
  "$RUNTIME" ps -a --filter "name=${LAB_ID}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
  section "endpoints"
  local p
  for p in "$S1_PORT" "$S2_PORT"; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${p}/" >/dev/null 2>&1; then
      printf '  127.0.0.1:%s  %sup%s\n' "$p" "$C_G" "$C_0"
    else
      printf '  127.0.0.1:%s  %sdown%s\n' "$p" "$C_R" "$C_0"
    fi
  done
  section "kubernetes"
  if kube_available && kubectl get ns "$NS" >/dev/null 2>&1; then
    kubectl -n "$NS" get deploy,pod,netpol 2>/dev/null || true
  else
    printf '  no lab namespace (cluster unreachable or scenario 3 not injected)\n'
  fi
}

do_restore() {
  require_root
  detect_runtime
  section "restore"
  local ct
  for ct in "$S1_CT" "$S2_CT"; do
    if ct_exists "$ct"; then
      "$RUNTIME" rm -f "$ct" >/dev/null 2>&1 || true
      log "removed container ${ct}"
    fi
  done
  if kube_available && kubectl get ns "$NS" >/dev/null 2>&1; then
    kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true
    log "namespace ${NS} deletion requested"
  fi
  if [[ "$LAB_DIR" == "/opt/lab-704-1" && -d "$LAB_DIR" ]]; then
    rm -rf -- "$LAB_DIR"
    log "removed ${LAB_DIR}"
  fi
  log "the lab image (${IMAGE}) was left in place; remove it with '${RUNTIME} rmi ${IMAGE}' if you want"
  ok_msg="host is back to its pre-lab state"
  log "$ok_msg"
}

usage() {
  cat <<EOF
704.1 Cloud Native Security -- break & fix

  ${SELF} break   [1|2|3|all]   inject the failure(s)      (root, confirmation)
  ${SELF} verify  [1|2|3|all]   grade your repair          (exit 0 = all pass)
  ${SELF} status                show current lab state
  ${SELF} restore               remove everything the lab created
  ${SELF} help                  this text

Environment:
  LAB_CONFIRM=${CONFIRM_TOKEN}   skip the interactive confirmation
  LAB_IMAGE=<ref>                  override the busybox image reference
EOF
}

main() {
  local cmd="${1:-help}" target="${2:-all}"
  case "$cmd" in
    break)
      require_root "$@"
      guard_lab_vm
      preflight
      case "$target" in
        1)   break_s1 ;;
        2)   break_s2 ;;
        3)   break_s3 ;;
        all) break_s1; break_s2; break_s3 ;;
        *)   die "unknown scenario '${target}'" ;;
      esac
      briefing
      [[ "$target" == "1" || "$target" == "all" ]] && briefing_s1
      [[ "$target" == "2" || "$target" == "all" ]] && briefing_s2
      [[ "$target" == "3" || "$target" == "all" ]] && briefing_s3
      printf '\n'
      ;;
    verify)
      require_root "$@"
      detect_runtime
      case "$target" in
        1)   verify_s1 ;;
        2)   verify_s2 ;;
        3)   verify_s3 ;;
        all) verify_s1; verify_s2; verify_s3 ;;
        *)   die "unknown scenario '${target}'" ;;
      esac
      printf '\n'
      if [[ "$FAILS" -eq 0 ]]; then
        printf '%s%d/%d checks passed -- controls kept, workload healthy.%s\n' \
          "$C_G" "$((CHECKS - FAILS))" "$CHECKS" "$C_0"
        exit 0
      fi
      printf '%s%d of %d checks failed -- keep going (solution is at the bottom of %s).%s\n' \
        "$C_R" "$FAILS" "$CHECKS" "$(basename "$SELF")" "$C_0"
      exit 1
      ;;
    status)  do_status ;;
    restore) do_restore ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
exit $?

# ============================================================================
#                          S O L U T I O N
#            stop here until you have tried and run "verify all"
# ============================================================================
#
# ----------------------------------------------------------------------------
# SCENARIO 1 -- seccomp profile that denies a syscall the application needs
# ----------------------------------------------------------------------------
#
# 1. Read the symptom, do not guess it.
#
#    # podman ps -a --filter name=lab-704-1-keyserver
#    CONTAINER ID  IMAGE                           COMMAND     STATUS
#    3f1c2b9a4d7e  docker.io/library/busybox:1.36  sh -c se...  Exited (1) 5 seconds ago
#
#    # podman logs lab-704-1-keyserver
#    [entrypoint] hardening /data/app.key
#    chmod: /data/app.key: Operation not permitted
#
#    "Operation not permitted" is EPERM. Note what it is NOT: the entrypoint runs
#    as root inside the container, the bind mount is writable on the host, and
#    the message appears before httpd starts. Root + EPERM on a plain chmod is
#    the signature of a kernel-side restriction, not of file permissions.
#    The three usual suspects, in order of likelihood: seccomp, LSM (SELinux/
#    AppArmor), capabilities. Here there is no capability involved (chmod on a
#    file you own needs none) and SELinux denials land in the audit log:
#
#    # ausearch -m AVC -ts recent        # empty -> not SELinux
#
# 2. Confirm the hypothesis WITHOUT calling that confirmation a fix.
#
#    # podman run --rm --security-opt seccomp=unconfined \
#        -v /opt/lab-704-1/s1/data:/data:Z docker.io/library/busybox:1.36 \
#        chmod 0600 /data/app.key && echo "seccomp was the blocker"
#    seccomp was the blocker
#
#    This is a diagnostic, and it is the exact command that must never reach the
#    production launcher. Leaving it there is how "we hardened the fleet" becomes
#    "one workload runs with the syscall filter off and nobody remembers why".
#
# 3. Find which filter is applied and read it.
#
#    # podman inspect lab-704-1-keyserver --format '{{.HostConfig.SecurityOpt}}'
#    [seccomp=/opt/lab-704-1/s1/seccomp.json]
#
#    # jq '.defaultAction, .syscalls[0].action, .syscalls[0].names' \
#        /opt/lab-704-1/s1/seccomp.json
#    "SCMP_ACT_ALLOW"
#    "SCMP_ACT_ERRNO"
#    ["add_key","bpf","chmod","chroot","fchmodat","fchmodat2","init_module",
#     "kexec_load","keyctl","mount","ptrace","unshare"]
#
#    There it is: the blocklist mixes syscalls no application should ever need
#    (init_module, kexec_load, bpf, keyctl, add_key) with the chmod family,
#    which this application does need. Somebody copied a hardening list without
#    profiling the workload.
#
# 4. Narrow the filter -- remove exactly the three chmod-family entries.
#
#    # cd /opt/lab-704-1/s1
#    # cp seccomp.json seccomp.json.bak
#    # jq '.syscalls[0].names |= map(select(. != "chmod" and . != "fchmodat" and . != "fchmodat2"))' \
#        seccomp.json.bak > seccomp.json
#    # jq -e '.syscalls[0].names | index("mount") and index("ptrace")' seccomp.json
#
#    Why all three names: glibc/musl route chmod(2) through fchmodat(2), and
#    kernels >= 6.6 add fchmodat2(2). Filtering by syscall means filtering every
#    entry point the libc may choose, which is also why an allowlist written from
#    documentation instead of from a recording is always incomplete.
#
# 5. RECREATE the container -- restarting is not enough.
#
#    # /opt/lab-704-1/s1/run.sh
#    # podman logs lab-704-1-keyserver
#    [entrypoint] hardening /data/app.key
#    [entrypoint] serving on :8080
#    # curl -s http://127.0.0.1:18081/
#    <h1>keyserver</h1>
#    # stat -c '%a' /opt/lab-704-1/s1/data/app.key
#    600
#
#    Both podman and docker resolve and snapshot the profile at container
#    CREATE time and store it in the container configuration; "restart" replays
#    the stored spec and never re-reads the file. In Kubernetes the equivalent
#    trap is a Localhost seccomp profile: changing the file on the node does
#    nothing until the pod is recreated.
#
# 6. Production posture (what this lab deliberately is not).
#
#    The lab profile is defaultAction SCMP_ACT_ALLOW + a small blocklist, chosen
#    so the failure is deterministic and readable. Real profiles are the
#    opposite: defaultAction SCMP_ACT_ERRNO with an explicit allowlist -- deny by
#    default, so a syscall added by a future library version is blocked instead
#    of silently permitted. Start from the runtime default rather than from
#    scratch (podman: /usr/share/containers/seccomp.json; docker ships the moby
#    default profile), record what the workload actually calls with the OCI
#    seccomp BPF hook or Inspektor Gadget, and distribute profiles to nodes with
#    the Security Profiles Operator instead of copying JSON by hand.
#    Reference: https://docs.docker.com/engine/security/seccomp/
#               https://kubernetes.io/docs/tutorials/security/seccomp/
#
# ----------------------------------------------------------------------------
# SCENARIO 2 -- capabilities: a low port in a container with no capabilities
# ----------------------------------------------------------------------------
#
# 1. Symptom.
#
#    # podman logs lab-704-1-edge
#    httpd: bind: Permission denied
#
#    # podman inspect lab-704-1-edge --format '{{.Config.User}} {{.HostConfig.CapDrop}}'
#    10001:10001 [ALL]
#
#    Binding a TCP port below 1024 requires CAP_NET_BIND_SERVICE in the process's
#    effective set. The container runs as UID 10001 with every capability
#    dropped, and the launcher asks httpd for port 80. Two facts, one conclusion.
#    Reference: https://man7.org/linux/man-pages/man7/capabilities.7.html
#
# 2. The three candidate fixes, and why only one of them is right.
#
#    a) --privileged. Grants the full capability set, disables the default
#       seccomp filter and relaxes device access, to solve a single-port problem.
#       Rejected on sight in review.
#
#    b) --cap-add=NET_BIND_SERVICE. Minimal in intent, but runtime-dependent
#       when the container runs as a non-root UID: a capability only survives
#       execve for a non-root process if it is in the AMBIENT set. Podman raises
#       the ambient set for --cap-add; Docker does not, so on Docker this "fix"
#       reproduces the same EPERM and sends you on a second debugging round.
#       Portable only if you also control which runtime executes the pod.
#
#    c) Do not need the capability. Bind an unprivileged port inside the
#       container and let the publish/Service layer present :80 to clients. The
#       capability set stays empty, the fix works identically on both runtimes,
#       and it is the same shape as a Kubernetes Service targeting containerPort
#       8080 while exposing port 80.
#
#    Take (c).
#
# 3. Apply it -- edit /opt/lab-704-1/s2/run.sh:
#
#      -  -p 127.0.0.1:18082:80 \
#      +  -p 127.0.0.1:18082:8080 \
#         ...
#      -  httpd -f -v -p 80 -h /www
#      +  httpd -f -v -p 8080 -h /www
#
#    Keep --user 10001:10001, --cap-drop=ALL and no-new-privileges exactly as
#    they are. Then:
#
#    # /opt/lab-704-1/s2/run.sh
#    # curl -s http://127.0.0.1:18082/
#    <h1>edge</h1>
#    # podman exec lab-704-1-edge grep ^CapEff /proc/1/status
#    CapEff: 0000000000000000
#
#    A zero effective set is the number to aim for: the workload proves it needs
#    no kernel privilege at all. In a Pod spec the same posture reads
#    securityContext: {runAsNonRoot: true, runAsUser: 10001,
#    allowPrivilegeEscalation: false, capabilities: {drop: [ALL]},
#    seccompProfile: {type: RuntimeDefault}, readOnlyRootFilesystem: true}.
#
#    (For completeness: net.ipv4.ip_unprivileged_port_start would also "solve"
#    it, but it is a host-wide kernel setting changed to accommodate one
#    container. In Kubernetes it is a per-pod safe sysctl, which is acceptable;
#    on a shared node, lowering it globally is not.)
#
# ----------------------------------------------------------------------------
# SCENARIO 3 -- Pod Security admission, then default-deny egress
# ----------------------------------------------------------------------------
#
# 1. No pods at all means the failure happened before scheduling: admission.
#
#    # kubectl -n lab-704-1 get deploy,rs,pod
#    NAME                         READY   UP-TO-DATE   AVAILABLE
#    deployment.apps/orders-api   0/1     0            0
#    NAME                                    DESIRED   CURRENT   READY
#    replicaset.apps/orders-api-6b9f7c4d58   1         0         0
#    No resources found for pods.
#
#    # kubectl -n lab-704-1 describe rs -l app=orders-api | tail -5
#    Warning  FailedCreate  ... Error creating: pods "orders-api-6b9f7c4d58-" is
#    forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation
#    != false (container "app" must set securityContext.allowPrivilegeEscalation=false),
#    unrestricted capabilities (container "app" must set
#    securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true,
#    seccompProfile (pod or container must set securityContext.seccompProfile.type
#    to "RuntimeDefault" or "Localhost")
#
#    The API server told you the four missing fields. Relabelling the namespace
#    to baseline would also make the message disappear; it is the same mistake as
#    seccomp=unconfined, one abstraction layer higher.
#    Reference: https://kubernetes.io/docs/concepts/security/pod-security-standards/
#               https://kubernetes.io/docs/concepts/security/pod-security-admission/
#
# 2. Fix the workload, not the policy.
#
#    # kubectl -n lab-704-1 patch deploy orders-api --type=strategic -p '
#    spec:
#      template:
#        spec:
#          securityContext:
#            runAsNonRoot: true
#            runAsUser: 10001
#            seccompProfile:
#              type: RuntimeDefault
#          containers:
#            - name: app
#              securityContext:
#                allowPrivilegeEscalation: false
#                capabilities:
#                  drop: ["ALL"]
#    '
#
#    runAsUser must be non-zero: runAsNonRoot is checked by the kubelet against
#    the effective UID, and a busybox image whose USER is root fails at startup
#    with CreateContainerConfigError if you only set the flag.
#
# 3. Second symptom, second control.
#
#    # kubectl -n lab-704-1 logs -l app=orders-api --tail=3
#    [app] cluster DNS unreachable
#    [app] cluster DNS unreachable
#
#    # kubectl -n lab-704-1 get netpol default-deny -o jsonpath='{.spec.policyTypes}'
#    ["Ingress","Egress"]
#
#    A NetworkPolicy with an empty podSelector and Egress in policyTypes denies
#    ALL egress from every pod in the namespace, DNS included. This is the single
#    most common cause of "my pod cannot resolve anything" after a team turns on
#    default-deny: they think about the application traffic and forget that name
#    resolution is traffic too.
#
#    Do not delete default-deny. Add the narrowest exception:
#
#    # kubectl apply -f - <<'YAML'
#    apiVersion: networking.k8s.io/v1
#    kind: NetworkPolicy
#    metadata:
#      name: allow-dns-egress
#      namespace: lab-704-1
#    spec:
#      podSelector: {}
#      policyTypes: ["Egress"]
#      egress:
#        - to:
#            - namespaceSelector:
#                matchLabels:
#                  kubernetes.io/metadata.name: kube-system
#              podSelector:
#                matchLabels:
#                  k8s-app: kube-dns
#          ports:
#            - protocol: UDP
#              port: 53
#            - protocol: TCP
#              port: 53
#    YAML
#
#    NetworkPolicies are additive and purely allow-based: this one does not
#    "override" default-deny, it unions one destination into the allowed set.
#    Adjust the podSelector label if your cluster labels CoreDNS differently
#    (k3s and kubeadm use k8s-app=kube-dns; check with
#    "kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels").
#
#    # kubectl -n lab-704-1 rollout status deploy/orders-api
#    deployment "orders-api" successfully rolled out
#
#    Reference: https://kubernetes.io/docs/concepts/services-networking/network-policies/
#
# 4. Caveat worth carrying to production: NetworkPolicy is enforced by the CNI
#    plugin, not by the API server. The object is accepted on any cluster; on a
#    cluster whose plugin ignores it (plain flannel, for example) it is a
#    comment. Verify enforcement empirically -- exec into a pod, try the traffic,
#    and only then claim the namespace is isolated.
#
# ----------------------------------------------------------------------------
# CLEAN UP
#   ./704.1-breakfix.sh restore
#
# WHAT TO CARRY OUT OF THIS LAB
#   Every scenario had a one-command "fix" that removed the control
#   (seccomp=unconfined, --privileged, enforce=baseline, delete the netpol) and a
#   slightly longer fix that narrowed it. The difference between the two is the
#   entire job. When a security control breaks a workload, the deliverable is
#   the smallest exception that names exactly what the workload needs -- and the
#   exception is reviewable evidence, which "unconfined" never is.
# ============================================================================