# gcp-cdl — Topic 6.2
# Modern Operations, Reliability, and Resilience in the Cloud
## Guided Exercises (hands-on + analytical)

**Exam:** Google Cloud Digital Leader, syllabus version `2026-08-12`
**Section:** 6 — *Successfully implementing and operating in the cloud* · **Objective 6.2** · **Exam weight: 5.0%**
**Primary source:** [Cloud Digital Leader Exam Guide (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

---

## How to use this document

The CDL exam tests *concepts and business trade-offs*, not `kubectl` muscle memory. But concepts that have never touched a real console evaporate under exam pressure. So these exercises are built in two layers:

| Layer | What you do | Why |
|---|---|---|
| **Hands-on blocks** (Ex. 1, 3, 4) | Run real `gcloud` commands, read real telemetry | Makes SLI/SLO/observability concrete |
| **Analytical blocks** (Ex. 2, 5, 6, 7, 8) | Compute budgets, design topologies, classify patterns | This is the shape the exam actually asks in |

Every block ends with a **Checkpoint**. Answer it *before* scrolling. The full answer key is in the collapsible `<details>` section at the very end.

### Prerequisites

- A Google Cloud project with billing enabled (Free Tier is sufficient for everything except the optional Cloud SQL block).
- `gcloud` CLI ≥ 450.0.0 installed and authenticated, **or** use [Cloud Shell](https://cloud.google.com/shell) — it has everything preinstalled and its usage is free.
- Roles on the project: `roles/run.admin`, `roles/monitoring.editor`, `roles/logging.viewer`, `roles/iam.serviceAccountUser`.

### Cost and safety

Cloud Run scales to zero and the traffic you generate here is a few hundred requests — it stays inside the Free Tier. Cloud Monitoring uptime checks and the first tranche of custom metrics are free. **Exercise 6, Step 4 provisions a Cloud SQL instance and does cost real money (cents per hour); it is explicitly marked optional and there is a paper-only path.** Run the teardown in Exercise 9 when you finish.

> ⚠️ `gcloud alpha` / `gcloud beta` surfaces change between SDK releases. Where an alpha command is used, the REST equivalent is given alongside it, and `gcloud <group> --help` is authoritative for *your* installed version. Do not memorise flags for the exam — memorise the concept.

---

## Exercise 1 — The vocabulary: SLI, SLO, SLA, and where the numbers come from

**Goal:** stop treating "reliability" as an adjective. By the end of this block you will have measured one, with your own hands, from raw request logs.

### Steps

**1.** Set your working project and a default region. Every later command inherits these.

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export REGION="us-central1"
export SERVICE="reliability-lab"

gcloud config set project "$PROJECT_ID"
gcloud config set run/region "$REGION"

echo "Project: $PROJECT_ID | Region: $REGION"
```

Expected output:

```
Updated property [core/project].
Updated property [run/region].
Project: my-cdl-project-4471 | Region: us-central1
```

**2.** Enable the four APIs this lab needs. This is idempotent — re-running it is free and silent.

```bash
gcloud services enable \
  run.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  cloudresourcemanager.googleapis.com
```

Expected output (first run may take 30–60 s):

```
Operation "operations/acat.p2-482910334471-9c1f...-a4e0" finished successfully.
```

**3.** Deploy a stateless service. We use Google's public sample container, so there is no source code to build and nothing to maintain.

```bash
gcloud run deploy "$SERVICE" \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region="$REGION" \
  --allow-unauthenticated \
  --min-instances=0 \
  --max-instances=3
```

Expected output (abridged):

```
Deploying container to Cloud Run service [reliability-lab] in project [my-cdl-project-4471] region [us-central1]
✓ Deploying new service... Done.
  ✓ Creating Revision...
  ✓ Routing traffic...
  ✓ Setting IAM Policy...
Done.
Service [reliability-lab] revision [reliability-lab-00001-xyz] has been deployed
and is serving 100 percent of traffic.
Service URL: https://reliability-lab-abc123def-uc.a.run.app
```

**4.** Capture the URL into a variable and confirm the service answers.

```bash
export URL="$(gcloud run services describe "$SERVICE" \
  --region="$REGION" --format='value(status.url)')"

curl -s -o /dev/null -w "status=%{http_code} latency=%{time_total}s\n" "$URL"
```

Expected output:

```
status=200 latency=0.412s
```

That first request is slow because it paid a **cold start**. Note the number — it comes back in Exercise 3.

**5.** Generate a controlled traffic mix: 180 good requests and 20 deliberate failures (a path the container does not serve). This gives us a known-good ground truth to check our measurement against.

```bash
for i in $(seq 1 180); do curl -s -o /dev/null "$URL/"; done
for i in $(seq 1 20);  do curl -s -o /dev/null "$URL/does-not-exist-$i"; done
echo "traffic generated: 180 expected-good, 20 expected-bad"
```

**6.** Wait ~60 seconds for log ingestion, then count outcomes **from the logs**, not from your loop. This is the difference between what you *think* you served and what you *actually* served.

```bash
sleep 60
gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\" AND httpRequest.status!=\"\"" \
  --freshness=15m --limit=1000 \
  --format='value(httpRequest.status)' | sort -n | uniq -c
```

Expected output (your exact counts will differ slightly — health probes and retries are real traffic too):

```
    181 200
     20 404
```

**7.** Compute the availability SLI by hand. The standard *request-based* definition is:

$$\text{SLI}_{\text{availability}} = \frac{\text{good events}}{\text{valid events}} \times 100$$

```bash
gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\"" \
  --freshness=15m --limit=1000 --format='value(httpRequest.status)' \
| awk 'NF{t++; if ($1<500) g++} END {printf "valid=%d good=%d SLI=%.3f%%\n", t, g, 100*g/t}'
```

Expected output:

```
valid=201 good=201 SLI=100.000%
```

**8.** Now re-run the same computation but classify `4xx` as bad:

```bash
gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\"" \
  --freshness=15m --limit=1000 --format='value(httpRequest.status)' \
| awk 'NF{t++; if ($1<400) g++} END {printf "valid=%d good=%d SLI=%.3f%%\n", t, g, 100*g/t}'
```

Expected output:

```
valid=201 good=181 SLI=90.050%
```

**Same service. Same second. Same logs. 100% or 90% depending on one line of the specification.** That is the single most important thing in this exercise.

**9.** Record the vendor-side commitment for comparison. Open [https://cloud.google.com/terms/sla](https://cloud.google.com/terms/sla), find the **Cloud Run** SLA, and write down: (a) the Monthly Uptime Percentage committed, (b) what the customer receives when it is missed, and (c) what is explicitly *excluded* from the calculation.

### Checkpoint 1

- **Q1.1** — In steps 7 and 8 the underlying system behaved identically, yet the measured reliability moved by 10 points. Which artefact changed, and what is the correct name for the document that pins it down?
- **Q1.2** — Define SLI, SLO and SLA in one sentence each, and state which of the three is the only one with legal and financial consequences.
- **Q1.3** — Your service's SLA promises 99.9%. Your team is debating whether to set the internal SLO at 99.9%, 99.5% or 99.95%. Which is correct and why? What is the specific failure mode of the wrong answers?
- **Q1.4** — The 404s in step 5 were caused by clients requesting a path that never existed. Argue *both* sides: should they count as "bad events" in an availability SLI?
- **Q1.5** — The first request in step 4 took 412 ms; subsequent requests take ~30 ms. Why is an *average* latency SLI a poor choice here, and what should you use instead?

---

## Exercise 2 — Error budgets and burn rate: turning a percentage into a decision

**Goal:** an SLO that does not change anyone's behaviour is decoration. The error budget is the mechanism that gives it teeth.

### Steps

**1.** Compute the time-based error budget for a 30-day compliance window. A 30-day month is 43,200 minutes.

$$\text{Budget}_{\text{minutes}} = (1 - \text{SLO}) \times 43{,}200$$

Fill this in yourself before checking:

```bash
for slo in 99 99.5 99.9 99.95 99.99 99.999; do
  python3 -c "print(f'SLO {$slo:>7}%  ->  {(1-$slo/100)*43200:9.2f} min/30d  ({(1-$slo/100)*43200/60:6.2f} h)')"
done
```

Expected output:

```
SLO      99%  ->    432.00 min/30d  (  7.20 h)
SLO    99.5%  ->    216.00 min/30d  (  3.60 h)
SLO    99.9%  ->     43.20 min/30d  (  0.72 h)
SLO   99.95%  ->     21.60 min/30d  (  0.36 h)
SLO   99.99%  ->      4.32 min/30d  (  0.07 h)
SLO  99.999%  ->      0.43 min/30d  (  0.01 h)
```

**2.** Compute the request-based budget for your own traffic. Suppose the service handles **10,000,000 requests** in the window under a **99.9%** SLO:

```bash
python3 - <<'PY'
total, slo = 10_000_000, 0.999
budget = total * (1 - slo)
print(f"allowed bad requests = {budget:,.0f}")
print(f"after 6,200 failures, budget consumed = {6200/budget:.1%}")
print(f"remaining budget       = {budget-6200:,.0f} requests")
PY
```

Expected output:

```
allowed bad requests = 10,000
after 6,200 failures, budget consumed = 62.0%
remaining budget       = 3,800 requests
```

**3.** Understand **burn rate**. Burn rate is how fast you are spending budget relative to the rate that would exactly exhaust it over the whole window.

$$\text{Burn rate} = \frac{\text{observed error ratio}}{1 - \text{SLO}}$$

```bash
python3 - <<'PY'
slo = 0.999
for err in (0.001, 0.003, 0.006, 0.0144, 0.05, 1.0):
    br = err / (1 - slo)
    print(f"error rate {err:7.2%}  -> burn rate {br:6.1f}x  "
          f"-> budget exhausted in {30/br*24:8.2f} h")
PY
```

Expected output:

```
error rate   0.10%  -> burn rate    1.0x  -> budget exhausted in   720.00 h
error rate   0.30%  -> burn rate    3.0x  -> budget exhausted in   240.00 h
error rate   0.60%  -> burn rate    6.0x  -> budget exhausted in   120.00 h
error rate   1.44%  -> burn rate   14.4x  -> budget exhausted in    50.00 h
error rate   5.00%  -> burn rate   50.0x  -> budget exhausted in    14.40 h
error rate 100.00%  -> burn rate 1000.0x  -> budget exhausted in     0.72 h
```

**4.** Study the canonical **multi-window, multi-burn-rate** alerting table from the SRE Workbook. This is what a mature operations team pages on — not on "CPU > 80%".

| Budget consumed | Long window | Short window | Burn rate | Action |
|---|---|---|---|---|
| 2% | 1 hour | 5 min | **14.4×** | **Page** (wake a human) |
| 5% | 6 hours | 30 min | **6×** | **Page** |
| 10% | 3 days | 6 hours | **1×** | **Ticket** (next business day) |

Source: [SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/).

**5.** Register your Cloud Run service as a *monitored service* so Cloud Monitoring can host an SLO for it. Cloud Run services are auto-discovered; list them:

```bash
gcloud alpha monitoring services list --format='table(name, displayName)' 2>/dev/null \
  || echo "alpha surface unavailable in this SDK — use the REST call below"
```

Expected output (abridged):

```
NAME                                                        DISPLAY_NAME
projects/my-cdl-project-4471/services/canonical:us-central1:cloud-run:reliability-lab   reliability-lab
```

REST equivalent, which is stable and always available:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/services" \
  | python3 -m json.tool | head -30
```

**6.** Define a 99.9% availability SLO over a rolling 28-day window as a JSON document. Note the structure: a *goal*, a *rolling period*, and an *SLI* built from a good/total ratio.

```bash
cat > /tmp/slo.json <<'JSON'
{
  "displayName": "99.9% availability - 28d rolling",
  "goal": 0.999,
  "rollingPeriod": "2419200s",
  "serviceLevelIndicator": {
    "basicSli": {
      "availability": {}
    }
  }
}
JSON
python3 -m json.tool /tmp/slo.json
```

`2419200s` = 28 days × 86,400 s. Verify that yourself — an SLO document with a wrong window is a silently wrong SLO.

**7.** Reason about the *policy*, which is the part that has nothing to do with technology:

> **Error budget policy (draft).** While budget remains, feature velocity is the priority and risky changes are allowed. When the budget is exhausted, a **feature freeze** takes effect: only reliability work and security fixes ship until the budget recovers. The freeze is automatic and does not require negotiation.

### Checkpoint 2

- **Q2.1** — A team proposes a 99.999% SLO for an internal expense-report tool. Compute the monthly downtime allowance and give the two strongest business arguments against that target.
- **Q2.2** — Your 99.9% service has consumed 62% of its budget on day 9 of a 30-day window. Is that acceptable? What is the burn rate, and what should the on-call engineer conclude?
- **Q2.3** — Why does the alerting table in step 4 pair a **long** window with a **short** window? What specific failure would occur if you alerted on the long window alone? And on the short window alone?
- **Q2.4** — A product manager asks to "pause the error budget policy" for a quarter because of a launch deadline. Explain, in the language of an executive, what the error budget actually *is* in organisational terms and what pausing it converts the SLO into.
- **Q2.5** — The service was 100% available all month and the budget is untouched at day 30. A naive reading calls this excellent. Give the SRE reading.

---

## Exercise 3 — Observability: the four golden signals, and why metrics ≠ observability

**Goal:** distinguish *monitoring* (known questions, predefined dashboards) from *observability* (the ability to answer questions you did not anticipate). Then instrument all four golden signals.

### Steps

**1.** The four golden signals ([SRE Book, Ch. 6](https://sre.google/sre-book/monitoring-distributed-systems/)):

| Signal | Question it answers | Cloud Run metric |
|---|---|---|
| **Latency** | How long does a request take? | `run.googleapis.com/request_latencies` |
| **Traffic** | How much demand is there? | `run.googleapis.com/request_count` |
| **Errors** | What fraction is failing? | `request_count` filtered by `response_code_class` |
| **Saturation** | How full is the system? | `container/cpu/utilizations`, `container/memory/utilizations`, instance count |

**2.** List the metric descriptors your service is actually emitting:

```bash
gcloud monitoring metrics-descriptors list \
  --filter='metric.type=starts_with("run.googleapis.com/request")' \
  --format='table(type, metricKind, valueType)' 2>/dev/null | head -20
```

Expected output:

```
TYPE                                        METRIC_KIND  VALUE_TYPE
run.googleapis.com/request_count            DELTA        INT64
run.googleapis.com/request_latencies        DELTA        DISTRIBUTION
```

Note `request_latencies` is a **DISTRIBUTION**, not a gauge. That is deliberate, and Q3.4 asks why.

**3.** Query traffic and errors with **PromQL**, which Cloud Monitoring supports natively. Open **Monitoring → Metrics Explorer → PromQL** in the console and run:

```promql
# Traffic: requests per second, by response class
sum by (response_code_class) (
  rate(run_googleapis_com:request_count{
    monitored_resource="cloud_run_revision",
    service_name="reliability-lab"
  }[5m])
)
```

```promql
# Errors: the availability SLI, as a live ratio
sum(rate(run_googleapis_com:request_count{service_name="reliability-lab",response_code_class!="5xx"}[5m]))
/
sum(rate(run_googleapis_com:request_count{service_name="reliability-lab"}[5m]))
```

**4.** Query latency percentiles — never the mean:

```promql
histogram_quantile(0.99,
  sum by (le) (
    rate(run_googleapis_com:request_latencies_bucket{service_name="reliability-lab"}[5m])
  )
)
```

**5.** Create a **log-based metric** to count a condition that no built-in metric covers. This is the bridge from logs to metrics:

```bash
gcloud logging metrics create client_errors_404 \
  --description="Count of 404 responses from reliability-lab" \
  --log-filter="resource.type=\"cloud_run_revision\"
                AND resource.labels.service_name=\"${SERVICE}\"
                AND httpRequest.status=404"
```

Expected output:

```
Created [client_errors_404].
```

**6.** Confirm it exists and understand what you just built:

```bash
gcloud logging metrics describe client_errors_404 \
  --format='yaml(name, filter, metricDescriptor.metricKind, metricDescriptor.valueType)'
```

Expected output:

```yaml
filter: |-
  resource.type="cloud_run_revision"
  AND resource.labels.service_name="reliability-lab"
  AND httpRequest.status=404
metricDescriptor:
  metricKind: DELTA
  valueType: INT64
name: client_errors_404
```

**7.** Name the three telemetry signals and where each lives in Google Cloud. Fill the right column from memory, then verify in the console:

| Signal | What it is | Google Cloud product |
|---|---|---|
| Metrics | Aggregated numeric time series | ? |
| Logs | Discrete, timestamped, high-cardinality events | ? |
| Traces | The path of one request across services | ? |

**8.** Observe the saturation signal by forcing concurrency. Run 40 parallel requests and then inspect the instance count in **Cloud Run → reliability-lab → Metrics**:

```bash
seq 1 40 | xargs -P 40 -I{} curl -s -o /dev/null -w "%{http_code} " "$URL/"
echo
```

Expected output:

```
200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200
```

Watch **Container instance count** rise from 0/1 toward `--max-instances=3`, then decay back to zero over the following minutes.

### Checkpoint 3

- **Q3.1** — Define the difference between *monitoring* and *observability* using a concrete example from this exercise.
- **Q3.2** — Name the four golden signals and, for each, one thing a user would notice if it degraded.
- **Q3.3** — Fill in the table from step 7. Then state which of the three signals is the most expensive at scale and why.
- **Q3.4** — Why is `request_latencies` a distribution rather than a single number? What would you lose if the platform stored only the mean?
- **Q3.5** — In step 8 the instance count rose and then fell. Which golden signal is that, and which two capabilities from this objective are being demonstrated?
- **Q3.6** — Your service calls three downstream APIs and p99 latency has doubled. Which telemetry signal identifies *which* downstream call is responsible, and why can metrics alone not answer it?

---

## Exercise 4 — Detection and incident response: uptime checks, alerts, and the human loop

**Goal:** close the loop from *a thing broke* to *the right human knows within seconds*, and place that loop inside a defined incident-management process.

### Steps

**1.** Create a notification channel. Substitute your own address.

```bash
export EMAIL="you@example.com"

gcloud beta monitoring channels create \
  --display-name="CDL Lab On-Call" \
  --type=email \
  --channel-labels="email_address=${EMAIL}"
```

Expected output:

```
Created notification channel [projects/my-cdl-project-4471/notificationChannels/1029384756102938475].
```

**2.** Capture the channel ID:

```bash
export CHANNEL="$(gcloud beta monitoring channels list \
  --filter='displayName="CDL Lab On-Call"' --format='value(name)')"
echo "$CHANNEL"
```

**3.** Create an **uptime check** — synthetic, black-box probing from multiple global locations. This is fundamentally different from the metrics in Exercise 3.

```bash
export HOST="$(echo "$URL" | sed 's|https://||')"

gcloud monitoring uptime create "reliability-lab-https" \
  --resource-type=uptime-url \
  --resource-labels="host=${HOST},project_id=${PROJECT_ID}" \
  --protocol=https \
  --path="/" \
  --port=443 \
  --period=1 \
  --timeout=10
```

Expected output:

```
Created [projects/my-cdl-project-4471/uptimeCheckConfigs/reliability-lab-https-a1b2c3].
```

**4.** Verify it and note the probe locations:

```bash
gcloud monitoring uptime list-configs \
  --format='table(displayName, monitoredResource.labels.host, period, selectedRegions)'
```

Expected output:

```
DISPLAY_NAME           HOST                                      PERIOD  SELECTED_REGIONS
reliability-lab-https  reliability-lab-abc123def-uc.a.run.app    60s     []
```

An empty `selectedRegions` means *all* regions — the probe runs from the Americas, Europe and Asia-Pacific simultaneously. That multi-location design exists for a specific reason; Q4.2 asks what it is.

**5.** Create an alerting policy on the uptime check. Note `--condition-filter` uses the Monitoring filter language, and the alert requires the failure to persist for 5 minutes.

```bash
gcloud alpha monitoring policies create \
  --display-name="reliability-lab uptime failure" \
  --condition-display-name="uptime check failing > 5m" \
  --condition-filter='metric.type="monitoring.googleapis.com/uptime_check/check_passed"
                      AND resource.type="uptime_url"' \
  --duration=300s \
  --if="< 1" \
  --aggregation='{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_FRACTION_TRUE"}' \
  --notification-channels="$CHANNEL" \
  --combiner=OR
```

> If your SDK rejects these flags, build the policy in **Monitoring → Alerting → Create policy**, or POST the equivalent JSON to
> `https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/alertPolicies`.
> The concept being taught — *condition + duration + notification channel* — is identical in all three paths.

**6.** List your policies:

```bash
gcloud alpha monitoring policies list \
  --format='table(displayName, enabled, conditions[0].displayName)'
```

**7.** Map the timeline vocabulary onto what you just built. For a hypothetical outage beginning at 14:00:00:

| Moment | Metric | Which of your artefacts drives it |
|---|---|---|
| 14:00:00 | outage begins | — |
| 14:01:00 | first failed probe | uptime check `--period=1` |
| 14:05:00 | **MTTD** — detection | `--duration=300s` |
| 14:06:30 | **MTTA** — acknowledgement | notification channel + on-call rota |
| 14:41:00 | **MTTR** — service restored | runbook / rollback |

**8.** Understand the response roles, which are process rather than product ([SRE Book — Managing Incidents](https://sre.google/sre-book/managing-incidents/)):

- **Incident Commander (IC)** — owns the incident, decides, delegates. Does *not* debug.
- **Operations / Ops Lead** — the only person making changes to the system.
- **Communications Lead** — updates stakeholders and the status page.
- **Planning** — tracks bugs, handoffs, and the postmortem record.

**9.** Trigger a real incident. Break the service by removing public access, wait, then observe the alert fire and the email arrive.

```bash
gcloud run services remove-iam-policy-binding "$SERVICE" \
  --region="$REGION" --member="allUsers" --role="roles/run.invoker"

curl -s -o /dev/null -w "status=%{http_code}\n" "$URL"
```

Expected output:

```
status=403
```

Wait 6–8 minutes, then check **Monitoring → Alerting → Incidents**. Restore service:

```bash
gcloud run services add-iam-policy-binding "$SERVICE" \
  --region="$REGION" --member="allUsers" --role="roles/run.invoker"
```

### Checkpoint 4

- **Q4.1** — The uptime check in step 3 is *black-box* monitoring; the metrics in Exercise 3 are *white-box*. Define both, and give one thing each detects that the other cannot.
- **Q4.2** — Why does the uptime check probe from multiple continents rather than one? Describe the specific false conclusion a single-location probe can produce.
- **Q4.3** — Step 5 set `--duration=300s`. Explain the trade-off you made. What goes wrong at `30s`? What goes wrong at `3600s`?
- **Q4.4** — Define MTTD, MTTA, MTTR and MTBF. Your MTTR is 35 minutes and leadership wants it under 10. Name two changes that reduce MTTR *without* making the system any less likely to fail.
- **Q4.5** — During the step-9 incident, the IC has a strong hypothesis about the root cause. Should they start debugging? Justify from the role definitions.
- **Q4.6** — Your team receives 60 alerts per week, of which 4 are actionable. Name the pathology, state its second-order consequence, and give the SRE-canonical rule for what deserves a page.

---

## Exercise 5 — Resilience: failure domains, redundancy, and deployment archetypes

**Goal:** reliability is a property you *measure*; resilience is a property you *design*. This block is where the architecture happens.

### Steps

**1.** Enumerate the failure-domain hierarchy. Each level contains the one above it and fails independently of its siblings:

```
Resource  →  Zone  →  Region  →  Multi-region  →  Global
```

**2.** Inspect the real topology of a region:

```bash
gcloud compute zones list --filter="region:( us-central1 )" \
  --format='table(name, status, region.basename())'
```

Expected output:

```
NAME           STATUS  REGION
us-central1-a  UP      us-central1
us-central1-b  UP      us-central1
us-central1-c  UP      us-central1
us-central1-f  UP      us-central1
```

```bash
gcloud compute regions list --format='table(name, status)' | head -8
```

**3.** Compute redundancy math. **Serial** dependencies multiply; **parallel** redundancy multiplies the *failure* probabilities.

$$A_{\text{serial}} = \prod_i A_i \qquad\qquad A_{\text{parallel}} = 1 - \prod_i (1 - A_i)$$

```bash
python3 - <<'PY'
def budget(a): return (1-a)*43200
serial = 0.999 ** 4
print(f"4 services in series, each 99.9%  -> {serial:.5%}  ({budget(serial):.1f} min/30d)")
par2 = 1 - (1-0.99)**2
par3 = 1 - (1-0.99)**3
print(f"2 independent zones, each 99%     -> {par2:.5%}  ({budget(par2):.1f} min/30d)")
print(f"3 independent zones, each 99%     -> {par3:.5%}  ({budget(par3):.1f} min/30d)")
PY
```

Expected output:

```
4 services in series, each 99.9%  -> 99.60060%  (172.8 min/30d)
2 independent zones, each 99%     -> 99.99000%  (4.3 min/30d)
3 independent zones, each 99%     -> 99.99900%  (0.4 min/30d)
```

**4.** Study the **deployment archetypes** ([cloud.google.com/architecture/deployment-archetypes](https://cloud.google.com/architecture/deployment-archetypes)). Complete the empty columns before checking the answer key:

| Archetype | Survives a **zone** failure? | Survives a **region** failure? | Relative cost | Typical use |
|---|---|---|---|---|
| **Zonal** | ? | ? | $ | Dev, batch, non-critical |
| **Regional** | ? | ? | $$ | Most production workloads |
| **Multi-regional** | ? | ? | $$$ | Business-critical, DR-bound |
| **Global** | ? | ? | $$$$ | Planet-scale user-facing |
| **Hybrid / Multicloud** | ? | ? | $$$$ | Regulatory, cloud-exit, edge |

**5.** Classify your own lab service. Cloud Run is a **regional** product — a revision runs across the zones of one region, managed for you.

```bash
gcloud run services describe "$SERVICE" --region="$REGION" \
  --format='value(metadata.labels."cloud.googleapis.com/location", status.url)'
```

Expected output:

```
us-central1	https://reliability-lab-abc123def-uc.a.run.app
```

**6.** Design the promotion to multi-regional — the paper design is the exam-relevant part:

```
                       ┌──────────────────────────────────┐
   Users  ──────────▶  │  Global external Application LB  │  ← single anycast IP
                       │      (Cloud CDN + Cloud Armor)   │
                       └───────────┬──────────┬───────────┘
                                   │          │
                   serverless NEG  │          │  serverless NEG
                             ┌─────▼────┐ ┌───▼──────┐
                             │ Cloud Run│ │ Cloud Run│
                             │us-central1│ │europe-w1│
                             └─────┬────┘ └───┬──────┘
                                   │          │
                             ┌─────▼──────────▼─────┐
                             │  Spanner (multi-region)│  ← the hard part
                             └────────────────────────┘
```

Deploy the second region so the design is real:

```bash
gcloud run deploy "$SERVICE" \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region=europe-west1 \
  --allow-unauthenticated \
  --max-instances=2

gcloud run services list --format='table(metadata.name, region, status.url)'
```

**7.** Name the resilience mechanisms and match each to what it protects against. Do this from memory first:

| Mechanism | Protects against |
|---|---|
| Load balancing + health checks | ? |
| Autoscaling | ? |
| Managed instance group auto-healing | ? |
| Retries with exponential backoff **and jitter** | ? |
| Circuit breaker | ? |
| Graceful degradation | ? |
| Rate limiting / throttling | ? |
| Chaos engineering | ? |

**8.** Reason about the two hardest failure modes in the table above. Write two sentences on each:

- **Retry storm / metastable failure**: a service recovers, all clients retry simultaneously, the recovered service falls over again. Why does *jitter* — not just backoff — fix this?
- **Cascading failure**: service C degrades, B's threads block on C, A's threads block on B, the whole stack is down though only C was sick. Which mechanism in the table cuts the chain, and how?

### Checkpoint 5

- **Q5.1** — Fill in the archetype table from step 4.
- **Q5.2** — Four microservices each at 99.9% are chained synchronously. What is the end-to-end availability, and what is the general architectural lesson? Name one pattern that breaks the multiplication.
- **Q5.3** — A stakeholder says "we're multi-zone, so we're covered." Name three real failure classes that multi-zone does *not* protect against.
- **Q5.4** — In the step-6 design, why is the database layer described as "the hard part"? Name the physical constraint and the trade-off it forces.
- **Q5.5** — Complete the mechanism table from step 7.
- **Q5.6** — Distinguish *reliability* from *resilience* precisely. Give a system that is highly reliable but not resilient, and one that is resilient but shows poor measured reliability.
- **Q5.7** — What is chaos engineering, and what is the prerequisite a team must have in place *before* running its first experiment?

---

## Exercise 6 — Disaster recovery: RTO, RPO, and choosing a pattern you can afford

**Goal:** high availability and disaster recovery are different disciplines with different budgets. Get the two objectives right and the pattern selects itself.

### Steps

**1.** Fix the definitions:

- **RTO — Recovery Time Objective:** the maximum tolerable *time* the service may be unavailable. Measured on the clock.
- **RPO — Recovery Point Objective:** the maximum tolerable *data loss*, expressed as a time window. Measured backwards from the incident.

**2.** Map a concrete timeline. Backups run hourly at :00; the region fails at 14:47; service is restored elsewhere at 16:20.

```
 13:00        14:00              14:47            16:20
   │            │                  │                │
 backup      backup            DISASTER          restored
              └──── RPO: 47 min ───┘                │
                                  └── RTO: 93 min ──┘
```

**3.** Compute the two figures for a set of scenarios:

```bash
python3 - <<'PY'
scenarios = [
    ("Hourly snapshot, manual restore",       60, 240),
    ("15-min snapshot, scripted restore",     15,  45),
    ("Continuous replication, warm standby",   1,  10),
    ("Synchronous multi-region, active-active", 0,  0),
]
print(f"{'Pattern':<42}{'RPO(min)':>10}{'RTO(min)':>10}")
for name, rpo, rto in scenarios:
    print(f"{name:<42}{rpo:>10}{rto:>10}")
PY
```

Expected output:

```
Pattern                                     RPO(min)  RTO(min)
Hourly snapshot, manual restore                   60       240
15-min snapshot, scripted restore                 15        45
Continuous replication, warm standby               1        10
Synchronous multi-region, active-active            0         0
```

**4.** Study the DR patterns ([cloud.google.com/architecture/disaster-recovery](https://cloud.google.com/architecture/disaster-recovery)). Complete this table:

| Pattern | Standby state | Typical RTO | Typical RPO | Standby cost |
|---|---|---|---|---|
| **Backup & restore** (cold) | Nothing running | ? | ? | ? |
| **Pilot light** | Core minimal, data replicating | ? | ? | ? |
| **Warm standby** | Scaled-down full stack, running | ? | ? | ? |
| **Hot standby / multi-site** | Full capacity, serving | ? | ? | ? |

**5.** *(Optional — this step provisions a billable resource. Skip to step 6 for the paper-only path.)* Inspect a real backup and point-in-time-recovery configuration:

```bash
gcloud sql instances create dr-lab \
  --database-version=POSTGRES_15 \
  --tier=db-f1-micro \
  --region="$REGION" \
  --enable-point-in-time-recovery \
  --retained-transaction-log-days=7 \
  --backup-start-time=03:00

gcloud sql instances describe dr-lab \
  --format='yaml(settings.backupConfiguration)'
```

Expected output:

```yaml
settings:
  backupConfiguration:
    backupRetentionSettings:
      retainedBackups: 7
      retentionUnit: COUNT
    enabled: true
    pointInTimeRecoveryEnabled: true
    startTime: '03:00'
    transactionLogRetentionDays: 7
```

**Delete it immediately when done:**

```bash
gcloud sql instances delete dr-lab --quiet
```

**6.** Paper path: read the effect of the flags above without provisioning anything.

- `enabled: true` with `startTime: '03:00'` gives daily backups → **RPO up to 24 h**.
- `pointInTimeRecoveryEnabled: true` streams the write-ahead log continuously → **RPO drops to seconds**, at the cost of storing those logs.
- Neither flag changes **RTO** at all. RTO is governed by how long a restore takes and by whether the restore procedure is automated and *rehearsed*.

**7.** Assign patterns to three businesses. Justify each in one sentence:

| Business | Constraint | Your pattern |
|---|---|---|
| Payment processor | Losing one transaction is a regulatory incident | ? |
| E-commerce catalogue | 30 min offline is survivable; rebuildable from source of truth | ? |
| Internal HR reporting | Read-only, business hours, refreshed nightly | ? |

**8.** The step that most organisations skip:

```bash
# There is no gcloud command for this. Put it on a calendar.
echo "DR drill scheduled: restore prod backup into an isolated project, measure actual RTO."
```

### Checkpoint 6

- **Q6.1** — Define RTO and RPO, then compute both for the timeline in step 2.
- **Q6.2** — Fill in the DR pattern table from step 4.
- **Q6.3** — Which of RTO or RPO is driven mainly by *backup frequency*, and which by *restore automation and rehearsal*? Why do teams routinely improve one and forget the other?
- **Q6.4** — Distinguish high availability from disaster recovery. Give one failure that HA handles and DR does not, and one that DR handles and HA does not.
- **Q6.5** — Complete the assignment table in step 7.
- **Q6.6** — A CTO asks for "RPO zero and RTO zero" for every system in the company. Explain the cost and engineering consequences, and reframe the request as the question they should actually be asking.
- **Q6.7** — Why is a backup that has never been restored not a backup? Name the operational practice that fixes this.

---

## Exercise 7 — Modern operations: DevOps, SRE, DORA, and toil

**Goal:** the "modern operations" half of the objective. This is measurable engineering culture, not slogans.

### Steps

**1.** Place the three terms:

- **DevOps** — the cultural and organisational movement: shared ownership between development and operations, small frequent changes, automation, feedback loops.
- **SRE** — a concrete, opinionated implementation of DevOps, invented at Google, that runs on SLOs, error budgets and toil limits. *"class SRE implements DevOps."*
- **DORA** — the research programme that measures whether either is working. [dora.dev](https://dora.dev/)

**2.** The four DORA keys. Two are **throughput**, two are **stability** — and the finding that made DORA famous is that they move *together*, not against each other:

| Metric | Type | Measures |
|---|---|---|
| **Deployment frequency** | Throughput | How often you ship to production |
| **Lead time for changes** | Throughput | Commit → running in production |
| **Change failure rate** | Stability | % of deploys causing a degradation needing remediation |
| **Failed deployment recovery time** | Stability | How fast you recover from a bad deploy (earlier reports called this MTTR) |

> Benchmark thresholds are re-derived in each year's *State of DevOps* report — cite the year, do not memorise the numbers.

**3.** Compute the four keys from a synthetic deployment log:

```bash
cat > /tmp/deploys.csv <<'CSV'
deploy_id,commit_ts,deploy_ts,failed,restored_ts
d1,2026-09-01T09:00,2026-09-01T11:00,0,
d2,2026-09-01T14:00,2026-09-02T10:00,0,
d3,2026-09-03T08:00,2026-09-03T09:30,1,2026-09-03T10:15
d4,2026-09-04T10:00,2026-09-04T12:00,0,
d5,2026-09-07T09:00,2026-09-07T09:45,0,
d6,2026-09-08T11:00,2026-09-08T16:00,1,2026-09-08T16:20
CSV

python3 - <<'PY'
import csv, datetime as dt
f = "%Y-%m-%dT%H:%M"
rows = list(csv.DictReader(open("/tmp/deploys.csv")))
lead = [(dt.datetime.strptime(r["deploy_ts"],f)-dt.datetime.strptime(r["commit_ts"],f)).total_seconds()/3600 for r in rows]
fails = [r for r in rows if r["failed"]=="1"]
rec = [(dt.datetime.strptime(r["restored_ts"],f)-dt.datetime.strptime(r["deploy_ts"],f)).total_seconds()/60 for r in fails]
print(f"Deployment frequency        : {len(rows)} deploys / 8 days = {len(rows)/8:.2f}/day")
print(f"Lead time for changes (mean): {sum(lead)/len(lead):.1f} h")
print(f"Change failure rate         : {len(fails)/len(rows):.1%}")
print(f"Failed deploy recovery (mean): {sum(rec)/len(rec):.0f} min")
PY
```

Expected output:

```
Deployment frequency        : 6 deploys / 8 days = 0.75/day
Lead time for changes (mean): 6.5 h
Change failure rate         : 33.3%
Failed deploy recovery (mean): 32 min
```

**4.** Apply the SRE definition of **toil** ([SRE Book, Ch. 5](https://sre.google/sre-book/eliminating-toil/)). Work is toil if it is: *manual, repetitive, automatable, tactical, devoid of enduring value, and scaling linearly with service growth.* Audit this week:

| Task | Toil? | Why / why not |
|---|---|---|
| Manually restarting a service that leaks memory nightly | ? | ? |
| Designing next quarter's multi-region migration | ? | ? |
| Copying metrics into a spreadsheet for a weekly report | ? | ? |
| Handling a genuinely novel production incident | ? | ? |
| Approving 30 identical access requests per week | ? | ? |
| Writing a postmortem | ? | ? |

**5.** Understand the 50% rule: SRE caps toil at **50%** of an SRE's time; the remainder must go to engineering that reduces future toil. Compute the compounding effect:

```bash
python3 - <<'PY'
toil, growth, reduction = 0.35, 1.6, 0.30   # 60% yearly service growth, 30% yearly automation
for year in range(6):
    print(f"year {year}: toil = {min(toil,1):.0%}")
    toil = min(toil * growth * (1 - reduction), 1.0)
PY
```

Expected output:

```
year 0: toil = 35%
year 1: toil = 39%
year 2: toil = 44%
year 3: toil = 49%
year 4: toil = 55%
year 5: toil = 62%
```

Automating 30% per year is *not enough* if the service grows 60% per year. That is the whole argument for the cap.

**6.** Write a **blameless postmortem** for the step-9 incident in Exercise 4. Use this skeleton, and enforce the blameless rule: describe *what the system allowed*, never *who was careless*.

```markdown
# Postmortem: reliability-lab returned 403 to all users

**Status:** resolved
**Impact:** 100% of requests failed for 12 minutes. Error budget consumed: ~28% of the 30-day budget.
**Detection:** uptime check `reliability-lab-https`, alert fired at T+5m (MTTD 5 min).
**Root cause:** an IAM policy change removed `allUsers:roles/run.invoker` from the
production service. The change had no review gate and no canary.

## Timeline
- T+0    IAM binding removed
- T+0.5  first probe failure (Americas, Europe, APAC)
- T+5    alert fires, on-call paged
- T+7    on-call acknowledges (MTTA 7 min)
- T+12   binding restored, probes green (MTTR 12 min)

## What went well
- Multi-region probing eliminated "is it just me?" from the first two minutes.

## What went wrong
- No pre-deploy diff on IAM policy for production services.
- The 5-minute alert duration is tuned for flakiness, not for total outage.

## Action items
| # | Action | Type | Owner | Due |
|---|---|---|---|---|
| 1 | Deny-policy blocking removal of `run.invoker` on prod without approval | prevent | @platform | 2026-09-19 |
| 2 | Add a fast-burn (14.4x/1h) alert alongside the 5-min uptime alert | detect  | @sre | 2026-09-16 |
| 3 | Runbook: "service returns 403 to everyone" | mitigate | @sre | 2026-09-23 |
```

**7.** Identify the automation practices this objective expects you to name: **IaC** (Terraform / Config Controller), **CI/CD** (Cloud Build, Cloud Deploy), **GitOps**, **policy as code** (Organization Policy, Policy Controller), **progressive delivery** (canary, blue/green, traffic splitting).

Cloud Run gives you the last one directly:

```bash
gcloud run deploy "$SERVICE" \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region="$REGION" --no-traffic --tag=canary

gcloud run services update-traffic "$SERVICE" \
  --region="$REGION" --to-tags=canary=10
```

Expected output (abridged):

```
✓ Routing traffic... Done.
Traffic:
  90% reliability-lab-00001-xyz
  10% reliability-lab-00002-abc  (tag: canary)
```

### Checkpoint 7

- **Q7.1** — Distinguish DevOps, SRE and DORA in one sentence each.
- **Q7.2** — Name the four DORA keys, classify each as throughput or stability, and state DORA's central counter-intuitive finding.
- **Q7.3** — From the step-3 output, which single metric is most alarming and what does it most likely indicate about the delivery pipeline?
- **Q7.4** — Complete the toil audit table in step 4.
- **Q7.5** — Explain the step-5 output to a manager who believes "we automated a lot last year, so toil should be going down."
- **Q7.6** — What makes a postmortem *blameless*, and what is the concrete engineering benefit — not the emotional one?
- **Q7.7** — In step 7 you sent 10% of traffic to a new revision. Name the practice, and explain how it lowers *change failure rate* and *failed deployment recovery time* simultaneously.

---

## Exercise 8 — Capstone: a reliability review under real constraints

**Goal:** integrate every block into one decision, which is the form the exam question takes.

### Scenario

*Cordillera Health* runs a patient-appointment platform on Google Cloud.

- Current architecture: Compute Engine MIG in **one zone** of `southamerica-east1`, one Cloud SQL instance, no replica, nightly backup at 02:00.
- Traffic: 08:00–20:00 local, peaks Monday mornings at 8× the daily mean.
- Last quarter: 3 outages, 52, 95 and 210 minutes. No SLO exists. Alerts are CPU-threshold based; the on-call receives ~80 alerts/week.
- The board demands "99.99% availability" after the 210-minute outage.
- Regulatory: appointment records must not be lost. Records are also written to an on-premises system of record.

### Steps

**1.** Compute last quarter's measured availability against a 30-day window:

```bash
python3 - <<'PY'
downtime = 52 + 95 + 210          # minutes over 90 days
window   = 90 * 24 * 60
a = 1 - downtime/window
print(f"measured availability = {a:.4%}")
for target in (0.99, 0.995, 0.999, 0.9999):
    print(f"  target {target:.2%}: budget {(1-target)*window:8.1f} min/90d "
          f"-> {'MET' if downtime <= (1-target)*window else 'MISSED'}")
PY
```

Expected output:

```
measured availability = 99.7183%
  target 99.00%: budget   1296.0 min/90d -> MET
  target 99.50%: budget    648.0 min/90d -> MET
  target 99.90%: budget    129.6 min/90d -> MISSED
  target 99.99%: budget     13.0 min/90d -> MISSED
```

**2.** Draft the reliability specification. Fill every cell:

| Item | Your answer |
|---|---|
| Availability SLI definition (good / valid) | ? |
| Latency SLI definition | ? |
| Proposed SLO and window | ? |
| Resulting error budget (min/30d) | ? |
| RTO | ? |
| RPO | ? |
| Deployment archetype | ? |
| DR pattern | ? |

**3.** List the changes in priority order, and for each state which failure the *last* quarter's outages it would have prevented.

**4.** Write the two-sentence response to the board's "99.99%" demand.

### Checkpoint 8

- **Q8.1** — Give your filled-in table from step 2, with a one-line justification per row.
- **Q8.2** — What is your priority-ordered change list, and which single change gives the largest availability improvement per dollar?
- **Q8.3** — Is 99.99% the right target for this platform? Answer with numbers, not opinion, and state what you would propose instead.
- **Q8.4** — The on-call gets 80 alerts/week under CPU thresholds. Describe precisely what replaces them and why the replacement produces fewer, better alerts.
- **Q8.5** — Records are also written to an on-premises system of record. How does that fact change your RPO requirement, and what does it *not* excuse you from?

---

## Exercise 9 — Teardown

Run this whether or not you completed the optional Cloud SQL step. Leaving resources running is the most common way a Free Tier project starts billing.

```bash
gcloud run services delete "$SERVICE" --region="$REGION" --quiet
gcloud run services delete "$SERVICE" --region=europe-west1 --quiet

gcloud logging metrics delete client_errors_404 --quiet

UPTIME_ID="$(gcloud monitoring uptime list-configs \
  --filter='displayName="reliability-lab-https"' --format='value(name)')"
[ -n "$UPTIME_ID" ] && gcloud monitoring uptime delete "$UPTIME_ID" --quiet

POLICY="$(gcloud alpha monitoring policies list \
  --filter='displayName="reliability-lab uptime failure"' --format='value(name)')"
[ -n "$POLICY" ] && gcloud alpha monitoring policies delete "$POLICY" --quiet

[ -n "$CHANNEL" ] && gcloud beta monitoring channels delete "$CHANNEL" --quiet

gcloud sql instances delete dr-lab --quiet 2>/dev/null || true

echo "teardown complete"
```

Verify nothing remains:

```bash
gcloud run services list
gcloud monitoring uptime list-configs
gcloud sql instances list
```

---

<details>
<summary><strong>📖 Answer key — expand only after attempting every checkpoint</strong></summary>

## Exercise 1 — SLI, SLO, SLA

**A1.1** — What changed is the **definition of a "good event"**: step 7 counted only `5xx` as bad; step 8 also counted `4xx`. The system's behaviour was identical. The document that pins this down is the **SLI specification** — the precise, written statement of *good events / valid events*. An SLO is meaningless without it, and the most common real-world reliability dispute ("engineering says 99.95%, support says 97%") is almost always two teams using different, unwritten SLI specs.

**A1.2**
- **SLI (Service Level Indicator):** a quantitative measurement of one aspect of service quality, normally expressed as a ratio of good events to valid events — e.g. "the proportion of HTTP requests returning non-5xx within 300 ms."
- **SLO (Service Level Objective):** a target value for an SLI over a stated window — e.g. "99.9% of requests over a rolling 28 days." Internal, chosen by the team, and the input to the error budget.
- **SLA (Service Level Agreement):** a contract with a customer containing an SLO plus **consequences** for missing it — typically service credits.

**Only the SLA has legal and financial consequences.** SLIs measure, SLOs guide engineering priority, SLAs create liability.

**A1.3** — **99.95%.** The internal SLO must be **stricter** than the external SLA, so the SLO is breached — and triggers corrective engineering — *before* the contract is breached and money is owed. That gap is the safety margin.

Failure modes of the wrong answers:
- **99.9% (equal to the SLA):** there is zero warning. The instant your SLO alert fires you are already paying service credits. You have converted an early-warning system into a billing notification.
- **99.5% (looser than the SLA):** actively harmful. Your monitoring reports "SLO healthy" while you are in contractual breach — the dashboard is green during a legal incident.

**A1.4** — Both positions are defensible, which is exactly why it must be written down:

*Count them as bad* — the user experienced a failure. If the 404s come from a broken link your own frontend emits, or a route that a bad deploy dropped, the user's session is broken and no amount of "technically the server responded correctly" changes that. `4xx` spikes are a real production signal.

*Do not count them* — an availability SLI measures whether **your service** is meeting its contract. A client requesting `/nonexistent` receives the semantically correct answer; the server is healthy. Counting arbitrary client behaviour as your failure makes the SLI trivially attackable: a single misbehaving scraper can burn your entire error budget without your service degrading at all.

**Standard practice:** exclude `4xx` from availability (they are usually *invalid* events, not bad ones), but track them separately — often as a log-based metric, exactly as in Exercise 3 — and treat a sudden `4xx` spike as its own alerting condition. If a specific `4xx` code is known to be caused by your own service (e.g. `429` from your own rate limiter), name it explicitly in the spec.

**A1.5** — Because the mean hides the tail. With 200 requests at 30 ms and one at 412 ms, the mean is ≈ 32 ms — indistinguishable from a service with no cold start at all. But that one user waited nearly half a second. At production scale the same arithmetic hides *thousands* of slow requests behind a healthy-looking average, and those requests are disproportionately your most active users (more requests → higher chance of hitting a tail event).

Use **percentiles**: p50 for the typical experience, p95 and p99 for the tail. The canonical latency SLI is not a percentile of latency but a **ratio**: *"the proportion of requests served faster than 300 ms"* — which converts latency into the same good/valid form as availability and makes it directly composable into an error budget.

---

## Exercise 2 — Error budgets and burn rate

**A2.1** — 99.999% over 30 days allows **0.43 minutes ≈ 25.9 seconds** of downtime per month.

Arguments against:
1. **Cost is superlinear, value is not.** Each additional nine roughly multiplies the engineering and infrastructure investment — multi-region active-active, synchronous replication, zero-downtime deploys, 24/7 follow-the-sun on-call. For an internal expense tool the marginal value of moving from 99.9% (43 min/month) to 99.999% (26 s/month) is essentially zero: employees file expenses on a weekday, and a 40-minute outage costs a few postponed submissions.
2. **The SLO would be undetectable and unachievable in practice.** 26 seconds is inside the noise floor: a single instance restart, a deploy, a dependency's own SLA, or the monitoring pipeline's own latency can consume the entire budget. An SLO you breach for reasons outside your control gets ignored within two months — and once one SLO is ignored, all of them lose authority.

The reframe: ask what downtime actually costs the business per hour, then buy the cheapest target that keeps that cost acceptable. For an internal tool that is usually **99.5% or 99.9%**.

**A2.2** — **No, it is not acceptable.**

Day 9 of 30 is 30% of the window elapsed, but 62% of the budget is consumed. The average burn rate is 62/30 ≈ **2.07×**. At that sustained rate the budget is exhausted around day 14.5 — halfway through the window — leaving 15+ days with zero budget and an automatic feature freeze.

The on-call should conclude: this is not a paging emergency (2× is a slow burn, well under the 14.4× fast-burn threshold), but it *is* a ticket, and it demands investigation now rather than at the end of the month. The correct actions are to identify what changed around the start of the burn, and to warn the product owner that the freeze is likely — before it lands as a surprise.

**A2.3** — The **long window** measures significance; the **short window** measures currency.

- **Long window alone:** a slow-decaying alert. Once a 1-hour or 6-hour window has accumulated enough bad events to breach, it keeps breaching for the rest of that window *even after the outage is fixed*. The on-call fixes the problem at 14:20 and the page keeps firing until 15:20. That trains people to ignore it. The short window acts as a **reset condition** — the alert clears as soon as the *current* error rate returns to normal.
- **Short window alone:** intolerable noise. A 5-minute window over a low-traffic service breaches on a handful of failed requests, a single instance restart, or a deploy. You would page dozens of times a week for events that consume a negligible fraction of the budget.

Requiring **both** windows to breach simultaneously gives you an alert that is *significant* (the long window proves real budget is being spent) and *current* (the short window proves it is still happening). That is the whole design.

**A2.4** — To an executive:

> The error budget is not a technical metric — it is the **negotiated agreement between product and engineering about how much risk we take**. We agreed that 99.9% is the reliability our customers need; the budget is the 0.1% of unreliability we deliberately allow ourselves to *spend* on shipping fast. Every risky launch, every skipped test, every hurried deploy draws on it. When it is gone, we have already delivered the amount of unreliability our customers agreed to tolerate this month.
>
> Pausing the policy does not create more budget — it just removes the mechanism that tells us we have run out. It converts the SLO from a commitment into a suggestion, and it moves the cost from our roadmap to our customers, where we cannot see it until they leave.

The right counter-move is not to pause the policy but to **negotiate the SLO** — with the data. If the business genuinely wants more velocity, propose lowering the target to 99.5% *explicitly*, so the risk is a decision on the record rather than an accident.

**A2.5** — Consistently finishing the window with an untouched budget means the SLO is **set too low relative to what the system actually delivers**, and that is a form of waste:

1. **You are over-invested in reliability.** Engineering effort, redundancy and infrastructure that produce reliability *above* the target buy nothing the business asked for. That capacity should go to features.
2. **You are shipping too slowly.** Unspent budget is permission you declined to use. It should have been spent on faster releases, larger experiments, or a migration you kept postponing.
3. **You have set customer expectations you cannot walk back.** If users experience 100% for six months, they will build workflows assuming it — and your actual 99.9% commitment becomes politically unenforceable. (This is why some teams deliberately inject controlled downtime; Google's Chubby lock service is the canonical example.)

The response is to **raise the SLO to match reality, or spend the budget deliberately.** A budget that is never consumed is a target that is not doing its job.

---

## Exercise 3 — Observability

**A3.1**
- **Monitoring** answers questions you knew to ask. In this exercise: the Cloud Run dashboard showing request count and latency. You predefined the metric, the dashboard and the threshold. It tells you **that** something is wrong.
- **Observability** is the property of a system that lets you answer questions you did *not* anticipate, from its external outputs, without shipping new code. In this exercise: the `gcloud logging read` query in step 6, where you sliced raw request logs by status code after the fact — and the log-based metric in step 5, where you created a brand-new measurement from data that was already being emitted. It tells you **why**.

The practical test: when a novel failure occurs, can you investigate it with the telemetry you already have, or must you deploy new instrumentation and wait for it to recur? The second answer means you have monitoring, not observability.

**A3.2**

| Signal | User-visible degradation |
|---|---|
| **Latency** | The page hangs; the spinner runs; the checkout feels broken even though it eventually works |
| **Traffic** | A collapse means users cannot reach you at all (DNS, LB, upstream); a spike means a launch, a bot, or an attack |
| **Errors** | Explicit failure — a 500 page, a failed payment, a lost form submission |
| **Saturation** | Nothing yet, then everything at once — queues grow, then latency rises, then timeouts turn into errors. Saturation is the **leading** indicator; it degrades before users notice, which is why it is the one to alert on for capacity |

**A3.3**

| Signal | Google Cloud product |
|---|---|
| Metrics | **Cloud Monitoring** |
| Logs | **Cloud Logging** |
| Traces | **Cloud Trace** |

(The wider suite adds **Cloud Profiler** for continuous CPU/heap profiling and **Error Reporting** for aggregating exceptions.)

**Logs are the most expensive at scale.** Metrics are pre-aggregated — a counter's storage cost is roughly independent of how many events it counts. Logs store every individual event with full context, so cost grows linearly with traffic *and* with how verbose each entry is. This is precisely why log-based metrics exist: convert the high-value pattern into a cheap counter, then let the raw logs expire on a short retention policy. High cardinality is the other trap — a label like `user_id` on a metric explodes the time-series count and can cost more than the logs did.

**A3.4** — Latency is not one number per interval; it is thousands of numbers per interval. A **distribution** metric stores them as histogram buckets, which preserves the *shape* of the response-time population.

If the platform stored only the mean you would lose:
- **All percentiles.** p50, p95 and p99 are not recoverable from a mean — the arithmetic simply does not exist.
- **Multimodality.** A service with a fast cache path (5 ms) and a slow cold path (500 ms) has the same mean as a uniformly mediocre service at 250 ms, and they need completely different fixes.
- **The ability to define a latency SLI at all.** "99% of requests under 300 ms" requires knowing how many requests fell under 300 ms, which is a bucket count.

Buckets also aggregate correctly: you can sum histograms across regions and revisions and still compute a valid global p99. You cannot average averages.

**A3.5** — That is **saturation**, and it demonstrates **autoscaling** (elasticity: capacity tracking demand automatically in both directions) and **capacity management without manual intervention** — the operations burden of provisioning for peak is removed.

The subtlety worth noting: the instance count stopped at 3 because you set `--max-instances=3`. A limit protects downstream dependencies from being overwhelmed and caps runaway cost, but it also means that beyond that point, additional load turns into **queueing → latency → errors**. Every autoscaling ceiling is a deliberate decision about which failure mode you prefer.

**A3.6** — **Traces** (Cloud Trace) — specifically distributed tracing, which propagates a trace context across service boundaries so one request's full path is reconstructed as a tree of timed spans. The trace shows immediately that the `inventory` span went from 40 ms to 900 ms while the other two are unchanged.

Metrics cannot answer this because they are **aggregated and disconnected**. You can see that your service's p99 doubled, and separately that three downstream services each have their own p99 — but there is no join between them. Averages across all requests hide the fact that only requests hitting a particular code path are slow, and if two downstream services both degraded slightly you cannot tell which combination produced your tail. Traces preserve **causality within a single request**, which is exactly the dimension aggregation destroys.

---

## Exercise 4 — Detection and incident response

**A4.1**
- **Black-box monitoring** probes the system from the outside, as a user would, with no knowledge of internals. The uptime check makes an HTTPS request from the public internet and records the response. It is **symptom**-oriented.
- **White-box monitoring** uses telemetry the system emits about itself — internal metrics, logs, traces. It is **cause**-oriented.

What each uniquely detects:
- **Black-box only:** the entire request path outside your application — DNS resolution failure, an expired TLS certificate, a misconfigured load balancer, a broken IAM binding (exactly the step-9 incident: your container was perfectly healthy and emitting perfectly healthy metrics while 100% of users got 403), a BGP or CDN problem. If your service is fine but nobody can reach it, only black-box notices.
- **White-box only:** anything internal that has not yet reached the user — a queue depth growing, a memory leak at 60% of the limit, a connection pool at 90% saturation, a p99 rising within SLO. These are the *predictive* signals that let you act before an outage.

You need both. Black-box is what you page on (it correlates with user pain); white-box is what you debug with.

**A4.2** — Because a single probe location cannot distinguish **"the service is down"** from **"the path between one probe and the service is down."**

The specific false conclusion: a network problem local to one region — a peering issue, a transit provider outage, a regional DNS resolver failure — makes the service look globally dead when it is serving every other continent normally. You page the on-call at 03:00 for a problem in someone else's network. The inverse is worse: a probe in the same region as your service can succeed over an internal path while every external user is failing, so you see green during a real outage.

Multi-location probing turns this into a *quorum*: all locations failing is a real outage; one location failing is a network event to investigate but not to page on. It also gives you regional latency data for free.

**A4.3** — The `--duration` setting is the trade-off between **false positives** and **detection time (MTTD)**.

- **At `30s`:** you page on transient noise — a single instance restart, a brief network blip, one slow probe, a normal deploy. High false-positive rate leads directly to alert fatigue (Q4.6). You buy 4.5 minutes of MTTD and pay for it with an on-call rotation that stops trusting the pager.
- **At `3600s`:** you have a 60-minute MTTD floor. A total outage runs for an hour before anyone is told. If your SLO is 99.9% (43 min/month), a *single* undetected outage has already blown the entire monthly budget before the alert fires. The alert is arithmetically incapable of protecting the SLO it exists to protect.

The principled way to set this is not to guess a duration but to **derive it from the error budget**: pick the window from the burn-rate table in Exercise 2 (14.4× over 1 hour with a 5-minute short window). Then the alert's sensitivity is a mathematical consequence of the SLO rather than a hunch. In practice, a real service runs *both*: a fast-burn page for catastrophic failure and a slow-burn ticket for degradation.

**A4.4**
- **MTTD — Mean Time To Detect:** incident starts → monitoring notices.
- **MTTA — Mean Time To Acknowledge:** alert fires → a human takes ownership.
- **MTTR — Mean Time To Repair/Recover/Restore:** incident starts → service healthy again. (Ambiguous in the wild — some organisations measure from detection rather than from onset; define it before reporting it.)
- **MTBF — Mean Time Between Failures:** average interval between incidents. Availability relates them: `MTBF / (MTBF + MTTR)`.

Two changes that reduce MTTR without touching failure probability:
1. **One-command, always-available rollback.** Most production incidents are change-induced. If reverting to the last known-good revision is a single command that any on-call can run without understanding the root cause, you decouple *recovery* from *diagnosis* — the single largest MTTR reduction available to most teams. Cloud Run's `update-traffic` to a previous revision is exactly this.
2. **Runbooks linked directly from the alert.** The alert should carry a link to a document that states what this alert means, what to check first, and what the known mitigations are. This attacks the "on-call spends 20 minutes rediscovering context" segment of every incident timeline. Its close cousin is reducing MTTA with a properly staffed rotation and escalation policy.

Note both are **operational** improvements. They change how fast you recover, not how often you break — which is precisely why MTTR and MTBF are separate levers, and why DORA treats recovery time as a first-class metric.

**A4.5** — **No.** The Incident Commander must not debug.

The IC's function is to hold the *global* picture: who is doing what, what has been tried, what the customer impact is, whether to escalate, whether to declare the incident resolved. The moment the IC opens a terminal and starts investigating their hypothesis, they lose that picture — attention narrows to one theory, coordination stops, two people start making changes to the same system without knowing about each other, and nobody is tracking whether the hypothesis is being disproven.

The correct move: the IC **states the hypothesis to the Ops Lead and delegates the investigation**, then keeps coordinating. The IC's knowledge is not wasted — it becomes an instruction rather than an action. Role separation exists because the failure mode it prevents (everyone debugging, nobody commanding) is the single most common way an incident response degrades into chaos.

**A4.6** — The pathology is **alert fatigue**, driven by a very low signal-to-noise ratio (4/60 ≈ 7% actionable).

The second-order consequence is the dangerous one: **the team stops trusting the pager**. Alerts get muted, auto-filtered into a folder, or acknowledged reflexively without investigation. Eventually a *real* alert arrives in that stream and is dismissed with the same reflex as the 56 noisy ones. Alert fatigue does not merely annoy people — it **increases MTTD for genuine incidents**, so a noisy monitoring system is measurably worse than a quiet one. It also drives on-call burnout and attrition, which removes the institutional knowledge that makes incidents short.

The canonical SRE rule: **page only on symptoms that are user-visible and require immediate human action.** Everything else is a ticket, a dashboard, or deleted. Concretely, an alert deserves a page only if it is *urgent* (waiting until morning makes it worse), *actionable* (there is something a human can do right now — a page for a condition with no remedy is pure noise), and *novel* (if the response is always the same three commands, automate them instead). Alerting on SLO burn rate rather than on resource thresholds does most of this filtering automatically: CPU at 90% is not a symptom, users getting errors is.

---

## Exercise 5 — Resilience and architecture

**A5.1**

| Archetype | Survives zone failure? | Survives region failure? | Cost | Use |
|---|---|---|---|---|
| **Zonal** | ❌ No | ❌ No | $ | Dev/test, batch that can be re-run, non-critical internal tools |
| **Regional** | ✅ Yes | ❌ No | $$ | The default for most production workloads |
| **Multi-regional** | ✅ Yes | ✅ Yes | $$$ | Business-critical, regulated, DR-bound systems |
| **Global** | ✅ Yes | ✅ Yes (+ latency routing) | $$$$ | Planet-scale user-facing services |
| **Hybrid / Multicloud** | ✅ Yes | ✅ Yes (+ provider failure) | $$$$ | Data-residency law, cloud-exit strategy, edge/on-prem integration |

The distinction between multi-regional and global is worth holding: multi-regional is about *fault tolerance* across regions; global adds a single anycast entry point that routes each user to the nearest healthy region, so it also buys *latency* — and it means a regional failure is handled by the load balancer, transparently, rather than by a failover procedure.

**A5.2** — `0.999⁴ = 0.99601` → **99.601%**, an error budget of **172.8 min/30d** — four times worse than any individual component.

The lesson: **synchronous dependencies multiply, so availability only ever goes down as you add hops.** A microservice architecture where every request traverses four services cannot be more available than the product of their SLOs, no matter how good each one is. This is the quantitative argument against deep synchronous call chains and the reason "we'll just add a service" is never free.

Patterns that break the multiplication:
- **Asynchronous decoupling** (Pub/Sub, task queues): the caller publishes and returns; the downstream service can be down for minutes without the user request failing. The dependency is removed from the critical path entirely.
- **Graceful degradation with a fallback:** if the recommendations service is down, serve a cached or generic list instead of failing the page. The dependency becomes optional rather than required.
- **Caching:** a cache hit does not consume the downstream service's availability at all.
- **Redundancy at each tier:** raising each component's own availability via parallel instances (see the parallel formula) partially offsets the serial multiplication.

**A5.3** — Multi-zone protects against *infrastructure* failure inside one datacentre. It does **not** protect against:

1. **Region-wide failure.** Zones share a metropolitan area — a natural disaster, a regional network or control-plane event, or a power grid failure at metro scale can take out every zone at once. Multi-zone is by definition single-region.
2. **Bad code and bad configuration.** This is the big one, and the most common cause of real outages. A broken deploy, a corrupt config push, a bad IAM policy (exactly the step-9 incident) or a schema migration that drops a column replicates to every zone *instantly and by design*. Redundancy faithfully reproduces your mistake in triplicate. The mitigations are progressive delivery, canaries and fast rollback — not more zones.
3. **Data-level disasters.** Accidental deletion, ransomware, and logical corruption propagate to every replica. Replication is not backup: it copies the damage. This is what point-in-time recovery and immutable, isolated backups exist for.

Honourable mentions in the same category: dependency on a single global control plane, a shared quota being exhausted, an expired certificate, and DNS.

**A5.4** — Because compute is stateless and state is not. You can run identical Cloud Run containers in two regions trivially — they hold nothing. The database holds the truth, and the truth cannot be in two places at once without a decision.

The physical constraint is **the speed of light**. `us-central1` to `europe-west1` is roughly 100 ms round trip, and no engineering removes it. So:

- **Synchronous replication** — every write is acknowledged by both regions before returning. RPO = 0, no data loss on regional failure. Cost: every write pays the inter-region round trip, so write latency goes from ~5 ms to ~100 ms+. For a write-heavy transactional workload this is often unacceptable.
- **Asynchronous replication** — the primary acknowledges immediately and ships changes in the background. Write latency stays local. Cost: **RPO > 0** — a regional failure loses whatever was in flight, and you must decide whether losing 5 seconds of writes is tolerable. It also introduces a failover decision (promote the replica? risk split-brain?) that adds to RTO.

This is the CAP/PACELC trade-off in operational clothing, and it is why **Cloud Spanner** appears in the diagram: it provides synchronous multi-region consistency with external consistency guarantees, using TrueTime to bound clock uncertainty — at a price, and with a write-latency floor set by geography. Choosing your database's replication mode *is* choosing your RPO, and it is the decision that determines whether "multi-region" means real failover or a comforting diagram.

**A5.5**

| Mechanism | Protects against |
|---|---|
| **Load balancing + health checks** | Individual instance or backend failure — traffic is steered away from unhealthy endpoints automatically, usually before users notice |
| **Autoscaling** | Demand-driven saturation — traffic spikes, Monday-morning peaks, viral events, and the cost of over-provisioning for peak |
| **MIG auto-healing** | Instances that are running but broken (hung process, failed health check) — the platform recreates them without a human |
| **Retries with exponential backoff + jitter** | Transient faults: a dropped packet, a brief 503, a leader election. The backoff prevents amplification; the **jitter** prevents synchronisation |
| **Circuit breaker** | Cascading failure — stops sending requests to a known-failing dependency so callers fail fast instead of exhausting their own threads/connections waiting |
| **Graceful degradation** | Non-essential dependency failure — serve a cached, simplified or partial response instead of an error page. Turns a total outage into a reduced experience |
| **Rate limiting / throttling** | Overload from any source: abusive clients, runaway retries, a buggy integration, or a genuine spike larger than your capacity. Protects the majority by rejecting the excess deterministically |
| **Chaos engineering** | *Untested assumptions* — the belief that your failover works. It does not prevent a failure; it finds the ones your design has not accounted for, in daylight, with everyone watching |

**A5.6**
- **Reliability** is the measured outcome: does the service do what users need, at the level promised, over time? It is what the SLI/SLO framework quantifies. It is *observed*.
- **Resilience** is the system property that produces it: the ability to absorb faults, degrade gracefully and recover automatically without human intervention. It is *designed*.

Reliable but not resilient: a single-zone VM that has simply not failed for two years. Its SLI reads 99.99%; its availability is entirely a matter of luck. The first zone-level event turns 99.99% into a multi-hour outage, because there is no mechanism to absorb the failure — only an absence of failures so far. This is the "we've never had an outage" argument, and it is the most dangerous sentence in operations.

Resilient but poor measured reliability: a well-architected multi-region system in its first month, where a bad deploy and a bad config push each caused visible incidents. The architecture absorbs infrastructure faults perfectly — but resilience to *infrastructure* failure gives no protection against *change*-induced failure, which is the majority of real outages. Its SLI is poor for reasons the redundancy was never designed to address.

The pair matters because they are improved by different work: reliability by measuring and prioritising, resilience by architecture — and neither substitutes for the other.

**A5.7** — **Chaos engineering** is the practice of deliberately injecting controlled failures into a system — terminating instances, adding latency, dropping a dependency, failing a zone — in order to *empirically verify* that the resilience mechanisms you designed actually work, and to discover the failure modes you did not anticipate. It moves the discovery of broken failover from 03:00 on a Sunday to 14:00 on a Tuesday with the whole team watching.

The prerequisite, and it is non-negotiable: **you must be able to observe and measure the blast radius, and stop the experiment.** Concretely that means (a) SLOs and telemetry good enough to detect the induced impact within seconds, (b) a defined, tested abort procedure, (c) a bounded blast radius — start in a pre-production environment or a small traffic slice, and (d) explicit organisational buy-in, because an experiment nobody agreed to is just an outage you caused.

Running chaos experiments without observability is not an experiment: you break something, learn nothing about the mechanism, and cannot tell whether the damage has stopped. The order is always **measure first, then break.** For the same reason, teams should fix the failures they already know about before hunting for new ones.

---

## Exercise 6 — Disaster recovery

**A6.1**
- **RTO (Recovery Time Objective):** the maximum acceptable duration of the outage — how long until service is restored. A *time-to-recover* target.
- **RPO (Recovery Point Objective):** the maximum acceptable amount of data loss, expressed as the time window whose writes you can afford to lose. A *data-loss* target.

For the step-2 timeline:
- **RPO = 47 minutes.** The last successful backup was at 14:00; the disaster struck at 14:47. Everything written in that 47-minute gap is gone.
- **RTO = 93 minutes.** From 14:47 (failure) to 16:20 (restored).

Note that both are *objectives* — targets you commit to — and what the timeline shows is the *achieved* value. A DR plan is only meaningful when the achieved values, measured in a real drill, are inside the objectives.

**A6.2**

| Pattern | Standby state | Typical RTO | Typical RPO | Standby cost |
|---|---|---|---|---|
| **Backup & restore** (cold) | Nothing running; backups in Cloud Storage | Hours to days | Hours (= backup interval) | Lowest — storage only |
| **Pilot light** | Minimal core running, data continuously replicating | Tens of minutes to hours | Minutes to seconds | Low — small always-on footprint |
| **Warm standby** | Scaled-down but complete stack, running and replicating | Minutes | Seconds | Medium — a fraction of prod |
| **Hot standby / multi-site** | Full capacity, actively serving | Seconds to zero | Near zero to zero | Highest — a full second production |

The shape of the table is the lesson: **RTO and RPO are bought with money**, roughly monotonically. There is no configuration that gives you hot-standby recovery at cold-standby cost, and any vendor claim to the contrary should be read carefully.

**A6.3**
- **RPO is driven by backup/replication frequency.** Hourly snapshots cap your RPO at one hour; continuous WAL streaming (PITR) drops it to seconds. It is a *data-plane* property.
- **RTO is driven by restore automation and rehearsal.** It is the sum of: detect → decide → execute → validate → cut traffic over. Backup frequency has zero effect on it. It is a *process* property.

Teams improve RPO and forget RTO because **RPO is a checkbox and RTO is a practice.** Enabling PITR is one flag, visible in a config file, auditable, and it stays done. RTO requires someone to actually restore a production backup into a clean environment, discover that the IAM bindings are missing, that the DNS TTL is 24 hours, that the runbook references a person who left, and that nobody knows the decryption key owner — and then fix all of it, and do it again next quarter because it decays. The config change is permanent; the capability is perishable.

The result is the classic failure: an organisation with excellent backups, a 15-second RPO, and a 14-hour actual RTO that nobody has ever measured.

**A6.4**
- **High availability (HA)** is about surviving *component* failure within a normal operating environment, automatically and continuously — redundant instances, multi-zone deployment, health-checked load balancing, automatic failover. It is always-on, measured in the SLO, and involves no human decision.
- **Disaster recovery (DR)** is about surviving the loss of an entire environment — a region, a dataset, an account — and involves a deliberate recovery *procedure*, usually with a human decision point, measured by RTO and RPO.

Handled by HA but not DR: a single VM crashing, a zone becoming unavailable, one backend failing a health check. The MIG replaces it or the load balancer routes around it in seconds; no DR plan is invoked and no data is restored — indeed invoking a DR failover for a single instance failure would be a far worse outcome than the failure itself.

Handled by DR but not HA: **logical destruction of data.** A `DROP TABLE`, ransomware, a bad migration, or an accidental bulk delete. HA replication propagates the damage to every replica at machine speed — that is exactly what replication is for. Only a point-in-time restore from an immutable backup recovers it. Region-wide loss is the other clear case: HA within a region has nothing left to fail over to.

The rule worth carrying: **replication is not backup.** HA protects against things breaking; DR protects against things being *wrong*.

**A6.5**

| Business | Pattern | Justification |
|---|---|---|
| **Payment processor** | **Hot standby / multi-site**, synchronous replication | RPO must be zero — a lost transaction is a regulatory and financial incident, not an inconvenience. That mandates synchronous multi-region writes (Spanner-class), and the write-latency and cost penalty is simply the price of the compliance requirement |
| **E-commerce catalogue** | **Warm standby** or pilot light | 30 minutes of RTO is explicitly acceptable, and the catalogue is rebuildable from an upstream source of truth — so RPO tolerance is generous. Paying for hot standby here buys recovery time the business has already said it does not need |
| **Internal HR reporting** | **Backup & restore** (cold) | Read-only, business hours, nightly refresh. A 24-hour RPO is inherent in the data's own refresh cycle — you cannot lose data that has not changed. A multi-hour RTO costs the business a delayed report. Anything more is spending money to protect against a non-event |

The meta-point: all three answers are correct *for their constraint*, and the constraint comes from the business, not from engineering taste. The exam tests whether you can read the constraint out of the scenario.

**A6.6** — What "RPO 0 and RTO 0 for everything" actually costs:

- **RPO 0** requires synchronous replication to a geographically separate location for every stateful system. Every write pays the inter-region round trip — realistically 50–150 ms added to each transaction — so throughput on write-heavy systems falls and some applications become unusable. Systems that cannot do synchronous multi-region replication must be re-architected or replaced.
- **RTO 0** requires a fully provisioned, actively serving second environment for every system, plus automated failover, plus continuous verification that the failover works. That is roughly **2× the infrastructure bill**, plus the engineering to build and maintain it, plus the ongoing drill cadence.
- Applied *company-wide*, the majority of that spend protects systems where an outage costs almost nothing — internal tools, reporting, batch pipelines.

The reframe:

> "Zero is achievable, and here is what it costs. The question that gets us the right answer isn't 'what recovery do we want?' — everyone wants instant. It's **'what does an hour of downtime, or an hour of lost data, cost this specific system?'** Then we buy the recovery each system's own risk justifies. For payments that will genuinely be near-zero. For the internal wiki it will be a nightly backup. Applying the payments standard to the wiki doubles our infrastructure bill to protect something nobody would notice was gone."

This is **tiering**, and it is the standard professional answer: classify systems into two or three recovery tiers, assign RTO/RPO per tier, and defend the classification rather than the number.

**A6.7** — Because a backup is not an artefact; it is a **capability**, and the artefact is only one of its parts. An untested backup is an untested *assumption* that the file is complete, that it is not silently corrupt, that its encryption key is still accessible, that the schema still matches the current application, that the restore procedure still works against the current infrastructure, that someone knows how to run it, and that the whole thing finishes inside your RTO. Every one of those has failed in real incidents, and every one fails *silently* — the backup job reports success right up until the day you need it.

The practice that fixes it is the **DR drill / restore test**: periodically restoring a real production backup into an isolated environment, validating the data, and **measuring the actual elapsed time** — which becomes your real, evidence-based RTO rather than an estimate. Run it on a schedule (quarterly is common), rotate who performs it so the capability is not one person's knowledge, and treat a failed drill exactly like a production incident, with a postmortem and action items. Mature organisations go further and automate the restore-and-verify as a continuous job.

---

## Exercise 7 — Modern operations

**A7.1**
- **DevOps** — a cultural and organisational movement that removes the wall between development and operations: shared ownership of production, small frequent changes, automation of the path to production, and fast feedback loops. It states goals and principles, not implementations.
- **SRE** — a specific, prescriptive implementation of those principles, developed at Google, that treats operations as a software engineering problem. It supplies the concrete mechanisms DevOps leaves open: SLIs/SLOs, error budgets as the arbiter between velocity and stability, a hard cap on toil, blameless postmortems, and defined incident command. *"class SRE implements DevOps."*
- **DORA (DevOps Research and Assessment)** — the multi-year research programme that measures software delivery performance across thousands of organisations and identifies which capabilities statistically predict better outcomes. It is the evidence layer: it tells you whether your DevOps or SRE adoption is actually working, using the four keys.

**A7.2**

| Metric | Type |
|---|---|
| Deployment frequency | **Throughput** |
| Lead time for changes | **Throughput** |
| Change failure rate | **Stability** |
| Failed deployment recovery time | **Stability** |

The central finding, and the reason the four are always reported together: **speed and stability are not a trade-off — they move together.** The intuition that shipping faster must mean breaking more is empirically wrong. High-performing organisations deploy far more frequently *and* have lower change failure rates *and* recover faster.

The mechanism is straightforward once stated: small, frequent changes are easier to review, easier to test, easier to reason about, and — critically — trivial to roll back, because the blame surface for any incident is one small diff rather than a quarter's accumulated work. Large infrequent releases are risky *because* they are large, and the fear they produce leads to less frequent releases, which makes them larger. Elite performance is the virtuous version of that same loop.

This is also why measuring only two of the four is dangerous: throughput without stability rewards recklessness, and stability without throughput rewards paralysis. The pair is the point.

**A7.3** — The **change failure rate of 33.3%** is the alarming one. One in three deploys causes a degradation requiring remediation, against a single-digit figure for high performers.

What it indicates: **problems are being discovered in production because nothing upstream is catching them.** The most likely causes, roughly in order of frequency —

- Inadequate automated testing, so the first real validation of a change happens when users hit it.
- **No progressive delivery.** Deploys go straight to 100% of traffic, so every defect that ships is a full-blast-radius incident. A canary would turn most of these into a 5% incident detected in three minutes.
- Large or batched changes: note that lead time averages 6.5 hours but one deploy took 24 hours and another 5 — the variance suggests inconsistent change sizes, and big changes fail more often.
- Environment drift between staging and production.

The encouraging counter-signal is the recovery time of 32 minutes, which shows the team *can* respond. The leverage is therefore entirely upstream: the cheapest large win here is a canary stage plus automatic rollback on SLO burn, because it attacks change failure rate and recovery time at the same time (see A7.7).

**A7.4**

| Task | Toil? | Why |
|---|---|---|
| Manually restarting a leaking service nightly | ✅ **Yes** | Manual, repetitive, automatable, purely tactical, no lasting value, and it recurs forever. The archetypal example — and note that the *right* fix is to find the leak, not to automate the restart |
| Designing next quarter's multi-region migration | ❌ **No** | Engineering work. Novel, creative, produces enduring value, and its output permanently changes the system's capabilities |
| Copying metrics into a spreadsheet weekly | ✅ **Yes** | Manual, repetitive, entirely automatable (a scheduled query or a dashboard), and it scales with the number of services being reported on |
| Handling a genuinely novel production incident | ❌ **No** | Novel by definition and requires judgement. Interrupt-driven and unwelcome, but not toil — the postmortem that follows produces enduring value. (If the "novel" incident is the same one for the fourth time, it has become toil) |
| Approving 30 identical access requests weekly | ✅ **Yes** | Manual, repetitive, scales linearly with headcount, and automatable via IAM groups, self-service with policy guardrails, or just-in-time access |
| Writing a postmortem | ❌ **No** | It produces durable value: action items, a permanent record, and organisational learning that prevents recurrence. Tedious is not the same as toil |

The distinction that resolves most disputes: toil is not "work I dislike." It is work that is **automatable and produces nothing that lasts**, and whose volume grows with the service. Unpleasant work that permanently reduces future work is engineering.

**A7.5** — To the manager:

> Both things are true — the automation worked, and toil still went up. The reason is that automation is subtractive and growth is multiplicative, and multiplication wins.
>
> Last year we removed about 30% of the manual work we had. But the service grew about 60%: more customers, more services, more environments, more incidents, more access requests. Toil scales with the size of the estate, so a 60% bigger estate generates 60% more toil, and we only removed 30% of it. Net, we went backwards — 35% to 39% — even though every automation project succeeded.
>
> The projection shows we cross 50% around year four. That matters because past 50%, the team spends most of its time on manual work, which means less time automating, which means toil grows faster next year. It is a feedback loop, and it ends with an operations team that has no capacity to do anything but operate.
>
> So the ask isn't "automate more" as an aspiration — it's a **hard cap on toil at 50% of the team's time**, with the rest protected for engineering that reduces future toil. That protected half is what keeps the curve from running away. Concretely: automation has to outpace growth, not just exist.

**A7.6** — A postmortem is blameless when it analyses **what the system permitted** rather than **who acted**. Same facts, different framing: not "Ana deleted the IAM binding" but "a single unreviewed command could remove public access from a production service, and no guardrail or canary existed to catch it." The person is a participant in the timeline, not its subject; the questions are what information they had, what the tooling made easy, and what would have made the correct action the default.

The concrete engineering benefit — not the emotional one:

**Blameless postmortems are the only ones that get accurate information.** In a blame culture, the people closest to the incident have a direct incentive to minimise, delay, omit and hedge. They report the outage later, describe it vaguely, and leave out the detail that makes them look careless — which is very often the detail that identifies the systemic flaw. You lose the data, so you fix the wrong thing, so the incident recurs with a different person's name on it.

There is a second, equally practical benefit: blameful postmortems produce useless action items. "Be more careful," "add a training session," "remind the team" — none of which change the system, all of which fail the next time someone is tired at 03:00. Blameless analysis forces action items that are *structural*: a policy that blocks the command, a required review, a canary, a better error message. Only those actually prevent recurrence.

The premise underneath it is the SRE assumption that **people act reasonably given the information and tools available to them**. If a competent engineer caused an outage with one command, the finding is about the command.

**A7.7** — The practice is **canary deployment** (a form of **progressive delivery**, alongside blue/green and traffic-splitting; Cloud Run implements it natively via revision tags and `update-traffic`).

It reduces **change failure rate** by shrinking the blast radius *and* by converting production into a detection stage. Only 10% of traffic touches the new revision, so a defect affects 10% of users instead of 100% — and, more importantly, you can compare the canary revision's SLIs against the stable revision's on live traffic before promoting. Many defects that no staging environment would surface (real data shapes, real concurrency, real dependencies) are caught here. Depending on how the organisation defines the metric, a caught-and-rolled-back canary is either a much smaller failure or not a production failure at all.

It reduces **failed deployment recovery time** because recovery is a traffic-weight change, not a rebuild or a redeploy. The previous revision is still running and still healthy; shifting 100% of traffic back to it takes seconds and requires no diagnosis, no image build, and no understanding of the root cause. Compare that to a conventional rollback, where you rebuild an artefact, redeploy it, and wait for instances to become healthy — minutes at best, and only after someone has decided what went wrong.

The compounding effect is the real prize: wire the canary's promotion to an **automated SLO burn-rate check**, and both the detection and the rollback stop requiring a human at all. That is the practical link between the SLO machinery in Exercises 2–4 and the delivery metrics here — the error budget stops being a report and becomes a control input to the deployment pipeline.

---

## Exercise 8 — Capstone

**A8.1**

| Item | Answer | Justification |
|---|---|---|
| **Availability SLI** | Proportion of HTTP requests to the appointment API returning non-`5xx`, measured at the load balancer, over valid requests (excluding `4xx` client errors and health probes) | Measured at the LB, not in the app, so it captures failures of the path itself — the step-9 lesson |
| **Latency SLI** | Proportion of appointment-booking requests completed in < 1000 ms | Expressed as a ratio, not a percentile, so it composes into an error budget. Booking is the user-critical path; browsing can have a looser target |
| **SLO** | **99.9%** availability, 30-day rolling window; **99%** of bookings under 1000 ms | 99.9% is one meaningful step up from the measured 99.72% — achievable within a quarter, and it would have failed last quarter, so it creates real pressure. See A8.3 for why not 99.99% |
| **Error budget** | **43.2 min / 30 days** | (1 − 0.999) × 43,200. For context: last quarter's *smallest* outage (52 min) alone would have exhausted a full month's budget |
| **RTO** | **30 minutes** | Traffic is 08:00–20:00, so an outage always has users. 30 min is aggressive enough to force automation but achievable with a regional architecture and rehearsed failover |
| **RPO** | **~0 (seconds)** | Non-negotiable and set by the regulator: appointment records must not be lost. This mandates synchronous or near-synchronous replication, not nightly backups |
| **Deployment archetype** | **Regional** (multi-zone within `southamerica-east1`), with a documented multi-region DR path | Regional removes the entire zonal single-point-of-failure class at modest cost. Full multi-regional is the next step, not the first — see A8.2 |
| **DR pattern** | **Warm standby** in a second region, with continuous replication | Satisfies RPO ≈ 0 via replication and RTO ≈ 30 min via a scaled-down running stack. Hot standby is not justified by the business impact of a 30-minute appointment outage |

**A8.2** — Priority order, with the outage each change addresses:

1. **Move to a regional (multi-zone) architecture** — MIG across ≥ 3 zones behind a regional load balancer with health checks, plus a Cloud SQL **HA configuration** (synchronous standby in a second zone) with automatic failover. This eliminates every single-zone failure mode in one change and is the largest availability gain available. It also gets RPO to ~0 for the zone-failure case.
2. **Define the SLO and error budget, and instrument the SLIs** — free, immediate, and it is the prerequisite for every later decision including whether any of this worked. Without it the team is arguing about opinions.
3. **Replace CPU-threshold alerts with SLO burn-rate alerts** — see A8.4. Also free, and it fixes the 80-alerts-per-week pathology that is currently inflating MTTD on real incidents.
4. **Enable Cloud SQL point-in-time recovery and run a restore drill** — measure the *actual* RTO rather than assuming it. The 210-minute outage strongly suggests recovery is manual and unrehearsed.
5. **Autoscaling sized for the Monday 8× peak** — with headroom and a tested maximum. A capacity-driven outage is likely among the three, given the traffic profile.
6. **CI/CD with canary deployment and automatic rollback on burn rate** — attacks change-induced failure, which the current architecture has no defence against at all.
7. **Warm standby in a second region** — last, because it is the most expensive and protects against the rarest failure class. Doing it before steps 1–3 would be paying for regional redundancy while a single zone can still take you down.

**Largest improvement per dollar: step 1 (regional/multi-zone).** It is a configuration and topology change rather than a new environment, roughly a modest cost increase, and it removes the failure class most likely to explain the 210-minute outage. Steps 2 and 3 cost essentially nothing and should be done in parallel — but they improve *knowledge*, not availability, so step 1 is the answer to the question as asked.

**A8.3** — **No. 99.99% is the wrong target, and the gap is not marginal.**

The numbers: measured availability is **99.72%**. A 99.99% SLO allows **4.32 minutes per 30 days** — about 13 minutes per quarter. Last quarter's downtime was **357 minutes**, roughly **27×** that budget. Even the *shortest* single outage, 52 minutes, would have blown a 99.99% quarterly budget twelve times over. And 99.99% means a total outage must be detected, diagnosed and fully recovered in **under four minutes**, every time, which forecloses any recovery path involving a human decision.

Reaching it would require multi-region active-active with synchronous replication, fully automated failover, zero-downtime deploys, and 24/7 staffed on-call — a rebuild, not an improvement, and a permanent cost increase far beyond what a regional appointment platform can justify.

There is also a governance argument: adopting a target you miss by 27× produces an SLO that is breached permanently. A permanently-breached SLO triggers a permanent feature freeze, which the business will immediately override, which destroys the authority of the error budget mechanism before it has ever been used. **A target nobody can meet is worse than no target**, because it also discredits the framework.

**What to propose instead:** commit to **99.9%** for the next two quarters — a ~3.5× reduction in downtime, achieved through steps 1–5 above, genuinely reachable, and enough to make last quarter's incident pattern impossible. Report against it monthly with real data. Then, with two quarters of measured evidence in hand, revisit whether 99.95% is worth its incremental cost. Present it to the board in their terms: *"We are committing to cut downtime by roughly three-quarters this quarter with a change we can deliver now, and we will show you the measurement every month — rather than committing to a number we would miss in week one."*

**A8.4** — Replace CPU thresholds with **multi-window, multi-burn-rate alerts on the availability and latency SLOs** (Exercise 2, step 4): a **page** at 14.4× over 1 h with a 5-minute short window, a **page** at 6× over 6 h with a 30-minute short window, and a **ticket** at 1× over 3 days. Add a black-box **uptime check** with multi-region probes as the catch-all for failures outside the application (DNS, TLS, LB, IAM), and keep resource metrics — CPU, memory, connection pool, replica lag — on **dashboards** for diagnosis, plus a small number of genuine capacity tickets. Nothing that is not user-visible pages.

Why this produces fewer and better alerts:

- **CPU is a cause, not a symptom, and it is a bad one.** High CPU during the Monday 8× peak is the system working correctly. Low CPU during a total outage is what a service that has stopped receiving traffic looks like. The correlation between CPU and user pain is weak in both directions, which is exactly why 56 of 60 alerts are not actionable — the metric is measuring the wrong thing, so no threshold tuning can fix it.
- **Burn rate alerts are, by construction, proportional to user harm.** They fire when users are actually experiencing failures fast enough to threaten the commitment, and they do not fire otherwise. Every page corresponds to real budget being consumed, so acting on it is always justified — which is what "actionable" means.
- **The short window suppresses the noise class that CPU thresholds are made of** — transient spikes, deploys, single instance restarts — because a brief blip cannot simultaneously breach a 1-hour window.
- **Severity is derived rather than guessed.** Fast burn wakes someone; slow burn creates a ticket for business hours. Under CPU thresholds every alert has the same undifferentiated urgency, which is why they all end up being treated as noise.

The second-order effect is the one to state to the team: dropping from ~80 alerts to a handful restores trust in the pager, and restored trust is what actually reduces MTTD on the next real incident. The current 80-alert stream is not merely annoying — it is a measurable contributor to the 210-minute outage.

**A8.5** — The on-premises system of record **changes the consequence of data loss, not the RPO requirement itself.**

What it changes: if every appointment write also lands on-premises, then a cloud-side data loss is *recoverable by reconciliation* rather than permanent. That reclassifies the failure from "regulatory incident" to "recovery procedure," and it means the cloud database can legitimately be treated as a replica of an authoritative store rather than the sole source of truth. In DR terms it can justify a less expensive cloud-side pattern — you are protecting availability and recovery time more than you are protecting the data's existence.

What it does **not** excuse you from:

1. **Proving the dual write is actually atomic and complete.** If the application writes to Cloud SQL and to on-prem as two independent operations, there is a window where one succeeds and the other does not — and that window is your real RPO, regardless of what the architecture diagram claims. Without a transactional outbox, a durable queue, or an equivalent guarantee, "it's also on-prem" is an assumption, not a control.
2. **Reconciliation must be built, automated and tested.** A copy of the data that no tooling can compare, diff and replay is not a recovery path. If the procedure is "someone writes a script during the incident," your RTO now includes writing that script under pressure.
3. **RTO is unaffected.** Having the data elsewhere does nothing for how long the service is down. Patients cannot book appointments during the outage whether or not the records survive.
4. **The on-premises system is now a dependency, and it has its own availability.** If it is a single datacentre with its own failure modes, you have not eliminated the risk — you have moved part of it into an environment with less redundancy than the cloud region, and one that is outside the SLO framework you just built. It needs its own backup, its own DR plan, and its own measurement.
5. **The regulator's requirement is about the record, not about a specific system.** You still have to be able to demonstrate — with evidence from a drill, not a diagram — that no appointment record can be lost.

The correct architectural conclusion: keep **RPO ≈ 0 as the requirement**, but note that it may now be satisfied by the *combination* of cloud replication and verified on-prem reconciliation rather than by synchronous multi-region replication alone. That is a legitimate cost saving — provided the verification is real.

</details>

---

## Sources

- **Exam guide:** [Cloud Digital Leader Exam Guide (PDF)](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)
- **SRE Book — Service Level Objectives:** https://sre.google/sre-book/service-level-objectives/
- **SRE Book — Monitoring Distributed Systems (golden signals):** https://sre.google/sre-book/monitoring-distributed-systems/
- **SRE Book — Eliminating Toil:** https://sre.google/sre-book/eliminating-toil/
- **SRE Book — Managing Incidents:** https://sre.google/sre-book/managing-incidents/
- **SRE Book — Postmortem Culture:** https://sre.google/sre-book/postmortem-culture/
- **SRE Workbook — Alerting on SLOs (burn rate):** https://sre.google/workbook/alerting-on-slos/
- **Google Cloud deployment archetypes:** https://cloud.google.com/architecture/deployment-archetypes
- **Disaster recovery planning guide:** https://cloud.google.com/architecture/disaster-recovery
- **Well-Architected Framework — Reliability pillar:** https://cloud.google.com/architecture/framework/reliability
- **SLO monitoring in Cloud Monitoring:** https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- **Uptime checks:** https://cloud.google.com/monitoring/uptime-checks
- **Log-based metrics:** https://cloud.google.com/logging/docs/logs-based-metrics
- **Cloud Run — rollbacks, gradual rollouts and traffic migration:** https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration
- **Cloud SQL — point-in-time recovery:** https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr
- **Google Cloud Service Level Agreements:** https://cloud.google.com/terms/sla
- **DORA — DevOps Research and Assessment:** https://dora.dev/