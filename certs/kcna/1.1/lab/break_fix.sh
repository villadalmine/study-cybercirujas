#!/usr/bin/env bash
#
# break-fix: KCNA - Tema 1.1 Kubernetes Core Concepts (peso examen: 44%)
# Escenario: Labels & Selectors / Services / Endpoints
#
# ADVERTENCIA: este script modifica el cluster apuntado por tu kubeconfig actual.
# Ejecutalo SOLO contra una VM de laboratorio descartable (kind/minikube/k3d),
# nunca contra un cluster real. Todo lo que crea vive en un namespace dedicado
# para poder limpiarlo con un solo comando.

set -euo pipefail

NAMESPACE="kcna-lab-1-1"
APP_LABEL="kcna-demo"
SVC_NAME="kcna-demo-svc"
DEPLOY_NAME="kcna-demo-deploy"

info()  { echo -e "\n[INFO] $*"; }
warn()  { echo -e "\n[WARN] $*"; }
step()  { echo -e "\n=== $* ==="; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] falta el comando '$1' en PATH."; exit 1; }
}

require_cmd kubectl

CURRENT_CTX="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
warn "Contexto de kubectl actual: '${CURRENT_CTX}'."
warn "Confirmá que esta es una VM/cluster de laboratorio DESCARTABLE antes de continuar."
read -r -p "Escribí 'si' para continuar: " CONFIRM
if [[ "${CONFIRM}" != "si" ]]; then
  echo "Cancelado por el usuario."
  exit 1
fi

step "1. Preparando entorno de laboratorio (namespace '${NAMESPACE}')"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

step "2. Desplegando Deployment + Service de referencia"
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  labels:
    app: ${APP_LABEL}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_LABEL}
  template:
    metadata:
      labels:
        app: ${APP_LABEL}
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
spec:
  selector:
    app: ${APP_LABEL}
  ports:
    - port: 80
      targetPort: 80
EOF

info "Esperando a que el Deployment esté listo..."
kubectl -n "${NAMESPACE}" rollout status deployment/"${DEPLOY_NAME}" --timeout=120s

step "3. Verificando que el Service enruta tráfico correctamente (estado sano)"
kubectl -n "${NAMESPACE}" get endpoints "${SVC_NAME}"
info "Si ves IPs listadas arriba (no <none>), el entorno está sano. Continuamos con la rotura."
sleep 2

step "4. ROMPIENDO el entorno de forma controlada"
# Se modifica el selector del Service para que ya no coincida con los labels
# de los Pods del Deployment. Esto es 100% reversible y no toca el Deployment.
kubectl -n "${NAMESPACE}" patch service "${SVC_NAME}" \
  --type merge \
  -p "{\"spec\":{\"selector\":{\"app\":\"${APP_LABEL}-roto\"}}}"

info "Rotura aplicada."

step "5. SÍNTOMA que vas a observar"
cat <<'EOF'
El Deployment sigue corriendo (kubectl get pods lo va a mostrar como Running,
2/2), pero el Service dejó de enrutar tráfico hacia esos Pods.

Comandos para reproducir el síntoma:
  kubectl -n kcna-lab-1-1 get pods
  kubectl -n kcna-lab-1-1 get endpoints kcna-demo-svc
  kubectl -n kcna-lab-1-1 run tmp-client --rm -it --restart=Never \
      --image=busybox -- wget -qO- --timeout=3 kcna-demo-svc

Vas a ver que 'get endpoints' devuelve ENDPOINTS = <none>, y el wget desde
el Pod cliente se queda colgado hasta el timeout (connection timed out).
EOF

step "6. Tu objetivo"
cat <<'EOF'
Diagnosticar por qué el Service "kcna-demo-svc" no tiene Endpoints a pesar
de que el Deployment "kcna-demo-deploy" tiene sus Pods en estado Running, y
corregirlo usando SOLO kubectl (sin borrar ni recrear ningún objeto).

Pistas de comandos útiles para el diagnóstico:
  kubectl -n kcna-lab-1-1 get pods --show-labels
  kubectl -n kcna-lab-1-1 describe svc kcna-demo-svc
  kubectl -n kcna-lab-1-1 get deployment kcna-demo-deploy -o yaml

Vas a saber que lo resolviste cuando 'kubectl get endpoints kcna-demo-svc'
muestre las IPs de los 2 Pods y el wget de prueba devuelva el HTML de nginx.

Limpieza del laboratorio (cuando termines):
  kubectl delete namespace kcna-lab-1-1
EOF

# ---------------------------------------------------------------------------
# SOLUCIÓN (spoiler - no leer hasta intentar resolverlo vos mismo/a)
# ---------------------------------------------------------------------------
#
# 1. Confirmar que los Pods están sanos y ver sus labels reales:
#      kubectl -n kcna-lab-1-1 get pods --show-labels
#    -> deberías ver "app=kcna-demo" en los labels de los Pods.
#
# 2. Inspeccionar el selector configurado en el Service:
#      kubectl -n kcna-lab-1-1 describe svc kcna-demo-svc
#    -> el campo "Selector" muestra "app=kcna-demo-roto", que no coincide
#       con el label real de los Pods ("app=kcna-demo"). Esta es la causa
#       raíz: un Service enruta tráfico usando un selector de labels contra
#       los Pods del cluster (vía el objeto Endpoints/EndpointSlice); si el
#       selector no matchea ningún Pod, el Service queda sin backends.
#
# 3. Corregir el selector del Service para que coincida con el label real:
#      kubectl -n kcna-lab-1-1 patch service kcna-demo-svc \
#        --type merge -p '{"spec":{"selector":{"app":"kcna-demo"}}}'
#
#    (alternativa equivalente: kubectl -n kcna-lab-1-1 edit svc kcna-demo-svc
#     y corregir manualmente el valor bajo "spec.selector.app")
#
# 4. Verificar que el Service recuperó sus Endpoints:
#      kubectl -n kcna-lab-1-1 get endpoints kcna-demo-svc
#    -> ahora debería listar las 2 IPs de los Pods en el puerto 80.
#
# 5. Confirmar el tráfico end-to-end:
#      kubectl -n kcna-lab-1-1 run tmp-client --rm -it --restart=Never \
#        --image=busybox -- wget -qO- --timeout=3 kcna-demo-svc
#    -> debería devolver el HTML de bienvenida de nginx.
#
# 6. Limpiar el laboratorio:
#      kubectl delete namespace kcna-lab-1-1
# ---------------------------------------------------------------------------