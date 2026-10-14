#!/usr/bin/env bash
# study-lab template (kind). Contract: break | verify | cleanup.
#   break   leaves the cluster broken on purpose and explains the symptom
#   verify  exit 0 ONLY when the student fixed it, non-zero otherwise
#   cleanup removes everything break created (idempotent)
# Example scenario: a Deployment whose image tag does not exist. Replace it.
set -euo pipefail
NS="__NS__"

case "${1:-break}" in
  break)
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "$NS" create deployment web --image=busybox:does-not-exist \
      --dry-run=client -o yaml -- sleep 3600 | kubectl apply -f - >/dev/null
    echo "ROTO: el Deployment 'web' del namespace $NS no llega a Available. Diagnosticá y arreglalo."
    ;;
  verify)
    if kubectl -n "$NS" wait deploy/web --for=condition=Available --timeout=60s >/dev/null 2>&1; then
      echo "OK: web Available"; exit 0
    fi
    echo "Todavía no: web no está Available"; exit 1
    ;;
  cleanup)
    kubectl delete namespace "$NS" --ignore-not-found >/dev/null
    echo "limpio"
    ;;
  *) echo "uso: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac
# SOLUCIÓN (no se ejecuta): kubectl -n __NS__ set image deploy/web busybox=busybox:1.37
