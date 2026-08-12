#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-3 306 (examen 306-300, v3.0) — Tema 362.1: DRBD
#  Ejercicio 'break & fix': replicación rota de forma controlada y REVERSIBLE
# ==============================================================================
#
#  Qué hace este script:
#    Rompe la REPLICACIÓN de un recurso DRBD alterando el puerto TCP de la
#    sección de conexión en el fichero '.res' del recurso. NO toca el backing
#    device ni los metadatos DRBD: tus datos están intactos en todo momento.
#    Sólo se pierde la conexión con el peer -> la réplica deja de sincronizar.
#
#  ADVERTENCIA — EJECUTAR SOLO EN UNA VM DE LABORATORIO DESCARTABLE.
#    Este ejercicio asume un cluster DRBD de dos nodos ya funcionando y se
#    ejecuta sobre UNO de los nodos (el que vas a "romper y arreglar"). No lo
#    corras jamás sobre un nodo con datos reales o en producción.
#
#  Uso:
#    sudo ./break_drbd_362_1.sh            # rompe el recurso 'r0' (por defecto)
#    sudo ./break_drbd_362_1.sh r1         # rompe el recurso 'r1'
#    sudo RES=r0 ./break_drbd_362_1.sh -y  # sin confirmación interactiva
#    sudo ./break_drbd_362_1.sh --restore  # revierte al estado original (red)
#
#  Fuentes oficiales de referencia:
#    - LPI 306 objectives: https://www.lpi.org/our-certifications/exam-306-objectives/
#    - DRBD 9.0 User's Guide: https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
#      * Configurar recursos:  .../#s-configure-resource
#      * Estados de conexión:  .../#s-connection-states
#      * Split brain recovery: .../#s-resolve-split-brain
#    - man 5 drbd.conf ; man 8 drbdadm ; man 8 drbdsetup
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Parámetros y flags
# ------------------------------------------------------------------------------
RES="${RES:-r0}"
ASSUME_YES=0
ACTION="break"
DRBD_DIR="/etc/drbd.d"

log()  { printf '\033[1;36m[362.1]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[362.1][WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[362.1][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    --restore)    ACTION="restore" ;;
    --res)        shift; RES="${1:?falta el nombre del recurso}" ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    -*)           die "flag desconocido: $1" ;;
    *)            RES="$1" ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# Guardas de seguridad — no rompemos nada si no es un lab DRBD válido
# ------------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "Ejecutá como root (sudo)."
command -v drbdadm >/dev/null 2>&1 || die "drbdadm no está instalado. ¿Es esta una VM de lab DRBD?"

# El recurso tiene que existir en la configuración, si no, abortamos.
drbdadm dump "$RES" >/dev/null 2>&1 \
  || die "El recurso DRBD '$RES' no está configurado. Abortando por seguridad."

# Localizamos el fichero .res que declara el recurso.
RES_FILE="$(grep -rslE "resource[[:space:]]+${RES}([[:space:]{]|$)" "$DRBD_DIR" 2>/dev/null | head -n1 || true)"
[[ -z "$RES_FILE" && -f "${DRBD_DIR}/${RES}.res" ]] && RES_FILE="${DRBD_DIR}/${RES}.res"
[[ -n "$RES_FILE" && -f "$RES_FILE" ]] \
  || die "No encuentro el .res del recurso '$RES' bajo ${DRBD_DIR}. No edito a ciegas."

PRISTINE="${RES_FILE}.pristine.bak"

show_status() {
  echo "----------------------------------------------------------------------"
  drbdadm status "$RES" 2>/dev/null || cat /proc/drbd 2>/dev/null || true
  echo "----------------------------------------------------------------------"
}

# ------------------------------------------------------------------------------
# --restore : vuelve al estado original de red y reconecta
# ------------------------------------------------------------------------------
if [[ "$ACTION" == "restore" ]]; then
  [[ -f "$PRISTINE" ]] || die "No hay backup pristine ($PRISTINE). Nada que restaurar."
  log "Restaurando configuración de red original de '$RES' desde $PRISTINE ..."
  cat "$PRISTINE" > "$RES_FILE"
  drbdadm dump "$RES" >/dev/null 2>&1 || die "El .res restaurado no parsea. Revisalo a mano."
  drbdadm adjust "$RES" 2>/dev/null || true
  drbdadm connect "$RES" 2>/dev/null || true
  sleep 2
  log "Restaurado. Estado actual:"
  show_status
  exit 0
fi

# ------------------------------------------------------------------------------
# Confirmación interactiva
# ------------------------------------------------------------------------------
CURRENT_ROLE="$(drbdadm role "$RES" 2>/dev/null | head -n1 || echo desconocido)"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  warn "Vas a ROMPER la replicación del recurso DRBD '$RES' (rol actual: $CURRENT_ROLE)."
  warn "Fichero afectado: $RES_FILE  —  Es REVERSIBLE, no toca datos ni metadatos."
  read -r -p "Escribí el nombre del recurso ('$RES') para continuar: " CONFIRM
  [[ "$CONFIRM" == "$RES" ]] || die "Confirmación incorrecta. No se rompió nada."
fi

# No re-romper si ya está roto (pristine ya existe) salvo FORCE=1
if [[ -f "$PRISTINE" && "${FORCE:-0}" -ne 1 ]]; then
  die "Ya existe $PRISTINE — parece que el recurso ya está roto. Usá --restore, o FORCE=1 para re-romper."
fi

# ------------------------------------------------------------------------------
# BREAK: guardamos backup y alteramos el puerto TCP de todas las líneas
#        'address ...:<port>;' del .res (peer inalcanzable).
# ------------------------------------------------------------------------------
[[ -f "$PRISTINE" ]] || cp -a "$RES_FILE" "$PRISTINE"
cp -a "$RES_FILE" "${RES_FILE}.$(date +%Y%m%d-%H%M%S).bak"

TMP="$(mktemp)"
CHANGED="$(awk -v out="$TMP" '
{
  line=$0
  if (line ~ /address/ && match(line, /:[0-9]+;/)) {
    port = substr(line, RSTART+1, RLENGTH-2) + 1
    line = substr(line,1,RSTART) port ";" substr(line, RSTART+RLENGTH)
    c++
  }
  print line > out
}
END { print c+0 }
' "$RES_FILE")"

if [[ "$CHANGED" -eq 0 ]]; then
  rm -f "$TMP" "$PRISTINE"
  die "El .res de '$RES' no tiene ninguna línea 'address ...:<port>;'. Este lab necesita una config estándar de dos nodos."
fi

cat "$TMP" > "$RES_FILE"   # preserva permisos/propietario del original
rm -f "$TMP"

# El fichero roto DEBE seguir parseando (sólo cambió el puerto), para que 'adjust' corra.
drbdadm dump "$RES" >/dev/null 2>&1 || die "El .res quedó inválido inesperadamente. Restaurá con: cat '$PRISTINE' > '$RES_FILE'"

log "Aplicando la config alterada (esto tira la conexión con el peer)..."
drbdadm adjust "$RES"    2>/dev/null || true
drbdadm disconnect "$RES" 2>/dev/null || true
drbdadm connect "$RES"    2>/dev/null || true
sleep 3

# ------------------------------------------------------------------------------
# Briefing para el estudiante
# ------------------------------------------------------------------------------
cat <<EOF

======================================================================
  ROTURA APLICADA — recurso DRBD: $RES   (rol de este nodo: $CURRENT_ROLE)
======================================================================

SÍNTOMA que vas a observar:
  * 'drbdadm status $RES' NO muestra 'Connected'. Verás la conexión en
    'connection:Connecting' (DRBD 9) o 'cs:WFConnection' (DRBD 8, en
    /proc/drbd): el nodo intenta hablar con el peer y nunca lo logra.
  * El disco local sigue 'UpToDate' y, si este nodo es Primary, la
    aplicación sigue escribiendo... pero YA NO se replica al peer. La
    protección de datos está silenciosamente degradada (peer 'Unknown'
    / diskless desde esta vista).
  * En el log del kernel (dmesg | tail  /  journalctl -k) verás intentos
    de conexión fallidos / 'Connection closed' / timeouts hacia el peer.

OBJETIVO (qué tenés que lograr para considerarlo ARREGLADO):
  Devolver el recurso a 'Connected' con AMBOS discos 'UpToDate/UpToDate'
  y la replicación al día, SIN destruir datos. Pista de método, no de
  respuesta: comparás la config EFECTIVA con la del peer y con la
  convención de puertos del recurso.

Herramientas que te conviene usar (no reveladas en el fix, descubrilas):
  drbdadm status $RES   |  drbdadm cstate $RES   |  drbdadm dump $RES
  journalctl -k | tail  |  ss -lntp | grep 77    |  \$EDITOR $RES_FILE
  drbdadm adjust $RES   |  drbdadm connect $RES

Red de seguridad: si te trabás, revertí todo con:
  sudo $0 --restore
(Backup original intacto en: $PRISTINE)

Estado actual:
EOF
show_status

exit 0

# ==============================================================================
#  SOLUCIÓN PASO A PASO  (spoiler — resolvé primero por tu cuenta)
# ==============================================================================
#
#  Diagnóstico
#  -----------
#  1) Confirmá el síntoma y el estado de la conexión:
#
#         drbdadm status r0
#         # connection: Connecting        <- nunca llega a Connected
#         # o, en DRBD 8:
#         cat /proc/drbd
#         # cs:WFConnection ro:Primary/Unknown ds:UpToDate/DUnknown
#
#     'WFConnection'/'Connecting' = capa de red rota; el disco local está
#     sano (UpToDate). No es split-brain: es un peer inalcanzable.
#
#  2) Mirá el log del kernel para ver POR QUÉ no conecta:
#
#         journalctl -k | tail -n 30
#         dmesg | grep -i drbd | tail
#         # ...conexión hacia el peer que expira / se cierra una y otra vez.
#
#  3) Verificá si el socket local escucha donde debería y a dónde disca:
#
#         ss -lntp | grep -E '77[0-9][0-9]'      # puerto de escucha DRBD
#         drbdadm dump r0                        # config EFECTIVA parseada
#
#     Comparás el puerto que aparece en las líneas 'address ...:<port>;'
#     de la config con el que usa el peer (7788/7789 por convención, o el
#     que tenga tu recurso). Vas a ver que el/los puerto/s de la sección
#     de conexión NO coinciden con los del nodo peer: están corridos.
#
#  Reparación
#  ----------
#  4) Editá el .res y corregí el puerto de las líneas 'address':
#
#         sudo "$EDITOR" /etc/drbd.d/r0.res
#         # dejá el mismo puerto en ambos nodos (p.ej. 7788), igual que el peer.
#
#     Atajo equivalente (restaura la sección de red original tal cual estaba):
#
#         sudo cp /etc/drbd.d/r0.res.pristine.bak /etc/drbd.d/r0.res
#         #  — o —
#         sudo ./break_drbd_362_1.sh --restore
#
#  5) Validá la sintaxis ANTES de aplicar (nunca apliques a ciegas):
#
#         drbdadm dump r0
#
#  6) Aplicá la config corregida y reconectá:
#
#         drbdadm adjust r0
#         # si sigue StandAlone/desconectado, forzá el ciclo de conexión:
#         drbdadm disconnect r0
#         drbdadm connect r0
#
#  Verificación
#  ------------
#  7) Confirmá que volvió a 'Connected' y 'UpToDate/UpToDate':
#
#         drbdadm status r0
#         # r0 role:Primary
#         #   disk:UpToDate
#         #   peer role:Secondary
#         #     replication:Established peer-disk:UpToDate
#
#  8) Probá que la replicación realmente fluye (opcional, en el Primary):
#
#         mount /dev/drbd0 /mnt   # sólo si el recurso ya tiene FS
#         dd if=/dev/zero of=/mnt/test.bin bs=1M count=50 conv=fsync
#         drbdadm status r0       # replication:Established, sin backlog
#         rm -f /mnt/test.bin ; umount /mnt
#
#  Nota didáctica (362.1)
#  ----------------------
#  El puerto vive en la sección de conexión de cada recurso, dentro de los
#  bloques 'on <host> { ... address <ip>:<port>; }' (o del bloque
#  'connection'/'host' en configuraciones DRBD 9 con node-id). DRBD escucha
#  y disca por TCP en ese puerto: si no coincide entre peers, el recurso se
#  queda esperando conexión (WFConnection/Connecting) aunque el disco esté
#  perfecto. Este es el modo de fallo "la réplica dejó de sincronizar y
#  nadie se enteró": el Primary sigue sirviendo, pero sin redundancia. Por
#  eso monitorear 'connection'/'peer-disk', no sólo el rol, es parte del
#  trabajo de operación de DRBD.
#
#  Ref.: DRBD 9.0 User's Guide, "Configuring resources" y "Connection states"
#        https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-configure-resource
#        https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-connection-states
# ==============================================================================