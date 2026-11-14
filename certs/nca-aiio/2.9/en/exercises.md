# Guided Exercises — Topic 2.9: Identify High-Speed Data Center Network Options and Their Use Cases

> **Exam:** NVIDIA NCA-AIIO · **Weight:** 4.0
> **Goal:** After these exercises you can name each network fabric in an NVIDIA AI data center, explain what traffic it carries and why it is built that way, and pick the right technology for a given scenario. The fabrics are NVLink/NVSwitch, InfiniBand, RoCE/Spectrum-X Ethernet, the storage fabric, in-band/out-of-band management, and BlueField DPUs.

> **About the lab environment:** Most steps use read-only diagnostics that run on any DGX-class node or GPU server with ConnectX/BlueField adapters. These include `nvidia-smi`, `ibstat`, `ibv_devinfo`, `ibdev2netdev`, `mlxconfig`, and `perftest`. If you have no such hardware, use the expected outputs shown in each step. They are representative of a DGX H100 or DGX B200, and the questions can be answered from them. Do not run any command that **sets** firmware parameters (`mlxconfig ... set`) on a production system without a maintenance window.

---

## Exercise 1 — Map the four networks of a DGX node

An NVIDIA DGX system is not "a server with a NIC". The DGX H100 and DGX B200 component descriptions list physically separate networks, each sized for a different traffic class:

| Network | Typical hardware (DGX H100 / B200) | Traffic |
|---|---|---|
| **Compute (east-west) fabric** | 8× single-port ConnectX-7, 400 Gb/s each, exposed through 4 OSFP ports (two 400G ports per twin-port OSFP cage) | GPU-to-GPU across nodes: NCCL all-reduce, all-to-all, pipeline/tensor-parallel traffic |
| **Storage + in-band fabric** | 2× dual-port QSFP112. ConnectX-7 on H100; BlueField-3 DPU on B200. Up to 400 Gb/s | Dataset reads, checkpoint writes, Slurm/Kubernetes control traffic, user access |
| **In-band management** | Onboard 10/25 GbE (or a port of the storage NICs) | OS provisioning, monitoring, cluster services |
| **Out-of-band (OOB) management** | 1 GbE RJ45 to the BMC | IPMI/Redfish, remote console, power control, firmware |

### Steps

1. List the NVIDIA (Mellanox) network devices on the PCIe bus:

   ```bash
   lspci -nn | grep -i -E 'mellanox|nvidia.*(network|infiniband|ethernet)'
   ```

   Representative output (DGX H100, trimmed):

   ```
   0c:00.0 Infiniband controller [0207]: Mellanox Technologies MT2910 Family [ConnectX-7] [15b3:1021]
   12:00.0 Infiniband controller [0207]: Mellanox Technologies MT2910 Family [ConnectX-7] [15b3:1021]
   ...
   aa:00.0 Ethernet controller [0200]: Mellanox Technologies MT2910 Family [ConnectX-7] [15b3:1021]
   aa:00.1 Ethernet controller [0200]: Mellanox Technologies MT2910 Family [ConnectX-7] [15b3:1021]
   ```

2. Map each RDMA device to its Linux netdev and its link state:

   ```bash
   ibdev2netdev -v
   ```

   Representative output:

   ```
   0000:0c:00.0 mlx5_0 (MT4129 - ...) fw 28.39.xxxx port 1 (ACTIVE) ==> ibp12s0 (Up)
   0000:12:00.0 mlx5_1 (MT4129 - ...) fw 28.39.xxxx port 1 (ACTIVE) ==> ibp18s0 (Up)
   ...
   0000:aa:00.0 mlx5_8 (MT4129 - ...) fw 28.39.xxxx port 1 (ACTIVE) ==> enp170s0f0np0 (Up)
   0000:aa:00.1 mlx5_9 (MT4129 - ...) fw 28.39.xxxx port 1 (ACTIVE) ==> enp170s0f1np1 (Up)
   ```

3. Count the devices whose netdev starts with `ib` and the devices whose netdev starts with `en`.

4. Find the BMC interface. It does not appear in `lspci` as a ConnectX device. Query it from the host:

   ```bash
   sudo ipmitool lan print 1 | grep -E 'IP Address|MAC Address'
   ```

**Questions**

- **Q1.1** How many devices belong to the compute fabric, and what is the aggregate compute-fabric bandwidth per node in Gb/s and in GB/s?
- **Q1.2** Why is the compute fabric built from eight *single-port* NICs instead of, say, four dual-port NICs? Hint: count the GPUs and think about PCIe locality.
- **Q1.3** Which network would you still be able to use if the host OS kernel panicked? Why does that matter operationally?
- **Q1.4** On a DGX B200 the storage/in-band NICs are BlueField-3 DPUs instead of plain ConnectX-7. Name one capability this adds.

---

## Exercise 2 — Inspect the intra-node fabric: NVLink and NVSwitch

Inside the node, GPUs do **not** talk over PCIe or the NICs. They use NVLink through NVSwitch chips.

- **DGX H100:** 4th-gen NVLink, 18 links per GPU, 900 GB/s bidirectional per GPU, through 4 NVSwitch chips.
- **DGX B200:** 5th-gen NVLink, 1.8 TB/s per GPU, 14.4 TB/s aggregate across the 8 GPUs.

### Steps

1. Print the topology matrix:

   ```bash
   nvidia-smi topo -m
   ```

   Representative output (DGX H100, trimmed to 4 GPUs and 2 NICs):

   ```
           GPU0  GPU1  GPU2  GPU3  NIC0  NIC1  CPU Affinity  NUMA Affinity
   GPU0     X    NV18  NV18  NV18  PXB   SYS   0-55          0
   GPU1    NV18   X    NV18  NV18  SYS   PXB   0-55          0
   GPU2    NV18  NV18   X    NV18  SYS   SYS   0-55          0
   GPU3    NV18  NV18  NV18   X    SYS   SYS   0-55          0
   NIC0    PXB   SYS   SYS   SYS    X    SYS
   NIC1    SYS   PXB   SYS   SYS   SYS    X

   Legend:
     X    = Self
     SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
     PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
     NV#  = Connection traversing a bonded set of # NVLinks
   ```

2. Check per-link status and speed for one GPU:

   ```bash
   nvidia-smi nvlink -s -i 0
   ```

   Representative output:

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-xxxxxxxx)
        Link 0: 26.562 GB/s
        Link 1: 26.562 GB/s
        ...
        Link 17: 26.562 GB/s
   ```

3. Check that no link is reporting errors:

   ```bash
   nvidia-smi nvlink -e -i 0
   ```

4. Do the arithmetic. Compare the per-GPU NVLink bandwidth (900 GB/s bidirectional) with the bandwidth of a single 400 Gb/s ConnectX-7 NIC.

**Questions**

- **Q2.1** What does `NV18` tell you? Why does every GPU pair show the same value even though there are no direct GPU-to-GPU cables?
- **Q2.2** Which NIC should GPU0's inter-node traffic use, according to the matrix, and why?
- **Q2.3** Per direction, how many times faster is NVLink per GPU on H100 than that GPU's dedicated 400 Gb/s NIC? What does this imply about where tensor parallelism should be placed?
- **Q2.4** The NVLink Switch System (for example GB200 NVL72) extends NVLink beyond one chassis. What problem does that solve that InfiniBand does not?

---

## Exercise 3 — Inspect an InfiniBand compute port

InfiniBand (NDR 400 Gb/s with Quantum-2; XDR 800 Gb/s with Quantum-X800) is the reference compute fabric in DGX SuperPOD. Its defining properties are:

- **Credit-based link-level flow control:** lossless by design, with no PFC tuning required.
- **A centralized Subnet Manager (SM):** OpenSM or UFM assigns LIDs and computes routes.
- **Native RDMA**, adaptive routing, and **SHARP**, which performs in-network reductions inside the switches.

### Steps

1. Query port state for the first compute HCA:

   ```bash
   ibstat mlx5_0
   ```

   Representative output:

   ```
   CA 'mlx5_0'
       CA type: MT4129
       Number of ports: 1
       Firmware version: 28.39.xxxx
       Port 1:
           State: Active
           Physical state: LinkUp
           Rate: 400
           Base lid: 117
           SM lid: 1
           Capability mask: 0xa751e848
           Port GUID: 0x946dae0300xxxxxx
           Link layer: InfiniBand
   ```

2. Identify the Subnet Manager that is serving this port:

   ```bash
   sudo sminfo
   ```

   Representative output:

   ```
   sminfo: sm lid 1 sm guid 0xfc6a1c0300xxxxxx, activity count 512334 priority 15 state 3 SMINFO_MASTER
   ```

3. Read the port error counters. Non-zero `SymbolErrorCounter` or `LinkDownedCounter` values point to cable or optics problems:

   ```bash
   sudo perfquery -x
   ```

4. Now break the assumption. Imagine `ibstat` shows `State: Initializing` and `Physical state: LinkUp`. Write down what is missing.

**Questions**

- **Q3.1** What does `Link layer: InfiniBand` tell you that `Rate: 400` alone does not?
- **Q3.2** In step 4, the cable is fine but the port never reaches `Active`. Which component is the most likely culprit, and why does Ethernet have no equivalent failure mode?
- **Q3.3** Explain in one sentence how SHARP reduces all-reduce time.
- **Q3.4** Why does InfiniBand not need PFC/ECN tuning to be lossless?

---

## Exercise 4 — RoCEv2 and AI Ethernet (Spectrum-X)

Ethernet is a valid AI compute fabric when it runs **RoCEv2**: RDMA over Converged Ethernet, carried in UDP on destination port 4791 and routable over IP. Standard Ethernet drops packets under congestion, and RDMA collapses when packets are lost. RoCE fabrics therefore need:

- **PFC** (Priority Flow Control, 802.1Qbb) on the RDMA traffic class.
- **ECN** with a congestion-control algorithm such as DCQCN.

NVIDIA Spectrum-X combines Spectrum-4 switches (SN5600, 64×800G) with BlueField-3 SuperNICs. It adds adaptive routing with packet reordering at the NIC, and telemetry-driven congestion control, aimed specifically at AI east-west traffic.

### Steps

1. On a RoCE port, confirm the link layer and the GIDs:

   ```bash
   ibv_devinfo -d mlx5_8 | grep -E 'link_layer|state|active_mtu'
   show_gids mlx5_8
   ```

   Representative output:

   ```
           state:          PORT_ACTIVE (4)
           active_mtu:     4096 (5)
           link_layer:     Ethernet

   DEV     PORT  INDEX  GID                                      IPv4         VER  DEV
   mlx5_8  1     0      fe80:0000:0000:0000:a288:c2ff:fexx:xxxx                v1   enp170s0f0np0
   mlx5_8  1     1      fe80:0000:0000:0000:a288:c2ff:fexx:xxxx                v2   enp170s0f0np0
   mlx5_8  1     3      0000:0000:0000:0000:0000:ffff:0a0a:0a15  10.10.10.21  v2   enp170s0f0np0
   ```

2. Inspect the QoS configuration: trust mode, and which priorities have PFC enabled:

   ```bash
   sudo mlnx_qos -i enp170s0f0np0
   ```

   Representative output (trimmed):

   ```
   DCBX mode: OS controlled
   Priority trust state: dscp
   PFC configuration:
       priority    0   1   2   3   4   5   6   7
       enabled     0   0   0   1   0   0   0   0
   ```

3. Check whether the port has been sending or receiving pause frames:

   ```bash
   ethtool -S enp170s0f0np0 | grep -E 'prio3_(rx|tx)_pause|rx_discards_phy|np_cnp_sent|rp_cnp_handled'
   ```

4. Compare the operational models. Fill this table from what you observed in Exercises 3 and 4:

   | Property | InfiniBand | RoCEv2 Ethernet |
   |---|---|---|
   | Losslessness mechanism | ? | ? |
   | Address used by RDMA | ? | ? |
   | Control plane | ? | ? |
   | Routable across L3? | ? | ? |

**Questions**

- **Q4.1** Which GID index would you give NCCL (`NCCL_IB_GID_INDEX`) for RoCEv2 over IPv4 in the output above? Why not index 0?
- **Q4.2** PFC is enabled only on priority 3. What happens to RDMA traffic if the switch trusts PCP but the host marks DSCP?
- **Q4.3** Non-zero `np_cnp_sent` and `rp_cnp_handled` counters mean what?
- **Q4.4** Give two reasons an organization might pick Spectrum-X Ethernet over InfiniBand for a new AI cluster, and one reason to pick InfiniBand anyway.

---

## Exercise 5 — GPUDirect RDMA and GPUDirect Storage

Without GPUDirect, inter-node data takes this path:

GPU memory → host bounce buffer → NIC

**GPUDirect RDMA** lets the NIC read and write GPU memory directly over PCIe. **GPUDirect Storage (GDS)** does the same for NVMe and NVMe-oF/parallel file systems on the storage fabric. In both cases the CPU and system memory drop out of the data path.

### Steps

1. Confirm that the peer-memory kernel module is loaded. This module is what lets ConnectX map GPU memory:

   ```bash
   lsmod | grep nvidia_peermem
   ```

   Expected output:

   ```
   nvidia_peermem         16384  0
   nvidia               ...    nvidia_uvm,nvidia_peermem,nvidia_modeset
   ```

2. Run a host-memory RDMA bandwidth test between two nodes over the compute fabric.

   Server:

   ```bash
   ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -D 10
   ```

   Client:

   ```bash
   ib_write_bw -d mlx5_0 -F --report_gbits -s 1048576 -D 10 <server-ip>
   ```

3. Repeat the test with GPU memory as the source and the destination. This requires perftest built with CUDA support:

   ```bash
   ib_write_bw -d mlx5_0 --use_cuda=0 -F --report_gbits -s 1048576 -D 10 <server-ip>
   ```

   Representative result for both runs:

   ```
    #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
    1048576    46xxxx         393.xx             392.xx               0.0468
   ```

4. Check the GDS configuration, if GDS is installed:

   ```bash
   /usr/local/cuda/gds/tools/gdscheck -p
   ```

**Questions**

- **Q5.1** In step 3, why does it matter that you pass `--use_cuda=0` together with `-d mlx5_0`, given the topology from Exercise 2?
- **Q5.2** Suppose the GPU-memory run delivered about 120 Gb/s while the host-memory run delivered about 392 Gb/s. Name the two most likely causes.
- **Q5.3** Which fabric does GDS traffic use, and which bottleneck does it remove during checkpointing?

---

## Exercise 6 — BlueField DPU: offload and isolation

A BlueField DPU is a NIC with its own Arm cores, memory, and accelerators, running its own OS. The NVIDIA blog on offloading and isolating workloads describes its role as running infrastructure services on the DPU instead of on the host x86 CPU. Those services include virtual switching (OVS), storage virtualization (SNAP/NVMe emulation), encryption (IPsec/TLS), firewalling, and telemetry. This frees host cores and creates a trust boundary that tenant workloads on the host cannot cross.

### Steps

1. Identify the BlueField-3 device and open the firmware tools:

   ```bash
   sudo mst start
   sudo mst status -v | grep -i bluefield
   ```

   Representative output:

   ```
   BlueField3(rev:1)  /dev/mst/mt41692_pciconf0  ca:00.0  mlx5_10  net-enp202s0f0np0  0
   ```

2. Query the operating mode. Do **not** set anything:

   ```bash
   sudo mlxconfig -d /dev/mst/mt41692_pciconf0 q | grep -E 'INTERNAL_CPU_MODEL|INTERNAL_CPU_OFFLOAD_ENGINE'
   ```

   Representative output (DPU mode):

   ```
           INTERNAL_CPU_MODEL                  EMBEDDED_CPU(1)
           INTERNAL_CPU_OFFLOAD_ENGINE         ENABLED(0)
   ```

   Parameter names and allowed values vary by firmware generation. Verify them against the BlueField documentation for your release before acting on them.

3. From the host, check whether the DPU's Arm OS is reachable through the virtual `tmfifo` interface:

   ```bash
   ip addr show tmfifo_net0
   ssh ubuntu@192.168.100.2 'uname -m; ovs-vsctl show | head'
   ```

   Expected: `aarch64`, and an OVS bridge in which the host's representor ports appear.

4. Classify each of the following workloads into "offload to the DPU" or "stays on the GPU/host":

   - (a) OVS-based tenant network isolation for a multi-tenant Kubernetes cluster
   - (b) Transformer forward pass
   - (c) Line-rate IPsec between data centers
   - (d) Presenting remote NVMe-oF storage to the host as a local NVMe device
   - (e) NCCL all-reduce math

**Questions**

- **Q6.1** In DPU mode, who controls the network data path: the host OS or the DPU Arm OS? What security property does that give a cloud operator?
- **Q6.2** What is the difference in purpose between a BlueField-3 used as a **DPU** in the storage/north-south path and a BlueField-3 used as a **SuperNIC** in Spectrum-X?
- **Q6.3** Give your answers for 4(a)–(e).

---

## Exercise 7 — Size a rail-optimized compute fabric (DGX SuperPOD)

The DGX SuperPOD reference architectures build the compute fabric from **Scalable Units (SUs)** of 32 DGX nodes in a **rail-optimized** topology. NIC *n* of every node (the NIC closest to GPU *n*) connects to leaf switch *n*, the "rail *n*" leaf. A Quantum-2 QM9700 switch has 64 NDR 400 Gb/s ports, and a non-blocking leaf splits them as 32 down and 32 up.

### Steps

1. Compute, for one SU of 32 DGX B200 nodes:

   - (a) GPUs per SU
   - (b) Compute NIC ports per SU
   - (c) Rail leaf switches per SU, and downlinks used per leaf
   - (d) Uplinks per leaf for a non-blocking (1:1) design

2. Write down which leaf a packet crosses when GPU3 on node 7 sends to GPU3 on node 22. Then do the same for GPU3 on node 7 sending to GPU5 on node 22.

3. Compute the per-node compute-fabric bandwidth (8 × 400 Gb/s). Compare it with the storage fabric (2 × dual-port × 200–400 Gb/s, typically not all ports active for storage). Explain the ratio.

**Questions**

- **Q7.1** Give your values for 1(a)–(d).
- **Q7.2** Why does rail optimization benefit NCCL collectives in particular? Use your answer to step 2.
- **Q7.3** Why does the reference architecture physically separate the storage fabric from the compute fabric instead of converging them?
- **Q7.4** Which switch family does the OOB management network typically use, and why would putting it on the 400G fabric be a design error?

---

## Exercise 8 — Match the scenario to the network (exam drill)

For each scenario, name the **primary** technology and justify it in one line.

1. Tensor-parallel communication among 8 GPUs inside one server.
2. Data-parallel all-reduce across 1,024 GPUs in 128 nodes, in a cluster built for maximum training performance with NVIDIA's reference design.
3. A cloud provider with an all-Ethernet operational team wants multi-tenant AI training at scale with RDMA performance.
4. Power-cycling a hung node at 3 a.m.
5. Streaming training shards from a parallel file system directly into GPU memory.
6. Isolating tenant traffic and encrypting it without spending host CPU cycles.
7. A 72-GPU model-parallel domain that must behave like one giant GPU for trillion-parameter inference.
8. PXE-booting and imaging the OS on new nodes.

---

## Answers

<details>
<summary>Click to reveal answers</summary>

### Exercise 1

- **Q1.1** There are 8 compute devices, the `ib*` netdevs from `mlx5_0` to `mlx5_7`. Aggregate bandwidth is 8 × 400 Gb/s = **3.2 Tb/s**. Divided by 8 bits per byte, that is **400 GB/s** per direction per node.
- **Q1.2** The design gives one NIC per GPU, and each NIC sits under the same PCIe switch as "its" GPU (`PXB` in the topology). Every GPU therefore gets a dedicated, local 400 Gb/s path for GPUDirect RDMA, with no traffic crossing the CPU or socket interconnect. Single-port NICs also map one-to-one onto the compute rails (Exercise 7).
- **Q1.3** The **OOB/BMC network**. The BMC is an independent controller with its own power domain and its own NIC. It still works when the host is crashed or powered off, which allows remote console access, power cycling, and firmware recovery without physical access.
- **Q1.4** Any one of the following: offload of infrastructure services such as OVS, storage emulation, encryption, and firewalling to the DPU's Arm cores; isolation of the infrastructure control plane from the host OS; or hardware-accelerated storage and security.

### Exercise 2

- **Q2.1** `NV18` means the path between the two GPUs uses a bonded set of 18 NVLinks, which is all 18 links of an H100. The links go into the NVSwitch chips rather than to another GPU. NVSwitch is a non-blocking crossbar, so every GPU reaches every other GPU at full NVLink bandwidth, and every pair looks identical.
- **Q2.2** **NIC0**. It is `PXB` to GPU0: it shares a PCIe switch with GPU0, so traffic stays below the CPU root complex. NIC1 is `SYS` and would cross the SMP interconnect.
- **Q2.3** NVLink delivers 900 GB/s bidirectional, which is 450 GB/s per direction. A 400 Gb/s NIC delivers 50 GB/s per direction. NVLink is therefore about **9×** faster per GPU. Tensor parallelism is the most communication-intensive form of parallelism, so it should stay **inside the NVLink domain**. Data and pipeline parallelism go across the InfiniBand or Ethernet fabric.
- **Q2.4** It extends the NVLink domain, with its memory-semantic, very-high-bandwidth GPU-to-GPU communication, across many GPUs in multiple trays. GB200 NVL72 joins 72 GPUs into one NVLink domain, which lets tensor or expert parallelism scale beyond 8 GPUs. Over InfiniBand that traffic would be capped at NIC bandwidth.

### Exercise 3

- **Q3.1** It shows the port runs the **InfiniBand protocol**, not Ethernet. A ConnectX-7 VPI adapter can run either protocol at 400 Gb/s, so `Rate: 400` alone is ambiguous. The link layer determines the tooling, the addressing (LIDs vs IP/GIDs), and the control plane (SM vs Ethernet/IP routing).
- **Q3.2** The **Subnet Manager**. It is absent, unreachable, or has not swept the fabric yet. An IB port moves to Active only after the SM assigns a LID and programs routes. Ethernet has no central fabric controller: a link that is physically up forwards frames immediately.
- **Q3.3** The switches aggregate (sum) the data as it flows through the fabric. Each node then sends and receives its data roughly once instead of many times, which reduces both the traffic volume and the latency of the collective.
- **Q3.4** IB uses **credit-based link-level flow control**. A sender transmits only when the receiver has advertised buffer credits, so the protocol never drops packets because of congestion.

### Exercise 4

- **Q4.1** Use **index 3**, the RoCE **v2** GID with an IPv4-mapped address (`10.10.10.21`). RoCEv2 is encapsulated in UDP/IP, so it is routable across L3 fabrics. Index 0 is a link-local RoCE **v1** GID, which is L2-only and not routable.
- **Q4.2** The switch classifies the packets into the wrong priority, most likely 0. PFC does not protect that priority, so under congestion RDMA packets are dropped. The result is retransmissions (go-back-N), throughput collapse, and long tail latency. Host and switch must agree on trust mode and mapping end to end.
- **Q4.3** ECN-based congestion control (DCQCN) is active. The receiver ("notification point") saw ECN-marked packets and sent Congestion Notification Packets. The sender ("reaction point") received them and lowered its rate. That is healthy behavior. Persistent high rates mean sustained congestion that is worth investigating.
- **Q4.4** For Ethernet: it reuses existing Ethernet skills, tooling, and automation; it integrates natively with multi-tenant cloud networking and L3; and it gives a single fabric technology across the data center. Spectrum-X adds adaptive routing and congestion control tuned for AI. For InfiniBand: it is lossless by design with no PFC tuning, it offers SHARP in-network computing, it is the reference fabric in DGX SuperPOD, and it delivers predictable latency at very large scale.

**Comparison table (step 4)**

| Property | InfiniBand | RoCEv2 Ethernet |
|---|---|---|
| Losslessness mechanism | Credit-based link-level flow control | PFC on the RDMA priority, plus ECN/DCQCN |
| Address used by RDMA | LID (assigned by the SM), plus GUID | GID derived from the IP address |
| Control plane | Centralized Subnet Manager | Distributed Ethernet/IP (BGP/ECMP, etc.) |
| Routable across L3? | Not natively; needs IB routers/gateways | Yes; UDP/IP, destination port 4791 |

### Exercise 5

- **Q5.1** GPU0 and `mlx5_0` (NIC0) share a PCIe switch. Peer-to-peer DMA between them stays local. Pairing GPU0 with a `SYS` NIC would push the DMA across the CPU socket interconnect, which cuts bandwidth substantially.
- **Q5.2** (1) `nvidia_peermem` is not loaded, or perftest was built without CUDA, so data is being staged through host memory. (2) The GPU and NIC are not PCIe-local (a `SYS` path), or ACS/IOMMU settings are forcing peer-to-peer traffic through the root complex.
- **Q5.3** GDS uses the **storage fabric** (storage/in-band NICs or DPUs toward the parallel file system or NVMe-oF). It removes the **CPU bounce buffer in system memory**: data moves directly between storage and GPU memory. That raises throughput, lowers CPU load, and shortens checkpoint save and load times.

### Exercise 6

- **Q6.1** The **DPU Arm OS** controls it. The host sees only representor or virtual functions that the DPU exposes. Even a host compromised by a tenant cannot reconfigure network policy, encryption, or the virtual switch. Infrastructure is isolated from workload, which is the zero-trust model the BlueField blog describes.
- **Q6.2** As a **DPU**, BlueField-3 runs infrastructure services: OVS, storage emulation, security, and the north-south and tenant control plane. As a **SuperNIC**, it is tuned for east-west AI compute traffic in Spectrum-X, providing high-bandwidth RoCE, adaptive-routing packet reordering, and congestion control. In other words, the SuperNIC is the AI data path and the DPU is the infrastructure platform.
- **Q6.3** (a) DPU. (b) GPU. (c) DPU, which has hardware crypto. (d) DPU (NVMe emulation, SNAP). (e) GPU/NCCL. SHARP can perform the reduction in IB switches, but this is never a DPU host-offload task.

### Exercise 7

- **Q7.1**
  - (a) 32 × 8 = **256 GPUs**.
  - (b) **256** compute ports (one per GPU).
  - (c) **8** rail leaves, one per GPU index. Each uses **32** downlinks, one per node.
  - (d) **32** uplinks per leaf for 1:1, using all 64 ports of a QM9700.
- **Q7.2** GPU3 on node 7 to GPU3 on node 22 crosses **only the rail-3 leaf: one hop**. GPU3 to GPU5 must either go through a spine, or first move over NVLink to GPU5 inside node 7 and then use rail 5. NCCL arranges rings and trees so that most inter-node traffic travels between same-index GPUs. Rail optimization therefore keeps most collective traffic on a single leaf, which minimizes hops, latency, and spine contention.
- **Q7.3** The traffic patterns conflict. Storage produces bursty, large, many-to-one reads and writes. NCCL collectives are synchronized and very sensitive to jitter: one slow flow stalls every GPU. Separate fabrics prevent checkpoint bursts from inflating step time. They also allow each fabric to be sized independently, and limit the blast radius of a failure.
- **Q7.4** Low-cost 1 GbE management switches; the NVIDIA reference architectures use SN2201-class switches. OOB has to stay reachable when the production fabric is down. Putting it on the 400G fabric would make management depend on the very network it is supposed to recover, and would waste expensive ports on kilobit-per-second traffic.

### Exercise 8

1. **NVLink/NVSwitch.** It has about 9× the per-GPU bandwidth of a NIC and stays inside the node.
2. **InfiniBand NDR or XDR, rail-optimized**, with SHARP. This is the DGX SuperPOD reference compute fabric.
3. **Spectrum-X Ethernet**: Spectrum-4 switches plus BlueField-3 SuperNICs running RoCEv2. It provides RDMA performance on an Ethernet operational model.
4. **OOB management network to the BMC** (IPMI/Redfish). It works even when the host is dead.
5. **Storage fabric with GPUDirect Storage.** Data goes directly from the file system to GPU memory without a CPU bounce buffer.
6. **BlueField DPU.** OVS, IPsec, and firewalling are offloaded and isolated from the host.
7. **NVLink Switch System** (for example GB200 NVL72). A single NVLink domain spans 72 GPUs.
8. **In-band management network** (Ethernet). It carries provisioning, PXE, and OS services.

</details>

---

## References

- NVIDIA DGX H100 User Guide — Component Descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA NVLink and NVLink Switch: https://www.nvidia.com/en-us/data-center/nvlink/
- Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Accelerating IO in the Modern Data Center — Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA AI Infrastructure and Operations Fundamentals (course): https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NCA-AIIO exam study guide (PDF): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf