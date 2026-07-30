#!/usr/bin/env bash
# Lab CNPE 1.2: Cost Management & Scaling
# Escenario: Un HPA no logra calcular el target de escalado porque los contenedores
# del Deployment no tienen definido el campo 'resources.requests.cpu'.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPE 1.2 ==="
kubectl create namespace cnpe-lab-1-2 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unscalable-app
  namespace: cnpe-lab-1-2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unscalable
  template:
    metadata:
      labels:
        app: unscalable
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        # Intencionalmente sin resources.requests
EOF

kubectl autoscale deployment unscalable-app -n cnpe-lab-1-2 --cpu-percent=50 --min=1 --max=5

echo "El HPA reporta '<unknown>/50%'. Diagnostique y solucione la causa raíz en el namespace 'cnpe-lab-1-2'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Revisar el estado del HPA:
#    kubectl get hpa -n cnpe-lab-1-2
# 2. Agregar el campo resources.requests.cpu al Deployment:
#    kubectl set resources deployment unscalable-app -n cnpe-lab-1-2 --requests=cpu=100m,memory=128Mi
