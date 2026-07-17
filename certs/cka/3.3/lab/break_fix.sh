#!/usr/bin/env bash
#
# break-fix-cka-3.3-workload-autoscaling.sh
#
# CKA v1.35 - Dominio 3.3 "Configure workload autoscaling" (peso 2.5)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Rompe un HorizontalPodAutoscaler (HPA) de forma controlada, en un namespace
# descartable, para que el estudiante practique el diagnóstico y la
# reparación de un problema real y muy común en el examen.
#
# USO:
#   ./break-fix-cka-3.3-workload-autoscaling.sh break     # rompe el laboratorio (default)
#   ./break-fix-cka-3.3-workload-autoscaling.sh verify    # chequea si ya lo arreglaste
#   ./break-fix-cka-3.3-workload-autoscaling.sh cleanup   # borra todo lo creado
#
# REQUISITOS:
#   - kubectl apuntando a un cluster de laboratorio DESCARTABLE (kind/minikube/etc).
#   - metrics-server instalado y funcionando en el cluster (si no lo está, el
#     script lo instala en una versión mínima apta para laboratorio).
#
# SEGURIDAD: el script se niega a correr si el contexto actual de kubectl
# contiene "prod" en el nombre, como salvaguarda mínima.

set -euo pipefail

NAMESPACE="autoscaling-lab"
DEPLOY="revenue-api"
HPA_NAME="revenue-api-hpa"
ACTION="${1:-break}"

c_red()    { printf '\033[31m%s\033[0m\n' "$1"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
section()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { c_red "kubectl no está instalado."; exit 1; }
}

guard_not_prod() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "")"
  if [[ -z "$ctx" ]]; then
    c_red "No hay un contexto de kubectl activo. Abortando."
    exit 1
  fi
  if [[ "$ctx" == *prod* ]]; then
    c_red "El contexto actual ('$ctx') parece de producción. Este script NO debe correr ahí. Abortando."
    exit 1
  fi
  c_yellow "Contexto activo: $ctx"
}

ensure_metrics_server() {
  if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    return 0
  fi
  c_yellow "metrics-server no encontrado. Instalando una versión mínima para laboratorio..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # En clusters de un solo nodo (kind/minikube) el kubelet suele usar certificados
  # self-signed; metrics-server necesita --kubelet-insecure-tls para funcionar ahí.
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
    >/dev/null 2>&1 || true
  echo "Esperando a que metrics-server esté disponible (puede tardar ~1 min)..."
  kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system
}

do_break() {
  require_kubectl
  guard_not_prod
  ensure_metrics_server

  section "Preparando namespace y carga de trabajo"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # BUG INYECTADO: el Deployment no define resources.requests.cpu en el
  # contenedor. Un HorizontalPodAutoscaler que usa el tipo "Resource" (cpu)
  # necesita ese request para poder calcular el % de utilización: sin él,
  # el controller no tiene contra qué comparar el uso real.
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NAMESPACE}
  labels:
    app: ${DEPLOY}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ${DEPLOY}
  template:
    metadata:
      labels:
        app: ${DEPLOY}
    spec:
      containers:
      - name: ${DEPLOY}
        image: registry.k8s.io/hpa-example
        ports:
        - containerPort: 80
        # <-- a propósito: NO hay bloque "resources" acá
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${HPA_NAME}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${DEPLOY}
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
EOF

  kubectl rollout status deployment/"$DEPLOY" -n "$NAMESPACE" --timeout=90s

  section "Laboratorio listo. Esto es lo que vas a ver"
  cat <<'MSG'
El Deployment "revenue-api" y el HPA "revenue-api-hpa" ya están creados,
pero el autoscaler NO está funcionando como debería.

Síntoma a observar:

    kubectl get hpa revenue-api-hpa -n autoscaling-lab

  La columna TARGETS va a mostrar algo como:

    NAME               REFERENCE                TARGETS         MINPODS  MAXPODS  REPLICAS
    revenue-api-hpa    Deployment/revenue-api    <unknown>/50%   2        6        3

  Y si describís el HPA vas a ver un evento del tipo:

    kubectl describe hpa revenue-api-hpa -n autoscaling-lab

    Warning  FailedGetResourceMetric  ... missing request for cpu on container
             "revenue-api" in pod "revenue-api-xxxx"

TU OBJETIVO:

  Lograr que el HPA pueda calcular la utilización de CPU real y quede
  operativo, sin borrar ni recrear el HPA ni el Deployment desde cero.

CRITERIO DE ÉXITO (correlo con: ./break-fix-cka-3.3-workload-autoscaling.sh verify):

  1. `kubectl get hpa revenue-api-hpa -n autoscaling-lab` muestra un
     porcentaje numérico en TARGETS (ej. "1%/50%"), no "<unknown>/50%".
  2. `kubectl describe hpa revenue-api-hpa -n autoscaling-lab` ya no
     reporta eventos FailedGetResourceMetric recientes.
  3. Los 3 Pods de revenue-api siguen corriendo (Running).

Pista: mirá qué necesita el HPA para poder medir el uso de CPU de un Pod
respecto de un valor de referencia.
MSG
}

do_verify() {
  require_kubectl
  section "Verificando el fix"

  local targets
  targets="$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "")"

  if [[ -z "$targets" ]]; then
    c_red "Todavía no hay métrica de utilización calculada. El HPA sigue en <unknown>."
    c_yellow "Repasá: ¿el contenedor de revenue-api ya tiene resources.requests.cpu definido?"
    exit 1
  fi

  c_green "El HPA ya está calculando utilización de CPU (${targets}%). ¡Resuelto!"
}

do_cleanup() {
  require_kubectl
  section "Limpiando laboratorio"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
}

case "$ACTION" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *) c_red "Uso: $0 {break|verify|cleanup}"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# ---------------------------------------------------------------------------
#
# El HPA no puede calcular utilización porque el contenedor "revenue-api"
# no tiene definido resources.requests.cpu: la utilización se calcula como
# (uso actual / request), así que sin request no hay base de cálculo.
#
# 1) Confirmar el diagnóstico:
#
#      kubectl describe hpa revenue-api-hpa -n autoscaling-lab
#      # Ver el evento: "missing request for cpu on container revenue-api"
#
# 2) Agregar el request de CPU faltante al Deployment (sin recrearlo):
#
#      kubectl set resources deployment/revenue-api -n autoscaling-lab \
#        --containers=revenue-api --requests=cpu=200m
#
#    (equivalente editando el manifiesto con `kubectl edit deployment
#    revenue-api -n autoscaling-lab` y agregando bajo el contenedor:
#
#      resources:
#        requests:
#          cpu: 200m
#    )
#
# 3) Esperar el rollout y confirmar que los Pods nuevos ya tienen el request:
#
#      kubectl rollout status deployment/revenue-api -n autoscaling-lab
#      kubectl get pods -n autoscaling-lab -o jsonpath='{.items[0].spec.containers[0].resources}'
#
# 4) Confirmar que el HPA ya calcula utilización real:
#
#      kubectl get hpa revenue-api-hpa -n autoscaling-lab -w
#      # TARGETS debería pasar de "<unknown>/50%" a algo como "1%/50%"
#
# 5) (Opcional) Generar carga para ver el scale-up en acción:
#
#      kubectl run load-generator --rm -it --image=busybox:1.36 \
#        --restart=Never -n autoscaling-lab -- \
#        /bin/sh -c "while true; do wget -q -O- http://revenue-api; done"
#
#      kubectl get hpa revenue-api-hpa -n autoscaling-lab -w
#      # Con el tiempo REPLICAS debería subir por encima de 2
# ---------------------------------------------------------------------------
