#!/usr/bin/env bash
#
# break-fix_kcna_2.1_application-delivery.sh
#
# KCNA - Tema 2.1 Application Delivery (peso examen: 5.3%)
# Fuente de referencia (curricula oficial CNCF):
#   https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# Ejercicio "break & fix": corre en una VM de laboratorio DESCARTABLE con un
# cluster Kubernetes accesible via kubectl (kind/minikube/k3s/etc). Crea un
# Deployment + Service aislados en un namespace propio, deja todo sano, y
# luego rompe UNA sola cosa relacionada con cómo un Service entrega tráfico
# a los Pods (el corazón de "Application Delivery" en KCNA). No toca nada
# fuera de su propio namespace.
#
# Uso:
#   ./break-fix_kcna_2.1_application-delivery.sh setup    # crea el lab y lo rompe
#   ./break-fix_kcna_2.1_application-delivery.sh check    # el estudiante verifica si ya arregló
#   ./break-fix_kcna_2.1_application-delivery.sh cleanup  # borra el namespace del lab
#
set -euo pipefail

NAMESPACE="kcna-2-1-app-delivery-lab"
APP="web-frontend"
SVC="web-frontend-svc"
TESTER="net-tester"
MANAGED_LABEL="kcna-lab-script=app-delivery"

log()  { printf '\n[lab] %s\n' "$*"; }
die()  { printf '\n[lab][ERROR] %s\n' "$*" >&2; exit 1; }

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl no está instalado o no está en el PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No se pudo contactar al cluster. ¿Está corriendo tu VM de lab (kind/minikube/k3s)?"

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  log "Contexto actual de kubectl: ${ctx}"
  if [[ "${ctx}" == *"prod"* ]]; then
    die "El contexto '${ctx}' contiene 'prod'. Este script es para una VM de lab descartable, abortando por seguridad."
  fi

  if [[ "${FORCE:-}" != "yes" ]]; then
    read -r -p "Esto va a crear/romper recursos en el namespace '${NAMESPACE}' del contexto '${ctx}'. Escribí 'romper' para confirmar: " confirm
    [[ "${confirm}" == "romper" ]] || die "Confirmación no recibida, abortando sin tocar nada."
  fi
}

deploy_lab() {
  log "Creando namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl label -f - "${MANAGED_LABEL}" --local -o yaml | kubectl apply -f -

  log "Desplegando Deployment '${APP}' (2 réplicas nginx) y Service '${SVC}'..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP}
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: ${TESTER}
  namespace: ${NAMESPACE}
  labels:
    app: net-tester
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
EOF

  log "Esperando a que el Deployment esté listo..."
  kubectl -n "${NAMESPACE}" rollout status deployment/"${APP}" --timeout=90s

  log "Esperando a que el pod de test esté listo..."
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod/"${TESTER}" --timeout=60s

  log "Verificando que el lab arranca sano (esto DEBE devolver 200)..."
  local code
  code="$(kubectl -n "${NAMESPACE}" exec "${TESTER}" -- curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${SVC}/" || echo "000")"
  [[ "${code}" == "200" ]] || die "El lab no arrancó sano (HTTP ${code}). Revisá el cluster antes de continuar."
  log "Baseline OK (HTTP 200). Ahora se rompe algo a propósito..."
}

break_lab() {
  kubectl -n "${NAMESPACE}" patch service "${SVC}" --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"${APP}-typo\"}}}" >/dev/null

  cat <<EOM

============================================================
 KCNA 2.1 Application Delivery - Break & Fix
============================================================

Contexto:
  Un Service de Kubernetes no "sabe" de sus Pods por nombre: los
  descubre dinámicamente comparando su spec.selector contra las
  labels de los Pods. Esa relación (Service -> Endpoints -> Pods)
  es la base de cómo se entrega tráfico a una app en el cluster.

Qué acabo de romper:
  Modifiqué el Service '${SVC}' en el namespace '${NAMESPACE}'.
  No toqué el Deployment ni los Pods: siguen Running y Ready.

Síntoma que vas a ver:
  - kubectl -n ${NAMESPACE} exec ${TESTER} -- curl -m 3 http://${SVC}/
    se cuelga y termina en timeout (o "Connection refused").
  - kubectl -n ${NAMESPACE} get endpoints ${SVC}
    muestra ENDPOINTS = <none>, a pesar de que los pods están sanos.

Tu objetivo:
  Sin borrar ni recrear el Deployment, hacer que el Service vuelva
  a entregar tráfico a los dos Pods de '${APP}'. Vas a saber que
  terminaste cuando:
    1) kubectl -n ${NAMESPACE} get endpoints ${SVC} liste 2 IPs, y
    2) curl contra http://${SVC}/ desde el pod '${TESTER}' devuelva HTTP 200.

Pistas (comandos, no la respuesta):
  kubectl -n ${NAMESPACE} get pods --show-labels
  kubectl -n ${NAMESPACE} get svc ${SVC} -o jsonpath='{.spec.selector}{"\n"}'
  kubectl -n ${NAMESPACE} describe svc ${SVC}

Para autoevaluarte en cualquier momento:
  $0 check

Cuando termines, limpiá el lab con:
  $0 cleanup
============================================================
EOM
}

do_check() {
  check_prereqs_light() {
    command -v kubectl >/dev/null 2>&1 || die "kubectl no está instalado."
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || die "El namespace '${NAMESPACE}' no existe. Corré '$0 setup' primero."
  }
  check_prereqs_light

  local endpoints code
  endpoints="$(kubectl -n "${NAMESPACE}" get endpoints "${SVC}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  code="$(kubectl -n "${NAMESPACE}" exec "${TESTER}" -- curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${SVC}/" 2>/dev/null || echo "000")"

  log "Endpoints de ${SVC}: ${endpoints:-<none>}"
  log "HTTP status vía Service: ${code}"

  if [[ -n "${endpoints}" && "${code}" == "200" ]]; then
    log "PASS: el Service vuelve a entregar tráfico a los Pods. ¡Arreglado!"
  else
    log "FAIL: todavía no hay endpoints y/o la app no responde 200. Seguí investigando."
  fi
}

do_cleanup() {
  if kubectl get namespace "${NAMESPACE}" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q "kcna-lab-script"; then
    log "Borrando namespace '${NAMESPACE}'..."
    kubectl delete namespace "${NAMESPACE}" --wait=false
  else
    log "El namespace '${NAMESPACE}' no existe o no fue creado por este script, no se toca nada."
  fi
}

usage() {
  echo "Uso: $0 {setup|check|cleanup}"
  exit 1
}

case "${1:-}" in
  setup)
    check_prereqs
    deploy_lab
    break_lab
    ;;
  check)
    do_check
    ;;
  cleanup)
    do_cleanup
    ;;
  *)
    usage
    ;;
esac

# ============================================================
# SOLUCIÓN PASO A PASO (spoiler - no leer antes de intentarlo)
# ============================================================
#
# 1) Diagnosticar que el problema es de "descubrimiento", no de la app:
#      kubectl -n kcna-2-1-app-delivery-lab get pods -o wide
#      -> los 2 pods de web-frontend están Running y READY 1/1.
#
# 2) Confirmar que el Service no tiene endpoints:
#      kubectl -n kcna-2-1-app-delivery-lab get endpoints web-frontend-svc
#      -> ENDPOINTS: <none>
#
# 3) Comparar el selector del Service contra las labels reales de los pods:
#      kubectl -n kcna-2-1-app-delivery-lab get svc web-frontend-svc \
#        -o jsonpath='{.spec.selector}{"\n"}'
#      -> {"app":"web-frontend-typo"}
#      kubectl -n kcna-2-1-app-delivery-lab get pods --show-labels
#      -> app=web-frontend
#      El selector no matchea ninguna label: por eso no hay endpoints.
#
# 4) Corregir el selector del Service para que vuelva a matchear
#    las labels reales de los pods (sin tocar el Deployment):
#      kubectl -n kcna-2-1-app-delivery-lab patch service web-frontend-svc \
#        --type merge -p '{"spec":{"selector":{"app":"web-frontend"}}}'
#
# 5) Verificar la reparación:
#      kubectl -n kcna-2-1-app-delivery-lab get endpoints web-frontend-svc
#      -> debe listar 2 IPs (una por pod)
#      kubectl -n kcna-2-1-app-delivery-lab exec net-tester -- \
#        curl -s -o /dev/null -w '%{http_code}\n' http://web-frontend-svc/
#      -> debe imprimir 200
#
# Concepto clave para el examen KCNA:
#   Un Service NO enruta por nombre de Pod ni por Deployment: usa
#   spec.selector para armar (vía el controller de Endpoints/EndpointSlices)
#   la lista de IPs de Pods a las que hace load balancing. Un typo en el
#   selector -o en las labels del template del Deployment- deja al Service
#   "vacío" aunque los Pods estén perfectamente sanos.