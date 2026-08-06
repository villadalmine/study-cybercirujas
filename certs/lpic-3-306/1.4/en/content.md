# LPIC-3 Exam 306-300 (v3.0) — Topic 1.4: Single Node High Availability

## 1. Motivation & Production Architectural Problem

In production infrastructure engineering, high availability (HA) is often conflated with distributed clustering frameworks (e.g., Kubernetes, Pacemaker, Ceph). However, distributed consensus algorithms (Raft, Paxos) and multi-node quorum models depend strictly on the stability of their underlying compute nodes. A single unhandled hardware fault—such as a degraded NVMe controller, a silently flapped NIC, or unmonitored UPS power degradation—can trigger premature cluster partition events, cascading failovers, split-brain scenarios, or catastrophic state corruption.

Single Node High Availability focuses on building fault-tolerant node primitives before scaling out. The goal is to maximize **Mean Time Between Failures (MTBF)** and minimize **Mean Time To Repair (MTTR)** at the hypervisor or bare-metal host layer.

```
+-----------------------------------------------------------------------------------+
|                            SINGLE NODE HA ARCHITECTURE                            |
+-----------------------------------------------------------------------------------+
|  Resource & Power Health    |  Storage Redundancy          | Network Resilience   |
|  - smartd (Predictive)      |  - Advanced mdadm (Bitmaps)  | - LACP / Bond Mode 4 |
|  - Monit (Auto-Recovery)    |  - LVM RAID1 / Thin-Pools    | - VLAN 802.1Q        |
|  - NUT / APCUPSD (UPS Signal|  - Hot-Spares & Scrubbing    | - BGP / VRRP (VIP)   |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        HARDWARE / KERNEL SUBSYSTEM (Bare-Metal)                   |
|  [ Physical Disks ]       [ Dual PSUs / UPS ]       [ Dual Top-of-Rack Switches ] |
+-----------------------------------------------------------------------------------+
```

### Key Degradation Vectors Handled at the Node Level:
1. **Silent Data Corruption & Drive Degradation:** Media wear-out on modern flash drives or reallocated sectors on magnetic media often fail to trigger immediate I/O errors until block read failures occur during a write barrier.
2. **Network Path Failure:** Cable degradation, SFP module failure, or upstream Top-of-Rack (ToR) switch reboots can disconnect a host while its local CPU and storage remain completely healthy.
3. **Storage Volumetric Saturation:** Uncapped log writes or unchecked thin-provisioned pools locking up the root filesystem or transaction log partition (`/var/log`, `/var/lib/docker`).
4. **Thermal and Power Instability:** Utility power dropouts or local power supply unit (PSU) failures causing abrupt power loss, resulting in journal inconsistency or corrupted storage metadata.

---

## 2. Technical Comparisons & Trade-Off Analysis

### 2.1 Storage Redundancy: Software RAID (`mdadm`) vs. Advanced LVM RAID vs. ZFS Single-Node

| Technical Metric | Linux Software RAID (`mdadm`) | Advanced LVM RAID (`lvcreate --type`) | ZFS on Linux (Single Pool) |
| :--- | :--- | :--- | :--- |
| **Architectural Layer** | Block Device Abstraction (`/dev/mdX`) | Volume Management + DM-RAID Subsystem | Integrated File System & Volume Manager |
| **Resync Recovery Overhead** | High (syncs entire disk unless Bitmap is configured) | High (uses kernel `md` module backend; mirrors allocated extents) | Low (syncs allocated live block pointers only) |
| **Write-Intent Bitmap Support** | Native internal/external bitmap; reduces rebuild times after dirty shutdowns | Supported via LVM metadata allocation for write logs | Native Copy-on-Write (CoW); no write hole |
| **Storage Flexibility** | Low (fixed block sizes, manual resize workflows) | High (online volume resizing, thin provisioning, snapshotting) | Dynamic allocation; Dataset-level storage quotas |
| **CPU / RAM Overhead** | Minimal CPU overhead; low RAM footprint | Low-to-Moderate CPU; low RAM footprint | High RAM requirement (ARC memory demands) |
| **Production Blast Radius** | Failure degraded per array; isolates block errors | Metadata corruption in Volume Group (VG) impacts all LVs | Pool-level corruption (`zpool`) impacts entire storage stack |

### 2.2 Network Link Redundancy: Bonding Modes & Routing Strategies

| Mode / Protocol | Operational Mechanism | L2/L3 Requirement | Throughput Aggregation | Failover Convergence |
| :--- | :--- | :--- | :--- | :--- |
| **Mode 1: Active-Backup** | Primary interface active; secondary interface stands by in promiscuous state | Standard unmanaged L2 switch | Single interface line-rate (1x) | Sub-second (depends on `miimon` probe interval) |
| **Mode 4: 802.3ad (LACP)** | Dynamic IEEE 802.3ad link negotiation using LACPDU frames | Requires ToR switch configured with LACP / MLAG | Multi-interface aggregated flow capacity based on hash | < 1 second on physical link loss |
| **Keepalived (VRRP)** | Virtual IP migration between two nodes via multicast heartbeats | Flat L2 broadcast domain | 1x Line-rate (Active node routes traffic) | 1-3 seconds (based on `advert_int` and timers) |
| **FRRouting (BGP / Anycast)** | Layer 3 ECMP peer connections to dual ToR leaf switches | L3 routed fabric (BGP capabilities on leaf switches) | Multi-path L3 ECMP load balancing | Sub-second with BFD (Bidirectional Forwarding Detection) |

---

## 3. Production Infrastructure Manifests & Configuration Files

### 3.1 Predictive Drive Failure Monitoring: `/etc/smartd.conf`

Production-grade S.M.A.R.T. daemon configuration to monitor NVMe drives and SATA/SAS disks, triggering predictive alert scripts before hard failure occurs.

```ini
# /etc/smartd.conf - Production SMART Monitoring Configuration
# Directives:
# -d auto   : Automatically detect device type
# -H        : Check SMART health status
# -l error  : Track SMART error log growth
# -l selftest : Track self-test log errors
# -f        : Check for failure of any usage attributes
# -s        : Run self-tests on schedule (Short test daily at 2AM, Long test Sundays at 3AM)
# -m        : Destination email/alert endpoint
# -M exec   : Custom notification handler binary

/dev/nvme0n1 -d nvme -H -l error -l selftest -W 2,55,65 -m sysadmin-alerts@infra.internal -M exec /usr/local/bin/smartd-pager.sh
/dev/sda -d auto -H -k on -l error -l selftest -f -s (S/../.././02|L/../../7/03) -W 4,45,55 -m sysadmin-alerts@infra.internal -M exec /usr/local/bin/smartd-pager.sh
/dev/sdb -d auto -H -k on -l error -l selftest -f -s (S/../.././02|L/../../7/03) -W 4,45,55 -m sysadmin-alerts@infra.internal -M exec /usr/local/bin/smartd-pager.sh
```

### 3.2 Service & System Resource Auto-Healing: `/etc/monit/monitrc` & Module Config

`/etc/monit/conf.d/node_health.monit` ensures core daemons remain operational and storage partitions do not exhaust node inodes or storage space.

```monit
# /etc/monit/conf.d/node_health.monit

set daemon 30 # Poll every 30 seconds
set log /var/log/monit.log

# Monitor Host Overall Performance Metrics
check host local_node address 127.0.0.1
    if loadavg (5min) > 16 then alert
    if memory usage > 85% then alert
    if cpu usage (system) > 30% for 3 cycles then alert

# Monitor Storage Mount Point
check filesystem rootfs path /
    if space usage > 80% for 2 cycles then alert
    if space usage > 92% then exec "/usr/local/bin/purge_scratch_space.sh"
    if inode usage > 88% then alert

# Monitor Keepalived Daemon Resilience
check process keepalived with pidfile /var/run/keepalived.pid
    start program = "/usr/bin/systemctl start keepalived"
    stop program  = "/usr/bin/systemctl stop keepalived"
    if failed host 127.0.0.1 port 112 protocol vrrp timeout 5 seconds then restart
    if 3 restarts within 5 cycles then timeout
```

### 3.3 Advanced Software RAID with Write-Intent Bitmap: Provisioning Script

This manifest script builds a degraded-resilient RAID 1 array using `mdadm`, attaches an internal write-intent bitmap to minimize recovery times, and persists the metadata configuration.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Zero out magic superblocks on raw target disks
mdadm --zero-superblock --force /dev/sdb1 /dev/sdc1

# 2. Assemble RAID 1 with an internal write-intent bitmap and 64K chunk size
mdadm --create /dev/md0 \
  --level=1 \
  --raid-devices=2 \
  --bitmap=internal \
  --bitmap-chunk=131072 \
  --metadata=1.2 \
  --name=node01:data_store \
  /dev/sdb1 /dev/sdc1

# 3. Format with ext4 featuring strict journal writeback guarantees
mkfs.ext4 -F -O journal_data_writeback,fast_commit -E lazy_itable_init=0,lazy_journal_init=0 /dev/md0

# 4. Generate persistent mdadm configuration
mkdir -p /etc/mdadm
mdadm --detail --scan --config=partitions >> /etc/mdadm/mdadm.conf
update-initramfs -u
```

### 3.4 Advanced LVM Redundancy: Thin-Pool with Auto-Extend and LVM RAID1

The configuration segment below enables automated volume management protections inside `/etc/lvm/lvm.conf` to expand thin pools before exhaustion automatically.

```ini
# /etc/lvm/lvm.conf (Partial snippet - Production critical settings)
activation {
    thin_pool_autoextend_threshold = 80
    thin_pool_autoextend_percent = 20
    snapshot_autoextend_threshold = 80
    snapshot_autoextend_percent = 20
    monitoring = 1
    raid_fault_policy = "warn"
    mirror_image_fault_policy = "remove"
}
```

Script to allocate an LVM RAID1 volume backed by redundant Physical Volumes:

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Initialize PVs
pvcreate /dev/nvme0n1p1 /dev/nvme1n1p1

# 2. Build Volume Group
vgcreate vg_production /dev/nvme0n1p1 /dev/nvme1n1p1

# 3. Create a mirrored Logical Volume (LVM RAID1) requiring both underlying PVs
lvcreate --type raid1 -m 1 -L 100G -n lv_database vg_production

# 4. Create a Thin Pool with automatic metadata redundancy
lvcreate --type thin-pool -L 200G -n thin_pool_apps vg_production
```

### 3.5 Network High Availability: LACP Bonding + VLAN Tagging (`systemd-networkd`)

To guarantee network path redundancy, we configure an IEEE 802.3ad (Mode 4) Bond over two physical interfaces (`eth0`, `eth1`), running a VLAN tag (`VLAN 100`) on top.

`**/etc/systemd/network/10-bond0.netdev**`
```ini
[NetDev]
Name=bond0
Kind=bond

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
MIIMonitorSec=100ms
LACPTransmitRate=fast
UpDelaySec=200ms
DownDelaySec=200ms
```

`**/etc/systemd/network/11-bond0-members.network**`
```ini
[Match]
Name=eth0 eth1

[Network]
Bond=bond0
```

`**/etc/systemd/network/20-bond0-vlan100.netdev**`
```ini
[NetDev]
Name=bond0.100
Kind=vlan

[VLAN]
Id=100
```

`**/etc/systemd/network/30-bond0-vlan100.network**`
```ini
[Match]
Name=bond0.100

[Network]
DHCP=no
Address=10.50.100.15/24
Gateway=10.50.100.1
DNS=10.50.100.2
```

### 3.6 Border Gateway Protocol (BGP) Multi-Homing: `/etc/frr/frr.conf`

Using FRRouting to peer a single host via BGP to dual Top-of-Rack switches for Layer-3 high availability and dynamic ECMP route injection.

```frr
! /etc/frr/frr.conf
frr version 8.5
frr defaults traditional
hostname node01.infra.internal
log syslogs informational
!
interface bond0.100
 ip address 10.50.100.15/24
!
router bgp 65001
 bgp router-id 10.50.100.15
 neighbor TOR_GROUP peer-group
 neighbor TOR_GROUP remote-as 65000
 neighbor TOR_GROUP timers 1 3
 neighbor 10.50.100.2 peer-group TOR_GROUP
 neighbor 10.50.100.3 peer-group TOR_GROUP
 !
 address-family ipv4 unicast
  redistribute connected
  neighbor TOR_GROUP activate
  maximum-paths 2
 exit-address-family
!
line vty
!
```

---

## 4. Real CLI Commands & Expected Terminal Outputs

### 4.1 S.M.A.R.T. Predictive Drive Health Inspection

Evaluating NVMe endurance attributes and controller error logs to detect pending failure.

```bash
$ smartctl -a /dev/nvme0n1
```
```text
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-5.15.0-88-generic] (local build)
Copyright (C) 2002-22, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

SMART/Health Information (NVMe Log 0x02)
Critical Warning:                   0x00
Temperature:                        34 Celsius
Available Spare:                    100%
Available Spare Threshold:          10%
Percentage Used:                    2%
Data Units Read:                    14,892,104 [7.62 TB]
Data Units Written:                 38,410,299 [19.6 TB]
Host Read Commands:                 120,491,012
Host Write Commands:                410,192,840
Controller Busy Time:               1,240 minutes
Power Cycles:                       14
Power On Hours:                     4,120
Unsafe Shutdowns:                   2
Media and Data Integrity Errors:    0
Error Information Log Entries:      0
Warning Comp. Temperature Time:     0
Critical Comp. Temperature Time:    0
```

### 4.2 Querying Software RAID Status & Write-Intent Bitmap

Checking array status, active bitmap bits, and rebuild progress on `/dev/md0`.

```bash
$ mdadm --detail /dev/md0
```
```text
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 14:22:10 2026
        Raid Level : raid1
        Array Size : 976434176 (931.20 GiB 1000.00 GB)
     Used Dev Size : 976434176 (931.20 GiB 1000.00 GB)
      Raid Devices : 2
     Total Devices : 2
       Persistence : Superblock is present

     Intent Bitmap : Internal pages 16

             State : active 
    Active Devices : 2
   Working Devices : 2
    Failed Devices : 0
     Spare Devices : 0

Consistency Policy : bitmap

              Name : node01:data_store  (local to host node01)
              UUID : 4f8a2b1c:9d3e5f7a:11223344:55667788
            Events : 4312

    Number   Major   Minor   RaidDevice State
       0       8       17        0      active sync   /dev/sdb1
       1       8       33        1      active sync   /dev/sdc1
```

### 4.3 Inspecting LVM RAID1 Mirror Sync & Health

Verifying logical volume layout and metadata sync percentage.

```bash
$ lvs -a -o lv_name,vg_name,attr,size,copy_percent,devices vg_production
```
```text
  LV                  VG            Attr       LSize   Copy%  Devices                           
  lv_database         vg_production rwi-a-r--- 100.00g 100.00 lv_database_rimage_0(0),lv_database_rimage_1(0)
  [lv_database_rmeta_0] vg_production rwi-a-r---   4.00m        /dev/nvme0n1p1(0)                 
  [lv_database_rmeta_1] vg_production rwi-a-r---   4.00m        /dev/nvme1n1p1(0)                 
  [lv_database_rimage_0] vg_production iwi-a-r--- 100.00g        /dev/nvme0n1p1(1)                 
  [lv_database_rimage_1] vg_production iwi-a-r--- 100.00g        /dev/nvme1n1p1(1)                 
  thin_pool_apps      vg_production twi-a-tz-- 200.00g  12.45 thin_pool_apps_tdata(0)             
```

### 4.4 Verifying Kernel Network Bonding Status

Directly inspecting the procfs interface to confirm LACP status and dual-link health.

```bash
$ cat /proc/net/bonding/bond0
```
```text
Ethernet Channel Bonding Driver: v5.15.0-88-generic

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200
Peer Encryption Protocol: none

802.3ad info
LACP rate: fast
Min links: 0
Aggregator selection policy (lacp_active): stable
System priority: 65535
System MAC address: 52:54:00:a1:b2:c3
Active Aggregator Info:
	Aggregator ID: 1
	Number of ports: 2
	Actor Key: 17
	Partner Key: 1
	Partner Mac Address: 00:1c:73:00:00:01

Slave Interface: eth0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a1:b2:c3
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_aggr

Slave Interface: eth1
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a1:b2:c4
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_aggr
```

### 4.5 Inspecting Routing Topology via FRRouting Shell (`vtysh`)

Verifying active BGP sessions and ECMP paths to the ToR switches.

```bash
$ vtysh -c "show ip bgp summary"
```
```text
IPv4 Unicast Summary:
BGP router identifier 10.50.100.15, local AS number 65001 vrf-id 0
BGP table version 12
RIB entries 5, using 960 bytes of memory
Peers 2, using 144 KiB of memory

Peer            V    AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down  State/PfxRcd   Desc
10.50.100.2     4 65000     412     415        0    0    0 06:45:12            24   N/A
10.50.100.3     4 65000     411     414        0    0    0 06:45:10            24   N/A

Total number of neighbors 2
```

---

## 5. Failure Verification & Diagnostic Guide

### 5.1 Step-by-Step Runbook: Simulated Disk Degradation & Hot Swap

When a disk enters a degraded state or fails S.M.A.R.T checks:

```
[ Step 1: Detect Failure ] ---> [ Step 2: Mark & Remove Disk ] ---> [ Step 3: Replace Physical Drive ] ---> [ Step 4: Partition & Re-add ] ---> [ Step 5: Verify Rebuild ]
```

```bash
# 1. Identify failing block device via kernel log trace
$ dmesg -T | grep -E "I/O error|SATA link down|medium error"

# 2. Force-fail and remove degraded disk (/dev/sdb1) from mdadm array
$ mdadm --manage /dev/md0 --fail /dev/sdb1
$ mdadm --manage /dev/md0 --remove /dev/sdb1

# 3. Verify hot-swap capability and remove disk safely from Linux SCSI layer
$ echo 1 > /sys/block/sdb/device/delete

# 4. Insert new drive, clone partition table from functional drive (/dev/sdc) to new drive (/dev/sdb)
$ sfdisk -d /dev/sdc | sfdisk /dev/sdb

# 5. Hot-add new partition to the active RAID array
$ mdadm --manage /dev/md0 --add /dev/sdb1

# 6. Monitor real-time reconstruction speed and kernel rebuild thread
$ watch -n 1 "cat /proc/mdstat"
```

### 5.2 Step-by-Step Runbook: Network Path & Link Flap Diagnostics

When LACP bonding drops an aggregator or drops frames:

```bash
# 1. Inspect interface link state and drop counters
$ ip -s link show bond0

# 2. Query physical transceiver optical levels and physical link speed via ethtool
$ ethtool eth0
$ ethtool -m eth0

# 3. Trace LACPDU frame exchange using tcpdump
$ tcpdump -nn -i eth0 ether proto 0x8809 -c 5

# 4. Check systemd-networkd operational state
$ networkctl status bond0
```

### 5.3 Step-by-Step Runbook: LVM Metadata Corruption Recovery

If LVM VG headers or metadata structures become corrupted:

```bash
# 1. Locate automatically created LVM metadata backup files
$ ls -la /etc/lvm/backup/

# 2. Test metadata restoration dry-run
$ vgcfgrestore --test -f /etc/lvm/backup/vg_production vg_production

# 3. Execute metadata restoration to raw PV headers
$ vgcfgrestore -f /etc/lvm/backup/vg_production vg_production

# 4. Scan and reactivate missing Volume Groups
$ vgscan
$ vgchange -ay vg_production
```

---

## 6. References

- **Linux Professional Institute (LPI) Official Objectives:**  
  [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
- **Linux Kernel Ethernet Bonding Driver Documentation:**  
  [https://www.kernel.org/doc/Documentation/networking/bonding.txt](https://www.kernel.org/doc/Documentation/networking/bonding.txt)
- **Linux RAID `mdadm` Official Administration Wiki:**  
  [https://raid.wiki.kernel.org/index.php/A_admin_guide](https://raid.wiki.kernel.org/index.php/A_admin_guide)
- **Red Hat Enterprise Linux 9 — Configuring and Managing LVM:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/)
- **Smartmontools Reference and Monitoring Manual:**  
  [https://www.smartmontools.org/wiki/TocDoc](https://www.smartmontools.org/wiki/TocDoc)
- **FRRouting Official User Documentation:**  
  [https://docs.frrouting.org/en/latest/bgp.html](https://docs.frrouting.org/en/latest/bgp.html)