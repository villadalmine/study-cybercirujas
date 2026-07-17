#!/usr/bin/env bash
#
# CKA v1.35 - Break & Fix Lab
# Tema 3.5: Configure Pod admission and scheduling (limits, node affinity, etc.)
# Peso en el examen: 2.5
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Uso:
#   ./cka-3.5-admission-scheduling.sh break     -> arma el escenario y rompe dos Deployments
#   ./cka-3.5-admission-scheduling.sh check     -> verifica si ya arreglaste todo
#   ./cka-3.5-admission-scheduling.sh cleanup   -> borra el namespace del lab
#
# Este script SOLO crea/borra objetos dentro de un namespace dedicado
# (no toca nodos, no toca otros namespaces). Aun así, correlo únicamente
# en un cluster de laboratorio descartable (kind/minikube/k3d/VM de práctica),
# nunca contra un cluster real.

set -euo pipefail

NAMESPACE="cka-3-5-lab"
DEPLOY_QUOTA="web-quota"
DEPLOY_AFFINITY="web-affinity"
LIMITRANGE_NAME="cpu-cap"
BAD_AFFINITY_KEY="lab.cka.io/tier"
BAD_AFFINITY_VALUE="gpu-ultra"

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: no se encontró kubectl en el PATH." >&2
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl no puede contactar al cluster (revisá tu kubeconfig/contexto)." >&2
    exit 1
  fi
}

confirm_lab_environment() {
  if [[ "${FORCE:-}" == "1" ]]; then
    return 0
  fi
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  echo "Contexto actual de kubectl: ${ctx}"
  echo "Este script va a crear el namespace '${NAMESPACE}' y romper deliberadamente"
  echo "dos Deployments dentro de él (LimitRange demasiado bajo y nodeAffinity imposible)."
  read -r -p "¿Confirmás que este es un cluster de laboratorio DESCARTABLE? [y/N] " ans
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Cancelado. Si estás seguro, corré con FORCE=1 ./$(basename "$0") break"
      exit 1
      ;;
  esac
}

setup_baseline() {
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -n "${NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_QUOTA}
  labels:
    app: ${DEPLOY_QUOTA}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${DEPLOY_QUOTA}
  template:
    metadata:
      labels:
        app: ${DEPLOY_QUOTA}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: 100m
            limits:
              cpu: 200m
EOF

  kubectl apply -n "${NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_AFFINITY}
  labels:
    app: ${DEPLOY_AFFINITY}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${DEPLOY_AFFINITY}
  template:
    metadata:
      labels:
        app: ${DEPLOY_AFFINITY}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
EOF

  echo "Esperando que la línea base quede sana antes de romper nada..."
  kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_QUOTA}" --timeout=120s
  kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_AFFINITY}" --timeout=120s
}

break_admission_limits() {
  # Admission: un LimitRange con un max.cpu muy bajo, y después el Deployment
  # pide más cpu de la que ese máximo permite -> los pods nuevos son rechazados
  # en el momento de la creación (admission), no en el scheduling.
  kubectl apply -n "${NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: ${LIMITRANGE_NAME}
spec:
  limits:
    - type: Container
      max:
        cpu: 150m
EOF

  kubectl -n "${NAMESPACE}" set resources "deployment/${DEPLOY_QUOTA}" \
    --containers=nginx --requests=cpu=250m --limits=cpu=300m >/dev/null
}

break_scheduling_affinity() {
  # Scheduling: requiredDuringSchedulingIgnoredDuringExecution nodeAffinity
  # que exige un label que ningún nodo tiene -> los pods quedan Pending.
  kubectl -n "${NAMESPACE}" patch "deployment/${DEPLOY_AFFINITY}" --type=json \
    -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/affinity\",\"value\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"${BAD_AFFINITY_KEY}\",\"operator\":\"In\",\"values\":[\"${BAD_AFFINITY_VALUE}\"]}]}]}}}}]" >/dev/null
}

print_task() {
  cat <<EOF

================================================================
LAB ROTO - Tema 3.5: Pod admission and scheduling
Namespace: ${NAMESPACE}
================================================================

Vas a ver algo así (dale unos segundos y corré vos mismo estos comandos):

  kubectl -n ${NAMESPACE} get deploy
  kubectl -n ${NAMESPACE} get pods
  kubectl -n ${NAMESPACE} get events --sort-by=.lastTimestamp

SÍNTOMA 1 (Deployment '${DEPLOY_QUOTA}'):
  El Deployment no llega a 2/2 réplicas nuevas disponibles. El ReplicaSet
  más reciente tiene un evento de tipo "FailedCreate" mencionando un
  LimitRange y un límite de cpu excedido.

SÍNTOMA 2 (Deployment '${DEPLOY_AFFINITY}'):
  Los pods quedan en estado Pending. El evento del pod dice algo como
  "0/N nodes are available: N node(s) didn't match Pod's node affinity/selector."

OBJETIVO:
  1. Para '${DEPLOY_QUOTA}': lográ que el Deployment quede en 2/2 Running
     SIN borrar ni deshabilitar el LimitRange '${LIMITRANGE_NAME}'. Tenés
     que reconciliar los resources del container con lo que el LimitRange
     permite (ajustando el Deployment, el LimitRange, o ambos).

  2. Para '${DEPLOY_AFFINITY}': lográ que el Deployment quede en 2/2 Running
     SIN quitar el bloque de nodeAffinity. Tenés que hacer que la regla
     de afinidad efectivamente se pueda cumplir en el cluster.

Cuando creas que está resuelto, corré:
  ./$(basename "$0") check

================================================================
EOF
}

do_break() {
  require_kubectl
  confirm_lab_environment
  setup_baseline
  break_admission_limits
  break_scheduling_affinity
  print_task
}

do_check() {
  require_kubectl
  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "El namespace ${NAMESPACE} no existe. Corré primero: ./$(basename "$0") break"
    exit 1
  fi

  local ok=1

  echo "Verificando ${DEPLOY_QUOTA}..."
  if kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_QUOTA}" --timeout=10s >/dev/null 2>&1; then
    echo "  OK: ${DEPLOY_QUOTA} está disponible."
  else
    echo "  TODAVÍA ROTO: ${DEPLOY_QUOTA} no llegó a estar disponible."
    ok=0
  fi

  echo "Verificando ${DEPLOY_AFFINITY}..."
  if kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_AFFINITY}" --timeout=10s >/dev/null 2>&1; then
    echo "  OK: ${DEPLOY_AFFINITY} está disponible."
  else
    echo "  TODAVÍA ROTO: ${DEPLOY_AFFINITY} no llegó a estar disponible."
    ok=0
  fi

  if kubectl -n "${NAMESPACE}" get limitrange "${LIMITRANGE_NAME}" >/dev/null 2>&1; then
    echo "  OK: el LimitRange '${LIMITRANGE_NAME}' sigue existiendo (no lo borraste)."
  else
    echo "  ATENCIÓN: el LimitRange '${LIMITRANGE_NAME}' fue borrado. La consigna pedía"
    echo "  resolverlo sin eliminar el objeto de admission control."
    ok=0
  fi

  if [[ "${ok}" -eq 1 ]]; then
    echo
    echo "TODO RESUELTO. Buen trabajo."
  else
    echo
    echo "Todavía hay puntos pendientes. Revisá 'kubectl describe' sobre los pods/RS afectados."
  fi
}

do_cleanup() {
  require_kubectl
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
  echo "Namespace ${NAMESPACE} eliminado."
}

case "${1:-}" in
  break) do_break ;;
  check) do_check ;;
  cleanup) do_cleanup ;;
  *)
    echo "Uso: $(basename "$0") {break|check|cleanup}" >&2
    exit 1
    ;;
esac

# ================================================================
# SOLUCIÓN PASO A PASO (spoiler - no se ejecuta, solo referencia)
# ================================================================
#
# --- Deployment web-quota (admission por LimitRange) ---
#
# 1) Diagnosticar:
#      kubectl -n cka-3-5-lab get deploy web-quota
#      kubectl -n cka-3-5-lab get rs -l app=web-quota
#      kubectl -n cka-3-5-lab describe rs -l app=web-quota
#      # Evento: "forbidden: [maximum cpu usage per Container is 150m, but limit is 300m]"
#      kubectl -n cka-3-5-lab get limitrange cpu-cap -o yaml
#      # spec.limits[0].max.cpu = 150m
#
# 2) Arreglar (dos caminos válidos, cualquiera de los dos sirve):
#      # Opción A: bajar los resources del Deployment para que entren en el max
#      kubectl -n cka-3-5-lab set resources deployment/web-quota \
#        --containers=nginx --requests=cpu=100m --limits=cpu=150m
#
#      # Opción B: subir el max del LimitRange para que soporte lo que pide el Deployment
#      kubectl -n cka-3-5-lab edit limitrange cpu-cap
#      # (subir spec.limits[0].max.cpu a 300m o más)
#
# 3) Confirmar:
#      kubectl -n cka-3-5-lab rollout status deployment/web-quota
#
#
# --- Deployment web-affinity (scheduling por nodeAffinity imposible) ---
#
# 1) Diagnosticar:
#      kubectl -n cka-3-5-lab get pods -l app=web-affinity -o wide
#      kubectl -n cka-3-5-lab describe pod -l app=web-affinity
#      # Evento: "0/N nodes are available: N node(s) didn't match Pod's node affinity/selector."
#      kubectl -n cka-3-5-lab get deployment web-affinity -o jsonpath='{.spec.template.spec.affinity}'
#      # -> exige label lab.cka.io/tier=gpu-ultra
#      kubectl get nodes --show-labels
#
# 2) Arreglar (dos caminos válidos, cualquiera de los dos sirve):
#      # Opción A: etiquetar un nodo real con el label que la afinidad exige
#      kubectl label node <NOMBRE_DEL_NODO> lab.cka.io/tier=gpu-ultra
#
#      # Opción B: editar el Deployment para que la afinidad apunte a un label
#      # que sí existe en el cluster
#      kubectl -n cka-3-5-lab edit deployment web-affinity
#      # (ajustar spec.template.spec.affinity.nodeAffinity...matchExpressions
#      #  a un key/value que un nodo real tenga, p. ej. kubernetes.io/hostname)
#
# 3) Confirmar:
#      kubectl -n cka-3-5-lab rollout status deployment/web-affinity
#
# --- Verificación final ---
#      ./cka-3.5-admission-scheduling.sh check
#
# --- Limpieza del lab ---
#      ./cka-3.5-admission-scheduling.sh cleanup
# ================================================================