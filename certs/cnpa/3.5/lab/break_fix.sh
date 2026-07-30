#!/usr/bin/env bash
# Lab CNPA 3.5: CI/CD Relationship Fundamentals and Integration
# Escenario de prueba: Simulación de fallo de integración entre el pipeline de CI
# y la sincronización de manifiestos en el clúster.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 3.5 ==="
kubectl create namespace cnpa-lab-3-5 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: broken-pipeline-config
  namespace: cnpa-lab-3-5
data:
  PIPELINE_STATUS: "FAILED_SYNC"
EOF

echo "El pipeline de CI no puede verificar la sincronización en el clúster en namespace 'cnpa-lab-3-5'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap del pipeline:
#    kubectl describe cm broken-pipeline-config -n cnpa-lab-3-5
# 2. Corregir el estado a SUCCESSFUL_SYNC.