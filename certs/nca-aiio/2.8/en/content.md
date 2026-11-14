# 2.8 — Data Center Networking Protocols and Key Concepts for AI Infrastructure

## 1. Motivation: why the network decides whether an AI cluster performs

A single DGX B200 has eight Blackwell GPUs that can exchange data over NVLink at **1.8 TB/s per GPU**. A training job that spans 32, 127 or 1,000 such systems has to move gradients, activations and checkpoints *between* nodes. That traffic leaves the NVLink domain and crosses NICs, cables and switches whose bandwidth is an order of magnitude lower. The production problem looks like this:

- **Collective operations are synchronous.** An `AllReduce` in NCCL completes only when the *slowest* participant finishes. One congested link, one flapping port or one mis-set MTU slows every GPU in the job. This is the **tail-latency problem**: in AI fabrics, p99 latency matters more than average throughput.
- **The CPU is a bottleneck.** If every byte crosses the kernel TCP/IP stack and gets copied into host memory before reaching the GPU, the host CPU and the memory bandwidth limit the throughput. RDMA and GPUDirect exist to take the CPU out of the data path.
- **AI traffic patterns break traditional Ethernet assumptions.** A few very large, long-lived "elephant" flows with low entropy collide on ECMP hashes. Classic per-flow ECMP leaves some links saturated and others idle.
- **There are several networks, each with a different job.** Mixing storage, compute, tenant and management traffic on one fabric without isolation causes interference and security exposure.

For NCA-AIIO you are expected to **identify and describe** these protocols and concepts: what each one is, where it sits in the architecture, and why you would choose it. This material goes one level deeper (configuration and diagnostics) so the concepts stick.

---

## 2. The networks of an AI data center

NVIDIA reference architectures (DGX BasePOD / DGX SuperPOD) define **physically separate networks**, each with its own purpose:

| Network | Purpose | Typical technology (DGX B200 SuperPOD) | Traffic characteristics |
|---|---|---|---|
| **Compute (east-west) fabric** | GPU-to-GPU traffic between nodes (NCCL collectives, MPI) | NDR 400 Gb/s InfiniBand (Quantum-2 QM9700), or Spectrum-X Ethernet; 8 × ConnectX-7 per node, one per GPU | Very high bandwidth, latency-sensitive, bursty, synchronous |
| **Storage fabric** | High-performance parallel filesystem access (datasets, checkpoints) | 400 Gb/s Ethernet or InfiniBand; dual-port NICs / BlueField-3 DPUs on the node | High throughput, read-heavy during training, write bursts at checkpoint |
| **In-band management** | SSH, Kubernetes / Slurm control plane, container image pulls, DNS, NFS home directories | Ethernet (often converged with storage in the B200 RA) | Moderate, general-purpose TCP/IP |
| **Out-of-band (OOB) management** | BMC (Redfish/IPMI), switch management ports, PDUs | 1 GbE Ethernet (e.g., SN2201 switches) | Low bandwidth, must stay up when everything else is down |
| **NVLink domain** (intra-node or rack-scale) | GPU-to-GPU traffic *inside* the NVLink domain | NVLink 5 + NVSwitch (8 GPUs in DGX B200; 72 GPUs in GB200 NVL72) | Highest bandwidth, memory-semantic (load/store) |

**Key concept: one NIC per GPU.** In DGX H100/B200, every GPU pairs with its own 400 Gb/s ConnectX-7 port behind a shared PCIe switch. GPUDirect RDMA traffic then flows GPU → PCIe switch → NIC without crossing the CPU root complex or socket interconnect.

### 2.1 Physical layout of a DGX H100 / B200 (networking-relevant parts)

| Component | DGX H100 | DGX B200 |
|---|---|---|
| GPUs | 8 × H100 SXM | 8 × B200 |
| GPU-GPU interconnect | NVLink 4, 900 GB/s per GPU, via 4 × NVSwitch chips | NVLink 5, 1.8 TB/s per GPU, via 2 × NVSwitch chips |
| Compute fabric NICs | 8 × single-port ConnectX-7 (400 Gb/s InfiniBand/Ethernet), exposed through 4 × OSFP ports (2 × 400G per twin-port OSFP) | 8 × single-port ConnectX-7 400 Gb/s via OSFP |
| Storage / in-band NICs | 2 × dual-port ConnectX-7 (QSFP112) | 2 × dual-port BlueField-3 DPUs |
| Management | 10/25 GbE onboard + 1 GbE BMC (RJ45) | 10 GbE onboard + 1 GbE BMC (RJ45) |

---

## 3. Core protocols and concepts

### 3.1 RDMA (Remote Direct Memory Access)

RDMA lets a NIC read or write the memory of a remote host **without involving the remote CPU or OS kernel**. The application registers memory regions with the NIC (a Memory Region gets an `lkey`/`rkey`) and posts work requests to **Queue Pairs (QPs)**. The NIC hardware executes the transfer and signals completion through a **Completion Queue (CQ)**.

Properties:
- **Kernel bypass:** the data path goes from user space directly to the NIC (verbs API, `libibverbs`).
- **Zero copy:** no intermediate kernel buffers.
- **Transport offload:** segmentation, reliability and ordering run in NIC hardware.

Transport services: **RC** (Reliable Connected — what NCCL mainly uses), **UC**, **UD** (Unreliable Datagram, used by some management/MAD traffic), and **DC** (Dynamically Connected — reduces QP state at scale).

RDMA runs over three wire protocols:

| Protocol | Layering | Lossless requirement | Routable | Typical use |
|---|---|---|---|---|
| **InfiniBand** | Native IB link/network/transport | Built in (credit-based link-level flow control) | Within subnet via LID; between subnets via IB routers | DGX SuperPOD compute fabric, HPC |
| **RoCEv2** | IB transport over UDP/IP (UDP dst port **4791**) over Ethernet | Needs a "lossless-ish" fabric (PFC + ECN) or modern congestion control | Yes, L3 | Ethernet AI fabrics, Spectrum-X, storage |
| **RoCEv1** | IB transport directly over Ethernet (EtherType 0x8915) | Requires PFC | No (L2 only) | Legacy, avoid |
| **iWARP** | RDMA over TCP | No (TCP handles loss) | Yes | Rare in AI clusters |

### 3.2 InfiniBand

InfiniBand is a complete, purpose-built network architecture, not just a link layer:

- **Subnet Manager (SM):** a centralized control plane (OpenSM or the SM embedded in UFM or in a managed switch) that discovers the topology, assigns **LIDs** (Local Identifiers, 16-bit addresses), computes forwarding tables and programs every switch. One master SM per subnet, with standby SMs for HA.
- **Credit-based flow control:** a sender transmits only when the receiver has advertised buffer credits, so the link is **lossless by design**. No PFC tuning is needed.
- **Partitions (P_Keys):** the IB equivalent of VLANs, used for tenant isolation.
- **Adaptive Routing (AR):** switches choose among multiple equal-cost output ports per packet based on queue depth.
- **SHARP (Scalable Hierarchical Aggregation and Reduction Protocol):** Quantum switches perform reduction operations (sum, min, max) **inside the network**. Data for an AllReduce is aggregated as it climbs the fat tree, which roughly halves the data each endpoint has to send and receive and cuts the latency of large collectives. NCCL uses it through the `nccl-rdma-sharp-plugins` / CollNet path.
- **Speeds:** HDR = 200 Gb/s, **NDR = 400 Gb/s** (Quantum-2, ConnectX-7), XDR = 800 Gb/s (Quantum-X800, ConnectX-8).
- **UFM (Unified Fabric Manager):** NVIDIA's fabric management, telemetry and SM platform for large IB fabrics.

### 3.3 Ethernet for AI: RoCE, lossless tuning and Spectrum-X

Standard Ethernet drops packets when buffers fill. Dropped packets are catastrophic for RoCE RC traffic: older NICs fall back to go-back-N retransmission, and throughput collapses. Three mechanisms address this:

| Mechanism | Layer | What it does | Risk |
|---|---|---|---|
| **PFC** (Priority Flow Control, IEEE 802.1Qbb) | L2, per priority class | Switch sends PAUSE frames for a specific priority when the ingress buffer crosses a threshold | Head-of-line blocking, pause storms, PFC deadlocks |
| **ECN** (Explicit Congestion Notification, RFC 3168) | L3 IP header | Switch marks packets (CE bit) when queue depth exceeds a threshold instead of dropping them | Needs correct marking thresholds |
| **DCQCN** (Data Center Quantized Congestion Notification) | End-to-end | The receiver NIC sends CNPs (Congestion Notification Packets) back to the sender, which reduces its rate | Tuning-sensitive; reacts in microseconds, not nanoseconds |
| **ETS** (Enhanced Transmission Selection, 802.1Qaz) | L2 | Bandwidth allocation between traffic classes | — |
| **DSCP-based trust** | L3 | Classifies RoCE traffic by DSCP (commonly DSCP 26 → priority 3; CNP DSCP 48) | Inconsistent trust mode end-to-end breaks QoS |

**NVIDIA Spectrum-X** is an end-to-end Ethernet platform for AI: **Spectrum-4 switches (SN5600)** combined with **BlueField-3 SuperNICs** (or ConnectX-8 SuperNICs). It goes beyond "RoCE plus PFC":

- **Adaptive routing with per-packet load balancing:** the switch sprays packets of one flow across all available paths based on real-time congestion. This removes ECMP hash collisions for elephant flows.
- **Direct Data Placement at the SuperNIC:** packets arrive out of order because they took different paths. The SuperNIC writes each packet directly to its final memory location, so the application sees in-order semantics without a reorder buffer.
- **Telemetry-based congestion control:** switches feed in-band telemetry to the SuperNIC, which meters injection rate per flow. This gives **performance isolation** between tenants or jobs sharing the fabric.

### 3.4 InfiniBand vs. Ethernet (RoCE / Spectrum-X): trade-offs

| Dimension | InfiniBand (Quantum-2 / X800) | Traditional Ethernet + RoCEv2 | Spectrum-X Ethernet |
|---|---|---|---|
| Losslessness | Native credit-based | PFC + ECN tuning required | Congestion control plus AR, PFC optional as a backstop |
| Load balancing | Adaptive routing (per-packet) | Per-flow ECMP (hash collisions) | Per-packet AR with NIC-side reordering |
| In-network compute | **SHARP** | None | None (as of Spectrum-4) |
| Control plane | Centralized SM, deterministic | Distributed (BGP/OSPF), well understood | Distributed + NVIDIA tooling (NetQ, Cumulus/NVUE) |
| Multi-tenancy | P_Keys | VLAN/VXLAN/EVPN, VRFs — rich | VXLAN/EVPN + performance isolation |
| Ops skill pool | Specialized | Very broad | Broad Ethernet skills + AI tuning |
| Integration with existing DC | Gateway required | Native | Native |
| Typical use | Largest training clusters, DGX SuperPOD compute fabric | Inference, small clusters, storage | Multi-tenant AI clouds, Ethernet-first organizations |

**Exam heuristic:** IB = lowest latency, native lossless, SHARP, centralized SM. Spectrum-X = AI-optimized Ethernet with adaptive routing and congestion control, multi-tenant, standards-based.

### 3.5 NVLink and NVSwitch (scale-up)

**NVLink** is a direct GPU-to-GPU interconnect with **memory semantics**: GPUs can load/store and run atomics on each other's HBM. **NVSwitch** is a switch chip that connects all GPUs in a domain all-to-all at full NVLink bandwidth.

| Generation | GPU | Bandwidth per GPU (bidirectional) | Links per GPU |
|---|---|---|---|
| NVLink 3 | A100 | 600 GB/s | 12 |
| NVLink 4 | H100 | 900 GB/s | 18 |
| NVLink 5 | B200 / GB200 | 1.8 TB/s | 18 |

- **Scale-up vs. scale-out:** NVLink/NVSwitch is **scale-up** (inside the NVLink domain). InfiniBand/Ethernet is **scale-out** (between domains).
- **GB200 NVL72:** the NVLink Switch System extends the NVLink domain to **72 GPUs across a rack**, with 130 TB/s aggregate GPU bandwidth. The whole rack acts as one large GPU for tensor-parallel and expert-parallel workloads.
- **Comparison:** PCIe Gen5 x16 ≈ 128 GB/s bidirectional. NVLink 5 is roughly 14× that.
- **Fabric Manager:** on NVSwitch-based systems, the `nvidia-fabricmanager` service must run so that NVSwitch routing is configured. If it is missing, CUDA apps fail to initialize multi-GPU and `nvidia-smi -q` shows fabric state errors.

### 3.6 GPUDirect family

| Technology | Data path | Requirement |
|---|---|---|
| **GPUDirect P2P** | GPU ↔ GPU in the same node (NVLink or PCIe) | Same PCIe root / NVLink |
| **GPUDirect RDMA** | NIC ↔ GPU memory directly, bypassing host memory | `nvidia-peermem` kernel module or DMA-BUF (open kernel driver), plus a NIC under the same PCIe switch for best performance |
| **GPUDirect Storage (GDS)** | NVMe / NVMe-oF / parallel FS ↔ GPU memory directly | `nvidia-fs` module, `cuFile` API, supported filesystem |
| **GPUDirect Async** | GPU triggers network operations itself | Recent NCCL/NVSHMEM |

Without GPUDirect RDMA, data takes the path GPU → host memory (bounce buffer) → NIC. That path consumes CPU memory bandwidth and adds latency.

### 3.7 DPUs and SuperNICs: BlueField

A **DPU (Data Processing Unit)** such as **BlueField-3** combines a ConnectX-7-class NIC, Arm cores (16 × Cortex-A78), and hardware accelerators (crypto, regex, compression, storage emulation). It runs its own OS and is programmed with **NVIDIA DOCA**.

Why it matters in production:
- **Offload:** OVS / virtual switching (ASAP² hardware offload), IPsec/TLS, NVMe-oF initiator (SNAP emulates NVMe devices to the host), firewalling. This returns host CPU cycles to the workload.
- **Isolation:** infrastructure services run on the DPU, outside the host's trust domain. A compromised tenant host cannot reconfigure the network policy enforced on the DPU. This is the **zero-trust / bare-metal cloud** model.
- **Acceleration:** line-rate encryption and storage protocol processing.

**DPU vs. SuperNIC vs. NIC:**

| Device | Role | Example |
|---|---|---|
| NIC / SmartNIC | Fast I/O with fixed-function offloads (RDMA, checksum, RSS) | ConnectX-7 |
| SuperNIC | East-west AI fabric NIC optimized for Spectrum-X (packet reordering, congestion control), lower power | BlueField-3 SuperNIC, ConnectX-8 SuperNIC |
| DPU | North-south and infrastructure offload + isolation, runs software (DOCA) | BlueField-3 DPU (storage/in-band ports in DGX B200) |

### 3.8 Topology concepts

- **Fat tree / Clos (leaf-spine):** multi-stage, non-blocking when uplink bandwidth equals downlink bandwidth (1:1 subscription). AI compute fabrics are designed **non-blocking**. Storage and in-band networks may be oversubscribed.
- **Rail-optimized topology:** GPU *n* of every node connects to leaf switch ("rail") *n*. Same-index GPUs across nodes reach each other in one switch hop. NCCL's ring/tree algorithms align with rails, and cross-rail traffic goes over NVLink inside the node (NCCL "PXN").
- **Scalable Unit (SU):** the DGX SuperPOD building block, **32 DGX B200 systems** per SU in the B200 reference architecture, with eight rail leaf switches per SU and spine switches connecting SUs.
- **Oversubscription ratio:** downlink bandwidth divided by uplink bandwidth at a tier. 1:1 for compute, often 2:1 to 4:1 elsewhere.
- **MTU:** IB uses a 4096-byte MTU. RoCE fabrics typically use 9000-byte jumbo frames on interfaces, which gives a RoCE MTU of 4096. A mismatched MTU anywhere on the path causes silent drops or poor performance.

---

## 4. Kubernetes configuration: exposing RDMA and GPUDirect to workloads

In Kubernetes clusters (including DGX systems running Kubernetes), the **NVIDIA Network Operator** deploys the networking stack: DOCA-OFED driver container, RDMA device plugins, SR-IOV, Multus, and IPAM. The **GPU Operator** deploys `nvidia-peermem` for GPUDirect RDMA. The manifests below are complete examples. Version tags are illustrative, so pin the ones from the Network Operator release notes that match your cluster.

### 4.1 NicClusterPolicy (Network Operator)

```yaml
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  ofedDriver:
    image: doca-driver
    repository: nvcr.io/nvidia/mellanox
    version: 25.01-0.6.0.0-0
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
        podSelector: ""
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
    multus:
      image: multus-cni
      repository: ghcr.io/k8snetworkplumbingwg
      version: v4.1.0
    cniPlugins:
      image: plugins
      repository: ghcr.io/k8snetworkplumbingwg
      version: v1.5.0
    ipamPlugin:
      image: whereabouts
      repository: ghcr.io/k8snetworkplumbingwg
      version: v0.7.0
```

Notes:
- Vendor `15b3` is NVIDIA/Mellanox. Device ID `1021` is ConnectX-7.
- The `config` value is a JSON string inside a YAML block scalar. That is valid YAML, and the device plugin parses the JSON.
- The shared device plugin exposes **one shared RDMA resource** that many pods can use. For strict per-pod VF isolation, use SR-IOV (next section).

### 4.2 SR-IOV for per-pod isolation (InfiniBand VFs)

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: ib-rail-0
  namespace: nvidia-network-operator
spec:
  resourceName: ib_rail0
  nodeSelector:
    feature.node.kubernetes.io/network-sriov.capable: "true"
  priority: 90
  numVfs: 8
  nicSelector:
    vendor: "15b3"
    pfNames:
      - "ibp24s0"
  linkType: ib
  isRdma: true
  deviceType: netdevice
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovIBNetwork
metadata:
  name: ib-rail-0-net
  namespace: nvidia-network-operator
spec:
  resourceName: ib_rail0
  networkNamespace: ml-training
  linkState: enable
  capabilities: '{ "infinibandGUID": true }'
  ipam: |
    {
      "type": "whereabouts",
      "range": "192.168.100.0/24"
    }
```

In a rail-optimized cluster you create one policy and one network per rail (`ib_rail0` … `ib_rail7`). Each pod then gets one VF per GPU, all on the same PCIe switch as its GPU.

### 4.3 RoCE secondary network (Ethernet fabric)

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: roce-rail-0
  namespace: ml-training
  annotations:
    k8s.v1.cni.cncf.io/resourceName: rdma/rdma_shared_device_a
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "roce-rail-0",
      "type": "macvlan",
      "master": "ens1f0np0",
      "mode": "bridge",
      "mtu": 9000,
      "ipam": {
        "type": "whereabouts",
        "range": "10.10.0.0/16",
        "exclude": ["10.10.0.0/24"]
      }
    }
```

### 4.4 Training pod using GPUs + RDMA + GPUDirect

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nccl-allreduce-worker-0
  namespace: ml-training
  annotations:
    k8s.v1.cni.cncf.io/networks: "roce-rail-0"
spec:
  restartPolicy: Never
  containers:
    - name: nccl-test
      image: nvcr.io/nvidia/pytorch:24.10-py3
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
      env:
        - name: NCCL_DEBUG
          value: "INFO"
        - name: NCCL_IB_HCA
          value: "mlx5"
        - name: NCCL_IB_GID_INDEX
          value: "3"
        - name: NCCL_SOCKET_IFNAME
          value: "net1"
        - name: NCCL_NET_GDR_LEVEL
          value: "PHB"
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

Key points:
- `IPC_LOCK` lets the process pin (register) memory for RDMA. Without it, `ibv_reg_mr` fails.
- `NCCL_IB_GID_INDEX=3` selects the RoCEv2 IPv4 GID on many systems. Verify it with `show_gids` and do not assume it. On native InfiniBand, leave it unset.
- A large `/dev/shm` is needed for NCCL intra-node transport.

### 4.5 Enabling GPUDirect RDMA in the GPU Operator (Helm values)

```yaml
driver:
  enabled: true
  rdma:
    enabled: true
    useHostMofed: false
toolkit:
  enabled: true
devicePlugin:
  enabled: true
dcgmExporter:
  enabled: true
gds:
  enabled: false
```

```
$ helm upgrade --install gpu-operator nvidia/gpu-operator \
    -n gpu-operator --create-namespace -f gpu-operator-values.yaml
```

`driver.rdma.enabled: true` deploys the `nvidia-peermem` module. Use `useHostMofed: true` only if DOCA-OFED is installed on the host instead of by the Network Operator. Set `gds.enabled: true` to deploy `nvidia-fs` for GPUDirect Storage.

---

## 5. CLI: inspecting the fabric

### 5.1 GPU ↔ NIC topology (`nvidia-smi topo -m`)

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  NIC2  NIC3  NIC4  NIC5  NIC6  NIC7  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PIX   SYS   SYS   SYS   SYS   SYS   SYS   SYS   0-55          0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   PIX   SYS   SYS   SYS   SYS   SYS   SYS   0-55          0
GPU2    NV18  NV18   X    NV18  NV18  NV18  NV18  NV18  SYS   SYS   PIX   SYS   SYS   SYS   SYS   SYS   0-55          0
GPU3    NV18  NV18  NV18   X    NV18  NV18  NV18  NV18  SYS   SYS   SYS   PIX   SYS   SYS   SYS   SYS   0-55          0
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   SYS   SYS   SYS   PIX   SYS   SYS   SYS   56-111        1
GPU5    NV18  NV18  NV18  NV18  NV18   X    NV18  NV18  SYS   SYS   SYS   SYS   SYS   PIX   SYS   SYS   56-111        1
GPU6    NV18  NV18  NV18  NV18  NV18  NV18   X    NV18  SYS   SYS   SYS   SYS   SYS   SYS   PIX   SYS   56-111        1
GPU7    NV18  NV18  NV18  NV18  NV18  NV18  NV18   X    SYS   SYS   SYS   SYS   SYS   SYS   SYS   PIX   56-111        1

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks

NIC Legend:
  NIC0: mlx5_0
  NIC1: mlx5_3
  ...
```

How to read it: `NV18` means 18 bonded NVLinks between every GPU pair, through NVSwitch. `PIX` between GPUn and NICn is the ideal GPUDirect RDMA path. If a GPU's nearest NIC shows `SYS`, RDMA traffic crosses the CPU socket interconnect, so expect degraded bandwidth.

### 5.2 NVLink status

```
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1c...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s

$ systemctl is-active nvidia-fabricmanager
active

$ nvidia-smi -q | grep -A3 -i fabric
    Fabric
        State                             : Completed
        Status                            : Success
```

18 links × ~26.5 GB/s ≈ 477 GB/s per direction, about 900 GB/s bidirectional. A link reported as `inactive` points to a hardware or NVSwitch issue.

### 5.3 NIC to netdev mapping and port state

```
$ ibdev2netdev
mlx5_0 port 1 ==> ibp24s0 (Up)
mlx5_1 port 1 ==> ens6f0np0 (Up)
mlx5_2 port 1 ==> ens6f1np1 (Up)
mlx5_3 port 1 ==> ibp64s0 (Up)
...

$ ibstat mlx5_0
CA 'mlx5_0'
        CA type: MT4129
        Number of ports: 1
        Firmware version: 28.42.1000
        Hardware version: 0
        Node GUID: 0xa088c20300f1b2c4
        System image GUID: 0xa088c20300f1b2c4
        Port 1:
                State: Active
                Physical state: LinkUp
                Rate: 400
                Base lid: 112
                LMC: 0
                SM lid: 1
                Capability mask: 0xa751e848
                Port GUID: 0xa088c20300f1b2c4
                Link layer: InfiniBand
```

Check these fields: `State: Active` (not `Initializing`, which means **no Subnet Manager** has configured the port), `Rate: 400` (NDR), and `Link layer` (`InfiniBand` vs. `Ethernet` tells you whether this is IB or RoCE).

```
$ ibv_devinfo -d mlx5_1 | egrep 'hca_id|state|active_mtu|link_layer'
hca_id: mlx5_1
                        state:                  PORT_ACTIVE (4)
                        active_mtu:             4096 (5)
                        link_layer:             Ethernet
```

### 5.4 Subnet Manager and fabric discovery (InfiniBand)

```
$ sminfo
sminfo: sm lid 1 sm guid 0xfc6a1c0300a1b200, activity count 482113 priority 15 state 3 SMINFO_MASTER

$ iblinkinfo --switches-only | head -5
Switch: 0xfc6a1c0300a1b200 QM9700 leaf-su1-rail0:
          1    1[  ] ==( 4X      106.25 Gbps Active/  LinkUp)==>     112    1[  ] "dgx-b200-001 mlx5_0" ( )
          1    2[  ] ==( 4X      106.25 Gbps Active/  LinkUp)==>     118    1[  ] "dgx-b200-002 mlx5_0" ( )
...

$ ibdiagnet --pc -o /tmp/ibdiag
...
-I- Links Check finished successfully
-I- Speed / Width checks finished successfully
-E- PM Counters Check finished with errors
-E-   lid=0x0076 dev=4129 dgx-b200-002/U1/P1  Performance Monitor counter : symbol_error_counter = 1873
```

`iblinkinfo` shows lane speed per link: 106.25 Gb/s per lane × 4 lanes ≈ 400 Gb/s NDR. `ibdiagnet` is the standard full-fabric health check. A growing `symbol_error_counter` or `link_downed_counter` points to a bad cable or transceiver.

### 5.5 RoCE QoS and GIDs (Ethernet)

```
$ show_gids mlx5_1
DEV     PORT    INDEX   GID                                     IPv4            VER     DEV
---     ----    -----   ---                                     ------------    ---     ---
mlx5_1  1       0       fe80:0000:0000:0000:a288:c2ff:fe11:2233                 v1      ens6f0np0
mlx5_1  1       1       fe80:0000:0000:0000:a288:c2ff:fe11:2233                 v2      ens6f0np0
mlx5_1  1       2       0000:0000:0000:0000:0000:ffff:0a0a:0105 10.10.1.5       v1      ens6f0np0
mlx5_1  1       3       0000:0000:0000:0000:0000:ffff:0a0a:0105 10.10.1.5       v2      ens6f0np0

$ mlnx_qos -i ens6f0np0 --trust dscp --pfc 0,0,0,1,0,0,0,0
DCBX mode: OS controlled
Priority trust state: dscp
PFC configuration:
        priority    0   1   2   3   4   5   6   7
        enabled     0   0   0   1   0   0   0   0
...

$ ethtool -S ens6f0np0 | egrep 'rx_prio3_pause|tx_prio3_pause|np_cnp_sent|rp_cnp_handled|out_of_buffer'
     rx_prio3_pause: 0
     tx_prio3_pause: 0
     rp_cnp_handled: 1024
     np_cnp_sent: 980
     rx_out_of_buffer: 0
```

How to interpret: index 3 (RoCE **v2**, IPv4) is the GID to give NCCL. PFC is enabled only on priority 3, the RoCE class. CNP counters show that DCQCN is reacting to congestion, which is normal under load. Pause counters that grow fast or `rx_out_of_buffer` mean a buffer/PFC/ECN misconfiguration.

### 5.6 Performance validation

```
# Server (node A), using GPU memory for the buffer (GPUDirect RDMA)
$ ib_write_bw -d mlx5_0 --use_cuda=0 -F --report_gbits -s 1048576 -q 4

# Client (node B)
$ ib_write_bw -d mlx5_0 --use_cuda=0 -F --report_gbits -s 1048576 -q 4 10.0.0.11
---------------------------------------------------------------------------------------
                    RDMA_Write BW Test
 Dual-port       : OFF          Device         : mlx5_0
 Number of qps   : 4            Transport type : IB
 Connection type : RC           Using SRQ      : OFF
 Mtu             : 4096[B]
 Link type       : IB
---------------------------------------------------------------------------------------
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 1048576    5000             392.15             391.88               0.046718
---------------------------------------------------------------------------------------
```

About 392 Gb/s on a 400 Gb/s NDR link is line rate after protocol overhead.

```
$ lsmod | egrep 'nvidia_peermem|nvidia_fs'
nvidia_peermem         16384  0
nvidia_fs             262144  0

$ mpirun -np 16 -H dgx01:8,dgx02:8 -x NCCL_DEBUG=INFO \
    ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 1
...
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_3:1/IB ... ; OOB ibp24s0:10.0.0.11<0>
NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
...
#       size    count   type   redop   root     time   algbw   busbw  #wrong
  8589934592  2147483648  float  sum     -1    48120  178.51  334.71       0
# Avg bus bandwidth    : 312.4
```

Look for `GDRDMA` in the NCCL log (GPUDirect RDMA active) and `NET/IB` (RDMA transport, not `NET/Socket`). For two 8-GPU H100/B200 nodes on NDR with one NIC per GPU, an all_reduce `busbw` in the high 300s GB/s is in the expected range. A tens-of-GB/s result points to a broken path.

---

## 6. Diagnostics: symptom → cause → fix

| Symptom | Likely cause | Verify with | Fix |
|---|---|---|---|
| IB port stuck in `Initializing` | No master Subnet Manager reachable | `ibstat` (State), `sminfo` | Start OpenSM/UFM SM, check SM HA |
| NCCL log shows `NET/Socket` instead of `NET/IB` | RDMA device not visible in container, missing `IPC_LOCK`, wrong `NCCL_IB_HCA` | `ibv_devices` inside pod, pod spec | Request the RDMA resource, add `IPC_LOCK`, fix env vars |
| NCCL uses IB but no `GDRDMA` | `nvidia-peermem` not loaded, or GPU/NIC topology is `SYS` | `lsmod`, `nvidia-smi topo -m` | Enable `driver.rdma` in GPU Operator, use NIC affinity |
| All-reduce `busbw` far below expected on one node only | Downgraded link (rate 200 vs. 400, width 2X), bad cable | `ibstat`, `iblinkinfo`, `ibdiagnet --pc` | Reseat or replace cable/transceiver |
| RoCE throughput collapses under load, pause counters grow | PFC storm / missing ECN marking / inconsistent DSCP trust | `ethtool -S` pause and CNP counters, switch QoS config | Align trust DSCP end-to-end, enable ECN, PFC only on the RoCE priority |
| RoCE connection fails, IB works | Wrong GID index (v1 vs. v2), wrong subnet | `show_gids` | Set `NCCL_IB_GID_INDEX` to the RoCEv2 GID |
| Jobs hang at start on multi-GPU node | `nvidia-fabricmanager` not running (NVSwitch not configured) | `systemctl status nvidia-fabricmanager`, `nvidia-smi -q` Fabric State | Start the service, match driver and Fabric Manager versions |
| Silent drops for large messages | MTU mismatch along the path | `ibv_devinfo` active_mtu, `ip link`, switch MTU | Jumbo frames end-to-end (9000+ on Ethernet) |
| Uneven link utilization on Ethernet spine | ECMP hash collision of elephant flows | Switch interface counters | Spectrum-X adaptive routing, or more QPs (`NCCL_IB_QPS_PER_CONNECTION`) for entropy |
| Storage reads slow, compute fine | Storage fabric oversubscribed or GDS inactive | `gdscheck -p`, storage NIC counters | Enable GDS, re-check storage network design |

**Diagnostic method (outside-in):**
1. **Physical:** link state, speed and width on every port (`ibstat`, `ethtool`, `iblinkinfo`).
2. **Control plane:** SM master present (IB), or routing/BGP up and QoS consistent (Ethernet).
3. **Error counters:** symbol errors, link-downed, pause frames, out-of-buffer.
4. **Point-to-point performance:** `ib_write_bw` with and without `--use_cuda`.
5. **Collective performance:** `nccl-tests` across 2 nodes, then a full SU, comparing `busbw` to the baseline.
6. **Application:** NCCL debug log (transport and GDR choice), DCGM metrics (`DCGM_FI_PROF_NVLINK_TX_BYTES`, `DCGM_FI_PROF_PCIE_RX_BYTES`).

---

## 7. Key concepts summary (exam review)

- **RDMA:** kernel bypass, zero copy, transport offload. It runs over **InfiniBand**, **RoCEv2** (UDP 4791) or iWARP.
- **InfiniBand:** native lossless (credit-based), **Subnet Manager** + LIDs, P_Keys, adaptive routing, **SHARP** in-network reduction, NDR 400 Gb/s / XDR 800 Gb/s, managed with **UFM**.
- **RoCE on Ethernet:** needs **PFC + ECN + DCQCN** (or Spectrum-X congestion control). DSCP trust must be consistent.
- **Spectrum-X:** Spectrum-4 switch + BlueField-3/ConnectX-8 SuperNIC. Per-packet adaptive routing, NIC-side data placement for out-of-order packets, telemetry-based congestion control, performance isolation.
- **NVLink/NVSwitch:** scale-up, memory semantics. 900 GB/s (H100), 1.8 TB/s (B200) per GPU. NVL72 = 72-GPU NVLink domain. Needs Fabric Manager on NVSwitch systems.
- **GPUDirect RDMA / Storage:** NIC or storage ↔ GPU memory without host bounce buffers (`nvidia-peermem`, `nvidia-fs`/cuFile).
- **BlueField DPU:** offloads networking, storage and security from the host CPU and isolates infrastructure from tenant workloads. Programmed with DOCA.
- **Separate networks:** compute, storage, in-band, out-of-band (BMC), plus the NVLink domain.
- **Topology:** non-blocking fat tree (Clos), **rail-optimized** (GPU *n* → leaf *n*), Scalable Units (32 DGX B200 per SU).

---

## Referencias

- NVIDIA NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA DGX SuperPOD Reference Architecture, DGX B200: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide, component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes/latest/index.html
- NVIDIA GPU Operator, GPUDirect RDMA and GPUDirect Storage: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-rdma.html
- NVIDIA Spectrum-X Ethernet platform: https://www.nvidia.com/en-us/networking/spectrumx/
- NCCL environment variables: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html
- NVIDIA Fabric Manager user guide: https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html