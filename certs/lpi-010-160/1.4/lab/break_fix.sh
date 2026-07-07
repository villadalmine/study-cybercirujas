#!/bin/bash
#
# =============================================================================
#  break-fix-1.4.sh — LPI Linux Essentials (010-160, v1.6)
#  Tema 1.4: ICT Skills and Working in Linux (peso: 2)
#
#  Ejercicio "break & fix": este script rompe, de forma controlada y
#  reversible, la seguridad básica de una cuenta de usuario de laboratorio.
#  Practica los conceptos de cybersecurity del tema 1.4: passwords,
#  bloqueo de cuentas y permisos que protegen la privacidad del usuario.
#
#  Referencia (solo consulta, contenido original):
#  https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
#
#  ADVERTENCIA: ejecutar ÚNICAMENTE en una VM de laboratorio descartable.
#  Requiere root. No toca ningún usuario real: crea su propio usuario
#  de práctica llamado "alumno".
# =============================================================================

set -euo pipefail

LAB_USER="alumno"
LAB_PASS="Linux-Essentials-1.4"

# --- Verificaciones de seguridad ---------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse como root (usá: sudo $0)" >&2
    exit 1
fi

echo "============================================================"
echo " LABORATORIO BREAK & FIX — Tema 1.4: Cybersecurity básica"
echo "============================================================"
echo
echo "Este script va a modificar la cuenta de práctica '${LAB_USER}'."
echo "SOLO continúes si esto es una VM descartable de laboratorio."
echo
read -r -p "¿Estás en una VM de laboratorio? (escribí SI para continuar): " CONFIRM
if [[ "${CONFIRM}" != "SI" ]]; then
    echo "Cancelado. No se modificó nada."
    exit 0
fi

# --- Preparación: crear el usuario de laboratorio si no existe ---------------

if ! id "${LAB_USER}" &>/dev/null; then
    useradd -m -s /bin/bash "${LAB_USER}"
    echo "${LAB_USER}:${LAB_PASS}" | chpasswd
    echo "[+] Usuario '${LAB_USER}' creado con password '${LAB_PASS}'."
else
    echo "[+] Usuario '${LAB_USER}' ya existe, se reutiliza."
    echo "${LAB_USER}:${LAB_PASS}" | chpasswd
fi

LAB_HOME=$(getent passwd "${LAB_USER}" | cut -d: -f6)

# Archivo "privado" del usuario, para el ejercicio de permisos
sudo -u "${LAB_USER}" bash -c "echo 'mis notas privadas del examen 010-160' > '${LAB_HOME}/diario-privado.txt'"

# --- BREAK: romper de forma controlada ----------------------------------------

echo
echo "[*] Rompiendo el sistema de forma controlada..."

# Rotura 1: bloquear el password de la cuenta (lock del account)
passwd -l "${LAB_USER}" >/dev/null

# Rotura 2: dejar el archivo privado legible por TODO el mundo
chmod 666 "${LAB_HOME}/diario-privado.txt"

# Rotura 3: dejar el home del usuario abierto a cualquier otro usuario
chmod 777 "${LAB_HOME}"

echo "[*] Listo. El entorno está roto. Leé lo que sigue con atención."

# --- Explicación para el estudiante -------------------------------------------

cat <<EOF

============================================================
 SÍNTOMAS QUE VAS A VER
============================================================

1) Si intentás hacer login como '${LAB_USER}' (en una consola nueva,
   con 'su - ${LAB_USER}' desde otro usuario NO root, o por SSH con
   password), el login FALLA aunque escribas el password correcto
   (${LAB_PASS}). La cuenta está bloqueada (locked account).
   Pista: mirá el segundo campo de la línea de '${LAB_USER}' en
   /etc/shadow (como root) o la salida de 'passwd -S ${LAB_USER}'.

2) CUALQUIER usuario del sistema puede leer y hasta modificar el
   archivo ${LAB_HOME}/diario-privado.txt.
   Probalo: creá otro usuario y hacé 'cat' de ese archivo. Funciona,
   y no debería: es una violación de privacidad (tema 1.4).

3) El directorio home ${LAB_HOME} tiene permisos 777: cualquier
   usuario puede entrar, crear y borrar archivos ahí adentro.
   Verificalo con: ls -ld ${LAB_HOME}

============================================================
 TU OBJETIVO (el "FIX")
============================================================

a) Desbloquear la cuenta '${LAB_USER}' para que pueda hacer login
   con su password de nuevo.
b) Dejar diario-privado.txt legible y escribible SOLO por su dueño
   (permisos 600).
c) Dejar el home con permisos razonables: solo el dueño con acceso
   total (700, o 750 si querés permitir lectura al grupo).

Verificación final esperada:
   passwd -S ${LAB_USER}          -> debe mostrar "P" (password válido), no "L"
   ls -l ${LAB_HOME}/diario-privado.txt  -> -rw-------
   ls -ld ${LAB_HOME}             -> drwx------ (o drwxr-x---)

Comandos que te conviene investigar: passwd (opciones -S, -l, -u),
chmod, ls -l, ls -ld, man.

No mires la solución de abajo hasta intentarlo. ¡Éxitos!

EOF

exit 0

# =============================================================================
#  SOLUCIÓN PASO A PASO (no leer hasta haberlo intentado)
# =============================================================================
#
#  Todos los comandos se ejecutan como root (o con sudo).
#
#  Paso 1 — Diagnosticar el estado de la cuenta:
#
#      passwd -S alumno
#
#      La salida muestra "L" (locked): el password está bloqueado.
#      Otra forma de verlo: en /etc/shadow, el hash del password de
#      'alumno' empieza con "!" — ese signo es lo que invalida el
#      password sin borrarlo.
#
#  Paso 2 — Desbloquear la cuenta:
#
#      passwd -u alumno
#
#      (Equivalente: usermod -U alumno). Verificar con 'passwd -S alumno':
#      ahora debe mostrar "P" (usable password). Probar el login:
#      su - alumno   (password: Linux-Essentials-1.4)
#
#  Paso 3 — Diagnosticar los permisos del archivo privado:
#
#      ls -l /home/alumno/diario-privado.txt
#
#      Muestra -rw-rw-rw- (666): lectura y escritura para owner, group
#      y others. Cualquiera puede leerlo y modificarlo.
#
#  Paso 4 — Corregir los permisos del archivo (solo el dueño):
#
#      chmod 600 /home/alumno/diario-privado.txt
#
#      (En notación simbólica: chmod u=rw,go= diario-privado.txt)
#      Verificar: ls -l debe mostrar -rw-------
#
#  Paso 5 — Diagnosticar y corregir los permisos del home:
#
#      ls -ld /home/alumno        -> drwxrwxrwx (777), abierto a todos
#      chmod 700 /home/alumno
#      ls -ld /home/alumno        -> drwx------
#
#  Paso 6 — Verificación final completa:
#
#      passwd -S alumno                          # "P" = OK
#      ls -l  /home/alumno/diario-privado.txt    # -rw-------
#      ls -ld /home/alumno                       # drwx------
#      su - alumno                               # el login funciona
#
#  Concepto clave del tema 1.4: la privacidad en un sistema multiusuario
#  depende de dos cosas que acabás de reparar: credenciales que funcionan
#  y están protegidas (passwords, lock/unlock de cuentas) y permisos de
#  archivos que limitan quién puede leer tus datos. Los permisos 600/700
#  son la configuración típica para datos personales y el directorio home.
#
#  Limpieza del laboratorio (opcional, cuando termines):
#
#      userdel -r alumno
#
# =============================================================================