#!/usr/bin/env bash
#
# CKA v1.35 - Tema 5.3: Use ClusterIP, NodePort, LoadBalancer service types and endpoints
# Peso en el examen: 3.33%
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Este script arma un laboratorio "break & fix" en una VM de laboratorio DESCARTABLE.
# No lo corras contra un cluster que te importe: crea recursos reales y rompe uno
# a propósito para generar una falla realista de Service/Endpoints.
#
# Uso:
#   ./break-fix-5.3-services.sh apply     -> crea el laboratorio (rompe algo)
#   ./break-fix-5.3-services.sh cleanup   -> borra todo lo creado por el laboratorio
#
set -euo pipefail

NAMESPACE="cka-5-3-lab"
ACTION="${1:-apply}"

confirm_lab() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  echo "Contexto actual de kubectl: ${ctx}"
  echo "Este script va a crear/borrar recursos reales en el namespace '${NAMESPACE}'."
  echo "Usalo SOLO en una VM/cluster de laboratorio descartable (kind, minikube, k3d, etc.)."
  read -r -p "Escribi 'si' para confirmar que este es un cluster descartable: " respuesta
  if [[ "${respuesta}" != "si" ]]; then
    echo "Confirmacion no recibida. Abortando sin tocar nada."
    exit 1
  fi
}

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "No se encontro 'kubectl' en el PATH. Instalalo antes de continuar." >&2
    exit 1
  fi
}

cleanup_lab() {
  echo "Borrando namespace '${NAMESPACE}' y todo lo que contiene..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
  echo "Limpieza completa."
}

apply_lab() {
  echo "Creando namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  echo "Desplegando la app 'web' (nginx, 2 replicas, label app=web)..."
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
EOF

  echo "Creando Service ClusterIP 'web-clusterip' (correcto, de referencia)..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web-clusterip
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
EOF

  echo "Creando Service LoadBalancer 'web-loadbalancer' (correcto; sin MetalLB va a quedar EXTERNAL-IP <pending> - eso es esperado, NO es la falla a arreglar)..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web-loadbalancer
  namespace: ${NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
EOF

  echo "Creando Service NodePort 'web-nodeport' con una falla intencional en el selector..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: web-front
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
EOF

  echo "Desplegando pod 'tester' (curl) para probar conectividad desde adentro del cluster..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tester
  namespace: ${NAMESPACE}
  labels:
    app: tester
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
EOF

  echo "Esperando a que el Deployment y el pod tester esten listos..."
  kubectl -n "${NAMESPACE}" rollout status deployment/web --timeout=120s
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod/tester --timeout=120s

  cat <<'MSG'

================================================================
LABORATORIO LISTO - CKA 5.3 (Service types + Endpoints)
================================================================

Que vas a observar (sintoma):

  - El Service "web-clusterip" funciona.
  - El Service "web-loadbalancer" queda con EXTERNAL-IP en <pending>
    (comportamiento normal en un cluster bare-metal sin un LoadBalancer
    controller externo, por ejemplo MetalLB. Eso NO es la falla que tenes
    que arreglar).
  - El Service "web-nodeport" NO responde: si desde el pod "tester" haces
    un curl contra el (por nombre DNS o por ClusterIP), la conexion se
    cuelga o da timeout. Si probas contra <IP-de-un-nodo>:30080 pasa lo
    mismo.

Tu objetivo:

  1. Diagnosticar por que "web-nodeport" no tiene trafico llegando a los
     pods, usando los objetos Service, Endpoints y las labels de los Pods.
  2. Corregir el Service "web-nodeport" (sin tocar el Deployment) para que
     vuelva a enrutar trafico a los 2 pods de "web".
  3. Confirmar el arreglo:
     - "kubectl get endpoints web-nodeport -n cka-5-3-lab" debe listar 2
       direcciones IP (una por pod).
     - Desde el pod tester:
       kubectl exec -n cka-5-3-lab tester -- curl -s -o /dev/null -w '%{http_code}\n' http://web-nodeport.cka-5-3-lab.svc.cluster.local
       debe devolver 200.
     - kubectl exec -n cka-5-3-lab tester -- curl -s -o /dev/null -w '%{http_code}\n' http://<IP-de-cualquier-nodo>:30080
       tambien debe devolver 200.

Comandos utiles para el diagnostico (no son la solucion, son para investigar):

  kubectl get svc,ep,pods -n cka-5-3-lab -o wide
  kubectl get pods -n cka-5-3-lab --show-labels
  kubectl describe svc web-nodeport -n cka-5-3-lab
  kubectl describe svc web-clusterip -n cka-5-3-lab   (para comparar contra el que si funciona)

Cuando termines, corre:
  ./break-fix-5.3-services.sh cleanup

================================================================
MSG
}

require_kubectl

case "${ACTION}" in
  apply)
    confirm_lab
    apply_lab
    ;;
  cleanup)
    confirm_lab
    cleanup_lab
    ;;
  *)
    echo "Uso: $0 {apply|cleanup}" >&2
    exit 1
    ;;
esac

exit 0

# ================================================================
# SOLUCION PASO A PASO (no se ejecuta, es solo referencia)
# ================================================================
#
# 1. Confirmar que el Deployment esta sano y que labels tienen los pods reales:
#      kubectl get pods -n cka-5-3-lab --show-labels
#    -> Los pods del Deployment "web" tienen la label "app=web".
#
# 2. Comparar los selectores de los tres Services:
#      kubectl get svc -n cka-5-3-lab -o jsonpath='{range .items[*]}{.metadata.name}{"  selector="}{.spec.selector}{"\n"}{end}'
#    -> "web-clusterip" y "web-loadbalancer" tienen selector app=web (coincide
#       con los pods).
#    -> "web-nodeport" tiene selector app=web-front (NO coincide con ningun pod).
#
# 3. Confirmar que por eso no hay Endpoints:
#      kubectl get endpoints web-nodeport -n cka-5-3-lab
#    -> "web-nodeport" no muestra ninguna direccion en ENDPOINTS (o "<none>"),
#       porque el selector no matchea labels de ningun pod. Un Service sin
#       Endpoints no tiene a donde enviar el trafico, sin importar su type
#       (ClusterIP, NodePort o LoadBalancer): el problema es previo a la capa
#       de exposicion externa.
#
# 4. Corregir el selector para que apunte a los pods reales:
#      kubectl patch svc web-nodeport -n cka-5-3-lab \
#        --type merge -p '{"spec":{"selector":{"app":"web"}}}'
#    (equivalente a "kubectl edit svc web-nodeport -n cka-5-3-lab" y cambiar
#    spec.selector.app de "web-front" a "web")
#
# 5. Verificar que ahora si hay Endpoints:
#      kubectl get endpoints web-nodeport -n cka-5-3-lab
#    -> Debe listar 2 IPs (una por replica del Deployment "web").
#
# 6. Probar conectividad desde adentro del cluster:
#      kubectl exec -n cka-5-3-lab tester -- \
#        curl -s -o /dev/null -w '%{http_code}\n' \
#        http://web-nodeport.cka-5-3-lab.svc.cluster.local
#    -> Debe devolver 200.
#
# 7. Probar el NodePort contra la IP de cualquier nodo del cluster:
#      NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
#      kubectl exec -n cka-5-3-lab tester -- \
#        curl -s -o /dev/null -w '%{http_code}\n' "http://${NODE_IP}:30080"
#    -> Debe devolver 200 (kube-proxy expone el nodePort 30080 en todas las
#    interfaces de todos los nodos y reenvia al ClusterIP -> a los pods).
#
# 8. Recordar que "web-loadbalancer" va a seguir en EXTERNAL-IP <pending>:
#    eso es esperado en un cluster sin cloud provider ni MetalLB, y NO forma
#    parte de esta falla.
# ================================================================