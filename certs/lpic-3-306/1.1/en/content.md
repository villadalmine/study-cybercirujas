# LPIC-3 Exam 306-300 (v3.0) — Topic 361: High Availability Cluster Management

---

## 1. Motivation and Production Architectural Problem

### 1.1 The High Availability Problem in Production
In modern enterprise platforms, single-node architectures introduce Single Points of Failure (SPOFs). Unplanned downtime directly violates Service Level Agreements (SLAs), incurs financial losses, and degrades user trust. Achieving High Availability (HA) requires shifting from single-system reliability to distributed fault tolerance, where services survive hardware failures, network partitioning, kernel panics, and hypervisor crashes without manual operator intervention.

```
+-----------------------------------------------------------------------+
|                         UNPLANNED DOWNTIME COST                       |
+-----------------------------------------------------------------------+
|  Availability Target  | Allowed Downtime/Year | Allowed Downtime/Day  |
+-----------------------+-----------------------+-----------------------+
|  99.9%   (Three Nines)| 8 hours, 45 minutes   | 1 minute, 26 seconds  |
|  99.99%  (Four Nines) | 52 minutes, 35 sec    | 8.64 seconds          |
|  99.999% (Five Nines) | 5 minutes, 15 sec     | 0.86 seconds          |
+-----------------------------------------------------------------------+
```

To deliver 99.999% availability, system architects must compute:

$$\text{Availability} (A) = \frac{\text{MTBF}}{\text{MTBF} + \text{MTTR}}$$

Where:
*   **MTBF (Mean Time Between Failures)**: Average operational time between inherent system failures.
*   **MTTR (Mean Time To Repair)**: Average time required to diagnose, isolate, fail over, and restore normal operations.

Minimizing MTTR requires automated failure detection, automated fencing, and instant state or IP migration.

---

### 1.2 Theoretical Foundations of Distributed Cluster Consensus

#### The FLP Impossibility Theorem (Fischer, Lynch, Paterson, 1985)
In an asynchronous network model, no deterministic consensus protocol can guarantee both **Safety** (never reaching an incorrect agreement) and **Liveness** (eventually reaching agreement) in the presence of even a single unannounced process crash. High availability cluster software must make explicit trade-offs—favoring Safety over Liveness during network splits to avoid data corruption.

#### Quorum and Split-Brain Prevention
When network partitioning splits an $N$-node cluster into isolated segments, multiple segments might attempt to assume ownership of shared storage or IP resources simultaneously. This state is known as **Split-Brain**.

```
                   +------------------+
                   |  Original Node 1 | (Node crashes or link severs)
                   +--------+---------+
                            |
                 [Network Partitioning]
                            |
           +----------------+----------------+
           |                                 |
           v                                 v
+--------------------+            +--------------------+
| Cluster Segment A  |            | Cluster Segment B  |
|   (Node 1, Node 2) |            |      (Node 3)      |
|    2/3 Votes       |            |     1/3 Votes      |
|   QUORATE (Active) |            |  INQUORATE (Halt)  |
+--------------------+            +--------------------+
```

To prevent concurrent modifications to stateful components, cluster engines implement **Quorum**:

$$Q = \left\lfloor \frac{N}{2} \right\rfloor + 1$$

*   A cluster segment is **Quorate** if it contains strictly more than $N/2$ votes.
*   An **Inquorate** partition must immediately cease all resource execution, unmount shared storage, and drop floating IP addresses.
*   **Two-Node Quorum Dilemma**: In a 2-node cluster ($N=2$), $Q = 2$. If one node fails, the remaining node has 1 vote out of 2 ($50\%$), losing quorum. To resolve this, engines use tie-breaker devices (e.g., `qdevice` in Corosync) or explicit two-node rules (`two_node: 1` with votequorum).

---

### 1.3 Fencing and STONITH Mechanics
Quorum alone is insufficient if an unresponsive node is frozen (e.g., experiencing DMA stalls, kernel lockups, or asynchronous network routing loops) and still writing to shared storage. 

**STONITH (Shoot The Other Node In The Head)** guarantees data integrity by forcefully resetting or cutting power to an uncommunicative node before another node imports its resources.

```
+-----------------------------------------------------------------------------------+
|                            STONITH EXECUTION SEQUENCE                             |
+-----------------------------------------------------------------------------------+
| 1. DC (Designated Controller) detects node failure via Corosync heartbeat timeout.|
| 2. Cluster freezes all resource migrations pending STONITH execution.             |
| 3. DC dispatches fencing request to fence_ipmilan agent targeting node2.           |
| 4. Out-of-Band (OOB) management controller (IPMI/iLO/iDRAC) cuts hardware power.  |
| 5. IPMI agent returns success (power state = off) to DC.                         |
| 6. DC releases resource locks and safely recovers services onto node1.            |
+-----------------------------------------------------------------------------------+
```

Fencing operates at two primary architectural levels:
1.  **Node-Level Fencing (Hardware Power Fencing)**: Uses IPMI, HPE iLO, Dell iDRAC, or PDU switches to force physical power off/cycle operations.
2.  **Storage-Level Fencing (SBD - Storage-Based Death)**: Employs hardware watchdogs (`/dev/watchdog`) and shared block devices (SAN/iSCSI LUNs). Nodes regularly clear a hardware watchdog timer; if Corosync loses quorum or misses heartbeat slots on the shared disk, the hardware watchdog triggers an ungraceful hardware reset (`sysrq-trigger` kernel panic/reset).

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Cluster Topology Architectures

| Architecture Topology | State Synchronization | Recovery Speed (RTO) | Storage Requirements | Scalability Limit | Primary Risk / Failure Mode |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Active / Passive (Hot Standby)** | Asynchronous or Synchronous Block-level replication (DRBD) | Fast (5s - 30s) | Replicated Storage per node or Shared SAN | Low (2 - 4 nodes) | Resource idle cost; failover delay during DB recovery |
| **Active / Active (Stateful)** | Distributed Lock Manager (DLM) + Clustered FS (GFS2/OCFS2) | Zero / Near-Instant | Shared Storage (Fibre Channel SAN / iSCSI) | Medium (4 - 16 nodes) | Lock contention overhead; DLM deadlocks during network partition |
| **Shared-Nothing (Stateless)** | No state on cluster nodes; DB offloaded | Sub-second | Local storage for OS only | Extremely High (100+ nodes) | External dependency failure (Backend DB overload) |

---

### 2.2 Load Balancing & High Availability Technologies

| Technology | Layer | Heartbeat Mechanism | VIP Control | State Persistence | Ideal Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Keepalived (VRRP)** | Layer 3 / 4 | VRRP Multicast (`224.0.0.18`) or Unicast UDP | Kernel ARP gratuitous broadcasts | None (Stateless failover) | Simple Floating IP failover for ingress routers & proxy pairs |
| **Pacemaker / Corosync** | Layer 3 - 7 | Totem Single Ring Protocol (UDP Unicast/Multicast) | OCF Resource Agents (`IPaddr2`) | Complete state machine (CIB XML tree) | Multi-resource orchestration (IP + FS + Database + STONITH) |
| **HAProxy** | Layer 4 / 7 | Health checking (HTTP, TCP, SMTP, MySQL polling) | External (requires Keepalived/Pacemaker for VIP) | Stick tables, SSL sessions, connection tracking | L4/L7 traffic routing, TLS termination, HTTP header rewrite |
| **Linux Virtual Server (IPVS)** | Layer 4 | External (managed via Keepalived or `ldirectord`) | Kernel netfilter IPVS table | Connection sync daemon (`ipvsadm --start-daemon`) | High-throughput kernel-space packet routing (LVS-DR / LVS-NAT) |

---

### 2.3 Fencing Mechanisms: IPMI vs. SBD vs. Network Fencing

| Fencing Method | Transport Path | Hardware Requirement | Dependency | Risk of False Fencing | RTO Impact |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Hardware OOB (IPMI / iLO)** | Dedicated Management LAN | BMC / IPMI Controller on host | Out-of-band network infrastructure | Low | Moderate (~15s - 45s power cycle) |
| **Storage-Based Death (SBD)** | Shared SAN LUN + Watchdog Device | Hardware Watchdog (`/dev/watchdog`) | Shared block storage | Extremely Low | Fast (Watchdog timeout, e.g., 10s reset) |
| **Managed PDU Fencing** | Ethernet to Smart PDU | Networkable Power Distribution Unit | PDU responsiveness & mapping | Low | Moderate (~30s) |
| **Network Switch Fencing (SNMP)** | Management IP to Switch | Managed L2/L3 Network Switch | Switch API / SNMP responsiveness | High (leaves node powered on) | Fast (Immediate interface shut) |

---

## 3. Production Configuration Manifests

The following configurations set up a 2-node HA cluster (`node1`: `192.168.10.11`, `node2`: `192.168.10.12`) running Keepalived, HAProxy, Corosync, and Pacemaker.

```
                      +----------------------------------+
                      |       Virtual IP (VIP)           |
                      |         192.168.10.100           |
                      +----------------+-----------------+
                                       |
                     +-----------------+-----------------+
                     |                                   |
                     v                                   v
         +-----------------------+           +-----------------------+
         |        NODE 1         |           |        NODE 2         |
         |     192.168.10.11     |           |     192.168.10.12     |
         |-----------------------|           |-----------------------|
         | Corosync / Pacemaker  | <=======> | Corosync / Pacemaker  |
         | Keepalived (Master)   |  UDP 5405 | Keepalived (Backup)   |
         | HAProxy (Active)      |  VRRP 112 | HAProxy (Active)      |
         +-----------------------+           +-----------------------+
```

---

### 3.1 `/etc/corosync/corosync.conf`
Production-grade Corosync configuration utilizing the Totem Single Ring Protocol over Unicast (`udpu`) with cryptographic authentication and votequorum.

```ini
totem {
    version: 2
    cluster_name: production_ha_cluster
    crypto_cipher: aes256
    crypto_hash: sha256
    transport: udpu
    token: 10000
    token_retransmits_before_loss_const: 10
    join: 60
    consensus: 12000
    max_messages: 20
    miss_count_const: 5
    interface {
        ringnumber: 0
        bindnetaddr: 192.168.10.0
        mcastport: 5405
        ttl: 1
    }
}

logging {
    to_logfile: yes
    logfile: /var/log/cluster/corosync.log
    to_syslog: yes
    syslog_facility: daemon
    debug: off
    logger_subsys {
        subsys: QUORUM
        debug: off
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    expected_votes: 2
    wait_for_all: 1
    last_man_standing: 1
    last_man_standing_window: 10000
}

nodelist {
    node {
        ring0_addr: 192.168.10.11
        nodeid: 1
        name: node1
    }
    node {
        ring0_addr: 192.168.10.12
        nodeid: 2
        name: node2
    }
}
```

---

### 3.2 `/etc/keepalived/keepalived.conf`
Production Keepalived configuration for floating IP management on `node1` (Master).

```haproxy
global_defs {
    router_id node1_vrrp
    enable_script_security
    script_user root
    max_auto_priority
}

vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 112
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K33pAliv3Sec2026
    }
    unicast_src_ip 192.168.10.11
    unicast_peer {
        192.168.10.12
    }
    virtual_ipaddress {
        192.168.10.100/24 dev eth0 label eth0:vip
    }
    track_script {
        check_haproxy
    }
    notify_master "/etc/keepalived/scripts/notify.sh MASTER"
    notify_backup "/etc/keepalived/scripts/notify.sh BACKUP"
    notify_fault  "/etc/keepalived/scripts/notify.sh FAULT"
}
```

---

### 3.3 `/etc/haproxy/haproxy.cfg`
High-performance Layer 4 and Layer 7 HAProxy setup with socket administration, health checks, and stick tables.

```haproxy
global
    log /dev/log local0 info
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 50000
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log global
    mode http
    option httplog
    option dontlognull
    option redispatch
    retries 3
    timeout queue 1m
    timeout connect 5s
    timeout client 50s
    timeout server 50s
    timeout http-request 10s
    maxconn 40000

frontend stats
    mode http
    bind 192.168.10.11:8404
    stats enable
    stats uri /
    stats refresh 5s
    stats admin if TRUE

frontend http_in
    bind 192.168.10.100:80
    mode http
    option forwardfor
    http-request set-header X-Forwarded-Proto http
    default_backend web_app_servers

backend web_app_servers
    mode http
    balance leastconn
    cookie SERVERID insert indirect nocache
    option httpchk GET /health HTTP/1.1\r\nHost:\ localhost
    http-check expect status 200
    server app1 192.168.10.21:8080 check inter 2000 fall 3 rise 2 cookie app1
    server app2 192.168.10.22:8080 check inter 2000 fall 3 rise 2 cookie app2
```

---

### 3.4 Pacemaker CIB Production Provisioning Script
Command sequence using `pcs` to build the cluster configuration, configure STONITH fencing via IPMI, enforce resource constraints, and manage cluster services.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Disable STONITH temporarily during initial provisioning
pcs property set stonith-enabled=false

# 2. Configure Quorum Policy and Failback Defaults
pcs property set no-quorum-policy=stop
pcs property set default-resource-stickiness=100

# 3. Create Virtual IP Resource (OCF Resource Agent)
pcs resource create Cluster_VIP ocf:heartbeat:IPaddr2 \
    ip=192.168.10.100 \
    cidr_netmask=24 \
    nic=eth0 \
    op monitor interval=10s timeout=20s

# 4. Create Systemd Service Resource for HAProxy
pcs resource create HAProxy_Service systemd:haproxy \
    op monitor interval=15s timeout=20s

# 5. Define Colocation Constraint (Run HAProxy on the same node as VIP)
pcs constraint colocation add HAProxy_Service with Cluster_VIP INFINITY

# 6. Define Order Constraint (Start VIP before HAProxy)
pcs constraint order start Cluster_VIP then start HAProxy_Service

# 7. Add Hardware IPMI STONITH Devices for Node Fencing
pcs stonith create fence_node1 fence_ipmilan \
    pcmk_host_list="node1" \
    ipaddr="192.168.10.211" \
    login="admin" \
    passwd="SecureIpmiPassword123!" \
    lanplus=1 \
    action=reboot \
    op monitor interval=60s

pcs stonith create fence_node2 fence_ipmilan \
    pcmk_host_list="node2" \
    ipaddr="192.168.10.212" \
    login="admin" \
    passwd="SecureIpmiPassword123!" \
    lanplus=1 \
    action=reboot \
    op monitor interval=60s

# 8. Re-enable STONITH for Production Readiness
pcs property set stonith-enabled=true
```

---

## 4. Real CLI Commands & Actual Terminal Outputs

### 4.1 Corosync Quorum & Ring Status Inspection

```console
$ sudo corosync-cfgtool -s
Plotting ring status...
Ring ID 0
	id	= 192.168.10.11
	status	= ring 0 active with no faults
```

```console
$ sudo corosync-quorumtool -s
Quorum information
------------------
Date:            Thu Aug  6 17:12:20 2026
Quorum provider: corosync_votequorum
Nodes:           2
Node ID:         1
Ring ID:         0/12
Quorate:         Yes

Votequorum information
----------------------
Expected votes:   2
Highest expected: 2
Total votes:      2
Quorum:           2
Flags:            2Node Quorate LMS 

Node information
----------------
Nodeid  Votes Name
     1      1 node1 (local)
     2      1 node2
```

---

### 4.2 Pacemaker Full Cluster Status (`pcs status --full`)

```console
$ sudo pcs status --full
Cluster name: production_ha_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: node1 (version 2.1.5-1.el9-a3f895f) - partition with quorum
  * Last updated: Thu Aug  6 17:12:25 2026
  * Last change:  Thu Aug  6 16:45:10 2026 by root via cibadmin on node1
  * 2 nodes configured
  * 4 resource instances configured

Node List:
  * Online: [ node1 (1) node2 (2) ]

Full List of Resources:
  * Resource Group: HA_Group:
    * Cluster_VIP	(ocf::heartbeat:IPaddr2):	Started node1
    * HAProxy_Service	(systemd:haproxy):	Started node1
  * STONITH Devices:
    * fence_node1	(stonith:fence_ipmilan):	Started node2
    * fence_node2	(stonith:fence_ipmilan):	Started node1

PCS DPD Daemon Status:
  pcsd: active/enabled on all nodes

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

---

### 4.3 HAProxy Socket Runtime Diagnostics

```console
$ echo "show info" | sudo socat stdio /run/haproxy/admin.sock
Name: HAProxy
Version: 2.8.3-2
Release_date: 2023/09/08
Nbthread: 4
Nbproc: 1
Process_num: 1
Pid: 14205
Uptime: 2d 04h12m18s
Uptime_sec: 187938
Limitconn: 50000
Maxconn: 50000
CurrConns: 142
CumConns: 891042
Tasks: 158
Run_queue: 1
Node: node1
Stopping: 0
Jobs: 144
UnstoppableJobs: 0
ConnRate: 45
MaxConnRate: 1250
SessRate: 45
MaxSessRate: 1250
```

```console
$ echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | cut -d',' -f1,2,5,18,37,40
# pxname,svname,scur,state,status,check_status
stats,FRONTEND,1,OPEN,OPEN,
stats,BACKEND,0,OPEN,UP,
http_in,FRONTEND,141,OPEN,OPEN,
web_app_servers,app1,68,UP,UP,L7OK
web_app_servers,app2,73,UP,UP,L7OK
web_app_servers,BACKEND,141,UP,UP,
```

---

### 4.4 Keepalived Runtime State and IP Alias Verification

```console
$ ip addr show dev eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    inet 192.168.10.11/24 brd 192.168.10.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet 192.168.10.100/24 scope global secondary eth0:vip
       valid_lft forever preferred_lft forever
    inet6 fe80::5054:ff:fe12:3456/64 scope link 
       valid_lft forever preferred_lft forever
```

```console
$ sudo systemctl status keepalived.service
● keepalived.service - LVS and VRRP High Availability Monitor
     Loaded: loaded (/usr/lib/systemd/system/keepalived.service; enabled; preset: disabled)
     Active: active (running) since Tue 2026-08-04 12:00:00 UTC; 2 days ago
   Main PID: 8912 (keepalived)
      Tasks: 2 (limit: 48800)
     Memory: 6.4M
        CPU: 12.410s
     CGroup: /system.slice/keepalived.service
             ├─8912 /usr/sbin/keepalived --dont-fork -D
             └─8913 /usr/sbin/keepalived --dont-fork -D

Aug 06 14:10:02 node1 Keepalived_vrrp[8913]: (VI_1) Entering MASTER STATE
Aug 06 14:10:03 node1 Keepalived_vrrp[8913]: (VI_1) setting VIPs.
Aug 06 14:10:03 node1 Keepalived_vrrp[8913]: (VI_1) Sending gratuitous ARP on eth0 for 192.168.10.100
Aug 06 14:10:03 node1 Keepalived_vrrp[8913]: (VI_1) Registering gratuitous ARP shared address 192.168.10.100
```

---

## 5. Verification & Fault Troubleshooting Guide

### 5.1 Systemic Diagnostic Workflow Tree

```
                       +-----------------------------------+
                       |      High Availability Incident    |
                       +-----------------+-----------------+
                                         |
                                         v
                     +---------------------------------------+
                     |  Is VIP (192.168.10.100) reachable?   |
                     +-------------------+-------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                    [ NO ]                              [ YES ]
                       |                                   |
                       v                                   v
+---------------------------------------------+ +------------------------------------+
| Check Layer 2 / VRRP                        | | Check Application Layer          |
| 1. tcpdump -i eth0 vrrp                     | | 1. curl http://192.168.10.100/   |
| 2. Check for Master collisions (Dual Master)| | 2. Inspect HAProxy Socket stats  |
| 3. Check firewall (IP Protocol 112 drop)    | | 3. Verify backend service health |
+---------------------------------------------+ +------------------------------------+
                       |
                       v
                     +---------------------------------------+
                     | Is Pacemaker/Corosync Quorate?        |
                     +-------------------+-------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                    [ NO ]                              [ YES ]
                       |                                   |
                       v                                   v
+---------------------------------------------+ +------------------------------------+
| Quorum & Network Partitioning Debug         | | Resource Failure / STONITH Debug   |
| 1. corosync-cfgtool -s                      | | 1. pcs status                    |
| 2. Verify UDP 5405 traffic via tcpdump      | | 2. pcs resource failcount show   |
| 3. Check /var/log/cluster/corosync.log      | | 3. Test IPMI fencing agent manually|
+---------------------------------------------+ +------------------------------------+
```

---

### 5.2 Deep-Dive Troubleshooting Scenarios & Resolution Commands

#### Scenario A: Dual Master Condition (Keepalived VRRP Split-Brain)
*   **Symptom**: Both `node1` and `node2` assign `192.168.10.100` to `eth0`, causing packet loss and IP address conflicts.
*   **Root Cause**: Firewall (`iptables` / `nftables`) blocking VRRP multicast protocol 112 (`224.0.0.18`), or unicast UDP packets between nodes.
*   **Diagnosis**:
    ```bash
    # Execute packet capture on node2 to see if VRRP advertisements arrive from node1
    $ sudo tcpdump -nn -i eth0 proto 112
    ```
*   **Remediation**:
    ```bash
    # Open VRRP traffic in firewalld on both nodes
    $ sudo firewall-cmd --add-protocol=vrrp --permanent
    $ sudo firewall-cmd --reload
    ```

---

#### Scenario B: Corosync Ring Failed / Lost Communication
*   **Symptom**: `corosync-cfgtool -s` shows `status = FAULTY`.
*   **Root Cause**: Network interface flap, misconfigured network bind address, or firewall blocking UDP port 5405.
*   **Diagnosis**:
    ```bash
    # Check corosync systemd journal logs
    $ sudo journalctl -u corosync.service -n 50 --no-pager
    
    # Trace UDP cluster communication port
    $ sudo tcpdump -nn -i eth0 port 5405
    ```
*   **Remediation**:
    ```bash
    # Re-evaluate and reset ring interface state without restarting corosync
    $ sudo corosync-cfgtool -r
    ```

---

#### Scenario C: Resource Fails to Start (Stuck in Failed State)
*   **Symptom**: `pcs status` reports `Failed Resource Actions: HAProxy_Service_start_0 on node1 'unknown error'`.
*   **Diagnosis**:
    ```bash
    # Inspect detailed error logs for the specific resource
    $ sudo pcs resource debug-start HAProxy_Service
    ```
*   **Remediation**:
    ```bash
    # Fix the underlying issue (e.g., syntax error in /etc/haproxy/haproxy.cfg), then clear fail counts:
    $ sudo pcs resource cleanup HAProxy_Service
    ```

---

#### Scenario D: STONITH Fencing Loop / Execution Failure
*   **Symptom**: Node constantly reboots, or DC reports `Fence action failed`.
*   **Diagnosis**:
    ```bash
    # Manually test fence agent connectivity to out-of-band IPMI interface
    $ fence_ipmilan -a 192.168.10.211 -l admin -p "SecureIpmiPassword123!" -L lanplus -o status
    ```
*   **Remediation**:
    If a node is stuck in a fencing loop during maintenance, temporarily unman the node or override STONITH:
    ```bash
    # Put node into maintenance mode to suppress fence actions
    $ sudo pcs node maintenance node2
    
    # Unmanage specific failing resource during active recovery
    $ sudo pcs resource unmanage HAProxy_Service
    ```

---

### 5.3 Emergency Cluster Recovery Commands Quick Reference

```bash
# Force temporary quorum emergency override on a single surviving node
$ sudo corosync-quorumtool -e 1

# Export full raw Cluster Information Base (CIB) XML configuration
$ sudo cibadmin --query > /tmp/cib_backup.xml

# Force replacement of active CIB configuration from file
$ sudo cibadmin --replace --xml-file /tmp/cib_backup.xml

# Complete cluster-wide service shutdown across all nodes
$ sudo pcs cluster stop --all

# Complete cluster-wide service startup across all nodes
$ sudo pcs cluster start --all
```

---

## 6. References

*   **Linux Professional Institute (LPI) Official LPIC-3 306 Objectives**:  
    [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
*   **Clusterlabs Pacemaker Documentation**:  
    [https://clusterlabs.org/pacemaker/doc/](https://clusterlabs.org/pacemaker/doc/)
*   **Corosync Official Documentation**:  
    [https://corosync.github.io/corosync/](https://corosync.github.io/corosync/)
*   **Keepalived Official Documentation**:  
    [https://www.keepalived.org/documentation.html](https://www.keepalived.org/documentation.html)
*   **HAProxy Enterprise & Community Documentation**:  
    [https://www.haproxy.org/#docs](https://www.haproxy.org/#docs)
*   **Linux Virtual Server (IPVS) Project**:  
    [http://www.linuxvirtualserver.org/software/ipvs.html](http://www.linuxvirtualserver.org/software/ipvs.html)