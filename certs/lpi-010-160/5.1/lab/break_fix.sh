#!/usr/bin/env bash
#
# =============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160, versión 1.6)
#  Tema 5.1: Basic Security and Identifying User Types (peso: 2)
#
#  Referencia consultada (no se copia texto literal):
#    https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
#
#  ⚠️  USAR SOLO EN UNA VM DE LABORATORIO DESCARTABLE.
#  El script crea un usuario de práctica ("opslab") y luego lo "rompe" de
#  forma controlada. NO toca usuarios reales ni archivos del sistema más
#  allá de las bases de cuentas (/etc/passwd, /etc/shadow, /etc/group),
#  siempre mediante herramientas estándar (usermod, passwd, gpasswd).
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# 0. Verificaciones de seguridad previas
# ----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse como root (probá: sudo $0)" >&2
    exit 1
fi

LAB_USER="opslab"
LAB_PASS="Lab010160!"

# Grupo administrativo según la distro (sudo en Debian/Ubuntu, wheel en RHEL/Fedora)
if getent group sudo >/dev/null; then
    ADMIN_GROUP="sudo"
elif getent group wheel >/dev/null; then
    ADMIN_GROUP="wheel"
else
    echo "ERROR: no encuentro un grupo administrativo (sudo/wheel)." >&2
    exit 1
fi

echo "============================================================"
echo " LAB 5.1 — Basic Security and Identifying User Types"
echo "============================================================"
echo
echo "Este lab va a crear y luego ROMPER (de forma controlada) al"
echo "usuario de práctica '${LAB_USER}' en esta máquina."
echo
read -r -p "¿Confirmás que esto es una VM descartable de laboratorio? (escribí SI): " CONFIRM
if [[ "${CONFIRM}" != "SI" ]]; then
    echo "Cancelado. No se modificó nada."
    exit 0
fi

# ----------------------------------------------------------------------------
# 1. Preparación: crear el usuario de laboratorio en estado SANO
# ----------------------------------------------------------------------------

if id "${LAB_USER}" &>/dev/null; then
    echo "El usuario '${LAB_USER}' ya existe; se reutiliza para el lab."
else
    useradd -m -c "Usuario de laboratorio 5.1" -s /bin/bash "${LAB_USER}"
    echo "${LAB_USER}:${LAB_PASS}" | chpasswd
    echo "Usuario '${LAB_USER}' creado con password '${LAB_PASS}'."
fi

# Lo agregamos al grupo administrativo para que pueda usar sudo (estado sano)
usermod -aG "${ADMIN_GROUP}" "${LAB_USER}"

echo
echo "Estado SANO de referencia (guardalo mentalmente):"
echo "--------------------------------------------------"
id "${LAB_USER}"
getent passwd "${LAB_USER}"
echo "--------------------------------------------------"
echo
read -r -p "Presioná ENTER para romper el sistema..." _

# ----------------------------------------------------------------------------
# 2. BREAK — tres roturas controladas sobre el usuario de laboratorio
# ----------------------------------------------------------------------------

# Rotura A: le cambiamos el login shell a uno que no permite sesión interactiva
usermod -s /usr/sbin/nologin "${LAB_USER}" 2>/dev/null \
    || usermod -s /sbin/nologin "${LAB_USER}"

# Rotura B: bloqueamos su password en /etc/shadow (aparece un '!' delante del hash)
passwd -l "${LAB_USER}" >/dev/null

# Rotura C: lo sacamos del grupo administrativo (pierde sudo)
gpasswd -d "${LAB_USER}" "${ADMIN_GROUP}" >/dev/null

clear
cat <<EOF
============================================================
 💥 SISTEMA ROTO — LEÉ CON ATENCIÓN
============================================================

ESCENARIO:
  Un "compañero distraído" hizo cambios en la cuenta '${LAB_USER}'
  y ahora ese usuario quedó inutilizable. Tu trabajo es diagnosticar
  QUÉ tipo de cambios sufrió la cuenta y devolverla a su estado sano.

SÍNTOMAS QUE VAS A VER:
  1. Si intentás "su - ${LAB_USER}" desde root, te muestra un mensaje
     tipo "This account is currently not available." y no abre shell.
  2. Si intentás loguearte como ${LAB_USER} con el password
     '${LAB_PASS}' (en una consola o por ssh), falla aunque el
     password sea correcto: la cuenta está bloqueada.
  3. Aunque arregles lo anterior, "sudo" le va a decir a ${LAB_USER}
     que no está en el archivo sudoers / no tiene permisos.

OBJETIVOS (criterio de éxito):
  [ ] ${LAB_USER} tiene de nuevo /bin/bash como login shell
      (verificalo con: getent passwd ${LAB_USER}).
  [ ] El password de ${LAB_USER} está desbloqueado
      (verificalo con: passwd -S ${LAB_USER}  → debe decir "P" o
      "PS", no "L" / "LK"; y "su - ${LAB_USER}" debe funcionar).
  [ ] ${LAB_USER} vuelve a pertenecer al grupo '${ADMIN_GROUP}'
      (verificalo con: id ${LAB_USER}) y puede ejecutar
      "sudo whoami" obteniendo "root".

HERRAMIENTAS DEL TEMA 5.1 QUE TE CONVIENE USAR PARA DIAGNOSTICAR:
  id, who, w, last, su, sudo
  getent passwd / getent group  (o mirar /etc/passwd y /etc/group)
  passwd -S <usuario>           (estado del password)

PISTAS CONCEPTUALES:
  - El séptimo campo de /etc/passwd es el login shell. Los usuarios
    de sistema (system accounts) suelen tener /usr/sbin/nologin ahí:
    compará ${LAB_USER} con un usuario de sistema como 'daemon'.
  - Un '!' delante del hash en /etc/shadow significa cuenta bloqueada.
  - Los privilegios de sudo suelen venir de pertenecer al grupo
    '${ADMIN_GROUP}' (mirá /etc/group y la salida de id).

Cuando creas que terminaste, verificá los tres objetivos.
La solución paso a paso está comentada al final de este script:
  less $(realpath "$0" 2>/dev/null || echo "$0")

¡Éxitos! 🐧
============================================================
EOF

exit 0

# =============================================================================
# 🔑 SOLUCIÓN PASO A PASO (no mires hasta haberlo intentado)
# =============================================================================
#
# --- Diagnóstico ------------------------------------------------------------
#
# 1) Ver la entrada del usuario en la base de cuentas:
#       getent passwd opslab
#    Salida rota (ejemplo):
#       opslab:x:1001:1001:Usuario de laboratorio 5.1:/home/opslab:/usr/sbin/nologin
#    El último campo (login shell) es /usr/sbin/nologin: por eso "su - opslab"
#    dice "This account is currently not available". Ese shell es típico de
#    cuentas de sistema (compará con: getent passwd daemon).
#
# 2) Ver el estado del password:
#       passwd -S opslab
#    Salida rota (ejemplo):
#       opslab L 2026-07-07 ...      ← "L" (o "LK") = locked
#    También podés mirarlo directo (solo root puede leer /etc/shadow):
#       grep '^opslab:' /etc/shadow
#    Vas a ver un '!' delante del hash: cuenta bloqueada.
#
# 3) Ver grupos del usuario:
#       id opslab
#    En la salida rota NO aparece el grupo administrativo (sudo o wheel),
#    por eso sudo le niega privilegios. Confirmalo con:
#       getent group sudo        # (o: getent group wheel)
#
# --- Reparación (como root) --------------------------------------------------
#
# Paso 1 — Restaurar el login shell interactivo:
#       usermod -s /bin/bash opslab
#    Verificación:
#       getent passwd opslab      # el último campo debe ser /bin/bash
#
# Paso 2 — Desbloquear el password:
#       passwd -u opslab
#    (equivalente: usermod -U opslab)
#    Verificación:
#       passwd -S opslab          # debe mostrar "P" / "PS" en lugar de "L"
#       su - opslab               # desde root abre sesión sin pedir password;
#                                 # desde otro usuario, pedirá 'Lab010160!'
#
# Paso 3 — Devolverle la membresía al grupo administrativo:
#    En Debian/Ubuntu:
#       usermod -aG sudo opslab
#    En RHEL/Fedora/CentOS:
#       usermod -aG wheel opslab
#    ⚠️ El flag -a (append) es clave: sin él, -G REEMPLAZA todos los grupos
#    secundarios del usuario en lugar de agregar uno.
#    Verificación:
#       id opslab                 # debe listar sudo (o wheel)
#       su - opslab -c 'sudo whoami'   # tras ingresar el password → "root"
#    Nota: la membresía nueva se aplica en la PRÓXIMA sesión; si opslab ya
#    tenía una sesión abierta, debe salir y volver a entrar.
#
# --- Conceptos del tema 5.1 que ejercita este lab -----------------------------
#
# * Tipos de usuario: root (UID 0, superusuario), usuarios estándar
#   (UID >= 1000 en la mayoría de las distros) y cuentas de sistema
#   (UID bajos, shell nologin/false, no hacen login interactivo).
# * /etc/passwd: campos usuario:x:UID:GID:GECOS:home:shell — la 'x' indica
#   que el hash real vive en /etc/shadow, legible solo por root.
# * /etc/group y grupos secundarios como mecanismo de autorización
#   (pertenecer a sudo/wheel habilita la escalación de privilegios).
# * Comandos de identificación y auditoría: id, who, w, last.
# * su vs sudo: su cambia de identidad con el password del destino;
#   sudo ejecuta con privilegios según la política de /etc/sudoers.
#
# --- Limpieza del laboratorio (opcional) --------------------------------------
#
#   userdel -r opslab       # elimina el usuario y su directorio home
#
# Fuente de referencia:
#   https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
# =============================================================================