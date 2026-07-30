#!/usr/bin/env bash
# Lab CNPA 4.3: Vulnerability Scanning and Continuous Risk Assessment
# Escenario de prueba: Simulación de detección de vulnerabilidad de nivel CRITICAL.

set -euo pipefail

echo "=== Aplicando escenario roto en CNPA 4.3 ==="
kubectl create namespace cnpa-lab-4-3 --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vulnerability-report
  namespace: cnpa-lab-4-3
data:
  CRITICAL_CVE_COUNT: "3"
EOF

echo "Se detectaron 3 CVEs CRITICAL en la imagen en namespace 'cnpa-lab-4-3'."

# ==============================================================================
# PASO A PASO SOLUCIÓN (Comentado)
# ==============================================================================
# 1. Inspeccionar el ConfigMap del reporte:
#    kubectl describe cm vulnerability-report -n cnpa-lab-4-3
# 2. Actualizar CRITICAL_CVE_COUNT a 0 aplicando la versión actualizada de la imagen.