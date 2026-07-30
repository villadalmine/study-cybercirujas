#!/usr/bin/env bash
# Lab CNPA 5.4: Ingress Controllers, Gateway API, and External Traffic Management
# Escenario: Un HTTPRoute no enruta tráfico porque el parentRef apunta a un Gateway inexistente.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 5.4 ==="
kubectl create namespace cnpa-lab-5-4 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-route-status
  namespace: cnpa-lab-5-4
data:
  ROUTE_STATUS: "NO_MATCHING_PARENT"
  GATEWAY_NAME: "non-existent-gateway"
EOF

echo "El HTTPRoute en namespace 'cnpa-lab-5-4' no encuentra su Gateway padre."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap:
#    kubectl describe cm gateway-route-status -n cnpa-lab-5-4
# 2. Crear el Gateway referenciado o corregir el parentRef del HTTPRoute.
# 3. Actualizar ROUTE_STATUS a ACCEPTED y GATEWAY_NAME al nombre correcto.