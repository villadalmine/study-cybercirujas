#!/usr/bin/env bash
# Lab CNPA 4.4: Cryptographic Identity Management and Secret Storage
# Escenario de prueba: Simulación de desincronización de token de Vault en External Secrets Operator.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 4.4 ==="
kubectl create namespace cnpa-lab-4-4 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: external-secret-status
  namespace: cnpa-lab-4-4
data:
  SYNC_STATUS: "VAULT_TOKEN_EXPIRED"
EOF

echo "El token de Vault ha expirado en el recurso ExternalSecret en namespace 'cnpa-lab-4-4'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap de estado:
#    kubectl describe cm external-secret-status -n cnpa-lab-4-4
# 2. Renovar el token de Vault y actualizar SYNC_STATUS a SECRET_SYNCED.