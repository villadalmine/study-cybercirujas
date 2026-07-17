#!/usr/bin/env bash
#
# Break & Fix Lab - CKAD v1.35
# Dominio: Application Environment, Configuration and Security
# Tema 4.5 "Understand ConfigMaps" (peso en el examen: 3)
#
# Fuente de referencia (curricula oficial, usada solo para encuadrar el
# objetivo de examen, no se copia texto de ahí):
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Este script asume que se corre contra un cluster Kubernetes descartable
# (kind, minikube, k3d, etc.) en una VM de laboratorio. Crea un namespace
# aislado, despliega una app sana que consume ConfigMaps de tres formas
# distintas (envFrom, configMapKeyRef y volumen), y después rompe algo a
# propósito para que lo diagnostiques y arregles vos.
#
set -euo pipefail

NAMESPACE="ckad-445-configmaps"
CM_ENV="web-config"
CM_HTML="web-html"
DEPLOYMENT="web-app"

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: no se encontró kubectl en PATH." >&2; exit 1; }
}

confirm_lab_context() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "")"
  if [[ -z "$ctx" ]]; then
    echo "ERROR: no hay un contexto de kubectl activo." >&2
    exit 1
  fi
  case "$ctx" in
    kind-*|minikube|k3d-*|*lab*|*sandbox*|*disposable*)
      ;;
    *)
      if [[ "${FORCE:-0}" != "1" ]]; then
        echo "ADVERTENCIA: el contexto actual de kubectl es '$ctx' y no parece un lab descartable (kind/minikube/k3d)." >&2
        echo "Si estás seguro de que este cluster es descartable, volvé a ejecutar con FORCE=1." >&2
        exit 1
      fi
      ;;
  esac
  echo ">> Usando contexto de kubectl: $ctx"
}

reset_namespace() {
  echo ">> Preparando namespace '$NAMESPACE' (se recrea si ya existía)..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true >/dev/null
  kubectl create namespace "$NAMESPACE" >/dev/null
}

create_configmaps() {
  echo ">> Creando ConfigMap '$CM_ENV' desde literales..."
  kubectl -n "$NAMESPACE" create configmap "$CM_ENV" \
    --from-literal=APP_ENV=production \
    --from-literal=APP_COLOR=blue \
    --from-literal=WELCOME_MSG="Hola desde una env var de ConfigMap"

  echo ">> Creando ConfigMap '$CM_HTML' desde un archivo..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/index.html" <<'HTML'
<html>
  <body>
    <h1>CKAD 4.5 - ConfigMaps</h1>
    <p>Esta pagina se sirve desde un archivo montado como ConfigMap.</p>
  </body>
</html>
HTML
  kubectl -n "$NAMESPACE" create configmap "$CM_HTML" --from-file=index.html="$tmpdir/index.html"
  rm -rf "$tmpdir"
}

deploy_app() {
  echo ">> Desplegando '$DEPLOYMENT'..."
  kubectl -n "$NAMESPACE" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT
  labels:
    app: $DEPLOYMENT
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOYMENT
  template:
    metadata:
      labels:
        app: $DEPLOYMENT
    spec:
      containers:
        - name: web
          image: nginx:stable-alpine
          envFrom:
            - configMapRef:
                name: $CM_ENV
          env:
            - name: APP_COLOR_PINNED
              valueFrom:
                configMapKeyRef:
                  name: $CM_ENV
                  key: APP_COLOR
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          ports:
            - containerPort: 80
      volumes:
        - name: html
          configMap:
            name: $CM_HTML
---
apiVersion: v1
kind: Service
metadata:
  name: $DEPLOYMENT
spec:
  selector:
    app: $DEPLOYMENT
  ports:
    - port: 80
      targetPort: 80
YAML

  echo ">> Esperando a que el Deployment quede Ready (estado inicial sano)..."
  kubectl -n "$NAMESPACE" rollout status deployment/"$DEPLOYMENT" --timeout=90s
}

break_it() {
  echo
  echo "############################################################"
  echo "  Rompiendo el entorno de forma controlada..."
  echo "############################################################"
  kubectl -n "$NAMESPACE" patch configmap "$CM_ENV" --type=json -p='[
    {"op":"remove","path":"/data/APP_COLOR"},
    {"op":"add","path":"/data/APP_COLOUR","value":"blue"}
  ]' >/dev/null

  kubectl -n "$NAMESPACE" delete pod -l app="$DEPLOYMENT" --wait=true >/dev/null
}

print_briefing() {
  cat <<EOF

============================================================
 CKAD 4.5 - Understand ConfigMaps - Break & Fix
============================================================

Algo cambio en el namespace '$NAMESPACE' y el Deployment
'$DEPLOYMENT' dejo de estar sano. Dale unos segundos y mira:

  kubectl -n $NAMESPACE get pods

SINTOMA que vas a ver:
  El pod queda en un estado de error de arranque de contenedor.
  No es un crash de la app: el contenedor ni llega a arrancar.

QUE TENES QUE LOGRAR:
  1. Encontrar la causa raiz mirando los eventos del pod
     (pista: 'kubectl describe pod ...') y el contenido actual
     del ConfigMap '$CM_ENV' ('kubectl get configmap ... -o yaml').
  2. Corregir el ConfigMap SIN perder las otras keys que ya
     tiene (WELCOME_MSG, APP_ENV) ni romper las env vars que
     vienen del 'envFrom'.
  3. Lograr que el Deployment vuelva a quedar Ready:
     kubectl -n $NAMESPACE rollout status deployment/$DEPLOYMENT
  4. Confirmar que la env var correcta llega al contenedor:
     kubectl -n $NAMESPACE exec deploy/$DEPLOYMENT -- printenv | grep APP_COLOR

No hace falta borrar ni recrear el Deployment: el problema
esta en la configuracion, no en el workload.
============================================================
EOF
}

main() {
  require_kubectl
  confirm_lab_context
  reset_namespace
  create_configmaps
  deploy_app
  break_it
  print_briefing
}

main "$@"

# ============================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta automaticamente)
# ============================================================
#
# 1. Confirmar el sintoma:
#      kubectl -n ckad-445-configmaps get pods
#    -> el pod aparece como "CreateContainerConfigError".
#
# 2. Ver la causa exacta en los eventos:
#      kubectl -n ckad-445-configmaps describe pod -l app=web-app
#    -> el evento dice algo como:
#       "Error: couldn't find key APP_COLOR in ConfigMap
#        ckad-445-configmaps/web-config"
#
# 3. Confirmar mirando el ConfigMap:
#      kubectl -n ckad-445-configmaps get configmap web-config -o yaml
#    -> se ve que la key se llama "APP_COLOUR" (con error de tipeo) en
#       vez de "APP_COLOR", que es la que pide el 'configMapKeyRef'
#       explicito del Deployment. El 'envFrom' no rompe con esto (importa
#       cualquier key que exista), pero el 'configMapKeyRef' si, porque
#       apunta a una key puntual que ya no existe.
#
# 4. Arreglar el ConfigMap sin tocar las demas keys:
#      kubectl -n ckad-445-configmaps patch configmap web-config \
#        --type=json -p='[
#          {"op":"add","path":"/data/APP_COLOR","value":"blue"},
#          {"op":"remove","path":"/data/APP_COLOUR"}
#        ]'
#    (alternativa equivalente: kubectl -n ckad-445-configmaps edit configmap web-config)
#
# 5. Forzar que el pod tome la config corregida
#    (las env vars de un ConfigMap no se releen en caliente en un pod vivo):
#      kubectl -n ckad-445-configmaps delete pod -l app=web-app
#
# 6. Verificar que el Deployment queda sano:
#      kubectl -n ckad-445-configmaps rollout status deployment/web-app
#
# 7. Verificar que la env var llega bien al contenedor:
#      kubectl -n ckad-445-configmaps exec deploy/web-app -- printenv | grep APP_COLOR
#    -> deberia mostrar APP_COLOR=blue (via envFrom) y
#       APP_COLOR_PINNED=blue (via configMapKeyRef explicito).
#
# 8. (Opcional) Verificar el contenido servido desde el volumen:
#      kubectl -n ckad-445-configmaps port-forward svc/web-app 8080:80 &
#      curl -s localhost:8080 | grep "CKAD 4.5"
# ============================================================