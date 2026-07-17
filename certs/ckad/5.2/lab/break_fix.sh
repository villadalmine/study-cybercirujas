#!/usr/bin/env bash
#
# CKAD (examen v1.35) - Laboratorio "break & fix"
# Curriculum: dominio "Services & Networking"
# Tema 5.2: Provide and troubleshoot access to applications via Services
# Peso en el examen: 5
# Fuente de referencia (curriculum oficial del CNCF, no se copia texto literal):
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Qué hace este script:
#   1) Crea un namespace descartable con un Deployment, un Service y un Pod
#      de test (curl) ya funcionando correctamente.
#   2) Verifica que todo funciona ANTES de romper nada.
#   3) Inyecta, al azar, UNA falla realista relacionada con cómo un Service
#      expone acceso a un Deployment (no se revela cuál).
#   4) Vos tenés que diagnosticar y arreglar el problema con kubectl.
#
# Uso:
#   ./ckad-5.2-break-fix.sh setup    # crea el laboratorio y rompe algo (default)
#   ./ckad-5.2-break-fix.sh check    # verifica si ya lo arreglaste
#   ./ckad-5.2-break-fix.sh cleanup  # borra todo lo creado por el laboratorio
#
# ADVERTENCIA: este script crea y borra un namespace, y aplica un patch
# destructivo A PROPÓSITO. Ejecutalo SOLO contra un cluster de laboratorio
# descartable (kind / minikube / k3d en una VM que podés tirar), nunca
# contra un cluster real o compartido.

set -euo pipefail

NS="ckad-5-2-lab"
DEPLOY="web-deploy"
SVC="web-svc"
TESTER="web-tester"

confirm_lab_cluster() {
  local ctx ans
  ctx="$(kubectl config current-context 2>/dev/null || echo '')"
  echo "Contexto actual de kubectl: ${ctx:-<ninguno>}"
  if [[ -z "$ctx" ]]; then
    echo "No hay contexto de kubectl configurado. Abortando." >&2
    exit 1
  fi
  if [[ "${CKAD_LAB_CONFIRM:-}" == "yes" ]]; then
    return 0
  fi
  ans=""
  read -r -p "Este script va a crear/borrar recursos en el namespace '${NS}' de ese cluster. ¿Es un cluster de laboratorio descartable? [escribí 'si' para continuar] " ans || ans=""
  if [[ "$ans" != "si" ]]; then
    echo "Cancelado por el usuario."
    exit 1
  fi
}

fault_selector_mismatch() {
  kubectl -n "$NS" patch service "$SVC" --type=merge \
    -p '{"spec":{"selector":{"app":"web-legacy"}}}' >/dev/null
}

fault_targetport_mismatch() {
  kubectl -n "$NS" patch service "$SVC" --type=json \
    -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]' >/dev/null
}

fault_scaled_to_zero() {
  kubectl -n "$NS" scale deployment "$DEPLOY" --replicas=0 >/dev/null
}

fault_broken_readiness() {
  kubectl -n "$NS" patch deployment "$DEPLOY" --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/no-existe-404"}]' >/dev/null
  kubectl -n "$NS" rollout status deployment/"$DEPLOY" --timeout=30s >/dev/null 2>&1 || true
}

inject_fault() {
  local faults pick
  faults=(fault_selector_mismatch fault_targetport_mismatch fault_scaled_to_zero fault_broken_readiness)
  pick="${faults[$((RANDOM % ${#faults[@]}))]}"
  "$pick"
}

cmd_setup() {
  confirm_lab_cluster

  if kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "Namespace previo detectado, limpiando..."
    kubectl delete namespace "$NS" --wait=true
  fi
  kubectl create namespace "$NS"

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels:
    app: web
spec:
  replicas: 2
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
EOF

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TESTER}
  namespace: ${NS}
  labels:
    app: web-tester
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
EOF

  echo "Esperando a que el Deployment esté listo..."
  kubectl -n "$NS" rollout status deployment/"$DEPLOY" --timeout=90s

  echo "Esperando a que el pod de test esté listo..."
  kubectl -n "$NS" wait --for=condition=Ready pod/"$TESTER" --timeout=60s

  echo "Verificación inicial (entorno sano, todavía sin romper nada)..."
  if ! kubectl -n "$NS" exec "$TESTER" -- curl -fsS --max-time 5 -o /dev/null "http://${SVC}/"; then
    echo "ERROR: el entorno base no quedó sano antes de inyectar la falla. Revisá el cluster." >&2
    exit 1
  fi
  echo "OK: el Service funciona correctamente antes de la falla inyectada."

  inject_fault

  cat <<MSG

============================================================
 LABORATORIO LISTO - Tema 5.2: acceso a apps via Services
============================================================
Se rompió A PROPÓSITO algo relacionado con cómo el Service
'${SVC}' expone al Deployment '${DEPLOY}' en el namespace
'${NS}'. Qué falla exacta se aplicó se elige al azar en cada
corrida de "setup" y no se te dice cuál es.

SÍNTOMA que vas a observar:
  Al intentar acceder a la app a través del Service, la
  conexión falla (timeout, connection refused, o no llega un
  HTTP 200), a pesar de que el Deployment "existe" en el
  namespace.

PROBAR EL SÍNTOMA:
  kubectl -n ${NS} exec ${TESTER} -- curl -v --max-time 5 http://${SVC}/

TU OBJETIVO:
  Diagnosticar y arreglar el problema usando kubectl, hasta
  que vuelva a valer lo siguiente:
    - kubectl -n ${NS} exec ${TESTER} -- curl -s -o /dev/null -w '%{http_code}\n' http://${SVC}/
      devuelve 200
    - kubectl -n ${NS} get endpoints ${SVC}
      muestra 2 direcciones
    - kubectl -n ${NS} get deployment ${DEPLOY}
      muestra 2/2 réplicas Ready

HERRAMIENTAS ÚTILES PARA DIAGNOSTICAR (no revelan la causa,
pero te dan las pistas que necesitás):
  kubectl -n ${NS} get deployment,pod,svc,endpoints -o wide
  kubectl -n ${NS} describe svc ${SVC}
  kubectl -n ${NS} describe pod -l app=web
  kubectl -n ${NS} get pod -l app=web --show-labels

Cuando creas que lo arreglaste, corré:
  $0 check

Para destruir el laboratorio:
  $0 cleanup
============================================================
MSG
}

cmd_check() {
  local http_code ready_endpoints ready_pods
  set +e
  http_code="$(kubectl -n "$NS" exec "$TESTER" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${SVC}/" 2>/dev/null)"
  ready_endpoints="$(kubectl -n "$NS" get endpoints "$SVC" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)"
  ready_pods="$(kubectl -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  set -e

  echo "HTTP code recibido: ${http_code:-<sin respuesta>}"
  echo "Endpoints Ready en el Service: ${ready_endpoints:-0}"
  echo "Pods Ready en el Deployment: ${ready_pods:-0} / 2"

  if [[ "${http_code:-}" == "200" && "${ready_endpoints:-0}" -ge 2 && "${ready_pods:-0}" -ge 2 ]]; then
    echo "RESULTADO: PASS - arreglaste el acceso a la app via el Service."
  else
    echo "RESULTADO: FAIL - todavía hay un problema. Seguí diagnosticando."
  fi
}

cmd_cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  echo "Namespace '${NS}' eliminado."
}

main() {
  local action="${1:-setup}"
  case "$action" in
    setup) cmd_setup ;;
    check) cmd_check ;;
    cleanup) cmd_cleanup ;;
    *)
      echo "Uso: $0 [setup|check|cleanup]" >&2
      exit 1
      ;;
  esac
}

main "$@"

# ============================================================
# SOLUCIÓN PASO A PASO (leer solo después de intentar el
# diagnóstico por tu cuenta)
# ============================================================
#
# Flujo general de troubleshooting para "acceso via Service":
#
#   1. kubectl -n ckad-5-2-lab get pods -o wide
#      ¿Hay pods corriendo? ¿Cuántos están Ready (columna READY,
#      ej. 1/1 vs 0/1)? Si no hay pods, el problema está en el
#      Deployment, no en el Service.
#
#   2. kubectl -n ckad-5-2-lab get endpoints web-svc
#      Un Service solo enruta tráfico a pods que:
#        a) coinciden con su spec.selector, y
#        b) están en estado Ready.
#      Si Endpoints está vacío (<none>), el problema es selector
#      o falta de pods Ready. Si Endpoints tiene IPs pero con un
#      puerto raro, el problema es targetPort.
#
#   3. kubectl -n ckad-5-2-lab describe svc web-svc
#      Mirá el campo "Selector:" y compará contra las labels
#      reales de los pods (paso 4).
#
#   4. kubectl -n ckad-5-2-lab get pod -l app=web --show-labels
#      Si este comando no devuelve nada pero "get pods" sí
#      muestra pods, es porque el selector del Service (o las
#      labels del pod) no coinciden.
#
#   5. kubectl -n ckad-5-2-lab describe pod <nombre-de-un-pod>
#      Mirá la sección "Events" al final: ahí aparecen fallos de
#      readiness probe con el detalle exacto (path, status code).
#
# Causa raíz según qué falla te haya tocado:
#
# --- CASO A: selector mismatch -----------------------------------
#   Diagnóstico: "describe svc web-svc" muestra Selector:
#   app=web-legacy, pero los pods tienen label app=web.
#   "get endpoints web-svc" está vacío.
#   Arreglo:
#     kubectl -n ckad-5-2-lab patch svc web-svc --type=merge \
#       -p '{"spec":{"selector":{"app":"web"}}}'
#
# --- CASO B: targetPort mismatch ----------------------------------
#   Diagnóstico: "get endpoints web-svc -o yaml" muestra el puerto
#   8080 en las addresses, pero el contenedor nginx solo escucha
#   en el 80 (containerPort: 80). curl da "connection refused".
#   Arreglo:
#     kubectl -n ckad-5-2-lab patch svc web-svc --type=json \
#       -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
#
# --- CASO C: Deployment escalado a 0 --------------------------------
#   Diagnóstico: "get deployment web-deploy" muestra 0/0 réplicas.
#   "get pods -l app=web" no devuelve nada. El Service está bien
#   configurado, pero no hay pods a los que enrutar.
#   Arreglo:
#     kubectl -n ckad-5-2-lab scale deployment web-deploy --replicas=2
#
# --- CASO D: readinessProbe rota ------------------------------------
#   Diagnóstico: "get pods -l app=web" muestra pods Running pero
#   0/1 en READY. "describe pod <pod>" muestra en Events algo como
#   "Readiness probe failed: HTTP probe failed with statuscode: 404"
#   contra el path /no-existe-404. Como no están Ready, no entran
#   en los Endpoints del Service.
#   Arreglo:
#     kubectl -n ckad-5-2-lab patch deployment web-deploy --type=json \
#       -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
#     kubectl -n ckad-5-2-lab rollout status deployment/web-deploy
#
# Verificación final (para cualquiera de los 4 casos):
#     ./ckad-5.2-break-fix.sh check
#   Debe imprimir "RESULTADO: PASS".
# ============================================================