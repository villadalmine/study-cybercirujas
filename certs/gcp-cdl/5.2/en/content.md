# 5.2 — The Business Value of Making Google Part of Your Security Team

### Defense in Depth and the Multilayered Approach to Cloud Security

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12)
**Domain:** 5 — Trust and Security
**Exam weight:** 9.0 (highest-weighted objective in the domain)
**Target profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation: The Production Architectural Problem

### 1.1 The staffing arithmetic that no CISO can win

Consider a real production scenario. A mid-size financial services organization runs 340 microservices across 12 Kubernetes clusters, 2 PB of object storage, 90 Cloud SQL instances, and a data warehouse serving 1,200 analysts. Its security org has 14 people: 4 on detection/response, 3 on identity, 3 on compliance/audit, 2 on appsec, 2 on infrastructure hardening.

Now enumerate what "defending" that estate actually requires, 24/7/365:

| Security function | Realistic FTE to run in-house at 24/7 coverage | What "good" looks like |
|---|---|---|
| SOC tier-1/2/3 with follow-the-sun | 12–18 | MTTD < 1 h, MTTR < 4 h |
| Threat intelligence production | 6–10 | Original IOC/TTP research, not a feed subscription |
| Hardware root-of-trust and firmware supply chain | 5+ | Custom silicon, signed firmware, verified boot |
| DDoS absorption at L3/L4/L7 | 4+ | Multi-Tbps scrubbing capacity, always-on |
| Physical datacenter security | 20+ per site | Biometrics, laser intrusion detection, disk destruction |
| Cryptographic key infrastructure (FIPS 140-2/3 L3) | 4+ | HSM fleet, rotation, quorum, attestation |
| Continuous compliance evidence (SOC 2, ISO 27001, PCI DSS, FedRAMP) | 6+ | Continuous, not annual point-in-time |
| Vulnerability research on the OS/hypervisor you run | 8+ | Finding 0-days before adversaries do |
| **Total** | **~65–90 FTE** | — |

The organization has 14. This is not a budget problem that a 20% headcount increase solves; it is a **structural mismatch between the surface area of a modern cloud estate and the labor available to defend it**. Every organization running its own security stack is independently re-solving problems that are (a) identical across all organizations and (b) subject to enormous economies of scale.

**The architectural insight of this objective:** Google Cloud is not a hosting provider you must then secure. It is a security organization — thousands of full-time security engineers, custom silicon, a global network, and the threat intelligence arm of Mandiant and the Google Threat Intelligence Group — whose output is delivered as **inherited controls**. You do not "buy security products from Google." You **absorb Google's security engineering as a permanent, non-headcount member of your team**.

### 1.2 Why the perimeter model failed — the concrete failure mode

The classic architecture is a hard shell around a soft interior:

```
Internet ──▶ [Firewall] ──▶ [DMZ] ──▶ [Corp VPN] ──▶ ██ FLAT TRUSTED NETWORK ██
                                                        ├─ HR database
                                                        ├─ Source control
                                                        ├─ Prod Kubernetes API
                                                        └─ Finance data warehouse
```

The implicit assertion is: **network location is a proxy for trust**. That assertion has three production failure modes that every SRE has seen:

1. **Lateral movement.** One phished laptop on the VPN inherits the full trust of the network. In post-incident forensics the attacker's dwell time is spent almost entirely *inside* the perimeter, moving east-west, unobserved, because east-west traffic was never authenticated or logged.
2. **The perimeter has no edge anymore.** With SaaS, contractors, mobile, and multi-cloud, there is no single choke point to place the firewall in front of. The "inside" is now a set of API endpoints on the public internet.
3. **Credential exfiltration bypasses the network entirely.** A leaked service account key used from an attacker-controlled host reaches `storage.googleapis.com` over the public API. No firewall rule in your VPC is on that path.

Failure mode #3 is the one architects most often miss. A VPC firewall protects *your network*; it does not protect *the Google API surface* your data lives behind. That gap is precisely what VPC Service Controls exists to close (Section 4.3).

### 1.3 Shared responsibility → shared fate

The baseline mental model is the **shared responsibility model**: the provider secures the cloud, the customer secures what they put in it. The division shifts with the service model:

| Layer | On-prem | IaaS (GCE) | PaaS (GKE Autopilot, Cloud Run) | SaaS (Workspace) |
|---|---|---|---|---|
| Content / data classification | Customer | Customer | Customer | Customer |
| Access policies (IAM) | Customer | Customer | Customer | Customer |
| Identity (users, MFA) | Customer | Customer | Customer | Customer |
| Web application security | Customer | Customer | Customer | **Google** |
| Deployment / container config | Customer | Customer | Shared | **Google** |
| Guest OS, patching, hardening | Customer | Customer | **Google** | **Google** |
| Network segmentation | Customer | Shared | Shared | **Google** |
| Hypervisor / host | Customer | **Google** | **Google** | **Google** |
| Kernel, firmware, boot integrity | Customer | **Google** | **Google** | **Google** |
| Hardware, custom silicon | Customer | **Google** | **Google** | **Google** |
| Physical datacenter, media destruction | Customer | **Google** | **Google** | **Google** |
| Global network, DDoS backbone | Customer | **Google** | **Google** | **Google** |

Google's stated evolution beyond this is **shared fate**: instead of drawing a line and handing you the harder half, Google engages *before* deployment (secure blueprints, landing zones), *during* (Security Command Center, Assured Workloads, Policy Intelligence), and *after* (Risk Protection Program — cyber insurance priced on your actual measured posture, via the Risk Manager report). The business framing that appears on the exam:

> **Shared responsibility** tells you *where your job starts*. **Shared fate** means Google has skin in the game for whether you succeed at it.

**Business-value translation (exam-critical):**

| Technical mechanism | Business value statement |
|---|---|
| Inherited infrastructure controls | Capex/opex avoidance of ~65–90 security FTE and datacenter security program |
| Continuous compliance artifacts | Audit cycles shrink from months to weeks; enter regulated markets faster |
| Global DDoS absorption at the edge | Revenue protection; availability SLO defended by capacity you could never buy |
| Encryption at rest/in transit by default | Data-breach blast radius reduced with **zero** engineering effort |
| Mandiant + Google Threat Intelligence | Frontline incident-response expertise on retainer, not on payroll |
| Risk Protection Program | Quantified, insurable risk — turns a variance problem into a premium line item |

---

## 2. The Layers: What Google Actually Runs Underneath You

Defense in depth means *no single control failing is fatal*. Google's stack has six layers; enumerate them, because the exam tests recognition of which layer a given control lives in.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 6. OPERATIONAL / DETECTION                                           │
│    Security Command Center · Google SecOps (Chronicle) · Mandiant    │
│    Access Transparency · Access Approval · Cloud Audit Logs          │
├──────────────────────────────────────────────────────────────────────┤
│ 5. IDENTITY & ACCESS  (the real perimeter)                           │
│    Cloud Identity · IAM · BeyondCorp Enterprise · IAP                │
│    Context-Aware Access · Titan Security Keys · Workload Identity    │
├──────────────────────────────────────────────────────────────────────┤
│ 4. DATA                                                              │
│    Encryption at rest (default AES-256) · CMEK · CSEK · Cloud EKM    │
│    Key Access Justifications · Sensitive Data Protection (DLP)       │
│    Confidential Computing (in-use encryption)                        │
├──────────────────────────────────────────────────────────────────────┤
│ 3. SERVICE / API PERIMETER                                           │
│    VPC Service Controls · Org Policy · Private Service Connect       │
│    Binary Authorization · Software Delivery Shield / SLSA            │
├──────────────────────────────────────────────────────────────────────┤
│ 2. NETWORK                                                           │
│    Global private backbone · Cloud Armor (L3–L7, WAF) · Cloud NGFW   │
│    ALTS mutual auth · Encryption in transit at the WAN edge          │
├──────────────────────────────────────────────────────────────────────┤
│ 1. HARDWARE & BOOT                                                   │
│    Titan security chip (hardware root of trust) · custom server      │
│    design · Verified/Shielded boot · datacenter physical security    │
│    · disk sanitization and destruction chain of custody              │
└──────────────────────────────────────────────────────────────────────┘
        ▲ Layers 1–2 are 100% inherited. You cannot misconfigure them.
```

### 2.1 Layer 1 — Hardware root of trust (fully inherited)

**Titan** is a purpose-built security microcontroller Google designs and places on servers and peripherals. It establishes a hardware root of trust: it verifies the low-level firmware and BIOS *before* the CPU is permitted to execute, and it provides a cryptographic machine identity. This defeats a class of attack — persistent firmware implants — that is essentially undetectable and unremediable from software.

The customer-facing analogue you *can* configure is **Shielded VM** (vTPM, Secure Boot, integrity monitoring) and **Confidential VM** (memory encrypted by the CPU with a per-VM key the hypervisor cannot read).

**Business value:** you inherit a supply-chain integrity program — custom silicon, signed firmware, hardware attestation — whose R&D cost is amortized across the entire planet. Building the equivalent is not merely expensive; for most organizations it is impossible at any price.

### 2.2 Layer 2 — The network you didn't have to build

Google operates one of the largest private backbones on Earth, with an edge presence in 200+ countries and territories. Two consequences matter architecturally:

- **DDoS is absorbed as a property of the network, not as a product you attach.** Traffic to a Google Cloud global load balancer is terminated at the nearest edge PoP. Volumetric L3/L4 floods are dissipated across global capacity before they are ever concentrated on your backend. Google's published mitigations include attacks in the multi-Tbps and hundreds-of-millions-of-RPS range.
- **Traffic between Google datacenters is authenticated and encrypted by default** using **ALTS** (Application Layer Transport Security), Google's mutual-authentication protocol, in addition to encryption of WAN links at the physical/logical layer.

> **SRE note on failure isolation:** a global external Application Load Balancer with Cloud Armor means the *first* device to see attacker traffic is Google's, not yours. Your autoscaler never sees the flood, so it never scales into a bill-driven denial-of-wallet event. Cloud Armor's **Adaptive Protection** uses ML to baseline your normal traffic and propose rules against L7 attacks that are below volumetric thresholds but still capable of exhausting your backends.

### 2.3 Layers 3–6

Covered in depth in Sections 3 and 4, since these are the layers you configure.

---

## 3. Technical Comparatives and Trade-off Tables

### 3.1 Encryption at rest: five key-management postures

All Google Cloud data at rest is encrypted by default — chunked, each chunk with its own data encryption key (DEK), DEKs wrapped by key encryption keys (KEKs) in Google's internal KMS. The design decision is *who holds and controls the KEK*.

| Posture | Where the KEK lives | Who can technically decrypt | Ops burden | Latency/availability risk | When to choose it |
|---|---|---|---|---|---|
| **Google-managed (default)** | Google internal KMS | Google systems | **Zero** | None | Default. Correct for the large majority of workloads. Do not add complexity without a driver. |
| **CMEK** (Cloud KMS, software) | Cloud KMS, your project | Google systems, gated on your key's IAM + enable state | Low: rotation, IAM, key ring topology | Low — key is regional; a disabled key breaks reads | Regulatory need to *demonstrate* key control, revoke access, and prove rotation cadence |
| **CMEK on Cloud HSM** | FIPS 140-2 Level 3 HSM | Same, key never leaves HSM | Low–medium | Low | Contractual/regulatory HSM mandate |
| **CSEK** (customer-supplied) | **You**, off-platform | Only you (key passed per API call, kept in memory) | **High** — you build key distribution | High: lose the key, lose the data, permanently | Narrow. Limited service support (GCE, GCS). Prefer CMEK/EKM. |
| **Cloud EKM** (external key manager) | **Third-party KMS outside Google** (e.g. partner HSM/KMS) | Google can only decrypt while your external system grants it | **Highest** | **Highest** — external KMS outage = data unreadable; adds network hop | True key sovereignty; "hold the keys outside the cloud" mandates |

**Cloud EKM + Key Access Justifications (KAJ)** is the sharpest control in this table. Every request to unwrap a key carries a machine-readable *justification code* (e.g. `CUSTOMER_INITIATED_ACCESS`, `GOOGLE_INITIATED_SYSTEM_OPERATION`). Your external KMS can **programmatically deny** unwrap requests whose justification you do not accept. That converts "trust us" into "deny by policy, with an auditable reason string."

> **Production trade-off, stated bluntly:** every step down this table trades **availability** for **control**. EKM makes your data's readability depend on a system Google does not run and cannot SLO. Architect the external KMS for higher availability than the data plane it gates, or accept that its outage is a data-plane outage. Choose CMEK unless a specific regulation forces EKM.

### 3.2 Encryption in use: Confidential Computing

Encryption at rest and in transit leaves a gap: data is plaintext in RAM while being processed. **Confidential VMs** and **Confidential GKE Nodes** close it using CPU-based memory encryption (AMD SEV / SEV-SNP, Intel TDX depending on machine family), with keys generated per-VM inside the CPU and never exposed to the hypervisor or host OS.

| Property | Standard VM | Shielded VM | Confidential VM |
|---|---|---|---|
| Data encrypted at rest | ✅ | ✅ | ✅ |
| Data encrypted in transit | ✅ | ✅ | ✅ |
| **Data encrypted in use (RAM)** | ❌ | ❌ | ✅ |
| Verified boot / vTPM / integrity monitoring | ❌ | ✅ | ✅ |
| Protection from a compromised hypervisor | ❌ | ❌ | ✅ |
| Remote attestation of workload identity | ❌ | Partial | ✅ |
| Perf overhead | — | ~0 | Low, workload-dependent (memory-bound workloads feel it most) |
| Machine-family constraint | None | Most | **Yes** — specific families/regions only |

**Business value:** enables multi-party computation on regulated data — two banks jointly modeling fraud without either seeing the other's rows; a hospital consortium training a model on data none of them may export. That is not a hardening story, it is a **new-revenue** story, which is exactly the framing the Cloud Digital Leader exam rewards.

### 3.3 The perimeter: four different tools, four different threats

Architects routinely conflate these. They are orthogonal.

| Control | Operates on | Stops | Does **not** stop |
|---|---|---|---|
| **VPC firewall rules / Cloud NGFW** | Packets in your VPC | East-west and north-south *network* flows | Anything going to `*.googleapis.com` with a valid credential |
| **IAM** | API identity + permission | Unauthorized *principals* | An **authorized** principal exfiltrating data to a personal project |
| **VPC Service Controls** | Google API access, by *resource perimeter* | **Exfiltration**: a valid credential moving data across the perimeter boundary | A caller acting entirely inside the perimeter |
| **IAP / BeyondCorp Enterprise** | User→app HTTPS sessions | Unauthenticated or non-compliant *device/user* access | Machine-to-machine service traffic |

**The canonical VPC-SC scenario, because the exam loves it:** a developer with legitimate `storage.objectViewer` on the production bucket runs `gsutil cp` to a bucket in their personal project. IAM says yes — the permission is real. The VPC firewall is irrelevant — the traffic never entered your VPC. **Only VPC Service Controls stops this**, because it evaluates the *perimeter boundary of the resource*, not the identity's permission. VPC-SC is a control against **insider risk and credential theft**, sitting orthogonally on top of IAM.

### 3.4 Zero trust access: VPN vs BeyondCorp

| Dimension | Traditional VPN | BeyondCorp Enterprise / IAP |
|---|---|---|
| Trust anchor | Network location | **Identity + device posture + context** |
| Blast radius of one compromised endpoint | Entire routable network | One application, one session |
| Contractor / BYOD onboarding | Ship a laptop, provision VPN | Grant IAM role + Access Level; browser is the client |
| Availability model | Concentrator capacity, regional | Google's global edge |
| Signals available for policy | Source IP | IP, geo, device OS/patch level, disk encryption, screen lock, certificate, time |
| Per-request re-evaluation | ❌ (session-level) | ✅ |
| Audit granularity | Connection logs | Per-request, per-resource logs |

**Failure mode this removes:** VPN split-tunnel misconfiguration silently exposing internal ranges. There is no tunnel to misconfigure; there is a policy expression evaluated on every request.

### 3.5 Detection: self-hosted SIEM vs Google SecOps

| Dimension | Self-hosted SIEM | Google SecOps (Chronicle) |
|---|---|---|
| Pricing model | Per GB ingested → **encourages logging less** | Predictable/capacity-based → **encourages logging everything** |
| Retention economics | Cold-storage tiering, painful rehydration | Default multi-year hot retention (commonly 12 months) |
| Retro-hunt across a year of telemetry | Hours to days, if the data was kept | Sub-minute typical |
| Threat intel | Purchased feeds | Google + **Mandiant** frontline intel, applied continuously to past data |
| Scaling the index | Your problem | Google's problem |

The **perverse incentive** in the left column is the real defect. When ingest is billed per GB, the rational SOC engineer drops "low-value" logs — DNS, NetFlow, endpoint process telemetry — which are precisely the sources that reconstruct an intrusion. Decoupling retention cost from detection quality is the business value.

### 3.6 Compliance: DIY controls vs Assured Workloads

| Dimension | DIY control mapping | Assured Workloads |
|---|---|---|
| Data residency enforcement | Manual review + org policy hand-assembly | Declarative, enforced at folder creation |
| Personnel access controls (support staff location/citizenship) | Contractual, not technical | Technically enforced per compliance regime |
| Regime coverage | You map each control yourself | Packaged (e.g. FedRAMP Moderate/High, IL4/IL5, regional sovereignty offerings) |
| Drift detection | Ad-hoc | Continuous monitoring, violations surfaced |
| Audit evidence | Screenshots and spreadsheets | Generated artifacts |

---

## 4. Infrastructure and Manifests (Complete, Deployable)

Everything below is a full artifact. Substitute `ORG_ID`, `PROJECT_ID`, `POLICY_ID`.

### 4.1 Organization Policy baseline — the "you cannot make that mistake" layer

Org Policy constraints are **preventive** controls evaluated at resource-creation time. They are the highest-leverage security investment in Google Cloud because they make entire vulnerability classes structurally unreachable.

`policies/00-domain-restricted-sharing.yaml`
```yaml
name: organizations/123456789012/policies/iam.allowedPolicyMemberDomains
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          # Cloud Identity customer IDs, NOT domain names.
          # Retrieve with: gcloud organizations list --format="value(owner.directoryCustomerId)"
          - "C03xh8abc"
```

`policies/01-no-public-ip.yaml`
```yaml
name: organizations/123456789012/policies/compute.vmExternalIpAccess
spec:
  inheritFromParent: false
  rules:
    - denyAll: true
```

`policies/02-require-shielded-vm.yaml`
```yaml
name: organizations/123456789012/policies/compute.requireShieldedVm
spec:
  rules:
    - enforce: true
```

`policies/03-uniform-bucket-level-access.yaml`
```yaml
name: organizations/123456789012/policies/storage.uniformBucketLevelAccess
spec:
  rules:
    - enforce: true
```

`policies/04-disable-sa-key-creation.yaml`
```yaml
name: organizations/123456789012/policies/iam.disableServiceAccountKeyCreation
spec:
  inheritFromParent: false
  rules:
    - enforce: true
    # Narrow, audited exception for a legacy on-prem integrator.
    - condition:
        title: legacy-onprem-connector-exception
        description: "Expires 2026-12-31. Tracked in RISK-4471."
        expression: "resource.matchTag('123456789012/exception', 'legacy-sa-keys')"
      enforce: false
```

`policies/05-restrict-vpc-peering.yaml`
```yaml
name: organizations/123456789012/policies/compute.restrictVpcPeering
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - under:organizations/123456789012
```

`policies/06-resource-locations.yaml`
```yaml
name: organizations/123456789012/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:eu-locations
```

Apply the whole bundle:

```bash
$ for f in policies/*.yaml; do
>   echo "==> $f"
>   gcloud org-policies set-policy "$f"
> done
==> policies/00-domain-restricted-sharing.yaml
Created policy [organizations/123456789012/policies/iam.allowedPolicyMemberDomains].
==> policies/01-no-public-ip.yaml
Created policy [organizations/123456789012/policies/compute.vmExternalIpAccess].
==> policies/02-require-shielded-vm.yaml
Created policy [organizations/123456789012/policies/compute.requireShieldedVm].
==> policies/03-uniform-bucket-level-access.yaml
Created policy [organizations/123456789012/policies/storage.uniformBucketLevelAccess].
==> policies/04-disable-sa-key-creation.yaml
Created policy [organizations/123456789012/policies/iam.disableServiceAccountKeyCreation].
==> policies/05-restrict-vpc-peering.yaml
Created policy [organizations/123456789012/policies/compute.restrictVpcPeering].
==> policies/06-resource-locations.yaml
Created policy [organizations/123456789012/policies/gcp.resourceLocations].
```

Verify the effective policy on a leaf project (inheritance resolved):

```bash
$ gcloud org-policies describe compute.vmExternalIpAccess \
    --project=prod-payments-8871 --effective
name: projects/prod-payments-8871/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

Demonstrate the preventive control firing:

```bash
$ gcloud compute instances create canary-public \
    --project=prod-payments-8871 --zone=europe-west1-b \
    --machine-type=e2-medium \
    --network-interface=network=prod-vpc,subnet=prod-eu-w1,address=''
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Constraint constraints/compute.vmExternalIpAccess violated for project
   prod-payments-8871. Add instance projects/prod-payments-8871/zones/
   europe-west1-b/instances/canary-public to the constraint to use external IP
   with it.
```

> **This is the whole point of defense in depth as an operating model.** The mistake was not detected in an audit six weeks later. It was made **impossible**, at the API, by a policy expressed as code.

### 4.2 Terraform equivalent (what actually goes in the repo)

`security-baseline/main.tf`
```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

variable "org_id"        { type = string }
variable "customer_id"   { type = string }
variable "billing_account" { type = string }

locals {
  org = "organizations/${var.org_id}"

  boolean_deny_constraints = [
    "compute.requireShieldedVm",
    "compute.requireOsLogin",
    "compute.disableSerialPortAccess",
    "compute.skipDefaultNetworkCreation",
    "storage.uniformBucketLevelAccess",
    "iam.disableServiceAccountKeyCreation",
    "iam.automaticIamGrantsForDefaultServiceAccounts",
    "sql.restrictPublicIp",
    "sql.restrictAuthorizedNetworks",
    "run.allowedIngress",
  ]
}

resource "google_org_policy_policy" "boolean_enforced" {
  for_each = toset(local.boolean_deny_constraints)

  name   = "${local.org}/policies/${each.value}"
  parent = local.org

  spec {
    inherit_from_parent = false
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "no_external_ip" {
  name   = "${local.org}/policies/compute.vmExternalIpAccess"
  parent = local.org
  spec {
    inherit_from_parent = false
    rules { deny_all = "TRUE" }
  }
}

resource "google_org_policy_policy" "domain_restricted_sharing" {
  name   = "${local.org}/policies/iam.allowedPolicyMemberDomains"
  parent = local.org
  spec {
    inherit_from_parent = false
    rules {
      values { allowed_values = [var.customer_id] }
    }
  }
}

# ---- Org-wide audit log sink: immutable, outside the projects it observes ----

resource "google_project" "audit" {
  name            = "central-audit"
  project_id      = "central-audit-9021"
  org_id          = var.org_id
  billing_account = var.billing_account
}

resource "google_storage_bucket" "audit_archive" {
  project                     = google_project.audit.project_id
  name                        = "org-audit-archive-9021"
  location                    = "EU"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Write-once, delete-never for the retention window.
  retention_policy {
    retention_period = 220752000 # 7 years, seconds
    is_locked        = true      # irreversible; even org admins cannot shorten it
  }

  versioning { enabled = true }

  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
}

resource "google_logging_organization_sink" "all_admin_activity" {
  name             = "org-admin-activity-archive"
  org_id           = var.org_id
  include_children = true
  destination      = "storage.googleapis.com/${google_storage_bucket.audit_archive.name}"

  filter = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR logName:"cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"cloudaudit.googleapis.com%2Fpolicy"
    OR protoPayload.metadata.@type="type.googleapis.com/google.cloud.audit.TransparencyLog"
  EOT
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.audit_archive.name
  role   = "roles/storage.objectCreator"
  member = google_logging_organization_sink.all_admin_activity.writer_identity
}
```

> **SRE note:** `is_locked = true` on the retention policy is **irreversible**. It is also the entire value of the control — an attacker who obtains org-admin cannot destroy the evidence of how they got it. Test it in a scratch org first; you cannot undo it.

### 4.3 VPC Service Controls — the anti-exfiltration perimeter

Create the access policy and a device/context-based Access Level:

```bash
$ gcloud access-context-manager policies create \
    --organization=123456789012 --title="corp-security-perimeter"
Create request issued
Waiting for operation [operations/accessPolicies/418872341190/create] to complete...done.
Created.

$ gcloud access-context-manager policies list --organization=123456789012
NAME          ORGANIZATION      TITLE                    SCOPES
418872341190  123456789012      corp-security-perimeter
```

`access-levels/trusted-corp.yaml`
```yaml
- title: trusted_corp_device
  description: >-
    Corporate-managed, encrypted, screen-locked device on a known egress range,
    originating from a country where we hold operating licences.
  basic:
    combiningFunction: AND
    conditions:
      - ipSubnetworks:
          - 203.0.113.0/24
          - 198.51.100.0/24
      - devicePolicy:
          requireScreenlock: true
          requireCorpOwned: true
          allowedEncryptionStatuses:
            - ENCRYPTED
          osConstraints:
            - osType: DESKTOP_MAC
              minimumVersion: "14.0.0"
            - osType: DESKTOP_WINDOWS
              minimumVersion: "10.0.19045"
            - osType: DESKTOP_CHROME_OS
              requireVerifiedChromeOs: true
      - regions:
          - ES
          - DE
          - IE
      - members:
          - user:sre-oncall@example.com
          - group:platform-sre@example.com
```

```bash
$ gcloud access-context-manager levels replace-all \
    --policy=418872341190 --source-file=access-levels/trusted-corp.yaml
Replaced all access levels.
```

Now the perimeter. `perimeters/prod-data.yaml`:

```yaml
name: accessPolicies/418872341190/servicePerimeters/prod_data
title: prod_data
description: "Production payments + analytics. Nothing leaves without an explicit rule."
perimeterType: PERIMETER_TYPE_REGULAR
status:
  resources:
    - projects/887100211934   # prod-payments-8871
    - projects/887100211935   # prod-analytics-8872
    - projects/887100211936   # prod-kms-8873
  accessLevels:
    - accessPolicies/418872341190/accessLevels/trusted_corp_device
  restrictedServices:
    - storage.googleapis.com
    - bigquery.googleapis.com
    - cloudkms.googleapis.com
    - pubsub.googleapis.com
    - sqladmin.googleapis.com
    - secretmanager.googleapis.com
    - container.googleapis.com
    - artifactregistry.googleapis.com
    - logging.googleapis.com
    - aiplatform.googleapis.com
  vpcAccessibleServices:
    enableRestriction: true
    allowedServices:
      - RESTRICTED-SERVICES
  ingressPolicies:
    # CI/CD in a separate project may push images and read build config.
    - ingressFrom:
        identities:
          - serviceAccount:cloudbuild-prod@ci-shared-4410.iam.gserviceaccount.com
        sources:
          - resource: projects/441000778812   # ci-shared-4410
      ingressTo:
        resources:
          - projects/887100211934
        operations:
          - serviceName: artifactregistry.googleapis.com
            methodSelectors:
              - permission: artifactregistry.repositories.uploadArtifacts
              - method: google.devtools.artifactregistry.v1.ArtifactRegistry.GetRepository
          - serviceName: storage.googleapis.com
            methodSelectors:
              - method: google.storage.objects.get
    # Break-glass: SRE on-call from a compliant device, read-only on logs.
    - ingressFrom:
        identities:
          - group:platform-sre@example.com
        sources:
          - accessLevel: accessPolicies/418872341190/accessLevels/trusted_corp_device
      ingressTo:
        resources:
          - ALL_RESOURCES
        operations:
          - serviceName: logging.googleapis.com
            methodSelectors:
              - method: google.logging.v2.LoggingServiceV2.ListLogEntries
  egressPolicies:
    # Publish anonymised, aggregated metrics to the partner analytics project.
    - egressFrom:
        identities:
          - serviceAccount:metrics-exporter@prod-analytics-8872.iam.gserviceaccount.com
      egressTo:
        resources:
          - projects/990022114567   # partner-analytics-9900
        operations:
          - serviceName: bigquery.googleapis.com
            methodSelectors:
              - method: google.cloud.bigquery.v2.JobService.InsertJob
```

Deploy in **dry-run** first. This is not optional in production:

```bash
$ gcloud access-context-manager perimeters dry-run create prod_data \
    --policy=418872341190 --perimeter-title=prod_data \
    --perimeter-type=regular \
    --perimeter-resources=projects/887100211934,projects/887100211935,projects/887100211936 \
    --perimeter-restricted-services=storage.googleapis.com,bigquery.googleapis.com,cloudkms.googleapis.com
Create request issued for: [prod_data]
Waiting for operation [operations/accessPolicies/418872341190/servicePerimeters/
prod_data/create/1757308811] to complete...done.
Created dry-run spec for Service Perimeter [prod_data].
```

Let it run 7–14 days, then read what *would* have broken:

```bash
$ gcloud logging read '
    protoPayload.metadata.dryRun="true" AND
    protoPayload.status.details.violations.type="SERVICE_PERIMETER"' \
    --project=prod-payments-8871 --limit=3 --format=json
[
  {
    "protoPayload": {
      "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
      "authenticationInfo": {
        "principalEmail": "legacy-etl@corp-dw-3301.iam.gserviceaccount.com"
      },
      "methodName": "google.storage.objects.list",
      "serviceName": "storage.googleapis.com",
      "resourceName": "projects/_/buckets/prod-payments-ledger",
      "metadata": {
        "dryRun": "true",
        "violationReason": "NO_MATCHING_ACCESS_LEVEL",
        "securityPolicyInfo": {
          "servicePerimeterName": "accessPolicies/418872341190/servicePerimeters/prod_data"
        }
      },
      "status": {
        "code": 7,
        "message": "Request is prohibited by organization's policy.",
        "details": [{
          "violations": [{
            "type": "SERVICE_PERIMETER",
            "description": "Request blocked by VPC Service Controls."
          }],
          "uniqueId": "8c1f0b2d-7a4e-4c11-9f3a-6d2e5b7c0a91"
        }]
      }
    },
    "timestamp": "2026-09-02T04:15:07.442Z"
  }
]
```

That output is the whole workflow: a legacy ETL service account you had forgotten about is reading the production ledger. You now have a decision — add an ingress rule, or fix the pipeline — made **before** you broke it. Then enforce:

```bash
$ gcloud access-context-manager perimeters dry-run enforce prod_data \
    --policy=418872341190
Enforce request issued for: [prod_data]
Waiting for operation [...]...done.
Enforced dry-run spec for Service Perimeter [prod_data].
```

Confirm the control now bites:

```bash
$ gsutil cp gs://prod-payments-ledger/2026-09/settlement.parquet gs://my-personal-scratch/
AccessDeniedException: 403 Request is prohibited by organization's policy.
vpcServiceControlsUniqueIdentifier: 8c1f0b2d-7a4e-4c11-9f3a-6d2e5b7c0a91
```

**IAM said yes. VPC Service Controls said no.** That is defense in depth in one terminal transcript.

### 4.4 Cloud Armor — L7 edge defense

`armor/prod-edge-policy.yaml` (exportable/importable form):
```yaml
name: prod-edge-policy
description: "Edge WAF + rate limiting + geo controls for the public payments API."
type: CLOUD_ARMOR
adaptiveProtectionConfig:
  layer7DdosDefenseConfig:
    enable: true
    ruleVisibility: STANDARD
advancedOptionsConfig:
  jsonParsing: STANDARD
  logLevel: VERBOSE
rules:
  - priority: 1000
    description: "Block sanctioned/embargoed jurisdictions at the edge."
    match:
      expr:
        expression: "origin.region_code in ['KP','IR','SY','CU']"
    action: deny(403)

  - priority: 1100
    description: "OWASP CRS: SQL injection, sensitivity 1 (low false positives)."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
    action: deny(403)

  - priority: 1200
    description: "OWASP CRS: cross-site scripting."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})"
    action: deny(403)

  - priority: 1300
    description: "OWASP CRS: local/remote file inclusion."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('lfi-v33-stable', {'sensitivity': 1})"
    action: deny(403)

  - priority: 1400
    description: "Known-bad: log4j / RCE probing."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('cve-canary', {'sensitivity': 1})"
    action: deny(403)

  - priority: 2000
    description: "Per-IP rate limit on the auth endpoint: credential stuffing."
    match:
      expr:
        expression: "request.path.matches('/api/v1/auth/')"
    action: rate_based_ban
    rateLimitOptions:
      conformAction: allow
      exceedAction: deny(429)
      enforceOnKey: IP
      rateLimitThreshold:
        count: 20
        intervalSec: 60
      banDurationSec: 900
      banThreshold:
        count: 100
        intervalSec: 600

  - priority: 2100
    description: "Global per-IP ceiling on the rest of the API."
    match:
      expr:
        expression: "true"
    action: throttle
    rateLimitOptions:
      conformAction: allow
      exceedAction: deny(429)
      enforceOnKey: IP
      rateLimitThreshold:
        count: 600
        intervalSec: 60

  - priority: 2147483647
    description: "Default rule: allow."
    match:
      versionedExpr: SRC_IPS_V1
      config:
        srcIpRanges: ["*"]
    action: allow
```

```bash
$ gcloud compute security-policies import prod-edge-policy \
    --source=armor/prod-edge-policy.yaml --global
Importing security policy [prod-edge-policy]...done.

$ gcloud compute backend-services update payments-api-backend \
    --security-policy=prod-edge-policy --global
Updated [https://www.googleapis.com/compute/v1/projects/prod-payments-8871/global/backendServices/payments-api-backend].

$ gcloud compute security-policies describe prod-edge-policy --global \
    --format="table(rules.priority,rules.action,rules.description)" | head -8
PRIORITY     ACTION           DESCRIPTION
1000         deny(403)        Block sanctioned/embargoed jurisdictions at the edge.
1100         deny(403)        OWASP CRS: SQL injection, sensitivity 1 (low false positives).
1200         deny(403)        OWASP CRS: cross-site scripting.
1300         deny(403)        OWASP CRS: local/remote file inclusion.
1400         deny(403)        Known-bad: log4j / RCE probing.
2000         rate_based_ban   Per-IP rate limit on the auth endpoint: credential stuffing.
2100         throttle         Global per-IP ceiling on the rest of the API.
```

> **Rollout discipline:** deploy every WAF rule with `--preview` (or `action: preview`) first, read `jsonPayload.enforcedSecurityPolicy.outcome` in the load-balancer logs, and only then enforce. A `sqli-v33-stable` rule at sensitivity 4 will block your own analytics team's legitimate query strings on day one.

### 4.5 Hardened GKE cluster + Binary Authorization (supply chain layer)

```bash
$ gcloud container clusters create-auto prod-payments \
    --project=prod-payments-8871 \
    --region=europe-west1 \
    --enable-private-nodes \
    --enable-master-authorized-networks \
    --master-authorized-networks=203.0.113.0/24 \
    --binauthz-evaluation-mode=PROJECT_SINGLETON_POLICY_ENFORCE \
    --enable-google-cloud-access \
    --workload-pool=prod-payments-8871.svc.id.goog \
    --database-encryption-key=projects/prod-kms-8873/locations/europe-west1/keyRings/gke/cryptoKeys/etcd-cmek \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM
Creating cluster prod-payments in europe-west1... Cluster is being health-checked...done.
kubeconfig entry generated for prod-payments.
NAME           LOCATION      MASTER_VERSION      MASTER_IP     MACHINE_TYPE  NODE_VERSION        NUM_NODES  STATUS
prod-payments  europe-west1  1.32.4-gke.1106000  10.24.0.2     e2-medium     1.32.4-gke.1106000  3          RUNNING
```

`binauthz/policy.yaml`
```yaml
defaultAdmissionRule:
  evaluationMode: REQUIRE_ATTESTATION
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
  requireAttestationsBy:
    - projects/prod-payments-8871/attestors/built-by-cloud-build
    - projects/prod-payments-8871/attestors/vuln-scan-passed

globalPolicyEvaluationMode: ENABLE

admissionWhitelistPatterns:
  - namePattern: gke.gcr.io/*
  - namePattern: gcr.io/gke-release/*
  - namePattern: europe-docker.pkg.dev/prod-payments-8871/base-images/*

clusterAdmissionRules:
  europe-west1.prod-payments:
    evaluationMode: REQUIRE_ATTESTATION
    enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
    requireAttestationsBy:
      - projects/prod-payments-8871/attestors/built-by-cloud-build
      - projects/prod-payments-8871/attestors/vuln-scan-passed
      - projects/prod-payments-8871/attestors/change-approved

istioServiceIdentityAdmissionRules: {}
```

```bash
$ gcloud container binauthz policy import binauthz/policy.yaml \
    --project=prod-payments-8871
Updated policy [projects/prod-payments-8871/policy].

$ kubectl run rogue --image=docker.io/library/nginx:latest
Error from server (VIOLATES_POLICY): admission webhook
"imagepolicywebhook.image-policy.k8s.io" denied the request: Image
docker.io/library/nginx:latest denied by Binary Authorization cluster admission
rule for europe-west1.prod-payments. Denied by attestor. Image
docker.io/library/nginx:latest denied by attestor
projects/prod-payments-8871/attestors/built-by-cloud-build: No attestations found
that were valid and signed by a key trusted by the attestor
```

The corresponding hardened workload — note that **every field here is a distinct layer**:

`k8s/payments-api.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
  annotations:
    # Workload Identity Federation: no service account keys exist to be stolen.
    iam.gke.io/gcp-service-account: payments-api@prod-payments-8871.iam.gserviceaccount.com
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 6
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      serviceAccountName: payments-api
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payments-api
      containers:
        - name: api
          # Digest-pinned. Tags are mutable; digests are not.
          image: europe-docker.pkg.dev/prod-payments-8871/apps/payments-api@sha256:9f2c1ab4d3e7885b0c1a6f4d2e9b7c3a5d8e1f0b4c7a2d9e6f3b8c5a1d4e7f0b
          ports:
            - name: http
              containerPort: 8443
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
              ephemeral-storage: "1Gi"
            limits:
              cpu: "2"
              memory: "2Gi"
              ephemeral-storage: "2Gi"
          env:
            - name: KMS_KEY
              value: projects/prod-kms-8873/locations/europe-west1/keyRings/app/cryptoKeys/pan-tokenizer
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
          livenessProbe:
            httpGet: { path: /healthz, port: http, scheme: HTTPS }
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: http, scheme: HTTPS }
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: tmp
          emptyDir: { medium: Memory, sizeLimit: 128Mi }
        - name: cache
          emptyDir: { sizeLimit: 512Mi }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payments-api-allow
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
      ports:
        - protocol: TCP
          port: 8443
  egress:
    # DNS only to kube-dns.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Google APIs via Private Google Access only (restricted VIP).
    - to:
        - ipBlock:
            cidr: 199.36.153.4/30
      ports:
        - protocol: TCP
          port: 443
    # Ledger database, explicit.
    - to:
        - podSelector:
            matchLabels:
              app: ledger-db
      ports:
        - protocol: TCP
          port: 5432
```

Note the egress rule to `199.36.153.4/30` — the **restricted.googleapis.com** VIP. Combined with the VPC-SC perimeter from §4.3, a compromised pod cannot reach `googleapis.com` endpoints outside the perimeter *even if* it steals a valid token. Two independent layers, either of which alone would be insufficient.

### 4.6 Security Command Center → detection pipeline

```bash
$ gcloud scc notifications create scc-critical-findings \
    --organization=123456789012 \
    --pubsub-topic=projects/central-audit-9021/topics/scc-findings \
    --filter='state="ACTIVE" AND (severity="CRITICAL" OR severity="HIGH")'
Created notification config
 [organizations/123456789012/notificationConfigs/scc-critical-findings].

$ gcloud scc findings list 123456789012 \
    --filter='state="ACTIVE" AND severity="HIGH"' \
    --format="table(finding.category, finding.resourceName.basename(), finding.eventTime)" \
    --limit=6
CATEGORY                          RESOURCE_NAME                 EVENT_TIME
PUBLIC_BUCKET_ACL                 legacy-marketing-assets       2026-09-06T22:14:03Z
OVER_PRIVILEGED_SERVICE_ACCOUNT   ci-runner@ci-shared-4410      2026-09-07T01:02:55Z
NON_ORG_IAM_MEMBER                prod-analytics-8872           2026-09-07T03:41:12Z
OPEN_FIREWALL                     allow-ssh-from-anywhere       2026-09-07T06:20:31Z
MFA_NOT_ENFORCED                  contractor-group@example.com  2026-09-07T09:55:48Z
WEAK_SSL_POLICY                   ext-lb-frontend               2026-09-07T11:08:19Z
```

`scc/export-to-bigquery.tf`
```hcl
resource "google_scc_source" "custom" {
  organization = var.org_id
  display_name = "platform-sre-custom-detectors"
  description  = "Findings emitted by internal SRE tooling."
}

resource "google_bigquery_dataset" "scc" {
  project                     = "central-audit-9021"
  dataset_id                  = "scc_findings"
  location                    = "EU"
  default_table_expiration_ms = null

  default_encryption_configuration {
    kms_key_name = "projects/prod-kms-8873/locations/europe/keyRings/audit/cryptoKeys/bq-cmek"
  }
}

resource "google_scc_v2_organization_scc_big_query_export" "findings" {
  name         = "scc-to-bq"
  organization = var.org_id
  location     = "global"
  dataset      = google_bigquery_dataset.scc.id
  description  = "All active findings, continuously exported for SLO reporting."
  filter       = "state=\"ACTIVE\""
}
```

Now findings become a queryable SLO, not a dashboard someone might open:

```sql
-- Mean time to remediate, by severity, last 90 days.
SELECT
  finding.severity,
  COUNT(*) AS findings,
  ROUND(AVG(TIMESTAMP_DIFF(
    finding.mute_update_time, finding.event_time, HOUR)), 1) AS mttr_hours,
  ROUND(APPROX_QUANTILES(TIMESTAMP_DIFF(
    finding.mute_update_time, finding.event_time, HOUR), 100)[OFFSET(95)], 1) AS p95_hours
FROM `central-audit-9021.scc_findings.findings`
WHERE finding.event_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  AND finding.state = 'INACTIVE'
GROUP BY finding.severity
ORDER BY
  CASE finding.severity
    WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3 ELSE 4 END;
```

```
+----------+----------+------------+-----------+
| severity | findings | mttr_hours | p95_hours |
+----------+----------+------------+-----------+
| CRITICAL |       23 |        6.4 |      21.0 |
| HIGH     |      187 |       38.2 |     144.0 |
| MEDIUM   |      904 |      211.7 |     720.0 |
+----------+----------+------------+-----------+
```

### 4.7 Access Transparency and Access Approval — the "who watches Google" layer

This is the control that answers the board question *"what stops a Google engineer from reading our data?"*

- **Access Transparency** emits a **near-real-time audit log entry** whenever Google personnel access your content — with the reason (e.g. a support ticket number), the accessor's home office location, and the resource touched.
- **Access Approval** goes further: Google must **request your explicit approval** before that access occurs. You can wire it to Pub/Sub and require a human on-call to click approve.

```bash
$ gcloud access-approval settings update \
    --project=prod-payments-8871 \
    --notification_emails='security-oncall@example.com' \
    --enrolled_services=all
name: projects/prod-payments-8871/accessApprovalSettings
notificationEmails:
- security-oncall@example.com
enrolledServices:
- cloudProduct: all
  enrollmentLevel: BLOCK_ALL
enrolledAncestor: false

$ gcloud access-approval requests list --project=prod-payments-8871 --state=pending
NAME                                                              REQUESTED_REASON             REQUESTED_EXPIRATION
projects/prod-payments-8871/approvalRequests/abcdef0123456789     CUSTOMER_INITIATED_SUPPORT   2026-09-09T14:00:00Z

$ gcloud access-approval requests approve \
    projects/prod-payments-8871/approvalRequests/abcdef0123456789
approve:
  approveTime: '2026-09-08T12:41:09Z'
  expireTime: '2026-09-09T14:00:00Z'
```

Query the transparency log:

```bash
$ gcloud logging read \
    'protoPayload.@type="type.googleapis.com/google.cloud.audit.TransparencyLog"' \
    --project=prod-payments-8871 --limit=1 --format=json
[
  {
    "protoPayload": {
      "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
      "methodName": "GoogleInternal.Read",
      "resourceName": "projects/prod-payments-8871/buckets/prod-payments-ledger",
      "metadata": {
        "@type": "type.googleapis.com/google.cloud.audit.TransparencyLog",
        "accesses": [{
          "principalOfficeCountry": "IE",
          "principalEmployingEntity": "Google_LLC",
          "principalPhysicalLocationCountry": "IE",
          "accessReason": "Customer-initiated support ticket 44219087.",
          "accessApprovalRequest": "projects/prod-payments-8871/approvalRequests/abcdef0123456789"
        }],
        "productName": ["Cloud Storage"]
      }
    },
    "timestamp": "2026-09-08T12:52:31.019Z"
  }
]
```

**Business value:** this is a *contractually and technically auditable* answer to a regulator, replacing a vendor assurance letter with a log line.

---

## 5. Verification and Failure Diagnosis

### 5.1 Verification ladder — run these in order

```bash
# 1. Are the preventive controls actually in force on every leaf project?
$ for p in $(gcloud projects list --format="value(projectId)" --filter="parent.id=887100"); do
>   v=$(gcloud org-policies describe compute.vmExternalIpAccess \
>        --project="$p" --effective --format="value(spec.rules[0].denyAll)" 2>/dev/null)
>   printf "%-28s external-ip-denied=%s\n" "$p" "${v:-NOT_SET}"
> done
prod-payments-8871           external-ip-denied=True
prod-analytics-8872          external-ip-denied=True
prod-kms-8873                external-ip-denied=True
sandbox-legacy-8899          external-ip-denied=NOT_SET     # <-- investigate

# 2. Any service account keys in existence? (they should not exist)
$ gcloud asset search-all-resources \
    --scope=organizations/123456789012 \
    --asset-types=iam.googleapis.com/ServiceAccountKey \
    --query='NOT name:"*/keys/*system-managed*"' \
    --format="table(project, displayName, createTime)"
PROJECT               DISPLAY_NAME                       CREATE_TIME
corp-dw-3301          legacy-etl user-managed key        2024-03-11T08:22:41Z

# 3. Anything publicly reachable?
$ gcloud asset search-all-iam-policies \
    --scope=organizations/123456789012 \
    --query='policy:("allUsers" OR "allAuthenticatedUsers")' \
    --format="table(resource, policy.bindings.role)"
RESOURCE                                                    ROLE
//storage.googleapis.com/legacy-marketing-assets            ['roles/storage.objectViewer']

# 4. Is the perimeter enforcing, not just dry-run?
$ gcloud access-context-manager perimeters describe prod_data \
    --policy=418872341190 --format="value(status.restrictedServices.len(), spec)"
9

# 5. Is Binary Authorization enforcing on every cluster?
$ gcloud container clusters list --format="table(name,location,binaryAuthorization.evaluationMode)"
NAME           LOCATION      EVALUATION_MODE
prod-payments  europe-west1  PROJECT_SINGLETON_POLICY_ENFORCE
dev-scratch    europe-west1  DISABLED
```

### 5.2 Symptom → cause → command

| Symptom | Most probable cause | Diagnostic command |
|---|---|---|
| `403 Request is prohibited by organization's policy` + `vpcServiceControlsUniqueIdentifier` | VPC-SC perimeter denial | `gcloud logging read 'protoPayload.status.details.violations.type="SERVICE_PERIMETER"' --limit=5 --format=json` and match the `uniqueId` |
| `403` with **no** unique identifier | Plain IAM denial | `gcloud policy-troubleshoot iam <RESOURCE> --principal-email=<SA> --permission=<PERM>` |
| `Constraint constraints/... violated` at create time | Org Policy preventive control | `gcloud org-policies describe <CONSTRAINT> --project=<P> --effective` |
| Pod stuck `ImagePullBackOff`, events mention `VIOLATES_POLICY` | Binary Authorization, no attestation | `gcloud container binauthz attestations list --attestor=<A> --artifact-url=<IMAGE_DIGEST_URL>` |
| App can resolve `googleapis.com` but every call times out | Egress NetworkPolicy or missing Private Google Access route | `gcloud compute networks subnets describe <SUBNET> --region=<R> --format="value(privateIpGoogleAccess)"` |
| `KMS_KEY_DISABLED` / data suddenly unreadable | CMEK key disabled, destroyed, or EKM unreachable | `gcloud kms keys versions list --key=<K> --keyring=<KR> --location=<L>` |
| Legit users blocked from an IAP-protected app | Access Level too strict (device policy / region) | `gcloud logging read 'resource.type="iap_web" AND jsonPayload.status="DENIED"' --limit=5` |
| Cloud Armor returning 403 on valid traffic | Preconfigured WAF false positive | filter LB logs on `jsonPayload.enforcedSecurityPolicy.name` and inspect `matchedFieldValue` |
| Findings appear in SCC but no alert fires | Notification filter too narrow, or Pub/Sub IAM missing | `gcloud scc notifications describe <ID> --organization=<ORG>` |

### 5.3 Worked diagnosis — the four-403 triage

The single most common production confusion is *which layer said no*. Google Cloud gives you a deterministic discriminator; use it.

```bash
# Step 1 — capture the raw error verbatim. The identifier field is the tell.
$ gsutil ls gs://prod-payments-ledger/
AccessDeniedException: 403 Request is prohibited by organization's policy.
vpcServiceControlsUniqueIdentifier: 4d0a91cc-2b17-4a83-b5e6-77f1c8a20d34
#            ^^^^^^^^^^^^^^^^^^^^^ present  => VPC Service Controls
#                                   absent  => IAM, Org Policy, or Context-Aware Access

# Step 2 — VPC-SC path: resolve the identifier to the exact violated rule.
$ gcloud logging read \
    'protoPayload.status.details.uniqueId="4d0a91cc-2b17-4a83-b5e6-77f1c8a20d34"' \
    --organization=123456789012 --limit=1 \
    --format="value(protoPayload.metadata.violationReason,
                    protoPayload.metadata.securityPolicyInfo.servicePerimeterName,
                    protoPayload.authenticationInfo.principalEmail,
                    protoPayload.methodName)"
NO_MATCHING_ACCESS_LEVEL   accessPolicies/418872341190/servicePerimeters/prod_data   analyst@example.com   google.storage.objects.list

# Step 3 — IAM path (no unique identifier): use Policy Troubleshooter, not guesswork.
$ gcloud policy-troubleshoot iam \
    //cloudresourcemanager.googleapis.com/projects/prod-payments-8871 \
    --principal-email=analyst@example.com \
    --permission=storage.objects.list
access: NOT_GRANTED
explainedPolicies:
- access: NOT_GRANTED
  fullResourceName: //cloudresourcemanager.googleapis.com/projects/prod-payments-8871
  bindingExplanations:
  - access: NOT_GRANTED
    role: roles/storage.objectViewer
    rolePermission: ROLE_PERMISSION_INCLUDED
    memberships:
      'user:analyst@example.com':
        membership: MEMBERSHIP_NOT_INCLUDED
    condition:
      expression: request.time < timestamp("2026-08-31T00:00:00Z")
      title: temporary-analyst-access
  relevance: HIGH
```

The condition expired on 2026-08-31. Diagnosed in three commands, with no guessing and no over-broad "just give them Editor" remediation.

### 5.4 The failure modes of defense in depth itself

Layered security has its own production pathologies. Name them so you can design against them:

| Pathology | How it manifests | Mitigation |
|---|---|---|
| **Debuggability collapse** | Four layers can each return 403; on-call cannot tell which | Standardize triage on §5.3; log the discriminating field in your error-handling middleware |
| **Change amplification** | Adding one new consumer requires edits in IAM + VPC-SC + NetworkPolicy + Cloud Armor | Terraform module that emits all four from one input |
| **Dry-run never enforced** | Perimeter sits in dry-run for 8 months | Alert on `spec != status` for any perimeter older than 30 days |
| **Exception rot** | Temporary org-policy exceptions become permanent | Every exception carries a `condition` with an expiry timestamp (see §4.1) |
| **Alert fatigue** | SCC MEDIUM findings at 900+ open | Route only CRITICAL/HIGH to paging; MEDIUM to a backlog with an SLO |
| **Availability coupling** | EKM/CMEK outage becomes a data-plane outage | Multi-region key rings, tested key-unavailability game day |

---

## 6. Mapping Technical Controls to the Exam's Business Language

The Cloud Digital Leader exam asks these in business framing. Train the translation both ways.

| Exam-style prompt | Correct control | Why |
|---|---|---|
| "Employees must access internal apps from anywhere without a VPN, with device posture checked" | **BeyondCorp Enterprise / IAP** | Zero trust: identity + context replaces network location |
| "Prevent an authorized employee from copying production data to a personal project" | **VPC Service Controls** | IAM permits it; only a resource perimeter blocks exfiltration |
| "Regulator requires we retain sole control of encryption keys, outside Google" | **Cloud EKM** (+ Key Access Justifications) | External key manager; Google cannot decrypt without your grant |
| "We must know, and approve, whenever Google support touches our data" | **Access Transparency + Access Approval** | Near-real-time logs plus explicit pre-approval |
| "Our public API is being flooded and scraped" | **Cloud Armor** (Adaptive Protection, rate limiting, WAF) | Absorbed at Google's global edge before it reaches your backends |
| "Only images built by our pipeline and scanned clean may run in prod" | **Binary Authorization** + Software Delivery Shield | Deploy-time attestation enforcement |
| "We need years of security telemetry searchable without per-GB ingest penalties" | **Google SecOps (Chronicle)** | Decouples retention cost from detection quality; Mandiant intel applied retroactively |
| "Sensitive customer data may not leave the EU, and support staff must be EU-based" | **Assured Workloads** (+ `gcp.resourceLocations`) | Technically enforced residency and personnel controls |
| "Two hospitals want to train a joint model without exposing each other's data" | **Confidential Computing** | Data encrypted in use; neither party nor Google sees the other's memory |
| "Find and classify PII across our warehouse before we open it to analysts" | **Sensitive Data Protection (Cloud DLP)** | Discovery, classification, de-identification, tokenization |
| "Reduce our cyber-insurance premium by proving our posture" | **Risk Protection Program** (Risk Manager report) | Measured posture becomes an insurable, priced quantity |
| "Executives are the top phishing target" | **Titan Security Keys** / phishing-resistant MFA, Advanced Protection | Hardware FIDO keys defeat credential phishing |

### 6.1 The three sentences the exam is testing

1. **Google is not a vendor you secure around; Google is a security organization whose engineering you inherit.** Layers 1–2 (silicon, boot, backbone, DDoS) are absorbed at zero configuration cost.
2. **Defense in depth means no single control failure is fatal** — IAM, VPC Service Controls, Org Policy, Cloud Armor, Binary Authorization and Confidential Computing are *orthogonal*, each catching what the others structurally cannot.
3. **The business value is measurable in four currencies:** avoided headcount, faster time-to-market in regulated segments, reduced breach probability and blast radius, and *new revenue* from workloads (multi-party, sovereign, regulated) that were previously impossible to run at all.

---

## 7. Referencias

**Objetivo del examen**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Modelo de seguridad y responsabilidad compartida**
- Google security overview / infrastructure security design — https://cloud.google.com/docs/security/infrastructure/design
- Shared responsibility and shared fate — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google Cloud security best practices center — https://cloud.google.com/security/best-practices
- Trust and security — https://cloud.google.com/security

**Hardware, boot y computación confidencial**
- Titan security key / hardware root of trust — https://cloud.google.com/blog/products/identity-security/titan-in-depth-security-in-plaintext
- Shielded VM — https://cloud.google.com/security/products/shielded-vm
- Confidential Computing — https://cloud.google.com/security/products/confidential-computing
- Confidential GKE Nodes — https://cloud.google.com/kubernetes-engine/docs/how-to/confidential-gke-nodes

**Red y edge**
- Cloud Armor — https://cloud.google.com/security/products/armor
- Cloud Armor security policies overview — https://cloud.google.com/armor/docs/security-policy-overview
- Adaptive Protection — https://cloud.google.com/armor/docs/adaptive-protection-overview
- Preconfigured WAF rules (OWASP CRS) — https://cloud.google.com/armor/docs/waf-rules
- Encryption in transit — https://cloud.google.com/docs/security/encryption-in-transit
- ALTS (Application Layer Transport Security) — https://cloud.google.com/docs/security/encryption-in-transit/application-layer-transport-security

**Identidad y zero trust**
- BeyondCorp Enterprise — https://cloud.google.com/beyondcorp-enterprise
- Identity-Aware Proxy — https://cloud.google.com/security/products/iap
- Context-Aware Access — https://cloud.google.com/beyondcorp-enterprise/docs/context-aware-access
- IAM overview — https://cloud.google.com/iam/docs/overview
- Workload Identity Federation for GKE — https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Policy Troubleshooter — https://cloud.google.com/policy-intelligence/docs/troubleshoot-access

**Perímetro de servicios y política organizacional**
- VPC Service Controls overview — https://cloud.google.com/vpc-service-controls/docs/overview
- VPC-SC dry-run mode — https://cloud.google.com/vpc-service-controls/docs/dry-run-mode
- VPC-SC troubleshooting — https://cloud.google.com/vpc-service-controls/docs/troubleshooting
- Organization Policy Service — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints reference — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Private Google Access / restricted VIP — https://cloud.google.com/vpc/docs/configure-private-google-access

**Datos y claves**
- Default encryption at rest — https://cloud.google.com/docs/security/encryption/default-encryption
- Customer-managed encryption keys (CMEK) — https://cloud.google.com/kms/docs/cmek
- Cloud External Key Manager (Cloud EKM) — https://cloud.google.com/kms/docs/ekm
- Key Access Justifications — https://cloud.google.com/assured-workloads/key-access-justifications/docs/overview
- Cloud HSM — https://cloud.google.com/kms/docs/hsm
- Sensitive Data Protection — https://cloud.google.com/security/products/sensitive-data-protection

**Cadena de suministro de software**
- Binary Authorization — https://cloud.google.com/binary-authorization/docs/overview
- Binary Authorization policy reference — https://cloud.google.com/binary-authorization/docs/policy-yaml-reference
- Software Delivery Shield — https://cloud.google.com/software-supply-chain-security/docs/overview
- GKE cluster hardening guide — https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster

**Detección, respuesta y transparencia**
- Security Command Center — https://cloud.google.com/security/products/security-command-center
- SCC findings and notifications — https://cloud.google.com/security-command-center/docs/how-to-notifications
- Google Security Operations (Chronicle) — https://cloud.google.com/security/products/security-operations
- Mandiant — https://cloud.google.com/security/mandiant
- Access Transparency — https://cloud.google.com/assured-workloads/access-transparency/docs/overview
- Access Approval — https://cloud.google.com/assured-workloads/access-approval/docs/overview
- Cloud Audit Logs — https://cloud.google.com/logging/docs/audit

**Cumplimiento y soberanía**
- Compliance resource center — https://cloud.google.com/security/compliance
- Compliance offerings / certifications — https://cloud.google.com/security/compliance/offerings
- Assured Workloads — https://cloud.google.com/security/products/assured-workloads
- Sovereign Cloud — https://cloud.google.com/sovereign-cloud
- Risk Protection Program — https://cloud.google.com/security/risk-protection-program