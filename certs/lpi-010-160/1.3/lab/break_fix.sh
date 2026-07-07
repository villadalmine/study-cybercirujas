#!/usr/bin/env bash
#
# ============================================================================
#  lab-1.3-licencias-break-fix.sh
#  Certificación : LPI Linux Essentials (examen 010-160, versión 1.6)
#  Tema          : 1.3 Open Source Software and Licensing (peso: 1)
#  Referencia    : https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
#
#  ⚠️  USAR SOLO EN UNA VM DE LABORATORIO DESCARTABLE.
#      El script modifica archivos de documentación de licencias del sistema.
#      No toca binarios, servicios ni datos de usuario, pero no lo ejecutes
#      en una máquina de producción.
#
#  USO:
#     sudo ./lab-1.3-licencias-break-fix.sh              # rompe el sistema (arma el lab)
#     sudo ./lab-1.3-licencias-break-fix.sh --verificar  # comprueba si lo arreglaste
#     sudo ./lab-1.3-licencias-break-fix.sh --restaurar  # botón de pánico: deshace todo
# ============================================================================

set -u

BACKUP_DIR="/root/.lab13_backup"
MARCA_FAKE="LICENCIA PROPIETARIA MEGACORP - TODOS LOS DERECHOS RESERVADOS"

# --- Detección de la familia de distribución --------------------------------
# En Debian/Ubuntu las licencias comunes viven en /usr/share/common-licenses
# (pertenecen al paquete "base-files"). En Fedora/RHEL cada paquete instala
# la suya en /usr/share/licenses/<paquete>/.
if [ -f /usr/share/common-licenses/GPL-3 ] || [ -f "$BACKUP_DIR/GPL-3" ]; then
    FAMILIA="debian"
    OBJETIVO="/usr/share/common-licenses/GPL-3"
    PAQUETE="base-files"
elif [ -f /usr/share/licenses/coreutils/COPYING ] || [ -f "$BACKUP_DIR/COPYING" ]; then
    FAMILIA="rhel"
    OBJETIVO="/usr/share/licenses/coreutils/COPYING"
    PAQUETE="coreutils"
else
    echo "ERROR: no encuentro un archivo de licencia conocido para usar en el lab."
    echo "Este script soporta distribuciones tipo Debian/Ubuntu y Fedora/RHEL."
    exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "ERROR: ejecutá este script con sudo o como root."; exit 1; }

verificar() {
    echo "== Verificando el arreglo =="
    if [ ! -f "$OBJETIVO" ]; then
        echo "❌ Todavía no existe $OBJETIVO"
        exit 1
    fi
    if grep -q "$MARCA_FAKE" "$OBJETIVO"; then
        echo "❌ El archivo existe pero sigue conteniendo la licencia FALSA."
        echo "   Tenés que recuperar el texto genuino de la GPL, no alcanza con que el archivo exista."
        exit 1
    fi
    if grep -qi "GNU GENERAL PUBLIC LICENSE" "$OBJETIVO"; then
        echo "✅ ¡Correcto! $OBJETIVO vuelve a contener el texto genuino de la GNU GPL."
        echo "   Podés borrar el backup del lab: rm -rf $BACKUP_DIR"
        exit 0
    fi
    echo "❌ El archivo existe pero su contenido no parece ser la GPL. Revisá qué restauraste."
    exit 1
}

restaurar() {
    echo "== Restauración de emergencia =="
    if [ -f "$BACKUP_DIR/$(basename "$OBJETIVO")" ]; then
        cp -a "$BACKUP_DIR/$(basename "$OBJETIVO")" "$OBJETIVO"
        echo "Archivo original restaurado desde $BACKUP_DIR."
    else
        echo "No hay backup local; reinstalando el paquete dueño ($PAQUETE)..."
        if [ "$FAMILIA" = "debian" ]; then
            apt-get install --reinstall -y "$PAQUETE"
        else
            dnf reinstall -y "$PAQUETE"
        fi
    fi
    verificar
}

case "${1:-}" in
    --verificar) verificar ;;
    --restaurar) restaurar ;;
esac

# --- ROMPER (armar el escenario) --------------------------------------------
if grep -q "$MARCA_FAKE" "$OBJETIVO" 2>/dev/null; then
    echo "El lab ya está armado. Corré '$0 --verificar' cuando creas haberlo arreglado."
    exit 0
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
cp -a "$OBJETIVO" "$BACKUP_DIR/"

cat > "$OBJETIVO" <<EOF
$MARCA_FAKE

Este software es propiedad exclusiva de MegaCorp Inc. Queda prohibido
estudiar, modificar, copiar o redistribuir este programa. El acceso al
código fuente no está permitido bajo ninguna circunstancia.

(Si estás leyendo esto en el lab: este texto es FALSO y fue plantado
a propósito. Contradice las cuatro libertades del software libre.)
EOF

cat <<EOF

############################################################################
#                 🧪 LAB 1.3 — BREAK & FIX: LICENCIAS                      #
############################################################################

📖 CONTEXTO
   Un "administrador anterior" de esta VM reemplazó el texto oficial de la
   GNU GPL que viene con el sistema por una licencia propietaria falsa.
   En un sistema real esto sería gravísimo: la documentación de licencias
   que distribuye tu sistema es parte del cumplimiento legal (compliance)
   de cada paquete.

🔍 SÍNTOMA QUE VAS A VER
   Ejecutá:
       cat $OBJETIVO
   En lugar del texto de la "GNU GENERAL PUBLIC LICENSE", vas a ver una
   "licencia propietaria" de MegaCorp que prohíbe estudiar, modificar y
   redistribuir el software. Eso viola las cuatro libertades que define
   la Free Software Foundation (FSF), así que algo anda muy mal.

🎯 TU MISIÓN
   1. Confirmá el síntoma leyendo el archivo.
   2. Averiguá QUÉ PAQUETE es el dueño legítimo de ese archivo
      (pista Debian/Ubuntu: dpkg -S <ruta> | pista Fedora/RHEL: rpm -qf <ruta>).
   3. Recuperá el texto GENUINO de la licencia usando el gestor de paquetes.
   4. Validá tu arreglo con:
          sudo $0 --verificar

🧠 MIENTRAS TRABAJÁS, PENSÁ (conceptos del examen 010-160):
   - ¿Cuáles son las 4 libertades del software libre según la FSF?
   - ¿Qué diferencia hay entre una licencia copyleft (GPL) y una
     permisiva (BSD, MIT, Apache)? ¿Cuál te obliga a liberar tus
     modificaciones bajo la misma licencia?
   - ¿Qué organización mantiene la Open Source Definition? (OSI)
   - ¿Qué familia de licencias usarías para una obra que NO es software,
     como un manual o una foto? (Creative Commons)

   Repasá el material oficial:
   https://learning.lpi.org/en/learning-materials/010-160/1/1.3/

🆘 Si te trabás del todo: sudo $0 --restaurar
############################################################################
EOF

exit 0

# ============================================================================
#                        SOLUCIÓN PASO A PASO (SPOILERS)
# ============================================================================
#
# Paso 1 — Confirmar el síntoma:
#
#     cat /usr/share/common-licenses/GPL-3        # Debian/Ubuntu
#     cat /usr/share/licenses/coreutils/COPYING   # Fedora/RHEL
#
#     Vas a ver la licencia propietaria falsa de "MegaCorp".
#
# Paso 2 — Identificar el paquete dueño del archivo:
#
#     En Debian/Ubuntu:
#         dpkg -S /usr/share/common-licenses/GPL-3
#         # → base-files: /usr/share/common-licenses/GPL-3
#
#     En Fedora/RHEL:
#         rpm -qf /usr/share/licenses/coreutils/COPYING
#         # → coreutils-<versión>
#
#     Lección: TODO archivo de licencia instalado pertenece a un paquete,
#     y el gestor de paquetes sabe cuál es.
#
# Paso 3 — (Opcional) Comprobar que el archivo fue alterado:
#
#     En Fedora/RHEL, rpm puede verificar la integridad contra la base de datos:
#         rpm -V coreutils
#         # La "5" en la salida indica que el checksum MD5 del archivo cambió.
#
#     En Debian/Ubuntu:
#         dpkg --verify base-files
#
# Paso 4 — Restaurar el archivo genuino reinstalando el paquete:
#
#     En Debian/Ubuntu:
#         sudo apt-get install --reinstall base-files
#
#     En Fedora/RHEL:
#         sudo dnf reinstall -y coreutils
#
#     Alternativa manual: el propio lab guardó una copia en
#     /root/.lab13_backup/ — copiarla de vuelta también sirve:
#         sudo cp -a /root/.lab13_backup/GPL-3 /usr/share/common-licenses/GPL-3
#
# Paso 5 — Verificar:
#
#     cat <ruta> | head          # debería mostrar "GNU GENERAL PUBLIC LICENSE"
#     sudo ./lab-1.3-licencias-break-fix.sh --verificar
#
# Respuestas a las preguntas de repaso:
#
#   * Las 4 libertades (FSF): (0) usar el programa con cualquier propósito,
#     (1) estudiar cómo funciona y adaptarlo, (2) redistribuir copias,
#     (3) mejorar el programa y publicar las mejoras. Las libertades 1 y 3
#     requieren acceso al código fuente.
#   * Copyleft (GPL): las obras derivadas deben distribuirse bajo la misma
#     licencia. Permisivas (MIT, BSD, Apache): permiten reutilizar el código
#     incluso en software propietario, con mínimas condiciones (p. ej.,
#     conservar el aviso de copyright).
#   * La Open Source Definition la mantiene la Open Source Initiative (OSI),
#     que además aprueba qué licencias califican como "open source".
#   * Para obras que no son software (textos, imágenes, música) se usan las
#     licencias Creative Commons (CC BY, CC BY-SA, CC0, etc.).
#
# Fuente de referencia del tema:
#   https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
# ============================================================================