#!/usr/bin/env bash
#
# ============================================================================
#  CNPA — Cloud Native Platform Engineering Associate
#  Exam version: 2025-04-01
#  Domain 2.4 — Kubernetes Security Essentials and Hardening  (weight 4.0)
#
#  BREAK & FIX LAB:  Pod Security Admission (restricted) rejects a workload
# ----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES
#    It hardens a namespace with the built-in Pod Security Admission (PSA)
#    controller at the `restricted` level, then deploys a perfectly ordinary
#    Deployment that does NOT meet that standard. The API server admits the
#    Deployment object, but the ReplicaSet controller cannot create any Pod:
#    every Pod is rejected at admission time. You get a Deployment that is
#    stuck at 0 replicas with no obvious crash — a very common real-world
#    "I hardened the cluster and now nothing schedules" incident.
#
#  WHY IT IS SAFE
#    - Everything lives in a single throwaway namespace: cnpa-lab-24
#    - It changes NO cluster-wide object, NO RBAC, NO node, NO CNI.
#    - It refuses to run against a context whose name looks like production.
#    - `--cleanup` deletes the namespace and returns the VM to its prior state.
#    Run it ONLY on a disposable single-node lab (kind / minikube / k3s).
#
#  OFFICIAL SOURCES
#    Pod Security Standards
#      https://kubernetes.io/docs/concepts/security/pod-security-standards/
#    Pod Security Admission (enforce/audit/warn)
#      https://kubernetes.io/docs/concepts/security/pod-security-admission/
#    Enforce a standard with namespace labels
#      https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
#    SecurityContext for a Pod/Container
#      https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
#    CNPA curriculum
#      https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ============================================================================

set -euo pipefail

NS="cnpa-lab-24"
DEPLOY="hardening-victim"
PSA_LEVEL="restricted"
PSA_VERSION="latest"   # pin to e.g. v1.30 in production to avoid silent drift

# --- pretty output (degrades cleanly when stdout is not a TTY) ---------------
if [[ -t 1 ]]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"
  GRN="$(printf '\033[32m')"; YLW="$(printf '\033[33m')"
  CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YLW=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "${*}"; }
head() { printf '\n%s%s%s\n' "${BOLD}${CYN}" "${*}" "${RST}"; }
warn() { printf '%s%s%s\n' "${YLW}" "${*}" "${RST}"; }

# --- preconditions -----------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { echo "${RED}kubectl not found in PATH${RST}"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "${RED}No reachable cluster (check your kubeconfig/context)${RST}"; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
if printf '%s' "${CTX}" | grep -qiE 'prod|production'; then
  echo "${RED}Refusing to run: context '${CTX}' looks like production.${RST}"
  echo "This lab is for a DISPOSABLE VM only. Switch contexts and retry."
  exit 1
fi

# Verify the server actually ships Pod Security Admission (GA since v1.25).
SRV_MINOR="$(kubectl version -o json 2>/dev/null \
  | grep -oE '"minor":[ ]*"[0-9]+"' | grep -oE '[0-9]+' | head -n1 || echo 0)"
if [[ "${SRV_MINOR}" -lt 25 ]]; then
  warn "Server is v1.${SRV_MINOR}: built-in Pod Security Admission needs v1.25+."
  warn "On older clusters this lab requires the PodSecurity feature gate."
fi

# --- cleanup path ------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" ]]; then
  head "== CLEANUP =="
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
  say "Namespace '${NS}' scheduled for deletion. Lab reset."
  exit 0
fi

# --- confirmation gate -------------------------------------------------------
head "== CNPA 2.4 BREAK & FIX — Pod Security Admission =="
say  "Target context : ${BOLD}${CTX}${RST}"
say  "Target namespace: ${BOLD}${NS}${RST}  (created fresh, deleted on --cleanup)"
if [[ "${LAB_CONFIRM:-}" != "yes" ]]; then
  printf 'Type %sYES%s to break this lab namespace: ' "${BOLD}" "${RST}"
  read -r ANSWER
  [[ "${ANSWER}" == "YES" ]] || { echo "Aborted."; exit 0; }
fi

# ============================================================================
#  BREAK: harden the namespace, then deploy a non-compliant workload
# ============================================================================
head "== BREAKING (hardening a namespace, deploying a bad workload) =="

# 1) Namespace hardened to `restricted` (enforce + audit + warn).
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label --overwrite namespace "${NS}" \
  "pod-security.kubernetes.io/enforce=${PSA_LEVEL}" \
  "pod-security.kubernetes.io/enforce-version=${PSA_VERSION}" \
  "pod-security.kubernetes.io/audit=${PSA_LEVEL}" \
  "pod-security.kubernetes.io/warn=${PSA_LEVEL}" >/dev/null
say "Namespace '${NS}' now ENFORCES the '${PSA_LEVEL}' Pod Security Standard."

# 2) A textbook-looking Deployment with NO securityContext at all.
#    It is fine on a permissive cluster and forbidden under `restricted`.
kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels: { app: ${DEPLOY} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${DEPLOY} }
  template:
    metadata:
      labels: { app: ${DEPLOY} }
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
          # No securityContext -> violates: runAsNonRoot, allowPrivilegeEscalation,
          # capabilities.drop[ALL], and seccompProfile. Four findings at once.
YAML
say "Deployment '${DEPLOY}' applied."

sleep 3

# ============================================================================
#  SYMPTOM  +  OBJECTIVE
# ============================================================================
head "== SYMPTOM YOU WILL OBSERVE =="
kubectl -n "${NS}" get deploy "${DEPLOY}" -o wide || true
echo
warn "* The Deployment reports READY 0/1 and stays there — but nothing crashes."
warn "* 'kubectl -n ${NS} get pods' is EMPTY: no Pod is ever created."
warn "* The rejection is on the ReplicaSet, not the Deployment. Look there:"
echo  "      kubectl -n ${NS} describe rs -l app=${DEPLOY}"
echo  "      kubectl -n ${NS} get events --sort-by=.lastTimestamp | tail -n 15"
echo
say "You will see a message like:"
say "  ${RED}Error creating: pods \"${DEPLOY}-xxxx\" is forbidden: violates PodSecurity"
say "  \"restricted:${PSA_VERSION}\": allowPrivilegeEscalation != false, unrestricted"
say "  capabilities, runAsNonRoot != true, seccompProfile ...${RST}"

head "== YOUR OBJECTIVE =="
say "Make '${DEPLOY}' reach ${GRN}READY 1/1${RST} WITHOUT weakening the namespace."
say "Rules of the fix:"
say "  1. Do NOT change, lower, or remove the 'enforce=${PSA_LEVEL}' label."
say "  2. Do NOT grant privileged/root; the hardening must stay in force."
say "  3. Fix the WORKLOAD so it complies with the 'restricted' standard."
echo
say "Diagnose, then edit the Pod template's securityContext. Success check:"
echo  "      kubectl -n ${NS} rollout status deploy/${DEPLOY} --timeout=60s"
echo  "      kubectl -n ${NS} get pods -o wide"
echo
say "When finished, reset the VM with:  ${BOLD}$0 --cleanup${RST}"

# ============================================================================
#  ────────────────────────────  SPOILER  ────────────────────────────
#  SOLUTION — step by step. Try the objective yourself before reading.
# ============================================================================
#
#  STEP 0 — Understand the failure surface
#  ---------------------------------------
#  A Deployment does not create Pods directly; its ReplicaSet does. Pod
#  Security Admission runs on the CREATE of the *Pod*, so a `restricted`
#  violation shows up as the ReplicaSet failing to create Pods, while the
#  Deployment object itself was admitted cleanly. This is why `get pods` is
#  empty and the real error hides in the ReplicaSet / namespace events.
#
#      kubectl -n cnpa-lab-24 describe rs -l app=hardening-victim
#      kubectl -n cnpa-lab-24 get events --sort-by=.lastTimestamp | tail -n 15
#
#  STEP 1 — Read exactly what `restricted` demands
#  -----------------------------------------------
#  The four findings in the error map 1:1 to the required fields:
#    * runAsNonRoot: true                    (must not run as UID 0)
#    * allowPrivilegeEscalation: false       (no setuid escalation)
#    * capabilities: drop ["ALL"]            (start from zero Linux caps)
#    * seccompProfile.type: RuntimeDefault   (syscall filtering on)
#  busybox's default user is root, so we also pin a non-zero UID
#  (runAsUser: 1000); otherwise runAsNonRoot passes admission but the
#  kubelet refuses to start the container at runtime.
#  Reference: https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted
#
#  STEP 2 — Apply the compliant workload (only the template changed)
#  -----------------------------------------------------------------
#  cat <<'FIXED' | kubectl apply -f -
#  apiVersion: apps/v1
#  kind: Deployment
#  metadata:
#    name: hardening-victim
#    namespace: cnpa-lab-24
#    labels: { app: hardening-victim }
#  spec:
#    replicas: 1
#    selector:
#      matchLabels: { app: hardening-victim }
#    template:
#      metadata:
#        labels: { app: hardening-victim }
#      spec:
#        securityContext:                 # ---- Pod level ----
#          runAsNonRoot: true
#          runAsUser: 1000
#          seccompProfile:
#            type: RuntimeDefault
#        containers:
#          - name: app
#            image: busybox:1.36
#            command: ["sh", "-c", "sleep infinity"]
#            securityContext:             # ---- Container level ----
#              allowPrivilegeEscalation: false
#              capabilities:
#                drop: ["ALL"]
#  FIXED
#
#  STEP 3 — Verify the fix while the hardening is still enforced
#  ------------------------------------------------------------
#      kubectl -n cnpa-lab-24 rollout status deploy/hardening-victim --timeout=60s
#      kubectl -n cnpa-lab-24 get pods -o wide          # -> Running, 1/1
#      # Confirm you did NOT weaken the namespace; enforce must still be restricted:
#      kubectl get ns cnpa-lab-24 -o jsonpath='{.metadata.labels}' ; echo
#      # Confirm the container is genuinely unprivileged:
#      kubectl -n cnpa-lab-24 exec deploy/hardening-victim -- id     # uid=1000 gid=0
#
#  STEP 4 — (Optional) prove the standard is real
#  ----------------------------------------------
#  Re-apply the original template (remove both securityContext blocks) and
#  watch the ReplicaSet be rejected again. This is the fastest way to teach
#  yourself which single field triggers which line of the admission error:
#  drop one required field at a time and re-read the message.
#
#  STEP 5 — Reset the lab
#  ----------------------
#      ./this-script.sh --cleanup      # deletes namespace cnpa-lab-24
#
#  KEY TAKEAWAYS
#  -------------
#  * `restricted` is enforced per-namespace via three labels: enforce, audit,
#    warn. Only `enforce` blocks; `warn`/`audit` are how you roll it out
#    safely on live namespaces before flipping enforce.
#  * Always pin enforce-version (e.g. v1.30) so a cluster upgrade cannot
#    silently tighten the policy underneath running workloads.
#  * The correct remediation is to fix the workload, never to downgrade the
#    namespace to `baseline`/`privileged` to make an error disappear.
# ============================================================================