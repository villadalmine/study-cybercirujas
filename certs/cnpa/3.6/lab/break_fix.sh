#!/usr/bin/env bash
# Lab CNPA 3.6: GitOps Basics, Controllers, and Workflows
# Escenario de prueba: Simulación de fallo en controlador de reconciliación de GitOps.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 3.6 ==="
kubectl create namespace cnpa-lab-3-6 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-drift-config
  namespace: cnpa-lab-3-6
data:
  SYNC_POLICY: "MANUAL"
EOF

echo "El controlador de GitOps está configurado en modo manual en namespace 'cnpa-lab-3-6'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap del laboratorio:
#    kubectl describe cm gitops-drift-config -n cnpa-lab-3-6
# 2. Cambiar SYNC_POLICY a AUTOMATED.