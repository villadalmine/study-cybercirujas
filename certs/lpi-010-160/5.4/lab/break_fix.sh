#!/usr/bin/env bash
#
# =============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160, versión 1.6)
#  Tema 5.4: Special Directories and Files (peso: 1)
#
#  Conceptos que practica este laboratorio:
#    - Directorios temporales del sistema: /tmp y /var/tmp
#    - El permiso especial "sticky bit" (t / 1777)
#    - Symbolic links (enlaces simbólicos) y hard links
#
#  Referencia (usada solo como guía conceptual, contenido original):
#    https://learning.lpi.org/en/learning-materials/010-160/5/5.4/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script modifica permisos de /tmp y crea archivos de práctica.
#  Requiere ejecutarse como root (sudo).
# =============================================================================

set -u

LAB_DIR="/opt/lab54"

# --- Verificaciones de seguridad -------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse como root. Usá: sudo $0" >&2
    exit 1
fi

if [[ ! -f /etc/lab_vm_descartable ]]; then
    echo "AVISO DE SEGURIDAD:"
    echo "Este script rompe cosas a propósito. Confirmá que estás en una"
    echo "VM de laboratorio descartable creando el archivo testigo:"
    echo
    echo "    sudo touch /etc/lab_vm_descartable"
    echo
    echo "y volvé a ejecutar el script."
    exit 1
fi

# --- ROMPER (de forma controlada) -------------------------------------------

echo "[*] Preparando el escenario del laboratorio..."

# ROTURA 1: quitar el sticky bit de /tmp
# Estado normal: drwxrwxrwt (modo 1777). Lo dejamos en 0777.
chmod 0777 /tmp

# ROTURA 2: crear un symbolic link roto (dangling symlink)
mkdir -p "$LAB_DIR"
echo "configuracion importante del servicio" > "$LAB_DIR/servicio.conf"
ln -sf "$LAB_DIR/servicio.conf" "$LAB_DIR/config_actual"
# Movemos el destino: el symlink queda apuntando a un archivo inexistente
mv "$LAB_DIR/servicio.conf" "$LAB_DIR/servicio.conf.bak"

# Usuarios de práctica para demostrar el problema del sticky bit
for u in alumno1 alumno2; do
    id "$u" &>/dev/null || useradd -m "$u"
done

# alumno1 deja un archivo en /tmp, como haría cualquier programa
su -s /bin/bash - alumno1 -c 'echo "datos temporales de alumno1" > /tmp/archivo_de_alumno1.txt'

clear
cat <<'EOF'
=============================================================================
 LABORATORIO 5.4 — Special Directories and Files
=============================================================================

 Se "rompieron" DOS cosas en esta VM. Tu misión es diagnosticarlas y
 repararlas usando lo que sabés sobre directorios y archivos especiales.

-----------------------------------------------------------------------------
 PROBLEMA 1 — /tmp perdió una protección importante
-----------------------------------------------------------------------------
 SÍNTOMA QUE VAS A VER:
   Cualquier usuario puede borrar los archivos temporales de OTROS
   usuarios en /tmp. Probalo vos mismo:

       sudo su - alumno2
       rm /tmp/archivo_de_alumno1.txt      # ¡funciona, y no debería!
       exit

   En un sistema sano, ese "rm" falla con "Operation not permitted",
   aunque /tmp sea escribible por todos.

 PISTAS:
   - Mirá los permisos: ls -ld /tmp
   - Compará con lo esperado en un directorio temporal compartido.
   - ¿Qué letra falta al final de los permisos? ¿Qué permiso especial
     hace que solo el dueño de un archivo pueda borrarlo?

 OBJETIVO:
   Restaurar /tmp para que "ls -ld /tmp" muestre: drwxrwxrwt
   y que alumno2 ya NO pueda borrar archivos de alumno1.

-----------------------------------------------------------------------------
 PROBLEMA 2 — un symbolic link roto en /opt/lab54
-----------------------------------------------------------------------------
 SÍNTOMA QUE VAS A VER:

       cat /opt/lab54/config_actual
       # cat: /opt/lab54/config_actual: No such file or directory

   Pero "ls -l /opt/lab54" muestra que config_actual SÍ existe...

 PISTAS:
   - ls -l /opt/lab54       (mirá la flecha "->" del symlink)
   - Un symbolic link guarda una RUTA, no los datos. Si el destino
     se mueve o se borra, el link queda "colgado" (dangling).
   - Buscá en /opt/lab54 si el contenido original sigue en algún lado.

 OBJETIVO:
   Que "cat /opt/lab54/config_actual" vuelva a mostrar el contenido
   del archivo de configuración.

-----------------------------------------------------------------------------
 Cuando termines, verificá:
   1) ls -ld /tmp                      -> drwxrwxrwt
   2) cat /opt/lab54/config_actual     -> muestra el texto de config
=============================================================================
EOF

exit 0

# =============================================================================
#  SOLUCIÓN PASO A PASO (no leer hasta intentarlo)
# =============================================================================
#
# --- PROBLEMA 1: sticky bit ausente en /tmp ---------------------------------
#
# 1) Diagnóstico: ver los permisos actuales del directorio.
#
#       ls -ld /tmp
#       # drwxrwxrwx ...  <- termina en "x": falta el sticky bit
#
#    Un /tmp sano termina en "t": drwxrwxrwt (modo octal 1777).
#    El sticky bit hace que, en un directorio escribible por todos,
#    solo el dueño del archivo (o root) pueda borrarlo o renombrarlo.
#
# 2) Reparación, en notación octal (el "1" inicial es el sticky bit):
#
#       sudo chmod 1777 /tmp
#
#    o en notación simbólica:
#
#       sudo chmod +t /tmp
#
# 3) Verificación:
#
#       ls -ld /tmp
#       # drwxrwxrwt ...  <- la "t" final confirma el sticky bit
#
#       sudo su - alumno1 -c 'echo hola > /tmp/prueba_a1.txt'
#       sudo su - alumno2 -c 'rm /tmp/prueba_a1.txt'
#       # rm: cannot remove '/tmp/prueba_a1.txt': Operation not permitted
#
# --- PROBLEMA 2: symbolic link roto -----------------------------------------
#
# 1) Diagnóstico: listar el directorio y observar el symlink.
#
#       ls -l /opt/lab54
#       # lrwxrwxrwx ... config_actual -> /opt/lab54/servicio.conf
#       # -rw-r--r-- ... servicio.conf.bak
#
#    El link apunta a "servicio.conf", que ya no existe (fue renombrado
#    a "servicio.conf.bak"). Por eso cat falla aunque el link "exista":
#    un symbolic link solo guarda una ruta de texto hacia su destino.
#
# 2) Reparación — hay dos caminos válidos:
#
#    Opción A: restaurar el archivo destino con su nombre original.
#
#       sudo mv /opt/lab54/servicio.conf.bak /opt/lab54/servicio.conf
#
#    Opción B: recrear el symlink apuntando al archivo que sí existe
#    (la opción -f fuerza el reemplazo del link viejo).
#
#       sudo ln -sf /opt/lab54/servicio.conf.bak /opt/lab54/config_actual
#
# 3) Verificación:
#
#       cat /opt/lab54/config_actual
#       # configuracion importante del servicio
#
# --- CONCEPTO EXTRA: hard link vs symbolic link ------------------------------
#
#    Si el link hubiera sido un HARD link (ln sin -s), mover o borrar el
#    nombre original NO lo habría roto: un hard link es otro nombre para
#    el mismo inode y los datos sobreviven mientras exista al menos un
#    nombre. Podés comprobarlo así:
#
#       cd /opt/lab54
#       sudo ln servicio.conf copia_dura
#       ls -li servicio.conf copia_dura   # mismo número de inode
#       sudo rm servicio.conf
#       cat copia_dura                    # sigue funcionando
#
# --- LIMPIEZA DEL LABORATORIO ------------------------------------------------
#
#       sudo userdel -r alumno1
#       sudo userdel -r alumno2
#       sudo rm -rf /opt/lab54
#       sudo rm -f /tmp/archivo_de_alumno1.txt /tmp/prueba_a1.txt
#
# =============================================================================