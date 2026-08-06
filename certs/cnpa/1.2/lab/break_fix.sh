#!/usr/bin/env bash
#===============================================================================
# CNPA 1.2 — DevOps Practices and Culture in Platform Engineering
# Break & Fix Lab: "The Silent Pipeline and the Snowflake Server"
#
# WHAT THIS LAB TEACHES
#   Two failure modes that CNPA 1.2 exists to make you recognize on sight:
#     1. Automation that fails SILENTLY — a delivery pipeline that stops
#        running without ever raising an error, destroying the feedback loop.
#     2. Configuration drift — a manual "hotfix" applied directly to the
#        running environment, bypassing Git, creating a snowflake server.
#   The fix exercises the core DevOps practices: Git as the single source of
#   truth, repairing the system instead of the symptom, and proving the loop
#   end-to-end before declaring victory.
#
# SAFETY
#   - Touches ONLY ~/cnpa-lab-1.2. No sudo, no services, no network access.
#   - Designed for a disposable lab VM; safe to re-run (idempotent: every run
#     rebuilds the lab from scratch and re-breaks it).
#
# USAGE
#   ./break_fix.sh          # (re)create the lab and break it
#   ./break_fix.sh verify   # check whether your fix is complete
#   ./break_fix.sh reset    # remove the lab entirely
#
# SOURCES
#   - CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   - CNCF Platforms Whitepaper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
#   - githooks(5) — hook execution rules: https://git-scm.com/docs/githooks
#   - Google SRE Book, "Eliminating Toil": https://sre.google/sre-book/eliminating-toil/
#   - DORA research (lead time, feedback loops): https://dora.dev/
#===============================================================================

set -euo pipefail

LAB_DIR="${HOME}/cnpa-lab-1.2"
ORIGIN_DIR="${LAB_DIR}/origin/platform.git"
DEV_DIR="${LAB_DIR}/dev/platform"
DEPLOY_DIR="${LAB_DIR}/deploy"
LOG_FILE="${LAB_DIR}/deploy.log"
HOOK="${ORIGIN_DIR}/hooks/post-receive"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: '$1' is required but not installed." >&2
        exit 1
    }
}

setup() {
    need git
    need diff
    need tar

    rm -rf "${LAB_DIR:?}"
    mkdir -p "${LAB_DIR}/origin" "${LAB_DIR}/dev" "$DEPLOY_DIR"

    # --- The "platform side": a bare repo whose post-receive hook IS the
    # --- delivery pipeline. In production this role is played by Argo CD,
    # --- Flux, Tekton or GitHub Actions; the mechanics are identical:
    # --- trigger on push -> validate -> deploy from Git -> report back.
    git init -q --bare "$ORIGIN_DIR"
    git --git-dir="$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main

    cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Minimal CI/CD pipeline for the lab, implemented as a git post-receive hook.
# Everything echoed here travels back to the developer's terminal prefixed
# with 'remote:' — that is the pipeline's feedback loop.
set -euo pipefail
DEPLOY_DIR="__DEPLOY_DIR__"
LOG_FILE="__LOG_FILE__"
while read -r oldrev newrev refname; do
    [ "$refname" = "refs/heads/main" ] || continue
    short="$(printf '%.7s' "$newrev")"
    echo "[pipeline] stage 1/3 checkout : ${short}"
    worktree="$(mktemp -d)"
    git archive "$newrev" | tar -x -C "$worktree"
    echo "[pipeline] stage 2/3 validate : syntax + version gate"
    bash -n "$worktree/app.sh" \
        || { echo "[pipeline] FAIL: app.sh has syntax errors"; rm -rf "$worktree"; exit 1; }
    grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$worktree/VERSION" \
        || { echo "[pipeline] FAIL: VERSION must be semver MAJOR.MINOR.PATCH"; rm -rf "$worktree"; exit 1; }
    echo "[pipeline] stage 3/3 deploy   : full sync — Git is the source of truth"
    rm -rf "$DEPLOY_DIR"
    mkdir -p "$DEPLOY_DIR"
    cp -a "$worktree"/. "$DEPLOY_DIR"/
    rm -rf "$worktree"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) deployed ${newrev} v$(cat "$DEPLOY_DIR/VERSION")" >> "$LOG_FILE"
    echo "[pipeline] OK: v$(cat "$DEPLOY_DIR/VERSION") is live in ${DEPLOY_DIR}"
done
HOOK_EOF
    sed -i "s|__DEPLOY_DIR__|${DEPLOY_DIR}|; s|__LOG_FILE__|${LOG_FILE}|" "$HOOK"
    chmod +x "$HOOK"

    # --- The "developer side": a working clone with the service source.
    git init -q "$DEV_DIR"
    git -C "$DEV_DIR" symbolic-ref HEAD refs/heads/main
    git -C "$DEV_DIR" config user.name  "CNPA Lab Student"
    git -C "$DEV_DIR" config user.email "student@cnpa.lab"
    git -C "$DEV_DIR" remote add origin "$ORIGIN_DIR"

    cat > "$DEV_DIR/app.sh" <<'APP_EOF'
#!/usr/bin/env bash
# payments-notifier — sends the daily settlement report to the finance team.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
version="$(cat "$here/VERSION")"
timeout_seconds=30
echo "payments-notifier v${version} (timeout=${timeout_seconds}s): settlement report sent"
APP_EOF
    printf '1.0.0\n' > "$DEV_DIR/VERSION"
    printf '# payments-notifier\n\nDeployed exclusively via the pipeline. Never edit the deploy dir by hand.\n' \
        > "$DEV_DIR/README.md"

    git -C "$DEV_DIR" add .
    git -C "$DEV_DIR" commit -q -m "feat: payments-notifier v1.0.0"

    echo ""
    echo "--- Initial push: memorize what a HEALTHY pipeline run looks like -------"
    git -C "$DEV_DIR" push -u origin main
    echo "-------------------------------------------------------------------------"
}

break_it() {
    # Sabotage 1 — the silent kill. Per githooks(5), git runs a hook ONLY if
    # the file is executable; a non-executable hook is skipped without any
    # warning. Pushes will keep succeeding while deployments simply stop.
    chmod -x "$HOOK"

    # Sabotage 2 — the 02:47 incident "hotfix", applied by hand directly to
    # the deployed copy, bypassing Git entirely. Classic configuration drift.
    sed -i 's/^timeout_seconds=30$/timeout_seconds=300/' "$DEPLOY_DIR/app.sh"
    printf '%s\n' "# HOTFIX (manual, 02:47, no ticket): raised timeout during the incident" \
        >> "$DEPLOY_DIR/app.sh"
    printf '1.0.0-hotfix1\n' > "$DEPLOY_DIR/VERSION"
}

briefing() {
    cat <<'EOF'

================================================================================
 CNPA 1.2 BREAK & FIX — The Silent Pipeline and the Snowflake Server
================================================================================

 SCENARIO
   Your platform team runs the delivery pipeline for 'payments-notifier'.
   Developers push to Git; the pipeline validates every commit on main and
   deploys it to ~/cnpa-lab-1.2/deploy. You just watched a healthy run above:
   every push answers back with 'remote: [pipeline] ...' lines — that is the
   feedback loop developers rely on.

   Last night there was a production incident. This morning two things are
   true: the deployed service no longer matches Git, and pushes have quietly
   stopped deploying.

 SYMPTOMS — reproduce them right now
   1) Ship a change through the golden path:
        cd ~/cnpa-lab-1.2/dev/platform
        echo "1.0.1" > VERSION
        git commit -am "chore: bump to 1.0.1"
        git push origin main
      Expected (broken) output — the push SUCCEEDS but the pipeline says
      nothing at all:
        To ~/cnpa-lab-1.2/origin/platform.git
           ab12cd3..ef45ab6  main -> main
      No 'remote: [pipeline]' lines. No error either. The automation failed
      SILENTLY — the most dangerous way automation can fail, because every
      developer still believes their code shipped.
   2) Compare reality with Git:
        cat ~/cnpa-lab-1.2/deploy/VERSION       ->  1.0.0-hotfix1
        tail -n 2 ~/cnpa-lab-1.2/deploy/app.sh  ->  a manual "HOTFIX" edit
      That version exists on the server and nowhere in Git history: a
      snowflake server, born from configuration drift.

 YOUR MISSION
   1. Find out why pushes stopped deploying and fix the PIPELINE.
      Hint: read githooks(5). What does git do with a hook file that exists
      but is not executable?
   2. Do NOT hand-edit anything under ~/cnpa-lab-1.2/deploy/. The drift must
      be reconciled BY the pipeline, from Git — Git is the single source of
      truth. (If the 300s timeout were genuinely needed, the DevOps way is
      to commit it through review; here, policy says 30s stands.)
   3. Prove the loop end-to-end: land a real change (the 1.0.1 bump is fine)
      and watch all three pipeline stages answer your push.
   4. ./break_fix.sh verify must show every check green.

 RULES OF ENGAGEMENT
   - Everything you need lives under ~/cnpa-lab-1.2. No sudo required.
   - Fixing the symptom by hand instead of fixing the system is precisely
     the anti-pattern this exam topic exists to unlearn.

 CULTURE NOTE (this IS the exam topic, not decoration)
   Nobody in this exercise asks WHO made the 02:47 hotfix. Blameless culture
   treats the incident as a system defect: the platform made the wrong thing
   easy (direct access to the deploy target) and the right thing invisible
   (a pipeline that dies without a sound). A good fix restores the golden
   path AND the feedback that tells you the path is alive.
================================================================================
 Lab is broken and ready. Start with the SYMPTOMS section above.
 Check your progress anytime with: ./break_fix.sh verify
================================================================================
EOF
}

verify() {
    [ -d "$ORIGIN_DIR" ] || { echo "Lab not found. Run ./break_fix.sh first." >&2; exit 1; }
    local fails=0 head
    head="$(git --git-dir="$ORIGIN_DIR" rev-parse refs/heads/main)"

    check() {
        local desc="$1"; shift
        if "$@" >/dev/null 2>&1; then
            echo "  [PASS] $desc"
        else
            echo "  [FAIL] $desc"
            fails=$((fails + 1))
        fi
    }
    hook_is_executable() { test -x "$HOOK"; }
    version_matches_git() {
        [ "$(git --git-dir="$ORIGIN_DIR" show main:VERSION)" = "$(cat "$DEPLOY_DIR/VERSION")" ]
    }
    app_matches_git() {
        git --git-dir="$ORIGIN_DIR" show main:app.sh | diff -q - "$DEPLOY_DIR/app.sh"
    }
    pipeline_ran_after_fix() {
        [ "$(wc -l < "$LOG_FILE")" -ge 2 ] && tail -n 1 "$LOG_FILE" | grep -q "$head"
    }

    echo "Verifying CNPA 1.2 lab state..."
    check "post-receive hook is executable (automation restored)"         hook_is_executable
    check "deployed VERSION matches Git main (no version drift)"          version_matches_git
    check "deployed app.sh matches Git main (hotfix drift reconciled)"    app_matches_git
    check "pipeline ran again after the break (last deploy = current HEAD)" pipeline_ran_after_fix

    echo ""
    if [ "$fails" -eq 0 ]; then
        cat <<'EOF'
ALL CHECKS GREEN. Debrief — what you just practiced:
  - Silent automation failure: a skipped hook produced no error, so the
    feedback loop (not the push exit code) was the only honest signal.
  - Drift reconciliation through Git: the pipeline's full sync erased the
    snowflake; you never touched the deploy directory by hand.
  - Prove, don't assume: the fix counted only after a real push flowed
    through all stages again. That is DORA's lead-time loop in miniature.
EOF
    else
        echo "$fails check(s) failing. Re-read the SYMPTOMS and MISSION in the briefing."
        exit 1
    fi
}

reset() {
    rm -rf "${HOME:?}/cnpa-lab-1.2"
    echo "Lab removed."
}

case "${1:-run}" in
    run)    setup; break_it; briefing ;;
    verify) verify ;;
    reset)  reset ;;
    *)      echo "Usage: $0 [run|verify|reset]" >&2; exit 2 ;;
esac
exit 0

#===============================================================================
# SOLUTION — step by step (spoilers below; try the lab first)
#===============================================================================
#
# 1) Reproduce the symptom and notice what is MISSING, not what is present.
#      cd ~/cnpa-lab-1.2/dev/platform
#      echo "1.0.1" > VERSION
#      git commit -am "chore: bump to 1.0.1"
#      git push origin main
#    The push exits 0 and prints the ref update, but there are zero
#    'remote: [pipeline]' lines. Compare with the healthy run you saw during
#    setup: checkout / validate / deploy stages all reported back. A missing
#    feedback signal is itself a diagnostic datum.
#
# 2) Confirm the drift and prove it is outside Git:
#      cat ~/cnpa-lab-1.2/deploy/VERSION
#        -> 1.0.0-hotfix1        (not a commit that exists anywhere)
#      git --git-dir=$HOME/cnpa-lab-1.2/origin/platform.git show main:app.sh \
#        | diff - ~/cnpa-lab-1.2/deploy/app.sh
#        -> timeout_seconds 30 vs 300, plus the manual "# HOTFIX" line.
#    Reality diverged from the source of truth, and Git history cannot
#    explain the divergence: that is the definition of configuration drift.
#
# 3) Diagnose the pipeline itself:
#      ls -l ~/cnpa-lab-1.2/origin/platform.git/hooks/
#        -rw-r--r-- ... post-receive     <-- NOT executable
#    Per githooks(5) (https://git-scm.com/docs/githooks), git only runs a
#    hook that is executable; otherwise it is silently ignored. No exec bit,
#    no pipeline, no error. In managed CI/CD the same class of failure looks
#    like a disabled webhook, a paused Argo CD Application, or a workflow
#    file renamed out of .github/workflows/.
#
# 4) Fix the SYSTEM, not the symptom:
#      chmod +x ~/cnpa-lab-1.2/origin/platform.git/hooks/post-receive
#    Resist the urge to hand-edit deploy/ — that would be one more untracked
#    change on a snowflake server.
#
# 5) Let the pipeline reconcile the drift from Git:
#      cd ~/cnpa-lab-1.2/dev/platform
#      git push origin main          # if the 1.0.1 bump is still unpushed
#      # ...or force a run without a content change:
#      git commit --allow-empty -m "ci: trigger redeploy" && git push origin main
#    Expected output now includes all three stages:
#      remote: [pipeline] stage 1/3 checkout : <sha>
#      remote: [pipeline] stage 2/3 validate : syntax + version gate
#      remote: [pipeline] stage 3/3 deploy   : full sync — Git is the source of truth
#      remote: [pipeline] OK: v1.0.1 is live in /home/<you>/cnpa-lab-1.2/deploy
#    The deploy stage rebuilds the target from the pushed commit, so the
#    hotfix drift is erased as a side effect of normal delivery — exactly how
#    GitOps reconcilers (Argo CD, Flux) heal drift continuously.
#
# 6) Prove it:
#      ./break_fix.sh verify
#      cat ~/cnpa-lab-1.2/deploy.log     # audit trail: one line per deploy
#
# 7) Takeaways to carry into the exam:
#    - Automation must fail loudly; a silent pipeline is worse than none,
#      because it converts every push into false confidence.
#    - Feedback loops are a deliverable of the platform, not a nicety: the
#      'remote:' stage output is the lab-scale version of pipeline status
#      checks, deploy notifications and Argo CD health/sync state.
#    - Drift is repaired through the source of truth, never in place; if the
#      hotfix value was right, it earns a commit and a review like any change.
#    - Blameless response: the question is never "who typed it at 02:47" but
#      "why was typing it the easiest available action" — then you fix that.
#      (https://sre.google/sre-book/eliminating-toil/, https://dora.dev/)
#===============================================================================