# gcp-cdl — Topic 4.1 · Guided Exercises

## Describe how Google Cloud helps organizations transition to the cloud

> **Exam alignment.** Cloud Digital Leader (version 2026-08-12), Objective 4.1, exam weight **6.0**. Source: [Cloud Digital Leader exam guide](https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf).
>
> **How to use this.** Every exercise is a numbered sequence you actually execute, followed by verification questions. The exam is non-technical, but the *decisions* it tests — which migration path, which transfer mechanism, when the discount model changes the answer — are only memorable if you have watched the tooling behave. Answers are in the collapsible section at the end.
>
> **Honesty about outputs.** Command outputs below are abbreviated and resource IDs are illustrative. Command groups marked `alpha`/`beta` (Migration Center, Migrate to Virtual Machines) change surface between releases — `gcloud <group> --help` is always authoritative over any document, including this one.

---

## Conventions and prerequisites

```bash
# Tooling
gcloud version   # expect: Google Cloud SDK 5xx.0.0 or later

# Identifiers used throughout. Substitute your own.
export PROJECT_ID="acme-migration-prod"
export REGION="us-central1"
export ZONE="us-central1-a"
export BILLING_ACCOUNT="01ABCD-234567-89EFGH"
export ORG_ID="123456789012"

gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
```

Required IAM on the project, at minimum: `roles/migrationcenter.admin`, `roles/compute.admin`, `roles/storagetransfer.admin`, `roles/datamigration.admin`, `roles/recommender.viewer`, `roles/billing.admin` on the billing account.

**Scenario used by every exercise.** *Acme Retail* runs 480 VMs across two on-premises datacenters on VMware vSphere, a 12 TB self-managed MySQL 8.0 OLTP database, a 240 TB archive of scanned documents on an NFS filer, a 90 TB Teradata data warehouse, and one SAP ECC instance the vendor supports only on specific hardware. The datacenter lease expires in 14 months. Their WAN egress link is 1 Gbps.

---

## Exercise 1 — Assess: build the inventory before you build anything else

Google's published migration framework has four phases — **assess, plan, deploy, optimize** ([Migration to Google Cloud: get started](https://cloud.google.com/architecture/migration-to-gcp-getting-started)). Everything in this exercise is phase one. You cannot cost, sequence, or choose a path for a workload you have not counted.

1. Enable the assessment-related APIs:

```bash
gcloud services enable \
  migrationcenter.googleapis.com \
  cloudasset.googleapis.com \
  recommender.googleapis.com \
  cloudbilling.googleapis.com
```

```
Operation "operations/acat.p2-84...-f3a1" finished successfully.
```

2. Migration Center is the unified assessment surface: it discovers assets, groups them, sizes Google Cloud equivalents, and produces a TCO report ([Migration Center overview](https://cloud.google.com/migration-center/docs/migration-center-overview)). Confirm the CLI surface available to you before scripting against it:

```bash
gcloud alpha migration-center --help | sed -n '/^GROUPS/,/^COMMANDS/p'
```

```
GROUPS
    assets              Manage discovered assets.
    discovery-clients   Manage discovery clients.
    groups               Manage asset groups.
    import-jobs          Manage import jobs.
    preference-sets      Manage preference sets.
    reports/report-configs
                         Manage assessment reports.
```

3. Create a group — the unit that reports are generated against. Groups are how you separate "the SAP estate" from "the 400 stateless app servers", because those two get different verdicts:

```bash
gcloud alpha migration-center groups create app-tier-dc1 \
  --location="${REGION}" \
  --description="DC1 stateless application servers"
```

```
Create request issued for: [app-tier-dc1]
Waiting for operation [operation-1757...-6b2] to complete...done.
Created group [app-tier-dc1].
```

4. Feed the inventory. Migration Center accepts three ingestion paths, and the choice is itself an exam-relevant trade-off:
   - the **discovery client** (a collector VM run inside your datacenter, continuous, includes performance samples),
   - an **RVTools export** from vSphere (`.xlsx`, one-shot, no performance history unless included),
   - a **manual CSV/file import** (last resort — accurate on shape, blind on utilization).

   Create an import job for a manual file. The exact CSV header names are validated against the published import schema, so take them from [the import-data documentation](https://cloud.google.com/migration-center/docs/import-data-overview) rather than from memory; the shape is:

```csv
MachineId,MachineName,PrimaryIPAddress,AllocatedProcessorCoreCount,MemoryMiB,AllocatedStorageBytes,OsName,OsVersion,HostingLocation
vm-0001,app-dc1-001,10.10.4.11,8,32768,536870912000,Red Hat Enterprise Linux,8.9,DC1-RackB
vm-0002,app-dc1-002,10.10.4.12,8,32768,536870912000,Red Hat Enterprise Linux,8.9,DC1-RackB
vm-0003,sap-ecc-prd,10.10.9.5,64,786432,17592186044416,SUSE Linux Enterprise Server,15.5,DC1-RackF
```

5. Validate before you execute. An import job runs in two steps — **validate**, then **run** — and this is deliberate: a malformed inventory that silently half-imports produces a TCO report that is confidently wrong.

```bash
gcloud alpha migration-center import-jobs create dc1-manual-2026q3 \
  --location="${REGION}" --asset-source=projects/${PROJECT_ID}/locations/${REGION}/sources/manual-dc1

gcloud alpha migration-center import-jobs validate dc1-manual-2026q3 --location="${REGION}"
gcloud alpha migration-center import-jobs run      dc1-manual-2026q3 --location="${REGION}"
gcloud alpha migration-center import-jobs describe dc1-manual-2026q3 --location="${REGION}" \
  --format="yaml(state, executionReport.framesReported, executionReport.executionErrors)"
```

```yaml
state: COMPLETED
executionReport:
  framesReported: 480
  executionErrors: {}
```

6. Read the number back independently. `framesReported: 480` must equal the row count you shipped:

```bash
tail -n +2 dc1-inventory.csv | wc -l
```

```
480
```

> **Checkpoint questions — block 1**
>
> **Q1.** Name the four phases of Google's migration framework in order.
> **Q2.** Acme's CFO asks for a cloud cost estimate in week one, before any discovery has run. What is wrong with producing one, in terms of the framework?
> **Q3.** Migration Center's discovery client and an RVTools export both produce an inventory. What does the discovery client give you that a one-shot RVTools export does not, and which downstream decision depends on it?
> **Q4.** Why does the import job separate `validate` from `run`?
> **Q5.** Step 6 counts rows in the CSV and compares them to `framesReported`. Why is checking the job's `state: COMPLETED` not sufficient?

---

## Exercise 2 — Plan: assign a migration path to each workload

Google names three migration paths ([Migration to Google Cloud: choosing your path](https://cloud.google.com/architecture/migration-to-gcp-getting-started)):

| Path | Also called | What changes | Typical target |
|---|---|---|---|
| **Lift and shift** | rehost | Nothing in the app | Compute Engine |
| **Improve and move** | replatform | Packaging/runtime, not the code's structure | GKE, Cloud SQL, Cloud Run |
| **Rip and replace** | refactor / rebuild | The application is rewritten or retired for a SaaS product | Managed & serverless services, Google Workspace, Marketplace SaaS |

The broader industry taxonomy adds **retire** (delete it) and **retain** (leave it where it is). Both are legitimate migration outcomes and both appear in exam scenarios.

1. Generate a preference set — this is what tells Migration Center *how* to size and price the target, e.g. sole-tenancy for licensing, committed-use assumptions, target region:

```bash
gcloud alpha migration-center preference-sets create acme-default \
  --location="${REGION}" \
  --virtual-machine-preferences-target-product=COMPUTE_ENGINE \
  --virtual-machine-preferences-region-preferences-preferred-regions="${REGION}" \
  --virtual-machine-preferences-commitment-plan=COMMITMENT_PLAN_THREE_YEAR
```

2. Produce the assessment report for the group and read the sizing verdict:

```bash
gcloud alpha migration-center reports create tco-dc1-app-tier \
  --location="${REGION}" \
  --report-config=projects/${PROJECT_ID}/locations/${REGION}/reportConfigs/acme-rc \
  --type=TOTAL_COST_OF_OWNERSHIP
```

3. Now do the part no tool does for you. Fill this table for Acme's six workload classes. Write one path per row and one sentence of justification:

| # | Workload | Constraint that dominates | Path | Target service |
|---|---|---|---|---|
| 1 | 400 stateless RHEL app servers, in-house code, low change rate | Datacenter lease, 14 months | ? | ? |
| 2 | 12 TB MySQL 8.0 OLTP, 3 ms p99 requirement | Ops burden; patching; HA | ? | ? |
| 3 | 90 TB Teradata warehouse, 200 analysts | Licence cost; concurrency ceiling | ? | ? |
| 4 | SAP ECC, vendor-certified hardware only | Vendor support matrix | ? | ? |
| 5 | Internal Exchange + file shares for 6 000 staff | Undifferentiated; commodity | ? | ? |
| 6 | 40 VMs running a decommissioned 2014 reporting tool, 0 logins in 90 days | Nobody uses it | ? | ? |

4. For workload 1, check what right-sizing would say about the machine shapes you are about to rehost. Active Assist's recommenders operate on running Compute Engine instances, so run this against a pilot wave already in Google Cloud ([Recommender docs](https://cloud.google.com/recommender/docs)):

```bash
gcloud recommender recommendations list \
  --project="${PROJECT_ID}" \
  --location="${ZONE}" \
  --recommender=google.compute.instance.MachineTypeRecommender \
  --format="table(name.basename(), \
                  content.overview.resourceName.basename():label=VM, \
                  content.overview.currentMachineType.name:label=CURRENT, \
                  content.overview.recommendedMachineType.name:label=RECOMMENDED, \
                  primaryImpact.costProjection.cost.units:label=USD_PER_MONTH)"
```

```
NAME                                  VM            CURRENT         RECOMMENDED      USD_PER_MONTH
0e9c1e2b-3f44-4a0e-9d31-8f2a1c7b55d1  app-dc1-001   n2-standard-8   n2-standard-4    -97
7a13f5c8-9b02-4d77-8e5a-2c6f4b1d90a2  app-dc1-014   n2-standard-8   n2-standard-2    -146
```

> **Checkpoint questions — block 2**
>
> **Q6.** Give the Google-preferred name for each of: rehost, replatform, refactor.
> **Q7.** For each of Acme's six workloads, state the path you chose and the single constraint that forced it.
> **Q8.** A stakeholder argues that lift and shift is "the wrong way to do cloud" and everything should be refactored before the lease expires. Give two concrete arguments for lift and shift as a *first* step, and one real cost of choosing it.
> **Q9.** The recommender in step 4 returns negative `USD_PER_MONTH` values. What does the sign mean, and why is this recommender useless during the assess phase for on-premises VMs?
> **Q10.** Which of the six workloads is the cheapest possible "migration", and what does that tell you about the value of the assessment phase?

---

## Exercise 3 — Deploy, path 1: rehost VMs with Migrate to Virtual Machines

Migrate to Virtual Machines replicates a running source VM into Google Cloud, adapts the guest OS (drivers, agents, licensing), and cuts over ([Migrate to Virtual Machines docs](https://cloud.google.com/migrate/virtual-machines/docs)).

1. Enable the service and inspect the surface:

```bash
gcloud services enable vmmigration.googleapis.com
gcloud alpha migration vms --help | sed -n '/^GROUPS/,/^COMMANDS/p'
```

2. A **migration source** represents the on-premises environment. For vSphere you deploy the Migrate Connector appliance (an OVA) inside vCenter, and it registers itself against the source. List what registered:

```bash
gcloud alpha migration vms sources list --location="${REGION}"
```

```
NAME          LOCATION      STATE   CREATE_TIME
vsphere-dc1   us-central1   ACTIVE  2026-09-02T11:04:19Z
```

3. Add VMs to a migration and start replication. The critical property: **the source VM keeps serving traffic during replication.** The connector performs a full initial copy, then repeated incremental copies using changed-block tracking, so downtime is bounded by the *final* increment, not by the total data size.

```bash
gcloud alpha migration vms migrations list \
  --source=vsphere-dc1 --location="${REGION}" \
  --format="table(name.basename(), state, lastSync.lastSyncTime, currentSyncInfo.progressPercent)"
```

```
NAME          STATE       LAST_SYNC_TIME        PROGRESS
app-dc1-001   ACTIVE      2026-09-08T02:11:47Z  100
app-dc1-002   ACTIVE      2026-09-08T02:14:02Z  100
app-dc1-003   REPLICATING 2026-09-08T01:52:10Z  61
```

4. **Test-clone before you cut over.** A clone builds a real Compute Engine instance from the latest replication snapshot while replication continues untouched. This is the rehearsal that de-risks the cut-over window:

```bash
gcloud alpha migration vms migrations clone app-dc1-001 \
  --source=vsphere-dc1 --location="${REGION}"
```

5. Validate the clone as an ordinary Compute Engine instance:

```bash
gcloud compute instances list --filter="name~app-dc1-001" \
  --format="table(name, zone.basename(), machineType.basename(), status, networkInterfaces[0].networkIP)"
```

```
NAME               ZONE           MACHINE_TYPE     STATUS   INTERNAL_IP
app-dc1-001-clone  us-central1-a  n2-standard-4    RUNNING  10.128.0.24
```

6. Cut over only after the clone passes functional tests. Cut-over stops the source VM, performs a last incremental sync, and creates the production instance.

> **Checkpoint questions — block 3**
>
> **Q11.** During replication the source VM is running. What determines the length of the cut-over outage, and why is it not proportional to the VM's disk size?
> **Q12.** What is a test-clone for, and what would you lose by skipping straight to cut-over?
> **Q13.** Acme rehosts an 8 vCPU VM that the right-sizing recommender later says should be 4 vCPU. Has the migration failed? Answer using the four-phase framework.
> **Q14.** Which phase of the framework does the test-clone belong to, and which phase does step 6's cut-over belong to?

---

## Exercise 4 — Deploy, path 2: move the data

Data movement is where migrations actually stall, and the exam tests the selection rule, not the syntax.

### 4a — Do the bandwidth arithmetic first

1. Compute the achievable daily transfer volume. Assume you can sustain ~80% of nominal link capacity:

| Link | 80% effective | Per day | 240 TB takes |
|---|---|---|---|
| 100 Mbps | 10 MB/s | 0.86 TB | ~278 days |
| 1 Gbps | 100 MB/s | 8.6 TB | **~28 days** |
| 10 Gbps | 1 GB/s | 86 TB | ~2.8 days |

2. Apply Google's published guidance: use **Transfer Appliance** — a physically shipped, encrypted storage device offered in 40 TB and 300 TB capacities — when an online transfer would take longer than roughly a week ([Transfer Appliance docs](https://cloud.google.com/transfer-appliance/docs)). Acme's 240 TB archive over 1 Gbps is 28 days *of the link being saturated*, which also starves every other workload sharing that WAN.

### 4b — Online transfer for what fits: Storage Transfer Service

3. Create an agent pool and install transfer agents next to the data ([Storage Transfer Service](https://cloud.google.com/storage-transfer/docs/overview)):

```bash
gcloud transfer agent-pools create acme-onprem-pool \
  --bandwidth-limit=400 \
  --display-name="DC1 NFS agents"

gcloud transfer agents install \
  --pool=acme-onprem-pool \
  --count=4 \
  --mount-directories=/mnt/archive
```

```
Created agent pool: projects/acme-migration-prod/agentPools/acme-onprem-pool
[4] agents installed and connected to pool [acme-onprem-pool].
```

Note `--bandwidth-limit=400` (MB/s): capping the migration so it does not consume the production WAN is a design decision, not an afterthought.

4. Create the job. A complete, syntactically valid `TransferJob` resource, which is what the CLI builds for you:

```json
{
  "description": "DC1 NFS archive -> GCS nearline landing",
  "projectId": "acme-migration-prod",
  "status": "ENABLED",
  "transferSpec": {
    "sourceAgentPoolName": "projects/acme-migration-prod/agentPools/acme-onprem-pool",
    "posixDataSource": {
      "rootDirectory": "/mnt/archive"
    },
    "gcsDataSink": {
      "bucketName": "acme-archive-landing",
      "path": "dc1/scanned-documents/"
    },
    "transferOptions": {
      "overwriteObjectsAlreadyExistingInSink": false,
      "deleteObjectsFromSourceAfterTransfer": false,
      "deleteObjectsUniqueInSink": false
    }
  },
  "schedule": {
    "scheduleStartDate": { "year": 2026, "month": 9, "day": 15 },
    "startTimeOfDay":    { "hours": 22, "minutes": 0, "seconds": 0, "nanos": 0 },
    "repeatInterval": "86400s"
  },
  "loggingConfig": {
    "logActions": ["COPY"],
    "logActionStates": ["SUCCEEDED", "FAILED"]
  }
}
```

5. The equivalent one-liner, and its output:

```bash
gcloud transfer jobs create posix:///mnt/archive gs://acme-archive-landing/dc1/scanned-documents \
  --source-agent-pool=acme-onprem-pool \
  --name=dc1-archive-nightly \
  --schedule-repeats-every=24h \
  --no-delete-from=source
```

```
Created job: transferJobs/dc1-archive-nightly
```

### 4c — Database migration with minimal downtime

6. Database Migration Service moves MySQL, PostgreSQL, Oracle and SQL Server into Cloud SQL / AlloyDB, with continuous change data capture ([DMS docs](https://cloud.google.com/database-migration/docs)). Create the source connection profile:

```bash
gcloud database-migration connection-profiles create mysql onprem-mysql-src \
  --region="${REGION}" \
  --host=10.10.9.40 --port=3306 \
  --username=dms_replica \
  --password="${DMS_PASSWORD}"     # in production: read from Secret Manager
```

7. Create the destination profile and the migration job. `--type=CONTINUOUS` is the choice that buys you a short cut-over:

```bash
gcloud database-migration connection-profiles create cloudsql acme-mysql-target \
  --region="${REGION}" \
  --source-id=onprem-mysql-src \
  --tier=db-n1-standard-8 \
  --database-version=MYSQL_8_0 \
  --storage-auto-resize \
  --root-password="${ROOT_PASSWORD}"

gcloud database-migration migration-jobs create mysql-to-cloudsql \
  --region="${REGION}" \
  --type=CONTINUOUS \
  --source=onprem-mysql-src \
  --destination=acme-mysql-target \
  --peer-vpc="projects/${PROJECT_ID}/global/networks/acme-vpc"
```

8. **Verify, then start.** `verify` runs connectivity, privilege and configuration prechecks without moving a byte:

```bash
gcloud database-migration migration-jobs verify mysql-to-cloudsql --region="${REGION}"
gcloud database-migration migration-jobs start  mysql-to-cloudsql --region="${REGION}"

gcloud database-migration migration-jobs describe mysql-to-cloudsql \
  --region="${REGION}" --format="yaml(state, phase, error)"
```

```yaml
state: RUNNING
phase: CDC
error: null
```

9. Cut over by promoting the destination. Only at this instant does the replica become a standalone, writable primary:

```bash
gcloud database-migration migration-jobs promote mysql-to-cloudsql --region="${REGION}"
```

### 4d — The warehouse

10. The 90 TB Teradata warehouse is not a data-movement problem; it is a **rip and replace** to BigQuery, and BigQuery Migration Service exists for the part that is not data: the batch SQL translator converts Teradata DDL/DML dialect into GoogleSQL ([BigQuery migration overview](https://cloud.google.com/bigquery/docs/migration-intro)).

> **Checkpoint questions — block 4**
>
> **Q15.** Acme has 240 TB on a 1 Gbps link. Show the arithmetic that decides between Storage Transfer Service and Transfer Appliance, and state the decision.
> **Q16.** What does `--bandwidth-limit=400` protect, and what does it cost you?
> **Q17.** In the DMS job, what is the practical difference between `--type=ONE_TIME` and `--type=CONTINUOUS` measured in application downtime?
> **Q18.** `promote` is a separate, explicit command. Why is that a feature rather than an extra step?
> **Q19.** Acme's team proposes moving Teradata to a large Compute Engine VM running Teradata, "to migrate first and modernize later". Name the path that represents, and one strong argument against it here that does not apply to the 400 app servers.
> **Q20.** Which of these four tools — Storage Transfer Service, Transfer Appliance, Database Migration Service, BigQuery Migration Service — is the odd one out, and why?

---

## Exercise 5 — Hybrid is a destination, not a failure

Acme's SAP ECC instance and a handful of latency-bound systems stay on-premises past the lease. Google Cloud's answer to "you cannot move everything" is hybrid connectivity plus a consistent control plane.

1. Choose the connectivity. Published options ([Network Connectivity docs](https://cloud.google.com/network-connectivity/docs/interconnect)):

| Option | Capacity | SLA on the connection | Traffic path |
|---|---|---|---|
| HA VPN | up to 3 Gbps per tunnel | 99.99% (two interfaces) | Over the public internet, IPsec-encrypted |
| Dedicated Interconnect | 10 or 100 Gbps circuits | 99.9% / 99.99% depending on topology | Private, direct to Google |
| Partner Interconnect | 50 Mbps – 50 Gbps | 99.9% / 99.99% depending on topology | Private, via a service provider |
| Direct / Carrier Peering | varies | none | Reaches Google public services, **not** your VPC |

2. Build HA VPN as the interim link while the Interconnect circuit is provisioned (Interconnect has a physical lead time; VPN does not):

```bash
gcloud compute vpn-gateways create acme-ha-vpn-gw \
  --network=acme-vpc --region="${REGION}"

gcloud compute routers create acme-cr \
  --network=acme-vpc --region="${REGION}" --asn=65001

gcloud compute external-vpn-gateways create onprem-gw \
  --interfaces 0=203.0.113.10,1=203.0.113.11

gcloud compute vpn-tunnels create tunnel-0 \
  --region="${REGION}" \
  --vpn-gateway=acme-ha-vpn-gw --interface=0 \
  --peer-external-gateway=onprem-gw --peer-external-gateway-interface=0 \
  --ike-version=2 --shared-secret="${PSK}" --router=acme-cr

gcloud compute routers add-interface acme-cr \
  --region="${REGION}" --interface-name=if-tunnel-0 \
  --vpn-tunnel=tunnel-0 --ip-address=169.254.0.2 --mask-length=30

gcloud compute routers add-bgp-peer acme-cr \
  --region="${REGION}" --peer-name=bgp-onprem-0 \
  --interface=if-tunnel-0 --peer-ip-address=169.254.0.1 --peer-asn=65500
```

3. Confirm the tunnel and the BGP session — a tunnel that is `ESTABLISHED` with no BGP session learns no routes:

```bash
gcloud compute vpn-tunnels describe tunnel-0 --region="${REGION}" \
  --format="value(status, detailedStatus)"
gcloud compute routers get-status acme-cr --region="${REGION}" \
  --format="table(result.bgpPeerStatus[].name, result.bgpPeerStatus[].state, \
                  result.bgpPeerStatus[].numLearnedRoutes)"
```

```
ESTABLISHED     Tunnel is up and running.

NAME           STATE        NUM_LEARNED_ROUTES
bgp-onprem-0   Established  14
```

4. Register the surviving on-premises Kubernetes cluster into a **fleet**, so one control plane governs both sides ([Fleet management](https://cloud.google.com/kubernetes-engine/fleet-management/docs)):

```bash
gcloud container fleet memberships register on-prem-dc1 \
  --context=onprem-admin \
  --kubeconfig="${HOME}/.kube/config" \
  --enable-workload-identity

gcloud container fleet memberships list \
  --format="table(name.basename(), endpoint.kubernetesMetadata.kubernetesApiServerVersion, state.code)"
```

```
NAME         K8S_VERSION   STATE
on-prem-dc1  v1.31.4       READY
gke-prod-1   v1.32.2       READY
```

5. Apply one policy and configuration baseline to both clusters with Config Sync and Policy Controller. `apply-spec.yaml`:

```yaml
applySpecVersion: 1
spec:
  configSync:
    enabled: true
    sourceFormat: unstructured
    syncRepo: https://github.com/acme-retail/platform-config
    syncBranch: main
    policyDir: clusters/on-prem-dc1
    secretType: token
  policyController:
    enabled: true
    templateLibraryInstalled: true
    referentialRulesEnabled: true
    auditIntervalSeconds: 60
```

```bash
gcloud container fleet config-management enable
gcloud container fleet config-management apply \
  --membership=on-prem-dc1 --config=apply-spec.yaml
gcloud container fleet config-management status
```

```
Name         Status   Last_Synced_Token  Sync_Branch  Policy_Controller
on-prem-dc1  SYNCED   a91f3c7            main         INSTALLED
gke-prod-1   SYNCED   a91f3c7            main         INSTALLED
```

> **Checkpoint questions — block 5**
>
> **Q21.** Acme needs a private, 10 Gbps, SLA-backed link to their VPC in 8 weeks. Which option, and which option would you deploy *this week* in the meantime?
> **Q22.** A colleague proposes Direct Peering to reach Compute Engine VMs on a private IP. What is wrong with that?
> **Q23.** In step 3, the tunnel is `ESTABLISHED` but `NUM_LEARNED_ROUTES` is 0. Is the migration link working? Explain.
> **Q24.** Both clusters report the same `Last_Synced_Token`. In one sentence, what business problem does that solve for an organization mid-transition?
> **Q25.** Give one reason an organization would deliberately *keep* a workload on-premises forever and still call its cloud transition successful.

---

## Exercise 6 — The landing zone and the Cloud Adoption Framework

A migration into an unstructured project sprawl is a future re-migration. The **landing zone** is the pre-built home: identity, resource hierarchy, networking, and security controls, in place before the first workload arrives ([Landing zone design](https://cloud.google.com/architecture/landing-zones)).

1. Establish the resource hierarchy — Organization → Folders → Projects → resources. Policy set at a node is inherited downward, which is the entire reason the hierarchy is a security control and not just tidiness:

```bash
gcloud resource-manager folders create --display-name="core"        --organization="${ORG_ID}"
gcloud resource-manager folders create --display-name="production"  --organization="${ORG_ID}"
gcloud resource-manager folders create --display-name="non-production" --organization="${ORG_ID}"

gcloud resource-manager folders list --organization="${ORG_ID}" \
  --format="table(displayName, name.basename(), lifecycleState)"
```

```
DISPLAY_NAME     ID             LIFECYCLE_STATE
core             451209887301   ACTIVE
production       451209887302   ACTIVE
non-production   451209887303   ACTIVE
```

2. Express the same thing as code, because a landing zone you cannot rebuild is not a landing zone. Valid Terraform:

```hcl
resource "google_folder" "production" {
  display_name = "production"
  parent       = "organizations/123456789012"
}

resource "google_project" "app_prod" {
  name            = "acme-app-prod"
  project_id      = "acme-app-prod"
  folder_id       = google_folder.production.name
  billing_account = "01ABCD-234567-89EFGH"
}

# Inherited guardrail: no VM in production may have an external IP.
resource "google_org_policy_policy" "no_external_ip" {
  name   = "${google_folder.production.name}/policies/compute.vmExternalIpAccess"
  parent = google_folder.production.name

  spec {
    rules {
      deny_all = "TRUE"
    }
  }
}
```

3. Verify the guardrail is inherited by the project, not merely declared on the folder:

```bash
gcloud org-policies describe compute.vmExternalIpAccess \
  --project="${PROJECT_ID}" --effective
```

```yaml
name: projects/acme-migration-prod/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

4. Score the *organization*, not the technology. The [Google Cloud Adoption Framework](https://cloud.google.com/adoption-framework) assesses four themes — **Learn, Lead, Scale, Secure** — across three maturity phases — **Tactical, Strategic, Transformational**. Fill it in for Acme as described:

| Theme | What it asks | Acme today | Phase |
|---|---|---|---|
| Learn | Quality and scale of upskilling; use of partners | 3 engineers self-taught, no programme | ? |
| Lead | Executive sponsorship; cross-functional teams | CTO sponsors; IT-only project team | ? |
| Scale | Use of cloud-native services; automation | Everything manual, all rehost | ? |
| Secure | Identity, controls, automated compliance | Perimeter model, manual reviews | ? |

5. Address the Learn gap explicitly — the transition is a people problem at least as much as a workload problem. Google's published levers: Google Cloud Skills Boost training and certification paths, the partner ecosystem, Professional Services Organization engagements, and programmes such as the Rapid Assessment & Migration Program (RAMP), whose assessment tooling is now surfaced through Migration Center.

> **Checkpoint questions — block 6**
>
> **Q26.** Name the four levels of the Google Cloud resource hierarchy, top to bottom.
> **Q27.** Name the four Cloud Adoption Framework themes and the three maturity phases.
> **Q28.** Assign a maturity phase to each of Acme's four rows in step 4, with one sentence each.
> **Q29.** Acme's plan says "build the landing zone after the first 50 VMs land, to show progress early." Give the strongest technical argument against, referencing step 3's output.
> **Q30.** Acme scores Tactical on Learn but has committed to a 14-month deadline. Which CAF theme predicts the migration will miss, and why is buying more cloud services not the fix?

---

## Exercise 7 — Optimize: the phase most organizations skip

Cloud economics is a shift from **CapEx** (buy hardware for peak, depreciate over 5 years) to **OpEx** (pay for consumption). That shift only pays off if someone acts on the consumption data.

1. Put a budget and alerting in place before the migration waves land, not after:

```bash
gcloud billing budgets create \
  --billing-account="${BILLING_ACCOUNT}" \
  --display-name="acme-migration-fy26" \
  --budget-amount=250000USD \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --threshold-rule=percent=0.8,basis=forecasted-spend
```

```
Created budget [billingAccounts/01ABCD-234567-89EFGH/budgets/8f2c...9b1].
```

Note the `forecasted-spend` rule: it fires on trajectory, which is the only threshold that arrives in time to change anything.

2. Find waste that a lift and shift necessarily imports — idle resources are the on-premises habit that survives the move:

```bash
gcloud recommender insights list \
  --project="${PROJECT_ID}" --location="${ZONE}" \
  --insight-type=google.compute.instance.IdleResourceInsight \
  --format="table(name.basename(), content.resourceName.basename():label=VM, \
                  insightSubtype, severity)"
```

```
NAME                                  VM             INSIGHT_SUBTYPE  SEVERITY
b0f31c9a-77d4-4f61-9c8e-2a5b41d0ee73  rpt-legacy-04  IDLE             HIGH
c4a92f18-2b60-4e35-a1d7-6f3c88b21a55  rpt-legacy-09  IDLE             HIGH
```

3. Ask Google Cloud what commitment it would buy, once the estate has stabilized:

```bash
gcloud recommender recommendations list \
  --project="${PROJECT_ID}" --location="${REGION}" \
  --recommender=google.compute.commitment.UsageCommitmentRecommender \
  --format="table(name.basename(), description, \
                  primaryImpact.costProjection.cost.units:label=MONTHLY_DELTA_USD)"
```

4. Reason about the discount model. Published mechanisms ([Compute Engine pricing](https://cloud.google.com/compute/vm-instance-pricing) — verify current rates, they change):

| Mechanism | Requires a commitment | Typical saving | Fits |
|---|---|---|---|
| Sustained use discounts (SUDs) | No — automatic | up to ~30% | Steady VMs you forgot to optimize |
| Resource-based CUDs (1 / 3 year) | Yes, to vCPU+RAM in a region | ~37% / ~55% | Predictable baseline |
| Flexible (spend-based) CUDs | Yes, to hourly spend | ~28% / ~46% | Predictable spend, changing shapes |
| Spot VMs | No | up to ~60–91% | Fault-tolerant, interruptible batch |
| Custom machine types / right-sizing | No | varies | Workloads that fit no predefined shape |

5. Now the exam-relevant judgement: work out which mechanism applies to each of Acme's cases.

   a. 400 app servers, running 24×7, shapes still being right-sized for the next 4 months.
   b. Nightly 6-hour batch render farm, fully checkpointed, tolerant of eviction.
   c. Cloud SQL production database, fixed size, staying for 3+ years.
   d. Dev/test VMs that engineers forget to stop over the weekend.

6. Model the total cost properly. On-premises spend that disappears must be counted on the credit side: hardware refresh, datacenter lease and power, hypervisor and OS licensing, storage array support contracts, and the staff hours spent patching them. Use the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) against Migration Center's sized output rather than against the source VM shapes.

> **Checkpoint questions — block 7**
>
> **Q31.** Explain the CapEx→OpEx shift in one sentence, and state the one organizational condition under which it *fails* to save money.
> **Q32.** Why is the `forecasted-spend` threshold rule more useful than the `percent=1.0` actual-spend rule?
> **Q33.** For each of the four cases in step 5, name the pricing mechanism.
> **Q34.** Why would you deliberately *not* buy a 3-year CUD in month one of a migration, even though it has the largest discount?
> **Q35.** Acme's TCO report shows Google Cloud costing 8% more per year than the current datacenter run-rate. Name three cost categories likely missing from the on-premises side of that comparison.

---

## Exercise 8 — Synthesis: sequence the whole transition

1. Produce a 14-month plan for Acme as an ordered list. Use exactly these building blocks, each once, and justify the ordering:

`Migration Center assessment` · `landing zone` · `HA VPN` · `Dedicated Interconnect` · `retire the legacy reporting tool` · `Transfer Appliance for the archive` · `pilot wave of 20 rehosted VMs` · `DMS continuous migration + promote` · `remaining 380 VMs via Migrate to VMs` · `BigQuery Migration Service for Teradata` · `fleet registration for the SAP-adjacent cluster` · `CUD purchase` · `Active Assist right-sizing loop`

2. For each block, tag it with its framework phase: **assess / plan / deploy / optimize**.

3. Identify the two blocks that could have been done in month one at essentially zero cost and would have reduced the scope of everything downstream.

> **Checkpoint questions — block 8**
>
> **Q36.** Give your ordered plan with a phase tag per block.
> **Q37.** Which two blocks are the zero-cost, scope-reducing ones from step 3?
> **Q38.** Acme's board asks for "the cloud migration" to be declared complete when the last VM cuts over. Argue, using the four-phase framework, why that is the wrong completion criterion.

---

## Cleanup

```bash
gcloud database-migration migration-jobs delete mysql-to-cloudsql --region="${REGION}" --quiet
gcloud transfer jobs delete transferJobs/dc1-archive-nightly
gcloud compute vpn-tunnels delete tunnel-0 --region="${REGION}" --quiet
gcloud compute vpn-gateways delete acme-ha-vpn-gw --region="${REGION}" --quiet
gcloud compute routers delete acme-cr --region="${REGION}" --quiet
gcloud alpha migration-center groups delete app-tier-dc1 --location="${REGION}" --quiet
gcloud container fleet memberships unregister on-prem-dc1 --context=onprem-admin
```

Verify nothing bills on: `gcloud compute instances list` and `gcloud sql instances list` should both return empty.

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — Assess

**Q1.** **Assess → Plan → Deploy → Optimize.**

**Q2.** A week-one estimate has no inventory behind it, so it prices an imagined estate. The assess phase exists precisely to produce the inputs — workload count, shapes, utilization, dependencies, licensing — that a cost model consumes. Producing the number first inverts the framework and converts a guess into a commitment the CFO will hold you to. The correct answer is a date for the estimate, not the estimate.

**Q3.** The discovery client collects **performance data over time** (actual CPU, memory, disk and network utilization), not just allocated capacity. RVTools tells you a VM was *given* 8 vCPU; the discovery client tells you it *used* 1.5. The downstream decision that depends on it is **right-sizing** — and therefore the entire cost model. Sizing Google Cloud to on-premises allocations reproduces years of over-provisioning and produces a TCO report that makes the cloud look expensive.

**Q4.** So that a malformed inventory fails loudly and completely instead of importing partially. A half-imported inventory still generates an assessment report — one that is internally consistent and externally wrong. `validate` checks the schema and reports errors before any asset is created.

**Q5.** `state: COMPLETED` means the job ran to completion, not that it ingested everything you sent. Rows can be skipped or rejected while the job as a whole succeeds. The only proof of completeness is comparing the count you shipped against `framesReported` — verify counts independently, per source, rather than trusting an aggregate status.

### Block 2 — Plan

**Q6.** rehost = **lift and shift**; replatform = **improve and move**; refactor/rebuild = **rip and replace**.

**Q7.**

| # | Workload | Dominant constraint | Path | Target |
|---|---|---|---|---|
| 1 | 400 app servers | The 14-month lease — time, not elegance | **Lift and shift** | Compute Engine |
| 2 | 12 TB MySQL | Operational burden (patching, backup, HA) that is undifferentiated work | **Improve and move** | Cloud SQL for MySQL |
| 3 | Teradata warehouse | Licence cost and a hard concurrency ceiling that no rehost removes | **Rip and replace** | BigQuery |
| 4 | SAP ECC | Vendor support matrix — an unsupported configuration is not a migration option | **Retain** (hybrid), revisit with the vendor's certified path | On-premises + Interconnect |
| 5 | Exchange + file shares | Pure commodity; running your own gives Acme no advantage | **Rip and replace** (repurchase) | Google Workspace / SaaS |
| 6 | Legacy reporting tool | Zero users in 90 days | **Retire** | Nothing |

**Q8.** For: (1) it is the only path that fits the 14-month lease for 400 applications — refactoring 400 apps in 14 months is not a schedule, it is a wish; (2) it decouples the datacenter exit from the modernization programme, so a slipping refactor no longer risks a hard lease deadline. Cost: you import your existing inefficiency — over-provisioned shapes, snowflake configuration, manual operations — and you pay for it monthly instead of having paid for it once. That debt must be retired in the optimize phase or lift and shift genuinely does cost more.

**Q9.** Negative values are **savings** — the projected monthly cost *delta* if you apply the recommendation. It is useless during assess for on-premises VMs because the recommender only observes running Compute Engine instances via Cloud Monitoring; it has no visibility into vSphere. On-premises right-sizing input comes from Migration Center's discovery client instead.

**Q10.** Workload 6, the retired reporting tool: 40 VMs that cost nothing to migrate because they are deleted. This is the assessment phase paying for itself — the cheapest workload to migrate is the one you discover nobody uses. Organizations that skip assessment migrate their dead weight and pay rent on it forever.

### Block 3 — Rehost

**Q11.** The outage equals the time to apply the **final incremental sync** plus boot and validation, because the bulk of the data was copied while the source was still serving traffic. Changed-block tracking means the last increment contains only blocks changed since the previous sync — minutes for a mostly-idle VM, regardless of whether the disk is 100 GB or 2 TB. Disk size drives the *initial* replication duration, which happens with zero downtime.

**Q12.** A test-clone builds a real Compute Engine instance from the latest replication point *while replication continues*, so you can boot the VM, run functional and integration tests, and check drivers, licensing and network reachability in the target environment — all before committing to an outage. Skipping it means your first discovery of a boot failure or a broken driver happens inside the cut-over window, with the source already stopped.

**Q13.** No. Rehosting is a **deploy**-phase outcome; right-sizing is an **optimize**-phase activity. The framework deliberately separates them so schedule pressure in deploy does not block the datacenter exit. The migration fails only if the optimize phase never happens.

**Q14.** Test-clone belongs to **deploy** (it is part of executing the migration, specifically its validation); cut-over is also **deploy**. Neither is optimize — optimize begins after the workload is running in Google Cloud and is being tuned.

### Block 4 — Data

**Q15.** 1 Gbps at ~80% effective ≈ 100 MB/s ≈ 8.6 TB/day. 240 TB ÷ 8.6 TB/day ≈ **28 days** of a fully saturated WAN. Google's guidance is to use Transfer Appliance when an online transfer would exceed roughly a week. Decision: **Transfer Appliance** (240 TB fits one 300 TB unit), keeping Storage Transfer Service for the ongoing incremental deltas after the bulk seed lands.

**Q16.** It protects the production WAN — without a cap, the transfer agents will consume the entire link and degrade every user-facing system sharing it. The cost is a longer transfer: capping at 400 MB/s on a link that could do more directly extends the elapsed migration window. It is an explicit trade of migration speed for production stability.

**Q17.** `ONE_TIME` takes a full dump and loads it; the application must be quiesced for the whole dump-plus-load duration — hours to days for 12 TB. `CONTINUOUS` performs the initial dump and then streams changes via CDC, so the application keeps writing to the source throughout; downtime is only the final cutover — stop writes, let CDC drain, promote. Minutes rather than days.

**Q18.** Because promotion is irreversible in effect: it breaks replication from the source and makes the Cloud SQL instance a standalone writable primary. Making it a separate, deliberate command means the cutover happens when *you* choose — after validation, in a maintenance window, with rollback still available up to that moment. An automatic promotion on sync would take the decision away from the operator.

**Q19.** That is **lift and shift**. The argument against, specific to this workload: the reasons to leave Teradata are its licence cost and concurrency ceiling, and rehosting carries both onto Compute Engine unchanged — you now pay Teradata licensing *plus* Google Cloud infrastructure, and the analysts still queue. For the 400 app servers, rehosting genuinely defers cost; here it *adds* cost while delivering none of the benefit. Lift and shift is right when the constraint is time; it is wrong when the constraint is the product itself.

**Q20.** **BigQuery Migration Service.** The other three move bytes from one place to another. BigQuery Migration Service's distinguishing work is translating SQL dialect and schema — converting the *logic* that surrounds the data, because a rip-and-replace changes the engine, not just the location.

### Block 5 — Hybrid

**Q21.** **Dedicated Interconnect** for the 10 Gbps private SLA-backed requirement. Deploy **HA VPN** this week: it is software-provisioned in minutes and gives 99.99% availability, covering the gap while the physical Interconnect circuit is provisioned. Running both is also the standard fallback design — VPN as backup for the Interconnect.

**Q22.** Direct Peering (and Carrier Peering) provides access to Google's **public** services and public IP endpoints; it does not connect to your VPC's private RFC 1918 address space, and it carries no SLA. Reaching Compute Engine VMs on internal IPs requires Cloud VPN or Cloud Interconnect.

**Q23.** No. The IPsec tunnel is up, but with no BGP session established and no learned routes, Cloud Router has nothing to advertise into the VPC route table and traffic has no path. `ESTABLISHED` is a statement about the tunnel, not about reachability — this is exactly why step 3 checks both, and it is a common cause of "the VPN is up but nothing works."

**Q24.** One Git commit defines policy and configuration for both the on-premises and cloud clusters, so an organization straddling two environments during a multi-year transition enforces one compliance baseline instead of maintaining two divergent ones — and drift on either side is detected and reverted automatically.

**Q25.** Legitimate reasons include: a vendor support matrix that certifies no cloud configuration (Acme's SAP ECC); data residency or regulatory constraints that no available region satisfies; sub-millisecond latency to physical plant equipment; or a workload whose remaining amortization period makes moving it economically irrational. A successful transition is one where each workload is in its *correct* location, not one where the location count is 1.

### Block 6 — Landing zone and CAF

**Q26.** **Organization → Folder → Project → Resource.**

**Q27.** Themes: **Learn, Lead, Scale, Secure.** Maturity phases: **Tactical, Strategic, Transformational.**

**Q28.**
- Learn — **Tactical.** Three self-taught engineers and no programme is individual initiative, not organizational capability.
- Lead — **Tactical**, edging toward Strategic. Executive sponsorship exists, but an IT-only team means the business is not co-owning outcomes; CAF's Strategic phase requires cross-functional teams.
- Scale — **Tactical.** All-manual and all-rehost means cloud is being consumed as rented hardware, with no automation or managed-service leverage.
- Secure — **Tactical.** A perimeter model with manual reviews is the on-premises posture transplanted; Strategic requires identity-centric controls and automated policy enforcement.

**Q29.** Because guardrails are **inherited**, and inheritance only helps resources created *under* the node that carries the policy. The `--effective` output in step 3 shows the project receiving `denyAll: true` from its ancestor folder — a project created outside that hierarchy receives nothing. Landing 50 VMs first means 50 workloads sitting in unstructured projects with no inherited policy, no consistent network, and no ownership boundaries; retrofitting them means moving projects, re-IPing networks, and re-doing IAM. The landing zone is cheap to build before the first workload and expensive after the fiftieth.

**Q30.** **Learn.** The framework's insight is that cloud adoption is limited by organizational capability, not by available technology. Buying more managed services against a Tactical Learn score increases the surface no one on staff can operate, diagnose, or secure — it converts a skills gap into an incident. The fix is a training and partner strategy (Google Cloud Skills Boost paths, certification targets, a partner or PSO engagement for the first waves) running in parallel with the migration, not after it.

### Block 7 — Optimize

**Q31.** CapEx→OpEx replaces a large up-front purchase of capacity sized for peak, depreciated over years, with metered payment for what you actually consume. It fails to save money when no one acts on consumption — if resources are provisioned for peak and never scaled down or stopped, you have kept the on-premises sizing habit and merely converted a depreciating asset into a permanent monthly bill.

**Q32.** Actual-spend thresholds are retrospective: `percent=1.0` fires when the budget is already gone, and by then the spend is unrecoverable. The forecasted-spend rule fires on trajectory — it warns you in week two that the month is heading over — which is the only alert that arrives while you can still change the outcome.

**Q33.**
- a. 400 app servers, shapes still changing → **Sustained use discounts**, applied automatically with no commitment, while right-sizing continues. Do not lock in a CUD against shapes you are about to change.
- b. Checkpointed, eviction-tolerant batch → **Spot VMs.**
- c. Fixed-size production database, 3+ years → **Committed use discount** (3-year; resource-based, or a Cloud SQL commitment as applicable).
- d. Forgotten dev/test VMs → not a pricing mechanism at all: **Active Assist idle-resource recommendations** plus scheduled instance stop/start. Discounting waste still buys waste.

**Q34.** Because a 3-year CUD commits you to a specific quantity of resources in a region, and in month one you do not yet know your steady-state shape — right-sizing, retirement of dead workloads and replatforming will all reduce and reshape consumption. Committing early locks you into paying for the *unoptimized* estate for three years, which can easily exceed the discount. Let the estate stabilize, let the Usage Commitment Recommender observe real consumption, then commit.

**Q35.** Commonly missing: (1) hardware refresh capital — the next server, storage array and network refresh cycle, plus its depreciation; (2) facilities — datacenter lease, power, cooling, physical security, and remaining lease liability; (3) licensing and support contracts — hypervisor, OS, storage array and database support renewals. Also frequently omitted: staff hours spent on patching, backup and capacity planning; disaster-recovery capacity that sits idle; and the cost of provisioning lead time (weeks to add capacity versus minutes).

### Block 8 — Synthesis

**Q36.** A defensible ordering:

| # | Block | Phase |
|---|---|---|
| 1 | Migration Center assessment | **Assess** |
| 2 | Retire the legacy reporting tool | **Plan** (acting on assessment output; removes 40 VMs from every later step) |
| 3 | Landing zone | **Plan** |
| 4 | HA VPN | **Plan/Deploy** — connectivity available in days |
| 5 | Pilot wave of 20 rehosted VMs | **Deploy** — validates the landing zone and the tooling at low risk |
| 6 | Dedicated Interconnect | **Deploy** — lands after its provisioning lead time, before the bulk waves |
| 7 | Transfer Appliance for the archive | **Deploy** — physical shipping lead time, start early |
| 8 | Remaining 380 VMs via Migrate to VMs | **Deploy** |
| 9 | DMS continuous migration + promote | **Deploy** — cutover scheduled with the app tier that depends on it |
| 10 | BigQuery Migration Service for Teradata | **Deploy** — independent track, longest because it is a rewrite |
| 11 | Fleet registration for the SAP-adjacent cluster | **Deploy** — makes the permanent hybrid state governable |
| 12 | Active Assist right-sizing loop | **Optimize** |
| 13 | CUD purchase | **Optimize** — last, after shapes have stabilized |

Ordering rationale: assessment gates everything; retirement shrinks scope before you pay to move anything; the landing zone must precede the first workload because policy is inherited; connectivity and the appliance start early because they have physical lead times; the pilot precedes the bulk wave; right-sizing precedes commitment purchasing.

**Q37.** **The Migration Center assessment** and **retiring the legacy reporting tool.** Both cost essentially nothing, and both shrink the scope of every subsequent block — the assessment right-sizes 480 VMs before they are priced or moved, and the retirement removes 40 of them outright.

**Q38.** Because the last cut-over marks the end of the **deploy** phase, and the framework has four. Declaring victory there guarantees the imported inefficiency of lift and shift — over-provisioned shapes, idle resources, unmanaged databases, on-premises operational habits — becomes permanent monthly cost, and the workloads that were rehosted to meet the lease deadline are never modernized. The honest completion criteria live in **optimize**: right-sizing applied, idle resources eliminated, commitments purchased against a stable baseline, undifferentiated operations handed to managed services, and the Cloud Adoption Framework Learn and Secure scores moved off Tactical.

</details>

---

## Sources

- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Migration to Google Cloud: get started — https://cloud.google.com/architecture/migration-to-gcp-getting-started
- Migration Center overview — https://cloud.google.com/migration-center/docs/migration-center-overview
- Migrate to Virtual Machines — https://cloud.google.com/migrate/virtual-machines/docs
- Database Migration Service — https://cloud.google.com/database-migration/docs
- Storage Transfer Service — https://cloud.google.com/storage-transfer/docs/overview
- Transfer Appliance — https://cloud.google.com/transfer-appliance/docs
- BigQuery migration overview — https://cloud.google.com/bigquery/docs/migration-intro
- Cloud Interconnect — https://cloud.google.com/network-connectivity/docs/interconnect
- Cloud VPN overview — https://cloud.google.com/network-connectivity/docs/vpn/concepts/overview
- Fleet management — https://cloud.google.com/kubernetes-engine/fleet-management/docs
- Landing zone design — https://cloud.google.com/architecture/landing-zones
- Google Cloud Adoption Framework — https://cloud.google.com/adoption-framework
- Recommender / Active Assist — https://cloud.google.com/recommender/docs
- Google Cloud Pricing Calculator — https://cloud.google.com/products/calculator