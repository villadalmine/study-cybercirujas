#!/usr/bin/env bash
# =============================================================================
# CKNE - Topic 3.1: Optimizing LLM Traffic
# BREAK & FIX LAB: "The gateway that treats tokens like web pages"
# =============================================================================
#
# RUN THIS ONLY ON A DISPOSABLE LAB CLUSTER (kind, k3d, minikube, k3s in a VM).
# Everything is created in a dedicated namespace. Nothing outside it is touched.
#
# Usage:
#   ./break-fix-3.1-llm-traffic.sh break     # deploy the lab and inject the faults (default)
#   ./break-fix-3.1-llm-traffic.sh verify    # check whether you have fixed it
#   ./break-fix-3.1-llm-traffic.sh cleanup   # delete the namespace and everything in it
#
# Requirements: kubectl pointing at a lab cluster that can pull public images
# (python:3.12-slim, envoyproxy/envoy, curlimages/curl).
#
# ------------------------------------------------------------------------------
# SCENARIO
# ------------------------------------------------------------------------------
# A platform team put a plain Envoy proxy ("llm-gateway") in front of three
# replicas of an OpenAI-compatible inference server ("llm-backend"). The
# backend is a CPU-only simulator that behaves like a real LLM server:
#
#   * Prefill:    ~2.0 s on a prefix-cache MISS, ~0.1 s on a HIT. The cache is
#                 per pod, keyed by the conversation (header x-session-id),
#                 like vLLM's automatic prefix caching of the KV cache.
#   * Decode:     one token every ~0.8 s, streamed as Server-Sent Events when
#                 "stream": true, or returned in one response when not.
#   * /metrics:   per-pod prefix-cache hits and misses.
#
# The gateway was configured with the same defaults the team uses for its REST
# APIs. For LLM traffic that config is wrong in two ways. Your job is to find
# out how, using the symptoms and Envoy's own admin interface.
#
# ------------------------------------------------------------------------------
# SYMPTOMS YOU WILL SEE
# ------------------------------------------------------------------------------
#   1. Any generation longer than a few tokens fails:
#        - non-streaming:  HTTP 504, body "upstream request timeout"
#        - streaming:      the SSE stream starts, delivers a few tokens, then
#                          the connection is cut and "data: [DONE]" never arrives
#   2. A multi-turn conversation (same x-session-id on every request) keeps
#      landing on different pods. Almost every turn is a prefix-cache MISS, so
#      time-to-first-token (TTFT) stays at ~2 s instead of ~0.1 s. The GPUs
#      (here: simulated) redo prefill work they already did.
#
# ------------------------------------------------------------------------------
# WHAT YOU MUST ACHIEVE
# ------------------------------------------------------------------------------
#   A. Long generations complete, streaming and non-streaming, WITHOUT simply
#      removing every protection: a backend that stops sending tokens must
#      still be cut off (an idle timeout between chunks, not a total cap).
#   B. Requests carrying the same x-session-id are consistently routed to the
#      same backend pod, so turns 2..N are prefix-cache HITs.
#   C. "./break-fix-3.1-llm-traffic.sh verify" reports every check as PASS.
#
# Do NOT change the backend Deployment or the simulator code. The fault is in
# the traffic layer, and so is the fix.
#
# Useful commands to start investigating:
#   kubectl -n ckne-llm-lab get pods -o wide
#   kubectl -n ckne-llm-lab get configmap envoy-config -o yaml
#   kubectl -n ckne-llm-lab exec client -- curl -s -i -X POST \
#     http://llm-gateway/v1/completions -H 'content-type: application/json' \
#     -d '{"prompt":"hello","max_tokens":8}'
#   kubectl -n ckne-llm-lab exec client -- curl -sN -X POST \
#     http://llm-gateway/v1/completions -H 'content-type: application/json' \
#     -H 'x-session-id: demo' -d '{"prompt":"hello","max_tokens":8,"stream":true}'
#   kubectl -n ckne-llm-lab port-forward deploy/llm-gateway 9901:9901
#     then: curl -s localhost:9901/config_dump | less
#           curl -s localhost:9901/stats | grep -E 'rq_timeout|rq_total|upstream_rq_5xx'
#           curl -s localhost:9901/clusters | grep llm-backends
#   kubectl -n ckne-llm-lab exec client -- sh -c \
#     'for ip in $(nslookup llm-backend-headless | awk "/^Address: /{print \$2}"); do curl -s $ip:8000/metrics; done'
#
# Official references:
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto
#   https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/timeouts
#   https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/load_balancers
#   https://gateway-api.sigs.k8s.io/reference/api-types/httproute/
#   https://gateway-api-inference-extension.sigs.k8s.io/
#   https://docs.vllm.ai/en/latest/design/prefix_caching.html
# =============================================================================

set -euo pipefail

NS="ckne-llm-lab"
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.33-latest}"
PYTHON_IMAGE="${PYTHON_IMAGE:-python:3.12-slim}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
MODE="${1:-break}"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
info() { echo "${BOLD}==>${RESET} $*"; }
warn() { echo "${YELLOW}WARN:${RESET} $*"; }
die()  { echo "${RED}ERROR:${RESET} $*" >&2; exit 1; }
kc()   { kubectl -n "$NS" "$@"; }

TMPDIR_LAB="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LAB"' EXIT

# -----------------------------------------------------------------------------
# Safety guard: refuse to run against anything that does not look like a lab.
# -----------------------------------------------------------------------------
lab_guard() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "No current kubectl context."
  case "$ctx" in
    kind-*|k3d-*|minikube|*lab*|default|docker-desktop|rancher-desktop) ;;
    *)
      if [[ "${I_UNDERSTAND_THIS_IS_A_LAB:-}" != "yes" ]]; then
        die "Context '$ctx' does not look like a lab cluster. If it really is disposable, re-run with I_UNDERSTAND_THIS_IS_A_LAB=yes"
      fi
      ;;
  esac
  kubectl version --request-timeout=10s >/dev/null 2>&1 || die "Cannot reach the API server for context '$ctx'."
  info "Using kubectl context: ${BOLD}$ctx${RESET}"
}

# -----------------------------------------------------------------------------
# The inference server simulator (OpenAI-style /v1/completions).
# -----------------------------------------------------------------------------
write_simulator() {
  cat > "$TMPDIR_LAB/server.py" <<'PYEOF'
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POD = os.environ.get("POD_NAME", "unknown")
PREFILL_MISS = float(os.environ.get("PREFILL_MISS_SECONDS", "2.0"))
PREFILL_HIT = float(os.environ.get("PREFILL_HIT_SECONDS", "0.1"))
TOKEN_DELAY = float(os.environ.get("TOKEN_DELAY_SECONDS", "0.8"))
MAX_TOKENS_CAP = 64

prefix_cache = set()
stats = {"hits": 0, "misses": 0, "requests": 0}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-llm/1.0"

    def log_message(self, fmt, *args):
        print("%s %s" % (POD, fmt % args), flush=True)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            return self._json(200, {"ok": True, "pod": POD})
        if self.path == "/metrics":
            with lock:
                s = dict(stats)
                size = len(prefix_cache)
            lines = [
                'mock_prefix_cache_hits_total{pod="%s"} %d' % (POD, s["hits"]),
                'mock_prefix_cache_misses_total{pod="%s"} %d' % (POD, s["misses"]),
                'mock_prefix_cache_entries{pod="%s"} %d' % (POD, size),
                'mock_requests_total{pod="%s"} %d' % (POD, s["requests"]),
            ]
            body = ("\n".join(lines) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/completions":
            return self._json(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._json(400, {"error": "invalid JSON"})

        prompt = str(req.get("prompt", ""))
        session = self.headers.get("x-session-id") or prompt[:32]
        max_tokens = max(1, min(int(req.get("max_tokens", 8)), MAX_TOKENS_CAP))
        stream = bool(req.get("stream", False))

        with lock:
            hit = session in prefix_cache
            prefix_cache.add(session)
            stats["requests"] += 1
            stats["hits" if hit else "misses"] += 1
        prefill = PREFILL_HIT if hit else PREFILL_MISS

        if stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                time.sleep(prefill)
                for i in range(max_tokens):
                    chunk = {"served_by": POD, "cache_hit": hit, "index": i, "text": "tok%d " % i}
                    self.wfile.write(("data: %s\n\n" % json.dumps(chunk)).encode())
                    self.wfile.flush()
                    time.sleep(TOKEN_DELAY)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                print("%s client went away mid-stream (session=%s)" % (POD, session), flush=True)
            return

        time.sleep(prefill + TOKEN_DELAY * max_tokens)
        self._json(200, {
            "served_by": POD,
            "cache_hit": hit,
            "ttft_seconds": prefill,
            "text": " ".join("tok%d" % i for i in range(max_tokens)),
            "usage": {"completion_tokens": max_tokens},
        })


if __name__ == "__main__":
    print("%s mock LLM listening on :8000" % POD, flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
PYEOF
}

# -----------------------------------------------------------------------------
# BROKEN Envoy config: REST-API defaults applied to LLM traffic.
#   - route timeout 5s        -> total cap on the whole response, streaming included
#   - lb_policy ROUND_ROBIN   -> ignores conversation identity, kills cache locality
# -----------------------------------------------------------------------------
write_broken_envoy() {
  cat > "$TMPDIR_LAB/envoy.yaml" <<EOF
admin:
  address:
    socket_address:
      address: 0.0.0.0
      port_value: 9901
static_resources:
  listeners:
  - name: llm_listener
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8080
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: llm
          route_config:
            name: llm_routes
            virtual_hosts:
            - name: llm
              domains:
              - "*"
              routes:
              - match:
                  prefix: "/v1/"
                route:
                  cluster: llm-backends
                  timeout: 5s
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: llm-backends
    type: STRICT_DNS
    dns_lookup_family: V4_ONLY
    dns_refresh_rate: 5s
    connect_timeout: 2s
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: llm-backends
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: llm-backend-headless.${NS}.svc.cluster.local
                port_value: 8000
EOF
}

write_manifests() {
  cat > "$TMPDIR_LAB/lab.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-backend
  namespace: ${NS}
  labels:
    app: llm-backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: llm-backend
  template:
    metadata:
      labels:
        app: llm-backend
    spec:
      containers:
      - name: server
        image: ${PYTHON_IMAGE}
        command:
        - python
        - /app/server.py
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: PYTHONUNBUFFERED
          value: "1"
        ports:
        - name: http
          containerPort: 8000
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8000
          periodSeconds: 3
        resources:
          requests:
            cpu: 20m
            memory: 32Mi
          limits:
            memory: 128Mi
        volumeMounts:
        - name: app
          mountPath: /app
      volumes:
      - name: app
        configMap:
          name: llm-simulator
---
apiVersion: v1
kind: Service
metadata:
  name: llm-backend-headless
  namespace: ${NS}
spec:
  clusterIP: None
  selector:
    app: llm-backend
  ports:
  - name: http
    port: 8000
    targetPort: 8000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-gateway
  namespace: ${NS}
  labels:
    app: llm-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llm-gateway
  template:
    metadata:
      labels:
        app: llm-gateway
    spec:
      containers:
      - name: envoy
        image: ${ENVOY_IMAGE}
        args:
        - "-c"
        - /etc/envoy/envoy.yaml
        - "--log-level"
        - info
        ports:
        - name: http
          containerPort: 8080
        - name: admin
          containerPort: 9901
        readinessProbe:
          httpGet:
            path: /ready
            port: 9901
          periodSeconds: 3
        resources:
          requests:
            cpu: 20m
            memory: 64Mi
          limits:
            memory: 256Mi
        volumeMounts:
        - name: config
          mountPath: /etc/envoy
      volumes:
      - name: config
        configMap:
          name: envoy-config
---
apiVersion: v1
kind: Service
metadata:
  name: llm-gateway
  namespace: ${NS}
spec:
  selector:
    app: llm-gateway
  ports:
  - name: http
    port: 80
    targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: ${NS}
  labels:
    app: client
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: curl
    image: ${CURL_IMAGE}
    command:
    - sh
    - "-c"
    - "while true; do sleep 3600; done"
EOF
}

do_break() {
  lab_guard
  info "Creating namespace ${NS}"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  write_simulator
  write_broken_envoy
  write_manifests

  info "Loading the LLM simulator and the (broken) gateway config"
  kubectl -n "$NS" create configmap llm-simulator --from-file=server.py="$TMPDIR_LAB/server.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" create configmap envoy-config --from-file=envoy.yaml="$TMPDIR_LAB/envoy.yaml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  info "Deploying backends, gateway and client"
  kubectl apply -f "$TMPDIR_LAB/lab.yaml" >/dev/null
  kc rollout restart deploy/llm-gateway >/dev/null 2>&1 || true

  info "Waiting for rollout (image pulls may take a minute)"
  kc rollout status deploy/llm-backend --timeout=240s
  kc rollout status deploy/llm-gateway --timeout=240s
  kc wait --for=condition=Ready pod/client --timeout=180s >/dev/null

  sleep 6  # give Envoy's STRICT_DNS a refresh cycle to see all three pods

  cat <<EOF

${BOLD}${RED}The lab is broken.${RESET}

Try it yourself:

  # 1) A normal 8-token completion through the gateway
  kubectl -n ${NS} exec client -- curl -s -i -X POST http://llm-gateway/v1/completions \\
    -H 'content-type: application/json' -d '{"prompt":"explain eBPF","max_tokens":8}'

  # 2) The same, streamed
  kubectl -n ${NS} exec client -- curl -sN -X POST http://llm-gateway/v1/completions \\
    -H 'content-type: application/json' -H 'x-session-id: chat-1' \\
    -d '{"prompt":"explain eBPF","max_tokens":8,"stream":true}'

  # 3) Five turns of one conversation - look at served_by and cache_hit
  for i in 1 2 3 4 5; do kubectl -n ${NS} exec client -- curl -s -X POST \\
    http://llm-gateway/v1/completions -H 'content-type: application/json' \\
    -H 'x-session-id: chat-2' -d '{"prompt":"turn","max_tokens":1}'; echo; done

Goals: see the header of this script (A, B, C).
When you think you are done:  $0 verify
EOF
}

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
PASS=0; FAIL=0
check() {
  if [[ "$1" == "ok" ]]; then echo "  ${GREEN}PASS${RESET}  $2"; PASS=$((PASS + 1))
  else echo "  ${RED}FAIL${RESET}  $2"; FAIL=$((FAIL + 1)); fi
}

do_verify() {
  lab_guard
  kc get pod client >/dev/null 2>&1 || die "Lab not deployed. Run: $0 break"
  kc rollout status deploy/llm-gateway --timeout=120s >/dev/null
  kc rollout status deploy/llm-backend --timeout=120s >/dev/null

  local url="http://llm-gateway/v1/completions"
  local sid="verify-$RANDOM-$RANDOM"

  info "Check 1: long non-streaming completion (16 tokens, ~15 s)"
  local code
  code="$(kc exec client -- curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X POST "$url" \
    -H 'content-type: application/json' -H "x-session-id: ${sid}-a" \
    -d '{"prompt":"long answer","max_tokens":16}' || true)"
  [[ "$code" == "200" ]] && check ok "non-streaming 16-token completion returned 200" \
                         || check fail "non-streaming 16-token completion returned '${code}' (expected 200)"

  info "Check 2: long streaming completion (16 tokens) reaches [DONE]"
  local out
  out="$(kc exec client -- curl -sN --max-time 90 -X POST "$url" \
    -H 'content-type: application/json' -H "x-session-id: ${sid}-b" \
    -d '{"prompt":"long stream","max_tokens":16,"stream":true}' || true)"
  local chunks
  chunks="$(grep -c '^data: {' <<<"$out" || true)"
  if grep -q '\[DONE\]' <<<"$out" && [[ "$chunks" -eq 16 ]]; then
    check ok "stream delivered 16/16 tokens and [DONE]"
  else
    check fail "stream delivered ${chunks}/16 tokens, [DONE] $(grep -q '\[DONE\]' <<<"$out" && echo present || echo missing)"
  fi

  info "Check 3: a backend that goes silent is still cut off (idle timeout, not unlimited)"
  local route_cfg
  route_cfg="$(kc get configmap envoy-config -o jsonpath='{.data.envoy\.yaml}')"
  if grep -Eq '^[[:space:]]*(idle_timeout|stream_idle_timeout):[[:space:]]*[0-9]+(\.[0-9]+)?s' <<<"$route_cfg" \
     && ! grep -Eq '^[[:space:]]*(idle_timeout|stream_idle_timeout):[[:space:]]*0s' <<<"$route_cfg"; then
    check ok "a non-zero idle timeout is configured"
  else
    check fail "no non-zero idle_timeout / stream_idle_timeout found - removing every timeout is not a fix"
  fi

  info "Check 4: session affinity - 6 turns of one conversation"
  local pods=() hits=0 line pod hit
  for _ in 1 2 3 4 5 6; do
    line="$(kc exec client -- curl -s --max-time 30 -X POST "$url" \
      -H 'content-type: application/json' -H "x-session-id: ${sid}-c" \
      -d '{"prompt":"turn","max_tokens":1}' || true)"
    pod="$(sed -n 's/.*"served_by": *"\([^"]*\)".*/\1/p' <<<"$line")"
    hit="$(sed -n 's/.*"cache_hit": *\(true\|false\).*/\1/p' <<<"$line")"
    pods+=("${pod:-ERROR}")
    [[ "$hit" == "true" ]] && hits=$((hits + 1))
  done
  local unique
  unique="$(printf '%s\n' "${pods[@]}" | sort -u | wc -l)"
  echo "        served_by: ${pods[*]}"
  [[ "$unique" -eq 1 && "${pods[0]}" != "ERROR" ]] \
    && check ok "all 6 turns served by the same pod" \
    || check fail "turns spread across ${unique} pods"
  [[ "$hits" -eq 5 ]] \
    && check ok "turns 2..6 were prefix-cache hits (5/5)" \
    || check fail "prefix-cache hits on turns 2..6: ${hits}/5"

  info "Check 5: different sessions still spread across backends"
  local spread=()
  for n in $(seq 1 12); do
    line="$(kc exec client -- curl -s --max-time 30 -X POST "$url" \
      -H 'content-type: application/json' -H "x-session-id: ${sid}-spread-${n}" \
      -d '{"prompt":"p","max_tokens":1}' || true)"
    spread+=("$(sed -n 's/.*"served_by": *"\([^"]*\)".*/\1/p' <<<"$line")")
  done
  unique="$(printf '%s\n' "${spread[@]}" | grep -v '^$' | sort -u | wc -l)"
  [[ "$unique" -ge 2 ]] \
    && check ok "12 distinct sessions landed on ${unique} pods (not pinned to one)" \
    || check fail "12 distinct sessions all landed on ${unique} pod(s) - affinity must be per session, not global"

  echo
  if [[ "$FAIL" -eq 0 ]]; then
    echo "${GREEN}${BOLD}All ${PASS} checks passed. LLM traffic is optimized.${RESET}"
  else
    echo "${RED}${BOLD}${FAIL} check(s) failed, ${PASS} passed.${RESET} Keep digging (hint: Envoy admin on :9901)."
    exit 1
  fi
}

do_cleanup() {
  lab_guard
  info "Deleting namespace ${NS}"
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  info "Done."
}

case "$MODE" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *) die "Unknown mode '$MODE'. Use: break | verify | cleanup" ;;
esac

# =============================================================================
# SOLUTION (spoilers - try first!)
# =============================================================================
#
# --- Step 1: reproduce and read the evidence -------------------------------
#
#   Non-streaming, 8 tokens:
#     HTTP/1.1 504 Gateway Timeout
#     upstream request timeout
#   The response body is written by Envoy itself, not by the backend. Envoy's
#   stats confirm it:
#     kubectl -n ckne-llm-lab port-forward deploy/llm-gateway 9901:9901 &
#     curl -s localhost:9901/stats | grep upstream_rq_timeout
#       cluster.llm-backends.upstream_rq_timeout: 3
#
#   Streaming: tokens 0..3 arrive and then the connection drops (curl: (18)
#   transfer closed ...). Once response headers are sent, Envoy cannot turn a
#   timeout into a 504, so it resets the stream instead.
#
#   Backend logs show the other side of it:
#     kubectl -n ckne-llm-lab logs deploy/llm-backend | grep "went away"
#
# --- Step 2: understand fault #1 (timeouts) ----------------------------------
#
#   route.timeout is a TOTAL deadline: from the end of the downstream request
#   until the upstream response is COMPLETE. When unset, Envoy uses 15s.
#   For REST that is sensible. For an LLM the response length scales with
#   max_tokens: 2 s prefill + 16 tokens x 0.8 s = ~15 s here, and minutes with
#   real reasoning models. Any fixed total cap will eventually truncate a
#   legitimate answer.
#
#   The correct shape for token streams is:
#     - no total cap (timeout: 0s disables it), and
#     - an IDLE timeout: the maximum silence allowed between bytes. A healthy
#       generation sends a token every few hundred ms. A hung GPU worker
#       sends nothing, and gets cut off.
#   The route-level idle_timeout overrides the HTTP connection manager's
#   stream_idle_timeout (default 5 min) for that route.
#
#   Note that the non-streaming request is silent until it completes, so the
#   idle timeout must exceed the longest non-streaming generation you accept.
#   This is one more reason to stream LLM responses.
#
# --- Step 3: understand fault #2 (load balancing) ----------------------------
#
#   curl -s localhost:9901/clusters | grep -E 'llm-backends::[0-9.]+:8000::rq_total'
#   shows three hosts with near-identical counts: ROUND_ROBIN at work.
#
#   Per-pod /metrics shows the cost:
#     kubectl -n ckne-llm-lab exec client -- sh -c \
#       'for ip in $(nslookup llm-backend-headless | awk "/^Address: /{print \$2}"); do curl -s $ip:8000/metrics; done'
#   Misses dominate and every pod caches the same conversations.
#
#   An inference server's KV cache is local to the pod. Turn N of a
#   conversation shares its whole prefix with turn N-1, so sending it to the
#   same pod skips prefill (TTFT drops from ~2 s to ~0.1 s here, and saves
#   GPU FLOPs in production). Round-robin and least-request are
#   cache-oblivious. A consistent hash on the conversation identity gives
#   affinity, and a consistent ring keeps most sessions in place when a pod
#   is added or removed.
#
# --- Step 4: apply the fix ---------------------------------------------------
#
#   kubectl -n ckne-llm-lab edit configmap envoy-config
#
#   Route section, from:
#                 route:
#                   cluster: llm-backends
#                   timeout: 5s
#   to:
#                 route:
#                   cluster: llm-backends
#                   timeout: 0s
#                   idle_timeout: 30s
#                   hash_policy:
#                   - header:
#                       header_name: x-session-id
#
#   Cluster section, from:
#     lb_policy: ROUND_ROBIN
#   to:
#     lb_policy: RING_HASH
#     ring_hash_lb_config:
#       minimum_ring_size: 1024
#
#   (MAGLEV is an equally valid consistent-hash choice: faster lookups, a
#   little more disruption when the host set changes.)
#
#   Envoy reads this static bootstrap only at startup, so restart it:
#     kubectl -n ckne-llm-lab rollout restart deploy/llm-gateway
#     kubectl -n ckne-llm-lab rollout status deploy/llm-gateway
#
#   Confirm Envoy loaded the new config, instead of assuming it:
#     curl -s localhost:9901/config_dump | grep -E '"(lb_policy|timeout|idle_timeout)"|header_name'
#       "lb_policy": "RING_HASH",
#       "timeout": "0s",
#       "idle_timeout": "30s",
#       "header_name": "x-session-id"
#
# --- Step 5: verify -----------------------------------------------------------
#
#   ./break-fix-3.1-llm-traffic.sh verify
#     PASS  non-streaming 16-token completion returned 200
#     PASS  stream delivered 16/16 tokens and [DONE]
#     PASS  a non-zero idle timeout is configured
#     PASS  all 6 turns served by the same pod
#     PASS  turns 2..6 were prefix-cache hits (5/5)
#     PASS  12 distinct sessions landed on 2 or 3 pods (not pinned to one)
#
#   Requests WITHOUT x-session-id get a random host under RING_HASH, because
#   there is nothing to hash. In production, make the client (or an upstream
#   filter) always set a stable conversation key.
#
# --- Step 6: the same fix in Gateway API terms (what the exam expects) -------
#
#   Timeouts in HTTPRoute (standard since Gateway API v1.2). "0s" disables
#   the timeout. The idle timeout is implementation-specific (for example
#   Envoy Gateway's ClientTrafficPolicy / BackendTrafficPolicy):
#
#     apiVersion: gateway.networking.k8s.io/v1
#     kind: HTTPRoute
#     metadata:
#       name: llm
#     spec:
#       parentRefs:
#       - name: inference-gateway
#       rules:
#       - matches:
#         - path:
#             type: PathPrefix
#             value: /v1/
#         backendRefs:
#         - name: llm-backend
#           port: 8000
#         timeouts:
#           request: "0s"
#
#   Consistent-hash affinity is also implementation-specific. With Envoy
#   Gateway it is a BackendTrafficPolicy with loadBalancer.type: ConsistentHash
#   hashing on a header; check the exact field shape for your release.
#
#   The production-grade answer goes beyond a static hash: the Gateway API
#   Inference Extension. An InferencePool groups the model-server pods, and an
#   Endpoint Picker (EPP) chooses the pod for each request from live
#   model-server metrics: queue depth, KV-cache utilisation, prefix-cache
#   locality and loaded LoRA adapters. A hash, by contrast, keeps sending a
#   session to a pod even while that pod is saturated. The HTTPRoute then
#   points its backendRef at the InferencePool instead of a Service.
#     https://gateway-api-inference-extension.sigs.k8s.io/
#
# --- Takeaways ----------------------------------------------------------------
#
#   * LLM responses are long-lived streams: bound silence (idle timeout), not
#     total duration.
#   * The KV / prefix cache makes backend pods non-interchangeable. Routing
#     should preserve cache locality: a hash at minimum, cache- and load-aware
#     picking (InferencePool + EPP) in production.
#   * Always prove a fix from the proxy's own view (config_dump, /stats,
#     /clusters) and from the backend's metrics, not only from a single curl.
#
# Cleanup when done:
#   ./break-fix-3.1-llm-traffic.sh cleanup
# =============================================================================