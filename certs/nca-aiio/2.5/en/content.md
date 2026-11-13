# 2.5 Key Components and Considerations of an Accelerated Infrastructure Cluster

> **Exam weight: 4.0.** You need to recognize the building blocks of a GPU cluster: compute nodes, GPUs, NVLink/NVSwitch, compute, storage and management fabrics, DPUs, storage, management/head nodes, power and cooling. You also need to understand why each one exists and what goes wrong when it is sized or wired incorrectly.

---

## 1. Motivation: why a GPU cluster is not "a lot of servers with GPUs"

A conventional CPU cluster is designed around **independent requests**. A web tier with 400 nodes keeps working when one node is slow, because the load balancer routes around it. Network traffic is mostly north–south, and each node's performance depends mainly on its own CPU and memory.

A cluster built for distributed AI training behaves very differently:

1. **It is one synchronous machine.** In data, tensor or pipeline parallelism, every step ends in a collective operation (all-reduce, all-gather, reduce-scatter) across every participating GPU. The step finishes only when the **slowest** GPU, link or switch port finishes. A single degraded 400 Gb/s port can reduce the throughput of a 1,024-GPU job by tens of percent.
2. **Traffic is east–west and bursty.** Gradients move between GPUs in different nodes, many times per second, at line rate. Oversubscription and congestion that a CPU cluster would tolerate become a hard cap on training throughput.
3. **The data path has to bypass the CPU.** If every byte moves NIC → host DRAM → GPU, the CPU and PCIe root complex become the bottleneck. Technologies such as **GPUDirect RDMA** and **GPUDirect Storage** exist to remove that hop.
4. **Power and heat are an order of magnitude higher.** One DGX H100 draws about 10.2 kW at maximum and one DGX B200 about 14.3 kW. A standard enterprise rack is often provisioned for 10–15 kW in total. The facility becomes part of the architecture.
5. **The cost of idle hardware is extreme.** A GPU that waits for storage, the network or the scheduler wastes capital. Utilization depends on the whole system, not only on the accelerator.

NVIDIA's answer is a **reference architecture** (DGX BasePOD / DGX SuperPOD). It defines a repeatable **Scalable Unit (SU)** of compute nodes, a set of **physically separate networks**, dedicated **management nodes**, certified **storage**, and a **software stack** (Base Command Manager, Slurm or Kubernetes, UFM, DCGM). The rest of this section breaks that design into its components.

---

## 2. Anatomy of the cluster: the component map

```
                         ┌──────────────────────────── Out-of-band (OOB) mgmt (1 GbE, BMC/IPMI/Redfish) ───────────┐
                         │                                                                                       │
 ┌──────────────┐   ┌────┴─────────────┐        ┌──────────────────────────────────────────────────────────┐    │
 │ Users / CI   │──▶│ Login / Head      │──────▶│               In-band management (Ethernet)              │    │
 │ (Slurm, k8s) │   │ nodes (BCM,       │        └──────┬────────────────┬────────────────────┬────────────┘    │
 └──────────────┘   │ Slurm ctl, k8s    │               │                │                    │                 │
                    │ control plane)    │        ┌──────┴─────┐   ┌──────┴─────┐       ┌──────┴─────┐           │
                    └───────────────────┘        │ DGX node 1 │   │ DGX node 2 │  ...  │ DGX node N │◀──────────┘
                                                 │ 8 GPU +    │   │ 8 GPU +    │       │ 8 GPU +    │
                                                 │ NVSwitch   │   │ NVSwitch   │       │ NVSwitch   │
                                                 └─┬───────┬──┘   └─┬───────┬──┘       └─┬───────┬──┘
                         Compute fabric (8 rails,  │       │        │       │            │       │
                         IB NDR / Spectrum-X) ◀────┘       │ ◀──────┘       │ ◀──────────┘       │
                                                           │                │                    │
                         Storage fabric ◀──────────────────┴────────────────┴────────────────────┘
                         (IB or Ethernet, BlueField-3 / CX-7) ──▶ Parallel FS / NVMe-oF appliances
                         UFM appliance manages the IB fabric
```

| Component | Role | Typical NVIDIA building block | What breaks if it is wrong |
|---|---|---|---|
| **Accelerated compute node** | Hosts GPUs, CPUs, NICs and local NVMe | DGX H100 / DGX B200 / HGX-based OEM servers | Everything: it is the unit of compute |
| **GPU** | Tensor math, HBM memory | H100 (80 GB HBM3), B200 (HBM3e) | Model does not fit; low throughput |
| **NVLink + NVSwitch** | Scale-up: GPU↔GPU inside the node or NVLink domain | NVLink 4 (900 GB/s/GPU), NVLink 5 (1.8 TB/s/GPU) | Tensor parallelism falls back to PCIe and becomes very slow |
| **Compute (east–west) fabric** | Scale-out: GPU↔GPU across nodes | Quantum-2 InfiniBand NDR 400 Gb/s, Spectrum-X Ethernet | Collectives stall; poor scaling efficiency |
| **Storage fabric** | Dataset reads, checkpoint writes | ConnectX-7 / BlueField-3 to a parallel filesystem | GPUs wait on I/O; slow checkpoints raise the cost of failures |
| **In-band management network** | Provisioning, SSH, scheduler, monitoring, container pulls | Ethernet | Nodes cannot be provisioned or reached; jobs cannot launch |
| **Out-of-band (OOB) network** | BMC: power cycle, console, sensors, firmware | 1 GbE to BMC (IPMI / Redfish) | You cannot recover a hung node remotely |
| **DPU** | Offload and isolate networking, storage and security from the host | BlueField-3 | Host CPU burns cycles on infrastructure; weaker tenant isolation |
| **Management / head nodes** | Cluster provisioning, image management, scheduler control plane | Base Command Manager, Slurm controller, Kubernetes control plane | No orchestration; no single source of truth for node images |
| **Fabric manager** | IB subnet management, telemetry, routing | UFM (Unified Fabric Manager) | IB subnet without SM = no traffic; no visibility into link errors |
| **Storage system** | High-throughput shared data | Certified parallel filesystems / NVMe-oF | Data starvation |
| **Facility** | Power, cooling, floor space, cabling | High-density PDUs; air or direct liquid cooling | Thermal throttling, tripped breakers, unbuildable racks |

---

## 3. The accelerated compute node, using DGX H100 and DGX B200

The DGX H100 user guide describes the system as a set of discrete components. Their arrangement is the reference model for any HGX-class server.

| Component | DGX H100 | DGX B200 |
|---|---|---|
| GPUs | 8× H100 SXM5, 80 GB HBM3 each (640 GB total) | 8× B200, 1,440 GB HBM3e total |
| GPU interconnect | 4× NVSwitch chips, NVLink 4: 18 links per GPU, 900 GB/s bidirectional per GPU | 2× NVSwitch chips, NVLink 5: 1.8 TB/s per GPU |
| CPUs | 2× Intel Xeon Platinum 8480C (112 cores total) | 2× Intel Xeon Platinum 8570 |
| System memory | 2 TB | up to 4 TB |
| Compute fabric NICs | 8× ConnectX-7 single-port 400 Gb/s (exposed through 4 OSFP cages) | 8× ConnectX-7 400 Gb/s (through 4 OSFP cages) |
| Storage / in-band NICs | 2× dual-port ConnectX-7 | 2× dual-port BlueField-3 DPU |
| OS storage | 2× 1.92 TB NVMe M.2 (RAID 1) | 2× 1.9 TB NVMe M.2 |
| Data cache | 8× 3.84 TB NVMe U.2 | 8× 3.84 TB NVMe U.2 |
| Management | BMC with dedicated 1 GbE (Redfish / IPMI) | BMC with dedicated 1 GbE |
| Max power | ~10.2 kW | ~14.3 kW |

### 3.1 The design principle: one NIC per GPU, with matching PCIe locality

The key point is not the number of NICs. It is their **placement**. Each of the 8 compute NICs sits behind the **same PCIe switch** as one GPU. That gives every GPU a dedicated 400 Gb/s path to the fabric that never crosses the CPU socket interconnect (UPI). With **GPUDirect RDMA**, the NIC DMA-reads and DMA-writes GPU HBM directly through that local PCIe switch.

```
  CPU socket 0 ──UPI── CPU socket 1
     │                     │
  PCIe switch           PCIe switch           (×4 such pairs per node in practice)
   ├── GPU0               ├── GPU4
   └── CX-7 (mlx5_0)      └── CX-7 (mlx5_4)
        │                       │
     Rail 0 leaf             Rail 4 leaf
```

If a job ends up using a GPU with a "remote" NIC (one across UPI), you get the `SYS` path in `nvidia-smi topo -m`, and RDMA bandwidth drops sharply. NCCL normally chooses correctly, but container runtimes, cgroups or incorrect device mapping can break this.

### 3.2 Scale-up vs scale-out

| Dimension | NVLink / NVSwitch (scale-up) | InfiniBand / Ethernet (scale-out) | PCIe Gen5 x16 (reference) |
|---|---|---|---|
| Per-GPU bandwidth | 900 GB/s (NVLink 4), 1.8 TB/s (NVLink 5) | 400 Gb/s = 50 GB/s per direction per NIC | ~64 GB/s per direction |
| Scope | Inside a node (8 GPUs), or a rack-scale NVLink domain (e.g. 72 GPUs in GB200 NVL72) | Thousands of nodes | Single host |
| Latency | Lowest; memory-semantic load/store | µs-scale RDMA | µs-scale |
| Best fit | Tensor parallelism, expert parallelism (MoE all-to-all) | Data parallelism, pipeline parallelism across nodes | Host↔GPU staging |
| Failure mode | NVLink errors / NVSwitch fault → node unusable for TP | Link flaps, congestion → job-wide slowdown | Downtrained link (x8 / Gen3) |

**Exam-level rule:** keep the most communication-heavy parallelism (tensor parallelism) **inside the NVLink domain**, and put the less chatty dimensions (data and pipeline parallelism) **across the network fabric**.

---

## 4. The networks: four physically separate fabrics

A DGX SuperPOD uses **four** distinct networks. Separation is deliberate. Mixing storage, management and compute traffic on one fabric creates interference that is hard to diagnose.

| Network | Medium (reference design) | Connects | Traffic | Key design property |
|---|---|---|---|---|
| **Compute fabric** | InfiniBand NDR 400 Gb/s (Quantum-2 QM9700) or Spectrum-X Ethernet | The 8 compute NICs of every node | NCCL collectives, MPI | **Rail-optimized**, full-bisection (non-blocking) fat tree |
| **Storage fabric** | InfiniBand or Ethernet (CX-7 / BlueField-3 dual-port) | Nodes ↔ storage appliances, plus mgmt nodes | Dataset reads, checkpoints | Sized to storage throughput, not to GPU count |
| **In-band management** | Ethernet (100/200 GbE class) | All nodes, head nodes, login nodes | SSH, provisioning, scheduler RPC, container image pulls, telemetry | Reliability and reachability |
| **Out-of-band management** | 1 GbE Ethernet | BMCs, switch management ports, PDUs | IPMI / Redfish, console, sensors, firmware | Works even when the host OS is down |

### 4.1 Rail-optimized topology

In a rail-optimized design, **NIC *i* of every node in a Scalable Unit connects to leaf switch *i*** (rail *i*). In the SuperPOD reference architecture, an SU contains **32 DGX nodes**. Their 32 × 8 = 256 compute ports land on 8 rail leaves.

```
             Spine layer (full bisection)
        ┌──────────┬──────────┬──── ... ──┐
     Leaf R0    Leaf R1    Leaf R2   ...  Leaf R7        ← one leaf per rail per SU
      │ │ │      │ │ │      │ │ │         │ │ │
   node1..32  node1..32  node1..32      node1..32
   (GPU0/NIC0)(GPU1/NIC1)(GPU2/NIC2)    (GPU7/NIC7)
```

Why it matters:

- GPU *i* on node A reaches GPU *i* on node B in **one switch hop** (same leaf). NCCL's ring and tree algorithms mostly communicate between same-index GPUs.
- Cross-rail traffic (GPU 0 → GPU 3 on another node) can go **through NVLink first** (to the local GPU 3) and then out on rail 3. NCCL calls this PXN (PCIe × NVLink). It avoids an extra spine hop.
- A failed leaf affects **one rail** across the SU instead of all GPUs in a rack. This is a cleaner, more predictable failure domain.

### 4.2 InfiniBand vs Spectrum-X Ethernet for the compute fabric

| Criterion | InfiniBand (Quantum-2 NDR) | Spectrum-X (Spectrum-4 + BlueField-3 SuperNIC) | Generic Ethernet + RoCE |
|---|---|---|---|
| Transport | Native RDMA, credit-based lossless flow control | RoCEv2 with NVIDIA adaptive routing and congestion control | RoCEv2, PFC/ECN tuning by hand |
| Control plane | Subnet Manager (UFM / OpenSM) | Standard Ethernet + NetQ / Cumulus / SONiC | Standard Ethernet |
| In-network computing | SHARP (switch-side reductions) | Not SHARP; relies on adaptive routing / CC | None |
| Operational skill set | IB-specific (LIDs, SM, partitions) | Ethernet-native | Ethernet-native |
| Predictability at scale | Highest, a reference choice for SuperPOD | Designed for AI at scale on Ethernet | Varies; prone to incast and PFC storms |
| Multi-tenancy / cloud integration | Partition keys (PKeys) | VXLAN/EVPN, familiar to cloud operators | VXLAN/EVPN |

### 4.3 Oversubscription

| Fabric | Typical ratio | Reason |
|---|---|---|
| Compute | 1:1 (non-blocking) | Collectives saturate all links at the same time |
| Storage | Can be oversubscribed | Bounded by storage system throughput |
| In-band mgmt | Oversubscribed | Low, bursty load |
| OOB | Heavily oversubscribed | Kilobits per BMC |

---

## 5. DPUs: offloading and isolating infrastructure

A **Data Processing Unit** (BlueField-3) combines a ConnectX NIC, Arm cores, its own memory and hardware accelerators (crypto, compression, regex, packet processing) on one card. It runs its **own OS**, separate from the host.

| Capability | Standard NIC | SmartNIC | DPU (BlueField) |
|---|---|---|---|
| Packet I/O, RDMA | ✔ | ✔ | ✔ |
| Fixed-function offloads (checksum, TSO, RSS) | ✔ | ✔ | ✔ |
| Programmable data path (OVS offload, flow tables) | ✘ | ✔ | ✔ |
| General-purpose cores running a full OS | ✘ | Limited | ✔ (Arm, runs DOCA services) |
| Independent trust domain from the host | ✘ | ✘ | ✔ |
| Storage emulation (presents NVMe to the host, backed by NVMe-oF) | ✘ | ✘ | ✔ |
| Inline crypto (IPsec / TLS / MACsec) | ✘ | Partial | ✔ |

Why this matters for an AI cluster:

- **CPU offload:** virtual switching (OVS), firewalling, encryption and storage protocols run on the DPU, so host cores remain available for data loading and preprocessing.
- **Isolation:** infrastructure software runs in a separate trust domain. A compromised tenant workload on the host cannot reconfigure the network policy enforced on the DPU. This is the zero-trust / bare-metal multi-tenancy argument from the NVIDIA DPU blog.
- **Storage path:** the DPU can present remote NVMe-oF storage to the host as local NVMe, which simplifies provisioning and enables stateless nodes.
- In the **DGX B200**, the two storage/management ports are BlueField-3 DPUs. In **Spectrum-X**, BlueField-3 SuperNICs run the compute fabric's congestion control endpoint.

Programming model: **NVIDIA DOCA** SDK, with services deployed on the DPU's Arm OS.

---

## 6. The I/O path: GPUDirect technologies

| Technology | Data path | Bypasses | Needed for |
|---|---|---|---|
| **GPUDirect P2P** | GPU ↔ GPU in the same node (NVLink or PCIe) | Host memory | Intra-node collectives |
| **GPUDirect RDMA** | NIC ↔ GPU memory, across nodes | Host memory and CPU copies | Inter-node NCCL / MPI |
| **GPUDirect Storage (GDS)** | NVMe or NVMe-oF / parallel FS ↔ GPU memory (cuFile API) | CPU bounce buffer | Data loading, checkpointing |

Without GDS: `storage → NIC → host DRAM (bounce buffer) → PCIe → GPU`.
With GDS: `storage → NIC → PCIe switch → GPU HBM`.

This is the core message of the NVIDIA "Accelerating IO in the modern data center" series. As GPU compute grows faster than CPU memory bandwidth, the only way to feed GPUs is to **remove the CPU from the data path**. That is also why NIC-to-GPU PCIe locality (Section 3.1) is a hard design requirement.

Software requirements on the host: the GPU driver plus either `nvidia-peermem` (legacy peer memory) or **DMA-BUF** (current kernels and drivers) for GPUDirect RDMA, plus the `nvidia-fs` kernel module and cuFile library for GDS.

---

## 7. Storage tier

| Tier | Location | Use | Characteristic |
|---|---|---|---|
| Local NVMe (RAID 0 over the 8× U.2) | Each node | Dataset cache, scratch | Very fast, not shared, lost on reimage |
| Parallel / high-performance shared FS | Storage fabric | Training data, checkpoints | High aggregate throughput, POSIX, GDS-capable products |
| Object storage / data lake | Ethernet / WAN | Raw data, long-term retention | Huge capacity, higher latency |
| Home / NFS | In-band mgmt | Code, configs, user homes | Low performance, convenience |

Sizing considerations:

- **Checkpoint bandwidth** is often the dominant write load. A large model checkpoint written by every node at the same time saturates the storage fabric. Slow checkpoints mean longer pauses and, after a failure, more lost work.
- **Read pattern:** many small files (images) stress metadata, while large sharded files (tokens) stress throughput. Choose the filesystem and the dataset format together.
- Storage traffic belongs on the **storage fabric**, not the compute fabric, so collectives do not compete with I/O.

---

## 8. Management plane and software stack

| Layer | Component | Function |
|---|---|---|
| Provisioning / cluster mgmt | **NVIDIA Base Command Manager (BCM)** | Bare-metal provisioning, node images, health checks, monitoring, workload manager integration |
| Workload manager | **Slurm** (classic HPC/training) or **Kubernetes** (with Run:ai or native scheduling) | Gang scheduling, topology-aware placement, queues |
| GPU enablement on Kubernetes | **NVIDIA GPU Operator** | Driver, container toolkit, device plugin, GFD, DCGM exporter, MIG manager |
| Network enablement on Kubernetes | **NVIDIA Network Operator** | DOCA-OFED driver, RDMA device plugin, SR-IOV, Multus secondary networks |
| Fabric management | **UFM** | IB subnet manager, topology validation, link telemetry, congestion monitoring |
| GPU telemetry and diagnostics | **DCGM** | Health checks, active diagnostics (`dcgmi diag`), Prometheus metrics via dcgm-exporter |
| Software catalog | **NGC** | Optimized containers (PyTorch, NeMo, Triton) |

Management nodes are **dedicated**, never DGX nodes repurposed. In the reference architecture, they run BCM (in HA), the Slurm controller and/or the Kubernetes control plane, and the login nodes. UFM runs on its own appliance or server attached to the IB fabric.

---

## 9. Facility considerations: power, cooling, space

| Consideration | Typical enterprise | Accelerated cluster | Consequence |
|---|---|---|---|
| Power per rack | 5–15 kW | 1 DGX H100 ≈ 10.2 kW, 1 DGX B200 ≈ 14.3 kW; rack-scale NVL72 systems in the ~120 kW class | Fewer nodes per rack, or new power distribution |
| Cooling | Air, hot/cold aisle | Air at the limit; **direct liquid cooling** for rack-scale systems | Requires CDUs, facility water loops |
| Redundancy | N+1 PSU | N+N PSUs in the node, A/B feeds | Loss of one feed must not drop the node |
| Cabling | Copper DAC | Optical OSFP transceivers, thousands of fibers per SU | Cable plant is a design deliverable; labeling matters |
| Weight | Standard floor | DGX nodes are heavy; dense racks | Floor loading checks |

| Cooling option | Pros | Cons |
|---|---|---|
| Air | Familiar, no facility water | Limits density; high fan power; thermal throttling risk |
| Rear-door heat exchanger | Retrofit for existing air-cooled halls | Still limited by node airflow |
| Direct-to-chip liquid | Supports very high rack density, efficient | Facility plumbing, leak management, new operational skills |

**Thermal throttling is a performance failure, not just a facility alert.** One hot GPU slows a synchronous job across the whole cluster.

---

## 10. Manifests and configuration

### 10.1 Kubernetes: GPU Operator `ClusterPolicy` for DGX nodes (pre-installed driver)

DGX OS ships the NVIDIA driver, so the operator does **not** manage it. It still deploys the toolkit, the device plugin, GPU Feature Discovery, DCGM and the validator.

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: cluster-policy
spec:
  operator:
    defaultRuntime: containerd
  daemonsets:
    priorityClassName: system-node-critical
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
  driver:
    enabled: false
    rdma:
      enabled: false
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
    config:
      name: ""
      default: ""
  gfd:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
    serviceMonitor:
      enabled: true
      interval: 15s
  mig:
    strategy: single
  migManager:
    enabled: true
  nodeStatusExporter:
    enabled: true
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: "false"
  gds:
    enabled: false
```

> On non-DGX nodes where the operator installs the driver, set `driver.enabled: true` and `driver.rdma.enabled: true` (or rely on DMA-BUF with a recent driver and kernel) to get GPUDirect RDMA.

### 10.2 Kubernetes: Network Operator `NicClusterPolicy` with an RDMA shared device plugin

This exposes the 8 compute-rail ConnectX-7 ports (InfiniBand) as an extended resource that pods can request. The device-plugin config is a JSON string embedded in a YAML block scalar.

```yaml
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  ofedDriver:
    image: doca-driver
    repository: nvcr.io/nvidia/mellanox
    version: 24.10-0.7.0.0-0
    startupProbe:
      initialDelaySeconds: 10
      periodSeconds: 20
    livenessProbe:
      initialDelaySeconds: 30
      periodSeconds: 30
    readinessProbe:
      initialDelaySeconds: 10
      periodSeconds: 30
    upgradePolicy:
      autoUpgrade: true
      maxParallelUpgrades: 1
      drain:
        enable: true
        force: true
        timeoutSeconds: 300
        deleteEmptyDir: true
  rdmaSharedDevicePlugin:
    image: k8s-rdma-shared-dev-plugin
    repository: ghcr.io/mellanox
    version: v1.5.2
    config: |
      {
        "configList": [
          {
            "resourceName": "rdma_shared_device_ib",
            "rdmaHcaMax": 63,
            "selectors": {
              "vendors": ["15b3"],
              "linkTypes": ["infiniband"],
              "ifNames": ["ibp24s0", "ibp64s0", "ibp79s0", "ibp94s0", "ibp154s0", "ibp192s0", "ibp206s0", "ibp220s0"]
            }
          }
        ]
      }
```

> Pin `version` values to what the Network Operator release notes list for your operator version. The `ifNames` must match the output of `ibdev2netdev` on your nodes (Section 11).

### 10.3 Kubernetes: a secondary IB network through Multus (IPoIB)

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
      "range": "10.200.0.0/16",
      "exclude": ["10.200.0.0/30"]
    }
```

### 10.4 Kubernetes: a full-node training pod with 8 GPUs and RDMA

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nccl-allreduce-worker-0
  namespace: ai-training
  annotations:
    k8s.v1.cni.cncf.io/networks: ib-rail0
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: worker
      image: nvcr.io/nvidia/pytorch:24.10-py3
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
      env:
        - name: NCCL_DEBUG
          value: INFO
        - name: NCCL_IB_HCA
          value: "mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7"
        - name: NCCL_SOCKET_IFNAME
          value: eth0
      resources:
        requests:
          nvidia.com/gpu: 8
          rdma/rdma_shared_device_ib: 1
          cpu: "96"
          memory: 1500Gi
        limits:
          nvidia.com/gpu: 8
          rdma/rdma_shared_device_ib: 1
          cpu: "96"
          memory: 1500Gi
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 64Gi
```

Why each element is there:

- `IPC_LOCK` lets RDMA pin (register) memory. Without it, `ibv_reg_mr` fails.
- `rdma/rdma_shared_device_ib` mounts `/dev/infiniband/*` into the container.
- A large `/dev/shm` is needed because NCCL and PyTorch dataloaders use shared memory. The 64 MiB default causes crashes.
- `NCCL_IB_HCA` pins NCCL to the 8 compute-rail HCAs, so it does not accidentally use the storage/management ports.

### 10.5 Kubernetes: node health check Job with DCGM diagnostics

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: dcgm-diag-level2
  namespace: gpu-operator
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: dgx-a017
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: dcgm-diag
          image: nvcr.io/nvidia/cloud-native/dcgm:3.3.9-1-ubuntu22.04
          command: ["dcgmi", "diag", "-r", "2"]
          resources:
            limits:
              nvidia.com/gpu: 8
```

### 10.6 Slurm: GPU-aware node definition (not YAML)

`gres.conf`:

```ini
AutoDetect=nvml
```

`slurm.conf` (excerpt):

```ini
GresTypes=gpu
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
TopologyPlugin=topology/tree
NodeName=dgx-a[001-032] Gres=gpu:h100:8 CPUs=224 Sockets=2 CoresPerSocket=56 ThreadsPerCore=2 RealMemory=2000000 State=UNKNOWN
PartitionName=batch Nodes=dgx-a[001-032] Default=YES MaxTime=INFINITE State=UP OverSubscribe=EXCLUSIVE
```

`topology.conf` (tells Slurm which nodes share leaf switches, so it can pack jobs to minimize hops):

```ini
SwitchName=su1-spine Switches=su1-leaf[0-7]
SwitchName=su1-leaf[0-7] Nodes=dgx-a[001-032]
```

---

## 11. CLI verification: what healthy looks like

> The outputs below are representative of a DGX H100 and have been shortened. Exact device names, bus IDs and NUMA ranges vary by system and software version.

### 11.1 GPU inventory and health

```
$ nvidia-smi --query-gpu=index,name,memory.total,pcie.link.gen.current,pcie.link.width.current,temperature.gpu,power.draw --format=csv
index, name, memory.total [MiB], pcie.link.gen.current, pcie.link.width.current, temperature.gpu, power.draw [W]
0, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 34, 71.52 W
1, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 33, 70.88 W
...
7, NVIDIA H100 80GB HBM3, 81559 MiB, 5, 16, 35, 72.10 W
```

Watch for PCIe gen < 5 or width < 16 **under load**. At idle, links can downshift to save power, which is normal.

### 11.2 Topology: NVLink and NIC locality

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  ...  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   NODE  ...  0-55,112-167  0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  NODE  PXB   ...  0-55,112-167  0
...
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   SYS   ...  56-111,168-223 1

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes (e.g., QPI/UPI)
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

How to read it:
- `NV18` between every GPU pair means all 18 NVLink 4 links are up through NVSwitch. `NV17` or lower means a degraded link.
- Each GPU should have **one NIC at `PIX`/`PXB`**: its rail NIC. That pairing is the GPUDirect RDMA path.

### 11.3 NVLink status

```
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s

$ nvidia-smi nvlink -e -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-...)
         Link 0: Replay Errors: 0
         Link 0: Recovery Errors: 0
         Link 0: CRC Errors: 0
         ...
```

The Fabric Manager service must be running on NVSwitch systems. Without it, the GPUs do not join the NVLink fabric and CUDA initialization fails:

```
$ systemctl is-active nvidia-fabricmanager
active
```

### 11.4 Compute-fabric NICs

```
$ ibdev2netdev
mlx5_0 port 1 ==> ibp24s0 (Up)
mlx5_1 port 1 ==> ibp64s0 (Up)
mlx5_2 port 1 ==> ibp79s0 (Up)
mlx5_3 port 1 ==> ibp94s0 (Up)
mlx5_4 port 1 ==> ibp154s0 (Up)
mlx5_5 port 1 ==> ibp192s0 (Up)
mlx5_6 port 1 ==> ibp206s0 (Up)
mlx5_7 port 1 ==> ibp220s0 (Up)
mlx5_8 port 1 ==> enp41s0f0np0 (Up)
mlx5_9 port 1 ==> enp41s0f1np1 (Up)
...

$ ibstat mlx5_0
CA 'mlx5_0'
        CA type: MT4129
        Number of ports: 1
        Firmware version: 28.39.1002
        Hardware version: 0
        Node GUID: 0xa088c20300xxxxxx
        System image GUID: 0xa088c20300xxxxxx
        Port 1:
                State: Active
                Physical state: LinkUp
                Rate: 400
                Base lid: 112
                LMC: 0
                SM lid: 1
                Capability mask: 0xa751e848
                Port GUID: 0xa088c20300xxxxxx
                Link layer: InfiniBand
```

Healthy indicators: `State: Active` (the Subnet Manager has configured the port), `Physical state: LinkUp`, `Rate: 400` (NDR), and **the same firmware version on all 8 NICs and across all nodes**.

`State: Initializing` with `Physical state: LinkUp` means the cable is fine but **no Subnet Manager** has programmed the port. Check UFM/OpenSM.

### 11.5 Link quality

```
$ sudo mlxlink -d mlx5_0 -c
...
Physical Counters and BER Info
------------------------------
Time Since Last Clear [Min]       : 4320.5
Effective Physical Errors         : 0
Effective Physical BER            : 15E-255
Raw Physical BER                  : 1E-11
Link Down Counter                 : 0
Link Error Recovery Counter       : 0
```

A rising `Link Down Counter` or `Link Error Recovery Counter`, or a high effective BER, points to a bad transceiver, a dirty fiber or a marginal cable. These are the classic causes of a "job slows down at random".

### 11.6 Out-of-band: BMC reachability

```
$ ipmitool -I lanplus -H dgx-a017-bmc -U admin -P '***' chassis status
System Power         : on
Power Overload       : false
Main Power Fault     : false
Power Control Fault  : false
Power Restore Policy : always-off
...

$ curl -sk -u admin:*** https://dgx-a017-bmc/redfish/v1/Chassis | head
```

### 11.7 Kubernetes view

```
$ kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count
NAME       STATUS   ROLES    AGE   VERSION   GPU.PRODUCT              GPU.COUNT
dgx-a001   Ready    <none>   41d   v1.30.4   NVIDIA-H100-80GB-HBM3    8
dgx-a002   Ready    <none>   41d   v1.30.4   NVIDIA-H100-80GB-HBM3    8

$ kubectl describe node dgx-a001 | sed -n '/Allocatable:/,/System Info/p'
Allocatable:
  cpu:                          224
  memory:                       2063597268Ki
  nvidia.com/gpu:               8
  rdma/rdma_shared_device_ib:   63
  ...

$ kubectl -n gpu-operator get pods
NAME                                         READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-xxxxx                  1/1     Running     0          41d
nvidia-container-toolkit-daemonset-xxxxx     1/1     Running     0          41d
nvidia-cuda-validator-xxxxx                  0/1     Completed   0          41d
nvidia-dcgm-exporter-xxxxx                   1/1     Running     0          41d
nvidia-device-plugin-daemonset-xxxxx         1/1     Running     0          41d
nvidia-operator-validator-xxxxx              1/1     Running     0          41d
```

### 11.8 End-to-end fabric validation with NCCL

Run inside the training image across 2 nodes (16 GPUs), for example with `nccl-tests` built in the container and launched by `mpirun` or `srun`:

```
$ srun -N 2 --ntasks-per-node=8 --gpus-per-node=8 ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 1
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
...
  8589934592    2147483648     float     sum      -1    ...     ...     ...      0     ...     ...     ...      0
# Avg bus bandwidth    : ...
```

Compare the large-message `busbw` to the baseline your vendor or acceptance tests established for the same node count. A node that drags the whole result down is found by **bisection**: rerun on pairs of nodes until the outlier shows up. In the NCCL debug log, confirm the transport:

```
$ NCCL_DEBUG=INFO ... 2>&1 | grep -E "NET/IB|GDRDMA"
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_1:1/IB ... [7]mlx5_7:1/IB ; OOB eth0:10.10.1.17<0>
NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
```

`GDRDMA` confirms GPUDirect RDMA is in use. If you see `NET/Socket` instead of `NET/IB`, NCCL fell back to TCP. Throughput will be a small fraction of expected.

### 11.9 GPU diagnostics

```
$ dcgmi diag -r 2
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.9                                          |
| Number of GPUs Detected   | 8                                              |
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Pass                                           |
| Graphics Processes        | Pass                                           |
| Inforom                   | Pass                                           |
|-----  Integration  -------+------------------------------------------------|
| PCIe                      | Pass - All                                     |
|-----  Hardware  ----------+------------------------------------------------|
| GPU Memory                | Pass - All                                     |
+---------------------------+------------------------------------------------+
```

Use `-r 3` (or `-r 4`) for burn-in and acceptance testing. They take longer and stress the GPUs harder.

---

## 12. Failure diagnosis guide

| Symptom | Probable component | Check | Typical fix |
|---|---|---|---|
| Multi-node job scales poorly; single-node is fine | Compute fabric | `NCCL_DEBUG=INFO` shows `NET/Socket`; `ibstat` not `Active`; NCCL bisection | Fix SM/UFM, IB device plugin, `IPC_LOCK`, `NCCL_IB_HCA` |
| Job randomly slows down, no errors in the app | One bad link or transceiver | `mlxlink -c` counters, UFM link telemetry, rerun nccl-tests per node pair | Replace optic/cable, clean fiber, drain node until fixed |
| `NV18` became `NV17`, or CUDA init fails on NVSwitch node | NVLink / NVSwitch / Fabric Manager | `nvidia-smi nvlink -e`, `systemctl status nvidia-fabricmanager`, `dmesg` for Xid | Restart Fabric Manager; matching driver/FM versions; RMA if hardware |
| `ibstat` shows `Initializing` | No Subnet Manager on that partition | UFM status, `sminfo` | Start/repair SM; check UFM HA |
| GPU at PCIe Gen3/x8 under load | Riser, slot, BIOS | `nvidia-smi -q -d PCI`, `lspci -vv` | Reseat; BIOS update; RMA |
| Xid 79 "GPU has fallen off the bus" | GPU / PCIe / power | `dmesg | grep -i xid`, BMC SEL | Drain node, power-cycle via BMC, RMA if repeated |
| Xid 48 / 63 / 64 (ECC, row remapping) | HBM | `nvidia-smi -q -d ECC,ROW_REMAPPER` | Reset GPU to apply pending row remap; RMA if remapping fails |
| Clocks drop, `HW Slowdown` / `Thermal` active | Cooling / facility | `nvidia-smi -q -d PERFORMANCE,TEMPERATURE`, BMC sensors | Check airflow, CDU, inlet temperature, blanking panels |
| Node unreachable by SSH | In-band network or host OS | Ping in-band IP, then BMC (OOB) | Use BMC console; power-cycle via Redfish/IPMI |
| GPUs idle, low utilization, high iowait | Storage fabric / filesystem | `iostat`, FS client stats, `gdscheck -p` | Cache to local NVMe, fix storage fabric, data format |
| Pods `Pending` with `Insufficient nvidia.com/gpu` | Device plugin / operator | `kubectl -n gpu-operator get pods`, node allocatable | Fix operator pods, driver/toolkit mismatch |
| Pods fail with `ibv_reg_mr` / "Cannot allocate memory" | RDMA memlock | Pod security context | Add `IPC_LOCK`; raise memlock ulimit |
| Inconsistent performance across nodes | Firmware or driver drift | Compare `ibstat` FW, `nvidia-smi` driver, BIOS across fleet | Single golden image (BCM); controlled rolling upgrades |

### Diagnostic order (outside-in, cheapest first)

1. **Is the node reachable?** In-band → OOB/BMC. A node that is only reachable via BMC is an in-band or OS problem.
2. **Does the node see all its hardware?** 8 GPUs, `NV18`, 8 rail NICs `Active` at 400, PCIe Gen5 x16.
3. **Is the node healthy in isolation?** `dcgmi diag -r 2`, single-node nccl-tests (NVLink only).
4. **Is the fabric healthy between nodes?** Pairwise nccl-tests, `mlxlink` counters, UFM.
5. **Is the scheduler and software layer correct?** Operator pods, allocatable resources, NCCL transport selection.
6. **Is the facility within limits?** Temperatures, throttle reasons, power capping.

Automated health checks (BCM health checks, DCGM policies, Kubernetes node problem detection) should **drain** a node automatically on these signals. In a synchronous cluster, a sick node that keeps accepting work is worse than a missing node.

---

## 13. Key exam takeaways

- A GPU cluster is designed as **one synchronous system**: the slowest component bounds the whole job.
- **Scale-up = NVLink/NVSwitch** (inside the node or NVLink domain, ~900 GB/s–1.8 TB/s per GPU). **Scale-out = InfiniBand or Spectrum-X Ethernet** (400 Gb/s per GPU NIC).
- DGX nodes pair **one 400 Gb/s NIC per GPU**, with PCIe locality, for GPUDirect RDMA.
- Reference clusters use **four separate networks**: compute, storage, in-band management, out-of-band management.
- The compute fabric is **rail-optimized and non-blocking**; the SuperPOD **Scalable Unit is 32 DGX nodes**.
- **BlueField DPUs** offload networking, storage and security from the host CPU and provide an **isolated trust domain**.
- **GPUDirect RDMA / Storage** remove the CPU and host memory from the data path.
- **Management nodes** (BCM, Slurm/Kubernetes control plane) and **UFM** are separate, dedicated infrastructure.
- **Power density and cooling** (10–14 kW per node, liquid cooling at rack scale) are first-class design constraints.
- Operations rely on **DCGM, UFM, NCCL tests and BMC/OOB access** to find and isolate failing components.

---

## Referencias

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA DGX SuperPOD Reference Architecture, DGX B200: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide, Component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Offloading and Isolating Data Center Workloads with NVIDIA BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes/latest/index.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- NCCL tests: https://github.com/NVIDIA/nccl-tests