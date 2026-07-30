#!/usr/bin/env bash
# Lab CNPA 5.2: Traffic Management, Canary Releases, and Circuit Breaking
# Escenario de prueba: Simulación de fallo en ponderación de tráfico de Canary Release.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 5.2 ==="
kubectl create namespace cnpa-lab-5-2 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: canary-weight-config
  namespace: cnpa-lab-5-2
data:
  CANARY_WEIGHT: "100"
EOF

echo "El tráfico Canary está recibiendo el 100% de las peticiones prematuramente en namespace 'cnpa-lab-5-2'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap de ponderación:
#    kubectl describe cm canary-weight-config -n cnpa-lab-5-2
# 2. Reducir CANARY_WEIGHT a 10.