#!/usr/bin/env bash
#
# ============================================================================
# break-fix-netpol.sh — CKAD v1.35 · Tema 5.1: NetworkPolicies (peso: 5)
# ============================================================================
#
# Ejercicio "break & fix": este script monta un mini-escenario en tu cluster
# de laboratorio, verifica que la red funciona, y despues la ROMPE de forma
# controlada aplicando NetworkPolicies mal configuradas. Tu trabajo es
# diagnosticar y arreglar.
#
# REQUISITOS (solo VM/cluster de laboratorio descartable):
#   - kubectl configurado contra un cluster de practica.
#   - Un CNI plugin que APLIQUE NetworkPolicies (Calico, Cilium, etc.).
#     OJO: el CNI por defecto de kind (kindnet) y algunos setups de minikube
#     NO las aplican: las policies se crean pero no bloquean nada. En ese
#     caso usa "minikube start --cni=calico" o un kind con Calico.
#
# SEGURIDAD: todo ocurre dentro del namespace "netpol-lab". No toca nada
# fuera de el. Limpieza total: kubectl delete namespace netpol-lab
#
# Fuentes de referencia (consultadas, no copiadas):
#   - CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#   - Kubernetes docs, Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
#
# ============================================================================

set -euo pipefail

NS="netpol-lab"

echo "============================================================"
echo " CKAD 5.1 — break & fix: NetworkPolicies"
echo "============================================================"
echo

# ----------------------------------------------------------------------------
# 0. Pre-checks
# ----------------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: no encuentro kubectl en el PATH. Aborto." >&2
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl no llega al cluster. Revisa tu kubeconfig. Aborto." >&2
  exit 1
fi

echo "[*] Cluster accesible. Preparando el escenario en el namespace '${NS}'..."

# Si quedo un intento anterior, lo borramos para arrancar limpio.
kubectl delete namespace "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# 1. Escenario: un backend (nginx + Service) y un frontend (busybox)
# ----------------------------------------------------------------------------
kubectl create namespace "${NS}" >/dev/null

kubectl apply -n "${NS}" -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: backend
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  labels:
    app: frontend
spec:
  containers:
  - name: box
    image: busybox:1.36
    command: ["sleep", "3600"]
EOF

echo "[*] Esperando a que los pods esten Ready..."
kubectl wait -n "${NS}" --for=condition=Available deployment/backend --timeout=120s >/dev/null
kubectl wait -n "${NS}" --for=condition=Ready pod/frontend --timeout=120s >/dev/null

# ----------------------------------------------------------------------------
# 2. Baseline: comprobamos que SIN policies la conexion funciona
# ----------------------------------------------------------------------------
echo "[*] Prueba de conectividad ANTES de romper nada:"
if kubectl exec -n "${NS}" frontend -- wget -qO- --timeout=3 http://backend >/dev/null 2>&1; then
  echo "    OK: el pod 'frontend' llega al Service 'backend' (HTTP 200)."
else
  echo "    ERROR: la conectividad base ya falla. Revisa el CNI del cluster antes de seguir." >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# 3. BREAK: aplicamos un default-deny y una policy de "allow" defectuosa
# ----------------------------------------------------------------------------
echo
echo "[*] Rompiendo la red de forma controlada..."

kubectl apply -n "${NS}" -f - <<'EOF' >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
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
          app: front
    ports:
    - protocol: TCP
      port: 8080
EOF

echo "[*] Listo. El escenario esta roto."

# ----------------------------------------------------------------------------
# 4. Instrucciones para el estudiante
# ----------------------------------------------------------------------------
cat <<'EOF'

============================================================
 TU MISION
============================================================

SINTOMA que vas a ver:
  El pod 'frontend' ya no puede hablar con el Service 'backend'.
  Comprobalo vos mismo:

    kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=3 http://backend

  Vas a obtener "wget: download timed out" (la conexion se cuelga,
  no hay "connection refused": el trafico se DESCARTA, sintoma tipico
  de una NetworkPolicy bloqueando ingress).

CONTEXTO:
  Alguien aplico un "default deny" de ingress en el namespace (eso es
  correcto y es una buena practica) y ademas una policy llamada
  'allow-frontend-to-backend' que DEBERIA permitir el trafico desde
  los pods con label app=frontend hacia los pods app=backend en el
  puerto 80/TCP... pero fue escrita con errores.

OBJETIVO (criterio de exito):
  1. NO borres 'default-deny-ingress': el deny por defecto debe quedar.
  2. Corregi la policy 'allow-frontend-to-backend' (tiene MAS DE UN error)
     para que este comando vuelva a devolver el HTML de nginx:

       kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=3 http://backend

PISTAS (mira solo si te trabas):
  - Pista 1: kubectl describe networkpolicy allow-frontend-to-backend -n netpol-lab
             y compara los labels que exige la policy con los labels
             reales de los pods (kubectl get pods -n netpol-lab --show-labels).
  - Pista 2: 'port' en una NetworkPolicy se refiere al puerto del POD
             de destino (containerPort), no al puerto del Service.

LIMPIEZA al terminar:
  kubectl delete namespace netpol-lab

============================================================
EOF

# ============================================================================
# SOLUCION PASO A PASO (no mires hasta intentarlo)
# ============================================================================
#
# Paso 1 — Confirmar el sintoma:
#   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=3 http://backend
#   -> "wget: download timed out". Timeout (y no "refused") sugiere que algo
#      descarta paquetes: firewall o NetworkPolicy.
#
# Paso 2 — Listar las policies del namespace:
#   kubectl get networkpolicy -n netpol-lab
#   -> hay dos: 'default-deny-ingress' (correcta, debe quedarse) y
#      'allow-frontend-to-backend' (la sospechosa).
#
# Paso 3 — Inspeccionar la policy sospechosa:
#   kubectl describe networkpolicy allow-frontend-to-backend -n netpol-lab
#   y comparar con la realidad:
#   kubectl get pods -n netpol-lab --show-labels
#
#   Errores encontrados (eran dos):
#   a) El 'from.podSelector' exige el label app=front, pero el pod cliente
#      tiene app=frontend. Un selector que no matchea ningun pod = no se
#      permite nada.
#   b) El puerto permitido es 8080/TCP, pero nginx escucha en el
#      containerPort 80. El campo 'ports' de la policy se evalua contra el
#      puerto del pod destino, no contra el puerto del Service.
#
# Paso 4 — Aplicar la version corregida (kubectl apply sobreescribe):
#
#   kubectl apply -n netpol-lab -f - <<'FIX'
#   apiVersion: networking.k8s.io/v1
#   kind: NetworkPolicy
#   metadata:
#     name: allow-frontend-to-backend
#   spec:
#     podSelector:
#       matchLabels:
#         app: backend
#     policyTypes:
#     - Ingress
#     ingress:
#     - from:
#       - podSelector:
#           matchLabels:
#             app: frontend
#       ports:
#       - protocol: TCP
#         port: 80
#   FIX
#
#   (Alternativa de examen: kubectl edit networkpolicy
#    allow-frontend-to-backend -n netpol-lab y corregir los dos campos.)
#
# Paso 5 — Verificar el arreglo:
#   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=3 http://backend
#   -> vuelve a imprimir el HTML "Welcome to nginx!". Exito.
#
# Paso 6 — Limpieza:
#   kubectl delete namespace netpol-lab
#
# LECCIONES CLAVE PARA EL EXAMEN:
#   - Las NetworkPolicies son aditivas (whitelist): con un default-deny
#     presente, solo pasa el trafico que alguna policy permite explicitamente.
#   - Los selectores matchean LABELS exactos: un typo en un label equivale
#     a bloquear todo, y no genera ningun error ni warning al aplicar.
#   - 'ports' apunta al puerto del pod destino (containerPort), no al del
#     Service.
#   - Sintoma tipico de policy bloqueando: timeout (drop), no refused.
#   - Sin un CNI que las aplique (Calico, Cilium...), las policies existen
#     pero no hacen nada: en el examen se asume que el cluster las aplica.
#
# Fuentes:
#   - https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#   - https://kubernetes.io/docs/concepts/services-networking/network-policies/
# ============================================================================