#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CKA v1.35 - Tema 2.1: Troubleshoot clusters and nodes (peso examen: 6)
# Fuente: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Escenario: rompe la configuración del kubelet en el nodo local
# provocando que quede en estado NotReady. Pensado para correr
# DENTRO de una VM de laboratorio descartable (nodo worker o
# control-plane de un cluster kubeadm de práctica), nunca en un
# nodo real.
# ============================================================

BACKUP_DIR="/root/lab-break-fix-backups"
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
MARKER="estoNoEsYAMLvalido"

usage() {
  echo "Uso: $0 [--yes] [--restore]"
  echo "  --yes      confirma la ejecución sin prompt interactivo"
  echo "  --restore  restaura el último backup de config.yaml y reinicia kubelet"
  exit 1
}

CONFIRM="no"
RESTORE="no"
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRM="yes" ;;
    --restore) RESTORE="yes" ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Este script debe correr como root." >&2
  exit 1
fi

if [[ ! -f "$KUBELET_CONFIG" ]]; then
  echo "No se encontró $KUBELET_CONFIG. ¿Este nodo tiene kubelet instalado vía kubeadm?" >&2
  exit 1
fi

if [[ "$RESTORE" == "yes" ]]; then
  LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/config.yaml.bak.* 2>/dev/null | head -n1 || true)
  if [[ -z "$LATEST_BACKUP" ]]; then
    echo "No hay backups en $BACKUP_DIR." >&2
    exit 1
  fi
  cp -a "$LATEST_BACKUP" "$KUBELET_CONFIG"
  systemctl restart kubelet
  echo "Restaurado $KUBELET_CONFIG desde $LATEST_BACKUP y kubelet reiniciado."
  exit 0
fi

echo "=============================================================="
echo " ADVERTENCIA: este script deja el nodo local en estado NotReady"
echo " modificando /var/lib/kubelet/config.yaml."
echo ""
echo " Corré esto SOLO en una VM de laboratorio descartable."
echo " El cambio queda respaldado en $BACKUP_DIR, pero se espera"
echo " que resuelvas el problema manualmente en vivo, no restaurando"
echo " el backup (podés usar '$0 --restore' para reiniciar el lab)."
echo "=============================================================="

if [[ "$CONFIRM" != "yes" ]]; then
  read -r -p "Escribí 'romper' para continuar: " ans
  if [[ "$ans" != "romper" ]]; then
    echo "Cancelado."
    exit 1
  fi
fi

mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_FILE="$BACKUP_DIR/config.yaml.bak.$TIMESTAMP"
cp -a "$KUBELET_CONFIG" "$BACKUP_FILE"
echo "Backup guardado en $BACKUP_FILE"

sed -i "1i ${MARKER}: [" "$KUBELET_CONFIG"

systemctl restart kubelet || true

cat <<'EOF'

=== SÍNTOMA QUE VAS A VER ===
En unos 30-60 segundos, este nodo va a pasar a estado NotReady:

    kubectl get nodes

El servicio kubelet va a estar fallando o reiniciándose en loop en
este host:

    systemctl status kubelet

=== TU TAREA ===
Sin restaurar ningún backup a mano, diagnosticá por qué kubelet no
levanta y dejá el nodo en Ready nuevamente. Herramientas sugeridas:

    kubectl describe node <nombre-del-nodo>
    systemctl status kubelet
    journalctl -u kubelet -xe --no-pager | tail -50

Cuando kubectl get nodes vuelva a mostrar Ready, terminaste.
EOF

# ============================================================
# SOLUCIÓN PASO A PASO (no leer antes de intentarlo)
#
# 1. kubectl get nodes
#    -> el nodo aparece en estado NotReady.
#
# 2. kubectl describe node <nodo>
#    -> en Conditions, Ready=False/Unknown, con un mensaje tipo
#       "kubelet stopped posting node status" (el kubelet dejó de
#       reportar porque no puede arrancar).
#
# 3. systemctl status kubelet
#    -> el servicio está en estado failed o reiniciando
#       constantemente (activating (auto-restart)).
#
# 4. journalctl -u kubelet -xe --no-pager | tail -50
#    -> se ve un error de parseo de YAML al cargar el config file,
#       algo como:
#       "error parsing /var/lib/kubelet/config.yaml ...
#        yaml: line 1: did not find expected node content"
#
# 5. cat /var/lib/kubelet/config.yaml | head -5
#    -> se ve la línea agregada al principio del archivo:
#       "estoNoEsYAMLvalido: ["
#       que rompe la sintaxis YAML (corchete sin cerrar).
#
# 6. Arreglo: eliminar esa línea inválida y dejar el resto del
#    archivo intacto.
#       sudo sed -i '/estoNoEsYAMLvalido/d' /var/lib/kubelet/config.yaml
#    (o editarlo a mano con vi/nano y borrar la línea).
#
# 7. Recargar y reiniciar el servicio:
#       sudo systemctl daemon-reload
#       sudo systemctl restart kubelet
#
# 8. Verificar:
#       systemctl status kubelet        # active (running)
#       kubectl get nodes               # vuelve a Ready en ~30-60s
#
# Nota: /var/lib/kubelet/config.yaml es leído por kubelet al
# arrancar (kubeadm lo genera y lo referencia desde el drop-in de
# systemd en /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# vía --config). Cualquier YAML inválido ahí impide que kubelet
# levante, lo que hace que el nodo deje de reportar estado al
# API server y termine en NotReady.
# ============================================================