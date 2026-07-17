#!/usr/bin/env bash
#
# =============================================================================
# BREAK & FIX — CKAD 2.2: Understand Deployments and how to perform
#                          rolling updates
# =============================================================================
# Certificación : CKAD (examen v1.35) — peso del tema en el examen: 5
#
# Qué hace este script:
#   1. Crea un namespace de laboratorio y un Deployment sano (nginx, 3 réplicas)
#      con una estrategia RollingUpdate estricta (maxUnavailable: 0).
#   2. Rompe el Deployment de forma controlada: dispara un rolling update
#      hacia una imagen que NO existe.
#   3. Te explica el síntoma que vas a ver y qué tenés que lograr para
#      considerarlo arreglado.
#
# Seguridad: todo ocurre dentro del namespace "ckad-2-2-breakfix" en tu VM
# de laboratorio descartable. Para limpiar todo:
#   kubectl delete namespace ckad-2-2-breakfix
#
# Fuentes de referencia (consultadas como guía, contenido original):
#   - CKAD Curriculum v1.35:
#     https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#   - Deployments (conceptos, rolling updates, rollback):
#     https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
#   - kubectl rollout:
#     https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/
# =============================================================================

set -euo pipefail

NS="ckad-2-2-breakfix"
DEPLOY="web"
GOOD_IMAGE="nginx:1.27-alpine"
BAD_IMAGE="nginx:9.99-noexiste"

# --- Chequeos previos --------------------------------------------------------

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: no se encontró 'kubectl' en el PATH. Instalalo antes de seguir." >&2
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: no hay conexión con el cluster. Revisá tu kubeconfig / que el cluster esté levantado." >&2
  exit 1
fi

echo ">>> Preparando el laboratorio (namespace: ${NS})..."

# Si quedó un intento anterior, lo limpiamos para arrancar de cero.
kubectl delete namespace "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl create namespace "${NS}" >/dev/null

# --- Estado inicial sano ------------------------------------------------------
# Deployment con:
#   - 3 réplicas
#   - strategy RollingUpdate con maxUnavailable: 0 y maxSurge: 1
#     (nunca baja un Pod viejo hasta que el nuevo esté Ready)
#   - progressDeadlineSeconds: 60 para que el rollout "colgado" se marque
#     como fallido en las conditions del Deployment.

kubectl apply -n "${NS}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  labels:
    app: ${DEPLOY}
spec:
  replicas: 3
  progressDeadlineSeconds: 60
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: ${DEPLOY}
  template:
    metadata:
      labels:
        app: ${DEPLOY}
    spec:
      containers:
      - name: web
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

kubectl -n "${NS}" annotate deployment "${DEPLOY}" \
  kubernetes.io/change-cause="version inicial: ${GOOD_IMAGE}" --overwrite >/dev/null

echo ">>> Esperando a que el Deployment inicial quede sano (3/3 Ready)..."
kubectl -n "${NS}" rollout status deployment/"${DEPLOY}" --timeout=180s

echo ">>> Estado sano confirmado. Guardado como revision 1 en el rollout history."
echo ""

# --- LA ROTURA ----------------------------------------------------------------
# Disparamos un rolling update hacia una imagen que no existe en el registry.

echo ">>> Rompiendo el Deployment: rolling update hacia una imagen inexistente..."
kubectl -n "${NS}" set image deployment/"${DEPLOY}" web="${BAD_IMAGE}" >/dev/null
kubectl -n "${NS}" annotate deployment "${DEPLOY}" \
  kubernetes.io/change-cause="update roto: ${BAD_IMAGE}" --overwrite >/dev/null

# Le damos unos segundos al controller para que cree el Pod nuevo fallido.
sleep 8

# --- Briefing para el estudiante -----------------------------------------------

cat <<BRIEF

=============================================================================
 ESCENARIO ROTO — LEÉ ESTO ANTES DE TOCAR NADA
=============================================================================

Contexto:
  El equipo hizo un "deploy a producción" del Deployment '${DEPLOY}' en el
  namespace '${NS}'... y el rollout nunca termina.

Síntomas que vas a ver:

  1) kubectl -n ${NS} rollout status deployment/${DEPLOY}
     → se queda colgado en "1 out of 3 new replicas have been updated..."
       y después de ~60s falla con "exceeded its progress deadline".

  2) kubectl -n ${NS} get pods
     → hay 4 Pods: 3 viejos Running y 1 nuevo en ErrImagePull /
       ImagePullBackOff que nunca pasa a Ready.

  3) kubectl -n ${NS} get deployment ${DEPLOY}
     → READY dice 3/3 (¡ojo!), pero UP-TO-DATE dice 1. El servicio sigue
       vivo porque maxUnavailable: 0 impidió bajar los Pods viejos, pero el
       rolling update está atascado. Este detalle (READY 3/3 con rollout
       roto) es un clásico del examen.

Tu misión (criterios de éxito):

  a) Diagnosticar POR QUÉ el rollout está atascado usando los comandos de
     rollout y la inspección de Pods (no vale mirar este script).
  b) Dejar el Deployment sano: 3/3 Ready, todos los Pods con una imagen
     válida, y 'kubectl rollout status' terminando exitosamente.
  c) Poder explicar qué revision quedó activa y por qué
     (pista: kubectl rollout history).

Reglas:
  - NO borres el namespace ni el Deployment: en el examen real arreglás el
    recurso existente, no lo recreás.
  - Todo lo que necesitás es kubectl.

Cuando termines, verificá con:
  kubectl -n ${NS} rollout status deployment/${DEPLOY} --timeout=60s
  kubectl -n ${NS} get deployment ${DEPLOY}

=============================================================================
BRIEF

exit 0

# =============================================================================
# SOLUCIÓN PASO A PASO (no leer hasta haberlo intentado)
# =============================================================================
#
# Paso 1 — Confirmar que el rollout está atascado:
#
#   kubectl -n ckad-2-2-breakfix rollout status deployment/web --timeout=30s
#
#   Salida esperada: "Waiting for deployment 'web' rollout to finish:
#   1 out of 3 new replicas have been updated..." y luego error de
#   "progress deadline exceeded". También se ve en las conditions:
#
#   kubectl -n ckad-2-2-breakfix get deployment web \
#     -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}'
#   → ProgressDeadlineExceeded
#
# Paso 2 — Encontrar el Pod problemático:
#
#   kubectl -n ckad-2-2-breakfix get pods
#   → un Pod del ReplicaSet nuevo en ErrImagePull / ImagePullBackOff.
#
# Paso 3 — Ver la causa raíz en los events del Pod:
#
#   kubectl -n ckad-2-2-breakfix describe pod <nombre-del-pod-roto>
#   → en Events: 'Failed to pull image "nginx:9.99-noexiste" ... not found'.
#   La imagen del update no existe en el registry.
#
# Paso 4 — Revisar el historial de revisiones:
#
#   kubectl -n ckad-2-2-breakfix rollout history deployment/web
#   → revision 1: "version inicial: nginx:1.27-alpine"
#     revision 2: "update roto: nginx:9.99-noexiste"
#
#   Se puede inspeccionar una revision puntual:
#   kubectl -n ckad-2-2-breakfix rollout history deployment/web --revision=1
#
# Paso 5 — Arreglar. Hay dos caminos válidos:
#
#   Opción A (rollback, la más rápida en el examen):
#     kubectl -n ckad-2-2-breakfix rollout undo deployment/web
#     (vuelve a la revision anterior; con --to-revision=1 elegís una puntual)
#
#   Opción B (roll-forward con una imagen correcta):
#     kubectl -n ckad-2-2-breakfix set image deployment/web web=nginx:1.27-alpine
#
#   Nota: tras el undo, la config vieja se re-guarda como una revision NUEVA
#   (revision 3); la numeración nunca retrocede.
#
# Paso 6 — Verificar que quedó sano:
#
#   kubectl -n ckad-2-2-breakfix rollout status deployment/web --timeout=60s
#   → "deployment \"web\" successfully rolled out"
#
#   kubectl -n ckad-2-2-breakfix get deployment web
#   → READY 3/3, UP-TO-DATE 3, AVAILABLE 3
#
#   kubectl -n ckad-2-2-breakfix get pods
#   → 3 Pods Running/Ready, el Pod en ImagePullBackOff desapareció.
#
# Lección clave del tema 2.2:
#   - maxUnavailable: 0 protege la disponibilidad durante un rolling update:
#     lo peor que pasa con una imagen rota es un rollout atascado, nunca una
#     caída del servicio.
#   - READY 3/3 en 'kubectl get deployment' NO significa que el rollout haya
#     terminado: mirá UP-TO-DATE y 'kubectl rollout status'.
#   - 'kubectl rollout undo' es la herramienta de recuperación inmediata, y
#     'progressDeadlineSeconds' es lo que convierte un rollout colgado en un
#     fallo detectable (condition ProgressDeadlineExceeded).
#
# Limpieza final del laboratorio:
#   kubectl delete namespace ckad-2-2-breakfix
# =============================================================================