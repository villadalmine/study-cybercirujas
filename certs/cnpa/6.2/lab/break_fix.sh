#!/usr/bin/env bash
# Lab CNPA 6.2: Autoscaling Strategies: HPA, VPA, KEDA, and Cluster Autoscaler
# Escenario: Un HPA no escala porque el metrics-server no está instalado,
# impidiendo que el controller obtenga las métricas de CPU de los Pods.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 6.2 ==="
kubectl create namespace cnpa-lab-6-2 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scaling-target
  namespace: cnpa-lab-6-2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: scaling-target
  template:
    metadata:
      labels:
        app: scaling-target
    spec:
      containers:
      - name: app
        image: nginx:alpine
        resources:
          requests:
            cpu: 100m
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: scaling-target-hpa
  namespace: cnpa-lab-6-2
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: scaling-target
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
EOF

echo "El HPA 'scaling-target-hpa' muestra '<unknown>/50%' porque no puede obtener métricas de CPU."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Verificar el estado del HPA:
#    kubectl get hpa -n cnpa-lab-6-2
# 2. Verificar que metrics-server está corriendo:
#    kubectl get pods -n kube-system | grep metrics-server
# 3. Si no está instalado, desplegar metrics-server:
#    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml