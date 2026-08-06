#!/usr/bin/env bash
#
# break_fix.sh — CNPA 1.4: Platform Architecture and Core Capabilities
#
# Break & fix lab. Builds a miniature Internal Developer Platform (IDP) on a
# disposable Kubernetes lab cluster, then injects two controlled faults — one
# per architectural layer — so the student has to reason about how a platform
# is put together, not just about a single broken pod:
#
#   Layer 1 — Developer interface (portal/API):
#       Deployment "portal-api" + Service "portal-api" in namespace
#       "idp-platform". The Service is the stable entry point every developer
#       interface (portal UI, CLI, CI job) resolves. Fault A breaks the
#       Service->Pod wiring.
#
#   Layer 2 — Core capability (self-service provisioning):
#       ServiceAccount "tenant-provisioner" + ClusterRole + ClusterRoleBinding
#       implement the golden path "give me a tenant namespace with quotas".
#       Fault B breaks the identity wiring of that capability.
#
# The point of the exercise: in a platform, the control plane (Kubernetes API)
# keeps working while a *capability built on top of it* fails. Diagnosis means
# walking the layers: interface -> platform API -> RBAC -> control plane.
#
# References:
#   - CNCF Platforms White Paper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
#   - CNCF Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
#   - Kubernetes Services: https://kubernetes.io/docs/concepts/services-networking/service/
#   - Kubernetes RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#
# Usage:
#   ./break_fix.sh            # setup + break + mission brief (default)
#   ./break_fix.sh setup      # deploy the healthy mini-platform only
#   ./break_fix.sh break      # inject the faults (runs setup first if needed)
#   ./break_fix.sh verify     # check whether the student's fix is complete
#   ./break_fix.sh reset      # remove every lab resource
#
# Safety: only creates/patches resources it owns (namespace "idp-platform",
# ClusterRole/Binding "cnpa-tenant-provisioner", namespaces labeled
# cnpa-lab=1.4). Refuses to run against a context that does not look like a
# lab cluster unless FORCE=1 is set.

set -euo pipefail

NS="idp-platform"
SA="tenant-provisioner"
CR="cnpa-tenant-provisioner"
CRB="cnpa-tenant-provisioner"
SVC="portal-api"
APP_LABEL="portal-api"
LAB_LABEL="cnpa-lab=1.4"
IMPERSONATE="system:serviceaccount:${NS}:${SA}"
CURL_IMAGE="curlimages/curl:8.10.1"

log()  { printf '\n\033[1;34m[lab]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[lab] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_lab_cluster() {
    command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
    kubectl version >/dev/null 2>&1 || die "no reachable Kubernetes cluster (is your lab VM's cluster running?)"
    local ctx
    ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
    if [[ "${FORCE:-0}" != "1" ]] && ! [[ "$ctx" =~ (kind|k3d|k3s|minikube|microk8s|rancher-desktop|docker-desktop|lab) ]]; then
        die "context '$ctx' does not look like a disposable lab cluster; re-run with FORCE=1 if you are sure"
    fi
}

setup() {
    log "Deploying the mini Internal Developer Platform into namespace '${NS}'..."

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    cnpa-lab: "1.4"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-content
  namespace: ${NS}
  labels:
    cnpa-lab: "1.4"
data:
  capabilities.json: |
    {
      "platform": "acme-idp",
      "architecture": {
        "control_plane": "kubernetes",
        "interfaces": ["portal", "api", "cli"]
      },
      "core_capabilities": [
        "self-service-provisioning",
        "golden-path-templates",
        "observability",
        "identity-and-access",
        "secrets-management"
      ]
    }
  index.html: |
    <html><body><h1>acme-idp developer portal</h1>
    <p>GET /capabilities.json for the capability catalog.</p></body></html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-api
  namespace: ${NS}
  labels:
    cnpa-lab: "1.4"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_LABEL}
  template:
    metadata:
      labels:
        app: ${APP_LABEL}
        cnpa-lab: "1.4"
    spec:
      containers:
      - name: portal
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: content
          mountPath: /usr/share/nginx/html
        readinessProbe:
          httpGet:
            path: /capabilities.json
            port: 80
          initialDelaySeconds: 2
          periodSeconds: 5
      volumes:
      - name: content
        configMap:
          name: portal-content
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
  labels:
    cnpa-lab: "1.4"
spec:
  selector:
    app: ${APP_LABEL}
  ports:
  - name: http
    port: 80
    targetPort: 80
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA}
  namespace: ${NS}
  labels:
    cnpa-lab: "1.4"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CR}
  labels:
    cnpa-lab: "1.4"
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["create", "get", "list", "patch"]
- apiGroups: [""]
  resources: ["resourcequotas", "limitranges"]
  verbs: ["create", "get", "list", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB}
  labels:
    cnpa-lab: "1.4"
subjects:
- kind: ServiceAccount
  name: ${SA}
  namespace: ${NS}
roleRef:
  kind: ClusterRole
  name: ${CR}
  apiGroup: rbac.authorization.k8s.io
EOF

    log "Waiting for the portal to become Ready..."
    kubectl -n "${NS}" rollout status deployment/portal-api --timeout=120s

    log "Baseline smoke test of both platform capabilities..."
    verify && log "Baseline is healthy. The platform works." \
           || die "baseline verification failed before any fault was injected — fix the cluster first"
}

inject_faults() {
    kubectl get ns "${NS}" >/dev/null 2>&1 || setup

    log "Injecting Fault A (interface layer): Service selector no longer matches the portal pods..."
    kubectl -n "${NS}" patch svc "${SVC}" --type merge \
        -p '{"spec":{"selector":{"app":"portal-backend"}}}' >/dev/null

    log "Injecting Fault B (capability layer): the provisioning ClusterRoleBinding now points at a ServiceAccount that does not exist..."
    kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB}
  labels:
    cnpa-lab: "1.4"
subjects:
- kind: ServiceAccount
  name: ${SA}-v2
  namespace: ${NS}
roleRef:
  kind: ClusterRole
  name: ${CR}
  apiGroup: rbac.authorization.k8s.io
EOF

    cat <<'BRIEF'

================================================================================
 MISSION BRIEF — CNPA 1.4: Platform Architecture and Core Capabilities
================================================================================

 Overnight, someone "refactored" the platform. This morning two independent
 capabilities of the acme-idp platform are broken. The Kubernetes control
 plane itself is perfectly healthy — the platform built on top of it is not.

 SYMPTOM 1 — The developer portal API is unreachable.
   Any client of the platform's interface layer fails. Try it yourself:

     kubectl -n idp-platform run probe --rm -i --restart=Never \
       --image=curlimages/curl:8.10.1 -- \
       curl -s --max-time 5 http://portal-api.idp-platform.svc/capabilities.json

   Expected symptom: the request hangs and then fails, e.g.
     curl: (28) Connection timed out ...   (or curl: (7) Failed to connect)
   Yet the portal pod is Running and Ready. Something between the stable
   Service entry point and the pods is wrong.

 SYMPTOM 2 — Self-service tenant provisioning is denied.
   The golden path "create me a tenant namespace" runs as the platform's
   provisioning identity. Try what the automation does:

     kubectl auth can-i create namespaces \
       --as=system:serviceaccount:idp-platform:tenant-provisioner

   Expected symptom: "no". A real provisioning call fails with:
     Error from server (Forbidden): namespaces is forbidden:
     User "system:serviceaccount:idp-platform:tenant-provisioner" cannot
     create resource "namespaces" ...
   Yet the ClusterRole with the right rules still exists. Something in the
   identity wiring of this capability is wrong.

 YOUR GOAL
   Restore both capabilities WITHOUT deleting the namespace or re-running
   setup. Walk the layers like a platform engineer:
     interface (Service) -> workload (labels) and
     capability (golden path) -> identity (RBAC subject) -> control plane.

 You are done when this reports 4/4 PASS:

     ./break_fix.sh verify

 Hints (in escalating order — try on your own first):
   kubectl -n idp-platform get endpoints portal-api
   kubectl -n idp-platform get svc portal-api -o yaml | grep -A2 selector
   kubectl -n idp-platform get pods --show-labels
   kubectl get clusterrolebinding cnpa-tenant-provisioner -o yaml
================================================================================
BRIEF
}

run_curl_probe() {
    local pod="cnpa-verify-curl-$$"
    kubectl -n "${NS}" run "${pod}" --restart=Never --image="${CURL_IMAGE}" \
        --labels="cnpa-lab=1.4" -- \
        curl -sf --max-time 5 "http://${SVC}.${NS}.svc/capabilities.json" >/dev/null 2>&1 || true
    local phase="Unknown" i
    for i in $(seq 1 24); do
        phase="$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
        [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
        sleep 5
    done
    kubectl -n "${NS}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1
    [[ "${phase}" == "Succeeded" ]]
}

verify() {
    local pass=0 total=4

    log "Check 1/4 — Service '${SVC}' has ready endpoints (interface layer wiring)"
    local eps
    eps="$(kubectl -n "${NS}" get endpoints "${SVC}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [[ -n "${eps}" ]]; then ok "endpoints: ${eps}"; pass=$((pass+1)); else fail "no endpoints behind the Service (selector vs pod labels?)"; fi

    log "Check 2/4 — Portal answers through the Service (in-cluster HTTP probe)"
    if run_curl_probe; then ok "GET /capabilities.json returned 200 via ${SVC}.${NS}.svc"; pass=$((pass+1)); else fail "portal not reachable through the Service"; fi

    log "Check 3/4 — Provisioning identity is authorized (capability layer RBAC)"
    if [[ "$(kubectl auth can-i create namespaces --as="${IMPERSONATE}" 2>/dev/null)" == "yes" ]]; then
        ok "${IMPERSONATE} can create namespaces"; pass=$((pass+1))
    else
        fail "${IMPERSONATE} is Forbidden (check the ClusterRoleBinding subject)"
    fi

    log "Check 4/4 — Golden path works end to end (provision a tenant as the platform would)"
    if kubectl --as="${IMPERSONATE}" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-smoke
  labels:
    cnpa-lab: "1.4"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: tenant-smoke
spec:
  hard:
    pods: "10"
    requests.cpu: "2"
    requests.memory: 2Gi
EOF
    then
        ok "tenant namespace + quota provisioned via impersonated golden path"
        pass=$((pass+1))
        kubectl delete ns tenant-smoke --ignore-not-found --wait=false >/dev/null 2>&1
    else
        fail "self-service provisioning failed (run it without >/dev/null to see the Forbidden error)"
    fi

    printf '\n\033[1m  Result: %d/%d checks passed\033[0m\n' "${pass}" "${total}"
    [[ "${pass}" -eq "${total}" ]]
}

reset() {
    log "Removing every lab resource..."
    kubectl delete clusterrolebinding "${CRB}" --ignore-not-found
    kubectl delete clusterrole "${CR}" --ignore-not-found
    kubectl delete ns -l "${LAB_LABEL}" --ignore-not-found --wait=false
    log "Done. Namespaces labeled ${LAB_LABEL} are terminating in the background."
}

require_lab_cluster
case "${1:-all}" in
    setup)  setup ;;
    break)  inject_faults ;;
    verify) verify ;;
    reset)  reset ;;
    all)    setup; inject_faults ;;
    *)      die "usage: $0 [setup|break|verify|reset]" ;;
esac
exit 0

################################################################################
# SOLUTION — step by step (do not read until you have tried on your own)
################################################################################
#
# --- Fault A: portal unreachable through the Service -------------------------
#
# 1. Confirm the symptom is in the Service layer, not the workload:
#
#      kubectl -n idp-platform get pods
#        NAME                          READY   STATUS    RESTARTS   AGE
#        portal-api-xxxxxxxxxx-xxxxx   1/1     Running   0          5m
#
#      kubectl -n idp-platform get endpoints portal-api
#        NAME         ENDPOINTS   AGE
#        portal-api   <none>      5m
#
#    A Ready pod with an empty Endpoints object means the Service selector
#    matches nothing. This is the classic interface-layer failure: the stable
#    entry point exists, but it is wired to a workload identity that no longer
#    matches.
#
# 2. Compare the selector with the actual pod labels:
#
#      kubectl -n idp-platform get svc portal-api -o jsonpath='{.spec.selector}'
#        {"app":"portal-backend"}
#      kubectl -n idp-platform get pods --show-labels
#        ... app=portal-api,cnpa-lab=1.4 ...
#
# 3. Fix: point the selector back at the real label:
#
#      kubectl -n idp-platform patch svc portal-api --type merge \
#        -p '{"spec":{"selector":{"app":"portal-api"}}}'
#
#    The EndpointSlice controller repopulates the endpoints within seconds:
#
#      kubectl -n idp-platform get endpoints portal-api
#        NAME         ENDPOINTS      AGE
#        portal-api   10.244.x.y:80  6m
#
# --- Fault B: self-service provisioning Forbidden ----------------------------
#
# 4. Confirm it is authorization, and locate the layer:
#
#      kubectl auth can-i create namespaces \
#        --as=system:serviceaccount:idp-platform:tenant-provisioner
#        no
#
#    The ClusterRole still has the right rules — verify with:
#
#      kubectl describe clusterrole cnpa-tenant-provisioner
#
#    So the break must be in the binding between identity and role.
#
# 5. Inspect the binding's subject:
#
#      kubectl get clusterrolebinding cnpa-tenant-provisioner \
#        -o jsonpath='{.subjects[0].name}'
#        tenant-provisioner-v2
#
#    The binding grants the role to a ServiceAccount that does not exist
#    ("tenant-provisioner-v2"), while the platform's automation still runs as
#    "tenant-provisioner". RBAC fails closed: an unmatched subject simply
#    means no permissions, with no error anywhere until a request is denied.
#
# 6. Fix: bind the role to the real ServiceAccount again. Subjects are not
#    patchable in-place by strategic merge on all servers, so replace cleanly:
#
#      kubectl apply -f - <<'YAML'
#      apiVersion: rbac.authorization.k8s.io/v1
#      kind: ClusterRoleBinding
#      metadata:
#        name: cnpa-tenant-provisioner
#        labels:
#          cnpa-lab: "1.4"
#      subjects:
#      - kind: ServiceAccount
#        name: tenant-provisioner
#        namespace: idp-platform
#      roleRef:
#        kind: ClusterRole
#        name: cnpa-tenant-provisioner
#        apiGroup: rbac.authorization.k8s.io
#      YAML
#
#      kubectl auth can-i create namespaces \
#        --as=system:serviceaccount:idp-platform:tenant-provisioner
#        yes
#
# 7. Prove both capabilities end to end:
#
#      ./break_fix.sh verify
#        ...
#        Result: 4/4 checks passed
#
# --- The architecture lesson -------------------------------------------------
#
# Neither fault touched the Kubernetes control plane, and `kubectl get
# componentstatuses` / node health would have shown nothing. A platform is
# layered: developer interfaces (the Service in front of the portal) and core
# capabilities (the RBAC-backed golden path) are contracts built ON TOP of the
# control plane, and each layer can break independently while every layer
# below it stays green. Production diagnosis therefore walks the request path
# layer by layer — interface, wiring, identity, control plane — instead of
# assuming "the cluster is down".
################################################################################