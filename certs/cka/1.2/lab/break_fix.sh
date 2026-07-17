#!/usr/bin/env bash
#
# CKA v1.35 - Tema 1.2: Configure volume types, access modes and reclaim policies
# Peso en el examen: 3.33
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Break & Fix lab pensado para correrse en una VM de laboratorio descartable
# con un cluster de un solo nodo (kind/minikube/k3s) donde este script y
# kubectl corren en el mismo host que hostea los volúmenes hostPath.
#
# Uso:
#   ./lab-1.2-volumes.sh break   # rompe el escenario (default)
#   ./lab-1.2-volumes.sh status  # muestra el estado actual del lab
#   ./lab-1.2-volumes.sh clean   # borra todos los recursos del lab
#
set -euo pipefail

NAMESPACE="vol-lab-12"
LAB_LABEL="lab=vol-lab-12"
HOSTPATH_BASE="/mnt/data/vol-lab-12"
KC="${KUBECTL:-kubectl}"

log()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[lab][atención]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[lab][error]\033[0m %s\n' "$*" >&2; }

require_kubectl() {
  if ! command -v "$KC" >/dev/null 2>&1; then
    err "No se encontró kubectl en el PATH. Instalalo antes de continuar."
    exit 1
  fi
  if ! $KC cluster-info >/dev/null 2>&1; then
    err "kubectl no puede contactar al cluster. Revisá tu kubeconfig/contexto."
    exit 1
  fi
}

confirm_disposable() {
  local ctx
  ctx="$($KC config current-context 2>/dev/null || echo '(desconocido)')"
  warn "Este script crea PersistentVolumes con hostPath y borra namespaces."
  warn "Contexto actual de kubectl: ${ctx}"
  warn "Corré esto SOLO en una VM/cluster de laboratorio descartable."
  if [ "${LAB_YES:-}" != "1" ]; then
    read -r -p "¿Confirmás que este es un entorno descartable? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) err "Cancelado por el usuario."; exit 1 ;;
    esac
  fi
}

cleanup_previous() {
  log "Limpiando restos de una corrida anterior (si existen)..."
  $KC delete namespace "$NAMESPACE" --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  $KC delete pv -l "$LAB_LABEL" --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  rm -rf "${HOSTPATH_BASE:?}" 2>/dev/null || true
}

break_lab() {
  require_kubectl
  confirm_disposable
  cleanup_previous

  log "Preparando directorios hostPath en el nodo local..."
  mkdir -p "${HOSTPATH_BASE}/pv-data" "${HOSTPATH_BASE}/pv-archive"

  log "Creando namespace ${NAMESPACE}..."
  $KC create namespace "$NAMESPACE" >/dev/null

  log "Creando PV disponible (pv-data, RWO, reclaimPolicy=Delete)..."
  $KC apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-data-vol-lab-12
  labels:
    lab: vol-lab-12
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: manual
  hostPath:
    path: ${HOSTPATH_BASE}/pv-data
EOF

  log "Creando PV de archivo (pv-archive, RWO, reclaimPolicy=Retain)..."
  $KC apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-archive-vol-lab-12
  labels:
    lab: vol-lab-12
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: ${HOSTPATH_BASE}/pv-archive
EOF

  log "Simulando un uso previo de pv-archive con un PVC temporal..."
  $KC apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-archive-tmp
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual
  volumeName: pv-archive-vol-lab-12
  resources:
    requests:
      storage: 1Gi
EOF

  $KC wait -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound \
    pvc/pvc-archive-tmp --timeout=30s >/dev/null

  log "Borrando el PVC temporal para dejar pv-archive en estado Released..."
  $KC delete pvc pvc-archive-tmp -n "$NAMESPACE" --wait=true --timeout=30s >/dev/null

  log "Creando el PVC de la aplicación con un access mode incompatible..."
  $KC apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-app
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: manual
  resources:
    requests:
      storage: 1Gi
EOF

  log "Creando el pod que depende de ese PVC..."
  $KC apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-app
  namespace: ${NAMESPACE}
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pvc-app
EOF

  sleep 5

  echo
  log "Estado actual del lab (esto es lo que vas a ver recién roto):"
  echo
  $KC get pv -l "$LAB_LABEL" -o wide
  echo
  $KC get pvc -n "$NAMESPACE" -o wide
  echo
  $KC get pod -n "$NAMESPACE" -o wide
  echo

  cat <<'MSG'
================================================================
SÍNTOMA
================================================================
- pod-app queda en estado Pending y no arranca.
- pvc-app queda en estado Pending indefinidamente (no bindea a
  ningún PersistentVolume).
- Hay dos PersistentVolume en el cluster: uno en estado Available
  y otro en estado Released, con un claimRef que apunta a un PVC
  que ya no existe (pvc-archive-tmp).

================================================================
OBJETIVO (qué tenés que lograr; no se te dice cómo)
================================================================
1. Lograr que pod-app quede Running, con pvc-app en estado Bound,
   sin borrar ni recrear pod-app ni el namespace.
2. Dejar el PV que quedó en Released nuevamente en estado Available,
   para que pueda ser reutilizado por un futuro PVC, entendiendo por
   qué Kubernetes no lo liberó automáticamente.

Investigá con: kubectl describe pvc/pv/pod -n vol-lab-12
Prestá atención a: accessModes, storageClassName, capacity y
persistentVolumeReclaimPolicy.

Cuando termines, corré: ./lab-1.2-volumes.sh status
================================================================
MSG
}

show_status() {
  require_kubectl
  echo "--- PersistentVolumes ---"
  $KC get pv -l "$LAB_LABEL" -o wide || true
  echo
  echo "--- PersistentVolumeClaims (${NAMESPACE}) ---"
  $KC get pvc -n "$NAMESPACE" -o wide || true
  echo
  echo "--- Pods (${NAMESPACE}) ---"
  $KC get pod -n "$NAMESPACE" -o wide || true
}

clean_lab() {
  require_kubectl
  cleanup_previous
  log "Lab limpiado."
}

case "${1:-break}" in
  break)  break_lab ;;
  status) show_status ;;
  clean)  clean_lab ;;
  *)
    err "Uso: $0 [break|status|clean]"
    exit 1
    ;;
esac

exit 0

# ================================================================
# SOLUCIÓN PASO A PASO (comentada — no se ejecuta)
# ================================================================
#
# 1. Diagnóstico del pod/PVC que no bindea:
#
#    kubectl describe pvc pvc-app -n vol-lab-12
#    # El evento muestra algo como:
#    # "no persistent volumes available for this claim and no
#    #  storage class is set" o, si tu versión de k8s lo detalla,
#    # verás que ningún PV ofrece accessModes: ReadWriteMany.
#
#    kubectl get pv -l lab=vol-lab-12
#    # pv-data-vol-lab-12    Available   accessModes: [ReadWriteOnce]
#    # pv-archive-vol-lab-12 Released    accessModes: [ReadWriteOnce]
#
#    Causa raíz: pvc-app pide ReadWriteMany, pero los únicos PV con
#    storageClassName=manual son ReadWriteOnce (hostPath, de hecho,
#    NO soporta ReadWriteMany en ningún caso). Por eso nunca hay un
#    PV candidato y el PVC queda Pending para siempre.
#
# 2. Arreglar el access mode del PVC para que coincida con lo que
#    el volumen puede ofrecer:
#
#    kubectl edit pvc pvc-app -n vol-lab-12
#    # cambiar accessModes de [ReadWriteMany] a [ReadWriteOnce]
#    #
#    # (los PVC son en gran parte inmutables una vez creados; si tu
#    # versión de Kubernetes rechaza el edit in-place, hay que borrar
#    # y recrear el PVC con el spec correcto: mismo name, mismo
#    # namespace, storageClassName: manual, accessModes: [ReadWriteOnce],
#    # requests.storage: 1Gi. El Pod referencia el PVC por nombre, así
#    # que al recrearse con el mismo nombre el Pod puede quedarse.)
#
#    kubectl get pvc pvc-app -n vol-lab-12 -w
#    # debería pasar a Bound, bindeando contra pv-data-vol-lab-12
#    # (el único PV en estado Available con accessMode compatible).
#
#    kubectl get pod pod-app -n vol-lab-12
#    # debería pasar a Running una vez que el PVC está Bound.
#
# 3. Recuperar el PV en estado Released (pv-archive-vol-lab-12):
#
#    kubectl get pv pv-archive-vol-lab-12 -o yaml
#    # spec.claimRef sigue apuntando a vol-lab-12/pvc-archive-tmp,
#    # que ya no existe. Como persistentVolumeReclaimPolicy: Retain,
#    # Kubernetes NUNCA borra automáticamente el PV ni limpia sus
#    # datos/claimRef al borrarse el PVC (a diferencia de Delete,
#    # que sí habría eliminado el PV y el hostPath subyacente).
#    # El reclamo manual queda a cargo del administrador.
#
#    kubectl patch pv pv-archive-vol-lab-12 --type=json \
#      -p '[{"op":"remove","path":"/spec/claimRef"}]'
#    # (alternativa equivalente: kubectl edit pv pv-archive-vol-lab-12
#    # y borrar a mano el bloque spec.claimRef)
#
#    kubectl get pv pv-archive-vol-lab-12
#    # STATUS debería pasar de Released a Available, quedando libre
#    # para ser reclamado por un futuro PVC.
#
# 4. Verificación final:
#
#    kubectl get pv -l lab=vol-lab-12
#    kubectl get pvc -n vol-lab-12
#    kubectl get pod -n vol-lab-12
#    # pv-data-vol-lab-12    Bound       pvc-app
#    # pv-archive-vol-lab-12 Available
#    # pvc-app               Bound
#    # pod-app               Running
#
# ================================================================