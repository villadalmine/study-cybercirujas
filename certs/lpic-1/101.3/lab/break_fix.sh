#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-1 (Exam 101-500, v5.0) — Topic 101.3
#  "Change runlevels / boot targets and shutdown or reboot system"
#  Exam weight: 4.69
#
#  BREAK & FIX LABORATORY  —  systemd default target sabotage
#
#  Reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#             https://www.freedesktop.org/software/systemd/man/systemctl.html
#             https://www.freedesktop.org/software/systemd/man/systemd.special.html
#             https://www.freedesktop.org/software/systemd/man/systemd.target.html
#             https://www.gnu.org/software/coreutils/manual/html_node/who-invocation.html
#
#  !!!  DESTRUCTIVE  !!!
#  Run ONLY inside a disposable laboratory VM that you can snapshot and roll
#  back. Never run this on a workstation, a jump host, or anything in
#  production. This script deliberately leaves the machine in a state where the
#  NEXT boot does not reach the graphical/multi-user environment you expect,
#  and where `shutdown`/`reboot` behave in a way you must diagnose.
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

readonly LAB_ID="lpic1-101.3-breakfix"
readonly BACKUP_DIR="/root/.${LAB_ID}.backup"
readonly STATE_FILE="${BACKUP_DIR}/state.env"
readonly BROKEN_TARGET="/etc/systemd/system/lab-broken.target"
readonly DEFAULT_LINK="/etc/systemd/system/default.target"
readonly SHUTDOWN_BLOCKER="/etc/systemd/system/lab-shutdown-blocker.service"
readonly NOLOGIN_FILE="/run/nologin"

# ------------------------------------------------------------------------------
# Guard rails
# ------------------------------------------------------------------------------

die() { printf '\n[FATAL] %s\n\n' "$*" >&2; exit 1; }
info() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "This lab must run as root (sudo -i, then re-run)."
}

require_systemd() {
    # systemd exposes /run/systemd/system while it is PID 1. This is the
    # canonical, documented detection method (sd_booted(3)).
    [[ -d /run/systemd/system ]] \
        || die "This VM is not booted with systemd as PID 1. This lab targets systemd."
    [[ "$(ps -o comm= -p 1)" == "systemd" ]] \
        || die "PID 1 is '$(ps -o comm= -p 1)', not systemd."
}

require_disposable() {
    # Refuse to run on anything that smells like a real machine.
    if [[ -f /etc/lpic1-lab-vm ]]; then
        info "Lab marker /etc/lpic1-lab-vm found. Proceeding."
        return 0
    fi

    cat <<'EOF'

  ############################################################################
  #                                                                          #
  #   WARNING — THIS SCRIPT BREAKS THE BOOT TARGET OF THIS MACHINE.          #
  #                                                                          #
  #   After running it, the next reboot will NOT reach the multi-user or     #
  #   graphical environment. You will land somewhere unfamiliar and you      #
  #   will have to repair it yourself.                                       #
  #                                                                          #
  #   Only continue if:                                                      #
  #     * this is a throw-away laboratory VM, AND                            #
  #     * you have a snapshot you can roll back to, AND                      #
  #     * you have console access (NOT only SSH) to this VM.                 #
  #                                                                          #
  #   Console access is mandatory: part of the breakage removes your         #
  #   ability to log in over the network.                                    #
  #                                                                          #
  ############################################################################

EOF
    read -r -p "  Type exactly: BREAK MY LAB VM  > " confirmation
    [[ "${confirmation}" == "BREAK MY LAB VM" ]] \
        || die "Confirmation phrase not given. Nothing was changed."

    read -r -p "  Do you have CONSOLE access to this VM (not just SSH)? [yes/no] > " console_ok
    [[ "${console_ok}" == "yes" ]] \
        || die "Get console access first (virt-manager, virsh console, VirtualBox window, hypervisor web console). Nothing was changed."
}

# ------------------------------------------------------------------------------
# Backup — so the instructor (and a desperate student) can always recover
# ------------------------------------------------------------------------------

take_backup() {
    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"

    local previous_default
    previous_default="$(systemctl get-default)"

    {
        printf 'LAB_ID=%s\n' "${LAB_ID}"
        printf 'PREVIOUS_DEFAULT_TARGET=%s\n' "${previous_default}"
        printf 'BROKEN_AT=%s\n' "$(date --iso-8601=seconds)"
        printf 'KERNEL=%s\n' "$(uname -r)"
    } > "${STATE_FILE}"
    chmod 600 "${STATE_FILE}"

    # Preserve the symlink itself, not the file it points at.
    if [[ -L "${DEFAULT_LINK}" ]]; then
        cp --no-dereference --preserve=all \
           "${DEFAULT_LINK}" "${BACKUP_DIR}/default.target.symlink" 2>/dev/null || true
    fi

    info "Backup written to ${BACKUP_DIR}"
    info "Previous default target recorded: ${previous_default}"
}

# ------------------------------------------------------------------------------
# BREAKAGE 1 — point the default boot target at a dead-end custom target
#
# Instead of the obvious `systemctl set-default rescue.target`, we create a
# target unit that pulls in almost nothing: it requires sysinit.target and
# activates a console, but does NOT pull in multi-user.target. The machine
# therefore boots, reaches a usable console, and stops there — no network
# services, no display manager, no getty on the usual VTs.
#
# This is a realistic misconfiguration: an admin who hand-writes a target unit
# and forgets `Requires=`/`After=` on the parts they actually need.
# ------------------------------------------------------------------------------

break_default_target() {
    info "Creating dead-end target unit ${BROKEN_TARGET} ..."

    cat > "${BROKEN_TARGET}" <<'UNIT'
[Unit]
Description=LPIC-1 lab dead-end target (101.3 break & fix)
Documentation=man:systemd.special(7) man:systemd.target(5)
Requires=sysinit.target
After=sysinit.target
Conflicts=rescue.service rescue.target
AllowIsolate=yes
UNIT

    chmod 644 "${BROKEN_TARGET}"

    # A single emergency console so the VM is recoverable from the hypervisor
    # window. Without this the student would have nothing at all to type into.
    mkdir -p "${BROKEN_TARGET}.wants"
    ln -sfn /usr/lib/systemd/system/emergency.service \
            "${BROKEN_TARGET}.wants/emergency.service" 2>/dev/null \
        || ln -sfn /lib/systemd/system/emergency.service \
                   "${BROKEN_TARGET}.wants/emergency.service"

    info "Repointing default.target at the dead-end target ..."
    systemctl set-default lab-broken.target >/dev/null

    systemctl daemon-reload
    info "default.target now resolves to: $(systemctl get-default)"
}

# ------------------------------------------------------------------------------
# BREAKAGE 2 — block clean shutdown/reboot with a hanging pre-stop unit
#
# A oneshot unit with RemainAfterExit=yes and a long-running ExecStop that
# systemd must wait for. `systemctl reboot` will appear to hang: the student
# watches "A stop job is running for ... (1min 30s / 10min)".
#
# Mechanics being taught:
#   * systemd stops units in reverse dependency order before entering
#     reboot.target / poweroff.target.
#   * DefaultTimeoutStopSec (and per-unit TimeoutStopSec) bound that wait.
#   * `systemctl reboot -i` / `--force` / `--force --force` escalate:
#     --force skips the ordinary job queue, --force --force is an immediate
#     kernel-level reboot with no unmount (reboot(2) directly).
# ------------------------------------------------------------------------------

break_shutdown_path() {
    info "Installing shutdown blocker unit ${SHUTDOWN_BLOCKER} ..."

    cat > "${SHUTDOWN_BLOCKER}" <<'UNIT'
[Unit]
Description=LPIC-1 lab shutdown blocker (101.3 break & fix)
Documentation=man:systemd.service(5) man:systemctl(1)
DefaultDependencies=no
Before=shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
# systemd waits for this on every stop of the unit, i.e. on every shutdown.
ExecStop=/bin/sleep 600
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
UNIT

    chmod 644 "${SHUTDOWN_BLOCKER}"
    systemctl daemon-reload
    systemctl enable --now lab-shutdown-blocker.service >/dev/null 2>&1 || true

    info "Shutdown blocker armed."
}

# ------------------------------------------------------------------------------
# BREAKAGE 3 — leave a stale /run/nologin
#
# `shutdown +15` creates /run/nologin to refuse new non-root logins while the
# shutdown is pending. If the shutdown is cancelled uncleanly, or written by
# hand, the file survives and PAM (pam_nologin.so) keeps rejecting every
# non-root login — a classic "nobody can log in but nothing is broken" ticket.
# ------------------------------------------------------------------------------

break_login_path() {
    info "Planting stale ${NOLOGIN_FILE} ..."
    printf '%s\n' \
        "System is going down for maintenance." \
        "Only root may log in until this file is removed." \
        > "${NOLOGIN_FILE}"
    chmod 644 "${NOLOGIN_FILE}"
    info "Non-root logins are now refused by pam_nologin."
}

# ------------------------------------------------------------------------------
# Briefing shown to the student
# ------------------------------------------------------------------------------

print_briefing() {
    cat <<'BRIEF'

================================================================================
  LPIC-1 101.3 — BREAK & FIX — INCIDENT BRIEFING
================================================================================

  The machine has been sabotaged in three related ways. Your job is to
  diagnose and repair it using only standard tooling. Do NOT restore from a
  snapshot — the snapshot is your safety net, not your solution.

--------------------------------------------------------------------------------
  SYMPTOM 1 — the machine no longer boots into its normal environment
--------------------------------------------------------------------------------

  Reboot the VM (see SYMPTOM 2 first — rebooting is itself broken).

  What you will see on the console:

    * Boot proceeds normally through the initramfs and the kernel messages.
    * sysinit.target completes.
    * Then everything stops. No display manager, no login prompt on tty1,
      no sshd, no network services.
    * You are dropped into an emergency shell that says something like:

        You are in emergency mode. After logging in, type "journalctl -xb"
        to view system logs, "systemctl reboot" to reboot, or "exit" to
        continue bootup.

        Give root password for maintenance
        (or press Control-D to continue):

    * `systemctl list-units --type=target` shows a target you have never
      seen before, and multi-user.target is NOT active.

  WHAT YOU MUST ACHIEVE:
    Bring the running system up to its normal environment WITHOUT rebooting,
    and then make that environment the default for every future boot. Prove
    it: `systemctl get-default` must report the correct target and
    `systemctl is-active multi-user.target` (or graphical.target) must
    report "active". Remove the offending unit file so it cannot come back.

  BONUS (do this one from the GRUB menu, it is exam-relevant):
    Reboot, interrupt GRUB, press `e`, and append a kernel parameter to the
    `linux` line so that this boot ignores the broken default target
    entirely. Which parameter? What is the SysV-era equivalent you would
    append on a machine using classic init?

--------------------------------------------------------------------------------
  SYMPTOM 2 — `reboot` and `shutdown` hang
--------------------------------------------------------------------------------

  Run `systemctl reboot` (or `shutdown -r now`). What you will see:

    * The command returns, the session drops, the console switches to the
      shutdown plymouth/text screen.
    * Then it sits there. After ~90 seconds a red line appears:

        [  *** ] A stop job is running for LPIC-1 lab shutdown blocker
                 (1min 32s / 10min)

    * The counter climbs toward 10 minutes before the machine finally goes
      down.

  WHAT YOU MUST ACHIEVE:
    a) Identify WHICH unit is holding the shutdown, from the running system,
       before you attempt the reboot. `systemd-analyze` and `systemctl`
       both have a way to show you.
    b) Get the machine down NOW, this once, without waiting 10 minutes —
       using the escalation switches that `systemctl(1)` documents. Know the
       difference between the plain call, one `--force`, and two `--force`,
       and know which of those risks a dirty filesystem.
    c) Make the hang stop permanently.

--------------------------------------------------------------------------------
  SYMPTOM 3 — only root can log in
--------------------------------------------------------------------------------

  From the console, log in as your normal (non-root) user. What you will
  see, on a correct password:

        System is going down for maintenance.
        Only root may log in until this file is removed.

    ... and the login is refused. `su - <user>` from root still works, and
    the password is not wrong. /var/log/secure (or /var/log/auth.log) shows
    a pam_nologin denial.

  WHAT YOU MUST ACHIEVE:
    Explain which PAM module produced that message, find the file it reads,
    and restore normal logins. Then answer: which normal, non-sabotage
    command creates that file, and what removes it again?

--------------------------------------------------------------------------------
  EXAM-RELEVANT QUESTIONS TO ANSWER BEFORE READING THE SOLUTION
--------------------------------------------------------------------------------

   1. What is the difference between `systemctl isolate X` and
      `systemctl set-default X`? Which one survives a reboot?
   2. Which SysV runlevel does each of these targets correspond to:
      poweroff.target, rescue.target, multi-user.target, graphical.target,
      reboot.target? Where does systemd document that mapping?
   3. What does `/etc/systemd/system/default.target` actually contain on a
      healthy machine? Is it a file or a symlink? Pointing where?
   4. `runlevel` prints "N 5". What do the two fields mean, and where does
      the command read them from?
   5. `who -r` and `runlevel` disagree with `systemctl get-default` on a
      systemd machine. Why is that not a contradiction?
   6. Write the single command that reboots the machine in 20 minutes and
      sends "patching window" to every logged-in user. Then cancel it.
   7. What does `wall` do, and what does `shutdown -k` do?
   8. `AllowIsolate=yes` — what breaks if a target unit lacks it and you
      try to isolate to it?
   9. Where does `systemctl set-default` write, and why does it never touch
      /usr/lib/systemd/system/?
  10. Which command tells you, on a running system, how long the previous
      boot took and which units were slowest to start?

================================================================================
  When you are done, or genuinely stuck, read the commented SOLUTION block
  at the bottom of this script:   less "$0"
================================================================================

BRIEF
}

# ------------------------------------------------------------------------------
# Optional teardown, for instructors resetting the lab between students
# ------------------------------------------------------------------------------

restore_lab() {
    [[ -f "${STATE_FILE}" ]] \
        || die "No lab state found at ${STATE_FILE}. Nothing to restore."

    # shellcheck disable=SC1090
    source "${STATE_FILE}"

    info "Restoring default target to ${PREVIOUS_DEFAULT_TARGET} ..."
    systemctl set-default "${PREVIOUS_DEFAULT_TARGET}" >/dev/null

    info "Removing sabotage units ..."
    systemctl disable --now lab-shutdown-blocker.service >/dev/null 2>&1 || true
    rm -f "${SHUTDOWN_BLOCKER}"
    rm -rf "${BROKEN_TARGET}.wants"
    rm -f "${BROKEN_TARGET}"
    rm -f "${NOLOGIN_FILE}"

    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true

    info "Lab restored. Current default: $(systemctl get-default)"
    info "Verify with: systemctl get-default && systemctl is-active multi-user.target"
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------

main() {
    local action="${1:-break}"

    require_root
    require_systemd

    case "${action}" in
        break)
            require_disposable
            take_backup
            break_default_target
            break_shutdown_path
            break_login_path
            print_briefing
            warn "The system is now sabotaged. Reboot when you are ready to start."
            warn "Instructor reset:  $0 restore"
            ;;
        restore)
            restore_lab
            ;;
        *)
            die "Usage: $0 [break|restore]"
            ;;
    esac
}

main "$@"

# ==============================================================================
# ==============================================================================
#
#   S O L U T I O N   —   step by step
#
#   Do not read this until you have tried. Everything below is commented out
#   and never executes.
#
# ==============================================================================
# ==============================================================================
#
# ------------------------------------------------------------------------------
# STEP 0 — Where am I? Establish the current state before changing anything.
# ------------------------------------------------------------------------------
#
#   # systemctl get-default
#   lab-broken.target
#
#   # systemctl is-active multi-user.target
#   inactive
#
#   # systemctl list-units --type=target --all --no-pager
#     UNIT                   LOAD   ACTIVE   SUB    DESCRIPTION
#     basic.target           loaded inactive dead   Basic System
#     emergency.target       loaded active   active Emergency Mode
#     lab-broken.target      loaded active   active LPIC-1 lab dead-end target
#     local-fs.target        loaded active   active Local File Systems
#     multi-user.target      loaded inactive dead   Multi-User System
#     sysinit.target         loaded active   active System Initialization
#
#   # runlevel
#   N 5
#   # who -r
#            run-level 5  2026-08-25 10:14
#
#   Note the disagreement: `runlevel` and `who -r` read the utmp records that
#   systemd writes for backwards compatibility (systemd-update-utmp.service).
#   They describe the SysV-compatible runlevel of the LAST recorded
#   transition, not the systemd default target. `systemctl get-default` is
#   authoritative on a systemd machine. Both fields of `runlevel` are
#   "previous current"; N means "none" — there was no previous runlevel since
#   boot.
#
# ------------------------------------------------------------------------------
# STEP 1 — Recover the RUNNING system without rebooting (SYMPTOM 1, part a)
# ------------------------------------------------------------------------------
#
#   isolate = "activate this target and stop every unit that is not part of
#   it". This is the systemd equivalent of `telinit 3` / `init 5`.
#
#   # systemctl isolate multi-user.target
#
#   ... or, on a desktop VM with a display manager:
#
#   # systemctl isolate graphical.target
#
#   Verify:
#
#   # systemctl is-active multi-user.target
#   active
#   # systemctl is-system-running
#   running
#
#   `isolate` only works on units with AllowIsolate=yes. All of the standard
#   runlevel-equivalent targets set it. If you isolate to a target that lacks
#   it you get:
#
#       Failed to isolate lab-example.target: Operation refused, unit may
#       not be isolated.
#
#   The SysV-compatible aliases still work and are exam-relevant — systemd
#   ships runlevel3.target -> multi-user.target and runlevel5.target ->
#   graphical.target as symlinks, and telinit/init are provided by systemd:
#
#   # init 3          # -> systemctl isolate multi-user.target
#   # telinit 5       # -> systemctl isolate graphical.target
#   # ls -l /usr/lib/systemd/system/runlevel[0-6].target
#
# ------------------------------------------------------------------------------
# STEP 2 — Fix the DEFAULT so future boots are correct (SYMPTOM 1, part b)
# ------------------------------------------------------------------------------
#
#   Isolating changed only the running system. The next boot still reads
#   /etc/systemd/system/default.target.
#
#   # ls -l /etc/systemd/system/default.target
#   lrwxrwxrwx. 1 root root 41 Aug 25 10:11 /etc/systemd/system/default.target
#       -> /etc/systemd/system/lab-broken.target
#
#   default.target is a SYMLINK, and `set-default` is nothing more than a
#   supported way to rewrite it. It writes under /etc/systemd/system/ —
#   never under /usr/lib/systemd/system/, because /usr belongs to the
#   distribution package manager and /etc is the local administrator's
#   override tree. That split is the whole point of systemd's unit search
#   path precedence: /etc > /run > /usr/lib.
#
#   # systemctl set-default multi-user.target
#   Removed /etc/systemd/system/default.target.
#   Created symlink /etc/systemd/system/default.target ->
#       /usr/lib/systemd/system/multi-user.target.
#
#   (Use graphical.target instead if this VM has a desktop.)
#
#   # systemctl get-default
#   multi-user.target
#
#   Now delete the sabotage unit so nothing can point back at it:
#
#   # rm -rf /etc/systemd/system/lab-broken.target.wants
#   # rm -f  /etc/systemd/system/lab-broken.target
#   # systemctl daemon-reload
#
#   Confirm systemd no longer knows about it:
#
#   # systemctl cat lab-broken.target
#   No files found for lab-broken.target.
#
# ------------------------------------------------------------------------------
# STEP 2b — The GRUB one-shot override (the bonus question)
# ------------------------------------------------------------------------------
#
#   If you could not log in at all, you would fix it from the boot loader.
#   At the GRUB menu press `e`, find the line starting with `linux` (or
#   `linux16`/`linuxefi`), go to the end of it and append ONE of:
#
#       systemd.unit=multi-user.target     # boot this target, this boot only
#       systemd.unit=rescue.target         # single-user-ish, minimal services
#       systemd.unit=emergency.target      # only / mounted read-only, no services
#
#   Then Ctrl-X (or F10) to boot. Nothing is written to disk — this is a
#   one-shot override, exactly the behaviour the exam expects you to know.
#
#   The classic SysV equivalents, still honoured by systemd for compatibility:
#
#       1        -> rescue.target      (single user)
#       3        -> multi-user.target
#       5        -> graphical.target
#       single   -> rescue.target
#       init=/bin/bash  -> replace PID 1 entirely, no init at all
#
#   Reference: man 7 systemd.special, man 1 systemd  ("Kernel Command Line").
#
# ------------------------------------------------------------------------------
# STEP 3 — Find what is blocking shutdown (SYMPTOM 2, part a)
# ------------------------------------------------------------------------------
#
#   Diagnose BEFORE you try to reboot. Two good tools:
#
#   # systemd-analyze critical-chain shutdown.target
#   # systemctl list-dependencies --before shutdown.target --no-pager
#
#   The blocker announces itself in its unit file. Read it:
#
#   # systemctl cat lab-shutdown-blocker.service
#   # /etc/systemd/system/lab-shutdown-blocker.service
#   [Unit]
#   Description=LPIC-1 lab shutdown blocker (101.3 break & fix)
#   DefaultDependencies=no
#   Before=shutdown.target
#   Conflicts=shutdown.target
#   [Service]
#   Type=oneshot
#   RemainAfterExit=yes
#   ExecStart=/bin/true
#   ExecStop=/bin/sleep 600
#   TimeoutStopSec=600
#
#   ExecStop=/bin/sleep 600 with TimeoutStopSec=600 is the whole story:
#   systemd must run ExecStop and wait for it before it may enter
#   shutdown.target, and the unit raised its own stop timeout to 10 minutes.
#   The "A stop job is running for ... (1min 32s / 10min)" line names the
#   unit — read it, it is telling you the answer.
#
#   The global default that a healthy unit would inherit:
#
#   # systemctl show --property=DefaultTimeoutStopUSec
#   DefaultTimeoutStopUSec=1min 30s
#
#   That is why 90 seconds is the familiar number: it is
#   DefaultTimeoutStopSec from /etc/systemd/system.conf.
#
# ------------------------------------------------------------------------------
# STEP 4 — Get the machine down NOW, this once (SYMPTOM 2, part b)
# ------------------------------------------------------------------------------
#
#   Escalation ladder, from safest to most brutal. Know all three:
#
#   1) # systemctl reboot
#      Normal path. Queues a job, stops every unit in reverse dependency
#      order, syncs and unmounts filesystems, then reboots. This is the one
#      that hangs here.
#
#   2) # systemctl reboot --force
#      Skips the ordinary job queue. systemd terminates processes itself and
#      still attempts to unmount filesystems, but does not run the full
#      graceful stop of every unit. Comparable to `reboot` from sysvinit's
#      point of view. Usually enough to escape a stuck stop job.
#
#   3) # systemctl reboot --force --force
#      Immediate reboot(2) syscall. No unmount, no sync, no unit stopping.
#      This is a hard reset in software. It WILL leave filesystems dirty —
#      expect an fsck/journal replay on the next boot. Last resort.
#
#   Also useful:
#
#   # systemctl reboot -i        # --ignore-inhibitors: override logind
#                                # inhibitor locks (e.g. "a package update
#                                # is running"). Different mechanism from
#                                # --force: inhibitors are advisory locks
#                                # taken by applications via logind.
#   # systemctl list-inhibitors  # who is holding one, and why
#
#   And, at the very bottom, the kernel's own magic SysRq — independent of
#   systemd entirely, useful when even PID 1 is wedged:
#
#   # echo 1 > /proc/sys/kernel/sysrq
#   # echo s > /proc/sysrq-trigger    # sync
#   # echo u > /proc/sysrq-trigger    # remount read-only
#   # echo b > /proc/sysrq-trigger    # reboot immediately
#
#   ("Raising Skinny Elephants Is Utterly Boring" — R E I S U B.)
#
# ------------------------------------------------------------------------------
# STEP 5 — Make the shutdown hang stop permanently (SYMPTOM 2, part c)
# ------------------------------------------------------------------------------
#
#   # systemctl disable --now lab-shutdown-blocker.service
#   Removed /etc/systemd/system/multi-user.target.wants/lab-shutdown-blocker.service.
#
#   `--now` also stops it — which itself takes 10 minutes because ExecStop is
#   the sleep. Do not wait. Kill the stop job first, then disable:
#
#   # systemctl kill --signal=SIGKILL --kill-whom=all lab-shutdown-blocker.service
#   # systemctl disable lab-shutdown-blocker.service
#   # rm -f /etc/systemd/system/lab-shutdown-blocker.service
#   # systemctl daemon-reload
#   # systemctl reset-failed
#
#   Verify the unit is gone, not merely stopped:
#
#   # systemctl cat lab-shutdown-blocker.service
#   No files found for lab-shutdown-blocker.service.
#
#   Then prove the fix by actually rebooting cleanly and timing it:
#
#   # systemd-analyze                      # boot time breakdown
#   # journalctl --list-boots              # the previous boots
#   # journalctl -b -1 -e                  # tail of the PREVIOUS boot —
#                                          # where a shutdown hang is logged
#
# ------------------------------------------------------------------------------
# STEP 6 — Restore non-root logins (SYMPTOM 3)
# ------------------------------------------------------------------------------
#
#   The message came from pam_nologin.so. It is in the `account` stack of
#   /etc/pam.d/login, /etc/pam.d/sshd and friends:
#
#   # grep -rn nologin /etc/pam.d/
#   /etc/pam.d/login:account    required     pam_nologin.so
#   /etc/pam.d/sshd:account     required     pam_nologin.so
#
#   pam_nologin refuses every non-root login while /run/nologin (historically
#   /etc/nologin) exists, and prints the file's contents as the reason.
#
#   # cat /run/nologin
#   System is going down for maintenance.
#   Only root may log in until this file is removed.
#
#   # rm -f /run/nologin
#
#   Log in again as the normal user — it works immediately, no service
#   restart needed, because PAM reads the file on every authentication.
#
#   WHO CREATES IT NORMALLY: `shutdown` does, once the shutdown is within
#   5 minutes of executing, so that no new user logs into a machine that is
#   about to disappear. Cancelling the shutdown removes it again:
#
#   # shutdown -r +15 "patching window, back in ~5 minutes"
#   Shutdown scheduled for Tue 2026-08-25 10:45:00 -03, use 'shutdown -c'
#   to cancel.
#
#   # shutdown -c
#   # ls /run/nologin
#   ls: cannot access '/run/nologin': No such file or directory
#
#   On systemd, `shutdown -c` also removes /run/systemd/shutdown/scheduled.
#   Inspect a pending shutdown with:
#
#   # systemctl show --property=ScheduledShutdown
#
# ------------------------------------------------------------------------------
# STEP 7 — Final verification checklist
# ------------------------------------------------------------------------------
#
#   # systemctl get-default
#   multi-user.target
#
#   # ls -l /etc/systemd/system/default.target
#   lrwxrwxrwx. 1 root root 41 ... -> /usr/lib/systemd/system/multi-user.target
#
#   # systemctl is-active multi-user.target
#   active
#
#   # systemctl is-system-running
#   running
#
#   # systemctl --failed --no-pager
#   0 loaded units listed.
#
#   # ls /etc/systemd/system/lab-*.target /etc/systemd/system/lab-*.service
#   ls: cannot access ...: No such file or directory
#
#   # ls /run/nologin
#   ls: cannot access '/run/nologin': No such file or directory
#
#   # reboot          # must complete in seconds, not minutes
#
# ------------------------------------------------------------------------------
# ANSWER KEY — the ten exam questions
# ------------------------------------------------------------------------------
#
#   1. `isolate` changes the RUNNING system now and is forgotten at reboot.
#      `set-default` rewrites the /etc/systemd/system/default.target symlink
#      and changes nothing right now, but every future boot follows it. You
#      normally want both.
#
#   2. poweroff.target = runlevel 0; rescue.target = runlevel 1 (single
#      user); multi-user.target = runlevels 2, 3 and 4; graphical.target =
#      runlevel 5; reboot.target = runlevel 6. Documented in
#      `man 7 systemd.special`, and materialised as runlevelN.target
#      symlinks under /usr/lib/systemd/system/.
#
#   3. It is a SYMLINK, not a regular file, normally pointing at
#      /usr/lib/systemd/system/graphical.target or .../multi-user.target.
#
#   4. "N 5" = previous runlevel, current runlevel. N means there was no
#      previous one since boot. `runlevel` reads the utmp database
#      (/var/run/utmp, i.e. /run/utmp), where systemd-update-utmp.service
#      writes SysV-compatible records.
#
#   5. Because they answer different questions. utmp records the last
#      SysV-style runlevel transition systemd chose to record for
#      compatibility; `get-default` reports the configured default target
#      for the NEXT boot. Neither is wrong; only `systemctl` is
#      authoritative about systemd's actual state.
#
#   6. # shutdown -r +20 "patching window"
#        ... the message is broadcast with wall to all logged-in users.
#      # shutdown -c
#        ... cancels it (and broadcasts the cancellation).
#
#   7. `wall` broadcasts a message to every logged-in terminal (it writes to
#      the tty of each user who has not disabled messages with `mesg n`).
#      `shutdown -k` sends the shutdown warning wall message and creates the
#      nologin condition WITHOUT actually shutting anything down — a drill.
#
#   8. Without AllowIsolate=yes, `systemctl isolate` refuses:
#      "Operation refused, unit may not be isolated." You can still `start`
#      the target; you just cannot make it THE active target and stop
#      everything else.
#
#   9. It writes /etc/systemd/system/default.target. /usr/lib/systemd/system
#      is owned by the package manager and is overwritten on updates; /etc
#      is the administrator's tree and takes precedence in systemd's unit
#      search path (/etc > /run > /usr/lib). Editing /usr would be silently
#      undone by the next package upgrade.
#
#  10. # systemd-analyze                 # total boot time, split
#                                        # firmware/loader/kernel/userspace
#      # systemd-analyze blame           # slowest units, descending
#      # systemd-analyze critical-chain  # the ordering chain that actually
#                                        # gated the boot
#
# ------------------------------------------------------------------------------
# SOURCES
# ------------------------------------------------------------------------------
#
#   LPI Exam 101-500 objectives, topic 101.3
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#   systemctl(1)
#     https://www.freedesktop.org/software/systemd/man/systemctl.html
#   systemd.special(7) — the standard targets and the runlevel mapping
#     https://www.freedesktop.org/software/systemd/man/systemd.special.html
#   systemd.target(5) / systemd.unit(5) — unit search path and precedence
#     https://www.freedesktop.org/software/systemd/man/systemd.target.html
#     https://www.freedesktop.org/software/systemd/man/systemd.unit.html
#   systemd(1) — "Kernel Command Line" (systemd.unit=)
#     https://www.freedesktop.org/software/systemd/man/systemd.html
#   shutdown(8), wall(1), runlevel(8)
#     https://www.freedesktop.org/software/systemd/man/shutdown.html
#     https://www.freedesktop.org/software/systemd/man/runlevel.html
#   pam_nologin(8)
#     http://www.linux-pam.org/Linux-PAM-html/sag-pam_nologin.html
#   Linux kernel — Magic SysRq key
#     https://www.kernel.org/doc/html/latest/admin-guide/sysrq.html
#
# ==============================================================================