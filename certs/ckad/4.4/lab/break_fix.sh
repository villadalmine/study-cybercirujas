#!/usr/bin/env bash
#===============================================================================
# break-fix.sh — CKAD 4.4: Define resource requirements (CKAD v1.35, peso 3)
#
# Laboratorio "break & fix": este script rompe TRES cosas de forma controlada
# y segura en un cluster de laboratorio DESCARTABLE (minikube, kind, k3s...).
# Tu trabajo: diagnosticar cada síntoma con kubectl y arreglarlo.
#
# ATENCION: no lo ejecutes nunca contra un cluster productivo. Todo lo que
# crea vive en los namespaces ckad44-lab y ckad44-quota, y se limpia con:
#   ./break-fix.sh clean
#
# Uso:
#   ./break-fix.sh          -> prepara el escenario roto
#   ./break-fix.sh verify   -> comprueba si ya arreglaste los tres incidentes
#   ./break-fix.sh clean    -> borra los namespaces del laboratorio
#
# Fuentes consultadas como referencia (contenido original, no copiado):
# - Curriculum CKAD v1.35:
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
# - Manage resources for containers:
#   https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
# - Assign memory resources / ejemplo OOM con polinux/stress:
#   https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
# - Resource Quotas:
#   https://kubernetes.io/docs/concepts/policy/resource-quotas/
#===============================================================================
set -euo pipefail

NS_LAB="ckad44-lab"      # incidentes 1 y 2 (scheduling y OOM)
NS_QUOTA="ckad44-quota"  # incidente 3 (ResourceQuota)

#-------------------------------------------------------------------------------
# Comprobaciones previas
#-------------------------------------------------------------------------------
require_cluster() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: no se encontró 'kubectl' en el PATH." >&2
    exit 1
  fi
  if ! kubectl get nodes >/dev/null 2>&1; then
    echo "ERROR: no hay conexión con el cluster (revisá tu kubeconfig)." >&2
    exit 1
  fi
}

#-------------------------------------------------------------------------------
# Limpieza
#-------------------------------------------------------------------------------
clean_lab() {
  echo ">>> Borrando namespaces ${NS_LAB} y ${NS_QUOTA}..."
  kubectl delete namespace "${NS_LAB}" "${NS_QUOTA}" --ignore-not-found --wait=true
  echo ">>> Laboratorio limpio."
}

#-------------------------------------------------------------------------------
# Verificación: la usás cuando creas que ya arreglaste todo
#-------------------------------------------------------------------------------
verify_lab() {
  local fallos=0

  echo "== Verificando los tres incidentes =="

  # Incidente 1: web-frontend debe estar Running (1/1)
  local ready1
  ready1=$(kubectl get deploy web-frontend -n "${NS_LAB}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [[ "${ready1:-0}" -ge 1 ]]; then
    echo "[OK]   Incidente 1: web-frontend está Ready (ya no queda Pending)."
  else
    echo "[FAIL] Incidente 1: web-frontend todavía no tiene replicas Ready."
    fallos=$((fallos + 1))
  fi

  # Incidente 2: cache-worker debe estar Running y SIN reiniciarse por OOM.
  # Medimos el restartCount dos veces con 30s de diferencia.
  local pod2 restarts_a restarts_b
  pod2=$(kubectl get pod -l app=cache-worker -n "${NS_LAB}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${pod2}" ]]; then
    restarts_a=$(kubectl get pod "${pod2}" -n "${NS_LAB}" \
      -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo -1)
    echo "       Incidente 2: observando estabilidad de ${pod2} durante 30s..."
    sleep 30
    restarts_b=$(kubectl get pod "${pod2}" -n "${NS_LAB}" \
      -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo -2)
    local phase2
    phase2=$(kubectl get pod "${pod2}" -n "${NS_LAB}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
    if [[ "${phase2}" == "Running" && "${restarts_a}" == "${restarts_b}" ]]; then
      echo "[OK]   Incidente 2: cache-worker corre estable (sin nuevos OOMKilled)."
    else
      echo "[FAIL] Incidente 2: cache-worker sigue reiniciándose o no está Running."
      fallos=$((fallos + 1))
    fi
  else
    echo "[FAIL] Incidente 2: no encuentro ningún pod con label app=cache-worker."
    fallos=$((fallos + 1))
  fi

  # Incidente 3: api-backend debe llegar a 3/3 sin tocar la ResourceQuota
  local ready3 quota_cpu
  ready3=$(kubectl get deploy api-backend -n "${NS_QUOTA}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  quota_cpu=$(kubectl get resourcequota cuota-equipo -n "${NS_QUOTA}" \
    -o jsonpath='{.spec.hard.requests\.cpu}' 2>/dev/null || echo "")
  if [[ "${quota_cpu}" != "1" ]]; then
    echo "[FAIL] Incidente 3: modificaste la ResourceQuota (la regla era no tocarla)."
    fallos=$((fallos + 1))
  elif [[ "${ready3:-0}" -ge 3 ]]; then
    echo "[OK]   Incidente 3: api-backend está 3/3 y la quota sigue intacta."
  else
    echo "[FAIL] Incidente 3: api-backend tiene ${ready3:-0}/3 replicas Ready."
    fallos=$((fallos + 1))
  fi

  echo ""
  if [[ "${fallos}" -eq 0 ]]; then
    echo "FELICITACIONES: los tres incidentes están resueltos."
    echo "Limpieza final: ./break-fix.sh clean"
  else
    echo "Todavía quedan ${fallos} incidente(s) por resolver. Seguí investigando."
  fi
}

#-------------------------------------------------------------------------------
# Escenario roto
#-------------------------------------------------------------------------------
setup_lab() {
  echo ">>> Preparando el laboratorio (si existía uno anterior, se borra)..."
  kubectl delete namespace "${NS_LAB}" "${NS_QUOTA}" --ignore-not-found --wait=true >/dev/null
  kubectl create namespace "${NS_LAB}" >/dev/null
  kubectl create namespace "${NS_QUOTA}" >/dev/null

  # ---- INCIDENTE 1: requests imposibles de agendar ---------------------------
  # Un "compañero de equipo" pidió una CPU absurda para un nginx.
  kubectl apply -n "${NS_LAB}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  labels:
    app: web-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        resources:
          requests:
            cpu: "128"
            memory: 128Mi
          limits:
            cpu: "128"
            memory: 256Mi
EOF

  # ---- INCIDENTE 2: memory limit menor que lo que consume el proceso ---------
  # El proceso reserva ~150M de RAM, pero el limit es 100Mi: el kernel lo mata.
  kubectl apply -n "${NS_LAB}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache-worker
  labels:
    app: cache-worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cache-worker
  template:
    metadata:
      labels:
        app: cache-worker
    spec:
      containers:
      - name: stress
        image: polinux/stress
        command: ["stress"]
        args: ["--vm", "1", "--vm-bytes", "150M", "--vm-hang", "0"]
        resources:
          requests:
            cpu: 100m
            memory: 50Mi
          limits:
            cpu: 500m
            memory: 100Mi
EOF

  # ---- INCIDENTE 3: ResourceQuota que no alcanza para todas las replicas -----
  # La quota la puso "el equipo de plataforma" y no se puede tocar.
  kubectl apply -n "${NS_QUOTA}" -f - >/dev/null <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: cuota-equipo
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
EOF

  kubectl apply -n "${NS_QUOTA}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-backend
  labels:
    app: api-backend
spec:
  replicas: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: api-backend
  template:
    metadata:
      labels:
        app: api-backend
    spec:
      containers:
      - name: api
        image: nginx:1.27-alpine
        resources:
          requests:
            cpu: 400m
            memory: 256Mi
          limits:
            cpu: 600m
            memory: 512Mi
EOF

  cat <<EOF

===============================================================================
 LABORATORIO LISTO: 3 incidentes de "resource requirements" te esperan
===============================================================================

 INCIDENTE 1 — namespace ${NS_LAB}, deployment web-frontend
   Síntoma que vas a ver: el pod queda en estado Pending para siempre.
   Pista de diagnóstico:
     kubectl get pods -n ${NS_LAB}
     kubectl describe pod -l app=web-frontend -n ${NS_LAB}
   Mirá los Events del describe: el scheduler te dice exactamente qué recurso
   no le alcanza a ningún node.
   OBJETIVO: dejá web-frontend en Running (1/1) con requests razonables.

 INCIDENTE 2 — namespace ${NS_LAB}, deployment cache-worker
   Síntoma que vas a ver: el pod arranca, muere a los pocos segundos y entra
   en CrashLoopBackOff. En el describe: Last State: Terminated,
   Reason: OOMKilled, Exit Code: 137.
   Dato clave: el proceso necesita ~150M de memoria para trabajar.
   Pista de diagnóstico:
     kubectl describe pod -l app=cache-worker -n ${NS_LAB}
   OBJETIVO: que cache-worker corra estable, sin reinicios por OOM.

 INCIDENTE 3 — namespace ${NS_QUOTA}, deployment api-backend
   Síntoma que vas a ver: el deployment queda en 2/3 READY y la tercera
   replica nunca aparece. El pod ni siquiera existe: al que hay que
   preguntarle es al ReplicaSet.
   Pista de diagnóstico:
     kubectl get deploy,rs,pods -n ${NS_QUOTA}
     kubectl describe rs -n ${NS_QUOTA}
     kubectl describe resourcequota cuota-equipo -n ${NS_QUOTA}
   REGLA DE JUEGO: la ResourceQuota es del equipo de plataforma, NO se toca.
   OBJETIVO: api-backend en 3/3 READY ajustando solo el deployment.

 Cuando creas que terminaste:   ./break-fix.sh verify
 Para empezar de cero:          ./break-fix.sh (lo regenera roto)
 Para limpiar todo:             ./break-fix.sh clean

 La solución paso a paso está comentada al FINAL de este archivo.
 No la mires hasta haber peleado un rato: en el examen no hay solucionario.
===============================================================================
EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
require_cluster
case "${1:-setup}" in
  setup)  setup_lab ;;
  verify) verify_lab ;;
  clean)  clean_lab ;;
  *)
    echo "Uso: $0 [setup|verify|clean]" >&2
    exit 1
    ;;
esac
exit 0

#===============================================================================
# SOLUCION PASO A PASO (spoilers — intentalo primero)
#===============================================================================
#
# ---- INCIDENTE 1: Pending por Insufficient cpu -------------------------------
#
# 1. Diagnóstico: el describe del pod muestra en Events algo como
#    "0/1 nodes are available: 1 Insufficient cpu."
#    El pod pide requests.cpu: "128" (¡128 cores enteros!) y ningún node del
#    lab tiene esa capacidad libre. El scheduler usa los REQUESTS (no el uso
#    real) para decidir dónde colocar un pod; si ningún node los puede
#    garantizar, el pod queda Pending indefinidamente.
#
# 2. Arreglo: bajá los requests a valores razonables. Lo más rápido en el
#    examen es kubectl set resources (dispara un rollout automáticamente):
#
#      kubectl set resources deployment/web-frontend -n ckad44-lab \
#        --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=256Mi
#
#    Alternativa: kubectl edit deployment web-frontend -n ckad44-lab
#    y corregir spec.template.spec.containers[0].resources a mano.
#
# 3. Verificación: kubectl get pods -n ckad44-lab -w  ->  Running 1/1.
#
# ---- INCIDENTE 2: OOMKilled / CrashLoopBackOff --------------------------------
#
# 1. Diagnóstico: kubectl describe pod muestra
#    Last State: Terminated / Reason: OOMKilled / Exit Code: 137.
#    El limit de memoria es un tope DURO: si el proceso lo supera, el kernel
#    lo mata (OOM killer) y kubelet lo reinicia una y otra vez
#    (CrashLoopBackOff). Acá el proceso reserva ~150M y el limit es 100Mi.
#
# 2. Arreglo: subí el limit por encima de lo que el proceso necesita, con
#    margen, y alineá el request con el consumo real:
#
#      kubectl set resources deployment/cache-worker -n ckad44-lab \
#        --requests=memory=150Mi --limits=memory=250Mi
#
# 3. Verificación: kubectl get pods -n ckad44-lab -w
#    El pod nuevo debe quedar Running y la columna RESTARTS dejar de crecer.
#    Regla mental para el examen: OOMKilled + 137 = problema de memory limit,
#    no un bug de la aplicación.
#
# ---- INCIDENTE 3: replica bloqueada por la ResourceQuota ----------------------
#
# 1. Diagnóstico: el pod que falta NO existe, así que no hay pod que describir.
#    Cuando una quota rechaza la creación, el error queda en el ReplicaSet:
#
#      kubectl describe rs -n ckad44-quota
#
#    En Events vas a ver algo como:
#    "forbidden: exceeded quota: cuota-equipo, requested: requests.cpu=400m,
#     used: requests.cpu=800m, limited: requests.cpu=1"
#
#    La cuenta: la quota permite requests.cpu = 1 (1000m) en el namespace.
#    Dos pods de 400m ya usan 800m; el tercero pediría 1200m en total y la
#    admission control lo rechaza.
#
# 2. Arreglo (sin tocar la quota): bajá el request por pod para que las 3
#    replicas entren en 1000m, es decir, 333m como máximo por pod:
#
#      kubectl set resources deployment/api-backend -n ckad44-quota \
#        --requests=cpu=250m
#
#    (3 x 250m = 750m <= 1000m, y los limits 3 x 600m = 1800m <= 2000m.)
#
#    Nota fina: este deployment usa strategy: Recreate a propósito. Con un
#    RollingUpdate, el pod nuevo se crea ANTES de borrar los viejos, y si la
#    quota ya está casi llena el rollout se puede trabar (el pod nuevo también
#    es rechazado). Si te pasa en un caso real: kubectl scale --replicas=0,
#    aplicás el cambio y volvés a escalar.
#
# 3. Verificación:
#      kubectl get deploy api-backend -n ckad44-quota   -> READY 3/3
#      kubectl describe resourcequota cuota-equipo -n ckad44-quota
#      (Used: requests.cpu 750m sobre Hard: 1)
#
# ---- Limpieza final -----------------------------------------------------------
#
#      ./break-fix.sh clean
#      (equivale a: kubectl delete ns ckad44-lab ckad44-quota)
#
#===============================================================================