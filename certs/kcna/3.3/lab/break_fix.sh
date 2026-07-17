#!/usr/bin/env bash
#
# ============================================================================
# KCNA - Dominio 3.3 Containerization (peso: 4)
# Break & Fix: el OCI runtime (runc) desaparece del path que usa el
# container engine para arrancar contenedores.
#
# Fuente de referencia:
#   https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable, nunca en
# un host de producción ni en tu equipo de trabajo. El script mueve un
# binario del sistema relacionado con el container runtime.
# ============================================================================

set -uo pipefail

STATE_FILE="/tmp/.kcna_3_3_break_fix_state"
LAB_TAG="kcna-3.3-containerization"

info()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }
ok()    { printf '\n\033[1;32m[OK]\033[0m %s\n' "$*"; }
fail()  { printf '\n\033[1;31m[FAIL]\033[0m %s\n' "$*"; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Este script necesita privilegios de root (sudo). Abortando."
    exit 1
  fi
}

confirm_disposable_vm() {
  if [[ "${KCNA_LAB_YES:-}" == "1" ]]; then
    return 0
  fi
  warn "Este script rompe algo a propósito en el motor de contenedores de esta máquina."
  warn "Usalo SOLO en una VM de laboratorio descartable (nunca en producción)."
  read -r -p "¿Confirmás que esta es una VM descartable y querés continuar? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) info "Cancelado por el usuario."; exit 0 ;;
  esac
}

detect_container_engine() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "No se encontró 'docker' en el PATH. Instalalo antes de correr este lab (ej: en Debian/Ubuntu: apt-get install -y docker.io)."
    exit 1
  fi
}

find_runc() {
  local candidates=(
    "$(command -v runc 2>/dev/null || true)"
    /usr/bin/runc
    /usr/sbin/runc
    /usr/local/bin/runc
    /usr/lib/docker/runc
  )
  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

break_it() {
  require_root
  confirm_disposable_vm
  detect_container_engine

  if [[ -f "$STATE_FILE" ]]; then
    warn "Ya hay un lab '$LAB_TAG' roto pendiente (según $STATE_FILE)."
    warn "Arreglalo o corré '$0 reset' antes de romper algo nuevo."
    exit 1
  fi

  local runc_path
  if ! runc_path="$(find_runc)"; then
    fail "No se encontró el binario de runc en este sistema. No se puede armar este lab."
    exit 1
  fi

  local disabled_path="${runc_path}.disabled-by-${LAB_TAG}"

  info "Confirmando que el container engine funciona ANTES de romper nada..."
  if ! docker run --rm hello-world >/tmp/.kcna_3_3_pre_check.log 2>&1; then
    fail "docker run hello-world ya falla antes de tocar nada. Revisá el entorno de la VM primero."
    exit 1
  fi
  ok "El engine funciona correctamente. Procediendo a romper el lab."

  mv "$runc_path" "$disabled_path"
  echo "${runc_path}|${disabled_path}" > "$STATE_FILE"

  ok "Lab armado."
  cat <<'EOF'

--------------------------------------------------------------------------
SÍNTOMA QUE VAS A VER
--------------------------------------------------------------------------
Corré:

    docker run --rm hello-world

Vas a ver un error parecido a:

    docker: Error response from daemon: failed to create task for container:
    failed to create shim task: OCI runtime create failed: runc: runc not
    installed: unknown.

El contenedor NO arranca, aunque el daemon (dockerd/containerd) está corriendo
sin problemas y la imagen se descarga bien.

--------------------------------------------------------------------------
TU OBJETIVO
--------------------------------------------------------------------------
Diagnosticar por qué el container engine puede descargar la imagen pero no
puede arrancar el contenedor, entendiendo la diferencia entre:

  - El "high-level container runtime" (dockerd / containerd): gestiona
    imágenes, redes y ciclo de vida de los contenedores.
  - El "low-level" u OCI runtime (runc): el proceso que realmente crea el
    contenedor usando namespaces y cgroups del kernel, siguiendo el
    OCI Runtime Spec.

Arreglá el problema para que este comando vuelva a funcionar:

    docker run --rm hello-world

Pista: no reinstales Docker entero. El daemon está sano; falta una pieza
puntual de la cadena container engine -> containerd-shim -> OCI runtime.

Cuando creas que lo arreglaste, verificá con:

    ./break-fix-3.3-containerization.sh check
--------------------------------------------------------------------------
EOF
}

check_fix() {
  detect_container_engine
  info "Verificando si el lab está resuelto..."
  if docker run --rm hello-world >/tmp/.kcna_3_3_check.log 2>&1; then
    ok "'docker run hello-world' funciona. ¡Resolviste el lab!"
    rm -f "$STATE_FILE"
    exit 0
  else
    fail "Todavía falla. Revisá /tmp/.kcna_3_3_check.log para el detalle del error."
    exit 1
  fi
}

reset_lab() {
  require_root
  if [[ ! -f "$STATE_FILE" ]]; then
    info "No hay ningún lab '$LAB_TAG' pendiente de reset."
    exit 0
  fi
  IFS='|' read -r orig disabled < "$STATE_FILE"
  if [[ -f "$disabled" ]]; then
    mv "$disabled" "$orig"
    ok "runc restaurado en $orig."
  else
    warn "No se encontró el binario respaldado en $disabled. Restauralo manualmente."
  fi
  rm -f "$STATE_FILE"
}

usage() {
  cat <<EOF
Uso: $0 {break|check|reset}

  break   Rompe el lab (mueve el binario de runc para que docker run falle).
  check   Verifica si ya arreglaste el problema.
  reset   Vuelve todo al estado original sin resolver el ejercicio
          (usalo para abandonar el lab, no para "hacer trampa").
EOF
}

case "${1:-}" in
  break) break_it ;;
  check) check_fix ;;
  reset) reset_lab ;;
  *) usage; exit 1 ;;
esac

# ============================================================================
# SOLUCIÓN (spoiler) - paso a paso
# ============================================================================
#
# 1. Diagnóstico:
#      docker run --rm hello-world
#    El daemon responde y llega hasta "failed to create shim task: OCI
#    runtime create failed: runc: runc not installed". Eso indica que
#    containerd encontró la imagen y armó el "shim", pero no pudo invocar
#    al OCI runtime (runc) para crear el contenedor real (namespaces +
#    cgroups).
#
# 2. Confirmar que el daemon en sí está sano:
#      systemctl status docker
#      docker info
#    (el daemon arranca bien; el problema es específico de runc, no del
#    engine completo)
#
# 3. Confirmar que runc no está donde se lo espera:
#      command -v runc          # no devuelve nada
#      ls /usr/bin/runc*        # aparece "runc.disabled-by-kcna-3.3-containerization"
#
# 4. Arreglo (sin reinstalar Docker entero):
#      sudo mv /usr/bin/runc.disabled-by-kcna-3.3-containerization /usr/bin/runc
#      sudo chmod +x /usr/bin/runc
#
#    (En un caso real, si el binario se hubiese perdido de verdad, la
#    alternativa es reinstalar el paquete que lo provee, por ejemplo:
#      sudo apt-get install --reinstall runc
#    o el paquete containerd.io, según la distro.)
#
# 5. Verificar:
#      docker run --rm hello-world
#    Debería completar OK, mostrando el mensaje "Hello from Docker!".
#
# 6. Concepto clave para el examen (dominio 3.3 Containerization):
#    un container engine como Docker no crea contenedores por sí mismo:
#    delega en un OCI runtime (runc por defecto, aunque también existen
#    gVisor, Kata Containers, crun, etc.) que es quien efectivamente usa
#    namespaces y cgroups del kernel de Linux para aislar procesos,
#    siguiendo el OCI Runtime Specification. containerd actúa como
#    intermediario ("high-level runtime") entre el CLI/daemon y ese
#    OCI runtime.
# ============================================================================