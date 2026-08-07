# LPI Security Essentials (020-100) — Topic 3.1: Node, Device and Storage Security

## 1. Motivation & Production Architectural Problem

In cloud-native platform engineering and modern infrastructure operations, node, device, and storage security form the fundamental baseline of the operational trust boundary. An insecure host environment invalidates all higher-layer abstractions, including container runtimes, service meshes, and identity providers. 

Production host infrastructure faces multi-dimensional threat vectors operating across physical, kernel, block-storage, and user-space domains:

1. **Physical & Firmware Tampering:** Unauthorized physical access or compromise of the Unified Extensible Firmware Interface (UEFI) environment can bypass operating system authentication, substitute the OS kernel, or extract sensitive secrets directly from non-volatile memory via Cold Boot attacks or Direct Memory Access (DMA) exploits.
2. **Data-at-Rest Exposure & Theft:** Storage volumes (NVMe, SSDs, SAN block devices, cloud persistent disks) decommissioned, improperly sanitized, stolen, or accessed out-of-band expose raw unencrypted blocks containing cryptographic material, secrets, application state, and compliance-sensitive records.
3. **Host Application Privilege Escalation & Container Escape:** Compromised user-space processes running with elevated kernel capabilities or unconfined Linux security modules (AppArmor/SELinux) can perform system-call hijacking, modify host kernel parameters (`/proc/sys`), or read sensitive device nodes (`/dev/mem`, `/dev/kmem`).
4. **Malware Persistence & File Integrity Violation:** Malicious binaries (rootkits, trojans, ransomware) establishing persistence in non-volatile system paths (`/usr/bin`, `/lib64`, kernel modules) corrupt node execution contexts and undermine workload isolation.
5. **Data Availability & Integrity Catastrophes:** Storage controller failures, silent bit rot, split-brain replication, or uncoordinated snapshot executions cause catastrophic data loss, unacceptable Recovery Time Objectives (RTO), and high Recovery Point Objectives (RPO).

### Zero Trust Host & Storage Architecture Blueprint

```
+-----------------------------------------------------------------------------------+
|                              HARDWARE ROOT OF TRUST                               |
|       [ TPM 2.0 ] ---> [ UEFI Secure Boot ] ---> [ Measured Boot (MOK/PCR) ]      |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                             STORAGE SECURITY LAYER                                |
|   [ dm-crypt / LUKS2 ] <--- Clevis / systemd-cryptenroll (Bound to TPM PCR 7/11)  |
|   [ dm-verity / Read-Only Root FS ] <--- Cryptographic Block Integrity Check      |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                              KERNEL & ISOLATION LAYER                             |
|  [ Linux Security Modules: AppArmor / SELinux ] <---> [ Seccomp Syscall Filters ] |
|  [ Namespaces & cgroups v2 ] <---> [ Hardware-Enforced Control Flow (CET/SMEP) ]  |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                           WORKLOAD & DATA AVAILABILITY                            |
|  [ Immutable Container Workloads ] <---> [ Velero / ZFS Offsite Air-Gapped Backup]|
+-----------------------------------------------------------------------------------+
```

Architecting production nodes requires enforcing a continuous chain of trust: hardware measurements (TPM 2.0) validate the boot state before releasing encryption keys for block storage (LUKS2/dm-crypt), followed by enforcing strict system call and file access policies (AppArmor/Seccomp) on applications, backed by automated, cryptographically signed, offsite backups.

---

## 2. Technical Comparison & Trade-off Tables

### Table 3.1.1: Block vs. File vs. Cloud Storage Encryption Mechanisms

| Metric / Dimension | LUKS2 / dm-crypt (Full Disk Encryption) | fscrypt (Linux Kernel File-Based Encryption) | Cloud Managed Storage (AWS EBS / GCP Persistent Disk) | dm-verity (Kernel Block Integrity) |
| :--- | :--- | :--- | :--- | :--- |
| **Layer of Operation** | Block device layer (`/dev/mapper`) | File system layer (ext4, f2fs) | Hypervisor / Storage Fabric layer | Block device layer (Read-only verification) |
| **Granularity** | Entire partition / volume | Per-directory / Per-file | Entire virtual volume | Entire partition / image |
| **Key Management** | Master Key wrapped by Key Slots (TPM2, Passphrase, Keyfile) | Per-user / Per-directory cryptographic keys via `keyctl` | Cloud KMS (Envelope Encryption, automatic rotation) | Hash tree root signature verified against kernel public key |
| **Performance Impact** | Low CPU overhead (AES-NI hardware acceleration ~2-5%) | Extremely low, applies only to targeted paths | Zero host CPU overhead (offloaded to hypervisor) | Moderate read overhead due to merkle-tree hashing (~5-10%) |
| **Cold Boot Resistance** | High (if combined with TPM 2.0 PCR binding) | Medium (keys cached in kernel keyring during user session) | High against physical disk theft; Low against compromised hypervisor | N/A (Focuses on integrity, not confidentiality) |
| **Metadata Protection** | Protects file names, directory structures, file sizes, timestamps | Protects file content and names; directory structure remains readable | Full protection at block level | Full integrity protection of block layout |
| **Production Use Case** | Bare-metal hosts, edge nodes, local NVMe drives | Multi-tenant home directories, container ephemeral volumes | Cloud-native VMs, managed K8s worker nodes | Immutable OS images (Talos Linux, Android, ChromeOS) |

---

### Table 3.1.2: Host Application Isolation & Sandboxing Paradigms

| Paradigm | Control Mechanisms | Performance Overhead | Syscall Attack Surface | Isolation Strength | Implementation Complexity |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Standard Linux Containers** | Namespaces (`mnt`, `pid`, `net`) + cgroups v2 | Near Zero (< 1%) | Full Shared Kernel (~350+ syscalls exposed) | Low to Medium | Low (Docker, containerd default) |
| **Hardened Containers (LSM + Seccomp)** | Namespaces + cgroups v2 + AppArmor/SELinux + Seccomp-BPF | Very Low (< 2%) | Filtered Kernel (~80-120 allowed syscalls) | High | Medium to High (Policy creation required) |
| **User-Space Kernel Sandbox (gVisor)** | Sentry interceptor translating syscalls to Go user-space | Moderate to High (10-30% I/O overhead) | Restricted to ~70 sanitized host syscalls | Very High | Medium |
| **MicroVM Isolation (Firecracker / KVM)** | KVM Hypervisor + Minimal VMM | Low to Moderate (5-15% memory/I/O cost) | Isolated Virtualized Kernel Instance | Maximum (Hardware-assisted virtualization) | High |

---

### Table 3.1.3: Storage Availability & Backup Architectures

| Architecture | RTO (Recovery Time Objective) | RPO (Recovery Point Objective) | Blast Radius Resilience | Storage Overhead | Ransomware Protection |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **RAID 10 (Striped Mirrors)** | Seconds (Automatic transparent failover) | Zero (Synchronous block mirror) | Single drive failure within mirror pair | 100% (Requires 2x raw capacity) | None (Deletions instantly mirrored) |
| **ZFS / Btrfs Local Copy-on-Write Snapshots** | Minutes (Instant local rollbacks) | Minutes to Hours | Protects against local software corruption | Low (Pointer-based, delta storage) | Low (Local snapshots can be deleted by compromised root) |
| **Block-Level Asynchronous Replication (DRBD)** | Minutes (Manual/Automated failover) | Seconds to Minutes | Protects against total host/chassis loss | 100% (Requires remote target capacity) | Low to Medium (Replicates corruptions rapidly) |
| **Air-Gapped Object Storage Backups (Velero / Restic)** | Hours to Days (Requires node re-provisioning) | Hours (Scheduled snapshot intervals) | Complete node, datacenter, and region loss | Moderate (Deduplicated, compressed) | Maximum (Enforced via Object Lock / Write Once Read Many) |

---

## 3. Complete Production Infrastructure Manifests & Configurations

### 3.1 Automated TPM2-Bound LUKS2 Volume Provisioning (`systemd-cryptsetup` & Clevis)

The following manifest and configuration files establish an automated, hardware-attested, encrypted storage volume mounted at `/var/lib/containerd` using TPM 2.0 PCRs (PCR 7 for Secure Boot state, PCR 11 for unified kernel image integrity).

#### File 1: `/etc/crypttab`
```etc
# /etc/crypttab: Production LUKS2 Volume Configuration
# Mapping Name         UUID                                     Keyfile Path                             Cryptsetup Options
var-lib-containerd     UUID=c49a3182-8d76-4a41-b0e6-123456789abc none                                     tpm2-device=auto,tpm2-pcrs=7+11,cipher=aes-xts-plain64,key-size=512,hash=sha512,discard
```

#### File 2: `/etc/systemd/system/var-lib-containerd.mount`
```ini
[Unit]
Description=Mount Encrypted Production Containerd Storage Directory
Documentation=https://github.com/containerd/containerd
After=systemd-cryptsetup@var-lib-containerd.service
BindsTo=systemd-cryptsetup@var-lib-containerd.service

[Mount]
What=/dev/mapper/var-lib-containerd
Where=/var/lib/containerd
Type=ext4
Options=defaults,noatime,nodev,nosuid,errors=remount-ro

[Install]
WantedBy=multi-user.target
```

#### File 3: Hardware Encryption & Provisioning Automation Script (`/usr/local/bin/provision-secure-storage.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DEVICE="/dev/nvme1n1"
MAPPER_NAME="var-lib-containerd"
MOUNT_POINT="/var/lib/containerd"
KEY_FILE="/etc/keys/luks-recovery.key"

echo "=== [1/5] Creating Secure Recovery Key Directory ==="
mkdir -p -m 0700 /etc/keys
dd if=/dev/urandom of="${KEY_FILE}" bs=64 count=1 status=none
chmod 0400 "${KEY_FILE}"

echo "=== [2/5] Formatting LUKS2 Volume on ${TARGET_DEVICE} ==="
cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --use-urandom \
    --label CONTAINER_DATA \
    --batch-mode \
    "${TARGET_DEVICE}" \
    "${KEY_FILE}"

echo "=== [3/5] Binding LUKS2 Key Slot to TPM 2.0 (PCR 7 + 11) ==="
systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=7+11 \
    --tpm2-with-pin=no \
    "${TARGET_DEVICE}"

echo "=== [4/5] Opening Encrypted Mapping ==="
cryptsetup open "${TARGET_DEVICE}" "${MAPPER_NAME}" --key-file "${KEY_FILE}"

echo "=== [5/5] Creating Filesystem and Mounting ==="
mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 -L containerd-data "/dev/mapper/${MAPPER_NAME}"
mkdir -p "${MOUNT_POINT}"
mount -o defaults,noatime,nodev,nosuid "/dev/mapper/${MAPPER_NAME}" "${MOUNT_POINT}"

echo "SUCCESS: Hardware-bound encrypted volume provisioned and mounted."
```

---

### 3.2 Production Application Isolation Security Manifests

To isolate host applications and container runtimes, we combine AppArmor profiles, strict Seccomp syscall filtering, and Kubernetes Pod Security Standards (`Restricted` profile).

#### File 1: Host AppArmor Profile (`/etc/apparmor.d/usr.bin.production-workload`)
```apparmor
#include <tunables/global>

profile production-workload /usr/bin/production-workload flags=(attach_disconnected,enforce) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # Network Restrictions: Allow outbound TCP socket creation only
  network inet stream,
  network inet6 stream,
  deny network raw,
  deny network dgram,

  # Capabilities Restrictions: Drop all dangerous kernel capabilities
  deny capability sys_admin,
  deny capability sys_ptrace,
  deny capability sys_module,
  deny capability sys_rawio,
  deny capability dac_override,
  deny capability setuid,
  deny capability setgid,

  # File System Access Rules (Explicit White-listing)
  /usr/bin/production-workload mr,
  /etc/ssl/certs/** r,
  /etc/hosts r,
  /etc/resolv.conf r,
  /var/log/production-workload/*.log w,
  /tmp/ rw,
  /tmp/** rw,

  # Explicit Denials for Host Isolation
  deny /proc/sys/** w,
  deny /sys/** w,
  deny /etc/shadow* rw,
  deny /etc/passwd* w,
  deny /root/** rw,
  deny /dev/sd* rw,
  deny /dev/nvme* rw,
}
```

#### File 2: Production Seccomp Profile (`/var/lib/kubelet/seccomp/profiles/strict-microservice.json`)
```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept4",
        "access",
        "arch_prctl",
        "bind",
        "brk",
        "clock_gettime",
        "clone3",
        "close",
        "connect",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "execve",
        "exit",
        "exit_group",
        "fcntl",
        "fstat",
        "futex",
        "getdents64",
        "getpid",
        "getrandom",
        "getsockopt",
        "listen",
        "lseek",
        "madvise",
        "mmap",
        "mprotect",
        "munmap",
        "newfstatat",
        "pipe2",
        "poll",
        "read",
        "readlink",
        "recvfrom",
        "rseq",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "sched_yield",
        "sendto",
        "set_robust_list",
        "setsockopt",
        "socket",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

#### File 3: Kubernetes Workload Security Manifest (`hardened-workload.yaml`)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-api-gateway
  namespace: production
  labels:
    app.kubernetes.io/name: secure-api-gateway
    security.cncf.io/tier: restricted
spec:
  replicas: 3
  selector:
    matchLabels:
      app: secure-api-gateway
  template:
    metadata:
      labels:
        app: secure-api-gateway
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/strict-microservice.json
      containers:
        - name: gateway
          image: registry.production.internal/gateway:v2.4.1
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "1"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "128Mi"
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: log-volume
              mountPath: /var/log/gateway
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: log-volume
          emptyDir:
            sizeLimit: 128Mi
```

---

### 3.3 Data Availability & Automated Backup Manifests (Velero & ZFS Engine)

#### File 1: Velero BackupStorageLocation Manifest (`velero-bsl-s3-immutable.yaml`)
```yaml
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: aws-s3-airgapped-immutable
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: prod-k8s-backups-immutable-us-east-1
    prefix: cluster-alpha
  config:
    region: us-east-1
    s3ForcePathStyle: "false"
    checksumAlgorithm: "SHA256"
  credential:
    name: cloud-credentials
    key: cloud
  accessMode: ReadWrite
  backupSyncPeriod: 30m0s
```

#### File 2: Velero Schedule Custom Resource (`velero-schedule-stateful.yaml`)
```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: stateful-workloads-hourly
  namespace: velero
spec:
  schedule: "0 * * * *"
  template:
    ttl: 720h0m0s
    includedNamespaces:
      - production-databases
      - stateful-services
    includedResources:
      - PersistentVolumeClaim
      - PersistentVolume
      - StatefulSet
      - Secret
      - ConfigMap
    storageLocation: aws-s3-airgapped-immutable
    snapshotVolumes: true
    defaultVolumesToFsBackup: false
    hooks:
      resources:
        - name: postgresql-quiesce
          includedNamespaces:
            - production-databases
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: postgresql
          pre:
            - exec:
                container: postgresql
                command:
                  - /bin/sh
                  - -c
                  - "psql -U postgres -c 'SELECT pg_backup_start(\"velero-snapshot\", true);'"
                onError: Fail
          post:
            - exec:
                container: postgresql
                command:
                  - /bin/sh
                  - -c
                  - "psql -U postgres -c 'SELECT pg_backup_stop();'"
                onError: Log
```

#### File 3: Automated ZFS Snapshot & Offsite Replication Daemon (`/usr/local/bin/zfs-backup-daemon.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

POOL_NAME="tank/production-data"
REMOTE_BACKUP_SERVER="backup-node01.infra.internal"
REMOTE_POOL="backup_tank/nodes/node01"
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
SNAPSHOT_NAME="${POOL_NAME}@auto_${TIMESTAMP}"

echo "=== [1/3] Creating Local Atomic ZFS Snapshot: ${SNAPSHOT_NAME} ==="
zfs snapshot "${SNAPSHOT_NAME}"

echo "=== [2/3] Streaming Snapshot to Remote Air-Gapped Backup Node ==="
LATEST_COMMON_SNAP=$(zfs list -t snapshot -o name -H -s creation | grep "${POOL_NAME}@" | tail -n 2 | head -n 1 || true)

if [ -n "${LATEST_COMMON_SNAP}" ]; then
    echo "Performing Incremental Replication from ${LATEST_COMMON_SNAP} to ${SNAPSHOT_NAME}..."
    zfs send -i "${LATEST_COMMON_SNAP}" "${SNAPSHOT_NAME}" | ssh -i /etc/keys/backup_ed25519 "root@${REMOTE_BACKUP_SERVER}" "zfs recv -F ${REMOTE_POOL}"
else
    echo "Performing Full Initial Replication of ${SNAPSHOT_NAME}..."
    zfs send "${SNAPSHOT_NAME}" | ssh -i /etc/keys/backup_ed25519 "root@${REMOTE_BACKUP_SERVER}" "zfs recv -F ${REMOTE_POOL}"
fi

echo "=== [3/3] Enforcing Retention Policy (Pruning Snapshots > 30 Days) ==="
zfs list -t snapshot -o name,creation -H | grep "${POOL_NAME}@auto_" | while read -r SNAP CREATED; do
    SNAP_EPOCH=$(date -d "${CREATED}" +%s 2>/dev/null || stat -c %Y "/dev/zvol/${SNAP}" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE_DAYS=$(( (NOW_EPOCH - SNAP_EPOCH) / 86400 ))
    if [ "${AGE_DAYS}" -gt 30 ]; then
        echo "Pruning expired snapshot: ${SNAP} (Age: ${AGE_DAYS} days)"
        zfs destroy "${SNAP}"
    fi
done

echo "SUCCESS: ZFS availability pipeline execution completed."
```

---

## 4. Real CLI Commands & Terminal Output ($)

### 4.1 Auditing UEFI Secure Boot, TPM 2.0 PCR State, and LUKS Encryption Status

```bash
$ bootctl status
```
```text
System:
     Firmware: UEFI 2.70 (Lenovo 1.45)
  Firmware Arch: x86-64
    Secure Boot: enabled (user-mode)
   Current Boot: 0001
    Boot Loader: systemd-boot 255.4-1-arch

Kernel:
    Machine ID: e9f38a104b9c467fa1289123456789ab
       Systemd: systemd 255 (255.4-1-arch)

Current Boot Loader Entry:
          title: Linux Production Kernel (Unified Kernel Image)
            id: linux-uki-production.conf
         source: /EFI/Linux/linux-uki-production.efi
```

```bash
$ tpm2_pcrread sha256:7,11
```
```text
sha256:
  7 : 0xB4D98C4E78120A9C1283F89A0123456789ABCDEF0123456789ABCDEF01234567
  11: 0x7E3A91280B4C129A847120398127391827391827391827391827391827391827
```

```bash
$ cryptsetup status var-lib-containerd
```
```text
/dev/mapper/var-lib-containerd is active and is in use.
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: keyring
  device:  /dev/nvme1n1
  sector size:  512 bytes
  offset:  32768 sectors
  size:    1875350000 sectors
  mode:    read/write
  flags:   discards 
```

```bash
$ cryptsetup luksDump /dev/nvme1n1
```
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 bytes
Keyslots:
  0: luks2
	Key:        512 bits
	Priority:   normal
	Cipher:     aes-xts-plain64
	PBKDF:      argon2id
	Time cost:  4
	Memory:     1048576
	CPUs:       4
  1: systemd-tpm2
	Key:        512 bits
	Priority:   normal
	TPM2 PCRs:  7,11
	TPM2 Primary Policy: abc123def4567890...
Data area:
  offset: 16777216 bytes
  encryption: aes-xts-plain64
```

---

### 4.2 Verifying Application Isolation (AppArmor & Seccomp Engine)

```bash
$ aa-status
```
```text
apparmor module is loaded.
42 profiles are loaded.
38 profiles are in enforce mode.
   /usr/bin/production-workload
   /usr/sbin/named
   /usr/sbin/dhcpd
   cri-containerd-default
4 profiles are in complain mode.
   /usr/bin/legacy-telemetry
0 processes have profiles defined.
3 processes are in enforce mode.
   /usr/bin/production-workload (14209)
   /usr/bin/production-workload (14210)
   /usr/bin/production-workload (14211)
```

```bash
$ journalctl -k --grep="audit" --no-pager -n 5
```
```text
Aug 07 01:15:22 node-01 audit[14209]: AVC apparmor="DENIED" operation="open" profile="/usr/bin/production-workload" name="/etc/shadow" pid=14209 comm="worker" requested_mask="r" denied_mask="r" fsuid=10001 ouid=0
Aug 07 01:15:23 node-01 audit[14209]: SECCOMP auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=14209 comm="worker" exe="/usr/bin/production-workload" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f9a8123b41a code=0x0
```

---

### 4.3 Verifying Storage Availability, ZFS Health, & Velero Backup State

```bash
$ zpool status tank
```
```text
  pool: tank
 state: ONLINE
  scan: scrub repaired 0B in 01:24:12 with 0 errors on Thu Aug  6 04:00:00 2026
config:

	NAME                        STATE     READ WRITE CKSUM
	tank                        ONLINE       0     0     0
	  mirror-0                  ONLINE       0     0     0
	    nvme0n1p2               ONLINE       0     0     0
	    nvme1n1p2               ONLINE       0     0     0
	  mirror-1                  ONLINE       0     0     0
	    nvme2n1p2               ONLINE       0     0     0
	    nvme3n1p2               ONLINE       0     0     0

errors: No known data errors
```

```bash
$ velero backup get
```
```text
NAME                                STATUS      ERRORS   WARNINGS   CREATED                         EXPIRES   STORAGE LOCATION             SELECTOR
stateful-workloads-hourly-20260807010000   Completed   0        0          2026-08-07 01:00:00 -0400 EDT   29d       aws-s3-airgapped-immutable   <none>
stateful-workloads-hourly-20260807000000   Completed   0        0          2026-08-07 00:00:00 -0400 EDT   29d       aws-s3-airgapped-immutable   <none>
```

```bash
$ velero backup describe stateful-workloads-hourly-20260807010000
```
```text
Name:         stateful-workloads-hourly-20260807010000
Namespace:    velero
Labels:       velero.io/schedule-name=stateful-workloads-hourly
Annotations:  velero.io/resource-timeout=10m0s

Phase:  Completed

Namespaces:
  Included:  production-databases, stateful-services
  Excluded:  <none>

Resources:
  Included:  PersistentVolumeClaim, PersistentVolume, StatefulSet, Secret, ConfigMap
  Excluded:  <none>

Storage Location:  aws-s3-airgapped-immutable

Velero-Native Snapshots:  Enabled

Hooks:
  Exec:
    Number of targeted pods: 2

Volume Snapshots:
  PersistentVolumeClaim: production-databases/data-postgresql-0
    Snapshot ID:        snap-0a1b2c3d4e5f67890
    Type:               aws-ebs
    Availability Zone:  us-east-1a
    IOPS:               3000
```

---

## 5. Verification & Failure Diagnostic Guide

```
+-----------------------------------------------------------------------------------+
|                        PRODUCTION TROUBLESHOOTING TREE                            |
+-----------------------------------------------------------------------------------+
                                         |
                       [ Event Triggered / Failure State ]
                                         |
                +------------------------+------------------------+
                |                                                 |
                v                                                 v
   [ Storage / Boot Failure ]                       [ Workload Execution Failure ]
                |                                                 |
   +------------+------------+                       +------------+------------+
   |                         |                       |                         |
   v                         v                       v                         v
[LUKS Unlock Fails]    [ZFS / Array Fault]    [AppArmor Denial]        [Seccomp SIGSYS]
   |                         |                       |                         |
   v                         v                       v                         v
Check TPM PCR 7/11    Run `zpool status`     Inspect `dmesg`          Parse `audit.log`
Mismatches via MOK    Replace Faulty Disk    Identify AVC Rule        Find Syscall ID
Update `cryptenroll`  Trigger `zpool replace` Append Path Rule         Update Seccomp List
```

### Scenario A: LUKS2 Boot Unlock Failure due to TPM PCR Mismatch

#### Root Cause
A firmware upgrade, EFI driver load, or Secure Boot certificate update modified the hash state of PCR 7 (Secure Boot state) or PCR 0 (System Firmware). As a result, the TPM 2.0 sealed secret refuses to unseal the LUKS2 volume key.

#### Diagnostic Workflow
1. Reboot the host into the Emergency Recovery Shell or Live OS.
2. Verify physical TPM status and measure PCR state:
   ```bash
   tpm2_pcrread sha256:7,11
   ```
3. Attempt manually unsealing or unwrap using the recovery passphrase/keyfile:
   ```bash
   cryptsetup open /dev/nvme1n1 var-lib-containerd --key-file /etc/keys/luks-recovery.key
   ```
4. Re-bind the TPM 2.0 key slot to the newly updated PCR state:
   ```bash
   # Remove old TPM2 slot (Slot 1)
   systemd-cryptenroll --tpm2-device=list /dev/nvme1n1
   cryptsetup luksKillSlot /dev/nvme1n1 1

   # Re-enroll with current PCR policy
   systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11 /dev/nvme1n1
   ```

---

### Scenario B: Host Application Crash Caused by Seccomp/AppArmor Violation

#### Root Cause
A newly deployed version of a binary or container image invoked an un-whitelisted system call (e.g., `clone3`, `epoll_pwait2`) or attempted to read a restricted path (`/sys/devices`), resulting in kernel signal termination (`SIGSYS` code 31).

#### Diagnostic Workflow
1. Inspect kernel ring buffer for Seccomp violations:
   ```bash
   dmesg -T | grep -i "seccomp"
   ```
   *Output Example:*
   `[Fri Aug 7 01:20:11 2026] audit: type=1326 audit(1786166411.102:44): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=18902 comm="gateway" exe="/usr/bin/gateway" sig=31 arch=c000003e syscall=435 compat=0 ip=0x7f920`

2. Translate the architecture code (`c000003e` = x86_64) and system call number (`435`) to human-readable format using `ausyscall`:
   ```bash
   ausyscall x86_64 435
   ```
   *Output:*
   `clone3`

3. Modify `/var/lib/kubelet/seccomp/profiles/strict-microservice.json` to include `clone3` within the allowed array, and re-apply the manifest.

---

### Scenario C: Persistent Volume Snapshot Backup Failure (Velero Quiesce Timeout)

#### Root Cause
Pre-snapshot database quiescence hooks (`pg_backup_start()`) hung due to uncommitted long-running transactions or lock contention, exceeding the Velero hook execution limit (default 10 minutes).

#### Diagnostic Workflow
1. Inspect Velero backup pod execution logs:
   ```bash
   velero backup logs stateful-workloads-hourly-20260807010000 --namespace velero | grep -i "error"
   ```
2. Inspect target workload container stderr logs:
   ```bash
   kubectl logs -n production-databases postgresql-0 -c postgresql --tail=100
   ```
3. Remediate by setting an explicit statement timeout for the backup session in the hook manifest:
   ```bash
   psql -U postgres -c 'SET statement_timeout = "30s"; SELECT pg_backup_start("velero-snapshot", true);'
   ```

---

## 6. References

- Linux Professional Institute (LPI) Security Essentials Overview:  
  https://www.lpi.org/our-certifications/security-essentials-overview/
- LPI Security Essentials (020-100) Detailed Objectives V1.0:  
  https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0
- Cryptsetup and dm-crypt On-Disk Format Specification (LUKS2):  
  https://gitlab.com/cryptsetup/cryptsetup/-/wikis/LUKS-standard/LUKS2-architecture.pdf
- Trusted Computing Group (TCG) TPM 2.0 Library Specification:  
  https://trustedcomputinggroup.org/resource/tpm-library-specification/
- Linux Kernel AppArmor Documentation & Profile Architecture:  
  https://apparmor.net/
- Kubernetes Pod Security Standards & Seccomp Integration:  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Velero Cloud-Native Backup & Disaster Recovery Architecture:  
  https://velero.io/docs/