# Guided Exercises — Topic 3.4: Key Considerations for Virtualizing Accelerated Infrastructure

**Exam weight:** 5.5% · **Certification:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)

> **How to use these exercises.** Each exercise has numbered steps. If you have access to a host with an NVIDIA data center GPU (A100/H100/L40S) and a hypervisor or Kubernetes cluster, run the commands. If you don't, read each command and its **expected output**, then predict the behavior *before* answering the questions. The exam tests whether you can choose between virtualization models and identify the constraints each one imposes, not whether you can type commands from memory.
>
> All sample outputs assume an **A100-PCIE-40GB** (PCI ID `10de:20f1`) unless noted. Values such as UUIDs, bus IDs, and driver versions will differ on your hardware.

**Reference sources**

- NVIDIA Multi-Instance GPU: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
- NVIDIA DCGM: https://developer.nvidia.com/dcgm
- NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
- Maximizing GPU utilization with Run:ai and NIM: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
- NVIDIA BMC (IGX Orin) introduction: https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
- AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- Kubernetes documentation: https://kubernetes.io/docs/home/
- Supporting docs (not in the source list, but they are the canonical references for the commands used here): NVIDIA vGPU Software User Guide (https://docs.nvidia.com/vgpu/), NVIDIA GPU Operator (https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/), KubeVirt user guide (https://kubevirt.io/user-guide/)

---

## Exercise 0 — The decision map (read first)

Every virtualization question on the exam reduces to five considerations. Keep this table open while you work through the exercises.

| Model | Sharing unit | Memory isolation | Fault isolation | QoS / performance predictability | Live migration | License |
|---|---|---|---|---|---|---|
| **PCIe passthrough** (VFIO) | Whole GPU → 1 VM | Full (dedicated device) | Full | Bare-metal-like (~native) | No (device state not migratable) | None beyond the guest driver |
| **Time-sliced vGPU** (C-series) | Fraction of framebuffer, shared SMs over time | Framebuffer partitioned by the vGPU manager | Partial: a GPU reset affects all vGPUs | Depends on vGPU scheduler (best effort / equal / fixed share) | Yes, on supported hypervisors and versions | NVIDIA AI Enterprise (or vGPU license) |
| **MIG** (bare metal or containers) | GPU Instance: dedicated SMs, L2 slices, memory controllers | Hardware | Hardware (per instance) | Hardware-guaranteed | N/A at host level | None for MIG itself |
| **MIG-backed vGPU** | One MIG instance → 1 VM | Hardware | Hardware | Hardware-guaranteed | Supported on specific hypervisor/vGPU releases | NVIDIA AI Enterprise |
| **K8s time-slicing** (device plugin) | Oversubscribed `nvidia.com/gpu` replicas | **None** | **None** | None (contexts compete) | N/A | None |
| **MPS** | Concurrent CUDA processes | Limited (address-space separation; errors can propagate) | Limited | Configurable SM % limit | N/A | None |
| **Run:ai GPU fractions** | Software-enforced fraction of memory/time | Software-enforced | Shared GPU | Scheduler-managed, dynamic | N/A | Run:ai |

### Questions

0.1. A regulated tenant demands that a neighbour's out-of-memory error or Xid fault must never affect its inference service, and that it gets guaranteed memory bandwidth. Which two rows satisfy this?

0.2. Which models do **not** require an NVIDIA software license for the sharing mechanism itself?

---

## Exercise 1 — Prepare the host: IOMMU, BIOS, and NUMA

Every form of VM-level GPU virtualization (passthrough, vGPU, MIG-backed vGPU) depends on the platform's IOMMU (Intel VT-d / AMD-Vi) and, for Ampere and later GPUs with vGPU, on **SR-IOV**.

1. Check that the CPU exposes hardware virtualization and that the IOMMU is active:

   ```bash
   grep -Eoc '(vmx|svm)' /proc/cpuinfo
   sudo dmesg | grep -Ei 'DMAR|IOMMU|AMD-Vi' | head
   ```

   Expected output (Intel host):

   ```
   128
   [    0.000000] DMAR: IOMMU enabled
   [    0.412311] DMAR: Intel(R) Virtualization Technology for Directed I/O
   [    1.203117] iommu: Default domain type: Passthrough (set via kernel command line)
   ```

2. If the IOMMU is not enabled, add the kernel parameters and reboot:

   ```bash
   # Intel: intel_iommu=on iommu=pt   |  AMD: amd_iommu=on iommu=pt
   sudo grubby --update-kernel=ALL --args="intel_iommu=on iommu=pt"   # RHEL/Fedora
   # Debian/Ubuntu: edit GRUB_CMDLINE_LINUX in /etc/default/grub, then: sudo update-grub
   sudo reboot
   cat /proc/cmdline
   ```

3. Identify the GPUs and the driver currently bound to them:

   ```bash
   lspci -nnk -d 10de:
   ```

   Expected output:

   ```
   41:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)
           Subsystem: NVIDIA Corporation Device [10de:145f]
           Kernel driver in use: nvidia
           Kernel modules: nvidiafb, nouveau, nvidia_drm, nvidia
   ```

4. List IOMMU groups. A device can only be passed through together with **every** other device in its group:

   ```bash
   for g in /sys/kernel/iommu_groups/*; do
     for d in "$g"/devices/*; do
       echo "group $(basename "$g"): $(lspci -nns "$(basename "$d")")"
     done
   done | grep -i nvidia
   ```

   Expected output:

   ```
   group 52: 41:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)
   ```

5. Inspect NUMA locality for the GPU and its neighbours:

   ```bash
   cat /sys/bus/pci/devices/0000:41:00.0/numa_node
   nvidia-smi topo -m
   ```

   Expected output (excerpt):

   ```
   1
           GPU0    GPU1    NIC0    CPU Affinity    NUMA Affinity
   GPU0     X      SYS     PIX     32-63,96-127    1
   GPU1    SYS      X      SYS     0-31,64-95      0
   NIC0    PIX     SYS      X
   ```

### Questions

1.1. What does `iommu=pt` change, and why is it commonly used on GPU virtualization hosts?

1.2. Step 4 shows the A100 alone in group 52. What would you have to do if the GPU shared a group with a SATA controller that the host needs?

1.3. From step 5, a VM receives `GPU0` via passthrough. Its vCPUs are pinned to host cores 0–15. What is the performance consequence, and how do you fix it?

1.4. `GPU0` and `NIC0` show `PIX`. Why does that matter for a VM running GPUDirect RDMA workloads?

---

## Exercise 2 — PCIe passthrough with VFIO

Passthrough gives one VM the whole physical GPU. The host must **not** load the NVIDIA driver on that device; `vfio-pci` owns it instead.

1. Bind the GPU to `vfio-pci` at boot:

   ```bash
   echo "options vfio-pci ids=10de:20f1" | sudo tee /etc/modprobe.d/vfio.conf
   echo "softdep nvidia pre: vfio-pci"   | sudo tee -a /etc/modprobe.d/vfio.conf
   sudo dracut -f            # or: sudo update-initramfs -u
   sudo reboot
   lspci -nnk -s 41:00.0 | grep 'driver in use'
   ```

   Expected output:

   ```
           Kernel driver in use: vfio-pci
   ```

2. Attach it to a libvirt guest. Create `gpu-hostdev.xml`:

   ```xml
   <hostdev mode='subsystem' type='pci' managed='yes'>
     <source>
       <address domain='0x0000' bus='0x41' slot='0x00' function='0x0'/>
     </source>
   </hostdev>
   ```

   ```bash
   virsh attach-device ai-vm01 gpu-hostdev.xml --config
   virsh start ai-vm01
   ```

3. Pin vCPUs and memory to the GPU's NUMA node (node 1 from Exercise 1):

   ```bash
   for v in $(seq 0 15); do virsh vcpupin ai-vm01 "$v" $((32 + v)) --config; done
   virsh numatune ai-vm01 --mode strict --nodeset 1 --config
   ```

4. Inside the guest, install the standard NVIDIA data center driver and verify:

   ```bash
   nvidia-smi --query-gpu=name,memory.total,pci.bus_id --format=csv
   ```

   Expected output:

   ```
   name, memory.total [MiB], pci.bus_id
   NVIDIA A100-PCIE-40GB, 40960 MiB, 00000000:07:00.0
   ```

5. Try to live-migrate the VM:

   ```bash
   virsh migrate --live ai-vm01 qemu+ssh://host02/system
   ```

   Expected output:

   ```
   error: Requested operation is not valid: cannot migrate domain: domain has assigned non-USB host devices
   ```

### Questions

2.1. Why does the guest see the GPU at a different bus ID (`07:00.0`) than the host (`41:00.0`)?

2.2. Which guest driver does a passthrough VM need — the vGPU guest driver or the regular data center driver? Is an NVIDIA license server required?

2.3. Step 5 failed. Name two operational consequences for a platform team that runs passthrough VMs, and one mitigation.

2.4. A team wants to give 8 small inference VMs GPU access on a host with 2 A100s using passthrough. Why is this the wrong model?

---

## Exercise 3 — Time-sliced vGPU: profiles, SR-IOV, and the scheduler

With NVIDIA vGPU, the **NVIDIA Virtual GPU Manager** runs on the hypervisor and carves each physical GPU into virtual GPUs. On Ampere and later, each vGPU is backed by an **SR-IOV Virtual Function (VF)**.

1. On a KVM host with the vGPU Manager installed (not the regular driver), enable the VFs:

   ```bash
   sudo /usr/lib/nvidia/sriov-manage -e 00:41:0000.0
   lspci -d 10de: | head -4
   ```

   Expected output:

   ```
   41:00.0 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
   41:00.4 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
   41:00.5 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
   41:00.6 3D controller: NVIDIA Corporation GA100 [A100 PCIe 40GB] (rev a1)
   ```

2. List supported and currently creatable vGPU types:

   ```bash
   nvidia-smi vgpu -s -i 0
   nvidia-smi vgpu -c -i 0
   ```

   Expected output (`-s`, excerpt):

   ```
   GPU 00000000:41:00.0
       NVIDIA A100-4C
       NVIDIA A100-5C
       NVIDIA A100-8C
       NVIDIA A100-10C
       NVIDIA A100-20C
       NVIDIA A100-40C
   ```

3. Inspect the mediated-device types exposed on a VF and create one vGPU:

   ```bash
   ls /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/
   cat /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/nvidia-472/name
   cat /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/nvidia-472/available_instances
   UUID=$(uuidgen)
   echo "$UUID" | sudo tee /sys/bus/pci/devices/0000:41:00.4/mdev_supported_types/nvidia-472/create
   ```

   Expected output:

   ```
   nvidia-468  nvidia-469  nvidia-470  nvidia-471  nvidia-472  nvidia-473 ...
   NVIDIA A100-10C
   1
   a6c3d2e8-6f0b-4c2a-9d0e-3c1b7d5f9e21
   ```

   > The numeric `nvidia-NNN` type IDs vary by driver release; always map them via the `name` file. Recent vGPU releases on newer Linux kernels use a vendor-specific VFIO framework instead of `mdev` on some distributions — check the vGPU release notes for your hypervisor.

4. After creating four `A100-10C` vGPUs and starting their VMs, check the host view:

   ```bash
   nvidia-smi vgpu
   nvidia-smi vgpu -u
   ```

   Expected output (`nvidia-smi vgpu`, excerpt):

   ```
   +-----------------------------------------------------------------------------+
   | NVIDIA-SMI 550.90.05              Driver Version: 550.90.05                 |
   |---------------------------------+------------------------------+------------+
   | GPU  Name                       | Bus-Id                       | GPU-Util   |
   |      vGPU ID     Name           | VM ID     VM Name            | vGPU-Util  |
   |=================================+==============================+============|
   |   0  NVIDIA A100-PCIE-40GB      | 00000000:41:00.0             |  97%       |
   |      3251634177  NVIDIA A100-10C| 2a1b...   ai-vm01            |     61%    |
   |      3251634178  NVIDIA A100-10C| 7f3c...   ai-vm02            |     36%    |
   |      3251634179  NVIDIA A100-10C| 9d2e...   ai-vm03            |      0%    |
   |      3251634180  NVIDIA A100-10C| c41a...   ai-vm04            |      0%    |
   +---------------------------------+------------------------------+------------+
   ```

5. Change the vGPU scheduler from the default **best effort** to **equal share**, then to **fixed share**:

   ```bash
   # 0x00 = best effort (default), 0x01 = equal share, 0x11 = fixed share
   echo 'options nvidia NVreg_RegistryDwords="RmPVMRL=0x01"' | sudo tee /etc/modprobe.d/nvidia-vgpu-sched.conf
   sudo reboot
   sudo dmesg | grep -i 'scheduler'
   ```

   Expected output (excerpt):

   ```
   NVRM: GPU at 0000:41:00.0 has software scheduler ENABLED with policy EQUAL_SHARE.
   ```

6. Enable CUDA Unified Memory and profiling for one vGPU (both are **disabled by default** on vGPU):

   ```bash
   echo "enable_uvm=1, enable_profiling=1" | sudo tee /sys/bus/mdev/devices/$UUID/nvidia/vgpu_params
   ```

   The VM must be powered off when you write this file.

### Questions

3.1. Decode the profile name `A100-10C`: what does `10` mean, and what does `C` mean? What workload is the `Q` series intended for instead?

3.2. With `A100-10C` on a 40 GB GPU, what is the maximum number of vGPUs per physical GPU? What happens if you then try to create an `A100-20C` on the same GPU (assume a release that requires homogeneous time-sliced profiles)?

3.3. In step 4, `ai-vm01` and `ai-vm02` consume 97% of the GPU together while two VMs are idle. Under **best effort**, **equal share**, and **fixed share**, what fraction of GPU time can `ai-vm01` get at most? Which policy gives the most predictable latency?

3.4. Why does a time-sliced vGPU provide framebuffer isolation but *not* the same fault and bandwidth isolation as MIG?

3.5. A data scientist complains that `cudaMallocManaged` fails and Nsight Compute reports no counters inside their vGPU VM. What is the cause and the fix from step 6?

---

## Exercise 4 — MIG: hardware partitioning

MIG (Ampere and later: A100, A30, H100, H200, B200) splits one GPU into up to **seven** GPU Instances, each with dedicated SMs, L2 cache slices, memory controllers, and DRAM bandwidth.

1. Enable MIG mode on GPU 0 (requires no running processes on the GPU):

   ```bash
   sudo nvidia-smi -i 0 -mig 1
   nvidia-smi -i 0 --query-gpu=mig.mode.current,mig.mode.pending --format=csv
   ```

   Expected output:

   ```
   Enabled MIG Mode for GPU 00000000:41:00.0
   All done.
   mig.mode.current, mig.mode.pending
   Enabled, Enabled
   ```

   > On some platforms the change stays `Pending` until a GPU reset (`nvidia-smi -i 0 -r`) or a reboot.

2. List the available GPU Instance profiles:

   ```bash
   sudo nvidia-smi mig -lgip
   ```

   Expected output (excerpt):

   ```
   +-----------------------------------------------------------------------------+
   | GPU instance profiles:                                                      |
   | GPU   Name             ID    Instances   Memory     P2P    SM    DEC   ENC  |
   |                              Free/Total   GiB              CE    JPEG  OFA  |
   |=============================================================================|
   |   0  MIG 1g.5gb        19     7/7        4.75       No     14     0     0   |
   |                                                             1     0     0   |
   |   0  MIG 2g.10gb       14     3/3        9.75       No     28     1     0   |
   |                                                             2     0     0   |
   |   0  MIG 3g.20gb        9     2/2        19.62      No     42     2     0   |
   |                                                             3     0     0   |
   |   0  MIG 4g.20gb        5     1/1        19.62      No     56     2     0   |
   |                                                             4     0     0   |
   |   0  MIG 7g.40gb        0     1/1        39.38      No     98     5     0   |
   |                                                             7     1     1   |
   +-----------------------------------------------------------------------------+
   ```

3. Create one `4g.20gb` and one `3g.20gb` instance, each with its default Compute Instance (`-C`):

   ```bash
   sudo nvidia-smi mig -i 0 -cgi 5,9 -C
   nvidia-smi -L
   ```

   Expected output:

   ```
   Successfully created GPU instance ID  1 on GPU  0 using profile MIG 4g.20gb (ID  5)
   Successfully created compute instance ID  0 on GPU  0 GPU instance ID  1 using profile MIG 4g.20gb (ID  3)
   Successfully created GPU instance ID  2 on GPU  0 using profile MIG 3g.20gb (ID  9)
   Successfully created compute instance ID  0 on GPU  0 GPU instance ID  2 using profile MIG 3g.20gb (ID  2)
   GPU 0: NVIDIA A100-PCIE-40GB (UUID: GPU-5d1e7c3a-...)
     MIG 4g.20gb     Device  0: (UUID: MIG-8b2f4a91-...)
     MIG 3g.20gb     Device  1: (UUID: MIG-c07e2d55-...)
   ```

4. Try to add a `1g.5gb` instance:

   ```bash
   sudo nvidia-smi mig -i 0 -cgi 19 -C
   ```

   Expected output:

   ```
   Unable to create a GPU instance on GPU  0 using profile 19: Insufficient Resources
   Failed to create GPU instances: Insufficient Resources
   ```

5. Tear down and rebuild for many small tenants:

   ```bash
   sudo nvidia-smi mig -i 0 -dci
   sudo nvidia-smi mig -i 0 -dgi
   sudo nvidia-smi mig -i 0 -cgi 19,19,19,19,19,19,19 -C
   nvidia-smi -L | grep -c 'MIG 1g.5gb'
   ```

   Expected output (last line):

   ```
   7
   ```

6. Run a workload pinned to one instance:

   ```bash
   CUDA_VISIBLE_DEVICES=MIG-8b2f4a91-... python3 -c "import torch; print(torch.cuda.get_device_name(0), torch.cuda.mem_get_info()[1] // 2**20, 'MiB')"
   ```

   Expected output:

   ```
   NVIDIA A100-PCIE-40GB MIG 1g.5gb 4864 MiB
   ```

### Questions

4.1. Why did step 4 fail even though `4g` + `3g` = 7 compute slices and there is no visible free memory? Explain in terms of the 7 compute slices and 8 memory slices of an A100.

4.2. Name the three hardware resources that MIG partitions which time-sliced vGPU does not, and why this matters for p99 latency of inference services.

4.3. MIG reconfiguration requires that no process uses the GPU. What does this imply for how often a platform team should repartition, and which tooling (Exercise 6) automates it per node?

4.4. A training job needs NVLink peer-to-peer between GPUs. Can it use a MIG instance? (Look at the `P2P` column.)

4.5. When MIG is combined with vGPU (MIG-backed vGPU), what is the mapping between MIG instances and VMs, and how does the isolation compare with time-sliced vGPU?

---

## Exercise 5 — Licensing and guest-side verification

vGPU C-series profiles are licensed through **NVIDIA AI Enterprise**, served by the NVIDIA License System (NLS): a Cloud License Service (CLS) instance or an on-premises Delegated License Service (DLS) instance. Passthrough and bare-metal MIG need no vGPU license.

1. Inside a vGPU guest, place the client configuration token and restart the licensing daemon:

   ```bash
   sudo cp client_configuration_token_*.tok /etc/nvidia/ClientConfigToken/
   sudo sed -i 's/^#\?FeatureType=.*/FeatureType=1/' /etc/nvidia/gridd.conf
   sudo systemctl restart nvidia-gridd
   ```

2. Verify the license status:

   ```bash
   nvidia-smi -q | grep -A2 -i 'vGPU Software Licensed Product'
   ```

   Expected output:

   ```
       vGPU Software Licensed Product
           Product Name                      : NVIDIA AI Enterprise
           License Status                    : Licensed (Expiry: 2027-3-1 0:0:0 GMT)
   ```

3. Check the guest and host driver versions:

   ```bash
   # guest
   nvidia-smi --query-gpu=driver_version --format=csv,noheader
   # host
   nvidia-smi --query-gpu=driver_version --format=csv,noheader
   ```

   Expected output:

   ```
   550.90.07
   550.90.05
   ```

4. Look at the guest journal when the license server is unreachable:

   ```bash
   journalctl -u nvidia-gridd --since "1 hour ago" | tail -3
   ```

   Expected output (example):

   ```
   nvidia-gridd: Failed to acquire license from 10.0.20.15 (Info: NVIDIA AI Enterprise - Error: Unable to connect to the license server)
   nvidia-gridd: License acquisition failed. Retrying...
   ```

### Questions

5.1. The guest and host drivers report different versions (`550.90.07` vs `550.90.05`). Is this a problem? What is the compatibility rule between the vGPU Manager and the guest driver?

5.2. What happens to an unlicensed vGPU guest over time, and why does that make the license service a production dependency (HA, network path, firewall)?

5.3. Choose CLS or DLS for an air-gapped GPU cluster in a defence lab, and justify it.

---

## Exercise 6 — GPU sharing in Kubernetes with the GPU Operator

The NVIDIA GPU Operator automates the driver, container toolkit, device plugin, MIG Manager, DCGM Exporter, and (for VMs) the vGPU Manager and VFIO binding. Here you'll compare time-slicing and MIG on Kubernetes.

1. Install the GPU Operator:

   ```bash
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
   helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace
   kubectl get pods -n gpu-operator
   ```

   Expected output (excerpt):

   ```
   NAME                                       READY   STATUS      RESTARTS   AGE
   gpu-feature-discovery-x8k2p                1/1     Running     0          3m
   nvidia-container-toolkit-daemonset-7qz9f   1/1     Running     0          3m
   nvidia-cuda-validator-m4w2r                0/1     Completed   0          2m
   nvidia-dcgm-exporter-q2c7d                 1/1     Running     0          3m
   nvidia-device-plugin-daemonset-n5t8h       1/1     Running     0          3m
   nvidia-driver-daemonset-6vbz4              1/1     Running     0          4m
   nvidia-mig-manager-h9l3s                   1/1     Running     0          3m
   ```

2. Configure **time-slicing** with 4 replicas. Save as `time-slicing-config.yaml`:

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
           resources:
           - name: nvidia.com/gpu
             replicas: 4
   ```

   ```bash
   kubectl apply -f time-slicing-config.yaml
   kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
     -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'
   kubectl get node gpu-node01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   kubectl get node gpu-node01 --show-labels | tr ',' '\n' | grep -E 'gpu.replicas|gpu.product'
   ```

   Expected output:

   ```
   4
   nvidia.com/gpu.product=NVIDIA-A100-PCIE-40GB-SHARED
   nvidia.com/gpu.replicas=4
   ```

3. Run two pods that each request one replica. Save as `ts-pods.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: ts-a
   spec:
     restartPolicy: Never
     containers:
     - name: cuda
       image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
       command: ["bash", "-c", "nvidia-smi --query-gpu=name,memory.total --format=csv && sleep 3600"]
       resources:
         limits:
           nvidia.com/gpu: 1
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: ts-b
   spec:
     restartPolicy: Never
     containers:
     - name: cuda
       image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
       command: ["bash", "-c", "nvidia-smi --query-gpu=name,memory.total --format=csv && sleep 3600"]
       resources:
         limits:
           nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f ts-pods.yaml
   kubectl logs ts-a
   kubectl logs ts-b
   ```

   Expected output (both pods):

   ```
   name, memory.total [MiB]
   NVIDIA A100-PCIE-40GB, 40960 MiB
   ```

4. Switch the node to **MIG** using the MIG Manager. First remove the time-slicing default, then set the `mixed` strategy and apply a MIG layout label:

   ```bash
   kubectl patch clusterpolicies.nvidia.com/cluster-policy --type json \
     -p '[{"op": "remove", "path": "/spec/devicePlugin/config"}]'
   kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
     -p '{"spec": {"mig": {"strategy": "mixed"}}}'
   kubectl label node gpu-node01 nvidia.com/mig.config=all-1g.5gb --overwrite
   kubectl get node gpu-node01 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
   kubectl get node gpu-node01 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia
   ```

   Expected output (after the MIG Manager finishes):

   ```
   success
   "nvidia.com/mig-1g.5gb":"7"
   ```

5. Request a MIG slice. Save as `mig-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: mig-infer
   spec:
     restartPolicy: Never
     containers:
     - name: cuda
       image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
       command: ["bash", "-c", "nvidia-smi -L && sleep 3600"]
       resources:
         limits:
           nvidia.com/mig-1g.5gb: 1
   ```

   ```bash
   kubectl apply -f mig-pod.yaml && kubectl logs mig-infer
   ```

   Expected output:

   ```
   GPU 0: NVIDIA A100-PCIE-40GB (UUID: GPU-5d1e7c3a-...)
     MIG 1g.5gb      Device  0: (UUID: MIG-3a9c71e0-...)
   ```

### Questions

6.1. In step 3, both pods report the full 40960 MiB. What does this reveal about memory isolation under time-slicing, and what failure can occur when `ts-a` allocates 30 GiB and `ts-b` allocates 15 GiB?

6.2. Why does the node advertise `NVIDIA-A100-PCIE-40GB-SHARED`, and how would you use that label to keep latency-sensitive workloads off shared nodes?

6.3. With the `mixed` strategy you get resources like `nvidia.com/mig-1g.5gb`. What would the `single` strategy expose instead, and when is it appropriate?

6.4. Before applying the `mig.config` label, what must happen to GPU workloads already running on that node? What does the MIG Manager do about it?

---

## Exercise 7 — VMs on Kubernetes: KubeVirt with GPU passthrough and vGPU

The GPU Operator can prepare nodes for **sandboxed workloads** (VMs) instead of containers. A node's role is selected by the label `nvidia.com/gpu.workload.config` = `container` | `vm-passthrough` | `vm-vgpu`.

1. Enable sandbox workloads and label a node for passthrough:

   ```bash
   helm upgrade gpu-operator nvidia/gpu-operator -n gpu-operator \
     --set sandboxWorkloads.enabled=true --reuse-values
   kubectl label node gpu-node02 nvidia.com/gpu.workload.config=vm-passthrough --overwrite
   kubectl get pods -n gpu-operator -o wide | grep gpu-node02
   ```

   Expected output (excerpt):

   ```
   nvidia-sandbox-device-plugin-daemonset-p7x4k   1/1   Running   0   2m   10.42.3.17   gpu-node02
   nvidia-sandbox-validator-c2h9w                 1/1   Running   0   2m   10.42.3.18   gpu-node02
   nvidia-vfio-manager-5kq8n                      1/1   Running   0   2m   10.42.3.16   gpu-node02
   ```

2. Confirm the device resource name advertised by the sandbox device plugin:

   ```bash
   kubectl get node gpu-node02 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia
   ```

   Expected output:

   ```
   "nvidia.com/GA100_A100_PCIE_40GB":"1"
   ```

3. Permit the device in KubeVirt. Save as `kubevirt-cr-patch.yaml` (merge it into your existing `KubeVirt` CR):

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
   ```

   ```bash
   kubectl apply -f kubevirt-cr-patch.yaml
   ```

   > Feature-gate names and graduation status change between KubeVirt releases; check the KubeVirt user guide for your version.

4. Create a VM that consumes the GPU. Save as `gpu-vm.yaml`:

   ```yaml
   apiVersion: kubevirt.io/v1
   kind: VirtualMachine
   metadata:
     name: gpu-vm
   spec:
     runStrategy: Always
     template:
       spec:
         domain:
           cpu:
             cores: 16
             dedicatedCpuPlacement: true
           memory:
             hugepages:
               pageSize: 1Gi
           devices:
             gpus:
             - name: gpu1
               deviceName: nvidia.com/GA100_A100_PCIE_40GB
             disks:
             - name: containerdisk
               disk:
                 bus: virtio
           resources:
             requests:
               memory: 32Gi
         volumes:
         - name: containerdisk
           containerDisk:
             image: quay.io/containerdisks/ubuntu:22.04
   ```

   ```bash
   kubectl apply -f gpu-vm.yaml
   kubectl get vmi gpu-vm
   ```

   Expected output:

   ```
   NAME     AGE   PHASE     IP            NODENAME     READY
   gpu-vm   90s   Running   10.42.3.25    gpu-node02   True
   ```

5. Relabel a second node for vGPU and choose the profile it will expose:

   ```bash
   kubectl label node gpu-node03 nvidia.com/gpu.workload.config=vm-vgpu --overwrite
   kubectl label node gpu-node03 nvidia.com/vgpu.config=A100-10C --overwrite
   kubectl get node gpu-node03 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia
   ```

   Expected output:

   ```
   "nvidia.com/NVIDIA_A100-10C":"4"
   ```

### Questions

7.1. Why can a single node not serve container GPU workloads and passthrough VMs from the same GPU at the same time? What does the `vfio-manager` pod do?

7.2. Why is `DisableMDEVConfiguration` set when the GPU Operator manages vGPU devices?

7.3. In `gpu-vm.yaml`, what do `dedicatedCpuPlacement: true` and 1 GiB hugepages contribute, and which kubelet policy must be enabled on the node for `dedicatedCpuPlacement` to work?

7.4. For the vGPU node in step 5, where does the vGPU Manager come from, and what registry access is needed? (Hint: the vGPU Manager is licensed software, not a public image.)

---

## Exercise 8 — Observability and fractional scheduling

Virtualization changes **where** you can see GPU metrics.

1. In a passthrough VM or on bare metal, use DCGM:

   ```bash
   dcgmi discovery -l
   dcgmi dmon -e 203,252,1004 -c 3
   ```

   Expected output (`dmon`, excerpt; fields: 203 = GPU utilization, 252 = framebuffer used, 1004 = tensor pipe active):

   ```
   #Entity   GPUTL   FBUSD   TENSO
   ID
   GPU 0     87      31254   0.612
   GPU 0     89      31254   0.634
   GPU 0     88      31254   0.621
   ```

2. On the same host with MIG enabled, list entities:

   ```bash
   dcgmi discovery -c
   ```

   Expected output (excerpt):

   ```
   +-------------------+--------------------------------------------------------------------+
   | Instance Hierarchy                                                                     |
   +===================+====================================================================+
   | GPU 0             | GPU GPU-5d1e7c3a-... (EntityID: 0)                                 |
   | -> I 0/1          | GPU Instance (EntityID: 1)                                         |
   |    -> CI 0/1/0    | Compute Instance (EntityID: 0)                                     |
   | -> I 0/2          | GPU Instance (EntityID: 2)                                         |
   |    -> CI 0/2/0    | Compute Instance (EntityID: 1)                                     |
   +-------------------+--------------------------------------------------------------------+
   ```

3. In Kubernetes, query DCGM Exporter for per-MIG metrics:

   ```bash
   kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
   curl -s localhost:9400/metrics | grep '^DCGM_FI_DEV_FB_USED' | head -3
   ```

   Expected output (excerpt):

   ```
   DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-5d1e7c3a-...",device="nvidia0",modelName="NVIDIA A100-PCIE-40GB",GPU_I_PROFILE="1g.5gb",GPU_I_ID="7",Hostname="gpu-node01",namespace="default",pod="mig-infer",container="cuda"} 412
   ```

4. Write an alert that fires when a pod on a time-sliced node uses more than 90% of the physical framebuffer. Save as `gpu-shared-alert.yaml`:

   ```yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: gpu-shared-framebuffer
     namespace: gpu-operator
   spec:
     groups:
     - name: gpu-sharing
       rules:
       - alert: SharedGPUFramebufferNearlyFull
         expr: |
           sum by (Hostname, gpu) (DCGM_FI_DEV_FB_USED)
             /
           max by (Hostname, gpu) (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
             > 0.9
         for: 5m
         labels:
           severity: warning
         annotations:
           summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} is above 90% framebuffer"
           description: "Time-sliced replicas share framebuffer without isolation; the next allocation may OOM."
   ```

   ```bash
   kubectl apply -f gpu-shared-alert.yaml
   ```

5. Compare with fractional scheduling under Run:ai. A pod requests half a GPU through an annotation and the Run:ai scheduler. Save as `runai-fraction.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nim-half-gpu
     annotations:
       gpu-fraction: "0.5"
     labels:
       runai/queue: team-inference
   spec:
     schedulerName: runai-scheduler
     containers:
     - name: nim
       image: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
       ports:
       - containerPort: 8000
   ```

   ```bash
   kubectl apply -f runai-fraction.yaml
   ```

   > Run:ai annotations, queue labels, and the exact scheduler name depend on the Run:ai version and project setup; consult the Run:ai documentation for your cluster. The pattern — request a fraction, let a GPU-aware scheduler bin-pack — is what the exam tests.

### Questions

8.1. Inside a time-sliced vGPU guest, DCGM profiling fields such as `1004` (tensor active) return no data by default. Why, and where else can an operator observe per-vGPU utilization?

8.2. In step 4, why is the PromQL `expr` written with every line at the same indentation, and what would break if the `/` line were indented less than the others?

8.3. The NVIDIA blog on Run:ai and NIM describes increasing GPU utilization by packing multiple inference services per GPU. What is the key difference between a Run:ai GPU fraction and a MIG instance in terms of isolation, and what is the key advantage of fractions?

8.4. Which tool would you use for fleet-level health checks and diagnostics (`dcgmi diag`) on the hypervisor host of a time-sliced vGPU setup — and which one inside the guest?

---

## Exercise 9 — Capstone design scenario

You run a 4-node cluster, each node with 8× H100 SXM 80 GB connected by NVLink/NVSwitch. Requirements:

- **A.** A research team runs multi-node distributed training with NCCL over NVLink and InfiniBand; it needs maximum throughput.
- **B.** A bank's fraud-detection inference service needs guaranteed latency and strict tenant isolation; each replica fits in 10 GB.
- **C.** 40 data scientists need interactive Jupyter environments in isolated VMs with a full guest OS, and the VMs must survive host maintenance windows without stopping.
- **D.** CI pipelines run short CUDA unit tests (<2 GB, seconds each) and tolerate interference.

1. For each requirement, choose a virtualization model from Exercise 0.
2. Allocate nodes (the 4 nodes, 32 GPUs) across A–D.
3. List the license(s) required.
4. List the two biggest operational risks of your design.

### Questions

9.1. Which model fits A, and why is any form of sharing counterproductive there?

9.2. Which model fits B? Give the H100 MIG profile you'd use and how many replicas fit per GPU.

9.3. Which model fits C, and what is the hidden requirement in "survive host maintenance windows"?

9.4. Which model fits D, and what is the cheapest way to provide it in Kubernetes?

---

## Answers

<details>
<summary>Exercise 0</summary>

**0.1.** **MIG** (bare metal or containers) and **MIG-backed vGPU** (for VMs). Both give hardware-partitioned SMs, L2, memory controllers, and DRAM bandwidth, with per-instance fault isolation. Passthrough also isolates fully, but it dedicates a whole GPU; it is not a *sharing* model.

**0.2.** PCIe passthrough, bare-metal MIG, Kubernetes time-slicing, and MPS. vGPU (time-sliced or MIG-backed) requires NVIDIA AI Enterprise / vGPU licensing. Run:ai is a commercial product with its own licensing.
</details>

<details>
<summary>Exercise 1</summary>

**1.1.** `iommu=pt` (passthrough mode) puts devices that the *host* uses into an identity-mapped IOMMU domain, so host DMA does not pay translation overhead. Devices assigned to VMs via VFIO still get full IOMMU translation and isolation. You get isolation where you need it and no overhead elsewhere.

**1.2.** Everything in an IOMMU group must go to the same owner. Options: move the GPU to a different PCIe slot or root port that has proper ACS (Access Control Services) isolation, update the BIOS/firmware, or choose a platform that is certified for the workload (NVIDIA-Certified Systems). The ACS override kernel patch breaks the isolation guarantee and is not acceptable in production.

**1.3.** The GPU sits on NUMA node 1 (CPUs 32–63, 96–127). Cores 0–15 are on node 0, so every host↔device transfer and every kernel launch crosses the inter-socket link (UPI/Infinity Fabric). Expect higher latency and lower H2D/D2H bandwidth. Fix: pin vCPUs to node 1 cores (`virsh vcpupin` to 32–47) and bind guest memory to node 1 (`virsh numatune --mode strict --nodeset 1`), as in Exercise 2 step 3.

**1.4.** `PIX` means the GPU and NIC share a single PCIe switch. GPUDirect RDMA traffic then goes peer-to-peer through that switch without traversing the CPU root complex. To keep that benefit in a VM, pass through **both** the GPU and the NIC (or a NIC VF) to the same VM and preserve topology. Otherwise, RDMA performance drops or P2P is not possible at all.
</details>

<details>
<summary>Exercise 2</summary>

**2.1.** The guest sees a virtual PCIe topology that QEMU emulates. The device is remapped into the guest's own bus numbering; the IOMMU translates the guest's DMA addresses to host physical addresses.

**2.2.** The regular NVIDIA data center driver, the same one as on bare metal. No vGPU license is required. Passthrough is not vGPU.

**2.3.** Consequences: (1) host maintenance (firmware, kernel, hardware) requires shutting down or restarting the VM, so you need application-level checkpointing or redundancy; (2) the scheduler cannot rebalance load by moving VMs. Mitigation: design workloads for restart (training checkpoints, replicated inference behind a load balancer), drain via orchestration, or use vGPU on a hypervisor/release that supports vGPU live migration when mobility is a hard requirement.

**2.4.** Passthrough is 1 GPU → 1 VM, so 2 GPUs serve at most 2 VMs; 6 VMs get nothing, and the 2 that do get a GPU likely waste most of it. Use vGPU (for example `A100-10C`, 4 per GPU = 8 VMs) or MIG-backed vGPU for hardware isolation.
</details>

<details>
<summary>Exercise 3</summary>

**3.1.** `10` = 10 GB of framebuffer assigned to the vGPU. `C` = Compute series, intended for AI/ML/HPC compute workloads and licensed with NVIDIA AI Enterprise. `Q` = virtual workstation series for professional graphics (CAD, rendering), licensed as RTX Virtual Workstation. (`B` = virtual PC, `A` = virtual apps.)

**3.2.** 40 GB ÷ 10 GB = **4** vGPUs. In releases that require homogeneous time-sliced profiles per physical GPU, creating an `A100-20C` on a GPU that already hosts `A100-10C` vGPUs fails: available instances for the other type drop to 0. Newer vGPU releases support mixed-size time-sliced profiles on specific GPUs; check the release notes.

**3.3.**
- **Best effort** (default): time slices go to vGPUs that have work, so `ai-vm01` can approach 100% when the others are idle (here it shares with `ai-vm02`). Best utilization, worst predictability.
- **Equal share**: GPU time is divided equally among *running/active* vGPUs. With 4 running VMs, each gets 1/4 when all are busy; idle time is not redistributed the same way as best effort, so `ai-vm01` is capped at about 25%.
- **Fixed share**: time is divided according to the *maximum* number of vGPUs of that type the GPU supports (4 for `A100-10C`), regardless of how many exist or are active, so 25% always.
- **Fixed share** gives the most predictable latency, at the cost of idle capacity.

**3.4.** The vGPU Manager partitions the framebuffer, so one VM cannot read another's memory. But all vGPUs time-share the same SMs, L2 cache, and memory bandwidth, and a GPU-level fault (some Xid errors, or a GPU reset) affects every vGPU on that GPU. MIG partitions SMs, L2, and memory controllers in hardware and contains faults per instance.

**3.5.** CUDA Unified Memory and the CUDA profiling counters are disabled by default on vGPU. Power off the VM and write `enable_uvm=1` (Unified Memory) and `enable_profiling=1` (profilers/Nsight counters) to the vGPU's `vgpu_params` file on the host; `enable_debugging=1` does the same for debuggers. Note that enabling these features can affect capabilities such as live migration for that vGPU.
</details>

<details>
<summary>Exercise 4</summary>

**4.1.** An A100 has **7 compute slices** and **8 memory slices** (5 GB each on the 40 GB model). `4g.20gb` uses 4 compute + 4 memory slices; `3g.20gb` uses 3 compute + 4 memory slices. Together: 7/7 compute and 8/8 memory. No compute slice remains for a `1g.5gb`, so the creation fails with `Insufficient Resources`. Placement rules are also fixed: instance profiles can only start at specific slice positions.

**4.2.** MIG partitions (1) the SMs, (2) the **L2 cache** slices, and (3) the **memory controllers / DRAM bandwidth** (plus copy engines and decoders). Time-sliced vGPU shares all of these, so a noisy neighbour can evict your L2 lines and saturate memory bandwidth, inflating tail latency. MIG eliminates that cross-tenant interference, so p99 latency stays stable.

**4.3.** Repartitioning is disruptive (all workloads on the GPU must stop), so treat layouts as relatively static node pools sized to demand, not as something you change per job. The **GPU Operator MIG Manager** applies layouts declaratively via the `nvidia.com/mig.config` node label.

**4.4.** No. The `P2P` column shows `No` for all MIG profiles: MIG instances do not support NVLink peer-to-peer. Distributed training that relies on NVLink P2P needs full GPUs.

**4.5.** One MIG instance (GPU Instance) → one VM. Each VM receives dedicated hardware resources with hardware fault isolation and guaranteed QoS, which is stronger than time-sliced vGPU, where all VMs share SMs, L2, and bandwidth through time slicing.
</details>

<details>
<summary>Exercise 5</summary>

**5.1.** Not necessarily. The rule is **branch compatibility**: the guest driver must belong to a branch supported by the vGPU Manager on the host (normally the same release branch; NVIDIA documents which combinations are supported). Different minor build numbers within a compatible release are expected, because guest and host packages are versioned separately. An incompatible guest driver fails to load or the vGPU fails to start.

**5.2.** Without a license, the vGPU first works at full capability briefly, then becomes progressively restricted (performance and features degrade, and CUDA workloads become unusable) until a license is acquired. Licenses are leased and must be renewed, so the license service is a hard runtime dependency: run DLS in HA, allow the required ports through firewalls, and monitor `nvidia-gridd` and license expiry.

**5.3.** **DLS** (Delegated License Service), which runs on-premises as a virtual appliance and serves licenses with no connection to NVIDIA's cloud at runtime. CLS needs internet access to the NVIDIA cloud, which an air-gapped site cannot provide.
</details>

<details>
<summary>Exercise 6</summary>

**6.1.** Time-slicing provides **no memory isolation**: every replica sees, and can allocate from, the entire 40 GB. If `ts-a` allocates 30 GiB and `ts-b` then asks for 15 GiB, `ts-b` gets a CUDA OOM error. Depending on timing, either pod can fail. There is no fault isolation either.

**6.2.** GPU Feature Discovery appends `-SHARED` when time-slicing is active (configurable via `renameByDefault`/flags) so that workloads can tell they are getting an oversubscribed replica, not a dedicated GPU. Use node affinity: latency-sensitive pods require `nvidia.com/gpu.product` without the `-SHARED` suffix (or `nvidia.com/gpu.replicas` = `1`), or taint the shared node pool and let only tolerant workloads schedule there.

**6.3.** `single` exposes MIG slices as plain `nvidia.com/gpu` resources. It requires every GPU on the node to use the same MIG profile. It suits homogeneous node pools and existing manifests that already request `nvidia.com/gpu`. `mixed` exposes each profile as a distinct resource and allows heterogeneous layouts.

**6.4.** No process can be using the GPU while MIG is reconfigured. The MIG Manager stops the GPU Operator's own GPU clients (device plugin, DCGM Exporter, and so on), applies the layout, and restarts them. Your user workloads must be drained beforehand (cordon + drain), because pods using the GPU block or break the reconfiguration. Watch `nvidia.com/mig.config.state` for `success` or `failed`.
</details>

<details>
<summary>Exercise 7</summary>

**7.1.** A GPU can be bound to only one kernel driver at a time: `nvidia` (containers) or `vfio-pci` (passthrough). The `vfio-manager` pod unbinds the GPUs from `nvidia` and binds them to `vfio-pci` so KubeVirt can assign them to VMs. This is why the operator works with per-node roles via `nvidia.com/gpu.workload.config`.

**7.2.** It tells KubeVirt not to create or manage mediated devices itself; otherwise KubeVirt and the GPU Operator's vGPU Device Manager would both try to configure the vGPU devices and conflict. With `externalResourceProvider: true`, the NVIDIA sandbox device plugin advertises the devices instead of KubeVirt's built-in plugin.

**7.3.** `dedicatedCpuPlacement: true` pins vCPUs to exclusive physical cores, which removes CPU contention and jitter from the host. 1 GiB hugepages reduce TLB misses and page-table overhead for guest memory and large DMA buffers. The node must run the kubelet with **CPU Manager policy `static`** (and the pod must be in the Guaranteed QoS class) for dedicated CPU placement to work. Hugepages must be pre-allocated on the node.

**7.4.** The vGPU Manager is not distributed publicly. You download it from the NVIDIA Licensing Portal (NVIDIA AI Enterprise entitlement), build a vGPU Manager container image from it, and push it to a **private registry**. The GPU Operator then pulls it using an image pull secret. Guest VMs still need NLS licenses.
</details>

<details>
<summary>Exercise 8</summary>

**8.1.** Profiling counters are disabled by default for vGPU (see 3.5: `enable_profiling`), and in time-sliced mode the hardware counters are shared, so per-VM attribution is restricted. Per-vGPU utilization is visible on the **hypervisor host** with `nvidia-smi vgpu -u` / `nvidia-smi vgpu -q`, or through the hypervisor's management tooling.

**8.2.** In a YAML block scalar (`expr: |`), the indentation of the first line fixes the scalar's indentation. A line indented less than that ends the scalar. With the `/` line under-indented, YAML would try to parse `/` as a new key at the parent level and the document would fail to parse; the rule would never load. Relative extra indentation inside the scalar (as with `/` and the following line) is fine and is preserved.

**8.3.** A Run:ai fraction is **software-enforced** sharing on a single GPU (memory limits and time scheduling by Run:ai's scheduler and runtime). It offers neither hardware isolation of SMs, L2 cache, and bandwidth nor hardware fault isolation. MIG is hardware-partitioned. The advantage of fractions is **flexibility**: any size (for example 0.3 or 0.5), dynamic and without repartitioning, on GPUs that do not support MIG, with quota/queue-aware bin-packing that raises utilization for bursty inference such as NIM microservices.

**8.4.** On the host: DCGM (and `nvidia-smi`) against the physical GPU for health, diagnostics, and policy. In the guest: `nvidia-smi` and DCGM report the vGPU view (framebuffer, guest-visible utilization), but not physical-GPU diagnostics such as a full `dcgmi diag` hardware run. Those belong on the host.
</details>

<details>
<summary>Exercise 9</summary>

**9.1.** **Bare metal (or containers on bare metal with whole GPUs), or full-GPU passthrough if VMs are mandatory.** Distributed training needs all SMs, full HBM bandwidth, NVLink/NVSwitch P2P (unavailable on MIG; see 4.4), and GPUDirect RDMA to the InfiniBand NICs. Any time-slicing adds context-switch overhead and contention; MIG removes P2P. Allocate, for example, 2 nodes (16 GPUs) as whole GPUs.

**9.2.** **MIG** (containers) or **MIG-backed vGPU** (if the bank requires VMs). On an H100 80 GB, `1g.10gb` gives **7 instances per GPU**, each with dedicated SMs, L2, and bandwidth: guaranteed latency and hardware fault isolation. One node gives up to 56 isolated replicas. MIG-backed vGPU additionally requires NVIDIA AI Enterprise.

**9.3.** **Time-sliced vGPU (C-series)**, or MIG-backed vGPU where the hypervisor and vGPU release support migration. Hidden requirement: **vGPU live migration**, which passthrough cannot do (2.3) and which only works on supported hypervisor/vGPU releases, with matching profiles and capacity on the destination host. Features such as `enable_uvm`/profiling may block migration. Licensing: NVIDIA AI Enterprise via a DLS/CLS, deployed in HA. Example: one node, `H100-20C` (4 per GPU) = 32 VMs, or `H100-16C` (5 per GPU) = 40 VMs, sized to the scientists' needs.

**9.4.** **Kubernetes time-slicing** via the GPU Operator device plugin ConfigMap (Exercise 6). It needs no license, tolerates interference by design, and fits small, short-lived jobs. Mark the nodes `-SHARED` and taint them so production workloads never land there. Alternatively, use part of the MIG pool with `1g.10gb` if some tests are flaky under contention.

**Licenses:** NVIDIA AI Enterprise for vGPU (C, and B if MIG-backed vGPU is used); none for bare metal, MIG on containers, or time-slicing.

**Top risks:** (1) License service outage degrading every vGPU VM → HA DLS and monitoring. (2) MIG/time-slicing layout mismatched with real demand, which strands capacity; repartitioning requires draining → size node pools from utilization data (DCGM Exporter) and review quarterly. Also: framebuffer OOMs on time-sliced nodes (alert from Exercise 8).
</details>