#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CKA 1.35 - Tema 1.3: Manage persistent volumes and persistent
# volume claims (peso examen: 3.34%)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Este script ROMPE algo a propósito en un namespace de laboratorio
# dedicado. Pensado para correr contra un cluster kubeadm/kind/minikube
# de UN SOLO NODO que sea completamente descartable. NO lo corras
# contra un cluster real ni compartido: crea, borra y vuelve a crear
# objetos, y usa hostPath en el/los nodo(s).
# ============================================================

if [[ "${LAB_CONFIRM:-}" != "yes" ]]; then
  echo "Este script modifica el cluster al que apunte tu kubeconfig actual."
  echo "Corre solo contra una VM de laboratorio descartable."
  echo "Si entendes el riesgo, volve a ejecutar con:"
  echo "  LAB_CONFIRM=yes bash $0"
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado en el PATH."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "No se pudo contactar al cluster. Revisa tu kubeconfig."; exit 1; }

NAMESPACE="cka-1-3-lab"
PV_NAME="pv-cka-1-3"
PVC_NAME="pvc-cka-1-3"
POD_WRITER="writer-cka-1-3"
POD_APP="app-cka-1-3"
STORAGE_CLASS_NAME="manual"
DATA_CONTENT="dato-original-$(date +%s)"

NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$NODE_NAME" ]]; then
  echo "No se detecto ningun nodo en el cluster."
  exit 1
fi

echo ">>> Limpiando restos de una corrida anterior (si existen)..."
kubectl delete ns "$NAMESPACE" --ignore-not-found --wait=true >/dev/null
kubectl delete pv "$PV_NAME" --ignore-not-found --wait=true >/dev/null

echo ">>> Creando namespace de laboratorio..."
kubectl create namespace "$NAMESPACE" >/dev/null

echo ">>> Creando PersistentVolume estatico (hostPath, Retain)..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV_NAME
spec:
  capacity:
    storage: 1Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: $STORAGE_CLASS_NAME
  hostPath:
    path: /tmp/cka-1-3-lab-data
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - $NODE_NAME
EOF

echo ">>> Creando PersistentVolumeClaim..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $STORAGE_CLASS_NAME
  resources:
    requests:
      storage: 1Gi
EOF

echo ">>> Esperando bind inicial de la PVC..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC_NAME" -n "$NAMESPACE" --timeout=60s

echo ">>> Levantando pod para escribir datos en el volumen..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD_WRITER
  namespace: $NAMESPACE
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $PVC_NAME
EOF

kubectl wait --for=condition=Ready "pod/$POD_WRITER" -n "$NAMESPACE" --timeout=90s
kubectl exec -n "$NAMESPACE" "$POD_WRITER" -- sh -c "echo $DATA_CONTENT > /data/hello.txt"
echo ">>> Dato escrito en /data/hello.txt: $DATA_CONTENT"

echo ">>> Liberando el pod para poder soltar la PVC..."
kubectl delete pod "$POD_WRITER" -n "$NAMESPACE" --wait=true >/dev/null

echo ">>> ROMPIENDO EL LABORATORIO..."
# Se simula que alguien borro la PVC por error y volvio a aplicar
# el mismo manifiesto esperando que todo siga funcionando igual.
kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE" --wait=true >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $STORAGE_CLASS_NAME
  resources:
    requests:
      storage: 1Gi
EOF

echo ">>> Volviendo a desplegar el pod de la aplicacion..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD_APP
  namespace: $NAMESPACE
spec:
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
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
        claimName: $PVC_NAME
EOF

sleep 5

echo ""
echo "================================================================"
echo " ESTADO ACTUAL DEL LABORATORIO ($NAMESPACE)"
echo "================================================================"
kubectl get pv "$PV_NAME"
echo ""
kubectl get pvc -n "$NAMESPACE"
echo ""
kubectl get pod -n "$NAMESPACE" -o wide
echo "================================================================"
echo ""
echo "SINTOMA:"
echo "  - La PVC '$PVC_NAME' quedo en estado Pending y no vuelve a"
echo "    engancharse con el PV existente, aunque storageClassName,"
echo "    accessModes y capacity siguen coincidiendo."
echo "  - El pod '$POD_APP' quedo en Pending porque su PVC no esta Bound."
echo "  - El PV '$PV_NAME' ya no figura como Available."
echo ""
echo "OBJETIVO:"
echo "  1. Diagnosticar por que la PVC no se bindea automaticamente."
echo "  2. Lograr que la PVC '$PVC_NAME' quede Bound REUTILIZANDO el"
echo "     PV existente '$PV_NAME' (sin borrarlo ni recrearlo)."
echo "  3. Lograr que el pod '$POD_APP' llegue a Running."
echo "  4. Confirmar que el archivo /data/hello.txt sigue teniendo el"
echo "     mismo contenido que se escribio antes de la rotura:"
echo "     valor esperado -> $DATA_CONTENT"
echo ""
echo "Cuando termines, limpia con:"
echo "  kubectl delete ns $NAMESPACE"
echo "  kubectl delete pv $PV_NAME"
echo "================================================================"

exit 0

# ================================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
# ================================================================
#
# 1) Diagnostico:
#    kubectl get pv pv-cka-1-3
#      -> STATUS = Released (no Available). La columna CLAIM sigue
#         mostrando cka-1-3-lab/pvc-cka-1-3, pero es una referencia
#         al objeto PVC viejo (distinto UID), no al nuevo.
#    kubectl describe pv pv-cka-1-3
#      -> spec.claimRef todavia apunta al UID de la PVC eliminada.
#    kubectl get pvc -n cka-1-3-lab
#      -> pvc-cka-1-3 en Pending, sin eventos de bind exitoso.
#
#    Causa raiz: con persistentVolumeReclaimPolicy=Retain, al borrar
#    la PVC el PV pasa a Released (no vuelve a Available) y conserva
#    su claimRef antiguo. El control loop de binding solo considera
#    PVs en Available, asi que una PVC nueva con specs identicas
#    jamas se engancha sola, por mas que "matchee" en teoria.
#
# 2) Liberar el PV quitando la referencia obsoleta, SIN borrar el PV:
#    kubectl patch pv pv-cka-1-3 --type=json \
#      -p='[{"op": "remove", "path": "/spec/claimRef"}]'
#
#    (alternativa equivalente: kubectl edit pv pv-cka-1-3 y borrar a
#    mano el bloque claimRef completo)
#
# 3) Verificar que el PV vuelve a Available y que la PVC bindea sola:
#    kubectl get pv pv-cka-1-3 -w
#    kubectl get pvc -n cka-1-3-lab -w
#
# 4) Verificar que el pod de la app pasa a Running:
#    kubectl get pod -n cka-1-3-lab -w
#
# 5) Confirmar que los datos originales sobrevivieron al ciclo
#    Released -> Available:
#    kubectl exec -n cka-1-3-lab app-cka-1-3 -- cat /data/hello.txt
#      -> debe imprimir exactamente el valor mostrado como
#         "esperado" en la salida del script (dato-original-<epoch>)
#
# 6) Limpieza del laboratorio:
#    kubectl delete ns cka-1-3-lab
#    kubectl delete pv pv-cka-1-3
# ================================================================