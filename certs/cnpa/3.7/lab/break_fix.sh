#!/usr/bin/env bash
# Lab CNPA 3.7: GitOps for Multi-Environment Application Management
# Escenario de prueba: Simulación de discrepancia de parches de Kustomize entre entornos.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 3.7 ==="
kubectl create namespace cnpa-lab-3-7 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: env-overlay-config
  namespace: cnpa-lab-3-7
data:
  TARGET_ENV: "DEV_BROKEN"
EOF

echo "El overlay del entorno 'dev' contiene una configuración errónea en namespace 'cnpa-lab-3-7'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap del overlay:
#    kubectl describe cm env-overlay-config -n cnpa-lab-3-7
# 2. Corregir TARGET_ENV a DEV_STABLE.