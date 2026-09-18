#!/usr/bin/env bash
#
# ============================================================================
#  701.3 Source Code Management -- break & fix lab
#  LPI DevOps Tools Engineer, exam 701-100, version 2.0.0 (weight 10)
#  Objectives: https://www.lpi.org/our-certifications/exam-701-objectives/
# ============================================================================
#
# WHAT THIS DOES
#   It builds a small Git "platform" under a sandbox directory: one bare
#   repository acting as the SCM server plus a working clone with real history,
#   a feature branch, an annotated tag and a versioned hook directory. Then it
#   plants seven faults that a real team hits: an interrupted rebase, a hook
#   that assumes a tool exists, an ignore rule shipped outside the repository,
#   a commit left on no branch, a server that moved, a diverged branch and a
#   tag that was never published. Your job is to repair all seven.
#
# SAFETY
#   Everything is created under LAB_ROOT (default: ~/lab-701.3-scm). The script
#   never writes to your global or system Git configuration, never calls sudo,
#   never touches the network and never removes a directory it did not create
#   (it checks for its own marker file first). Run it on a disposable lab VM
#   anyway -- that is what break & fix scripts are for.
#
# USAGE
#   ./break_fix.sh              build the lab and print the briefing
#   ./break_fix.sh --verify     grade your repair, objective by objective
#   ./break_fix.sh --brief      print the briefing again
#   ./break_fix.sh --solution   print the walkthrough at the bottom of this file
#   ./break_fix.sh --reset      rebuild the lab from scratch
#   ./break_fix.sh --clean      delete the lab directory
#
# REQUIREMENTS
#   bash 4+, git 2.28 or newer (for "git init -b"). No network, no root.
#

set -euo pipefail

LAB_ROOT=${LAB_ROOT:-$HOME/lab-701.3-scm}
REPO="$LAB_ROOT/deploy-scripts"
ORIGIN_OLD="$LAB_ROOT/origin.git"
ORIGIN_NEW="$LAB_ROOT/srv/deploy-scripts.git"
EXCLUDES="$LAB_ROOT/platform-gitignore"
MARKER="$LAB_ROOT/.lab-701.3-scm"

LAB_NAME="SCM Lab Student"
LAB_MAIL="student@lab.example"

# Subjects and strings the grader looks for. They survive rebase, cherry-pick
# and merge, which is why the checks key off them instead of off SHAs.
SUBJ_TIMEOUT="ops: raise the deploy timeout to 180s"
SUBJ_ROLLBACK="feat: rollback helper for failed deploys"
SUBJ_HOTFIX="fix: quote DEPLOY_ROOT so paths with spaces work"
SUBJ_COLLEAGUE="docs: document the --dry-run flag"
ENTRY_TIMEOUT="- ops: raise the deploy timeout to 180s"
ENTRY_ROLLBACK="- feat: rollback helper for failed deploys"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

say()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Every git call against the student repository goes through this helper.
g() { git -C "$REPO" "$@"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
    command -v git >/dev/null 2>&1 || die "git is not installed."

    local version major minor
    version=$(git --version | awk '{print $3}')
    major=${version%%.*}
    minor=${version#*.}; minor=${minor%%.*}
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 28 ]; }; then
        die "git $version is too old for this lab; 2.28 or newer is required."
    fi

    case "$LAB_ROOT" in
        /|"$HOME"|"") die "LAB_ROOT ($LAB_ROOT) is not a safe sandbox path." ;;
    esac
}

# ---------------------------------------------------------------------------
# Fixture content
# ---------------------------------------------------------------------------

write_fixtures() {
    mkdir -p "$REPO/.githooks" "$REPO/lib" "$REPO/config"

    cat > "$REPO/deploy.sh" <<'SH'
#!/usr/bin/env bash
# deploy-scripts - roll a release out to the fleet.
set -euo pipefail

readonly DEPLOY_TIMEOUT=120
readonly STRATEGY="rolling"
readonly LOCK_FILE="/var/lock/deploy.lock"

usage() {
    echo "usage: ${0##*/} [--dry-run] <environment>"
}

DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/deploy}
. ${DEPLOY_ROOT}/lib/common.sh

main() {
    local environment=${1:-staging}
    log_info "deploying to ${environment} (strategy=${STRATEGY})"
    wait_for_health "${environment}" "${DEPLOY_TIMEOUT}"
    log_info "deploy finished"
}

main "$@"
SH
    chmod 0755 "$REPO/deploy.sh"

    cat > "$REPO/README.md" <<'MD'
# deploy-scripts

Fleet deployment helpers used by the platform team.

    ./deploy.sh staging

Hooks are versioned under `.githooks/` and wired up with
`git config core.hooksPath .githooks` on every fresh clone.
MD

    cat > "$REPO/.gitignore" <<'IGN'
# Repository-local ignores. Anything the team ships fleet-wide lives in the
# shared excludes file instead, so it is NOT listed here.
*.log
tmp/
.venv/
IGN

    # The hook is versioned in-tree: the modern pattern, and the reason
    # core.hooksPath exists. It is also the second planted fault.
    cat > "$REPO/.githooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Platform pre-commit hook: no shell script lands without static analysis.
set -euo pipefail

changed=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.sh$' || true)
[ -z "$changed" ] && exit 0

# shellcheck disable=SC2086
shellcheck --severity=error $changed
echo "pre-commit: shellcheck clean"
HOOK
    chmod 0755 "$REPO/.githooks/pre-commit"

    cat > "$REPO/CHANGELOG.md" <<'MD'
# Changelog

## Unreleased

## v1.4.0 - 2026-08-02
- initial fleet deploy script
- health gate before declaring a deploy successful
MD

    cat > "$REPO/config/prod.env.example" <<'ENV'
# Copy to prod.env and fill in. prod.env itself must never be committed.
DEPLOY_TOKEN=
DEPLOY_ENDPOINT=https://deploy.internal.example/api
ENV
}

commit_at() {  # commit_at <iso-date> <message>
    GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" g commit --quiet -m "$2"
}

# ---------------------------------------------------------------------------
# Build the lab
# ---------------------------------------------------------------------------

build() {
    if [ -e "$LAB_ROOT" ]; then
        die "$LAB_ROOT already exists. Use --reset to rebuild it, or --clean to remove it."
    fi

    say "creating the sandbox in $LAB_ROOT"
    mkdir -p "$LAB_ROOT"
    printf 'lab marker for 701.3 Source Code Management - safe to delete\n' > "$MARKER"

    say "initialising the SCM server (bare repository)"
    git init --quiet --bare -b main "$ORIGIN_OLD"

    say "cloning the working copy"
    git clone --quiet "$ORIGIN_OLD" "$REPO"

    # Repository-local identity only: the student's global config is untouched,
    # and the lab still works on a VM that has no identity configured at all.
    g config user.name "$LAB_NAME"
    g config user.email "$LAB_MAIL"
    g config commit.gpgsign false
    g config gc.auto 0            # keeps the unreachable hotfix alive

    say "writing history"
    write_fixtures

    g add deploy.sh README.md .gitignore .githooks/pre-commit
    commit_at "2026-08-02T09:10:00" "feat: fleet deploy script with a versioned pre-commit hook"

    g add CHANGELOG.md config/prod.env.example
    commit_at "2026-08-02T16:40:00" "docs: changelog and prod env template"

    g push --quiet -u origin main

    GIT_COMMITTER_DATE="2026-08-02T16:45:00" \
        g tag -a v1.4.0 -m "release 1.4.0 - first fleet-wide rollout"

    say "branching feature/rollback"
    g checkout --quiet -b feature/rollback
    cat >> "$REPO/deploy.sh" <<'SH'

rollback() {
    local environment=$1
    log_error "rolling ${environment} back to the previous release"
    wait_for_health "${environment}" "${DEPLOY_TIMEOUT}"
}
SH
    perl -0pi -e "s/## Unreleased\n/## Unreleased\n$ENTRY_ROLLBACK\n/" "$REPO/CHANGELOG.md" \
        2>/dev/null || {
        # perl is optional on a minimal VM; fall back to awk.
        awk -v entry="$ENTRY_ROLLBACK" \
            '{print} /^## Unreleased$/{print entry}' "$REPO/CHANGELOG.md" > "$REPO/.cl" \
            && mv "$REPO/.cl" "$REPO/CHANGELOG.md"
    }
    g add deploy.sh CHANGELOG.md
    commit_at "2026-08-03T11:05:00" "$SUBJ_ROLLBACK"

    say "moving main forward (same changelog slot: this is the conflict)"
    g checkout --quiet main
    sed -i 's/^readonly DEPLOY_TIMEOUT=120$/readonly DEPLOY_TIMEOUT=180/' "$REPO/deploy.sh"
    awk -v entry="$ENTRY_TIMEOUT" \
        '{print} /^## Unreleased$/{print entry}' "$REPO/CHANGELOG.md" > "$REPO/.cl" \
        && mv "$REPO/.cl" "$REPO/CHANGELOG.md"
    g add deploy.sh CHANGELOG.md
    commit_at "2026-08-03T15:20:00" "$SUBJ_TIMEOUT"
    g push --quiet origin main

    say "a colleague pushes while you are not looking"
    local mate="$LAB_ROOT/.colleague"
    git clone --quiet "$ORIGIN_OLD" "$mate"
    git -C "$mate" config user.name "Ana Ops"
    git -C "$mate" config user.email "ana@ops.example"
    git -C "$mate" config commit.gpgsign false
    printf '\n## Flags\n\n- `--dry-run` prints the plan and exits without touching the fleet.\n' \
        >> "$mate/README.md"
    git -C "$mate" add README.md
    GIT_AUTHOR_DATE="2026-08-04T08:30:00" GIT_COMMITTER_DATE="2026-08-04T08:30:00" \
        git -C "$mate" commit --quiet -m "$SUBJ_COLLEAGUE"
    git -C "$mate" push --quiet origin main
    rm -rf "$mate"

    # ---- fault 4: a commit made on a detached HEAD and then abandoned -------
    say "planting the lost hotfix"
    g -c advice.detachedHead=false checkout --quiet --detach main
    sed -i 's|^\. \${DEPLOY_ROOT}/lib/common\.sh$|. "${DEPLOY_ROOT}/lib/common.sh"|' "$REPO/deploy.sh"
    g add deploy.sh
    commit_at "2026-08-04T19:55:00" "$SUBJ_HOTFIX"
    g checkout --quiet main 2>/dev/null

    # ---- fault 3: an ignore rule that lives outside the repository ----------
    say "planting the fleet-wide excludes file"
    cat > "$EXCLUDES" <<'IGN'
# Shipped by the platform team to every workstation via configuration
# management, wired up with: git config core.excludesFile <this file>
*.env
*.retry
common*
build/
IGN
    g config core.excludesFile "$EXCLUDES"

    cat > "$REPO/lib/common.sh" <<'SH'
#!/usr/bin/env bash
# Shared helpers sourced by deploy.sh.

log_info()  { printf '[INFO ] %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

wait_for_health() {
    local environment=$1 timeout=$2
    log_info "waiting up to ${timeout}s for ${environment} to report healthy"
    return 0
}
SH
    chmod 0755 "$REPO/lib/common.sh"

    printf 'DEPLOY_TOKEN=lab-placeholder-not-a-real-secret\nDEPLOY_ENDPOINT=https://deploy.internal.example/api\n' \
        > "$REPO/config/prod.env"
    chmod 0600 "$REPO/config/prod.env"

    # ---- fault 2: hooks are wired up, and the hook assumes shellcheck -------
    g config core.hooksPath "$REPO/.githooks"

    # ---- fault 5: the SCM server was migrated to a new path -----------------
    say "migrating the SCM server (the clone does not know yet)"
    mkdir -p "$LAB_ROOT/srv"
    mv "$ORIGIN_OLD" "$ORIGIN_NEW"

    # ---- fault 1: leave the repository in the middle of a rebase -----------
    say "leaving a rebase half-finished"
    g checkout --quiet feature/rollback
    if GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true g rebase main >/dev/null 2>&1; then
        die "the planted rebase did not conflict; the lab would be trivial. Aborting."
    fi
    if [ ! -d "$REPO/.git/rebase-merge" ] && [ ! -d "$REPO/.git/rebase-apply" ]; then
        die "the rebase stopped for an unexpected reason; lab state is not valid."
    fi

    say "lab ready"
    echo
    brief
}

# ---------------------------------------------------------------------------
# Briefing
# ---------------------------------------------------------------------------

brief() {
    cat <<EOF
${C_BOLD}=============================================================================
 701.3 SOURCE CODE MANAGEMENT -- BREAK & FIX
=============================================================================${C_RESET}

Sandbox      : $LAB_ROOT
Your clone   : $REPO
SCM server   : $ORIGIN_NEW  (it did not always live there)

Start with:  cd "$REPO"

${C_BOLD}THE STORY${C_RESET}
  You took over the deploy-scripts repository this morning. The previous owner
  left mid-rebase, the CI clone cannot even start deploy.sh, a hotfix everybody
  remembers reviewing is on no branch, and the release automation says tag
  v1.4.0 does not exist. Nothing here is corrupt: every fault is ordinary Git
  state or ordinary Git configuration.

${C_BOLD}SYMPTOMS YOU WILL SEE${C_RESET}
  1. git status opens with "You are currently rebasing branch 'feature/rollback'"
     and CHANGELOG.md is listed as "both modified", with conflict markers in it.
  2. Every commit dies with "shellcheck: command not found" and the commit is
     not created. The repository has no .git/hooks content, so grepping there
     explains nothing.
  3. git status is clean, yet lib/common.sh exists in the worktree and a fresh
     clone of this repository cannot run deploy.sh:
     "line 14: /srv/deploy/lib/common.sh: No such file or directory".
     git add lib/common.sh answers "paths are ignored by one of your .gitignore
     files" -- and .gitignore says nothing about it.
  4. The hotfix that quotes DEPLOY_ROOT is in no branch: neither git log main
     nor git branch --contains can find it. It was committed, not imagined.
  5. git fetch and git push fail with
     "fatal: '$ORIGIN_OLD' does not appear to be a git repository".
  6. Once the remote answers again, git push is rejected: "! [rejected]
     main -> main (fetch first)". Somebody else pushed while you were away.
  7. git tag shows v1.4.0, git ls-remote --tags origin shows nothing. The
     release job keys off the tag on the server, so the release is invisible.

${C_BOLD}OBJECTIVES -- what you must achieve${C_RESET}
  1. No Git operation left in progress, and feature/rollback sits on top of
     main's timeout commit with BOTH changelog entries kept and no markers.
  2. Commits succeed without --no-verify, the hook still exists and is still
     executable, and it must not break on a machine that has no shellcheck.
  3. lib/common.sh is tracked on main, while config/prod.env stays untracked
     AND stays ignored. Fix the rule, do not just force-add the file.
  4. The lost hotfix commit is part of main's history, with its content.
  5. origin points at the repository's real location.
  6. main contains your colleague's commit and origin/main equals your main.
     Do not force-push: the grader checks that their commit survived.
  7. The annotated tag v1.4.0 exists on the server, still annotated.

${C_BOLD}RULES OF ENGAGEMENT${C_RESET}
  - Do not delete and re-clone: every objective is about recovering state.
  - --no-verify, git add -f and git push --force each make one symptom
    disappear while leaving the cause armed. The grader knows.
  - Useful instruments: git status, git log --oneline --graph --all,
    git reflog, git fsck --lost-found, git check-ignore -v, git config
    --local --list --show-origin, git ls-remote, git diff --check.

${C_BOLD}GRADE YOUR WORK${C_RESET}
  $0 --verify

EOF
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

PASSED=0
FAILED=0

check() {  # check <title> <function> <hint>
    local title=$1 fn=$2 hint=$3
    if "$fn" >/dev/null 2>&1; then
        printf '  %s[ PASS ]%s %s\n' "$C_GREEN" "$C_RESET" "$title"
        PASSED=$((PASSED + 1))
    else
        printf '  %s[ FAIL ]%s %s\n' "$C_RED" "$C_RESET" "$title"
        printf '           %s\n' "$hint"
        FAILED=$((FAILED + 1))
    fi
}

has_subject() {  # has_subject <rev> <subject>
    g log --format=%s "$1" 2>/dev/null | grep -qxF "$2"
}

v1_rebase() {
    [ -d "$REPO/.git/rebase-merge" ] && return 1
    [ -d "$REPO/.git/rebase-apply" ] && return 1
    [ -f "$REPO/.git/MERGE_HEAD" ] && return 1
    [ -f "$REPO/.git/CHERRY_PICK_HEAD" ] && return 1
    g rev-parse --verify --quiet feature/rollback >/dev/null || return 1
    has_subject feature/rollback "$SUBJ_ROLLBACK" || return 1
    has_subject feature/rollback "$SUBJ_TIMEOUT"  || return 1

    local changelog
    changelog=$(g show feature/rollback:CHANGELOG.md) || return 1
    grep -qF "$ENTRY_ROLLBACK" <<<"$changelog" || return 1
    grep -qF "$ENTRY_TIMEOUT"  <<<"$changelog" || return 1
    grep -qE '^(<{7}|={7}|>{7})' <<<"$changelog" && return 1
    return 0
}

hook_path() {
    local configured
    configured=$(g config --get core.hooksPath 2>/dev/null || true)
    if [ -n "$configured" ]; then
        case "$configured" in
            /*) printf '%s/pre-commit\n' "$configured" ;;
            *)  printf '%s/%s/pre-commit\n' "$REPO" "$configured" ;;
        esac
    else
        printf '%s/.git/hooks/pre-commit\n' "$REPO"
    fi
}

v2_hook() {
    local hook; hook=$(hook_path)
    [ -x "$hook" ] || return 1

    # Probe on a throwaway copy of the repository, so grading never mutates
    # the student's work. The copy inherits the same config, hence the same
    # hook and the same excludes file.
    local tmp rc=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scm701-probe.XXXXXX") || return 1
    if cp -a "$REPO" "$tmp/copy" >/dev/null 2>&1 && (
        cd "$tmp/copy" || exit 1
        rm -rf .git/rebase-merge .git/rebase-apply .git/MERGE_HEAD .git/CHERRY_PICK_HEAD
        git checkout --quiet -f -B hook-probe main || exit 1
        printf '\n# hook probe\n' >> deploy.sh
        git add deploy.sh || exit 1
        git commit --quiet -m "chore: hook probe" || exit 1
    ); then rc=0; else rc=1; fi
    rm -rf "$tmp"
    return $rc
}

v3_common() {
    g ls-tree -r --name-only main -- lib/common.sh | grep -qx 'lib/common.sh' || return 1
    g show main:lib/common.sh | grep -q 'wait_for_health' || return 1
    # The over-broad rule must be gone ...
    g check-ignore -q -- lib/common.sh && return 1
    # ... and the secret must still be ignored and still untracked.
    g check-ignore -q -- config/prod.env || return 1
    g ls-files --error-unmatch config/prod.env >/dev/null 2>&1 && return 1
    return 0
}

v4_hotfix() {
    has_subject main "$SUBJ_HOTFIX" || return 1
    g show main:deploy.sh | grep -qF '. "${DEPLOY_ROOT}/lib/common.sh"' || return 1
    return 0
}

v5_remote() {
    g ls-remote origin >/dev/null 2>&1
}

v6_published() {
    has_subject main "$SUBJ_COLLEAGUE" || return 1
    local remote_sha local_sha
    remote_sha=$(g ls-remote origin refs/heads/main 2>/dev/null | awk '{print $1}')
    local_sha=$(g rev-parse main 2>/dev/null)
    [ -n "$remote_sha" ] && [ "$remote_sha" = "$local_sha" ]
}

v7_tag() {
    local refs
    refs=$(g ls-remote --tags origin 2>/dev/null) || return 1
    grep -q 'refs/tags/v1\.4\.0$'      <<<"$refs" || return 1
    grep -q 'refs/tags/v1\.4\.0\^{}$'  <<<"$refs" || return 1   # proves annotated
    return 0
}

verify() {
    [ -d "$REPO/.git" ] || die "no lab at $REPO. Run $0 with no arguments first."

    printf '\n%s701.3 break & fix -- grading%s\n\n' "$C_BOLD" "$C_RESET"
    check "1. rebase finished, both changelog entries kept" v1_rebase \
        "git status must be free of any in-progress operation, and feature/rollback must contain main's timeout commit plus its own, with both CHANGELOG lines and no conflict markers."
    check "2. pre-commit hook repaired, commits work without --no-verify" v2_hook \
        "The hook must still exist and be executable, and a normal commit must succeed on a machine without shellcheck."
    check "3. lib/common.sh tracked, config/prod.env still ignored" v3_common \
        "Track lib/common.sh on main by narrowing the ignore rule (git check-ignore -v shows which file and line), and leave *.env hiding config/prod.env."
    check "4. lost hotfix recovered onto main" v4_hotfix \
        "The commit '$SUBJ_HOTFIX' must be reachable from main -- git reflog, then cherry-pick."
    check "5. origin points at the migrated repository" v5_remote \
        "git remote set-url origin $ORIGIN_NEW"
    check "6. history integrated and published without force" v6_published \
        "main must contain '$SUBJ_COLLEAGUE' and origin/main must equal main."
    check "7. annotated tag v1.4.0 published" v7_tag \
        "git push origin v1.4.0 -- git push alone never sends tags."

    printf '\n  %s%d passed%s, %s%d failed%s\n\n' \
        "$C_GREEN" "$PASSED" "$C_RESET" "$C_RED" "$FAILED" "$C_RESET"
    if [ "$FAILED" -eq 0 ]; then
        printf '  %sAll seven objectives met.%s\n\n' "$C_BOLD" "$C_RESET"
        return 0
    fi
    printf '  Stuck? %s --solution\n\n' "$0"
    return 1
}

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

clean() {
    if [ ! -e "$LAB_ROOT" ]; then
        say "nothing to clean: $LAB_ROOT does not exist"
        return 0
    fi
    [ -f "$MARKER" ] || die "$LAB_ROOT has no lab marker; refusing to delete it."
    say "removing $LAB_ROOT"
    rm -rf "$LAB_ROOT"
}

solution() {
    sed -n '/^# ==== SOLUTION START/,/^# ==== SOLUTION END/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
}

main() {
    preflight
    case "${1:-}" in
        "")             build ;;
        --verify|-v)    verify ;;
        --brief|-b)     brief ;;
        --solution|-s)  solution ;;
        --reset|-r)     clean; build ;;
        --clean|-c)     clean ;;
        --help|-h)      sed -n '2,32p' "$0" | sed 's/^#\{1,\} \{0,1\}//' ;;
        *)              die "unknown option: $1 (try --help)" ;;
    esac
}

main "$@"
exit $?

# ==== SOLUTION START =========================================================
#
#  SPOILERS. Read only after you have worked the symptoms.
#  Every step below is one of the seven objectives, in the order that hurts
#  least: repair the tooling first, then the history, then the server.
#
#  0. Orient yourself.
#
#       cd ~/lab-701.3-scm/deploy-scripts
#       git status
#       git log --oneline --graph --all --decorate
#       git config --local --list --show-origin
#
#     That last command is the one most people skip, and it is where two of
#     the seven faults are sitting in plain sight: core.hooksPath and
#     core.excludesFile. Configuration is part of the repository's state.
#
#  1. OBJECTIVE 2 first -- the hook blocks every commit the rest of the work
#     needs.
#
#       git config --get core.hooksPath     # .../deploy-scripts/.githooks
#       cat .githooks/pre-commit
#
#     The hook calls shellcheck unconditionally. On a box without it, the
#     shell returns 127, `set -e` propagates it, the hook exits non-zero and
#     git aborts the commit. The correct repair is graceful degradation --
#     insert before the shellcheck call:
#
#       if ! command -v shellcheck >/dev/null 2>&1; then
#           echo "pre-commit: shellcheck not installed, skipping analysis" >&2
#           exit 0
#       fi
#
#     Installing the tool (dnf install ShellCheck / apt install shellcheck)
#     also makes commits pass, and the grader accepts it -- but a hook that
#     assumes a binary exists breaks on every fresh clone and in CI, so fix
#     the hook as well. `git commit --no-verify` is not a fix: it disables the
#     control for you only, and silently.
#
#       chmod +x .githooks/pre-commit       # hooks must stay executable
#
#  2. OBJECTIVE 1 -- finish the rebase.
#
#       git status                 # both modified: CHANGELOG.md
#       git diff --check           # points at the conflict markers
#       git log --oneline REBASE_HEAD -1    # the commit being replayed
#
#     Edit CHANGELOG.md, keep BOTH entries under "## Unreleased", delete the
#     <<<<<<< ======= >>>>>>> lines, then:
#
#       git add CHANGELOG.md
#       git rebase --continue
#
#       git log --oneline main..feature/rollback   # only the rollback commit
#       git log --oneline -3 feature/rollback      # main's commit underneath
#
#     `git rebase --abort` also clears the state, and is the right move when a
#     rebase surprises you -- but here it throws the integration away, and
#     objective 1 checks that main's timeout commit is in the branch history.
#     If you aborted, just rebase again: git rebase main feature/rollback.
#
#  3. OBJECTIVE 3 -- the file that nobody can commit.
#
#       git checkout main
#       git status                    # clean; lib/common.sh is invisible
#       git add lib/common.sh
#         -> The following paths are ignored by one of your .gitignore files
#       git check-ignore -v lib/common.sh
#         -> /home/you/lab-701.3-scm/platform-gitignore:6:common*  lib/common.sh
#
#     The rule is not in .gitignore. It comes from the fleet-wide excludes
#     file that core.excludesFile points at:
#
#       git config --get core.excludesFile
#
#     `common*` was meant for a build artefact and also swallows lib/common.sh.
#     Narrow it; do NOT delete the file, because `*.env` in it is what keeps
#     config/prod.env out of the repository:
#
#       sed -i '/^common\*$/d' "$(git config --get core.excludesFile)"
#       git check-ignore -v lib/common.sh     # no output, exit status 1
#       git check-ignore -v config/prod.env   # still matched by *.env
#
#     Now commit the file and the repaired hook together:
#
#       git add lib/common.sh .githooks/pre-commit
#       git commit -m "fix: ship lib/common.sh and make the pre-commit hook optional"
#
#     `git add -f lib/common.sh` would track the file and leave the trap armed
#     for the next person; objective 3 checks the rule, not just the blob.
#
#  4. OBJECTIVE 4 -- recover the commit that is on no branch.
#
#       git log --oneline -5 main            # not there
#       git reflog | head -20                # "checkout: moving from <sha> to main"
#       git log --oneline --walk-reflogs -20 # same information, per ref
#
#     If the reflog had already expired (90 days by default for reachable
#     entries, 30 for unreachable ones), the object itself is still in the
#     database until gc runs:
#
#       git fsck --lost-found --no-reflogs   # dangling commit <sha>
#
#     Inspect and bring it over:
#
#       git show <sha>
#       git branch rescue/quoting <sha>      # optional safety net first
#       git cherry-pick <sha>
#       git log --oneline -2 main
#       git show main:deploy.sh | grep DEPLOY_ROOT
#
#     Reflog entries are per-repository and never pushed: this only works in
#     the clone where the commit was created. That is why abandoned work is
#     recoverable locally and gone everywhere else.
#
#  5. OBJECTIVE 5 -- the server moved.
#
#       git remote -v
#       git fetch origin
#         -> fatal: '.../origin.git' does not appear to be a git repository
#       ls ~/lab-701.3-scm/srv                # deploy-scripts.git
#       git remote set-url origin ~/lab-701.3-scm/srv/deploy-scripts.git
#       git ls-remote origin
#
#     git remote set-url rewrites remote.origin.url in .git/config; the
#     upstream tracking configuration (branch.main.remote/merge) is untouched,
#     which is why `git push` with no arguments starts working again.
#
#  6. OBJECTIVE 6 -- diverged branch.
#
#       git push
#         -> ! [rejected] main -> main (fetch first)
#       git fetch origin
#       git log --oneline main..origin/main    # their commit
#       git log --oneline origin/main..main    # yours
#       git pull --rebase origin main          # or: git merge origin/main
#       git push origin main
#
#     A rebase gives a linear history and rewrites your local commits' SHAs --
#     safe here because they were never published. `git push --force` would
#     "work" too, and would delete your colleague's commit from the server;
#     the grader checks that it is still in main's history. When you genuinely
#     must overwrite a remote branch, use --force-with-lease, which refuses if
#     the remote moved since your last fetch.
#
#  7. OBJECTIVE 7 -- publish the tag.
#
#       git tag -n                     # v1.4.0 is local
#       git ls-remote --tags origin    # empty: push never sends tags
#       git push origin v1.4.0         # or: git push --follow-tags
#       git ls-remote --tags origin
#         -> <sha> refs/tags/v1.4.0
#         -> <sha> refs/tags/v1.4.0^{}
#
#     The ^{} line is the dereferenced commit: its presence is what proves the
#     tag is annotated (a real object with tagger, date and message) rather
#     than a lightweight ref. Releases should always be annotated -- and
#     signed (git tag -s) where a key is available. Prefer `git push
#     --follow-tags` over `git push --tags`: the former sends only annotated
#     tags reachable from what you are pushing, the latter sends every local
#     tag you happen to have, including experiments.
#
#  8. Grade it.
#
#       ./break_fix.sh --verify        # expect 7 passed, 0 failed
#
#  WHAT THE LAB IS ACTUALLY TEACHING
#    - Git state lives in three places: the object database, the refs, and the
#      configuration. Two of these seven faults were pure configuration.
#    - Nothing committed is lost until gc prunes it; reflog and fsck are the
#      two doors into unreachable objects.
#    - --no-verify, add -f and push --force each silence a symptom and keep
#      the cause. In a team, the cause is what hurts the next person.
#    - Hooks are local by default; core.hooksPath plus a versioned .githooks
#      directory is how a team ships them, and it is the first place to look
#      when a commit is rejected by something you cannot find.
#
#  Reference: LPI Exam 701-100 objectives, topic 701.3 Source Code Management
#  https://www.lpi.org/our-certifications/exam-701-objectives/
#  Git documentation: https://git-scm.com/docs (git-rebase, git-reflog,
#  git-check-ignore, githooks, gitignore, git-push)
#
# ==== SOLUTION END ===========================================================