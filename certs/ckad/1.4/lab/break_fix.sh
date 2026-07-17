#!/usr/bin/env bash
#
# CKAD (examen v1.35) - Tema 1.4: Utilize persistent and ephemeral volumes (peso: 5)
# Fuente curricular: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Break & Fix: un PersistentVolumeClaim que nunca hace bind por un
# storageClassName con typo, mientras un volumen ephemeral (emptyDir) en el
# mismo Pod sigue funcionando sin problemas. El objetivo es que el
# estudiante distinga un fallo de storage persistente de uno ephemeral y
# sepa diagnosticar el binding entre PV y PVC.
#
# Pensado para correr en una VM de laboratorio DESCARTABLE con un cluster
# Kubernetes de un solo nodo (kind, minikube o k3s) y kubectl ya configurado
# contra ese cluster. No ejecutar contra un cluster que no sea de laboratorio.

set -euo pipefail

NAMESPACE="ckad-1-4-lab"
PV_NAME="pv-ckad-1-4"
PVC_NAME="pvc-ckad-1-4"
POD_NAME="web-ckad-1-4"
HOST_PATH="/mnt/ckad-1-4-data"
STORAGE_CLASS_OK="manual"
STORAGE_CLASS_BROKEN="manua"   # typo intencional para el "break"

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: kubectl no está en el PATH. Corré esto en la VM de laboratorio." >&2
    exit 1
  }
}

confirm_lab_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  echo "Contexto actual de kubectl: ${ctx}"
  read -r -p "Confirmás que este es un cluster de LABORATORIO descartable? [escribí 'si' para continuar] " ans
  if [[ "${ans}" != "si" ]]; then
    echo "Cancelado por el usuario. No se tocó el cluster."
    exit 1
  fi
}

setup_namespace() {
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl wait --for=delete namespace/"${NAMESPACE}" --timeout=60s >/dev/null 2>&1 || true
  kubectl create namespace "${NAMESPACE}" >/dev/null
}

apply_pod_manifest() {
  # Recibe el storageClassName que debe usar el PVC como $1
  local sc="$1"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${sc}
  resources:
    requests:
      storage: 200Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ckad-1-4
spec:
  initContainers:
    - name: seed-content
      image: busybox:1.36
      command: ["sh", "-c", "echo 'contenido persistente OK' > /data/index.html"]
      volumeMounts:
        - name: data-vol
          mountPath: /data
  containers:
    - name: nginx
      image: nginx:1.25-alpine
      volumeMounts:
        - name: data-vol
          mountPath: /usr/share/nginx/html
        - name: cache-vol
          mountPath: /tmp/cache
    - name: log-writer
      image: busybox:1.36
      command: ["sh", "-c", "while true; do date >> /cache/access.log; sleep 5; done"]
      volumeMounts:
        - name: cache-vol
          mountPath: /cache
  volumes:
    - name: data-vol
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
    - name: cache-vol
      emptyDir:
        sizeLimit: 50Mi
EOF
}

deploy_healthy_state() {
  echo ">> Desplegando estado inicial sano: PV + PVC (persistent) + Pod con emptyDir (ephemeral)..."

  # Asume cluster de un solo nodo, como corresponde a la VM de laboratorio.
  local node
  node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: 500Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${STORAGE_CLASS_OK}
  hostPath:
    path: ${HOST_PATH}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${node}
EOF

  apply_pod_manifest "${STORAGE_CLASS_OK}"

  kubectl wait --for=condition=Ready pod/"${POD_NAME}" -n "${NAMESPACE}" --timeout=90s
  echo ">> Estado sano confirmado: el Pod ${POD_NAME} está Running, el PVC quedó Bound"
  echo "   y el sidecar log-writer escribe en el volumen ephemeral /cache sin problema."
}

break_it() {
  echo ""
  echo ">> Rompiendo el entorno de forma controlada..."

  kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --wait=true
  kubectl delete pvc "${PVC_NAME}" -n "${NAMESPACE}" --wait=true

  # accessModes y storageClassName son inmutables en un PVC ya creado, por eso
  # hay que borrar y recrear para simular el manifest roto que "alguien pusheó".
  apply_pod_manifest "${STORAGE_CLASS_BROKEN}"

  echo ">> Listo. El daño ya está aplicado."
}

print_briefing() {
  cat <<'EOF'

====================================================================
SÍNTOMA que vas a observar
====================================================================
- "kubectl get pod web-ckad-1-4 -n ckad-1-4-lab" muestra el Pod en
  estado "Pending" y no avanza nunca a "Running".
- "kubectl get pvc pvc-ckad-1-4 -n ckad-1-4-lab" muestra STATUS
  "Pending" en vez de "Bound".
- "kubectl describe pod web-ckad-1-4 -n ckad-1-4-lab" tiene un evento
  del tipo "pod has unbound immediate PersistentVolumeClaims".
- El PersistentVolume "pv-ckad-1-4" existe y está "Available", pero
  nadie lo reclama.
- El volumen ephemeral (emptyDir) no tiene ningún problema: es
  puramente un bug del volumen persistente.

====================================================================
QUÉ TENÉS QUE LOGRAR
====================================================================
Hacé que el Pod "web-ckad-1-4" en el namespace "ckad-1-4-lab" llegue
a estado Running con sus contenedores Ready (init incluido), y que
el PVC "pvc-ckad-1-4" quede Bound contra el PV "pv-ckad-1-4"
existente, sin borrar ni recrear el PersistentVolume.

Pista de investigación: compará el storageClassName del PVC con el
storageClassName del PV, y con la salida de "kubectl get storageclass".
====================================================================

EOF
}

require_kubectl
confirm_lab_context
setup_namespace
deploy_healthy_state
break_it
print_briefing

# ====================================================================
# SOLUCIÓN paso a paso (no se ejecuta, queda como referencia)
# ====================================================================
#
# 1. Diagnosticar:
#      kubectl get pvc pvc-ckad-1-4 -n ckad-1-4-lab
#      kubectl describe pvc pvc-ckad-1-4 -n ckad-1-4-lab
#      kubectl get pv pv-ckad-1-4 -o jsonpath='{.spec.storageClassName}'
#    Se ve que el PVC pide storageClassName "manua" y el PV ofrece
#    "manual": no matchean, por eso el PVC nunca bindea.
#
# 2. storageClassName es inmutable en un PVC ya creado, así que hay que
#    borrarlo y recrearlo con el valor correcto:
#      kubectl delete pvc pvc-ckad-1-4 -n ckad-1-4-lab
#
# 3. Recrearlo apuntando a la storage class real:
#      cat <<EOF | kubectl apply -f -
#      apiVersion: v1
#      kind: PersistentVolumeClaim
#      metadata:
#        name: pvc-ckad-1-4
#        namespace: ckad-1-4-lab
#      spec:
#        accessModes:
#          - ReadWriteOnce
#        storageClassName: manual
#        resources:
#          requests:
#            storage: 200Mi
#      EOF
#
# 4. Verificar el bind:
#      kubectl get pvc pvc-ckad-1-4 -n ckad-1-4-lab
#      # STATUS debe pasar a Bound, VOLUME debe listar pv-ckad-1-4
#
# 5. El Pod ya referenciaba claimName: pvc-ckad-1-4, así que en cuanto
#    el PVC bindea, el kubelet monta el volumen y el Pod pasa a Running
#    solo (puede necesitar un "kubectl delete pod ... " si quedó en un
#    estado de scheduling colgado):
#      kubectl get pod web-ckad-1-4 -n ckad-1-4-lab -w
#
# 6. Confirmar contenido servido desde el volumen persistente:
#      kubectl exec -n ckad-1-4-lab web-ckad-1-4 -c nginx -- \
#        cat /usr/share/nginx/html/index.html
#      # Debe imprimir: contenido persistente OK
#
# 7. (Opcional) limpiar el namespace de laboratorio:
#      kubectl delete namespace ckad-1-4-lab
#      kubectl delete pv pv-ckad-1-4
# ====================================================================