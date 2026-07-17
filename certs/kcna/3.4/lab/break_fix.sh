#!/usr/bin/env bash
#
# KCNA - Dominio: Cloud Native Architecture
# Tema 3.4 Networking (peso en el examen: 4)
# Break & Fix: Service sin Endpoints por selector mal configurado
#
# Fuente de referencia (curriculum oficial, solo como contexto):
#   https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# Qué enseña este lab:
#   El selector de un Service en Kubernetes hace match contra los labels
#   de los Pods usando AND logico (todas las keys deben coincidir, no
#   alguna). Si el selector no matchea ningun Pod, el Service se queda
#   sin Endpoints y deja de rutear trafico, aunque el Service, el
#   Deployment y los Pods figuren todos como "corriendo" sin errores.
#
# Requisitos:
#   - kubectl apuntando a un cluster DESCARTABLE (kind/minikube/k3d) en
#     esta VM de laboratorio. No corras esto contra un cluster real.
#   - El lab se aisla en su propio namespace y no toca nada fuera de el.

set -euo pipefail

NAMESPACE="kcna-net-lab"
DEPLOY_NAME="web"
SVC_NAME="web-svc"
CLIENT_POD="client"

log()  { printf '\n\033[1;34m[lab]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "No se encontro kubectl en el PATH."
kubectl cluster-info >/dev/null 2>&1 || die "kubectl no puede contactar ningun cluster. Levanta tu cluster de lab (kind/minikube) antes de correr esto."

CTX="$(kubectl config current-context 2>/dev/null || echo '?')"
warn "Este script va a crear/romper recursos en el namespace '$NAMESPACE'"
warn "del contexto de kubectl actual: '$CTX'"
warn "Confirma que este es un cluster de laboratorio DESCARTABLE."
read -r -p "Escribi 'si' para continuar: " CONFIRM
[ "$CONFIRM" = "si" ] || die "Cancelado por el usuario."

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  die "El namespace '$NAMESPACE' ya existe. Corre 'kubectl delete namespace $NAMESPACE' y volve a intentar."
fi

log "Creando namespace aislado '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" >/dev/null

log "Desplegando Deployment '$DEPLOY_NAME' (2 replicas) y Service '$SVC_NAME'..."
kubectl apply -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
      tier: frontend
  template:
    metadata:
      labels:
        app: web
        tier: frontend
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: $SVC_NAME
spec:
  selector:
    app: web
    tier: frontend
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: $CLIENT_POD
  labels:
    role: test-client
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sleep", "infinity"]
EOF

log "Esperando a que el Deployment y el pod cliente esten listos..."
kubectl rollout status deployment/"$DEPLOY_NAME" -n "$NAMESPACE" --timeout=120s
kubectl wait --for=condition=Ready pod/"$CLIENT_POD" -n "$NAMESPACE" --timeout=60s >/dev/null

log "Probando conectividad ANTES de romper nada (deberia funcionar)..."
if kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- wget -qO- --timeout=5 "http://$SVC_NAME" >/dev/null 2>&1; then
  echo "OK: el pod cliente puede llegar a http://$SVC_NAME"
else
  die "La conectividad baseline ya esta rota antes de aplicar el fallo. Revisa el cluster."
fi

log "Rompiendo algo... (patch silencioso al Service)"
kubectl patch svc "$SVC_NAME" -n "$NAMESPACE" \
  --type merge -p '{"spec":{"selector":{"app":"web","tier":"backend"}}}' >/dev/null

cat <<'MSG'

================================================================
 SINTOMA
================================================================
El Deployment sigue con sus Pods en estado Running (nada crasheo).
El Service tampoco muestra errores en su definicion.
Pero ahora, si corres:

    kubectl exec -n kcna-net-lab client -- wget -qO- --timeout=5 http://web-svc

el pedido va a fallar (timeout o "connection refused", segun el modo
de kube-proxy: iptables o ipvs). La resolucion DNS del nombre
"web-svc" funciona bien (el Service existe), el problema esta en el
routing hacia los Pods.

================================================================
 TU MISION
================================================================
Sin borrar ni recrear el Service ni el Deployment, restablece la
conectividad entre el pod "client" y el Service "web-svc" en el
namespace "kcna-net-lab".

Pistas de comandos utiles para diagnosticar (no son la solucion,
son punto de partida):
  kubectl get endpoints web-svc -n kcna-net-lab
  kubectl get svc web-svc -n kcna-net-lab -o yaml
  kubectl get pods -n kcna-net-lab --show-labels

Cuando creas que lo arreglaste, valida con:
  kubectl get endpoints web-svc -n kcna-net-lab
  kubectl exec -n kcna-net-lab client -- wget -qO- --timeout=5 http://web-svc

Si el segundo comando imprime el HTML de bienvenida de nginx, gano.

Para limpiar el lab al terminar:
  kubectl delete namespace kcna-net-lab

================================================================
MSG

exit 0

# ================================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
# ================================================================
#
# 1. Diagnosticar que el Service no tiene backends:
#      kubectl get endpoints web-svc -n kcna-net-lab
#    -> la columna ENDPOINTS aparece vacia (<none>), a pesar de que
#       los Pods del Deployment estan Running. Esto confirma que el
#       problema es el selector del Service, no los Pods.
#
# 2. Comparar el selector del Service contra los labels reales de
#    los Pods:
#      kubectl get svc web-svc -n kcna-net-lab -o jsonpath='{.spec.selector}{"\n"}'
#      kubectl get pods -n kcna-net-lab -l app=web --show-labels
#    -> el Service pide app=web Y tier=backend (AND), pero los Pods
#       tienen tier=frontend. Como el selector matchea con AND logico,
#       alcanza con que UNA sola key no coincida para que ningun Pod
#       cumpla la condicion completa.
#
# 3. Corregir el selector para que coincida con los labels reales
#    del Pod template del Deployment:
#      kubectl patch svc web-svc -n kcna-net-lab \
#        --type merge -p '{"spec":{"selector":{"app":"web","tier":"frontend"}}}'
#
# 4. Verificar que el Service recupero sus Endpoints:
#      kubectl get endpoints web-svc -n kcna-net-lab
#    -> deberia listar las IPs de los 2 Pods del Deployment en el
#       puerto 80.
#
# 5. Re-testear conectividad desde el pod cliente:
#      kubectl exec -n kcna-net-lab client -- wget -qO- --timeout=5 http://web-svc
#    -> deberia devolver el HTML por defecto de nginx.
#
# Nota conceptual: un Service en Kubernetes no "sabe" a que Pods
# apunta por nombre; kube-proxy programa las reglas de red (iptables/
# ipvs) a partir del objeto Endpoints (o EndpointSlice), que a su vez
# el control plane arma automaticamente matcheando spec.selector del
# Service contra los labels de los Pods. Un Service sin selector
# valido para ningun Pod es un Service "vivo" pero sin ningun backend
# real detras: ni el objeto ni los Pods reportan error alguno, por
# eso este tipo de falla es dificil de detectar sin revisar
# especificamente el objeto Endpoints.