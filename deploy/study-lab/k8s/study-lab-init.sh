#!/usr/bin/env bash
# Converges the lab container to "cluster ready". Idempotent: every step checks
# before acting, so running it twice is a no-op.
#   study-lab-init [kind|k3s] [workers] [node-image]
set -euo pipefail
FAMILY="${1:-kind}"
WORKERS="${2:-0}"
NODE_IMAGE="${3:-$KIND_NODE_IMAGE}"
CLUSTER=lab
CACHE=/cache

log() { printf '[study-lab-init] %s\n' "$*"; }

# 1. dockerd (started by the image entrypoint) answering
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info >/dev/null 2>&1 || { log "dockerd did not start"; exit 1; }

if [ "$FAMILY" != kind ]; then log "family $FAMILY not implemented yet in this image"; exit 2; fi

# 2. node image: pulled by digest once, saved to the shared cache volume, and
#    loaded from there on every later run (much faster than a pull).
REF_TAG="${NODE_IMAGE%@*}"
if ! docker image inspect "$REF_TAG" >/dev/null 2>&1; then
  tarball="$CACHE/$(echo "$REF_TAG" | tr '/:' '__').tar"
  if [ -s "$tarball" ]; then
    log "loading $REF_TAG from cache"
    docker load -q -i "$tarball" >/dev/null
  else
    log "pulling $NODE_IMAGE (first run only; then cached)"
    docker pull -q "$NODE_IMAGE" >/dev/null
    docker tag "$NODE_IMAGE" "$REF_TAG"
    if [ -d "$CACHE" ]; then docker save -o "$tarball.tmp.$$" "$REF_TAG" && mv "$tarball.tmp.$$" "$tarball"; fi
  fi
fi
NODE_IMAGE="$REF_TAG"

# 3. kind cluster
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  cfg=/tmp/kind.yaml
  { echo "kind: Cluster"; echo "apiVersion: kind.x-k8s.io/v1alpha4"; echo "nodes:"; echo "- role: control-plane"
    for _ in $(seq 1 "$WORKERS"); do echo "- role: worker"; done; } > "$cfg"
  log "creating kind cluster ($NODE_IMAGE, $WORKERS workers)"
  kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --config "$cfg" --wait 180s >/tmp/kind.log 2>&1     || { cat /tmp/kind.log; exit 1; }
fi
kind export kubeconfig --name "$CLUSTER" >/dev/null 2>&1

# 4. ready: nodes Ready and the default StorageClass present (several labs rely on it)
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
for _ in $(seq 1 60); do kubectl get storageclass 2>/dev/null | grep -q '(default)' && break; sleep 2; done
log "ready: $(kubectl get nodes --no-headers | awk '{print $1"="$2}' | tr '\n' ' ')"
