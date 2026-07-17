#!/usr/bin/env bash
#==============================================================================
# CKAD 1.2 — Break & Fix: elegir y usar el workload resource correcto
#            (Deployment, DaemonSet, CronJob)
#
# Peso en el examen: 5
#
# USO:
#   ./ckad-1.2-breakfix.sh setup     # crea los 3 escenarios rotos
#   ./ckad-1.2-breakfix.sh verify    # comprueba si ya los arreglaste
#   ./ckad-1.2-breakfix.sh cleanup   # borra todo (elimina el namespace)
#
# ADVERTENCIA: ejecutá esto SOLO en un cluster de laboratorio descartable
# (minikube, kind o k3s dentro de una VM). Todo lo que rompe queda contenido
# en el namespace "ckad-1-2-breakfix", pero jamás lo corras en producción.
#
# Fuentes de referencia (consultadas como guía, contenido original):
# - CNCF, CKAD Curriculum v1.35:
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
# - Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
# - DaemonSet:   https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
# - CronJob:     https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
#==============================================================================

set -euo pipefail

NS="ckad-1-2-breakfix"

banner() {
  echo ""
  echo "=============================================================="
  echo "  $*"
  echo "=============================================================="
}

require_cluster() {
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl no está instalado."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: no hay conexión con ningún cluster. ¿Está levantado minikube/kind?"; exit 1; }
}

#------------------------------------------------------------------------------
# SETUP: crea recursos que "funcionan mal" de forma controlada.
# Cada escenario ilustra un error típico al usar el workload resource elegido.
#------------------------------------------------------------------------------
setup() {
  require_cluster

  if kubectl get ns "$NS" >/dev/null 2>&1; then
    echo "El namespace $NS ya existe. Corré primero: $0 cleanup"
    exit 1
  fi

  kubectl create namespace "$NS" >/dev/null

  banner "Escenario 1: Deployment que no actualiza"
  # Deployment sano con nginx:1.27...
  kubectl -n "$NS" create deployment web --image=nginx:1.27 --replicas=3 >/dev/null
  kubectl -n "$NS" rollout status deployment/web --timeout=120s >/dev/null
  # ...que rompemos: pausamos el rollout y DESPUÉS pedimos una imagen nueva.
  kubectl -n "$NS" rollout pause deployment/web
  kubectl -n "$NS" set image deployment/web nginx=nginx:1.28 >/dev/null

  banner "Escenario 2: CronJob que nunca ejecuta"
  # CronJob cada minuto, pero nace suspendido.
  kubectl -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "*/1 * * * *"
  suspend: true
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: backup
            image: busybox:1.36
            command: ["sh", "-c", "echo backup ejecutado en $(date)"]
EOF

  banner "Escenario 3: DaemonSet que no agenda ningún Pod"
  # DaemonSet con un nodeSelector que ningún node del cluster cumple.
  kubectl -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
spec:
  selector:
    matchLabels:
      app: log-agent
  template:
    metadata:
      labels:
        app: log-agent
    spec:
      nodeSelector:
        role: logging
      containers:
      - name: agent
        image: busybox:1.36
        command: ["sh", "-c", "sleep infinity"]
EOF

  cat <<EOT

##############################################################################
#  LABORATORIO LISTO — namespace: $NS
##############################################################################

Los tres workload resources del tema 1.2 están desplegados, y los tres tienen
un problema. Tu misión es diagnosticarlos y arreglarlos usando solo kubectl.

--- SÍNTOMA 1 (Deployment "web") ------------------------------------------
Alguien pidió actualizar la imagen a nginx:1.28, pero los Pods siguen
corriendo nginx:1.27. Vas a verlo con:

    kubectl -n $NS get pods -o jsonpath='{.items[*].spec.containers[*].image}'
    kubectl -n $NS rollout status deployment/web   # se queda colgado

OBJETIVO: que las 3 replicas corran nginx:1.28 y el rollout termine.
PISTA: mirá el campo "paused" con: kubectl -n $NS get deploy web -o yaml

--- SÍNTOMA 2 (CronJob "backup") -------------------------------------------
El CronJob debería crear un Job por minuto, pero pasan los minutos y:

    kubectl -n $NS get cronjob,jobs
    # LAST SCHEDULE = <none> y no aparece ningún Job

OBJETIVO: que el CronJob cree Jobs y que al menos uno complete.
PISTA: fijate la columna SUSPEND en "kubectl get cronjob".

--- SÍNTOMA 3 (DaemonSet "log-agent") --------------------------------------
Un DaemonSet debe correr un Pod en cada node, pero:

    kubectl -n $NS get daemonset log-agent
    # DESIRED = 0, CURRENT = 0: ¡no agendó nada en ningún node!

OBJETIVO: que log-agent tenga al menos 1 Pod Running.
PISTA: compará el nodeSelector del DaemonSet con los labels reales de tus
nodes ("kubectl get nodes --show-labels"). Hay dos formas válidas de
arreglarlo: cambiar el DaemonSet o cambiar el node.

Cuando creas que terminaste, validá con:  $0 verify
Para borrar todo:                          $0 cleanup
EOT
}

#------------------------------------------------------------------------------
# VERIFY: comprueba los tres objetivos sin revelar la solución.
#------------------------------------------------------------------------------
verify() {
  require_cluster
  local ok=0 fail=0

  banner "Verificando escenario 1: Deployment web"
  local paused updated image
  paused=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.paused}' 2>/dev/null || echo "")
  image=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
  updated=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  if [ "$paused" != "true" ] && [ "$image" = "nginx:1.28" ] && [ "${updated:-0}" -ge 3 ]; then
    echo "  [OK] Rollout reanudado y las 3 replicas corren nginx:1.28"
    ok=$((ok+1))
  else
    echo "  [FALTA] paused='$paused' image='$image' updatedReplicas='${updated:-0}'"
    fail=$((fail+1))
  fi

  banner "Verificando escenario 2: CronJob backup"
  local suspend scheduled
  suspend=$(kubectl -n "$NS" get cronjob backup -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "")
  scheduled=$(kubectl -n "$NS" get cronjob backup -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || echo "")
  if [ "$suspend" = "false" ] && [ -n "$scheduled" ]; then
    echo "  [OK] CronJob activo, último schedule: $scheduled"
    ok=$((ok+1))
  elif [ "$suspend" = "false" ]; then
    echo "  [CASI] suspend=false pero todavía no corrió ningún Job. Esperá 1 minuto y volvé a verificar."
    fail=$((fail+1))
  else
    echo "  [FALTA] El CronJob sigue suspendido (suspend='$suspend')"
    fail=$((fail+1))
  fi

  banner "Verificando escenario 3: DaemonSet log-agent"
  local ready
  ready=$(kubectl -n "$NS" get daemonset log-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  if [ "${ready:-0}" -ge 1 ]; then
    echo "  [OK] DaemonSet con $ready Pod(s) Ready"
    ok=$((ok+1))
  else
    echo "  [FALTA] El DaemonSet sigue sin Pods Ready (numberReady=${ready:-0})"
    fail=$((fail+1))
  fi

  banner "Resultado: $ok/3 escenarios resueltos"
  [ "$fail" -eq 0 ] && echo "¡Excelente! Ya podés borrar el laboratorio con: $0 cleanup"
  [ "$fail" -eq 0 ]
}

cleanup() {
  require_cluster
  kubectl delete namespace "$NS" --ignore-not-found
  # Si arreglaste el escenario 3 etiquetando un node, sacale el label:
  kubectl label nodes --all role- >/dev/null 2>&1 || true
  echo "Laboratorio eliminado."
}

case "${1:-setup}" in
  setup)   setup ;;
  verify)  verify ;;
  cleanup) cleanup ;;
  *) echo "Uso: $0 [setup|verify|cleanup]"; exit 1 ;;
esac

exit 0

#==============================================================================
# SOLUCIÓN PASO A PASO (no mires hasta intentarlo)
#==============================================================================
#
# --- Escenario 1: Deployment "web" pausado -----------------------------------
# Diagnóstico: el rollout está en pausa, por eso el cambio de imagen quedó
# escrito en el spec pero nunca se aplicó a los Pods.
#
#   kubectl -n ckad-1-2-breakfix get deploy web -o jsonpath='{.spec.paused}'
#   # -> true
#   kubectl -n ckad-1-2-breakfix describe deploy web | grep -i progress
#   # -> condición Progressing con reason: DeploymentPaused
#
# Arreglo: reanudar el rollout y esperar a que termine.
#
#   kubectl -n ckad-1-2-breakfix rollout resume deployment/web
#   kubectl -n ckad-1-2-breakfix rollout status deployment/web
#
# Lección CKAD: "rollout pause/resume" permite agrupar varios cambios en un
# solo rollout; un Deployment pausado acepta ediciones pero no las despliega.
#
# --- Escenario 2: CronJob "backup" suspendido --------------------------------
# Diagnóstico: la columna SUSPEND está en True; el controller no crea Jobs.
#
#   kubectl -n ckad-1-2-breakfix get cronjob backup
#   # NAME    SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE
#   # backup  */1 * * * *   True      0        <none>
#
# Arreglo: poner suspend en false (patch o edit) y esperar ~1 minuto.
#
#   kubectl -n ckad-1-2-breakfix patch cronjob backup \
#     -p '{"spec":{"suspend":false}}'
#   kubectl -n ckad-1-2-breakfix get jobs -w
#
# Truco de examen: para no esperar al schedule podés disparar un Job manual
# desde el CronJob:
#
#   kubectl -n ckad-1-2-breakfix create job backup-manual --from=cronjob/backup
#
# Lección CKAD: CronJob es el workload correcto para tareas programadas;
# "suspend: true" lo apaga sin borrarlo (útil en mantenimientos).
#
# --- Escenario 3: DaemonSet "log-agent" sin nodes elegibles ------------------
# Diagnóstico: el nodeSelector "role: logging" no coincide con ningún node,
# así que DESIRED=0. Un DaemonSet solo agenda Pods en nodes que matcheen.
#
#   kubectl -n ckad-1-2-breakfix get ds log-agent \
#     -o jsonpath='{.spec.template.spec.nodeSelector}'
#   kubectl get nodes --show-labels
#
# Arreglo — opción A: etiquetar un node para que cumpla el selector.
#
#   kubectl label node <nombre-del-node> role=logging
#
# Arreglo — opción B: quitar el nodeSelector del DaemonSet para que corra
# en todos los nodes (comportamiento clásico de un agente de logging).
#
#   kubectl -n ckad-1-2-breakfix patch ds log-agent --type=json \
#     -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
#
# Lección CKAD: DaemonSet es el workload correcto para "un Pod por node"
# (agentes de logs, monitoring, CNI); su scheduling depende de labels,
# selectors, taints y tolerations, no del campo replicas.
#
# --- Repaso del tema 1.2: ¿qué workload elijo? -------------------------------
# * Deployment: apps stateless con replicas y rolling updates.
# * DaemonSet:  un Pod por node (o por subconjunto de nodes vía labels).
# * Job:        tarea que corre hasta completarse una vez.
# * CronJob:    Jobs en un horario (sintaxis cron).
# * StatefulSet: identidad estable por Pod + storage persistente por replica.
#==============================================================================