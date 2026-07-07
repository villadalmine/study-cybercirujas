#!/usr/bin/env bash
#
# =============================================================================
#  LAB BREAK & FIX — LPI Linux Essentials (010-160 v1.6)
#  Tema 1.2: Major Open Source Applications (peso: 2)
#
#  Escenario: el web server Apache HTTP Server, una de las aplicaciones
#  open source más importantes que cubre este tema, deja de funcionar
#  por un error de configuración. Tu misión es diagnosticarlo y repararlo.
#
#  Referencia de estudio:
#    https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable.
#  El script modifica la configuración de Apache y detiene el servicio.
#  Requiere: root (sudo), y Apache instalado (apache2 en Debian/Ubuntu
#  o httpd en RHEL/Fedora/CentOS). Si no está instalado, lo instala.
# =============================================================================

set -u

# --- Verificaciones de seguridad ---------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse como root (usá: sudo $0)" >&2
    exit 1
fi

if [[ ! -f /etc/lab_vm_ok ]]; then
    echo "=============================================================="
    echo " PROTECCIÓN: este script rompe cosas a propósito."
    echo " Confirmá que esta es una VM descartable de laboratorio creando"
    echo " el archivo testigo:"
    echo ""
    echo "     sudo touch /etc/lab_vm_ok"
    echo ""
    echo " y volvé a ejecutar el script."
    echo "=============================================================="
    exit 1
fi

# --- Detección de la distribución y del paquete de Apache ---------------------

if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    APACHE_SVC="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    APACHE_SVC="httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    APACHE_SVC="httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
else
    echo "ERROR: no se detectó apt, dnf ni yum. Distribución no soportada." >&2
    exit 1
fi

# --- Instalación de Apache si hace falta --------------------------------------

if ! command -v "$APACHE_SVC" >/dev/null 2>&1 && [[ ! -f "$APACHE_CONF" ]]; then
    echo "[*] Apache no está instalado. Instalando ($APACHE_SVC)..."
    case "$PKG_MGR" in
        apt) apt-get update -qq && apt-get install -y -qq apache2 ;;
        dnf) dnf install -y -q httpd ;;
        yum) yum install -y -q httpd ;;
    esac
    if [[ ! -f "$APACHE_CONF" ]]; then
        echo "ERROR: la instalación de Apache falló." >&2
        exit 1
    fi
fi

# --- Estado inicial sano: el servicio debe andar antes de romperlo -------------

echo "[*] Arrancando Apache para verificar el estado inicial sano..."
systemctl start "$APACHE_SVC" 2>/dev/null

if ! systemctl is-active --quiet "$APACHE_SVC"; then
    echo "ERROR: Apache no arranca ni siquiera antes de romperlo." >&2
    echo "Revisá la VM antes de continuar (journalctl -u $APACHE_SVC)." >&2
    exit 1
fi
echo "[OK] Apache está corriendo. Ahora vamos a romperlo de forma controlada."

# --- Backup de seguridad (para poder restaurar si el lab sale mal) -------------

BACKUP="/root/lab-backup-$(basename "$APACHE_CONF").orig"
if [[ ! -f "$BACKUP" ]]; then
    cp -a "$APACHE_CONF" "$BACKUP"
    echo "[*] Backup del archivo original guardado en: $BACKUP"
fi

# --- LA ROTURA -----------------------------------------------------------------
# 1) Insertamos una directiva inválida al principio del archivo de configuración.
# 2) Reiniciamos el servicio, que va a fallar al validar la configuración.

sed -i '1i DirectivaInventadaLab on' "$APACHE_CONF"
systemctl restart "$APACHE_SVC" 2>/dev/null || true

# --- Explicación para el estudiante ---------------------------------------------

cat <<'EOF'

==================================================================
  LAB ROTO CON ÉXITO — AHORA TE TOCA A VOS
==================================================================

CONTEXTO (Tema 1.2 - Major Open Source Applications):
  Apache HTTP Server es el web server open source más conocido y
  uno de los ejemplos clásicos de "server application" del examen
  010-160. Como casi todo el software de servidor en Linux, se
  configura con archivos de texto plano en /etc/.

SÍNTOMA QUE VAS A VER:
  - El servicio web NO está corriendo. Probá:
        systemctl status apache2      (Debian/Ubuntu)
        systemctl status httpd        (RHEL/Fedora/CentOS)
    y vas a ver el estado "failed".
  - Si intentás reiniciarlo:
        sudo systemctl restart apache2   (o httpd)
    el comando falla.
  - Un navegador o "curl http://localhost" no obtiene respuesta
    ("connection refused").

OBJETIVO:
  Lograr que el servicio arranque de nuevo y que
        curl -s http://localhost
  devuelva la página de bienvenida de Apache.

PISTAS (en orden, usá la mínima cantidad posible):
  1. Los servicios registran errores. Mirá los logs:
         sudo journalctl -u apache2 -e     (o -u httpd)
  2. Apache tiene un comando para VALIDAR su configuración sin
     arrancar el servicio:
         sudo apachectl configtest
     Ese comando te dice archivo y NÚMERO DE LÍNEA del problema.
  3. La configuración principal vive en /etc/. Editá el archivo
     indicado con nano o vim, corregí (borrá) la línea inválida,
     y reiniciá el servicio.

REGLA DEL LAB:
  No restaurar el backup ciegamente: la idea es que encuentres la
  línea rota leyendo los mensajes de error, como en la vida real.

¡Éxitos! La solución completa está comentada al final de este
script, pero intentalo primero sin mirarla.
==================================================================

EOF

exit 0

# =============================================================================
#  SOLUCIÓN PASO A PASO (no leer hasta haberlo intentado)
# =============================================================================
#
# Paso 1 — Confirmar el síntoma:
#     sudo systemctl status apache2        # o httpd en RHEL/Fedora
#   Salida esperada: "Active: failed" y un mensaje del tipo
#   "Invalid command 'DirectivaInventadaLab'".
#
# Paso 2 — Leer el log del servicio para entender la causa:
#     sudo journalctl -u apache2 -e        # o -u httpd
#   Ahí aparece el error de sintaxis con el archivo y la línea exacta.
#
# Paso 3 — Validar la configuración (el método profesional):
#     sudo apachectl configtest
#   Salida esperada:
#     AH00526: Syntax error on line 1 of /etc/apache2/apache2.conf:
#     Invalid command 'DirectivaInventadaLab', perhaps misspelled...
#   (En RHEL/Fedora el archivo es /etc/httpd/conf/httpd.conf)
#
# Paso 4 — Corregir el archivo: borrar la línea inválida.
#   Opción con editor:
#     sudo nano /etc/apache2/apache2.conf      # borrar la línea 1 y guardar
#   Opción con sed (borra la línea que contiene la directiva falsa):
#     sudo sed -i '/DirectivaInventadaLab/d' /etc/apache2/apache2.conf
#     # RHEL/Fedora:
#     sudo sed -i '/DirectivaInventadaLab/d' /etc/httpd/conf/httpd.conf
#
# Paso 5 — Volver a validar y reiniciar:
#     sudo apachectl configtest        # debe decir "Syntax OK"
#     sudo systemctl restart apache2   # o httpd
#     sudo systemctl status apache2    # debe decir "active (running)"
#
# Paso 6 — Verificar el objetivo final:
#     curl -s http://localhost | head
#   Debe devolver HTML de la página de bienvenida de Apache.
#
# Restauración de emergencia (solo si el lab quedó inusable):
#     sudo cp /root/lab-backup-apache2.conf.orig /etc/apache2/apache2.conf
#     # RHEL/Fedora:
#     sudo cp /root/lab-backup-httpd.conf.orig /etc/httpd/conf/httpd.conf
#     sudo systemctl restart apache2   # o httpd
#
# QUÉ TE LLEVÁS DE ESTE LAB (conexión con el examen):
#   - Apache HTTP Server como ejemplo central de "server application"
#     open source (Tema 1.2).
#   - Los servicios en Linux se configuran con archivos de texto en /etc/.
#   - Flujo de diagnóstico: systemctl status -> journalctl -> herramienta
#     de validación propia de la aplicación (apachectl configtest).
#
# Fuente de referencia del tema:
#   https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
# =============================================================================