#!/usr/bin/env bash
#
# CKA (v1.35) - Tema 2.2: Troubleshoot cluster components (peso 6)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Rompe, de forma controlada, UNO de tres cluster components en un
# control-plane node de kubeadm y le pide al estudiante que lo diagnostique
# y lo repare. Pensado para correr SOLO en una VM de laboratorio
# descartable: modifica static pod manifests y /etc/kubernetes/kubelet.conf
# y reinicia kubelet.
#
# Uso:
#   sudo ./break-2.2-cluster-components.sh --break --yes-this-is-a-throwaway-vm [--scenario 1|2|3]
#   sudo ./break-2.2-cluster-components.sh --check
#   sudo ./break-2.2-cluster-components.sh --restore
#
set -euo pipefail

MANIFEST_DIR=/etc/kubernetes/manifests
KUBELET_CONF=/etc/kubernetes/kubelet.conf
STATE_DIR=/var/lib/cka-2.2-lab
BACKUP_DIR="$STATE_DIR/backup"
STATE_FILE="$STATE_DIR/scenario"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

usage() {
  cat <<'EOF'
Uso:
  break-2.2-cluster-components.sh --break --yes-this-is-a-throwaway-vm [--scenario 1|2|3]
  break-2.2-cluster-components.sh --check
  break-2.2-cluster-components.sh --restore
EOF
}

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Ejecutá este script como root." >&2; exit 1; }
}

break_1() {
  local f="$MANIFEST_DIR/kube-scheduler.yaml"
  [[ -f "$f" ]] || { echo "No se encontró $f: ¿es este un control-plane node de kubeadm?" >&2; exit 1; }
  mkdir -p "$BACKUP_DIR"
  cp "$f" "$BACKUP_DIR/kube-scheduler.yaml"
  sed -i '0,/^\( *- \)kube-scheduler$/s//\1kube-scheduler-broken/' "$f"
  cat <<'MSG'
[break] Escenario: kube-scheduler

SINTOMA: los pods nuevos quedan en estado Pending y nunca se asignan a
un nodo. "kubectl get pods -n kube-system" muestra un pod
kube-scheduler-<nodo> en CrashLoopBackOff o Error.

OBJETIVO: dejar kube-scheduler corriendo de forma estable (Running, sin
restarts nuevos) y confirmar que un pod recién creado se agenda
correctamente en un nodo.
MSG
}

break_2() {
  local f="$MANIFEST_DIR/etcd.yaml"
  [[ -f "$f" ]] || { echo "No se encontró $f: ¿es este un control-plane node de kubeadm?" >&2; exit 1; }
  mkdir -p "$BACKUP_DIR"
  cp "$f" "$BACKUP_DIR/etcd.yaml"
  sed -i -E '/--listen-client-urls/ s/:2379/:23799/g' "$f"
  cat <<'MSG'
[break] Escenario: etcd

SINTOMA: los comandos kubectl empiezan a fallar o quedarse colgados
(connection refused o timeout). Los logs de kube-apiserver (crictl logs
<container-id>, o journalctl -u kubelet en el control plane) muestran
errores de conexión hacia etcd en 127.0.0.1:2379.

OBJETIVO: que kube-apiserver vuelva a conectar con etcd y que
"kubectl get nodes" responda correctamente de nuevo.
MSG
}

break_3() {
  [[ -f "$KUBELET_CONF" ]] || { echo "No se encontró $KUBELET_CONF." >&2; exit 1; }
  mkdir -p "$BACKUP_DIR"
  cp "$KUBELET_CONF" "$BACKUP_DIR/kubelet.conf"
  sed -i -E 's#(server: https://[^:]+):6443#\1:16443#' "$KUBELET_CONF"
  systemctl restart kubelet
  cat <<'MSG'
[break] Escenario: kubelet

SINTOMA: después de un rato "kubectl get nodes" muestra este nodo en
estado NotReady, aunque los pods que ya corrían siguen funcionando.
"journalctl -u kubelet -n 50" muestra errores de conexión rechazada al
intentar hablar con el kube-apiserver.

OBJETIVO: que el nodo vuelva a Ready y que journalctl -u kubelet no
muestre más errores de conexión.
MSG
}

restore_1() { cp "$BACKUP_DIR/kube-scheduler.yaml" "$MANIFEST_DIR/kube-scheduler.yaml"; }
restore_2() { cp "$BACKUP_DIR/etcd.yaml" "$MANIFEST_DIR/etcd.yaml"; }
restore_3() { cp "$BACKUP_DIR/kubelet.conf" "$KUBELET_CONF"; systemctl restart kubelet; }

check() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl no está en PATH." >&2; exit 1; }
  echo "== Nodos =="
  kubectl get nodes -o wide || true
  echo
  echo "== Pods de control plane =="
  kubectl get pods -n kube-system -o wide 2>/dev/null | grep -E 'kube-scheduler|kube-apiserver|etcd|kube-controller-manager|NAME' || true
  echo
  echo "== Prueba de scheduling =="
  if kubectl run cka-lab-check --image=busybox:1.36 --restart=Never --command -- sleep 5 >/dev/null 2>&1; then
    sleep 5
    kubectl get pod cka-lab-check -o wide || true
    kubectl delete pod cka-lab-check --ignore-not-found --wait=false >/dev/null 2>&1 || true
  else
    echo "No se pudo crear el pod de prueba (esperable si el cluster todavía está roto)."
  fi
}

ACTION=""
SCENARIO=""
CONFIRMED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --break) ACTION="break"; shift ;;
    --check) ACTION="check"; shift ;;
    --restore) ACTION="restore"; shift ;;
    --scenario) SCENARIO="$2"; shift 2 ;;
    --yes-this-is-a-throwaway-vm) CONFIRMED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$ACTION" ]] || { usage; exit 1; }

require_root

case "$ACTION" in
  break)
    if [[ $CONFIRMED -ne 1 ]]; then
      echo "Este script rompe componentes reales del control plane." >&2
      echo "Ejecutalo SOLO en una VM de laboratorio descartable." >&2
      echo "Volvé a correrlo con --yes-this-is-a-throwaway-vm para confirmar." >&2
      exit 1
    fi
    mkdir -p "$STATE_DIR"
    n="${SCENARIO:-$((RANDOM % 3 + 1))}"
    case "$n" in
      1) break_1 ;;
      2) break_2 ;;
      3) break_3 ;;
      *) echo "Escenario inválido: $n (usar 1, 2 o 3)" >&2; exit 1 ;;
    esac
    echo "$n" > "$STATE_FILE"
    ;;
  check)
    check
    ;;
  restore)
    [[ -f "$STATE_FILE" ]] || { echo "No hay backup registrado (¿corriste --break?)." >&2; exit 1; }
    n=$(cat "$STATE_FILE")
    case "$n" in
      1) restore_1 ;;
      2) restore_2 ;;
      3) restore_3 ;;
      *) echo "Estado inválido en $STATE_FILE." >&2; exit 1 ;;
    esac
    rm -f "$STATE_FILE"
    echo "Escenario $n restaurado."
    ;;
esac

# SOLUCION PASO A PASO (leer solo después de intentarlo)
#
# Escenario 1 - kube-scheduler roto:
#   1. kubectl get pods -n kube-system | grep scheduler
#      -> kube-scheduler-<nodo>  CrashLoopBackOff
#   2. kubectl describe pod kube-scheduler-<nodo> -n kube-system
#      (o crictl ps -a | grep scheduler / crictl logs <id>)
#      -> "exec: kube-scheduler-broken: no such file or directory"
#   3. cat /etc/kubernetes/manifests/kube-scheduler.yaml
#      -> ver "- kube-scheduler-broken" en vez de "- kube-scheduler"
#   4. sed -i 's/kube-scheduler-broken/kube-scheduler/' \
#         /etc/kubernetes/manifests/kube-scheduler.yaml
#   5. kubelet detecta el cambio en el manifest y recrea el static pod
#      solo (30-60s). Confirmar con kubectl get pods -n kube-system y
#      creando un pod nuevo para ver que se agenda.
#
# Escenario 2 - etcd inalcanzable:
#   1. kubectl get nodes  -> timeout o "connection refused"
#   2. crictl ps -a | grep kube-apiserver ; crictl logs <id>
#      -> errores conectando a etcd en 127.0.0.1:2379
#   3. cat /etc/kubernetes/manifests/etcd.yaml
#      -> --listen-client-urls usa :23799 en vez de :2379
#   4. sed -i -E '/--listen-client-urls/ s/:23799/:2379/g' \
#         /etc/kubernetes/manifests/etcd.yaml
#   5. kubelet recrea el pod de etcd; kube-apiserver reconecta solo.
#      Confirmar con kubectl get nodes.
#
# Escenario 3 - kubelet no reporta al apiserver:
#   1. kubectl get nodes -> el nodo pasa a NotReady
#   2. journalctl -u kubelet -n 50 --no-pager
#      -> "connection refused" contra el puerto 16443
#   3. grep server /etc/kubernetes/kubelet.conf
#      -> server: https://<ip>:16443 en vez de :6443
#   4. sed -i -E 's/:16443/:6443/' /etc/kubernetes/kubelet.conf
#   5. systemctl restart kubelet
#   6. Esperar 30-60s y volver a chequear: kubectl get nodes -> Ready