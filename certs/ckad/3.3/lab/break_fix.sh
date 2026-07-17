#!/usr/bin/env bash
#
# break-fix: CKAD 3.3 - Utilize container logs (peso en el examen: 4)
# Referencia: CKAD Curriculum v1.35 (dominio "Application Observability and Maintenance")
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Este script asume que se ejecuta en una VM de laboratorio descartable con
# kubectl apuntando a un cluster de práctica (kind/minikube/k3s, etc.), no
# productivo. Todo lo que rompe queda aislado en un namespace propio, fácil
# de borrar al final.

set -euo pipefail

NAMESPACE="ckad-333-logs"
DEPLOY="orders-api"

usage() {
  cat <<USAGE
Uso: $0 [break|clean]

  break   Rompe el escenario de práctica (default si no se pasa argumento).
  clean   Borra todo lo creado por este script (namespace completo).
USAGE
}

check_prereqs() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: no se encontró kubectl en el PATH. Instalalo antes de continuar." >&2
    exit 1
  fi

  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl no puede contactar a ningún cluster. Verificá tu kubeconfig/contexto." >&2
    exit 1
  fi

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '?')"
  if [[ "$ctx" =~ prod ]]; then
    echo "ERROR: el contexto actual ('${ctx}') parece productivo. Este script no se ejecuta ahí." >&2
    exit 1
  fi

  echo "Contexto actual de kubectl: ${ctx}"
  read -r -p "Confirmás que este es un cluster de laboratorio descartable? (escribí 'si' para continuar): " confirm
  if [[ "${confirm}" != "si" ]]; then
    echo "Cancelado por el usuario."
    exit 1
  fi
}

break_scenario() {
  echo ">>> Creando namespace aislado '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  echo ">>> Desplegando orders-api (roto a propósito)..."
  kubectl apply -n "${NAMESPACE}" -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: ckad-333-logs
  labels:
    app: orders-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c"]
          args:
            - |
              echo "[orders-api] booting..."
              echo "[orders-api] loading configuration..."
              if [ -z "${DB_DSN:-}" ]; then
                echo "[orders-api] FATAL: DB_DSN environment variable is not set, cannot connect to database" >&2
                exit 1
              fi
              echo "[orders-api] connected to ${DB_DSN}"
              i=0
              while true; do
                i=$((i + 1))
                echo "[orders-api] heartbeat OK (${i})"
                sleep 5
              done
        - name: log-shipper
          image: busybox:1.36
          command: ["sh", "-c", "echo '[log-shipper] started, watching for app logs...'; while true; do sleep 30; done"]
YAML

  echo
  echo "=========================================================="
  echo " ESCENARIO ROTO: orders-api (namespace ${NAMESPACE})"
  echo "=========================================================="
  echo "Dale unos 20-30 segundos al Deployment y despues corré:"
  echo "  kubectl get pods -n ${NAMESPACE}"
  echo
  echo "Síntoma esperado:"
  echo "  - El pod va a quedar en CrashLoopBackOff (o Error) para uno de"
  echo "    sus containers (READY va a mostrar 1/2)."
  echo "  - El pod tiene DOS containers (app y log-shipper). Si corrés"
  echo "    'kubectl logs <pod> -n ${NAMESPACE}' sin especificar container,"
  echo "    kubectl te va a devolver un error pidiendo que uses -c."
  echo
  echo "Objetivo:"
  echo "  1) Usando SOLO kubectl logs (con -c y, si hace falta, --previous),"
  echo "     identificá cuál de los dos containers falla y cuál es el"
  echo "     mensaje de error exacto que explica por qué."
  echo "  2) Arreglá el Deployment orders-api (sin borrarlo y recrearlo"
  echo "     desde cero) para que TODOS los containers del pod queden"
  echo "     Running de forma estable, sin reinicios nuevos."
  echo "  3) Confirmá el arreglo mirando 'kubectl logs -f deploy/${DEPLOY}"
  echo "     -c app -n ${NAMESPACE}' y viendo los heartbeats sostenidos."
  echo
  echo "Cuando termines, limpiá con: $0 clean"
  echo "=========================================================="
}

clean_scenario() {
  echo ">>> Borrando namespace '${NAMESPACE}' y todo lo que contiene..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
  echo "Listo."
}

main() {
  local action="${1:-break}"
  case "${action}" in
    break)
      check_prereqs
      break_scenario
      ;;
    clean)
      check_prereqs
      clean_scenario
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"

# ==========================================================================
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# ==========================================================================
#
# 1. Ver el estado del pod:
#      kubectl get pods -n ckad-333-logs
#    Vas a ver algo como:
#      orders-api-7f9c9b6f9d-abcde   1/2   CrashLoopBackOff   4   3m
#
# 2. Intentar ver logs sin indicar container (falla a propósito):
#      kubectl logs orders-api-7f9c9b6f9d-abcde -n ckad-333-logs
#    kubectl responde:
#      error: a container name must be specified for pod orders-api-...,
#      choose one of: [app log-shipper]
#
# 3. Ver logs del container "app" (el sospechoso, porque log-shipper es
#    un simple sleep que no puede fallar):
#      kubectl logs orders-api-7f9c9b6f9d-abcde -c app -n ckad-333-logs
#    Si el container ya reinició y el intento actual todavía no generó
#    output, agregar --previous para ver el último intento que sí corrió:
#      kubectl logs orders-api-7f9c9b6f9d-abcde -c app --previous -n ckad-333-logs
#    En ambos casos el mensaje clave es:
#      [orders-api] FATAL: DB_DSN environment variable is not set, cannot connect to database
#
# 4. Confirmar la causa con describe (opcional, refuerza el diagnóstico):
#      kubectl describe pod orders-api-7f9c9b6f9d-abcde -n ckad-333-logs
#    Vas a ver "State: Waiting - Reason: CrashLoopBackOff" y
#    "Last State: Terminated - Reason: Error - Exit Code: 1" para "app".
#
# 5. Arreglar el Deployment agregando la variable de entorno que falta.
#    Como los Pods no permiten editar env vars in-place, hay que tocar el
#    Deployment (esto dispara un rollout con un Pod nuevo):
#      kubectl set env deployment/orders-api -c app \
#        DB_DSN="postgres://orders:changeme@db:5432/orders" \
#        -n ckad-333-logs
#
# 6. Esperar el rollout y confirmar que el nuevo pod queda estable:
#      kubectl rollout status deployment/orders-api -n ckad-333-logs
#      kubectl get pods -n ckad-333-logs
#
# 7. Verificar los logs del container arreglado, siguiendo en vivo:
#      kubectl logs -f deploy/orders-api -c app -n ckad-333-logs
#    Deberías ver:
#      [orders-api] booting...
#      [orders-api] loading configuration...
#      [orders-api] connected to postgres://orders:changeme@db:5432/orders
#      [orders-api] heartbeat OK (1)
#      [orders-api] heartbeat OK (2)
#      ...
#    sin más reinicios (RESTARTS se mantiene fijo en kubectl get pods).
#
# 8. Limpieza del laboratorio:
#      kubectl delete namespace ckad-333-logs
# ==========================================================================