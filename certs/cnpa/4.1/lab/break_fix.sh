#!/usr/bin/env bash
# Lab CNPA 4.1: Software Supply Chain Security and SBOM Principles
# Escenario de prueba: Simulación de fallo en verificación de atestación SBOM.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 4.1 ==="
kubectl create namespace cnpa-lab-4-1 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: sbom-verification-config
  namespace: cnpa-lab-4-1
data:
  SBOM_VERIFIED: "FALSE"
EOF

echo "La atestación del SBOM no pudo verificarse en namespace 'cnpa-lab-4-1'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap del laboratorio:
#    kubectl describe cm sbom-verification-config -n cnpa-lab-4-1
# 2. Actualizar SBOM_VERIFIED a TRUE.