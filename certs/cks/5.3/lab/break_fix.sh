#!/usr/bin/env bash
#
# CKS 1.34 - Dominio 5 (System Hardening) - Tema 5.3
# "Minimize external access to the network"
# Peso en el examen: 2.5
#
# Fuente de referencia (curriculum oficial, no se copia texto literal):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Este script es un laboratorio "break & fix". Ejecutalo SOLO en una VM
# descartable con un cluster de un solo nodo (kind/minikube/k3d) donde
# tengas permisos de cluster-admin. No lo corras contra nada productivo.
#
# Uso:
#   ./cks-5.3-break-fix.sh break     -> rompe el escenario y explica el objetivo
#   ./cks-5.3-break-fix.sh verify    -> chequea si ya lo arreglaste
#   ./cks-5.3-break-fix.sh clean     -> borra todo lo creado por el lab
#
set -euo pipefail

NS="cks-53-lab"
APP_DEPLOY="internal-api"
APP_SVC="internal-api-svc"
NODEPORT=30531

usage() {
  echo "Uso: $0 {break|verify|clean}"
  exit 1
}

preflight() {
  command -v kubectl >/dev/null 2>&1 || { echo "Falta kubectl en el PATH."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "No hay un cluster accesible con el kubeconfig actual."; exit 1; }
  echo "Contexto actual: $(kubectl config current-context)"
  read -r -p "Confirmás que este es un cluster de laboratorio descartable? (escribi 'si'): " ans
  [ "$ans" = "si" ] || { echo "Cancelado."; exit 1; }
}

do_break() {
  preflight

  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_DEPLOY
  labels:
    app: $APP_DEPLOY
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP_DEPLOY
  template:
    metadata:
      labels:
        app: $APP_DEPLOY
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: $APP_SVC
spec:
  type: NodePort
  selector:
    app: $APP_DEPLOY
  ports:
    - port: 80
      targetPort: 80
      nodePort: $NODEPORT
EOF

  kubectl -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  labels:
    app: attacker
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend-client
  labels:
    app: frontend-client
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
EOF

  echo "Esperando a que los pods estén Ready..."
  kubectl -n "$NS" wait --for=condition=Ready pod -l app=attacker --timeout=90s >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready pod -l app=frontend-client --timeout=90s >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready pod -l app="$APP_DEPLOY" --timeout=90s >/dev/null

  echo
  echo "=================================================================="
  echo " ESCENARIO ROTO - namespace '$NS'"
  echo "=================================================================="
  echo "Se desplegó '$APP_DEPLOY', una API interna que NO debería tener"
  echo "acceso desde fuera del cluster ni desde cualquier pod al azar."
  echo
  echo "Síntoma 1 (exposición externa):"
  echo "  El Service '$APP_SVC' es type=NodePort en el puerto $NODEPORT."
  echo "  Eso significa que cualquier cliente con red hacia el nodo -sin"
  echo "  pasar por el cluster- puede llegar a la API. Probalo vos mismo:"
  echo "    curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$NODEPORT/"
  echo "  (si el nodo es local, ese curl debería responder 200)"
  echo
  echo "Síntoma 2 (falta de segmentación este-oeste):"
  echo "  No hay ninguna NetworkPolicy en '$NS'. Cualquier pod del cluster,"
  echo "  tenga o no relación con esta app, puede llegar a ella:"
  echo "    kubectl -n $NS exec attacker -- curl -s -o /dev/null -w '%{http_code}\n' http://$APP_SVC/"
  echo "  ese pod 'attacker' no debería tener ninguna razón para hablarle"
  echo "  a $APP_DEPLOY, y sin embargo responde 200."
  echo
  echo "OBJETIVO:"
  echo "  1) Sacar la exposición externa innecesaria: el Service '$APP_SVC'"
  echo "     debe pasar a type=ClusterIP (nada de NodePort/LoadBalancer)."
  echo "  2) Crear una NetworkPolicy en '$NS' que:"
  echo "     - aplique default-deny de ingress a todo el namespace, y"
  echo "     - permita ingress hacia pods con label app=$APP_DEPLOY"
  echo "       ÚNICAMENTE desde pods con label app=frontend-client"
  echo "       dentro del mismo namespace."
  echo "  3) Al terminar, 'attacker' debe fallar (timeout/connection refused)"
  echo "     y 'frontend-client' debe seguir obteniendo 200."
  echo
  echo "Corré '$0 verify' cuando creas que lo resolviste."
  echo "=================================================================="
}

do_verify() {
  preflight

  ok=1

  svc_type=$(kubectl -n "$NS" get svc "$APP_SVC" -o jsonpath='{.spec.type}' 2>/dev/null || echo "MISSING")
  if [ "$svc_type" = "ClusterIP" ]; then
    echo "[OK] $APP_SVC es ClusterIP."
  else
    echo "[FALTA] $APP_SVC sigue siendo '$svc_type', tiene que ser ClusterIP."
    ok=0
  fi

  netpol_count=$(kubectl -n "$NS" get networkpolicy -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "$netpol_count" -gt 0 ]; then
    echo "[OK] Hay $netpol_count NetworkPolicy(s) en $NS."
  else
    echo "[FALTA] No hay ninguna NetworkPolicy en $NS."
    ok=0
  fi

  echo "Probando conectividad real..."
  if kubectl -n "$NS" exec attacker -- curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$APP_SVC/" 2>/dev/null | grep -q '^200$'; then
    echo "[FALTA] 'attacker' todavía puede llegar a $APP_DEPLOY (debería estar bloqueado)."
    ok=0
  else
    echo "[OK] 'attacker' ya no puede llegar a $APP_DEPLOY."
  fi

  if kubectl -n "$NS" exec frontend-client -- curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$APP_SVC/" 2>/dev/null | grep -q '^200$'; then
    echo "[OK] 'frontend-client' sigue teniendo acceso legítimo."
  else
    echo "[FALTA] 'frontend-client' debería poder llegar a $APP_DEPLOY y no puede."
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    echo "Todo correcto. Escenario resuelto."
  else
    echo "Todavía falta algo. Revisá los puntos marcados [FALTA]."
  fi
}

do_clean() {
  preflight
  kubectl delete namespace "$NS" --ignore-not-found
  echo "Namespace $NS eliminado."
}

case "${1:-}" in
  break) do_break ;;
  verify) do_verify ;;
  clean) do_clean ;;
  *) usage ;;
esac

# ==================================================================
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# ==================================================================
#
# 1) Sacar la exposición externa: cambiar el Service a ClusterIP.
#    (NodePort/LoadBalancer solo deben usarse cuando el servicio
#    realmente necesita ser alcanzable desde fuera del cluster)
#
#   kubectl -n cks-53-lab patch svc internal-api-svc \
#     -p '{"spec":{"type":"ClusterIP"},"$deleteFromPrimitiveList/ports":[]}' 2>/dev/null || true
#
#   # más simple y confiable: reemplazar el Service entero
#   kubectl -n cks-53-lab apply -f - <<'EOF2'
#   apiVersion: v1
#   kind: Service
#   metadata:
#     name: internal-api-svc
#   spec:
#     type: ClusterIP
#     selector:
#       app: internal-api
#     ports:
#       - port: 80
#         targetPort: 80
#   EOF2
#
# 2) Aplicar default-deny de ingress a todo el namespace, y después
#    una policy puntual que habilite solo el tráfico legítimo.
#    El default-deny es clave: sin un podSelector: {} que cubra todo
#    el namespace, cualquier pod nuevo nace con acceso irrestricto.
#
#   kubectl -n cks-53-lab apply -f - <<'EOF2'
#   apiVersion: networking.k8s.io/v1
#   kind: NetworkPolicy
#   metadata:
#     name: default-deny-ingress
#   spec:
#     podSelector: {}
#     policyTypes:
#       - Ingress
#   ---
#   apiVersion: networking.k8s.io/v1
#   kind: NetworkPolicy
#   metadata:
#     name: allow-frontend-to-internal-api
#   spec:
#     podSelector:
#       matchLabels:
#         app: internal-api
#     policyTypes:
#       - Ingress
#     ingress:
#       - from:
#           - podSelector:
#               matchLabels:
#                 app: frontend-client
#         ports:
#           - protocol: TCP
#             port: 80
#   EOF2
#
# 3) Verificar:
#
#   kubectl -n cks-53-lab exec attacker -- curl -m 5 http://internal-api-svc/
#     -> debe fallar (timeout, el default-deny bloquea el ingress)
#
#   kubectl -n cks-53-lab exec frontend-client -- curl -m 5 http://internal-api-svc/
#     -> debe responder 200 (matchea el podSelector de la policy)
#
#   kubectl -n cks-53-lab get svc internal-api-svc -o jsonpath='{.spec.type}'
#     -> debe imprimir "ClusterIP"
#
# Notas conceptuales para el estudiante:
#   - El CNI del cluster tiene que soportar NetworkPolicy (Calico, Cilium,
#     Weave Net, etc.). El CNI "bridge" por default de algunos kind/minikube
#     puede no aplicarlas: si 'verify' sigue fallando después de aplicar
#     todo esto, comprobar el CNI antes de sospechar de la policy.
#   - "Minimize external access to the network" no es solo NetworkPolicy:
#     también incluye no exponer Services más allá de lo necesario
#     (NodePort/LoadBalancer solo si hace falta), restringir el rango de
#     IPs que puede hablarle al API server, y bloquear egress hacia
#     endpoints sensibles como el metadata service de la nube
#     (169.254.169.254) para mitigar SSRF.