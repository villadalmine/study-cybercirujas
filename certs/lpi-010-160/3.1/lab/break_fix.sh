#!/bin/bash
#
# =============================================================================
#  LAB BREAK & FIX — LPI Linux Essentials (010-160 v1.6)
#  Tema 3.1: Archiving Files on the Command Line (peso: 2)
#
#  Referencia de estudio:
#    https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
#
#  ¿Qué hace este script?
#    Prepara un directorio de laboratorio (~/lab-archiving) con tres
#    escenarios "rotos" de forma controlada y segura. Nada fuera de ese
#    directorio se modifica. Pensado para una VM de laboratorio descartable.
#
#  Uso:
#    bash lab-archiving-breakfix.sh        # prepara el laboratorio
#    bash lab-archiving-breakfix.sh reset  # borra y vuelve a preparar
#
#  La solución paso a paso está COMENTADA al final del script.
#  ¡No la mires hasta intentarlo!
# =============================================================================

set -euo pipefail

LAB="$HOME/lab-archiving"

# --- Verificación de herramientas necesarias --------------------------------
for cmd in tar gzip bzip2 xz zip unzip file; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: falta el comando '$cmd'. Instalalo antes de continuar." >&2
        echo "  (en Debian/Ubuntu: sudo apt install tar gzip bzip2 xz-utils zip unzip file)" >&2
        exit 1
    fi
done

# --- Reset opcional ----------------------------------------------------------
if [ "${1:-}" = "reset" ] && [ -d "$LAB" ]; then
    rm -rf "$LAB"
    echo "[*] Laboratorio anterior eliminado."
fi

if [ -d "$LAB" ]; then
    echo "ERROR: ya existe $LAB. Ejecutá con 'reset' para regenerarlo." >&2
    exit 1
fi

mkdir -p "$LAB"
cd "$LAB"

# =============================================================================
#  PREPARACIÓN DE DATOS DE EJEMPLO (esto NO está roto)
# =============================================================================
mkdir -p proyecto/docs proyecto/src
echo "Informe trimestral de ventas - datos importantes"  > proyecto/docs/informe.txt
echo "print('hola mundo')"                               > proyecto/src/app.py
echo "Configuracion del servidor: puerto=8080"           > proyecto/config.txt

# =============================================================================
#  ESCENARIO 1: la extensión miente
#  Se crea un archive comprimido con bzip2... pero se lo nombra .tar.gz
# =============================================================================
tar -cjf backup-proyecto.tar.bz2 proyecto
mv backup-proyecto.tar.bz2 backup-proyecto.tar.gz

# =============================================================================
#  ESCENARIO 2: texto "ilegible"
#  Un archivo de notas fue comprimido con gzip y luego renombrado sin la
#  extensión .gz. Al hacer cat, el estudiante verá caracteres binarios.
# =============================================================================
echo "Password del router del lab: laboratorio123 (solo ejemplo)" > notas.txt
gzip notas.txt
mv notas.txt.gz notas.txt

# =============================================================================
#  ESCENARIO 3: extracción que "pierde" archivos
#  Un zip con estructura de directorios; el estudiante debe listar su
#  contenido SIN extraerlo y encontrar un archivo puntual adentro.
# =============================================================================
mkdir -p .oculto/nivel1/nivel2
echo "FLAG-LPI-3.1: encontraste el archivo perdido" > .oculto/nivel1/nivel2/tesoro.txt
( cd .oculto && zip -qr ../misterio.zip nivel1 )
rm -rf .oculto

# =============================================================================
#  INSTRUCCIONES PARA EL ESTUDIANTE
# =============================================================================
cat <<'EOF'

=============================================================
  LABORATORIO LISTO: ~/lab-archiving
=============================================================

Trabajá dentro de ~/lab-archiving. Tenés 3 desafíos:

--- DESAFÍO 1: backup-proyecto.tar.gz ---
SÍNTOMA: al intentar extraerlo con
    tar -xzf backup-proyecto.tar.gz
vas a ver un error del estilo:
    gzip: stdin: not in gzip format
    tar: Child returned status 1
OBJETIVO: descubrir el formato REAL del archivo (pista: comando
'file') y extraerlo correctamente. Debe aparecer el directorio
'proyecto/' con su contenido intacto.

--- DESAFÍO 2: notas.txt ---
SÍNTOMA: al hacer
    cat notas.txt
la terminal muestra caracteres binarios ilegibles.
OBJETIVO: identificar qué le pasó al archivo y recuperar el texto
original en un notas.txt legible con cat.

--- DESAFÍO 3: misterio.zip ---
OBJETIVO: SIN extraer todo a ciegas, primero listá el contenido
del zip desde la línea de comandos, ubicá el archivo 'tesoro.txt'
y mostrá su contenido (contiene una FLAG).

Comandos que te conviene repasar:
  file, tar (-c, -x, -t, -z, -j, -J, -f, -v), gzip/gunzip,
  bzip2/bunzip2, xz/unxz, zip, unzip (-l)

Cuando termines, verificá:
  1) proyecto/ extraído del backup, con docs/ y src/ adentro
  2) cat notas.txt muestra texto legible
  3) podés mostrar la FLAG de tesoro.txt

=============================================================
EOF

# =============================================================================
# =============================================================================
#
#   S O L U C I Ó N   P A S O   A   P A S O   (no mirar antes de intentar)
#
# =============================================================================
# =============================================================================
#
# --- DESAFÍO 1 ---------------------------------------------------------------
# 1) Nunca confíes en la extensión: preguntale al kernel de verdad qué es:
#
#       file backup-proyecto.tar.gz
#       # -> "bzip2 compressed data"  (¡no es gzip!)
#
# 2) La opción -z de tar es para gzip; para bzip2 se usa -j:
#
#       tar -xjf backup-proyecto.tar.gz
#
#    Alternativa: las versiones modernas de GNU tar detectan la compresión
#    automáticamente al extraer, así que esto también funciona:
#
#       tar -xf backup-proyecto.tar.gz
#
# 3) (Opcional, buena práctica) Renombrar con la extensión correcta:
#
#       mv backup-proyecto.tar.gz backup-proyecto.tar.bz2
#
# 4) Verificar: ls proyecto/ debe mostrar config.txt, docs/ y src/
#
#    Concepto de examen: -z = gzip (.tar.gz), -j = bzip2 (.tar.bz2),
#    -J = xz (.tar.xz). Para LISTAR sin extraer: tar -tf archivo.
#
# --- DESAFÍO 2 ---------------------------------------------------------------
# 1) Diagnóstico:
#
#       file notas.txt
#       # -> "gzip compressed data, was 'notas.txt' ..."
#
# 2) gzip exige la extensión .gz para descomprimir, así que primero
#    renombramos y luego descomprimimos:
#
#       mv notas.txt notas.txt.gz
#       gunzip notas.txt.gz          # equivalente: gzip -d notas.txt.gz
#
#    Alternativa sin renombrar (manda el resultado a stdout):
#
#       zcat notas.txt               # o: gzip -dc notas.txt
#
# 3) Verificar: cat notas.txt muestra el texto legible.
#
#    Concepto de examen: gzip/gunzip REEMPLAZAN el archivo original
#    (notas.txt <-> notas.txt.gz); zcat permite ver el contenido sin
#    descomprimir en disco.
#
# --- DESAFÍO 3 ---------------------------------------------------------------
# 1) Listar el contenido del zip sin extraer:
#
#       unzip -l misterio.zip
#       # -> nivel1/nivel2/tesoro.txt
#
# 2) Extraer (todo, o solo el archivo puntual):
#
#       unzip misterio.zip                          # todo
#       unzip misterio.zip nivel1/nivel2/tesoro.txt # solo ese archivo
#
# 3) Mostrar la FLAG:
#
#       cat nivel1/nivel2/tesoro.txt
#
#    Concepto de examen: a diferencia de tar (que archiva y comprime con
#    ayuda de gzip/bzip2/xz), zip archiva Y comprime en un solo formato,
#    y unzip -l equivale conceptualmente a tar -tf.
#
# --- LIMPIEZA FINAL DEL LAB ---------------------------------------------------
#       rm -rf ~/lab-archiving
#
# =============================================================================