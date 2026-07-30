#!/usr/bin/env bash
# Lab CNPA 5.1: Service Mesh Concepts, Sidecars, and Proxy Architectures
# Escenario de prueba: Simulación de fallo en inyección de proxy Envoy sidecar.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 5.1 ==="
kubectl create namespace cnpa-lab-5-1 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: sidecar-injection-status
  namespace: cnpa-lab-5-1
data:
  INJECTION_STATUS: "DISABLED"
EOF

echo "La inyección automática del sidecar está desactivada en namespace 'cnpa-lab-5-1'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar la etiqueta del namespace y el ConfigMap:
#    kubectl get ns cnpa-lab-5-1 --show-labels
# 2. Etiquetar el namespace: kubectl label ns cnpa-lab-5-1 istio-injection=enabled
# 3. Actualizar INJECTION_STATUS a ENABLED.