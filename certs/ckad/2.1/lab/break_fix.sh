#!/usr/bin/env bash
#
# break-fix: CKAD 2.1 - Use Kubernetes primitives to implement common
# deployment strategies (blue/green, canary)
#
# Fuente de referencia (curriculum, no material copiado literal):
# https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Uso:
#   ./break-fix-2.1.sh break     -> crea el lab y rompe el cutover blue/green
#   ./break-fix-2.1.sh verify    -> chequea si ya arreglaste el problema
#   ./break-fix-2.1.sh cleanup   -> borra todo lo creado por este script
#
# Requiere: kubectl apuntando a un cluster descartable (kind/minikube/k3d) con
# salida a internet para bajar la imagen hashicorp/http-echo:1.0 (~5MB).

set -euo pipefail

NAMESPACE="ckad-2-1-blue-green"
SVC="webapp-svc"
CLIENT_POD="curl-client"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()  { echo "${BLUE}[lab]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }
ok()   { echo "${GREEN}[ok]${NC} $*"; }
err()  { echo "${RED}[x]${NC} $*"; }

safety_check() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "")"
  if [[ -z "$ctx" ]]; then
    err "No hay un current-context de kubectl configurado. Abortando."
    exit 1
  fi
  if [[ "$ctx" =~ prod ]]; then
    err "El current-context '$ctx' parece de producción. Este script rompe cosas a propósito: abortando por seguridad."
    exit 1
  fi
  log "current-context: $ctx (asumido cluster descartable de laboratorio)"
}

usage() {
  echo "Uso: $0 {break|verify|cleanup}"
}

setup_lab() {
  log "Recreando namespace $NAMESPACE ..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found >/dev/null
  kubectl wait --for=delete namespace/"$NAMESPACE" --timeout=60s 2>/dev/null || true
  kubectl create namespace "$NAMESPACE" >/dev/null

  log "Desplegando versión 'blue' (producción actual)..."
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-blue
  labels:
    app: webapp
    version: blue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
      version: blue
  template:
    metadata:
      labels:
        app: webapp
        version: blue
    spec:
      containers:
        - name: webapp
          image: hashicorp/http-echo:1.0
          args:
            - "-text=RESPONSE_FROM_BLUE"
            - "-listen=:5678"
          ports:
            - containerPort: 5678
EOF

  log "Desplegando versión 'green' (candidata al cutover)..."
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-green
  labels:
    app: webapp
    version: green
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
      version: green
  template:
    metadata:
      labels:
        app: webapp
        version: green
    spec:
      containers:
        - name: webapp
          image: hashicorp/http-echo:1.0
          args:
            - "-text=RESPONSE_FROM_GREEN"
            - "-listen=:5678"
          ports:
            - containerPort: 5678
EOF

  log "Creando Service (apunta a blue, que es lo que está sirviendo hoy)..."
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SVC
spec:
  selector:
    app: webapp
    version: blue
  ports:
    - port: 80
      targetPort: 5678
EOF

  log "Esperando rollouts..."
  kubectl -n "$NAMESPACE" rollout status deployment/webapp-blue --timeout=120s
  kubectl -n "$NAMESPACE" rollout status deployment/webapp-green --timeout=120s

  log "Creando pod cliente para hacer curl interno..."
  kubectl run "$CLIENT_POD" -n "$NAMESPACE" --image=curlimages/curl:8.7.1 \
    --restart=Never --command -- sleep infinity >/dev/null
  kubectl wait -n "$NAMESPACE" --for=condition=Ready pod/"$CLIENT_POD" --timeout=60s
}

curl_svc() {
  kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -s -m 3 "http://${SVC}" 2>/dev/null
}

show_baseline() {
  log "Chequeo de baseline (debería responder BLUE, que es lo que está en prod):"
  local resp
  for i in 1 2 3; do
    if resp="$(curl_svc)"; then
      echo "  intento $i: $resp"
    else
      warn "  intento $i: sin respuesta"
    fi
  done
}

inject_fault() {
  log "Un compañero de equipo intentó completar el cutover a green y corrió esto:"
  log "  kubectl patch service $SVC -n $NAMESPACE -p '{\"spec\":{\"selector\":{\"version\":\"green-v2\"}}}'"
  kubectl patch service "$SVC" -n "$NAMESPACE" --type merge \
    -p '{"spec":{"selector":{"app":"webapp","version":"green-v2"}}}' >/dev/null
}

print_briefing() {
  cat <<BRIEF

${YELLOW}================= SÍNTOMA =================${NC}
El Service '$SVC' en el namespace '$NAMESPACE' dejó de responder.
Un teammate quiso migrar el tráfico de la versión 'blue' a la versión
'green' (cutover blue/green) pero algo salió mal en el proceso.

Comprobalo vos mismo:

  kubectl get endpoints $SVC -n $NAMESPACE
  kubectl exec -n $NAMESPACE $CLIENT_POD -- curl -s -m 3 http://$SVC

Vas a ver que el Service no tiene ningún endpoint (EndpointSlice/Endpoints
vacío) y el curl no devuelve nada o hace timeout, aunque los Deployments
'webapp-blue' y 'webapp-green' están Ready con sus pods corriendo sin
problema.

${YELLOW}================ TU MISIÓN =================${NC}
1. Investigá por qué el Service no tiene endpoints (label selector vs.
   labels reales de los pods: 'kubectl get pods -n $NAMESPACE --show-labels').
2. Completá el cutover blue/green correctamente: el Service debe quedar
   sirviendo 100% tráfico a la versión 'green', sin volver a 'blue' y
   sin dejar el selector roto.
3. Confirmá el resultado corriendo varias veces:
     kubectl exec -n $NAMESPACE $CLIENT_POD -- curl -s -m 3 http://$SVC
   Todas las respuestas deben ser "RESPONSE_FROM_GREEN".

Cuando creas que lo arreglaste, corré:
  $0 verify

${YELLOW}=============================================${NC}

BRIEF
}

do_break() {
  safety_check
  setup_lab
  show_baseline
  inject_fault
  print_briefing
}

do_verify() {
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    err "El namespace $NAMESPACE no existe. Corré primero: $0 break"
    exit 1
  fi

  log "Endpoints actuales de $SVC:"
  kubectl get endpoints "$SVC" -n "$NAMESPACE" || true

  local total=5 green_count=0 other_count=0 fail_count=0 resp
  for i in $(seq 1 "$total"); do
    if resp="$(curl_svc)"; then
      echo "  intento $i: $resp"
      if [[ "$resp" == "RESPONSE_FROM_GREEN" ]]; then
        green_count=$((green_count + 1))
      else
        other_count=$((other_count + 1))
      fi
    else
      echo "  intento $i: sin respuesta"
      fail_count=$((fail_count + 1))
    fi
  done

  echo
  if [[ "$green_count" -eq "$total" ]]; then
    ok "Cutover completo: $green_count/$total respuestas fueron RESPONSE_FROM_GREEN. ¡Bien hecho!"
  elif [[ "$fail_count" -eq "$total" ]]; then
    err "El Service sigue sin endpoints funcionales. Revisá el selector del Service contra los labels reales de los pods de webapp-green."
    exit 1
  else
    warn "Resultado mixto (green=$green_count, otros=$other_count, fallos=$fail_count). El cutover todavía no es 100% green."
    exit 1
  fi
}

do_cleanup() {
  log "Borrando namespace $NAMESPACE ..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
}

case "${1:-}" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *)       usage; exit 1 ;;
esac

# =============================================================================
# SOLUCIÓN PASO A PASO (comentada a propósito: no se ejecuta automáticamente)
# =============================================================================
#
# 1. Confirmar el síntoma:
#      kubectl get endpoints webapp-svc -n ckad-2-1-blue-green
#      -> ENDPOINTS: <none>
#
# 2. Ver el selector roto que quedó en el Service:
#      kubectl get service webapp-svc -n ckad-2-1-blue-green -o yaml
#      -> spec.selector: { app: webapp, version: green-v2 }
#
#    El valor "green-v2" no existe en ningún pod: ningún pod matchea ese
#    selector (superset/typo), por eso el Service queda sin endpoints
#    aunque webapp-blue y webapp-green estén Ready.
#
# 3. Ver los labels reales de los pods candidatos al cutover:
#      kubectl get pods -n ckad-2-1-blue-green --show-labels
#      -> pods de webapp-green tienen: app=webapp, version=green
#
# 4. Corregir el selector del Service para que apunte a la versión green
#    (completando el cutover, no revirtiendo a blue):
#      kubectl patch service webapp-svc -n ckad-2-1-blue-green \
#        --type merge -p '{"spec":{"selector":{"app":"webapp","version":"green"}}}'
#
#    (Alternativa equivalente con edición interactiva:)
#      kubectl edit service webapp-svc -n ckad-2-1-blue-green
#      # cambiar spec.selector.version de "green-v2" a "green"
#
# 5. Verificar que el Service ahora tiene endpoints y que sirve solo green:
#      kubectl get endpoints webapp-svc -n ckad-2-1-blue-green
#      kubectl exec -n ckad-2-1-blue-green curl-client -- curl -s http://webapp-svc
#      -> RESPONSE_FROM_GREEN (repetido en todos los intentos)
#
# 6. (Opcional, buena práctica post-cutover) Una vez confirmado que green
#    es estable, escalar a cero o eliminar el Deployment webapp-blue para
#    liberar recursos, ya que el Service ya no lo selecciona:
#      kubectl scale deployment webapp-blue -n ckad-2-1-blue-green --replicas=0
#
# =============================================================================