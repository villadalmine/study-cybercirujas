#!/usr/bin/env bash
#
# =============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160, v1.6)
#  Tema 4.4: Your Computer on the Network (peso: 2)
#
#  Escenario: "El servidor conoce las IPs, pero no los nombres"
#
#  Referencia de estudio:
#    https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
#
#  ADVERTENCIA: ejecutar SOLO en una VM de laboratorio DESCARTABLE.
#  El script rompe la resolución de nombres (DNS) de forma controlada.
#  NO lo corras en tu máquina real ni en un servidor de producción.
# =============================================================================

set -u

BACKUP_DIR="/root/lab-4.4-backup"

# --------------------------------------------------------------------------
# 0. Verificaciones previas
# --------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: este script debe ejecutarse como root (usá: sudo $0)" >&2
    exit 1
fi

if [ -d "$BACKUP_DIR" ]; then
    echo "ERROR: ya existe $BACKUP_DIR — parece que el lab ya fue ejecutado." >&2
    echo "Si querés reiniciar el lab, restaurá primero los archivos y borrá ese directorio." >&2
    exit 1
fi

echo
echo "Este lab va a modificar la configuración de red de esta VM."
read -r -p "¿Confirmás que esto es una VM de laboratorio descartable? (escribí SI): " CONFIRM
if [ "$CONFIRM" != "SI" ]; then
    echo "Abortado. No se modificó nada."
    exit 0
fi

# --------------------------------------------------------------------------
# 1. Backup de seguridad (por si el estudiante queda trabado)
# --------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null
cp -a /etc/hosts       "$BACKUP_DIR/hosts.bak"
echo "[ok] Backups guardados en $BACKUP_DIR (para emergencias, no para hacer trampa ;-) )"

# --------------------------------------------------------------------------
# 2. LA ROTURA (controlada y reversible)
# --------------------------------------------------------------------------
# Rotura A: apuntamos el resolver a un name server inexistente.
# 192.0.2.0/24 es un rango reservado para documentación (TEST-NET-1),
# así que garantizamos que NUNCA va a responder consultas DNS.
#
# Si el sistema usa systemd-resolved u otro gestor, forzamos un archivo
# plano para que la rotura sea determinística.
if [ -L /etc/resolv.conf ]; then
    readlink /etc/resolv.conf > "$BACKUP_DIR/resolv.conf.symlink-target"
    rm -f /etc/resolv.conf
fi
cat > /etc/resolv.conf <<'EOF'
# Configurado por el equipo de redes (¿o no?)
nameserver 192.0.2.53
EOF

# Rotura B: envenenamos /etc/hosts con una entrada falsa para que el
# estudiante descubra el orden de resolución (files -> dns, ver nsswitch.conf)
echo "192.0.2.80    www.ejemplo-lab.com intranet.ejemplo-lab.com" >> /etc/hosts

echo "[ok] Rotura aplicada."

# --------------------------------------------------------------------------
# 3. Briefing para el estudiante
# --------------------------------------------------------------------------
cat <<'BRIEFING'

=============================================================================
 SITUACIÓN
=============================================================================
Sos el nuevo sysadmin junior. Los usuarios reportan: "no anda internet".
Pero un compañero te jura que la red física está bien.

SÍNTOMAS QUE VAS A VER:
  * ping 8.8.8.8            -> FUNCIONA (hay conectividad IP y routing)
  * ping www.lpi.org        -> FALLA: "Temporary failure in name resolution"
  * host www.lpi.org        -> FALLA: "connection timed out; no servers
                                could be reached"
  * getent hosts intranet.ejemplo-lab.com -> devuelve una IP sospechosa
                                             (192.0.2.80) que no responde

DIAGNÓSTICO SUGERIDO (herramientas del examen 010-160):
  * ip addr / ip route      -> ¿tengo IP y default gateway? (spoiler: sí)
  * ping <IP> vs ping <nombre> -> aísla el problema: ¿es de red o de DNS?
  * cat /etc/resolv.conf    -> ¿a qué name server le estoy preguntando?
  * cat /etc/hosts          -> ¿hay entradas locales que pisan al DNS?
  * host / dig <nombre>     -> probá también contra un server explícito:
                               host www.lpi.org 9.9.9.9

OBJETIVO PARA APROBAR EL LAB:
  1. ping -c 2 www.lpi.org           -> responde
  2. host www.lpi.org                -> resuelve a una IP real
  3. getent hosts www.ejemplo-lab.com -> NO devuelve 192.0.2.80

PISTA CONCEPTUAL:
  La resolución de nombres tiene DOS capas: los archivos locales
  (/etc/hosts) y el servicio DNS (/etc/resolv.conf). El orden lo define
  /etc/nsswitch.conf (línea "hosts:"). Acá están rotas LAS DOS capas.

Cuando lo arregles, verificá con los tres comandos del objetivo.
¡Éxitos! (La solución está comentada al final de este script: $0)
=============================================================================
BRIEFING

exit 0

# =============================================================================
#  SOLUCIÓN PASO A PASO (no leer hasta haberlo intentado)
# =============================================================================
#
# PASO 1 — Aislar el problema (red vs. nombres):
#     ping -c 2 8.8.8.8          # responde -> IP, interfaz y routing OK
#     ping -c 2 www.lpi.org      # falla    -> el problema es de name resolution
#     ip addr; ip route          # confirman IP asignada y default gateway
#
# PASO 2 — Revisar el resolver DNS:
#     cat /etc/resolv.conf
#     # Vas a ver: nameserver 192.0.2.53
#     # 192.0.2.x es un rango de documentación (TEST-NET-1): ese server no existe.
#
#     Probá que el DNS en general sí funciona usando un server público:
#     host www.lpi.org 9.9.9.9   # o dig @1.1.1.1 www.lpi.org
#
# PASO 3 — Corregir /etc/resolv.conf con un name server válido:
#     Opción rápida (editar el archivo):
#         echo "nameserver 9.9.9.9" > /etc/resolv.conf
#         # (podés usar 1.1.1.1, 8.8.8.8 o el DNS de tu red/gateway)
#     Opción "prolija" si el sistema usaba systemd-resolved:
#         cat /root/lab-4.4-backup/resolv.conf.symlink-target  # ver destino original
#         ln -sf <ese-destino> /etc/resolv.conf
#         systemctl restart systemd-resolved
#
# PASO 4 — Limpiar la entrada falsa de /etc/hosts:
#     grep 192.0.2.80 /etc/hosts
#     # Borrá esa línea con tu editor, o con:
#         sed -i '/192\.0\.2\.80/d' /etc/hosts
#     # Recordá: por el orden "hosts: files dns" de /etc/nsswitch.conf,
#     # una entrada en /etc/hosts le GANA al DNS, por eso hay que sacarla.
#
# PASO 5 — Verificar los objetivos:
#     ping -c 2 www.lpi.org                 # responde
#     host www.lpi.org                      # resuelve a una IP real
#     getent hosts www.ejemplo-lab.com      # ya no devuelve 192.0.2.80
#
# RESTAURACIÓN DE EMERGENCIA (si quedaste trabado):
#     cp -a /root/lab-4.4-backup/hosts.bak /etc/hosts
#     cp -a /root/lab-4.4-backup/resolv.conf.bak /etc/resolv.conf
#     rm -rf /root/lab-4.4-backup
#
# CONCEPTOS DEL EXAMEN QUE PRACTICASTE (tema 4.4):
#   - Diferenciar fallas de conectividad IP vs. fallas de DNS
#   - ip addr, ip route, ping, host, dig, getent
#   - /etc/resolv.conf, /etc/hosts, /etc/nsswitch.conf y su orden de consulta
#   Fuente de referencia:
#   https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
# =============================================================================