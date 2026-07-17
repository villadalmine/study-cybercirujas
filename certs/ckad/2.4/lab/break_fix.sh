#!/usr/bin/env bash
#
# CKAD v1.35 - Tema 2.4: Understand API deprecations (peso: 5)
# Break & Fix lab - ejecutar SOLO en una VM de laboratorio descartable con
# un cluster de Kubernetes de prueba (kind/minikube/k3d). El script no toca
# nada fuera de un namespace dedicado y es completamente reversible.
#
# Fuentes de referencia (consultadas solo como contexto, contenido original):
#   - https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#   - https://kubernetes.io/docs/reference/using-api/deprecation-guide/
#   - https://kubernetes.io/docs/reference/using-api/deprecation-policy/
#
# Uso:
#   ./ckad-2.4-api-deprecations.sh break     # rompe el escenario (default)
#   ./ckad-2.4-api-deprecations.sh verify    # chequea si ya lo arreglaste
#   ./ckad-2.4-api-deprecations.sh teardown  # limpia todo lo creado

set -euo pipefail

NS="ckad-topic-2-4"
LAB_DIR="$(mktemp -d /tmp/ckad-2.4-lab.XXXXXX)"
MANIFEST="${LAB_DIR}/cronjob.yaml"
CRONJOB_NAME="log-rotation"

log()  { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*"; }
goal() { printf '[GOAL]  %s\n' "$*"; }
sym()  { printf '[SINTOMA] %s\n' "$*"; }

require_disposable_confirmation() {
    local ctx
    ctx="$(kubectl config current-context 2>/dev/null || echo '<sin-contexto>')"

    if [[ "${ctx}" =~ (prod|production|prd) ]]; then
        echo "El contexto actual ('${ctx}') parece un cluster productivo. Abortando." >&2
        exit 1
    fi

    if [[ "${CKAD_LAB_CONFIRM:-}" != "yes" ]]; then
        cat >&2 <<EOF
Este script crea/borra recursos en el contexto de kubectl: '${ctx}'.
Debe correr únicamente contra una VM/cluster de laboratorio descartable
(kind, minikube, k3d, etc).

Si confirmás que este es un entorno descartable, volvé a ejecutar con:
  CKAD_LAB_CONFIRM=yes $0 $*
EOF
        exit 1
    fi
}

ensure_namespace() {
    kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"
}

server_minor_version() {
    kubectl get --raw /version \
        | grep -oP '"gitVersion":\s*"\Kv[0-9]+\.[0-9]+' \
        | sed -E 's/^v[0-9]+\.//'
}

do_break() {
    require_disposable_confirmation
    ensure_namespace

    # batch/v1beta1 es la apiVersion pre-1.21 de CronJob. Quedó deprecada en
    # 1.21 y fue removida por completo del API server en 1.25 (ver
    # deprecation-guide arriba). Este manifiesto simula un pipeline de
    # deploy viejo que nadie actualizó.
    cat > "${MANIFEST}" <<EOF
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: ${CRONJOB_NAME}
  namespace: ${NS}
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: rotate
              image: busybox:1.36
              command: ["sh", "-c", "echo rotating logs; sleep 5"]
EOF

    log "Namespace de laboratorio: ${NS}"
    log "Manifiesto 'roto' generado en: ${MANIFEST}"
    log "Intentando desplegar el pipeline de siempre..."
    echo

    set +e
    kubectl apply -f "${MANIFEST}"
    rc=$?
    set -e
    echo

    minor="$(server_minor_version || echo '?')"

    if [[ ${rc} -ne 0 ]]; then
        sym "kubectl apply falló. El API server de este cluster (v1.${minor}) ya no reconoce 'batch/v1beta1'."
        sym "El error típico es algo como: no matches for kind \"CronJob\" in version \"batch/v1beta1\""
    else
        sym "kubectl apply 'funcionó', pero fijate el stderr: debería haber un warning de deprecación"
        sym "del tipo: 'batch/v1beta1 CronJob is deprecated in v1.21+, unavailable in v1.25+; use batch/v1 CronJob'"
        warn "Este cluster (v1.${minor}) todavía sirve la API deprecada. En un cluster >=1.25 esto rompe directamente."
    fi

    echo
    goal "El equipo necesita que el CronJob '${CRONJOB_NAME}' quede corriendo en el namespace '${NS}'"
    goal "usando una apiVersion soportada de forma estable por este cluster (no deprecada)."
    goal "No cambies el nombre, el namespace ni el schedule del CronJob."
    goal "Cuando termines, 'kubectl get cronjob -n ${NS}' debe mostrar el recurso y"
    goal "'kubectl apply -f ${MANIFEST}' no debe emitir errores ni warnings de deprecación."
    echo
    log "Herramientas permitidas para investigar: kubectl api-resources, kubectl api-versions,"
    log "kubectl explain cronjob, kubectl apply --dry-run=server -f ${MANIFEST}"
    log "Editá el archivo con: \${EDITOR:-vi} ${MANIFEST}"
    echo
    log "Corré '$0 verify' cuando creas que lo resolviste."
}

do_verify() {
    if ! kubectl get cronjob "${CRONJOB_NAME}" -n "${NS}" >/dev/null 2>&1; then
        echo "FALLO: no existe el CronJob '${CRONJOB_NAME}' en el namespace '${NS}'." >&2
        exit 1
    fi

    api_version="$(kubectl get cronjob "${CRONJOB_NAME}" -n "${NS}" -o jsonpath='{.apiVersion}')"
    if [[ "${api_version}" == "batch/v1beta1" ]]; then
        echo "FALLO: el CronJob sigue usando la apiVersion deprecada/removida (${api_version})." >&2
        exit 1
    fi

    warnings="$(kubectl apply -f "${MANIFEST}" --dry-run=server 2>&1 >/dev/null || true)"
    if echo "${warnings}" | grep -qi deprecat; then
        echo "FALLO: kubectl todavía reporta un warning de deprecación:" >&2
        echo "${warnings}" >&2
        exit 1
    fi

    echo "OK: CronJob '${CRONJOB_NAME}' corriendo con apiVersion '${api_version}', sin warnings de deprecación."
}

do_teardown() {
    kubectl delete namespace "${NS}" --ignore-not-found=true
    rm -rf "${LAB_DIR}"
    log "Namespace '${NS}' y archivos temporales eliminados."
}

case "${1:-break}" in
    break)    do_break ;;
    verify)   do_verify ;;
    teardown) do_teardown ;;
    *)
        echo "Uso: $0 [break|verify|teardown]" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# SOLUCIÓN (comentada - no se ejecuta)
#
# 1. Confirmar qué versión de la API está removida/deprecada en este cluster:
#      kubectl api-resources | grep -i cronjob
#      kubectl api-versions | grep batch
#    Solo debería listarse 'batch/v1' para CronJob; 'batch/v1beta1' ya no
#    aparece en clusters >=1.25.
#
# 2. Confirmar la causa exacta releyendo el error/warning del paso 'break':
#    - Si fue error duro: "no matches for kind \"CronJob\" in version
#      \"batch/v1beta1\"" -> la API fue removida del API server.
#    - Si fue solo warning: "CronJob is deprecated in v1.21+, unavailable in
#      v1.25+; use batch/v1 CronJob" -> todavía funciona pero hay que
#      migrarlo antes de actualizar el cluster.
#
# 3. Editar el manifiesto y cambiar únicamente la apiVersion (el resto del
#    schema de CronJob es idéntico entre batch/v1beta1 y batch/v1, no hace
#    falta tocar spec.schedule ni spec.jobTemplate):
#
#      sed -i 's#apiVersion: batch/v1beta1#apiVersion: batch/v1#' "$MANIFEST"
#
#    O manualmente:
#      apiVersion: batch/v1
#      kind: CronJob
#      metadata:
#        name: log-rotation
#        namespace: ckad-topic-2-4
#      spec:
#        schedule: "*/5 * * * *"
#        jobTemplate:
#          spec:
#            template:
#              spec:
#                restartPolicy: OnFailure
#                containers:
#                  - name: rotate
#                    image: busybox:1.36
#                    command: ["sh", "-c", "echo rotating logs; sleep 5"]
#
# 4. Validar antes de aplicar (sin efectos secundarios):
#      kubectl apply -f "$MANIFEST" --dry-run=server
#    No debe haber errores ni warnings de deprecación.
#
# 5. Aplicar de verdad y confirmar:
#      kubectl apply -f "$MANIFEST"
#      kubectl get cronjob -n ckad-topic-2-4
#
# 6. (Opcional, buena práctica real) Auditar el resto del namespace/cluster
#    por otras APIs deprecadas antes de un upgrade, con una herramienta como
#    'pluto' (https://github.com/FairwindsOps/pluto) o
#    'kubectl-convert' (plugin oficial de kubectl) que reescribe manifiestos
#    viejos a la apiVersion actual automáticamente.
# ---------------------------------------------------------------------------