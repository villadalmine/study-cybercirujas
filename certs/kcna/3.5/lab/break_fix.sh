#!/usr/bin/env bash
#
# KCNA - Dominio 3.5 Security (peso 4)
# Lab break&fix: RBAC (Role) mal configurado - falta el verbo "list"
# Requiere: kubectl apuntando a un cluster descartable (kind/minikube/k3d)
#
# Fuente de referencia (curriculum, usado solo como guía temática):
#   https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf

set -euo pipefail

NAMESPACE="kcna-security-lab"
SA_NAME="log-reader"
ROLE_NAME="log-reader-role"
ROLEBINDING_NAME="log-reader-binding"
POD_NAME="rbac-probe"
IMAGE="curlimages/curl:8.10.1"

log()  { printf '\n[lab] %s\n' "$*"; }
die()  { printf '\n[lab][ERROR] %s\n' "$*" >&2; exit 1; }

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl no está instalado o no está en el PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No se pudo contactar al cluster. Verificá tu kubeconfig."
}

require_disposable_cluster() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"

  if [[ "${FORCE:-0}" == "1" ]]; then
    return 0
  fi

  case "$ctx" in
    kind-*|minikube|k3d-*|k3s-default|docker-desktop) return 0 ;;
    *)
      die "El contexto actual ('$ctx') no parece un cluster descartable de laboratorio (kind/minikube/k3d/docker-desktop). Abortando por seguridad. Si estás seguro de lo que hacés, exportá FORCE=1 y reintentá."
      ;;
  esac
}

setup() {
  log "Creando namespace, ServiceAccount, Role, RoleBinding y Pod de prueba en '${NAMESPACE}'..."

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create serviceaccount "${SA_NAME}" -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ROLEBINDING_NAME}
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: ${SA_NAME}
  restartPolicy: Never
  containers:
  - name: probe
    image: ${IMAGE}
    command: ["sh", "-c"]
    args:
    - |
      TOKEN=/var/run/secrets/kubernetes.io/serviceaccount/token
      CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      NS=/var/run/secrets/kubernetes.io/serviceaccount/namespace
      API="https://\${KUBERNETES_SERVICE_HOST}:\${KUBERNETES_SERVICE_PORT}"
      while true; do
        CODE=\$(curl -s -o /tmp/body -w '%{http_code}' --cacert "\$CA" -H "Authorization: Bearer \$(cat \$TOKEN)" "\${API}/api/v1/namespaces/\$(cat \$NS)/pods")
        echo "=== \$(date -u +%H:%M:%S) HTTP \$CODE ==="
        cat /tmp/body
        echo
        sleep 5
      done
EOF

  log "Esperando a que el pod '${POD_NAME}' esté Running..."
  kubectl wait -n "${NAMESPACE}" --for=condition=Ready pod/"${POD_NAME}" --timeout=90s
}

break_lab() {
  log "Rompiendo el laboratorio: quitando el verbo 'list' del Role '${ROLE_NAME}'..."
  kubectl patch role "${ROLE_NAME}" -n "${NAMESPACE}" \
    --type=json -p='[{"op":"replace","path":"/rules/0/verbs","value":["get"]}]'

  cat <<'MSG'

============================================================
 SÍNTOMA
============================================================
El pod 'rbac-probe' sigue Running y su ServiceAccount se sigue
autenticando correctamente contra el API server (el token es
válido, eso es AUTHENTICATION). Pero cada pocos segundos vas a ver
en sus logs algo como:

  === 12:34:56 HTTP 403 ===
  {
    "kind": "Status",
    "apiVersion": "v1",
    "status": "Failure",
    "message": "pods is forbidden: User \"system:serviceaccount:kcna-security-lab:log-reader\" cannot list resource \"pods\" in API group \"\" in the namespace \"kcna-security-lab\"",
    "reason": "Forbidden",
    "code": 403
  }

Mirá los logs con:
  kubectl logs -n kcna-security-lab -f rbac-probe

============================================================
 OBJETIVO
============================================================
El request llega autenticado pero falla en la etapa de
AUTHORIZATION (RBAC), no en autenticación ni en admission control.
Tenés que reparar el Role 'log-reader-role' en el namespace
'kcna-security-lab' para que el ServiceAccount 'log-reader' pueda
volver a listar pods (verbo 'list' sobre el recurso 'pods', que es
distinto del verbo 'get' aunque ambos usen el método HTTP GET).

No hace falta tocar el Pod, el ServiceAccount ni el RoleBinding:
el problema está solo en las reglas del Role.

Para confirmar que lo arreglaste, corré:
  ./break-fix-3.5-security.sh verify
============================================================
MSG
}

verify() {
  log "Verificando acceso actual del ServiceAccount vía el pod de prueba..."
  local code
  code=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- sh -c '
    NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
    curl -s -o /dev/null -w "%{http_code}" \
      --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
      "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/api/v1/namespaces/${NS}/pods"
  ')

  if [[ "${code}" == "200" ]]; then
    log "OK: el ServiceAccount puede listar pods de nuevo (HTTP 200). ¡Resuelto!"
  else
    log "Todavía falla (HTTP ${code}). El Role sigue sin el verbo 'list'."
  fi
}

cleanup() {
  log "Eliminando namespace '${NAMESPACE}' y todos sus recursos..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
}

usage() {
  cat <<EOF
Uso: $0 [setup|break|verify|cleanup]

  (sin argumentos)  equivale a: setup + break
  setup             crea el namespace, SA, Role, RoleBinding y el pod de prueba
  break             rompe el Role quitando el verbo 'list' y muestra el enunciado
  verify            chequea si el estudiante ya arregló el RBAC
  cleanup           borra todo el namespace del laboratorio
EOF
}

main() {
  require_kubectl
  require_disposable_cluster

  case "${1:-}" in
    "")        setup; break_lab ;;
    setup)     setup ;;
    break)     break_lab ;;
    verify)    verify ;;
    cleanup)   cleanup ;;
    -h|--help) usage ;;
    *)         usage; exit 1 ;;
  esac
}

main "$@"

# ============================================================
# SOLUCIÓN PASO A PASO (para el instructor / autocorrección)
# ============================================================
#
# 1. Diagnosticar dónde falla el request:
#      kubectl logs -n kcna-security-lab rbac-probe --tail=20
#    Se ve HTTP 403 con reason "Forbidden": el token es válido
#    (si no lo fuera, sería 401/Unauthorized), así que el problema
#    es de AUTHORIZATION, no de autenticación ni de admission control.
#
# 2. Inspeccionar el Role y confirmar que falta el verbo 'list':
#      kubectl get role log-reader-role -n kcna-security-lab -o yaml
#    Se ve: verbs: ["get"]  (debería incluir también "list").
#
# 3. Confirmar que el RoleBinding y el ServiceAccount están intactos
#    (el break no los toca, no hace falta arreglarlos):
#      kubectl get rolebinding log-reader-binding -n kcna-security-lab -o yaml
#      kubectl get sa log-reader -n kcna-security-lab
#
# 4. Reparar el Role agregando el verbo 'list':
#      kubectl patch role log-reader-role -n kcna-security-lab \
#        --type=json -p='[{"op":"replace","path":"/rules/0/verbs","value":["get","list"]}]'
#
#    (equivalente con kubectl edit:
#      kubectl edit role log-reader-role -n kcna-security-lab
#      # y cambiar verbs: ["get"] por verbs: ["get", "list"])
#
# 5. Verificar la corrección:
#      kubectl logs -n kcna-security-lab -f rbac-probe
#    o directamente:
#      ./break-fix-3.5-security.sh verify
#    Ambos deberían mostrar HTTP 200 y el JSON con la lista de pods.
#
# 6. Limpiar el laboratorio cuando termines:
#      ./break-fix-3.5-security.sh cleanup
# ============================================================