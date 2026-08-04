# CKS 5.1 — Minimize Host OS Footprint (Reduce Attack Surface)

**Certification:** Certified Kubernetes Security Specialist (CKS), exam version 1.34
**Domain:** System Hardening — **Exam weight of this topic: 2.5%**

---

## Lab requirements and safety notice

These exercises **modify the host operating system**. Every step is destructive-by-design: you will disable services, purge packages, unload kernel modules, and lock accounts.

| Requirement | Value |
|---|---|
| Node | A **throwaway VM** running Ubuntu 22.04/24.04 or Debian 12, joined to a kubeadm cluster (1 control-plane + 1 worker is ideal) |
| Access | `root` or passwordless `sudo`, plus a **console/out-of-band session** (you will harden SSH and can lock yourself out) |
| Snapshot | Take a VM snapshot **before starting**. You will need to roll back. |
| Cluster state | Run `kubectl cordon` / `kubectl drain` on the target node before the module and sysctl blocks |

```bash
# Run this FIRST, from your workstation, targeting the node you will harden.
kubectl cordon cks-worker-1
kubectl drain cks-worker-1 --ignore-daemonsets --delete-emptydir-data --timeout=120s
```

> **Never** run Block 4 (kernel modules) or Block 8 (sysctl) on a node that is actively serving Pods. Unloading a netfilter or overlay module under a live CNI produces a partition that looks like a control-plane failure and wastes an hour of diagnosis.

---

## Block 1 — Baseline the attack surface before you touch anything

Hardening without a baseline is not hardening; it is guessing. Every change you make in Blocks 2–9 must be diffable against this snapshot.

1. Create a working directory and capture the running service inventory.

```bash
sudo mkdir -p /root/cks-baseline && cd /root/cks-baseline

systemctl list-units --type=service --state=running --no-pager --no-legend \
  | awk '{print $1}' | sort > services-running.txt

systemctl list-unit-files --state=enabled --no-pager --no-legend \
  | awk '{print $1}' | sort > units-enabled.txt

wc -l services-running.txt units-enabled.txt
```

Expected output on a stock kubeadm worker:

```
  21 services-running.txt
  34 units-enabled.txt
  55 total
```

2. Capture every listening socket, with the owning process. This is the single most important artifact: a port with no listener is not an attack surface, and a listener with no port is not remotely reachable.

```bash
sudo ss -tulpnH | sort -k5 > sockets-listening.txt
sudo ss -tulpn
```

Representative output on a control-plane node:

```
Netid State  Recv-Q Send-Q     Local Address:Port  Peer Address:Port Process
udp   UNCONN 0      0          127.0.0.54:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=15))
udp   UNCONN 0      0       127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=14))
tcp   LISTEN 0      4096        127.0.0.1:10248        0.0.0.0:*     users:(("kubelet",pid=1023,fd=20))
tcp   LISTEN 0      4096        127.0.0.1:10249        0.0.0.0:*     users:(("kube-proxy",pid=2871,fd=14))
tcp   LISTEN 0      4096        127.0.0.1:10257        0.0.0.0:*     users:(("kube-controller",pid=1499,fd=3))
tcp   LISTEN 0      4096        127.0.0.1:10259        0.0.0.0:*     users:(("kube-scheduler",pid=1512,fd=3))
tcp   LISTEN 0      4096        127.0.0.1:2379         0.0.0.0:*     users:(("etcd",pid=1580,fd=9))
tcp   LISTEN 0      4096    192.168.56.10:2379         0.0.0.0:*     users:(("etcd",pid=1580,fd=8))
tcp   LISTEN 0      4096    192.168.56.10:2380         0.0.0.0:*     users:(("etcd",pid=1580,fd=7))
tcp   LISTEN 0      4096                *:10250              *:*     users:(("kubelet",pid=1023,fd=27))
tcp   LISTEN 0      4096                *:6443               *:*     users:(("kube-apiserver",pid=1466,fd=3))
tcp   LISTEN 0      128           0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=901,fd=3))
```

3. Capture packages, loaded kernel modules, local accounts, and SUID/SGID binaries.

```bash
dpkg-query -W -f='${Package}\n' | sort > packages-all.txt
apt-mark showmanual | sort                > packages-manual.txt

lsmod | awk 'NR>1 {print $1}' | sort > modules-loaded.txt

awk -F: '{printf "%s:%s:%s\n", $1, $3, $7}' /etc/passwd | sort > accounts.txt

sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
  -printf '%m %u %g %p\n' 2>/dev/null | sort -k4 > suid-sgid.txt

wc -l packages-all.txt modules-loaded.txt accounts.txt suid-sgid.txt
```

```
 641 packages-all.txt
  98 modules-loaded.txt
  31 accounts.txt
  26 suid-sgid.txt
```

4. Record a fingerprint so you can prove later what changed and when.

```bash
sha256sum ./*.txt | tee baseline.sha256
uname -r | tee kernel-version.txt
```

### Comprehension questions — Block 1

1. `ss` reports two entries for etcd on port 2379: one on `127.0.0.1` and one on `192.168.56.10`. Why does removing the loopback listener break the cluster, while restricting the `192.168.56.10` listener does not?
2. Why is `apt-mark showmanual` a more useful starting point for package reduction than `dpkg-query -W`?
3. The `find` command uses `-xdev`. What would you miss without it on a Kubernetes node, and why is that omission *desirable* here?
4. A listener bound to `*:10250` and a listener bound to `127.0.0.1:10248` belong to the same process. Explain, in attack-surface terms, why only one of them is in scope for this topic.

---

## Block 2 — Disable and mask unnecessary services (including socket activation)

A `systemctl stop` survives until the next dependency triggers it. A `systemctl disable` survives until something socket-activates it. Only `mask` is unconditional.

1. List enabled units and identify candidates that no Kubernetes node needs.

```bash
systemctl list-unit-files --state=enabled --type=service --no-pager
```

```
UNIT FILE                      STATE   PRESET
apache2.service                enabled enabled
cron.service                   enabled enabled
containerd.service             enabled enabled
cups.service                   enabled enabled
kubelet.service                enabled enabled
rpcbind.service                enabled enabled
snapd.service                  enabled enabled
ssh.service                    enabled enabled
systemd-resolved.service       enabled enabled
```

2. Before removing anything, confirm what a candidate actually exposes.

```bash
sudo ss -tulpn | grep -E 'apache2|cups|rpcbind'
```

```
tcp   LISTEN 0 511      *:80              *:*   users:(("apache2",pid=1802,fd=4))
tcp   LISTEN 0 4096     *:111             *:*   users:(("rpcbind",pid=744,fd=8))
udp   UNCONN 0 0        *:111             *:*   users:(("rpcbind",pid=744,fd=5))
tcp   LISTEN 0 128 127.0.0.1:631     0.0.0.0:*  users:(("cupsd",pid=903,fd=7))
```

3. Stop, disable, and mask the HTTP server. Verify each stage separately so you internalize the difference.

```bash
sudo systemctl disable --now apache2.service
systemctl is-enabled apache2.service ; systemctl is-active apache2.service
```

```
disabled
inactive
```

4. Now handle `rpcbind`, which is **socket-activated**. Disable only the `.service` and it comes straight back.

```bash
systemctl list-sockets --no-pager | grep -i rpcbind
```

```
/run/rpcbind.sock  rpcbind.socket  rpcbind.service
0.0.0.0:111        rpcbind.socket  rpcbind.service
```

```bash
sudo systemctl disable --now rpcbind.service rpcbind.socket
sudo systemctl mask rpcbind.service rpcbind.socket
systemctl is-enabled rpcbind.socket
```

```
masked
```

5. Prove that masking is stronger than disabling.

```bash
sudo systemctl start rpcbind.service
```

```
Failed to start rpcbind.service: Unit rpcbind.service is masked.
```

```bash
ls -l /etc/systemd/system/rpcbind.service
```

```
lrwxrwxrwx 1 root root 9 Aug  4 11:02 /etc/systemd/system/rpcbind.service -> /dev/null
```

6. Re-check the socket table and diff against the baseline.

```bash
sudo ss -tulpnH | sort -k5 > /root/cks-baseline/sockets-after-block2.txt
diff /root/cks-baseline/sockets-listening.txt /root/cks-baseline/sockets-after-block2.txt
```

### Comprehension questions — Block 2

5. Describe the three distinct states `stop`, `disable`, and `mask` produce, and give a concrete failure scenario for each of the two weaker ones.
6. `systemctl disable --now rpcbind.service` alone left port 111 open. Trace the exact mechanism by which the service reappeared.
7. Which two of the services listed in step 1 must **never** be masked on a Kubernetes worker, and what breaks immediately if you do?
8. You mask a unit and later need it back. What is the exact command, and why is `systemctl enable` insufficient on its own?

---

## Block 3 — Remove unnecessary packages

Disabled software is still a filesystem full of exploitable binaries reachable by any process that achieves code execution — including a container that escapes with a host mount.

1. Identify the largest installed packages and the manually-installed set.

```bash
dpkg-query -W -f='${Installed-Size}\t${Package}\n' | sort -rn | head -15
```

```
187341  linux-image-6.8.0-45-generic
 94210  containerd.io
 41022  snapd
 22876  apache2
 15203  gcc-12
 11940  cups-daemon
  9884  build-essential
  8612  tcpdump
  6210  netcat-openbsd
```

2. Simulate a purge before executing it. `--dry-run` is not optional in production.

```bash
sudo apt-get purge --dry-run apache2 apache2-utils cups cups-daemon
```

```
The following packages will be REMOVED:
  apache2* apache2-bin* apache2-data* apache2-utils* cups* cups-common*
  cups-daemon* libapache2-mod-php8.1*
0 upgraded, 0 newly installed, 8 to remove and 0 not upgraded.
```

3. Execute the purge, then reclaim orphaned dependencies.

```bash
sudo apt-get purge -y apache2 apache2-utils cups cups-daemon
sudo apt-get autoremove --purge -y
```

4. Remove the offensive-tooling and compiler footprint. A compiler on a node turns a read-only exploit primitive into an arbitrary-payload primitive.

```bash
sudo apt-get purge -y gcc-12 build-essential tcpdump netcat-openbsd nmap
dpkg -l | grep -cE '^ii' 
```

5. Confirm no configuration residue remains (`rc` state means the package is removed but its config files persist).

```bash
dpkg -l | awk '/^rc/ {print $2}'
```

```
(no output)
```

6. Re-baseline and quantify the reduction.

```bash
dpkg-query -W -f='${Package}\n' | sort > /root/cks-baseline/packages-after-block3.txt
diff /root/cks-baseline/packages-all.txt /root/cks-baseline/packages-after-block3.txt | grep -c '^<'
```

```
34
```

### Comprehension questions — Block 3

9. What is the operational difference between `apt remove` and `apt purge`, and why does the difference matter for a CIS-style audit?
10. A package shows state `rc` in `dpkg -l`. Is its attack surface removed? Justify.
11. Removing `gcc` is a classic hardening recommendation. Give one concrete post-exploitation capability it denies an attacker — and one realistic reason the control is weaker in 2026 than it was in 2010.
12. Why is purging `tcpdump` from the node a meaningfully different control from denying `NET_RAW` to Pods, even though both target packet capture?

---

## Block 4 — Reduce the kernel module footprint

Every loadable module is kernel-mode code reachable from user space. `CVE`-class filesystem and exotic-protocol modules are the classic local-privilege-escalation surface.

1. Check which target modules are currently loaded.

```bash
lsmod | grep -E '^(cramfs|freevxfs|jffs2|hfs|hfsplus|udf|usb_storage|dccp|sctp|rds|tipc)'
```

```
sctp                  405504  0
usb_storage            81920  0
```

2. Distinguish loadable modules from built-in code. Built-ins cannot be unloaded and blacklisting them is a no-op you must not report as remediated.

```bash
grep -E 'sctp|overlay|br_netfilter' /lib/modules/$(uname -r)/modules.builtin
modinfo -n sctp
```

```
/lib/modules/6.8.0-45-generic/kernel/net/sctp/sctp.ko.zst
```

3. Unload the live modules. `modprobe -r` refuses if the reference count is non-zero, which is the safe behaviour.

```bash
sudo modprobe -r sctp usb_storage
lsmod | grep -E 'sctp|usb_storage' || echo "unloaded"
```

```
unloaded
```

4. Make it persistent. **Two directives are required**: `blacklist` stops automatic/alias-driven loading; `install ... /bin/false` also stops an explicit `modprobe <name>`.

```bash
sudo tee /etc/modprobe.d/99-cks-hardening.conf >/dev/null <<'EOF'
# CKS 5.1 — deny rarely-used filesystems and network protocols.
# blacklist  : prevents alias/auto-load (udev, filesystem autodetect)
# install ... : also defeats an explicit `modprobe <name>`
blacklist cramfs
install cramfs /bin/false
blacklist freevxfs
install freevxfs /bin/false
blacklist jffs2
install jffs2 /bin/false
blacklist hfs
install hfs /bin/false
blacklist hfsplus
install hfsplus /bin/false
blacklist udf
install udf /bin/false
blacklist usb-storage
install usb-storage /bin/false
blacklist dccp
install dccp /bin/false
blacklist sctp
install sctp /bin/false
blacklist rds
install rds /bin/false
blacklist tipc
install tipc /bin/false
EOF

sudo depmod -a
sudo update-initramfs -u
```

5. Verify the deny actually holds against an explicit load attempt.

```bash
sudo modprobe sctp ; echo "exit=$?"
modprobe --showconfig | grep -E '^(install|blacklist) sctp'
```

```
exit=1
blacklist sctp
install sctp /bin/false
```

6. **Trade-off checkpoint.** Inspect the modules Kubernetes itself requires. Blacklisting any of these takes the node offline.

```bash
lsmod | grep -E '^(overlay|br_netfilter|nf_conntrack|ip_vs|ip_tables|nf_nat|vxlan|xt_)' | head
```

```
overlay               196608  84
br_netfilter           32768  0
nf_conntrack          188416  6
ip_vs_rr               16384  1
ip_vs                 233472  3 ip_vs_rr
nf_nat                 57344  4
vxlan                 143360  0
```

7. *(Advanced, one-way door.)* `kernel.modules_disabled=1` freezes the module table until reboot. Read the trade-off before you consider it in production.

```bash
# DO NOT run this yet on a node whose CNI loads modules lazily.
# sudo sysctl -w kernel.modules_disabled=1
sysctl kernel.modules_disabled
```

```
kernel.modules_disabled = 0
```

### Comprehension questions — Block 4

13. Why is `blacklist <mod>` alone insufficient, and what precisely does `install <mod> /bin/false` intercept that `blacklist` does not?
14. You add `blacklist overlay` to `/etc/modprobe.d/` and reboot a worker. Predict the observable symptom, at both the `systemctl` and `kubectl` layer.
15. What does `update-initramfs -u` accomplish here, and name a module class for which skipping it silently defeats your blacklist.
16. `kernel.modules_disabled=1` is described as a one-way door. Explain the ordering constraint that makes it usable at all on a Kubernetes node, and one failure mode it causes with Calico or Cilium.

---

## Block 5 — Audit users, groups, and authentication paths

1. Enumerate human-usable accounts (UID ≥ 1000) and any account with a login shell.

```bash
awk -F: '($3>=1000)&&($1!="nobody"){print $1" uid="$3" shell="$7}' /etc/passwd
```

```
ubuntu uid=1000 shell=/bin/bash
jenkins uid=1001 shell=/bin/bash
deploy uid=1002 shell=/bin/bash
oldadmin uid=1003 shell=/bin/bash
```

2. Hunt for the three classic misconfigurations: duplicate UID 0, empty passwords, and stale sudo grants.

```bash
awk -F: '($3==0){print "UID0: "$1}' /etc/passwd
sudo awk -F: '($2==""){print "EMPTY-PASSWD: "$1}' /etc/shadow
getent group sudo adm root
sudo grep -rE '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/
```

```
UID0: root
UID0: backdoor
sudo:x:27:ubuntu,jenkins,oldadmin
adm:x:4:syslog,ubuntu
root:x:0:
/etc/sudoers.d/90-cloud-init-users:ubuntu ALL=(ALL) NOPASSWD:ALL
/etc/sudoers.d/jenkins:jenkins ALL=(ALL) NOPASSWD:ALL
```

3. Eliminate the second UID 0 account immediately — it is a root account by definition, regardless of its name.

```bash
sudo userdel -r backdoor
awk -F: '($3==0){print $1}' /etc/passwd
```

```
root
```

4. Lock the stale account and expire it, rather than deleting it, when file ownership must be preserved for forensics.

```bash
sudo usermod -L -s /usr/sbin/nologin -e 1 oldadmin
sudo passwd -S oldadmin
sudo gpasswd -d oldadmin sudo
```

```
oldadmin L 08/04/2026 0 99999 7 -1
```

5. Convert every service account to a non-login shell and verify none can obtain a shell.

```bash
awk -F: '($3<1000)&&($7!~/(nologin|false|sync)$/){print $1" -> "$7}' /etc/passwd
```

```
sync -> /bin/sync
```

6. Confirm the reduction.

```bash
awk -F: '($7~/(bash|sh|zsh)$/){print $1}' /etc/passwd | tee /root/cks-baseline/shell-accounts-after.txt
```

```
root
ubuntu
jenkins
deploy
```

### Comprehension questions — Block 5

17. An account named `backdoor` has UID 0. Why is its *name* irrelevant, and what does the kernel actually compare when authorizing a privileged syscall?
18. `usermod -L` prefixes the password hash with `!`. Does that block **all** authentication paths for the account? Name at least one path it leaves open and the flag that closes it.
19. Distinguish `usermod -L` from `chage -E 0` / `usermod -e 1`. Which of the two survives a subsequent `passwd` reset by an administrator?
20. A `NOPASSWD:ALL` sudoers entry exists for a CI account. Explain the specific escalation chain from "container escape into the `jenkins` UID" to "cluster-admin" that this enables.

---

## Block 6 — Harden the SSH daemon

SSH is usually the only *intentional* remote entry point left after the previous blocks. Its configuration is therefore load-bearing.

1. Read the effective configuration, not the file. `sshd -T` resolves `Include` directives, `Match` blocks, and compiled-in defaults.

```bash
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|permitemptypasswords|maxauthtries|x11forwarding|logingracetime|kbdinteractiveauthentication)'
```

```
permitrootlogin yes
passwordauthentication yes
kbdinteractiveauthentication yes
permitemptypasswords no
maxauthtries 6
x11forwarding yes
logingracetime 120
```

2. **Before disabling password auth, prove key-based login works.** Skipping this step is the single most common way to brick a lab node.

```bash
# From your workstation, in a SEPARATE terminal you keep open:
ssh -o PasswordAuthentication=no ubuntu@cks-worker-1 'echo KEY-AUTH-OK'
```

```
KEY-AUTH-OK
```

3. Write a drop-in rather than editing `/etc/ssh/sshd_config`. On Ubuntu 22.04+ the main file ends with `Include /etc/ssh/sshd_config.d/*.conf`, and **the first occurrence of a keyword wins** — so a drop-in included at the top overrides later defaults.

```bash
sudo tee /etc/ssh/sshd_config.d/99-cks-hardening.conf >/dev/null <<'EOF'
# CKS 5.1 — SSH attack-surface reduction
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowGroups ssh-users
EOF

sudo groupadd -f ssh-users
sudo usermod -aG ssh-users ubuntu
```

4. **Validate the syntax before reloading.** A malformed file plus a restart equals an unreachable node.

```bash
sudo sshd -t && echo "CONFIG OK"
```

```
CONFIG OK
```

5. Reload (not restart) and re-read the effective configuration.

```bash
sudo systemctl reload ssh
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|allowgroups)'
```

```
permitrootlogin no
passwordauthentication no
maxauthtries 3
allowgroups ssh-users
```

6. Verify negatively — the control must be observed failing, not assumed.

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@cks-worker-1
```

```
root@cks-worker-1: Permission denied (publickey).
```

### Comprehension questions — Block 6

21. Why is `sshd -T` authoritative where `grep PermitRootLogin /etc/ssh/sshd_config` is misleading? Name two configuration mechanisms `grep` misses.
22. `PermitRootLogin prohibit-password` is a common middle ground. What exactly does it still allow, and in what scenario is it strictly better than `no`?
23. `systemctl reload ssh` was used instead of `restart`. What is the practical difference for a session you currently hold open?
24. `AllowGroups ssh-users` is set and `deploy` is not in that group. Can `deploy` still obtain a shell on the node? Enumerate the remaining paths.

---

## Block 7 — Reduce SUID/SGID binaries

A SUID-root binary is an intentional, permanent privilege-escalation primitive. The control is not "remove them all" — it is "keep only those whose escalation is required, and pin that decision so package upgrades cannot undo it."

1. Enumerate and classify.

```bash
sudo find / -xdev -type f -perm -4000 -printf '%m %u %g %p\n' 2>/dev/null | sort -k4
```

```
4755 root root /usr/bin/chfn
4755 root root /usr/bin/chsh
4755 root root /usr/bin/fusermount3
4755 root root /usr/bin/gpasswd
4755 root root /usr/bin/mount
4755 root root /usr/bin/newgrp
4755 root root /usr/bin/passwd
4755 root root /usr/bin/su
4755 root root /usr/bin/sudo
4755 root root /usr/bin/umount
4755 root root /usr/bin/pkexec
4755 root root /usr/lib/openssh/ssh-keysign
```

2. Attribute each binary to its owning package. An unattributed SUID binary is an incident, not a finding.

```bash
for f in $(sudo find / -xdev -type f -perm -4000 2>/dev/null); do
  pkg=$(dpkg -S "$f" 2>/dev/null | cut -d: -f1)
  printf '%-45s %s\n' "$f" "${pkg:-*** UNOWNED ***}"
done
```

```
/usr/bin/chsh                                 passwd
/usr/bin/passwd                               passwd
/usr/bin/sudo                                 sudo
/usr/bin/pkexec                               policykit-1
/tmp/.cache/nginx-worker                      *** UNOWNED ***
```

3. Strip the SUID bit from binaries with no operational justification on a headless node.

```bash
sudo chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp
sudo chmod u-s /usr/bin/pkexec        # CVE-2021-4034 class; unused headless
ls -l /usr/bin/chsh /usr/bin/pkexec
```

```
-rwxr-xr-x 1 root root 72712 Mar 23  2025 /usr/bin/chsh
-rwxr-xr-x 1 root root 31032 Feb 21  2025 /usr/bin/pkexec
```

4. **Pin the decision.** A plain `chmod` is reverted by the next `apt upgrade` of the owning package; `dpkg-statoverride` is not.

```bash
sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chsh
sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chfn
sudo dpkg-statoverride --list | grep -E 'chsh|chfn'
```

```
root root 0755 /usr/bin/chfn
root root 0755 /usr/bin/chsh
```

5. Investigate the unowned binary — this is the pattern of a persisted backdoor.

```bash
sudo stat /tmp/.cache/nginx-worker
sudo sha256sum /tmp/.cache/nginx-worker
sudo find / -xdev -type f -perm -4000 -newer /etc/hostname 2>/dev/null
```

6. Repeat for SGID and confirm the delta against the baseline.

```bash
sudo find / -xdev -type f -perm -2000 -printf '%m %u %g %p\n' 2>/dev/null | sort -k4 \
  > /root/cks-baseline/sgid-after.txt
diff <(grep -c . /root/cks-baseline/suid-sgid.txt) <(sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l)
```

### Comprehension questions — Block 7

25. What does the leading `4` in mode `4755` mean, and which UID does the process run as when a normal user executes it?
26. You `chmod u-s /usr/bin/passwd`. What breaks, and why is this a bad trade on a multi-user node but arguably fine on a node where all humans authenticate by SSH key only?
27. Explain why `dpkg-statoverride` is required for the control to survive, and what an auditor would see three months after a plain `chmod u-s`.
28. A SUID binary in `/tmp` is not owned by any package. Beyond removing it, name two artifacts you would collect before deletion and why order matters.

---

## Block 8 — Kernel parameter and `/proc` hardening (with the `ip_forward` trap)

1. Read the current values of the parameters you are about to change.

```bash
sysctl kernel.dmesg_restrict kernel.kptr_restrict kernel.yama.ptrace_scope \
       fs.suid_dumpable fs.protected_hardlinks net.ipv4.ip_forward
```

```
kernel.dmesg_restrict = 0
kernel.kptr_restrict = 1
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 2
fs.protected_hardlinks = 1
net.ipv4.ip_forward = 1
```

2. Apply the hardening set. Note what is **deliberately absent**.

```bash
sudo tee /etc/sysctl.d/99-cks-hardening.conf >/dev/null <<'EOF'
# CKS 5.1 — kernel attack-surface reduction

# Kernel information leaks
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3

# Local privilege escalation primitives
kernel.yama.ptrace_scope = 1
kernel.kexec_load_disabled = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# eBPF surface (unprivileged eBPF is a recurring LPE vector)
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Network stack
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0

# DELIBERATELY NOT SET — required by the CNI and kube-proxy:
#   net.ipv4.ip_forward            must remain 1
#   net.bridge.bridge-nf-call-iptables  must remain 1
#   net.ipv4.conf.all.rp_filter    leave at the CNI's value (Calico expects 0 on cali* ifaces)
EOF

sudo sysctl --system | tail -20
```

3. Verify the values took effect and that forwarding is untouched.

```bash
sysctl kernel.dmesg_restrict kernel.kptr_restrict kernel.unprivileged_bpf_disabled net.ipv4.ip_forward
```

```
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.ipv4.ip_forward = 1
```

4. Observe a control working. As a non-root user, kernel pointers must now read as zeros and `dmesg` must be denied.

```bash
su - ubuntu -c 'dmesg | head -2'
su - ubuntu -c 'grep " commit_creds" /proc/kallsyms'
```

```
dmesg: read kernel buffer failed: Operation not permitted
0000000000000000 T commit_creds
```

5. Demonstrate the `ip_forward` trap that CIS-hardening scripts routinely cause. Run it, observe, and revert.

```bash
sudo sysctl -w net.ipv4.ip_forward=0
kubectl run trap-test --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl exec trap-test -- wget -qO- --timeout=3 http://10.96.0.10:53 ; echo "exit=$?"
```

```
wget: download timed out
exit=1
```

```bash
sudo sysctl -w net.ipv4.ip_forward=1     # restore immediately
kubectl delete pod trap-test
```

6. *(Advanced, with a real trade-off.)* Hide other users' processes in `/proc`.

```bash
sudo groupadd -f procmon
sudo mount -o remount,hidepid=invisible,gid=$(getent group procmon | cut -d: -f3) /proc
su - ubuntu -c 'ps aux | wc -l'
```

```
7
```

```bash
# Persist only after validating your monitoring agents still work:
# /proc  /proc  proc  defaults,hidepid=invisible,gid=procmon  0 0
```

### Comprehension questions — Block 8

29. Give the meaning of each value of `kernel.kptr_restrict` (0, 1, 2) and state which one is required to defeat a `/proc/kallsyms` leak from an *unprivileged* process.
30. Why must `net.ipv4.ip_forward` stay at `1`, and which two Kubernetes components stop functioning at `0`? Describe the symptom a user reports.
31. `fs.suid_dumpable = 0` is set. What class of information disclosure does this close, and where would that data otherwise land?
32. `kernel.unprivileged_bpf_disabled = 1` reduces a real LPE surface but has a cost on some clusters. Name the workload category that may break and how you would detect it before rolling out fleet-wide.
33. `hidepid=invisible` hides processes from `ps`. Name two node-level agents that commonly break, and explain the role of the `gid=` option in mitigating that.

---

## Block 9 — Reduce node-daemon and runtime exposure

The Kubernetes node agents *are* part of the host OS footprint. A kubelet with an anonymous read-only port is a larger attack surface than any package you removed.

1. Inspect the kubelet's effective configuration.

```bash
sudo grep -E 'readOnlyPort|anonymous|authorization|mode:|enabled:' /var/lib/kubelet/config.yaml
```

```
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: false
authorization:
  mode: AlwaysAllow
readOnlyPort: 10255
```

2. Confirm the exposure empirically from another host, before fixing it.

```bash
curl -sk https://192.168.56.11:10250/pods | head -c 200
curl -s  http://192.168.56.11:10255/pods | jq -r '.items[].metadata.name' | head
```

```
{"kind":"PodList","apiVersion":"v1","metadata":{},"items":[{"metadata":{"name":"etcd-cks-cp",...
kube-proxy-8xqzt
coredns-5d78c9869d-rl7bq
```

3. Apply the fix.

```bash
sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak
sudo tee /var/lib/kubelet/config.yaml.patch >/dev/null <<'EOF'
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
readOnlyPort: 0
EOF
# Merge the stanzas above into /var/lib/kubelet/config.yaml, then:
sudo systemctl restart kubelet
sudo systemctl is-active kubelet
```

```
active
```

4. Verify negatively.

```bash
curl -sk https://192.168.56.11:10250/pods
curl -s --max-time 3 http://192.168.56.11:10255/pods ; echo "exit=$?"
```

```
Unauthorized
exit=7
```

5. Audit the container runtime socket — the single highest-value host object a Pod can be handed.

```bash
ls -l /run/containerd/containerd.sock
sudo find / -xdev -perm -0002 -type f 2>/dev/null | head
```

```
srw-rw---- 1 root root 0 Aug  4 09:12 /run/containerd/containerd.sock
```

6. Find every Pod in the cluster that has been granted a piece of the host.

```bash
kubectl get pods -A -o json | jq -r '
  .items[] | select(
    .spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true or
    (.spec.volumes // [])[]? .hostPath != null
  ) | "\(.metadata.namespace)/\(.metadata.name)"' | sort -u
```

```
default/debug-shell
kube-system/etcd-cks-cp
kube-system/kube-apiserver-cks-cp
kube-system/kube-proxy-8xqzt
```

7. Restrict the control-plane ports at the host firewall. Order matters: a host firewall on a Kubernetes node coexists with kube-proxy's chains.

```bash
sudo ufw default deny incoming
sudo ufw allow from 192.168.56.0/24 to any port 22   proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 6443 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 10250 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 2379:2380 proto tcp
sudo ufw allow in on cni0
sudo ufw --force enable
sudo ufw status numbered
```

```
Status: active
     To                         Action      From
     --                         ------      ----
[1]  22/tcp                     ALLOW IN    192.168.56.0/24
[2]  6443/tcp                   ALLOW IN    192.168.56.0/24
[3]  10250/tcp                  ALLOW IN    192.168.56.0/24
[4]  2379:2380/tcp              ALLOW IN    192.168.56.0/24
[5]  Anywhere on cni0           ALLOW IN    Anywhere
```

8. Immediately validate the cluster survived the firewall.

```bash
kubectl get nodes
kubectl run fw-check --image=busybox:1.36 --restart=Never --rm -it -- \
  nslookup kubernetes.default.svc.cluster.local
```

### Comprehension questions — Block 9

34. Port 10255 returned a full Pod list with no credentials. Enumerate what an attacker learns from `/pods`, `/metrics`, and `/runningpods` on that port.
35. `anonymous.enabled: true` combined with `authorization.mode: AlwaysAllow` on port 10250 is far worse than the read-only port. What single request turns that into RCE on the node, and which kubelet endpoint serves it?
36. Why does enabling a host firewall on a Kubernetes node require an explicit allow for the CNI interface, and what does kube-proxy do that a naive `deny incoming` policy interferes with?
37. A Pod mounts `/run/containerd/containerd.sock` via `hostPath`. The socket is mode `srw-rw----` owned by `root:root`. Does the file mode protect you? Explain the container-UID mapping that determines the answer.

---

## Block 10 — Verify, diff, and report

1. Re-run the full baseline capture into a second directory and diff every artifact.

```bash
sudo mkdir -p /root/cks-after && cd /root/cks-after
systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}' | sort > services-running.txt
sudo ss -tulpnH | sort -k5 > sockets-listening.txt
dpkg-query -W -f='${Package}\n' | sort > packages-all.txt
lsmod | awk 'NR>1 {print $1}' | sort > modules-loaded.txt
sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %u %g %p\n' 2>/dev/null | sort -k4 > suid-sgid.txt

for f in services-running.txt sockets-listening.txt packages-all.txt modules-loaded.txt suid-sgid.txt; do
  printf '\n=== %s ===\n' "$f"
  diff /root/cks-baseline/$f ./$f | grep -E '^[<>]' | sort | uniq -c
done
```

2. Run an automated benchmark and compare its verdict to your own findings.

```bash
kubectl run kube-bench --image=docker.io/aquasec/kube-bench:v0.10.4 \
  --restart=Never --overrides='
{
  "apiVersion": "v1",
  "spec": {
    "hostPID": true,
    "containers": [{
      "name": "kube-bench",
      "image": "docker.io/aquasec/kube-bench:v0.10.4",
      "command": ["kube-bench","run","--targets","node"],
      "volumeMounts": [
        {"name":"var-lib-kubelet","mountPath":"/var/lib/kubelet","readOnly":true},
        {"name":"etc-kubernetes","mountPath":"/etc/kubernetes","readOnly":true}
      ]
    }],
    "volumes": [
      {"name":"var-lib-kubelet","hostPath":{"path":"/var/lib/kubelet"}},
      {"name":"etc-kubernetes","hostPath":{"path":"/etc/kubernetes"}}
    ]
  }
}'
kubectl logs kube-bench | grep -E '^\[(FAIL|WARN)\]' | head -20
```

3. Return the node to service and confirm scheduling works end to end.

```bash
kubectl uncordon cks-worker-1
kubectl run post-harden --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"nodeName":"cks-worker-1"}}' -- sleep 60
kubectl get pod post-harden -o wide
```

```
NAME           READY   STATUS    RESTARTS   AGE   IP           NODE
post-harden    1/1     Running   0          8s    10.244.1.7   cks-worker-1
```

4. **Strategic step.** Compare your hardened general-purpose distro against a purpose-built immutable node OS. Count what remains reachable.

```bash
ls /usr/bin | wc -l ; ls /bin /sbin /usr/sbin 2>/dev/null | wc -l
```

```
1204
843
```

Contrast with the design point of Talos Linux, Bottlerocket, Flatcar, and Fedora CoreOS: no shell, no SSH, no package manager, read-only `/usr`, API-driven configuration. Talos ships roughly a dozen binaries and no interactive login path at all — the entire content of Blocks 2, 3, 5, 6, and 7 becomes *unrepresentable* rather than *remediated*.

### Comprehension questions — Block 10

38. Your diff shows 34 packages removed and 6 listeners closed, but `kube-bench` still reports `[FAIL]` on a kubelet check. Which of the two signals do you trust, and what is the procedure to resolve the disagreement?
39. `kube-bench` is deployed with `hostPID: true` and host mounts. Reconcile that with everything Block 9 taught about host access. What compensating controls make this acceptable?
40. Name two distinct classes of attack surface that hardening a general-purpose distro **cannot** reduce but an immutable node OS eliminates by construction.
41. You must justify this work to a platform team. Rank the ten blocks by risk reduction per hour of engineering effort, and defend the top two.

---

## Sources

- CNCF, *CKS Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Ports and Protocols* — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubernetes, *Kubelet authentication/authorization* — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes, *Set Kubelet Parameters Via A Configuration File* — https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/
- Kubernetes, *Using sysctls in a Kubernetes Cluster* — https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Linux kernel, *Documentation/admin-guide/sysctl/kernel.rst* — https://docs.kernel.org/admin-guide/sysctl/kernel.html
- Linux kernel, *Yama LSM* — https://docs.kernel.org/admin-guide/LSM/Yama.html
- `man 5 modprobe.d`, `man 8 dpkg-statoverride`, `man 5 sshd_config`, `man 8 systemctl`, `man 5 proc`
- CIS, *Benchmarks* (Ubuntu Linux, Kubernetes) — https://www.cisecurity.org/cis-benchmarks
- Aqua Security, *kube-bench* — https://github.com/aquasecurity/kube-bench
- Sidero Labs, *Talos Linux — Philosophy* — https://www.talos.dev/latest/learn-more/philosophy/
- AWS, *Bottlerocket* — https://github.com/bottlerocket-os/bottlerocket

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1

**1.** The loopback listener on `127.0.0.1:2379` serves the co-located control-plane components — `kube-apiserver` connects to etcd over loopback in a stacked kubeadm topology — and the etcd health endpoint (`2381`) is likewise loopback-bound. Removing it breaks the API server's storage backend and the node stops serving the cluster. The `192.168.56.10:2379` listener serves peer/client traffic across the network and is the one that must be firewalled to the control-plane subnet only. The general principle: a loopback listener is only reachable by processes already on the host, so it belongs to the *local* threat model; a routable-address listener belongs to the *remote* one, which is what "reduce attack surface" targets first.

**2.** `dpkg-query -W` lists every installed package including automatically-pulled dependencies, so the list is dominated by libraries you cannot remove independently. `apt-mark showmanual` lists only packages an operator explicitly installed — the actual decision set. Remove a manual package and `apt autoremove --purge` collects its now-orphaned dependencies automatically, which is a far safer reduction strategy than picking library packages off a flat list.

**3.** `-xdev` prevents `find` from descending into other filesystems. Without it on a Kubernetes node, `find` walks every container's overlayfs layer under `/var/lib/containerd/`, every `emptyDir` under `/var/lib/kubelet/pods/`, and every mounted PV — producing thousands of SUID binaries that belong to container images, not to the host. That omission is desirable because this topic is about the **host OS** footprint; container image SUID binaries are Domain 4/6 material and are remediated by rebuilding images, not by `chmod` on the node.

**4.** `*:10250` is the kubelet API, bound to all interfaces and reachable from any host that can route to the node — it is remote attack surface and in scope. `127.0.0.1:10248` is the kubelet healthz endpoint, reachable only by a process already executing on the host. Reaching it already requires the code execution that the healthz endpoint could grant. It is defence-in-depth at best; 10250 is the perimeter.

### Block 2

**5.**
- `stop` — changes only the current runtime state. The unit restarts on the next boot, on the next dependency activation, or on the next socket connection.
- `disable` — removes the `WantedBy`/`RequiredBy` symlinks so the unit is not started at boot by a target. It does **not** prevent activation as a dependency of another running unit, nor socket/path/timer activation. Failure scenario: you `disable` `apache2` but a monitoring unit lists `Requires=apache2.service` — it starts anyway.
- `mask` — symlinks the unit name to `/dev/null` in `/etc/systemd/system/`, so systemd cannot construct the unit at all. Every start path fails, including manual and dependency-driven. Failure scenario for `stop`: a `stop`-only remediation reports green in an audit run and reverts silently on the next reboot.

**6.** `rpcbind.socket` remained enabled. systemd held the listening socket on `0.0.0.0:111` itself, and on the first inbound connection it performed socket activation: it spawned `rpcbind.service` and passed it the already-bound file descriptor. Because the socket unit owns the port, `ss` shows the port open even while the service is inactive. Socket-activated services must have the `.socket` unit disabled *and* masked, or the `.service` deny is cosmetic.

**7.** `containerd.service` and `kubelet.service`. Masking `containerd` leaves the kubelet with no CRI endpoint — it logs `failed to get container runtime status ... connection refused` and the node goes `NotReady`. Masking `kubelet` stops all Pod lifecycle management on that node; existing containers keep running under containerd but nothing reconciles them, and the node goes `NotReady` after `nodeStatusUpdateFrequency` × the lease expiry.

**8.** `sudo systemctl unmask <unit>` followed by `sudo systemctl enable --now <unit>`. `enable` alone fails because the `/etc/systemd/system/<unit>` → `/dev/null` symlink takes precedence over the vendor unit in `/lib/systemd/system/`; `enable` would attempt to create its own symlink in the same location and systemd still resolves the unit to `/dev/null`. `unmask` deletes that symlink first.

### Block 3

**9.** `apt remove` deletes the package's binaries and data but leaves its configuration files (`/etc/…`) and any conffile-marked content on disk, and the package enters state `rc`. `apt purge` deletes those too. For an audit this matters because leftover configuration can contain credentials (an `htpasswd` file, a database DSN in an Apache vhost, a `cups` printer definition with an SMB password), and because a subsequent reinstall of the package silently restores the old, possibly insecure, configuration rather than the vendor default.

**10.** Mostly, yes — the executables are gone, so no code path remains. But it is not *fully* removed: configuration files persist and may leak secrets to any process that can read `/etc`, and the package is trivially reactivated with its old configuration by `apt install`. `rc` is therefore a finding: run `apt purge` on the package name to reach state `un`/absent.

**11.** Denied capability: compiling a local privilege-escalation exploit *on the target* from source, which is how kernel LPE PoCs are typically distributed. Weaker in 2026 because attackers overwhelmingly ship statically-linked, pre-compiled payloads (Go and Rust tooling makes this trivial), and because on a Kubernetes node an attacker who can create a Pod simply brings a container image containing a full toolchain. Removing `gcc` raises the cost of opportunistic attacks; it does not stop a prepared one.

**12.** They operate at different layers and cover different actors. Denying `NET_RAW` (via Pod Security Standards *Baseline*/*Restricted* or a `securityContext.capabilities.drop`) prevents *containers* from opening raw sockets — it constrains workloads. Purging `tcpdump` removes the tool from the *host* namespace, which is where an attacker lands after a container escape or an SSH compromise, and where they have host `CAP_NET_RAW` and can see all node traffic including other tenants' Pod-to-Pod flows and the kubelet's TLS handshakes. Neither substitutes for the other.

### Block 4

**13.** `blacklist <mod>` only suppresses *implicit* loading: alias resolution, udev hotplug events, and filesystem-type autodetection at mount time. It explicitly does **not** stop `modprobe <mod>` typed by a user or invoked by a script — that is documented behaviour in `modprobe.d(5)`. `install <mod> /bin/false` overrides the module's install command entirely: any load attempt, implicit or explicit, executes `/bin/false` instead of inserting the module, and returns non-zero. You need both because `blacklist` covers the alias path with correct semantics and `install` covers the direct path.

**14.** `systemctl status containerd` shows the service running but failing to start containers; `journalctl -u containerd` logs `failed to create shim / mount overlay: no such device` or `failed to mount overlay: invalid argument`. `kubelet` reports `Failed to create pod sandbox`. At the `kubectl` layer: every Pod on that node sits in `ContainerCreating`, `kubectl describe pod` shows `FailedCreatePodSandBox`, and the node eventually reports `NotReady` because the kubelet cannot start its own static Pods. Overlayfs is the default containerd snapshotter — without it there is no container filesystem.

**15.** `update-initramfs -u` regenerates the initial ramdisk so that the modprobe configuration is present during the early-boot phase. Skipping it silently defeats blacklists for any module loaded from the initramfs before the root filesystem is mounted — notably storage/filesystem drivers and, on many distros, `usb-storage` (loaded by early udev for boot-from-USB support). The module ends up loaded before `/etc/modprobe.d/` is even readable, and `lsmod` afterwards shows it present despite a correct-looking config file.

**16.** `kernel.modules_disabled=1` is a write-once toggle: once set to 1 it cannot be returned to 0 without a reboot. It is only usable if it is applied **last in the boot sequence**, after the CNI, kube-proxy, and containerd have loaded every module they need — in practice via a `systemd` unit ordered `After=kubelet.service` with a delay, not via `/etc/sysctl.d/` (which is applied by `systemd-sysctl.service` early in boot). Failure mode with Calico or Cilium: both load modules lazily in response to configuration — Calico may load `ipip`, `vxlan`, or `xt_*` netfilter extensions when a matching IPPool or policy is first created; Cilium loads eBPF-adjacent and `xt_*` modules when new datapath features activate. With module loading frozen, the first Pod requiring an unloaded `xt_` match fails to program its rule and traffic silently blackholes — with no log line pointing at module loading.

### Block 5

**17.** The account name is a label stored in `/etc/passwd`; it has no role in authorization. The kernel compares the process credential structure's numeric `euid` against `0` (or, on capability-aware paths, evaluates the effective capability set, which a UID-0 process receives in full by default). `backdoor` with UID 0 is root by every kernel check: it can read `/etc/shadow`, load modules, and open `/run/containerd/containerd.sock`. This is exactly why a UID-0 duplicate is an incident finding, not a hygiene finding.

**18.** No. `usermod -L` prefixes the stored hash in `/etc/shadow` with `!`, which makes the hash uncomparable and so blocks **password** authentication only. It leaves open: SSH public-key authentication (the key is in `~/.ssh/authorized_keys`, no password consulted), any PAM module that does not consult `pam_unix` (LDAP, Kerberos, `pam_ssh_agent_auth`), `su` from root, and cron/systemd-timer execution as that user. The flag that closes the interactive paths is `usermod -e 1` (or `chage -E 0`), which sets an account expiry in the past — `pam_unix` account management then denies the account regardless of authentication method, so key-based SSH also fails.

**19.** `usermod -L` is an *authentication* control that mutates the password hash. `chage -E 0` / `usermod -e 1` is an *account* control that sets `sp_expire` in `/etc/shadow` and is enforced during PAM's account phase. `chage -E` survives a subsequent `passwd` reset: an administrator setting a new password clears the `!` lock but does not touch the expiry field, so the account remains denied. This is why the expiry control is the durable one and the lock is the convenient one — set both.

**20.** The container escape lands the attacker as UID 1001 (`jenkins`) on the node. `sudo -n true` succeeds because of `NOPASSWD:ALL`, giving immediate host root. As root the attacker reads `/etc/kubernetes/kubelet.conf` and `/var/lib/kubelet/pki/kubelet-client-current.pem` — the node's client certificate, which carries the `system:node:<name>` identity — and, on a control-plane node, `/etc/kubernetes/admin.conf`, which is `cluster-admin` outright. Even on a worker, root can read every mounted ServiceAccount token under `/var/lib/kubelet/pods/*/volumes/kubernetes.io~projected/`; if any Pod on that node runs with a ServiceAccount bound to `cluster-admin` (or with permission to create Pods, or to read Secrets cluster-wide), that token is the escalation. The chain is: `NOPASSWD` sudo → host root → node credentials and every co-located ServiceAccount token → cluster-admin.

**21.** `sshd -T` asks the daemon to dump its **effective** configuration after full parsing. `grep` on the main file misses (a) `Include /etc/ssh/sshd_config.d/*.conf` drop-ins, which on Ubuntu 22.04+ are where cloud-init and vendor packages place overrides, and (b) compiled-in defaults for keywords absent from the file entirely — `PermitRootLogin` defaults to `prohibit-password` when unset, so `grep` returning nothing tells you nothing. It also misses `Match` blocks, whose conditional settings `sshd -T` will show if you pass `-C user=...,host=...,addr=...`.

**22.** `prohibit-password` (formerly `without-password`) permits root login by **public key**, GSSAPI, or host-based authentication, but denies password and keyboard-interactive. It is strictly better than `no` in exactly one scenario: automation that must run as root over SSH with a key — configuration management, backup agents, `rsync --rsync-path="sudo rsync"` alternatives, or an emergency break-glass path — where switching to a non-root account plus `sudo` would require a `NOPASSWD` grant that is itself a worse control (see answer 20).

**23.** `reload` sends `SIGHUP`; the master `sshd` re-reads its configuration and re-execs, but **existing connections are preserved** because each session is served by a forked child process that is untouched. `restart` tears down the master and, depending on the unit's `KillMode`, may kill the children — dropping your session. If the new configuration is broken, `reload` leaves you connected and able to fix it, while `restart` can leave you locked out with a daemon that failed to start. This is why the sequence is always `sshd -t` → `systemctl reload`.

**24.** Yes, several paths remain. `AllowGroups` is enforced by `sshd` only, so it constrains **SSH** logins alone. `deploy` can still obtain a shell via: the physical/serial/hypervisor console and any `getty`; `su - deploy` or `sudo -u deploy -i` from another authorized account; a cron job or systemd user unit running as `deploy` that executes an attacker-controlled script; and — most relevantly on a Kubernetes node — any Pod or process that executes with UID 1002. Host-level access control is a union of all these paths, not just the SSH one.

### Block 7

**25.** The leading `4` is the setuid bit (`S_ISUID`, octal `04000`). When any user with execute permission runs the file, the kernel sets the process's **effective** UID (and saved set-UID) to the file's owner — `root` here — while the real UID remains the invoking user. The program therefore runs with root's authority for privileged operations, which is precisely why an implementation bug in such a binary is a local privilege escalation.

**26.** Non-root users can no longer change their own password: `passwd` needs to write `/etc/shadow`, which is `-rw-r----- root:shadow`, and without SUID it runs as the unprivileged caller and fails with `passwd: Authentication token manipulation error`. Related tools that call it (`chage` for self-service, some PAM password-change flows, expired-password login) break too. On a multi-user node this is a bad trade — you have broken a routine security operation. On a node where all humans authenticate by SSH key and `PasswordAuthentication no` is set, no one ever changes a Unix password, so the binary has no legitimate caller and stripping it removes a real primitive at zero operational cost.

**27.** A plain `chmod u-s` changes only the inode's mode bits. `dpkg` records the intended permissions in the package metadata and reapplies them whenever the owning package is unpacked — so the next `apt upgrade` of `passwd`, `util-linux`, or `policykit-1` silently restores the SUID bit. `dpkg-statoverride` registers the deviation in `/var/lib/dpkg/statoverride`, which `dpkg` consults during unpack and honours instead of the package default. Three months after a plain `chmod`, an auditor re-running the `find` scan would see the SUID bit back on `chsh`, `chfn`, and `pkexec`, with nothing in the change log to explain it — the classic silent regression.

**28.** Collect, in this order: (1) the file's timestamps and inode metadata via `stat` — `Change` time is the one an attacker cannot set with `touch -t`, and it dates the compromise; (2) a cryptographic hash (`sha256sum`) plus a copy of the binary itself preserved off-host for reverse engineering and IOC matching. Also worth capturing: the owning process if it is running (`fuser`/`lsof` on the path), and the parent directory listing. Order matters because reading the file with `sha256sum` or `cp` updates the access time, and any write or move destroys the change time — you must record metadata *before* touching content, and you must copy the artifact *before* deleting it, or you have destroyed the only evidence of how the node was compromised.

### Block 8

**29.** `kernel.kptr_restrict` controls whether `%pK` format-specifier pointers are exposed:
- `0` — pointers are printed to everyone, no restriction.
- `1` — pointers are hidden (printed as zeros) from processes **lacking `CAP_SYSLOG`**. This is the value that already conceals `/proc/kallsyms` symbol addresses from an unprivileged reader, and it is what the exercise demonstrates.
- `2` — pointers are printed as zeros **regardless of privilege**, including for root/`CAP_SYSLOG` holders.

`1` is sufficient to defeat the unprivileged `/proc/kallsyms` leak; `2` is the hardened choice because it also denies a process that has already obtained `CAP_SYSLOG` — a realistic intermediate state on a node — and closes leaks via other `%pK` consumers.

**30.** `net.ipv4.ip_forward=1` makes the kernel route packets between interfaces. Kubernetes networking is built on that: **kube-proxy** DNATs a ClusterIP to a backend Pod IP and relies on the kernel to forward the rewritten packet out the CNI interface, and the **CNI plugin** (Flannel, Calico, Cilium in non-eBPF-routing modes) forwards Pod-to-Pod traffic between the veth pairs and the node's uplink. At `0`, the kernel drops those packets. The user-visible symptom: DNS resolution inside Pods times out (`nslookup: can't resolve ...`), Service connections hang and then fail with `connection timed out` rather than `connection refused`, cross-node Pod traffic dies while same-node traffic on some CNIs still works — and nothing in `kubectl describe` or the CNI logs points at the sysctl. It is a top-tier false-remediation because generic CIS Linux benchmarks legitimately recommend `ip_forward=0` for a host that is not a router; a Kubernetes node *is* a router.

**31.** It closes disclosure via **core dumps of setuid/setgid programs**. With `fs.suid_dumpable` at `1` (all dumpable) or `2` (dumpable but only readable by root), a crashing SUID binary writes a core file containing the full process memory it held while running as root — password hashes read from `/etc/shadow`, private keys, decrypted secrets, kernel pointers. The dump lands wherever `kernel.core_pattern` directs: typically the process's CWD, `/var/crash`, or piped to `systemd-coredump` / `apport`, from which it may be world-readable, shipped to a crash-reporting service, or simply left on disk. `0` disables dumping for privilege-changing processes entirely.

**32.** eBPF-based workloads that load programs from a non-root or reduced-capability context may break. In practice on Kubernetes this is a narrower risk than it sounds: **Cilium**, **Falco's modern-eBPF driver**, **Pixie**, and most eBPF observability agents run as root with `CAP_BPF`/`CAP_SYS_ADMIN`, and `kernel.unprivileged_bpf_disabled=1` restricts only *unprivileged* (`CAP_BPF`-less) `bpf()` calls — so they are unaffected. The realistic breakage is in-house or third-party tooling that calls `bpf()` from an unprivileged process, and older agents relying on unprivileged socket-filter programs. Detection before fleet rollout: set the value on a single canary node, then watch for `bpf()` calls returning `EPERM` — trace with `sudo bpftrace -e 'tracepoint:syscalls:sys_exit_bpf /args->ret == -1/ { printf("%s %d\n", comm, args->ret); }'` (or `auditd` on the `bpf` syscall) — and confirm every agent DaemonSet stays `Ready` for a full deployment cycle.

**33.** Commonly broken: node exporters and metrics agents (`node_exporter`'s process collector, `cAdvisor`'s host process view), APM/profiling agents (Datadog Agent, Dynatrace OneAgent, Pixie), and any process-based monitoring or log shipper that resolves PIDs to command lines. `gid=` designates a group whose members retain full visibility into `/proc` despite `hidepid`; you add the monitoring agent's service account to that group so it keeps working while ordinary users — and any process an attacker lands in — see only their own processes. Without `gid=`, `hidepid=invisible` forces every monitoring agent to run as root, which is a net loss.

### Block 9

**34.** The read-only port 10255 requires no authentication and exposes:
- `/pods` — the full `PodList` for the node, including every Pod's spec: container images and tags (an image inventory for CVE matching), command and args, **environment variables**, volume definitions with `hostPath` targets, ServiceAccount names, node name, and namespace layout. Environment variables routinely contain credentials injected by CI or Helm.
- `/metrics` and `/metrics/cadvisor` — per-container resource metrics: container names, namespaces, image identifiers, and cgroup paths. Useful for mapping the cluster and for timing side channels.
- `/runningpods` — the currently running Pods with container IDs, which lets an attacker correlate against the container runtime.

Cumulatively this is a complete reconnaissance dossier for the node and, via ServiceAccount and namespace names, a target list for the cluster. The remediation is `readOnlyPort: 0` — the port has no authentication mechanism at all, so it cannot be secured, only closed.

**35.** A `POST` to `/run/{namespace}/{pod}/{container}` or an upgrade request to `/exec/{namespace}/{pod}/{container}?command=...` on port 10250. With `anonymous.enabled: true` the kubelet accepts the unauthenticated request, and with `authorization.mode: AlwaysAllow` it skips the SubjectAccessReview that would otherwise deny it. The attacker gets command execution inside **any container on the node** — including, on a control-plane node, `kube-apiserver` or `etcd`, whose filesystems contain `/etc/kubernetes/pki/` and the entire cluster datastore. From any container they can also read the mounted ServiceAccount token and pivot to the API server. This is the classic full-cluster compromise from a single unauthenticated HTTP request; the fix is `anonymous.enabled: false`, `authorization.mode: Webhook`, and a `clientCAFile` for x509 client authentication.

**36.** kube-proxy programs `nat` and `filter` rules in iptables/nftables to implement Services, and the CNI programs its own `FORWARD` and `nat` rules for Pod networking. `ufw` installs a default `FORWARD` policy of `DROP` plus its own chains, and a naive `ufw default deny incoming` also drops traffic arriving on the CNI bridge (`cni0`, `flannel.1`, `cali*`, `cilium_host`). The result is that Pod-to-Pod, Pod-to-Service, and Pod-to-DNS traffic is dropped by the host firewall even though kube-proxy's DNAT rules fired correctly. An explicit `ufw allow in on <cni-iface>` (and, on some CNIs, `ufw default allow routed` / a permissive `FORWARD` policy) restores it. The deeper point: on a Kubernetes node the host firewall shares the netfilter tables with the cluster's own datapath, so rule ordering and default policies are a shared resource — which is why network-level segmentation (security groups, a physical firewall) is usually the better place to restrict 6443/10250/2379.

**37.** No, the file mode does not protect you. A container by default runs as root (UID 0) inside its user namespace, and unless **user namespace remapping** is enabled the container's UID 0 *is* the host's UID 0 — the kernel compares the same numeric UID against the socket's `root:root` `srw-rw----` mode and grants access. Mounting the socket therefore hands the Pod the containerd API, from which it can launch a new container with `privileged: true`, the host PID namespace, and `/` mounted — i.e. full host root. The mode bits would matter only if the container ran as a non-root UID *and* was not in the `root` group *and* had no `CAP_DAC_OVERRIDE` (which a default-root container has). Given how many of those must hold simultaneously, the correct control is to forbid the mount: `hostPath` on the runtime socket is denied by the *Baseline* Pod Security Standard, and should be blocked by admission policy (Pod Security Admission `baseline`/`restricted`, or a Kyverno/Gatekeeper rule) rather than trusted to file permissions.

### Block 10

**38.** Trust neither blindly — the disagreement is the finding. Your diff proves *what changed on this host*; `kube-bench` evaluates *a specific benchmark control* and may be checking a different file path, a different flag name, or a control that your changes did not target. The procedure: read the exact `[FAIL]` line, which names the CIS control number and the remediation text; locate the file and key it actually inspects (`kube-bench` prints the audit command in `--json` output or in `/opt/kube-bench/cfg/`); verify that value by hand on the node. The two outcomes are (a) a real gap your manual work missed — fix it; or (b) a benchmark false positive, typically because the check greps a `kubelet` command line for a flag you set in `config.yaml` instead, or targets a path your distro places elsewhere. Document which it was; an undocumented suppressed `[FAIL]` is how real gaps survive audits.

**39.** `kube-bench` genuinely requires host access — its job is to read `/var/lib/kubelet/config.yaml`, `/etc/kubernetes/manifests/`, and file ownership and permissions on the node. The tension is resolved not by denying the access but by constraining its blast radius: the mounts are `readOnly: true`; the Pod is `restartPolicy: Never` and short-lived, deleted immediately after; it runs in a dedicated namespace with a ServiceAccount holding no API permissions; the image digest is pinned and verified; the Pod is exempted from the Pod Security Standard by an explicit, named, auditable exception rather than by loosening the namespace default. The general principle: privileged tooling is acceptable when it is *ephemeral, narrowly scoped, individually exempted, and logged* — the failure mode is a standing privileged DaemonSet that nobody removes.

**40.** Two classes:
1. **The interactive access surface itself.** A general-purpose distro has a shell, a package manager, an SSH daemon, and a writable `/usr` — you can harden each, but every one of them remains a code path an attacker who reaches the node can use, and every future package installed by an operator reopens some of it. Talos and Bottlerocket ship no shell and no SSH: there is no interactive session to compromise, and configuration is applied through an authenticated API. `chmod`, `mask`, and `purge` cannot produce that property; only removing the components from the image can.
2. **Configuration and binary drift over the node's lifetime.** Your hardened Ubuntu node diverges from its baseline the moment someone runs `apt install`, a package upgrade restores a SUID bit, or an incident-response session leaves a tool behind — and that drift is invisible without continuous re-scanning. An immutable OS mounts `/usr` read-only, ships atomic image-based updates with rollback, and often verifies the root filesystem with dm-verity, so drift is structurally impossible rather than merely audited. Related: the update mechanism itself becomes a single verifiable artifact rather than hundreds of independently-versioned packages.

**41.** A defensible ranking by risk reduction per hour, with the reasoning that matters more than the exact order:

| Rank | Block | Why here |
|---|---|---|
| 1 | **9 — node daemon exposure** | Minutes of work; closes unauthenticated RCE and cluster-wide reconnaissance |
| 2 | **5 — users and sudo** | Minutes; removes standing root and the escape-to-cluster-admin chain |
| 3 | **6 — SSH hardening** | ~30 min; closes the primary remote entry point to key-only |
| 4 | **2 — services and sockets** | Fast, reversible, directly removes listening ports |
| 5 | **8 — sysctl** | One file; blocks broad LPE and info-leak classes — but carries the `ip_forward` footgun |
| 6 | **3 — packages** | High volume, moderate value; mostly raises attacker cost |
| 7 | **7 — SUID/SGID** | Real value, but per-binary analysis is slow and regression-prone without `dpkg-statoverride` |
| 8 | **4 — kernel modules** | Genuine LPE reduction, highest breakage risk, requires drain + reboot validation |
| 9 | **1 / 10 — baseline and verify** | Zero direct reduction, but every block above is unverifiable without them |

Defence of the top two. **Block 9** is first because it is the only block that addresses a *remotely reachable, unauthenticated, pre-authentication* vulnerability. An anonymous kubelet on 10250 with `AlwaysAllow` is command execution on the node from a single HTTP request — no credential, no user interaction, no prior foothold. Nothing else on the list is exploitable by an attacker who has not already reached the host, and the remediation is three keys in one YAML file plus a service restart. Risk reduction per hour is effectively unbounded.

**Block 5** is second because it targets the *escalation* half of the kill chain rather than the entry half, and because it is the shortest path from "attacker has any foothold" to "attacker has cluster-admin." A duplicate UID 0 account or a `NOPASSWD:ALL` sudoers entry converts a low-severity container escape — which lands you as an unprivileged UID with nothing interesting — into host root, node credentials, and every ServiceAccount token mounted on the node. Auditing UID 0 duplicates, empty passwords, and sudo grants takes four commands, and unlike Blocks 3, 4, and 7 it has essentially no breakage risk and requires no reboot. The pattern that justifies the whole ranking: **prioritise controls that break a kill-chain link outright over controls that merely raise attacker cost**, and among those, prefer the ones that need no drain and no reboot.

</details>