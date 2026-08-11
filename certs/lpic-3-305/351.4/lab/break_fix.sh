#!/usr/bin/env bash
#
# break-fix-351.4-libvirt.sh
# LPIC-3 305 — Exam 305-300 (version 3.0)
# Topic 351.4: Libvirt Virtual Machine Management   (exam weight: 15)
#
# PURPOSE
#   A self-contained "break & fix" lab. It builds a fully disposable libvirt
#   environment (one virtual network + one throwaway domain that boots under
#   TCG/qemu, so no nested KVM is required), proves it works, then breaks ONE
#   thing in a controlled, reversible way. Your job is to diagnose the symptom
#   and bring the VM back to the 'running' state — the way you would on call.
#
#   The full step-by-step solution is at the BOTTOM of this file, commented out.
#   Do not read it until you have tried. Reset anytime with '--cleanup'.
#
# SAFETY / SCOPE
#   * Every object this script touches is namespaced with the prefix 'bf351-'.
#     It never inspects, modifies, or deletes any pre-existing domain, network,
#     pool, or bridge. '--cleanup' removes ONLY the bf351-* objects.
#   * Runs against qemu:///system, so it needs root (or membership in the
#     libvirt group with a working system connection).
#   * The break is a pure libvirt state change (a virtual network is taken
#     down and its autostart disabled). No host files are moved or destroyed.
#   * Intended for a DISPOSABLE lab host only. Arming requires explicit consent
#     (--yes or BF351_CONFIRM=yes) so it can never run by accident.
#
# USAGE
#   sudo ./break-fix-351.4-libvirt.sh --yes        # build the lab and break it
#   sudo ./break-fix-351.4-libvirt.sh --status     # show current lab state
#   sudo ./break-fix-351.4-libvirt.sh --cleanup    # remove all bf351-* objects
#   sudo ./break-fix-351.4-libvirt.sh --help
#
# OFFICIAL SOURCES (verify, do not trust memory)
#   * LPI 305-300 objectives ....... https://www.lpi.org/our-certifications/exam-305-objectives/
#   * virsh(1) manual .............. https://libvirt.org/manpages/virsh.html
#   * Virtual network XML format ... https://libvirt.org/formatnetwork.html
#   * Domain XML format ............ https://libvirt.org/formatdomain.html
#   * Networking concepts .......... https://libvirt.org/formatnetwork.html#nat-based-network

set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Configuration (override via environment if the defaults collide on your host)
# --------------------------------------------------------------------------- #
PREFIX="bf351"
DOMAIN="${BF351_DOMAIN:-${PREFIX}-vm}"
NET="${BF351_NET:-${PREFIX}-net}"
BRIDGE="${BF351_BRIDGE:-${PREFIX}br0}"          # must be <= 15 chars for the kernel
SUBNET="${BF351_SUBNET:-192.168.155}"           # change if this /24 is already in use
IMG_DIR="${BF351_IMG_DIR:-/var/lib/libvirt/images}"
DISK="${IMG_DIR}/${PREFIX}-disk.qcow2"
DISK_SIZE="${BF351_DISK_SIZE:-1G}"
VIRSH="virsh -c qemu:///system"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_grn()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_ylw()   { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_cyn()   { printf '\033[1;36m%s\033[0m\n' "$*"; }
hr()      { printf '%s\n' "-----------------------------------------------------------------------"; }

trap 'c_red "[!] Unexpected failure at line $LINENO. Fix the host prerequisite and re-run."' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { c_red "[!] Missing required command: $1"; exit 1; }
}

preflight() {
  require_cmd virsh
  require_cmd qemu-img
  if ! $VIRSH version >/dev/null 2>&1; then
    c_red "[!] Cannot talk to qemu:///system. Run as root and ensure libvirtd/virtqemud is active:"
    c_red "      systemctl status libvirtd    (or: systemctl status virtqemud)"
    exit 1
  fi
  EMULATOR="$(command -v qemu-system-x86_64 || true)"
  [[ -z "$EMULATOR" && -x /usr/libexec/qemu-kvm ]] && EMULATOR=/usr/libexec/qemu-kvm
  if [[ -z "${EMULATOR:-}" ]]; then
    c_red "[!] No x86_64 QEMU emulator found (qemu-system-x86_64 / qemu-kvm)."
    c_red "    Install the QEMU package for your distro and re-run."
    exit 1
  fi
}

net_exists()    { $VIRSH net-info    "$NET"    >/dev/null 2>&1; }
domain_exists() { $VIRSH dominfo     "$DOMAIN" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Build the disposable lab
# --------------------------------------------------------------------------- #
setup() {
  c_cyn "[*] Building the disposable lab (prefix '${PREFIX}-') ..."
  mkdir -p "$IMG_DIR"

  # 1) Backing disk (blank; the VM only needs to reach the 'running' state).
  if [[ -f "$DISK" ]]; then
    c_ylw "    disk already present, keeping it: $DISK"
  else
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
    c_grn "    created disk: $DISK ($DISK_SIZE)"
  fi

  # 2) Virtual network (NAT). This is the dependency we will later break.
  if net_exists; then
    c_ylw "    network '$NET' already defined, keeping it"
  else
    $VIRSH net-define /dev/stdin >/dev/null <<EOF
<network>
  <name>${NET}</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${SUBNET}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${SUBNET}.2' end='${SUBNET}.254'/>
    </dhcp>
  </ip>
</network>
EOF
    c_grn "    defined network: $NET (bridge $BRIDGE, ${SUBNET}.0/24)"
  fi
  $VIRSH net-start     "$NET" >/dev/null 2>&1 || true
  $VIRSH net-autostart "$NET" >/dev/null 2>&1 || true

  # 3) Domain. type='qemu' forces TCG so it starts without hardware/nested KVM.
  if domain_exists; then
    c_ylw "    domain '$DOMAIN' already defined, keeping it"
  else
    $VIRSH define /dev/stdin >/dev/null <<EOF
<domain type='qemu'>
  <name>${DOMAIN}</name>
  <memory unit='MiB'>256</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>destroy</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>${EMULATOR}</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISK}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='${NET}'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
    <graphics type='vnc' port='-1' listen='127.0.0.1'/>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
    c_grn "    defined domain: $DOMAIN (depends on network '$NET')"
  fi

  # 4) Prove the baseline works: start, confirm 'running', then power it off.
  c_cyn "[*] Verifying baseline (start -> running -> shutoff) ..."
  if $VIRSH start "$DOMAIN" >/dev/null 2>&1; then
    sleep 1
    c_grn "    baseline domstate: $($VIRSH domstate "$DOMAIN" 2>/dev/null)"
    $VIRSH destroy "$DOMAIN" >/dev/null 2>&1 || true
  else
    c_ylw "    baseline start did not complete cleanly on this host — the break"
    c_ylw "    scenario below is still valid; continuing."
    $VIRSH destroy "$DOMAIN" >/dev/null 2>&1 || true
  fi
}

# --------------------------------------------------------------------------- #
# The controlled break
# --------------------------------------------------------------------------- #
break_it() {
  c_cyn "[*] Introducing the fault ..."
  # Take the virtual network out of service AND disable its autostart, so the
  # fault also survives a libvirtd restart until the student makes it durable.
  $VIRSH net-autostart --disable "$NET" >/dev/null 2>&1 || true
  $VIRSH net-destroy "$NET"             >/dev/null 2>&1 || true
  c_grn "    done."
}

briefing() {
  hr
  c_red   "  BROKEN LAB READY — Topic 351.4 Libvirt Virtual Machine Management"
  hr
  echo
  c_ylw   "  SYMPTOM you will observe"
  echo    "    The domain '$DOMAIN' refuses to start. Try it now and read the error:"
  echo
  echo    "      \$ ${VIRSH} start ${DOMAIN}"
  echo
  echo    "    Live output on this host:"
  # Show the real, current error message (never persists a stub; just displays).
  { $VIRSH start "$DOMAIN"; } 2>&1 | sed 's/^/      /' || true
  echo
  echo    "    Expected shape of the error:"
  echo    "      error: Failed to start domain '${DOMAIN}'"
  echo    "      error: Network '${NET}' is not active"
  echo
  c_ylw   "  WHAT YOU MUST ACHIEVE (the goal)"
  echo    "    1. '${DOMAIN}' reaches state 'running':"
  echo    "         ${VIRSH} domstate ${DOMAIN}      ->  running"
  echo    "    2. The fix is DURABLE across a libvirtd/host restart — i.e. the"
  echo    "       network it depends on comes up on its own next boot:"
  echo    "         ${VIRSH} net-list --all          ->  ${NET}  active  yes"
  echo
  c_ylw   "  USEFUL STARTING POINTS"
  echo    "    ${VIRSH} list --all"
  echo    "    ${VIRSH} net-list --all"
  echo    "    ${VIRSH} dumpxml ${DOMAIN} | grep -A4 '<interface'"
  echo    "    ${VIRSH} net-info ${NET}"
  echo
  c_cyn   "  Reset the lab any time with:   sudo $0 --cleanup"
  c_cyn   "  Re-arm it with:               sudo $0 --yes"
  hr
}

status() {
  hr; c_cyn "  Current lab state"; hr
  echo "  Domains:";  $VIRSH list --all    2>/dev/null | sed 's/^/    /' || true
  echo "  Networks:"; $VIRSH net-list --all 2>/dev/null | sed 's/^/    /' || true
  if domain_exists; then
    echo "  ${DOMAIN} domstate: $($VIRSH domstate "$DOMAIN" 2>/dev/null || echo '(none)')"
  fi
}

# --------------------------------------------------------------------------- #
# Teardown
# --------------------------------------------------------------------------- #
cleanup() {
  c_cyn "[*] Removing all ${PREFIX}-* lab objects ..."
  $VIRSH destroy       "$DOMAIN" >/dev/null 2>&1 || true
  $VIRSH undefine      "$DOMAIN" >/dev/null 2>&1 || true
  $VIRSH net-destroy   "$NET"    >/dev/null 2>&1 || true
  $VIRSH net-undefine  "$NET"    >/dev/null 2>&1 || true
  [[ -f "$DISK" ]] && rm -f "$DISK" && c_grn "    removed disk: $DISK"
  c_grn "[*] Clean. No non-lab objects were touched."
}

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
main() {
  local action="arm"
  local confirm="${BF351_CONFIRM:-no}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)      confirm="yes" ;;
      --cleanup)     action="cleanup" ;;
      --status)      action="status" ;;
      --help|-h)     usage; exit 0 ;;
      *) c_red "[!] Unknown argument: $1"; usage; exit 2 ;;
    esac
    shift
  done

  preflight

  case "$action" in
    cleanup) cleanup ;;
    status)  status ;;
    arm)
      if [[ "$confirm" != "yes" ]]; then
        c_red "[!] This will build and BREAK a libvirt lab on this host."
        c_red "    Only run it on a disposable lab machine."
        c_red "    Confirm with:  sudo $0 --yes   (or set BF351_CONFIRM=yes)"
        exit 1
      fi
      setup
      break_it
      briefing
      ;;
  esac
}

main "$@"

# =========================================================================== #
#                     S O L U T I O N   (do not peek early)                    #
# =========================================================================== #
#
# Root cause
#   The domain '$DOMAIN' has an <interface type='network'> whose <source
#   network='...'> points at the virtual network '$NET'. libvirt will not
#   start a domain whose referenced network is INACTIVE, so 'virsh start'
#   aborts with "Network '<name>' is not active". The break also disabled the
#   network's autostart flag, so even a host reboot would NOT bring it back —
#   that is the production trap you must close.
#
# Diagnose
#   1) Read the exact failure:
#        virsh -c qemu:///system start bf351-vm
#        # error: Failed to start domain 'bf351-vm'
#        # error: Network 'bf351-net' is not active
#
#   2) Confirm the network is the culprit — inactive AND autostart=no:
#        virsh -c qemu:///system net-list --all
#        #  Name        State      Autostart   Persistent
#        # ---------------------------------------------------
#        #  bf351-net   inactive   no          yes
#
#   3) Prove the domain depends on exactly that network:
#        virsh -c qemu:///system dumpxml bf351-vm | grep -A4 '<interface'
#        #   <interface type='network'>
#        #     <source network='bf351-net'/>
#        #     <model type='virtio'/>
#        #   ...
#
# Fix
#   4) Bring the network up:
#        virsh -c qemu:///system net-start bf351-net
#        # Network bf351-net started
#
#   5) Make the fix DURABLE (this is what satisfies goal #2):
#        virsh -c qemu:///system net-autostart bf351-net
#        # Network bf351-net marked as autostarted
#
#   6) Start the VM:
#        virsh -c qemu:///system start bf351-vm
#        # Domain 'bf351-vm' started
#
# Verify
#   7) Both goals met:
#        virsh -c qemu:///system domstate bf351-vm
#        # running
#        virsh -c qemu:///system net-list --all
#        #  bf351-net   active   yes   yes
#
# Notes / going deeper (production mindset)
#   * "Not active" vs "not found": if you also ran 'net-undefine', the error
#     becomes "Network not found: no network with matching name 'bf351-net'".
#     The cure is then 'net-define <xml>' + 'net-start' + 'net-autostart', or
#     'virsh edit bf351-vm' to repoint the interface at an existing network.
#   * The virtual bridge 'bf351br0' only exists while the network is active;
#     'ip link show bf351br0' and 'ip addr show bf351br0' will show it appear
#     after step 4 — a fast host-side confirmation the NAT network is live.
#   * Autostart is stored as a symlink under
#     /etc/libvirt/qemu/networks/autostart/ ; step 5 creates it, which is why
#     the fix now survives a reboot.
#   * Refs: virsh(1) net-* subcommands — https://libvirt.org/manpages/virsh.html
#           network XML — https://libvirt.org/formatnetwork.html
#           domain interface XML — https://libvirt.org/formatdomain.html#network-interfaces
# =========================================================================== #