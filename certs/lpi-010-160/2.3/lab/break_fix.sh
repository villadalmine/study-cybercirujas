#!/usr/bin/env bash
#
# =============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160 v1.6)
#  Tema 2.3: Using Directories and Listing Files (peso: 2)
#
#  Conceptos que se practican: pwd, cd, ls (con -a, -l, -R, -d),
#  archivos y directorios ocultos (dotfiles), rutas absolutas y relativas,
#  el directorio home (~), y los directorios especiales "." y "..".
#
#  Referencia consultada (material original, no copiado):
#    https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
#
#  SEGURIDAD:
#   - Pensado para una VM de laboratorio DESCARTABLE.
#   - Solo crea y modifica archivos dentro de $HOME/lab-lpi-2.3.
#   - NO toca archivos del sistema, NO requiere root, NO borra nada
#     fuera del laboratorio.
# =============================================================================

set -euo pipefail

LAB="$HOME/lab-lpi-2.3"

# --- Comprobaciones de seguridad ---------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
    echo "ERROR: No ejecutes este lab como root. Usá tu usuario normal." >&2
    exit 1
fi

if [[ -e "$LAB" ]]; then
    echo "Ya existe un laboratorio anterior en $LAB — lo reinicio..."
    rm -rf -- "$LAB"
fi

# --- Construcción del escenario ----------------------------------------------
mkdir -p "$LAB"/documentos
mkdir -p "$LAB"/proyectos/web/img
mkdir -p "$LAB"/proyectos/scripts
mkdir -p "$LAB"/musica

# El "tesoro": los apuntes del estudiante, que vamos a esconder.
APUNTES_CONTENIDO="Apuntes del examen 010-160 - Tema 2.3: pwd, cd, ls, rutas absolutas y relativas."

# ROTURA CONTROLADA:
# 1) Movemos apuntes.txt fuera de su lugar y lo enterramos dentro de una
#    cadena de directorios OCULTOS (empiezan con "."), que ls normal no muestra.
mkdir -p "$LAB"/proyectos/.backup/.old/.tmp
echo "$APUNTES_CONTENIDO" > "$LAB"/proyectos/.backup/.old/.tmp/apuntes.txt

# 2) Dejamos señuelos: archivos vacíos con nombres parecidos, para que el
#    estudiante tenga que verificar con ls -l cuál es el verdadero (tamaño > 0).
touch "$LAB"/musica/apuntes.txt
touch "$LAB"/proyectos/web/apuntes.txt
touch "$LAB"/proyectos/scripts/apuntes.txt

# 3) Relleno realista para que ls -R tenga algo que mostrar.
touch "$LAB"/proyectos/web/index.html
touch "$LAB"/proyectos/web/img/logo.png
touch "$LAB"/proyectos/scripts/backup.sh
echo "config oculta del lab" > "$LAB"/.labrc

# 4) Pista escondida en un dotfile dentro de documentos/.
cat > "$LAB"/documentos/.pista.txt <<'EOF'
PISTA: Lo que no se ve con "ls" a veces aparece con "ls -a".
Los directorios cuyo nombre empieza con "." están ocultos.
Buscá dentro de proyectos/ ... y acordate de que "cd .." sube un nivel.
EOF

# --- Script de verificación para el estudiante --------------------------------
cat > "$LAB"/verificar.sh <<'EOF'
#!/usr/bin/env bash
# Verifica si el laboratorio quedó reparado.
LAB="$HOME/lab-lpi-2.3"
DESTINO="$LAB/documentos/apuntes.txt"

if [[ ! -f "$DESTINO" ]]; then
    echo "TODAVÍA NO: no existe $DESTINO"
    echo "Sugerencia: usá 'ls -a' para ver archivos y directorios ocultos."
    exit 1
fi

if [[ ! -s "$DESTINO" ]]; then
    echo "CASI: hay un apuntes.txt en documentos/, pero está VACÍO."
    echo "Copiaste un señuelo. Verificá los tamaños con 'ls -l'."
    exit 1
fi

if [[ -f "$LAB/proyectos/.backup/.old/.tmp/apuntes.txt" ]]; then
    echo "CASI: el archivo verdadero sigue en su escondite."
    echo "Tenés que MOVERLO (mv), no solo copiarlo."
    exit 1
fi

echo "¡LABORATORIO REPARADO! apuntes.txt volvió a documentos/ con su contenido."
echo "Dominaste: ls -a, ls -l, cd, pwd, rutas absolutas y relativas."
EOF
chmod +x "$LAB"/verificar.sh

# --- Explicación para el estudiante --------------------------------------------
cat <<EOF

=====================================================================
 LAB ROTO Y LISTO — Tema 2.3: Using Directories and Listing Files
=====================================================================

 ESCENARIO:
   Tenías tus apuntes del examen en:
       $LAB/documentos/apuntes.txt
   ...pero un "script de backup defectuoso" los movió a un lugar
   desconocido dentro del laboratorio y dejó copias falsas (vacías)
   repartidas por ahí.

 SÍNTOMA QUE VAS A VER:
   - "ls $LAB/documentos" muestra el directorio vacío (¿seguro?).
   - Hay varios apuntes.txt en el árbol, pero "ls -l" revela que
     tienen tamaño 0: son señuelos.
   - Con "ls" normal NO vas a encontrar el verdadero: está dentro
     de directorios ocultos (su nombre empieza con ".").

 TU MISIÓN (el "fix"):
   1. Navegá el árbol con cd y pwd (probá rutas absolutas Y relativas).
   2. Encontrá el apuntes.txt VERDADERO (el que tiene contenido).
   3. Movelo de vuelta a $LAB/documentos/apuntes.txt
   4. Comprobá tu trabajo:  bash $LAB/verificar.sh

 HERRAMIENTAS PERMITIDAS (las del tema 2.3):
   pwd, cd, ls, ls -a, ls -l, ls -R, ls -d, mv
   (Nada de find ni grep: la gracia es practicar ls y cd.)

 Empezá con:
   cd $LAB
   pwd
   ls

=====================================================================

EOF

# =============================================================================
#  SOLUCIÓN PASO A PASO (¡no mirar hasta intentarlo!)
# =============================================================================
#
#  1. Entrar al laboratorio y ubicarse:
#       cd ~/lab-lpi-2.3        # "~" es tu directorio home
#       pwd                     # confirma dónde estás (ruta absoluta)
#
#  2. Listar lo visible... y lo oculto:
#       ls                      # vista normal: no aparece todo
#       ls -a                   # aparecen ".labrc", "." y ".."
#
#  3. Buscar la pista en documentos/ (ruta relativa):
#       cd documentos
#       ls -a                   # aparece .pista.txt
#       cat .pista.txt          # dice que busques en proyectos/
#       cd ..                   # ".." sube al directorio padre
#
#  4. Explorar proyectos/ incluyendo ocultos:
#       cd proyectos
#       ls -a                   # aparece el directorio oculto .backup
#       cd .backup
#       ls -a                   # aparece .old
#       cd .old/.tmp            # ruta relativa encadenada
#       pwd                     # ~/lab-lpi-2.3/proyectos/.backup/.old/.tmp
#       ls -l                   # apuntes.txt con tamaño > 0: ¡el verdadero!
#
#     (Atajo: "ls -laR ~/lab-lpi-2.3" lista TODO el árbol, ocultos
#      incluidos, de una sola vez.)
#
#  5. Mover el archivo a su lugar usando una ruta absoluta:
#       mv apuntes.txt ~/lab-lpi-2.3/documentos/apuntes.txt
#
#     ...o, sin moverte de ~/lab-lpi-2.3, con rutas relativas:
#       mv proyectos/.backup/.old/.tmp/apuntes.txt documentos/
#
#  6. Verificar que no copiaste un señuelo (tamaño 0 = falso):
#       ls -l ~/lab-lpi-2.3/documentos/apuntes.txt
#       ls -l ~/lab-lpi-2.3/musica/apuntes.txt      # señuelo vacío
#
#  7. Correr la verificación:
#       bash ~/lab-lpi-2.3/verificar.sh
#
#  CONCEPTOS CLAVE REPASADOS:
#   - Los archivos/directorios cuyo nombre empieza con "." están ocultos;
#     "ls -a" los muestra ("-A" los muestra sin "." ni "..").
#   - "." es el directorio actual y ".." el directorio padre.
#   - Ruta absoluta: empieza en "/" (o "~" que expande al home).
#     Ruta relativa: se interpreta desde el directorio actual (pwd).
#   - "ls -l" muestra tamaño y metadatos; "ls -R" lista recursivamente;
#     "ls -d" lista el directorio en sí, no su contenido.
#
#  Para limpiar el laboratorio al terminar:
#       rm -rf ~/lab-lpi-2.3
#
#  Fuente de referencia:
#   https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
# =============================================================================