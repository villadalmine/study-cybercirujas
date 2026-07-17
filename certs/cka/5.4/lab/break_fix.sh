#!/usr/bin/env bash
#
# CKA v1.35 - Dominio 5.4: Use the Gateway API to manage Ingress traffic (peso 3.33%)
# Ejercicio "break & fix" para una VM de laboratorio descartable.
#
# Fuente de referencia (curricula oficial, solo como guia de alcance del tema):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
# Referencias tecnicas usadas para los comandos (no se copia texto, solo se cita):
#   https://gateway-api.sigs.k8s.io/
#   https://github.com/kubernetes-sigs/gateway-api/releases
#   https://docs.nginx.com/nginx-gateway-fabric/ (implementacion de referencia usada si el cluster no trae una)
#
# Este script NO debe correrse contra un cluster real. Esta pensado para un
# cluster de laboratorio descartable (kind/minikube/VM de practica).

set -euo pipefail

NAMESPACE="cka-gwapi-lab"
GATEWAY_NAME="web-gateway"
ROUTE_NAME="web-route"
SVC_NAME="web-svc"
HOSTNAME="web.cka.lab"
GWAPI_VERSION="v1.1.0"
NGF_VERSION="v1.5.0"
ASSUME_YES=0
FULL_CLEANUP=0
DO_CLEANUP=0

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
err()   { echo "[ERROR] $*" >&2; }

usage() {
  cat <<EOF
Uso: $0 [--yes] [--cleanup] [--full-cleanup] [-h]

  --yes           No pedir confirmacion interactiva (asumir "si").
  --cleanup       Borrar solo el namespace del lab ($NAMESPACE) y salir.
  --full-cleanup  Ademas de lo anterior, desinstalar NGINX Gateway Fabric
                  si fue instalado por este script.
  -h, --help      Mostrar esta ayuda.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --cleanup) DO_CLEANUP=1 ;;
    --full-cleanup) DO_CLEANUP=1; FULL_CLEANUP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Argumento desconocido: $1"; usage; exit 1 ;;
  esac
  shift
done

confirm_lab() {
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "desconocido")
  warn "Este script crea y ROMPE recursos de Kubernetes en el contexto actual: '$ctx'."
  warn "Usalo SOLO en una VM/cluster de laboratorio descartable."
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "Escribi 'si' para confirmar que este es un cluster de practica descartable: " ans
  if [[ "$ans" != "si" ]]; then
    err "Cancelado por el usuario."
    exit 1
  fi
}

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { err "kubectl no esta instalado."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { err "No se puede contactar al cluster."; exit 1; }
}

cleanup() {
  info "Borrando namespace de laboratorio '$NAMESPACE'..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  if [[ "$FULL_CLEANUP" -eq 1 ]]; then
    info "Desinstalando NGINX Gateway Fabric (si fue instalado por este script)..."
    kubectl delete -f "https://github.com/nginx/nginx-gateway-fabric/releases/download/${NGF_VERSION}/nginx-gateway.yaml" --ignore-not-found || true
    kubectl delete -f "https://github.com/nginx/nginx-gateway-fabric/releases/download/${NGF_VERSION}/crds.yaml" --ignore-not-found || true
  fi
}

ensure_gateway_api_crds() {
  if ! kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
    info "Instalando los CRDs estandar de Gateway API ($GWAPI_VERSION)..."
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml"
  else
    info "CRDs de Gateway API ya presentes."
  fi
}

detect_gateway_class() {
  local list gwc status
  list=$(kubectl get gatewayclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  for gwc in $list; do
    status=$(kubectl get gatewayclass "$gwc" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
    if [[ "$status" == "True" ]]; then
      echo "$gwc"
      return 0
    fi
  done
  return 1
}

ensure_gateway_controller() {
  local gwc waited=0
  gwc=$(detect_gateway_class || true)
  if [[ -n "$gwc" ]]; then
    info "GatewayClass ya aceptada encontrada: '$gwc'. La reuso para el lab."
    GATEWAY_CLASS="$gwc"
    return 0
  fi

  warn "No hay ninguna GatewayClass en estado Accepted=True."
  warn "Instalo NGINX Gateway Fabric ($NGF_VERSION) como implementacion de referencia para poder practicar."
  kubectl apply -f "https://github.com/nginx/nginx-gateway-fabric/releases/download/${NGF_VERSION}/crds.yaml"
  kubectl apply -f "https://github.com/nginx/nginx-gateway-fabric/releases/download/${NGF_VERSION}/nginx-gateway.yaml"

  while (( waited < 90 )); do
    gwc=$(detect_gateway_class || true)
    [[ -n "$gwc" ]] && break
    sleep 5
    waited=$((waited + 5))
  done

  if [[ -z "$gwc" ]]; then
    warn "Segui sin encontrar una GatewayClass Accepted. Continuo de todas formas:"
    warn "el foco del ejercicio es el modelo de objetos de Gateway API (Gateway/HTTPRoute),"
    warn "no la validacion de trafico real con un data plane funcionando."
    gwc="nginx"
  fi
  GATEWAY_CLASS="$gwc"
}

deploy_backend() {
  info "Creando namespace y backend de prueba en '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NAMESPACE" create deployment web --image=nginx:1.27-alpine --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NAMESPACE" expose deployment web --name="$SVC_NAME" --port=80 --target-port=80 --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NAMESPACE" rollout status deployment/web --timeout=90s
}

deploy_gateway_and_route() {
  info "Creando Gateway '$GATEWAY_NAME' y HTTPRoute '$ROUTE_NAME'..."
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "${HOSTNAME}"
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${ROUTE_NAME}
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
  hostnames:
    - "${HOSTNAME}"
  rules:
    - backendRefs:
        - name: ${SVC_NAME}
          port: 80
EOF

  local waited=0 status
  while (( waited < 60 )); do
    status=$(kubectl -n "$NAMESPACE" get httproute "$ROUTE_NAME" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
    [[ "$status" == "True" ]] && break
    sleep 3
    waited=$((waited + 3))
  done
}

introduce_fault() {
  info "Rompiendo la HTTPRoute de forma controlada (backendRefs con nombre incorrecto)..."
  kubectl -n "$NAMESPACE" patch httproute "$ROUTE_NAME" --type=json \
    -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"'"${SVC_NAME}"'-typo"}]'
}

print_mission() {
  cat <<EOF

============================================================
LAB ROTO: Gateway API - dominio 5.4 (CKA v1.35)
============================================================

Namespace del lab: $NAMESPACE
Objetos involucrados: Gateway/$GATEWAY_NAME, HTTPRoute/$ROUTE_NAME, Service/$SVC_NAME

SINTOMA:
  La HTTPRoute "$ROUTE_NAME" existe y esta asociada al Gateway "$GATEWAY_NAME",
  pero el trafico no llega al backend. Si el cluster tiene un controlador de
  Gateway API activo, un curl contra la direccion del Gateway devuelve un
  error (502/503 o "no healthy upstream"). En cualquier caso, la HTTPRoute
  va a mostrar una condicion de estado en False para el backend referenciado.

TU MISION:
  1. Diagnosticar por que la HTTPRoute no resuelve su backend, usando
     'kubectl describe' y/o 'kubectl get -o yaml' sobre el HTTPRoute.
  2. Corregir la HTTPRoute IN PLACE (sin borrarla y recrearla) para que
     vuelva a apuntar al Service correcto del namespace "$NAMESPACE".
  3. Confirmar que la condicion "ResolvedRefs" del parent quede en True:

     kubectl -n $NAMESPACE get httproute $ROUTE_NAME \\
       -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'

  4. Si el cluster tiene un data plane funcionando, validar con:

     GW_IP=\$(kubectl -n $NAMESPACE get gateway $GATEWAY_NAME -o jsonpath='{.status.addresses[0].value}')
     curl -H "Host: ${HOSTNAME}" "http://\${GW_IP}/"

     (deberia devolver 200 OK con la pagina default de nginx)

Corre este mismo script con --cleanup cuando termines para borrar el lab.
============================================================
EOF
}

main() {
  check_prereqs
  if [[ "$DO_CLEANUP" -eq 1 ]]; then
    cleanup
    exit 0
  fi
  confirm_lab
  ensure_gateway_api_crds
  ensure_gateway_controller
  deploy_backend
  deploy_gateway_and_route
  introduce_fault
  print_mission
}

main "$@"

# ============================================================
# SOLUCION PASO A PASO (comentada, no se ejecuta automaticamente)
# ============================================================
#
# 1) Ver el estado del HTTPRoute y localizar la condicion en False:
#      kubectl -n cka-gwapi-lab describe httproute web-route
#    Buscar algo como:
#      Type: ResolvedRefs   Status: False   Reason: BackendNotFound
#      Message: ... service "web-svc-typo" not found ...
#
# 2) Confirmar el nombre real del Service que si existe:
#      kubectl -n cka-gwapi-lab get svc
#      -> el Service correcto se llama "web-svc"
#
# 3) Corregir el backendRefs de la HTTPRoute (dos formas equivalentes):
#
#    a) Con patch JSON:
#      kubectl -n cka-gwapi-lab patch httproute web-route --type=json \
#        -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"web-svc"}]'
#
#    b) O editando interactivamente:
#      kubectl -n cka-gwapi-lab edit httproute web-route
#      (cambiar spec.rules[0].backendRefs[0].name de "web-svc-typo" a "web-svc")
#
# 4) Verificar que la referencia haya quedado resuelta:
#      kubectl -n cka-gwapi-lab get httproute web-route \
#        -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'
#      -> debe imprimir "True"
#
# 5) (Si hay un controlador de Gateway API con data plane real) validar trafico:
#      GW_IP=$(kubectl -n cka-gwapi-lab get gateway web-gateway -o jsonpath='{.status.addresses[0].value}')
#      curl -H "Host: web.cka.lab" "http://$GW_IP/"
#      -> debe devolver 200 OK con la pagina default de nginx
#
# 6) Limpieza del lab:
#      ./este-script.sh --cleanup
# ============================================================