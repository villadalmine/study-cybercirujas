# Certification Study Guide: LPI Security Essentials (Exam 020-100, Version 1.0)
## Topic 3.1: Node, Device, and Storage Security
**Exam Weight:** 20  
**Official Reference:** [LPI Security Essentials Overview](https://www.lpi.org/our-certifications/security-essentials-overview/)

---

### Architectural Overview & Target Competencies

In production infrastructure—whether bare-metal Kubernetes nodes, cloud virtual machines, or edge devices—securing the host node, peripheral interfaces, and storage subsystems forms the bedrock of the defense-in-depth model. Vulnerabilities at the hardware or block-storage layer bypass upper-layer controls (such as network firewalls or container runtimes).

This guide provides deep-dive, production-grade hands-on exercises covering four essential domain areas:
1. **Hardware & Firmware Security**: TPM 2.0, Unified Extensible Firmware Interface (UEFI) Secure Boot, PCR bindings, and peripheral interface protection using `usbguard`.
2. **Data-at-Rest Storage Security**: Block-device encryption using `LUKS2`/`dm-crypt`, Argon2id key derivation, TPM2 key unsealing via `systemd-cryptenroll`, and hardened mount points.
3. **Storage & System Integrity Enforcement**: Kernel protection parameters (`sysctl`), cryptographically signed block devices (`dm-verity`), and Integrity Measurement Architecture (`IMA`).
4. **Data Availability & Resilience**: Storage redundancy verification, automated integrity scrubbing, and append-only/immutable backup strategies.

---

### Module 1: Node & Hardware Security Architecture (TPM 2.0, Secure Boot, & USBGuard)

#### Deep Technical Concept
Hardware security relies on establishing a **Chain of Trust** starting from an immutable hardware root of trust—the **Trusted Platform Module (TPM 2.0)** and **UEFI Secure Boot**. 

- **Platform Configuration Registers (PCRs)**: The TPM contains cryptographic registers that cannot be directly overwritten; they can only be *extended* with hashes of firmware binaries, bootloaders, kernel images, and security policies.
  - **PCR 0**: Core System Firmware (BIOS/UEFI executable code).
  - **PCR 4**: Boot Manager code and Boot Configuration Data.
  - **PCR 7**: Secure Boot state and PK/KEK/db policy signatures.
- **Peripheral Hardening**: USB devices represent physical attack vectors (e.g., BadUSB keystroke injection, unauthorized DMA). `usbguard` uses Linux kernel `udev` events and netlink sockets to block unapproved USB device descriptors based on class, subclass, and serial numbers.

Official References:
- [Trusted Computing Group TPM 2.0 Library Specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/)
- [USBGuard Documentation](https://usbguard.github.io/)

---

#### Exercise 1.1: Auditing TPM 2.0 PCR Registers and Hardware Trust State

##### Step 1: Verify TPM 2.0 Device Driver Availability
Inspect kernel ring messages and character devices to ensure the TPM 2.0 chip is recognized by the Linux kernel.

```bash
ls -l /dev/tpm*
dmesg | grep -i tpm
```

*Expected Output:*
```text
crw-rw---- 1 root tss 253, 0 Aug 07 00:00 /dev/tpm0
crw-rw---- 1 root tss 253, 65536 Aug 07 00:00 /dev/tpmrm0
[    1.204512] tpm_tis 00:01: 2.0 TPM (device-id 0x1B, rev-id 16)
[    1.218901] tpm tpm0: A TPM 2.0 chip is detected (scanned 1 DTPM)
```

##### Step 2: Read Platform Configuration Registers (PCRs)
Use `tpm2_pcrread` to output the current SHA-256 state of platform boot measurements.

```bash
tpm2_pcrread sha256:0,4,7
```

*Expected Output:*
```text
sha256:
  0 : 0xDF23A16F8C8B564E9C12A09B2B471C5DE67D980F123C890AB76D1E89F0A2B11C
  4 : 0x7E12BC9A4310EE987F09D1B2C34E5F678901ABCD2345EF678901234567890ABC
  7 : 0x3F890ABCD1234567890EF1234567890ABC1234567890DEF1234567890ABCDEF1
```

---

#### Exercise 1.2: Enforcing Peripheral Control via USBGuard

##### Step 1: Generate an Initial USBGuard Policy
Create a baseline rule set allowing currently connected USB authorization descriptors while blocking future unknown devices.

```bash
sudo usbguard generate-policy | sudo tee /etc/usbguard/rules.conf
```

*Expected Output:*
```text
allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "..." parent-hash "..." via-port "usb1" with-interface 09:00:00
allow id 046d:c52b serial "" name "USB Receiver" hash "..." parent-hash "..." via-port "1-1" with-interface { 03:01:01 03:01:02 03:00:00 }
```

##### Step 2: Configure the USBGuard Daemon Policy
Inspect `/etc/usbguard/usbguard-daemon.conf` to enforce implicit deny for unauthorized devices and log audit events to syslog.

```bash
sudo cat << 'EOF' | sudo tee /etc/usbguard/usbguard-daemon.conf
RuleFile=/etc/usbguard/rules.conf
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=false
DeviceManagerBackend=uevent
IPCAllowedUsers=root
IPCAllowedGroups=wheel
AuditBackend=syslog
EOF
```

##### Step 3: Enable and Verify USBGuard Status
Start the `usbguard` service and check active policy enforcement.

```bash
sudo systemctl restart usbguard
sudo systemctl status usbguard
sudo usbguard list-devices
```

*Expected Output:*
```text
● usbguard.service - USBGuard daemon
     Loaded: loaded (/lib/systemd/system/usbguard.service; enabled; vendor preset: enabled)
     Active: active (running) since Fri 2026-08-07 00:05:00 UTC; 10s ago
   Main PID: 14205 (usbguard-daemon)
...
1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" ...
2: allow id 046d:c52b serial "" name "USB Receiver" ...
```

---

#### Verification Questions (Module 1)

1. What happens to a key sealed inside a TPM 2.0 bound to PCR 0 and PCR 7 if an attacker flashes a modified, unauthenticated UEFI firmware image onto the motherboard?
2. In `usbguard`, what is the key difference between setting `ImplicitPolicyTarget` to `block` versus `reject`?

---

### Module 2: Storage Security & Encryption at Rest (LUKS2, dm-crypt, & Mount Hardening)

#### Deep Technical Concept
Data-at-rest protection relies on block device encryption via `dm-crypt` and the `LUKS2` (Linux Unified Key Setup v2) header specification.

```
+-----------------------------------------------------------------------------------+
|                                  User Space                                       |
|                  Application / POSIX System Calls (read/write)                    |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                              Filesystem (ext4 / xfs)                              |
|                    Mount Options: nodev, noexec, nosuid, ro                       |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        Kernel Device Mapper Subsystem                             |
|                 dm-crypt (AES-256-XTS cipher / Argon2id KDF)                     |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                       Physical / Virtual Block Device                             |
|                    /dev/nvme0n1p2 or /dev/sdb1 (LUKS2 Header)                     |
+-----------------------------------------------------------------------------------+
```

- **Cryptographic Primitives**: Standard LUKS2 uses `aes-xts-plain64` with a 512-bit key size and `Argon2id` Key Derivation Function (KDF) to prevent GPU-accelerated brute-force attacks against volume passphrases.
- **TPM2 Auto-Unsealing**: `systemd-cryptenroll` binds LUKS2 key slots directly to TPM 2.0 PCRs, permitting automated decryption during boot **only if** the system integrity state (Secure Boot + Firmware) remains untouched.
- **Filesystem Mount Security Flags**:
  - `nodev`: Prevents interpretation of character or block special devices on the filesystem.
  - `nosuid`: Blocks set-user-identifier (`SUID`) or set-group-identifier (`SGID`) bits from taking effect.
  - `noexec`: Disallows execution of any binaries on the mounted filesystem.

Official References:
- [Linux Kernel dm-crypt Documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html)
- [freedesktop.org systemd-cryptenroll Documentation](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)

---

#### Exercise 2.1: Provisioning a LUKS2 Encrypted Storage Volume with Argon2id

##### Step 1: Format a Secondary Block Device with LUKS2
Format `/dev/sdb1` (or a loopback device `/dev/loop0`) with explicit cryptographic parameters.

```bash
# Create a dummy 1GB raw backing storage file if testing on a sandbox
dd if=/dev/zero of=/var/tmp/secure_storage.img bs=1M count=1024
sudo losetup /dev/loop0 /var/tmp/secure_storage.img

# Format block device with LUKS2
echo -n "ProductionPassphrase123!" | sudo cryptsetup luksFormat /dev/loop0 \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --pbkdf argon2id \
  --hash sha512 \
  --label "SECURE_DATA" \
  --key-file -
```

*Expected Output:*
```text
WARNING!
========
This will overwrite data on /dev/loop0 irrevocably.

Command successful.
```

##### Step 2: Dump and Verify LUKS2 Metadata
Inspect the LUKS2 header to verify the cipher, PBKDF algorithm, and key slot allocation.

```bash
sudo cryptsetup luksDump /dev/loop0
```

*Expected Output:*
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 bytes
Keyslots area:  16744448 bytes
UUID:           a1b2c3d4-e5f6-7890-abcd-1234567890ab
Label:          SECURE_DATA

Data segments:
  0: crypt
	offset: 16777216 [bytes]
	cipher: aes-xts-plain64
	sector: 512 [bytes]

Keyslots:
  0: luks2
	Cipher:        aes-xts-plain64
	PBKDF:         argon2id
	Hash:          sha512
	Time cost:     4
	Memory cost:   1048576
	Threads:       4
```

##### Step 3: Open the Encrypted Mapping and Format Filesystem
Map the encrypted block device to `/dev/mapper/secure_vault` and format it with `ext4`.

```bash
echo -n "ProductionPassphrase123!" | sudo cryptsetup open /dev/loop0 secure_vault --key-file -
sudo mkfs.ext4 -L "VAULT" /dev/mapper/secure_vault
```

*Expected Output:*
```text
Opening /dev/loop0 as secure_vault...
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 258048 4k blocks and 64512 inodes
Filesystem UUID: f890abcd-1234-5678-90ab-cdef12345678
Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (4096 blocks): done
Writing superblocks and filesystem accounting information: done
```

---

#### Exercise 2.2: Hardening Filesystem Mounts in `/etc/fstab`

##### Step 1: Create a Secure Target Mount Point
Create directory `/mnt/secure_vault` with restrictive permissions.

```bash
sudo mkdir -p /mnt/secure_vault
sudo chmod 700 /mnt/secure_vault
```

##### Step 2: Configure `/etc/fstab` with Security Enforcement Flags
Append an entry in `/etc/fstab` using UUID matching and strict mount options (`defaults`, `nodev`, `nosuid`, `noexec`).

```bash
VAULT_UUID=$(sudo blkid -s UUID -o value /dev/mapper/secure_vault)
echo "UUID=${VAULT_UUID} /mnt/secure_vault ext4 defaults,nodev,nosuid,noexec 0 2" | sudo tee -a /etc/fstab
sudo mount -a
```

##### Step 3: Audit Mount Option Enforcement
Verify using `findmnt` that `nodev`, `nosuid`, and `noexec` flags are active on `/mnt/secure_vault`.

```bash
findmnt -M /mnt/secure_vault -o TARGET,FSTYPE,OPTIONS
```

*Expected Output:*
```text
TARGET            FSTYPE OPTIONS
/mnt/secure_vault ext4   rw,nosuid,nodev,noexec,relatime
```

##### Step 4: Validate `noexec` Enforcement Mechanics
Attempt to execute a binary within the mounted partition to ensure execution is blocked by the kernel.

```bash
sudo cp /bin/echo /mnt/secure_vault/test_echo
sudo chmod +x /mnt/secure_vault/test_echo
/mnt/secure_vault/test_echo "Hello World"
```

*Expected Output:*
```text
bash: /mnt/secure_vault/test_echo: Permission denied
```

---

#### Exercise 2.3: Binding LUKS2 Volume Key to TPM 2.0 via `systemd-cryptenroll`

##### Step 1: Enroll TPM 2.0 to LUKS2 Key Slot
Bind decryption of `/dev/loop0` to TPM2 PCR 0 (Firmware) and PCR 7 (Secure Boot State).

```bash
echo -n "ProductionPassphrase123!" | sudo systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=0+7 \
  /dev/loop0
```

*Expected Output:*
```text
Enrolling TPM2 token...
New TPM2 token enrolled as key slot 1.
```

##### Step 2: Validate Enrolled LUKS2 Tokens
Verify LUKS dump shows the newly enrolled systemd-tpm2 token.

```bash
sudo cryptsetup luksDump /dev/loop0 | grep -A 8 "Tokens:"
```

*Expected Output:*
```text
Tokens:
  0: systemd-tpm2
	Keyslot: 1
	tpm2-pcr-bank: sha256
	tpm2-pcrs: 0,7
```

---

#### Verification Questions (Module 2)

1. If a node hosts a shared data partition at `/mnt/data` with options `defaults,nosuid,nodev`, can a user create a functional executable file, compile code, or run bash scripts in that directory? Explain why or why not.
2. What distinct attack vector does the `Argon2id` PBKDF protect against compared to legacy `pbkdf2` in LUKS1 headers?

---

### Module 3: Storage & System Integrity Enforcement (Kernel Parameters, dm-verity, & IMA)

#### Deep Technical Concept

Preventing runtime tampering and offline data modifications requires strong kernel enforcement mechanisms:

```
                  +---------------------------------------+
                  |  Read Request for File / Block Data   |
                  +---------------------------------------+
                                      |
                                      v
                  +---------------------------------------+
                  |       Integrity Engine Check          |
                  +---------------------------------------+
                                 /         \
                                /           \
              dm-verity (Block Level)      IMA / EVM (File Level)
              Calculates sector hash       Measures file execution hash
              Compares vs Merkle Tree      Compares vs Kernel Policy/TPM
                                \           /
                                 \         /
                                  v       v
                        +-------------------+
                        | Integrity Match?  |
                        +-------------------+
                           /             \
                   YES    /               \    NO
                         v                 v
               [ Allow IO Access ]   [ Block IO / I/O Error ]
```

- **Kernel Hardening (`sysctl`)**: Disabling unprivileged BPF access, enforcing strict hardlink/symlink restrictions, restricting kernel pointer exposure (`kptr_restrict`), and enforcing dmesg restrictions prevents local privilege escalation (LPE).
- **dm-verity**: Provides transparent, read-only integrity checking of block devices using a cryptographic hash tree (**Merkle Tree**). If a single bit on disk is tampered with offline, `dm-verity` detects a hash mismatch and raises an I/O error or triggers an immediate kernel panic.
- **Integrity Measurement Architecture (IMA)**: Measures the cryptographic hash of files before they are executed or read by the kernel, appending these measurements into TPM PCR 10.

Official References:
- [Linux Kernel dm-verity Documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-verity.html)
- [Linux Kernel IMA Subsystem Documentation](https://www.kernel.org/doc/html/latest/security/IMA-subsystem.html)

---

#### Exercise 3.1: Enforcing Production Kernel Security Parameters (`sysctl`)

##### Step 1: Create a Production Hardened Kernel Configuration
Write system hardening rules to `/etc/sysctl.d/99-node-security.conf`.

```bash
sudo cat << 'EOF' | sudo tee /etc/sysctl.d/99-node-security.conf
# Restrict kernel pointer addresses in /proc and dmesg
kernel.kptr_restrict = 2

# Restrict dmesg access to CAP_SYSLOG
kernel.dmesg_restrict = 1

# Disable unprivileged eBPF execution
kernel.unprivileged_bpf_disabled = 1

# Enable JIT hardening for eBPF
net.core.bpf_jit_harden = 2

# Protect against hardlink/symlink TOCTOU attacks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# Protect FIFO and regular files in world-writable sticky directories
fs.protected_fifos = 2
fs.protected_regular = 2

# Disable kexec system call to prevent loading unverified kernel runtime
kernel.kexec_load_disabled = 1
EOF
```

##### Step 2: Apply and Validate Security Parameters
Load settings dynamically and audit active sysctl keys.

```bash
sudo sysctl --system
sudo sysctl kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled fs.protected_hardlinks
```

*Expected Output:*
```text
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
fs.protected_hardlinks = 1
```

---

#### Exercise 3.2: Setting Up Read-Only Root Integrity Verification via `dm-verity`

##### Step 1: Prepare Raw Data and Hash Storage Devices
Create two loop devices representing a read-only root partition (`/dev/loop1`) and a metadata hash device (`/dev/loop2`).

```bash
# Create data block file (100MB) and hash metadata file (20MB)
dd if=/dev/zero of=/var/tmp/ro_data.img bs=1M count=100
dd if=/dev/zero of=/var/tmp/ro_hash.img bs=1M count=20

sudo losetup /dev/loop1 /var/tmp/ro_data.img
sudo losetup /dev/loop2 /var/tmp/ro_hash.img

# Format loop1 with ext4 filesystem containing sample files
sudo mkfs.ext4 /dev/loop1
sudo mkdir -p /mnt/verity_test
sudo mount /dev/loop1 /mnt/verity_test
echo "Root filesystem immutable data v1.0" | sudo tee /mnt/verity_test/integrity_check.txt
sudo umount /mnt/verity_test
```

##### Step 2: Format the Block Device with `veritysetup`
Generate the cryptographic Merkle Tree on the hash device and output the **Root Hash**.

```bash
sudo veritysetup format /dev/loop1 /dev/loop2 | tee /var/tmp/verity_format.log
```

*Expected Output:*
```text
VERITY header information
Version:        1
Hash algorithm: sha256
Data block size: 4096
Hash block size: 4096
Data blocks:     25600
Salt:           a1b2c3d4e5f678901234567890abcdef1234567890abcdef1234567890abcdef
Root hash:      e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

##### Step 3: Create the Verified Mapping
Attach the verity device using the generated Root Hash.

```bash
ROOT_HASH=$(grep "Root hash:" /var/tmp/verity_format.log | awk '{print $3}')
sudo veritysetup open /dev/loop1 verity_protected /dev/loop2 "$ROOT_HASH"
```

##### Step 4: Validate Read Access and Tamper Protection
Mount the verity mapped device and attempt a raw block modification to simulate rootkit tampering.

```bash
# Mount verity device
sudo mkdir -p /mnt/verity_protected
sudo mount -o ro /dev/mapper/verity_protected /mnt/verity_protected
cat /mnt/verity_protected/integrity_check.txt

# Simulate low-level offline block corruption directly on backing data device
sudo umount /mnt/verity_protected
sudo veritysetup close verity_protected

# Corrupt sector data directly via dd
echo "MALICIOUS_CORRUPTION" | sudo dd of=/dev/loop1 bs=512 seek=2000 count=1 conv=notrunc

# Re-open verity mapping and trigger I/O read across corrupted block
sudo veritysetup open /dev/loop1 verity_protected /dev/loop2 "$ROOT_HASH"
sudo mount -o ro /dev/mapper/verity_protected /mnt/verity_protected
sudo cat /mnt/verity_protected/integrity_check.txt
```

*Expected Output:*
```text
Root filesystem immutable data v1.0
...
cat: /mnt/verity_protected/integrity_check.txt: Input/output error
```
*(The kernel logs an explicit `device-mapper: verity: 7:1: data block 250 is corrupted` error and denies the read).*

---

#### Verification Questions (Module 3)

1. How does `dm-verity` detect if an attacker alters a single byte on the physical block storage device? Why can't the attacker simply update the corresponding hash in the hash device?
2. What vulnerability vector is eliminated by setting `kernel.kexec_load_disabled = 1` on a running host?

---

### Module 4: Data Availability, Storage Redundancy, & Immutable Backup Strategies

#### Deep Technical Concept

Security Essentials mandates that **Data Availability** is preserved against hardware failure, ransomware encryptors, and administrative errors.

- **RAID / Storage Scrubbing**: Disk arrays (e.g., Software RAID `mdadm`, ZFS, Btrfs) can suffer from silent data corruption ("bit rot"). Periodic scrubbing forces read checks across redundant drives, using parity blocks to automatically repair bad sectors.
- **Immutable & Append-Only Backups**: Protecting backups against compromise requires decoupling backup writers from deletion capabilities. 
  - **S3 Object Lock (Compliance Mode)** / **FileSystem Immutability (`chattr +i`)**: Prevents modification or deletion of backup artifacts even by the `root` user during a defined retention window.
  - **Repository Locking**: Utilizing modern backup tools (`restic`, `borg`) paired with append-only access controls ensures that compromised nodes cannot issue a `prune` or `forget` command to purge remote backups.

---

#### Exercise 4.1: Storage Redundancy Integrity Scrubbing (`mdadm`)

##### Step 1: Inspect RAID Array Integrity Status
Inspect `/proc/mdstat` and issue a background integrity scrub command to calculate sector checksum parity across software RAID devices.

```bash
cat /proc/mdstat
```

*Expected Output:*
```text
Personalities : [raid1] [raid6] [raid5] [raid4] 
md0 : active raid1 sdb1[1] sda1[0]
      1047552 blocks super 1.2 [2/2] [UU]
```

##### Step 2: Trigger Array Data Scrubbing
Initiate a check operation on the RAID device to detect and automatically heal parity discrepancies.

```bash
echo "check" | sudo tee /sys/block/md0/md/sync_action
cat /sys/block/md0/md/mismatch_cnt
```

*Expected Output:*
```text
check
0
```

---

#### Exercise 4.2: Implementing Immutable Ransomware-Resistant Backups

##### Step 1: Create an Encrypted Local Backup Repository using Restic
Initialize an encrypted repository using `restic`.

```bash
# Install restic if missing
sudo apt-get install -y restic || sudo yum install -y restic

# Set repository location and password environment variable
export RESTIC_REPOSITORY="/var/backups/production_repo"
export RESTIC_PASSWORD="BackupEncryptionKey987!"

# Initialize backup repository
sudo -E restic init
```

*Expected Output:*
```text
created restic repository 8f90abcd12 at /var/backups/production_repo

Please note that knowledge of your password is required to access
the repository. Losing your password means total loss of data.
```

##### Step 2: Perform an Initial Snapshot
Backup target host configuration directories `/etc` and `/etc/sysctl.d`.

```bash
sudo -E restic backup /etc/sysctl.d /etc/usbguard
```

*Expected Output:*
```text
Files:           3 new,     0 changed,     0 unmodified
Dirs:            3 new,     0 changed,     0 unmodified
Added to the repository: 4.120 KiB

processed 3 files, 1.230 KiB in 0:00
snapshot 1a2b3c4d saved
```

##### Step 3: Enforce Filesystem-Level Immutability on Backup Repositories
Set the immutable attribute (`+i`) on the repository index and data blobs to block write/delete/truncate actions, even from `root`.

```bash
# Apply immutable flag recursively to repository data blocks
sudo chattr -R +i /var/backups/production_repo/data
sudo lsattr -d /var/backups/production_repo/data
```

*Expected Output:*
```text
----i---------e------- /var/backups/production_repo/data
```

##### Step 4: Validate Immutability Protection Against Deletion
Attempt to delete or modify a file inside the protected repository as `root`.

```bash
sudo rm -rf /var/backups/production_repo/data/*
```

*Expected Output:*
```text
rm: cannot remove '/var/backups/production_repo/data/...': Operation not permitted
```

---

#### Verification Questions (Module 4)

1. If a production server is compromised by ransomware with full `root` privilege, how does enforcing **S3 Object Lock Compliance Mode** on offsite backup buckets prevent the ransomware from destroying backups?
2. What is the difference between a RAID `check` action and a RAID `repair` action in `mdadm`?

---

### Solution Key & Comprehensive Technical Explanations

<details>
<summary><strong>Click here to expand the detailed answers and explanations</strong></summary>

#### Module 1 Answers

1. **TPM 2.0 PCR Binding Mechanism**:
   - **Answer**: The TPM 2.0 chip will fail to unseal the stored cryptographic key, causing the automated boot/decryption process to halt.
   - **Detailed Technical Explanation**: When a secret is sealed to TPM 2.0 PCRs (e.g., PCR 0 for firmware and PCR 7 for Secure Boot state), the TPM evaluates the current cryptographic digest stored in those registers before releasing the key. If an attacker flashes modified firmware or disables Secure Boot, the hash measurements extended into PCR 0 or PCR 7 change. When `systemd-cryptenroll` or `tpm2_unseal` requests key unsealing, the TPM compares the current state of the PCRs against the policy digest created at key enrollment. Because the hashes mismatch, the TPM hardware policy engine denies access to the secret, leaving data on disk encrypted.

2. **USBGuard Policy Targets (`block` vs `reject`)**:
   - **Answer**: `block` silently drops the USB interface at the kernel layer, while `reject` explicitly resets or disconnects the device descriptor.
   - **Detailed Technical Explanation**: `ImplicitPolicyTarget=block` directs the `usbguard-daemon` to set the kernel device authorization state to `0` without sending explicit error feedback to the device controller. The physical device receives power, but no interface drivers or endpoints are attached in subsystem space. `reject` goes a step further by instructing the device controller to explicitly de-authorize and logical teardown of the peripheral descriptor. In high-security environments, `block` is preferred to prevent USB fuzzing tools or rogue devices from gaining telemetry on policy enforcement behavior.

---

#### Module 2 Answers

1. **Execution Rights under `nosuid,nodev` Mount Options**:
   - **Answer**: Yes, users can still create executable files and run scripts unless `noexec` is explicitly specified.
   - **Detailed Technical Explanation**: 
     - `nosuid` only disables the kernel handling of the `SUID` and `SGID` file mode bits (preventing privilege escalation via binaries like setuid root).
     - `nodev` prevents the kernel from treating files on the filesystem as block or character special devices (e.g., creating a rogue `/dev/sda` node via `mknod`).
     - Neither option restricts standard file permissions (`chmod +x`) or execution calls (`execve`). A user can run compiled binaries or execute scripts (via `bash script.sh` or direct execution) unless the **`noexec`** flag is applied to the mount entry in `/etc/fstab`.

2. **LUKS2 Argon2id vs LUKS1 PBKDF2**:
   - **Answer**: Argon2id protects against hardware-accelerated offline brute-force attacks (utilizing GPUs, ASICs, or FPGAs) by enforcing memory-hard computational complexity.
   - **Detailed Technical Explanation**: Standard `PBKDF2` is compute-bound, relying primarily on SHA-1/SHA-256 iterations. Attackers using custom ASICs or parallel GPU clusters can execute billions of PBKDF2 calculations per second at low cost. `Argon2id` (the key derivation function used in LUKS2) is both **memory-hard** and **time-hard**. It requires a massive allocation of memory (e.g., 1GB RAM per attempt) and utilizes data-independent and data-dependent memory access patterns. This makes GPU/ASIC parallelization prohibitively expensive due to memory bandwidth limits.

---

#### Module 3 Answers

1. **dm-verity Cryptographic Merkle Tree**:
   - **Answer**: `dm-verity` uses a hierarchical Merkle tree structure anchored by a single immutable Root Hash. Modifying data blocks invalidates parent node hashes all the way up to the Root Hash.
   - **Detailed Technical Explanation**: In `dm-verity`, the storage volume is divided into fixed-size data blocks (e.g., 4096 bytes). Each block is hashed. Those hashes are grouped into blocks and hashed again, forming a tree hierarchy. The top of the tree is a single **Root Hash**, which is passed securely to the kernel during boot (often signed by a trusted kernel key or embedded in Secure Boot authenticated initramfs). If an attacker alters a single byte on disk, the block hash changes, breaking the parent node hash, which breaks the layer above it, invalidating the Root Hash match. An attacker cannot simply rewrite the hash device because altering the upper hashes would change the required Root Hash, which is locked in kernel memory.

2. **Preventing Runtime Kernel Replacement via `kexec_load_disabled`**:
   - **Answer**: It prevents a compromised `root` account from executing `kexec` to boot a malicious, unverified kernel directly in memory without going through UEFI Secure Boot.
   - **Detailed Technical Explanation**: The `kexec` system call permits a running kernel to load and jump directly into another kernel binary without undergoing a hardware reset or BIOS/UEFI reboot. If a threat actor gains `root` access on a live host, they could use `kexec` to boot a custom kernel patched with rootkits, completely bypassing UEFI Secure Boot signature validation (which only runs on physical cold/warm restarts). Setting `kernel.kexec_load_disabled = 1` permanently disables the `kexec_load` and `kexec_file_load` system calls until the next full system reboot.

---

#### Module 4 Answers

1. **S3 Object Lock Compliance Mode Immunity**:
   - **Answer**: Compliance Mode enforces strict, immutable retention periods at the cloud storage API layer that cannot be bypassed, altered, or deleted by any user—including root accounts or account owners.
   - **Detailed Technical Explanation**: In S3 Object Lock, **Governance Mode** allows users with special IAM permissions (`s3:BypassGovernanceRetention`) to alter retention settings or delete objects. However, **Compliance Mode** completely locks the object lifecycle rules. Neither the compromised server IAM credentials, the AWS account root user, nor AWS Support can overwrite or delete objects locked in Compliance Mode before the retention period expires. Even if ransomware steals complete administrative cloud credentials, the underlying S3 API rejects all `DeleteObject` and `PutObjectRetention` requests for locked objects.

2. **`mdadm` Sync Actions (`check` vs `repair`)**:
   - **Answer**: `check` performs a non-destructive audit of array parity and logs discrepancies, whereas `repair` actively rewrites parity blocks based on the first operational mirror drive.
   - **Detailed Technical Explanation**: 
     - Writing `check` to `/sys/block/mdX/md/sync_action` reads all blocks across RAID mirrors/stripes, calculates expected parity, and increments `/sys/block/mdX/md/mismatch_cnt` whenever a mismatch (silent corruption) is detected. It **does not modify disk data**.
     - Writing `repair` instructs `mdadm` to recalculate parity upon detecting a mismatch and **overwrite** the inconsistent block on the parity/secondary drive with data read from the primary drive. `check` is safest for routine monitoring, allowing SREs to investigate disk hardware health before authorizing potentially destructive repair writes.

</details>