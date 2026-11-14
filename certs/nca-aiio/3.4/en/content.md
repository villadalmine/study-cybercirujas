# 3.4 Identify the Key Considerations for Virtualizing Accelerated Infrastructure

> **Exam weight: 5.5%.** Expect scenario questions such as: "A team needs hardware-isolated GPU slices inside VMs. Which model fits?" or "Which component must be licensed for vGPU compute workloads?" You will also need to recognize the prerequisites, including IOMMU, SR-IOV, licensing, and NUMA, and the operational trade-offs of each GPU virtualization model.

---

## 1. Motivation: The Production Architecture Problem

GPUs are the most expensive and most underutilized resource in many data centers. A typical enterprise AI estate runs a mix of workloads:

| Workload | GPU demand profile | What it needs from the platform |
|---|---|---|
| Large-scale training (multi-node) | 100% of 8 GPUs per node for days, NVLink/NVSwitch, RDMA | Bare-metal-like performance, full topology |
| Fine-tuning / experimentation | Bursty, 1–2 GPUs, hours | Fast provisioning, self-service |
| Inference (NIM, Triton, vLLM) | Steady, often <30% of one GPU's compute | Right-sized slices, QoS, isolation |
| Jupyter / data science | Idle >80% of the time | Fractional sharing, oversubscription |
| VDI / visualization (vWS) | Graphics + some CUDA | Display, live migration, per-user isolation |

Two forces push organizations to **virtualize** this infrastructure rather than run everything on bare-metal Kubernetes:

1. **Operational model and governance.** Many enterprises already operate VMware vSphere, Nutanix AHV, Red Hat OpenShift Virtualization (KubeVirt), or KVM. Security teams require VM-level tenant boundaries. Change management works in terms of VMs, and HA, DRS, and backup tooling all assume VMs.
2. **Utilization economics.** An inference service that uses 15% of an H100 wastes the remaining 85% unless the GPU is partitioned. Virtualization makes that partitioning possible at the VM boundary, through vGPU and MIG-backed vGPU, rather than only at the container boundary.

The architectural problem is that GPUs were not designed as trivially shareable devices like CPUs. A GPU has:

- **Large framebuffer memory** that must be partitioned or time-shared.
- **Large PCIe BARs (MMIO)** that the hypervisor and the guest firmware must be able to map.
- **DMA capability**, so an IOMMU is required to keep a guest from reading host memory.
- **Context-switch cost**, so time-slicing has real overhead and introduces noisy-neighbor effects.
- **Topology sensitivity** to NUMA, PCIe switch placement, NVLink, and GPUDirect RDMA paths to NICs.

The key considerations tested in the NCA-AIIO exam reduce to this question: **which GPU virtualization model gives the required isolation, performance, density, and manageability, and what platform prerequisites, licensing, and monitoring does it impose?**

---

## 2. The GPU Virtualization Models

### 2.1 PCIe Passthrough (Direct Device Assignment)

In passthrough, the whole physical GPU is assigned to one VM through VFIO (KVM) or DirectPath I/O (vSphere).

- The **guest** runs the standard NVIDIA data center driver. No vGPU Manager runs on the host.
- The **IOMMU** (Intel VT-d / AMD-Vi) remaps the device's DMA into the guest's physical address space.
- Performance is near bare-metal, typically within low single-digit percent for compute-bound CUDA work.
- The ratio is **1 GPU : 1 VM**, though one VM may receive several GPUs. There is no sharing.
- **No live migration.** The device state lives in hardware that the hypervisor does not control.
- The host has no visibility into the GPU. Monitoring with DCGM or nvidia-smi happens **inside the guest**.
- On HGX systems with NVSwitch, passthrough of GPU groups requires care with **Fabric Manager** placement. NVIDIA documents a *full passthrough* model and a *shared NVSwitch multitenancy* model, in which Fabric Manager runs in a dedicated service VM.

### 2.2 NVIDIA vGPU, Time-Sliced

The **NVIDIA Virtual GPU Manager** is a host driver installed in the hypervisor. It carves a physical GPU into multiple virtual GPUs:

- **Framebuffer is statically partitioned.** Each vGPU gets a fixed slice. For example, an A100 40GB can be split into 2 × 20 GB, 4 × 10 GB, and so on.
- **Compute engines are time-sliced.** The vGPU scheduler gives each vGPU exclusive access to the GPU's engines in turn.
- Each guest runs an **NVIDIA vGPU guest driver**, which must match a supported branch of the host vGPU Manager, and must be **licensed**.
- On Ampere and later GPUs, vGPUs are exposed through **SR-IOV Virtual Functions (VFs)**. On pre-Ampere GPUs, they are exposed as mediated devices (mdev).
- **Live migration** is supported on supported hypervisors, such as vSphere vMotion and supported KVM distributions.

### 2.3 MIG-Backed vGPU

On MIG-capable GPUs (A30, A100, H100, H200, B200 and similar), the GPU is first partitioned with **Multi-Instance GPU**. Each vGPU is then backed by a **GPU Instance**.

- Each slice has **hardware isolation**: dedicated SMs, L2 cache slices, memory controllers, and DRAM bandwidth.
- There is **no time-slicing between vGPUs**, so there is no noisy neighbor on compute or memory bandwidth, and fault isolation is stronger.
- The model provides deterministic QoS, which suits multi-tenant inference.
- Partition shapes are constrained by the MIG geometry, with a maximum of 7 instances. They are less flexible than time-sliced vGPU sizes.

### 2.4 Container-Level Sharing (Bare Metal or Inside a VM)

These models do not virtualize the GPU at the hypervisor. They are relevant because the exam contrasts them with VM-level virtualization.

- **CUDA time-slicing through the Kubernetes device plugin**: one GPU is advertised as N replicas. There is **no memory or fault isolation**.
- **MIG on bare metal**: Kubernetes advertises `nvidia.com/mig-<profile>` resources.
- **CUDA MPS**: concurrent kernels from multiple processes with optional limits on active thread percentage. Isolation is limited.
- **NVIDIA Run:ai fractional GPUs**: a scheduler-enforced fraction of GPU memory and compute plus dynamic allocation, applied at the pod level.

---

## 3. Technical Comparison and Trade-Offs

### 3.1 Model Comparison

| Criterion | PCIe Passthrough | vGPU (time-sliced) | MIG-backed vGPU | K8s time-slicing | MIG (bare-metal K8s) | Run:ai fractions |
|---|---|---|---|---|---|---|
| Sharing unit | Whole GPU → 1 VM | Fixed FB slice + time share | GPU Instance | Replica of whole GPU | GPU Instance | Fraction of GPU memory/compute |
| Memory isolation | Full | Yes (static FB partition) | Yes (hardware) | **None** | Yes (hardware) | Software-enforced |
| Compute isolation | Full | Time-sliced (scheduler policy) | Hardware (dedicated SMs) | Time-sliced, no policy | Hardware | Time-shared, scheduler-governed |
| Fault isolation | Full | Per-VM (guest driver) | Strong | **None** (shared context domain) | Strong | Limited |
| Performance overhead | ~bare metal | Context switch + scheduler | Low (no time-slicing) | Context switch | Low | Low to moderate |
| Max density per GPU | 1 | Up to profile limits (for example 1 GB profiles on some GPUs) | 7 | Configurable (replicas) | 7 | Configurable |
| Live migration | **No** | Yes (supported hypervisors) | Supported in recent releases on supported hypervisors (check matrix) | N/A (pods reschedule) | N/A | N/A |
| Host visibility | None | Full (`nvidia-smi vgpu`) | Full | Full | Full | Full |
| Licensing | Data center driver; NVIDIA AI Enterprise entitlement for supported stack | **vGPU/AI Enterprise license required** in guest | **License required** | NVIDIA AI Enterprise optional (support) | Optional (support) | Run:ai license |
| Best fit | Training, max perf, NVLink/RDMA | VDI, dev VMs, dense mixed use | Multi-tenant inference with QoS | Dev/test, bursty notebooks | Inference on bare-metal K8s | Multi-team clusters, notebooks, NIM density |

### 3.2 vGPU Profile Series

vGPU profiles are named `<GPU>-<FB GB><series>` for time-sliced profiles and `<GPU>-<GPCs>-<FB GB><series>` for MIG-backed profiles.

| Series | Product | Purpose | Example |
|---|---|---|---|
| **C** | NVIDIA Virtual Compute Server (part of **NVIDIA AI Enterprise**) | Compute-intensive AI/HPC, CUDA | `A100-20C`, `A100-3-20C`, `H100-1-10C` |
| **Q** | NVIDIA RTX Virtual Workstation | Pro graphics + CUDA | `A40-24Q` |
| **B** | NVIDIA Virtual PC | Business desktops | `A16-2B` |
| **A** | NVIDIA Virtual Applications | RDSH / published apps | `A16-4A` |

For AI infrastructure, the **C-series** is the relevant one. It is consumed through **NVIDIA AI Enterprise** entitlements.

Reading a MIG-backed profile, `A100-3-20C` means an A100, a MIG instance with 3 compute slices, 20 GB of framebuffer, and the C-series.

### 3.3 vGPU Scheduler Policies (Time-Sliced vGPU Only)

| Policy | Behavior | When to use |
|---|---|---|
| **Best effort** (default) | Round-robin. An idle vGPU's time is given to busy ones. | Maximum aggregate throughput, VDI |
| **Equal share** | Each *running* vGPU gets an equal share. It adjusts as vGPUs start and stop. | Fairness among active tenants |
| **Fixed share** | Each vGPU gets a fixed share based on the maximum vGPUs of that type per GPU, even if others are idle. | Predictable, SLA-bound QoS |

Equal share and fixed share accept a configurable **time slice length**, set through the `RmPVMRL` registry key in the vGPU Manager. Longer slices favor throughput for compute and reduce context switches. Shorter slices favor latency for interactive and graphics work.

Scheduler policy does **not** apply to MIG-backed vGPU, because there is no time-slicing between instances.

### 3.4 Hypervisor and Platform Choices

| Platform | Passthrough | vGPU | MIG-backed vGPU | Live migration with vGPU | K8s integration |
|---|---|---|---|---|---|
| VMware vSphere | DirectPath I/O | Yes | Yes | vMotion | VMware Private AI Foundation, Tanzu/VKS, GPU Operator in guest |
| Red Hat OpenShift Virtualization / KubeVirt | Yes | Yes | Yes (version-dependent) | Supported in recent releases (check matrix) | Native (VMs as K8s objects, GPU Operator sandbox workloads) |
| Nutanix AHV | Yes | Yes | Yes | Yes (supported versions) | NKP + GPU Operator in guest |
| Generic KVM (Ubuntu, RHEL) | VFIO | Yes | Yes | Distribution-dependent | Manual or OpenStack Nova |

Always validate against the **NVIDIA vGPU / NVIDIA AI Enterprise support matrix**. The supported combination is defined by the triple of GPU, hypervisor version, and vGPU software branch.

---

## 4. Platform Prerequisites (Host Side)

### 4.1 Firmware and BIOS

| Setting | Why |
|---|---|
| **Intel VT-x / AMD-V** | CPU virtualization |
| **Intel VT-d / AMD-Vi (IOMMU)** | DMA remapping, mandatory for passthrough and vGPU |
| **SR-IOV** | Required for vGPU on Ampere and later (VFs), and for NIC VFs (RDMA) |
| **Above 4G Decoding / MMIO above 4 GB** | GPUs expose BARs of tens to hundreds of GB |
| **Resizable BAR / large MMIO window** | Ensures BAR1 fits; check the server vendor's GPU guide |
| **ACS (Access Control Services)** | Clean IOMMU groups. Note that GPUDirect P2P/RDMA may require ACS to be *disabled* on specific PCIe switches; this is a security versus performance trade-off. |
| **Power profile: Performance**, C-states as recommended | Latency and clock stability |
| **NUMA / Sub-NUMA Clustering per vendor guidance** | Affinity between vCPUs, memory, GPU, and NIC |

### 4.2 Kernel and Host Configuration (KVM)

```
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.8.0-87-generic root=/dev/mapper/vg-root ro intel_iommu=on iommu=pt

$ sudo dmesg | grep -iE 'DMAR|IOMMU' | head -5
[    0.000000] DMAR: IOMMU enabled
[    0.412883] DMAR: Host address width 46
[    1.802341] DMAR: Intel(R) Virtualization Technology for Directed I/O
[    1.802377] iommu: Default domain type: Passthrough (set via kernel command line)
[    2.113004] pci 0000:41:00.0: Adding to iommu group 37
```

`iommu=pt` keeps host-owned devices in passthrough mode, which avoids translation overhead on the host. Devices assigned to guests are still remapped.

Check the IOMMU groups. A GPU assigned with VFIO should sit alone in its group, or share it only with its own audio or USB functions.

```
$ for d in /sys/kernel/iommu_groups/*/devices/*; do
    g=${d%/devices/*}; g=${g##*/}
    printf 'group %s: ' "$g"; lspci -nns "${d##*/}"
  done | grep -i nvidia
group 37: 41:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)
group 81: c1:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)
```

### 4.3 NUMA Locality

```
$ cat /sys/bus/pci/devices/0000:41:00.0/numa_node
0
$ cat /sys/bus/pci/devices/0000:c1:00.0/numa_node
1
$ lscpu | grep -i 'numa node'
NUMA node(s):                    2
NUMA node0 CPU(s):               0-31,64-95
NUMA node1 CPU(s):               32-63,96-127
```

A VM using the GPU at `41:00.0` should have its vCPUs pinned to node 0 CPUs and its memory allocated from node 0, preferably with hugepages. Cross-socket traffic over UPI or Infinity Fabric degrades host-to-device bandwidth and adds latency to every `cudaMemcpy`.

---

## 5. vGPU Internals and Operations

### 5.1 Software Components

```
 ┌──────────────────────── Guest VM ──────────────────────────┐
 │  CUDA app / NIM / Triton                                     │
 │  NVIDIA vGPU guest driver (licensed via NLS)                 │
 │  nvidia-gridd  ── leases license from CLS/DLS ──────────┐    │
 └──────────────▲───────────────────────────────────────────│────┘
                │ VF / mdev (vfio-pci)                      │
 ┌──────────────┴──── Hypervisor host ───────────────┐      ▼
 │  NVIDIA Virtual GPU Manager (host driver)          │  NVIDIA License System
 │  vGPU scheduler · FB partitioning · SR-IOV VFs     │  CLS (cloud) or DLS (on-prem VM)
 └──────────────▲─────────────────────────────────────┘
                │
        Physical GPU (A100/H100/L40S/...)
```

- **Virtual GPU Manager**: the host driver package, shipped as a VIB for ESXi or as an RPM/DEB for KVM. It creates vGPUs and runs the scheduler.
- **Guest driver**: must be from a branch compatible with the host manager.
- **NVIDIA License System (NLS)**:
  - **CLS (Cloud License Service)** is hosted in the NVIDIA Licensing Portal.
  - **DLS (Delegated License Service)** is an on-premises virtual appliance, used for air-gapped or latency-sensitive environments.
  - The guest authenticates with a **client configuration token** placed in `/etc/nvidia/ClientConfigToken/`.
- **An unlicensed vGPU** runs with degraded capability: performance and features are restricted after a short grace period. Production must monitor license state.

### 5.2 Enabling vGPU on a KVM Host (Ampere and Later, SR-IOV)

```
$ nvidia-smi --query-gpu=name,pci.bus_id,driver_version --format=csv
name, pci.bus_id, driver_version
NVIDIA A100-PCIE-40GB, 00000000:41:00.0, 580.95.02
NVIDIA A100-PCIE-40GB, 00000000:C1:00.0, 580.95.02

$ sudo /usr/lib/nvidia/sriov-manage -e 00000000:41:00.0
Enabling VFs on 0000:41:00.0

$ lspci -d 10de: | head -6
41:00.0 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
41:00.4 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
41:00.5 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
41:00.6 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
41:00.7 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
41:01.0 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
```

VF enablement does not persist across reboots by default. The vGPU Manager package ships a systemd unit (`nvidia-sriov.service`, or the vendor equivalent) that runs `sriov-manage -e ALL` at boot. Verify that it is enabled.

There are two vGPU creation interfaces, depending on the vGPU release and kernel:

**A. mdev interface** (classic; RHEL and older Ubuntu kernels):

```
$ ls /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/
nvidia-471  nvidia-472  nvidia-473  nvidia-474  nvidia-475  nvidia-476

$ cat /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/nvidia-474/name
NVIDIA A100-20C
$ cat /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/nvidia-474/available_instances
1

$ UUID=$(uuidgen)
$ echo "$UUID" | sudo tee /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/nvidia-474/create
3f2c9a6e-8d41-4b7e-9c0a-2e5b7d1f4a90

$ mdevctl list
3f2c9a6e-8d41-4b7e-9c0a-2e5b7d1f4a90 0000:41:00.4 nvidia-474
$ sudo mdevctl define --auto --uuid "$UUID"     # persist across reboots
```

**B. Vendor-specific VFIO framework** (recent vGPU releases on kernels 6.8 and later, for example Ubuntu 24.04). The vGPU type is written directly to the VF, and the VF itself is then assigned to the VM as a PCI device:

```
$ cat /sys/bus/pci/devices/0000:41:00.4/nvidia/creatable_vgpu_types
ID    : vGPU Name
474   : NVIDIA A100-20C
475   : NVIDIA A100-40C

$ echo 474 | sudo tee /sys/bus/pci/devices/0000:41:00.4/nvidia/current_vgpu_type
474
```

Check the vGPU release documentation for your hypervisor to know which interface applies.

### 5.3 libvirt Domain Fragments

PCIe passthrough of the whole GPU (VFIO):

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0xc1' slot='0x00' function='0x0'/>
  </source>
</hostdev>
```

vGPU through the mdev interface:

```xml
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
  <source>
    <address uuid='3f2c9a6e-8d41-4b7e-9c0a-2e5b7d1f4a90'/>
  </source>
</hostdev>
```

The guest also needs NUMA pinning and a firmware that can map large BARs. Use OVMF/UEFI with q35, and enlarge the 64-bit PCI hole for 80 GB-class GPUs:

```xml
<vcpu placement='static' cpuset='0-15'>16</vcpu>
<numatune>
  <memory mode='strict' nodeset='0'/>
</numatune>
<memoryBacking>
  <hugepages>
    <page size='1' unit='G'/>
  </hugepages>
</memoryBacking>
<os firmware='efi'>
  <type arch='x86_64' machine='q35'>hvm</type>
</os>
```

On vSphere, the equivalents for large-BAR GPUs in passthrough are the VM advanced settings `pciPassthru.use64bitMMIO = "TRUE"` and `pciPassthru.64bitMMIOSizeGB`. Size the latter to the total BAR space of the assigned GPUs, rounded up to a power of two. The VM must also use EFI firmware.

### 5.4 MIG-Backed vGPU on the Host

```
$ sudo nvidia-smi -i 1 -mig 1
Enabled MIG Mode for GPU 00000000:C1:00.0
All done.

$ nvidia-smi mig -i 1 -lgip
+-----------------------------------------------------------------------------+
| GPU instance profiles:                                                      |
| GPU   Name             ID    Instances   Memory     P2P    SM    DEC   ENC  |
|                              Free/Total   GiB              CE    JPEG  OFA  |
|=============================================================================|
|   1  MIG 1g.5gb        19     7/7        4.75       No     14     0     0   |
|                                                             1     0     0   |
|   1  MIG 2g.10gb       14     3/3        9.75       No     28     1     0   |
|                                                             2     0     0   |
|   1  MIG 3g.20gb        9     2/2        19.62      No     42     2     0   |
|                                                             3     0     0   |
|   1  MIG 4g.20gb        5     1/1        19.62      No     56     2     0   |
|                                                             4     0     0   |
|   1  MIG 7g.40gb        0     1/1        39.25      No     98     5     0   |
|                                                             7     1     1   |
+-----------------------------------------------------------------------------+
```

With MIG enabled, the vGPU Manager offers MIG-backed types such as `A100-1-5C`, `A100-2-10C`, `A100-3-20C`, `A100-4-20C`, and `A100-7-40C`. When a vGPU of that type is created, the manager allocates the GPU instance.

### 5.5 Host-Side vGPU Observability

```
$ nvidia-smi vgpu
Fri Nov 14 10:21:07 2026
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 580.95.02              Driver Version: 580.95.02                 |
|---------------------------------+------------------------------+------------+
| GPU  Name                       | Bus-Id                       | GPU-Util   |
|      vGPU ID     Name           | VM ID     VM Name            | vGPU-Util  |
|=================================+==============================+============|
|   0  NVIDIA A100-PCIE-40GB      | 00000000:41:00.0             |  71%       |
|      3251634213  NVIDIA A100... | 1a7f...  ml-train-01         |     48%    |
|      3251634217  NVIDIA A100... | 2c09...  nim-llama-02        |     23%    |
+---------------------------------+------------------------------+------------+

$ nvidia-smi vgpu -q -i 0 | grep -E 'VM Name|vGPU Name|License Status|FB Memory|Used' 
        VM Name                           : ml-train-01
        vGPU Name                         : NVIDIA A100-20C
        License Status                    : Licensed (Expiry: 2026-12-14 10:03:12 GMT)
        FB Memory Usage
            Used                          : 15872 MiB
        VM Name                           : nim-llama-02
        vGPU Name                         : NVIDIA A100-20C
        License Status                    : Licensed (Expiry: 2026-12-14 10:05:44 GMT)
        FB Memory Usage
            Used                          : 18210 MiB

$ nvidia-smi vgpu -u -l 5        # per-vGPU SM / memory / encoder utilization, every 5 s
```

Query and set the scheduler state on the host:

```
$ nvidia-smi vgpu -ss
GPU 00000000:41:00.0
    Supported vGPU Scheduler Policies : best effort, equal share, fixed share
    Scheduler Policy                  : BEST_EFFORT
    ARR Mode                          : Disabled
```

### 5.6 Licensing the Guest

On the guest, place the token and set the feature type:

```
$ sudo cp client_configuration_token_11-14-2026-09-00-00.tok /etc/nvidia/ClientConfigToken/
$ sudo chmod 744 /etc/nvidia/ClientConfigToken/*.tok
$ grep -E '^FeatureType' /etc/nvidia/gridd.conf
FeatureType=1
$ sudo systemctl restart nvidia-gridd

$ nvidia-smi -q | grep -A3 'vGPU Software Licensed Product'
    vGPU Software Licensed Product
        Product Name                      : NVIDIA Virtual Compute Server
        License Status                    : Licensed (Expiry: 2026-12-14 10:03:12 GMT)

$ journalctl -u nvidia-gridd --since -10m | tail -3
Nov 14 10:03:10 ml-train-01 nvidia-gridd[1342]: Acquiring license. (Info: api.cls.licensing.nvidia.com; NVIDIA Virtual Compute Server)
Nov 14 10:03:12 ml-train-01 nvidia-gridd[1342]: License acquired successfully. (Info: api.cls.licensing.nvidia.com, NVIDIA Virtual Compute Server; Expiry: 2026-12-14 10:03:12 GMT)
```

For vGPU, the licensed product is derived from the vGPU type: C-series maps to Virtual Compute Server. `FeatureType` matters mainly for passthrough and bare-metal licensing scenarios.

---

## 6. Kubernetes and Virtualized GPUs

There are two distinct integration patterns, and the exam expects you to tell them apart:

1. **Kubernetes inside VMs** (vSphere, Nutanix, OpenStack). The VM has a vGPU or passthrough GPU. The **GPU Operator runs in the guest cluster** and deploys the **vGPU guest driver** with licensing, or the standard driver for passthrough.
2. **Kubernetes as the hypervisor** (KubeVirt / OpenShift Virtualization). The GPU Operator runs on the host cluster in **sandbox workloads** mode. It prepares GPUs for VMs through VFIO passthrough or vGPU, instead of for containers.

### 6.1 Pattern 1: GPU Operator in a Guest Cluster with vGPU

Create the licensing secret from the NLS token and `gridd.conf`:

```
$ cat gridd.conf
FeatureType=1

$ kubectl create namespace gpu-operator
namespace/gpu-operator created

$ kubectl create secret generic licensing-config -n gpu-operator \
    --from-file=gridd.conf \
    --from-file=client_configuration_token.tok
secret/licensing-config created

$ kubectl create secret docker-registry registry-secret -n gpu-operator \
    --docker-server=registry.example.com --docker-username=ci --docker-password="$REG_PW"
secret/registry-secret created
```

The vGPU guest driver image must be **built and pushed to a private registry**. It is distributed through the NVIDIA Licensing Portal, or through NGC for NVIDIA AI Enterprise customers with access to the AI Enterprise catalog. Helm values for the guest cluster:

```yaml
# values-guest-vgpu.yaml
operator:
  defaultRuntime: containerd
driver:
  enabled: true
  repository: registry.example.com/nvidia
  image: vgpu-guest-driver
  version: "580.95.02"
  imagePullSecrets:
    - registry-secret
  licensingConfig:
    secretName: licensing-config
    nlsEnabled: true
toolkit:
  enabled: true
devicePlugin:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
migManager:
  enabled: false
```

Older GPU Operator releases used `driver.licensingConfig.configMapName` with a ConfigMap. Recent releases prefer `secretName`, because the token is a credential.

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
$ helm install gpu-operator nvidia/gpu-operator -n gpu-operator \
    --version "${GPU_OPERATOR_VERSION}" -f values-guest-vgpu.yaml

$ kubectl get pods -n gpu-operator
NAME                                                  READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-x7k2p                           1/1     Running     0          4m
gpu-operator-6f9d8c7b5d-qx2lm                         1/1     Running     0          5m
nvidia-container-toolkit-daemonset-4h8tr              1/1     Running     0          4m
nvidia-cuda-validator-m2v9c                           0/1     Completed   0          3m
nvidia-dcgm-exporter-p8w6z                            1/1     Running     0          4m
nvidia-device-plugin-daemonset-tz5bq                  1/1     Running     0          4m
nvidia-driver-daemonset-9lcxs                         1/1     Running     0          5m
nvidia-operator-validator-rk4nd                       1/1     Running     0          4m

$ kubectl exec -n gpu-operator ds/nvidia-driver-daemonset -- nvidia-smi -q | grep -A2 'Licensed Product'
    vGPU Software Licensed Product
        Product Name                      : NVIDIA Virtual Compute Server
        License Status                    : Licensed (Expiry: 2026-12-14 10:12:40 GMT)
```

The guest sees `nvidia.com/gpu: 1` per vGPU. A pod consumes it normally:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1
```

```
$ kubectl logs cuda-vectoradd
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

### 6.2 Pattern 2: KubeVirt with GPU Operator Sandbox Workloads

The GPU Operator labels each node with a workload type through `nvidia.com/gpu.workload.config`:

| Label value | Operator deploys | Result |
|---|---|---|
| `container` (default) | Driver, toolkit, device plugin, DCGM | GPUs for pods |
| `vm-passthrough` | **vfio-manager** (binds GPUs to `vfio-pci`), **sandbox device plugin** | Whole GPUs for KubeVirt VMs |
| `vm-vgpu` | **vgpu-manager** (host vGPU Manager driver), **vgpu-device-manager** (creates vGPUs), sandbox device plugin | vGPUs for KubeVirt VMs |

A single node serves only one of these modes at a time. Plan node pools accordingly.

Helm values for the host cluster:

```yaml
# values-sandbox.yaml
sandboxWorkloads:
  enabled: true
  defaultWorkload: container
vfioManager:
  enabled: true
sandboxDevicePlugin:
  enabled: true
vgpuManager:
  enabled: true
  repository: registry.example.com/nvidia
  image: vgpu-manager
  version: "580.95.02"
  imagePullSecrets:
    - registry-secret
vgpuDeviceManager:
  enabled: true
  config:
    name: vgpu-devices-config
    default: A100-20C
```

The `vgpu-device-manager` configuration declares which vGPU types to create per node:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vgpu-devices-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    vgpu-configs:
      A100-20C:
        - devices: all
          vgpu-devices:
            "A100-20C": 2
      A100-10C:
        - devices: all
          vgpu-devices:
            "A100-10C": 4
      A100-40C:
        - devices: all
          vgpu-devices:
            "A100-40C": 1
```

KubeVirt must be told that the GPU Operator is the external device provider, and which devices VMs may request:

```yaml
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  configuration:
    developerConfiguration:
      featureGates:
        - GPU
        - DisableMDEVConfiguration
    permittedHostDevices:
      pciHostDevices:
        - pciVendorSelector: "10DE:20F1"
          resourceName: nvidia.com/GA100_A100_PCIE_40GB
          externalResourceProvider: true
      mediatedDevices:
        - mdevNameSelector: "NVIDIA A100-20C"
          resourceName: nvidia.com/NVIDIA_A100-20C
          externalResourceProvider: true
```

On OpenShift Virtualization, the same is expressed in the `HyperConverged` CR (`spec.permittedHostDevices`), which uses `pciDeviceSelector` instead of `pciVendorSelector`:

```yaml
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  permittedHostDevices:
    pciHostDevices:
      - pciDeviceSelector: "10DE:20F1"
        resourceName: nvidia.com/GA100_A100_PCIE_40GB
        externalResourceProvider: true
    mediatedDevices:
      - mdevNameSelector: "NVIDIA A100-20C"
        resourceName: nvidia.com/NVIDIA_A100-20C
        externalResourceProvider: true
```

Assign the node roles:

```
$ kubectl label node gpu-node-01 nvidia.com/gpu.workload.config=vm-passthrough --overwrite
node/gpu-node-01 labeled
$ kubectl label node gpu-node-02 nvidia.com/gpu.workload.config=vm-vgpu --overwrite
node/gpu-node-02 labeled
$ kubectl label node gpu-node-02 nvidia.com/vgpu.config=A100-20C --overwrite
node/gpu-node-02 labeled

$ kubectl get pods -n gpu-operator -o wide | grep -E 'vfio|vgpu|sandbox'
nvidia-sandbox-device-plugin-daemonset-2kq9x   1/1   Running   0   3m   10.128.2.14   gpu-node-01
nvidia-sandbox-device-plugin-daemonset-wl7pd   1/1   Running   0   2m   10.128.3.22   gpu-node-02
nvidia-sandbox-validator-7tbxf                 1/1   Running   0   3m   10.128.2.15   gpu-node-01
nvidia-sandbox-validator-j6m4c                 1/1   Running   0   2m   10.128.3.23   gpu-node-02
nvidia-vfio-manager-8n2rs                      1/1   Running   0   3m   10.128.2.16   gpu-node-01
nvidia-vgpu-device-manager-c5x8h               1/1   Running   0   2m   10.128.3.24   gpu-node-02
nvidia-vgpu-manager-daemonset-hq4zl            1/1   Running   0   3m   10.128.3.25   gpu-node-02

$ kubectl get node gpu-node-02 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia
"nvidia.com/NVIDIA_A100-20C":"4"

$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia
"nvidia.com/GA100_A100_PCIE_40GB":"2"
```

A KubeVirt VM requesting one vGPU, with dedicated CPUs, NUMA passthrough, and hugepages:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ml-train-vgpu
  namespace: ai-vms
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: ml-train-vgpu
    spec:
      nodeSelector:
        nvidia.com/gpu.workload.config: vm-vgpu
      domain:
        cpu:
          sockets: 1
          cores: 8
          threads: 1
          dedicatedCpuPlacement: true
          numa:
            guestMappingPassthrough: {}
        memory:
          guest: 64Gi
          hugepages:
            pageSize: 1Gi
        firmware:
          bootloader:
            efi:
              secureBoot: false
        devices:
          gpus:
            - name: vgpu0
              deviceName: nvidia.com/NVIDIA_A100-20C
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources:
          requests:
            memory: 64Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/ubuntu:24.04
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              hostname: ml-train-vgpu
              ssh_authorized_keys:
                - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyReplaceMe sre@example.com
```

For passthrough, change `deviceName` to `nvidia.com/GA100_A100_PCIE_40GB` and the `nodeSelector` value to `vm-passthrough`.

The guest still needs a driver. A vGPU requires the **vGPU guest driver plus a license**. A passthrough GPU requires the standard data center driver.

```
$ virtctl start ml-train-vgpu -n ai-vms     # not needed with runStrategy: Always
$ kubectl get vmi -n ai-vms
NAME            AGE   PHASE     IP             NODENAME      READY
ml-train-vgpu   92s   Running   10.0.2.2       gpu-node-02   True

$ virtctl ssh ubuntu@vmi/ml-train-vgpu -n ai-vms -c 'lspci -nn | grep -i nvidia'
06:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)
```

### 6.3 Container-Level Sharing on Bare Metal or Inside Large VMs

**Time-slicing through the device plugin.** This oversubscribes a GPU with no memory isolation:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: true
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

```
$ kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
    -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched

$ kubectl get node gpu-node-03 -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.replicas}{"\n"}{.status.allocatable.nvidia\.com/gpu}{"\n"}'
4
8
```

The node has 2 physical GPUs with 4 replicas each. A pod that leaks memory can OOM every other tenant on the same GPU.

**MIG through mig-manager** gives hardware isolation for pods:

```
$ kubectl label node gpu-node-04 nvidia.com/mig.config=all-1g.5gb --overwrite
node/gpu-node-04 labeled
$ kubectl get node gpu-node-04 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
success
$ kubectl get node gpu-node-04 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia
"nvidia.com/mig-1g.5gb":"14"
```

With `mig.strategy=mixed`, pods request the specific profile:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: triton-mig
  namespace: inference
spec:
  containers:
    - name: triton
      image: nvcr.io/nvidia/tritonserver:24.10-py3
      args:
        - tritonserver
        - --model-repository=/models
      resources:
        limits:
          nvidia.com/mig-1g.5gb: 1
```

**NVIDIA Run:ai fractional GPUs** are scheduler-managed fractions, useful for packing NIM microservices and notebooks:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nim-llm-fraction
  namespace: runai-team-a
  labels:
    runai/queue: team-a
  annotations:
    gpu-fraction: "0.5"
spec:
  schedulerName: runai-scheduler
  containers:
    - name: nim
      image: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
      ports:
        - containerPort: 8000
      env:
        - name: NGC_API_KEY
          valueFrom:
            secretKeyRef:
              name: ngc-api
              key: NGC_API_KEY
```

Run:ai also adds quota, fair-share, over-quota borrowing, and preemption across teams. It addresses the *organizational* side of utilization, which hardware partitioning alone does not solve. It can run in a bare-metal cluster or in a guest cluster backed by passthrough GPUs.

---

## 7. Monitoring and Telemetry Considerations

Where telemetry is visible depends on the virtualization model:

| Model | Host sees | Guest sees | DCGM placement |
|---|---|---|---|
| Passthrough | Nothing (device owned by VM) | Full GPU, all metrics including profiling | DCGM / dcgm-exporter **in guest** |
| vGPU (time-sliced) | Physical GPU + per-vGPU utilization, FB, license state (`nvidia-smi vgpu`) | Its vGPU: FB usage, utilization; **some metrics unavailable** (for example certain profiling counters, ECC/thermal) | Guest exporter for tenant view; host tools for capacity and fairness |
| MIG-backed vGPU | Physical GPU, MIG instances, per-vGPU stats | Its instance | Same as above |
| Bare-metal MIG / time-slicing | Everything | N/A | dcgm-exporter on node; MIG metrics labeled by `GPU_I_ID` |

Sample dcgm-exporter output from a guest with a vGPU:

```
$ kubectl port-forward -n gpu-operator ds/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|FB_USED|FB_FREE)'
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-6c1e...",device="nvidia0",modelName="NVIDIA A100-20C",Hostname="ml-train-01"} 47
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-6c1e...",device="nvidia0",modelName="NVIDIA A100-20C",Hostname="ml-train-01"} 15872
DCGM_FI_DEV_FB_FREE{gpu="0",UUID="GPU-6c1e...",device="nvidia0",modelName="NVIDIA A100-20C",Hostname="ml-train-01"} 4320
```

Here `modelName` reports the **vGPU type**, not the physical GPU.

Operational SLOs to track in virtualized GPU estates:

- **License state** per guest. A lapsed lease silently degrades performance. Alert on `nvidia-gridd` errors and on `License Status != Licensed`.
- **Per-vGPU utilization versus allocation**, to find over-provisioned profiles that should be downsized.
- **Physical GPU XID errors** on the host (`dmesg | grep -i xid`). One physical fault can affect every vGPU on that GPU.
- **Host/guest driver branch skew** after upgrades.

For whole-fleet management above the hypervisor layer, NVIDIA Base Command Manager provides cluster provisioning, monitoring, and workload management. DCGM remains the per-GPU telemetry and diagnostics engine. On the out-of-band side, the BMC (Redfish/IPMI) provides hardware health independent of the host OS or hypervisor.

---

## 8. Advanced Considerations

### 8.1 Performance Overhead Sources

| Source | Affects | Mitigation |
|---|---|---|
| vGPU context switching | Time-sliced vGPU | Fewer, larger profiles; fixed or equal share; tune `RmPVMRL`; use MIG-backed vGPU for QoS |
| Cross-NUMA DMA | All models | Pin vCPUs and memory to the GPU's NUMA node; hugepages |
| IOMMU translation | Passthrough, vGPU | `iommu=pt` for host devices; hugepages reduce IOTLB pressure |
| Missing large BAR | Passthrough | Above 4G decoding, 64-bit MMIO sizing, UEFI guest |
| vCPU contention | All | Dedicated CPUs (`dedicatedCpuPlacement`), avoid CPU overcommit on GPU hosts |
| Storage/network virtualization | Data loading | SR-IOV NIC VFs, virtio-multiqueue, GPUDirect Storage where supported |

### 8.2 Multi-GPU, NVLink, and GPUDirect RDMA in VMs

- **NVLink peer-to-peer** works in passthrough when all NVLink-connected GPUs are assigned to the **same VM**. On HGX/NVSwitch platforms, the Fabric Manager model must match: full passthrough, or shared NVSwitch multitenancy with Fabric Manager in a service VM.
- **Multi-vGPU per VM**, meaning several vGPUs in one VM, is supported only with specific (typically full-framebuffer) profiles. Check the release notes.
- **GPUDirect RDMA** in a VM requires:
  - the GPU and an **SR-IOV VF** (or PF) of a ConnectX/BlueField NIC passed into the same VM, ideally behind the same PCIe switch;
  - ATS and ACS configured per NVIDIA guidance;
  - the `nvidia-peermem` module in the guest.
- Multi-node training generally favors **passthrough** or bare metal for this reason. vGPU adds limits on P2P and RDMA.

### 8.3 Live Migration and Lifecycle

- **Passthrough cannot be live-migrated.** Plan maintenance with workload checkpointing and cordon/drain at the orchestration layer.
- **vGPU live migration** works only on supported hypervisor and GPU combinations, and requires compatible vGPU Manager versions on source and destination. Migration blackout time scales with dirty framebuffer.
- **Upgrade order:** host vGPU Manager first, within the supported host/guest compatibility window, then guest drivers. Under KubeVirt and the GPU Operator, upgrading `vgpuManager.version` triggers a driver reload on the node, so drain VMs off that node first.

### 8.4 Security and Multi-Tenancy

- Isolation strength runs, from strongest to weakest: **Passthrough ≈ MIG-backed vGPU > time-sliced vGPU > container MIG > Run:ai fractions / MPS > device-plugin time-slicing**.
- Hopper-class and later GPUs add **Confidential Computing**. The GPU is assigned in passthrough to a TEE VM (Intel TDX or AMD SEV-SNP), and memory and PCIe traffic are encrypted and attested. This is relevant for regulated multi-tenant AI.
- The vGPU guest debugging and profiling tools (CUDA debugger, Nsight) are **disabled by default per VM** and must be explicitly enabled through vGPU plugin parameters. Weigh this against tenant isolation requirements.

### 8.5 Capacity Planning Rules of Thumb

- **Time-sliced vGPU, older or equal-size mode:** all vGPUs on one physical GPU must be the **same type**. Recent releases add a mixed-size mode on supported GPUs. Plan profile pools per GPU, not per host.
- **MIG geometry is fixed per GPU.** For example, a `3g.20gb` plus `4g.20gb` layout leaves no room for more instances. Reconfiguration requires that no workloads run on that GPU.
- The framebuffer per profile must cover model weights, KV cache (for LLM inference), activations, and CUDA context overhead. Undersized profiles fail with OOM, not slowdowns.

---

## 9. Verification and Failure Diagnosis

### 9.1 Layered Verification Checklist

```
# 1. Firmware/kernel: IOMMU active?
$ sudo dmesg | grep -E 'DMAR: IOMMU enabled|AMD-Vi: .*IOMMU'
[    0.000000] DMAR: IOMMU enabled

# 2. Device bound to the right driver?
$ lspci -nnk -s 41:00.0
41:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)
	Subsystem: NVIDIA Corporation Device [10de:145f]
	Kernel driver in use: nvidia
	Kernel modules: nouveau, nvidia_vgpu_vfio, nvidia
#   vGPU host  -> nvidia (vGPU Manager);  passthrough -> vfio-pci

# 3. SR-IOV VFs present (Ampere+ vGPU)?
$ cat /sys/bus/pci/devices/0000:41:00.0/sriov_numvfs
16

# 4. vGPU Manager loaded and healthy?
$ lsmod | grep nvidia_vgpu_vfio
nvidia_vgpu_vfio       86016  0
$ systemctl is-active nvidia-vgpu-mgr
active

# 5. Guest: driver + license
$ nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
name, driver_version, memory.total [MiB]
NVIDIA A100-20C, 580.95.02, 20480 MiB

# 6. Workload: CUDA actually runs
$ kubectl logs cuda-vectoradd | tail -2
Test PASSED
Done
```

### 9.2 Failure Modes

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| VM fails to start: `vfio: failed to set iommu for container` / `IOMMU not found` | VT-d/AMD-Vi disabled or missing kernel parameter | `dmesg \| grep -i iommu` | Enable in BIOS; add `intel_iommu=on` (Intel) |
| VM fails: `group N is not viable` | Other devices share the IOMMU group | List `/sys/kernel/iommu_groups/N/devices` | Assign the whole group, move the card to another slot, fix ACS in BIOS |
| Guest sees GPU but `nvidia-smi` reports `No devices were found`, BAR errors in `dmesg` | Insufficient MMIO for large BARs | Guest `dmesg \| grep -i 'BAR\|NVRM'` | UEFI guest, Above 4G decoding, `pciPassthru.64bitMMIOSizeGB` / larger 64-bit PCI hole |
| `mdev_supported_types` or `creatable_vgpu_types` missing | VFs not enabled (Ampere+), or vGPU Manager not loaded | `sriov_numvfs`, `lsmod`, `journalctl -u nvidia-vgpu-mgr` | `sriov-manage -e ALL`; enable the systemd unit; check host driver install |
| `available_instances` is 0 | GPU already holds vGPUs of another type (equal-size mode), or MIG state mismatch | `nvidia-smi vgpu`, `nvidia-smi -q \| grep -i mig` | Destroy mismatched vGPUs; toggle MIG per profile type |
| Guest driver fails: version incompatibility in host log | Guest driver branch outside the host-supported window | Host `journalctl -u nvidia-vgpu-mgr` | Align with the release compatibility matrix |
| Performance drops after ~20 minutes, CUDA restricted | **Unlicensed vGPU** | `nvidia-smi -q \| grep 'License Status'`; `journalctl -u nvidia-gridd` | Valid client token, network reachability to CLS/DLS, correct clock/NTP |
| KubeVirt VMI `Pending`: insufficient `nvidia.com/...` | Wrong node workload label, resource name mismatch, or device plugin not running | `kubectl describe vmi`; `kubectl get node -o yaml \| grep nvidia.com` | Fix label (`vm-vgpu`/`vm-passthrough`), align `permittedHostDevices.resourceName`, check sandbox device plugin |
| KubeVirt creates conflicting mdevs | KubeVirt mdev management fighting vgpu-device-manager | `kubectl logs -n gpu-operator ds/nvidia-vgpu-device-manager` | Enable `DisableMDEVConfiguration` and `externalResourceProvider: true` |
| `nvidia.com/vgpu.config.state=failed` | Requested type not supported on that GPU / VF count | `kubectl logs ds/nvidia-vgpu-device-manager` | Choose a type valid for the GPU; check the ConfigMap name |
| Noisy neighbor latency spikes in inference | Time-sliced vGPU with best-effort scheduler | Host `nvidia-smi vgpu -u` | Fixed share, fewer vGPUs per GPU, or MIG-backed vGPU |
| All vGPUs on a GPU fail together | Physical GPU fault (XID) | Host `dmesg \| grep -i xid`; `dcgmi diag -r 3` (when GPU is drained) | RMA / reset; capacity headroom per GPU |
| Pods OOM randomly on time-sliced nodes | No memory isolation in device-plugin time-slicing | `nvidia-smi` process list per GPU | Move to MIG or vGPU for isolation; enforce app-level memory caps |
| Slow `cudaMemcpy` in VM | Cross-NUMA placement | Compare GPU `numa_node` with vCPU pinning (`virsh vcpupin`, `numastat -p`) | Pin to the local NUMA node; hugepages |

---

## 10. Exam Takeaways

- **Passthrough** gives 1 GPU to 1 VM: maximum performance, no sharing, no live migration, monitoring only in the guest.
- **vGPU (time-sliced)** gives a static framebuffer partition with time-shared compute. It requires the **vGPU Manager on the host, the vGPU guest driver, and an NLS license (CLS or DLS)**. It supports live migration on supported platforms. Its scheduler policies are best effort, equal share, and fixed share.
- **MIG-backed vGPU** gives hardware-isolated slices with deterministic QoS, up to 7 per GPU, and is the preferred choice for multi-tenant inference in VMs.
- **C-series profiles** are the compute profiles (Virtual Compute Server, delivered through **NVIDIA AI Enterprise**). Q, B, and A are graphics and VDI profiles.
- **Host prerequisites:** VT-x/VT-d (IOMMU), SR-IOV (Ampere and later vGPU, NIC VFs), Above 4G decoding and large MMIO, NUMA alignment, and a supported GPU/hypervisor/software triple.
- **Kubernetes:**
  - In guest clusters, the GPU Operator deploys the vGPU guest driver with a licensing secret.
  - On KubeVirt, the GPU Operator runs with `sandboxWorkloads.enabled=true` and node labels `vm-passthrough` or `vm-vgpu`.
  - Container sharing options are device-plugin time-slicing (no isolation), MIG (hardware isolation), and Run:ai fractions (scheduler-governed, with quotas).
- **Monitoring:** use DCGM in the guest for passthrough. For vGPU, use DCGM in the guest plus `nvidia-smi vgpu` on the host. Always monitor license state and host XIDs.

---

## Referencias

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA Multi-Instance GPU: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
- NVIDIA MIG User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
- NVIDIA Virtual GPU Software Documentation: https://docs.nvidia.com/vgpu/
- NVIDIA vGPU Software User Guide (profiles, scheduler policies, KVM/mdev, SR-IOV): https://docs.nvidia.com/vgpu/latest/grid-vgpu-user-guide/index.html
- NVIDIA License System User Guide (CLS/DLS, client configuration token): https://docs.nvidia.com/license-system/latest/
- NVIDIA AI Enterprise Documentation: https://docs.nvidia.com/ai-enterprise/
- NVIDIA GPU Operator, GPU Operator with KubeVirt (sandbox workloads): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-kubevirt.html
- NVIDIA GPU Operator, NVIDIA vGPU in guest clusters: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/install-gpu-operator-vgpu.html
- NVIDIA GPU Operator, Time-Slicing GPUs in Kubernetes: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- NVIDIA GPU Operator, MIG Support: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html
- NVIDIA Fabric Manager User Guide (NVSwitch virtualization models): https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/
- NVIDIA DCGM: https://developer.nvidia.com/dcgm
- NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
- NVIDIA IGX Orin BMC documentation (out-of-band management): https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
- Maximizing GPU Utilization with NVIDIA Run:ai and NVIDIA NIM: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
- KubeVirt User Guide, Host Devices / GPU assignment: https://kubevirt.io/user-guide/compute/host-devices/
- Kubernetes Documentation, Schedule GPUs: https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/
- Kubernetes Documentation: https://kubernetes.io/docs/home/