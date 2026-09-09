# Guided Exercises — Topic 1.1
## Explain why and how the cloud is revolutionizing businesses
**Certification:** Google Cloud Digital Leader (exam guide version 2026-08-12) · **Exam weight:** 9.0

---

## What this exercise set is for

The Cloud Digital Leader exam asks *business* questions, but it grades you on whether you understand the *mechanics* underneath them. "The cloud turns CapEx into OpEx" is a slogan until you have queried a price out of the Cloud Billing Catalog API, built a cost-per-delivered-vCPU-hour model, watched a service scale to zero, and found the point where the on-premises answer actually wins.

These exercises are executable. You will run real `gcloud` commands against a real project and read real numbers. Everywhere a number appears in an expected output, treat it as **representative** — list prices, region counts and carbon figures change, and reading the live value *is the exercise*.

**Primary reference:** [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

---

## Prerequisites and cost control

Before starting:

1. A Google Cloud project with a billing account attached (a free-trial account works).
2. `gcloud` CLI ≥ 460.0.0 installed and authenticated, plus `jq`, `curl`, `python3`, and `bq`.
3. Roles on the project: `roles/owner` or the combination `roles/billing.viewer` + `roles/run.admin` + `roles/compute.admin` + `roles/monitoring.viewer`.

> **Cost warning.** Exercises 3, 4 and 6 create billable resources. Everything here is designed to fit inside the [Google Cloud Free Tier](https://cloud.google.com/free/docs/free-cloud-features) (Cloud Run: 2M requests, 180,000 vCPU-seconds, 360,000 GiB-seconds/month; Compute Engine: one `e2-micro` in `us-west1`, `us-central1` or `us-east1`). Expect well under **US$1** if you complete the teardown in Exercise 10 the same day. Exercise 9 deliberately marks the Global External Application Load Balancer as **paper-only** because a forwarding rule bills per hour whether traffic flows or not.

Set your working variables once:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
export BILLING_ACCOUNT="$(gcloud billing accounts list \
  --filter='open=true' --format='value(name)' --limit=1 | sed 's|billingAccounts/||')"

echo "project=$PROJECT_ID region=$REGION billing=$BILLING_ACCOUNT"
```

Representative output:

```
project=cdl-lab-471203 region=us-central1 billing=01A2B3-C4D5E6-F7G8H9
```

If `BILLING_ACCOUNT` is empty, you have no billing account you can read — stop and fix that first, because six of the ten exercises depend on it.

---

## Exercise 1 — The unit of cost: turning a hardware purchase into a price query

The single most important mechanical difference between the two models is *granularity*. On-premises, the smallest thing you can buy is a server, and you buy it once, for years. In the cloud, the smallest thing you can buy is a **SKU × unit of consumption**, and the price is a public API.

### Steps

1. Enable the Cloud Billing Catalog API:

    ```bash
    gcloud services enable cloudbilling.googleapis.com --project="$PROJECT_ID"
    ```

2. List the billable services. Every Google Cloud product has a stable service ID:

    ```bash
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://cloudbilling.googleapis.com/v1/services?pageSize=200" \
    | jq -r '.services[] | [.serviceId, .displayName] | @tsv' \
    | sort -k2 | head -20
    ```

    Representative output:

    ```
    2062-016F-44A2	AI Platform
    5AD9-C69C-B617	Access Approval
    6F81-5844-456A	Compute Engine
    9662-B51E-5089	Cloud Storage
    152E-C115-5142	Cloud Run
    ...
    ```

    Note `6F81-5844-456A` — Compute Engine. That ID is a constant; you will reuse it.

3. Pull the on-demand price of one N2 vCPU-hour and one N2 GiB-hour in the Americas:

    ```bash
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=5000" \
    | jq -r '
        .skus[]
        | select(.category.usageType == "OnDemand")
        | select(.description | test("^N2 Instance (Core|Ram) running in Americas$"))
        | [ .description,
            .pricingInfo[0].pricingExpression.usageUnitDescription,
            ( (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.units | tonumber)
              + (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos / 1e9) )
          ] | @tsv'
    ```

    Representative output:

    ```
    N2 Instance Core running in Americas	hour	0.031611
    N2 Instance Ram running in Americas	gibibyte hour	0.004237
    ```

4. Compute the list price of an `n2-standard-8` (8 vCPU, 32 GiB) for one hour, and for one year running continuously:

    ```bash
    python3 - <<'PY'
    vcpu_h, gib_h = 0.031611, 0.004237      # <-- replace with YOUR values from step 3
    hourly = 8 * vcpu_h + 32 * gib_h
    print(f"n2-standard-8  hourly = ${hourly:.6f}")
    print(f"n2-standard-8  1 year = ${hourly * 8760:,.2f}")
    print(f"n2-standard-8  1 hour of a 4-hour daily peak, for a year = ${hourly * 4 * 365:,.2f}")
    PY
    ```

    Representative output:

    ```
    n2-standard-8  hourly = $0.388472
    n2-standard-8  1 year = $3,402.02
    n2-standard-8  1 hour of a 4-hour daily peak, for a year = $567.17
    ```

5. Now find the *same* capacity as a Spot VM, which is the same hardware with a preemption contract attached:

    ```bash
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?pageSize=5000" \
    | jq -r '
        .skus[]
        | select(.category.usageType == "Preemptible")
        | select(.description | test("^Spot Preemptible N2 Instance (Core|Ram) running in Americas$"))
        | [ .description,
            ( (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.units | tonumber)
              + (.pricingInfo[0].pricingExpression.tieredRates[0].unitPrice.nanos / 1e9) )
          ] | @tsv'
    ```

    Representative output:

    ```
    Spot Preemptible N2 Instance Core running in Americas	0.007533
    Spot Preemptible N2 Instance Ram running in Americas	0.001010
    ```

**Sources:** [Cloud Billing Catalog API](https://cloud.google.com/billing/v1/how-tos/catalog-api) · [Compute Engine pricing](https://cloud.google.com/compute/all-pricing) · [Spot VMs](https://cloud.google.com/compute/docs/instances/spot)

### Check your understanding — Block 1

1. **Q1.1** — In step 4, the same machine costs $3,402 running all year and $567 running four hours a day. Nothing about the hardware changed. What business capability does that ratio represent, and why is it structurally impossible to obtain from a purchased server?
2. **Q1.2** — The Spot price in step 5 is roughly 76% below on-demand for identical hardware. What is the customer actually paying less *for*? Name one workload class where that discount is free money and one where it is unusable.
3. **Q1.3** — A CFO asks: "Why do we need an API for prices? Vendors send quotes." Give the operational reason a public, machine-readable price catalog changes how architecture decisions get made.
4. **Q1.4** — The SKU for vCPU and the SKU for RAM are billed separately and independently. What architectural freedom does that decomposition create that a fixed 1U server catalogue does not?

---

## Exercise 2 — Build the TCO model, then find where it flips

Most "cloud is cheaper" claims compare the wrong quantities: a *provisioned* on-premises cost against a *consumed* cloud cost. The honest metric is **cost per delivered vCPU-hour** — cost divided by capacity that actually did work.

### Steps

1. Create the model. Save as `tco.py`:

    ```python
    #!/usr/bin/env python3
    """Cost per DELIVERED vCPU-hour: on-premises vs Google Cloud.
    Every input is an assumption. Change them and re-run; that is the point."""

    # ---------- workload ----------
    SERVERS         = 24
    VCPU_PER_SERVER = 32
    GIB_PER_VCPU    = 4

    # ---------- on-premises assumptions ----------
    SERVER_CAPEX     = 9_500      # USD per server
    REFRESH_YEARS    = 4
    ARRAY_CAPEX      = 180_000    # storage + top-of-rack + core switching
    ARRAY_YEARS      = 5
    RACKS            = 3
    COLO_PER_RACK_MO = 1_200
    KW_DRAWN         = 6.0        # average IT load
    PUE              = 1.6
    KWH_PRICE        = 0.14
    OPS_FTE          = 1.5
    FTE_LOADED       = 130_000
    LICENSING_YR     = 28_000
    ONPREM_UTIL      = 0.22       # classic steady-state utilisation

    # ---------- cloud assumptions (replace with YOUR Exercise 1 values) ----------
    VCPU_HOUR   = 0.031611
    GIB_HOUR    = 0.004237
    CUD_3YR     = 0.55            # 3-year resource-based commitment discount
    CLOUD_UTIL  = 0.65            # achievable with autoscaling
    CLOUD_OPS_FTE = 0.75
    CLOUD_STORAGE_EGRESS_YR = 60_000

    # ---------- on-premises ----------
    onprem = {
        "hardware":  SERVERS * SERVER_CAPEX / REFRESH_YEARS,
        "array":     ARRAY_CAPEX / ARRAY_YEARS,
        "colo":      RACKS * COLO_PER_RACK_MO * 12,
        "power":     KW_DRAWN * PUE * 8760 * KWH_PRICE,
        "ops":       OPS_FTE * FTE_LOADED,
        "licensing": LICENSING_YR,
    }
    onprem_yr   = sum(onprem.values())
    provisioned = SERVERS * VCPU_PER_SERVER * 8760
    delivered   = provisioned * ONPREM_UTIL

    # ---------- cloud: same DELIVERED capacity ----------
    unit_ondemand = VCPU_HOUR + GIB_PER_VCPU * GIB_HOUR
    unit_cud      = unit_ondemand * (1 - CUD_3YR)
    cloud_provisioned = delivered / CLOUD_UTIL
    cloud = {
        "compute": cloud_provisioned * unit_cud,
        "ops":     CLOUD_OPS_FTE * FTE_LOADED,
        "storage_egress": CLOUD_STORAGE_EGRESS_YR,
    }
    cloud_yr = sum(cloud.values())

    def show(label, breakdown, total, prov):
        print(f"\n=== {label} ===")
        for k, v in breakdown.items():
            print(f"  {k:<16} ${v:>12,.0f}/yr")
        print(f"  {'TOTAL':<16} ${total:>12,.0f}/yr")
        print(f"  provisioned vCPU-h {prov:>14,.0f}")
        print(f"  delivered   vCPU-h {delivered:>14,.0f}")
        print(f"  $/provisioned vCPU-h  ${total/prov:.4f}")
        print(f"  $/DELIVERED   vCPU-h  ${total/delivered:.4f}")

    show("ON-PREMISES", onprem, onprem_yr, provisioned)
    show("GOOGLE CLOUD", cloud, cloud_yr, cloud_provisioned)
    print(f"\nDelta: ${onprem_yr - cloud_yr:,.0f}/yr "
          f"({100*(onprem_yr-cloud_yr)/onprem_yr:.1f}% lower)")
    ```

2. Run it:

    ```bash
    python3 tco.py
    ```

    Representative output:

    ```
    === ON-PREMISES ===
      hardware         $      57,000/yr
      array            $      36,000/yr
      colo             $      43,200/yr
      power            $      11,773/yr
      ops              $     195,000/yr
      licensing        $      28,000/yr
      TOTAL            $     370,973/yr
      provisioned vCPU-h      6,727,680
      delivered   vCPU-h      1,480,090
      $/provisioned vCPU-h  $0.0551
      $/DELIVERED   vCPU-h  $0.2506

    === GOOGLE CLOUD ===
      compute          $      49,754/yr
      ops              $      97,500/yr
      storage_egress   $      60,000/yr
      TOTAL            $     207,254/yr
      provisioned vCPU-h      2,277,062
      delivered   vCPU-h      1,480,090
      $/provisioned vCPU-h  $0.0910
      $/DELIVERED   vCPU-h  $0.1400

    Delta: $163,719/yr (44.1% lower)
    ```

3. **Read the paradox.** Per *provisioned* vCPU-hour the cloud is 65% **more expensive** ($0.0910 vs $0.0551). Per *delivered* vCPU-hour it is 44% cheaper. Confirm you can explain that before continuing.

4. **Break the model.** Re-run four times, changing one input each time, and record the delta:

    ```bash
    sed -i 's/^ONPREM_UTIL.*/ONPREM_UTIL      = 0.70/'  tco.py && python3 tco.py | tail -2
    sed -i 's/^ONPREM_UTIL.*/ONPREM_UTIL      = 0.22/'  tco.py
    sed -i 's/^REFRESH_YEARS.*/REFRESH_YEARS    = 7/'   tco.py && python3 tco.py | tail -2
    sed -i 's/^REFRESH_YEARS.*/REFRESH_YEARS    = 4/'   tco.py
    sed -i 's/^OPS_FTE.*/OPS_FTE          = 0.5/'       tco.py && python3 tco.py | tail -2
    sed -i 's/^OPS_FTE.*/OPS_FTE          = 1.5/'       tco.py
    sed -i 's/^CUD_3YR.*/CUD_3YR     = 0.0/'            tco.py && python3 tco.py | tail -2
    sed -i 's/^CUD_3YR.*/CUD_3YR     = 0.55/'           tco.py
    ```

5. Verify the discount you assumed is real. Committed use discounts are documented, not negotiated:

    ```bash
    gcloud compute commitments list --project="$PROJECT_ID"   # empty in a lab project
    ```

    ```
    Listed 0 items.
    ```

    Read the published rates instead: 1-year commitments reach roughly 37% and 3-year roughly 55% for general-purpose resource-based commitments. Sustained use discounts (automatic, no commitment) reach roughly 20–30% depending on machine family, and **do not stack** with CUDs.

**Sources:** [Committed use discounts](https://cloud.google.com/docs/cuds) · [Sustained use discounts](https://cloud.google.com/compute/docs/sustained-use-discounts) · [Google Cloud pricing philosophy](https://cloud.google.com/pricing)

### Check your understanding — Block 2

1. **Q2.1** — Explain the paradox in step 3 in one sentence a CFO would accept: how is the cloud simultaneously more expensive per unit and cheaper overall?
2. **Q2.2** — In step 4, which single input change came closest to erasing the cloud advantage? What real-world organisation does that input describe?
3. **Q2.3** — A 3-year committed use discount locks spend for three years. Argue that a CUD is a CapEx-shaped instrument sold under an OpEx contract. Does buying one forfeit the elasticity benefit? Be precise.
4. **Q2.4** — The on-premises model charges 1.5 FTE and the cloud model 0.75 FTE. A sceptical infrastructure lead says this is the author putting a thumb on the scale. What concrete work disappears, and what new work appears, in the cloud column?
5. **Q2.5** — Name two cost categories that appear in *neither* column but materially affect a real migration decision.

---

## Exercise 3 — Elasticity you can observe: scale to zero and back

Elasticity is the property that makes the Exercise 2 numbers possible. Here you will watch capacity appear and disappear in seconds.

### Steps

1. Enable and deploy Google's sample container to Cloud Run:

    ```bash
    gcloud services enable run.googleapis.com --project="$PROJECT_ID"

    gcloud run deploy elasticity-demo \
      --image=us-docker.pkg.dev/cloudrun/container/hello \
      --region="$REGION" \
      --allow-unauthenticated \
      --min-instances=0 \
      --max-instances=20 \
      --cpu=1 --memory=512Mi \
      --project="$PROJECT_ID"
    ```

    Representative output:

    ```
    Deploying container to Cloud Run service [elasticity-demo] in project [cdl-lab-471203] region [us-central1]
    ✓ Deploying new service... Done.
      ✓ Creating Revision...
      ✓ Routing traffic...
      ✓ Setting IAM Policy...
    Done.
    Service [elasticity-demo] revision [elasticity-demo-00001-abc] has been deployed
    and is serving 100 percent of traffic.
    Service URL: https://elasticity-demo-a1b2c3d4e5-uc.a.run.app
    ```

2. Capture the URL and confirm the service answers:

    ```bash
    export SVC_URL="$(gcloud run services describe elasticity-demo \
      --region="$REGION" --format='value(status.url)')"

    curl -s -o /dev/null -w "http=%{http_code} total=%{time_total}s\n" "$SVC_URL"
    ```

3. Measure the **cold start** — the honest cost of scale-to-zero. Wait for the service to idle out, then hit it once:

    ```bash
    echo "waiting 15 minutes for the instance to be reclaimed..."; sleep 900
    curl -s -o /dev/null -w "COLD  total=%{time_total}s\n" "$SVC_URL"
    curl -s -o /dev/null -w "WARM  total=%{time_total}s\n" "$SVC_URL"
    ```

    Representative output:

    ```
    COLD  total=1.284051s
    WARM  total=0.061733s
    ```

4. Generate a burst and watch instances materialise. Fifty concurrent clients for 30 seconds:

    ```bash
    seq 1 50 | xargs -P 50 -I{} sh -c \
      'end=$(( $(date +%s) + 30 )); while [ $(date +%s) -lt $end ]; do curl -s -o /dev/null '"$SVC_URL"'; done'
    ```

5. Read the actual instance count from Cloud Monitoring — not the console, the API:

    ```bash
    gcloud services enable monitoring.googleapis.com --project="$PROJECT_ID"

    END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    START="$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -G "https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/timeSeries" \
      --data-urlencode 'filter=metric.type="run.googleapis.com/container/instance_count" AND resource.labels.service_name="elasticity-demo"' \
      --data-urlencode "interval.startTime=$START" \
      --data-urlencode "interval.endTime=$END" \
      --data-urlencode 'aggregation.alignmentPeriod=60s' \
      --data-urlencode 'aggregation.perSeriesAligner=ALIGN_MAX' \
    | jq -r '.timeSeries[] | .metric.labels.state as $s
             | .points[] | [$s, .interval.endTime, .value.doubleValue] | @tsv' \
    | sort -k2
    ```

    Representative output:

    ```
    idle	2026-09-06T14:31:00Z	0
    active	2026-09-06T14:31:00Z	0
    active	2026-09-06T14:38:00Z	11
    idle	2026-09-06T14:38:00Z	2
    active	2026-09-06T14:39:00Z	0
    idle	2026-09-06T14:39:00Z	3
    active	2026-09-06T14:52:00Z	0
    idle	2026-09-06T14:52:00Z	0
    ```

6. Now buy away the cold start and read the price of that decision:

    ```bash
    gcloud run services update elasticity-demo \
      --region="$REGION" --min-instances=2 --project="$PROJECT_ID"

    gcloud run services describe elasticity-demo --region="$REGION" \
      --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])"
    ```

    ```
    2
    ```

7. Reset it, so the teardown is clean and the free tier is preserved:

    ```bash
    gcloud run services update elasticity-demo --region="$REGION" --min-instances=0
    ```

**Sources:** [Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling) · [Cloud Run pricing](https://cloud.google.com/run/pricing) · [Cloud Run metrics](https://cloud.google.com/monitoring/api/metrics_gcp#gcp-run)

### Check your understanding — Block 3

1. **Q3.1** — In step 5 the instance count went from 0 to 11 and back to 0 inside ~15 minutes. Restate that as a *procurement* statement: what would the equivalent on-premises transaction have been, and how long would it have taken?
2. **Q3.2** — Step 3 shows a cold request taking ~20× longer than a warm one. Setting `--min-instances=2` removes it. Describe the trade-off in the exact terms the exam uses, and say which stakeholder owns the decision.
3. **Q3.3** — `--max-instances=20` was set explicitly. In an elastic platform, why would anyone cap the ceiling? Give both the cost reason and the correctness reason.
4. **Q3.4** — The metric is split into `active` and `idle` states. Why does Cloud Run's default request-based billing model make that distinction financially meaningful, and what changes under instance-based billing?
5. **Q3.5** — A team argues elasticity is irrelevant because their traffic is perfectly flat 24/7. Give two ways elasticity still delivers value to them.

---

## Exercise 4 — Global reach as a configuration value

"Enter a new market" used to mean signing a data-centre lease. Here it is a flag.

### Steps

1. Count the footprint you can reach right now:

    ```bash
    gcloud compute regions list --format='value(name)' | wc -l
    gcloud compute zones list --format='value(name)' | wc -l
    gcloud compute regions list --format='table(name, description, status)' | head -12
    ```

    Representative output:

    ```
    43
    132
    NAME                     DESCRIPTION                          STATUS
    africa-south1            Johannesburg, South Africa           UP
    asia-east1               Changhua County, Taiwan              UP
    asia-northeast1          Tokyo, Japan                         UP
    australia-southeast1     Sydney, Australia                    UP
    europe-west1             St. Ghislain, Belgium                UP
    ...
    ```

    Record *your* two numbers — they are higher than the ones printed here.

2. Deploy the identical service into three continents. This is the whole market-entry exercise:

    ```bash
    for R in us-central1 europe-west1 asia-northeast1; do
      gcloud run deploy reach-demo \
        --image=us-docker.pkg.dev/cloudrun/container/hello \
        --region="$R" --allow-unauthenticated --min-instances=0 \
        --project="$PROJECT_ID" --quiet
    done
    ```

3. Measure what your users would feel from where you are sitting:

    ```bash
    for R in us-central1 europe-west1 asia-northeast1; do
      U="$(gcloud run services describe reach-demo --region="$R" --format='value(status.url)')"
      curl -s -o /dev/null "$U"    # warm it
      printf "%-18s " "$R"
      curl -s -o /dev/null -w "connect=%{time_connect}s  ttfb=%{time_starttransfer}s\n" "$U"
    done
    ```

    Representative output (measured from South America):

    ```
    us-central1        connect=0.142s  ttfb=0.298s
    europe-west1       connect=0.231s  ttfb=0.462s
    asia-northeast1    connect=0.318s  ttfb=0.641s
    ```

4. Inspect the network product you are implicitly buying:

    ```bash
    gcloud compute project-info describe --project="$PROJECT_ID" \
      --format="value(defaultNetworkTier)"
    ```

    ```
    PREMIUM
    ```

    Premium Tier carries traffic across Google's private backbone from the point of presence nearest the user; Standard Tier hands it to the public internet at the region. That is a per-project, per-resource *pricing and performance* choice, not a data-centre build.

5. Confirm the residency dimension. Regions are not interchangeable when law is involved:

    ```bash
    gcloud compute regions list --filter='name~^europe' --format='value(name, description)'
    ```

    ```
    europe-central2   Warsaw, Poland
    europe-north1     Hamina, Finland
    europe-southwest1 Madrid, Spain
    europe-west1      St. Ghislain, Belgium
    europe-west3      Frankfurt, Germany
    europe-west4      Eemshaven, Netherlands
    europe-west9      Paris, France
    ...
    ```

**Sources:** [Geography and regions](https://cloud.google.com/docs/geography-and-regions) · [Regions and zones](https://cloud.google.com/compute/docs/regions-zones) · [Network Service Tiers](https://cloud.google.com/network-tiers/docs/overview)

### Check your understanding — Block 4

1. **Q4.1** — Step 2 put a production-capable service in three continents in under two minutes at effectively zero fixed cost. Write the business-case sentence this replaces, and identify which class of company benefits *disproportionately*.
2. **Q4.2** — A zone and a region are not the same failure domain. Define each, and state what a "multi-region" deployment protects against that a "multi-zone" deployment does not.
3. **Q4.3** — Standard Tier is cheaper than Premium Tier for the same bytes. Name a workload where choosing Standard is correct engineering rather than corner-cutting.
4. **Q4.4** — Step 5 lists seven European regions in seven countries. Give two distinct business reasons — one regulatory, one commercial — for choosing `europe-west9` over the cheaper `europe-west4`.
5. **Q4.5** — Latency in step 3 correlates with physical distance. What does that tell you about the limits of "the cloud is everywhere"?

---

## Exercise 5 — Service models: what you are actually buying

IaaS / PaaS / SaaS is an exam-guide vocabulary item, but it is really a question about *where the responsibility boundary sits*. Run the same trivial workload two ways and look at the boundary directly.

### Steps

1. **IaaS.** Create a VM and note everything you now own:

    ```bash
    gcloud services enable compute.googleapis.com --project="$PROJECT_ID"

    gcloud compute instances create iaas-demo \
      --zone="${REGION}-a" \
      --machine-type=e2-micro \
      --image-family=debian-12 --image-project=debian-cloud \
      --boot-disk-size=10GB \
      --project="$PROJECT_ID"
    ```

    Representative output:

    ```
    Created [.../zones/us-central1-a/instances/iaas-demo].
    NAME       ZONE           MACHINE_TYPE  INTERNAL_IP  EXTERNAL_IP    STATUS
    iaas-demo  us-central1-a  e2-micro      10.128.0.7   34.72.101.204  RUNNING
    ```

2. Enumerate the surface you inherited:

    ```bash
    gcloud compute ssh iaas-demo --zone="${REGION}-a" --command='
      echo "--- kernel ---";  uname -r
      echo "--- distro ---";  . /etc/os-release && echo "$PRETTY_NAME"
      echo "--- pending security updates ---"
      sudo apt-get -qq update >/dev/null 2>&1
      apt list --upgradable 2>/dev/null | grep -ci security || echo 0
      echo "--- listening sockets ---"; sudo ss -tlnp | tail -n +2 | wc -l
      echo "--- uptime you must manage ---"; uptime -p'
    ```

    Representative output:

    ```
    --- kernel ---
    6.1.0-23-cloud-amd64
    --- distro ---
    Debian GNU/Linux 12 (bookworm)
    --- pending security updates ---
    7
    --- listening sockets ---
    4
    --- uptime you must manage ---
    up 3 minutes
    ```

3. **PaaS / serverless.** Ask the same questions of the Cloud Run service from Exercise 3:

    ```bash
    gcloud run services describe elasticity-demo --region="$REGION" --format=yaml \
      | grep -Ei 'kernel|osImage|patch|sshKey' || echo "no OS surface is exposed — there is nothing here to patch"
    ```

    ```
    no OS surface is exposed — there is nothing here to patch
    ```

4. Compare the operational contract quantitatively:

    ```bash
    echo "--- IaaS knobs you own ---"
    gcloud compute instances describe iaas-demo --zone="${REGION}-a" --format=json \
      | jq '[paths(scalars)] | length'

    echo "--- PaaS knobs you own ---"
    gcloud run services describe elasticity-demo --region="$REGION" --format=json \
      | jq '[paths(scalars)] | length'
    ```

    Representative output:

    ```
    --- IaaS knobs you own ---
    213
    --- PaaS knobs you own ---
    97
    ```

    The count is a proxy, not a law — but the direction is the lesson.

5. **SaaS.** You have been using one all along. `gcloud`, the Cloud Console and the Billing API are Google-operated software you consume without provisioning anything:

    ```bash
    gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)' | head
    ```

    ```
    bigquery.googleapis.com
    cloudbilling.googleapis.com
    compute.googleapis.com
    logging.googleapis.com
    monitoring.googleapis.com
    run.googleapis.com
    ```

    You did not install, patch, scale or back up any of these.

**Sources:** [What is IaaS](https://cloud.google.com/learn/what-is-iaas) · [What is PaaS](https://cloud.google.com/learn/what-is-paas) · [What is SaaS](https://cloud.google.com/learn/what-is-saas) · [Cloud Run overview](https://cloud.google.com/run/docs/overview/what-is-cloud-run)

### Check your understanding — Block 5

1. **Q5.1** — Step 2 found 7 pending security updates on a VM three minutes old. Step 3 found no OS surface at all. Restate this as the definition of the IaaS/PaaS boundary, without using the words "IaaS" or "PaaS".
2. **Q5.2** — Order IaaS, PaaS and SaaS by (a) customer control and (b) customer operational burden. What is the relationship between the two orderings, and why is that the entire trade?
3. **Q5.3** — A team wants PaaS-level operations but has a licensed application requiring a specific kernel module. Which model must they use, and what is the honest cost of that constraint?
4. **Q5.4** — Migrating a VM to Google Cloud unchanged ("lift and shift") lands in IaaS. What portion of the Exercise 2 savings does that capture, and what portion does it leave on the table?
5. **Q5.5** — Classify each and justify: Compute Engine, Google Kubernetes Engine Autopilot, Cloud Run, BigQuery, Google Workspace. Which one is hardest to classify cleanly, and why is that instructive?

---

## Exercise 6 — Shared responsibility, and Google's shared fate

Every cloud vendor publishes a shared responsibility model. Google adds **shared fate**: rather than drawing the line and stepping back, Google takes an active stake in the customer's side of it.

### Steps

1. Prove the security boundary is real by finding where *your* obligation begins. The VM from Exercise 5 has a default firewall posture — inspect it:

    ```bash
    gcloud compute firewall-rules list \
      --format='table(name, network, direction, sourceRanges.list(), allowed[].map().firewall_rule().list())'
    ```

    Representative output:

    ```
    NAME                    NETWORK  DIRECTION  SRC_RANGES     ALLOW
    default-allow-icmp      default  INGRESS    0.0.0.0/0      icmp
    default-allow-internal  default  INGRESS    10.128.0.0/9   tcp:0-65535,udp:0-65535,icmp
    default-allow-rdp       default  INGRESS    0.0.0.0/0      tcp:3389
    default-allow-ssh       default  INGRESS    0.0.0.0/0      tcp:22
    ```

    Google supplied the network. **You** own the fact that TCP/22 is open to the entire internet.

2. Check who is responsible for OS patching — and confirm Google offers to help without taking the obligation:

    ```bash
    gcloud services enable osconfig.googleapis.com --project="$PROJECT_ID"
    gcloud compute os-config patch-deployments list --project="$PROJECT_ID"
    ```

    ```
    Listed 0 items.
    ```

    Zero. VM Manager exists, is free, and is *opt-in*. Nothing patches until you say so — that is the boundary in one command.

3. Contrast with the managed side. Ask which Cloud Run revision is running and what version of anything underlies it:

    ```bash
    gcloud run revisions list --service=elasticity-demo --region="$REGION" \
      --format='table(name, active, creationTimestamp)'
    ```

    ```
    NAME                        ACTIVE  CREATION_TIMESTAMP
    elasticity-demo-00002-xyz   yes     2026-09-06T14:55:11Z
    elasticity-demo-00001-abc           2026-09-06T14:22:03Z
    ```

    There is no host, kernel or runtime version for you to query, because there is none for you to patch.

4. Inspect the identity boundary — the part that is *always* yours regardless of service model:

    ```bash
    gcloud projects get-iam-policy "$PROJECT_ID" \
      --flatten='bindings[].members' \
      --format='table(bindings.role, bindings.members)' | head -15
    ```

    Representative output:

    ```
    ROLE                            MEMBERS
    roles/owner                     user:villadalmine@gmail.com
    roles/editor                    serviceAccount:471203-compute@developer.gserviceaccount.com
    roles/run.serviceAgent          serviceAccount:service-471203@serverless-robot-prod.iam.gserviceaccount.com
    ```

    Note the default Compute Engine service account holds `roles/editor`. Google created it; you own the decision to leave it that way.

5. Read the shared-fate mechanisms and check which are available to you at no charge:

    ```bash
    gcloud services list --available --filter='config.name~(securitycenter|assuredworkloads|recommender)' \
      --format='value(config.name)' 2>/dev/null
    ```

    ```
    assuredworkloads.googleapis.com
    recommender.googleapis.com
    securitycenter.googleapis.com
    ```

    `recommender.googleapis.com` powers IAM Recommender, which proposes least-privilege role reductions from observed usage — Google analysing *your* side of the boundary and handing you the fix. That is shared fate in practice.

**Sources:** [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate) · [VM Manager](https://cloud.google.com/compute/docs/vm-manager) · [IAM Recommender](https://cloud.google.com/policy-intelligence/docs/role-recommendations-overview)

### Check your understanding — Block 6

1. **Q6.1** — In step 1, Google built a network with `default-allow-ssh` from `0.0.0.0/0`. If that VM is compromised through a weak SSH credential, whose responsibility is the breach under the shared responsibility model? Justify from the model, not from intuition.
2. **Q6.2** — Step 2 shows patching is opt-in. Restate the general rule for how the responsibility boundary moves as you go IaaS → PaaS → SaaS. Which single responsibility never moves?
3. **Q6.3** — Distinguish shared *responsibility* from shared *fate* in one sentence each. Give the concrete example from step 5.
4. **Q6.4** — The default Compute Engine service account holds `roles/editor` (step 4). Why does that default exist, and what does its existence tell you about the vendor's design trade-off between adoption friction and secure defaults?
5. **Q6.5** — An executive says "we moved to the cloud, so security is Google's problem now." Correct them in three sentences, and name one thing that genuinely *did* become Google's problem.

---

## Exercise 7 — The cost feedback loop that CapEx never had

A purchased server's cost is known once, at purchase. A cloud resource's cost is known continuously — and that changes how organisations behave.

### Steps

1. Create a BigQuery dataset to receive the billing export:

    ```bash
    gcloud services enable bigquery.googleapis.com --project="$PROJECT_ID"
    bq --location=US mk --dataset --description "Cloud Billing export" "${PROJECT_ID}:billing_export"
    bq ls --project_id="$PROJECT_ID"
    ```

    ```
      datasetId
     ---------------
      billing_export
    ```

2. **Enable the export.** This step has no `gcloud` equivalent — Cloud Billing export configuration is Console-only. Go to **Billing → Billing export → BigQuery export → Standard usage cost → Edit settings**, select this project and the `billing_export` dataset, and save.

    > Data begins landing within a few hours and is not retroactive. Note the time; you will query it later.

3. Confirm the table appears (re-run after a few hours if empty):

    ```bash
    bq ls --format=prettyjson "${PROJECT_ID}:billing_export" | jq -r '.[].tableReference.tableId'
    ```

    ```
    gcp_billing_export_v1_01A2B3_C4D5E6_F7G8H9
    ```

4. Ask the question no on-premises finance system can answer — cost by service, by day:

    ```bash
    bq query --use_legacy_sql=false --format=pretty "
    SELECT
      service.description         AS service,
      DATE(usage_start_time)      AS day,
      ROUND(SUM(cost), 4)         AS cost_usd,
      ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 4) AS credits_usd
    FROM \`${PROJECT_ID}.billing_export.gcp_billing_export_v1_$(echo "$BILLING_ACCOUNT" | tr '-' '_')\`
    GROUP BY service, day
    ORDER BY day DESC, cost_usd DESC
    LIMIT 20"
    ```

    Representative output:

    ```
    +--------------------+------------+----------+-------------+
    |      service       |    day     | cost_usd | credits_usd |
    +--------------------+------------+----------+-------------+
    | Compute Engine     | 2026-09-06 |   0.0731 |     -0.0731 |
    | Cloud Run          | 2026-09-06 |   0.0042 |     -0.0042 |
    | Networking         | 2026-09-06 |   0.0011 |      0.0    |
    +--------------------+------------+----------+-------------+
    ```

    The `credits_usd` column is the free tier cancelling the charge — the mechanism, made visible.

5. Close the loop with an automated control:

    ```bash
    gcloud services enable billingbudgets.googleapis.com --project="$PROJECT_ID"

    gcloud billing budgets create \
      --billing-account="$BILLING_ACCOUNT" \
      --display-name="cdl-lab-guardrail" \
      --budget-amount=10USD \
      --threshold-rule=percent=0.5 \
      --threshold-rule=percent=0.9 \
      --threshold-rule=percent=1.0 \
      --filter-projects="projects/$PROJECT_ID"
    ```

    Representative output:

    ```
    Created budget [billingAccounts/01A2B3-C4D5E6-F7G8H9/budgets/9f2c1e44-...]
    displayName: cdl-lab-guardrail
    amount:
      specifiedAmount:
        currencyCode: USD
        units: '10'
    thresholdRules:
    - thresholdPercent: 0.5
    - thresholdPercent: 0.9
    - thresholdPercent: 1.0
    ```

6. Verify it exists and understand what it does — and does not — do:

    ```bash
    gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
      --format='table(displayName, amount.specifiedAmount.units, thresholdRules.len())'
    ```

**Sources:** [Export billing data to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery) · [Budgets and alerts](https://cloud.google.com/billing/docs/how-to/budgets) · [Billing export schema](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/standard-usage)

### Check your understanding — Block 7

1. **Q7.1** — Step 4 produced per-service, per-day cost from a live SQL query. Name three organisational decisions this makes possible that annual depreciation schedules do not.
2. **Q7.2** — A budget alert notifies; it does **not** stop spending. Why is that the default, and what would you build to make it enforcing?
3. **Q7.3** — Billing export is not retroactive (step 2). What does that imply about the *first* action to take when a new organisation adopts Google Cloud?
4. **Q7.4** — Explain how this exercise connects back to Exercise 2. What model input becomes *measured* rather than assumed once billing export exists?
5. **Q7.5** — The exam frames this as "operational expenditure enables agility." Using the artefacts you built, explain the causal chain from *granular billing* to *faster product decisions*.

---

## Exercise 8 — Sustainability as a business driver, not a slogan

Carbon reporting has become a procurement requirement in regulated markets. It is also a genuine cloud-versus-on-premises differentiator, because hyperscale efficiency and clean-energy contracting are not reproducible in a leased rack.

### Steps

1. Pull Google's published per-region carbon data — an official, machine-readable, free source:

    ```bash
    curl -sL https://raw.githubusercontent.com/GoogleCloudPlatform/region-carbon-info/main/data/yearly/2023.csv \
      | column -t -s,
    ```

    Representative output (abridged):

    ```
    Region             CFE%   Grid carbon intensity (gCO2eq/kWh)
    europe-north1      0.91   127
    europe-west1       0.85   110
    us-central1        0.64   394
    asia-northeast1    0.28   468
    australia-southeast1 0.24  600
    ```

2. Rank the regions you might actually deploy to, by cleanliness:

    ```bash
    curl -sL https://raw.githubusercontent.com/GoogleCloudPlatform/region-carbon-info/main/data/yearly/2023.csv \
      | tail -n +2 | sort -t, -k2 -rn | head -8 \
      | awk -F, '{printf "%-24s CFE=%.0f%%  grid=%s gCO2eq/kWh\n", $1, $2*100, $3}'
    ```

3. Quantify a workload decision. Take the 1,480,090 delivered vCPU-hours from Exercise 2 and compare two regions:

    ```bash
    python3 - <<'PY'
    DELIVERED_VCPU_H = 1_480_090
    WATTS_PER_VCPU   = 6.0          # rough, for illustration only
    kwh = DELIVERED_VCPU_H * WATTS_PER_VCPU / 1000

    for region, cfe, gco2 in [("europe-north1", 0.91, 127),
                              ("us-central1",   0.64, 394),
                              ("asia-northeast1",0.28, 468)]:
        tonnes = kwh * (1 - cfe) * gco2 / 1e6
        print(f"{region:<18} {kwh:>10,.0f} kWh  ->  {tonnes:>7.1f} tCO2e/yr")
    PY
    ```

    Representative output:

    ```
    europe-north1           8,881 kWh  ->      0.1 tCO2e/yr
    us-central1             8,881 kWh  ->      1.3 tCO2e/yr
    asia-northeast1         8,881 kWh  ->      3.0 tCO2e/yr
    ```

4. Check whether your own account's carbon footprint report is available. Like billing export, it is enabled in the Console (**Billing → Carbon Footprint**) and exported to BigQuery:

    ```bash
    bq ls --format=prettyjson "${PROJECT_ID}:billing_export" 2>/dev/null \
      | jq -r '.[].tableReference.tableId' | grep -i carbon || echo "carbon export not configured"
    ```

5. Note the claims you should be able to state on the exam, and where they are published:
    - Google has matched 100% of its annual global electricity consumption with renewable energy purchases since 2017.
    - Google has been carbon neutral in operations since 2007.
    - The stated goal is to run on 24/7 carbon-free energy in every grid where it operates by 2030.
    - Google Cloud customers inherit these properties by using the platform; the customer's reported Scope 2 emissions for that workload move accordingly.

**Sources:** [Carbon-free energy by region](https://cloud.google.com/sustainability/region-carbon) · [region-carbon-info dataset](https://github.com/GoogleCloudPlatform/region-carbon-info) · [Carbon Footprint](https://cloud.google.com/carbon-footprint) · [Google Sustainability](https://sustainability.google/operating-sustainably/)

### Check your understanding — Block 8

1. **Q8.1** — Step 3 shows a 30× emissions difference for identical compute, decided by one string in a deploy command. What organisational function should own that string, and why is it usually owned by the wrong one?
2. **Q8.2** — Distinguish "carbon neutral" from "24/7 carbon-free energy." Why is the second dramatically harder, and why does it matter to a customer rather than only to Google?
3. **Q8.3** — Region choice trades carbon against latency (Exercise 4) and price (Exercise 1). Construct a case where the *cleanest* region is the wrong choice, and one where it is the right choice despite being slower.
4. **Q8.4** — An on-premises data centre with PUE 1.6 (Exercise 2's assumption) versus a hyperscale facility near 1.1: express that gap as a percentage of total energy and explain what a customer buys that they could not build.
5. **Q8.5** — Why is a *machine-readable* carbon footprint export a different product from a sustainability report PDF?

---

## Exercise 9 — Synthesis: write the business case (paper exercise)

No commands. This is the deliverable a Cloud Digital Leader is actually asked for, and the exam tests whether you can produce it.

### Scenario

**Meridian Freight** is a 40-year-old regional logistics company. 620 employees. Two leased data-centre rooms running ~180 physical servers, average utilisation 19%, hardware refresh due in 11 months at a quoted **US$2.4M**. Their core dispatch application is a Java monolith on Oracle. Peak load is 5.5× baseline during the two-week holiday season; last year they dropped shipments because they could not add capacity. A venture-backed competitor launched 14 months ago with same-day route optimisation and is taking their mid-market accounts. The board has asked for a recommendation before the refresh purchase.

### Steps

1. Fill in this table. One row per driver, and every "Evidence" cell must reference an exercise you actually ran.

    | # | Business pressure | Cloud capability | Evidence (exercise) | Risk if we do nothing |
    |---|---|---|---|---|
    | 1 | US$2.4M refresh, 19% utilisation | | | |
    | 2 | 5.5× seasonal peak | | | |
    | 3 | Competitor shipping features faster | | | |
    | 4 | No visibility into per-customer cost to serve | | | |
    | 5 | Ops staff consumed by patching | | | |
    | 6 | Enterprise RFPs now require carbon reporting | | | |

2. Write the three-sentence board recommendation. Constraint: no adjectives, one number per sentence, and a named next step.

3. Argue the **opposite** case in 150 words. Find the strongest genuine reason Meridian should buy the hardware. If you cannot construct one that a competent CFO would take seriously, you do not yet understand the trade-off.

4. Choose a migration approach and justify it with a timeline:
    - **Rehost** (lift and shift to Compute Engine)
    - **Replatform** (rehost, then move Oracle to Cloud SQL and the web tier to Cloud Run)
    - **Refactor** (rewrite the monolith as services)
    - **Hybrid** (dispatch stays on-premises via GKE Enterprise; burst and analytics in the cloud)

    State which one you would start with in month 1, and what would have to be true by month 6 to move to the next.

5. Identify the two things that will actually kill this programme, and they are not technical. Name them and propose one mitigation each.

**Sources:** [Cloud Adoption Framework](https://cloud.google.com/adoption-framework) · [Migration to Google Cloud](https://cloud.google.com/architecture/migration-to-gcp-getting-started) · [Google Cloud Architecture Framework](https://cloud.google.com/architecture/framework)

### Check your understanding — Block 9

1. **Q9.1** — Which of the six pressures in step 1 is *not* solved by cloud adoption alone, and what else is required?
2. **Q9.2** — The refresh quote is US$2.4M and the deadline is 11 months. Why is that deadline the single most important fact in the scenario, and what does it mean if the board delays six months?
3. **Q9.3** — Rehosting captures a fraction of the value (see Q5.4) and is the fastest path. Defend it as the correct month-1 choice anyway.
4. **Q9.4** — Meridian's differentiator is 40 years of route and delivery data. Which cloud capability turns that from a cost centre into the competitive answer to the venture-backed rival?
5. **Q9.5** — Name the failure mode where a company migrates successfully, saves money, and still loses to the competitor. What does that tell you about the difference between *cloud migration* and *digital transformation*?

---

## Exercise 10 — Teardown

Run this. Elasticity means you stop paying when you stop consuming — but only if you actually stop.

```bash
# Cloud Run, all three regions
for R in us-central1 europe-west1 asia-northeast1; do
  gcloud run services delete reach-demo --region="$R" --quiet 2>/dev/null
done
gcloud run services delete elasticity-demo --region="$REGION" --quiet

# Compute Engine
gcloud compute instances delete iaas-demo --zone="${REGION}-a" --quiet

# Budget (keep it if you intend to keep using the project)
BUDGET="$(gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
  --filter='displayName=cdl-lab-guardrail' --format='value(name)')"
[ -n "$BUDGET" ] && gcloud billing budgets delete "$BUDGET" --quiet

# BigQuery dataset (this deletes the billing export history)
bq rm -r -f --dataset "${PROJECT_ID}:billing_export"

# Verify nothing is left running
echo "--- remaining instances ---"; gcloud compute instances list
echo "--- remaining services ---";  gcloud run services list
```

Representative output:

```
--- remaining instances ---
Listed 0 items.
--- remaining services ---
Listed 0 items.
```

Then check the bill in 24 hours. The number you see is the last exercise.

---

<details>
<summary><strong>Answers</strong> — open only after attempting every block</summary>

### Block 1 — The unit of cost

**A1.1** — The ratio represents **paying for consumption instead of capacity**. A purchased server's cost is fixed at the moment of purchase and is completely independent of how many hours it does useful work; its idle hours cost exactly as much as its busy hours. The 6× difference is not a discount — it is the absence of a charge for the 20 hours a day the machine is not needed. It is structurally impossible on owned hardware because the CapEx transaction has already completed: there is no mechanism by which not using a server refunds part of its purchase price, its rack space, its power circuit or its depreciation.

**A1.2** — The customer is paying less for **the right to not be interrupted**. Spot capacity is Compute Engine's spare inventory, reclaimable with a ~30-second termination notice and a 24-hour maximum lifetime. Free money: batch rendering, CI/CD build fleets, ETL, ML training with checkpointing, video transcoding, fuzzing — anything that is stateless, restartable, and has a deadline measured in hours rather than seconds. Unusable: the primary replica of a stateful database, a session-affinity web tier without connection draining, a licensed appliance with a lengthy boot sequence, or anything under a latency SLO that a 30-second eviction would breach.

**A1.3** — Because it moves cost from a *procurement* activity to an *engineering* one. When prices are quotes, cost is discovered at purchase time, by a different department, on a quarterly cycle — so architecture is chosen first and costed afterwards, and the cost is unchangeable once discovered. When prices are an API, a cost model can be built during design, run in CI, attached to a pull request, and re-evaluated automatically when Google changes a price. The architect and the accountant read the same number at the same time. That is the difference between cost as a constraint you discover and cost as a variable you design against.

**A1.4** — It lets you buy the *shape* of your workload rather than the shape of a vendor's SKU. On-premises, a memory-hungry workload forces you to buy the CPUs bolted to that memory, and those idle cores are pure waste you paid for. Separate vCPU and RAM SKUs are what make custom machine types possible — a 4 vCPU / 32 GiB instance costs exactly 4 cores plus 32 GiB with no rounding up to the nearest catalogue item. The generalisation: decomposed pricing lets resource dimensions be scaled independently, which is the same principle that makes storage independent of compute in BigQuery.

### Block 2 — TCO

**A2.1** — "We pay a higher rate per server-hour but we buy roughly a third as many server-hours, because we only pay for the hours we actually use." Both statements are true simultaneously because the denominators are different: the on-premises price is amortised over capacity that exists whether or not it works, and the cloud price is charged against capacity that only exists while it works.

**A2.2** — Raising `ONPREM_UTIL` from 0.22 to 0.70 is by far the largest single move, because it more than triples the on-premises denominator without changing its numerator. It describes an organisation that has already done the hard part: a mature virtualisation or containerisation practice with real bin-packing, aggressive consolidation, stable and predictable demand, and no large idle safety margin. Such organisations exist — high-frequency trading, some scientific computing, mature private clouds — and for them the cloud cost case is genuinely weak. Their case has to be made on agility, global reach or managed services instead. Lengthening `REFRESH_YEARS` to 7 is the second largest, and describes an organisation running hardware past its efficient life, which shifts cost from the CapEx line to the risk and power lines where this model does not capture it.

**A2.3** — A CUD is a promise to spend a fixed amount for a fixed term in exchange for a discount. Structurally that is exactly what a hardware purchase is: capacity paid for in advance, unrefundable, sized on a forecast. The differences are real but narrower than they sound — the commitment is financial rather than physical, it has no residual value or disposal problem, and it can be attached to different machine instances over its life. It does **not** forfeit elasticity, and the reason matters: the correct pattern is to commit to your *floor* and burn on-demand or Spot for everything above it. Commit to the 60th percentile of demand, not the peak. You keep elasticity on the marginal capacity, which is exactly where elasticity has value, and you buy the discount on the baseline, where elasticity has none.

**A2.4** — Genuinely disappears: hardware procurement and vendor management, physical installation and cabling, RAID rebuilds and disk replacement, firmware and BIOS updates, hypervisor lifecycle, capacity planning meetings, data-centre access and escorts, spare-parts inventory, and the on-call rotation for physical failure. Genuinely appears: IAM and organisation-policy design, cloud cost management (a new discipline — see Exercise 7), Terraform/IaC skills, network peering and hybrid connectivity, service-quota management, and a considerably larger security surface to configure. The model's 1.5 → 0.75 assumption is defensible but is an assumption; the honest framing is that headcount *shifts from undifferentiated operations toward platform engineering*, and organisations that migrate without making that shift capture neither saving.

**A2.5** — Several are valid; strong answers include: (i) **one-time migration cost** — assessment, tooling, dual-running both environments during cutover, application remediation, which is typically the single largest number in year one and appears in no steady-state model; (ii) **training and hiring**; (iii) **software re-licensing** — per-core licences frequently price differently on cloud infrastructure, and Oracle in particular can dominate the entire comparison; (iv) **egress charges** for data-intensive or multi-cloud architectures; (v) **the residual value and stranded cost of hardware already owned**; (vi) **the opportunity cost of the engineering time** spent migrating instead of building product.

### Block 3 — Elasticity

**A3.1** — Equivalent on-premises transaction: acquire and provision eleven servers, then decommission them fifteen minutes later. In practice that is a capacity request, a budget approval, a purchase order, a manufacturing and shipping lead time of four to twelve weeks, rack-and-stack, cabling, imaging and network configuration — call it one to three months and a five-figure irreversible spend — followed by owning the hardware for the next four years. The cloud version cost a few cents and required no human decision. This is the mechanism behind the exam's word "agility": it is not that the cloud is faster at the same task, it is that the task ceased to be a procurement event.

**A3.2** — The trade is **cost versus latency**, and it is the canonical serverless decision. `--min-instances=0` means you pay nothing at idle and the first user after an idle period absorbs a container cold start. `--min-instances=2` means two instances bill continuously — 24/7, forever — and no user ever pays for a start. The decision belongs to the **product or business owner**, not to engineering, because it is a purchase of user experience with money and the exchange rate is quantifiable: monthly cost of the warm floor versus the conversion impact of a ~1.2-second first-request penalty. Engineering's job is to price both sides accurately, not to pick.

**A3.3** — **Cost:** the ceiling is the blast radius of a bug or an attack. A retry storm, a runaway client or a small DDoS against an uncapped service converts directly into an unbounded bill, and unlike a fixed server fleet nothing stops it. **Correctness:** downstream dependencies have finite capacity. If each Cloud Run instance opens database connections, unbounded scaling exhausts the database connection pool and takes down every consumer of that database — the elastic tier destroys the inelastic tier behind it. `--max-instances` is the mechanism that makes the elastic layer respect the limits of the layer it depends on.

**A3.4** — Under Cloud Run's default **request-based** billing, you are charged for CPU and memory only during request processing; an instance that exists but is idle between requests bills at a much lower rate or not at all for CPU. So the `active`/`idle` split maps almost directly onto the bill, and an instance kept warm for latency reasons is far cheaper than a continuously-billed VM. Under **instance-based** billing (`--no-cpu-throttling`, needed for background work, in-process queues or long-lived connections) CPU is always allocated and always billed for the instance's whole lifetime — the `idle` count stops being free and starts looking exactly like a running VM. Choosing instance-based billing therefore changes both the concurrency model *and* the economics, which is why it is a deliberate flag rather than a default.

**A3.5** — (i) **Failure recovery and deployment.** Elasticity is the same machinery that replaces a failed instance and that runs a blue/green or canary rollout — you get transparent capacity replacement and zero-downtime deploys from the same primitive, regardless of whether demand varies. (ii) **Right-sizing without risk.** With flat demand the value moves from scaling *out* to scaling *down*: because capacity is reversible, you can trim provisioned resources toward actual usage and undo the change in seconds if you overshoot. On owned hardware, over-provisioning is the rational choice because under-provisioning is unrecoverable; elasticity removes the penalty for guessing low. Also acceptable: growth is not always daily — flat traffic today still becomes 3× traffic after a successful launch, and elasticity is the option value on that.

### Block 4 — Global reach

**A4.1** — Replaced business case: "Enter the European market — 18 months, site selection, legal entity, data-centre lease, hardware purchase and shipping, local operations hiring, several million dollars committed before the first customer." Now: a region string and a deploy, reversible in one command. The disproportionate beneficiary is **the small or new company**, and this is the structurally important point: cloud does not merely reduce the cost of global operations, it removes global reach as a *barrier to entry*. A three-person startup and a multinational now deploy into the same 40-plus regions on the same terms. That symmetry — not the cost saving — is the actual revolution the exam objective is naming, and it is why incumbents lose to newcomers who were never able to compete before.

**A4.2** — A **zone** is a deployment area within a region, engineered as an independent failure domain: separate power, cooling and networking, so that a hardware, power or software failure in one zone should not affect another. A **region** is an independent geographic location containing three or more zones, typically within a metropolitan area. Multi-zone protects against equipment failure, a datacentre-level power or cooling event, and most maintenance and rollout failures. Multi-region additionally protects against events with regional scope — natural disaster, extended regional power or network loss, region-wide service disruption — and is the only configuration that addresses data residency and user-proximity latency, which are not availability concerns at all.

**A4.3** — Any workload where the traffic is bulk, latency-tolerant, and regionally contained. Concretely: nightly backup replication to Cloud Storage, batch log shipping, large dataset transfers between systems on the same continent, internal analytics egress, or an internal-only application whose users are all in the same region as the resources. Premium Tier buys you Google's private backbone from the edge nearest the user — which is worth paying for when users are far away and latency is user-visible, and is worth nothing when the bytes are machine-to-machine and nobody is waiting.

**A4.4** — **Regulatory:** a French public-sector customer, a healthcare or defence contract, or a contractual data-residency clause may require that data be stored and processed inside France specifically, not merely inside the EU. `europe-west4` in the Netherlands satisfies GDPR but fails a French residency requirement, and the constraint is binary — no amount of cost saving makes non-compliant architecture acceptable. **Commercial:** latency and market credibility. Users in France see materially lower latency from Paris, and for a latency-sensitive product that is a measurable conversion difference; separately, "hosted in France" is a statement that wins French enterprise deals independently of any legal requirement. Both are business reasons that outrank the price delta, which is the general lesson: region selection is a business decision with technical inputs, not the reverse.

**A4.5** — That the speed of light is not a vendor feature. Google can put a region near your users, but it cannot make Tokyo closer to São Paulo. "The cloud is everywhere" means *you can choose where you are*, not that location has stopped mattering — and that choice remains a real architectural decision with real trade-offs against cost, carbon and operational complexity. Architectures that ignore this (a single region serving a global user base) get physics-limited latency that no amount of scaling fixes.

### Block 5 — Service models

**A5.1** — Below the boundary, the vendor delivers a working system and updates it without asking you; above the boundary, you receive a system that will degrade and become insecure unless you personally maintain it. The boundary is defined by **who is obliged to act when a vulnerability is published**. Everything below it is the vendor's obligation; everything above it, including the obligation to notice, is yours.

**A5.2** — (a) Control: IaaS > PaaS > SaaS. (b) Operational burden: IaaS > PaaS > SaaS. The orderings are **identical**, and that is the whole trade: control and burden are the same quantity viewed from two sides. Every knob you retain is a knob you must set correctly, keep correct, and be paged about. There is no model that gives more control with less work — choosing a service model is choosing how much of the stack you want to be responsible for, and the correct choice is the least control that still meets the requirement.

**A5.3** — They must use **IaaS** (Compute Engine, or GKE Standard with a custom node image if they can containerise). A kernel module requires kernel access, and PaaS platforms provide no kernel to modify — this is not a limitation to work around, it is the definition of the tier. Honest cost: they now own OS patching, kernel updates, image lifecycle, hardening, host-level monitoring, capacity planning and node autoscaling for that component, plus the ongoing risk that the vendor's module lags kernel security fixes. The mature architectural response is to **scope the constraint**: isolate the licensed component on IaaS and run everything that does not need the module on PaaS, rather than letting one requirement pull the entire architecture down a tier.

**A5.4** — Rehosting captures the **infrastructure economics** and little else: elasticity of VM count, no hardware refresh, no data-centre lease, per-hour billing, global region choice, and the ability to right-size — which in the Exercise 2 model is the hardware, array, colo and power lines. It leaves on the table the **operational** savings, which were the largest single line in that model: the VM still needs patching, backing up, monitoring and capacity planning, so the ops FTE number barely moves. It also leaves the managed-service and developer-velocity benefits entirely untouched. The important caveat: rehost-only migrations frequently produce *higher* bills than the on-premises estate, because a lift-and-shift preserves the 19% utilisation it was built around while switching to a pricing model that punishes idleness. Rehosting is a valid first step but a poor final state.

**A5.5** —
- **Compute Engine** — IaaS. You choose machine type, image, disks and network; you own the OS.
- **GKE Autopilot** — PaaS in practice, though marketed as managed Kubernetes. Google owns nodes, node OS, scaling and node security; you own workloads and cluster-scoped configuration. GKE *Standard*, by contrast, sits much closer to IaaS because you own the node pools.
- **Cloud Run** — PaaS (specifically serverless CaaS). You supply a container; Google supplies everything under it.
- **BigQuery** — PaaS by the standard taxonomy, and the hardest to place. It is fully managed and serverless with no infrastructure exposed at all, which reads as SaaS, but you write the schemas and the SQL and it is a component you build *with*, not an application you use.
- **Google Workspace** — SaaS. Finished application, no build step, consumed by end users.

The instructive part is BigQuery. The three-model taxonomy was designed for a world of virtual machines, and modern serverless data and AI products do not sit cleanly in it. The exam still uses the taxonomy, so learn it — but the *useful* question in practice is not "which of three letters is this" but "exactly which responsibilities does the vendor take, and which remain mine." That question always has a precise answer; the taxonomy sometimes does not.

### Block 6 — Shared responsibility and shared fate

**A6.1** — The **customer's** responsibility, unambiguously. Google's obligation is the security *of* the cloud: the physical facility, the hardware, the hypervisor, the network fabric, and the correct functioning of the firewall service. The customer's obligation is security *in* the cloud: which rules that firewall enforces, which credentials exist, and how they are protected. Google shipped a default network optimised for a developer's first five minutes and documents that it is not a production posture; leaving `0.0.0.0/0` on port 22 is a customer configuration decision. The fair criticism is of the *default*, not of the boundary — see A6.4.

**A6.2** — As you move IaaS → PaaS → SaaS, the boundary moves **upward through the stack, transferring responsibilities from customer to provider**: first physical and virtualisation (always the provider's), then OS, patching and runtime, then application maintenance and availability, then finally the application itself. The responsibility that **never moves** is the customer's: **data, and identity/access to it**. Whatever the model, you decide what data you put in, who may reach it, how it is classified, and whether the access grants are correct. Google can encrypt it, replicate it and audit access to it — Google cannot decide on your behalf that a given person should not have been an Owner.

**A6.3** — **Shared responsibility** is a static division of labour: a published matrix stating which layers the provider secures and which the customer secures, so that neither assumes the other is handling something. **Shared fate** is the provider taking an active, ongoing stake in the customer's half — supplying secure-by-default configurations, blueprints, continuous analysis of the customer's own posture, and in some programmes financial risk-sharing — on the premise that a customer breach is the provider's problem too. The step-5 example is **IAM Recommender**: Google continuously analyses actual permission usage inside your project and proposes least-privilege role reductions. IAM configuration is squarely the customer's responsibility under the matrix, and Google does the analysis and hands over the fix anyway. Google's own framing is that shared responsibility describes *who is accountable*, while shared fate describes *how the provider helps the customer succeed at their part*.

**A6.4** — It exists to eliminate adoption friction: without a default service account holding broad permissions, a new user's first VM cannot write logs, read from Cloud Storage or call any API, and the getting-started experience becomes an IAM tutorial. The trade-off is explicit and it is the recurring tension of cloud platform design — **a default that is safe for everyone is inconvenient for beginners, and a default that is convenient for beginners is unsafe at scale.** The existence of `roles/editor` on that account tells you Google chose adoption at the default layer and pushed the correction into a *separate*, opt-in layer: organisation policies (`iam.automaticIamGrantsForDefaultServiceAccounts` can disable it), IAM Recommender, Security Command Center findings. The practical lesson for an architect: **the platform's defaults are not its recommendations.** Never treat a default as a security review.

**A6.5** — "The physical infrastructure, the hypervisor and the network fabric did become Google's problem, and Google is measurably better at those than we were. What did not move is our data and who can access it — every significant cloud breach on record has been a customer misconfiguration, not a provider compromise. Our security work did not disappear; it changed from patching servers to getting identity, access and configuration right, and we currently have a default service account with editor rights and SSH open to the internet." A concrete thing that genuinely did become Google's problem: physical data-centre security, hardware supply-chain integrity, hypervisor isolation between tenants, and encryption at rest by default.

### Block 7 — Cost feedback loop

**A7.1** — Any three of: **(i) Unit economics** — join billing data to application labels to compute cost per customer, per tenant, per transaction or per feature, which makes pricing and margin decisions evidence-based instead of allocated by floor-space guesswork. **(ii) Chargeback and showback** — attribute real cost to the team that caused it, which changes engineering behaviour within days rather than at the next budget cycle. **(iii) Kill decisions** — see that a feature costs more to run than it earns, and retire it. **(iv) Optimisation targeting** — identify the top-cost SKU and fix that one, instead of running an untargeted efficiency programme. **(v) Regression detection** — treat a cost spike as a build failure, because a change that triples spend is usually also a bug. **(vi) Accurate forecasting** — model next quarter from measured trend rather than from a vendor quote.

**A7.2** — Budgets alert rather than enforce because **stopping spend means stopping the business**. A hard cap that disables billing takes production down, deletes resources, and turns a cost overrun — recoverable — into an outage and possible data loss — sometimes not. Google cannot know whether your overrun is a runaway test loop or Black Friday. To make it enforcing you build the loop yourself: budget → Pub/Sub notification → Cloud Function that takes a *scoped, reversible* action. Sensible actions in escalating order: notify the owning team, reduce `--max-instances` on non-production services, stop tagged development VMs, cancel long-running BigQuery jobs. Disabling billing on the project is the documented last resort and should be reserved for sandbox projects that contain nothing you would miss. The design principle: automate the response, but keep the blast radius proportional and the action reversible.

**A7.3** — That the **first substantive action** in a new Google Cloud organisation — before workloads, before the landing zone is finished — is to enable billing export, along with a labelling/tagging standard and an organisation-level budget. Every hour of delay is an hour of cost history that can never be recovered, and cost history is what every later optimisation, forecast and chargeback conversation depends on. It is free, it takes minutes, and it is the single most common thing organisations skip and then regret twelve months later when they cannot answer "when did this start?"

**A7.4** — In Exercise 2, `CLOUD_UTIL`, the hourly rates, `CLOUD_STORAGE_EGRESS_YR` and effectively the entire cloud column were **assumptions**. With billing export they become **measurements** taken from your own account, and the model turns from a pre-migration sales artefact into a live operational dashboard you re-run monthly. This closes the loop that on-premises finance never could: the on-premises column stays an estimate forever, because a depreciation schedule cannot tell you which workload consumed which fraction of a shared array. That asymmetry — one side measurable, the other permanently estimated — is itself part of the argument.

**A7.5** — The chain: granular billing means every team can see the cost of its own decisions in near-real time → cost stops being a centrally-allocated overhead and becomes a property of the change → teams can evaluate a proposal's economics themselves without a finance gate → experiments become cheap to *evaluate*, not merely cheap to *run* → the organisation can try many small things, measure which pay, and kill the rest quickly. The agility comes from OpEx removing **two** barriers, and the second is the one people miss: the first is that no capital approval is needed to start, and the second is that no capital write-off is incurred to stop. When failure is cheap and reversible, the rational number of experiments goes up — and running more experiments is how a company out-innovates one that must be right the first time.

### Block 8 — Sustainability

**A8.1** — It should be owned by whoever owns the **architecture decision record** — the platform or cloud-governance function — encoded as an organisation policy (`gcp.resourceLocations`) and a default in the deployment templates, so the carbon-aware choice is the path of least resistance rather than a per-team judgement call. It is usually owned by the individual developer, who selects a region by copying the region from the tutorial they were reading — which is why so much of the world's cloud workload sits in `us-central1`. The general lesson: a decision this consequential should not live in the default value of a copy-pasted command.

**A8.2** — **Carbon neutral** means annual net emissions are brought to zero through offsets and matched renewable purchases — an *annual, netted* accounting. Google has been carbon neutral in operations since 2007 and has matched 100% of annual electricity consumption with renewable purchases since 2017. **24/7 carbon-free energy** means that every hour, in every grid, the electricity actually consumed comes from carbon-free sources — no netting across time or geography. It is dramatically harder because it cannot be solved by buying more renewables somewhere sunny: it requires clean generation available at 3 a.m. in that specific grid, which demands storage, geothermal, nuclear or grid-scale transmission that in many regions does not yet exist. It matters to the customer because carbon accounting standards and regulators are moving toward hourly, location-based reporting, under which annual matching stops being sufficient — so a provider on the 24/7 path is protecting the customer's *future* compliance position, not just its current one.

**A8.3** — **Cleanest is wrong:** a real-time payment authorisation or ad-bidding service for Japanese users placed in `europe-north1` for its 91% CFE would add roughly 250 ms of round-trip latency, breaching the SLO and failing the product. Carbon cannot buy back physics; the correct move is the cleanest region *within* the latency envelope. **Cleanest is right:** a nightly batch job — model training, log aggregation, data warehouse rebuild — with a twelve-hour completion window and no interactive user. Latency is irrelevant, so region choice is free to optimise for carbon and price, and a 30× emissions reduction costs nothing. The generalisable rule: **carbon is a legitimate tiebreaker among regions that already satisfy the hard constraints**, and batch workloads have almost no hard constraints, which is why carbon-aware scheduling starts there.

**A8.4** — PUE 1.6 means 0.6 kWh of overhead — cooling, power conversion, lighting — per 1.0 kWh delivered to compute; total draw is 1.6 units for 1 unit of useful work, so 37.5% of all energy is overhead. At PUE 1.1 the overhead is 9%. Moving from 1.6 to 1.1 cuts total energy consumption for identical compute by about 31%. What the customer buys and could not build: purpose-designed facilities at a scale that justifies custom cooling, ML-driven thermal management, custom power distribution and hardware co-designed with the building — plus long-term power-purchase agreements with new clean generation, which require creditworthiness and volume that essentially no single enterprise possesses. This is an economy of scale in the strict sense: the efficiency is not a technique being withheld, it is only achievable *at* that scale.

**A8.5** — Because a PDF is a *disclosure* and an export is an *input*. A machine-readable export can be joined to the billing export from Exercise 7, attributed to a project, team, service or customer, put on a dashboard next to cost, checked in CI, fed into a regulatory filing, and used to make a deployment decision *before* the workload runs. A PDF can only be read after the fact and re-typed. The pattern is identical to A1.3: the moment a number becomes an API rather than a document, it moves from something you report to something you engineer against.

### Block 9 — Synthesis

**A9.1** — **Pressure 3, "competitor shipping features faster."** Cloud infrastructure removes an *obstacle* to shipping speed; it does not create speed. Also required: CI/CD, automated testing, decomposition of the Java monolith so that changes can be released independently, product teams empowered to release without a change-advisory board, and observability sufficient to make frequent releases safe. A rehosted monolith with a quarterly release train ships exactly as slowly on Compute Engine as it did on-premises, at a comparable or higher cost. This is the objective's word "how" — the technology is necessary and nowhere near sufficient.

**A9.2** — Because it is the moment the decision becomes **irreversible for four years**. Every month before the purchase, migration is an option; the day the purchase order is signed, US$2.4M of sunk capital exists and every subsequent cloud proposal has to argue against abandoning it, which is a political argument no one wins. Refresh deadlines are the natural decision point for migration precisely because they are the only moments when the status quo also requires writing a large cheque — the comparison is finally like-for-like. If the board delays six months, the practical outcome is that they will buy the hardware: five months is not enough to assess, plan and begin a migration of 180 servers, so the "safe" default wins by running out the clock. The correct recommendation therefore includes a decision date well before the eleventh month.

**A9.3** — Because the binding constraint is the 11-month deadline, not the optimum. Rehosting is the only approach that can demonstrably move enough workload off the existing estate in time to cancel the refresh purchase — and cancelling that purchase is what funds and de-risks everything after it. It also front-loads the organisational learning (IAM, networking, IaC, cost management) on low-stakes workloads, so the team is competent before it touches the dispatch application. The discipline that makes it defensible rather than lazy is committing in advance to what happens next: rehost with *right-sizing applied at migration* rather than a like-for-like clone of 19%-utilised VMs, with a named replatform target and date. Rehosting is a good first move and a bad destination; the failure mode is not choosing it, it is stopping there.

**A9.4** — The **data and AI/ML stack** — consolidating four decades of route, delivery-time, fuel and exception data into BigQuery, then building route optimisation and delivery-time prediction on it. This is the strategic core of the answer. The competitor has better software but 14 months of data; Meridian has worse software and 40 years of it. Cloud economics are what make that asset usable: querying decades of history requires enormous, bursty, intermittent compute that is absurd to buy as hardware and trivial to rent for an hour. Note that this is the only item on the list that is *offensive* rather than defensive — the cost, capacity and patching items make Meridian cheaper to run, but this one is the only one that can win back a customer.

**A9.5** — The failure mode is **rehost-and-stop**: the company completes a technically clean migration, decommissions the data centre, reports the infrastructure saving, and declares victory — while the monolith, the quarterly release train, the change-advisory board and the org chart all survive intact. Costs fall perhaps 20%; feature velocity is unchanged; the competitor keeps winning accounts. The lesson is that **cloud migration is a change of venue and digital transformation is a change of operating model**. Migration is the necessary precondition and the easy half; it is measured in servers moved. Transformation is measured in how quickly the company can turn an idea into something a customer uses, and it requires changes to team structure, release process, funding model and decision rights that no `gcloud` command performs. A company that does the first and calls it the second has bought the bill without the benefit — which is the precise reason this exam objective is phrased as *why and how*, and not merely *what*.

</details>