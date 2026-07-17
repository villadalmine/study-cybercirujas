#!/usr/bin/env bash
#
# KCNA — Kubernetes and Cloud Native Associate
# Tema 4.2: Cloud Native Community and Collaboration (peso en el examen: 6)
#
# Fuente de referencia:
#   https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
# Referencia técnica adicional (el mecanismo DCO que este lab simula es
# un estándar real usado por Kubernetes, containerd, Helm y la mayoría
# de los proyectos CNCF para gestionar contribuciones):
#   https://developercertificate.org/
#   https://github.com/cncf/foundation (políticas de gobernanza CNCF)
#
# ADVERTENCIA: este script modifica configuración de git (local Y global)
# y crea archivos bajo $HOME. Ejecutalo SOLO en una VM de laboratorio
# descartable, nunca en tu máquina de trabajo. No requiere red ni
# privilegios de root; todo lo que rompe es reversible con "reset".
#
# Escenario: sos un nuevo contribuyente que quiere mandar un patch al
# proyecto ficticio "cloudnative-widget" (modelado como un proyecto CNCF
# Sandbox). Como todos los proyectos CNCF reales, exige que cada commit
# lleve la firma DCO (Developer Certificate of Origin) en vez de un CLA
# firmado a mano: así la comunidad cloud native gestiona la procedencia
# legal de las contribuciones sin fricción de papeleo. Un git hook local
# (commit-msg) hace de "CI" que valida esto, tal como lo haría el bot de
# DCO check en un PR real de GitHub.
#
# Uso:
#   ./break-fix-4.2.sh          # arma el laboratorio (rompe el entorno)
#   ./break-fix-4.2.sh check    # valida si ya lo arreglaste
#   ./break-fix-4.2.sh reset    # borra el laboratorio y arranca de cero
#
set -euo pipefail

LAB_DIR="${HOME}/kcna-lab-4.2-community"
REPO_DIR="${LAB_DIR}/cloudnative-widget"

confirm_disposable_vm() {
  if [[ "${KCNA_LAB_CONFIRM:-}" != "yes" ]]; then
    cat <<'EOF'
Este script rompe configuración de git de forma intencional (identidad
local y global). Si estás en una VM de laboratorio descartable, volvé a
ejecutar con:

  KCNA_LAB_CONFIRM=yes ./break-fix-4.2.sh

Si NO estás en una VM descartable, cancelá ahora (Ctrl+C).
EOF
    exit 1
  fi
}

setup_repo() {
  mkdir -p "${REPO_DIR}"
  cd "${REPO_DIR}"

  if [[ ! -d .git ]]; then
    git init -q
    git config --local user.name "Cloud Native Widget Bot"
    git config --local user.email "bot@cloudnative-widget.example"

    cat > CONTRIBUTING.md <<'EOF'
# Contributing to cloudnative-widget

Este proyecto sigue las prácticas de gobernanza típicas de un proyecto
CNCF Sandbox: cualquier persona puede abrir un PR, pero todo commit debe
incluir una línea `Signed-off-by` (Developer Certificate of Origin, ver
https://developercertificate.org/) que coincida con la identidad
configurada en git. No se acepta un CLA firmado en PDF: la firma DCO en
el propio commit es la evidencia de procedencia que la comunidad usa
para aceptar contribuciones.

Para firmar un commit: `git commit -s -m "mensaje"`.
EOF

    cat > MAINTAINERS.md <<'EOF'
# Maintainers

- alice (GitHub: @alice-oss) — TOC liaison
- bob   (GitHub: @bob-oss)   — release manager
EOF

    printf '1.0.0\n' > VERSION
    printf '#!/usr/bin/env bash\necho "cloudnative-widget $(cat VERSION)"\n' > widget.sh
    chmod +x widget.sh

    git add CONTRIBUTING.md MAINTAINERS.md VERSION widget.sh
    git commit -q -s -m "initial scaffold for cloudnative-widget"
  fi

  install_dco_hook
}

install_dco_hook() {
  mkdir -p "${REPO_DIR}/.git/hooks"
  cat > "${REPO_DIR}/.git/hooks/commit-msg" <<'HOOK'
#!/usr/bin/env bash
# Simula el bot de CI "DCO check" que usan los proyectos CNCF reales.
set -euo pipefail

msg_file="$1"
name="$(git config user.name || true)"
email="$(git config user.email || true)"

if [[ -z "${name}" || -z "${email}" ]]; then
  echo "DCO check FAILED: no hay identidad de git configurada (user.name/user.email)." >&2
  echo "Un contribuyente nuevo necesita configurar su identidad antes de commitear." >&2
  exit 1
fi

if ! grep -qF "Signed-off-by: ${name} <${email}>" "${msg_file}"; then
  echo "DCO check FAILED: falta 'Signed-off-by: ${name} <${email}>' en el mensaje del commit." >&2
  echo "Usá 'git commit -s' para que git agregue el trailer automáticamente." >&2
  exit 1
fi

echo "DCO check OK"
HOOK
  chmod +x "${REPO_DIR}/.git/hooks/commit-msg"
}

break_env() {
  cd "${REPO_DIR}"

  # Simula el problema más común de un contribuyente nuevo: la VM de
  # laboratorio no tiene identidad de git configurada (ni local ni
  # global). Solo se tocan las claves user.name/user.email; nada más
  # de tu configuración de git se modifica, y es reversible con "reset".
  git config --local  --unset user.name  2>/dev/null || true
  git config --local  --unset user.email 2>/dev/null || true
  git config --global --unset user.name  2>/dev/null || true
  git config --global --unset user.email 2>/dev/null || true

  # Deja un cambio real, ya en el índice, esperando ser commiteado:
  # una contribución legítima (bump de versión) lista para mandar.
  printf '1.1.0\n' > VERSION
  git add VERSION

  cat <<EOF

=================================================================
LAB ARMADO — cloudnative-widget (${REPO_DIR})
=================================================================

Síntoma: hay un cambio preparado (VERSION 1.0.0 -> 1.1.0) en el
staging area, pero no podés commitearlo:

  $ git commit -m "bump version to 1.1.0"
  *** Please tell me who you are.
  ...

Incluso si configurás una identidad cualquiera y agregás -s, el hook
local de DCO (commit-msg) va a rechazar el commit si el Signed-off-by
no coincide EXACTAMENTE con tu identidad de git configurada.

Objetivo: lograr que el commit quede aceptado por el proyecto,
siguiendo su CONTRIBUTING.md (leelo). Necesitás:

  1) Configurar tu identidad de git (nombre y email), como haría
     cualquier contribuyente nuevo a un proyecto CNCF real.
  2) Commitear el cambio con firma DCO válida (git commit -s).
  3) Confirmar que el DCO check del proyecto pasa.

Cuando creas que lo resolviste, corré:

  ./break-fix-4.2.sh check

=================================================================
EOF
}

check_fix() {
  cd "${REPO_DIR}" 2>/dev/null || { echo "No existe el lab todavía. Corré ./break-fix-4.2.sh primero."; exit 1; }

  local name email head_msg ok=1

  name="$(git config user.name 2>/dev/null || true)"
  email="$(git config user.email 2>/dev/null || true)"

  if [[ -z "${name}" || -z "${email}" ]]; then
    echo "FAIL: todavía no configuraste identidad de git (user.name/user.email)."
    ok=0
  fi

  if [[ -n "$(git status --porcelain -- VERSION 2>/dev/null)" ]] || [[ "$(cat VERSION 2>/dev/null)" != "1.1.0" ]]; then
    echo "FAIL: VERSION debería estar en 1.1.0 y el commit ya hecho (working tree limpio)."
    ok=0
  fi

  if [[ "${ok}" -eq 1 ]]; then
    head_msg="$(git log -1 --format='%B' 2>/dev/null || true)"
    if ! grep -qF "Signed-off-by: ${name} <${email}>" <<<"${head_msg}"; then
      echo "FAIL: el commit HEAD no tiene 'Signed-off-by: ${name} <${email}>'."
      ok=0
    fi
  fi

  if [[ "${ok}" -eq 1 ]]; then
    echo "PASS: el commit cumple el proceso de contribución del proyecto (DCO sign-off válido)."
  else
    echo
    echo "Pista: releé CONTRIBUTING.md dentro de ${REPO_DIR} y probá de nuevo."
  fi
}

reset_lab() {
  rm -rf "${LAB_DIR}"
  echo "Lab borrado: ${LAB_DIR}"
}

main() {
  case "${1:-}" in
    check)
      check_fix
      ;;
    reset)
      reset_lab
      ;;
    "")
      confirm_disposable_vm
      setup_repo
      break_env
      ;;
    *)
      echo "Uso: $0 [check|reset]" >&2
      exit 1
      ;;
  esac
}

main "$@"

# =================================================================
# SOLUCIÓN PASO A PASO (para el instructor / autocorrección)
# =================================================================
#
# cd "$HOME/kcna-lab-4.2-community/cloudnative-widget"
#
# 1) Configurar identidad de git (alcanza con local; también sirve
#    global si preferís dejarla para el resto de la VM):
#
#      git config user.name  "Estudiante KCNA"
#      git config user.email "estudiante@kcna.example"
#
# 2) Commitear el cambio ya preparado, firmando DCO (el flag -s
#    agrega automáticamente la línea "Signed-off-by: Nombre <email>"
#    tomando el nombre/email de la config de git, tal como exige
#    CONTRIBUTING.md):
#
#      git commit -s -m "bump version to 1.1.0"
#
# 3) Verificar que el hook (el "CI" local que simula el DCO check
#    real de los proyectos CNCF) aceptó el commit:
#
#      git log -1 --format='%B'
#      # debe mostrar algo como:
#      # bump version to 1.1.0
#      #
#      # Signed-off-by: Estudiante KCNA <estudiante@kcna.example>
#
# 4) Confirmar con el propio script:
#
#      ./break-fix-4.2.sh check
#      # => PASS: el commit cumple el proceso de contribución del
#      #    proyecto (DCO sign-off válido).
#
# Nota conceptual (tema 4.2): esto reproduce en miniatura el flujo
# real de contribución a un proyecto CNCF — CONTRIBUTING.md define
# el proceso, MAINTAINERS.md documenta quién tiene autoridad de
# merge (rol de maintainer dentro de la gobernanza del proyecto), y
# el DCO reemplaza a un CLA tradicional como mecanismo liviano para
# que la comunidad acepte contribuciones sin fricción legal — un
# rasgo característico de cómo CNCF organiza la colaboración open
# source entre contribuyentes, maintainers y el TOC.
# =================================================================