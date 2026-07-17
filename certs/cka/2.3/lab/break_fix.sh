#!/usr/bin/env bash
#
# CKA v1.35 - Dominio 2.3: Monitor cluster and application resource usage (peso: 6)
# Fuente de referencia del temario (no se copia texto, solo se cita):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Break & Fix: metrics-server queda "sano" a nivel Pod pero deja de servir
# métricas porque su Service pierde el selector correcto. El estudiante debe
# diagnosticar por qué "kubectl top" deja de funcionar y restaurar el pipeline
# de métricas sin reinstalar metrics-server desde cero.
#
# Pensado para correr UNA SOLA VEZ contra una VM/cluster de laboratorio
# DESCARTABLE (kubeadm, kind, minikube, etc). No usar contra un cluster real.

set -euo pipefail

NAMESPACE="resource-lab"
APP_NAME="load-demo"
MS_NAMESPACE="kube-system"
MS_DEPLOYMENT="metrics-server"
MS_SERVICE="metrics-server"
MS_LABEL_KEY="k8s-app"
MS_LABEL_VALUE="metrics-server"
BROKEN_LABEL_VALUE="metrics-server-disabled"

log()  { printf '\n[lab] %s\n' "$1"; }
warn() { printf '\n[!!] %s\n' "$1"; }

require_confirmation() {
  if [[ "${FORCE:-}" == "1" ]]; then
    return 0
  fi
  warn "Este script modifica el cluster apuntado por tu kubeconfig actual."
  kubectl config current-context 2>/dev/null || true
  read -r -p "Confirmás que es una VM/cluster de laboratorio DESCARTABLE? (escribí 'si'): " ans
  if [[ "$ans" != "si" ]]; then
    echo "Cancelado. No se modificó nada."
    exit 1
  fi
}

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado en PATH."; exit 1; }
  kubectl get nodes >/dev/null 2>&1 || { echo "No se puede contactar al cluster. Revisá tu kubeconfig."; exit 1; }
}

ensure_metrics_server() {
  if kubectl get deployment "$MS_DEPLOYMENT" -n "$MS_NAMESPACE" >/dev/null 2>&1; then
    log "metrics-server ya está instalado, se reutiliza."
  else
    log "metrics-server no está instalado, se instala el manifest oficial."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    log "Se agrega --kubelet-insecure-tls (habitual en labs con certificados self-signed)."
    kubectl patch deployment "$MS_DEPLOYMENT" -n "$MS_NAMESPACE" --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  fi
  log "Esperando rollout de metrics-server..."
  kubectl rollout status deployment/"$MS_DEPLOYMENT" -n "$MS_NAMESPACE" --timeout=120s

  log "Esperando a que la Metrics API responda (puede tardar ~30-60s)..."
  for i in $(seq 1 20); do
    if kubectl top nodes >/dev/null 2>&1; then
      log "Metrics API respondiendo OK."
      return 0
    fi
    sleep 5
  done
  warn "La Metrics API no respondió a tiempo. Revisá metrics-server antes de continuar."
  exit 1
}

deploy_lab_workload() {
  log "Desplegando carga de ejemplo en namespace '$NAMESPACE' para tener algo que monitorear."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  namespace: $NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
    spec:
      containers:
        - name: $APP_NAME
          image: nginx:stable
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
EOF
  kubectl rollout status deployment/"$APP_NAME" -n "$NAMESPACE" --timeout=90s
}

prove_baseline_healthy() {
  log "Estado ANTES de romper nada (baseline sano):"
  kubectl top nodes || true
  kubectl top pods -n "$NAMESPACE" || true
}

break_it() {
  log "Rompiendo el pipeline de métricas de forma controlada..."
  kubectl patch svc "$MS_SERVICE" -n "$MS_NAMESPACE" --type merge \
    -p "{\"spec\":{\"selector\":{\"$MS_LABEL_KEY\":\"$BROKEN_LABEL_VALUE\"}}}"
  log "Listo. El Service '$MS_SERVICE' ya no selecciona ningún Pod."
}

prove_symptom() {
  log "Estado DESPUÉS de la falla (esto es lo que vas a ver vos también):"
  sleep 5
  kubectl top nodes 2>&1 || true
  kubectl top pods -n "$NAMESPACE" 2>&1 || true
}

print_challenge() {
  cat <<'EOF'

============================================================
 DESAFÍO - CKA 2.3 Monitor cluster and application resource usage
============================================================
SÍNTOMA:
  - "kubectl top nodes" y "kubectl top pods" fallan con un error del
    estilo "Metrics API not available" o "the server is currently
    unable to handle the request" (metrics.k8s.io).
  - Los Pods de metrics-server en el namespace kube-system están
    Running y sin restarts: el problema NO está en el propio Pod.

OBJETIVO:
  Restaurar "kubectl top nodes" y "kubectl top pods" a un estado
  funcional, SIN eliminar ni reinstalar el Deployment de
  metrics-server. Hay un único recurso mal configurado.

PISTAS DE POR DÓNDE EMPEZAR (comandos, no respuestas):
  kubectl get apiservice v1beta1.metrics.k8s.io -o yaml
  kubectl get endpoints metrics-server -n kube-system
  kubectl describe svc metrics-server -n kube-system
  kubectl get pods -n kube-system -l k8s-app=metrics-server --show-labels

Cuando "kubectl top nodes" vuelva a mostrar datos, el desafío está
resuelto. La solución comentada está al final de este script, pero
tratá de resolverlo antes de leerla.
============================================================

EOF
}

main() {
  check_prereqs
  require_confirmation
  ensure_metrics_server
  deploy_lab_workload
  prove_baseline_healthy
  break_it
  prove_symptom
  print_challenge
}

main "$@"

# ============================================================
# SOLUCIÓN PASO A PASO (spoiler)
# ============================================================
#
# 1. Confirmar el síntoma:
#      kubectl top nodes
#      kubectl top pods -A
#    -> Error from server (ServiceUnavailable): the server is currently
#       unable to handle the request (get nodes.metrics.k8s.io)
#
# 2. Revisar la condición de la APIService que agrega metrics.k8s.io:
#      kubectl get apiservice v1beta1.metrics.k8s.io -o yaml
#    -> status.conditions muestra Available=False con un mensaje del
#       estilo "endpoints for service/metrics-server in namespace
#       kube-system have no addresses". Esto descarta que el problema
#       esté en el kube-apiserver o en el propio Pod de metrics-server.
#
# 3. Confirmar que el Deployment y los Pods de metrics-server están OK:
#      kubectl get deployment,pods -n kube-system -l k8s-app=metrics-server
#    -> Deployment con réplicas disponibles, Pods Running, 0 restarts.
#
# 4. Revisar los Endpoints del Service (acá está la falla real):
#      kubectl get endpoints metrics-server -n kube-system
#    -> ENDPOINTS: <none>. Un Service sin Endpoints, con Pods Running,
#       siempre apunta a un problema de selector/labels.
#
# 5. Comparar el selector del Service contra las labels reales del Pod:
#      kubectl get svc metrics-server -n kube-system -o jsonpath='{.spec.selector}{"\n"}'
#      kubectl get pods -n kube-system -l k8s-app=metrics-server --show-labels
#    -> El Service selecciona k8s-app=metrics-server-disabled, pero los
#       Pods tienen la label k8s-app=metrics-server.
#
# 6. Corregir el selector del Service para que vuelva a matchear los Pods:
#      kubectl patch svc metrics-server -n kube-system \
#        -p '{"spec":{"selector":{"k8s-app":"metrics-server"}}}'
#
# 7. Verificar que los Endpoints se repueblan y que la Metrics API responde:
#      kubectl get endpoints metrics-server -n kube-system
#      kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions}'
#      kubectl top nodes
#      kubectl top pods -n resource-lab
#
# ============================================================