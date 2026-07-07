#!/usr/bin/env bash
#
# =============================================================================
#  LAB BREAK & FIX - LPI Linux Essentials (010-160 v1.6)
#  Tema 4.1: Choosing an Operating System (peso: 1)
#
#  Escenario: "El sistema que no sabe quién es"
#
#  Este script rompe, de forma controlada y reversible, la identificación
#  de la distribución del sistema: el archivo /etc/os-release.
#
#  ¿Por qué este archivo? Porque el tema 4.1 trata sobre saber ELEGIR y
#  RECONOCER un sistema operativo: distinguir Linux de Windows y macOS,
#  identificar la distribución, su versión y su ciclo de vida (release
#  cycle, LTS vs rolling release). En Linux, /etc/os-release es la fuente
#  estándar de esa información: la leen herramientas como hostnamectl,
#  lsb_release, neofetch, scripts de instalación y hasta contenedores.
#
#  Referencia: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script hace backup de todo lo que toca y NO borra nada del sistema.
# =============================================================================

set -euo pipefail

LAB_DIR="/root/.lab-4.1-backup"
MARKER="${LAB_DIR}/.lab-active"

# ----------------------------------------------------------------------------
# Comprobaciones de seguridad
# ----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este lab debe ejecutarse como root (probá: sudo $0)" >&2
    exit 1
fi

# Nos negamos a correr si esto no parece una VM (heurística simple, no
# infalible: systemd-detect-virt devuelve 'none' en hardware físico).
if command -v systemd-detect-virt >/dev/null 2>&1; then
    if [[ "$(systemd-detect-virt 2>/dev/null || true)" == "none" ]]; then
        echo "ERROR: esto no parece una máquina virtual." >&2
        echo "Este lab solo debe correrse en una VM descartable. Abortando." >&2
        exit 1
    fi
fi

if [[ -f "$MARKER" ]]; then
    echo "El lab ya está activo. Si querés reiniciarlo, primero resolvelo"
    echo "o restaurá manualmente desde ${LAB_DIR} (ver solución al final)."
    exit 1
fi

if [[ ! -e /etc/os-release && ! -e /usr/lib/os-release ]]; then
    echo "ERROR: no se encontró os-release en este sistema. Lab no aplicable." >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# BREAK: guardamos el estado real y plantamos una identidad falsa
# ----------------------------------------------------------------------------

mkdir -p "$LAB_DIR"
chmod 700 "$LAB_DIR"

# Backup fiel de /etc/os-release, preservando si era symlink o archivo regular
if [[ -L /etc/os-release ]]; then
    readlink /etc/os-release > "${LAB_DIR}/os-release.was-symlink"
elif [[ -f /etc/os-release ]]; then
    cp -a /etc/os-release "${LAB_DIR}/os-release.regular"
fi

# Guardamos también una copia legible del contenido real, como "chuleta"
# de emergencia para el instructor (el estudiante no debería mirar acá).
cat /etc/os-release > "${LAB_DIR}/os-release.contents" 2>/dev/null || true

rm -f /etc/os-release
cat > /etc/os-release <<'EOF'
NAME="MysteryOS"
VERSION="9999 (Amnesia)"
ID=mysteryos
PRETTY_NAME="MysteryOS 9999 (Amnesia)"
VERSION_ID="9999"
HOME_URL="https://example.invalid/"
SUPPORT_END="1970-01-01"
EOF
chmod 644 /etc/os-release

touch "$MARKER"

# ----------------------------------------------------------------------------
# Briefing para el estudiante
# ----------------------------------------------------------------------------

cat <<'EOF'

=============================================================================
 LAB 4.1 ACTIVO: "El sistema que no sabe quién es"
=============================================================================

 SITUACIÓN
 ---------
 Heredaste un servidor de un administrador anterior. Antes de decidir si
 este sistema operativo sigue siendo adecuado (¿tiene soporte?, ¿es una
 versión LTS?, ¿hay que migrar?), necesitás saber QUÉ distribución y QUÉ
 versión es. Pero alguien manipuló su identificación.

 SÍNTOMAS QUE VAS A VER
 ----------------------
 Probá estos comandos y observá que mienten o fallan:

   cat /etc/os-release        -> dice "MysteryOS 9999 (Amnesia)"
   hostnamectl                -> muestra un Operating System falso
   lsb_release -a             -> (si existe) puede mostrar datos raros
   neofetch / screenfetch     -> (si existen) logo o nombre incorrecto

 Además, cualquier script o instalador que lea ID= o VERSION_ID= de
 /etc/os-release va a tomar decisiones equivocadas.

 TU OBJETIVO
 -----------
 1. Averiguar la identidad REAL del sistema SIN usar /etc/os-release.
    Pistas de investigación (esto es lo que evalúa el tema 4.1):
      - uname -a               (kernel, no distro... ¿qué te dice y qué NO?)
      - /usr/lib/os-release    (¿de dónde viene /etc/os-release en realidad?)
      - el package manager     (¿hay apt? ¿dnf? ¿zypper? ¿pacman? cada
                                familia de distros usa uno distinto)
      - /etc/debian_version, /etc/redhat-release, etc. si existen

 2. Restaurar /etc/os-release para que hostnamectl y
    'cat /etc/os-release' vuelvan a mostrar la distribución correcta.

 CRITERIO DE ÉXITO
 -----------------
   grep PRETTY_NAME /etc/os-release   -> muestra tu distro real
   hostnamectl                        -> Operating System correcto

 PREGUNTAS PARA PENSAR (materia del examen)
 ------------------------------------------
 - ¿Qué diferencia hay entre el kernel (lo que muestra uname) y la
   distribución (lo que muestra os-release)?
 - ¿Tu distro es LTS o rolling release? ¿Cómo afecta eso al ciclo de
   vida y a la decisión de "choosing an operating system"?
 - ¿Cómo identificarías la versión en Windows o macOS? ¿Existe algo
   equivalente a os-release?

 La solución paso a paso está comentada al final de este script:
   sudo tail -n 60 "$0"
=============================================================================

EOF

exit 0

# =============================================================================
# SOLUCIÓN PASO A PASO (no leer hasta intentarlo)
# =============================================================================
#
# PASO 1 - Confirmar el síntoma:
#     cat /etc/os-release
#   Muestra "MysteryOS", una distro que no existe. hostnamectl repite el
#   dato porque lee exactamente este archivo.
#
# PASO 2 - Investigar la identidad real sin ese archivo:
#     uname -a
#   Te da kernel, arquitectura y hostname, pero OJO: uname identifica el
#   KERNEL Linux, no la distribución. Ese matiz es materia de examen.
#
#     cat /usr/lib/os-release
#   Acá está la clave: en la mayoría de las distros modernas (systemd),
#   /etc/os-release es un symlink hacia /usr/lib/os-release, que es el
#   archivo que instala el vendor. El "atacante" solo reemplazó el symlink
#   por un archivo falso; el original del vendor sigue intacto.
#
#   Pistas adicionales por familia de distro:
#     command -v apt   && echo "familia Debian/Ubuntu"
#     command -v dnf   && echo "familia Red Hat/Fedora"
#     command -v zypper && echo "familia SUSE"
#     command -v pacman && echo "familia Arch"
#     cat /etc/debian_version 2>/dev/null
#     cat /etc/redhat-release 2>/dev/null
#
# PASO 3 - Restaurar el archivo. Dos caminos válidos:
#
#   Opción A (la correcta en distros systemd): recrear el symlink
#     sudo rm /etc/os-release
#     sudo ln -s ../usr/lib/os-release /etc/os-release
#
#   Opción B: usar el backup que dejó este lab
#     - Si existe /root/.lab-4.1-backup/os-release.was-symlink:
#         sudo rm /etc/os-release
#         sudo ln -s "$(cat /root/.lab-4.1-backup/os-release.was-symlink)" /etc/os-release
#     - Si existe /root/.lab-4.1-backup/os-release.regular:
#         sudo cp -a /root/.lab-4.1-backup/os-release.regular /etc/os-release
#
# PASO 4 - Verificar:
#     cat /etc/os-release      -> PRETTY_NAME correcto
#     hostnamectl              -> Operating System correcto
#
# PASO 5 - Limpiar el lab:
#     sudo rm -rf /root/.lab-4.1-backup
#
# LECCIÓN
# -------
# /etc/os-release es el estándar para identificar una distribución Linux
# (nombre, versión, ID, fin de soporte). Saber leerlo —y saber que uname
# habla del kernel y no de la distro— es exactamente la habilidad que pide
# el tema 4.1: reconocer qué sistema operativo tenés delante y evaluar su
# ciclo de vida (LTS vs rolling release) antes de elegirlo o mantenerlo.
#
# Fuente de referencia:
#   https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
# =============================================================================