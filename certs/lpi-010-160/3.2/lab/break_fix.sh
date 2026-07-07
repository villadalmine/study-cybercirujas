#!/bin/bash
#
# =============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160, v1.6)
#  Tema 3.2: Searching and Extracting Data from Files
#  Peso en el examen: 3
#
#  Comandos que se practican: grep, cut, sort, uniq, wc, head, tail,
#  redirection (>, >>, 2>), pipes (|) y basic regular expressions.
#
#  Referencia (consultada, no copiada):
#  https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script trabaja únicamente dentro de ~/lab-lpi-3.2 y no toca
#  archivos del sistema, pero la regla de oro de un lab break & fix
#  es: máquina descartable, snapshot previo si es posible.
# =============================================================================

set -euo pipefail

LAB_DIR="$HOME/lab-lpi-3.2"

# -----------------------------------------------------------------------------
# 0. Confirmación de seguridad
# -----------------------------------------------------------------------------
echo "============================================================"
echo " LAB BREAK & FIX — Tema 3.2: Searching and Extracting Data"
echo "============================================================"
echo
echo "Este script va a crear (o recrear) el directorio: $LAB_DIR"
echo "y va a dejar allí un escenario ROTO a propósito."
echo
read -r -p "¿Estás en una VM de laboratorio descartable? (escribí SI para continuar): " CONFIRMA
if [ "$CONFIRMA" != "SI" ]; then
    echo "Abortado. Ejecutá este lab solo en una VM descartable."
    exit 1
fi

# -----------------------------------------------------------------------------
# 1. Preparar el escenario: datos de ejemplo
# -----------------------------------------------------------------------------
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR"
cd "$LAB_DIR"

# Un "log" de aplicación inventado, con campos separados por ';'
# Formato: FECHA;NIVEL;USUARIO;MENSAJE
cat > app.log <<'EOF'
2026-07-01;INFO;ana;login ok
2026-07-01;ERROR;bruno;password incorrecto
2026-07-01;INFO;carla;login ok
2026-07-02;WARN;ana;disco al 85%
2026-07-02;ERROR;bruno;password incorrecto
2026-07-02;ERROR;dario;cuenta bloqueada
2026-07-03;INFO;ana;logout
2026-07-03;ERROR;bruno;password incorrecto
2026-07-03;INFO;elena;login ok
2026-07-03;WARN;carla;disco al 90%
2026-07-04;ERROR;elena;token expirado
2026-07-04;INFO;dario;login ok
EOF

# -----------------------------------------------------------------------------
# 2. EL "BREAK": un script de reporte saboteado
# -----------------------------------------------------------------------------
# El equipo de operaciones usa reporte.sh para generar reporte.txt con:
#   a) todas las líneas de nivel ERROR del log
#   b) la lista de usuarios con errores, sin duplicados y ordenada
#   c) el total de líneas ERROR
#
# Alguien lo rompió con CUATRO errores clásicos del tema 3.2.
cat > reporte.sh <<'EOF'
#!/bin/bash
# reporte.sh — genera reporte.txt a partir de app.log
# *** ESTE SCRIPT ESTÁ ROTO A PROPÓSITO: NO LO EJECUTES SIN LEERLO ***

# (a) Buscar las líneas de error
grep 'error' app.log > reporte.txt

# (b) Usuarios con errores, sin duplicados y ordenados
grep 'error' app.log | cut -d ',' -f 3 | uniq | sort > reporte.txt

# (c) Contar cuántas líneas de error hay
grep -c 'error' app.log 2> reporte.txt
EOF
chmod +x reporte.sh

# Generamos el "síntoma": el reporte roto que encontró el estudiante
./reporte.sh || true

# -----------------------------------------------------------------------------
# 3. Briefing para el estudiante
# -----------------------------------------------------------------------------
cat <<EOF

============================================================
 ESCENARIO
============================================================
Directorio del lab: $LAB_DIR
Archivos:
  - app.log     : log de la aplicación (campos separados por ';')
  - reporte.sh  : script de reporte SABOTEADO
  - reporte.txt : la salida rota que produce hoy

SÍNTOMA QUE VAS A VER:
  Ejecutá:  cd $LAB_DIR && ./reporte.sh && cat reporte.txt
  El archivo reporte.txt queda VACÍO (o casi), aunque app.log
  claramente contiene líneas con ERROR. Comprobalo vos mismo:
      grep ERROR app.log

TU MISIÓN (criterio de éxito):
  Arreglar reporte.sh para que reporte.txt contenga, en este orden:
    1) Todas las líneas de nivel ERROR de app.log
    2) La lista de usuarios con errores, ÚNICOS y ordenados
       alfabéticamente (una sola vez cada uno)
    3) Una línea final con el número total de líneas ERROR

PISTAS (hay 4 bugs, todos del tema 3.2):
  - grep distingue mayúsculas de minúsculas por defecto.
    ¿Qué dice exactamente el log: 'error' o 'ERROR'?
    (mirá también la opción -i en 'man grep')
  - ¿Qué diferencia hay entre '>' y '>>' cuando escribís
    varias veces en el mismo archivo? (output redirection)
  - cut -d define el delimiter: ¿el log usa ',' o ';'?
  - uniq solo elimina duplicados ADYACENTES: ¿va antes o
    después de sort en el pipeline?
  - Bonus: '2>' redirige stderr, no stdout. ¿Era eso lo que
    el paso (c) quería hacer?

Herramientas permitidas: grep, cut, sort, uniq, wc, head, tail,
pipes y redirection. La solución está comentada al final de
este mismo script ($0): no la mires hasta intentarlo.
============================================================
EOF

exit 0

# =============================================================================
#  SOLUCIÓN PASO A PASO (spoiler — intentalo primero)
# =============================================================================
#
# Diagnóstico bug por bug:
#
# BUG 1 — Pattern con mayúsculas/minúsculas incorrectas.
#   El script busca grep 'error' pero el log dice 'ERROR'.
#   grep es case-sensitive por defecto, así que no encuentra nada.
#   Fix: grep 'ERROR' app.log   (o grep -i 'error' app.log)
#   Verificación:  grep -c 'ERROR' app.log   -> debe dar 5
#
# BUG 2 — Sobrescritura con '>' en cada paso.
#   Cada comando usa '> reporte.txt', y '>' TRUNCA el archivo.
#   El paso (b) pisa lo que escribió (a), y el paso (c) pisa todo
#   de nuevo. Fix: el primer comando usa '>' (crear/limpiar) y los
#   siguientes usan '>>' (append).
#
# BUG 3 — Delimiter equivocado en cut.
#   El log separa campos con ';' pero el script usa cut -d ','.
#   Con un delimiter que no existe en la línea, cut devuelve la
#   línea entera en lugar del campo 3 (el usuario).
#   Fix: cut -d ';' -f 3
#
# BUG 4 — uniq antes de sort.
#   uniq solo colapsa líneas repetidas si están ADYACENTES.
#   El orden correcto del pipeline es: ... | sort | uniq
#   (bruno aparece 3 veces en días distintos: sin sort primero,
#   podrían quedar duplicados).
#
# BUG BONUS — '2>' en el conteo.
#   'grep -c ... 2> reporte.txt' manda STDERR al archivo y el
#   número (que sale por STDOUT) a la pantalla. Como grep no
#   emite errores, reporte.txt queda vacío. Fix: usar '>>'
#   (stdout, en modo append).
#
# reporte.sh corregido:
# -----------------------------------------------------------------
# #!/bin/bash
# # (a) líneas de error — '>' crea/limpia el reporte
# grep 'ERROR' app.log > reporte.txt
#
# # (b) usuarios únicos ordenados — ';' como delimiter, sort ANTES de uniq
# grep 'ERROR' app.log | cut -d ';' -f 3 | sort | uniq >> reporte.txt
#
# # (c) total de líneas ERROR — stdout con append, no '2>'
# grep -c 'ERROR' app.log >> reporte.txt
# -----------------------------------------------------------------
#
# Verificación final:
#   ./reporte.sh && cat reporte.txt
#   Esperado: 5 líneas ERROR, luego los usuarios
#   bruno / dario / elena (una vez cada uno, en orden), y al
#   final el número 5.
#   Chequeo extra:  wc -l reporte.txt   -> 9 líneas en total.
#
# Conceptos del examen repasados:
#   - grep y case sensitivity (-i, -c)
#   - output redirection: '>' vs '>>' y stdout vs stderr ('2>')
#   - cut -d / -f para extraer campos
#   - sort | uniq y por qué ese orden
#   - pipes para encadenar filtros
#
# Fuente de referencia:
#   https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
# =============================================================================