#!/usr/bin/env bash
#
# CKAD 1.35 - Tema 5.3: Use Ingress rules to expose applications (peso 5)
# Script "break & fix" para VM de laboratorio descartable.
# Crea una app + Service + Ingress funcionando y luego rompe una regla del
# Ingress a propósito. El estudiante debe diagnosticar y arreglar SOLO el
# Ingress (sin borrar/recrear el namespace) hasta que el curl de verificación
# devuelva 200.
#
# Referencia curricular: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Uso:
#   ./break-fix-5.3-ingress.sh            # crea el escenario y lo rompe
#   ./break-fix-5.3-ingress.sh -y         # igual, sin pedir confirmación
#   ./break-fix-5.3-ingress.sh --cleanup  # borra todo lo creado por el script

set -euo pipefail

NAMESPACE="ckad-53-ingress-lab"
APP_NAME="hello-ingress"
SVC_NAME="hello-ingress-svc"
ING_NAME="hello-ingress-rules"
CM_NAME="hello-ingress-html"
CORRECT_HOST="hello.ckad.test"
BROKEN_HOST="hello.ckad.tset"   # typo realista: transposición de letras

SKIP_CONFIRM="no"
DO_CLEANUP="no"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) SKIP_CONFIRM="yes" ;;
    --cleanup) DO_CLEANUP="yes" ;;
    -h|--help)
      echo "Uso: $0 [-y|--yes] [--cleanup]"
      exit 0
      ;;
    *)
      echo "Argumento desconocido: $arg" >&2
      exit 1
      ;;
  esac
done

log() { echo "[ckad-5.3-lab] $*"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado en PATH." >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "No se puede contactar al cluster de kubectl." >&2; exit 1; }

if [ "$DO_CLEANUP" = "yes" ]; then
  log "Borrando namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
  log "Listo."
  exit 0
fi

CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "desconocido")
log "Contexto actual de kubectl: ${CURRENT_CTX}"

if [ "$SKIP_CONFIRM" != "yes" ]; then
  read -r -p "Este script crea recursos y ROMPE un Ingress a propósito en este cluster. Ejecutalo SOLO en una VM de laboratorio descartable. ¿Continuar? [y/N] " ans
  case "$ans" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Cancelado."; exit 1 ;;
  esac
fi

log "Creando namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

ING_CLASS=$(kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${ING_CLASS}" ]; then
  log "ADVERTENCIA: no se detectó ninguna IngressClass en el cluster."
  log "Instalá un ingress controller (ej: 'minikube addons enable ingress' o ingress-nginx) antes de validar el ejercicio."
  ING_CLASS_YAML=""
else
  log "IngressClass detectada: ${ING_CLASS}"
  ING_CLASS_YAML="  ingressClassName: ${ING_CLASS}"
fi

log "Creando ConfigMap con contenido de la app..."
kubectl -n "${NAMESPACE}" create configmap "${CM_NAME}" \
  --from-literal=index.html="OK - CKAD 5.3 Ingress Lab" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Creando Deployment y Service..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: web
        image: nginx:stable-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: ${CM_NAME}
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP_NAME}
  ports:
  - port: 80
    targetPort: 80
EOF

log "Esperando rollout del Deployment..."
kubectl -n "${NAMESPACE}" rollout status deployment/"${APP_NAME}" --timeout=90s

log "Creando Ingress con la regla correcta (host: ${CORRECT_HOST})..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${ING_NAME}
  namespace: ${NAMESPACE}
spec:
${ING_CLASS_YAML}
  rules:
  - host: ${CORRECT_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SVC_NAME}
            port:
              number: 80
EOF

sleep 5

log "Rompiendo el escenario (modificando una regla del Ingress)..."
kubectl -n "${NAMESPACE}" patch ingress "${ING_NAME}" \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"${BROKEN_HOST}\"}]"

get_access_ip() {
  local ip=""
  if command -v minikube >/dev/null 2>&1 && kubectl config current-context 2>/dev/null | grep -qi minikube; then
    ip=$(minikube ip 2>/dev/null || true)
  fi
  if [ -z "$ip" ]; then
    ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
  if [ -z "$ip" ]; then
    ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  fi
  echo "$ip"
}

ACCESS_IP=$(get_access_ip)
if [ -z "$ACCESS_IP" ]; then
  ACCESS_IP="<IP-DEL-INGRESS-CONTROLLER>"
fi

cat <<MSG

=================================================================
ESCENARIO ROTO - CKAD 5.3: Use Ingress rules to expose applications
=================================================================
Namespace: ${NAMESPACE}

Todos los Pods están Running, el Service tiene Endpoints, y el Ingress
existe. Sin embargo, al probar la aplicación no se obtiene la respuesta
esperada.

Comando de verificación (el objetivo es que esto devuelva HTTP 200
con el cuerpo "OK - CKAD 5.3 Ingress Lab"):

  curl -i -H "Host: ${CORRECT_HOST}" http://${ACCESS_IP}/

Si tu cluster expone el ingress controller por NodePort en vez de
LoadBalancer, ajustá el puerto en la URL de arriba según corresponda
(kubectl -n ingress-nginx get svc).

SÍNTOMA: el curl no devuelve el contenido esperado (probablemente un
404 del "default backend" del ingress controller), a pesar de que
Deployment, Pods y Service se ven saludables.

OBJETIVO: encontrá y corregí SOLO el recurso Ingress "${ING_NAME}"
en el namespace "${NAMESPACE}" (sin borrar ni recrear namespace,
Deployment o Service) para que el curl de arriba devuelva 200.

Herramientas de diagnóstico permitidas:
  kubectl -n ${NAMESPACE} get pods,svc,endpoints,ingress
  kubectl -n ${NAMESPACE} describe ingress ${ING_NAME}
  kubectl -n ${NAMESPACE} get ingress ${ING_NAME} -o yaml

Cuando termines, limpiá el laboratorio con:
  $0 --cleanup
=================================================================
MSG

# ================================================================
# SOLUCIÓN PASO A PASO (no la leas antes de intentar resolverlo solo)
# ================================================================
#
# 1. Diagnóstico general: confirmar que Pods, Service y endpoints están OK.
#      kubectl -n ckad-53-ingress-lab get pods,svc,endpoints
#    -> Pods en Running, endpoints con 2 IPs. El problema no está ahí.
#
# 2. Inspeccionar el Ingress:
#      kubectl -n ckad-53-ingress-lab get ingress hello-ingress-rules -o yaml
#      kubectl -n ckad-53-ingress-lab describe ingress hello-ingress-rules
#    -> spec.rules[0].host aparece como "hello.ckad.tset" en vez de
#       "hello.ckad.test". Como el Host header que se está probando no
#       coincide con ninguna regla del Ingress, el ingress controller
#       enruta la petición al "default backend" (típicamente 404).
#
# 3. Reproducir el síntoma explícitamente:
#      curl -i -H "Host: hello.ckad.test" http://<IP>/     -> 404 default backend
#      curl -i -H "Host: hello.ckad.tset" http://<IP>/     -> 200 (host roto, no es el que pide el enunciado)
#
# 4. Causa raíz: el campo host de la regla de enrutamiento del Ingress
#    (topic "Ingress rules") no coincide con el host esperado por los
#    clientes/tests, así que ninguna regla matchea la petición real.
#
# 5. Fix (elegí una):
#      kubectl -n ckad-53-ingress-lab patch ingress hello-ingress-rules \
#        --type='json' \
#        -p='[{"op":"replace","path":"/spec/rules/0/host","value":"hello.ckad.test"}]'
#
#    o editando interactivamente:
#      kubectl -n ckad-53-ingress-lab edit ingress hello-ingress-rules
#      # cambiar spec.rules[0].host de "hello.ckad.tset" a "hello.ckad.test"
#
# 6. Verificación:
#      kubectl -n ckad-53-ingress-lab get ingress hello-ingress-rules
#      curl -i -H "Host: hello.ckad.test" http://<IP>/
#    -> Debe responder "HTTP/1.1 200 OK" con cuerpo "OK - CKAD 5.3 Ingress Lab".
#
# 7. Limpieza del laboratorio:
#      kubectl delete namespace ckad-53-ingress-lab
# ================================================================