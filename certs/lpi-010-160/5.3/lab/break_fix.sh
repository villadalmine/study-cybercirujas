#!/bin/bash
#
# ============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160, versión 1.6)
#  Tema 5.3: Managing File Permissions and Ownership (peso: 2)
#
#  Referencia (solo como material de consulta, contenido original):
#    https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script crea usuarios, grupos y archivos de práctica bajo /opt/lab-perms
#  y "rompe" permisos y ownership de forma controlada. No toca archivos
#  del sistema ni datos existentes.
#
#  Uso:   sudo bash lab-permisos-break.sh
# ============================================================================

set -euo pipefail

LAB_DIR="/opt/lab-perms"
LAB_USER="ana"
LAB_USER2="bruno"
LAB_GROUP="proyecto"

# ----------------------------------------------------------------------------
# Verificaciones de seguridad
# ----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse como root (usá sudo)." >&2
    exit 1
fi

echo "============================================================"
echo " LAB 5.3 — File Permissions and Ownership"
echo "============================================================"
echo
echo "Este lab va a crear los usuarios '${LAB_USER}' y '${LAB_USER2}',"
echo "el grupo '${LAB_GROUP}' y el directorio ${LAB_DIR}."
echo
read -rp "¿Estás en una VM descartable de laboratorio? (si/no): " CONFIRMA
if [[ "${CONFIRMA}" != "si" ]]; then
    echo "Abortado. Ejecutá este lab únicamente en una VM descartable."
    exit 1
fi

# ----------------------------------------------------------------------------
# Preparación del escenario (estado "sano" inicial)
# ----------------------------------------------------------------------------
echo
echo "[*] Preparando el escenario..."

groupadd -f "${LAB_GROUP}"
id "${LAB_USER}"  &>/dev/null || useradd -m -s /bin/bash -G "${LAB_GROUP}" "${LAB_USER}"
id "${LAB_USER2}" &>/dev/null || useradd -m -s /bin/bash -G "${LAB_GROUP}" "${LAB_USER2}"

mkdir -p "${LAB_DIR}/compartido"

cat > "${LAB_DIR}/compartido/informe.txt" <<'EOF'
Informe semanal del equipo del proyecto.
Ambos integrantes del grupo 'proyecto' deben poder leer y editar este archivo.
EOF

cat > "${LAB_DIR}/compartido/backup.sh" <<'EOF'
#!/bin/bash
echo "Backup del proyecto ejecutado correctamente: $(date)"
EOF

cat > "${LAB_DIR}/compartido/notas-privadas-ana.txt" <<'EOF'
Notas privadas de Ana. Solo Ana debe poder leer este archivo.
EOF

# ----------------------------------------------------------------------------
# ROMPIENDO COSAS (de forma controlada)
# ----------------------------------------------------------------------------
echo "[*] Rompiendo permisos y ownership de forma controlada..."

# Rotura 1: el directorio compartido pierde el bit de ejecución (x),
#           por lo que nadie puede "entrar" (cd) ni acceder a su contenido,
#           aunque el bit de lectura (r) siga presente.
chown root:"${LAB_GROUP}" "${LAB_DIR}" "${LAB_DIR}/compartido"
chmod 755 "${LAB_DIR}"
chmod 640 "${LAB_DIR}/compartido"

# Rotura 2: el informe del equipo queda con owner root:root y permisos 600,
#           así que ni Ana ni Bruno pueden leerlo ni editarlo.
chown root:root "${LAB_DIR}/compartido/informe.txt"
chmod 600 "${LAB_DIR}/compartido/informe.txt"

# Rotura 3: el script de backup pertenece al grupo correcto pero perdió
#           el permiso de ejecución para todos.
chown root:"${LAB_GROUP}" "${LAB_DIR}/compartido/backup.sh"
chmod 644 "${LAB_DIR}/compartido/backup.sh"

# Rotura 4: las notas privadas de Ana quedaron legibles para todo el mundo
#           (world-readable) y además con owner equivocado.
chown "${LAB_USER2}":"${LAB_GROUP}" "${LAB_DIR}/compartido/notas-privadas-ana.txt"
chmod 644 "${LAB_DIR}/compartido/notas-privadas-ana.txt"

# ----------------------------------------------------------------------------
# Instrucciones para el estudiante
# ----------------------------------------------------------------------------
cat <<EOF

============================================================
 ESCENARIO ROTO — TU MISIÓN
============================================================

Contexto: '${LAB_USER}' y '${LAB_USER2}' son integrantes del grupo
'${LAB_GROUP}' y trabajan juntos en ${LAB_DIR}/compartido.
Algo salió mal con los permissions y el ownership.

SÍNTOMAS QUE VAS A VER (probalos vos mismo):

  1. Nadie puede entrar al directorio compartido:
       sudo -u ${LAB_USER} ls ${LAB_DIR}/compartido
     -> "Permission denied", aunque el directorio "parece" legible.
     Pista: en un directorio, el bit 'x' (execute) es lo que permite
     atravesarlo y acceder a lo que contiene.

  2. Una vez que arregles el punto 1, ni ${LAB_USER} ni ${LAB_USER2}
     pueden leer ni editar informe.txt:
       sudo -u ${LAB_USER} cat ${LAB_DIR}/compartido/informe.txt
     -> "Permission denied". Mirá su owner y su group con 'ls -l'.

  3. El script backup.sh no se puede ejecutar:
       sudo -u ${LAB_USER2} ${LAB_DIR}/compartido/backup.sh
     -> "Permission denied". Le falta el bit de ejecución.

  4. Problema de seguridad: notas-privadas-ana.txt es legible por
     cualquier usuario del sistema y ni siquiera pertenece a ${LAB_USER}.

QUÉ DEBÉS LOGRAR:

  a) Que ${LAB_USER} y ${LAB_USER2} puedan entrar al directorio
     compartido y listar su contenido.
  b) Que informe.txt pertenezca a ${LAB_USER} y al grupo ${LAB_GROUP},
     con lectura y escritura para owner y group (y nada para others).
  c) Que backup.sh sea ejecutable por el owner y el grupo.
  d) Que notas-privadas-ana.txt pertenezca a ${LAB_USER} y solo ella
     pueda leerlo y escribirlo (modo 600).

HERRAMIENTAS QUE VAS A NECESITAR:
  ls -l, chmod (notación octal y simbólica), chown, chgrp.

VERIFICACIÓN FINAL (todo debe funcionar sin errores):
  sudo -u ${LAB_USER}  ls -l ${LAB_DIR}/compartido
  sudo -u ${LAB_USER2} cat ${LAB_DIR}/compartido/informe.txt
  sudo -u ${LAB_USER2} ${LAB_DIR}/compartido/backup.sh
  sudo -u ${LAB_USER2} cat ${LAB_DIR}/compartido/notas-privadas-ana.txt
     (este último SÍ debe fallar con "Permission denied": ¡es privado!)

¡Éxitos! La solución está comentada al final de este script:
no la mires hasta intentarlo.
============================================================
EOF

exit 0

# ============================================================================
#  SOLUCIÓN PASO A PASO (no leer antes de intentarlo)
# ============================================================================
#
# Paso 0 — Diagnóstico. Siempre empezá mirando el estado real:
#
#   ls -ld /opt/lab-perms/compartido
#   ls -l  /opt/lab-perms/compartido      # (fallará hasta arreglar el paso 1)
#
#   Recordá cómo leer la salida de 'ls -l':
#     -rw-r----- 1 root proyecto ...
#      ^^^ ^^ ^^     ^      ^
#      |   |  |      |      +-- group owner
#      |   |  |      +--------- user owner
#      |   |  +---------------- permisos de others
#      |   +------------------- permisos del group
#      +----------------------- permisos del user (owner)
#
# Paso 1 — Restaurar el acceso al directorio compartido.
#   El directorio quedó en 640 (rw-r-----): sin el bit 'x' no se puede
#   entrar ni acceder a los archivos internos. Un directorio de trabajo
#   en grupo típico usa 770 o 2770; acá alcanza con 770:
#
#   sudo chmod 770 /opt/lab-perms/compartido
#
#   Equivalente en notación simbólica:
#   sudo chmod u=rwx,g=rwx,o= /opt/lab-perms/compartido
#
# Paso 2 — Arreglar informe.txt (ownership + permisos).
#   Estaba root:root con 600. Hay que devolvérselo a ana y al grupo
#   proyecto, con rw para owner y group:
#
#   sudo chown ana:proyecto /opt/lab-perms/compartido/informe.txt
#   sudo chmod 660 /opt/lab-perms/compartido/informe.txt
#
#   Nota: 'chown usuario:grupo archivo' cambia ambos a la vez.
#   Solo el grupo también podría cambiarse con:
#   sudo chgrp proyecto /opt/lab-perms/compartido/informe.txt
#
# Paso 3 — Hacer ejecutable backup.sh para owner y grupo.
#   Con notación simbólica (agrega 'x' sin tocar el resto):
#
#   sudo chmod ug+x /opt/lab-perms/compartido/backup.sh
#
#   Equivalente en octal (rwxr-x--- no; queremos rwxr-xr-- según 644+x):
#   partiendo de 644, ug+x da 754. También sería válido fijar 750 o 774
#   según la política del equipo; lo esencial es que owner y group
#   tengan el bit 'x'.
#
# Paso 4 — Proteger las notas privadas de ana.
#   Devolver el ownership a ana y dejar solo rw para ella (600):
#
#   sudo chown ana:ana /opt/lab-perms/compartido/notas-privadas-ana.txt
#   sudo chmod 600 /opt/lab-perms/compartido/notas-privadas-ana.txt
#
# Paso 5 — Verificar todo:
#
#   sudo -u ana   ls -l /opt/lab-perms/compartido          # funciona
#   sudo -u bruno cat  /opt/lab-perms/compartido/informe.txt   # funciona
#   sudo -u bruno /opt/lab-perms/compartido/backup.sh          # funciona
#   sudo -u bruno cat /opt/lab-perms/compartido/notas-privadas-ana.txt
#     -> "Permission denied" (correcto: es un archivo privado de ana)
#   sudo -u ana   cat /opt/lab-perms/compartido/notas-privadas-ana.txt
#     -> funciona (ana es la owner)
#
# Conceptos clave repasados (tema 5.3):
#   - r/w/x significan cosas distintas en archivos y en directorios:
#     en un directorio, 'x' permite atravesarlo y 'r' listar su contenido.
#   - Tríadas user/group/others y su lectura en 'ls -l'.
#   - chmod en notación octal (660, 770) y simbólica (ug+x, o=).
#   - chown para cambiar user owner y group owner; chgrp solo el grupo.
#   - Principio de mínimo privilegio: others no necesita acceso.
#
# Limpieza del laboratorio (opcional, cuando termines):
#
#   sudo rm -rf /opt/lab-perms
#   sudo userdel -r ana
#   sudo userdel -r bruno
#   sudo groupdel proyecto
#
# Referencia consultada:
#   https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
# ============================================================================