#!/usr/bin/env bash
#
# CNPE - Tema 1.2: Using Cost Management Solutions for Right-Sizing and Scaling
# Script tipo "break & fix"
#
# CONTEXTO:
#   Este script asume que la VM de laboratorio (descartable) tiene:
#     - kubectl configurado contra un cluster local (kind/minikube/k3s)
#     - permisos para crear namespaces y recursos
#
# OBJETIVO PEDAGÓGICO:
#   El estudiante debe entender por qué el "right-sizing" (<PERSON>   requests/limits) es la base de cualquier solución de cost management
#   (Kubecost, VPA, HPA, Cluster Autoscaler). Sin requests correctamente
#   definidos, el autoscaling basado en métricas de recursos NO funciona,
#   lo que rompe tanto el scaling como la posibilidad de estimar costos
#   por workload.
#
# USO:
#   ./break_fix_1.2.sh break     -> rompe el escenario
#   ./break_fix_1.2.sh diagnose  -> pistas de diagnóstico
#   ./break_fix_1.2.sh verify    -> <PERSON> arregló
#   ./break_fix_1.2.sh cleanup   -> borra <PERSON> creado por el lab
#
set -euo pipefail

NAMESPACE="costlab"
DEPLOY="webapp"
HPA_NAME="webapp-hpa"

log() { echo -e "\n>>> $*\n"; }

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl no encontrado."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: no hay cluster accesible."; exit 1; }
}

ensure_metrics_server() {
  if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    log "Instalando metrics-server (requerido para HPA)..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl patch deployment metrics-server -n kube-system --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true
    log "Esperando a que metrics-server esté Ready..."
    kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
  fi
}

break_scenario() {
  check_prereqs
  ensure_metrics_server

  log "Creando namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  log "Desplegando '${DEPLOY}' SIN resource requests/limits (esto es lo que rompe el lab)..."
  cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  labels:
    app: ${DEPLOY}
spec:
  replicas: 1
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
        image: nginx:1.25
        ports:
        - containerPort: 80
EOF

  log "Creando HorizontalPodAutoscaler apuntando a CPU 50%..."
  cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${HPA_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${DEPLOY}
  <PERSON>: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
EOF

  kubectl rollout status deployment/${DEPLOY} -n "${NAMESPACE}" --timeout=60s

  cat <<'MSG'

============================================================
 SÍNTOMA QUE VA A OBSERVAR EL ESTUDIANTE
============================================================
Ejecutando:
  kubectl get hpa webapp-hpa -n costlab

Va a ver algo como:

  NAME         REFERENCE           TARGETS         MINPODS   MAXPODS   REPLICAS
  webapp-hpa   Deployment/webapp   <unknown>/50%   1         5         1

El HPA NUNCA calcula el porcentaje real de uso y nunca escala,
sin importar la carga que reciba el Deployment.

Con:
  kubectl describe hpa webapp-hpa -n costlab

Va a ver un evento tipo:
  Warning  FailedGetResourceMetric  ... missing request for cpu

============================================================
 QUÉ DEBE LOGRAR EL ESTUDIANTE
============================================================
1. Diagnosticar por qué el HPA no puede calcular utilización
   (pista: relación entre HPA, metrics-server y resource requests).
2. Corregir el Deployment 'webapp' en el namespace 'costlab' para
   que tenga 'resources.requests.cpu' (y opcionalmente limits.cpu)
   definidos en el contenedor.
3. Verificar que el HPA pase de <unknown>/50% a un valor numérico
   como 0%/50% o similar.
4. (Opcional, para pensar en cost management real) reflexionar:
   ¿qué pasa con herramientas como Kubecost si los workloads no
   declaran requests? ¿Cómo estiman costo por pod/namespace?

Use: ./break_fix_1.2.sh diagnose
Use: ./break_fix_1.2.sh verify
para asistencia y validación.
============================================================
MSG
}

diagnose() {
  log "<PERSON> actual del HPA:"
  kubectl get hpa "${HPA_NAME}" -n "${NAMESPACE}" || true
  log "Eventos del HPA (buscar 'FailedGetResourceMetric'):"
  kubectl describe hpa "${HPA_NAME}" -n "${NAMESPACE}" | tail -n 20 || true
  log "<PERSON> actual del contenedor (revisar 'resources'):"
  kubectl get deployment "${DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
}

verify() {
  check_prereqs
  REQ_CPU=$(kubectl get deployment "${DEPLOY}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "")

  if [[ -z "${REQ_CPU}" ]]; then
    echo "TODAVÍA ROTO: el contenedor no tiene resources.requests.cpu definido."
    exit 1
  fi

  log "requests.cpu definido: ${REQ_CPU}. <PERSON> (hasta 60s)..."
  for i in $(seq 1 12); do
    TARGETS=$(kubectl get hpa "${HPA_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "")
    if [[ -n "${TARGETS}" ]]; then
      echo "OK: HPA está reportando utilización real: ${TARGETS}%"
      echo "Lab resuelto correctamente."
      exit 0
    fi
    sleep 5
  done

  echo "AÚN NO: el HPA sigue sin reportar métricas. Revisar metrics-server y el request seteado."
  exit 1
}

cleanup() {
  log "Borrando namespace '${NAMESPACE}'..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
}

case "${1:-}" in
  break)    break_scenario ;;
  diagnose) diagnose ;;
  verify)   verify ;;
  cleanup)  cleanup ;;
  *)
    echo "Uso: $0 {break|diagnose|verify|cleanup}"
    exit 1
    ;;
esac

################################################################################
# SOLUCIÓN PASO A PASO (comentada, no se ejecuta automáticamente)
#
# Paso 1: Confirmar el diagnóstico
#   kubectl describe hpa webapp-hpa -n costlab
#   -> <PERSON> "FailedGetResourceMetric ... missing request for cpu"
#      Esto confirma que el HPA no puede calcular utilización porque el
#      Deployment no declara requests.cpu (base de todo right-sizing).
#
# Paso 2: Editar el Deployment para agregar requests (y limits) de CPU
#   kubectl edit deployment webapp -n costlab
#
#   Agregar bajo spec.template.spec.containers[0]:
#     resources:
#       requests:
#         cpu: "100m"
#         memory: "64Mi"
#       limits:
#         cpu: "200m"
#         memory: "128Mi"
#
#   Alternativa vía patch (más rápido para el instructor):
#   kubectl patch deployment webapp -n costlab --type='json' -p='[
#     {"op":"add","path":"/spec/template/spec/containers/0/resources",
#      "value":{"requests":{"cpu":"100m","memory":"64Mi"},
#               "limits":{"cpu":"200m","memory":"128Mi"}}}
#   ]'
#
# Paso 3: Esperar el rollout del nuevo ReplicaSet
#   kubectl rollout status deployment/webapp -n costlab
#
# Paso 4: <PERSON> utilización real
#   kubectl get hpa webapp-hpa -n costlab
#   -> TARGETS debería mostrar algo como "0%/50%" en vez de "<unknown>/50%"
#
# Paso 5 (opcional, generar carga para ver el scaling en acción):
#   kubectl run load-generator --image=busybox -n costlab --restart=Never -- \
#     /bin/sh -c "while true; do wget -q -O- http://webapp; done"
#   kubectl get hpa webapp-hpa -n costlab -w
#
# CONCEPTO CLAVE PARA EL EXAMEN:
#   - El right-sizing (requests/limits <PERSON>) es prerequisito
#     técnico para que funcionen HPA, VPA y Cluster Autoscaler.
#   - Herramientas de cost management (ej. Kubecost) usan estos mismos
#     requests/limits para atribuir costo estimado por pod/namespace;
#     sin ellos, <PERSON> right-sizing y los reportes de
#     costo pierden precisión o directamente no pueden calcularse.
################################################################################