# Topic 5.1 — Describe Fundamental Cloud Security Concepts
## Guided Exercises · Google Cloud Digital Leader (exam version 2026-08-12) · Section 5 weight: 9%

> **What this lab set proves.** The Cloud Digital Leader exam asks you to *describe* security concepts, not to configure them. But descriptions memorised from slides collapse under scenario questions ("a customer stores PII in Cloud Storage and asks who is responsible for patching the encryption library…"). Every exercise below makes you **execute the thing you will later be asked to describe**, so that the vocabulary — shared responsibility, shared fate, least privilege, separation of duties, defense in depth, zero trust, CMEK, data residency — is anchored to an artifact you produced and inspected.

---

## 0. Environment setup

**Roles you need:** `roles/owner` on a **sandbox** project, or the combination `roles/resourcemanager.projectIamAdmin` + `roles/iam.roleAdmin` + `roles/cloudkms.admin` + `roles/logging.viewer` + `roles/compute.securityAdmin`.

**Cost warning.** Exercises 1–3, 7, 8 and 9 are free (metadata reads and IAM writes). Exercise 4 creates **Cloud KMS** key versions (~US$0.06 per key version per month, and a key ring can never be deleted). Exercise 6 creates a Cloud Armor security policy — free while unattached to a load balancer. Exercises 5 and 6b need an **organization** and are provided with read-only fallbacks.

```bash
# 1. Authenticate and pin a sandbox project
gcloud auth login
export PROJECT_ID="cdl-sec-lab-$(whoami)"          # use an EXISTING sandbox project id
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export REGION="europe-west1"
gcloud config set project "$PROJECT_ID"

# 2. Enable the APIs used across the lab
gcloud services enable \
  cloudkms.googleapis.com \
  cloudasset.googleapis.com \
  policytroubleshooter.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com
```

Expected (abridged):

```
Operation "operations/acat.p2-482913746215-9f0b...-cb1e" finished successfully.
```

Verify the account you are acting as — nearly every "permission denied" in this lab traces back to this line:

```bash
gcloud auth list --filter=status:ACTIVE --format="value(account)"
```

```
you@example.com
```

---

## Exercise 1 — Security *of* the cloud vs. security *in* the cloud

**Concept under test:** the **shared responsibility model**, and its Google-specific evolution, **shared fate**. The single highest-yield idea in Section 5: the responsibility boundary *moves with the service model*.

### Steps

1. List which compute-family services are enabled in the project. Each one sits at a different point on the responsibility spectrum.

   ```bash
   gcloud services list --enabled \
     --filter="config.name:(compute.googleapis.com OR container.googleapis.com OR run.googleapis.com OR cloudfunctions.googleapis.com OR bigquery.googleapis.com)" \
     --format="table(config.name, config.title)"
   ```

   ```
   NAME                        TITLE
   bigquery.googleapis.com     BigQuery API
   compute.googleapis.com      Compute Engine API
   run.googleapis.com          Cloud Run Admin API
   ```

2. Prove the boundary empirically on **IaaS**. Create a minimal VM and ask the guest OS who patches it:

   ```bash
   gcloud compute instances create resp-demo \
     --zone="${REGION}-b" \
     --machine-type=e2-micro \
     --image-family=debian-12 \
     --image-project=debian-cloud \
     --no-address \
     --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
   ```

   ```
   Created [https://www.googleapis.com/compute/v1/projects/cdl-sec-lab/zones/europe-west1-b/instances/resp-demo].
   NAME       ZONE            MACHINE_TYPE  INTERNAL_IP  STATUS
   resp-demo  europe-west1-b  e2-micro      10.132.0.7   RUNNING
   ```

3. Inspect what Google guarantees *underneath* that VM — the Shielded VM integrity baseline — and what it explicitly does **not** cover (anything inside the disk):

   ```bash
   gcloud compute instances describe resp-demo --zone="${REGION}-b" \
     --format="yaml(shieldedInstanceConfig, shieldedInstanceIntegrityPolicy, disks[].licenses)"
   ```

   ```yaml
   disks:
   - licenses:
     - https://www.googleapis.com/compute/v1/projects/debian-cloud/global/licenses/debian-12-bookworm
   shieldedInstanceConfig:
     enableIntegrityMonitoring: true
     enableSecureBoot: true
     enableVtpm: true
   shieldedInstanceIntegrityPolicy:
     updateAutoLearnPolicy: true
   ```

   Read that literally: Google attests the **boot chain** (firmware, bootloader, kernel — measured into a vTPM). The Debian userland packages above the kernel are `debian-cloud`'s image and **your** ongoing patching duty.

4. Now the contrast. Ask a **serverless** product the same question — there is no OS surface to query at all:

   ```bash
   gcloud run services list --region="$REGION" 2>&1 | head -3
   ```

   ```
   Listed 0 items.
   ```

   There is no `--image-family`, no kernel, no patch cadence you control. On Cloud Run, the OS, container runtime, autoscaler and TLS termination are **security *of* the cloud**; your container image contents, IAM invoker bindings and application logic are **security *in* the cloud**.

5. Fill in this table before reading the answer key. `G` = Google, `C` = Customer, `S` = Shared.

   | Layer | Compute Engine | GKE Standard | GKE Autopilot | Cloud Run | BigQuery |
   |---|---|---|---|---|---|
   | Physical datacenter & hardware | | | | | |
   | Hypervisor / host kernel | | | | | |
   | Guest OS / node OS patching | | | | | |
   | Container runtime | | | | | |
   | Application code & dependencies | | | | | |
   | IAM policy on the resource | | | | | |
   | Data classification & content | | | | | |
   | Encryption key management (default) | | | | | |
   | Network firewall rules | | | | | |

### Checkpoint questions

**Q1.** In one sentence each, distinguish *security **of** the cloud* from *security **in** the cloud*, and state which one is always the customer's.

**Q2.** Complete the table in step 5 for the "Guest OS / node OS patching" row across all five services. Explain why GKE Standard and GKE Autopilot differ.

**Q3.** Google markets **shared fate** as an evolution of shared responsibility. Name three concrete mechanisms by which Google takes on part of *your* risk under shared fate, and state why shared fate does **not** transfer legal accountability for your data.

**Q4.** A customer says: "We moved to Cloud Run, so we no longer need a vulnerability management program." Identify the flaw and name the one artifact they still own that can carry a CVE.

---

## Exercise 2 — The principle of least privilege, measured

**Concept under test:** least privilege, and the three role types (**basic**, **predefined**, **custom**). CDL scenario questions hinge on "which role should you grant?" — the answer is almost never `roles/editor`.

### Steps

1. Read the project's current allow policy. This is the authoritative answer to "who can do what here":

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" --format=yaml
   ```

   ```yaml
   bindings:
   - members:
     - user:you@example.com
     role: roles/owner
   - members:
     - serviceAccount:482913746215-compute@developer.gserviceaccount.com
     role: roles/editor
   etag: BwYh3s9kZ0M=
   version: 1
   ```

   Note the `etag`: it is an optimistic-concurrency token. Read-modify-write on IAM without preserving it is how two admins silently clobber each other's grants.

2. Quantify why basic roles violate least privilege. Count the permissions each one carries:

   ```bash
   for R in roles/viewer roles/editor roles/owner; do
     N=$(gcloud iam roles describe "$R" \
           --format="value(includedPermissions)" | tr ';' '\n' | wc -l)
     printf "%-14s %6s permissions\n" "$R" "$N"
   done
   ```

   ```
   roles/viewer     4912 permissions
   roles/editor     8043 permissions
   roles/owner      8061 permissions
   ```

   > These counts drift upward every quarter as Google ships services. The order of magnitude — **thousands** — is the point, and it is why basic roles are discouraged outside sandbox projects.

3. Compare against a predefined role scoped to one job:

   ```bash
   gcloud iam roles describe roles/storage.objectViewer \
     --format="yaml(name, title, stage, includedPermissions)"
   ```

   ```yaml
   includedPermissions:
   - storage.managedFolders.get
   - storage.managedFolders.list
   - storage.objects.get
   - storage.objects.list
   name: roles/storage.objectViewer
   stage: GA
   title: Storage Object Viewer
   ```

   Four permissions versus 8,043. That ratio *is* the principle of least privilege expressed numerically.

4. Build a **custom role** when no predefined role is tight enough. Write the manifest:

   ```yaml
   # custom-role-log-triage.yaml
   title: "Log Triage (read-only)"
   description: "Read log entries and log-based metrics for incident triage. No export, no sink modification, no data mutation."
   stage: "GA"
   includedPermissions:
   - logging.logEntries.list
   - logging.logs.list
   - logging.logMetrics.get
   - logging.logMetrics.list
   - logging.views.access
   - resourcemanager.projects.get
   ```

   ```bash
   gcloud iam roles create logTriage \
     --project="$PROJECT_ID" \
     --file=custom-role-log-triage.yaml
   ```

   ```
   Created role [logTriage].
   description: Read log entries and log-based metrics for incident triage. No export,
     no sink modification, no data mutation.
   etag: BwYh3tA1p2Y=
   includedPermissions:
   - logging.logEntries.list
   - logging.logs.list
   - logging.logMetrics.get
   - logging.logMetrics.list
   - logging.views.access
   - resourcemanager.projects.get
   name: projects/cdl-sec-lab/roles/logTriage
   stage: GA
   title: Log Triage (read-only)
   ```

5. Tighten further with an **IAM Condition** — least privilege in the *time* and *resource* dimensions, not just the verb dimension:

   ```bash
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="user:oncall@example.com" \
     --role="projects/${PROJECT_ID}/roles/logTriage" \
     --condition='expression=request.time < timestamp("2026-10-01T00:00:00Z"),title=incident-window,description=Expires after the Q3 incident review' \
     --format="yaml(bindings)"
   ```

   ```yaml
   bindings:
   - condition:
       description: Expires after the Q3 incident review
       expression: request.time < timestamp("2026-10-01T00:00:00Z")
       title: incident-window
     members:
     - user:oncall@example.com
     role: projects/cdl-sec-lab/roles/logTriage
   ```

   The policy `version` is now `3`. A conditional binding silently disappears from a `version: 1` read — a classic audit blind spot.

6. Confirm the grant expires by *description*, then verify what the principal can actually do:

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" \
     --format="table(bindings.role, bindings.members, bindings.condition.title)"
   ```

### Checkpoint questions

**Q5.** State the principle of least privilege in one sentence, then give the numeric evidence you gathered in steps 2–3 that `roles/editor` violates it.

**Q6.** A data analyst must read objects in one Cloud Storage bucket and nothing else. Rank these four options from best to worst and justify the ranking: (a) `roles/owner`, (b) `roles/storage.admin` at project level, (c) `roles/storage.objectViewer` on the single bucket, (d) a custom role with `storage.objects.get` + `storage.objects.list` on the single bucket.

**Q7.** What is an **IAM Condition**, and which two least-privilege dimensions does it add beyond "which permissions"?

**Q8.** Why does IAM return an `etag`, and what failure mode does ignoring it produce?

---

## Exercise 3 — Separation of duties and guardrails that outrank IAM

**Concept under test:** **separation of duties (SoD)**, **defense in depth**, and the fact that an Organization Policy constraint is evaluated *before* IAM — a Project Owner cannot grant their way around it.

### Steps

1. Model SoD as three disjoint duties. Notice that no principal below can both *create* a key and *use* it to read data, and none can also *audit*:

   ```bash
   # Duty A — key custodian: manages keys, cannot decrypt data
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="group:key-custodians@example.com" \
     --role="roles/cloudkms.admin" --quiet >/dev/null

   # Duty B — data operator: uses keys to encrypt/decrypt, cannot manage or delete them
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="group:data-operators@example.com" \
     --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" --quiet >/dev/null

   # Duty C — auditor: reads everything, changes nothing
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="group:security-audit@example.com" \
     --role="roles/iam.securityReviewer" --quiet >/dev/null
   ```

   > `roles/cloudkms.admin` deliberately **excludes** `cloudkms.cryptoKeyVersions.useToDecrypt`. That exclusion is Google encoding SoD into the role catalogue for you.

2. Verify the separation instead of trusting it:

   ```bash
   gcloud iam roles describe roles/cloudkms.admin \
     --format="value(includedPermissions)" | tr ';' '\n' | grep -c 'useToDecrypt'
   ```

   ```
   0
   ```

3. Now add the guardrail layer. Inspect an **effective** organization policy on the project:

   ```bash
   gcloud org-policies describe constraints/compute.requireOsLogin \
     --project="$PROJECT_ID" --effective
   ```

   ```
   name: projects/cdl-sec-lab/policies/compute.requireOsLogin
   spec:
     rules:
     - enforce: false
   ```

4. Enforce it. This is a **preventive** control — it stops the action, unlike a detective control that merely reports it:

   ```yaml
   # orgpolicy-require-oslogin.yaml
   name: projects/cdl-sec-lab/policies/compute.requireOsLogin
   spec:
     rules:
     - enforce: true
   ```

   ```bash
   gcloud org-policies set-policy orgpolicy-require-oslogin.yaml
   ```

   ```
   Created policy [projects/cdl-sec-lab/policies/compute.requireOsLogin].
   name: projects/cdl-sec-lab/policies/compute.requireOsLogin
   spec:
     etag: CO+9vsAGEIC...
     rules:
     - enforce: true
     updateTime: '2026-09-08T11:42:07.331Z'
   ```

5. Apply a **list constraint** that blocks the most common real-world data-exposure path — public IPs on Cloud SQL — and a domain-restriction constraint that blocks external identities entirely:

   ```yaml
   # orgpolicy-list-constraints.yaml
   name: projects/cdl-sec-lab/policies/sql.restrictPublicIp
   spec:
     rules:
     - enforce: true
   ```

   ```bash
   gcloud org-policies set-policy orgpolicy-list-constraints.yaml
   gcloud org-policies list --project="$PROJECT_ID" \
     --format="table(constraint, spec.rules[0].enforce)"
   ```

   ```
   CONSTRAINT                              ENFORCE
   constraints/compute.requireOsLogin      True
   constraints/sql.restrictPublicIp        True
   ```

6. Test that the guardrail outranks your own Owner role. Attempt a violating action:

   ```bash
   gcloud compute instances add-metadata resp-demo --zone="${REGION}-b" \
     --metadata=enable-oslogin=FALSE
   gcloud compute instances describe resp-demo --zone="${REGION}-b" \
     --format="value(metadata.items.filter(\"key:enable-oslogin\").extract(value))"
   ```

   The metadata write succeeds, but OS Login remains **required** — the organization policy is evaluated at the platform layer and the instance-level opt-out is ignored. You are a Project Owner and you still cannot disable it from inside the project.

7. Add the deny layer. **IAM Deny policies** are evaluated *before* allow policies and cannot be overridden by any allow binding:

   ```json
   {
     "displayName": "Block key deletion outside the custodian group",
     "rules": [
       {
         "denyRule": {
           "deniedPrincipals": ["principalSet://goog/public:all"],
           "exceptionPrincipals": ["principalSet://goog/group/key-custodians@example.com"],
           "deniedPermissions": [
             "cloudkms.googleapis.com/cryptoKeyVersions.destroy",
             "cloudkms.googleapis.com/cryptoKeys.destroy"
           ]
         }
       }
     ]
   }
   ```

   ```bash
   gcloud iam policies create deny-key-destroy \
     --attachment-point="cloudresourcemanager.googleapis.com/projects/${PROJECT_ID}" \
     --kind=denypolicies \
     --policy-file=deny-key-destroy.json
   ```

   ```
   Created policy [deny-key-destroy].
   ```

   > **Gotcha:** if your shell or a tool does not URL-encode the attachment point, pass it pre-encoded as `cloudresourcemanager.googleapis.com%2Fprojects%2F${PROJECT_ID}`. A malformed attachment point returns `INVALID_ARGUMENT: Invalid attachment point`, not a permission error.

### Checkpoint questions

**Q9.** Define separation of duties and explain how splitting `roles/cloudkms.admin` from `roles/cloudkms.cryptoKeyEncrypterDecrypter` implements it. What attack does it stop that least privilege alone does not?

**Q10.** Order the evaluation of these three controls and state the practical consequence of that order: IAM allow policy, IAM deny policy, Organization Policy constraint.

**Q11.** Classify each as **preventive** or **detective**: (a) `constraints/sql.restrictPublicIp`, (b) a Security Command Center `PUBLIC_BUCKET_ACL` finding, (c) an IAM deny policy, (d) a Cloud Audit Log entry, (e) VPC Service Controls in enforced mode.

**Q12.** Explain **defense in depth** using exactly the layers you built in Exercises 2 and 3, from outermost to innermost.

---

## Exercise 4 — Encryption: at rest, in transit, and who holds the key

**Concept under test:** encryption is **on by default and not optional**; CMEK/CSEK/EKM change *who controls the key*, not *whether encryption happens*. This distinction is examined directly.

### Steps

1. Create a bucket and observe that it is already encrypted with **Google-managed keys** — you did nothing to ask for this:

   ```bash
   export BUCKET="gs://cdl-sec-lab-${PROJECT_NUMBER}"
   gcloud storage buckets create "$BUCKET" \
     --location="$REGION" \
     --uniform-bucket-level-access \
     --public-access-prevention

   gcloud storage buckets describe "$BUCKET" \
     --format="yaml(name, location, default_kms_key, iamConfiguration)"
   ```

   ```yaml
   default_kms_key: null
   iamConfiguration:
     publicAccessPrevention: enforced
     uniformBucketLevelAccess:
       enabled: true
       lockedTime: '2026-09-08T11:50:12.004Z'
   location: EUROPE-WEST1
   name: cdl-sec-lab-482913746215
   ```

   `default_kms_key: null` does **not** mean "unencrypted". It means the default: Google generates, rotates and stores the data encryption key (DEK), wrapped by a key encryption key (KEK) in Google's internal KMS. AES-256 at rest, always, at no cost and with no toggle.

2. Take control of the KEK — **CMEK**. Create a key ring and a rotating key:

   ```bash
   gcloud kms keyrings create cdl-sec-ring --location="$REGION"

   gcloud kms keys create bucket-cmek \
     --location="$REGION" \
     --keyring=cdl-sec-ring \
     --purpose=encryption \
     --rotation-period=90d \
     --next-rotation-time="$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)"

   gcloud kms keys describe bucket-cmek \
     --location="$REGION" --keyring=cdl-sec-ring \
     --format="yaml(name, purpose, rotationPeriod, nextRotationTime, versionTemplate)"
   ```

   ```yaml
   name: projects/cdl-sec-lab/locations/europe-west1/keyRings/cdl-sec-ring/cryptoKeys/bucket-cmek
   nextRotationTime: '2026-12-07T11:55:00Z'
   purpose: ENCRYPT_DECRYPT
   rotationPeriod: 7776000s
   versionTemplate:
     algorithm: GOOGLE_SYMMETRIC_ENCRYPTION
     protectionLevel: SOFTWARE
   ```

3. Grant the **Cloud Storage service agent** — not yourself — permission to use the key. Forgetting this is the number-one CMEK failure:

   ```bash
   export GCS_AGENT="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"

   gcloud kms keys add-iam-policy-binding bucket-cmek \
     --location="$REGION" --keyring=cdl-sec-ring \
     --member="serviceAccount:${GCS_AGENT}" \
     --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
   ```

   ```
   Updated IAM policy for key [bucket-cmek].
   bindings:
   - members:
     - serviceAccount:service-482913746215@gs-project-accounts.iam.gserviceaccount.com
     role: roles/cloudkms.cryptoKeyEncrypterDecrypter
   ```

4. Attach the key and prove it took effect on a new object:

   ```bash
   gcloud storage buckets update "$BUCKET" \
     --default-encryption-key="projects/${PROJECT_ID}/locations/${REGION}/keyRings/cdl-sec-ring/cryptoKeys/bucket-cmek"

   echo "classified payload" > sample.txt
   gcloud storage cp sample.txt "${BUCKET}/sample.txt"

   gcloud storage objects describe "${BUCKET}/sample.txt" \
     --format="yaml(name, kms_key, storage_class)"
   ```

   ```yaml
   kms_key: projects/cdl-sec-lab/locations/europe-west1/keyRings/cdl-sec-ring/cryptoKeys/bucket-cmek/cryptoKeyVersions/1
   name: sample.txt
   storage_class: STANDARD
   ```

5. Exercise the control you just bought. Disable the key version and observe that data becomes **cryptographically unreachable** — for Google too:

   ```bash
   gcloud kms keys versions disable 1 \
     --key=bucket-cmek --keyring=cdl-sec-ring --location="$REGION"

   gcloud storage cat "${BUCKET}/sample.txt"
   ```

   ```
   ERROR: (gcloud.storage.cat) HTTPError 400: Cloud KMS error when decrypting
   the object: The key used to encrypt this object has been disabled or destroyed.
   ```

   Re-enable to continue:

   ```bash
   gcloud kms keys versions enable 1 \
     --key=bucket-cmek --keyring=cdl-sec-ring --location="$REGION"
   gcloud storage cat "${BUCKET}/sample.txt"
   ```

   ```
   classified payload
   ```

6. Observe **encryption in transit**. Every Google Cloud API endpoint is TLS-only; there is no plaintext port to fall back to:

   ```bash
   curl -sS -o /dev/null -w "http=%{http_code} tls=%{ssl_verify_result}\n" \
     https://storage.googleapis.com/storage/v1/b/${BUCKET#gs://}
   curl -sS --max-time 5 http://storage.googleapis.com/ -o /dev/null -w "%{http_code}\n" 2>&1 | tail -1
   ```

   ```
   http=401 tls=0
   301
   ```

   The `401` (not `000`) proves the TLS handshake completed and certificate verification returned `0`; the request was rejected on *authentication*, not transport. Plain HTTP is `301`-redirected to HTTPS, never served.

7. Compare the three key-control models without running them (CSEK and Cloud EKM require external material). Note the syntax difference:

   ```bash
   # CSEK — you supply the raw AES-256 key, base64-encoded. Google never stores it.
   # Lose it and the data is unrecoverable, with no support path.
   gcloud storage cp secret.txt "${BUCKET}/secret.txt" \
     --encryption-key="$(openssl rand -base64 32)"    # <-- keep this string or lose the object
   ```

### Checkpoint questions

**Q13.** Is data in Cloud Storage encrypted at rest when `default_kms_key` is `null`? Answer yes/no and explain what the field actually indicates.

**Q14.** Distinguish Google-managed encryption keys, **CMEK**, **CSEK**, and **Cloud EKM** along two axes: *where the key material lives* and *who can render the data unreadable*.

**Q15.** In step 5, disabling one key version made the object unreadable. Name the compliance requirement this capability satisfies, and name the operational risk it introduces.

**Q16.** A regulator asks: "Can a Google employee read our Cloud Storage data?" Give the layered answer, naming the transparency and access-control mechanisms involved.

**Q17.** Why did the CMEK binding go to `service-<PROJECT_NUMBER>@gs-project-accounts.iam.gserviceaccount.com` rather than to your own user account?

---

## Exercise 5 — Data residency, data sovereignty, and privacy

**Concept under test:** residency (*where bytes sit*), sovereignty (*whose law governs them and who can compel access*), and privacy (*whose data it is*). The exam treats these as three different words.

### Steps

1. Prove residency is a property you choose and can verify:

   ```bash
   gcloud storage buckets describe "$BUCKET" \
     --format="value(location, location_type, custom_placement_config)"
   ```

   ```
   EUROPE-WEST1    region
   ```

2. Enforce residency organization-wide so residency is not left to whoever runs `gcloud`:

   ```yaml
   # orgpolicy-resource-locations.yaml
   name: projects/cdl-sec-lab/policies/gcp.resourceLocations
   spec:
     rules:
     - values:
         allowedValues:
         - in:eu-locations
   ```

   ```bash
   gcloud org-policies set-policy orgpolicy-resource-locations.yaml
   gcloud org-policies describe constraints/gcp.resourceLocations \
     --project="$PROJECT_ID" --effective
   ```

   ```
   name: projects/cdl-sec-lab/policies/gcp.resourceLocations
   spec:
     rules:
     - values:
         allowedValues:
         - in:eu-locations
   ```

3. Test it. A bucket outside the EU value group must now be refused:

   ```bash
   gcloud storage buckets create "gs://cdl-sec-lab-us-${PROJECT_NUMBER}" --location=us-central1
   ```

   ```
   ERROR: (gcloud.storage.buckets.create) HTTPError 412: Constraint
   constraints/gcp.resourceLocations violated for projects/cdl-sec-lab attempting
   to create a bucket in us-central1. See https://cloud.google.com/resource-manager/docs/organization-policy/defining-locations
   ```

   HTTP **412 Precondition Failed** is the signature of an organization policy denial — distinguish it from `403 PERMISSION_DENIED` (IAM) when triaging.

4. Inspect the sovereignty controls without buying them. **Assured Workloads** adds personnel-access, support-personnel-location and provider-controls guarantees on top of residency:

   ```bash
   gcloud assured workloads list \
     --organization=YOUR_ORG_ID --location=europe-west1 2>&1 | head -5
   ```

   ```
   Listed 0 items.
   ```

   *No organization?* Read the control catalogue instead:

   ```bash
   gcloud alpha assured locations list 2>&1 | head -5
   ```

5. Inventory where personal data could leak, using Cloud Asset Inventory as a free, org-wide privacy sweep:

   ```bash
   gcloud asset search-all-iam-policies \
     --scope="projects/${PROJECT_ID}" \
     --query="policy:(allUsers OR allAuthenticatedUsers)" \
     --format="table(resource, policy.bindings.role)"
   ```

   ```
   Listed 0 items.
   ```

   An empty result here is the outcome you want. Any row is a public-exposure finding.

### Checkpoint questions

**Q18.** Define data residency, data sovereignty and data privacy, and give one Google Cloud control that primarily addresses each.

**Q19.** In step 3 the failure was HTTP `412`, not `403`. What does each status tell you about *which* control blocked the request, and how does that change your remediation?

**Q20.** A European customer stores data in `europe-west1` and asks whether that alone satisfies digital-sovereignty requirements. Answer, and name the two additional dimensions Assured Workloads addresses beyond byte location.

**Q21.** Under Google Cloud's trust principles, who owns customer data, and what does Google commit regarding its use for advertising and for training?

---

## Exercise 6 — Zero trust, the perimeter, and common threats

**Concept under test:** **zero trust / BeyondCorp** ("never trust, always verify — the network is not the perimeter, identity and device posture are"), plus the threat/mitigation pairs the exam enumerates: DDoS, OWASP web attacks, data exfiltration, phishing/credential theft.

### Steps — 6a. Cloud Armor against DDoS and OWASP (project-level, free to create)

1. Create an edge security policy with Adaptive Protection (Layer 7 DDoS, ML-based):

   ```bash
   gcloud compute security-policies create cdl-edge-policy \
     --description="Zero-trust edge: WAF + rate limiting + adaptive DDoS"

   gcloud compute security-policies update cdl-edge-policy \
     --enable-layer7-ddos-defense
   ```

   ```
   Created [https://www.googleapis.com/compute/v1/projects/cdl-sec-lab/global/securityPolicies/cdl-edge-policy].
   Updated [.../securityPolicies/cdl-edge-policy].
   ```

2. Add a preconfigured WAF rule for SQL injection — you do not write the signatures, Google maintains them from the OWASP ModSecurity Core Rule Set:

   ```bash
   gcloud compute security-policies rules create 1000 \
     --security-policy=cdl-edge-policy \
     --expression="evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})" \
     --action=deny-403 \
     --description="Block SQL injection (CRS 3.3, low false-positive tier)"

   gcloud compute security-policies rules create 1100 \
     --security-policy=cdl-edge-policy \
     --expression="evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})" \
     --action=deny-403 \
     --description="Block cross-site scripting"
   ```

3. Add rate limiting — the volumetric-abuse control:

   ```bash
   gcloud compute security-policies rules create 2000 \
     --security-policy=cdl-edge-policy \
     --src-ip-ranges="*" \
     --action=throttle \
     --rate-limit-threshold-count=100 \
     --rate-limit-threshold-interval-sec=60 \
     --conform-action=allow \
     --exceed-action=deny-429 \
     --enforce-on-key=IP \
     --description="100 req/min per source IP"
   ```

4. Review the assembled policy in evaluation order (lowest priority number first):

   ```bash
   gcloud compute security-policies describe cdl-edge-policy \
     --format="table(rules[].priority, rules[].action, rules[].description)"
   ```

   ```
   PRIORITY     ACTION     DESCRIPTION
   1000         deny-403   Block SQL injection (CRS 3.3, low false-positive tier)
   1100         deny-403   Block cross-site scripting
   2000         throttle   100 req/min per source IP
   2147483647   allow      Default rule, higher priority overrides it
   ```

   > Google's global network absorbs **Layer 3/4** volumetric DDoS by default and at no charge, for every customer, with no configuration. Cloud Armor is the **Layer 7** application-aware layer you opt into.

### Steps — 6b. Identity as the perimeter

5. Inspect the VM's exposure. In a zero-trust design you do **not** open port 22 to the internet:

   ```bash
   gcloud compute firewall-rules list \
     --format="table(name, network, direction, sourceRanges.list(), allowed[].map().firewall_rule().list())"
   ```

   ```
   NAME                   NETWORK  DIRECTION  SOURCE_RANGES  ALLOWED
   default-allow-ssh      default  INGRESS    0.0.0.0/0      tcp:22
   default-allow-icmp     default  INGRESS    0.0.0.0/0      icmp
   default-allow-internal default  INGRESS    10.128.0.0/9   tcp:0-65535,udp:0-65535,icmp
   ```

   `0.0.0.0/0 → tcp:22` is exactly the implicit-trust perimeter model zero trust replaces. Remove it and use **IAP TCP forwarding**, which brokers the connection through Google's front end after verifying *identity* and *IAM authorization*:

   ```bash
   gcloud compute firewall-rules delete default-allow-ssh --quiet

   # IAP's fixed range — the only source that may reach port 22
   gcloud compute firewall-rules create allow-ssh-from-iap \
     --network=default --direction=INGRESS \
     --action=allow --rules=tcp:22 \
     --source-ranges=35.235.240.0/20 \
     --description="Zero trust: SSH only via Identity-Aware Proxy"

   gcloud compute ssh resp-demo --zone="${REGION}-b" --tunnel-through-iap --command="hostname"
   ```

   ```
   External IP address was not found; defaulting to using IAP tunneling.
   resp-demo
   ```

   The VM has **no external IP** (step 2 of Exercise 1 used `--no-address`) and the firewall no longer trusts the internet. Access is granted by IAM role `roles/iap.tunnelResourceAccessor`, not by network location.

6. Inspect the exfiltration control. **VPC Service Controls** draws a perimeter around *API services*, so stolen credentials cannot pull data out to an attacker's project:

   ```bash
   gcloud access-context-manager perimeters list \
     --policy=YOUR_ACCESS_POLICY_ID 2>&1 | head -3
   ```

   ```
   Listed 0 items.
   ```

   The production-safe creation pattern is **dry-run first** — VPC-SC in enforced mode breaks working pipelines instantly:

   ```bash
   gcloud access-context-manager perimeters dry-run create prod-data-perimeter \
     --policy=YOUR_ACCESS_POLICY_ID \
     --perimeter-title="Prod data perimeter" \
     --perimeter-resources="projects/${PROJECT_NUMBER}" \
     --perimeter-restricted-services="storage.googleapis.com,bigquery.googleapis.com" \
     --perimeter-type=regular
   ```

### Checkpoint questions

**Q22.** State the zero-trust premise in one sentence, then explain how replacing `0.0.0.0/0 → tcp:22` with IAP TCP forwarding implements it. What replaced the network as the trust signal?

**Q23.** Which DDoS protection do you receive by default with no configuration and no charge, and which requires Cloud Armor? Map each to an OSI layer.

**Q24.** Match each threat to its primary Google Cloud mitigation: (a) SQL injection, (b) volumetric L3/L4 flood, (c) exfiltration of BigQuery data by a compromised service account, (d) phishing of an administrator's password, (e) an over-permissioned custom role granted by a project owner.

**Q25.** IAM protects against unauthorized access, yet VPC Service Controls exists as a separate product. Give the concrete scenario IAM cannot address that VPC-SC does.

**Q26.** Why should VPC Service Controls perimeters be created in dry-run mode first, and what does dry-run actually produce?

---

## Exercise 7 — Audit logging: the evidence layer

**Concept under test:** the four Cloud Audit Log types, which are free and always-on versus which you must enable and pay for, and why immutability matters for compliance.

### Steps

1. Read Admin Activity logs — these are **always on, cannot be disabled, and are free**:

   ```bash
   gcloud logging read \
     'logName="projects/'"$PROJECT_ID"'/logs/cloudaudit.googleapis.com%2Factivity"' \
     --limit=3 --freshness=1d \
     --format="table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.methodName, resource.type)"
   ```

   ```
   TIMESTAMP                       PRINCIPAL_EMAIL      METHOD_NAME                         RESOURCE_TYPE
   2026-09-08T11:55:31.882Z        you@example.com      google.cloud.kms.v1.KeyManagementService.CreateCryptoKey  cloudkms_cryptokey
   2026-09-08T11:50:11.204Z        you@example.com      storage.buckets.create              gcs_bucket
   2026-09-08T11:42:07.331Z        you@example.com      SetOrgPolicy                        project
   ```

   Every administrative action from this lab is recorded with **who**, **what**, **when** and **from where** — without you configuring anything.

2. Confirm Data Access logs are **off by default** (except BigQuery) — they are high-volume and billable:

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" --format="yaml(auditConfigs)"
   ```

   ```yaml
   auditConfigs: null
   ```

3. Enable Data Access logging for Cloud Storage only, exempting a noisy pipeline service account:

   ```yaml
   # audit-config.yaml  (merge into the full policy before setting)
   auditConfigs:
   - auditLogConfigs:
     - logType: DATA_READ
       exemptedMembers:
       - serviceAccount:etl-pipeline@cdl-sec-lab.iam.gserviceaccount.com
     - logType: DATA_WRITE
     service: storage.googleapis.com
   ```

   ```bash
   gcloud projects get-iam-policy "$PROJECT_ID" --format=yaml > policy.yaml
   # append the auditConfigs block above to policy.yaml, preserving the etag
   gcloud projects set-iam-policy "$PROJECT_ID" policy.yaml
   ```

   ```
   Updated IAM policy for project [cdl-sec-lab].
   auditConfigs:
   - auditLogConfigs:
     - exemptedMembers:
       - serviceAccount:etl-pipeline@cdl-sec-lab.iam.gserviceaccount.com
       logType: DATA_READ
     - logType: DATA_WRITE
     service: storage.googleapis.com
   ```

4. Generate and retrieve a data-access event:

   ```bash
   gcloud storage cat "${BUCKET}/sample.txt" >/dev/null
   sleep 45
   gcloud logging read \
     'logName="projects/'"$PROJECT_ID"'/logs/cloudaudit.googleapis.com%2Fdata_access"
      AND protoPayload.resourceName:"sample.txt"' \
     --limit=1 --freshness=1h \
     --format="yaml(protoPayload.authenticationInfo.principalEmail, protoPayload.methodName, protoPayload.requestMetadata.callerIp)"
   ```

   ```yaml
   protoPayload:
     authenticationInfo:
       principalEmail: you@example.com
     methodName: storage.objects.get
     requestMetadata:
       callerIp: 203.0.113.44
   ```

5. Find the highest-signal query in incident response — **who changed permissions**:

   ```bash
   gcloud logging read \
     'protoPayload.methodName="SetIamPolicy"' \
     --limit=5 --freshness=7d \
     --format="table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.resourceName)"
   ```

### Checkpoint questions

**Q27.** Name the four Cloud Audit Log types and state, for each, whether it is enabled by default and whether it is billable.

**Q28.** Why can Admin Activity logs not be disabled, even by a Project Owner? Frame the answer in terms of the shared responsibility model.

**Q29.** You must prove to an auditor that no one read a specific object last quarter, but Data Access logs were never enabled. What can you truthfully claim, and what is the corrective action?

**Q30.** Classify Cloud Audit Logs as preventive, detective or corrective, and explain why the other two categories still need separate controls.

---

## Exercise 8 — Diagnosing a permission failure

**Concept under test:** operational fluency with the access model. In production, "it worked yesterday" is usually one of five causes; a leader who can name them communicates credibly with the security team.

### Steps

1. Reproduce a denial by impersonating a low-privilege service account:

   ```bash
   gcloud iam service-accounts create lowpriv-tester \
     --display-name="Least-privilege test principal"
   export SA="lowpriv-tester@${PROJECT_ID}.iam.gserviceaccount.com"

   gcloud storage buckets describe "$BUCKET" \
     --impersonate-service-account="$SA"
   ```

   ```
   ERROR: (gcloud.storage.buckets.describe) HTTPError 403: lowpriv-tester@cdl-sec-lab.iam.gserviceaccount.com
   does not have storage.buckets.get access to the Google Cloud Storage bucket.
   Permission 'storage.buckets.get' denied on resource (or it may not exist).
   ```

2. Do not guess. Ask **Policy Troubleshooter** which policy produced that answer:

   ```bash
   gcloud policy-troubleshoot iam \
     "//storage.googleapis.com/projects/_/buckets/${BUCKET#gs://}" \
     --principal-email="$SA" \
     --permission="storage.buckets.get" \
     --format="yaml(access, explainedPolicies[].access, explainedPolicies[].fullResourceName)"
   ```

   ```yaml
   access: NOT_GRANTED
   explainedPolicies:
   - access: NOT_GRANTED
     fullResourceName: //storage.googleapis.com/projects/_/buckets/cdl-sec-lab-482913746215
   - access: NOT_GRANTED
     fullResourceName: //cloudresourcemanager.googleapis.com/projects/cdl-sec-lab
   ```

   Both the bucket policy **and** the inherited project policy say `NOT_GRANTED` — so this is a missing allow binding, not a deny policy and not an organization policy.

3. Grant the minimum that fixes it, at the narrowest scope:

   ```bash
   gcloud storage buckets add-iam-policy-binding "$BUCKET" \
     --member="serviceAccount:${SA}" \
     --role="roles/storage.legacyBucketReader"

   gcloud storage buckets describe "$BUCKET" \
     --impersonate-service-account="$SA" --format="value(name)"
   ```

   ```
   cdl-sec-lab-482913746215
   ```

4. Run the reverse query — **Policy Analyzer** answers "what can this identity reach?", the question auditors actually ask:

   ```bash
   gcloud asset analyze-iam-policy \
     --scope="projects/${PROJECT_ID}" \
     --identity="serviceAccount:${SA}" \
     --format="yaml(mainAnalysis.analysisResults[].attachedResourceFullName, mainAnalysis.analysisResults[].iamBinding.role)"
   ```

   ```yaml
   mainAnalysis:
     analysisResults:
     - attachedResourceFullName: //storage.googleapis.com/projects/_/buckets/cdl-sec-lab-482913746215
       iamBinding:
         role: roles/storage.legacyBucketReader
   ```

5. Memorise the triage ladder produced by this exercise — check in this order:

   | # | Cause | Signature | Command that confirms it |
   |---|---|---|---|
   | 1 | Missing allow binding | `403` + `NOT_GRANTED` on all policies | `gcloud policy-troubleshoot iam` |
   | 2 | IAM **deny** policy | `403` + `access: DENIED` with a deny rule cited | `gcloud iam policies list-attached` |
   | 3 | Organization Policy constraint | **`412`** + `Constraint ... violated` | `gcloud org-policies describe --effective` |
   | 4 | VPC Service Controls | `403` + `VPC_SERVICE_CONTROLS` + a unique request id | `gcloud logging read 'protoPayload.status.details.violations.type="VPC_SERVICE_CONTROLS"'` |
   | 5 | Expired IAM Condition | Worked yesterday, `403` today, binding still visible | `get-iam-policy` with `--format=yaml` (needs policy `version: 3`) |
   | 6 | Disabled/destroyed CMEK key | `400` + `Cloud KMS error when decrypting` | `gcloud kms keys versions list` |

### Checkpoint questions

**Q31.** Distinguish the questions answered by Policy Troubleshooter and Policy Analyzer, and say which one an auditor asking "who can read production data?" needs.

**Q32.** A job that ran successfully for six months began returning `403` overnight, with no deployment and no IAM change in the audit log. Give the two most likely causes from the triage table and the command that distinguishes them.

**Q33.** A `403` cites `VPC_SERVICE_CONTROLS` with a unique identifier. Why is the error message deliberately vague about *what* was blocked, and what is the correct next step?

---

## Exercise 9 — Synthesis: map the scenario to the control

Do this without running commands. Each row is the shape of a Section 5 exam item.

| # | Scenario | Name the concept **and** the Google Cloud product/control |
|---|---|---|
| 1 | A retailer's checkout page is flooded with 4 Tbps of UDP traffic | |
| 2 | Auditors require proof of every permission change for 400 days | |
| 3 | A German bank must guarantee that no US-based support engineer can access its data | |
| 4 | A departing contractor's project-level `roles/editor` was never revoked | |
| 5 | A service-account key was leaked on GitHub and used to copy a BigQuery dataset to an external project | |
| 6 | Employees must reach internal apps from unmanaged laptops without a VPN | |
| 7 | A healthcare provider must be able to make patient records permanently unreadable on demand | |
| 8 | Developers keep creating Cloud SQL instances with public IPs | |
| 9 | The security team wants a single console listing misconfigurations and active threats org-wide | |
| 10 | A login form is being probed with `' OR 1=1--` | |

### Checkpoint question

**Q34.** Complete the table above.

---

## Cleanup

```bash
gcloud compute instances delete resp-demo --zone="${REGION}-b" --quiet
gcloud compute security-policies delete cdl-edge-policy --quiet
gcloud compute firewall-rules delete allow-ssh-from-iap --quiet
gcloud storage rm -r "$BUCKET"
gcloud iam service-accounts delete "$SA" --quiet
gcloud iam roles delete logTriage --project="$PROJECT_ID" --quiet
gcloud iam policies delete deny-key-destroy \
  --attachment-point="cloudresourcemanager.googleapis.com/projects/${PROJECT_ID}" --kind=denypolicies --quiet

# Org policies: reset to inherited, do not leave a project pinned to a stale constraint
for C in compute.requireOsLogin sql.restrictPublicIp gcp.resourceLocations; do
  gcloud org-policies delete "constraints/${C}" --project="$PROJECT_ID" --quiet
done

# KMS: key versions can be scheduled for destruction (24h+ delay);
# key rings and keys are PERMANENT and cannot be deleted. Budget ~$0.06/version/month.
gcloud kms keys versions destroy 1 \
  --key=bucket-cmek --keyring=cdl-sec-ring --location="$REGION" --quiet
```

```
Destroyed key version [1]. It will be destroyed after 2026-09-09T12:31:00Z.
```

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 1

**A1.** *Security **of** the cloud* is everything Google operates and secures beneath the service boundary: datacenters, custom hardware (Titan), the hypervisor, the host kernel, the global network, physical media destruction. *Security **in** the cloud* is everything the customer configures above that boundary. The customer's side always includes at least **data classification, access management (IAM) and application-layer logic** — those never transfer to Google at any service model.

**A2.** Guest OS / node OS patching:

| Service | Owner | Why |
|---|---|---|
| Compute Engine | **C** | You chose the image; you run `apt upgrade` or rebuild it |
| GKE Standard | **S** | Google publishes node images and auto-upgrade channels; **you** own the upgrade window, surge settings and whether auto-upgrade is on |
| GKE Autopilot | **G** | Google owns and patches nodes; you cannot SSH to them or install a DaemonSet that needs host privileges |
| Cloud Run | **G** | No node exists in your responsibility surface |
| BigQuery | **G** | Fully managed analytics service; no OS surface at all |

GKE Standard and Autopilot differ because Autopilot removes node-level configuration from the customer entirely — the responsibility boundary moves up with the abstraction. This is the general rule: **the more managed the service, the more of the stack Google secures, and the smaller (never zero) the customer's slice.**

**A3.** Shared fate means Google does not merely publish a boundary and leave you on the other side — it actively helps you succeed on your side and shares in the outcome. Three mechanisms: (1) **secure-by-default configurations and blueprints** (Security Foundations blueprint, Assured Workloads, hardened base images, default encryption) so the safe path is the default path; (2) **risk-protection programs** — cyber-insurance offerings from partner insurers priced off your Security Command Center posture; (3) **guardrails and posture tooling** Google builds and maintains for you (Organization Policy constraints, SCC detectors, Policy Intelligence recommendations). Shared fate does **not** transfer legal accountability: under GDPR-style regimes the customer is the **data controller** and Google Cloud is the **data processor**. Contractual and regulatory liability for the data itself remains with the customer.

**A4.** Flawed: Cloud Run removes the OS and runtime from their responsibility, but **the container image is still theirs**. Every OS package in the base image and every application dependency (npm, PyPI, Maven) can carry a CVE. They still need image scanning (Artifact Registry vulnerability scanning / Artifact Analysis), a rebuild cadence, and supply-chain controls (Binary Authorization). The artifact that carries the CVE is the **container image and its dependencies**.

### Exercise 2

**A5.** Least privilege: **grant a principal only the permissions required to perform its intended task, on only the resources it needs, for only as long as it needs them.** Evidence: `roles/editor` carries roughly **8,000 permissions** while the job "read objects in a bucket" needs **four** (`roles/storage.objectViewer`). Granting Editor to that analyst over-grants by a factor of ~2,000 and includes destructive permissions (delete VMs, modify databases, alter networks) wholly unrelated to the task.

**A6.** Best to worst: **(c) ≈ (d) > (b) > (a)**.
- (c) `roles/storage.objectViewer` on the single bucket — correct verbs, correct scope, and Google maintains it as services evolve. This is the right answer.
- (d) is functionally equivalent and equally tight, but a custom role is **operational debt**: you must maintain it yourself as the API adds permissions, and it will not automatically pick up e.g. new managed-folder permissions. Prefer a predefined role when one fits; reserve custom roles for when none does.
- (b) `roles/storage.admin` at project level — wrong verbs (**write and delete**, including `storage.buckets.delete`) and wrong scope (**every** bucket).
- (a) `roles/owner` — catastrophic over-grant; also lets the analyst change IAM and grant themselves anything else.

**A7.** An IAM Condition is a **CEL expression attached to a role binding**, evaluated at request time; the binding only takes effect when it evaluates true. Beyond "which permissions", it adds: **(1) time** — `request.time < timestamp(...)` for expiring/just-in-time access, and **(2) resource** — `resource.name.startsWith(...)` or `resource.type == ...` to narrow one binding to a subset of resources. (Request attributes such as source IP via Access Levels are a third dimension.) Conditional bindings require IAM policy **version 3**; reading the policy at version 1 hides them.

**A8.** The `etag` is an **optimistic concurrency control** token: `set-iam-policy` succeeds only if the etag you submit still matches the server's current policy. Ignoring it — writing a policy assembled from a stale read — produces the **lost update** failure mode: admin B's read-modify-write silently erases the binding admin A added seconds earlier, with no error. Always use `add-iam-policy-binding` / `remove-iam-policy-binding` (which handle the etag and retry), or preserve the etag when doing a full `set-iam-policy`.

### Exercise 3

**A9.** Separation of duties: **no single principal should control an entire sensitive workflow end to end** — the person who authorises is not the person who executes, and neither is the person who audits. The KMS split implements it because `roles/cloudkms.admin` can create, rotate, disable and schedule destruction of keys but **cannot decrypt** (it lacks `cryptoKeyVersions.useToDecrypt`), while `roles/cloudkms.cryptoKeyEncrypterDecrypter` can use keys on data but cannot create, disable or destroy them.

What it stops that least privilege alone does not: **insider abuse and undetected fraud by a single legitimately-privileged actor.** Least privilege asks "is this permission necessary for the job?" — a key custodian legitimately needs key admin, and a data operator legitimately needs decrypt. Both grants pass a least-privilege review individually. SoD is the additional rule that they must not land on the **same** principal, because that principal could then create a key, decrypt data with it, exfiltrate, and destroy the key to erase the trail. SoD constrains *combinations*; least privilege constrains *amounts*.

**A10.** Evaluation order: **Organization Policy → IAM deny policy → IAM allow policy.** Practical consequence: an Organization Policy constraint cannot be overridden by *any* IAM grant, so a Project Owner cannot grant themselves an exemption from inside the project — only someone with `roles/orgpolicy.policyAdmin` at a higher node can change it. Likewise, a deny rule beats every allow binding, including `roles/owner`. This is why guardrails are the correct control for "must never happen", and IAM is the correct control for "who may do this".

**A11.** (a) **Preventive** — the API call is refused. (b) **Detective** — SCC reports an existing misconfiguration after the fact. (c) **Preventive**. (d) **Detective** — audit logs record, they do not block. (e) **Preventive** in enforced mode (in dry-run mode it is **detective**: it logs what *would* have been blocked).

**A12.** Defense in depth = **multiple independent layers, so no single failure or bypass is sufficient**. Outermost to innermost, as built:
1. **Organization Policy** — `requireOsLogin`, `restrictPublicIp` block whole classes of unsafe configuration before IAM is even consulted.
2. **IAM deny policy** — `deny-key-destroy` blocks specific dangerous permissions regardless of any allow grant.
3. **IAM allow policy** — least-privilege predefined/custom roles define who may act at all.
4. **IAM Conditions** — narrow those grants further in time and resource scope.
5. **Separation of duties** across principals — even a compromised single account cannot complete a full destructive workflow.
6. **Cloud Audit Logs** — if every layer above fails, the action is still recorded immutably.

### Exercise 4

**A13.** **Yes.** All data at rest in Google Cloud is encrypted by default with AES-256, with no configuration, no charge and no opt-out. `default_kms_key: null` means only that **no customer-managed key is configured**, so Google generates and manages the key encryption key in its internal KMS. The field indicates *who controls the key*, not *whether encryption occurs*.

**A14.**

| Model | Where key material lives | Who can render data unreadable |
|---|---|---|
| **Google-managed (default)** | Google's internal KMS; generated, rotated and stored by Google | Google only (operationally: nobody, by design) |
| **CMEK** (Cloud KMS) | Cloud KMS in *your* project (SOFTWARE, or HSM for FIPS 140-2 L3) | **You** — disabling or destroying a key version instantly blocks all decryption, including by Google's services |
| **CSEK** | **Outside Google entirely.** You send the raw AES-256 key with each request; Google holds it in memory only and never persists it | You — and you alone bear the loss risk: lose the key and the data is unrecoverable, with no support recovery path |
| **Cloud EKM** | An external key-management partner (Thales, Fortanix, Equinix…) outside Google's infrastructure | You, via the external partner — you can revoke access to the key *and* prove the key never resided in Google's premises |

**A15.** The requirement is **crypto-shredding** (also called crypto-erase): making data permanently unreadable by destroying the key rather than overwriting the bytes. It satisfies "right to erasure"/GDPR Article 17 and record-destruction mandates at scale, since destroying one key version renders terabytes unreadable instantly. The operational risk is **self-inflicted denial of service and permanent data loss**: a mistaken key disable takes production down immediately (as in step 5), and a destroy is irreversible after the mandatory delay window. Mitigate with an IAM deny policy on `cryptoKeyVersions.destroy` (built in Exercise 3), the 24-hour-minimum destruction delay, and alerting on KMS admin events.

**A16.** Layered answer:
1. **Encryption at rest and in transit is automatic and universal**, plus data is chunked and each chunk separately encrypted and distributed — there is no single "your data" file on a disk.
2. **CMEK/Cloud EKM** let you hold the key, so Google's systems cannot decrypt if you revoke it.
3. **Access is denied by default**; Google employees have no standing access to customer content, and administrative access requires a documented, job-based justification.
4. **Access Transparency** produces logs of Google-personnel access to your content, with the reason and the ticket reference — you see it happening.
5. **Access Approval** goes further: Google must request your **explicit approval** before such access occurs, and you may deny it.
6. **Assured Workloads** can additionally constrain support personnel to specific citizenships and geographies.

**A17.** Because Cloud Storage — not you — performs the encryption and decryption. When the bucket has a CMEK, the **service agent**, a Google-managed service account created automatically per project and per service, calls Cloud KMS on the bucket's behalf. Granting yourself `cryptoKeyEncrypterDecrypter` lets *you* call KMS directly but does nothing for the service, so writes fail with `Permission denied on Cloud KMS key`. This is also a least-privilege pattern: the grant is scoped to one key and one service identity, not to a human.

### Exercise 5

**A18.**
- **Data residency** — the *physical/geographic location* where data is stored and processed. Control: `constraints/gcp.resourceLocations` plus choosing regional (not multi-region) resources.
- **Data sovereignty** — *which jurisdiction's laws govern the data and who can legally compel access to it*, including the nationality and location of the personnel who can touch it. Control: **Assured Workloads**, **Cloud EKM**, **Access Approval**, and sovereign-partner offerings.
- **Data privacy** — *whose personal data it is, and the limits on its use*. Control: **Cloud DLP / Sensitive Data Protection** for discovery, classification and de-identification, plus IAM and VPC Service Controls to limit who can reach it and Google's contractual trust principles.

**A19.** `403 PERMISSION_DENIED` means **IAM** decided: the principal lacks a required permission, or a deny rule matched. Remediation: grant the right role at the right scope, or amend the deny policy. `412 Precondition Failed` with `Constraint ... violated` means an **Organization Policy** blocked the request *before* IAM was consulted. Remediation is completely different: no IAM change can fix it — you must modify the constraint at the organization/folder/project node with `roles/orgpolicy.policyAdmin`, or comply with the constraint (choose an allowed location). Confusing the two sends teams on hours of futile IAM debugging.

**A20.** Region choice alone gives **residency**, not **sovereignty**. Sovereignty adds: **(1) personnel controls** — restricting which Google support and operations staff may access the data, by citizenship and by physical location (data sovereignty of *operations*); and **(2) survivability/key and software sovereignty** — the customer's ability to control encryption keys outside Google's infrastructure (Cloud EKM), approve or deny each administrative access (Access Approval), and in the strongest offerings run under a locally-operated partner so that no foreign legal process can compel disclosure. Assured Workloads packages these as a compliance regime applied to a folder, with continuous monitoring that flags drift.

**A21.** **The customer owns their data, not Google.** Google's stated trust principles commit that: customer data is not used for advertising; customer data is not sold to third parties; Google does not use customer data to train its models without permission; customers control where data is stored and can export or delete it at any time; access by Google personnel is limited, justified and logged (Access Transparency), and requires customer approval where Access Approval is enabled; and Google publishes its compliance certifications (ISO/IEC 27001, 27017, 27018, 27701, SOC 1/2/3, PCI DSS, HIPAA, FedRAMP, GDPR) with third-party audit reports available in Compliance Reports Manager.

### Exercise 6

**A22.** Zero trust: **no request is trusted because of where it came from; every request is authenticated, authorised and encrypted based on identity, device state and context, on every access.** The `0.0.0.0/0 → tcp:22` rule is the opposite model — it grants reachability by *network position*, and anyone who reaches the IP gets to attempt authentication. With IAP TCP forwarding, the VM has no external IP and the firewall admits only Google's IAP range (`35.235.240.0/20`); IAP terminates the connection at Google's front end, verifies the caller's **Google identity**, checks the IAM permission `iap.tunnelInstances.accessViaIAP`, and can additionally require device posture and context via Access Levels. **Verified identity (plus device and context) replaced network location as the trust signal.** This is the BeyondCorp model Google adopted internally after abandoning its own corporate VPN perimeter.

**A23.** **Layer 3/4 volumetric DDoS** (SYN floods, UDP amplification, reflection attacks) is absorbed **by default, automatically, at no additional charge** by Google's global front-end infrastructure and anycast network for anything fronted by Google's load balancers — no configuration required. **Layer 7 application-level attacks** (HTTP floods, slowloris, application-specific abuse, OWASP injection) require **Cloud Armor**, whose Adaptive Protection uses ML to baseline normal traffic and propose targeted mitigation rules, and whose preconfigured WAF rules implement the OWASP Core Rule Set.

**A24.**
- (a) SQL injection → **Cloud Armor** preconfigured WAF rule (`sqli-v33-stable`), OWASP CRS-based.
- (b) Volumetric L3/L4 flood → **Google's default DDoS protection** on the global load balancer; add Cloud Armor Adaptive Protection for the L7 component.
- (c) Exfiltration by a compromised service account → **VPC Service Controls** (the perimeter blocks the API call to a destination outside it even with valid credentials); supported by **Cloud Armor** is *not* relevant here.
- (d) Phishing of an admin password → **2-Step Verification, ideally phishing-resistant security keys (Titan/FIDO2)**, plus Cloud Identity SSO and, for high-risk accounts, the Advanced Protection Program. Google's internal deployment of security keys eliminated employee-account phishing entirely.
- (e) Over-permissioned custom role → **IAM Recommender / Policy Intelligence** (detective: flags unused permissions) plus **Organization Policy and IAM deny policies** (preventive), and SCC findings for over-privilege.

**A25.** IAM answers "**is this principal allowed to perform this operation?**" — but it cannot distinguish *where the result goes*. A service account legitimately authorised to read a BigQuery dataset, whose key is stolen, is still authorised: the attacker uses valid credentials to make an allowed API call and copies the dataset to a project they control. IAM sees nothing wrong. **VPC Service Controls** adds a service perimeter: the `bigquery.googleapis.com` API refuses requests that cross the perimeter boundary, so the same valid credentials fail when used from outside — or when used to move data outward. It defends against **credential theft, insider exfiltration and misconfigured public access**, which are precisely the cases where IAM is working exactly as configured.

**A26.** Because a VPC-SC perimeter in enforced mode blocks **every** cross-boundary API call immediately, and real environments have undocumented dependencies — a partner's ingestion job, a CI pipeline, an analytics tool, a backup in another project. Enforcing blind causes a broad, hard-to-diagnose outage. **Dry-run mode produces log entries recording every request that *would have been* denied**, without denying it (`protoPayload.metadata.dryRun: true` with `VPC_SERVICE_CONTROLS` violation details). You run it for a full business cycle, build the necessary ingress/egress rules and access levels from those logs, and only then promote to enforced.

### Exercise 7

**A27.**

| Log type | Enabled by default | Billable | Records |
|---|---|---|---|
| **Admin Activity** | Yes — **always on, cannot be disabled** | **No, free** | Config/metadata writes: `SetIamPolicy`, resource create/update/delete |
| **Data Access** | **No** (exception: BigQuery data access is on by default) | **Yes** | Reads of user data, and writes to user data |
| **System Event** | Yes — always on | **No, free** | Google-system-initiated actions, e.g. automatic live migration of a VM |
| **Policy Denied** | Yes, when a service denies access due to a security policy | **Yes** | Denials by VPC Service Controls and similar policy engines |

**A28.** Because Admin Activity logging is on Google's side of the responsibility boundary — it is part of the **platform's integrity guarantee**, not a customer-configurable feature. If a Project Owner (or an attacker who becomes one) could disable it, the log would be worthless as evidence: the first act of any compromise would be to turn it off. Making it immutable and non-disableable means Google guarantees the audit trail *of* the cloud, while the customer remains responsible for **exporting and retaining** it (log sinks to Cloud Storage with retention/Bucket Lock, or to BigQuery), for enabling the optional Data Access logs, and for actually reviewing them. Note the default retention for Admin Activity is 400 days in `_Required`; longer retention is the customer's job.

**A29.** You can truthfully claim only that **no administrative change to that object or its permissions occurred** (from Admin Activity logs) and that **the object's IAM policy did not permit access to anyone outside the recorded bindings** (from the current and historical policy, via Cloud Asset Inventory's history API). You **cannot** claim no one read it — the absence of Data Access logs is absence of evidence, not evidence of absence, and stating otherwise to an auditor would be a false attestation. Corrective action: enable `DATA_READ`/`DATA_WRITE` audit config for the relevant services now (Exercise 7 step 3), configure a log sink to a retention-locked Cloud Storage bucket or BigQuery for the required period, budget for the log volume, use `exemptedMembers` for high-volume non-sensitive service accounts, and document the gap and its start/end dates in the audit response.

**A30.** Cloud Audit Logs are **detective**. They record what happened; they never block anything and never repair anything. Preventive controls are still needed because a log entry does not stop the exfiltration it records — that requires Organization Policy, IAM deny policies, VPC-SC, firewall rules. Corrective controls are still needed because detection without response leaves the damage in place — that requires alerting on log-based metrics, automated remediation (Cloud Functions triggered by Pub/Sub from a log sink or SCC finding), key rotation, credential revocation and restore-from-backup. The three categories are complements, and **defense in depth requires all three**.

### Exercise 8

**A31.** **Policy Troubleshooter** answers a *forward, single-question* query: "**Why** does principal P have (or not have) permission X on resource R?" — it walks every policy in the inheritance chain and shows which one produced the verdict. It is the debugging tool. **Policy Analyzer** (Cloud Asset Inventory) answers the *reverse, set-valued* query: "**Which** principals can do **what** on **which** resources within this scope?" — you can pin any one, two or none of the three axes. The auditor asking "who can read production data?" needs **Policy Analyzer**, pinning the resource and the permission and asking for the set of identities, including access inherited from groups and from ancestor folders.

**A32.** The two most likely causes are **(5) an expired IAM Condition** and **(6) a disabled or destroyed CMEK key version** — both change effective access with no new IAM write appearing in the audit log. A third strong candidate is a **service account key expiry or the service account being disabled**. Distinguish by the error itself first: a CMEK failure returns **`400` with `Cloud KMS error when decrypting`**, not `403`. For a suspected expired condition, run:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --format="yaml(bindings)" | grep -A4 'condition:'
```

Reading the policy without requesting version 3 will not show conditional bindings at all — which is exactly why this cause is so often missed. Confirm with `gcloud policy-troubleshoot iam`, which evaluates conditions against the current request time and reports `CONDITIONAL` / `NOT_GRANTED`.

**A33.** The message is deliberately vague — it gives a unique identifier and no detail about the perimeter, the resource or the rule — because **the error itself must not become an information-disclosure channel**. A verbose message would tell an attacker holding stolen credentials that the resource exists, which perimeter guards it, and which service is restricted, letting them map the environment by probing. The correct next step is to give that **unique request identifier** to someone with permission to read the perimeter's violation logs, who queries:

```bash
gcloud logging read \
  'protoPayload.status.details.violations.type="VPC_SERVICE_CONTROLS"' \
  --freshness=1h --format=json
```

The log entry — visible only to authorised principals — contains the perimeter name, the violated ingress/egress rule and the caller identity.

### Exercise 9

**A34.**

| # | Concept | Control |
|---|---|---|
| 1 | Volumetric L3/L4 DDoS | Google's **default DDoS protection** on the global external load balancer (free, automatic); **Cloud Armor Adaptive Protection** for the L7 component |
| 2 | Auditability / non-repudiation | **Cloud Audit Logs** (Admin Activity, immutable) exported via a **log sink** to Cloud Storage with **Bucket Lock**/retention policy, or to BigQuery |
| 3 | Data sovereignty (personnel controls) | **Assured Workloads** (EU regions + EU-personnel support controls), reinforced by **Access Approval**, **Access Transparency** and **Cloud EKM** |
| 4 | Least privilege / stale access | **IAM Recommender** (Policy Intelligence) to surface unused permissions; **IAM Conditions** with expiry to prevent recurrence; offboarding via **Cloud Identity** to disable the principal |
| 5 | Data exfiltration with valid credentials | **VPC Service Controls** perimeter around `bigquery.googleapis.com`; prevent the root cause with **service account key constraints** (`constraints/iam.disableServiceAccountKeyCreation`) and **Workload Identity Federation** instead of downloadable keys |
| 6 | Zero trust / BeyondCorp | **Identity-Aware Proxy** with **BeyondCorp Enterprise** access levels (identity + device posture + context), no VPN |
| 7 | Crypto-shredding / right to erasure | **CMEK** in Cloud KMS — destroy the key version to render the data permanently unreadable |
| 8 | Preventive guardrail | Organization Policy **`constraints/sql.restrictPublicIp`** |
| 9 | Centralised posture and threat management | **Security Command Center** (Premium/Enterprise tiers for Event Threat Detection, Security Health Analytics, attack path simulation) |
| 10 | OWASP injection attack | **Cloud Armor** preconfigured WAF rule `sqli-v33-stable` |

</details>

---

## Sources

- Google Cloud, *Cloud Digital Leader Certification Exam Guide* — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Google Cloud, *Shared responsibilities and shared fate on Google Cloud* — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google Cloud, *IAM overview* — https://cloud.google.com/iam/docs/overview
- Google Cloud, *IAM Conditions overview* — https://cloud.google.com/iam/docs/conditions-overview
- Google Cloud, *Deny policies* — https://cloud.google.com/iam/docs/deny-overview
- Google Cloud, *Organization Policy Service* — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Google Cloud, *Restricting resource locations* — https://cloud.google.com/resource-manager/docs/organization-policy/defining-locations
- Google Cloud, *Default encryption at rest* — https://cloud.google.com/docs/security/encryption/default-encryption
- Google Cloud, *Encryption in transit* — https://cloud.google.com/docs/security/encryption-in-transit
- Google Cloud, *Customer-managed encryption keys (CMEK)* — https://cloud.google.com/kms/docs/cmek
- Google Cloud, *Cloud External Key Manager* — https://cloud.google.com/kms/docs/ekm
- Google Cloud, *Assured Workloads overview* — https://cloud.google.com/assured-workloads/docs/overview
- Google Cloud, *Access Transparency / Access Approval* — https://cloud.google.com/assured-workloads/access-approval/docs/overview
- Google Cloud, *Cloud Audit Logs overview* — https://cloud.google.com/logging/docs/audit
- Google Cloud, *VPC Service Controls overview* — https://cloud.google.com/vpc-service-controls/docs/overview
- Google Cloud, *Identity-Aware Proxy: TCP forwarding* — https://cloud.google.com/iap/docs/using-tcp-forwarding
- Google Cloud, *BeyondCorp Enterprise* — https://cloud.google.com/beyondcorp-enterprise/docs/overview
- Google Cloud, *Cloud Armor: preconfigured WAF rules* — https://cloud.google.com/armor/docs/waf-rules
- Google Cloud, *Cloud Armor Adaptive Protection* — https://cloud.google.com/armor/docs/adaptive-protection-overview
- Google Cloud, *Security Command Center overview* — https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Google Cloud, *Policy Troubleshooter / Policy Analyzer* — https://cloud.google.com/policy-intelligence/docs/troubleshoot-access
- Google Cloud, *Trust principles* — https://cloud.google.com/security/transparency