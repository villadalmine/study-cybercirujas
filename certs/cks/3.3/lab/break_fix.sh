#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# CKS v1.34 - Cluster Setup & Hardening
# Tema 3.3: Restrict access to Kubernetes API (peso examen: 3.75%)
#
# Fuentes de referencia (consultar para profundizar, no se copia texto
# literal de ninguna de ellas):
#   - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#   - https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#   - https://kubernetes.io/docs/reference/access-authn-authz/authentication/#anonymous-requests
#
# Escenario: alguien crea un ClusterRoleBinding pensando en habilitar
# a una herramienta externa de monitoreo para que pueda consultar el
# estado del cluster sin manejar credenciales. El problema es que en
# vez de atarlo a un ServiceAccount concreto, lo ata al grupo
# "system:unauthenticated" (el grupo al que Kubernetes asigna a
# CUALQUIER request sin autenticar, siempre que anonymous-auth siga
# habilitado en el kube-apiserver, que es el default). El resultado:
# cualquiera que pueda alcanzar por red al kube-apiserver puede leer
# recursos del cluster sin presentar ningún token.
#
# ADVERTENCIA: correr esto SOLO en una VM de laboratorio descartable
# con un cluster de un solo nodo (kubeadm, kind, minikube, k3s, etc.)
# que puedas destruir después. El script solo toca objetos de la API
# (ClusterRoleBinding + un Namespace de demo), no modifica manifests
# estáticos del control plane ni reinicia el kube-apiserver.
# ==========================================================================

LAB_NS="cks-lab-333"
CRB_NAME="external-healthcheck-reader"

usage() {
  cat <<'EOF'
Uso: ./cks-3.3-restrict-api-access.sh <comando>

Comandos:
  break    Introduce la falla de forma controlada
  status   Muestra el estado actual (para diagnosticar)
  fix      Aplica la solución automáticamente (usalo para validar
           tu propia solución manual, no como atajo)
  clean    Elimina todo rastro del laboratorio

Antes de "break" tenés que exportar:
  export I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM=yes
EOF
  exit 1
}

require_confirmation() {
  if [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM:-}" != "yes" ]]; then
    echo "ERROR: este script modifica RBAC a nivel de cluster." >&2
    echo "Corré esto solo en una VM de laboratorio descartable y confirmá con:" >&2
    echo "  export I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM=yes" >&2
    exit 1
  fi
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  echo ">> Contexto actual de kubectl: ${ctx}"
  read -r -p ">> Confirmás que este cluster es descartable? (escribí 'si' para continuar): " ans
  if [[ "${ans}" != "si" ]]; then
    echo "Cancelado." >&2
    exit 1
  fi
}

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { echo "Falta kubectl" >&2; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "No se puede alcanzar el cluster" >&2; exit 1; }
}

break_lab() {
  require_confirmation
  check_prereqs

  kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${LAB_NS}" create configmap app-config \
    --from-literal=db_host=internal-db.cks-lab-333.svc.cluster.local \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${LAB_NS}" run demo-pod --image=nginx:alpine --restart=Never \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB_NAME}
subjects:
- kind: Group
  name: system:unauthenticated
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF

  cat <<'EOF'

============================================================
 SINTOMA REPORTADO
============================================================
El equipo de seguridad corrió un scan externo contra la IP
del kube-apiserver y detectó que devuelve datos del cluster
a requests SIN ningún token ni certificado de cliente.

Para reproducir el sintoma vos mismo:

  APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  curl -sk "${APISERVER}/api/v1/namespaces/cks-lab-333/pods" | head -c 400
  echo
  curl -sk "${APISERVER}/api/v1/namespaces/cks-lab-333/configmaps" | head -c 400

Si el cluster está mal configurado, vas a ver JSON con los
objetos Pod y ConfigMap reales (incluido demo-pod y
app-config) en vez de un 401 Unauthorized / 403 Forbidden.

============================================================
 OBJETIVO
============================================================
1. Confirmá el sintoma con los comandos de arriba.
2. Encontrá QUÉ objeto de RBAC le está dando permisos al
   tráfico no autenticado (pensá en qué "user" y qué
   "groups" recibe una request anónima en Kubernetes).
3. Eliminá o corregí ese objeto para que las requests sin
   autenticar vuelvan a recibir 401/403.
4. Verificá que kubectl con tus credenciales normales sigue
   funcionando (no rompas tu propio acceso).
5. Volvé a correr los curl de arriba: ahora deben fallar.

Pista de comandos de diagnóstico (sin revelar la respuesta):
  kubectl get clusterrolebindings
  kubectl describe clusterrolebinding <nombre-sospechoso>
  kubectl auth can-i --list --as=system:anonymous
============================================================
EOF
}

status_lab() {
  check_prereqs
  echo ">> ClusterRoleBindings que atan a system:anonymous o system:unauthenticated:"
  if command -v jq >/dev/null 2>&1; then
    kubectl get clusterrolebindings -o json | \
      jq -r '.items[] | select(.subjects != null) | select(any(.subjects[]; .name=="system:anonymous" or .name=="system:unauthenticated")) | .metadata.name'
  else
    kubectl get clusterrolebindings -o custom-columns='NAME:.metadata.name,SUBJECTS:.subjects[*].name' | \
      grep -E 'system:anonymous|system:unauthenticated' || true
  fi
  echo
  echo ">> Prueba rápida de acceso anónimo:"
  APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  code=$(curl -sk -o /dev/null -w '%{http_code}' "${APISERVER}/api/v1/namespaces/${LAB_NS}/pods")
  echo "   HTTP status sin credenciales: ${code} (200 = vulnerable, 401/403 = correcto)"
}

fix_lab() {
  require_confirmation
  check_prereqs
  kubectl delete clusterrolebinding "${CRB_NAME}" --ignore-not-found
  echo ">> ClusterRoleBinding '${CRB_NAME}' eliminado."
  status_lab
}

clean_lab() {
  check_prereqs
  kubectl delete clusterrolebinding "${CRB_NAME}" --ignore-not-found
  kubectl delete namespace "${LAB_NS}" --ignore-not-found
  echo ">> Laboratorio limpio."
}

case "${1:-}" in
  break)  break_lab ;;
  status) status_lab ;;
  fix)    fix_lab ;;
  clean)  clean_lab ;;
  *)      usage ;;
esac

# ==========================================================================
# SOLUCION PASO A PASO (leer solo después de intentarlo por tu cuenta)
# ==========================================================================
#
# 1. Reproducir y confirmar el sintoma:
#
#    APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
#    curl -sk "${APISERVER}/api/v1/namespaces/cks-lab-333/pods"
#    # -> devuelve el PodList real sin ningún header de Authorization.
#    # Esto pasa porque el kube-apiserver tiene, por default,
#    # --anonymous-auth=true. Toda request sin credenciales válidas
#    # se autentica igual como user "system:anonymous" y queda en el
#    # group "system:unauthenticated". Eso por sí solo no es grave
#    # SI no hay ningún binding de RBAC apuntando a ese group/user.
#
# 2. Listar los ClusterRoleBindings y buscar el que ata ese group:
#
#    kubectl get clusterrolebindings -o json | \
#      jq -r '.items[] | select(.subjects != null) |
#        select(any(.subjects[]; .name=="system:unauthenticated")) |
#        .metadata.name'
#    # -> external-healthcheck-reader
#
#    kubectl describe clusterrolebinding external-healthcheck-reader
#    # Confirma: Subjects -> Group system:unauthenticated
#    #           RoleRef  -> ClusterRole/view
#
# 3. Eliminar el binding que rompe el modelo de "restrict access to
#    the Kubernetes API" (least privilege / no anonymous access to
#    cluster data):
#
#    kubectl delete clusterrolebinding external-healthcheck-reader
#
# 4. Si el requerimiento original era real (una herramienta externa
#    necesita leer el estado del cluster), la forma correcta es:
#
#    kubectl create serviceaccount healthcheck-reader -n cks-lab-333
#    kubectl create rolebinding healthcheck-reader-binding \
#      -n cks-lab-333 \
#      --clusterrole=view \
#      --serviceaccount=cks-lab-333:healthcheck-reader
#    # RoleBinding en vez de ClusterRoleBinding: acota el permiso al
#    # namespace cks-lab-333 en vez de todo el cluster, y el subject
#    # es un ServiceAccount identificable y auditable, no "cualquiera".
#    # La herramienta externa autentica con el token de ese SA
#    # (kubectl create token healthcheck-reader -n cks-lab-333),
#    # nunca de forma anónima.
#
# 5. Verificar que el acceso anónimo ahora está bloqueado y que tu
#    propio acceso sigue intacto:
#
#    curl -sk "${APISERVER}/api/v1/namespaces/cks-lab-333/pods"
#    # -> 401 Unauthorized (o 403 Forbidden según versión/authz mode)
#
#    kubectl auth can-i list pods -n cks-lab-333 --as=system:anonymous
#    # -> no
#
#    kubectl get pods -n cks-lab-333
#    # -> funciona normal con tus credenciales
#
# 6. (Hardening opcional, no obligatorio para este lab): en un cluster
#    real donde nada dependa de anonymous auth (algunos health checks
#    de balanceadores externos sí lo requieren, revisar antes), se
#    puede reforzar aún más deshabilitando el flag directamente en el
#    manifest estático del kube-apiserver
#    (/etc/kubernetes/manifests/kube-apiserver.yaml en kubeadm):
#
#      --anonymous-auth=false
#
#    Esto es defensa en profundidad: aunque quede un RBAC binding mal
#    hecho como el de este lab, ninguna request anónima llega siquiera
#    a ser evaluada por el authorizer.
# ==========================================================================