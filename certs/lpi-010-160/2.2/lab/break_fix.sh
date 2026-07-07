#!/usr/bin/env bash
#
# =============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160, v1.6)
#  Tema 2.2: Using the Command Line to Get Help
#  Peso en el examen: 2
#
#  Referencia (solo como material de consulta, contenido original):
#    https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script necesita root (sudo). No borra ni modifica archivos del
#  sistema existentes: únicamente CREA archivos nuevos, así que el
#  arreglo consiste en encontrarlos y eliminarlos.
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: ejecutá este script como root (sudo $0)" >&2
    exit 1
fi

echo "=============================================================="
echo " Preparando el escenario de fallas del sistema de ayuda..."
echo "=============================================================="

# -----------------------------------------------------------------------------
# ROTURA 1: un 'man' impostor que se antepone al verdadero
# -----------------------------------------------------------------------------
# Creamos un script falso en /usr/local/bin, que en la mayoría de las
# distribuciones aparece ANTES que /usr/bin en el PATH. Al escribir 'man',
# el shell va a ejecutar este impostor y no el binario real.
cat > /usr/local/bin/man <<'EOF'
#!/bin/sh
echo "man: fatal error: cannot open manual database" >&2
exit 1
EOF
chmod 755 /usr/local/bin/man

# -----------------------------------------------------------------------------
# ROTURA 2: MANPATH apuntando a un directorio vacío
# -----------------------------------------------------------------------------
# Definimos la variable MANPATH en un archivo de perfil global. Cuando MANPATH
# está definida (sin ':' inicial o final), REEMPLAZA por completo la lista de
# rutas donde man, apropos y whatis buscan las páginas. Con un directorio
# vacío, incluso el 'man' verdadero deja de encontrar documentación, y
# 'apropos' / 'whatis' responden "nothing appropriate".
mkdir -p /opt/lab-manpages-vacio
cat > /etc/profile.d/99-lab-manpath.sh <<'EOF'
# Archivo plantado por el laboratorio break & fix (tema 2.2)
export MANPATH=/opt/lab-manpages-vacio
EOF
chmod 644 /etc/profile.d/99-lab-manpath.sh

# Limpiamos el hash de comandos del shell actual para que el impostor
# tome efecto de inmediato en esta sesión.
hash -r 2>/dev/null || true

clear 2>/dev/null || true
cat <<'BRIEFING'
==============================================================
 ESCENARIO: "El día que se apagó la ayuda"
==============================================================

Un compañero hizo "una mejora" en el servidor y desde entonces
nadie puede consultar la documentación. Cerrá esta sesión,
abrí una nueva (o hacé: exec bash -l) y probá lo siguiente:

  SÍNTOMAS QUE VAS A VER
  ----------------------
  1) man ls
       -> "man: fatal error: cannot open manual database"
  2) apropos copy   (o: whatis cp)
       -> "nothing appropriate" / "nada apropiado"
  3) Sin embargo, 'ls --help' sigue funcionando perfecto,
     o sea que los programas y su ayuda integrada están bien.

  TU MISIÓN
  ---------
  a) Descubrir POR QUÉ 'man' falla aunque el paquete man-db
     está instalado y sano.
  b) Descubrir por qué, aun arreglando (a), man/apropos/whatis
     no encuentran ninguna página.
  c) Dejar el sistema como antes: 'man ls', 'whatis cp' y
     'apropos copy' deben volver a funcionar en una sesión
     de login nueva.

  HERRAMIENTAS DEL TEMA 2.2 QUE TE VAN A SALVAR
  ---------------------------------------------
    type man          # ¿qué ejecuta realmente el shell?
    which -a man      # ¿cuántos 'man' hay en el PATH y en qué orden?
    echo $PATH        # orden de búsqueda de comandos
    echo $MANPATH     # rutas donde man busca sus páginas
    manpath           # rutas efectivas que usaría man
    man --help        # la ayuda integrada nunca te abandona
    grep -r MANPATH /etc/profile.d/   # ¿quién define esa variable?

  No sigas leyendo hasta resolverlo... la solución está
  comentada al final de este script.
==============================================================
BRIEFING

exit 0

# =============================================================================
#  SOLUCIÓN PASO A PASO (no leer antes de intentarlo)
# =============================================================================
#
# --- Diagnóstico de la ROTURA 1 (el 'man' impostor) ---------------------
#
# 1) Preguntale al shell qué está ejecutando en realidad:
#       type man
#    Respuesta: "man is /usr/local/bin/man"  <- ¡no es /usr/bin/man!
#
# 2) Confirmá cuántos 'man' hay en el PATH y su orden de precedencia:
#       which -a man
#    Vas a ver /usr/local/bin/man ANTES que /usr/bin/man, porque en
#    el PATH /usr/local/bin aparece primero. El shell ejecuta el
#    primer match, por eso el impostor gana.
#
# 3) Mirá el contenido del impostor y comprobá que es un script falso:
#       cat /usr/local/bin/man
#
# 4) Eliminalo y refrescá la caché de comandos del shell:
#       sudo rm /usr/local/bin/man
#       hash -r
#
# --- Diagnóstico de la ROTURA 2 (MANPATH vacío) --------------------------
#
# 5) Ahora 'man ls' ejecuta el binario real, pero sigue sin encontrar
#    páginas, y 'apropos copy' responde "nothing appropriate".
#    Revisá la variable de entorno que controla dónde busca man:
#       echo $MANPATH        -> /opt/lab-manpages-vacio
#       manpath              -> avisa que MANPATH está definida y la usa
#    Cuando MANPATH está definida, reemplaza la lista de directorios
#    estándar (/usr/share/man, etc.), y ese directorio está vacío.
#
# 6) Encontrá quién la define en los archivos de perfil globales:
#       grep -r MANPATH /etc/profile.d/
#    Resultado: /etc/profile.d/99-lab-manpath.sh
#
# 7) Eliminá el archivo plantado y el directorio señuelo:
#       sudo rm /etc/profile.d/99-lab-manpath.sh
#       sudo rmdir /opt/lab-manpages-vacio
#
# 8) La variable sigue exportada en tu sesión actual; limpiala o abrí
#    una sesión de login nueva:
#       unset MANPATH        # o: exec bash -l
#
# --- Verificación final ---------------------------------------------------
#
# 9) Todo debe funcionar de nuevo:
#       man ls          # abre la página de manual (salir con 'q')
#       whatis cp       # muestra la descripción corta de cp
#       apropos copy    # lista comandos relacionados con "copy"
#    Si apropos/whatis siguieran vacíos en alguna distro, regenerá el
#    índice de la base de datos de man:
#       sudo mandb
#
# --- Moraleja (lo que evalúa el objetivo 2.2) -----------------------------
#
#  * 'man', 'apropos'/'man -k' y 'whatis' dependen de dónde estén las
#    páginas (MANPATH / manpath) y de su índice (mandb).
#  * El shell ejecuta el primer comando que encuentra en el PATH:
#    'type' y 'which -a' revelan impostores y problemas de precedencia.
#  * La ayuda integrada ('comando --help') vive dentro de cada binario
#    y funciona aunque el sistema de manuales esté roto: es tu primera
#    línea de auxilio para diagnosticar.
#
#  Referencia consultada:
#    https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
# =============================================================================