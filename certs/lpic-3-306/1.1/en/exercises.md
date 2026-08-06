# Production Study Guide & Guided Exercises: LPIC-3 Exam 306-300 (Topic 306.1)
**Exam:** LPIC-3 High Availability and Storage Clusters (306-300, Version 3.0)  
**Topic:** 306.1 High Availability Cluster Management  
**Weight:** 25  
**Official Reference:** [LPI LPIC-3 306 Objectives](https://www.lpi.org/our-certifications/lpic-3-306-overview/) | [ClusterLabs Documentation](https://clusterlabs.org/pacemaker/doc/)

---

## Exercise 1: Corosync 3 & Pacemaker Architecture, Quorum, and Split-Brain Mechanics

### Architecture & Mechanics Overview
Corosync provides the cluster membership and messaging layer (via the **Kronosnet / knet** transport protocol in modern deployments), while Pacemaker acts as the Distributed Resource Manager (CRM). 
Quorum is maintained using the `corosync_votequorum` provider. In a cluster of \(N\) nodes, quorum requires:

$$\text{Quorum} = \left\lfloor \frac{N}{2} \right\rfloor + 1$$

In a 2-node cluster (\(N=2\)), single-node loss drops votes to 1 out of 2 (50%), losing quorum unless `two_node: 1` or `auto_tie_breaker: 1` is configured.

```
       +---------------------------------------------+
       |             Pacemaker (crmd/pengine)        |
       +---------------------------------------------+
       |               Corosync 3 (knet)             |
       +-------------------------------+-------------+
                                       |
           +---------------------------+---------------------------+
           | Link 0 (192.168.122.10/11)  | Link 1 (10.0.10.10/11)    |
           v                           v
     [ Node-01 ] <=================================> [ Node-02 ]
                     Redundant Knet Links (Ring 0 & 1)
```

---

### Guided Execution Steps

#### Step 1.1: Examine and Deploy Production `corosync.conf`
Deploy the following valid, multi-link redundant Corosync 3 configuration file on both nodes (`node-01` and `node-02`).

File Path: `/etc/corosync/corosync.conf`
```ini
totem {
    version: 2
    cluster_name: ha_prod_cluster
    transport: knet
    crypto_cipher: aes256
    crypto_hash: sha256
}

nodelist {
    node {
        ring0_addr: 192.168.122.10
        ring1_addr: 10.0.10.10
        nodeid: 1
        name: node-01
    }
    node {
        ring0_addr: 192.168.122.11
        ring1_addr: 10.0.10.11
        nodeid: 2
        name: node-02
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    wait_for_all: 1
    auto_tie_breaker: 0
}

logging {
    to_logfile: yes
    logfile: /var/log/cluster/corosync.log
    to_syslog: yes
    syslog_facility: daemon
    debug: off
    timestamp: on
    logger_subsys {
        subsys: QUORUM
        debug: off
    }
}
```

#### Step 1.2: Start Services & Inspect Knet Link Status
Execute the following commands on `node-01`:

```bash
systemctl restart corosync pacemaker
corosync-cfgtool -s
```

**Expected Command Output:**
```text
Printing link status.
Ring ID 0
	nodeid: 1
	host: 192.168.122.10
	status: enabled connected
Ring ID 1
	nodeid: 1
	host: 10.0.10.10
	status: enabled connected
```

#### Step 1.3: Inspect Quorum via Runtime Map (`corosync-cmapctl`)
Verify active vote accounting and node membership:

```bash
corosync-cmapctl | grep -E "quorum\.(quorate|total_votes|expected_votes)"
```

**Expected Command Output:**
```text
quorum.expected_votes (u32) = 2
quorum.quorate (u8) = 1
quorum.total_votes (u32) = 2
```

---

### Step 1 Comprehension Questions

1. In a 2-node cluster with `two_node: 1` and `wait_for_all: 1`, what specific boot sequence behavior occurs if `node-01` powers on while `node-02` remains powered off?
2. If `ring0_addr` experiences a complete switch failure, how does Corosync 3 Knet handle traffic redirection to `ring1_addr`, and what metric determines link health?

---

## Exercise 2: STONITH / Fencing Mechanisms & Node Isolation Mechanics

### Architecture & Mechanics Overview
STONITH (**S**hoot **T**he **O**ther **N**ode **I**n **T**he **H**ead) prevents data corruption caused by concurrent writes to shared storage during split-brain conditions.

Pacemaker enforces a **Fence-Before-Recovery** policy. When a node stops responding to cluster heartbeats, Pacemaker's Cluster Resource Manager Daemon (`crmd`) initiates a fencing action. The Policy Engine (`pengine`) will **never** re-assign or restart resources previously assigned to an unconfirmed node until the fencing agent returns a confirmed exit status (`0`).

```
 +------------------+        Heartbeat Lost       +------------------+
 |  node-01 (Master)| <=========================X |  node-02 (Failed)|
 +------------------+                             +------------------+
          |                                                ^
          | 1. Execute fence_ipmilan / SBD                   |
          +------------------------------------------------+
                             2. Hard Power Off / NMI Watchdog Reset
```

---

### Guided Execution Steps

#### Step 2.1: Configure Storage-Based Death (SBD) Watchdog Mechanism
Edit SBD cluster configuration on both nodes to enable kernel watchdog integration.

File Path: `/etc/sysconfig/sbd` (or `/etc/default/sbd` on Debian/Ubuntu)
```bash
SBD_DEVICE="/dev/sdc1"
SBD_OPTS="-n node-01 -t 10 -4 20"
SBD_WATCHDOG_DEV="/dev/watchdog"
SBD_WATCHDOG_TIMEOUT=5
SBD_TIMEOUT_ACTION="flush,reboot"
SBD_MOVE_TO_ROOT_CGROUP=yes
```

Initialize the SBD disk header across nodes:
```bash
sbd -d /dev/sdc1 create
sbd -d /dev/sdc1 dump
```

**Expected Command Output:**
```text
Header version:     2.1
Number of slots:    255
Sector size:        512
Timeout (watchdog): 5
Timeout (allocate): 2
Timeout (loop):     1
Timeout (msgwait):  10
```

#### Step 2.2: Register IPMI STONITH Resource in Pacemaker
Execute on `node-01` using `pcs`:

```bash
pcs property set stonith-enabled=true
pcs stonith create fence_node02 fence_ipmilan \
    ipaddr="192.168.122.250" \
    login="admin" \
    passwd="SecretPassword123" \
    lanplus=1 \
    action=reboot \
    pcmk_host_list="node-02" \
    delay=15 \
    op monitor interval=60s timeout=20s
```

#### Step 2.3: Test STONITH Execution and Diagnostic Tracing
Simulate an out-of-band fence request targeting `node-02`:

```bash
stonith_admin --reboot node-02
pcs status | grep -A 5 "Fencing Devices"
```

**Expected Command Output:**
```text
Fencing Devices:
  * Resource: fence_node02 (class=stonith:fence_ipmilan)
    * fence_node02 Started node-01

Node List:
  * Node node-02: UNCLEAN (offline)
```

Inspect Pacemaker fence history:
```bash
pcs stonith history show
```

**Expected Command Output:**
```text
Node: node-02
  * Action: reboot, Targeted: node-02, Requested-by: node-01, Client: stonith_admin, Result: success
```

---

### Step 2 Comprehension Questions

1. Why is the `delay=15` parameter explicitly set on `fence_node02` when configuring IPMI fencing in a two-node cluster where each node has its own distinct fence agent device?
2. What happens to Pacemaker cluster resources running on `node-02` if the fence agent `fence_ipmilan` times out or returns a non-zero exit code during a STONITH event?

---

## Exercise 3: Advanced Resource Management, Constraints, and Score Mechanics

### Architecture & Mechanics Overview
Pacemaker resource placement decision logic is strictly driven by **score mathematics**.
A node's final placement score for a given resource \(R\) is calculated as:

$$\text{Score}_{\text{final}}(N) = \text{Score}_{\text{base}} + \sum \text{Score}_{\text{location}} + \sum \text{Score}_{\text{colocation}} + \text{Stickiness} - (\text{FailCount} \times \text{MigrationPenalty})$$

- $\text{INFINITY} = +1,000,000$ (Must run on this node)
- $-\text{INFINITY} = -1,000,000$ (Must **NOT** run on this node)

---

### Guided Execution Steps

#### Step 3.1: Define OCF Floating VIP and Promotable DRBD Storage Resource
Deploy an OCF resource for Virtual IP (`IPaddr2`) and a Promotable (Master/Slave) storage resource.

```bash
# Create Virtual IP Resource
pcs resource create Cluster_VIP ocf:heartbeat:IPaddr2 \
    ip="192.168.122.200" \
    cidr_netmask="24" \
    nic="eth0" \
    op monitor interval=10s timeout=20s

# Create DRBD Data Resource
pcs resource create DRBD_Data ocf:linbit:drbd \
    drbd_resource="r0" \
    op monitor interval=15s role="Unpromoted" \
    op monitor interval=10s role="Promoted"

# Define Promotable Clone
pcs resource promotable DRBD_Data \
    promoted-max=1 \
    promoted-node-max=1 \
    clone-max=2 \
    clone-node-max=1
```

#### Step 3.2: Configure Multi-layer Resource Constraints & Stickiness
Apply stickiness globally and enforce ordering and colocation rules:

```bash
# Set Resource Stickiness (Prevents automatic failback on node recovery)
pcs resource defaults update resource-stickiness=100

# Enforce Colocation: VIP must run where DRBD is Promoted (Master)
pcs constraint colocation add Cluster_VIP with promoted DRBD_Data-clone INFINITY

# Enforce Ordering: DRBD must be Promoted before VIP starts
pcs constraint order promote DRBD_Data-clone then start Cluster_VIP

# Enforce Location Preference for node-01
pcs constraint location Cluster_VIP prefers node-01=50
```

#### Step 3.3: Verify Constraint Graph Configuration
Display structural rules via CLI:

```bash
pcs constraint --full
```

**Expected Command Output:**
```text
Location Constraints:
  Resource: Cluster_VIP
    Enabled on: node-01 (score:50) (id:location-Cluster_VIP-node-01-50)
Ordering Constraints:
  Promote DRBD_Data-clone then start Cluster_VIP (kind:Mandatory) (id:order-DRBD_Data-clone-Cluster_VIP-mandatory)
Colocation Constraints:
  Cluster_VIP with DRBD_Data-clone (score:INFINITY) (rsc-role:Started) (with-rsc-role:Promoted) (id:colocation-Cluster_VIP-DRBD_Data-clone-INFINITY)
```

#### Step 3.4: Configure Migration Thresholds & Test Failure Fallback
Set failure tracking metrics on `Cluster_VIP`:

```bash
pcs resource update Cluster_VIP meta migration-threshold=2 failure-timeout=60s
```

Simulate resource failure by forcibly unbinding the secondary IP address:
```bash
ip addr del 192.168.122.200/24 dev eth0
pcs resource failcount show Cluster_VIP
```

**Expected Command Output:**
```text
Name: Cluster_VIP
  node-01: 1
```

---

### Step 3 Comprehension Questions

1. If `Cluster_VIP` has `resource-stickiness=100` and a location constraint `prefers node-01=50`, where will `Cluster_VIP` run when `node-01` reboots and rejoins the healthy cluster? Show the score calculation.
2. What is the operational difference between `kind=Mandatory` (default) and `kind=Optional` in a Pacemaker Ordering Constraint?

---

## Exercise 4: Maintenance Modes, Troubleshooting & Cluster Diagnostic Workflows

### Architecture & Mechanics Overview
During cluster software upgrades, kernel patches, or SAN storage maintenance, administrators must suppress Pacemaker automated monitoring and recovery actions to prevent unwanted STONITH triggers or false-positive failovers.

Pacemaker provides two levels of isolation:
1. **Unmanaged Resource State**: Monitors and action calls are disabled for a specific resource.
2. **Cluster Maintenance Mode**: Global suppression of all fence actions and resource monitoring.

---

### Guided Execution Steps

#### Step 4.1: Enter Maintenance Modes

##### Option A: Single Node Maintenance Mode
```bash
pcs node maintenance node-02
pcs status
```

**Expected Command Output:**
```text
Cluster name: ha_prod_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: node-01 (version 2.1.5) - partition with quorum
  * Last updated: Thu Aug  6 17:13:08 2026
  * Last change:  Thu Aug  6 17:10:00 2026 by root via cibadmin on node-01
  * 2 nodes configured
  * 2 resource instances configured

Node List:
  * Node node-01: online
  * Node node-02: maintenance

Full List of Resources:
  * Cluster_VIP	(ocf::heartbeat:IPaddr2):	Started node-01
  * DRBD_Data-clone	(ocf::linbit:drbd):
    * Promoted: node-01
    * Unmanaged: [ node-02 ]
```

##### Option B: Global Cluster Maintenance Mode
```bash
pcs property set maintenance-mode=true
pcs property show maintenance-mode
```

**Expected Command Output:**
```text
Cluster Properties Settings:
  maintenance-mode: true
```

#### Step 4.2: Perform Diagnostic Analysis via Log & CIB Inspection
Run standard cluster sanity checks:

```bash
crm_verify -L -V
```

**Expected Command Output (Clean Config):**
```text
(No output returned indicates zero syntax or structural CIB errors)
```

Extract live cluster configuration in raw XML format to verify constraint execution IDs:
```bash
pcs cluster cib | grep -i "nvpair" | head -n 5
```

Analyze Corosync Knet link engine state directly from kernel logs:
```bash
journalctl -u corosync --since "10 minutes ago" | grep -E "KNET|QUORUM"
```

**Expected Command Output:**
```text
corosync[1234]: [KNET  ] link: Host 2 link 0 is online
corosync[1234]: [KNET  ] link: Host 2 link 1 is online
corosync[1234]: [QUORUM] Members[2]: 1 2
corosync[1234]: [QUORUM] Quorate status set: true
```

#### Step 4.3: Unset Maintenance Mode and Clear Fail Counts
```bash
pcs property set maintenance-mode=false
pcs node maintenance node-02 --off
pcs resource cleanup
```

**Expected Command Output:**
```text
Cleaned up all resources on all nodes
```

---

### Step 4 Comprehension Questions

1. What occurs if a system administrator manually stops a systemd service (e.g., `systemctl stop apache2`) while the Pacemaker cluster is in `maintenance-mode=true` versus when `maintenance-mode=false`?
2. Explain the diagnostic utility of the `crm_simulate -s -v` command prior to applying production CIB changes.

---

<details>
<summary><strong>Click to View Exercise Answers and Technical Explanations</strong></summary>

### Answers to Exercise 1

1. **Boot Sequence Behavior:**  
   Because `wait_for_all: 1` is explicitly set, `node-01` will **not** establish quorum upon booting alone, even though `two_node: 1` is enabled. Corosync requires *both* nodes to join the cluster at least once following initial cluster startup to establish a baseline membership. Until `node-02` connects, `node-01` remains in an unquorate state, preventing Pacemaker from starting resources. This prevents split-brain scenarios where one node starts up after a total outage and assumes authority without knowing the state of its peer.

2. **Corosync Knet Redundancy Mechanics:**  
   Corosync 3 Knet continuously monitors link latency and packet loss using active heartbeats across all configured Knet links (`ring0` and `ring1`). If `ring0` fails, Knet seamlessly switches packet transport to `ring1` without dropping cluster membership or triggering a quorum recalculation event. Knet evaluates link health based on `latency`, `packet loss threshold`, and link MTU diagnostics defined in Knet parameters.

---

### Answers to Exercise 2

1. **IPMI Fence Delay (`delay=15`):**  
   In a two-node cluster, if both nodes lose cluster communication simultaneously (e.g., Knet ring failure), both nodes might attempt to fence each other simultaneously (a fencing race). Adding `delay=15` to the fence configuration for `node-02` (or assigning different delays to each node) introduces an intentional asymmetry. This ensures `node-01` executes its STONITH action first, successfully rebooting `node-02` and taking over resources cleanly, rather than having both nodes power off each other at the exact same moment.

2. **Unconfirmed STONITH Recovery Mechanics:**  
   If `fence_ipmilan` returns a non-zero exit code or times out, Pacemaker treats the STONITH operation as **FAILED**. Under its strict safety guarantee, Pacemaker considers `node-02` to be in an `UNCLEAN` state. It will **NEVER** start or migrate `node-02`'s resources onto `node-01` as long as `node-02`'s power state remains unconfirmed. The cluster stops all recovery operations for those resources to prevent concurrent writes and data corruption. Manual administrator intervention via `stonith_admin --confirm` is required to forcibly clear the uncleared node state.

---

### Answers to Exercise 3

1. **Score Calculation and Sticky Placement:**  
   When `node-01` rejoins the cluster, the placement score for `Cluster_VIP` is calculated as follows:
   - On `node-02` (where `Cluster_VIP` currently runs): Base Score + Location Score (0) + Resource Stickiness (100) = **100**.
   - On `node-01` (rejoining node): Base Score + Location Preference (50) + Resource Stickiness (0, since it is not currently running there) = **50**.

   Since `node-02` (score 100) beats `node-01` (score 50), `Cluster_VIP` **remains on `node-02`**. This prevents unnecessary resource failback flap/downtime.

2. **Mandatory vs. Optional Order Constraints:**  
   - **Mandatory (`kind=Mandatory`):** Resource B will *never* start unless Resource A is successfully started/promoted first. If Resource A fails to start, Resource B execution is blocked completely.
   - **Optional (`kind=Optional`):** Resource B will start after Resource A *if* Resource A is starting at the same time. However, if Resource A fails to start, Resource B is still allowed to start independently.

---

### Answers to Exercise 4

1. **Manual Systemd Stop Behavior with Maintenance Modes:**  
   - When `maintenance-mode=true`: Pacemaker completely ignores local system status changes. Stopping `apache2` via `systemctl` causes no reaction from Pacemaker. No monitor operations are executed, no failure counts increment, and no fencing/failover actions occur.
   - When `maintenance-mode=false`: During the next scheduled OCF/systemd monitor operation, Pacemaker detects that `apache2` is stopped unexpectedly. It increments the resource failcount on that node, triggers local restart attempts, and if `migration-threshold` is reached, fails over the service to another node (or invokes STONITH if configured).

2. **Diagnostic Utility of `crm_simulate`:**  
   The `crm_simulate` tool allows an administrator to test "what-if" scenarios against the current CIB without modifying production cluster state. Using `crm_simulate -s -v`, you can simulate node failures, link loss, or configuration changes (e.g., adding constraints) to preview how Pacemaker's Policy Engine (`pengine`) will calculate scores and transition resource states.

</details>