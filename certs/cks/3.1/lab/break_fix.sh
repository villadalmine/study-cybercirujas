#!/usr/bin/env bash
#
# CKS v1.34 - Dominio 3: Minimize Microservice Vulnerabilities
# Tema 3.1: Use Role Based Access Controls to minimize exposure (peso: 3.75)
#
# Fuente de referencia (curriculum, no copiar literal):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Lab "break & fix": crea un workload cuyo ServiceAccount quedo atado a un
# ClusterRole/ClusterRoleBinding sobre-permisivo (mucho mas acceso del que
# la app realmente necesita). El objetivo del estudiante es detectar el
# exceso de privilegios y reducirlo al minimo indispensable (least privilege).
#
# SOLO para un cluster descartable de laboratorio (kind/minikube/k3d/VM
# efimera). No lo corras contra un cluster que te importe.

set -euo pipefail

NAMESPACE="cks-rbac-lab"
SA_NAME="log-shipper"
DEPLOY_NAME="log-shipper"
CR_NAME="log-shipper-cluster-role"
CRB_NAME="log-shipper-cluster-binding"

log()  { printf '\n\033[1;34m[lab]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$1"; }

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado en PATH"; exit 1; }
}

confirm_disposable_cluster() {
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "desconocido")
  warn "Contexto actual de kubectl: ${ctx}"
  if [[ "$ctx" =~ (gke_|eks|aks|arn:aws|prod|production) ]]; then
    fail "El contexto '${ctx}' parece un cluster real/administrado. Abortando por seguridad."
    exit 1
  fi
  read -r -p "Este script modifica RBAC y crea recursos cluster-scoped. Escribi BREAK para continuar: " reply
  [[ "$reply" == "BREAK" ]] || { echo "Cancelado."; exit 1; }
}

cmd_break() {
  require_kubectl
  confirm_disposable_cluster

  log "Creando namespace y ServiceAccount de la app..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  log "Otorgando permisos EXCESIVOS al ServiceAccount (esto es el 'break')..."
  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CR_NAME}
rules:
- apiGroups: [""]
  resources: ["pods", "configmaps", "secrets", "namespaces", "nodes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB_NAME}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: ${CR_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF

  log "Desplegando el workload que usa ese ServiceAccount..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOY_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
    spec:
      serviceAccountName: ${SA_NAME}
      containers:
      - name: log-shipper
        image: curlimages/curl:8.9.1
        command: ["sleep", "infinity"]
EOF

  kubectl rollout status deployment/"$DEPLOY_NAME" -n "$NAMESPACE" --timeout=60s

  cat <<'MSG'

================================================================
SINTOMA
================================================================
"log-shipper" es un agente que solo deberia poder LEER pods y
configmaps dentro de su propio namespace (para enriquecer logs
con metadata). Sin embargo, quedo desplegado con un ServiceAccount
que tiene un ClusterRoleBinding a nivel de todo el cluster.

Investiga el alcance real de sus privilegios, por ejemplo:

  kubectl auth can-i --list \
    --as=system:serviceaccount:cks-rbac-lab:log-shipper

  kubectl auth can-i list secrets --all-namespaces \
    --as=system:serviceaccount:cks-rbac-lab:log-shipper

  kubectl auth can-i delete pods -n kube-system \
    --as=system:serviceaccount:cks-rbac-lab:log-shipper

Vas a ver que el ServiceAccount puede leer Secrets de CUALQUIER
namespace (incluido kube-system) y hasta borrar/crear/modificar
pods y nodos en todo el cluster. Eso es una exposicion critica:
si el pod se compromete, el atacante hereda ese token con alcance
de cluster.

================================================================
OBJETIVO
================================================================
Aplicar el principio de minimo privilegio:

1. El ServiceAccount "log-shipper" debe conservar EXCLUSIVAMENTE
   los verbos get/list/watch sobre pods y configmaps, y unicamente
   dentro del namespace "cks-rbac-lab".
2. Eliminar el ClusterRole/ClusterRoleBinding cluster-scoped.
3. Reemplazarlo por un Role + RoleBinding namespaced con esas
   reglas minimas.
4. El pod del Deployment debe seguir funcionando (no hace falta
   reiniciarlo para que el cambio de RBAC tome efecto).

Verificacion sugerida (o corre: ./este_script.sh verify):

  kubectl auth can-i list secrets --all-namespaces \
    --as=system:serviceaccount:cks-rbac-lab:log-shipper      # debe ser "no"

  kubectl auth can-i list pods -n cks-rbac-lab \
    --as=system:serviceaccount:cks-rbac-lab:log-shipper      # debe ser "yes"

  kubectl auth can-i delete pods -n cks-rbac-lab \
    --as=system:serviceaccount:cks-rbac-lab:log-shipper      # debe ser "no"
================================================================
MSG
}

cmd_status() {
  require_kubectl
  log "Permisos actuales de system:serviceaccount:${NAMESPACE}:${SA_NAME}:"
  kubectl auth can-i --list -n "$NAMESPACE" \
    --as="system:serviceaccount:${NAMESPACE}:${SA_NAME}" || true
}

cmd_verify() {
  require_kubectl
  local sa="system:serviceaccount:${NAMESPACE}:${SA_NAME}"
  local pass=true

  check() {
    local expect="$1" verb="$2" resource="$3" ns_flag="$4" desc="$5"
    local result
    result=$(kubectl auth can-i "$verb" "$resource" $ns_flag --as="$sa" 2>/dev/null || echo "no")
    if [[ "$result" == "$expect" ]]; then
      ok "$desc (esperado: $expect, obtuvo: $result)"
    else
      fail "$desc (esperado: $expect, obtuvo: $result)"
      pass=false
    fi
  }

  log "Verificando que persista lo minimo necesario y se haya revocado el exceso..."
  check "yes" list pods    "-n $NAMESPACE" "puede listar pods en su namespace"
  check "yes" list configmaps "-n $NAMESPACE" "puede listar configmaps en su namespace"
  check "no"  delete pods  "-n $NAMESPACE" "NO puede borrar pods en su namespace"
  check "no"  list secrets "--all-namespaces" "NO puede listar secrets de todo el cluster"
  check "no"  list pods    "-n kube-system" "NO puede listar pods fuera de su namespace"

  if kubectl get clusterrolebinding "$CRB_NAME" >/dev/null 2>&1; then
    fail "El ClusterRoleBinding '${CRB_NAME}' todavia existe"
    pass=false
  else
    ok "El ClusterRoleBinding cluster-scoped fue eliminado"
  fi

  echo
  if $pass; then
    ok "RESULTADO: el ServiceAccount quedo con acceso minimo. Lab resuelto."
  else
    fail "RESULTADO: todavia hay exposicion de mas. Segui ajustando el RBAC."
    exit 1
  fi
}

cmd_teardown() {
  require_kubectl
  log "Limpiando recursos del lab..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  kubectl delete clusterrolebinding "$CRB_NAME" --ignore-not-found
  kubectl delete clusterrole "$CR_NAME" --ignore-not-found
  ok "Lab desmontado."
}

usage() {
  cat <<USAGE
Uso: $0 {break|status|verify|teardown}

  break     Crea el escenario con RBAC sobre-permisivo (el "bug" de seguridad)
  status    Muestra los permisos actuales del ServiceAccount del lab
  verify    Chequea si ya redujiste los privilegios al minimo correcto
  teardown  Elimina todos los recursos creados por el lab
USAGE
}

case "${1:-}" in
  break)    cmd_break ;;
  status)   cmd_status ;;
  verify)   cmd_verify ;;
  teardown) cmd_teardown ;;
  *)        usage; exit 1 ;;
esac

# ================================================================
# SOLUCION PASO A PASO (no se ejecuta, es referencia para el docente
# o para el estudiante que ya intento resolverlo por su cuenta)
# ================================================================
#
# 1. Confirmar el exceso de privilegios:
#
#    kubectl auth can-i --list \
#      --as=system:serviceaccount:cks-rbac-lab:log-shipper
#
#    (se ve acceso a secrets/nodes/namespaces en todo el cluster,
#    con verbos create/update/patch/delete que la app no necesita)
#
# 2. Crear un Role namespaced con solo lo que la app usa de verdad:
#
#    kubectl apply -f - <<EOF
#    apiVersion: rbac.authorization.k8s.io/v1
#    kind: Role
#    metadata:
#      name: log-shipper-role
#      namespace: cks-rbac-lab
#    rules:
#    - apiGroups: [""]
#      resources: ["pods", "configmaps"]
#      verbs: ["get", "list", "watch"]
#    EOF
#
# 3. Enlazar ese Role al ServiceAccount con un RoleBinding
#    (namespaced, no ClusterRoleBinding):
#
#    kubectl apply -f - <<EOF
#    apiVersion: rbac.authorization.k8s.io/v1
#    kind: RoleBinding
#    metadata:
#      name: log-shipper-binding
#      namespace: cks-rbac-lab
#    subjects:
#    - kind: ServiceAccount
#      name: log-shipper
#      namespace: cks-rbac-lab
#    roleRef:
#      kind: Role
#      name: log-shipper-role
#      apiGroup: rbac.authorization.k8s.io
#    EOF
#
# 4. Eliminar el ClusterRoleBinding y el ClusterRole originales
#    (ahi es donde vivia la exposicion real):
#
#    kubectl delete clusterrolebinding log-shipper-cluster-binding
#    kubectl delete clusterrole log-shipper-cluster-role
#
# 5. Re-chequear con kubectl auth can-i (o con ./este_script.sh verify)
#    que el ServiceAccount:
#      - SI puede get/list/watch pods y configmaps en cks-rbac-lab
#      - NO puede tocar secrets, nodes ni recursos de otros namespaces
#      - NO tiene verbos destructivos (create/update/patch/delete)
#
# No hace falta reiniciar el Deployment: RBAC se evalua en cada
# request contra el API server, no queda cacheado en el pod.
# ================================================================