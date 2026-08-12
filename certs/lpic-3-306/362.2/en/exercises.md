# 362.2 Cluster Storage Access — Guided Exercises

These exercises build a complete shared-block-storage stack from scratch: an **iSCSI target** exporting LUNs (LIO/`targetcli`), one or more **initiators** attaching them (`open-iscsi`/`iscsiadm`), stable device identification (**WWID**, `scsi_id`, `/dev/disk/by-*`), redundant access with **DM-Multipath**, and finally an awareness pass over **Fibre Channel / FCoE**. This is exactly the layer that sits *underneath* a shared cluster filesystem (GFS2/OCFS2) — get the block layer wrong and the filesystem above it corrupts silently.

> Official objective reference: LPI Exam 306 Objectives, topic 362.2 — <https://www.lpi.org/our-certifications/exam-306-objectives/>

## Lab topology

You need two Linux hosts (VMs are fine). Names and addresses used throughout:

| Role | Hostname | Primary IP | Secondary IP (for multipath) |
|------|----------|-----------|------------------------------|
| SAN / iSCSI target | `sanbox` | `192.168.50.10` | `192.168.60.10` |
| Cluster node / initiator | `node1` | `192.168.50.21` | `192.168.60.21` |

On `sanbox`, attach a spare 1 GiB block device (`/dev/vdb`) that will become the exported LUN. The secondary IPs live on a second NIC/subnet and are only needed for Exercise 4.

Package names differ by distribution; both families are shown where relevant (`dnf` = RHEL/Fedora/Alma/Rocky, `apt` = Debian/Ubuntu). Run every command as `root` (or under `sudo`).

---

## Exercise 1 — Export a LUN from an iSCSI target with `targetcli` (LIO)

The in-kernel **LIO** target is driven by the `targetcli` shell. You will create a *backstore*, wrap it in an iSCSI *target* (IQN), expose it as a *LUN* inside a *TPG*, publish a *portal*, and lock it down with an *ACL*.

**On `sanbox`:**

1. Install and enable the target service:

   ```bash
   # RHEL family
   dnf install -y targetcli
   systemctl enable --now target
   # Debian family
   apt install -y targetcli-fb
   systemctl enable --now rtslib-fb-targetctl
   ```

2. Create a **block backstore** from the spare disk (block backstores pass SCSI commands straight through and are what you want for production LUNs; `fileio` is the image-file alternative):

   ```bash
   targetcli /backstores/block create name=lun0 dev=/dev/vdb
   ```

   Expected:

   ```
   Created block storage object lun0 using /dev/vdb.
   ```

3. Create the **iSCSI target** with an explicit IQN (never let it auto-generate one in a lab you must reason about):

   ```bash
   targetcli /iscsi create iqn.2020-01.club.cybercirujas:sanbox.target0
   ```

   Expected:

   ```
   Created target iqn.2020-01.club.cybercirujas:sanbox.target0.
   Created TPG 1.
   Created default portal listening on all IPs (0.0.0.0), port 3260.
   ```

4. Map the backstore into the target's TPG as **LUN 0**:

   ```bash
   targetcli /iscsi/iqn.2020-01.club.cybercirujas:sanbox.target0/tpg1/luns \
       create /backstores/block/lun0
   ```

5. Replace the wide-open default portal with an explicit one on the storage subnet:

   ```bash
   TPG=/iscsi/iqn.2020-01.club.cybercirujas:sanbox.target0/tpg1
   targetcli $TPG/portals delete 0.0.0.0 3260
   targetcli $TPG/portals create 192.168.50.10 3260
   ```

6. Add an **ACL** so only `node1`'s initiator IQN may log in (the default `generate_node_acls` is off, meaning access is denied unless explicitly granted):

   ```bash
   targetcli $TPG/acls create iqn.2020-01.club.cybercirujas:node1
   ```

7. Persist the configuration and inspect the tree:

   ```bash
   targetcli saveconfig
   targetcli ls
   ```

   Expected (abridged):

   ```
   o- iscsi ........................................................ [Targets: 1]
   | o- iqn.2020-01.club.cybercirujas:sanbox.target0 ................ [TPGs: 1]
   |   o- tpg1 ........................................... [no-gen-acls, no-auth]
   |     o- acls ...................................................... [ACLs: 1]
   |     | o- iqn.2020-01.club.cybercirujas:node1 ............... [Mapped LUNs: 1]
   |     o- luns ...................................................... [LUNs: 1]
   |     | o- lun0 ......... [block/lun0 (/dev/vdb) (default_tg_pt_gp)]
   |     o- portals ................................................ [Portals: 1]
   |       o- 192.168.50.10:3260 ........................................... [OK]
   ```

8. Open the firewall for iSCSI:

   ```bash
   firewall-cmd --add-port=3260/tcp --permanent && firewall-cmd --reload   # firewalld
   # or: ufw allow 3260/tcp
   ```

> Sources: LIO / `targetcli-fb` — <https://github.com/open-iscsi/targetcli-fb> · Red Hat, *Configuring and managing storage devices → Getting started with iSCSI* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-iscsi_managing-storage-devices>

**Comprehension check:**

- **1a.** Decompose the IQN `iqn.2020-01.club.cybercirujas:sanbox.target0` into its four fields. What real-world fact does the `2020-01` portion assert, and why is it a date and not a version?
- **1b.** In LIO terminology, what is the difference between a *backstore*, a *LUN*, and a *TPG*? Which one actually holds data?
- **1c.** You created an ACL but never configured a password. Is the target reachable by an initiator with a different IQN? What single TPG attribute would you flip to accept *any* initiator, and why is that dangerous outside a lab?
- **1d.** Where did `saveconfig` write the persistent configuration, and what happens to the exported LUNs after a reboot if you *forget* to run it?

---

## Exercise 2 — Attach the LUN from the initiator with `open-iscsi`

Now consume the LUN from `node1`. The initiator side is the `iscsiadm` administration tool plus the `iscsid` daemon.

**On `node1`:**

1. Install the initiator utilities:

   ```bash
   dnf install -y iscsi-initiator-utils     # RHEL family
   apt install -y open-iscsi                # Debian family
   ```

2. Set the initiator's IQN so it matches the ACL you created in Exercise 1 — this is the identity the target authenticates against:

   ```bash
   echo 'InitiatorName=iqn.2020-01.club.cybercirujas:node1' > /etc/iscsi/initiatorname.iscsi
   systemctl enable --now iscsid
   systemctl restart iscsid          # re-read the new InitiatorName
   ```

3. Set login persistence in `/etc/iscsi/iscsid.conf` so discovered nodes reconnect after reboot:

   ```ini
   node.startup = automatic
   ```

4. Run **SendTargets discovery** against the portal. This queries the portal and records every advertised target into the persistent node database under `/var/lib/iscsi/`:

   ```bash
   iscsiadm -m discovery -t sendtargets -p 192.168.50.10:3260
   ```

   Expected:

   ```
   192.168.50.10:3260,1 iqn.2020-01.club.cybercirujas:sanbox.target0
   ```

5. **Log in** to the discovered target (this is when the SCSI device appears):

   ```bash
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.50.10:3260 --login
   ```

   Expected:

   ```
   Logging in to [iface: default, target: iqn.2020-01...:sanbox.target0, portal: 192.168.50.10,3260]
   Login to [iface: default, target: iqn.2020-01...:sanbox.target0, portal: 192.168.50.10,3260] successful.
   ```

6. Confirm the new block device and its transport path:

   ```bash
   lsblk --scsi
   ls -l /dev/disk/by-path/ | grep iscsi
   ```

   Expected (abridged):

   ```
   NAME HCTL       TYPE VENDOR   MODEL       TRAN
   sda  3:0:0:0    disk LIO-ORG  lun0        iscsi
   ...
   ip-192.168.50.10:3260-iscsi-iqn.2020-01.club.cybercirujas:sanbox.target0-lun-0 -> ../../sda
   ```

7. Inspect the live session in full detail:

   ```bash
   iscsiadm -m session -P 3
   ```

   Look for `iSCSI Session State: LOGGED_IN`, the negotiated `HeaderDigest`/`DataDigest`, and the attached SCSI disk.

8. Cleanly log out and observe the device disappear:

   ```bash
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.50.10:3260 --logout
   lsblk --scsi        # sda is gone
   ```

   Then log back in (`--login`) — you will need the LUN attached for the next exercises.

> Sources: `open-iscsi` project — <https://github.com/open-iscsi/open-iscsi> · Debian Wiki, *SAN/iSCSI* — <https://wiki.debian.org/SAN/iSCSI/open-iscsi>

**Comprehension check:**

- **2a.** What is the practical difference between iSCSI *discovery* and *login*? After discovery but before login, does a block device exist under `/dev`?
- **2b.** You changed `/etc/iscsi/initiatorname.iscsi` and then restarted `iscsid`. Why is the restart mandatory, and what login error would the target return if this file did not match the ACL from Exercise 1?
- **2c.** `node.startup = automatic` lives in `iscsid.conf`, but discovery also stamped a per-node value into the node DB. If you later edit `iscsid.conf` alone, does an *already discovered* node change its startup behaviour? How do you update it for an existing node with `iscsiadm`?
- **2d.** Why is `/dev/disk/by-path/ip-192.168.50.10:3260-iscsi-...-lun-0` a safer reference in `/etc/fstab` than `/dev/sda`? What does `/dev/sda` depend on that makes it unstable across reboots?

---

## Exercise 3 — Stable identity: WWID, `scsi_id`, and `/dev/disk/by-id`

Before layering multipath on top, understand *how the same physical LUN is recognized across every path and every reboot*. The key is the **WWID** — the persistent SCSI identifier read from VPD page `0x83`, independent of the `sdX` letter.

**On `node1` (with the LUN logged in):**

1. Extract the WWID directly from the device:

   ```bash
   /usr/lib/udev/scsi_id --whitelisted --device=/dev/sda
   # equivalent short form:
   /usr/lib/udev/scsi_id -g -u -d /dev/sda
   ```

   Expected (a `3` prefix means "NAA registered, page 0x83 designator"):

   ```
   36001405d9f8a1b2c3d4e5f60718293a4
   ```

2. Cross-check the udev-populated symlinks — the WWID appears as a `scsi-` / `wwn-` alias:

   ```bash
   ls -l /dev/disk/by-id/ | grep -Ei 'sda$'
   ```

   Expected:

   ```
   scsi-36001405d9f8a1b2c3d4e5f60718293a4 -> ../../sda
   wwn-0x6001405d9f8a1b2c3d4e5f60718293a4 -> ../../sda
   ```

3. Contrast the three identifier namespaces udev maintains and note *what each one is keyed on*:

   ```bash
   ls /dev/disk/by-id/     # content identity  → WWID / serial
   ls /dev/disk/by-path/   # topology          → transport + portal + LUN
   ls /dev/disk/by-uuid/   # filesystem        → mkfs-assigned UUID (only after a filesystem exists)
   ```

> Sources: `systemd`/`udev` persistent device naming — <https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html> · `scsi_id(8)` man page.

**Comprehension check:**

- **3a.** The `scsi_id` output starts with `3`, and the `wwn-` symlink starts with `0x6`. Explain what the leading `3` designates and why the two strings otherwise share the same hex body.
- **3b.** A LUN reachable over two paths shows up as both `/dev/sda` and `/dev/sdb`. What does `scsi_id` return for each, and why is that result the linchpin that lets DM-Multipath *know they are the same disk*?
- **3c.** Distinguish **WWID** from **WWN/WWNN/WWPN**. Which of these is an iSCSI concept, which is a Fibre Channel concept, and which one does multipath key its device on?
- **3d.** Why does `/dev/disk/by-uuid/` for a fresh LUN return nothing, whereas `/dev/disk/by-id/` already has an entry?

---

## Exercise 4 — Redundant access with DM-Multipath

A single path is a single point of failure. Present the *same* LUN over *two* portals (two subnets) and let **DM-Multipath** coalesce the two `sdX` devices into one `/dev/mapper/mpathX` that survives a path loss.

**On `sanbox`** — add the second portal so the LUN is reachable on both subnets:

1. ```bash
   TPG=/iscsi/iqn.2020-01.club.cybercirujas:sanbox.target0/tpg1
   targetcli $TPG/portals create 192.168.60.10 3260
   targetcli saveconfig
   ```

**On `node1`** — discover and log in over *both* portals, then enable multipath:

2. Discover and log in on the second path as well:

   ```bash
   iscsiadm -m discovery -t sendtargets -p 192.168.60.10:3260
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.60.10:3260 --login
   lsblk --scsi        # now BOTH sda and sdb, same LIO-ORG lun0
   ```

3. Install and enable multipath:

   ```bash
   # RHEL family
   dnf install -y device-mapper-multipath
   mpathconf --enable --with_multipathd y
   # Debian family
   apt install -y multipath-tools     # ships an active default /etc/multipath.conf
   systemctl enable --now multipathd
   ```

4. View the assembled multipath map:

   ```bash
   multipath -ll
   ```

   Expected:

   ```
   mpatha (36001405d9f8a1b2c3d4e5f60718293a4) dm-2 LIO-ORG,lun0
   size=1.0G features='0' hwhandler='1 alua' wp=rw
   `-+- policy='service-time 0' prio=50 status=active
     |- 3:0:0:0 sda 8:0  active ready running
     `- 4:0:0:0 sdb 8:16 active ready running
   ```

   Both paths sit in **one** priority group → this is `multibus`-style, both active.

5. Pin a stable alias and a **failover** policy by editing `/etc/multipath.conf`. Bind on the WWID from Exercise 3, not on any `sdX` name:

   ```conf
   defaults {
       user_friendly_names   yes
       find_multipaths       yes
   }

   multipaths {
       multipath {
           wwid                    36001405d9f8a1b2c3d4e5f60718293a4
           alias                   cluster-data
           path_grouping_policy    failover
           path_selector           "service-time 0"
           no_path_retry           12
       }
   }
   ```

   Reload and re-inspect:

   ```bash
   systemctl reload multipathd     # or: multipathd reconfigure
   multipath -ll
   ```

   Expected — now **two** priority groups, only one active (true active/standby failover):

   ```
   cluster-data (36001405d9f8a1b2c3d4e5f60718293a4) dm-2 LIO-ORG,lun0
   size=1.0G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
   |-+- policy='service-time 0' prio=50 status=active
   | `- 3:0:0:0 sda 8:0  active ready running
   `-+- policy='service-time 0' prio=10 status=enabled
     `- 4:0:0:0 sdb 8:16 active ready running
   ```

6. Use the multipath device — partition it and expose partitions with `kpartx`:

   ```bash
   parted -s /dev/mapper/cluster-data mklabel gpt mkpart data ext4 1MiB 100%
   kpartx -a -v /dev/mapper/cluster-data
   ls /dev/mapper/cluster-data*
   ```

   Expected:

   ```
   /dev/mapper/cluster-data   /dev/mapper/cluster-data1
   ```

7. Drive the daemon interactively for live diagnostics:

   ```bash
   multipathd -k
   multipathd> show topology
   multipathd> show paths
   multipathd> show config
   multipathd> quit
   ```

8. **Test failover.** Simulate a path loss by logging out one path, and watch the map degrade but stay usable:

   ```bash
   iscsiadm -m node -T iqn.2020-01.club.cybercirujas:sanbox.target0 \
       -p 192.168.60.10:3260 --logout
   multipath -ll        # sdb now 'failed faulty'; sda still active → I/O continues
   ```

   Then restore the path (`--login`) and confirm it returns to `active ready running`.

> Sources: Red Hat, *Configuring device mapper multipath* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_device_mapper_multipath/index> · Kernel Device Mapper docs — <https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/> · `multipath.conf(5)`.

**Comprehension check:**

- **4a.** In step 4 both paths were in one priority group; in step 5 they split into two. Which `path_grouping_policy` value produces each layout, and what is the operational difference between `multibus` and `failover` for throughput vs. redundancy?
- **4b.** The `multipaths {}` stanza binds on `wwid`, never on `sda`/`sdb`. Why is binding on the device letter a latent data-corruption bug in a cluster?
- **4c.** After the alias config, `features` gained `queue_if_no_path` and you set `no_path_retry 12`. Describe precisely what happens to in-flight I/O when *all* paths fail — does it error immediately, queue forever, or something in between? What is the risk of `queue_if_no_path` combined with an unmounted-clean assumption?
- **4d.** Why is `kpartx` needed for partitions on `/dev/mapper/cluster-data` when a plain local disk gets its `sda1` automatically? What layer is `kpartx` substituting for?
- **4e.** During the step-8 failover, `multipath -ll` still reported the map as usable while one path was `faulty`. What component decided to keep serving I/O over the surviving path, and where would you look to confirm no I/O errors reached the filesystem?

---

## Exercise 5 — Awareness: Fibre Channel and FCoE

The exam expects *recognition* of FC/FCoE, even without dedicated hardware. Inspect the sysfs interfaces the FC transport class exposes (present whenever an FC or FCoE HBA is driven; on a pure-iSCSI lab these directories will simply be empty — read the commands and expected output).

**On a host with an FC/FCoE HBA:**

1. Enumerate FC hosts and read their addresses:

   ```bash
   ls /sys/class/fc_host/
   cat /sys/class/fc_host/host5/node_name    # WWNN — identifies the HBA/node
   cat /sys/class/fc_host/host5/port_name    # WWPN — identifies the individual port
   cat /sys/class/fc_host/host5/port_state   # e.g. Online
   ```

   Expected:

   ```
   host5
   0x2000000e1e1a2b3c
   0x2100000e1e1a2b3c
   Online
   ```

2. Same data via `sysfsutils`:

   ```bash
   systool -c fc_host -v
   ```

3. List every SCSI device and its transport (FC-attached LUNs appear as ordinary SCSI disks):

   ```bash
   lsscsi --transport
   ```

4. For **FCoE** specifically, inspect the FCoE-over-Ethernet interfaces:

   ```bash
   fcoeadm -i        # interface info
   fcoeadm -t        # discovered targets
   ```

> Sources: LPI Exam 306 Objectives 362.2 — <https://www.lpi.org/our-certifications/exam-306-objectives/> · Red Hat, *Using Fibre Channel devices* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/using-fibre-channel-devices_managing-storage-devices>

**Comprehension check:**

- **5a.** Distinguish **WWNN** from **WWPN**. A dual-port HBA has how many of each? Which one does SAN zoning on the fabric switch typically match against?
- **5b.** FCoE carries Fibre Channel frames over Ethernet. What Ethernet feature must the switches support for FCoE to be lossless, and why can't you run FCoE over an arbitrary best-effort Ethernet segment?
- **5c.** Both an FC LUN and an iSCSI LUN show up as a plain `/dev/sdX` SCSI disk. From the perspective of DM-Multipath and the filesystem above it, does the transport (FC vs. FCoE vs. iSCSI) matter? What single identifier lets multipath treat all of them uniformly?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **1a.** Fields: `iqn` (the naming type), `2020-01` (year-month), `club.cybercirujas` (reverse-DNS naming authority), and `:sanbox.target0` (an optional, authority-assigned unique string). Per RFC 3720, the date is the *first month in which the naming authority owned the domain name* used in the reverse-DNS portion — it guarantees global uniqueness even if the domain later changes hands. It is deliberately **not** a version: it anchors ownership, not release state.
- **1b.** The **backstore** (`block/lun0` → `/dev/vdb`) is the actual storage object holding data. The **LUN** is a numbered mapping that exposes a backstore inside a target so an initiator can address it. The **TPG** (Target Portal Group) is the container that binds portals, LUNs, ACLs and auth together for one target. Only the backstore holds data.
- **1c.** No — with `generate_node_acls` off (the default, shown as `no-gen-acls`) and one explicit ACL, only `iqn.2020-01.club.cybercirujas:node1` may log in; any other initiator is rejected. Setting the TPG attribute `generate_node_acls=1` (often together with `authentication=0`, "demo mode") makes the target accept *any* initiator with no ACL — convenient in a lab, catastrophic in production because any host on the SAN can mount and corrupt the LUN.
- **1d.** `saveconfig` writes `/etc/target/saveconfig.json`, which the `target`/`rtslib-fb-targetctl` service restores at boot. Forget it and the running (in-kernel) configuration is lost on reboot — the LUNs, target and portals silently disappear and initiators fail to log in.

### Exercise 2
- **2a.** *Discovery* (SendTargets) asks a portal which targets it advertises and records them in the node DB (`/var/lib/iscsi/`) — no device is created. *Login* opens an actual iSCSI session; only then does the kernel attach the LUN as a `/dev/sdX` SCSI disk. After discovery but before login, no block device exists.
- **2b.** `iscsid` reads `initiatorname.iscsi` at startup; without a restart it keeps the old IQN and the target's ACL match fails. A mismatch produces a login failure such as `iSCSI login failed due to authorization failure` (initiator not permitted) — the ACL is keyed on the initiator IQN.
- **2c.** No — changing `iscsid.conf` only affects *future* discoveries. An already-discovered node keeps the `node.startup` value stamped into its per-node DB record. Update it with:
  `iscsiadm -m node -T <iqn> -p <ip:port> -o update -n node.startup -v automatic`.
- **2d.** `/dev/sda` is assigned in probe order and can point at a different disk after a reboot or when a path count changes; `/dev/disk/by-path/...` encodes the transport, portal and LUN, so it always resolves to the same LUN regardless of enumeration order. (`by-id`/WWID is even stronger — it is topology-independent.)

### Exercise 3
- **3a.** The leading `3` is the SCSI **designator type/association code** `scsi_id` prepends (NAA identifier from VPD page 0x83). The `wwn-0x6...` symlink is the raw NAA value; the shared hex body (`6001405…`) is the same registered identifier, just with different prefixes for the two representations.
- **3b.** `scsi_id` returns the **identical WWID** for both `/dev/sda` and `/dev/sdb`, because the identifier comes from the LUN itself (VPD 0x83), not from the path. That identity is precisely what DM-Multipath uses to conclude the two SCSI devices are two paths to one disk and to fold them into a single `dm-` device.
- **3c.** **WWID** is a generic, transport-independent SCSI unique identifier (works for iSCSI, FC, SAS, …) and is what multipath keys its device on. **WWN/WWNN/WWPN** are Fibre Channel constructs — WWNN names the node/HBA, WWPN names an individual FC port. iSCSI uses IQNs, not WWNs.
- **3d.** `by-uuid` is populated from a *filesystem* UUID assigned by `mkfs`; a raw LUN has no filesystem yet, so there is no entry. `by-id`/WWID comes from the device's own SCSI inquiry data, which exists the moment the LUN is attached.

### Exercise 4
- **4a.** One priority group with both paths active = `path_grouping_policy multibus` (all paths load-balanced simultaneously — maximizes throughput). Two groups with one active and one standby = `path_grouping_policy failover` (active/standby — maximizes redundancy determinism, one path at a time). Trade-off: `multibus` uses aggregate bandwidth but sends I/O down every path; `failover` keeps a hot spare and only fails over on loss.
- **4b.** `sdX` names are assigned by probe/enumeration order and can be reused for a *different* LUN after a reboot or path change. Binding multipath (or a mount) to `sda` can therefore silently attach the wrong disk — in a shared cluster that means writing into another node's or another LUN's data. The WWID is intrinsic to the LUN and never drifts.
- **4c.** `queue_if_no_path` plus `no_path_retry 12` means: on total path loss, in-flight and new I/O is **queued** (not errored) while multipath retries; the numeric `12` bounds the retry attempts (roughly `12 × polling_interval` seconds) before I/O is finally failed back to the filesystem. So it is neither an immediate error nor an infinite hang by default — it is a bounded queue. The danger of an *unbounded* `queue_if_no_path` (e.g. `no_path_retry queue`) is that processes block in uninterruptible D-state indefinitely and the node cannot cleanly unmount or fence, which is exactly what breaks orderly cluster failover.
- **4d.** A local disk's partition table is read by the kernel's block layer, which auto-creates `sda1`. A DM/multipath device is a virtual device-mapper target; the kernel does not auto-scan its partition table into separate device nodes. `kpartx` reads the partition table and creates the `-partN` device-mapper mappings (`cluster-data1`) that stand in for the missing kernel-generated partitions.
- **4e.** `multipathd` (with the kernel `dm-multipath` target) detected the path failure via its path checker, marked `sdb` faulty, and continued routing I/O over the surviving active path — the failure never reaches the filesystem. Confirm the filesystem saw no errors by checking `dmesg`/`journalctl -k` for I/O errors on the `dm-` device (there should be path-down messages but no filesystem-level I/O errors) and `multipath -ll` showing the surviving path still `active ready running`.

### Exercise 5
- **5a.** **WWNN** names the node (the whole HBA/adapter); **WWPN** names an individual port. A dual-port HBA typically presents **one WWNN and two WWPNs** (one per port). SAN switch zoning is normally done by **WWPN**, because zoning controls which specific ports may talk on the fabric.
- **5b.** FCoE requires **lossless Ethernet** — Data Center Bridging (DCB), specifically Priority-based Flow Control (PFC, 802.1Qbb) — because Fibre Channel assumes a no-drop transport. Ordinary best-effort Ethernet drops frames under congestion, which FC has no tolerance for, so FCoE cannot run reliably over a switch segment lacking DCB/PFC.
- **5c.** No — once the LUN is attached, the transport is transparent to DM-Multipath and the filesystem; all present as SCSI `/dev/sdX` devices. The **WWID** (from SCSI VPD page 0x83) is the single identifier that lets multipath treat FC, FCoE and iSCSI paths to the same LUN uniformly.

</details>