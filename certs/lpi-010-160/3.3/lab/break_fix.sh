#!/bin/bash
#
# =============================================================================
# LAB BREAK & FIX — LPI Linux Essentials (010-160 v1.6)
# Tema 3.3: Turning Commands into a Script (peso: 4)
#
# Referencia consultada (contenido original, no copiado):
#   https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
#
# QUE HACE ESTE LAB:
#   Crea un directorio de laboratorio en tu HOME con un shell script
#   "roto" de tres maneras distintas, todas relacionadas con los
#   conceptos del tema: la linea shebang (#!), los permisos de
#   ejecucion (chmod +x) y la sintaxis de variables en bash.
#
# SEGURIDAD:
#   - Solo escribe dentro de ~/lab-3.3-script (nada fuera de tu HOME).
#   - No toca configuracion del sistema, ni servicios, ni paquetes.
#   - Pensado para una VM de laboratorio descartable, pero es inocuo
#     incluso en una maquina real.
#   - Para deshacer todo: rm -rf ~/lab-3.3-script
#
# USO:
#   bash lab-3.3-break.sh        (ejecutalo como tu usuario normal, sin sudo)
# =============================================================================

set -euo pipefail

LAB_DIR="$HOME/lab-3.3-script"
BROKEN_SCRIPT="$LAB_DIR/saludo.sh"

# --- Verificaciones previas --------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: no ejecutes este lab como root. Usa tu usuario normal." >&2
    exit 1
fi

if [ -e "$LAB_DIR" ]; then
    echo "AVISO: ya existe $LAB_DIR de un intento anterior."
    echo "Se elimina y se vuelve a crear para empezar de cero..."
    rm -rf "$LAB_DIR"
fi

mkdir -p "$LAB_DIR"

# --- Creacion del script roto ------------------------------------------------
#
# El script "saludo.sh" contiene TRES roturas intencionales:
#
#   ROTURA 1: la linea shebang apunta a un interprete que no existe
#             (#!/bin/bashh en lugar de #!/bin/bash).
#
#   ROTURA 2: la variable NOMBRE se asigna con espacios alrededor del
#             signo igual (NOMBRE = "..."), algo que bash interpreta
#             como un comando llamado "NOMBRE" con dos argumentos.
#
#   ROTURA 3: el archivo se crea SIN permiso de ejecucion (chmod 644),
#             asi que ni siquiera se puede lanzar con ./saludo.sh.

cat > "$BROKEN_SCRIPT" <<'EOF'
#!/bin/bashh
# saludo.sh — muestra un saludo con la fecha y el usuario actual

NOMBRE = "estudiante"

echo "Hola, $NOMBRE"
echo "Hoy es $(date)"
echo "Tu usuario es $USER y estas en el directorio $PWD"

exit 0
EOF

chmod 644 "$BROKEN_SCRIPT"

# --- Instrucciones para el estudiante ----------------------------------------

cat <<INSTRUCCIONES

=============================================================================
 LAB LISTO — Tema 3.3: Turning Commands into a Script
=============================================================================

Se creo el script:  $BROKEN_SCRIPT
Esta roto de TRES maneras distintas. Tu mision es dejarlo funcionando.

SINTOMAS QUE VAS A VER (en orden, a medida que avances):

  1) Si haces:   cd ~/lab-3.3-script && ./saludo.sh
     Veras:      bash: ./saludo.sh: Permission denied
     Pista:      revisa los permisos con "ls -l" — ¿el archivo tiene
                 el bit de ejecucion (x)?

  2) Cuando arregles lo anterior y vuelvas a ejecutarlo, veras algo como:
                 bash: ./saludo.sh: /bin/bashh: bad interpreter:
                 No such file or directory
     Pista:      mira la primera linea del script (la linea shebang).
                 ¿Ese interprete existe? Comprobalo con "which bash".

  3) Cuando arregles el shebang, el script arrancara pero mostrara:
                 ./saludo.sh: line 4: NOMBRE: command not found
                 Hola,
     Pista:      en bash, la asignacion de variables NO admite espacios
                 alrededor del signo "=".

OBJETIVO (criterio de exito):
  ./saludo.sh debe ejecutarse sin errores y mostrar el saludo completo,
  incluyendo "Hola, estudiante", la fecha, tu usuario y tu directorio.
  Ademas, "echo \$?" inmediatamente despues debe mostrar 0 (exit status
  de exito).

HERRAMIENTAS QUE TE CONVIENE REPASAR:
  ls -l, chmod, which, nano (o vi), echo \$?

Para limpiar el laboratorio cuando termines:
  rm -rf ~/lab-3.3-script

¡Exito!
=============================================================================
INSTRUCCIONES

exit 0

# =============================================================================
# SOLUCION PASO A PASO (no mirar hasta haberlo intentado)
# =============================================================================
#
# PASO 0 — Situarse en el laboratorio y observar el problema:
#
#   cd ~/lab-3.3-script
#   ./saludo.sh
#   # -> bash: ./saludo.sh: Permission denied
#
# PASO 1 — Arreglar los permisos de ejecucion (ROTURA 3):
#
#   ls -l saludo.sh
#   # -> -rw-r--r-- ...   (no hay ninguna "x": el archivo no es ejecutable)
#
#   chmod +x saludo.sh          # o de forma equivalente: chmod 755 saludo.sh
#   ls -l saludo.sh
#   # -> -rwxr-xr-x ...   (ahora si tiene permiso de ejecucion)
#
#   Concepto: en Linux un script es un archivo de texto comun; para poder
#   lanzarlo como "./script.sh" necesita el bit de ejecucion (x). Sin el,
#   solo podrias correrlo pasandoselo explicitamente al interprete, por
#   ejemplo "bash saludo.sh" (truco util para diagnosticar, ademas).
#
# PASO 2 — Arreglar la linea shebang (ROTURA 1):
#
#   ./saludo.sh
#   # -> bad interpreter: /bin/bashh: No such file or directory
#
#   head -n 1 saludo.sh
#   # -> #!/bin/bashh      (interprete mal escrito: "bashh" no existe)
#
#   which bash
#   # -> /bin/bash         (esta es la ruta correcta del interprete)
#
#   Editar la primera linea con nano (o vi):
#     nano saludo.sh
#   y dejarla exactamente asi:
#     #!/bin/bash
#
#   Concepto: la linea shebang (#!) debe ser la PRIMERA linea del script
#   e indica al kernel que interprete usar para ejecutarlo. Si la ruta
#   no existe, el script no puede arrancar aunque tenga permisos.
#
# PASO 3 — Arreglar la asignacion de la variable (ROTURA 2):
#
#   ./saludo.sh
#   # -> ./saludo.sh: line 4: NOMBRE: command not found
#   # -> Hola,              (la variable quedo vacia)
#
#   La linea rota es:
#     NOMBRE = "estudiante"
#
#   Hay que dejarla SIN espacios alrededor del "=":
#     NOMBRE="estudiante"
#
#   Concepto: con espacios, bash interpreta "NOMBRE" como un comando y
#   "=" y "estudiante" como sus argumentos; como no existe ningun comando
#   llamado NOMBRE, falla con "command not found" y la variable nunca se
#   define. La sintaxis correcta de asignacion en bash es VARIABLE=valor,
#   todo junto, y luego se lee con $VARIABLE.
#
# PASO 4 — Verificar el arreglo completo:
#
#   ./saludo.sh
#   # -> Hola, estudiante
#   # -> Hoy es <fecha actual>
#   # -> Tu usuario es <tu_usuario> y estas en el directorio <ruta>
#
#   echo $?
#   # -> 0    (exit status 0 = el script termino con exito)
#
# PASO 5 — Limpieza del laboratorio:
#
#   cd ~
#   rm -rf ~/lab-3.3-script
#
# RESUMEN DE CONCEPTOS DEL TEMA 3.3 CUBIERTOS:
#   - Shebang (#!) y eleccion del interprete.
#   - Permisos de ejecucion: chmod +x / notacion octal.
#   - Variables en bash: asignacion sin espacios, expansion con $.
#   - Ejecucion con ./script.sh vs "bash script.sh".
#   - Exit status ($?) para verificar exito o fallo.
#
# Referencia: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
# =============================================================================