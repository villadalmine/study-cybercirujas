#!/usr/bin/env bash
# Reintenta la generación de contenido cuando el backend Claude quedó
# bloqueado por límite de uso. Corre desacoplado de cualquier sesión
# interactiva (systemd --user timer) para que se recupere solo aunque la
# sesión de Claude Code que lo dejó andando también esté bloqueada por el
# mismo límite. Es seguro llamarlo aunque no haya nada pendiente: cada
# `teach cert generate` saltea los temas ya generados y no gasta cuota.
set -uo pipefail

REPO=/var/home/dalmine/Nextcloud/Repos/teach-plat
cd "$REPO" || exit 1
TEACH="$REPO/.venv/bin/teach"
STATE_DIR="$HOME/.local/state/teach-plat"
LOG="$STATE_DIR/resume.log"
LOCK="$STATE_DIR/resume.lock"
mkdir -p "$STATE_DIR"

# Si ya hay una generación corriendo (lanzada a mano o por una corrida
# anterior de este mismo script), no lanzar otra en paralelo — evita
# duplicar llamadas a claude sobre el mismo tema.
if pgrep -f "teach cert generate" > /dev/null; then
    exit 0
fi

exec 9>"$LOCK"
flock -n 9 || exit 0

# cert:lang a mantener al día. Certs sin topics todavía (ej. cka antes del
# snapshot) simplemente no generan nada — no rompe.
TARGETS=(
    "lpi-010-160:pt"
    "lpi-010-160:fr"
    "lpi-010-160:de"
    "lpi-010-160:zh"
    "lpi-010-160:ja"
    "ckad:es"
    "cka:es"
    "cks:es"
    "kcna:es"
)

{
    echo "=== $(date -Iseconds) ==="
    echo "--- fix_corrupted_content ---"
    "$REPO/.venv/bin/python3" "$REPO/scripts/fix_corrupted_content.py"
    for target in "${TARGETS[@]}"; do
        cert="${target%%:*}"
        lang="${target##*:}"
        echo "--- $cert ($lang) ---"
        "$TEACH" cert generate "$cert" --backend claude --lang "$lang"
    done
    echo "=== fin $(date -Iseconds) ==="
} >> "$LOG" 2>&1
