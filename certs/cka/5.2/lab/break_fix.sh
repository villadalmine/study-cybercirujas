#!/usr/bin/env bash
#
# break-fix: CKA v1.35 - Tema 5.2 "Define and enforce Network Policies" (peso: 3.33%)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable con un cluster
# Kubernetes cuyo CNI soporte NetworkPolicy (Calico, Cilium, etc). Si el cluster
# usa un CNI que no aplica NetworkPolicy (por ejemplo kindnet por defecto), el
# ejercicio no va a reproducir el síntoma esperado.
#
# Este script NO borra nada fuera del namespace que crea. Al terminar el
# ejercicio podés eliminar todo con:
#   kubectl delete namespace <namespace-impreso-al-final>

set -euo pipefail

NAMESPACE="netpol-breakfix-${RANDOM}"
BACKEND_LABEL_KEY="app"
BACKEND_LABEL_VAL="backend"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[lab]\033[0m %s\n' "$*"; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl no está en el PATH"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "No se puede contactar al cluster actual (kubectl context)"; exit 1; }

if ! kubectl get pods -n kube-system 2>/dev/null | grep -qiE 'calico|cilium|antrea|weave'; then
  warn "No se detectó un CNI conocido que soporte NetworkPolicy en kube-system."
  warn "Si tu CNI no la aplica, este ejercicio no va a reproducir el bloqueo esperado."
fi

log "Creando namespace descartable: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" >/dev/null

log "Desplegando backend (nginx) + Service ClusterIP en puerto 80"
kubectl -n "${NAMESPACE}" create deployment backend --image=nginx:1.27-alpine >/dev/null
kubectl -n "${NAMESPACE}" label deployment backend "${BACKEND_LABEL_KEY}=${BACKEND_LABEL_VAL}" --overwrite >/dev/null
kubectl -n "${NAMESPACE}" expose deployment backend --name=backend-svc --port=80 --target-port=80 >/dev/null

log "Desplegando cliente 'frontend' (autorizado) y cliente 'other' (no autorizado)"
kubectl -n "${NAMESPACE}" create deployment frontend --image=curlimages/curl:8.10.1 -- sleep 3600 >/dev/null
kubectl -n "${NAMESPACE}" label deployment frontend app=frontend --overwrite >/dev/null

kubectl -n "${NAMESPACE}" create deployment other --image=curlimages/curl:8.10.1 -- sleep 3600 >/dev/null
kubectl -n "${NAMESPACE}" label deployment other app=other --overwrite >/dev/null

log "Esperando a que los pods estén Ready..."
kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout=90s >/dev/null
kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout=90s >/dev/null
kubectl -n "${NAMESPACE}" rollout status deployment/other --timeout=90s >/dev/null

log "Aplicando NetworkPolicy (esta es la parte 'break')"
cat <<EOF | kubectl apply -n "${NAMESPACE}" -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-frontend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: front-end
      ports:
        - protocol: TCP
          port: 80
EOF

log "Demostrando el síntoma (esto puede tardar unos segundos por el timeout de curl)..."
FRONTEND_POD=$(kubectl -n "${NAMESPACE}" get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')
set +e
kubectl -n "${NAMESPACE}" exec "${FRONTEND_POD}" -- curl -s -m 5 -o /dev/null -w 'frontend -> backend-svc: HTTP %{http_code}\n' http://backend-svc
set -e

cat <<MSG

====================================================================
 SÍNTOMA
====================================================================
El pod "frontend" (label app=frontend) NO puede conectarse a
"backend-svc:80", aunque debería estar autorizado. El curl anterior
se cuelga o termina en timeout / código 000.

====================================================================
 OBJETIVO
====================================================================
Namespace de trabajo: ${NAMESPACE}

Hay una NetworkPolicy llamada "backend-allow-frontend" que debería
permitir tráfico de ingress hacia los pods "backend" (app=backend)
únicamente desde los pods "frontend" (app=frontend), puerto 80/TCP,
y bloquear cualquier otro origen (incluido el pod "other").

Tu tarea: corregir la NetworkPolicy para que se cumplan AMBAS
condiciones al mismo tiempo:

  1. El pod "frontend" SÍ puede llegar a backend-svc:80.
  2. El pod "other" NO puede llegar a backend-svc:80 (debe seguir
     bloqueado; no vale borrar la policy ni convertirla en un
     allow-all).

Comandos útiles para diagnosticar:
  kubectl -n ${NAMESPACE} get networkpolicy backend-allow-frontend -o yaml
  kubectl -n ${NAMESPACE} get pods --show-labels
  kubectl -n ${NAMESPACE} exec <pod> -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://backend-svc

Verificación final esperada:
  kubectl -n ${NAMESPACE} exec deploy/frontend -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://backend-svc
    -> 200
  kubectl -n ${NAMESPACE} exec deploy/other -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://backend-svc
    -> timeout / 000

Cuando termines, limpiá el namespace:
  kubectl delete namespace ${NAMESPACE}
====================================================================

MSG

exit 0

# ====================================================================
# SOLUCIÓN (no leer hasta intentar resolverlo por tu cuenta)
# ====================================================================
#
# 1. Inspeccionar la policy aplicada:
#      kubectl -n <namespace> get networkpolicy backend-allow-frontend -o yaml
#
#    El bug está en spec.ingress[0].from[0].podSelector.matchLabels:
#    la policy selecciona "app: front-end" pero el pod frontend real
#    tiene la label "app: frontend" (con guion vs sin guion). Como
#    ningún pod matchea ese selector, el ingress rule nunca se
#    cumple y, al haber un podSelector que matchea al backend con
#    policyTypes: [Ingress], TODO el tráfico entrante queda denegado
#    por defecto (deny-all implícito de NetworkPolicy).
#
# 2. Confirmar las labels reales:
#      kubectl -n <namespace> get pods --show-labels
#
# 3. Corregir el selector (opción con patch JSON):
#      kubectl -n <namespace> patch networkpolicy backend-allow-frontend \
#        --type='json' \
#        -p='[{"op":"replace","path":"/spec/ingress/0/from/0/podSelector/matchLabels/app","value":"frontend"}]'
#
#    o editando directamente:
#      kubectl -n <namespace> edit networkpolicy backend-allow-frontend
#      # cambiar "app: front-end" por "app: frontend" bajo ingress[0].from[0].podSelector.matchLabels
#
# 4. Verificar que "frontend" ahora pasa:
#      kubectl -n <namespace> exec deploy/frontend -- \
#        curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://backend-svc
#      # esperado: 200
#
# 5. Verificar que "other" sigue bloqueado (la policy no se volvió allow-all):
#      kubectl -n <namespace> exec deploy/other -- \
#        curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://backend-svc
#      # esperado: timeout / 000
#
# 6. Si en el paso 3 se hubiera borrado la NetworkPolicy en lugar de
#    corregirla, el paso 4 pasaría, pero el paso 5 también pasaría
#    (mal) porque "other" dejaría de estar bloqueado: eso NO es una
#    solución válida para este ejercicio, porque el requisito es
#    "define and enforce" la policy correcta, no eliminar el control.
#
# 7. Limpieza:
#      kubectl delete namespace <namespace>