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

# Only one instance of THIS script at a time — a firing must not stack on top of
# a previous one that is still working. It deliberately does NOT exclude other
# agents: collisions are prevented per topic (teach/core/claims.py), so a second
# agent generating a different certification is two agents working, not a
# conflict. This used to be a `pgrep -f "teach cert generate"` guard, which
# blocked the timer whenever ANYONE was generating anything — and an agent that
# finds itself blocked for no reason writes its own runner that skips the guard,
# which is precisely what happened on 2026-08-06.
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

    # Refresh the matrix here too. `make cert` and `make publish` already do it,
    # but THIS is the path that does most of the generating, so leaving it out
    # meant the dashboard drifted exactly when nobody was watching — STATUS.md
    # sat a day stale reporting kcsa at 2/42 when it was 42/42. A report that is
    # only right when a human remembers to refresh it is worse than no report,
    # because it is believed.
    #
    # Idempotent, like everything else here: it is derived from disk, so running
    # it twice changes nothing and running it never is the only way to be wrong.
    "$REPO/.venv/bin/teach" status || true
    echo "=== end $(date -Iseconds) ==="
} >> "$LOG" 2>&1
