#!/usr/bin/env bash
#
# break-fix: CKA v1.35 - Tema 4.3 "Manage the lifecycle of Kubernetes clusters" (peso 3.57%)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Escenario: un nodo kubeadm que, tras una "tarea de mantenimiento" mal hecha
# (edición manual de los argumentos de arranque de kubelet, algo típico durante
# rotación de certificados, cambios de runtime o preparación de un upgrade),
# deja de arrancar correctamente. El objetivo del estudiante es diagnosticar
# el fallo del lifecycle del componente kubelet y restaurar el nodo a Ready
# usando las herramientas de troubleshooting de kubeadm/systemd/journalctl.
#
# SOLO para uso en una VM de laboratorio descartable con un cluster kubeadm
# ya instalado (single-node o control-plane). NO ejecutar en un cluster real.

set -euo pipefail

KUBEADM_FLAGS_FILE="/var/lib/kubelet/kubeadm-flags.env"
BACKUP_FILE="/root/kubeadm-flags.env.break-fix.bak"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Este script debe ejecutarse como root (usa sudo)." >&2
  exit 1
fi

if [[ ! -f "${KUBEADM_FLAGS_FILE}" ]]; then
  echo "No se encontró ${KUBEADM_FLAGS_FILE}." >&2
  echo "Este script asume un nodo administrado por kubeadm. Abortando." >&2
  exit 1
fi

echo "=========================================================="
echo " ADVERTENCIA: este script va a romper el arranque de kubelet"
echo " en esta VM de forma intencional para practicar troubleshooting"
echo " del lifecycle del cluster (Tema 4.3 del CKA)."
echo ""
echo " Ejecutalo SOLO en una VM de laboratorio descartable."
echo "=========================================================="
read -r -p "¿Confirmás que esta es una VM de laboratorio descartable? [y/N] " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "Cancelado por el usuario."
  exit 0
fi

echo ""
echo ">> Haciendo backup de ${KUBEADM_FLAGS_FILE} en ${BACKUP_FILE}..."
cp -a "${KUBEADM_FLAGS_FILE}" "${BACKUP_FILE}"

echo ">> Inyectando una flag inválida en KUBELET_KUBEADM_ARGS..."
sed -i \
  's/^KUBELET_KUBEADM_ARGS="\(.*\)"$/KUBELET_KUBEADM_ARGS="\1 --this-flag-does-not-exist=true"/' \
  "${KUBEADM_FLAGS_FILE}"

echo ">> Reiniciando kubelet para aplicar el cambio roto..."
systemctl restart kubelet || true

sleep 5

echo ""
echo "=========================================================="
echo " SÍNTOMA QUE VAS A OBSERVAR"
echo "=========================================================="
echo "- 'systemctl status kubelet' va a mostrar el servicio en estado"
echo "  failed o en un loop de reinicios (activating/auto-restart)."
echo "- 'kubectl get nodes' (si todavía responde el API server) va a"
echo "  mostrar este nodo en estado NotReady, o dejará de responder"
echo "  si este es el único control-plane node."
echo "- 'journalctl -u kubelet -n 50 --no-pager' va a mostrar un error"
echo "  de parseo de flags al inicio del proceso kubelet."
echo ""
echo "=========================================================="
echo " QUÉ TENÉS QUE LOGRAR"
echo "=========================================================="
echo "1. Diagnosticar, usando journalctl y el archivo"
echo "   ${KUBEADM_FLAGS_FILE}, cuál es la causa raíz del fallo"
echo "   de arranque de kubelet (no asumas, confirmalo en los logs)."
echo "2. Corregir el archivo de configuración de kubelet gestionado"
echo "   por kubeadm sin restaurar ciegamente el backup: editá el"
echo "   archivo a mano quitando la flag inválida que causó el problema."
echo "3. Reiniciar kubelet y verificar que:"
echo "   - 'systemctl is-active kubelet' devuelve 'active'"
echo "   - 'kubectl get nodes' muestra este nodo en estado Ready"
echo ""
echo "Backup de referencia disponible en: ${BACKUP_FILE}"
echo "(no lo copies directo: practicá el diagnóstico primero)"
echo "=========================================================="

exit 0

# ==========================================================
# SOLUCIÓN PASO A PASO (no ejecutada automáticamente)
# ==========================================================
#
# 1) Confirmar el estado roto del servicio:
#      systemctl status kubelet
#      journalctl -u kubelet -n 50 --no-pager
#
#    En los logs vas a ver algo como:
#      "error: unknown flag: --this-flag-does-not-exist"
#    o un error de parseo similar al arrancar el proceso kubelet.
#
# 2) Identificar el origen de la flag inyectada. kubeadm arma la
#    línea de arranque de kubelet combinando dos archivos:
#      /var/lib/kubelet/kubeadm-flags.env   (KUBELET_KUBEADM_ARGS)
#      /var/lib/kubelet/config.yaml         (KubeletConfiguration)
#    Inspeccionar el primero:
#      cat /var/lib/kubelet/kubeadm-flags.env
#
# 3) Editar el archivo a mano y quitar la flag inválida:
#      sudo vi /var/lib/kubelet/kubeadm-flags.env
#    Dejar la línea KUBELET_KUBEADM_ARGS solo con las flags
#    originales (sin "--this-flag-does-not-exist=true").
#
# 4) Recargar el estado de systemd y reiniciar kubelet:
#      sudo systemctl daemon-reload
#      sudo systemctl restart kubelet
#
# 5) Verificar la recuperación:
#      systemctl is-active kubelet        # debe devolver "active"
#      journalctl -u kubelet -n 20 --no-pager   # sin errores nuevos
#      kubectl get nodes                  # el nodo debe volver a Ready
#
# 6) (Opcional) Comparar el archivo corregido contra el backup
#    generado por el script para confirmar que la única diferencia
#    era la flag inyectada:
#      diff /var/lib/kubelet/kubeadm-flags.env \
#           /root/kubeadm-flags.env.break-fix.bak
# ==========================================================