#!/usr/bin/env bash
#===============================================================================
# LAB BREAK & FIX — LPI Linux Essentials (010-160, versión 1.6)
# Tema 4.3: Where Data is Stored (peso: 3)
#
# Referencia de estudio (citada, no copiada):
#   https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
#
# ¿Qué practica este laboratorio?
#   - Que la configuración del sistema vive en /etc (archivos de texto plano).
#   - Resolución de nombres local con /etc/hosts.
#   - Mensajería y logging del sistema: logger, journalctl, /var/log.
#   - Inspección del sistema en vivo: /proc, dmesg, ps.
#
# ADVERTENCIA DE SEGURIDAD
#   Ejecutar SOLO en una VM de laboratorio DESCARTABLE. El script pide
#   confirmación explícita, hace backup de todo lo que toca y NO borra
#   datos, pero no está pensado para máquinas reales.
#
# USO:
#   sudo ./lab43-break-fix.sh break    # rompe el sistema de forma controlada
#   sudo ./lab43-break-fix.sh check    # verifica si el estudiante lo arregló
#   sudo ./lab43-break-fix.sh reset    # restaura el estado original (rendirse)
#===============================================================================

set -u

BACKUP_DIR="/root/.lab43-backup"
MARKER="${BACKUP_DIR}/lab43.activo"
HOSTNAME_LAB="app.lab"
IP_ROTA="203.0.113.99"      # Rango TEST-NET-3 (RFC 5737): nunca rutea, es seguro
IP_CORRECTA="127.0.0.1"
TAG_LOG="lab43"

#-------------------------------------------------------------------------------
# Utilidades
#-------------------------------------------------------------------------------
msg()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[X]\033[0m %s\n' "$*"; }

requiere_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        fail "Este script necesita privilegios de root. Ejecutalo con: sudo $0 $*"
        exit 1
    fi
}

confirmar_vm() {
    printf '\n\033[1;33m¡ATENCIÓN!\033[0m Esto modifica /etc/hosts en esta máquina.\n'
    printf 'Solo continúa si esto es una VM de laboratorio descartable.\n'
    read -r -p "Escribí exactamente SI-ES-UNA-VM para continuar: " respuesta
    if [[ "${respuesta}" != "SI-ES-UNA-VM" ]]; then
        fail "Confirmación no recibida. No se hizo ningún cambio."
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# BREAK: rompe la resolución de nombres local de forma controlada
#-------------------------------------------------------------------------------
do_break() {
    requiere_root
    if [[ -f "${MARKER}" ]]; then
        fail "El laboratorio ya está activo. Usá 'check' o 'reset'."
        exit 1
    fi
    confirmar_vm

    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"

    # Backup íntegro del archivo que vamos a tocar
    cp -a /etc/hosts "${BACKUP_DIR}/hosts.original"

    # LA ROTURA: una entrada falsa en /etc/hosts que apunta el hostname
    # de la "aplicación interna" a una IP inalcanzable (TEST-NET, RFC 5737).
    {
        echo ""
        echo "# entrada agregada por mantenimiento (lab43)"
        echo "${IP_ROTA}   ${HOSTNAME_LAB}"
    } >> /etc/hosts

    # PISTA ESCONDIDA EN EL LOGGING DEL SISTEMA: el estudiante practica
    # buscar mensajes con journalctl / /var/log, tal como pide el tema 4.3.
    logger -t "${TAG_LOG}" "AVISO: se modifico un archivo de configuracion en /etc relacionado con resolucion de nombres. Revisa /etc/hosts."

    touch "${MARKER}"

    cat <<'EOF'

===============================================================================
 ESCENARIO PARA EL ESTUDIANTE
===============================================================================
 Sos el nuevo sysadmin. Los usuarios reportan que la aplicación interna
 dejó de responder después de un "mantenimiento" de anoche.

 SÍNTOMA QUE VAS A VER:
   $ ping -c 2 app.lab
   ... no responde (timeout), o responde una IP rara: 203.0.113.99

   $ getent hosts app.lab
   203.0.113.99   app.lab      <-- esa IP no es de tu red

 OBJETIVO (condición de éxito):
   Lograr que "app.lab" vuelva a resolver a 127.0.0.1 y que
   "ping -c 2 app.lab" responda. Verificalo con:
       sudo ./lab43-break-fix.sh check

 PISTAS (conceptos del tema 4.3 - Where Data is Stored):
   1. ¿Dónde guarda Linux la configuración del sistema? Es un directorio
      de archivos de TEXTO PLANO que podés leer con less/cat.
   2. Antes de que exista el DNS, hay un archivo local que traduce
      nombres a direcciones IP. Está en ese mismo directorio.
   3. El "mantenimiento" dejó rastros en el logging del sistema.
      Probá: journalctl -t lab43        (systemd journal)
      o bien: grep lab43 /var/log/syslog  (o /var/log/messages en RPM)
   4. Para investigar el sistema en vivo también tenés /proc (por ejemplo
      /proc/cpuinfo, /proc/meminfo) y dmesg para mensajes del kernel;
      no arreglan esto, pero repasalos: entran en el examen.

 NO uses 'reset' salvo que quieras rendirte: eso restaura todo solo.
===============================================================================
EOF
}

#-------------------------------------------------------------------------------
# CHECK: verifica si el estudiante arregló el problema
#-------------------------------------------------------------------------------
do_check() {
    requiere_root
    if [[ ! -f "${MARKER}" ]]; then
        fail "El laboratorio no está activo. Ejecutá primero: sudo $0 break"
        exit 1
    fi

    resuelto="$(getent hosts "${HOSTNAME_LAB}" | awk '{print $1}' | head -n1)"

    if [[ "${resuelto}" == "${IP_CORRECTA}" ]]; then
        ok "'${HOSTNAME_LAB}' resuelve a ${IP_CORRECTA}."
        if ping -c 1 -W 2 "${HOSTNAME_LAB}" >/dev/null 2>&1; then
            ok "ping a ${HOSTNAME_LAB} responde."
            msg "¡LABORATORIO RESUELTO! Aprendiste que la configuración vive en /etc y que los logs (journal / /var/log) cuentan la historia de lo que pasó."
            rm -f "${MARKER}"
        else
            fail "Resuelve bien pero el ping no responde. Revisá que la entrada quede: ${IP_CORRECTA}   ${HOSTNAME_LAB}"
        fi
    elif [[ "${resuelto}" == "${IP_ROTA}" ]]; then
        fail "'${HOSTNAME_LAB}' todavía resuelve a ${IP_ROTA} (la IP rota)."
        echo "    Pista: ¿ya miraste el archivo de hosts dentro de /etc?"
    elif [[ -z "${resuelto}" ]]; then
        fail "'${HOSTNAME_LAB}' no resuelve a nada. Borraste la entrada en vez de corregirla."
        echo "    Pista: agregá la línea correcta apuntando a ${IP_CORRECTA}."
    else
        fail "'${HOSTNAME_LAB}' resuelve a ${resuelto}, que no es ${IP_CORRECTA}."
    fi
}

#-------------------------------------------------------------------------------
# RESET: restaura el estado original (para rendirse o re-hacer el lab)
#-------------------------------------------------------------------------------
do_reset() {
    requiere_root
    if [[ ! -f "${BACKUP_DIR}/hosts.original" ]]; then
        fail "No hay backup en ${BACKUP_DIR}. Nada que restaurar."
        exit 1
    fi
    cp -a "${BACKUP_DIR}/hosts.original" /etc/hosts
    rm -f "${MARKER}"
    ok "/etc/hosts restaurado desde el backup. Laboratorio reiniciado."
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
case "${1:-}" in
    break) do_break ;;
    check) do_check ;;
    reset) do_reset ;;
    *)
        echo "Uso: sudo $0 {break|check|reset}"
        echo "  break : rompe el sistema de forma controlada (solo VM de lab)"
        echo "  check : verifica si lo arreglaste"
        echo "  reset : restaura el estado original"
        exit 1
        ;;
esac

exit 0

#===============================================================================
# SOLUCIÓN PASO A PASO (¡NO LEER hasta intentarlo!)
#===============================================================================
#
# Paso 1 — Confirmar el síntoma:
#   $ ping -c 2 app.lab
#   $ getent hosts app.lab
#   Vemos que app.lab resuelve a 203.0.113.99, una IP que no responde.
#
# Paso 2 — Buscar rastros en el logging del sistema (tema 4.3):
#   $ journalctl -t lab43
#   (en sistemas con syslog clásico: grep lab43 /var/log/syslog
#    o grep lab43 /var/log/messages)
#   El mensaje dice que se tocó un archivo de configuración en /etc
#   relacionado con resolución de nombres.
#
# Paso 3 — Recordar dónde se guarda la configuración:
#   En Linux, la configuración del sistema vive en /etc como archivos de
#   texto plano. La resolución de nombres LOCAL se define en /etc/hosts
#   (formato: IP  nombre). El orden de consulta (hosts primero, DNS
#   después) lo controla /etc/nsswitch.conf.
#
# Paso 4 — Inspeccionar el archivo:
#   $ cat /etc/hosts
#   Al final aparece la línea agregada por el "mantenimiento":
#       # entrada agregada por mantenimiento (lab43)
#       203.0.113.99   app.lab
#
# Paso 5 — Corregir con un editor de texto (como root):
#   $ sudo nano /etc/hosts        # o vi /etc/hosts
#   Cambiar la línea rota para que quede:
#       127.0.0.1   app.lab
#   (Alternativa en una sola línea, si preferís sed:
#    $ sudo sed -i 's/^203\.0\.113\.99[[:space:]]\+app\.lab/127.0.0.1   app.lab/' /etc/hosts )
#
# Paso 6 — Verificar la reparación:
#   $ getent hosts app.lab        -> 127.0.0.1  app.lab
#   $ ping -c 2 app.lab           -> responde
#   $ sudo ./lab43-break-fix.sh check   -> ¡LABORATORIO RESUELTO!
#
# Repaso de conceptos del tema 4.3 que usaste:
#   - /etc          : configuración del sistema en texto plano (/etc/hosts).
#   - journalctl    : consulta del systemd journal; logger escribe en él.
#   - /var/log      : logs tradicionales (syslog, messages, dmesg, etc.).
#   - dmesg         : mensajes del ring buffer del kernel (hardware, boot).
#   - /proc y /sys  : pseudo-filesystems con datos del kernel en vivo
#                     (procesos por PID, /proc/cpuinfo, /proc/meminfo).
#
# Fuente de referencia:
#   https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
#===============================================================================