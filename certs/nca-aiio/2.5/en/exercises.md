# Guided Exercises: Topic 2.5: Key Components and Considerations of an Accelerated Infrastructure Cluster

**Certification:** NCA-AIIO · **Topic weight:** 4.0

These exercises take you from the anatomy of a single accelerated node, through the intra-node and inter-node fabrics, to how a full scalable unit is designed, powered, and consumed by a workload scheduler. Every step can be done in one of two ways:

- **Hands-on track:** you have shell access to a multi-GPU node, such as a DGX H100/B200, an HGX-based OEM server, or a cloud instance with 8 SXM GPUs and InfiniBand/RoCE NICs.
- **Paper track:** you do not have that hardware. Each step includes a representative output block. Read it and answer the questions from it.

Reference sources used throughout:

- DGX H100 component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- DGX SuperPOD B200 Reference Architecture: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Magnum IO network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- BlueField DPU offload and isolation: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/

---

## Exercise 1: Anatomy of an accelerated node

An AI cluster is built from nodes whose internal design is as important as the network between them. Start by inventorying one node.

### Step 1.1: Enumerate the GPUs

```bash
nvidia-smi -L
```

Representative output (DGX H100):

```
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3a1f...)
GPU 1: NVIDIA H100 80GB HBM3 (UUID: GPU-8c22...)
GPU 2: NVIDIA H100 80GB HBM3 (UUID: GPU-91d0...)
GPU 3: NVIDIA H100 80GB HBM3 (UUID: GPU-04be...)
GPU 4: NVIDIA H100 80GB HBM3 (UUID: GPU-77c1...)
GPU 5: NVIDIA H100 80GB HBM3 (UUID: GPU-e5a9...)
GPU 6: NVIDIA H100 80GB HBM3 (UUID: GPU-2bd4...)
GPU 7: NVIDIA H100 80GB HBM3 (UUID: GPU-c018...)
```

### Step 1.2: Enumerate the PCIe devices that make up the node

```bash
lspci | grep -iE "nvidia|mellanox"
```

Representative output (trimmed):

```
18:00.0 Bridge: NVIDIA Corporation Device 22a3 (rev a1)
...
1b:00.0 3D controller: NVIDIA Corporation GH100 [H100 SXM5 80GB] (rev a1)
...
1a:00.0 Infiniband controller: Mellanox Technologies MT2910 Family [ConnectX-7]
...
a9:00.0 Ethernet controller: Mellanox Technologies MT2910 Family [ConnectX-7]
a9:00.1 Ethernet controller: Mellanox Technologies MT2910 Family [ConnectX-7]
```

Count each class:

```bash
lspci | grep -ic "3D controller: NVIDIA"
lspci | grep -i "Bridge: NVIDIA" | wc -l
lspci | grep -i mellanox | wc -l
```

On a DGX H100, expect 8 GPUs and 4 NVSwitch bridge entries. The ConnectX count depends on whether the storage/in-band adapters are ConnectX-7 or BlueField-3.

### Step 1.3: Fill in the component table

Use the DGX H100 user guide to complete this table. Then repeat it for DGX B200 using the SuperPOD B200 RA.

| Component | DGX H100 | DGX B200 |
|---|---|---|
| GPUs / total GPU memory | | |
| NVLink generation / per-GPU NVLink bandwidth | | |
| NVSwitch chips | | |
| Compute fabric NICs | | |
| Storage / in-band NICs | | |
| CPUs | | |
| System memory | | |
| OS drives / internal data cache | | |
| Max system power | | |
| Out-of-band management | | |

**Questions:**

1. Why does a DGX node carry **one compute-fabric NIC per GPU** instead of one or two shared NICs for the whole node?
2. The node has 8× NVMe U.2 drives that are separate from the OS drives. What is their role in a training cluster, and why are they not a replacement for shared storage?
3. The NVSwitch chips appear in `lspci` as "Bridge" devices. What do they connect, and what traffic never touches them?

---

## Exercise 2: Intra-node topology (NVLink, PCIe, NUMA)

Topology determines which GPU talks to which NIC and CPU at full speed. Schedulers, NCCL, and you all need to read it.

### Step 2.1: Print the topology matrix

```bash
nvidia-smi topo -m
```

Representative output (DGX H100, trimmed to 4 GPUs and 4 NICs):

```
        GPU0  GPU1  GPU2  GPU3  NIC0  NIC1  NIC2  NIC3  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  PXB   NODE  NODE  NODE  0-55,112-167  0
GPU1    NV18   X    NV18  NV18  NODE  PXB   NODE  NODE  0-55,112-167  0
GPU2    NV18  NV18   X    NV18  NODE  NODE  PXB   NODE  0-55,112-167  0
GPU3    NV18  NV18  NV18   X    NODE  NODE  NODE  PXB   0-55,112-167  0
NIC0    PXB   NODE  NODE  NODE   X    NODE  NODE  NODE
...

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
  ...
```

GPUs 4–7 show NUMA affinity `1` and CPU cores `56-111,168-223`.

**Questions:**

4. What does `NV18` mean, and why is it the same for every GPU pair?
5. Which NIC should a process driving GPU2 use for inter-node traffic, and why?
6. A job pins a data-loader process for GPU5 to CPU cores 0–15. What is the penalty, and which column reveals the mistake?

### Step 2.2: Check NVLink state and speed

```bash
nvidia-smi nvlink -s -i 0
```

Representative output:

```
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3a1f...)
	 Link 0: 26.562 GB/s
	 Link 1: 26.562 GB/s
	 ...
	 Link 17: 26.562 GB/s
```

Check the error counters too:

```bash
nvidia-smi nvlink -e -i 0
```

**Questions:**

7. Multiply the per-link figure by the number of links. How does the result relate to the "900 GB/s per GPU" marketing figure for fourth-generation NVLink?
8. If `nvidia-smi nvlink -s` shows a link as `<inactive>`, what do you expect to happen to all-reduce performance inside the node?
9. Fifth-generation NVLink in Blackwell doubles per-GPU bandwidth to 1.8 TB/s. For which parallelism strategy, tensor parallel or data parallel, does this matter most, and why?

---

## Exercise 3: The four networks of an AI cluster

The SuperPOD reference architecture separates traffic into distinct fabrics. Identify each one on a real node.

### Step 3.1: Map RDMA devices to network interfaces

```bash
ibdev2netdev
```

Representative output:

```
mlx5_0 port 1 ==> ibp26s0 (Up)
mlx5_1 port 1 ==> ibp60s0 (Up)
mlx5_2 port 1 ==> ibp77s0 (Up)
mlx5_3 port 1 ==> ibp94s0 (Up)
mlx5_4 port 1 ==> ibp156s0 (Up)
mlx5_5 port 1 ==> ibp176s0 (Up)
mlx5_6 port 1 ==> ibp192s0 (Up)
mlx5_7 port 1 ==> ibp206s0 (Up)
mlx5_8 port 1 ==> enp170s0f0np0 (Up)
mlx5_9 port 1 ==> enp170s0f1np1 (Up)
mlx5_10 port 1 ==> enp41s0f0np0 (Up)
mlx5_11 port 1 ==> enp41s0f1np1 (Up)
```

### Step 3.2: Inspect a compute-fabric port

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
	Node GUID: 0xa088c20300e1b2c4
	System image GUID: 0xa088c20300e1b2c4
	Port 1:
		State: Active
		Physical state: LinkUp
		Rate: 400
		Base lid: 112
		LMC: 0
		SM lid: 1
		Capability mask: 0xa651e848
		Port GUID: 0xa088c20300e1b2c4
		Link layer: InfiniBand
```

### Step 3.3: Reach the out-of-band network

The BMC sits on its own 1 GbE port. Query it through Redfish from a management host. Do not run this from the node itself.

```bash
curl -sk -u admin:'<password>' https://<bmc-ip>/redfish/v1/Systems | python3 -m json.tool
```

### Step 3.4: Classify

Fill in this table:

| Network | Purpose | Typical technology | Devices on this node |
|---|---|---|---|
| Compute fabric (east-west) | | | |
| Storage fabric | | | |
| In-band management | | | |
| Out-of-band management | | | |

**Questions:**

10. Why is GPU-to-GPU training traffic kept on a network physically separate from storage traffic?
11. `Link layer: InfiniBand` and `SM lid: 1` appear in the `ibstat` output. What is the Subnet Manager, and where does it typically run in a SuperPOD?
12. A node's OS hangs and SSH is unreachable. Which network do you still have, and what can you do through it?

---

## Exercise 4: Designing a rail-optimized compute fabric (paper exercise)

You will size the compute fabric for a cluster built from scalable units (SUs) of **32 DGX nodes**, each with **8 × 400 Gb/s** compute ports. The fabric uses InfiniBand NDR switches with **64 × 400 Gb/s ports** each, such as the QM9700, in a **non-blocking two-tier fat tree**.

### Step 4.1: Understand rails

In a rail-optimized design, **GPU/NIC *n* of every node connects to leaf switch *n*** of the SU. With 8 GPUs per node, each SU has 8 rails.

Draw it: 32 nodes on the bottom, 8 leaf switches above them, with node *k*'s NIC0 going to leaf 0, NIC1 to leaf 1, and so on.

### Step 4.2: Size one SU

Compute:

- Downlinks per leaf switch (node-facing ports)
- Uplinks per leaf needed for non-blocking (1:1)
- Do the downlinks plus uplinks fit in 64 ports?
- Leaf switches per SU
- Node-to-leaf cables per SU

### Step 4.3: Scale to 4 SUs

Compute:

- Total leaf switches
- Total leaf uplinks
- Spine switches required if each spine uses all 64 ports facing leaves

### Step 4.4: Compare with the reference architecture

Open the SuperPOD B200 RA and compare your numbers with its compute-fabric section. Note any differences, such as ports reserved for management appliances (UFM) or nodes removed from the full count.

**Questions:**

13. In a rail-optimized fabric, GPU3 on node 1 sends to GPU3 on node 20 in the same SU. How many switch hops does that take?
14. GPU3 on node 1 now needs data from GPU5 on node 20. What can the node do so this traffic still stays on a single rail?
15. Why does the RA build the cluster from fixed SUs instead of adding nodes one at a time?
16. What does **SHARP** do in the switches, and which collective benefits most?

---

## Exercise 5: Measuring the fabrics with NCCL tests

Specifications are claims; collective benchmarks are evidence.

### Step 5.1: Build the NCCL tests

```bash
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests
make MPI=1 MPI_HOME=/usr/mpi/gcc/openmpi-4.1.7a1 CUDA_HOME=/usr/local/cuda
```

Adjust `MPI_HOME` to the MPI installation on your system.

### Step 5.2: Intra-node all-reduce (NVLink/NVSwitch only)

```bash
./build/all_reduce_perf -b 8 -e 8G -f 2 -g 8
```

Representative tail of the output (DGX H100):

```
#       size         count      type   redop    root     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)
  1073741824     268435456     float     sum      -1   4012.5  267.60  468.30      0
  2147483648     536870912     float     sum      -1   7951.8  270.06  472.61      0
  4294967296    1073741824     float     sum      -1  15855.0  270.89  474.06      0
  8589934592    2147483648     float     sum      -1  31688.2  271.08  474.39      0
# Avg bus bandwidth    : 312.48
```

### Step 5.3: Inter-node all-reduce (compute fabric)

Run on 2 nodes with 16 GPUs total, one rank per GPU:

```bash
mpirun -np 16 -N 8 -H node01:8,node02:8 \
  -x NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7 \
  -x NCCL_DEBUG=INFO \
  ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 1
```

In the `NCCL_DEBUG=INFO` log, look for lines that confirm the transport:

```
NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
```

**Questions:**

17. For all-reduce, NCCL reports `busbw = algbw × 2(n−1)/n`. Verify this with the 8 GiB row from Step 5.2, where n = 8. Why does NCCL report bus bandwidth at all?
18. The compute fabric gives each node 8 × 400 Gb/s. Convert that to GB/s. Would you expect inter-node busbw to be above or below the intra-node figure, and why?
19. What does `GDRDMA` in the NCCL log tell you? What would `NET/IB/0` without `GDRDMA` imply?
20. Inter-node busbw on the 2-node test is roughly one-eighth of the expected value, but intra-node results are normal. Name two causes you would check first, and the command for each.

---

## Exercise 6: The I/O path: GPUDirect and the DPU

Magnum IO technologies remove the CPU and system memory from the data path. The BlueField DPU moves infrastructure services off the host.

### Step 6.1: Verify GPUDirect RDMA support

```bash
lsmod | grep -E "nvidia_peermem|nv_peer_mem"
```

Representative output:

```
nvidia_peermem         16384  0
nvidia               9719808  ... nvidia_uvm,nvidia_peermem,nvidia_modeset
ib_core               434176  9 rdma_cm,ib_ipoib,nvidia_peermem,...
```

### Step 6.2: Verify GPUDirect Storage support (if installed)

```bash
/usr/local/cuda/gds/tools/gdscheck -p
```

Representative output (trimmed):

```
 GDS release version: 1.9.0.20
 nvidia_fs version:  2.18 libcufile version: 2.12
 ...
 ============
 DRIVER CONFIGURATION:
 ============
 NVMe               : Supported
 NVMeOF             : Unsupported
 SCSI               : Unsupported
 ScaleFlux CSD      : Unsupported
 NVMesh             : Unsupported
 DDN EXAScaler      : Supported
 IBM Spectrum Scale : Unsupported
 NFS                : Supported
 WekaFS             : Supported
 ...
```

### Step 6.3: Identify the DPU (if present)

```bash
lspci | grep -i bluefield
```

Representative output:

```
a9:00.0 Ethernet controller: Mellanox Technologies MT43244 BlueField-3 integrated ConnectX-7 network controller
a9:00.1 Ethernet controller: Mellanox Technologies MT43244 BlueField-3 integrated ConnectX-7 network controller
a9:00.2 DMA controller: Mellanox Technologies MT43244 BlueField-3 SoC Management Interface
```

**Questions:**

21. Trace the data path of a NIC receiving a tensor for GPU0, first **without** and then **with** GPUDirect RDMA. Which hops disappear?
22. GPUDirect Storage solves a similar problem for a different flow. Which flow, and which training phase benefits?
23. According to the BlueField offload article, what are three classes of infrastructure work that move from the host CPU to the DPU?
24. Beyond freeing CPU cycles, what **security** property does running infrastructure services on the DPU provide in a multi-tenant cluster?

---

## Exercise 7: Power, cooling, and facility budget (paper exercise)

Accelerated clusters are often limited by the data center before they are limited by the budget.

Use these data:

- DGX H100 max system power: ~10.2 kW
- DGX B200 max system power: ~14.3 kW
- The existing data hall supports **40 kW per rack** with air cooling
- Plan one SU of **32 nodes**

### Step 7.1: Compute

1. Total compute-node power for one SU of DGX H100 and one SU of DGX B200.
2. Maximum DGX nodes per 40 kW rack for each model.
3. Racks needed for compute nodes alone for each model.

### Step 7.2: Add the rest

List at least four other components in an SU that consume power and rack space, besides the DGX nodes.

**Questions:**

25. Why do designers size against **max** power instead of typical power?
26. When per-rack density keeps rising, what cooling change do higher-density designs move toward, and why?
27. A facility can deliver the power but has no free floor space. Which of your calculations changes, and what trade-off appears in the cabling?

---

## Exercise 8: Consuming the cluster from Kubernetes

The hardware is only useful when a scheduler exposes it correctly. On Kubernetes, the **NVIDIA GPU Operator** manages the driver, container toolkit, device plugin, and DCGM exporter. The **NVIDIA Network Operator** manages OFED/DOCA drivers, RDMA device plugins, and secondary networks.

### Step 8.1: Check what a GPU node advertises

```bash
kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable}' | python3 -m json.tool
```

Representative output:

```
{
    "cpu": "224",
    "ephemeral-storage": "1797089689052",
    "hugepages-1Gi": "0",
    "hugepages-2Mi": "0",
    "memory": "2113396860Ki",
    "nvidia.com/gpu": "8",
    "pods": "110",
    "rdma/rdma_shared_device_a": "63"
}
```

```bash
kubectl get node gpu-node-01 --show-labels | tr ',' '\n' | grep nvidia.com
```

Representative output (trimmed):

```
nvidia.com/gpu.count=8
nvidia.com/gpu.memory=81559
nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
nvidia.com/mig.capable=true
```

### Step 8.2: Request a full node for a distributed training worker

The RDMA resource name depends on how the Network Operator's RDMA shared device plugin is configured. `rdma/rdma_shared_device_a` is a common default in its examples.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: trainer-worker-0
  labels:
    app: trainer
spec:
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
  containers:
    - name: trainer
      image: nvcr.io/nvidia/pytorch:24.10-py3
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      env:
        - name: NCCL_DEBUG
          value: "INFO"
        - name: NCCL_IB_HCA
          value: "mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7"
      resources:
        limits:
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

```bash
kubectl apply -f trainer-worker-0.yaml
kubectl exec trainer-worker-0 -- nvidia-smi topo -m
kubectl exec trainer-worker-0 -- ls /dev/infiniband
```

The last command should list `uverbs*` devices. If the directory is missing, the RDMA device was not injected.

**Questions:**

28. Why does the Pod request **all 8 GPUs** instead of, for example, 2 GPUs on each of 4 nodes?
29. Why does the container need `IPC_LOCK` and a memory-backed `/dev/shm`?
30. Which component exports GPU health and utilization metrics to Prometheus, and which Kubernetes operator installs it?

---

## Exercise 9: Integrated troubleshooting scenario

A 4-node training job reports 30% lower throughput than last week. You collect this data:

```
$ nvidia-smi nvlink -s -i 6 | grep -c inactive
0

$ ibstat mlx5_5 | grep -E "State|Rate"
		State: Active
		Physical state: LinkUp
		Rate: 200

$ ibstat mlx5_2 | grep -E "State|Rate"
		State: Active
		Physical state: LinkUp
		Rate: 400

$ dcgmi diag -r 1
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
| Deployment                | Pass                                           |
+---------------------------+------------------------------------------------+
```

**Questions:**

31. Which component is the most likely cause, and what physical issues typically produce this symptom?
32. Why does one degraded rail slow down the **entire** job, not just GPU5's traffic?
33. What would you do operationally while the fix is pending, and what should you change in monitoring so this is caught before users notice?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Component table**

| Component | DGX H100 | DGX B200 |
|---|---|---|
| GPUs / memory | 8× H100 SXM5, 640 GB HBM3 total | 8× B200, 1,440 GB HBM3e total |
| NVLink | 4th gen, 900 GB/s per GPU | 5th gen, 1.8 TB/s per GPU (14.4 TB/s aggregate) |
| NVSwitch | 4 chips | 2 chips |
| Compute NICs | 8× single-port ConnectX-7, 400 Gb/s, via 4 OSFP cages | 8× single-port ConnectX-7 VPI, 400 Gb/s, via 4 OSFP cages |
| Storage/in-band | 2× dual-port ConnectX-7 (or BlueField-3) | 2× dual-port BlueField-3 DPU |
| CPUs | 2× Xeon Platinum 8480C, 112 cores | 2× Xeon Platinum 8570, 112 cores |
| System memory | 2 TB | up to 4 TB |
| Storage | OS 2× 1.9 TB NVMe M.2; data 8× 3.84 TB NVMe U.2 | same layout |
| Max power | ~10.2 kW | ~14.3 kW |
| OOB | BMC, 1 GbE RJ45 | BMC, 1 GbE RJ45 |

Check the exact figures against the current product documentation; configurations are revised between SKUs.

1. In multi-node training, each GPU exchanges gradients and activations with its peers on other nodes. One NIC per GPU gives each GPU a dedicated 400 Gb/s path on its own PCIe switch, so there is no contention for a shared NIC or the CPU's PCIe root. It also enables GPUDirect RDMA on a short PCIe path, and it maps directly onto the 8 rails of a rail-optimized fabric.

2. They form a local, high-throughput **cache**, for example for datasets staged by the job or for checkpoint scratch. They are per-node, not shared or replicated, and they are lost if the node is reimaged. The authoritative copy of datasets and checkpoints must live on the shared storage fabric.

3. NVSwitch interconnects the NVLink ports of all 8 GPUs, giving all-to-all, full-bandwidth GPU-to-GPU communication inside the node. Traffic that leaves the node never touches NVSwitch, because it goes GPU → PCIe → NIC → fabric. In the DGX H100/B200 generation, inter-node traffic goes over InfiniBand/Ethernet. The rack-scale NVLink switch systems of GB200 NVL72 are a different design.

### Exercise 2

4. `NV18` means the pair is connected through a bonded set of 18 NVLink links. Every GPU routes all of its 18 links through the NVSwitch chips, so every pair sees the same full bandwidth. The NVSwitch fabric is a non-blocking all-to-all, not a ring or mesh.

5. NIC2 (`mlx5_2`) is the right choice. It is `PXB` to GPU2, meaning it sits under the same PCIe switch hierarchy, so the RDMA path does not cross the CPU host bridge. Some systems report this relationship as `PIX`; either way it is the closest NIC. NCCL makes this choice automatically from the topology. That rail is also the rail GPU2 is wired to in the fabric.

6. GPU5 has NUMA affinity 1 (cores 56–111 and 168–223). Pinning to cores 0–15, which are on NUMA 0, forces host-to-device copies across the inter-socket link (`SYS` path). That adds latency, consumes inter-socket bandwidth, and uses memory on the wrong NUMA node. The `CPU Affinity` and `NUMA Affinity` columns reveal it.

7. 18 × 26.562 GB/s ≈ 478 GB/s per direction. nvidia-smi reports raw link signaling; the nominal data rate is about 25 GB/s per direction per link, so 18 × 25 = 450 GB/s. Doubled for both directions, that gives the **900 GB/s** bidirectional figure.

8. That GPU's NVLink bandwidth drops. Because a ring or tree all-reduce runs at the speed of its slowest participant, **the whole node's collective slows down**. Also run `nvidia-smi nvlink -e` and check the logs for XID errors; the node should be drained and serviced.

9. **Tensor parallelism**. It splits individual layers across GPUs and exchanges activations and partial results at every layer, in the forward and backward pass. That makes it extremely bandwidth- and latency-sensitive, which is why it is kept inside the NVLink domain. Data parallelism communicates once per step (gradient all-reduce) and tolerates the slower inter-node fabric better.

### Exercise 3

**Network classification**

| Network | Purpose | Technology | Devices |
|---|---|---|---|
| Compute | GPU-to-GPU collectives across nodes | InfiniBand NDR 400 Gb/s (or Spectrum-X Ethernet/RoCE) | `mlx5_0`–`mlx5_7` (`ibp*`) |
| Storage | Dataset reads, checkpoint writes to shared parallel FS | 200/400 Gb/s Ethernet or IB | dual-port ConnectX-7 / BlueField-3 (`enp*` here) |
| In-band mgmt | SSH, job scheduler, provisioning, monitoring, container pulls | Ethernet | one port of the dual-port adapters, or the host 10 GbE |
| OOB mgmt | BMC: power, console, firmware, sensors | 1 GbE | BMC RJ45 port |

The exact port-to-role assignment is site-defined; the RA documents the recommended mapping.

10. Isolation. Collective operations are synchronized: every step waits for the slowest transfer. Bursty storage traffic, such as a 30-node checkpoint write, would cause congestion and jitter on shared links and stall all GPUs. Separate fabrics also let each one be sized independently, with a non-blocking compute fabric and a storage fabric sized to throughput needs.

11. The Subnet Manager (SM) discovers the InfiniBand fabric, assigns LIDs, and computes and programs forwarding tables. `SM lid: 1` is the LID of the master SM. In SuperPOD designs it typically runs on **UFM** (Unified Fabric Manager) appliances, with redundancy, rather than on the switches or compute nodes.

12. You still have the **out-of-band** network to the BMC. Through it you can open a serial-over-LAN or remote console, power-cycle the node, read hardware sensors and the event log, and update firmware, all independently of the host OS. Redfish and IPMI are the usual interfaces.

### Exercise 4

**Step 4.2:** Each leaf has 32 downlinks, one per node on that rail. Non-blocking requires 32 uplinks. 32 + 32 = 64, which uses exactly the switch's 64 ports. There is 1 leaf per rail, so **8 leaf switches per SU**, and 32 × 8 = **256 node-to-leaf cables**.

**Step 4.3:** 4 SUs × 8 = **32 leaf switches**, with 32 × 32 = **1,024 uplinks**. 1,024 / 64 = **16 spine switches**.

**Step 4.4:** The published RA differs in details. For example, it reserves ports or a node slot for UFM and management appliances, so a 4-SU build has slightly fewer than 128 DGX nodes. The SU and rail structure is the same.

13. One hop through a single switch. Both endpoints are on rail 3, so the traffic goes NIC → leaf 3 → NIC and never reaches a spine.

14. The node first moves the data over NVLink to GPU3 on the sending node (or GPU5 on the receiving side). The transfer then happens on a single rail. NCCL's PXN (PCIe × NVLink) feature does exactly this, trading a cheap NVLink hop for avoiding a spine traversal.

15. A fixed, validated building block makes cabling, power, cooling, switch port counts, and performance predictable and repeatable. You scale by adding identical SUs to a spine layer sized for the target, which avoids re-cabling the fabric and creating uneven, blocking topologies.

16. **SHARP** (Scalable Hierarchical Aggregation and Reduction Protocol) performs the reduction arithmetic **inside the InfiniBand switches** as data flows through them. That reduces the data each endpoint must send and receive, and lowers latency. **All-reduce** benefits most, because it is the dominant collective in data-parallel training.

### Exercise 5

17. 271.08 × 2 × 7 / 8 = 271.08 × 1.75 ≈ **474.4 GB/s**, which matches the reported value. Algorithm bandwidth (size/time) depends on the collective and the number of ranks. Bus bandwidth normalizes it to the speed actually achieved on the hardware links, so you can compare it directly with the link specification (≈450–480 GB/s per direction for H100 NVLink) and across different GPU counts.

18. 8 × 400 Gb/s = 3,200 Gb/s = **400 GB/s** per node. Expect inter-node busbw **below** the intra-node figure. A 2-node all-reduce is bound by the slower link, which is the 400 GB/s network minus protocol overhead (often in the high 300s GB/s on healthy NDR), not the ~450+ GB/s per-direction NVLink path.

19. `GDRDMA` means **GPUDirect RDMA** is in use: the NIC reads and writes GPU memory directly over PCIe. `NET/IB` without it means data is staged through host memory, which costs extra copies, CPU memory bandwidth, and latency. That usually means `nvidia_peermem` is missing or the ACS/IOMMU configuration is wrong.

20. Common first checks:
   - **NCCL using only one NIC, or falling back to TCP sockets.** Check the `NCCL_DEBUG=INFO` output for `NET/Socket` and for which HCAs are listed, and check the `NCCL_IB_HCA` setting.
   - **Ports down or degraded.** Run `ibstat` and `ibdev2netdev` on both nodes.
   - **GPUDirect RDMA disabled.** Run `lsmod | grep nvidia_peermem`.
   - Bandwidth around one-eighth of expected strongly suggests that only one of the 8 rails is in use.

### Exercise 6

21. **Without GPUDirect RDMA:** NIC → PCIe → CPU root complex → system memory (bounce buffer) → CPU/driver copy → PCIe → GPU memory. **With GPUDirect RDMA:** NIC → PCIe switch → GPU memory, peer-to-peer. The system memory bounce buffer, the extra copy, and the CPU involvement disappear, and the traffic can stay under the shared PCIe switch.

22. **Storage ↔ GPU memory**: NVMe or a remote parallel filesystem reads go directly into GPU memory without a CPU bounce buffer. Data loading and checkpoint save/restore benefit, especially for large datasets that cannot be cached locally.

23. Examples from the BlueField article: **networking** (virtual switching/OVS, overlay encapsulation), **storage** (NVMe-oF initiator, storage virtualization, compression and encryption), and **security** (firewalling, encryption/IPsec/TLS, telemetry and intrusion detection). All of these are programmed through the DOCA SDK.

24. **Isolation and a separate trust domain.** The DPU runs its own OS on its own Arm cores, outside the host. A compromised or malicious tenant workload on the host cannot tamper with the firewall, encryption, or telemetry enforced on the DPU. Infrastructure control remains with the operator even when the tenant has full control of the host, including bare-metal.

### Exercise 7

**Step 7.1:**

| | DGX H100 | DGX B200 |
|---|---|---|
| SU compute power | 32 × 10.2 = **326.4 kW** | 32 × 14.3 = **457.6 kW** |
| Nodes per 40 kW rack | floor(40 / 10.2) = **3** | floor(40 / 14.3) = **2** |
| Racks for compute | ceil(32 / 3) = **11** | 32 / 2 = **16** |

**Step 7.2:** Other components include leaf and spine compute switches, storage fabric switches, in-band and OOB Ethernet switches, UFM/fabric management appliances, head/management nodes (cluster manager, scheduler), the storage system, and PDUs and cable management.

25. Training jobs run every GPU near full load simultaneously and for long periods, so a cluster actually reaches its peak. If the circuits are sized for typical power, breakers trip or power capping kicks in under exactly the workload the cluster exists for.

26. Toward **liquid cooling**, such as direct-to-chip or rear-door heat exchangers. Air cannot remove heat at very high rack densities with acceptable airflow, noise, and fan power. Liquid carries far more heat per volume, which enables denser racks and better energy efficiency.

27. The nodes-per-rack figure must rise, which needs more power and cooling per rack. Otherwise, the cluster cannot fit in the floor space. Spreading nodes across more distant racks lengthens cable runs. 400 Gb/s links beyond short copper (DAC) distances require optical transceivers or active cables, which add cost, power, and failure points. Rail-optimized designs try to keep each SU's cabling local for this reason.

### Exercise 8

28. Within one node, GPU-to-GPU traffic uses NVLink at roughly 900 GB/s per GPU. Spread across 4 nodes, the same communication goes over the network at 400 Gb/s (50 GB/s) per GPU, with higher latency. Packing a worker onto one full node keeps the most communication-intensive parallelism (tensor parallel) on NVLink and avoids sharing the node's NICs with other jobs.

29. `IPC_LOCK` lets the process **pin (lock) memory** so it cannot be swapped out, which RDMA requires for the buffers the NIC accesses directly. NCCL and PyTorch DataLoaders use shared memory for intra-node communication between processes. The container runtime's default 64 MB `/dev/shm` is far too small and causes failures or fallback to slower paths.

30. **DCGM Exporter**, built on NVIDIA Data Center GPU Manager. The **NVIDIA GPU Operator** installs it alongside the driver, container toolkit, and device plugin.

### Exercise 9

31. The compute NIC `mlx5_5` (rail 5) has **negotiated 200 Gb/s instead of 400 Gb/s**. Typical causes are a damaged or dirty optical connector or cable, a failing transceiver, a mismatched cable type, or a port that auto-negotiated down after errors. NVLink and the GPU diagnostics are clean, so the problem is in the fabric, not in the GPUs.

32. Collective operations are synchronous and striped across all rails. Each step of a ring or tree all-reduce must finish on every rail before the next begins, so the whole collective runs at the speed of the slowest link. A half-speed rail stretches every step, and every GPU in the job waits for it.

33. **Operationally:** drain the node from the scheduler (for example `kubectl cordon`/`drain`, or `scontrol update nodename=... state=drain` in Slurm), restart the job on healthy nodes, reseat or replace the cable or transceiver, and verify with `ibstat` and a NCCL test before returning the node to service. **Monitoring:** alert on port rate below the expected value and on link error counters, using UFM fabric telemetry or node-level exporters. Run periodic NCCL or DCGM burn-in checks so that a degraded link drains the node automatically instead of being discovered from user throughput complaints.

</details>