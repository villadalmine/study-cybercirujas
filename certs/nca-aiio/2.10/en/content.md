# 2.10 — The Purpose and Benefits of a DPU in a Data Center

> **Exam weight: 4.0.** Expect conceptual questions. You will be asked what a DPU is, what it offloads, how it differs from a CPU, GPU, NIC or SuperNIC, and where it sits in DGX and DGX SuperPOD architectures. This material also covers how DPUs are operated in production, because that operational knowledge is what makes the concepts stick.

---

## 1. Motivation: the architectural problem a DPU solves

### 1.1 The "infrastructure tax"

In a traditional server, the host CPU runs two kinds of work:

1. **Application work**: the thing you bought the server for, such as a training job's data loader, an inference service, or a database.
2. **Infrastructure work**: everything needed to make the server a citizen of the data center:
   - Virtual switching: OVS, VXLAN/Geneve encap/decap, connection tracking, NAT.
   - Storage virtualization: NVMe-oF initiators, iSCSI, erasure coding, compression, encryption at rest.
   - Security: IPsec/TLS crypto, stateful firewalls, micro-segmentation, telemetry and flow logging.
   - Management agents, monitoring exporters, and the hypervisor or container runtime networking stack.

At 100–400 Gb/s line rates, infrastructure work does not scale on general-purpose cores. Processing 400 Gb/s of small packets in software with per-packet encap, conntrack and crypto can consume a large fraction of a server's cores. NVIDIA and the industry often call this the **data center infrastructure tax**: the share depends on workload and link speed; NVIDIA's offload article frames it as the work of dozens to hundreds of CPU cores (30, 100 or 300 cores depending on the scenario), not as a fixed percentage.

For AI infrastructure the tax is worse, for three reasons:

- **GPUs are the expensive resource.** A GPU stalled because the host CPU cannot feed storage I/O or move data fast enough wastes the most expensive silicon in the rack.
- **Multi-tenancy is the norm.** AI clouds, internal GPU-as-a-service platforms and bare-metal-as-a-service all need strong tenant isolation without a hypervisor eating cycles or adding jitter.
- **Determinism matters.** Collective operations such as all-reduce are only as fast as the slowest rank. Infrastructure software stealing cycles on one node causes jitter that slows every node.

### 1.2 The security problem: the infrastructure runs inside the attack surface

In the traditional model, the firewall, the virtual switch and the policy agent run **on the same CPU and OS as the tenant workload**. If the host is compromised (kernel exploit, root escape from a container, or a malicious bare-metal tenant), the attacker can disable or reconfigure the very controls meant to contain them.

A DPU moves the infrastructure control plane into a **separate trust domain**. It has its own CPU cores, its own OS, its own memory and its own management interface, physically located on the I/O path between the host and the network. A host with full root still cannot reconfigure the policy enforced on the DPU.

### 1.3 The three verbs: offload, accelerate, isolate

NVIDIA consistently frames the DPU's value with three words. Memorize them for the exam:

| Verb | Meaning | Example |
|---|---|---|
| **Offload** | Move infrastructure software off the host CPU onto the DPU's own Arm cores | OVS control plane, storage target/initiator emulation, telemetry agents run on the DPU |
| **Accelerate** | Execute the data path in dedicated hardware engines at line rate | ASAP² flow offload in the eSwitch, inline IPsec/TLS/MACsec crypto, RDMA, compression, regex |
| **Isolate** | Run infrastructure in a separate, hardware-enforced trust domain | Tenant cannot reach the DPU OS. Zero-trust and bare-metal multi-tenancy |

The resulting benefits:

- **Reclaimed host CPU** for applications. In GPU servers, more CPU is available to feed GPUs.
- **Line-rate, deterministic I/O** independent of host load.
- **Zero-trust security** with policy enforced outside the host.
- **Bare-metal cloud** with cloud-style networking and storage, without a hypervisor.
- **Better TCO and performance per watt**, because fixed-function engines are far more efficient than general-purpose cores for packet and crypto work.
- **Operational separation**: the infrastructure team owns the DPU, the tenant or application team owns the host.

---

## 2. What a DPU actually is

### 2.1 Definition

A **Data Processing Unit (DPU)** is a programmable system-on-a-chip on a network adapter. It combines:

1. **A high-performance network interface** with RDMA/RoCE and InfiniBand or Ethernet at 200–400 Gb/s. In NVIDIA's case this is the ConnectX core.
2. **A multi-core general-purpose CPU complex** (Arm) running its own full OS, typically Ubuntu, from on-board memory and storage.
3. **Programmable acceleration engines** for networking, storage and security.
4. **A PCIe switch / root complex** so it can sit between the host and the network, and even present emulated devices to the host.

NVIDIA's mental model is that the data center now has **three pillars of compute**:

- **CPU** for general-purpose application logic.
- **GPU** for accelerated computing (AI, HPC, graphics).
- **DPU** for data-center infrastructure: moving, securing and processing data.

### 2.2 NVIDIA BlueField-3 at a glance

| Component | BlueField-3 (representative spec) |
|---|---|
| Network | Up to 400 Gb/s total. Ethernet and InfiniBand (ConnectX-7 class). 1× 400G or 2× 200G ports |
| Arm cores | Up to 16× Arm Cortex-A78AE |
| Memory | On-board DDR5 (16–32 GB depending on SKU) |
| Host interface | PCIe Gen5 x16, with integrated PCIe switch |
| Accelerators | ASAP² eSwitch flow offload, inline IPsec/TLS/MACsec crypto, RDMA/GPUDirect, NVMe-oF and storage emulation (SNAP), compression/decompression, regex, programmable datapath accelerator (DPA) cores, precision timing (PTP) |
| Management | Out-of-band 1GbE management port and BMC on many SKUs. RShim interface over PCIe/USB |
| Software | NVIDIA DOCA SDK and runtime, BlueField OS (BFB image, Ubuntu-based) |

The previous generation, BlueField-2, has 8× Cortex-A72, 200 Gb/s and PCIe Gen4. You may see it in older material and in `mlxconfig` device names (`mt41686` for BF-2, `mt41692` for BF-3).

### 2.3 Internal architecture and the data path

```
                 +--------------------------------------------------+
                 |                  BlueField-3 DPU                 |
   Host server   |                                                  |   Network
  +---------+    |  +------------+     +--------------------------+ |  +--------+
  | x86/Arm |    |  | Arm complex|     | ConnectX core            | |  | Leaf / |
  |  CPU    |<===|=>|  16x A78AE |<--->|  eSwitch (ASAP2)         |<|=>| Spine  |
  |  GPUs   |PCIe|  |  DDR5, eMMC|     |  RDMA / RoCE / IB        | |  |        |
  +---------+Gen5|  |  BlueField |     |  Crypto (IPsec/TLS/MACsec| |  +--------+
                 |  |  OS + DOCA |     |  Compression, Regex, DPA | |
                 |  +------------+     +--------------------------+ |
                 |        ^ control plane          ^ data plane     |
                 |  OOB 1GbE mgmt / BMC      RShim (PCIe/USB)       |
                 +--------------------------------------------------+
```

The key architectural idea is the **split between control plane and data plane**:

- The **control plane** runs on the Arm cores: OVS daemon, routing (FRR/BGP), policy agents, storage controllers, Kubernetes components and telemetry collectors.
- The **data plane** runs in the hardware eSwitch and accelerators. The first packet of a flow may go to the Arm (slow path). OVS then programs a hardware rule through TC flower / rte_flow (ASAP²), and every subsequent packet of the flow is switched, encapsulated, NAT-ed or encrypted **in hardware at line rate**, touching neither the host CPU nor the Arm cores.

### 2.4 Operating modes

How the DPU sits relative to the host is configurable. This is the most important operational fact about BlueField:

| Mode | Who owns the embedded switch (eSwitch) | Host sees | Use case |
|---|---|---|---|
| **DPU mode** (a.k.a. Embedded CPU Function Ownership, ECPF). This is the default | The **Arm OS**. All host traffic traverses the eSwitch under DPU control | A PF/VFs whose traffic is steered by rules the DPU installs | Full offload, isolation and zero-trust. Infrastructure control runs on the DPU |
| **NIC mode** | The **host**. Arm cores are inactive or unused for the datapath | A ConnectX-7-like SmartNIC | When you only need a high-performance NIC, e.g. compute fabric ports, or you have no DPU software to run |
| **Separated host mode** (legacy, BF-2 era) | Arm and host each get their own network function, symmetric, no ownership | Independent PF | Niche. Largely superseded |

> **Production consequence of DPU mode:** the host's network connectivity *depends on the Arm OS*. If OVS on the DPU is not running or the DPU OS is wedged, the host has no network even though its own NIC driver looks healthy. Section 5 covers how to diagnose this.

### 2.5 Software: DOCA

**NVIDIA DOCA** (Data Center Infrastructure On a Chip Architecture) is to the DPU what CUDA is to the GPU:

- **Libraries and drivers**: DOCA Flow (hardware steering), DOCA Comch, DOCA DMA, DOCA Crypto/IPsec, DOCA Compress, DOCA RegEx, DOCA GPUNetIO, DOCA DPA.
- **Services** (containerized, run on the DPU): DOCA Telemetry Service, OVS-DOCA, DOCA Firefly (PTP), HBN (Host-Based Networking: Cumulus/FRR BGP-EVPN routing on the DPU), SNAP (storage emulation), App Shield.
- **Runtime and host packages**: `doca-runtime`, `doca-tools`, and on the host the DOCA-Host / OFED drivers (`mlx5_core`, `mlx5_ib`).
- **Orchestration**: the NVIDIA Network Operator (Kubernetes) on hosts, and the DOCA Platform Framework (DPF) for provisioning and lifecycle of DPUs and DPU services from Kubernetes.

---

## 3. Technical comparisons

### 3.1 CPU vs GPU vs DPU

| Dimension | CPU | GPU | DPU |
|---|---|---|---|
| Primary role | General application logic, OS | Massively parallel math (AI/HPC) | Data-center infrastructure: move, secure, store data |
| Optimized for | Low-latency serial/branchy code | Throughput on dense tensor/vector ops | Line-rate packet/storage/crypto processing |
| Typical location | Motherboard socket | PCIe/SXM/NVLink module | PCIe adapter on the network edge of the server |
| Runs its own OS? | Is the host | No (driven by the host) | **Yes**: independent Arm OS |
| Security role | Inside the tenant trust domain | Inside the tenant trust domain | **Separate trust domain** enforcing policy on the host |
| Programming | C, Go, Python... | CUDA | DOCA (plus standard Linux tools on Arm) |

### 3.2 NIC vs SmartNIC vs DPU vs SuperNIC

| Capability | Basic NIC | SmartNIC (e.g., ConnectX-7) | DPU (BlueField-3) | SuperNIC (BlueField-3 SuperNIC) |
|---|---|---|---|---|
| Stateless offloads (checksum, TSO, RSS) | Yes | Yes | Yes | Yes |
| RDMA / RoCE / GPUDirect | Limited/no | Yes | Yes | Yes, AI-tuned |
| Hardware flow offload (OVS/ASAP²) | No | Yes (host-controlled) | Yes (DPU-controlled) | Focused on east-west AI traffic |
| Inline crypto | No | Some | Yes (IPsec/TLS/MACsec) | Yes |
| General-purpose cores with own OS | No | No | **Yes, 16 Arm cores** | Reduced Arm footprint, not the focus |
| Separate trust domain | No | No | **Yes** | Not the primary purpose |
| Storage emulation (NVMe/virtio-blk to host) | No | No | **Yes (SNAP)** | No |
| Primary use in AI factory | — | Compute fabric (InfiniBand/RoCE) | **North-south**: storage, in-band management, tenant/cloud networking, security | **East-west** GPU-to-GPU traffic in Spectrum-X Ethernet AI fabrics (RoCE adaptive routing, congestion control) |

The exam trap: **SuperNIC ≠ DPU**, even though both are built on BlueField-3 silicon. The DPU is the infrastructure computer for north-south traffic and isolation. The SuperNIC is a network accelerator for GPU-to-GPU east-west traffic in Spectrum-X, typically one per GPU.

### 3.3 Where infrastructure functions run: trade-offs

| Approach | Host CPU cost | Performance at 400G | Isolation | Operational complexity |
|---|---|---|---|---|
| Software on host (kernel OVS, software IPsec, software NVMe-oF) | High | Poor; cores saturate, jitter | None (same OS as tenant) | Low; familiar tooling |
| SmartNIC offload, host-controlled (ASAP² with host OVS) | Low on datapath, control plane still on host | Line rate for offloaded flows | None (host owns the eSwitch) | Medium |
| **DPU, DPU mode** (OVS/HBN/SNAP on Arm, hardware datapath) | **Near zero** | **Line rate** | **Strong**: separate OS, host cannot reconfigure | Higher: a second OS per server to image, patch and monitor |
| Hypervisor-based isolation | Medium-high (vSwitch, vhost) | Degrades under load | Good, but hypervisor in the trust chain | Medium; not suited to bare-metal GPU nodes |

The honest trade-off: a DPU adds **a second computer per server** to lifecycle-manage (firmware, BFB OS images, CVEs, monitoring). The payoff is reclaimed CPU, line-rate deterministic I/O and real isolation. That payoff is decisive at AI scale, but it is not free.

### 3.4 Key acceleration features and what they replace

| DPU feature | Replaces on the host | Benefit |
|---|---|---|
| **ASAP²** (Accelerated Switching and Packet Processing) eSwitch offload | Kernel/userspace OVS datapath, VXLAN/Geneve encap, conntrack, NAT | Line-rate virtual networking, zero host cycles |
| **Inline IPsec / TLS / MACsec** | Software crypto (OpenSSL, kernel xfrm) | Encrypt everything (zero-trust) at line rate |
| **NVMe SNAP / virtio-blk emulation** | Host NVMe-oF initiator, iSCSI, storage agents | Host sees a "local" NVMe disk that is actually remote. Bare-metal elastic storage |
| **GPUDirect Storage / RDMA** | Bounce buffers through host memory | Data goes storage → NIC → GPU memory directly |
| **HBN** (BGP/EVPN on the DPU) | Routing daemons on host, L2 stretched to host | Layer-3 to the host, VTEP on the DPU, host is unaware |
| **DOCA Telemetry / flow logging** | Host monitoring agents, sFlow in software | Visibility that a compromised host cannot tamper with |
| **Precision Time Protocol (PTP) hardware** | Software PTP | Nanosecond-class time sync for distributed systems |

---

## 4. DPUs in NVIDIA AI infrastructure

### 4.1 DGX H100 / DGX B200 network topology

The two DGX generations split their network adapters by purpose, but not with the same hardware:

| Adapter | DGX H100 ([user guide](https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html)) | DGX B200 ([user guide](https://docs.nvidia.com/dgx/dgxb200-user-guide/introduction-to-dgxb200.html)) | Role |
|---|---|---|---|
| ConnectX-7 (OSFP modules) | 8 single-port 400 Gb/s cards, one per GPU | 8 single-port 400 Gb/s cards, one per GPU | **Compute fabric** (InfiniBand NDR or Ethernet): east-west GPU-to-GPU traffic for collectives |
| Storage and in-band management card | **2 dual-port ConnectX-7** Ethernet cards | **2 dual-port BlueField-3 DPU** cards | North-south: access to shared storage and the cluster management network |
| BMC port | 1 GbE RJ-45 | 1 GbE RJ-45 | Out-of-band management (BMC) |

The DPU appears in the node only from DGX B200 on. On a DGX H100 the same storage and in-band role is served by ConnectX-7 cards, without an Arm subsystem to run offload services. Do not assume a DPU in every DGX.

So inside a DGX:

- **ConnectX-7 / InfiniBand or SuperNIC** carry the GPU-to-GPU compute traffic.
- **Storage and in-band management cards** (ConnectX-7 on DGX H100, BlueField-3 DPUs on DGX B200) carry storage and management traffic. On DGX B200 the DPUs are where storage offload, security and isolation functions can live.
- **NVLink/NVSwitch** carries GPU-to-GPU traffic *inside* the node. It never touches the DPU.

### 4.2 DGX SuperPOD

The DGX SuperPOD reference architecture (B200) defines **separate networks**:

1. **Compute fabric**: InfiniBand (Quantum) or Spectrum-X Ethernet, rail-optimized, connecting the per-GPU ConnectX-7 adapters.
2. **Storage fabric**: connects the nodes' **BlueField-3 DPUs** to high-performance storage appliances. It is kept separate so storage I/O does not interfere with collective communication.
3. **In-band management network**: also through the BlueField-3 ports. Used for cluster services such as Slurm, Kubernetes control plane, image provisioning and monitoring.
4. **Out-of-band management**: BMCs, switch management.

Why put storage and management on DPUs? Those are exactly the north-south, multi-tenant, security-sensitive paths where offload (storage protocols), acceleration (crypto, RDMA to storage) and isolation (policy outside the host) pay off.

### 4.3 Reference use cases

- **AI cloud / GPU-as-a-service, bare metal**: the tenant gets root on the DGX. The provider enforces VPC networking (HBN/OVS with VXLAN), security groups and storage attachment from the DPU, which the tenant cannot touch.
- **Zero-trust data center**: every server's traffic is encrypted and policy-checked at the DPU. Telemetry is collected from a domain the workload cannot tamper with.
- **Storage disaggregation**: SNAP presents remote NVMe-oF volumes to the host as local NVMe devices. No host initiator software, no host drivers beyond standard NVMe.
- **Cyber-security**: NVIDIA Morpheus pipelines consume DPU telemetry. DOCA App Shield does host introspection from the DPU.

---

## 5. Hands-on: operating a BlueField-3 DPU

> Outputs below are representative of BlueField-3 with DOCA 2.x / BFB 4.x-era tooling. Exact versions, PCI addresses and interface names vary by platform and release.

### 5.1 Discover the DPU from the host

```
$ lspci -d 15b3: -nn
03:00.0 Ethernet controller [0200]: Mellanox Technologies MT43244 BlueField-3 integrated ConnectX-7 network controller [15b3:a2dc] (rev 01)
03:00.1 Ethernet controller [0200]: Mellanox Technologies MT43244 BlueField-3 integrated ConnectX-7 network controller [15b3:a2dc] (rev 01)
03:00.2 DMA controller [0801]: Mellanox Technologies MT43244 BlueField-3 SoC Management Interface [15b3:c2d5] (rev 01)
```

The `SoC Management Interface` function is the **RShim** path over PCIe. Its presence tells you this is a DPU and not a plain ConnectX.

Start the Mellanox Software Tools (MST) service and query the devices:

```
$ sudo mst start
Starting MST (Mellanox Software Tools) driver set
Loading MST PCI module - Success
Loading MST PCI configuration module - Success
Create devices

$ sudo mst status -v
MST modules:
------------
    MST PCI module loaded
    MST PCI configuration module loaded
PCI devices:
------------
DEVICE_TYPE             MST                           PCI       RDMA            NET                                     NUMA
BlueField3(rev:1)       /dev/mst/mt41692_pciconf0.1   03:00.1   mlx5_1          net-ens1f1np1                           0
BlueField3(rev:1)       /dev/mst/mt41692_pciconf0     03:00.0   mlx5_0          net-ens1f0np0                           0
```

Check firmware:

```
$ sudo mlxfwmanager --query
Querying Mellanox devices firmware ...

Device #1:
----------
  Device Type:      BlueField3
  Part Number:      900-9D3B6-00CV-AA0_Ax
  Description:      NVIDIA BlueField-3 B3220 P-Series FHHL DPU; 200GbE (default mode) / NDR200 IB; Dual-port QSFP112; PCIe Gen5.0 x16 with x16 PCIe extension option; 16 Arm cores; 32GB on-board DDR; integrated BMC; Crypto Enabled
  PSID:             MT_0000000884
  PCI Device Name:  /dev/mst/mt41692_pciconf0
  Versions:         Current        Available
     FW             32.41.1000     N/A
     PXE            3.7.0300       N/A
     UEFI           14.34.0012     N/A
     UEFI Virtio blk   22.4.0013   N/A
     UEFI Virtio net   21.4.0013   N/A
  Status:           No matching image found
```

### 5.2 Verify and change the operating mode

```
$ sudo mlxconfig -d /dev/mst/mt41692_pciconf0 q INTERNAL_CPU_MODEL INTERNAL_CPU_OFFLOAD_ENGINE

Device #1:
----------
Device type:        BlueField3
Name:               900-9D3B6-00CV-AA0_Ax
Description:        NVIDIA BlueField-3 B3220 P-Series FHHL DPU; ...
Device:             /dev/mst/mt41692_pciconf0

Configurations:                                      Next Boot
        INTERNAL_CPU_MODEL                          EMBEDDED_CPU(1)
        INTERNAL_CPU_OFFLOAD_ENGINE                 ENABLED(0)
```

`EMBEDDED_CPU(1)` with `INTERNAL_CPU_OFFLOAD_ENGINE ENABLED(0)` means **DPU mode**. To switch a BlueField-3 to **NIC mode**:

```
$ sudo mlxconfig -d /dev/mst/mt41692_pciconf0 s INTERNAL_CPU_OFFLOAD_ENGINE=1
...
Apply new Configuration? (y/n) [n] : y
Applying... Done!
-I- Please reboot machine to load new configurations.
```

The change requires a **full power cycle** of the host (cold reboot, or `mlxfwreset` where supported), not just a warm reboot. Revert with `INTERNAL_CPU_OFFLOAD_ENGINE=0`.

### 5.3 Reach the DPU's Arm OS

Three paths exist:

1. **RShim over PCIe** from the host (`rshim` service creates `/dev/rshim0/` and a `tmfifo_net0` virtual Ethernet interface).
2. **Out-of-band 1GbE management port** (`oob_net0` on the DPU), the production path.
3. **BMC console** on DPUs with an integrated BMC.

```
$ sudo systemctl enable --now rshim
$ ls /dev/rshim0/
boot  console  misc  rshim

$ sudo ip addr add 192.168.100.1/30 dev tmfifo_net0
$ sudo ip link set tmfifo_net0 up
$ ssh ubuntu@192.168.100.2
ubuntu@dpu:~$ uname -m
aarch64
ubuntu@dpu:~$ nproc
16
```

Inspect the installed software on the DPU:

```
ubuntu@dpu:~$ sudo bfver

-bfver-

BlueField ATF version: v2.2(release):4.9.0-25-gxxxxxxx
BlueField UEFI version: 4.9.0-41-gxxxxxxx
BlueField BSP version: 4.9.0.13xxx

Installed OS image version: bf-bundle-2.9.0-90_24.10_ubuntu-22.04_prod
```

### 5.4 Provision (re-image) a DPU with a BFB

The BlueField OS ships as a **BFB** (BlueField Bootstream) bundle containing ATF, UEFI, the OS image and NIC firmware. A `bf.cfg` file customizes first boot (credentials, hostname, network). It is shell-style, not YAML:

```
# bf.cfg
ubuntu_PASSWORD='$6$rounds=656000$examplesalt$Q1sF2hPjWk8m3H3hSxk3vYbZ0Wq0pQk9m1Vb7K0xQe2yQ2Yk0wR8m4cY2wN2L3pX3fF0s9nV8b1cG5uT1aH0.'
bfb_modify_os() {
    echo "dpu-node01" > /mnt/etc/hostname
}
```

Generate a real hash with `openssl passwd -6`; the value above is a placeholder.

```
$ sudo bfb-install --bfb bf-bundle-2.9.0-90_24.10_ubuntu-22.04_prod.bfb \
      --config bf.cfg --rshim rshim0
Pushing bfb + cfg
1.41GiB 0:01:52 [12.9MiB/s] [================================>] 100%
Collecting BlueField booting status. Press Ctrl+C to stop…
 INFO[PSC]: PSC BL1 START
 INFO[BL2]: start
 INFO[BL31]: start
 INFO[UEFI]: UEFI loaded
 INFO[MISC]: Ubuntu installation started
 INFO[MISC]: Installation finished
 INFO[MISC]: Rebooting...
```

At fleet scale this is done from Kubernetes via the **DOCA Platform Framework** (DPF provisioning) or via the BMC Redfish API, never by hand.

### 5.5 Inspect the offloaded datapath on the DPU

In DPU mode the Arm OS sees **representor** netdevs: `p0`/`p1` for the physical uplinks, `pf0hpf`/`pf1hpf` for the host PF, and `pf0vfN` for host VFs. Default BFB images ship two OVS bridges:

```
ubuntu@dpu:~$ sudo ovs-vsctl show
a6b1c3d2-1f4e-4a2b-9e7d-0c5f2b8e1a9d
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
    ovs_version: "3.0.x-doca"
```

Confirm the eSwitch is in **switchdev** mode and hardware offload is enabled:

```
ubuntu@dpu:~$ sudo devlink dev eswitch show pci/0000:03:00.0
pci/0000:03:00.0: mode switchdev inline-mode none encap-mode basic

ubuntu@dpu:~$ sudo ovs-vsctl get Open_vSwitch . other_config:hw-offload
"true"
```

Prove that flows are actually running in hardware. This is the single most important check:

```
ubuntu@dpu:~$ sudo ovs-appctl dpctl/dump-flows type=offloaded
recirc_id(0),in_port(pf0hpf),eth(src=94:6d:ae:12:34:56,dst=b8:3f:d2:aa:bb:cc),eth_type(0x0800),ipv4(frag=no), packets:18452311, bytes:27101994412, used:0.010s, actions:p0
recirc_id(0),in_port(p0),eth(src=b8:3f:d2:aa:bb:cc,dst=94:6d:ae:12:34:56),eth_type(0x0800),ipv4(frag=no), packets:9233104, bytes:612443901, used:0.010s, actions:pf0hpf

ubuntu@dpu:~$ sudo ovs-appctl dpctl/dump-flows type=non-offloaded
```

High packet counters in `type=offloaded` and an empty or near-empty `non-offloaded` list mean the host's traffic is being switched by the ASAP² hardware, with zero host CPU and near-zero Arm CPU.

### 5.6 Kubernetes: exposing DPU/ConnectX capabilities to workloads

On GPU nodes, the **NVIDIA Network Operator** deploys the DOCA host driver, RDMA/SR-IOV device plugins and secondary networking. This is how pods consume the accelerated I/O, for example GPUDirect RDMA to storage over the BlueField ports. Pin every image version to the Network Operator release you deploy; the versions below are illustrative.

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
    forcePrecompiled: false
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
      safeLoad: false
      drain:
        enable: true
        force: true
        podSelector: ""
        timeoutSeconds: 300
        deleteEmptyDir: true
  sriovDevicePlugin:
    image: sriov-network-device-plugin
    repository: nvcr.io/nvidia/mellanox
    version: "network-operator-v25.4.0"
    config: |
      {
        "resourceList": [
          {
            "resourcePrefix": "nvidia.com",
            "resourceName": "bf3_storage_vf",
            "selectors": {
              "vendors": ["15b3"],
              "devices": ["101e"],
              "pfNames": ["ens1f0np0#0-7"],
              "isRdma": true
            }
          }
        ]
      }
  secondaryNetwork:
    cniPlugins:
      image: plugins
      repository: nvcr.io/nvidia/mellanox
      version: "network-operator-v25.4.0"
    multus:
      image: multus-cni
      repository: nvcr.io/nvidia/mellanox
      version: "network-operator-v25.4.0"
  nvIpam:
    image: nvidia-k8s-ipam
    repository: nvcr.io/nvidia/mellanox
    version: "network-operator-v25.4.0"
    enableWebhook: false
```

Create the VFs on the host-facing PF with the SR-IOV Network Operator. On a DPU in DPU mode, the VFs appear on the host, while their representors (`pf0vf0`...) appear on the Arm side, where OVS/HBN controls their connectivity:

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: bf3-storage-vfs
  namespace: nvidia-network-operator
spec:
  resourceName: bf3_storage_vf
  nodeSelector:
    feature.node.kubernetes.io/network-sriov.capable: "true"
    nvidia.com/gpu.present: "true"
  priority: 90
  numVfs: 8
  mtu: 9000
  nicSelector:
    vendor: "15b3"
    pfNames:
      - "ens1f0np0#0-7"
  deviceType: netdevice
  isRdma: true
```

IP pool and network attachment for pods:

```yaml
apiVersion: nv-ipam.nvidia.com/v1alpha1
kind: IPPool
metadata:
  name: storage-pool
  namespace: nvidia-network-operator
spec:
  subnet: 10.42.0.0/16
  perNodeBlockSize: 64
  gateway: 10.42.0.1
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: nvidia.com/gpu.present
            operator: In
            values:
              - "true"
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: storage-net
  namespace: nvidia-network-operator
spec:
  resourceName: bf3_storage_vf
  networkNamespace: ml-training
  ipam: |
    {
      "type": "nv-ipam",
      "poolName": "storage-pool"
    }
```

A training pod that reads its dataset over the DPU-attached storage fabric with RDMA:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: trainer-0
  namespace: ml-training
  annotations:
    k8s.v1.cni.cncf.io/networks: storage-net
spec:
  restartPolicy: Never
  containers:
    - name: trainer
      image: nvcr.io/nvidia/pytorch:25.04-py3
      command:
        - "bash"
        - "-c"
        - "ibv_devinfo && python /workspace/train.py --data /mnt/dataset"
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
      resources:
        limits:
          nvidia.com/gpu: 8
          nvidia.com/bf3_storage_vf: 1
        requests:
          nvidia.com/gpu: 8
          nvidia.com/bf3_storage_vf: 1
      volumeMounts:
        - name: dataset
          mountPath: /mnt/dataset
        - name: shm
          mountPath: /dev/shm
  volumes:
    - name: dataset
      persistentVolumeClaim:
        claimName: imagenet-pvc
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 64Gi
```

Verify from the node and the pod:

```
$ kubectl get node dgx-b200-01 -o jsonpath='{.status.allocatable}' | jq 'with_entries(select(.key|test("nvidia")))'
{
  "nvidia.com/bf3_storage_vf": "8",
  "nvidia.com/gpu": "8"
}

$ kubectl -n ml-training exec trainer-0 -- ip -br addr show net1
net1             UP             10.42.3.17/16

$ kubectl -n ml-training exec trainer-0 -- ibv_devinfo | grep -E 'hca_id|state|link_layer'
hca_id: mlx5_4
                        state:                  PORT_ACTIVE (4)
                        link_layer:             Ethernet
```

---

## 6. Verification and failure diagnosis

### 6.1 Health checklist

| Check | Where | Command | Healthy result |
|---|---|---|---|
| DPU enumerated on PCIe | Host | `lspci -d 15b3:` | ConnectX functions plus `SoC Management Interface` |
| Mode as intended | Host | `mlxconfig -d <dev> q INTERNAL_CPU_MODEL INTERNAL_CPU_OFFLOAD_ENGINE` | `EMBEDDED_CPU(1)` / `ENABLED(0)` for DPU mode |
| Arm OS booted | Host | `cat /dev/rshim0/misc` | `DISPLAY_LEVEL`/boot status shows Linux up. SSH via `tmfifo_net0` or OOB works |
| Firmware consistent | Host | `mlxfwmanager --query` | Versions match the validated BFB bundle |
| Physical link | Host or DPU | `mlxlink -d <dev> -m` | `State: Active`, expected speed, low BER, no FEC errors climbing |
| eSwitch mode | DPU | `devlink dev eswitch show pci/0000:03:00.0` | `mode switchdev` |
| OVS up and offloading | DPU | `systemctl is-active openvswitch-switch`, `ovs-vsctl get Open_vSwitch . other_config:hw-offload` | `active`, `"true"` |
| Flows in hardware | DPU | `ovs-appctl dpctl/dump-flows type=offloaded` | Counters increasing |
| RDMA ready | Host/pod | `ibv_devinfo`, `rdma link` | `PORT_ACTIVE`, `LINK_UP` |

### 6.2 Common failure modes

**Symptom: host has no network connectivity, but `ip link` on the host shows the PF UP.**

- *Cause:* the DPU is in DPU mode, and the Arm side is not forwarding. Possible reasons: OVS stopped, the bridge lost the `pf0hpf` port, the Arm OS is still booting or crashed, or a BFB upgrade is in progress.
- *Diagnose:*
  ```
  $ sudo cat /dev/rshim0/misc
  DISPLAY_LEVEL   0 (0:basic, 1:advanced, 2:log)
  BF_MODE         Unknown
  BOOT_MODE       1 (0:rshim, 1:emmc, 2:emmc-boot-swap)
  BOOT_TIMEOUT    150
  DROP_MODE       0 (0:normal, 1:drop)
  SW_RESET        0 (1: reset)
  DEV_NAME        pcie-0000:03:00.2
  DEV_INFO        BlueField-3(Rev 1)
  OPN_STR         N/A
  UP_TIME         431(s)

  $ sudo screen /dev/rshim0/console 115200
  ```
  Then on the DPU: `systemctl status openvswitch-switch`, `ovs-vsctl show`, `journalctl -u openvswitch-switch -b`.
- *Fix:* restore OVS and the bridge ports. If the Arm OS is unrecoverable, re-image with `bfb-install`. Treat the DPU OS as **critical-path infrastructure** with its own monitoring and alerting.

**Symptom: high host or Arm CPU, throughput below line rate.**

- *Cause:* flows are **not** being offloaded. Common reasons: `hw-offload` false; eSwitch in `legacy` mode; unsupported match/action (some conntrack states, certain tunnel options); offload table full.
- *Diagnose:*
  ```
  ubuntu@dpu:~$ sudo ovs-appctl dpctl/dump-flows type=non-offloaded | wc -l
  48211
  ubuntu@dpu:~$ sudo ovs-appctl dpctl/dump-flows type=offloaded | wc -l
  12
  ubuntu@dpu:~$ top -b -n1 | grep ovs-vswitchd
     1287 root      10 -10 4127840 512332  14200 S 395.0   1.6  812:03.12 ovs-vswitchd
  ```
- *Fix:* `ovs-vsctl set Open_vSwitch . other_config:hw-offload=true` then restart OVS. Confirm `switchdev`. Review flow rules for unsupported actions. On current BFB images consider OVS-DOCA (DOCA Flow-based datapath).

**Symptom: `mlxconfig` changes "don't take effect".**

- *Cause:* the setting is staged for "Next Boot" and only a warm reboot happened, so the adapter was never power-cycled.
- *Fix:* cold power cycle via BMC, or `mlxfwreset -d <dev> reset` where the platform supports it. Re-query and compare `Current` vs `Next Boot`.

**Symptom: DPU appears as a plain NIC, no RShim function, Arm unreachable.**

- *Cause:* the DPU was put into NIC mode (`INTERNAL_CPU_OFFLOAD_ENGINE=DISABLED(1)`), or the `rshim` service on the host is not running.
- *Fix:* check the mode, set back to DPU mode if intended, power-cycle, then `systemctl enable --now rshim`. Remember that only one rshim driver can own the device (host vs BMC). A BMC-side RShim will block the host one.

**Symptom: link flaps or degraded speed on storage fabric ports.**
```
$ sudo mlxlink -d /dev/mst/mt41692_pciconf0 -m -c

Operational Info
----------------
State                           : Active
Physical state                  : LinkUp
Speed                           : 200G
Width                           : 4x
FEC                             : Standard_RS-FEC - (544,514)
Loopback Mode                   : No Loopback
Auto Negotiation                : ON

Physical Counters and BER Info
------------------------------
Time Since Last Clear [Min]     : 1203.4
Effective Physical Errors       : 0
Effective Physical BER          : 15E-255
Raw Physical BER                : 3E-9
Link Down Counter               : 7
Link Error Recovery Counter     : 0
```
- A climbing `Link Down Counter` or raw BER worse than ~1E-6 points to the cable or transceiver, a dirty fiber, or a switch-port mismatch. Swap optics, clean fibers, and verify switch FEC and speed.

**Symptom: pods cannot get the `bf3_storage_vf` resource.**

- *Diagnose:* `kubectl -n nvidia-network-operator get sriovnetworknodestates -o yaml` (check `syncStatus`), and device plugin logs. Check `pfNames` matches the actual netdev name.
- *Fix:* the PF name changed after a mode switch or a kernel upgrade (`ens1f0np0` vs `enp3s0f0np0`). Update the selector, or select by PCI address via `rootDevices`.

### 6.3 Monitoring the DPU as a first-class asset

- Scrape the **DOCA Telemetry Service** (Prometheus endpoint on the DPU) for port counters, PCIe and flow statistics.
- Alert on: DPU Arm OS unreachable over OOB, OVS service down, offloaded flow ratio dropping, link-down counters, DPU temperature, BFB/firmware drift across the fleet.
- Version-control the BFB, firmware and `bf.cfg` together. Roll them out in canary batches, because a bad DPU image can take a node's network down entirely.

---

## 7. Exam-focused summary

- **Purpose of a DPU:** offload, accelerate and isolate data-center infrastructure services (networking, storage, security, management) from the host CPU.
- **Benefits:** frees host CPU cycles for applications and GPU feeding; line-rate deterministic I/O; zero-trust security in a separate trust domain; bare-metal multi-tenancy; better performance per watt and TCO.
- **What's inside BlueField-3:** ConnectX-7-class 400 Gb/s networking, 16 Arm A78 cores running their own OS, DDR5, PCIe Gen5 switch, hardware engines (ASAP², crypto, storage emulation, compression, regex, DPA).
- **Software:** DOCA is the SDK/runtime, analogous to CUDA for GPUs.
- **Three pillars:** CPU (general compute), GPU (accelerated compute), DPU (infrastructure compute).
- **In DGX:** ConnectX-7 adapters serve the compute fabric. The storage and in-band management networks use 2× dual-port ConnectX-7 cards on DGX H100 and **2× BlueField-3 DPUs on DGX B200**. NVLink handles intra-node GPU traffic. DGX systems ship their BlueField-3 DPUs in **NIC mode** by default.
- **SuperNIC vs DPU:** both are BlueField-3 based. The SuperNIC accelerates east-west GPU traffic in Spectrum-X Ethernet. The DPU handles north-south infrastructure, storage and security.
- **Modes:** DPU mode (Arm owns the eSwitch; default) vs NIC mode (behaves like ConnectX).

### Practice questions

1. *A cloud provider rents bare-metal DGX nodes and needs to enforce tenant network policy that a tenant with root access cannot disable. Which component provides this?*
   A BlueField DPU in DPU mode. Policy is enforced on the DPU's Arm OS and eSwitch, which is a separate trust domain from the host.
2. *Which network in a DGX SuperPOD is connected through the BlueField-3 DPUs?*
   The storage fabric and the in-band management network. The compute fabric uses the per-GPU ConnectX-7 adapters.
3. *What is the main benefit of offloading OVS to a DPU?*
   The host CPU no longer spends cycles on virtual switching. The datapath runs in hardware (ASAP²) at line rate, and the control plane runs isolated on the DPU.
4. *What SDK do developers use to program BlueField DPUs?*
   NVIDIA DOCA.
5. *How does a DPU differ from a SmartNIC?*
   A DPU adds general-purpose Arm cores running an independent OS, storage emulation and a separate security domain. A SmartNIC offers hardware offloads controlled by the host.

---

## Referencias

- NVIDIA NCA-AIIO Exam Study Guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- Offloading and Isolating Data Center Workloads with BlueField DPU (NVIDIA Technical Blog): https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA DGX SuperPOD Reference Architecture, DGX B200: https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide, Component Descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- Accelerating IO in the Modern Data Center: Network IO (NVIDIA Technical Blog): https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA BlueField DPU documentation (modes of operation, RShim, BFB installation): https://docs.nvidia.com/networking/display/bluefielddpuosv500
- NVIDIA DOCA documentation: https://docs.nvidia.com/doca/sdk/index.html
- NVIDIA Network Operator documentation: https://docs.nvidia.com/networking/display/kubernetes2540/index.html
- NVIDIA DGX B200 User Guide: https://docs.nvidia.com/dgx/dgxb200-user-guide/introduction-to-dgxb200.html
