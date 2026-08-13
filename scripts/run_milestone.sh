#!/usr/bin/env bash
#
# Work the declared milestone to completion, then stop.
#
# One pass generates `budget.topics_per_run` topics and exits, which is right for
# a timer firing every 20 minutes and wrong for "finish this certification".
# This is the loop around it: passes back to back until the goal is met, the
# quota window closes, or the cap is reached.
#
# It stops on its own, three ways, and every one of them is reported:
#
#   the milestone is met            the goal in pipeline.yaml has no work left
#   the quota window closed         probed before each pass, so nothing is wasted
#   the pass cap                    a backstop against a bug that never converges
#
# Set the goal first; with none declared this generates nothing:
#
#     scripts/steer.py milestone kca en es
#     scripts/run_milestone.sh                 # or: make milestone
#
# Everything a finished certification needs happens inside the pass — video,
# STATUS.md, and building and deploying the image when the set of complete
# certifications changes. There is no separate "now publish" step to remember.
#
# Safe to run twice: each pass rescans from disk and claims per topic, so a
# second copy works on different topics rather than the same ones.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/teach-plat"
LOG="$STATE_DIR/milestone.log"
mkdir -p "$STATE_DIR"

export TEACH_AGENT="${TEACH_AGENT:-claude}"
# Pin the exact model, never the `opus` alias: the alias means "the latest Opus"
# and the CLI can fall back mid-run, which makes two topics incomparable.
export TEACH_CLAUDE_MODEL="${TEACH_CLAUDE_MODEL:-claude-opus-4-8}"

MAX_PASSES="${MAX_PASSES:-30}"
PASS_OUT="$(mktemp)"
trap 'rm -f "$PASS_OUT"' EXIT

for i in $(seq 1 "$MAX_PASSES"); do
    if ! "$REPO/.venv/bin/python3" "$REPO/scripts/quota.py" --quiet; then
        echo "=== pass $i: quota window closed, stopping ===" | tee -a "$LOG"
        exit 0
    fi

    # This pass's own output, not the tail of the shared log. Grepping the log
    # matched the PREVIOUS milestone's "Milestone met" line and exited on pass 1
    # with one topic done — a loop that reads history as if it were the present.
    "$REPO/.venv/bin/python3" "$REPO/scripts/fix_corrupted_content.py" --milestone \
        > "$PASS_OUT" 2>&1
    cat "$PASS_OUT" >> "$LOG"

    if grep -q "Milestone met\|No milestone declared\|not mine to do" "$PASS_OUT"; then
        tail -1 "$PASS_OUT"
        echo "=== finished at pass $i ===" >> "$LOG"
        exit 0
    fi
done

echo "=== pass cap ($MAX_PASSES) reached; run again to continue ===" | tee -a "$LOG"
