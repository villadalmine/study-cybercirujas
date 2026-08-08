# 5.4 AI/ML Integration in Platform Automation

> **Domain 5 · Exam weight 2.0** — *Certified Cloud Native Platform Engineering Associate (CNPA), curriculum 2025-04-01*

Platform engineering meets AI/ML along **two orthogonal axes**, and a Platform Architect must keep them distinct because they have different failure modes, different SLOs, and different blast radii:

1. **AI/ML *as a platform workload*** — the Internal Developer Platform (IDP) must expose accelerators, model serving, batch training, and queueing as *self-service golden paths*, the same way it exposes stateless HTTP services. This is "platform engineering **for** AI".
2. **AI/ML *for platform automation* (AIOps/GenAI-Ops)** — using models to forecast load, detect anomalies, do root-cause analysis, and drive remediation. This is "AI **in** the platform".

This topic sits at the intersection. The exam-relevant skill is knowing *where the CNCF-native primitives fit*, what the trade-offs are, and how to keep a non-deterministic component (a model) from sitting in the write path of a control loop.

---

## 1. The production architectural problem

A stateless web service is *fungible*: any replica on any node serves any request in a few milliseconds, CPU/memory requests are cheap and elastic, and the scheduler treats nodes as interchangeable. **Every one of those assumptions breaks for AI/ML.**

| Assumption for web apps | Reality for AI/ML workloads | Platform consequence |
|---|---|---|
| Resources are cheap and elastic | A single H100 node is ~$30–100k; GPUs are scarce and often the hard cap | Quota, fair-sharing, borrowing, and preemption become first-class (Kueue/Volcano) |
| Replicas are interchangeable | Placement is topology-sensitive (NVLink, NUMA, same rack for NCCL all-reduce) | Scheduler must be topology- and gang-aware |
| Requests are short & uniform | LLM inference: variable token length, KV-cache pressure, seconds-long requests | CPU-based HPA is useless; you scale on in-flight requests / concurrency |
| Cold start is milliseconds | Loading a 16 GB model + CUDA graph capture is 30–300 s | Scale-to-zero needs careful warm-pool / activator design |
| One pod = one process | Training is a *gang*: all-or-nothing across N pods | Partial scheduling deadlocks the cluster ("resource fragmentation") |
| Node = CPU + RAM | Node = CPU + RAM + N heterogeneous GPUs, shareable via MIG/MPS/time-slicing | The device-plugin `nvidia.com/gpu: 1` abstraction is too coarse → **DRA** |

The architectural job is to wrap this complexity behind a stable platform API so an application team gets a **golden path** ("deploy this model, autoscale it, charge my quota") without learning Knative, DCGM, MIG profiles, or gang scheduling. The rest of this topic is the machinery behind that abstraction.

---

## 2. Serving accelerators as a platform capability

### 2.1 GPU allocation & sharing — the strategy matrix

The default device plugin exposes a GPU as an opaque countable resource (`nvidia.com/gpu: 1`). That is fine for full-device training but wasteful for inference. The platform must offer *sharing* strategies and, increasingly, **Dynamic Resource Allocation (DRA)**, which went GA as `resource.k8s.io/v1` in Kubernetes 1.34.

| Strategy | Isolation | Granularity | Failure mode | Best for | K8s mechanism |
|---|---|---|---|---|---|
| **Full GPU** | Hard | Whole device | Under-utilization | Training, large LLMs | Device plugin / DRA |
| **Time-slicing** | **None** (context switch) | Logical replicas | Noisy-neighbor, OOM (no memory isolation) | Dev/test, bursty low-QPS | GPU Operator config |
| **MPS** | Soft (shared CUDA context) | % SM | One crash can take down the context | Many small co-located models | GPU Operator MPS |
| **MIG** | **Hard** (partitioned) | Fixed profiles (`1g.5gb`…`7g.40gb`) | Rigid, requires node drain to reprofile | Strict multi-tenant SLO | GPU Operator + MIG profiles |
| **DRA** | Driver-defined | Arbitrary, topology-aware | New (GA 1.34), driver maturity | Fine-grained, heterogeneous fleets | `resource.k8s.io/v1` |

> Key point for the exam: **time-slicing gives you concurrency, not isolation.** A pod can consume all VRAM and OOM its slice-mates. MIG is the only *hard-partitioned* sharing model.

**GPU Operator time-slicing config** (4 logical replicas per physical A100):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  a100-40gb: |-
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
---
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: cluster-policy
spec:
  devicePlugin:
    config:
      name: time-slicing-config
      default: a100-40gb
```

### 2.2 Dynamic Resource Allocation (DRA) — the successor to the device plugin

DRA moves accelerator selection from "count a magic string" to a *claim-based, CEL-selectable, topology-aware* model. The platform defines a `DeviceClass`; teams reference a `ResourceClaimTemplate`.

```yaml
apiVersion: resource.k8s.io/v1        # GA in Kubernetes 1.34 (beta lineage: v1beta1 in 1.32)
kind: DeviceClass
metadata:
  name: gpu.nvidia.com
spec:
  selectors:
  - cel:
      expression: device.driver == "gpu.nvidia.com"
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: single-a100
  namespace: model-serving
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:                       # v1 wraps the request; the alternative is `firstAvailable` (prioritized list)
          deviceClassName: gpu.nvidia.com
          allocationMode: ExactCount
          count: 1
          selectors:
          - cel:
              expression: |
                device.attributes["gpu.nvidia.com"].productName == "NVIDIA-A100-SXM4-40GB" &&
                device.capacity["gpu.nvidia.com"].memory.compareTo(quantity("40Gi")) >= 0
---
apiVersion: v1
kind: Pod
metadata:
  name: llama-trainer
  namespace: model-serving
spec:
  restartPolicy: Never
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-a100
  containers:
  - name: trainer
    image: nvcr.io/nvidia/pytorch:24.10-py3
    command: ["python", "train.py"]
    resources:
      claims:
      - name: gpu
```

DRA requires a **DRA driver** (`NVIDIA/k8s-dra-driver-gpu`) that publishes `ResourceSlice` objects describing each node's devices. The scheduler matches claims against slices — no more "1 GPU means the whole card and nothing else can be expressed."

### 2.3 Model serving frameworks

| Capability | **KServe** *(CNCF Incubating)* | Seldon Core v2 | Raw `Deployment` (vLLM/Triton) |
|---|---|---|---|
| Scale-to-zero | ✅ (Knative/Serverless mode) | via KEDA | manual / KEDA |
| Deployment modes | Serverless · RawDeployment · ModelMesh | native | n/a |
| Multi-model density | ✅ ModelMesh | ✅ | ❌ (one model/pod) |
| Standard API | Open Inference Protocol v2 + OpenAI-compat (HF runtime) | OIP v2 | framework-native |
| Canary / traffic split | ✅ native (`canaryTrafficPercent`) | ✅ | ❌ manual |
| Best when | You want a golden path | Complex inference graphs | Full control, no abstraction |

**KServe `InferenceService`** — an LLM served with the HuggingFace runtime (vLLM backend, OpenAI-compatible endpoints), scale-to-zero on concurrency:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llama-3-8b
  namespace: model-serving
  annotations:
    serving.kserve.io/deploymentMode: Serverless   # Serverless | RawDeployment | ModelMesh
spec:
  predictor:
    minReplicas: 0            # scale-to-zero (Knative activator holds the request during cold start)
    maxReplicas: 5
    scaleTarget: 10           # 10 concurrent requests per replica
    scaleMetric: concurrency  # Knative KPA — NOT CPU
    containerConcurrency: 20  # hard ceiling before queueing
    model:
      modelFormat:
        name: huggingface
      runtime: kserve-huggingfaceserver
      storageUri: hf://meta-llama/Meta-Llama-3-8B-Instruct
      args:
        - --max-model-len=8192
        - --dtype=bfloat16
      resources:
        requests:
          cpu: "4"
          memory: 24Gi
          nvidia.com/gpu: "1"
        limits:
          nvidia.com/gpu: "1"
```

> **Why `scaleMetric: concurrency` and not CPU/GPU-util?** GPU utilization is a lagging, saturating signal — a card can read 100% util while still accepting more concurrent requests, or read 40% while its KV-cache is full and latency is exploding. *In-flight concurrency* and *queue depth* (`vllm:num_requests_waiting`) are the load signals that correlate with tail latency.

### 2.4 Fair-share, quota, and gang scheduling

Without admission control, ten teams submitting training jobs will each grab a few GPUs and **deadlock the cluster** — every job partially scheduled, none able to complete its gang. **Kueue** (Kubernetes SIG) solves this by *suspending* workloads until the full quota is available.

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: gpu-a100
spec:
  nodeLabels:
    nvidia.com/gpu.product: NVIDIA-A100-SXM4-40GB
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: training-cq
spec:
  namespaceSelector: {}
  cohort: ml-platform          # cohorts share/borrow unused quota
  preemption:
    reclaimWithinCohort: Any
    withinClusterQueue: LowerPriority
  resourceGroups:
  - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
    flavors:
    - name: gpu-a100
      resources:
      - name: cpu
        nominalQuota: "200"
      - name: memory
        nominalQuota: 800Gi
      - name: nvidia.com/gpu
        nominalQuota: "16"
        borrowingLimit: "8"    # may borrow up to 8 idle GPUs from the cohort
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: team-a
  namespace: model-serving
spec:
  clusterQueue: training-cq
---
apiVersion: batch/v1
kind: Job
metadata:
  name: llama-finetune
  namespace: model-serving
  labels:
    kueue.x-k8s.io/queue-name: team-a   # <- routes the Job through Kueue admission
spec:
  parallelism: 4
  completions: 4
  suspend: true                          # Kueue un-suspends only when the full gang fits
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: trainer
        image: nvcr.io/nvidia/pytorch:24.10-py3
        resources:
          requests: { cpu: "8", memory: 64Gi, nvidia.com/gpu: "1" }
          limits:   { nvidia.com/gpu: "1" }
```

| | **Kueue** | **Volcano** *(CNCF Incubating)* | **YuniKorn** *(Apache)* |
|---|---|---|---|
| Model | Quota admission + Job `suspend` | Batch scheduler / PodGroup | Replacement scheduler |
| Gang scheduling | Via workload integration | Native `PodGroup` (`minAvailable`) | Native |
| Fair-share / borrowing | Cohorts + borrowing limits | Queues (weighted) | Hierarchical queues |
| Uses default kube-scheduler | ✅ (admission only) | Replaces / augments | Replaces |
| Best for | Multi-tenant quota on vanilla clusters | HPC/MPI gang, DAG jobs | Multi-tenant, Spark/Flink heritage |

---

## 3. Autoscaling AI/ML inference

There are three viable patterns; the choice follows the deployment mode.

| Signal | Correlates with load? | Reaction speed | Tooling |
|---|---|---|---|
| CPU utilization | ❌ (GPU work is off-CPU) | — | HPA v2 (don't) |
| `DCGM_FI_DEV_GPU_UTIL` | Weak (util ≠ saturation) | Medium | Prometheus Adapter / KEDA |
| `vllm:num_requests_waiting` (queue depth) | ✅ strong | Fast | KEDA |
| Knative concurrency | ✅ strong (LLM) | Fast | KServe Serverless |
| Token throughput / TTFT SLO | ✅ direct SLO | — | Custom metric |

**KEDA `ScaledObject`** (for `RawDeployment` mode) scaling on vLLM queue depth *and* GPU utilization, with a scale-down stabilization window to avoid thrash on expensive nodes:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: llama-inference
  namespace: model-serving
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: llama-3-8b-predictor
  minReplicaCount: 1
  maxReplicaCount: 10
  cooldownPeriod: 300
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300   # GPU nodes are costly — don't flap
          policies:
          - type: Pods
            value: 1
            periodSeconds: 120
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus-k8s.monitoring.svc:9090
      query: sum(vllm:num_requests_waiting{service="llama-3-8b"})
      threshold: "5"
  - type: prometheus
    metadata:
      serverAddress: http://prometheus-k8s.monitoring.svc:9090
      query: avg(DCGM_FI_DEV_GPU_UTIL{exported_pod=~"llama-3-8b.*"})
      threshold: "70"
```

---

## 4. The golden path: one platform API over all of it

The IDP should not make an app team assemble an `InferenceService` + `LocalQueue` binding + KEDA + `ServiceMonitor` by hand. A **Crossplane** (or Backstage-templated) composite hides it behind one claim:

```yaml
apiVersion: platform.example.com/v1alpha1
kind: ModelService                # a Crossplane Composite Claim (the golden path)
metadata:
  name: llama-3-8b
  namespace: team-a
spec:
  model:
    source: hf://meta-llama/Meta-Llama-3-8B-Instruct
    maxContextLength: 8192
  accelerator:
    type: nvidia-a100
    count: 1
  scaling:
    min: 0
    max: 5
    signal: concurrency=10
  quota:
    localQueue: team-a            # binds spend to the team's Kueue quota
  observability:
    slo: { latencyP99Ms: 2000 }
```

The Composition fans this single object out to: an `InferenceService`, the Kueue queue label, a `ServiceMonitor` for vLLM/DCGM metrics, a KEDA `ScaledObject`, and a Grafana SLO panel. The team gets self-service; the platform keeps quota, provenance, and cost governance centralized.

---

## 5. AI/ML *for* platform automation (AIOps) — with guardrails

Using models to run the platform is powerful and dangerous. The governing principle: **keep the non-deterministic component out of the write path of any control loop.** A model *proposes*; a deterministic, policy-gated system *disposes*.

| Level | Behavior | Human role | Example | Risk |
|---|---|---|---|---|
| **L0 Manual** | Dashboards, alerts | Acts | Grafana + Alertmanager | — |
| **L1 Assisted** | RCA hints, summaries | Approves | LLM summarizes 500 log lines to a probable cause | Hallucinated cause |
| **L2 Semi-auto** | Proposes *and* stages an action | Approves via GitOps PR | Model opens a PR tuning HPA thresholds | Bad diff merged |
| **L3 Auto (guardrailed)** | Acts within a bounded policy, auto-rolls-back | Audits | Predictive pre-scaling; auto-restart within a rate limit | Feedback loop / thrash |
| **L4 Autonomous** | Closed loop | Oversight only | Rare in production | Runaway blast radius |

Production platforms live at **L1–L3**. The safe integration pattern:

1. **Read-heavy, write-gated.** The model reads telemetry (Prometheus, logs, traces) and *emits a proposal* — never a direct `kubectl apply`.
2. **GitOps as the airlock.** The proposal becomes a **pull request** to the config repo. Argo CD / Flux applies only merged, reviewed, policy-passing manifests. This gives you diff review, audit trail, and instant rollback (`git revert`).
3. **Policy-as-code gate.** Every AI-authored change passes **Kyverno/OPA Gatekeeper** admission (no privileged pods, resource ceilings, allowed registries) *before* it can reach the cluster.
4. **Bounded blast radius.** Rate-limit AI-initiated actions; cap the magnitude (e.g., "scale by at most 2×"); wire an automatic rollback on SLO regression.
5. **Observe the observer.** The AI's own actions and cost (tokens, latency, override rate) are themselves metrics on a dashboard.

**Model Context Protocol (MCP)** is the emerging standard for connecting an LLM agent to platform tools (kubectl, Prometheus queries, incident systems) through typed, permissioned tool definitions — the interface that makes L2/L3 auditable rather than an opaque shell. Scope MCP tool servers to *read* by default; require an explicit, separately-authorized tool for any mutation, and route mutations through the GitOps airlock above.

Common AIOps use cases and their CNCF-native substrate:

- **Anomaly detection** — recording rules + a forecasting model over Prometheus series (e.g., Holt-Winters / Prophet) feeding Alertmanager; the model flags *deviation from forecast*, not a static threshold.
- **Predictive autoscaling** — forecast the next window's load and pre-warm GPU replicas *before* the queue builds (LLM cold start is minutes — reactive scaling arrives too late). Implemented as an external metric fed to KEDA.
- **LLM-assisted RCA** — on-incident, an agent correlates logs/traces/recent diffs and drafts a probable cause + suggested runbook step for the on-call engineer to approve.

---

## 6. Verification & failure diagnosis

### 6.1 Confirm the accelerator plane is healthy

```console
$ kubectl get nodes -L nvidia.com/gpu.product -o wide
NAME          STATUS   ROLES    VERSION   GPU.PRODUCT
gpu-node-01   Ready    <none>   v1.34.1   NVIDIA-A100-SXM4-40GB
gpu-node-02   Ready    <none>   v1.34.1   NVIDIA-A100-SXM4-40GB

$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
4                                    # 4 => time-slicing is active (physical card is 1)

$ kubectl exec -it -n gpu-operator ds/nvidia-device-plugin-daemonset -- nvidia-smi
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07    Driver Version: 550.90.07    CUDA Version: 12.4     |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
|   0  NVIDIA A100-SXM4-40GB On | 00000000:07:00.0 Off |                    0 |
| N/A   38C    P0    68W / 400W |  18211MiB / 40960MiB |     71%      Default |
+-------------------------------+----------------------+----------------------+

$ kubectl get resourceslices                      # DRA: is the node publishing devices?
NAME                        NODE          DRIVER            POOL          AGE
gpu-node-01-gpu.nvidia...   gpu-node-01   gpu.nvidia.com    gpu-node-01   3h
```

### 6.2 Check serving, queue, and autoscaler state

```console
$ kubectl get inferenceservice -n model-serving
NAME         URL                                              READY   PREV   LATEST   AGE
llama-3-8b   http://llama-3-8b.model-serving.example.com      True    0      100      12m

$ kubectl get clusterqueue
NAME          COHORT       PENDING WORKLOADS   ADMITTED WORKLOADS
training-cq   ml-platform  3                   4

$ kubectl get workloads -n model-serving
NAME                        QUEUE    ADMITTED   AGE
job-llama-finetune-a1b2c    team-a   False      45s        # suspended: gang doesn't fit

$ kubectl get scaledobject,hpa -n model-serving
NAME                                          SCALETARGETNAME        MIN   MAX   READY   ACTIVE
scaledobject.keda.sh/llama-inference          llama-3-8b-predictor   1     10    True    True
NAME                                          REFERENCE                       TARGETS
horizontalpodautoscaler/keda-hpa-llama-...    Deployment/llama-3-8b-predictor 7/5, 62/70
```

### 6.3 Symptom → root cause → resolution

| Symptom | Command that reveals it | Root cause | Resolution |
|---|---|---|---|
| Pod `Pending`, `0/5 nodes … Insufficient nvidia.com/gpu` | `kubectl describe pod` (Events) | Device plugin not registered, or all GPUs claimed | `kubectl get ds -n gpu-operator`; check node has `Allocatable` gpu > 0; verify tolerations for the GPU taint |
| Pod scheduled but CUDA errors / `CUDA_ERROR_OUT_OF_MEMORY` on a "shared" GPU | Container logs | **Time-slicing has no memory isolation** — a slice-mate exhausted VRAM | Move to MIG (hard partition) or full-GPU; set `failRequestsGreaterThanOne` |
| `ResourceClaim` stuck `WaitingForFirstConsumer`/unallocated | `kubectl get resourceclaims`, `kubectl describe` | DRA driver down or no `ResourceSlice` matches the CEL selector | Check DRA driver DaemonSet; loosen selector; `kubectl get resourceslices` |
| `Workload … Admitted: False` forever | `kubectl describe workload` | Kueue quota exhausted, or gang larger than `nominalQuota` | Raise `nominalQuota`/`borrowingLimit`; reduce `parallelism`; check cohort borrowing |
| `InferenceService READY=False`, predictor 0/1 | `kubectl describe isvc`; predictor pod logs | Model download failed (auth to HF), OOM on load, or CUDA/driver mismatch | Add HF token secret; raise memory; align CUDA image with node driver |
| Cold-start requests time out (Serverless) | Knative activator logs | Model load (30–300 s) exceeds client timeout with `minReplicas: 0` | Set `minReplicas: 1` (warm pool) or raise the request/activator timeout |
| KEDA never scales up under load | `kubectl describe scaledobject`; `kubectl get hpa` shows `<unknown>` | Prometheus query returns no series (bad label match) or Prometheus unreachable | Run the PromQL by hand; fix `serverAddress`/labels; check `keda-operator` logs |
| HPA scales on GPU-util but latency still bad | Grafana: util high, `vllm:num_requests_waiting` climbing | **GPU util saturates** — it's not a load signal | Scale on queue depth / concurrency instead of util |
| AI-remediation loop causes thrash | Audit AI-action metrics | No stabilization / no rate limit on AI actions (L3 gone wrong) | Add `stabilizationWindowSeconds`, rate-limit, cap magnitude, gate via GitOps PR |

### 6.4 End-to-end smoke test of a served model

```console
$ kubectl port-forward -n model-serving svc/llama-3-8b-predictor 8080:80 &
$ curl -s http://localhost:8080/openai/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"llama-3-8b","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' | jq .choices[0].message.content
"pong — how can I help?"

$ curl -s http://localhost:8080/metrics | grep -E 'vllm:(num_requests_running|gpu_cache_usage_perc)'
vllm:num_requests_running{model_name="llama-3-8b"} 3.0
vllm:gpu_cache_usage_perc{model_name="llama-3-8b"} 0.41       # KV-cache 41% full — headroom OK
```

If `gpu_cache_usage_perc` approaches `1.0`, the model is *preempting/recomputing* sequences and tail latency will spike — that is your real saturation signal, well before `DCGM_FI_DEV_GPU_UTIL` shows a problem.

---

## Referencias

- **CNPA Curriculum (CNCF)** — https://github.com/cncf/curriculum · https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- **Kubernetes — Dynamic Resource Allocation (GA 1.34)** — https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/
- **KServe** *(CNCF Incubating)* — https://kserve.github.io/website/latest/ · HuggingFace runtime: https://kserve.github.io/website/latest/modelserving/v1beta1/llm/huggingface/
- **Kueue** — https://kueue.sigs.k8s.io/docs/
- **Volcano** *(CNCF Incubating)* — https://volcano.sh/en/docs/
- **Apache YuniKorn** — https://yunikorn.apache.org/docs/
- **KEDA** *(CNCF Graduated)* — https://keda.sh/docs/latest/
- **Knative Serving — Autoscaling (KPA)** — https://knative.dev/docs/serving/autoscaling/
- **NVIDIA GPU Operator** — https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- **NVIDIA GPU sharing (time-slicing / MPS / MIG)** — https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- **NVIDIA DRA Driver for GPUs** — https://github.com/NVIDIA/k8s-dra-driver-gpu
- **DCGM Exporter (GPU metrics)** — https://github.com/NVIDIA/dcgm-exporter
- **vLLM (serving engine & metrics)** — https://docs.vllm.ai/en/latest/
- **Kubeflow (Training/Pipelines)** — https://www.kubeflow.org/docs/
- **Prometheus Adapter (custom/external metrics)** — https://github.com/kubernetes-sigs/prometheus-adapter
- **Crossplane** *(CNCF Graduated)* — https://docs.crossplane.io/
- **Kyverno / OPA Gatekeeper (policy airlock)** — https://kyverno.io/docs/ · https://open-policy-agent.github.io/gatekeeper/website/docs/
- **Argo CD (GitOps airlock)** — https://argo-cd.readthedocs.io/
- **Model Context Protocol (MCP)** — https://modelcontextprotocol.io/
- **CNCF TAG Workloads Foundation (formerly TAG Runtime) — AI/ML WG** — https://github.com/cncf/tag-workloads-foundation