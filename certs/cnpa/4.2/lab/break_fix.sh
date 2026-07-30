#!/usr/bin/env bash
# Lab CNPA 4.2: Artifact Signing, Attestations, and Verification
# Escenario de prueba: Simulación de fallo de verificación de firma de imagen.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 4.2 ==="
kubectl create namespace cnpa-lab-4-2 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: image-signature-config
  namespace: cnpa-lab-4-2
data:
  SIGNATURE_VALID: "FALSE"
EOF

echo "La firma de la imagen no pudo ser verificada en namespace 'cnpa-lab-4-2'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap del laboratorio:
#    kubectl describe cm image-signature-config -n cnpa-lab-4-2
# 2. Actualizar SIGNATURE_VALID a TRUE.