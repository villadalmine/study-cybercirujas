# 5.1 — Describe Fundamental Cloud Security Concepts

**Certification:** Google Cloud Digital Leader (exam guide 2026-08-12)
**Domain 5:** Trust and security with Google Cloud — **Objective weight: 9.0**
**Depth profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation: the architectural problem this objective actually solves

### 1.1 The failure mode that creates the objective

Every production incident classified as a "security breach" in a public cloud estate resolves, on post-mortem, into one of four *architectural* defects — not into a zero-day:

| Defect class | Concrete manifestation | Why the classic on-prem control does not apply |
|---|---|---|
| **Ambiguous ownership** | Nobody patched the guest OS on a fleet of `n2-standard-8` VMs because the platform team assumed "the cloud patches it" | The perimeter firewall was the ownership boundary on-prem; in cloud the boundary moved *inside* the service stack and is different per service model |
| **Identity sprawl** | A service account key JSON committed to a repo in 2023 is still valid in 2026 and holds `roles/editor` at project level | On-prem, credential blast radius was bounded by network reachability; in cloud, an API key is reachable from any IP on Earth |
| **Implicit trust in the network** | An attacker who lands on one VM in a VPC can reach BigQuery and Cloud Storage using the VM's attached service account, from inside the "trusted" subnet | The `10.0.0.0/8` "internal = trusted" axiom is false when the data plane is `*.googleapis.com`, which is *not* on your network |
| **Unbounded data egress** | A compromised or merely careless principal copies a 4 TB BigQuery dataset to a personal-project bucket. Every IAM check passes — the principal genuinely had `bigquery.dataViewer` | IAM answers "may this identity act on this resource?" It does **not** answer "may this data leave this trust boundary?" |

The Cloud Digital Leader exam frames 5.1 as conceptual. As a Platform Architect you should read it as the *control taxonomy* that maps each defect above to a specific, testable Google Cloud mechanism. That mapping is the whole content of this topic:

```
Ambiguous ownership   → Shared responsibility model → shared fate
Identity sprawl       → IAM: least privilege, deny policies, WIF, no keys
Implicit network trust→ Zero trust / BeyondCorp, IAP, Context-Aware Access
Unbounded egress      → VPC Service Controls (a control plane IAM cannot express)
```

Plus two cross-cutting axes the exam explicitly separates:

```
Privacy  ≠ Security   → data protection, residency, sovereignty, Access Transparency
Compliance            → attestations, Assured Workloads, auditability
```

### 1.2 Security vs. privacy — the distinction the exam tests

Candidates routinely conflate these. They are orthogonal, and a system can satisfy one while violating the other.

| Axis | **Security** | **Privacy** |
|---|---|---|
| Question answered | *Is the data protected from unauthorized access, modification, loss?* | *Is the data used only for the purposes the data subject and the customer agreed to?* |
| Primary threat actor | External attacker, malicious insider, ransomware | Over-broad internal use, undisclosed processing, unauthorized jurisdiction |
| Google Cloud mechanisms | IAM, encryption, VPC-SC, Cloud Armor, Security Command Center | Access Transparency, Access Approval, Key Access Justifications, data residency controls, Sensitive Data Protection, contractual DPA |
| Failure looks like | Exfiltration, defacement, outage | Data processed in a non-approved region; support engineer reads content without a ticket |
| Can be satisfied while other fails? | Yes — perfectly encrypted data replicated to a jurisdiction the customer forbade | Yes — data never leaves the EU, and is publicly readable |

**Google's stated commitments** (relevant to privacy, not security): customer data is the customer's data; Google does not sell customer data; customer data is not used for advertising; and encryption at rest and in transit is the default, not an option.

### 1.3 The CIA triad, restated for a distributed control plane

| Property | On-prem instrument | Google Cloud instrument | SLO/measurable proxy |
|---|---|---|---|
| **Confidentiality** | Network segmentation, disk encryption appliance | IAM allow/deny policies, default AES-256 at rest, ALTS in transit, CMEK/EKM, VPC-SC, Confidential Computing | % resources with public IAM bindings = 0; % buckets with CMEK |
| **Integrity** | File integrity monitoring, RAID | Shielded VM (Measured Boot, vTPM, integrity monitoring), Binary Authorization, object versioning + retention lock, checksums (CRC32C/MD5) on every GCS object | Integrity-monitoring findings = 0; % images signed by attestor |
| **Availability** | Redundant HW, UPS | Multi-region/dual-region storage, regional MIGs, Cloud Armor + Google's edge for DDoS absorption, org-policy-enforced backups | Error budget burn; DDoS L3/L4 absorbed at edge with no origin impact |

---

## 2. The shared responsibility model — and why Google reframes it as *shared fate*

### 2.1 The boundary moves with the service model

The single most-tested concept in 5.1. The rule: **the more managed the service, the more of the stack Google owns — but the customer *always* owns data, identities, and access policy.**

| Layer | On-prem | **IaaS** (Compute Engine) | **PaaS/CaaS** (GKE Standard, App Engine flex) | **CaaS autopilot / Serverless** (Cloud Run, GKE Autopilot) | **SaaS/Fully managed** (BigQuery, Cloud Storage, Spanner) |
|---|---|---|---|---|---|
| Content / data | Customer | Customer | Customer | Customer | Customer |
| Access policies (IAM) | Customer | Customer | Customer | Customer | Customer |
| Identity management | Customer | Customer | Customer | Customer | Customer (fed. via Cloud Identity) |
| Usage / configuration | Customer | Customer | Customer | Customer | Customer |
| Web application security | Customer | Customer | Customer | Customer | **Google** |
| Deployment / app code | Customer | Customer | Customer | Shared | **Google** |
| Guest OS, patching, image | Customer | **Customer** | Shared (node images auto-upgradable) | **Google** | **Google** |
| Network security (in-VPC) | Customer | Customer | Shared | Shared | **Google** |
| Container/runtime hardening | Customer | Customer | Shared | **Google** | **Google** |
| Hypervisor / host OS | Customer | **Google** | Google | Google | Google |
| Hardware, firmware (Titan) | Customer | **Google** | Google | Google | Google |
| Physical datacenter security | Customer | **Google** | Google | Google | Google |

**The three lines that never move, at any service model:** *your data*, *your identities*, *your access policies*. A CDL question that says "Google secures X for you" is almost always false if X is one of those three.

### 2.2 Shared responsibility → shared fate

Shared responsibility, honestly evaluated, is a **liability-allocation contract**. It tells the customer what they will be blamed for; it does not help them succeed. Google's stated evolution is **shared fate**: the provider takes an active interest in the customer's secure outcome.

| Dimension | Shared responsibility (classic) | **Shared fate (Google's model)** |
|---|---|---|
| Posture | "Here is the line. Below it, we're liable." | "We help you land safely above the line." |
| Artifacts | Responsibility matrix, contract | Opinionated **security foundations blueprint**, secure-by-default landing zones, `terraform-google-modules` |
| Defaults | Customer must harden | Secure defaults: encryption at rest on by default, no public IPs unless requested, uniform bucket-level access recommended, Shielded VM default on many images |
| Guardrails | Customer builds them | Organization Policy constraints, Assured Workloads control packages |
| Visibility | Customer builds SIEM | Security Command Center, Cloud Audit Logs on by default (Admin Activity), Access Transparency |
| Risk transfer | None | **Risk Protection Program** — posture data (from SCC) shared with insurers to price cyber-insurance |

**Architectural consequence for a platform team:** shared fate is the justification for *building a paved road*. If your landing zone ships a project factory with org policies, VPC-SC perimeters, log sinks and a hardened base image pre-attached, application teams inherit the correct posture rather than re-deriving it. That is the shared-fate pattern applied internally.

---

## 3. The resource hierarchy: the substrate every control binds to

Nothing in Google Cloud security is comprehensible without this. Policies attach to nodes and flow **downward**.

```
Organization  (1 per Cloud Identity / Workspace domain — the root of trust)
│
├── Folder: prod
│   ├── Folder: payments
│   │   ├── Project: pay-api-prod-4471
│   │   │   ├── VPC network, subnets, firewall rules
│   │   │   ├── Cloud SQL instance, GCS buckets, BigQuery datasets
│   │   │   └── Service accounts (project-scoped identities)
│   │   └── Project: pay-ledger-prod-9922
│   └── Folder: platform
├── Folder: nonprod
└── Folder: sandbox
```

Two *different* policy systems attach to these nodes, and confusing them is a classic exam trap:

| | **IAM allow policy** | **Organization policy (constraint)** |
|---|---|---|
| Answers | *Who can do what on which resource* | *What configurations are permitted to exist at all* |
| Grant target | Principal → role → resource | Resource type / field → allowed values |
| Inheritance | **Additive union.** A child cannot subtract a grant made at the parent | Inherited; may be overridden by a child **only if** the constraint and hierarchy permit (`inheritFromParent`, `reset`) |
| Example | `alice@ → roles/storage.objectViewer on project pay-api-prod-4471` | `constraints/compute.vmExternalIpAccess: denyAll` on folder `prod` |
| Enforced at | Request authorization time | Resource create/update time (and evaluated on some existing resources) |
| The gap it leaves | Cannot stop a *permitted* principal from exfiltrating | Cannot express "this identity may not read this dataset" |

Because allow policies are purely additive, the only ways to *subtract* effective access are: **IAM deny policies**, **principal access boundary policies**, **organization policies**, and **VPC Service Controls**. Memorize that list — it is the answer to "how do I restrict an over-privileged inherited grant?"

---

## 4. Identity and access management: mechanics

### 4.1 Policy evaluation order

```
Request: principal P wants permission M on resource R
  │
  ├─ 1. Principal Access Boundary  → is R inside P's allowed boundary?   NO → DENY
  ├─ 2. IAM Deny policies (resource + all ancestors)
  │       any matching deny rule where P is not an exception principal?  YES → DENY
  ├─ 3. IAM Allow policies (resource + all ancestors, unioned)
  │       does any bound role contain M? (IAM Conditions evaluated here)  NO → DENY
  ├─ 4. VPC Service Controls perimeter check (for supported APIs)
  │       does the call cross a perimeter without a matching rule?       YES → DENY
  └─ ALLOW
```

**Deny wins. Always. Order 1→4 is short-circuiting.**

### 4.2 Principal types and their blast radius

| Principal type | Identifier form | Credential | Rotation | Recommended for |
|---|---|---|---|---|
| Google Account | `user:sre@example.com` | Password + phishing-resistant MFA (Titan/FIDO2) | Human | Humans only |
| Google Group | `group:platform-sre@example.com` | n/a (membership) | n/a | **All human grants** — never bind users directly |
| Service account | `serviceAccount:app@proj.iam.gserviceaccount.com` | Short-lived OAuth token via metadata server | Automatic (~1 h) | Workloads on Google Cloud |
| SA **key** (JSON) | same, + `private_key` | Static RSA key | **Never expires by default** | ⚠️ Avoid. This is the #1 leaked-credential vector |
| Workload identity federation | `principal://iam.googleapis.com/projects/.../subject/...` | External IdP OIDC/SAML token exchanged for a short-lived Google token | Per-request | GitHub Actions, AWS, on-prem, GKE |
| Workforce identity federation | `principal://iam.googleapis.com/locations/global/workforcePools/...` | External IdP (Okta, Entra ID) | Session | Humans from an existing corporate IdP |

### 4.3 Role granularity trade-off

| Role class | Example | Permissions | Trade-off |
|---|---|---|---|
| **Basic** (legacy) | `roles/owner`, `roles/editor`, `roles/viewer` | Thousands, across all services | ❌ Never in production. `roles/editor` can modify IAM on many resources and read almost all data |
| **Predefined** | `roles/storage.objectViewer` | Curated per service, maintained by Google (new permissions added automatically) | ✅ Default choice. Occasional over-grant; Google may add permissions you did not audit |
| **Custom** | `roles/custom.bucketLister` | Exactly the permissions you list | Tightest least privilege, but **you** own maintenance; permissions in `SUPPORTED`/`TESTING` stages can break; org- or project-scoped only |

**Practical rule:** default to predefined; escalate to custom only when a Policy-Analyzer-driven review shows a predefined role grants a permission that would materially widen blast radius (typically `*.setIamPolicy`, `*.getIamPolicy`, `*.keys.create`).

---

## 5. Complete infrastructure: a least-privilege, guardrailed project

Everything below is deployable as-is. Substitute `ORG_ID`, `BILLING_ID`, project IDs.

### 5.1 Organization policies (guardrails) — YAML, applied with `gcloud org-policies`

`policies/vm-external-ip.yaml`
```yaml
# Deny public IPs on Compute Engine VMs across the whole prod folder.
# Exception is granted per-project by an inheritFromParent=false override.
name: folders/641182299038/policies/compute.vmExternalIpAccess
spec:
  inheritFromParent: true
  rules:
    - denyAll: true
```

`policies/allowed-domains.yaml`
```yaml
# Only identities from our Cloud Identity customer ID may appear in any
# IAM allow policy. This single constraint blocks allUsers, allAuthenticatedUsers
# and every gmail.com account from ever being granted a role.
name: organizations/889201773455/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
    - values:
        allowedValues:
          - is:C03xk9qz1          # Cloud Identity customer ID
```

`policies/uniform-bucket-level-access.yaml`
```yaml
# Kill per-object ACLs. Without this, an object can be world-readable
# even when the bucket IAM policy is clean.
name: organizations/889201773455/policies/storage.uniformBucketLevelAccess
spec:
  rules:
    - enforce: true
```

`policies/disable-sa-key-creation.yaml`
```yaml
# The single highest-value guardrail in the catalogue: it makes the
# "leaked JSON key" incident class structurally impossible.
name: organizations/889201773455/policies/iam.disableServiceAccountKeyCreation
spec:
  rules:
    - enforce: true
```

`policies/require-shielded-vm.yaml`
```yaml
name: organizations/889201773455/policies/compute.requireShieldedVm
spec:
  rules:
    - enforce: true
```

`policies/restrict-sql-public-ip.yaml`
```yaml
name: organizations/889201773455/policies/sql.restrictPublicIp
spec:
  rules:
    - enforce: true
```

`policies/resource-locations.yaml`
```yaml
# Data residency as a hard constraint, not a convention.
# Creation of any location-bound resource outside the EU fails at the API.
name: folders/641182299038/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:eu-locations
```

Apply them:

```bash
$ for f in policies/*.yaml; do gcloud org-policies set-policy "$f"; done
Created policy [organizations/889201773455/policies/iam.allowedPolicyMemberDomains].
name: organizations/889201773455/policies/iam.allowedPolicyMemberDomains
spec:
  etag: CO7Rzr4GEJDh8bYB
  rules:
  - values:
      allowedValues:
      - is:C03xk9qz1
  updateTime: '2026-09-08T11:04:27.918433Z'
...
```

Verify effective policy at a leaf project (this resolves inheritance, which `describe` does not):

```bash
$ gcloud org-policies describe compute.vmExternalIpAccess \
    --project=pay-api-prod-4471 --effective
name: projects/pay-api-prod-4471/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

### 5.2 A **custom** organization policy constraint

Predefined constraints do not cover everything. Custom constraints evaluate a CEL expression against the resource being created or updated.

`policies/custom-require-cmek-gce.yaml`
```yaml
name: organizations/889201773455/customConstraints/custom.requireCmekOnBootDisk
resourceTypes:
  - compute.googleapis.com/Disk
methodTypes:
  - CREATE
condition: "has(resource.diskEncryptionKey) && resource.diskEncryptionKey.kmsKeyName.startsWith('projects/sec-kms-prod-1180/')"
actionType: ALLOW
displayName: Boot and data disks must use a CMEK from the central KMS project
description: >-
  Google-managed encryption is not sufficient for PCI-DSS scoped workloads;
  the key must be revocable by the security team.
```

```bash
$ gcloud org-policies set-custom-constraint policies/custom-require-cmek-gce.yaml
Created custom constraint [organizations/889201773455/customConstraints/custom.requireCmekOnBootDisk].
```

Then enforce it like any other constraint:

```yaml
name: folders/641182299038/policies/custom.requireCmekOnBootDisk
spec:
  rules:
    - enforce: true
```

### 5.3 IAM deny policy — subtracting an inherited grant

Deny policies attach to org/folder/project via the IAM v2 API and are the only way to say "no" to a principal who was granted a role by an ancestor.

`policies/deny-sa-impersonation.yaml`
```yaml
displayName: Block impersonation of break-glass service accounts
rules:
  - denyRule:
      deniedPrincipals:
        - principalSet://goog/public:all
      exceptionPrincipals:
        - principalSet://goog/group/breakglass-approvers@example.com
      deniedPermissions:
        - iam.googleapis.com/serviceAccounts.getAccessToken
        - iam.googleapis.com/serviceAccounts.getOpenIdToken
        - iam.googleapis.com/serviceAccounts.implicitDelegation
      denialCondition:
        title: Only break-glass SAs
        expression: >-
          resource.matchTag('889201773455/tier', 'breakglass')
```

```bash
$ gcloud iam policies create deny-breakglass-impersonation \
    --attachment-point=cloudresourcemanager.googleapis.com/organizations/889201773455 \
    --kind=denypolicies \
    --policy-file=policies/deny-sa-impersonation.yaml
Created policy [deny-breakglass-impersonation].

$ gcloud iam policies list \
    --attachment-point=cloudresourcemanager.googleapis.com/organizations/889201773455 \
    --kind=denypolicies --format="table(name.basename(), displayName)"
NAME                             DISPLAY_NAME
deny-breakglass-impersonation    Block impersonation of break-glass service accounts
```

### 5.4 Conditional IAM binding (time- and resource-bounded access)

```bash
$ gcloud projects add-iam-policy-binding pay-api-prod-4471 \
  --member="group:oncall-payments@example.com" \
  --role="roles/cloudsql.client" \
  --condition='expression=request.time < timestamp("2026-09-15T00:00:00Z") && resource.name.startsWith("projects/pay-api-prod-4471/instances/ledger-"),title=oncall-window-w37,description=Sprint 37 on-call rotation only'
Updated IAM policy for project [pay-api-prod-4471].
bindings:
- condition:
    description: Sprint 37 on-call rotation only
    expression: request.time < timestamp("2026-09-15T00:00:00Z") && resource.name.startsWith("projects/pay-api-prod-4471/instances/ledger-")
    title: oncall-window-w37
  members:
  - group:oncall-payments@example.com
  role: roles/cloudsql.client
etag: BwYh0Z9pQ2s=
version: 3
```

### 5.5 Keyless workload identity on GKE — full manifest set

`k8s/serviceaccount.yaml`
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger-api
  namespace: payments
  annotations:
    # Legacy impersonation model. With direct IAM bindings on the
    # principal:// identifier this annotation is no longer required,
    # but it remains the most widely deployed pattern.
    iam.gke.io/gcp-service-account: ledger-api@pay-api-prod-4471.iam.gserviceaccount.com
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

`k8s/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger-api
  namespace: payments
  labels:
    app: ledger-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ledger-api
  template:
    metadata:
      labels:
        app: ledger-api
    spec:
      serviceAccountName: ledger-api
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      nodeSelector:
        cloud.google.com/gke-nodepool: confidential-pool
      containers:
        - name: api
          # Digest-pinned. Binary Authorization will reject anything unsigned.
          image: europe-west1-docker.pkg.dev/pay-api-prod-4471/apps/ledger-api@sha256:6b1e0f7f0b9c3f7d3a2e1c5a9d8b7f6e5d4c3b2a1908f7e6d5c4b3a2918f7e6d
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            # No credentials here. The metadata server mints tokens.
            - name: GOOGLE_CLOUD_PROJECT
              value: pay-api-prod-4471
            - name: SPANNER_INSTANCE
              value: ledger-eu
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ledger-api-default-deny
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ledger-api-allow
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: ledger-api
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # DNS
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
    # Google APIs via Private Google Access (restricted VIP)
    - to:
        - ipBlock:
            cidr: 199.36.153.4/30
      ports:
        - protocol: TCP
          port: 443
    # GKE metadata server for token minting
    - to:
        - ipBlock:
            cidr: 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 988
```

Bind the Kubernetes SA to the Google SA:

```bash
$ gcloud iam service-accounts add-iam-policy-binding \
    ledger-api@pay-api-prod-4471.iam.gserviceaccount.com \
    --role=roles/iam.workloadIdentityUser \
    --member="serviceAccount:pay-api-prod-4471.svc.id.goog[payments/ledger-api]"
Updated IAM policy for serviceAccount [ledger-api@pay-api-prod-4471.iam.gserviceaccount.com].
bindings:
- members:
  - serviceAccount:pay-api-prod-4471.svc.id.goog[payments/ledger-api]
  role: roles/iam.workloadIdentityUser
etag: BwYh1A2bC3d=
version: 1
```

Verify from inside the pod that the identity is the Google SA and no key file exists:

```bash
$ kubectl -n payments exec -it deploy/ledger-api -- \
    curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
ledger-api@pay-api-prod-4471.iam.gserviceaccount.com

$ kubectl -n payments exec -it deploy/ledger-api -- ls /var/secrets 2>&1
ls: cannot access '/var/secrets': No such file or directory
```

### 5.6 Terraform: the same posture as code

`security.tf`
```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

locals {
  org_id     = "889201773455"
  prod_folder = "folders/641182299038"
  kms_project = "sec-kms-prod-1180"
}

# ---------------------------------------------------------------------------
# Guardrails
# ---------------------------------------------------------------------------
resource "google_org_policy_policy" "no_sa_keys" {
  name   = "organizations/${local.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${local.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "domain_restricted_sharing" {
  name   = "organizations/${local.org_id}/policies/iam.allowedPolicyMemberDomains"
  parent = "organizations/${local.org_id}"

  spec {
    rules {
      values {
        allowed_values = ["is:C03xk9qz1"]
      }
    }
  }
}

resource "google_org_policy_policy" "eu_only" {
  name   = "${local.prod_folder}/policies/gcp.resourceLocations"
  parent = local.prod_folder

  spec {
    inherit_from_parent = false
    rules {
      values {
        allowed_values = ["in:eu-locations"]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# CMEK: key ring, key, rotation, and the service-agent grant everyone forgets
# ---------------------------------------------------------------------------
resource "google_kms_key_ring" "ledger" {
  project  = local.kms_project
  name     = "ledger-eu"
  location = "europe-west1"
}

resource "google_kms_crypto_key" "ledger_data" {
  name            = "ledger-data"
  key_ring        = google_kms_key_ring.ledger.id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "HSM" # FIPS 140-2 Level 3
  }

  lifecycle {
    prevent_destroy = true
  }
}

data "google_storage_project_service_account" "gcs_agent" {
  project = "pay-api-prod-4471"
}

# Without this binding the bucket create fails with a KMS permission error.
resource "google_kms_crypto_key_iam_member" "gcs_agent_use" {
  crypto_key_id = google_kms_crypto_key.ledger_data.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs_agent.email_address}"
}

resource "google_storage_bucket" "ledger_archive" {
  project                     = "pay-api-prod-4471"
  name                        = "pay-ledger-archive-eu"
  location                    = "EU"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning { enabled = true }

  encryption {
    default_kms_key_name = google_kms_crypto_key.ledger_data.id
  }

  retention_policy {
    retention_period = 220752000 # 7 years, regulatory hold
    is_locked        = false     # flip to true only when you are certain
  }

  logging {
    log_bucket        = "pay-audit-logs-eu"
    log_object_prefix = "gcs-access/"
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_agent_use]
}

# ---------------------------------------------------------------------------
# Org-wide audit log sink, immutable
# ---------------------------------------------------------------------------
resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-to-bq"
  org_id           = local.org_id
  include_children = true
  destination      = "bigquery.googleapis.com/projects/sec-logging-prod-2201/datasets/cloud_audit"

  filter = <<-EOT
    logName:"logs/cloudaudit.googleapis.com%2Factivity" OR
    logName:"logs/cloudaudit.googleapis.com%2Fdata_access" OR
    logName:"logs/cloudaudit.googleapis.com%2Fsystem_event" OR
    logName:"logs/cloudaudit.googleapis.com%2Fpolicy"
  EOT
}
```

### 5.7 Enabling Data Access audit logs (off by default — the classic gap)

Admin Activity logs are always on and free. **Data Access logs are opt-in** (except BigQuery) and are what tells you *who read the data*.

`audit/policy.yaml`
```yaml
auditConfigs:
  - service: allServices
    auditLogConfigs:
      - logType: ADMIN_READ
      - logType: DATA_READ
      - logType: DATA_WRITE
        exemptedMembers:
          - serviceAccount:high-volume-etl@pay-api-prod-4471.iam.gserviceaccount.com
bindings:
  - members:
      - group:platform-sre@example.com
    role: roles/viewer
etag: BwYh0Z9pQ2s=
version: 3
```

```bash
$ gcloud projects set-iam-policy pay-api-prod-4471 audit/policy.yaml
Updated IAM policy for project [pay-api-prod-4471].

$ gcloud projects get-iam-policy pay-api-prod-4471 \
    --format="yaml(auditConfigs)"
auditConfigs:
- auditLogConfigs:
  - logType: ADMIN_READ
  - logType: DATA_READ
  - exemptedMembers:
    - serviceAccount:high-volume-etl@pay-api-prod-4471.iam.gserviceaccount.com
    logType: DATA_WRITE
  service: allServices
```

**Cost trade-off (real, and it bites):** Data Access logs on a high-throughput Cloud Storage or Spanner workload can generate hundreds of GB/day. Enable per-service, exempt known bulk service accounts, and route to a BigQuery sink with partition expiration rather than keeping them in the `_Default` log bucket.

---

## 6. Encryption: at rest, in transit, in use

### 6.1 Envelope encryption — the default, with no action from you

```
Object / row / block
   │
   ├─ split into chunks
   │
   ▼
Each chunk ──AES-256-GCM──▶ ciphertext
   with a unique DEK (Data Encryption Key)
                 │
                 ▼
        DEK is itself encrypted (wrapped) by a KEK
                 │
                 ▼
        KEK lives in Google's internal KMS (Keystore)
                 │
                 ▼
        Keystore's own root keys live in Root KMS,
        backed by hardware, distributed, tightly ACL'd
```

Wrapped DEKs are stored **next to the data**; the KEK never leaves KMS. Rotating the KEK re-wraps DEKs — it does not require re-encrypting petabytes.

### 6.2 Key management options — full trade-off table

| Option | Where key material lives | Who can destroy the key | Google can access data if compelled? | Latency / availability impact | Typical driver |
|---|---|---|---|---|---|
| **Google-managed (GMEK)** — default | Google internal Keystore | Google (lifecycle-managed) | Yes | None | Default; zero operational cost |
| **CMEK** (Cloud KMS, software) | Cloud KMS, Google infra | **You** | Yes (key is on Google infra) | Small; KMS is a dependency of the data service | Auditability, crypto-shredding, key rotation policy |
| **CMEK with HSM** | Cloud HSM, FIPS 140-2 L3 | **You** | Yes | Slightly higher than software KMS | FIPS requirement |
| **Cloud EKM** | **Third-party manager outside Google** (Fortanix, Thales, Virtru, Equinix) | **You** | **No** — key never enters Google | Highest; external round trip on unwrap; external manager becomes an availability dependency for your data | External key custody, sovereignty |
| **EKM + Key Access Justifications** | External | You | No, and you see + can auto-deny a justification per access | As EKM | Strongest control; regulated sovereignty |
| **CSEK** (customer-supplied) | **You**, sent in each API call | You | No (Google keeps it only in memory) | You must supply the key on every operation | Narrow: Compute Engine disks and Cloud Storage only. Lose the key → data is unrecoverable |

**Crypto-shredding** is the operational reason CMEK matters most: destroying a key version renders every object encrypted under it permanently unreadable, which satisfies "delete this tenant's data" faster and more provably than issuing millions of delete calls.

```bash
$ gcloud kms keys versions destroy 3 \
    --key=ledger-data --keyring=ledger-eu --location=europe-west1 \
    --project=sec-kms-prod-1180
You are about to destroy version [3] of key [ledger-data].
Do you want to continue (Y/n)?  Y
Destroyed version [3] of key [ledger-data].
name: projects/sec-kms-prod-1180/locations/europe-west1/keyRings/ledger-eu/cryptoKeys/ledger-data/cryptoKeyVersions/3
state: DESTROY_SCHEDULED
destroyTime: '2026-10-08T11:19:44.220Z'   # 24-hour minimum, default 30 days
```

Note `DESTROY_SCHEDULED`: the destruction is delayed (configurable, minimum 24 h) precisely so an accidental or malicious destroy can be restored.

### 6.3 Encryption in transit

| Path | Mechanism | Notes |
|---|---|---|
| Internet → Google edge (GFE) | TLS 1.2/1.3, BoringSSL, automatic cert management on load balancers | The GFE terminates and is the DDoS/L7 chokepoint |
| Google edge → your backend (same VPC) | Encrypted at the network layer where it leaves physical boundaries | Traffic on Google's private WAN between DCs is encrypted at the physical/network layer |
| Google service ↔ Google service (RPC) | **ALTS** (Application Layer Transport Security) — mutual auth using service identities, not hostnames | Not TLS; an internal protocol with per-service identity |
| Workload ↔ Google APIs | TLS to `*.googleapis.com`, optionally via **Private Google Access** / **Private Service Connect** so traffic never touches a public IP | `restricted.googleapis.com` (199.36.153.4/30) only resolves services supported by VPC-SC |
| Pod ↔ Pod (GKE) | Not encrypted by default; add a service mesh (Cloud Service Mesh mTLS) or Dataplane V2 with inter-node transparent encryption | A common audit finding |

### 6.4 Encryption in use — Confidential Computing

Encryption at rest and in transit leave a gap: plaintext in RAM, visible in principle to the hypervisor. Confidential VMs close it by encrypting memory with a key generated and held in the CPU, unavailable to the host.

```bash
$ gcloud compute instances create ledger-confidential-1 \
    --project=pay-api-prod-4471 \
    --zone=europe-west1-b \
    --machine-type=n2d-standard-8 \
    --confidential-compute-type=SEV_SNP \
    --min-cpu-platform="AMD Milan" \
    --maintenance-policy=TERMINATE \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --no-address \
    --service-account=ledger-api@pay-api-prod-4471.iam.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud
Created [https://www.googleapis.com/compute/v1/projects/pay-api-prod-4471/zones/europe-west1-b/instances/ledger-confidential-1].
NAME                   ZONE            MACHINE_TYPE   INTERNAL_IP  EXTERNAL_IP  STATUS
ledger-confidential-1  europe-west1-b  n2d-standard-8 10.20.4.19                RUNNING
```

Verify the memory encryption is actually active:

```bash
$ gcloud compute ssh ledger-confidential-1 --zone=europe-west1-b --tunnel-through-iap \
    --command="dmesg | grep -i -E 'sev|memory encryption'"
[    0.000000] Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
[    0.318442] SEV-SNP: RMP table physical address [0x0000000035600000 - 0x0000000075afffff]
```

**Trade-off table:**

| | Standard VM | Shielded VM | Confidential VM (SEV-SNP / TDX) |
|---|---|---|---|
| Protects against | — | Boot-level rootkits, kernel tampering | Malicious/compromised hypervisor, memory scraping |
| Mechanism | — | UEFI Secure Boot, vTPM, Measured Boot, integrity monitoring | Per-VM memory encryption key in the CPU + attestation report |
| Performance cost | 0 | ~0 | Low single-digit % typical; workload dependent |
| Machine type constraint | any | most | `n2d`, `c2d`, `c3d` (AMD SEV/SEV-SNP); `c3` (Intel TDX) |
| Live migration | Yes | Yes | **No** — must set `--maintenance-policy=TERMINATE` |
| Cost | base | base | base + confidential compute premium |

The live-migration constraint is the operationally significant one: a Confidential VM is terminated on host maintenance. Design for it with a regional MIG and a `PodDisruptionBudget`, or do not use Confidential Computing for a stateful singleton.

---

## 7. Zero trust: eliminating implicit network trust

### 7.1 The model

| Assumption | Perimeter model (castle-and-moat) | **Zero trust / BeyondCorp** |
|---|---|---|
| Trust source | Network location (inside the VPN = trusted) | Identity + device posture + context, evaluated **per request** |
| VPN | Required for internal apps | Not required; apps are published to the internet behind an identity-aware proxy |
| Lateral movement after compromise | Largely unrestricted | Each hop re-authorized independently |
| Access decision cached for | Session/duration of the VPN tunnel | Per request |
| Google Cloud products | Cloud VPN, firewall rules | **Identity-Aware Proxy (IAP)**, Access Context Manager (access levels), Context-Aware Access, Chrome Enterprise Premium, endpoint verification |

### 7.2 Access level + IAP: complete configuration

`access-levels/corp-trusted.yaml`
```yaml
- name: accessPolicies/419320017722/accessLevels/corp_trusted
  title: Corporate trusted device and geography
  basic:
    combiningFunction: AND
    conditions:
      - regions:
          - ES
          - DE
          - IE
      - devicePolicy:
          requireScreenlock: true
          requireCorpOwned: true
          osConstraints:
            - osType: DESKTOP_MAC
              minimumVersion: "14.0.0"
            - osType: DESKTOP_LINUX
            - osType: DESKTOP_CHROME_OS
              requireVerifiedChromeOs: true
          allowedEncryptionStatuses:
            - ENCRYPTED
      - members:
          - group:employees@example.com
```

```bash
$ gcloud access-context-manager levels replace-all \
    --policy=419320017722 --source-file=access-levels/corp-trusted.yaml
Replaced all access levels in policy [419320017722].

# Publish an internal app through IAP — no VPN, no public path to the backend.
$ gcloud compute backend-services update ledger-admin-backend \
    --global --iap=enabled
Updated [https://www.googleapis.com/compute/v1/projects/pay-api-prod-4471/global/backendServices/ledger-admin-backend].

$ gcloud iap web add-iam-policy-binding \
    --resource-type=backend-services --service=ledger-admin-backend \
    --member="group:ledger-admins@example.com" \
    --role="roles/iap.httpsResourceAccessor" \
    --condition='expression=request.auth.claims.google.access_levels.exists(l, l == "accessPolicies/419320017722/accessLevels/corp_trusted"),title=corp-device-only'
Updated IAM policy for an IAP web resource.
```

Firewall rules must then admit **only** the IAP forwarder range, so the backend has no other reachable path:

```bash
$ gcloud compute firewall-rules create allow-iap-forwarders \
    --network=vpc-prod-eu --direction=INGRESS --action=ALLOW \
    --rules=tcp:8080 --source-ranges=35.235.240.0/20 \
    --target-tags=ledger-admin --priority=1000
Creating firewall...done.

$ gcloud compute firewall-rules create deny-all-ingress \
    --network=vpc-prod-eu --direction=INGRESS --action=DENY \
    --rules=all --source-ranges=0.0.0.0/0 --priority=65534
Creating firewall...done.
```

Same range enables SSH without a bastion or public IP:

```bash
$ gcloud compute ssh ledger-confidential-1 --zone=europe-west1-b --tunnel-through-iap
External IP address was not found; defaulting to using IAP tunneling.
WARNING: To increase the performance of the tunnel, consider installing NumPy.
Linux ledger-confidential-1 6.8.0-1021-gcp #23-Ubuntu SMP x86_64
ledger@ledger-confidential-1:~$
```

---

## 8. VPC Service Controls: the exfiltration boundary IAM cannot express

**The problem restated:** `alice@example.com` holds `roles/bigquery.dataViewer` on `projects/pay-ledger-prod-9922`. She is legitimate. She runs a query from her laptop at home and exports the result to `gs://alice-personal-bucket`. **Every IAM check passes.** IAM has no vocabulary for "this data may not leave this set of projects."

VPC-SC adds that vocabulary: a **service perimeter** around a set of projects, within which specified Google APIs will refuse calls that cross the boundary.

`perimeter/ledger-perimeter.yaml`
```yaml
name: accessPolicies/419320017722/servicePerimeters/ledger_eu
title: ledger_eu
perimeterType: PERIMETER_TYPE_REGULAR
status:
  resources:
    - projects/771820039411   # pay-ledger-prod-9922
    - projects/771820039412   # pay-api-prod-4471
    - projects/771820039413   # sec-kms-prod-1180
  restrictedServices:
    - bigquery.googleapis.com
    - storage.googleapis.com
    - cloudkms.googleapis.com
    - spanner.googleapis.com
    - logging.googleapis.com
    - pubsub.googleapis.com
  accessLevels:
    - accessPolicies/419320017722/accessLevels/corp_trusted
  vpcAccessibleServices:
    enableRestriction: true
    allowedServices:
      - bigquery.googleapis.com
      - storage.googleapis.com
      - cloudkms.googleapis.com
      - spanner.googleapis.com
      - logging.googleapis.com
      - pubsub.googleapis.com
```

`perimeter/egress-rules.yaml` — the narrow, justified holes:
```yaml
- egressFrom:
    identityType: ANY_SERVICE_ACCOUNT
    sources:
      - resource: projects/771820039411
    sourceRestriction: SOURCE_RESTRICTION_ENABLED
  egressTo:
    resources:
      - projects/992047711830          # regulator-facing reporting project
    operations:
      - serviceName: storage.googleapis.com
        methodSelectors:
          - method: google.storage.objects.create
```

`perimeter/ingress-rules.yaml`:
```yaml
- ingressFrom:
    identities:
      - serviceAccount:terraform-prod@sec-cicd-prod-3310.iam.gserviceaccount.com
    sources:
      - accessLevel: accessPolicies/419320017722/accessLevels/corp_trusted
  ingressTo:
    resources:
      - "*"
    operations:
      - serviceName: storage.googleapis.com
        methodSelectors:
          - method: "*"
      - serviceName: cloudkms.googleapis.com
        methodSelectors:
          - method: "*"
```

**Always deploy in dry-run first.** Dry-run populates `spec` instead of `status`; violations are logged, not enforced.

```bash
$ gcloud access-context-manager perimeters dry-run create ledger_eu \
    --policy=419320017722 \
    --perimeter-title="ledger_eu" \
    --perimeter-type=regular \
    --perimeter-resources=projects/771820039411,projects/771820039412,projects/771820039413 \
    --perimeter-restricted-services=bigquery.googleapis.com,storage.googleapis.com,cloudkms.googleapis.com,spanner.googleapis.com \
    --perimeter-access-levels=accessPolicies/419320017722/accessLevels/corp_trusted
Create request issued for: [ledger_eu]
Waiting for operation [operations/accessPolicies/419320017722/servicePerimeters/ledger_eu/create/1757328117410] to complete...done.
Created.
```

Harvest what *would* have been blocked, over a full business cycle (a week minimum — month-end batch jobs are the classic surprise):

```bash
$ gcloud logging read '
    protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"
    AND protoPayload.metadata.dryRun="true"
  ' --organization=889201773455 --freshness=7d --limit=500 \
  --format="table(
      protoPayload.authenticationInfo.principalEmail,
      protoPayload.serviceName,
      protoPayload.methodName,
      protoPayload.metadata.violationReason,
      protoPayload.metadata.ingressViolations[0].targetResource)"
PRINCIPAL_EMAIL                                        SERVICE_NAME             METHOD_NAME                       VIOLATION_REASON              TARGET_RESOURCE
etl-nightly@pay-data-prod-8890.iam.gserviceaccount.com bigquery.googleapis.com  google.cloud.bigquery.v2.JobService.InsertJob  NO_MATCHING_ACCESS_LEVEL  projects/771820039411
backup-agent@ops-prod-1120.iam.gserviceaccount.com     storage.googleapis.com   google.storage.objects.create     RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER  projects/771820039411
alice@example.com                                      bigquery.googleapis.com  google.cloud.bigquery.v2.JobService.Query      NO_MATCHING_ACCESS_LEVEL  projects/771820039411
```

Every line is a decision: add an ingress rule, move the project inside, or accept the block. Only when the dry-run log is quiet do you enforce:

```bash
$ gcloud access-context-manager perimeters dry-run enforce ledger_eu --policy=419320017722
Enforce request issued for: [ledger_eu]
Waiting for operation [operations/...]...done.
Enforced.
```

### 8.1 Which control answers which question

| Question | IAM | Org Policy | Firewall | **VPC-SC** | Cloud Armor |
|---|---|---|---|---|---|
| May this identity call this API? | ✅ | — | — | — | — |
| May this resource be created with this config? | — | ✅ | — | — | — |
| May this packet reach this VM on this port? | — | — | ✅ | — | — |
| May this data leave this set of projects? | ❌ | ❌ | ❌ | **✅** | — |
| May this request from the internet reach my L7 app? | — | — | partial | — | **✅** |
| Blocks a *legitimately authorized* principal? | No | No | No | **Yes** | No |

---

## 9. The edge: DDoS and application-layer defence

### 9.1 Threat landscape mapped to controls

| Threat | Mechanism | Google Cloud control |
|---|---|---|
| Volumetric DDoS (L3/L4) | UDP/SYN flood, amplification | Absorbed by Google's global edge + Cloud Load Balancing anycast, **always on, no configuration** |
| Application DDoS (L7) | HTTP flood, slowloris | Cloud Armor rate limiting + Adaptive Protection (ML-derived signatures) |
| OWASP Top 10 injection | SQLi, XSS, RCE, LFI | Cloud Armor preconfigured WAF rules (ModSecurity CRS derived) |
| Phishing / credential theft | Fake login, MFA fatigue | Phishing-resistant MFA (Titan Security Key / FIDO2), Context-Aware Access, Chrome Enterprise Premium |
| Malware / ransomware | Payload execution, encryption of data | Shielded VM, Binary Authorization, object versioning + **locked** retention policy, SCC threat detection |
| Supply chain | Compromised base image / dependency | Artifact Analysis vulnerability scanning, Binary Authorization attestations, Assured OSS, SLSA provenance |
| Insider / provider access | Support engineer reads content | Access Transparency (visibility), Access Approval (you approve), Key Access Justifications (you can auto-deny) |
| Data exfiltration by authorized user | Copy to personal project | **VPC Service Controls** |
| Misconfiguration | Public bucket, wide IAM | Org Policy, SCC Security Health Analytics, Policy Intelligence recommendations |

### 9.2 Cloud Armor policy — full definition

```bash
$ gcloud compute security-policies create ledger-edge-policy \
    --description="Edge protection for ledger public API" \
    --type=CLOUD_ARMOR
Created [https://www.googleapis.com/compute/v1/projects/pay-api-prod-4471/global/securityPolicies/ledger-edge-policy].

# Default action at the lowest priority
$ gcloud compute security-policies rules update 2147483647 \
    --security-policy=ledger-edge-policy --action=deny-403
Updated [ledger-edge-policy].

# Preconfigured WAF: SQL injection, sensitivity tuned down to reduce FPs
$ gcloud compute security-policies rules create 1000 \
    --security-policy=ledger-edge-policy \
    --expression="evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 2})" \
    --action=deny-403 \
    --description="OWASP CRS 3.3 SQL injection"
Created rule [1000].

$ gcloud compute security-policies rules create 1001 \
    --security-policy=ledger-edge-policy \
    --expression="evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 2})" \
    --action=deny-403 \
    --description="OWASP CRS 3.3 cross-site scripting"
Created rule [1001].

# Rate limiting with a ban, keyed per client IP
$ gcloud compute security-policies rules create 2000 \
    --security-policy=ledger-edge-policy \
    --expression="request.path.matches('/api/v1/')" \
    --action=rate-based-ban \
    --rate-limit-threshold-count=600 \
    --rate-limit-threshold-interval-sec=60 \
    --ban-duration-sec=600 \
    --conform-action=allow \
    --exceed-action=deny-429 \
    --enforce-on-key=IP \
    --description="600 req/min per IP on the API surface"
Created rule [2000].

# Geo allow-list ahead of the deny-all default
$ gcloud compute security-policies rules create 500 \
    --security-policy=ledger-edge-policy \
    --expression="origin.region_code in ['ES','DE','IE','FR','PT','IT']" \
    --action=allow \
    --description="EU market only"
Created rule [500].

# Adaptive Protection (Cloud Armor Enterprise)
$ gcloud compute security-policies update ledger-edge-policy \
    --enable-layer7-ddos-defense
Updated [ledger-edge-policy].

$ gcloud compute backend-services update ledger-public-backend \
    --global --security-policy=ledger-edge-policy
Updated [ledger-public-backend].
```

Inspect what you built:

```bash
$ gcloud compute security-policies describe ledger-edge-policy \
    --format="table(rules[].priority, rules[].action, rules[].description)"
PRIORITY     ACTION          DESCRIPTION
500          allow           EU market only
1000         deny(403)       OWASP CRS 3.3 SQL injection
1001         deny(403)       OWASP CRS 3.3 cross-site scripting
2000         rate_based_ban  600 req/min per IP on the API surface
2147483647   deny(403)       Default rule, higher priority overrides it
```

**Trade-off:** WAF sensitivity 1 → few false positives, weaker coverage; sensitivity 4 → strong coverage, will block legitimate traffic containing SQL-like strings (a search box, a JSON payload with `--`). The correct rollout is `--action=preview` at production sensitivity, harvest `jsonPayload.enforcedSecurityPolicy.outcome="ACCEPT"` versus what *would* have been denied, tune per-rule exclusions, then enforce.

---

## 10. Control, compliance, residency and sovereignty

### 10.1 Four distinct concepts routinely conflated

| Concept | Question it answers | Google Cloud instrument |
|---|---|---|
| **Data residency** | *Where is the data physically stored?* | `gcp.resourceLocations` org policy; regional/dual-region/multi-region resource selection |
| **Data sovereignty** | *Which jurisdiction's law governs the data, and who can technically access it?* | Cloud EKM + Key Access Justifications (key outside Google → Google technically cannot decrypt) |
| **Operational sovereignty** | *Who operates the infrastructure, and can I constrain support to in-region personnel?* | Assured Workloads personnel data-location and support controls; Access Approval |
| **Software sovereignty** | *Can I run my workload elsewhere without lock-in?* | Open standards: Kubernetes, GKE Enterprise / Anthos, open-source APIs, Cloud Run (Knative-derived) |

Residency is the weakest of the four and the one customers most often mistake for the others: data stored *in* Frankfurt is still reachable by a US-jurisdiction entity absent the sovereignty controls.

### 10.2 Assured Workloads

```bash
$ gcloud assured workloads create \
    --location=europe-west1 \
    --organization=889201773455 \
    --display-name="ledger-eu-regions-support" \
    --compliance-regime=EU_REGIONS_AND_SUPPORT \
    --billing-account=billingAccounts/01F3A2-B9C4D1-77E210 \
    --next-rotation-time="2026-12-01T00:00:00Z" \
    --rotation-period="7776000s"
Create request issued.
Waiting for operation [operations/...] to complete...done.
Created workload [organizations/889201773455/locations/europe-west1/workloads/8891029384756].
```

An Assured Workloads folder applies a **control package**: it pins resource locations, restricts which Google personnel may support the workload and from where, enables required org policies, and pre-provisions CMEK. The trade-off is explicit: fewer services are available inside the folder, and some features lag general availability.

| Control package (examples) | Regime | Primary constraint |
|---|---|---|
| `FEDRAMP_MODERATE` / `FEDRAMP_HIGH` | US federal | US data location + screened US personnel |
| `IL4` | US DoD | Stronger personnel and location screening |
| `ITAR` | US export control | US persons only |
| `EU_REGIONS_AND_SUPPORT` | EU | EU data location + EU-based support personnel |
| `CA_REGIONS_AND_SUPPORT` | Canada | Canadian data + support |
| `HIPAA` / `HITRUST` | US healthcare | Applicable-service restriction + BAA |
| `IRS_1075` | US tax data | Location + personnel controls |

### 10.3 Access Transparency and Access Approval

| | **Access Transparency** | **Access Approval** | **Key Access Justifications** |
|---|---|---|---|
| Gives you | A log entry each time Google personnel access your content, with a justification and a ticket reference | An explicit **approve/deny** gate before that access occurs | A justification attached to every *cryptographic* unwrap request, which your external key manager may auto-deny |
| Blocks access? | No — visibility only | **Yes** | **Yes**, and unilaterally, outside Google's control |
| Requires | Support plan tier | Access Transparency enabled | Cloud EKM |

```bash
$ gcloud logging read 'logName:"cloudaudit.googleapis.com%2Faccess_transparency"' \
    --project=pay-api-prod-4471 --limit=3 \
    --format="table(timestamp, protoPayload.metadata.reason[0].type, protoPayload.metadata.reason[0].detail, protoPayload.resourceName)"
TIMESTAMP                       TYPE                    DETAIL                       RESOURCE_NAME
2026-09-04T08:12:44.101Z        CUSTOMER_INITIATED_SUPPORT  Case number: 61024488    projects/771820039412/instances/ledger-api-3
```

`CUSTOMER_INITIATED_SUPPORT` with a case number you opened is the expected shape. An entry with a type you did not initiate is an incident-response trigger.

---

## 11. Detection: Security Command Center and audit logs

### 11.1 Audit log types

| Log type | Default | Cost | Records |
|---|---|---|---|
| **Admin Activity** | **Always on, cannot be disabled** | Free | Config/metadata writes — who created the VM, who changed IAM |
| **Data Access** | **Off** (except BigQuery) | Charged | Who read/wrote data, and API reads of config |
| **System Event** | Always on | Free | Google-initiated actions (live migration, automatic key rotation) |
| **Policy Denied** | Always on when generated | Charged | Denials from VPC-SC and other security policies |

### 11.2 SCC tiers

| | **Standard** | **Premium** | **Enterprise** |
|---|---|---|---|
| Asset inventory, Security Health Analytics (subset) | ✅ | ✅ | ✅ | 
| Full Security Health Analytics + compliance dashboards (CIS, PCI-DSS, NIST, ISO) | — | ✅ | ✅ |
| Event Threat Detection, Container Threat Detection, VM Threat Detection | — | ✅ | ✅ |
| Attack path simulation / exposure scoring | — | ✅ | ✅ |
| Multi-cloud (AWS, Azure) posture, integrated SIEM/SOAR, case management | — | — | ✅ |

```bash
$ gcloud scc findings list 889201773455 \
    --source=- \
    --filter='state="ACTIVE" AND severity="HIGH" OR severity="CRITICAL"' \
    --format="table(finding.category, finding.severity, finding.resourceName.basename(), finding.eventTime)" \
    --limit=8
CATEGORY                          SEVERITY  RESOURCE_NAME             EVENT_TIME
PUBLIC_BUCKET_ACL                 HIGH      legacy-reports-eu         2026-09-07T22:14:03Z
OVER_PRIVILEGED_SERVICE_ACCOUNT   HIGH      etl-nightly               2026-09-07T21:02:55Z
SERVICE_ACCOUNT_KEY_NOT_ROTATED   MEDIUM    reporting-legacy          2026-09-07T20:41:18Z
OPEN_FIREWALL                     CRITICAL  allow-all-legacy-2019     2026-09-07T19:33:07Z
NON_ORG_IAM_MEMBER                HIGH      contractor@gmail.com      2026-09-06T14:20:41Z
```

---

## 12. Verification and failure diagnosis

### 12.1 A verification pass you can run end to end

```bash
# 1. No basic roles anywhere in the org
$ gcloud asset search-all-iam-policies \
    --scope=organizations/889201773455 \
    --query='policy:(roles/owner OR roles/editor)' \
    --format="table(resource, policy.bindings[].role, policy.bindings[].members)" \
  | head -20
RESOURCE                                                              ROLE           MEMBERS
//cloudresourcemanager.googleapis.com/projects/sandbox-dev-1902       roles/editor   ['user:contractor@example.com']

# 2. No external principals
$ gcloud asset search-all-iam-policies \
    --scope=organizations/889201773455 \
    --query='policy:(allUsers OR allAuthenticatedUsers)' \
    --format="value(resource)"
(no output — clean)

# 3. No user-managed service account keys
$ for p in $(gcloud projects list --format='value(projectId)'); do
    for sa in $(gcloud iam service-accounts list --project="$p" --format='value(email)' 2>/dev/null); do
      n=$(gcloud iam service-accounts keys list --iam-account="$sa" \
            --managed-by=user --format='value(name)' 2>/dev/null | wc -l)
      [ "$n" -gt 0 ] && echo "KEY  $p  $sa  ($n)"
    done
  done
KEY  reporting-legacy-3301  bi-extract@reporting-legacy-3301.iam.gserviceaccount.com  (2)

# 4. Buckets without CMEK or without public access prevention
$ gcloud storage buckets list --format="table(name, default_kms_key, public_access_prevention, uniform_bucket_level_access.enabled)"
NAME                     DEFAULT_KMS_KEY                                                                                   PUBLIC_ACCESS_PREVENTION  ENABLED
pay-ledger-archive-eu    projects/sec-kms-prod-1180/locations/europe-west1/keyRings/ledger-eu/cryptoKeys/ledger-data        enforced                  True
legacy-reports-eu                                                                                                          inherited                 False

# 5. Effective org policy resolution at a leaf
$ gcloud org-policies list --project=pay-api-prod-4471 --format="table(constraint, spec.rules[0])"

# 6. Resolve what a principal can actually do (Policy Analyzer)
$ gcloud asset analyze-iam-policy \
    --organization=889201773455 \
    --identity="user:alice@example.com" \
    --format="table(analysisResults[].iamBinding.role, analysisResults[].attachedResourceFullName)"
```

### 12.2 Failure catalogue — symptom → root cause → fix

**A. Organization policy violation**

```
$ gcloud compute instances create web-1 --zone=europe-west1-b --address=""
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Constraint constraints/compute.vmExternalIpAccess violated for project
   pay-api-prod-4471. Add instance projects/pay-api-prod-4471/zones/europe-west1-b/instances/web-1
   to the constraint to use external IP with it.
```
*Root cause:* guardrail working as designed.
*Diagnosis:* `gcloud org-policies describe compute.vmExternalIpAccess --project=... --effective` to find whether it came from the folder or org.
*Fix:* front the workload with a load balancer and Cloud NAT — do not punch a hole. If genuinely required, override at the project with a documented exception and an expiry.

---

**B. VPC Service Controls denial — the hardest to diagnose**

```
$ gcloud storage cp gs://pay-ledger-archive-eu/2026-08.parquet .
ERROR: (gcloud.storage.cp) HTTPError 403: Request is prohibited by organization's policy.
vpcServiceControlsUniqueIdentifier: L7cQ2mF9xR4tYb1oN8pW3sVzKj0aHdGe
```

The message deliberately reveals nothing. The identifier is the join key into the audit log:

```bash
$ gcloud logging read '
    protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"
    AND protoPayload.metadata.vpcServiceControlsUniqueId="L7cQ2mF9xR4tYb1oN8pW3sVzKj0aHdGe"
  ' --organization=889201773455 --limit=1 --format=json
```
```json
{
  "protoPayload": {
    "authenticationInfo": { "principalEmail": "alice@example.com" },
    "methodName": "google.storage.objects.get",
    "serviceName": "storage.googleapis.com",
    "metadata": {
      "dryRun": false,
      "violationReason": "NO_MATCHING_ACCESS_LEVEL",
      "securityPolicyInfo": {
        "servicePerimeterName": "accessPolicies/419320017722/servicePerimeters/ledger_eu"
      },
      "ingressViolations": [
        { "targetResource": "projects/771820039411",
          "servicePerimeter": "accessPolicies/419320017722/servicePerimeters/ledger_eu" }
      ]
    },
    "requestMetadata": { "callerIp": "203.0.113.44" }
  },
  "severity": "ERROR"
}
```

| `violationReason` | Meaning | Fix |
|---|---|---|
| `NO_MATCHING_ACCESS_LEVEL` | Caller is outside the perimeter and matched no access level | Add an ingress rule or bring the caller onto a corp-trusted device/network |
| `RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER` | Source and target projects are in different perimeters | Egress rule, or a perimeter bridge |
| `SERVICE_NOT_ALLOWED_FROM_VPC` | `vpcAccessibleServices` restriction blocks the API from inside the VPC | Add the service to `allowedServices` |
| `NETWORK_NOT_IN_SAME_SERVICE_PERIMETER` | VPC is not associated with the perimeter | Add the host project to the perimeter |

---

**C. CMEK service-agent permission — the most common Terraform failure**

```
$ gcloud storage buckets create gs://ledger-new-eu --location=EU \
    --default-encryption-key=projects/sec-kms-prod-1180/locations/europe-west1/keyRings/ledger-eu/cryptoKeys/ledger-data
ERROR: (gcloud.storage.buckets.create) HTTPError 400: Permission denied on Cloud KMS key.
Please ensure that your Cloud Storage service agent
service-771820039412@gs-project-accounts.iam.gserviceaccount.com
has been granted the Cloud KMS CryptoKey Encrypter/Decrypter role.
```
*Root cause:* each Google service uses a per-project **service agent** identity to touch KMS on your behalf. It is not your workload's service account.
*Fix:*
```bash
$ gcloud kms keys add-iam-policy-binding ledger-data \
    --keyring=ledger-eu --location=europe-west1 --project=sec-kms-prod-1180 \
    --member="serviceAccount:service-771820039412@gs-project-accounts.iam.gserviceaccount.com" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
Updated IAM policy for key [ledger-data].
```
*Note the region rule:* the KMS key must be in the same location as the resource (or `global` where supported). An `EU` multi-region bucket needs a `europe` multi-region key; a `europe-west1` key will be rejected.

---

**D. Workload Identity on GKE returns the node's identity, not the workload's**

```
$ kubectl -n payments exec deploy/ledger-api -- \
    curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
771820039412-compute@developer.gserviceaccount.com
```
*Symptom:* the **default Compute Engine** service account, not `ledger-api@…`.
*Root causes, in order of frequency:*
1. Workload Identity is not enabled on the **node pool** (cluster-level enablement is not enough):
```bash
$ gcloud container node-pools update confidential-pool \
    --cluster=ledger-gke-eu --region=europe-west1 \
    --workload-metadata=GKE_METADATA
```
2. The KSA annotation namespace/name does not exactly match the `workloadIdentityUser` member string.
3. The `roles/iam.workloadIdentityUser` binding is missing on the **Google** service account.

Verify the binding:
```bash
$ gcloud iam service-accounts get-iam-policy \
    ledger-api@pay-api-prod-4471.iam.gserviceaccount.com --format=yaml
bindings:
- members:
  - serviceAccount:pay-api-prod-4471.svc.id.goog[payments/ledger-api]
  role: roles/iam.workloadIdentityUser
```

---

**E. "Why can't this principal do X?" — Policy Troubleshooter**

```bash
$ gcloud policy-troubleshoot iam \
    //cloudresourcemanager.googleapis.com/projects/pay-ledger-prod-9922 \
    --principal-email=alice@example.com \
    --permission=bigquery.tables.getData
access: NOT_GRANTED
explainedPolicies:
- access: NOT_GRANTED
  bindingExplanations:
  - access: NOT_GRANTED
    role: roles/bigquery.dataViewer
    rolePermission: ROLE_PERMISSION_INCLUDED
    condition:
      expression: request.time < timestamp("2026-09-01T00:00:00Z")
    conditionRelevance: HEURISTICAL_RELEVANCE_HIGH
    memberships:
      user:alice@example.com:
        membership: MEMBERSHIP_INCLUDED
  fullResourceName: //cloudresourcemanager.googleapis.com/projects/pay-ledger-prod-9922
```
*Read:* the role does contain the permission and alice is in the binding — but the **IAM condition expired**. This is the tool to reach for before adding any new grant; it prevents the reflex over-grant that creates the next audit finding.

---

**F. Cloud Armor false positive**

```bash
$ gcloud logging read '
    resource.type="http_load_balancer"
    AND jsonPayload.enforcedSecurityPolicy.outcome="DENY"
  ' --project=pay-api-prod-4471 --limit=3 \
  --format="table(
      httpRequest.requestUrl,
      httpRequest.remoteIp,
      jsonPayload.enforcedSecurityPolicy.name,
      jsonPayload.enforcedSecurityPolicy.priority,
      jsonPayload.statusDetails)"
REQUEST_URL                                  REMOTE_IP        NAME                 PRIORITY  STATUS_DETAILS
https://api.example.com/v1/search?q=1--2     198.51.100.7     ledger-edge-policy   1000      denied_by_security_policy
```
*Root cause:* the search string `1--2` matched an SQLi signature.
*Fix:* add a targeted exclusion rather than lowering global sensitivity:
```bash
$ gcloud compute security-policies rules create 900 \
    --security-policy=ledger-edge-policy \
    --expression="request.path.matches('/v1/search')" \
    --action=allow \
    --description="Search endpoint: WAF exclusion, validated server-side with parameterised queries"
```
The description matters: an exclusion is a documented risk acceptance, and it is only defensible because the endpoint uses parameterised queries.

---

## 13. Synthesis: what the exam asks, and what production requires

| Exam-level statement (CDL) | Production-level implication (Platform Architect) |
|---|---|
| "Google secures the infrastructure; you secure what you put in it" | Write down the responsibility matrix *per service* you actually use; the boundary is different for GKE Standard and GKE Autopilot |
| "Data is encrypted at rest and in transit by default" | True, and insufficient for regulated data — decide GMEK vs CMEK vs EKM against a named regulator requirement, and budget for the KMS availability dependency |
| "Least privilege" | No basic roles; groups not users; predefined over custom; conditions with expiry; zero SA keys enforced by org policy |
| "Zero trust means never trust, always verify" | IAP + access levels replacing the VPN; firewall ingress limited to `35.235.240.0/20`; per-request device posture |
| "The cloud helps with compliance" | Google's certifications cover the infrastructure; **your configuration is in scope for your audit**. Assured Workloads narrows the gap; SCC Premium evidences it |
| "Privacy is not security" | Access Transparency/Approval and KAJ are privacy controls; they do not harden anything, and encryption does not satisfy them |
| "IAM protects your data" | IAM protects *access*. Exfiltration by an authorized principal is a VPC-SC problem, and VPC-SC is the single control most estates lack |

**The three things to enable first in any new organization**, ordered by risk reduction per unit of effort:

1. `constraints/iam.disableServiceAccountKeyCreation` + `constraints/iam.allowedPolicyMemberDomains` — removes the two highest-frequency breach vectors structurally.
2. An org-level audit log sink to a separate, restricted logging project — because you cannot investigate what you did not record, and Data Access logs are off by default.
3. A VPC-SC perimeter in **dry-run** around your crown-jewel data projects — costs nothing, blocks nothing, and produces the exfiltration inventory you currently do not have.

---

## 14. References

Official Google sources. Every URL below is a Google-published document.

**Exam guide**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Shared responsibility, shared fate, architecture**
- Shared responsibility and shared fate on Google Cloud — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google Cloud Architecture Framework: Security, privacy and compliance — https://cloud.google.com/architecture/framework/security
- Google Cloud security foundations blueprint — https://cloud.google.com/architecture/security-foundations
- Google infrastructure security design overview — https://cloud.google.com/docs/security/infrastructure/design

**Identity and access**
- IAM overview — https://cloud.google.com/iam/docs/overview
- IAM roles and permissions — https://cloud.google.com/iam/docs/roles-overview
- Deny policies — https://cloud.google.com/iam/docs/deny-overview
- Principal access boundary policies — https://cloud.google.com/iam/docs/principal-access-boundary-policies
- IAM Conditions — https://cloud.google.com/iam/docs/conditions-overview
- Best practices for service accounts — https://cloud.google.com/iam/docs/best-practices-service-accounts
- Workload Identity Federation — https://cloud.google.com/iam/docs/workload-identity-federation
- Workforce Identity Federation — https://cloud.google.com/iam/docs/workforce-identity-federation
- GKE Workload Identity Federation — https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Policy Troubleshooter — https://cloud.google.com/policy-intelligence/docs/troubleshoot-access

**Resource hierarchy and guardrails**
- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Organization Policy Service — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Custom organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints

**Encryption and key management**
- Default encryption at rest — https://cloud.google.com/docs/security/encryption/default-encryption
- Encryption in transit — https://cloud.google.com/docs/security/encryption-in-transit
- Customer-managed encryption keys (CMEK) — https://cloud.google.com/kms/docs/cmek
- Cloud External Key Manager (EKM) — https://cloud.google.com/kms/docs/ekm
- Key Access Justifications — https://cloud.google.com/cloud-provider-access-management/key-access-justifications/docs/overview
- Customer-supplied encryption keys — https://cloud.google.com/compute/docs/disks/customer-supplied-encryption
- Cloud HSM — https://cloud.google.com/kms/docs/hsm
- Confidential Computing — https://cloud.google.com/confidential-computing/docs
- Shielded VM — https://cloud.google.com/security/shielded-cloud/shielded-vm

**Network and perimeter**
- VPC Service Controls overview — https://cloud.google.com/vpc-service-controls/docs/overview
- VPC-SC dry-run mode — https://cloud.google.com/vpc-service-controls/docs/dry-run-mode
- VPC-SC troubleshooting — https://cloud.google.com/vpc-service-controls/docs/troubleshooting
- Access Context Manager — https://cloud.google.com/access-context-manager/docs/overview
- Identity-Aware Proxy — https://cloud.google.com/iap/docs/concepts-overview
- Private Google Access — https://cloud.google.com/vpc/docs/private-google-access
- Cloud Armor security policies — https://cloud.google.com/armor/docs/security-policy-overview
- Cloud Armor preconfigured WAF rules — https://cloud.google.com/armor/docs/waf-rules
- Cloud Armor Adaptive Protection — https://cloud.google.com/armor/docs/adaptive-protection-overview
- BeyondCorp / zero trust — https://cloud.google.com/beyondcorp

**Detection, compliance, privacy**
- Security Command Center overview — https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Cloud Audit Logs — https://cloud.google.com/logging/docs/audit
- Configuring Data Access audit logs — https://cloud.google.com/logging/docs/audit/configure-data-access
- Sensitive Data Protection — https://cloud.google.com/sensitive-data-protection/docs
- Assured Workloads — https://cloud.google.com/assured-workloads/docs/overview
- Compliance offerings and resource centre — https://cloud.google.com/security/compliance/offerings
- Access Transparency — https://cloud.google.com/cloud-provider-access-management/access-transparency/docs/overview
- Access Approval — https://cloud.google.com/cloud-provider-access-management/access-approval/docs/overview
- Privacy commitments for Google Cloud — https://cloud.google.com/privacy
- Binary Authorization — https://cloud.google.com/binary-authorization/docs
- Risk Protection Program — https://cloud.google.com/security/risk-protection-program