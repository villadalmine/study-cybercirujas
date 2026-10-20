#!/usr/bin/env bash
# Install the chart into the current kube context, prove it serves, and uninstall it.
#
#   IMAGE=study:ci deploy/helm-smoke/smoke.sh
#
# IMAGE must already be present on the nodes (kind load docker-image). The cluster is
# not created or deleted here: CI gets a fresh kind cluster per run, a local run deletes
# its own (docs in .github/workflows/chart-smoke.yml). Exit code != 0 on any failure,
# after printing what the pod and the events say.
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE=<repository>:<tag>, already loaded into the cluster}"
RELEASE="${RELEASE:-study}"
NS="${NS:-teach-plat}"
PORT="${PORT:-18080}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/../helm"
APP="$RELEASE-app"

secret="$(openssl rand -hex 32)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$secret"; fi
set_args=(-f "$HERE/values.yaml" --set "image.repository=${IMAGE%:*}" --set "image.tag=${IMAGE##*:}"
          --set-string "env.TEACH_SECRET=$secret")

pf_pid=""
diagnose() {
  echo "::group::diagnostics" 2>/dev/null || true
  kubectl -n "$NS" get all,pvc -o wide || true
  kubectl -n "$NS" describe pod -l "app=$APP" || true
  kubectl -n "$NS" logs "deploy/$APP" --tail=100 || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -30 || true
  echo "::endgroup::" 2>/dev/null || true
}
cleanup() {
  rc=$?
  [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then diagnose; fi
  exit "$rc"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

step "lint"
helm lint "$CHART" "${set_args[@]}"

step "install $RELEASE ($IMAGE) into $NS"
helm install "$RELEASE" "$CHART" -n "$NS" --create-namespace "${set_args[@]}" --wait --timeout 5m

step "rollout"
kubectl -n "$NS" rollout status "deploy/$APP" --timeout=180s
kubectl -n "$NS" get pvc "$RELEASE-bot-stats" -o jsonpath='{.status.phase}{"\n"}' | grep -qx Bound
echo "bot-stats PVC Bound"

step "the app user can write the bot-stats volume"
kubectl -n "$NS" exec "deploy/$APP" -- sh -c 'id -u; touch /data/.smoke && rm /data/.smoke && echo writable'

step "HTTP through port-forward"
kubectl -n "$NS" port-forward "svc/$APP" "$PORT:80" >/dev/null 2>&1 &
pf_pid=$!
for _ in $(seq 1 30); do curl -fsS "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 1; done
health="$(curl -fsS --max-time 10 "localhost:$PORT/healthz")"
echo "/healthz -> $health"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d.get("ok") is True and d.get("certs",0) > 0, d' "$health"
catalog="$(curl -fsS --max-time 10 "localhost:$PORT/api/catalog")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d, "empty catalog"; print("/api/catalog ->", len(d), "entries")' "$catalog"
kill "$pf_pid"; pf_pid=""

step "uninstall"
helm uninstall "$RELEASE" -n "$NS" --wait --timeout 3m
left="$(kubectl -n "$NS" get deploy,svc,pvc,secret -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null; kubectl -n "$NS" get deploy,svc,pvc -o name 2>/dev/null)"
if [ -n "$left" ]; then echo "left behind after uninstall:"; echo "$left"; exit 1; fi
echo "nothing left in $NS"

printf '\nchart smoke test: OK\n'
