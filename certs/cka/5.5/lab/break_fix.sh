#!/usr/bin/env bash
#
# CKA v1.35 - Tema 5.5: Ingress controllers e Ingress resources (peso 3.34)
# Fuente de referencia del temario: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Laboratorio "break & fix": arma un Ingress funcional apuntando a una app
# de prueba, lo rompe de forma aleatoria y controlada, y te deja
# diagnosticar y arreglarlo vos mismo/a.
#
# Requisitos: kubectl configurado contra un cluster con un Ingress
# controller nginx ya instalado (minikube addon "ingress", kind + manifest
# oficial, k3d, etc.).
#
# ADVERTENCIA: corré esto SOLO en una VM/cluster de laboratorio descartable.
# El script crea un namespace, parchea recursos y puede escalar a 0 el
# Deployment del Ingress controller del cluster apuntado por tu kubeconfig
# actual.

set -euo pipefail

NS="cka-ingress-lab"
APP="web"
HOST="cka-lab.example.com"
MARKER="/tmp/.cka-ingress-lab-break"

usage() {
  cat <<'USAGE'
Uso: ./ingress-break-fix.sh [--yes] [--cleanup] [--help]

  --yes       No pedir confirmacion interactiva antes de romper el cluster.
  --cleanup   Borra los recursos creados por el laboratorio, restaura el
              Ingress controller si hacia falta, y sale.
  --help      Muestra esta ayuda.
USAGE
}

CONFIRM=0
CLEANUP=0
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRM=1 ;;
    --cleanup) CLEANUP=1 ;;
    --help) usage; exit 0 ;;
    *) echo "Argumento desconocido: $arg" >&2; usage; exit 1 ;;
  esac
done

if [ "$CLEANUP" -eq 1 ]; then
  echo ">> Limpiando namespace $NS..."
  kubectl delete namespace "$NS" --ignore-not-found
  if [ -f "$MARKER" ]; then
    read -r _SC CONTROLLER_NS_SAVED CONTROLLER_DEPLOY_SAVED ORIG_REPLICAS_SAVED < "$MARKER"
    if [ -n "${CONTROLLER_DEPLOY_SAVED:-}" ] && [ -n "${ORIG_REPLICAS_SAVED:-}" ]; then
      echo ">> Restaurando $CONTROLLER_DEPLOY_SAVED en $CONTROLLER_NS_SAVED a $ORIG_REPLICAS_SAVED replica(s)..."
      kubectl scale "$CONTROLLER_DEPLOY_SAVED" -n "$CONTROLLER_NS_SAVED" --replicas="$ORIG_REPLICAS_SAVED" 2>/dev/null || true
    fi
    rm -f "$MARKER"
  fi
  echo "Listo."
  exit 0
fi

CTX=$(kubectl config current-context 2>/dev/null || echo "desconocido")

if [ "$CONFIRM" -ne 1 ]; then
  echo "Este script va a crear recursos y ROMPER intencionalmente el Ingress"
  echo "en el cluster del contexto actual: '$CTX'."
  echo "Usalo SOLO en una VM de laboratorio descartable."
  read -r -p "Confirmas que este cluster es descartable? (escribi 'si' para continuar): " ans
  if [ "$ans" != "si" ]; then
    echo "Cancelado."
    exit 1
  fi
fi

echo ">> Buscando un Ingress controller (nginx) corriendo en el cluster..."
CONTROLLER_NS=""
for ns in ingress-nginx kube-system; do
  if kubectl get pods -n "$ns" -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | grep -q Running; then
    CONTROLLER_NS="$ns"
    break
  fi
done

if [ -z "$CONTROLLER_NS" ]; then
  echo "No encontre un ingress-nginx controller corriendo."
  echo "Instalalo antes de correr este lab, por ejemplo:"
  echo "  minikube addons enable ingress"
  echo "  # o, en kind:"
  echo "  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"
  exit 1
fi

CONTROLLER_DEPLOY=$(kubectl get deploy -n "$CONTROLLER_NS" -l app.kubernetes.io/name=ingress-nginx -o name | head -n1)
ORIG_REPLICAS=$(kubectl get "$CONTROLLER_DEPLOY" -n "$CONTROLLER_NS" -o jsonpath='{.spec.replicas}')
REAL_CLASS=$(kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "nginx")

CONTROLLER_SVC_IP=$(kubectl get svc -n "$CONTROLLER_NS" -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)
if [ -z "$CONTROLLER_SVC_IP" ]; then
  CONTROLLER_SVC_IP=$(kubectl get svc -n "$CONTROLLER_NS" -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)
fi
if [ -z "$CONTROLLER_SVC_IP" ]; then
  echo "No pude resolver la ClusterIP del Service del Ingress controller."
  exit 1
fi

echo ">> Controller encontrado en '$CONTROLLER_NS' (deployment: $CONTROLLER_DEPLOY, ingressClass: $REAL_CLASS)"

echo ">> Preparando namespace y aplicacion de prueba ($NS)..."
kubectl delete namespace "$NS" --ignore-not-found >/dev/null
kubectl create namespace "$NS" >/dev/null

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $APP
  template:
    metadata:
      labels:
        app: $APP
    spec:
      containers:
        - name: $APP
          image: registry.k8s.io/e2e-test-images/agnhost:2.39
          args: ["netexec", "--http-port=8080"]
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}-svc
  namespace: $NS
spec:
  selector:
    app: $APP
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP}-ingress
  namespace: $NS
spec:
  ingressClassName: $REAL_CLASS
  rules:
    - host: $HOST
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${APP}-svc
                port:
                  number: 80
YAML

echo ">> Esperando que los pods de la app esten listos..."
kubectl wait --for=condition=Available deployment/"$APP" -n "$NS" --timeout=120s

echo ">> Verificando que el Ingress funciona ANTES de romper nada..."
kubectl run -n "$NS" precheck-curl --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" "http://${CONTROLLER_SVC_IP}:80/" \
  > /tmp/.cka-precheck-code 2>/dev/null || true
CODE=$(cat /tmp/.cka-precheck-code 2>/dev/null || echo "000")
rm -f /tmp/.cka-precheck-code
if [ "$CODE" != "200" ]; then
  echo "El Ingress no responde 200 antes de romper nada (codigo: $CODE)."
  echo "Revisa tu cluster / ingress controller antes de continuar."
  exit 1
fi
echo "   OK, responde 200."

echo ">> Rompiendo algo... (elegido al azar)"
SCENARIO=$(( RANDOM % 4 ))

case "$SCENARIO" in
  0)
    kubectl patch ingress "${APP}-ingress" -n "$NS" --type=merge \
      -p "{\"spec\":{\"ingressClassName\":\"${REAL_CLASS}-x\"}}" >/dev/null
    ;;
  1)
    kubectl patch ingress "${APP}-ingress" -n "$NS" --type=json \
      -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":9999}]' >/dev/null
    ;;
  2)
    kubectl patch service "${APP}-svc" -n "$NS" --type=merge \
      -p '{"spec":{"selector":{"app":"web-none"}}}' >/dev/null
    ;;
  3)
    kubectl scale "$CONTROLLER_DEPLOY" -n "$CONTROLLER_NS" --replicas=0 >/dev/null
    ;;
esac

echo "$SCENARIO $CONTROLLER_NS $CONTROLLER_DEPLOY $ORIG_REPLICAS" > "$MARKER"

cat <<EOF

================================================================
  LABORATORIO ROTO - namespace: $NS
================================================================

Sintoma que vas a observar:

  Corre este comando para probar el Ingress (apunta directo al
  Service del controller, con el header Host correspondiente,
  asi no dependes de DNS ni de un LoadBalancer externo):

    kubectl run -n $NS test-curl --rm -it --restart=Never \\
      --image=curlimages/curl:8.10.1 -- \\
      curl -v -H "Host: $HOST" http://${CONTROLLER_SVC_IP}:80/

  Antes de romperlo, ese comando devolvia HTTP 200. Ahora va a
  fallar de alguna manera (timeout, connection refused, 503, o
  un evento de configuracion invalida) — no te digo cual para
  que practiques el diagnostico.

Objetivo:

  Restaurar el acceso HTTP 200 al Ingress "${APP}-ingress" en el
  namespace "$NS", usando SOLO el estado actual del cluster (no
  borres y recrees los recursos: encontra el campo puntual que
  esta mal y corregilo).

Por donde empezar a mirar (comandos, no respuestas):

  kubectl get ingress -n $NS
  kubectl describe ingress ${APP}-ingress -n $NS
  kubectl get ingressclass
  kubectl get endpoints ${APP}-svc -n $NS
  kubectl get deploy -A -l app.kubernetes.io/name=ingress-nginx
  kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx

Cuando termines, confirma con el mismo curl de arriba: tiene que
volver a dar HTTP 200.

Para reiniciar el laboratorio desde cero (recrea todo, elige otro
escenario al azar): volve a correr este script.
Para limpiar todo: ./$(basename "$0") --cleanup

================================================================
EOF

exit 0

# ============================================================
# SOLUCION PASO A PASO (no la mires antes de intentarlo solo/a)
# ============================================================
#
# El script rompio UNO de estos cuatro escenarios al azar. Diagnostica
# con los comandos de arriba y aplica SOLO el fix que corresponda a lo
# que encontraste; los otros tres no aplican a tu corrida.
#
# --- Escenario 0: ingressClassName apunta a una IngressClass inexistente
#
#   Sintoma: "kubectl get ingress -n cka-ingress-lab" no muestra ADDRESS,
#   o tarda mucho / nunca aparece. El controller nunca "ve" este Ingress
#   porque su ingressClassName no matchea ninguna IngressClass real
#   ("kubectl get ingressclass" te muestra el nombre correcto).
#
#   Diagnostico:
#     kubectl get ingress web-ingress -n cka-ingress-lab -o jsonpath='{.spec.ingressClassName}{"\n"}'
#     kubectl get ingressclass
#
#   Fix (usa el nombre REAL que te dio "kubectl get ingressclass"):
#     kubectl patch ingress web-ingress -n cka-ingress-lab --type=merge \
#       -p '{"spec":{"ingressClassName":"nginx"}}'
#
# --- Escenario 1: el backend del Ingress apunta a un puerto que el Service no expone
#
#   Sintoma: HTTP 503, o un evento en "kubectl describe ingress" indicando
#   que el backend/puerto configurado no existe en el Service.
#
#   Diagnostico:
#     kubectl describe ingress web-ingress -n cka-ingress-lab
#     kubectl get service web-svc -n cka-ingress-lab -o yaml
#
#   Fix:
#     kubectl patch ingress web-ingress -n cka-ingress-lab --type=json \
#       -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":80}]'
#
# --- Escenario 2: el selector del Service ya no matchea los Pods (sin Endpoints)
#
#   Sintoma: el Ingress y el controller estan OK, pero curl igual da 503.
#   "kubectl get endpoints web-svc -n cka-ingress-lab" muestra <none>,
#   aunque los Pods de la app estan Running.
#
#   Diagnostico:
#     kubectl get endpoints web-svc -n cka-ingress-lab
#     kubectl get pods -n cka-ingress-lab --show-labels
#     kubectl get service web-svc -n cka-ingress-lab -o jsonpath='{.spec.selector}{"\n"}'
#
#   Fix:
#     kubectl patch service web-svc -n cka-ingress-lab --type=merge \
#       -p '{"spec":{"selector":{"app":"web"}}}'
#
# --- Escenario 3: el Deployment del Ingress controller esta escalado a 0
#
#   Sintoma: timeout o "connection refused" sin importar que Ingress uses.
#   Ningun Pod del controller aparece corriendo.
#
#   Diagnostico:
#     kubectl get deploy -A -l app.kubernetes.io/name=ingress-nginx
#     kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx
#
#   Fix (con el namespace/deployment que encontraste arriba):
#     kubectl scale deployment/<nombre-del-deployment> -n <namespace> --replicas=1
#     # espera a que el pod quede Running antes de reintentar el curl
#
# ============================================================