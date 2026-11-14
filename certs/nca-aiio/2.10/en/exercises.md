# Topic 2.10 — Guided Exercises: Purpose and Benefits of a DPU in the Data Center

> **Scope.** These exercises build a working mental model of the NVIDIA BlueField DPU: what it is physically, which work it takes off the host CPU, how it creates a separate trust domain, and where it sits in DGX and DGX SuperPOD architectures. Steps 1–4 assume access to a server with a BlueField-2 or BlueField-3 card. If you have no hardware, read the representative outputs and answer the questions anyway. Steps 5–7 are analysis exercises and need no hardware.
>
> Command flags and default names (bridges, representors, IPs) vary between DOCA/BFB releases. Before running anything on real equipment, check the DOCA documentation for your installed version.

**Official references used throughout**

- NVIDIA BlueField-3 DPU datasheet: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- Accelerating IO in the Modern Data Center — Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- DGX H100 component descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- DGX SuperPOD B200 reference architecture: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVLink: https://www.nvidia.com/en-us/data-center/nvlink/
- AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727

---

## Exercise 1 — Identify the DPU from the host

A DPU combines three things on one card:

- a high-speed network adapter: a ConnectX-7 on BlueField-3, a ConnectX-6 Dx on BlueField-2;
- a general-purpose Arm SoC with its own DRAM and its own OS;
- hardware acceleration engines for packet processing, crypto, compression, and storage.

From the host's point of view, it first looks like a PCIe device.

1. List Mellanox/NVIDIA PCIe functions on the host:

   ```bash
   lspci -nn | grep -i -E 'mellanox|bluefield'
   ```

   Representative output for a dual-port BlueField-3:

   ```
   17:00.0 Ethernet controller [0200]: Mellanox Technologies MT43244 BlueField-3 integrated ConnectX-7 network controller [15b3:a2dc] (rev 01)
   17:00.1 Ethernet controller [0200]: Mellanox Technologies MT43244 BlueField-3 integrated ConnectX-7 network controller [15b3:a2dc] (rev 01)
   17:00.2 DMA controller [0801]: Mellanox Technologies MT43244 BlueField-3 SoC Management Interface [15b3:c2d5] (rev 01)
   ```

2. Show the link width and speed negotiated for the first function:

   ```bash
   sudo lspci -s 17:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
   ```

   ```
   LnkCap: Port #0, Speed 32GT/s, Width x16, ASPM not supported
   LnkSta: Speed 32GT/s, Width x16
   ```

3. Show the host-side network interfaces bound to the card:

   ```bash
   ip -br link | grep -E '^(ens|enp)'
   sudo ethtool -i ens1f0np0 | head -4
   ```

   ```
   ens1f0np0        UP             b8:3f:d2:aa:bb:01 <BROADCAST,MULTICAST,UP,LOWER_UP>
   ens1f1np1        DOWN           b8:3f:d2:aa:bb:02 <BROADCAST,MULTICAST>
   driver: mlx5_core
   version: 24.10-1.1.4
   firmware-version: 32.43.1014 (MT_0000000884)
   bus-info: 0000:17:00.0
   ```

**Questions**

1.1. The output shows two "Ethernet controller" functions and one "DMA controller / SoC Management Interface". What does each represent?

1.2. 32 GT/s x16 corresponds to which PCIe generation? Why does this matter for a 400 Gb/s device?

1.3. The host uses the ordinary `mlx5_core` driver. What does this tell you about how applications on the host consume DPU networking?

---

## Exercise 2 — Inspect and understand the operating mode

A BlueField can run in different modes. The mode decides who controls the embedded switch (eSwitch) of the network adapter.

- **DPU mode** (the default, also called ECPF / embedded function mode): the Arm cores own the eSwitch. All host traffic passes through policies that the DPU OS installs.
- **NIC mode**: the Arm subsystem is not used for the data path, and the card behaves like a ConnectX SmartNIC. The host owns the eSwitch.

1. Start the Mellanox Software Tools service and find the configuration device:

   ```bash
   sudo mst start
   sudo mst status -v | grep -i bluefield
   ```

   ```
   BlueField3(rev:1)  /dev/mst/mt41692_pciconf0   17:00.0   mlx5_0   net-ens1f0np0
   BlueField3(rev:1)  /dev/mst/mt41692_pciconf0.1 17:00.1   mlx5_1   net-ens1f1np1
   ```

2. Query the mode-related parameters:

   ```bash
   sudo mlxconfig -d /dev/mst/mt41692_pciconf0 q | grep -E 'Device type|Description|INTERNAL_CPU'
   ```

   ```
   Device type:        BlueField3
   Description:        NVIDIA BlueField-3 B3220 P-Series FHHL DPU; 200GbE (default mode) / NDR200 IB; Dual-port QSFP112; PCIe Gen5.0 x16; 16 Arm cores; 32GB on-board DDR; integrated BMC; Crypto Enabled
           INTERNAL_CPU_MODEL                          EMBEDDED_CPU(1)
           INTERNAL_CPU_OFFLOAD_ENGINE                 ENABLED(0)
   ```

3. **Read only. Do not run this on a production node.** This is how an operator would switch a BlueField-3 to NIC mode. A full power cycle is needed for it to take effect:

   ```bash
   sudo mlxconfig -d /dev/mst/mt41692_pciconf0 s INTERNAL_CPU_OFFLOAD_ENGINE=1
   ```

**Questions**

2.1. Given `INTERNAL_CPU_MODEL EMBEDDED_CPU(1)` and `INTERNAL_CPU_OFFLOAD_ENGINE ENABLED(0)`, which mode is this card in?

2.2. Which security benefit is lost if an operator switches the card to NIC mode? Why?

2.3. Name a legitimate reason to run a BlueField in NIC mode.

---

## Exercise 3 — Reach the DPU's own operating system via RShim

The DPU runs its own Linux, typically an Ubuntu-based BFB image built by NVIDIA. The host reaches it through the **RShim** driver. RShim exposes the following over PCIe (or over USB/BMC):

- a boot channel;
- a serial console;
- a virtual Ethernet link called `tmfifo_net`.

1. Check the RShim service and its device nodes on the host:

   ```bash
   systemctl is-active rshim
   ls /dev/rshim0/
   cat /dev/rshim0/misc
   ```

   ```
   active
   boot  console  misc  rshim
   DISPLAY_LEVEL   0 (0:basic, 1:advanced, 2:log)
   BOOT_MODE       1 (0:rshim, 1:emmc, 2:emmc-boot-swap)
   BOOT_TIMEOUT    150 (seconds)
   DROP_MODE       0 (0:normal, 1:drop)
   SW_RESET        0 (1: reset)
   DEV_NAME        pcie-0000:17:00.2
   DEV_INFO        BlueField-3(Rev 1)
   ```

2. Bring up the host side of the virtual link and log in to the DPU. These are the default addresses: the host is `192.168.100.1/30` and the DPU is `192.168.100.2`.

   ```bash
   sudo ip addr add 192.168.100.1/30 dev tmfifo_net0
   sudo ip link set tmfifo_net0 up
   ssh ubuntu@192.168.100.2
   ```

3. Inside the DPU, look at its CPU and memory:

   ```bash
   lscpu | grep -E 'Architecture|Model name|^CPU\(s\)'
   free -g | head -2
   cat /etc/mlnx-release
   ```

   ```
   Architecture:            aarch64
   CPU(s):                  16
   Model name:              Cortex-A78AE
                 total        used        free      shared  buff/cache   available
   Mem:             30           2          26           0           2          27
   bf-bundle-2.9.1-xx_24.10_ubuntu-22.04_prod
   ```

4. **Read only.** Reimaging the DPU OS from the host looks like this:

   ```bash
   sudo bfb-install --bfb bf-bundle-2.9.1-xx_24.10_ubuntu-22.04_prod.bfb --rshim rshim0
   ```

**Questions**

3.1. The DPU reports 16 Arm cores and about 30 GB of RAM that are not part of the host's CPU/RAM inventory. Why is this separate compute domain the foundation of the DPU value proposition?

3.2. RShim's `SW_RESET` and `boot` interfaces let the host reset and reimage the DPU. In a hardened multi-tenant cloud, would you leave this path open to the tenant who owns the host OS? What would you use instead?

3.3. Which component on the B3220 card (listed in the `Description` field in Exercise 2) provides out-of-band management of the DPU itself?

---

## Exercise 4 — See infrastructure offload in action: OVS and ASAP²

In DPU mode, the virtual switch runs on the Arm cores, not on the host. The Accelerated Switching and Packet Processing (ASAP²) technology then pushes established flows into the eSwitch hardware. After that, packets are forwarded at line rate without touching any CPU, neither the host's nor the Arm's.

1. On the DPU, show the default OVS topology:

   ```bash
   sudo ovs-vsctl show
   ```

   ```
   Bridge ovsbr1
       Port p0
           Interface p0
       Port pf0hpf
           Interface pf0hpf
       Port en3f0pf0sf0
           Interface en3f0pf0sf0
       Port ovsbr1
           Interface ovsbr1
               type: internal
   Bridge ovsbr2
       Port p1
           Interface p1
       Port pf1hpf
           Interface pf1hpf
       Port en3f1pf1sf0
           Interface en3f1pf1sf0
       Port ovsbr2
           Interface ovsbr2
               type: internal
   ovs_version: "3.x"
   ```

2. Confirm that hardware offload is enabled:

   ```bash
   sudo ovs-vsctl get Open_vSwitch . other_config:hw-offload
   ```

   ```
   "true"
   ```

3. From the host, generate traffic toward another node, for example `ping -c 100 10.0.0.20` or an `iperf3` run. Then, on the DPU, compare the flows handled in hardware with those handled in software:

   ```bash
   sudo ovs-appctl dpctl/dump-flows type=offloaded | head -3
   sudo ovs-appctl dpctl/dump-flows type=ovs | wc -l
   ```

   ```
   recirc_id(0),in_port(pf0hpf),eth(src=b8:3f:d2:aa:bb:01,dst=b8:3f:d2:cc:dd:01),eth_type(0x0800),ipv4(frag=no), packets:98, bytes:9604, used:0.4s, actions:p0
   recirc_id(0),in_port(p0),eth(src=b8:3f:d2:cc:dd:01,dst=b8:3f:d2:aa:bb:01),eth_type(0x0800),ipv4(frag=no), packets:98, bytes:9604, used:0.4s, actions:pf0hpf
   2
   ```

4. While `iperf3` runs at high throughput, check CPU load on both sides:

   ```bash
   # on the host
   mpstat 1 5 | tail -1
   # on the DPU
   mpstat 1 5 | tail -1
   ```

   With offloaded flows, the expected result is that neither the host nor the Arm cores show significant `%soft` (softirq) time attributable to switching.

**Questions**

4.1. What do `p0`, `pf0hpf`, and `en3f0pf0sf0` represent?

4.2. 98 packets were forwarded by the `offloaded` flows. Why did only the first packet(s) of the conversation reach OVS software?

4.3. Explain in one paragraph why the blog post "Accelerating IO in the Modern Data Center — Network IO" argues that software networking on host CPUs does not scale with link speed.

---

## Exercise 5 — Draw the trust boundary (analysis, no hardware)

Scenario: a bare-metal-as-a-service provider rents whole GPU servers to tenants. Each tenant gets root on the host OS. The provider must still do three things:

- enforce tenant network isolation (VXLAN/EVPN overlays and security groups);
- encrypt traffic between racks;
- collect flow telemetry.

1. Make a table with three columns: **Function**, **Runs on host (no DPU)**, **Runs on DPU**. Fill it in for these functions: overlay encapsulation, firewall/security groups, IPsec/TLS encryption, flow telemetry, NVMe-oF storage initiator, and the tenant's AI training job.
2. Assume the tenant is malicious and has root. For each column, write down what the tenant can tamper with.
3. Identify the single physical path between the tenant's OS and the provider's control plane.

**Questions**

5.1. Why does moving the security policy onto the DPU give a **zero-trust** posture even when the tenant has root on the host?

5.2. The NVIDIA blog "Offloading and Isolating Data Center Workloads with BlueField DPU" groups DPU benefits into offload, acceleration, and isolation. Classify each of these under one of the three: (a) host CPU cores returned to applications; (b) inline crypto at line rate; (c) security agents that host malware cannot disable.

5.3. Which BlueField storage capability lets the DPU present remote storage to the host as if it were a local NVMe drive? Why is that useful for bare-metal tenants?

---

## Exercise 6 — Quantify the CPU reclaim (calculation)

A node has 2 × 32-core CPUs, which gives 64 cores. Profiling shows the following per-node infrastructure cost when running on the host:

| Infrastructure task | Host cores consumed |
|---|---|
| OVS + VXLAN overlay | 6 |
| IPsec for east-west encryption | 5 |
| Storage initiator (NVMe/TCP) | 3 |
| Security agent + telemetry | 2 |

1. Compute the total infrastructure overhead in cores and as a percentage of the node.
2. Assume the DPU offloads all four tasks and leaves 0.5 cores of residual host driver overhead. Compute the cores returned to applications.
3. Scale the result to a 1,000-node cluster. Express the reclaimed capacity as "equivalent nodes".

**Questions**

6.1. What percentage of host CPU is infrastructure overhead in this scenario? How does it compare with the claim, commonly cited by NVIDIA, that infrastructure tasks can consume up to roughly 30% of server CPU cycles?

6.2. Besides more cores, name two second-order benefits of the offload that do not show up in a core count.

6.3. In a GPU server, why is reclaimed host CPU especially valuable, even though the "real work" runs on the GPUs?

---

## Exercise 7 — Place the DPU in DGX and DGX SuperPOD (architecture mapping)

Open the DGX H100 component descriptions and the DGX SuperPOD B200 reference architecture (URLs above).

1. From the DGX H100 user guide, list the network adapters in the system and the role assigned to each.
2. In the SuperPOD B200 RA, identify the networks: compute fabric, storage fabric, in-band management, and out-of-band management. For each one, note which adapter in the DGX node connects to it.
3. Fill in this table:

   | Traffic | Direction | Adapter | Why that adapter |
   |---|---|---|---|
   | GPU-to-GPU inside one node | ? | ? | ? |
   | GPU-to-GPU across nodes (training all-reduce) | ? | ? | ? |
   | Dataset / checkpoint reads and writes to shared storage | ? | ? | ? |
   | Cluster management, SSH, job scheduler, container pulls | ? | ? | ? |

**Questions**

7.1. Why are the BlueField-3 DPUs **not** the adapters that carry the multi-node compute fabric traffic in a DGX?

7.2. NVLink also moves data at very high bandwidth. Why is it a mistake to group NVLink with DPUs?

7.3. NVIDIA also ships the BlueField-3 **SuperNIC** for Spectrum-X Ethernet AI fabrics. How does a SuperNIC differ in purpose from a BlueField-3 DPU?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1.1.** Functions `17:00.0` and `17:00.1` are the two PCIe physical functions (PF0/PF1) of the integrated ConnectX-7, one per network port; the host sees these as NICs. `17:00.2` is the SoC management interface, the RShim function. Through it, the host reaches the Arm subsystem for boot, console, and the `tmfifo` virtual network.

**1.2.** 32 GT/s per lane is PCIe Gen5. A Gen5 x16 link gives about 64 GB/s per direction, roughly 512 Gb/s raw. That is the headroom a 400 Gb/s BlueField-3 needs to feed the host at line rate. A Gen4 x16 link (~256 Gb/s) would bottleneck a 400 Gb/s port.

**1.3.** The DPU is transparent to applications. The host loads the standard `mlx5_core`/RDMA stack and sees normal netdevs, VFs, or SFs. All infrastructure logic is hidden behind those functions and enforced on the card: switching, overlays, encryption, firewalling. No application changes are needed.

### Exercise 2

**2.1.** DPU mode, also called embedded CPU / ECPF mode. `INTERNAL_CPU_MODEL=EMBEDDED_CPU` means the Arm subsystem owns the eSwitch, and `INTERNAL_CPU_OFFLOAD_ENGINE=ENABLED(0)` means the Arm offload engine is active.

**2.2.** Isolation is lost. In NIC mode the host owns the eSwitch and programs the flow rules, so anyone with root on the host can change or bypass network policy. In DPU mode, policy lives in a separate OS on the Arm cores, outside the host's control.

**2.3.** Examples include:
- a single-tenant environment that only wants ConnectX-class acceleration (RDMA, RoCE, crypto offload) without operating a second OS;
- simpler fleet management;
- slightly lower latency when no Arm-side processing is required;
- running certain software that expects a plain NIC.

### Exercise 3

**3.1.** Offload and isolation both depend on having compute that is not the host's:
- Offload: infrastructure services run on the DPU's Arm cores and accelerators instead of consuming host cores.
- Isolation: the services run in a different OS with a different security domain. A compromised host kernel cannot read DPU memory or stop DPU processes.

**3.2.** No. RShim access from the host lets the host OS reset and reimage the DPU, which defeats the trust boundary. In a hardened multi-tenant design, the provider disables host-side RShim access and manages the DPU out-of-band. Typical channels are the DPU's integrated BMC (Redfish), the DPU's out-of-band 1GbE management port, or RShim over the BMC/USB path controlled by the provider.

**3.3.** The integrated BMC ("integrated BMC" in the description). It allows power control, firmware updates, and console access to the DPU independently of the host.

### Exercise 4

**4.1.**
- `p0` is the representor of physical uplink port 0, the wire.
- `pf0hpf` is the representor of the host PF0. Traffic the host sends on `ens1f0np0` arrives in OVS here.
- `en3f0pf0sf0` is a Scalable Function on the Arm side, commonly used for the DPU's own in-band connectivity.

Every host-facing function has a representor on the DPU. That is how the DPU switches, and can police, every host packet.

**4.2.** ASAP² uses a slow-path / fast-path model. The first packet of a new flow misses in the hardware table and goes up to OVS (`ovs-vswitchd`) on the Arm cores. OVS evaluates the OpenFlow pipeline and installs a datapath flow, and because `hw-offload=true`, the flow is programmed into the ConnectX eSwitch through TC flower. Later packets match in hardware and are forwarded at line rate without any CPU involvement.

**4.3.** Link speeds have grown much faster than per-core CPU performance. At 100–400 Gb/s, the per-packet time budget is a few nanoseconds to tens of nanoseconds. Software processing of each packet (parsing, encapsulation, lookup, crypto, copies, interrupts) would need many cores just to keep up. The result is fewer cores for applications, plus higher and less predictable latency. Moving packet processing into dedicated NIC/DPU hardware decouples network performance from host CPU scaling.

### Exercise 5

**5.1.** The enforcement point is outside the tenant's reach. The overlay, firewall rules, encryption keys, and telemetry agents run on the DPU's Arm OS and in the eSwitch hardware. The tenant's root account controls only the host OS. Every packet from the host must cross representors that the provider controls, so the tenant cannot disable or tamper with policy: they can only send traffic through it. The provider no longer has to trust the host. That is zero trust applied at the server edge.

The single physical path asked for in step 3 is the PCIe link into the DPU's host-facing functions (PFs, VFs, SFs). Host-side RShim must be locked down, as covered in 3.2.

**5.2.**
- (a) Offload: host CPU cores are returned to applications.
- (b) Acceleration: inline crypto runs at line rate in dedicated engines.
- (c) Isolation: security agents run in a separate domain that host malware cannot disable.

**5.3.** BlueField SNAP (NVMe SNAP / storage emulation). The DPU emulates a standard NVMe PCIe device to the host, while the actual I/O goes over the network to remote storage, for example NVMe-oF. Bare-metal tenants use the stock NVMe driver and can even boot from it. The provider keeps control of where the storage lives, how it is encrypted, and how QoS is applied, with no provider software running in the tenant's OS.

### Exercise 6

**6.1.** 6 + 5 + 3 + 2 = 16 cores, and 16 / 64 = 25% of the node. That is within the range NVIDIA cites, which is up to roughly 30%, depending on workload, link speed, and which services (encryption, storage) are enabled.

Step 2: 16 − 0.5 = 15.5 cores reclaimed per node.

Step 3: 15.5 × 1,000 = 15,500 cores. Divided by 64 cores per node, that is about 242 equivalent nodes of capacity recovered without buying servers.

**6.2.** Any two of the following:
- more predictable application latency and less jitter, because there are no noisy-neighbor softirqs or cache pollution from packet processing;
- lower power per unit of work, since hardware engines are more efficient than general-purpose cores for crypto and packet processing;
- simpler security audits, because policy is centralized on the DPU;
- infrastructure software can be upgraded on the DPU without touching or rebooting the tenant's host OS;
- licensing savings when software is licensed per host core.

**6.3.** The host CPUs on a GPU server run the code that feeds the GPUs: data loading, preprocessing and augmentation, launching CUDA kernels, and communication setup. If infrastructure tasks steal these cores, input pipelines starve and expensive GPUs sit idle. Reclaimed host CPU therefore turns into higher GPU utilization.

### Exercise 7

**7.1.** In a DGX, the multi-node compute (east-west, GPU-to-GPU RDMA) fabric is carried by the dedicated ConnectX-7 adapters. There is one adapter per GPU, and they connect to the InfiniBand (or Spectrum-X Ethernet) compute fabric so that each GPU gets its own NIC bandwidth via GPUDirect RDMA.

The two BlueField-3 DPUs serve the converged storage and in-band management network (north-south). Their value there is offload, isolation, and infrastructure services. Raw per-GPU RDMA bandwidth is not their role.

The table from step 3:

| Traffic | Direction | Adapter | Why that adapter |
|---|---|---|---|
| GPU-to-GPU inside one node | Intra-node | NVLink / NVSwitch | Highest bandwidth, no NIC involved |
| GPU-to-GPU across nodes | East-west | ConnectX-7 (compute fabric, one per GPU) | Per-GPU RDMA bandwidth, GPUDirect |
| Storage I/O | North-south | BlueField-3 DPU | Storage offload, isolation, high-throughput access to shared storage |
| Management, SSH, scheduler, registry | North-south | BlueField-3 DPU (in-band); BMC port for out-of-band | Isolation and infrastructure services; OOB stays separate |

**7.2.** NVLink is a GPU-to-GPU interconnect (and, with NVLink Switch, a scale-up domain). It moves tensors between GPU memories. It does not run an OS, does not enforce network or security policy, and does not offload storage or networking services. A DPU is a network endpoint with its own Arm compute that offloads, accelerates, and isolates data center infrastructure. They solve different problems at different layers.

**7.3.** A BlueField-3 SuperNIC is optimized for east-west AI traffic in Spectrum-X Ethernet fabrics: high-bandwidth GPU-to-GPU RoCE with features such as adaptive routing support, congestion control, and packet reordering. A BlueField-3 DPU targets north-south and infrastructure workloads: networking, storage, and security offload, plus a separate trust domain running the provider's software stack.

On the exam:
- "infrastructure offload/isolation" → DPU;
- "AI fabric GPU-to-GPU over Ethernet" → SuperNIC (or ConnectX in InfiniBand fabrics);
- "intra-node GPU-to-GPU" → NVLink.

</details>