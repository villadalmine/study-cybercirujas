#!/usr/bin/env bash
#===============================================================================
# break-fix-ckad-3.2.sh
#
# CKAD (examen v1.35) — Tema 3.2: "Use built-in CLI tools to monitor
# Kubernetes applications" (peso en el examen: 4%)
#
# Ejercicio "break & fix": este script rompe TRES cosas de forma controlada
# en un cluster de laboratorio y te propone diagnosticarlas usando solo las
# herramientas de monitoreo integradas en kubectl:
#
#     kubectl top | kubectl logs | kubectl describe | kubectl get events
#
# ⚠️  USALO ÚNICAMENTE EN UNA VM / CLUSTER DE LABORATORIO DESCARTABLE.
#     - Escala metrics-server (kube-system) a 0 réplicas.
#     - Crea workloads que consumen CPU (acotados con limits).
#     Todo es reversible; la limpieza está documentada al final.
#
# Fuentes de referencia (consultadas como guía, contenido original):
#   - Curriculum oficial CKAD v1.35:
#     https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#   - Resource metrics pipeline (kubectl top / metrics-server):
#     https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
#   - Debug de aplicaciones con kubectl:
#     https://kubernetes.io/docs/tasks/debug/debug-application/
#===============================================================================
set -euo pipefail

NS="ckad-lab-3-2"

#-------------------------------------------------------------------------------
# 0. Guardas de seguridad: confirmar cluster y acceso
#-------------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl no está instalado."; exit 1; }
kubectl version >/dev/null 2>&1 || { echo "ERROR: no puedo hablar con el API server. Revisá tu kubeconfig."; exit 1; }

echo "Este script va a modificar el cluster apuntado por tu contexto actual:"
echo "  context: $(kubectl config current-context)"
echo
read -r -p "¿Es un cluster de laboratorio DESCARTABLE? Escribí 'si' para continuar: " CONFIRMA
[ "${CONFIRMA}" = "si" ] || { echo "Abortado. No se tocó nada."; exit 1; }

#-------------------------------------------------------------------------------
# 1. Preparar el namespace del laboratorio
#-------------------------------------------------------------------------------
kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

#-------------------------------------------------------------------------------
# 2. BREAK B — app que entra en CrashLoopBackOff (la causa está en los logs)
#    Deployment "pedidos-api": arranca, loguea, y muere con exit code 1
#    porque le falta una variable de entorno. El diagnóstico exige
#    kubectl describe (exit code, events) + kubectl logs --previous.
#-------------------------------------------------------------------------------
kubectl apply -n "${NS}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pedidos-api
  labels:
    app: pedidos-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pedidos-api
  template:
    metadata:
      labels:
        app: pedidos-api
    spec:
      containers:
      - name: api
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
          - |
            echo "[pedidos-api] iniciando version 2.4.1"
            echo "[pedidos-api] cargando configuracion..."
            sleep 5
            if [ -z "${DB_HOST:-}" ]; then
              echo "[pedidos-api] FATAL: variable de entorno DB_HOST no definida, imposible conectar a la base de datos"
              exit 1
            fi
            echo "[pedidos-api] conectado a ${DB_HOST}"
            while true; do
              echo "[pedidos-api] procesando pedidos OK $(date)"
              sleep 30
            done
        resources:
          requests:
            cpu: 50m
            memory: 16Mi
          limits:
            cpu: 200m
            memory: 64Mi
EOF

#-------------------------------------------------------------------------------
# 3. BREAK C — workload "fugado" que devora CPU (se caza con kubectl top)
#    Deployment "carga-batch": 2 réplicas corriendo `yes > /dev/null`,
#    acotadas a 300m de CPU cada una para no tumbar la VM del lab.
#    También se despliega "frontend-web" (sano y casi sin consumo) para
#    que la comparación en kubectl top tenga sentido.
#-------------------------------------------------------------------------------
kubectl apply -n "${NS}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: carga-batch
  labels:
    app: carga-batch
spec:
  replicas: 2
  selector:
    matchLabels:
      app: carga-batch
  template:
    metadata:
      labels:
        app: carga-batch
    spec:
      containers:
      - name: worker
        image: busybox:1.36
        command: ["sh", "-c", "yes > /dev/null"]
        resources:
          requests:
            cpu: 50m
            memory: 16Mi
          limits:
            cpu: 300m
            memory: 32Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-web
  labels:
    app: frontend-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend-web
  template:
    metadata:
      labels:
        app: frontend-web
    spec:
      containers:
      - name: web
        image: busybox:1.36
        command: ["sh", "-c", "while true; do echo '[frontend-web] sirviendo trafico'; sleep 60; done"]
        resources:
          requests:
            cpu: 50m
            memory: 16Mi
          limits:
            cpu: 200m
            memory: 32Mi
EOF

#-------------------------------------------------------------------------------
# 4. BREAK A — tumbar metrics-server para que kubectl top deje de funcionar
#-------------------------------------------------------------------------------
if kubectl -n kube-system get deployment metrics-server >/dev/null 2>&1; then
  kubectl -n kube-system scale deployment metrics-server --replicas=0 >/dev/null
  METRICS="roto"
else
  METRICS="ausente"
fi

#-------------------------------------------------------------------------------
# 5. Briefing para el estudiante
#-------------------------------------------------------------------------------
cat <<EOF

===============================================================================
 ESCENARIO LISTO — CKAD 3.2: monitoreo con herramientas CLI integradas
===============================================================================

Contexto: sos el operador de guardia. Te reportan varios problemas en el
namespace "${NS}" (y uno a nivel cluster). Tu caja de herramientas para
diagnosticar es la que evalúa el examen en este tema:

    kubectl top nodes / pods      (métricas de CPU y memoria en vivo)
    kubectl logs                  (stdout/stderr de los contenedores)
    kubectl describe              (estado, exit codes, events del objeto)
    kubectl get events            (events del namespace, ordenables)

Para APLICAR el fix podés usar kubectl scale / set env / edit.

-------------------------------------------------------------------------------
 TAREA 1 — el monitoreo de métricas no responde   [resolvela PRIMERO]
-------------------------------------------------------------------------------
 SÍNTOMA : "kubectl top nodes" y "kubectl top pods" fallan con
           "error: Metrics API not available".
 OBJETIVO: que "kubectl top nodes" vuelva a mostrar CPU y memoria.
 PISTA   : kubectl top no habla con los kubelets directamente; depende de
           un componente que corre como Deployment en kube-system.
 NOTA    : la Tarea 3 necesita que kubectl top funcione — por eso va primero.
EOF

if [ "${METRICS}" = "ausente" ]; then
cat <<'EOF'
 ATENCIÓN: tu cluster NO tiene metrics-server desplegado, así que la Tarea 1
 se convierte en "instalarlo/activarlo" (en minikube:
 `minikube addons enable metrics-server`; en otros clusters, el manifiesto
 oficial de https://github.com/kubernetes-sigs/metrics-server).
EOF
fi

cat <<EOF

-------------------------------------------------------------------------------
 TAREA 2 — pedidos-api no levanta
-------------------------------------------------------------------------------
 SÍNTOMA : el pod de "pedidos-api" en "${NS}" cicla entre Error y
           CrashLoopBackOff; el contenedor termina con exit code 1.
 OBJETIVO: pod Running y READY 1/1, y que sus logs muestren
           "[pedidos-api] conectado a ...".
 PISTA   : la aplicación te dice exactamente qué le falta antes de morir,
           pero como el contenedor ya reinició, tenés que mirar los logs
           de la instancia ANTERIOR.

-------------------------------------------------------------------------------
 TAREA 3 — hay algo devorando CPU en el cluster
-------------------------------------------------------------------------------
 SÍNTOMA : la CPU del nodo está anormalmente alta; en "${NS}" conviven
           varios workloads y uno de ellos es el culpable.
 OBJETIVO: identificar con MÉTRICAS (no adivinando) cuál es el workload que
           más CPU consume, compararlo contra sus limits, y escalarlo a 0
           réplicas. Verificá después que el consumo del nodo bajó.
 PISTA   : kubectl top acepta --sort-by y --containers.

Cuando termines (o te rindas), abrí este script: la solución paso a paso
está comentada al final. Limpieza del lab: también documentada ahí.
===============================================================================
EOF

exit 0

#===============================================================================
# SOLUCIÓN PASO A PASO — no sigas leyendo hasta haberlo intentado
#===============================================================================
#
# ------ TAREA 1: metrics-server caído -----------------------------------------
# 1) Reproducí el síntoma:
#        kubectl top nodes
#        # error: Metrics API not available
#    kubectl top consume la Metrics API (metrics.k8s.io), que sirve
#    metrics-server agregando datos de los kubelets. Si metrics-server no
#    corre, kubectl top no tiene de dónde leer.
#    Ref: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
# 2) Mirá el componente en kube-system:
#        kubectl -n kube-system get deployment metrics-server
#        # READY 0/0  ← alguien lo escaló a cero
# 3) Restauralo:
#        kubectl -n kube-system scale deployment metrics-server --replicas=1
#        kubectl -n kube-system rollout status deployment metrics-server
# 4) Verificá (las métricas tardan ~30-60 s en juntarse tras el arranque):
#        kubectl top nodes
#
# ------ TAREA 2: pedidos-api en CrashLoopBackOff ------------------------------
# 1) Estado general:
#        kubectl -n ckad-lab-3-2 get pods
#        # pedidos-api-xxxx   0/1   CrashLoopBackOff
# 2) kubectl describe te da el exit code y los events:
#        kubectl -n ckad-lab-3-2 describe pod -l app=pedidos-api
#        # Last State: Terminated, Reason: Error, Exit Code: 1
#        # Events: Back-off restarting failed container
#    Exit code 1 = la app abortó por decisión propia → la causa está en logs.
# 3) Logs de la instancia ANTERIOR del contenedor (clave en el examen):
#        kubectl -n ckad-lab-3-2 logs deploy/pedidos-api --previous
#        # [pedidos-api] FATAL: variable de entorno DB_HOST no definida...
# 4) Otra vista útil de lo mismo, a nivel namespace:
#        kubectl -n ckad-lab-3-2 get events --sort-by=.metadata.creationTimestamp
# 5) El fix: inyectar la variable que falta (cualquier valor no vacío sirve
#    en este lab):
#        kubectl -n ckad-lab-3-2 set env deployment/pedidos-api DB_HOST=db.lab.local
# 6) Verificá:
#        kubectl -n ckad-lab-3-2 get pods -l app=pedidos-api
#        # 1/1 Running
#        kubectl -n ckad-lab-3-2 logs deploy/pedidos-api
#        # [pedidos-api] conectado a db.lab.local
#
# ------ TAREA 3: cazar al devorador de CPU con kubectl top --------------------
# 1) Con metrics-server ya reparado, ordená los pods por consumo:
#        kubectl -n ckad-lab-3-2 top pods --sort-by=cpu
#        # carga-batch-xxxx   ~300m   ← clavado en su limit (throttling)
#        # carga-batch-yyyy   ~300m
#        # frontend-web-zzzz  ~1m
#        # pedidos-api-wwww   ~1m
#    (a nivel cluster sería: kubectl top pods -A --sort-by=cpu)
# 2) Detalle por contenedor si el pod tuviera varios:
#        kubectl -n ckad-lab-3-2 top pods --containers
# 3) Contrastá consumo real vs. requests/limits declarados:
#        kubectl -n ckad-lab-3-2 describe pod -l app=carga-batch | grep -A4 Limits
#    Consumo == limit de CPU ⇒ el contenedor está siendo throttled: quiere más.
# 4) El fix pedido: sacar de circulación al workload fugado:
#        kubectl -n ckad-lab-3-2 scale deployment carga-batch --replicas=0
# 5) Verificá que el consumo bajó:
#        kubectl -n ckad-lab-3-2 top pods
#        kubectl top nodes
#
# ------ LIMPIEZA DEL LABORATORIO ----------------------------------------------
#        kubectl delete namespace ckad-lab-3-2
#    metrics-server ya quedó restaurado al resolver la Tarea 1; si no lo
#    resolviste, restauralo a mano:
#        kubectl -n kube-system scale deployment metrics-server --replicas=1
#===============================================================================