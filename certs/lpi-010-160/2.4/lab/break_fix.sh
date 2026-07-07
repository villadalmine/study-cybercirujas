#!/usr/bin/env bash
#
# =====================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160, versión 1.6)
#  Tema 2.4: Creating, Moving and Deleting Files (peso: 2)
#
#  Referencia (solo consulta, no copiado literal):
#    https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
#
#  USO:
#    bash lab-2.4-break-fix.sh          -> prepara (rompe) el escenario
#    bash lab-2.4-break-fix.sh check    -> verifica si ya lo arreglaste
#
#  SEGURIDAD:
#    - Pensado para una VM de laboratorio DESCARTABLE.
#    - Solo crea y borra archivos dentro de $HOME/lab-lpi-2.4.
#    - No toca nada del sistema ni requiere root. NO lo ejecutes como root.
# =====================================================================

set -u

LAB="$HOME/lab-lpi-2.4"

# ---------------------------------------------------------------------
# MODO VERIFICACIÓN: bash lab-2.4-break-fix.sh check
# ---------------------------------------------------------------------
if [ "${1:-}" = "check" ]; then
    echo "=== Verificando tu solución en $LAB ==="
    ok=0; fail=0

    chk() {  # chk "descripción" "condición de test"
        if eval "$2"; then
            echo "  [OK]    $1"; ok=$((ok+1))
        else
            echo "  [FALTA] $1"; fail=$((fail+1))
        fi
    }

    chk "Existe el árbol proyecto/informes"            "[ -d '$LAB/proyecto/informes' ]"
    chk "Existe el árbol proyecto/datos"               "[ -d '$LAB/proyecto/datos' ]"
    chk "Existe el árbol proyecto/respaldo"            "[ -d '$LAB/proyecto/respaldo' ]"
    chk "Los 3 .txt están en proyecto/informes"        "[ \$(ls '$LAB/proyecto/informes/'*.txt 2>/dev/null | wc -l) -eq 3 ]"
    chk "Los 2 .csv están en proyecto/datos"           "[ \$(ls '$LAB/proyecto/datos/'*.csv 2>/dev/null | wc -l) -eq 2 ]"
    chk "No quedan .txt ni .csv sueltos en la raíz"    "[ \$(ls '$LAB/'*.txt '$LAB/'*.csv 2>/dev/null | wc -l) -eq 0 ]"
    chk "Hay una copia de los .txt en proyecto/respaldo" "[ \$(ls '$LAB/proyecto/respaldo/'*.txt 2>/dev/null | wc -l) -ge 3 ]"
    chk "El archivo '-basura.tmp' fue eliminado"       "[ ! -e '$LAB/-basura.tmp' ]"
    chk "El directorio 'temporal' fue eliminado"       "[ ! -d '$LAB/temporal' ]"

    echo
    if [ "$fail" -eq 0 ]; then
        echo ">>> ¡Excelente! Escenario resuelto. Dominás mkdir, cp, mv, rm y globbing."
    else
        echo ">>> Todavía faltan $fail objetivo(s). Releé el enunciado y seguí intentando."
    fi
    exit 0
fi

# ---------------------------------------------------------------------
# PREPARACIÓN DEL ESCENARIO ("BREAK")
# ---------------------------------------------------------------------
echo "=== Preparando el escenario roto en $LAB ==="

# Empezar de cero, pero SOLO dentro del directorio del lab
rm -rf "$LAB"
mkdir -p "$LAB"
cd "$LAB" || exit 1

# 1) Archivos de trabajo tirados en la raíz del lab, sin estructura
for n in enero febrero marzo; do
    echo "Informe mensual: $n" > "informe_$n.txt"
done
echo "id,valor" > ventas.csv
echo "id,valor" > gastos.csv

# 2) Un archivo cuyo nombre empieza con guion: rm "normal" falla con él
echo "archivo basura" > ./-basura.tmp

# 3) Un directorio que parece vacío pero no lo está (archivo oculto):
#    rmdir va a fallar y el estudiante debe descubrir por qué
mkdir temporal
echo "cache vieja" > temporal/.oculto

cat <<'ENUNCIADO'

=====================================================================
 ESCENARIO
=====================================================================
Un compañero desordenó el directorio de trabajo del equipo antes de
irse de vacaciones. Entrá al laboratorio con:

    cd ~/lab-lpi-2.4

SÍNTOMAS QUE VAS A VER:
  1. Los informes (*.txt) y las planillas (*.csv) están tirados en la
     raíz del lab, sin ninguna estructura de directorios.
  2. Hay un archivo llamado "-basura.tmp". Si intentás borrarlo con
       rm -basura.tmp
     rm se queja con "invalid option" porque interpreta el nombre
     como si fueran opciones.
  3. Hay un directorio "temporal" que parece vacío con "ls", pero
       rmdir temporal
     falla con "Directory not empty".

QUÉ TENÉS QUE LOGRAR (sin salir de ~/lab-lpi-2.4):
  a) Crear en UN solo comando el árbol:
         proyecto/informes
         proyecto/datos
         proyecto/respaldo
     (pista: mkdir tiene una opción para crear padres e hijos juntos).
  b) Mover TODOS los .txt a proyecto/informes y TODOS los .csv a
     proyecto/datos usando globbing (wildcards), no archivo por archivo.
  c) Copiar los informes a proyecto/respaldo (copia, no movimiento).
  d) Eliminar el archivo "-basura.tmp" a pesar del guion inicial.
  e) Eliminar el directorio "temporal", investigando primero por qué
     rmdir dice que no está vacío.

Cuando creas que terminaste, verificá con:

    bash lab-2.4-break-fix.sh check

Comandos del tema: mkdir, rmdir, cp, mv, rm, ls  + wildcards (* ? [])
=====================================================================
ENUNCIADO

exit 0

# =====================================================================
#  SOLUCIÓN PASO A PASO (¡no mires hasta intentarlo!)
# =====================================================================
#
#  cd ~/lab-lpi-2.4
#
#  Paso a) Crear todo el árbol en un solo comando.
#     La opción -p (parents) de mkdir crea los directorios intermedios
#     que falten, y podés pasar varias rutas a la vez:
#
#         mkdir -p proyecto/informes proyecto/datos proyecto/respaldo
#
#  Paso b) Mover por lote con globbing.
#     El wildcard * expande a todos los nombres que coincidan, así que
#     no hace falta escribir cada archivo:
#
#         mv *.txt proyecto/informes/
#         mv *.csv proyecto/datos/
#
#     (El último argumento de mv es el directorio de destino.)
#
#  Paso c) Copiar (no mover) los informes al respaldo:
#
#         cp proyecto/informes/*.txt proyecto/respaldo/
#
#     Alternativa recursiva, copiando el directorio entero:
#         cp -r proyecto/informes/. proyecto/respaldo/
#
#  Paso d) Borrar el archivo que empieza con guion.
#     "rm -basura.tmp" falla porque rm lee "-b", "-a"... como opciones.
#     Dos soluciones clásicas:
#
#         rm -- -basura.tmp      # "--" marca el fin de las opciones
#         rm ./-basura.tmp       # la ruta ya no empieza con "-"
#
#  Paso e) Eliminar "temporal".
#     Primero investigá por qué "no está vacío": ls normal no muestra
#     archivos ocultos, hace falta -a (o -A):
#
#         ls -a temporal         # aparece el archivo .oculto
#
#     Opción 1 (con rmdir, que solo borra directorios vacíos):
#         rm temporal/.oculto
#         rmdir temporal
#
#     Opción 2 (recursiva, borra el directorio con su contenido):
#         rm -r temporal
#
#     Nota de examen: rmdir SOLO funciona con directorios vacíos;
#     rm -r elimina recursivamente y rm -rf además no pregunta ni
#     avisa (usalo con muchísimo cuidado).
#
#  Verificación final:
#
#         bash lab-2.4-break-fix.sh check
#
#  Referencia: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
# =====================================================================