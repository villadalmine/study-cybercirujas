#!/usr/bin/env bash
#
# CKS 1.34 - Dominio 6.2: Detect threats within physical infrastructure,
# apps, networks, data, users and workloads
#
# Break & Fix: Falco (el runtime threat detection engine de facto en CKS)
# sigue "corriendo" con normalidad, pero alguien deshabilitó en silencio
# dos reglas default que cubren justamente "apps/workloads" (shell
# interactiva dentro de un contenedor) y "data" (lectura de archivos
# sensibles por un proceso no confiable). El servicio no se cae: la falla
# es un blind spot de detección, que es el escenario más realista y
# peligroso de este dominio.
#
# Uso:
#   sudo ./break_fix_cks_6_2.sh           -> rompe el entorno
#   sudo ./break_fix_cks_6_2.sh --reset   -> restaura el estado original
#
# Requiere: VM descartable con docker corriendo (y, si es posible, Falco
# ya instalado como parte de la imagen base del laboratorio).
#
# Fuente de referencia (curricula, no reglas ni texto literal de terceros):
# https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf

set -euo pipefail

FALCO_LOCAL_RULES="/etc/falco/falco_rules.local.yaml"
BACKUP_FILE="/etc/falco/falco_rules.local.yaml.orig-break-fix"
TARGET_CONTAINER="cks-6-2-target"

log()  { printf '\n[break-fix] %s\n' "$1"; }
die()  { printf '\n[break-fix][ERROR] %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Corré este script como root (sudo)."

if [ "${1:-}" = "--reset" ]; then
  log "Restaurando estado original..."
  if [ -f "$BACKUP_FILE" ]; then
    mv "$BACKUP_FILE" "$FALCO_LOCAL_RULES"
  else
    : > "$FALCO_LOCAL_RULES"
  fi
  docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
  systemctl restart falco 2>/dev/null || true
  log "Listo. Falco vuelve a tener sus reglas default activas."
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "Necesitás docker instalado (es el runtime que Falco va a instrumentar)."
systemctl is-active --quiet docker || die "El servicio docker no está activo. Arrancalo antes de correr este script."

if ! command -v falco >/dev/null 2>&1; then
  log "Falco no está instalado. Intentando instalar con el script oficial (falco.org)..."
  log "Si tu imagen base de laboratorio no trae Falco preinstalado y esto se queda"
  log "esperando una elección interactiva de driver, instalalo manualmente siguiendo"
  log "https://falco.org/docs/getting-started/installation/ y volvé a correr el script."
  curl -s https://falco.org/script/install | bash
fi

systemctl enable falco >/dev/null 2>&1 || true
systemctl start falco >/dev/null 2>&1 || true
sleep 3
systemctl is-active --quiet falco || die "Falco no pudo arrancar. Revisá 'journalctl -u falco' antes de continuar; el script no puede romper algo que no está sano."

log "Levantando un contenedor de prueba para que puedas simular actividad sospechosa..."
docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$TARGET_CONTAINER" alpine:3 sleep 3600 >/dev/null

[ -f "$FALCO_LOCAL_RULES" ] || touch "$FALCO_LOCAL_RULES"
cp "$FALCO_LOCAL_RULES" "$BACKUP_FILE"

log "Rompiendo la detección: deshabilitando reglas default en $FALCO_LOCAL_RULES ..."
cat >> "$FALCO_LOCAL_RULES" <<'EOF'

# --- override aplicado fuera de horario, sin ticket asociado ---
- rule: Terminal shell in container
  enabled: false

- rule: Read sensitive file untrusted
  enabled: false
EOF

systemctl restart falco
sleep 3

if ! systemctl is-active --quiet falco; then
  log "Falco no arrancó con el override aplicado, revirtiendo para dejar la VM en estado seguro..."
  mv "$BACKUP_FILE" "$FALCO_LOCAL_RULES"
  systemctl restart falco
  die "El override rompía la sintaxis de Falco. Se revirtió automáticamente, volvé a correr el script."
fi

cat <<'EOF'

============================================================
SÍNTOMA QUE VAS A VER
============================================================
Falco está activo (systemctl status falco te va a mostrar "active
(running)"), así que a simple vista todo parece sano. Pero si generás
alguna de estas dos actividades, que Falco detecta out-of-the-box:

  1) Una shell interactiva dentro de un contenedor:
       docker exec -it cks-6-2-target sh

  2) Un proceso no confiable leyendo un archivo sensible dentro de un
     contenedor:
       docker exec cks-6-2-target sh -c 'cat /etc/shadow'

...no vas a ver NINGUNA alerta correspondiente en los logs de Falco:

       journalctl -u falco -f
       # o, según instalación:
       tail -f /var/log/falco/falco.log 2>/dev/null

============================================================
QUÉ TENÉS QUE LOGRAR
============================================================
Encontrar por qué Falco dejó de generar esas dos alertas puntuales sin
haberse caído el servicio, y restaurar la detección SIN reinstalar Falco
desde cero. Al terminar, repetir los dos comandos de arriba tiene que
producir alertas visibles de "Terminal shell in container" y
"Read sensitive file untrusted" en los logs de Falco.

Pistas de método (no la solución):
  - falco --validate /etc/falco/falco.yaml
  - Revisá qué archivos carga la directiva rules_file en /etc/falco/falco.yaml
  - Una regla puede seguir "cargada" y sin embargo no disparar si algún
    rules_file posterior la sobreescribió con enabled: false.

Para deshacer todo el laboratorio: sudo ./break_fix_cks_6_2.sh --reset
============================================================
EOF

exit 0

# ============================================================
# SOLUCIÓN PASO A PASO
# ============================================================
#
# 1) Confirmar que Falco está vivo pero mudo para esos dos eventos:
#      systemctl status falco
#      journalctl -u falco -f &
#      docker exec -it cks-6-2-target sh -c 'echo hola'   # no genera alerta
#
# 2) Falco carga varios archivos de reglas en orden, definido en
#    /etc/falco/falco.yaml bajo la clave rules_file (típicamente:
#    falco_rules.yaml, falco_rules.local.yaml, rules.d/*). Un archivo
#    cargado más tarde puede sobreescribir campos de una regla ya
#    definida repitiendo su nombre exacto:
#      grep -A5 '^rules_file' /etc/falco/falco.yaml
#
# 3) Inspeccionar el archivo local de overrides, que es justamente el
#    lugar pensado para customización y por eso el más probable para que
#    alguien "esconda" un cambio así:
#      cat /etc/falco/falco_rules.local.yaml
#
#    Se va a ver algo como:
#      - rule: Terminal shell in container
#        enabled: false
#      - rule: Read sensitive file untrusted
#        enabled: false
#
# 4) Arreglar el override. Dos formas válidas:
#    a) Borrar directamente esas líneas del archivo local, dejándolo
#       vacío/comentado como viene por default.
#    b) Reescribir el override en positivo (deja rastro de auditoría
#       explícito del cambio):
#         - rule: Terminal shell in container
#           enabled: true
#         - rule: Read sensitive file untrusted
#           enabled: true
#
# 5) Validar la sintaxis antes de reiniciar:
#      falco --validate /etc/falco/falco.yaml
#
# 6) Reiniciar el servicio y confirmar que sigue activo:
#      systemctl restart falco
#      systemctl is-active falco
#
# 7) Re-disparar los dos eventos y confirmar que ahora sí aparecen en el
#    log:
#      docker exec -it cks-6-2-target sh
#      docker exec cks-6-2-target sh -c 'cat /etc/shadow'
#      journalctl -u falco -n 50 --no-pager | grep -i falco
#
#    Deberías ver dos alertas con rule="Terminal shell in container" y
#    rule="Read sensitive file untrusted", cada una referenciando el
#    container_id de cks-6-2-target en el output.
#
# 8) (Alternativa igual de válida) restaurar el backup que este mismo
#    script hace al arrancar:
#      mv /etc/falco/falco_rules.local.yaml.orig-break-fix \
#         /etc/falco/falco_rules.local.yaml
#      systemctl restart falco
# ============================================================