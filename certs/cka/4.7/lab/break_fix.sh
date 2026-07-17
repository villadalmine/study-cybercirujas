#!/usr/bin/env bash
#
# break-fix-cka-4.7.sh
# CKA v1.35 - Tema 4.7: Understand CRDs, install and configure operators (peso 3.58%)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Este script:
#   1) Instala en el cluster un CRD propio (Widget) + un mini-operator (loop de reconciliación
#      corriendo como Deployment, sin dependencias externas más que kubectl) que reacciona a los
#      Custom Resources creados.
#   2) Verifica que todo funciona (reconciliación end-to-end).
#   3) Rompe algo de forma controlada: borra el ClusterRoleBinding del operator.
#   4) Te deja un Custom Resource nuevo, sin reconciliar, para que diagnostiques y arregles.
#
# Pensado para correr en una VM de laboratorio descartable con un cluster ya funcionando
# (kubeadm, kind, minikube, etc.) y kubectl apuntando a ese cluster.
#
# Uso:
#   ./break-fix-cka-4.7.sh            # pide confirmación antes de tocar el cluster
#   ./break-fix-cka-4.7.sh -y         # sin confirmación (asumí que sabés que es un lab descartable)
#   ./break-fix-cka-4.7.sh --cleanup  # borra todo lo creado por este script

set -euo pipefail

NAMESPACE="crd-lab"
WORKDIR="$(mktemp -d /tmp/widget-lab.XXXXXX)"
CRD_NAME="widgets.training.cka.io"
CLUSTERROLE_NAME="widget-operator-role"
BINDING_NAME="widget-operator-binding"
SA_NAME="widget-operator"
OPERATOR_IMAGE="bitnami/kubectl:latest"
AUTO_YES="false"
DO_CLEANUP="false"

log()  { echo "[lab] $*"; }
warn() { echo "[lab][WARN] $*" >&2; }
die()  { echo "[lab][ERROR] $*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES="true" ;;
    --cleanup) DO_CLEANUP="true" ;;
    -h|--help)
      echo "Uso: $0 [-y|--yes] [--cleanup]"
      exit 0
      ;;
    *) die "Argumento desconocido: $arg" ;;
  esac
done

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl no está en el PATH."
  kubectl cluster-info >/dev/null 2>&1 || die "No se pudo contactar al cluster. Revisá tu kubeconfig/contexto."
}

confirm_lab_vm() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  log "Contexto actual de kubectl: ${ctx}"
  if [[ "${AUTO_YES}" == "true" ]]; then
    return 0
  fi
  read -r -p "Este script crea un CRD, RBAC cluster-scoped y un Deployment, y luego rompe algo a propósito. Solo corré esto en una VM de laboratorio descartable. ¿Continuar? [escribí SI]: " ans
  [[ "${ans}" == "SI" ]] || die "Cancelado por el usuario."
}

cleanup() {
  log "Limpiando recursos del lab (namespace, CRD, ClusterRole, ClusterRoleBinding)..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null
  kubectl delete crd "${CRD_NAME}" --ignore-not-found >/dev/null
  kubectl delete clusterrole "${CLUSTERROLE_NAME}" --ignore-not-found >/dev/null
  kubectl delete clusterrolebinding "${BINDING_NAME}" --ignore-not-found >/dev/null
  log "Listo. Nada más quedó pendiente."
}

write_manifests() {
  mkdir -p "${WORKDIR}"

  cat > "${WORKDIR}/00-namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF

  cat > "${WORKDIR}/10-crd.yaml" <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${CRD_NAME}
spec:
  group: training.cka.io
  scope: Namespaced
  names:
    plural: widgets
    singular: widget
    kind: Widget
    shortNames: ["wg"]
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: Message
          type: string
          jsonPath: .spec.message
        - name: Phase
          type: string
          jsonPath: .status.phase
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["message"]
              properties:
                message:
                  type: string
            status:
              type: object
              properties:
                phase:
                  type: string
EOF

  cat > "${WORKDIR}/20-rbac.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTERROLE_NAME}
rules:
  - apiGroups: ["training.cka.io"]
    resources: ["widgets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["training.cka.io"]
    resources: ["widgets/status"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${BINDING_NAME}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: ${CLUSTERROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF

  # Script del "mini-operator": reconcile loop en sh puro, sin dependencias.
  # Ojo: heredoc con delimitador entre comillas ('EOF') para que las variables
  # $ns/$name/$phase se evalúen adentro del contenedor, no acá en el host.
  cat > "${WORKDIR}/reconcile.sh" <<'EOF'
#!/bin/sh
set -u
echo "[widget-operator] arrancando, reconciliando cada 5s"
while true; do
  WIDGETS="$(kubectl get widgets.training.cka.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/tmp/last-error.log)"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "[widget-operator] ERROR listando widgets (revisa RBAC del ServiceAccount):"
    cat /tmp/last-error.log
    sleep 5
    continue
  fi
  echo "$WIDGETS" | while IFS='|' read -r ns name; do
    [ -z "$name" ] && continue
    phase="$(kubectl -n "$ns" get widgets.training.cka.io "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    if [ "$phase" != "Ready" ]; then
      msg="$(kubectl -n "$ns" get widgets.training.cka.io "$name" -o jsonpath='{.spec.message}')"
      echo "[widget-operator] reconciliando ${ns}/${name}: ${msg}"
      if kubectl -n "$ns" create configmap "widget-${name}" --from-literal=message="${msg}" --dry-run=client -o yaml | kubectl apply -f - >/tmp/cm-out.log 2>&1; then
        if kubectl -n "$ns" patch widgets.training.cka.io "$name" --type=merge --subresource=status -p '{"status":{"phase":"Ready"}}' >/tmp/patch-out.log 2>&1; then
          echo "[widget-operator] ${ns}/${name} -> Ready"
        else
          echo "[widget-operator] fallo al actualizar status de ${ns}/${name}:"
          cat /tmp/patch-out.log
        fi
      else
        echo "[widget-operator] fallo al crear configmap de ${ns}/${name}:"
        cat /tmp/cm-out.log
      fi
    fi
  done
  sleep 5
done
EOF

  cat > "${WORKDIR}/30-operator.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: widget-operator-script
  namespace: ${NAMESPACE}
data:
  reconcile.sh: |
$(sed 's/^/    /' "${WORKDIR}/reconcile.sh")
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: widget-operator
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: widget-operator
  template:
    metadata:
      labels:
        app: widget-operator
    spec:
      serviceAccountName: ${SA_NAME}
      containers:
        - name: operator
          image: ${OPERATOR_IMAGE}
          command: ["sh", "/scripts/reconcile.sh"]
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: widget-operator-script
            defaultMode: 0755
EOF

  cat > "${WORKDIR}/40-sample-widget.yaml" <<EOF
apiVersion: training.cka.io/v1
kind: Widget
metadata:
  name: demo-widget
  namespace: ${NAMESPACE}
spec:
  message: "hola desde el lab de CRDs"
EOF
}

install_lab() {
  log "Creando namespace, CRD, RBAC y operator en ${WORKDIR}..."
  kubectl apply -f "${WORKDIR}/00-namespace.yaml"
  kubectl apply -f "${WORKDIR}/10-crd.yaml"
  kubectl wait --for=condition=Established --timeout=60s "crd/${CRD_NAME}"
  kubectl apply -f "${WORKDIR}/20-rbac.yaml"
  kubectl apply -f "${WORKDIR}/30-operator.yaml"
  kubectl -n "${NAMESPACE}" rollout status deployment/widget-operator --timeout=90s

  log "Creando Widget de prueba y esperando reconciliación inicial..."
  kubectl apply -f "${WORKDIR}/40-sample-widget.yaml"

  local i phase
  for i in $(seq 1 15); do
    phase="$(kubectl -n "${NAMESPACE}" get widget demo-widget -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    if [[ "${phase}" == "Ready" ]] && kubectl -n "${NAMESPACE}" get configmap widget-demo-widget >/dev/null 2>&1; then
      log "Reconciliación inicial OK: demo-widget -> Ready, configmap widget-demo-widget creado."
      return 0
    fi
    sleep 4
  done
  die "El operator nunca reconcilió demo-widget. Revisá 'kubectl -n ${NAMESPACE} logs deploy/widget-operator' antes de seguir."
}

break_it() {
  log "Rompiendo el lab: borrando el ClusterRoleBinding del operator..."
  kubectl delete clusterrolebinding "${BINDING_NAME}" --ignore-not-found

  log "Creando un segundo Widget para que quede pendiente de reconciliar..."
  cat > "${WORKDIR}/41-broken-widget.yaml" <<EOF
apiVersion: training.cka.io/v1
kind: Widget
metadata:
  name: post-break-widget
  namespace: ${NAMESPACE}
spec:
  message: "este widget deberia quedar sin reconciliar"
EOF
  kubectl apply -f "${WORKDIR}/41-broken-widget.yaml"
  sleep 6

  cat <<MSG

================================================================
 SINTOMA
================================================================
El namespace '${NAMESPACE}' tiene un CRD (Widget) y un operator
(Deployment widget-operator) que veniamos viendo reconciliar sin
problemas: cada Widget nuevo generaba un ConfigMap y pasaba a
status.phase=Ready.

Ahora se creo el Custom Resource 'post-break-widget' y NO esta
siendo reconciliado:

  kubectl -n ${NAMESPACE} get widgets
  kubectl -n ${NAMESPACE} get configmap widget-post-break-widget   # No encontrado
  kubectl -n ${NAMESPACE} logs deploy/widget-operator --tail=20    # errores tipo Forbidden

El CRD sigue "Established", el Deployment del operator sigue con
1/1 Ready (el pod no crasheo), y el ClusterRole del operator sigue
existiendo. Algo en el camino entre el ServiceAccount del operator
y los permisos que necesita se rompio.

================================================================
 OBJETIVO
================================================================
Sin modificar el codigo del operator ni el CRD, y usando el
principio de menor privilegio (no uses cluster-admin ni un
binding mas amplio del necesario), lograr que:

  kubectl -n ${NAMESPACE} get widget post-break-widget -o jsonpath='{.status.phase}'

devuelva "Ready", y que exista:

  kubectl -n ${NAMESPACE} get configmap widget-post-break-widget

Pistas: revisa los logs del operator, la ServiceAccount que usa el
Deployment, y que objetos de RBAC (Role/ClusterRole/RoleBinding/
ClusterRoleBinding) referencian a esa ServiceAccount. 'kubectl auth
can-i --as=system:serviceaccount:${NAMESPACE}:${SA_NAME} ...' te va
a servir para confirmar el diagnostico.

Manifiestos originales del lab, por si los necesitas: ${WORKDIR}
================================================================
MSG
}

main() {
  require_kubectl

  if [[ "${DO_CLEANUP}" == "true" ]]; then
    cleanup
    exit 0
  fi

  confirm_lab_vm
  write_manifests
  install_lab
  break_it
}

main "$@"

# ================================================================
# SOLUCION PASO A PASO (spoiler - no leer hasta intentar diagnosticar)
# ================================================================
#
# 1) Confirmar el sintoma en los logs del operator:
#      kubectl -n crd-lab logs deploy/widget-operator --tail=20
#    Se ve algo como:
#      Error from server (Forbidden): widgets.training.cka.io is forbidden:
#      User "system:serviceaccount:crd-lab:widget-operator" cannot list
#      resource "widgets" in API group "training.cka.io" at the cluster scope
#
# 2) Confirmar el diagnostico sin adivinar, usando auth can-i:
#      kubectl auth can-i list widgets.training.cka.io -A \
#        --as=system:serviceaccount:crd-lab:widget-operator
#    Devuelve "no".
#
# 3) Revisar que el ClusterRole todavia existe (el problema NO es el Role):
#      kubectl get clusterrole widget-operator-role -o yaml
#
# 4) Revisar que el binding desaparecio:
#      kubectl get clusterrolebinding | grep widget-operator
#    (no aparece nada -> ahi esta la causa raiz)
#
# 5) Recrear el binding correcto, con el mismo alcance minimo que tenia
#    (no uses cluster-admin ni un Role mas permisivo):
#      kubectl create clusterrolebinding widget-operator-binding \
#        --clusterrole=widget-operator-role \
#        --serviceaccount=crd-lab:widget-operator
#
#    Alternativa (si conservaste el manifiesto original del script):
#      kubectl apply -f /tmp/widget-lab.*/20-rbac.yaml
#
# 6) Confirmar el permiso:
#      kubectl auth can-i list widgets.training.cka.io -A \
#        --as=system:serviceaccount:crd-lab:widget-operator
#    Devuelve "yes".
#
# 7) Esperar el proximo ciclo de reconciliacion (<=5s) y verificar:
#      kubectl -n crd-lab get widget post-break-widget -o jsonpath='{.status.phase}'
#      kubectl -n crd-lab get configmap widget-post-break-widget
#      kubectl -n crd-lab logs deploy/widget-operator --tail=10
#
# Para limpiar todo el lab despues:
#   ./break-fix-cka-4.7.sh --cleanup
# ================================================================