# 104.2 — Maintain the Integrity of Filesystems

**Certification:** LPIC-1 (Exams 101-500 / 102-500, version 5.0)
**Topic:** 104.2 — Maintain the integrity of filesystems
**Exam weight:** 3.12
**Level:** Advanced — Platform Architect / SRE

**Objective scope (LPI):**
- Verify the integrity of filesystems
- Monitor free space and inodes
- Repair simple filesystem problems

**Terms and utilities:** `du`, `df`, `fsck`, `e2fsck`, `mke2fs`, `tune2fs`, `xfs_repair`, `xfs_fsr`, `xfs_db`

---

## 1. Motivation: the production architectural problem

A filesystem is not a bag of bytes. It is an on-disk **database** with its own transaction log, allocation bitmaps, reference counts and invariants. Every one of the following invariants must hold, and every one of them can be violated by a power cut, a firmware bug, a misbehaving RAID controller, a truncated iSCSI session, or a kernel bug:

1. Every allocated block belongs to **exactly one** inode (or to metadata).
2. Every inode's `i_links_count` equals the number of directory entries pointing at it.
3. Every directory entry points at an in-use inode.
4. Every in-use inode is reachable from the root inode (or from `lost+found`).
5. The free-block and free-inode counters in the superblock/AG headers match reality.

Filesystem integrity work in production splits into three failure classes that operators routinely confuse:

| Failure class | Root cause | What it looks like | Correct response |
|---|---|---|---|
| **Space exhaustion** | Capacity planning / runaway writer | `ENOSPC` (`No space left on device`), writes fail, app crashes, DB refuses to start | `df`, `du`, `lsof +L1` → reclaim. **Never** run `fsck` |
| **Inode exhaustion** | Millions of tiny files, geometry chosen at `mkfs` time | `ENOSPC` **with** free blocks visible in `df -h` | `df -i`, find the offender directory, reclaim or rebuild the fs |
| **Metadata corruption** | Power loss, storage stack bug, dying media | `EIO`/`EUCLEAN` (`Structure needs cleaning`), fs remounted read-only, `dmesg` errors | Take offline, image it, `e2fsck`/`xfs_repair` |

The architectural mistake made most often is applying the third response to the first problem. **`fsck` does not free space and does not fix a full filesystem.** Running a repair tool on a mounted filesystem, or running it "just in case" on healthy media that is merely full, is how a recoverable incident becomes a restore-from-backup incident.

The second architectural mistake is treating an integrity check as something that happens at boot. On a 40 TiB XFS volume, an offline `xfs_repair` is a multi-hour, memory-hungry, **downtime** operation. In a modern platform, integrity is *continuously verified online* (`e2scrub`, `xfs_scrub`, LVM-snapshot checks, metadata checksums) and *continuously monitored* (free space, free inodes, superblock error counters, read-only remounts) so that offline repair is a planned event, not a surprise.

### The reserved-block invariant

`mke2fs` reserves 5% of the blocks for UID 0 by default. This is not superstition, it serves two distinct purposes:

1. **Operational escape hatch** — when a filesystem hits 100% for unprivileged writers, root can still log in, rotate logs, write to `/var/log` and run recovery tooling. On `/`, a filesystem with 0% reserved that fills completely is often unrecoverable without a rescue boot, because `sshd` cannot write its session files.
2. **Allocator headroom** — extent-based allocators degrade badly near full. A filesystem driven past ~95% suffers severe free-space fragmentation; the allocator spends more time searching and the extent count per file explodes.

On a 12 TiB data volume, 5% is 600 GiB of stranded capacity, so tuning it down to 1% is a legitimate production decision — but **only** on a filesystem that holds no system state and is monitored.

---

## 2. Technical comparisons and trade-offs

### 2.1 Repair and verification model per filesystem

| Property | ext4 | XFS | Btrfs |
|---|---|---|---|
| Consistency mechanism | jbd2 journal (metadata; optionally data) | Internal write-ahead log (metadata only) | Copy-on-Write, no journal |
| Offline repair tool | `e2fsck` (`fsck.ext4`) | `xfs_repair` | `btrfs check --repair` (last resort) |
| Boot-time `fsck` | Yes — `fsck.ext4` via `systemd-fsck@.service` | **No** — `/usr/sbin/fsck.xfs` is a stub that exits 0 | No |
| Online consistency check | `e2scrub` (LVM snapshot + `e2fsck -fn`) | `xfs_scrub` (native online scrub) | `btrfs scrub` (verifies checksums) |
| Metadata checksums | `metadata_csum` feature (default since e2fsprogs 1.43) | `crc=1` (default since xfsprogs 3.2.3) | Always on |
| **Data** checksums | No | No | Yes (crc32c/xxhash/blake2) |
| Grow online | Yes (`resize2fs`) | Yes (`xfs_growfs`) | Yes |
| Shrink | Yes, **offline only** | **Never supported** | Yes, online |
| Repair memory cost | Modest, bounded by inode count | High — `xfs_repair` may need GiB; use `-m` / `-P` | High |
| Repairs while mounted | Never | Never (`xfs_repair` refuses) | Never |
| Typical platform role | Root volumes, general purpose, `/boot` | Large data volumes, RHEL default root, high parallel I/O | Snapshot-centric workloads |

**Architect's reading of this table:** if `fsck.xfs` is a no-op, then `passno` in `/etc/fstab` is meaningless for XFS and an XFS root volume gets *zero* boot-time verification. The XFS design position is that the log replay at mount time is the recovery mechanism, and that a full structural check is an explicit, operator-initiated event. That is a correct design — but it means your monitoring, not your boot sequence, is the thing that will tell you an XFS volume is sick.

### 2.2 `df` vs `du` — two different questions

| | `df` | `du` |
|---|---|---|
| Data source | Superblock / AG headers via `statfs(2)` | Walks the directory tree, `stat(2)`s every entry |
| Question answered | "How many blocks does the *filesystem* think are allocated?" | "How many blocks are reachable through *this path*?" |
| Cost | O(1), microseconds | O(number of files), minutes on large trees |
| Sees deleted-but-open files | **Yes** (still allocated) | **No** (unlinked, unreachable) |
| Sees files hidden under a mountpoint | Yes | No (walks the *upper* mount) |
| Sees other filesystems | One row each | Yes, unless `-x` is given |
| Sparse files | Counts allocated blocks | Counts allocated blocks — unless `--apparent-size` |
| Respects reserved blocks | Yes (`Avail` excludes them; `Use%` is relative to non-reserved) | N/A |

Every `du` vs `df` discrepancy in production reduces to one of five causes:

| Symptom | Cause | Proof |
|---|---|---|
| `df` >> `du` | Deleted files held open by a process | `lsof -nP +L1` |
| `df` >> `du` | Files shadowed by a later mount over a populated directory | `mount --bind / /mnt && du -xsh /mnt/var` |
| `df` >> `du` | `du` run without root, skipping unreadable directories | Run as root, check stderr |
| `du` >> `df` reported "size" | Hard links counted once by `du`, or sparse files | `du --apparent-size`, `find -links +1` |
| Both look fine, writes still fail | Inodes exhausted, or quota, or reserved blocks | `df -i`, `repquota`, `tune2fs -l` |

### 2.3 `fsck` exit codes (bitmask — the exam tests this, and so does your automation)

| Code | Meaning |
|---|---|
| 0 | No errors |
| 1 | Filesystem errors corrected |
| 2 | Filesystem errors corrected, **system should be rebooted** |
| 4 | Filesystem errors left **uncorrected** |
| 8 | Operational error |
| 16 | Usage or syntax error |
| 32 | Checking canceled by user request |
| 128 | Shared-library error |

`fsck` on multiple filesystems returns the **bitwise OR** of the per-filesystem codes. A wrapper script that tests `if [ $? -eq 0 ]` will treat exit 1 (successfully repaired) as a failure and exit 5 (`1|4`, "some fixed, some not") the same as exit 4. Test the bits:

```bash
fsck -A -a
rc=$?
(( rc & 4 )) && echo "UNCORRECTED ERRORS — do not boot into production" >&2
(( rc & 2 )) && echo "reboot required" >&2
(( rc == 0 || rc == 1 )) && echo "clean"
```

### 2.4 ext4 error behaviour — the single most important tunable

| `errors=` value | Kernel behaviour on metadata error | When to use |
|---|---|---|
| `continue` | Log the error, keep going | Almost never — propagates corruption |
| `remount-ro` | Immediately remount read-only, preserve on-disk state | **Default choice for every production volume** |
| `panic` | Kernel panic | HA clusters where a fenced reboot is safer than a live degraded node |

`remount-ro` converts silent data corruption into a loud, contained, diagnosable outage. The application starts throwing `EROFS`, monitoring fires, and the on-disk damage stops growing. XFS has an equivalent: on serious metadata corruption it performs a **filesystem shutdown** (`XFS (dm-2): Corruption detected. Unmount and run xfs_repair`), after which all I/O returns `EIO` until the volume is unmounted.

### 2.5 `tune2fs` ↔ XFS equivalents

| Task | ext4 | XFS |
|---|---|---|
| Show geometry / features | `tune2fs -l`, `dumpe2fs -h` | `xfs_info /mnt`, `xfs_db -r -c 'sb 0' -c p` |
| Set label | `tune2fs -L data` | `xfs_admin -L data` (unmounted) |
| Set UUID | `tune2fs -U <uuid>` | `xfs_admin -U <uuid>` |
| Force check next boot | `tune2fs -C 100 -c 20` | *(not applicable — no boot fsck)* |
| Error behaviour | `tune2fs -e remount-ro` | `/sys/fs/xfs/<dev>/error/` knobs |
| Reserved space | `tune2fs -m 1` | *(none; use project quotas)* |
| Defragment | `e4defrag` | `xfs_fsr` |
| Inode capacity | fixed at `mke2fs` time | dynamic, capped by `imaxpct` |

---

## 3. Complete infrastructure manifests

### 3.1 `cloud-init` — provisioning a data volume with a defensible geometry

```yaml
#cloud-config
# Provisions a data volume for a metadata-heavy workload (maildir / object cache):
#   - 8 KiB bytes-per-inode instead of the 16 KiB default -> 2x the inodes
#   - reserved blocks cut to 1% (this volume holds no system state)
#   - errors=remount-ro so metadata corruption is contained, not propagated
#   - lazy_itable_init=0 pays the full mkfs cost up front instead of during
#     the first hours of production I/O
bootcmd:
  - [ cloud-init-per, once, mkpart, sgdisk, --new=1:0:0, --typecode=1:8e00, /dev/nvme1n1 ]

runcmd:
  - [ pvcreate, /dev/nvme1n1p1 ]
  - [ vgcreate, vg_data, /dev/nvme1n1p1 ]
  # Leave >=256 MiB free in the VG: e2scrub needs room for its snapshot.
  - [ lvcreate, --name, lv_data, --extents, 95%FREE, vg_data ]
  - |
    mke2fs -t ext4 \
      -L data \
      -m 1 \
      -i 8192 \
      -b 4096 \
      -O metadata_csum,metadata_csum_seed,64bit,dir_index,extent,dir_nlink \
      -E lazy_itable_init=0,lazy_journal_init=0,discard \
      /dev/vg_data/lv_data
  - [ tune2fs, -e, remount-ro, /dev/vg_data/lv_data ]
  - [ tune2fs, -c, "0", -i, "0", /dev/vg_data/lv_data ]
  - [ mkdir, -p, /srv/data ]

mounts:
  - [ "LABEL=data", "/srv/data", "ext4",
      "defaults,noatime,errors=remount-ro,nodev,nosuid", "0", "2" ]

write_files:
  - path: /etc/systemd/system/e2scrub_all.timer.d/override.conf
    content: |
      # Ship the distro's weekly online scrub, but move it off the
      # backup window and stop it racing other nodes in the same rack.
      [Timer]
      OnCalendar=
      OnCalendar=Sun 03:30
      RandomizedDelaySec=1800

runcmd_post:
  - [ systemctl, enable, --now, e2scrub_all.timer ]
```

### 3.2 `/etc/fstab` — the `passno` field is a policy decision

```
# <file system>            <mount point>  <type> <options>                                              <dump> <pass>
UUID=6b1f...  /              ext4   defaults,errors=remount-ro                             0      1
UUID=a3c9...  /boot          ext4   defaults,errors=remount-ro,nodev,nosuid,noexec         0      2
UUID=e7d2...  /var           ext4   defaults,noatime,errors=remount-ro,nodev,nosuid        0      2
LABEL=data                   /srv/data      ext4   defaults,noatime,errors=remount-ro,nodev,nosuid        0      2
LABEL=archive                /srv/archive   xfs    defaults,noatime,nodev,nosuid                          0      0
tmpfs                        /tmp           tmpfs  defaults,noatime,nodev,nosuid,noexec,size=2G,nr_inodes=200k 0 0
```

Rules encoded above:

- **`passno=1`** exactly once, on `/`. It is checked first, alone.
- **`passno=2`** on other ext4 volumes — checked in parallel across *different physical devices* after the root pass.
- **`passno=0`** on XFS (the checker is a no-op) and on `tmpfs`.
- `nr_inodes=200k` on `/tmp`: a `tmpfs` can exhaust *inodes* long before it exhausts its `size=`, and an unbounded `tmpfs` inode count is a memory-exhaustion vector.

### 3.3 Prometheus alerting rules — space, inodes, and integrity

```yaml
groups:
  - name: filesystem-capacity
    interval: 30s
    rules:
      # Rate of change matters more than the instantaneous level: a volume at
      # 60% that is filling at 5 GiB/h will page you at 03:00 unless you know now.
      - alert: FilesystemFillingUp
        expr: |
          (
            node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs",mountpoint!~"/(run|var/lib/kubelet/pods).*"}
              / node_filesystem_size_bytes{fstype=~"ext4|xfs|btrfs"}
          ) < 0.25
          and
          predict_linear(
            node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs"}[6h], 8 * 3600
          ) < 0
          and node_filesystem_readonly == 0
        for: 30m
        labels:
          severity: warning
          runbook: fs-capacity
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} fills within 8h"
          description: >-
            {{ $value | humanizePercentage }} free and trending to zero.
            Run: du -x -h --max-depth=1 {{ $labels.mountpoint }} | sort -h | tail -20

      - alert: FilesystemSpaceCritical
        expr: |
          (
            node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs"}
              / node_filesystem_size_bytes{fstype=~"ext4|xfs|btrfs"}
          ) < 0.05
          and node_filesystem_readonly == 0
        for: 5m
        labels:
          severity: critical
          runbook: fs-capacity
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} below 5% free"
          description: >-
            Extent allocators degrade sharply past 95%. Check for
            deleted-but-open files first: lsof -nP +L1 | grep {{ $labels.mountpoint }}

      # Inode exhaustion is invisible to a bytes-only dashboard and produces
      # the identical ENOSPC errno. It must be a separate alert.
      - alert: FilesystemInodesCritical
        expr: |
          (
            node_filesystem_files_free{fstype=~"ext4|xfs"}
              / node_filesystem_files{fstype=~"ext4|xfs"}
          ) < 0.10
          and node_filesystem_files{fstype=~"ext4|xfs"} > 0
        for: 15m
        labels:
          severity: critical
          runbook: fs-inodes
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} below 10% free inodes"
          description: >-
            ext4 inode counts are fixed at mkfs time and cannot be raised in
            place. Identify the offender:
            find {{ $labels.mountpoint }} -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head

  - name: filesystem-integrity
    interval: 30s
    rules:
      # A read-only remount is the ext4 errors=remount-ro contract firing.
      # It is never routine on a volume mounted rw in fstab.
      - alert: FilesystemRemountedReadOnly
        expr: node_filesystem_readonly{fstype=~"ext4|xfs"} == 1
        for: 2m
        labels:
          severity: critical
          runbook: fs-corruption
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} is read-only"
          description: >-
            Do NOT remount rw. Capture dmesg, drain the node, image the volume,
            then run e2fsck/xfs_repair offline.

      # Exported by the sentinel DaemonSet in 3.5 from the ext4 superblock
      # error counter (dumpe2fs -h). This counter is PERSISTENT: it survives
      # reboots and is only cleared by a successful e2fsck run.
      - alert: FilesystemSuperblockErrorsRecorded
        expr: increase(node_ext4_fs_error_count[24h]) > 0
        labels:
          severity: critical
          runbook: fs-corruption
        annotations:
          summary: "ext4 recorded {{ $value }} new metadata errors on {{ $labels.device }}"

      - alert: FilesystemScrubStale
        expr: |
          (time() - node_filesystem_last_scrub_timestamp_seconds) > 14 * 86400
        labels:
          severity: warning
          runbook: fs-scrub
        annotations:
          summary: "No successful scrub of {{ $labels.device }} in 14 days"

      # Correlate with the hardware layer: never "repair" dying media.
      - alert: DiskReallocatedSectorsGrowing
        expr: increase(smartmon_reallocated_sector_ct_raw_value[24h]) > 0
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.disk }} reallocated sectors growing — replace, do not repair"
```

### 3.4 systemd — online integrity verification via LVM snapshot

`e2fsprogs` ships `e2scrub`/`e2scrub_all` (and `xfsprogs` ships `xfs_scrub_all`), and on a supported distribution those are the correct tools. The unit below is the portable equivalent that covers **both** ext4 and XFS on hosts where you must drive the snapshot yourself.

`/usr/local/sbin/fs-integrity-check`:

```bash
#!/usr/bin/env bash
# Point-in-time consistency check of a MOUNTED filesystem, with no downtime.
#
# Mechanism: take an LVM snapshot (atomic, crash-consistent), replay the
# journal/log into the snapshot by mounting it read-only once, then run the
# repair tool in dry-run mode against the now-clean snapshot. The production
# LV is never touched.
#
# Exit: 0 clean, 1 inconsistencies found, 2 could not run the check.
set -euo pipefail

VG=${1:?usage: fs-integrity-check <vg> <lv> [snapshot-size]}
LV=${2:?usage: fs-integrity-check <vg> <lv> [snapshot-size]}
SNAP_SIZE=${3:-4G}

SNAP="${LV}_scrub"
SNAP_DEV="/dev/${VG}/${SNAP}"
SRC_DEV="/dev/${VG}/${LV}"
MNT=$(mktemp -d /tmp/fs-scrub.XXXXXX)
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rmdir "$MNT" 2>/dev/null || true
    lvs "$SNAP_DEV" &>/dev/null && lvremove -f "$SNAP_DEV" >/dev/null || true
}
trap cleanup EXIT

emit_metric() {
    local status=$1
    install -d -m 0755 "$TEXTFILE_DIR"
    cat > "${TEXTFILE_DIR}/fs_scrub_${VG}_${LV}.prom.$$" <<EOF
# HELP node_filesystem_scrub_status 0=clean 1=inconsistent 2=error
# TYPE node_filesystem_scrub_status gauge
node_filesystem_scrub_status{device="${SRC_DEV}"} ${status}
# HELP node_filesystem_last_scrub_timestamp_seconds Unix time of last completed scrub
# TYPE node_filesystem_last_scrub_timestamp_seconds gauge
node_filesystem_last_scrub_timestamp_seconds{device="${SRC_DEV}"} ${EPOCHSECONDS}
EOF
    mv "${TEXTFILE_DIR}/fs_scrub_${VG}_${LV}.prom.$$" \
       "${TEXTFILE_DIR}/fs_scrub_${VG}_${LV}.prom"
}

FSTYPE=$(blkid -o value -s TYPE "$SRC_DEV")

# A snapshot that overflows its COW space is silently INVALIDATED and every
# read from it returns EIO. Refuse to start without room in the VG.
FREE_MB=$(vgs --noheadings --units m -o vg_free --nosuffix "$VG" | tr -d ' ' | cut -d. -f1)
NEED_MB=$(numfmt --from=iec "$SNAP_SIZE" | awk '{print int($1/1048576)}')
if (( FREE_MB < NEED_MB )); then
    echo "FATAL: VG ${VG} has ${FREE_MB}MiB free, need ${NEED_MB}MiB for the snapshot" >&2
    emit_metric 2; exit 2
fi

lvcreate --snapshot --size "$SNAP_SIZE" --name "$SNAP" "$SRC_DEV" >/dev/null
udevadm settle

# Replay the journal / log into the snapshot. Both ext4 and XFS perform
# recovery even on a read-only mount, which is exactly what we want: after
# this umount the snapshot is a cleanly-unmounted filesystem and the checkers
# will not refuse to run or report spurious "needs recovery" state.
case "$FSTYPE" in
    ext4|ext3|ext2) mount -o ro          "$SNAP_DEV" "$MNT" ;;
    xfs)            mount -o ro,nouuid   "$SNAP_DEV" "$MNT" ;;  # nouuid: duplicate UUID
    *) echo "FATAL: unsupported fstype ${FSTYPE}" >&2; emit_metric 2; exit 2 ;;
esac
umount "$MNT"

rc=0
case "$FSTYPE" in
    ext4|ext3|ext2)
        # -f force full check, -n answer no to everything (never writes)
        e2fsck -fn "$SNAP_DEV" || rc=$?
        # Bit 4 = errors left uncorrected; bit 1/2 cannot occur under -n.
        (( rc & 4 )) && rc=1 || rc=0
        ;;
    xfs)
        # -n = no modify. xfs_repair exits 1 when it would have made changes.
        xfs_repair -n "$SNAP_DEV" || rc=1
        ;;
esac

if (( rc == 0 )); then
    echo "CLEAN: ${SRC_DEV} (${FSTYPE})"
    emit_metric 0
else
    echo "INCONSISTENT: ${SRC_DEV} (${FSTYPE}) — schedule an offline repair window" >&2
    emit_metric 1
fi
exit "$rc"
```

`/etc/systemd/system/fs-integrity-check@.service`:

```ini
[Unit]
Description=Online integrity check of LVM volume %I (snapshot based)
Documentation=man:e2fsck(8) man:xfs_repair(8) man:lvcreate(8)
After=local-fs.target
ConditionPathExists=/usr/local/sbin/fs-integrity-check

[Service]
Type=oneshot
# %I is "vg--lv"; split it back into two arguments.
ExecStart=/bin/bash -c '/usr/local/sbin/fs-integrity-check "${0%%--*}" "${0##*--}"' %I
# The check is CPU and I/O heavy: keep it out of the way of production traffic.
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
# e2fsck/xfs_repair on a large volume can take hours; no timeout kill.
TimeoutStartSec=infinity
# Least privilege: it needs device-mapper, mount and raw block access only.
PrivateNetwork=yes
ProtectHome=yes
ProtectKernelModules=yes
NoNewPrivileges=yes
SuccessExitStatus=0
```

`/etc/systemd/system/fs-integrity-check@.timer`:

```ini
[Unit]
Description=Weekly online integrity check of %I

[Timer]
OnCalendar=Sun 03:30
# Never let a whole rack scrub at the same instant.
RandomizedDelaySec=3600
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

Enable with the escaped instance name (`-` is escaped as `\x2d`, so use `--` as the separator as the unit above expects):

```bash
$ sudo systemctl enable --now 'fs-integrity-check@vg_data--lv_data.timer'
Created symlink /etc/systemd/system/timers.target.wants/fs-integrity-check@vg_data--lv_data.timer → /etc/systemd/system/fs-integrity-check@.timer
```

### 3.5 Kubernetes — node-level filesystem pressure and a sentinel DaemonSet

Kubelet eviction is the cluster-level expression of "monitor free space and inodes". Note that `imageGCHighThresholdPercent` must sit *above* the `imagefs.available` eviction threshold, otherwise the kubelet evicts pods before it ever garbage-collects images.

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Soft thresholds warn and give workloads a grace period to shed data;
# hard thresholds evict immediately. Both nodefs.available AND
# nodefs.inodesFree are required: a node can be at 20% disk usage and
# still be unable to create a single file.
evictionSoft:
  nodefs.available: "15%"
  nodefs.inodesFree: "10%"
  imagefs.available: "20%"
evictionSoftGracePeriod:
  nodefs.available: "2m"
  nodefs.inodesFree: "2m"
  imagefs.available: "2m"
evictionHard:
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
  memory.available: "500Mi"
evictionMinimumReclaim:
  nodefs.available: "2Gi"
  nodefs.inodesFree: "50000"
  imagefs.available: "5Gi"
evictionPressureTransitionPeriod: 5m
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
imageMinimumGCAge: 2m
```

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fs-integrity-sentinel
  namespace: monitoring
  labels:
    app.kubernetes.io/name: fs-integrity-sentinel
    app.kubernetes.io/component: node-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fs-integrity-sentinel
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fs-integrity-sentinel
    spec:
      hostPID: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: sentinel
          image: registry.example.com/platform/fs-sentinel:1.4.0
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              OUT=/textfile/fs_integrity.prom
              while true; do
                : > "${OUT}.tmp"
                {
                  echo '# HELP node_ext4_fs_error_count Persistent ext4 superblock error counter'
                  echo '# TYPE node_ext4_fs_error_count counter'
                  echo '# HELP node_ext4_mount_count Mounts since last full check'
                  echo '# TYPE node_ext4_mount_count gauge'
                  echo '# HELP node_filesystem_last_check_timestamp_seconds Last e2fsck completion'
                  echo '# TYPE node_filesystem_last_check_timestamp_seconds gauge'
                } >> "${OUT}.tmp"

                # Enumerate real block-backed ext4 mounts from the host namespace.
                awk '$3 ~ /^ext[234]$/ && $1 ~ /^\/dev\// {print $1}' /host/proc/mounts \
                | sort -u | while read -r dev; do
                    hdr=$(dumpe2fs -h "$dev" 2>/dev/null) || continue
                    errs=$(awk -F: '/^FS Error count/ {gsub(/ /,"",$2); print $2}' <<<"$hdr")
                    mc=$(awk -F: '/^Mount count/ {gsub(/ /,"",$2); print $2}' <<<"$hdr")
                    lc=$(awk -F'Last checked:' '/^Last checked/ {print $2}' <<<"$hdr")
                    lc_epoch=$(date -d "${lc:-@0}" +%s 2>/dev/null || echo 0)
                    printf 'node_ext4_fs_error_count{device="%s"} %s\n' "$dev" "${errs:-0}" >> "${OUT}.tmp"
                    printf 'node_ext4_mount_count{device="%s"} %s\n' "$dev" "${mc:-0}" >> "${OUT}.tmp"
                    printf 'node_filesystem_last_check_timestamp_seconds{device="%s"} %s\n' "$dev" "$lc_epoch" >> "${OUT}.tmp"
                  done

                # Atomic publish: node_exporter must never read a half-written file.
                mv "${OUT}.tmp" "${OUT}"
                sleep 300
              done
          securityContext:
            # dumpe2fs reads the raw block device: CAP_SYS_RAWIO/root on the
            # device node is required. Everything else is dropped.
            runAsUser: 0
            privileged: false
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["SYS_RAWIO", "DAC_READ_SEARCH"]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: dev
              mountPath: /dev
            - name: textfile
              mountPath: /textfile
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: proc
          hostPath: { path: /proc, type: Directory }
        - name: dev
          hostPath: { path: /dev, type: Directory }
        - name: textfile
          hostPath: { path: /var/lib/node_exporter/textfile_collector, type: DirectoryOrCreate }
        - name: tmp
          emptyDir: { medium: Memory, sizeLimit: 16Mi }
```

### 3.6 Ansible — enforcing the policy fleet-wide

```yaml
---
- name: Enforce filesystem integrity policy on data nodes
  hosts: storage_nodes
  become: true
  gather_facts: true

  vars:
    fs_policy:
      - device: /dev/mapper/vg_data-lv_data
        mount: /srv/data
        fstype: ext4
        mkfs_opts: "-m 1 -i 8192 -O metadata_csum,64bit -E lazy_itable_init=0"
        mount_opts: "defaults,noatime,errors=remount-ro,nodev,nosuid"
        passno: 2
      - device: /dev/mapper/vg_arch-lv_arch
        mount: /srv/archive
        fstype: xfs
        mkfs_opts: "-m crc=1,finobt=1 -i maxpct=5"
        mount_opts: "defaults,noatime,nodev,nosuid"
        passno: 0            # fsck.xfs is a no-op; passno must be 0

  tasks:
    - name: Install filesystem tooling
      ansible.builtin.package:
        name: [e2fsprogs, xfsprogs, lvm2, smartmontools]
        state: present

    - name: Create filesystems with the policy geometry
      community.general.filesystem:
        fstype: "{{ item.fstype }}"
        dev: "{{ item.device }}"
        opts: "{{ item.mkfs_opts }}"
        state: present
      loop: "{{ fs_policy }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Contain ext4 metadata errors by remounting read-only
      ansible.builtin.command:
        cmd: "tune2fs -e remount-ro {{ item.device }}"
      register: tune_errbehav
      changed_when: "'Setting error behavior' in tune_errbehav.stdout"
      loop: "{{ fs_policy | selectattr('fstype', 'eq', 'ext4') | list }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Disable mount-count and time-based boot fsck on data volumes
      # Boot-time fsck on a 12 TiB volume is an unbounded outage. Integrity is
      # verified online by the weekly snapshot scrub instead.
      ansible.builtin.command:
        cmd: "tune2fs -c 0 -i 0 {{ item.device }}"
      register: tune_sched
      changed_when: "'Setting' in tune_sched.stdout"
      loop: "{{ fs_policy | selectattr('fstype', 'eq', 'ext4') | list }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Mount according to policy and persist in /etc/fstab
      ansible.posix.mount:
        path: "{{ item.mount }}"
        src: "{{ item.device }}"
        fstype: "{{ item.fstype }}"
        opts: "{{ item.mount_opts }}"
        dump: "0"
        passno: "{{ item.passno | string }}"
        state: mounted
      loop: "{{ fs_policy }}"
      loop_control:
        label: "{{ item.mount }}"

    - name: Install the online integrity checker
      ansible.builtin.copy:
        src: fs-integrity-check
        dest: /usr/local/sbin/fs-integrity-check
        mode: "0750"
        owner: root
        group: root

    - name: Install the checker units
      ansible.builtin.copy:
        src: "{{ item }}"
        dest: "/etc/systemd/system/{{ item }}"
        mode: "0644"
      loop:
        - fs-integrity-check@.service
        - fs-integrity-check@.timer
      notify: reload systemd

    - name: Schedule the weekly scrub per LVM volume
      ansible.builtin.systemd:
        name: "fs-integrity-check@{{ item.device | regex_replace('^/dev/mapper/([^-]+)-(.+)$', '\\1--\\2') }}.timer"
        enabled: true
        state: started
        daemon_reload: true
      loop: "{{ fs_policy }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Assert every ext4 volume has a clean superblock error counter
      ansible.builtin.shell:
        cmd: "dumpe2fs -h {{ item.device }} 2>/dev/null | awk -F: '/^FS Error count/ {gsub(/ /,\"\",$2); print $2}'"
      register: fs_errors
      changed_when: false
      failed_when: fs_errors.stdout | default('0') | int > 0
      loop: "{{ fs_policy | selectattr('fstype', 'eq', 'ext4') | list }}"
      loop_control:
        label: "{{ item.device }}"

  handlers:
    - name: reload systemd
      ansible.builtin.systemd:
        daemon_reload: true
```

---

## 4. CLI reference with real terminal output

### 4.1 `df` — monitoring free space and inodes

```
$ df -hT -x tmpfs -x devtmpfs -x squashfs
Filesystem              Type  Size  Used Avail Use% Mounted on
/dev/nvme0n1p2          ext4   98G   71G   22G  77% /
/dev/nvme0n1p1          vfat  511M  6.1M  505M   2% /boot/efi
/dev/mapper/vg_data-lv_data ext4  1.8T  1.7T   18G  99% /srv/data
/dev/mapper/vg_arch-lv_arch xfs   9.1T  4.2T  4.9T  47% /srv/archive
```

The inode view is a **separate question** and must be asked separately:

```
$ df -i -x tmpfs -x devtmpfs
Filesystem                   Inodes   IUsed     IFree IUse% Mounted on
/dev/nvme0n1p2              6553600  412337   6141263    7% /
/dev/mapper/vg_data-lv_data 244195328 243980112  215216  100% /srv/data
/dev/mapper/vg_arch-lv_arch 1907143104 3221844 1903921260   1% /srv/archive
```

`/srv/data` is at **100% inodes** — writes there already fail with `ENOSPC` regardless of the 18 GiB of free blocks. Note the XFS row: XFS allocates inodes dynamically, so `Inodes` is a *projection* based on `imaxpct` and free space, not a fixed number. It moves as the filesystem fills.

One command that answers both questions at once, which is what belongs in a runbook:

```
$ df -h --output=source,fstype,size,used,avail,pcent,itotal,iused,ipcent,target \
     -x tmpfs -x devtmpfs -x overlay
Filesystem                  Type  Size  Used Avail Use% Inodes IUsed IUse% Mounted on
/dev/nvme0n1p2              ext4   98G   71G   22G  77%   6.3M  403K    7% /
/dev/mapper/vg_data-lv_data ext4  1.8T  1.7T   18G  99%   233M  233M  100% /srv/data
/dev/mapper/vg_arch-lv_arch xfs   9.1T  4.2T  4.9T  47%   1.8G  3.1M    1% /srv/archive
```

The reserved blocks are visible as the gap between "free" and "available":

```
$ df -B1 --output=size,used,avail /srv/data | tail -1
   1976579796992  1834429874176      18874368000

$ echo "size - used - avail = reserved"
$ python3 -c "print((1976579796992-1834429874176-18874368000)/2**30, 'GiB reserved')"
115.0 GiB reserved
```

### 4.2 `du` — attributing consumption

```
$ sudo du -x -h --max-depth=1 /var 2>/dev/null | sort -h
1.1M	/var/spool
4.0M	/var/tmp
18M	/var/cache
392M	/var/backups
2.1G	/var/lib
41G	/var/log
44G	/var
```

Descend into the offender, one level at a time. `-x` is not optional: without it `du` crosses into every mounted filesystem underneath and the numbers become meaningless.

```
$ sudo du -x -h --max-depth=1 /var/log | sort -h | tail -6
216M	/var/log/journal
1.4G	/var/log/nginx
2.9G	/var/log/audit
36G	/var/log/app
41G	/var/log
```

Largest individual files, which `du` will not show you directly:

```
$ sudo find /var/log -xdev -type f -size +500M -printf '%s\t%TY-%Tm-%Td\t%p\n' \
    | sort -rn | numfmt --to=iec --field=1
19G	2026-08-26	/var/log/app/debug.log
8.4G	2026-08-19	/var/log/app/debug.log.1
5.1G	2026-08-24	/var/log/audit/audit.log
```

The sparse-file trap — `du` and `ls` disagree, and both are right:

```
$ ls -lh /srv/data/vm/disk0.qcow2
-rw-r--r-- 1 qemu qemu 500G Aug 26 09:14 /srv/data/vm/disk0.qcow2

$ du -h /srv/data/vm/disk0.qcow2
47G	/srv/data/vm/disk0.qcow2

$ du -h --apparent-size /srv/data/vm/disk0.qcow2
500G	/srv/data/vm/disk0.qcow2
```

`ls -l` and `du --apparent-size` report `i_size` (the logical length). Plain `du` reports allocated blocks. Only the latter is what the filesystem is actually spending.

### 4.3 The classic incident: `df` full, `du` says otherwise

```
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var  50G   49G     0 100% /var

$ sudo du -xsh /var
12G	/var
```

37 GiB unaccounted for. The blocks are allocated to inodes with `i_links_count == 0` that are still held open — the file is unlinked but not yet released:

```
$ sudo lsof -nP +L1
COMMAND     PID  USER   FD   TYPE DEVICE   SIZE/OFF NLINK    NODE NAME
java      21847   app    3w   REG  253,3 21474836480     0  786434 /var/log/app/debug.log (deleted)
java      21847   app    7w   REG  253,3 16106127360     0  786441 /var/log/app/trace.log (deleted)
```

`NLINK 0` is the signature. Someone deleted the logs to "free space" while the JVM still had them open — the space is not returned until the last file descriptor closes. Reclaim **without restarting the process** by truncating through `/proc`:

```
$ sudo truncate -s 0 /proc/21847/fd/3
$ sudo truncate -s 0 /proc/21847/fd/7
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var  50G   12G   36G  26% /var
```

The other shape of the same discrepancy — files hidden underneath a mountpoint:

```
$ sudo mkdir -p /mnt/rootcheck
$ sudo mount --bind / /mnt/rootcheck
$ sudo du -xsh /mnt/rootcheck/var
28G	/mnt/rootcheck/var          # <- 28 GiB written to /var BEFORE the LV was mounted over it
$ sudo umount /mnt/rootcheck
```

### 4.4 Inode exhaustion

```
$ df -i /srv/data
Filesystem                     Inodes     IUsed  IFree IUse% Mounted on
/dev/mapper/vg_data-lv_data 244195328 244195328      0  100% /srv/data

$ sudo -u app touch /srv/data/probe
touch: cannot touch '/srv/data/probe': No space left on device

$ df -h /srv/data
Filesystem                   Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_data  1.8T  1.7T   18G  99% /srv/data
```

`ENOSPC` with 18 GiB free. Locate the directory holding the file count:

```
$ sudo find /srv/data -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -5
 8412339 /srv/data/cache/sessions
  241887 /srv/data/uploads/thumbs
   19204 /srv/data/tmp
```

Per-subtree counts, which is what you actually want at the top of an incident:

```
$ for d in /srv/data/*/; do
>   printf '%10d  %s\n' "$(sudo find "$d" -xdev | wc -l)" "$d"
> done | sort -rn
   8412512  /srv/data/cache/
    243901  /srv/data/uploads/
     19204  /srv/data/tmp/
      1174  /srv/data/vm/
```

**Architectural consequence:** on ext4 the inode count is fixed at `mke2fs` time and **cannot be increased in place**. `resize2fs` adds inodes only when *growing* the filesystem (each new block group brings `Inodes per group` more). If growing is not an option, the fix is a rebuild with a different `-i`/`-N`, which means a full data migration. Model the file-count profile before `mkfs`, not after:

```
$ sudo tune2fs -l /dev/mapper/vg_data-lv_data | grep -E 'Inode count|Block count|Block size'
Inode count:              244195328
Block count:              488390656
Block size:               4096

$ python3 -c "print(488390656*4096//244195328, 'bytes per inode')"
8192 bytes per inode
```

XFS does not have this failure mode in the same way — inodes are allocated on demand — but it has its own ceiling:

```
$ xfs_info /srv/archive | head -3
meta-data=/dev/mapper/vg_arch-lv_arch isize=512    agcount=32, agsize=76288000 blks
         =                       sectsz=512   attr=2, projid32bit=1
data     =                       bsize=4096   blocks=2441216000, imaxpct=5

$ sudo xfs_growfs -m 25 /srv/archive        # raise the inode-space cap to 25%
meta-data=/dev/mapper/vg_arch-lv_arch isize=512 agcount=32, agsize=76288000 blks
...
inode max percent changed from 5 to 25
```

### 4.5 `tune2fs` and `dumpe2fs` — reading and steering ext4 policy

```
$ sudo tune2fs -l /dev/mapper/vg_data-lv_data
tune2fs 1.47.0 (5-Feb-2023)
Filesystem volume name:   data
Last mounted on:          /srv/data
Filesystem UUID:          6b1f9c2e-4a77-4d31-9f0b-3c8a51e2d904
Filesystem magic number:  0xEF53
Filesystem revision #:    1 (dynamic)
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Filesystem flags:         signed_directory_hash 
Default mount options:    user_xattr acl
Filesystem state:         clean
Errors behavior:          Remount read-only
Filesystem OS type:       Linux
Inode count:              244195328
Block count:              488390656
Reserved block count:     4883906
Free blocks:              4611893
Free inodes:              0
First block:              0
Block size:               4096
Fragment size:            4096
Group descriptor size:    64
Blocks per group:         32768
Inodes per group:         16384
Inode blocks per group:   1024
Flex block group size:    16
Filesystem created:       Mon Mar  3 11:04:22 2026
Last mount time:          Tue Aug 11 07:41:09 2026
Last write time:          Wed Aug 26 09:22:41 2026
Mount count:              41
Maximum mount count:      -1
Last checked:             Mon Mar  3 11:04:22 2026
Check interval:           0 (<none>)
Lifetime writes:          14 TB
Reserved blocks uid:      0 (user root)
Reserved blocks gid:      0 (group root)
First inode:              11
Inode size:	          256
Journal inode:            8
Default directory hash:   half_md4
Checksum type:            crc32c
```

Read this like an SRE:

- `Filesystem state: clean` — the fs was cleanly unmounted or is currently mounted and consistent. `not clean` or `clean with errors` means a check is owed.
- `Errors behavior: Remount read-only` — the policy from §2.4 is in force.
- `Maximum mount count: -1` and `Check interval: 0` — no automatic boot fsck. Deliberate, and it means the online scrub is now mandatory, not optional.
- `Free inodes: 0` — the incident from §4.4, visible directly in the superblock.
- `Lifetime writes: 14 TB` — useful for SSD endurance correlation.

The persistent error counter (only present once errors have occurred) is the highest-signal field on the whole system:

```
$ sudo dumpe2fs -h /dev/sdc1 2>/dev/null | grep -A6 'FS Error count'
FS Error count:           7
First error time:         Mon Aug 17 03:12:44 2026
First error function:     ext4_journal_check_start
First error line #:       83
First error inode #:      0
First error block #:      0
Last error time:          Sat Aug 22 19:08:03 2026
Last error function:      ext4_lookup
Last error line #:        1852
Last error inode #:       1310721
Last error block #:       0
```

This counter lives in the superblock, **survives reboots**, and is cleared only by a successful `e2fsck`. A rebooted node whose "problem went away" still carries the evidence here. This is precisely what the sentinel DaemonSet in §3.5 exports.

Policy changes:

```
$ sudo tune2fs -e remount-ro /dev/sdc1
tune2fs 1.47.0 (5-Feb-2023)
Setting error behavior to 2

$ sudo tune2fs -m 1 /dev/mapper/vg_data-lv_data
tune2fs 1.47.0 (5-Feb-2023)
Setting reserved blocks percentage to 1% (4883906 blocks)

$ sudo tune2fs -c 30 -i 0 /dev/sdc1
tune2fs 1.47.0 (5-Feb-2023)
Setting maximal mount count to 30
Setting interval between checks to 0 seconds

$ sudo tune2fs -C 31 /dev/sdc1        # force a check on the NEXT boot
tune2fs 1.47.0 (5-Feb-2023)
Setting current mount count to 31
```

| `tune2fs` flag | Effect |
|---|---|
| `-l` | List superblock contents |
| `-c N` | Max mount count before a forced check (`0`/`-1` disables) |
| `-C N` | Set the *current* mount count — the trick to force a check next boot |
| `-i D[d\|w\|m]` | Check interval by time (`0` disables) |
| `-e continue\|remount-ro\|panic` | Error behaviour |
| `-m N` | Reserved-block percentage |
| `-r N` | Reserved-block absolute count |
| `-L label` / `-U uuid` | Label / UUID |
| `-j` | Add a journal to an ext2 filesystem (ext2 → ext3) |
| `-o [^]opt` | Default mount options stored in the superblock |
| `-O [^]feature` | Toggle a feature; most require the fs unmounted **and** a subsequent `e2fsck -f` |

**Caution:** `tune2fs -O` on a mounted filesystem, or without the mandatory follow-up `e2fsck -f`, is a documented way to corrupt an otherwise healthy volume. `tune2fs` says so and then does it anyway if you insist.

### 4.6 `mke2fs` — geometry decisions and the superblock-backup trick

Always dry-run first. `-n` creates nothing and prints exactly what would be built, **including the backup superblock locations you will need if the primary is destroyed**:

```
$ sudo mke2fs -n -t ext4 -i 8192 -m 1 /dev/sdd1
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 262144000 4k blocks and 131072000 inodes
Filesystem UUID: 9a3d51c7-8e12-4f6b-b0a2-77c4e91d3fa8
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872, 71663616, 78675968, 
	102400000, 214990848

$ sudo mke2fs -n /dev/sdd1 > /root/sdd1-superblock-backups.txt
```

Record that output before an incident, not during one. It is also recoverable afterwards with `dumpe2fs`, but only if the primary superblock is still readable — which is exactly the case where you do not need it.

| `mke2fs` option | Purpose | SRE guidance |
|---|---|---|
| `-b 1024\|2048\|4096` | Block size | Leave at 4096 (matches page size); smaller only for tiny volumes |
| `-i bytes` | Bytes per inode | The single most consequential choice. Default 16384; use 8192 or 4096 for maildir/session/cache workloads |
| `-N count` | Absolute inode count | Use when you know the file count exactly |
| `-m percent` | Reserved blocks | 5 default; 1 or 0 on pure data volumes only |
| `-T type` | Usage profile from `/etc/mke2fs.conf` (`news`, `largefile`, `largefile4`) | `-T largefile4` = 4 MiB/inode for video/backup stores |
| `-O feature[,...]` | Feature set; `^x` disables | Keep `metadata_csum`, `64bit`; never disable `has_journal` on production |
| `-E lazy_itable_init=0,lazy_journal_init=0` | Write all inode tables at mkfs time | Pay the cost once instead of during production I/O |
| `-E stride=N,stripe_width=M` | RAID alignment | Misalignment on RAID5/6 causes read-modify-write on every metadata update |
| `-E discard` | TRIM the device first | SSD/thin-provisioned volumes |
| `-c` / `-cc` | Read-only / non-destructive read-write badblocks scan | Slow; modern drives self-remap — prefer `smartctl` |
| `-n` | Dry run | Always, first |

RAID alignment worked example — a 6-disk RAID6 (4 data disks), 512 KiB chunk, 4 KiB blocks:

```
$ python3 -c "print('stride =', 512*1024//4096, ' stripe_width =', (512*1024//4096)*4)"
stride = 128  stripe_width = 512

$ sudo mke2fs -t ext4 -b 4096 -E stride=128,stripe_width=512 -m 0 /dev/md0
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 5859373056 4k blocks and 366210048 inodes
Filesystem UUID: c40e8a1b-...
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, ...
Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (262144 blocks): done
Writing superblocks and filesystem accounting information: done
```

### 4.7 `fsck` and `e2fsck` — repairing ext filesystems

`fsck` is a **dispatcher**. It reads the type from `/etc/fstab` or `blkid` and execs `fsck.<type>`; every option after `--` goes to the backend.

```
$ sudo fsck -N /dev/sdc1
fsck from util-linux 2.38.1
[/usr/sbin/fsck.ext4 (1) -- /dev/sdc1] fsck.ext4 /dev/sdc1
```

**Rule zero: never run a repair on a mounted filesystem.** `e2fsck` warns; if you continue, the kernel's in-memory state and the on-disk state diverge and the filesystem is destroyed.

```
$ sudo e2fsck -f /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
/dev/mapper/vg_data-lv_data is mounted.
e2fsck: Cannot continue, aborting.
```

The correct sequence on a real repair:

```
$ sudo systemctl stop app.service
$ sudo umount /srv/data
umount: /srv/data: target is busy.

$ sudo fuser -vm /srv/data
                     USER        PID ACCESS COMMAND
/srv/data:           root     kernel mount /srv/data
                     app        3128 F..c. java

$ sudo systemctl stop app-worker.service
$ sudo umount /srv/data
$ mountpoint /srv/data
/srv/data is not a mountpoint
```

Before touching anything, capture the metadata. `e2image` writes a sparse image of *only* the metadata — typically a few hundred MiB even for multi-TiB volumes — and it is your only undo:

```
$ sudo e2image -r /dev/mapper/vg_data-lv_data /var/backups/data-meta-$(date +%F).img
e2image 1.47.0 (5-Feb-2023)

$ ls -lh --apparent-size /var/backups/data-meta-2026-08-26.img
-rw------- 1 root root 1.8T Aug 26 09:41 /var/backups/data-meta-2026-08-26.img
$ du -h /var/backups/data-meta-2026-08-26.img
612M	/var/backups/data-meta-2026-08-26.img
```

Then a **read-only** assessment pass. `-f` forces a full check even if the superblock says clean; `-n` answers "no" to every question and never writes:

```
$ sudo e2fsck -fn /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Inode 1310721, i_blocks is 48, should be 40.  Fix? no

Pass 2: Checking directory structure
Entry 'session-4a91.tmp' in /cache/sessions (1310722) has deleted/unused inode 1441795.  Clear? no

Pass 3: Checking directory connectivity
Unconnected directory inode 1572865 (was in /cache)
Connect to /lost+found? no

Pass 4: Checking reference counts
Inode 1310721 ref count is 3, should be 2.  Fix? no

Pass 5: Checking group summary information
Block bitmap differences:  -(1310730--1310737)
Fix? no

Free blocks count wrong for group #40 (18234, counted=18242).
Fix? no

Free blocks count wrong (4611893, counted=4611901).
Fix? no


/dev/mapper/vg_data-lv_data: ********** WARNING: Filesystem still has errors **********

/dev/mapper/vg_data-lv_data: 244195328/244195328 files (0.3% non-contiguous), 483778763/488390656 blocks
$ echo $?
4
```

This is exactly the picture of a crash during writeback: a handful of accounting mismatches, one orphaned directory, one dangling directory entry. Now repair for real:

```
$ sudo e2fsck -fy /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Inode 1310721, i_blocks is 48, should be 40.  Fix? yes

Pass 2: Checking directory structure
Entry 'session-4a91.tmp' in /cache/sessions (1310722) has deleted/unused inode 1441795.  Clear? yes

Pass 3: Checking directory connectivity
Unconnected directory inode 1572865 (was in /cache)
Connect to /lost+found? yes

Inode 1572865 ref count is 2, should be 3.  Fix? yes

Pass 4: Checking reference counts
Inode 1310721 ref count is 3, should be 2.  Fix? yes

Pass 5: Checking group summary information
Block bitmap differences:  -(1310730--1310737)
Fix? yes

Free blocks count wrong for group #40 (18234, counted=18242).
Fix? yes

Free blocks count wrong (4611893, counted=4611901).
Fix? yes


/dev/mapper/vg_data-lv_data: ***** FILE SYSTEM WAS MODIFIED *****
/dev/mapper/vg_data-lv_data: 244195327/244195328 files (0.3% non-contiguous), 483778755/488390656 blocks
$ echo $?
1
```

Exit 1 = errors found and corrected. Verify with a second pass — a clean repair always converges to exit 0:

```
$ sudo e2fsck -fn /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
/dev/mapper/vg_data-lv_data: 244195327/244195328 files (0.3% non-contiguous), 483778755/488390656 blocks
$ echo $?
0
```

**If the second pass is not clean, stop.** Repeated non-convergence means the underlying device is returning different data on each read — a hardware problem, not a filesystem problem. Continuing to run `e2fsck` on failing media grinds the remaining good data into `lost+found`.

Check what the repair reparented:

```
$ sudo mount /srv/data
$ sudo ls -la /srv/data/lost+found | head
total 132
drwx------   3 root root  16384 Mar  3 11:04 .
drwxr-xr-x  12 root root   4096 Aug 26 09:44 ..
drwxr-xr-x   2 app  app    4096 Aug 24 18:21 #1572865
```

Files in `lost+found` are named after their inode number; their directory entries — and therefore their names and paths — are gone. Identify them by content (`file`, `head`, magic numbers) and by mtime.

#### Recovering from a destroyed primary superblock

```
$ sudo mount /dev/sdd1 /mnt/restore
mount: /mnt/restore: wrong fs type, bad option, bad superblock on /dev/sdd1, missing codepage or helper program, or other error.
       dmesg(1) may have more information after failed mount system call.

$ sudo dmesg | tail -2
[ 8814.203117] EXT4-fs (sdd1): VFS: Can't find ext4 filesystem
```

Recover the backup locations (this works even without a readable primary because `mke2fs -n` recomputes the layout deterministically from the same parameters), then point `e2fsck` at one:

```
$ sudo mke2fs -n /dev/sdd1
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 262144000 4k blocks and 131072000 inodes
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, ...

$ sudo e2fsck -b 32768 -B 4096 -y /dev/sdd1
e2fsck 1.47.0 (5-Feb-2023)
/dev/sdd1 was not cleanly unmounted, check forced.
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
Free blocks count wrong for group #0 (24576, counted=24575).
Fix? yes

/dev/sdd1: ***** FILE SYSTEM WAS MODIFIED *****
/dev/sdd1: 1247/131072000 files (0.1% non-contiguous), 8412337/262144000 blocks
```

`-b` selects the backup superblock; `-B` states the block size explicitly because it cannot be read from a destroyed primary. A successful run **writes the repaired superblock back to the primary location**. `mke2fs -n` must be given the *same* parameters the filesystem was created with, or the computed backup offsets will be wrong.

| `e2fsck` option | Meaning | Production note |
|---|---|---|
| `-n` | Answer no to all; open read-only | The mandatory first pass |
| `-p` | Preen: fix only unambiguously safe problems, non-interactive | What boot-time `fsck -a` uses; exits 4 on anything requiring judgement |
| `-y` | Answer yes to all | Only after `-n` and after an `e2image` backup |
| `-f` | Force a full check even if marked clean | Always, when checking on purpose |
| `-c` / `-cc` | Run `badblocks` read-only / non-destructive rw | Very slow; prefer SMART |
| `-b N` / `-B N` | Backup superblock / block size | Primary-superblock recovery |
| `-D` | Optimise and compact directories | Useful after mass deletion in huge directories |
| `-E discard` | TRIM freed blocks | Thin-provisioned / SSD |

### 4.8 XFS — `xfs_repair`, `xfs_db`, `xfs_fsr`

XFS is not checked at boot. Confirm it for yourself:

```
$ cat /usr/sbin/fsck.xfs
#!/bin/sh
# Copyright (c) 2002 Silicon Graphics, Inc.  All Rights Reserved.
#
# Just for the record, XFS never needs fsck.
...
exit 0
```

Health and geometry of a mounted XFS:

```
$ xfs_info /srv/archive
meta-data=/dev/mapper/vg_arch-lv_arch isize=512    agcount=32, agsize=76288000 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=0
data     =                       bsize=4096   blocks=2441216000, imaxpct=5
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=521728, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
```

`crc=1` means metadata checksums are on — corruption is *detected* rather than silently consumed. `agcount=32` is the parallelism unit: allocation groups are independently locked, and they are also the unit of `xfs_repair`'s work and memory.

The read-only assessment. `xfs_repair -n` **requires the filesystem to be unmounted** and reports without modifying:

```
$ sudo umount /srv/archive
$ sudo xfs_repair -n /dev/mapper/vg_arch-lv_arch
Phase 1 - find and verify superblock...
Phase 2 - using internal log
        - zero log...
        - scan filesystem freespace and inode maps...
        - found root inode chunk
Phase 3 - for each AG...
        - scan (but don't clear) agi unlinked lists...
        - process known inodes and perform inode discovery...
        - agno = 0
        - agno = 1
        - agno = 2
        - agno = 3
        - process newly discovered inodes...
Phase 4 - check for duplicate blocks...
        - setting up duplicate extent list...
        - check for inodes claiming duplicate blocks...
        - agno = 0
        - agno = 1
        - agno = 2
        - agno = 3
No modify flag set, skipping phase 5
Phase 6 - check inode connectivity...
        - traversing filesystem ...
        - traversal finished ...
        - moving disconnected inodes to lost+found ...
disconnected inode 1074266112, would move to lost+found
Phase 7 - verify link counts...
would have reset inode 1074266112 nlinks from 0 to 1
No modify flag set, skipping filesystem flush and exiting.
$ echo $?
1
```

Every message under `-n` is conditional ("would move", "would have reset"). Exit 1 means changes are needed.

The dirty-log case, and the one genuinely dangerous flag in this entire topic:

```
$ sudo xfs_repair /dev/mapper/vg_arch-lv_arch
Phase 1 - find and verify superblock...
Phase 2 - using internal log
        - zero log...
ERROR: The filesystem has valuable metadata changes in a log which needs to
be replayed.  Mount the filesystem to replay the log, and unmount it before
re-running xfs_repair.  If you are unable to mount the filesystem, then use
the -L option to destroy the log and attempt a repair.
Note that destroying the log may cause corruption -- please attempt a mount
of the filesystem before doing this.
```

The tool is telling you the correct procedure. **Do it:**

```
$ sudo mount /dev/mapper/vg_arch-lv_arch /srv/archive
$ sudo umount /srv/archive
$ sudo xfs_repair /dev/mapper/vg_arch-lv_arch
Phase 1 - find and verify superblock...
Phase 2 - using internal log
        - zero log...
        - scan filesystem freespace and inode maps...
        - found root inode chunk
Phase 3 - for each AG...
        - scan and clear agi unlinked lists...
        - process known inodes and perform inode discovery...
        - agno = 0
        - agno = 1
        - process newly discovered inodes...
Phase 4 - check for duplicate blocks...
        - setting up duplicate extent list...
        - check for inodes claiming duplicate blocks...
Phase 5 - rebuild AG headers and trees...
        - reset superblock...
Phase 6 - check inode connectivity...
        - resetting contents of realtime bitmap and summary inodes
        - traversing filesystem ...
        - traversal finished ...
        - moving disconnected inodes to lost+found ...
disconnected inode 1074266112, moving to lost+found
Phase 7 - verify and correct link counts...
Note - stripe unit (0) and width (0) were copied from a backup superblock.
Please reset with mount -o sunit=<value>,swidth=<value> if necessary
done
```

`xfs_repair -L` **zeroes the log**, discarding every metadata transaction that had not yet been checkpointed. Use it only when the filesystem physically cannot be mounted, after imaging the device, and accepting that recent metadata operations are gone. It is a data-loss operation with a friendly name.

Memory control on very large filesystems — `xfs_repair` builds in-memory structures proportional to the inode count and will get OOM-killed on a small management node:

```
$ sudo xfs_repair -m 8192 -P /dev/mapper/vg_arch-lv_arch
```

(`-m` caps memory at 8 GiB; `-P` disables prefetch, trading speed for a much smaller footprint.)

**`xfs_db` — the metadata inspector.** Always use `-r` (read-only) unless you are being supervised by someone who wrote the filesystem:

```
$ sudo xfs_db -r -c 'sb 0' -c 'print' /dev/mapper/vg_arch-lv_arch | head -20
magicnum = 0x58465342
blocksize = 4096
dblocks = 2441216000
rblocks = 0
rextents = 0
uuid = 3f8e12a4-9c07-4b5d-8e21-6a4f0d17b3c9
logstart = 1073741828
rootino = 128
rbmino = 129
rsumino = 130
rextsize = 1
agblocks = 76288000
agcount = 32
icount = 3221844
ifree = 4108
fdblocks = 1288847360
```

Fragmentation assessment (`xfs_db` on a *mounted* filesystem requires `-r`; the numbers are a snapshot and may be slightly inconsistent):

```
$ sudo xfs_db -r -c frag /dev/mapper/vg_arch-lv_arch
actual 4198234, ideal 3221844, fragmentation factor 23.26%
Note, this number is largely meaningless.
Files on this filesystem average 1.30 extents per file
```

The upstream note is not sarcasm: the "fragmentation factor" counts extents against files, so a filesystem full of legitimately large multi-extent files scores badly while performing perfectly. The number that matters is **extents per file** for the files you actually read sequentially:

```
$ sudo filefrag -v /srv/archive/2026/backup-full.tar.zst | tail -4
    412: 1048320..1049343:  8912384..  8913407:   1024:
    413: 1049344..1050367:  8913408..  8914431:   1024:  last,eof
/srv/archive/2026/backup-full.tar.zst: 414 extents found
```

**`xfs_fsr` — online defragmentation.** It works on a *mounted* filesystem by copying each fragmented file into a fresh, contiguous temporary inode and atomically swapping the extents:

```
$ sudo xfs_fsr -v -t 600 /srv/archive
/srv/archive start inode=0
ino=1074266401
extents before:412 after:3 DONE ino=1074266401
ino=1074266580
extents before:198 after:2 DONE ino=1074266580
ino=1074266891
extents before:87 after:1 DONE ino=1074266891
/srv/archive start inode=1074267002
```

| `xfs_fsr` flag | Meaning |
|---|---|
| `-v` | Verbose, per-inode before/after extent counts |
| `-t seconds` | Time budget per invocation (default 7200) |
| `-p passes` | Passes over the filesystem |
| `-m mtab` | Alternate mount table |
| *(no args)* | Reorganise every XFS in `/etc/mtab`, resuming from `/var/tmp/.fsrlast_xfs` |

Constraints that matter in production: `xfs_fsr` needs free space (it writes a full second copy of each file it moves), it is I/O-intensive, and it **cannot help a filesystem that is nearly full** — which is usually the one that got fragmented. It also skips files with shared extents (reflinks) rather than breaking the sharing. Defragmentation is a symptom treatment; the cure is not running filesystems above 85%.

Native online scrub, where the kernel supports it:

```
$ sudo xfs_scrub -n /srv/archive
Info: /srv/archive: Scrubbing filesystem metadata.
Info: /srv/archive: Scanning all inodes.
Info: /srv/archive: Scrubbing filesystem summary counters.
/srv/archive: 3221844 inodes scanned, 0 errors found.
```

### 4.9 The boot-time path

```
$ systemctl list-units 'systemd-fsck*'
  UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
  systemd-fsck-root.service   loaded active exited File System Check on Root Device
  systemd-fsck@dev-disk-by\x2duuid-a3c9....service loaded active exited File System Check on /dev/disk/by-uuid/a3c9...

$ journalctl -b -u systemd-fsck-root.service
systemd-fsck[412]: /dev/nvme0n1p2: clean, 412337/6553600 files, 18632144/25690112 blocks
```

Forcing or suppressing a check is done via the kernel command line, not the long-obsolete `/forcefsck` marker file:

| Kernel parameter | Effect |
|---|---|
| `fsck.mode=auto` | Default: check when the fs is marked dirty or counters expire |
| `fsck.mode=force` | Force a full check of every filesystem this boot |
| `fsck.mode=skip` | Skip all checks (recovery only — you are booting a possibly inconsistent fs) |
| `fsck.repair=preen` | Default: `fsck -a`, fix only unambiguous problems |
| `fsck.repair=yes` | `fsck -y`, answer yes to everything |
| `fsck.repair=no` | `fsck -n`, report only |

```
$ sudo grubby --update-kernel=ALL --args="fsck.mode=force fsck.repair=preen"
$ sudo reboot
# ... and afterwards, so it does not force on every boot:
$ sudo grubby --update-kernel=ALL --remove-args="fsck.mode fsck.repair"
```

---

## 5. Verification and failure-diagnosis guide

### 5.1 Triage: `ENOSPC` on a filesystem that has free space

```
                    write() -> ENOSPC
                            │
              ┌─────────────┴─────────────┐
        df -h shows                  df -h shows
        100% used                    free space
              │                            │
    ┌─────────┴─────────┐        ┌─────────┴──────────────┐
 du -xsh ≈ df      du -xsh << df │                        │
    │                   │     df -i at 100%?        df -i has room?
 Genuine full     Deleted-open   │                        │
    │             files, or a    │              ┌─────────┴─────────┐
 Reclaim /        shadowed mount │        Reserved blocks?     Quota?
 grow the LV          │      Inode exhaustion       │              │
                lsof -nP +L1     │            tune2fs -l      repquota -a
                mount --bind /   │            (writing as        xfs_quota
                                 │             non-root)       -c 'report'
                          ext4: cannot fix         │
                          in place -> grow    tune2fs -m 1
                          or rebuild with -i
                          xfs: xfs_growfs -m
```

Additional XFS-only cause worth knowing: a filesystem created long ago and mounted `inode32` can only place inodes in the first 1 TiB of the device. On a grown multi-TiB volume this produces `ENOSPC` on file *creation* with terabytes free. Confirm with `grep xfs /proc/mounts` and remount `inode64`.

### 5.2 Triage: suspected corruption

```
1. CONFIRM   dmesg -T | grep -Ei 'EXT4-fs error|XFS.*(corrupt|Internal error)|I/O error|remount'
             dumpe2fs -h <dev> | grep -A6 'FS Error count'
             grep ' ro,' /proc/mounts

2. CLASSIFY  smartctl -a /dev/nvme0n1   # Reallocated_Sector_Ct, Media_Wearout, nvme error log
             ├── media failing  -> STOP. ddrescue to healthy media, repair the COPY.
             └── media healthy  -> filesystem-level repair is appropriate.

3. PRESERVE  e2image -r <dev> /backup/meta.img          (ext4, minutes, ~0.05% of fs size)
             lvcreate --snapshot ...                    (if on LVM)
             ddrescue                                    (if media is suspect)

4. QUIESCE   systemctl stop <consumers>
             fuser -vm <mountpoint>
             umount <mountpoint>            # NEVER repair a mounted filesystem

5. ASSESS    e2fsck -fn <dev>       ; echo $?     # expect 0 or 4
             xfs_repair -n <dev>    ; echo $?     # expect 0 or 1

6. REPAIR    e2fsck -fy <dev>                     # after step 3, not before
             xfs_repair <dev>                     # mount+umount first if the log is dirty

7. VERIFY    e2fsck -fn <dev>  -> MUST exit 0     # non-convergence => hardware
             xfs_repair -n <dev> -> MUST exit 0
             mount <dev> <mp> && ls -la <mp>/lost+found

8. RECONCILE Identify lost+found contents, restore named files from backup,
             clear the superblock error counter is automatic on a clean e2fsck,
             record the incident, re-arm monitoring.
```

### 5.3 Verification checklist — what proves what

| Claim | Command that proves it | Acceptable result |
|---|---|---|
| The filesystem is structurally consistent | `e2fsck -fn <dev>` / `xfs_repair -n <dev>` | Exit 0, no messages |
| No corruption has ever been recorded | `dumpe2fs -h <dev> \| grep 'FS Error count'` | Field absent, or `0` |
| It is mounted read-write | `findmnt -no OPTIONS <mp> \| grep -o '^rw'` | `rw` |
| Errors will be contained | `tune2fs -l <dev> \| grep 'Errors behavior'` | `Remount read-only` |
| It has room for blocks | `df -h <mp>` | `Use%` < 85% |
| It has room for inodes | `df -i <mp>` | `IUse%` < 85% |
| It has been checked recently | `tune2fs -l <dev> \| grep 'Last checked'` | Within the scrub interval |
| The underlying media is healthy | `smartctl -H -A <disk>` | `PASSED`, reallocated count flat |
| The scrub timer is actually firing | `systemctl list-timers 'fs-integrity-check@*'` | `NEXT` in the future, `LAST` recent |
| Monitoring would catch it | `curl -s localhost:9100/metrics \| grep node_filesystem_files_free` | Series present per mount |

```
$ systemctl list-timers 'fs-integrity-check@*' --all
NEXT                         LEFT      LAST                         PASSED  UNIT                                          ACTIVATES
Sun 2026-08-30 03:47:12 UTC  3 days    Sun 2026-08-23 04:11:55 UTC  3 days  fs-integrity-check@vg_data--lv_data.timer     fs-integrity-check@vg_data--lv_data.service

$ sudo systemctl start 'fs-integrity-check@vg_data--lv_data.service'
$ journalctl -u 'fs-integrity-check@vg_data--lv_data.service' -n 5 --no-pager
systemd[1]: Starting Online integrity check of vg_data--lv_data...
fs-integrity-check[9214]: CLEAN: /dev/vg_data/lv_data (ext4)
systemd[1]: fs-integrity-check@vg_data--lv_data.service: Deactivated successfully.
systemd[1]: Finished Online integrity check of vg_data--lv_data.
```

### 5.4 Failure-mode catalogue

| Symptom | Likely cause | Diagnostic | Action |
|---|---|---|---|
| `EROFS` on every write, `mount` shows `ro` | `errors=remount-ro` fired | `dmesg \| grep 'EXT4-fs error'` | Do **not** remount rw. Drain, image, repair offline |
| `Structure needs cleaning` (`EUCLEAN`) | Corrupted directory or extent tree | `dmesg`, `dumpe2fs -h` error fields | Unmount, `e2fsck -fn`, then repair |
| `XFS (dm-2): Corruption detected. Unmount and run xfs_repair` | XFS shutdown on metadata CRC failure | `dmesg`, `/proc/fs/xfs/stat` | Unmount, `xfs_repair -n`, then repair |
| `mount: wrong fs type, bad option, bad superblock` | Primary superblock damaged, or wrong type | `blkid`, `mke2fs -n` for backups | `e2fsck -b <backup> -B <blocksize>` |
| `e2fsck: Cannot continue, aborting` | Filesystem is mounted | `mountpoint`, `fuser -vm` | Stop consumers, unmount |
| `xfs_repair` refuses: "valuable metadata changes in a log" | Dirty XFS log | — | `mount` then `umount` to replay; `-L` only as a last resort |
| `e2fsck` never converges to exit 0 | Media returning different data per read | `smartctl -A`, `dmesg \| grep 'I/O error'` | Stop. `ddrescue` to new media, repair the copy |
| `df` full, `du` small | Deleted-but-open files | `lsof -nP +L1` | `truncate -s 0 /proc/<pid>/fd/<n>` |
| `df` full, `du` small, no deleted files | Files under a mountpoint | `mount --bind / /mnt && du -xsh /mnt/<path>` | Unmount, clean the underlying dir, remount |
| `ENOSPC` with blocks free | Inodes exhausted | `df -i` | ext4: grow or rebuild with `-i`; XFS: `xfs_growfs -m` |
| `ENOSPC` only for non-root users | 5% reserved blocks | `tune2fs -l \| grep Reserved` | `tune2fs -m 1` on data-only volumes |
| Boot hangs at "File System Check on..." | Forced check on a huge volume | Console, `journalctl -b -u systemd-fsck@*` | Let it finish; afterwards `tune2fs -c 0 -i 0` + online scrub |
| Snapshot check reports garbage | Snapshot COW space exhausted → snapshot invalidated | `lvs -o lv_name,snap_percent` | Size the snapshot for the write rate over the check duration |
| Sequential read throughput degraded on XFS | Extent fragmentation | `filefrag -v`, `xfs_db -r -c frag` | `xfs_fsr -t 600`; keep the fs under 85% |

### 5.5 Rules that hold without exception

1. **Never repair a mounted filesystem.** Read-only assessment on a snapshot, yes. Repair, no.
2. **Always run `-n` before `-y`.** The read-only pass is free and tells you whether this is a five-second accounting fix or a structural disaster.
3. **Image the metadata before repairing.** `e2image -r` costs minutes and is the only undo that exists.
4. **Rule out hardware first.** Repairing a filesystem on dying media accelerates data loss.
5. **`fsck` never frees space.** Full is not corrupt.
6. **Verify convergence.** A repair is complete when a second read-only pass exits 0, not when the first pass finishes.
7. **`xfs_repair -L` is a data-loss operation.** Exhaust mount/umount log replay first.
8. **XFS has no boot-time check**, so `passno` must be `0` and monitoring is the only detector.
9. **ext4 inode counts are immutable in place.** Choose `-i`/`-N` at `mkfs` time against a measured file-count profile.
10. **Monitor blocks and inodes as two separate alerts.** They produce the identical errno and only one of them is on your dashboard by default.

---

## Referencias

**Certification objectives**
- LPI Exam 101 Objectives (LPIC-1 version 5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI LPIC-1 certification overview — <https://www.lpi.org/our-certifications/lpic-1-overview/>

**ext2/3/4 and e2fsprogs**
- Linux kernel documentation, ext4 Data Structures and Algorithms — <https://docs.kernel.org/filesystems/ext4/index.html>
- e2fsprogs project — <https://e2fsprogs.sourceforge.net/>
- `e2fsck(8)` — <https://man7.org/linux/man-pages/man8/e2fsck.8.html>
- `mke2fs(8)` — <https://man7.org/linux/man-pages/man8/mke2fs.8.html>
- `mke2fs.conf(5)` — <https://man7.org/linux/man-pages/man5/mke2fs.conf.5.html>
- `tune2fs(8)` — <https://man7.org/linux/man-pages/man8/tune2fs.8.html>
- `dumpe2fs(8)` — <https://man7.org/linux/man-pages/man8/dumpe2fs.8.html>
- `e2image(8)` — <https://man7.org/linux/man-pages/man8/e2image.8.html>
- `e2scrub(8)` — <https://man7.org/linux/man-pages/man8/e2scrub.8.html>
- `resize2fs(8)` — <https://man7.org/linux/man-pages/man8/resize2fs.8.html>
- `badblocks(8)` — <https://man7.org/linux/man-pages/man8/badblocks.8.html>

**XFS**
- Linux kernel documentation, XFS — <https://docs.kernel.org/filesystems/xfs/index.html>
- XFS project documentation — <https://xfs.wiki.kernel.org/>
- `xfs_repair(8)` — <https://man7.org/linux/man-pages/man8/xfs_repair.8.html>
- `xfs_db(8)` — <https://man7.org/linux/man-pages/man8/xfs_db.8.html>
- `xfs_fsr(8)` — <https://man7.org/linux/man-pages/man8/xfs_fsr.8.html>
- `xfs_admin(8)` — <https://man7.org/linux/man-pages/man8/xfs_admin.8.html>
- `xfs_growfs(8)` — <https://man7.org/linux/man-pages/man8/xfs_growfs.8.html>
- `xfs_scrub(8)` — <https://man7.org/linux/man-pages/man8/xfs_scrub.8.html>
- `mkfs.xfs(8)` — <https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html>

**Generic utilities**
- `fsck(8)` (util-linux) — <https://man7.org/linux/man-pages/man8/fsck.8.html>
- GNU coreutils manual, `df` — <https://www.gnu.org/software/coreutils/manual/html_node/df-invocation.html>
- GNU coreutils manual, `du` — <https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html>
- `fstab(5)` — <https://man7.org/linux/man-pages/man5/fstab.5.html>
- `mount(8)`, filesystem-independent and ext4/XFS mount options — <https://man7.org/linux/man-pages/man8/mount.8.html>
- `filefrag(8)` — <https://man7.org/linux/man-pages/man8/filefrag.8.html>
- `lsof(8)` — <https://man7.org/linux/man-pages/man8/lsof.8.html>
- `lvcreate(8)`, LVM snapshots — <https://man7.org/linux/man-pages/man8/lvcreate.8.html>

**systemd and boot-time checking**
- `systemd-fsck@.service` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-fsck@.service.html>
- `systemd.timer(5)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html>
- Kernel command-line options (`fsck.mode`, `fsck.repair`) — <https://www.freedesktop.org/software/systemd/man/latest/kernel-command-line.html>

**Platform monitoring**
- Prometheus node_exporter — <https://github.com/prometheus/node_exporter>
- Prometheus alerting rules — <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Kubernetes, Node-pressure Eviction — <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/>
- Kubernetes, `KubeletConfiguration` (v1beta1) — <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/>
- Ansible `ansible.posix.mount` module — <https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html>
- Ansible `community.general.filesystem` module — <https://docs.ansible.com/ansible/latest/collections/community/general/filesystem_module.html>
- cloud-init modules reference — <https://cloudinit.readthedocs.io/en/latest/reference/modules.html>