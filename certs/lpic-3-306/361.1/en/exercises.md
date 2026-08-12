# Guided Exercises — Topic 361.1: High Availability Concepts and Theory

**LPIC-3 306 (exam 306-300, v3.0) · Objective weight: 10**

These exercises are runnable on any Linux workstation — the calculations use `python3`/`bc`, and the cluster inspection steps show the exact expected output so you can follow them even without a live Corosync/Pacemaker lab. Work through each block in order, run every command, and answer the checkpoint questions before revealing the consolidated answers at the end.

> Convention: throughout, **A** = availability, **MTTF** = mean time to failure, **MTTR** = mean time to repair/recover, **MTBF** = MTTF + MTTR. A "nine" is a factor of 10 in unavailability.

---

## Exercise 1 — Availability arithmetic, MTTF/MTTR, and the "nines"

The single most testable skill in 361.1 is turning field metrics into an availability figure and a downtime budget, and back again.

1. Compute the steady-state availability of one server that fails on average every 90 days and takes 4 hours to recover. MTTF = 90 × 24 = 2160 h, MTTR = 4 h:

   ```bash
   python3 -c "mttf=2160; mttr=4; A=mttf/(mttf+mttr); print('A=%.6f'%A, 'downtime=%.2f h/yr'%((1-A)*8760))"
   ```

2. Now build the reference "nines" table — availability, and the annual downtime budget each level buys:

   ```bash
   python3 -c "
   for n in [2,3,4,5,6]:
       A=1-10**(-n)
       mins=(1-A)*365*24*60
       print(f'{n} nines  A={A:.6f}  budget={mins:9.2f} min/yr')
   "
   ```

3. Invert the relationship. Your SLA target is four nines. Detection + failover in your cluster takes 90 seconds per event. How many failover events per year can you afford before you blow the budget?

   ```bash
   python3 -c "budget=52.56*60; per=90; print('events/yr =', budget/per)"
   ```

4. Reduce MTTR instead of MTTF. Take the server from step 1 and cut recovery from 4 h to 6 min (a hot-standby failover instead of a manual repair), keeping MTTF at 2160 h:

   ```bash
   python3 -c "mttf=2160; mttr=0.1; A=mttf/(mttf+mttr); print('A=%.6f'%A, 'downtime=%.2f min/yr'%((1-A)*8760*60))"
   ```

**Checkpoint 1**
1. What availability (and how many nines) did the single server in step 1 achieve?
2. Four nines is ~52.56 min/yr. Why is that number, not "99.99%", the one an on-call engineer actually manages against?
3. In step 4 you touched only MTTR, never MTTF (the hardware fails just as often). Why does availability improve so dramatically anyway, and what does this tell you about where HA engineering effort pays off?
4. The naive reading of "five nines" is "the system almost never breaks." Correct it.

---

## Exercise 2 — Series vs. parallel: redundancy math and the independence trap

Availability composes differently depending on whether components are in the **request path** (series — all must work) or **redundant** (parallel — any one suffices).

1. Model a request path: load balancer → app server → database, each with its own availability. In series, availabilities multiply:

   ```bash
   python3 -c "
   comps={'load_balancer':0.9999,'app_server':0.999,'database':0.9995}
   A=1
   for k,v in comps.items(): A*=v
   print('series A=%.6f'%A, 'downtime=%.2f h/yr'%((1-A)*8760))
   "
   ```

2. Compare the total to its weakest single link (`app_server`, 0.999 = 8.76 h/yr). Note which is worse.

3. Now add redundancy. Put identical 99% nodes in **parallel** — the system is down only if *all* fail: A = 1 − (1 − a)ⁿ:

   ```bash
   python3 -c "
   a=0.99
   for n in [1,2,3]:
       A=1-(1-a)**n
       print(f'{n} node(s)  A=%.6f'%A, 'downtime=%.2f min/yr'%((1-A)*525600))
   "
   ```

4. Spring the trap. Those two "redundant" 99% nodes share a single power feed with A = 0.9995. The shared feed is a **series** term stacked on top of the parallel pair:

   ```bash
   python3 -c "
   pair=1-(1-0.99)**2      # 0.9999
   feed=0.9995
   A=pair*feed
   print('pair alone A=%.6f'%pair)
   print('pair+shared feed A=%.6f'%A, 'downtime=%.2f h/yr'%((1-A)*8760))
   "
   ```

**Checkpoint 2**
1. In step 1, is the series total better or worse than the single worst component? State the general rule for series systems in one sentence.
2. Adding the second parallel node in step 3 changed 99% into what? Roughly how many nines does each additional independent parallel node buy while the base is 99%?
3. In step 4 the pair was four nines on its own. What did the shared power feed do to that figure, and which term dominates the residual downtime?
4. Define **Single Point of Failure (SPOF)** in terms of the series/parallel model, and explain why "we have two of everything" is not by itself a SPOF-free claim.

---

## Exercise 3 — Quorum, split brain, and the two-node problem

Quorum is the mechanism that decides *which* partition of a fractured cluster is allowed to act. Get this wrong and you get **split brain**: two partitions both believing they own the service.

1. Compute simple-majority quorum and the failure tolerance for a range of cluster sizes (quorum = ⌊N/2⌋ + 1):

   ```bash
   python3 -c "
   for n in range(2,8):
       q=n//2+1
       print(f'nodes={n}  quorum={q}  tolerates={n-q} node failure(s)')
   "
   ```

2. Compare N=3 with N=4 in that output. Notice how many failures each tolerates.

3. Simulate a network partition and see how three cluster configurations behave. Save and run this:

   ```bash
   python3 <<'PY'
   total=2  # a 2-node cluster splits: each side keeps 1 vote
   here=1
   def majority(): return here > total/2

   print("A) plain majority quorum")
   print("   side keeps quorum?", majority(), "-> both sides False: cluster HALTS (safe, but unavailable)")

   print("B) two_node:1 forced quorum, NO fencing")
   print("   both sides act as quorate -> both run resources -> SPLIT BRAIN / data corruption")

   print("C) two_node:1 + fencing (STONITH)")
   print("   fence race: one node shoots the other -> single survivor runs (safe AND available)")
   PY
   ```

4. Inspect what a healthy 3-node quorum looks like on a real Corosync cluster. On a live cluster you would run `corosync-quorumtool -s`; the expected output is:

   ```text
   Quorum information
   ------------------
   Quorate:          Yes

   Votequorum information
   ----------------------
   Expected votes:   3
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

5. For an unavoidable 2-node cluster, read how the vote count is repaired without adding a full node — a **quorum device** (`corosync-qdevice` talking to an external `corosync-qnetd` arbiter) contributes an extra vote, turning 2 votes into 3 so one node can still reach majority when the peer link dies. (Reference: `votequorum(5)`, `corosync-qdevice(8)`.)

**Checkpoint 3**
1. From step 1/2: a 4-node cluster tolerates how many failures compared to a 3-node cluster? State the practical rule this implies about cluster sizing.
2. In simulation branch **A**, no data is corrupted but the service is down. In branch **B**, the service stays up but data is corrupted. Which outcome does a correctly configured cluster prefer, and what is the name of the branch-B failure?
3. Branch **C** relies on fencing to be *safe*. Precisely why does a `two_node: 1` cluster make fencing mandatory rather than optional?
4. Define a **quorum device** and explain how it lets a 2-node cluster survive a single node failure without a 50/50 tie.
5. Why are odd-numbered cluster sizes generally preferred over even ones?

---

## Exercise 4 — Fencing / STONITH: reasoning about known state

**STONITH** (Shoot The Other Node In The Head) is fencing that forcibly puts a suspect node into a *known* state — usually off — before the cluster recovers its resources.

1. List the classes of fencing and what each guarantees. Fill this reasoning table on paper as you read:

   | Fence method | Example agent | What it isolates |
   |---|---|---|
   | Power fencing | IPMI / iLO / DRAC, managed PDU | Cuts power to the whole node |
   | Storage/fabric fencing | SCSI-3 PR, SAN zoning | Blocks the node's writes to shared storage |
   | Watchdog (self-fence) | SBD + hardware watchdog | Node reboots *itself* if it loses quorum |

2. On a live cluster you would enumerate installed agents with `stonith_admin --list-installed` and check config with `pcs stonith config`. Reason about this scenario without a cluster:

   - Node **B** stops answering Corosync heartbeats. It is *not* dead — it is frozen under load and will thaw in 40 seconds, resuming writes to the shared LUN it still has mounted.
   - Node **A** is quorate and wants to recover B's resources.

3. Walk the two timelines and decide which is safe:
   - **Without fencing:** A imports the shared filesystem and starts writing. 40 s later, B thaws and continues its own writes to the same LUN.
   - **With power fencing:** A issues a STONITH reset of B *and waits for confirmation* before importing the filesystem. B is powered off; when it reboots it rejoins as a fresh member with nothing mounted.

**Checkpoint 4**
1. In the "without fencing" timeline, what exactly goes wrong at the 40-second mark?
2. Fencing is described as putting a node in a *known* state. Why is "known" the operative word — why isn't "waiting until B looks dead" good enough?
3. A colleague argues a **shared-nothing** cluster (each node has its own disks, data replicated) needs fencing less urgently than a **shared-storage** one. Is there a defensible core to that claim? Where does it break down?
4. What is the specific advantage of watchdog/SBD self-fencing over power fencing when the cluster nodes are VMs with no reliable out-of-band power control?

---

## Exercise 5 — Failover, failback, switchover, and active/active capacity

The recovery vocabulary is exam-critical, and active/active clusters add a capacity-planning trap that active/passive does not.

1. Fix the three terms precisely by classifying each event as **failover**, **failback**, or **switchover**:
   - (a) A node's PSU dies at 03:12; the cluster automatically moves its VIP and service to the standby.
   - (b) At 02:00 during a maintenance window, an admin runs `pcs node standby node1` to relocate resources so node1 can be patched.
   - (c) node1 is repaired and rejoins; per a location preference it automatically reclaims the resources it originally ran.

2. Model active/active capacity. Four nodes each run at 60% utilization. One fails; survivors must absorb the load:

   ```bash
   python3 -c "
   nodes=4; util=0.60
   total=nodes*util
   surv=nodes-1
   print('total load units =', round(total,2))
   print('per surviving node after 1 failure = %.1f%%'%(total/surv*100))
   "
   ```

3. Push utilization to 80% and re-run to see the cascade:

   ```bash
   python3 -c "
   nodes=4; util=0.80
   print('per surviving node = %.1f%%'%(nodes*util/(nodes-1)*100))
   "
   ```

4. Derive the safe steady-state ceiling. For an N-node active/active cluster that must survive one node loss, the maximum safe utilization is (N−1)/N:

   ```bash
   python3 -c "[print(f'N={n}  max safe util = {(n-1)/n*100:.1f}%') for n in (2,3,4,8)]"
   ```

**Checkpoint 5**
1. Match (a)/(b)/(c) from step 1 to failover / failback / switchover, and give the two-axis distinction (planned vs. unplanned, automatic vs. manual) that separates them.
2. Step 2 was fine at 60%; step 3 overloaded at 80%. What is this failure mode called, and why can it turn one node's loss into a full-cluster outage?
3. From step 4, what is the safe utilization ceiling for a 2-node active/active cluster, and what practical conclusion does that force about running two nodes "hot"?
4. **Automatic failback** (event c) can cause a *second* outage the failover did not. Explain the ping-pong risk and one way to prevent it.
5. State one advantage and one disadvantage of active/active versus active/passive.

---

## Exercise 6 — Shared-storage vs. shared-nothing, RTO/RPO, and site resiliency

The final block ties the storage architecture to the recovery objectives the business actually signs off on.

1. Define the two objectives, then compute an RPO from a replication policy. Data is replicated **asynchronously** every 5 minutes to the standby:

   ```bash
   python3 -c "interval_min=5; print('worst-case RPO ~= %d min of data loss'%interval_min)"
   ```

2. Contrast with **synchronous** replication (e.g. DRBD protocol C, where the write is not acknowledged until the peer has it):

   ```bash
   python3 -c "print('synchronous RPO ~= 0 (no acknowledged write is lost) at the cost of added write latency')"
   ```

3. Compute a downtime-budget burn. Your SLA is four nines *per year* (≈52.56 min). A single unfenced split-brain incident this quarter caused 30 minutes of recovery downtime:

   ```bash
   python3 -c "
   annual=52.56
   used=30
   print('annual four-nines budget = %.2f min'%annual)
   print('remaining after one 30-min incident = %.2f min'%(annual-used))
   "
   ```

4. Classify each architecture against its dominant risk:

   | Architecture | How data is shared | Dominant risk to design around |
   |---|---|---|
   | Shared-storage | Nodes mount a common SAN/LUN | Concurrent writes → needs fencing; the array itself is a SPOF unless redundant |
   | Shared-nothing | Each node owns its disks; data replicated | Replication lag → non-zero RPO; failover may lose in-flight data |

5. Extend to **site resiliency**: the whole primary datacenter is a failure domain. A stretch cluster or DR site adds inter-site latency (raising synchronous-write cost) and needs a *third-site* arbiter/quorum witness so a link cut between the two data sites cannot produce a 50/50 split.

**Checkpoint 6**
1. Define RTO and RPO in one sentence each, and say which of the two the *replication method* primarily controls.
2. From step 3: what does a single 30-minute incident do to a four-nines *annual* budget, and what does that reveal about the true cost of skipping fencing?
3. Give the core trade-off between synchronous and asynchronous replication (name the objective each one optimizes at the other's expense).
4. Why does a two-site stretch cluster specifically need a *third* site for quorum, and which single-site concept from Exercise 3 is this the geographic version of?
5. Name one way virtualization/cloud both *helps* and *complicates* HA relative to bare metal.

---

<details>
<summary><strong>Answers — Exercises 1–6</strong></summary>

### Exercise 1
1. A = 2160/2164 = **0.998151… ≈ 99.815%**, i.e. between two and three nines (~16.19 h downtime/yr). Roughly 4 failures/year × 4 h each.
2. Because availability percentages are abstract, but the **downtime budget in minutes is the thing you spend**: 52.56 min/yr is the total time on-call may lose across *all* incidents before the SLA breaks. It's a finite, burnable resource — you manage the budget, not the percentage.
3. A = MTTF/(MTTF + MTTR). Cutting MTTR from 4 h to 6 min shrinks the *unavailability* term while failures stay just as frequent — availability jumps to **0.99995… (~4.4 min/yr, four–five nines)**. Lesson: in HA the payoff is overwhelmingly in **fast detection and automatic recovery (small MTTR)**, not in making hardware fail less often. Failover speed is the lever.
4. Five nines is **~5.26 min of downtime per year** — it does *not* mean rare failures. A system can fail often yet still hit five nines if every recovery is measured in a few seconds; conversely a system that "never" fails but takes hours to recover the one time it does will miss it.

### Exercise 2
1. **Worse.** Series total 0.998401 (~14 h/yr) is worse than the weakest link (0.999, 8.76 h/yr). Rule: **series availability is always ≤ the least-available component** — dependencies only ever subtract.
2. 99% (two nines) became **0.9999 (four nines)** with two nodes, 0.999999 (six nines) with three. Each additional *independent* parallel node adds roughly **two nines** when the base is 99% (it squares the unavailability).
3. It **collapsed four nines back toward three**: 0.9999 × 0.9995 = 0.99940 (~5.26 h/yr). The **shared power feed dominates** the residual downtime — the perfectly redundant pair contributes almost nothing next to it.
4. A **SPOF** is any component that appears as a **series term with no parallel alternative** — its failure fails the whole system. "Two of everything" is only SPOF-free if the two are in *independent failure domains*; a shared feed, switch, storage array, or rack turns nominally redundant components back into a single series term.

### Exercise 3
1. **The same — one.** N=3 tolerates 1 failure (quorum 2); N=4 also tolerates only 1 (quorum 3) while costing more hardware *and* adding a 50/50 split risk. Rule: **going from an odd size to the next even size buys no extra tolerance** — grow in odd steps (3→5→7).
2. A correct cluster prefers **A (safe but down)** over **B (up but corrupt)** — availability is never worth silent data corruption. Branch B is **split brain**.
3. `two_node: 1` *forces* both nodes to consider themselves quorate (otherwise a 2-node cluster could never reach majority). That removes quorum as the split-brain guard, so **fencing is the only remaining mechanism** ensuring exactly one node survives the partition — hence mandatory. Typically paired with `wait_for_all`.
4. A **quorum device** is an external arbiter (`corosync-qnetd` on a third host, reached via `corosync-qdevice`) that contributes one vote. A 2-node cluster becomes **3 votes**; the node still able to reach the arbiter holds majority (2/3) and survives, while the isolated node loses quorum — breaking the tie without a 50/50 stalemate and without a third full cluster node.
5. Odd sizes give a **clean majority with no tie**: an even cluster can split exactly in half (N/2 vs N/2), leaving *neither* side quorate — the extra even node adds cost and tie-risk without adding fault tolerance.

### Exercise 4
1. At 40 s **both A and B write to the same shared LUN concurrently** with no coordination → filesystem/data **corruption** (classic split-brain on shared storage).
2. Because a hung node is indistinguishable from a dead one over the network — it may resume I/O at any instant. Fencing **forces** the node into a state you can *prove* (powered off / write-blocked) before recovering resources; "looks dead" is an assumption, and recovering on an assumption is exactly how corruption happens.
3. Defensible core: shared-nothing has **no single LUN two nodes can corrupt simultaneously**, so the shared-storage double-write failure mode is absent. It breaks down because a false failover on shared-nothing still causes **split brain at the application/replication layer** (two masters, divergent datasets, conflicting client updates) — you still need to guarantee a single authority, so fencing/quorum are still required.
4. VMs often have **no reliable out-of-band power control** (no real IPMI/PDU the cluster can trust). **Watchdog/SBD self-fencing** makes the node reboot *itself* via a hardware/hypervisor watchdog when it loses quorum or the SBD heartbeat — it needs no external power path and no cooperation from the suspect node's OS.

### Exercise 5
1. (a) **Failover** — unplanned + automatic. (b) **Switchover** — planned + manual (a.k.a. manual/administrative failover). (c) **Failback** — return to the original/preferred node after recovery. Two axes: **planned vs. unplanned** and **automatic vs. manual**.
2. **Overload cascade** (thundering-herd / capacity overrun): survivors exceed 100%, degrade or fall over, shedding their load onto the remaining nodes, which then also fail — one node's loss becomes total collapse.
3. Ceiling for N=2 is **(2−1)/2 = 50%**. Two "hot" active/active nodes must each run at **≤50%** to survive the other's loss — meaning you are paying for two nodes to get one node's safe throughput. Above 50%, a single failure overloads the survivor.
4. **Automatic failback** moves resources *back* the moment the recovered node rejoins — a second, avoidable service interruption; if the node is flapping, resources **ping-pong** repeatedly, causing recurring outages. Prevent it by disabling auto-failback (in Pacemaker, keep `resource-stickiness` high / avoid a hard location preference) so resources stay put until an admin deliberately moves them.
5. Advantage of active/active: **all nodes do useful work** (better resource utilization and horizontal scale). Disadvantage: **more complexity** (needs cluster-aware apps or a load balancer, careful capacity headroom, and correct handling of shared state/locking); active/passive is simpler but wastes the standby's capacity.

### Exercise 6
1. **RTO** = maximum acceptable *time to restore service* after an outage (how long you're down). **RPO** = maximum acceptable *data loss*, expressed as a point in time before the failure (how much recent data you can lose). **RPO is primarily controlled by the replication method.**
2. It **consumes 30 of the 52.56 min annual four-nines budget in one event** (~57%), leaving ~22.56 min for the rest of the year. It shows that skipping fencing isn't a corner-case risk — a *single* split-brain recovery can blow more than half the annual SLA budget by itself.
3. **Synchronous** optimizes **RPO** (≈0 data loss) at the cost of **write latency/throughput**; **asynchronous** optimizes **latency/throughput** at the cost of **RPO** (you can lose up to one replication interval). You trade durability against performance.
4. A two-site stretch cluster with equal votes can split exactly in half if the inter-site link is cut — **neither site is quorate (or, if forced, both are → split brain across sites)**. A **third-site arbiter/quorum witness** provides the tie-breaking vote so exactly one data site stays quorate. It is the **geographic version of the quorum device / odd-vote-count principle** from Exercise 3.
5. **Helps:** virtualization/cloud make redundancy cheap and fast — VM restart, live migration, auto-scaling groups, and API-driven fencing/provisioning shrink MTTR. **Complicates:** virtual nodes can share hidden failure domains (same physical host, hypervisor, availability zone, or storage backend), reintroducing correlated failures and SPOFs that look redundant but aren't — and out-of-band power fencing may be unavailable, pushing you to watchdog/SBD self-fencing.

</details>

---

### Sources

- LPI — Exam 306 Objectives (Objective 361.1): https://www.lpi.org/our-certifications/exam-306-objectives/
- ClusterLabs — *Pacemaker Explained* (quorum, fencing/STONITH, resource placement): https://clusterlabs.org/pacemaker/doc/
- Corosync — `votequorum(5)`, `corosync.conf(5)`, `corosync-qdevice(8)`, `corosync-quorumtool(8)`: https://corosync.github.io/corosync/
- Red Hat — *Configuring and managing high availability clusters* (fencing, quorum devices, two-node clusters): https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index