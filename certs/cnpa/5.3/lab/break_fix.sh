#!/usr/bin/env bash
# Lab CNPA 5.3: Kubernetes Networking Model and CNI Plugins
# Escenario: Un Pod no puede comunicarse con el backend debido a una NetworkPolicy
# default-deny sin reglas de excepción configuradas.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 5.3 ==="
kubectl create namespace cnpa-lab-5-3 --dry-run=client -o yaml | kubectl apply -f -

# Aplicar default-deny
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: cnpa-lab-5-3
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Desplegar un Pod de prueba
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-client
  namespace: cnpa-lab-5-3
  labels:
    role: client
spec:
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["sleep", "3600"]
EOF

echo "El Pod 'test-client' no puede hacer peticiones de salida en namespace 'cnpa-lab-5-3'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar las NetworkPolicies:
#    kubectl get networkpolicy -n cnpa-lab-5-3
# 2. Crear una NetworkPolicy que permita el Egress para el Pod con label role=client:
#    kubectl apply -f allow-egress.yaml