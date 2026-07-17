#!/usr/bin/env bash
#
# CKAD 1.35 - Tema 4.1: Discover and use resources that extend Kubernetes (CRD, Operators)
# Laboratorio break & fix
#
# Este script crea un escenario descartable en el cluster actual (un namespace
# dedicado + un CRD + un "operator" minimalista basado en un loop de
# reconciliación en bash) y despues rompe un permiso RBAC del ServiceAccount
# del operator, simulando un incidente real: alguien endurece RBAC y el
# operator deja de poder reconciliar sus Custom Resources.
#
# Pensado para correr SOLO contra un cluster de laboratorio descartable
# (kind, minikube, k3d). Todo lo que crea/rompe está namespaced dentro de
# "ckad-4-1-lab" o son objetos cluster-scoped con nombres únicos
# (CRD websites.training.ckad.dev, ClusterRole/ClusterRoleBinding
# website-operator-*). No toca nada más del cluster.
#
# Uso:
#   ./break-fix-4.1.sh setup      # crea el laboratorio y lo rompe (default)
#   ./break-fix-4.1.sh cleanup    # borra todo lo creado por el script
#
# Variables de entorno:
#   LAB_YES=yes   salta la confirmación interactiva (útil en CI)
#
set -euo pipefail

NAMESPACE="ckad-4-1-lab"
CRD_NAME="websites.training.ckad.dev"
CLUSTERROLE="website-operator-role"
CLUSTERROLEBINDING="website-operator-binding"
SA_NAME="website-operator"
DEPLOY_NAME="website-operator"
CONFIGMAP_NAME="website-operator-reconcile"

confirm() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '<sin contexto>')"
  echo "Contexto actual de kubectl: ${ctx}"
  echo "Este script va a crear/romper recursos en ese cluster (namespace ${NAMESPACE}"
  echo "+ un CRD y RBAC cluster-scoped). Usalo solo contra un cluster de laboratorio descartable."
  if [[ "${LAB_YES:-}" == "yes" ]]; then
    return 0
  fi
  read -r -p "¿Continuar? [y/N] " ans
  [[ "${ans}" =~ ^[yY]$ ]] || { echo "Cancelado."; exit 1; }
}

check_prereqs() {
  command -v kubectl >/dev/null || { echo "Falta kubectl"; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "No hay cluster accesible"; exit 1; }
}

create_lab() {
  echo "==> Creando namespace ${NAMESPACE}"
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  echo "==> Instalando el CRD ${CRD_NAME}"
  kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: websites.training.ckad.dev
spec:
  group: training.ckad.dev
  scope: Namespaced
  names:
    kind: Website
    listKind: WebsiteList
    plural: websites
    singular: website
    shortNames: ["ws"]
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["image"]
              properties:
                image:
                  type: string
                replicas:
                  type: integer
                  minimum: 1
                  default: 1
            status:
              type: object
              properties:
                phase:
                  type: string
                observedImage:
                  type: string
      additionalPrinterColumns:
        - name: Image
          type: string
          jsonPath: .spec.image
        - name: Phase
          type: string
          jsonPath: .status.phase
EOF

  kubectl wait --for=condition=Established "crd/${CRD_NAME}" --timeout=30s

  echo "==> Creando ServiceAccount y RBAC correctos para el operator"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
EOF

  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTERROLE}
rules:
  - apiGroups: ["training.ckad.dev"]
    resources: ["websites"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["training.ckad.dev"]
    resources: ["websites/status"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create"]
EOF

  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CLUSTERROLEBINDING}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: ${CLUSTERROLE}
  apiGroup: rbac.authorization.k8s.io
EOF

  echo "==> Desplegando el 'operator' (loop de reconciliación en bash)"
  kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: website-operator-reconcile
data:
  reconcile.sh: |
    #!/bin/bash
    set -uo pipefail
    NS="ckad-4-1-lab"
    while true; do
      for ws in $(kubectl get websites -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/tmp/reconcile.err); do
        image=$(kubectl get website "${ws}" -n "${NS}" -o jsonpath='{.spec.image}')
        pod="ws-${ws}"
        if ! kubectl get pod "${pod}" -n "${NS}" >/dev/null 2>&1; then
          kubectl run "${pod}" -n "${NS}" --image="${image}" \
            --labels="managed-by=website-operator,website=${ws}"
        fi
        kubectl patch website "${ws}" -n "${NS}" --type=merge --subresource=status \
          -p "{\"status\":{\"phase\":\"Ready\",\"observedImage\":\"${image}\"}}" \
          >/dev/null 2>>/tmp/reconcile.err || true
      done
      if [[ -s /tmp/reconcile.err ]]; then
        echo "[reconcile] $(date -Is) error:"; cat /tmp/reconcile.err
      fi
      sleep 5
    done
EOF

  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: website-operator
  template:
    metadata:
      labels:
        app: website-operator
    spec:
      serviceAccountName: ${SA_NAME}
      containers:
        - name: operator
          image: bitnami/kubectl:1.30
          command: ["/bin/bash", "/scripts/reconcile.sh"]
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: ${CONFIGMAP_NAME}
            defaultMode: 0755
EOF

  echo "==> Esperando a que el operator esté listo"
  kubectl rollout status -n "${NAMESPACE}" "deployment/${DEPLOY_NAME}" --timeout=120s

  echo "==> Creando el primer Website (debería reconciliarse solo)"
  kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: training.ckad.dev/v1
kind: Website
metadata:
  name: demo-site
spec:
  image: nginx:1.27
EOF

  echo "==> Esperando el Pod ws-demo-site (prueba de que el operator funciona)"
  for i in $(seq 1 24); do
    if kubectl get pod ws-demo-site -n "${NAMESPACE}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  kubectl get website demo-site -n "${NAMESPACE}"
}

break_lab() {
  echo "==> Rompiendo el laboratorio: recortando el RBAC del operator"
  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTERROLE}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create"]
EOF

  echo "==> Creando un segundo Website que va a quedar sin reconciliar"
  kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: training.ckad.dev/v1
kind: Website
metadata:
  name: broken-site
spec:
  image: nginx:1.27
EOF

  cat <<'MSG'

============================================================
 LABORATORIO ROTO - CKAD 4.1 (CRD / Operators)
============================================================
SÍNTOMA:
  El Website "broken-site" (namespace ckad-4-1-lab) nunca llega a tener
  un Pod asociado ni status.phase=Ready, aunque el mismo operator SÍ
  reconcilió correctamente a "demo-site" hace un momento.

    kubectl get website -n ckad-4-1-lab
    kubectl get pods -n ckad-4-1-lab

  vas a ver que "broken-site" se queda sin PHASE y sin su pod "ws-broken-site".

OBJETIVO:
  Encontrá por qué el operator dejó de poder reconciliar Website y
  restaurá el comportamiento, sin recrear el CRD ni el Deployment del
  operator, hasta que:
    - kubectl get pod ws-broken-site -n ckad-4-1-lab exista y esté Running
    - kubectl get website broken-site -n ckad-4-1-lab muestre PHASE=Ready

PISTAS DE DÓNDE MIRAR (no la solución):
  - Logs del operator: kubectl logs -n ckad-4-1-lab deploy/website-operator
  - Los permisos efectivos de su ServiceAccount:
    kubectl auth can-i --list --as=system:serviceaccount:ckad-4-1-lab:website-operator
============================================================

MSG
}

cleanup_lab() {
  echo "==> Borrando el laboratorio"
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
  kubectl delete clusterrolebinding "${CLUSTERROLEBINDING}" --ignore-not-found
  kubectl delete clusterrole "${CLUSTERROLE}" --ignore-not-found
  kubectl delete crd "${CRD_NAME}" --ignore-not-found
}

main() {
  local action="${1:-setup}"
  check_prereqs
  case "${action}" in
    setup)
      confirm
      create_lab
      break_lab
      ;;
    cleanup)
      confirm
      cleanup_lab
      ;;
    *)
      echo "Uso: $0 [setup|cleanup]"
      exit 1
      ;;
  esac
}

main "$@"

# ============================================================
# SOLUCIÓN PASO A PASO (comentada - referencia del instructor,
# no hace falta ejecutar nada de esto para que el script corra)
# ============================================================
#
# 1. Confirmar el síntoma:
#      kubectl get website -n ckad-4-1-lab
#      kubectl get pods -n ckad-4-1-lab
#    "broken-site" no tiene PHASE ni pod ws-broken-site; "demo-site" sí.
#
# 2. Mirar los logs del operator para ver el error real:
#      kubectl logs -n ckad-4-1-lab deploy/website-operator
#    Se va a ver algo como:
#      Error from server (Forbidden): websites.training.ckad.dev is
#      forbidden: User "system:serviceaccount:ckad-4-1-lab:website-operator"
#      cannot list resource "websites" in API group "training.ckad.dev"
#      at the cluster scope
#
# 3. Confirmar que es un problema de RBAC, no del CRD ni del Deployment:
#      kubectl auth can-i list websites.training.ckad.dev \
#        --as=system:serviceaccount:ckad-4-1-lab:website-operator
#    Responde "no" - antes del break respondía "yes".
#
# 4. Restaurar los permisos que break_lab le sacó al ClusterRole
#    (get/list/watch sobre websites y get/patch/update sobre
#    websites/status):
#
#      kubectl apply -f - <<'EOF'
#      apiVersion: rbac.authorization.k8s.io/v1
#      kind: ClusterRole
#      metadata:
#        name: website-operator-role
#      rules:
#        - apiGroups: ["training.ckad.dev"]
#          resources: ["websites"]
#          verbs: ["get", "list", "watch"]
#        - apiGroups: ["training.ckad.dev"]
#          resources: ["websites/status"]
#          verbs: ["get", "patch", "update"]
#        - apiGroups: [""]
#          resources: ["pods"]
#          verbs: ["get", "list", "watch", "create"]
#      EOF
#
# 5. El operator reconcilia cada 5s, así que en poco tiempo:
#      kubectl get pod ws-broken-site -n ckad-4-1-lab
#      kubectl get website broken-site -n ckad-4-1-lab
#    deberían mostrar el pod Running y PHASE=Ready.
#
# 6. Terminado el ejercicio, limpiar todo:
#      ./break-fix-4.1.sh cleanup
# ============================================================