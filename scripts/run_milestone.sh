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
# No model pin here on purpose. pipeline.yaml `generation.model` is the declared
# decision and the generator reads it; a default in this script would silently
# win over the file, which is the failure the declaration exists to prevent.
# TEACH_CLAUDE_MODEL still works for a deliberate one-off comparison run.

# Derived from the work actually left, not a magic number: a fixed 30 passes at
# budget.topics_per_run=2 is 60 combos, and kca needs 62 — so the cap stopped the
# loop two topics short of the goal it exists to reach. Doubled for margin,
# because a pass whose topic is already claimed by another run does no work and
# still counts (13 of them in one session, from two loops running at once).
NEEDED="$("$REPO/.venv/bin/python3" - <<'PYEOF'
import sys
sys.path.insert(0, ".")
sys.path.insert(0, "scripts")
try:
    from teach.core import pipeline
    import fix_corrupted_content as audit
    todo = [c for c in audit.find_bad_combos()
            if pipeline.in_milestone(c[0], c[2]) and pipeline.mine(c[0])]
    per = pipeline.topics_per_run() or 1
    print(max(4, -(-len(todo) // per) * 2))
except Exception:
    print(30)
PYEOF
)"
MAX_PASSES="${MAX_PASSES:-$NEEDED}"
echo "=== milestone: $NEEDED passes budgeted for the work remaining ===" >> "$LOG"
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
