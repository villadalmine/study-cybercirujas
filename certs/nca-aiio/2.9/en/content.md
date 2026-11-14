# 2.9 — High-Speed Data Center Network Options and Their Use Cases

## 1. Motivation: the network is part of the computer

A single modern GPU does dense math at petaFLOPS scale. Distributed training splits one model across hundreds or thousands of them, using data, tensor, pipeline and expert parallelism. Those GPUs must constantly exchange gradients, activations and parameters. Every collective operation (`AllReduce`, `AllGather`, `ReduceScatter`, `AllToAll`) is a synchronization barrier: the slowest link sets the step time for the whole job.

That makes the production problem concrete:

| Symptom in production | Root architectural cause |
|---|---|
| GPU utilization of 40–60% during training, even with perfect input pipelines | Collectives are network-bound; GPUs wait on the fabric |
| Step time degrades as the cluster grows from 64 to 1024 GPUs | Oversubscribed or poorly-routed fabric; congestion and hash collisions |
| One slow node drags down the whole job (tail latency) | Lossy transport, retransmits, a degraded link running at reduced width |
| Checkpoint save/restore takes tens of minutes | Storage traffic shares (or lacks) a dedicated high-bandwidth path |
| Host CPU saturates on networking or storage/security processing | Infrastructure services run on the host instead of being offloaded |

NVIDIA's answer is not one network but a **hierarchy of interconnects**. Each one is optimized for a different distance, bandwidth, latency and failure domain:

1. **Scale-up (intra-node / intra-rack):** NVLink + NVSwitch, which makes GPUs behave like one large GPU with shared memory semantics.
2. **Scale-out compute fabric (east-west, between nodes):** InfiniBand (Quantum) or AI-tuned Ethernet (Spectrum-X), driven by ConnectX SuperNICs with RDMA and GPUDirect.
3. **Storage fabric:** high-bandwidth RDMA path to parallel filesystems, often via BlueField DPUs, using GPUDirect Storage.
4. **In-band management (north-south):** Ethernet for job scheduling, provisioning, Kubernetes/Slurm control plane, user access.
5. **Out-of-band (OOB) management:** low-speed Ethernet to BMCs and switch management ports, for when everything else is broken.

The exam objective, "identify options and their use cases", maps directly onto this hierarchy. You must be able to look at a traffic pattern and name the right interconnect.

---

## 2. Scale-up: NVLink and NVSwitch

### 2.1 Mechanics

**NVLink** is a point-to-point, high-bandwidth, low-latency GPU-to-GPU (and GPU-to-CPU, with NVLink-C2C on Grace) interconnect. It supports load/store memory semantics: a GPU can directly read, write and perform atomics in a peer GPU's HBM, without staging through host memory or PCIe.

**NVSwitch** is a switch ASIC that connects NVLink ports from all GPUs in a node, or in a rack with NVLink Switch systems. It provides **all-to-all, non-blocking** connectivity: every GPU talks to every other GPU at full NVLink bandwidth simultaneously. Third-generation and later NVSwitch also implements **NVLink SHARP (NVLS)**: in-switch reductions for collectives, which cut the data each GPU must send for an AllReduce.

| Generation | Platform example | Bandwidth per GPU (bidirectional) | Links per GPU | Domain size |
|---|---|---|---|---|
| NVLink 4 | DGX H100 / H200 (Hopper) | 900 GB/s | 18 | 8 GPUs per node (4 NVSwitch chips) |
| NVLink 5 | DGX B200 (Blackwell) | 1.8 TB/s | 18 | 8 GPUs per node (2 NVSwitch chips) |
| NVLink 5 + NVLink Switch | GB200 NVL72 | 1.8 TB/s | 18 | 72 GPUs in one NVLink domain, ~130 TB/s aggregate |

Compare that with scale-out: one 400 Gb/s NIC delivers ~50 GB/s per direction. On a DGX H100 with 8× 400G compute NICs, the node has ~400 GB/s per direction of scale-out bandwidth in total. A **single GPU** has ~450 GB/s per direction over NVLink (900 GB/s bidirectional), so one GPU alone can move more than the whole node can send out, and each GPU's share of the fabric is only ~50 GB/s: about one ninth. This ratio drives the most important design rule.

> **Design rule:** place the most bandwidth-hungry parallelism, typically **tensor parallelism** and expert-parallel `AllToAll`, inside the NVLink domain. Place data parallelism and pipeline stages, which communicate less often, across the scale-out fabric.

### 2.2 Use cases

| Use case | Why NVLink |
|---|---|
| Tensor parallelism (splitting individual layers across GPUs) | Exchanges activations every layer; needs TB/s-class bandwidth and µs latency |
| Mixture-of-Experts `AllToAll` | Dense, all-pairs traffic; NVSwitch is non-blocking all-to-all |
| Large-model inference with KV cache spread over GPUs | Memory pooling over NVLink; NVL72 serves trillion-parameter models as one domain |
| Intra-node stage of hierarchical collectives | NCCL reduces within the node over NVLink/NVLS, then across nodes over the NIC |

---

## 3. Scale-out compute fabric: InfiniBand vs Spectrum-X Ethernet

### 3.1 Why RDMA and GPUDirect RDMA

Traditional TCP/IP networking copies data GPU → host memory → kernel socket buffer → NIC. Each hop costs CPU cycles, memory bandwidth and latency.

**RDMA** lets the NIC read and write application memory directly, with kernel bypass and zero copy. **GPUDirect RDMA** extends this so the NIC DMAs straight to and from **GPU HBM** across the PCIe switch, bypassing the CPU and system memory entirely. This is why every DGX pairs each GPU with its own NIC under the same PCIe switch: a "rail".

```
            ┌───────────────── DGX node ─────────────────┐
            │  GPU0 ─┐                         ┌─ GPU1   │
            │        PCIe switch          PCIe switch    │
            │  NIC0 ─┘ (GPUDirect RDMA)        └─ NIC1   │
            │        all 8 GPUs ←→ NVSwitch (NVLink)     │
            └──────┬───────────────────────────┬─────────┘
                rail 0 leaf                 rail 1 leaf
```

### 3.2 InfiniBand (NVIDIA Quantum)

InfiniBand is a purpose-built HPC/AI fabric, lossless by design:

- **Credit-based link-level flow control:** a sender transmits only when the receiver has advertised buffer credits. Packets are never dropped due to congestion. No PFC tuning is required.
- **Subnet Manager (SM):** a centralized controller (OpenSM, or NVIDIA UFM) discovers the topology, assigns LIDs and computes forwarding tables. The fabric is software-defined from day one.
- **Adaptive routing:** switches pick the least-congested output port per packet, which avoids the static-hash collisions of ECMP.
- **SHARP (Scalable Hierarchical Aggregation and Reduction Protocol):** reductions are performed **inside the switch ASICs**. An AllReduce no longer needs every byte to traverse the network twice, which roughly halves the data volume and reduces latency.
- **Hardware congestion control** and very low, deterministic switch latency.

| Generation | Per-port speed | Switch example | NIC |
|---|---|---|---|
| NDR | 400 Gb/s | Quantum-2 QM9700 (64× 400G in 32 OSFP cages) | ConnectX-7 |
| XDR | 800 Gb/s | Quantum-X800 | ConnectX-8 SuperNIC |

### 3.3 Ethernet for AI: RoCEv2 and Spectrum-X

**RoCEv2** (RDMA over Converged Ethernet v2) carries the InfiniBand transport over UDP/IP. It is routable and uses standard Ethernet operations, but Ethernet is **lossy** by default, and RDMA tolerates loss poorly (go-back-N retransmission). Plain RoCE therefore needs:

- **PFC (Priority Flow Control)** on the RDMA traffic class, for lossless behavior.
- **ECN + DCQCN** congestion control, so senders throttle before PFC pauses cascade.
- Consistent DSCP/trust/buffer configuration on **every** switch and NIC.

Misconfiguration produces PFC storms, head-of-line blocking and deadlocks.

**NVIDIA Spectrum-X** is an end-to-end Ethernet platform built for AI. It pairs **Spectrum-4 (Spectrum-X800 for 800G) switches** with **BlueField-3 SuperNICs or ConnectX-8 SuperNICs**, and it fixes the classic Ethernet weaknesses for AI traffic:

- **Per-packet adaptive routing (packet spraying)** across all equal-cost paths, instead of per-flow ECMP hashing. AI traffic consists of a few huge "elephant" flows, and hashing collides badly with such flows.
- The SuperNIC performs **out-of-order packet placement** directly into memory, so spraying is transparent to the application.
- **Telemetry-driven congestion control:** switches feed in-band congestion signals to NICs for fast, precise rate control. This also provides **performance isolation** between tenants.
- Interoperates with standard Ethernet tooling, automation (Cumulus Linux/NVUE, SONiC) and existing data center operations.

### 3.4 Trade-off comparison

| Dimension | InfiniBand (Quantum) | Spectrum-X Ethernet | Generic RoCEv2 Ethernet | TCP/IP Ethernet |
|---|---|---|---|---|
| Losslessness | Native (credit-based) | Engineered (PFC/ECN + NIC/switch CC) | PFC/ECN, hand-tuned | No (TCP retransmit) |
| Load balancing | Adaptive routing (SM + switch) | Per-packet AR + NIC reorder | Per-flow ECMP hash | Per-flow ECMP hash |
| In-network compute | SHARP | No SHARP-equivalent in-switch reduction | No | No |
| Latency / jitter | Lowest, most deterministic | Low, predictable with Spectrum-X | Variable under load | High |
| Multi-tenancy / cloud | Partitions (PKeys), less common in public clouds | Native VLAN/VXLAN/EVPN, built for multi-tenant AI clouds | VXLAN/EVPN | Native |
| Operational skillset | IB-specific (SM, UFM, LIDs, PKeys) | Standard Ethernet ops + AI tuning | Ethernet + deep QoS expertise | Standard |
| Typical deployment | Largest training clusters, DGX SuperPOD compute fabric, HPC | AI clouds and enterprise AI factories standardized on Ethernet | Mixed / brownfield | Management, user access, general services |

**How to choose (exam framing):**
- *Maximum performance for large-scale training, a single tenant, in-network reductions wanted* → **InfiniBand**.
- *Multi-tenant AI cloud, an organization standardized on Ethernet operations, needs near-IB AI performance* → **Spectrum-X**.
- *Control plane, provisioning, user/SSH access, Kubernetes API, monitoring* → standard **Ethernet** (in-band management).
- *BMC/IPMI/Redfish, switch consoles* → **OOB management Ethernet** (1 GbE class).

### 3.5 Topology: rail-optimized fat tree

DGX SuperPOD compute fabrics use a **rail-optimized, non-blocking fat-tree**:

- Each of the 8 compute NICs in a DGX ("rail" N) connects to the **leaf switch dedicated to rail N** in its Scalable Unit (SU).
- An SU is **32 DGX nodes = 256 GPUs**. Rails are aggregated through spine switches; larger systems add a core layer.
- Traffic between the same GPU index on different nodes is the dominant collective pattern, and it stays **one hop (leaf-local)** within an SU.
- PXN (PCIe × NVLink) in NCCL lets a GPU send through a peer GPU's NIC over NVLink, keeping traffic on the right rail.

```
          Spine layer  (S1 ... Sn)   ← full bisection, no oversubscription
             /    |    |    \
 Rail-0 leaf  Rail-1 leaf  ...  Rail-7 leaf    (per SU)
   |  |  |      |  |  |           |  |  |
 NIC0 of      NIC1 of           NIC7 of
 DGX 1..32    DGX 1..32         DGX 1..32
```

---

## 4. Storage, in-band and out-of-band networks; the role of the DPU

### 4.1 The four physical networks of a DGX system

| Network | DGX H100 | DGX B200 | Traffic | Technology |
|---|---|---|---|---|
| Compute fabric | 8× ConnectX-7 single-port 400 Gb/s (via OSFP ports) | 8× ConnectX-7 400 Gb/s | GPU-to-GPU collectives, east-west | InfiniBand NDR (or Spectrum-X) |
| Storage + in-band | 2× dual-port ConnectX-7 (up to 400 Gb/s) | 2× dual-port BlueField-3 DPU (up to 400 Gb/s) | Datasets, checkpoints, Slurm/K8s, provisioning | IB or Ethernet (RoCE) for storage; Ethernet for in-band |
| OOB management | 1 GbE BMC port | 1 GbE BMC port | Redfish/IPMI, remote console, firmware | Ethernet |
| Scale-up | 4× NVSwitch, 900 GB/s/GPU | 2× NVSwitch, 1.8 TB/s/GPU | Intra-node GPU traffic | NVLink 4 / NVLink 5 |

Isolating these networks prevents interference. A multi-terabyte checkpoint write must never steal bandwidth from the latency-sensitive compute fabric, and a broken data plane must never take away your remote access to the BMC.

### 4.2 GPUDirect Storage (GDS)

GDS creates a direct DMA path between storage (local NVMe or remote NVMe-oF / parallel filesystems such as Lustre, GPFS, WEKA or VAST) and **GPU memory**. It avoids the CPU bounce buffer. Results: higher throughput, lower latency and lower CPU utilization for data loading and checkpointing. GDS is part of the **Magnum IO** stack, together with GPUDirect RDMA, NCCL, NVSHMEM and UCX.

### 4.3 BlueField DPU: offload and isolation

A **DPU (Data Processing Unit)** such as BlueField-3 is a NIC (ConnectX core) with integrated Arm cores, memory and hardware accelerators. It is programmable through **NVIDIA DOCA**. It runs infrastructure services **on the card instead of on the host**:

| Function | Benefit |
|---|---|
| Virtual switching (OVS) offload, overlay (VXLAN) encap/decap | Frees host cores; line-rate SDN |
| Storage virtualization (NVMe-oF, SNAP: remote storage exposed as a local NVMe device) | Host sees a local disk; storage stack runs on the DPU |
| Inline crypto (IPsec, TLS, MACsec), stateful firewall, micro-segmentation | Line-rate security without CPU tax |
| Isolation domain: infrastructure control plane runs on the DPU, separate from the tenant host OS | Zero-trust; a compromised host cannot reconfigure the network or security policy |
| Telemetry and monitoring at the edge of every server | Visibility without host agents |

Distinguish clearly:
- **ConnectX SuperNIC / NIC** → moves data fast (RDMA, GPUDirect) for **east-west** AI traffic.
- **BlueField DPU** → moves data fast **and** runs infrastructure services with isolation. It is typically used for **north-south**, storage and multi-tenant cloud functions.
- **BlueField-3 SuperNIC** → a BlueField-3 in a mode optimized for Spectrum-X east-west AI networking.

---

## 5. Kubernetes integration: RDMA networking for GPU workloads

In Kubernetes, the **NVIDIA Network Operator** deploys the networking stack: DOCA/OFED driver, RDMA device plugin, Multus and secondary CNIs. The **GPU Operator** deploys GPU drivers and `nvidia-peermem` for GPUDirect RDMA. The pod gets a primary cluster network (in-band, Ethernet) plus secondary high-speed interfaces (compute fabric).

### 5.1 NicClusterPolicy (Network Operator)

Pin `version` values to the release notes of the Network Operator version you install. The values below illustrate the structure.

```yaml
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  ofedDriver:
    image: doca-driver
    repository: nvcr.io/nvidia/mellanox
    version: "25.04-0.6.1.0-2"
    upgradePolicy:
      autoUpgrade: true
      maxParallelUpgrades: 1
      drain:
        enable: true
        force: true
        timeoutSeconds: 300
        deleteEmptyDir: true
    startupProbe:
      initialDelaySeconds: 10
      periodSeconds: 20
    livenessProbe:
      initialDelaySeconds: 30
      periodSeconds: 30
    readinessProbe:
      initialDelaySeconds: 10
      periodSeconds: 30
  rdmaSharedDevicePlugin:
    image: k8s-rdma-shared-dev-plugin
    repository: ghcr.io/mellanox
    version: "v1.5.2"
    config: |
      {
        "configList": [
          {
            "resourceName": "rdma_shared_device_a",
            "rdmaHcaMax": 63,
            "selectors": {
              "vendors": ["15b3"],
              "deviceIDs": ["1021"],
              "ifNames": ["ibp24s0", "ibp64s0", "ibp79s0", "ibp94s0", "ibp154s0", "ibp192s0", "ibp206s0", "ibp220s0"]
            }
          }
        ]
      }
  secondaryNetwork:
    cniPlugins:
      image: plugins
      repository: ghcr.io/k8snetworkplumbingwg
      version: "v1.5.0"
    multus:
      image: multus-cni
      repository: ghcr.io/k8snetworkplumbingwg
      version: "v4.1.0"
    ipamPlugin:
      image: whereabouts
      repository: ghcr.io/k8snetworkplumbingwg
      version: "v0.7.0"
```

Notes:
- `15b3` is the NVIDIA (Mellanox) PCI vendor ID; `1021` is ConnectX-7.
- `ifNames` must match the actual compute-fabric interface names on your nodes. Verify them with `ip -br link` or `ibdev2netdev`.
- `rdmaHcaMax` caps how many pods can share each HCA through the shared device plugin. Use the SR-IOV device plugin instead when you need hard per-pod VF isolation.

### 5.2 Secondary network over InfiniBand (IPoIB)

```yaml
apiVersion: mellanox.com/v1alpha1
kind: IPoIBNetwork
metadata:
  name: ib-rail0
spec:
  networkNamespace: ai-training
  master: ibp24s0
  ipam: |
    {
      "type": "whereabouts",
      "range": "10.10.0.0/16",
      "exclude": ["10.10.0.0/24"]
    }
```

### 5.3 Secondary network over RoCE / Spectrum-X Ethernet

```yaml
apiVersion: mellanox.com/v1alpha1
kind: MacvlanNetwork
metadata:
  name: roce-rail0
spec:
  networkNamespace: ai-training
  master: enp24s0np0
  mode: bridge
  mtu: 9000
  ipam: |
    {
      "type": "whereabouts",
      "range": "10.20.0.0/16",
      "exclude": ["10.20.0.0/24"]
    }
```

### 5.4 Workload pod: NCCL test over the compute fabric

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nccl-test-0
  namespace: ai-training
  annotations:
    k8s.v1.cni.cncf.io/networks: ib-rail0
spec:
  restartPolicy: Never
  containers:
    - name: nccl
      image: nvcr.io/nvidia/pytorch:25.01-py3
      command: ["sleep", "infinity"]
      env:
        - name: NCCL_DEBUG
          value: "INFO"
        - name: NCCL_DEBUG_SUBSYS
          value: "INIT,NET"
        - name: NCCL_IB_HCA
          value: "mlx5"
        - name: NCCL_NET_GDR_LEVEL
          value: "PHB"
        - name: NCCL_SOCKET_IFNAME
          value: "eth0"
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      resources:
        limits:
          nvidia.com/gpu: 8
          rdma/rdma_shared_device_a: 1
        requests:
          nvidia.com/gpu: 8
          rdma/rdma_shared_device_a: 1
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 64Gi
```

Why each piece matters:
- `IPC_LOCK` → RDMA must pin (register) memory. Without it, `ibv_reg_mr` fails.
- `/dev/shm` as a memory-backed volume → NCCL uses shared memory for intra-node transport. The 64 MiB container default causes hangs or failures.
- `NCCL_SOCKET_IFNAME=eth0` → bootstrap and out-of-band NCCL traffic go over the cluster network. Data goes over IB (`NCCL_IB_HCA`).
- `rdma/rdma_shared_device_a` → mounts the `/dev/infiniband/*` verbs devices into the container.

### 5.5 RoCE switch QoS on Spectrum (Cumulus Linux / NVUE)

For RoCE on Spectrum switches, apply the lossless RoCE profile consistently:

```bash
$ nv set qos roce mode lossless
$ nv config apply
$ nv show qos roce
                    operational  applied
------------------  -----------  --------
enable              on           on
mode                lossless     lossless
pfc
  pfc-priority      3            3
  rx-enabled        enabled
  tx-enabled        enabled
congestion-control
  congestion-mode   ECN
  enabled-tc        3
trust
  trust-mode        pcp,dscp
```

On the host NIC, the matching trust and PFC settings are applied with `mlnx_qos` (for example `mlnx_qos -i enp24s0np0 --trust dscp --pfc 0,0,0,1,0,0,0,0`). PFC priority and DSCP mapping **must match end to end**.

---

## 6. Verification and diagnostics

### 6.1 Scale-up: NVLink topology and health

```bash
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  ...  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PIX   SYS   ...  0-55,112-167  0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   PIX   ...  0-55,112-167  0
...
Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

Read it as follows:
- `NV18` between every GPU pair means all 18 NVLinks are active through NVSwitch. A lower number, or `SYS` between GPUs, means a degraded NVLink or NVSwitch.
- `PIX` between GPU*N* and NIC*N* means the GPU and its rail NIC share a PCIe switch, which is the optimal path for GPUDirect RDMA.

```bash
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s

$ nvidia-smi nvlink -e -i 0          # error counters per link (CRC, replay, recovery)
$ nvidia-smi -q | grep -A3 -i fabric
    Fabric
        State                             : Completed
        Status                            : Success
```

On NVSwitch systems, the **NVIDIA Fabric Manager** service must be running. If it is not, GPUs cannot establish NVLink peer connectivity and CUDA workloads fail to initialize.

```bash
$ systemctl status nvidia-fabricmanager --no-pager
● nvidia-fabricmanager.service - NVIDIA fabric manager service
     Loaded: loaded (/usr/lib/systemd/system/nvidia-fabricmanager.service; enabled)
     Active: active (running) since Fri 2026-11-13 08:12:44 UTC; 1 day ago
```

### 6.2 Scale-out: NIC and link state

```bash
$ ibdev2netdev
mlx5_0 port 1 ==> ibp24s0 (Up)
mlx5_1 port 1 ==> ibp64s0 (Up)
...
mlx5_7 port 1 ==> ibp220s0 (Up)

$ ibstat mlx5_0
CA 'mlx5_0'
	CA type: MT4129
	Number of ports: 1
	Firmware version: 28.39.1002
	Hardware version: 0
	Node GUID: 0xa088c20300e1a2b4
	System image GUID: 0xa088c20300e1a2b4
	Port 1:
		State: Active
		Physical state: LinkUp
		Rate: 400
		Base lid: 112
		LMC: 0
		SM lid: 1
		Capability mask: 0xa751e848
		Port GUID: 0xa088c20300e1a2b4
		Link layer: InfiniBand
```

Read it as follows:
- `MT4129` is ConnectX-7.
- `Rate: 400` means NDR.
- `State: Active` requires a Subnet Manager. `State: Initializing` with `Physical state: LinkUp` means **the cable is fine but no SM has configured the port**. Check OpenSM or UFM.
- `Link layer: Ethernet` means the port is in Ethernet/RoCE mode. Port type is set with `mlxconfig -d <dev> set LINK_TYPE_P1=1` for IB or `=2` for Ethernet, followed by a reboot or firmware reset.

```bash
$ sudo mlxlink -d mlx5_0
Operational Info
----------------
State                           : Active
Physical state                  : LinkUp
Speed                           : IB-NDR
Width                           : 4x
FEC                             : Standard_RS-FEC - (544,514)
...
Physical Counters and BER Info
------------------------------
Effective Physical BER          : 15E-255
Raw Physical BER                : 1E-8
Link Down Counter               : 0
Link Error Recovery Counter     : 0
```

A width of `1x` or `2x` instead of `4x`, a speed lower than expected, or rising `Link Down` / `Link Error Recovery` counters all point to a bad cable, a bad transceiver or a dirty connector. That node becomes the straggler of every job it joins.

```bash
$ ibv_devinfo -d mlx5_0 | egrep 'hca_id|fw_ver|state|active_mtu|link_layer'
hca_id:	mlx5_0
	fw_ver:				28.39.1002
			state:			PORT_ACTIVE (4)
			active_mtu:		4096 (5)
			link_layer:		InfiniBand
```

### 6.3 Fabric-wide health (InfiniBand)

```bash
$ sudo ibdiagnet --pc -o /tmp/ibdiag
...
-I- Discovering ... 1312 nodes (64 Switches & 1248 CA-s) discovered.
-I- Lids Check
-I- Links Check
-I- Errors: 0 Warnings: 3
...
$ sudo ibswitches | head -3
Switch	: 0xfc6a1c0300a1b2c0 ports 129 "Quantum-2 QM9700 leaf-su1-rail0" enhanced port 0 lid 3 lmc 0
$ sudo perfquery -x 112 1      # extended port counters for LID 112, port 1
# Port extended counters: Lid 112 port 1
PortXmitData:....................183920348810
PortRcvData:.....................183918723104
SymbolErrorCounter:..............0
LinkDownedCounter:...............0
PortRcvErrors:...................0
PortXmitDiscards:................0
PortXmitWait:....................12034
```

`PortXmitWait` growing quickly means congestion: the port wanted to send but had no credits. Persistent `SymbolErrorCounter` growth means a physical-layer problem.

### 6.4 RDMA bandwidth between two nodes (perftest)

```bash
# On node B (server), with GPUDirect into GPU 0
$ ib_write_bw -d mlx5_0 --use_cuda=0 -F --report_gbits -s 1048576 -D 10

# On node A (client)
$ ib_write_bw -d mlx5_0 --use_cuda=0 -F --report_gbits -s 1048576 -D 10 nodeB
---------------------------------------------------------------------------------------
                    RDMA_Write BW Test
 Dual-port       : OFF		Device         : mlx5_0
 Number of qps   : 1		Transport type : IB
 Connection type : RC		Using SRQ      : OFF
 Mtu             : 4096[B]
 Link type       : IB
---------------------------------------------------------------------------------------
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 1048576    46012          391.82             391.67               0.046692
---------------------------------------------------------------------------------------
```

Expect roughly 390 Gb/s on a healthy NDR link. A result near 100–200 Gb/s suggests a degraded link width, a PCIe problem (a NIC trained at a lower PCIe generation or width; check with `lspci -vv`) or a NUMA mismatch.

On RoCE, add `-x <gid_index>` and use `show_gids` to pick the RoCEv2 GID:

```bash
$ show_gids mlx5_0
DEV	PORT	INDEX	GID					IPv4  		VER	DEV
---	----	-----	---					------------  	---	---
mlx5_0	1	0	fe80:0000:0000:0000:a288:c2ff:fee1:a2b4			v1	enp24s0np0
mlx5_0	1	1	fe80:0000:0000:0000:a288:c2ff:fee1:a2b4			v2	enp24s0np0
mlx5_0	1	2	0000:0000:0000:0000:0000:ffff:0a14:0011	10.20.0.17  	v1	enp24s0np0
mlx5_0	1	3	0000:0000:0000:0000:0000:ffff:0a14:0011	10.20.0.17  	v2	enp24s0np0
```

Index 3 (IPv4, v2) is the routable RoCEv2 GID. In NCCL, set it with `NCCL_IB_GID_INDEX=3`.

### 6.5 End-to-end: NCCL tests

```bash
$ mpirun -np 16 -H nodeA:8,nodeB:8 \
    -x NCCL_DEBUG=INFO -x NCCL_IB_HCA=mlx5 -x NCCL_SOCKET_IFNAME=eth0 \
    ./build/all_reduce_perf -b 1G -e 8G -f 2 -g 1
...
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_1:1/IB [2]mlx5_2:1/IB [3]mlx5_3:1/IB [4]mlx5_4:1/IB [5]mlx5_5:1/IB [6]mlx5_6:1/IB [7]mlx5_7:1/IB ; OOB eth0:10.0.0.11<0>
NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
...
#       size         count      type   redop    root     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)
  1073741824     268435456     float     sum      -1   5642.1  190.31  356.83      0
  2147483648     536870912     float     sum      -1    11087  193.69  363.17      0
  4294967296    1073741824     float     sum      -1    21950  195.67  366.88      0
  8589934592    2147483648     float     sum      -1    43715  196.49  368.42      0
# Avg bus bandwidth    : 363.825
```

These numbers are representative of a healthy 2-node H100 system with 8× NDR. Compare against your own baseline taken at acceptance testing.

What to verify in the log:
- `NET/IB` with all 8 HCAs listed. Seeing `NET/Socket` means NCCL **fell back to TCP**: no RDMA devices in the container, or the verbs libraries are missing.
- `GDRDMA` in the channel lines means GPUDirect RDMA is active. Its absence means data is staged through host memory. Check `lsmod | grep nvidia_peermem` and the GPU Operator setting `driver.rdma.enabled=true`.
- `busbw` per size compared with your acceptance baseline. Run single-node first: if NVLink performance is correct but multi-node is not, the problem is in the scale-out fabric.

### 6.6 Failure diagnosis matrix

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| NCCL log shows `NET/Socket` | RDMA devices not exposed to the pod; missing `rdma/*` resource; no IB verbs libraries | `ls /dev/infiniband` inside pod; `kubectl describe node \| grep rdma` | Request the RDMA resource; fix the NicClusterPolicy selectors |
| `NET/IB` but no `GDRDMA` | `nvidia-peermem` not loaded; ACS/IOMMU blocking P2P; GPU-NIC across CPU sockets | `lsmod`; `nvidia-smi topo -m` shows `SYS` | Load peermem (GPU Operator RDMA); disable ACS on PCIe switches per platform guide |
| Port `Initializing` | No Subnet Manager reachable | `sminfo`; UFM/OpenSM status | Start or restore the SM (with an HA standby) |
| One node slows every job | Degraded link (width 2x/1x, lower speed), high BER, thermal throttling | `mlxlink`, `perfquery`, `ibdiagnet`; per-node `ib_write_bw` | Reseat or replace the cable or transceiver; drain the node until fixed |
| RoCE throughput collapses under load, pause storms | PFC/DSCP mismatch between NIC and switch; ECN disabled | `ethtool -S <if> \| grep -E 'pause\|ecn'`; `nv show qos roce` | Align trust mode, PFC priority and ECN end to end, or adopt Spectrum-X |
| ECMP hot spots on Ethernet | Few elephant flows hashing onto the same uplink | Uneven uplink utilization in switch telemetry | Per-packet adaptive routing (Spectrum-X); more QPs per connection (`NCCL_IB_QPS_PER_CONNECTION`) |
| CUDA init fails on 8-GPU node, `Fabric State: In Progress/Failure` | Fabric Manager down or version mismatch with driver | `systemctl status nvidia-fabricmanager`; `nvidia-smi -q` | Match Fabric Manager to driver version; restart |
| Checkpoints slow, training jitter during saves | Storage traffic on compute fabric, or CPU bounce buffers | Per-interface counters during checkpoint | Dedicated storage fabric; GPUDirect Storage; DPU offload |
| `ibv_reg_mr` failures / "cannot allocate memory" | Memlock limit too low | `ulimit -l` in container | Add `IPC_LOCK`; set unlimited memlock in the runtime |

---

## 7. Exam-oriented summary

| If the question mentions… | The answer is usually… |
|---|---|
| GPU-to-GPU inside a server or rack, TB/s, memory semantics, tensor parallelism | **NVLink / NVSwitch** (NVL72 for rack-scale) |
| Lowest latency, lossless, in-network reductions, largest training clusters, Subnet Manager | **InfiniBand (Quantum-2 NDR 400G / Quantum-X800 XDR 800G)** with **SHARP** |
| AI performance on Ethernet, multi-tenant AI cloud, adaptive routing on Ethernet | **Spectrum-X** (Spectrum-4 switches + BlueField-3 / ConnectX-8 SuperNIC) |
| RDMA over Ethernet, PFC/ECN | **RoCEv2** |
| NIC writes directly into GPU memory | **GPUDirect RDMA** |
| Storage directly into GPU memory, no CPU bounce buffer | **GPUDirect Storage** (Magnum IO) |
| Offload of OVS, storage, encryption, firewalls; isolation from the host; Arm cores; DOCA | **BlueField DPU** |
| BMC, Redfish, IPMI, remote console | **Out-of-band management network** |
| Slurm, Kubernetes API, provisioning, user access | **In-band management Ethernet** |
| DGX SuperPOD compute topology | **Rail-optimized, non-blocking fat tree; SU = 32 nodes / 256 GPUs** |

---

## Referencias

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide — Component Descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Offloading and Isolating Data Center Workloads with NVIDIA BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes/latest/index.html
- NVIDIA Spectrum-X Ethernet platform: https://www.nvidia.com/en-us/networking/spectrumx/
- NVIDIA Quantum InfiniBand platform: https://www.nvidia.com/en-us/networking/products/infiniband/
- NCCL Tests: https://github.com/NVIDIA/nccl-tests
- NCCL environment variables: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html
- GPUDirect Storage overview: https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html