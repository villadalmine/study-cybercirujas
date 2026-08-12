# Guided Exercises — Topic 362.2: Cluster Storage Access

> **Exam:** LPIC‑3 306‑300 (v3.0) · **Objective 362.2** · **Weight: 5**
> **Scope of this objective:** Storage Area Networks (SAN), Fibre Channel / FCoE, iSCSI targets and initiators, and Device Mapper Multipath I/O (DM‑MPIO). Awareness of CIFS/NFS as file‑level alternatives to block SAN.
> **Official objective:** https://www.lpi.org/our-certifications/exam-306-objectives/

Before a cluster file system (GFS2/OCFS2, objective 362.3) can be layered on top, every node must first *reach the same block device*, and reach it *redundantly*. That is exactly what this objective is about: presenting a block LUN over the network (iSCSI target), consuming it from each node (iSCSI initiator), and making the two independent I/O paths look like one resilient device (DM‑Multipath). These labs walk that chain end to end.

---

## Lab topology

You need three Linux VMs on the same L2 segment. Any distribution with a recent kernel LIO target and `open-iscsi` works; command names for the two big families are noted where they differ (RHEL/Fedora `dnf` + `targetcli`, Debian/Ubuntu `apt` + `targetcli-fb`).

```
                   ┌─────────────────────────────────────┐
                   │  storage   (the SAN / iSCSI target)  │
                   │  eth1 → 192.168.50.10/24  (fabric A)  │
                   │  eth2 → 192.168.60.10/24  (fabric B)  │
                   │  /dev/sdb  = 10 GiB backing block dev │
                   └───────────────┬─────────────────────┘
                    fabric A 50.0/24│ │fabric B 60.0/24
              ┌──────────────────────┘ └───────────────────────┐
   ┌──────────┴───────────┐                       ┌─────────────┴────────┐
   │ node1                │                       │ node2                │
   │ eth1 192.168.50.21   │                       │ eth1 192.168.50.22   │
   │ eth2 192.168.60.21   │                       │ eth2 192.168.60.22   │
   └──────────────────────┘                       └──────────────────────┘
```

Two separate subnets (`50.0/24` and `60.0/24`) deliberately model **two independent SAN fabrics** — the physical prerequisite for multipathing. In real hardware these would be two separate switches so that losing one switch does not lose the LUN.

Run all commands as `root` (or via `sudo`).

---

## Exercise 1 — Export a block LUN with an iSCSI target (`targetcli` / LIO)

You will present `/dev/sdb` on `storage` as an iSCSI LUN backed by the in‑kernel LIO target, reachable on both fabrics, and restricted to the two node initiators by ACL.

**Perform these steps on `storage`.**

1. Install and enable the kernel target service:

   ```bash
   # RHEL/Fedora
   dnf install -y targetcli
   # Debian/Ubuntu
   apt install -y targetcli-fb

   systemctl enable --now target
   ```

2. Confirm the backing device is present and unused (no filesystem, not mounted):

   ```bash
   lsblk /dev/sdb
   # NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
   # sdb    8:16   0  10G  0 disk
   ```

3. Enter the target shell and create a **block backstore** over `/dev/sdb`:

   ```bash
   targetcli
   /> cd /backstores/block
   /backstores/block> create name=lun0 dev=/dev/sdb
   Created block storage object lun0 using /dev/sdb.
   ```

4. Create the target's **IQN** (the target's iSCSI name). LIO auto‑creates `tpg1` with a default portal on `0.0.0.0:3260`:

   ```bash
   /backstores/block> cd /iscsi
   /iscsi> create iqn.2026-08.club.cybercirujas:storage.target0
   Created target iqn.2026-08.club.cybercirujas:storage.target0.
   Created TPG 1.
   Global pref auto_add_default_portal=true
   Created default portal listening on all IPs (0.0.0.0), port 3260.
   ```

5. Map the backstore as **LUN 0** inside the TPG:

   ```bash
   /iscsi> cd iqn.2026-08.club.cybercirujas:storage.target0/tpg1/luns
   /iscsi/iqn.20...t0/tpg1/luns> create /backstores/block/lun0
   Created LUN 0.
   ```

6. Replace the wildcard portal with **one explicit portal per fabric** (so we control which addresses are advertised):

   ```bash
   /iscsi/iqn.20...t0/tpg1/luns> cd ../portals
   /iscsi/iqn.20...t0/tpg1/portals> delete 0.0.0.0 3260
   /iscsi/iqn.20...t0/tpg1/portals> create 192.168.50.10
   /iscsi/iqn.20...t0/tpg1/portals> create 192.168.60.10
   ```

7. Create **ACLs** for the two initiator IQNs (these must match `/etc/iscsi/initiatorname.iscsi` on the nodes, set in Exercise 2):

   ```bash
   /iscsi/iqn.20...t0/tpg1/portals> cd ../acls
   /iscsi/iqn.20...t0/tpg1/acls> create iqn.2026-08.club.cybercirujas:node1
   /iscsi/iqn.20...t0/tpg1/acls> create iqn.2026-08.club.cybercirujas:node2
   ```

8. (Optional but recommended) Add **CHAP** authentication on the `node1` ACL:

   ```bash
   /iscsi/iqn.20...t0/tpg1/acls> cd iqn.2026-08.club.cybercirujas:node1
   /iscsi/iqn.20.../node1> set auth userid=node1 password=S3cr3tCHAPpass
   ```

9. Persist the configuration and leave. LIO stores it as JSON, replayed by `target.service` at boot:

   ```bash
   /> cd /
   /> saveconfig
   Configuration saved to /etc/target/saveconfig.json
   /> exit
   ```

10. Open the firewall for the iSCSI port on both fabrics:

    ```bash
    firewall-cmd --permanent --add-port=3260/tcp && firewall-cmd --reload
    # or: iptables -A INPUT -p tcp --dport 3260 -j ACCEPT
    ```

**Comprehension questions (Block 1)**

1. Decompose the IQN `iqn.2026-08.club.cybercirujas:storage.target0` into its mandatory parts. What does the `2026-08` field actually denote, and why is it *not* required to be the day you ran the command?
2. You chose a **block** backstore. Name the other three LIO backstore types and give one situation where **fileio** would be preferred over **block**.
3. A LUN and a target are different objects. If you added `/dev/sdc` as `lun1` in the same TPG, how many *targets* and how many *LUNs* would an initiator that logs into this target now see?
4. What is the practical security difference between the ACL you created in step 7 and the CHAP secret you set in step 8? Could an attacker on `192.168.50.0/24` reach the LUN with only one of them in place?

---

## Exercise 2 — Attach the LUN from an initiator (`open-iscsi` / `iscsiadm`)

**Perform these steps on `node1`** (repeat on `node2`, changing the IQN to `:node2`).

1. Install the initiator and set this node's initiator name to match the ACL you created:

   ```bash
   dnf install -y iscsi-initiator-utils     # Debian/Ubuntu: apt install open-iscsi

   echo "InitiatorName=iqn.2026-08.club.cybercirujas:node1" \
        > /etc/iscsi/initiatorname.iscsi
   ```

2. Put the CHAP credentials into `/etc/iscsi/iscsid.conf` (only if you enabled CHAP in Ex.1 step 8):

   ```ini
   node.session.auth.authmethod = CHAP
   node.session.auth.username   = node1
   node.session.auth.password   = S3cr3tCHAPpass
   ```

3. Enable the daemon (a restart is needed so it re‑reads the new initiator name):

   ```bash
   systemctl enable --now iscsid
   systemctl restart iscsid
   ```

4. **Discover** targets on fabric A. This queries the portal and writes a node record into the persistent DB under `/var/lib/iscsi/`:

   ```bash
   iscsiadm -m discovery -t sendtargets -p 192.168.50.10
   # 192.168.50.10:3260,1 iqn.2026-08.club.cybercirujas:storage.target0
   # 192.168.60.10:3260,1 iqn.2026-08.club.cybercirujas:storage.target0
   ```

   > Note both portals are returned even though you queried only one — the target advertises every portal in the TPG.

5. **Log in** to all discovered nodes for this target, establishing one session per portal:

   ```bash
   iscsiadm -m node -T iqn.2026-08.club.cybercirujas:storage.target0 -L all
   # Logging in to [iface: default, target: iqn.2026-08...:storage.target0, portal: 192.168.50.10,3260]
   # Logging in to [iface: default, target: iqn.2026-08...:storage.target0, portal: 192.168.60.10,3260]
   # Login to [...] successful.
   ```

6. Verify the two sessions and the two resulting SCSI disks:

   ```bash
   iscsiadm -m session
   # tcp: [1] 192.168.50.10:3260,1 iqn.2026-08...:storage.target0 (non-flash)
   # tcp: [2] 192.168.60.10:3260,1 iqn.2026-08...:storage.target0 (non-flash)

   lsscsi
   # [7:0:0:0]  disk  LIO-ORG  lun0  4.0   /dev/sdb
   # [8:0:0:0]  disk  LIO-ORG  lun0  4.0   /dev/sdc

   ls -l /dev/disk/by-path/ | grep iscsi
   # ...ip-192.168.50.10:3260-iscsi-iqn.2026-08...:storage.target0-lun-0 -> ../../sdb
   # ...ip-192.168.60.10:3260-iscsi-iqn.2026-08...:storage.target0-lun-0 -> ../../sdc
   ```

7. Make the login **persistent across reboots** by setting the node's startup mode to automatic:

   ```bash
   iscsiadm -m node -T iqn.2026-08.club.cybercirujas:storage.target0 \
            -o update -n node.startup -v automatic
   ```

**Comprehension questions (Block 2)**

1. The initiator sees the **same 10 GiB LUN** as both `/dev/sdb` and `/dev/sdc`. Why is writing a filesystem directly to `/dev/sdb` and mounting it *dangerous* right now, before Exercise 3 is done?
2. What is the concrete difference between `iscsiadm -m discovery` and `iscsiadm -m node --login`? After discovery but before login, is any SCSI disk present in `lsblk`?
3. Why is `/dev/disk/by-path/…` a safer identifier to script against than `/dev/sdb`, even for a single‑path setup?
4. You set `node.startup=automatic` with `-o update`. In which file/DB does that value live, and which distribution‑global default in `iscsid.conf` would have achieved the same for *all future* discovered nodes?

---

## Exercise 3 — Redundant access with Device Mapper Multipath (DM‑MPIO)

Right now each node has **two** paths (`/dev/sdb`, `/dev/sdc`) to **one** LUN. Multipath coalesces them into a single `/dev/mapper/mpathX` device that survives the loss of either fabric.

**Perform these steps on `node1` (and `node2`).**

1. Install multipath tooling:

   ```bash
   dnf install -y device-mapper-multipath   # Debian/Ubuntu: apt install multipath-tools
   ```

2. Generate a default config and enable the daemon. On RHEL family the helper writes a minimal `/etc/multipath.conf`:

   ```bash
   mpathconf --enable --with_multipathd y   # RHEL family
   # Debian/Ubuntu ships /etc/multipath.conf via multipath-tools; if absent:
   #   cp /usr/share/doc/multipath-tools/examples/multipath.conf.* /etc/multipath.conf

   systemctl enable --now multipathd
   ```

3. Find the LUN's **WWID** — the unique SCSI identifier that ties both paths to the same physical LUN:

   ```bash
   /lib/udev/scsi_id -g -u -d /dev/sdb
   # 36001405f1a2b3c4d5e6f7089abcdef01
   /lib/udev/scsi_id -g -u -d /dev/sdc
   # 36001405f1a2b3c4d5e6f7089abcdef01     <-- identical, as expected
   ```

4. Give the LUN a stable **alias** and blacklist the local root disk so multipath never touches it. Edit `/etc/multipath.conf`:

   ```conf
   defaults {
       user_friendly_names yes
       find_multipaths     yes
       path_grouping_policy multibus
       path_checker        tur
       failback            immediate
       no_path_retry       queue
   }

   blacklist {
       devnode "^(ram|zram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
       devnode "^sda"
   }

   multipaths {
       multipath {
           wwid  36001405f1a2b3c4d5e6f7089abcdef01
           alias san-lun0
       }
   }
   ```

5. Reload multipathd and inspect the merged device:

   ```bash
   systemctl reload multipathd     # or: multipathd reconfigure

   multipath -ll
   ```

   Expected output — one map, one path group, **two active paths**:

   ```
   san-lun0 (36001405f1a2b3c4d5e6f7089abcdef01) dm-3 LIO-ORG,lun0
   size=10G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
   `-+- policy='service-time 0' prio=50 status=active
     |- 7:0:0:0 sdb 8:16 active ready running
     `- 8:0:0:0 sdc 8:32 active ready running
   ```

6. Confirm the device‑mapper node and its slaves:

   ```bash
   ls -l /dev/mapper/san-lun0
   # lrwxrwxrwx 1 root root 7 ... /dev/mapper/san-lun0 -> ../dm-3

   lsblk /dev/mapper/san-lun0
   # NAME       MAJ:MIN RM SIZE RO TYPE  MOUNTPOINTS
   # san-lun0   253:3    0  10G  0 mpath
   ```

7. **Failover test.** Watch the paths, then blackhole fabric A and observe the map degrade *without* the block device disappearing:

   ```bash
   # terminal 1
   watch -n1 multipath -ll

   # terminal 2 — kill one path
   iptables -A OUTPUT -d 192.168.50.10 -j DROP
   ```

   After ~`path_checker` interval one path flips to `failed faulty`:

   ```
   san-lun0 (3600...ef01) dm-3 LIO-ORG,lun0
   `-+- policy='service-time 0' prio=50 status=active
     |- 7:0:0:0 sdb 8:16 failed faulty running
     `- 8:0:0:0 sdc 8:32 active ready  running
   ```

   `/dev/mapper/san-lun0` stays usable throughout. Restore the path and watch it rejoin:

   ```bash
   iptables -D OUTPUT -d 192.168.50.10 -j DROP
   ```

**Comprehension questions (Block 3)**

1. In `multipath -ll`, both paths sit in **one** path group under `policy='service-time 0'`. If you changed `path_grouping_policy` to `failover` instead of `multibus`, how would that output change, and what does that imply about how the two fabrics carry I/O during normal operation?
2. Explain the role of the **WWID** in step 3. Why can multipath *not* rely on `/dev/sdb`/`/dev/sdc` names, and what would happen after a reboot if it tried?
3. `no_path_retry queue` (via `queue_if_no_path`) was set. Describe the failure mode this creates if **both** paths die and stay dead — and why an HA cluster stack might prefer `no_path_retry fail` instead.
4. Which `defaults` keyword decided that the recovered path rejoins the active group *immediately* in step 7, and what is the alternative value?
5. Why is blacklisting `^sda` in step 4 important, and what does `find_multipaths yes` do to protect single‑path local disks even without an explicit blacklist entry?

---

## Exercise 4 — Partition, format and mount the multipath device (`kpartx`)

A multipath device is a whole disk. To use partitions on it you must ask device‑mapper to expose the partition maps. **Do this on `node1` only** (a plain filesystem like XFS/ext4 is *not* cluster‑safe — do not mount it read‑write on both nodes at once; that is what GFS2/OCFS2 in 362.3 solves).

1. Create a partition **on the mapped device**, not on `/dev/sdb`:

   ```bash
   parted -s /dev/mapper/san-lun0 mklabel gpt
   parted -s /dev/mapper/san-lun0 mkpart primary 1MiB 100%
   ```

2. Expose the new partition map with **kpartx** (multipath usually does this automatically; do it explicitly to see the mechanism):

   ```bash
   kpartx -a -v /dev/mapper/san-lun0
   # add map san-lun0-part1 (253:4): 0 20953088 linear 253:3 2048

   ls /dev/mapper/san-lun0*
   # /dev/mapper/san-lun0  /dev/mapper/san-lun0-part1
   ```

3. Make a filesystem and mount it via the stable mapper path:

   ```bash
   mkfs.xfs /dev/mapper/san-lun0-part1
   mkdir -p /mnt/san
   mount /dev/mapper/san-lun0-part1 /mnt/san
   df -hT /mnt/san
   # Filesystem                       Type  Size  Used Avail Use% Mounted on
   # /dev/mapper/san-lun0-part1       xfs   10G   ...  ...   1% /mnt/san
   ```

4. For a persistent mount, reference the multipath device and add the correct dependencies so it mounts **after** the SAN is up:

   ```fstab
   /dev/mapper/san-lun0-part1  /mnt/san  xfs  _netdev,nofail  0 0
   ```

**Comprehension questions (Block 4)**

1. Why must the partition table be created on `/dev/mapper/san-lun0` rather than on `/dev/sdb`? What would multipath report if you partitioned the raw path directly?
2. What does `kpartx -a` actually create, in device‑mapper terms, and why is the naming `san-lun0-part1` rather than `san-lun01`?
3. The fstab line uses `_netdev` and `nofail`. Explain the boot‑time problem each of those two options prevents.
4. Mounting XFS read‑write on `node1` **and** `node2` simultaneously will corrupt the filesystem. In one sentence, why — and what class of filesystem removes that restriction?

---

## Exercise 5 — Inspect the fabric layer: iSCSI vs Fibre Channel vs FCoE (concepts + discovery)

This objective also expects you to *recognise* the transport technologies even if the lab only had iSCSI. These steps inspect whatever transport a node actually has.

1. Inspect iSCSI transport state (what you built above):

   ```bash
   iscsiadm -m session -P 3 | grep -E 'Target:|Portal:|iSCSI Connection State|SID'
   ```

2. If the host has a real **Fibre Channel** HBA, its ports show up under sysfs. On the lab VMs these directories will be empty — that empty result is itself the answer to "do I have FC?":

   ```bash
   ls /sys/class/fc_host/          # host2  host3   (one entry per FC port, or empty)
   cat /sys/class/fc_host/host2/port_name    # 0x21000024ff00aa11  <- the WWPN
   cat /sys/class/fc_host/host2/port_state   # Online
   systool -c fc_host -v            # verbose HBA attributes (from sysfsutils)
   ```

3. Rescan a transport for newly presented LUNs without rebooting (works for both iSCSI and FC):

   ```bash
   # iSCSI: rescan the existing sessions
   iscsiadm -m session --rescan

   # generic SCSI host rescan
   for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h"; done

   # or, with sg3_utils installed:
   rescan-scsi-bus.sh -a
   ```

**Comprehension questions (Block 5)**

1. iSCSI carries SCSI commands over **TCP/IP**; Fibre Channel carries them over a dedicated FC fabric. Name two operational consequences of that difference (think: hardware cost, routability, and where congestion is handled).
2. What does **FCoE** change relative to plain FC, and which Ethernet feature set (one acronym) must the switches support for FCoE to be lossless? Name the protocol FCoE uses to discover the FCoE VLAN and log in to the fabric.
3. On a Fibre Channel node you found a **WWPN** in step 2. Map the FC concepts **WWNN**, **WWPN**, **zoning**, and **LUN masking** onto their nearest iSCSI equivalents from Exercises 1–2.
4. The objective also mentions **CIFS** and **NFS** as "awareness." Why are they categorically *not* substitutes for the iSCSI/FC block LUN you just built when the goal is a shared‑disk cluster file system?
5. `echo "- - -" > /sys/class/scsi_host/hostX/scan` — what do the three dashes represent, and why is this preferable to rebooting a production node to see a new LUN?

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — iSCSI target

1. **IQN parts:** `iqn` (the naming type/prefix, fixed) · `2026-08` (year‑month) · `club.cybercirujas` (the reversed DNS domain of the naming authority) · `:storage.target0` (an optional, authority‑chosen unique suffix). The date field records **when the naming authority owned that domain / when the naming convention was established**, not when you typed the command — it exists only to keep IQNs globally unique even if a domain later changes hands. Any valid `yyyy-mm` the domain was held is acceptable.
2. Other LIO backstores: **fileio** (a regular file used as a disk image), **ramdisk** (volatile RAM‑backed, for testing), **pscsi** (pass‑through of a real physical SCSI device). **fileio** is preferred when you want thin/sparse provisioning, a file you can snapshot/`cp`/back up at the filesystem level, or when no spare whole block device is available. (block gives the best performance and full SCSI semantics, which is why it was chosen here.)
3. Still **one target** (one IQN), now exposing **two LUNs** (LUN 0 and LUN 1). Targets and LUNs are orthogonal: a target is the network‑addressable endpoint; LUNs are the disks presented behind it.
4. The **ACL** is *authorization by identity* — only initiators whose IQN matches an ACL entry may access the TPG; it is trivially spoofable because an initiator simply asserts its own IQN. **CHAP** is *authentication* — it proves the initiator knows a shared secret. With only the ACL, an attacker on the fabric who sets `InitiatorName=…:node1` reaches the LUN; with CHAP added, they must also possess the secret. Defence in depth: keep both, plus network isolation of the SAN fabric.

### Block 2 — iSCSI initiator

1. Both `/dev/sdb` and `/dev/sdc` are the **same LUN reached over two paths**, not two disks. Writing a filesystem to `/dev/sdb` and, say, `/dev/sdc` (or writing via one path while multipath later reorders names) means two views of one disk with inconsistent caches — you can corrupt it. You must first let **multipath (Ex.3)** collapse them into one `/dev/mapper` device and address only that.
2. `discovery` only *asks a portal what targets exist* and records node records in the DB — **no session, no SCSI disk** appears; `lsblk` shows nothing new. `--login` establishes an actual iSCSI **session**, after which the LUN appears as a `/dev/sd*` disk.
3. `/dev/sdX` names are assigned in **probe order** and can change between boots or as devices come and go, so a script bound to `/dev/sdb` may hit the wrong disk after a reboot. `/dev/disk/by-path/…` encodes the portal IP + target IQN + LUN number, so it stably points at *that path to that LUN* regardless of enumeration order.
4. The value is stored in the persistent **node database** under `/var/lib/iscsi/nodes/<target-iqn>/<portal>/default` (key `node.startup`). Setting `node.startup = automatic` in **`/etc/iscsi/iscsid.conf`** makes it the default for all *future* discovered nodes (existing records keep whatever they were created with).

### Block 3 — DM‑Multipath

1. With `multibus`, both paths are in **one path group**, so I/O is **load‑balanced across both fabrics simultaneously** (active/active). With `failover`, each path lands in its **own** group and only the higher‑priority group is `active` while the other is `enabled`/standby — I/O uses **one fabric at a time** (active/passive), switching only on failure. The `-ll` output would show two separate `policy=…` groups, one `status=active`, one `status=enabled`.
2. The **WWID** is the LUN's globally unique SCSI identifier (from VPD page 0x83 / `scsi_id`), identical on every path to the same LUN. Multipath groups paths **by WWID**, which is why both `/dev/sdb` and `/dev/sdc` merge into one map. It cannot key on `sdb`/`sdc` because those kernel names are unstable across reboots/rescans; keying on them would risk merging *different* LUNs or splitting the same one after names shuffle.
3. `queue_if_no_path` means when **all** paths are down the device **holds I/O in a blocked/queued state indefinitely** instead of returning errors — good for surviving a brief total outage, but if the outage is permanent, processes hang in uninterruptible sleep (`D` state) and the node can become unresponsive (even reboots stall). An HA stack often prefers `no_path_retry fail` (or a finite retry count) so I/O **errors out quickly**, letting the cluster fence/relocate the resource instead of hanging.
4. `failback immediate` caused the recovered path to rejoin the active group at once. Alternatives: `manual` (admin must run `multipathd reinstate`/reconfigure) or a numeric value = seconds to wait before failing back (dampening to avoid flapping).
5. `^sda` is the **local root/OS disk**; if multipath grabbed it, it could try to treat the boot disk as a SAN path and break booting. `find_multipaths yes` tells multipath to **only** create a map for a device that actually has **more than one path** (or is already a known multipath member), so a genuinely single‑path local disk is left alone even if you forget to blacklist it.

### Block 4 — kpartx / partitions

1. Because the **whole‑disk device is `/dev/mapper/san-lun0`**; the partition table and the partition device nodes must live under the mapper device so I/O is routed through multipath. Partitioning `/dev/sdb` directly writes the table via a single path only, bypassing failover, and multipath would flag inconsistency / the partitions would not appear as managed `-partN` maps.
2. `kpartx -a` reads the partition table and creates a **linear device‑mapper target** for each partition, mapped onto the parent dm device (you saw `linear 253:3`). The name is `san-lun0-part1` (with the `-partN` separator) precisely to avoid ambiguity: if the device already ends in a digit, `mpatha1` vs `mpatha-part1` disambiguates the partition from a device whose name naturally ends in `1`.
3. `_netdev` marks the mount as **network‑backed**, so systemd waits for the network/iSCSI to be online before mounting and unmounts it before the network goes down — preventing a boot hang or a mount attempt against a not‑yet‑present LUN. `nofail` means a **missing/failed SAN device does not abort the boot** into emergency mode; the system continues without that mount.
4. XFS/ext4 assume a **single host owns the block device** and cache metadata locally with no cross‑node coordination; two nodes writing the same on‑disk structures with independent caches corrupt it. A **cluster / shared‑disk filesystem (GFS2, OCFS2)** — which coordinates access through a distributed lock manager (DLM) — removes that restriction.

### Block 5 — Fabric layer

1. Any two of: iSCSI runs on **commodity Ethernet NICs/switches (cheap, no special HBA)** whereas FC needs dedicated HBAs and FC switches; iSCSI traffic is **routable across L3/IP networks and even the WAN**, FC is a self‑contained L2 fabric; iSCSI inherits **TCP** congestion/retransmission (software overhead, jitter), while FC provides **lossless, credit‑based flow control** in hardware for more deterministic latency. Also: iSCSI can share NICs with other traffic (needs isolation/VLAN/jumbo frames), FC is physically separate.
2. **FCoE** encapsulates native FC frames directly inside **Ethernet** frames (no IP/TCP), letting FC and LAN share one converged 10GbE+ fabric. It requires **DCB** (Data Center Bridging — notably PFC/priority flow control) so the Ethernet is lossless like real FC. It uses **FIP (FCoE Initialization Protocol)** to discover the FCoE VLAN and perform fabric login (FLOGI/FDISC).
3. **WWNN** (World Wide Node Name, identifies the whole HBA/node) ≈ the initiator/target **IQN at node level**; **WWPN** (World Wide Port Name, per FC port) ≈ the **per‑portal/session endpoint**; **zoning** (restricting which WWPNs can see each other on the FC switch) ≈ **iSCSI ACLs / target portal + network isolation**; **LUN masking** (presenting specific LUNs only to specific WWPNs) ≈ the **per‑ACL LUN mapping in the TPG** on the target.
4. CIFS and NFS are **file‑level** protocols: the server owns the filesystem and clients send file operations, so they *can* be shared by many clients but they present **files, not a raw block device**. A cluster filesystem like GFS2/OCFS2 needs to place its **own on‑disk structures and DLM locking directly on a shared block LUN** — which only block transports (iSCSI, FC, FCoE, or shared SCSI) provide. NFS/CIFS already solve sharing at a different layer and cannot be the *underlying* shared block device.
5. The three dashes are **channel, target (SCSI ID), LUN** — all wildcarded, i.e. "rescan every channel/target/LUN on this SCSI host." It is preferable to a reboot because it makes newly presented LUNs appear **online, with zero downtime**, instead of disrupting every running service on the node just to re‑enumerate storage.

</details>

---

**Sources**

- LPI, *Exam 306 Objectives (306‑300, v3.0)* — https://www.lpi.org/our-certifications/exam-306-objectives/
- The Linux SCSI Target (LIO) / `targetcli` — https://linux-iscsi.org/ · `man targetcli`, `man 8 targetcli`
- Open‑iSCSI project & `iscsiadm` — https://www.open-iscsi.com/ · `man 8 iscsiadm`, `man 5 iscsid.conf`
- Kernel device‑mapper documentation — https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html
- DM Multipath configuration and `multipath.conf` — https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_device_mapper_multipath/ · `man 5 multipath.conf`, `man 8 multipath`, `man 8 kpartx`
- Open‑FCoE / FCoE tooling (`fcoeadm`, `fipvlan`) — https://open-fcoe.org/