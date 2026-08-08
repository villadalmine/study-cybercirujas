#!/usr/bin/env bash
#
# ==============================================================================
#  ICA 2.2 — Troubleshooting the Mesh Control Plane
#  Break & Fix lab:  "istiod is Ready, but the whole mesh stops converging"
# ==============================================================================
#
#  WHAT THIS DOES
#  --------------
#  It injects ONE controlled, fully reversible fault into the Istio control
#  plane and then hands the cluster to you to diagnose and repair.
#
#  The fault is subtle on purpose: the istiod Deployment stays Running/Ready
#  (green in `kubectl get pods`), yet no sidecar in the mesh can pull xDS
#  configuration anymore. This is the single most important control-plane
#  lesson: "the control plane pod is healthy" and "the control plane is
#  serving config" are NOT the same statement, and pod status will lie to you.
#
#  SAFETY
#  ------
#  - It only edits the `istiod` discovery Service (one field: a targetPort).
#  - It deletes nothing and reinstalls nothing.
#  - The original Service is backed up to disk before the change.
#  - Still: run it ONLY on a disposable lab cluster. It gates on the context.
#
#  Env overrides: ISTIO_NS (default istio-system), BROKEN_TP (default 15099),
#                 BACKUP_DIR (default /tmp/ica-2.2-break-fix), FORCE=1 to skip
#                 the interactive confirmation.
#
#  Sources (official):
#   - Istio, Understand your mesh with istioctl proxy-status:
#       https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
#   - Istio, Diagnose your configuration with istioctl analyze:
#       https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
#   - Istio, Common problems (control plane / injection / sync):
#       https://istio.io/latest/docs/ops/common-problems/
#   - Istio, Ports used by the control plane (15012 = xDS over TLS):
#       https://istio.io/latest/docs/ops/deployment/application-requirements/
#   - CNCF ICA Curriculum:
#       https://github.com/cncf/curriculum
# ==============================================================================

set -euo pipefail

ISTIO_NS="${ISTIO_NS:-istio-system}"
SVC="istiod"
XDS_PORT=15012                       # istiod's xDS-over-TLS port (sidecars dial this)
BROKEN_TP="${BROKEN_TP:-15099}"      # a TCP port istiod does NOT listen on -> connection refused
BACKUP_DIR="${BACKUP_DIR:-/tmp/ica-2.2-break-fix}"

log()  { printf '\n\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

require kubectl
command -v istioctl >/dev/null 2>&1 \
  || warn "istioctl not found on PATH — you will need it to diagnose. Install it before you start troubleshooting."

# ------------------------------------------------------------------ safety gate
CTX="$(kubectl config current-context 2>/dev/null || true)"
[ -n "$CTX" ] || die "no active kubectl context — point KUBECONFIG at your lab cluster first"

log "This lab will DELIBERATELY BREAK the Istio control-plane discovery Service."
log "It is safe and fully reversible, but only run it on a THROWAWAY lab cluster."
log "Active kube-context:  ${CTX}"
log "Istio namespace:      ${ISTIO_NS}"

if [ "${FORCE:-}" != "1" ]; then
  printf '\n'
  read -r -p "Type the context name exactly to confirm this is a disposable lab: " ANSWER
  [ "$ANSWER" = "$CTX" ] || die "confirmation mismatch — aborting, nothing was changed"
fi

# -------------------------------------------------------------------- preflight
kubectl -n "$ISTIO_NS" get deploy istiod >/dev/null 2>&1 \
  || die "istiod Deployment not found in namespace '$ISTIO_NS' (set ISTIO_NS=... if your install differs)"
kubectl -n "$ISTIO_NS" get svc "$SVC" >/dev/null 2>&1 \
  || die "Service '$SVC' not found in namespace '$ISTIO_NS'"

mkdir -p "$BACKUP_DIR"
kubectl -n "$ISTIO_NS" get svc "$SVC" -o yaml > "$BACKUP_DIR/${SVC}-svc.orig.yaml"

ORIG_TP="$(kubectl -n "$ISTIO_NS" get svc "$SVC" \
             -o jsonpath="{.spec.ports[?(@.port==$XDS_PORT)].targetPort}")"
[ -n "$ORIG_TP" ] || die "could not locate xDS port $XDS_PORT on Service '$SVC' — is this a standard install?"
printf '%s\n' "$ORIG_TP" > "$BACKUP_DIR/${SVC}-xds-targetPort.orig"

log "Backup written:"
log "  full Service YAML   -> $BACKUP_DIR/${SVC}-svc.orig.yaml"
log "  original targetPort -> $BACKUP_DIR/${SVC}-xds-targetPort.orig  (value: $ORIG_TP)"

# --------------------------------------------------------------------- the break
# Strategic-merge patch (default type). spec.ports merges by the `port` key, so
# ONLY the 15012 entry's targetPort is rewritten; every other port is preserved.
log "Injecting fault: ${SVC}:${XDS_PORT} targetPort ${ORIG_TP} -> ${BROKEN_TP} (a dead port)."
kubectl -n "$ISTIO_NS" patch svc "$SVC" \
  -p "{\"spec\":{\"ports\":[{\"port\":${XDS_PORT},\"targetPort\":${BROKEN_TP}}]}}"

# Force every sidecar (and istioctl-visible proxy) to re-establish its xDS stream,
# so the symptom is immediate and mesh-wide instead of drifting in slowly.
log "Rolling istiod so all proxies must reconnect through the (now broken) Service…"
kubectl -n "$ISTIO_NS" rollout restart deploy/istiod
kubectl -n "$ISTIO_NS" rollout status  deploy/istiod --timeout=120s || true

# ----------------------------------------------------------------- the briefing
cat <<'BRIEF'

================================================================================
  FAULT INJECTED — the mesh is now broken. Your shift starts here.
================================================================================

THE STORY
  A change window "touched networking" and now the platform team reports:
  new deployments come up but their traffic misbehaves, and no configuration
  change (VirtualService, DestinationRule, mTLS mode) seems to take effect.
  Nobody restarted istiod on purpose. istiod "looks fine".

WHAT YOU WILL OBSERVE
  * kubectl -n istio-system get pods         -> istiod is Running and READY (1/1).
  * istioctl proxy-status                    -> proxies are STALE / NOT SENT, or
                                                newly started proxies never appear
                                                (they can't complete the xDS
                                                handshake). If proxy-status itself
                                                errors out trying to reach istiod,
                                                that is ALSO a clue, not a dead end.
  * Sidecar (istio-proxy) container logs     -> repeated messages about the xDS /
                                                ADS gRPC stream being closed or the
                                                connection to istiod:15012 being
                                                "connection refused".
  * Any new VirtualService/DestinationRule   -> accepted by the API server but
                                                never reflected in Envoy config.

YOUR OBJECTIVE (definition of done)
  Restore control-plane config distribution WITHOUT deleting or reinstalling
  Istio, so that:
    1) `istioctl proxy-status`  reports every proxy as SYNCED, and
    2) `istioctl analyze -A`    reports no problems, and
    3) a fresh config change actually reaches the sidecars.

RULES OF ENGAGEMENT
  * The istiod Pod, Deployment, and image are NOT the fault. Resist the urge to
    `kubectl delete pod istiod` and call it fixed — that will not help.
  * The fault is a single misconfigured field somewhere between the sidecars and
    istiod's listening socket. Find the layer, not just the symptom.

FIRST MOVES (safe, read-only)
  kubectl -n istio-system get pods -l app=istiod
  istioctl proxy-status
  kubectl -n istio-system logs deploy/istiod --tail=50
  kubectl get pods -A -l 'security.istio.io/tlsMode' -o wide   # find a sidecar to inspect

  A backup of the original Service is in:  $BACKUP_DIR
  (so even if you get lost, the ground truth of "what it should be" is on disk).

  Good luck. Do not scroll to the bottom of this script until you have tried.
================================================================================

BRIEF

exit 0

# ==============================================================================
#  ▼▼▼  SOLUTION — read only after you have attempted the diagnosis  ▼▼▼
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  The `istiod` Service's xDS port (spec.ports[port==15012]) had its
#  `targetPort` repointed from 15012 to a port istiod does not listen on
#  (15099). Envoy sidecars dial the Service at istiod.istio-system.svc:15012;
#  kube-proxy dutifully forwards those SYNs to podIP:15099, where nothing is
#  listening, so the pod resets the connection. Result: every sidecar's ADS
#  stream fails with "connection refused", no proxy can pull config, and the
#  mesh silently stops converging — while istiod's readiness probe (a different
#  port/path on the pod) stays green. This is why Pod status alone is a trap.
#
#  WHY istioctl proxy-status may still work
#  ----------------------------------------
#  `istioctl proxy-status`/`proxy-config` port-forward to the istiod POD
#  directly, bypassing the Service. So istioctl can still talk to istiod and
#  show you that the *sidecars* are stale — even though the *sidecars* cannot.
#  That asymmetry (istioctl works, Envoys don't) is the fingerprint of a
#  Service-layer fault rather than an istiod-process fault.
#
#  STEP-BY-STEP DIAGNOSIS
#  ----------------------
#  1) Confirm the control-plane process is actually healthy (rule out the pod):
#       kubectl -n istio-system get pods -l app=istiod
#       kubectl -n istio-system logs deploy/istiod --tail=100 | \
#         grep -iE 'error|panic|readiness|listen' || true
#     istiod is Ready and its logs show it listening — so the process is fine.
#
#  2) Ask the mesh whether config is flowing:
#       istioctl proxy-status
#     Proxies show STALE / NOT SENT, or restarted proxies are missing entirely.
#
#  3) Look from a data-plane sidecar's point of view (the connection refused):
#       POD=$(kubectl get pods -A -l 'security.istio.io/tlsMode=istio' \
#               -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}')
#       NS=${POD%/*}; NAME=${POD#*/}
#       kubectl -n "$NS" logs "$NAME" -c istio-proxy --tail=50 | \
#         grep -iE 'ads|xds|connect|refused|StreamAggregatedResources'
#     You will see the ADS gRPC stream to istiod:15012 being closed / refused.
#
#  4) The process is up but the port is unreachable -> suspect the Service.
#     Compare the advertised port to the port istiod actually listens on:
#       kubectl -n istio-system get svc istiod \
#         -o jsonpath='{range .spec.ports[*]}{.name}{"  port="}{.port}{"  target="}{.targetPort}{"\n"}{end}'
#     The 15012 line shows target=15099 — istiod does not listen on 15099.
#     Cross-check what istiod truly listens on (should include 15012):
#       kubectl -n istio-system exec deploy/istiod -c discovery -- \
#         sh -c 'netstat -tlnp 2>/dev/null || ss -tlnp' | grep -E '15012|15099' || true
#
#  THE FIX (pick one)
#  ------------------
#  A) Targeted repair — put the xDS targetPort back to 15012:
#       kubectl -n istio-system patch svc istiod \
#         -p '{"spec":{"ports":[{"port":15012,"targetPort":15012}]}}'
#
#  B) Or restore the backed-up Service verbatim:
#       kubectl -n istio-system apply -f "$BACKUP_DIR/istiod-svc.orig.yaml"
#
#  RECONVERGE + VERIFY
#  -------------------
#  5) Sidecars auto-reconnect within seconds; nudge any stubborn ones:
#       kubectl -n istio-system rollout restart deploy/istiod   # (optional)
#       # or bounce a specific stuck workload:
#       # kubectl -n "$NS" rollout restart deploy/<app>
#
#  6) Prove config distribution is healthy again:
#       istioctl proxy-status            # every proxy -> SYNCED
#       istioctl analyze -A              # No validation issues found
#
#  7) Prove a NEW change now actually reaches Envoy (end-to-end):
#       istioctl proxy-config listeners "$NAME.$NS" --port 15012 >/dev/null 2>&1 || true
#       # apply any trivial DestinationRule and confirm it appears in the proxy:
#       # istioctl proxy-config route "$NAME.$NS" | grep <your-host>
#
#  TAKEAWAYS FOR THE EXAM
#  ----------------------
#  * "istiod Ready" != "istiod serving config". Always corroborate with
#    `istioctl proxy-status`; SYNCED across all proxies is the real health signal.
#  * Sidecars reach istiod through the `istiod` Service on 15012 (xDS/TLS);
#    istioctl port-forwards to the pod. A Service/port fault breaks the first
#    path and not the second — that split is your localization signal.
#  * The control-plane failure surface is layered: process -> Service/Endpoints
#    -> mutating webhook (15017) -> RBAC/watch permissions -> mesh ConfigMap.
#    Walk the layers; don't stop at the first green checkmark.
#
#  RESET / CLEANUP (leave the lab pristine)
#  ----------------------------------------
#       kubectl -n istio-system apply -f "$BACKUP_DIR/istiod-svc.orig.yaml"
#       istioctl proxy-status && istioctl analyze -A
# ==============================================================================