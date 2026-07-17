#!/usr/bin/env bash
#
# KCNA - Dominio: Cloud Native Observability
# Tema 2.3: Observability (peso en el examen: 5.4%)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# Laboratorio "break & fix": desplega un Deployment con un liveness probe
# mal configurado (apunta a un puerto que el contenedor no escucha) y
# genera un CrashLoopBackOff real. El estudiante debe diagnosticar la
# causa raíz usando SOLO herramientas de observability nativas de
# Kubernetes (kubectl get/describe/logs/events/rollout), sin tocar la
# imagen del contenedor, y corregir el manifiesto.
#
# USO:
#   ./break-fix-observability.sh break     -> rompe el laboratorio
#   ./break-fix-observability.sh hint      -> muestra pistas adicionales
#   ./break-fix-observability.sh verify    -> valida si ya lo arreglaste
#   ./break-fix-observability.sh cleanup   -> borra todo lo creado
#
# ADVERTENCIA: este script está pensado para correr contra un cluster de
# laboratorio DESCARTABLE (kind, minikube, k3d, etc.), nunca contra un
# cluster productivo. Incluye un guard de seguridad, pero la
# responsabilidad final de dónde se ejecuta es tuya.

set -euo pipefail

NAMESPACE="kcna-obs-lab"
DEPLOY_NAME="webshop-frontend"

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl no está instalado o no está en el PATH." >&2
    exit 1
  fi
}

guard_not_production() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  echo "Contexto actual de kubectl: ${ctx}"
  case "${ctx}" in
    *prod*|*production*)
      echo "ERROR: el contexto '${ctx}' parece productivo. Abortando por seguridad." >&2
      echo "Este laboratorio está pensado para clusters descartables (kind/minikube/k3d)." >&2
      exit 1
      ;;
  esac
  read -r -p "¿Confirmás que este es un cluster de laboratorio descartable? [y/N] " confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "Cancelado por el usuario."
    exit 1
  fi
}

do_break() {
  require_kubectl
  guard_not_production

  echo "==> Creando namespace ${NAMESPACE}..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  echo "==> Desplegando app con un health check mal configurado..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${DEPLOY_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOY_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 1
EOF

  cat <<'MSG'

============================================================
 SINTOMA
============================================================
En menos de un minuto vas a ver que el pod entra en
CrashLoopBackOff, con el contador de RESTARTS subiendo sin
parar:

  kubectl get pods -n kcna-obs-lab -w

Nginx arranca perfectamente bien (podés confirmarlo mirando
los logs), pero algo lo está matando una y otra vez.

============================================================
 TU MISION
============================================================
Usando SOLO herramientas de observability de Kubernetes (no
edites la imagen del contenedor ni el código de la app),
encontrá la causa raíz y corregí el manifiesto para que el
Deployment quede estable:

  READY      1/1
  RESTARTS   deja de crecer
  kubectl rollout status deployment/webshop-frontend -n kcna-obs-lab
    -> "successfully rolled out"

Herramientas que probablemente necesites:
  kubectl get pods -n kcna-obs-lab
  kubectl describe pod <pod> -n kcna-obs-lab
  kubectl logs <pod> -n kcna-obs-lab
  kubectl logs <pod> -n kcna-obs-lab --previous
  kubectl get events -n kcna-obs-lab --sort-by=.lastTimestamp

Cuando creas que lo resolviste, corré:
  ./break-fix-observability.sh verify

MSG
}

do_hint() {
  cat <<'MSG'
PISTA 1: "kubectl describe pod" tiene una sección de Events al
final. Ahí vas a ver cuál probe está fallando y por qué (leé el
mensaje de error completo, no solo el nombre del evento).

PISTA 2: comparalo con el "port" que declara el container
(containerPort) contra el "port" que usa cada probe por
separado. ¿El liveness y el readiness apuntan al mismo puerto?

PISTA 3: los logs de la aplicación (kubectl logs) se ven
normales, sin errores. Esa es una pista en sí misma: si la app
arranca bien pero el kubelet la mata igual, el problema está en
cómo Kubernetes observa la salud del contenedor (el health
check), no en la app.
MSG
}

do_verify() {
  require_kubectl
  echo "==> Verificando el rollout de deployment/${DEPLOY_NAME} en ${NAMESPACE}..."
  if ! kubectl get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "No encuentro el deployment. ¿Corriste 'break' y no lo borraste con 'cleanup'?"
    exit 1
  fi

  if kubectl rollout status "deployment/${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=60s; then
    ready="$(kubectl get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}')"
    echo "Deployment estable. readyReplicas=${ready:-0}"
    echo "Resuelto: el pod ya no reinicia por el liveness probe."
  else
    echo "Todavía no está estable."
    echo "Revisá: kubectl describe pod -l app=${DEPLOY_NAME} -n ${NAMESPACE}"
    exit 1
  fi
}

do_cleanup() {
  require_kubectl
  echo "==> Borrando namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
}

usage() {
  echo "Uso: $0 {break|hint|verify|cleanup}"
  exit 1
}

case "${1:-}" in
  break)   do_break ;;
  hint)    do_hint ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *)       usage ;;
esac

# ============================================================
# SOLUCION PASO A PASO (no leer antes de intentarlo)
# ============================================================
#
# 1. kubectl get pods -n kcna-obs-lab
#    Se ve STATUS CrashLoopBackOff y RESTARTS creciendo sin parar.
#
# 2. kubectl describe pod -l app=webshop-frontend -n kcna-obs-lab
#    En la sección Events aparece algo como:
#      Warning  Unhealthy  ...  Liveness probe failed: Get
#      "http://<pod-ip>:8080/": dial tcp <pod-ip>:8080:
#      connect: connection refused
#      Normal   Killing    ...  Container nginx failed liveness probe,
#      will be restarted
#
# 3. kubectl logs -l app=webshop-frontend -n kcna-obs-lab
#    (y con --previous) muestran que nginx arrancó bien y sirvió
#    tráfico normal: el problema NO está en la aplicación.
#
# 4. Root cause: el livenessProbe apunta al puerto 8080, pero nginx
#    solo escucha en el puerto 80 (el mismo que declara containerPort
#    y que usa el readinessProbe, que sí funciona). Con
#    failureThreshold=1, la primera vez que el kubelet intenta el
#    chequeo de liveness y se encuentra con "connection refused",
#    mata el contenedor de inmediato -> CrashLoopBackOff.
#
# 5. Fix: corregir el puerto del livenessProbe para que coincida con
#    el puerto real de la aplicación (80). Como es un Deployment,
#    alcanza con reaplicar el manifiesto corregido o editarlo
#    directamente:
#
#      kubectl edit deployment webshop-frontend -n kcna-obs-lab
#      # cambiar spec.template.spec.containers[0].livenessProbe.httpGet.port
#      # de 8080 a 80
#
#    o bien, reaplicando el YAML con el valor corregido:
#
#      kubectl apply -f deployment-corregido.yaml
#
#    Cualquiera de las dos opciones dispara un nuevo rollout: el
#    ReplicaSet viejo (con el pod en crashloop) se reemplaza por uno
#    nuevo con el probe corregido.
#
# 6. Confirmar con:
#      kubectl rollout status deployment/webshop-frontend -n kcna-obs-lab
#      kubectl get pods -n kcna-obs-lab -w
#    y verificar que RESTARTS deja de crecer y el pod queda
#    READY 1/1, STATUS Running.
#
# ============================================================