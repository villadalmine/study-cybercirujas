#!/usr/bin/env bash
# break-fix: CKA 1.35 - Tema 2.4 "Manage and evaluate container output streams" (peso 6)
# Fuente de referencia del temario: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Este script ROMPE algo a propósito dentro de un namespace descartable.
# Ejecutalo únicamente en una VM de laboratorio / cluster de práctica (kind, minikube, k3d, etc.),
# nunca contra un cluster productivo.
#
# Cleanup manual cuando termines: kubectl delete ns cka-2-4-lab

set -euo pipefail

NS="cka-2-4-lab"
POD="billing-worker"

# --- guardas de seguridad: no correr esto en cualquier contexto ---
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ABORTADO: no se encontró kubectl en el PATH." >&2
  exit 1
fi

CTX="$(kubectl config current-context 2>/dev/null)" || CTX=""

case "$CTX" in
  *kind*|*minikube*|*k3d*|*k3s*|*lab*|*test*|*sandbox*)
    ;;
  *)
    if [ "${I_UNDERSTAND_THIS_IS_DISPOSABLE:-}" != "yes" ]; then
      echo "ABORTADO: el contexto actual de kubectl es '${CTX}'." >&2
      echo "Este script rompe cosas a propósito y no está pensado para clusters reales." >&2
      echo "Si estás 100% seguro de que este cluster es descartable, volvé a correr con:" >&2
      echo "  I_UNDERSTAND_THIS_IS_DISPOSABLE=yes $0" >&2
      exit 1
    fi
    ;;
esac

echo "Usando contexto: ${CTX}"
echo "Preparando namespace '${NS}' (se recrea desde cero)..."

kubectl delete namespace "$NS" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl create namespace "$NS" >/dev/null

# --- BREAK: Pod con dos containers, cada uno rompe algo distinto sobre output streams ---
# worker: en su primer arranque loguea unas líneas normales a stdout y después
#         "crashea" con un error fatal por stderr y exit 1 (kubelet lo reinicia).
#         A partir del segundo arranque queda estable y solo loguea heartbeats "ok".
# metrics-sidecar: nunca escribe nada a stdout/stderr; loguea todo a un archivo
#         dentro del container (patrón clásico de app "mal ciudadana" para logging).
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: billing-worker
  namespace: cka-2-4-lab
  labels:
    app: billing-worker
spec:
  restartPolicy: Always
  volumes:
    - name: lab-state
      emptyDir: {}
    - name: metrics-log
      emptyDir: {}
  containers:
    - name: worker
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          STATE=/var/lib/lab-state/attempts
          N=$(cat "$STATE" 2>/dev/null || echo 0)
          N=$((N+1))
          echo "$N" > "$STATE"
          echo "starting billing-worker (attempt $N)"
          if [ "$N" -eq 1 ]; then
            i=0
            while [ "$i" -lt 4 ]; do
              echo "heartbeat: processing batch $i"
              sleep 2
              i=$((i+1))
            done
            echo "FATAL: connection pool exhausted, restarting" >&2
            exit 1
          else
            while true; do
              echo "heartbeat: processing batch ok"
              sleep 2
            done
          fi
      volumeMounts:
        - name: lab-state
          mountPath: /var/lib/lab-state
    - name: metrics-sidecar
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          mkdir -p /var/log/metrics
          i=0
          while true; do
            echo "$(date 2>/dev/null) metrics-sidecar heartbeat $i" >> /var/log/metrics/metrics.log
            i=$((i+1))
            sleep 5
          done
      volumeMounts:
        - name: metrics-log
          mountPath: /var/log/metrics
EOF

echo "Esperando el primer ciclo de crash/restart del container 'worker' (es esperado, no lo interrumpas)..."

ATTEMPTS=0
RESTARTS=""
while [ "$ATTEMPTS" -lt 30 ]; do
  RESTARTS="$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="worker")].restartCount}' 2>/dev/null)" || true
  if [ -z "$RESTARTS" ]; then
    RESTARTS=0
  fi
  if [ "$RESTARTS" -ge 1 ]; then
    break
  fi
  sleep 3
  ATTEMPTS=$((ATTEMPTS+1))
done

cat <<MSG

============================================================
 LAB ROTO - CKA 2.4: Manage and evaluate container output streams
 namespace: ${NS}   pod: ${POD}
============================================================

SÍNTOMAS que vas a observar:

  1) kubectl get pods -n ${NS}
     El pod "${POD}" aparece Running, pero la columna RESTARTS
     ya no está en 0 para el container "worker".

  2) kubectl logs -n ${NS} ${POD} -c worker
     (sin ningún flag extra) se ve "limpio": solo heartbeats
     normales, sin ningún rastro de error.

  3) kubectl logs -n ${NS} ${POD} -c metrics-sidecar
     no devuelve absolutamente nada, aunque el container está
     Running y (podés confirmarlo con exec) claramente sigue vivo.

OBJETIVOS (qué tenés que lograr):

  A) Determinar la causa raíz del restart del container "worker",
     usando exclusivamente evaluación de logs con kubectl (sin exec,
     sin mirar el código de la imagen).

  B) Lograr que "kubectl logs -f -n ${NS} ${POD} -c metrics-sidecar"
     muestre output en vivo, SIN borrar ni recrear el Pod.

Pistas de dónde mirar (repasá su documentación si hace falta):
  kubectl logs --previous
  kubectl logs -c <container>
  kubectl exec -it ... -c <container> -- sh
  /proc/<pid>/fd/*

Cuando termines, para descartar el lab: kubectl delete ns ${NS}
============================================================
MSG

# ============================================================
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# ============================================================
#
# --- Objetivo A: causa raíz del restart de "worker" ---
#
# 1) kubectl get pods -n cka-2-4-lab
#    -> billing-worker  2/2  Running  RESTARTS=1
#    El RESTARTS>0 avisa que hubo un crash aunque el pod hoy esté sano.
#
# 2) kubectl logs -n cka-2-4-lab billing-worker -c worker
#    -> Solo muestra "starting billing-worker (attempt 2)" y heartbeats "ok".
#    Esto corresponde al intento ACTUAL (el segundo), que nunca falló.
#    Por diseño no hay ninguna pista del error acá.
#
# 3) kubectl logs -n cka-2-4-lab billing-worker -c worker --previous
#    -> Muestra el log del intento anterior (el primero):
#       starting billing-worker (attempt 1)
#       heartbeat: processing batch 0..3
#       FATAL: connection pool exhausted, restarting
#    Esa línea FATAL (emitida por stderr) es la causa raíz del restart.
#    Lección: un pod "Running" y con logs limpios puede haber crasheado
#    antes; siempre revisar RESTARTS y --previous.
#
# --- Objetivo B: hacer visible el log de "metrics-sidecar" sin recrear el Pod ---
#
# 4) kubectl logs -n cka-2-4-lab billing-worker -c metrics-sidecar
#    -> vacío. El container runtime solo captura lo que el proceso PID 1
#    del container escribe a stdout/stderr; esta app loguea a un archivo
#    (/var/log/metrics/metrics.log), por eso kubectl logs no ve nada.
#
# 5) Confirmar que el proceso está vivo y logueando a archivo:
#    kubectl exec -n cka-2-4-lab billing-worker -c metrics-sidecar -- \
#      sh -c 'tail -n 5 /var/log/metrics/metrics.log'
#    -> se ven líneas "metrics-sidecar heartbeat N" creciendo.
#
# 6) Fix sin recrear el Pod: lanzar, dentro del MISMO container, un proceso
#    que reenvíe el archivo al file descriptor 1 del PID 1 de ese container
#    (el mismo fd que el container runtime ya está capturando como stdout):
#    kubectl exec -n cka-2-4-lab billing-worker -c metrics-sidecar -- \
#      sh -c 'nohup tail -n 0 -f /var/log/metrics/metrics.log >> /proc/1/fd/1 2>&1 &'
#
# 7) Verificar:
#    kubectl logs -f -n cka-2-4-lab billing-worker -c metrics-sidecar
#    -> ahora deberían aparecer, en vivo, las nuevas líneas de metrics.log.
#
# Nota: esto es un workaround forense útil para diagnosticar en caliente,
# no el fix "de fábrica". En un manifiesto real, la solución correcta es
# corregir la app para loguear a stdout/stderr, o declarar desde el inicio
# un container sidecar de logging (streaming sidecar container) que haga
# "tail -f" del archivo, y aplicar el cambio con kubectl apply/rollout.