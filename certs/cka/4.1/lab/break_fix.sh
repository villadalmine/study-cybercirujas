#!/usr/bin/env bash
#
# break-fix 4.1 - Prepare underlying infrastructure for installing a Kubernetes cluster
# CKA v1.35 - dominio 4 (peso 3.57%)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Este script tiene que correr como root (o con sudo) en una VM de laboratorio descartable." >&2
  exit 1
fi

cat <<'EOF'
=====================================================================
 BREAK & FIX - CKA 4.1: Prepare underlying infrastructure
=====================================================================
Este script rompe, a propósito, tres precondiciones que kubeadm
verifica antes de poder inicializar (o unir) un nodo al cluster.
Corré este script SOLO en una VM de laboratorio descartable: modifica
/etc/fstab, carga/descarga kernel modules, cambia sysctls y detiene
containerd.
=====================================================================
EOF

read -rp "Escribí CONFIRMAR para romper esta VM de laboratorio: " ans
if [[ "$ans" != "CONFIRMAR" ]]; then
  echo "Cancelado, no se modificó nada."
  exit 0
fi

BACKUP_DIR="/root/breakfix-4.1-backup"
mkdir -p "$BACKUP_DIR"
cp -a /etc/fstab "$BACKUP_DIR/fstab.bak" 2>/dev/null || true
[[ -f /etc/modules-load.d/k8s.conf ]] && cp -a /etc/modules-load.d/k8s.conf "$BACKUP_DIR/k8s-modules.conf.bak"
[[ -f /etc/sysctl.d/k8s.conf ]] && cp -a /etc/sysctl.d/k8s.conf "$BACKUP_DIR/k8s-sysctl.conf.bak"
echo "Backups guardados en $BACKUP_DIR (solo referencia, no los necesitás para resolver el ejercicio)."

echo "[1/3] Reactivando swap..."
SWAPFILE="/swapfile-lab"
if ! swapon --show | grep -q "$SWAPFILE"; then
  if [[ ! -f "$SWAPFILE" ]]; then
    fallocate -l 512M "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=512
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
  fi
  swapon "$SWAPFILE"
fi
if ! grep -q "$SWAPFILE" /etc/fstab; then
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

echo "[2/3] Descargando br_netfilter y reseteando sysctls de red..."
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/k8s.conf
modprobe -r br_netfilter 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=0 >/dev/null

echo "[3/3] Deteniendo y deshabilitando containerd..."
if systemctl list-unit-files | grep -q '^containerd.service'; then
  systemctl stop containerd 2>/dev/null || true
  systemctl disable containerd 2>/dev/null || true
else
  echo "  (containerd no está instalado en esta VM; se omite este paso)"
fi

cat <<'EOF'

=====================================================================
 SÍNTOMA QUE VAS A VER
=====================================================================
Si containerd, kubelet y kubeadm ya estaban instalados en esta VM,
"kubeadm init" (o "kubeadm join") va a fallar en la fase preflight
con errores como:

  [ERROR Swap]: running with swap on is not supported...
  [ERROR FileContent--proc-sys-net-bridge-bridge-nf-call-iptables]
  [ERROR FileContent--proc-sys-net-ipv4-ip_forward]: ...
  [ERROR CRI]: container runtime is not running...

Si todavía no instalaste containerd/kubeadm/kubelet, no vas a ver
esos mensajes hasta que los instales y corras kubeadm, pero la VM
ya quedó en un estado que no cumple los prerequisitos de infra.

=====================================================================
 QUÉ TENÉS QUE LOGRAR
=====================================================================
Dejá esta VM lista para poder correr "kubeadm init" (o
"kubeadm join") sin errores de preflight relacionados con:

  1. swap: tiene que estar deshabilitado en runtime Y no debe
     volver a activarse en el próximo reboot.
  2. kernel modules y sysctls: "overlay" y "br_netfilter" cargados,
     y persistidos para que se carguen en cada boot; y los sysctls
     net.bridge.bridge-nf-call-iptables=1,
     net.bridge.bridge-nf-call-ip6tables=1 y net.ipv4.ip_forward=1
     aplicados Y persistidos.
  3. containerd corriendo y habilitado para iniciar en cada boot.

Verificá vos mismo con:
  swapon --show
  lsmod | grep br_netfilter
  sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward
  systemctl status containerd
=====================================================================
EOF

# =====================================================================
# SOLUCIÓN PASO A PASO (comentada a propósito: no se ejecuta sola)
# =====================================================================
#
# 1) Deshabilitar swap en runtime y de forma persistente:
#
#    swapoff -a
#    sed -i '/swapfile-lab/d' /etc/fstab
#    rm -f /swapfile-lab
#
# 2) Cargar los kernel modules necesarios y persistirlos:
#
#    cat <<EOM > /etc/modules-load.d/k8s.conf
#    overlay
#    br_netfilter
#    EOM
#    modprobe overlay
#    modprobe br_netfilter
#
#    Aplicar y persistir los sysctls requeridos:
#
#    cat <<EOM > /etc/sysctl.d/k8s.conf
#    net.bridge.bridge-nf-call-iptables  = 1
#    net.bridge.bridge-nf-call-ip6tables = 1
#    net.ipv4.ip_forward                 = 1
#    EOM
#    sysctl --system
#
# 3) Levantar y habilitar containerd (si ya está instalado):
#
#    systemctl enable --now containerd
#
# 4) Verificar que todo quedó en orden:
#
#    swapon --show                        # sin salida = OK
#    lsmod | grep -E 'overlay|br_netfilter'
#    sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
#    systemctl is-active containerd
#    kubeadm init phase preflight         # si kubeadm ya está instalado
#
# =====================================================================