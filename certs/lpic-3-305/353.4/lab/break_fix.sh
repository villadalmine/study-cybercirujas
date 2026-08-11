#!/usr/bin/env bash
#
# =============================================================================
# LPIC-3 305 (Exam 305-300, v3.0) — Topic 353.4: Vagrant (exam weight 5.0)
# Break & Fix lab :: Synced folders and the Vagrant configuration lifecycle
# -----------------------------------------------------------------------------
# Reference / official objectives:
#   https://www.lpi.org/our-certifications/exam-305-objectives/
#
# WHAT THIS SCRIPT DOES
#   It provisions a small, self-contained Vagrant project (a single "web" guest
#   with a private_network, a forwarded_port and a shell provisioner that serves
#   a document root) and then injects ONE controlled fault. Your job is to
#   diagnose the symptom and repair the environment.
#
#   The script ONLY builds and breaks the project. It never runs `vagrant up`
#   for you: booting a guest and burning host resources is your call, not the
#   lab's. Everything happens inside a throwaway directory under $HOME.
#
# SAFETY MODEL
#   * Refuses to run as root.
#   * Touches nothing outside its own disposable LAB_DIR.
#   * `clean` tears the whole thing down (vagrant destroy -f + rm -rf LAB_DIR).
#
# USAGE
#   ./353.4-vagrant-breakfix.sh            # build the project and inject the fault
#   ./353.4-vagrant-breakfix.sh verify     # check whether you have fixed it
#   ./353.4-vagrant-breakfix.sh clean      # destroy the guest and remove the lab
#   ./353.4-vagrant-breakfix.sh help
# =============================================================================

set -euo pipefail

# --- Configuration (override via environment if your lab differs) -------------
LAB_DIR="${LAB_DIR:-$HOME/vagrant-lab-353.4-breakfix}"
LAB_BOX="${LAB_BOX:-generic/alpine317}"   # small, works on libvirt and virtualbox

# --- Cosmetics ----------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    B="$(tput bold)"; R="$(tput setaf 1)"; G="$(tput setaf 2)"; Y="$(tput setaf 3)"; C="$(tput setaf 6)"; N="$(tput sgr0)"
else
    B=""; R=""; G=""; Y=""; C=""; N=""
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s%s%s\n' "$B$C" "$*" "$N"; }
ok()   { printf '%s[ OK ]%s %s\n'   "$G" "$N" "$*"; }
warn() { printf '%s[WARN]%s %s\n'   "$Y" "$N" "$*"; }
fail() { printf '%s[FAIL]%s %s\n'   "$R" "$N" "$*"; }

# --- Guardrails ---------------------------------------------------------------
guardrails() {
    if [ "$(id -u)" -eq 0 ]; then
        fail "Do not run this lab as root. Use your unprivileged user."
        exit 1
    fi
    if ! command -v vagrant >/dev/null 2>&1; then
        fail "The 'vagrant' binary was not found in PATH. Install Vagrant first."
        exit 1
    fi
}

# --- Detect an available provider so the Vagrantfile is realistic -------------
detect_provider() {
    if [ -n "${VAGRANT_DEFAULT_PROVIDER:-}" ]; then
        printf '%s' "$VAGRANT_DEFAULT_PROVIDER"; return
    fi
    if command -v virsh >/dev/null 2>&1 && vagrant plugin list 2>/dev/null | grep -q vagrant-libvirt; then
        printf 'libvirt'
    elif command -v VBoxManage >/dev/null 2>&1; then
        printf 'virtualbox'
    else
        printf 'virtualbox'   # sensible default; validate/up will tell you if it is absent
    fi
}

# --- Build the KNOWN-GOOD project, then inject the controlled fault -----------
setup() {
    local provider; provider="$(detect_provider)"

    head "Building the disposable Vagrant project"
    say  "Lab directory : ${B}${LAB_DIR}${N}"
    say  "Box           : ${B}${LAB_BOX}${N}"
    say  "Provider      : ${B}${provider}${N}"

    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR"
    cd "$LAB_DIR"

    # Write the Vagrantfile. Note the synced_folder line: the provisioner's
    # document root is backed by the host directory ./site.
    cat > Vagrantfile <<VAGRANTFILE
# -*- mode: ruby -*-
# vi: set ft=ruby :
# LPIC-3 305 :: 353.4 Vagrant :: web tier for the break & fix lab.
Vagrant.configure("2") do |config|
  config.vm.box      = "${LAB_BOX}"
  config.vm.hostname = "web353"

  # Objective 353.4: Vagrant networking.
  config.vm.network "private_network", ip: "192.168.56.30"
  config.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true

  # Objective 353.4: synced folders. The web document root is served from the
  # host directory ./site. 'create: false' means Vagrant must NOT create it —
  # the host path is expected to already exist.
  config.vm.synced_folder "./site", "/var/www/html", create: false

  config.vm.provider "${provider}" do |p|
    p.memory = 512
    p.cpus   = 1
  end

  # Objective 353.4: provisioners. Best-effort web server over the synced root.
  config.vm.provision "shell", inline: <<-SHELL
    set -e
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache nginx >/dev/null && mkdir -p /run/nginx
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null && apt-get install -y nginx >/dev/null
    fi
    ln -sfn /var/www/html /usr/share/nginx/html 2>/dev/null || true
    rc-service nginx restart 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    echo "[provision] document root:" && ls -1 /var/www/html || true
  SHELL
end
VAGRANTFILE

    # Bring the project to a healthy state first: the host document root exists.
    mkdir -p site
    cat > site/index.html <<'HTML'
<!doctype html><title>353.4</title><h1>web353 is serving the synced document root</h1>
HTML
    ok "Project created in a working state (host path ./site present)."

    # -------------------------------------------------------------------------
    # INJECT THE CONTROLLED FAULT
    # Simulate a teammate's over-eager cleanup that removed the document-root
    # host directory while the Vagrantfile still references it with create:false.
    # -------------------------------------------------------------------------
    rm -rf "$LAB_DIR/site"
    warn "Controlled fault injected: the host directory ./site was removed."

    print_briefing "$provider"
}

print_briefing() {
    local provider="$1"
    head "================  MISSION BRIEFING — 353.4 Vagrant  ================"
    cat <<BRIEF
Enter the lab:
    ${B}cd "$LAB_DIR"${N}

SYMPTOM you will observe
    Run either of these and the environment refuses to come up:
        ${B}vagrant validate${N}
        ${B}vagrant up${N}
    Vagrant aborts BEFORE the guest is usable, with a configuration error of
    the form:
        "The host path of the shared folder is missing: .../site"
    (message wording varies slightly by Vagrant version). The guest never
    finishes booting and no web page is served on http://127.0.0.1:8080/.

WHY it happens (think before you touch anything)
    The Vagrantfile declares:
        config.vm.synced_folder "./site", "/var/www/html", create: false
    'create: false' tells Vagrant the HOST path must already exist; Vagrant
    validates that during configuration, before the provider is ever invoked.
    The directory ./site is gone, so validation fails hard.

YOUR GOAL (definition of done)
    Make ${B}vagrant validate${N} exit 0 again AND keep the document root wired
    through the synced folder — do NOT simply delete the synced_folder line,
    that would remove the very feature this objective is about. The web tier
    must still serve content from the host directory.

CHECK YOURSELF
    ${B}$0 verify${N}
    Tear everything down when finished:
    ${B}$0 clean${N}

Provider in use: ${provider}. If it is not installed, 'vagrant up' will tell
you separately — but 'vagrant validate' reproduces THIS fault on its own.
BRIEF
}

# --- Student self-check -------------------------------------------------------
verify() {
    if [ ! -d "$LAB_DIR" ]; then
        fail "No lab found at $LAB_DIR. Run '$0' first."
        exit 1
    fi
    cd "$LAB_DIR"
    local score=0

    head "Verifying your fix"

    if [ -f "$LAB_DIR/site/index.html" ]; then
        ok "Host document root ./site/index.html exists again."
        score=$((score + 1))
    else
        fail "Host path ./site (with content) is still missing."
    fi

    if grep -q 'synced_folder' Vagrantfile; then
        ok "The synced_folder declaration is still present (feature preserved)."
        score=$((score + 1))
    else
        fail "The synced_folder line was removed — that defeats the objective."
    fi

    if vagrant validate >/dev/null 2>&1; then
        ok "'vagrant validate' now exits 0."
        score=$((score + 1))
    else
        fail "'vagrant validate' still reports a configuration error."
    fi

    echo
    if [ "$score" -eq 3 ]; then
        ok "${B}SOLVED.${N} Run 'vagrant up' to boot, then: curl http://127.0.0.1:8080/"
    else
        warn "Not there yet ($score/3). Re-read the briefing and try again."
    fi
}

clean() {
    head "Cleaning up the disposable lab"
    if [ -d "$LAB_DIR" ]; then
        ( cd "$LAB_DIR" && vagrant destroy -f >/dev/null 2>&1 || true )
        rm -rf "$LAB_DIR"
        ok "Guest destroyed and $LAB_DIR removed."
    else
        say "Nothing to clean; $LAB_DIR does not exist."
    fi
}

usage() {
    sed -n '3,40p' "$0"
}

# --- Dispatch -----------------------------------------------------------------
main() {
    guardrails
    case "${1:-setup}" in
        setup|"")     setup ;;
        verify|check) verify ;;
        clean|destroy) clean ;;
        help|-h|--help) usage ;;
        *) fail "Unknown command: $1"; usage; exit 1 ;;
    esac
}
main "$@"

# =============================================================================
# ===============  SOLUTION — read only after attempting it  ==================
# =============================================================================
#
# ROOT CAUSE
#   The Vagrantfile maps the guest document root from a host directory:
#       config.vm.synced_folder "./site", "/var/www/html", create: false
#   Vagrant validates synced-folder HOST paths at configuration time. With
#   'create: false', Vagrant will not create the directory for you, so when
#   ./site is absent the whole machine configuration is rejected and no
#   provider action (boot, mount, provision) ever runs.
#
# DIAGNOSIS, STEP BY STEP
#   1. Reproduce and read the exact error:
#          cd "$HOME/vagrant-lab-353.4-breakfix"
#          vagrant validate
#      -> reports the host path of the shared folder is missing (.../site).
#
#   2. Confirm what the Vagrantfile expects on the host side:
#          grep synced_folder Vagrantfile
#      -> first argument "./site" is the HOST path; second "/var/www/html"
#         is the GUEST mount point.
#
#   3. Confirm the host path is really gone:
#          ls -ld ./site        # -> "No such file or directory"
#
# FIX — choose the one that matches intent (any one restores 'vagrant validate'):
#
#   Option A (recommended — restore the expected host content):
#          mkdir -p site
#          echo '<h1>web353 restored</h1>' > site/index.html
#          vagrant validate        # -> exits 0
#          vagrant up              # boot; provisioner mounts ./site at /var/www/html
#          curl http://127.0.0.1:8080/
#
#   Option B (let Vagrant create the host directory automatically):
#          # In the Vagrantfile, flip the flag:
#          #   config.vm.synced_folder "./site", "/var/www/html", create: true
#          vagrant validate        # -> exits 0 (Vagrant will mkdir ./site)
#      Trade-off: an empty document root is created; the site starts blank.
#
#   Option C (the host content lives elsewhere — repoint the mapping):
#          # If the real content directory is, e.g., ./public, edit the line to:
#          #   config.vm.synced_folder "./public", "/var/www/html", create: false
#          vagrant validate
#      Trade-off: correct only when another valid host path genuinely exists.
#
#   NOT a fix: deleting the synced_folder line. It makes 'validate' pass but
#   silently drops the feature — the guest would then serve nothing from the
#   host, which is exactly what 353.4 tests you on.
#
# VERIFY AND RELOAD
#   If the guest was already running when you edited the Vagrantfile, apply the
#   configuration change with:
#          vagrant reload           # re-reads Vagrantfile, re-mounts synced folders
#   then re-run the provisioner if needed:
#          vagrant provision
#   Full self-check:
#          ./353.4-vagrant-breakfix.sh verify
#
# KEY TAKEAWAYS (exam-relevant)
#   * synced_folder's FIRST argument is the host path, SECOND is the guest path.
#   * 'create: false' (the default) makes the host path a hard prerequisite that
#     Vagrant validates before booting; 'create: true' lets Vagrant mkdir it.
#   * 'vagrant validate' catches configuration faults with zero provider cost —
#     use it as your first diagnostic before spending time on 'vagrant up'.
#   * 'vagrant reload' is how a running guest picks up Vagrantfile changes;
#     'vagrant provision' re-runs provisioners without a full reboot.
#
# Source: LPI Exam 305-300 objectives, topic 353.4 (Vagrant):
#   https://www.lpi.org/our-certifications/exam-305-objectives/
# =============================================================================