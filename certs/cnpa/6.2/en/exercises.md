# Topic 6.2 — DORA Metrics and Indicators for Platform Initiatives — Guided Exercises

> **Scope.** These exercises build a working DORA measurement pipeline from raw delivery events, compute the four keys by hand and with tooling, benchmark the result against the DORA performance clusters, and then use the numbers the way a platform team must: as *indicators of a platform initiative's impact*, not as a scoreboard for individuals. You will run everything locally with `jq`, `bc`, and (optionally) PromQL, so you can trace every number back to the event that produced it.
>
> **Reference sources**
> - DORA — *DORA's software delivery metrics: the four keys* — https://dora.dev/guides/dora-metrics-four-keys/
> - DORA — *State of DevOps* research & benchmarks — https://dora.dev/research/
> - Google/DORA — *Four Keys* reference implementation — https://github.com/dora-team/fourkeys
> - CNCF TAG App Delivery — *Platform Engineering Maturity Model* — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
> - Forsgren, Storey et al. — *The SPACE of Developer Productivity* — https://queue.acm.org/detail.cfm?id=3454124
> - OpenTelemetry — *CI/CD semantic conventions* — https://opentelemetry.io/docs/specs/semconv/cicd/
> - CloudEvents specification — https://cloudevents.io/

---

## Lab setup

You need `jq` (≥ 1.6) and `bc`. Create a synthetic event log of two weeks of production deployments for a service called `checkout`. Each line is one **deployment event**; two of them **caused a production incident** and therefore carry an `incident_resolved_at` field.

1. Create the working directory and the deployment event log:

```bash
mkdir -p ~/dora-lab && cd ~/dora-lab
cat > deploys.jsonl <<'EOF'
{"id":"d1","service":"checkout","env":"production","deployed_at":"2026-01-01T10:00:00Z","commit_at":"2026-01-01T06:00:00Z","caused_incident":false}
{"id":"d2","service":"checkout","env":"production","deployed_at":"2026-01-02T14:00:00Z","commit_at":"2026-01-01T12:00:00Z","caused_incident":false}
{"id":"d3","service":"checkout","env":"production","deployed_at":"2026-01-03T09:00:00Z","commit_at":"2026-01-03T06:00:00Z","caused_incident":false}
{"id":"d4","service":"checkout","env":"production","deployed_at":"2026-01-05T16:00:00Z","commit_at":"2026-01-03T14:00:00Z","caused_incident":true,"incident_resolved_at":"2026-01-05T19:00:00Z"}
{"id":"d5","service":"checkout","env":"production","deployed_at":"2026-01-06T17:00:00Z","commit_at":"2026-01-06T09:00:00Z","caused_incident":false}
{"id":"d6","service":"checkout","env":"production","deployed_at":"2026-01-07T11:00:00Z","commit_at":"2026-01-07T09:00:00Z","caused_incident":false}
{"id":"d7","service":"checkout","env":"production","deployed_at":"2026-01-09T20:00:00Z","commit_at":"2026-01-09T08:00:00Z","caused_incident":false}
{"id":"d8","service":"checkout","env":"production","deployed_at":"2026-01-10T18:00:00Z","commit_at":"2026-01-09T12:00:00Z","caused_incident":true,"incident_resolved_at":"2026-01-10T18:45:00Z"}
{"id":"d9","service":"checkout","env":"production","deployed_at":"2026-01-12T15:00:00Z","commit_at":"2026-01-12T09:00:00Z","caused_incident":false}
{"id":"d10","service":"checkout","env":"production","deployed_at":"2026-01-14T12:00:00Z","commit_at":"2026-01-13T18:00:00Z","caused_incident":false}
EOF
wc -l deploys.jsonl
```

Expected output:

```
10 deploys.jsonl
```

The measurement window is `2026-01-01T00:00:00Z … 2026-01-15T00:00:00Z` = **14 days**. Keep that constant in mind — every rate metric is a count *over a window*.

---

## Exercise 1 — Model the four keys as events

Before you can measure anything you must decide *what an event is* and *where it comes from*. DORA's data model is deliberately small: two event streams.

1. Name the four DORA metrics and, next to each, write whether it is a **throughput** metric (velocity) or a **stability** metric (quality). Do it on paper first, then check against step 2.

2. Draw the minimal event model. Confirm that every metric can be derived from just **two** event types by running this to see what fields each metric consumes:

```bash
jq -r '
  "deployment event → \(.id): deployed_at, commit_at" +
  (if .caused_incident then "  | ALSO an incident: incident_resolved_at" else "" end)
' deploys.jsonl
```

Expected output:

```
deployment event → d1: deployed_at, commit_at
deployment event → d2: deployed_at, commit_at
deployment event → d3: deployed_at, commit_at
deployment event → d4: deployed_at, commit_at  | ALSO an incident: incident_resolved_at
deployment event → d5: deployed_at, commit_at
deployment event → d6: deployed_at, commit_at
deployment event → d7: deployed_at, commit_at
deployment event → d8: deployed_at, commit_at  | ALSO an incident: incident_resolved_at
deployment event → d9: deployed_at, commit_at
deployment event → d10: deployed_at, commit_at
```

3. Map each field to the **platform component** that is the authoritative source of truth for it, so the pipeline is not guessing:
   - `deployed_at` → the CI/CD / progressive-delivery controller (e.g. Argo CD, Flux, a GitHub Actions deploy job).
   - `commit_at` → the source-control / VCS system (git author or merge timestamp).
   - `caused_incident` + `incident_resolved_at` → the incident manager / alerting system (PagerDuty, Alertmanager, Incident.io).

4. Note the transport contract. The Four Keys reference pipeline and most platform implementations normalise these into a common envelope — **CloudEvents** — so the CI system, VCS, and incident tool can each emit into one collector. OpenTelemetry now ships **CI/CD semantic conventions** (`cicd.pipeline.*`) for exactly this.

**Check your understanding — 1**
- **1a.** Which two of the four keys are *stability* metrics, and which two are *throughput* metrics?
- **1b.** Deployment frequency and change failure rate are both computed from the deployment stream. Why can neither be computed correctly if a *failed pipeline run that never reached production* is recorded as a "deployment"?
- **1c.** Why is an authoritative timestamp for "reached production" (not "merged to main", not "image built") required specifically for **change lead time**, and which direction does the error go if you substitute the merge time for the production time?

---

## Exercise 2 — Compute Deployment Frequency and Change Lead Time (throughput)

1. **Deployment Frequency (DF)** — count production deployments in the window, then express it as a rate:

```bash
jq -s '[.[] | select(.env=="production")] | length' deploys.jsonl
```

Expected output:

```
10
```

Convert 10 deployments over 14 days into deployments/week:

```bash
echo "scale=2; 10*7/14" | bc
```

Expected output:

```
5.00
```

So DF = **5 successful production deployments per week** (≈ 0.71/day).

2. **Change Lead Time (CLT)** — for each deployment compute `deployed_at − commit_at` in hours, then take the **median** (never the mean — lead-time distributions are heavily right-skewed by a few stragglers):

```bash
jq -s '
  [ .[] | select(.env=="production")
        | ((.deployed_at|fromdateiso8601) - (.commit_at|fromdateiso8601)) / 3600 ]
  | sort
  | (.[length/2|floor] + .[(length-1)/2|floor]) / 2
' deploys.jsonl
```

Expected output:

```
10
```

The per-deployment lead times sort to `[2, 3, 4, 6, 8, 12, 18, 26, 30, 50]` hours; the two middle values are 8 h and 12 h, so the median CLT = **10 hours**.

3. Inspect the distribution you just collapsed, to see the tail the median protected you from:

```bash
jq -s '
  [ .[] | select(.env=="production")
        | { id, hours: (((.deployed_at|fromdateiso8601) - (.commit_at|fromdateiso8601))/3600) } ]
  | sort_by(.hours) | .[] | "\(.id)\t\(.hours)h"
' deploys.jsonl
```

Expected output:

```
d6	2h
d3	3h
d1	4h
d9	6h
d5	8h
d7	12h
d2	18h
...
```

*(d10=18 h, d2=26 h, d8=30 h, d4=50 h complete the tail.)*

4. **Production framing:** in a real platform, DF often comes straight from an SLI counter rather than a log. If your platform exposes `platform_deployments_total{env="production"}`, the equivalent PromQL is:

```promql
sum(increase(platform_deployments_total{env="production"}[7d]))
```

**Check your understanding — 2**
- **2a.** DF came out to 5/week. If d4 and d8 (the two that caused incidents) had *rolled back automatically* within minutes, should they still count toward Deployment Frequency? Justify from the DORA definition.
- **2b.** The mean of the lead-time list is 15.9 h but the median is 10 h. What real-world situation does the gap between them represent, and why does DORA report the median?
- **2c.** A teammate proposes measuring lead time from "PR opened" instead of "commit authored / merged". Name one way that inflates the metric and one way it deflates it depending on team workflow.

---

## Exercise 3 — Compute Change Failure Rate and Failed Deployment Recovery Time (stability)

1. **Change Failure Rate (CFR)** — the share of production deployments that caused a degraded service requiring remediation (hotfix, rollback, patch):

```bash
jq -s '
  ([.[] | select(.env=="production")] | length) as $total
  | ([.[] | select(.env=="production" and .caused_incident==true)] | length) as $fail
  | { total: $total, failed: $fail, cfr_percent: ($fail/$total*100) }
' deploys.jsonl
```

Expected output:

```json
{
  "total": 10,
  "failed": 2,
  "cfr_percent": 20
}
```

CFR = **20%**.

2. **Failed Deployment Recovery Time (FDRT)** — formerly "time to restore service" / MTTR; DORA renamed it in the 2023 report because it is scoped to *deployment-induced* failures. Compute `incident_resolved_at − deployed_at` per failing deploy, then take the median:

```bash
jq -s '
  [ .[] | select(.caused_incident==true)
        | ((.incident_resolved_at|fromdateiso8601) - (.deployed_at|fromdateiso8601)) / 3600 ]
  | sort
  | (.[length/2|floor] + .[(length-1)/2|floor]) / 2
' deploys.jsonl
```

Expected output:

```
1.875
```

The two recovery times are 0.75 h (d8) and 3 h (d4); median FDRT = **1.875 h ≈ 1 h 53 m**.

3. Show the recovery detail so the number is auditable:

```bash
jq -r '
  select(.caused_incident==true)
  | "\(.id): failed at \(.deployed_at), restored \(.incident_resolved_at) → " +
    (((.incident_resolved_at|fromdateiso8601)-(.deployed_at|fromdateiso8601))/3600|tostring) + "h"
' deploys.jsonl
```

Expected output:

```
d4: failed at 2026-01-05T16:00:00Z, restored 2026-01-05T19:00:00Z → 3h
d8: failed at 2026-01-10T18:00:00Z, restored 2026-01-10T18:45:00Z → 0.75h
```

**Check your understanding — 3**
- **3a.** CFR is 20% but only 2 deployments failed. Explain why CFR is a *rate*, not a count, and what would happen to the number if the team deployed 40 times in the same window with the same 2 failures.
- **3b.** FDRT and change lead time both measure "elapsed time." What is the fundamental difference in what each one tells a platform team about the system?
- **3c.** One incident (d8) was resolved in 45 minutes by an automatic rollback; the other (d4) took 3 hours of manual debugging. Why is the *median* a weak summary for only two data points, and what should you report alongside it?

---

## Exercise 4 — Benchmark against the DORA performance clusters

DORA groups teams into **Elite / High / Medium / Low** clusters. Exact thresholds are revised in each annual *State of DevOps* report — always confirm the current numbers with the DORA Quick Check at https://dora.dev/quickcheck/ — but the representative bands are:

| Metric | Elite | High | Medium | Low |
|---|---|---|---|---|
| Deployment frequency | On-demand (multiple/day) | 1/day – 1/week | 1/week – 1/month | < 1/month |
| Change lead time | < 1 day | 1 day – 1 week | 1 week – 1 month | > 1 month |
| Change failure rate | 0–15% | 16–30% | 16–30% | > 30% |
| Failed deployment recovery time | < 1 hour | < 1 day | 1 day – 1 week | > 1 week |

1. Place each of your four computed values into the table:
   - DF = 5/week → ?
   - CLT (median) = 10 h → ?
   - CFR = 20% → ?
   - FDRT (median) = ~1.9 h → ?

2. Write down the **cluster mismatch**: three of the four keys land in strong bands, one lags. Identify which one drags the profile and which two DORA dimensions it belongs to (throughput vs stability).

3. State the diagnosis in one sentence. A profile that is fast (good DF, good CLT) but fails often (high CFR) is the classic "**shipping instability**" signature — velocity is not the constraint; change quality is.

4. Turn it into a platform initiative. The platform team proposes a **golden path** that bakes in progressive delivery (canary + automated analysis) so bad changes are caught before full rollout. Write the **target metric** and the **guardrail metric** for this initiative:
   - Primary target: reduce **CFR** from 20% toward ≤ 15%.
   - Guardrail: **DF and CLT must not regress** (the initiative must not buy stability by slowing delivery).

**Check your understanding — 4**
- **4a.** Which single metric places this team below Elite/High overall, and why is it correct to say the team's *throughput is healthy but its stability is not*?
- **4b.** The platform team could also cut FDRT by improving rollback automation. Given the four current values, argue why lowering **CFR** is the higher-leverage initiative than lowering FDRT for *this* service.
- **4c.** DORA's research finds that throughput and stability improve *together* in elite teams rather than trading off. Why does that finding make "DF must not regress" a mandatory guardrail on the CFR initiative, rather than an acceptable sacrifice?

---

## Exercise 5 — Use DORA as a *platform* indicator without gaming it

DORA metrics describe a **system**, not a person. For platform engineering the unit of analysis is the *platform's effect on the teams that adopt it* — which changes how you slice, baseline, and pair the metrics.

1. **Baseline before, measure after.** For a platform initiative, capture the four keys for a cohort *before* onboarding, then re-measure the same cohort after. Simulate the "after" snapshot for the canary rollout by pretending d4 and d8 were caught before full production and did not count as failures:

```bash
jq -s '
  ([.[] | select(.env=="production")] | length) as $total
  | ([.[] | select(.env=="production" and .caused_incident==true and .id!="d4" and .id!="d8")] | length) as $fail
  | { cfr_after_percent: ($fail/$total*100) }
' deploys.jsonl
```

Expected output:

```json
{ "cfr_after_percent": 0 }
```

The delta (20% → 0%) is the *indicator of the initiative's impact* — that is the number a platform team reports, not the absolute value alone.

2. **Segment by adoption, not by team ranking.** Compare golden-path adopters vs non-adopters. Never publish a per-developer DORA leaderboard — it is the fastest way to induce Goodhart's law (people optimize the measure, e.g. splitting one deploy into ten to inflate DF).

3. **Pair the four keys with a counter-metric and a reliability signal:**
   - Counter-metric against DF gaming: keep an eye on CFR and FDRT together — DF that rises while CFR rises is *not* an improvement.
   - The **fifth key**: DORA added **reliability / operational performance** (does the service meet its SLOs?). A platform initiative that improves the four keys but blows the error budget has not succeeded.

4. **Triangulate with SPACE.** DORA answers "how does delivery perform?" but not "at what human cost?" Pair it with the **SPACE** framework (Satisfaction, Performance, Activity, Communication, Efficiency) — e.g. a developer-experience survey and platform NPS — so a DORA win achieved by burning out on-call engineers is visible.

5. **Anchor to the CNCF maturity model.** Map the initiative onto the CNCF *Platform Engineering Maturity Model* dimensions (Investment, Adoption, Interfaces, Operations, Measurement). Reaching the higher "Measurement" levels means DORA metrics are *automatically collected from platform events* (Exercise 1's pipeline) rather than manually harvested per team.

**Check your understanding — 5**
- **5a.** A manager wants a monthly per-engineer DORA scoreboard to rank the team. Give two concrete ways this backfires, using Deployment Frequency and Change Failure Rate as examples.
- **5b.** After the golden-path rollout, DF jumps to 12/week and CFR drops to 5%, but the on-call SLO error budget is exhausted every week. Using the fifth key and SPACE, explain why you cannot yet call the initiative a success.
- **5c.** Why must a platform team report DORA metrics as a **cohort delta (before → after adoption)** rather than an absolute cluster label when justifying a platform investment to leadership?

---

<details>
<summary><strong>Answer key</strong> (click to expand)</summary>

### Exercise 1
- **1a.** Stability: **Change Failure Rate** and **Failed Deployment Recovery Time**. Throughput: **Deployment Frequency** and **Change Lead Time**. DORA groups the four keys into these two dimensions precisely so a team can see whether it is trading speed for quality (or, in elite teams, getting both).
- **1b.** Both metrics use the *count of production deployments* as their reference set — DF as the numerator, CFR as the denominator. If a failed pipeline run that never reached production is logged as a "deployment," DF is inflated with non-events, and CFR's denominator grows so the failure rate is understated. The definitions are anchored on **successfully reaching production**, so only deployments that actually shipped may be counted.
- **1c.** Change lead time measures *commit → running in production*, i.e. the full path a change travels to reach a user. Merge time and image-build time are earlier checkpoints; the time from there to production (approvals, queueing, staged/progressive rollout, soak) can dominate. Substituting merge time **understates (deflates)** lead time because it discards everything after merge — exactly the part a platform's delivery pipeline is responsible for.

### Exercise 2
- **2a.** Yes — they still count. Deployment Frequency counts changes that **successfully reached production**; d4 and d8 both deployed to production and *then* caused incidents (change failures), which is a stability problem captured by CFR, not a throughput exclusion. A change that never reached production (e.g. failed in the pipeline) would *not* count. Rollback speed is measured by FDRT, not by removing the deploy from the DF count.
- **2b.** The gap means a **long right tail**: most changes flow through in hours (2–18 h), but a few stragglers (26, 30, 50 h) pull the mean up to 15.9 h. Those stragglers are usually blocked/queued work, not typical flow. The median (10 h) reflects the experience of a *typical* change, so DORA reports the median (or a percentile) to avoid a handful of outliers misrepresenting the pipeline.
- **2c.** Measuring from "PR opened" **inflates** lead time for teams that open draft/WIP PRs early and let them sit (idle review time gets counted as delivery time). It **deflates** lead time for teams that do most of the work on a local branch and open the PR only at the very end (the long build-up before the PR is invisible). Because the anchor shifts with workflow, cross-team comparison becomes meaningless — hence DORA anchors on commit → production.

### Exercise 3
- **3a.** CFR is *failed production deployments ÷ total production deployments*, expressed as a percentage — a rate, so it is comparable across teams and windows regardless of volume. With 40 deployments and the same 2 failures, CFR falls to 2/40 = **5%**. The same absolute quality (2 bad changes) reads very differently as a rate, which is the point: it normalizes for how often you ship.
- **3b.** Change lead time is a **throughput/flow** measure — how quickly value moves from a developer's commit to the user. FDRT is a **stability/resilience** measure — how quickly the system recovers *after a change breaks production*. One tells you how good you are at delivering; the other tells you how good you are at containing damage when delivery goes wrong.
- **3c.** With only two data points the "median" is just their average (1.875 h) and is dominated by both extremes equally — it is statistically fragile and hides that recovery ranged from 45 minutes to 3 hours. You should report the **sample size and the range/individual values** (n=2; 0.75 h and 3 h) alongside it, and be explicit that the estimate is low-confidence until more incidents accumulate.

### Exercise 4
- **Placement:** DF = 5/week → **High** (between 1/day and 1/week). CLT = 10 h → **Elite** (< 1 day). CFR = 20% → **High/Medium band** (16–30%, i.e. *not* Elite). FDRT ≈ 1.9 h → **High** (< 1 day; just above the < 1 h Elite line).
- **4a.** **Change Failure Rate (20%)** is the metric holding the team out of the Elite band; it is the only one of the four in a mid band. The two throughput keys (DF High, CLT Elite) show the team ships fast, while the stability keys — CFR especially — show one in five changes breaks production. Throughput is healthy; stability (change quality) is the constraint.
- **4b.** FDRT is already strong (~1.9 h, near Elite) and it only helps *after* a failure occurs — it caps damage but does not reduce how often customers are impacted. CFR at 20% means failures are *frequent*; every avoided failure removes an incident entirely (no recovery needed at all) and simultaneously lifts the stability profile. Reducing the frequency of failures (CFR) is higher-leverage than shaving an already-short recovery time.
- **4c.** DORA's research shows elite performers achieve high throughput *and* high stability together — they are not on a trade-off curve. So a CFR improvement bought by slowing deployments (dropping DF/CLT) would be moving *against* the elite pattern, not toward it — it would trade one dimension for another instead of improving the system. The guardrail forces the initiative to raise quality *without* sacrificing speed, which is the only movement that actually advances the team.

### Exercise 5
- **5a.** (1) A per-engineer **DF** leaderboard rewards deploying more often, so engineers split one logical change into many tiny deploys to pad their count — DF rises with no real delivery improvement (Goodhart's law). (2) A per-engineer **CFR** ranking punishes owning risky/critical changes, so engineers avoid touching fragile-but-important systems or under-report incidents to keep their failure rate down — the metric gets "improved" by hiding failures, degrading real reliability. DORA measures a system; attributing it to individuals corrupts both the number and behavior.
- **5b.** The four keys look elite, but the **fifth key (reliability/operational performance)** is failing: the service is not meeting its SLOs — the error budget is exhausted weekly, meaning the speed and low CFR came at the cost of running the service too hot. From **SPACE**, exhausting on-call every week signals collapsing Satisfaction/Efficiency (burnout, toil), which is invisible in the four keys but predicts future regression. A genuine success holds the four keys *and* reliability *and* human sustainability together.
- **5c.** An absolute cluster label ("we are High") does not attribute the change to the platform — the team might have been High before the investment, or improved for unrelated reasons. A **before→after cohort delta** on the teams that adopted the platform (ideally vs. a non-adopting control cohort) isolates the platform's *causal contribution* and expresses it as impact (e.g. "CFR 20% → 5% for onboarded teams"), which is what justifies continued investment. Absolute labels justify nothing; deltas attributable to the initiative do.

</details>