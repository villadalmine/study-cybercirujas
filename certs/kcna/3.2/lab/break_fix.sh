#!/usr/bin/env bash
#
# KCNA - Dominio 3.2 "Scheduling" (peso en el examen: 4)
# Laboratorio break & fix: nodeSelector inválido -> Pods en Pending
#
# Referencia curricular: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# Objetivo de examen que cubre: entender cómo el kube-scheduler asigna Pods
# a Nodes, y cómo las restricciones de scheduling que impone un admin
# (nodeSelector, node affinity/anti-affinity, taints y tolerations) pueden
# dejar Pods sin poder ser programados.
#
# USO:
#   ./kcna-3-2-scheduling-breakfix.sh break [--yes]
#   ./kcna-3-2-scheduling-breakfix.sh hints
#   ./kcna-3-2-scheduling-breakfix.sh cleanup
#
# Ejecutar SOLO contra un cluster de laboratorio descartable (kind, minikube,
# k3d, etc.). El script crea y borra su propio namespace; no toca nada fuera
# de él salvo un label de Node que el propio estudiante puede agregar como
# parte del fix (y que "cleanup" revierte).

set -euo pipefail

NAMESPACE="kcna-scheduling-lab"
DEPLOYMENT="broken-scheduler-demo"
LABEL_KEY="kcna.example.com/disk"
LABEL_VALUE="ssd-fast"

banner() {
  cat <<'EOF'
============================================================
 KCNA 3.2 Scheduling - Laboratorio break & fix
============================================================
Este laboratorio rompe la capacidad del kube-scheduler de
asignar Pods a un Node, usando una restricción de scheduling
(nodeSelector) que ningún Node del cluster cumple.

Vas a tener que diagnosticar el síntoma con kubectl y decidir
vos mismo cuál de las soluciones válidas aplicar.
============================================================
EOF
}

check_prereqs() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: no se encontró kubectl en el PATH." >&2
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl no puede contactar a ningún cluster. Configurá el kubeconfig de tu VM de laboratorio." >&2
    exit 1
  fi
}

confirm_lab() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '<desconocido>')"
  echo "Contexto actual de kubectl: $ctx"
  if [[ "${1:-}" == "--yes" ]]; then
    return 0
  fi
  read -r -p "Este script modifica el namespace '$NAMESPACE' en ese cluster. Confirmá que es una VM de laboratorio DESCARTABLE (y no un cluster real) [escribí 'si' para continuar]: " ans
  if [[ "$ans" != "si" ]]; then
    echo "Cancelado."
    exit 1
  fi
}

break_it() {
  check_prereqs
  confirm_lab "${1:-}"

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT
  namespace: $NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $DEPLOYMENT
  template:
    metadata:
      labels:
        app: $DEPLOYMENT
    spec:
      nodeSelector:
        $LABEL_KEY: $LABEL_VALUE
      containers:
        - name: nginx
          image: nginx:stable
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
EOF

  echo
  echo "Esperando unos segundos a que el scheduler intente asignar los Pods..."
  sleep 8

  echo
  echo "------------------------------------------------------------"
  echo " SÍNTOMA"
  echo "------------------------------------------------------------"
  kubectl -n "$NAMESPACE" get pods -o wide
  echo
  echo "Vas a ver los Pods del Deployment '$DEPLOYMENT' en estado Pending"
  echo "y sin Node asignado, y no van a salir de ese estado solos."
  echo
  echo "------------------------------------------------------------"
  echo " TU DESAFÍO"
  echo "------------------------------------------------------------"
  echo "Lográ que todos los Pods del Deployment '$DEPLOYMENT' en el"
  echo "namespace '$NAMESPACE' queden en estado Running, SIN borrar ni"
  echo "recrear el Deployment desde cero."
  echo
  echo "Pistas de diagnóstico (correr 'hints' para verlas de nuevo):"
  echo "  kubectl -n $NAMESPACE get pods"
  echo "  kubectl -n $NAMESPACE describe pod <nombre-de-un-pod>   # mirá la sección Events"
  echo "  kubectl get nodes --show-labels"
  echo "------------------------------------------------------------"
}

hints() {
  cat <<EOF
Comandos útiles para diagnosticar por qué un Pod queda Pending:

  kubectl -n $NAMESPACE get pods -o wide
  kubectl -n $NAMESPACE describe pod <nombre-de-un-pod>
  kubectl -n $NAMESPACE get events --sort-by=.lastTimestamp
  kubectl get nodes --show-labels
  kubectl -n $NAMESPACE get deployment $DEPLOYMENT -o yaml

Preguntate: ¿qué restricción de scheduling tiene el Pod en spec.template.spec
que ningún Node del cluster satisface? ¿Cómo se corrige eso, ya sea desde el
lado del Node o desde el lado del Pod?
EOF
}

cleanup() {
  check_prereqs
  echo "Borrando namespace '$NAMESPACE'..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found

  echo "Revirtiendo el label '$LABEL_KEY' en los Nodes (si se llegó a agregar)..."
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    kubectl label node "$node" "${LABEL_KEY}-" >/dev/null 2>&1 || true
  done
  echo "Cleanup completo."
}

usage() {
  echo "Uso: $0 {break [--yes]|hints|cleanup}"
  exit 1
}

main() {
  banner
  case "${1:-}" in
    break)
      break_it "${2:-}"
      ;;
    hints)
      hints
      ;;
    cleanup)
      cleanup
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"

# ==============================================================================
# SOLUCIÓN (spoiler — leé esto solo después de intentar resolverlo)
# ==============================================================================
#
# Qué se rompió:
#   El Deployment "broken-scheduler-demo" tiene, en spec.template.spec:
#     nodeSelector:
#       kcna.example.com/disk: ssd-fast
#   Ningún Node del cluster tiene ese label, así que el kube-scheduler no
#   encuentra ningún Node candidato y los Pods quedan Pending indefinidamente.
#
# Cómo se diagnostica:
#   1. kubectl -n kcna-scheduling-lab get pods
#      -> STATUS: Pending, sin NODE asignado.
#   2. kubectl -n kcna-scheduling-lab describe pod <pod>
#      -> En la sección Events vas a ver algo como:
#         "0/1 nodes are available: 1 node(s) didn't match Pod's node
#          affinity/selector."
#   3. kubectl get nodes --show-labels
#      -> Confirma que ningún Node tiene el label kcna.example.com/disk.
#
# Cómo se arregla (cualquiera de las dos es válida y demuestra el concepto):
#
#   Opción 1 - agregar el label faltante al Node (simula que un admin
#   etiqueta el hardware real para que coincida con lo que pide el Pod):
#     NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
#     kubectl label node "$NODE" kcna.example.com/disk=ssd-fast
#
#   Opción 2 - si la restricción no debería existir, quitar el nodeSelector
#   del Deployment:
#     kubectl -n kcna-scheduling-lab patch deployment broken-scheduler-demo \
#       --type=json \
#       -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
#
# Verificación:
#   kubectl -n kcna-scheduling-lab rollout status deployment/broken-scheduler-demo
#   kubectl -n kcna-scheduling-lab get pods -o wide
#   -> Los 2 Pods deben quedar Running y con NODE asignado.
#
# Para volver la VM de laboratorio a un estado limpio:
#   ./kcna-3-2-scheduling-breakfix.sh cleanup
# ==============================================================================