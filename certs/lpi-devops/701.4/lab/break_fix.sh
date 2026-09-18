#!/usr/bin/env bash
#
# ============================================================================
#  break & fix lab — LPI DevOps Tools Engineer, exam 701-100 v2.0.0
#  Topic 701.4  Continuous Integration and Continuous Delivery  (weight 5)
#  Source of objectives: https://www.lpi.org/our-certifications/exam-701-objectives/
# ============================================================================
#
#  WHAT THIS SCRIPT BUILDS
#  -----------------------
#  A complete, offline CI/CD system under /opt/cicd-lab, with the same moving
#  parts every real pipeline has, and nothing else:
#
#      /opt/cicd-lab/repo.git      bare git repository            (the SCM)
#      /opt/cicd-lab/src           developer working clone
#      hooks/post-receive          the trigger                    (the "webhook")
#      /var/spool/mini-ci/*.trigger  the job queue
#      mini-ci.path + mini-ci.service   the runner/agent          (systemd)
#      /usr/local/bin/mini-ci      the runner itself, reads .ci/pipeline.yml
#      /opt/cicd-lab/artifacts/    the artifact repository        (versioned)
#      /opt/cicd-lab/releases/     immutable releases
#      /opt/cicd-lab/current       symlink switch                 (the deploy)
#      demo-app.service            the deployed app on port 18080
#
#  It then injects FIVE faults, one in each layer of the pipeline, and leaves
#  the student with a red pipeline, a stale production symlink, and the same
#  tools a real engineer has: git, systemctl, journalctl and the run logs.
#
#  SAFETY
#  ------
#  Everything is confined to /opt/cicd-lab, /var/spool/mini-ci,
#  /usr/local/bin/{mini-ci,cicd-lab-verify} and three unit files in
#  /etc/systemd/system. No package is installed, no firewall or network
#  configuration is touched, no existing service is modified, nothing outside
#  those paths is written or deleted. `clean` removes all of it.
#  Run it on a DISPOSABLE lab VM anyway: it creates and destroys system units.
#
#  USAGE
#  -----
#      ./break_fix.sh            build the lab and break it   (default)
#      ./break_fix.sh setup      build a healthy lab only
#      ./break_fix.sh break      build, then inject the faults
#      ./break_fix.sh verify     grade the repair, stage by stage
#      ./break_fix.sh hint [1-3] progressive hints
#      ./break_fix.sh clean      remove every trace of the lab
#      ./break_fix.sh --yes ...  skip the interactive confirmation
#
#  The full step-by-step solution is at the END of this file, commented out.
#  Do not read it before you have spent time with `journalctl -u mini-ci`.
#
set -euo pipefail

LAB_ROOT=/opt/cicd-lab
SPOOL=/var/spool/mini-ci
REPO="$LAB_ROOT/repo.git"
SRC="$LAB_ROOT/src"
RELEASES="$LAB_ROOT/releases"
ARTIFACTS="$LAB_ROOT/artifacts"
PIPELINES="$LAB_ROOT/pipelines"
CURRENT="$LAB_ROOT/current"
RUNNER=/usr/local/bin/mini-ci
VERIFIER=/usr/local/bin/cicd-lab-verify
UNIT_DIR=/etc/systemd/system
APP_PORT=18080

ASSUME_YES=no

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '[lab] %s\n' "$*"; }
warn() { printf '[lab] WARNING %s\n' "$*" >&2; }
die()  { printf '[lab] ERROR %s\n' "$*" >&2; exit 1; }

rule() { printf '%s\n' "----------------------------------------------------------------------"; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "run this as root (sudo $0 $*)"
}

require_systemd() {
    [[ -d /run/systemd/system ]] || die "systemd is not PID 1 here; this lab needs systemd units"
}

require_tools() {
    local missing=()
    local t
    for t in git tar sha256sum awk sed install systemctl journalctl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    (( ${#missing[@]} == 0 )) || die "missing required commands -> ${missing[*]}"
}

confirm_disposable() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    if [[ ! -t 0 ]]; then
        die "not a terminal; re-run with --yes if this really is a disposable lab VM"
    fi
    rule
    say "This creates system units and rewrites $LAB_ROOT from scratch."
    say "Only run it on a throwaway lab VM."
    rule
    local answer=""
    read -r -p "Type BREAK to continue, anything else to abort: " answer
    [[ "$answer" == "BREAK" ]] || die "aborted by the user"
}

# ---------------------------------------------------------------------------
# the runner: /usr/local/bin/mini-ci
#
# A ~200 line CI runner. It does what GitLab Runner and a Jenkins agent do,
# minus the distribution: take a commit, get a clean workspace, validate the
# pipeline definition, run stage by stage, archive declared artifacts, and
# record the result. Reading it is part of the lab.
# ---------------------------------------------------------------------------
write_runner() {
    cat > "$RUNNER" <<'MINICI'
#!/usr/bin/env bash
#
# mini-ci - a minimal CI/CD runner for the 701.4 lab.
#
# Pipeline definition: .ci/pipeline.yml in the repository (GitLab CI shape).
# Trigger: files dropped in /var/spool/mini-ci by the post-receive hook.
# Invocation: systemd (mini-ci.path -> mini-ci.service), or `mini-ci run`.
#
# Deliberate simplification versus a real runner: all stages of one pipeline
# share a single workspace, so the "dist/" directory survives from build to
# deploy. Declared artifacts are still uploaded to the artifact repository,
# and the deploy stage consumes them from there - exactly as it would if the
# stages ran on different agents.

set -uo pipefail

LAB_ROOT=/opt/cicd-lab
SPOOL=/var/spool/mini-ci
REPO="$LAB_ROOT/repo.git"
WORKSPACE="$LAB_ROOT/workspace"
ARTIFACTS_ROOT="$LAB_ROOT/artifacts"
PIPELINES="$LAB_ROOT/pipelines"
PIPELINE_FILE=".ci/pipeline.yml"
LOCK=/run/mini-ci.lock

log()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

usage() {
    cat >&2 <<'USAGE'
usage: mini-ci <command>

  run              consume the trigger queue and execute the pipelines
  trigger [sha]    queue a pipeline by hand (source=manual)
  lint [file]      validate a pipeline definition and exit
  status           show the result of the last pipeline
  logs [id]        print the log of a pipeline (default the last one)
  queue            list pending triggers
USAGE
    exit 64
}

# --- pipeline definition ---------------------------------------------------
#
# Syntax validation first. Every one of these rules exists because it has
# silently broken somebody's pipeline.

ci_lint() {
    local file="$1"
    [[ -f "$file" ]] || { fail "no pipeline definition at $file"; return 1; }

    local out rc=0
    out="$(awk '
        /\t/ {
            printf "  line %d  tab character: YAML forbids tabs for indentation\n", NR; bad++
        }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_.-]*:[^[:space:]]/ {
            printf "  line %d  no space after the colon -> %s\n", NR, $0; bad++
        }
        /^[[:space:]]*-[[:space:]]+\*/ {
            printf "  line %d  list item starts with an asterisk, YAML reads it as an alias, quote it -> %s\n", NR, $0; bad++
        }
        /:[[:space:]]+\*[^ ]/ {
            printf "  line %d  value starts with an asterisk, quote it -> %s\n", NR, $0; bad++
        }
        END { exit (bad ? 1 : 0) }
    ' "$file")" || rc=1

    if (( rc != 0 )); then
        fail "pipeline definition is not valid YAML"
        printf '%s\n' "$out" >&2
        return 1
    fi

    # structural check: every job must declare a stage that exists
    local declared job stage
    declared=" $(ci_stages "$file" | tr '\n' ' ') "
    while read -r job stage; do
        [[ -n "$job" ]] || continue
        case "$declared" in
            *" $stage "*) ;;
            *) fail "job \"$job\" declares stage \"$stage\", which is not in the stages list"; rc=1 ;;
        esac
    done < <(ci_job_stages "$file")

    return $rc
}

ci_stages() {
    awk '
        /^stages:[[:space:]]*$/ { s = 1; next }
        s && /^[[:space:]]+-[[:space:]]+/ {
            v = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", v); gsub(/"/, "", v); print v; next
        }
        s && /^[^[:space:]#]/ { s = 0 }
    ' "$1"
}

ci_job_stages() {
    awk '
        /^[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ { j = $0; sub(/:[[:space:]]*$/, "", j); next }
        j != "" && /^[[:space:]]+stage:[[:space:]]+/ {
            v = $0; sub(/^[[:space:]]+stage:[[:space:]]+/, "", v); gsub(/"/, "", v); print j, v
        }
    ' "$1"
}

ci_jobs_in_stage() {
    awk -v want="$2" '
        /^[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ { j = $0; sub(/:[[:space:]]*$/, "", j); next }
        j != "" && /^[[:space:]]+stage:[[:space:]]+/ {
            v = $0; sub(/^[[:space:]]+stage:[[:space:]]+/, "", v); gsub(/"/, "", v)
            if (v == want) print j
        }
    ' "$1"
}

ci_script() {
    awk -v want="$2" '
        /^[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ { j = $0; sub(/:[[:space:]]*$/, "", j); inlist = 0; next }
        j == want && /^[[:space:]]+script:[[:space:]]*$/ { inlist = 1; next }
        inlist && /^[[:space:]]+-[[:space:]]+/ {
            v = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", v); print v; next
        }
        inlist && /^[[:space:]]+[A-Za-z_]/ { inlist = 0 }
    ' "$1"
}

ci_artifact_paths() {
    awk -v want="$2" '
        /^[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ { j = $0; sub(/:[[:space:]]*$/, "", j); art = 0; paths = 0; next }
        j == want && /^[[:space:]]+artifacts:[[:space:]]*$/ { art = 1; next }
        art && /^[[:space:]]+paths:[[:space:]]*$/ { paths = 1; next }
        paths && /^[[:space:]]+-[[:space:]]+/ {
            v = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", v); gsub(/"/, "", v); print v; next
        }
        paths && /^[[:space:]]+[A-Za-z_]/ { paths = 0; art = 0 }
    ' "$1"
}

ci_variables() {
    awk '
        /^variables:[[:space:]]*$/ { v = 1; next }
        v && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+/ {
            line = $0; sub(/^[[:space:]]+/, "", line)
            k = line; sub(/:.*$/, "", k)
            val = line; sub(/^[^:]*:[[:space:]]+/, "", val); gsub(/"/, "", val)
            printf "%s=%s\n", k, val; next
        }
        v && /^[^[:space:]#]/ { v = 0 }
    ' "$1"
}

# --- artifact handling -----------------------------------------------------

collect_artifacts() {
    local job="$1" dest="$ARTIFACTS_ROOT/$VERSION"
    local pattern total=0
    local -a matched

    while IFS= read -r pattern; do
        [[ -n "$pattern" ]] || continue
        shopt -s nullglob
        # shellcheck disable=SC2206  # the glob is the point here
        matched=( $pattern )
        shopt -u nullglob
        if (( ${#matched[@]} == 0 )); then
            log "    artifacts: no file matched \"$pattern\", nothing uploaded for this path"
            continue
        fi
        install -d "$dest"
        cp -a "${matched[@]}" "$dest"/
        total=$(( total + ${#matched[@]} ))
        log "    artifacts: uploaded ${#matched[@]} file(s) matching \"$pattern\""
    done < <(ci_artifact_paths "$PIPELINE_FILE" "$job")

    (( total > 0 )) && log "    artifacts: $total file(s) in $dest"
    return 0
}

# --- the pipeline ----------------------------------------------------------

run_pipeline() {
    local id="$1" sha="$2" ref="$3" source="$4"
    local status_file="$PIPELINES/$id.status"
    local result=failed stage job line rc=0

    log "pipeline $id"
    log "  commit $sha on $ref, triggered by $source"

    rm -rf "$WORKSPACE"
    if ! git clone --quiet "$REPO" "$WORKSPACE"; then
        fail "  could not clone $REPO"
        write_status "$status_file" "$id" "$sha" "$ref" "$source" "" failed
        return 1
    fi
    cd "$WORKSPACE" || return 1
    git checkout --quiet "$sha" || { fail "  commit $sha not found"; return 1; }

    local base="0.0.0"
    [[ -f VERSION ]] && base="$(tr -d '[:space:]' < VERSION)"
    VERSION="${base}-g${sha:0:7}"
    export VERSION
    export CI_PIPELINE_ID="$id"
    export CI_COMMIT_SHA="$sha"
    export CI_COMMIT_REF_NAME="${ref#refs/heads/}"
    log "  version $VERSION"

    if ! ci_lint "$PIPELINE_FILE"; then
        fail "  pipeline aborted before the first stage"
        write_status "$status_file" "$id" "$sha" "$ref" "$source" "$VERSION" failed
        return 1
    fi
    log "  pipeline definition ok"

    local k v
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] || continue
        export "$k=$v"
        log "  variable $k=$v"
    done < <(ci_variables "$PIPELINE_FILE")

    for stage in $(ci_stages "$PIPELINE_FILE"); do
        log "  stage $stage"
        for job in $(ci_jobs_in_stage "$PIPELINE_FILE" "$stage"); do
            log "    job $job"
            while IFS= read -r line; do
                [[ -n "${line// /}" ]] || continue
                log "      \$ $line"
                bash -c "$line"
                rc=$?
                if (( rc != 0 )); then
                    fail "    job $job FAILED with exit code $rc"
                    fail "    failing command -> $line"
                    write_status "$status_file" "$id" "$sha" "$ref" "$source" "$VERSION" failed
                    return 1
                fi
            done < <(ci_script "$PIPELINE_FILE" "$job")
            collect_artifacts "$job"
            log "    job $job passed"
        done
    done

    result=success
    log "  pipeline $id SUCCESS"
    write_status "$status_file" "$id" "$sha" "$ref" "$source" "$VERSION" "$result"
    return 0
}

write_status() {
    local file="$1"
    install -d "$(dirname "$file")"
    {
        printf 'id=%s\n'       "$2"
        printf 'sha=%s\n'      "$3"
        printf 'ref=%s\n'      "$4"
        printf 'source=%s\n'   "$5"
        printf 'version=%s\n'  "$6"
        printf 'result=%s\n'   "$7"
        printf 'finished=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$file"
}

field() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$2"; }

# --- commands --------------------------------------------------------------

cmd_run() {
    exec 9>"$LOCK" || exit 1
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || { log "another pipeline holds the lock, giving up"; exit 0; }
    fi

    shopt -s nullglob
    local -a triggers=( "$SPOOL"/*.trigger )
    shopt -u nullglob

    if (( ${#triggers[@]} == 0 )); then
        log "the queue is empty, nothing to do"
        exit 0
    fi

    install -d "$PIPELINES"
    local t sha ref source id log_file rc=0 prc
    for t in "${triggers[@]}"; do
        sha="$(field sha "$t")"
        ref="$(field ref "$t")"
        source="$(field source "$t")"
        [[ -n "$sha" ]] || { fail "malformed trigger $t"; rm -f "$t"; continue; }
        rm -f "$t"

        id="$(date -u +%Y%m%d-%H%M%S)-${sha:0:7}"
        log_file="$PIPELINES/$id.log"
        run_pipeline "$id" "$sha" "${ref:-refs/heads/main}" "${source:-unknown}" 2>&1 | tee -a "$log_file"
        prc=${PIPESTATUS[0]}
        printf '%s\n' "$id" > "$PIPELINES/latest"
        (( prc == 0 )) || rc=1
    done
    exit $rc
}

cmd_trigger() {
    local sha="${1:-}"
    [[ -n "$sha" ]] || sha="$(git --git-dir="$REPO" rev-parse refs/heads/main)"
    install -d "$SPOOL"
    local f="$SPOOL/$(date -u +%s)-$$-${sha:0:7}.trigger"
    {
        printf 'sha=%s\n'  "$sha"
        printf 'ref=%s\n'  "refs/heads/main"
        printf 'source=%s\n' "manual"
    } > "$f"
    log "queued a manual pipeline for ${sha:0:7}"
}

cmd_status() {
    local id
    [[ -f "$PIPELINES/latest" ]] || { echo "no pipeline has ever run"; return 1; }
    id="$(cat "$PIPELINES/latest")"
    [[ -f "$PIPELINES/$id.status" ]] || { echo "no status file for $id"; return 1; }
    cat "$PIPELINES/$id.status"
}

cmd_logs() {
    local id="${1:-}"
    [[ -n "$id" ]] || id="$(cat "$PIPELINES/latest" 2>/dev/null || true)"
    [[ -n "$id" && -f "$PIPELINES/$id.log" ]] || { echo "no log for \"$id\""; return 1; }
    cat "$PIPELINES/$id.log"
}

cmd_queue() {
    shopt -s nullglob
    local -a t=( "$SPOOL"/*.trigger )
    shopt -u nullglob
    (( ${#t[@]} )) || { echo "the queue is empty"; return 0; }
    printf '%s pending trigger(s)\n' "${#t[@]}"
    local f
    for f in "${t[@]}"; do printf '  %s -> %s\n' "$(basename "$f")" "$(field sha "$f")"; done
}

case "${1:-}" in
    run)     shift; cmd_run "$@" ;;
    trigger) shift; cmd_trigger "$@" ;;
    lint)    shift; ci_lint "${1:-$PIPELINE_FILE}" && echo "pipeline definition ok" ;;
    status)  shift; cmd_status "$@" ;;
    logs)    shift; cmd_logs "$@" ;;
    queue)   shift; cmd_queue "$@" ;;
    *)       usage ;;
esac
MINICI
    chmod 0755 "$RUNNER"
}

# ---------------------------------------------------------------------------
# the trigger: the post-receive hook of the bare repository
# ---------------------------------------------------------------------------
write_hook() {
    cat > "$REPO/hooks/post-receive" <<'HOOK'
#!/usr/bin/env bash
#
# post-receive - the CI trigger.
#
# git runs this after a successful push, with one line per updated ref on
# stdin. Anything written to stdout travels back to the pushing client, which
# is why a broken hook is easy to miss: the push itself still succeeds.

set -uo pipefail
SPOOL=/var/spool/mini-ci

while read -r oldrev newrev refname; do
    if [[ "$refname" != "refs/heads/main" ]]; then
        echo "mini-ci: $refname is not a pipeline branch, skipped"
        continue
    fi
    if [[ "$newrev" =~ ^0+$ ]]; then
        echo "mini-ci: branch deleted, no pipeline"
        continue
    fi
    install -d -m 0755 "$SPOOL"
    trigger="$SPOOL/$(date -u +%s)-$$-${newrev:0:7}.trigger"
    {
        printf 'sha=%s\n' "$newrev"
        printf 'ref=%s\n' "$refname"
        printf 'source=%s\n' "hook"
    } > "$trigger"
    echo "mini-ci: queued a pipeline for ${newrev:0:7}"
done
HOOK
    chmod 0755 "$REPO/hooks/post-receive"
}

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------
write_units() {
    cat > "$UNIT_DIR/mini-ci.service" <<'UNIT'
[Unit]
Description=mini-ci pipeline runner (LPI 701.4 lab)
Documentation=https://www.lpi.org/our-certifications/exam-701-objectives/

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mini-ci run
WorkingDirectory=/opt/cicd-lab
StandardOutput=journal
StandardError=journal
UNIT

    cat > "$UNIT_DIR/mini-ci.path" <<'UNIT'
[Unit]
Description=Watch the mini-ci trigger queue (LPI 701.4 lab)

[Path]
PathExistsGlob=/var/spool/mini-ci/*.trigger
Unit=mini-ci.service

[Install]
WantedBy=multi-user.target
UNIT

    if command -v python3 >/dev/null 2>&1; then
        cat > "$UNIT_DIR/demo-app.service" <<UNIT
[Unit]
Description=demo-app served from the current release (LPI 701.4 lab)
After=network.target

[Service]
ExecStart=/usr/bin/env python3 -m http.server $APP_PORT --directory $CURRENT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    fi

    systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# the verifier the student uses to grade the repair
# ---------------------------------------------------------------------------
write_verifier() {
    cat > "$VERIFIER" <<'VERIFY'
#!/usr/bin/env bash
#
# cicd-lab-verify - grade the 701.4 break & fix lab, layer by layer.

set -uo pipefail

LAB_ROOT=/opt/cicd-lab
REPO="$LAB_ROOT/repo.git"
SPOOL=/var/spool/mini-ci
PIPELINES="$LAB_ROOT/pipelines"
CURRENT="$LAB_ROOT/current"
PORT=18080

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
no()  { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }

printf 'CI/CD pipeline check\n'
printf -- '----------------------------------------------------------------------\n'

# 1. trigger
if [[ -x "$REPO/hooks/post-receive" ]]; then
    ok "trigger      the post-receive hook is executable"
else
    no "trigger      $REPO/hooks/post-receive is not executable, a push starts nothing"
fi

# 2. runner
if systemctl is-active --quiet mini-ci.path; then
    ok "runner       mini-ci.path is active and watching the queue"
else
    no "runner       mini-ci.path is not active, triggers pile up in $SPOOL"
fi
if systemctl is-enabled --quiet mini-ci.path 2>/dev/null; then
    ok "runner       mini-ci.path is enabled, it survives a reboot"
else
    no "runner       mini-ci.path is not enabled, the lab would break again on reboot"
fi

expected_sha="$(git --git-dir="$REPO" rev-parse refs/heads/main 2>/dev/null || true)"
expected_base="$(git --git-dir="$REPO" show refs/heads/main:VERSION 2>/dev/null | tr -d '[:space:]')"
expected_version="${expected_base}-g${expected_sha:0:7}"
printf '  ....  head of main is %s, expected release %s\n' "${expected_sha:0:7}" "$expected_version"

# 3. last pipeline
id="$(cat "$PIPELINES/latest" 2>/dev/null || true)"
status="$PIPELINES/$id.status"
field() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$2" 2>/dev/null; }

if [[ -n "$id" && -f "$status" ]]; then
    result="$(field result "$status")"
    sha="$(field sha "$status")"
    source="$(field source "$status")"
    version="$(field version "$status")"
    if [[ "$result" == "success" ]]; then
        ok "pipeline     the last pipeline ($id) succeeded"
    else
        no "pipeline     the last pipeline ($id) ended as $result, see: mini-ci logs $id"
    fi
    if [[ "$sha" == "$expected_sha" ]]; then
        ok "pipeline     it ran the head of main"
    else
        no "pipeline     it ran ${sha:0:7}, not the head of main (${expected_sha:0:7})"
    fi
    if [[ "$source" == "hook" ]]; then
        ok "pipeline     it was started by the post-receive hook, not by hand"
    else
        no "pipeline     it was started by \"$source\"; the goal is an end to end push, fix the hook"
    fi
else
    no "pipeline     no pipeline has ever run for this repository"
    version=""
fi

# 4. artifact repository
art="$LAB_ROOT/artifacts/$expected_version/demo-app-$expected_version.tar.gz"
if [[ -f "$art" ]]; then
    ok "artifacts    $(basename "$art") is in the artifact repository"
else
    no "artifacts    no build artifact for $expected_version under $LAB_ROOT/artifacts"
fi
if [[ -f "$art.sha256" ]] && ( cd "$(dirname "$art")" && sha256sum -c "$(basename "$art").sha256" >/dev/null 2>&1 ); then
    ok "artifacts    the checksum of the stored artifact verifies"
else
    no "artifacts    no verifiable checksum next to the artifact"
fi

# 5. deploy
if [[ -L "$CURRENT" ]]; then
    target="$(readlink -f "$CURRENT")"
    ok "deploy       $CURRENT is a symlink -> $target"
    if [[ "$target" == "$LAB_ROOT/releases/$expected_version" ]]; then
        ok "deploy       it points at the release built from the head of main"
    else
        no "deploy       it points at $target, expected $LAB_ROOT/releases/$expected_version"
    fi
elif [[ -d "$CURRENT" ]]; then
    no "deploy       $CURRENT is a real directory, not a symlink; ln -sfn writes INSIDE it"
else
    no "deploy       $CURRENT does not exist"
fi

served=""
if command -v curl >/dev/null 2>&1; then
    served="$(curl -fsS --max-time 3 "http://127.0.0.1:$PORT/version.txt" 2>/dev/null | tr -d '[:space:]')"
fi
[[ -n "$served" ]] || served="$(tr -d '[:space:]' < "$CURRENT/version.txt" 2>/dev/null || true)"

if [[ "$served" == "$expected_version" ]]; then
    ok "production   the running app serves $served"
else
    no "production   the running app serves \"${served:-nothing}\", expected $expected_version"
fi

if [[ -x "$CURRENT/bin/app" ]] && "$CURRENT/bin/app" checksum >/dev/null 2>&1; then
    ok "production   the 1.5.0 checksum subcommand is live"
else
    no "production   the deployed binary has no working checksum subcommand, it is still the old release"
fi

printf -- '----------------------------------------------------------------------\n'
printf '%d passed, %d failed\n' "$pass" "$fail"
if (( fail == 0 )); then
    printf 'LAB SOLVED. The pipeline is green end to end and production serves the new release.\n'
    exit 0
fi
printf 'Not solved yet. Fix the highest failing layer first, then push again.\n'
exit 1
VERIFY
    chmod 0755 "$VERIFIER"
}

# ---------------------------------------------------------------------------
# repository content
# ---------------------------------------------------------------------------
write_app_v1() {
    install -d "$SRC/app" "$SRC/tests" "$SRC/.ci"
    printf '1.4.0\n' > "$SRC/VERSION"

    cat > "$SRC/app/demo-app.sh" <<'APP'
#!/usr/bin/env bash
# demo-app - the payload of the 701.4 pipeline.
# @VERSION@ is substituted by the build stage, which is why the binary that
# reaches production can always be traced back to a commit.
set -euo pipefail
VERSION="@VERSION@"

case "${1:-version}" in
    version) printf 'demo-app %s\n' "$VERSION" ;;
    health)  printf 'ok\n' ;;
    *)       printf 'usage - demo-app [version|health]\n' >&2; exit 64 ;;
esac
APP

    cat > "$SRC/tests/test_app.sh" <<'TEST'
#!/usr/bin/env bash
# Unit tests, run by the test stage against the built artifact, never against
# the source. Testing what you did not build is how a green pipeline lies.
set -euo pipefail
app="${1:?usage - test_app.sh <path to the built app>}"
checks=0
fail() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }

out="$("$app" version)"
[[ "$out" == demo-app\ * ]] || fail "unexpected version output -> $out"
checks=$((checks + 1))

[[ "$out" == *"$VERSION"* ]] || fail "the built app does not carry the pipeline version -> $out"
checks=$((checks + 1))

[[ "$("$app" health)" == "ok" ]] || fail "the health subcommand did not answer ok"
checks=$((checks + 1))

printf 'PASS - %d checks\n' "$checks"
TEST

    write_pipeline_good "$SRC/.ci/pipeline.yml"
    cat > "$SRC/README.md" <<'DOC'
# demo-app

Payload of the LPI 701.4 CI/CD lab.

    .ci/pipeline.yml   the pipeline as code
    app/               source
    tests/             unit tests, run against the build output
    VERSION            the release number, the commit sha is appended by the runner

Push to `main` and the post-receive hook queues a pipeline. Follow it with:

    journalctl -u mini-ci.service -f
DOC
}

write_pipeline_good() {
    cat > "$1" <<'PIPE'
# Pipeline as code for demo-app.
# The runner exports VERSION, CI_COMMIT_SHA, CI_PIPELINE_ID and every entry
# under "variables" before running a script line.

stages:
  - build
  - test
  - package
  - deploy

variables:
  APP_NAME: demo-app
  ARTIFACT_DIR: /opt/cicd-lab/artifacts
  RELEASES_DIR: /opt/cicd-lab/releases
  CURRENT_LINK: /opt/cicd-lab/current

build:
  stage: build
  script:
    - install -d dist
    - sed "s/@VERSION@/$VERSION/" app/demo-app.sh > dist/demo-app.sh
    - chmod 0755 dist/demo-app.sh
    - echo "built $APP_NAME $VERSION"
  artifacts:
    paths:
      - "dist/demo-app.sh"

test:
  stage: test
  script:
    - bash tests/test_app.sh dist/demo-app.sh

package:
  stage: package
  script:
    - tar -czf "dist/$APP_NAME-$VERSION.tar.gz" -C dist demo-app.sh
    - cd dist && sha256sum "$APP_NAME-$VERSION.tar.gz" > "$APP_NAME-$VERSION.tar.gz.sha256"
  artifacts:
    paths:
      - "dist/*.tar.gz"
      - "dist/*.tar.gz.sha256"

deploy:
  stage: deploy
  script:
    - echo "looking for $APP_NAME-$VERSION.tar.gz in the artifact repository"
    - test -f "$ARTIFACT_DIR/$VERSION/$APP_NAME-$VERSION.tar.gz"
    - cd "$ARTIFACT_DIR/$VERSION" && sha256sum -c "$APP_NAME-$VERSION.tar.gz.sha256"
    - install -d "$RELEASES_DIR/$VERSION/bin"
    - tar -xzf "$ARTIFACT_DIR/$VERSION/$APP_NAME-$VERSION.tar.gz" -C "$RELEASES_DIR/$VERSION"
    - mv "$RELEASES_DIR/$VERSION/demo-app.sh" "$RELEASES_DIR/$VERSION/bin/app"
    - echo "$VERSION" > "$RELEASES_DIR/$VERSION/version.txt"
    - ln -sfn "$RELEASES_DIR/$VERSION" "$CURRENT_LINK"
    - echo "deployed $VERSION"
PIPE
}

write_app_v2_broken_pipeline() {
    printf '1.5.0\n' > "$SRC/VERSION"

    cat > "$SRC/app/demo-app.sh" <<'APP'
#!/usr/bin/env bash
# demo-app - the payload of the 701.4 pipeline.
# @VERSION@ is substituted by the build stage, which is why the binary that
# reaches production can always be traced back to a commit.
set -euo pipefail
VERSION="@VERSION@"

case "${1:-version}" in
    version)  printf 'demo-app %s\n' "$VERSION" ;;
    health)   printf 'ok\n' ;;
    checksum) sha256sum "$0" | awk '{ print $1 }' ;;
    *)        printf 'usage - demo-app [version|health|checksum]\n' >&2; exit 64 ;;
esac
APP

    cat > "$SRC/tests/test_app.sh" <<'TEST'
#!/usr/bin/env bash
# Unit tests, run by the test stage against the built artifact, never against
# the source. Testing what you did not build is how a green pipeline lies.
set -euo pipefail
app="${1:?usage - test_app.sh <path to the built app>}"
checks=0
fail() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }

out="$("$app" version)"
[[ "$out" == demo-app\ * ]] || fail "unexpected version output -> $out"
checks=$((checks + 1))

[[ "$out" == *"$VERSION"* ]] || fail "the built app does not carry the pipeline version -> $out"
checks=$((checks + 1))

[[ "$("$app" health)" == "ok" ]] || fail "the health subcommand did not answer ok"
checks=$((checks + 1))

[[ "$("$app" checksum)" =~ ^[0-9a-f]{64}$ ]] || fail "the checksum subcommand did not return a sha256"
checks=$((checks + 1))

printf 'PASS - %d checks\n' "$checks"
TEST

    # The "developer" touched the pipeline definition in the same commit as the
    # feature. Two faults live here: the file no longer parses as YAML, and the
    # package stage archives paths that do not exist.
    cat > "$SRC/.ci/pipeline.yml" <<'PIPE'
# Pipeline as code for demo-app.
# The runner exports VERSION, CI_COMMIT_SHA, CI_PIPELINE_ID and every entry
# under "variables" before running a script line.

stages:
  - build
  - test
  - package
  - deploy

variables:
  APP_NAME: demo-app
  ARTIFACT_DIR:/opt/cicd-lab/artifacts
  RELEASES_DIR: /opt/cicd-lab/releases
  CURRENT_LINK: /opt/cicd-lab/current

build:
  stage: build
  script:
    - install -d dist
    - sed "s/@VERSION@/$VERSION/" app/demo-app.sh > dist/demo-app.sh
    - chmod 0755 dist/demo-app.sh
    - echo "built $APP_NAME $VERSION"
  artifacts:
    paths:
      - "dist/demo-app.sh"

test:
  stage: test
  script:
    - bash tests/test_app.sh dist/demo-app.sh

package:
  stage: package
  script:
    - tar -czf "dist/$APP_NAME-$VERSION.tar.gz" -C dist demo-app.sh
    - cd dist && sha256sum "$APP_NAME-$VERSION.tar.gz" > "$APP_NAME-$VERSION.tar.gz.sha256"
  artifacts:
    paths:
      - *.tar.gz
      - "build/*.tar.gz.sha256"

deploy:
  stage: deploy
  script:
    - echo "looking for $APP_NAME-$VERSION.tar.gz in the artifact repository"
    - test -f "$ARTIFACT_DIR/$VERSION/$APP_NAME-$VERSION.tar.gz"
    - cd "$ARTIFACT_DIR/$VERSION" && sha256sum -c "$APP_NAME-$VERSION.tar.gz.sha256"
    - install -d "$RELEASES_DIR/$VERSION/bin"
    - tar -xzf "$ARTIFACT_DIR/$VERSION/$APP_NAME-$VERSION.tar.gz" -C "$RELEASES_DIR/$VERSION"
    - mv "$RELEASES_DIR/$VERSION/demo-app.sh" "$RELEASES_DIR/$VERSION/bin/app"
    - echo "$VERSION" > "$RELEASES_DIR/$VERSION/version.txt"
    - ln -sfn "$RELEASES_DIR/$VERSION" "$CURRENT_LINK"
    - echo "deployed $VERSION"
PIPE
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
do_setup() {
    info "building the lab under $LAB_ROOT"

    systemctl disable --now mini-ci.path   >/dev/null 2>&1 || true
    systemctl disable --now demo-app.service >/dev/null 2>&1 || true

    rm -rf "$LAB_ROOT" "$SPOOL"
    install -d "$LAB_ROOT" "$SPOOL" "$RELEASES" "$ARTIFACTS" "$PIPELINES"

    git init --bare --quiet "$REPO"
    git --git-dir="$REPO" symbolic-ref HEAD refs/heads/main

    write_runner
    write_verifier
    write_hook
    write_units

    info "seeding the repository with demo-app 1.4.0"
    install -d "$SRC"
    git init --quiet "$SRC"
    git -C "$SRC" symbolic-ref HEAD refs/heads/main
    git -C "$SRC" config user.name  "Lab Student"
    git -C "$SRC" config user.email "student@lab.invalid"
    git -C "$SRC" config commit.gpgsign false
    write_app_v1
    git -C "$SRC" add -A
    git -C "$SRC" commit --quiet -m "feat: demo-app 1.4.0 with the delivery pipeline"
    git -C "$SRC" remote add origin "$REPO" 2>/dev/null || true

    systemctl enable --now mini-ci.path >/dev/null 2>&1

    info "running the first pipeline to get a known good baseline"
    git -C "$SRC" push --quiet origin main 2>&1 | sed 's/^/      /'
    "$RUNNER" run >/dev/null 2>&1 || true
    sleep 1

    if [[ ! -L "$CURRENT" ]]; then
        warn "the baseline pipeline did not deploy, inspect it with: mini-ci logs"
        "$RUNNER" status || true
        die "refusing to hand over a lab whose baseline is already broken"
    fi

    if [[ -f "$UNIT_DIR/demo-app.service" ]]; then
        systemctl enable --now demo-app.service >/dev/null 2>&1 || warn "demo-app.service did not start, port $APP_PORT may be taken"
    else
        warn "python3 is not installed, the HTTP endpoint is skipped; read $CURRENT/version.txt instead"
    fi

    info "baseline deployed -> $(readlink -f "$CURRENT")"
}

# ---------------------------------------------------------------------------
# break
# ---------------------------------------------------------------------------
do_break() {
    info "injecting the faults"

    # FAULT 1 - the trigger. A hook without the execute bit is silently ignored
    # by git: the push succeeds and nothing is queued.
    chmod 0644 "$REPO/hooks/post-receive"

    # FAULT 2 - the runner. The path unit is stopped and disabled, so even a
    # trigger written by hand sits in the spool for ever.
    systemctl disable --now mini-ci.path >/dev/null 2>&1 || true

    # FAULTS 3 and 4 - the pipeline definition. A developer commits the 1.5.0
    # feature together with an edit to .ci/pipeline.yml that does not parse and
    # that archives paths which do not exist.
    write_app_v2_broken_pipeline
    git -C "$SRC" add -A
    git -C "$SRC" commit --quiet -m "feat: add the checksum subcommand, bump to 1.5.0

Also tidied up the artifact paths in the pipeline definition."
    git -C "$SRC" push --quiet origin main >/dev/null 2>&1

    # FAULT 5 - the deploy switch. Somebody once ran "mkdir current". From now
    # on ln -sfn creates a link INSIDE that directory and production freezes on
    # whatever the directory happens to contain.
    local frozen
    frozen="$(readlink -f "$CURRENT")"
    rm -f "$CURRENT"
    install -d "$CURRENT"
    cp -a "$frozen/." "$CURRENT/"

    # the queue is emptied so the student starts from a clean, quiet system
    rm -f "$SPOOL"/*.trigger 2>/dev/null || true
    systemctl reset-failed mini-ci.service >/dev/null 2>&1 || true

    briefing
}

# ---------------------------------------------------------------------------
# briefing
# ---------------------------------------------------------------------------
briefing() {
    local head_sha
    head_sha="$(git --git-dir="$REPO" rev-parse --short refs/heads/main)"
    cat <<EOF

======================================================================
 LPI 701-100 - topic 701.4 - Continuous Integration and Continuous Delivery
 BREAK & FIX: "the release that never shipped"
======================================================================

THE STORY

  demo-app 1.4.0 was delivered by the pipeline and is in production.
  A developer then pushed commit $head_sha, which adds the "checksum"
  subcommand and bumps VERSION to 1.5.0. The ticket was closed. Two days
  later support reports that the new subcommand does not exist in production.

THE SYMPTOM YOU WILL SEE

  1. git push into $REPO succeeds and prints nothing
     about a pipeline. No job is queued.
  2. $SPOOL stays empty; when you queue a job by hand
     it stays there, unread.
  3. Once jobs do run, the pipeline dies before the first stage with a
     complaint about the pipeline definition.
  4. Once it parses, the pipeline dies in "deploy", looking for a tarball
     the artifact repository does not have.
  5. And when the pipeline finally reports SUCCESS, production STILL serves
     the old release. A green pipeline that deploys nothing is the most
     expensive failure in this lab - learn to recognise it.

  Look now:

      curl -s http://127.0.0.1:$APP_PORT/version.txt      # or: cat $CURRENT/version.txt
      $CURRENT/bin/app checksum

YOUR GOAL

  An end to end delivery, with no manual step in the middle:

      a plain "git push" from $SRC
        -> the hook queues a pipeline
        -> the runner picks it up on its own
        -> build, test, package and deploy all pass
        -> the artifact of THIS commit is stored with a valid checksum
        -> $CURRENT points at the new release
        -> the running app answers 1.5.0-g<sha> and has the checksum subcommand

  Five independent faults, one per layer: trigger, runner, pipeline
  definition, artifacts, deploy. Fix forward - reverting the developer's
  commit would also revert the feature, and 1.5.0 must ship.

YOUR TOOLBOX

      $VERIFIER              grade yourself, layer by layer
      mini-ci queue | status | logs | lint       the runner CLI
      journalctl -u mini-ci.service -n 80 --no-pager
      systemctl status mini-ci.path mini-ci.service
      git -C $SRC log -p .ci/pipeline.yml
      ls -l $REPO/hooks/ $LAB_ROOT/

  Hints, one level at a time:   $0 hint 1

======================================================================
EOF
}

do_hint() {
    case "${1:-1}" in
        1)
            cat <<'EOF'
HINT 1 - work from the outside in, and do not guess.

  A pipeline has a chain of custody. Walk it in order and ask each link to
  prove it did its job; the first one that cannot is where you stop.

    push accepted?      git push, and read what the server printed back
    job queued?         ls -l /var/spool/mini-ci/
    runner listening?   systemctl status mini-ci.path
    job executed?       journalctl -u mini-ci.service -n 80 --no-pager
    artifact stored?    ls -lR /opt/cicd-lab/artifacts/
    release switched?   ls -ld /opt/cicd-lab/current

  Three of the five faults announce themselves in one of those six commands.
EOF
            ;;
        2)
            cat <<'EOF'
HINT 2 - specifics.

  * git ignores a hook that is not executable, and says nothing about it.
    Compare: ls -l /opt/cicd-lab/repo.git/hooks/

  * A systemd .path unit only watches while it is active, and only comes back
    after a reboot if it is enabled. "is-active" and "is-enabled" are two
    different questions, and this lab fails both.

  * The pipeline definition changed in the last commit. Read the diff, do not
    read the file: git -C /opt/cicd-lab/src log -p -1 .ci/pipeline.yml
    Then check it with: cd /opt/cicd-lab/src && mini-ci lint .ci/pipeline.yml

  * In YAML, "key:value" is not a mapping and an unquoted leading "*" is an
    alias, not a glob.
EOF
            ;;
        *)
            cat <<'EOF'
HINT 3 - the two that hide.

  * Read the runner log of a "successful" pipeline line by line, not just its
    last line. It tells you when an artifacts pattern matched no file at all.
    An upload that matches nothing is a warning, not an error - which is why
    the failure only surfaces one stage later, in deploy.

  * "ln -sfn TARGET LINK" replaces LINK only if LINK is a symlink or a file.
    If LINK is an existing DIRECTORY, ln creates TARGET's basename INSIDE it
    and returns 0. Your deploy stage will report success every single time
    while production never moves. Prove it:
        ls -ld /opt/cicd-lab/current
        ls -l  /opt/cicd-lab/current/
EOF
            ;;
    esac
}

do_clean() {
    confirm_disposable
    info "removing the lab"
    systemctl disable --now mini-ci.path     >/dev/null 2>&1 || true
    systemctl disable --now demo-app.service >/dev/null 2>&1 || true
    systemctl stop mini-ci.service           >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/mini-ci.path" "$UNIT_DIR/mini-ci.service" "$UNIT_DIR/demo-app.service"
    systemctl daemon-reload
    systemctl reset-failed mini-ci.service >/dev/null 2>&1 || true
    rm -rf "$LAB_ROOT" "$SPOOL" "$RUNNER" "$VERIFIER" /run/mini-ci.lock
    info "done, nothing of the lab is left on this machine"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local cmd=break
    local args=()
    local a
    for a in "$@"; do
        case "$a" in
            --yes|-y) ASSUME_YES=yes ;;
            setup|break|verify|hint|status|clean) cmd="$a" ;;
            *) args+=("$a") ;;
        esac
    done

    case "$cmd" in
        setup)
            require_root; require_systemd; require_tools; confirm_disposable
            do_setup
            info "healthy lab ready. Break it with: $0 break --yes"
            ;;
        break)
            require_root; require_systemd; require_tools; confirm_disposable
            do_setup
            do_break
            ;;
        verify)
            require_root
            [[ -x "$VERIFIER" ]] || die "the lab is not installed, run: $0 break"
            "$VERIFIER"
            ;;
        status)
            [[ -x "$RUNNER" ]] || die "the lab is not installed"
            "$RUNNER" status
            ;;
        hint)
            do_hint "${args[0]:-1}"
            ;;
        clean)
            require_root
            do_clean
            ;;
    esac
}

main "$@"

# ===========================================================================
#
#                          S O L U T I O N
#              read only after you have tried the lab
#
# ===========================================================================
#
# The five faults, in the order the evidence reveals them. Never fix more than
# one layer at a time: push, read the log, then move on. That discipline is
# the whole skill this objective tests.
#
# ---------------------------------------------------------------------------
# STEP 0 - reproduce, and collect evidence before touching anything
# ---------------------------------------------------------------------------
#
#   cd /opt/cicd-lab/src
#   git commit --allow-empty -m "chore: trigger a pipeline"
#   git push origin main
#
# Expected: the push succeeds, the remote prints nothing about mini-ci.
# A push that says nothing is the first fact: the trigger never ran.
#
#   ls -l /var/spool/mini-ci/          # empty, no job was queued
#   /usr/local/bin/cicd-lab-verify     # the full picture, layer by layer
#
# ---------------------------------------------------------------------------
# FAULT 1 - the trigger: post-receive is not executable
# ---------------------------------------------------------------------------
#
#   ls -l /opt/cicd-lab/repo.git/hooks/post-receive
#   -rw-r--r-- 1 root root 812 ... post-receive          <- no x bit
#
# git runs hooks with execve(2). A hook without the execute bit is skipped in
# complete silence: no warning, no non-zero exit, and the push still succeeds.
# This is the most common "CI stopped working after we restored the repo from
# a backup / copied it with a tool that drops modes" incident there is.
#
#   chmod +x /opt/cicd-lab/repo.git/hooks/post-receive
#   ls -l /opt/cicd-lab/repo.git/hooks/post-receive
#   -rwxr-xr-x 1 root root 812 ... post-receive
#
# Verify the trigger alone, before worrying about the runner:
#
#   cd /opt/cicd-lab/src
#   git commit --allow-empty -m "chore: trigger a pipeline"
#   git push origin main
#   remote: mini-ci: queued a pipeline for 9f2c1ab
#   ls -l /var/spool/mini-ci/
#   -rw-r--r-- 1 root root 78 ... 1789...-9f2c1ab.trigger
#
# The trigger is now proven. The job is queued and nobody consumes it.
#
# ---------------------------------------------------------------------------
# FAULT 2 - the runner: mini-ci.path is stopped and disabled
# ---------------------------------------------------------------------------
#
#   systemctl status mini-ci.path
#   * mini-ci.path - Watch the mini-ci trigger queue (LPI 701.4 lab)
#        Loaded: loaded (/etc/systemd/system/mini-ci.path; disabled; ...)
#        Active: inactive (dead)
#
# Two separate problems in one line, and you must fix both:
#   "inactive (dead)"  -> it is not watching right now
#   "disabled"         -> it will not come back after a reboot
# Fixing only the first is the classic half repair that reappears at 3 a.m.
#
#   systemctl enable --now mini-ci.path
#   systemctl is-active mini-ci.path && systemctl is-enabled mini-ci.path
#   active
#   enabled
#
# The pending trigger is picked up immediately, because PathExistsGlob
# matches at activation, not only on a new inotify event:
#
#   journalctl -u mini-ci.service -n 40 --no-pager
#   ... mini-ci[1234]: 12:41:07 pipeline 20260918-124107-9f2c1ab
#   ... mini-ci[1234]: 12:41:07   commit 9f2c1ab... on refs/heads/main, triggered by hook
#   ... mini-ci[1234]: 12:41:07   version 1.5.0-g9f2c1ab
#   ... mini-ci[1234]: 12:41:07 pipeline definition is not valid YAML
#   ... mini-ci[1234]: 12:41:07   line 13  no space after the colon -> ...
#
# The runner is proven. Now the pipeline itself is the problem - which is
# progress: the failure moved one layer inward.
#
# ---------------------------------------------------------------------------
# FAULT 3 - the pipeline definition does not parse
# ---------------------------------------------------------------------------
#
# Do not open the file first. Ask git what changed, because a pipeline that
# worked yesterday and fails today changed in a commit:
#
#   git -C /opt/cicd-lab/src log -p -1 .ci/pipeline.yml
#
#   -  ARTIFACT_DIR: /opt/cicd-lab/artifacts
#   +  ARTIFACT_DIR:/opt/cicd-lab/artifacts
#   ...
#   -      - "dist/*.tar.gz"
#   -      - "dist/*.tar.gz.sha256"
#   +      - *.tar.gz
#   +      - "build/*.tar.gz.sha256"
#
# Reproduce the parse error locally, without burning a pipeline run:
#
#   cd /opt/cicd-lab/src && mini-ci lint .ci/pipeline.yml
#   pipeline definition is not valid YAML
#     line 13  no space after the colon -> ...
#     line 45  list item starts with an asterisk, YAML reads it as an alias ...
#
# Why each one is fatal, and not merely ugly:
#
#   ARTIFACT_DIR:/opt/cicd-lab/artifacts
#       YAML needs a space after the colon to recognise a mapping. Without it
#       the whole thing is one scalar string, "ARTIFACT_DIR:/opt/...", and the
#       variable simply does not exist. Worse than a crash: in a parser that
#       tolerates it, the deploy stage would later expand $ARTIFACT_DIR to the
#       empty string and run "test -f /1.5.0-g9f2c1ab/demo-app...".
#
#   - *.tar.gz
#       "*" opens an alias reference in YAML. An unquoted glob at the start of
#       a scalar is read as "*.tar.gz" the alias name, and the document is
#       rejected. Any value that begins with * & ! % @ ` { [ or that contains
#       ": " must be quoted. This is the same rule that bites people writing
#       "- *.example.com" in an Ingress or a certificate SAN list.
#
# Fix both, in the same edit as fault 4 below - they are two lines apart.
#
# ---------------------------------------------------------------------------
# FAULT 4 - the artifacts are archived from paths that do not exist
# ---------------------------------------------------------------------------
#
# If you only fix the quoting, the next run gets further and shows you this:
#
#   ...   stage package
#   ...     job package
#   ...       $ tar -czf "dist/demo-app-1.5.0-g9f2c1ab.tar.gz" -C dist demo-app.sh
#   ...     artifacts: no file matched "*.tar.gz", nothing uploaded for this path
#   ...     artifacts: no file matched "build/*.tar.gz.sha256", nothing uploaded
#   ...     job package passed
#   ...   stage deploy
#   ...       $ test -f "/opt/cicd-lab/artifacts/1.5.0-g9f2c1ab/demo-app-1.5.0-g9f2c1ab.tar.gz"
#   ...     job deploy FAILED with exit code 1
#
# Read that sequence carefully: the package job PASSED. Every command in it
# returned 0. The tarball was built. What failed is the upload, and an upload
# that matches nothing is a warning in GitLab CI, in Jenkins archiveArtifacts
# and here. The error surfaces one stage later, in the consumer, pointing at a
# missing file - and the natural but wrong reading is "deploy is broken".
#
#   "*.tar.gz"          the pattern is relative to the workspace root, the
#                       tarball lives in dist/ -> zero matches
#   "build/*.tar.gz.sha256"   there is no build/ directory at all
#
# Fix faults 3 and 4 together, forward, without reverting the feature:
#
#   cd /opt/cicd-lab/src
#   sed -i 's|^  ARTIFACT_DIR:/|  ARTIFACT_DIR: /|' .ci/pipeline.yml
#   sed -i 's|^      - \*\.tar\.gz$|      - "dist/*.tar.gz"|' .ci/pipeline.yml
#   sed -i 's|^      - "build/\*\.tar\.gz\.sha256"$|      - "dist/*.tar.gz.sha256"|' .ci/pipeline.yml
#
#   mini-ci lint .ci/pipeline.yml
#   pipeline definition ok
#
#   git add .ci/pipeline.yml
#   git commit -m "fix(ci): restore the artifact paths and the ARTIFACT_DIR mapping"
#   git push origin main
#
#   journalctl -u mini-ci.service -n 60 --no-pager
#   ...     artifacts: uploaded 1 file(s) matching "dist/*.tar.gz"
#   ...     artifacts: uploaded 1 file(s) matching "dist/*.tar.gz.sha256"
#   ...   stage deploy
#   ...       $ cd "/opt/cicd-lab/artifacts/..." && sha256sum -c "demo-app-....tar.gz.sha256"
#   ...     demo-app-1.5.0-gab34cd1.tar.gz: OK
#   ...       $ echo "deployed 1.5.0-gab34cd1"
#   ...   pipeline 20260918-125512-ab34cd1 SUCCESS
#
# Green. And still wrong.
#
# ---------------------------------------------------------------------------
# FAULT 5 - a green pipeline that deploys nothing
# ---------------------------------------------------------------------------
#
#   curl -s http://127.0.0.1:18080/version.txt
#   1.4.0-g7e11d04                       <- the OLD release, after a SUCCESS
#
#   ls -ld /opt/cicd-lab/current
#   drwxr-xr-x 3 root root 4096 ... /opt/cicd-lab/current     <- a directory
#
#   ls -l /opt/cicd-lab/current
#   lrwxrwxrwx 1 root root 38 ... 1.5.0-gab34cd1 -> /opt/cicd-lab/releases/1.5.0-gab34cd1
#   -rwxr-xr-x 1 root root ...    bin
#   -rw-r--r-- 1 root root  15 ... version.txt
#
# There is the whole story. "ln -sfn TARGET LINK" replaces LINK when LINK is a
# symlink or a regular file, but when LINK is an existing directory it creates
# TARGET's basename INSIDE it and exits 0. Every deploy since then has been
# quietly filing new symlinks into a directory nobody serves from.
#
#   rm -rf /opt/cicd-lab/current            # it is a directory, its content is
#                                           # a copy of an old release, nothing
#                                           # unique lives there
#   ln -sfn /opt/cicd-lab/releases/1.5.0-gab34cd1 /opt/cicd-lab/current
#   ls -ld /opt/cicd-lab/current
#   lrwxrwxrwx 1 root root 38 ... /opt/cicd-lab/current -> /opt/cicd-lab/releases/1.5.0-gab34cd1
#
# Or, better, let the pipeline do it - the point of CD is that no human touches
# production by hand:
#
#   rm -rf /opt/cicd-lab/current
#   cd /opt/cicd-lab/src
#   git commit --allow-empty -m "chore: redeploy"
#   git push origin main
#
# ---------------------------------------------------------------------------
# VERIFY
# ---------------------------------------------------------------------------
#
#   /usr/local/bin/cicd-lab-verify
#     PASS  trigger      the post-receive hook is executable
#     PASS  runner       mini-ci.path is active and watching the queue
#     PASS  runner       mini-ci.path is enabled, it survives a reboot
#     PASS  pipeline     the last pipeline (...) succeeded
#     PASS  pipeline     it ran the head of main
#     PASS  pipeline     it was started by the post-receive hook, not by hand
#     PASS  artifacts    demo-app-1.5.0-g....tar.gz is in the artifact repository
#     PASS  artifacts    the checksum of the stored artifact verifies
#     PASS  deploy       /opt/cicd-lab/current is a symlink -> ...
#     PASS  deploy       it points at the release built from the head of main
#     PASS  production   the running app serves 1.5.0-g...
#     PASS  production   the 1.5.0 checksum subcommand is live
#   12 passed, 0 failed
#   LAB SOLVED.
#
#   curl -s http://127.0.0.1:18080/version.txt
#   1.5.0-gab34cd1
#   /opt/cicd-lab/current/bin/app checksum
#   5b1f...e9c4
#
# ---------------------------------------------------------------------------
# WHAT THIS LAB IS ACTUALLY TEACHING (701.4)
# ---------------------------------------------------------------------------
#
# 1. A pipeline is a chain of custody, not a single program. Trigger, runner,
#    definition, artifact store, deployment target. Diagnose it in that order;
#    each layer can be proven independently, and the fault is always at the
#    first link that cannot prove its part.
#
# 2. "The job passed" is not "the job did what it was for". The package job
#    returned 0 while uploading nothing. Exit codes measure commands, not
#    intent. This is the practical reason artifact patterns and deployment
#    steps need their own assertions.
#
# 3. Green pipeline, stale production is the failure mode that survives longest
#    in real organisations, because every dashboard is green. The remediation
#    is not "be careful with ln": it is to end the deploy stage with a smoke
#    test that interrogates the running system, so the pipeline can only be
#    green when production actually changed. Add this to the deploy job and
#    fault 5 becomes a red pipeline instead of a silent one:
#
#      - test "$(readlink -f "$CURRENT_LINK")" = "$RELEASES_DIR/$VERSION"
#      - test "$(cat "$CURRENT_LINK/version.txt")" = "$VERSION"
#      - "$CURRENT_LINK/bin/app" health
#
# 4. Pipeline as code is code. It belongs in the repository, it is reviewed in
#    the diff, and "git log -p .ci/pipeline.yml" is the first command when a
#    pipeline that worked yesterday fails today. Lint it locally before you
#    push - a CI round trip is the slowest possible syntax checker.
#
# 5. Immutable releases plus a symlink switch is the cheapest deployment
#    strategy that supports instant rollback: the previous release is still on
#    disk, so undoing a bad deploy is one atomic "ln -sfn" and no rebuild. That
#    is the same principle blue-green and canary scale up - route traffic to a
#    new version that already exists, keep the old one alive until you are
#    sure, and make the switch, not the build, the moment of truth.
#
# 6. Build once, deploy many. The artifact that reaches production is the one
#    the test stage tested, fetched from the artifact repository and checked
#    against its sha256. Rebuilding per environment breaks that guarantee.
#
# Objectives reference:
#   https://www.lpi.org/our-certifications/exam-701-objectives/
#   git hooks:      https://git-scm.com/docs/githooks
#   systemd.path:   https://www.freedesktop.org/software/systemd/man/systemd.path.html
#   GitLab CI yml:  https://docs.gitlab.com/ee/ci/yaml/
#   Jenkins pipeline: https://www.jenkins.io/doc/book/pipeline/
#   YAML 1.2 spec:  https://yaml.org/spec/1.2.2/
#
# ---------------------------------------------------------------------------
# Tear the lab down when you are done:   ./break_fix.sh clean
# ---------------------------------------------------------------------------