#!/usr/bin/env bash
#
# CKS v1.34 - Dominio 2.4: Implement Pod-to-Pod encryption (Cilium, Istio)
# Peso en el examen: 5
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Este script de "break & fix" apunta a la implementación vía Cilium
# (WireGuard transparent encryption), una de las dos rutas que cubre
# este dominio (la otra es mTLS de Istio). Pensado para correr en una
# VM de laboratorio DESCARTABLE con un cluster Kubernetes que ya usa
# Cilium como CNI.
#
# Uso:
#   ./break-2.4-cilium-encryption.sh          -> rompe el lab (pide confirmación interactiva)
#   CKS_LAB_CONFIRM=yes ./break-....sh        -> rompe sin prompt (para automatizar el lab)
#
# Este script NO aplica el arreglo. La solución está documentada,
# paso a paso, en el bloque de comentarios al final del archivo.
#
# Para reiniciar el laboratorio desde cero:
#   kubectl delete namespace cks-2-4-podenc
#   kubectl -n kube-system apply -f /tmp/cks-2.4-backup/cilium-config.yaml
#   kubectl -n kube-system rollout restart daemonset/cilium

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

NAMESPACE="cks-2-4-podenc"
CILIUM_NS="kube-system"
BACKUP_DIR="/tmp/cks-2.4-backup"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Falta el comando requerido: $1"
    exit 1
  fi
}

confirm_destructive_action() {
  if [[ "${CKS_LAB_CONFIRM:-}" == "yes" ]]; then
    return 0
  fi
  log_warn "Este script modifica la configuración de cifrado de Cilium en el cluster actual."
  log_warn "Corré esto SOLO en una VM de laboratorio descartable, nunca contra un cluster real."
  read -r -p "Escribí 'romper' para continuar: " answer
  if [[ "$answer" != "romper" ]]; then
    log_info "Cancelado por el usuario."
    exit 0
  fi
}

check_prereqs() {
  require_cmd kubectl
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "No se pudo contactar al cluster. Revisá tu kubeconfig."
    exit 1
  fi
  if ! kubectl -n "$CILIUM_NS" get daemonset cilium >/dev/null 2>&1; then
    log_error "No se encontró el DaemonSet 'cilium' en el namespace '$CILIUM_NS'."
    log_error "Este laboratorio requiere un cluster con Cilium como CNI."
    exit 1
  fi
  log_ok "Cluster alcanzable y Cilium detectado como CNI."
}

get_cilium_pod() {
  kubectl -n "$CILIUM_NS" get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}'
}

deploy_test_workload() {
  log_info "Desplegando workload de prueba pod-to-pod en el namespace '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: enc-server
  namespace: cks-2-4-podenc
  labels:
    app: enc-server
spec:
  containers:
    - name: server
      image: busybox:1.36
      command: ["sh", "-c", "while true; do echo hello-from-server | nc -l -p 9000; done"]
      ports:
        - containerPort: 9000
---
apiVersion: v1
kind: Service
metadata:
  name: enc-server
  namespace: cks-2-4-podenc
spec:
  selector:
    app: enc-server
  ports:
    - port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Pod
metadata:
  name: enc-client
  namespace: cks-2-4-podenc
  labels:
    app: enc-client
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app: enc-server
            topologyKey: kubernetes.io/hostname
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "infinity"]
EOF

  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/enc-server --timeout=90s
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/enc-client --timeout=90s
  log_ok "Pods de prueba listos: enc-server / enc-client (Service enc-server:9000)."
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  kubectl -n "$CILIUM_NS" get configmap cilium-config -o yaml > "$BACKUP_DIR/cilium-config.yaml"
  log_ok "Backup del ConfigMap cilium-config guardado en $BACKUP_DIR/cilium-config.yaml"
}

break_encryption() {
  log_warn "Rompiendo el cifrado pod-to-pod (deshabilitando WireGuard en Cilium)..."
  kubectl -n "$CILIUM_NS" patch configmap cilium-config --type merge \
    -p '{"data":{"enable-wireguard":"false"}}' >/dev/null

  kubectl -n "$CILIUM_NS" rollout restart daemonset/cilium >/dev/null
  log_info "Esperando a que los agentes de Cilium se reinicien con la nueva config..."
  kubectl -n "$CILIUM_NS" rollout status daemonset/cilium --timeout=180s
}

print_student_briefing() {
  local cilium_pod
  cilium_pod="$(get_cilium_pod)"
  cat <<EOF

============================================================
  LABORATORIO ROTO - CKS 2.4 Pod-to-Pod encryption (Cilium)
============================================================

SÍNTOMA:
  El namespace '$NAMESPACE' tiene dos pods (enc-server, enc-client)
  y un Service para probar conectividad. La conectividad entre pods
  sigue funcionando con normalidad, pero el tráfico entre nodos YA
  NO viaja cifrado por el túnel WireGuard que Cilium debería estar
  manteniendo. No vas a ver errores de conexión: el problema es
  silencioso, típico de un control de seguridad que dejó de
  aplicarse sin que nadie lo note.

  Podés ver el estado actual con:
    kubectl -n $CILIUM_NS exec $cilium_pod -c cilium-agent -- cilium status --verbose | grep -i encrypt

OBJETIVO:
  Restaurar el cifrado pod-to-pod vía Cilium/WireGuard, sin romper
  la conectividad entre enc-client y enc-server, y confirmar que
  'cilium status' vuelve a reportar el modo de cifrado correcto
  (Wireguard) en todos los agentes.

VALIDACIÓN SUGERIDA (una vez que creas que lo arreglaste):
  kubectl -n $CILIUM_NS exec $cilium_pod -c cilium-agent -- cilium status --verbose | grep -i encrypt
  kubectl -n $NAMESPACE exec enc-client -- nc -w2 enc-server.$NAMESPACE.svc.cluster.local 9000

  Si tu lab tiene más de un nodo worker, también podés capturar
  tráfico en la interfaz física del nodo mientras generás tráfico
  entre los pods, para confirmar que viaja encapsulado en WireGuard
  y no en texto plano (el puerto UDP por defecto de Cilium WireGuard
  es 51871, pero confirmalo con 'cilium status --verbose' porque
  puede variar según versión/config).

============================================================
EOF
}

main() {
  check_prereqs
  confirm_destructive_action
  deploy_test_workload
  backup_config
  break_encryption
  print_student_briefing
}

main "$@"

# ============================================================
# SOLUCIÓN PASO A PASO (no ejecutada por este script)
# ============================================================
#
# 1. Confirmar el diagnóstico: el ConfigMap cilium-config tiene
#    "enable-wireguard: false" cuando debería estar en "true".
#      kubectl -n kube-system get configmap cilium-config -o yaml | grep wireguard
#
# 2. Restaurar la clave a "true" (o reaplicar el backup que dejó
#    este mismo script en /tmp/cks-2.4-backup/cilium-config.yaml):
#      kubectl -n kube-system patch configmap cilium-config --type merge \
#        -p '{"data":{"enable-wireguard":"true"}}'
#
#    Alternativa equivalente, reaplicando el backup completo:
#      kubectl -n kube-system apply -f /tmp/cks-2.4-backup/cilium-config.yaml
#
# 3. Reiniciar los agentes de Cilium para que tomen la nueva config
#    (el flag de WireGuard no se relee en caliente):
#      kubectl -n kube-system rollout restart daemonset/cilium
#      kubectl -n kube-system rollout status daemonset/cilium --timeout=180s
#
# 4. Verificar que cada agente reporta el modo de cifrado correcto:
#      CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
#      kubectl -n kube-system exec "$CILIUM_POD" -c cilium-agent -- cilium status --verbose | grep -i encrypt
#      # Esperado: "Encryption: Wireguard" y, más abajo, la lista de
#      # nodos con su clave pública de WireGuard poblada (no vacía).
#
# 5. Confirmar que la conectividad de aplicación sigue intacta:
#      kubectl -n cks-2-4-podenc exec enc-client -- nc -w2 \
#        enc-server.cks-2-4-podenc.svc.cluster.local 9000
#      # Esperado: recibe "hello-from-server".
#
# 6. (Opcional, si el lab tiene 2+ nodos worker) Confirmar con una
#    captura de paquetes en la interfaz física del nodo que el
#    tráfico entre pods de distintos nodos va encapsulado como UDP
#    WireGuard y no como el protocolo de aplicación en texto plano:
#      tcpdump -i <iface-del-nodo> udp port 51871
#
# Nota conceptual para el examen: en Cilium, el cifrado transparente
# (WireGuard o IPsec) cifra el tráfico NODO A NODO a nivel de CNI,
# de forma transparente para la aplicación: no requiere sidecars ni
# cambios en los pods. Es la alternativa "sin service mesh" a lo que
# Istio logra con mTLS entre sidecars Envoy (PeerAuthentication en
# modo STRICT + DestinationRule con ISTIO_MUTUAL). Para el dominio
# 2.4 del CKS hay que saber diagnosticar y remediar cualquiera de
# las dos rutas.
# Fuente: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
# ============================================================