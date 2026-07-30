#!/usr/bin/env bash
# Retries content generation after the Claude backend has been blocked by a
# usage limit. Runs decoupled from any interactive session (systemd --user
# timer) so it recovers on its own even when the Claude Code session that left
# it running is blocked by the same limit. Safe to call with nothing pending:
# each `teach cert generate` skips already generated topics and spends no quota.
set -uo pipefail

REPO=/var/home/dalmine/Nextcloud/Repos/teach-plat
cd "$REPO" || exit 1
TEACH="$REPO/.venv/bin/teach"
STATE_DIR="$HOME/.local/state/teach-plat"
LOG="$STATE_DIR/resume.log"
LOCK="$STATE_DIR/resume.lock"
mkdir -p "$STATE_DIR"

# If a generation is already running (started by hand or by an earlier run of
# this same script), do not start another in parallel — that would duplicate
# claude calls on the same topic.
if pgrep -f "teach cert generate" > /dev/null; then
    exit 0
fi

exec 9>"$LOCK"
flock -n 9 || exit 0

# cert:lang comes from pipeline.yaml, not from a list here. Keeping its own list
# meant adding a language required remembering three places, and that did not
# happen: this script stayed Spanish-only while English was being generated.
mapfile -t TARGETS < <("$REPO/.venv/bin/python3" -c "
from teach.core import pipeline
for cert, langs in pipeline.targets():
    for lang in langs:
        print(f'{cert}:{lang}')
")

{
    echo "=== $(date -Iseconds) ==="
    # fix_corrupted_content already honours budget.topics_per_run from
    # pipeline.yaml, so an unattended pass advances a little at a time instead
    # of trying to drain the queue — and the quota — in one go.
    echo "--- fix_corrupted_content ---"
    "$REPO/.venv/bin/python3" "$REPO/scripts/fix_corrupted_content.py"
    for target in "${TARGETS[@]}"; do
        cert="${target%%:*}"
        lang="${target##*:}"
        echo "--- $cert ($lang) ---"
        "$TEACH" cert generate "$cert" --backend claude --lang "$lang"
    done
    echo "=== end $(date -Iseconds) ==="
} >> "$LOG" 2>&1
