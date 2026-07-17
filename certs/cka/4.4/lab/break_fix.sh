#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# break-fix: CKA v1.35 - Tema 4.4
# "Implement and configure a highly-available control plane"
# Peso en el examen: 3.57%
# Fuente (solo como referencia de alcance del tema, no se copia texto):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Este script está pensado para correr en la VM que actúa como load balancer
# (haproxy + keepalived) de un control plane HA armado con kubeadm (topología
# de etcd apilado, varios nodos control-plane detrás de una VIP).
# Es destructivo a propósito y SOLO debe usarse en una VM de laboratorio
# descartable. No toca los nodos control-plane ni etcd: solo el balanceador.
# ============================================================================

LAB_CONFIRM_VALUE="I-UNDERSTAND-THIS-IS-A-DISPOSABLE-LAB-VM"
BACKUP_DIR="/root/cka-4.4-lab-backups"
HAPROXY_CFG=""

for candidate in /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.d/*.cfg; do
  if [[ -f "$candidate" ]]; then
    HAPROXY_CFG="$candidate"
    break
  fi
done

usage() {
  echo "Uso: LAB_CONFIRM=${LAB_CONFIRM_VALUE} $0 {break|restore}"
  echo
  echo "  break    - rompe de forma controlada el load balancer del control plane"
  echo "  restore  - revierte el último break usando el backup guardado (red de seguridad)"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Este script necesita correr como root (systemctl, /etc/haproxy)." >&2
    exit 1
  fi
}

require_confirmation() {
  if [[ "${LAB_CONFIRM:-}" != "${LAB_CONFIRM_VALUE}" ]]; then
    echo "Falta confirmación explícita de que esto es una VM de laboratorio descartable." >&2
    echo "Volvé a ejecutar así:" >&2
    echo "  LAB_CONFIRM=${LAB_CONFIRM_VALUE} $0 break" >&2
    exit 1
  fi
}

require_haproxy() {
  if [[ -z "${HAPROXY_CFG}" ]]; then
    echo "No se encontró configuración de haproxy en este host." >&2
    echo "Este ejercicio espera correr en el nodo load balancer del control plane HA." >&2
    exit 1
  fi
  if ! command -v haproxy >/dev/null 2>&1; then
    echo "El binario haproxy no está instalado en esta VM." >&2
    exit 1
  fi
}

detect_vip() {
  local vip=""
  if [[ -f /etc/keepalived/keepalived.conf ]]; then
    vip=$(grep -A2 "virtual_ipaddress" /etc/keepalived/keepalived.conf \
      | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
  fi
  echo "${vip}"
}

do_break() {
  require_root
  require_confirmation
  require_haproxy

  mkdir -p "${BACKUP_DIR}"
  local ts
  ts=$(date +%Y%m%d%H%M%S)
  local backup_file="${BACKUP_DIR}/haproxy.cfg.${ts}.bak"
  cp -a "${HAPROXY_CFG}" "${backup_file}"
  echo "${HAPROXY_CFG}" > "${BACKUP_DIR}/last-cfg-path"
  echo "${backup_file}" > "${BACKUP_DIR}/last-backup-path"

  # Corrompe el puerto de los backends de kube-apiserver en el backend de
  # haproxy: cambia :6443 por :16443 en las líneas "server ... check".
  # El archivo sigue siendo sintácticamente válido (haproxy arranca bien),
  # pero el health check falla y ningún backend queda arriba.
  if ! grep -Eq '^\s*server\s+\S+\s+\S+:6443\s+check' "${HAPROXY_CFG}"; then
    echo "No se encontraron líneas 'server ... 6443 check' para romper en ${HAPROXY_CFG}." >&2
    echo "Revisá el archivo manualmente antes de continuar." >&2
    exit 1
  fi

  sed -i -E 's/(^\s*server\s+\S+\s+\S+):6443(\s+check.*)/\1:16443\2/' "${HAPROXY_CFG}"

  if ! haproxy -c -f "${HAPROXY_CFG}" >/dev/null 2>&1; then
    echo "El archivo quedó con sintaxis inválida, restaurando backup por seguridad." >&2
    cp -a "${backup_file}" "${HAPROXY_CFG}"
    exit 1
  fi

  systemctl restart haproxy

  local vip
  vip=$(detect_vip)

  cat <<EOF

============================================================
BREAK APLICADO - 4.4 Highly-available control plane
============================================================
Qué se rompió: no se te dice directamente. Vas a tener que
diagnosticarlo vos mismo con las herramientas de troubleshooting.

Síntoma que vas a observar:
  - kubectl (apuntando a la VIP del control plane$( [[ -n "${vip}" ]] && echo " en ${vip}" )
    en el kubeconfig) empieza a fallar o tardar mucho, con errores
    tipo "connection refused" o "context deadline exceeded" contra
    el puerto 6443.
  - curl -k https://<VIP>:6443/version también falla o cuelga.
  - "systemctl status haproxy" muestra el servicio activo (running),
    pero "echo 'show stat' | socat stdio tcp-connect:127.0.0.1:9000"
    (si está habilitado el stats socket), o los logs de haproxy
    (journalctl -u haproxy), muestran los backends del apiserver
    en estado DOWN.
  - Si accedés directo a cualquier nodo control-plane por su IP y
    puerto 6443 (sin pasar por la VIP), el apiserver responde bien:
    el problema está en el load balancer, no en los nodos control-plane.

Qué tenés que lograr:
  1) Identificar por qué el load balancer no puede alcanzar a los
     kube-apiserver de los nodos control-plane.
  2) Corregir la configuración de haproxy sin reinstalar nada ni
     tocar los nodos control-plane.
  3) Validar la configuración antes de aplicarla (evitar romper la
     sintaxis) y recargar/reiniciar el servicio correspondiente.
  4) Confirmar que kubectl vuelve a funcionar contra la VIP y que
     "kubectl get nodes" devuelve la lista completa de nodos Ready.

Archivo involucrado: ${HAPROXY_CFG}
Backup de seguridad (NO lo mires todavía si querés practicar el
diagnóstico real): ${backup_file}
============================================================

EOF
}

do_restore() {
  require_root
  if [[ ! -f "${BACKUP_DIR}/last-cfg-path" || ! -f "${BACKUP_DIR}/last-backup-path" ]]; then
    echo "No hay un backup registrado para restaurar." >&2
    exit 1
  fi
  local cfg_path backup_path
  cfg_path=$(cat "${BACKUP_DIR}/last-cfg-path")
  backup_path=$(cat "${BACKUP_DIR}/last-backup-path")
  cp -a "${backup_path}" "${cfg_path}"
  systemctl restart haproxy
  echo "Restaurado ${cfg_path} desde ${backup_path} y haproxy reiniciado."
}

case "${1:-}" in
  break)
    do_break
    ;;
  restore)
    do_restore
    ;;
  *)
    usage
    ;;
esac

# ============================================================================
# SOLUCIÓN PASO A PASO (no leer hasta intentar resolverlo solo)
# ============================================================================
#
# 1. Confirmar que el problema es de conectividad hacia el apiserver a
#    través de la VIP, no del cluster en sí:
#      curl -k -m 5 https://<VIP>:6443/version
#      (falla / timeout)
#
# 2. Descartar los nodos control-plane: entrar a cualquiera de ellos y
#    probar el apiserver localmente:
#      curl -k -m 5 https://127.0.0.1:6443/version
#      (responde bien -> el apiserver está sano, el problema es el LB)
#
# 3. En la VM del load balancer, revisar el estado del servicio y del
#    backend de haproxy:
#      systemctl status haproxy
#      journalctl -u haproxy -n 50 --no-pager
#      echo "show stat" | socat stdio tcp-connect:127.0.0.1:9000
#      (muestra los servers del backend "apiserver" en estado DOWN)
#
# 4. Revisar la configuración de haproxy:
#      cat /etc/haproxy/haproxy.cfg
#    Buscar la sección "backend" con las líneas:
#      server <nombre-nodo> <IP-nodo>:16443 check
#    El puerto 16443 es incorrecto: kube-apiserver escucha en 6443 en
#    cada nodo control-plane, no en 16443.
#
# 5. Corregir el puerto en cada línea "server ... check" del backend,
#    dejándolo en 6443:
#      sed -i -E 's/(server\s+\S+\s+\S+):16443(\s+check.*)/\1:6443\2/' \
#        /etc/haproxy/haproxy.cfg
#
# 6. Validar la sintaxis antes de aplicar cambios en caliente:
#      haproxy -c -f /etc/haproxy/haproxy.cfg
#
# 7. Reiniciar (o recargar) el servicio para que tome la configuración:
#      systemctl restart haproxy
#
# 8. Verificar que los backends vuelven a estar UP:
#      echo "show stat" | socat stdio tcp-connect:127.0.0.1:9000
#
# 9. Verificar la recuperación end-to-end desde una máquina con el
#    kubeconfig apuntando a la VIP:
#      curl -k https://<VIP>:6443/version
#      kubectl get nodes
#      kubectl get componentstatuses   (o kubectl get --raw='/healthz')
#    Todos los nodos control-plane deben aparecer Ready y kubectl debe
#    responder con normalidad, confirmando que el control plane HA
#    volvió a estar accesible a través del load balancer.
# ============================================================================