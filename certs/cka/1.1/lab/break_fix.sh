#!/usr/bin/env bash
#
# break-fix: CKA (examen v1.35) - Tema 1.1
# "Implement storage classes and dynamic volume provisioning" (peso: 3.33%)
#
# Fuente de referencia (curriculum oficial, solo para ubicar el tema y su peso,
# el contenido de este script es original):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Uso:
#   ./break-fix-1.1-storage-classes.sh break     # rompe el laboratorio (default)
#   ./break-fix-1.1-storage-classes.sh verify    # chequea si ya lo arreglaste
#   ./break-fix-1.1-storage-classes.sh cleanup   # borra todo lo creado por el script
#
# Pensado para correr SOLO contra una VM de laboratorio descartable con un
# cluster de Kubernetes (kind/minikube/k3s/kubeadm) que ya tenga al menos
# un dynamic provisioner funcionando (por ejemplo local-path-provisioner,
# el hostpath provisioner de minikube, o un CSI driver). El script detecta
# ese provisioner automáticamente; si no encuentra ninguno, aborta sin tocar
# nada.

set -euo pipefail

NS="cka-1-1-storage-lab"
BROKEN_SC="cka-lab-broken-sc"
PVC_NAME="cka-lab-pvc"
POD_NAME="cka-lab-writer"
FAKE_PROVISIONER="example.com/does-not-exist"

info()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || die "No se encontró kubectl en el PATH."
  kubectl get nodes >/dev/null 2>&1 || die "No se pudo contactar al cluster (revisá tu kubeconfig/context)."
}

confirm_disposable_vm() {
  if [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM:-}" == "yes" ]]; then
    return
  fi
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  warn "Este script crea objetos en el cluster del context actual: '${ctx}'."
  warn "Corré esto SOLO en una VM de laboratorio descartable, nunca contra un cluster real."
  read -r -p "Escribí 'romper' para continuar: " respuesta
  [[ "$respuesta" == "romper" ]] || die "Cancelado por el usuario."
}

detect_working_provisioner() {
  local sc_name
  sc_name=$(kubectl get storageclass \
    -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
    2>/dev/null || true)
  if [[ -z "$sc_name" ]]; then
    sc_name=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi
  [[ -n "$sc_name" ]] || die "No hay ninguna StorageClass en el cluster. Instalá un provisioner (ej: local-path-provisioner) antes de correr este laboratorio."
  kubectl get storageclass "$sc_name" -o jsonpath='{.provisioner}'
}

cmd_break() {
  require_kubectl
  confirm_disposable_vm

  local real_provisioner
  real_provisioner="$(detect_working_provisioner)"
  ok "Provisioner funcional detectado en el cluster: ${real_provisioner}"
  info "Guardá ese nombre, lo vas a necesitar para arreglar el laboratorio."

  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  info "Creando una StorageClass con el provisioner apuntando mal a propósito..."
  kubectl apply -f - <<EOF >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${BROKEN_SC}
provisioner: ${FAKE_PROVISIONER}
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

  info "Creando un PersistentVolumeClaim que usa esa StorageClass..."
  kubectl apply -n "$NS" -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${BROKEN_SC}
  resources:
    requests:
      storage: 1Gi
EOF

  info "Creando un Pod que monta ese PVC..."
  kubectl apply -n "$NS" -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo hello from CKA lab > /data/hello.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF

  cat <<MSG

============================================================
 LABORATORIO ROTO: namespace '${NS}'
============================================================

SÍNTOMA que vas a observar:
  - kubectl get pvc -n ${NS}
      -> ${PVC_NAME} va a quedar en fase "Pending" indefinidamente.
  - kubectl get pod -n ${NS}
      -> ${POD_NAME} va a quedar en fase "Pending" (no puede arrancar
         porque su volumen nunca se provisiona).
  - kubectl describe pvc ${PVC_NAME} -n ${NS}
      -> En events vas a ver algo como "waiting for a volume to be
         created, either by external provisioner "${FAKE_PROVISIONER}"
         or manually by system administrator", repetido cada tanto.

Notá que "kubectl apply" de la StorageClass rota funcionó sin error:
Kubernetes no valida que el campo "provisioner" corresponda a un
controller real que exista en el cluster. El fallo es completamente
asíncrono y silencioso del lado del apiserver.

OBJETIVO (qué tenés que lograr):
  1. Diagnosticar por qué el PVC nunca se bindea, usando "describe"
     sobre el PVC y sobre la StorageClass.
  2. Arreglar la StorageClass '${BROKEN_SC}' para que use un
     provisioner que sí funcione en este cluster.
     Pista: el campo "provisioner" de una StorageClass es inmutable
     una vez creada (kubectl edit no te va a dejar cambiarlo).
  3. Sin borrar ni recrear el PVC ni el Pod, lograr que:
       - ${PVC_NAME} quede en fase "Bound"
       - ${POD_NAME} quede en fase "Running"

Cuando creas que lo resolviste, corré:
  $0 verify

============================================================
MSG
}

cmd_verify() {
  require_kubectl
  local pvc_phase pod_phase
  pvc_phase=$(kubectl get pvc "$PVC_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  pod_phase=$(kubectl get pod "$POD_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  echo "PVC ${PVC_NAME}: ${pvc_phase}"
  echo "Pod ${POD_NAME}: ${pod_phase}"

  if [[ "$pvc_phase" == "Bound" && "$pod_phase" == "Running" ]]; then
    ok "Laboratorio resuelto: PVC Bound y Pod Running."
  else
    warn "Todavía no. Objetivo: PVC Bound y Pod Running."
  fi
}

cmd_cleanup() {
  require_kubectl
  info "Borrando namespace '${NS}' y la StorageClass '${BROKEN_SC}'..."
  kubectl delete namespace "$NS" --ignore-not-found
  kubectl delete storageclass "$BROKEN_SC" --ignore-not-found
  ok "Limpieza completa."
}

case "${1:-break}" in
  break)   cmd_break ;;
  verify)  cmd_verify ;;
  cleanup) cmd_cleanup ;;
  *) die "Uso: $0 [break|verify|cleanup]" ;;
esac

# ============================================================
# SOLUCIÓN PASO A PASO (comentada, no se ejecuta)
# ============================================================
#
# 1) Diagnóstico:
#
#    kubectl get pvc -n cka-1-1-storage-lab
#      -> ver que cka-lab-pvc está "Pending"
#
#    kubectl describe pvc cka-lab-pvc -n cka-1-1-storage-lab
#      -> en Events aparece el mensaje de espera por un provisioner
#         que no existe (example.com/does-not-exist)
#
#    kubectl get storageclass cka-lab-broken-sc -o yaml
#      -> confirmar que "provisioner: example.com/does-not-exist"
#         es el nombre inventado, no coincide con ningún controller
#         real corriendo en el cluster (compará contra el provisioner
#         que anotaste al principio del ejercicio, el que devolvió
#         detect_working_provisioner, por ejemplo "rancher.io/local-path"
#         o "k8s.io/minikube-hostpath" según el cluster).
#
# 2) El campo "provisioner" es inmutable, así que no se puede editar
#    la StorageClass existente. Hay que borrarla y recrearla con el
#    MISMO nombre pero el provisioner correcto:
#
#    kubectl delete storageclass cka-lab-broken-sc
#
#    kubectl apply -f - <<EOF
#    apiVersion: storage.k8s.io/v1
#    kind: StorageClass
#    metadata:
#      name: cka-lab-broken-sc
#    provisioner: <PROVISIONER_REAL_DETECTADO_EN_EL_PASO_1>
#    reclaimPolicy: Delete
#    volumeBindingMode: Immediate
#    EOF
#
# 3) El PVC cka-lab-pvc sigue existiendo, sin modificar, referenciando
#    la StorageClass por nombre. Apenas el controller de provisioning
#    (kube-controller-manager o el sidecar CSI, según el caso) hace su
#    próximo resync, va a ver una StorageClass con un provisioner que
#    sí reconoce y va a crear el PersistentVolume dinámicamente:
#
#    kubectl get pvc cka-lab-pvc -n cka-1-1-storage-lab -w
#      -> pasa de "Pending" a "Bound" (puede tardar unos segundos)
#
# 4) Una vez que el PVC está Bound, el scheduler puede completar el
#    montaje del volumen y el Pod arranca solo:
#
#    kubectl get pod cka-lab-writer -n cka-1-1-storage-lab -w
#      -> pasa de "Pending" a "Running"
#
# 5) Verificación final:
#
#    kubectl exec -n cka-1-1-storage-lab cka-lab-writer -- cat /data/hello.txt
#      -> debe imprimir "hello from CKA lab"
#
# ============================================================