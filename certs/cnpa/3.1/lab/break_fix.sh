#!/usr/bin/env bash
#
# CNPA — Certified Cloud Native Platform Engineering Associate
# Exam version: 2025-04-01
# Domain 3 — Continuous Integration & Delivery
# Topic 3.1 — Continuous Integration Fundamentals and Best Practices  (exam weight 2.3)
#
# BREAK & FIX lab — "The pipeline that lies"
# =============================================================================
# WHAT THIS IS
#   A self-contained, disposable-VM exercise that plants exactly ONE realistic
#   defect in a minimal CI pipeline (lint -> build -> test) and asks you to make
#   the pipeline honest again. It writes nothing outside its own lab directory
#   and needs only bash + coreutils (git is used if present, optional).
#
# THE BEST PRACTICE UNDER TEST
#   A CI pipeline's first responsibility is to TELL THE TRUTH: if any stage
#   fails, the whole run must fail — fail-fast, with correct exit-code
#   propagation. A green build that hides a red stage is worse than no build at
#   all: it ships broken code wearing a badge of confidence. This lab reproduces
#   the single most common way shell-based pipelines lie — a failing command
#   piped into `tee`, whose zero exit status silently overwrites the real one.
#
# SAFETY
#   * Everything happens under $CNPA_LAB_DIR (default ~/cnpa-lab-3.1-ci).
#   * `reset` only deletes a directory that carries this lab's sentinel file.
#   * Run it on a THROWAWAY VM or container. Do not run it inside a real repo.
#
# USAGE
#   ./break_fix.sh            # arm the lab (build + break) and print the briefing
#   ./break_fix.sh verify     # check whether your fix makes the pipeline honest
#   ./break_fix.sh solution   # print the step-by-step solution
#   ./break_fix.sh reset      # wipe the lab dir and re-arm from scratch
#
# SOURCES (official / canonical)
#   * CNCF CNPA Curriculum:
#       https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   * GNU Bash Reference Manual — Pipelines, `set -o pipefail`, PIPESTATUS:
#       https://www.gnu.org/software/bash/manual/bash.html#Pipelines
#   * M. Fowler, "Continuous Integration" (canonical definition & practices):
#       https://martinfowler.com/articles/continuousIntegration.html
# =============================================================================

set -euo pipefail

LAB_DIR="${CNPA_LAB_DIR:-$HOME/cnpa-lab-3.1-ci}"
MARKER="$LAB_DIR/.cnpa-lab-marker"

# -----------------------------------------------------------------------------
# build_lab: materialise the app, its test, and the (broken) CI runner.
# -----------------------------------------------------------------------------
build_lab() {
  mkdir -p "$LAB_DIR/app" "$LAB_DIR/tests" "$LAB_DIR/ci"
  printf 'cnpa 3.1 continuous-integration break-fix lab\n' > "$MARKER"

  # --- application under test (contains a REAL, deliberate defect) ------------
  cat > "$LAB_DIR/app/calc.sh" <<'CALC'
#!/usr/bin/env bash
# Tiny "application under test". It ships a real bug: add() subtracts.
set -u
add() { echo "$(( ${1:-0} - ${2:-0} ))"; }   # BUG: should be +, not -
case "${1:-}" in
  add) add "${2:-}" "${3:-}" ;;
  *)   echo "usage: calc.sh add A B" >&2; exit 2 ;;
esac
CALC

  # --- unit test that CORRECTLY catches the bug (this SHOULD fail) ------------
  cat > "$LAB_DIR/tests/test_add.sh" <<'TEST'
#!/usr/bin/env bash
set -u
got="$(bash app/calc.sh add 2 3)"
want=5
if [ "$got" = "$want" ]; then
  echo "test_add: ok"
  exit 0
fi
echo "test_add: FAIL  want=$want  got=$got"
exit 1
TEST

  # --- the CI runner (contains the ONE defect you must fix) ------------------
  cat > "$LAB_DIR/ci/run-ci.sh" <<'CI'
#!/usr/bin/env bash
# Minimal CI runner: lint -> build -> test, streaming every stage to ci.log.
#
# There is exactly ONE defect in this file, on the line marked "DEFECT" below.
# Do NOT "fix" the build by deleting the failing test or by patching calc.sh —
# your job is to make THIS RUNNER report failure when a stage fails.
set -u

CI_LOG="ci/ci.log"
: > "$CI_LOG"

stage_lint()  { echo "lint:  ok (no linters configured)"; return 0; }
stage_build() { chmod +x app/*.sh tests/*.sh 2>/dev/null || true; echo "build: ok"; return 0; }
stage_test()  {
  rc=0
  for t in tests/test_*.sh; do
    [ -e "$t" ] || continue
    if bash "$t"; then echo "  PASS $t"; else echo "  FAIL $t"; rc=1; fi
  done
  return "$rc"
}

run_stage() {
  name="$1"; shift
  echo ">>> stage: $name"
  "$@" | tee -a "$CI_LOG"
  rc=$?                       # <<< DEFECT: this is tee's exit status, never the stage's
  if [ "$rc" -ne 0 ]; then
    echo "!!! stage '$name' FAILED (rc=$rc)"
    return "$rc"
  fi
  return 0
}

run_stage lint  stage_lint  || { echo "Pipeline: FAILED"; exit 1; }
run_stage build stage_build || { echo "Pipeline: FAILED"; exit 1; }
run_stage test  stage_test  || { echo "Pipeline: FAILED"; exit 1; }

echo "Pipeline: SUCCESS"
exit 0
CI

  chmod +x "$LAB_DIR"/app/*.sh "$LAB_DIR"/tests/*.sh "$LAB_DIR"/ci/*.sh

  # Optional: make it a git repo so it feels like a real CI checkout.
  if command -v git >/dev/null 2>&1 && [ ! -d "$LAB_DIR/.git" ]; then
    ( cd "$LAB_DIR" \
        && git init -q \
        && git add -A \
        && git -c user.email=lab@example.com -c user.name='CNPA Lab' \
             commit -qm "cnpa 3.1 lab: initial (broken pipeline)" ) >/dev/null 2>&1 || true
  fi
}

ensure_armed() { [ -f "$MARKER" ] || build_lab; }

# -----------------------------------------------------------------------------
# briefing: tell the student the symptom, the objective and how to self-check.
# -----------------------------------------------------------------------------
briefing() {
  local d="$LAB_DIR"
  cat <<'HDR'

==============================================================================
 CNPA 3.1 — CONTINUOUS INTEGRATION FUNDAMENTALS — BREAK & FIX
 Scenario: "The pipeline that lies"
==============================================================================
HDR
  cat <<DYN
 Lab directory : $d
 CI runner     : $d/ci/run-ci.sh   <-- the file you will edit

REPRODUCE THE SYMPTOM
    cd "$d"
    bash ci/run-ci.sh ; echo "exit=\$?"
DYN
  cat <<'BODY'

  Expected (WRONG) output — note the FAIL line and the green verdict together:
    >>> stage: test
      FAIL tests/test_add.sh
    Pipeline: SUCCESS
    exit=0

  A downstream deploy gated on `exit=0` would happily ship the broken build.

WHAT HAPPENED
  The app is broken on purpose: `calc.sh add 2 3` returns -1, and
  tests/test_add.sh already catches it. The pipeline ran that failing test...
  and still printed "Pipeline: SUCCESS" with exit code 0. The red stage was
  swallowed somewhere between the test and the verdict.

THE SYMPTOM IN ONE LINE
  A stage fails, yet the pipeline exits 0 and reports SUCCESS.

YOUR OBJECTIVE (definition of done)
  Make the CI runner HONEST: when any stage fails, the run must print
  "Pipeline: FAILED" and exit non-zero. The failing test is the canary — it is
  MEANT to fail. Do NOT delete the test and do NOT patch calc.sh to hide it.
  The only file you should need to change is ci/run-ci.sh.

CONSTRAINTS
  * Fix the pipeline's failure detection, not the application.
  * The lint and build stages must still pass on a healthy run.

HINTS (peek only if stuck)
  1. Run the test by hand and inspect its exit code — the test itself is fine:
        bash tests/test_add.sh ; echo $?      # -> 1
  2. Now read how run-ci.sh captures a stage's exit code. Look at the line
     marked "DEFECT". What is the exit status of `cmd | tee file` — the exit of
     `cmd`, or the exit of `tee`?
  3. In bash a pipeline's `$?` is, by default, the exit status of its LAST
     command. `tee` almost always succeeds. Two documented ways to change that:
     `set -o pipefail`, or reading `${PIPESTATUS[0]}`.

CHECK YOURSELF
    ./break_fix.sh verify

  It injects a throwaway always-failing test, runs your pipeline, and confirms
  the pipeline now exits non-zero when a stage fails.

The full step-by-step solution is at the very bottom of this script (commented),
or run:  ./break_fix.sh solution
==============================================================================
BODY
}

# -----------------------------------------------------------------------------
# arm / reset / verify / solution
# -----------------------------------------------------------------------------
arm() {
  if [ -f "$MARKER" ]; then
    echo "Lab already present at: $LAB_DIR"
    echo "Start fixing, or run './break_fix.sh reset' to rebuild from scratch."
  else
    build_lab
    echo "Lab armed at: $LAB_DIR"
  fi
  briefing
}

reset() {
  if [ -d "$LAB_DIR" ]; then
    if [ -f "$MARKER" ]; then
      rm -rf "$LAB_DIR"
      echo "Removed old lab at $LAB_DIR"
    else
      echo "Refusing to delete $LAB_DIR: no $MARKER sentinel found." >&2
      exit 1
    fi
  fi
  build_lab
  echo "Lab rebuilt at $LAB_DIR"
  briefing
}

verify() {
  ensure_armed
  cd "$LAB_DIR"
  cat > tests/test_zzz_canary.sh <<'CANARY'
#!/usr/bin/env bash
echo "canary: deliberate failure to test pipeline honesty"
exit 1
CANARY
  set +e
  out="$(bash ci/run-ci.sh 2>&1)"
  rc=$?
  set -e
  rm -f tests/test_zzz_canary.sh
  echo "$out" | sed 's/^/    ci| /'
  echo
  if [ "$rc" -ne 0 ]; then
    echo "RESULT: PASS  — pipeline exited $rc when a stage failed. It tells the truth now."
  else
    echo "RESULT: FAIL  — pipeline still exited 0 with a failing stage. Keep going."
    echo "               Re-read the line marked DEFECT in ci/run-ci.sh."
  fi
}

solution() {
  cat <<'SOL'
SOLUTION (option A is the idiomatic CI answer)
  Root cause: in run_stage(), the stage runs as the left side of a pipe:
        "$@" | tee -a "$CI_LOG"
        rc=$?
  A pipeline's $? is the exit status of its LAST command — here `tee`, which
  succeeds — so rc is almost always 0, the failure guard never fires, and the
  script falls through to `echo "Pipeline: SUCCESS"; exit 0`.

  Fix A (recommended): add, right after the shebang of ci/run-ci.sh:
        set -o pipefail
  Fix B: change `rc=$?` to `rc=${PIPESTATUS[0]}`  (status of the FIRST member).

  Verify:
        bash ci/run-ci.sh ; echo "exit=$?"     # -> Pipeline: FAILED / exit=1
        ./break_fix.sh verify                  # -> RESULT: PASS
SOL
}

# -----------------------------------------------------------------------------
main() {
  case "${1:-arm}" in
    arm|"")        arm ;;
    verify)        verify ;;
    solution)      solution ;;
    reset)         reset ;;
    -h|--help|help) sed -n '2,52p' "$0" ;;
    *) echo "unknown command: $1" >&2
       echo "try: arm | verify | solution | reset" >&2
       exit 2 ;;
  esac
}

main "$@"

# #############################################################################
# SOLUTION — step by step (do not read until you have tried)
# #############################################################################
#
# ROOT CAUSE
#   In ci/run-ci.sh, run_stage() runs each stage as the LEFT side of a pipe so
#   its output can be streamed to the log:
#
#       "$@" | tee -a "$CI_LOG"
#       rc=$?
#
#   In bash, the exit status of a pipeline ($?) is the exit status of its LAST
#   command — here `tee`, which essentially always succeeds. So `rc` is 0 even
#   when stage_test returned 1. The `if [ "$rc" -ne 0 ]` guard never fires, none
#   of the `run_stage ... ||` shortcuts trigger, and control falls through to:
#
#       echo "Pipeline: SUCCESS"
#       exit 0
#
#   The real status was thrown away by tee. Same class of bug as piping a build
#   through `tee build.log` in a Makefile, or `kubectl apply -f - | tee` in a
#   deploy step: the log is captured, the failure is not.
#
# THE FIX (pick ONE; option A is the idiomatic CI answer)
#
#   A) Turn on pipefail so a pipeline fails if ANY member fails. Add this line
#      to ci/run-ci.sh right after the shebang (line 2):
#
#          set -o pipefail
#
#      With pipefail, `"$@" | tee ...` returns stage_test's non-zero status,
#      rc becomes 1, run_stage returns 1, the `run_stage test ... ||` shortcut
#      fires, and the runner prints "Pipeline: FAILED" and exits 1.
#      (General best practice for CI scripts: begin with `set -euo pipefail`.)
#
#   B) Read the specific pipeline member instead of the pipeline's last status.
#      Replace:
#          rc=$?
#      with:
#          rc=${PIPESTATUS[0]}      # exit status of the FIRST pipe member ("$@")
#      PIPESTATUS is a bash array holding every member's status; index 0 is the
#      stage function. This works even without pipefail.
#
#   C) Don't pipe the status-bearing command at all — capture, then tee:
#          "$@" >"$CI_LOG.stage" 2>&1; rc=$?
#          tee -a "$CI_LOG" <"$CI_LOG.stage"; rm -f "$CI_LOG.stage"
#      More verbose; prefer A or B.
#
# APPLY OPTION A
#       cd "${CNPA_LAB_DIR:-$HOME/cnpa-lab-3.1-ci}"
#       sed -i '1a set -o pipefail' ci/run-ci.sh
#       # (or open ci/run-ci.sh and add `set -o pipefail` after the shebang)
#
# VERIFY THE FIX
#       bash ci/run-ci.sh ; echo "exit=$?"
#   Expected (CORRECT) output now:
#       >>> stage: test
#         FAIL tests/test_add.sh
#       !!! stage 'test' FAILED (rc=1)
#       Pipeline: FAILED
#       exit=1
#
#       ./break_fix.sh verify
#   Expected:
#       RESULT: PASS  — pipeline exited 1 when a stage failed. It tells the truth now.
#
# WHY THIS IS A CI FUNDAMENTAL (exam framing)
#   * Fail fast / fail loud: a pipeline exists to STOP bad changes; a run that
#     cannot fail provides zero protection and manufactures false confidence.
#   * Exit-code propagation is the contract between a job and its orchestrator —
#     GitHub Actions, GitLab CI, Jenkins and Argo Workflows all gate the next
#     step on the previous step's exit code. Any masking (`| tee`, `| cat`, a
#     trailing `|| true`, an un-awaited background job) silently breaks it.
#   * The remedy is a habit: start every CI shell script with `set -euo pipefail`
#     and assert on ${PIPESTATUS[@]} whenever you must keep a pipe.
#
# CLEAN UP
#       ./break_fix.sh reset      # rebuild the broken lab to practise again
#       rm -rf "${CNPA_LAB_DIR:-$HOME/cnpa-lab-3.1-ci}"   # remove it entirely
# #############################################################################