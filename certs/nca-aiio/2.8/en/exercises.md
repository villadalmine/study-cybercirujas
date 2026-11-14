# Guided Exercises — Topic 2.8: Data Center Networking Protocols and Key Concepts (NCA-AIIO)

These exercises cover the networking concepts that NCA-AIIO expects you to identify and describe:

- The separate networks in an AI data center: compute (east-west), storage, in-band management, and out-of-band (OOB) management.
- **InfiniBand** compared with **Ethernet/RoCE**.
- **RDMA** and **GPUDirect RDMA / GPUDirect Storage**.
- **NVLink/NVSwitch** for scale-up compared with the NIC fabric for scale-out.
- Rail-optimized fat-tree topologies.
- Congestion control (credit-based flow control, PFC, ECN, DCQCN, adaptive routing).
- In-network computing (**SHARP**).
- The role of **BlueField DPUs/SuperNICs** and **Spectrum-X**.

There are two kinds of exercises:

- **Hands-on exercises** run on any Linux VM. They use **Soft-RoCE** (`rdma_rxe`), so you can practice real RDMA verbs without a ConnectX NIC.
- **Read-the-output exercises** use realistic outputs from DGX-class systems, so you can practise diagnosis without access to a SuperPOD.

Official references used throughout:

- DGX H100 component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- DGX SuperPOD B200 reference architecture: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Network I/O and GPUDirect: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- BlueField DPU offload and isolation: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727

---

## Prerequisites

| Need | For exercises | Notes |
|---|---|---|
| Linux VM (Ubuntu 22.04+/Fedora 39+), 1 NIC, sudo | 2 | No special hardware. Soft-RoCE emulates a RoCEv2 device in the kernel |
| Pen and paper / calculator | 1, 4, 5 | Bandwidth and topology math |
| Nothing (read outputs) | 3, 6, 7, 8 | Outputs are representative of DGX H100/B200 systems |

---

## Exercise 1 — Map the four networks of a DGX node

An AI cluster node does not have "a network". It has several physically separate fabrics, and each one carries a different class of traffic. The DGX H100 user guide describes the node's network adapters as follows:

- **Compute fabric:** 4× OSFP ports serving **8× single-port ConnectX-7 VPI** adapters. Each adapter runs at up to **400 Gb/s**, in InfiniBand or Ethernet mode. There is one adapter per GPU.
- **Storage and in-band management:** **2× dual-port ConnectX-7** adapters (on the DGX B200 SuperPOD RA, these are **BlueField-3** DPUs).
- **Out-of-band management:** a **1 GbE RJ45 BMC** port.
- **Inside the node:** the 8 GPUs are interconnected through **NVSwitch** with **NVLink**. This is the scale-up domain, and it never leaves the chassis on a DGX H100/B200.

### Steps

1. Draw a box for one DGX node. Inside it, draw 8 GPUs connected to an "NVSwitch" block.
2. Attach one 400 Gb/s NIC to each GPU, eight NICs in total. Label this group **Compute (east-west) fabric**.
3. Attach two dual-port NICs to the CPU complex. Label them **Storage + In-band management (north-south)**.
4. Attach the BMC to a 1 GbE switch. Label it **OOB management**.
5. Next to each network, write what travels on it. Choose from: NCCL all-reduce traffic, dataset reads and checkpoint writes, SSH/Slurm/Kubernetes API/container image pulls, IPMI/Redfish power cycling and firmware updates.

### Questions

- **1.1** Why does the compute fabric use one NIC per GPU instead of a few big shared NICs?
- **1.2** A job fills the storage network while writing a checkpoint. Why does this not slow down the gradient all-reduce of another job running at the same moment?
- **1.3** The in-band network is down. Which network do you still have to power-cycle the node or reach its console, and through which component?
- **1.4** Which traffic never touches any NIC on a single 8-GPU DGX H100 job?

---

## Exercise 2 — Hands-on RDMA with Soft-RoCE

RDMA lets one host read or write another host's registered memory **without involving the remote CPU or kernel**. The NIC executes the transfer, which gives zero-copy, kernel bypass, and low latency.

- **RoCEv2** carries the InfiniBand transport over UDP/IP. The UDP destination port is **4791**.
- **Soft-RoCE** implements the same verbs API in software.

The commands, verbs, and tools in this exercise are the same ones you use on a ConnectX-7. Only the performance differs.

### Steps

1. Install the tools.

   Ubuntu:
   ```bash
   sudo apt update
   sudo apt install -y rdma-core ibverbs-utils perftest iproute2
   ```

   Fedora:
   ```bash
   sudo dnf install -y rdma-core libibverbs-utils perftest iproute
   ```

2. Find the Ethernet interface and its IPv4 address:
   ```bash
   ip -br addr show
   ```
   Expected output (yours will differ):
   ```
   lo        UNKNOWN  127.0.0.1/8 ::1/128
   enp0s3    UP       10.0.2.15/24 fe80::a00:27ff:fe4e:66a1/64
   ```

3. Load the Soft-RoCE driver and create an RDMA device on top of the interface:
   ```bash
   sudo modprobe rdma_rxe
   sudo rdma link add rxe0 type rxe netdev enp0s3
   rdma link show
   ```
   Expected output:
   ```
   link rxe0/1 state ACTIVE physical_state LINK_UP netdev enp0s3
   ```

4. Inspect the device the same way you would inspect a ConnectX:
   ```bash
   ibv_devices
   ibv_devinfo -d rxe0
   ```
   Expected output (trimmed):
   ```
       device                 node GUID
       ------              ----------------
       rxe0                0a0027fffe4e66a1

   hca_id: rxe0
           transport:                      InfiniBand (0)
           fw_ver:                         0.0.0
           node_guid:                      0a00:27ff:fe4e:66a1
           phys_port_cnt:                  1
                   port:   1
                           state:          PORT_ACTIVE (4)
                           max_mtu:        4096 (5)
                           active_mtu:     1024 (3)
                           link_layer:     Ethernet
   ```

5. List the GIDs and their types. RoCE has no LIDs; peers are addressed through **GIDs** derived from the interface's IP addresses.
   ```bash
   for i in 0 1 2; do
     printf "GID %s: %s  type: %s\n" "$i" \
       "$(cat /sys/class/infiniband/rxe0/ports/1/gids/$i 2>/dev/null)" \
       "$(cat /sys/class/infiniband/rxe0/ports/1/gid_attrs/types/$i 2>/dev/null)"
   done
   ```
   Expected output:
   ```
   GID 0: fe80:0000:0000:0000:0a00:27ff:fe4e:66a1  type: RoCE v2
   GID 1: 0000:0000:0000:0000:0000:ffff:0a00:020f  type: RoCE v2
   GID 2: 0000:0000:0000:0000:0000:0000:0000:0000  type:
   ```
   `::ffff:0a00:020f` is the IPv4-mapped form of `10.0.2.15`.

6. Run an RDMA WRITE bandwidth test. Use two terminals on the same VM:
   ```bash
   # Terminal 1 (server)
   ib_write_bw -d rxe0 -x 1 -s 65536 -D 5

   # Terminal 2 (client)
   ib_write_bw -d rxe0 -x 1 -s 65536 -D 5 10.0.2.15
   ```
   Expected output on the client (trimmed; numbers vary):
   ```
                       RDMA_Write BW Test
    Dual-port       : OFF          Device         : rxe0
    Number of qps   : 1            Transport type : IB
    Connection type : RC           Using SRQ      : OFF
    Link type       : Ethernet
    GID index       : 1
   ---------------------------------------------------------------------------------------
    #bytes     #iterations    BW peak[MB/sec]    BW average[MB/sec]   MsgRate[Mpps]
    65536      41200            0.00               515.08               0.008241
   ---------------------------------------------------------------------------------------
   ```

7. Observe the transport on the wire. Use a third terminal while repeating step 6:
   ```bash
   sudo tcpdump -i enp0s3 -c 5 udp port 4791
   ```
   On loopback-to-self traffic tcpdump may show nothing, because the kernel short-circuits it. If that happens, repeat the test between two VMs on the same subnet.

8. Clean up:
   ```bash
   sudo rdma link delete rxe0
   ```

### Questions

- **2.1** `ibv_devinfo` reports `transport: InfiniBand` and also `link_layer: Ethernet`. Explain how both can be true.
- **2.2** Why did you pass `-x 1` to `ib_write_bw`? What GID index would a native InfiniBand HCA use, and how is a native InfiniBand port addressed inside its subnet?
- **2.3** In a real `ib_write_bw` between two ConnectX-7 NICs, the remote host's `top` shows almost no CPU usage while 49 GB/s arrives. Which RDMA property explains this?
- **2.4** Soft-RoCE reached about 0.5 GB/s, while a ConnectX-7 at 400 Gb/s reaches about 48–49 GB/s. Where does the work happen in each case?
- **2.5** Which UDP port identifies RoCEv2? Why does RoCEv2 being routable (UDP/IP) matter compared with RoCEv1?

---

## Exercise 3 — Read the node's PCIe/NVLink topology

On a DGX H100, `nvidia-smi topo -m` shows how GPUs and NICs relate. This output is trimmed to 4 GPUs and 4 compute NICs:

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
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks

NIC Legend:
  NIC0: mlx5_0
  NIC1: mlx5_1
  NIC2: mlx5_2
  NIC3: mlx5_3
```

Complementary command:
```bash
nvidia-smi nvlink -s -i 0
```
```
GPU 0: NVIDIA H100 80GB HBM3
	 Link 0: 26.562 GB/s
	 Link 1: 26.562 GB/s
	 ...
	 Link 17: 26.562 GB/s
```

### Steps

1. Count the NVLinks between GPU0 and any other GPU.
2. Identify the NIC "closest" to GPU0. That is the one with the shortest PCIe path.
3. Find which CPU cores a process driving GPU0 and mlx5_0 should be pinned to.

### Questions

- **3.1** `NV18` means 18 NVLinks. With 4th-gen NVLink, an H100 has 900 GB/s of total bidirectional bandwidth. How much is that per link, per direction? Compare your result with the 26.562 GB/s that `nvidia-smi nvlink -s` reports.
- **3.2** Why is every GPU pair `NV18`, even though each GPU does not have 7×18 links?
- **3.3** GPUDirect RDMA lets mlx5_0 DMA directly into GPU0's HBM. Why must the NIC and GPU share a PCIe switch (`PXB`/`PIX`) for best performance? What happens to the data path if the pair is `SYS`?
- **3.4** NCCL picks the NIC for each GPU automatically. If NCCL instead routed GPU0's traffic through mlx5_3, which shared resource would you be crossing?

---

## Exercise 4 — Inspect an InfiniBand fabric

Read these outputs from a DGX node on an NDR InfiniBand compute fabric.

```bash
ibstat mlx5_0
```
```
CA 'mlx5_0'
	CA type: MT4129
	Number of ports: 1
	Firmware version: 28.39.1002
	Hardware version: 0
	Node GUID: 0xa088c20300e4b2f0
	System image GUID: 0xa088c20300e4b2f0
	Port 1:
		State: Active
		Physical state: LinkUp
		Rate: 400
		Base lid: 37
		LMC: 0
		SM lid: 1
		Capability mask: 0xa751e848
		Port GUID: 0xa088c20300e4b2f0
		Link layer: InfiniBand
```

```bash
ibstat mlx5_5
```
```
CA 'mlx5_5'
	...
	Port 1:
		State: Initializing
		Physical state: LinkUp
		Rate: 400
		Base lid: 65535
		SM lid: 0
		Link layer: InfiniBand
```

```bash
sminfo
```
```
sminfo: sm lid 1 sm guid 0xb83fd20300a1c0de, activity count 948211 priority 15 state 3 SMINFO_MASTER
```

```bash
ibdev2netdev
```
```
mlx5_0 port 1 ==> ibp24s0 (Up)
mlx5_1 port 1 ==> ibp64s0 (Up)
...
mlx5_10 port 1 ==> enp170s0f0np0 (Up)
mlx5_11 port 1 ==> enp170s0f1np1 (Up)
```

### Steps

1. Note `CA type`, `Rate`, `Link layer`, `Base lid`, and `SM lid` for each port.
2. Compare the healthy port (mlx5_0) with the problem port (mlx5_5).
3. Identify which devices belong to the compute fabric and which to the storage/in-band fabric.

### Questions

- **4.1** What does `MT4129` identify? What does `Rate: 400` correspond to in InfiniBand generation naming (HDR/NDR/XDR)?
- **4.2** mlx5_5 has a physical link (`LinkUp`) but is stuck in `Initializing` with LID 65535. What is missing, and which fabric component is responsible for fixing it?
- **4.3** Name the two things the Subnet Manager does that an Ethernet fabric does without a central controller. Name the NVIDIA product that runs and manages the SM at scale.
- **4.4** `mlx5_10`/`mlx5_11` show `enp...np0/np1` netdevs instead of `ibp...`. What does this tell you about those ports and their role in the node?
- **4.5** InfiniBand is described as "lossless by design". Which link-level mechanism makes it lossless, and why does RoCE need extra configuration to approximate this?

---

## Exercise 5 — Design a rail-optimized compute fabric

In the DGX SuperPOD reference architecture, a **Scalable Unit (SU)** is **32 DGX nodes**, which is 256 GPUs. The compute fabric is a **rail-optimized, non-blocking fat-tree**. NIC *i* of every node, which serves GPU *i*, connects to the leaf switch(es) of **rail *i***. Leaf switches are NVIDIA Quantum-2 **QM9700**, with **64 NDR 400 Gb/s ports**.

### Steps

1. Count the compute NIC ports in one SU: 32 nodes × 8 NICs.
2. Assign them to rails: how many ports land on each rail?
3. Make each leaf non-blocking: half its ports face down to nodes, half face up to spines. How many down-ports does a leaf have, and how many leaves does one SU need?
4. Compute the aggregate injection bandwidth of one node into the compute fabric, in Gb/s and GB/s.
5. Compute the aggregate NVLink bandwidth of one DGX H100: 8 GPUs × 900 GB/s.
6. A 2-level (leaf/spine) non-blocking fat-tree built from radix-*k* switches supports up to *k²/2* endpoints. Compute this for *k* = 64.

### Questions

- **5.1** How many leaf switches does one SU need, and why does that number match the GPU count of a node?
- **5.2** Why does rail alignment matter for NCCL? Consider which traffic stays within a single leaf hop.
- **5.3** What is the ratio between intra-node NVLink bandwidth (step 5) and inter-node fabric bandwidth (step 4)? What does it imply for how frameworks place tensor parallelism compared with data parallelism?
- **5.4** How many 400 Gb/s endpoints fit in a 2-level fat-tree of QM9700 switches? How many DGX nodes is that? What must you add beyond that size?
- **5.5** "Non-blocking" means a 1:1 ratio between down-links and up-links on each leaf. What happens to all-reduce performance with a 2:1 oversubscription?

---

## Exercise 6 — Configure lossless RoCE: PFC, ECN, DCQCN

On an Ethernet compute fabric with ConnectX NICs, RDMA traffic is typically carried in a dedicated traffic class. That class uses three mechanisms:

- **PFC** (Priority Flow Control, IEEE 802.1Qbb): a pause frame per priority, used as a safety net against drops.
- **ECN** (Explicit Congestion Notification): switches mark packets when queues build up.
- **DCQCN**: the receiving NIC turns ECN marks into **CNP** (Congestion Notification Packets), and the sender's NIC lowers its rate.

Read this host-side configuration. The output is representative of `mlnx_qos` from MLNX_OFED/DOCA-Host:

```bash
sudo mlnx_qos -i enp170s0f0np0 --trust dscp --pfc 0,0,0,1,0,0,0,0
```
```
DCBX mode: OS controlled
Priority trust state: dscp
...
PFC configuration:
	priority    0   1   2   3   4   5   6   7
	enabled     0   0   0   1   0   0   0   0
```

```bash
cat /sys/class/net/enp170s0f0np0/ecn/roce_np/enable/3
cat /sys/class/net/enp170s0f0np0/ecn/roce_rp/enable/3
```
```
1
1
```

```bash
ethtool -S enp170s0f0np0 | grep -E 'rx_prio3_pause|tx_prio3_pause|np_cnp_sent|rp_cnp_handled|out_of_buffer'
```
```
     rx_prio3_pause: 1842
     tx_prio3_pause: 12
     np_cnp_sent: 230411
     rp_cnp_handled: 198770
     out_of_buffer: 0
```

### Steps

1. Identify which priority carries RoCE traffic.
2. Identify which role each sysfs knob enables: `roce_np` (notification point) and `roce_rp` (reaction point).
3. Interpret the counters: is the fabric dropping packets, pausing, or reacting through rate control?

### Questions

- **6.1** Why is PFC enabled on **only one** priority instead of all eight?
- **6.2** What problems arise if a fabric relies only on PFC, with no ECN/DCQCN? Name at least two.
- **6.3** `np_cnp_sent` and `rp_cnp_handled` are large and `out_of_buffer` is 0. Is this healthy? Explain what the counters show.
- **6.4** NVIDIA Spectrum-X adds **adaptive routing with per-packet load balancing** across all paths, and BlueField-3 SuperNICs reorder packets at the receiver. Why is this better for AI collective traffic than classic ECMP flow hashing?
- **6.5** InfiniBand also has adaptive routing and congestion control, but it needs no PFC. Why?

---

## Exercise 7 — Expose RDMA and GPUs to a Kubernetes pod

On Kubernetes, the **NVIDIA Network Operator** deploys the RDMA device plugin and drivers, and the **GPU Operator** exposes GPUs. The RDMA resource name is defined in the Network Operator configuration. `rdma/rdma_shared_device_a` is the name used in its examples; check yours with `kubectl describe node`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nccl-allreduce-worker
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
      env:
        - name: NCCL_DEBUG
          value: "INFO"
        - name: NCCL_IB_HCA
          value: "mlx5_0"
      resources:
        limits:
          nvidia.com/gpu: 1
          rdma/rdma_shared_device_a: 1
        requests:
          nvidia.com/gpu: 1
          rdma/rdma_shared_device_a: 1
```

Inside the pod, NCCL logs show which transport it chose:

```
nccl-allreduce-worker:212:212 [0] NCCL INFO NET/IB : Using [0]mlx5_0:1/IB ; OOB eth0:10.244.3.17<0>
nccl-allreduce-worker:212:240 [0] NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
```

### Steps

1. Identify the line in the manifest that grants the pod access to an RDMA device.
2. Identify why `IPC_LOCK` is added.
3. In the NCCL log, find the transport (`NET/IB`) and the `GDRDMA` keyword.

### Questions

- **7.1** Why does an RDMA application need `IPC_LOCK`? Think of what memory registration does to pages.
- **7.2** What does `GDRDMA` in the NCCL log tell you about the data path between GPU0 and mlx5_0?
- **7.3** The log says `OOB eth0`. Is this the BMC network from Exercise 1? What is NCCL using it for?
- **7.4** If the log said `via NET/Socket` instead of `NET/IB`, which network is NCCL using? What would you expect to happen to all-reduce bandwidth?

---

## Exercise 8 — Scenario diagnosis and concept identification

For each scenario, identify the protocol, technology, or concept, and justify your answer in one or two sentences.

### Steps and questions

- **8.1** A 4-node training job runs `all_reduce_perf` from nccl-tests. One node shows `busbw` of about 360 GB/s with 8 NICs, while another shows about 315 GB/s. `ibstat` on the slow node shows one port at `Rate: 200`. What happened physically? Which tool inspects the cable/transceiver and the negotiated speed and width?
- **8.2** An all-reduce result is computed **inside the switches** as data flows through them, so less data crosses the fabric and latency drops. Name the technology and the switch family that provides it.
- **8.3** A cloud provider wants to run its storage virtualization, firewall, and telemetry agents on separate hardware, isolated from tenant code on the host CPU, so a compromised tenant cannot tamper with them. Which device fits, and what are its key components?
- **8.4** Training data is read from an NVMe-oF/parallel filesystem directly into GPU memory, avoiding a bounce buffer in system RAM. Name the technology and the API applications use.
- **8.5** A designer proposes connecting 72 GPUs into a single NVLink domain, so all of them can communicate at NVLink speed. Which component allows NVLink to extend beyond a single server, and in which NVIDIA system is this done?
- **8.6** The OOB switch fails. Which operations stop working, and which keep working: running training jobs, `ssh` to nodes, Redfish firmware updates?
- **8.7** For a compute fabric, the RoCE MTU is set to 4096 while the switch interfaces are at 1500. What symptom do you expect? Why do RDMA fabrics use jumbo frames (9000+ on the Ethernet side)?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **1.1** It gives each GPU its own 400 Gb/s path to the fabric through GPUDirect RDMA, with no sharing and no PCIe contention. It also enables the rail-optimized topology, where GPU *i* of every node meets GPU *i* of other nodes on the same leaf. Inter-node bandwidth then scales linearly with the GPU count.
- **1.2** The compute fabric and the storage fabric are physically separate networks with their own NICs, cables, and switches. Storage bursts cannot create congestion on the compute links that carry NCCL traffic.
- **1.3** The **OOB management network**, through the **BMC**: IPMI/Redfish, the remote console, and power control. It is independent of the host OS and of the in-band network.
- **1.4** The GPU-to-GPU collective traffic. Within one node it travels over **NVLink/NVSwitch** and never uses a NIC.

### Exercise 2

- **2.1** `transport` describes the RDMA transport protocol and verbs semantics, which are the InfiniBand transport (queue pairs, RC/UD, and so on). `link_layer` describes what carries it on the wire. RoCE means "the InfiniBand transport over Ethernet". RoCEv2 encapsulates it in UDP/IP.
- **2.2** GID index 1 is the RoCEv2 GID derived from the IPv4 address, so traffic is sent as routable RoCEv2 over IPv4. A native IB HCA normally uses GID index 0, the port GID made of the subnet prefix and the port GUID. Within an IB subnet, ports are addressed by **LIDs** assigned by the Subnet Manager, and GIDs are used for routing across subnets.
- **2.3** **Kernel bypass and zero-copy, with one-sided operations.** An RDMA WRITE is placed into the remote host's registered memory by the remote NIC. No interrupts, no copies, and no remote CPU involvement.
- **2.4** Soft-RoCE runs the whole transport (segmentation, ACKs, retransmissions, memory copies) on the **host CPU in the kernel**. The ConnectX-7 runs it in **NIC hardware**. That is the essence of RDMA offload.
- **2.5** UDP **4791**. RoCEv1 is an Ethernet-layer protocol (EtherType 0x8915), confined to a single L2 broadcast domain. RoCEv2 runs over IP, so it can cross L3 boundaries: routed leaf/spine fabrics, ECMP, and ECN in the IP header.

### Exercise 3

- **3.1** 900 GB/s ÷ 18 links = 50 GB/s bidirectional per link, which is **25 GB/s per direction**. `nvidia-smi nvlink -s` reports **26.562 GB/s** per link. That figure is per direction, but it is the raw link rate before protocol overhead, so it is slightly higher than the 25 GB/s you derive from the marketing aggregate. Both describe the same link; they just count overhead differently.
- **3.2** The links do not go GPU-to-GPU. All 18 links of each GPU go to the **NVSwitch** chips (four 3rd-gen NVSwitch chips on DGX H100), and the switches give any-to-any connectivity at full bandwidth. Every pair therefore "sees" all 18 links' worth of bandwidth.
- **3.3** With GPUDirect RDMA, the peer-to-peer DMA goes NIC ↔ PCIe switch ↔ GPU, without touching the CPU root complex or system memory. If the path is `SYS`, the traffic must cross the CPU's inter-socket interconnect. Bandwidth drops and latency rises, or the driver falls back to staging through host memory.
- **3.4** The CPU's PCIe host bridge and, depending on placement, the inter-socket link. You would also be stealing bandwidth from the GPU that "owns" mlx5_3 and breaking rail alignment.

### Exercise 4

- **4.1** `MT4129` is the PCI device ID family of the **ConnectX-7**. `Rate: 400` is **NDR** (400 Gb/s, 4× lanes at 100 Gb/s). HDR is 200 Gb/s and XDR is 800 Gb/s.
- **4.2** The port has no LID assigned (65535 is the unassigned/permissive value) and no `SM lid` (0). The **Subnet Manager** has not yet configured it, or cannot reach it. A port goes `Initializing → Armed → Active` only after the SM programs it. Check the SM (`sminfo`, UFM logs) and the switch port.
- **4.3** The SM (1) **discovers the topology and assigns LIDs** to every port, and (2) **computes routes and programs the forwarding tables** of every switch. It also handles partitions (P_Keys) and QoS/SL-to-VL mappings. At scale, this is run with **NVIDIA UFM (Unified Fabric Manager)**; OpenSM is the open-source SM.
- **4.4** They are **Ethernet-mode** ports, with `np0/np1` showing the two ports of one dual-port adapter. They are the **storage and in-band management** NICs, not part of the InfiniBand compute fabric. ConnectX-7 VPI can run either protocol.
- **4.5** **Credit-based link-level flow control.** A sender transmits only when the receiver has advertised buffer credits, so switch buffers never overflow. Ethernet is best-effort and drops on overflow. RoCE needs PFC and/or ECN-based congestion control (DCQCN), or a fabric like Spectrum-X, to avoid drops and retransmissions, which RDMA handles badly.

### Exercise 5

Calculations:

- Step 1: 32 × 8 = **256 ports**.
- Step 2: 256 / 8 rails = **32 ports per rail**.
- Step 3: 64-port leaf → **32 down / 32 up**, so 1 leaf per rail, which is **8 leaves per SU**.
- Step 4: 8 × 400 Gb/s = **3200 Gb/s = 400 GB/s** per node.
- Step 5: 8 × 900 GB/s = **7.2 TB/s** aggregate NVLink bandwidth.
- Step 6: 64² / 2 = **2048 endpoints**.

Answers:

- **5.1** **8 leaves**, one per rail. There are 8 rails because there are 8 GPUs/NICs per node: rail *i* gathers NIC *i* from all 32 nodes, which is exactly 32 down-ports.
- **5.2** NCCL's ring/tree algorithms pair GPU *i* on one node with GPU *i* on other nodes. In a rail-optimized fabric, that traffic stays on **one leaf switch** (one hop) inside an SU, so latency and spine load are minimal. Cross-rail data movement is done over NVLink inside the node first, which NCCL's "PXN" feature exploits.
- **5.3** 7.2 TB/s ÷ 0.4 TB/s = **18×**. Communication-heavy **tensor parallelism** (and expert parallelism) is kept **inside the NVLink domain**. **Data parallelism and pipeline parallelism**, which exchange less data or exchange it less frequently, are spread across nodes over the NIC fabric.
- **5.4** **2048 endpoints**, which is 2048 / 8 = **256 DGX nodes** (8 SUs). Beyond that you add a **third tier** (core switches) to keep it non-blocking. This is what large SuperPOD designs do.
- **5.5** In 2:1 oversubscription, the up-links carry only half the bandwidth of the down-links. Collectives that cross leaves congest at the spine, `busbw` falls (up to about half), and tail latency grows. Synchronous training is limited by its slowest link, so the entire job slows down.

### Exercise 6

- **6.1** PFC pauses a whole priority. Enabling it on all priorities would let any congestion freeze all traffic, including TCP and management traffic, and would maximize the risk of head-of-line blocking and **PFC deadlocks/pause storms**. RDMA is isolated in its own lossless class (priority 3 here, selected by DSCP), and everything else stays lossy.
- **6.2** Without ECN/DCQCN, the pauses do the throttling. That causes:
  - **Head-of-line blocking:** innocent flows sharing the priority are paused.
  - **Congestion spreading:** pauses propagate upstream hop by hop, creating a "congestion tree".
  - **Possible deadlocks** in cyclic buffer dependencies.
  - **Pause storms** from a misbehaving NIC.

  DCQCN lowers sender rates *before* buffers fill, so PFC rarely triggers.
- **6.3** Yes, it is healthy. Switches mark ECN at priority 3. The receiving NIC (notification point) sends CNPs (`np_cnp_sent`), and the sending NIC (reaction point) reduces its rate in response (`rp_cnp_handled`). PFC pauses are few compared with CNPs, so they act only as a safety net. `out_of_buffer: 0` means the NIC never dropped data for lack of receive buffers. Congestion is being managed by rate control, not by loss.
- **6.4** AI collectives produce a **small number of very large, long-lived "elephant" flows** with low entropy. ECMP hashes each flow onto one path, so collisions leave some links overloaded and others idle, and throughput becomes unpredictable. Per-packet adaptive routing sprays packets across all equal-cost paths based on real-time load. The SuperNIC restores order at the receiver (direct data placement), giving higher effective bandwidth and much lower tail latency, while tenants and jobs are isolated from each other's noise.
- **6.5** InfiniBand's **credit-based flow control** is lossless natively at the link layer, so pause frames are unnecessary. Its adaptive routing (selected by the SM/switches) and its congestion control (FECN/BECN marking with source throttling) work on top of a fabric that never drops packets due to buffer overflow.

### Exercise 7

- **7.1** Memory registration (`ibv_reg_mr`) **pins** pages so the OS cannot swap or move them while the NIC DMA's into them. Pinning is limited by `RLIMIT_MEMLOCK`, and `CAP_IPC_LOCK` lets the process lock as much memory as it needs. Without it, registrations fail with errors such as `Cannot allocate memory`.
- **7.2** **GPUDirect RDMA** is active. mlx5_0 reads and writes GPU0's HBM directly over PCIe, with no staging through host memory and no CPU copy.
- **7.3** No. Here "OOB" is NCCL's term for its **bootstrap/control channel**: a regular TCP socket over the pod network (`eth0`) that is used to exchange connection info such as QP numbers and GIDs before the RDMA data path is set up. It is unrelated to the BMC network.
- **7.4** NCCL fell back to **TCP sockets** over the pod's regular network, usually because no RDMA device was visible (a missing resource request, NAD, or driver). Bandwidth would drop drastically, to a few GB/s at best instead of about 45–49 GB/s per NIC, and CPU usage would rise sharply.

### Exercise 8

- **8.1** One link **negotiated at half speed** (200 Gb/s), typically due to a faulty or dirty cable or transceiver, a bad port, or a width degradation. Inspect it with **`mlxlink -d <device>`**, which shows speed, width, FEC, BER, and module info. For the fabric-wide view, use **`ibdiagnet`** and `iblinkinfo`. Because every GPU waits for the slowest participant, one degraded link lowers the whole job's `busbw`.
- **8.2** **NVIDIA SHARP** (Scalable Hierarchical Aggregation and Reduction Protocol). It is in-network computing on **Quantum InfiniBand** switches (SHARPv3 on Quantum-2), and NCCL uses it through the SHARP plugin (CollNet/NVLS-tree paths).
- **8.3** A **BlueField DPU** (for example BlueField-3). It combines a ConnectX network engine, programmable **Arm cores**, its own memory and OS, and hardware accelerators for crypto, storage (NVMe-oF/SNAP), and packet processing, programmed through **DOCA**. It runs infrastructure services in a separate trust domain from the host. This offloads the host CPU and isolates the control plane from tenants.
- **8.4** **GPUDirect Storage (GDS)**, through the **cuFile API** (`cuFileRead`/`cuFileWrite`). It creates a direct DMA path between storage (local NVMe or NIC-attached remote storage) and GPU memory.
- **8.5** **NVLink Switch** in an external NVLink switch tray, together with 5th-gen NVLink. It is used in **GB200 NVL72**, which joins 72 Blackwell GPUs into one NVLink domain, with 1.8 TB/s per GPU on NVLink 5. On DGX H100/B200, NVLink stays inside the 8-GPU node.
- **8.6** **Stop:** BMC functions such as Redfish/IPMI, the remote console, power cycling, and BMC-driven firmware updates, as well as hardware telemetry collected through the BMC. **Keep working:** running training jobs, which use the compute fabric, and `ssh`, which uses the in-band network. The networks are independent, so an OOB failure is an operations problem, not a workload outage.
- **8.7** Frames larger than the path MTU are **dropped**. Connections may establish (small control packets fit), but RDMA transfers then stall, time out, and retry (`transport retry counter exceeded` errors). Jumbo frames (9000 bytes on Ethernet, carrying an RDMA MTU of 4096) reduce per-packet overhead and the packet rate the NIC and switches must process, which increases effective bandwidth for large messages. The MTU must be **consistent end to end**: the NIC, every switch port, and the RoCE MTU.

</details>