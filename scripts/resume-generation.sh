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

# cert:lang sale de pipeline.yaml, no de una lista acá. Tener la lista propia
# significaba que agregar un idioma requería acordarse de tres lugares, y no
# pasó: este script quedó en español-solamente mientras se generaba inglés.
mapfile -t TARGETS < <("$REPO/.venv/bin/python3" -c "
from teach.core import pipeline
for cert, langs in pipeline.targets():
    for lang in langs:
        print(f'{cert}:{lang}')
")

{
    echo "=== $(date -Iseconds) ==="
    # fix_corrupted_content ya respeta budget.topics_per_run de pipeline.yaml,
    # así que una pasada desatendida avanza de a poco en vez de intentar
    # vaciar la cola (y la cuota) de una sola vez.
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
