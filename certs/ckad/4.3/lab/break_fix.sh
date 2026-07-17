#!/usr/bin/env bash
# ============================================================================
# CKAD 1.35 - Tema 4.3: Understand requests, limits, quotas (peso: 3)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Script "break & fix" para laboratorio DESCARTABLE (kind/minikube/VM de
# práctica). Crea un namespace propio, rompe algo relacionado con
# ResourceQuota y con los requests/limits de los Pods, y deja al
# estudiante el desafío de diagnosticarlo y arreglarlo sin tocar la
# quota. La solución completa está comentada al final del archivo.
#
# Uso:
#   ./break-433.sh break      # rompe el escenario
#   ./break-433.sh status     # verifica si ya lo resolviste
#   ./break-433.sh cleanup    # borra todo lo creado (namespace incluido)
# ============================================================================

set -euo pipefail

NS="ckad-433-lab"
QUOTA_NAME="team-quota"
DEPLOY_NAME="checkout-api"

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: no se encuentra kubectl en el PATH." >&2
    exit 1
  }
}

confirm_disposable_cluster() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  echo "Contexto actual de kubectl: ${ctx}"
  echo "Este script MODIFICA el cluster (crea/borra el namespace '${NS}')."
  echo "Ejecutalo solo contra un cluster de laboratorio descartable (kind, minikube, VM de práctica)."
  read -r -p "¿Confirmás que este NO es un cluster productivo? (escribí 'si' para continuar): " ans
  if [[ "${ans}" != "si" ]]; then
    echo "Cancelado. No se modificó nada."
    exit 1
  fi
}

cmd_break() {
  require_kubectl
  confirm_disposable_cluster

  echo ">> Creando namespace '${NS}'..."
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

  echo ">> Aplicando ResourceQuota '${QUOTA_NAME}' en '${NS}'..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${QUOTA_NAME}
  namespace: ${NS}
spec:
  hard:
    requests.cpu: "500m"
    requests.memory: "512Mi"
    limits.cpu: "1"
    limits.memory: "1Gi"
    pods: "10"
EOF

  echo ">> Desplegando '${DEPLOY_NAME}' con 3 replicas..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NS}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ${DEPLOY_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
    spec:
      containers:
        - name: api
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: "300m"
              memory: "256Mi"
            limits:
              cpu: "300m"
              memory: "256Mi"
EOF

  cat <<'MSG'

============================================================
 SINTOMA
============================================================
El Deployment quedó aplicado pero no todos los Pods están
Running. Vas a ver algo como:

  $ kubectl get deployment checkout-api -n ckad-433-lab
  NAME           READY   UP-TO-DATE   AVAILABLE   AGE
  checkout-api   1/3     1            1           1m

El ReplicaSet no logra crear todos los Pods que le pide el
Deployment.

============================================================
 OBJETIVO
============================================================
Lograr que 'checkout-api' llegue a 3/3 Pods Running, SIN
eliminar ni modificar el ResourceQuota 'team-quota' del
namespace, y sin bajar 'replicas: 3' del Deployment.

Pistas de comandos para investigar:
  kubectl get resourcequota -n ckad-433-lab
  kubectl describe resourcequota team-quota -n ckad-433-lab
  kubectl get replicaset -n ckad-433-lab
  kubectl describe replicaset -n ckad-433-lab
  kubectl get events -n ckad-433-lab --sort-by=.lastTimestamp

Cuando creas que lo resolviste, corré:
  ./break-433.sh status

============================================================
MSG
}

cmd_status() {
  require_kubectl
  echo ">> Estado de '${DEPLOY_NAME}' en '${NS}':"
  kubectl get deployment "${DEPLOY_NAME}" -n "${NS}" -o wide 2>/dev/null || {
    echo "No existe el Deployment. ¿Corriste '$0 break'?"
    exit 1
  }
  local ready desired
  ready="$(kubectl get deployment "${DEPLOY_NAME}" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="$(kubectl get deployment "${DEPLOY_NAME}" -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  if [[ "${ready:-0}" == "${desired}" ]]; then
    echo "OK: ${ready}/${desired} Pods Running. Ejercicio resuelto."
  else
    echo "Todavía no: ${ready:-0}/${desired} Pods Running. Seguí investigando."
  fi
}

cmd_cleanup() {
  require_kubectl
  echo ">> Borrando namespace '${NS}' (esto elimina todo lo creado por el lab)..."
  kubectl delete namespace "${NS}" --ignore-not-found=true
}

main() {
  case "${1:-}" in
    break)   cmd_break ;;
    status)  cmd_status ;;
    cleanup) cmd_cleanup ;;
    *)
      echo "Uso: $0 {break|status|cleanup}" >&2
      exit 1
      ;;
  esac
}

main "$@"

# ============================================================================
# SOLUCIÓN (spoiler) - paso a paso
# ============================================================================
#
# 1. Ver el estado del Deployment y del ReplicaSet:
#      kubectl get deployment checkout-api -n ckad-433-lab
#      kubectl get replicaset -n ckad-433-lab
#      kubectl describe replicaset -n ckad-433-lab
#
#    En la sección "Events" del ReplicaSet aparece algo como:
#      Warning  FailedCreate  ... pods "checkout-api-xxxx" is forbidden:
#      exceeded quota: team-quota, requested: requests.cpu=300m,
#      requests.memory=256Mi, used: requests.cpu=600m,requests.memory=512Mi,
#      limited: requests.cpu=500m,requests.memory=512Mi
#
# 2. Confirmar los valores reales de la quota:
#      kubectl describe resourcequota team-quota -n ckad-433-lab
#
#    hard.requests.cpu = 500m, hard.requests.memory = 512Mi.
#    3 réplicas * 300m cpu   = 900m  > 500m  -> no entran las 3.
#    3 réplicas * 256Mi mem  = 768Mi > 512Mi -> tampoco entran las 3.
#
# 3. Como no se puede tocar la quota ni bajar 'replicas: 3', la única
#    solución válida es reducir el 'requests'/'limits' de cada Pod para
#    que las 3 réplicas entren dentro del hard de la quota. Por ejemplo,
#    150m cpu / 150Mi memoria por Pod:
#      3 * 150m  cpu    = 450m  <= 500m
#      3 * 150Mi memory = 450Mi <= 512Mi
#
#      kubectl set resources deployment/checkout-api -n ckad-433-lab \
#        --containers=api \
#        --requests=cpu=150m,memory=150Mi \
#        --limits=cpu=150m,memory=150Mi
#
#    (equivalente a editar el manifiesto y reaplicar con
#    'kubectl apply -f -', o 'kubectl edit deployment checkout-api -n ckad-433-lab')
#
# 4. Verificar que el rollout terminó y las 3 réplicas están Running:
#      kubectl rollout status deployment/checkout-api -n ckad-433-lab
#      kubectl get pods -n ckad-433-lab
#      ./break-433.sh status   # debería imprimir "OK: 3/3 ..."
#
# Concepto clave del examen: un ResourceQuota con 'requests.cpu' /
# 'requests.memory' limita la SUMA de los requests de todos los Pods
# del namespace. Si un Deployment pide más réplicas de las que entran
# dentro de ese total, el ReplicaSet queda con Pods sin crear
# (FailedCreate en events) aunque el Deployment en sí se haya aplicado
# sin error.
# ============================================================================