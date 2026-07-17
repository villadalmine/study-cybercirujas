#!/usr/bin/env bash
#
# CKA 1.35 - 3.1 Understand application deployments and how to perform
# rolling update and rollbacks
#
# break-fix: dispara un rolling update de un Deployment hacia una imagen
# que no existe, dejando el rollout trabado a mitad de camino.
#
# Uso:
#   ./3.1-break-fix.sh           -> rompe el entorno
#   ./3.1-break-fix.sh cleanup   -> borra todo lo creado por el script
#
# Pensado para correr contra un cluster de laboratorio DESCARTABLE
# (kubeadm, kind, etc.) con kubectl ya configurado contra ese cluster.
# Todo el trabajo queda aislado en un namespace dedicado para no tocar
# nada más del cluster.

set -euo pipefail

NAMESPACE="cka-3-1-lab"
DEPLOYMENT="web"
GOOD_IMAGE="nginx:1.25"
BAD_IMAGE="nginx:1.25-does-not-exist"
REPLICAS=4

cleanup() {
  echo ">> Borrando namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=false
  echo ">> Listo. El namespace termina de borrarse en background."
}

if [[ "${1:-}" == "cleanup" ]]; then
  cleanup
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado en el PATH" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "No se puede contactar al cluster. Revisá tu kubeconfig." >&2; exit 1; }

echo "=================================================================="
echo " CKA 3.1 - break & fix: rolling update trabado"
echo "=================================================================="
echo
echo ">> Preparando namespace y Deployment en estado sano..."

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT}
  labels:
    app: ${DEPLOYMENT}
spec:
  replicas: ${REPLICAS}
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: ${DEPLOYMENT}
  template:
    metadata:
      labels:
        app: ${DEPLOYMENT}
    spec:
      containers:
        - name: ${DEPLOYMENT}
          image: ${GOOD_IMAGE}
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
EOF

echo ">> Esperando a que el Deployment quede Ready con la imagen buena (revision 1)..."
kubectl rollout status deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=120s

echo
echo ">> Todo sano. Ahora se rompe algo de forma controlada..."
sleep 1

kubectl set image deployment/"${DEPLOYMENT}" "${DEPLOYMENT}=${BAD_IMAGE}" -n "${NAMESPACE}" >/dev/null

echo
echo "=================================================================="
echo " ENTORNO ROTO - namespace: ${NAMESPACE}"
echo "=================================================================="
cat <<EOF

Se disparó un rolling update sobre el Deployment "${DEPLOYMENT}" en el
namespace "${NAMESPACE}" que apunta a una imagen que no existe en el
registry.

SÍNTOMA que vas a observar:
  - "kubectl get pods -n ${NAMESPACE}" muestra algunos pods nuevos en
    estado ImagePullBackOff o ErrImagePull, mezclados con pods viejos
    que siguen corriendo.
  - "kubectl rollout status deployment/${DEPLOYMENT} -n ${NAMESPACE}"
    no termina (queda esperando, el rollout no progresa).
  - "kubectl get deployment ${DEPLOYMENT} -n ${NAMESPACE}" muestra
    menos réplicas UP-TO-DATE/AVAILABLE que el total deseado (${REPLICAS}).

QUÉ TENÉS QUE LOGRAR:
  1. Diagnosticar por qué el rollout no progresa (identificar la
     imagen mala como causa raíz).
  2. Dejar el Deployment "${DEPLOYMENT}" en estado sano: todas las
     réplicas deseadas Running, Ready y con una imagen que exista.
  3. Confirmar que "kubectl rollout status deployment/${DEPLOYMENT} -n ${NAMESPACE}"
     termina OK y que "kubectl rollout history deployment/${DEPLOYMENT} -n ${NAMESPACE}"
     refleja el revision correcto.

Pistas de comandos a explorar (sin spoilear la solución):
  kubectl get pods -n ${NAMESPACE} -o wide
  kubectl describe pod <pod> -n ${NAMESPACE}
  kubectl rollout history deployment/${DEPLOYMENT} -n ${NAMESPACE}
  kubectl rollout history deployment/${DEPLOYMENT} -n ${NAMESPACE} --revision=<N>

Cuando termines, corré este mismo script con el argumento "cleanup"
para borrar todo lo que se creó:
  ./3.1-break-fix.sh cleanup

EOF

exit 0

# =================================================================
# SOLUCIÓN PASO A PASO (no se ejecuta; queda como comentario de
# referencia para el docente o para destrabar al estudiante)
# =================================================================
#
# 1. Confirmar el síntoma y la causa raíz:
#      kubectl get pods -n cka-3-1-lab
#      kubectl describe pod <pod-con-ImagePullBackOff> -n cka-3-1-lab
#    En los Events vas a ver algo como "Failed to pull image ...
#    not found" apuntando a la imagen nginx:1.25-does-not-exist.
#
# 2. Revisar el historial de revisions del Deployment:
#      kubectl rollout history deployment/web -n cka-3-1-lab
#    Vas a ver al menos 2 revisions: la 1 (imagen buena, nginx:1.25)
#    y la 2 (imagen rota, la que quedó a mitad de camino).
#
# 3. Opción A (rollback, la más directa): volver a la revision
#    anterior conocida como buena.
#      kubectl rollout undo deployment/web -n cka-3-1-lab
#    Esto vuelve a la revision 1 (nginx:1.25).
#
#    Opción B (equivalente, corrigiendo hacia adelante en vez de
#    volver atrás): fijar explícitamente la imagen correcta con un
#    nuevo rolling update.
#      kubectl set image deployment/web web=nginx:1.25 -n cka-3-1-lab
#
# 4. Esperar a que el rollout converja:
#      kubectl rollout status deployment/web -n cka-3-1-lab
#    Debe terminar con "successfully rolled out", sin quedarse colgado.
#
# 5. Verificar el estado final:
#      kubectl get deployment web -n cka-3-1-lab
#      kubectl get pods -n cka-3-1-lab -o wide
#    READY/UP-TO-DATE/AVAILABLE deben coincidir con las 4 réplicas
#    deseadas, y todos los pods deben estar Running con RESTARTS
#    estable.
#
# 6. (Opcional) Confirmar que la revision activa es la correcta:
#      kubectl rollout history deployment/web -n cka-3-1-lab --revision=<N>
#
# 7. Limpiar el laboratorio:
#      kubectl delete namespace cka-3-1-lab
#      # o directamente: ./3.1-break-fix.sh cleanup