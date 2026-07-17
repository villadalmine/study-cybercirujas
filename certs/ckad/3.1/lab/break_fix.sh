#!/usr/bin/env bash
# =====================================================================
# CKAD (v1.35) — Tema 3.1: Implement probes and health checks
# Ejercicio "break & fix" — laboratorio descartable
#
# Este script rompe algo DE FORMA CONTROLADA en tu cluster de laboratorio
# (minikube, kind o similar). NO lo ejecutes en un cluster real.
#
# Uso:
#   ./breakfix-probes.sh            -> despliega el escenario roto
#   ./breakfix-probes.sh verificar  -> comprueba si lo arreglaste
#   ./breakfix-probes.sh limpiar    -> borra el laboratorio completo
#
# Fuentes de referencia (contenido original, consultadas como guía):
#   - CKAD Curriculum v1.35:
#     https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#   - Configure Liveness, Readiness and Startup Probes:
#     https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
#   - Pod Lifecycle:
#     https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
# =====================================================================

set -euo pipefail

NS="lab-probes"

requisitos() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: kubectl no está instalado o no está en el PATH." >&2
    exit 1
  }
  kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: no hay un cluster accesible. Levantá minikube o kind primero." >&2
    exit 1
  }
}

romper() {
  requisitos
  echo ">>> Creando el namespace '$NS' y desplegando el escenario roto..."

  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

  # --- Escenario 1: livenessProbe rota (puerto equivocado) ---
  kubectl apply -n "$NS" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  labels:
    app: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: nginx:1.27
        ports:
        - containerPort: 80
        livenessProbe:
          httpGet:
            path: /
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 2
EOF

  # --- Escenario 2: readinessProbe rota (path inexistente) ---
  kubectl apply -n "$NS" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx:1.27
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /healthz
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF

  cat <<'TXT'

=====================================================================
 ESCENARIO LISTO. Hay DOS problemas en el namespace 'lab-probes'.
=====================================================================

 SÍNTOMA 1 — Deployment 'api':
   Esperá 1-2 minutos y mirá:
       kubectl get pods -n lab-probes -w
   Vas a ver la columna RESTARTS subiendo sin parar y el pod
   alternando entre Running y CrashLoopBackOff. El container
   funciona bien, pero "algo" lo está matando una y otra vez.

 SÍNTOMA 2 — Deployment 'web':
   El pod queda Running pero NUNCA pasa a READY 1/1:
       kubectl get pods -n lab-probes -l app=web
   Y el Service 'web' no tiene endpoints, así que ningún tráfico
   llega a la aplicación:
       kubectl get endpoints web -n lab-probes

 TU OBJETIVO:
   1. Diagnosticar POR QUÉ pasa cada cosa usando:
        kubectl describe pod <pod> -n lab-probes
      (prestá atención a la sección Events: ahí el kubelet cuenta
       exactamente qué probe falla y por qué).
   2. Corregir la configuración de las probes SIN eliminarlas
      (borrar las probes no es arreglar: en el examen CKAD te piden
       implementarlas bien, no sacarlas).
   3. Al final debés lograr:
        - 'api': READY 1/1 y RESTARTS estable (sin nuevos reinicios).
        - 'web': READY 1/1 y el Service 'web' con endpoints.

 Cuando creas que está resuelto, ejecutá:
       ./breakfix-probes.sh verificar
=====================================================================
TXT
}

verificar() {
  requisitos
  local ok=1

  echo ">>> Verificando el estado del laboratorio..."

  local api_ready web_ready endpoints api_liveness web_readiness
  api_ready=$(kubectl -n "$NS" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  web_ready=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  endpoints=$(kubectl -n "$NS" get endpoints web -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  api_liveness=$(kubectl -n "$NS" get deploy api -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' 2>/dev/null || true)
  web_readiness=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null || true)

  if [ -z "$api_liveness" ]; then
    echo "[FALLO] 'api' ya no tiene livenessProbe. Borrarla no es la solución: configurala bien."
    ok=0
  elif [ "${api_ready:-0}" = "1" ]; then
    echo "[OK] 'api' está READY y su livenessProbe sigue presente."
  else
    echo "[FALLO] 'api' todavía no está READY. Mirá los Events con 'kubectl describe pod'."
    ok=0
  fi

  if [ -z "$web_readiness" ]; then
    echo "[FALLO] 'web' ya no tiene readinessProbe. Borrarla no es la solución: configurala bien."
    ok=0
  elif [ "${web_ready:-0}" = "1" ] && [ -n "$endpoints" ]; then
    echo "[OK] 'web' está READY y el Service tiene endpoints: $endpoints"
  else
    echo "[FALLO] 'web' no está READY o el Service sigue sin endpoints."
    ok=0
  fi

  if [ "$ok" = "1" ]; then
    echo ""
    echo "¡Laboratorio resuelto! Ambas probes funcionan y el tráfico fluye."
    echo "Podés limpiar con: ./breakfix-probes.sh limpiar"
  else
    echo ""
    echo "Todavía falta. Pistas: 'kubectl describe pod' (sección Events),"
    echo "'kubectl get endpoints -n $NS' y compará el puerto/path de cada"
    echo "probe con lo que el container realmente expone."
    exit 1
  fi
}

limpiar() {
  requisitos
  echo ">>> Eliminando el namespace '$NS'..."
  kubectl delete namespace "$NS" --ignore-not-found
  echo "Laboratorio eliminado."
}

case "${1:-romper}" in
  romper)    romper ;;
  verificar) verificar ;;
  limpiar)   limpiar ;;
  *)
    echo "Uso: $0 [romper|verificar|limpiar]" >&2
    exit 1
    ;;
esac

exit 0

# =====================================================================
# SOLUCIÓN PASO A PASO (no leas esto hasta intentarlo)
# =====================================================================
#
# --- Diagnóstico ---
#
# 1. Mirá el estado general:
#      kubectl get pods -n lab-probes
#    'api' acumula RESTARTS; 'web' queda Running pero 0/1 READY.
#
# 2. Investigá 'api':
#      kubectl describe pod -n lab-probes -l app=api
#    En Events vas a ver algo como:
#      "Liveness probe failed: Get http://...:8081/ ... connection refused"
#      "Container api failed liveness probe, will be restarted"
#    Conclusión: la livenessProbe apunta al puerto 8081, pero nginx
#    escucha en el 80. El kubelet cree que el container está muerto
#    y lo reinicia en loop. Regla de oro: una livenessProbe mal
#    configurada es PEOR que no tener ninguna.
#
# 3. Investigá 'web':
#      kubectl describe pod -n lab-probes -l app=web
#    En Events:
#      "Readiness probe failed: HTTP probe failed with statuscode: 404"
#    Conclusión: la readinessProbe pide GET /healthz y nginx no tiene
#    esa ruta (devuelve 404). El pod nunca pasa a Ready, y un pod
#    not-Ready se saca de los endpoints del Service: por eso no llega
#    tráfico. Notá la diferencia clave del examen: liveness que falla
#    REINICIA el container; readiness que falla lo SACA del Service
#    sin reiniciarlo.
#
# --- Arreglo ---
#
# Opción A (recomendada en el examen por velocidad): kubectl edit
#
#   kubectl edit deploy api -n lab-probes
#     -> en livenessProbe.httpGet cambiá "port: 8081" por "port: 80"
#
#   kubectl edit deploy web -n lab-probes
#     -> en readinessProbe.httpGet cambiá "path: /healthz" por "path: /"
#
# Opción B (equivalente, sin editor): kubectl patch
#
#   kubectl -n lab-probes patch deploy api --type=json \
#     -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/port","value":80}]'
#
#   kubectl -n lab-probes patch deploy web --type=json \
#     -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
#
# Al editar el template, el Deployment hace rollout de pods nuevos.
#
# --- Verificación ---
#
#   kubectl rollout status deploy/api -n lab-probes
#   kubectl rollout status deploy/web -n lab-probes
#   kubectl get pods -n lab-probes          # ambos 1/1 READY, sin nuevos restarts
#   kubectl get endpoints web -n lab-probes # ahora aparece una IP
#   ./breakfix-probes.sh verificar          # debe dar todo [OK]
#
# --- Para llevarte del ejercicio ---
#
#   * livenessProbe: "¿está vivo?" -> si falla, kubelet REINICIA el container.
#   * readinessProbe: "¿puede recibir tráfico?" -> si falla, el pod se
#     excluye de los endpoints del Service (no se reinicia).
#   * startupProbe (no usada acá): protege apps de arranque lento;
#     mientras corre, deshabilita liveness y readiness.
#   * Ante síntomas raros, siempre: kubectl describe pod + sección Events.
# =====================================================================