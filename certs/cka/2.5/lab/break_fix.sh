#!/usr/bin/env bash
#
# CKA v1.35 - Tema 2.5: Troubleshoot services and networking (peso 6%)
# Break & Fix lab - ejecutar SOLO en una VM de laboratorio descartable
# con acceso a un cluster de prueba (kind/minikube/k3s), nunca en un
# cluster real o compartido.
#
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf

set -euo pipefail

LAB_NS="cka-topic25-lab"
DEPLOY_NAME="web"
SVC_NAME="web-svc"
CLIENT_POD="net-debug"

log()  { echo -e "\n>>> $*\n"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail "kubectl no está en el PATH"
kubectl cluster-info >/dev/null 2>&1 || fail "no hay un cluster accesible via kubectl"

CTX="$(kubectl config current-context 2>/dev/null || echo desconocido)"
echo "Contexto actual de kubectl: ${CTX}"
echo "Este script crea recursos, rompe un Service a propósito y lo deja"
echo "para que lo diagnostiques y arregles. Ejecutalo SOLO en un cluster"
echo "de laboratorio descartable."
read -r -p "Escribí 'romper' para continuar: " CONFIRM
[ "${CONFIRM}" = "romper" ] || fail "cancelado por el usuario"

log "Preparando namespace de laboratorio: ${LAB_NS}"
kubectl delete namespace "${LAB_NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl create namespace "${LAB_NS}"

log "Desplegando aplicación de referencia"
kubectl -n "${LAB_NS}" create deployment "${DEPLOY_NAME}" --image=nginx:1.27-alpine --replicas=2
kubectl -n "${LAB_NS}" rollout status deployment/"${DEPLOY_NAME}" --timeout=120s

log "Exponiendo el deployment como Service ClusterIP"
kubectl -n "${LAB_NS}" expose deployment "${DEPLOY_NAME}" --name="${SVC_NAME}" --port=80 --target-port=80

log "Desplegando pod cliente para pruebas de red"
kubectl -n "${LAB_NS}" run "${CLIENT_POD}" --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n "${LAB_NS}" wait --for=condition=Ready pod/"${CLIENT_POD}" --timeout=60s

log "Verificando que todo funciona ANTES de romper nada"
kubectl -n "${LAB_NS}" exec "${CLIENT_POD}" -- wget -q -T 5 -O- "http://${SVC_NAME}" >/dev/null \
  && echo "Baseline OK: el Service responde correctamente" \
  || fail "el baseline ya falla, revisá el cluster antes de continuar"

log "Rompiendo el Service..."
kubectl -n "${LAB_NS}" patch service "${SVC_NAME}" --type merge \
  -p '{"spec":{"selector":{"app":"web-DOES-NOT-EXIST"}}}'

cat <<EOF

================================================================
SINTOMA PARA EL ESTUDIANTE
================================================================
Namespace: ${LAB_NS}

El pod cliente "${CLIENT_POD}" ya no puede llegar a la app a
través del Service "${SVC_NAME}":

  kubectl -n ${LAB_NS} exec ${CLIENT_POD} -- wget -q -T 5 -O- http://${SVC_NAME}

Ese comando va a colgarse o devolver timeout / connection refused.
Los Pods de la aplicación siguen Running y Ready; el problema no
está en el Deployment.

OBJETIVO
--------
Diagnosticá por qué el Service dejó de enrutar tráfico a los Pods
y arreglalo, SIN borrar ni recrear el Service ni el Deployment.

Comandos que te pueden servir para investigar (no son la solución):
  kubectl -n ${LAB_NS} get endpoints ${SVC_NAME}
  kubectl -n ${LAB_NS} get endpointslices
  kubectl -n ${LAB_NS} describe service ${SVC_NAME}
  kubectl -n ${LAB_NS} get pods --show-labels

CRITERIO DE ÉXITO
------------------
1) Este comando debe devolver el HTML de nginx sin error:
     kubectl -n ${LAB_NS} exec ${CLIENT_POD} -- wget -q -T 5 -O- http://${SVC_NAME}

2) Este comando debe listar 2 IPs de Pod (una por réplica):
     kubectl -n ${LAB_NS} get endpoints ${SVC_NAME}
================================================================
EOF

# ================================================================
# SOLUCIÓN PASO A PASO (no leer antes de intentarlo)
# ================================================================
#
# 1. Confirmar el síntoma: el Service no tiene endpoints.
#      kubectl -n cka-topic25-lab get endpoints web-svc
#    -> La columna ENDPOINTS aparece vacía (<none>), lo que indica
#       que ningún Pod matchea el selector del Service.
#
# 2. Comparar el selector del Service contra las labels reales
#    de los Pods:
#      kubectl -n cka-topic25-lab get service web-svc -o jsonpath='{.spec.selector}{"\n"}'
#      kubectl -n cka-topic25-lab get pods --show-labels
#    -> El Service selecciona "app=web-DOES-NOT-EXIST", pero los
#       Pods tienen la label "app=web" (heredada del Deployment).
#       Ese mismatch es la causa raíz.
#
# 3. Corregir el selector para que coincida con las labels reales
#    de los Pods:
#      kubectl -n cka-topic25-lab patch service web-svc --type merge \
#        -p '{"spec":{"selector":{"app":"web"}}}'
#
# 4. Verificar que los endpoints se repueblan:
#      kubectl -n cka-topic25-lab get endpoints web-svc
#    -> Debe mostrar 2 IPs (una por Pod) en el puerto 80.
#
# 5. Confirmar que el tráfico llega de nuevo:
#      kubectl -n cka-topic25-lab exec net-debug -- wget -q -T 5 -O- http://web-svc
#    -> Debe devolver el HTML por defecto de nginx.
#
# Limpieza del laboratorio:
#      kubectl delete namespace cka-topic25-lab
# ================================================================