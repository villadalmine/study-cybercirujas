# Topic 4.2 — Guided Exercises

## Describe the functionality, business use cases, and business value of Google Cloud's infrastructure offerings

**Certification:** Google Cloud Digital Leader (exam guide 2026-08-12) · **Section 4 weight:** 6.0

---

### How to use this document

Every exercise is a **numbered execution block** followed by **verification questions**. Run the commands; do not read them. The commands are deliberately biased toward *discovery* (`list`, `describe`, Billing Catalog API) rather than *provisioning*, because the exam tests whether you can **map a business requirement onto an infrastructure offering and defend the cost**, not whether you can type `gcloud compute instances create` from memory.

Answers to every question are in the single collapsible section at the end.

> **Cost warning.** Exercises 3, 6 and 9 create billable resources. Each block ends with a teardown step. Total spend if you follow the teardown is under **USD 1.00**. Exercise 9 (regional MIG) is the only one that can run away — set a budget alert before you start.
>
> **Prices and inventory in this document are list values captured at the time of writing.** Google changes SKUs, region counts and discount percentages continuously. Every exercise that quotes a number also gives you the command to pull the *live* number. When they disagree, the live number is right and this document is stale. That habit — never quoting a cloud price from memory — is itself part of the objective.

### Prerequisites

| Requirement | Check |
|---|---|
| `gcloud` CLI ≥ 480.0.0 | `gcloud version` |
| A project with a billing account attached | `gcloud beta billing projects describe $PROJECT_ID` |
| `jq` | `jq --version` |
| Roles | `roles/compute.viewer`, `roles/billing.viewer`, and `roles/compute.instanceAdmin.v1` for the provisioning blocks |
| APIs | `compute.googleapis.com`, `cloudbilling.googleapis.com`, `run.googleapis.com` |

---

## Exercise 0 — Establish a reproducible shell

**Objective:** every later block assumes these variables. Infrastructure decisions are *regional* decisions; hard-coding a region in your head is the most common source of wrong cost answers.

### Steps

1. Pin the project and a working region/zone pair.

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
export ZONE="us-central1-a"
gcloud config set project "$PROJECT_ID"
gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"
```

2. Enable the APIs the exercises need. This is idempotent.

```bash
gcloud services enable \
  compute.googleapis.com \
  cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com \
  run.googleapis.com \
  recommender.googleapis.com
```

3. Confirm the billing account is live — a project without billing silently degrades half the commands below to `PERMISSION_DENIED`.

```bash
gcloud beta billing projects describe "$PROJECT_ID" \
  --format="value(billingAccountName, billingEnabled)"
```

Expected output:

```
billingAccounts/01A2B3-C4D5E6-F7G8H9	True
```

4. Set a hard guardrail before you provision anything.

```bash
gcloud billing budgets create \
  --billing-account="01A2B3-C4D5E6-F7G8H9" \
  --display-name="cdl-4.2-lab-guardrail" \
  --budget-amount=5USD \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --filter-projects="projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')"
```

### Verification questions

**Q0.1** — A budget with threshold rules does **not** stop spend. What is the exam-relevant business distinction between a *budget alert*, a *quota*, and a *committed use discount*, and which of the three is the only true spending cap?

**Q0.2** — Why does `gcloud config set compute/region` change the *answer* to a TCO question, not just the target of a command? Name two cost components that vary by region.

---

## Exercise 1 — The physical substrate: regions, zones, and the private backbone

**Objective:** Google Cloud's infrastructure story starts below the product list. Regions/zones determine latency, data residency, availability SLA, price and carbon intensity simultaneously. The exam phrases this as "business value of Google Cloud's global infrastructure."

### Steps

1. Count the live footprint from the API rather than from a slide.

```bash
gcloud compute regions list --format="value(name)" | wc -l
gcloud compute zones  list --format="value(name)" | wc -l
```

Representative output (your numbers will be higher — Google adds regions continuously):

```
42
127
```

2. Inspect a single region's structure and capacity envelope.

```bash
gcloud compute regions describe "$REGION" \
  --format="yaml(name, status, zones.basename())"
```

```yaml
name: us-central1
status: UP
zones:
- us-central1-a
- us-central1-b
- us-central1-c
- us-central1-f
```

3. Show that zones are **independent failure domains with different hardware**, not cosmetic labels. Compare the CPU platforms available per zone:

```bash
for z in $(gcloud compute zones list \
             --filter="region:($REGION)" --format="value(name)"); do
  printf '%-18s %s\n' "$z" \
    "$(gcloud compute zones describe "$z" \
         --format='value(availableCpuPlatforms.list())')"
done
```

```
us-central1-a      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Sapphire Rapids,Intel Skylake,AMD Rome,AMD Milan,AMD Genoa
us-central1-b      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake,Intel Sapphire Rapids,Intel Skylake,AMD Rome,AMD Milan
us-central1-c      Intel Broadwell,Intel Cascade Lake,Intel Emerald Rapids,Intel Ice Lake,Intel Skylake,AMD Rome,AMD Milan,AMD Genoa
us-central1-f      Intel Broadwell,Intel Cascade Lake,Intel Ice Lake,Intel Skylake,AMD Rome
```

4. Prove that machine *inventory* is zonal, not regional. Ask two zones in the same region for the same machine family:

```bash
gcloud compute machine-types list \
  --filter="zone:($REGION-a) AND name~^c4-standard" \
  --format="table(name, guestCpus, memoryMb)"

gcloud compute machine-types list \
  --filter="zone:($REGION-f) AND name~^c4-standard" \
  --format="table(name, guestCpus, memoryMb)"
```

If the second command returns fewer rows (or `Listed 0 items.`), you have just discovered — for free, before writing a Terraform plan — that a zone in your target region cannot host the machine type your capacity model assumed.

5. Read the multi-region and dual-region location metadata, which is where data-residency answers actually come from:

```bash
gcloud storage buckets create "gs://cdl-42-multiregion-${RANDOM}" \
  --location=US --dry-run
```

```
Would create: gs://cdl-42-multiregion-14822 with location "US" (multi-region),
storage class "STANDARD", uniform bucket-level access disabled.
```

6. Pull the carbon characteristics of candidate regions. This is a published, per-region figure — Google's Carbon Free Energy percentage (CFE%) and grid carbon intensity (gCO₂eq/kWh) — and it is now a routine input to region selection for regulated and ESG-reporting customers. Consult <https://cloud.google.com/sustainability/region-carbon>; the Cloud console region picker surfaces the same data as a **Low CO₂** badge.

### Verification questions

**Q1.1** — A retail bank must keep customer records inside a single EU member state, and it must survive the loss of a datacenter building. Which Google Cloud location construct satisfies both, and which one satisfies *neither* despite sounding safer? Explain in terms of failure domain and residency boundary.

**Q1.2** — Step 3 showed different CPU platforms in different zones of one region. What concrete production incident does this cause when you deploy a regional managed instance group with a machine type that pins `minCpuPlatform`, and what is the business consequence?

**Q1.3** — Google's inter-region traffic rides a privately owned fibre backbone with subsea cables, while a comparable on-premises multi-site architecture rides transit providers. Translate that engineering fact into two *business value* statements a CFO would accept.

**Q1.4** — A workload's users are 80% in São Paulo and its data must be replicated for DR. Deploying in `southamerica-east1` gives low latency but a higher grid carbon intensity than `us-central1`. Under what governance conditions is it defensible to choose the higher-carbon region anyway?

**Sources:** <https://cloud.google.com/docs/geography-and-regions> · <https://cloud.google.com/compute/docs/regions-zones> · <https://cloud.google.com/about/locations> · <https://cloud.google.com/sustainability/region-carbon>

---

## Exercise 2 — The compute abstraction ladder

**Objective:** the exam's favourite question shape is "which compute offering fits this business scenario." The decision is not about technology preference; it is about **who is responsible for what**, and each rung up the ladder trades control for removed operational cost.

| Rung | Offering | You manage | Google manages | Billing granularity |
|---|---|---|---|---|
| IaaS | **Bare Metal Solution / Sole-tenant nodes** | OS, patching, licensing, HA | Physical facility, power, network | Per node/hour, monthly minimum |
| IaaS | **Compute Engine** | OS, patching, scaling policy, HA design | Hypervisor, host maintenance, live migration | Per second (60 s minimum) |
| IaaS | **Google Cloud VMware Engine** | vSphere workloads, VM lifecycle | ESXi/vSAN/NSX stack, hardware, upgrades | Per node/hour |
| CaaS | **GKE Standard** | Node pools, upgrades, capacity | Control plane, healing | Per node/second + control plane fee |
| CaaS | **GKE Autopilot** | Pod specs, requests/limits | Nodes, scaling, node security posture | Per **pod resource request**/second |
| PaaS | **App Engine / Cloud Run** | Container image, concurrency, min/max | Everything below the container | Per request or per instance-second |
| FaaS | **Cloud Run functions** | A function body | Everything else | Per invocation + GB-s |

### Steps

1. Deploy the *same* business capability at two different rungs and compare the artefact you had to author. First, the serverless rung — a complete, valid Knative service manifest:

```yaml
# checkout-service.yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: checkout-api
  labels:
    cost-center: "retail-payments"
    env: "prod"
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"
        autoscaling.knative.dev/maxScale: "100"
        run.googleapis.com/cpu-throttling: "false"
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/startup-cpu-boost: "true"
    spec:
      containerConcurrency: 80
      timeoutSeconds: 300
      serviceAccountName: checkout-sa@PROJECT_ID.iam.gserviceaccount.com
      containers:
        - image: us-docker.pkg.dev/cloudrun/container/hello
          ports:
            - name: http1
              containerPort: 8080
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
          env:
            - name: LOG_LEVEL
              value: "info"
  traffic:
    - percent: 100
      latestRevision: true
```

```bash
sed -i "s/PROJECT_ID/$PROJECT_ID/" checkout-service.yaml
gcloud run services replace checkout-service.yaml --region="$REGION"
```

```
Applying new configuration to Cloud Run service [checkout-api] in project [my-proj] region [us-central1]
✓ Deploying new service... Done.
  ✓ Creating Revision...
  ✓ Routing traffic...
Done.
Service [checkout-api] revision [checkout-api-00001-abc] has been deployed
and is serving 100 percent of traffic.
Service URL: https://checkout-api-abcdefghij-uc.a.run.app
```

2. Count the operational surface you did **not** author: no OS image, no patch schedule, no autoscaler resource, no load balancer, no TLS certificate, no health check.

```bash
gcloud run services describe checkout-api --region="$REGION" \
  --format="value(status.url, status.traffic[0].revisionName)"
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  "$(gcloud run services describe checkout-api --region=$REGION --format='value(status.url)')"
```

```
200 0.284510s
```

3. Now express the same workload at the CaaS rung. This is the manifest set you would owe on GKE — note what appears that Cloud Run did for you implicitly:

```yaml
# checkout-gke.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      nodeSelector:
        cloud.google.com/compute-class: Balanced
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: checkout
      containers:
        - name: checkout
          image: us-docker.pkg.dev/cloudrun/container/hello
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
              ephemeral-storage: 1Gi
            limits:
              cpu: 500m
              memory: 512Mi
              ephemeral-storage: 1Gi
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-pdb
  namespace: shop
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: checkout
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-hpa
  namespace: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

4. Do **not** create a cluster (a GKE Autopilot cluster costs real money per hour). Instead, price the difference analytically in Exercise 4.

5. Tear down the Cloud Run service — it scales to zero but the revision retains an image reference and a URL:

```bash
gcloud run services delete checkout-api --region="$REGION" --quiet
```

### Verification questions

**Q2.1** — In the Cloud Run manifest, `minScale: "1"` was set. Name the business trade-off this single line encodes, and quantify it: what does the customer buy, and what does the customer stop getting?

**Q2.2** — GKE Autopilot bills per **pod resource request**, GKE Standard bills per **node**. A team habitually sets `requests` at 3× measured usage. Which billing model punishes that behaviour, which one hides it, and what does that imply for a FinOps programme?

**Q2.3** — A logistics company has a monolithic Windows application with a licensed third-party driver that requires kernel access, and it needs to be off the corporate datacenter in nine months. Rank the rungs of the ladder for this scenario and justify the top choice in one sentence of business language.

**Q2.4** — Both manifests declare `cpu: 500m`/`cpu: "1"`. On Cloud Run this affects *price per request*; on GKE Standard it does not directly affect the bill at all. Explain why.

**Sources:** <https://cloud.google.com/run/docs/overview/what-is-cloud-run> · <https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview> · <https://cloud.google.com/docs/overview/cloud-platform-services>

---

## Exercise 3 — Machine families, right-sizing, and live migration

**Objective:** Compute Engine's business value is *not* "virtual machines exist." It is the combination of custom shapes, per-second billing, automatic right-sizing recommendations, and transparent host maintenance.

### Steps

1. Enumerate the machine families visible in your zone and group them by prefix. The prefix *is* the family, and the family *is* the price/performance contract.

```bash
gcloud compute machine-types list --zones="$ZONE" \
  --format="value(name)" \
  | sed 's/-.*//' | sort -u | tr '\n' ' '
```

```
a2 a3 c2 c2d c3 c3d c4 c4a e2 f1 g2 h3 m1 m2 m3 n1 n2 n2d n4 t2a t2d z3
```

2. Read the shape of one member of each of the four purpose classes:

```bash
gcloud compute machine-types describe n4-standard-8 --zone="$ZONE" \
  --format="table(name, guestCpus, memoryMb)"
gcloud compute machine-types describe c4-highcpu-8   --zone="$ZONE" \
  --format="table(name, guestCpus, memoryMb)" 2>/dev/null
gcloud compute machine-types describe m3-ultramem-32  --zone="$ZONE" \
  --format="table(name, guestCpus, memoryMb)" 2>/dev/null
```

```
NAME           GUEST_CPUS  MEMORY_MB
n4-standard-8  8           32768
NAME           GUEST_CPUS  MEMORY_MB
c4-highcpu-8   8           16384
NAME            GUEST_CPUS  MEMORY_MB
m3-ultramem-32  32          976000
```

The ratio is the whole story: general-purpose ≈ 4 GB/vCPU, compute-optimized ≈ 2 GB/vCPU, memory-optimized ≈ 30 GB/vCPU.

3. Create a **custom machine type** — a shape no other major provider's standard catalog offers — sized to a measured workload of 6 vCPU / 20 GB, and observe the automatic maintenance behaviour:

```bash
gcloud compute instances create cdl-42-rightsize \
  --zone="$ZONE" \
  --custom-cpu=6 \
  --custom-memory=20GB \
  --custom-vm-type=n2 \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-type=pd-balanced --boot-disk-size=20GB \
  --maintenance-policy=MIGRATE \
  --labels=cost-center=cdl-lab,owner=student \
  --metadata=enable-oslogin=TRUE
```

```
Created [https://www.googleapis.com/compute/v1/projects/my-proj/zones/us-central1-a/instances/cdl-42-rightsize].
NAME              ZONE           MACHINE_TYPE               PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP    STATUS
cdl-42-rightsize  us-central1-a  n2-custom-6-20480                       10.128.0.14  34.66.112.203  RUNNING
```

4. Confirm the maintenance contract that differentiates Compute Engine from most IaaS competitors:

```bash
gcloud compute instances describe cdl-42-rightsize --zone="$ZONE" \
  --format="yaml(name, machineType.basename(), scheduling)"
```

```yaml
machineType: n2-custom-6-20480
name: cdl-42-rightsize
scheduling:
  automaticRestart: true
  onHostMaintenance: MIGRATE
  preemptible: false
  provisioningModel: STANDARD
```

`onHostMaintenance: MIGRATE` means Google moves this running VM to another physical host during datacenter maintenance **without rebooting the guest**. Read <https://cloud.google.com/compute/docs/instances/live-migration-process>.

5. Ask the platform what it thinks of your sizing. Recommendations need ~24 h of metrics, so expect an empty set on a fresh VM — run it against a long-lived project if you have one:

```bash
gcloud recommender recommendations list \
  --project="$PROJECT_ID" \
  --location="$ZONE" \
  --recommender=google.compute.instance.MachineTypeRecommender \
  --format="table(description, primaryImpact.costProjection.cost.units, stateInfo.state)"
```

```
DESCRIPTION                                                        UNITS  STATE
Save cost by changing machine type from n2-standard-8 to n2-standard-4.  -71  ACTIVE
```

6. Inspect the sole-tenancy option without buying one — this is the answer to per-core licensing and physical-isolation compliance requirements:

```bash
gcloud compute sole-tenancy node-types list --zones="$ZONE" \
  --format="table(name, cpuCount, memoryMb, localSsdGb)"
```

```
NAME          CPU_COUNT  MEMORY_MB  LOCAL_SSD_GB
c2-node-60-240      60     245760            0
m3-node-128-3904   128    3997696         3000
n2-node-80-640      80     655360            0
```

7. **Teardown.**

```bash
gcloud compute instances delete cdl-42-rightsize --zone="$ZONE" --quiet
```

### Verification questions

**Q3.1** — Step 3 produced `n2-custom-6-20480`. The nearest predefined shapes are `n2-standard-8` (8/32) and `n2-highcpu-8` (8/8). State the business value of the custom shape in one number and one sentence, and name the two situations where a custom shape is the *wrong* choice.

**Q3.2** — `onHostMaintenance: MIGRATE` versus `TERMINATE`. Which workloads *must* use `TERMINATE`, and what compensating architecture do they need? What is the customer-visible business value of the `MIGRATE` default?

**Q3.3** — A software vendor licenses per physical core and audits annually. The customer runs 40 VMs on Compute Engine. Explain, in licensing terms, why sole-tenant nodes can *reduce* total cost even though the node SKU is more expensive per hour than the equivalent shared-tenancy VMs.

**Q3.4** — The Machine Type Recommender proposed a downsize worth ~USD 71/month for one VM. Why is the *organisational* value of Active Assist recommendations usually larger than the sum of the individual savings?

**Sources:** <https://cloud.google.com/compute/docs/machine-resource> · <https://cloud.google.com/compute/docs/instances/creating-instance-with-custom-machine-type> · <https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes> · <https://cloud.google.com/compute/docs/instances/live-migration-process>

---

## Exercise 4 — The four pricing levers, and a defensible TCO model

**Objective:** this is the highest-yield exercise in the topic. "Business value" on this exam almost always resolves to: *which discount mechanism applies, and what commitment does it demand in exchange.*

The four levers:

| Lever | Commitment | Typical reduction | Applies to |
|---|---|---|---|
| **Sustained use discount (SUD)** | None — automatic | up to ~20–30% | Older families (N1 up to ~30%; N2/N2D/C2/C2D/M1–M3 up to ~20%). **Not** E2 or the newest families (N4, C3, C4) |
| **Resource-based CUD** | 1 or 3 years, per region, per family | ~37% (1 yr) / ~55% (3 yr) general-purpose; higher for memory-optimized | Committed vCPU + RAM |
| **Flexible (spend-based) CUD** | 1 or 3 years, hourly spend | ~28% (1 yr) / ~46% (3 yr) | Portable across families, regions, and several services |
| **Spot VMs** | None — preemptible with ~30 s notice, no SLA | 60–91% | Fault-tolerant/batch |

### Steps

1. Pull **live** list prices from the Cloud Billing Catalog API instead of trusting the table above. Find the Compute Engine service ID first:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudbilling.googleapis.com/v1/services?pageSize=200" \
  | jq -r '.services[] | select(.displayName|test("Compute Engine")) | "\(.serviceId)\t\(.displayName)"'
```

```
6F81-5844-456A	Compute Engine
```

2. Extract the on-demand and Spot SKUs for N2 vCPU in your region:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD&pageSize=5000" \
  | jq -r --arg R "$REGION" '
      .skus[]
      | select(.serviceRegions[]? == $R)
      | select(.description | test("N2 Instance (Core|Ram)"))
      | "\(.description)\t\(.pricingInfo[0].pricingExpression.tieredRates[-1].unitPrice.nanos/1e9)\t\(.pricingInfo[0].pricingExpression.usageUnitDescription)"'
```

Representative output:

```
N2 Instance Core running in Americas	0.031611	hour
N2 Instance Ram running in Americas	0.004237	gibibyte hour
Spot Preemptible N2 Instance Core running in Americas	0.007652	hour
Spot Preemptible N2 Instance Ram running in Americas	0.001026	gibibyte hour
```

3. Build the on-demand hourly price of `n2-standard-8` (8 vCPU, 32 GB) by hand — the exam expects you to know that Compute Engine prices **resources**, not SKU names:

```
(8 × 0.031611) + (32 × 0.004237) = 0.252888 + 0.135584 = 0.388472 USD/hour
730 h/month × 0.388472 = 283.58 USD/VM/month
```

4. Apply each lever to a 100-VM fleet running 24/7:

| Scenario | Effective rate | 100 VMs / month | vs on-demand |
|---|---|---|---|
| On-demand, no discount | $283.58 | **$28,358** | — |
| SUD only (N2, full month, ~20%) | $226.86 | **$22,686** | −20% |
| 1-year resource CUD (~37%) | $178.66 | **$17,866** | −37% |
| 3-year resource CUD (~55%) | $127.61 | **$12,761** | −55% |
| Spot (~70% observed) | $85.07 | **$8,507** | −70% |

5. Now build the shape a real platform team would actually commit to — a **blended** fleet, because committing 100% is a bet that the fleet never shrinks:

```
 60 VMs × 3-year CUD   =  60 × 127.61 =  $7,656.60
 25 VMs × on-demand+SUD =  25 × 226.86 =  $5,671.50
 15 VMs × Spot (batch)  =  15 ×  85.07 =  $1,276.05
                                        -----------
                            blended     = $14,604.15 / month
                            vs on-demand $28,358.00 → 48.5% reduction
```

6. Verify a Spot instance's contract yourself — the price is real and so is the eviction:

```bash
gcloud compute instances create cdl-42-spot \
  --zone="$ZONE" \
  --machine-type=n2-standard-2 \
  --provisioning-model=SPOT \
  --instance-termination-action=DELETE \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=20GB --boot-disk-type=pd-balanced

gcloud compute instances describe cdl-42-spot --zone="$ZONE" \
  --format="yaml(scheduling)"
```

```yaml
scheduling:
  automaticRestart: false
  instanceTerminationAction: DELETE
  onHostMaintenance: TERMINATE
  preemptible: true
  provisioningModel: SPOT
```

Note what Google refused to let you set: `automaticRestart: false` and `onHostMaintenance: TERMINATE` are forced. That is the SLA exclusion made mechanical.

7. Inspect existing commitments (empty in a lab project, but this is the audit command):

```bash
gcloud compute commitments list \
  --format="table(name, region.basename(), plan, status, endTimestamp)"
```

8. **Teardown.**

```bash
gcloud compute instances delete cdl-42-spot --zone="$ZONE" --quiet
```

### Verification questions

**Q4.1** — Sustained use discounts require no commitment and apply automatically, yet Google's newest machine families (N4, C3, C4) and E2 do **not** offer them. What did Google give customers instead, and why is that arguably better for a customer with a mature FinOps practice?

**Q4.2** — A resource-based CUD is bought per-region and per-family. A company commits 3 years of N2 in `us-central1`, then re-platforms to C4 in `europe-west4` in year two. What happens to the commitment, and which discount instrument would have avoided the trap?

**Q4.3** — Using step 5's blended model: the CFO asks "why not commit 100% at 3 years and save 55% across the board?" Give the two-part answer — one part financial, one part architectural.

**Q4.4** — A nightly risk-simulation batch takes 6 hours on 200 VMs and can checkpoint every 5 minutes. A customer-facing payments API runs on 12 VMs. Assign a pricing lever to each and state the *specific* property of the workload that justifies it.

**Q4.5** — Compute Engine bills per second with a 60-second minimum. Name a workload pattern where this granularity is worth more than any discount percentage.

**Sources:** <https://cloud.google.com/compute/docs/sustained-use-discounts> · <https://cloud.google.com/docs/cuds> · <https://cloud.google.com/compute/docs/instances/spot> · <https://cloud.google.com/billing/docs/how-to/catalog-api> · <https://cloud.google.com/products/calculator>

---

## Exercise 5 — Storage offerings: the cost / latency / durability triangle

**Objective:** map four distinct storage *products* — object, block, file, and the archive tiers — onto four distinct business requirements.

### Steps

1. Enumerate the block storage types available to a VM. The generational split matters: Persistent Disk couples performance to capacity; Hyperdisk decouples them.

```bash
gcloud compute disk-types list --zones="$ZONE" \
  --format="table(name, validDiskSize)"
```

```
NAME                 VALID_DISK_SIZE
hyperdisk-balanced   4GB-65536GB
hyperdisk-extreme    64GB-65536GB
hyperdisk-ml         4GB-65536GB
hyperdisk-throughput 2048GB-32768GB
local-ssd            375GB-375GB
pd-balanced          10GB-65536GB
pd-extreme           500GB-65536GB
pd-ssd               10GB-65536GB
pd-standard          10GB-65536GB
```

2. Create one of each generation and read back the performance contract:

```bash
gcloud compute disks create cdl-42-pd \
  --zone="$ZONE" --type=pd-balanced --size=100GB

gcloud compute disks create cdl-42-hd \
  --zone="$ZONE" --type=hyperdisk-balanced --size=100GB \
  --provisioned-iops=6000 --provisioned-throughput=200

gcloud compute disks describe cdl-42-hd --zone="$ZONE" \
  --format="yaml(name, type.basename(), sizeGb, provisionedIops, provisionedThroughput)"
```

```yaml
name: cdl-42-hd
provisionedIops: '6000'
provisionedThroughput: '200'
sizeGb: '100'
type: hyperdisk-balanced
```

On `pd-balanced` you cannot set those fields at all — you buy IOPS by over-provisioning capacity you do not need. That over-provisioning **is** the cost difference.

3. Create a bucket per storage class and read the class contract:

```bash
BUCKET="cdl-42-${RANDOM}"
for CLASS in STANDARD NEARLINE COLDLINE ARCHIVE; do
  gcloud storage buckets create "gs://${BUCKET}-$(echo $CLASS | tr 'A-Z' 'a-z')" \
    --location="$REGION" --default-storage-class="$CLASS" \
    --uniform-bucket-level-access
done

gcloud storage buckets list --format="table(name, location, storageClass)" \
  --filter="name~^${BUCKET}"
```

```
NAME                    LOCATION     STORAGE_CLASS
cdl-42-14822-archive    US-CENTRAL1  ARCHIVE
cdl-42-14822-coldline   US-CENTRAL1  COLDLINE
cdl-42-14822-nearline   US-CENTRAL1  NEARLINE
cdl-42-14822-standard   US-CENTRAL1  STANDARD
```

4. Attach a lifecycle policy — the mechanism that converts a storage-class *table* into an actual cost curve:

```json
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "SetStorageClass", "storageClass": "NEARLINE" },
        "condition": { "age": 30, "matchesStorageClass": ["STANDARD"] }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "COLDLINE" },
        "condition": { "age": 90, "matchesStorageClass": ["NEARLINE"] }
      },
      {
        "action": { "type": "SetStorageClass", "storageClass": "ARCHIVE" },
        "condition": { "age": 365, "matchesStorageClass": ["COLDLINE"] }
      },
      {
        "action": { "type": "Delete" },
        "condition": { "age": 2555, "numNewerVersions": 3 }
      }
    ]
  }
}
```

```bash
cat > lifecycle.json <<'EOF'
{ ... paste the JSON above ... }
EOF
gcloud storage buckets update "gs://${BUCKET}-standard" --lifecycle-file=lifecycle.json
gcloud storage buckets describe "gs://${BUCKET}-standard" --format="yaml(lifecycle)"
```

5. Do the arithmetic that justifies the policy. 100 TB of audit logs, 10% read in any month, list prices ≈ Standard $0.020, Nearline $0.010, Coldline $0.004, Archive $0.0012 per GB-month (regional, `us-central1`):

```
Flat Standard:  102,400 GB × 0.020                     = $2,048.00 / month
Tiered:          10,240 GB × 0.020 (Standard, hot)     =   $204.80
                 30,720 GB × 0.010 (Nearline)          =   $307.20
                 61,440 GB × 0.0012 (Archive)          =    $73.73
                                                         ----------
                                                          $585.73 / month  (−71%)
   + retrieval:  Nearline $0.01/GB, Coldline $0.02/GB, Archive $0.05/GB
```

6. Look at the file rung — the offering that exists because "lift the NFS server" is a real migration requirement:

```bash
gcloud filestore instances create cdl-42-nfs \
  --zone="$ZONE" --tier=BASIC_HDD \
  --file-share=name=share1,capacity=1TB \
  --network=name=default \
  --dry-run 2>&1 | head -5
```

Filestore tiers (`BASIC_HDD`, `BASIC_SSD`, `ZONAL`, `REGIONAL`, `ENTERPRISE`) trade minimum capacity and price against IOPS and availability scope; `REGIONAL`/`ENTERPRISE` are the ones with a regional availability posture. **Do not actually create one** — the minimum billable capacity is 1 TB.

7. **Teardown.**

```bash
gcloud compute disks delete cdl-42-pd cdl-42-hd --zone="$ZONE" --quiet
for CLASS in standard nearline coldline archive; do
  gcloud storage rm --recursive "gs://${BUCKET}-${CLASS}" --quiet
done
```

### Verification questions

**Q5.1** — Archive class costs ~$0.0012/GB-month against Standard's ~$0.020 — a 16× difference — and has the *same* 11-nines design durability. Name the three cost mechanisms that make Archive expensive for the wrong workload, and describe a scenario where lifecycle tiering to Archive **increases** the bill.

**Q5.2** — Hyperdisk lets you provision IOPS and throughput independently of capacity. Express the business value as a sentence about a database with a 200 GB dataset that needs 60,000 IOPS.

**Q5.3** — Local SSD is fixed at 375 GB increments, is physically attached to the host, and is **ephemeral**. Given that, what is it actually for, and what does its existence tell you about how Compute Engine's storage tiers are meant to be composed?

**Q5.4** — A team proposes replacing a 4 TB Filestore share with a Cloud Storage bucket "because objects are cheaper per GB." What breaks, and what is the correct decision criterion between file and object storage?

**Sources:** <https://cloud.google.com/storage/docs/storage-classes> · <https://cloud.google.com/storage/docs/lifecycle> · <https://cloud.google.com/compute/docs/disks> · <https://cloud.google.com/filestore/docs/service-tiers> · <https://cloud.google.com/storage/sla>

---

## Exercise 6 — Networking offerings: tiers, load balancing, and hybrid connectivity

**Objective:** Google's network is the offering customers most often fail to price and most often underestimate as a differentiator. Two decisions dominate: **network service tier** and **hybrid connectivity type**.

### Steps

1. Read the project's default network tier and change it explicitly. Defaults that cost money should never be implicit:

```bash
gcloud compute project-info describe \
  --format="value(defaultNetworkTier)"
```

```
PREMIUM
```

2. Reserve one address in each tier and observe the constraint the platform enforces:

```bash
gcloud compute addresses create cdl-42-premium \
  --region="$REGION" --network-tier=PREMIUM

gcloud compute addresses create cdl-42-standard \
  --region="$REGION" --network-tier=STANDARD

gcloud compute addresses list \
  --format="table(name, address, region.basename(), networkTier, status)" \
  --filter="name~^cdl-42"
```

```
NAME             ADDRESS         REGION       NETWORK_TIER  STATUS
cdl-42-premium   34.66.112.210   us-central1  PREMIUM       RESERVED
cdl-42-standard  35.184.20.17    us-central1  STANDARD      RESERVED
```

3. Try to build a **global** external IP in Standard tier — the failure is the lesson:

```bash
gcloud compute addresses create cdl-42-global-standard \
  --global --network-tier=STANDARD
```

```
ERROR: (gcloud.compute.addresses.create) Could not fetch resource:
 - Invalid value for field 'resource.networkTier': 'STANDARD'.
   Global addresses only support PREMIUM network tier.
```

Standard Tier is **regional by construction**. Global anycast load balancing — one IP served from the nearest of Google's edge locations — is a Premium Tier capability.

4. Price the tier decision on 10 TB/month of internet egress (list prices, Premium tiered at ~$0.12/GB for the first TiB then ~$0.11/GB; Standard ~$0.085/GB):

```
Premium:  1,024 GB × 0.12 = $122.88
          9,216 GB × 0.11 = $1,013.76      → $1,136.64 / month
Standard: 10,240 GB × 0.085                → $  870.40 / month   (−23%)
```

The 23% saving buys: no global anycast IP, no cold-potato routing (traffic leaves Google's backbone at the *source* region rather than the edge nearest the user), regional-only load balancing, and a latency/jitter profile set by the public internet.

5. Enumerate the load balancer families — the exam tests *selection*, so learn the axes: external/internal, global/regional, proxy/passthrough, L7/L4.

```bash
gcloud compute backend-services list \
  --format="table(name, loadBalancingScheme, protocol, region.basename())"
```

| Load balancer | Scheme | Scope | Layer | Business use case |
|---|---|---|---|---|
| Global external Application LB | `EXTERNAL_MANAGED` | Global | L7 | Public web/API, one anycast IP worldwide, Cloud CDN + Cloud Armor attach here |
| Regional external Application LB | `EXTERNAL_MANAGED` | Regional | L7 | Data-residency-bound web tier |
| External proxy Network LB | `EXTERNAL_MANAGED` | Global/Regional | L4 proxy | TCP/SSL offload for non-HTTP protocols |
| External passthrough Network LB | `EXTERNAL` | Regional | L4 passthrough | Preserve client IP, UDP, arbitrary protocols; Maglev-based |
| Internal Application LB | `INTERNAL_MANAGED` | Regional/Cross-region | L7 | Microservice-to-microservice with path routing |
| Internal passthrough Network LB | `INTERNAL` | Regional | L4 | Default gateway / NVA insertion, database VIPs |

6. Compare hybrid connectivity products against a business requirement, not a bandwidth number:

| Product | Bandwidth | SLA | Traverses public internet? | Typical driver |
|---|---|---|---|---|
| **HA VPN** | ~3 Gbps/tunnel, aggregated | 99.99% (HA config) | Yes, encrypted (IPsec) | Fast to stand up, low bandwidth, no colo presence |
| **Partner Interconnect** | 50 Mbps – 50 Gbps | 99.9% / 99.99% by topology | No | No colo presence, but needs private, predictable path |
| **Dedicated Interconnect** | 10 or 100 Gbps circuits | 99.9% / 99.99% by topology | No | High sustained volume; also **lowers egress price** |
| **Cross-Cloud Interconnect** | 10 / 100 Gbps | Per topology | No | Private link to AWS/Azure/OCI for real multicloud data planes |
| **Network Connectivity Center** | n/a (control plane) | n/a | n/a | Hub-and-spoke transit across VPCs, sites and clouds |

7. **Teardown.**

```bash
gcloud compute addresses delete cdl-42-premium cdl-42-standard \
  --region="$REGION" --quiet
```

### Verification questions

**Q6.1** — Explain "cold-potato routing" and why Google's use of it in Premium Tier is a *product* decision with a *cost* consequence, not just a routing preference.

**Q6.2** — A gaming company serves players in 30 countries from one region and is considering Standard Tier to save 23% on egress. Which single technical constraint from step 3 makes this a bad trade for them, and what would have to be true about their architecture for Standard Tier to become correct?

**Q6.3** — A manufacturer moves 400 TB/month between an on-prem ERP and BigQuery. They currently use HA VPN. Give the two independent reasons Dedicated Interconnect wins here, one performance and one financial.

**Q6.4** — When does an **internal passthrough** Network Load Balancer beat an **internal Application** Load Balancer, given the Application LB has strictly more features?

**Sources:** <https://cloud.google.com/network-tiers/docs/overview> · <https://cloud.google.com/load-balancing/docs/load-balancing-overview> · <https://cloud.google.com/network-connectivity/docs/interconnect> · <https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview>

---

## Exercise 7 — When the datacenter cannot fully leave: GCVE, GDC, and specialised hardware

**Objective:** the exam includes scenarios where "migrate to Compute Engine" is the wrong answer — sovereignty, latency to a factory floor, an unmovable licensed appliance, or a fixed nine-month datacenter exit.

### Steps

1. Map the four escape hatches before you need them:

| Offering | What it is | Runs where | Primary business driver |
|---|---|---|---|
| **Google Cloud VMware Engine (GCVE)** | Managed VMware stack (vSphere, vSAN, NSX, HCX) on dedicated nodes | Google region | Datacenter exit on a deadline with **zero application refactoring**; retains VMware tooling and skills |
| **Sole-tenant nodes** | Physical host dedicated to one customer's VMs | Google region | Per-physical-core licensing; physical isolation for compliance |
| **Google Distributed Cloud (connected)** | Google-managed hardware/software running in *your* datacenter or at the edge, linked to Google Cloud | Customer premises / edge | Data-gravity, low-latency-to-machinery, local processing with cloud control plane |
| **Google Distributed Cloud (air-gapped)** | Full stack with **no** connection to Google Cloud | Customer premises | Sovereignty, classified workloads, jurisdictions that forbid any egress |

2. Check the region availability for GCVE — hybrid offerings are far more region-constrained than core compute, which frequently reverses a migration plan:

```bash
gcloud vmware private-clouds list --location="$REGION-a" 2>&1 | head -3
```

```
Listed 0 items.
```

```bash
gcloud vmware locations list --format="table(name.basename())" 2>&1 | head -10
```

3. Reason about the **shared responsibility shift**. For each offering, write down who patches the hypervisor and who patches the guest OS:

```
Compute Engine     → Google: hypervisor + host.  Customer: guest OS, apps.
GCVE               → Google: hardware + ESXi/vSAN/NSX lifecycle.  Customer: VMs, guest OS, apps.
GDC (connected)    → Google: platform software lifecycle.  Customer: physical security, power, workloads.
GDC (air-gapped)   → Customer: everything Google cannot reach — including update delivery.
```

4. Note the database special case. Oracle workloads have historically been the single largest blocker to datacenter exit. The current path is **Oracle Database@Google Cloud** — Oracle Exadata infrastructure physically located in Google Cloud datacenters with a low-latency interconnect to your VPC. If a scenario mentions a legacy Oracle estate, this is the modern answer; verify the current product and region list at <https://cloud.google.com/oracle/database/docs> before quoting availability, and check the status of the older Bare Metal Solution offering in the same docs rather than assuming it.

### Verification questions

**Q7.1** — A European insurer must exit two datacenters in 11 months. It runs 1,400 VMware VMs, has a vSphere-trained operations team, and no application source code for a third of the estate. Rank GCVE, Compute Engine (rehost), and refactoring-to-GKE, and defend the ranking with the *time-to-value* argument.

**Q7.2** — Contrast GDC connected and GDC air-gapped along a single axis: what capability does the air-gapped variant *lose*, and which customers accept that loss deliberately?

**Q7.3** — A car plant needs sub-10ms inference on a vision model watching a production line, and it must keep operating through a WAN outage. Which offering, and which two words in the requirement decided it?

**Q7.4** — GCVE nodes are billed per node/hour with a minimum cluster size, versus Compute Engine's per-second billing. Why is the *less* granular billing model sometimes the one a CFO prefers?

**Sources:** <https://cloud.google.com/vmware-engine/docs/overview> · <https://cloud.google.com/distributed-cloud/docs> · <https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes> · <https://cloud.google.com/oracle/database/docs>

---

## Exercise 8 — Migration path and the assessment that precedes it

**Objective:** infrastructure offerings are chosen during an assessment, not during a design workshop. The exam expects you to know the migration phases and which tool serves each.

### Steps

1. Learn the four phases Google names, and what each produces:

```
Assess    → inventory, dependency map, TCO comparison   → Migration Center
Plan      → landing zone, IAM, network, org policy      → Cloud Foundation / landing zone
Deploy    → move workloads                              → Migrate to Virtual Machines,
                                                          Database Migration Service,
                                                          Storage Transfer Service,
                                                          Transfer Appliance
Optimize  → right-size, commit, modernize               → Active Assist, CUDs, refactor
```

2. Map the migration *strategies* onto the offerings from Exercises 2 and 7:

| Strategy | Meaning | Lands on | Effort | Cloud benefit realised |
|---|---|---|---|---|
| Rehost ("lift and shift") | Move VM as-is | Compute Engine, GCVE | Lowest | Lowest |
| Replatform ("move and improve") | Swap components for managed services | Compute Engine + Cloud SQL, GKE | Medium | Medium |
| Refactor / re-architect | Rewrite for cloud-native | Cloud Run, GKE Autopilot, BigQuery | Highest | Highest |
| Repurchase | Replace with SaaS | Google Workspace, third-party SaaS | Low | Varies |
| Retire | Delete | — | Lowest | Immediate |
| Retain | Leave in place, revisit | — | None | None |

3. Inspect the assessment surface without running a full discovery:

```bash
gcloud migration-center groups list --location="$REGION" 2>&1 | head -3
gcloud migration-center assets list --location="$REGION" \
  --format="table(name.basename(), assetType, updateTime)" 2>&1 | head -5
```

```
Listed 0 items.
```

An empty inventory is the correct starting state — and the correct thing to point at when someone proposes a migration wave without discovery data.

4. Compute the availability side of the business case. Google's Compute Engine SLA is **99.99%** for instances distributed across multiple zones in a region running the same workload, and **99.9%** for a single instance with the required disk types. Convert to error budget:

```
Monthly minutes = 43,800
99.9%   → 43.80 minutes of allowed downtime per month  (~8h 46m per year)
99.95%  → 21.90 minutes per month                      (~4h 23m per year)
99.99%  →  4.38 minutes per month                      (~52m 34s per year)
```

5. Turn that into money. An e-commerce platform books USD 240,000/hour of gross revenue during peak:

```
Single-zone (99.9%)   : 8.76 h/yr × 240,000 = $2,102,400 expected annual revenue at risk
Multi-zone  (99.99%)  : 0.88 h/yr × 240,000 =   $211,200
                                              -----------
Value of the multi-zone design               = $1,891,200 / year
```

Compare that to the incremental cost of running across three zones — typically a load balancer, cross-zone traffic, and idle capacity headroom. **This calculation is the entire business-value argument for regional architecture**, and it is the shape of answer the exam rewards.

6. Build the regional, self-healing infrastructure that earns the 99.99% figure. Complete, valid Terraform:

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region"     { type = string  default = "us-central1" }

resource "google_compute_health_check" "web" {
  name                = "web-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/healthz"
  }
}

resource "google_compute_instance_template" "web" {
  name_prefix  = "web-"
  machine_type = "n4-standard-4"
  region       = var.region

  disk {
    source_image = "projects/debian-cloud/global/images/family/debian-12"
    auto_delete  = true
    boot         = true
    disk_type    = "hyperdisk-balanced"
    disk_size_gb = 50
  }

  network_interface {
    network = "default"
  }

  scheduling {
    provisioning_model  = "STANDARD"
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
  }

  labels = {
    cost-center = "retail-web"
    env         = "prod"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "web" {
  name                      = "web-mig"
  region                    = var.region
  base_instance_name        = "web"
  distribution_policy_zones = ["us-central1-a", "us-central1-b", "us-central1-c"]

  version {
    instance_template = google_compute_instance_template.web.id
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.web.id
    initial_delay_sec = 120
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }
}

resource "google_compute_region_autoscaler" "web" {
  name   = "web-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.web.id

  autoscaling_policy {
    min_replicas    = 3
    max_replicas    = 30
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}
```

Three design details carry the SLA: `distribution_policy_zones` (spread across failure domains), `auto_healing_policies` (recreate on health-check failure, not just on VM crash), and `max_unavailable_fixed = 0` with `max_surge_fixed = 3` (rolling update never dips below capacity).

7. **Do not `terraform apply`** unless you intend to pay for three `n4-standard-4` VMs. `terraform validate` and `terraform plan` are free and prove the manifest:

```bash
terraform init -backend=false && terraform validate
```

```
Success! The configuration is valid.
```

### Verification questions

**Q8.1** — In step 6, `max_unavailable_fixed = 0` and `max_surge_fixed = 3`. Explain the availability guarantee this pair encodes during a rolling update, and what would break if you set `max_surge_fixed = 0` instead.

**Q8.2** — The SLA math in step 5 assumed multi-zone deployment yields 99.99%. Name two design mistakes that would leave a customer paying for three zones while still holding a 99.9% (or worse) *effective* availability.

**Q8.3** — A CIO wants to "rehost everything, then modernize later." State the strongest argument **for** and the strongest argument **against**, and give the condition that decides between them.

**Q8.4** — Why does Google's SLA credit structure (service credits, not cash) make the revenue-at-risk calculation in step 5 the *only* honest way to price availability?

**Q8.5** — Migration Center's discovery produces a dependency map. Name the specific migration failure it exists to prevent.

**Sources:** <https://cloud.google.com/migration-center/docs/migration-center-overview> · <https://cloud.google.com/migrate/virtual-machines/docs> · <https://cloud.google.com/compute/sla> · <https://cloud.google.com/architecture/framework/reliability>

---

## Exercise 9 — Assemble the board-level narrative

**Objective:** the final skill this objective tests is translation — from `n2-standard-8` to a sentence an executive committee can vote on.

### Steps

1. Pull the four numbers you now know how to produce, for a hypothetical 400-VM datacenter exit:

```
(a) Infrastructure run-rate, on-demand           Exercise 4, step 4
(b) Infrastructure run-rate, blended commitments Exercise 4, step 5
(c) Storage cost, flat vs lifecycle-tiered       Exercise 5, step 5
(d) Revenue at risk, single-zone vs multi-zone   Exercise 8, step 5
```

2. Write the five-line summary. Each line must be traceable to a command you ran:

```
1. CAPEX ELIMINATION   — no hardware refresh cycle; datacenter lease exits in month 11.
2. RUN-RATE            — blended commitment model lands 48.5% under on-demand list
                         (3-yr CUD baseline + SUD burst + Spot batch).
3. DATA COST CURVE     — lifecycle tiering cuts archive storage 71% with no
                         application change.
4. AVAILABILITY        — regional MIG raises the SLA floor from 99.9% to 99.99%,
                         removing ~$1.89M/yr of expected revenue at risk.
5. OPTIONALITY         — the same platform hosts VMware (GCVE), containers (GKE),
                         and serverless (Cloud Run); modernization becomes incremental,
                         not a second migration.
```

3. Identify the three claims in that summary an auditor could falsify, and the evidence for each:

```
Claim 2 → Billing Catalog API export + signed commitment records (`gcloud compute commitments list`)
Claim 3 → Storage Insights / bucket lifecycle config + billing export by storage class
Claim 4 → Compute Engine SLA text + MIG distribution_policy_zones in the Terraform state
```

4. Confirm you have no stray billable resources from any exercise:

```bash
gcloud compute instances list --format="table(name, zone.basename(), status)"
gcloud compute disks list     --format="table(name, zone.basename(), sizeGb)"
gcloud compute addresses list --format="table(name, region.basename(), status)"
gcloud run services list      --format="table(metadata.name, region)"
gcloud storage buckets list   --filter="name~cdl-42" --format="value(name)"
```

Every command must return `Listed 0 items.` before you close the lab.

### Verification questions

**Q9.1** — Line 1 says "CAPEX elimination." A CFO objects that a 3-year committed use discount is economically a capital commitment. Is the objection correct? Answer precisely.

**Q9.2** — Line 5 claims "optionality." What is the counter-argument a sceptical board member should raise, and what is the honest response?

**Q9.3** — Of the five lines, which one is the *weakest* business case on its own, and why do infrastructure proposals nonetheless lead with it?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** — A **budget alert** is observational: it sends notifications at thresholds and never blocks an API call, so spend continues past 100%. A **quota** is a hard technical ceiling on resource count or rate (e.g. vCPUs per region) and *is* the only true cap — an over-quota request fails with `QUOTA_EXCEEDED`. A **committed use discount** is neither a cap nor an alert; it is a purchase obligation that lowers the *rate* while guaranteeing Google a minimum spend, so it can only ever raise your floor, never lower your ceiling. The exam-relevant framing: budgets give visibility, quotas give control, CUDs give price. Cost control requires all three; customers who buy only the CUD are surprised twice.

**A0.2** — Both **resource price** and **data transfer price** are region-dependent. The same `n2-standard-8` costs materially more in `southamerica-east1` or `asia-northeast1` than in `us-central1`, and internet egress pricing varies by both source region and destination continent. A third, often-missed component is **cross-region replication** for multi-region storage. So "what does this cost?" is unanswerable without a region, and a TCO built in `us-central1` and executed in `europe-west3` is simply wrong.

### Exercise 1

**A1.1** — A **region with multiple zones** (e.g. `europe-west3` with `-a/-b/-c`) satisfies both: the residency boundary is the single member state, and the zones are independent failure domains — separate power, cooling, and network within the region, so losing one building does not lose the service. A **multi-region** location (e.g. `EU`) satisfies neither cleanly for this requirement: it sounds safer because it spans a wider geography, but it replicates data across *multiple countries* inside the EU, which violates the single-member-state residency rule. The lesson: broader geographic scope is not automatically better — residency is a constraint that narrows, availability is a constraint that widens, and they conflict.

**A1.2** — A regional MIG spreads instances across the zones you list. If your instance template pins `minCpuPlatform: "Intel Emerald Rapids"` and one of the zones does not offer that platform, instance creation in that zone fails with a resource error. In practice this manifests as a MIG that reports the wrong size, an autoscaler that cannot scale out during a traffic peak, or an auto-heal that never replaces a failed VM. The business consequence: you paid for a three-zone design, you documented a 99.99% SLA, and under load you are actually running in two zones with reduced capacity — an availability regression that only appears during the incident it was supposed to prevent.

**A1.3** — (1) **Predictable performance without a negotiated contract.** Inter-region traffic stays on privately owned fibre rather than transiting third-party networks, so latency and packet loss are engineering properties Google controls, not a supplier's SLA you renegotiate annually. (2) **The cost of global reach is already in the unit price.** Reaching a new geography does not require a new carrier contract, a new colo, or a capital project — it is a region flag on a deploy. The CFO framing for both: converts an unpredictable, contract-driven, capital-intensive network expansion into a variable operating cost with no procurement cycle.

**A1.4** — It is defensible when (a) latency to the primary user population is a **stated, measurable requirement** with revenue attached, or data residency law forbids the alternative; (b) the carbon delta is **quantified and reported** rather than ignored — Carbon Footprint export to BigQuery makes the number auditable; and (c) the decision is **recorded with an owner and a review date**, so it is revisited when regional CFE% improves. What is *not* defensible is choosing the higher-carbon region without measuring the delta. The exam's framing of sustainability is transparency and accountability, not an absolute rule that the greenest region always wins.

### Exercise 2

**A2.1** — `minScale: "1"` keeps one instance warm permanently. The customer **buys** the elimination of cold-start latency on the first request after an idle period — for a payments API this is the difference between a 40ms and a 2,000ms p99 for the unlucky user. The customer **stops getting** scale-to-zero, which is Cloud Run's single largest cost advantage: the service now bills continuously, 730 hours a month, whether or not anyone calls it. The trade-off is exactly "predictable latency versus zero idle cost," and the correct answer depends on whether the traffic pattern has idle periods long enough for instances to be reclaimed.

**A2.2** — **Autopilot punishes it directly**: you are billed for the requested 3×, so the waste appears as a line item on the bill the day it is deployed. **GKE Standard hides it**: you pay for nodes, so over-requesting shows up only as poor bin-packing — the cluster needs more nodes than the actual workload justifies, and the cost looks like "we need a bigger cluster" rather than "our requests are wrong." The FinOps implication is that Autopilot makes resource requests a *financial* signal, which aligns the developer who writes the manifest with the person who pays the bill. On Standard, closing that loop requires separate tooling (cost allocation by namespace, VPA recommendations) because the billing model will not do it for you.

**A2.3** — Ranking: **(1) Compute Engine or GCVE (rehost), (2) GKE Standard, (3) Cloud Run/Autopilot — effectively excluded.** The kernel-access driver rules out every managed-container and serverless rung, because those run your code in a container on a host you do not control; GKE Autopilot forbids privileged pods outright. Business justification: *the nine-month deadline and the kernel dependency mean the only options that finish on time are ones that move the machine, not the application — rehosting to Compute Engine (or GCVE if the estate is VMware) removes the datacenter without touching the software, and modernization becomes a separate, optional decision made later from a position of safety.*

**A2.4** — On Cloud Run you are billed for **allocated CPU and memory per instance-second** (plus requests), so the `cpu`/`memory` values are literally the price multiplier — halving them halves the compute portion of the bill. On GKE Standard you are billed for the **nodes**, which exist whether or not pods are scheduled on them; a pod's `requests` affect only *scheduling*, i.e. how many pods fit per node. Lowering requests therefore reduces cost on GKE Standard only *indirectly and only if* the improved density lets the cluster autoscaler remove nodes. This is the sharpest illustration of the abstraction-ladder trade: on higher rungs, resource declarations are a price; on lower rungs, they are a hint.

### Exercise 3

**A3.1** — The number: the custom shape is ~6/8 of the vCPU and ~20/32 of the RAM of `n2-standard-8`, so roughly **30% cheaper** than the nearest fitting predefined type, with no performance loss for a workload measured at 6/20. The sentence: *you pay for the workload's actual shape instead of rounding up to the vendor's catalog.* Custom is the **wrong** choice when (a) you want committed use discounts under a simple, auditable commitment model and standard shapes make the commitment easier to reason about, or more importantly (b) the family does not support custom shapes at all — the newer families (C3, C4, N4 and the accelerator/storage-optimized families) are predefined-only, so a custom-shape strategy quietly locks you onto older generations. A third, softer case: fleet-wide standardisation is worth more than per-VM optimisation when you have thousands of VMs and a small platform team.

**A3.2** — Workloads that **must** use `TERMINATE`: VMs with attached GPUs or TPUs in configurations that do not support migration, Spot/preemptible VMs (forced), and some sole-tenant and confidential-computing configurations. Their compensating architecture is **checkpointing plus orchestration**: the work must be resumable, and a MIG, Batch, or Kubernetes controller must recreate the instance and resume from the last checkpoint. The business value of `MIGRATE` as the default is that **Google's datacenter maintenance is invisible to the customer** — no maintenance windows to negotiate with the business, no change-advisory-board tickets for host patching, no application-level HA required just to survive routine infrastructure work. In on-premises terms, it removes an entire recurring operational ritual.

**A3.3** — Per-physical-core licensing charges for the cores of the *host*, not the vCPUs of the guest. On shared-tenancy Compute Engine you cannot see or bound the physical host, so a strict auditor may require licensing the entire estate the VM could theoretically land on — an unbounded and unbudgetable exposure. A **sole-tenant node** gives you a known physical host with a known core count, and node affinity pins your VMs to it. You now license *that node's* cores, a fixed, provable number, and you can pack many VMs onto it. The arithmetic that matters: if the license costs more per core than the infrastructure, the optimisation target flips from "minimise vCPU-hours" to "maximise VMs per licensed physical core," and the more expensive node SKU wins on total cost. This is also why sole-tenant nodes support **bring-your-own-license** scenarios that shared tenancy cannot.

**A3.4** — Because the individual recommendation is a symptom, and the aggregate is a **management signal**. One VM's $71/month is noise. But a project-wide or org-wide Recommender export tells you: how much of your fleet is systematically over-provisioned, which teams over-provision, whether the pattern is worsening, and whether your provisioning defaults (templates, Terraform modules, golden images) are wrong at the source. Fixing the default fixes every future VM; fixing one VM fixes one VM. The business value of Active Assist is therefore **continuous, automated waste detection built into the platform** rather than a quarterly consulting exercise — and its output is a governance input, not just a savings line.

### Exercise 4

**A4.1** — Google gave those families **lower on-demand list prices** and steered customers to **flexible (spend-based) CUDs**. For a mature FinOps practice this is better because SUD is a *passive* discount you cannot plan around — it depends on how many hours each VM happened to run in a calendar month, it resets monthly, and it cannot be forecast into a budget with confidence. A flexible CUD is an explicit, portable, forecastable instrument: you commit to an hourly spend, you know the discount percentage, and the discount follows your architecture as it changes. Trading an unpredictable automatic discount for a predictable purchased one is the right trade for anyone who does capacity planning; it is a worse trade for a small customer with bursty, unplanned usage, which is why the lower on-demand base price exists to compensate.

**A4.2** — A resource-based CUD is **bound to a region and a machine family** and continues to bill for its full term whether or not you use it. Moving to C4 in `europe-west4` leaves you paying for unused N2 capacity in `us-central1` for the remaining two years — the classic commitment stranding. Mitigations in order of preference: (1) buy a **flexible/spend-based CUD**, which is portable across families, regions and several services and would have survived the re-platform intact; (2) if resource-based commitments are already held, some can be **modified or transferred within a billing account** — check the current rules before assuming; (3) match commitment *term* to architectural confidence — 3 years is appropriate for a stable estate, 1 year for one under active modernization. The general principle: **the discount depth you buy should not exceed the architectural certainty you have.**

**A4.3** — *Financial:* a 3-year commitment is an obligation to pay regardless of usage. Committing 100% converts every future efficiency gain — right-sizing, refactoring to Cloud Run, retiring a service, a business downturn — into stranded cost, because the savings you engineer are already paid for. You would be buying a 55% discount on capacity you intend to stop using. *Architectural:* the fleet is not one thing. Baseline capacity that runs 24/7 for three years is genuinely commitment-shaped; burst capacity is not (it is idle most of the month, so a commitment covers nothing); and fault-tolerant batch is Spot-shaped, where the discount is deeper than any commitment and requires no obligation at all. The correct posture is to **commit to the floor, not the peak** — typically the P50–P70 of steady-state usage — and let the levers above the floor stay elastic. That is why the blended model lands at 48.5% real savings and is *safer* than the 55% headline.

**A4.4** — **Batch simulation → Spot VMs.** The justifying property is not "it's a batch job," it is **checkpointing every 5 minutes with a ~30-second preemption notice**: the maximum work lost to an eviction is bounded and small, and the job has no external availability commitment. Deadline slack matters too — a 6-hour job in an overnight window tolerates re-scheduling. **Payments API → committed use discount (plus on-demand headroom).** The justifying property is that it is customer-facing with an availability commitment, so it must never be evicted; and it runs continuously at a predictable floor, which is exactly the usage shape a commitment prices well. Note the symmetry: Spot's discount is compensation for accepting eviction risk, and the payments API is precisely the workload that cannot accept it at any price.

**A4.5** — **Bursty, short-lived, high-parallelism workloads** — CI/CD build farms, per-commit test runners, ephemeral rendering or transcoding jobs, ad-hoc data processing. If a build takes 4 minutes and you run 500 a day, per-hour billing would charge you 500 hours for 33 hours of work: a 15× overcharge that **no discount percentage can recover**, because the waste is in the billing granularity, not the rate. Per-second billing with a 60-second minimum makes "spin up 200 VMs for three minutes" economically rational, which in turn makes a *different architecture* affordable — massive short-lived parallelism instead of a small always-on cluster with a queue. Granularity does not just reduce a bill; it unlocks a design.

### Exercise 5

**A5.1** — The three mechanisms: (1) **Minimum storage duration** — Archive objects are billed for 365 days even if deleted on day 2, as an early-delete charge. (2) **Retrieval fees** — roughly $0.05/GB, charged every time you read, against Standard's zero. (3) **Operation (Class A/B) charges**, which dominate when object counts are high and object sizes are small. The scenario where tiering *increases* the bill: a compliance archive of many small objects that a quarterly audit tool scans in full. At 100 TB, a single full read costs ~$5,120 in retrieval alone; four scans a year exceed the entire annual Standard-class storage cost you were trying to avoid. **Storage class is a bet on access frequency, and a wrong bet is more expensive than never having tiered at all.** Note also that all classes share the same ~11-nines design durability and the same millisecond-latency access path — the tiers differ on *cost of access*, not on speed or safety, which is the single most commonly mis-stated fact about Cloud Storage.

**A5.2** — *"You buy the performance the database needs without buying the capacity it doesn't."* Under the Persistent Disk model, IOPS scales with provisioned size, so reaching 60,000 IOPS forces you to provision terabytes of disk for a 200 GB dataset — you pay for capacity purely as a means of purchasing performance. Hyperdisk lets you provision 200 GB of capacity and 60,000 IOPS as independent, separately-billed dimensions. The business framing: it removes a structural over-provisioning tax on exactly the workloads that are most performance-sensitive and least capacity-hungry — transactional databases.

**A5.3** — Local SSD is for **ephemeral, latency-critical, reconstructible data**: scratch space, temp files, shuffle/spill space for analytics engines, and caches. It is physically attached to the host, so it delivers the lowest latency and highest IOPS available, and it does not survive instance stop, host migration, or termination. What its existence tells you: Compute Engine storage is meant to be **composed by durability requirement, not chosen once**. A well-built VM commonly uses a Persistent Disk or Hyperdisk boot volume (durable, survives the instance), Hyperdisk for the data set (durable, provisioned performance), and Local SSD for scratch (fast, disposable). Putting durable data on Local SSD to "make it fast" is the classic failure; the correct move is to place each dataset on the tier matching *how bad it is to lose it*.

**A5.4** — What breaks: **POSIX semantics**. Cloud Storage is an object store with a flat namespace, no true directories, no file locking, no partial in-place writes, and no `open()`/`seek()`/`write()` — objects are replaced atomically in whole. Applications expecting a mounted filesystem (legacy apps, shared home directories, media editing, many rendering and HPC pipelines, anything using file locks) either fail or perform catastrophically. FUSE-based adapters exist but do not restore locking or POSIX write semantics, and they add latency. The correct decision criterion: **choose by access protocol and consistency semantics required by the application, not by price per GB.** If the application needs a filesystem, Filestore (or NetApp Volumes for enterprise features) is the answer and the per-GB premium is the price of the protocol. If the application can be changed to speak object APIs, the refactor is often worth it — but that is a *refactor* decision, not a storage-substitution decision.

### Exercise 6

**A6.1** — Cold-potato routing means Google carries the traffic on **its own backbone for as long as possible**, handing it off to the public internet at the edge location closest to the *user*. Hot-potato routing (Standard Tier, and typical of transit-cost-minimising networks) does the opposite: it dumps traffic onto the public internet at the edge closest to the *source*, letting someone else's network carry it the rest of the way. It is a product decision because Google is choosing to spend its own backbone capacity — a real cost — to control latency, jitter and packet loss end-to-end, and it prices Premium Tier accordingly. The customer's side of the trade: Premium's higher per-GB price is the cost of the performance staying an engineering property rather than an internet-weather property.

**A6.2** — The constraint is that **Standard Tier cannot use global external IPs or global load balancing** — it is regional only. With one region and 30 countries of players, Standard Tier means every player's traffic exits at the source region and crosses the public internet the whole way, and you cannot present a single anycast IP served from the nearest edge. For latency-sensitive gaming that is a direct product-quality regression, and 23% off egress will not compensate for churn. Standard Tier becomes correct when the architecture is **already regional and the users are local to that region** — for example, a domestic-only service, an internal or batch workload, a data-export pipeline to a known endpoint, or a dev/test environment. The rule of thumb: Standard Tier is right when you were never going to use the global edge anyway.

**A6.3** — *Performance:* 400 TB/month is ~1.2 Gbps sustained average, with peaks far higher during ERP batch windows. HA VPN tunnels top out around 3 Gbps each and run over the public internet, so throughput is capped and — more importantly — **jitter and packet loss are outside your control**, which is exactly what destroys large sustained transfers. Dedicated Interconnect provides 10 or 100 Gbps circuits on a private path with a deterministic profile. *Financial:* egress over Interconnect is billed at a **substantially lower per-GB rate than internet egress**, so at 400 TB/month the data-transfer saving alone typically eclipses the circuit's fixed port charge. The general shape: VPN is cheap to start and expensive at volume; Interconnect has a fixed floor and a much lower marginal rate, and the crossover comes far below 400 TB.

**A6.4** — When you need any of: **client IP preservation** (the passthrough LB does not terminate the connection, so backends see the real source address — required for IP allowlists, geolocation, audit logging and some licensing), **non-HTTP protocols** including UDP and arbitrary IP protocols, **very low latency** (no proxy hop, no connection termination), or **it to act as a next hop / default gateway** for network virtual appliance insertion and custom routing. The Application LB has more features precisely *because* it terminates and re-originates connections — and that termination is the thing you are trying to avoid. More features is not more suitable; the feature set you want here is the empty set plus wire fidelity.

### Exercise 7

**A7.1** — Ranking: **(1) GCVE, (2) Compute Engine rehost, (3) refactor to GKE.** GCVE wins on time-to-value: the VMs move as VMs into a vSphere environment the existing team already operates, using HCX for bulk migration, so the datacenter exit is a *migration project* rather than 1,400 individual application projects. Compute Engine rehost is second — technically feasible and cheaper per unit, but each VM requires guest-OS driver work, re-IPing, and per-application validation, and the third of the estate with no source code is exactly where that validation is riskiest. Refactoring is last and, at 11 months for 1,400 VMs, is not a plan: you cannot refactor applications you have no source for. The time-to-value argument in business language: *the deadline is fixed and external (the lease), so the correct strategy is the one that decouples "leave the datacenter" from "modernize the applications" — GCVE does that completely, and modernization then proceeds application by application, funded by its own business case, with no deadline attached.*

**A7.2** — The air-gapped variant **loses the connection to Google Cloud's control plane** — and therefore loses cloud-side management, telemetry flowing to Google, automatic updates delivered over the network, and access to the Google Cloud service catalog. Everything must be operated, updated and monitored locally, with updates delivered through a physical or controlled process. Customers who accept this deliberately: defence and intelligence, classified government workloads, some critical national infrastructure, and jurisdictions whose law forbids *any* data or metadata leaving national control — including operational telemetry, which is the detail that rules out the connected variant for them. They are not choosing air-gapped because they distrust the cloud; they are choosing it because the regulation is written about connectivity itself.

**A7.3** — **Google Distributed Cloud (connected), at the edge.** The two deciding words are **"sub-10ms"** and **"through a WAN outage."** Sub-10ms to a region is physically impossible for most plant locations — speed of light plus network hops sets a floor — so the compute must be on the factory floor. "Through a WAN outage" means the inference must keep running with no link to Google Cloud, which excludes any architecture where the control plane or the model-serving path crosses the WAN. GDC connected gives local execution with a cloud-managed lifecycle when the link is up. Note that either requirement alone would have been enough; together they leave no alternative.

**A7.4** — Because **predictability often beats optimality in a budget cycle.** A per-node/hour model with a minimum cluster size produces a run-rate the CFO can forecast to the dollar twelve months out, put in a plan, and compare against the datacenter cost it replaces. Per-second billing is cheaper in aggregate but produces a variable monthly figure that moves with engineering behaviour, making variance an ongoing conversation. There is a second, subtler reason: a fixed-capacity cluster **caps the downside** — no engineer can accidentally 10× the bill overnight. Elastic billing's greatest strength and its greatest governance weakness are the same property. Mature organisations reconcile this with budgets, quotas and commitments; organisations early in their cloud journey often prefer the model that cannot surprise them.

### Exercise 8

**A8.1** — `max_unavailable_fixed = 0` means the MIG may never drop below its target size during an update; `max_surge_fixed = 3` means it may temporarily create up to three *extra* instances. Together they encode **full capacity throughout the rolling update**: new instances are created and pass health checks *before* old ones are removed, so at no point is serving capacity reduced. If you set `max_surge_fixed = 0`, the MIG has no room to add instances first, so with `max_unavailable = 0` it could not make progress at all — and in the configuration where you also allow unavailability, it would have to **delete before creating**, running the update at reduced capacity. During a traffic peak that is a self-inflicted partial outage. The cost of the safe setting is the three extra instance-hours per update; the cost of the unsafe one is measured in the incident report.

**A8.2** — (1) **A zonal dependency underneath a regional compute tier** — the classic case is a zonal database, a zonal Persistent Disk, a zonal Filestore instance, or a single-zone NFS mount that all three zones' VMs depend on. The compute is regional; the availability is still zonal, because the weakest component sets the floor. (2) **No health-check-driven auto-healing, or a health check that only tests liveness of the VM rather than the application.** A VM that is `RUNNING` but serving 500s is counted as healthy, never replaced, and continues receiving traffic — you have three zones of instances and no mechanism that notices one third of them is broken. A third common one worth naming: **insufficient capacity headroom** — running exactly at capacity across three zones means losing one zone drops you to 67% and the service degrades even though nothing "failed."

**A8.3** — *For:* it collapses two risky projects into one, hits the datacenter deadline, stops the hardware refresh spend immediately, and moves the estate onto a platform where modernization can then happen incrementally and be funded per-application. Rehosting is the only strategy whose timeline you can actually predict. *Against:* rehosting realises the least cloud benefit — you are running the same architecture with the same inefficiencies at cloud prices, which for some workloads is *more* expensive than the datacenter was, and "modernize later" is a promise that competes with every feature request thereafter. Organisations that rehost without a funded follow-through end up with a more expensive datacenter and none of the agility. *The deciding condition:* **is there an external, dated forcing function?** If the lease expires, the hardware is end-of-support, or the datacenter is closing, rehost — the deadline dominates and you optimize afterwards. If there is no deadline, the migration is discretionary and you should replatform or refactor the workloads where the business case is strongest, and retire or retain the rest.

**A8.4** — Because service credits **do not compensate the business loss**. A 99.9% miss earns a percentage credit against the Compute Engine bill for that month — a figure denominated in your infrastructure spend, which is typically a small fraction of the revenue the outage cost. In the worked example, 8.76 hours of annual downtime represents $2.1M of revenue at risk, while the SLA credit against a ~$28k/month compute bill is at most a few thousand dollars. Treating the SLA credit as the value of availability therefore understates it by two or three orders of magnitude. The honest method is to price availability from **the business impact of downtime**, and treat the SLA as a *specification of what the platform commits to* — the input to your architecture decision — rather than as insurance. This is also why multi-zone architecture is justified on revenue protection, not on SLA credits.

**A8.5** — It exists to prevent **migrating a workload without its dependencies** — moving an application server while leaving behind a database, a licence server, a file share, an LDAP/AD dependency, a hard-coded IP, or a batch job that writes to it nightly. The failure mode is characteristic: the migration succeeds, smoke tests pass, and the application breaks days later at month-end or when an undiscovered upstream system tries to reach the old address. Discovery-based dependency mapping turns migration waves from "which VMs are easy" into "which VMs form a complete, movable unit," which is the difference between a wave that cuts over cleanly and one that requires a rollback.

### Exercise 9

**A9.1** — The objection is **partially correct, and the distinction matters**. A 3-year CUD is a contractual spend obligation, so from a cash-commitment standpoint it does resemble a capital commitment: you owe the money whether or not you use the capacity. What it is *not* is capital expenditure in the accounting sense — there is no depreciating asset on the balance sheet, no residual value to manage, no disposal, and (depending on the accounting treatment your controller applies) it is generally recognised as operating expense over the term. The genuine differences that survive the objection: the commitment is **partial** (you commit to the baseline, not the whole estate), it is **denominated in spend rather than in hardware** so it does not lock you to a specific machine, and it carries **no technology risk** — a committed dollar can buy next year's machine family, whereas a purchased server cannot become a newer server. The precise honest answer to the CFO: *"You're right that it's a commitment. It is not a capital asset, it covers only our steady-state floor, and unlike hardware it does not obsolete."*

**A9.2** — The counter-argument: **"optionality" is the word people use when they have not decided anything.** Every migration deck promises incremental modernization, and most estates rehost and stop; the platform's *capability* to run containers and serverless creates no value unless someone funds the work, and meanwhile you carry the cost of the more expensive rehosted architecture. The honest response is to convert optionality into commitments: name the first two or three workloads to modernize, attach a business case and a date to each, assign an owner, and put the modernization budget in the same plan as the migration budget. Optionality that is not exercised is just an unused feature — the defensible claim is not "we could modernize," it is "we will modernize these workloads, on this schedule, for this return, and the platform is why we can."

**A9.3** — **Line 1 (CAPEX elimination) is the weakest on its own.** Avoiding a hardware refresh is a one-time timing benefit, and the cost simply reappears as operating expense — often at similar or higher total cost for a rehosted estate. It says nothing about whether the business runs better afterwards. The strongest lines are 2 and 4, because they are recurring and measurable: a 48.5% run-rate reduction compounds every month, and $1.89M/year of removed revenue risk is a number the business already understands. Infrastructure proposals nonetheless lead with line 1 because it is the **easiest number to agree on** — the hardware refresh quote is a real invoice with a real date, it requires no modelling assumptions, and it maps to a budget line the finance team already tracks. It is a good opening and a bad case. The disciplined version of this slide leads with CAPEX to establish the trigger, then spends the rest of its time on run-rate and availability, which is where the durable value actually is.

</details>

---

### Consolidated sources

- Cloud Digital Leader exam guide — <https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf>
- Geography and regions — <https://cloud.google.com/docs/geography-and-regions>
- Regions and zones (Compute Engine) — <https://cloud.google.com/compute/docs/regions-zones>
- Machine families resource guide — <https://cloud.google.com/compute/docs/machine-resource>
- Live migration — <https://cloud.google.com/compute/docs/instances/live-migration-process>
- Sole-tenant nodes — <https://cloud.google.com/compute/docs/nodes/sole-tenant-nodes>
- Sustained use discounts — <https://cloud.google.com/compute/docs/sustained-use-discounts>
- Committed use discounts — <https://cloud.google.com/docs/cuds>
- Spot VMs — <https://cloud.google.com/compute/docs/instances/spot>
- Cloud Billing Catalog API — <https://cloud.google.com/billing/docs/how-to/catalog-api>
- Storage classes — <https://cloud.google.com/storage/docs/storage-classes>
- Object lifecycle management — <https://cloud.google.com/storage/docs/lifecycle>
- Block storage options — <https://cloud.google.com/compute/docs/disks>
- Filestore service tiers — <https://cloud.google.com/filestore/docs/service-tiers>
- Network service tiers — <https://cloud.google.com/network-tiers/docs/overview>
- Cloud Load Balancing overview — <https://cloud.google.com/load-balancing/docs/load-balancing-overview>
- Cloud Interconnect — <https://cloud.google.com/network-connectivity/docs/interconnect>
- Cloud VPN — <https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview>
- Cloud Run — <https://cloud.google.com/run/docs/overview/what-is-cloud-run>
- GKE Autopilot — <https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview>
- Google Cloud VMware Engine — <https://cloud.google.com/vmware-engine/docs/overview>
- Google Distributed Cloud — <https://cloud.google.com/distributed-cloud/docs>
- Oracle Database@Google Cloud — <https://cloud.google.com/oracle/database/docs>
- Migration Center — <https://cloud.google.com/migration-center/docs/migration-center-overview>
- Migrate to Virtual Machines — <https://cloud.google.com/migrate/virtual-machines/docs>
- Compute Engine SLA — <https://cloud.google.com/compute/sla>
- Cloud Storage SLA — <https://cloud.google.com/storage/sla>
- Well-Architected Framework, reliability — <https://cloud.google.com/architecture/framework/reliability>
- Carbon-free energy by region — <https://cloud.google.com/sustainability/region-carbon>
- Carbon Footprint reporting — <https://cloud.google.com/carbon-footprint/docs>