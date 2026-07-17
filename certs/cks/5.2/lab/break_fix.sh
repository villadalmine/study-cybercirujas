#!/usr/bin/env bash
#
# Break & Fix - CKS v1.34
# Dominio 5.2: Using least-privilege identity and access management (peso examen: 2.5)
#
# Referencia: CKS Curriculum v1.34
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# ADVERTENCIA: este script crea un namespace, ServiceAccounts, Roles,
# RoleBindings, un Pod y un ClusterRoleBinding con cluster-admin. Ejecutalo
# SOLO en una VM de laboratorio descartable, nunca contra un cluster real.
#
set -euo pipefail

NAMESPACE="cks-5-2-lab"
SA_NAME="metrics-reader"
ROLE_NAME="pod-reader"
RB_NAME="pod-reader-binding"
POD_NAME="metrics-watcher"
DECOY_SA="legacy-debug-sa"
DECOY_CRB="legacy-debug-full-access"

log() { printf '\n\033[1;34m[break-fix]\033[0m %s\n' "$*"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado. Abortando."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "No hay conexión a un cluster. Abortando."; exit 1; }

echo "Contexto actual de kubectl: $(kubectl config current-context)"
read -r -p "Esto va a crear/borrar objetos (incluyendo un ClusterRoleBinding con cluster-admin) en este cluster. ¿Continuar? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Cancelado."; exit 0; }

# ============================================================
# SETUP: estado inicial funcionando
# ============================================================
log "Preparando namespace '$NAMESPACE'..."
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl delete namespace "$NAMESPACE" --wait=true --timeout=120s
fi
kubectl create namespace "$NAMESPACE"

log "Creando ServiceAccount de la aplicación..."
kubectl -n "$NAMESPACE" create serviceaccount "$SA_NAME"

log "Creando Role y RoleBinding con permisos mínimos (get, list, watch sobre pods)..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${RB_NAME}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF

log "Desplegando el Pod que consume la API con el token de su ServiceAccount..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  labels:
    app: metrics-reader
spec:
  serviceAccountName: ${SA_NAME}
  restartPolicy: Never
  containers:
    - name: watcher
      image: curlimages/curl:8.10.1
      command: ["sh", "-c"]
      args:
        - |
          while true; do
            echo "--- \$(date -Iseconds) ---"
            curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
              --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
              -H "Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
              "https://kubernetes.default.svc/api/v1/namespaces/\$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)/pods"
            sleep 5
          done
EOF

# Este ClusterRoleBinding NO es "el break": representa un hallazgo típico de
# auditoría (una identidad legacy con permisos excesivos, sin relación con
# el Pod de la app) que queda dando vueltas en el cluster desde antes.
log "Sembrando un hallazgo de auditoría preexistente (identidad legacy sobre-privilegiada)..."
kubectl -n "$NAMESPACE" create serviceaccount "$DECOY_SA"
kubectl create clusterrolebinding "$DECOY_CRB" \
  --clusterrole=cluster-admin \
  --serviceaccount="${NAMESPACE}:${DECOY_SA}"

log "Esperando a que el Pod esté Ready..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=60s

log "Estado ANTES de romper nada (debería devolver HTTP_STATUS:200):"
sleep 6
kubectl -n "$NAMESPACE" logs "$POD_NAME" --tail=4

# ============================================================
# BREAK: se reduce el Role a solo "get", quitando "list" y "watch"
# ============================================================
log "=== APLICANDO EL BREAK ==="
kubectl -n "$NAMESPACE" patch role "$ROLE_NAME" \
  --type='json' \
  -p='[{"op":"replace","path":"/rules/0/verbs","value":["get"]}]'

sleep 6
log "Estado DESPUÉS del break (mirá el HTTP_STATUS):"
kubectl -n "$NAMESPACE" logs "$POD_NAME" --tail=4

# ============================================================
# Explicación para el estudiante
# ============================================================
cat <<'MSG'

============================================================
SÍNTOMA
============================================================
El Pod "metrics-watcher" (namespace cks-5-2-lab) hace polling cada 5s
contra la API de Kubernetes usando el token de su propio ServiceAccount
"metrics-reader". Desde el break, sus logs muestran HTTP_STATUS:403 con
un mensaje del tipo:

  "pods is forbidden: User \"system:serviceaccount:cks-5-2-lab:metrics-reader\"
   cannot list resource \"pods\" in API group \"\" in the namespace \"cks-5-2-lab\""

El ServiceAccount sigue existiendo, el RoleBinding sigue existiendo, y el
Role todavía tiene una regla sobre "pods" — pero algo cambió en esa regla.

============================================================
OBJETIVO
============================================================
1. Diagnosticar por qué el ServiceAccount "metrics-reader" ya no puede
   completar la llamada que hace el Pod, usando herramientas como
   "kubectl auth can-i ... --as=system:serviceaccount:<ns>:<sa>".
2. Restaurar el acceso aplicando el PRINCIPIO DE MENOR PRIVILEGIO: el Pod
   solo necesita listar pods de su propio namespace. No es aceptable
   "arreglarlo" dándole cluster-admin, un ClusterRoleBinding, ni un verbo
   comodín ("*"). La solución correcta agrega exactamente el/los verbo(s)
   que falta(n) al Role existente.
3. Como ejercicio adicional de auditoría (domino 5.2 no se trata solo de
   restaurar acceso, sino también de detectar exceso de privilegios):
   revisá el ServiceAccount "legacy-debug-sa" y el ClusterRoleBinding
   "legacy-debug-full-access" que ya estaban en el namespace. ¿Debería
   existir esa identidad con cluster-admin? Decidí si corresponde
   eliminarla como parte del hardening, aunque no afecta al síntoma
   observado en los logs.

Comandos de diagnóstico útiles:
  kubectl -n cks-5-2-lab logs metrics-watcher --tail=10 -f
  kubectl -n cks-5-2-lab get role pod-reader -o yaml
  kubectl auth can-i list pods -n cks-5-2-lab \
    --as=system:serviceaccount:cks-5-2-lab:metrics-reader
  kubectl -n cks-5-2-lab describe rolebinding pod-reader-binding
  kubectl get clusterrolebindings -o wide | grep cks-5-2-lab

============================================================
MSG

exit 0

# ============================================================
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# ============================================================
#
# 1) Confirmar el diagnóstico: la llamada del Pod es un GET a la colección
#    /api/v1/namespaces/cks-5-2-lab/pods (sin nombre de recurso), lo que en
#    RBAC requiere el verbo "list", no "get". El break reemplazó los verbos
#    del Role por ["get"] únicamente, por eso "get" individual funcionaría
#    pero el listado no:
#
#      kubectl -n cks-5-2-lab get role pod-reader -o jsonpath='{.rules[0].verbs}'
#      # -> ["get"]
#
#      kubectl auth can-i list pods -n cks-5-2-lab \
#        --as=system:serviceaccount:cks-5-2-lab:metrics-reader
#      # -> no
#
# 2) Restaurar el mínimo necesario agregando "list" (y "watch" si se quiere
#    que además funcione un watch, ya que el curl del Pod solo necesita
#    "list"). Nunca usar "*" como verbo ni cambiar de Role a ClusterRole:
#
#      kubectl -n cks-5-2-lab patch role pod-reader \
#        --type='json' \
#        -p='[{"op":"replace","path":"/rules/0/verbs","value":["get","list","watch"]}]'
#
#    (equivalente con kubectl edit role pod-reader -n cks-5-2-lab)
#
# 3) Verificar que el ServiceAccount ya puede listar:
#
#      kubectl auth can-i list pods -n cks-5-2-lab \
#        --as=system:serviceaccount:cks-5-2-lab:metrics-reader
#      # -> yes
#
#      kubectl -n cks-5-2-lab logs metrics-watcher --tail=4
#      # -> HTTP_STATUS:200
#
# 4) Auditar y resolver el hallazgo de menor privilegio adicional: el
#    ServiceAccount "legacy-debug-sa" tiene cluster-admin vía el
#    ClusterRoleBinding "legacy-debug-full-access" sin ninguna relación con
#    la aplicación. Si no hay una razón documentada para ese acceso,
#    eliminarlo:
#
#      kubectl delete clusterrolebinding legacy-debug-full-access
#      kubectl -n cks-5-2-lab delete serviceaccount legacy-debug-sa
#
# 5) Limpieza del laboratorio una vez terminado el ejercicio:
#
#      kubectl delete namespace cks-5-2-lab
#      kubectl delete clusterrolebinding legacy-debug-full-access --ignore-not-found
#
# Idea clave del dominio 5.2: "least privilege" es en dos direcciones —
# otorgar exactamente lo que una identidad necesita para funcionar (ni más
# amplio que el verbo/recurso real que usa), y detectar/retirar accesos que
# quedaron de más (ClusterRoleBindings, roles con "*", SAs sin uso).