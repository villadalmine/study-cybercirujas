#!/usr/bin/env bash
#
# break_fix.sh — CNPE 1.1: Applying Platform Architecture Best Practices
#                for Networking, Storage, and Compute
#
# Cloud Native Platform Engineer (CNPE) — Domain 1, Topic 1.1 (exam weight: 5)
#
# WHAT THIS SCRIPT IS
#   A controlled "break & fix" drill for a DISPOSABLE single-node Kubernetes
#   lab VM (k3s / kind / minikube). It provisions a small stateful workload the
#   way a platform team would ship it (Deployment + PersistentVolumeClaim +
#   Service, with resource requests and a readiness probe) and then injects ONE
#   realistic platform-architecture defect in the STORAGE layer. Your job is to
#   diagnose it the way you would on call and drive the workload back to a
#   healthy, Ready state.
#
# WHY STORAGE
#   Topic 1.1 spans networking, storage and compute. Storage is where most
#   "the app won't start and nobody changed the app" incidents actually live:
#   a StorageClass with the wrong provisioner, a missing default class, or a
#   binding-mode assumption that only fails once a Pod is scheduled. Getting the
#   StorageClass -> PVC -> PV -> Pod chain right IS platform architecture.
#
# SAFETY
#   - Everything lives in the namespace 'cnpe-lab-1-1' plus ONE clearly-prefixed
#     cluster-scoped StorageClass ('cnpe-fast-ssd'). The cluster's real default
#     StorageClass is never touched.
#   - Refuses to run on a cluster with more than one node unless you set
#     CNPE_LAB_FORCE=1, so you cannot fire this at a real multi-node cluster by
#     accident.
#   - Idempotent: re-running 'break' just re-applies the same manifests.
#   - 'cleanup' removes every object it created.
#
# USAGE
#   ./break_fix.sh            # same as 'break': inject the fault + print briefing
#   ./break_fix.sh break      # inject the fault and print the student briefing
#   ./break_fix.sh verify     # check whether you have restored the workload
#   ./break_fix.sh cleanup    # delete all lab objects
#   ./break_fix.sh solution   # print the step-by-step solution
#
# SOURCES (official)
#   - CNPE Curriculum:
#     https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
#   - StorageClasses & volume binding mode:
#     https://kubernetes.io/docs/concepts/storage/storage-classes/
#   - Dynamic provisioning & the default StorageClass:
#     https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
#   - PersistentVolumes / PersistentVolumeClaims:
#     https://kubernetes.io/docs/concepts/storage/persistent-volumes/
#   - Debugging Pending Pods:
#     https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
#
set -euo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------------- #
# Configuration                                                               #
# --------------------------------------------------------------------------- #
NS="cnpe-lab-1-1"
APP="payments"
BROKEN_SC="cnpe-fast-ssd"          # cluster-scoped, prefixed, removed on cleanup
PVC="payments-data"
IMAGE="${CNPE_IMAGE:-nginx:1.27-alpine}"

# --------------------------------------------------------------------------- #
# Helpers                                                                      #
# --------------------------------------------------------------------------- #
say()  { printf '%s\n' "$*"; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

preflight() {
  command -v kubectl >/dev/null 2>&1 || die \
    "kubectl not found. This drill needs a disposable single-node cluster (k3s/kind/minikube)."
  kubectl version >/dev/null 2>&1 || kubectl cluster-info >/dev/null 2>&1 || die \
    "No reachable Kubernetes cluster. Point KUBECONFIG at your lab cluster and retry."

  local ctx node_count
  ctx="$(kubectl config current-context 2>/dev/null || echo '<unknown>')"
  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  say "Context : ${ctx}"
  say "Nodes   : ${node_count}"

  if [ "${node_count:-0}" -gt 1 ] && [ "${CNPE_LAB_FORCE:-0}" != "1" ]; then
    die "This looks like a multi-node cluster (${node_count} nodes). Refusing.
     Run on a disposable single-node lab, or export CNPE_LAB_FORCE=1 to override."
  fi
}

detect_default_sc() {
  kubectl get storageclass -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' '$2=="true"{print $1; exit}'
}

# --------------------------------------------------------------------------- #
# break — inject the fault                                                     #
# --------------------------------------------------------------------------- #
break_it() {
  preflight
  say "Injecting the CNPE 1.1 storage fault into namespace '${NS}'..."

  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # A StorageClass that a platform team "designed" for a fast local tier but
  # wired to the static local provisioner with NO backing PV and a lazy binding
  # mode. Dynamic provisioning therefore never happens.
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${BROKEN_SC}
  labels:
    app.kubernetes.io/part-of: ${NS}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
YAML

  # The workload, shipped correctly, but pinned to the broken StorageClass.
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${APP}
    app.kubernetes.io/part-of: ${NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${BROKEN_SC}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${APP}
    app.kubernetes.io/part-of: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      containers:
        - name: ${APP}
          image: ${IMAGE}
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "128Mi"
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC}
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${APP}
spec:
  selector:
    app: ${APP}
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

  briefing
}

# --------------------------------------------------------------------------- #
# briefing — what the student sees and must achieve                            #
# --------------------------------------------------------------------------- #
briefing() {
  local default_sc; default_sc="$(detect_default_sc || true)"
  rule
  say "CNPE 1.1 BREAK & FIX — Storage architecture incident"
  rule
  say ""
  say "SCENARIO"
  say "  The '${APP}' service in namespace '${NS}' was shipped by another team."
  say "  It has a PersistentVolumeClaim for its data tier. The Deployment is"
  say "  healthy in YAML, the image is fine, and nobody changed the app code."
  say "  Yet the Pod never starts."
  say ""
  say "SYMPTOM YOU WILL SEE"
  say "  \$ kubectl -n ${NS} get pods"
  say "    NAME                        READY   STATUS    RESTARTS   AGE"
  say "    ${APP}-xxxxxxxxxx-xxxxx      0/1     Pending   0          30s"
  say ""
  say "  \$ kubectl -n ${NS} get pvc"
  say "    NAME            STATUS    VOLUME  CAPACITY  ACCESS MODES  STORAGECLASS"
  say "    ${PVC}   Pending                                 ${BROKEN_SC}"
  say ""
  say "  'kubectl -n ${NS} describe pvc ${PVC}' will report the PVC is"
  say "  'waiting for first consumer to be created before binding', and once the"
  say "  Pod is scheduled it still never binds — the Pod events say it is"
  say "  waiting for a volume that no provisioner will ever create."
  say ""
  say "YOUR GOAL"
  say "  Drive the workload to a healthy state WITHOUT deleting the namespace and"
  say "  WITHOUT rewriting the application. Success means all of:"
  say "    - PVC '${PVC}' is Bound"
  say "    - Deployment '${APP}' has 1/1 available replicas (Pod Running & Ready)"
  say "    - Service '${APP}' has a ready endpoint"
  say ""
  say "THINK LIKE A PLATFORM ARCHITECT"
  say "  - What does 'provisioner: kubernetes.io/no-provisioner' actually promise?"
  say "  - What does 'volumeBindingMode: WaitForFirstConsumer' change about WHEN"
  say "    the failure appears?"
  say "  - Is a PVC's storageClassName mutable once created?"
  say "  - Two valid fixes exist: repoint the claim at a working dynamic"
  say "    StorageClass (best practice), or satisfy the static class with a PV."
  if [ -n "${default_sc}" ]; then
    say "  - This cluster's default (dynamic) StorageClass is: '${default_sc}'."
  else
    say "  - Heads up: this cluster has NO default StorageClass — that constraint"
    say "    itself is part of the lesson. The static-PV path will still work."
  fi
  say ""
  say "  Investigate with:"
  say "    kubectl -n ${NS} get pods,pvc"
  say "    kubectl -n ${NS} describe pvc ${PVC}"
  say "    kubectl -n ${NS} describe pod -l app=${APP}"
  say "    kubectl get storageclass"
  say ""
  say "When you believe it is fixed, run:  ./break_fix.sh verify"
  rule
}

# --------------------------------------------------------------------------- #
# verify — did the student restore service?                                    #
# --------------------------------------------------------------------------- #
verify() {
  preflight
  local pvc_phase avail eps ok=1

  pvc_phase="$(kubectl -n "${NS}" get pvc "${PVC}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  avail="$(kubectl -n "${NS}" get deploy "${APP}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  eps="$(kubectl -n "${NS}" get endpoints "${APP}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"

  rule
  say "VERIFY — CNPE 1.1"
  rule
  [ "${pvc_phase}" = "Bound" ] && say "[ok]   PVC ${PVC} is Bound" \
                                || { say "[fail] PVC ${PVC} phase='${pvc_phase:-<none>}' (want Bound)"; ok=0; }
  [ "${avail:-0}" -ge 1 ] 2>/dev/null && say "[ok]   Deployment ${APP} available replicas=${avail}" \
                                       || { say "[fail] Deployment ${APP} available replicas='${avail:-0}' (want >=1)"; ok=0; }
  [ -n "${eps}" ] && say "[ok]   Service ${APP} has endpoint(s): ${eps}" \
                   || { say "[fail] Service ${APP} has no ready endpoints"; ok=0; }
  rule
  if [ "${ok}" -eq 1 ]; then
    say "PASS — you restored the storage chain and the workload is serving. Well done."
    return 0
  fi
  say "NOT YET — inspect the objects above, then re-run './break_fix.sh verify'."
  say "Stuck? './break_fix.sh solution' prints the full walkthrough."
  return 1
}

# --------------------------------------------------------------------------- #
# cleanup — remove everything the drill created                                #
# --------------------------------------------------------------------------- #
cleanup() {
  preflight
  say "Removing CNPE 1.1 lab objects..."
  kubectl delete namespace "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete storageclass "${BROKEN_SC}" --ignore-not-found >/dev/null 2>&1 || true
  # Any static PV the student may have created to fix the drill:
  kubectl delete pv -l "app.kubernetes.io/part-of=${NS}" --ignore-not-found >/dev/null 2>&1 || true
  say "Done."
}

print_solution() { sed -n '/^# ===== SOLUTION/,/^# ===== END SOLUTION/p' "$0"; }

# --------------------------------------------------------------------------- #
# main                                                                         #
# --------------------------------------------------------------------------- #
main() {
  case "${1:-break}" in
    break|"")  break_it ;;
    verify)    verify ;;
    cleanup)   cleanup ;;
    solution)  print_solution ;;
    *)         die "Unknown action '${1}'. Use: break | verify | cleanup | solution" ;;
  esac
}
main "${@:-}"

# ===== SOLUTION (step-by-step) ================================================
#
# ROOT CAUSE
#   The PVC 'payments-data' is bound (by name) to StorageClass 'cnpe-fast-ssd',
#   whose provisioner is 'kubernetes.io/no-provisioner'. That provisioner does
#   NOT create volumes dynamically — it only binds PVCs to PersistentVolumes an
#   administrator has already created statically. No such PV exists, so the PVC
#   can never be satisfied. Because volumeBindingMode is WaitForFirstConsumer,
#   the PVC sits Pending ("waiting for first consumer to be created before
#   binding") until the Pod is scheduled, and then STILL never binds — so the
#   Pod is stuck Pending forever. The application is innocent; the storage
#   architecture is the fault.
#
# DIAGNOSIS (what a platform engineer runs)
#   1. See the stuck workload and its claim:
#        kubectl -n cnpe-lab-1-1 get pods,pvc
#   2. Read the claim's events — this is where the truth is:
#        kubectl -n cnpe-lab-1-1 describe pvc payments-data
#      -> "waiting for first consumer..." then no binding = no provisioner.
#   3. Inspect the StorageClass the claim points at:
#        kubectl get storageclass cnpe-fast-ssd -o yaml
#      -> provisioner: kubernetes.io/no-provisioner   (the smoking gun)
#   4. Confirm the Pod is blocked purely on the volume:
#        kubectl -n cnpe-lab-1-1 describe pod -l app=payments
#   5. Find a StorageClass that DOES provision dynamically:
#        kubectl get storageclass
#      (the one annotated storageclass.kubernetes.io/is-default-class="true")
#
# ------------------------------------------------------------------------------
# FIX A — RECOMMENDED (best practice): repoint the claim at a dynamic class.
#   A PVC's spec.storageClassName is IMMUTABLE, so you must delete and recreate
#   the claim. The PVC is guarded by the pvc-protection finalizer while a Pod
#   references it, so scale the workload down first, then back up.
#
#   # Discover the default/dynamic class name (k3s: local-path, minikube/kind: standard)
#   SC="$(kubectl get storageclass -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | awk -F"\t" '$2=="true"{print $1; exit}')"
#   echo "Using dynamic StorageClass: ${SC:?no default StorageClass found — use FIX B}"
#
#   kubectl -n cnpe-lab-1-1 scale deploy/payments --replicas=0
#   kubectl -n cnpe-lab-1-1 delete pvc payments-data
#   cat <<EOF | kubectl apply -f -
#   apiVersion: v1
#   kind: PersistentVolumeClaim
#   metadata:
#     name: payments-data
#     namespace: cnpe-lab-1-1
#     labels:
#       app.kubernetes.io/part-of: cnpe-lab-1-1
#   spec:
#     accessModes: ["ReadWriteOnce"]
#     storageClassName: ${SC}
#     resources:
#       requests:
#         storage: 1Gi
#   EOF
#   kubectl -n cnpe-lab-1-1 scale deploy/payments --replicas=1
#
#   # The default class provisions a volume, the PVC binds, the Pod runs.
#   kubectl -n cnpe-lab-1-1 get pvc,pods -w
#
# ------------------------------------------------------------------------------
# FIX B — STATIC PROVISIONING: honor the existing class by supplying a PV.
#   Works on ANY single-node cluster, even one with no default class, because it
#   gives 'kubernetes.io/no-provisioner' exactly what it expects: a pre-created
#   PersistentVolume in the same StorageClass. WaitForFirstConsumer then binds it
#   as soon as the Pod is scheduled. (hostPath is fine for a disposable lab node;
#   in production you would use a real local/CSI volume with nodeAffinity.)
#
#   cat <<EOF | kubectl apply -f -
#   apiVersion: v1
#   kind: PersistentVolume
#   metadata:
#     name: cnpe-payments-pv
#     labels:
#       app.kubernetes.io/part-of: cnpe-lab-1-1
#   spec:
#     capacity:
#       storage: 1Gi
#     accessModes: ["ReadWriteOnce"]
#     persistentVolumeReclaimPolicy: Delete
#     storageClassName: cnpe-fast-ssd
#     hostPath:
#       path: /tmp/cnpe-payments-data
#       type: DirectoryOrCreate
#   EOF
#
#   # No delete/recreate needed — the existing Pending PVC binds to this PV.
#   kubectl -n cnpe-lab-1-1 get pvc,pods -w
#
# ------------------------------------------------------------------------------
# VERIFY
#   ./break_fix.sh verify
#   Expect: PVC Bound, Deployment 1/1, Service endpoint present.
#
# CLEANUP
#   ./break_fix.sh cleanup
#
# PLATFORM-ARCHITECTURE TAKEAWAYS (topic 1.1)
#   - Provisioner choice is an architecture decision: 'no-provisioner' means the
#     platform team owns PV lifecycle manually; a CSI/dynamic class means the
#     platform provisions on demand. Never ship a workload against a static class
#     without also shipping (or automating) the backing PVs.
#   - WaitForFirstConsumer defers binding to scheduling time so the volume lands
#     in the right topology (zone/node) as the Pod — powerful, but it also DELAYS
#     when a misconfiguration surfaces from "apply time" to "first Pod schedule".
#   - storageClassName is immutable; treat a PVC's class as a day-0 contract.
#   - A default StorageClass is a platform guarantee: claims that omit a class
#     should Just Work. A cluster with none is a deliberate (and testable) choice.
#   Refs: https://kubernetes.io/docs/concepts/storage/storage-classes/
#         https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
#         https://kubernetes.io/docs/concepts/storage/persistent-volumes/
# ===== END SOLUTION ===========================================================