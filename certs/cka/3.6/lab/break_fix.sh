#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="cka-rbac-lab"
SA_NAME="auditor"
ROLE_NAME="log-reader"
BINDING_NAME="auditor-binding"
POD_NAME="audit-agent"

echo "== CKA 3.6 - Manage RBAC - break & fix lab =="
echo "Este script crea un entorno RBAC funcional, lo rompe de forma controlada"
echo "en un namespace descartable, y te deja instrucciones para diagnosticar"
echo "y arreglar el problema."
echo

command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado. Abortando." >&2; exit 1; }

echo "[1/5] Limpiando namespace previo (si existe)..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo "[2/5] Creando namespace, ServiceAccount, Role y RoleBinding..."
kubectl create namespace "${NAMESPACE}" >/dev/null
kubectl create serviceaccount "${SA_NAME}" -n "${NAMESPACE}" >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
EOF

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BINDING_NAME}
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

echo "[3/5] Desplegando pod '${POD_NAME}' que usa la ServiceAccount '${SA_NAME}'..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: audit-agent
spec:
  serviceAccountName: ${SA_NAME}
  restartPolicy: Always
  containers:
  - name: audit-agent
    image: bitnami/kubectl:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        while true; do
          echo "--- $(date -u +%FT%TZ) ---";
          kubectl get pods -n ${NAMESPACE};
          sleep 5;
        done
EOF

echo "Esperando a que el pod esté Ready..."
kubectl wait --for=condition=Ready pod/"${POD_NAME}" -n "${NAMESPACE}" --timeout=120s >/dev/null

echo "[4/5] Rompiendo el entorno de forma controlada (fallo intencional en RBAC)..."
kubectl patch rolebinding "${BINDING_NAME}" -n "${NAMESPACE}" \
  --type='json' -p='[{"op":"replace","path":"/subjects/0/name","value":"auditor-svc"}]' >/dev/null

sleep 6

echo "[5/5] Listo. Entorno preparado en el namespace '${NAMESPACE}'."
echo
echo "=================== SÍNTOMA ==================="
echo "El pod '${POD_NAME}' sigue Running, pero dejó de poder listar pods."
echo "Revisá los logs:"
echo "  kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=10"
echo "Vas a ver un error del tipo:"
echo "  Error from server (Forbidden): pods is forbidden: User \"system:serviceaccount:${NAMESPACE}:${SA_NAME}\""
echo "  cannot list resource \"pods\" in API group \"\" in the namespace \"${NAMESPACE}\""
echo
echo "=================== OBJETIVO ==================="
echo "El Role '${ROLE_NAME}' y el RoleBinding '${BINDING_NAME}' siguen existiendo"
echo "en el namespace, y el pod sigue usando la ServiceAccount '${SA_NAME}'."
echo "Sin modificar el Pod ni recrear la ServiceAccount, arreglá el objeto RBAC"
echo "que está mal configurado para que '${SA_NAME}' vuelva a tener los permisos"
echo "get/list/watch sobre pods (y get sobre pods/log) en el namespace '${NAMESPACE}'."
echo "No uses ClusterRoleBinding ni cluster-admin: la solución debe respetar"
echo "el principio de mínimo privilegio, con alcance de namespace."
echo
echo "Pistas de diagnóstico:"
echo "  kubectl get role,rolebinding -n ${NAMESPACE}"
echo "  kubectl describe rolebinding ${BINDING_NAME} -n ${NAMESPACE}"
echo "  kubectl auth can-i list pods --as=system:serviceaccount:${NAMESPACE}:${SA_NAME} -n ${NAMESPACE}"
echo
echo "Verificación de éxito:"
echo "  kubectl auth can-i list pods --as=system:serviceaccount:${NAMESPACE}:${SA_NAME} -n ${NAMESPACE}"
echo "  debe responder 'yes', y 'kubectl logs -n ${NAMESPACE} ${POD_NAME} --tail=5'"
echo "  debe volver a mostrar la lista de pods en vez del error Forbidden."

# ============================================================
# SOLUCIÓN (no ejecutar hasta intentar resolverlo por tu cuenta)
#
# 1. Diagnosticar dónde está el desajuste:
#    kubectl get rolebinding auditor-binding -n cka-rbac-lab -o yaml
#    -> el subject "name" es "auditor-svc", pero la ServiceAccount real
#       (y la que usa el Pod) se llama "auditor". El Role y sus verbs
#       están bien; el problema es el binding entre subject y role.
#
# 2. Corregir el subject del RoleBinding:
#    kubectl patch rolebinding auditor-binding -n cka-rbac-lab \
#      --type='json' \
#      -p='[{"op":"replace","path":"/subjects/0/name","value":"auditor"}]'
#
#    (alternativa equivalente: kubectl edit rolebinding auditor-binding \
#     -n cka-rbac-lab y corregir a mano el campo subjects[0].name)
#
# 3. Verificar:
#    kubectl auth can-i list pods \
#      --as=system:serviceaccount:cka-rbac-lab:auditor -n cka-rbac-lab
#    # -> yes
#    kubectl logs -n cka-rbac-lab audit-agent --tail=5
#    # -> vuelve a mostrar la lista de pods, sin error Forbidden
#
# 4. Limpieza del laboratorio:
#    kubectl delete namespace cka-rbac-lab
# ============================================================