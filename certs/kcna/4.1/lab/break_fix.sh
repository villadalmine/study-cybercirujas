#!/usr/bin/env bash
#
# break-fix-kcna-4.1.sh
# KCNA - Dominio 4.1: Cloud Native Ecosystem and Principles
# Principio bajo prueba: ELASTICITY / AUTOSCALING (uno de los pilares
# cloud native descritos en el KCNA Curriculum: la capacidad de un
# sistema de escalar automáticamente en base a demanda real, apoyada
# en el ecosistema CNCF - metrics-server / Metrics API).
#
# Este script está pensado para correr en una VM de laboratorio
# DESCARTABLE con un cluster kind/minikube/k3d ya funcionando.
# NO ejecutar contra un cluster real o compartido.

set -euo pipefail

NAMESPACE="kcna-401-lab"
APP="cpu-demo"
METRICS_NS="kube-system"
METRICS_DEPLOY="metrics-server"

c_red()   { printf '\033[31m%s\033[0m\n' "$1"; }
c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$1"; }

require_lab_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "$ctx" ]]; then
    c_red "No hay un contexto de kubectl activo. Abortando."
    exit 1
  fi
  if [[ "$ctx" != *kind* && "$ctx" != *minikube* && "$ctx" != *k3d* && "$ctx" != *k3s* && "${ALLOW_ANY_CLUSTER:-0}" != "1" ]]; then
    c_red "El contexto actual ('$ctx') no parece ser un cluster de laboratorio descartable (kind/minikube/k3d)."
    c_red "Si estás seguro de lo que hacés, reexecutá con ALLOW_ANY_CLUSTER=1."
    exit 1
  fi
  c_blue "Contexto de laboratorio detectado: $ctx"
}

check_deps() {
  command -v kubectl >/dev/null 2>&1 || { c_red "kubectl no encontrado."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { c_red "No se puede contactar al cluster."; exit 1; }
}

ensure_metrics_server() {
  if kubectl -n "$METRICS_NS" get deployment "$METRICS_DEPLOY" >/dev/null 2>&1; then
    c_blue "metrics-server ya está instalado, se reutiliza."
  else
    c_blue "Instalando metrics-server (requerido para que autoscaling funcione)..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    # kind/minikube usan certificados kubelet self-signed: se necesita --kubelet-insecure-tls
    kubectl -n "$METRICS_NS" patch deployment "$METRICS_DEPLOY" --type=json -p \
      '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
      >/dev/null 2>&1 || true
  fi
  kubectl -n "$METRICS_NS" rollout status deployment/"$METRICS_DEPLOY" --timeout=120s
}

deploy_app() {
  c_blue "Desplegando aplicación de demo con HPA configurado..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP
  template:
    metadata:
      labels:
        app: $APP
    spec:
      containers:
      - name: $APP
        image: registry.k8s.io/hpa-example
        resources:
          requests:
            cpu: 200m
          limits:
            cpu: 500m
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: $APP
  namespace: $NAMESPACE
spec:
  selector:
    app: $APP
  ports:
  - port: 80
    targetPort: 80
EOF

  kubectl -n "$NAMESPACE" rollout status deployment/"$APP" --timeout=120s

  kubectl -n "$NAMESPACE" autoscale deployment "$APP" \
    --cpu-percent=50 --min=1 --max=5 --dry-run=client -o yaml | kubectl apply -f -
}

break_it() {
  c_yellow "Rompiendo el escenario de forma controlada..."
  kubectl -n "$METRICS_NS" scale deployment "$METRICS_DEPLOY" --replicas=0
  kubectl -n "$METRICS_NS" wait --for=delete pod -l k8s-app=metrics-server --timeout=60s 2>/dev/null || true

  echo
  c_red   "=================================================================="
  c_red   " ESCENARIO ROTO - KCNA 4.1: Cloud Native Ecosystem and Principles"
  c_red   "=================================================================="
  echo
  c_yellow "SÍNTOMA que vas a observar:"
  echo    "  - kubectl -n $NAMESPACE get hpa"
  echo    "    mostrará TARGETS como <unknown>/50% en lugar de un valor numérico."
  echo    "  - Aunque generes carga de CPU sobre el pod '$APP', el Horizontal"
  echo    "    Pod Autoscaler NO va a crear réplicas nuevas: el deployment se"
  echo    "    queda clavado en 1 réplica pase lo que pase."
  echo    "  - kubectl top pods / kubectl top nodes van a fallar o no devolver datos."
  echo
  c_yellow "OBJETIVO (principio cloud native evaluado: elasticity/autoscaling):"
  echo    "  El autoscaling es uno de los principios centrales del ecosistema"
  echo    "  cloud native: los sistemas deben poder escalar automáticamente en"
  echo    "  base a métricas reales, sin intervención manual. Ese comportamiento"
  echo    "  depende de que la Metrics API (metrics.k8s.io) esté disponible."
  echo
  echo    "  Tu tarea es diagnosticar POR QUÉ el HPA no puede leer métricas y"
  echo    "  restaurar el comportamiento correcto, de forma que:"
  echo    "    1) kubectl -n $NAMESPACE get hpa muestre un valor numérico en TARGETS."
  echo    "    2) Al generar carga sobre el servicio '$APP', el número de réplicas"
  echo    "       suba por encima de 1 (hasta un máximo de 5)."
  echo
  c_yellow "Pistas de diagnóstico permitidas:"
  echo    "  kubectl -n $NAMESPACE describe hpa $APP"
  echo    "  kubectl get apiservices | grep metrics"
  echo    "  kubectl -n $METRICS_NS get deployment $METRICS_DEPLOY"
  echo    "  kubectl -n $METRICS_NS get pods"
  echo
  c_yellow "Para generar carga una vez que arregles el problema (opcional, en otra terminal):"
  echo    "  kubectl -n $NAMESPACE run load-generator --image=busybox --restart=Never -- \\"
  echo    "    /bin/sh -c \"while true; do wget -q -O- http://$APP.$NAMESPACE.svc.cluster.local; done\""
  echo
  c_red   "=================================================================="
}

cleanup() {
  c_blue "Limpiando entorno de laboratorio..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  kubectl -n "$METRICS_NS" scale deployment "$METRICS_DEPLOY" --replicas=1 2>/dev/null || true
  kubectl -n "$METRICS_NS" delete pod load-generator --ignore-not-found 2>/dev/null || true
  c_green "Listo."
}

main() {
  if [[ "${1:-}" == "--cleanup" ]]; then
    require_lab_context
    cleanup
    exit 0
  fi

  require_lab_context
  check_deps
  ensure_metrics_server
  deploy_app
  break_it
}

main "$@"

# ==================================================================
# SOLUCIÓN PASO A PASO (para el instructor / autocorrección)
# ==================================================================
#
# 1) Confirmar el síntoma:
#      kubectl -n kcna-401-lab get hpa cpu-demo
#      -> TARGETS: <unknown>/50%
#
# 2) Revisar el estado del HPA en detalle:
#      kubectl -n kcna-401-lab describe hpa cpu-demo
#      -> Vas a ver un evento tipo "FailedGetResourceMetric" o
#         "unable to fetch metrics from resource metrics API"
#
# 3) Revisar si la Metrics API está registrada pero no disponible:
#      kubectl get apiservices | grep metrics
#      -> v1beta1.metrics.k8s.io   False (FailedDiscoveryCheck)
#
# 4) Revisar la causa raíz: el Deployment de metrics-server en kube-system
#    fue escalado a 0 réplicas:
#      kubectl -n kube-system get deployment metrics-server
#      -> READY 0/0
#
# 5) Arreglar restaurando las réplicas:
#      kubectl -n kube-system scale deployment metrics-server --replicas=1
#      kubectl -n kube-system rollout status deployment/metrics-server
#
# 6) Verificar que la Metrics API vuelve a estar disponible:
#      kubectl get apiservices | grep metrics
#      -> v1beta1.metrics.k8s.io   True
#      kubectl top nodes
#      kubectl top pods -n kcna-401-lab
#
# 7) Confirmar que el HPA vuelve a reportar un valor numérico:
#      kubectl -n kcna-401-lab get hpa cpu-demo -w
#      -> TARGETS: 0%/50% (o similar, ya no <unknown>)
#
# 8) Generar carga y verificar que ahora sí escala:
#      kubectl -n kcna-401-lab run load-generator --image=busybox --restart=Never -- \
#        /bin/sh -c "while true; do wget -q -O- http://cpu-demo.kcna-401-lab.svc.cluster.local; done"
#      kubectl -n kcna-401-lab get hpa cpu-demo -w
#      -> REPLICAS sube por encima de 1 en unos minutos.
#
# 9) Limpieza:
#      ./break-fix-kcna-4.1.sh --cleanup
# ==================================================================