# Guided Exercises — Topic 2.7: Determine Networking Requirements for AI Workloads

**Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Exam weight:** 4.0

> **How to use these exercises.** Each exercise has numbered steps. Some are calculations or design decisions you can do on paper. Others are commands to run on a GPU node with NVIDIA ConnectX/BlueField adapters. If you have no hardware, read the **representative output** and work from it. Device names, firmware versions, and exact numbers will differ on your system. Answer the questions after each block before you open the answer key at the end.

**Official references used throughout:**

- NVIDIA DGX H100 User Guide, component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA NVLink and NVLink Switch: https://www.nvidia.com/en-us/data-center/nvlink/
- Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727

---

## Exercise 1 — Classify AI traffic and map it to the right network

An AI data center does not run on one network. The DGX SuperPOD reference architecture separates traffic into physically distinct fabrics, because each traffic class has different requirements for bandwidth, latency, loss tolerance, and security:

| Fabric | Typical technology | Carries |
|---|---|---|
| **Compute (east-west) fabric** | InfiniBand NDR 400 Gb/s (Quantum-2) or Spectrum-X Ethernet (RoCE) | GPU-to-GPU collective traffic between nodes (NCCL AllReduce, AllGather, ReduceScatter, all-to-all) |
| **Storage fabric** | InfiniBand or high-speed Ethernet | Dataset reads, checkpoint writes, parallel file system traffic |
| **In-band management** | Ethernet | SSH, Slurm/Kubernetes control plane, container image pulls, monitoring, user access |
| **Out-of-band (OOB) management** | 1 GbE Ethernet | BMC/IPMI/Redfish, switch management ports, PDUs |

Inside a node there is also the **NVLink/NVSwitch** domain, which carries GPU-to-GPU traffic without touching any NIC.

### Steps

1. For each of the following flows, write down which network or interconnect carries it:
   a. A PyTorch DDP job on 64 nodes runs a gradient AllReduce at the end of each step.
   b. A tensor-parallel layer splits a matrix multiply across the 8 GPUs of one DGX H100.
   c. The training job writes a 2 TB checkpoint every 30 minutes.
   d. An operator power-cycles a hung node through its BMC with Redfish.
   e. `docker pull nvcr.io/nvidia/pytorch:24.10-py3` runs on a compute node.
   f. An inference client sends HTTP requests to a Triton/NIM endpoint.
2. For each flow, mark whether it is **east-west** (server-to-server inside the cluster) or **north-south** (into or out of the cluster).

### Questions

- **Q1.1** Why does the reference architecture keep the storage fabric separate from the compute fabric, even when both could run on InfiniBand?
- **Q1.2** Why does the OOB network have to stay up and reachable when the in-band network is down?
- **Q1.3** Which workload type is dominated by east-west traffic, and which by north-south: large-scale training or online inference?

---

## Exercise 2 — Read the internal topology of a DGX node

GPUDirect RDMA lets a NIC read and write GPU memory directly, with no bounce buffer in host memory. It works best when the GPU and its NIC share a PCIe switch. `nvidia-smi topo -m` shows that affinity.

### Steps

1. On a GPU node, run:

   ```bash
   nvidia-smi topo -m
   ```

   Representative output (DGX H100-class system, trimmed to 4 GPUs and 4 NICs for readability):

   ```
           GPU0  GPU1  GPU2  GPU3  NIC0  NIC1  NIC2  NIC3  CPU Affinity  NUMA Affinity
   GPU0     X    NV18  NV18  NV18  PXB   NODE  NODE  NODE  0-55,112-167  0
   GPU1    NV18   X    NV18  NV18  NODE  PXB   NODE  NODE  0-55,112-167  0
   GPU2    NV18  NV18   X    NV18  NODE  NODE  PXB   NODE  0-55,112-167  0
   GPU3    NV18  NV18  NV18   X    NODE  NODE  NODE  PXB   0-55,112-167  0
   NIC0    PXB   NODE  NODE  NODE   X    NODE  NODE  NODE
   NIC1    NODE  PXB   NODE  NODE  NODE   X    NODE  NODE
   NIC2    NODE  NODE  PXB   NODE  NODE  NODE   X    NODE
   NIC3    NODE  NODE  NODE  PXB   NODE  NODE  NODE   X

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
     NIC1: mlx5_1
     NIC2: mlx5_2
     NIC3: mlx5_3
   ```

2. Build a table that pairs each GPU with its "closest" NIC.
3. Map the NIC names to RDMA devices and network interfaces:

   ```bash
   ibdev2netdev
   ```

   Representative output:

   ```
   mlx5_0 port 1 ==> ibp24s0 (Up)
   mlx5_1 port 1 ==> ibp64s0 (Up)
   mlx5_2 port 1 ==> ibp79s0 (Up)
   mlx5_3 port 1 ==> ibp94s0 (Up)
   ```

### Questions

- **Q2.1** What does `NV18` between two GPUs tell you about the NVLink generation and per-GPU bandwidth on this system?
- **Q2.2** GPU0 shows `PXB` to NIC0 and `NODE` to NIC1. Which NIC should NCCL use for GPU0's inter-node traffic, and why?
- **Q2.3** What would `SYS` between a GPU and the NIC it uses mean for GPUDirect RDMA performance?
- **Q2.4** According to the DGX H100 user guide, how many ConnectX-7 ports does the system dedicate to the compute fabric, and at what speed?

---

## Exercise 3 — Quantify NVLink versus PCIe

### Steps

1. Check NVLink link state and speed for GPU 0:

   ```bash
   nvidia-smi nvlink -s -i 0
   ```

   Representative output (H100 SXM):

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
        Link 0: 26.562 GB/s
        Link 1: 26.562 GB/s
        ...
        Link 17: 26.562 GB/s
   ```

   > The tool reports per-link, per-direction signalling. The commonly quoted figure is **50 GB/s bidirectional per link**. Use NVIDIA's published aggregate numbers for design work.

2. Fill in the table using the NVLink page (https://www.nvidia.com/en-us/data-center/nvlink/):

   | Interconnect | Links per GPU | Total bidirectional bandwidth per GPU |
   |---|---|---|
   | NVLink 4 (Hopper, H100) | 18 | ? |
   | NVLink 5 (Blackwell, B200) | 18 | ? |
   | PCIe Gen5 x16 | — | ~128 GB/s (≈64 GB/s each direction) |
   | One ConnectX-7 NDR port | — | 400 Gb/s per direction = ? GB/s |

3. Compute the ratios: NVLink 4 per GPU ÷ PCIe Gen5 x16, and NVLink 4 per GPU ÷ one NDR port (per direction).

### Questions

- **Q3.1** Why do parallelism strategies with very heavy communication (tensor parallelism) usually stay inside the NVLink domain, while data parallelism crosses the network fabric?
- **Q3.2** What does the NVLink Switch System (for example, GB200 NVL72) change about the size of the NVLink domain, and why does that matter for network design?
- **Q3.3** How many NVSwitch chips does a DGX H100 have, and what does NVSwitch provide that point-to-point NVLink alone does not?

---

## Exercise 4 — Verify the compute fabric ports on a node

### Steps

1. List adapter and port state:

   ```bash
   ibstat mlx5_0
   ```

   Representative output:

   ```
   CA 'mlx5_0'
   	CA type: MT4129
   	Number of ports: 1
   	Firmware version: 28.39.1002
   	Hardware version: 0
   	Node GUID: 0x946dae0300a1b2c4
   	System image GUID: 0x946dae0300a1b2c4
   	Port 1:
   		State: Active
   		Physical state: LinkUp
   		Rate: 400
   		Base lid: 112
   		LMC: 0
   		SM lid: 1
   		Capability mask: 0xa651e848
   		Port GUID: 0x946dae0300a1b2c4
   		Link layer: InfiniBand
   ```

2. Check the detailed device view:

   ```bash
   ibv_devinfo -d mlx5_0 | grep -E 'hca_id|state|active_mtu|link_layer'
   ```

   ```
   hca_id:	mlx5_0
   		state:			PORT_ACTIVE (4)
   		active_mtu:		4096 (5)
   		link_layer:		InfiniBand
   ```

3. Now look at a second, misbehaving port:

   ```
   CA 'mlx5_5'
   	Port 1:
   		State: Initializing
   		Physical state: LinkUp
   		Rate: 400
   		Base lid: 65535
   		SM lid: 0
   		Link layer: InfiniBand
   ```

4. Check the physical layer and error counters of a port with `mlxlink` (MFT package):

   ```bash
   sudo mlxlink -d mlx5_0 -m -c
   ```

   Look at `Effective Physical Errors`, `Raw Physical BER`, and `Link Down Counter`.

### Questions

- **Q4.1** `CA type: MT4129`: which adapter family is this, and what is the maximum rate shown?
- **Q4.2** `mlx5_5` has physical link up but logical state `Initializing`, `Base lid: 65535`, and `SM lid: 0`. What is missing in the fabric?
- **Q4.3** What component plays that role in a DGX SuperPOD with InfiniBand, and where does it usually run?
- **Q4.4** If `Link layer` read `Ethernet`, which protocol would RDMA use, and what would you need from the switch fabric that InfiniBand provides natively?

---

## Exercise 5 — Size a rail-optimized compute fabric

In a **rail-optimized** design, the compute NIC attached to GPU *i* on every node connects to the same leaf switch (rail *i*). Traffic between same-index GPUs on different nodes crosses one switch. NCCL uses features such as PXN (PCIe × NVLink) to first move data over NVLink to the GPU on the right rail, then send it out on that rail.

Assumptions for this exercise (a simplified version of the SuperPOD B200 reference architecture building block; check the RA for the real bill of materials):

- 1 Scalable Unit (SU) = **32 DGX B200 nodes**
- Each node: **8 × 400 Gb/s** ConnectX-7 compute ports (one per GPU)
- Switch: **NVIDIA Quantum-2 QM9700**, **64 × NDR 400 Gb/s ports** (32 OSFP cages)
- Non-blocking fabric (1:1): every leaf uses half its ports down and half up

### Steps

1. Compute the aggregate compute-fabric bandwidth of one node in Tb/s and GB/s (per direction).
2. Compute the total node-facing ports in one SU.
3. Compute the number of leaf switches. Assign them to rails.
4. Compute the number of uplink ports from the leaves, and the number of 64-port spine switches needed to keep the fabric non-blocking.
5. Repeat step 4 for an oversubscribed 2:1 design (each leaf: 32 down... keep 32 down and only 16 up).

### Questions

- **Q5.1** Why is the AI compute fabric typically designed non-blocking (1:1), while a traditional enterprise data center often accepts 3:1 or higher oversubscription?
- **Q5.2** In a ring or tree AllReduce, what determines the step time: the average link or the slowest link? What does that mean for oversubscription and for a single flapping cable?
- **Q5.3** What is the purpose of the "rail" grouping? What happens to traffic between GPU 3 on node A and GPU 5 on node B?
- **Q5.4** Quantum-2 switches support SHARP. What does SHARP do to AllReduce traffic volume on the fabric?

---

## Exercise 6 — Measure: raw RDMA, then collective bandwidth

### Steps

1. **Raw RDMA bandwidth between two nodes**, host memory (perftest package). On node A (server):

   ```bash
   ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -D 10
   ```

   On node B (client):

   ```bash
   ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -D 10 nodeA
   ```

   Representative client output (trimmed):

   ```
    #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
    1048576    466452           0.00               391.34               0.046648
   ```

2. **Repeat with GPU memory** (perftest built with CUDA support) to exercise GPUDirect RDMA:

   ```bash
   ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -D 10 --use_cuda=0 nodeA
   ```

3. **Collective bandwidth inside one node** (nccl-tests):

   ```bash
   ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 8
   ```

   Representative tail of the output:

   ```
   #       size         count      type   redop    root     time   algbw   busbw  #wrong
   #        (B)    (elements)                               (us)  (GB/s)  (GB/s)
     4294967296    1073741824     float     sum      -1    17520  245.15  429.01      0
     8589934592    2147483648     float     sum      -1    34830  246.63  431.60      0
   # Avg bus bandwidth    : 149.82
   ```

4. **Collective bandwidth across 2 nodes** (16 GPUs), with NCCL logging:

   ```bash
   mpirun -np 16 -H nodeA:8,nodeB:8 \
     -x NCCL_DEBUG=INFO \
     -x NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7 \
     ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 1
   ```

5. Compute the theoretical upper bound for inter-node busbw per node: 8 NICs × 400 Gb/s.

### Questions

- **Q6.1** nccl-tests reports `algbw` and `busbw`. For AllReduce, busbw = algbw × 2(n−1)/n. Using the 8 GB row (n = 8), check that 246.63 × 2 × 7/8 ≈ 431.6. Why is busbw the number you compare against hardware link speeds?
- **Q6.2** The single-node busbw (~430 GB/s) is far above the PCIe Gen5 limit. Which interconnect produced it?
- **Q6.3** What is the theoretical inter-node ceiling from step 5, in GB/s? If the 2-node run reports ~95 GB/s busbw at large message sizes, list two likely causes.
- **Q6.4** The `# Avg bus bandwidth` (149.82 GB/s) is much lower than the large-message rows. Why?

---

## Exercise 7 — Choose InfiniBand or Ethernet (RoCE / Spectrum-X)

### Steps

1. Read the scenarios and choose a compute fabric: **InfiniBand (Quantum-2)**, **Spectrum-X Ethernet (Spectrum-4 + BlueField-3 SuperNIC)**, or **standard TCP Ethernet**.
   a. A 1,000-GPU dedicated training cluster. The team wants the lowest latency, in-network reductions, and the reference architecture DGX SuperPOD design.
   b. A cloud provider building a multi-tenant AI cloud. The operations team runs Ethernet and wants AI-tuned performance with Ethernet tooling and multi-tenancy.
   c. A 4-node inference cluster serving a 7B model, one model replica per GPU, no cross-node communication.
2. For a RoCEv2 deployment, list the switch/NIC settings needed for good RDMA performance. Use these terms: **PFC**, **ECN**, **DCQCN**, **DSCP**, **UDP 4791**, **MTU**.
3. Verify RoCE-related settings on a NIC (only on Ethernet-mode ports):

   ```bash
   show_gids mlx5_0
   ```

   Representative output:

   ```
   DEV     PORT    INDEX   GID                                     IPv4            VER     DEV
   ---     ----    -----   ---                                     ------------    ---     ---
   mlx5_0  1       0       fe80:0000:0000:0000:a288:c2ff:fe11:2233                 v1      ens1f0np0
   mlx5_0  1       1       fe80:0000:0000:0000:a288:c2ff:fe11:2233                 v2      ens1f0np0
   mlx5_0  1       2       0000:0000:0000:0000:0000:ffff:c0a8:6401 192.168.100.1   v1      ens1f0np0
   mlx5_0  1       3       0000:0000:0000:0000:0000:ffff:c0a8:6401 192.168.100.1   v2      ens1f0np0
   ```

### Questions

- **Q7.1** InfiniBand is lossless by design. What mechanism provides that, and what is the Ethernet equivalent RoCE relies on?
- **Q7.2** Which GID index from the output would you use for routable RoCEv2 over IPv4, and how would you tell NCCL to use it?
- **Q7.3** What does Spectrum-X add on top of "plain" RoCE to make Ethernet suitable for large-scale AI training?
- **Q7.4** Why is scenario (c) not a reason to buy a non-blocking 400G compute fabric? Which network does matter for it?

---

## Exercise 8 — Storage networking and GPUDirect Storage

Training needs bandwidth from storage for two reasons: feeding data (sustained reads) and checkpointing (bursty, large writes that block or slow the job). **GPUDirect Storage (GDS)** creates a direct DMA path between storage (local NVMe or NVMe-oF/parallel file systems over RDMA) and GPU memory, with no copy through a CPU bounce buffer.

### Steps

1. Checkpoint math. A 70B-parameter model trained with mixed precision and the Adam optimizer needs roughly **16 bytes per parameter** for a full checkpoint (BF16 weights, FP32 master weights, two FP32 Adam moments, plus overhead rounded up).
   a. Compute the checkpoint size.
   b. The job writes it from 32 nodes over the storage fabric. Each node can sustain 2 × 200 Gb/s to storage. Compute the time to write the checkpoint if the storage system can absorb the aggregate.
   c. Recompute if the storage back end can only absorb **40 GB/s** total.
2. Check GDS support on a node:

   ```bash
   /usr/local/cuda/gds/tools/gdscheck -p
   ```

   Representative output (trimmed):

   ```
    GDS release version: 1.11.1.6
    nvidia_fs version:  2.22 libcufile version: 2.12
    Platform: x86_64
    ============
    ENVIRONMENT:
    ============
    =====================
    DRIVER CONFIGURATION:
    =====================
    NVMe               : Supported
    NVMeOF             : Supported
    SCSI               : Unsupported
    ScaleFlux CSD      : Unsupported
    NVMesh             : Unsupported
    DDN EXAScaler      : Supported
    IBM Spectrum Scale : Unsupported
    NFS                : Supported
    WekaFS             : Supported
    Userspace RDMA     : Supported
    --rdma library        : Loaded (libcufile_rdma.so)
    --rdma devices        : Configured
    --rdma_device_status  : Up: 2 Down: 0
   ```

### Questions

- **Q8.1** What are the answers to steps 1a, 1b, and 1c? Which component is the bottleneck in 1c?
- **Q8.2** Name two benefits of GDS compared with the traditional storage → host memory → GPU path.
- **Q8.3** Why does the DGX node use separate adapters for storage/in-band traffic instead of sharing the 8 compute NICs?

---

## Exercise 9 — Offload and isolate with BlueField DPUs

A BlueField DPU combines a ConnectX network adapter, Arm cores, and hardware accelerators on one card. It runs infrastructure services (virtual switching, storage virtualization, encryption, firewalling, telemetry) in its own trusted domain, separate from the host CPU (see the BlueField offload blog post linked above).

### Steps

1. For each service, decide whether it can be offloaded to a BlueField DPU and what the host gains:
   a. Open vSwitch datapath for tenant overlay networks (VXLAN)
   b. IPsec/TLS encryption of east-west traffic
   c. Presenting remote NVMe-oF storage to the host as a local NVMe device
   d. The PyTorch training loop itself
   e. A distributed firewall/microsegmentation policy for a multi-tenant cluster
2. In a multi-tenant AI cloud, a tenant gets root on a bare-metal GPU server. Describe where the infrastructure control plane (network policy, storage access) must live so the tenant cannot tamper with it.
3. Look at how the DGX B200 places BlueField-3 in the node (SuperPOD B200 RA). Note which fabric the BlueField-3 DPUs serve and which fabric the ConnectX-7 NICs serve.

### Questions

- **Q9.1** Why does offloading infrastructure services matter specifically for expensive GPU servers?
- **Q9.2** What is the difference between a "DPU" and a "SuperNIC" role for BlueField-3 in NVIDIA's AI networking story?
- **Q9.3** What security property does running the control plane on the DPU give you that running it on the host does not?

---

## Exercise 10 — Expose the RDMA fabric to Kubernetes pods

Kubernetes pod networking (the primary CNI) is designed for general TCP traffic, not for 400G RDMA. The NVIDIA Network Operator deploys the drivers (MOFED/DOCA-OFED), RDMA device plugins, and secondary CNIs. **Multus** attaches the extra RDMA interfaces to pods. This example uses a RoCE (Ethernet) port and the RDMA shared device plugin.

### Steps

1. Create the namespace and a secondary network for rail 0:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: ai-training
   ---
   apiVersion: k8s.cni.cncf.io/v1
   kind: NetworkAttachmentDefinition
   metadata:
     name: rdma-net-rail0
     namespace: ai-training
     annotations:
       k8s.v1.cni.cncf.io/resourceName: rdma/rdma_shared_device_a
   spec:
     config: |
       {
         "cniVersion": "0.3.1",
         "name": "rdma-net-rail0",
         "type": "macvlan",
         "master": "ens1f0np0",
         "ipam": {
           "type": "whereabouts",
           "range": "192.168.100.0/24"
         }
       }
   ```

   ```bash
   kubectl apply -f rdma-net-rail0.yaml
   kubectl get network-attachment-definitions -n ai-training
   ```

   ```
   NAME             AGE
   rdma-net-rail0   5s
   ```

2. Check that the node advertises the RDMA resource:

   ```bash
   kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep -E 'rdma|nvidia'
   ```

   ```
   "nvidia.com/gpu":"8"
   "rdma/rdma_shared_device_a":"63"
   ```

3. Run a test pod that requests GPUs, the RDMA device, and the secondary network:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nccl-test-0
     namespace: ai-training
     annotations:
       k8s.v1.cni.cncf.io/networks: rdma-net-rail0
   spec:
     restartPolicy: Never
     containers:
       - name: nccl
         image: nvcr.io/nvidia/pytorch:24.10-py3
         command: ["sleep", "infinity"]
         securityContext:
           capabilities:
             add: ["IPC_LOCK"]
         resources:
           limits:
             nvidia.com/gpu: 8
             rdma/rdma_shared_device_a: 1
   ```

4. Verify inside the pod:

   ```bash
   kubectl exec -n ai-training nccl-test-0 -- ip -br addr
   kubectl exec -n ai-training nccl-test-0 -- ibv_devices
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   eth0@if42        UP             10.244.3.17/24
   net1@if7         UP             192.168.100.12/24

       device                 node GUID
       ------              ----------------
       mlx5_0              a288c2fffe112233
   ```

### Questions

- **Q10.1** What are `eth0` and `net1` in the pod, and which one should NCCL use for its data path?
- **Q10.2** Why does the container need the `IPC_LOCK` capability for RDMA?
- **Q10.3** This example uses `macvlan` on a RoCE port. Which CNI choices would you use for an InfiniBand port, or when you need a dedicated virtual function per pod with hardware isolation?
- **Q10.4** A real training pod on a DGX node would attach 8 networks, not 1. Why?

---

## Exercise 11 — Troubleshoot a slow multi-node job

A 4-node training job runs at a fraction of the expected throughput. You rerun it with `NCCL_DEBUG=INFO` and collect these lines from rank 0:

```
gpu-node-01:2231:2231 [0] NCCL INFO NCCL_SOCKET_IFNAME set by environment to eth0
gpu-node-01:2231:2231 [0] NCCL INFO Bootstrap : Using eth0:10.244.3.17<0>
gpu-node-01:2231:2290 [0] NCCL INFO NET/IB : No device found.
gpu-node-01:2231:2290 [0] NCCL INFO NET/Socket : Using [0]eth0:10.244.3.17<0>
gpu-node-01:2231:2290 [0] NCCL INFO Using network Socket
gpu-node-01:2231:2290 [0] NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/Socket/0
```

A healthy run on the same cluster looks like this:

```
gpu-node-01:2231:2290 [0] NCCL INFO NET/IB : Using [0]mlx5_0:1/RoCE [1]mlx5_1:1/RoCE ... ; OOB eth0:10.244.3.17<0>
gpu-node-01:2231:2290 [0] NCCL INFO Using network IB
gpu-node-01:2231:2290 [0] NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
```

### Steps

1. Compare the two logs line by line and write down every difference.
2. List the checks you would run, in order, to find the root cause. Use commands from the earlier exercises.
3. Propose the fix for the pod spec in Exercise 10 if the pod was missing the RDMA resource request.

### Questions

- **Q11.1** What transport did the slow job use, and why is that a networking-requirements failure and not a GPU failure?
- **Q11.2** What does `GDRDMA` in the healthy log confirm?
- **Q11.3** `NCCL_SOCKET_IFNAME=eth0` is set in both runs. Is that variable the cause? What does it actually control?
- **Q11.4** After you fix transport selection, the job uses NET/IB but one node is still 30% slower than the others. Name two network-level causes and the command that would expose each.

---

## Answer Key

<details>
<summary><strong>Exercise 1 — Answers</strong></summary>

**Step 1–2:**

| Flow | Network | Direction |
|---|---|---|
| a. DDP gradient AllReduce across 64 nodes | Compute fabric (plus NVLink inside each node) | East-west |
| b. Tensor parallelism inside one DGX | NVLink/NVSwitch (no NIC involved) | Intra-node |
| c. 2 TB checkpoint | Storage fabric | East-west (to storage inside the data center) |
| d. BMC power cycle via Redfish | OOB management | Management plane |
| e. Container image pull | In-band management (through to the registry/proxy) | North-south |
| f. Inference HTTP requests | In-band / front-end (user access) network | North-south |

**Q1.1** Isolation of performance. Checkpoint bursts and dataset reads are bulk transfers. If they share links with the collectives, they inject congestion into a synchronous AllReduce, and the slowest flow sets the step time. Separate fabrics also let you size each one independently and keep storage reachable when the compute fabric is being maintained. The SuperPOD RA defines compute, storage, in-band, and OOB networks separately.

**Q1.2** OOB is the path you use to recover the in-band network and the nodes: BMC console, power control, firmware updates, switch management. If it shared fate with in-band, a misconfiguration or outage would lock operators out of the tools needed to fix it.

**Q1.3** Large-scale training is dominated by east-west traffic (collectives between GPUs). Online inference is dominated by north-south traffic (client requests and responses), though very large models served with multi-node tensor/pipeline parallelism also generate east-west traffic.

</details>

<details>
<summary><strong>Exercise 2 — Answers</strong></summary>

**Step 2:** GPU0 ↔ NIC0 (mlx5_0), GPU1 ↔ NIC1 (mlx5_1), GPU2 ↔ NIC2 (mlx5_2), GPU3 ↔ NIC3 (mlx5_3). Each pair shows `PXB`: they share a PCIe switch hierarchy without going through the CPU host bridge.

**Q2.1** `NV18` = 18 bonded NVLinks. That matches 4th-generation NVLink on Hopper (H100 SXM): 18 links × 50 GB/s = 900 GB/s bidirectional per GPU, switched through NVSwitch so every GPU reaches every other at full bandwidth.

**Q2.2** NIC0 (mlx5_0). The `PXB` path keeps the GPUDirect RDMA traffic in the PCIe switch, without crossing the CPU root complex. `NODE` means traversing host bridges, which adds latency and competes for root-complex bandwidth. NCCL reads this topology and picks the closest NIC automatically.

**Q2.3** `SYS` means traffic crosses the inter-socket link (for example, between NUMA nodes). GPUDirect RDMA across the socket interconnect is slow or disabled by NCCL's default `NCCL_NET_GDR_LEVEL`, so NCCL falls back to staging through host memory. Bandwidth drops and latency rises.

**Q2.4** Eight single-port ConnectX-7 adapters at 400 Gb/s (InfiniBand or Ethernet), exposed through four OSFP cages on the motherboard tray, dedicated to the cluster (compute) network. DGX H100 also has two dual-port ConnectX-7 adapters for storage and in-band management, a 10 GbE port, and a 1 GbE BMC port for OOB.

</details>

<details>
<summary><strong>Exercise 3 — Answers</strong></summary>

**Step 2:**

| Interconnect | Total bidirectional bandwidth per GPU |
|---|---|
| NVLink 4 (H100) | **900 GB/s** |
| NVLink 5 (B200) | **1.8 TB/s** |
| PCIe Gen5 x16 | ~128 GB/s |
| One NDR port | 400 Gb/s ÷ 8 = **50 GB/s** per direction |

**Step 3:** 900 / 128 ≈ **7×** PCIe Gen5. Per direction, NVLink 4 is 450 GB/s versus 50 GB/s for one NDR port ≈ **9×**.

**Q3.1** Tensor parallelism exchanges activations inside every layer, forward and backward, with almost no compute to hide it behind. It needs the ~9× bandwidth and lower latency of NVLink. Data parallelism exchanges gradients once per step (or per bucket) and can overlap that communication with the backward pass, so it tolerates the lower per-GPU bandwidth of the network. Network design follows from the parallelism plan: TP inside the NVLink domain, PP and DP across the fabric.

**Q3.2** The NVLink Switch System extends NVLink beyond one server. GB200 NVL72 connects 72 Blackwell GPUs in a single NVLink domain (about 130 TB/s aggregate, per NVIDIA's NVLink page). Larger NVLink domains let bigger TP/expert-parallel groups avoid the InfiniBand/Ethernet fabric, which changes how much bandwidth the scale-out fabric needs and which traffic it sees.

**Q3.3** Four third-generation NVSwitch chips. NVSwitch makes the NVLink domain a non-blocking switched fabric: any GPU can talk to any other GPU at full NVLink bandwidth simultaneously, instead of being limited to the GPUs it is directly wired to. Point-to-point NVLink alone would make bandwidth depend on the pairing.

</details>

<details>
<summary><strong>Exercise 4 — Answers</strong></summary>

**Q4.1** MT4129 is the ConnectX-7 family. `Rate: 400` = 400 Gb/s (NDR).

**Q4.2** A subnet manager (SM). On InfiniBand, the SM discovers the topology, assigns LIDs, computes routing tables, and moves ports from `Initializing` to `Active`. `Base lid: 65535` (unassigned) and `SM lid: 0` show no SM has configured this port. Either no SM is reachable on that port's subnet, or the SM has not swept it (for example, the port is on an isolated switch or a rail whose SM is down).

**Q4.3** NVIDIA UFM (Unified Fabric Manager), which includes the subnet manager plus fabric monitoring and telemetry, typically running on dedicated management servers (often in an HA pair) attached to the fabric. OpenSM can also run on a host or switch in smaller deployments.

**Q4.4** RoCEv2 (RDMA over Converged Ethernet, encapsulated in UDP/IP). InfiniBand has native credit-based link-level flow control, so it does not drop packets under congestion. On Ethernet you need to configure congestion handling end-to-end: PFC (lossless priority), ECN marking, and DCQCN congestion control, consistently on NICs and switches. Spectrum-X builds this tuning into the platform.

</details>

<details>
<summary><strong>Exercise 5 — Answers</strong></summary>

1. 8 × 400 Gb/s = **3.2 Tb/s** = **400 GB/s** per direction per node.
2. 32 nodes × 8 ports = **256** node-facing ports.
3. With 32 ports down per leaf: 256 / 32 = **8 leaf switches**, one per rail (leaf *i* connects NIC *i* of all 32 nodes).
4. Non-blocking: each leaf has 32 uplinks → 8 × 32 = **256 uplink ports**. 256 / 64 = **4 spine switches**.
5. 2:1 oversubscription: 16 uplinks per leaf → 128 uplink ports → **2 spines**. Cross-rail and cross-SU traffic now has half the bandwidth of node-facing traffic.

**Q5.1** Collectives are synchronous: every GPU waits for the slowest participant. Enterprise traffic is statistically multiplexed (many independent flows that rarely peak together), so oversubscription is cheap. AI collectives drive all links at line rate at the same time, so any oversubscription becomes a direct slowdown for the whole job, wasting GPU time that costs far more than the switches.

**Q5.2** The slowest link. Ring and tree AllReduce proceed in lock-step, so one congested uplink or a cable that flaps or runs at a degraded rate stretches every step for every GPU in the job. That is why the RA uses non-blocking fabrics and why per-port error and BER monitoring (UFM, `mlxlink`) matters.

**Q5.3** Rails keep the most common inter-node traffic (same GPU index on different nodes, which is how NCCL rings/trees and many parallelism layouts map) to one switch hop, reducing latency and spine load. For GPU 3 on node A to GPU 5 on node B, NCCL can use PXN: move data over NVLink from GPU 3 to GPU 5 on node A, then send it on rail 5 to node B (one hop). Without that, the traffic would cross leaf 3 → spine → leaf 5.

**Q5.4** SHARP (Scalable Hierarchical Aggregation and Reduction Protocol) performs the reduction inside the switches. Each node sends its data up once and receives the reduced result, instead of the ~2× data movement of a ring AllReduce through endpoints. This roughly halves the data each endpoint moves and reduces latency, improving effective AllReduce bandwidth.

</details>

<details>
<summary><strong>Exercise 6 — Answers</strong></summary>

**Q6.1** 246.63 × 2 × 7/8 = 246.63 × 1.75 ≈ **431.6 GB/s**. algbw is "data size ÷ time", which depends on the algorithm: a ring AllReduce moves each byte about 2(n−1)/n times across links. busbw corrects for that, giving the effective per-link bandwidth. It is independent of the number of ranks and comparable to the hardware's peak link bandwidth.

**Q6.2** NVLink 4 through NVSwitch. ~430 GB/s is close to the 450 GB/s per-direction NVLink bandwidth of H100 and far beyond PCIe Gen5 x16 (~64 GB/s per direction).

**Q6.3** 8 × 400 Gb/s = 3.2 Tb/s = **400 GB/s** per node per direction (theoretical, before protocol overhead). ~95 GB/s means roughly 2 of 8 rails' worth. Likely causes: NCCL is not using all 8 HCAs (wrong `NCCL_IB_HCA`, ports down or not Active); GPUDirect RDMA is disabled, so traffic is staged through host memory; poor GPU–NIC affinity (`SYS` paths); NCCL fell back to TCP sockets; an oversubscribed or congested fabric path; RoCE without proper PFC/ECN causing drops and retransmits.

**Q6.4** The average includes all message sizes from 8 B upward. Small messages are latency-bound, so their busbw is tiny and drags the average down. Large-message rows show the bandwidth limit. Gradient buckets in real training are usually large enough to approach it, which is why those rows are the ones to compare with the hardware.

</details>

<details>
<summary><strong>Exercise 7 — Answers</strong></summary>

**Step 1:**
- a. **InfiniBand Quantum-2.** Lowest latency, native lossless transport, SHARP in-network computing, adaptive routing, and it is the DGX SuperPOD RA compute fabric.
- b. **Spectrum-X Ethernet.** Purpose-built for AI on Ethernet: RoCE with adaptive routing and congestion control between Spectrum-4 switches and BlueField-3 SuperNICs, Ethernet operational model, multi-tenancy and isolation.
- c. **Standard Ethernet** for the front-end (north-south) network. With one replica per GPU and no cross-node communication, there is no east-west collective traffic to justify a high-performance compute fabric.

**Step 2 (RoCEv2 requirements):**
- RoCEv2 runs over **UDP destination port 4791**; switches and ACLs must allow and classify it.
- Mark RDMA traffic with a dedicated **DSCP** value; configure switches to trust DSCP and map it to a lossless traffic class.
- Enable **PFC** on that priority only, to prevent drops from buffer overflow.
- Enable **ECN** marking on switches and **DCQCN** on NICs, so senders slow down before PFC pauses spread (avoiding head-of-line blocking and pause storms).
- Consistent **MTU** end-to-end (jumbo frames, for example 9000 bytes on the Ethernet side; RDMA MTU 4096).

**Q7.1** InfiniBand uses **credit-based link-level flow control**: a sender only transmits when the receiver has advertised buffer credits, so packets are not dropped due to congestion. RoCE relies on **PFC** (802.1Qbb) for a lossless priority, plus ECN/DCQCN for end-to-end congestion control.

**Q7.2** Index **3**: IPv4-mapped address, `v2` (RoCEv2 is routable over IP; v1 is layer-2 only). Set `NCCL_IB_GID_INDEX=3`. (Recent NCCL versions can select the GID automatically, but explicit settings are common in RoCE clusters.)

**Q7.3** End-to-end co-design between Spectrum-4 switches and BlueField-3 SuperNICs: per-packet adaptive routing that sprays traffic across all paths, with the SuperNIC reordering packets so the application sees in-order delivery; telemetry-driven congestion control for noisy-neighbor isolation; and performance isolation for multi-tenant AI clouds. Plain RoCE relies on ECMP flow hashing, which can collide elephant flows on the same link and leave others idle.

**Q7.4** No inter-node collectives happen, so a non-blocking 400G east-west fabric would sit idle. What matters is the front-end network (request latency, load balancing, client throughput), plus storage/in-band bandwidth for loading model weights quickly at scale-up time.

</details>

<details>
<summary><strong>Exercise 8 — Answers</strong></summary>

**Q8.1**
- a. 70 × 10⁹ × 16 B = **1.12 TB**.
- b. Per node 2 × 200 Gb/s = 400 Gb/s = 50 GB/s; 32 nodes → 1,600 GB/s aggregate. 1,120 GB ÷ 1,600 GB/s ≈ **0.7 s** (theoretical, network-bound).
- c. 1,120 GB ÷ 40 GB/s = **28 s**. The bottleneck is the storage back end, not the network. Network requirements have to be sized together with the storage system's ingest capacity. Over a long training run, those seconds multiplied by every checkpoint and every GPU are expensive, which is why fast storage and asynchronous checkpointing matter.

**Q8.2** (any two) Higher bandwidth, because data moves directly via DMA into GPU memory; lower latency; no CPU bounce-buffer copies, which frees CPU cycles and host memory bandwidth; lower CPU utilization so the CPU can run data pipelines; more predictable performance under load.

**Q8.3** Separation of traffic classes: storage I/O and in-band traffic would contend with synchronous collectives on the compute NICs and stretch step time. Each compute NIC is paired one-to-one with a GPU in the rail design, so its bandwidth is already fully allocated to collectives. DGX H100 uses two dual-port ConnectX-7 adapters for storage/in-band; DGX B200 uses two BlueField-3 DPUs for that role.

</details>

<details>
<summary><strong>Exercise 9 — Answers</strong></summary>

**Step 1:**
- a. **Yes.** OVS datapath and VXLAN encap/decap offloaded to the DPU's eSwitch (ASAP²). Host CPU cycles freed; line-rate overlay networking.
- b. **Yes.** Inline IPsec/TLS crypto acceleration on the DPU. Encryption at line rate without host CPU cost.
- c. **Yes.** NVMe emulation (SNAP): the DPU presents remote storage as a local NVMe device; the host needs no special drivers and storage access is controlled by the DPU.
- d. **No.** The training loop runs on the GPUs (and host CPU for orchestration). DPUs offload infrastructure, not the application.
- e. **Yes.** Firewall and microsegmentation enforced on the DPU, outside the tenant's reach.

**Step 2:** On the DPU, which runs its own OS on its Arm cores in a separate trust domain. Even with root on the host, the tenant cannot reconfigure the DPU's network policy or storage access.

**Step 3:** In DGX B200, the two BlueField-3 DPUs serve the storage and in-band management network (north-south / converged storage), while the eight ConnectX-7 NICs (400 Gb/s, one per GPU) serve the compute east-west fabric.

**Q9.1** Every CPU cycle spent on packet processing, encryption, or storage virtualization is a cycle not feeding the GPUs (data loading, preprocessing, orchestration). On servers where GPUs are the expensive resource, offloading keeps them saturated and makes infrastructure overhead predictable.

**Q9.2** As a **DPU**, BlueField-3 runs infrastructure services (networking, storage, security) on its Arm cores and accelerators, typically on the north-south/storage/in-band side. As a **SuperNIC** (Spectrum-X), it focuses on high-performance east-west RoCE for GPU-to-GPU traffic: adaptive routing with packet reordering, congestion control, and isolation, paired with Spectrum-4 switches.

**Q9.3** Isolation of the control plane from the workload: the policy enforcement point sits outside the host's trust domain, so a compromised or malicious host OS (or tenant with root) cannot disable or bypass network policy, encryption, or storage access controls. That enables zero-trust, bare-metal multi-tenancy.

</details>

<details>
<summary><strong>Exercise 10 — Answers</strong></summary>

**Q10.1** `eth0` is the primary pod network interface from the cluster's default CNI (overlay, general traffic, control plane, Kubernetes services). `net1` is the secondary interface Multus attached from `rdma-net-rail0`, backed by the physical RoCE port. NCCL's data path should use the RDMA device (`mlx5_0`, associated with `net1`). `eth0` is fine for NCCL's bootstrap/OOB socket.

**Q10.2** RDMA registers (pins) memory buffers so the NIC can DMA into them without the kernel paging them out. Pinning memory requires `CAP_IPC_LOCK` (or a high `RLIMIT_MEMLOCK`). Without it, memory registration fails or is capped and RDMA does not work.

**Q10.3** For InfiniBand: the **IPoIB CNI** (`ipoib-cni`) on a shared device, or **SR-IOV InfiniBand** (`ib-sriov-cni`) with a VF per pod. For dedicated, hardware-isolated interfaces on Ethernet: **SR-IOV CNI** with the SR-IOV device plugin (a VF per pod, optionally with RDMA in exclusive namespace mode). All are deployable through the NVIDIA Network Operator.

**Q10.4** A DGX node has 8 compute NICs, one per GPU (rail). To reach the full 3.2 Tb/s per node and preserve GPU–NIC affinity for GPUDirect RDMA, the pod needs all 8 RDMA interfaces, one per rail. With 1, all 8 GPUs share 400 Gb/s and most traffic crosses PCIe paths far from the NIC.

</details>

<details>
<summary><strong>Exercise 11 — Answers</strong></summary>

**Step 1 — Differences:**
- Slow run: `NET/IB : No device found.` → NCCL found no usable RDMA device.
- Slow run: `Using network Socket` → fell back to TCP sockets over `eth0` (the overlay pod network).
- Slow run: channels go `via NET/Socket/0`; healthy: `via NET/IB/0/GDRDMA`.
- Healthy run lists the RDMA devices (`mlx5_0:1/RoCE`, ...) and keeps `eth0` only as the OOB/bootstrap interface.

**Step 2 — Checks, in order:**
1. Inside the pod: `ibv_devices` / `ibv_devinfo`. Are RDMA devices visible at all?
2. Pod spec: does it request `rdma/rdma_shared_device_a` (or SR-IOV resource) and the Multus `networks` annotation? `kubectl describe pod` and look for `net1`.
3. Node: `kubectl get node -o jsonpath='{.status.allocatable}'` → is the RDMA resource advertised? Are Network Operator pods (device plugin, drivers) healthy?
4. Host: `ibstat` / `ibdev2netdev` → are ports `Active`/`Up`?
5. Once devices are visible: `ib_write_bw` between nodes, then `all_reduce_perf` with `NCCL_DEBUG=INFO`.

**Step 3 — Fix:** add the RDMA resource limit and the Multus annotation (as in the Exercise 10 pod), keep `IPC_LOCK`, and for production attach all 8 rail networks.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: trainer-0
  namespace: ai-training
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-net-rail0
spec:
  containers:
    - name: trainer
      image: nvcr.io/nvidia/pytorch:24.10-py3
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      resources:
        limits:
          nvidia.com/gpu: 8
          rdma/rdma_shared_device_a: 1
```

**Q11.1** TCP sockets over the pod overlay (`eth0`). The GPUs were fine; the job could not reach the RDMA fabric, so every collective went through the kernel TCP stack, host memory copies, and the overlay network, at a small fraction of 400G RDMA bandwidth and with much higher latency. The networking requirement (RDMA access with GPUDirect) was not met.

**Q11.2** NCCL is using GPUDirect RDMA: the NIC reads from and writes to GPU memory directly, with no staging through host memory.

**Q11.3** No. `NCCL_SOCKET_IFNAME` selects the interface for NCCL's bootstrap and for the socket transport if it is used. The healthy run has the same setting and uses IB for data. The root cause is that no RDMA device was available in the pod, which forced the socket transport. (Pointing it at `eth0` is acceptable for bootstrap.)

**Q11.4** (any two)
- A port on that node is down or not `Active`, so NCCL uses fewer rails → `ibstat` / `ibdev2netdev`.
- A link trained at a lower rate or has a high bit error rate, causing retransmissions → `mlxlink -d mlx5_X -m -c` (`Rate`, `Effective Physical Errors`, `Raw Physical BER`), or UFM port counters.
- A GPU–NIC pairing has a `SYS` path or GPUDirect RDMA is disabled on that node (missing `nvidia-peermem` module) → `nvidia-smi topo -m`, `lsmod | grep nvidia_peermem`, and look for `GDRDMA` in the NCCL log.
- RoCE congestion settings missing on that node's switch port (PFC/ECN), causing drops → NIC counters (`ethtool -S <iface> | grep -iE 'pause|discard|ecn'`).
- Uplink congestion from oversubscription → compare `ib_write_bw` results between node pairs on the same leaf versus across spines.

</details>