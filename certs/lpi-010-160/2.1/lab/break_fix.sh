#!/usr/bin/env bash
#
# ============================================================================
#  LAB BREAK & FIX — LPI Linux Essentials (010-160 v1.6)
#  Tema 2.1: Command Line Basics (peso: 3)
#
#  Conceptos que practica este laboratorio:
#    - La variable de entorno PATH y cómo el shell localiza los comandos
#    - Diferencia entre shell builtins, comandos externos y aliases
#    - Uso de type, export, echo, unalias y rutas absolutas
#    - Archivos de configuración del shell (~/.bashrc)
#
#  Material de referencia (usado solo como guía, contenido original):
#    https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script rompe el entorno del usuario actual de forma controlada
#  y reversible (guarda un backup de ~/.bashrc antes de tocar nada).
# ============================================================================

set -u

MARCA="$HOME/.lab_2_1_roto"
BASHRC="$HOME/.bashrc"
BACKUP="$HOME/.bashrc.backup-lab-2.1"

# --- Controles de seguridad --------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: no ejecutes este laboratorio como root."
    echo "Usá un usuario normal en una VM descartable."
    exit 1
fi

if [ -f "$MARCA" ]; then
    echo "El laboratorio ya está activo. Arreglalo antes de volver a romperlo."
    echo "Pista: tu backup está en $BACKUP"
    exit 1
fi

if [ ! -f "$BASHRC" ]; then
    echo "ERROR: no existe $BASHRC. Este laboratorio necesita bash como shell."
    exit 1
fi

echo "============================================================"
echo " LAB 2.1 — Command Line Basics: BREAK & FIX"
echo "============================================================"
echo
echo "Este script va a modificar tu ~/.bashrc para simular un"
echo "entorno de shell mal configurado. Es reversible y se guarda"
echo "un backup, pero SOLO debe usarse en una VM de laboratorio."
echo
read -r -p "¿Estás en una VM descartable y querés continuar? (escribí SI): " RESP
if [ "$RESP" != "SI" ]; then
    echo "Cancelado. No se modificó nada."
    exit 0
fi

# --- BREAK: romper el entorno de forma controlada ----------------------------

cp "$BASHRC" "$BACKUP"

cat >> "$BASHRC" <<'EOF'

# >>> LAB-2.1-BREAK (inicio) — NO borrar a mano sin leer las instrucciones
# Un "administrador distraído" quiso agregar un directorio al PATH,
# pero en lugar de agregarlo, lo reemplazó por completo:
export PATH="/opt/herramientas_inexistentes"
# Además dejó un alias que enmascara al verdadero comando ls:
alias ls='echo "ls: no puedo trabajar así, arreglá tu PATH primero"'
# <<< LAB-2.1-BREAK (fin)
EOF

touch "$MARCA"

# --- Instrucciones para el estudiante ----------------------------------------

echo
echo "============================================================"
echo " ENTORNO ROTO. Leé con atención antes de abrir otra terminal."
echo "============================================================"
echo
echo "QUÉ SE ROMPIÓ"
echo "  Tu ~/.bashrc ahora contiene dos problemas típicos:"
echo "    1. La variable PATH fue REEMPLAZADA (no ampliada), así que"
echo "       el shell ya no encuentra los comandos externos."
echo "    2. Un alias enmascara al comando ls."
echo
echo "SÍNTOMA QUE VAS A VER"
echo "  Abrí una terminal NUEVA (o corré: bash) y probá comandos:"
echo "    - cat, grep, nano, vi  ->  'command not found'"
echo "    - ls                   ->  imprime un mensaje burlón en vez"
echo "                               de listar archivos"
echo "    - cd, echo, pwd, type  ->  siguen funcionando... ¿por qué?"
echo
echo "TU MISIÓN"
echo "  1. Explicá por qué cd, echo y pwd siguen andando aunque el"
echo "     PATH esté roto (pista: type cd, type cat)."
echo "  2. Desde la shell rota, recuperá un PATH funcional para la"
echo "     sesión actual usando solo builtins y rutas absolutas."
echo "  3. Hacé el arreglo PERMANENTE: eliminá el bloque LAB-2.1-BREAK"
echo "     de ~/.bashrc (o restaurá el backup) y verificá que una"
echo "     terminal nueva funcione bien."
echo "  4. Cuando todo funcione, borrá el archivo marcador:"
echo "     rm ~/.lab_2_1_roto"
echo
echo "  Backup de seguridad: $BACKUP"
echo "  Comandos que te van a servir: type, echo \$PATH, export,"
echo "  unalias, alias, y las rutas absolutas como /usr/bin/ls"
echo
echo "¡Suerte! La solución completa está comentada al final de este"
echo "script: $0"
exit 0

# ============================================================================
#  SOLUCIÓN PASO A PASO (no leer hasta haberlo intentado)
# ============================================================================
#
#  PASO 0 — Entender el síntoma
#  ----------------------------
#  El shell busca los comandos externos recorriendo, en orden, los
#  directorios listados en la variable PATH. Al reemplazar PATH por un
#  directorio inexistente, bash ya no encuentra binarios como /usr/bin/cat
#  y responde "command not found".
#
#  Los builtins (cd, echo, pwd, export, type, unalias...) NO son archivos
#  en disco: están integrados en el propio bash, por eso siguen funcionando
#  aunque el PATH esté roto. Podés comprobarlo así:
#
#      type cd        # -> "cd is a shell builtin"
#      type cat       # -> "not found" (¡porque depende del PATH!)
#      type ls        # -> "ls is aliased to ..." (el alias enmascara al binario)
#
#  PASO 1 — Diagnóstico desde la shell rota
#  ----------------------------------------
#      echo $PATH
#      # Muestra: /opt/herramientas_inexistentes
#      # Ahí está el problema: PATH fue reemplazado, no ampliado.
#
#      alias
#      # Muestra el alias que enmascara a ls.
#
#  PASO 2 — Arreglo temporal (solo para la sesión actual)
#  -------------------------------------------------------
#      export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
#      unalias ls
#
#      # Verificación:
#      type ls        # -> /usr/bin/ls (o /bin/ls según la distro)
#      ls             # -> vuelve a listar archivos
#
#  Nota: mientras el PATH estaba roto también podías invocar cualquier
#  comando por su ruta absoluta, p. ej.:  /usr/bin/ls  o  /bin/cat
#
#  PASO 3 — Arreglo permanente
#  ---------------------------
#  Opción A (recomendada — editar y entender):
#      nano ~/.bashrc
#      # Borrá todo el bloque entre las líneas:
#      #   # >>> LAB-2.1-BREAK (inicio) ...
#      #   # <<< LAB-2.1-BREAK (fin)
#      # Guardá y salí.
#
#  Opción B (restaurar el backup):
#      cp ~/.bashrc.backup-lab-2.1 ~/.bashrc
#
#  PASO 4 — Verificación final y limpieza
#  --------------------------------------
#      # Abrí una terminal NUEVA (para que se relea ~/.bashrc) y probá:
#      echo $PATH     # -> PATH normal con /usr/bin, /bin, etc.
#      type ls        # -> ya no es un alias
#      ls; cat /etc/hostname   # -> funcionan
#
#      # Marcá el laboratorio como resuelto:
#      rm ~/.lab_2_1_roto
#      rm ~/.bashrc.backup-lab-2.1   # opcional, cuando estés seguro
#
#  LECCIÓN CLAVE
#  -------------
#  Para AGREGAR un directorio al PATH sin romper nada, siempre hay que
#  conservar el valor anterior:
#
#      export PATH="$PATH:/opt/mis_herramientas"     # correcto
#      export PATH="/opt/mis_herramientas"           # ¡reemplaza todo! (el bug)
#
#  Y ante un "command not found" sospechoso, los builtins type y echo
#  son tus mejores aliados de diagnóstico, porque no dependen del PATH.
#
#  Referencia: https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
# ============================================================================