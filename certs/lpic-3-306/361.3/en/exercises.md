# Topic 361.3: Failover Clusters — Guided Exercises

> **Exam 306-300, v3.0 — Topic 361 (High Availability Cluster Management).** Objective 361.3 is the single heaviest objective in the exam, and it is where theory becomes a running system: a Corosync membership/quorum layer, a Pacemaker resource manager on top, fencing/STONITH to make failover safe, and resource constraints that decide *where* and *in what order* services run.

**Lab topology used throughout.** Three nodes so quorum behaves normally (2 of 3 votes), one shared block device for SBD poison-pill fencing, one shared block device for a clustered filesystem.

| Host | Ring 0 address | Role |
|---|---|---|
| `node1` | 192.168.122.11 | cluster member, initial DC |
| `node2` | 192.168.122.12 | cluster member |
| `node3` | 192.168.122.13 | cluster member |
| — | 192.168.122.100 | floating service VIP (a resource, not a host) |
| `/dev/disk/by-id/…-sbd` | shared LUN | SBD slot device (~10 MiB) |
| `/dev/disk/by-id/…-web` | shared LUN | XFS filesystem for the web payload |

Run each command as `root`. Where a step says *"on all nodes"*, run it on `node1`, `node2` and `node3`; everything else is run once on `node1` unless noted, because Pacemaker replicates the CIB (Cluster Information Base) to every node automatically.

---

## Exercise 1 — Bootstrap the Corosync/Pacemaker cluster with `pcs`

1. Install the stack **on all nodes** (RHEL/Alma/Rocky 9 package names shown; on SUSE the meta-package is `ha_sles`, on Debian it is `pacemaker corosync pcs`):

   ```bash
   dnf install -y pacemaker corosync pcs sbd fence-agents-sbd fence-agents-all
   ```

2. The `pcs` daemon authenticates nodes with a local system user `hacluster` created by the package. Give it a password **on all nodes** (use the same password everywhere):

   ```bash
   echo 'S0meStr0ngP@ss' | passwd --stdin hacluster
   ```

3. Enable and start the `pcsd` daemon **on all nodes** — this is the REST/CLI control plane, distinct from Corosync/Pacemaker:

   ```bash
   systemctl enable --now pcsd
   ```

4. From `node1`, authenticate the three nodes to each other. In `pcs` ≥ 0.10 the subcommand is `host auth` (older `pcs cluster auth` is the 0.9 spelling):

   ```bash
   pcs host auth node1 node2 node3 -u hacluster -p 'S0meStr0ngP@ss'
   ```
   ```
   node1: Authorized
   node2: Authorized
   node3: Authorized
   ```

5. Generate and distribute `/etc/corosync/corosync.conf` to all three nodes in one shot. `pcs cluster setup` writes the config, sets up the authkey, and pushes both cluster-wide:

   ```bash
   pcs cluster setup hacluster node1 node2 node3
   ```

6. Start Corosync + Pacemaker everywhere, and enable them at boot:

   ```bash
   pcs cluster start --all
   pcs cluster enable --all
   ```

7. Confirm the cluster is up and quorate:

   ```bash
   pcs status
   ```
   ```
   Cluster name: hacluster
   Cluster Summary:
     * Stack: corosync
     * Current DC: node1 (version 2.1.5-a3f44794f94) - partition with quorum
     * 3 nodes configured
     * 0 resource instances configured

   Node List:
     * Online: [ node1 node2 node3 ]

   Full List of Resources:
     * No resources

   Daemon Status:
     corosync: active/enabled
     pacemaker: active/enabled
     pcsd: active/enabled
   ```

**Comprehension check 1**

- **1a.** Three daemons are now running per node: `pcsd`, `corosync`, and `pacemaker`. What is the distinct job of each, and which one would you *not* strictly need running for the cluster to keep providing service after configuration?
- **1b.** Step 4 (`pcs host auth`) and step 5 (`pcs cluster setup`) both touch every node. Why can't you skip step 4 and go straight to `setup`?
- **1c.** `pcs status` reports "partition with quorum." With three nodes online, how many votes are present and how many are required for quorum? What does "partition" refer to here?

---

## Exercise 2 — Inspect the membership and quorum layer (Corosync)

Pacemaker is only as healthy as the Corosync layer feeding it membership events. These tools query Corosync directly.

1. Look at the totem ring status and the transport in use (Corosync 3 defaults to the `knet` transport):

   ```bash
   corosync-cfgtool -s
   ```
   ```
   Local node ID 1, transport knet
   LINK ID 0 udp
       addr    = 192.168.122.11
       status:
           nodeid:   1:    localhost
           nodeid:   2:    connected
           nodeid:   3:    connected
   ```

2. Query the votequorum service — this is the authoritative quorum view:

   ```bash
   corosync-quorumtool -s
   ```
   ```
   Quorum information
   ------------------
   Quorum provider:  corosync_votequorum
   Nodes:            3
   Node ID:          1
   Ring ID:          1.1a
   Quorate:          Yes

   Votequorum information
   ----------------------
   Expected votes:   3
   Highest expected: 3
   Total votes:      3
   Quorum:           2
   Flags:            Quorate

   Membership information
   ----------------------
       Nodeid      Votes Name
            1          1 node1 (local)
            2          1 node2
            3          1 node3
   ```

3. Dump and grep the in-memory configuration map (CMAP), where Corosync keeps runtime keys:

   ```bash
   corosync-cmapctl | grep -E 'quorum|two_node|members'
   ```
   ```
   quorum.provider (str) = corosync_votequorum
   runtime.members.1.status (str) = joined
   runtime.members.2.status (str) = joined
   runtime.members.3.status (str) = joined
   ```

4. Read the config that `pcs cluster setup` generated:

   ```bash
   cat /etc/corosync/corosync.conf
   ```
   ```
   totem {
       version: 2
       cluster_name: hacluster
       transport: knet
       crypto_cipher: aes256
       crypto_hash: sha256
   }

   nodelist {
       node { ring0_addr: node1  name: node1  nodeid: 1 }
       node { ring0_addr: node2  name: node2  nodeid: 2 }
       node { ring0_addr: node3  name: node3  nodeid: 3 }
   }

   quorum {
       provider: corosync_votequorum
   }

   logging {
       to_logfile: yes
       logfile: /var/log/cluster/corosync.log
       to_syslog: yes
       timestamp: on
   }
   ```

**Comprehension check 2**

- **2a.** In the `corosync-quorumtool` output, `Quorum: 2`. Derive that number from `Expected votes`. If you later add a fourth node, what will `Quorum` become, and why can a 4-node cluster be *more* fragile than a 3-node one under a clean 50/50 split?
- **2b.** The generated `corosync.conf` has **no** `two_node: 1` line. When would `pcs` add one, and what two side-effects does `two_node` enable in the `votequorum` provider?
- **2c.** `corosync-cfgtool -s` shows `nodeid: 2: connected`, but `corosync-quorumtool` shows `Nodeid 2 … joined`. One is a *link* status and one is a *membership* status. Which tool would first reveal a broken network ring while the node is otherwise up?

---

## Exercise 3 — Make failover safe: fencing / STONITH with SBD

A failover cluster that cannot fence must not fail over — otherwise a partitioned node that Pacemaker *thinks* is dead may still be writing to shared storage (split-brain → corruption). We configure **SBD (Storage-Based Death)**: a poison-pill written to a shared slot device, backed by a hardware/software watchdog.

1. Confirm STONITH is currently *enabled as a policy* but that no device exists yet — the cluster is in an unsafe state and will refuse to start resources cleanly:

   ```bash
   pcs property config stonith-enabled
   ```
   ```
   Cluster Properties:
     stonith-enabled: true   # default; never disable this in production
   ```

2. Load a watchdog **on all nodes**. Real hardware exposes `/dev/watchdog` (e.g. `iTCO_wdt`); for a lab, the software watchdog works:

   ```bash
   modprobe softdog
   ls -l /dev/watchdog
   ```

3. Initialise SBD metadata on the shared slot device (do this **once**, from `node1` only — it writes the on-disk header all nodes will share):

   ```bash
   sbd -d /dev/disk/by-id/scsi-360014...-sbd create
   ```

4. Enable SBD cluster-wide with `pcs`. This writes `/etc/sysconfig/sbd` on every node, wires the watchdog, and requires a cluster restart to take effect:

   ```bash
   pcs cluster stop --all
   pcs stonith sbd enable \
       --device=/dev/disk/by-id/scsi-360014...-sbd \
       SBD_WATCHDOG_TIMEOUT=5 \
       SBD_STARTMODE=clean
   pcs cluster start --all
   ```

5. Create the fencing resource that arms the poison-pill mechanism (shared-disk SBD needs a `fence_sbd` STONITH primitive; diskless SBD would not):

   ```bash
   pcs stonith create sbd-fence fence_sbd \
       devices=/dev/disk/by-id/scsi-360014...-sbd \
       pcmk_delay_base=5s
   ```

6. Verify the SBD daemon and inspect the slot allocation table:

   ```bash
   pcs stonith sbd status --full
   sbd -d /dev/disk/by-id/scsi-360014...-sbd list
   ```
   ```
   0  node1  clear
   1  node2  clear
   2  node3  clear
   ```

7. Exercise the mechanism *without* killing a node — send a `test` message to a slot and watch it clear:

   ```bash
   sbd -d /dev/disk/by-id/scsi-360014...-sbd message node2 test
   ```

**Comprehension check 3**

- **3a.** SBD relies on *two* independent components working together to guarantee a node is dead. Name both, and explain what each one guarantees on its own — why is the watchdog indispensable even when the disk slot mechanism works?
- **3b.** `pcs property config` shows `stonith-enabled: true`. What does Pacemaker do to a resource that needs recovery if `stonith-enabled=true` but **no** working STONITH device exists?
- **3c.** Step 5 sets `pcmk_delay_base=5s`. In a symmetric two-node "fence race," what problem does a fencing delay solve, and why is it typically applied asymmetrically (delay on one node only)?
- **3d.** Contrast **shared-disk SBD** (this exercise) with **diskless SBD**. What does diskless SBD rely on *entirely* for its fencing decision, and what is the minimum node count it realistically needs?

---

## Exercise 4 — Create resources and constrain them

Now build the actual service: a shared XFS filesystem, a floating VIP, and Apache, arranged so they always run together, on the same node, in the right order.

1. Inspect the available OCF resource agents for the `heartbeat` provider (this is the `ocf` *resource class* the exam asks you to be aware of, alongside `lsb`, `systemd`, `service`, `stonith`, and `nagios`):

   ```bash
   pcs resource list ocf:heartbeat: | grep -E 'IPaddr2|Filesystem|apache'
   ```

2. Create the shared filesystem resource (assumes the LUN already holds an `xfs` filesystem):

   ```bash
   pcs resource create WebFS ocf:heartbeat:Filesystem \
       device="/dev/disk/by-id/scsi-360014...-web" \
       directory="/var/www/html" fstype="xfs" \
       op monitor interval=20s timeout=40s
   ```

3. Create the floating VIP:

   ```bash
   pcs resource create ClusterVIP ocf:heartbeat:IPaddr2 \
       ip=192.168.122.100 cidr_netmask=24 \
       op monitor interval=30s
   ```

4. Create the web server. Here we use the **OCF** `apache` agent (it can probe `server-status`), not the plain systemd unit, to show a smarter agent:

   ```bash
   pcs resource create WebSite ocf:heartbeat:apache \
       configfile="/etc/httpd/conf/httpd.conf" \
       statusurl="http://127.0.0.1/server-status" \
       op monitor interval=1min
   ```

5. Bind all three into a **resource group**. A group is shorthand: members are colocated on the same node *and* started in listed order (stopped in reverse):

   ```bash
   pcs resource group add WebStack WebFS ClusterVIP WebSite
   ```

6. Add an explicit **location** preference so the stack favours `node1` when it can, without pinning it there:

   ```bash
   pcs constraint location WebStack prefers node1=50
   ```

7. Review the constraint graph and where things actually landed:

   ```bash
   pcs constraint --full
   pcs status resources
   ```
   ```
     * Resource Group: WebStack:
       * WebFS       (ocf:heartbeat:Filesystem):   Started node1
       * ClusterVIP  (ocf:heartbeat:IPaddr2):      Started node1
       * WebSite     (ocf:heartbeat:apache):       Started node1
   ```

**Comprehension check 4**

- **4a.** You grouped `WebFS → ClusterVIP → WebSite`. Write the two *explicit* constraints (one colocation, one ordering) that a group implicitly creates between `WebFS` and `WebSite`. What score does the implicit colocation use?
- **4b.** The location constraint uses score `50`, but a colocation inside a group uses `INFINITY`. What is special about the score `INFINITY` in Pacemaker's arithmetic, and why would `prefers node1=50` *not* be enough to override a `-INFINITY` location rule?
- **4c.** Step 4 uses `ocf:heartbeat:apache` instead of `systemd:httpd`. Give one concrete monitoring capability the OCF agent has that the plain `systemd` class resource does not.
- **4d.** If you had created the three resources *without* a group and *without* constraints, describe a valid but useless placement Pacemaker might choose.

---

## Exercise 5 — Drive a failover and manage node/resource state

1. Watch the cluster live in one terminal (`-Arf` shows attributes, failcounts, and pending operations):

   ```bash
   crm_mon -Arf
   ```

2. In another terminal, put `node1` into **standby** — it stays a cluster member and keeps voting, but hosts no resources:

   ```bash
   pcs node standby node1
   ```
   The whole `WebStack` should relocate to `node2` (or `node3`) as one unit. Confirm:

   ```bash
   pcs status resources
   ```
   ```
     * Resource Group: WebStack:
       * WebFS       (ocf:heartbeat:Filesystem):   Started node2
       * ClusterVIP  (ocf:heartbeat:IPaddr2):      Started node2
       * WebSite     (ocf:heartbeat:apache):       Started node2
   ```

3. Bring `node1` back:

   ```bash
   pcs node unstandby node1
   ```
   Note that the stack **stays on node2** even though `node1` is preferred at score 50 — resources are "sticky" once running (default `resource-stickiness`). 

4. Now force a move to a specific node. `pcs resource move` creates a temporary `-INFINITY` location rule:

   ```bash
   pcs resource move WebStack node3
   pcs constraint --full | grep cli-
   ```
   ```
     Location Constraints:
       Constraint: cli-prefer-WebStack
         Rule: score=INFINITY  ... #uname eq node3
   ```

5. **Clean up the leftover constraint** so future scheduling is free again (forgetting this is a classic exam trap and a real-world outage cause):

   ```bash
   pcs resource clear WebStack
   ```

6. Simulate a real failure. Kill the Apache process out from under Pacemaker on the active node and watch the monitor operation catch it:

   ```bash
   ssh node3 'pkill -9 httpd'
   ```
   Within one `monitor interval` the resource is marked failed and recovered (restarted in place, or relocated if it keeps failing). Inspect the failure counter:

   ```bash
   pcs resource failcount show WebSite
   ```
   ```
   Failcounts for resource 'WebSite'
     node3: 1
   ```

7. Reset the failure history after you have understood the cause:

   ```bash
   pcs resource cleanup WebSite
   ```

**Comprehension check 5**

- **5a.** In step 3, `node1` is preferred (score 50) yet the resource did not move back after `unstandby`. Which cluster/resource property counteracts the location preference, and what real-world problem does it prevent?
- **5b.** `pcs resource move` "worked," but step 5 was still necessary. Explain *mechanically* what `move` leaves behind and what would go wrong on the next node failure if you never ran `pcs resource clear`.
- **5c.** A resource with `migration-threshold=3` reaches a failcount of 3 on `node3`. What does Pacemaker do next, and how does `failure-timeout` interact with that?
- **5d.** Contrast **standby** (step 2) with **fencing** (Exercise 3). Both remove a node from service — why is only one of them safe to trigger for planned maintenance, and why can't standby substitute for fencing during an actual split-brain?

---

## Exercise 6 — The same cluster through `crmsh`

`pcs` and `crmsh` (`crm`) are two front-ends to the *same* CIB. SUSE ships `crmsh`; RHEL ships `pcs`; the exam expects fluency in both. Nothing below changes the design — it re-reads and lightly edits the running cluster.

1. Status and live monitor via `crmsh`:

   ```bash
   crm status
   crm_mon -1
   ```

2. Dump the entire configuration in `crmsh`'s compact syntax:

   ```bash
   crm configure show
   ```
   ```
   node 1: node1
   node 2: node2
   node 3: node3
   primitive ClusterVIP IPaddr2 params ip=192.168.122.100 cidr_netmask=24 \
       op monitor interval=30s
   primitive WebFS Filesystem params device="/dev/disk/by-id/...-web" \
       directory="/var/www/html" fstype=xfs op monitor interval=20s
   primitive WebSite apache params configfile="/etc/httpd/conf/httpd.conf" \
       op monitor interval=1min
   primitive sbd-fence stonith:fence_sbd params devices="/dev/...-sbd"
   group WebStack WebFS ClusterVIP WebSite
   location cli-WebStack-on-node1 WebStack 50: node1
   property cib-bootstrap-options: stonith-enabled=true ...
   ```

3. Dry-run the scheduler: ask "what *would* happen right now?" without changing anything. `crm_simulate` reads the live CIB and prints the transition graph:

   ```bash
   crm_simulate -sL
   ```

4. Make an edit through `crmsh` to prove parity — raise the VIP's monitor frequency — then verify with `pcs` that both front-ends see it:

   ```bash
   crm configure edit ClusterVIP     # opens $EDITOR on that primitive
   pcs resource config ClusterVIP    # confirm the change via the other tool
   ```

5. Standby/unstandby a node the `crmsh` way:

   ```bash
   crm node standby node2
   crm node online node2
   ```

**Comprehension check 6**

- **6a.** You changed the VIP monitor interval with `crm configure edit` and confirmed it with `pcs resource config`. What shared object makes both tools agree, and where does it physically live and replicate?
- **6b.** `crm_simulate -sL` reported a transition even though you changed nothing. What is `crm_simulate` for, and how would you use it *before* a risky change to predict fallout?
- **6c.** Map these `crmsh` verbs to their `pcs` equivalents: `crm node standby`, `crm configure show`, `crm resource cleanup`, `crm status`.

---

## Exercise 7 (awareness) — Multi-site failover with Booth

A single Pacemaker cluster assumes low-latency links; it cannot stretch across geographically separate sites and still fence safely. **Booth** coordinates *between* independent Pacemaker clusters using a **ticket** that a majority of arbitrators grant to exactly one site at a time.

1. Read the Booth config skeleton (do not deploy — this is awareness-level):

   ```bash
   cat /etc/booth/booth.conf
   ```
   ```
   transport = UDP
   port = 9929
   arbitrator = 192.0.2.50
   site = 198.51.100.10        # cluster at site A
   site = 203.0.113.10         # cluster at site B
   ticket = "web-ticket"
       expire = 600
   ```

2. Observe how a ticket gates a resource group so it runs at **only one site**:

   ```bash
   pcs constraint ticket add web-ticket WebStack loss-policy=fence
   booth ticket grant web-ticket
   ```

**Comprehension check 7**

- **7a.** Why does Booth need an odd number of participants (sites + arbitrators), and what is the arbitrator's *only* job?
- **7b.** The ticket constraint sets `loss-policy=fence`. If site A loses the `web-ticket`, what happens to `WebStack` at site A, and why is that the safe choice for a stretched cluster?

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

### Exercise 1

- **1a.** `pcsd` is the **configuration/management** daemon — a REST + CLI control plane on port 2224 that authenticates nodes and pushes config; it is *not* part of the data path, so once the cluster is configured you can stop `pcsd` and resources keep running (you just lose easy management). `corosync` is the **messaging/membership/quorum** layer (totem protocol + votequorum). `pacemaker` is the **cluster resource manager** that decides where resources run and drives start/stop/monitor/fence. The one you don't strictly need running for continued service is **`pcsd`**.
- **1b.** `pcs cluster setup` distributes files (`corosync.conf`, the Corosync authkey) to the other nodes over the `pcsd` channel. That channel is only trusted after `pcs host auth` establishes a mutual token between the nodes. Without step 4, `setup` has no authenticated path to write to `node2`/`node3` and fails.
- **1c.** Three nodes → three votes present; quorum = `floor(expected/2) + 1 = floor(3/2)+1 = 2`. "Partition" is Corosync's term for the set of nodes that can currently see each other; "partition with quorum" means the local node is in a group holding ≥ 2 votes and is therefore allowed to run resources.

### Exercise 2

- **2a.** `Quorum = floor(3/2)+1 = 2`. With four nodes, `Quorum = floor(4/2)+1 = 3`. A clean 2/2 split of a 4-node cluster leaves **neither** side with 3 votes, so *both* partitions lose quorum and stop all resources — an even node count buys you no extra fault tolerance over the odd count below it, and adds a tie-break failure mode. (This is why quorum devices / odd counts are preferred.)
- **2b.** `pcs` adds `two_node: 1` automatically when the cluster is created with exactly **two** nodes. It enables (1) an effective quorum of 1 so a single surviving node stays quorate, and (2) `wait_for_all` on startup so the cluster won't assume quorum until both nodes have been seen at least once (preventing a lone node from fencing its healthy peer at boot).
- **2c.** `corosync-cfgtool -s` — it reports **link/ring** status per node. A ring can break (link `status: … 2: disconnected`) before the node is fully evicted from membership, so the cfgtool link view surfaces the network fault first.

### Exercise 3

- **3a.** The two components are the **shared disk slot** and the **hardware/software watchdog**. The disk slot lets a healthy node *tell* a target to die by writing a poison-pill message; the watchdog guarantees a node that is hung, or has lost access to the slot device, **self-resets** because it can no longer pet `/dev/watchdog`. The watchdog is indispensable because a node that cannot read its poison-pill (e.g. storage path down, kernel hang) would never voluntarily die — the watchdog makes "I can no longer prove I'm healthy" equal "I reboot myself," which is what makes SBD's death guarantee unconditional.
- **3b.** With `stonith-enabled=true` and no working device, Pacemaker will **block recovery**: it refuses to start the affected resource elsewhere because it cannot confirm the old location is dead. Resources needing fence-gated recovery stay stopped until a fence succeeds — the cluster deliberately chooses unavailability over risking split-brain.
- **3c.** In a symmetric two-node partition, both nodes decide to fence the other simultaneously and can shoot each other dead ("fence race" → both down). A fencing **delay** makes one node pause before firing; the un-delayed node wins the race and survives. It's applied asymmetrically (delay on one node only, e.g. via `pcmk_delay_base`/`priority-fencing-delay`) precisely so there is a deterministic winner instead of a tie.
- **3d.** **Diskless SBD** has no shared slot device; it relies **entirely on the watchdog plus quorum** — a node that loses quorum simply stops petting the watchdog and self-fences. It has no way to send a positive poison-pill to another node, so it needs a reliable quorum signal and realistically **three or more nodes** (or a quorum device) to avoid both partitions self-fencing on a tie.

### Exercise 4

- **4a.** A group `WebFS ClusterVIP WebSite` implies, between the endpoints `WebFS` and `WebSite`: a colocation `colocation … WebSite with WebFS INFINITY` (same node, mandatory) and an ordering `order … WebFS then WebSite` (start WebFS first, stop it last). The implicit colocation score is **`INFINITY`**.
- **4b.** `INFINITY` (and `-INFINITY`) are treated as absolute, not just large: any finite score added to `-INFINITY` is still `-INFINITY`. So a mandatory (`INFINITY`/`-INFINITY`) rule always wins over any advisory finite preference. `prefers node1=50` is a *finite* nudge; it can lose to stickiness or to any `-INFINITY` "never run here" rule, which cannot be outweighed by adding 50.
- **4c.** The OCF `apache` agent can perform an **application-level health probe** — it fetches `statusurl` (`/server-status`) and considers the resource failed if the HTTP check fails, catching a hung-but-running daemon. The plain `systemd:httpd` resource only knows whether systemd reports the unit active, so a wedged server that still shows "active" would go undetected.
- **4d.** With no constraints, Pacemaker load-balances by default and could place `WebFS` on `node1`, `ClusterVIP` on `node2`, and `WebSite` on `node3` — every piece "running," but Apache has no filesystem and no VIP on its node, so the service is completely non-functional.

### Exercise 5

- **5a.** `resource-stickiness` (a positive default stickiness score) makes an already-running resource "prefer to stay put." When stickiness ≥ the location preference (50), the resource does not migrate back to the preferred node after it returns. This prevents an unnecessary, service-disrupting failback (and flapping) just because a preferred node rejoined.
- **5b.** `pcs resource move` implements the move by injecting a permanent `cli-prefer-*` location constraint at `INFINITY` pinning the resource to the target node. If you never `clear` it, that node is now the *only* place the resource is willing to run; when it later fails, Pacemaker cannot relocate the resource and the service stays down — the "move" quietly disabled failover.
- **5c.** Reaching the `migration-threshold` on a node makes that node **ineligible** for the resource (effectively `-INFINITY` there), forcing relocation to another node. `failure-timeout` expires old failures after a set interval, decaying the failcount so the node becomes eligible again automatically instead of being banned forever.
- **5d.** **Standby** is a *cooperative* state change: the node is healthy and agrees to give up its resources, which are cleanly stopped and moved — safe for planned maintenance. **Fencing** is for an *uncooperative or unknown* node: you can't trust it to stop cleanly, so you power-cut/reset it. Standby can't substitute for fencing in a split-brain because a partitioned node can't be *asked* to stand by — you have no communication with it, and only a forcible fence can guarantee it isn't still writing to shared storage.

### Exercise 6

- **6a.** Both front-ends read and write the **CIB (Cluster Information Base)**, an XML document managed by Pacemaker's `pacemaker-based` (CIB) daemon. It lives in `/var/lib/pacemaker/cib/cib.xml` on each node and is **replicated automatically** to every node, so a change made through `crmsh` is immediately visible to `pcs` and vice-versa.
- **6b.** `crm_simulate` runs the **policy engine offline** against a CIB to show the transition graph it *would* execute — which resources start/stop/move/fence — without touching the cluster. Before a risky change you save the CIB, apply the change to that copy, and simulate it (e.g. `crm_simulate -Sx new.xml`) to see the fallout (unexpected restarts, a fence, a stack relocation) *before* committing.
- **6c.** `crm node standby` → `pcs node standby`; `crm configure show` → `pcs config` / `pcs resource config` (full: `pcs cluster cib`); `crm resource cleanup` → `pcs resource cleanup`; `crm status` → `pcs status`.

### Exercise 7

- **7a.** Booth grants a ticket by **majority vote**, so the total number of participants (sites + arbitrators) must be **odd** to guarantee a decisive majority and prevent two sites from both claiming the ticket. The arbitrator's only job is to be a **tie-breaking voter** — it runs no resources; it exists purely to make the vote total odd and decide which site holds the ticket.
- **7b.** With `loss-policy=fence`, if site A loses `web-ticket`, Pacemaker at site A **fences its own nodes** running `WebStack`, guaranteeing they stop before site B is allowed to start the same resources. For a stretched multi-site cluster this is the safe choice: it makes absolutely certain the workload (and any shared data writes) runs at exactly one site, eliminating cross-site split-brain even when the inter-site link is gone.

</details>

---

### Sources

- LPI — Exam 306 Objectives, Topic 361.3 *Failover Clusters*: https://www.lpi.org/our-certifications/exam-306-objectives/
- ClusterLabs — *Pacemaker Administration* and *Pacemaker Explained*: https://clusterlabs.org/pacemaker/doc/
- ClusterLabs — Corosync `votequorum(5)` and `corosync.conf(5)` man pages: https://clusterlabs.org/corosync.html
- `pcs`(8) manual, ClusterLabs: https://clusterlabs.org/pcs/
- `crmsh` documentation (SUSE/ClusterLabs): https://crmsh.github.io/
- SBD — Storage-Based Death daemon: https://github.com/ClusterLabs/sbd
- Booth — Cluster Ticket Manager: https://github.com/ClusterLabs/booth