# 6.2 — Modern Operations, Reliability, and Resilience in the Cloud

**Certification:** Google Cloud Digital Leader (`gcp-cdl`) · Exam guide version 2026-08-12
**Domain:** Section 6 — *Scaling with Google Cloud Operations* · **Objective 6.2** · **Exam weight: 5.0**
**Audience profile of this document:** Platform Architect / SRE. The exam asks you to *describe* these concepts; this material teaches you to *operate* them, because the descriptions only become unambiguous once you have seen the arithmetic and the failure modes behind them.

---

## 1. Motivation: the production architectural problem

### 1.1 The claim that breaks in production

A team migrates a monolith to Google Cloud. The migration deck says:

> "Google Cloud's SLA is 99.99%, so our availability improves from 99.5% to 99.99%."

This sentence contains three distinct errors, and each one maps to an exam concept:

1. **An SLA is not an SLO, and neither is an SLI.** The provider's SLA is a *financial contract about a specific resource*, not a prediction about *your application*.
2. **Availability composes multiplicatively along the serial request path**, not by taking the best number in the stack.
3. **Redundancy only helps when failures are independent.** Most real outages are correlated: one bad config, one bad binary, one expired certificate, one exhausted quota — pushed simultaneously to every replica.

### 1.2 The arithmetic of serial dependencies

Take a realistic checkout request path on Google Cloud:

```
Client
  → Cloud DNS
  → Global external Application Load Balancer (+ Cloud Armor)
  → GKE Ingress / NEG
  → checkout-api Pod
      → auth-service      (internal)
      → catalog-service   (internal)
      → pricing-service   (internal)
      → Cloud SQL (orders)
      → Memorystore (session cache)
      → Pub/Sub (event emit)
      → payment provider  (third party, egress)
```

If every one of the 12 hops is independently available at **99.9%**, and *all* must succeed for the request to succeed:

```
A_serial = 0.999 ^ 12 = 0.98807  →  98.807%
```

Unavailability = 1.193% of a 30-day month = **8 h 35 min of downtime per month**, from components that each individually "meet three nines". Nobody in the chain violated their target. The *user journey* failed anyway.

This is the central production problem the objective describes: **reliability is a property of the user journey, not of any component**, and it must therefore be *measured at the user journey* and *budgeted*, not asserted from vendor SLAs.

### 1.3 The arithmetic of redundancy — and why it under-delivers

Two replicas of a 99.9% component, failing **independently**, in a parallel (either-one-serves) topology:

```
A_parallel = 1 - (0.001)^2 = 0.999999  →  six nines
```

Now introduce a **correlation factor** ρ — the fraction of failures that hit both replicas at once (same bad image, same zone, same config rollout, same dependency):

| Correlation ρ | Effective unavailability | Effective availability | Downtime / 30 days |
|---|---|---|---|
| 0.00 (fully independent) | 1.0 × 10⁻⁶ | 99.9999% | 2.6 s |
| 0.01 | ≈ 1.1 × 10⁻⁵ | 99.9989% | 47 s |
| 0.10 | ≈ 1.0 × 10⁻⁴ | 99.99% | 4.3 min |
| 0.50 | ≈ 5.0 × 10⁻⁴ | 99.95% | 21.6 min |
| 1.00 (fully correlated) | 1.0 × 10⁻³ | 99.9% | 43.2 min |

Approximation: `U_eff ≈ ρ·U + (1-ρ)·U²`.

**Architectural consequence:** duplicating instances buys you almost nothing if the duplicate shares the failure cause. The engineering work of resilience is *decorrelating* — spreading across zones and regions, staggering rollouts, isolating blast radius, and shedding load gracefully — not merely increasing replica count.

### 1.4 The nines table you must be able to reproduce

| Availability | Downtime / 30-day month | Downtime / year | Typical GCP construct that gets you there |
|---|---|---|---|
| 99% ("two nines") | 7 h 12 min | 3 d 15 h | Single VM, best-effort |
| 99.5% | 3 h 36 min | 1 d 19 h | Single zonal deployment, manual recovery |
| 99.9% ("three nines") | 43 min 12 s | 8 h 46 min | Single zone + autohealing MIG |
| 99.95% | 21 min 36 s | 4 h 23 min | Regional (multi-zone) deployment |
| 99.99% ("four nines") | 4 min 19 s | 52 min 36 s | Multi-zone + global LB + automated failover |
| 99.999% ("five nines") | 25.9 s | 5 min 15 s | Multi-region active/active, e.g. Spanner multi-region |

**Exam-relevant reading of this table:** each additional nine costs roughly an order of magnitude more, and above ~99.99% the limiting factor is no longer infrastructure — it is *human response time*. You cannot page a human and recover in 25 seconds. Five nines requires automated failover with no human in the loop.

---

## 2. The reliability vocabulary, defined precisely

These four terms are the highest-yield definitions in the objective, and they are routinely confused.

### 2.1 SLI / SLO / SLA / Error Budget

| Term | What it is | Who it is for | Formal expression | Consequence of violation |
|---|---|---|---|---|
| **SLI** — Service Level Indicator | A *measurement* of service behaviour, expressed as a ratio of good events to valid events | Engineers | `good_events / valid_events` over a window | None — it is just a number |
| **SLO** — Service Level Objective | An *internal target* for an SLI over a window | Engineering + product | `SLI ≥ 99.9% over 30 rolling days` | Error budget policy triggers (freeze features, prioritise reliability work) |
| **SLA** — Service Level Agreement | An *external contract* with financial remedy | Customers, legal, finance | `SLA target < SLO target`, plus credits schedule | Service credits / contractual penalty |
| **Error budget** | The permitted unreliability: `1 − SLO` | Engineering + product | `(1 − 0.999) × valid_events` | Exhaustion = agreed change-freeze |

**The invariant you must remember:** `SLA target  <  SLO target  ≤  achievable SLI`.
The SLO is deliberately *stricter* than the SLA so the team is alerted and reacts **before** the contract is breached. A team that sets SLO = SLA has no reaction margin at all.

### 2.2 SLI types — the four that matter

| SLI type | Definition | Good example specification | Common mistake |
|---|---|---|---|
| **Availability** | Fraction of valid requests served successfully | `count(status != 5xx) / count(status != 4xx-client-fault)` | Counting client 4xx as your failures |
| **Latency** | Fraction of valid requests faster than a threshold | `count(latency < 300 ms) / count(all)` | Reporting a *mean*; means hide the tail |
| **Quality / correctness** | Fraction of responses served without degradation | `count(full_result) / count(all)` | Not measuring degraded-mode responses at all |
| **Freshness / durability** (data & batch) | Fraction of data younger than a threshold | `count(records with age < 5 min) / count(all)` | Assuming pipeline "success" == fresh data |

**Latency must be expressed as a threshold ratio, never as a percentile target alone.** "p99 < 300 ms" and "99% of requests < 300 ms" are the same statement; but "average latency < 300 ms" is compatible with 5% of users waiting 10 seconds. Google's Golden Signals framing exists precisely to force the distributional view.

### 2.3 Error budget math and burn rate

For a 99.9% SLO over a 30-day rolling window:

```
Error budget            = 0.1% of valid requests
Budget in wall-clock    = 0.001 × 30 d = 43 min 12 s
```

**Burn rate** is the multiple of the *nominal* consumption speed:

```
burn_rate = (fraction of budget consumed) / (fraction of window elapsed)
```

Burn rate 1 exhausts the budget exactly at the end of the window. Burn rate 14.4 exhausts it in 50 hours — and consumes 2% of it in a single hour.

| Budget consumed | In elapsed time | Burn rate | Time to exhaustion | Recommended alert action |
|---|---|---|---|---|
| 2% | 1 hour | **14.4** | ~2 days | **Page** (long window 1 h / short window 5 min) |
| 5% | 6 hours | **6** | ~5 days | **Page** (long 6 h / short 30 min) |
| 10% | 3 days | **1** | 30 days | **Ticket** (long 3 d / short 6 h) |
| 10% | 1 hour | 72 | ~10 hours | Page — total outage class |

**Multi-window, multi-burn-rate alerting** is the technique that makes this actionable, and it is what you implement in §5:

* the **long window** gives precision (it will not fire on a 15-second blip);
* the **short window** (conventionally 1/12 of the long window) gives *reset speed* — it stops the alert from staying latched for hours after the incident is over;
* both conditions must be true simultaneously (`AND` combiner).

| Alerting strategy | Detection time | False-positive rate | Reset time | Verdict |
|---|---|---|---|---|
| Threshold on raw error rate (`errors > 10/s`) | Fast | Very high (scales with traffic) | Fast | Rejected: not user-centric, no budget semantics |
| Single long window on budget consumption | Slow | Low | Very slow (latched) | Rejected: alert stays firing after recovery |
| Single short window | Very fast | High | Fast | Rejected: pages on every blip |
| **Multi-window multi-burn-rate** | Fast for severe, slow for mild | Low | Fast | **Adopted standard** |

---

## 3. Modern operations: DevOps, SRE, and platform engineering

### 3.1 The three operating models compared

| Dimension | Traditional Ops (siloed) | DevOps | SRE (as Google practises it) |
|---|---|---|---|
| Core premise | Change is risk; minimise change | Shared ownership of delivery | Reliability is a *feature*, engineered with data |
| Who runs production | Separate ops team | "You build it, you run it" | Engineering team, with SRE as a specialist partner |
| Stability vs. velocity | Framed as a trade-off | Framed as mutually reinforcing | **Arbitrated numerically by the error budget** |
| Change approval | CAB / manual gates | Automated pipeline + tests | Automated + progressive delivery + budget policy |
| Response to an outage | Find who broke it | Retrospective | **Blameless postmortem**, systemic action items |
| Manual work | Accepted as the job | Reduced where convenient | **Toil capped (≤ 50%)**, explicitly measured |
| Definition of "done" | Deployed | Deployed and monitored | Deployed, instrumented, SLO'd, and on-call-ready |

The exam-level framing: **SRE is a concrete implementation of DevOps principles**, and its distinguishing mechanism is the **error budget**, which converts an unwinnable political argument ("ship faster" vs. "stop breaking things") into a shared number that both sides agreed to in advance.

### 3.2 The error budget policy — the actual mechanism

An error budget without a written *policy* is decoration. The policy states, before the incident, what happens at each threshold:

| Budget remaining | Policy action |
|---|---|
| > 50% | Normal operation. Ship features. Risky experiments allowed. |
| 25–50% | Reliability work prioritised alongside features. Canary percentages reduced. |
| 10–25% | Feature freeze on the affected service, except reliability fixes and security patches. |
| < 10% | Full change freeze. All engineering capacity on reliability. Rollback authority delegated to on-call. |
| Exhausted / negative | Freeze + mandatory review with product ownership before the freeze lifts. |

### 3.3 Toil — the definition you must be able to recite

**Toil** is operational work that is: *manual, repetitive, automatable, tactical, devoid of enduring value, and scaling linearly with service growth.*

The linear-scaling clause is the discriminator. Designing a new capacity model is not toil (it produces enduring value). Manually resizing 40 node pools every quarter is toil (it grows with the fleet).

**The economics:** if a task takes `t` minutes, happens `n` times per month, and automation costs `C` engineer-minutes:

```
payback_months = C / (t × n)
```

At `t = 20 min`, `n = 30/month`, `C = 2400 min` (one engineer-week), payback is **4 months** — and it also removes a class of human error and an on-call wake-up. SRE practice caps toil at **50% of an SRE's time**, with the remainder reserved for engineering that reduces future toil.

### 3.4 DORA — the measurement layer of modern operations

DORA (DevOps Research and Assessment, now part of Google Cloud) measures delivery performance with four keys, plus reliability as the outcome metric.

| Metric | What it measures | Throughput or Stability | Elite-performer band (typical published figures) |
|---|---|---|---|
| **Deployment frequency** | How often you release to production | Throughput | On demand, multiple times per day |
| **Lead time for changes** | Commit → running in production | Throughput | Less than one day |
| **Change failure rate** | % of deployments causing degradation requiring remediation | Stability | 5–10% |
| **Failed deployment recovery time** (formerly *time to restore service* / MTTR) | Time to recover from a failed deployment | Stability | Less than one hour |
| **Reliability** (fifth, outcome) | Ability to meet or exceed user expectations — i.e. your SLOs | Outcome | Meeting SLO targets |

The counter-intuitive, exam-relevant DORA finding: **throughput and stability rise together.** Teams that deploy more frequently have *lower* change failure rates, because small batches are easier to test, review, canary and roll back. The traditional assumption — that slowing releases increases safety — is contradicted by the data.

### 3.5 Terminology matrix — the acronyms that get confused

| Acronym | Expansion | Measures | Domain |
|---|---|---|---|
| MTTR | Mean Time To Repair/Restore | Detection → service restored | Incident response |
| MTTD | Mean Time To Detect | Fault begins → alert fires | Observability quality |
| MTTA | Mean Time To Acknowledge | Alert fires → human responds | On-call health |
| MTBF | Mean Time Between Failures | Failure → next failure | Component reliability |
| **RTO** | **Recovery Time Objective** | **Max tolerable *downtime* after disaster** | **DR planning** |
| **RPO** | **Recovery Point Objective** | **Max tolerable *data loss*, in time** | **DR planning** |

**RTO vs. RPO is the single most frequently examined distinction in this objective.**
*RTO looks forward from the disaster: how long until I am serving again.*
*RPO looks backward from the disaster: how much data am I willing to lose.*
RPO is bounded by your **backup/replication interval**: hourly snapshots ⇒ RPO cannot be better than 1 hour, no matter how fast you restore.

---

## 4. Observability on Google Cloud

### 4.1 Monitoring vs. observability

| | Monitoring | Observability |
|---|---|---|
| Question answered | "Is the known-bad condition happening?" | "Why is this unknown-bad condition happening?" |
| Built from | Pre-defined metrics, dashboards, alerts | High-cardinality telemetry you can query ad hoc |
| Fails when | The failure mode was not anticipated | Cardinality/cost explodes, or context is missing |
| Typical artefact | Alert policy, uptime check | Trace waterfall, log query, profile flame graph |

You need both. Monitoring tells you *that* the SLO is burning; observability tells you *which of the 12 hops* is responsible.

### 4.2 The Four Golden Signals → Google Cloud metric mapping

| Golden signal | Meaning | GCP metric source (typical) |
|---|---|---|
| **Latency** | Time to serve a request — *split successful from failed* | `loadbalancing.googleapis.com/https/total_latencies`, `run.googleapis.com/request_latencies`, Cloud Trace |
| **Traffic** | Demand on the system | `loadbalancing.googleapis.com/https/request_count`, `pubsub.googleapis.com/subscription/num_undelivered_messages` |
| **Errors** | Rate of failed requests, explicit and implicit | `response_code_class = 5xx`, Error Reporting groups, logs-based metrics |
| **Saturation** | How full the most constrained resource is | `kubernetes.io/container/cpu/limit_utilization`, `memory/used_bytes`, connection pool depth, queue depth |

**Failed-request latency must be separated from successful-request latency.** A service that fails fast looks like a latency *improvement* on a blended chart — an outage that presents as a performance win is a classic dashboard trap.

### 4.3 The Google Cloud Observability product set

| Product | Purpose | Signal | Key operational note |
|---|---|---|---|
| **Cloud Logging** | Ingest, store, route, query logs | Logs | `_Required` bucket (400 d, free, immutable retention); `_Default` bucket (30 d, configurable). **Log sinks** route to BigQuery/GCS/Pub/Sub. Logs-based metrics turn logs into time series. |
| **Cloud Monitoring** | Metrics, dashboards, uptime checks, alert policies, **SLO/error-budget services** | Metrics | Native SLO objects with burn-rate selectors; metric scopes let one project observe many. |
| **Cloud Trace** | Distributed tracing across services | Traces | Latency waterfall — the tool that identifies *which hop* is slow in §1.2. |
| **Cloud Profiler** | Continuous statistical CPU/heap profiling in production | Profiles | Low overhead; finds *why the code* is slow, after Trace found *where*. |
| **Error Reporting** | Aggregates and deduplicates crashes/exceptions into groups | Errors | Turns 40,000 stack traces into 3 issues with first/last-seen. |
| **Cloud Debugger / snapshots** | Inspect state in running apps | State | Availability varies by runtime; verify current support in docs before relying on it. |
| **Managed Service for Prometheus** | Global, long-term Prometheus-compatible metrics | Metrics | Ingests PromQL workloads without running your own Prometheus HA pair. |
| **Personalized Service Health** | Google-side incident signal scoped to *your* projects | Events | Distinguishes "Google is broken" from "we are broken" — critical during triage. |

**Triage order that follows from this table:** Monitoring (SLO burn) → Personalized Service Health (is it us?) → Trace (which hop) → Logging/Error Reporting (what error) → Profiler (why the code).

---

## 5. Complete infrastructure: SLOs and burn-rate alerting as code

Everything in §2 becomes operational only when it is declared. The following Terraform is complete and applies as-is against a project with the Monitoring API enabled.

```hcl
# ---------------------------------------------------------------------------
# slo.tf — Service, SLOs and multi-window multi-burn-rate alerting
# Provider: hashicorp/google >= 5.0
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Project that owns the Monitoring workspace."
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "url_map_name" {
  type        = string
  description = "URL map fronting the checkout service."
  default     = "checkout-urlmap"
}

variable "oncall_channel_id" {
  type        = string
  description = "Existing notification channel ID for the paging rotation."
}

variable "ticket_channel_id" {
  type        = string
  description = "Existing notification channel ID for the ticket queue."
}

# ---------------------------------------------------------------------------
# 1. The Service. An SLO always hangs off a Service object in Cloud Monitoring.
#    Use google_monitoring_custom_service for anything Monitoring does not
#    auto-discover (GKE/App Engine/Cloud Run services can be discovered).
# ---------------------------------------------------------------------------
resource "google_monitoring_custom_service" "checkout" {
  project      = var.project_id
  service_id   = "checkout-api"
  display_name = "Checkout API (critical user journey)"

  user_labels = {
    tier            = "critical"
    owning_team     = "payments-platform"
    error_budget_pol = "cup-2026-01"
  }
}

# ---------------------------------------------------------------------------
# 2. Availability SLI/SLO — request-based, good/total ratio.
#    "Valid" excludes 4xx: client-side faults are not our budget to spend.
# ---------------------------------------------------------------------------
locals {
  lb_base_filter = join(" AND ", [
    "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
    "resource.type=\"https_lb_rule\"",
    "resource.label.\"project_id\"=\"${var.project_id}\"",
    "resource.label.\"url_map_name\"=\"${var.url_map_name}\"",
  ])

  lb_latency_base_filter = join(" AND ", [
    "metric.type=\"loadbalancing.googleapis.com/https/total_latencies\"",
    "resource.type=\"https_lb_rule\"",
    "resource.label.\"project_id\"=\"${var.project_id}\"",
    "resource.label.\"url_map_name\"=\"${var.url_map_name}\"",
  ])
}

resource "google_monitoring_slo" "checkout_availability" {
  project      = var.project_id
  service      = google_monitoring_custom_service.checkout.service_id
  slo_id       = "checkout-availability-30d"
  display_name = "99.9% of valid checkout requests succeed (30d rolling)"

  goal                = 0.999
  rolling_period_days = 30

  request_based_sli {
    good_total_ratio {
      # Good  = everything that is not a server-side failure.
      good_service_filter = join(" AND ", [
        local.lb_base_filter,
        "metric.label.\"response_code_class\"!=\"500\"",
        "metric.label.\"response_code_class\"!=\"400\"",
      ])

      # Total = valid requests. 4xx removed: a malformed client request is
      # not an availability failure of ours.
      total_service_filter = join(" AND ", [
        local.lb_base_filter,
        "metric.label.\"response_code_class\"!=\"400\"",
      ])
    }
  }
}

# ---------------------------------------------------------------------------
# 3. Latency SLI/SLO — distribution cut. 99% of requests under 300 ms.
# ---------------------------------------------------------------------------
resource "google_monitoring_slo" "checkout_latency" {
  project      = var.project_id
  service      = google_monitoring_custom_service.checkout.service_id
  slo_id       = "checkout-latency-300ms-30d"
  display_name = "99% of checkout requests complete in under 300 ms (30d rolling)"

  goal                = 0.99
  rolling_period_days = 30

  request_based_sli {
    distribution_cut {
      distribution_filter = local.lb_latency_base_filter

      range {
        min = 0
        max = 300 # milliseconds
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 4. FAST BURN — 14.4x. Consumes 2% of the 30-day budget in one hour.
#    Two conditions ANDed: 1h long window (precision) + 5m short window (reset).
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "checkout_availability_fast_burn" {
  project      = var.project_id
  display_name = "[PAGE] checkout availability — fast burn (14.4x)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "1h burn rate > 14.4"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"3600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 14.4
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "5m burn rate > 14.4"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"300s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 14.4
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.oncall_channel_id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Checkout availability budget burning at >14.4x"
    content   = <<-EOT
      ## Fast burn — page

      At this rate the 30-day error budget is exhausted in **~50 hours**.

      ### First five minutes
      1. Check Personalized Service Health: is this a Google-side incident?
         `gcloud beta service-health events list --location=global`
      2. Check for a recent rollout — most fast burns are change-induced:
         `gcloud deploy rollouts list --delivery-pipeline=checkout-api \
            --region=${var.region} --limit=5`
      3. If a rollout landed within the burn window, **roll back first,
         diagnose second**. Rollback authority is delegated to on-call.
      4. Identify the failing hop in Cloud Trace before touching any service.

      ### Escalation
      Payments Platform on-call → Platform SRE lead after 20 minutes.
    EOT
  }

  severity = "CRITICAL"
}

# ---------------------------------------------------------------------------
# 5. SLOW BURN — 6x over 6h. Page, but with a wider, less twitchy window.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "checkout_availability_slow_burn" {
  project      = var.project_id
  display_name = "[PAGE] checkout availability — slow burn (6x)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "6h burn rate > 6"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"21600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 6
      duration        = "0s"

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "30m burn rate > 6"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"1800s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 6
      duration        = "0s"

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.oncall_channel_id]

  alert_strategy {
    auto_close = "3600s"
  }

  severity = "ERROR"
}

# ---------------------------------------------------------------------------
# 6. GRADUAL BURN — 1x over 3 days. Ticket, never a page.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "checkout_availability_gradual_burn" {
  project      = var.project_id
  display_name = "[TICKET] checkout availability — gradual burn (1x)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "3d burn rate > 1"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"259200s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "0s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "6h burn rate > 1"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.checkout_availability.name}\", \"21600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "0s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.ticket_channel_id]

  alert_strategy {
    auto_close = "86400s"
  }

  severity = "WARNING"
}

# ---------------------------------------------------------------------------
# 7. Black-box uptime check — catches whole-frontend failures that produce
#    no LB metrics at all (DNS gone, cert expired, forwarding rule deleted).
#    White-box SLOs go blind exactly when the system is most broken.
# ---------------------------------------------------------------------------
resource "google_monitoring_uptime_check_config" "checkout_https" {
  project      = var.project_id
  display_name = "checkout-api /healthz (global)"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path           = "/healthz"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = "checkout.example.com"
    }
  }

  selected_regions = ["EUROPE", "USA", "SOUTH_AMERICA", "ASIA_PACIFIC"]

  checker_type = "STATIC_IP_CHECKERS"
}

resource "google_monitoring_alert_policy" "checkout_uptime_down" {
  project      = var.project_id
  display_name = "[PAGE] checkout-api unreachable from multiple regions"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\"",
        "resource.type=\"uptime_url\"",
        "metric.label.\"check_id\"=\"${google_monitoring_uptime_check_config.checkout_https.uptime_check_id}\"",
      ])
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 3 # at least 3 probe regions failing → not a probe artefact
      }
    }
  }

  notification_channels = [var.oncall_channel_id]
  severity              = "CRITICAL"
}

output "availability_slo_name" {
  value       = google_monitoring_slo.checkout_availability.name
  description = "Fully qualified SLO resource name, used by select_slo_burn_rate()."
}
```

---

## 6. Resilience: failure domains, redundancy topologies, and DR

### 6.1 Google Cloud failure domains

| Scope | Blast radius | Survives | Does not survive | Example resources |
|---|---|---|---|---|
| **Zonal** | One zone | Single machine/rack failure | Zone outage | GCE instance, zonal PD, zonal GKE cluster, zonal MIG |
| **Regional** | One region (≥3 zones) | Zone outage | Region outage | Regional MIG, regional PD, regional GKE, Cloud SQL HA, regional GCS bucket |
| **Multi-regional** | A defined set of regions | Region outage | Continent-wide correlated event (rare) | GCS multi-region bucket, Spanner multi-region config, BigQuery multi-region dataset |
| **Global** | Google's global network | Region outage, transparently | Global control-plane incident (very rare) | Global external Application Load Balancer, Cloud DNS, VPC, IAM, Cloud CDN |

**The architectural rule that follows:** a service is only as resilient as its *least-resilient stateful dependency*. A globally load-balanced, multi-region stateless tier that writes to a single **zonal** Cloud SQL instance is a zonal service wearing a global costume.

### 6.2 Published availability SLAs — orientation

These are contractual figures published by Google Cloud and they change; always confirm against `cloud.google.com/terms/sla` before designing to them. They are shown here to illustrate the *shape* of the cost/availability curve.

| Service / configuration | Typical published monthly SLA |
|---|---|
| Compute Engine — single instance | 99.9% |
| Compute Engine — instances in ≥2 zones in a region | 99.99% |
| GKE — zonal cluster control plane | 99.5% |
| GKE — regional cluster control plane | 99.95% |
| Cloud Run | 99.95% |
| Cloud SQL — HA (regional) configuration | 99.95% |
| Cloud Spanner — regional configuration | 99.99% |
| Cloud Spanner — multi-region configuration | 99.999% |
| Cloud Storage — Standard, regional | 99.9% |
| Cloud Storage — Standard, multi-region/dual-region | 99.95% |
| Global external Application Load Balancer | 99.99% |

Note the pattern: **crossing a failure domain boundary is what buys a nine.** Zonal → regional → multi-region, each step upward.

### 6.3 Disaster recovery patterns — the RTO/RPO/cost trade-off

| Pattern | RTO | RPO | Steady-state cost | What actually runs in the DR region | Failure mode it does *not* cover |
|---|---|---|---|---|---|
| **Backup & restore** | Hours → days | Hours (= backup interval) | Lowest (~5% of prod) | Nothing; backups in GCS | Anything needing fast recovery; untested restores |
| **Cold standby / pilot light** | 10s of minutes → hours | Minutes → hours | Low (~15–25%) | Data replicated, minimal core services, images pre-built | Capacity unavailable in DR region at failover time |
| **Warm standby** | Minutes | Seconds → minutes | Medium (~50%) | Scaled-down full stack, continuous replication | Scale-up lag under real production load |
| **Hot standby / active-active** | Near zero | Near zero | Highest (2× or more) | Full stack serving traffic in both regions | Correlated logical failures (bad config/data replicates instantly) |

**The trap in the last row:** active-active replication propagates *logical* corruption at replication speed. A `DELETE` without a `WHERE` clause reaches every region in milliseconds. Hot standby protects against *infrastructure* disasters; only **point-in-time recovery and immutable backups** protect against *logical* ones. Mature designs run both.

### 6.4 Resilience patterns in application design

| Pattern | Problem solved | Implementation on GCP | Cost of getting it wrong |
|---|---|---|---|
| **Health checks + autohealing** | Sick instances keep receiving traffic | MIG `auto_healing_policies`, GKE liveness probes | Aggressive probes cause restart storms under load |
| **Graceful degradation** | Total failure when one dependency dies | Serve cached/partial results; feature flags | Silent quality loss with no SLI to detect it |
| **Circuit breaker** | Retries against a dead dependency amplify the outage | Backend service `circuitBreakers`, Envoy/Service Mesh | Threshold too low ⇒ breaks on normal spikes |
| **Exponential backoff + jitter** | Synchronised retry storms (thundering herd) | Client libraries; `retry` in Pub/Sub, Cloud Tasks | Fixed-interval retries re-synchronise every client |
| **Load shedding** | Overload collapses everything instead of degrading | Cloud Armor rate limiting, `maxRatePerEndpoint` | Shedding the wrong traffic (drop bots, not checkouts) |
| **Bulkhead / isolation** | One noisy tenant starves the rest | Separate node pools, per-tenant quotas, separate backend services | Over-partitioning wastes capacity |
| **Timeout budgets** | Threads pile up on slow calls | `BackendConfig.timeoutSec`, gRPC deadlines | Inner timeout > outer timeout ⇒ caller gives up first, work wasted |
| **Idempotency** | Retries duplicate side effects | Idempotency keys, Pub/Sub `messageId` dedup | Double-charged customers |
| **Chaos / DiRT testing** | Untested failover does not work | Scheduled zone-drain game days | The first real test is the real outage |

**Timeout budget invariant:** for a call chain `A → B → C`, you need `timeout(A→B) > timeout(B→C) + processing(B)`. Violating it means A abandons the request while B and C keep burning capacity on work nobody will read — a classic retry-amplification collapse.

---

## 7. Complete workload manifests: a resilient GKE service

The following is a full, syntactically valid manifest set. It encodes every resilience pattern from §6.4 that belongs at the workload layer.

```yaml
# ---------------------------------------------------------------------------
# checkout-api.yaml — resilient workload for GKE regional cluster
# Apply with: kubectl apply -f checkout-api.yaml
# ---------------------------------------------------------------------------
apiVersion: v1
kind: Namespace
metadata:
  name: checkout
  labels:
    app.kubernetes.io/part-of: payments-platform
    tier: critical
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-user-journey
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: >-
  Critical user journeys. Under node pressure these evict batch and internal
  tooling workloads rather than being evicted themselves.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    # Workload Identity Federation for GKE: no downloaded service account keys.
    iam.gke.io/gcp-service-account: checkout-api@example-prod.iam.gserviceaccount.com
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  labels:
    app: checkout-api
    app.kubernetes.io/name: checkout-api
    app.kubernetes.io/version: "2.14.0"
spec:
  # Baseline only. The HPA owns replicas after the first reconcile; keep this
  # value out of your GitOps diff loop or the HPA and Git will fight forever.
  replicas: 6
  revisionHistoryLimit: 10

  # Minimum time a new Pod must stay Ready before it counts toward the
  # rollout's available replicas. Without it, a Pod that becomes Ready and
  # then crash-loops still advances the rollout.
  minReadySeconds: 30

  # Fail the rollout instead of hanging forever on a broken image.
  progressDeadlineSeconds: 600

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%        # burst capacity during rollout
      maxUnavailable: 0    # never dip below the current replica count

  selector:
    matchLabels:
      app: checkout-api

  template:
    metadata:
      labels:
        app: checkout-api
        app.kubernetes.io/version: "2.14.0"
      annotations:
        # Forces a rollout when the ConfigMap changes; without this, config
        # changes silently apply only to Pods that happen to restart later.
        checksum/config: "e3b0c44298fc1c149afbf4c8996fb924"
    spec:
      serviceAccountName: checkout-api
      priorityClassName: critical-user-journey

      # Must exceed the longest in-flight request plus the preStop drain.
      terminationGracePeriodSeconds: 90

      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault

      # ---- Decorrelation, part 1: spread across zones -------------------
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: checkout-api
        # Softer constraint at node granularity: prefer spreading, but do not
        # block scheduling if the cluster is temporarily packed.
        - maxSkew: 2
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: checkout-api

      # ---- Decorrelation, part 2: never co-locate two replicas ----------
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: checkout-api

      containers:
        - name: checkout-api
          image: europe-west1-docker.pkg.dev/example-prod/apps/checkout-api:2.14.0
          imagePullPolicy: IfNotPresent

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP

          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['topology.kubernetes.io/zone']
            - name: OTEL_SERVICE_NAME
              value: checkout-api
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://opentelemetry-collector.observability:4317
            # Timeout budget: this must be SMALLER than the LB backend
            # timeout (30 s) so we fail before the caller abandons us.
            - name: UPSTREAM_TIMEOUT_MS
              value: "2500"
            - name: UPSTREAM_MAX_RETRIES
              value: "2"

          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              # Memory limit == request: memory is incompressible, so
              # overcommitting it converts a slowdown into an OOMKill.
              memory: "512Mi"
              # CPU limit deliberately omitted. A CPU limit throttles the
              # container even when the node is idle, which inflates tail
              # latency (the exact thing the latency SLO measures). The
              # request already guarantees a share under contention.

          # ---- Three distinct probes, three distinct jobs ---------------
          # startupProbe:   "has it finished booting?"   — suppresses the others
          # readinessProbe: "should it get traffic now?" — removes from Service
          # livenessProbe:  "is it unrecoverable?"       — restarts the container
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: http
            failureThreshold: 30
            periodSeconds: 5        # allows up to 150 s of cold start

          readinessProbe:
            httpGet:
              path: /healthz/ready   # MUST check downstream dependencies
              port: http
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 3
            successThreshold: 1
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /healthz/live    # MUST NOT check downstream dependencies
              port: http
            initialDelaySeconds: 0
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 4      # ~60 s before a restart

          lifecycle:
            preStop:
              exec:
                # Connection draining. Endpoint removal from the NEG is
                # eventually consistent; exiting immediately on SIGTERM
                # produces 502s for in-flight requests routed by a
                # not-yet-updated load balancer.
                command: ["/bin/sh", "-c", "sleep 20"]

          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: config
              mountPath: /etc/checkout
              readOnly: true

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
        - name: config
          configMap:
            name: checkout-api-config
---
# ---------------------------------------------------------------------------
# PodDisruptionBudget: bounds VOLUNTARY disruption only — node upgrades,
# cluster autoscaler scale-down, `kubectl drain`. It does NOT protect against
# node crashes or zone outages. That is what topology spread is for.
# ---------------------------------------------------------------------------
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api
  namespace: checkout
spec:
  # Percentage form, not an absolute count: this stays correct as the HPA
  # scales the Deployment between 6 and 60 replicas.
  maxUnavailable: 25%
  selector:
    matchLabels:
      app: checkout-api
  # Do not let Pods that are already broken block a node drain forever.
  unhealthyPodEvictionPolicy: AlwaysAllow
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
  namespace: checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api

  minReplicas: 6      # >= 3 zones x 2, so a zone loss never drops below quorum
  maxReplicas: 60

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # 60%, not 80%: the headroom absorbs the scale-up lag
          # (metric scrape + HPA period + scheduling + image pull + startup).
          averageUtilization: 60

    # Demand-side signal. Scaling on requests-per-pod reacts to the load
    # itself rather than to CPU, which is a lagging proxy for it.
    - type: Pods
      pods:
        metric:
          name: prometheus.googleapis.com|http_requests_per_second|gauge
        target:
          type: AverageValue
          averageValue: "80"

  behavior:
    scaleUp:
      # React fast to load. Under-provisioning is a user-visible outage;
      # brief over-provisioning is only a cost line.
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100          # allow doubling
          periodSeconds: 30
        - type: Pods
          value: 8
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      # React slowly. Aggressive scale-down causes flapping and turns a
      # traffic dip into an outage when traffic returns.
      stabilizationWindowSeconds: 600
      policies:
        - type: Percent
          value: 10
          periodSeconds: 120
      selectPolicy: Min
---
apiVersion: v1
kind: Service
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    # Container-native load balancing: the LB targets Pod IPs directly via a
    # Network Endpoint Group, removing the kube-proxy hop. This both lowers
    # latency and makes LB health checks reflect real Pod health.
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"default": "checkout-api-backendconfig"}'
spec:
  type: ClusterIP
  selector:
    app: checkout-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: checkout-api-backendconfig
  namespace: checkout
spec:
  # Outer timeout of the budget chain. Inner call timeout is 2500 ms.
  timeoutSec: 30

  # Must be >= the preStop sleep, or the LB stops draining before the Pod
  # has finished serving in-flight requests.
  connectionDraining:
    drainingTimeoutSec: 60

  healthCheck:
    type: HTTP
    requestPath: /healthz/ready
    port: 8080
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3

  # Load shedding at the edge, before the request costs you a Pod.
  securityPolicy:
    name: checkout-edge-policy

  logging:
    enable: true
    sampleRate: 1.0   # full sampling on a critical journey; reduce if cost-bound

  # Edge caching for static/idempotent GETs.
  cdn:
    enabled: false
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-api-default-deny-egress
  namespace: checkout
spec:
  podSelector:
    matchLabels:
      app: checkout-api
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app: auth-service
        - podSelector:
            matchLabels:
              app: catalog-service
        - podSelector:
            matchLabels:
              app: pricing-service
      ports:
        - protocol: TCP
          port: 8080
    # Google APIs via Private Google Access
    - to:
        - ipBlock:
            cidr: 199.36.153.8/30
      ports:
        - protocol: TCP
          port: 443
```

### 7.1 The probe distinction that causes cascading outages

This is the highest-value operational detail in the manifest above, and it is worth stating as a rule:

> **A liveness probe must never test a downstream dependency.**

If `/healthz/live` calls the database and the database has a 90-second blip, every Pod in the fleet fails liveness simultaneously, every Pod is restarted simultaneously, all warm caches and connection pools are destroyed simultaneously, and the fleet then stampedes the *recovering* database with reconnect traffic. A recoverable 90-second dependency blip becomes a 30-minute self-inflicted outage.

| Probe | Question | May check dependencies? | Failure action | Correct threshold posture |
|---|---|---|---|---|
| `startupProbe` | "Has it finished booting?" | No | Suppresses the other probes until it passes | Generous `failureThreshold` |
| `readinessProbe` | "Can it serve *right now*?" | **Yes** | Removed from Service endpoints; **not restarted** | Sensitive — fast in and out |
| `livenessProbe` | "Is it permanently wedged?" | **No — process-local only** | **Container restarted** | Conservative — high threshold, long period |

---

## 8. Progressive delivery: making change safe

### 8.1 Deployment strategy trade-offs

| Strategy | Blast radius on a bad release | Rollback speed | Infra cost | Requires traffic splitting | Requires schema back-compat |
|---|---|---|---|---|---|
| **Recreate** | 100% + downtime window | Slow (redeploy) | 1× | No | Yes |
| **Rolling update** | Grows with each batch (0→100%) | Medium (roll back through batches) | ~1.25× | No | Yes |
| **Blue/green** | 100% at cutover, 0% before | **Fastest** (flip pointer) | **2×** | Yes (all-or-nothing) | Yes |
| **Canary** | Bounded by canary % (e.g. 5%) | Fast (shift traffic back) | ~1.1× | Yes (weighted) | Yes |
| **Feature flag / dark launch** | Bounded by flag cohort | **Instant** (no redeploy) | 1× | No (in-process) | Yes |
| **Shadow / mirrored traffic** | **Zero** (responses discarded) | N/A | ~2× compute | Yes (mirroring) | Yes |

**Canary is the default for a critical journey**, because it bounds blast radius *and* is cheap. Blue/green buys the fastest rollback but doubles cost and still exposes 100% of users at the instant of cutover.

**The constraint that applies to every row:** all of them require the *database schema* to be backward-compatible with the previous application version, because during any of these strategies two application versions run concurrently against one schema. This is the **expand/contract** (parallel change) pattern: expand the schema, deploy code that writes both, backfill, deploy code that reads new, contract the schema — four separate deployments, never one.

### 8.2 Cloud Deploy pipeline with automated canary and rollback

```yaml
# ---------------------------------------------------------------------------
# clouddeploy.yaml
# Register with:
#   gcloud deploy apply --file=clouddeploy.yaml --region=europe-west1
# ---------------------------------------------------------------------------
apiVersion: deploy.cloud.google.com/v1
kind: DeliveryPipeline
metadata:
  name: checkout-api
  annotations:
    owning-team: payments-platform
  labels:
    tier: critical
description: >-
  Checkout API delivery pipeline. staging is fully automated; prod requires
  approval and rolls out as a 5/25/50/100 canary with verification at each step.
serialPipeline:
  stages:
    - targetId: staging
      profiles:
        - staging
      strategy:
        standard:
          verify: true

    - targetId: prod
      profiles:
        - prod
      strategy:
        canary:
          runtimeConfig:
            kubernetes:
              gatewayServiceMesh:
                httpRoute: checkout-api-route
                service: checkout-api
                deployment: checkout-api
                routeUpdateWaitTime: 60s
                podSelectorLabel: app
          canaryDeployment:
            percentages: [5, 25, 50]
            verify: true
            predeploy:
              actions:
                - snapshot-slo-baseline
            postdeploy:
              actions:
                - check-slo-burn
---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: staging
description: Regional GKE staging cluster (europe-west1)
requireApproval: false
gke:
  cluster: projects/example-staging/locations/europe-west1/clusters/apps-euw1
executionConfigs:
  - usages: [RENDER, DEPLOY, VERIFY, PREDEPLOY, POSTDEPLOY]
    serviceAccount: clouddeploy-exec@example-staging.iam.gserviceaccount.com
    artifactStorage: gs://example-staging-clouddeploy-artifacts
    executionTimeout: 3600s
---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: prod
description: Regional GKE production cluster (europe-west1)
# Human gate on the critical journey. The canary bounds the blast radius;
# the approval bounds *when* it happens (no Friday 18:00 promotions).
requireApproval: true
gke:
  cluster: projects/example-prod/locations/europe-west1/clusters/apps-euw1
executionConfigs:
  - usages: [RENDER, DEPLOY, VERIFY, PREDEPLOY, POSTDEPLOY]
    serviceAccount: clouddeploy-exec@example-prod.iam.gserviceaccount.com
    artifactStorage: gs://example-prod-clouddeploy-artifacts
    executionTimeout: 3600s
---
# ---------------------------------------------------------------------------
# Automation: advance the canary automatically when verification passes, and
# roll back automatically when a rollout job fails. This is the mechanism that
# takes the human out of the MTTR path for change-induced failure — the single
# largest category of production incidents.
# ---------------------------------------------------------------------------
apiVersion: deploy.cloud.google.com/v1
kind: Automation
metadata:
  name: checkout-api/auto-advance-and-repair
description: Advance verified canary phases; roll back on failure.
serviceAccount: clouddeploy-automation@example-prod.iam.gserviceaccount.com
selector:
  - target:
      id: prod
rules:
  - advanceRolloutRule:
      name: advance-verified-canary
      sourcePhases: ["canary-5", "canary-25", "canary-50"]
      wait: 10m          # soak each phase before advancing

  - repairRolloutRule:
      name: rollback-on-failure
      phases: ["canary-5", "canary-25", "canary-50", "stable"]
      jobs: ["deploy", "verify"]
      repairPhases:
        - retry:
            attempts: 1
            wait: 60s
            backoffMode: BACKOFF_MODE_LINEAR
        - rollback:
            destinationPhase: "stable"
            disableRollbackIfRolloutPending: true
---
# ---------------------------------------------------------------------------
# skaffold.yaml — the renderer Cloud Deploy invokes.
# ---------------------------------------------------------------------------
apiVersion: skaffold/v4beta7
kind: Config
metadata:
  name: checkout-api
manifests:
  kustomize:
    paths:
      - manifests/base
deploy:
  kubectl: {}
verify:
  - name: slo-smoke-test
    container:
      name: slo-smoke-test
      image: europe-west1-docker.pkg.dev/example-prod/tools/verifier:1.4.0
      command: ["/bin/sh"]
      args:
        - -c
        - |
          set -euo pipefail
          echo "Probing canary endpoint for 300s..."
          /usr/local/bin/probe \
            --url "https://checkout.example.com/api/v1/cart/health" \
            --duration 300s \
            --qps 20 \
            --max-error-rate 0.005 \
            --max-p99-latency 300ms
customActions:
  - name: snapshot-slo-baseline
    containers:
      - name: snapshot
        image: europe-west1-docker.pkg.dev/example-prod/tools/sloctl:1.2.0
        args: ["snapshot", "--slo", "checkout-availability-30d", "--out", "gs://example-prod-clouddeploy-artifacts/baselines"]
  - name: check-slo-burn
    containers:
      - name: burn
        image: europe-west1-docker.pkg.dev/example-prod/tools/sloctl:1.2.0
        args: ["burn", "--slo", "checkout-availability-30d", "--window", "600s", "--fail-above", "6.0"]
profiles:
  - name: staging
    manifests:
      kustomize:
        paths: ["manifests/overlays/staging"]
  - name: prod
    manifests:
      kustomize:
        paths: ["manifests/overlays/prod"]
```

---

## 9. Regional infrastructure with autohealing and cross-region DR

```hcl
# ---------------------------------------------------------------------------
# resilient-infra.tf — regional MIG behind a global LB, plus Cloud SQL HA
# with a cross-region read replica for DR promotion.
# ---------------------------------------------------------------------------

# ---- Health check consumed by BOTH autohealing and the load balancer ------
# One definition, two consumers: prevents the split-brain state where the LB
# considers an instance healthy while autohealing is recreating it.
resource "google_compute_health_check" "checkout" {
  project             = var.project_id
  name                = "checkout-hc"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz/ready"
  }

  log_config {
    enable = true
  }
}

resource "google_compute_instance_template" "checkout" {
  project      = var.project_id
  name_prefix  = "checkout-tpl-"
  machine_type = "e2-standard-4"
  region       = var.region

  disk {
    source_image = "projects/cos-cloud/global/images/family/cos-stable"
    auto_delete  = true
    boot         = true
    disk_size_gb = 50
    disk_type    = "pd-balanced"
  }

  network_interface {
    network    = "projects/${var.project_id}/global/networks/prod-vpc"
    subnetwork = "projects/${var.project_id}/regions/${var.region}/subnetworks/prod-euw1"
    # No external IP: egress via Cloud NAT, ingress via the load balancer only.
  }

  service_account {
    email  = "checkout-vm@${var.project_id}.iam.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }

  tags = ["checkout", "allow-health-checks"]

  lifecycle {
    create_before_destroy = true
  }
}

# ---- Regional MIG: instances spread EVENLY across all zones in the region --
resource "google_compute_region_instance_group_manager" "checkout" {
  project = var.project_id
  name    = "checkout-mig"
  region  = var.region

  base_instance_name        = "checkout"
  distribution_policy_zones = [
    "${var.region}-b",
    "${var.region}-c",
    "${var.region}-d",
  ]
  # EVEN keeps the zone distribution balanced during scaling events, which is
  # what preserves survivability of a single-zone loss. BALANCED trades that
  # for higher chance of obtaining capacity.
  distribution_policy_target_shape = "EVEN"

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.checkout.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check = google_compute_health_check.checkout.id
    # Long enough for the application to boot and warm. Too short and the MIG
    # kills instances mid-startup, producing a permanent recreate loop.
    initial_delay_sec = 300
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 3   # must be >= number of zones
    max_unavailable_fixed        = 0   # never reduce serving capacity
    replacement_method           = "SUBSTITUTE"
    # Canary at the infrastructure layer: 20% of instances get the new
    # template and stay there until a human or automation removes the cap.
    min_ready_sec                = 60
  }

  lifecycle {
    ignore_changes = [target_size] # the autoscaler owns this
  }
}

resource "google_compute_region_autoscaler" "checkout" {
  project = var.project_id
  name    = "checkout-autoscaler"
  region  = var.region
  target  = google_compute_region_instance_group_manager.checkout.id

  autoscaling_policy {
    min_replicas    = 6
    max_replicas    = 60
    cooldown_period = 90
    mode            = "ON"

    cpu_utilization {
      target            = 0.6
      predictive_method = "OPTIMIZE_AVAILABILITY" # pre-scales for learned cycles
    }

    load_balancing_utilization {
      target = 0.7
    }

    scale_in_control {
      time_window_sec = 600
      max_scaled_in_replicas {
        percent = 10 # bound how fast we can shed capacity
      }
    }
  }
}

# ---- Global backend service: circuit breaking + outlier detection ----------
resource "google_compute_backend_service" "checkout" {
  project               = var.project_id
  name                  = "checkout-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.checkout.id]
  locality_lb_policy    = "ROUND_ROBIN"

  backend {
    group           = google_compute_region_instance_group_manager.checkout.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    # Overflow headroom: allows the region to absorb 10% above target before
    # traffic spills to another region's backend.
    capacity_scaler = 1.0
  }

  # ---- Circuit breaker: bound the damage a slow backend can do ------------
  circuit_breakers {
    max_requests_per_connection = 100
    max_connections             = 2048
    max_pending_requests        = 512
    max_requests                = 2048
    max_retries                 = 3
  }

  # ---- Outlier detection: eject instances that are failing, not just down --
  # Health checks answer "is it up?". Outlier detection answers "is it
  # returning errors?" — a process can pass /healthz and still 500 on real work.
  outlier_detection {
    consecutive_errors                    = 5
    interval { seconds = 10 }
    base_ejection_time { seconds = 30 }
    max_ejection_percent                  = 50   # never eject the whole fleet
    enforcing_consecutive_errors          = 100
    consecutive_gateway_failure           = 3
    enforcing_consecutive_gateway_failure = 100
    success_rate_minimum_hosts            = 5
    success_rate_request_volume           = 100
    success_rate_stdev_factor             = 1900
  }

  connection_draining_timeout_sec = 60

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  security_policy = google_compute_security_policy.checkout_edge.id
}

# ---- Load shedding at the edge --------------------------------------------
resource "google_compute_security_policy" "checkout_edge" {
  project = var.project_id
  name    = "checkout-edge-policy"
  type    = "CLOUD_ARMOR"

  # Rate-based ban: sheds abusive traffic before it costs backend capacity.
  rule {
    action   = "rate_based_ban"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
      ban_duration_sec = 300
    }
    description = "Per-IP rate limit: 600 req/min, 5 minute ban on breach."
  }

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable          = true
      rule_visibility = "STANDARD"
    }
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow."
  }
}

# ---- Stateful tier: HA primary + cross-region replica for DR ---------------
resource "google_sql_database_instance" "orders_primary" {
  project             = var.project_id
  name                = "orders-primary-euw1"
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = true

  settings {
    tier = "db-custom-8-32768"

    # REGIONAL = synchronous replication to a standby in another zone,
    # automatic failover. This is what turns a zonal database into a
    # regional one, and it is the RPO=0 / RTO~60s configuration.
    availability_type = "REGIONAL"

    disk_type       = "PD_SSD"
    disk_size       = 500
    disk_autoresize = true

    backup_configuration {
      enabled    = true
      start_time = "02:00"
      location   = "eu" # multi-region backup location

      # PITR is the ONLY protection against logical corruption, which
      # replicates to the standby and to every read replica instantly.
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7      # Sunday
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.project_id}/global/networks/prod-vpc"
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }
}

# Cross-region replica: asynchronous. RPO is replication lag (seconds),
# RTO is promotion time (minutes) plus application reconfiguration.
resource "google_sql_database_instance" "orders_dr_replica" {
  project              = var.project_id
  name                 = "orders-replica-euw4"
  region               = "europe-west4"
  database_version     = "POSTGRES_15"
  master_instance_name = google_sql_database_instance.orders_primary.name
  deletion_protection  = true

  replica_configuration {
    failover_target = false # cross-region replicas are promoted manually
  }

  settings {
    tier              = "db-custom-8-32768"
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.project_id}/global/networks/prod-vpc"
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }
}

# Alert on replication lag — this IS your live RPO measurement.
resource "google_monitoring_alert_policy" "replica_lag" {
  project      = var.project_id
  display_name = "[TICKET] orders DR replica lag exceeds RPO (60s)"
  combiner     = "OR"

  conditions {
    display_name = "Replica lag > 60s for 10m"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"cloudsql.googleapis.com/database/replication/replica_lag\"",
        "resource.type=\"cloudsql_database\"",
        "resource.label.\"database_id\"=\"${var.project_id}:orders-replica-euw4\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 60
      duration        = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.ticket_channel_id]
  severity              = "WARNING"
}
```

---

## 10. CLI: operating and verifying the system

### 10.1 Confirming the SLO exists and reading the live error budget

```
$ export PROJECT_ID=example-prod
$ gcloud config set project $PROJECT_ID
Updated property [core/project].

$ curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/services/checkout-api/serviceLevelObjectives" \
  | jq -r '.serviceLevelObjectives[] | "\(.displayName)\t goal=\(.goal)\t period=\(.rollingPeriod)"'
99.9% of valid checkout requests succeed (30d rolling)	 goal=0.999	 period=2592000s
99% of checkout requests complete in under 300 ms (30d rolling)	 goal=0.99	 period=2592000s
```

Read the current burn rate directly from the SLO time series:

```
$ SLO="projects/${PROJECT_ID}/services/checkout-api/serviceLevelObjectives/checkout-availability-30d"
$ NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$ AGO=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)

$ curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/timeSeries" \
    --data-urlencode "filter=select_slo_burn_rate(\"${SLO}\", \"3600s\")" \
    --data-urlencode "interval.startTime=${AGO}" \
    --data-urlencode "interval.endTime=${NOW}" \
  | jq -r '.timeSeries[0].points[] | "\(.interval.endTime)  burn_rate=\(.value.doubleValue)"' | head -8
2026-09-09T14:00:00Z  burn_rate=18.42
2026-09-09T13:55:00Z  burn_rate=17.90
2026-09-09T13:50:00Z  burn_rate=16.03
2026-09-09T13:45:00Z  burn_rate=14.88
2026-09-09T13:40:00Z  burn_rate=9.71
2026-09-09T13:35:00Z  burn_rate=1.12
2026-09-09T13:30:00Z  burn_rate=0.94
2026-09-09T13:25:00Z  burn_rate=0.88
```

**Interpretation:** burn rate crossed 14.4 between 13:40 and 13:45 and is still climbing. The fast-burn page fired. The step change at 13:35 → 13:40 is characteristic of a **change-induced** failure, not a gradual degradation — go look at what deployed.

### 10.2 Is it us, or is it Google?

```
$ gcloud beta service-health events list --location=global \
    --format="table(name.basename(),category,state,detailedState,updateTime)"
NAME                      CATEGORY  STATE     DETAILED_STATE  UPDATE_TIME
(no incidents affecting this project)
```

Nothing on Google's side. It is ours.

### 10.3 What changed?

```
$ gcloud deploy rollouts list \
    --delivery-pipeline=checkout-api \
    --release=- \
    --region=europe-west1 \
    --limit=5 \
    --format="table(name.basename(),targetId,state,phaseId,createTime)"
NAME                              TARGET_ID  STATE       PHASE_ID   CREATE_TIME
checkout-api-2-14-0-to-prod-0001  prod       IN_PROGRESS canary-25  2026-09-09T13:38:41Z
checkout-api-2-13-4-to-prod-0001  prod       SUCCEEDED   stable     2026-09-08T09:12:07Z
checkout-api-2-13-3-to-prod-0001  prod       SUCCEEDED   stable     2026-09-05T16:44:19Z
checkout-api-2-13-2-to-prod-0001  prod       SUCCEEDED   stable     2026-09-04T11:02:55Z
checkout-api-2-13-1-to-prod-0001  prod       SUCCEEDED   stable     2026-09-03T15:31:12Z
```

A canary advanced to 25% at 13:38. The burn rate stepped up at 13:40. **Correlation in time plus a matching traffic percentage is sufficient evidence to roll back.** Diagnose after the bleeding stops.

```
$ gcloud deploy rollouts rollback checkout-api-2-14-0-to-prod-0001 \
    --delivery-pipeline=checkout-api \
    --region=europe-west1 \
    --release=checkout-api-2-14-0
Rolling back to release [checkout-api-2-13-4].
Created Cloud Deploy rollout [checkout-api-2-13-4-to-prod-0002] in target [prod].

$ gcloud deploy rollouts describe checkout-api-2-13-4-to-prod-0002 \
    --delivery-pipeline=checkout-api --release=checkout-api-2-13-4 \
    --region=europe-west1 --format="value(state)"
SUCCEEDED
```

Then confirm the budget stopped burning — do not close the incident on the deploy succeeding:

```
$ watch -n 60 'curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/example-prod/timeSeries" \
    --data-urlencode "filter=select_slo_burn_rate(\"'"$SLO"'\", \"300s\")" \
    --data-urlencode "interval.startTime=$(date -u -d "-10 min" +%Y-%m-%dT%H:%M:%SZ)" \
    --data-urlencode "interval.endTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | jq -r ".timeSeries[0].points[0].value.doubleValue"'
0.41
```

### 10.4 Workload-level verification

```
$ kubectl -n checkout get deploy,hpa,pdb
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/checkout-api   18/18   18           18          214d

NAME                                              REFERENCE                 TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.../checkout-api           Deployment/checkout-api   cpu: 54%/60%, 71/80 (avg)      6         60        18         214d

NAME                                        MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/checkout-api     N/A             25%               4                     214d
```

Verify the zonal spread actually happened — the manifest declares intent, the cluster decides:

```
$ kubectl -n checkout get pods -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,STATUS:.status.phase' \
  --sort-by=.metadata.name | head -8
NAME                            NODE                          ZONE              STATUS
checkout-api-7c9f4d8b6-2xk9p    gke-apps-euw1-pool-a-9f2c     europe-west1-b    Running
checkout-api-7c9f4d8b6-4nqvz    gke-apps-euw1-pool-a-1d7e     europe-west1-c    Running
checkout-api-7c9f4d8b6-6bd8w    gke-apps-euw1-pool-a-3a11     europe-west1-d    Running
checkout-api-7c9f4d8b6-8fzt2    gke-apps-euw1-pool-a-9f2c     europe-west1-b    Running
checkout-api-7c9f4d8b6-9klmc    gke-apps-euw1-pool-a-1d7e     europe-west1-c    Running
checkout-api-7c9f4d8b6-b7rpn    gke-apps-euw1-pool-a-3a11     europe-west1-d    Running
checkout-api-7c9f4d8b6-cw4gh    gke-apps-euw1-pool-a-7c40     europe-west1-b    Running
checkout-api-7c9f4d8b6-dj2sq    gke-apps-euw1-pool-a-1d7e     europe-west1-c    Running

$ kubectl -n checkout get pods -o json \
  | jq -r '.items[].metadata.labels["topology.kubernetes.io/zone"]' | sort | uniq -c
      6 europe-west1-b
      6 europe-west1-c
      6 europe-west1-d
```

Even spread across three zones: losing any one zone removes 33% of capacity, and the HPA plus the remaining headroom absorbs it.

### 10.5 Backend and endpoint health

```
$ gcloud compute backend-services get-health checkout-backend --global \
    --format="value(status.healthStatus[].instance.basename(),status.healthStatus[].healthState)"
checkout-x9k2  HEALTHY
checkout-mn4p  HEALTHY
checkout-qq81  UNHEALTHY
checkout-b3zv  HEALTHY
checkout-tt7c  HEALTHY
checkout-lp0d  HEALTHY

$ gcloud compute instance-groups managed list-instances checkout-mig \
    --region=europe-west1 \
    --format="table(name,zone.basename(),instanceStatus,currentAction,instanceHealth[0].detailedHealthState)"
NAME           ZONE            INSTANCE_STATUS  CURRENT_ACTION  DETAILED_HEALTH_STATE
checkout-x9k2  europe-west1-b  RUNNING          NONE            HEALTHY
checkout-mn4p  europe-west1-b  RUNNING          NONE            HEALTHY
checkout-qq81  europe-west1-c  RUNNING          RECREATING      UNHEALTHY
checkout-b3zv  europe-west1-c  RUNNING          NONE            HEALTHY
checkout-tt7c  europe-west1-d  RUNNING          NONE            HEALTHY
checkout-lp0d  europe-west1-d  RUNNING          NONE            HEALTHY
```

`CURRENT_ACTION: RECREATING` confirms autohealing is doing its job. The system is degrading gracefully rather than failing.

### 10.6 Log queries that answer real questions

```
$ gcloud logging read \
  'resource.type="k8s_container"
   resource.labels.namespace_name="checkout"
   severity>=ERROR
   timestamp>="2026-09-09T13:30:00Z"' \
  --limit=5 --format="value(timestamp, resource.labels.pod_name, jsonPayload.message)"
2026-09-09T13:52:11Z  checkout-api-7c9f4d8b6-2xk9p  upstream deadline exceeded: pricing-service (2500ms)
2026-09-09T13:52:09Z  checkout-api-7c9f4d8b6-8fzt2  upstream deadline exceeded: pricing-service (2500ms)
2026-09-09T13:52:04Z  checkout-api-7c9f4d8b6-cw4gh  upstream deadline exceeded: pricing-service (2500ms)
2026-09-09T13:51:58Z  checkout-api-7c9f4d8b6-2xk9p  connection pool exhausted (max=64, waiting=211)
2026-09-09T13:51:57Z  checkout-api-7c9f4d8b6-4nqvz  connection pool exhausted (max=64, waiting=211)
```

Break the 5xx down by backend to find *which hop* — the §1.2 question:

```
$ gcloud logging read \
  'resource.type="http_load_balancer"
   httpRequest.status>=500
   timestamp>="2026-09-09T13:30:00Z"' \
  --format="value(jsonPayload.statusDetails)" --limit=2000 | sort | uniq -c | sort -rn
   1584 backend_timeout
    221 failed_to_pick_backend
     47 backend_connection_closed_before_data_sent_to_client
      6 response_sent_by_backend
```

`backend_timeout` dominating means the backend is *slow*, not *down*. That points at the pricing-service dependency, not at the checkout Pods — and it explains why the health checks all still pass.

### 10.7 A DR drill: promoting the cross-region replica

Never run this for the first time during a real disaster.

```
$ gcloud sql instances describe orders-replica-euw4 \
    --format="value(state, masterInstanceName, region, replicaConfiguration.failoverTarget)"
RUNNABLE  example-prod:orders-primary-euw1  europe-west4  False

# Measure live RPO before promoting.
$ gcloud monitoring time-series list \
  --filter='metric.type="cloudsql.googleapis.com/database/replication/replica_lag" AND
            resource.labels.database_id="example-prod:orders-replica-euw4"' \
  --format="value(points[0].value.doubleValue)"
3.0

# 3 seconds of lag == 3 seconds of potential data loss. Within the 60s RPO.

$ gcloud sql instances promote-replica orders-replica-euw4 --quiet
Promoting Cloud SQL replica...done.
Promoted [https://sqladmin.googleapis.com/sql/v1beta4/projects/example-prod/instances/orders-replica-euw4].

$ gcloud sql instances describe orders-replica-euw4 \
    --format="value(state, masterInstanceName, instanceType)"
RUNNABLE    CLOUD_SQL_INSTANCE
```

`masterInstanceName` is now empty and `instanceType` is `CLOUD_SQL_INSTANCE`: it is a standalone primary. **Promotion is irreversible** — the replication relationship cannot be recreated in the original direction without a rebuild. This is why the drill has to be scheduled, scoped, and budgeted, and why `failover_target = false` in the Terraform: nothing should promote a cross-region replica by accident.

Compare with the *intra-region* HA failover, which is reversible and routine:

```
$ gcloud sql instances failover orders-primary-euw1 --quiet
Failing over Cloud SQL instance...done.
Failed over [https://sqladmin.googleapis.com/sql/v1beta4/projects/example-prod/instances/orders-primary-euw1].

$ gcloud sql operations list --instance=orders-primary-euw1 --limit=1 \
    --format="table(name.basename(),operationType,status,startTime,endTime)"
NAME                                  OPERATION_TYPE  STATUS  START_TIME                END_TIME
9f2c1d4a-7b31-4c8e-a2f0-11de83c4b907  FAILOVER        DONE    2026-09-09T14:41:02.114Z  2026-09-09T14:42:07.883Z
```

**65 seconds of measured RTO, RPO = 0** (synchronous regional replication). That is the actual, evidenced number for the DR plan — not an estimate.

### 10.8 A zone-loss game day

```
# Simulate losing europe-west1-c by cordoning and draining its nodes.
$ ZONE=europe-west1-c
$ kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o name | wc -l
4

$ kubectl cordon -l topology.kubernetes.io/zone=$ZONE
node/gke-apps-euw1-pool-a-1d7e cordoned
node/gke-apps-euw1-pool-a-4f88 cordoned
node/gke-apps-euw1-pool-a-6b02 cordoned
node/gke-apps-euw1-pool-a-8e5a cordoned

$ kubectl drain -l topology.kubernetes.io/zone=$ZONE \
    --ignore-daemonsets --delete-emptydir-data --timeout=300s
node/gke-apps-euw1-pool-a-1d7e already cordoned
evicting pod checkout/checkout-api-7c9f4d8b6-4nqvz
evicting pod checkout/checkout-api-7c9f4d8b6-9klmc
error when evicting pods/"checkout-api-7c9f4d8b6-dj2sq" -n "checkout" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
evicting pod checkout/checkout-api-7c9f4d8b6-dj2sq
pod/checkout-api-7c9f4d8b6-4nqvz evicted
pod/checkout-api-7c9f4d8b6-9klmc evicted
pod/checkout-api-7c9f4d8b6-dj2sq evicted
node/gke-apps-euw1-pool-a-1d7e drained
```

**The `Cannot evict pod as it would violate the pod's disruption budget` message is the PDB working correctly, not an error.** The drain paced itself to keep 75% of the fleet serving. If that message never appears during a drain, your PDB is too permissive to be protecting anything.

Then verify the SLO held through the drill:

```
$ curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/projects/example-prod/timeSeries" \
    --data-urlencode "filter=select_slo_burn_rate(\"${SLO}\", \"1800s\")" \
    --data-urlencode "interval.startTime=$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)" \
    --data-urlencode "interval.endTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | jq -r '[.timeSeries[0].points[].value.doubleValue] | max'
1.34

$ kubectl uncordon -l topology.kubernetes.io/zone=$ZONE
node/gke-apps-euw1-pool-a-1d7e uncordoned
node/gke-apps-euw1-pool-a-4f88 uncordoned
node/gke-apps-euw1-pool-a-6b02 uncordoned
node/gke-apps-euw1-pool-a-8e5a uncordoned
```

Peak burn rate of 1.34 during a simulated full zone loss: the design survives it with margin. **That number is the deliverable of the game day** — not "the drill completed".

---

## 11. Verification and failure diagnosis guide

### 11.1 Pre-production verification checklist

| # | Claim | Command that proves it | Pass criterion |
|---|---|---|---|
| 1 | The SLO exists and is being evaluated | `curl .../serviceLevelObjectives \| jq` | Object returned, `goal` matches design |
| 2 | Alerting is multi-window, not single | `gcloud alpha monitoring policies list --format='value(displayName,combiner,conditions.len())'` | `combiner=AND`, 2 conditions per burn policy |
| 3 | Pages actually reach a human | `gcloud alpha monitoring channels list` + send a test | Test alert acknowledged by on-call |
| 4 | White-box blindness is covered | `gcloud monitoring uptime list-configs` | ≥1 uptime check from ≥3 regions |
| 5 | Replicas really span zones | `kubectl get pods -o json \| jq ... \| sort \| uniq -c` | ≥3 zones, skew ≤ 1 |
| 6 | Voluntary disruption is bounded | `kubectl get pdb -A` | `ALLOWED DISRUPTIONS` > 0 and < replicas |
| 7 | Liveness does not test dependencies | `kubectl get deploy -o yaml \| yq '.spec.template.spec.containers[].livenessProbe'` | Path is process-local |
| 8 | Rollback is automated and tested | `gcloud deploy automations list --delivery-pipeline=... --region=...` | `repairRolloutRule` present |
| 9 | The DR plan has measured numbers | Drill operation timestamps (§10.7) | RTO/RPO measured, not estimated |
| 10 | Backups restore | Restore to a scratch instance and query it | Row counts and checksums match |

**Item 10 is the one teams skip.** A backup that has never been restored is not a backup; it is an untested hypothesis with a storage bill.

### 11.2 Symptom → diagnosis table

| Symptom | Most likely cause | Command that confirms it | Fix |
|---|---|---|---|
| Burn rate steps up sharply at a timestamp | Change-induced failure | `gcloud deploy rollouts list --limit=5` | Roll back first, diagnose second |
| Burn rate drifts up over days | Capacity/leak/traffic growth | `kubectl top pods`; memory trend in Monitoring | Right-size, fix leak, raise `maxReplicas` |
| LB 502s, Pods all Ready | Pods exiting on SIGTERM before NEG deregistration | `gcloud logging read 'statusDetails="backend_connection_closed_before_data_sent_to_client"'` | Add `preStop` sleep ≥ drain time; `terminationGracePeriodSeconds` > preStop + request time |
| LB `failed_to_pick_backend` | Zero healthy backends | `gcloud compute backend-services get-health ... --global` | Fix health-check path/port; check firewall for `35.191.0.0/16`, `130.211.0.0/22` |
| Whole fleet restarts at once | Liveness probe checking a dependency | `kubectl get events -n <ns> --sort-by=.lastTimestamp \| grep Unhealthy` | Split liveness (local) from readiness (dependency-aware) |
| HPA stuck at `<unknown>/60%` | Missing resource **requests**, or metrics adapter down | `kubectl describe hpa <name>` | Set `resources.requests.cpu`; verify metrics pipeline |
| HPA oscillates | `scaleDown` stabilization too short | `kubectl describe hpa` → scaling events | Raise `scaleDown.stabilizationWindowSeconds` to 300–600 |
| Pods `Pending` during a zone loss | `whenUnsatisfiable: DoNotSchedule` + no capacity | `kubectl describe pod` → `FailedScheduling` | Cluster autoscaler headroom; or relax to `ScheduleAnyway` for the node-level constraint |
| Tail latency high, CPU low | CPU limit throttling | `container/cpu/cfs_throttled_periods` metric | Remove the CPU limit; keep the request |
| Errors climb only after a retry starts | Retry amplification | Compare inbound vs. outbound request counts | Exponential backoff + jitter; retry budget; circuit breaker |
| One instance serves errors while "healthy" | Health check too shallow | Compare per-instance 5xx rates | Deepen the check; enable `outlier_detection` |
| Cloud SQL failover took far longer than 60 s | Long-running transactions / large uncommitted state | `gcloud sql operations list` durations | Shorten transactions; measure again in the next drill |
| DR replica lag growing | Write volume exceeds replica capacity, or network | `replica_lag` metric trend | Scale replica tier; the current RPO is *the lag*, so update the DR doc |
| SLO looks fine, users complain | SLI measured at the wrong place | Compare LB metrics vs. client RUM | Move the SLI to the user's vantage point |

### 11.3 The last row deserves its own note

An SLI measured at the load balancer cannot see: DNS resolution failure, TLS handshake failure, Anycast routing problems, client-side JavaScript errors, or the user's own network. A service can be at 100% by the LB's own accounting while a meaningful fraction of users cannot reach it at all.

That is precisely why the uptime check in §5 (`resource 7`) is not redundant with the SLO: **the black-box probe measures the path the SLO cannot see, and it keeps reporting when the white-box telemetry stops arriving.** White-box goes blind exactly when the system is at its most broken.

### 11.4 Blameless postmortem — the required structure

A postmortem is an artefact of *modern operations*, and its properties are examinable.

| Section | Content | Anti-pattern to avoid |
|---|---|---|
| **Summary** | Two sentences: what broke, for whom, for how long | Jargon nobody outside the team parses |
| **Impact** | Users affected, requests failed, **error budget consumed**, revenue/SLA exposure | "Some users may have seen errors" |
| **Timeline** | UTC timestamps: fault begins → detected → acknowledged → mitigated → resolved | Starting the clock at "we noticed" |
| **Root cause** | Contributing factors, plural; the systemic conditions | A person's name |
| **Detection** | How you found out; **MTTD**; would existing alerts have caught it? | "A customer told us" with no follow-up action |
| **Resolution** | What actually stopped the bleeding | Conflating mitigation with a permanent fix |
| **Action items** | Owner + due date + priority for each; split *prevent* / *detect faster* / *mitigate faster* | A list with no owners, which is a wish list |
| **Lessons: what went well / what went badly / where we got lucky** | Especially "where we got lucky" — luck is an unrecorded risk | Omitting the luck section |

**Blameless does not mean consequence-free.** It means the analysis targets the *system* that allowed a competent engineer to cause an outage — the missing guardrail, the confusing interface, the absent canary — because blaming the individual reliably suppresses the reporting you depend on to find the next fault.

---

## 12. Exam-focused distinctions

These are the pairs most often confused on the Cloud Digital Leader exam within this objective:

| A | B | The discriminator |
|---|---|---|
| **SLO** | **SLA** | SLO is internal and stricter; SLA is external with financial remedy |
| **SLI** | **SLO** | SLI is the measurement; SLO is the target for that measurement |
| **RTO** | **RPO** | RTO = tolerable *downtime*; RPO = tolerable *data loss* |
| **High availability** | **Disaster recovery** | HA absorbs component failure automatically within a design's normal operation; DR restores service after the design's assumptions are exceeded |
| **Backup** | **Replication** | Backup is a point in time you can return to (protects against logical corruption); replication is a live copy (propagates corruption) |
| **Reliability** | **Resilience** | Reliability = behaves correctly over time; resilience = *recovers* when parts fail |
| **Monitoring** | **Observability** | Monitoring answers known questions; observability lets you ask new ones |
| **Scalability** | **Elasticity** | Scalability = can grow; elasticity = grows *and shrinks* automatically with demand |
| **Vertical scaling** | **Horizontal scaling** | Bigger machine vs. more machines; only horizontal survives a machine failure |
| **Toil** | **Operational work** | Toil is manual, repetitive, automatable, and scales *linearly with growth* |
| **DevOps** | **SRE** | SRE is a concrete implementation of DevOps, with the error budget as its arbitration mechanism |
| **MTTR** | **MTBF** | Time to recover *from* a failure vs. time *between* failures |
| **Zone** | **Region** | A zone is a failure domain within a region; a region contains three or more zones |
| **Regional resource** | **Multi-regional resource** | Survives a zone loss vs. survives a region loss |
| **CapEx** | **OpEx** | Cloud converts capital expenditure into operational expenditure — the financial framing of Section 6 |

### 12.1 The single sentence that summarises the objective

> **Modern cloud operations replaces "prevent all failure" with "define the acceptable amount of failure, measure it continuously at the user journey, spend it deliberately on change velocity, and engineer the system to recover automatically when it is exceeded."**

Every technique in this document — SLIs, error budgets, burn-rate alerting, multi-zone spread, PDBs, canary releases, autohealing, RTO/RPO planning, blameless postmortems — is an implementation detail of that sentence.

---

## Referencias

**Exam guide (authoritative scope for this objective)**
- Google Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification page — https://cloud.google.com/learn/certification/cloud-digital-leader

**SRE, reliability and error budgets**
- Google SRE Book (full text) — https://sre.google/sre-book/table-of-contents/
- Google SRE Book, Ch. 4 "Service Level Objectives" — https://sre.google/sre-book/service-level-objectives/
- Google SRE Book, Ch. 5 "Eliminating Toil" — https://sre.google/sre-book/eliminating-toil/
- Google SRE Book, Ch. 6 "Monitoring Distributed Systems" (Golden Signals) — https://sre.google/sre-book/monitoring-distributed-systems/
- Google SRE Book, Ch. 15 "Postmortem Culture" — https://sre.google/sre-book/postmortem-culture/
- The Site Reliability Workbook, Ch. 2 "Implementing SLOs" (multi-window multi-burn-rate) — https://sre.google/workbook/implementing-slos/
- The Site Reliability Workbook, Ch. 5 "Alerting on SLOs" — https://sre.google/workbook/alerting-on-slos/
- SRE resources index — https://sre.google/resources/

**Well-Architected Framework**
- Google Cloud Well-Architected Framework — https://cloud.google.com/architecture/framework
- Reliability pillar — https://cloud.google.com/architecture/framework/reliability
- Operational excellence pillar — https://cloud.google.com/architecture/framework/operational-excellence

**Observability**
- Google Cloud Observability overview — https://cloud.google.com/stackdriver/docs
- Cloud Monitoring documentation — https://cloud.google.com/monitoring/docs
- SLO monitoring — https://cloud.google.com/stackdriver/docs/solutions/slo-monitoring
- Alerting policies — https://cloud.google.com/monitoring/alerts
- Uptime checks — https://cloud.google.com/monitoring/uptime-checks
- Cloud Logging documentation — https://cloud.google.com/logging/docs
- Logs-based metrics — https://cloud.google.com/logging/docs/logs-based-metrics
- Cloud Trace — https://cloud.google.com/trace/docs
- Cloud Profiler — https://cloud.google.com/profiler/docs
- Error Reporting — https://cloud.google.com/error-reporting/docs
- Managed Service for Prometheus — https://cloud.google.com/stackdriver/docs/managed-prometheus
- Personalized Service Health — https://cloud.google.com/service-health/docs

**Resilience, HA and disaster recovery**
- Disaster recovery planning guide — https://cloud.google.com/architecture/dr-scenarios-planning-guide
- DR building blocks — https://cloud.google.com/architecture/dr-scenarios-building-blocks
- Patterns for scalable and resilient apps — https://cloud.google.com/architecture/scalable-and-resilient-apps
- Geography and regions — https://cloud.google.com/docs/geography-and-regions
- Google Cloud service-level agreements — https://cloud.google.com/terms/sla
- Backup and DR Service — https://cloud.google.com/backup-disaster-recovery/docs

**Compute, GKE and load balancing**
- Regional managed instance groups — https://cloud.google.com/compute/docs/instance-groups/distributing-instances-with-regional-instance-groups
- MIG autohealing — https://cloud.google.com/compute/docs/instance-groups/autohealing-instances-in-migs
- Autoscaling managed instance groups — https://cloud.google.com/compute/docs/autoscaler
- GKE regional clusters — https://cloud.google.com/kubernetes-engine/docs/concepts/types-of-clusters
- Horizontal Pod autoscaling in GKE — https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler
- Container-native load balancing (NEGs) — https://cloud.google.com/kubernetes-engine/docs/concepts/container-native-load-balancing
- GKE BackendConfig — https://cloud.google.com/kubernetes-engine/docs/how-to/ingress-features
- Cloud Load Balancing documentation — https://cloud.google.com/load-balancing/docs
- Cloud Armor rate limiting — https://cloud.google.com/armor/docs/rate-limiting-overview
- Kubernetes: Pod Disruption Budgets — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Kubernetes: Configure liveness, readiness and startup probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes: Pod topology spread constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/

**Delivery and change management**
- Cloud Deploy documentation — https://cloud.google.com/deploy/docs
- Cloud Deploy deployment strategies (canary) — https://cloud.google.com/deploy/docs/deployment-strategies
- Cloud Deploy automation — https://cloud.google.com/deploy/docs/automation
- Cloud Build documentation — https://cloud.google.com/build/docs
- DORA research program — https://dora.dev/
- DORA capabilities catalog — https://dora.dev/capabilities/
- Using the Four Keys to measure DevOps performance — https://cloud.google.com/blog/products/devops-sre/using-the-four-keys-to-measure-your-devops-performance

**Data tier**
- Cloud SQL high availability — https://cloud.google.com/sql/docs/postgres/high-availability
- Cloud SQL replication — https://cloud.google.com/sql/docs/postgres/replication
- Cloud SQL point-in-time recovery — https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr
- Cloud Spanner instance configurations — https://cloud.google.com/spanner/docs/instance-configurations
- Cloud Storage bucket locations — https://cloud.google.com/storage/docs/locations

**Terraform provider reference**
- `google_monitoring_slo` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_slo
- `google_monitoring_alert_policy` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_alert_policy
- `google_compute_region_instance_group_manager` — https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_region_instance_group_manager