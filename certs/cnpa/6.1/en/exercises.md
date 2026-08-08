# Topic 6.1 — Platform Efficiency, Product Value, and Team Productivity
## Guided Exercises (CNPA, exam version 2025-04-01 · domain weight 4.0)

These exercises treat the **Internal Developer Platform (IDP) as a product**: the platform team is the vendor, the stream-aligned teams are the customers, and "value" is measured the way a product manager measures it — adoption, satisfaction, flow, and cost. You will compute the metrics that appear on the exam (DORA, SPACE, cognitive load, error budgets, cost efficiency) from real data rather than reciting their definitions.

**Prerequisites**

- `python3` (3.10+), `jq`, `curl`, `git`
- A Kubernetes cluster for Exercises 2 and 4 (`kind create cluster` or `minikube start` is enough), with `kubectl` configured. Exercises 1, 3 and 5 are pure data analysis and need no cluster.
- Optional: `promtool` (ships with Prometheus) to lint the rule files.

Create a scratch directory: `mkdir -p ~/cnpa-6.1 && cd ~/cnpa-6.1`.

Reference sources are listed at the end of each exercise and consolidated at the bottom.

---

## Exercise 1 — Quantify delivery performance with the four DORA metrics

The DORA metrics are the canonical *outcome* measures the exam uses for "team productivity." You will compute all four from event logs, classify them into performance bands, and read the trade-off the numbers reveal.

### Steps

1. Create a synthetic-but-realistic deployment log for one service over a 30-day window. In production these rows come from your CD system (Argo CD `Application` sync events, a GitHub Actions webhook, a Flux `Kustomization` reconcile). Here we hand-write a representative sample; assume the full file has **84** deployment records.

   ```bash
   cat > deployments.jsonl <<'EOF'
   {"deploy_id":"d-0001","service":"checkout","env":"prod","deployed_at":"2025-03-01T09:14:03Z","changes":[{"sha":"a1b2c3","merged_at":"2025-03-01T06:50:11Z"}]}
   {"deploy_id":"d-0007","service":"checkout","env":"prod","deployed_at":"2025-03-02T14:41:00Z","changes":[{"sha":"d4e5f6","merged_at":"2025-03-02T12:05:00Z"},{"sha":"778899","merged_at":"2025-03-01T18:22:00Z"}]}
   {"deploy_id":"d-0031","service":"checkout","env":"prod","deployed_at":"2025-03-12T10:03:00Z","changes":[{"sha":"aa11bb","merged_at":"2025-03-11T03:10:00Z"}]}
   EOF
   # ... assume 84 total rows for the full window ...
   ```

2. Create the incident log. An "incident" here is DORA's *change failure*: a deployment that resulted in degraded service requiring remediation (rollback, hotfix, forward-fix). Assume **15** incidents in the window.

   ```bash
   cat > incidents.jsonl <<'EOF'
   {"incident_id":"i-01","service":"checkout","env":"prod","caused_by_deploy":"d-0007","started_at":"2025-03-02T15:02:00Z","restored_at":"2025-03-02T15:49:00Z"}
   {"incident_id":"i-02","service":"checkout","env":"prod","caused_by_deploy":"d-0031","started_at":"2025-03-12T10:20:00Z","restored_at":"2025-03-12T15:50:00Z"}
   EOF
   # ... assume 15 total rows ...
   ```

3. Write the metric calculator. Note the deliberate choices baked in: lead time is measured **merge → deploy per change** (not per deployment), it reports **median and p95** (never the mean), and the band thresholds follow the DORA report.

   ```python
   cat > dora.py <<'EOF'
   #!/usr/bin/env python3
   """Compute the four DORA metrics from local JSONL event logs."""
   import argparse, json, statistics as stats
   from datetime import datetime

   def parse_ts(s): return datetime.fromisoformat(s.replace("Z", "+00:00"))
   def load(p):     return [json.loads(l) for l in open(p) if l.strip()]

   def pct(values, q):
       if not values: return None
       xs = sorted(values); k = max(0, min(len(xs)-1, round(q*(len(xs)-1))))
       return xs[k]

   def hms(sec):
       if sec is None: return "n/a"
       h, rem = divmod(int(sec), 3600); m, s = divmod(rem, 60)
       return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"

   def band_freq(pd):
       return ("Elite (multiple/day)" if pd>=1 else "High (day–week)" if pd>=1/7
               else "Medium (week–month)" if pd>=1/30 else "Low (< monthly)")
   def band_lead(h):
       return ("Elite (< 1 day)" if h<24 else "High (1 day–1 week)" if h<168
               else "Medium (1 week–1 month)" if h<720 else "Low (> 1 month)")
   def band_cfr(r):
       return "Elite (0–15%)" if r<=0.15 else "High/Medium (16–30%)" if r<=0.30 else "Low (> 30%)"
   def band_rec(h):
       return ("Elite (< 1 hour)" if h<1 else "High (< 1 day)" if h<24
               else "Medium (< 1 week)" if h<168 else "Low (> 1 week)")

   def main():
       ap = argparse.ArgumentParser()
       ap.add_argument("--deployments", required=True)
       ap.add_argument("--incidents", required=True)
       ap.add_argument("--window-days", type=int, required=True)
       a = ap.parse_args()
       deploys, incidents = load(a.deployments), load(a.incidents)
       n = len(deploys); per_day = n / a.window_days

       lead = [(parse_ts(d["deployed_at"]) - parse_ts(c["merged_at"])).total_seconds()
               for d in deploys for c in d.get("changes", [])]
       failed = {i["caused_by_deploy"] for i in incidents}
       cfr = len(failed)/n if n else 0.0
       rec = [(parse_ts(i["restored_at"]) - parse_ts(i["started_at"])).total_seconds()
              for i in incidents]

       print(f"Window {a.window_days}d  Deployments {n}  Incidents {len(incidents)}")
       print("-"*66)
       print(f"Deployment frequency : {per_day:5.2f}/day  -> {band_freq(per_day)}")
       print(f"Lead time  (median)  : {hms(stats.median(lead))}     -> {band_lead(stats.median(lead)/3600)}")
       print(f"Lead time  (p95)     : {hms(pct(lead,0.95))}")
       print(f"Change failure rate  : {cfr*100:4.1f}%      -> {band_cfr(cfr)}")
       print(f"Recovery   (median)  : {hms(stats.median(rec))}      -> {band_rec(stats.median(rec)/3600)}")
       print(f"Recovery   (p90)     : {hms(pct(rec,0.90))}")

   if __name__ == "__main__": main()
   EOF
   ```

4. Run it against the full 30-day window:

   ```bash
   python3 dora.py --deployments deployments.jsonl --incidents incidents.jsonl --window-days 30
   ```

   Expected output for the full dataset:

   ```
   Window 30d  Deployments 84  Incidents 15
   ------------------------------------------------------------------
   Deployment frequency :  2.80/day  -> Elite (multiple/day)
   Lead time  (median)  : 2h24m     -> Elite (< 1 day)
   Lead time  (p95)     : 31h00m
   Change failure rate  : 17.9%      -> High/Medium (16–30%)
   Recovery   (median)  : 41m00s      -> Elite (< 1 hour)
   Recovery   (p90)     : 5h30m
   ```

### Comprehension check — Exercise 1

- **1a.** This team is Elite on three metrics and only "High/Medium" on Change Failure Rate. Which two DORA metrics measure *throughput* and which two measure *stability*, and what does this specific profile tell you about where to invest platform effort?
- **1b.** Why does the calculator report the **median** and **p95** lead time instead of the mean? What does the gap between the 2h24m median and 31h p95 indicate?
- **1c.** A manager proposes setting a team OKR of "deploy 5 times per day." Using Goodhart's law, explain how optimizing deployment frequency in isolation could *worsen* the product, and name one counter-metric that keeps it honest.

---

## Exercise 2 — Define platform SLIs, an SLO, and an error budget

"Platform efficiency" is meaningless without a Service Level agreement with your customers. Here you define the platform's own SLIs (the platform *is* the service), encode them as Prometheus recording rules, and derive an error-budget-burn alert.

### Steps

1. Assume the platform control plane exports these metrics (from a provisioning controller / Crossplane / operator):
   - `platform_provisioning_requests_total{outcome="success|failure", golden_path}` — counter of self-service requests (namespace, database, ingress, etc.).
   - `platform_provisioning_duration_seconds_bucket` — histogram of provision time (CR created → `Ready`).
   - `platform_managed_workloads{golden_path="true|false"}` — gauge of workloads under management.

2. Write the SLI/SLO rules. Save and lint:

   ```yaml
   cat > platform-slis.yaml <<'EOF'
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: platform-slis
     namespace: platform-system
     labels:
       role: platform-slo
       release: kube-prometheus-stack
   spec:
     groups:
       - name: platform.slis
         interval: 60s
         rules:
           # SLI 1 — self-service success ratio (30d)
           - record: platform:provisioning_success:ratio_rate30d
             expr: |
               sum(rate(platform_provisioning_requests_total{outcome="success"}[30d]))
                 /
               sum(rate(platform_provisioning_requests_total[30d]))
           # SLI 2 — provisioning latency p95 (7d)
           - record: platform:provisioning_latency_seconds:p95_7d
             expr: |
               histogram_quantile(
                 0.95,
                 sum by (le) (rate(platform_provisioning_duration_seconds_bucket[7d]))
               )
           # SLI 3 — golden-path adoption ratio
           - record: platform:golden_path_adoption:ratio
             expr: |
               sum(platform_managed_workloads{golden_path="true"})
                 /
               sum(platform_managed_workloads)
       - name: platform.slo.errorbudget
         interval: 60s
         rules:
           # SLO: 99.5% of self-service requests succeed over 30d
           - record: platform:provisioning:error_budget_remaining
             expr: |
               1 - ( (1 - platform:provisioning_success:ratio_rate30d) / (1 - 0.995) )
           - alert: PlatformProvisioningErrorBudgetBurn
             expr: |
               (1 - platform:provisioning_success:ratio_rate30d) / (1 - 0.995) > 1
             for: 15m
             labels:
               severity: page
             annotations:
               summary: "Self-service provisioning 30d error budget exhausted"
               description: "Budget consumed ratio is {{ $value | humanize }}x (>1 means the 99.5% SLO budget is gone)."
   EOF
   promtool check rules platform-slis.yaml
   ```

   Expected:

   ```
   Checking platform-slis.yaml
     SUCCESS: 5 rules found
   ```

3. Apply it and query the recorded series (adjust the port-forward target to your Prometheus):

   ```bash
   kubectl apply -f platform-slis.yaml
   kubectl -n platform-system port-forward svc/prometheus-operated 9090 >/dev/null 2>&1 &
   curl -sG 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=platform:provisioning_success:ratio_rate30d' | jq '.data.result[0].value[1]'
   ```

   Expected (a healthy platform hovering just under target):

   ```
   "0.9971"
   ```

4. Evaluate the error budget manually. With a 99.5% SLO the allowed failure fraction is `1 − 0.995 = 0.005`. Observed failure fraction is `1 − 0.9971 = 0.0029`. Budget consumed = `0.0029 / 0.005 = 0.58`; **remaining = 0.42 (42%)**. The alert (`>1`) does not fire.

### Comprehension check — Exercise 2

- **2a.** SLI 3 (golden-path adoption) is a *product* metric, not a reliability metric, yet it lives in the same rule file. Why is adoption the leading indicator that ultimately validates every other platform SLI?
- **2b.** The SLO is 99.5%, not 100%. Explain the purpose of the error budget as a **shared incentive** between the platform team and its customer teams, and what a platform team should be *allowed* to do while budget remains.
- **2c.** Why is provisioning latency expressed as a **p95 from a histogram** rather than an average `rate()`? What failure would an average hide?

---

## Exercise 3 — Reduce cognitive load and find the Thinnest Viable Platform (TVP)

Team Topologies frames the platform's job as *reducing the cognitive load* of stream-aligned teams so they can own their software end-to-end. This exercise turns that into an inventory-and-decision procedure — the analytical skill the exam tests under "team productivity."

### Steps

1. Inventory every capability a stream-aligned team currently must operate to ship one service. Build the table (fill it for your own org; a worked example is shown):

   | Capability | Load type | Who should own it | Platform action |
   |---|---|---|---|
   | Business logic of the service | Intrinsic | Stream-aligned team | Never abstract — this is the team's reason to exist |
   | Writing a Dockerfile from scratch | Extraneous | Platform | Provide a `golden-path` build (Cloud Native Buildpacks) |
   | Authoring raw K8s YAML (Deployment/Service/Ingress/HPA/NetworkPolicy) | Extraneous | Platform | Provide a higher-level abstraction / CRD or Score/Helm template |
   | Choosing & wiring TLS certs, DNS, mTLS | Extraneous | Platform | Automate via ingress + cert-manager defaults |
   | Designing a canary rollout strategy | Germane | Shared | Provide progressive-delivery as a paved road (Argo Rollouts) |
   | Understanding their own SLOs | Germane | Stream-aligned team | Provide the SLO tooling, not the SLO targets |

2. Classify each row's cognitive load into the three types and apply the rule:
   - **Intrinsic** (essential to the problem) → *never* remove; it is the team's value.
   - **Extraneous** (accidental complexity of the delivery mechanism) → **the platform's target**; automate or abstract it away.
   - **Germane** (effort that builds valuable expertise) → keep, but *support* with tooling.

3. Derive the **Thinnest Viable Platform**. Sort capabilities by `(frequency of pain) × (number of teams affected)`. The TVP is the *smallest* set of extraneous-load removers that covers the top of that list — deliberately **not** a maximal platform. Write the one-sentence TVP scope statement, e.g.:

   > "The TVP provides: a golden-path build+deploy pipeline, managed ingress/TLS, and a self-service namespace/database request — nothing else, until adoption of these three exceeds 70% of teams."

### Comprehension check — Exercise 3

- **3a.** A platform team proudly ships a feature to let teams write custom admission webhooks through the portal. Only 2 of 40 teams asked for it. Using the intrinsic/extraneous/germane model and the TVP principle, argue whether this was a good use of platform capacity.
- **3b.** Team Topologies warns against the platform becoming a **bottleneck**. If every namespace request must be ticketed and manually approved by the platform team, which cognitive-load type has the platform *failed* to remove, and what is the fix that preserves governance?
- **3c.** Why does the TVP definition include an explicit adoption gate ("until adoption > 70%") before expanding scope? Connect this to "product value."

---

## Exercise 4 — Measure platform cost efficiency (FinOps for the IDP)

"Platform efficiency" has a literal financial dimension: are the resources the platform hands out actually *used*? You will compute allocation efficiency and idle waste per team, the numbers a platform PM reports to the business.

### Steps

1. Get requested vs. actual CPU per namespace directly from the API and metrics. First, requested CPU per namespace:

   ```bash
   kubectl get pods -A -o json | jq -r '
     [.items[] | {ns:.metadata.namespace,
       cpu:( [ .spec.containers[].resources.requests.cpu // "0" ]
             | map( if endswith("m") then (.[:-1]|tonumber) else (tonumber*1000) end )
             | add )}]
     | group_by(.ns)[] | {ns:.[0].ns, requested_mCPU:(map(.cpu)|add)}'
   ```

   Expected (abridged):

   ```json
   {"ns":"team-checkout","requested_mCPU":4200}
   {"ns":"team-search","requested_mCPU":9000}
   {"ns":"platform-system","requested_mCPU":2500}
   ```

2. Compute **allocation efficiency = used / requested** per namespace in Prometheus (requires `kube-state-metrics` + cAdvisor):

   ```promql
   sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[7d]))
     /
   sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
   ```

   Expected instant vector:

   ```
   {namespace="team-checkout"}  0.71
   {namespace="team-search"}    0.22
   {namespace="platform-system"} 0.55
   ```

   `team-search` uses only 22% of what it reserves — 78% of its reserved CPU is **idle waste** that no one else can schedule onto.

3. Attach a price and get a per-team cost/waste report with OpenCost (the CNCF cost-allocation project):

   ```bash
   kubectl -n opencost port-forward svc/opencost 9003 >/dev/null 2>&1 &
   curl -sG 'http://localhost:9003/allocation' \
     --data-urlencode 'window=7d' \
     --data-urlencode 'aggregate=namespace' \
     --data-urlencode 'accumulate=true' \
     | jq '.data[] | to_entries[] | {ns:.key,
            cpuCost:(.value.cpuCost),
            cpuEfficiency:(.value.cpuEfficiency),
            idleCost:( .value.cpuCost * (1 - .value.cpuEfficiency) ) }'
   ```

   Expected (abridged):

   ```json
   {"ns":"team-search","cpuCost":312.40,"cpuEfficiency":0.22,"idleCost":243.67}
   {"ns":"team-checkout","cpuCost":98.10,"cpuEfficiency":0.71,"idleCost":28.45}
   ```

4. Turn the number into a platform action. `team-search` is burning **$243/week** on reserved-but-idle CPU. The platform response is *not* "email the team" — it is to make the efficient path the default: ship a Vertical Pod Autoscaler recommendation, or a right-sizing dashboard, as a paved road, and show the savings back to the team.

### Comprehension check — Exercise 4

- **4a.** Distinguish **utilization** (used/capacity of the node) from **allocation efficiency** (used/requested). A platform can have high node utilization *and* terrible allocation efficiency at the same time — how, and which one exposes wasted money?
- **4b.** Why is idle cost a *platform-team* concern and not purely the app team's problem? Frame the answer in "platform as a product" terms — what does high idle waste say about the platform's defaults?
- **4c.** The platform team is tempted to solve step 3 by hard-capping every namespace's requests via a `LimitRange`. Give one way this could *harm* product value and reliability, and why "make the good path easy" beats "make the bad path impossible" here.

---

## Exercise 5 — Build a Platform Product-Value Scorecard

Finally, combine throughput, stability, adoption, developer satisfaction, and cost into a single **product-value scorecard** — the artifact a platform team reviews with stakeholders. This is the synthesis skill the domain is really testing.

### Steps

1. Choose the five dimensions and pull the input from the earlier exercises plus one SPACE survey signal. The SPACE framework says productivity is multidimensional — never a single number — so we score five and keep them *visible side by side*, not collapsed into one figure without breakdown.

   | Dimension (SPACE lens) | Source | Raw value | Normalized 0–1 | Weight |
   |---|---|---|---|---|
   | Flow / lead time (Efficiency & flow) | Ex. 1 | median 2h24m → Elite | 1.00 | 0.20 |
   | Stability / CFR (Performance) | Ex. 1 | 17.9% → High/Medium | 0.60 | 0.20 |
   | Adoption (Activity) | Ex. 2 SLI 3 | 68% golden-path | 0.68 | 0.25 |
   | Developer satisfaction (Satisfaction) | Quarterly survey (eSat 1–5) | 4.1 / 5 | 0.78 | 0.25 |
   | Cost efficiency (Efficiency) | Ex. 4 | 0.49 avg alloc-eff | 0.49 | 0.10 |

2. Design the survey question that produces the Satisfaction input — a single, comparable-over-time item plus a free-text follow-up (Developer eNPS style):

   > "How much does the platform help you deliver value to your users?" (1 = fights me, 5 = accelerates me) — followed by "What's the one thing that most slows you down?"

3. Compute the weighted index (a *communication* device, always shown with its breakdown):

   ```python
   dims = {
     "flow":        (1.00, 0.20),
     "stability":   (0.60, 0.20),
     "adoption":    (0.68, 0.25),
     "satisfaction":(0.78, 0.25),
     "cost":        (0.49, 0.10),
   }
   index = sum(v*w for v,w in dims.values())
   print(f"Platform Product-Value Index: {index:.2f}")   # -> 0.71
   ```

   Expected output:

   ```
   Platform Product-Value Index: 0.71
   ```

4. Read it as a product manager. The index is 0.71, but the *shape* is the message: flow is Elite while **stability (0.60) and cost (0.49) drag**. The roadmap writes itself — progressive delivery to cut CFR (from Ex. 1) and right-sizing defaults to lift efficiency (from Ex. 4) — and adoption at 68% is one point short of the TVP expansion gate from Ex. 3.

### Comprehension check — Exercise 5

- **5a.** Why does the scorecard keep all five dimensions visible instead of reporting only the 0.71 composite to leadership? Tie this to the SPACE framework's core warning about single-metric productivity.
- **5b.** Which of the five inputs are **lagging** indicators (they confirm value already delivered) and which are **leading** (they predict future value)? Why does a platform product roadmap need both?
- **5c.** Adoption carries weight 0.25, tied with satisfaction, and higher than flow or cost. Justify why adoption is weighted so heavily for a *platform* product specifically — what is a technically excellent platform worth if adoption is 5%?

---

## Answers

<details>
<summary>Click to reveal answers for Exercises 1–5</summary>

### Exercise 1

- **1a.** *Throughput* = Deployment Frequency and Lead Time for Changes; *stability* = Change Failure Rate and Failed-deployment Recovery Time. This team ships fast and often and recovers quickly, but ~1 in 5 changes causes a failure. That is a classic "fast but fragile" profile: the constraint is **pre-production quality and blast-radius control**, not speed. Platform investment should go into stability paved roads — progressive delivery (canary/blue-green via Argo Rollouts), automated rollback on SLO breach, better pre-merge testing and preview environments — *not* into deploying even faster, which would only increase the absolute number of failures.
- **1b.** Lead time distributions are heavily right-skewed: a few changes that sat in review for days pull the **mean** far above the typical experience, so the mean describes no real change. The **median** reflects the normal case and **p95** exposes the painful tail. The 2h24m vs 31h gap means the *typical* change flows in hours, but the slowest 5% take over a day — usually a batching, review-latency, or manual-approval bottleneck worth hunting down.
- **1c.** Goodhart: "when a measure becomes a target, it ceases to be a good measure." Chasing deployment frequency invites tiny no-op deploys, skipped tests, and deploying to inflate the count — raising throughput while Change Failure Rate and user pain climb. The honest **counter-metric** is Change Failure Rate (or recovery time): you only celebrate more frequent deploys if stability holds. DORA is explicitly designed as a *balanced* set for exactly this reason.

### Exercise 2

- **2a.** A reliable, fast, cheap platform that no one uses delivers zero value — adoption is the metric that proves the platform is actually a product and not shelfware. Every other SLI (success ratio, latency) only matters *for the workloads on the platform*; if golden-path adoption is low, high reliability is being measured over an empty room. Adoption is the leading indicator that the platform is winning its internal "market."
- **2b.** The error budget is the **shared contract**: the customer teams accept that 0.5% of requests may fail, and in exchange the platform team is *allowed to change and ship* as long as budget remains. It converts "reliability vs. velocity" from an argument into a number. While budget remains, the platform team can roll out risky improvements, run experiments, and move fast; when it is exhausted, the alert forces a freeze on feature work and a pivot to reliability — a rule both sides agreed to in advance, removing politics from the decision.
- **2c.** Provisioning time is right-skewed and the *worst* experiences drive dissatisfaction, so you must measure the tail. A `rate()`-based average would be dominated by the many fast provisions and could stay flat even while p95 doubled — hiding a subset of requests (e.g., a specific database class) that now take minutes. `histogram_quantile(0.95, …)` surfaces exactly the slow tail an average conceals.

### Exercise 3

- **3a.** Custom admission webhooks are **germane/intrinsic complexity for a specialist platform capability**, and only 5% of teams (2/40) asked — so it fails the TVP prioritization `(pain frequency × teams affected)`. Platform capacity spent here removed almost no aggregate cognitive load while widening the surface the platform must maintain. Better spent on an extraneous-load remover that touches all 40 teams. Building it was a poor use of capacity — a "cool feature" over a broad pain point.
- **3b.** It failed to remove the **extraneous cognitive load** of provisioning; worse, by inserting manual approval it made the platform a bottleneck, re-introducing wait time (hurting lead time from Ex. 1). The fix is **self-service with guardrails**: policy-as-code (e.g., an admission policy / OPA-Gatekeeper / Kyverno + a namespace request CRD) that auto-approves anything conforming to policy and only escalates exceptions. Governance is preserved in code, not in a human ticket queue.
- **3c.** A platform's value is realized only when teams *use* it; expanding scope before the current TVP is adopted spreads the team thin and risks building more shelfware. The 70% adoption gate forces the team to *finish making the existing paved roads genuinely better than the alternatives* — the product-management discipline of validating demand before building more. Feature breadth ≠ product value; adoption is the proof of value.

### Exercise 4

- **4a.** **Utilization** = node's used ÷ node's capacity (are the machines busy?). **Allocation efficiency** = used ÷ *requested* (are reservations honest?). You can have a fully packed cluster (high utilization) where every pod reserves 4× what it uses — the scheduler packs based on *requests*, so the node looks full while real CPU sits idle inside each pod. **Allocation efficiency** is the one that exposes wasted money, because you pay for reserved capacity, and low efficiency means you're buying nodes to hold reservations no one consumes.
- **4b.** High idle waste means the platform's **defaults are wrong**: teams over-request because the golden path told them to, or gave them no right-sizing signal. In "platform as a product" terms, the platform *shipped a default that costs the business money*. Fixing it centrally (better default requests, a VPA recommender, a right-sizing dashboard as a paved road) fixes it for every team at once — far higher leverage than 40 teams each rediscovering the problem. Waste is a platform-defaults defect, not just a per-team mistake.
- **4c.** A hard `LimitRange` cap can throttle or OOM-kill a workload that legitimately spikes (a checkout surge), turning a cost problem into a reliability incident — raising Change Failure Rate and destroying trust in the platform. "Make the good path easy" (a recommender that *suggests* right-sized requests, applied by the team with visibility) preserves the team's autonomy and safety margin while still driving efficiency, whereas "make the bad path impossible" removes the safety valve and pushes teams *off* the platform. Guardrails that guide beat gates that block.

### Exercise 5

- **5a.** SPACE's central thesis is that **developer productivity is multidimensional and cannot be captured by any single metric** — collapsing to one number invites gaming and hides trade-offs (e.g., a team maximizing throughput while satisfaction collapses). Reporting only 0.71 lets leadership optimize the composite blindly; showing the five components makes the *shape* actionable and keeps any one dimension from being sacrificed for the index.
- **5b.** *Lagging* (confirm delivered value): flow/lead time, stability/CFR, cost efficiency — they describe what already happened. *Leading* (predict future value): adoption and developer satisfaction — a rising adoption curve and improving satisfaction predict tomorrow's throughput and retention on the platform. A roadmap needs both: lagging metrics tell you whether last quarter's bets paid off; leading metrics tell you whether teams will still be with you next quarter. Steering on lagging indicators alone means you only learn you've lost teams after they've gone.
- **5c.** For a *platform* product, adoption is the multiplier on every other benefit: a technically excellent platform used by 5% of teams delivers ~5% of its potential organizational value and still costs its full operating budget — a net loss. Reliability, speed, and cost savings only compound across the teams that actually adopt the paved roads. That is why adoption is weighted alongside satisfaction and above raw flow: it is the closest proxy for realized product value, and the precondition that makes all the other metrics matter at scale.

</details>

---

### Sources

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum
- CNCF Platforms White Paper (CNCF TAG App Delivery) — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- DORA / State of DevOps (four keys, performance bands) — https://dora.dev/
- The SPACE of Developer Productivity (Forsgren et al., ACM Queue) — https://queue.acm.org/detail.cfm?id=3454124
- Team Topologies (cognitive load, Thinnest Viable Platform, platform-as-a-product) — https://teamtopologies.com/key-concepts
- OpenCost (CNCF cost allocation) — https://www.opencost.io/docs/
- FinOps Foundation (allocation, efficiency principles) — https://www.finops.org/framework/
- Prometheus recording & alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/