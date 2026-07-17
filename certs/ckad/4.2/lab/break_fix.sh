#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# CKAD 1.35 - Tema 4.2: Understand authentication, authorization
# and admission control (peso examen: 3)
# Fuente de referencia (curriculum oficial, solo como contexto, no copiado):
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Este script arma un escenario "break & fix" seguro y descartable:
# crea un namespace nuevo, un ServiceAccount, un Role con permisos
# INCORRECTOS y un Pod que usa ese ServiceAccount para llamar a la
# API de Kubernetes. El estudiante va a ver el fallo de autorizacion
# en los logs del Pod y tiene que arreglar el RBAC para que el Pod
# pueda listar sus propios Pods en el namespace.
#
# Pensado para correr DENTRO de una VM de laboratorio descartable
# (kind/k3s/minikube), nunca contra un cluster real o compartido.
# ============================================================================

SUFFIX="$(tr -dc 'a-z0-9' </dev/urandom | head -c5)"
NAMESPACE="ckad-422-lab-${SUFFIX}"
SA_NAME="app-sa"
ROLE_NAME="app-role"
ROLEBINDING_NAME="app-rolebinding"
POD_NAME="app-checker"

info()  { echo -e "\n[INFO]  $*"; }
warn()  { echo -e "\n[WARN]  $*"; }
fail()  { echo -e "\n[ERROR] $*"; exit 1; }

# ----------------------------------------------------------------------------
# Guardas de seguridad
# ----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || fail "kubectl no esta instalado."

CURRENT_CTX="$(kubectl config current-context 2>/dev/null || true)"
[ -n "$CURRENT_CTX" ] || fail "No hay un contexto de kubectl configurado."

case "$CURRENT_CTX" in
  *prod*|*production*)
    fail "El contexto actual ('${CURRENT_CTX}') parece de produccion. Abortando."
    ;;
esac

warn "Este script va a crear recursos en el cluster del contexto: '${CURRENT_CTX}'"
warn "Namespace de laboratorio a crear: ${NAMESPACE}"
if [ "${CKAD_LAB_CONFIRM:-}" != "yes" ]; then
  read -r -p "Confirmas que este es un cluster de laboratorio descartable? (escribi 'si' para continuar): " ANSWER
  [ "$ANSWER" = "si" ] || fail "Cancelado por el usuario."
fi

# ----------------------------------------------------------------------------
# Paso 1: preparar el escenario (namespace, ServiceAccount, RBAC roto, Pod)
# ----------------------------------------------------------------------------
info "Creando namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}"

info "Creando ServiceAccount ${SA_NAME}..."
kubectl create serviceaccount "${SA_NAME}" -n "${NAMESPACE}"

info "Creando Role con permisos INCORRECTOS (a proposito)..."
# El Role solo otorga 'get' y 'list' sobre 'services', pero el Pod
# va a necesitar 'list' sobre 'pods'. Esto es el "break" del ejercicio.
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
rules:
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list"]
EOF

info "Creando RoleBinding entre el Role y el ServiceAccount..."
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ROLEBINDING_NAME}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF

info "Desplegando Pod ${POD_NAME} que usa el ServiceAccount y consulta la API cada 5s..."
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
spec:
  serviceAccountName: ${SA_NAME}
  automountServiceAccountToken: true
  restartPolicy: Never
  containers:
    - name: checker
      image: curlimages/curl:8.10.1
      command: ["sh", "-c"]
      args:
        - |
          NS="${NAMESPACE}"
          TOKEN_FILE=/var/run/secrets/kubernetes.io/serviceaccount/token
          CA_FILE=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          while true; do
            TOKEN=$(cat "$TOKEN_FILE")
            echo "--- $(date -u +%H:%M:%S) intentando listar pods en namespace $NS ---"
            curl -s --cacert "$CA_FILE" \
              -H "Authorization: Bearer $TOKEN" \
              "https://kubernetes.default.svc/api/v1/namespaces/$NS/pods"
            echo
            sleep 5
          done
EOF

info "Esperando a que el Pod este Running..."
kubectl wait -n "${NAMESPACE}" --for=condition=Ready pod/"${POD_NAME}" --timeout=60s 2>/dev/null || true

# ----------------------------------------------------------------------------
# Que va a ver el estudiante / que tiene que lograr
# ----------------------------------------------------------------------------
cat <<MSG

============================================================================
ESCENARIO ROTO LISTO
============================================================================
Namespace de laboratorio: ${NAMESPACE}

SINTOMA:
  Revisa los logs del Pod:

    kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=20 -f

  Vas a ver que cada 5 segundos la respuesta de la API de Kubernetes
  es un JSON de tipo "Status" con "status": "Failure",
  "reason": "Forbidden" y un mensaje similar a:

    pods is forbidden: User "system:serviceaccount:${NAMESPACE}:${SA_NAME}"
    cannot list resource "pods" in API group "" in the namespace "${NAMESPACE}"

  Es decir: la AUTENTICACION funciona (el token del ServiceAccount es
  valido y la API sabe quien esta llamando), pero la AUTORIZACION
  (RBAC) rechaza el pedido porque el Role actual no le da permiso
  sobre el recurso "pods".

TU OBJETIVO:
  Modificar el RBAC (el Role, o crear/editar el binding) para que el
  ServiceAccount "${SA_NAME}" pueda hacer "list" (y "get") sobre el
  recurso "pods" en el namespace "${NAMESPACE}", sin darle permisos
  de mas (no uses cluster-admin ni un ClusterRole innecesario).

COMO VERIFICAR QUE LO LOGRASTE:
  Volve a mirar los logs del Pod. Cuando el fix este aplicado, en
  lugar del error "Forbidden" vas a ver un JSON de tipo "PodList"
  con al menos el propio Pod "${POD_NAME}" en el listado.

LIMPIEZA DEL LABORATORIO:
  kubectl delete namespace ${NAMESPACE}
============================================================================
MSG

# ============================================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
# ============================================================================
#
# 1) Confirmar el diagnostico viendo los logs:
#      kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=5
#    -> se ve "reason": "Forbidden" para el recurso "pods".
#
# 2) Inspeccionar el Role actual:
#      kubectl get role ${ROLE_NAME} -n ${NAMESPACE} -o yaml
#    -> las rules solo cubren resources: ["services"].
#
# 3) Corregir el Role para incluir el recurso "pods" con los verbos
#    necesarios (get/list/watch es el set minimo razonable):
#      kubectl patch role ${ROLE_NAME} -n ${NAMESPACE} --type='json' \
#        -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["pods"],"verbs":["get","list","watch"]}}]'
#
#    (Alternativa equivalente, reescribiendo el manifiesto completo):
#      kubectl apply -n ${NAMESPACE} -f - <<EOF
#      apiVersion: rbac.authorization.k8s.io/v1
#      kind: Role
#      metadata:
#        name: ${ROLE_NAME}
#      rules:
#        - apiGroups: [""]
#          resources: ["services"]
#          verbs: ["get", "list"]
#        - apiGroups: [""]
#          resources: ["pods"]
#          verbs: ["get", "list", "watch"]
#      EOF
#
# 4) El RoleBinding ya existente (${ROLEBINDING_NAME}) no necesita
#    cambios: sigue apuntando al mismo Role, que ahora tiene los
#    permisos correctos. RBAC en Kubernetes es dinamico, no hace
#    falta reiniciar el Pod ni el kube-apiserver.
#
# 5) Verificar el fix mirando los logs de nuevo:
#      kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=5 -f
#    -> ahora la respuesta es un "PodList" con el Pod "${POD_NAME}"
#       en items[], en vez del error Forbidden.
#
# Nota conceptual: cada request a la API pasa por tres etapas en
# orden: authentication (quien sos - en este caso el token del
# ServiceAccount), authorization (que podes hacer - RBAC, el punto
# que rompimos aca) y admission control (se valida/muta el objeto
# antes de persistirlo, aplica sobre todo a writes como create/update,
# por ejemplo PodSecurity admission o webhooks). Esta relacion en
# cadena es clave para el tema 4.2 del curriculum de CKAD.
# ============================================================================