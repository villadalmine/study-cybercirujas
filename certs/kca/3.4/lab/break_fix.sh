#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 3: Installation and Configuration
#  Topic 3.4 — Installing Kyverno CLI            (exam weight: 3.0)
#
#  BREAK & FIX lab. This script performs a CONTROLLED, REVERSIBLE break on a
#  DISPOSABLE lab VM so you can practice recovering a working Kyverno CLI
#  installation the way you would under exam / on-call pressure.
#
#  What it touches (and nothing else):
#    - /usr/local/bin/kyverno            (installs a fake "decoy" shim)
#    - /usr/local/bin/kubectl-kyverno    (installs a fake "decoy" shim)
#    - any genuine kyverno / kubectl-kyverno already on PATH -> moved aside,
#      recorded in a manifest, fully restorable with `--restore`
#    - ${HOME}/.kca-lab/...              (state + backups only)
#
#  It does NOT touch your cluster, kubeconfig, workloads or Kyverno policies.
#  It is idempotent: re-running the break does nothing once broken.
#
#  Usage:
#    ./break-fix-3.4.sh            # perform the break (asks for confirmation)
#    ./break-fix-3.4.sh --status   # show current lab state
#    ./break-fix-3.4.sh --restore  # undo the scaffolding, restore pre-lab state
#
#  Non-interactive break (CI / headless lab):
#    I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM=yes ./break-fix-3.4.sh
#
#  Reference sources (official):
#    - KCA Curriculum:
#        https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    - Kyverno CLI install guide:
#        https://kyverno.io/docs/kyverno-cli/install/
#    - Kyverno CLI usage:
#        https://kyverno.io/docs/kyverno-cli/usage/
#    - Release assets:
#        https://github.com/kyverno/kyverno/releases
#    - Krew (kubectl plugin manager):
#        https://krew.sigs.k8s.io/docs/user-guide/setup/install/
# ============================================================================

set -euo pipefail

LAB_ID="kca-3.4-kyverno-cli"
STATE_DIR="${HOME}/.kca-lab/${LAB_ID}"
BACKUP_DIR="${STATE_DIR}/backup"
MANIFEST="${STATE_DIR}/manifest.txt"
BROKEN_MARK="${STATE_DIR}/.broken"

DECOY_DIR="/usr/local/bin"
DECOY_KYVERNO="${DECOY_DIR}/kyverno"
DECOY_PLUGIN="${DECOY_DIR}/kubectl-kyverno"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a command as root only when necessary.
priv() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "ERROR: need root (or sudo) to modify ${DECOY_DIR}." >&2
    exit 1
  fi
}

# List every executable named "$1" that is reachable on the current PATH,
# plus the well-known krew location. Portable, no dependency on `which -a`.
enumerate_on_path() {
  local name="$1" d
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    if [ -f "$d/$name" ] && [ -x "$d/$name" ]; then
      printf '%s\n' "$d/$name"
    fi
  done
  if [ -x "${HOME}/.krew/bin/$name" ]; then
    printf '%s\n' "${HOME}/.krew/bin/$name"
  fi
}

# Move a real binary aside and remember where it came from.
backup_and_remove() {
  local name="$1" p bk
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || continue
    # Skip our own decoys if a previous half-run left them behind.
    case "$p" in
      "$DECOY_KYVERNO"|"$DECOY_PLUGIN") continue ;;
    esac
    bk="${BACKUP_DIR}/$(printf '%s' "$p" | tr '/' '_')"
    if [ -w "$(dirname "$p")" ]; then
      mv -f "$p" "$bk"
    else
      priv mv -f "$p" "$bk"
    fi
    printf '%s|%s\n' "$p" "$bk" >> "$MANIFEST"
    echo "  moved aside: $p"
  done < <(enumerate_on_path "$name")
}

# Write a decoy that mimics a corrupt / partial install: `version` LIES with a
# bogus tag, and every real subcommand fails. Teaches you not to trust
# `kyverno version` alone.
write_decoy() {
  local dest="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'DECOY'
#!/usr/bin/env bash
# KCA lab decoy for topic 3.4 — this is NOT the real Kyverno CLI.
if [ "${1:-}" = "version" ]; then
  echo "Version: v0.0.0-kca-lab-decoy"
  echo "Time: 1970-01-01T00:00:00Z"
  echo "Git commit ID: 0000000000000000000000000000000000000000"
  exit 0
fi
echo "kyverno: broken/partial install (kca-lab decoy): subcommand '${1:-<none>}' is unavailable" >&2
echo "kyverno: reinstall the official Kyverno CLI to continue" >&2
exit 127
DECOY
  chmod 0755 "$tmp"
  priv install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
}

confirm_disposable() {
  if [ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM:-}" = "yes" ]; then
    return 0
  fi
  cat <<'EOF'
------------------------------------------------------------------------------
  WARNING: this will DELIBERATELY BREAK the Kyverno CLI on THIS machine.
  Run it ONLY on a disposable lab VM you can throw away.
  (It is reversible with `--restore`, but do not run it on a workstation.)
------------------------------------------------------------------------------
EOF
  if [ ! -t 0 ]; then
    echo "Non-interactive shell: set I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM=yes to proceed." >&2
    exit 1
  fi
  local ans
  read -r -p "Type EXACTLY 'break my lab vm' to continue: " ans
  if [ "$ans" != "break my lab vm" ]; then
    echo "Aborted. Nothing was changed."
    exit 1
  fi
}

print_briefing() {
  cat <<'EOF'

==============================================================================
  LAB 3.4 — INSTALLING KYVERNO CLI :: THE BREAK IS DONE
==============================================================================

  SCENARIO
  --------
  A teammate "installed" the Kyverno CLI on this box, but the install is
  botched: a fake binary shadows the real tool and there is no genuine
  Kyverno CLI anywhere on PATH.

  SYMPTOMS YOU WILL SEE
  ---------------------
    $ kyverno version
    Version: v0.0.0-kca-lab-decoy          <-- obviously wrong / fake tag

    $ kyverno apply policy.yaml --resource pod.yaml
    kyverno: broken/partial install (kca-lab decoy): subcommand 'apply' is unavailable
    kyverno: reinstall the official Kyverno CLI to continue

    $ file "$(command -v kyverno)"
    .../kyverno: a /usr/bin/env bash script       <-- it's a script, not an ELF binary

  YOUR GOAL (definition of done)
  ------------------------------
    1. `kyverno version`  reports a REAL Kyverno release (e.g. Version: v1.13.x).
    2. `file "$(command -v kyverno)"` shows an ELF 64-bit executable, not a script.
    3. `kyverno apply --help`  and  `kyverno test --help`  both exit 0.
    4. The genuine binary is the FIRST `kyverno` found on PATH.

  Verify yourself with:
    hash -r; which -a kyverno; kyverno version
    kyverno apply --help >/dev/null && kyverno test --help >/dev/null && echo "CLI OK"

  Hints: `which -a kyverno`, `echo "$PATH"`, `file`, and the official install
  guide -> https://kyverno.io/docs/kyverno-cli/install/

  When finished (or to reset): ./break-fix-3.4.sh --restore
==============================================================================
EOF
}

print_status() {
  echo "Lab state for ${LAB_ID}:"
  if [ -f "$BROKEN_MARK" ]; then
    echo "  state:   BROKEN"
  else
    echo "  state:   clean (not broken)"
  fi
  echo "  kyverno on PATH:"
  local found=0 p
  while IFS= read -r p; do echo "    - $p"; found=1; done < <(enumerate_on_path kyverno)
  [ "$found" -eq 1 ] || echo "    (none)"
  if command -v kyverno >/dev/null 2>&1; then
    echo -n "  kyverno version -> "; kyverno version 2>&1 | head -n1 || true
  fi
  if [ -f "$MANIFEST" ]; then
    echo "  backed-up originals:"
    sed 's/^/    /' "$MANIFEST"
  fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

break_lab() {
  confirm_disposable
  mkdir -p "$BACKUP_DIR"

  if [ -f "$BROKEN_MARK" ]; then
    echo "Lab is already broken (idempotent). Re-printing the briefing."
    print_briefing
    return 0
  fi

  : > "$MANIFEST"
  echo "Moving any genuine Kyverno CLI out of the way..."
  backup_and_remove kyverno
  backup_and_remove kubectl-kyverno

  echo "Installing decoy binaries into ${DECOY_DIR}..."
  write_decoy "$DECOY_KYVERNO"
  write_decoy "$DECOY_PLUGIN"

  touch "$BROKEN_MARK"
  hash -r 2>/dev/null || true
  print_briefing
}

restore_lab() {
  echo "Restoring pre-lab state..."
  # Remove decoys (only if they are still our shims).
  for d in "$DECOY_KYVERNO" "$DECOY_PLUGIN"; do
    if [ -f "$d" ] && grep -q "kca-lab decoy" "$d" 2>/dev/null; then
      priv rm -f "$d"
      echo "  removed decoy: $d"
    fi
  done
  # Restore originals only where the student has not already put a real one.
  if [ -f "$MANIFEST" ]; then
    while IFS='|' read -r orig bk; do
      [ -n "$orig" ] || continue
      [ -e "$bk" ] || continue
      if [ -e "$orig" ]; then
        echo "  kept existing: $orig (backup left at $bk)"
        continue
      fi
      if [ -w "$(dirname "$orig")" ]; then
        mv -f "$bk" "$orig"
      else
        priv mv -f "$bk" "$orig"
      fi
      echo "  restored: $orig"
    done < "$MANIFEST"
  fi
  rm -f "$BROKEN_MARK" "$MANIFEST"
  hash -r 2>/dev/null || true
  echo "Done."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

case "${1:-}" in
  ""|--break|break) break_lab ;;
  --status|status)  print_status ;;
  --restore|restore) restore_lab ;;
  -h|--help|help)
    sed -n '2,40p' "$0"
    ;;
  *)
    echo "Unknown argument: $1" >&2
    echo "Use: $0 [--break|--status|--restore]" >&2
    exit 2
    ;;
esac

# ============================================================================
#  ===========================  SOLUTION  ====================================
#  (Everything below is commented out — read it only after you have tried.)
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  Two independent faults, both classic real-world install failures:
#    (a) A non-functional binary sits earlier on PATH and SHADOWS the CLI.
#        `kyverno version` "works" but every other subcommand fails, because
#        the shim only fakes `version`. Lesson: `version` succeeding does NOT
#        prove a healthy install — check `file $(command -v kyverno)` and run
#        a real subcommand like `kyverno apply --help`.
#    (b) No genuine Kyverno CLI is installed at all, so you must (re)install it.
#
#  STEP 0 — DIAGNOSE
#  -----------------
#    which -a kyverno kubectl-kyverno
#    echo "$PATH"
#    file "$(command -v kyverno)"          # -> shell script, not an ELF binary
#    head -1 "$(command -v kyverno)"        # -> #!/usr/bin/env bash  (a shim!)
#    kyverno version                        # -> v0.0.0-kca-lab-decoy (fake)
#
#  STEP 1 — REMOVE THE DECOY
#  -------------------------
#    sudo rm -f /usr/local/bin/kyverno /usr/local/bin/kubectl-kyverno
#    hash -r                                # drop the shell's cached path
#
#  STEP 2 — INSTALL THE OFFICIAL CLI  (pick ONE method)
#  ----------------------------------------------------
#  2A) From the official GitHub release  (portable, no cluster required)
#      # Resolve the latest tag (or pin one from the releases page):
#      VER="$(curl -fsSL https://api.github.com/repos/kyverno/kyverno/releases/latest \
#             | grep -oP '"tag_name":\s*"\K[^"]+')"
#      VER="${VER:-v1.13.4}"                # fallback pin if offline
#      OS="linux"                            # or: darwin
#      case "$(uname -m)" in
#        x86_64|amd64)  ARCH="x86_64" ;;
#        aarch64|arm64) ARCH="arm64"  ;;
#      esac
#      curl -fsSLO "https://github.com/kyverno/kyverno/releases/download/${VER}/kyverno-cli_${VER}_${OS}_${ARCH}.tar.gz"
#      tar -xvf "kyverno-cli_${VER}_${OS}_${ARCH}.tar.gz" kyverno
#      sudo install -m 0755 kyverno /usr/local/bin/kyverno
#      # (Optional) also expose it as a kubectl plugin:
#      sudo ln -sf /usr/local/bin/kyverno /usr/local/bin/kubectl-kyverno
#      # Ref: https://kyverno.io/docs/kyverno-cli/install/
#
#  2B) Via Krew (installs the kubectl-plugin form -> `kubectl kyverno ...`)
#      kubectl krew update
#      kubectl krew install kyverno
#      # Ref: https://kyverno.io/docs/kyverno-cli/install/  (Krew section)
#
#  2C) Via Homebrew (macOS / Linuxbrew)
#      brew install kyverno
#
#  2D) From source (Go toolchain required)
#      go install github.com/kyverno/kyverno/cmd/cli/kubectl-kyverno@latest
#      sudo ln -sf "$(go env GOPATH)/bin/kubectl-kyverno" /usr/local/bin/kyverno
#
#  STEP 3 — VERIFY THE FIX (definition of done)
#  --------------------------------------------
#    hash -r
#    which -a kyverno                       # genuine binary is first on PATH
#    file "$(command -v kyverno)"           # ELF 64-bit executable (not a script)
#    kyverno version                        # real semver, e.g. Version: v1.13.4
#    kyverno apply --help >/dev/null && echo "apply OK"
#    kyverno test  --help >/dev/null && echo "test  OK"
#    # Smoke-test the CLI end-to-end (offline, no cluster):
#    cat > /tmp/require-labels.yaml <<'YAML'
#    apiVersion: kyverno.io/v1
#    kind: ClusterPolicy
#    metadata:
#      name: require-team-label
#    spec:
#      validationFailureAction: Enforce
#      background: false
#      rules:
#        - name: check-team
#          match:
#            any:
#              - resources:
#                  kinds: [Pod]
#          validate:
#            message: "The label 'team' is required."
#            pattern:
#              metadata:
#                labels:
#                  team: "?*"
#    YAML
#    cat > /tmp/bad-pod.yaml <<'YAML'
#    apiVersion: v1
#    kind: Pod
#    metadata:
#      name: nolabels
#    spec:
#      containers:
#        - name: app
#          image: nginx:1.27
#    YAML
#    kyverno apply /tmp/require-labels.yaml --resource /tmp/bad-pod.yaml
#    # Expected: 1 policy rule fails on 'nolabels' -> proves the CLI truly works.
#
#  STEP 4 — RESET THE LAB (optional)
#  ---------------------------------
#    ./break-fix-3.4.sh --restore
#
# ============================================================================