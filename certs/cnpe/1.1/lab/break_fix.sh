#!/usr/bin/env bash
# Lab CNPE 1.1: Platform Networking, Storage & Compute
# Escenario: Un Pod falla al ser programado porque el StorageClass requiere
# una topología de zona específica y el Pod no coincide.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPE 1.1 ==="
kubectl create namespace cnpe-lab-1-1 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: lab-topology-sc
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF

echo "El laboratorio ha sido inicializado. Diagnostique el estado de los recursos en namespace 'cnpe-lab-1-1'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Verificar el evento de fallo en scheduling:
#    kubectl get events -n cnpe-lab-1-1
# 2. Corregir la definición de la StorageClass o las TopologySpreadConstraints del Deployment.
