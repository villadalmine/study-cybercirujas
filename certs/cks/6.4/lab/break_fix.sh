#!/usr/bin/env bash
#
# =============================================================================
#  CKS 1.34 — Domain 6: Supply Chain Security
#  Topic 6.4 — Ensure immutability of containers at runtime   (topic weight: 4)
#
#  BREAK & FIX LAB
#
#  Reference: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#             https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
#             https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
#             https://kubernetes.io/docs/concepts/security/pod-security-standards/
#
#  WHAT THIS LAB DOES
#  ------------------
#  It provisions a namespace with a ValidatingAdmissionPolicy that *enforces*
#  runtime immutability, then plants two deliberately broken workloads:
#
#    BREAK #1  edge-proxy    — correctly hardened (readOnlyRootFilesystem: true)
#                              but with no writable ephemeral volumes, so the
#                              process cannot start. CrashLoopBackOff.
#    BREAK #2  report-agent  — admitted BEFORE the policy existed, therefore
#                              still Running while violating every immutability
#                              rule. Any restart of it is denied at admission.
#
#  The student must make BOTH workloads healthy WITHOUT weakening the policy.
#  The naive fix (readOnlyRootFilesystem: false) is blocked on purpose.
#
#  SAFETY
#  ------
#  * Everything created is confined to the namespace 'immutability-lab' plus two
#    cluster-scoped objects prefixed 'cks-64-'. Nothing else is touched.
#  * The admission policy binding is scoped by namespaceSelector, so it can
#    never deny a Pod outside the lab namespace.
#  * Still: run this ONLY on a disposable lab cluster where you are admin
#    (kind / minikube / a throwaway kubeadm VM). It refuses to run unless you
#    explicitly confirm.
#  * './break_fix.sh --cleanup' removes 100% of what it created.
#
#  USAGE
#    ./break_fix.sh --confirm      # break the lab and print the briefing
#    ./break_fix.sh --brief        # reprint the mission briefing
#    ./break_fix.sh --verify       # grade your fix (9 automated checks)
#    ./break_fix.sh --cleanup      # remove the lab
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until you have burned at least 30 minutes on your own.
# =============================================================================

set -euo pipefail

NS="immutability-lab"
POLICY="cks-64-require-immutability"
BINDING="cks-64-require-immutability-binding"
LAB_DIR="${LAB_DIR:-$HOME/cks-6.4-immutability-lab}"
POLICY_ENFORCED="true"

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; BOLD=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; BOLD=""; N=""
fi

log()  { printf '%s[lab]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  PASS%s  %s\n' "$G" "$N" "$*"; }
bad()  { printf '%s  FAIL%s  %s\n' "$R" "$N" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[fatal]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  kubectl version -o yaml >/dev/null 2>&1 || die "no reachable cluster (check your kubeconfig)."

  local ctx server
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo unknown)"

  case "$ctx" in
    *prod*|*production*|*prd*)
      die "current context '$ctx' looks like production. Refusing. Switch context first." ;;
  esac

  log "context : $ctx"
  log "server  : $server"
  log "k8s     : $(kubectl version -o json 2>/dev/null | tr -d ' \n' | sed -n 's/.*"serverVersion".*"gitVersion":"\([^"]*\)".*/\1/p')"

  if [ "${CKS_LAB_CONFIRM:-}" != "yes" ] && [ "${CONFIRMED:-0}" != "1" ]; then
    cat <<'EOF'

  This script mutates a live cluster. Re-run it with --confirm (or export
  CKS_LAB_CONFIRM=yes) once you are sure the context above is a DISPOSABLE lab.

EOF
    exit 1
  fi

  # ValidatingAdmissionPolicy is GA since v1.30 and is what the CKS 1.34 exam
  # ships with. Degrade gracefully on older clusters instead of half-breaking.
  if kubectl api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null \
       | grep -q '^validatingadmissionpolicies'; then
    POLICY_ENFORCED="true"
  else
    POLICY_ENFORCED="false"
    warn "ValidatingAdmissionPolicy is unavailable on this API server."
    warn "The lab will still break correctly, but the 'you cannot cheat' guard"
    warn "is advisory only. Prefer a v1.30+ cluster for the full experience."
  fi
}

# -----------------------------------------------------------------------------
# Manifests — written to disk so the student edits real files, like in the exam
# -----------------------------------------------------------------------------
write_manifests() {
  mkdir -p "$LAB_DIR"

  cat > "$LAB_DIR/00-namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: immutability-lab
  labels:
    # The admission policy binding below selects namespaces by THIS label.
    # Removing it disables enforcement -> --verify treats that as cheating.
    cks.lab/immutability: enforced
    # Pod Security Admission "restricted" is enabled on purpose: note that it
    # does NOT require readOnlyRootFilesystem. That gap is exactly why the
    # ValidatingAdmissionPolicy exists. Classic exam trap.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
YAML

  cat > "$LAB_DIR/10-policy.yaml" <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: cks-64-require-immutability
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      # NOTE: CREATE only. Admission control is NOT retroactive: a Pod already
      # running when the policy lands keeps running. That is break #2.
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE"]
        resources:   ["pods"]
        scope:       "Namespaced"
  validations:
    - expression: >-
        object.spec.containers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "immutability: every container must set securityContext.readOnlyRootFilesystem: true"
      reason: Forbidden
    - expression: >-
        object.spec.containers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.allowPrivilegeEscalation) &&
          c.securityContext.allowPrivilegeEscalation == false)
      message: "immutability: every container must set securityContext.allowPrivilegeEscalation: false"
      reason: Forbidden
    - expression: >-
        object.spec.containers.all(c,
          c.image.contains(":") && !c.image.endsWith(":latest"))
      message: "immutability: container images must be pinned to an explicit non-:latest tag or a digest"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: cks-64-require-immutability-binding
spec:
  policyName: cks-64-require-immutability
  validationActions: ["Deny"]
  matchResources:
    # Blast radius: this binding can only ever reject Pods in namespaces
    # carrying cks.lab/immutability=enforced.
    namespaceSelector:
      matchLabels:
        cks.lab/immutability: enforced
YAML

  cat > "$LAB_DIR/20-edge-proxy-configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: edge-proxy-conf
  namespace: immutability-lab
data:
  nginx.conf: |
    worker_processes  auto;
    error_log         /dev/stderr warn;
    # The pid file is relocated out of /var/run on purpose: /var/run is a
    # symlink to /run in Alpine, and mounting over symlinks is avoidable pain.
    pid               /tmp/nginx.pid;

    events {
        worker_connections  1024;
    }

    http {
        include       /etc/nginx/mime.types;
        default_type  application/octet-stream;
        access_log    /dev/stdout;
        sendfile      on;
        keepalive_timeout  65;

        # Temp paths keep their compiled-in defaults under /var/cache/nginx.
        # nginx creates them at startup, before it ever binds a socket.

        server {
            listen       8080;   # >1024: no NET_BIND_SERVICE needed
            server_name  localhost;

            location = /healthz {
                access_log off;
                add_header Content-Type text/plain;
                return 200 "ok\n";
            }

            location / {
                root  /usr/share/nginx/html;
                index index.html index.htm;
            }
        }
    }
YAML

  # --- BREAK #1: hardened, policy-compliant, and completely unable to boot ---
  cat > "$LAB_DIR/21-edge-proxy.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-proxy
  namespace: immutability-lab
  labels:
    app: edge-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: edge-proxy
  template:
    metadata:
      labels:
        app: edge-proxy
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 101          # uid of 'nginx' in the official alpine image
        runAsGroup: 101
        fsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            readOnlyRootFilesystem: true      # <-- the whole point of 6.4
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            # ------------------------------------------------------------
            # BROKEN ON PURPOSE: nginx must write to a handful of paths and
            # the root filesystem is read-only. No writable mounts exist.
            # ------------------------------------------------------------
      volumes:
        - name: nginx-conf
          configMap:
            name: edge-proxy-conf
---
apiVersion: v1
kind: Service
metadata:
  name: edge-proxy
  namespace: immutability-lab
spec:
  selector:
    app: edge-proxy
  ports:
    - name: http
      port: 8080
      targetPort: 8080
YAML

  # --- BREAK #2: the legacy, self-mutating workload, applied pre-policy ------
  cat > "$LAB_DIR/22-report-agent.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-agent
  namespace: immutability-lab
  labels:
    app: report-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: report-agent
  template:
    metadata:
      labels:
        app: report-agent
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: agent
          image: alpine:latest          # BROKEN: floating tag, unreproducible
          command: ["/bin/sh", "-c"]
          args:
            - |
              # BROKEN: the container mutates its own image at runtime.
              # In the real world this line is 'apk add --no-cache curl' or
              # 'pip install', or a curl|sh bootstrap. Same anti-pattern:
              # what runs in production is not what you scanned and signed.
              cp /bin/busybox /usr/local/bin/report-tool 2>/dev/null \
                && echo "drift: installed /usr/local/bin/report-tool at runtime"
              mkdir -p /var/log
              while true; do
                status=unreachable
                if wget -q -T 3 -O /dev/null http://edge-proxy:8080/healthz; then
                  status=ok
                fi
                echo "report $(date -u +%FT%TZ) edge-proxy=$status" | tee -a /var/log/report-agent.log
                sleep 20
              done
          # BROKEN: no container securityContext at all -> writable rootfs,
          # privilege escalation allowed, no capability drop.
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
YAML
}

# -----------------------------------------------------------------------------
# Break
# -----------------------------------------------------------------------------
break_lab() {
  write_manifests

  log "creating namespace and config ..."
  kubectl apply -f "$LAB_DIR/00-namespace.yaml" >/dev/null
  kubectl apply -f "$LAB_DIR/20-edge-proxy-configmap.yaml" >/dev/null

  # Order matters: report-agent must be admitted BEFORE the policy exists,
  # otherwise the lesson "admission control is not retroactive" is lost.
  log "deploying the legacy report-agent (pre-policy, deliberately mutable) ..."
  kubectl apply -f "$LAB_DIR/22-report-agent.yaml" >/dev/null
  kubectl -n "$NS" rollout status deploy/report-agent --timeout=180s >/dev/null 2>&1 \
    || warn "report-agent did not become ready in time (image pull?). Continuing."

  if [ "$POLICY_ENFORCED" = "true" ]; then
    log "installing the ValidatingAdmissionPolicy (Deny) ..."
    kubectl apply -f "$LAB_DIR/10-policy.yaml" >/dev/null
    sleep 3   # let the policy compile and propagate to the API servers
  else
    warn "skipping policy installation (API not available on this cluster)."
  fi

  log "deploying edge-proxy (policy-compliant, but it will not start) ..."
  kubectl apply -f "$LAB_DIR/21-edge-proxy.yaml" >/dev/null

  log "waiting for the failure to materialise ..."
  local i state=""
  for i in $(seq 1 40); do
    state="$(kubectl -n "$NS" get pods -l app=edge-proxy \
              -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    [ "$state" = "CrashLoopBackOff" ] && break
    sleep 3
  done

  briefing
}

# -----------------------------------------------------------------------------
# Briefing
# -----------------------------------------------------------------------------
briefing() {
  cat <<'EOF'

===============================================================================
 CKS 6.4 — ENSURE IMMUTABILITY OF CONTAINERS AT RUNTIME — BREAK & FIX
===============================================================================

The cluster now hosts namespace 'immutability-lab' with two problems.
Your editable manifests are in the lab directory printed at the end.

-------------------------------------------------------------------------------
 SYMPTOM #1 — edge-proxy never comes up
-------------------------------------------------------------------------------
  $ kubectl -n immutability-lab get pods
  NAME                          READY   STATUS             RESTARTS   AGE
  edge-proxy-6c9f7d4b58-2ktqd   0/1     CrashLoopBackOff   4          2m
  report-agent-7d4c6f9b7-lm8xq  1/1     Running            0          2m

  $ kubectl -n immutability-lab logs deploy/edge-proxy
  nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)

  Fix that one and the next layer surfaces:

  nginx: [emerg] open() "/tmp/nginx.pid" failed (30: Read-only file system)

  The Deployment is NOT misconfigured from a security standpoint — it is
  exactly what a hardened workload should look like. It is misconfigured from
  an operational standpoint: hardening a rootfs read-only without declaring
  where the process may still write is only half the job.

-------------------------------------------------------------------------------
 SYMPTOM #2 — report-agent is Running and that is the bug
-------------------------------------------------------------------------------
  It was admitted before the policy existed, so it survives while breaking
  every rule. Prove the drift with your own eyes:

  $ kubectl -n immutability-lab exec deploy/report-agent -- ls -l /usr/local/bin/report-tool
  -rwxr-xr-x 1 65532 65532 ... /usr/local/bin/report-tool

  $ kubectl -n immutability-lab exec deploy/report-agent -- touch /usr/bin/backdoor
  (succeeds — the image is being rewritten at runtime)

  Now try to restart it:

  $ kubectl -n immutability-lab rollout restart deploy/report-agent
  $ kubectl -n immutability-lab describe rs -l app=report-agent | grep -A3 FailedCreate
  Warning  FailedCreate  ... Error creating: pods "report-agent-..." is forbidden:
    ValidatingAdmissionPolicy 'cks-64-require-immutability' with binding
    'cks-64-require-immutability-binding' denied request:
    immutability: every container must set securityContext.readOnlyRootFilesystem: true

-------------------------------------------------------------------------------
 YOUR MISSION
-------------------------------------------------------------------------------
  1. edge-proxy: 1/1 Ready and serving /healthz on port 8080 through its
     Service, WITHOUT setting readOnlyRootFilesystem to false and WITHOUT
     granting capabilities back.
  2. report-agent: rolled to a new, admitted Pod that is
       - pinned to an explicit non-:latest tag or a digest,
       - readOnlyRootFilesystem: true, allowPrivilegeEscalation: false,
       - capabilities dropped to ALL,
       - still writing 'edge-proxy=ok' lines,
       - free of runtime drift: /usr/local/bin/report-tool must NOT exist in
         the running container.
  3. The policy, the binding and the namespace label must remain intact and
     the binding must still be validationActions: ["Deny"].
     Deleting the guard is not a fix. Grading detects it.

  Useful reconnaissance:
    kubectl -n immutability-lab get events --sort-by=.lastTimestamp | tail -20
    kubectl -n immutability-lab describe pod -l app=edge-proxy
    kubectl get validatingadmissionpolicy cks-64-require-immutability -o yaml
    kubectl -n immutability-lab exec deploy/report-agent -- mount | grep -E ' / | /tmp '

  Grade yourself:   ./break_fix.sh --verify
  Reset the lab:    ./break_fix.sh --cleanup && ./break_fix.sh --confirm

EOF
  printf ' Lab directory: %s%s%s\n\n' "$BOLD" "$LAB_DIR" "$N"
}

# -----------------------------------------------------------------------------
# Verify — 9 checks
# -----------------------------------------------------------------------------
jp() { kubectl "$@" 2>/dev/null || true; }

verify_lab() {
  local pass=0 fail=0
  _pass() { ok "$1"; pass=$((pass+1)); }
  _fail() { bad "$1"; fail=$((fail+1)); }

  printf '\n%s=== CKS 6.4 grading ===%s\n\n' "$BOLD" "$N"

  # --- anti-cheat -----------------------------------------------------------
  if [ "$POLICY_ENFORCED" = "true" ]; then
    local actions
    actions="$(jp get validatingadmissionpolicybinding "$BINDING" -o jsonpath='{.spec.validationActions[*]}')"
    if jp get validatingadmissionpolicy "$POLICY" -o name | grep -q . && [ "$actions" = "Deny" ]; then
      _pass "1. admission policy still installed with validationActions=[Deny]"
    else
      _fail "1. the policy/binding was removed or downgraded — that is not a fix"
    fi
  else
    warn "1. skipped: ValidatingAdmissionPolicy unsupported on this cluster"
  fi

  local nslabel
  nslabel="$(jp get ns "$NS" -o jsonpath='{.metadata.labels.cks\.lab/immutability}')"
  if [ "$nslabel" = "enforced" ]; then
    _pass "2. namespace still labelled cks.lab/immutability=enforced"
  else
    _fail "2. the namespace label was stripped — enforcement was bypassed"
  fi

  # --- edge-proxy -----------------------------------------------------------
  local ready
  ready="$(jp -n "$NS" get deploy edge-proxy -o jsonpath='{.status.readyReplicas}')"
  if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then
    _pass "3. edge-proxy has ${ready} ready replica(s)"
  else
    _fail "3. edge-proxy has no ready replica (kubectl -n $NS logs deploy/edge-proxy)"
  fi

  local rorfs
  rorfs="$(jp -n "$NS" get pods -l app=edge-proxy --field-selector=status.phase=Running \
            -o jsonpath='{.items[*].spec.containers[*].securityContext.readOnlyRootFilesystem}')"
  if [ -n "$rorfs" ] && ! printf '%s' "$rorfs" | grep -qw false; then
    _pass "4. edge-proxy running containers keep readOnlyRootFilesystem: true"
  else
    _fail "4. edge-proxy is not running with a read-only root filesystem"
  fi

  local eds
  eds="$(jp -n "$NS" get deploy edge-proxy -o jsonpath='{.spec.template.spec.volumes[*].emptyDir}')"
  if [ -n "$eds" ]; then
    _pass "5. edge-proxy declares writable ephemeral volume(s)"
  else
    _fail "5. edge-proxy declares no emptyDir — writable paths must be explicit"
  fi

  local body
  body="$(jp -n "$NS" exec deploy/report-agent -- wget -q -T 5 -O - http://edge-proxy:8080/healthz)"
  if printf '%s' "$body" | grep -q '^ok'; then
    _pass "6. GET http://edge-proxy:8080/healthz returns 'ok' through the Service"
  else
    _fail "6. /healthz is not reachable through the Service (got: '${body:-<empty>}')"
  fi

  # --- report-agent ---------------------------------------------------------
  local aro aape
  aro="$(jp -n "$NS" get pods -l app=report-agent --field-selector=status.phase=Running \
          -o jsonpath='{.items[*].spec.containers[*].securityContext.readOnlyRootFilesystem}')"
  aape="$(jp -n "$NS" get pods -l app=report-agent --field-selector=status.phase=Running \
          -o jsonpath='{.items[*].spec.containers[*].securityContext.allowPrivilegeEscalation}')"
  if [ -n "$aro" ] && ! printf '%s' "$aro" | grep -qw false \
     && [ -n "$aape" ] && ! printf '%s' "$aape" | grep -qw true; then
    _pass "7. report-agent runs read-only with allowPrivilegeEscalation: false"
  else
    _fail "7. the running report-agent Pod is still mutable (roRootFs='$aro' allowPrivEsc='$aape')"
  fi

  local img
  img="$(jp -n "$NS" get pods -l app=report-agent --field-selector=status.phase=Running \
          -o jsonpath='{.items[*].spec.containers[*].image}')"
  if [ -n "$img" ] && ! printf '%s' "$img" | grep -q ':latest' && printf '%s' "$img" | grep -q ':'; then
    _pass "8. report-agent image is pinned ($img)"
  else
    _fail "8. report-agent image is unpinned or floating ('${img:-<none>}')"
  fi

  local drift logs
  drift="$(jp -n "$NS" exec deploy/report-agent -- sh -c 'test -e /usr/local/bin/report-tool && echo present || echo absent')"
  logs="$(jp -n "$NS" logs deploy/report-agent --tail=20)"
  if [ "$drift" = "absent" ] && printf '%s' "$logs" | grep -q 'edge-proxy=ok'; then
    _pass "9. no runtime drift and the agent still reports edge-proxy=ok"
  else
    _fail "9. drift='${drift:-unknown}' and/or the agent is not reporting edge-proxy=ok"
  fi

  printf '\n  %s%d passed%s, %s%d failed%s\n\n' "$G" "$pass" "$N" "$R" "$fail" "$N"
  if [ "$fail" -eq 0 ]; then
    printf ' %sLab complete.%s Read the commented solution at the bottom of this\n' "$BOLD" "$N"
    printf ' script — it covers the production trade-offs the checks cannot grade.\n\n'
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
cleanup_lab() {
  log "removing lab objects ..."
  kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete validatingadmissionpolicybinding "$BINDING" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete validatingadmissionpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  log "done. Namespace deletion finishes in the background."
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
usage() {
  sed -n '/^#  USAGE/,/^# ===/p' "$0" | sed 's/^# \{0,2\}//'
}

main() {
  local action="break"
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) CONFIRMED=1 ;;
      --verify)  action="verify" ;;
      --cleanup) action="cleanup" ;;
      --brief)   action="brief" ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  case "$action" in
    brief)   briefing ;;
    cleanup) CONFIRMED=1; preflight; cleanup_lab ;;
    verify)  CONFIRMED=1; preflight; verify_lab ;;
    break)   preflight; break_lab ;;
  esac
}

main "$@"

# =============================================================================
# =============================================================================
#
#   S O L U T I O N   —   stop reading unless you are done
#
# =============================================================================
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0 — Read the failure instead of guessing
# -----------------------------------------------------------------------------
#   kubectl -n immutability-lab get pods
#   kubectl -n immutability-lab logs deploy/edge-proxy --previous
#
#   nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
#
#   errno 30 (EROFS) is the signature of readOnlyRootFilesystem: true. It is not
#   a permissions problem: chown/chmod/fsGroup/runAsUser will never fix EROFS.
#   The kubelet asked the runtime to mount the container rootfs read-only, so
#   *every* path that is not backed by a volume is immutable, for every uid,
#   including uid 0.
#
#   Find every path the process needs to write. Two reliable methods:
#     a) read the image: `docker run --rm --entrypoint sh nginx:1.27-alpine -c \
#          'nginx -T 2>/dev/null | grep -E "_temp_path|^pid"'`
#     b) run it once WITHOUT the restriction in a scratch namespace and diff:
#          kubectl debug ... / `crictl inspect` / `docker diff <id>`
#   For this image: /var/cache/nginx/* (temp paths) and /tmp/nginx.pid.
#
# -----------------------------------------------------------------------------
# STEP 1 — Fix edge-proxy by DECLARING the writable surface, not by removing
#          the restriction
# -----------------------------------------------------------------------------
#   Edit $LAB_DIR/21-edge-proxy.yaml. Keep the whole securityContext untouched
#   and add two bounded emptyDir volumes:
#
#           volumeMounts:
#             - name: nginx-conf
#               mountPath: /etc/nginx/nginx.conf
#               subPath: nginx.conf
#               readOnly: true
#             - name: cache
#               mountPath: /var/cache/nginx
#             - name: tmp
#               mountPath: /tmp
#       volumes:
#         - name: nginx-conf
#           configMap:
#             name: edge-proxy-conf
#         - name: cache
#           emptyDir:
#             sizeLimit: 64Mi
#         - name: tmp
#           emptyDir:
#             sizeLimit: 16Mi
#
#   Then:
#     kubectl apply -f $LAB_DIR/21-edge-proxy.yaml
#     kubectl -n immutability-lab rollout status deploy/edge-proxy
#     kubectl -n immutability-lab get pods -l app=edge-proxy
#     NAME                          READY   STATUS    RESTARTS   AGE
#     edge-proxy-5f7b9c6d84-x4rzt   1/1     Running   0          12s
#
#   WHY sizeLimit MATTERS: an unbounded emptyDir is node-local disk. Turning a
#   read-only rootfs into "read-only plus an infinite scratch disk" trades a
#   tampering risk for a node-filling DoS. Bound it, and pair it with a
#   `resources.limits.ephemeral-storage` on the container. This is the single
#   most common review finding on hardened manifests.
#
#   WHY emptyDir AND NOT hostPath: emptyDir lives and dies with the Pod, so the
#   filesystem is reset on every restart — the drift window is one Pod lifetime.
#   A hostPath would persist attacker-written files across restarts and leak
#   them to every other Pod that mounts the same path.
#
#   Verify the property actually holds inside the container:
#     kubectl -n immutability-lab exec deploy/edge-proxy -- sh -c 'touch /usr/bin/x'
#     touch: /usr/bin/x: Read-only file system
#     kubectl -n immutability-lab exec deploy/edge-proxy -- mount | grep ' / '
#     overlay on / type overlay (ro,relatime,...)          <-- 'ro' is the proof
#
# -----------------------------------------------------------------------------
# STEP 2 — Understand why report-agent survived
# -----------------------------------------------------------------------------
#   ValidatingAdmissionPolicy (like any admission webhook) runs on the API
#   request path. It has no opinion about objects already stored in etcd. The
#   policy landed after that Pod was admitted, so the Pod persists untouched.
#
#   Consequences worth internalising for the exam and for production:
#     * Rolling out an admission policy does not remediate the fleet. You need
#       a separate detection pass over what is already running.
#     * Audit before you deny. Ship the binding with
#         validationActions: ["Audit", "Warn"]
#       first, read the API server audit annotations
#         validation.policy.admission.k8s.io/validation_failure
#       and only then flip to ["Deny"].
#     * Find the survivors with a plain query — no tooling required:
#         kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{@.securityContext.readOnlyRootFilesystem}{"\t"}{end}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | grep -v '^true'
#
# -----------------------------------------------------------------------------
# STEP 3 — Fix report-agent: pin the image, drop the runtime mutation, harden
# -----------------------------------------------------------------------------
#   Three independent defects, three independent fixes.
#
#   (a) `alpine:latest` is a moving target: the digest behind it changes without
#       notice, so the artifact you scanned, signed and admitted is not the one
#       that runs after the next node restart or image GC. Pin an explicit tag,
#       and prefer a digest — a digest is the only truly immutable reference:
#           image: alpine:3.20
#           # strongest form:
#           # image: alpine@sha256:<64-hex>
#       Get the digest of what you already ran:
#           kubectl -n immutability-lab get pod -l app=report-agent \
#             -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
#       Pair it with `imagePullPolicy: IfNotPresent` (a digest cannot drift) and,
#       in production, an ImagePolicyWebhook / Kyverno rule that rejects any
#       reference that is not a digest.
#
#   (b) The `cp /bin/busybox /usr/local/bin/report-tool` line is the anti-pattern
#       the whole topic exists to kill. Anything a container installs at runtime
#       — apk/apt/pip/npm, a curl|sh bootstrap, a self-updater — is unsigned,
#       unscanned, unreproducible code entering production. Move it into the
#       image build (a Dockerfile layer, reviewed and scanned), or drop it. Here
#       busybox is already in the image, so it is pure waste. Delete the line.
#
#   (c) Add the container securityContext. Note that the *Pod* level context
#       has no readOnlyRootFilesystem field: it is container-scoped only, and
#       must be repeated on every container and initContainer.
#
#   Final manifest — replace the container block in
#   $LAB_DIR/22-report-agent.yaml with:
#
#       containers:
#         - name: agent
#           image: alpine:3.20
#           imagePullPolicy: IfNotPresent
#           command: ["/bin/sh", "-c"]
#           args:
#             - |
#               while true; do
#                 status=unreachable
#                 if wget -q -T 3 -O /dev/null http://edge-proxy:8080/healthz; then
#                   status=ok
#                 fi
#                 echo "report $(date -u +%FT%TZ) edge-proxy=$status" | tee -a /var/log/report-agent.log
#                 sleep 20
#               done
#           securityContext:
#             readOnlyRootFilesystem: true
#             allowPrivilegeEscalation: false
#             capabilities:
#               drop: ["ALL"]
#           resources:
#             requests: { cpu: 10m, memory: 16Mi }
#             limits:   { memory: 64Mi, ephemeral-storage: 64Mi }
#           volumeMounts:
#             - name: varlog
#               mountPath: /var/log
#       volumes:
#         - name: varlog
#           emptyDir:
#             sizeLimit: 32Mi
#
#   Apply and force the old Pod out:
#     kubectl apply -f $LAB_DIR/22-report-agent.yaml
#     kubectl -n immutability-lab rollout status deploy/report-agent
#     kubectl -n immutability-lab logs deploy/report-agent --tail=3
#     report 2026-08-05T12:41:07Z edge-proxy=ok
#
#   Confirm the mutation path is closed:
#     kubectl -n immutability-lab exec deploy/report-agent -- sh -c 'cp /bin/busybox /usr/local/bin/x'
#     cp: can't create '/usr/local/bin/x': Read-only file system
#
#   A sharp detail: writing logs to a file at all is a smell. `tee -a` only
#   exists here to give you something to mount. Log to stdout and let the node
#   agent ship it — then the container needs no writable mount whatsoever, which
#   is the ideal end state for immutability.
#
# -----------------------------------------------------------------------------
# STEP 4 — Grade
# -----------------------------------------------------------------------------
#     ./break_fix.sh --verify        # expect 9 passed, 0 failed
#
# -----------------------------------------------------------------------------
# WHAT THE EXAM ACTUALLY ASKS OF YOU HERE
# -----------------------------------------------------------------------------
#   * readOnlyRootFilesystem is CONTAINER-level. There is no Pod-level version.
#     Miss one sidecar or initContainer and the whole Pod stays writable.
#   * Pod Security Admission 'restricted' does NOT require
#     readOnlyRootFilesystem. It covers privilege escalation, capabilities,
#     runAsNonRoot, seccomp, hostPath/hostNetwork — not rootfs immutability.
#     If a task says "make sure containers cannot be modified at runtime",
#     PSA alone is not the answer; you need the securityContext field, plus a
#     ValidatingAdmissionPolicy / Kyverno / Gatekeeper rule to keep it there.
#   * The immutability triad the graders look for:
#       securityContext:
#         readOnlyRootFilesystem: true
#         allowPrivilegeEscalation: false
#         capabilities: { drop: ["ALL"] }
#     plus runAsNonRoot: true and a pinned, non-:latest image.
#   * readOnlyRootFilesystem does NOT protect mounted volumes. An emptyDir,
#     a ConfigMap mounted read-write, a PVC — all remain writable. Mount
#     ConfigMaps and Secrets with readOnly: true and keep the writable set as
#     small as you can defend.
#   * It also does not stop `kubectl exec`. An attacker with exec rights can
#     still run whatever is already in the image, in memory, from a writable
#     emptyDir. Immutability raises the cost of persistence; it does not
#     replace RBAC on pods/exec, distroless images, or runtime detection
#     (Falco rules on write-below-binary-dir).
#   * Docker/containerd equivalent, for the "how does this work underneath"
#     follow-up: `docker run --read-only --tmpfs /tmp --cap-drop ALL \
#     --security-opt no-new-privileges`. Kubernetes is expressing exactly this.
#
# -----------------------------------------------------------------------------
# SOURCES
# -----------------------------------------------------------------------------
#   CKS Curriculum v1.34 — https://github.com/cncf/curriculum
#   Security context      — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
#   SecurityContext API   — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context-1
#   Validating admission policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
#   Pod Security Standards      — https://kubernetes.io/docs/concepts/security/pod-security-standards/
#   emptyDir / ephemeral volumes — https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
#   Images and pull policy       — https://kubernetes.io/docs/concepts/containers/images/
# =============================================================================