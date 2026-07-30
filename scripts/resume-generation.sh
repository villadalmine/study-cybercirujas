#!/usr/bin/env bash
# Retries content generation after the Claude backend has been blocked by a
# usage limit. Runs decoupled from any interactive session (systemd --user
# timer) so it recovers on its own even when the Claude Code session that left
# it running is blocked by the same limit. Safe to call with nothing pending:
# each `teach cert generate` skips already generated topics and spends no quota.
set -uo pipefail

REPO=/var/home/dalmine/Nextcloud/Repos/teach-plat
cd "$REPO" || exit 1
STATE_DIR="$HOME/.local/state/teach-plat"
LOG="$STATE_DIR/resume.log"
LOCK="$STATE_DIR/resume.lock"
mkdir -p "$STATE_DIR"

# If a generation is already running (started by hand or by an earlier run of
# this same script), do not start another in parallel — that would duplicate
# claude calls on the same topic.
if pgrep -f "teach cert generate" > /dev/null; then
    echo "=== $(date -Iseconds) — generation already running, skipping ===" >> "$LOG"
    exit 0
fi

exec 9>"$LOCK"
flock -n 9 || exit 0

# Quota gate. Without this the script walked the whole target list on every
# firing and every call failed the same way, which is noisy and pointless while
# a spend window is closed. One cheap probe answers it, and each probe is
# appended to a history so there is an empirical record of when the window
# actually reopened — that cannot be computed, only observed.
if ! "$REPO/.venv/bin/python3" "$REPO/scripts/quota.py" --quiet; then
    echo "=== $(date -Iseconds) — no quota, skipping ===" >> "$LOG"
    exit 0
fi

{
    echo "=== $(date -Iseconds) ==="
    # One bounded pass per firing. fix_corrupted_content derives its work from
    # pipeline.yaml — every active cert and language, anything missing, corrupt
    # or below the quality floor — and stops at budget.topics_per_run.
    #
    # This used to also loop `teach cert generate <cert> --lang <lang>` over
    # every target, with no --topic, which generates EVERY pending topic for
    # that combination. Unbounded, and contradicting the deliberate pacing.
    # It was redundant too: the audit already enumerates the same queue.
    "$REPO/.venv/bin/python3" "$REPO/scripts/fix_corrupted_content.py"
    echo "=== end $(date -Iseconds) ==="
} >> "$LOG" 2>&1
