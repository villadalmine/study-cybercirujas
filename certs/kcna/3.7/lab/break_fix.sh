#!/usr/bin/env bash
#
# KCNA - Dominio 3.7 Storage (peso: 4)
# Lab break & fix: Persistent Volumes / Persistent Volume Claims en Kubernetes
#
# Referencia: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# Ejecutar SOLO en una VM de laboratorio descartable con acceso a un
# cluster de Kubernetes de UN SOLO NODO donde el kubelet corre en la
# misma máquina que este script (k3s, kubeadm de un nodo, minikube en
# modo --driver=none), para que el hostPath usado abajo sea visible
# tanto para el script como para el kubelet.
#
# Todos los recursos quedan identificados por el namespace
# "kcna-storage-lab" y el label lab=kcna-storage, para poder destruir
# el laboratorio entero con:
#   kubectl delete ns kcna-storage-lab
#   kubectl delete pv lab-pv
#
set -euo pipefail

NAMESPACE="kcna-storage-lab"
PV_NAME="lab-pv"
PVC_NAME="lab-pvc"
POD_NAME="lab-app"
HOSTPATH_DIR="/tmp/${NAMESPACE}-pv"

echo "==================================================================="
echo " KCNA 3.7 Storage - break & fix lab"
echo "==================================================================="
echo

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl no está instalado. Abortando." >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: no hay un cluster accesible con el kubeconfig actual. Abortando." >&2; exit 1; }

echo "-> Preparando namespace y directorio de hostPath..."
mkdir -p "$HOSTPATH_DIR"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "-> Creando PersistentVolume ${PV_NAME} (storageClassName: lab-slow)..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
  labels:
    lab: kcna-storage
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: lab-slow
  hostPath:
    path: ${HOSTPATH_DIR}
EOF

echo "-> Inyectando la falla: PVC pidiendo un storageClassName que no existe..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    lab: kcna-storage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: lab-fast
EOF

echo "-> Desplegando el Pod que depende de ese PVC..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    lab: kcna-storage
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo hello-kcna > /data/hello.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF

sleep 3

echo
echo "==================================================================="
echo " SÍNTOMA"
echo "==================================================================="
cat <<'MSG'
El Pod "lab-app" en el namespace "kcna-storage-lab" no arranca:

  kubectl get pod -n kcna-storage-lab lab-app

lo va a mostrar en estado "Pending" (o "ContainerCreating" según el
runtime) indefinidamente. El PVC asociado también se queda pegado:

  kubectl get pvc -n kcna-storage-lab lab-pvc

muestra STATUS "Pending" y nunca avanza a "Bound", aunque ya existe un
PersistentVolume en el cluster con capacidad de sobra:

  kubectl get pv lab-pv

lo muestra en estado "Available" (nadie lo está usando).

OBJETIVO
--------
Lograr que:
  1. "kubectl get pvc -n kcna-storage-lab lab-pvc" muestre STATUS "Bound".
  2. "kubectl get pod -n kcna-storage-lab lab-app" muestre STATUS "Running".
  3. El archivo /data/hello.txt exista dentro del contenedor:
       kubectl exec -n kcna-storage-lab lab-app -- cat /data/hello.txt

PISTAS
------
- Compará el "storageClassName" del PVC contra el del PV, y contra la
  salida de "kubectl get storageclass".
- "kubectl describe pvc -n kcna-storage-lab lab-pvc" trae el evento
  que explica por qué el volume binder no encuentra candidato.
- El campo spec.storageClassName de un PVC es inmutable una vez creado:
  no alcanza con "kubectl edit" ni "kubectl patch". Vas a necesitar
  borrar y recrear el recurso correcto (y lo que bloquee ese borrado).

Para destruir todo el laboratorio cuando termines:
  kubectl delete ns kcna-storage-lab
  kubectl delete pv lab-pv
MSG

echo "==================================================================="

exit 0

# ===================================================================
# SOLUCIÓN (comentada, no se ejecuta)
# ===================================================================
#
# 1. Confirmar el síntoma:
#      kubectl get pvc -n kcna-storage-lab lab-pvc
#      kubectl get pod -n kcna-storage-lab lab-app
#      kubectl get pv lab-pv
#
# 2. Ver por qué el PVC no bindea:
#      kubectl describe pvc -n kcna-storage-lab lab-pvc
#    El evento dice algo como:
#      "waiting for a volume to be created, either by external
#       provisioner "lab-fast" or manually created by system administrator"
#    Eso indica que Kubernetes busca un StorageClass o un PV estático
#    con storageClassName=lab-fast, y ninguno existe.
#
# 3. Comparar las storageClassName en juego:
#      kubectl get pvc -n kcna-storage-lab lab-pvc -o jsonpath='{.spec.storageClassName}{"\n"}'
#      kubectl get pv lab-pv -o jsonpath='{.spec.storageClassName}{"\n"}'
#      kubectl get storageclass
#    El PVC pide "lab-fast" (no existe como StorageClass), mientras que
#    el único PV disponible usa "lab-slow". El binding estático exige
#    coincidencia exacta de accessModes + capacidad + storageClassName,
#    así que nunca ocurre, y como tampoco hay un provisioner dinámico
#    para "lab-fast", el PVC queda Pending para siempre.
#
# 4. spec.storageClassName es inmutable en un PVC ya creado (patch/edit
#    fallan con un error de campo inmutable). Además, mientras el Pod
#    exista referenciando el PVC, el finalizer kubernetes.io/pvc-protection
#    bloquea su borrado. Hay que borrar primero el Pod y después el PVC:
#      kubectl delete pod -n kcna-storage-lab lab-app
#      kubectl delete pvc -n kcna-storage-lab lab-pvc
#
# 5. Recrear el PVC con el storageClassName correcto (el mismo que el PV):
#      cat <<EOF | kubectl apply -f -
#      apiVersion: v1
#      kind: PersistentVolumeClaim
#      metadata:
#        name: lab-pvc
#        namespace: kcna-storage-lab
#      spec:
#        accessModes:
#          - ReadWriteOnce
#        resources:
#          requests:
#            storage: 1Gi
#        storageClassName: lab-slow
#      EOF
#
# 6. Verificar el bind:
#      kubectl get pvc -n kcna-storage-lab lab-pvc
#      # STATUS debe pasar a "Bound" y VOLUME debe listar "lab-pv"
#
# 7. Recrear el Pod (mismo manifiesto que generó el script):
#      cat <<EOF | kubectl apply -f -
#      apiVersion: v1
#      kind: Pod
#      metadata:
#        name: lab-app
#        namespace: kcna-storage-lab
#      spec:
#        containers:
#          - name: writer
#            image: busybox:1.36
#            command: ["sh", "-c", "echo hello-kcna > /data/hello.txt && sleep 3600"]
#            volumeMounts:
#              - name: data
#                mountPath: /data
#        volumes:
#          - name: data
#            persistentVolumeClaim:
#              claimName: lab-pvc
#      EOF
#
# 8. Confirmar la solución:
#      kubectl get pod -n kcna-storage-lab lab-app
#      # STATUS debe pasar a "Running"
#      kubectl exec -n kcna-storage-lab lab-app -- cat /data/hello.txt
#      # Debe imprimir: hello-kcna
#
# 9. Limpieza del laboratorio:
#      kubectl delete ns kcna-storage-lab
#      kubectl delete pv lab-pv
#