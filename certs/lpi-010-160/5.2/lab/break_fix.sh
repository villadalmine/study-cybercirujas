#!/bin/bash
#
# =============================================================================
#  LAB BREAK & FIX - LPI Linux Essentials (010-160 v1.6)
#  Tema 5.2: Creating Users and Groups (peso: 2)
#
#  Referencia (solo consulta, contenido original):
#    https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script crea un usuario y un grupo de práctica y luego los "rompe"
#  de forma controlada. No toca usuarios ni grupos preexistentes.
#
#  Uso:   sudo bash lab-5.2-break-fix.sh
# =============================================================================

set -u

LAB_USER="dev1"
LAB_GROUP="developers"
LAB_HOME="/home/${LAB_USER}"

# --- Comprobaciones de seguridad ---------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse como root (usá sudo)." >&2
    exit 1
fi

if [[ ! -f /etc/passwd || ! -f /etc/group ]]; then
    echo "ERROR: no encuentro /etc/passwd o /etc/group. Sistema no soportado." >&2
    exit 1
fi

if id "${LAB_USER}" &>/dev/null; then
    echo "ERROR: el usuario '${LAB_USER}' ya existe. Este lab necesita crearlo desde cero." >&2
    echo "Si es un resto de un lab anterior, eliminalo con: userdel -r ${LAB_USER}" >&2
    exit 1
fi

# --- Fase 1: preparar el escenario -------------------------------------------

echo "[*] Creando el grupo de laboratorio '${LAB_GROUP}'..."
getent group "${LAB_GROUP}" >/dev/null || groupadd "${LAB_GROUP}"

echo "[*] Creando el usuario de laboratorio '${LAB_USER}' con home y bash..."
useradd -m -s /bin/bash -G "${LAB_GROUP}" -c "Usuario de laboratorio 5.2" "${LAB_USER}"

echo "[*] Asignando la contraseña 'Lab2026!' al usuario..."
echo "${LAB_USER}:Lab2026!" | chpasswd

echo "[*] Verificación inicial (todo sano):"
id "${LAB_USER}"
grep "^${LAB_USER}:" /etc/passwd

# --- Fase 2: romper de forma controlada --------------------------------------
# Tres fallas típicas de administración de cuentas:

echo
echo "[*] Rompiendo la cuenta (3 fallas controladas)..."

# Falla 1: bloquear la contraseña de la cuenta
usermod -L "${LAB_USER}"

# Falla 2: cambiar el login shell a uno que no permite sesión interactiva
usermod -s /usr/sbin/nologin "${LAB_USER}" 2>/dev/null \
    || usermod -s /sbin/nologin "${LAB_USER}"

# Falla 3: sacar al usuario de su grupo secundario 'developers'
gpasswd -d "${LAB_USER}" "${LAB_GROUP}" >/dev/null

# --- Fase 3: briefing para el estudiante --------------------------------------

cat <<'EOF'

=============================================================================
 ESCENARIO PARA EL ESTUDIANTE
=============================================================================
 Contexto: sos el nuevo sysadmin. El usuario 'dev1' abrió un ticket:
 "No puedo iniciar sesión y tampoco accedo a los archivos compartidos
 del equipo de desarrollo".

 SÍNTOMAS que vas a observar:
   1. 'su - dev1' pide la contraseña (Lab2026!) pero la autenticación
      falla, o si llega a autenticarse, la sesión se cierra de inmediato
      con un mensaje tipo "This account is currently not available".
   2. 'id dev1' muestra que el usuario YA NO pertenece al grupo
      secundario 'developers'.
   3. En /etc/shadow, el hash de la contraseña de dev1 empieza con '!'
      (señal de cuenta bloqueada).
   4. En /etc/passwd, el último campo de dev1 no es /bin/bash.

 OBJETIVO (criterios de éxito):
   - 'su - dev1' con la contraseña Lab2026! debe abrir una sesión
     interactiva con bash.
   - 'id dev1' debe listar 'developers' entre sus grupos.
   - 'passwd -S dev1' debe mostrar la cuenta con estado P (password set)
     y no L (locked).

 HERRAMIENTAS SUGERIDAS (temario 5.2):
   id, getent, grep en /etc/passwd y /etc/group, passwd, usermod,
   gpasswd, su.

 PISTA: hay TRES cosas rotas. Diagnosticá antes de tocar:
   passwd -S dev1
   getent passwd dev1
   id dev1

 Cuando termines, verificá y después limpiá la VM con:
   userdel -r dev1 && groupdel developers
=============================================================================

EOF

exit 0

# =============================================================================
#  SOLUCIÓN PASO A PASO (no leer antes de intentarlo)
# =============================================================================
#
#  Paso 0 - Diagnóstico:
#    passwd -S dev1
#        -> muestra "L" (locked): la contraseña está bloqueada.
#    grep '^dev1:' /etc/shadow
#        -> el hash empieza con '!', confirmando el bloqueo.
#    getent passwd dev1
#        -> el último campo es /usr/sbin/nologin (o /sbin/nologin),
#           un shell que impide sesiones interactivas.
#    id dev1
#        -> falta el grupo secundario 'developers'.
#
#  Paso 1 - Desbloquear la contraseña:
#    usermod -U dev1
#        (equivalente: passwd -u dev1)
#
#  Paso 2 - Restaurar un login shell válido:
#    usermod -s /bin/bash dev1
#
#  Paso 3 - Reincorporar al usuario a su grupo secundario:
#    usermod -aG developers dev1
#        (¡ojo con la -a! Sin ella, -G reemplaza TODOS los grupos
#         secundarios en lugar de agregar uno.)
#        (equivalente: gpasswd -a dev1 developers)
#
#  Paso 4 - Verificación final:
#    passwd -S dev1          # debe mostrar estado P
#    id dev1                 # debe incluir 'developers'
#    su - dev1               # con Lab2026! debe abrir un shell bash
#
#  Conceptos clave del tema 5.2 que este lab refuerza:
#    - /etc/passwd guarda usuario, UID, GID, home y login shell.
#    - /etc/shadow guarda el hash de la contraseña; un '!' delante
#      indica cuenta bloqueada (usermod -L / passwd -l).
#    - /etc/group define los grupos y sus miembros secundarios.
#    - usermod modifica cuentas existentes; useradd/groupadd las crean.
#    - id y getent son las herramientas de consulta estándar.
#
#  Referencia consultada:
#    https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
# =============================================================================