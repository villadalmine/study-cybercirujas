#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# CKA v1.35 - Tema 3.4 (peso 2.5)
# Understand the primitives used to create robust, self-healing,
# application deployments
#
# Fuente de referencia (curriculum oficial, NO copiar texto literal):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Primitivos que este laboratorio pone a prueba:
#   - Deployment / ReplicaSet (control loop de reconciliación)
#   - livenessProbe / readinessProbe
#   - restartPolicy (Always, por defecto en Pods de un Deployment)
#   - rollout status / self-healing automático de Kubernetes
#
# USO:
#   ./break-fix-3.4.sh break    -> rompe el laboratorio (acción por defecto)
#   ./break-fix-3.4.sh status   -> muestra el estado actual (diagnóstico)
#   ./break-fix-3.4.sh check    -> valida si ya arreglaste el problema
#   ./break-fix-3.4.sh clean    -> borra el namespace del laboratorio
# ============================================================================

NAMESPACE="cka-3-4-selfheal"
DEPLOYMENT="webapp"
LAB_MARKER="/etc/teach-plat-lab"

confirm_disposable_vm() {
  if [[ "${TEACH_PLAT_LAB_CONFIRMED:-}" == "yes" || -f "${LAB_MARKER}" ]]; then
    return 0
  fi
  echo "Este script rompe recursos de Kubernetes a propósito."
  echo "Ejecutalo SOLO en una VM de laboratorio descartable, nunca contra un cluster real."
  read -r -p "Escribi 'si' para confirmar que esta es una VM descartable: " ans
  if [[ "${ans}" != "si" ]]; then
    echo "Cancelado. No se modificó nada."
    exit 1
  fi
}

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado. Abortando."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "No se puede contactar al cluster. Abortando."; exit 1; }
}

deploy_baseline() {
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  cat <<'EOF' | kubectl apply -n "${NAMESPACE}" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  labels:
    app: webapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports:
            - containerPort: 80
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 5
EOF
  kubectl -n "${NAMESPACE}" rollout status deployment/"${DEPLOYMENT}" --timeout=120s
}

break_it() {
  echo "Desplegando baseline sano en el namespace '${NAMESPACE}'..."
  deploy_baseline

  echo "Rompiendo el livenessProbe del Deployment '${DEPLOYMENT}'..."
  kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type='json' -p='[
    {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/nope-no-existe"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/port", "value": 9999},
    {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/periodSeconds", "value": 2}
  ]' >/dev/null

  cat <<MSG

============================================================
LABORATORIO ROTO: ${NAMESPACE}/${DEPLOYMENT}
============================================================

SÍNTOMA que vas a observar en 10-30 segundos:
  - 'kubectl get pods -n ${NAMESPACE}' muestra RESTARTS subiendo
    sin parar en los 3 Pods del Deployment.
  - Eventualmente el STATUS pasa a CrashLoopBackOff.
  - 'kubectl rollout status deployment/${DEPLOYMENT} -n ${NAMESPACE}'
    nunca termina (no llega a estar "successfully rolled out").
  - La aplicación (nginx) NO tiene ningún problema real: el proceso
    adentro del container está sano. Es el mecanismo de self-healing
    (kubelet + livenessProbe) el que está matando containers buenos.

OBJETIVO:
  Identificá qué primitivo de self-healing está mal configurado y
  arreglalo para que el ReplicaSet mantenga 3/3 Pods Ready y estables
  (RESTARTS sin seguir creciendo) sin recrear el Deployment desde cero.

Pistas de comandos para diagnosticar (no son la solución, son el camino):
  kubectl get pods -n ${NAMESPACE} -w
  kubectl describe pod <pod> -n ${NAMESPACE}
  kubectl get deployment ${DEPLOYMENT} -n ${NAMESPACE} -o yaml

Cuando creas que lo arreglaste, corré:
  $0 check

============================================================
MSG
}

status() {
  echo "--- kubectl get pods -n ${NAMESPACE} ---"
  kubectl get pods -n "${NAMESPACE}" -o wide || true
  echo
  echo "--- eventos recientes ---"
  kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp | tail -n 15 || true
}

check() {
  echo "Esperando a que el rollout se estabilice (60s máx)..."
  if ! kubectl -n "${NAMESPACE}" rollout status deployment/"${DEPLOYMENT}" --timeout=60s; then
    echo "TODAVÍA ROTO: el rollout no se estabiliza. Seguí investigando el livenessProbe."
    exit 1
  fi

  local restarts_before restarts_after
  restarts_before=$(kubectl -n "${NAMESPACE}" get pods -l app=webapp \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}')
  sleep 15
  restarts_after=$(kubectl -n "${NAMESPACE}" get pods -l app=webapp \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}')

  if [[ "${restarts_before}" == "${restarts_after}" ]]; then
    echo "RESUELTO: 3/3 Pods Ready y los RESTARTS dejaron de crecer. Buen trabajo."
  else
    echo "TODAVÍA ROTO: los RESTARTS siguen aumentando (${restarts_before} -> ${restarts_after})."
    exit 1
  fi
}

clean() {
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
  echo "Namespace '${NAMESPACE}' eliminado."
}

main() {
  local action="${1:-break}"
  case "${action}" in
    break)
      confirm_disposable_vm
      require_kubectl
      break_it
      ;;
    status)
      require_kubectl
      status
      ;;
    check)
      require_kubectl
      check
      ;;
    clean)
      require_kubectl
      clean
      ;;
    *)
      echo "Uso: $0 [break|status|check|clean]"
      exit 1
      ;;
  esac
}

main "$@"

# ============================================================================
# SOLUCIÓN PASO A PASO (comentada - no la leas antes de intentarlo vos mismo)
# ============================================================================
#
# 1) Diagnosticar el síntoma:
#      kubectl get pods -n cka-3-4-selfheal
#      -> STATUS: CrashLoopBackOff, RESTARTS creciendo en los 3 Pods.
#
# 2) Confirmar la causa raíz con los eventos del Pod:
#      kubectl describe pod <pod> -n cka-3-4-selfheal
#      -> En la sección Events vas a ver algo como:
#         "Liveness probe failed: Get http://10.x.x.x:9999/nope-no-existe:
#          dial tcp 10.x.x.x:9999: connect: connection refused"
#         "Killing container with id ...: Container failed liveness probe,
#          will be restarted"
#      Esto confirma que el kubelet está matando el container porque el
#      livenessProbe apunta a un puerto/path que no existe, NO porque la
#      app esté rota.
#
# 3) Revisar la configuración actual del primitivo roto:
#      kubectl get deployment webapp -n cka-3-4-selfheal -o yaml \
#        | grep -A6 livenessProbe
#      -> path: /nope-no-existe, port: 9999, periodSeconds: 2
#
# 4) Arreglar el livenessProbe para que apunte al puerto/path reales
#    que expone el container (nginx en el puerto 80, path "/"):
#
#      kubectl patch deployment webapp -n cka-3-4-selfheal --type='json' -p='[
#        {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/"},
#        {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/port", "value": 80},
#        {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/periodSeconds", "value": 5}
#      ]'
#
#    (Alternativa equivalente: kubectl edit deployment webapp -n cka-3-4-selfheal
#     y corregir a mano los mismos tres campos bajo livenessProbe.)
#
# 5) Verificar que el ReplicaSet converge al estado deseado (primitivo de
#    self-healing funcionando correctamente esta vez):
#      kubectl rollout status deployment/webapp -n cka-3-4-selfheal --timeout=60s
#      kubectl get pods -n cka-3-4-selfheal
#      -> 3/3 Pods READY, STATUS Running, RESTARTS estable (no sigue creciendo).
#
# 6) Confirmación automatizada: ./break-fix-3.4.sh check
#
# ============================================================================