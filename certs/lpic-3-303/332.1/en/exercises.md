# LPIC-3 303 (303-300 v3.0.0) — Topic 332.1: Host Hardening
## Guided Exercises

> **Exam weight:** 8.33 — one of the heaviest single objectives in the Security specialty.
> **Objective source:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

---

### Lab prerequisites and safety notice

Every exercise below changes boot configuration, kernel runtime state, service sandboxing, or authorization policy. Several of them **can lock you out of the machine**.

| Requirement | Why |
|---|---|
| A disposable VM (Debian 12/13 or RHEL 9/Rocky 9), **not** a workstation | GRUB passwords, USBGuard and `nproc` limits are all lockout vectors |
| A snapshot taken *before* Exercise 3 | Boot-loader mistakes are only recoverable from rescue media |
| Console access (virt-manager, `virsh console`, IPMI, serial) — not only SSH | You will deliberately break interactive login paths |
| `sudo`/root, and a second root session left open | Standard practice when editing PAM, polkit or limits |
| ~4 GB RAM, 2 vCPU, a `gcc` toolchain, and one spare USB device if you have passthrough | Exercise 5 compiles binaries; Exercise 8 needs a hot-plug event |

Install the tool set once:

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install -y build-essential binutils checksec policykit-1 usbguard \
                    libcap2-bin lsof procps util-linux devscripts

# RHEL / Rocky / AlmaLinux 9
sudo dnf install -y gcc binutils checksec polkit usbguard libcap procps-ng \
                    lsof util-linux
```

Distribution differences are called out in-line; the exam is distribution-neutral, so you are expected to recognise both families.

---

## Exercise 1 — Establish a baseline: measure the attack surface before touching it

Hardening without a baseline is guesswork. You cannot prove a service was removed if you never proved it was running.

### Steps

1. Create a working directory for the evidence you will collect throughout this lab:

   ```bash
   sudo install -d -m 0700 /root/hardening-lab
   cd /root/hardening-lab
   ```

2. Capture every unit file that is *enabled* (will start at next boot), not merely running now:

   ```bash
   systemctl list-unit-files --state=enabled --no-pager > 01-enabled-units.txt
   wc -l 01-enabled-units.txt
   ```

   Illustrative output:

   ```
   UNIT FILE                              STATE   PRESET
   auditd.service                         enabled enabled
   chronyd.service                        enabled enabled
   cups.path                              enabled enabled
   cups.service                           enabled enabled
   cups.socket                            enabled enabled
   sshd.service                           enabled enabled
   ...
   ```

3. Capture what is actually running right now:

   ```bash
   systemctl list-units --type=service --state=running --no-pager > 02-running-services.txt
   ```

4. Capture every listening socket together with the owning process:

   ```bash
   sudo ss -tulpnH | sort -k1,1 -k5,5 > 03-listeners.txt
   cat 03-listeners.txt
   ```

   Illustrative output:

   ```
   tcp   LISTEN 0 128    0.0.0.0:22    0.0.0.0:*  users:(("sshd",pid=812,fd=3))
   tcp   LISTEN 0 4096   127.0.0.1:631 0.0.0.0:*  users:(("cupsd",pid=744,fd=7))
   udp   UNCONN 0 0      0.0.0.0:5353  0.0.0.0:*  users:(("avahi-daemon",pid=701,fd=12))
   ```

5. Map each listener back to the package that owns the binary — this is the step that turns "disable" into "remove":

   ```bash
   # Debian
   for p in $(sudo ss -tulpnH | grep -oP '(?<=users:\(\(")[^"]+' | sort -u); do
       printf '%-16s %s\n' "$p" "$(dpkg -S "$(command -v "$p" 2>/dev/null)" 2>/dev/null || echo '?')"
   done

   # RHEL
   for p in $(sudo ss -tulpnH | grep -oP '(?<=users:\(\(")[^"]+' | sort -u); do
       printf '%-16s %s\n' "$p" "$(rpm -qf "$(command -v "$p" 2>/dev/null)" 2>/dev/null || echo '?')"
   done
   ```

6. Record the boot-time cost of each unit — a rough proxy for "how much is this box doing that nobody asked for":

   ```bash
   systemd-analyze blame --no-pager | head -20 > 04-blame.txt
   systemd-analyze critical-chain --no-pager > 05-critical-chain.txt
   ```

7. Take the security baseline that Exercise 6 will be measured against:

   ```bash
   systemd-analyze security --no-pager > 06-security-baseline.txt
   head -12 06-security-baseline.txt
   ```

   Illustrative output:

   ```
   UNIT                          EXPOSURE PREDICATE HAPPY
   dbus.service                       9.5 UNSAFE    😨
   NetworkManager.service             7.6 EXPOSED   🙁
   sshd.service                       9.6 UNSAFE    😨
   systemd-udevd.service              6.6 MEDIUM    😐
   systemd-logind.service             2.8 OK        🙂
   ```

**Check your understanding**

- **Q1.1** — `systemctl list-units --state=running` shows no `cups.service`, yet `systemctl list-unit-files --state=enabled` shows `cups.socket` as enabled. Is the CUPS attack surface present or absent? Justify.
- **Q1.2** — Why is `ss -tulpn` a weaker attack-surface measurement than the enabled-unit list, and why is the enabled-unit list weaker than the installed-package list?
- **Q1.3** — In the `systemd-analyze security` output, is a *higher* exposure number better or worse, and what is the numeric range?
- **Q1.4** — Name two categories of locally reachable attack surface that `ss -tulpn` will never show you.

---

## Exercise 2 — Disable, mask, and remove unused software and services

### Steps

1. Pick a genuinely unnecessary service for a server. On a fresh desktop-flavoured install, `cups` and `avahi-daemon` are the classic pair. Inspect what CUPS actually consists of:

   ```bash
   systemctl list-unit-files --no-pager | grep -E '^cups'
   ```

   ```
   cups.path       enabled  enabled
   cups.service    enabled  enabled
   cups.socket     enabled  enabled
   cups-browsed.service enabled enabled
   ```

2. Stop and disable **all** of the activation units, not just the service:

   ```bash
   sudo systemctl disable --now cups.service cups.socket cups.path cups-browsed.service
   ```

   ```
   Removed "/etc/systemd/system/multi-user.target.wants/cups.service".
   Removed "/etc/systemd/system/sockets.target.wants/cups.socket".
   Removed "/etc/systemd/system/multi-user.target.wants/cups.path".
   ```

3. Prove that `disable` is not a lock. Any dependency — or any user with the right polkit rights — can still start it:

   ```bash
   sudo systemctl start cups.service
   systemctl is-active cups.service
   ```

   ```
   active
   ```

4. Now apply the real lock, `mask`, and observe the difference:

   ```bash
   sudo systemctl mask --now cups.service cups.socket cups.path
   ls -l /etc/systemd/system/cups.service
   sudo systemctl start cups.service
   ```

   ```
   lrwxrwxrwx 1 root root 9 Aug 24 10:12 /etc/systemd/system/cups.service -> /dev/null
   Failed to start cups.service: Unit cups.service is masked.
   ```

5. Check whether anything depended on the unit you just removed from service:

   ```bash
   systemctl list-dependencies --reverse cups.socket --no-pager
   sudo systemctl --failed --no-pager
   ```

6. Escalate from "masked" to "not installed" — the only state with no residual code, no SUID binaries and no CVE exposure:

   ```bash
   # Debian: purge also removes configuration
   sudo apt-get purge --autoremove -y cups cups-daemon cups-browsed avahi-daemon

   # RHEL
   sudo dnf remove -y cups cups-filters avahi
   ```

7. Verify the removal three independent ways:

   ```bash
   systemctl list-unit-files --no-pager | grep -c cups || echo "no cups units"
   command -v cupsd || echo "no cupsd binary"
   sudo ss -tulpnH | grep -E ':631|:5353' || echo "no listeners"
   ```

8. Re-run the baseline diff to quantify what you achieved:

   ```bash
   systemctl list-unit-files --state=enabled --no-pager > /root/hardening-lab/01-enabled-units-after.txt
   diff /root/hardening-lab/01-enabled-units.txt /root/hardening-lab/01-enabled-units-after.txt
   ```

9. A masked unit is *inert*, not *gone*. Confirm the vendor unit file still exists on disk and could be restored in one command:

   ```bash
   systemctl cat cups.service 2>&1 | head -3
   # After purge this fails; before purge it shows the /usr/lib unit behind the mask.
   ```

**Check your understanding**

- **Q2.1** — State the mechanical difference between `systemctl disable` and `systemctl mask` in terms of what each one writes to the filesystem.
- **Q2.2** — You masked `cups.service` but left `cups.socket` enabled. What happens when a process connects to the CUPS socket?
- **Q2.3** — Which of these three is reversible by a non-root user with a polkit `manage-units` grant: disabled, masked, purged?
- **Q2.4** — Why does `systemctl mask` refuse to operate on a *static* unit, and what should you use instead for a unit with no `[Install]` section?

---

## Exercise 3 — Boot loader (GRUB 2) and firmware hardening

> **Snapshot the VM now.** A malformed `grub.cfg` produces an unbootable machine.

### Part A — Demonstrate the vulnerability you are about to close

1. Reboot and hold `Shift` (BIOS) or press `Esc` (UEFI) to reach the GRUB menu.
2. Highlight the default entry and press `e` to edit it.
3. Find the line beginning with `linux /boot/vmlinuz…` and append to its end:

   ```
   init=/bin/bash
   ```

4. Press `Ctrl-X` (or `F10`) to boot. You land in a root shell with no password prompt:

   ```
   bash-5.2# id
   uid=0(root) gid=0(root) groups=0(root)
   bash-5.2# mount -o remount,rw /
   bash-5.2# passwd root
   New password:
   ```

5. Reboot back to normal (`exec /sbin/init`, or force-reset the VM).

### Part B — Set a GRUB 2 superuser password

6. Generate a PBKDF2 hash. Note the binary name differs by family:

   ```bash
   # Debian / Ubuntu
   grub-mkpasswd-pbkdf2
   # RHEL / Rocky (equivalent)
   grub2-mkpasswd-pbkdf2
   ```

   ```
   Enter password:
   Reenter password:
   PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.7A1C…F3.9B44…2E
   ```

7. On **Debian/Ubuntu**, append to `/etc/grub.d/40_custom` (below the `exec tail` line, never above it):

   ```bash
   sudo tee -a /etc/grub.d/40_custom >/dev/null <<'EOF'
   set superusers="grubadm"
   password_pbkdf2 grubadm grub.pbkdf2.sha512.10000.7A1C…F3.9B44…2E
   EOF
   ```

8. Keep unattended reboots working by marking the generated menu entries as `--unrestricted`. Edit `/etc/grub.d/10_linux` and add the flag to the `CLASS` variable:

   ```bash
   sudo sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' /etc/grub.d/10_linux
   grep '^CLASS=' /etc/grub.d/10_linux
   ```

   ```
   CLASS="--class gnu-linux --class gnu --class os --unrestricted"
   ```

9. Regenerate the configuration and verify before rebooting:

   ```bash
   sudo update-grub                       # Debian wrapper
   # sudo grub2-mkconfig -o /boot/grub2/grub.cfg    # RHEL

   sudo grep -E 'superusers|password_pbkdf2|--unrestricted' /boot/grub/grub.cfg | head
   ```

   On **RHEL 9** the supported path is a single command that writes `/boot/grub2/user.cfg`:

   ```bash
   sudo grub2-setpassword
   sudo cat /boot/grub2/user.cfg
   ```

   ```
   GRUB2_PASSWORD=grub.pbkdf2.sha512.10000.4E9B…A1.77CD…04
   ```

10. Tighten the file permissions — the hash is offline-crackable, and by default `grub.cfg` is world-readable:

    ```bash
    sudo chmod 0600 /boot/grub/grub.cfg   # /boot/grub2/grub.cfg and user.cfg on RHEL
    sudo ls -l /boot/grub/grub.cfg
    ```

11. Reboot. Confirm that the default entry still boots unattended, but pressing `e` or `c` now demands credentials:

    ```
    Enter username: grubadm
    Enter password:
    ```

12. Repeat the Part A bypass. It must now fail before the editor opens.

### Part C — Harden the kernel command line and the firmware

13. Add defence-in-depth kernel parameters. Measure the cost before adopting these in production — `init_on_free` and `nosmt` carry real performance penalties:

    ```bash
    sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=1 vsyscall=none debugfs=off"/' /etc/default/grub
    grep GRUB_CMDLINE /etc/default/grub
    sudo update-grub
    ```

    On RHEL the equivalent, applied to every installed kernel:

    ```bash
    sudo grubby --update-kernel=ALL --args="slab_nomerge init_on_alloc=1 vsyscall=none debugfs=off"
    sudo grubby --info=ALL | grep args
    ```

14. After reboot, confirm what the kernel actually received (never trust the config file, trust the kernel):

    ```bash
    cat /proc/cmdline
    ```

    ```
    BOOT_IMAGE=/boot/vmlinuz-6.1.0-25-amd64 root=UUID=…\
     ro quiet slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=1 vsyscall=none debugfs=off
    ```

15. Record the firmware-level controls that GRUB cannot provide, and set them in your hypervisor/BIOS: supervisor password, boot order pinned to the internal disk, external/USB/PXE boot disabled, Secure Boot enabled. Verify Secure Boot state from Linux:

    ```bash
    mokutil --sb-state 2>/dev/null || bootctl status 2>/dev/null | grep -i 'secure boot'
    ```

    ```
    SecureBoot enabled
    ```

**Check your understanding**

- **Q3.1** — With `set superusers` defined but `--unrestricted` **not** applied to menu entries, what happens on an unattended reboot after a power cut?
- **Q3.2** — An attacker has physical access and the machine has a GRUB superuser password, a BIOS password, and boot order locked to the internal disk. Name the attack that still succeeds, and the control from a *different* 303 objective that stops it.
- **Q3.3** — Why is `password_pbkdf2` preferred over the `password` directive, and what does the `10000` in the hash string mean?
- **Q3.4** — You set a GRUB password on RHEL with `grub2-setpassword`. Which username must be typed at the prompt, and where is the hash stored?
- **Q3.5** — After a kernel package upgrade on Debian, `update-grub` runs automatically. Will your `40_custom` password survive? Will a hand-edit of `/boot/grub/grub.cfg` survive?

---

## Exercise 4 — Kernel runtime parameters (`sysctl`)

### Steps

1. Inspect the current values of the security-relevant tunables:

   ```bash
   sudo sysctl kernel.randomize_va_space kernel.kptr_restrict kernel.dmesg_restrict \
                kernel.yama.ptrace_scope kernel.sysrq kernel.perf_event_paranoid \
                fs.protected_symlinks fs.protected_hardlinks fs.suid_dumpable
   ```

   ```
   kernel.randomize_va_space = 2
   kernel.kptr_restrict = 0
   kernel.dmesg_restrict = 0
   kernel.yama.ptrace_scope = 1
   kernel.sysrq = 16
   kernel.perf_event_paranoid = 2
   fs.protected_symlinks = 1
   fs.protected_hardlinks = 1
   fs.suid_dumpable = 0
   ```

2. Demonstrate what `kptr_restrict = 0` leaks to an unprivileged user:

   ```bash
   sudo sysctl -w kernel.kptr_restrict=0
   head -3 /proc/kallsyms                 # run as a NON-root user
   ```

   ```
   ffffffffb3e00000 T startup_64
   ffffffffb3e00060 T secondary_startup_64
   ffffffffb3e001d0 T __pfx_verify_cpu
   ```

   Those are live kernel text addresses — KASLR defeated for anyone who can read that file.

3. Restrict it and re-read as the same unprivileged user:

   ```bash
   sudo sysctl -w kernel.kptr_restrict=2
   head -3 /proc/kallsyms
   ```

   ```
   0000000000000000 T startup_64
   0000000000000000 T secondary_startup_64
   0000000000000000 T __pfx_verify_cpu
   ```

4. Demonstrate `ptrace_scope`. As a normal user, start a background `sleep` and try to attach from a *sibling* shell (not the parent):

   ```bash
   sudo sysctl -w kernel.yama.ptrace_scope=0
   sleep 600 &                            # note the PID
   # from a second terminal, same user:
   gdb -p <PID> -batch -ex 'info proc' 2>&1 | tail -3
   ```

   Then set scope 1 and repeat:

   ```bash
   sudo sysctl -w kernel.yama.ptrace_scope=1
   gdb -p <PID> -batch -ex 'info proc' 2>&1 | tail -3
   ```

   ```
   ptrace: Operation not permitted.
   ```

5. Write a persistent policy file. Use a numeric prefix so ordering is explicit:

   ```bash
   sudo tee /etc/sysctl.d/60-hardening.conf >/dev/null <<'EOF'
   # Kernel information leaks
   kernel.kptr_restrict = 2
   kernel.dmesg_restrict = 1
   kernel.perf_event_paranoid = 2

   # Process introspection
   kernel.yama.ptrace_scope = 1

   # Memory layout
   kernel.randomize_va_space = 2
   vm.mmap_min_addr = 65536

   # Filesystem race hardening
   fs.protected_symlinks = 1
   fs.protected_hardlinks = 1
   fs.protected_fifos = 2
   fs.protected_regular = 2
   fs.suid_dumpable = 0

   # Magic SysRq: allow only the sync/remount-ro subset
   kernel.sysrq = 4

   # eBPF
   kernel.unprivileged_bpf_disabled = 1
   net.core.bpf_jit_harden = 2
   EOF
   ```

6. Apply and read the ordering that your distribution actually uses — **derive it, do not assume it**:

   ```bash
   sudo sysctl --system 2>&1 | grep '^\* Applying'
   ```

   ```
   * Applying /usr/lib/sysctl.d/50-default.conf ...
   * Applying /usr/lib/sysctl.d/50-pid-max.conf ...
   * Applying /etc/sysctl.d/60-hardening.conf ...
   * Applying /etc/sysctl.d/99-sysctl.conf ...
   * Applying /etc/sysctl.conf ...
   ```

7. Prove the precedence rule with an experiment. Create a conflicting file that sorts *later* and confirm which value wins:

   ```bash
   echo 'kernel.dmesg_restrict = 0' | sudo tee /etc/sysctl.d/90-conflict.conf
   sudo sysctl --system >/dev/null
   sysctl kernel.dmesg_restrict
   ```

   ```
   kernel.dmesg_restrict = 0
   ```

8. Now prove the *shadowing* rule — an `/etc` file masks a `/usr/lib` file **of the same name**:

   ```bash
   ls /usr/lib/sysctl.d/
   # Pick one, e.g. 50-pid-max.conf, and shadow it:
   sudo ln -sf /dev/null /etc/sysctl.d/50-pid-max.conf
   sudo sysctl --system 2>&1 | grep pid-max
   ```

9. Clean up the deliberate conflict and confirm the intended end state:

   ```bash
   sudo rm /etc/sysctl.d/90-conflict.conf /etc/sysctl.d/50-pid-max.conf
   sudo sysctl --system >/dev/null
   sysctl kernel.dmesg_restrict kernel.kptr_restrict
   ```

10. Explore the **one-way** switches. These cannot be reverted without a reboot — read the value, but think before writing:

    ```bash
    sysctl kernel.kexec_load_disabled kernel.modules_disabled
    ```

    ```
    kernel.kexec_load_disabled = 0
    kernel.modules_disabled = 0
    ```

    Test the irreversibility on a machine you are willing to reboot:

    ```bash
    sudo sysctl -w kernel.kexec_load_disabled=1
    sudo sysctl -w kernel.kexec_load_disabled=0
    ```

    ```
    sysctl: setting key "kernel.kexec_load_disabled": Operation not permitted
    ```

11. Reboot and verify persistence — a runtime value that vanishes on reboot is not a control:

    ```bash
    sudo reboot
    # after boot
    sudo sysctl -a --pattern 'kptr_restrict|dmesg_restrict|ptrace_scope|protected_' 2>/dev/null
    ```

**Check your understanding**

- **Q4.1** — You dropped `kernel.kptr_restrict = 2` into `/etc/sysctl.d/60-hardening.conf` and rebooted, but the running value is `1`. Give two distinct explanations and the command that distinguishes them.
- **Q4.2** — What is the difference between `kernel.kptr_restrict = 1` and `= 2`?
- **Q4.3** — `kernel.modules_disabled = 1` breaks which routine administrative operations? Why is it nonetheless recommended on a fixed-function appliance?
- **Q4.4** — Explain the difference in threat model between `fs.protected_symlinks` and `fs.protected_regular`.
- **Q4.5** — `kernel.yama.ptrace_scope` has no effect on your system and `sysctl` reports the key does not exist. What is the cause?
- **Q4.6** — Which of these belong to objective **334.1 Network Hardening** rather than 332.1: `net.ipv4.tcp_syncookies`, `kernel.dmesg_restrict`, `net.ipv4.conf.all.rp_filter`, `fs.suid_dumpable`?

---

## Exercise 5 — ASLR, NX/DEP, and per-binary exploit mitigations

### Part A — Observe ASLR

1. Confirm the system-wide setting and its meaning:

   ```bash
   cat /proc/sys/kernel/randomize_va_space
   ```

   ```
   2
   ```

2. Observe randomisation directly. Each iteration is a new process, so each gets a fresh layout:

   ```bash
   for i in 1 2 3; do awk '/\[stack\]/{print "stack:", $1} /\[heap\]/{print "heap: ", $1}' /proc/self/maps; done
   ```

   ```
   stack: 7ffd3a1c9000-7ffd3a1ea000
   heap:  55a4c1f2e000-55a4c1f4f000
   stack: 7ffe8b04d000-7ffe8b06e000
   heap:  5601de7a1000-5601de7c2000
   stack: 7ffc2e9b1000-7ffc2e9d2000
   heap:  55f30ba46000-55f30ba67000
   ```

3. Disable it system-wide, observe, and restore:

   ```bash
   sudo sysctl -w kernel.randomize_va_space=0
   for i in 1 2 3; do awk '/\[stack\]/{print $1}' /proc/self/maps; done
   sudo sysctl -w kernel.randomize_va_space=2
   ```

   ```
   7ffffffde000-7ffffffff000
   7ffffffde000-7ffffffff000
   7ffffffde000-7ffffffff000
   ```

4. Now compare with the *per-process* disable, available to any unprivileged user:

   ```bash
   for i in 1 2 3; do setarch "$(uname -m)" -R awk '/\[stack\]/{print $1}' /proc/self/maps; done
   sysctl kernel.randomize_va_space
   ```

   Note that the system-wide value is still `2` — the personality flag applied only to those children.

5. Compare mode `1` (conservative) against mode `2` (full) by watching only the heap:

   ```bash
   for m in 1 2; do
     sudo sysctl -qw kernel.randomize_va_space=$m
     echo "--- mode $m ---"
     for i in 1 2 3; do awk '/\[heap\]/{print $1}' /proc/self/maps; done
   done
   sudo sysctl -qw kernel.randomize_va_space=2
   ```

### Part B — Confirm NX/DEP is active

6. Check the CPU feature and the kernel's use of it:

   ```bash
   grep -o '\bnx\b' /proc/cpuinfo | head -1
   sudo dmesg | grep -i 'NX (Execute Disable)'
   ```

   ```
   nx
   [    0.000000] NX (Execute Disable) protection: active
   ```

7. Inspect a real binary's stack permissions. `RW` is correct; `RWE` means an executable stack:

   ```bash
   readelf -lW /bin/ls | grep -E 'GNU_STACK|GNU_RELRO'
   ```

   ```
     GNU_RELRO      0x01f5f0 0x00000000000205f0 0x00000000000205f0 0x000a10 0x000a10 R   0x1
     GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x10
   ```

### Part C — Build a weak and a hardened binary and compare

8. Write the test program:

   ```bash
   cat > /tmp/probe.c <<'EOF'
   #include <stdio.h>
   #include <stdlib.h>
   #include <string.h>

   void copy(const char *src) {
       char buf[32];
       strcpy(buf, src);          /* deliberately unchecked */
       printf("buf @ %p = %s\n", (void *)buf, buf);
   }

   int main(int argc, char **argv) {
       printf("main   @ %p\n", (void *)main);
       printf("heap   @ %p\n", malloc(16));
       printf("printf @ %p\n", (void *)printf);
       if (argc > 1) copy(argv[1]);
       return 0;
   }
   EOF
   ```

9. Compile it two ways:

   ```bash
   gcc -O0 -fno-stack-protector -no-pie -z execstack -Wl,-z,norelro \
       -U_FORTIFY_SOURCE -o /tmp/weak /tmp/probe.c

   gcc -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE -pie \
       -Wl,-z,relro,-z,now -Wl,-z,noexecstack -o /tmp/strong /tmp/probe.c
   ```

10. Compare the mitigation profile:

    ```bash
    checksec --file=/tmp/weak
    checksec --file=/tmp/strong
    ```

    ```
    RELRO         STACK CANARY    NX           PIE          RPATH    RUNPATH   FORTIFY  FILE
    No RELRO      No canary found NX disabled  No PIE       No RPATH No RUNPATH No      /tmp/weak
    Full RELRO    Canary found    NX enabled   PIE enabled  No RPATH No RUNPATH Yes     /tmp/strong
    ```

11. Derive the same facts from `readelf` alone — `checksec` is not on the exam, `readelf` is:

    ```bash
    for b in /tmp/weak /tmp/strong; do
      echo "== $b"
      readelf -hW  "$b" | awk '/^  Type:/{print "  Type       :", $2}'      # DYN = PIE, EXEC = fixed
      readelf -lW  "$b" | awk '/GNU_STACK/{print "  GNU_STACK  :", $(NF-1)}'
      readelf -lW  "$b" | grep -q GNU_RELRO && echo "  RELRO      : present" || echo "  RELRO      : absent"
      readelf -dW  "$b" | grep -q BIND_NOW  && echo "  BIND_NOW   : yes" || echo "  BIND_NOW   : no"
      readelf -sW  "$b" | grep -q __stack_chk_fail && echo "  Canary     : yes" || echo "  Canary     : no"
      readelf -sW  "$b" | grep -q '_chk@'   && echo "  FORTIFY    : yes" || echo "  FORTIFY    : no"
    done
    ```

    ```
    == /tmp/weak
      Type       : EXEC
      GNU_STACK  : RWE
      RELRO      : absent
      BIND_NOW   : no
      Canary     : no
      FORTIFY    : no
    == /tmp/strong
      Type       : DYN
      GNU_STACK  : RW
      RELRO      : present
      BIND_NOW   : yes
      Canary     : yes
      FORTIFY    : yes
    ```

12. Observe the canary firing. Overflow the 32-byte buffer in each binary:

    ```bash
    /tmp/weak   "$(python3 -c 'print("A"*200)')"; echo "weak exit=$?"
    /tmp/strong "$(python3 -c 'print("A"*200)')"; echo "strong exit=$?"
    ```

    ```
    ...
    Segmentation fault (core dumped)
    weak exit=139
    *** stack smashing detected ***: terminated
    Aborted (core dumped)
    strong exit=134
    ```

13. Observe that PIE moves the *code* too, which `no-pie` does not:

    ```bash
    for i in 1 2; do /tmp/weak   | head -1; done
    for i in 1 2; do /tmp/strong | head -1; done
    ```

    ```
    main   @ 0x401136
    main   @ 0x401136
    main   @ 0x5581f3a01169
    main   @ 0x55d0e4e2a169
    ```

14. Audit the system's own binaries for the weakest links:

    ```bash
    for f in $(find /usr/bin /usr/sbin -maxdepth 1 -type f -perm -4000 2>/dev/null); do
        s=$(readelf -lW "$f" 2>/dev/null | awk '/GNU_STACK/{print $(NF-1)}')
        t=$(readelf -hW "$f" 2>/dev/null | awk '/^  Type:/{print $2}')
        printf '%-32s type=%-5s stack=%s\n' "$f" "$t" "$s"
    done
    ```

15. Clean up:

    ```bash
    rm -f /tmp/weak /tmp/strong /tmp/probe.c
    ```

**Check your understanding**

- **Q5.1** — Explain the difference between `randomize_va_space` values `0`, `1` and `2`, naming one region that only mode `2` randomises.
- **Q5.2** — `setarch -R` requires no privilege. Does that make ASLR useless as a security control? Argue both sides.
- **Q5.3** — NX/DEP is a CPU + kernel feature, yet `/tmp/weak` had an executable stack. Reconcile these two statements.
- **Q5.4** — What is the difference between *Partial RELRO* and *Full RELRO*, and which linker flag produces the second?
- **Q5.5** — Why does a stack canary produce `SIGABRT` (exit 134) rather than `SIGSEGV` (exit 139), and why does that distinction matter to a defender reading logs?
- **Q5.6** — `_FORTIFY_SOURCE=2` requires an optimisation level of at least `-O1`. Why?
- **Q5.7** — A 32-bit legacy binary on your server shows `GNU_STACK: RWE`. You cannot recompile it. What are your options, in order of preference?

---

## Exercise 6 — systemd unit sandboxing

### Steps

1. Score a real service to see where you stand:

   ```bash
   systemd-analyze security sshd.service --no-pager | head -20
   ```

   ```
   NAME                                   DESCRIPTION                          EXPOSURE
   ✗ PrivateNetwork=                      Service has access to the host…            0.5
   ✗ User=/DynamicUser=                   Service runs as root                       0.4
   ✗ CapabilityBoundingSet=~CAP_SYS_ADMIN Service has administrator privileges       0.3
   ✗ ProtectHome=                         Service has full access to home dirs       0.2
   ✗ PrivateDevices=                      Service potentially has access to…         0.2
   …
   → Overall exposure level for sshd.service: 9.6 UNSAFE 😨
   ```

2. Build a small, safe target service so you can harden aggressively without breaking anything real:

   ```bash
   sudo tee /usr/local/bin/lab-probe.sh >/dev/null <<'EOF'
   #!/bin/bash
   while true; do
     printf 'uid=%s tmp=%s root_writable=%s\n' \
            "$(id -u)" \
            "$(ls -d /tmp | xargs stat -c %i)" \
            "$(touch /etc/lab-probe-canary 2>/dev/null && echo YES || echo NO)"
     sleep 30
   done
   EOF
   sudo chmod 0755 /usr/local/bin/lab-probe.sh

   sudo tee /etc/systemd/system/lab-probe.service >/dev/null <<'EOF'
   [Unit]
   Description=Host hardening lab probe

   [Service]
   Type=simple
   ExecStart=/usr/local/bin/lab-probe.sh
   Restart=no

   [Install]
   WantedBy=multi-user.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl start lab-probe.service
   ```

3. Take the "before" measurement and the "before" behaviour:

   ```bash
   systemd-analyze security lab-probe.service --no-pager | tail -1
   journalctl -u lab-probe.service -n 2 --no-pager
   ```

   ```
   → Overall exposure level for lab-probe.service: 9.6 UNSAFE 😨
   Aug 24 11:02:11 lab lab-probe.sh[2211]: uid=0 tmp=1 root_writable=YES
   ```

4. Add a sandbox as a **drop-in**, never by editing the vendor unit:

   ```bash
   sudo systemctl edit lab-probe.service
   ```

   Enter, in the editable region:

   ```ini
   [Service]
   # Identity and privilege
   DynamicUser=yes
   NoNewPrivileges=yes
   CapabilityBoundingSet=
   AmbientCapabilities=
   RestrictSUIDSGID=yes

   # Filesystem
   ProtectSystem=strict
   ProtectHome=yes
   PrivateTmp=yes
   ReadWritePaths=/var/lib/lab-probe
   StateDirectory=lab-probe
   UMask=0077

   # Kernel and host state
   ProtectKernelTunables=yes
   ProtectKernelModules=yes
   ProtectKernelLogs=yes
   ProtectControlGroups=yes
   ProtectClock=yes
   ProtectHostname=yes
   ProtectProc=invisible
   ProcSubset=pid
   PrivateDevices=yes

   # Namespaces, memory, syscalls
   RestrictNamespaces=yes
   RestrictRealtime=yes
   LockPersonality=yes
   MemoryDenyWriteExecute=yes
   SystemCallArchitectures=native
   SystemCallFilter=@system-service
   SystemCallErrorNumber=EPERM

   # Network
   RestrictAddressFamilies=AF_UNIX
   PrivateNetwork=yes
   IPAddressDeny=any
   ```

5. Confirm where the drop-in landed and what the merged unit now looks like:

   ```bash
   ls -l /etc/systemd/system/lab-probe.service.d/
   systemctl cat lab-probe.service | head -40
   ```

   ```
   -rw-r--r-- 1 root root 812 Aug 24 11:09 override.conf
   ```

6. Restart and measure the delta:

   ```bash
   sudo systemctl restart lab-probe.service
   systemd-analyze security lab-probe.service --no-pager | tail -1
   journalctl -u lab-probe.service -n 2 --no-pager
   ```

   ```
   → Overall exposure level for lab-probe.service: 1.2 OK 🙂
   Aug 24 11:10:41 lab lab-probe.sh[2390]: uid=63478 tmp=1179648 root_writable=NO
   ```

   The UID changed (`DynamicUser`), `/tmp` is a different inode (`PrivateTmp`), and the write to `/etc` failed (`ProtectSystem=strict`).

7. Inspect the sandbox from inside the service's own namespace:

   ```bash
   PID=$(systemctl show -p MainPID --value lab-probe.service)
   sudo ls -l /proc/$PID/ns/
   sudo nsenter -t "$PID" -m -p -n --  sh -c 'ls /tmp; ip -brief addr; cat /etc/hostname'
   ```

8. Prove the syscall filter actually denies something. Add a probe that calls `mount(2)`:

   ```bash
   sudo systemd-run --unit=lab-mount-test \
        -p SystemCallFilter=@system-service -p SystemCallErrorNumber=EPERM \
        -p NoNewPrivileges=yes \
        /bin/mount -t tmpfs none /mnt
   journalctl -u lab-mount-test --no-pager -n 5
   ```

   ```
   mount: /mnt: permission denied.
   ```

9. Learn the failure mode. Deliberately over-restrict and observe how it presents:

   ```bash
   sudo systemd-run --unit=lab-jit-test -p MemoryDenyWriteExecute=yes \
        /usr/bin/python3 -c 'import ctypes; print("ok")'
   systemctl status lab-jit-test --no-pager
   ```

10. Compare exposure across the whole system before and after your changes:

    ```bash
    systemd-analyze security --no-pager > /root/hardening-lab/06-security-after.txt
    diff /root/hardening-lab/06-security-baseline.txt /root/hardening-lab/06-security-after.txt
    ```

11. Apply a conservative, low-risk sandbox to a *real* service and verify it still works end to end:

    ```bash
    sudo systemctl edit chronyd.service   # or systemd-timesyncd / ntpsec
    ```

    ```ini
    [Service]
    NoNewPrivileges=yes
    ProtectHome=yes
    ProtectKernelModules=yes
    ProtectControlGroups=yes
    RestrictRealtime=yes
    RestrictSUIDSGID=yes
    LockPersonality=yes
    ```

    ```bash
    sudo systemctl restart chronyd
    chronyc tracking | head -3
    systemd-analyze security chronyd.service --no-pager | tail -1
    ```

12. Tear down the lab units:

    ```bash
    sudo systemctl stop lab-probe.service
    sudo systemctl disable lab-probe.service
    sudo rm -rf /etc/systemd/system/lab-probe.service.d /etc/systemd/system/lab-probe.service \
                /usr/local/bin/lab-probe.sh /etc/lab-probe-canary
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    ```

**Check your understanding**

- **Q6.1** — What is the practical difference between `ProtectSystem=yes`, `=full` and `=strict`? Which one requires `ReadWritePaths=` to be usable by most daemons?
- **Q6.2** — Why must `NoNewPrivileges=yes` be set for `SystemCallFilter=` to be enforceable without privilege, and what does it break if the service uses `su`, `sudo` or a SUID helper?
- **Q6.3** — You set `PrivateTmp=yes` on a daemon that writes a socket to `/tmp` for a client to connect to. What breaks, and what is the correct fix?
- **Q6.4** — A colleague argues that `systemd-analyze security` reporting `1.2 OK` proves the service is secure. Rebut this in two sentences.
- **Q6.5** — Why is `systemctl edit` preferred over editing `/usr/lib/systemd/system/foo.service` directly? Name the specific failure the direct edit causes.
- **Q6.6** — `MemoryDenyWriteExecute=yes` is one of the strongest anti-exploitation directives available. Name three classes of legitimate software it breaks.
- **Q6.7** — What is the difference between `CapabilityBoundingSet=` (empty) and `AmbientCapabilities=` (empty)?

---

## Exercise 7 — polkit authorization

### Steps

1. Determine your polkit version — the rules format changed at 0.106, and this is a classic exam trap:

   ```bash
   pkaction --version
   ```

   ```
   pkaction version 122
   ```

   Anything ≥ 0.106 uses JavaScript rules in `/etc/polkit-1/rules.d/`. Older versions (and some SUSE/Ubuntu LTS builds with the local-authority backend) use `.pkla` INI files under `/etc/polkit-1/localauthority/`.

2. Enumerate the actions registered on the system:

   ```bash
   pkaction | wc -l
   pkaction | grep systemd1
   ```

   ```
   183
   org.freedesktop.systemd1.manage-units
   org.freedesktop.systemd1.manage-unit-files
   org.freedesktop.systemd1.reload-daemon
   org.freedesktop.systemd1.set-environment
   ```

3. Read the defaults an action ships with:

   ```bash
   pkaction --action-id org.freedesktop.systemd1.manage-units --verbose
   ```

   ```
   org.freedesktop.systemd1.manage-units:
     description:       Manage system services or other units
     message:           Authentication is required to manage system services or other units.
     vendor:            The systemd Project
     implicit any:      auth_admin
     implicit inactive: auth_admin
     implicit active:   auth_admin_keep
   ```

4. Find the XML behind it and read the `<defaults>` block:

   ```bash
   grep -A8 'manage-units' /usr/share/polkit-1/actions/org.freedesktop.systemd1.policy | head -20
   ```

5. Test an authorization decision without performing the action:

   ```bash
   pkcheck --action-id org.freedesktop.systemd1.manage-units --process $$ ; echo "exit=$?"
   ```

   ```
   Error checking for authorization org.freedesktop.systemd1.manage-units: \
   Authorization requires authentication and -u wasn't passed.
   exit=3
   ```

   Read `pkcheck(1)` on your system and record the exact meaning of each exit status — `0` is authorized, and the non-zero values distinguish "denied" from "authentication required".

6. Create a delegation group and a member:

   ```bash
   sudo groupadd -f webops
   sudo useradd -m -G webops -s /bin/bash alice
   sudo passwd alice
   id alice
   ```

7. Write a rule granting `webops` the ability to manage exactly one unit — and nothing else:

   ```bash
   sudo tee /etc/polkit-1/rules.d/49-webops-nginx.rules >/dev/null <<'EOF'
   // Allow members of "webops" to start/stop/restart nginx.service only.
   // Every other unit falls through to the systemd defaults (auth_admin).
   polkit.addRule(function(action, subject) {
       if (action.id !== "org.freedesktop.systemd1.manage-units") {
           return polkit.Result.NOT_HANDLED;
       }
       if (!subject.isInGroup("webops")) {
           return polkit.Result.NOT_HANDLED;
       }

       var unit = action.lookup("unit");
       var verb = action.lookup("verb");

       if (unit === "nginx.service" &&
           ["start", "stop", "restart", "reload", "status"].indexOf(verb) >= 0) {
           polkit.log("webops grant: " + subject.user + " " + verb + " " + unit);
           return polkit.Result.YES;
       }
       return polkit.Result.NOT_HANDLED;
   });
   EOF
   sudo chmod 0644 /etc/polkit-1/rules.d/49-webops-nginx.rules
   ```

8. polkit reloads `rules.d` automatically on change. Confirm it parsed cleanly:

   ```bash
   sudo journalctl -u polkit -n 20 --no-pager
   ```

   ```
   polkitd[701]: Loading rules from directory /etc/polkit-1/rules.d
   polkitd[701]: Finished loading, compiling and executing 6 rules
   ```

   A syntax error appears here — and the rest of that file is silently skipped:

   ```
   polkitd[701]: Error compiling script /etc/polkit-1/rules.d/49-webops-nginx.rules
   ```

9. Test as `alice`, from a login session (polkit needs a session; `su -` alone may not give you one):

   ```bash
   sudo apt-get install -y nginx || sudo dnf install -y nginx
   ssh alice@localhost
   ```

   ```bash
   systemctl restart nginx.service          # allowed, no password
   echo "exit=$?"
   systemctl restart sshd.service           # denied / prompts for admin auth
   ```

   ```
   exit=0
   ==== AUTHENTICATING FOR org.freedesktop.systemd1.manage-units ====
   Authentication is required to manage system services or other units.
   Authenticating as: root
   Password:
   ```

10. Verify the log line your rule emitted:

    ```bash
    sudo journalctl -u polkit --no-pager | grep 'webops grant'
    ```

    ```
    polkitd[701]: webops grant: alice restart nginx.service
    ```

11. Understand rule ordering. Files are read in lexicographic order and the **first** rule returning a non-`NOT_HANDLED` value decides. Prove it:

    ```bash
    sudo tee /etc/polkit-1/rules.d/10-deny-all-manage.rules >/dev/null <<'EOF'
    polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            subject.isInGroup("webops")) {
            return polkit.Result.NO;
        }
    });
    EOF
    # Retry the nginx restart as alice — it now fails outright.
    sudo rm /etc/polkit-1/rules.d/10-deny-all-manage.rules
    ```

12. Audit `pkexec`, historically the highest-value local privilege-escalation target on Linux (CVE-2021-4034 "PwnKit", CVE-2021-3560):

    ```bash
    ls -l "$(command -v pkexec)"
    ```

    ```
    -rwsr-xr-x 1 root root 31032 Aug  1 09:14 /usr/bin/pkexec
    ```

13. If nothing on the host requires it, remove the setuid bit and make the change survive package upgrades:

    ```bash
    # Debian: statoverride so dpkg does not restore the bit
    sudo dpkg-statoverride --update --add root root 0755 /usr/bin/pkexec
    ls -l /usr/bin/pkexec

    # RHEL: file capability/permission change plus a check in your config management
    sudo chmod 0755 /usr/bin/pkexec
    ```

14. Verify the effect and confirm nothing you rely on broke:

    ```bash
    pkexec id
    ```

    ```
    pkexec must be setuid root
    ```

    Reverse it if you find a dependency:

    ```bash
    sudo dpkg-statoverride --remove /usr/bin/pkexec && sudo chmod 4755 /usr/bin/pkexec
    ```

**Check your understanding**

- **Q7.1** — Distinguish `auth_self`, `auth_admin`, `auth_self_keep` and `auth_admin_keep` in a `<defaults>` block.
- **Q7.2** — Your rule returns `polkit.Result.NO` instead of `polkit.Result.NOT_HANDLED` when the subject is not in `webops`. What is the unintended consequence?
- **Q7.3** — Why is a `.pkla` file you wrote on Debian 12 silently ignored, and how do you confirm which backend is in use?
- **Q7.4** — A polkit rule grants a user `manage-units` for *all* units. Explain concretely why this is equivalent to granting root.
- **Q7.5** — What is the functional difference between `subject.isInGroup("webops")` and `subject.active`, and when would you require both?
- **Q7.6** — Removing the setuid bit from `pkexec` mitigates PwnKit. Name one thing it does *not* mitigate, and the control that does.

---

## Exercise 8 — USBGuard: device-level attack surface

> **Lockout warning.** Generate the policy while your keyboard and mouse are attached, and keep a console/serial/SSH path open. On a laptop, an incorrect policy means no keyboard at the login prompt.

### Steps

1. Enumerate the devices the kernel currently sees:

   ```bash
   lsusb
   usbguard list-devices
   ```

   ```
   1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "jEP/6WzviqdJ5VSeTUY8PatCNBKead+ktYwvZ/aiKvo=" parent-hash "..." with-interface 09:00:00
   4: allow id 046d:c31c serial "" name "USB Keyboard" hash "kFEE2FpMHU2..." parent-hash "..." with-interface { 03:01:01 03:00:00 }
   6: block id 0781:5591 serial "4C531001..." name "Ultra USB 3.0" hash "d6a9Xz..." with-interface 08:06:50
   ```

2. Generate an initial allow-list from the currently connected hardware:

   ```bash
   sudo usbguard generate-policy > /tmp/rules.conf
   sudo install -o root -g root -m 0600 /tmp/rules.conf /etc/usbguard/rules.conf
   sudo shred -u /tmp/rules.conf
   sudo cat /etc/usbguard/rules.conf
   ```

3. Read the daemon configuration and understand each policy knob before starting the service:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/usbguard/usbguard-daemon.conf
   ```

   ```
   RuleFile=/etc/usbguard/rules.conf
   RuleFolder=/etc/usbguard/rules.d/
   ImplicitPolicyTarget=block
   PresentDevicePolicy=apply-policy
   PresentControllerPolicy=keep
   InsertedDevicePolicy=apply-policy
   RestoreControllerDeviceState=false
   DeviceManagerBackend=uevent
   IPCAllowedUsers=root
   IPCAllowedGroups=
   AuditFilePath=/var/log/usbguard/usbguard-audit.log
   ```

4. Confirm the two settings that determine whether you lock yourself out:

   ```bash
   grep -E '^(PresentDevicePolicy|PresentControllerPolicy|ImplicitPolicyTarget)' /etc/usbguard/usbguard-daemon.conf
   ```

   `PresentControllerPolicy=keep` is what keeps the built-in root hubs — and therefore an internal keyboard — functional regardless of policy.

5. Start the daemon and confirm state:

   ```bash
   sudo systemctl enable --now usbguard.service
   systemctl status usbguard --no-pager | head -5
   usbguard list-rules
   ```

6. Test the block path. Insert a USB mass-storage device that is **not** in the policy:

   ```bash
   usbguard list-devices --blocked
   sudo journalctl -u usbguard -n 10 --no-pager
   ```

   ```
   9: block id 0781:5591 serial "..." name "Ultra USB 3.0" hash "..." with-interface 08:06:50
   usbguard-daemon[1120]: Device blocked: id=9 name="Ultra USB 3.0" rule="implicit"
   ```

   Confirm the kernel never bound a driver:

   ```bash
   lsblk | grep -c sdb || echo "no block device created"
   ```

7. Authorize it for this session only, then permanently:

   ```bash
   sudo usbguard allow-device 9
   lsblk | tail -2

   sudo usbguard allow-device -p 9       # -p appends a persistent rule
   sudo usbguard list-rules | tail -1
   ```

8. Write a targeted policy by *interface class* rather than by device — this is the durable form. USB class `08` is mass storage, `03` is HID, `e0` is wireless controller:

   ```bash
   sudo tee -a /etc/usbguard/rules.conf >/dev/null <<'EOF'
   # Permit HID (keyboard/mouse) from any vendor, but reject anything that
   # additionally advertises a mass-storage or network interface (BadUSB pattern).
   allow with-interface equals { 03:*:* }

   # Block all USB mass storage outright.
   block with-interface one-of { 08:*:* }

   # Reject (logically detach) USB-to-Ethernet adapters, a common exfil path.
   reject with-interface one-of { e0:*:* 02:*:* }
   EOF
   sudo systemctl restart usbguard
   usbguard list-rules
   ```

9. Understand `allow` vs `block` vs `reject` empirically. Insert the mass-storage device again under each target and watch:

   ```bash
   sudo journalctl -u usbguard -f
   # in another terminal: unplug/replug
   ```

10. Delegate read-only visibility to an operator group without giving them the power to authorize devices:

    ```bash
    sudo usbguard add-user -g wheel --devices=listen --policy=list --exceptions=listen
    sudo ls -l /etc/usbguard/IPCAccessControl.d/
    sudo systemctl restart usbguard
    ```

11. Confirm the audit trail exists and is protected:

    ```bash
    sudo ls -l /var/log/usbguard/
    sudo tail -5 /var/log/usbguard/usbguard-audit.log
    ```

12. Practice the recovery you will one day need. Simulate a lockout and repair it from a console:

    ```bash
    # Console-only recovery:
    sudo systemctl stop usbguard        # policy stops being enforced; devices are authorized by the kernel default
    # or, without stopping the daemon:
    sudo usbguard set-parameter ImplicitPolicyTarget allow 2>/dev/null || \
      sudo sed -i 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=allow/' /etc/usbguard/usbguard-daemon.conf
    sudo systemctl restart usbguard
    ```

**Check your understanding**

- **Q8.1** — What is the difference between the `block` and `reject` rule targets in USBGuard, and which one is visible to a user watching `lsusb`?
- **Q8.2** — Why is `PresentControllerPolicy=keep` the single most important setting to check before enabling the daemon on a laptop?
- **Q8.3** — A rule matches on `hash`. What does the hash cover, and why is it stronger than matching on `id 046d:c31c`?
- **Q8.4** — An attacker plugs in a device that presents itself as a keyboard and injects keystrokes (a "Rubber Ducky"). Does `allow with-interface equals { 03:*:* }` stop it? What would?
- **Q8.5** — Explain the difference between `equals`, `one-of`, `none-of` and `all-of` in a `with-interface` clause.
- **Q8.6** — USBGuard is running with a strict policy. Name two USB-borne risks it does *not* address.

---

## Exercise 9 — Resource limits: PAM versus systemd

### Steps

1. Read your own current limits, soft and hard:

   ```bash
   ulimit -a
   ulimit -Sn; ulimit -Hn
   ```

   ```
   real-time non-blocking time  (microseconds, -R) unlimited
   core file size              (blocks, -c) 0
   max user processes          (-u) 15693
   open files                  (-n) 1024
   1024
   1048576
   ```

2. Read the limits of a *running process* — this is the diagnostic that settles every argument about which mechanism won:

   ```bash
   sudo cat /proc/1/limits
   PID=$(pgrep -f sshd | head -1); sudo cat /proc/$PID/limits | grep -E 'Max open files|Max processes'
   ```

   ```
   Limit                     Soft Limit           Hard Limit           Units
   Max processes             15693                15693                processes
   Max open files            1024                 524288               files
   ```

3. Create a test user and a group to constrain:

   ```bash
   sudo groupadd -f labusers
   sudo useradd -m -G labusers -s /bin/bash bob
   sudo passwd bob
   ```

4. Apply PAM-based limits in a dedicated file — never edit `limits.conf` itself if a `.d` directory exists:

   ```bash
   sudo tee /etc/security/limits.d/50-labusers.conf >/dev/null <<'EOF'
   # <domain>  <type>  <item>       <value>
   @labusers   soft    nproc        40
   @labusers   hard    nproc        60
   @labusers   soft    nofile       1024
   @labusers   hard    nofile       4096
   @labusers   hard    core         0
   @labusers   hard    memlock      64
   @labusers   -       maxlogins    3
   *           hard    core         0
   EOF
   ```

5. Confirm `pam_limits.so` is actually in the stacks you care about — a limits file with no PAM module is inert:

   ```bash
   grep -rn 'pam_limits' /etc/pam.d/
   ```

   ```
   /etc/pam.d/common-session:25:session required        pam_limits.so      # Debian
   /etc/pam.d/system-auth:18:session     required      pam_limits.so       # RHEL
   /etc/pam.d/sshd:8:session    required     pam_limits.so
   ```

6. Verify from a *new login session* (limits apply at session establishment; an existing shell keeps its old values):

   ```bash
   ssh bob@localhost 'ulimit -Su; ulimit -Hu; ulimit -Sn; ulimit -Hn'
   ```

   ```
   40
   60
   1024
   4096
   ```

7. Prove the limit contains a runaway. **In the VM only**, as `bob`:

   ```bash
   ssh bob@localhost
   ```

   ```bash
   ulimit -Su
   # A bounded stress test, not an unbounded fork bomb:
   for i in $(seq 1 200); do sleep 60 & done 2>&1 | tail -3
   ```

   ```
   -bash: fork: retry: Resource temporarily unavailable
   -bash: fork: retry: Resource temporarily unavailable
   -bash: fork: Resource temporarily unavailable
   ```

   Clean up from the *root* session, not bob's:

   ```bash
   sudo pkill -u bob
   ```

8. Now demonstrate the crucial gap: **systemd services do not traverse PAM**. Create a service running as `bob` and read its real limits:

   ```bash
   sudo systemd-run --unit=lab-limits --uid=bob --remain-after-exit \
        /bin/sh -c 'sleep 300'
   PID=$(systemctl show -p MainPID --value lab-limits)
   sudo grep -E 'Max processes|Max open files' /proc/$PID/limits
   ```

   ```
   Max processes             15693                15693                processes
   Max open files            1024                 524288               files
   ```

   The `@labusers hard nproc 60` rule had no effect.

9. Apply the systemd-native equivalent:

   ```bash
   sudo systemctl stop lab-limits ; sudo systemctl reset-failed
   sudo systemd-run --unit=lab-limits --uid=bob --remain-after-exit \
        -p LimitNPROC=60 -p LimitNOFILE=4096:4096 -p TasksMax=50 -p MemoryMax=256M \
        /bin/sh -c 'sleep 300'
   PID=$(systemctl show -p MainPID --value lab-limits)
   sudo grep -E 'Max processes|Max open files' /proc/$PID/limits
   systemctl show lab-limits -p TasksMax -p TasksCurrent -p MemoryMax
   ```

   ```
   Max processes             60                   60                   processes
   Max open files            4096                 4096                 files
   TasksMax=50
   TasksCurrent=1
   MemoryMax=268435456
   ```

10. Constrain *interactive* user sessions the systemd way, via the user slice — this is the layer that catches a fork bomb regardless of PAM:

    ```bash
    sudo mkdir -p /etc/systemd/system/user-.slice.d
    sudo tee /etc/systemd/system/user-.slice.d/50-limits.conf >/dev/null <<'EOF'
    [Slice]
    TasksMax=200
    MemoryMax=2G
    CPUQuota=200%
    EOF
    sudo systemctl daemon-reload
    ```

    Verify against a live session:

    ```bash
    UID_BOB=$(id -u bob)
    ssh -f bob@localhost 'sleep 120'
    systemctl show "user-${UID_BOB}.slice" -p TasksMax -p TasksCurrent -p MemoryMax
    systemd-cgls "/user.slice/user-${UID_BOB}.slice" | head
    ```

11. Set global defaults for all services and for the manager itself:

    ```bash
    grep -E '^#?Default(LimitNOFILE|LimitNPROC|TasksMax)' /etc/systemd/system.conf
    sudo sed -i 's/^#\?DefaultLimitCORE=.*/DefaultLimitCORE=0:0/' /etc/systemd/system.conf
    sudo systemctl daemon-reexec
    systemctl show -p DefaultLimitCORE -p DefaultTasksMax
    ```

12. Disable core dumps completely — they leak keys and credentials from memory. All three layers are required:

    ```bash
    # 1. sysctl
    echo 'fs.suid_dumpable = 0' | sudo tee /etc/sysctl.d/61-coredump.conf
    # 2. PAM/shell limit
    echo '* hard core 0' | sudo tee -a /etc/security/limits.d/50-labusers.conf
    # 3. systemd's coredump handler
    sudo mkdir -p /etc/systemd/coredump.conf.d
    printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' | sudo tee /etc/systemd/coredump.conf.d/disable.conf
    sudo sysctl --system >/dev/null && sudo systemctl daemon-reexec
    sysctl kernel.core_pattern fs.suid_dumpable
    ```

13. Clean up:

    ```bash
    sudo systemctl stop lab-limits; sudo systemctl reset-failed
    sudo pkill -u bob; sudo userdel -r bob
    ```

**Check your understanding**

- **Q9.1** — You added `@labusers hard nproc 60` to `/etc/security/limits.d/`, but a `bob`-owned systemd service still gets 15693. Why, and give the two possible fixes.
- **Q9.2** — What is the difference between the `soft`, `hard` and `-` types in `limits.conf`, and which one can a non-root user raise?
- **Q9.3** — `nproc` is enforced per-UID across *all* of that user's sessions. Give a concrete operational incident this causes and how to avoid it.
- **Q9.4** — Distinguish `LimitNPROC=` from `TasksMax=` in a systemd unit. Which one survives a `setuid` change inside the service?
- **Q9.5** — Why does `ulimit -n 8192` fail for a normal user whose hard limit is 4096, and succeed for root?
- **Q9.6** — Explain why disabling core dumps requires three separate changes rather than one.

---

## Exercise 10 — Accounts, shells, and the SUID/capability surface

### Steps

1. List every account that can obtain an interactive shell:

   ```bash
   awk -F: '$7 !~ /(nologin|false|sync)$/ {printf "%-16s uid=%-6s shell=%s\n", $1, $3, $7}' /etc/passwd
   ```

2. List service accounts that wrongly have one:

   ```bash
   awk -F: '$3 >= 1 && $3 < 1000 && $7 !~ /(nologin|false)$/ {print $1, $3, $7}' /etc/passwd
   ```

3. Correct them. Note the path difference between families:

   ```bash
   NOLOGIN=$( [ -x /usr/sbin/nologin ] && echo /usr/sbin/nologin || echo /sbin/nologin )
   sudo usermod -s "$NOLOGIN" games 2>/dev/null
   getent passwd games
   ```

4. Give `nologin` a message and confirm it is shown:

   ```bash
   echo "This account is not available for interactive login. Contact secops@example.com" \
     | sudo tee /etc/nologin.txt
   sudo -u nobody -s "$NOLOGIN" 2>&1 || true
   ```

5. Understand the three different ways an account is "disabled", and what each one actually stops:

   ```bash
   sudo useradd -m carol; sudo passwd carol
   sudo -u carol ssh-keygen -q -N '' -f /home/carol/.ssh/id_ed25519
   sudo -u carol sh -c 'cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'

   # (a) lock the password only
   sudo passwd -l carol
   sudo passwd -S carol
   ```

   ```
   carol L 2026-08-24 0 99999 7 -1
   ```

   ```bash
   # SSH key login still works:
   sudo -u carol ssh -o BatchMode=yes -o StrictHostKeyChecking=no carol@localhost 'echo STILL_IN'
   ```

   ```
   STILL_IN
   ```

   ```bash
   # (b) expire the account — this blocks every authentication path
   sudo chage -E 0 carol
   sudo chage -l carol | head -3
   sudo -u carol ssh -o BatchMode=yes carol@localhost 'echo STILL_IN' ; echo "exit=$?"
   ```

   ```
   Account expired
   exit=254
   ```

   ```bash
   # (c) change the shell — blocks a shell, not scp/sftp/port-forwarding
   sudo usermod -s "$NOLOGIN" carol
   ```

6. Use `/etc/nologin` for maintenance windows and learn its lifecycle gotcha:

   ```bash
   echo "Patching window until 18:00 UTC — logins disabled." | sudo tee /etc/nologin
   ssh carol@localhost ; echo "exit=$?"     # blocked by pam_nologin.so; root is exempt
   grep -rn pam_nologin /etc/pam.d/
   ```

   Now observe that systemd removes it for you at the next boot:

   ```bash
   systemctl cat systemd-user-sessions.service | grep -E 'ExecStart|Description'
   ```

   ```
   Description=Permit User Sessions
   ExecStart=/usr/lib/systemd/systemd-user-sessions start
   ```

   ```bash
   sudo rm -f /etc/nologin
   ```

7. Inventory the SUID/SGID surface — the classic local privilege-escalation inventory:

   ```bash
   sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
        -printf '%M %u %g %10s %p\n' 2>/dev/null | sort -k5 > /root/hardening-lab/07-suid.txt
   wc -l /root/hardening-lab/07-suid.txt
   cat /root/hardening-lab/07-suid.txt
   ```

   ```
   -rwsr-xr-x root root    72000 /usr/bin/chfn
   -rwsr-xr-x root root    44808 /usr/bin/chsh
   -rwsr-xr-x root root    88464 /usr/bin/gpasswd
   -rwsr-xr-x root root    59704 /usr/bin/mount
   -rwsr-xr-x root root    31032 /usr/bin/pkexec
   -rwsr-xr-x root root    68208 /usr/bin/passwd
   -rwsr-xr-x root root   277936 /usr/bin/sudo
   -rwsr-xr-x root root    35192 /usr/bin/umount
   -rwsr-xr-x root root    55672 /usr/bin/su
   ```

8. Inventory **file capabilities** as well — a `cap_setuid` binary is as dangerous as a SUID one and is invisible to the search above:

   ```bash
   sudo getcap -r / 2>/dev/null
   ```

   ```
   /usr/bin/ping cap_net_raw=ep
   /usr/bin/newgidmap cap_setgid=ep
   /usr/bin/newuidmap cap_setuid=ep
   ```

9. Remove the setuid bit from a binary nobody needs, in a way package upgrades will not undo:

   ```bash
   # Debian
   sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chfn
   ls -l /usr/bin/chfn

   # RHEL — record it in your configuration management, dpkg-statoverride has no rpm equivalent
   sudo chmod u-s /usr/bin/chfn
   rpm -Va shadow-utils | grep chfn
   ```

   ```
   .M....... /usr/bin/chfn
   ```

   That `M` is exactly how the package-integrity check (objective 332.2) will report your deliberate change — document it.

10. Re-run the SUID inventory and diff against the baseline. Any future difference is either your change or an intrusion:

    ```bash
    sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %g %10s %p\n' 2>/dev/null \
      | sort -k5 > /root/hardening-lab/07-suid-after.txt
    diff /root/hardening-lab/07-suid.txt /root/hardening-lab/07-suid-after.txt
    ```

11. Clean up:

    ```bash
    sudo userdel -r carol
    sudo dpkg-statoverride --remove /usr/bin/chfn 2>/dev/null && sudo chmod 4755 /usr/bin/chfn
    ```

**Check your understanding**

- **Q10.1** — Rank `passwd -l`, `usermod -s /usr/sbin/nologin` and `chage -E 0` by how completely they disable an account, and explain what each one leaves open.
- **Q10.2** — Why does `/etc/nologin` disappear after a reboot on a systemd host, and which unit is responsible?
- **Q10.3** — Why does the SUID inventory use `-xdev`, and what would you miss without it? What would you miss *with* it?
- **Q10.4** — A binary has no setuid bit but carries `cap_dac_read_search=ep`. What can its user read, and why is this arguably worse than SUID root for a data-confidentiality threat model?
- **Q10.5** — On Debian, why is `dpkg-statoverride` used instead of a plain `chmod u-s`?

---

## Exercise 11 — Verification: prove the hardening survived a reboot

A control that is not verified after reboot is a control you *hope* you have.

### Steps

1. Write a verification script that asserts every change you made:

   ```bash
   sudo tee /root/hardening-lab/verify.sh >/dev/null <<'EOF'
   #!/bin/bash
   # Post-reboot verification for LPIC-3 303 objective 332.1 lab.
   fail=0
   chk() {  # chk <description> <expected> <actual>
       if [ "$2" = "$3" ]; then
           printf '  [ OK ]  %-42s %s\n' "$1" "$3"
       else
           printf '  [FAIL]  %-42s expected=%s actual=%s\n' "$1" "$2" "$3"; fail=1
       fi
   }

   echo "== Kernel runtime parameters =="
   for kv in kernel.kptr_restrict=2 kernel.dmesg_restrict=1 kernel.yama.ptrace_scope=1 \
             kernel.randomize_va_space=2 fs.suid_dumpable=0 fs.protected_regular=2; do
       k=${kv%%=*}; want=${kv##*=}
       chk "$k" "$want" "$(sysctl -n "$k" 2>/dev/null)"
   done

   echo "== Boot loader =="
   cfg=$(ls /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null | head -1)
   chk "grub.cfg mode"        "600" "$(stat -c %a "$cfg" 2>/dev/null)"
   grep -qE 'password_pbkdf2|GRUB2_PASSWORD' "$cfg" /boot/grub2/user.cfg 2>/dev/null \
       && echo "  [ OK ]  grub superuser password present" \
       || { echo "  [FAIL]  grub superuser password absent"; fail=1; }

   echo "== Kernel command line =="
   for p in slab_nomerge init_on_alloc=1 vsyscall=none; do
       grep -qw -- "$p" /proc/cmdline \
           && echo "  [ OK ]  cmdline contains $p" \
           || { echo "  [FAIL]  cmdline missing $p"; fail=1; }
   done

   echo "== Services =="
   for u in cups.service avahi-daemon.service; do
       st=$(systemctl is-enabled "$u" 2>&1)
       case "$st" in
         masked|disabled|*"No such file"*) echo "  [ OK ]  $u -> $st" ;;
         *) echo "  [FAIL]  $u -> $st"; fail=1 ;;
       esac
   done

   echo "== USBGuard =="
   chk "usbguard active"       "active" "$(systemctl is-active usbguard 2>/dev/null)"
   chk "rules.conf mode"       "600"    "$(stat -c %a /etc/usbguard/rules.conf 2>/dev/null)"

   echo "== Core dumps =="
   chk "kernel.core_pattern"   "|/bin/false" "$(sysctl -n kernel.core_pattern 2>/dev/null)"

   echo
   [ "$fail" -eq 0 ] && echo "RESULT: all checks passed" || echo "RESULT: failures present"
   exit "$fail"
   EOF
   sudo chmod 0700 /root/hardening-lab/verify.sh
   ```

2. Run it before rebooting, to catch typos while you still have a working shell:

   ```bash
   sudo /root/hardening-lab/verify.sh
   ```

3. Reboot and run it again. Only the second run is evidence:

   ```bash
   sudo reboot
   # after boot:
   sudo /root/hardening-lab/verify.sh; echo "exit=$?"
   ```

4. Confirm nothing you hardened broke a service:

   ```bash
   systemctl --failed --no-pager
   sudo journalctl -p err -b --no-pager | tail -30
   systemd-analyze security --no-pager | head -15
   ```

5. Produce the final delta report against the Exercise 1 baseline:

   ```bash
   cd /root/hardening-lab
   sudo ss -tulpnH | sort -k1,1 -k5,5 > 03-listeners-after.txt
   diff 03-listeners.txt 03-listeners-after.txt
   diff 06-security-baseline.txt 06-security-after.txt | head -20
   ```

**Check your understanding**

- **Q11.1** — Why is the pre-reboot run of `verify.sh` insufficient as evidence, even when every check passes?
- **Q11.2** — Your verification script asserts `kernel.core_pattern = |/bin/false` but on a systemd host it reads `|/usr/lib/systemd/systemd-coredump …`. Is that a failure? What is the correct assertion?
- **Q11.3** — `systemctl --failed` is empty, but a sandboxed service is silently failing to do its job (writes to a path it can no longer reach). How would you detect this?
- **Q11.4** — Name the single control from this entire lab that most reduces risk on an internet-facing server, and the one that most reduces risk on a physically accessible kiosk. Justify both.

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 1

**Q1.1 — Present.** `cups.socket` is a socket-activation unit: systemd itself holds the listening socket, and the first connection to it starts `cups.service` on demand. The service being "not running" is a snapshot, not a state. This is the single most common hardening error on systemd hosts — disabling `foo.service` and leaving `foo.socket`, `foo.path` or `foo.timer` enabled. Always enumerate the whole family with `systemctl list-unit-files | grep '^cups'`.

**Q1.2 —** `ss -tulpn` shows only what is *listening right now over IP/UDP*. It misses socket-activated units that are idle, UNIX-domain sockets, D-Bus-activated services, cron/timer jobs, kernel modules, SUID binaries, and anything triggered by a device event. The enabled-unit list catches those, but it in turn misses code that is *installed but not enabled* — a vulnerable SUID binary, a library with a CVE, a helper another service can invoke. The package list is the widest measurement, which is why "remove the package" beats "disable the service" whenever it is possible.

**Q1.3 —** The scale runs from `0` (least exposed) to `10` (most exposed); higher is worse. The textual predicate degrades roughly `SAFE → GOOD → OK → MEDIUM → EXPOSED → UNSAFE` as the number rises. Read the exact thresholds for your systemd version rather than memorising numbers.

**Q1.4 —** Any two of: UNIX-domain sockets (`ss -xlp`); D-Bus-activatable services (`busctl list`); socket-activated units currently idle; SUID/SGID binaries and file capabilities; kernel interfaces such as `/proc`, `/sys`, `io_uring`, eBPF; timers and cron jobs; USB/device-event handlers (udev rules).

---

### Exercise 2

**Q2.1 —** `disable` removes the symlinks that the unit's `[Install]` section created — typically under `/etc/systemd/system/<target>.wants/`. The unit file is untouched and can still be started manually or pulled in as a dependency of something else. `mask` creates a symlink from `/etc/systemd/system/<unit>` (or `/run/systemd/system/<unit>` with `--runtime`) to `/dev/null`, which makes the unit completely unloadable: manual start fails, and any dependency on it fails too.

**Q2.2 —** The connection is accepted by systemd, which then tries to start `cups.service` — and fails, because it is masked. The socket stays open (so the port is still reachable and still an attack surface for anything that can be triggered pre-activation), and clients get a connection that goes nowhere. Mask the socket as well.

**Q2.3 —** *Disabled* is trivially reversible by anyone with `manage-units` (`systemctl start` needs no `enable`). *Masked* is not reversible with `manage-units` alone — `unmask` maps to `manage-unit-files`, which is a separate polkit action, and the mask symlink lives in `/etc` and needs root to remove. *Purged* is not reversible without package-installation rights. This ladder is exactly why "purge > mask > disable".

**Q2.4 —** A static unit has no `[Install]` section, so it is never in a `.wants/` directory and there is nothing for `disable` to unlink — `systemctl disable` reports it as static and does nothing. `mask` *does* work on static units and is the correct tool there. (`mask` refuses only on units that are already symlinks pointing somewhere other than `/dev/null`, and on units in `/run` when a conflicting `/etc` entry exists.)

---

### Exercise 3

**Q3.1 —** The machine stops at the GRUB menu and waits for a username and password before booting anything. It will not come back up unattended. This is why `--unrestricted` exists: it separates *"may boot the default entry"* (everyone) from *"may edit entries or reach the GRUB shell"* (superusers only). An `--users ""` clause on a `menuentry` achieves the same for a single entry.

**Q3.2 —** Removing the disk and reading it in another machine — or booting the machine from removable media if the firmware controls are ever bypassed or reset by clearing NVRAM/CMOS. The GRUB password protects the *boot menu*, not the *data*. The control that stops it is **full-disk encryption with LUKS**, objective **331.3 Encrypted File Systems**. GRUB passwords and firmware passwords raise the effort; only encryption changes the outcome.

**Q3.3 —** `password` stores the password in **cleartext** inside `grub.cfg`, which is world-readable by default and is copied into backups and images. `password_pbkdf2` stores a salted PBKDF2-HMAC-SHA512 derivation. The `10000` is the PBKDF2 **iteration count** — the work factor. It is still offline-crackable, which is why step 10 also restricts the file mode; a low iteration count plus a weak password is a weekend of GPU time.

**Q3.4 —** The username is `root` (RHEL's `grub2-setpassword` hard-codes the GRUB superuser as `root`; this is the *GRUB* root, unrelated to the Unix root password). The hash is stored in `/boot/grub2/user.cfg` as `GRUB2_PASSWORD=…`, which `grub.cfg` sources. Keeping it in a separate file is what allows `grub2-mkconfig` to regenerate `grub.cfg` without destroying the password.

**Q3.5 —** The `40_custom` password **survives**, because `update-grub`/`grub2-mkconfig` regenerates `grub.cfg` *from* the `/etc/grub.d/` scripts and `/etc/default/grub` — your directives are inputs, not outputs. A hand-edit of `/boot/grub/grub.cfg` **does not survive**: that file is generated output and is overwritten wholesale. This is the general rule for GRUB 2 and the most frequently examined point about it.

---

### Exercise 4

**Q4.1 —** Two explanations: **(a)** another file that sorts later — `/etc/sysctl.d/99-*.conf` or `/etc/sysctl.conf` — sets it to `1` and wins on precedence; **(b)** the value is being set at runtime after boot by a service, container runtime, or `systemd-sysctl` reading a `/usr/lib/sysctl.d` file that shadows differently than you assumed. Distinguish them with `sudo sysctl --system 2>&1 | grep -i kptr` (prints every file applied, in order, so the last one to touch the key is the winner) and `grep -rn kptr_restrict /etc/sysctl.conf /etc/sysctl.d/ /run/sysctl.d/ /usr/lib/sysctl.d/`.

**Q4.2 —** `1` replaces kernel pointers with zeros for users **lacking `CAP_SYSLOG`** — root and `CAP_SYSLOG` holders still see real addresses. `2` replaces them with zeros for **everyone**, regardless of capability. Use `2` on servers; use `1` if a monitoring agent legitimately needs symbol addresses and runs with `CAP_SYSLOG`.

**Q4.3 —** It breaks loading *any* new kernel module: hot-plugging hardware that needs a driver not yet loaded, `modprobe` for a filesystem type on first mount, network drivers for a newly attached NIC, and some VPN/filesystem/container features. It is recommended on a fixed-function appliance because the hardware and workload never change, so nothing legitimate needs to load a module after boot — and it eliminates the single most direct kernel-code-injection path available to a compromised root process. It is a **one-way switch**: only a reboot restores it.

**Q4.4 —** `fs.protected_symlinks` defends against the classic **symlink race in a world-writable sticky directory** (`/tmp`): a privileged process follows a symlink planted by an attacker and writes to a file it did not intend. The kernel refuses to follow symlinks in sticky world-writable directories when the symlink owner differs from the directory owner and the follower. `fs.protected_regular` defends against a *different* attack in the same directories: a privileged process **opens for writing** a pre-created regular file owned by an attacker, letting the attacker read or corrupt data written into "its" file. One is about traversal, the other about ownership of the target.

**Q4.5 —** The **Yama LSM is not built into or not enabled in the running kernel**. `kernel.yama.*` keys only exist when Yama is compiled in (`CONFIG_SECURITY_YAMA=y`) and active. Check with `cat /sys/kernel/security/lsm` — Yama must appear in that list. Debian/Ubuntu enable it by default; some RHEL and custom kernels do not, in which case you must add `yama` to the `lsm=` kernel command line.

**Q4.6 —** `net.ipv4.tcp_syncookies` and `net.ipv4.conf.all.rp_filter` belong to **334.1 Network Hardening**. `kernel.dmesg_restrict` and `fs.suid_dumpable` are host hardening (332.1). The distinction matters for study scope: 332.1 is about the *host* — boot, kernel, services, users, devices — while the `net.*` tree is examined under 334.

---

### Exercise 5

**Q5.1 —** `0` = ASLR off; every process gets identical addresses. `1` = *conservative*: the stack, memory-mapped regions (shared libraries, `mmap` allocations) and the VDSO are randomised, but the **heap (`brk`)** is not, and non-PIE executables load at a fixed address. `2` = *full*: everything in mode 1, **plus the `brk` heap**. The region unique to mode 2 is the `brk`-based heap.

**Q5.2 —** *Useless:* a local attacker can spawn their target with `setarch -R`, or simply brute-force a 32-bit address space, or use an information leak — so ASLR is not a boundary. *Not useless:* the personality flag only affects processes the attacker creates; it cannot derandomise an already-running daemon, a network-facing service, or a setuid binary they did not spawn. ASLR's real job is to force an attacker to chain an **information leak** to a memory-corruption bug, converting a one-shot exploit into a two-bug requirement. Correct framing: ASLR raises exploitation cost; it does not create a privilege boundary. That is also why it is paired with `kptr_restrict`, PIE and RELRO rather than relied on alone.

**Q5.3 —** NX/DEP is *available* from the CPU and *managed* by the kernel, but which pages are marked executable is decided **per binary**, from the ELF `PT_GNU_STACK` program header. `-z execstack` tells the linker to emit that header with `RWE`, and the kernel honours it by mapping the stack executable. NX being "active" means the mechanism works; it does not mean every binary opts in. This is why per-binary auditing (`readelf -lW … GNU_STACK`) is a required step and not redundant with the `dmesg` check.

**Q5.4 —** **Partial RELRO** (`-Wl,-z,relro`) moves the ELF metadata that can be made read-only after relocation — `.init_array`, `.fini_array`, `.got` — into a segment marked read-only, but the **PLT-related GOT (`.got.plt`) stays writable** because lazy binding needs to patch it at each first call. **Full RELRO** adds `-Wl,-z,now` (`BIND_NOW`), which resolves every symbol at load time so `.got.plt` can also be made read-only. The flag producing Full RELRO is therefore `-Wl,-z,relro,-z,now`. Full RELRO closes the classic "GOT overwrite" technique at the cost of slower process start-up.

**Q5.5 —** The canary check is a *deliberate*, detected condition: `__stack_chk_fail` calls `__fortify_fail`, which invokes `abort()` → `SIGABRT` (128 + 6 = 134). A plain `SIGSEGV` (128 + 11 = 139) is an *undetected* memory error that happened to hit an unmapped page. The distinction matters to a defender because `*** stack smashing detected ***` in the journal is a **high-confidence exploitation signal**: the corruption reached the return-address region and was caught. A bare segfault is far more often an ordinary bug. Alert on the first, triage the second.

**Q5.6 —** `_FORTIFY_SOURCE` replaces calls such as `strcpy`/`memcpy`/`sprintf` with `__strcpy_chk`-style variants that receive a compile-time-known destination size. That size comes from `__builtin_object_size()`, which can only compute a useful answer once the optimiser has run enough analysis to know the object's extent. At `-O0` it returns "unknown" for almost everything, so the fortified variants degrade to the unfortified ones and the feature silently does nothing. Hence GCC warns and the flag is effectively a no-op without at least `-O1`.

**Q5.7 —** In order of preference: **(1)** replace or upgrade the software — an executable stack in 2026 almost always means an unmaintained binary with other problems. **(2)** Isolate it: run it under a systemd unit with `MemoryDenyWriteExecute=yes` where possible, a restrictive `SystemCallFilter`, a dedicated unprivileged `User=`, `PrivateNetwork=`/`IPAddressDeny=`, and MAC confinement (SELinux `execstack` booleans / an AppArmor profile — objective 333.2). **(3)** Patch the header in place with `execstack -c /path/to/binary` (or `patchelf`) and test — this works when the executable stack was a linker accident rather than a real requirement, and fails loudly if the program genuinely uses trampolines. **(4)** Accept and compensate: network-isolate it and monitor. Never simply set `randomize_va_space=0` or relax MAC policy to make it work.

---

### Exercise 6

**Q6.1 —** `ProtectSystem=yes` mounts `/usr` and `/boot` read-only. `=full` adds `/etc` read-only. `=strict` mounts the **entire filesystem hierarchy** read-only except `/dev`, `/proc` and `/sys` (which have their own directives). `=strict` is the one that requires `ReadWritePaths=` (or `StateDirectory=`/`LogsDirectory=`/`CacheDirectory=`/`RuntimeDirectory=`) for any daemon that writes state, since otherwise `/var` is read-only too.

**Q6.2 —** `SystemCallFilter=` is implemented with **seccomp-bpf**. The kernel only lets an unprivileged process install a seccomp filter if it has `CAP_SYS_ADMIN` *or* has set `PR_SET_NO_NEW_PRIVS` — the guarantee that the filter cannot be escaped by executing a setuid binary that gains privileges the filter's author never anticipated. systemd therefore implies `NoNewPrivileges=yes` for these directives. What it breaks: any `execve` of a **setuid/setgid binary or a file with capabilities** stops gaining those privileges, so an internal `sudo`, `su`, `pkexec`, `ping`, `mount` or `newuidmap` call inside the service fails. Services that shell out to privileged helpers must be redesigned or given the capability directly via `AmbientCapabilities=`.

**Q6.3 —** `PrivateTmp=yes` gives the service a **private mount namespace** with a fresh `tmpfs` on `/tmp` and `/var/tmp`. The daemon creates its socket inside that namespace, and no client outside can see it — the client gets `ENOENT`. The correct fix is not to disable `PrivateTmp`; it is to move the socket to a proper runtime directory with `RuntimeDirectory=myservice` (creating `/run/myservice`, which is *not* namespaced) and point both daemon and clients there. `/tmp` was never the right place for an IPC socket.

**Q6.4 —** `systemd-analyze security` is a **static, heuristic checklist** of directives present in the unit file; it scores the *configuration*, not the code. A service can score `1.2 OK` and still be running a daemon with a remote unauthenticated RCE, a hard-coded credential, or a path-traversal bug — none of which any sandbox directive addresses. The score tells you how much damage a compromise *could* cause, not how likely a compromise is; treat it as an exposure metric, never as an assurance metric.

**Q6.5 —** `systemctl edit` writes a drop-in to `/etc/systemd/system/<unit>.d/override.conf`, which is **merged over** the vendor unit and lives in the administrator-owned tree. Editing `/usr/lib/systemd/system/foo.service` directly puts your change in the **package-owned** tree: the next package upgrade overwrites it and your hardening silently disappears — with no failure, no log line, and a service that quietly runs unconfined again. (`systemctl edit --full` is the escape hatch when you must replace the whole unit; it copies it into `/etc`, which is still safe.)

**Q6.6 —** Any three of: **JIT compilers and runtimes** (Java/JVM, .NET, JavaScript engines including anything embedding V8/SpiderMonkey, LuaJIT, PyPy); **language runtimes doing dynamic code generation** (Python `ctypes` callbacks, Ruby, Julia, some Node native modules); **graphics/compute stacks** that generate shaders at runtime (Mesa, CUDA/OpenCL, some GPU drivers); **emulators, tracing and debugging tools** (QEMU TCG, Wine, `gdb`, eBPF-adjacent userspace JITs, Valgrind); **Go binaries using cgo with certain trampolines**, and **FFI libraries** such as libffi's closure allocation. The directive blocks `mmap`/`mprotect` producing simultaneously writable+executable mappings, and all of the above depend on that transition.

**Q6.7 —** `CapabilityBoundingSet=` (empty) clears the **bounding set** — the ceiling on what capabilities *any* process in the unit may ever hold, including after `execve` of a file with file capabilities. It is a hard limit that can never be raised for the lifetime of the service. `AmbientCapabilities=` (empty) clears the **ambient set** — the capabilities that are *automatically granted* to a non-root process across `execve`. Emptying ambient means "hand out nothing extra"; emptying bounding means "nothing can ever be acquired". Bounding is the security control; ambient is the grant mechanism. Setting `AmbientCapabilities=CAP_NET_BIND_SERVICE` while `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` is the idiomatic way to let a non-root daemon bind port 443 and nothing else.

---

### Exercise 7

**Q7.1 —** All four require successful authentication before the action proceeds; they differ in **whose** credentials and **for how long**. `auth_self` — the requesting user's own password. `auth_admin` — the password of an administrator (root, or a member of the admin group as configured for the polkit backend, typically `wheel`/`sudo`). The `_keep` variants (`auth_self_keep`, `auth_admin_keep`) cache the successful authorization for a short period scoped to the session, so repeated actions do not re-prompt. Use `_keep` only where repeated prompting drives users to disable the control entirely.

**Q7.2 —** Returning `NO` is an **explicit deny that terminates evaluation**. Because rules are evaluated in lexicographic filename order and the first non-`NOT_HANDLED` result wins, an explicit `NO` for every non-`webops` subject means *no rule in any later file, and no `<defaults>` in the action's own `.policy` XML, is ever consulted*. Root and administrators would be denied `manage-units` outright, breaking `systemctl` for everyone. `NOT_HANDLED` is the correct "I have no opinion" value; reserve `NO` for a deliberate, targeted denial you intend to be final.

**Q7.3 —** `.pkla` files are read only by the **local-authority backend**, which polkit ≥ 0.106 replaced with the JavaScript `rules.d` engine. Debian 12 ships polkit ≥ 0.105-with-JS (and Debian 13 / RHEL 9 ship polkit 121+), so the `localauthority` directories are either absent or vestigial and your file is never parsed — silently, with no error. Confirm with `pkaction --version` (≥ 0.106 → JavaScript) and by checking whether `/etc/polkit-1/rules.d/` exists and whether `journalctl -u polkit` reports "Loading rules from directory". If `/etc/polkit-1/localauthority/` is present *and* the version is < 0.106, `.pkla` applies.

**Q7.4 —** `org.freedesktop.systemd1.manage-units` allows starting an arbitrary unit. A user with that right can create nothing new, but they can `systemctl start` any existing unit — and, combined with `manage-unit-files` or a writable unit directory, define one. Even without file-write rights, systemd offers `systemd-run`-style transient units through the same D-Bus interface: the user asks the manager (running as PID 1, as root) to execute a command as root. There is no meaningful gap between "may ask PID 1 to run arbitrary units" and "is root". This is why the rule in step 7 filters on `action.lookup("unit")` and `action.lookup("verb")` and returns `NOT_HANDLED` for everything else.

**Q7.5 —** `subject.isInGroup("webops")` asks **who** the requester is — a static identity property. `subject.active` asks **where they are** — whether their login session is currently the active session on a local seat (physically at the console), as opposed to an inactive session or a remote/SSH session. Require both when a grant should only apply to someone physically present: e.g. allowing suspend, mounting removable media, or changing network settings from the console, while denying the same action to an SSH session. `subject.local` (session on a local seat, active or not) is the companion property.

**Q7.6 —** Removing the setuid bit stops `pkexec` from being usable as a *privilege-escalation* target — PwnKit (CVE-2021-4034) needed pkexec to be setuid-root to matter. It does **not** mitigate CVE-2021-3560, which is a bug in `polkitd` itself: a race in how the daemon resolves the requesting process lets an unprivileged caller have a request evaluated as `uid=0`, no `pkexec` involved. The control for that is **patching polkit**. More generally, removing the bit hardens one path; keeping the package updated is what addresses the daemon, the D-Bus surface, and the rules engine.

---

### Exercise 8

**Q8.1 —** `block` means "do not authorize this device" — the kernel refuses to bind drivers, so it is non-functional, but it **remains enumerated and visible**: it shows in `lsusb` and in `usbguard list-devices` with a `block` target. `reject` means "remove this device from the system entirely" — USBGuard instructs the kernel to logically detach it, so it **disappears from `lsusb`** as though unplugged. `block` is the better default (it is reversible in place with `allow-device`, and it preserves an audit record of what was attached); `reject` is appropriate for device classes you never want to see and want the kernel to stop tracking.

**Q8.2 —** Because a laptop's internal keyboard and trackpad are attached to USB **root hubs and internal controllers**. If `PresentControllerPolicy` is anything other than `keep` (e.g. `apply-policy` with an `ImplicitPolicyTarget=block`), starting the daemon can block the controllers themselves — taking the keyboard down with them. You are then at a login prompt with no way to type, and the only recoveries are a serial/network session or booting rescue media. `keep` preserves the authorization state controllers already had at daemon start.

**Q8.3 —** The USBGuard device hash is computed over the device's **descriptor set** — vendor ID, product ID, device name/manufacturer strings, serial number, and the interface descriptors — producing a fingerprint of the device's declared identity. It is stronger than `id 046d:c31c` because vendor:product identifies a *model*, not a *unit*: any device that claims those 16-bit IDs matches, and a programmable USB device (Rubber Ducky, Bash Bunny, a flashed microcontroller) can claim any IDs it likes for a few cents. The hash additionally binds the serial and interface layout, so a substituted device with a different serial or an extra interface no longer matches. It is still self-reported data — a determined attacker who clones every descriptor field will match — so treat the hash as raising cost substantially, not as cryptographic device attestation.

**Q8.4 —** **No.** A keystroke-injection device *is* a HID keyboard: it presents interface class `03` and a rule allowing all of class `03` allows it. This is exactly the BadUSB threat model. What helps: (a) allow HID only by **hash or serial** for the specific keyboards you own, rather than by class; (b) `reject` any device presenting a HID interface **combined with** storage/network interfaces (`with-interface all-of { 03:*:* 08:*:* }`); (c) screen-lock policies plus session-level input filtering; (d) organisationally, physical port control. USBGuard is a device-authorization layer; it cannot distinguish a legitimate keyboard from a malicious one that is descriptor-identical.

**Q8.5 —** These are set operators over the device's list of interface descriptors. `equals` — the device's interface set must match the listed set **exactly** (no more, no fewer). `one-of` — **at least one** listed interface is present. `none-of` — **no** listed interface is present. `all-of` — **every** listed interface is present, and others may also be. `equals` is the strictest and the right choice for a known device; `one-of` is right for "block anything that has a mass-storage interface at all"; `all-of` is right for detecting composite-device patterns like HID+storage.

**Q8.6 —** Any two of: (a) **an authorized device that later misbehaves** — USBGuard authorizes at attach time and does not inspect traffic afterwards; (b) **firmware attacks against the USB controller or the device's own firmware**, below the descriptor layer; (c) **DMA attacks over Thunderbolt/USB4**, which are a PCIe problem addressed by the IOMMU and Kernel DMA Protection, not by USB device authorization; (d) **data exfiltration via an allowed device** — a whitelisted USB drive can still walk out of the building, which is an encryption and DLP problem; (e) **electrical attacks** ("USB Killer"), which no software control addresses.

---

### Exercise 9

**Q9.1 —** Because `/etc/security/limits.conf` is read by the PAM module `pam_limits.so`, and **systemd services do not go through a PAM stack**. systemd forks and executes the service directly from PID 1, applying only the resource directives in the unit; there is no `session` phase and therefore no `pam_limits`. Two fixes: **(a) the correct one** — set the limits natively in the unit: `LimitNPROC=60`, `LimitNOFILE=4096`, `TasksMax=50`, ideally in a drop-in. **(b)** Add `PAMName=<stack>` to the unit so systemd does open a PAM session for it — legitimate but heavier, and only appropriate when you specifically want the full PAM session semantics (it is what `systemd --user` and login services do).

**Q9.2 —** `soft` is the currently enforced value; `hard` is the ceiling the soft value may be raised to; `-` sets both at once to the same value, making the limit unraisable. A **non-root user may raise their soft limit up to their hard limit**, and may lower either — but may never raise a hard limit. Consequently a `soft` limit is a guardrail against accident, while a `hard` limit (or `-`) is the security control. Writing `@labusers soft nproc 40` alone is nearly meaningless if the hard limit remains 15693.

**Q9.3 —** `RLIMIT_NPROC` is counted **per real UID across the whole system**, not per session or per login. So an operator who is already running 55 processes across three SSH sessions and a cron job hits a `hard nproc 60` and **cannot open a new session at all** — `sshd` fails to fork the shell, and the error looks like an authentication failure. The same trap bites service accounts running many workers. Avoid it by: sizing `nproc` from observed peak usage plus generous headroom; never applying a low `nproc` to `root` or to `*` (which includes root on many stacks); preferring cgroup-based `TasksMax=` on the user slice, which is enforced at the cgroup level with clearer failure semantics; and always testing from a *new* session while keeping an existing root session open.

**Q9.4 —** `LimitNPROC=` sets the POSIX `RLIMIT_NPROC` rlimit, which the kernel counts **per real UID** and which is inherited across `fork`/`exec`. `TasksMax=` sets the **cgroup v2 `pids.max`** controller on the unit's cgroup, counting every task in that cgroup regardless of UID. **`TasksMax=` survives a setuid change**: if the service drops from root to another user, or spawns helpers under different UIDs, the cgroup limit still applies to the whole unit, whereas `RLIMIT_NPROC` starts counting against a different UID's separate quota (and is famously not enforced for root at all in some paths). For containment, `TasksMax=` is the reliable one; use `LimitNPROC=` for compatibility with software that reads its own rlimits.

**Q9.5 —** Raising a **hard** limit requires `CAP_SYS_RESOURCE`. A normal user calling `ulimit -n 8192` when the hard limit is 4096 is implicitly asking to exceed the ceiling, and `setrlimit(2)` returns `EPERM`. Root (or any process with `CAP_SYS_RESOURCE`) may raise the hard limit freely, so the same command succeeds. Note the asymmetry that makes this a one-way door: any process may **lower** its hard limit, and the lowering is irreversible for that process and all its children — which is itself a useful hardening primitive.

**Q9.6 —** Because three independent subsystems can each produce or permit a dump. **(1)** `fs.suid_dumpable` governs whether the kernel will dump a process that changed privileges (setuid/setgid/capabilities) — the highest-value dumps, since their memory holds privileged secrets. **(2)** `RLIMIT_CORE` (via `limits.conf` for login sessions, `LimitCORE=`/`DefaultLimitCORE=` for systemd units) governs the maximum core size per process; a nonzero value anywhere re-enables dumps for that context. **(3)** `kernel.core_pattern` decides *where* the dump goes — on a systemd host it pipes to `systemd-coredump`, which has its own storage policy in `coredump.conf`, and which will happily store dumps even when the shell's `ulimit -c` is 0, because the pipe handler receives the dump directly. Set only one and dumps still land somewhere. This layering — kernel policy, per-process limit, collection handler — is a good general model for host hardening: controls compose, and a single knob is rarely the whole control.

---

### Exercise 10

**Q10.1 —** Weakest to strongest:
1. **`usermod -s /usr/sbin/nologin`** — blocks an interactive shell only. SSH public-key authentication still *succeeds*; the user simply gets the nologin message. Anything not needing a shell still works or partly works: port forwarding, in some configurations `scp`/`sftp` (if the subsystem is invoked without the login shell), cron jobs, `su - user -s /bin/bash` from root, and any daemon running as that UID.
2. **`passwd -l` (equivalently `usermod -L`)** — prefixes the password hash with `!`, so no password will ever match. Password authentication is dead. **SSH keys, GSSAPI/Kerberos, PAM modules that do not consult the hash, and `su` from root all still work** — as demonstrated in step 5(a). Locking the password is the most commonly over-trusted of the three.
3. **`chage -E 0` (or `usermod --expiredate 1`)** — sets the account expiry in the past. `pam_unix`'s account phase rejects the login regardless of *how* the user authenticated, so key-based SSH, password, and Kerberos all fail. This is the closest thing to a real off switch short of `userdel`.
A complete disable applies all three, plus removing `authorized_keys`, killing live sessions (`pkill -u`), and revoking Kerberos/LDAP credentials and sudo rules.

**Q10.2 —** `/etc/nologin` is created and removed by **`systemd-user-sessions.service`**: it removes the file when the system reaches `multi-user.target` (permitting logins) and creates it during shutdown (to stop new logins while services stop). So a hand-created `/etc/nologin` is a *runtime* maintenance flag that does **not** survive a reboot. If you need logins blocked across a reboot, you must stop or mask the login path itself — e.g. `systemctl mask systemd-user-sessions.service` (which then blocks logins persistently, and is a lockout risk), or disable `sshd` and use console access.

**Q10.3 —** `-xdev` keeps `find` on a single filesystem. It is used to avoid descending into `/proc`, `/sys`, `/run`, network mounts (NFS/CIFS — potentially enormous and slow, and their SUID bits are the remote server's problem, not this host's), and bind mounts and container layers under `/var/lib/docker` that would report the same file many times. Without it, the scan is slow, noisy and full of duplicates. **With** it you miss anything on a *separately mounted* local filesystem — very commonly `/home`, `/var`, `/tmp`, `/opt` and `/usr/local` on a partitioned server, which is exactly where an attacker-planted SUID binary would sit. The correct pattern is therefore to enumerate local mount points and run the scan once per filesystem — e.g. iterate over `findmnt -rno TARGET -t ext4,xfs,btrfs` — rather than relying on a single `-xdev` pass from `/`. Also note `nosuid` on a mount defeats SUID regardless of the bit, so mount options belong in the same audit.

**Q10.4 —** `cap_dac_read_search` bypasses **all filesystem read and directory-search permission checks**. Its user can read *every file on the system*: `/etc/shadow`, every private key, every TLS certificate key, every database credential, every user's home directory, and the contents of `/proc/<pid>/environ` for other processes. It is arguably worse than SUID root *for a confidentiality threat model* for two reasons: it is **invisible to the standard `find -perm -4000` audit** that most administrators and many checklists run, and it grants total read access with no accompanying "this is a privileged binary" signal in the file mode — `ls -l` shows an ordinary executable. (For an *integrity* threat model SUID root is worse, since it also grants write.) Always pair the SUID inventory with `getcap -r /`.

**Q10.5 —** Because `dpkg` records the intended ownership and permissions of every file it installs, and on upgrade it **restores** them — a plain `chmod u-s /usr/bin/chfn` is silently reverted the next time the `passwd`/`shadow-utils` package is updated, with no error and no log entry. `dpkg-statoverride` registers a local exception in dpkg's database, so the package manager applies *your* mode on every subsequent unpack. The general lesson applies beyond Debian: any permission hardening that fights the package manager must be recorded somewhere the package manager (or your configuration-management tool) will re-apply, or it is temporary.

---

### Exercise 11

**Q11.1 —** Because almost every control in this lab has two distinct states — *applied now at runtime* and *configured to apply at boot* — and only the second is durable. `sysctl -w` values, a `systemctl start`, a manually authorized USB device and an `ulimit` in the current shell all pass a pre-reboot check while being pure runtime state that vanishes. Conversely, a change written only to a config file (a GRUB directive not yet run through `update-grub`, a kernel parameter added to `/etc/default/grub`) passes no runtime check at all. The reboot is what collapses "configured" and "effective" into one observation. It also catches the failure that matters most operationally: a hardening change that makes the machine **not boot** or **not accept logins** — which you want to discover in a maintenance window, not six weeks later during an unrelated power event.

**Q11.2 —** **Not a failure — the assertion is wrong.** On a systemd host `kernel.core_pattern` is normally `|/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c %h`, because systemd installs its own collector; that is the expected and supported configuration. Piping to `/bin/false` is one way to suppress dumps, but it fights the platform and breaks legitimate crash diagnostics tooling. The correct assertion is to check the **policy**, not the pattern: verify `Storage=none` (and optionally `ProcessSizeMax=0`) in the merged `coredump.conf`, together with `fs.suid_dumpable=0` and `DefaultLimitCORE=0:0` — i.e. `systemd-analyze cat-config systemd/coredump.conf | grep -E '^(Storage|ProcessSizeMax)'`. Assert on the intended outcome; do not hard-code one implementation of it.

**Q11.3 —** `systemctl --failed` only catches units whose **main process exited non-zero or was killed**. A daemon that catches its own `EACCES`, logs a warning and continues running looks perfectly healthy. Detect it by: (a) reading the unit's own journal for the window after the change — `journalctl -u <unit> --since "$(systemctl show -p ActiveEnterTimestamp --value <unit>)" -p warning`; (b) watching for `EPERM`/`EACCES` denials from the sandbox itself, which systemd logs, and for seccomp kills — `journalctl -b | grep -Ei 'seccomp|Operation not permitted|Permission denied'` and `auditctl`-based `SECCOMP` records; (c) strace-ing the running process against the sandbox — `strace -f -e trace=file -p $(systemctl show -p MainPID --value <unit>)`; (d) most reliably, an **end-to-end functional test** of what the service is supposed to produce — did the backup file appear, did the metric arrive, did `chronyc tracking` show a synchronised source. This is the general rule for sandboxing work: the exposure score tells you the sandbox is tight, only a functional test tells you the service still works.

**Q11.4 —**
- **Internet-facing server: systemd unit sandboxing (Exercise 6)**, applied to the network-facing daemons. The realistic attack path is remote code execution in a listening service, and the sandbox directives are what decide whether that RCE yields a shell in a namespace with no capabilities, no write access outside one state directory, a `@system-service` syscall filter and no network egress — or root on the host. GRUB passwords and USBGuard are irrelevant to an attacker who is never physically present. (Reducing the number of listeners at all, Exercise 2, is the close runner-up and is a prerequisite: the cheapest sandbox is a service that is not installed.)
- **Physically accessible kiosk: full-disk encryption, with the boot chain of Exercise 3 as its enforcement.** The realistic attack is someone with hands on the machine: boot to a root shell with `init=/bin/bash`, boot from a USB stick, or take the disk. A GRUB superuser password plus firmware password, locked boot order and Secure Boot close the first two; only LUKS (objective 331.3) closes the third. USBGuard is the strong second control here, since the same physical access enables BadUSB and mass-storage exfiltration.
The underlying point is that "hardening" is not a fixed checklist — the same catalogue of controls is ranked differently by the exposure of the host, and being able to justify that ranking is what the objective is testing.

</details>

---

## References

- LPI, *Exam 303-300 Objectives (LPIC-3 Security, version 3.0)* — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- GNU, *GRUB 2 Manual — Security* — <https://www.gnu.org/software/grub/manual/grub/grub.html#Security>
- The Linux Kernel Archives, *Documentation: sysctl/kernel.rst* — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html>
- The Linux Kernel Archives, *Documentation: sysctl/fs.rst* — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html>
- The Linux Kernel Archives, *Yama LSM* — <https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html>
- The Linux Kernel Archives, *Address space layout randomization / `personality(2)` semantics* — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html#randomize-va-space>
- freedesktop.org, *systemd.exec(5) — Sandboxing directives* — <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
- freedesktop.org, *systemd.resource-control(5)* — <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
- freedesktop.org, *systemd-analyze(1) — `security` verb* — <https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html>
- freedesktop.org, *sysctl.d(5)* — <https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html>
- freedesktop.org, *systemd-coredump(8) and coredump.conf(5)* — <https://www.freedesktop.org/software/systemd/man/latest/coredump.conf.html>
- freedesktop.org, *polkit — Reference Manual* — <https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html>
- freedesktop.org, *polkit — Writing polkit rules (`polkit.js`)* — <https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html#polkit-rules>
- USBGuard Project, *Documentation and rule language* — <https://usbguard.github.io/documentation/>
- man7.org, *`setrlimit(2)`*, *`pam_limits(8)`*, *`capabilities(7)`*, *`seccomp(2)`*, *`nologin(5)`*, *`personality(2)`* — <https://man7.org/linux/man-pages/>
- Red Hat, *Configuring GRUB and protecting boot entries (RHEL 9 Security hardening)* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/>
- Debian, *Securing Debian Manual* — <https://www.debian.org/doc/manuals/securing-debian-manual/>
- MITRE, *CVE-2021-4034 (PwnKit)* — <https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2021-4034>
- MITRE, *CVE-2021-3560 (polkit authentication bypass)* — <https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2021-3560>