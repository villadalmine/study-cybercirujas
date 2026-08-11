#!/usr/bin/env bash
#
# =====================================================================
#  LPIC-3 305 (exam 305-300, version 3.0)
#  Topic 352.1 — Container Virtualization Concepts   (exam weight: 11.67)
#  BREAK & FIX LAB — "the user namespace that runs out of disk"
# =====================================================================
#
#  WHY THIS LAB MAPS TO 352.1
#  --------------------------
#  OS-level virtualization (containers) is NOT a hypervisor. There is no
#  guest kernel and no emulated hardware: every container is just a set of
#  host processes that the SAME kernel isolates with three primitives —
#    * namespaces  -> what a process can SEE   (mnt, pid, net, uts, ipc,
#                                                user, cgroup, time)
#    * cgroups     -> how much it can USE       (cpu, memory, io, pids)
#    * capabilities/seccomp/LSM -> what it may DO (syscalls, privileges)
#  The USER namespace is the keystone of rootless/unprivileged containers:
#  it lets an ordinary UID become uid 0 *inside* an isolated namespace
#  while remaining unprivileged on the host. runc, containerd, podman,
#  systemd-nspawn and LXC all lean on it. Kill the kernel's ability to
#  create user namespaces and "rootless containers" quietly stop working.
#
#  This script BREAKS that capability in a controlled, fully reversible
#  way on a DISPOSABLE lab VM, shows you the (deliberately confusing)
#  symptom, and asks YOU to diagnose and repair it. The worked solution
#  is at the very bottom of this file, commented out — do not peek first.
#
#  Sources (official):
#    - LPI exam 305-300 objectives:
#        https://www.lpi.org/our-certifications/exam-305-objectives/
#    - namespaces(7):        https://man7.org/linux/man-pages/man7/namespaces.7.html
#    - user_namespaces(7):   https://man7.org/linux/man-pages/man7/user_namespaces.7.html
#    - unshare(1):           https://man7.org/linux/man-pages/man1/unshare.1.html
#    - Kernel namespace limits (ENOSPC on overflow):
#        https://docs.kernel.org/admin-guide/sysctl/user.html
#    - OCI runtime-spec (user namespace mappings):
#        https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md
# =====================================================================

set -uo pipefail   # NOTE: intentionally no '-e'; we WANT to run a command
                   # that is expected to fail so you can see the symptom.

SYSCTL_KEY="user.max_user_namespaces"
SYSCTL_PATH="/proc/sys/user/max_user_namespaces"
STATE_FILE="/var/tmp/lpic305-352_1-userns.state"
DEMO_CMD=(unshare --user --map-root-user -- sh -c 'printf "root-inside? uid=%s user=%s\n" "$(id -u)" "$(id -un)"')

c_red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_cyn()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
rule()   { printf '%s\n' "----------------------------------------------------------------------"; }

# --------------------------------------------------------------------
# Guard rails: root, a real disposable-lab acknowledgement, and tooling.
# --------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        c_red "This lab must run as root (it writes to $SYSCTL_PATH)."
        echo  "Re-run with: sudo $0"
        exit 1
    fi
}

require_lab_ack() {
    # This break alters a system-wide kernel knob. Refuse to run anywhere
    # that has not explicitly declared itself throwaway.
    if [ "${LPIC_LAB_DISPOSABLE:-}" = "yes" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        c_red "Refusing to run non-interactively without acknowledgement."
        echo  "Set LPIC_LAB_DISPOSABLE=yes ONLY on a disposable lab VM, then re-run."
        exit 1
    fi
    c_ylw "This script disables user-namespace creation on THIS host."
    c_ylw "Run it ONLY on a throwaway lab VM you can reboot or destroy."
    read -r -p "Type 'yes' to confirm this is a disposable lab VM: " ack
    [ "$ack" = "yes" ] || { echo "Aborted."; exit 1; }
}

require_tools() {
    if ! command -v unshare >/dev/null 2>&1; then
        c_red "'unshare' (util-linux) is required for the demo and is missing."
        exit 1
    fi
    if [ ! -w "$SYSCTL_PATH" ]; then
        c_red "$SYSCTL_PATH is not writable on this kernel."
        echo  "This kernel may be built without CONFIG_USER_NS. Pick another lab VM."
        exit 1
    fi
}

# --------------------------------------------------------------------
# Save the pre-break value so grading/rollback is unambiguous.
# --------------------------------------------------------------------
save_state() {
    local orig
    orig="$(cat "$SYSCTL_PATH")"
    if [ ! -f "$STATE_FILE" ]; then
        printf 'ORIGINAL_%s=%s\n' "$SYSCTL_KEY" "$orig" > "$STATE_FILE"
    fi
    c_cyn "Saved original value ($SYSCTL_KEY=$orig) to $STATE_FILE"
}

# --------------------------------------------------------------------
# Baseline: prove that rootless isolation WORKS before we break it.
# An unprivileged user namespace maps the caller to uid 0 inside — the
# exact trick every rootless container runtime relies on.
# --------------------------------------------------------------------
baseline_demo() {
    rule
    c_cyn "BASELINE — creating a user namespace and mapping to root inside:"
    echo  "  \$ ${DEMO_CMD[*]}"
    if "${DEMO_CMD[@]}"; then
        c_grn "  OK: the kernel let us build an isolated user namespace."
    else
        c_ylw "  Baseline already fails — this VM may have user namespaces"
        c_ylw "  disabled already. The lab still works; just note it started broken."
    fi
    rule
}

# --------------------------------------------------------------------
# THE BREAK — cap the number of user namespaces at zero.
# This is a live, runtime-only sysctl change (no persistence file is
# written), so a reboot is a guaranteed escape hatch. Your job is to
# fix it WITHOUT rebooting and to understand why it broke.
# --------------------------------------------------------------------
apply_break() {
    echo 0 > "$SYSCTL_PATH"
    c_red  "BREAK APPLIED: $SYSCTL_KEY is now $(cat "$SYSCTL_PATH")."
}

# --------------------------------------------------------------------
# Show the student the exact, deliberately misleading symptom.
# --------------------------------------------------------------------
print_briefing() {
    rule
    c_cyn "REPRODUCING THE FAILURE THE STUDENT WILL SEE:"
    echo  "  \$ unshare --user --map-root-user id"
    local out
    out="$(unshare --user --map-root-user id 2>&1)"; local rc=$?
    printf '  %s\n' "$out"
    echo  "  (exit status: $rc)"
    rule
    c_ylw "SYMPTOM"
    cat <<'EOF'
  Creating any new user namespace now fails with:

      unshare: unshare failed: No space left on device

  This is a TRAP. It is NOT a disk problem — `df -h` shows plenty of free
  space and `free -m` shows plenty of RAM. The kernel returns ENOSPC
  ("No space left on device") when a per-namespace COUNT limit is
  exceeded, and here the limit for user namespaces has been set to 0, so
  the very first one already "overflows".

  Downstream effects on a container host:
    * `podman run` / rootless `docker run` fail to start containers.
    * `systemd-nspawn -U` refuses to boot a container.
    * Any `unshare -U` / `newuidmap`-based tooling errors out.
    * Privileged (root) containers that DON'T request a user namespace
      may still start — which makes the failure look random.
EOF
    rule
    c_grn "YOUR GOAL"
    cat <<EOF
  Restore the host's ability to create user namespaces so that

      unshare --user --map-root-user id

  again prints 'uid=0(root) ...', WITHOUT rebooting the VM. Then make the
  fix survive a reboot the right way (a drop-in under /etc/sysctl.d/).

  Success check:
      unshare --user --map-root-user -- id -u    # must print: 0

  Original value is recorded in: $STATE_FILE
EOF
    rule
    c_cyn "INVESTIGATION HINTS (run these before you touch anything):"
    cat <<'EOF'
    sysctl user.max_user_namespaces          # what is the limit now?
    cat /proc/sys/user/max_user_namespaces
    df -h ; free -m                           # prove it is NOT disk/RAM
    lsns --type=user                          # existing user namespaces
    strace -f -e trace=unshare unshare -U true 2>&1 | grep unshare
    dmesg | tail -n 20                        # (usually silent here — note that)
    man 7 user_namespaces                     # section on the count limits
EOF
    rule
    c_ylw "When you think it is fixed, scroll to the bottom of THIS script"
    c_ylw "for the fully commented, step-by-step solution."
}

main() {
    require_root
    require_lab_ack
    require_tools
    save_state
    baseline_demo
    apply_break
    print_briefing
}

main "$@"

# =====================================================================
#  SOLUTION — STEP BY STEP  (do not read until you have tried)
# =====================================================================
#
#  STEP 0 — Read the symptom literally, then distrust it.
#  -----------------------------------------------------
#  The message is "No space left on device" (ENOSPC). Reflex says "disk
#  full". Disprove that first, because in container work ENOSPC is
#  frequently a NAMESPACE-COUNT limit, not storage:
#
#      df -h            # root fs has free space  -> not the disk
#      df -i            # inodes are fine too     -> not inode exhaustion
#      free -m          # RAM is fine             -> not memory
#
#  Kernel doc confirming the overloaded meaning of ENOSPC:
#      https://docs.kernel.org/admin-guide/sysctl/user.html
#      "If a namespace ... would exceed the ... limit, the ... call fails
#       with the error ENOSPC."
#
#
#  STEP 1 — Confirm which primitive is broken: it's the USER namespace.
#  -------------------------------------------------------------------
#      unshare --user  true    ; echo "userns rc=$?"   # fails (ENOSPC)
#      unshare --uts   true    ; echo "uts   rc=$?"    # still works
#      unshare --pid --fork true ; echo "pid rc=$?"    # still works
#
#  Only CLONE_NEWUSER is affected -> look at the user-namespace knobs.
#
#
#  STEP 2 — Inspect the per-namespace limits.
#  -----------------------------------------
#      sysctl user.max_user_namespaces
#      # user.max_user_namespaces = 0     <-- the smoking gun
#
#      # For comparison, the sibling limits (normally large):
#      sysctl -a 2>/dev/null | grep '^user\.max_.*_namespaces'
#
#  A value of 0 means "zero user namespaces allowed", so creation #1
#  already overflows -> ENOSPC. (Note: on Debian/Ubuntu a DIFFERENT knob,
#  kernel.unprivileged_userns_clone=0, produces EPERM "Operation not
#  permitted" instead — recognise both. This lab used the upstream
#  mainline knob, user.max_user_namespaces.)
#
#
#  STEP 3 — Repair it live (no reboot).
#  -----------------------------------
#  Restore a sane limit. Use the value saved by the lab, or the common
#  default of 15000 (some distros use higher; any large value is fine):
#
#      # If the state file exists, reuse the exact original:
#      #   . /var/tmp/lpic305-352_1-userns.state
#      #   sysctl -w user.max_user_namespaces="${ORIGINAL_user_max_user_namespaces}"
#
#      sysctl -w user.max_user_namespaces=15000
#      # equivalently: echo 15000 > /proc/sys/user/max_user_namespaces
#
#
#  STEP 4 — Verify the fix (this is the grading check).
#  ---------------------------------------------------
#      unshare --user --map-root-user -- id -u        # -> 0
#      unshare --user --map-root-user -- id           # -> uid=0(root) ...
#      # If you have a runtime installed, the real proof:
#      #   podman run --rm alpine id                  # rootless container starts
#
#
#  STEP 5 — Make it persist correctly across reboots.
#  -------------------------------------------------
#  sysctl -w changes are runtime-only. Persist via a drop-in, which is
#  the LPIC-3-correct way (ordered, greppable, package-friendly):
#
#      cat > /etc/sysctl.d/99-userns.conf <<'CONF'
#      # Allow user namespaces (required by rootless containers: podman,
#      # rootless docker, systemd-nspawn -U, buildah, etc.)
#      user.max_user_namespaces = 15000
#      CONF
#
#      sysctl --system            # reload all drop-ins and confirm
#      sysctl user.max_user_namespaces
#
#  Also check nobody is re-disabling it on boot (precedence matters —
#  the LAST matching file wins):
#
#      grep -R 'max_user_namespaces\|unprivileged_userns_clone' \
#           /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d 2>/dev/null
#
#
#  STEP 6 — Clean up the lab breadcrumb.
#  ------------------------------------
#      rm -f /var/tmp/lpic305-352_1-userns.state
#
#
#  KEY TAKEAWAYS FOR 352.1
#  -----------------------
#   * Containers share the host kernel: they are namespaces + cgroups +
#     capabilities/seccomp/LSM, not a hypervisor. A single kernel knob can
#     therefore disable a whole class of containers system-wide.
#   * The USER namespace is what makes "rootless" possible: it maps an
#     unprivileged host UID to uid 0 inside the namespace.
#   * ENOSPC / "No space left on device" from unshare/clone almost never
#     means disk — it means a per-namespace COUNT limit was hit
#     (user.max_user_namespaces, user.max_pid_namespaces, ...).
#   * Runtime tuning is `sysctl -w`; durable config is a drop-in under
#     /etc/sysctl.d/ applied with `sysctl --system`.
# =====================================================================