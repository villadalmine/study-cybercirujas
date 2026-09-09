# Topic 5.2 — Guided Exercises

## Describe the business value of making Google part of an organization's security team: defense-in-depth and a multilayered approach to cloud security

**Certification:** Google Cloud Digital Leader (exam version 2026-08-12)
**Domain weight:** 9.0
**Primary reference:** [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf)

---

## How to use this document

Every exercise is a **layer** of the defence-in-depth stack. You execute the layer, observe what Google already did for you, and then answer the business question the exam actually asks: *what did that layer buy the organization?*

The Cloud Digital Leader exam is not a hands-on exam. You are running these commands anyway, because "Google is part of your security team" is an empty slogan until you have seen a bucket encrypted with no work on your part, an org policy block a mistake that has not happened yet, and Security Command Center name a misconfiguration you did not know you had.

### Prerequisites

| Requirement | Why |
|---|---|
| A Google Cloud project with billing enabled | Exercises 4, 5, 8 create billable resources |
| `gcloud` CLI ≥ 470.0.0, authenticated | All exercises |
| Organization-level roles (`roles/orgpolicy.policyAdmin`, `roles/securitycenter.admin`, `roles/accesscontextmanager.policyAdmin`) | Exercises 2, 5, 6 |
| A Cloud Identity or Workspace organization | Exercises 2, 3, 5, 6, 9 |

> **If you have no organization node** (a personal `gmail.com` account creates projects with no parent), the org-scoped steps are marked **`[ORG]`**. Read them, run the project-scoped alternative given in each block, and answer the questions from the documentation. The business reasoning is the examinable part; the org node is not.

> **Cost warning.** Exercise 4 creates a Cloud KMS key ring — **key rings and keys cannot be deleted**, only their key versions destroyed, and each active key version bills monthly. Exercise 8 creates a Confidential VM (a premium over standard N2D pricing). Delete the VM when you finish. Everything else in this document is free or free-tier.

### Set your working variables

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export ORG_ID="$(gcloud organizations list --format='value(ID)' | head -n1)"   # [ORG]
export REGION="us-central1"
export ZONE="us-central1-a"
echo "project=$PROJECT_ID number=$PROJECT_NUMBER org=${ORG_ID:-<none>}"
```

---

## Exercise 1 — Find the security work Google already did before you logged in

**Layer:** infrastructure and cryptography
**Business question:** what is the value of a control you did not have to build, staff, or audit?

### Steps

1. Create a bucket with no security flags at all — the laziest possible action:

    ```bash
    gcloud storage buckets create "gs://${PROJECT_ID}-defaults" --location="$REGION"
    ```

2. Ask what encryption that bucket uses:

    ```bash
    gcloud storage buckets describe "gs://${PROJECT_ID}-defaults" \
      --format="json(name, location, default_kms_key, uniform_bucket_level_access)"
    ```

    Illustrative output:

    ```json
    {
      "name": "example-proj-defaults",
      "location": "US-CENTRAL1",
      "uniform_bucket_level_access": {
        "enabled": true,
        "lockedTime": "2026-12-07T00:00:00.000Z"
      }
    }
    ```

3. Note what is **missing** from that output: there is no `default_kms_key`, and there is no `encryption` block. Now read the platform's statement about what happens to that data anyway:

    > *"Cloud Storage always encrypts your data on the server side, before it is written to disk, at no additional charge."*
    > — [Default encryption at rest](https://cloud.google.com/docs/security/encryption/default-encryption)

4. Upload an object and confirm the server-side encryption is reported per object:

    ```bash
    echo "layer-1 test" > /tmp/l1.txt
    gcloud storage cp /tmp/l1.txt "gs://${PROJECT_ID}-defaults/l1.txt"
    gcloud storage objects describe "gs://${PROJECT_ID}-defaults/l1.txt" \
      --format="json(name, size, storage_class, crc32c_hash, customer_encryption)"
    ```

5. Inspect what protects the same data *in motion*. Trace a request from your workstation to the API and observe where TLS terminates:

    ```bash
    curl -sS -o /dev/null -w 'http=%{http_code} tls=%{ssl_verify_result} ip=%{remote_ip}\n' \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://storage.googleapis.com/storage/v1/b/${PROJECT_ID}-defaults"
    ```

    Illustrative output:

    ```
    http=200 tls=0 ip=142.250.65.80
    ```

    That IP is a **Google Front End (GFE)**, not the storage servers. The GFE terminates TLS, absorbs volumetric DoS, and forwards the request over Google's private backbone using **ALTS** (Application Layer Transport Security), Google's internal mutually-authenticated RPC encryption. See [Encryption in transit](https://cloud.google.com/docs/security/encryption-in-transit) and [Google infrastructure security design](https://cloud.google.com/docs/security/infrastructure/design).

6. Write down, on paper, the list of controls you did **not** configure but that are now protecting this bucket. A correct list includes at minimum: AES-256 encryption at rest with per-chunk data encryption keys; key wrapping and rotation in Google's internal KMS; TLS termination at the GFE with a Google-managed certificate; ALTS on the internal hop; DDoS absorption at the edge; hardware root of trust (**Titan**) attesting the machines that serve the request; physical datacentre security; secure boot and provenance for the host firmware.

### Verify your understanding

**Q1.1** The `describe` output showed no `encryption` field. Explain in one sentence why that is *not* evidence that the object is unencrypted, and what the field's absence actually indicates.

**Q1.2** A CFO asks: "We already pay for a disk-encryption product on-premises. Why is Google's default encryption a *business* benefit rather than just a technical one?" Give two distinct business arguments.

**Q1.3** Name the three encryption states a workload's data can be in, and say which of the three is *not* covered by the defaults you just observed.

**Q1.4** Your organization's auditor asks for evidence that Google encrypts traffic between its own datacentres. Which two artefacts would you present — one a technology name, one a document class — without needing to run anything in your project?

---

## Exercise 2 — The governance layer: prevent the mistake that has not happened yet

**Layer:** preventive guardrails
**Business question:** what is a control worth if it makes an entire class of incident impossible, org-wide, permanently?

### Steps

1. **`[ORG]`** List the constraints available on your organization:

    ```bash
    gcloud org-policies list --organization="$ORG_ID"
    ```

2. Ask what the *effective* policy is for public IP addresses on VMs — "effective" means the value after inheritance down the hierarchy is resolved:

    ```bash
    gcloud org-policies describe constraints/compute.vmExternalIpAccess \
      --organization="$ORG_ID" --effective
    ```

    Illustrative output on an unhardened organization:

    ```yaml
    name: organizations/123456789012/policies/compute.vmExternalIpAccess
    spec:
      rules:
      - allowValues:
        - ALLOW_ALL
    ```

3. **Project-scoped alternative if you have no org node** — every command below works with `--project="$PROJECT_ID"` instead of `--organization="$ORG_ID"`. The lesson is identical; only the blast radius of the guardrail changes.

4. Write a policy that stops the single most common cloud credential leak — long-lived service account keys checked into a repository:

    ```bash
    cat > /tmp/no-sa-keys.yaml <<EOF
    name: organizations/${ORG_ID}/policies/iam.disableServiceAccountKeyCreation
    spec:
      rules:
      - enforce: true
    EOF
    gcloud org-policies set-policy /tmp/no-sa-keys.yaml
    ```

5. Prove the guardrail works by trying to violate it:

    ```bash
    gcloud iam service-accounts create leaky-sa --display-name="Guardrail test" || true
    gcloud iam service-accounts keys create /tmp/leak.json \
      --iam-account="leaky-sa@${PROJECT_ID}.iam.gserviceaccount.com"
    ```

    Illustrative output:

    ```
    ERROR: (gcloud.iam.service-accounts.keys.create) FAILED_PRECONDITION: Key creation is
    not allowed on this service account.
    ```

    Note *who* enforced that: not a script, not a scanner, not a reviewer. The API refused. There is no window between the mistake and its detection, because there is no mistake.

6. Now do the same thing **without** breaking anything — use org policy dry-run mode, which evaluates and logs violations while still allowing the action:

    ```bash
    cat > /tmp/dryrun-extip.yaml <<EOF
    name: organizations/${ORG_ID}/policies/compute.vmExternalIpAccess
    dryRunSpec:
      rules:
      - denyAll: true
    EOF
    gcloud org-policies set-policy /tmp/dryrun-extip.yaml
    ```

7. Read the would-be violations out of Cloud Logging after some hours of normal activity:

    ```bash
    gcloud logging read \
      'protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.OrgPolicyViolationInfo"' \
      --organization="$ORG_ID" --limit=20 --format="value(protoPayload.resourceName)"
    ```

8. Clean up so later exercises are not blocked:

    ```bash
    gcloud org-policies delete constraints/iam.disableServiceAccountKeyCreation --organization="$ORG_ID"
    gcloud org-policies delete constraints/compute.vmExternalIpAccess --organization="$ORG_ID"
    gcloud iam service-accounts delete "leaky-sa@${PROJECT_ID}.iam.gserviceaccount.com" --quiet
    ```

Reference: [Organization Policy Service overview](https://cloud.google.com/resource-manager/docs/organization-policy/overview).

### Verify your understanding

**Q2.1** Classify each of these as **preventive**, **detective**, or **corrective**: (a) an org policy denying external IPs, (b) a Security Command Center finding titled `PUBLIC_IP_ADDRESS`, (c) a Cloud Function that deletes public IPs nightly. Which of the three has the lowest total cost of ownership, and why?

**Q2.2** Explain the business purpose of **dry-run mode** to a VP of Engineering who is afraid a security mandate will break production on a Friday.

**Q2.3** The resource hierarchy is Organization → Folder → Project → Resource. Give one business reason a company would set a strict policy at the organization node and grant an *exception* at a single folder, rather than setting the policy on each project.

**Q2.4** Your company acquires a competitor and inherits 400 of their projects. Describe, in two sentences, how the hierarchy plus org policy turns a 400-project security remediation into a bounded piece of work.

---

## Exercise 3 — The identity layer: least privilege, discovered by machine

**Layer:** authentication and authorization
**Business question:** identity is the new perimeter — what does it cost to maintain that perimeter by hand, and who pays for it?

### Steps

1. Dump the current IAM policy of your project and count the bindings:

    ```bash
    gcloud projects get-iam-policy "$PROJECT_ID" --format=json > /tmp/iam.json
    jq '.bindings | length' /tmp/iam.json
    jq -r '.bindings[] | select(.role | test("roles/(owner|editor)$")) | "\(.role)\t\(.members | join(", "))"' /tmp/iam.json
    ```

    Illustrative output:

    ```
    7
    roles/owner	user:founder@example.com
    roles/editor	serviceAccount:123456789012-compute@developer.gserviceaccount.com
    ```

    `roles/editor` on the default compute service account is a basic role with write access to nearly every service in the project. Every VM using it inherits that.

2. Ask Google to find the over-permission for you. **IAM Recommender** analyses 90 days of actual API usage and proposes a narrower role:

    ```bash
    gcloud services enable recommender.googleapis.com policyanalyzer.googleapis.com
    gcloud recommender recommendations list \
      --project="$PROJECT_ID" \
      --location=global \
      --recommender=google.iam.policy.Recommender \
      --format="table(name.basename(), primaryImpact.category, stateInfo.state, description)"
    ```

    Illustrative output:

    ```
    NAME                                  CATEGORY  STATE   DESCRIPTION
    b1c2d3e4-5f60-7182-93a4-b5c6d7e8f901  SECURITY  ACTIVE  Replace the current role with a smaller role to cover the permissions needed.
    ```

    Note the economics: this analysis is produced continuously, at no marginal cost to you, on every project in the organization. An access-review consultant produces the same artefact once per audit cycle, at a day rate.

3. Answer the auditor's question — "who can read this bucket, by any path?" — with **Policy Analyzer**, which resolves inherited bindings, group membership, and conditions:

    ```bash
    gcloud asset analyze-iam-policy \
      --organization="$ORG_ID" \
      --full-resource-name="//storage.googleapis.com/${PROJECT_ID}-defaults" \
      --permissions="storage.objects.get" \
      --format=json | jq -r '.mainAnalysis.analysisResults[].iamBinding.members[]' | sort -u
    ```

    Project-scoped alternative:

    ```bash
    gcloud asset analyze-iam-policy --project="$PROJECT_ID" \
      --permissions="storage.objects.get" --format=json | jq '.mainAnalysis.analysisResults | length'
    ```

4. Move from "who are you" to "who are you, from where, on what device". Inspect the access-level surface that backs **context-aware access** and **Chrome Enterprise Premium** (formerly BeyondCorp Enterprise):

    ```bash
    gcloud access-context-manager policies list --organization="$ORG_ID"
    export POLICY_ID="$(gcloud access-context-manager policies list \
      --organization="$ORG_ID" --format='value(name)' | sed 's|accessPolicies/||')"

    cat > /tmp/level.yaml <<'EOF'
    - devicePolicy:
        requireScreenlock: true
        requireCorpOwned: true
        osConstraints:
        - osType: DESKTOP_CHROME_OS
        - osType: DESKTOP_MAC
      regions:
      - AR
      - ES
      - US
    EOF

    gcloud access-context-manager levels create trusted_corp_device \
      --policy="$POLICY_ID" \
      --title="Corp-owned, screenlocked, allowed regions" \
      --basic-level-spec=/tmp/level.yaml \
      --combine-function=AND
    ```

5. Read that YAML back as a sentence: *access requires a corporate-owned device, with a screen lock, running an approved OS, connecting from one of three countries* — and note that **no VPN appears anywhere in it**. That is the zero-trust substitution: the trust decision moved from network location to verified identity plus device posture.

References: [Role recommendations](https://cloud.google.com/policy-intelligence/docs/role-recommendations-overview), [Chrome Enterprise Premium](https://cloud.google.com/chrome-enterprise-premium/docs), [BeyondCorp zero trust model](https://cloud.google.com/beyondcorp).

### Verify your understanding

**Q3.1** State the difference between **authentication** and **authorization**, and name the Google Cloud service primarily responsible for each.

**Q3.2** IAM Recommender needed 90 days of usage data. What business risk does an organization take by acting on a recommendation *before* that window is full, and how would you phrase that risk to a non-technical steering committee?

**Q3.3** A retail company has 3,000 seasonal staff hired every November and released in January. Explain why the zero-trust model of Exercise 3 step 4 scales better financially than issuing 3,000 VPN accounts.

**Q3.4** Which of these is the strongest evidence that "Google is part of your security team" rather than merely "Google sells you a security tool": (a) the org policy in Exercise 2, (b) the IAM recommendation in step 2, (c) the access level in step 4? Defend your choice in two sentences.

---

## Exercise 4 — The data layer: key custody and finding the sensitive data you forgot about

**Layer:** data protection
**Business question:** who holds the keys, who can be compelled to hand them over, and what is that worth to a regulated business?

### Steps

1. Create a key ring and a rotating symmetric key. **This is the billable step** — key rings and keys are permanent:

    ```bash
    gcloud services enable cloudkms.googleapis.com
    gcloud kms keyrings create cdl-lab --location="$REGION"
    gcloud kms keys create bucket-cmek \
      --location="$REGION" --keyring=cdl-lab \
      --purpose=encryption \
      --rotation-period=90d \
      --next-rotation-time="$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)"
    gcloud kms keys describe bucket-cmek --location="$REGION" --keyring=cdl-lab \
      --format="yaml(name, purpose, rotationPeriod, versionTemplate)"
    ```

2. Grant the Cloud Storage service agent permission to use the key, then create a CMEK-encrypted bucket:

    ```bash
    export GCS_AGENT="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"
    gcloud kms keys add-iam-policy-binding bucket-cmek \
      --location="$REGION" --keyring=cdl-lab \
      --member="serviceAccount:${GCS_AGENT}" \
      --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"

    gcloud storage buckets create "gs://${PROJECT_ID}-cmek" \
      --location="$REGION" \
      --default-encryption-key="projects/${PROJECT_ID}/locations/${REGION}/keyRings/cdl-lab/cryptoKeys/bucket-cmek"

    gcloud storage buckets describe "gs://${PROJECT_ID}-cmek" --format="value(default_kms_key)"
    ```

3. Demonstrate what "you hold the keys" means operationally — disable the key and watch the data become unreadable *without deleting a single byte*:

    ```bash
    echo "regulated payload" > /tmp/reg.txt
    gcloud storage cp /tmp/reg.txt "gs://${PROJECT_ID}-cmek/reg.txt"

    gcloud kms keys versions disable 1 --key=bucket-cmek --keyring=cdl-lab --location="$REGION"
    sleep 30
    gcloud storage cat "gs://${PROJECT_ID}-cmek/reg.txt"
    ```

    Illustrative output:

    ```
    ERROR: (gcloud.storage.cat) HTTPError 400: Cloud KMS error when decrypting: key version
    is not enabled, current state is: DISABLED
    ```

    Re-enable it:

    ```bash
    gcloud kms keys versions enable 1 --key=bucket-cmek --keyring=cdl-lab --location="$REGION"
    ```

    That single toggle is **crypto-shredding**: an instant, provable, jurisdiction-independent revocation of access to arbitrarily large datasets. It is the mechanism behind many "right to erasure" and offboarding controls.

4. Now find the sensitive data nobody told you about. Call **Sensitive Data Protection** (formerly Cloud DLP) on a sample string:

    ```bash
    gcloud services enable dlp.googleapis.com

    cat > /tmp/inspect.json <<'EOF'
    {
      "item": {
        "value": "Ticket #4471 from Ana Ruiz, ana.ruiz@example.com, card 4111 1111 1111 1111, phone +54 11 4555 0100"
      },
      "inspectConfig": {
        "infoTypes": [
          {"name": "PERSON_NAME"},
          {"name": "EMAIL_ADDRESS"},
          {"name": "CREDIT_CARD_NUMBER"},
          {"name": "PHONE_NUMBER"}
        ],
        "minLikelihood": "POSSIBLE",
        "includeQuote": true
      }
    }
    EOF

    curl -sS -X POST \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      -d @/tmp/inspect.json \
      "https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/global/content:inspect" \
    | jq -r '.result.findings[] | "\(.infoType.name)\t\(.likelihood)\t\(.quote)"'
    ```

    Illustrative output:

    ```
    PERSON_NAME	        LIKELY	    Ana Ruiz
    EMAIL_ADDRESS	    LIKELY	    ana.ruiz@example.com
    CREDIT_CARD_NUMBER	VERY_LIKELY	4111 1111 1111 1111
    PHONE_NUMBER	    LIKELY	    +54 11 4555 0100
    ```

5. Repeat the call with `"deidentifyConfig"` replacing `"inspectConfig"` against the `content:deidentify` endpoint, using a `characterMaskConfig`, and observe that the record survives with the identifiers masked. Note the business consequence: the analytics team keeps the dataset, the privacy office keeps the guarantee, and neither has to negotiate with the other.

6. Clean up the VM-free resources:

    ```bash
    gcloud storage rm -r "gs://${PROJECT_ID}-cmek" "gs://${PROJECT_ID}-defaults"
    ```

References: [Cloud KMS](https://cloud.google.com/kms/docs), [Cloud KMS Autokey](https://cloud.google.com/kms/docs/autokey/overview), [Sensitive Data Protection](https://cloud.google.com/sensitive-data-protection/docs).

### Verify your understanding

**Q4.1** Rank these four key-management options by *degree of customer control*, lowest to highest: CMEK, Google-managed default encryption, Cloud External Key Manager (EKM), CSEK. For each step up the ladder, name one thing the customer gains and one operational burden they take on.

**Q4.2** In step 3 you made data unreadable in about 30 seconds without touching the data. Give two business scenarios where that property is the deciding factor in a purchasing decision.

**Q4.3** A bank must prove that Google **cannot** decrypt its most sensitive dataset even under a lawful order served on Google. Which product combination addresses this, and what is the honest limitation you must state to the bank?

**Q4.4** Sensitive Data Protection found a credit card number in a support ticket. Describe the compliance consequence of that ticket sitting in an unclassified logging bucket, and how discovery-plus-de-identification converts an *unbounded* compliance scope into a *bounded* one.

---

## Exercise 5 — The network and perimeter layer: WAF at the edge, exfiltration boundary inside

**Layer:** network defence and data-egress control
**Business question:** what happens to your cost model when DDoS absorption is a shared platform capability rather than bandwidth you buy?

### Steps

1. Build a Cloud Armor edge policy with Google's pre-configured WAF rules — these are maintained by Google against the OWASP ModSecurity Core Rule Set, so you are consuming a rule set you do not author or tune from zero:

    ```bash
    gcloud compute security-policies create edge-waf \
      --description="Defence-in-depth lab: L7 filtering at the edge"

    gcloud compute security-policies rules create 1000 \
      --security-policy=edge-waf \
      --expression="evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})" \
      --action=deny-403 \
      --description="Block SQL injection"

    gcloud compute security-policies rules create 1010 \
      --security-policy=edge-waf \
      --expression="evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})" \
      --action=deny-403 \
      --description="Block cross-site scripting"

    gcloud compute security-policies rules create 1020 \
      --security-policy=edge-waf \
      --expression="origin.region_code == 'KP'" \
      --action=deny-403 \
      --description="Geo restriction example"
    ```

2. Turn on **Adaptive Protection**, which builds an ML baseline of your normal traffic and proposes a mitigation rule during an attack:

    ```bash
    gcloud compute security-policies update edge-waf --enable-layer7-ddos-defense
    gcloud compute security-policies describe edge-waf \
      --format="yaml(name, adaptiveProtectionConfig, rules.priority, rules.action)"
    ```

    Illustrative output:

    ```yaml
    adaptiveProtectionConfig:
      layer7DdosDefenseConfig:
        enable: true
        ruleVisibility: STANDARD
    name: edge-waf
    ```

3. Observe where this policy is enforced: at the **Google Front End**, on Google's edge, before the traffic reaches your VPC or consumes your egress. A volumetric L3/L4 flood is absorbed by the same infrastructure that serves Search and YouTube. You did not provision for peak attack capacity, and you are not billed for the attack traffic your backends never saw.

4. Now the inner boundary. IAM answers *who*; **VPC Service Controls** answers *from where a service may be reached and to where its data may travel*. Create the perimeter in dry-run mode so nothing breaks:

    ```bash
    gcloud access-context-manager perimeters dry-run create data-perimeter \
      --policy="$POLICY_ID" \
      --perimeter-title="Regulated data perimeter" \
      --perimeter-type=regular \
      --perimeter-resources="projects/${PROJECT_NUMBER}" \
      --perimeter-restricted-services=storage.googleapis.com,bigquery.googleapis.com
    ```

5. Generate traffic (re-run any of the storage commands above), then read what the perimeter *would* have blocked:

    ```bash
    gcloud logging read \
      'protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"
       AND protoPayload.metadata.dryRun="true"' \
      --project="$PROJECT_ID" --limit=10 \
      --format="table(timestamp, protoPayload.methodName, protoPayload.metadata.violationReason)"
    ```

6. Reason about the threat this closes and IAM cannot: an insider or a compromised credential with **legitimate** `storage.objects.get` permission copying a dataset to a personal project. Every IAM check passes. The perimeter refuses the egress because the destination is outside the boundary.

7. Clean up:

    ```bash
    gcloud access-context-manager perimeters delete data-perimeter --policy="$POLICY_ID" --quiet
    gcloud compute security-policies delete edge-waf --quiet
    ```

References: [Cloud Armor security policies](https://cloud.google.com/armor/docs/security-policy-overview), [VPC Service Controls](https://cloud.google.com/vpc-service-controls/docs/overview).

### Verify your understanding

**Q5.1** Cloud Armor and VPC Service Controls both sound like "network security". State precisely what each one protects against, and give one attack that only one of them stops.

**Q5.2** Explain to a CFO why DDoS protection on Google Cloud changes the *shape* of the cost, not just the amount — reference what an on-premises organization must buy to reach comparable capacity.

**Q5.3** "We have IAM configured correctly, so we do not need VPC Service Controls." Refute this in three sentences using the scenario from step 6.

**Q5.4** Name the layers of defence a single malicious HTTP request now has to survive, in order, from the public internet to a row in BigQuery. Aim for at least five.

---

## Exercise 6 — The detection layer: Google's threat intelligence, applied to your estate

**Layer:** detection, investigation and response
**Business question:** what does an organization pay today to build the detection content, threat intel, and 24/7 analyst coverage that this layer supplies as a product?

### Steps

1. **`[ORG]`** List the detection sources active on your organization. These are the built-in services writing findings into **Security Command Center**:

    ```bash
    gcloud scc sources list "organizations/${ORG_ID}" \
      --format="table(displayName, description)"
    ```

    Illustrative output:

    ```
    DISPLAY_NAME                 DESCRIPTION
    Security Health Analytics    Detects misconfigurations in Google Cloud resources.
    Event Threat Detection       Detects threats in Cloud Logging using Google threat intelligence.
    Container Threat Detection   Detects runtime attacks in GKE containers.
    Web Security Scanner         Detects web application vulnerabilities.
    ```

    Read that list as a staffing plan you did not have to hire: a misconfiguration scanner, a log-based threat detector fed by Google's threat intel, a container runtime sensor, and a DAST scanner — four distinct security engineering capabilities, on by default at the Standard tier.

2. List your active findings, worst first:

    ```bash
    gcloud scc findings list "organizations/${ORG_ID}" \
      --source=- \
      --filter='state="ACTIVE" AND severity="HIGH"' \
      --format="table(finding.category, finding.severity, finding.resourceName.basename(), finding.eventTime)" \
      --limit=20
    ```

    Illustrative output:

    ```
    CATEGORY                        SEVERITY  RESOURCE_NAME         EVENT_TIME
    PUBLIC_BUCKET_ACL               HIGH      example-proj-public   2026-09-06T04:11:07Z
    OVER_PRIVILEGED_SERVICE_ACCOUNT HIGH      default-compute-sa    2026-09-06T04:11:07Z
    MFA_NOT_ENFORCED                HIGH      example.com           2026-09-05T22:40:12Z
    ```

    Project-scoped alternative:

    ```bash
    gcloud scc findings list --project="$PROJECT_ID" --source=- --limit=10
    ```

3. Group findings to produce the number an executive actually reads — a per-category count, not a list of 4,000 rows:

    ```bash
    gcloud scc findings group "organizations/${ORG_ID}" \
      --source=- \
      --group-by="category" \
      --filter='state="ACTIVE"'
    ```

4. Suppress the known-and-accepted noise so the signal survives, using a mute config rather than closing findings by hand:

    ```bash
    gcloud scc muteconfigs create accepted-lab-risk \
      --organization="$ORG_ID" \
      --description="Accepted risk: lab projects" \
      --filter='resource.project_display_name="cdl-lab"'
    ```

5. Map the tiers to the business capability they buy. Confirm your tier in the console under **Security Command Center → Settings**:

    | Tier | Adds | The capability an organization would otherwise buy or build |
    |---|---|---|
    | **Standard** | Security Health Analytics (subset), Web Security Scanner (custom scans), asset inventory | Cloud Security Posture Management (CSPM), basic |
    | **Premium** | Event Threat Detection, Container Threat Detection, VM Threat Detection, Attack Path Simulation, compliance dashboards (CIS, PCI DSS, NIST 800-53, ISO 27001) | Full CSPM + CWPP + continuous compliance reporting |
    | **Enterprise** | Google SecOps (SIEM/SOAR), Mandiant threat intelligence and expertise, multicloud coverage (AWS, Azure), case management | SIEM + SOAR + a threat intel subscription + IR retainer |

6. Note the specific asset behind the Enterprise tier: **Mandiant**, acquired by Google in 2022, is an incident-response practice that works the largest breaches in the industry. Its frontline findings become detection content in Google SecOps and in Google Threat Intelligence. That is the concrete meaning of "Google on your security team" — you are consuming intelligence derived from breaches you were not in.

7. Clean up:

    ```bash
    gcloud scc muteconfigs delete accepted-lab-risk --organization="$ORG_ID" --quiet
    ```

References: [Security Command Center overview](https://cloud.google.com/security-command-center/docs/security-command-center-overview), [Google Security Operations](https://cloud.google.com/security/products/security-operations), [Google Threat Intelligence](https://cloud.google.com/security/products/threat-intelligence).

### Verify your understanding

**Q6.1** Distinguish a **misconfiguration** finding from a **threat** finding. Name the SCC service that produces each, and explain why an organization needs both.

**Q6.2** You muted a finding rather than closing it. Explain the governance difference, and why an auditor cares.

**Q6.3** A 200-person company is considering hiring a security analyst (fully loaded cost, one full-time employee) versus upgrading to SCC Premium. List three things the analyst provides that Premium does not, and three things Premium provides that one analyst cannot.

**Q6.4** Articulate the business value of Mandiant being part of Google Cloud, in the form a Digital Leader would say it to a board: one sentence, no product names other than the two.

---

## Exercise 7 — The software supply chain layer: trust what you deploy

**Layer:** build and deploy integrity
**Business question:** after a supply chain compromise became a boardroom topic, what does provable build provenance do to your risk register?

### Steps

1. Export your project's current Binary Authorization policy:

    ```bash
    gcloud services enable binaryauthorization.googleapis.com containeranalysis.googleapis.com
    gcloud container binauthz policy export
    ```

    Illustrative default output:

    ```yaml
    defaultAdmissionRule:
      enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
      evaluationMode: ALWAYS_ALLOW
    globalPolicyEvaluationMode: ENABLE
    name: projects/example-proj/policy
    ```

    Read the default honestly: `evaluationMode: ALWAYS_ALLOW` means any image from anywhere deploys. This is the state most organizations are in.

2. Tighten it to require an attestation — a cryptographic statement that a specific image passed a specific gate:

    ```bash
    gcloud container binauthz policy export > /tmp/policy.yaml
    cat > /tmp/policy.yaml <<EOF
    name: projects/${PROJECT_ID}/policy
    globalPolicyEvaluationMode: ENABLE
    admissionWhitelistPatterns:
    - namePattern: gcr.io/google-containers/*
    - namePattern: gke.gcr.io/*
    defaultAdmissionRule:
      evaluationMode: REQUIRE_ATTESTATION
      enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
      requireAttestationsBy:
      - projects/${PROJECT_ID}/attestors/built-by-cloud-build
    EOF
    gcloud container binauthz policy import /tmp/policy.yaml
    ```

3. Scan an image for known CVEs before it ever reaches the policy gate, using Artifact Analysis:

    ```bash
    gcloud artifacts docker images list "${REGION}-docker.pkg.dev/${PROJECT_ID}/my-repo" \
      --show-occurrences --occurrence-filter='kind="VULNERABILITY"' \
      --format="table(package, version, vulnerability.effectiveSeverity)" 2>/dev/null \
      || echo "No Artifact Registry repo yet — read the reference and continue."
    ```

4. Reason about the three assurances now stacked on one container image, and note that each answers a different question:

    | Control | Question it answers |
    |---|---|
    | **Assured OSS** | Are the open-source dependencies ones Google itself builds, scans, and signs in its own pipeline? |
    | **Artifact Analysis** | Does this image contain a known CVE? |
    | **Binary Authorization** | Was this exact image built by our pipeline, and did it pass our gates? |

5. Restore the permissive policy so you do not block your own future deployments:

    ```bash
    cat > /tmp/policy-open.yaml <<EOF
    name: projects/${PROJECT_ID}/policy
    globalPolicyEvaluationMode: ENABLE
    defaultAdmissionRule:
      evaluationMode: ALWAYS_ALLOW
      enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
    EOF
    gcloud container binauthz policy import /tmp/policy-open.yaml
    ```

References: [Binary Authorization](https://cloud.google.com/binary-authorization/docs/overview), [Assured Open Source Software](https://cloud.google.com/assured-open-source-software/docs/overview), [Software Supply Chain Security](https://cloud.google.com/software-supply-chain-security/docs/overview).

### Verify your understanding

**Q7.1** A vulnerability scanner already reports CVEs in your images. What class of attack does Binary Authorization stop that the scanner cannot see at all?

**Q7.2** Assured OSS ships the *same* open-source packages that are free on public registries. In one sentence, state precisely what a customer is paying for, and give the business unit most likely to sign the cheque.

**Q7.3** Place these three controls on the timeline **build → deploy → run**, and explain why defence in depth requires a control at each point rather than the strongest possible control at one point.

---

## Exercise 8 — The operator layer: constraining Google itself

**Layer:** provider transparency and confidential computing
**Business question:** the sharpest objection to cloud adoption is "the provider's own staff can see our data" — what is the auditable answer?

### Steps

1. Enrol the project in **Access Approval**, which requires *your* explicit approval before a Google employee can access your data for a support case:

    ```bash
    gcloud services enable accessapproval.googleapis.com
    gcloud access-approval settings update \
      --project="$PROJECT_ID" \
      --notification_emails='security@example.com' \
      --enrolled_services=all
    gcloud access-approval settings get --project="$PROJECT_ID"
    ```

    Illustrative output:

    ```yaml
    enrolledServices:
    - cloudProduct: all
      enrollmentLevel: BLOCK_ALL
    name: projects/example-proj/accessApprovalSettings
    notificationEmails:
    - security@example.com
    ```

2. Read the **Access Transparency** log stream — near-real-time entries recording when Google staff accessed your content, and the justification ticket:

    ```bash
    gcloud logging read \
      'logName:"logs/cloudaudit.googleapis.com%2Faccess_transparency"' \
      --project="$PROJECT_ID" --limit=5 --format=json
    ```

    An empty result is the expected and desirable outcome. The value is not in the entries — it is in the existence of the stream: an audit trail of the provider, generated by the provider, that you own.

3. Close the last gap — data **in use**, in memory, where the two previous encryption states do not reach. Create a Confidential VM (**billable — delete it in step 5**):

    ```bash
    gcloud compute instances create conf-vm \
      --zone="$ZONE" \
      --machine-type=n2d-standard-2 \
      --min-cpu-platform="AMD Milan" \
      --confidential-compute-type=SEV \
      --maintenance-policy=TERMINATE \
      --image-family=ubuntu-2204-lts \
      --image-project=ubuntu-os-cloud \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
    ```

4. Verify from inside the guest that memory encryption is active:

    ```bash
    gcloud compute ssh conf-vm --zone="$ZONE" --command="sudo dmesg | grep -i -E 'sev|memory encryption'"
    ```

    Illustrative output:

    ```
    [    0.000000] AMD Memory Encryption Features active: SEV
    [    0.223401] SEV is active, SME is not
    ```

    The hypervisor — Google's own code — cannot read this VM's memory. The encryption key lives in the AMD Secure Processor, not in software Google operates.

5. **Delete the VM now:**

    ```bash
    gcloud compute instances delete conf-vm --zone="$ZONE" --quiet
    ```

References: [Access Transparency](https://cloud.google.com/logging/docs/audit/access-transparency-overview), [Access Approval](https://cloud.google.com/assured-workloads/access-approval/docs/overview), [Confidential VM](https://cloud.google.com/confidential-computing/confidential-vm/docs/confidential-vm-overview), [Key Access Justifications](https://cloud.google.com/assured-workloads/key-access-justifications/docs/overview).

### Verify your understanding

**Q8.1** Distinguish **Access Transparency** from **Access Approval** in one sentence each, and say which of the two is a *detective* control and which is *preventive*.

**Q8.2** Confidential Computing closed which of the three data states? Name a specific industry workload where that state is the entire reason cloud adoption was previously blocked.

**Q8.3** **Key Access Justifications** lets a customer see the stated reason for every key access request and deny it programmatically. Combined with Cloud EKM, describe the sovereignty guarantee this produces, and name the one party who must still be trusted.

**Q8.4** A prospect says: "Cloud means giving up control." Using only Exercise 8, give a three-point rebuttal in the order transparency → approval → technical impossibility.

---

## Exercise 9 — Compliance, sovereignty, and transferring the risk

**Layer:** governance, assurance and financial risk
**Business question:** compliance is a cost centre and a time-to-market gate. What does inheriting a provider's certifications actually change?

### Steps

1. Open the [Compliance Reports Manager](https://cloud.google.com/security/compliance/compliance-reports-manager) and download the current **SOC 2 Type II** report and the **ISO/IEC 27001** certificate. Note two things: the elapsed time (minutes) and the number of Google Cloud staff involved (zero).

2. Compare that against the internal effort those artefacts represent — a SOC 2 Type II covers a multi-month observation window, an external audit firm, and evidence collection across the whole infrastructure. Your organization inherits the *infrastructure* portion of that scope and audits only what it built on top.

3. **`[ORG]`** Inspect the Assured Workloads surface — a compliance-regime-bound folder where Google enforces data residency, personnel controls, and support-access restrictions as platform behaviour rather than as policy documents:

    ```bash
    gcloud services enable assuredworkloads.googleapis.com
    gcloud assured workloads list \
      --organization="$ORG_ID" --location="$REGION" \
      --format="table(displayName, complianceRegime, resources)"
    ```

    An empty list is expected. Read the available regimes instead:

    ```bash
    gcloud assured workloads create --help | grep -A 30 'compliance-regime'
    ```

    You will find regimes including `FEDRAMP_MODERATE`, `FEDRAMP_HIGH`, `IL4`, `CJIS`, `HIPAA`, `ITAR`, `EU_REGIONS_AND_SUPPORT`, and `ASSURED_WORKLOADS_FOR_PARTNERS`.

4. Enforce data residency independently of Assured Workloads, with a single org policy constraint:

    ```bash
    cat > /tmp/residency.yaml <<EOF
    name: organizations/${ORG_ID}/policies/gcp.resourceLocations
    spec:
      rules:
      - values:
          allowedValues:
          - in:eu-locations
    EOF
    gcloud org-policies set-policy /tmp/residency.yaml
    ```

    Test it and observe the refusal:

    ```bash
    gcloud storage buckets create "gs://${PROJECT_ID}-us-test" --location=us-central1
    ```

    Illustrative output:

    ```
    ERROR: (gcloud.storage.buckets.create) HTTPError 412: Constraint constraints/gcp.resourceLocations
    violated for projects/example-proj. us-central1 violates constraint.
    ```

    Clean up:

    ```bash
    gcloud org-policies delete constraints/gcp.resourceLocations --organization="$ORG_ID"
    ```

5. Read the [Risk Protection Program](https://cloud.google.com/security/risk-protection-program). This is the layer most often missed on the exam: Google partners with **Munich Re** and **Allianz** to offer *Cloud Protection +*, cyber insurance priced using the customer's Security Command Center posture data. The insurers underwrite against the measured posture rather than a questionnaire.

6. State the significance in one line before moving on: an insurer accepting Google's telemetry as underwriting evidence is an independent, financially-backed third party asserting that this security model reduces loss. That converts "our security is good" from a claim into a priced instrument.

7. Distinguish the two models that frame this whole document:

    | Model | Google's posture | Customer experience |
    |---|---|---|
    | **Shared responsibility** | Here is the line. Above it is yours. | A contract. Correct, and cold. |
    | **Shared fate** | Here are secure-by-default blueprints, guardrails, landing zones, posture telemetry, and an insurance path. We carry risk with you. | A partnership with skin in the game. |

    See [Shared responsibility and shared fate](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate).

### Verify your understanding

**Q9.1** For each of IaaS, PaaS, and SaaS, state who patches the guest operating system, and give a business consequence of that difference for a company with a small platform team.

**Q9.2** Explain, in the language of a CFO, why "inheriting compliance" shortens time to revenue, not just time to audit. Use a concrete example (a healthcare or public-sector deal).

**Q9.3** State the difference between **shared responsibility** and **shared fate** in one sentence each, then name the artefact from this document that is the clearest evidence of shared fate.

**Q9.4** A European public-sector customer requires that data never leave the EU and that support staff be EU-resident. Which two mechanisms from this exercise address which half of that requirement, and why is the org policy alone insufficient?

---

## Exercise 10 — Synthesis: the one-page memo

You are not being asked to configure anything. You are being asked to do the Digital Leader's actual job.

### Steps

1. Write a one-page memo to a board that has approved a cloud migration but is nervous about security. Structure it in exactly four sections:
    - **What we stop paying for** — capabilities that become platform features (list five, drawn from Exercises 1, 5, 6, 7).
    - **What we still own** — your side of the shared responsibility line (list five).
    - **How we prove it** — the artefacts an auditor accepts, and how long each takes to produce (Exercises 6 and 9).
    - **What happens when it fails anyway** — detection, response, and financial transfer (Exercises 6 and 9).

2. Constrain yourself to **one product name per section**. If a section needs three product names to make its point, the point is not yet a business argument.

3. Test the memo against the exam's phrasing. The objective says *"making Google part of an organization's security team."* If your memo reads as "we bought security tools", rewrite it. If it reads as "capabilities that used to require headcount, capital, and calendar time are now inherited, measured, and insured", it is correct.

### Verify your understanding

**Q10.1** In one sentence with no product names at all, state the business value of defence in depth.

**Q10.2** Name the layer from Exercises 1–9 you would implement **first** at a 50-person startup with no security staff, and defend the choice on cost-to-benefit, not on completeness.

**Q10.3** An executive says: "Defence in depth is just redundancy, and redundancy is waste." Refute this using a concrete failure chain from these exercises where exactly one layer held.

---

<details>
<summary><strong>Answers</strong> — attempt every question before opening</summary>

### Exercise 1 — Infrastructure and cryptography

**A1.1** The `default_kms_key` / `encryption` field records only whether a **customer-managed** key (CMEK) is configured; its absence means the object is encrypted with **Google-managed keys**, which is the platform default and cannot be turned off. The field describes key custody, not the presence of encryption.

**A1.2** Two of:
- **Zero marginal cost and zero operational surface.** There is no encryption product to license, deploy, monitor, patch, or fail. Encryption cannot be accidentally disabled by a misconfiguration, so an entire class of audit finding does not exist.
- **Audit scope reduction.** "Data at rest is encrypted" is satisfied by an inherited platform control backed by Google's SOC 2 / ISO 27001 reports, rather than by evidence your team must collect per system, per audit cycle.
- **Uniformity.** On-premises, encryption coverage is per-system and drifts. Here it is invariant across every service, every region, every new resource, including ones created by teams that never read the security policy.

**A1.3** At rest, in transit, and in use. **In use** — data decrypted in a machine's memory during processing — is *not* covered by the defaults; that requires Confidential Computing (Exercise 8).

**A1.4** (1) The technology: **ALTS** (Application Layer Transport Security), Google's mutually-authenticated encryption for internal RPC, plus encryption of traffic on the private WAN between datacentres. (2) The document class: Google's third-party audit reports and whitepapers — the *Encryption in Transit in Google Cloud* whitepaper and the SOC 2 Type II report from Compliance Reports Manager. Neither requires access to your project, because the control is Google's, not yours.

### Exercise 2 — Governance

**A2.1** (a) **preventive**, (b) **detective**, (c) **corrective**. The **preventive** control has the lowest TCO: the detective control requires someone to triage and act on every finding, and the corrective control is code you must write, test, secure, grant privileges to, and maintain — and it acts only *after* an exposure window during which the risk was real. The preventive control has no exposure window and no ongoing labour; the API simply refuses.

**A2.2** Dry-run mode evaluates the policy against real traffic and logs every action that *would* have been blocked, while allowing all of them to succeed. It converts a security mandate from a bet into a measurement: you see the exact list of teams and workloads that would break, quantify the remediation, and schedule it — before anyone is paged. The security outcome is unchanged; only the risk of the rollout is removed.

**A2.3** Exceptions are visible, few, and reviewable. If the strict policy sits at the organization node, the default for every current and future project — including ones nobody has created yet — is secure, and the security team audits a short list of deliberate exceptions. If policy is set per project, the default for a new project is *nothing*, security depends on someone remembering, and the auditable question changes from "what are our exceptions?" (answerable) to "did anyone forget?" (not answerable at scale).

**A2.4** Move the 400 acquired projects under a single folder, apply the organization's guardrails to that folder in **dry-run mode**, and read the violation log to get a precise, complete, ranked remediation list. Then enforce the constraints in order of severity: a single policy change fixes a class of misconfiguration across all 400 projects simultaneously, so the work scales with the number of *policies*, not the number of projects.

### Exercise 3 — Identity

**A3.1** **Authentication** proves who or what is making the request (identity); **authorization** decides whether that identity may perform this action on this resource. Authentication is handled by **Cloud Identity** (with Google Workspace, external IdP federation, or Workload Identity for services); authorization is handled by **Cloud IAM**.

**A3.2** Acting on a partial window risks revoking a permission used by a real but **infrequent** process — quarterly close, annual DR test, month-end batch, seasonal peak. The failure surfaces at the worst moment, and the business damage lands on the team that ran the security improvement, which poisons the next one. To a steering committee: *"We are reducing access based on observed usage. If we act before we have observed a full business cycle, we will break something that only runs once a quarter, and we will break it during that quarter's most important day."*

**A3.3** VPN accounts have per-seat cost, provisioning and deprovisioning labour, a helpdesk load that spikes at exactly the moment staffing is thinnest, and a residual risk that concentrates in the deprovisioning step — an unrevoked VPN account is network-level access. The zero-trust model has no per-seat appliance capacity to size for the November peak, evaluates trust per request from identity and device posture, and revocation is a single identity change that takes effect on the next request everywhere at once. Financially: the seasonal capacity spike stops being a capital-planning problem.

**A3.4** **(b), the IAM recommendation.** (a) and (c) are configuration surfaces — powerful, but they only do what you tell them, which is the definition of a tool. (b) is Google performing continuous analysis of your specific environment and returning a finding you did not ask for and could not have produced without dedicating an engineer to it; that is a colleague's output, not a tool's. (A defence of (c) is also creditable if it argues that Google's device-posture and threat signals are what make the decision possible.)

### Exercise 4 — Data protection

**A4.1** Lowest to highest control: **Google-managed default encryption → CMEK → Cloud EKM → CSEK**.

| Step | Gains | Takes on |
|---|---|---|
| Default → **CMEK** | Control over key lifecycle, rotation policy, and the ability to disable/destroy (crypto-shredding); key usage appears in your audit logs | Key ring/key billing, IAM on the key, and the risk that disabling a key takes production down |
| CMEK → **EKM** | Keys live outside Google, in your own or a partner's key manager; Google cannot access the key material | Availability of your key manager becomes a hard dependency of your data's availability; latency and operational burden |
| EKM → **CSEK** | The key is supplied on every request and never stored by Google at all | You must transmit and manage the key per request, with no recovery if lost; limited service support (legacy — prefer CMEK/EKM) |

**A4.2** Two of:
- **Right to erasure / GDPR Article 17 at scale.** Proving deletion of every backup, replica, and archived copy of a dataset is hard; destroying the key that makes all copies readable is provable and instantaneous.
- **Offboarding a tenant, joint venture, or divested business unit.** Access ends at a known timestamp with an auditable event, without a data-migration project.
- **Incident containment.** On evidence of credential compromise, a key disable stops all readers of the affected dataset in seconds, including readers you have not yet identified.
- **Contractual exit.** A customer or regulator can be shown a mechanism, not a promise, for terminating the provider's ability to serve their data.

**A4.3** **Cloud External Key Manager (Cloud EKM)** plus **Key Access Justifications**, ideally inside an **Assured Workloads** boundary. The key material stays in an external key manager outside Google's control, so Google cannot decrypt without a key-unwrap call the customer can deny. The honest limitation: this protects data **at rest**. Data must still be decrypted in memory to be processed, so the guarantee is only complete when combined with **Confidential Computing** — and even then the customer trusts the CPU vendor's hardware root of trust and the correctness of Google's key-request justification reporting.

**A4.4** A payment card number in a general logging bucket pulls that bucket — and everything reachable from it, and every system that ships logs to it — into **PCI DSS** scope, which means controls, evidence and audit for the whole path. Discovery plus de-identification inverts this: you learn exactly where regulated data lives (bounded), mask or tokenize it at ingestion so the log stream carries no cardholder data, and the audit scope shrinks to the small, deliberately-designed system that does hold it. Unbounded scope is what makes compliance expensive; the scope reduction *is* the return on investment.

### Exercise 5 — Network and perimeter

**A5.1** **Cloud Armor** filters **inbound** traffic at Google's edge: volumetric L3/L4 DDoS, and L7 application attacks (SQLi, XSS, RCE, LFI) via WAF rules. **VPC Service Controls** constrains **outbound** and cross-boundary access to Google APIs: it defines a perimeter that data may not leave, regardless of IAM. Only Cloud Armor stops an SQL injection from the internet; only VPC Service Controls stops an authorized user copying a BigQuery table into a personal project.

**A5.2** On-premises, DDoS protection is bought as **capacity you must own in advance** — scrubbing appliances, upstream bandwidth, and a provider contract sized for an attack that may never come. That is capital expenditure and a permanent utilization loss. On Google Cloud, the absorption happens on shared global edge infrastructure sized for Google's own traffic; you consume a *capability*, not reserved capacity, and attack traffic dropped at the edge never becomes your egress bill. The shape changes from *fixed cost for peak capacity* to *variable cost for actual service*.

**A5.3** IAM answers "may this identity perform this action?" — and in the exfiltration scenario the answer is legitimately *yes*, because the credential holds `storage.objects.get` for a business reason. A compromised credential, a malicious insider, or a leaked service account key therefore passes every IAM check on the way out. VPC Service Controls asks a different question — "may this data cross this boundary?" — and refuses the copy to an outside project even though the identity is fully authorized, which is precisely the gap IAM structurally cannot close.

**A5.4** In order: **(1)** Google's edge / GFE volumetric DDoS absorption → **(2)** Cloud Armor WAF and rule evaluation (SQLi, XSS, geo, rate limiting) → **(3)** Cloud Load Balancing and TLS termination with a managed certificate → **(4)** VPC firewall rules / Cloud NGFW and private networking (no external IP, per org policy) → **(5)** IAM authentication and authorization of the calling identity → **(6)** VPC Service Controls perimeter evaluation on the BigQuery API call → **(7)** column-level access policies and encryption at rest with CMEK → **(8)** detection: Event Threat Detection and audit logs recording the whole path. Any one layer failing does not produce a breach.

### Exercise 6 — Detection

**A6.1** A **misconfiguration** finding says a resource is in a risky *state* — a public bucket, no MFA, an over-privileged service account — with no evidence anyone exploited it; **Security Health Analytics** produces these. A **threat** finding says something *happened* — anomalous IAM grants, cryptomining behaviour, connections to known-malicious infrastructure; **Event Threat Detection**, **Container Threat Detection**, and **VM Threat Detection** produce these. Both are required because fixing misconfigurations reduces the attack surface but cannot detect an attacker using legitimate credentials, and threat detection catches the live intrusion but arrives after the exposure the misconfiguration created.

**A6.2** Closing a finding asserts it was **remediated**; muting asserts it was **reviewed and accepted as a known risk**, with a filter, an owner, and a stated reason, and the finding remains queryable. An auditor cares because the two are different control outcomes: accepted risk must be documented, attributed and revisited, whereas a closed-but-unfixed finding is an undocumented exception that hides a real exposure and looks identical to genuine remediation in the metrics.

**A6.3**
*Only the analyst provides:* business context (which system actually matters, which "critical" finding is on a decommissioned service); judgement in ambiguous cases and the authority to make a call; relationships with engineering teams that get findings actually fixed; incident response coordination with humans in the loop; policy authorship and risk acceptance decisions.
*Only Premium provides:* 24/7/365 coverage with no fatigue, holidays, or attrition; complete and continuous coverage of every resource in every project including ones nobody told the analyst about; detection content authored from Google's and Mandiant's global threat visibility; attack path simulation across the whole estate; continuous compliance mapping to CIS/PCI DSS/NIST/ISO.
The correct conclusion is that these are **complementary, not substitutes** — Premium is what makes one analyst effective at a scale that would otherwise need a team.

**A6.4** *"Mandiant works the world's largest breaches, and since Google acquired them, what they learn on those front lines becomes detection running in our environment — so we are defended by intelligence from incidents we were never part of."*

### Exercise 7 — Supply chain

**A7.1** A scanner detects **known** vulnerabilities in the artefact it is given. Binary Authorization stops a **legitimate-looking, CVE-free image that your pipeline did not build** — a substituted or backdoored image pushed by a compromised registry credential, a developer bypassing CI, or an attacker with deploy access. There is no CVE to find, because the malicious code is not a known vulnerability in a public package; the only detectable property is that the image lacks an attestation from your build system.

**A7.2** The customer pays for **provenance and assurance** — packages built, scanned, fuzzed and signed inside Google's own pipeline with SLSA build provenance and an SBOM, backed by Google's vulnerability enrichment — not for the code itself, which remains open source. The cheque is signed by whoever owns audit and regulatory outcomes (CISO, risk, or compliance), because the purchase is an evidence artefact for auditors and customers, not a developer feature.

**A7.3** **Build:** Assured OSS and Artifact Analysis (are the ingredients and the resulting image clean?). **Deploy:** Binary Authorization (is this the artefact our pipeline produced and approved?). **Run:** Container Threat Detection, VPC Service Controls, IAM (is the running workload behaving, and can it reach data it should not?). Depth is required at each point because each control is blind to the others' failure modes: a perfect scanner is bypassed by substituting the image after the scan; a perfect deploy gate cannot see a container compromised at runtime through a zero-day; and runtime detection alone catches the attack only after it is already executing in production.

### Exercise 8 — Operator layer

**A8.1** **Access Transparency** produces near-real-time logs recording when Google personnel accessed your content and why — it is **detective**. **Access Approval** requires your explicit approval before that access can occur — it is **preventive**.

**A8.2** Data **in use** (in memory during processing). Examples: multi-party analytics between competing banks or insurers on pooled fraud data; genomic and clinical research where patient data from multiple institutions must be jointly analysed; sovereign or defence workloads where the operator must be provably unable to observe processing; and confidential financial modelling under M&A restrictions. In each, the blocker was not storage or transport — both were already solved — but the moment of computation.

**A8.3** With Cloud EKM the key material lives outside Google; with Key Access Justifications, every unwrap request arrives with a machine-readable reason code that the customer's key manager can automatically approve or **deny**. The guarantee is that Google's ability to decrypt is not merely policy-restricted but technically gated on an approval the customer controls and logs, giving the customer a unilateral, auditable veto. The party who must still be trusted is the **CPU/hardware vendor** whose secure processor and attestation underpin Confidential Computing — plus, strictly, Google's correct implementation of the justification reporting itself.

**A8.4** *"First, transparency: we get a log of every access by the provider's staff, with the reason and the ticket — something no on-premises datacentre gives us about our own contractors. Second, approval: nothing happens without our explicit sign-off, per request, enforced by the platform. Third, technical impossibility: with Confidential Computing and external key management, the provider's staff cannot read the data even if they wanted to, because the memory is encrypted by the CPU and we hold the key."*

### Exercise 9 — Compliance and risk

**A9.1**
- **IaaS** — the **customer** patches the guest OS. Maximum control, and a permanent, non-differentiating operational load: patch cycles, maintenance windows, CVE tracking, and a small platform team spending a meaningful share of its capacity on undifferentiated work.
- **PaaS** — **Google** patches the OS and the runtime; the customer owns the application code and its data and access. The small team redirects that capacity to product.
- **SaaS** — **Google** owns everything up to the application; the customer owns only data, users, access, and configuration. Maximum leverage per engineer, minimum control over the stack.
The business consequence: for a small platform team, moving up this ladder is the difference between headcount spent on maintenance and headcount spent on revenue.

**A9.2** Compliance certifications are frequently **deal gates**, not just audit obligations. A healthcare buyer will not sign until you can evidence HIPAA-aligned controls; a public-sector buyer will not sign without FedRAMP. Building that evidence from scratch means a multi-month observation window before the first report exists — so the deal is not lost, it is *deferred past the fiscal year*. Inheriting Google's certified infrastructure and scoping your own audit to the application layer compresses that window, which moves recognised revenue earlier. To a CFO: *compliance is not a cost line here, it is a date on the revenue forecast.*

**A9.3** **Shared responsibility:** a contractual division of duties — Google secures the infrastructure *of* the cloud, the customer secures what they build *in* the cloud. **Shared fate:** Google takes an active stake in the customer's success by supplying secure-by-default configurations, blueprints and landing zones, guardrails, continuous posture telemetry, and a path to transfer residual risk. The clearest evidence of shared fate is the **Risk Protection Program** — Google's partners, Munich Re and Allianz, underwrite cyber insurance priced on Security Command Center posture data, meaning a third party puts money behind the model's effectiveness.

**A9.4** **`constraints/gcp.resourceLocations`** addresses the *data residency* half — it prevents resources from being created outside permitted regions. **Assured Workloads** (regime `EU_REGIONS_AND_SUPPORT`) addresses the *personnel* half — it constrains which Google support staff, in which jurisdictions, may access the workload, and enforces the residency guarantee as a property of the folder. The org policy alone is insufficient because it governs **where resources live**, not **who at Google may touch them**; residency without personnel controls does not satisfy a sovereignty requirement.

### Exercise 10 — Synthesis

**A10.1** Defence in depth means no single control failure becomes a breach, so the organization's security outcome no longer depends on any one control, vendor, configuration, or person being perfect.

**A10.2** The **governance layer (Exercise 2): organization policy constraints.** It is free, takes hours rather than months, requires no security staff to operate because the API enforces it, applies retroactively to every project and prospectively to every project not yet created, and eliminates the misconfigurations that account for the majority of cloud incidents. Every other layer needs someone to watch it; this one does not. A defensible alternative answer is **Security Command Center Standard**, on the grounds that you cannot prioritise what you cannot see — but the cost-to-benefit argument favours prevention when there is nobody to triage findings.

**A10.3** Example chain: a developer commits a service account key to a public repository (layer 1 — secret hygiene — fails); an attacker finds it within minutes and authenticates successfully (layer 2 — IAM — grants access, because the credential is valid and the permissions are real); the attacker attempts to copy the BigQuery dataset to a project they control, and the **VPC Service Controls perimeter refuses the egress** (layer 3 holds); the attempt writes an audit log, Event Threat Detection raises an anomalous-access finding, and the key is revoked within the hour (layer 4 responds). Two layers failed completely and one — a perimeter that costs nothing per request and that nobody watched — turned a breach into a ticket. That is not redundancy; each layer is a *different question*, and the attacker only had to be wrong once.

</details>

---

## Sources

- Google Cloud, *Cloud Digital Leader Certification Exam Guide* — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Google Cloud, *Google infrastructure security design overview* — https://cloud.google.com/docs/security/infrastructure/design
- Google Cloud, *Default encryption at rest* — https://cloud.google.com/docs/security/encryption/default-encryption
- Google Cloud, *Encryption in transit in Google Cloud* — https://cloud.google.com/docs/security/encryption-in-transit
- Google Cloud, *Organization Policy Service overview* — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Google Cloud, *Role recommendations overview* — https://cloud.google.com/policy-intelligence/docs/role-recommendations-overview
- Google Cloud, *Chrome Enterprise Premium documentation* — https://cloud.google.com/chrome-enterprise-premium/docs
- Google Cloud, *BeyondCorp: zero trust* — https://cloud.google.com/beyondcorp
- Google Cloud, *Cloud Key Management Service documentation* — https://cloud.google.com/kms/docs
- Google Cloud, *Cloud KMS Autokey overview* — https://cloud.google.com/kms/docs/autokey/overview
- Google Cloud, *Sensitive Data Protection documentation* — https://cloud.google.com/sensitive-data-protection/docs
- Google Cloud, *Cloud Armor security policy overview* — https://cloud.google.com/armor/docs/security-policy-overview
- Google Cloud, *VPC Service Controls overview* — https://cloud.google.com/vpc-service-controls/docs/overview
- Google Cloud, *Security Command Center overview* — https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Google Cloud, *Google Security Operations* — https://cloud.google.com/security/products/security-operations
- Google Cloud, *Google Threat Intelligence* — https://cloud.google.com/security/products/threat-intelligence
- Google Cloud, *Binary Authorization overview* — https://cloud.google.com/binary-authorization/docs/overview
- Google Cloud, *Assured Open Source Software overview* — https://cloud.google.com/assured-open-source-software/docs/overview
- Google Cloud, *Software supply chain security* — https://cloud.google.com/software-supply-chain-security/docs/overview
- Google Cloud, *Access Transparency overview* — https://cloud.google.com/logging/docs/audit/access-transparency-overview
- Google Cloud, *Access Approval overview* — https://cloud.google.com/assured-workloads/access-approval/docs/overview
- Google Cloud, *Key Access Justifications overview* — https://cloud.google.com/assured-workloads/key-access-justifications/docs/overview
- Google Cloud, *Confidential VM overview* — https://cloud.google.com/confidential-computing/confidential-vm/docs/confidential-vm-overview
- Google Cloud, *Assured Workloads overview* — https://cloud.google.com/assured-workloads/docs/overview
- Google Cloud, *Compliance Reports Manager* — https://cloud.google.com/security/compliance/compliance-reports-manager
- Google Cloud, *Risk Protection Program* — https://cloud.google.com/security/risk-protection-program
- Google Cloud Architecture Framework, *Shared responsibility and shared fate* — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate