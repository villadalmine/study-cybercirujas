# LPI BSD Specialist (702-100) — Topic 711.1: BSD Operating System Installation

## Official Reference Documentation
* **LPI BSD Specialist Overview**: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD Handbook - Installing FreeBSD**: [https://docs.freebsd.org/en/books/handbook/bsdinstall/](https://docs.freebsd.org/en/books/handbook/bsdinstall/)
* **FreeBSD Manual - bsdinstall(8)**: [https://man.freebsd.org/cgi/man.cgi?query=bsdinstall](https://man.freebsd.org/cgi/man.cgi?query=bsdinstall)
* **FreeBSD Manual - freebsd-update(8)**: [https://man.freebsd.org/cgi/man.cgi?query=freebsd-update](https://man.freebsd.org/cgi/man.cgi?query=freebsd-update)
* **OpenBSD FAQ - Installation Guide**: [https://www.openbsd.org/faq/faq4.html](https://www.openbsd.org/faq/faq4.html)
* **OpenBSD Manual - autoinstall(8)**: [https://man.openbsd.org/autoinstall.8](https://man.openbsd.org/autoinstall.8)
* **OpenBSD Manual - sysupgrade(8)**: [https://man.openbsd.org/sysupgrade.8](https://man.openbsd.org/sysupgrade.8)
* **NetBSD Guide - Installing NetBSD**: [https://www.netbsd.org/docs/guide/en/chap-install.html](https://www.netbsd.org/docs/guide/en/chap-install.html)
* **NetBSD Manual - sysinst(8)**: [https://man.netbsd.org/sysinst.8](https://man.netbsd.org/sysinst.8)

---

## Exercise 1: FreeBSD Automated Installation Architecture and Disk Partitioning Mechanics

### Scenario & Technical Context
In enterprise production environments, manual installer navigation using ncurses dialogs does not scale. System Administrators and Site Reliability Engineers automate FreeBSD deployments using `bsdinstall` with scripted configuration files passed via PXE or local media. Understanding how `bsdinstall` partitions disks using `gpart` and configures ZFS storage pools non-interactively is crucial for infrastructure automation.

---

### Step-by-Step Guided Execution

#### Step 1.1: Inspect system identification and existing disk topologies
Before triggering an automated installation script, inspect the system kernel architecture, hardware properties, and existing storage layout using system reporting tools.

Execute the following commands in the shell:

```bash
uname -a
sysctl hw.model hw.ncpu hw.physmem
gpart show
```

**Expected Output:**
```text
FreeBSD bsd-node-01.internal.net 14.0-RELEASE FreeBSD 14.0-RELEASE p5 releng/14.0-n265808-f7db8178822 GENERIC amd64
hw.model: AMD EPYC 7763 64-Core Processor
hw.ncpu: 4
hw.physmem: 8589934592
=>       40  104857520  ada0  GPT  (50G)
         40       1024     1  freebsd-boot  (512K)
       1064        984        - free -  (492K)
       2048    4194304     2  freebsd-swap  (2.0G)
    4196352  100661208     3  freebsd-zfs  (48G)
```

#### Step 1.2: Construct an automated `bsdinstall` configuration script
Create a non-interactive installation script `/tmp/bsdinstall-script` that configures network parameters, user accounts, target hostname, ZFS layout, and binary Distribution Sets.

Execute the following shell command to write the installation manifest:

```bash
cat << 'EOF' > /tmp/bsdinstall-script
#!/bin/sh

# Environment variables governing bsdinstall behavior
export HISTSIZE=1000
export PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Set installation target parameters
HOSTNAME="freebsd-prod-01.infra.local"
KEYMAP="us.iso.acc.kbd"
DISTRIBUTIONS="base.txz kernel.txz src.txz"

# Automated ZFS disk layout configuration (Mirror setup on ada0 and ada1)
export ZFSBOOT_VDEV_TYPE="mirror"
export ZFSBOOT_DISKS="ada0 ada1"
export ZFSBOOT_CONFIRM_ZPOOL="YES"
export ZFSBOOT_POOL_NAME="zroot"
export ZFSBOOT_SWAP_SIZE="4g"
export ZFSBOOT_SWAP_ENCRYPTION="YES"

# Execute ZFS partitioning subsystem non-interactively
bsdinstall zfsboot

# Configure post-installation OS parameters inside target chroot
bsdinstall config

# Apply post-install customizations to target system
cat << 'CHROOT_EOF' >> /mnt/etc/rc.conf
hostname="freebsd-prod-01.infra.local"
ifconfig_vtnet0="DHCP"
sshd_enable="YES"
ntpdate_enable="YES"
zfs_enable="YES"
CHROOT_EOF

cat << 'CHROOT_EOF' >> /mnt/etc/sysctl.conf
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
CHROOT_EOF

echo "Installation complete."
EOF
chmod +x /tmp/bsdinstall-script
```

#### Step 1.3: Validate script syntax and simulate automated bsdinstall execution
Validate the script structure and execute `bsdinstall` in scripted mode against a target root directory.

Execute:

```bash
bsdinstall script /tmp/bsdinstall-script
```

**Expected Output:**
```text
----------------------------------------------------------------------
bsdinstall: Running script /tmp/bsdinstall-script
Formatting ZFS pool 'zroot' on mirrors: ada0 ada1...
Creating ZFS datasets (zroot/ROOT/default, zroot/tmp, zroot/usr/home)...
Extracting base.txz...
Extracting kernel.txz...
Extracting src.txz...
Writing /etc/rc.conf to target environment...
Installation complete.
----------------------------------------------------------------------
```

#### Step 1.4: Verify system identity and build metadata post-installation
Verify kernel release version, system architecture, build dates, and system tuning parameters.

Execute:

```bash
uname -s -r -m -i -p -v
```

**Expected Output:**
```text
FreeBSD 14.0-RELEASE amd64 GENERIC amd64 FreeBSD 14.0-RELEASE p5 releng/14.0-n265808-f7db8178822 GENERIC
```

---

### Verification Questions — Exercise 1

#### Question 1.1
What is the precise mechanical difference between `uname -m` and `uname -p` on FreeBSD systems running on modern 64-bit x86 hardware?

#### Question 1.2
When invoking `bsdinstall script <script-path>`, which environment variable or configuration directive determines which distribution tarballs (such as `base.txz`, `kernel.txz`, or `ports.txz`) are fetched and extracted into the target partition root?

#### Question 1.3
Why does an enterprise SRE prefer creating a dedicated swap partition (`ZFSBOOT_SWAP_SIZE="4g"`) formatted outside of ZFS pool datasets, and what risk is associated with placing a swap file directly on a ZFS filesystem pool during high memory pressure?

---

## Exercise 2: FreeBSD Live Patching and In-Place Major Version Release Upgrades (`freebsd-update`)

### Scenario & Technical Context
Maintaining production uptime requires SREs to apply binary security patches and perform major operating system version upgrades across FreeBSD hosts without rebuilding from source. `freebsd-update` handles binary distribution upgrades, tracking kernel state, configuration merges in `/etc`, and userland library synchronization.

---

### Step-by-Step Guided Execution

#### Step 2.1: Audit system update configuration and check current version state
Inspect `/etc/freebsd-update.conf` to understand which components (Kernel, Userland, Libraries) are included in update checks.

Execute the following commands in the shell:

```bash
freebsd-update updatesready
uname -K -U
cat /etc/freebsd-update.conf | grep -E "^(Components|IgnorePaths|StrictComponents)"
```

**Expected Output:**
```text
1400097 1400097
Components src world kernel
IgnorePaths
StrictComponents false
```

> [!NOTE]
> `uname -K` outputs the OS revision of the running FreeBSD kernel, while `uname -U` outputs the userland binary version. When security patches are applied to userland only, `uname -U` increments (e.g., `1400097`), providing precise diagnostic separation between kernel and userland build states.

#### Step 2.2: Perform security patch fetch and non-interactive installation
Fetch signed binary patch sets from official FreeBSD distribution mirrors and apply them to the live kernel and userland.

Execute:

```bash
freebsd-update fetch
freebsd-update install
```

**Expected Output:**
```text
src component not installed, skipped
Looking up update.FreeBSD.org mirrors... 3 mirrors found.
Fetching public key from update1.freebsd.org... done.
Fetching metadata signature for 14.0-RELEASE from update1.freebsd.org... done.
Fetching metadata index... done.
Inspecting system... done.
Preparing to download files... done.

The following files will be updated as part of updating to 14.0-RELEASE-p6:
/boot/kernel/kernel
/usr/sbin/sshd
/lib/libc.so.7

Downloading files... done.
Installing updates... done.
```

#### Step 2.3: Execute a major release version upgrade to FreeBSD 14.1-RELEASE
Perform a major release version upgrade of FreeBSD using `freebsd-update upgrade`.

Execute:

```bash
freebsd-update -r 14.1-RELEASE upgrade
```

**Expected Output:**
```text
Looking up update.FreeBSD.org mirrors... 3 mirrors found.
Fetching metadata signature for 14.1-RELEASE from update1.freebsd.org... done.
Fetching metadata index... done.
Inspecting system... done.

The following components will be updated as part of updating to 14.1-RELEASE:
world kernel src

Does this look reasonable (y/n)? y

Fetching 12402 files... done.
Attempting to automatically merge changes in files from /etc... done.
File merge status:
  /etc/master.passwd: merged automatically
  /etc/group: merged automatically
  /etc/ssh/sshd_config: conflict detected, opening editor...

To install the downloaded updates, run "/usr/sbin/freebsd-update install".
```

#### Step 2.4: Execute multi-stage binary installation sequence
Applying major upgrades with `freebsd-update` requires a mandatory 3-step sequence interspersed with system reboots to maintain ABI compatibility between kernel and userland libraries.

Execute Stage 1 (Kernel Installation):

```bash
freebsd-update install
```

**Expected Output:**
```text
Installing updates...
Kernel updates installed successfully.
Please reboot the system and run '/usr/sbin/freebsd-update install' again to install userland components.
```

Execute Stage 2 (Post-Reboot Userland Installation):

```bash
# Executed after rebooting into the new kernel:
freebsd-update install
```

**Expected Output:**
```text
Installing userland updates...
Removing old shared libraries...
Complete. Re-run pkg-static upgrade to update installed packages.
```

---

### Verification Questions — Exercise 2

#### Question 2.1
Why does `freebsd-update install` require execution **twice** (separated by a system reboot) when performing a major version upgrade from `14.0-RELEASE` to `14.1-RELEASE`?

#### Question 2.2
If an administrator modifies `/etc/ntp.conf` locally, and an updated version of `/etc/ntp.conf` is provided in the new FreeBSD release, how does `freebsd-update` handle the merge, and what happens if a three-way merge conflict occurs?

#### Question 2.3
What command can an SRE execute to immediately rollback a `freebsd-update install` step if a newly installed kernel fails to boot properly?

---

## Exercise 3: OpenBSD Automated Installation Mechanics (`bsd.rd` and `autoinstall`)

### Scenario & Technical Context
OpenBSD installations leverage a monolithic RAM disk installer kernel named `bsd.rd` (RAM Disk kernel). For zero-touch bare-metal provisioning, OpenBSD provides the `autoinstall(8)` daemon infrastructure. When `bsd.rd` boots, it queries DHCP for option 114 (URL) or attempts to fetch an answer file named `install.conf` via HTTP/TFTP based on system IP or MAC address.

---

### Step-by-Step Guided Execution

#### Step 3.1: Inspect the OpenBSD `bsd.rd` ramdisk environment
Boot an OpenBSD node into `bsd.rd` or inspect the live system installer ramdisk file directly.

Execute the following commands in the shell:

```bash
ls -lh /bsd.rd
uname -a
sysctl kern.version
```

**Expected Output:**
```text
-rwxr-xr-x  1 root  wheel   11.4M Aug  1 12:00 /bsd.rd
OpenBSD openbsd-node-01.infra.net 7.5 GENERIC.MP#82 amd64
kern.version=OpenBSD 7.5 (GENERIC.MP) #82: Thu Mar 21 10:14:22 MDT 2024
    deraadt@amd64.openbsd.org:/usr/src/sys/arch/amd64/compile/GENERIC.MP
```

#### Step 3.2: Construct an OpenBSD `install.conf` automated installer manifest
Create a syntactically valid `install.conf` response file to automate an OpenBSD installation non-interactively over HTTP.

Execute:

```bash
cat << 'EOF' > /var/www/htdocs/install.conf
System hostname = openbsd-node-02
Password for root = $6$sOmESaLt$v.8Jp7dM1aW7oK... (or plain text secret)
Change the default console font = no
Setup a user = SREAdmin
Full name for user SREAdmin = Lead SRE
Password for user SREAdmin = SecretSREPass123!
Public ssh key for user SREAdmin = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... sre@infra
Which speed should com0 use = 115200
Setup network interface = vio0
IPv4 address for vio0 = dhcp
IPv6 address for vio0 = none
Which device is the root disk = sd0
URL to receive file = http://cdn.openbsd.org/pub/OpenBSD/7.5/amd64/
Set name(s) = +* -game* -x*
Location of sets = HTTP
HTTP proxy = none
Use autoinstall response file = yes
EOF
```

#### Step 3.3: Configure DHCP server options to broadcast OpenBSD autoinstall payload
To instruct the OpenBSD `bsd.rd` boot environment to execute an automated installation, configure the OpenBSD DHCP server (`/etc/dhcpd.conf`) to serve the HTTP URL of `install.conf`.

Execute:

```bash
cat << 'EOF' >> /etc/dhcpd.conf
subnet 192.168.1.0 netmask 255.255.255.0 {
    option routers 192.168.1.1;
    option domain-name-servers 192.168.1.1;
    range 192.168.1.100 192.168.1.200;

    host openbsd-target {
        hardware ethernet 52:54:00:ab:cd:ef;
        fixed-address 192.168.1.150;
        filename "pxeboot";
        option vendor-encapsulated-options "http://192.168.1.10/install.conf";
    }
}
EOF
```

#### Step 3.4: Verify system installation state via signify cryptographic signatures
During OpenBSD automated installations, file integrity and distribution set authenticity are strictly verified using `signify(1)`. Inspect the public key associated with the installation release.

Execute:

```bash
ls -l /etc/signify/openbsd-*-base.pub
signify -V -p /etc/signify/openbsd-75-base.pub -e -m /etc/motd
```

**Expected Output:**
```text
-rw-r--r--  1 root  wheel  101 Mar 21  2024 /etc/signify/openbsd-75-base.pub
Signature Verified
```

---

### Verification Questions — Exercise 3

#### Question 3.1
In OpenBSD autoinstall architecture, what is `bsd.rd`, where does it reside in memory during installation execution, and how does it differ mechanically from the production kernel `/bsd`?

#### Question 3.2
If an OpenBSD machine boots `bsd.rd` with `autoinstall` enabled, what sequence of URLs/filenames will the system attempt to fetch from the HTTP server if DHCP option 114 is not specified?

#### Question 3.3
What syntax is used in `install.conf` to explicitly include all standard base installation sets while omitting games (`game75.tgz`) and X11 graphics packages (`xbase75.tgz`, `xfont75.tgz`, etc.)?

---

## Exercise 4: OpenBSD Non-Interactive In-Place Upgrades via `sysupgrade`

### Scenario & Technical Context
Prior to OpenBSD 6.6, upgrading OpenBSD required manually booting into `bsd.rd`, selecting `(U)pgrade`, and stepping through prompt options. Modern SRE operations rely on `sysupgrade(8)`, a utility that automates fetching release binaries, verifying `signify` signatures, staging `bsd.rd` as `/bsd.upgrade`, and initiating an unattended system upgrade reboot.

---

### Step-by-Step Guided Execution

#### Step 4.1: Audit the current system version and patch status
Check the running OpenBSD release version and architecture details before executing `sysupgrade`.

Execute:

```bash
uname -a
sysctl syspatch
```

**Expected Output:**
```text
OpenBSD openbsd-prod-01.infra.net 7.4 GENERIC.MP#0 amd64
010_syspatch 011_ports 012_kernel
```

#### Step 4.2: Execute unattended `sysupgrade` to fetch update sets and stage upgrade kernel
Run `sysupgrade` to fetch the OpenBSD 7.5 upgrade binaries non-interactively.

Execute:

```bash
sysupgrade -n
```

**Expected Output:**
```text
Fetching release candidate binaries from https://cdn.openbsd.org/pub/OpenBSD/7.5/amd64/
Verifying SHA256.sig with /etc/signify/openbsd-75-base.pub... Signature Verified!
Downloading bsd... 100%
Downloading bsd.rd... 100%
Downloading base75.tgz... 100%
Downloading comp75.tgz... 100%
Downloading man75.tgz... 100%
Extracting bsd.rd to /bsd.upgrade... done.
System staged for upgrade on reboot. (-n flag: skipping automatic reboot)
```

#### Step 4.3: Inspect the staged boot environment and initiate reboot
Inspect `/bsd.upgrade` and `/auto_upgrade.conf` created by `sysupgrade` in the root filesystem.

Execute:

```bash
ls -la /bsd.upgrade /auto_upgrade.conf
cat /auto_upgrade.conf
```

**Expected Output:**
```text
-rwxr-xr-x  1 root  wheel  11956224 Aug  6 14:22 /bsd.upgrade
-rw-------  1 root  wheel        86 Aug  6 14:22 /auto_upgrade.conf

Location of sets = /home/_sysupgrade
Root filesystem has changed = yes
Force upgrade = yes
```

#### Step 4.4: Synchronize third-party packages post-upgrade
After rebooting into the upgraded OpenBSD OS release, synchronize all installed third-party ports/packages to match the new ABI version.

Execute:

```bash
pkg_add -u
```

**Expected Output:**
```text
quirks-7.5 signed on 2024-03-21T11:00:00Z
python-3.11.8 -> python-3.11.9: ok
nginx-1.24.0p0 -> nginx-1.26.0: ok
Finished updates.
```

---

### Verification Questions — Exercise 4

#### Question 4.1
When `sysupgrade` runs, it places the installer kernel at `/bsd.upgrade`. How does the OpenBSD bootloader (`boot(8)`) know to execute `/bsd.upgrade` instead of the default `/bsd` kernel on the subsequent system reboot?

#### Question 4.2
What is the role of `/etc/signify/openbsd-XX-base.pub` during a `sysupgrade` run, and what happens if signature validation fails during set download?

---

## Exercise 5: NetBSD Automated Installation (`sysinst`) and Binary Upgrades

### Scenario & Technical Context
NetBSD uses `sysinst(8)` as its core menu-driven installation utility. For automated deployments, `sysinst` supports configuration file driven unattended installations via command line flags (`sysinst -f configfile`). Additionally, maintaining NetBSD installations involves downloading base sets (`.tar.xz` or `.tgz` tarballs) and unpacking them over the system root while using `etcupdate(8)` to reconcile `/etc` configuration changes.

---

### Step-by-Step Guided Execution

#### Step 5.1: Query NetBSD system architecture and release parameters
Determine system architecture, machine type, and release version using `uname` and `sysctl`.

Execute:

```bash
uname -a
uname -m
uname -p
sysctl hw.model
```

**Expected Output:**
```text
NetBSD netbsd-node-01.internal 10.0 NetBSD 10.0 (GENERIC) #0: Thu Mar 28 08:31:37 UTC 2024  build@netbsd.org:/usr/obj/sys/arch/amd64/compile/GENERIC amd64
amd64
x86_64
hw.model = Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz
```

#### Step 5.2: Create an automated `sysinst` configuration manifest
Create a non-interactive `sysinst` configuration file at `/tmp/sysinst.conf` for automated NetBSD provisioning.

Execute:

```bash
cat << 'EOF' > /tmp/sysinst.conf
# NetBSD sysinst automated installation configuration file
install
{
    disk = wd0;
    partition_type = gpt;
    logging = yes;
    net_media = dhcp;
    
    # Disk Partition layout specification
    partition = swap, size = 2048M;
    partition = /, size = rest, type = ffs, version = 2, cgd = no;

    # Fetch locations for NetBSD sets
    fetch_method = http;
    http_host = "cdn.netbsd.org";
    http_dir = "pub/NetBSD/NetBSD-10.0/amd64/binary/sets";

    # Distribution sets selection
    sets = base, comp, etc, games, kern-GENERIC, man, modules, text;
}
EOF
```

#### Step 5.3: Invoke `sysinst` in unattended mode
Execute `sysinst` passing the non-interactive configuration manifest.

Execute:

```bash
sysinst -f /tmp/sysinst.conf
```

**Expected Output:**
```text
Parsing /tmp/sysinst.conf...
Configuring disk wd0 (GPT layout)...
Formatting wd0a (FFSv2 with logging)...
Fetching base.tar.xz from cdn.netbsd.org... 100%
Fetching comp.tar.xz from cdn.netbsd.org... 100%
Fetching etc.tar.xz from cdn.netbsd.org... 100%
Extracting sets into target root... done.
Executing post-install configuration... done.
NetBSD-10.0 installation complete.
```

#### Step 5.4: Execute in-place configuration reconciliation using `etcupdate`
When updating NetBSD binary sets, system binaries are unpacked, but configuration files in `/etc` must be merged safely using `etcupdate(8)` to prevent overwriting local customizations.

Execute:

```bash
etcupdate -s /usr/usr-sets/etc.tar.xz
```

**Expected Output:**
```text
*** Installing new files, updating existing files ***
/etc/group: merged automatically
/etc/rc.conf: user modified, skipping (merge required)
  [c] compare, [m] merge, [s] skip, [i] install new version: m
*** Starting 3-way merge using diff3 ***
Merge successful. New file written to /etc/rc.conf.
```

---

### Verification Questions — Exercise 5

#### Question 5.1
In NetBSD system administration, what is the precise operational role of `sysinst`, and how does passing the `-f` flag alter its execution workflow?

#### Question 5.2
Why is `etcupdate(8)` or `postinstall(8)` mandatory when performing manual binary upgrades of NetBSD by unpacking updated `base.tar.xz` and `etc.tar.xz` archive sets over the system root?

---

<details>
<summary>Answers and Explanations</summary>

### Exercise 1 Solutions

#### Solution 1.1
* `uname -m` prints the **hardware implementation/machine architecture** reported by the system kernel (e.g., `amd64`, `i386`, `sparc64`).
* `uname -p` prints the **processor architecture/instruction set architecture (ISA)** (e.g., `x86_64`, `aarch64`).
* On FreeBSD x86 64-bit systems, `uname -m` outputs `amd64` (FreeBSD's platform target identifier), whereas `uname -p` outputs `amd64` or `x86_64` depending on compiler target aliases. On architecture families such as ARM, `uname -m` might return `arm` while `uname -p` specifies the precise instruction architecture like `armv7` or `aarch64`.

#### Solution 1.2
The `DISTRIBUTIONS` environment variable inside the `bsdinstall` script defines the list of tarballs fetched and extracted during automated installation (e.g., `DISTRIBUTIONS="base.txz kernel.txz src.txz"`).

#### Solution 1.3
* Placing a active swap space inside a ZFS storage pool dataset (`zroot/swap`) introduces a potential **deadlock condition** during extreme low-memory (OOM) situations. To write swapped memory pages out to a ZFS dataset, ZFS must allocate dirty buffers and kernel memory for copy-on-write (COW) metadata calculations, checksumming, and compression. If free memory is fully exhausted, ZFS cannot allocate memory to process the write, causing the I/O path to block indefinitely and panicking the kernel.
* Allocating dedicated raw GPT swap partitions (`freebsd-swap` formatted outside ZFS) or enabling GELI swap encryption (`ZFSBOOT_SWAP_ENCRYPTION="YES"`) circumvents ZFS allocation overhead during memory paging.

---

### Exercise 2 Solutions

#### Solution 2.1
* Major version updates involve breaking changes in binary ABIs (Application Binary Interfaces), system call numbers, and shared system libraries (`libc.so`, `libcrypto.so`).
* **First `freebsd-update install`**: Updates only the kernel (`/boot/kernel/kernel`) and kernel modules. The system must then be rebooted so the new kernel (which maintains backward compatibility with older userland binaries) is actively running.
* **Second `freebsd-update install`**: Updates the userland binaries (`world`), system libraries, and header files while the system is supported by the newly running kernel. Running userland updates prior to booting the compatible kernel would cause active system binaries to crash against incompatible kernel syscalls.

#### Solution 2.2
`freebsd-update` performs a three-way merge using `diff3(1)` between the original release baseline configuration, the local user modifications in `/etc`, and the incoming release defaults. If changes overlap in the same lines of a file, `freebsd-update` triggers a interactive merge prompt (or flags a conflict status in scripted mode), allowing the administrator to resolve conflict markers before finalizing installation.

#### Solution 2.3
An SRE can execute `freebsd-update rollback`. This command restores the kernel and userland binaries to the state immediately preceding the last `freebsd-update install` execution by swapping restored files from `/var/db/freebsd-update/`.

---

### Exercise 3 Solutions

#### Solution 3.1
* `bsd.rd` is a standalone OpenBSD kernel image containing a compressed RAM disk (`rd`) image embedded within its binary structure.
* During boot, the system loads `bsd.rd` into physical memory, mounts the root filesystem completely in RAM (using a memory disk `rd0`), and executes the installation script `/install`.
* Unlike the production multiprocessor kernel `/bsd` (or `/bsd.mp`), `bsd.rd` runs a stripped-down single-processor kernel containing minimal device drivers and installer tools (such as `disklabel`, `newfs`, `bioctl`, and `fetch`) required to format disks and install base packages.

#### Solution 3.2
If DHCP option 114 (or vendor option string) is not supplied, `autoinstall` sends HTTP requests to the default gateway or HTTP server looking for answer files named in the following order:
1. `http://<boot-server>/<MAC_address>-install.conf` (e.g., `52:54:00:ab:cd:ef-install.conf`)
2. `http://<boot-server>/<IP_address>-install.conf` (e.g., `192.168.1.150-install.conf`)
3. `http://<boot-server>/install.conf`

#### Solution 3.3
The syntax `Set name(s) = +* -game* -x*` uses glob pattern matching where `+*` enables all standard sets (`base75.tgz`, `comp75.tgz`, `man75.tgz`, etc.), `-game*` explicitly excludes the games set (`game75.tgz`), and `-x*` excludes all X11 graphical sets (`xbase75.tgz`, `xfont75.tgz`, `xserv75.tgz`, `xshare75.tgz`).

---

### Exercise 4 Solutions

#### Solution 4.1
When `sysupgrade` extracts `bsd.rd` to `/bsd.upgrade`, it creates or updates the kernel boot directive file `/boot.conf` or sets the bootloader environment variable instructing `boot(8)` to load `/bsd.upgrade` on the next reboot. Once `/bsd.upgrade` boots, it detects the presence of `/auto_upgrade.conf`, triggers an automated upgrade without network interaction using pre-staged set files in `/home/_sysupgrade`, replaces `/bsd.upgrade` with the new `/bsd`, removes `/auto_upgrade.conf`, and reboots into the updated production kernel.

#### Solution 4.2
`/etc/signify/openbsd-XX-base.pub` contains the public cryptographic key used by `signify(1)` to verify the digital signature file (`SHA256.sig`) accompanying the OpenBSD release tarballs. If signature validation fails (due to corrupt downloads, tampered binaries, or untrusted mirrors), `sysupgrade` aborts immediately with a signature error, preventing unauthenticated or corrupted code from staging as `/bsd.upgrade`.

---

### Exercise 5 Solutions

#### Solution 5.1
* `sysinst` is NetBSD's official system installation program. It abstracts disk partitioning (MBR/GPT), disk formatting (FFSv1/FFSv2), network interface setup, set retrieval (via HTTP, FTP, NFS, or local media), and base extraction.
* Passing `-f <config-file>` executes `sysinst` non-interactively. The configuration file pre-populates all installation responses (disks, set selections, passwords, network parameters), suppressing interactive curses prompts and enabling automated deployment pipelines.

#### Solution 5.2
Unpacking binary archives like `base.tar.xz` directly onto a live NetBSD root filesystem replaces system binaries (`/bin`, `/sbin`, `/usr/bin`), but skipping `etcupdate(8)` leaves configuration files (`/etc/master.passwd`, `/etc/rc.conf`, `/etc/defaults/rc.conf`) out of sync with new daemon requirements or system structures. `etcupdate` reconciles configuration file differences without overwriting custom local configuration parameters, while `postinstall(8)` checks for obsolete files, broken device nodes in `/dev`, and missing system users.

</details>