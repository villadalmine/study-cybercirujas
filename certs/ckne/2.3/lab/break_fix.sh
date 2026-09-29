#!/usr/bin/env bash
# =============================================================================
# CKNE - Topic 2.3: Customizing CoreDNS for Services
# Break & Fix lab: "The legacy domain that stopped resolving"
#
# Run this ONLY against a DISPOSABLE lab cluster, such as kubeadm, kind or
# minikube, where CoreDNS is configured by the "coredns" ConfigMap in kube-system.
#
# What it does, in a controlled and reversible way:
#   1. Backs up the current Corefile to a local state directory.
#   2. Creates two namespaces: bf-data, with a ClusterIP Service called orders-db,
#      and bf-app, with a dnsutils client Pod.
#   3. Adds a CoreDNS "rewrite" rule. It is supposed to map
#      <name>.legacy.internal -> <name>.bf-data.svc.cluster.local, but it
#      contains faults.
#   4. Restarts CoreDNS so the broken configuration is live.
#
# Usage:
#   ./breakfix-ckne-2.3.sh break     # set up the scenario and break it (default)
#   ./breakfix-ckne-2.3.sh verify    # check whether you fixed it (exit 0 = fixed)
#   ./breakfix-ckne-2.3.sh restore   # put the original Corefile back
#   ./breakfix-ckne-2.3.sh cleanup   # restore + delete lab namespaces + state
#
# Non-interactive confirmation: BREAKFIX_CONFIRM=yes ./breakfix-ckne-2.3.sh break
#
# Official references:
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
#   https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
#   https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
#   https://coredns.io/plugins/rewrite/
#   https://coredns.io/plugins/reload/
#   https://coredns.io/manual/plugins/  (plugin execution order = plugin.cfg)
# =============================================================================
set -euo pipefail

MODE="${1:-break}"
STATE_DIR="${BREAKFIX_STATE_DIR:-$HOME/.breakfix/ckne-2.3}"
ORIG_COREFILE="$STATE_DIR/Corefile.orig"
BROKEN_COREFILE="$STATE_DIR/Corefile.broken"
MARKER="breakfix-ckne-2.3"
DATA_NS="bf-data"
APP_NS="bf-app"
CLIENT_POD="dnsutils"
DNS_IMAGE="registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

preflight() {
  need kubectl
  need awk
  need grep
  kubectl version --request-timeout=10s >/dev/null 2>&1 \
    || die "cannot reach the API server with the current kubeconfig."
  kubectl -n kube-system get deployment coredns >/dev/null 2>&1 \
    || die "deployment kube-system/coredns not found (this lab expects a kubeadm/kind/minikube-style CoreDNS)."
  kubectl -n kube-system get configmap coredns >/dev/null 2>&1 \
    || die "configmap kube-system/coredns not found."
}

confirm_lab() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo unknown)"
  if printf '%s' "$ctx" | grep -Eiq 'prod|prd|live'; then
    die "current context '$ctx' looks like production. Refusing to run."
  fi
  bold "Current kubectl context: $ctx"
  echo "This lab REWRITES the cluster-wide CoreDNS configuration and restarts CoreDNS."
  echo "It is meant for a disposable lab cluster only."
  if [[ "${BREAKFIX_CONFIRM:-}" != "yes" ]]; then
    read -r -p "Type 'yes' to continue: " answer
    [[ "$answer" == "yes" ]] || die "aborted by user."
  fi
}

current_corefile() {
  kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
}

# Replace only the Corefile key. 'apply' merges, so other keys in the same
# ConfigMap (for example NodeHosts on some distributions) are preserved.
# kubectl may warn about a missing last-applied annotation; that is harmless.
apply_corefile() {
  kubectl -n kube-system create configmap coredns \
    --from-file=Corefile="$1" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
}

restart_coredns() {
  kubectl -n kube-system rollout restart deployment coredns >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=180s >/dev/null
}

create_workloads() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${DATA_NS}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NS}
---
apiVersion: v1
kind: Service
metadata:
  name: orders-db
  namespace: ${DATA_NS}
  labels:
    app.kubernetes.io/part-of: ${MARKER}
spec:
  type: ClusterIP
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
      protocol: TCP
---
apiVersion: v1
kind: Pod
metadata:
  name: ${CLIENT_POD}
  namespace: ${APP_NS}
  labels:
    app.kubernetes.io/part-of: ${MARKER}
spec:
  restartPolicy: Always
  containers:
    - name: dnsutils
      image: ${DNS_IMAGE}
      command: ["sleep", "3600000"]
EOF
  kubectl -n "$APP_NS" wait --for=condition=Ready "pod/$CLIENT_POD" --timeout=180s >/dev/null \
    || die "client pod did not become Ready (image pull problem?)."
}

in_client() {
  kubectl -n "$APP_NS" exec "$CLIENT_POD" -- "$@"
}

do_break() {
  preflight
  confirm_lab
  mkdir -p "$STATE_DIR"

  local live
  live="$(current_corefile)"
  [[ -n "$live" ]] || die "the coredns ConfigMap has no Corefile key."

  if printf '%s\n' "$live" | grep -q "$MARKER"; then
    bold "The scenario is already injected (marker found in the Corefile). Nothing to break again."
    print_briefing
    exit 0
  fi

  printf '%s\n' "$live" | grep -Eq '^\.:53[[:space:]]*\{' \
    || die "Corefile has no '.:53 {' server block; this lab expects the default layout."
  printf '%s\n' "$live" | grep -Eq 'kubernetes[[:space:]]+cluster\.local' \
    || die "Corefile does not serve cluster.local; this lab assumes the default cluster domain."

  if [[ ! -s "$ORIG_COREFILE" ]]; then
    printf '%s\n' "$live" > "$ORIG_COREFILE"
    green "Backed up the original Corefile to $ORIG_COREFILE"
  fi

  echo "Creating lab workloads..."
  create_workloads

  echo "Checking baseline cluster DNS before breaking anything..."
  in_client getent hosts kubernetes.default.svc.cluster.local >/dev/null \
    || die "baseline DNS is already broken in this cluster; fix that first or use a fresh lab."

  # The rewrite stanza, injected right after the '.:53 {' line.
  # Passed through ENVIRON so awk does not interpret the regex backslashes.
  REWRITE_BLOCK="$(cat <<'EOF'
    # breakfix-ckne-2.3: map <name>.legacy.internal to Services in namespace bf-data
    rewrite stop {
        name regex ^([a-z0-9-]+)\.legacy\.internal\.$ {1}.bf-date.svc.cluster.local.
        answer name ^([a-z0-9-]+)\.bf-data\.svc\.cluster\.local\.$ {1}.legacy.internal.
    }
EOF
)"
  export REWRITE_BLOCK

  # Fault 1: namespace typo in the rewrite target (bf-date instead of bf-data).
  # Fault 2: the 'reload' plugin is removed, so ConfigMap edits are never picked up.
  printf '%s\n' "$live" | awk '
    /^[[:space:]]*reload[[:space:]]*$/ { next }
    { print }
    /^\.:53[[:space:]]*\{/ && !done { print ENVIRON["REWRITE_BLOCK"]; done = 1 }
  ' > "$BROKEN_COREFILE"

  apply_corefile "$BROKEN_COREFILE"
  echo "Restarting CoreDNS so the new configuration is live..."
  restart_coredns

  green "Scenario injected."
  print_briefing
}

print_briefing() {
  cat <<EOF

=============================================================================
 SCENARIO
=============================================================================
 The "orders" application in namespace ${APP_NS} still has its legacy
 connection string hard-coded:

     orders-db.legacy.internal:5432

 Nobody can change the application. So the platform team added a rule to
 CoreDNS: any <name>.legacy.internal must resolve to the Service
 <name>.${DATA_NS}.svc.cluster.local, and the answer the client receives must
 carry the legacy name.

 Since the last CoreDNS change, the application cannot connect.

 SYMPTOM YOU WILL SEE
 ---------------------
   \$ kubectl -n ${APP_NS} exec ${CLIENT_POD} -- getent hosts orders-db.legacy.internal
   command terminated with exit code 2

   \$ kubectl -n ${APP_NS} exec ${CLIENT_POD} -- dig +noall +comments orders-db.legacy.internal.
   ;; Got answer:
   ;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: ...

 The Service itself exists and normal cluster DNS still works:
   \$ kubectl -n ${DATA_NS} get svc orders-db
   \$ kubectl -n ${APP_NS} exec ${CLIENT_POD} -- getent hosts orders-db.${DATA_NS}.svc.cluster.local

 YOUR GOAL
 ---------
   1. 'getent hosts orders-db.legacy.internal' inside ${CLIENT_POD} returns
      the ClusterIP of Service ${DATA_NS}/orders-db.
   2. The DNS answer carries the owner name orders-db.legacy.internal.
      (the client asked for it, so that is what it must get back).
   3. Future edits to the coredns ConfigMap must take effect WITHOUT anyone
      restarting CoreDNS by hand.
   4. Regular cluster DNS (kubernetes.default) keeps working.

 RULES
 -----
   - Fix it in the CoreDNS configuration (ConfigMap kube-system/coredns).
     Do not change the application, the Service name or its namespace.
   - Do not delete the rewrite rule; it is a business requirement.

 Check your work:   $0 verify
 Give up / reset:   $0 restore     (original Corefile back)
 Remove everything: $0 cleanup
=============================================================================
EOF
}

do_verify() {
  preflight
  local ok=0 cip got corefile

  kubectl -n "$APP_NS" get pod "$CLIENT_POD" >/dev/null 2>&1 \
    || die "client pod not found; run '$0 break' first."

  cip="$(kubectl -n "$DATA_NS" get svc orders-db -o jsonpath='{.spec.clusterIP}')"
  corefile="$(current_corefile)"

  if printf '%s\n' "$corefile" | grep -Eq '^[[:space:]]*rewrite'; then
    green "PASS  a rewrite rule is present in the Corefile"
  else
    red   "FAIL  the rewrite rule was removed (it is a requirement)"; ok=1
  fi

  if printf '%s\n' "$corefile" | grep -Eq '^[[:space:]]*reload[[:space:]]*$'; then
    green "PASS  the reload plugin is enabled"
  else
    red   "FAIL  the reload plugin is missing: ConfigMap edits will not be applied automatically"; ok=1
  fi

  got="$(in_client getent hosts orders-db.legacy.internal 2>/dev/null | awk '{print $1}' | head -n1 || true)"
  if [[ -n "$got" && "$got" == "$cip" ]]; then
    green "PASS  getent hosts orders-db.legacy.internal -> $got (ClusterIP $cip)"
  else
    red   "FAIL  getent hosts orders-db.legacy.internal -> '${got:-<nothing>}' (expected $cip)"; ok=1
  fi

  if in_client dig +noall +answer orders-db.legacy.internal. A 2>/dev/null \
       | grep -Eq '^orders-db\.legacy\.internal\.[[:space:]]'; then
    green "PASS  the answer owner name is orders-db.legacy.internal."
  else
    red   "FAIL  the DNS answer does not carry the legacy name"; ok=1
  fi

  if in_client getent hosts kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    green "PASS  regular cluster DNS still resolves kubernetes.default"
  else
    red   "FAIL  regular cluster DNS is broken"; ok=1
  fi

  echo
  if [[ $ok -eq 0 ]]; then
    green "All checks passed. Well done."
  else
    red "Not fixed yet. Keep going."
  fi
  return $ok
}

do_restore() {
  preflight
  [[ -s "$ORIG_COREFILE" ]] || die "no backup found at $ORIG_COREFILE; nothing to restore."
  apply_corefile "$ORIG_COREFILE"
  restart_coredns
  green "Original Corefile restored from $ORIG_COREFILE and CoreDNS restarted."
}

do_cleanup() {
  preflight
  if [[ -s "$ORIG_COREFILE" ]]; then
    do_restore
  fi
  kubectl delete namespace "$APP_NS" "$DATA_NS" --ignore-not-found --wait=false >/dev/null
  rm -rf "$STATE_DIR"
  green "Lab namespaces deleted and local state removed."
}

case "$MODE" in
  break)   do_break ;;
  verify)  do_verify ;;
  restore) do_restore ;;
  cleanup) do_cleanup ;;
  *)       die "unknown mode '$MODE' (use: break | verify | restore | cleanup)" ;;
esac

# =============================================================================
# SOLUTION (spoilers: try it yourself first)
# =============================================================================
#
# Step 1: Confirm this is DNS, not the network or the Service.
#   kubectl -n bf-data get svc orders-db                     # the Service exists and has a ClusterIP
#   kubectl -n bf-app exec dnsutils -- getent hosts orders-db.bf-data.svc.cluster.local   # resolves
#   kubectl -n bf-app exec dnsutils -- dig orders-db.legacy.internal.                     # NXDOMAIN
#   The canonical name works but the legacy name does not, so the problem is
#   the name mapping in CoreDNS.
#
# Step 2: Read the configuration CoreDNS is using.
#   kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
#
#   You will find, inside the ".:53 {" block:
#     rewrite stop {
#         name regex ^([a-z0-9-]+)\.legacy\.internal\.$ {1}.bf-date.svc.cluster.local.
#         answer name ^([a-z0-9-]+)\.bf-data\.svc\.cluster\.local\.$ {1}.legacy.internal.
#     }
#   and no "reload" line.
#
#   The query name is rewritten to orders-db.bf-date.svc.cluster.local.
#   Namespace "bf-date" does not exist, so the kubernetes plugin
#   authoritatively answers NXDOMAIN for it. The "answer name" line expects
#   bf-data, so it never matches either.
#
#   Optional: watch it happen. Add "log" to the .:53 block temporarily, then:
#     kubectl -n kube-system logs -l k8s-app=kube-dns -f
#   The log shows the query with its original name and NXDOMAIN as the result.
#
# Step 3: Fix the typo AND bring back the reload plugin.
#   kubectl -n kube-system edit configmap coredns
#
#   The .:53 block should look like this. Keep your cluster's other plugins
#   exactly as they were:
#     .:53 {
#         # breakfix-ckne-2.3: map <name>.legacy.internal to Services in namespace bf-data
#         rewrite stop {
#             name regex ^([a-z0-9-]+)\.legacy\.internal\.$ {1}.bf-data.svc.cluster.local.
#             answer name ^([a-z0-9-]+)\.bf-data\.svc\.cluster\.local\.$ {1}.legacy.internal.
#         }
#         errors
#         health {
#            lameduck 5s
#         }
#         ready
#         kubernetes cluster.local in-addr.arpa ip6.arpa {
#            pods insecure
#            fallthrough in-addr.arpa ip6.arpa
#            ttl 30
#         }
#         prometheus :9153
#         forward . /etc/resolv.conf {
#            max_concurrent 1000
#         }
#         cache 30
#         loop
#         reload
#         loadbalance
#     }
#
# Step 4: The trap. You saved the ConfigMap, waited, and it is still NXDOMAIN.
#   Without the "reload" plugin, CoreDNS never re-reads its Corefile. The
#   kubelet does update the mounted file in each pod (after up to about a
#   minute), but the running process ignores the change. Since the config
#   running right now has no reload, restart CoreDNS this one time:
#     kubectl -n kube-system rollout restart deployment coredns
#     kubectl -n kube-system rollout status deployment coredns
#   With "reload" back, future edits are picked up automatically: the kubelet
#   syncs the ConfigMap to the volume, then reload notices the checksum change
#   (it checks every 30s by default). A syntax error during a reload is logged,
#   and the previous working config stays active.
#
# Step 5: Verify.
#   kubectl -n bf-app exec dnsutils -- getent hosts orders-db.legacy.internal
#   kubectl -n bf-app exec dnsutils -- dig +noall +answer orders-db.legacy.internal.
#     orders-db.legacy.internal. 30 IN A 10.96.x.y
#   ./breakfix-ckne-2.3.sh verify
#
# Why the details matter (exam-relevant mechanics):
#   - The position of "rewrite" inside the block does not matter. CoreDNS runs
#     plugins in the order fixed by plugin.cfg at compile time, and rewrite runs
#     before kubernetes and forward. That is why the rewritten name reaches the
#     kubernetes plugin.
#   - "answer name" rewrites the response back to the name the client asked
#     for. Without it, the answer's owner name (orders-db.bf-data.svc...) does
#     not match the question, and stub resolvers such as glibc may discard it.
#     dig shows an IP while getent/the application fail, which is a classic
#     half-fix.
#   - The regex is anchored with ^...\.$ on the fully qualified name, including
#     the trailing dot. The pod has ndots:5 and search domains, so the resolver
#     first tries names like orders-db.legacy.internal.bf-app.svc.cluster.local.
#     An unanchored regex would also rewrite those search-path expansions.
#   - "stop" ends rewrite processing after this rule matches; "continue" would
#     let later rewrite rules apply as well.
#   - For a whole external zone, rather than a name mapping, the usual tool is
#     a separate server block with "forward" (a stub domain), for example:
#       legacy.internal:53 {
#           errors
#           cache 30
#           forward . 10.0.0.53
#       }
#
# Reset the lab at any time:  ./breakfix-ckne-2.3.sh restore
# Remove everything:          ./breakfix-ckne-2.3.sh cleanup
# =============================================================================