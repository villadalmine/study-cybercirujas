#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 305 (exam 305-300, v3.0) — Topic 353.2: Packer  (exam weight 3.33)
#  BREAK & FIX LAB — "the build that forgot its builder"
# ============================================================================
#
#  What this lab exercises (LPI 353.2 key knowledge areas):
#    - Understand the architecture and functioning of Packer
#    - Understand and create/maintain Packer templates (HCL2 format)
#    - Understand the relationship between `source` and `build` blocks
#    - Use packer init / validate / inspect / fmt for diagnosis
#
#  Design goals:
#    - SAFE: everything lives inside a dedicated lab directory under $HOME.
#            No sudo, no system files touched. We only ever run
#            `packer validate` / `packer inspect` — never `packer build` —
#            so no QEMU VM is ever launched and nothing on the host changes.
#    - CONTROLLED: exactly ONE fault is injected, at the HCL reference layer.
#    - REVERSIBLE / IDEMPOTENT: re-running rebuilds the lab from scratch.
#
#  Sources (official):
#    - LPI 305 objectives: https://www.lpi.org/our-certifications/exam-305-objectives/
#    - HCL2 templates:     https://developer.hashicorp.com/packer/docs/templates/hcl_templates
#    - build block:        https://developer.hashicorp.com/packer/docs/templates/hcl_templates/blocks/build
#    - source block:       https://developer.hashicorp.com/packer/docs/templates/hcl_templates/blocks/source
#    - packer{} block:     https://developer.hashicorp.com/packer/docs/templates/hcl_templates/blocks/packer
#    - packer init:        https://developer.hashicorp.com/packer/docs/commands/init
#    - QEMU builder:       https://developer.hashicorp.com/packer/integrations/hashicorp/qemu
# ----------------------------------------------------------------------------

set -uo pipefail

# --- Cosmetics --------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
  YEL="$(printf '\033[33m')"; CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RST"; }

# --- Safe, dedicated, disposable lab directory ------------------------------
LAB_DIR="${HOME}/lab-353.2-packer"
TEMPLATE="ubuntu.pkr.hcl"

# Guardrails: never operate outside a clearly-owned lab path.
case "$LAB_DIR" in
  "$HOME"/lab-353.2-packer) : ;;
  *) say "${RED}Refusing to use unsafe LAB_DIR='$LAB_DIR'${RST}"; exit 1 ;;
esac

# --- Preconditions ----------------------------------------------------------
head "Checking preconditions"
if ! command -v packer >/dev/null 2>&1; then
  say "${RED}Packer is not installed.${RST}"
  say "Install it on a Debian/Ubuntu lab VM with:"
  say "  wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg"
  say '  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list'
  say "  sudo apt-get update && sudo apt-get install -y packer"
  say "Docs: https://developer.hashicorp.com/packer/install"
  exit 1
fi
say "Found: $(packer version | head -n1)"
say "Note: the QEMU *plugin binary* is enough for 'packer validate';"
say "      you do NOT need qemu-kvm installed for this lab."

# --- (Re)create a clean lab from scratch (idempotent) -----------------------
head "Creating a clean lab in ${CYN}${LAB_DIR}${RST}"
rm -rf -- "$LAB_DIR"
mkdir -p -- "$LAB_DIR"
cd -- "$LAB_DIR"

# Known-GOOD, production-shaped QEMU template. Quoted heredoc => no shell
# expansion, so 'var.*' references reach the file verbatim.
cat > "$TEMPLATE" <<'PKRTEMPLATE'
# Production-shaped QEMU image build for Ubuntu Server.
# HCL2 format. Reference: https://developer.hashicorp.com/packer/docs/templates/hcl_templates

packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "URL or local path to the installer ISO."
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
}

variable "iso_checksum" {
  type        = string
  description = "ISO checksum, prefixed with its algorithm (validated, not fetched)."
  default     = "sha256:d6dab0c3a657988501b4bd76f1297c053df710e06e0c3aece60dead24f270b4d"
}

variable "disk_size" {
  type        = string
  description = "Backing disk size."
  default     = "10240M"
}

# A 'source' block is a REUSABLE builder definition. It is addressed elsewhere
# as  source.<builder-type>.<name>  ->  here that is  source.qemu.ubuntu
source "qemu" "ubuntu" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "output-ubuntu"
  disk_size        = var.disk_size
  format           = "qcow2"
  accelerator      = "kvm"
  headless         = true
  memory           = 2048
  cpus             = 2
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  boot_wait        = "5s"
  ssh_username     = "ubuntu"
  ssh_password     = "ubuntu"
  ssh_timeout      = "20m"
  shutdown_command = "echo 'ubuntu' | sudo -S shutdown -P now"
}

# A 'build' block WIRES one or more sources to provisioners/post-processors.
build {
  name    = "ubuntu-noble"
  sources = ["source.qemu.ubuntu"]

  provisioner "shell" {
    inline = [
      "echo 'Image provisioned by Packer'",
      "cloud-init status --wait || true",
      "sudo apt-get update",
    ]
  }

  post-processor "manifest" {
    output = "manifest.json"
  }
}
PKRTEMPLATE

say "Wrote ${CYN}${TEMPLATE}${RST}"

# --- Install the plugin (one-time, needs network) ---------------------------
head "Running 'packer init' (downloads the QEMU plugin binary)"
if ! packer init . ; then
  say ""
  say "${YEL}'packer init' failed — most likely no network to reach the plugin"
  say "registry. Give the lab VM outbound access ONCE and re-run this script.${RST}"
  say "Without the plugin, 'packer validate' would fail for the wrong reason"
  say "and muddy the exercise, so stopping here."
  exit 1
fi
say "${GRN}Plugin installed.${RST}"

# --- Prove the template is otherwise healthy BEFORE we break it -------------
head "Baseline check on the known-good template"
if packer validate . >/dev/null 2>&1; then
  say "${GRN}Baseline 'packer validate .' PASSED — template is sound.${RST}"
else
  say "${YEL}Baseline validation did not pass in this environment.${RST}"
  say "The injected fault below is still the single intended change."
fi

# ============================================================================
#  INJECT THE FAULT  (the ONLY change from the known-good template)
#  We point the build block at a source name that no source block defines.
# ============================================================================
head "Injecting a single, controlled fault"
sed -i 's#\["source\.qemu\.ubuntu"\]#["source.qemu.ubuntu-server"]#' "$TEMPLATE"
say "Done. The lab is now in a broken state."

# ============================================================================
#  STUDENT BRIEFING
# ============================================================================
cat <<BRIEF

${BOLD}=====================  BREAK & FIX — Topic 353.2 Packer  =====================${RST}

  Lab directory:  ${CYN}${LAB_DIR}${RST}
  Template:       ${CYN}${TEMPLATE}${RST}

${BOLD}THE SYMPTOM${RST}
  From inside the lab directory, run:

      cd ${LAB_DIR}
      packer validate .

  Packer exits ${RED}non-zero${RST} and prints an error similar to:

      ${RED}Error: Unknown source source.qemu.ubuntu-server${RST}
        on ${TEMPLATE}, in the build block:
          sources = ["source.qemu.ubuntu-server"]

  Notice what is NOT the problem:
    * 'packer init' succeeded  -> the QEMU plugin is fine.
    * There is no HCL syntax error (no unbalanced braces, no bad tokens).
  So this is a ${BOLD}reference / wiring${RST} problem inside the template itself,
  not a plugin problem and not a syntax problem. In a real 'packer build'
  this fails instantly, before any VM is ever booted.

${BOLD}YOUR GOAL${RST}
  Make this command succeed again:

      packer validate .        ->   ${GRN}"The configuration is valid."${RST}

  Constraints (so you fix it, not gut it):
    * Do NOT delete the build block, the provisioner, or the source block.
    * The build must still produce the QEMU image from the defined source.
  You must reconcile the reference between the ${BOLD}source${RST} block and the
  ${BOLD}build${RST} block.

${BOLD}HINTS${RST}
  1. A source is addressed as   source.<builder-type>.<name> .
     Compare the label of  source "qemu" "____"  with the string inside
     the build block's  sources = ["source.qemu.____"] .
  2. Ask Packer what sources it actually sees:
         packer inspect .
     The 'builds' section lists the sources Packer knows about.
  3. Auto-format after editing to catch stray mistakes:
         packer fmt .

  The step-by-step solution is at the very bottom of this script, commented out.
  Try it yourself first.

${BOLD}=============================================================================${RST}
BRIEF

exit 0

# ============================================================================
#  ============================  SOLUTION  ==================================
#  (Read only after attempting the fix yourself.)
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  Packer's HCL2 model separates the *definition* of a builder from its *use*:
#
#    * A `source "qemu" "ubuntu" { ... }` block DEFINES a reusable builder
#      configuration. Its address is  source.qemu.ubuntu
#      (that is  source.<builder-type>.<block-label>).
#
#    * A `build { sources = [...] }` block REFERENCES one or more of those
#      addresses and attaches provisioners/post-processors to them.
#
#  The injected fault changed the build reference to `source.qemu.ubuntu-server`,
#  but no source block carries the label `ubuntu-server`. The build therefore
#  points at a builder that does not exist, so Packer has nothing to build and
#  refuses the whole configuration:  "Unknown source source.qemu.ubuntu-server".
#
#  DIAGNOSIS
#  ---------
#    cd ~/lab-353.2-packer
#    packer validate .        # shows: Unknown source source.qemu.ubuntu-server
#    packer inspect .         # shows the ONLY real source is: qemu.ubuntu
#                             # => the build references a name inspect never lists
#
#  FIX (option A — correct the reference; recommended, smallest change)
#  --------------------------------------------------------------------
#    Edit ubuntu.pkr.hcl and, inside the build block, change:
#        sources = ["source.qemu.ubuntu-server"]
#    back to:
#        sources = ["source.qemu.ubuntu"]
#
#    Or apply it non-interactively:
#        sed -i 's/source\.qemu\.ubuntu-server/source.qemu.ubuntu/' ubuntu.pkr.hcl
#
#  FIX (option B — rename the source instead; also valid)
#  ------------------------------------------------------
#    Keep the build reference and rename the source block label so both match:
#        source "qemu" "ubuntu" {   ->   source "qemu" "ubuntu-server" {
#    Either way the rule is identical: the label after the builder type and the
#    string inside sources[] must name the SAME source block.
#
#  VERIFY
#  ------
#    packer fmt .             # normalize formatting (exit 0, maybe reformats)
#    packer validate .        # expected: "The configuration is valid."
#    echo $?                  # expected: 0
#    packer inspect .         # the build 'ubuntu-noble' now lists source qemu.ubuntu
#
#  WHY THIS MATTERS IN PRODUCTION
#  ------------------------------
#  This exact bug appears when someone renames or splits a source block (e.g.
#  parameterising per-distro sources) and forgets to update every build's
#  sources[] list. `packer validate` (ideally in CI) catches it in milliseconds,
#  long before a multi-gigabyte image build wastes a QEMU run. The habit to
#  build: run `packer fmt -check` and `packer validate` as a gate before any
#  `packer build`.
#    Docs: https://developer.hashicorp.com/packer/docs/templates/hcl_templates/blocks/build
#          https://developer.hashicorp.com/packer/docs/commands/validate
# ============================================================================