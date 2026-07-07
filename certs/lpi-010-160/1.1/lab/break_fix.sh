#!/usr/bin/env bash
#
# ============================================================================
#  LAB BREAK & FIX — LPI Linux Essentials (010-160, versión 1.6)
#  Tema 1.1: Linux Evolution and Popular Operating Systems (peso: 2)
#
#  Fuente de referencia (consultada, no copiada):
#    https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
#
#  ADVERTENCIA: Ejecutar SOLO en una VM de laboratorio descartable.
#  El script hace un backup de todo lo que modifica y NO toca datos
#  de usuario, pero no está pensado para máquinas de producción.
#
#  Uso:
#     sudo ./lab-1.1-break-fix.sh break    # rompe el escenario
#     sudo ./lab-1.1-break-fix.sh status   # muestra el estado del lab
#     sudo ./lab-1.1-break-fix.sh restore  # restaura todo (salida de emergencia)
# ============================================================================

set -euo pipefail

LAB_DIR="/root/.lab-1.1-backup"
OS_RELEASE="/etc/os-release"
ISSUE="/etc/issue"

# ----------------------------------------------------------------------------
# Comprobaciones previas
# ----------------------------------------------------------------------------
requiere_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: este script necesita privilegios de root. Usá: sudo $0 $*" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# BREAK: rompemos la identificación de la distribución
# ----------------------------------------------------------------------------
do_break() {
    requiere_root

    if [[ -d "$LAB_DIR" ]]; then
        echo "El lab ya está roto. Usá 'status' para ver los síntomas o 'restore' para salir." >&2
        exit 1
    fi

    mkdir -p "$LAB_DIR"
    chmod 700 "$LAB_DIR"

    # Backup de seguridad de todo lo que vamos a tocar
    cp -a "$OS_RELEASE" "$LAB_DIR/os-release.bak" 2>/dev/null || true
    cp -a "$ISSUE"      "$LAB_DIR/issue.bak"      2>/dev/null || true
    # /etc/os-release suele ser un symlink a /usr/lib/os-release: registramos eso
    if [[ -L "$OS_RELEASE" ]]; then
        readlink "$OS_RELEASE" > "$LAB_DIR/os-release.symlink"
    fi

    # LA ROTURA (controlada y reversible):
    # Reemplazamos /etc/os-release por un archivo falso que identifica el
    # sistema como una distribución inexistente, y ensuciamos /etc/issue.
    rm -f "$OS_RELEASE"
    cat > "$OS_RELEASE" <<'EOF'
NAME="MysteryOS"
VERSION="0.0 (Broken Lab)"
ID=mysteryos
PRETTY_NAME="MysteryOS 0.0 — esta NO es tu distribución real"
HOME_URL="https://example.invalid/"
EOF
    echo "MysteryOS 0.0 \n \l" > "$ISSUE"

    clear
    cat <<'EOF'
============================================================================
 ESCENARIO ROTO — LAB 1.1: ¿Qué distribución estoy usando?
============================================================================

 CONTEXTO (lo que estudiás en el tema 1.1):
   Linux no es un único sistema operativo: el kernel Linux se combina con
   herramientas GNU y otro software para formar "distributions" (Debian,
   Ubuntu, Fedora, openSUSE, etc.). Todo sysadmin necesita saber identificar
   en qué distribución está parado, porque de eso dependen el package
   manager, los ciclos de release y el soporte.

 SÍNTOMA QUE VAS A VER:
   Ejecutá cualquiera de estos comandos:

       cat /etc/os-release
       hostnamectl        (si tu sistema usa systemd)
       lsb_release -a     (si está instalado)

   Todos van a decir que estás en "MysteryOS 0.0", una distribución que
   NO EXISTE. El banner de login en consola (/etc/issue) también miente.

 TU MISIÓN:
   1. Descubrí cuál es la distribución REAL de esta VM sin confiar en
      /etc/os-release. Pistas para investigar:
        - ¿El archivo /etc/os-release era originalmente un symlink? ¿A dónde?
        - ¿Qué package manager responde? (apt, dnf, zypper, pacman...)
        - ¿Qué dice 'uname -a' sobre el kernel? ¿El kernel identifica
          la distribución o solo el kernel? (pensá por qué)
   2. Restaurá /etc/os-release y /etc/issue para que el sistema vuelva a
      identificarse correctamente.

 CRITERIO DE ÉXITO:
       cat /etc/os-release
   debe mostrar de nuevo tu distribución real, y 'hostnamectl' (si aplica)
   debe reflejarla.

 Si te trabás: la solución paso a paso está comentada al final del script.
 Salida de emergencia: sudo ./lab-1.1-break-fix.sh restore
============================================================================
EOF
}

# ----------------------------------------------------------------------------
# STATUS: ¿el lab sigue roto?
# ----------------------------------------------------------------------------
do_status() {
    if grep -q "mysteryos" "$OS_RELEASE" 2>/dev/null; then
        echo "[ROTO] /etc/os-release sigue identificando 'MysteryOS'. Seguí investigando."
    else
        echo "[OK] /etc/os-release ya no miente. Verificá con: cat /etc/os-release && hostnamectl"
        if [[ -d "$LAB_DIR" ]]; then
            echo "Nota: quedan backups en $LAB_DIR. Podés borrarlos cuando termines."
        fi
    fi
}

# ----------------------------------------------------------------------------
# RESTORE: salida de emergencia (deshace todo automáticamente)
# ----------------------------------------------------------------------------
do_restore() {
    requiere_root

    if [[ ! -d "$LAB_DIR" ]]; then
        echo "No hay backups del lab. Nada que restaurar." >&2
        exit 1
    fi

    rm -f "$OS_RELEASE"
    if [[ -f "$LAB_DIR/os-release.symlink" ]]; then
        ln -s "$(cat "$LAB_DIR/os-release.symlink")" "$OS_RELEASE"
    elif [[ -f "$LAB_DIR/os-release.bak" ]]; then
        cp -a "$LAB_DIR/os-release.bak" "$OS_RELEASE"
    fi
    [[ -f "$LAB_DIR/issue.bak" ]] && cp -a "$LAB_DIR/issue.bak" "$ISSUE"

    rm -rf "$LAB_DIR"
    echo "Restaurado. Verificá con: cat /etc/os-release"
}

# ----------------------------------------------------------------------------
case "${1:-}" in
    break)   do_break   ;;
    status)  do_status  ;;
    restore) do_restore ;;
    *)
        echo "Uso: sudo $0 {break|status|restore}" >&2
        exit 1
        ;;
esac

exit 0

# ============================================================================
#  SOLUCIÓN PASO A PASO (no mirar hasta intentarlo)
# ============================================================================
#
#  PASO 1 — Confirmar el síntoma:
#      cat /etc/os-release
#      hostnamectl
#    Ambos muestran "MysteryOS", que no existe. Conclusión: alguien alteró
#    los archivos de identificación, no el sistema en sí.
#
#  PASO 2 — Entender qué identifica cada cosa:
#      uname -a
#    'uname' consulta al KERNEL: muestra versión del kernel Linux y la
#    arquitectura, pero NO la distribución. Esto refuerza el concepto clave
#    del tema 1.1: "Linux" es solo el kernel; la distribución es el kernel
#    más el userland (herramientas GNU, package manager, etc.).
#
#  PASO 3 — Identificar la distribución real sin /etc/os-release:
#    a) Ver si existe la copia canónica que muchos sistemas symlinkan:
#           cat /usr/lib/os-release
#       En la mayoría de las distros modernas, /etc/os-release es un
#       symlink a /usr/lib/os-release, y ese archivo sigue intacto.
#    b) Confirmar por el package manager (cada familia tiene el suyo):
#           command -v apt   && echo "familia Debian/Ubuntu"
#           command -v dnf   && echo "familia Red Hat/Fedora"
#           command -v zypper && echo "familia openSUSE"
#           command -v pacman && echo "familia Arch"
#    c) Archivos específicos de familia, si existen:
#           cat /etc/debian_version   # Debian/Ubuntu
#           cat /etc/redhat-release   # RHEL/Fedora/CentOS
#
#  PASO 4 — Reparar /etc/os-release:
#    Caso A (lo más común): restaurar el symlink original:
#        sudo rm /etc/os-release
#        sudo ln -s /usr/lib/os-release /etc/os-release
#    Caso B (si tu distro usa archivo regular): copiar desde el backup
#    que dejó el script:
#        sudo cp /root/.lab-1.1-backup/os-release.bak /etc/os-release
#
#  PASO 5 — Reparar el banner de consola:
#        sudo cp /root/.lab-1.1-backup/issue.bak /etc/issue
#
#  PASO 6 — Verificar:
#        cat /etc/os-release
#        hostnamectl
#    Deben mostrar la distribución real. Después limpiá los backups:
#        sudo rm -rf /root/.lab-1.1-backup
#
#  QUÉ TE LLEVÁS DE ESTE LAB (mapeado al tema 1.1):
#    - Diferencia entre kernel (Linux, lo que reporta 'uname') y
#      distribution (lo que reporta /etc/os-release).
#    - Las familias de distribuciones se reconocen por su package manager
#      y sus archivos de release.
#    - /etc/os-release es el estándar moderno de identificación y suele
#      ser un symlink a /usr/lib/os-release.
#
#  Referencia: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
# ============================================================================