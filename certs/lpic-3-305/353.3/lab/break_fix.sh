#!/usr/bin/env bash
#
# =============================================================================
#  teach-plat  ::  break & fix lab
#  Certification : LPIC-3 305  (exam 305-300, version 3.0)
#  Topic         : 353.3  cloud-init            (exam weight: 5)
#  Skill drilled : cloud-config authoring, schema validation, boot-stage
#                  diagnostics, state inspection and clean re-run
#  Reference     : https://www.lpi.org/our-certifications/exam-305-objectives/
#                  https://cloudinit.readthedocs.io/en/latest/reference/cli.html
#                  https://cloudinit.readthedocs.io/en/latest/reference/modules.html
#
#  WHAT THIS DOES
#  This script installs a *syntactically valid but schema-invalid* cloud-config
#  drop-in into /etc/cloud/cloud.cfg.d/. cloud-init merges every *.cfg there into
#  the instance configuration, so the fault is real: on the next boot (or a forced
#  re-run) the affected modules are skipped and warnings are logged. The break is
#  read-only-surfaceable — you diagnose it with `cloud-init schema` without having
#  to reboot — and it is undone by editing or removing a single file.
#
#  RUN ONLY ON A DISPOSABLE LAB VM. It touches system cloud-init configuration.
# =============================================================================

set -uo pipefail

BREAK_FILE="/etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg"
BACKUP_DIR="/root/teach-plat-lab-backup/353.3"
MARKER="/etc/teach-plat/353.3-break.active"

# -----------------------------------------------------------------------------
# Safety guards
# -----------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (the break edits /etc/cloud/cloud.cfg.d/)." >&2
    exit 1
fi

if ! command -v cloud-init >/dev/null 2>&1; then
    echo "ERROR: cloud-init is not installed on this host." >&2
    echo "       Debian/Ubuntu: apt-get install -y cloud-init" >&2
    echo "       RHEL/openSUSE : zypper/dnf install -y cloud-init" >&2
    exit 1
fi

if [[ "${LAB_VM:-no}" != "yes" ]]; then
    echo "REFUSING TO RUN: this modifies system cloud-init config."
    echo "Confirm this is a THROWAWAY lab VM by re-running with:"
    echo
    echo "    LAB_VM=yes $0"
    echo
    exit 1
fi

echo ">> cloud-init version: $(cloud-init --version 2>&1)"

# -----------------------------------------------------------------------------
# Back up anything we are about to shadow (idempotent: keep the first backup)
# -----------------------------------------------------------------------------
mkdir -p "${BACKUP_DIR}"
if [[ ! -f "${BACKUP_DIR}/.done" ]]; then
    cp -a /etc/cloud/cloud.cfg "${BACKUP_DIR}/cloud.cfg.orig" 2>/dev/null || true
    cp -a /etc/cloud/cloud.cfg.d "${BACKUP_DIR}/cloud.cfg.d.orig" 2>/dev/null || true
    touch "${BACKUP_DIR}/.done"
    echo ">> Original config backed up to ${BACKUP_DIR}"
else
    echo ">> Backup already present at ${BACKUP_DIR} (kept)"
fi

# -----------------------------------------------------------------------------
# THE BREAK
# The intent expressed below is legitimate and common:
#   1. refresh the package index at boot
#   2. run one command at boot
#   3. write one file to disk
# ...but EVERY key is given with the WRONG YAML TYPE. The document parses as YAML
# yet violates the cloud-config JSON schema, so cloud-init discards these modules.
# -----------------------------------------------------------------------------
cat > "${BREAK_FILE}" <<'BROKEN'
#cloud-config
# teach-plat 353.3 lab — intentionally schema-invalid cloud-config
# (valid YAML, invalid cloud-config schema — this is the whole point)

package_update: "yes"                 # WRONG: expects a boolean, got a string

runcmd: echo "lab started"            # WRONG: expects a list, got a scalar string

write_files:                          # WRONG: each item is missing required 'path'
  - content: "teach-plat 353.3 marker"
    permissions: 0644                 # WRONG: expects a string like "0644", not an int
BROKEN

mkdir -p "$(dirname "${MARKER}")"
date -u +"%Y-%m-%dT%H:%M:%SZ break installed" > "${MARKER}"
chmod 0644 "${BREAK_FILE}"

echo ">> Installed broken drop-in: ${BREAK_FILE}"

# -----------------------------------------------------------------------------
# Surface the symptom immediately (read-only — no reboot, no module execution)
# -----------------------------------------------------------------------------
echo
echo "=============================================================="
echo " SYMPTOM — this is what the validator now reports:"
echo "=============================================================="
cloud-init schema --config-file "${BREAK_FILE}" || true
echo "--------------------------------------------------------------"
echo "( `cloud-init schema --system` will also flag it once this drop-in"
echo "  is part of the merged instance config. On the next boot the"
echo "  runcmd / write_files / package modules are SKIPPED and you get"
echo "  WARNING lines in /var/log/cloud-init.log. )"

# -----------------------------------------------------------------------------
# Briefing for the student
# -----------------------------------------------------------------------------
cat <<'BRIEF'

==============================================================
 BREAK & FIX — Topic 353.3 cloud-init
==============================================================

WHAT JUST BROKE
  A cloud-config drop-in was installed at:
      /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg
  It is valid YAML but violates the cloud-config schema. cloud-init
  therefore refuses those modules: at boot they never run.

SYMPTOMS YOU CAN OBSERVE
  1) Schema validation fails:
         cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg
         cloud-init schema --system
     Both list the offending keys and the expected types.
  2) On a forced re-run (see below) cloud-init logs WARNINGs and the
     three intended effects DO NOT happen:
       - package index is NOT refreshed
       - the boot command does NOT run
       - the file is NOT written
  3) cloud-init status --long may report a degraded/error state.

YOUR OBJECTIVE
  Edit ONLY the drop-in file and make BOTH commands report success:
         cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg
         cloud-init schema --system
  Success looks like:  "Valid schema <file>"
  You MUST preserve the three intents (update packages, run one boot
  command, write one file). Deleting the keys is NOT a fix — correct
  the TYPE of each value. Do not touch /etc/cloud/cloud.cfg itself.

TOOLKIT YOU SHOULD REACH FOR (353.3)
  cloud-init schema --config-file <f>     validate one cloud-config file
  cloud-init schema --system              validate the merged instance config
  cloud-init status --long                overall state + last error
  cloud-init query userdata               show the rendered user-data
  cloud-init analyze show | blame         per-stage / per-module timing
  cloud-init clean --logs                 wipe state so config re-runs at boot
  /var/log/cloud-init.log                 module-level WARN/ERROR detail
  /var/log/cloud-init-output.log          stdout/stderr of runcmd & friends

HOW TO RE-TRIGGER cloud-init WITHOUT REBOOTING (optional, on the lab VM)
  Re-run a single module against the system config, forcing it:
      cloud-init single --name runcmd     --frequency always
      cloud-init single --name write_files --frequency always
  Or replay the whole config/final stages after wiping state:
      cloud-init clean --logs
      cloud-init init            # local + network datasource stages
      cloud-init modules --mode config
      cloud-init modules --mode final

WHEN YOU THINK YOU ARE DONE — self check
      cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg \
        && echo "PASS: file schema valid"
      cloud-init schema --system && echo "PASS: system schema valid"

==============================================================
BRIEF

exit 0

# =============================================================================
#  SOLUTION  (do not peek until you have tried) — step by step
# =============================================================================
#
#  STEP 0 — Understand the failure class
#  -------------------------------------
#  The document is valid YAML, so a plain `yamllint` or `python3 -c
#  'import yaml,sys;yaml.safe_load(open(sys.argv[1]))'` PASSES. The problem is
#  the cloud-config *schema*: a separate contract that says which keys exist and
#  what TYPE each value must be. That is why cloud-init has its own validator:
#      cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg
#
#  STEP 1 — Read the validator output and map each error to a key
#  --------------------------------------------------------------
#  You will see errors equivalent to (wording varies by cloud-init version):
#      package_update: 'yes' is not of type 'boolean'
#      runcmd: 'echo "lab started"' is not of type 'array'
#      write_files.0: 'path' is a required property
#      write_files.0.permissions: 0644 is not of type 'string'
#  Each line names the JSON-path of the offending value and the expected type.
#
#  STEP 2 — Correct each value to its proper type (keep the intent)
#  ---------------------------------------------------------------
#  - package_update  : boolean   ->  true          (not the string "yes")
#  - runcmd          : list      ->  a YAML list of commands
#  - write_files[].path : required string          (add it)
#  - permissions     : string    ->  "0644"        (quote it; a leading 0 as an
#                                                    int is also octal-ambiguous)
#
#  Replace the file contents with the corrected cloud-config below:
#
#      cat > /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg <<'FIXED'
#      #cloud-config
#      # teach-plat 353.3 lab — corrected cloud-config (types fixed, intent kept)
#
#      package_update: true
#
#      runcmd:
#        - echo "lab started" >> /var/log/teach-plat-lab.log
#
#      write_files:
#        - path: /etc/teach-plat/lab-marker
#          content: "teach-plat 353.3 marker"
#          permissions: "0644"
#      FIXED
#
#  STEP 3 — Re-validate (this is the objective)
#  --------------------------------------------
#      cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg
#      #   -> Valid schema /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg
#      cloud-init schema --system
#      #   -> Valid schema user-data
#
#  STEP 4 — Prove the modules now actually run (optional, lab VM only)
#  ------------------------------------------------------------------
#      cloud-init single --name write_files --frequency always
#      test -f /etc/teach-plat/lab-marker && echo "write_files applied"
#      cloud-init single --name runcmd --frequency always
#      grep -q "lab started" /var/log/teach-plat-lab.log && echo "runcmd applied"
#  Inspect what happened and when:
#      cloud-init status --long
#      cloud-init analyze blame
#      tail -n 40 /var/log/cloud-init.log
#      tail -n 40 /var/log/cloud-init-output.log
#
#  STEP 5 — Full restore of the original machine state
#  ---------------------------------------------------
#      rm -f /etc/cloud/cloud.cfg.d/99-teach-plat-lab.cfg
#      # (or restore everything captured at break time)
#      cp -a /root/teach-plat-lab-backup/353.3/cloud.cfg.d.orig/. /etc/cloud/cloud.cfg.d/
#      rm -f /etc/teach-plat/353.3-break.active
#      cloud-init schema --system && echo "clean"
#
#  KEY TAKEAWAYS FOR THE EXAM
#  --------------------------
#  * Every file in /etc/cloud/cloud.cfg.d/*.cfg is merged into the instance
#    config in lexical order; a bad drop-in silently disables its own modules.
#  * `cloud-init schema` validates the SCHEMA, which is stricter than YAML
#    syntax — quote booleans/octal-looking values only when the schema asks for
#    a string, and give lists where lists are required (runcmd, bootcmd).
#  * The boot stages are: local -> network -> config -> final. `runcmd` runs in
#    the final stage; `bootcmd` runs earlier (network stage) on every boot.
#  * State lives under /var/lib/cloud/; `cloud-init clean` removes it so config
#    re-runs on next boot. `--frequency always` forces a per-boot module to
#    re-execute now.
# =============================================================================