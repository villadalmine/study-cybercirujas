# Topic 1.2 — Describe fundamental cloud concepts
## Guided exercises (gcp-cdl · exam version 2026-08-12 · exam weight 9.0)

> **What this topic actually asks of you.** Section 1.2 of the Cloud Digital Leader exam guide is not "name the five NIST characteristics." It asks you to *reason about a business decision*: CapEx vs OpEx, the total cost of ownership, which service model shifts which operational burden, and what "public / private / hybrid / multicloud" commits an organization to. Every exercise below therefore ends in an artefact you can put in front of a CFO, not just a command that ran.
>
> Source of record: [Cloud Digital Leader exam guide (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf). Conceptual baseline: [NIST SP 800-145, *The NIST Definition of Cloud Computing*](https://csrc.nist.gov/pubs/sp/800/145/final).

**Estimated time:** 150–180 minutes. **Estimated spend:** under **USD 2** if you complete the cleanup section. Most steps are free (`describe`, `list`, Catalog API); the billable ones are flagged with 💸.

---

## Exercise 0 — Build the lab, and put a fence around the money first

A cloud account with no budget is the single most common way a "free" lab becomes a USD 400 invoice. *Measured service* means the meter starts the instant a resource exists, whether or not you use it. Build the guardrail before the workload.

### Block 0.1 — Environment and identity

1. Open [Cloud Shell](https://cloud.google.com/shell/docs) (`>_` in the Cloud console) or install the [gcloud CLI](https://cloud.google.com/sdk/docs/install) locally. Cloud Shell is preferable here: it is itself a PaaS product, and you will use that fact in Exercise 3.

2. Confirm the toolchain and the active identity:

```bash
gcloud version
gcloud auth list
```

Expected (versions drift; the shape is what matters):

```
Google Cloud SDK 5xx.0.0
bq 2.1.x
core 2026.xx.xx
gcloud-crc32c 1.0.0
gsutil 5.xx

     Credentialed Accounts
ACTIVE  ACCOUNT
*       you@example.com

To set the active account, run:
    $ gcloud config set account `ACCOUNT`
```

3. Create a dedicated project. A project is the billing, quota and IAM boundary — never run a lab inside a project that holds anything you care about:

```bash
export PROJECT_ID="cdl-12-lab-$(date +%s | tail -c 6)"
gcloud projects create "$PROJECT_ID" --name="CDL 1.2 lab"
gcloud config set project "$PROJECT_ID"
```

```
Create in progress for [https://cloudresourcemanager.googleapis.com/v1/projects/cdl-12-lab-84021].
Waiting for [operations/cp.7412...] to finish...done.
Enabling service [cloudapis.googleapis.com] on project [cdl-12-lab-84021]...
Updated property [core/project].
```

4. Inspect the resource hierarchy the project landed in:

```bash
gcloud projects describe "$PROJECT_ID" --format="yaml(projectId,parent,lifecycleState)"
```

```yaml
lifecycleState: ACTIVE
parent:
  id: '481920374652'
  type: organization
projectId: cdl-12-lab-84021
```

If `parent` is absent, your project is org-less (a personal Gmail account). Note that difference — it changes who can enforce policy, which is the whole point of Exercise 4.

### Block 0.2 — Attach billing and set the fence

5. List the billing accounts you can act on:

```bash
gcloud billing accounts list
```

```
ACCOUNT_ID            NAME                 OPEN  MASTER_ACCOUNT_ID
01A2B3-C4D5E6-F7G8H9  My Billing Account   True
```

6. Link the project and enable the APIs used throughout:

```bash
export BILLING_ACCOUNT="01A2B3-C4D5E6-F7G8H9"   # substitute yours
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

gcloud services enable \
  compute.googleapis.com \
  run.googleapis.com \
  cloudbilling.googleapis.com \
  billingbudgets.googleapis.com \
  cloudresourcemanager.googleapis.com \
  recommender.googleapis.com
```

```
billingAccountName: billingAccounts/01A2B3-C4D5E6-F7G8H9
billingEnabled: true
name: projects/cdl-12-lab-84021/billingInfo
projectId: cdl-12-lab-84021

Operation "operations/acat.p2-481920374652-9c1e..." finished successfully.
```

7. Create a budget with a **forecast-based** alert, not only an actual-spend alert. Actual-spend alerts tell you that you have already lost the money:

```bash
gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="CDL 1.2 lab guard" \
  --budget-amount=10USD \
  --filter-projects="projects/$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=0.9,basis=forecasted-spend
```

```
Created budget [billingAccounts/01A2B3-C4D5E6-F7G8H9/budgets/8f3a1c0e-...].
```

8. Verify it exists, and read what a budget is *not*:

```bash
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
  --format="table(displayName, amount.specifiedAmount.units, thresholdRules[].thresholdPercent)"
```

```
DISPLAY_NAME       UNITS  THRESHOLD_PERCENT
CDL 1.2 lab guard  10     [0.5, 0.9, 0.9]
```

> Reference: [Create, edit, or delete budgets and budget alerts](https://cloud.google.com/billing/docs/how-to/budgets).

**Comprehension check — Exercise 0**

- **Q1.** A budget of USD 10 with a 100% threshold fires an alert. What happens to the running VMs at that moment, by default?
- **Q2.** Which NIST essential characteristic does the existence of a per-project, per-SKU billing record demonstrate, and why does that characteristic make OpEx accounting possible at all?
- **Q3.** You linked a *project* to a *billing account*. Explain, in the terms a CFO uses, what each of those two objects maps to in a traditional finance model.
- **Q4.** Why is a forecast-based threshold operationally more useful than an actual-spend threshold in a lab, and *less* useful than a hard quota in production?

---

## Exercise 1 — "Measured service" is literal: read the price list as an API

Traditional procurement asks a vendor for a quote. Cloud pricing is a queryable, versioned, machine-readable catalogue. Understanding this is what separates a real TCO model from a guess.

1. Enumerate the billable services. Each has a stable service ID:

```bash
TOKEN=$(gcloud auth print-access-token)

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://cloudbilling.googleapis.com/v1/services?pageSize=200" \
| jq -r '.services[] | select(.displayName | test("Compute Engine|Cloud Run|Cloud Storage|BigQuery")) | "\(.serviceId)  \(.displayName)"'
```

```
6F81-5844-456A  Compute Engine
152E-C115-5142  Cloud Run
95FF-2EF5-5EA1  Cloud Storage
24E6-581D-38E5  BigQuery
```

2. Pull the SKUs for Compute Engine and isolate one concrete unit price — the on-demand vCPU-hour for the N2 family in `us-central1`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD&pageSize=5000" \
| jq -r '
  .skus[]
  | select(.category.resourceGroup=="CPU")
  | select(.description | test("^N2 Instance Core running in Americas$"))
  | {
      sku: .skuId,
      desc: .description,
      regions: .serviceRegions,
      usage: .pricingInfo[0].pricingExpression.usageUnitDescription,
      nanos: .pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos
    }'
```

```json
{
  "sku": "9B1F-3D07-A9F1",
  "desc": "N2 Instance Core running in Americas",
  "regions": ["us-central1", "us-east1", "us-east4", "us-west1", "..."],
  "usage": "hour",
  "nanos": 31611000
}
```

3. Convert nanos to dollars and derive the monthly cost of a machine that is switched on and never touched:

```bash
python3 - <<'PY'
vcpu_hr  = 31611000 / 1e9        # USD per vCPU-hour  (nanos -> USD)
gib_hr   =  4237000 / 1e9        # USD per GiB-hour, N2 RAM, Americas
vcpus, gib, hours = 4, 16, 730   # n2-standard-4, one average month
print(f"vCPU: ${vcpu_hr*vcpus*hours:7.2f}")
print(f"RAM : ${gib_hr*gib*hours:7.2f}")
print(f"TOTAL on-demand, 24x7: ${(vcpu_hr*vcpus + gib_hr*gib)*hours:7.2f}/month")
PY
```

```
vCPU: $  92.30
RAM : $  49.49
TOTAL on-demand, 24x7: $ 141.79/month
```

> ⚠️ Prices change. The `nanos` values above are illustrative; the *method* is the deliverable. Always re-read them from the [Cloud Billing Catalog API](https://cloud.google.com/billing/v1/how-tos/catalog-api) or the [Pricing Calculator](https://cloud.google.com/products/calculator).

4. Now price the same shape of machine in three regions and observe that geography is a pricing dimension:

```bash
for R in us-central1 europe-west3 southamerica-east1 asia-northeast1; do
  printf '%-20s' "$R"
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD&pageSize=5000" \
  | jq -r --arg r "$R" '
      [ .skus[]
        | select(.category.resourceGroup=="CPU")
        | select(.description | startswith("N2 Instance Core running in"))
        | select(.serviceRegions | index($r))
        | .pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos ][0] // "n/a"'
done
```

```
us-central1         31611000
europe-west3        37773000
southamerica-east1  49962000
asia-northeast1     40398000
```

**Comprehension check — Block 1**

- **Q5.** The same `n2-standard-4` costs roughly 58% more in `southamerica-east1` than in `us-central1`. Give two business reasons an architect would still deploy there, and name the one that is *not* negotiable.
- **Q6.** The API returned a price per **vCPU-hour** and a separate price per **GiB-hour**, not a price per "server". What does that decomposition let you do that a traditional server quote does not?
- **Q7.** A CFO asks, "What will we spend on compute next year?" Explain precisely why the honest answer is a *forecast with a demand assumption*, and which NIST characteristic makes it so.

---

## Exercise 2 — Geography: zones, regions, multi-region, and the speed of light

"The cloud" has coordinates. Availability, latency, cost and legal exposure all fall out of them.

### Block 2.1 — The hierarchy

1. List regions and read the quota columns as a capacity statement:

```bash
gcloud compute regions list --format="table(name, status, quotas[0].metric, quotas[0].limit)" | head -12
```

```
NAME                     STATUS  METRIC  LIMIT
africa-south1            UP      CPUS    24.0
asia-east1               UP      CPUS    24.0
asia-northeast1          UP      CPUS    24.0
australia-southeast1     UP      CPUS    24.0
europe-north1            UP      CPUS    24.0
europe-west1             UP      CPUS    24.0
me-central1              UP      CPUS    24.0
southamerica-east1       UP      CPUS    24.0
us-central1              UP      CPUS    24.0
```

2. Expand one region into its zones:

```bash
gcloud compute zones list --filter="region:( us-central1 europe-west4 )" \
  --format="table(name, region.basename(), status, nextMaintenanceWindow)"
```

```
NAME             REGION        STATUS  NEXT_MAINTENANCE
europe-west4-a   europe-west4  UP
europe-west4-b   europe-west4  UP
europe-west4-c   europe-west4  UP
us-central1-a    us-central1   UP
us-central1-b    us-central1   UP
us-central1-c    us-central1   UP
us-central1-f    us-central1   UP
```

3. Count zones per region across the whole platform — this is your blast-radius map:

```bash
gcloud compute zones list --format="value(region.basename())" | sort | uniq -c | sort -rn | head -8
```

```
      4 us-central1
      3 us-east1
      3 europe-west1
      3 asia-east1
      3 southamerica-east1
      ...
```

4. Confirm that not every machine family exists in every zone. Capability is regional, not global:

```bash
for Z in us-central1-a europe-west4-a southamerica-east1-a; do
  printf '%-22s' "$Z"
  gcloud compute machine-types list --zones="$Z" \
    --filter="name~^c3-standard" --format="value(name)" | wc -l
done
```

```
us-central1-a         9
europe-west4-a        9
southamerica-east1-a  0
```

**Comprehension check — Block 2.1**

- **Q8.** Define *zone* and *region* so that a non-engineer understands why "two VMs in `us-central1-a` and `us-central1-b`" is more available than "two VMs in `us-central1-a`", and why that is still not a disaster-recovery plan.
- **Q9.** `southamerica-east1-a` returned zero `c3-standard` machine types. What does that tell you about the assumption "the cloud has infinite capacity of every kind, everywhere"?

### Block 2.2 — Latency is physics, not configuration

5. Measure real round-trip latency from your location to Google Cloud regions using Google's own tool:

```bash
# Cloud Shell: Go is preinstalled
go install github.com/GoogleCloudPlatform/gcping/cmd/gcping@latest
"$(go env GOPATH)/bin/gcping" -n 5 -t 10s
```

```
 1.  us-central1                 12 ms
 2.  us-east4                    28 ms
 3.  us-west1                    41 ms
 4.  northamerica-northeast1     47 ms
 5.  europe-west2               104 ms
 6.  europe-west3               112 ms
 7.  southamerica-east1         156 ms
 8.  asia-northeast1            168 ms
 9.  asia-south1                241 ms
10.  australia-southeast1       196 ms
```

(No Go? The same measurement runs in a browser at [gcping.com](https://gcping.com).)

6. Compute the theoretical floor and compare it to what you measured:

```bash
python3 - <<'PY'
# Great-circle distance is ~ the shortest possible fibre path.
# Light in glass travels at ~2/3 c => ~200,000 km/s. RTT doubles the distance.
for city, km in [("US-central <-> Europe", 7500), ("US-central <-> São Paulo", 8300),
                 ("US-central <-> Tokyo", 10000)]:
    floor_ms = (2 * km) / 200_000 * 1000
    print(f"{city:28s} theoretical RTT floor: {floor_ms:5.1f} ms")
PY
```

```
US-central <-> Europe        theoretical RTT floor:  75.0 ms
US-central <-> São Paulo     theoretical RTT floor:  83.0 ms
US-central <-> Tokyo         theoretical RTT floor: 100.0 ms
```

7. Contrast a **regional** resource with a **multi-region** one. Create two buckets and read back their location type:

```bash
gcloud storage buckets create "gs://${PROJECT_ID}-regional"    --location=us-central1
gcloud storage buckets create "gs://${PROJECT_ID}-multiregion" --location=us

gcloud storage buckets describe "gs://${PROJECT_ID}-regional"    --format="value(location,location_type)"
gcloud storage buckets describe "gs://${PROJECT_ID}-multiregion" --format="value(location,location_type)"
```

```
US-CENTRAL1     region
US              multi-region
```

> References: [Geography and regions](https://cloud.google.com/docs/geography-and-regions) · [Regions and zones](https://cloud.google.com/compute/docs/regions-zones) · [Cloud locations](https://cloud.google.com/about/locations).

**Comprehension check — Block 2.2**

- **Q10.** Your measured RTT to a distant region is close to the theoretical floor. What does that prove about the value of "optimising the application" to fix cross-continent latency?
- **Q11.** A European retailer must serve customers in Frankfurt with sub-50 ms page loads **and** keep customer records inside the EU. Which two distinct 1.2 concepts is this requirement combining, and which one can be solved with a CDN while the other cannot?
- **Q12.** Explain the durability/availability difference between the `us-central1` bucket and the `US` multi-region bucket, and state the cost consequence.

---

## Exercise 3 — The service-model ladder: run one workload as IaaS, PaaS and SaaS

The exam wants you to place a workload on the IaaS/PaaS/SaaS ladder and say *what the organization stopped doing*. Build the same "serve an HTTP page" outcome three ways and count the tasks.

### Block 3.1 — IaaS 💸

1. Create a VM and install a web server yourself:

```bash
gcloud compute instances create iaas-web \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --image-family=debian-12 --image-project=debian-cloud \
  --tags=http-lab \
  --metadata=startup-script='#!/bin/bash
apt-get update -y
apt-get install -y nginx
echo "IaaS: I chose the OS, I patch the OS." > /var/www/html/index.html
systemctl enable --now nginx'
```

```
Created [https://www.googleapis.com/compute/v1/projects/cdl-12-lab-84021/zones/us-central1-a/instances/iaas-web].
NAME      ZONE           MACHINE_TYPE  PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP    STATUS
iaas-web  us-central1-a  e2-micro                   10.128.0.2   34.121.55.198  RUNNING
```

2. You now own the firewall too. Nothing reaches it until you say so:

```bash
gcloud compute firewall-rules create allow-http-lab \
  --allow=tcp:80 --target-tags=http-lab --source-ranges=0.0.0.0/0
sleep 45
curl -s "http://$(gcloud compute instances describe iaas-web --zone=us-central1-a \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
```

```
Creating firewall...done.
IaaS: I chose the OS, I patch the OS.
```

3. Enumerate what you inherited by choosing IaaS:

```bash
gcloud compute ssh iaas-web --zone=us-central1-a --command="
  echo '--- kernel you are responsible for ---'; uname -r
  echo '--- pending security updates you are responsible for ---'
  apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true
  echo '--- uptime you are billed for regardless of traffic ---'; uptime -p
"
```

```
--- kernel you are responsible for ---
6.1.0-28-cloud-amd64
--- pending security updates you are responsible for ---
14
--- uptime you are billed for regardless of traffic ---
up 3 minutes
```

**Comprehension check — Block 3.1**

- **Q13.** List the four operational tasks you performed in Block 3.1 that a PaaS would have removed entirely.
- **Q14.** The VM reports 14 pending package updates. In the shared responsibility model, who must apply them, and would that answer change on Cloud Run?

### Block 3.2 — PaaS 💸 (pennies)

4. Deploy the equivalent outcome as a managed container platform. No OS, no firewall rule, no patching:

```bash
gcloud run deploy paas-web \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region=us-central1 \
  --allow-unauthenticated \
  --min-instances=0 --max-instances=5
```

```
Deploying container to Cloud Run service [paas-web] in project [cdl-12-lab-84021] region [us-central1]
✓ Deploying new service... Done.
  ✓ Creating Revision...
  ✓ Routing traffic...
  ✓ Setting IAM Policy...
Done.
Service [paas-web] revision [paas-web-00001-kip] has been deployed
and is serving 100 percent of traffic.
Service URL: https://paas-web-1a2b3c4d5e-uc.a.run.app
```

5. Prove the economic difference — scale to zero:

```bash
URL=$(gcloud run services describe paas-web --region=us-central1 --format='value(status.url)')
curl -s -o /dev/null -w "cold start: %{time_total}s\n" "$URL"
curl -s -o /dev/null -w "warm:       %{time_total}s\n" "$URL"

gcloud run services describe paas-web --region=us-central1 \
  --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])"
```

```
cold start: 1.284s
warm:       0.061s
0
```

6. Ask the platform what it manages on your behalf:

```bash
gcloud run services describe paas-web --region=us-central1 \
  --format="yaml(status.conditions, spec.template.spec.containers[0].image)"
```

```yaml
spec:
  template:
    spec:
      containers:
      - image: us-docker.pkg.dev/cloudrun/container/hello
status:
  conditions:
  - status: 'True'
    type: Ready
  - status: 'True'
    type: ConfigurationsReady
  - status: 'True'
    type: RoutesReady
```

There is no kernel version in that output because there is no kernel that is yours.

### Block 3.3 — SaaS (free)

7. You have been using SaaS for the entire lab. Confirm it:

```bash
gcloud services list --enabled --format="table(config.name, config.title)" | head
```

```
NAME                              TITLE
cloudbilling.googleapis.com       Cloud Billing API
cloudresourcemanager.googleapis.com  Cloud Resource Manager API
compute.googleapis.com            Compute Engine API
run.googleapis.com                Cloud Run Admin API
```

The Cloud console, Google Workspace and Looker Studio are consumed the same way: you configure and you use; you never see a version number, a server, or a maintenance window.

8. Build the comparison table that is the actual deliverable of this exercise:

```bash
cat <<'MD' > ~/service-models.md
| Layer                     | On-premises | IaaS (GCE) | PaaS (Cloud Run) | SaaS (Workspace) |
|---------------------------|:-----------:|:----------:|:----------------:|:----------------:|
| Data & access policy      | You         | You        | You              | You              |
| Application code          | You         | You        | You              | Provider         |
| Runtime / libraries       | You         | You        | Provider         | Provider         |
| Container / OS patching   | You         | **You**    | Provider         | Provider         |
| Virtualisation            | You         | Provider   | Provider         | Provider         |
| Servers, storage, network | You         | Provider   | Provider         | Provider         |
| Facility, power, physical | You         | Provider   | Provider         | Provider         |
| Billed when idle?         | Always      | **Yes**    | No (min=0)       | Per seat/licence |
MD
cat ~/service-models.md
```

> References: [What is Cloud Run](https://cloud.google.com/run/docs/overview/what-is-cloud-run) · [Compute Engine documentation](https://cloud.google.com/compute/docs) · [Google Cloud service terms](https://cloud.google.com/terms/services).

**Comprehension check — Block 3.3**

- **Q15.** The IaaS VM and the Cloud Run service serve an identical HTTP response. State the two dimensions on which their cost curves diverge, and name the traffic profile that makes each one cheaper.
- **Q16.** In the table above, one row never moves to the provider at any service model. Which row, and what is the security principle that guarantees it never moves?
- **Q17.** A company says "we moved to the cloud" after lifting 300 VMs into Compute Engine unchanged. Using the ladder, explain what they gained and what they explicitly did *not* gain.

---

## Exercise 4 — Shared responsibility, and Google's "shared fate"

The line between customer and provider is not a diagram on a slide — it is enforced in the API. Find the line by touching it.

1. Ask which side owns encryption at rest by default:

```bash
gcloud compute disks describe iaas-web --zone=us-central1-a \
  --format="yaml(name, sizeGb, diskEncryptionKey)"
```

```yaml
name: iaas-web
sizeGb: '10'
```

The absent `diskEncryptionKey` block is the answer: Google encrypts every persistent disk at rest with Google-managed keys, always, with no action from you. To take that responsibility *back*, you would supply a CMEK.

2. Now find something Google will **not** do for you — check who can access the project:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --format="table(bindings.role, bindings.members)"
```

```
ROLE                  MEMBERS
roles/owner           user:you@example.com
roles/editor          serviceAccount:481920374652@cloudservices.gserviceaccount.com
```

3. Deliberately create the most common cloud misconfiguration in existence, then detect it:

```bash
gcloud storage buckets add-iam-policy-binding "gs://${PROJECT_ID}-regional" \
  --member=allUsers --role=roles/storage.objectViewer

gcloud storage buckets get-iam-policy "gs://${PROJECT_ID}-regional" \
  --format="json(bindings)" | jq '.bindings[] | select(.members[]=="allUsers")'
```

```json
{
  "members": ["allUsers"],
  "role": "roles/storage.objectViewer"
}
```

Google's infrastructure worked perfectly. The bucket is world-readable because *you* said so. Revert it:

```bash
gcloud storage buckets remove-iam-policy-binding "gs://${PROJECT_ID}-regional" \
  --member=allUsers --role=roles/storage.objectViewer
```

4. Observe **shared fate** — the provider actively helping you stay on the right side of the line, rather than merely documenting where it is:

```bash
gcloud recommender recommendations list \
  --project="$PROJECT_ID" \
  --location=global \
  --recommender=google.iam.policy.Recommender \
  --format="table(description.flatten(), priority)" 2>/dev/null \
  || echo "(No IAM recommendations yet — the recommender needs ~90 days of usage data.)"
```

```
(No IAM recommendations yet — the recommender needs ~90 days of usage data.)
```

Also inspect the machinery an organization uses to make the customer side *hard to get wrong* — Organization Policy:

```bash
gcloud resource-manager org-policies list --project="$PROJECT_ID" 2>/dev/null \
  || echo "(Requires an organization: constraints such as storage.publicAccessPrevention live here.)"
```

5. Read the availability half of the contract:

```bash
gcloud compute instances describe iaas-web --zone=us-central1-a \
  --format="value(scheduling.onHostMaintenance, scheduling.automaticRestart)"
```

```
MIGRATE  True
```

Live migration is Google keeping its SLA obligation. A single Compute Engine instance carries a **99.9%** monthly uptime commitment; instances spread across two or more zones in a region carry **99.99%**. The architecture that earns the higher number is yours to build.

> References: [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate) · [Compute Engine SLA](https://cloud.google.com/compute/sla) · [Google Cloud SLAs](https://cloud.google.com/terms/sla/).

**Comprehension check — Exercise 4**

- **Q18.** In step 3 you exposed a bucket to the entire internet and no Google control stopped you. Was this a failure of the provider? Justify your answer using the shared responsibility model.
- **Q19.** Distinguish *shared responsibility* from *shared fate* in one sentence each, and give one concrete Google Cloud feature that exists only because of the second idea.
- **Q20.** The Compute Engine SLA offers 99.9% for a single instance. Convert that to permitted downtime per 30-day month, and explain why an SLA is a **credit** mechanism rather than an availability guarantee.

---

## Exercise 5 — Elasticity vs scalability, demonstrated

Two words the exam treats as distinct: *scalability* is the ability to grow; *elasticity* is the ability to grow **and shrink automatically** with demand. Elasticity is what converts fixed cost into variable cost.

1. 💸 Build an autoscaled managed instance group — the IaaS expression of elasticity:

```bash
gcloud compute instance-templates create elastic-tpl \
  --machine-type=e2-micro \
  --image-family=debian-12 --image-project=debian-cloud \
  --tags=http-lab \
  --metadata=startup-script='#!/bin/bash
apt-get update -y && apt-get install -y nginx stress-ng
echo "elastic node $(hostname)" > /var/www/html/index.html
systemctl enable --now nginx'

gcloud compute instance-groups managed create elastic-mig \
  --template=elastic-tpl --size=1 --zone=us-central1-a

gcloud compute instance-groups managed set-autoscaling elastic-mig \
  --zone=us-central1-a \
  --min-num-replicas=1 --max-num-replicas=4 \
  --target-cpu-utilization=0.60 \
  --cool-down-period=60
```

```
Created [.../instanceTemplates/elastic-tpl].
Created [.../instanceGroupManagers/elastic-mig].
Updated [.../autoscalers/elastic-mig].
```

2. Read the autoscaler's decision policy back — this is the contract between demand and spend:

```bash
gcloud compute instance-groups managed describe elastic-mig --zone=us-central1-a \
  --format="yaml(targetSize, status.autoscaler.basename(), currentActions)"

gcloud compute autoscalers describe elastic-mig --zone=us-central1-a \
  --format="yaml(autoscalingPolicy)"
```

```yaml
currentActions:
  creating: 0
  deleting: 0
  none: 1
  recreating: 0
status.autoscaler: elastic-mig
targetSize: 1
---
autoscalingPolicy:
  coolDownPeriodSec: 60
  cpuUtilization:
    predictiveMethod: NONE
    utilizationTarget: 0.6
  maxNumReplicas: 4
  minNumReplicas: 1
  mode: 'ON'
```

3. Generate load and watch the group grow (allow 3–5 minutes; the autoscaler is deliberately damped):

```bash
NODE=$(gcloud compute instance-groups managed list-instances elastic-mig \
  --zone=us-central1-a --format="value(instance.basename())" | head -1)

gcloud compute ssh "$NODE" --zone=us-central1-a --command="nohup stress-ng --cpu 2 --timeout 420s >/dev/null 2>&1 &"

for i in $(seq 1 10); do
  printf '%s  targetSize=' "$(date +%H:%M:%S)"
  gcloud compute instance-groups managed describe elastic-mig --zone=us-central1-a --format="value(targetSize)"
  sleep 60
done
```

```
14:02:11  targetSize=1
14:03:12  targetSize=1
14:04:13  targetSize=2
14:05:14  targetSize=3
14:06:15  targetSize=3
14:07:16  targetSize=3
```

4. Stop the load and observe the asymmetry — scale-in is slower than scale-out, on purpose:

```bash
gcloud compute ssh "$NODE" --zone=us-central1-a --command="pkill stress-ng || true"
# Recheck after ~10-15 minutes:
gcloud compute instance-groups managed describe elastic-mig --zone=us-central1-a --format="value(targetSize)"
```

```
1
```

5. Contrast with the PaaS expression of the same idea — no policy to write, and a floor of **zero**:

```bash
gcloud run services describe paas-web --region=us-central1 \
  --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/maxScale'],
                  spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])"
```

```
5    0
```

> References: [Autoscaling groups of instances](https://cloud.google.com/compute/docs/autoscaler) · [About Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling).

**Comprehension check — Exercise 5**

- **Q21.** The MIG floor is 1 and the Cloud Run floor is 0. Express that single difference as a monthly-cost statement for a service that receives traffic 4 hours per business day.
- **Q22.** Scale-out took ~2 minutes; scale-in took ~12. Why is that asymmetry a deliberate engineering choice rather than a defect?
- **Q23.** A finance team asks for a fixed monthly cloud budget with autoscaling enabled. Name the two knobs that make this answerable, and explain the trade-off each one imposes.
- **Q24.** Distinguish *scalability* from *elasticity* using this exercise, then say which of the two an on-premises datacentre can genuinely offer.

---

## Exercise 6 — Deployment models: public, private, hybrid, multicloud

1. Create the network boundary. A VPC is what makes "public cloud" behave like private infrastructure:

```bash
gcloud compute networks create lab-vpc --subnet-mode=custom
gcloud compute networks subnets create lab-subnet \
  --network=lab-vpc --region=us-central1 --range=10.10.0.0/24 \
  --enable-private-ip-google-access
```

```
Created [.../networks/lab-vpc].
NAME     SUBNET_MODE  BGP_ROUTING_MODE  IPV4_RANGE  GATEWAY_IPV4
lab-vpc  CUSTOM       REGIONAL

Created [.../subnetworks/lab-subnet].
NAME        REGION       NETWORK  RANGE
lab-subnet  us-central1  lab-vpc  10.10.0.0/24
```

2. 💸 Launch a VM with **no external IP** and prove it still reaches Google APIs — this is a private deployment pattern inside a public cloud:

```bash
gcloud compute instances create private-node \
  --zone=us-central1-a --machine-type=e2-micro \
  --subnet=lab-subnet --no-address \
  --image-family=debian-12 --image-project=debian-cloud \
  --scopes=cloud-platform

gcloud compute instances describe private-node --zone=us-central1-a \
  --format="value(networkInterfaces[0].networkIP, networkInterfaces[0].accessConfigs)"
```

```
10.10.0.2
```

The empty second column is the point: no public address, no path from the internet, yet Private Google Access lets it call `storage.googleapis.com`.

3. Model the **hybrid** edge. Inspect what a connection to an on-premises datacentre would consist of, without paying for one:

```bash
gcloud compute interconnects list
gcloud compute vpn-gateways list
gcloud compute routers list
```

```
Listed 0 items.
Listed 0 items.
Listed 0 items.
```

Now create the free half — a Cloud Router, the BGP speaker that would exchange routes with your on-prem edge:

```bash
gcloud compute routers create lab-router \
  --network=lab-vpc --region=us-central1 --asn=64514

gcloud compute routers describe lab-router --region=us-central1 \
  --format="yaml(name, bgp.asn, network.basename())"
```

```yaml
bgp:
  asn: 64514
name: lab-router
network: lab-vpc
```

An ASN and BGP are the tell: hybrid connectivity is *routing*, not a VPN checkbox. The production choices are [HA VPN](https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview) (over the public internet, encrypted, 99.99% SLA when configured with two interfaces) and [Cloud Interconnect](https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview) (Dedicated or Partner, private physical circuits, no internet transit).

4. Model **multicloud**. Query the fleet API that would register a cluster running in another provider:

```bash
gcloud container fleet memberships list 2>/dev/null \
  || echo "(Enable gkehub.googleapis.com — fleet memberships can include AWS/Azure/on-prem clusters.)"
```

```
(Enable gkehub.googleapis.com — fleet memberships can include AWS/Azure/on-prem clusters.)
```

5. Write the decision record. This, not the commands, is the exam-relevant artefact:

```bash
cat <<'MD' > ~/deployment-models.md
| Model       | Where compute runs            | Chosen because                                   | Principal cost                          |
|-------------|-------------------------------|--------------------------------------------------|-----------------------------------------|
| Public      | Provider infrastructure only  | Speed, elasticity, no CapEx, global reach         | Egress fees; provider-specific services |
| Private     | Owned/leased DC, or GDC       | Sovereignty, air-gap, unmovable legacy hardware   | CapEx, capacity planning, low elasticity|
| Hybrid      | Both, connected by Interconnect/HA VPN | Mainframe or data gravity stays put; burst to cloud | Two operating models; link is now critical |
| Multicloud  | Two or more public providers  | Provider risk, per-provider strengths, M&A reality | Duplicated skills, tooling, egress      |
MD
cat ~/deployment-models.md
```

> References: [VPC overview](https://cloud.google.com/vpc/docs/overview) · [Private Google Access](https://cloud.google.com/vpc/docs/private-google-access) · [GKE Enterprise overview](https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview) · [Google Distributed Cloud](https://cloud.google.com/distributed-cloud) · [BigQuery Omni](https://cloud.google.com/bigquery/docs/omni-introduction).

**Comprehension check — Exercise 6**

- **Q25.** `private-node` has no external IP. Does that make it a *private cloud* deployment? Answer precisely.
- **Q26.** A bank keeps its core ledger on a mainframe that cannot move, and wants ML on that data in Google Cloud. Name the deployment model, the connectivity product you would specify, and the single technical reason you would reject HA VPN for it.
- **Q27.** A CIO says "multicloud so we're never locked in." Give the strongest counter-argument in one sentence, and the one scenario where the CIO is simply right.
- **Q28.** Egress appears as a cost in three rows of your table. Explain why data transfer *out* is the pricing dimension that most often surprises organizations in a hybrid or multicloud design.

---

## Exercise 7 — Total cost of ownership: build the model, then attack it

Everything before this exercise exists so that this one is honest.

1. Establish the on-premises baseline. TCO is never just the hardware:

```bash
python3 - <<'PY'
years = 3
onprem = {
  "Servers (10 x 2-socket, incl. 3y support)": 148_000,
  "Storage array + expansion":                  62_000,
  "Network (ToR switches, optics, cabling)":    24_000,
  "Hypervisor + backup licences (3y)":          51_000,
  "Rack, power, cooling (3y)":                  39_000,
  "Datacentre space / colo (3y)":               72_000,
  "DR site (contracted, 3y)":                   58_000,
  "Ops staff share (0.6 FTE x 3y)":            234_000,
  "Refresh/disposal at end of life":            11_000,
}
total = sum(onprem.values())
for k, v in onprem.items():
    print(f"{k:46s} ${v:>9,}")
print("-" * 58)
print(f"{'3-YEAR ON-PREM TCO':46s} ${total:>9,}")
print(f"{'Per month':46s} ${total/(years*12):>9,.0f}")
PY
```

```
Servers (10 x 2-socket, incl. 3y support)      $  148,000
Storage array + expansion                      $   62,000
Network (ToR switches, optics, cabling)        $   24,000
Hypervisor + backup licences (3y)              $   51,000
Rack, power, cooling (3y)                      $   39,000
Datacentre space / colo (3y)                   $   72,000
DR site (contracted, 3y)                       $   58,000
Ops staff share (0.6 FTE x 3y)                 $  234,000
Refresh/disposal at end of life                $   11,000
----------------------------------------------------------
3-YEAR ON-PREM TCO                             $  699,000
Per month                                      $   19,417
```

2. Build the cloud side using the discount mechanisms, and note which are automatic:

```bash
python3 - <<'PY'
base = 141.79            # n2-standard-4, 24x7 on-demand, from Exercise 1
fleet = 40               # equivalent VMs

scenarios = {
  "On-demand, 24x7":                       base * fleet,
  "+ Sustained use discount (automatic)":  base * fleet * 0.80,
  "+ 1-year CUD (resource-based)":         base * fleet * 0.63,
  "+ 3-year CUD (resource-based)":         base * fleet * 0.45,
  "Spot VMs (fault-tolerant tier only)":   base * fleet * 0.25,
  "Right-sized: 40 -> 26 VMs, 3-year CUD": base * 26   * 0.45,
}
for name, monthly in scenarios.items():
    print(f"{name:42s} ${monthly:8,.0f}/mo   ${monthly*36:10,.0f} / 3y")
PY
```

```
On-demand, 24x7                            $   5,672/mo   $   204,178 / 3y
+ Sustained use discount (automatic)       $   4,537/mo   $   163,342 / 3y
+ 1-year CUD (resource-based)              $   3,573/mo   $   128,632 / 3y
+ 3-year CUD (resource-based)              $   2,552/mo   $    91,880 / 3y
Spot VMs (fault-tolerant tier only)        $   1,418/mo   $    51,044 / 3y
Right-sized: 40 -> 26 VMs, 3-year CUD      $   1,659/mo   $    59,722 / 3y
```

Discount mechanics, as documented:
- **[Sustained use discounts](https://cloud.google.com/compute/docs/sustained-use-discounts)** — automatic, no commitment, applied when eligible machine types (N1, N2, N2D, C2, C2D and the memory-optimized families) run a large share of the month. E2 and Tau T2D/T2A do **not** receive SUDs; their on-demand price is already lower.
- **[Committed use discounts](https://cloud.google.com/docs/cuds)** — 1- or 3-year commitments. Resource-based CUDs commit to vCPU/memory in a region; spend-based (flexible) CUDs commit to an hourly dollar amount and follow you across services. Deep discounts, but you pay whether you use it or not.
- **[Spot VMs](https://cloud.google.com/compute/docs/instances/spot)** — 60–91% off, no minimum runtime, preemptible with a 30-second notice. Only for work that can die and be retried.

3. Verify that step 2's right-sizing figure is not a fiction — the platform will tell you:

```bash
gcloud recommender recommendations list \
  --project="$PROJECT_ID" --location=us-central1-a \
  --recommender=google.compute.instance.MachineTypeRecommender \
  --format="table(description.flatten(), primaryImpact.costProjection.cost.units)" 2>/dev/null \
  || echo "(Needs ~8 days of metrics. In production this is where the right-sizing number comes from — measured, not assumed.)"
```

4. Put the two sides in one frame and expose the assumptions:

```bash
python3 - <<'PY'
onprem_3y, cloud_3y = 699_000, 59_722
print(f"On-prem 3y : ${onprem_3y:>9,}   (CapEx-heavy, paid up front, 3-5y refresh cycle)")
print(f"Cloud   3y : ${cloud_3y:>9,}   (OpEx, monthly, exits with the workload)")
print(f"Delta      : ${onprem_3y-cloud_3y:>9,}")
print()
for a in [
  "Fleet is 40 VMs -> 26 after right-sizing (MUST be measured, not assumed)",
  "Egress volume is unpriced above (network egress is the #1 TCO surprise)",
  "Migration project cost is excluded (one-time, often 6-12 months of effort)",
  "Ops FTE is reduced, not eliminated: cloud ops is a different job, not no job",
  "Licence portability (BYOL for OS/DB) is not modelled",
  "On-prem sunk cost: hardware already bought changes the decision entirely",
]:
    print(f"  ! {a}")
PY
```

```
On-prem 3y : $  699,000   (CapEx-heavy, paid up front, 3-5y refresh cycle)
Cloud   3y : $   59,722   (OpEx, monthly, exits with the workload)
Delta      : $  639,278

  ! Fleet is 40 VMs -> 26 after right-sizing (MUST be measured, not assumed)
  ! Egress volume is unpriced above (network egress is the #1 TCO surprise)
  ! Migration project cost is excluded (one-time, often 6-12 months of effort)
  ! Ops FTE is reduced, not eliminated: cloud ops is a different job, not no job
  ! Licence portability (BYOL for OS/DB) is not modelled
  ! On-prem sunk cost: hardware already bought changes the decision entirely
```

5. Reproduce the compute line in the [Pricing Calculator](https://cloud.google.com/products/calculator) and confirm your figure lands within ~5% of the tool. If it does not, your model has a wrong assumption, not a wrong tool.

**Comprehension check — Exercise 7**

- **Q29.** Two of the nine on-premises line items have no cloud equivalent at all. Which two, and what does their disappearance say about what an organization is really buying?
- **Q30.** The right-sizing row saves more than the discount rows for the same fleet in step 2. State the general principle that follows, in the order you would apply optimisations.
- **Q31.** A 3-year CUD is the cheapest committed option. Name the specific business circumstance that makes signing it a mistake.
- **Q32.** Explain the CapEx→OpEx shift's effect beyond the total: name one balance-sheet consequence and one *behavioural* consequence inside an engineering team.
- **Q33.** Your model shows cloud at 8.5% of on-premises cost. Give the two most likely reasons that number is too good, and how you would test each.

---

## Cleanup — delete everything (this is part of the lesson)

*Measured service* runs in both directions. Anything you leave behind bills forever.

```bash
gcloud compute instance-groups managed delete elastic-mig --zone=us-central1-a --quiet
gcloud compute instance-templates delete elastic-tpl --quiet
gcloud compute instances delete iaas-web private-node --zone=us-central1-a --quiet
gcloud run services delete paas-web --region=us-central1 --quiet
gcloud compute firewall-rules delete allow-http-lab --quiet
gcloud compute routers delete lab-router --region=us-central1 --quiet
gcloud compute networks subnets delete lab-subnet --region=us-central1 --quiet
gcloud compute networks delete lab-vpc --quiet
gcloud storage rm -r "gs://${PROJECT_ID}-regional" "gs://${PROJECT_ID}-multiregion"
```

Verify nothing bills, then remove the project — the only deletion that is truly complete:

```bash
gcloud compute instances list; gcloud run services list; gcloud compute disks list
gcloud projects delete "$PROJECT_ID"
```

```
Listed 0 items.
Listed 0 items.
Listed 0 items.

Your project will be deleted.
Do you want to continue (Y/n)?  Y
Deleted [https://cloudresourcemanager.googleapis.com/v1/projects/cdl-12-lab-84021].
```

Project deletion is soft for ~30 days, then permanent. The billing account survives — delete the budget separately if you no longer want it.

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 0

**A1.** Nothing. A budget alert is a **notification**, not a control. VMs keep running and keep billing. To make it enforce, wire the budget's Pub/Sub topic to a Cloud Function that disables billing on the project or deletes resources — and understand that disabling billing stops workloads abruptly. The exam-relevant point: budgets provide *visibility*; quotas and Organization Policy provide *enforcement*.

**A2.** *Measured service.* Resource use is metered, controlled and reported at a granularity the customer can see. Without per-SKU metering there is no per-unit price, and without a per-unit price you cannot convert infrastructure into an operating expense that varies with consumption — you are back to buying a fixed asset.

**A3.** The **billing account** is the payment instrument and the invoice — the cost centre or the corporate card. The **project** is the cost-allocation tag — the department, product or environment the spend is charged to. One billing account fans out to many projects, which is exactly how chargeback/showback works: the invoice arrives once, attributed by project, label and folder.

**A4.** In a lab, spend is small and detection speed is everything — a forecast alert fires at the moment a runaway trend appears, hours before a threshold on actual spend would. In production it is *insufficient* because a forecast is still only a warning: it cannot stop a misconfigured job from spawning 500 GPUs. Quotas (`gcloud compute project-info describe`, quota limits per region/resource) are the hard ceiling; budgets are the smoke alarm.

### Exercise 1

**A5.** Legitimate reasons: (a) **latency** to end users in the region; (b) **data residency / sovereignty law** requiring data to stay in-country; (c) reduced egress by keeping data near where it is produced; (d) sustainability targets tied to a region's carbon-free-energy score. The **non-negotiable** one is data residency — a legal requirement cannot be architected around by moving to a cheaper region, whereas latency can be partially mitigated with CDN and caching.

**A6.** It lets you buy exactly the shape of resource the workload needs, including **custom machine types** with a non-standard vCPU:RAM ratio, and it makes right-sizing a continuous financial lever rather than a hardware refresh event. A server quote bundles CPU, RAM, disk and chassis into one indivisible unit that you over-provision once and live with for years.

**A7.** Because cloud cost is `unit price × consumption`, and only the **unit price** is known in advance. Consumption is a function of demand, which is a business forecast, not an engineering fact. This follows directly from *measured service* and *rapid elasticity*: the platform charges for what you use, so the spend is genuinely variable. The correct deliverable is a model with explicit demand assumptions and a sensitivity range, plus committed-use coverage for the demand floor you are confident about.

### Exercise 2

**A8.** A **zone** is a deployment area within a region backed by one or more clusters — it is the failure domain for correlated infrastructure events such as a power or cooling failure. A **region** is an independent geographic area containing three or more zones, connected by low-latency links. Two VMs in different zones survive the loss of one zone; two VMs in the same zone do not. It is still not a DR plan because a whole region can become unavailable (natural disaster, large-scale network event) and because zonal redundancy does nothing about the failure modes that actually cause most outages — bad deploys, corrupted data and deleted resources, all of which replicate happily across zones.

**A9.** Capacity and *capability* are finite and regional. Newer machine families, GPUs, TPUs and some services roll out region by region; quota is per-region and per-project. Architecturally this means region selection constrains which products you can use, and multi-region designs must verify that every dependency exists in every target region before committing.

**A10.** It proves the latency is dominated by **propagation delay in fibre**, which no amount of application optimisation can remove. The only real fixes are architectural: move compute closer to the user (regional deployments), move the response closer (Cloud CDN, edge caching), or remove round trips (batching, asynchronous protocols, local write-then-replicate). This is why "just make the app faster" is the wrong answer to a cross-continent latency complaint.

**A11.** It combines **latency/proximity** with **data residency/sovereignty**. A CDN solves the first — cache static assets and page shells at edge locations near Frankfurt. It cannot solve the second: caching personal data at a global edge would move it outside the EU, which is precisely what the requirement forbids. The residency constraint forces a `europe-*` region for the data tier, potentially with Assured Workloads to enforce it technically.

**A12.** Both offer the same nominal object durability. The difference is **availability and failure domain**: the `us-central1` bucket stores data redundantly within one region and becomes unreachable if that region does; the `US` multi-region bucket replicates across geographically separated regions inside the United States and survives the loss of one. The cost consequence is that multi-region storage carries a higher per-GB price, and you should therefore reserve it for data whose unavailability is genuinely business-stopping.

### Exercise 3

**A13.** (1) Choosing and provisioning an OS image; (2) installing and configuring the web server via startup script; (3) opening a firewall rule to admit traffic; (4) owning OS/kernel patching thereafter. A fifth, implicit one: sizing the machine in advance. Cloud Run required none of these — you supplied a container image and a URL came back.

**A14.** In IaaS the **customer** patches the guest OS. Google patches the hypervisor, host and physical layers; the guest is yours. On Cloud Run the answer changes: Google owns the operating system and the container runtime, and the customer's responsibility stops at the contents of the container image — which still includes patching the base image and libraries you packaged. Responsibility narrows; it does not vanish.

**A15.** They diverge on (1) **billing granularity** — the VM bills for wall-clock existence, Cloud Run bills for request-serving time in fine-grained increments; and (2) **idle floor** — the VM has a permanent floor, Cloud Run's floor is zero. Cloud Run is cheaper for **spiky, intermittent or low-duty-cycle** traffic. The always-on VM becomes cheaper at **high, sustained, predictable** utilisation, where per-request pricing plus platform margin exceeds the flat rate — and where SUDs/CUDs apply.

**A16.** **Data and access policy.** It never moves because the provider cannot know your business rules: who should see what, how long data is retained, which classification it carries. This is the invariant of the shared responsibility model — the provider secures the infrastructure, the customer secures what they put in it and who they let near it. Even in SaaS, you own the sharing settings and the accounts.

**A17.** They gained the **infrastructure** benefits: no hardware refresh, capacity on demand, global regions, CapEx→OpEx, and the ability to scale a VM in minutes. They did **not** gain the operational benefits above the hypervisor line — they still patch 300 operating systems, still size machines, still carry that toil in headcount. Lift-and-shift is a valid first step (it stops the bleeding of a datacentre lease) but it is a change of *location*, not of *operating model*; the modernisation benefit arrives only when workloads move up the ladder.

### Exercise 4

**A18.** No — it is the model working exactly as designed. Google's responsibility is that the IAM system faithfully enforces the policy you set, that the API authenticates you, and that the infrastructure is secure. Your responsibility is the policy itself. The provider will not second-guess an authorised administrator's explicit grant. (This is also why *shared fate* exists: `storage.publicAccessPrevention` as an Organization Policy constraint, and Security Command Center findings, are Google making the mistake harder to make — while leaving the decision yours.)

**A19.** *Shared responsibility* draws the line: here is what the provider secures, here is what you secure — the customer is then on their own on their side. *Shared fate* is Google taking active co-responsibility for your success on your side of the line: secure-by-default configurations, blueprints, Assured Workloads, risk-protection insurance, and recommenders — so the secure path is the easy path. A concrete artefact of the second: the **Risk Protection Program** / cyber-insurance offering, or the security foundations blueprint — neither makes sense under pure shared responsibility.

**A20.** 99.9% of a 30-day month permits about **43 minutes 12 seconds** of downtime (30 × 24 × 60 × 0.001). An SLA is a **financial credit** mechanism: if the provider misses the target, you receive a percentage credit against your bill. It does not guarantee your service stays up, and the credit will never approach the revenue lost by an outage. Availability is therefore something you *architect* (multi-zone, multi-region, graceful degradation) and the SLA is what you *fall back on* — which is exactly why the 99.99% tier requires you to deploy across zones.

### Exercise 5

**A21.** The MIG bills 730 hours per month regardless of traffic. The Cloud Run service bills roughly 4 h × ~21 business days ≈ **84 hours** of active time — about 11% of the wall clock — and nothing for the remaining ~89%. Same workload, an order-of-magnitude difference in cost, arising purely from whether the idle floor is 1 or 0.

**A22.** Scale-out protects **user experience**: under load, being late is being down, so the autoscaler reacts fast and errs toward over-provisioning. Scale-in protects **stability**: aggressive removal risks flapping (thrash between sizes), terminating instances mid-request, and repeatedly paying cold-start cost. Since over-provisioning for ten extra minutes is cheap and a flapping fleet is expensive in both money and reliability, the damping is deliberate — the `coolDownPeriodSec` and the stabilisation window encode exactly that asymmetry.

**A23.** (1) **`maxNumReplicas` / `--max-instances`** — a hard ceiling that makes worst-case cost computable (`max × unit price × hours`); the trade-off is that traffic beyond the ceiling is queued, throttled or dropped, so you have converted a cost risk into an availability risk. (2) **Committed use discounts sized to the demand floor** — commit to the baseline, burn on-demand for the peak; the trade-off is paying for the commitment even in a quiet month. The honest framing for finance: you can have a *cost ceiling* or *unlimited elasticity*, not both.

**A24.** **Scalability** is the capacity to handle growth — add nodes, get more throughput; the MIG could go to 4, the datacentre could rack more servers. **Elasticity** is scaling *automatically in both directions* in response to demand, so cost tracks use. An on-premises datacentre can offer scalability (buy and rack more hardware, on a procurement timescale of weeks to months) but **not elasticity**: it can never scale *in*, because releasing a server does not refund it. That one-way ratchet is the structural reason on-premises capacity is sized for peak and idle most of the time.

### Exercise 6

**A25.** No. `private-node` is a workload with **private network addressing** running on **public cloud** — Google-owned, multi-tenant infrastructure. "Private cloud" describes the *ownership and tenancy* of the underlying infrastructure (a datacentre you own or dedicated single-tenant infrastructure such as Google Distributed Cloud), not whether a VM has an external IP. Conflating the two is a classic exam distractor: a VPC gives you private *addressing and isolation* on public cloud, which is a network property, not a deployment model.

**A26.** Deployment model: **hybrid cloud**. Connectivity: **Cloud Interconnect** — Dedicated Interconnect if you can reach a colocation facility, Partner Interconnect otherwise. Reject HA VPN for the single reason that it traverses the **public internet**, so bandwidth and latency are best-effort and unpredictable, and per-tunnel throughput is capped — unacceptable for continuously shipping large ledger volumes into a training pipeline. (Encryption is *not* the reason to reject it — HA VPN is encrypted; Interconnect is private but unencrypted by default, and adds MACsec or application-layer encryption if required.)

**A27.** Counter-argument: multicloud usually **trades vendor lock-in for complexity lock-in** — you now run to the lowest common denominator of services, duplicate skills, tooling, security posture and compliance evidence across providers, and pay egress to move data between them; the portability you bought is often never exercised, while the cost is paid every day. The CIO is **right** when the driver is not philosophical but factual: a regulatory requirement for provider diversity (as in some financial-services jurisdictions), a merger that arrived with a second cloud already in production, or a specific best-in-class service that exists on only one provider.

**A28.** Because **ingress is generally free and egress is not**, so cost accrues on the direction nobody budgets for. Designs that look symmetric on a diagram are not symmetric on the invoice: a hybrid analytics pipeline pulling data from cloud back to on-prem, a multicloud design with a database on one provider and compute on another, or a chatty microservice mesh spanning providers, all generate continuous cross-boundary egress. The surprise compounds because the volume scales with *usage growth*, which is exactly what success looks like — so the bill grows fastest right when the project is being declared a win. Mitigations: co-locate compute with data, use Cloud Interconnect (which carries lower egress rates than internet egress), cache aggressively, and measure egress explicitly in the TCO model rather than leaving it as a footnote.

### Exercise 7

**A29.** **"Refresh/disposal at end of life"** and **"Rack, power, cooling"** (the DR-site and colo lines are closely related). Their disappearance shows that on-premises infrastructure is bought as a **depreciating physical asset on a refresh cycle**, with an entire supporting apparatus — space, power, cooling, disposal, and the capacity planning that must predict demand 3–5 years out. What the organization is really buying in the cloud is not "servers, cheaper"; it is the **removal of the asset lifecycle** and of the obligation to forecast capacity years in advance.

**A30.** The principle: **eliminate before you discount.** A discount on a resource you did not need is still money spent. Apply in order: (1) **delete** what is unused — orphaned disks, idle IPs, forgotten dev environments; (2) **right-size** to measured utilisation; (3) **reschedule** — turn off non-production outside business hours; (4) **re-architect** where the win is structural — move to managed/serverless so idle costs nothing; (5) **then** commit — apply CUDs to the demand floor that survives steps 1–4, and Spot to the fault-tolerant tier. Committing first locks in your current waste for three years.

**A31.** When **demand is uncertain or the architecture is about to change.** Concretely: you are mid-migration and expect to re-architect onto serverless or managed services within a year; the business is seasonal or in a volatile market; the product may be discontinued; or a merger could relocate the workload. A resource-based CUD bills whether or not you consume it and is region- and resource-family-scoped, so a 3-year commitment against a fleet you plan to shrink or move converts a variable cost right back into a fixed one — surrendering the exact flexibility that justified the move to cloud. Flexible (spend-based) CUDs mitigate this partially by following spend across services rather than pinning a machine family.

**A32.** **Balance-sheet consequence:** spend moves off the balance sheet as a capitalised, depreciated asset and onto the P&L as a monthly operating expense. Cash is not tied up for years in advance, and cost aligns in time with the revenue the workload generates — though the organization also loses the depreciation shield and gains a recurring commitment that never ends. **Behavioural consequence:** infrastructure becomes a self-service decision made in seconds by an engineer instead of a procurement cycle approved by a committee. That is the productivity unlock and the governance risk simultaneously — which is precisely why budgets, quotas, labels and showback (Exercise 0) are not bureaucracy but the control system that makes OpEx safe.

**A33.** Two likely reasons and how to test each. (1) **The workload was not modelled honestly** — the cloud side assumes right-sizing to 26 VMs and prices only compute, omitting storage, egress, load balancing, backup, licences and non-production environments. *Test:* rebuild the estimate from a real inventory in the Pricing Calculator with every SKU the workload touches, and reconcile against a month of actual billing export in BigQuery after a pilot migration. (2) **The comparison is not like-for-like** — the on-premises figure includes DR, staff and facilities, while the cloud figure quietly assumes those become free; in reality cloud operations, FinOps, security tooling and the one-time migration project all cost money. *Test:* add a migration line item and a cloud-operations FTE line to the cloud side, and check whether the on-prem hardware is already **sunk cost** — if it is paid for and has two years of life left, the near-term comparison is against marginal running cost only, and the honest answer may be to migrate at the refresh boundary rather than immediately.

</details>

---

### Sources

- [Cloud Digital Leader exam guide (official PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)
- [NIST SP 800-145 — The NIST Definition of Cloud Computing](https://csrc.nist.gov/pubs/sp/800/145/final)
- [Geography and regions](https://cloud.google.com/docs/geography-and-regions) · [Regions and zones](https://cloud.google.com/compute/docs/regions-zones) · [Cloud locations](https://cloud.google.com/about/locations)
- [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate) · [Google Cloud SLAs](https://cloud.google.com/terms/sla/) · [Compute Engine SLA](https://cloud.google.com/compute/sla)
- [Cloud Billing Catalog API](https://cloud.google.com/billing/v1/how-tos/catalog-api) · [Pricing Calculator](https://cloud.google.com/products/calculator) · [Budgets and alerts](https://cloud.google.com/billing/docs/how-to/budgets) · [Billing export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery)
- [Sustained use discounts](https://cloud.google.com/compute/docs/sustained-use-discounts) · [Committed use discounts](https://cloud.google.com/docs/cuds) · [Spot VMs](https://cloud.google.com/compute/docs/instances/spot)
- [Autoscaling groups of instances](https://cloud.google.com/compute/docs/autoscaler) · [Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling) · [What is Cloud Run](https://cloud.google.com/run/docs/overview/what-is-cloud-run)
- [VPC overview](https://cloud.google.com/vpc/docs/overview) · [Private Google Access](https://cloud.google.com/vpc/docs/private-google-access) · [Cloud Interconnect](https://cloud.google.com/network-connectivity/docs/interconnect/concepts/overview) · [Cloud VPN](https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview)
- [GKE Enterprise overview](https://cloud.google.com/kubernetes-engine/enterprise/docs/concepts/overview) · [Google Distributed Cloud](https://cloud.google.com/distributed-cloud) · [BigQuery Omni](https://cloud.google.com/bigquery/docs/omni-introduction)
- [gcping — latency measurement tool](https://github.com/GoogleCloudPlatform/gcping) · [gcping.com](https://gcping.com)