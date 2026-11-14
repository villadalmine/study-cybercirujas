# 2.7 — Determine Networking Requirements for AI Workloads

## 1. Why the Network Determines Whether AI Infrastructure Performs

A single GPU node is rarely the bottleneck in a production AI cluster. The network that ties GPUs together usually is. Once a model or a training job outgrows one GPU, every training step ends with a **collective communication** phase. In that phase, gradients, activations or parameters are exchanged among all participating GPUs, and no GPU can start step *n+1* until it finishes. The cluster therefore runs at the speed of its slowest link.

Some numbers show the scale of the problem:

- An NVIDIA H100 SXM delivers on the order of ~1,000 dense BF16 TFLOPS. A B200 is roughly twice that.
- A data-parallel replica of a 70B-parameter model in BF16 produces **~140 GB of gradients per step**, and those gradients must be all-reduced.
- A 100 GbE NIC moves 12.5 GB/s. An NDR InfiniBand or 400 GbE port moves 50 GB/s.

If you underprovision the fabric, a $300k+ server spends most of each step idle, waiting on the network. The NCA-AIIO domain "Determine networking requirements" asks you to reason about this. You need to know which traffic goes on which fabric, at what bandwidth, with what latency and loss characteristics, and with which NVIDIA technologies.

### 1.1 The four traffic classes of an AI data center

| Traffic class | Direction | Typical consumer | Requirement | NVIDIA reference fabric |
|---|---|---|---|---|
| **GPU-to-GPU inside a node** (scale-up) | Intra-node | Tensor parallelism, expert parallelism, NCCL intra-node collectives | TB/s, sub-µs, memory-semantic | NVLink + NVSwitch |
| **GPU-to-GPU across nodes** (scale-out, "compute fabric") | East-west | Data/pipeline parallel collectives, distributed inference KV transfer | 400–800 Gb/s **per GPU**, low latency, lossless, non-blocking | InfiniBand (Quantum-2/X800) or Spectrum-X Ethernet (RoCE) |
| **Storage** | East-west / north-south | Dataset reads, checkpoint writes, model loading | High aggregate throughput, RDMA (GPUDirect Storage) | Dedicated storage fabric (IB or Ethernet), often via BlueField DPU |
| **Management & user access** | North-south | SSH, Slurm/K8s control plane, monitoring, image pulls, inference API traffic | Reliability, isolation, moderate bandwidth | In-band Ethernet + out-of-band (BMC) Ethernet |

The DGX SuperPOD reference architecture builds these as **physically separate networks**. Its four fabrics are compute, storage, in-band management and out-of-band management. You will see the same separation in every DGX/HGX design. The exam expects you to know why: interference isolation, failure-domain isolation, and right-sizing each fabric for its own traffic pattern.

### 1.2 Training vs. inference: different network profiles

| Dimension | Large-scale training | Inference (online serving) |
|---|---|---|
| Dominant pattern | Synchronous collectives (all-reduce, all-gather, reduce-scatter, all-to-all for MoE) | Request/response; for large models, intra-node TP plus, increasingly, KV-cache transfer between prefill and decode pools |
| Sensitivity | Bandwidth **and** tail latency (stragglers stall every rank) | Latency (TTFT, inter-token latency), north-south throughput |
| East-west need | Extreme, sustained, bursty in lockstep | Moderate to high (disaggregated serving, multi-node TP/PP for very large models) |
| North-south need | Low (job control, dataset ingest via storage fabric) | High: client traffic, load balancers, API gateways |
| Failure tolerance | One bad link can slow or hang a 1,000-GPU job | Usually isolated to replicas; load balancer reroutes |
| Typical design | Rail-optimized, non-blocking fat tree, 1 NIC per GPU | Scale-up node(s) per replica, Ethernet front-end, compute fabric if multi-node models |

---

## 2. Scale-Up: NVLink and NVSwitch

### 2.1 Mechanics

NVLink is a point-to-point, high-signaling-rate GPU interconnect. It supports **memory semantics**: a GPU can load, store or perform atomics directly on a peer's HBM. NVSwitch is a switch ASIC that connects every GPU's NVLinks into a non-blocking crossbar. That crossbar gives every GPU full NVLink bandwidth to every other GPU in the NVLink domain, with no shared PCIe or CPU path.

From third-generation NVSwitch (Hopper) onward, the switch also implements **NVLink SHARP (NVLS)**. NVLS performs in-switch reductions, so an all-reduce inside the node sends roughly half the data it would with a ring algorithm. NCCL uses NVLS automatically when it is available.

| Platform | NVLink gen | Per-GPU NVLink bandwidth (bidirectional) | NVSwitch in system | NVLink domain |
|---|---|---|---|---|
| DGX A100 | 3rd | 600 GB/s (12 links) | 6× NVSwitch (2nd gen) | 8 GPUs |
| DGX H100 / H200 | 4th | 900 GB/s (18 links) | 4× NVSwitch (3rd gen, NVLS) | 8 GPUs |
| DGX B200 | 5th | 1.8 TB/s (18 links) | 2× NVSwitch (5th gen) | 8 GPUs, 14.4 TB/s aggregate |
| GB200 NVL72 | 5th | 1.8 TB/s | NVLink Switch trays in the rack | **72 GPUs**, ~130 TB/s aggregate |

For comparison, PCIe Gen5 x16 provides about **128 GB/s bidirectional**. NVLink 5 is more than 14× that per GPU. This gap explains why tensor parallelism, which exchanges activations at every layer, is almost always kept **inside the NVLink domain**.

### 2.2 Architectural consequence: map parallelism to the hierarchy

```
            ┌──────────────── NVLink domain (8 GPUs, or 72 on NVL72) ────────────────┐
 Tensor     │ highest traffic, per-layer activations → NVLink/NVSwitch (TB/s)        │
 parallel   └─────────────────────────────────────────────────────────────────────────┘
 Pipeline     point-to-point activations between stages → compute fabric (400–800 Gb/s/GPU)
 parallel
 Data         gradient all-reduce once per step (overlappable) → compute fabric, SHARP-offloadable
 parallel
 Expert       all-to-all token routing → prefers large NVLink domains (NVL72) or high-radix fabric
 parallel
```

Rule of thumb: **the more frequent and the more latency-critical the exchange, the closer to the GPU it must stay.** The rack-scale NVLink domain of GB200 NVL72 exists largely so that mixture-of-experts all-to-all and very large tensor-parallel groups never touch the scale-out network.

---

## 3. Scale-Out: The Compute Fabric

### 3.1 Sizing rule: one NIC per GPU, matched bandwidth

Modern DGX systems give **each GPU its own NIC** on the compute fabric:

| System | Compute-fabric NICs | Per-GPU scale-out bandwidth | Storage / in-band NICs |
|---|---|---|---|
| DGX H100 | 8× single-port ConnectX-7 (exposed as 4× OSFP twin-port cages) | 400 Gb/s (NDR IB or 400 GbE) | 2× dual-port ConnectX-7 (QSFP112), up to 400 Gb/s; optional BlueField-3 |
| DGX B200 | 8× single-port ConnectX-7 via 4× OSFP | 400 Gb/s | 2× dual-port BlueField-3 DPU |
| Blackwell Ultra (B300/GB300) generation | ConnectX-8 SuperNIC | 800 Gb/s | BlueField-3 |

Why one NIC per GPU? Each NIC sits on the **same PCIe switch** as its GPU. With **GPUDirect RDMA**, the NIC reads and writes GPU memory directly, so data never crosses host memory or the CPU root complex, and never crosses the inter-socket link. A shared NIC across GPUs would reintroduce PCIe contention and CPU-path hops.

### 3.2 Bandwidth estimation: worked example

A ring all-reduce over *N* ranks sends and receives `2·(N−1)/N · S` bytes per rank for a message of size *S*. If per-rank network bandwidth is *B*:

```
t_allreduce ≈ 2·(N−1)/N · S / B
```

Take a 7B-parameter model with BF16 gradients (S = 14 GB) across 64 GPUs (8 nodes). Assume the collective is bottlenecked by inter-node links and ignore overlap.

| Per-GPU fabric | B (GB/s) | t_allreduce | Comment |
|---|---|---|---|
| 1× 100 GbE shared by 8 GPUs | 1.56 | ~17.6 s | Unusable |
| 100 GbE per GPU | 12.5 | ~2.2 s | Communication dominates step time |
| 400 Gb/s (NDR / 400 GbE) per GPU | 50 | ~0.55 s | Can be hidden behind backward pass with overlap |
| 400 Gb/s + SHARP in-network reduction | ~effective 2× | ~0.28 s | Switch performs reduction, halves the data each endpoint moves |

The conclusion that matters on the exam: **compute-fabric bandwidth is provisioned per GPU, not per server**, and the fabric must be **non-blocking (1:1)** so that all ranks can communicate at line rate simultaneously.

### 3.3 Topology: rail-optimized, non-blocking fat tree

In a **rail-optimized** design, GPU/NIC *k* of every node connects to the **same leaf switch (rail k)**. NCCL places ring and tree neighbors so that most traffic between GPUs of the same index stays **one switch hop** away and never climbs to the spine.

```
            Spine layer (full bisection bandwidth, 1:1)
     ┌──────────┬──────────┬──────────┬─────  ...  ─────┐
   Leaf R0    Leaf R1    Leaf R2    Leaf R3   ...      Leaf R7     ← one leaf (or leaf group) per rail
     │          │          │          │                  │
  ┌──┴──┐    ┌──┴──┐    ┌──┴──┐    ┌──┴──┐            ┌──┴──┐
  Node1 NIC0 Node1 NIC1 Node1 NIC2 Node1 NIC3   ...    Node1 NIC7
  Node2 NIC0 Node2 NIC1 ...
  ...
  NodeN NIC0 ...                                        NodeN NIC7
```

The DGX SuperPOD (B200) reference architecture builds the compute fabric from **Scalable Units (SUs) of 32 DGX systems**. Each SU is rail-optimized, with NDR 400 Gb/s InfiniBand on Quantum-2 QM9700 switches (64 ports of NDR each). SUs are joined through a spine layer, which keeps the full fat tree non-blocking.

### 3.4 InfiniBand vs. Spectrum-X Ethernet (RoCE)

| Characteristic | InfiniBand (Quantum-2 NDR / Quantum-X800 XDR) | Spectrum-X Ethernet (Spectrum-4 + BlueField-3 / ConnectX SuperNIC) | Generic Ethernet + RoCEv2 |
|---|---|---|---|
| Losslessness | Native, **credit-based link-level flow control** | RoCE with PFC/ECN plus NVIDIA congestion control tuned end-to-end | PFC + ECN + DCQCN; must be hand-tuned |
| Control plane | **Subnet Manager** (UFM or OpenSM) assigns LIDs and computes routes | Standard Ethernet/IP (BGP/EVPN), NVUE/Cumulus | Standard Ethernet/IP |
| Adaptive routing | Yes (per-packet, switch-driven) | Yes (per-packet AR, NIC reorders via DDP) | Usually ECMP flow hashing → elephant-flow collisions |
| In-network compute | **SHARP** (reductions offloaded to switches) | No SHARP in-network reduction (NVLS stays in the NVLink domain) | No |
| Latency | Lowest (sub-µs port-to-port) | Low | Variable under congestion |
| Multi-tenancy / cloud integration | Partition keys (PKeys), more specialized ops | Native Ethernet tooling, VRF/VXLAN, BlueField isolation | Native |
| Typical use | Largest training clusters, DGX SuperPOD default | AI clouds and Ethernet-standardized enterprises | Small clusters, inference, non-critical |
| Operational skillset | HPC/IB (ibdiagnet, UFM) | Network engineering on Ethernet | Network engineering |

Both are first-class NVIDIA AI fabrics. **Generic, oversubscribed Ethernet with ECMP is not an AI compute fabric.** Flow-hash collisions among a few huge, synchronized flows produce exactly the tail latency that stalls collectives.

### 3.5 Lossless transport and why it matters

RDMA transports (IB verbs, RoCEv2) assume a near-lossless network. A single dropped packet triggers retransmission timeouts that cost far more than the drop itself. In a synchronous collective, the slowest rank sets the pace for all ranks.

- **InfiniBand:** a sender transmits only when the receiver has advertised buffer credits, so the network cannot drop for congestion by design.
- **RoCEv2:** Priority Flow Control (PFC, IEEE 802.1Qbb) pauses a specific traffic class. ECN marks packets before queues overflow. DCQCN (or Spectrum-X congestion control) throttles senders. A misconfigured PFC can cause **PFC storms and head-of-line blocking**, which is the classic RoCE operational risk.

### 3.6 In-network computing: SHARP

NVIDIA **Scalable Hierarchical Aggregation and Reduction Protocol** runs the reduction step of all-reduce inside Quantum switches. Each endpoint sends its data once, and the aggregation tree returns the result. Effects:

- Roughly halves the bytes each NIC must move for an all-reduce.
- Reduces latency for small and medium messages, because there are fewer hops of software-driven exchange.
- Is used by NCCL through the CollNet/SHARP plugin when the fabric and the SM/UFM aggregation manager support it.

---

## 4. Storage and North-South Networking

### 4.1 Storage fabric

- **Workloads:** dataset streaming (read-heavy, random or large sequential), checkpointing (burst writes of hundreds of GB to TB), model loading in inference (cold-start latency).
- **GPUDirect Storage (GDS):** a DMA path between NVMe/NVMe-oF/parallel-filesystem clients and GPU memory that bypasses the CPU bounce buffer. It is part of **Magnum IO** together with GPUDirect RDMA, NCCL, NVSHMEM and UCX.
- **Why separate from compute:** a checkpoint burst sharing links with all-reduce traffic creates stragglers. SuperPOD gives storage its own fabric and its own NICs (the dual-port ConnectX-7 / BlueField-3 ports on DGX).
- **Sizing:** sized by aggregate read and write throughput per SU and per node, against the storage performance tiers specified in the SuperPOD reference architecture. Checkpoint size and frequency drive write bandwidth. Data-loader throughput per GPU drives read bandwidth.

### 4.2 In-band and out-of-band management

| Network | Purpose | Typical speed | Notes |
|---|---|---|---|
| **In-band management** | OS access, Slurm/Kubernetes control plane, container registry pulls, monitoring, NFS home dirs | 25–200 GbE | Often also carries user/login access via gateway nodes |
| **Out-of-band (OOB)** | BMC (Redfish/IPMI), switch management ports, PDUs | 1 GbE | Must remain reachable when the host OS or in-band network is down; isolated for security |

### 4.3 Inference front-end (north-south)

Inference adds a **client-facing Ethernet** path: load balancers, API gateways, TLS termination, and service mesh. Its requirements differ from those of the compute fabric:

- **Per-request latency budget:** network RTT adds directly to TTFT.
- **Throughput:** streaming tokens is cheap, but multimodal inputs (images, audio, video) can be heavy.
- **Disaggregated prefill/decode:** this pattern moves KV cache between GPU pools. That transfer is east-west RDMA traffic (NIXL/UCX over IB or RoCE), so serving clusters increasingly need a real compute fabric as well.

---

## 5. BlueField DPU: Offload and Isolation

A **BlueField DPU** is a NIC (ConnectX core) with Arm cores, hardware accelerators (crypto, regex, compression, storage emulation) and its own OS. NVIDIA's offload-and-isolate model moves **infrastructure services** off the host CPU and onto the DPU.

| Function | Without DPU | With BlueField |
|---|---|---|
| Virtual switching (OVS), overlay (VXLAN) | Host CPU cores | OVS-DOCA hardware offload on DPU |
| Firewall / microsegmentation | Host iptables/eBPF, tenant can tamper | Enforced on DPU, outside the tenant's trust domain |
| Encryption (IPsec/TLS) | Host CPU | Inline crypto engines |
| Storage virtualization | Host CPU running NVMe-oF initiator | SNAP: DPU presents NVMe devices backed by remote storage |
| Telemetry | Host agents | DPU-side, tamper-resistant |

Why this matters for AI networking requirements:

1. **Host CPU reclaimed:** the CPU stays free for data loading and preprocessing.
2. **Multi-tenant isolation:** in AI clouds the tenant may have root on the host, yet the network policy runs on the DPU and the tenant cannot reach it.
3. **Spectrum-X:** a BlueField-3 SuperNIC (or ConnectX-8) participates in end-to-end congestion control and adaptive-routing reorder.
4. **DGX B200:** uses 2× dual-port BlueField-3 for storage and in-band traffic. The compute fabric stays on ConnectX-7.

The software stack is **DOCA**, the DPU SDK and runtime services.

---

## 6. Decision Framework: Determining Requirements

Answer these questions in order. The exam scenarios follow the same logic.

| # | Question | If yes / large | If no / small |
|---|---|---|---|
| 1 | Does the model or job fit in **one GPU**? | No multi-GPU network needed beyond front-end | Continue |
| 2 | Does it fit in **one NVLink domain** (8 GPUs, or 72 on NVL72)? | NVLink/NVSwitch suffices for GPU traffic; size storage + front-end | Need compute fabric |
| 3 | Is it **training** (synchronous collectives)? | Non-blocking, rail-optimized, 1 NIC/GPU at 400–800 Gb/s, lossless | Inference: size by latency and KV/PP traffic |
| 4 | Is the scale **hundreds+ of GPUs** or is MoE dominant? | InfiniBand with SHARP, or Spectrum-X; consider NVL72 for all-to-all | Smaller IB or Spectrum-X; RoCE acceptable if properly tuned |
| 5 | Is it **multi-tenant** or an AI cloud? | BlueField DPUs for isolation; Ethernet/Spectrum-X often preferred | Bare-metal, single-tenant IB is simplest |
| 6 | Checkpoint size × frequency, dataset throughput? | Dedicated storage fabric with GDS | In-band may carry storage for small clusters |
| 7 | Need lights-out operations? | Always: OOB management network | Always |

---

## 7. Kubernetes Implementation: Exposing the Fabric to Workloads

The **NVIDIA Network Operator** deploys the DOCA/MOFED driver, RDMA device plugins, secondary-network CNIs and IPAM. The **GPU Operator** deploys the GPU driver and loads `nvidia-peermem`, which GPUDirect RDMA requires. The manifests below show a rail-optimized InfiniBand compute fabric on DGX H100-class nodes. The last manifest shows the RoCE alternative.

### 7.1 NicClusterPolicy (InfiniBand compute fabric, RDMA shared device plugin)

On InfiniBand, NCCL addresses peers with **IB verbs (LID/GID)**, not IP. A pod therefore needs **access to the RDMA devices** but does not need a per-rail IP interface. NCCL bootstraps over the pod's primary interface (`eth0`).

```yaml
# NVIDIA Network Operator - NicClusterPolicy
# Pin image versions to the ones listed in the Network Operator release notes
# for the release you install; the values below are examples.
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
      safeLoad: false
      drain:
        enable: true
        force: true
        podSelector: ""
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
    version: "v1.5.3"
    # One resource that bundles the 8 compute-fabric HCAs (one per rail).
    # Interface names are platform specific: take them from `ibdev2netdev`.
    # The storage/in-band HCAs are intentionally excluded.
    config: |
      {
        "configList": [
          {
            "resourceName": "rdma_compute",
            "rdmaHcaMax": 64,
            "selectors": {
              "vendors": ["15b3"],
              "ifNames": [
                "ibp24s0",
                "ibp64s0",
                "ibp79s0",
                "ibp94s0",
                "ibp154s0",
                "ibp192s0",
                "ibp206s0",
                "ibp220s0"
              ]
            }
          }
        ]
      }
  nvIpam:
    image: nvidia-k8s-ipam
    repository: ghcr.io/mellanox
    version: "v0.3.7"
    enableWebhook: false
  secondaryNetwork:
    cniPlugins:
      image: plugins
      repository: ghcr.io/k8snetworkplumbingwg
      version: "v1.6.2-update.1"
    multus:
      image: multus-cni
      repository: ghcr.io/k8snetworkplumbingwg
      version: "v4.1.0"
```

### 7.2 Multi-node NCCL validation job (MPI Operator)

```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: nccl-allreduce-2node
  namespace: ai-validation
spec:
  slotsPerWorker: 8
  runPolicy:
    cleanPodPolicy: Running
    backoffLimit: 0
  mpiImplementation: OpenMPI
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: launcher
              # Build from https://github.com/NVIDIA/nccl-tests on a CUDA base image
              # with OpenMPI; this tag is a placeholder for your registry.
              image: registry.example.com/hpc/nccl-tests:cuda12.6-nccl2.23
              command:
                - mpirun
                - --allow-run-as-root
                - -np
                - "16"
                - -bind-to
                - none
                - -map-by
                - slot
                - -x
                - NCCL_DEBUG=INFO
                - -x
                - NCCL_DEBUG_SUBSYS=INIT,NET
                - -x
                - NCCL_SOCKET_IFNAME=eth0
                - -x
                - NCCL_IB_HCA==mlx5_0,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_9,mlx5_10,mlx5_11
                - -x
                - NCCL_NET_GDR_LEVEL=PIX
                - -x
                - LD_LIBRARY_PATH
                - /opt/nccl-tests/build/all_reduce_perf
                - -b
                - 8M
                - -e
                - 16G
                - -f
                - "2"
                - -g
                - "1"
              resources:
                limits:
                  cpu: "2"
                  memory: 4Gi
    Worker:
      replicas: 2
      template:
        spec:
          restartPolicy: Never
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      training.kubeflow.org/job-name: nccl-allreduce-2node
                      training.kubeflow.org/job-role: worker
                  topologyKey: kubernetes.io/hostname
          containers:
            - name: worker
              image: registry.example.com/hpc/nccl-tests:cuda12.6-nccl2.23
              securityContext:
                capabilities:
                  add:
                    - IPC_LOCK
              resources:
                limits:
                  nvidia.com/gpu: 8
                  rdma/rdma_compute: 1
                  cpu: "96"
                  memory: 512Gi
                requests:
                  nvidia.com/gpu: 8
                  rdma/rdma_compute: 1
                  cpu: "96"
                  memory: 512Gi
              volumeMounts:
                - name: dshm
                  mountPath: /dev/shm
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
```

Key details:

- `IPC_LOCK` lets RDMA pin (register) memory. Without it, verbs fail with `Cannot allocate memory`.
- `/dev/shm` as a memory-backed volume lets NCCL use shared-memory transport between processes inside the pod. The 64 MB default breaks NCCL.
- `NCCL_IB_HCA==...` uses a leading `=`, which means an exact match. Without it, the value is treated as a prefix, so `mlx5_1` would also match `mlx5_10` and `mlx5_11`.
- Pod anti-affinity forces one worker per node, so the test actually crosses the fabric.

### 7.3 RoCE alternative: one IP network per rail (template for rail 0)

On Ethernet/RoCEv2, each rail needs an IP subnet so that RoCE GIDs exist inside the pod. Create one `IPPool` and one `MacvlanNetwork` per rail: `rail0` to `rail7`, each with its own `master` interface and subnet. Then list all eight in the pod annotation.

```yaml
apiVersion: nv-ipam.nvidia.com/v1alpha1
kind: IPPool
metadata:
  name: rail0-pool
  namespace: nvidia-network-operator
spec:
  subnet: 192.168.100.0/24
  perNodeBlockSize: 16
  gateway: 192.168.100.1
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: feature.node.kubernetes.io/network-sriov.capable
            operator: In
            values:
              - "true"
---
apiVersion: mellanox.com/v1alpha1
kind: MacvlanNetwork
metadata:
  name: rail0
spec:
  networkNamespace: ai-validation
  master: enp24s0np0
  mode: bridge
  mtu: 9000
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "rail0-pool"
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: roce-probe
  namespace: ai-validation
  annotations:
    k8s.v1.cni.cncf.io/networks: rail0,rail1,rail2,rail3,rail4,rail5,rail6,rail7
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: registry.example.com/hpc/nccl-tests:cuda12.6-nccl2.23
      command:
        - sleep
        - infinity
      env:
        - name: NCCL_IB_GID_INDEX
          value: "3"
        - name: NCCL_SOCKET_IFNAME
          value: eth0
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
      resources:
        limits:
          nvidia.com/gpu: 8
          rdma/rdma_compute: 1
```

`NCCL_IB_GID_INDEX=3` usually selects the RoCEv2/IPv4 GID. Verify the index with `show_gids` on your nodes.

### 7.4 Switch side: lossless RoCE on Spectrum (NVUE)

```
$ nv set qos roce mode lossless
$ nv config apply
$ nv show qos roce
                    operational  applied
------------------  -----------  --------
enable              on           on
mode                lossless     lossless
pfc
  pfc-priority      3            3
congestion-control
  congestion-mode   ECN          ECN
  enabled-tc        3            3
  min-threshold     150 KB       150 KB
  max-threshold     1500 KB      1500 KB
trust
  trust-mode        pcp,dscp     pcp,dscp
```

The `nv set qos roce` macro configures PFC on priority 3, ECN thresholds and DSCP trust in one step. The host NICs must use the same priority and DSCP mapping, which the DOCA driver and `mlnx_qos` handle on the server side.

---

## 8. Verification: CLI and Expected Output

All outputs below are representative of a DGX H100-class node. Exact device names, GUIDs and numbers vary.

### 8.1 Intra-node topology: is every GPU on NVLink and paired with a NIC?

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  NIC2  ...  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PIX   NODE  NODE  ...  0-55,112-167  0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  NODE  NODE  NODE  ...  0-55,112-167  0
...
GPU7    NV18  NV18  NV18  NV18  NV18  NV18  NV18   X    SYS   SYS   SYS   ...  56-111,168-223 1

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

What to look for:

- **`NV18` between all GPU pairs** means all 18 NVLink 4 links are active through NVSwitch. A lower number, or `SYS`/`NODE` between GPUs, means degraded NVLink.
- **Each GPU has exactly one NIC at `PIX`** (same PCIe switch). That NIC is the one NCCL will pair with for GPUDirect RDMA.

### 8.2 NVLink link state and speed

```
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1c2a8e-...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s
```

The output should show 18 links per H100, all with the same speed. A link reported as `<inactive>` is a hardware or NVSwitch fabric problem. Check that the Fabric Manager service is active:

```
$ systemctl is-active nvidia-fabricmanager
active
$ nvidia-smi -q | grep -A2 -i "fabric"
    Fabric
        State                             : Completed
        Status                            : Success
```

### 8.3 RDMA devices and link state

```
$ ibdev2netdev
mlx5_0 port 1 ==> ibp24s0 (Up)
mlx5_1 port 1 ==> enp41s0f0np0 (Up)
mlx5_2 port 1 ==> enp41s0f1np1 (Up)
mlx5_3 port 1 ==> ibp64s0 (Up)
mlx5_4 port 1 ==> ibp79s0 (Up)
mlx5_5 port 1 ==> ibp94s0 (Up)
mlx5_6 port 1 ==> ibp154s0 (Up)
mlx5_7 port 1 ==> enp170s0f0np0 (Up)
mlx5_8 port 1 ==> enp170s0f1np1 (Up)
mlx5_9 port 1 ==> ibp192s0 (Up)
mlx5_10 port 1 ==> ibp206s0 (Up)
mlx5_11 port 1 ==> ibp220s0 (Up)

$ ibstat mlx5_0
CA 'mlx5_0'
        CA type: MT4129
        Number of ports: 1
        Firmware version: 28.39.2048
        Hardware version: 0
        Node GUID: 0xa088c20300e1b2c4
        System image GUID: 0xa088c20300e1b2c4
        Port 1:
                State: Active
                Physical state: LinkUp
                Rate: 400
                Base lid: 112
                LMC: 0
                SM lid: 1
                Capability mask: 0xa751e848
                Port GUID: 0xa088c20300e1b2c4
                Link layer: InfiniBand
```

Checks:

- **`State: Active`** requires a working Subnet Manager. `State: Initializing` with `Physical state: LinkUp` means the cable is fine but **no SM is reachable** on that subnet.
- **`Rate: 400`** is the expected NDR speed. 200 or 100 means a downgraded link: bad cable, wrong transceiver, or a switch-port speed setting.
- MT4129 is ConnectX-7.

Confirm the Subnet Manager:

```
$ sminfo
sminfo: sm lid 1 sm guid 0x0002c90300a1b2c3, activity count 4512876 priority 15 state 3 SMINFO_MASTER
```

### 8.4 GPUDirect RDMA module

```
$ lsmod | grep -E "nvidia_peermem|ib_core"
nvidia_peermem         16384  0
ib_core               495616  9 rdma_cm,ib_ipoib,nvidia_peermem,iw_cm,ib_umad,rdma_ucm,ib_uverbs,mlx5_ib,ib_cm
nvidia              11657216  ... nvidia_uvm,nvidia_peermem,nvidia_modeset
```

On Kubernetes, the GPU Operator loads it when `driver.rdma.enabled=true`. Without `nvidia_peermem`, or the DMA-BUF path on newer kernels and drivers, NCCL falls back to staging through host memory.

### 8.5 Point-to-point RDMA bandwidth between two nodes (perftest)

```
# Node B (server)
$ ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -D 10

# Node A (client)
$ ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -D 10 nodeb-ib0
---------------------------------------------------------------------------------------
                    RDMA_Write BW Test
 Dual-port       : OFF          Device         : mlx5_0
 Number of qps   : 1            Transport type : IB
 Connection type : RC           Using SRQ      : OFF
 TX depth        : 128
 CQ Moderation   : 1
 Mtu             : 4096[B]
 Link type       : IB
 Max inline data : 0[B]
 rdma_cm QPs     : OFF
 Data ex. method : Ethernet
---------------------------------------------------------------------------------------
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 1048576    46802          392.61             392.48               0.046789
---------------------------------------------------------------------------------------
```

~392 Gb/s on a 400 Gb/s NDR link is healthy, since protocol overhead takes a few percent. To test GPUDirect RDMA from GPU memory, add `--use_cuda=0`. Perftest must be built with CUDA support.

### 8.6 Collective bandwidth: the number that actually matters

```
$ kubectl -n ai-validation logs -f nccl-allreduce-2node-launcher
...
nccl-allreduce-2node-worker-0:212:212 [0] NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_3:1/IB [2]mlx5_4:1/IB [3]mlx5_5:1/IB [4]mlx5_6:1/IB [5]mlx5_9:1/IB [6]mlx5_10:1/IB [7]mlx5_11:1/IB ; OOB eth0:10.244.3.17<0>
nccl-allreduce-2node-worker-0:212:212 [0] NCCL INFO Using network IB
nccl-allreduce-2node-worker-0:212:298 [0] NCCL INFO Channel 00/0 : 15[7] -> 0[0] [receive] via NET/IB/0/GDRDMA
...
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
     8388608       2097152     float     sum      -1    112.4   74.63  139.93      0    110.9   75.64  141.83      0
    67108864      16777216     float     sum      -1    497.1  135.00  253.13      0    495.6  135.41  253.89      0
   536870912     134217728     float     sum      -1   2983.7  179.94  337.38      0   2979.2  180.21  337.89      0
  4294967296    1073741824     float     sum      -1  22311.0  192.50  360.95      0  22298.4  192.62  361.16      0
 17179869184    4294967296     float     sum      -1  88974.2  193.09  362.04      0  88961.7  193.11  362.09      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 289.432
```

How to read it:

- **`busbw` (bus bandwidth)** normalizes algorithm bandwidth by `2(N−1)/N` for all-reduce. You can compare it against hardware link speed. Here 8 × 400 Gb/s = 400 GB/s per node of inter-node line rate, so **~360 GB/s busbw at large sizes is a healthy fabric**.
- **`NET/IB` with `GDRDMA`** confirms that NCCL uses InfiniBand verbs **with GPUDirect RDMA**.
- **`#wrong` = 0**: any non-zero value indicates data corruption, which is a hardware problem.
- Expect values well above line rate when SHARP/CollNet is enabled, and for single-node tests that use NVLink/NVLS (hundreds of GB/s).

### 8.7 Fabric-wide health (InfiniBand)

```
$ perfquery -x 112 1
# Port extended counters: Lid 112 port 1 (CapMask: 0x5A00)
PortSelect:......................1
CounterSelect:...................0x0000
PortXmitData:....................918273645509
PortRcvData:.....................918113420117
PortXmitPkts:....................2210378811
PortRcvPkts:.....................2209998102
...
$ perfquery 112 1 | grep -E "SymbolErrorCounter|LinkDownedCounter|PortRcvErrors|PortXmitDiscards"
SymbolErrorCounter:..............0
LinkDownedCounter:...............0
PortRcvErrors:...................0
PortXmitDiscards:................0

$ ibdiagnet --pc -o /tmp/ibdiag
...
-I- Links Check finished successfully
-I- PM Counters Info
-W- lid=0x0071 dev=54002 QM9700/U1 port=17 symbol_error_counter=1452 (threshold=1)
...
-I- Stages Status Report:
    STAGE                                    Errors Warnings
    Discovery                                0      0
    Lids Check                               0      0
    Links Check                              0      0
    Subnet Manager                           0      0
    Port Counters                            0      1
```

A rising `SymbolErrorCounter` on one switch port marks a marginal cable or transceiver. It is the most common hardware cause of a single slow rank in a large job. `mlxlink -d <device> -m` shows physical-layer detail such as BER, eye opening and module temperature for the suspect port.

---

## 9. Failure Diagnosis Playbook

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| NCCL log shows `NET/Socket` instead of `NET/IB`; busbw ~1–10 GB/s | Pod has no RDMA devices; wrong `NCCL_IB_HCA`; driver not loaded | `NCCL_DEBUG=INFO` → `NET/IB : No device found`; `ls /dev/infiniband` inside pod | Request `rdma/rdma_compute`, fix the device plugin selector, check the DOCA driver pod |
| `NET/IB` but no `GDRDMA`, busbw well below line rate | `nvidia_peermem` (or DMA-BUF support) missing; GPU-NIC not on same PCIe switch | `lsmod`, NCCL log `GPU Direct RDMA Disabled`; `nvidia-smi topo -m` shows `SYS` | Enable RDMA in the GPU Operator; set `NCCL_NET_GDR_LEVEL` appropriately; check NIC slot placement |
| Bandwidth is fine intra-node, poor inter-node; P2P errors | **PCIe ACS** enabled on switches/bridges, which forces P2P through the root complex | `lspci -vvv` shows `ACSCtl: SrcValid+`; NCCL P2P warnings | Disable ACS in BIOS or with `setpci` for bare metal; for VMs use ATS |
| `ibstat` shows `State: Initializing` | No Subnet Manager on that subnet, or SM failed over and is unreachable | `sminfo` times out | Restore UFM/OpenSM HA; check SM partition config |
| `Rate: 200` (or 100) on some ports | Downgraded link: cable, transceiver, port config | `mlxlink -d mlx5_X`, `ibdiagnet` speed check | Reseat or replace the cable/optic; set the port speed on the switch |
| One job slow, all nodes healthy individually | Single bad link or straggler; job spans SUs with suboptimal rail mapping | `ibdiagnet --pc` counters; NCCL per-rank timings; `nccl-tests` on subsets (bisect) | Replace the flaky link; drain the node; topology-aware scheduling |
| RoCE: periodic throughput collapse, pause frames climbing | PFC storm or head-of-line blocking; mismatched DSCP/priority between host and switch | `ethtool -S <if> \| grep pause`, `nv show qos roce`, `mlnx_qos -i <if>` | Align the trust/priority mapping; enable the PFC watchdog; verify ECN thresholds |
| RoCE: NCCL hangs at init across nodes | Wrong `NCCL_IB_GID_INDEX` (IPv6 link-local GID selected); MTU mismatch | `show_gids`; `ip link` MTU on the rails vs switch | Set the correct GID index; make MTU consistent end to end (e.g., 9000 / 4096 RoCE MTU) |
| `ibv_reg_mr` fails, `Cannot allocate memory` | Missing `IPC_LOCK` / memlock limit | `ulimit -l` in the container | Add `IPC_LOCK`; set an unlimited memlock in the runtime |
| NCCL crashes or very slow with "shm" errors | `/dev/shm` too small (64 MB default) | `df -h /dev/shm` in the pod | Mount an `emptyDir` with `medium: Memory` |
| NVLink errors or GPUs show `SYS` between each other | NVSwitch / Fabric Manager not running, or hardware fault | `systemctl status nvidia-fabricmanager`; `nvidia-smi nvlink -e` | Start Fabric Manager (same version as the driver); RMA if links stay down |
| Checkpoint writes slow training to a crawl | Storage traffic sharing the compute fabric, or the storage fabric undersized | Per-interface counters during the checkpoint; NCCL step time spikes aligned with checkpoints | Separate the storage fabric; asynchronous/staged checkpointing; GDS |

### Diagnostic order of operations

1. **Single node:** `nvidia-smi topo -m`, Fabric Manager status, `all_reduce_perf` with `-g 8` in one process. This validates NVLink/NVSwitch.
2. **Node to fabric:** `ibdev2netdev`, `ibstat` (Active, rate), `sminfo`. This validates links and the SM.
3. **Point to point:** `ib_write_bw` per rail between two nodes, with and without `--use_cuda`. This validates each rail and GPUDirect RDMA.
4. **Collective, two nodes, then scale up:** `nccl-tests` with `NCCL_DEBUG=INFO`. Confirm `NET/IB` + `GDRDMA` and compare `busbw` against line rate.
5. **Fabric-wide:** `ibdiagnet --pc`, or UFM / Spectrum telemetry. Find error counters and congestion hotspots.
6. **Bisect:** if a large job is slow, run nccl-tests on halves of the node set until you isolate the bad node or link.

---

## 10. Exam-Oriented Summary

| Concept | What to remember |
|---|---|
| Scale-up vs. scale-out | NVLink/NVSwitch inside a node or rack (TB/s); InfiniBand/Ethernet across nodes (400–800 Gb/s per GPU) |
| NVLink bandwidth | H100: 900 GB/s per GPU (NVLink 4); B200: 1.8 TB/s per GPU (NVLink 5); GB200 NVL72: 72-GPU domain, ~130 TB/s |
| DGX networking | 8 compute NICs (1 per GPU, 400 Gb/s ConnectX-7) + storage/in-band NICs (ConnectX-7 or BlueField-3) + BMC OOB |
| SuperPOD fabrics | Compute, storage, in-band management, out-of-band management: physically separate |
| Topology | Rail-optimized, non-blocking (1:1) fat tree; SU = 32 DGX (B200 RA) |
| InfiniBand strengths | Credit-based lossless, Subnet Manager, adaptive routing, SHARP in-network reduction |
| Ethernet for AI | Spectrum-X (Spectrum-4 + BlueField-3/ConnectX SuperNIC): RoCE, adaptive routing, congestion control; generic ECMP Ethernet is not sufficient for large training |
| RoCE requirements | PFC + ECN (lossless), consistent DSCP/priority, MTU, correct GID |
| GPUDirect RDMA | NIC ↔ GPU memory directly, no CPU/host-memory bounce; needs `nvidia_peermem` / DMA-BUF and NIC on the GPU's PCIe switch |
| GPUDirect Storage | Storage ↔ GPU memory DMA path; part of Magnum IO |
| BlueField DPU | Offloads and isolates infrastructure (networking, security, storage) from the host; DOCA SDK; key for multi-tenancy |
| Training vs. inference | Training: east-west, bandwidth-bound, lockstep. Inference: latency, north-south, plus east-west for multi-node and disaggregated serving |

---

## Referencias

- NVIDIA, *NCA-AIIO exam study guide*: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, *AI Infrastructure and Operations Fundamentals*: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA Technical Blog, *Offloading and Isolating Data Center Workloads with BlueField DPU*: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA, *DGX SuperPOD Reference Architecture — DGX B200*: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA, *DGX H100 User Guide — Component Descriptions*: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA, *NVLink and NVLink Switch*: https://www.nvidia.com/en-us/data-center/nvlink/
- NVIDIA Technical Blog, *Accelerating IO in the Modern Data Center: Network IO*: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes2504/index.html
- NVIDIA NCCL environment variables: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html
- NVIDIA nccl-tests (performance metrics, busbw definition): https://github.com/NVIDIA/nccl-tests/blob/master/doc/PERFORMANCE.md
- NVIDIA GPUDirect RDMA documentation: https://docs.nvidia.com/cuda/gpudirect-rdma/index.html
- NVIDIA Spectrum-X Ethernet platform: https://www.nvidia.com/en-us/networking/spectrumx/
- NVIDIA Cumulus Linux, RoCE configuration (NVUE): https://docs.nvidia.com/networking-ethernet-software/cumulus-linux/Layer-1-and-Switch-Ports/Quality-of-Service/RDMA-over-Converged-Ethernet-RoCE/