# 332.1 — Host Hardening

**LPIC-3 303-300 (Security), v3.0.0 · Topic 332: Host Security · Weight 5/60 ≈ 8.33 %**

---

## 1. The production problem

A Linux host in production is not a single trust boundary — it is a stack of them, and each one fails independently:

```
┌─────────────────────────────────────────────────────────────────┐
│ Application / workload                                          │
├─────────────────────────────────────────────────────────────────┤
│ Service sandbox      systemd unit directives, seccomp, caps     │  ← 332.1
├─────────────────────────────────────────────────────────────────┤
│ MAC layer            SELinux / AppArmor                         │  ← 333.2
├─────────────────────────────────────────────────────────────────┤
│ DAC layer            uid/gid, ACLs, file capabilities, SUID     │  ← 333.1
├─────────────────────────────────────────────────────────────────┤
│ Kernel               sysctl, ASLR/NX, lockdown, module policy   │  ← 332.1
├─────────────────────────────────────────────────────────────────┤
│ Firmware / boot      UEFI Secure Boot, GRUB 2 password, TPM     │  ← 332.1
├─────────────────────────────────────────────────────────────────┤
│ Physical             USB ports, DMA, chassis, console           │  ← 332.1
└─────────────────────────────────────────────────────────────────┘
```

Host hardening is the discipline of making each of those layers cost the attacker something, on the assumption that the layer above it has *already* failed. That assumption is not pessimism, it is arithmetic: a fleet of 500 nodes running 40 packages each is running 20 000 pieces of third-party code, and the probability that all of them are free of remote code execution over a five-year window is zero.

### 1.1 The three failure modes hardening actually addresses

| Failure mode | What the attacker already has | What hardening must deny |
|---|---|---|
| **Post-exploitation escalation** | Code execution as an unprivileged service account (`www-data`, `nobody`, a container uid) | Kernel exploit primitives, SUID paths, writable `/etc`, `ptrace` of other users, `kexec`, module loading |
| **Lateral movement / persistence** | A valid low-privilege shell | Readable credential material, unnecessary listening services, unrestricted egress, cron/systemd persistence points |
| **Physical / evil-maid** | Console or hands-on access for a few minutes | Single-user boot, kernel cmdline editing, USB HID injection, DMA, unencrypted disk |

### 1.2 Why "harden the host" is the wrong unit of work

The single most common architectural mistake is treating hardening as an *event* (a checklist run once during provisioning) rather than a *property* (a continuously asserted state). Three consequences:

1. **Drift is invisible without a baseline.** A `sysctl` written to `/etc/sysctl.d/99-hardening.conf` in 2024 and silently shadowed in 2026 by a Kubernetes CNI dropping `/etc/sysctl.d/99-zzz-calico.conf` produces a host that *passes the audit at provisioning time* and is wrong forever after. Load order matters and is lexicographic — see §7.2.
2. **Hardening that is not reversible is an outage generator.** `kernel.modules_disabled=1`, `kernel.kexec_load_disabled=1` and `kernel.unprivileged_bpf_disabled=1` are one-way switches until reboot. USBGuard with a bad policy locks you out of your own keyboard. A GRUB password on a host with no out-of-band console makes the box unrecoverable after a failed kernel upgrade.
3. **Unmeasured hardening is theatre.** `systemd-analyze security`, `checksec`, `oscap` and `/sys/devices/system/cpu/vulnerabilities/` all emit machine-readable state. If your hardening is not asserted by a test that runs in CI and on the live fleet, you do not know its status.

The design rule for the rest of this material: **every control gets a mechanism, a trade-off, a verification command, and a documented failure mode.**

---

## 2. The boot chain: firmware, Secure Boot, GRUB 2

### 2.1 Threat mechanics

An attacker at the physical console with an unprotected GRUB 2 menu needs no exploit and no password:

```
# At the GRUB menu, press 'e', append to the linux line:
linux /vmlinuz-6.1.0-18-amd64 root=/dev/mapper/vg0-root ro init=/bin/bash
# Ctrl-X
```

The kernel boots, `PID 1` is `/bin/bash` running as `uid 0` with no PAM, no authentication, no audit. `mount -o remount,rw /` and the host is theirs. Variants: `systemd.unit=rescue.target`, `rd.break` (dracut, drops to a shell in the initramfs *before* the root filesystem pivot), `single`, `1`.

This is why the GRUB password is not a "nice to have" for anything in a colocation cage, a branch office, a lab rack, or a laptop.

**What a GRUB password does and does not buy you:**

| Control | Stops cmdline editing | Stops booting other media | Stops offline disk read | Stops firmware-level implant |
|---|---|---|---|---|
| GRUB 2 superuser password | ✅ | ❌ | ❌ | ❌ |
| UEFI/BIOS admin password + boot-order lock | ✅ (indirectly) | ✅ | ❌ | ❌ |
| UEFI Secure Boot + signed kernel + `module.sig_enforce=1` | partial (unsigned kernels rejected) | ✅ for unsigned loaders | ❌ | partial |
| LUKS full-disk encryption (Topic 331.3) | ❌ | ❌ | ✅ | ❌ |
| TPM 2.0 measured boot + PCR-sealed LUKS key | ❌ | ❌ | ✅ | ✅ (detects) |

The layers are **not** substitutes for one another. A GRUB password on an unencrypted disk buys you about ninety seconds of attacker time — they boot a USB live image instead. The complete physical baseline is: firmware password → boot order restricted to internal disk → Secure Boot enforcing → GRUB superuser password → LUKS with TPM sealing.

### 2.2 Generating the password hash

GRUB 2 stores a PBKDF2-SHA512 hash, never a cleartext password.

```console
$ grub-mkpasswd-pbkdf2 --iteration-count=210000 --salt=32
Enter password:
Reenter password:
PBKDF2 hash of your password is grub.pbkdf2.sha512.210000.C1E5C0A9F3E0A4D6B7C8391A2B4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F.9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B
```

On RHEL/Fedora the binary is `grub2-mkpasswd-pbkdf2`. The default iteration count is 10000, which is low by 2026 standards for an offline-crackable hash; raise it. The hash string is safe to store in configuration management — it is not a secret in the way a private key is, but treat it as one anyway (§2.6).

### 2.3 Debian / Ubuntu implementation

GRUB config is generated; **never edit `/boot/grub/grub.cfg` directly** — it is overwritten by the next kernel package upgrade.

`/etc/grub.d/40_custom`:

```bash
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.

set superusers="grubadmin"
password_pbkdf2 grubadmin grub.pbkdf2.sha512.210000.C1E5C0A9F3E0A4D6B7C8391A2B4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F.9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B
```

By default, declaring `superusers` locks **every** menu entry — the machine will not boot unattended. That is almost never what you want on a server. Allow the normal entries to boot without a password while still requiring one to *edit* them, by adding `--unrestricted` to the generated menu entries:

`/etc/default/grub`:

```bash
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off lockdown=integrity module.sig_enforce=1 mitigations=auto"

# Do not offer a recovery (single-user) entry at all.
GRUB_DISABLE_RECOVERY="true"

# Boot the default entries without a password; still require one to edit them.
GRUB_DISABLE_SUBMENU=y
```

Debian's `/etc/grub.d/10_linux` builds the entry class from `$CLASS`. The supported way to add `--unrestricted` without patching the distro script is a small custom generator that runs *before* it:

`/etc/grub.d/09_unrestricted`:

```bash
#!/bin/sh
# Mark generated Linux menu entries as --unrestricted so that a superuser
# password is required to EDIT an entry but not to BOOT the default one.
# Without this, `set superusers` makes every boot interactive.
cat <<'EOF'
# 09_unrestricted: applied by 10_linux via CLASS
EOF
```

In practice on Debian the pragmatic and widely used approach is a `sed` guard applied by configuration management to `/etc/grub.d/10_linux`:

```console
$ sudo sed -i 's/^CLASS="\(.*\)"$/CLASS="\1 --unrestricted"/' /etc/grub.d/10_linux
$ grep ^CLASS= /etc/grub.d/10_linux
CLASS="--class gnu-linux --class gnu --class os --unrestricted"
```

Regenerate and verify:

```console
$ sudo update-grub
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.1.0-18-amd64
Found initrd image: /boot/initrd.img-6.1.0-18-amd64
Found linux image: /boot/vmlinuz-6.1.0-17-amd64
Found initrd image: /boot/initrd.img-6.1.0-17-amd64
Warning: os-prober will not be executed to detect other bootable partitions.
done

$ sudo grep -nE 'superusers|password_pbkdf2|--unrestricted' /boot/grub/grub.cfg | head
188:set superusers="grubadmin"
189:password_pbkdf2 grubadmin grub.pbkdf2.sha512.210000.C1E5C0A9...
201:menuentry 'Debian GNU/Linux' --class debian --class gnu-linux --class gnu --class os --unrestricted $menuentry_id_option 'gnulinux-simple-...' {
```

### 2.4 RHEL / Fedora / Rocky implementation

RHEL 8+ ships a purpose-built helper. It writes the hash to `/boot/grub2/user.cfg`, which is sourced by `/etc/grub.d/01_users`; `superusers` is set to `root`.

```console
$ sudo grub2-setpassword
Enter password:
Confirm password:

$ sudo cat /boot/grub2/user.cfg
GRUB2_PASSWORD=grub.pbkdf2.sha512.10000.9F1B2C3D...E7A8B9C0

$ sudo ls -l /boot/grub2/user.cfg
-rw-------. 1 root root 199 Aug 24 09:12 /boot/grub2/user.cfg
```

RHEL 9 uses BootLoader Spec (BLS) entries under `/boot/loader/entries/`, so kernel cmdline changes go through `grubby`, not by editing a generated `grub.cfg`:

```console
$ sudo grubby --update-kernel=ALL --args="slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none debugfs=off lockdown=integrity"

$ sudo grubby --info=DEFAULT
index=0
kernel="/boot/vmlinuz-5.14.0-427.13.1.el9_4.x86_64"
args="ro crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M rd.lvm.lv=rl/root rd.lvm.lv=rl/swap slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none debugfs=off lockdown=integrity"
root="/dev/mapper/rl-root"
initrd="/boot/initramfs-5.14.0-427.13.1.el9_4.x86_64.img"
title="Rocky Linux (5.14.0-427.13.1.el9_4.x86_64) 9.4 (Blue Onyx)"
id="a1b2c3d4e5f60718293a4b5c6d7e8f90-5.14.0-427.13.1.el9_4.x86_64"
```

Also update `/etc/default/grub`'s `GRUB_CMDLINE_LINUX` so *future* kernels inherit the arguments, then `grub2-mkconfig -o /boot/grub2/grub.cfg`.

### 2.5 Kernel command-line hardening parameters

| Parameter | Effect | Cost / risk |
|---|---|---|
| `slab_nomerge` | Disables SLAB/SLUB cache merging; kills a large class of heap-grooming cross-cache exploits | ~1–3 % more slab memory |
| `init_on_alloc=1 init_on_free=1` | Zeroes heap pages on alloc and free; neutralises most use-after-free info leaks | 1–5 % CPU on allocation-heavy workloads |
| `page_alloc.shuffle=1` | Randomises free-list order in the page allocator | Negligible; slight cache-locality loss |
| `randomize_kstack_offset=on` | Per-syscall randomisation of the kernel stack offset | <1 % |
| `vsyscall=none` | Removes the legacy fixed-address `vsyscall` page (a classic ROP anchor) | Breaks pre-2013 static binaries only |
| `debugfs=off` | `debugfs` not mounted/populated | Breaks some tracing and GPU debug tooling |
| `lockdown=integrity` | Blocks `/dev/mem`, unsigned modules, `kexec` of unsigned images, raw MSR/PCI writes | Breaks DKMS with unsigned modules, `perf` on some paths, some hypervisor tooling |
| `module.sig_enforce=1` | Refuses unsigned kernel modules | Hard-breaks out-of-tree modules you have not signed |
| `mitigations=auto,nosmt` | Enables all CPU-vulnerability mitigations and disables SMT | 15–40 % throughput loss; see §8 |
| `pti=on` | Force page-table isolation on regardless of CPU reporting | 5–30 % syscall-heavy workloads |

`lockdown=integrity` and `module.sig_enforce=1` are the two that most often cause a post-reboot outage. Stage them: roll them into a canary group first, confirm every module in `lsmod` is signed (`modinfo <mod> | grep -i sig`), and only then fleet-wide.

### 2.6 Verification and failure diagnosis — boot chain

```console
$ sudo stat -c '%a %U:%G %n' /boot/grub/grub.cfg /etc/grub.d/40_custom
600 root:root /boot/grub/grub.cfg
700 root:root /etc/grub.d/40_custom

$ mokutil --sb-state
SecureBoot enabled

$ sudo cat /sys/kernel/security/lockdown
none [integrity] confidentiality

$ sudo dmesg | grep -i 'kernel supported'
[    0.000000] Kernel is locked down from command line; see man kernel_lockdown.7
```

**Emergency-mode check that almost everyone misses.** systemd's `emergency.service` and `rescue.service` run `sulogin`, which asks for the root password. If the root account is locked (`!` in `/etc/shadow`, the Debian/Ubuntu cloud-image default) *and* the unit sets `SYSTEMD_SULOGIN_FORCE=1`, systemd hands out an **unauthenticated root shell**. Check before you assume your GRUB password matters:

```console
$ systemctl cat emergency.service | grep -iE 'sulogin|Environment'
Environment=HOME=/root
ExecStart=-/usr/lib/systemd/systemd-sulogin-shell emergency

$ sudo passwd -S root
root L 2026-01-14 0 99999 7 -1
```

`L` means locked. Either set a strong root password (stored in your secret manager) or mask the emergency path and rely on out-of-band console recovery. Document which one you chose — a host with a GRUB password, a locked root, and no iDRAC/iLO is a host you cannot fix at 03:00.

| Symptom | Likely cause | Diagnostic |
|---|---|---|
| Boot hangs at a `grubadmin` username prompt | `superusers` set without `--unrestricted` on entries | Boot rescue media, `grep -c -- --unrestricted /boot/grub/grub.cfg` |
| GRUB password stops working after kernel upgrade | Edited `grub.cfg` directly instead of `/etc/grub.d/` | `grep superusers /etc/grub.d/*` — must be there, not only in `grub.cfg` |
| `error: file '/boot/grub/i386-pc/normal.mod' not found` | `grub-install` never re-run after disk change | `grub-install /dev/sda && update-grub` from rescue |
| Signed kernel refuses to boot | Secure Boot on, shim/MOK mismatch | `mokutil --list-enrolled`, `dmesg \| grep -i 'Lockdown\|secure boot'` |
| Unsigned DKMS module fails after `module.sig_enforce=1` | Module not enrolled with a MOK key | `modinfo <mod> \| grep sig`, `mokutil --import` |

---

## 3. Reducing the service surface

Every listening socket is an unauthenticated entry point until proven otherwise. Every enabled unit is code that runs as root at boot.

### 3.1 Inventory first

```console
$ systemctl list-units --type=service --state=running --no-pager
  UNIT                        LOAD   ACTIVE SUB     DESCRIPTION
  auditd.service              loaded active running Security Auditing Service
  chronyd.service             loaded active running NTP client/server
  cups.service                loaded active running CUPS Scheduler
  dbus-broker.service         loaded active running D-Bus System Message Bus
  nginx.service               loaded active running The nginx HTTP and reverse proxy server
  rpcbind.service             loaded active running RPC Bind
  sshd.service                loaded active running OpenSSH server daemon
  systemd-journald.service    loaded active running Journal Service
  systemd-logind.service      loaded active running User Login Management
  systemd-udevd.service       loaded active running Rule-based Manager for Device Events and Files

10 loaded units listed.
```

Cross-reference with what is actually reachable:

```console
$ sudo ss -tulpen
Netid  State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process
udp    UNCONN  0       0              0.0.0.0:111          0.0.0.0:*      users:(("rpcbind",pid=712,fd=5))  uid:0 ino:20114 sk:1
udp    UNCONN  0       0            127.0.0.1:323          0.0.0.0:*      users:(("chronyd",pid=901,fd:5))  uid:993 ino:21455 sk:2
udp    UNCONN  0       0              0.0.0.0:631          0.0.0.0:*      users:(("cups-browsed",pid=944,fd=7)) uid:0 ino:21990 sk:3
tcp    LISTEN  0       4096           0.0.0.0:111          0.0.0.0:*      users:(("rpcbind",pid=712,fd=4))  uid:0 ino:20110 sk:4
tcp    LISTEN  0       511            0.0.0.0:80           0.0.0.0:*      users:(("nginx",pid=1204,fd=6))   uid:0 ino:23881 sk:5
tcp    LISTEN  0       128            0.0.0.0:22           0.0.0.0:*      users:(("sshd",pid=1010,fd=3))    uid:0 ino:22503 sk:6
tcp    LISTEN  0       128          127.0.0.1:631          0.0.0.0:*      users:(("cupsd",pid=943,fd=8))    uid:0 ino:21988 sk:7
```

`rpcbind` on `0.0.0.0:111` and `cups-browsed` on `0.0.0.0:631` on a web server are pure liability: neither is used, both have CVE history, both are reachable from the network.

### 3.2 stop vs disable vs mask vs purge

| Action | Stops now | Survives reboot | Survives `systemctl start` by another unit/admin | Survives package reinstall | Removes the code from disk |
|---|---|---|---|---|---|
| `systemctl stop foo` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `systemctl disable foo` | ❌ | ✅ | ❌ | ⚠️ (preset may re-enable) | ❌ |
| `systemctl disable --now foo` | ✅ | ✅ | ❌ | ⚠️ | ❌ |
| `systemctl mask foo` | ❌ | ✅ | ✅ (`Unit is masked`) | ✅ | ❌ |
| `systemctl mask --now foo` | ✅ | ✅ | ✅ | ✅ | ❌ |
| `apt purge` / `dnf remove` | ✅ | ✅ | ✅ | n/a | ✅ |

Two traps:

- **Socket activation.** `systemctl disable cups.service` does nothing if `cups.socket` is enabled — the first connection starts the service. Disable the socket *and* the path/timer units: `systemctl disable --now cups.socket cups.path cups.service`.
- **Presets.** `/usr/lib/systemd/system-preset/*.preset` re-enables services on package reinstall. `mask` is the only state a package upgrade cannot silently undo.

```console
$ sudo systemctl mask --now cups.service cups.socket cups.path cups-browsed.service
Created symlink /etc/systemd/system/cups.service → /dev/null.
Created symlink /etc/systemd/system/cups.socket → /dev/null.
Created symlink /etc/systemd/system/cups.path → /dev/null.
Created symlink /etc/systemd/system/cups-browsed.service → /dev/null.

$ sudo systemctl start cups.service
Failed to start cups.service: Unit cups.service is masked.
```

Removal is still better than masking where the workload permits it — masked code is code that a future admin can unmask, and code whose CVEs still show up in your scanner:

```console
$ sudo apt purge -y cups cups-daemon cups-browsed rpcbind nfs-common
Reading package lists... Done
Building dependency tree... Done
The following packages will be REMOVED:
  cups* cups-browsed* cups-client* cups-common* cups-core-drivers* cups-daemon*
  cups-filters* cups-ppdc* cups-server-common* nfs-common* rpcbind*
0 upgraded, 0 newly installed, 11 to remove and 0 not upgraded.
After this operation, 27.4 MB disk space will be freed.
```

### 3.3 Boot-time surface

```console
$ systemd-analyze blame --no-pager | head -12
7.412s NetworkManager-wait-online.service
2.208s dracut-initqueue.service
1.884s systemd-udev-settle.service
 812ms lvm2-monitor.service
 640ms sssd.service
 401ms auditd.service
 388ms systemd-journal-flush.service
 233ms nginx.service
 190ms chronyd.service
 118ms sshd.service

$ systemctl list-unit-files --state=enabled --no-pager | wc -l
47
```

Forty-seven enabled units on a single-purpose web node is the number to attack. Each one is evaluated against a single question: *if this binary had an unauthenticated RCE tomorrow, would this host be compromised?* If the answer is yes and the service is not required, it goes.

---

## 4. systemd service sandboxing

Service sandboxing is the highest-leverage control in this objective: it is per-service, requires no application changes, is fully declarative, and is *scored* by a tool shipped with the OS.

### 4.1 Measure the baseline

```console
$ systemd-analyze security nginx.service --no-pager
  NAME                                                        DESCRIPTION                                                             EXPOSURE
✗ PrivateNetwork=                                             Service has access to the host's network                                     0.5
✗ User=/DynamicUser=                                          Service runs as root, option does not apply                                  0.4
✗ CapabilityBoundingSet=~CAP_SYS_ADMIN                        Service has administrator privileges                                         0.3
✗ CapabilityBoundingSet=~CAP_SYS_PTRACE                       Service has ptrace() debugging abilities                                     0.3
✗ RestrictAddressFamilies=~AF_PACKET                          Service may allocate packet sockets                                          0.2
✗ SystemCallFilter=~@debug                                    Service does not filter system calls                                         0.2
✗ ProtectKernelTunables=                                      Service may alter kernel tunables                                            0.2
✗ ProtectKernelModules=                                       Service may load kernel modules                                              0.2
✗ ProtectSystem=                                              Service has full access to the OS file hierarchy                             0.2
✗ ProtectHome=                                                Service has full access to home directories                                  0.2
✗ NoNewPrivileges=                                            Service processes may acquire new privileges                                 0.2
✗ PrivateDevices=                                             Service potentially has access to hardware devices                           0.2
✗ RestrictNamespaces=~CLONE_NEWUSER                           Service may create user namespaces                                           0.3
✗ MemoryDenyWriteExecute=                                     Service may create writable executable memory mappings                       0.1

→ Overall exposure level for nginx.service: 9.6 UNSAFE 😨
```

The score is a heuristic, not a proof — but a movement from 9.6 to 1.5 is a movement from "root with the whole filesystem" to "an unprivileged process that can open two paths and one socket family."

### 4.2 The directive catalogue

| Directive | Mechanism | Denies | Common breakage |
|---|---|---|---|
| `NoNewPrivileges=yes` | `PR_SET_NO_NEW_PRIVS` | SUID/`setcap` escalation from inside the service | Services that legitimately call `sudo`/`su` (e.g. some backup agents) |
| `User=` / `DynamicUser=yes` | uid/gid switch, transient uid | Running as root at all | Needs `AmbientCapabilities` for ports <1024; `DynamicUser` needs `StateDirectory=` |
| `CapabilityBoundingSet=` | Capability bounding set | Everything not listed, permanently | Dropping `CAP_NET_BIND_SERVICE` on a :80 listener |
| `AmbientCapabilities=` | Ambient set | — (grants) | Requires the cap to also be in the bounding set |
| `ProtectSystem=strict` | Read-only bind mount of the whole hierarchy | Writes anywhere except `/dev`, `/proc`, `/sys` and `ReadWritePaths=` | Any daemon that writes logs/state outside declared paths |
| `ProtectHome=yes` | `/home`, `/root`, `/run/user` empty | Reading user data / SSH keys | Services legitimately serving `~/public_html` |
| `PrivateTmp=yes` | Private mount ns for `/tmp`, `/var/tmp` | `/tmp` symlink races, cross-service tmp snooping | Two units expecting a *shared* `/tmp` socket |
| `PrivateDevices=yes` | Private `/dev` with only pseudo-devices | Raw disk, `/dev/mem`, `/dev/kmem`, hardware | Anything touching real hardware (backup agents, GPU) |
| `PrivateUsers=yes` | User namespace, host root unmapped | Host-uid privilege even on escape | Needs `user.max_user_namespaces>0` (see §7.3) |
| `ProtectKernelTunables=yes` | `/proc/sys`, `/sys` read-only | `sysctl` writes from the service | Services that tune the network stack at start |
| `ProtectKernelModules=yes` | Blocks `init_module`/`finit_module`, `delete_module` | Rootkit loading | Nothing legitimate on a server |
| `ProtectKernelLogs=yes` | Blocks `syslog(2)`, `/dev/kmsg` | Reading kernel pointers/leaks | Log shippers reading `/dev/kmsg` |
| `ProtectControlGroups=yes` | `/sys/fs/cgroup` read-only | cgroup-release-agent escape | Container runtimes, cgroup managers |
| `ProtectProc=invisible` + `ProcSubset=pid` | procfs `hidepid`/`subset` | Enumerating other users' processes and most of `/proc/*` | Monitoring agents (`node_exporter`, `top`-style tooling) |
| `RestrictNamespaces=yes` | Blocks `unshare`/`clone` namespace flags | User-ns based kernel LPE chains | Container runtimes, rootless Podman |
| `RestrictSUIDSGID=yes` | Blocks setting S_ISUID/S_ISGID | Dropping a SUID backdoor | Package managers, `mkfs`-style tooling |
| `RestrictRealtime=yes` | Blocks `SCHED_FIFO`/`SCHED_RR` | Realtime-priority DoS | Audio, low-latency trading, some DBs |
| `RestrictAddressFamilies=` | seccomp on `socket(2)` | `AF_PACKET`, `AF_NETLINK`, `AF_BLUETOOTH`, … | `AF_NETLINK` is needed more often than expected (glibc NSS, `getifaddrs`) |
| `LockPersonality=yes` | Blocks `personality(2)` | ASLR-disabling / legacy-ABI exploit tricks | 32-bit compat shims |
| `MemoryDenyWriteExecute=yes` | seccomp on `mmap`/`mprotect` W\|X | Injecting shellcode into an existing process | **Breaks every JIT**: JVM, V8/Node, LuaJIT, PyPy, .NET |
| `SystemCallFilter=@system-service` | seccomp-bpf allowlist | ~60 % of the syscall table, incl. `@mount`, `@reboot`, `@swap`, `@module` | Anything using a syscall outside the set |
| `SystemCallArchitectures=native` | seccomp arch filter | 32-bit syscall entry on x86_64 (a historic bypass class) | 32-bit binaries |
| `SystemCallErrorNumber=EPERM` | seccomp action | — (turns kill into `EPERM`) | Makes debugging far easier than `SIGSYS` |
| `IPAddressDeny=any` + `IPAddressAllow=` | eBPF cgroup socket filter | Egress to C2 / lateral movement | Silent connection failures; DNS needs its resolvers allowed |
| `DevicePolicy=closed` + `DeviceAllow=` | cgroup device controller | All device nodes except listed | Anything with a real device |
| `UMask=0077` | Process umask | World-readable files created by the service | Multi-user drop directories |

### 4.3 A complete hardened drop-in

Never edit the vendor unit; use a drop-in so package upgrades keep working.

```console
$ sudo systemctl edit nginx.service
```

`/etc/systemd/system/nginx.service.d/10-hardening.conf`:

```ini
# Hardening drop-in for nginx.service
# Baseline: systemd-analyze security nginx.service  ->  1.4 OK
#
# Rationale for every relaxation is inline. Do not remove a comment when
# removing a directive: the next engineer needs to know why it was safe.

[Service]
# ---- Identity and privilege --------------------------------------------
User=nginx
Group=nginx
NoNewPrivileges=yes
# nginx binds :80 and :443. CAP_NET_BIND_SERVICE must be in BOTH the
# bounding set and the ambient set, otherwise the master process
# cannot bind and exits with "bind() to 0.0.0.0:80 failed (13: Permission denied)".
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# ---- Filesystem --------------------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectProc=invisible
ProcSubset=pid
UMask=0077

# Everything nginx must be able to write to, enumerated explicitly.
# /var/log/nginx  : access and error logs
# /var/lib/nginx  : proxy/fastcgi/client body temp paths
# /run            : nginx.pid and unix sockets
RuntimeDirectory=nginx
RuntimeDirectoryMode=0750
LogsDirectory=nginx
LogsDirectoryMode=0750
StateDirectory=nginx
StateDirectoryMode=0750
ReadWritePaths=/var/log/nginx /var/lib/nginx /run

# ---- Kernel interfaces -------------------------------------------------
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes

# ---- Namespaces and execution ------------------------------------------
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
# nginx has no JIT; safe. Would break a service embedding LuaJIT (OpenResty).
MemoryDenyWriteExecute=yes
RemoveIPC=yes

# ---- Syscalls ----------------------------------------------------------
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
# EPERM instead of SIGSYS: a denied syscall shows up as an errno in the
# service log rather than a bare "killed by signal 31".
SystemCallErrorNumber=EPERM

# ---- Network -----------------------------------------------------------
# AF_UNIX is required for the master<->worker channel and for syslog.
# AF_NETLINK is required by glibc's getifaddrs()/NSS on some builds.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

# Egress allowlist: loopback, the upstream app tier, and the resolvers.
# Comment this block out and re-test if upstreams start timing out.
IPAddressDeny=any
IPAddressAllow=localhost
IPAddressAllow=10.42.0.0/16
IPAddressAllow=10.10.0.53/32
IPAddressAllow=10.10.1.53/32

# ---- Resource ceilings (see also 332.3) --------------------------------
LimitNOFILE=65535
LimitNPROC=512
LimitCORE=0
TasksMax=1024
MemoryMax=2G
```

Apply and re-measure:

```console
$ sudo systemctl daemon-reload
$ sudo systemctl restart nginx.service
$ systemd-analyze security nginx.service --no-pager | tail -3
✗ RestrictAddressFamilies=~AF_NETLINK                         Service may allocate netlink sockets                                         0.1

→ Overall exposure level for nginx.service: 1.4 OK 🙂
```

### 4.4 Testing a sandbox before you ship it

`systemd-run` applies the same directives to an ad-hoc unit, so you can bisect a broken sandbox without touching the real service:

```console
$ sudo systemd-run --pty --same-dir --wait --collect \
    -p ProtectSystem=strict -p PrivateDevices=yes -p SystemCallFilter=@system-service \
    /usr/sbin/nginx -t
Running as unit: run-u512.service; invocation ID: 4f2b...
Press ^] three times within 1s to disconnect TTY.
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

### 4.5 Diagnosing a sandbox failure

The signature of a seccomp kill is `SIGSYS` (signal 31) or, with `SystemCallErrorNumber=EPERM`, an unexplained `Operation not permitted`.

```console
$ sudo systemctl status nginx.service --no-pager -l
× nginx.service - The nginx HTTP and reverse proxy server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)
    Drop-In: /etc/systemd/system/nginx.service.d
             └─10-hardening.conf
     Active: failed (Result: signal) since Mon 2026-08-24 11:04:17 UTC; 3s ago
    Process: 4471 ExecStart=/usr/sbin/nginx (code=killed, signal=SYS)

Aug 24 11:04:17 web01 systemd[1]: nginx.service: Main process exited, code=killed, status=31/SYS
```

Resolve the exact syscall from the audit log:

```console
$ sudo ausearch -m SECCOMP -ts recent -i | tail -4
type=SECCOMP msg=audit(2026-08-24 11:04:17.882:2291) : auid=unset uid=nginx gid=nginx ses=unset subj=system_u:system_r:httpd_t:s0 pid=4471 comm=nginx exe=/usr/sbin/nginx sig=SIGSYS arch=x86_64 syscall=io_uring_setup compat=0 ip=0x7f2c1d0a3b4d code=kill_process

$ ausyscall x86_64 425
io_uring_setup
```

`io_uring_setup` is not in `@system-service` (it is in `@io-uring`, excluded by default since systemd 250 for good reason). Either drop the nginx `io_uring` build flag or, if you accept the risk, add `SystemCallFilter=@io-uring` explicitly and record why.

Other high-frequency sandbox failures:

| Log line | Cause | Fix |
|---|---|---|
| `Read-only file system` on a path not in `ReadWritePaths=` | `ProtectSystem=strict` | Add the path, or use `StateDirectory=`/`LogsDirectory=` |
| `bind(): Permission denied` on port <1024 | Cap in bounding set but not ambient | Add `AmbientCapabilities=CAP_NET_BIND_SERVICE` |
| `getaddrinfo: Temporary failure in name resolution` | `AF_NETLINK` blocked or `IPAddressDeny=any` without resolvers | Allow `AF_NETLINK`; add resolver IPs to `IPAddressAllow=` |
| JVM/Node aborts at startup with `mprotect failed` | `MemoryDenyWriteExecute=yes` | Remove it for JIT workloads; there is no partial version |
| `node_exporter` reports zero processes | `ProtectProc=invisible` / `ProcSubset=pid` | Do not set these on monitoring agents |
| Service works, then fails hours later | `IPAddressDeny=any` blocking a rarely used upstream | `journalctl -u <svc> \| grep -i 'connect'`, widen the allowlist |

---

## 5. Userspace exploit mitigations: ASLR, NX/DEP, PIE

### 5.1 What each mitigation actually stops

| Mitigation | Layer | Attack class defeated | Bypassed by |
|---|---|---|---|
| **NX / DEP** (`XD` bit, page `NX` flag) | CPU + kernel page tables | Executing injected shellcode from stack/heap | ROP / JOP / ret2libc |
| **ASLR** | Kernel VM layout | Hardcoded gadget and libc addresses | Info leaks, low entropy on 32-bit, non-PIE binaries, brute force on forking servers |
| **PIE** (`-fPIE -pie`) | ELF type `ET_DYN` | Fixed load address of the *main executable* — without PIE, ASLR does not randomise the binary's own `.text` | Info leak of the binary base |
| **Stack canary** (`-fstack-protector-strong`) | Compiler | Linear stack buffer overflow overwriting the saved return address | Non-linear/indexed writes, canary leak, overwriting a pointer before the canary |
| **RELRO** (`-Wl,-z,relro,-z,now`) | Linker | GOT overwrite → arbitrary code | Non-GOT function-pointer overwrite |
| **FORTIFY_SOURCE** (`-D_FORTIFY_SOURCE=2/3`) | Compiler + glibc | `memcpy`/`sprintf`/`strcpy` overflows with compile- or run-time-known sizes | Sizes not statically or dynamically derivable |
| **CET / IBT + Shadow Stack** (`-fcf-protection=full`) | CPU (Intel Tiger Lake+) | ROP (shadow stack), JOP (indirect-branch tracking) | Data-only attacks |
| **BTI + PAC** (`-mbranch-protection=standard`) | CPU (ARMv8.3+/8.5+) | ROP/JOP on aarch64 | Signing-gadget abuse |

### 5.2 ASLR: mechanics and control

`/proc/sys/kernel/randomize_va_space`:

| Value | Randomised | Notes |
|---|---|---|
| `0` | Nothing | ASLR fully disabled. Only for debugging; never in production. |
| `1` | Stack, `mmap` base, VDSO, shared libraries | "Conservative" — heap (`brk`) still adjacent to the executable |
| `2` | The above **plus** `brk`/heap | Default on every modern distro. This is the required value. |

```console
$ cat /proc/sys/kernel/randomize_va_space
2

$ for i in 1 2 3; do grep -m1 '\[stack\]' /proc/self/maps; done
7ffd1a3c9000-7ffd1a3ea000 rw-p 00000000 00:00 0                          [stack]
7ffc884e5000-7ffc88506000 rw-p 00000000 00:00 0                          [stack]
7ffe4b71c000-7ffe4b73d000 rw-p 00000000 00:00 0                          [stack]
```

Three different stack bases across three executions — ASLR is live. Now the crucial detail: **any unprivileged user can disable ASLR for their own process** via the `ADDR_NO_RANDOMIZE` personality:

```console
$ setarch $(uname -m) -R /bin/sh -c 'grep -m1 "\[stack\]" /proc/self/maps'
7ffffffde000-7ffffffff000 rw-p 00000000 00:00 0                          [stack]
$ setarch $(uname -m) -R /bin/sh -c 'grep -m1 "\[stack\]" /proc/self/maps'
7ffffffde000-7ffffffff000 rw-p 00000000 00:00 0                          [stack]
```

Identical addresses. This is *by design* (`personality(2)` is not privileged) and it is exactly why `LockPersonality=yes` exists in the systemd sandbox: it stops an attacker who has code execution inside a service from turning off ASLR before launching a second-stage exploit.

Entropy is tunable:

```console
$ sysctl vm.mmap_rnd_bits vm.mmap_rnd_compat_bits
vm.mmap_rnd_bits = 28
vm.mmap_rnd_compat_bits = 8

$ sudo sysctl -w vm.mmap_rnd_bits=32
vm.mmap_rnd_bits = 32
```

28 bits is the x86_64 default; 32 is the maximum and costs nothing but a slightly larger address space fragmentation. The `compat` (32-bit) value of 8 bits is trivially brute-forceable — one more argument for having no 32-bit binaries on the host, enforced by `SystemCallArchitectures=native`.

### 5.3 NX / DEP

```console
$ grep -o ' nx ' /proc/cpuinfo | head -1
 nx

$ dmesg | grep -i 'NX (Execute Disable)'
[    0.000000] NX (Execute Disable) protection: active
```

NX is enforced per page. Verify a real process has a non-executable stack and heap:

```console
$ grep -E '\[stack\]|\[heap\]' /proc/$(pgrep -n nginx)/maps
55d3a8f00000-55d3a8f21000 rw-p 00000000 00:00 0                          [heap]
7ffd3b6e1000-7ffd3b702000 rw-p 00000000 00:00 0                          [stack]
```

`rw-p` — read, write, **no `x`**. If you ever see `rwxp` in a production process map, either the binary was linked with `-z execstack` or the process is a JIT. Find them:

```console
$ sudo awk '/rwxp/ {print FILENAME": "$0}' /proc/*/maps 2>/dev/null | head
$ 
```

Empty output is the correct answer. Check the ELF flag directly:

```console
$ readelf -lW /usr/sbin/nginx | grep -A1 GNU_STACK
  GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x10
```

`RW` (not `RWE`) means a non-executable stack was requested at link time.

### 5.4 Auditing compiler hardening across the fleet

```console
$ checksec --file=/usr/sbin/sshd
RELRO           STACK CANARY      NX            PIE             RPATH      RUNPATH      Symbols         FORTIFY Fortified  Fortifiable  FILE
Full RELRO      Canary found      NX enabled    PIE enabled     No RPATH   No RUNPATH   No Symbols        Yes     9         25           /usr/sbin/sshd

$ checksec --file=/opt/vendor/bin/agentd
RELRO           STACK CANARY      NX            PIE             RPATH      RUNPATH      Symbols         FORTIFY Fortified  Fortifiable  FILE
Partial RELRO   No canary found   NX enabled    No PIE          No RPATH   RUNPATH      82 Symbols        No      0         14           /opt/vendor/bin/agentd
```

The second line is what a vendor-supplied binary usually looks like, and it is the finding that matters: no PIE means ASLR does not randomise its `.text`, no canary means every stack overflow is directly exploitable, partial RELRO means the GOT is writable, and a `RUNPATH` means library hijacking is on the table. That binary belongs in a tight systemd sandbox or off the host.

Sweep the whole system:

```console
$ checksec --dir=/usr/bin --output=csv 2>/dev/null | awk -F, '$4=="No PIE"' | head -5
/usr/bin/legacytool,Partial RELRO,No canary found,No PIE,No RPATH,No RUNPATH,54 Symbols,No,0,3

$ hardening-check /usr/sbin/nginx
/usr/sbin/nginx:
 Position Independent Executable: yes
 Stack protected: yes
 Fortify Source functions: yes (some protected functions found)
 Read-only relocations: yes
 Immediate binding: yes
 Stack clash protection: yes
 Control flow integrity: yes
```

For code you build yourself, the production flag set:

```makefile
# Distribution-grade hardening flags (glibc >= 2.35, GCC >= 12)
CFLAGS  += -O2 -fstack-protector-strong -fstack-clash-protection \
           -D_FORTIFY_SOURCE=3 -fPIE -fcf-protection=full \
           -Wformat -Wformat-security -Werror=format-security
LDFLAGS += -pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code
```

`-D_FORTIFY_SOURCE=3` (GCC 12+/glibc 2.35+) extends fortification to dynamically sized objects via `__builtin_dynamic_object_size`; it is strictly better than `=2` and costs ~1 % code size. `-fstack-clash-protection` closes the stack-guard-page jump class that `-fstack-protector` does not.

---

## 6. Filesystem and privilege surface

### 6.1 SUID/SGID inventory

Every SUID-root binary is a candidate local privilege escalation. Enumerate and *justify each one*:

```console
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u:%g %p\n' 2>/dev/null | sort -k3
-rwsr-xr-x root:root /usr/bin/chfn
-rwsr-xr-x root:root /usr/bin/chsh
-rwsr-xr-x root:root /usr/bin/gpasswd
-rwsr-xr-x root:root /usr/bin/mount
-rwsr-xr-x root:root /usr/bin/newgrp
-rwsr-xr-x root:root /usr/bin/passwd
-rwsr-xr-x root:root /usr/bin/su
-rwsr-xr-x root:root /usr/bin/sudo
-rwsr-xr-x root:root /usr/bin/umount
-rwxr-sr-x root:shadow /usr/bin/expiry
-rwxr-sr-x root:tty   /usr/bin/wall
-rwxr-sr-x root:crontab /usr/bin/crontab
-rwsr-xr-- root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper
-rwsr-xr-x root:root /usr/lib/openssh/ssh-keysign
```

On an unattended server, `chfn`, `chsh`, `newgrp`, `wall` and `ssh-keysign` are typically all removable:

```console
$ sudo chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp
$ sudo chmod g-s /usr/bin/wall
$ sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chsh
```

`dpkg-statoverride` (Debian) is essential — a plain `chmod` is reverted by the next package upgrade. RHEL's equivalent is to record the change in your configuration management and re-assert it, since RPM restores modes on `dnf reinstall`.

### 6.2 File capabilities — the SUID you forget to look for

```console
$ sudo getcap -r / 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/mtr-packet cap_net_raw=ep
/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper cap_net_bind_service,cap_net_admin=ep
/usr/bin/systemd-detect-virt cap_dac_override,cap_sys_ptrace=ep
```

A `cap_dac_override` or `cap_sys_admin` file capability anywhere outside a package-managed path is a red flag: it is a persistence mechanism that no SUID scan finds.

```console
$ sudo setcap -r /usr/bin/mtr-packet
$ sudo getcap /usr/bin/mtr-packet
$
```

### 6.3 Mount options

```
# /etc/fstab — hardened mount options
# <device>                  <mount>     <fs>   <options>                                   <dump> <pass>
UUID=1a2b3c4d-...           /           ext4   defaults                                    0 1
UUID=5e6f7a8b-...           /boot       ext4   defaults,nodev,nosuid,noexec                0 2
UUID=9c0d1e2f-...           /boot/efi   vfat   umask=0077,shortname=winnt,nodev,nosuid,noexec 0 2
UUID=3a4b5c6d-...           /home       ext4   defaults,nodev,nosuid                       0 2
UUID=7e8f9a0b-...           /var        ext4   defaults,nodev                              0 2
UUID=1c2d3e4f-...           /var/log    ext4   defaults,nodev,nosuid,noexec                0 2
UUID=5a6b7c8d-...           /var/log/audit ext4 defaults,nodev,nosuid,noexec               0 2
UUID=9e0f1a2b-...           /var/tmp    ext4   defaults,nodev,nosuid,noexec                0 2
tmpfs                       /tmp        tmpfs  defaults,rw,nosuid,nodev,noexec,mode=1777,size=2G 0 0
tmpfs                       /dev/shm    tmpfs  defaults,rw,nosuid,nodev,noexec,mode=1777   0 0
proc                        /proc       proc   defaults,hidepid=invisible,gid=4            0 0
```

| Option | Blocks | Common breakage |
|---|---|---|
| `nosuid` | SUID/SGID bits honoured on that fs | User-writable SUID sandboxes; nothing on `/tmp`, `/var`, `/home` normally |
| `nodev` | Device nodes interpreted | Container storage backends that create devices under `/var/lib` |
| `noexec` | `execve` of files on that fs | **Package post-install scripts extracting to `/tmp`**, DKMS builds, Ansible's `remote_tmp`, some Java installers, `pip` builds |
| `hidepid=invisible,gid=4` (`proc`) | Non-root users seeing other users' `/proc/<pid>` | Monitoring agents (`node_exporter`, `zabbix-agent`) — add their uid to the `gid=` group |

`noexec` on `/tmp` is the single most commonly reverted hardening measure because it breaks `apt`/`dnf` post-install scripts. The correct fix is not to remove it but to redirect the tooling:

```console
$ sudo tee /etc/apt/apt.conf.d/50noexec-tmp >/dev/null <<'EOF'
DPkg::Pre-Invoke  {"mount -o remount,exec /tmp";};
DPkg::Post-Invoke {"mount -o remount,noexec /tmp";};
EOF
```

and for Ansible, set `remote_tmp = /var/lib/ansible/tmp` in `ansible.cfg` on a filesystem that permits exec.

`hidepid` verification:

```console
$ sudo mount -o remount,hidepid=invisible,gid=4 /proc
$ ps -u nginx -o pid,comm            # as root: visible
    PID COMMAND
   1204 nginx
   1205 nginx

$ sudo -u nobody ps -ef | wc -l      # as an unprivileged user: only own processes
      4
```

Note that `hidepid=2` is the legacy spelling; kernels 5.8+ accept `hidepid=invisible` and add `hidepid=ptraceable`. systemd's `ProtectProc=invisible` gives the same effect per-service without a global remount, and is the preferable tool when you only need it for one daemon.

### 6.4 Kernel module policy

```console
$ cat /etc/modprobe.d/99-hardening.conf
# Filesystems no server here mounts. `install ... /bin/true` prevents
# autoloading even when a mount(8) call would trigger it, which a plain
# `blacklist` does not.
install cramfs      /bin/true
install freevxfs    /bin/true
install jffs2       /bin/true
install hfs         /bin/true
install hfsplus     /bin/true
install squashfs    /bin/true
install udf         /bin/true

# Legacy / rarely used network protocols with a poor CVE record.
install dccp        /bin/true
install sctp        /bin/true
install rds         /bin/true
install tipc        /bin/true

# Wireless and Bluetooth on a datacentre node.
install bluetooth   /bin/true
install btusb       /bin/true

# Firewire and Thunderbolt: DMA attack surface.
install firewire-core /bin/true
install firewire-ohci /bin/true
install thunderbolt   /bin/true

# USB mass storage. Keep HID working (see USBGuard, section 9) but deny
# data exfiltration via a plugged-in disk.
install usb-storage /bin/true
install uas         /bin/true
```

`blacklist foo` only prevents *alias-based* autoload; a direct `modprobe foo` still works. `install foo /bin/true` defeats both. Neither survives an attacker with `CAP_SYS_MODULE` and a direct `finit_module(2)` — for that you need module signature enforcement or the one-way switch:

```console
$ sudo sysctl -w kernel.modules_disabled=1
kernel.modules_disabled = 1

$ sudo modprobe dummy
modprobe: ERROR: could not insert 'dummy': Operation not permitted

$ sudo sysctl -w kernel.modules_disabled=0
sysctl: setting key "kernel.modules_disabled": Operation not permitted
```

**One-way until reboot.** Set it at the *end* of boot, after every needed module is loaded — a `systemd` unit ordered `After=multi-user.target` with a delay, or the last task of your provisioning run. Setting it in `/etc/sysctl.d/` alone is fine because `systemd-sysctl` runs early, before most modules load, and will break networking, storage or the audit subsystem on the next boot.

---

## 7. Kernel tunables: sysctl

### 7.1 Mechanics

`sysctl` is a thin wrapper over `/proc/sys`. Every knob is a file:

```console
$ sysctl kernel.kptr_restrict
kernel.kptr_restrict = 1

$ cat /proc/sys/kernel/kptr_restrict
1

$ echo 2 | sudo tee /proc/sys/kernel/kptr_restrict
2
```

Runtime writes do not persist. Persistence is via drop-in files, applied at boot by `systemd-sysctl.service`.

### 7.2 Load order — the drift trap

`sysctl --system` reads, in this order, with **later files overriding earlier ones**, and within the whole set files are merged by *basename* in lexicographic order (a file in a higher-priority directory shadows a same-named file in a lower one):

```
/etc/sysctl.d/*.conf      ← highest precedence directory for same basename
/run/sysctl.d/*.conf
/usr/local/lib/sysctl.d/*.conf
/usr/lib/sysctl.d/*.conf
/lib/sysctl.d/*.conf
/etc/sysctl.conf          ← applied last of all (legacy, wins on conflict)
```

```console
$ sudo sysctl --system
* Applying /usr/lib/sysctl.d/10-default-yama-scope.conf ...
* Applying /usr/lib/sysctl.d/50-coredump.conf ...
* Applying /usr/lib/sysctl.d/50-default.conf ...
* Applying /usr/lib/sysctl.d/50-pid-max.conf ...
* Applying /etc/sysctl.d/99-hardening.conf ...
* Applying /etc/sysctl.d/99-zzz-calico.conf ...
* Applying /etc/sysctl.conf ...
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.rp_filter = 0
...
```

Note `net.ipv4.conf.all.rp_filter = 0` in the final output despite the hardening file setting `1`: `99-zzz-calico.conf` sorts *after* `99-hardening.conf` and wins. This is the exact drift scenario from §1.2. **Always assert effective runtime values, never file contents.**

### 7.3 The hardening drop-in, annotated

`/etc/sysctl.d/99-hardening.conf`:

```ini
# ============================================================================
#  Host hardening baseline — kernel and network tunables
#  Applied by systemd-sysctl.service at boot; assert with scripts/verify-sysctl.
#  Every entry carries a breakage note. Do not copy blindly onto a node whose
#  role is not documented here (this file targets: bare application servers).
# ============================================================================

# ---------------------------------------------------------------------------
#  Kernel information leaks
# ---------------------------------------------------------------------------
# Hide kernel pointers from /proc and other interfaces (%pK format specifier).
# 1 = hidden from unprivileged, 2 = hidden from everyone including root reads.
# Breakage: some profiling tools (perf, systemtap) and crash analysis need 0/1.
kernel.kptr_restrict = 2

# Only root may read the kernel ring buffer. Blocks leaking of KASLR offsets
# and driver addresses via dmesg after a crash.
# Breakage: unprivileged log shippers reading dmesg; use journald instead.
kernel.dmesg_restrict = 1

# Restrict perf_event_open(2). 2 = no kernel or raw tracepoint access for
# unprivileged users. 3 (Debian/Ubuntu patch only) = deny entirely.
# Breakage: unprivileged profiling; CI perf tests. Set 2 if you profile.
kernel.perf_event_paranoid = 3
kernel.perf_event_max_sample_rate = 1

# ---------------------------------------------------------------------------
#  Process isolation
# ---------------------------------------------------------------------------
# Yama ptrace scope. 1 = only a direct parent may ptrace a child (blocks
# credential scraping across processes of the same uid), 2 = admin only,
# 3 = nobody, ever (not reversible without reboot).
# Breakage: gdb attaching to a running PID, strace -p, some APM agents.
kernel.yama.ptrace_scope = 1

# Full ASLR including the heap. Never lower this.
kernel.randomize_va_space = 2

# Maximum mmap entropy on 64-bit.
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16

# Refuse mapping below 64 KiB. Defeats the whole NULL-pointer-dereference
# kernel exploit class that maps a payload at address 0.
vm.mmap_min_addr = 65536

# ---------------------------------------------------------------------------
#  Privileged interfaces
# ---------------------------------------------------------------------------
# Disable kexec_load(2): stops loading a replacement kernel at runtime, a
# clean rootkit persistence path that survives a "reboot".
# ONE-WAY until the next boot. Breakage: kdump crash-dump capture.
kernel.kexec_load_disabled = 1

# Deny eBPF to unprivileged users; harden the JIT against spray attacks.
# 1 = disabled and locked; 2 = disabled but still changeable.
# Breakage: unprivileged seccomp-bpf is unaffected; rootless BPF tooling is not.
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Magic SysRq: 0 disables entirely; 4 permits keyboard control only;
# 176 (128+32+16) permits reboot/remount-ro/sync for emergency recovery.
# Breakage: 0 removes your ability to do an emergency sync+remount+reboot
# from the console during a hung host. Choose deliberately.
kernel.sysrq = 0

# User namespaces: the single largest source of unprivileged kernel LPEs.
# 0 disables them completely.
# Breakage: rootless Podman/Docker, Flatpak, Chrome's sandbox, bubblewrap,
# `unshare -r`. Set 0 ONLY on nodes that run no rootless containers.
user.max_user_namespaces = 0

# ---------------------------------------------------------------------------
#  Core dumps and SUID
# ---------------------------------------------------------------------------
# Never dump core from a SUID/privileged process — dumps contain secrets.
fs.suid_dumpable = 0
kernel.core_pattern = |/bin/false

# ---------------------------------------------------------------------------
#  Filesystem race protections
# ---------------------------------------------------------------------------
# Block the classic /tmp symlink and hardlink attacks in sticky world-writable
# directories, plus FIFO and regular-file variants.
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# ---------------------------------------------------------------------------
#  TTY
# ---------------------------------------------------------------------------
# Stop autoloading line disciplines (a repeated LPE source: n_hdlc, slip...).
dev.tty.ldisc_autoload = 0

# ---------------------------------------------------------------------------
#  Network stack — IPv4
# ---------------------------------------------------------------------------
# This host does not route. Set to 1 ONLY on Kubernetes nodes, NAT gateways
# and routers — and if you do, revisit rp_filter and accept_redirects below.
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0

# Reverse-path filtering: 1 = strict (RFC 3704), 2 = loose.
# Strict breaks asymmetric routing and multi-homed hosts; use 2 there.
# NOTE: the effective value is max(conf.all, conf.<iface>), not the interface
# value alone — see the "all vs default vs iface" table below.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Never accept ICMP redirects: they rewrite the routing table from the wire.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Source routing lets the sender pick the return path — reject it.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log packets with impossible source addresses (early signal for spoofing).
# Breakage: log volume on a noisy segment; rate-limited by icmp_ratelimit.
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# SYN flood mitigation. Costs TCP options (window scaling, SACK) only for
# connections established while the backlog is full.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2

# Do not participate in smurf amplification.
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Ignore gratuitous ARP; require the target IP to be on the receiving iface.
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2

# TIME-WAIT assassination protection.
net.ipv4.tcp_rfc1337 = 1

# ---------------------------------------------------------------------------
#  Network stack — IPv6
# ---------------------------------------------------------------------------
# Router advertisements are unauthenticated: an attacker on-link can become
# your default gateway. Disable RA on a statically addressed server.
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.forwarding = 0

# If IPv6 is genuinely unused, disable it here AND remove any AAAA records —
# a half-disabled IPv6 stack is worse than an enabled, filtered one because
# your firewall rules stop being evaluated for a live protocol.
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
```

### 7.4 `all` vs `default` vs `<iface>` — the semantics nobody documents in their runbook

This is the highest-value piece of `sysctl` knowledge for both the exam and production:

| Key | How `all` and `<iface>` combine | Consequence |
|---|---|---|
| `rp_filter` | **max(all, iface)** | Setting `all.rp_filter=1` forces strict RPF on every interface even where the per-interface value is `0`. Kubernetes CNIs that need `0` set it on `all` for that reason. |
| `accept_redirects` | **AND(all, iface)** | Setting `all=0` is sufficient to disable everywhere. |
| `log_martians`, `arp_filter`, `proxy_arp`, `forwarding` | **OR(all, iface)** | Setting `all=1` enables everywhere; you cannot exempt one interface by setting it to `0`. |
| `default.*` | **Template, applied at interface creation only** | Changing `default.*` does **not** affect existing interfaces. |

The practical consequence: **interfaces created after `systemd-sysctl` runs do not inherit hardening you only wrote to `all.*`.** Every `veth`, `docker0`, `cni0`, `tun0`, `wg0` and VLAN sub-interface created later gets the `default.*` values. This is why the file above sets *both* `all.*` and `default.*` for every network key, and why the verification step (§7.5) enumerates real interfaces rather than trusting `all`.

### 7.5 Verification and diagnosis

```console
$ sudo sysctl --system >/dev/null && echo applied
applied

$ sysctl -a --pattern 'kernel.(kptr|dmesg|yama|randomize|modules|kexec|sysrq)' 2>/dev/null
kernel.dmesg_restrict = 1
kernel.kexec_load_disabled = 1
kernel.kptr_restrict = 2
kernel.modules_disabled = 0
kernel.randomize_va_space = 2
kernel.sysrq = 0
kernel.yama.ptrace_scope = 1
```

Per-interface assertion — the check that catches the `veth` blind spot:

```console
$ for i in $(ls /proc/sys/net/ipv4/conf/); do
>   printf '%-12s rp_filter=%s accept_redirects=%s send_redirects=%s\n' "$i" \
>     "$(cat /proc/sys/net/ipv4/conf/$i/rp_filter)" \
>     "$(cat /proc/sys/net/ipv4/conf/$i/accept_redirects)" \
>     "$(cat /proc/sys/net/ipv4/conf/$i/send_redirects)"
> done
all          rp_filter=1 accept_redirects=0 send_redirects=0
default      rp_filter=1 accept_redirects=0 send_redirects=0
eth0         rp_filter=1 accept_redirects=0 send_redirects=0
lo           rp_filter=1 accept_redirects=0 send_redirects=0
docker0      rp_filter=1 accept_redirects=0 send_redirects=1
veth3f2a1c   rp_filter=1 accept_redirects=0 send_redirects=1
```

`docker0` and the `veth` were created after boot and carry `send_redirects=1`. Either fix the container runtime's sysctl drop-in or add a udev/networkd hook. A hard-fail assertion script:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-sysctl — assert effective runtime values, exit 1 on drift.
set -euo pipefail

declare -A EXPECTED=(
  [kernel.kptr_restrict]=2
  [kernel.dmesg_restrict]=1
  [kernel.yama.ptrace_scope]=1
  [kernel.randomize_va_space]=2
  [kernel.kexec_load_disabled]=1
  [kernel.unprivileged_bpf_disabled]=1
  [fs.protected_hardlinks]=1
  [fs.protected_symlinks]=1
  [fs.suid_dumpable]=0
  [net.ipv4.tcp_syncookies]=1
  [net.ipv4.conf.all.accept_source_route]=0
)

rc=0
for key in "${!EXPECTED[@]}"; do
  want="${EXPECTED[$key]}"
  got="$(sysctl -n "$key" 2>/dev/null || echo MISSING)"
  if [[ "$got" != "$want" ]]; then
    printf 'DRIFT  %-42s want=%-6s got=%s\n' "$key" "$want" "$got"
    rc=1
  fi
done

# Per-interface keys must hold on EVERY interface, not just conf.all.
for iface_path in /proc/sys/net/ipv4/conf/*; do
  iface="$(basename "$iface_path")"
  for key in accept_redirects accept_source_route send_redirects; do
    got="$(cat "$iface_path/$key")"
    if [[ "$got" != "0" ]]; then
      printf 'DRIFT  net.ipv4.conf.%s.%s want=0 got=%s\n' "$iface" "$key" "$got"
      rc=1
    fi
  done
done

[[ $rc -eq 0 ]] && echo "OK: sysctl baseline holds"
exit $rc
```

```console
$ sudo /usr/local/sbin/verify-sysctl
DRIFT  net.ipv4.conf.docker0.send_redirects want=0 got=1
DRIFT  net.ipv4.conf.veth3f2a1c.send_redirects want=0 got=1
$ echo $?
1
```

| Symptom | Cause | Diagnostic |
|---|---|---|
| Setting reverts after reboot | Higher-precedence drop-in overrides it | `sudo sysctl --system 2>&1 \| grep Applying`, then `grep -r '<key>' /etc/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf` |
| `sysctl: cannot stat /proc/sys/...: No such file` | Module providing the knob is not loaded (e.g. `net.netfilter.*` needs `nf_conntrack`) | `modprobe nf_conntrack`, or move the setting to a `modprobe`-ordered unit |
| Rootless Podman: `cannot clone: Operation not permitted` | `user.max_user_namespaces = 0` | `sysctl user.max_user_namespaces` — raise it or move the workload |
| `kdump` no longer captures | `kernel.kexec_load_disabled = 1` | Choose: crash dumps or kexec hardening. You cannot have both. |
| Pods lose network on a k8s node | `net.ipv4.ip_forward = 0` or `all.rp_filter = 1` | `sysctl net.ipv4.ip_forward`; k8s nodes need forwarding and usually loose RPF |
| `gdb -p <pid>` fails with `ptrace: Operation not permitted` | `kernel.yama.ptrace_scope >= 1` | Temporarily `sysctl -w kernel.yama.ptrace_scope=0`, restore after |
| Asymmetric routing drops traffic | `rp_filter=1` (strict) | `sysctl -w net.ipv4.conf.all.rp_filter=2` (loose) and watch `log_martians` |

---

## 8. CPU hardware vulnerabilities and their mitigations

Speculative-execution flaws are unique in this objective: the mitigation lives in microcode and the kernel, the cost is measured in double-digit percentages of throughput, and the correct setting depends entirely on the trust model of the workload.

### 8.1 Reading the current state

```console
$ grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null
/sys/devices/system/cpu/vulnerabilities/gather_data_sampling:Not affected
/sys/devices/system/cpu/vulnerabilities/itlb_multihit:KVM: Mitigation: VMX disabled
/sys/devices/system/cpu/vulnerabilities/l1tf:Mitigation: PTE Inversion; VMX: conditional cache flushes, SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/mds:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/meltdown:Mitigation: PTI
/sys/devices/system/cpu/vulnerabilities/mmio_stale_data:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/reg_file_data_sampling:Not affected
/sys/devices/system/cpu/vulnerabilities/retbleed:Mitigation: IBRS
/sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow:Not affected
/sys/devices/system/cpu/vulnerabilities/spec_store_bypass:Mitigation: Speculative Store Bypass disabled via prctl
/sys/devices/system/cpu/vulnerabilities/spectre_v1:Mitigation: usercopy/swapgs barriers and __user pointer sanitization
/sys/devices/system/cpu/vulnerabilities/spectre_v2:Mitigation: IBRS, IBPB: conditional, STIBP: conditional, RSB filling, PBRSB-eIBRS: Not affected
/sys/devices/system/cpu/vulnerabilities/srbds:Not affected
/sys/devices/system/cpu/vulnerabilities/tsx_async_abort:Not affected
```

The three words that matter in that output are **`SMT vulnerable`**. They appear on `l1tf`, `mds` and `mmio_stale_data` and mean: the mitigation is active, but a sibling hyperthread can still read data from the other thread's buffers. On a single-tenant host that is acceptable. On a multi-tenant hypervisor or a shared CI runner it is not.

```console
$ lscpu | sed -n '/Vulnerabilit/,$p'
Vulnerabilities:
  Gather data sampling:   Not affected
  Itlb multihit:          KVM: Mitigation: VMX disabled
  L1tf:                   Mitigation; PTE Inversion; VMX: conditional cache flushes, SMT vulnerable
  Mds:                    Mitigation; Clear CPU buffers; SMT vulnerable
  Meltdown:               Mitigation; PTI
  Spectre v1:             Mitigation; usercopy/swapgs barriers and __user pointer sanitization
  Spectre v2:             Mitigation; IBRS, IBPB: conditional, STIBP: conditional, RSB filling
```

### 8.2 Trade-off matrix

| Vulnerability | Boundary crossed | Mitigation | Typical cost | Cmdline control |
|---|---|---|---|---|
| Meltdown (CVE-2017-5754) | User → kernel memory | KPTI (page-table isolation) | 5–30 % on syscall-heavy workloads | `pti=on\|off\|auto` |
| Spectre v1 (CVE-2017-5753) | In-process bounds check | `array_index_nospec` barriers in kernel | <1 % | — (compiled in) |
| Spectre v2 (CVE-2017-5715) | Cross-process/VM branch predictor | retpoline / eIBRS / IBPB / STIBP | 3–15 % | `spectre_v2=`, `spectre_v2_user=` |
| L1TF (Foreshadow) | Guest → host L1 cache | PTE inversion + L1D flush on VM entry | High on virt; near-zero bare metal | `l1tf=flush\|full\|off` |
| MDS / TAA / MMIO stale data | Cross-thread CPU buffers | `VERW` buffer clear on transitions | 2–10 % | `mds=`, `tsx_async_abort=`, `mmio_stale_data=` |
| Retbleed | Return-stack across privilege | IBRS / call depth tracking | 10–30 % on AMD Zen1/2, Intel pre-Ice Lake | `retbleed=auto\|ibpb\|off` |
| SRSO (Inception) | AMD return-stack | Safe-RET / IBPB | 5–25 % | `spec_rstack_overflow=` |

### 8.3 The decision, not the default

```console
# Multi-tenant: shared hypervisor, shared CI runners, untrusted code
GRUB_CMDLINE_LINUX="... mitigations=auto,nosmt"

# Single-tenant, dedicated, no untrusted local code, network-isolated
GRUB_CMDLINE_LINUX="... mitigations=auto"

# HPC / batch on an air-gapped fabric where you have accepted the risk
# IN WRITING and the node runs exactly one trusted workload:
GRUB_CMDLINE_LINUX="... mitigations=off"
```

`nosmt` halves your logical core count. That is a capacity decision with a budget attached, and it belongs to the architecture review, not to a hardening script. What is *not* negotiable is that the decision is explicit and recorded — `mitigations=off` inherited from a copied kernel cmdline in a Packer template is how a fleet ends up silently vulnerable.

```console
$ sudo grubby --update-kernel=ALL --args="mitigations=auto,nosmt"
$ sudo reboot
...
$ cat /sys/devices/system/cpu/vulnerabilities/mds
Mitigation: Clear CPU buffers; SMT disabled
$ lscpu | grep -E 'Thread|^CPU\(s\)'
CPU(s):                  32
Thread(s) per core:      1
```

`SMT vulnerable` became `SMT disabled`, and 64 logical CPUs became 32. Both facts are now true and both are visible.

Microcode is a prerequisite for several of these — a kernel mitigation with stale microcode silently degrades:

```console
$ sudo dnf install -y microcode_ctl        # RHEL family
$ sudo apt install -y intel-microcode amd64-microcode   # Debian family
$ journalctl -k | grep -i microcode
Aug 24 09:41:02 web01 kernel: microcode: updated early: 0x2b000603 -> 0x2b000620, date = 2026-02-18
```

---

## 9. USBGuard: controlling the physical bus

### 9.1 Threat mechanics

A USB device declares its own class. A device that looks like a phone charger can enumerate as a HID keyboard (`03:01:01`) and type. Attack payload: plug in, wait two seconds, inject `Ctrl-Alt-F2`, `curl … | sh`. No exploit, no CVE, no password. Variants: mass storage for exfiltration, an Ethernet gadget (`02:06:00`) that becomes a higher-priority default gateway and steals DHCP, and — on Thunderbolt — direct DMA to physical memory.

USBGuard implements a **device allowlist enforced at enumeration**, before the kernel binds a driver.

### 9.2 Architecture

```
 USB device inserted
        │
        ▼
 kernel USB core enumerates → descriptors read
        │
        ▼  uevent (netlink)
 usbguard-daemon  ── evaluates rules.conf top-to-bottom, first match wins
        │                    │
        │ allow              │ block / reject
        ▼                    ▼
 echo 1 > /sys/bus/usb/    echo 0 > .../authorized
 devices/<dev>/authorized  (reject = also detach)
        │
        ▼
 driver binds, device usable
```

The kernel primitive is `/sys/bus/usb/devices/*/authorized` and `/sys/bus/usb/devices/usbN/authorized_default`. USBGuard is a policy engine on top of it; the enforcement is in the kernel and holds even if the daemon is killed (already-decided devices keep their state).

**Rule targets:** `allow` (authorize), `block` (do not authorize now — reconnect re-evaluates), `reject` (authorize denied *and* logically remove the device).

### 9.3 Complete configuration

`/etc/usbguard/usbguard-daemon.conf`:

```ini
# ============================================================================
#  usbguard-daemon.conf — USB device authorization policy engine
#  DANGER: a wrong policy here locks you out of your own keyboard.
#  Always generate the initial policy WITH the keyboard attached (see below),
#  and always keep a second access path (SSH, IPMI SoL) open during rollout.
# ============================================================================

# Primary rule file, written by `usbguard generate-policy > ...`.
RuleFile=/etc/usbguard/rules.conf

# Additional rule fragments, merged in lexicographic order BEFORE RuleFile.
# Use this for config-management-owned fragments so the machine-local
# rules.conf stays editable by hand.
RuleFolder=/etc/usbguard/rules.d/

# What to do with a device matching no rule at all. `block` is the whole point
# of running USBGuard; `allow` turns it into an audit-only deployment, which is
# the correct FIRST stage of a rollout.
ImplicitPolicyTarget=block

# Devices already connected when the daemon starts.
#   keep          - leave the current authorization state untouched
#   apply-policy  - evaluate them against the rules like any other device
#   block/reject  - deny regardless of policy
# `apply-policy` is correct steady state; use `keep` during the first rollout
# so a bad policy cannot detach the console keyboard on daemon restart.
PresentDevicePolicy=apply-policy

# USB controllers (hubs/root hubs) present at daemon start. `keep` avoids
# tearing down the entire bus if a controller is not in the policy.
PresentControllerPolicy=keep

# Devices inserted while the daemon is running.
InsertedDevicePolicy=apply-policy

# On daemon shutdown, restore the pre-USBGuard authorization state.
# false = devices stay as the policy left them (fail closed). Keep false.
RestoreControllerDeviceState=false

# Device enumeration backend. `uevent` is the netlink-based default;
# `umockdev` exists for testing only.
DeviceManagerBackend=uevent

# --- IPC access control -----------------------------------------------------
# Who may talk to the daemon over its Unix socket. An unrestricted IPC socket
# is equivalent to giving away the policy: any listed user can `allow-device`.
IPCAllowedUsers=root
IPCAllowedGroups=wheel
IPCAccessControlFiles=/etc/usbguard/IPCAccessControl.d/

# --- Policy generation behaviour -------------------------------------------
# Include the physical port (via-port) in generated rules. false is usually
# right: with true, moving a keyboard to another port blocks it.
DeviceRulesWithPort=false

# --- Audit ------------------------------------------------------------------
# LinuxAudit sends events to auditd (integrates with 332.2); FileAudit writes
# a dedicated log. LinuxAudit is preferred where auditd is already deployed.
AuditBackend=LinuxAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log

# Redact serial numbers and hashes from logs on shared/regulated systems.
HidePII=false
```

Generate the initial policy from the currently attached, known-good hardware:

```console
$ sudo usbguard generate-policy -X -t reject > /etc/usbguard/rules.conf
$ sudo chmod 0600 /etc/usbguard/rules.conf
$ sudo cat /etc/usbguard/rules.conf
allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "jEP/6WzviqdJ5VSeTUY8PatCNBKeaREvo2OqdplND/o=" parent-hash "" with-interface 09:00:00 with-connect-type ""
allow id 1d6b:0003 serial "0000:00:14.0" name "xHCI Host Controller" hash "kL8/2XzvKqdN9VSeTUY8PatCNBKeaREvo2OqdplND/x=" parent-hash "" with-interface 09:00:00 with-connect-type ""
allow id 8087:0026 serial "" name "" hash "9Mv3nT7pQrS2uV4wX6yZ8aB0cD1eF2gH3iJ4kL5mN6o=" parent-hash "jEP/6WzviqdJ5VSeTUY8PatCNBKeaREvo2OqdplND/o=" with-interface { e0:01:01 e0:01:01 } with-connect-type "hardwired"
allow id 413c:2113 serial "" name "Dell KB216 Wired Keyboard" hash "7Qw9eR2tY5uI8oP1aS4dF7gH0jK3lZ6xC9vB2nM5qW8=" parent-hash "jEP/6WzviqdJ5VSeTUY8PatCNBKeaREvo2OqdplND/o=" with-interface { 03:01:01 03:00:00 } with-connect-type "hotplug"

# Deny everything that did not match above. `reject` also detaches.
reject
```

The `-t reject` flag appends the explicit catch-all; `-X` omits the hash from... (use `usbguard generate-policy --help` on your build to confirm flag semantics — the important part is that the last line is a deliberate catch-all and that the rules are hash-pinned, so cloning a VID:PID is not enough to be allowed).

A hand-written policy fragment for a class-based rule:

`/etc/usbguard/rules.d/10-classes.conf`:

```
# Allow only hubs, HID keyboards and the internal Bluetooth radio.
# Explicitly reject mass storage and network gadgets regardless of vendor.

# Hubs (class 09) are needed for the bus to work at all.
allow with-interface equals { 09:00:* }

# HID keyboards (03:01:01) but NOT composite devices that ALSO expose
# storage or network — `equals` is an exact multiset match on the interface
# list, which is what defeats a BadUSB composite descriptor.
allow with-interface equals { 03:01:01 03:00:00 }

# Reject mass storage (08:*), network (02:*), and vendor-specific serial
# adapters (ff:*) outright, with a message in the audit log.
reject with-interface one-of { 08:*:* }
reject with-interface one-of { 02:*:* }
reject with-interface one-of { ff:*:* }
```

The distinction between `equals`, `one-of`, `none-of` and `all-of` is where the security actually lives. `allow with-interface one-of { 03:01:01 }` would allow a device that presents a keyboard **and** a mass-storage interface — precisely the BadUSB shape. `equals` requires the interface set to match exactly.

### 9.4 Rollout without locking yourself out

```console
# Stage 1: audit only. ImplicitPolicyTarget=allow, watch what appears.
$ sudo sed -i 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=allow/' /etc/usbguard/usbguard-daemon.conf
$ sudo systemctl enable --now usbguard.service
$ sudo usbguard watch
[device] present: id=1 target=allow device_rule='allow id 1d6b:0002 ...'
[device] inserted: id=7 target=allow device_rule='allow id 0781:5583 serial "4C530001..." name "Ultra Fit" hash "..." with-interface { 08:06:50 }'

# Stage 2: flip to block, keep present devices untouched.
$ sudo sed -i 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=block/' /etc/usbguard/usbguard-daemon.conf
$ sudo sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=keep/' /etc/usbguard/usbguard-daemon.conf
$ sudo systemctl restart usbguard.service

# Stage 3, only after a successful reboot test with the console keyboard:
$ sudo sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=apply-policy/' /etc/usbguard/usbguard-daemon.conf
$ sudo systemctl restart usbguard.service
```

Runtime operation:

```console
$ sudo usbguard list-devices
1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "jEP/6Wzviq..." parent-hash "" via-port "usb1" with-interface 09:00:00 with-connect-type ""
4: allow id 413c:2113 serial "" name "Dell KB216 Wired Keyboard" hash "7Qw9eR2tY5..." parent-hash "jEP/6Wzviq..." via-port "1-3" with-interface { 03:01:01 03:00:00 } with-connect-type "hotplug"
7: block id 0781:5583 serial "4C530001280621119131" name "Ultra Fit" hash "aB3cD4eF5g..." parent-hash "jEP/6Wzviq..." via-port "1-4" with-interface { 08:06:50 } with-connect-type "hotplug"

$ sudo usbguard list-devices --blocked
7: block id 0781:5583 serial "4C530001280621119131" name "Ultra Fit" hash "aB3cD4eF5g..." ...

# Temporary, non-persistent authorization for a known device:
$ sudo usbguard allow-device 7

# Permanent, appended to rules.conf:
$ sudo usbguard allow-device 7 -p

$ sudo usbguard list-rules
1: allow id 1d6b:0002 serial "0000:00:14.0" ...
4: allow id 413c:2113 serial "" name "Dell KB216 Wired Keyboard" ...
5: allow id 0781:5583 serial "4C530001280621119131" name "Ultra Fit" hash "aB3cD4eF5g..."
6: reject
```

### 9.5 The kernel-only alternatives

| Control | Granularity | Survives daemon death | Complexity | When to use |
|---|---|---|---|---|
| USBGuard | Per-device, hash-pinned, interface-class aware | Yes (state is in sysfs) | High | Workstations, jump hosts, anything with a keyboard and a threat model |
| `authorized_default=0` on root hubs | All-or-nothing per controller | Yes | Low | Headless servers with zero USB requirement |
| `install usb-storage /bin/true` | Blocks the storage driver only | Yes | Trivial | Cheap partial win; does nothing against HID injection |
| `nousb` / unbind `xhci_hcd` | Entire bus dead | Yes | Trivial | Bare-metal servers with IPMI/serial console and no USB console |
| BIOS "disable USB ports" | Per-port or global, pre-OS | Yes | Trivial | Best when you truly need none — but blocks recovery media too |

```console
# The blunt instrument, for a headless server with no USB requirement:
$ for hub in /sys/bus/usb/devices/usb*; do echo 0 | sudo tee $hub/authorized_default; done
0
0
$ cat /sys/bus/usb/devices/usb1/authorized_default
0
```

### 9.6 Verification and diagnosis

```console
$ systemctl is-active usbguard
active

$ sudo ausearch -m USER_DEVICE -ts recent -i | tail -3
type=USER_DEVICE msg=audit(2026-08-24 12:18:44.201:3391) : pid=1187 uid=root auid=unset ses=unset msg='usbguard: type=Policy.DeviceRule device_rule="reject id 0781:5583 serial 4C530001280621119131 name Ultra Fit hash aB3cD4eF5g..." target=reject exe=/usr/sbin/usbguard-daemon res=success'

$ cat /sys/bus/usb/devices/1-4/authorized
0

$ journalctl -u usbguard -n 5 --no-pager
Aug 24 12:18:44 ws01 usbguard-daemon[1187]: Device inserted: id=7 ... target=reject
```

| Symptom | Cause | Recovery |
|---|---|---|
| Console keyboard dead after enabling USBGuard | Keyboard not in policy, or `PresentDevicePolicy=apply-policy` on first start | Boot with `systemd.mask=usbguard.service` from GRUB; or SSH in and `usbguard allow-device <id> -p` |
| Keyboard works on one port, not another | `DeviceRulesWithPort=true` pinned `via-port` | Set `DeviceRulesWithPort=false`, regenerate policy |
| `usbguard: IPC connection error` as a non-root user | User not in `IPCAllowedUsers`/`IPCAllowedGroups` | `usbguard add-user <user> --devices=listmodify --policy=list` |
| Policy lost after upgrade | `rules.conf` not under configuration management | Ship `rules.d/` fragments from CM; treat `rules.conf` as generated |
| Device allowed but still non-functional | Driver blacklisted in `modprobe.d` | `dmesg \| tail`, `lsmod \| grep usb_storage` |

**Always mask-escape hatch:** appending `systemd.mask=usbguard.service` at the GRUB prompt recovers a locked-out host — which is precisely why the GRUB password from §2 and the USBGuard policy protect *different* things and both are needed.

---

## 10. Polyinstantiated directories (`pam_namespace`)

### 10.1 The problem

`/tmp` is world-writable and shared. Consequences on a multi-user host: symlink and hardlink races against privileged processes, predictable-filename attacks, and plain snooping — user A can list user B's temporary files and often read them. `fs.protected_symlinks` (§7.3) closes the race class; it does not close the *visibility* class.

**Polyinstantiation** gives each user (or each SELinux level/context) a private `/tmp`, mounted into their session's own mount namespace at login time. Two users both see `/tmp`; they are two different directories.

### 10.2 Configuration

`/etc/security/namespace.conf`:

```
# ============================================================================
#  pam_namespace configuration — polyinstantiated directories
#
#  Format:
#    <polydir>  <instance_prefix>  <method>  <uid_exclusion_list>  [flags]
#
#  method:
#    user    - one instance per user (instance dir suffixed with the username)
#    level   - one instance per SELinux MLS level (falls back to user without
#              SELinux MLS)
#    context - one instance per SELinux context
#    both    - per context AND per user
#    tmpfs   - a fresh empty tmpfs per session (no persistence between logins)
#    tmpdir  - a fresh empty directory per session, removed on logout
#
#  uid_exclusion_list: comma-separated users who are NOT polyinstantiated.
#  Always exclude root and your admin/monitoring accounts, otherwise a broken
#  instance directory locks administrators out of a working /tmp.
# ============================================================================

# Per-user /tmp. Instances live under /tmp-inst, which must be mode 000 and
# owned by root so that no user can traverse into another user's instance.
/tmp        /tmp-inst/              level      root,adm,monitoring

# Per-user /var/tmp, same construction.
/var/tmp    /var/tmp/tmp-inst/      level      root,adm,monitoring

# Per-user home instance, for shared bastion/jump hosts where users must not
# see each other's home directories at all. Requires the parent to exist.
# $HOME    /home/inst/             user       root,adm
```

Create the instance parents with the exact permissions `pam_namespace` requires — it refuses to run if they are wrong:

```console
$ sudo mkdir -p /tmp-inst /var/tmp/tmp-inst
$ sudo chmod 000 /tmp-inst /var/tmp/tmp-inst
$ sudo chown root:root /tmp-inst /var/tmp/tmp-inst
$ ls -ld /tmp-inst
d---------. 2 root root 6 Aug 24 13:02 /tmp-inst
```

Enable the module in the PAM stacks that create sessions:

```console
$ grep -n pam_namespace /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/runuser-l
/etc/pam.d/sshd:9:session    required     pam_namespace.so
/etc/pam.d/login:12:session  required     pam_namespace.so
```

On RHEL family this is normally done by adding the line to `/etc/pam.d/postlogin` or by enabling it via `authselect`:

```console
$ sudo authselect enable-feature with-pam-namespace
$ sudo authselect apply-changes
```

Optional per-instance initialisation (copy skeleton files, set SELinux contexts) goes in `/etc/security/namespace.init`, which receives the polydir, the instance dir, a "new instance" flag and the username as arguments:

```bash
#!/bin/sh -p
# /etc/security/namespace.init — run once when a new instance dir is created.
# $1 polydir  $2 instance dir  $3 new (1) or existing (0)  $4 user
if [ "$3" = "1" ]; then
    # Restore the SELinux context the polydir would normally carry.
    [ -x /sbin/restorecon ] && /sbin/restorecon "$2"
fi
exit 0
```

### 10.3 Verification

```console
# Session 1, as alice:
alice@bastion:~$ echo secret-alice > /tmp/mydata
alice@bastion:~$ ls -l /tmp/
total 4
-rw-------. 1 alice alice 13 Aug 24 13:11 mydata

# Session 2, as bob, at the same time:
bob@bastion:~$ ls -l /tmp/
total 0
bob@bastion:~$ cat /tmp/mydata
cat: /tmp/mydata: No such file or directory

# As root, the shared /tmp is visible and both instances are on disk:
$ sudo ls -l /tmp-inst/
total 0
drwx------. 2 alice alice 60 Aug 24 13:11 tmp.inst-alice
drwx------. 2 bob   bob   40 Aug 24 13:12 tmp.inst-bob

$ sudo findmnt -T /tmp -o TARGET,SOURCE,FSTYPE,OPTIONS
TARGET SOURCE                                       FSTYPE OPTIONS
/tmp   /dev/mapper/vg0-root[/tmp-inst/tmp.inst-alice] xfs   rw,relatime,seclabel,attr2,inode64

$ sudo grep ' /tmp ' /proc/$(pgrep -u alice -n bash)/mountinfo
912 887 253:0 /tmp-inst/tmp.inst-alice /tmp rw,relatime shared:1 - xfs /dev/mapper/vg0-root rw,seclabel,attr2,inode64,logbufs=8
```

The `mountinfo` of alice's shell shows the bind source is the per-user instance — that is the proof, not the `ls` output.

### 10.4 `pam_namespace` vs `PrivateTmp=`

| | `pam_namespace` | systemd `PrivateTmp=yes` |
|---|---|---|
| Scope | Per login session (interactive users) | Per service unit |
| Granularity | Per user / SELinux level / context | Per unit |
| Persistence across sessions | Yes with `level`/`user`; no with `tmpfs`/`tmpdir` | No — destroyed with the unit |
| Applies to `cron`/`at` jobs | Only if the PAM stack includes it | n/a |
| Configuration surface | `namespace.conf` + PAM stacks + instance dirs | One directive |
| Failure mode | Broken instance dir → user cannot log in | Service cannot see host `/tmp` |

They are complementary, not alternatives: `PrivateTmp=` covers daemons, `pam_namespace` covers humans. On a bastion host you want both.

| Symptom | Cause | Diagnostic |
|---|---|---|
| Login fails right after enabling `pam_namespace` | Instance parent has wrong mode/owner | `ls -ld /tmp-inst` must be `d--------- root root`; check `journalctl -t sshd \| grep namespace` |
| Root's `/tmp` also became private | `root` missing from the exclusion list | Add `root` to column 4, re-login |
| X11/DBus session breaks | `/tmp/.X11-unix` is per-instance now | Exclude the display manager user, or use `tmpfs` method with an `iscript` that recreates the sockets |
| `scp`/`sftp` behaves differently from `ssh` | `pam_namespace` only in `/etc/pam.d/sshd`, not in the subsystem path | Verify with `findmnt` inside an `sftp` session's process |

---

## 11. The baseline as code

Hardening that exists only in a wiki page is not hardening. Below is the complete Ansible role that implements everything above, plus the verification suite.

`roles/host_hardening/defaults/main.yml`:

```yaml
---
# Host hardening role defaults.
# Every switch defaults to the SAFE value; a node opts in to the aggressive
# ones through group_vars, so a new node cannot be bricked by inheritance.

hardening_grub_enable_password: true
hardening_grub_superuser: grubadmin
# Generate with: grub-mkpasswd-pbkdf2 --iteration-count=210000 --salt=32
# Store in Ansible Vault; never in plain group_vars.
hardening_grub_password_pbkdf2: "{{ vault_grub_password_pbkdf2 }}"

hardening_kernel_cmdline_args:
  - slab_nomerge
  - init_on_alloc=1
  - init_on_free=1
  - page_alloc.shuffle=1
  - randomize_kstack_offset=on
  - vsyscall=none
  - debugfs=off

# Opt-in: these have caused outages. Enable per group after a canary.
hardening_kernel_lockdown: false          # lockdown=integrity
hardening_module_sig_enforce: false       # module.sig_enforce=1
hardening_disable_smt: false              # mitigations=auto,nosmt

hardening_services_masked:
  - cups.service
  - cups.socket
  - cups.path
  - cups-browsed.service
  - rpcbind.service
  - rpcbind.socket
  - avahi-daemon.service
  - avahi-daemon.socket
  - bluetooth.service
  - debug-shell.service
  - kdump.service

hardening_packages_absent:
  - telnet
  - rsh-client
  - ypbind
  - tftp
  - talk
  - xinetd

# Set false on Kubernetes nodes, NAT gateways and routers.
hardening_ip_forward: false
# Set 2 (loose) on multi-homed hosts with asymmetric routing.
hardening_rp_filter: 1
# Set >0 on nodes running rootless containers (Podman, Flatpak, Chrome).
hardening_max_user_namespaces: 0
# Set 0 to keep kdump working.
hardening_kexec_load_disabled: 1

hardening_blacklisted_modules:
  - cramfs
  - freevxfs
  - jffs2
  - hfs
  - hfsplus
  - squashfs
  - udf
  - dccp
  - sctp
  - rds
  - tipc
  - firewire-core
  - firewire-ohci
  - thunderbolt
  - usb-storage
  - uas

hardening_suid_strip:
  - /usr/bin/chfn
  - /usr/bin/chsh
  - /usr/bin/newgrp

hardening_usbguard_enabled: false          # opt-in; see rollout in section 9.4
hardening_usbguard_implicit_target: block
hardening_usbguard_present_policy: keep

hardening_pam_namespace_enabled: false     # bastion hosts only
```

`roles/host_hardening/tasks/main.yml`:

```yaml
---
- name: Assert the role is running on a supported OS family
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] in ['Debian', 'RedHat']
    fail_msg: "host_hardening supports Debian and RedHat families only"

- name: Include OS-family specific variables
  ansible.builtin.include_vars: "{{ ansible_facts['os_family'] }}.yml"

# ---------------------------------------------------------------------------
#  Boot chain
# ---------------------------------------------------------------------------
- name: Install the GRUB superuser stanza
  ansible.builtin.template:
    src: 40_custom.j2
    dest: /etc/grub.d/40_custom
    owner: root
    group: root
    mode: '0700'
  when:
    - hardening_grub_enable_password | bool
    - ansible_facts['os_family'] == 'Debian'
  notify: regenerate grub config

- name: Mark generated menu entries --unrestricted so unattended boot works
  ansible.builtin.replace:
    path: /etc/grub.d/10_linux
    regexp: '^CLASS="(?!.*--unrestricted)(.*)"$'
    replace: 'CLASS="\1 --unrestricted"'
  when:
    - hardening_grub_enable_password | bool
    - ansible_facts['os_family'] == 'Debian'
  notify: regenerate grub config

- name: Set the GRUB password on the RedHat family
  ansible.builtin.copy:
    content: "GRUB2_PASSWORD={{ hardening_grub_password_pbkdf2 }}\n"
    dest: /boot/grub2/user.cfg
    owner: root
    group: root
    mode: '0600'
  when:
    - hardening_grub_enable_password | bool
    - ansible_facts['os_family'] == 'RedHat'
  notify: regenerate grub config

- name: Compose the hardened kernel command line
  ansible.builtin.set_fact:
    _hardening_cmdline: >-
      {{ (hardening_kernel_cmdline_args
          + (['lockdown=integrity'] if hardening_kernel_lockdown else [])
          + (['module.sig_enforce=1'] if hardening_module_sig_enforce else [])
          + (['mitigations=auto,nosmt'] if hardening_disable_smt else ['mitigations=auto'])
         ) | join(' ') }}

- name: Apply the kernel command line (Debian family)
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^GRUB_CMDLINE_LINUX='
    line: 'GRUB_CMDLINE_LINUX="{{ _hardening_cmdline }}"'
    create: false
  when: ansible_facts['os_family'] == 'Debian'
  notify: regenerate grub config

- name: Apply the kernel command line (RedHat family, BLS entries)
  ansible.builtin.command:
    cmd: grubby --update-kernel=ALL --args="{{ _hardening_cmdline }}"
  register: _grubby
  changed_when: _grubby.rc == 0
  when: ansible_facts['os_family'] == 'RedHat'

- name: Never offer a recovery entry
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^#?GRUB_DISABLE_RECOVERY='
    line: 'GRUB_DISABLE_RECOVERY="true"'
  notify: regenerate grub config

- name: Restrict permissions on the generated bootloader config
  ansible.builtin.file:
    path: "{{ hardening_grub_cfg_path }}"
    owner: root
    group: root
    mode: '0600'

# ---------------------------------------------------------------------------
#  Service surface
# ---------------------------------------------------------------------------
- name: Remove insecure legacy packages
  ansible.builtin.package:
    name: "{{ hardening_packages_absent }}"
    state: absent

- name: Mask unnecessary units
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    masked: true
    enabled: false
    state: stopped
  loop: "{{ hardening_services_masked }}"
  failed_when: false          # a unit that does not exist is not an error here

# ---------------------------------------------------------------------------
#  Kernel tunables
# ---------------------------------------------------------------------------
- name: Deploy the sysctl hardening baseline
  ansible.builtin.template:
    src: 99-hardening.conf.j2
    dest: /etc/sysctl.d/99-hardening.conf
    owner: root
    group: root
    mode: '0644'
    validate: 'sysctl -p %s -n'
  notify: reload sysctl

- name: Blacklist unused kernel modules
  ansible.builtin.template:
    src: 99-hardening-modules.conf.j2
    dest: /etc/modprobe.d/99-hardening.conf
    owner: root
    group: root
    mode: '0644'

- name: Unload any blacklisted module that is currently loaded
  community.general.modprobe:
    name: "{{ item }}"
    state: absent
  loop: "{{ hardening_blacklisted_modules }}"
  failed_when: false

# ---------------------------------------------------------------------------
#  Filesystem and privilege surface
# ---------------------------------------------------------------------------
- name: Harden shared-memory and temporary filesystems
  ansible.posix.mount:
    path: "{{ item.path }}"
    src: "{{ item.src }}"
    fstype: tmpfs
    opts: "{{ item.opts }}"
    state: mounted
  loop:
    - { path: /dev/shm, src: tmpfs, opts: 'rw,nosuid,nodev,noexec,mode=1777' }
    - { path: /tmp,     src: tmpfs, opts: 'rw,nosuid,nodev,noexec,mode=1777,size=2G' }

- name: Keep package managers working with noexec /tmp
  ansible.builtin.copy:
    content: |
      DPkg::Pre-Invoke  {"mount -o remount,exec /tmp";};
      DPkg::Post-Invoke {"mount -o remount,noexec /tmp";};
    dest: /etc/apt/apt.conf.d/50noexec-tmp
    owner: root
    group: root
    mode: '0644'
  when: ansible_facts['os_family'] == 'Debian'

- name: Strip SUID from binaries no unattended server needs
  ansible.builtin.file:
    path: "{{ item }}"
    mode: 'u-s'
  loop: "{{ hardening_suid_strip }}"
  failed_when: false

- name: Persist the mode change against package upgrades (Debian)
  ansible.builtin.command:
    cmd: "dpkg-statoverride --force-statoverride-add --update --add root root 0755 {{ item }}"
  loop: "{{ hardening_suid_strip }}"
  register: _statoverride
  changed_when: "'already exists' not in (_statoverride.stderr | default(''))"
  failed_when: false
  when: ansible_facts['os_family'] == 'Debian'

- name: Inventory SUID/SGID binaries for the compliance record
  ansible.builtin.shell:
    cmd: >-
      find / -xdev \( -perm -4000 -o -perm -2000 \) -type f
      -printf '%M %u:%g %p\n' 2>/dev/null | sort -k3
  register: _suid_inventory
  changed_when: false

- name: Fail if an unexpected SUID binary appeared
  ansible.builtin.assert:
    that:
      - (_suid_inventory.stdout_lines | map('regex_replace', '^\\S+ \\S+ ', '') | list
         | difference(hardening_suid_allowlist)) | length == 0
    fail_msg: >-
      Unexpected SUID/SGID binaries:
      {{ _suid_inventory.stdout_lines | map('regex_replace', '^\S+ \S+ ', '')
         | list | difference(hardening_suid_allowlist) }}

# ---------------------------------------------------------------------------
#  Optional subsystems
# ---------------------------------------------------------------------------
- name: Configure USBGuard
  when: hardening_usbguard_enabled | bool
  block:
    - name: Install usbguard
      ansible.builtin.package:
        name: usbguard
        state: present

    - name: Deploy the usbguard daemon configuration
      ansible.builtin.template:
        src: usbguard-daemon.conf.j2
        dest: /etc/usbguard/usbguard-daemon.conf
        owner: root
        group: root
        mode: '0600'
      notify: restart usbguard

    - name: Deploy config-management-owned rule fragments
      ansible.builtin.copy:
        src: usbguard-rules.d/
        dest: /etc/usbguard/rules.d/
        owner: root
        group: root
        mode: '0600'
      notify: restart usbguard

    - name: Generate the machine-local policy if none exists
      ansible.builtin.shell:
        cmd: usbguard generate-policy -t reject > /etc/usbguard/rules.conf
        creates: /etc/usbguard/rules.conf

    - name: Enable usbguard
      ansible.builtin.systemd_service:
        name: usbguard
        enabled: true
        state: started

- name: Configure polyinstantiated directories
  when: hardening_pam_namespace_enabled | bool
  block:
    - name: Create the instance parent directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: root
        group: root
        mode: '0000'
      loop:
        - /tmp-inst
        - /var/tmp/tmp-inst

    - name: Deploy namespace.conf
      ansible.builtin.template:
        src: namespace.conf.j2
        dest: /etc/security/namespace.conf
        owner: root
        group: root
        mode: '0644'

    - name: Enable pam_namespace in the sshd and login stacks
      ansible.builtin.lineinfile:
        path: "/etc/pam.d/{{ item }}"
        line: 'session    required     pam_namespace.so'
        insertafter: '^session'
        state: present
      loop:
        - sshd
        - login
```

`roles/host_hardening/handlers/main.yml`:

```yaml
---
- name: regenerate grub config
  ansible.builtin.command:
    cmd: "{{ hardening_grub_mkconfig_cmd }}"
  changed_when: true

- name: reload sysctl
  ansible.builtin.command:
    cmd: sysctl --system
  changed_when: true

- name: restart usbguard
  ansible.builtin.systemd_service:
    name: usbguard
    state: restarted
```

`roles/host_hardening/vars/Debian.yml`:

```yaml
---
hardening_grub_cfg_path: /boot/grub/grub.cfg
hardening_grub_mkconfig_cmd: "grub-mkconfig -o /boot/grub/grub.cfg"
hardening_suid_allowlist:
  - /usr/bin/mount
  - /usr/bin/umount
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/gpasswd
  - /usr/bin/crontab
  - /usr/bin/expiry
  - /usr/lib/dbus-1.0/dbus-daemon-launch-helper
  - /usr/lib/openssh/ssh-keysign
```

`roles/host_hardening/vars/RedHat.yml`:

```yaml
---
hardening_grub_cfg_path: /boot/grub2/grub.cfg
hardening_grub_mkconfig_cmd: "grub2-mkconfig -o /boot/grub2/grub.cfg"
hardening_suid_allowlist:
  - /usr/bin/mount
  - /usr/bin/umount
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/gpasswd
  - /usr/bin/crontab
  - /usr/bin/at
  - /usr/sbin/pam_timestamp_check
  - /usr/sbin/unix_chkpwd
  - /usr/libexec/dbus-1/dbus-daemon-launch-helper
```

### 11.1 Continuous assertion with `goss`

`/etc/goss/hardening.yaml`:

```yaml
---
# goss test suite: asserts the RUNTIME state of the hardening baseline.
# Run from cron/systemd timer and ship the JSON result to your metrics store.
# `goss validate --format json` exits non-zero on any failure.

kernel-param:
  kernel.randomize_va_space:
    value: "2"
  kernel.kptr_restrict:
    value: "2"
  kernel.dmesg_restrict:
    value: "1"
  kernel.yama.ptrace_scope:
    value: "1"
  kernel.kexec_load_disabled:
    value: "1"
  kernel.unprivileged_bpf_disabled:
    value: "1"
  fs.protected_hardlinks:
    value: "1"
  fs.protected_symlinks:
    value: "1"
  fs.suid_dumpable:
    value: "0"
  net.ipv4.conf.all.accept_source_route:
    value: "0"
  net.ipv4.conf.all.accept_redirects:
    value: "0"
  net.ipv4.tcp_syncookies:
    value: "1"
  net.ipv6.conf.all.accept_ra:
    value: "0"

file:
  /boot/grub/grub.cfg:
    exists: true
    mode: "0600"
    owner: root
    group: root
    contains:
      - "set superusers="
      - "password_pbkdf2"
      - "--unrestricted"
  /etc/modprobe.d/99-hardening.conf:
    exists: true
    mode: "0644"
    contains:
      - "install usb-storage /bin/true"
      - "install thunderbolt /bin/true"
  /sys/kernel/security/lockdown:
    exists: true
    contains:
      - "[integrity]"
  /sys/devices/system/cpu/vulnerabilities/meltdown:
    exists: true
    contains:
      - "Mitigation"
  /proc/sys/kernel/randomize_va_space:
    exists: true
    contains:
      - "2"

mount:
  /dev/shm:
    exists: true
    opts:
      - nosuid
      - nodev
      - noexec
  /tmp:
    exists: true
    opts:
      - nosuid
      - nodev
      - noexec

service:
  cups:
    enabled: false
    running: false
  rpcbind:
    enabled: false
    running: false
  auditd:
    enabled: true
    running: true
  sshd:
    enabled: true
    running: true

package:
  telnet:
    installed: false
  rsh-client:
    installed: false
  auditd:
    installed: true

port:
  tcp:111:
    listening: false
  tcp:631:
    listening: false
  tcp:22:
    listening: true
    ip:
      - 0.0.0.0

command:
  systemd-analyze-security-nginx:
    exec: "systemd-analyze security nginx.service --no-pager | tail -1"
    exit-status: 0
    stdout:
      - "/exposure level for nginx.service: [0-2]\\./"
  no-writable-executable-mappings:
    exec: "awk '/rwxp/ {c++} END {print c+0}' /proc/*/maps 2>/dev/null"
    exit-status: 0
    stdout:
      - "0"
  no-unexpected-file-capabilities:
    exec: "getcap -r /usr /opt /srv 2>/dev/null | grep -c cap_sys_admin || true"
    exit-status: 0
    stdout:
      - "0"
```

```console
$ sudo goss -g /etc/goss/hardening.yaml validate --format documentation
Kernel Param: kernel.randomize_va_space: value: matches expectation: ["2"]
Kernel Param: kernel.kptr_restrict: value: matches expectation: ["2"]
Kernel Param: kernel.yama.ptrace_scope: value: matches expectation: ["1"]
File: /boot/grub/grub.cfg: mode: matches expectation: ["0600"]
File: /boot/grub/grub.cfg: contains: matches expectation: ["set superusers=", "password_pbkdf2", "--unrestricted"]
Mount: /dev/shm: opts: matches expectation: ["nosuid", "nodev", "noexec"]
Service: cups: running: matches expectation: [false]
Port: tcp:111: listening: matches expectation: [false]
Command: systemd-analyze-security-nginx: exit-status: matches expectation: [0]

Total Duration: 0.412s
Count: 41, Failed: 0, Skipped: 0
```

### 11.2 Compliance scanning with OpenSCAP

```console
$ sudo dnf install -y openscap-scanner scap-security-guide

$ sudo oscap info /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml | grep -A12 Profiles
Profiles:
  Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server
    Id: xccdf_org.ssgproject.content_profile_cis_server_l1
  Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 2 - Server
    Id: xccdf_org.ssgproject.content_profile_cis
  Title: DISA STIG for Red Hat Enterprise Linux 9
    Id: xccdf_org.ssgproject.content_profile_stig
  Title: PCI-DSS v4.0 Control Baseline
    Id: xccdf_org.ssgproject.content_profile_pci-dss

$ sudo oscap xccdf eval \
    --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --results-arf /var/log/oscap/arf-$(hostname)-2026-08-24.xml \
    --report /var/log/oscap/report-$(hostname)-2026-08-24.html \
    /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml
Title   Ensure ASLR is enabled
Rule    xccdf_org.ssgproject.content_rule_sysctl_kernel_randomize_va_space
Ident   CCE-83700-7
Result  pass

Title   Disable Core Dumps for SUID programs
Rule    xccdf_org.ssgproject.content_rule_sysctl_fs_suid_dumpable
Ident   CCE-80953-5
Result  pass

Title   Set Boot Loader Password in grub2
Rule    xccdf_org.ssgproject.content_rule_grub2_password
Ident   CCE-80828-9
Result  pass

Title   Disable Kernel Support for USB via Bootloader Configuration
Rule    xccdf_org.ssgproject.content_rule_grub2_nousb_argument
Ident   CCE-90853-4
Result  fail

Title   Uninstall rsync-daemon Package
Rule    xccdf_org.ssgproject.content_rule_package_rsyncd_removed
Ident   CCE-89757-0
Result  pass
```

| Baseline | Strength | Weakness | Use when |
|---|---|---|---|
| **CIS Level 1** | Broad, low breakage risk, well-known to auditors | Conservative; misses modern mitigations (lockdown, sandboxing) | Default fleet baseline |
| **CIS Level 2** | Adds partitioning, auditing, stricter mounts | Real breakage risk; assumes dedicated partitions | Regulated / high-value hosts |
| **DISA STIG** | Most prescriptive; maps to a formal control catalogue | Heavy-handed; many rules irrelevant to cloud workloads | Government / defence contracts |
| **PCI-DSS** | Scoped to cardholder-data environments | Narrow; not a general hardening baseline | CDE hosts only |
| **Custom (this role)** | Matches your actual threat model and workload | You own the maintenance and the audit narrative | Everywhere — layered *on top of* a recognised baseline |

The honest position: run a recognised profile for the audit narrative, and run your own `goss` suite for the controls the profile does not cover (systemd sandbox exposure scores, `SMT vulnerable` status, USBGuard policy integrity, per-interface sysctl values). The profile satisfies the auditor; the `goss` suite satisfies the threat model.

---

## 12. Failure diagnosis playbook

### 12.1 Symptom → cause → command

| Symptom | Most likely cause | First command |
|---|---|---|
| Host boots to a GRUB username prompt | `superusers` without `--unrestricted` | Rescue media → `grep -c -- --unrestricted /boot/grub/grub.cfg` |
| Host boots, network dead | `sysctl` `ip_forward=0` on a router/k8s node, or blacklisted NIC module | `ip -br a`, `sysctl net.ipv4.ip_forward`, `dmesg \| grep -i firmware` |
| Service dies with `status=31/SYS` | seccomp `SystemCallFilter` denial | `ausearch -m SECCOMP -ts recent -i` |
| Service dies with `Read-only file system` | `ProtectSystem=strict` without `ReadWritePaths=` | `systemctl show -p ReadWritePaths,ProtectSystem <unit>` |
| Rootless container fails to start | `user.max_user_namespaces=0` or `RestrictNamespaces=yes` | `sysctl user.max_user_namespaces` |
| JVM/Node aborts immediately after a hardening rollout | `MemoryDenyWriteExecute=yes` | `systemctl show -p MemoryDenyWriteExecute <unit>` |
| `apt`/`dnf` post-install script fails with `Permission denied` | `noexec` on `/tmp` | `findmnt /tmp -o OPTIONS` |
| Monitoring shows zero processes | `hidepid` or `ProtectProc=invisible` | `findmnt /proc -o OPTIONS`; `id <agent-user>` vs `gid=` |
| Console keyboard dead | USBGuard policy | GRUB → `systemd.mask=usbguard.service` |
| `gdb -p` / `strace -p` refused | `kernel.yama.ptrace_scope >= 1` | `sysctl kernel.yama.ptrace_scope` |
| DKMS build fails after reboot | `lockdown=integrity` + `module.sig_enforce=1` | `cat /sys/kernel/security/lockdown`; `modinfo <mod> \| grep sig` |
| `kdump` produces no vmcore | `kernel.kexec_load_disabled=1` | `sysctl kernel.kexec_load_disabled` |
| Throughput fell 30 % after a kernel upgrade | New CPU mitigation enabled by default | `grep -r . /sys/devices/system/cpu/vulnerabilities/` |
| Users cannot log in via SSH after a change | `pam_namespace` instance dir permissions | `journalctl -t sshd \| grep -i namespace`; `ls -ld /tmp-inst` |

### 12.2 The pre-reboot checklist

Every one of the controls in this material can produce a host that boots but is unusable, or does not boot at all. Before any reboot that applies new hardening:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/pre-reboot-hardening-check
# Run BEFORE rebooting a host with newly applied hardening. Exit 1 = do not reboot.
set -uo pipefail
rc=0
say() { printf '%-8s %s\n' "$1" "$2"; }

# 1. Is there a way back in that does not need the console?
if ! systemctl is-enabled --quiet sshd 2>/dev/null; then
  say FAIL "sshd is not enabled — no remote path back in"; rc=1
else
  say OK "sshd enabled"
fi

# 2. Does the GRUB config still parse, and can the default entry boot unattended?
if grep -q 'set superusers=' "${GRUB_CFG:-/boot/grub/grub.cfg}" 2>/dev/null; then
  if grep -q -- '--unrestricted' "${GRUB_CFG:-/boot/grub/grub.cfg}"; then
    say OK "GRUB password set, default entries unrestricted"
  else
    say FAIL "GRUB superuser set but NO --unrestricted entry: boot will block"; rc=1
  fi
fi

# 3. Will every currently loaded module still load under sig_enforce?
if grep -qw 'module.sig_enforce=1' /proc/cmdline /etc/default/grub 2>/dev/null; then
  unsigned=$(lsmod | tail -n +2 | awk '{print $1}' \
    | while read -r m; do modinfo "$m" 2>/dev/null | grep -q '^sig_id' || echo "$m"; done)
  if [[ -n "$unsigned" ]]; then
    say FAIL "unsigned modules present with sig_enforce pending: $unsigned"; rc=1
  else
    say OK "all loaded modules are signed"
  fi
fi

# 4. Is the root account recoverable from the console?
if [[ "$(passwd -S root | awk '{print $2}')" == "L" ]] \
   && ! systemctl cat emergency.service 2>/dev/null | grep -q SULOGIN_FORCE; then
  say WARN "root is locked and emergency shell requires a password — console recovery impossible"
fi

# 5. Do the sysctl drop-ins still parse?
if ! sysctl -p /etc/sysctl.d/99-hardening.conf -n >/dev/null 2>&1; then
  say FAIL "/etc/sysctl.d/99-hardening.conf does not parse"; rc=1
else
  say OK "sysctl drop-in parses"
fi

# 6. USBGuard: is a keyboard in the policy?
if systemctl is-enabled --quiet usbguard 2>/dev/null; then
  if usbguard list-devices 2>/dev/null | grep -q 'allow.*03:01:01'; then
    say OK "a HID keyboard is allowed by the USBGuard policy"
  else
    say WARN "USBGuard enabled with no allowed HID keyboard — console lockout risk"
  fi
fi

exit $rc
```

```console
$ sudo /usr/local/sbin/pre-reboot-hardening-check
OK       sshd enabled
FAIL     GRUB superuser set but NO --unrestricted entry: boot will block
OK       all loaded modules are signed
WARN     root is locked and emergency shell requires a password — console recovery impossible
OK       sysctl drop-in parses
OK       a HID keyboard is allowed by the USBGuard policy
$ echo $?
1
```

### 12.3 Recovery paths, ranked

1. **SSH still works** — fix in place, this is not an incident.
2. **Out-of-band console (iDRAC/iLO/IPMI SoL/cloud serial console)** — edit the GRUB entry (needs the superuser password, which is why it belongs in your secret manager and not in an engineer's head), append `systemd.unit=rescue.target`, `systemd.mask=<unit>` or `mitigations=off`.
3. **Physical console** — same as above; blocked by a firmware password if you set one, which is the trade you accepted.
4. **Rescue/live media** — blocked by boot-order lock and Secure Boot; requires the firmware password. Chroot in, revert, `grub-mkconfig`.
5. **Reprovision** — the reason immutable golden images plus a fast rebuild pipeline are themselves a hardening control: a host you can recreate in four minutes is a host you can afford to lock down aggressively.

The architectural conclusion: **the aggressiveness of your hardening should be proportional to the speed of your recovery path.** A pet server with no out-of-band access gets a conservative baseline. A cattle node behind an autoscaling group and a Packer image gets `lockdown=integrity`, `module.sig_enforce=1`, `mitigations=auto,nosmt`, `kernel.modules_disabled=1` and a fully sandboxed service — because the worst case is a terminated instance, not a 200 km drive to a rack.

---

## References

- LPI — Exam 303-300 Objectives (LPIC-3 Security, v3.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- GNU GRUB Manual — Security and `password_pbkdf2`: https://www.gnu.org/software/grub/manual/grub/grub.html#Security
- `grub-mkpasswd-pbkdf2` invocation: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dmkpasswd_002dpbkdf2
- Red Hat — Managing, monitoring and updating the kernel (GRUB, `grubby`, BLS): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/index
- Debian Wiki — GRUB 2 password protection: https://wiki.debian.org/Grub2
- Linux kernel — Kernel Lockdown (`kernel_lockdown.7`): https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- Linux kernel — The kernel's command-line parameters: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Linux kernel — Hardware vulnerabilities (Meltdown, Spectre, MDS, L1TF, Retbleed, SRSO): https://www.kernel.org/doc/html/latest/admin-guide/hw-vuln/index.html
- Linux kernel — `/proc/sys/kernel/` documentation (`randomize_va_space`, `kptr_restrict`, `dmesg_restrict`, `modules_disabled`, `kexec_load_disabled`, `perf_event_paranoid`, `sysrq`, `yama`): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
- Linux kernel — `/proc/sys/net/` and IP sysctl reference (`rp_filter`, `accept_redirects`, `log_martians`, `all` vs `default` semantics): https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
- Linux kernel — `/proc/sys/fs/` (`protected_symlinks`, `protected_hardlinks`, `protected_fifos`, `protected_regular`, `suid_dumpable`): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html
- Linux kernel — Yama LSM (`ptrace_scope`): https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html
- Linux kernel — USB device authorization (`authorized`, `authorized_default`): https://www.kernel.org/doc/html/latest/driver-api/usb/authorization.html
- Linux kernel — `proc(5)` mount options including `hidepid` and `subset`: https://man7.org/linux/man-pages/man5/proc.5.html
- Kernel Self Protection Project — recommended settings: https://kernsec.org/wiki/index.php/Kernel_Self_Protection_Project/Recommended_Settings
- systemd — `systemd.exec(5)`, sandboxing directives: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — `systemd.resource-control(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- systemd — `systemd-analyze(1)`, `security` verb: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- systemd — `systemd-sysctl.service(8)` and `sysctl.d(5)` load order: https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html
- systemd — `systemctl(1)` (`mask`, `disable`, `list-unit-files`): https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- USBGuard — official documentation: https://usbguard.github.io/documentation/
- USBGuard — rule language reference (`usbguard-rules.conf(5)`): https://usbguard.github.io/documentation/rule-language.html
- USBGuard — daemon configuration (`usbguard-daemon.conf(5)`): https://github.com/USBGuard/usbguard/blob/main/doc/usbguard-daemon.conf.5.md
- Linux-PAM — `pam_namespace(8)`: https://man7.org/linux/man-pages/man8/pam_namespace.8.html
- Linux-PAM — `namespace.conf(5)`: https://man7.org/linux/man-pages/man5/namespace.conf.5.html
- Linux-PAM — Administrator's Guide: https://github.com/linux-pam/linux-pam/blob/master/doc/sag/pam.md
- `capabilities(7)` — capability sets, file capabilities, ambient set: https://man7.org/linux/man-pages/man7/capabilities.html
- `personality(2)` — `ADDR_NO_RANDOMIZE` and `LockPersonality=`: https://man7.org/linux/man-pages/man2/personality.html
- `seccomp(2)` and seccomp-bpf filtering: https://man7.org/linux/man-pages/man2/seccomp.html
- `prctl(2)` — `PR_SET_NO_NEW_PRIVS`: https://man7.org/linux/man-pages/man2/prctl.html
- `modprobe.d(5)` — `blacklist` vs `install`: https://man7.org/linux/man-pages/man5/modprobe.d.html
- `mount(8)` — `nodev`, `nosuid`, `noexec`: https://man7.org/linux/man-pages/man8/mount.8.html
- GCC — Instrumentation and hardening options (`-fstack-protector-strong`, `-fstack-clash-protection`, `-fcf-protection`): https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html
- glibc — `_FORTIFY_SOURCE` (levels 1, 2 and 3): https://www.gnu.org/software/libc/manual/html_node/Source-Fortification.html
- OpenSSF — Compiler Options Hardening Guide for C and C++: https://best.openssf.org/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C++.html
- Debian Wiki — Hardening and `hardening-check`: https://wiki.debian.org/Hardening
- `checksec` — project page: https://github.com/slimm609/checksec.sh
- OpenSCAP — user manual and `oscap(8)`: https://www.open-scap.org/tools/openscap-base/
- SCAP Security Guide — profiles and rules: https://complianceascode.readthedocs.io/en/latest/
- CIS Benchmarks — Linux: https://www.cisecurity.org/cis-benchmarks
- DISA STIGs — Red Hat Enterprise Linux: https://public.cyber.mil/stigs/downloads/
- NIST SP 800-123 — Guide to General Server Security: https://csrc.nist.gov/pubs/sp/800/123/final
- UEFI Secure Boot on Linux — `mokutil(1)` and shim: https://github.com/rhboot/shim/blob/main/README.md
- Ansible — `ansible.posix` and `community.general` collections: https://docs.ansible.com/ansible/latest/collections/index.html
- goss — server validation: https://github.com/goss-org/goss