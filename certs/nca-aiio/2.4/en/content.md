# Topic 2.4 — On-Prem vs Cloud AI Infrastructure: Advantages, Challenges, and Considerations

**Exam:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Weight:** 4.0

---

## 1. Motivation: The Production Architecture Problem

Every organization that runs AI at scale eventually has to decide **where GPUs live**. This is a systems-engineering decision with consequences that last years, and it is more than a procurement checkbox. It has four parts:

1. **Physics.** An 8-GPU DGX H100 draws up to **~10.2 kW**. A DGX B200 draws up to **~14.3 kW**. Most legacy enterprise racks were designed for 8–15 kW *per rack*, not per server. Where the electrons and the heat go is a first-order constraint.
2. **Fabric topology.** Distributed training is bound by communication. NVLink/NVSwitch inside the node (900 GB/s per GPU on H100, 1.8 TB/s on Blackwell) and 400 Gb/s InfiniBand or RoCE between nodes are not optional extras. Whether you control that fabric or rent someone else's determines your scaling efficiency.
3. **Economics.** On-prem is **CapEx**: you buy, depreciate over 3–5 years, and pay for power, cooling, space, and staff. Cloud is **OpEx**: you pay per GPU-hour, and egress and storage are billed on top. The crossover point depends almost entirely on **sustained utilization**.
4. **Governance.** Data sovereignty, regulatory residency, IP protection, and multi-tenant isolation can make the decision for you before any cost spreadsheet does.

The exam expects you to articulate these trade-offs. A production architect also needs to **operate** both models, and in practice usually a **hybrid** of the two. This chapter covers both: the conceptual trade-offs and the operational mechanics.

### Typical production scenario

> A fintech company trains a fraud-detection foundation model monthly (2 weeks of 64-GPU jobs) and serves inference 24/7 on 16 GPUs. Customer transaction data cannot leave the EU. The research team occasionally needs 256 GPUs for a few days to run ablation sweeps.

- **Inference (24/7, steady)** has high sustained utilization. That favors **on-prem** or reserved cloud capacity.
- **Monthly training** sits at medium utilization, and the data is regulated. That favors **on-prem** or a **sovereign/EU-region** cloud.
- **Bursty 256-GPU sweeps** have low average utilization and high peaks. That favors **cloud burst**, provided the data can be moved or anonymized.

Most real answers are **hybrid**. The engineering challenge is making workloads **portable** across both environments without losing performance.

---

## 2. Deployment Models: Definitions

| Model | Who owns hardware | Who operates it | Examples |
|---|---|---|---|
| **On-premises** | You | You | DGX H100/B200 in your own data center, DGX SuperPOD, DGX BasePOD |
| **Colocation** | You | You (the facility provider supplies power, cooling, space) | Your DGX racks in an Equinix or Digital Realty cage |
| **Public cloud IaaS** | Cloud provider | You operate the OS and above | AWS P5 (8× H100), Azure ND H100 v5, Google Cloud A3 |
| **Managed AI cloud / AI-as-a-Service** | Provider | Provider operates the stack, you bring workloads | NVIDIA DGX Cloud, specialized GPU clouds |
| **Hybrid** | Mixed | Mixed, ideally one control plane | On-prem baseline plus cloud burst under one scheduler |
| **Sovereign cloud** | Regional provider | Provider, under jurisdictional constraints | Country-specific AI clouds built on NVIDIA reference architectures |

**Colocation** is a frequent exam distractor. It gives you **hardware control** (and CapEx) without needing your own facility. It solves the power and cooling problem. It does not solve the staffing problem.

---

## 3. What You Actually Get: Hardware Reference Points

You cannot reason about trade-offs without knowing the building blocks. These numbers come from NVIDIA's official documentation.

### 3.1 DGX H100 (per node)

| Component | Specification |
|---|---|
| GPUs | 8× NVIDIA H100 Tensor Core, 80 GB HBM3 each (640 GB total) |
| GPU interconnect | 4× third-generation NVSwitch; 18 NVLink links per GPU, 900 GB/s bidirectional per GPU |
| CPUs | 2× Intel Xeon Platinum 8480C (112 cores total) |
| System memory | 2 TB |
| Compute networking | 8× single-port ConnectX-7 (OSFP), up to 400 Gb/s InfiniBand/Ethernet each |
| Storage/in-band networking | 2× dual-port ConnectX-7 (QSFP112) |
| Internal storage | 2× 1.92 TB NVMe M.2 (OS), 8× 3.84 TB NVMe U.2 (data cache, ~30 TB) |
| Power | Up to ~10.2 kW max; 6× 3.3 kW PSUs |
| Form factor | 8U rack-mount |

### 3.2 DGX B200 / DGX SuperPOD (B200)

| Component | Specification |
|---|---|
| GPUs | 8× NVIDIA B200 (1,440 GB total GPU memory) |
| NVLink | Fifth-generation NVLink, 1.8 TB/s per GPU, 14.4 TB/s aggregate per node |
| Compute fabric | 8× ConnectX-7 at 400 Gb/s NDR InfiniBand (rail-optimized) |
| Storage/in-band | 2× BlueField-3 DPU |
| Power | ~14.3 kW max per node |
| SuperPOD building block | **Scalable Unit (SU)** of 32 DGX B200 nodes; reference designs scale to multiple SUs on a non-blocking NDR InfiniBand fabric (Quantum-2 QM9700 switches) |

### 3.3 Why these numbers matter for the decision

- **Power density.** Four DGX B200s in one rack come to about **57 kW**. That is beyond what air cooling handles in most enterprise facilities, so you need rear-door heat exchangers or liquid cooling, and possibly new power distribution. On-prem therefore can carry a **facility project** on top of the hardware purchase.
- **Fabric.** A SuperPOD uses **separate networks**: a compute fabric (InfiniBand, rail-optimized), a storage fabric, in-band management, and out-of-band (BMC) management. In the cloud the provider has built an equivalent, but you get whatever topology they give you, such as AWS EFA, Azure InfiniBand, or GCP GPUDirect-TCPX/RDMA. **You do not choose rail alignment or oversubscription.**
- **DPUs (BlueField).** On-prem you can offload networking, storage, and security functions (OVS, NVMe-oF, firewalling, isolation) to the DPU. This frees host CPU cycles and creates a hardware-enforced trust boundary. Cloud providers do the same thing internally with their own offload cards, such as AWS Nitro. You **consume** the isolation; you do not program it.

---

## 4. Core Trade-offs

### 4.1 Master comparison table

| Dimension | On-premises | Public cloud |
|---|---|---|
| **Cost model** | CapEx plus fixed OpEx (power, cooling, space, staff); depreciated over 3–5 years | Pure OpEx, pay-per-use; reserved or committed discounts trade flexibility for price |
| **Cost at high utilization** | ✅ Lowest cost per GPU-hour once sustained utilization is high | ❌ Premium for flexibility; on-demand GPU-hours are expensive |
| **Cost at low/bursty utilization** | ❌ Idle GPUs still depreciate and draw idle power | ✅ Pay only when running; scale to zero |
| **Time to first GPU** | ❌ Weeks to months (procurement, lead times, facility readiness, racking, burn-in) | ✅ Minutes, *if capacity and quota exist* |
| **Elasticity** | ❌ Fixed ceiling = what you bought | ✅ High elasticity in theory; in practice large H100/B200 blocks often require reservations |
| **Performance control** | ✅ Full control: BIOS, firmware, fabric topology, NUMA, rail-optimized InfiniBand, storage tiering | ⚠️ Provider-defined; good, but opaque; noisy-neighbor risk on shared fabrics/storage |
| **Latest hardware** | ⚠️ Locked to what you bought until refresh | ✅ New generations become available without a refresh cycle (subject to allocation) |
| **Data gravity** | ✅ Compute next to where large datasets already live | ❌ Ingress is usually free, **egress is billed**; moving PBs is slow and costly |
| **Sovereignty & compliance** | ✅ Full physical and jurisdictional control | ⚠️ Region selection, sovereign offerings, contractual controls; shared-responsibility model |
| **Security boundary** | You own physical, network, host, and app layers | Shared responsibility: provider secures facility/hypervisor, you secure everything above |
| **Operational burden** | ❌ You need staff for hardware, firmware, fabric, cooling, failures, RMA | ✅ Hardware failures are the provider's problem (you still handle job-level resiliency) |
| **Facility requirements** | ❌ High-density power (10–15 kW per node), cooling (possibly liquid), floor loading | ✅ None |
| **Vendor lock-in** | Hardware vendor lock-in (mitigated by standard stacks) | Cloud-API lock-in (IAM, storage, networking, managed services) |
| **Predictability** | ✅ Fixed, predictable cost | ⚠️ Variable bills; surprise costs (egress, idle instances, storage snapshots) |

### 4.2 Advantages summary (exam-ready)

**On-premises advantages**
- Lowest **total cost of ownership (TCO)** for **sustained, high-utilization** workloads.
- **Data sovereignty, privacy, and regulatory control**.
- **Predictable performance**: dedicated, non-blocking fabrics with no noisy neighbors.
- **Full-stack customization**: firmware, drivers, schedulers, network topology, DPU offloads.
- **Data locality**: no egress fees, and compute sits next to existing data lakes.

**Cloud advantages**
- **Speed and agility**: no procurement cycle.
- **Elasticity** for bursty, experimental, or seasonal workloads.
- **No facility investment**: power, cooling, and space are someone else's problem.
- **Access to new GPU generations** without hardware refresh risk.
- **Global reach**: deploy inference close to users in many regions.

### 4.3 Challenges summary

**On-premises challenges**
- High **upfront capital** plus **long lead times**.
- **Power and cooling** retrofits for high-density racks.
- **Specialized skills**: InfiniBand fabric management, GPU fleet health, firmware lifecycle.
- **Capacity planning risk**: overbuying leaves stranded assets, underbuying creates queue backlogs.
- **Hardware obsolescence**: GPU generations turn over every ~2 years.

**Cloud challenges**
- **Cost at scale**: 24/7 GPU usage gets expensive quickly.
- **GPU capacity scarcity**: you can hit quota limits and `InsufficientInstanceCapacity` errors, and large contiguous allocations typically require reserved capacity blocks.
- **Egress costs and data gravity**.
- **Less control** over topology and interconnect, which makes performance tuning opaque.
- **Shared-responsibility security**: misconfigured IAM or storage buckets are your problem.
- **Lock-in** through proprietary managed services.

---

## 5. TCO Mechanics: The Utilization Break-even

The single most important quantitative concept is that **on-prem wins when sustained utilization exceeds a break-even threshold**.

### 5.1 Model

```
Effective on-prem cost per GPU-hour:

           (CapEx / amortization_hours) + OpEx_per_hour
C_onprem = --------------------------------------------
                 GPUs × utilization

where:
  CapEx              = hardware + networking + storage share + install
  amortization_hours = years × 8760
  OpEx_per_hour      = power×PUE×price + staff + space + support contracts
  utilization        = fraction of hours GPUs do useful work (0..1)

Cloud cost per *useful* GPU-hour (pay-per-use, scale to zero):
  C_cloud ≈ price_per_GPU_hour   (utilization does not inflate it if you stop idle instances)

Break-even utilization:
  u* = (CapEx/amortization_hours + OpEx_per_hour) / (GPUs × C_cloud)
```

### 5.2 Worked example (illustrative numbers, not quotes)

All inputs below are **assumptions** for teaching purposes. Replace them with your real quotes.

| Input | Value (assumed) |
|---|---|
| 8-GPU node, fully loaded with share of fabric/storage | $400,000 |
| Amortization | 4 years = 35,040 h |
| Max power draw | 10.2 kW; assume 8 kW average |
| PUE | 1.4 |
| Electricity | $0.12 / kWh |
| Staff + space + support (per node, per hour) | $6.00 |
| Cloud equivalent | $4.00 per GPU-hour (committed-use rate) |

```
Capital per hour   = 400000 / 35040              = $11.42/h
Power per hour     = 8 kW × 1.4 × $0.12           = $1.34/h
Other OpEx         =                                $6.00/h
Total node cost    =                                $18.76/h  (paid whether busy or idle)

Cloud cost for the same node-hour = 8 × $4.00     = $32.00/h

Break-even u* = 18.76 / 32.00 ≈ 0.59 → ~59% sustained utilization
```

**Interpretation:**
- At **>~60% sustained utilization**, on-prem is cheaper per useful GPU-hour.
- At **<~60%** (bursty research, prototyping), cloud is cheaper.
- This model **omits** several factors: egress fees (they push toward on-prem when data is big), facility retrofit (pushes toward cloud), resale/residual value, and the **opportunity cost of time-to-market** (cloud lets you start months earlier).

### 5.3 Measure before you decide

Use **measured** utilization, not guesses. On an existing cluster you can get it from DCGM metrics in Prometheus:

```
avg_over_time(
  avg by (Hostname) (DCGM_FI_DEV_GPU_UTIL)[30d:5m]
)
```

`DCGM_FI_DEV_GPU_UTIL` measures "a kernel was running," which is not the same as "the SMs were busy." For a truer picture of efficiency, also look at `DCGM_FI_PROF_SM_ACTIVE` and `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`.

---

## 6. Technical Considerations in Depth

### 6.1 Networking and scaling efficiency

Distributed training (data/tensor/pipeline parallelism) spends a significant fraction of each step in **collective operations** (all-reduce, all-gather) through **NCCL**.

| Layer | On-prem (DGX SuperPOD) | Cloud |
|---|---|---|
| Intra-node | NVLink + NVSwitch: same hardware as cloud for the same GPU SKU | Same hardware, if the instance is a full 8-GPU HGX/DGX-class node |
| Inter-node | Rail-optimized NDR InfiniBand, 400 Gb/s per GPU, non-blocking fat tree, SHARP in-network reductions | Provider fabric, e.g. AWS EFA (3,200 Gbps aggregate on p5.48xlarge), Azure NDR InfiniBand on ND H100 v5, GCP GPUDirect variants |
| GPUDirect RDMA | Yes, configurable | Depends on provider and instance; requires specific drivers/plugins (e.g. aws-ofi-nccl for EFA) |
| Topology awareness | You know exact rail and switch placement | Placement groups or compact placement policies approximate it |

**Key consideration:** a **partial-node** cloud instance (1, 2, or 4 GPUs) may not have NVLink across all GPUs and usually lacks the high-bandwidth inter-node fabric. For multi-node training, always use **full-node** instances with the provider's RDMA networking enabled.

### 6.2 Storage and data gravity

- On-prem DGX SuperPOD reference architectures specify a **high-performance parallel file system** on a dedicated storage fabric, plus local NVMe cache on each node.
- In the cloud you combine object storage (cheap, high latency) with managed parallel file systems (e.g. FSx for Lustre, Azure Managed Lustre, GCP Parallelstore) or local NVMe instance storage.
- **Egress** is the hidden tax. Moving a 2 PB dataset *out* of a cloud region costs real money and takes days or weeks. Once a dataset is large, compute tends to follow it. This is **data gravity**.

### 6.3 Security, isolation, and sovereignty

| Concern | On-prem mechanism | Cloud mechanism |
|---|---|---|
| Physical access | Your badge system, your cage | Provider's facility controls; audit reports (SOC 2, ISO 27001) |
| Tenant isolation | MIG (hardware partitioning of A100/H100/B200), namespaces, BlueField DPU-enforced network isolation | Hypervisor/bare-metal isolation by provider; VPC; dedicated hosts |
| Data residency | Guaranteed by location | Region choice and sovereign cloud offerings; must be validated contractually |
| Encryption | Self-managed KMS/HSM | Provider KMS, customer-managed keys, confidential computing options |
| Supply chain/firmware | You control firmware versions and update cadence | Provider controls; you trust their process |

**BlueField DPU on-prem:** the DPU runs infrastructure services (virtual switching, storage virtualization, security policies) on its own Arm cores, **isolated from the host OS**. A compromised tenant workload on the host cannot reconfigure the network policy enforced on the DPU. This is how on-prem multi-tenant AI clouds reach cloud-grade isolation.

### 6.4 Operations and staffing

On-prem means **you** own:

- GPU health (Xid errors, ECC/row-remapping, thermal throttling), DCGM diagnostics, RMA logistics.
- Fabric management (UFM for InfiniBand, link flaps, cable/optic failures).
- Firmware/driver/CUDA/NCCL compatibility matrices.
- Facility monitoring (inlet temps, power capping, PDU loads).

In the cloud, hardware faults turn into **"instance retired / replace node"** events. You still need **job-level resiliency**: checkpointing, elastic restarts, and health checks before training starts.

### 6.5 Hybrid architecture principles

1. **Standardize the software stack:** same container images (NGC), the same Kubernetes + NVIDIA GPU Operator (or Slurm), and the same NCCL versions everywhere.
2. **Abstract placement** with labels, node pools, and a scheduler that understands multiple capacity flavors.
3. **Classify data** so you know what may cross the boundary (anonymized/synthetic vs regulated).
4. **Prefer owned capacity first, then cloud burst.** This keeps on-prem utilization above break-even.
5. **Observe uniformly:** DCGM exporter → Prometheus in both environments.

---

## 7. Manifests: Building a Portable, Hybrid GPU Platform

The following example is a single Kubernetes cluster that contains both on-prem DGX nodes and cloud GPU nodes, as in a hybrid-nodes setup. The same YAML runs in either place, and **Kueue** decides placement, with on-prem preferred and cloud as overflow.

### 7.1 Node labeling convention

```bash
$ kubectl label node dgx-h100-01 dgx-h100-02 dgx-h100-03 dgx-h100-04 \
    infra.example.com/location=onprem \
    infra.example.com/gpu-class=h100-80gb \
    infra.example.com/fabric=infiniband-ndr
node/dgx-h100-01 labeled
node/dgx-h100-02 labeled
node/dgx-h100-03 labeled
node/dgx-h100-04 labeled

$ kubectl taint node dgx-h100-01 dgx-h100-02 dgx-h100-03 dgx-h100-04 \
    nvidia.com/gpu=present:NoSchedule
node/dgx-h100-01 tainted
node/dgx-h100-02 tainted
node/dgx-h100-03 tainted
node/dgx-h100-04 tainted
```

Cloud nodes get `infra.example.com/location=cloud` through their node group definition (see the Terraform in 7.5).

### 7.2 NVIDIA GPU Operator values: on-prem vs cloud

**On-prem (bare-metal DGX running a generic OS; the operator manages the driver):**

```yaml
# values-onprem.yaml — helm install gpu-operator nvidia/gpu-operator -n gpu-operator -f values-onprem.yaml
driver:
  enabled: true
  rdma:
    enabled: true
    useHostMofed: false
toolkit:
  enabled: true
devicePlugin:
  enabled: true
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: "15s"
gfd:
  enabled: true
migManager:
  enabled: true
mig:
  strategy: mixed
nodeStatusExporter:
  enabled: true
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "true"
daemonsets:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
```

**Cloud (managed GPU node image with the driver preinstalled):**

```yaml
# values-cloud.yaml — drivers come from the provider's GPU-optimized node image
driver:
  enabled: false
toolkit:
  enabled: true
devicePlugin:
  enabled: true
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: "15s"
gfd:
  enabled: true
migManager:
  enabled: false
nodeStatusExporter:
  enabled: true
daemonsets:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
```

The difference between the two files is the **operational boundary**. On-prem you own the driver and RDMA lifecycle. In the cloud the provider image does, and installing a second driver on top of it causes conflicts.

### 7.3 Kueue: on-prem first, cloud as overflow

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: onprem-h100
spec:
  nodeLabels:
    infra.example.com/location: onprem
    infra.example.com/gpu-class: h100-80gb
  nodeTaints:
    - key: nvidia.com/gpu
      value: present
      effect: NoSchedule
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: present
      effect: NoSchedule
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: cloud-h100
spec:
  nodeLabels:
    infra.example.com/location: cloud
    infra.example.com/gpu-class: h100-80gb
  nodeTaints:
    - key: nvidia.com/gpu
      value: present
      effect: NoSchedule
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: present
      effect: NoSchedule
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: training-cq
spec:
  namespaceSelector: {}
  queueingStrategy: BestEffortFIFO
  flavorFungibility:
    whenCanBorrow: Borrow
    whenCanPreempt: TryNextFlavor
  resourceGroups:
    - coveredResources:
        - cpu
        - memory
        - nvidia.com/gpu
      flavors:
        - name: onprem-h100
          resources:
            - name: cpu
              nominalQuota: "448"
            - name: memory
              nominalQuota: "8000Gi"
            - name: nvidia.com/gpu
              nominalQuota: 32
        - name: cloud-h100
          resources:
            - name: cpu
              nominalQuota: "768"
            - name: memory
              nominalQuota: "8000Gi"
            - name: nvidia.com/gpu
              nominalQuota: 32
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: team-fraud
  namespace: ml-fraud
spec:
  clusterQueue: training-cq
```

Kueue evaluates flavors **in order**. A job lands on `onprem-h100` while the 32 on-prem GPUs have room, and only overflows to `cloud-h100` once on-prem quota is exhausted. Paired with a cluster autoscaler on the cloud node group (min size 0), the cloud capacity costs nothing until it is used. This is the break-even logic from section 5, implemented as policy.

### 7.4 Portable distributed training job

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ml-fraud
  labels:
    data-classification: anonymized
---
apiVersion: batch/v1
kind: Job
metadata:
  name: fraud-pretrain-ablation-07
  namespace: ml-fraud
  labels:
    kueue.x-k8s.io/queue-name: team-fraud
spec:
  suspend: true
  parallelism: 2
  completions: 2
  completionMode: Indexed
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: fraud-pretrain
    spec:
      restartPolicy: OnFailure
      subdomain: fraud-pretrain
      containers:
        - name: trainer
          image: nvcr.io/nvidia/pytorch:24.10-py3
          command:
            - torchrun
          args:
            - "--nnodes=2"
            - "--nproc-per-node=8"
            - "--node-rank=$(JOB_COMPLETION_INDEX)"
            - "--master-addr=fraud-pretrain-ablation-07-0.fraud-pretrain"
            - "--master-port=29500"
            - "/workspace/train.py"
            - "--checkpoint-dir=/checkpoints/ablation-07"
            - "--resume-from-latest"
          env:
            - name: NCCL_DEBUG
              value: "INFO"
            - name: NCCL_DEBUG_SUBSYS
              value: "INIT,NET"
            - name: TORCH_NCCL_ASYNC_ERROR_HANDLING
              value: "1"
          resources:
            requests:
              cpu: "96"
              memory: "1000Gi"
              nvidia.com/gpu: 8
            limits:
              nvidia.com/gpu: 8
          volumeMounts:
            - name: dshm
              mountPath: /dev/shm
            - name: checkpoints
              mountPath: /checkpoints
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: "256Gi"
        - name: checkpoints
          persistentVolumeClaim:
            claimName: fraud-checkpoints
---
apiVersion: v1
kind: Service
metadata:
  name: fraud-pretrain
  namespace: ml-fraud
spec:
  clusterIP: None
  selector:
    app: fraud-pretrain
  ports:
    - name: rendezvous
      port: 29500
      targetPort: 29500
```

Design notes:
- The job sets `suspend: true` and relies on Kueue to unsuspend it once it is admitted. Kueue injects the flavor's `nodeSelector` and tolerations, so the manifest itself carries no on-prem or cloud specifics.
- `--resume-from-latest` together with a shared checkpoint PVC makes the job tolerant of cloud spot reclamation and of on-prem node failures. Resiliency should be the same in both environments.
- In the cloud, RDMA networking needs extra configuration that is **environment specific**. On AWS, for example, you request `vpc.amazonaws.com/efa` resources and use an image with the aws-ofi-nccl plugin. Keep that difference in a Kustomize overlay rather than forking the base job.

### 7.5 Cloud burst node group (Terraform, AWS EKS example)

```hcl
resource "aws_eks_node_group" "gpu_burst_h100" {
  cluster_name    = aws_eks_cluster.hybrid.name
  node_group_name = "gpu-burst-h100"
  node_role_arn   = aws_iam_role.gpu_nodes.arn
  subnet_ids      = [aws_subnet.gpu_az1.id]
  instance_types  = ["p5.48xlarge"]
  ami_type        = "AL2023_x86_64_NVIDIA"
  capacity_type   = "ON_DEMAND"

  scaling_config {
    min_size     = 0
    desired_size = 0
    max_size     = 4
  }

  labels = {
    "infra.example.com/location"  = "cloud"
    "infra.example.com/gpu-class" = "h100-80gb"
    "infra.example.com/fabric"    = "efa"
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NO_SCHEDULE"
  }

  tags = {
    "cost-center"                                  = "ml-research"
    "k8s.io/cluster-autoscaler/enabled"            = "true"
    "k8s.io/cluster-autoscaler/hybrid-ai-platform" = "owned"
  }
}
```

The key settings here are `min_size = 0`, which means no idle cloud spend, and the single-subnet placement, which keeps the nodes in one AZ for EFA and lowers latency. The `cost-center` tag enables chargeback, which is what makes the cloud-vs-on-prem comparison measurable.

### 7.6 Equivalent on-prem view with Slurm (`gres.conf` and partition)

Many on-prem SuperPODs run **Slurm** (often via NVIDIA Base Command Manager) instead of, or alongside, Kubernetes.

```
# /etc/slurm/gres.conf
AutoDetect=nvml
NodeName=dgx-h100-[01-04] Name=gpu Type=h100 File=/dev/nvidia[0-7]
```

```
# /etc/slurm/slurm.conf (excerpt)
GresTypes=gpu
NodeName=dgx-h100-[01-04] CPUs=224 Sockets=2 CoresPerSocket=56 ThreadsPerCore=2 RealMemory=2000000 Gres=gpu:h100:8 State=UNKNOWN
PartitionName=train Nodes=dgx-h100-[01-04] Default=YES MaxTime=7-00:00:00 State=UP OverSubscribe=EXCLUSIVE
```

`OverSubscribe=EXCLUSIVE` gives each training job whole nodes, so it never shares NVLink domains or NICs with another job. This is the predictable-performance argument for on-prem, expressed as configuration.

---

## 8. CLI: Verifying What You Actually Got

### 8.1 Confirm the GPU and NVLink topology (both environments)

```
$ nvidia-smi --query-gpu=index,name,memory.total,power.limit --format=csv
index, name, memory.total [MiB], power.limit [W]
0, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
1, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
2, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
3, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
4, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
5, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
6, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
7, NVIDIA H100 80GB HBM3, 81559 MiB, 700.00 W
```

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  ...  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PIX   SYS   ...  0-55,112-167  0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   PIX   ...  0-55,112-167  0
...
Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

`NV18` between every pair of GPUs means a full NVSwitch fabric with 18 NVLinks per GPU, as on DGX H100. If you see `SYS` or `PHB` between GPUs on a cloud instance, it is **not** a full NVLink node, and multi-GPU training will be PCIe-bound. Each GPU also having a `PIX` NIC shows the rail-aligned GPU-to-NIC pairing that GPUDirect RDMA relies on.

```
$ nvidia-smi nvlink --status -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3b1c...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
         Link 17: 26.562 GB/s
```

### 8.2 On-prem: check the InfiniBand compute fabric

```
$ ibstat mlx5_0
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
                Base lid: 17
                LMC: 0
                SM lid: 1
                Capability mask: 0xa751e848
                Port GUID: 0x946dae0300a1b2c4
                Link layer: InfiniBand
```

`Rate: 400` means NDR. `State: Active` means a subnet manager (UFM/OpenSM) has configured the port. If you see `State: Initializing`, the link is physically up but no subnet manager is reachable.

```
$ for i in 0 1 2 3 4 5 6 7; do printf "mlx5_%s " $i; ibstat mlx5_$i | awk '/State:|Rate:/ {printf "%s %s ", $1, $2} END {print ""}'; done
mlx5_0 State: Active Rate: 400
mlx5_1 State: Active Rate: 400
mlx5_2 State: Active Rate: 400
mlx5_3 State: Active Rate: 400
mlx5_4 State: Active Rate: 400
mlx5_5 State: Active Rate: 400
mlx5_6 State: Active Rate: 400
mlx5_7 State: Active Rate: 400
```

### 8.3 Cloud: confirm instance capabilities before committing

```
$ aws ec2 describe-instance-types --instance-types p5.48xlarge \
    --query 'InstanceTypes[0].{GPUs:GpuInfo.Gpus[0].Count,GPU:GpuInfo.Gpus[0].Name,GPUMemMiB:GpuInfo.TotalGpuMemoryInMiB,EFA:NetworkInfo.EfaSupported,MaxNICs:NetworkInfo.MaximumNetworkCards,Network:NetworkInfo.NetworkPerformance}' \
    --output table
-----------------------------------------------------------------------------------
|                              DescribeInstanceTypes                              |
+------+-----+-------+------------+---------+-------------------------------------+
| EFA  | GPU | GPUs  | GPUMemMiB  | MaxNICs |              Network                |
+------+-----+-------+------------+---------+-------------------------------------+
|  True|  H100|  8   |  655360    |  32     |  3200 Gigabit                       |
+------+-----+-------+------------+---------+-------------------------------------+
```

```
$ aws service-quotas get-service-quota --service-code ec2 --quota-code L-417A185B \
    --query 'Quota.{Name:QuotaName,Value:Value}' --output table
-------------------------------------------------------------------
|                         GetServiceQuota                         |
+----------------------------------------------------------+------+
|                           Name                           |Value |
+----------------------------------------------------------+------+
|  Running On-Demand P instances                           |  0.0 |
+----------------------------------------------------------+------+
```

A quota of `0.0` vCPUs is common on new accounts. The cloud's "minutes to first GPU" promise does not hold until the quota increase is approved, and large H100/B200 allocations often need **capacity reservations** booked in advance. This is a real-world challenge of cloud that the exam expects you to know.

### 8.4 Kubernetes: verify GPUs are allocatable and where jobs landed

```
$ kubectl get nodes -L infra.example.com/location,infra.example.com/gpu-class \
    -o custom-columns='NAME:.metadata.name,LOC:.metadata.labels.infra\.example\.com/location,GPU:.status.allocatable.nvidia\.com/gpu'
NAME                                         LOC      GPU
dgx-h100-01                                  onprem   8
dgx-h100-02                                  onprem   8
dgx-h100-03                                  onprem   8
dgx-h100-04                                  onprem   8
ip-10-20-4-117.eu-central-1.compute.internal cloud    8
```

```
$ kubectl get workloads -n ml-fraud
NAME                                   QUEUE        RESERVED IN   ADMITTED   FINISHED   AGE
job-fraud-pretrain-ablation-07-3f9a2   team-fraud   training-cq   True                  4m

$ kubectl get workload job-fraud-pretrain-ablation-07-3f9a2 -n ml-fraud \
    -o jsonpath='{.status.admission.podSetAssignments[0].flavors}{"\n"}'
{"cpu":"cloud-h100","memory":"cloud-h100","nvidia.com/gpu":"cloud-h100"}
```

The job was admitted on `cloud-h100`, which means on-prem quota was full and burst occurred. Track how often this happens. If burst is constant, your on-prem capacity is undersized, and buying more on-prem capacity is probably cheaper than continuing to pay cloud prices.

### 8.5 Validate inter-node bandwidth (NCCL tests)

```
$ mpirun -np 16 -N 8 --hostfile hosts \
    -x NCCL_DEBUG=WARN -x LD_LIBRARY_PATH \
    /opt/nccl-tests/build/all_reduce_perf -b 1G -e 8G -f 2 -g 1
#       size         count      type   redop    root     time   algbw   busbw  #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)
  1073741824     268435456     float     sum      -1   6512.3  164.88  309.15      0
  2147483648     536870912     float     sum      -1  12880.1  166.73  312.62      0
  4294967296    1073741824     float     sum      -1  25621.7  167.63  314.31      0
  8589934592    2147483648     float     sum      -1  51104.9  168.09  315.17      0
# Avg bus bandwidth    : 312.81
```

**Interpretation:**
- 8 × 400 Gb/s NICs give 400 GB/s theoretical per node. A busbw in the **~300+ GB/s** range across two nodes indicates a healthy rail-optimized fabric with GPUDirect RDMA.
- If busbw is around **10–25 GB/s**, NCCL has fallen back to TCP sockets. This is the most common cloud failure mode (EFA/RDMA not configured). See section 9.
- Run this test **on both environments** before migrating workloads. It is the most objective on-prem vs cloud performance comparison you have.

### 8.6 Health diagnostics before admitting a node (both environments)

```
$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.x                                          |
| Driver Version Detected   | 550.x                                          |
| GPU Device IDs Detected   | 2330,2330,2330,2330,2330,2330,2330,2330        |
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Pass                                           |
| Graphics Processes        | Pass                                           |
| Inforom                   | Pass                                           |
+-----  Integration  -------+------------------------------------------------+
| PCIe                      | Pass - All                                     |
+-----  Hardware  ----------+------------------------------------------------+
| GPU Memory                | Pass - All                                     |
+-----  Stress  ------------+------------------------------------------------+
| Targeted Stress           | Pass - All                                     |
+---------------------------+------------------------------------------------+
```

On-prem, a failure here starts **your** RMA process. In the cloud, a failure means you cordon the node and terminate the instance so that it gets replaced. **The diagnostic is the same in both environments, but the remediation path differs.**

---

## 9. Troubleshooting Guide: Environment-Specific Failure Modes

### 9.1 Decision table

| Symptom | Likely environment | Root cause | Diagnosis | Fix |
|---|---|---|---|---|
| Multi-node training scales poorly; NCCL busbw ~10–25 GB/s | Cloud (also misconfigured on-prem) | NCCL fell back to TCP sockets; RDMA/EFA/IB not in use | `NCCL_DEBUG=INFO` log shows `NET/Socket` instead of `NET/IB` or `NET/OFI` | Cloud: attach EFA/RDMA devices, install the provider NCCL plugin, use full-node instances in one placement group. On-prem: check IB ports `Active`, `nvidia-peermem` loaded |
| IB ports stuck at `State: Initializing` | On-prem | No subnet manager reachable | `ibstat`; `sminfo` fails | Check UFM/OpenSM HA, switch connectivity |
| GPU clocks drop under sustained load; step time increases over hours | On-prem | Thermal or power throttling: inadequate cooling or power cap | `nvidia-smi -q -d PERFORMANCE` shows `HW Thermal Slowdown: Active` or `SW Power Cap: Active` | Fix airflow, inlet temps, liquid cooling loop; verify PDU capacity. This is a facility issue |
| Pods pending with `Insufficient nvidia.com/gpu` while cloud node group is at 0 | Cloud | Autoscaler can't launch: quota or capacity | Autoscaler logs/events show `InsufficientInstanceCapacity` or quota exceeded | Request a quota increase; use capacity reservations; allow alternate AZs/instance types |
| Monthly cloud bill spikes unexpectedly | Cloud | Idle GPU instances, cross-AZ/egress traffic, orphaned volumes | Cost explorer grouped by tag; check `min_size` | Scale to zero, tag everything, keep data and compute co-located |
| GPU disappears from node; `nvidia-smi` shows `No devices were found` or `Unknown Error` | Both | Xid 79 (fell off the bus), hardware fault | `dmesg \| grep -i xid` | On-prem: drain, reseat or RMA. Cloud: terminate and replace the instance |
| Job fails after "spot reclamation" | Cloud | Preemptible capacity reclaimed | Node events show a termination notice | Checkpoint frequently, `--resume-from-latest`, mix on-demand and spot |
| Driver version conflict after GPU Operator install | Cloud | Operator-managed driver installed on top of a preinstalled AMI driver | Driver pod `CrashLoopBackOff`; `lsmod \| grep nvidia` shows a pre-existing module | Use `driver.enabled: false` (values-cloud.yaml) |

### 9.2 Reading NCCL transport selection

```
$ kubectl logs fraud-pretrain-ablation-07-0-xxxxx -n ml-fraud | grep -E "NET/|Using network"
NCCL INFO NET/Plugin: Could not find: libnccl-net.so. Using internal network plugin.
NCCL INFO NET/IB : No device found.
NCCL INFO NET/Socket : Using [0]eth0:10.20.4.117<0>
NCCL INFO Using network Socket
```

This log shows the **failure case**: no RDMA device is visible, so NCCL uses TCP. A healthy on-prem node shows:

```
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_1:1/IB [2]mlx5_2:1/IB [3]mlx5_3:1/IB [4]mlx5_4:1/IB [5]mlx5_5:1/IB [6]mlx5_6:1/IB [7]mlx5_7:1/IB ; OOB ib0:10.0.0.11<0>
NCCL INFO Using network IB
NCCL INFO Channel 00/0 : 0[0] -> 8[0] [send] via NET/IB/0/GDRDMA
```

`GDRDMA` confirms **GPUDirect RDMA**: data moves NIC↔GPU memory without bouncing through host memory. On a cloud instance with EFA, the healthy equivalent shows `NET/OFI` with the `efa` provider selected.

### 9.3 Detecting on-prem facility problems

```
$ nvidia-smi -q -d PERFORMANCE -i 3
==============NVSMI LOG==============
GPU 00000000:5D:00.0
    Performance
        Clocks Event Reasons
            Idle                              : Not Active
            Applications Clocks Setting       : Not Active
            SW Power Cap                      : Not Active
            HW Slowdown                       : Active
                HW Thermal Slowdown           : Active
                HW Power Brake Slowdown       : Not Active
            Sync Boost                        : Not Active
            SW Thermal Slowdown               : Not Active
            Display Clock Setting             : Not Active
```

```
$ nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory,clocks.sm,power.draw --format=csv
index, temperature.gpu, temperature.memory, clocks.sm [MHz], power.draw [W]
0, 64, 72, 1980, 688.21
1, 65, 73, 1980, 691.04
2, 63, 71, 1980, 684.77
3, 87, 95, 1410, 512.30
4, 64, 72, 1980, 690.12
5, 66, 74, 1980, 689.55
6, 65, 73, 1980, 687.90
7, 64, 72, 1980, 686.43
```

GPU 3 runs **~23 °C hotter** and its SM clock dropped from 1980 to 1410 MHz. In synchronous data-parallel training, **one slow GPU slows the whole job**. This problem class does not exist in the cloud (the provider absorbs it), and it is a direct operational cost of running on-prem. Check fan modules, blanking panels, hot-aisle containment, and inlet temperatures.

### 9.4 Detecting cloud capacity problems

```
$ kubectl get events -n kube-system --field-selector reason=FailedScaleUp | tail -3
LAST SEEN   TYPE      REASON          OBJECT                         MESSAGE
2m          Warning   FailedScaleUp   pod/fraud-pretrain-...-0-abcde  Node scale up in zones eu-central-1a associated with this pod failed: Could not launch On-Demand Instances. InsufficientInstanceCapacity - We currently do not have sufficient p5.48xlarge capacity in the Availability Zone you requested (eu-central-1a). Our system will be working on provisioning additional capacity.
```

Elasticity has limits. For critical burst windows, reserve capacity ahead of time. Alternatively, design jobs that can run on more than one GPU class, which means defining additional Kueue flavors.

---

## 10. Decision Framework (Exam Summary)

| Workload / constraint | Recommended placement | Reasoning |
|---|---|---|
| 24/7 inference, stable load | On-prem or reserved cloud | High utilization, above break-even |
| Large recurring training on regulated data | On-prem / colocation / sovereign cloud | Sovereignty plus high utilization plus data gravity |
| Proof of concept, early experimentation | Cloud | Speed, no CapEx, unknown requirements |
| Spiky, seasonal, or one-off large runs | Cloud burst | Pay only for peaks |
| Need latest GPU generation now | Cloud / managed AI cloud (e.g. DGX Cloud) | Avoid procurement lead time and refresh risk |
| Massive datasets already on-prem | On-prem | Avoid egress cost and transfer time |
| No data-center power/cooling for 10–15 kW nodes | Cloud or colocation | Facility constraint dominates |
| Limited ops staff with GPU/IB expertise | Cloud / managed | Operational burden |
| Mixed portfolio | **Hybrid**: on-prem baseline, cloud overflow, one software stack | Keeps on-prem above break-even while preserving elasticity |

### Key takeaways for the exam

1. **Utilization drives TCO.** On-prem is cheaper at high sustained utilization; cloud is cheaper for low or bursty usage.
2. **CapEx vs OpEx.** On-prem means upfront investment plus depreciation. Cloud means pay-as-you-go with a premium for flexibility.
3. **Cloud's advantages** are agility, elasticity, no facility burden, and fast access to new hardware. Its **challenges** are cost at scale, egress, capacity and quota limits, less control, and lock-in.
4. **On-prem's advantages** are control, performance predictability, data sovereignty, and long-run cost. Its **challenges** are CapEx, lead times, power/cooling density, staffing, and obsolescence.
5. **Power and cooling** are first-class constraints: 10.2 kW per DGX H100, ~14.3 kW per DGX B200.
6. **Networking parity matters.** NVLink inside the node and RDMA (InfiniBand/RoCE/EFA) between nodes; verify both with `nvidia-smi topo -m` and `nccl-tests`.
7. **DPUs (BlueField)** bring cloud-style isolation and offload to on-prem infrastructure.
8. **Hybrid** with a standardized stack (NGC containers, GPU Operator, Kubernetes/Slurm, DCGM) is the most common enterprise answer.

---

## Referencias

- NVIDIA AI Infrastructure and Operations — exam study guide (PDF): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA Technical Blog — Offloading and Isolating Data Center Workloads with BlueField DPU: https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
- NVIDIA DGX SuperPOD Reference Architecture (DGX B200): https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
- NVIDIA DGX H100 User Guide — Component Descriptions: https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
- NVIDIA NVLink and NVSwitch: https://www.nvidia.com/en-us/data-center/nvlink/
- NVIDIA Technical Blog — Accelerating IO in the Modern Data Center: Network IO: https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- NCCL tests: https://github.com/NVIDIA/nccl-tests
- Kueue documentation (ResourceFlavor, ClusterQueue): https://kueue.sigs.k8s.io/docs/concepts/
- AWS EC2 P5 instances: https://aws.amazon.com/ec2/instance-types/p5/