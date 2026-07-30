#!/usr/bin/env bash
#
# CNPE - Tema 1.3: Optimizing Multi-Tenancy Resource Usage
# Script break & fix para laboratorio descartable (kind/minikube/<PERSON>).
#
# ADVERTENCIA: ejecutar SOLO en un cluster de laboratorio descartable.
# El script crea un namespace propio y no toca nada fuera de él.

set -euo pipefail

NAMESPACE="cnpe-lab-mt"
DEPLOY_NAME="tenant-app"

log() { echo -e "\n[LAB] $*\n"; }

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { echo "Falta kubectl en el PATH"; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "No se puede contactar al cluster"; exit 1; }
}

cleanup() {
  log "Limpiando namespace de laboratorio ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
}

break_lab() {
  log "Creando namespace de tenant y aplicando ResourceQuota..."

  kubectl create namespace "${NAMESPACE}" >/dev/null

  # ResourceQuota que simula un tenant en un cluster multi-tenant
  # con límites acordados por el administrador de la plataforma.
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "300m"
    requests.memory: "384Mi"
    limits.cpu: "600m"
    limits.memory: "768Mi"
    pods: "10"
EOF

  # Deployment "roto": pide más recursos de los que el quota permite
  # para el conjunto de réplicas. Esto es un error típico de un equipo
  # que despliega su carga de trabajo sin considerar los límites del tenant.
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 4
  selector:
    matchLabels:
      app: ${DEPLOY_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
    spec:
      containers:
      - name: app
        image: nginx:1.25-alpine
        resources:
          requests:
            cpu: "150m"
            memory: "192Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
EOF

  log "Entorno roto listo."
  cat <<'MSG'
SÍNTOMA A OBSERVAR:
--------------------
Vas a ver que el Deployment "tenant-app" no llega a tener sus 4 réplicas
corriendo. Investigá con:

  kubectl get deployment tenant-app -n cnpe-lab-mt
  kubectl get pods -n cnpe-lab-mt
  kubectl describe resourcequota tenant-quota -n cnpe-lab-mt
  kubectl get events -n cnpe-lab-mt --sort-by=.lastTimestamp

Vas a encontrar eventos del tipo "FailedCreate" con el mensaje
"forbidden: exceeded quota" en el ReplicaSet.

OBJETIVO:
---------
Sin modificar ni eliminar el ResourceQuota "tenant-quota" (representa un
límite acordado por la plataforma para este tenant), <PERSON> réplicas
necesarias del Deployment queden en estado Running, optimizando el uso de
recursos del tenant (requests/limits y/o cantidad de réplicas) <PERSON> dentro del quota disponible.

<PERSON> con:
  kubectl get pods -n cnpe-lab-mt   (todas en Running)
  kubectl describe resourcequota tenant-quota -n cnpe-lab-mt  (Used <= Hard)
MSG
}

main() {
  check_prereqs
  trap 'log "Si querés destruir el laboratorio: cleanup"' EXIT
  break_lab
}

main "$@"

# =========================================================================
# SOLUCIÓN PASO A PASO (comentada, no se ejecuta automáticamente)
# =========================================================================
#
# 1) Diagnosticar el quota disponible vs lo solicitado:
#
#    kubectl describe resourcequota tenant-quota -n cnpe-lab-mt
#
#    Hard:  requests.cpu=300m, requests.memory=384Mi
#    El deployment pide 4 réplicas x 150m/192Mi = 600m/768Mi de requests,
#    el doble de lo permitido. Por eso solo entran ~2 pods y el resto
#    queda bloqueado por el admission controller de ResourceQuota.
#
# 2) Opción A - Reducir requests/limits por pod para que entren las 4 réplicas:
#
#    kubectl -n cnpe-lab-mt set resources deployment/tenant-app \
#      --requests=cpu=50m,memory=64Mi \
#      --limits=cpu=100m,memory=128Mi
#
#    Cálculo: 4 réplicas x 50m/64Mi = 200m/256Mi de requests,
#    dentro del hard de 300m/384Mi.
#
# 3) Opción B - Si el sizing por pod es fijo por requerimiento de la app,
#    reducir la cantidad de réplicas a lo que el quota permite:
#
#    kubectl -n cnpe-lab-mt scale deployment/tenant-app --replicas=2
#
#    Cálculo: 2 réplicas x 150m/192Mi = 300m/384Mi, exactamente el hard.
#
# 4) Validar que todos los pods llegaron a Running y que el uso del
#    tenant está dentro de su cuota:
#
#    kubectl get pods -n cnpe-lab-mt
#    kubectl describe resourcequota tenant-quota -n cnpe-lab-mt
#
#    (columna "Used" debe ser <= "Hard" en todas las dimensiones)
#
# 5) Reflexión del ejercicio (multi-tenancy):
#    - El ResourceQuota protege a otros tenants del cluster de un consumo
#      desmedido de un namespace individual.
#    - La responsabilidad de "entrar" en el presupuesto asignado es del
#      equipo dueño del namespace: se <PERSON> requests/limits
#      (rightsizing) o el número de réplicas, no ampliando el quota.
#    - Combinar ResourceQuota con LimitRange (valores default de request/
#      limit) evita que un pod sin resources declarados rompa el cálculo
#      de cuota del namespace.
#
# 6) Para destruir el laboratorio:
#
#    kubectl delete namespace cnpe-lab-mt
# =========================================================================