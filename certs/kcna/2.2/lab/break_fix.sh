#!/usr/bin/env bash
#
# KCNA 2.2 - Debugging (peso examen: 5.3%)
# Break & Fix: Pod que entra en CrashLoopBackOff por un liveness probe mal configurado
#
# Fuente de referencia (solo consulta, contenido original):
#   https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# ADVERTENCIA: este script modifica un cluster de Kubernetes. Ejecutalo
# UNICAMENTE contra una VM/cluster de laboratorio descartable (kind, minikube,
# k3d, etc.), nunca contra un cluster compartido o productivo. Todos los
# recursos se crean dentro de un namespace dedicado para poder destruirlos
# limpiamente con la opcion "cleanup".

set -euo pipefail

NAMESPACE="kcna-lab-debug"
DEPLOYMENT="webapp"

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: no se encontro kubectl en el PATH." >&2
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl no puede contactar a ningun cluster. Configura el kubeconfig de tu VM de laboratorio." >&2
    exit 1
  fi
}

confirm_lab_cluster() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  echo "Contexto actual de kubectl: ${ctx}"
  read -r -p "Confirmas que este es un cluster de LABORATORIO DESCARTABLE (no productivo)? [escribi 'si' para continuar]: " ans
  if [[ "${ans}" != "si" ]]; then
    echo "Cancelado. No se realizo ningun cambio."
    exit 1
  fi
}

break_it() {
  require_kubectl
  confirm_lab_cluster

  echo "Creando namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  echo "Desplegando '${DEPLOYMENT}' con un liveness probe mal configurado (puerto incorrecto)..."
  cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT}
  labels:
    app: ${DEPLOYMENT}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOYMENT}
  template:
    metadata:
      labels:
        app: ${DEPLOYMENT}
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          livenessProbe:
            httpGet:
              path: /
              port: 9999
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 1
EOF

  cat <<'MSG'

============================================================
 ESCENARIO ROTO - KCNA 2.2 Debugging
============================================================
Se desplego el Deployment 'webapp' en el namespace 'kcna-lab-debug'.

SINTOMA que vas a observar (dale unos 30-60 segundos):

  kubectl get pods -n kcna-lab-debug

El pod va a quedar en estado CrashLoopBackOff, con el contador de
RESTARTS subiendo constantemente. A primera vista parece que el
contenedor se cae solo, pero el proceso de nginx dentro del
contenedor arranca perfectamente bien.

TU OBJETIVO:
  1. Usar las herramientas de debugging de kubectl (no adivinar)
     para encontrar la causa real: kubectl get pods, kubectl describe
     pod, kubectl logs, kubectl get events.
  2. Identificar por que kubelet esta matando y reiniciando el
     contenedor a pesar de que la aplicacion esta sana.
  3. Corregir el recurso (kubectl edit / kubectl apply) para que el
     pod quede en estado Running con READY 1/1 y sin reinicios
     adicionales durante al menos 60 segundos.

Pista de herramientas a usar (sin revelar la causa):
  - kubectl get pods -n kcna-lab-debug -w
  - kubectl describe pod -n kcna-lab-debug -l app=webapp
  - kubectl logs -n kcna-lab-debug -l app=webapp --previous
  - kubectl get events -n kcna-lab-debug --sort-by=.metadata.creationTimestamp

Cuando creas que lo arreglaste, corre:
  ./este-script.sh verify

Para destruir todo el escenario de laboratorio:
  ./este-script.sh cleanup
============================================================
MSG
}

verify_fix() {
  require_kubectl
  echo "Verificando estado del Deployment '${DEPLOYMENT}' en '${NAMESPACE}'..."

  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "El namespace '${NAMESPACE}' no existe. Corre primero: ./este-script.sh break"
    exit 1
  fi

  local ready restarts
  ready="$(kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOYMENT}" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")"
  restarts="$(kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOYMENT}" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")"

  echo "READY actual: ${ready} | RESTARTS: ${restarts}"

  if [[ "${ready}" == "true" ]]; then
    echo "El pod esta Ready. Esperando 60s para confirmar estabilidad (sin nuevos restarts)..."
    local restarts_before="${restarts}"
    sleep 60
    local restarts_after
    restarts_after="$(kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOYMENT}" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")"
    if [[ "${restarts_after}" == "${restarts_before}" ]]; then
      echo "CORRECTO: el pod se mantuvo estable, sin restarts nuevos. Ejercicio resuelto."
    else
      echo "TODAVIA ROTO: el contador de restarts siguio subiendo (${restarts_before} -> ${restarts_after})."
    fi
  else
    echo "TODAVIA ROTO: el pod no esta Ready. Seguí investigando con describe/logs/events."
  fi
}

cleanup() {
  require_kubectl
  echo "Eliminando namespace '${NAMESPACE}' y todos sus recursos..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
  echo "Listo."
}

usage() {
  cat <<'USAGE'
Uso: ./este-script.sh [break|verify|cleanup]

  break    - Rompe el escenario (crea el Deployment con el bug)
  verify   - Verifica si el estudiante ya lo arreglo
  cleanup  - Borra el namespace de laboratorio completo
USAGE
}

case "${1:-}" in
  break) break_it ;;
  verify) verify_fix ;;
  cleanup) cleanup ;;
  *) usage ;;
esac

# ============================================================
# SOLUCION PASO A PASO (para el instructor / autocorreccion)
# ============================================================
#
# 1. Observar el sintoma:
#      kubectl get pods -n kcna-lab-debug
#    -> STATUS: CrashLoopBackOff, RESTARTS subiendo.
#
# 2. Descartar que sea un problema de la aplicacion en si:
#      kubectl logs -n kcna-lab-debug -l app=webapp --previous
#    -> Los logs muestran a nginx arrancando sin errores. Esto es
#       la pista clave: si el proceso arranca bien, el problema no
#       esta en el codigo de la app sino en como Kubernetes decide
#       si el pod esta "sano".
#
# 3. Revisar los eventos del pod, que es donde kubelet reporta
#    fallas de probes:
#      kubectl describe pod -n kcna-lab-debug -l app=webapp
#    o
#      kubectl get events -n kcna-lab-debug --sort-by=.metadata.creationTimestamp
#    -> Se ven eventos tipo:
#       "Liveness probe failed: Get http://<pod-ip>:9999/: dial tcp
#        <pod-ip>:9999: connect: connection refused"
#       "Killing container with id ...: Container failed liveness probe,
#        will be restarted"
#
# 4. Diagnostico: el livenessProbe apunta al puerto 9999, pero nginx
#    escucha en el puerto 80 (containerPort: 80). kubelet nunca logra
#    conectarse, marca el probe como fallido, mata el contenedor y lo
#    reinicia en loop -> CrashLoopBackOff, aunque la app nunca estuvo
#    rota.
#
# 5. Corregir el recurso, alineando el puerto del probe con el puerto
#    real del contenedor:
#      kubectl edit deployment webapp -n kcna-lab-debug
#    y cambiar:
#      livenessProbe.httpGet.port: 9999   ->   80
#    (alternativa equivalente: aplicar de nuevo el manifiesto con el
#    puerto corregido via kubectl apply -f).
#
# 6. Confirmar la correccion:
#      kubectl rollout status deployment/webapp -n kcna-lab-debug
#      kubectl get pods -n kcna-lab-debug -w
#    -> READY 1/1, STATUS Running, RESTARTS deja de aumentar.
#
# 7. Limpieza del laboratorio:
#      kubectl delete namespace kcna-lab-debug
# ============================================================