#!/usr/bin/env bash
# Lab CNPA 6.1: Cost Optimization and FinOps for Cloud Native Infrastructure
# Escenario: Un deployment con requests de CPU 10x superiores al consumo real,
# desperdiciando recursos y presupuesto cloud.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 6.1 ==="
kubectl create namespace cnpa-lab-6-1 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: overprovisioned-app
  namespace: cnpa-lab-6-1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: overprovisioned
  template:
    metadata:
      labels:
        app: overprovisioned
    spec:
      containers:
      - name: app
        image: nginx:alpine
        resources:
          requests:
            cpu: "2"
            memory: 4Gi
          limits:
            cpu: "4"
            memory: 8Gi
EOF

echo "El deployment 'overprovisioned-app' tiene requests de CPU=2 y memoria=4Gi, pero el consumo real es ~50m CPU y ~32Mi."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Verificar el consumo real:
#    kubectl top pods -n cnpa-lab-6-1
# 2. Reducir los requests a valores realistas (ej: cpu=100m, memory=64Mi).
# 3. Opcionalmente configurar un VPA para ajuste automático.