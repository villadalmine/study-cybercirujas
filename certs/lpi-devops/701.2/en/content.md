# 701.2 — Standard Components and Platforms for Software

**Certification:** LPI DevOps Tools Engineer (exam 701-100, version 2.0.0)
**Topic weight:** 5.0
**Profile:** Principal Platform Architect / Senior SRE

---

## 1. The architectural problem: you are assembling a platform, not writing one

Every non-trivial service you will ever run in production is a thin layer of your own business logic sitting on top of six or seven components that somebody else already wrote: a compute substrate, a durable store, a transactional database, a cache, a message broker, an object store, and an ingress/CDN edge. The engineering decision is almost never *"should we have a cache?"* — it is **which cache, operated by whom, with what failure semantics, at what cost, and what happens to the rest of the platform when it fails.**

This objective exists because the single most expensive class of production incident is not a bug in application code. It is a **mismatch between the guarantees a standard component actually provides and the guarantees the application assumed it provided.**

Three concrete shapes of that failure, all of which are on the exam's conceptual map:

1. **Delivery-semantics mismatch.** A team builds an order pipeline on RabbitMQ with `autoAck` enabled because it "went faster in the benchmark". A consumer pod is OOM-killed mid-transaction. The broker had already removed the message at delivery time. Orders vanish with no error, no alert, and no trace — the queue depth graph is flat and green. The component was correct; the assumption ("the broker will redeliver") was not.

2. **Responsibility-boundary mismatch.** A team migrates from self-hosted PostgreSQL to a managed DBaaS and keeps a nightly `pg_dump` cron on a bastion host. Eighteen months later the provider's automated backups are found to have a 7-day retention while the compliance requirement is 35 days, and the bastion was decommissioned in a cost-cutting sweep. Nobody owned the gap, because each side assumed the other did.

3. **Elasticity mismatch.** A serverless function is put in front of a fixed-size relational database. Traffic triples. The FaaS platform obligingly scales to 900 concurrent invocations, each opening a connection. PostgreSQL's `max_connections = 200` is exhausted in four seconds; every other service that shares the database — including the healthcheck path — starts failing. The elastic tier weaponised the inelastic one.

The discipline that prevents all three is the same: **for every standard component, know its service model, its consistency model, its delivery semantics, its scaling axis, and its cost model — and write those down as an explicit contract before the first line of code.**

---

## 2. Service models and the responsibility boundary

The classical IaaS/PaaS/SaaS split is not marketing taxonomy; it is a **map of who gets paged at 03:00**. Read the table as a responsibility matrix, not a product list.

| Layer | IaaS | CaaS | PaaS | FaaS | SaaS |
|---|---|---|---|---|---|
| Physical / DC | Provider | Provider | Provider | Provider | Provider |
| Hypervisor | Provider | Provider | Provider | Provider | Provider |
| Guest OS + kernel CVEs | **You** | Provider | Provider | Provider | Provider |
| Container runtime | **You** | Provider | Provider | Provider | Provider |
| Orchestration / scheduling | **You** | Provider* | Provider | Provider | Provider |
| Language runtime + patches | **You** | **You** (image) | Provider (buildpack) | Provider | Provider |
| Application code | **You** | **You** | **You** | **You** | Provider |
| Data / access control | **You** | **You** | **You** | **You** | **You** |
| Scaling policy | **You** | **You** | Declarative | Automatic | Provider |
| Unit of deployment | VM image | Container image | Source / buildpack | Function handler | Nothing |
| Typical lead time to first deploy | Days | Hours | Minutes | Minutes | Zero |
| Lock-in surface | Low (images, cloud-init) | Low (OCI, Kubernetes API) | Medium (buildpacks, service brokers) | **High** (event shapes, IAM, runtime) | Total |

\* Managed Kubernetes control plane; you still own the node pool unless it is a fully serverless container runtime.

**The rule that survives every re-org:** *data and access control never move to the provider.* Encryption at rest being "provider-managed" means the provider manages the cipher, not your bucket policy.

### 2.1 The cost model is part of the architecture

| Pricing axis | Where it bites | Typical magnitude (public cloud, 2026) | Architectural consequence |
|---|---|---|---|
| On-demand compute | Steady-state services | Baseline 1.0× | Never the right price for a 24/7 tier |
| Reserved / committed use | 1–3 year commitment | 0.4–0.65× | Needs a capacity forecast, creates a floor |
| Spot / preemptible | Interruptible work | 0.1–0.3× | Requires drain handling and checkpointing |
| Egress to Internet | Any chatty API or media | $0.05–0.12 / GiB | Dominates the bill for content services; motivates CDN |
| Cross-AZ traffic | Replicated datastores | $0.01–0.02 / GiB each way | A 3-AZ Kafka cluster pays for every replica hop |
| Per-request | FaaS, object storage, API gateways | $0.20–0.40 / million | Kills fine-grained chatter; batch or die |
| Provisioned IOPS | Databases | $0.05–0.65 / IOPS-month | Often exceeds the capacity cost itself |
| Managed-service premium | DBaaS vs self-hosted | 1.3–2.5× raw infra | Compare against a loaded SRE salary, not against zero |

The honest self-hosted-versus-managed calculation is:

```
cost_managed  =  list_price
cost_selfhost =  infra + (engineer_fte_fraction * loaded_salary)
                 + expected_annual_downtime_hours * revenue_per_hour
                 + opportunity_cost_of_not_building_product
```

A three-node PostgreSQL HA cluster is roughly 0.2–0.3 FTE once you count patching, major-version upgrades, backup restore drills, and failover testing. At a loaded €120k that is €24k–€36k/year before a single euro of hardware — which is why managed relational databases win for almost everyone below very large scale, and lose above it.

---

## 3. Compute: virtual machines, containers, functions

### 3.1 Trade-off matrix

| Property | VM (KVM/Xen) | microVM (Firecracker/Cloud Hypervisor) | Container (runc) | Sandboxed container (gVisor/Kata) | FaaS |
|---|---|---|---|---|---|
| Cold start | 20–60 s | 125 ms – 1 s | 50–500 ms | 200 ms – 2 s | 100 ms – 10 s cold, ~1 ms warm |
| Kernel | Own | Own (minimal) | **Shared with host** | Own / user-space | Provider's |
| Isolation boundary | Hypervisor | Hypervisor + minimal device model | namespaces, cgroups, seccomp, LSM | Syscall interception / hypervisor | Provider microVM |
| Density per host | 10–40 | 100–1 000 | 100–300 | 50–200 | n/a |
| Image size | GiB | GiB | MiB | MiB | KiB–MiB |
| Persistent local state | Native | Native | Only via volumes | Via volumes | **None** |
| Max execution time | Unbounded | Unbounded | Unbounded | Unbounded | 15 min (AWS Lambda), 60 min (Cloud Run jobs) |
| Billing granularity | Per second, 60 s minimum | Per ms | Per node-second | Per node-second | Per ms + per request |
| Live migration | Yes | Limited | No | No | n/a |
| Right for | Legacy, kernel modules, multi-tenant hard isolation | Multi-tenant serverless substrate | Stateless microservices | Untrusted code on shared nodes | Spiky, event-driven, short work |

**The container isolation caveat that gets asked in interviews and exams alike:** a container is a *process* with namespaces (`pid`, `net`, `mnt`, `uts`, `ipc`, `user`, `cgroup`), cgroup limits, a seccomp filter and an LSM profile. It is **not** a security boundary equivalent to a VM — a kernel LPE escapes it. That is precisely why Firecracker, gVisor and Kata exist: public FaaS and CaaS platforms cannot run mutually distrusting tenants on a shared kernel.

### 3.2 FaaS, portably: Knative Serving

Knative is the vendor-neutral answer to "Lambda, but on my Kubernetes". It gives you scale-to-zero, request-driven autoscaling, and revision-based traffic splitting. Full, deployable manifest:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: invoice-renderer
  namespace: functions
  labels:
    app.kubernetes.io/name: invoice-renderer
    app.kubernetes.io/part-of: billing-platform
spec:
  template:
    metadata:
      name: invoice-renderer-00007
      annotations:
        autoscaling.knative.dev/class: kpa.autoscaling.knative.dev
        autoscaling.knative.dev/metric: concurrency
        autoscaling.knative.dev/target: "20"
        autoscaling.knative.dev/min-scale: "2"
        autoscaling.knative.dev/max-scale: "60"
        autoscaling.knative.dev/window: "60s"
        autoscaling.knative.dev/scale-down-delay: "120s"
    spec:
      containerConcurrency: 25
      timeoutSeconds: 300
      responseStartTimeoutSeconds: 15
      serviceAccountName: invoice-renderer
      containers:
        - name: user-container
          image: registry.internal.example.com/billing/invoice-renderer@sha256:9f2c1d4b8a6e5037c2b1ae94d3f70c5d81ea2b46f0c9d7381ba5e6c0f4a21d38
          ports:
            - name: http1
              containerPort: 8080
          env:
            - name: PDF_ENGINE
              value: weasyprint
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
            - name: DB_DSN
              valueFrom:
                secretKeyRef:
                  name: invoice-renderer-db
                  key: dsn
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 10001
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: scratch
              mountPath: /tmp
      volumes:
        - name: scratch
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi
  traffic:
    - revisionName: invoice-renderer-00006
      percent: 90
    - revisionName: invoice-renderer-00007
      percent: 10
      tag: canary
```

Deploy and observe the scale-from-zero behaviour:

```
$ kubectl apply -f invoice-renderer.yaml
service.serving.knative.dev/invoice-renderer configured

$ kn service list -n functions
NAME               URL                                                      LATEST                   AGE   CONDITIONS   READY
invoice-renderer   http://invoice-renderer.functions.example.com             invoice-renderer-00007   12d   3 OK / 3     True

$ kn revision list -n functions
NAME                     SERVICE            TRAFFIC   TAGS     GENERATION   AGE   CONDITIONS   READY
invoice-renderer-00007   invoice-renderer        10%   canary            7   4m    3 OK / 3     True
invoice-renderer-00006   invoice-renderer        90%                     6   3d    3 OK / 3     True

$ hey -z 30s -c 200 http://invoice-renderer.functions.example.com/render
Summary:
  Total:        30.0041 secs
  Slowest:      2.9137 secs
  Fastest:      0.0193 secs
  Average:      0.1842 secs
  Requests/sec: 1083.4

Latency distribution:
  50% in 0.0921 secs
  95% in 0.6110 secs
  99% in 2.4483 secs

$ kubectl get pods -n functions -l serving.knative.dev/service=invoice-renderer
NAME                                                     READY   STATUS    RESTARTS   AGE
invoice-renderer-00007-deployment-6b47c9f5d8-2xq4k       2/2     Running   0          31s
invoice-renderer-00007-deployment-6b47c9f5d8-7hjvn       2/2     Running   0          28s
invoice-renderer-00007-deployment-6b47c9f5d8-c9pmz       2/2     Running   0          25s
...
```

The `2/2` is the user container plus the `queue-proxy` sidecar — Knative's per-pod request buffer, concurrency enforcer and metrics source. When you debug a Knative latency problem, **read `queue-proxy` logs before the application's**: it is the component that reports queueing delay separately from handler time.

> **The connection-pool trap, in one manifest.** The service above can reach 60 replicas × 25 concurrency = 1 500 in-flight requests. If each opens its own PostgreSQL connection, you need a connection pooler (PgBouncer in transaction mode) between them, or `max-scale` must be bounded by `max_connections / connections_per_pod`. Elastic tiers must never be allowed to overrun inelastic ones — this is the single most common serverless-plus-RDBMS outage.

---

## 4. Storage: block, file, object — and the CDN edge

### 4.1 The three shapes of persistence

| | Block | File | Object |
|---|---|---|---|
| Unit | Fixed-size blocks on a raw device | Files in a POSIX hierarchy | Immutable blobs + metadata under a key |
| Access | `/dev/nvme1n1`, formatted by you | `open()/read()/write()`, byte-range | HTTP `GET`/`PUT`/`DELETE` of whole objects |
| Mutation | In-place, byte-level | In-place, byte-level | **Replace whole object** (or multipart) |
| Typical latency | 0.1–1 ms local NVMe; 0.5–10 ms network | 0.5–5 ms | 20–200 ms time-to-first-byte |
| Sharing | One writer (`ReadWriteOnce`) | Many writers (`ReadWriteMany`) | Unlimited concurrent readers |
| Consistency | Strong | Close-to-open (NFS) | Strong read-after-write for PUT/DELETE (S3 since Dec 2020) |
| Scaling ceiling | Per-volume (tens of TiB) | Per-filesystem | Effectively unbounded |
| Cost / GiB-month | $0.08–0.12 (+ IOPS) | $0.16–0.30 | $0.004–0.023 |
| Right for | Databases, write-ahead logs | Shared assets, legacy apps, home dirs | Backups, media, data lake, artifacts, logs |
| Products | EBS, Cinder, Ceph RBD, iSCSI/NVMe-oF | NFS, SMB, CephFS, EFS, Manila | S3, Swift, MinIO, Ceph RGW, GCS |

**The rule of thumb that costs the least money:** put databases on block, put everything that is written once and read many times on object, and use file storage only when an application you cannot change demands a POSIX path shared between writers. `ReadWriteMany` volumes are the slowest, most expensive and most fragile of the three; every one of them in a design is a question to answer, not a default.

**Object storage APIs.** S3 is the de-facto standard wire protocol; OpenStack Swift is the other major one, and Ceph RADOS Gateway speaks both. MinIO, Ceph RGW and Swift's S3 middleware let you run the S3 API on-premises — which is the single most effective anti-lock-in decision available in the storage layer, because backup tooling, log shippers, CI artifact stores and data-lake engines all speak S3 and nothing else.

### 4.2 Consuming storage declaratively on Kubernetes (CSI)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  throughput: "500"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:eu-central-1:111122223333:key/6f1a2b3c-4d5e-6789-abcd-ef0123456789
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
  - matchLabelExpressions:
      - key: topology.ebs.csi.aws.com/zone
        values:
          - eu-central-1a
          - eu-central-1b
          - eu-central-1c
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: orders-db-data
  namespace: data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 200Gi
```

Two parameters in that manifest are architectural decisions disguised as fields:

- `reclaimPolicy: Retain` — with `Delete`, removing a namespace destroys the underlying volume. On any stateful workload this is a one-keystroke data-loss primitive.
- `volumeBindingMode: WaitForFirstConsumer` — with `Immediate`, the volume is provisioned in a zone chosen before the scheduler has placed the pod, and the pod can become permanently `Pending` because no node in that zone has capacity.

Verification:

```
$ kubectl get pvc -n data orders-db-data
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
orders-db-data   Bound    pvc-3f7a1e2c-9b04-4d61-8a7e-2c5d18f0b933   200Gi      RWO            fast-ssd       6d

$ kubectl get pv pvc-3f7a1e2c-9b04-4d61-8a7e-2c5d18f0b933 -o jsonpath='{.spec.nodeAffinity}' | jq .
{
  "required": {
    "nodeSelectorTerms": [
      {
        "matchExpressions": [
          {
            "key": "topology.ebs.csi.aws.com/zone",
            "operator": "In",
            "values": [
              "eu-central-1b"
            ]
          }
        ]
      }
    ]
  }
}
```

That output is the answer to "why does my stateful pod never reschedule after a node failure?" — the PV is pinned to one zone, so the replacement pod can only be scheduled there.

### 4.3 Static versus dynamic content, and the CDN

| | Static content | Dynamic content |
|---|---|---|
| Produced by | Build step, uploaded once | Application, per request |
| Varies by | URL only (plus `Accept-Encoding`) | Session, tenant, geography, time |
| Cacheable at edge | Yes, for months | Rarely; only with surrogate keys and purge |
| Ideal origin | Object storage bucket | Application tier |
| Correct headers | `Cache-Control: public, max-age=31536000, immutable` | `Cache-Control: private, no-store` |
| Cost driver | Egress (mitigated by CDN hit ratio) | CPU and database IOPS |

The CDN is the only component on this list that simultaneously improves latency, reduces cost and increases availability, and it does so **only if content is addressed immutably**. Fingerprint the filename (`app.7f3c91a2.js`) and cache it forever; never cache `app.js` and then try to purge it globally under incident pressure.

```
$ curl -sSI https://cdn.example.com/assets/app.7f3c91a2.js
HTTP/2 200
content-type: application/javascript; charset=utf-8
content-length: 284713
cache-control: public, max-age=31536000, immutable
etag: "7f3c91a2b4e6"
age: 84213
x-cache: HIT
x-cache-hits: 1842
server-timing: cdn-cache;desc=HIT, edge;dur=2

$ curl -sSI https://api.example.com/v1/orders/8812
HTTP/2 200
content-type: application/json
cache-control: private, no-store
x-cache: MISS
server-timing: origin;dur=41
```

`age`, `x-cache` and `server-timing` are the three headers to check first when someone reports "the deploy did not go out" — a stale edge object explains it far more often than a broken pipeline.

---

## 5. Databases: relational and NoSQL

### 5.1 Choosing a data model

| Family | Examples | Data model | Consistency | Scaling axis | Transactions | Best fit | Failure mode to plan for |
|---|---|---|---|---|---|---|---|
| Relational (OLTP) | PostgreSQL, MySQL/MariaDB, SQL Server | Tables, enforced schema, joins | Strong, serialisable available | Vertical + read replicas; sharding is manual | Full ACID, multi-row | Anything with invariants across entities: money, inventory, identity | Connection exhaustion; replication lag on read replicas |
| Key-value | Redis, Memcached, DynamoDB, etcd | Opaque value under a key | Redis: strong per-node; DynamoDB: tunable | Horizontal, trivially | Limited (Lua, single-item) | Sessions, cache, counters, feature flags | Hot key; unbounded memory growth |
| Document | MongoDB, Couchbase, DocumentDB | JSON-like documents, flexible schema | Tunable read/write concern | Horizontal via shard key | Multi-document since MongoDB 4.0 | Aggregates read whole, evolving schema | Wrong shard key = permanent hotspot |
| Wide-column | Cassandra, ScyllaDB, HBase, Bigtable | Partition key + clustering columns | Tunable quorum (`ONE`…`ALL`) | Horizontal, linear | Lightweight transactions only | Time series, very high write volume | Tombstones; queries the partition key does not support |
| Graph | Neo4j, JanusGraph, Neptune | Nodes and edges with properties | Usually strong | Mostly vertical | ACID (Neo4j) | Fraud rings, permissions, recommendations | Supernodes; traversal explosion |
| Search | Elasticsearch, OpenSearch, Solr | Inverted index, documents | **Near real-time, not a system of record** | Horizontal via shards | None | Full-text, log analytics, facets | Used as a primary store; split-brain on old versions |
| Columnar OLAP | ClickHouse, Druid, BigQuery, Redshift | Column-oriented, compressed | Eventually consistent inserts | Horizontal | Limited | Aggregations over billions of rows | Point lookups and `UPDATE`s |
| Time series | Prometheus, InfluxDB, TimescaleDB, VictoriaMetrics | Series = metric + labels, downsampled | Eventual | Horizontal (federation/sharding) | None | Metrics, IoT telemetry | Label cardinality explosion |

### 5.2 CAP, and the part everyone forgets: PACELC

CAP says that during a network **P**artition you must choose between **C**onsistency and **A**vailability. It is true and it is nearly useless for daily design, because partitions are rare. **PACELC** is the version you actually apply:

> **if P**artition then (**A**vailability or **C**onsistency) **e**lse (**L**atency or **C**onsistency)

| System | During partition | Normal operation |
|---|---|---|
| PostgreSQL (sync replication) | PC — refuses writes | EC — pays latency for durability |
| PostgreSQL (async replication) | PA — primary keeps accepting | EL — replicas can serve stale reads |
| Cassandra `QUORUM` | PC | EC |
| Cassandra `ONE` | PA | EL |
| DynamoDB (eventually consistent read) | PA | EL |
| DynamoDB (strongly consistent read) | PC | EC |
| MongoDB `w:majority` | PC | EC |
| etcd / ZooKeeper (Raft, ZAB) | **PC always** — minority side stops | EC |

The "else" branch is the one you live with 99.99 % of the time. A read replica two seconds behind the primary is not a partition; it is the everyday latency-versus-consistency trade, and the bug it produces is *"I saved it and the next page says it does not exist."* Fix it with read-your-writes routing (send a session's reads to the primary for N seconds after a write), not by making every read strongly consistent.

### 5.3 A complete, production-shaped PostgreSQL cluster (CloudNativePG)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: orders-db
  namespace: data
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.2
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover
  enableSuperuserAccess: false

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: 4GB
      effective_cache_size: 12GB
      work_mem: 16MB
      maintenance_work_mem: 512MB
      wal_compression: "on"
      max_wal_size: 4GB
      min_wal_size: 1GB
      checkpoint_completion_target: "0.9"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
      log_min_duration_statement: "500"
      log_checkpoints: "on"
      log_lock_waits: "on"
      log_autovacuum_min_duration: "0"
      shared_preload_libraries: pg_stat_statements
      track_io_timing: "on"
    pg_hba:
      - hostssl orders orders_app 10.42.0.0/16 scram-sha-256
      - hostssl all all 0.0.0.0/0 reject
    synchronous:
      method: any
      number: 1

  bootstrap:
    initdb:
      database: orders
      owner: orders_app
      secret:
        name: orders-db-app-credentials
      encoding: UTF8
      localeCollate: C
      localeCType: C
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS pg_stat_statements
        - CREATE EXTENSION IF NOT EXISTS pgcrypto

  storage:
    size: 200Gi
    storageClass: fast-ssd
  walStorage:
    size: 50Gi
    storageClass: fast-ssd

  resources:
    requests:
      cpu: "2"
      memory: 8Gi
    limits:
      cpu: "4"
      memory: 16Gi

  affinity:
    enablePodAntiAffinity: true
    topologyKey: topology.kubernetes.io/zone
    podAntiAffinityType: required

  monitoring:
    enablePodMonitor: true

  backup:
    retentionPolicy: 35d
    barmanObjectStore:
      destinationPath: "s3://platform-backups/orders-db"
      endpointURL: "https://s3.eu-central-1.amazonaws.com"
      s3Credentials:
        accessKeyId:
          name: backup-object-store
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: backup-object-store
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 8
      data:
        compression: gzip
        immediateCheckpoint: false
        jobs: 4
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: orders-db-nightly
  namespace: data
spec:
  schedule: "0 30 2 * * *"
  backupOwnerReference: self
  cluster:
    name: orders-db
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: orders-db-rw-pool
  namespace: data
spec:
  cluster:
    name: orders-db
  instances: 3
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "2000"
      default_pool_size: "40"
      reserve_pool_size: "10"
      reserve_pool_timeout: "3"
      server_idle_timeout: "120"
```

Note `schedule: "0 30 2 * * *"` — CloudNativePG uses a **six-field** cron expression (seconds first). Writing a five-field expression there is a classic silent misconfiguration: backups run at the wrong time or not at all.

Operate and verify it:

```
$ kubectl cnpg status orders-db -n data
Cluster Summary
Name:                orders-db
Namespace:           data
System ID:           7412908371445023745
PostgreSQL Image:    ghcr.io/cloudnative-pg/postgresql:17.2
Primary instance:    orders-db-1
Primary start time:  2026-09-11 08:14:02 +0000 UTC (uptime 7d04h)
Status:              Cluster in healthy state
Instances:           3
Ready instances:     3
Current Write LSN:   3F/6A1C4E80 (Timeline: 4 - WAL File: 0000000400000
                     03F00000006A)

Certificates Status
Certificate Name          Expiration Date                Days Left Until Expiration
----------------          ---------------                --------------------------
orders-db-ca              2027-06-08 08:11:41 +0000 UTC  263.00
orders-db-replication     2027-06-08 08:11:41 +0000 UTC  263.00
orders-db-server          2027-06-08 08:11:41 +0000 UTC  263.00

Continuous Backup status
First Point of Recoverability:  2026-08-14T02:31:07Z
Working WAL archiving:          OK
WALs waiting to be archived:    0
Last Archived WAL:              000000040000003F0000006A   @   2026-09-18T09:02:11Z

Streaming Replication status
Name         Sent LSN     Write LSN    Flush LSN    Replay LSN   Write Lag  Flush Lag  Replay Lag  State      Sync State  Sync Priority
----         --------     ---------    ---------    ----------   ---------  ---------  ----------  -----      ----------  -------------
orders-db-2  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  00:00:00   00:00:00   00:00:00    streaming  quorum      1
orders-db-3  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C4E80  3F/6A1C1220  00:00:00   00:00:00   00:00:00.001 streaming  quorum      1

Instances status
Name         Database Size  Current LSN  Replication role  Status  QoS         Manager Version  Node
----         -------------  -----------  ----------------  ------  ---         ---------------  ----
orders-db-1  147 GB         3F/6A1C4E80  Primary           OK      Burstable   1.24.1           node-a-07
orders-db-2  147 GB         3F/6A1C4E80  Standby (sync)    OK      Burstable   1.24.1           node-b-03
orders-db-3  147 GB         3F/6A1C1220  Standby (sync)    OK      Burstable   1.24.1           node-c-11
```

Deliberate failover drill — the only way to know HA works:

```
$ kubectl cnpg promote orders-db orders-db-2 -n data
Node orders-db-2 in cluster orders-db will be promoted

$ kubectl get pods -n data -l cnpg.io/cluster=orders-db -w
NAME          READY   STATUS    RESTARTS   AGE
orders-db-1   1/1     Running   0          7d4h
orders-db-2   1/1     Running   0          7d4h
orders-db-3   1/1     Running   0          7d4h
orders-db-1   0/1     Running   0          7d4h
orders-db-1   1/1     Running   0          7d4h

$ kubectl get endpoints -n data orders-db-rw
NAME           ENDPOINTS           AGE
orders-db-rw   10.42.3.117:5432    7d4h
```

Measured service interruption on a healthy three-node cluster is typically **2–8 seconds** — the time to fence the old primary, promote the standby and repoint the `-rw` Service. Your application must retry idempotent writes across that window, or the "HA" database still produces a user-visible outage.

---

## 6. Caches

### 6.1 Redis versus Memcached

| | Redis (Valkey) | Memcached |
|---|---|---|
| Data types | Strings, lists, sets, sorted sets, hashes, streams, bitmaps, HyperLogLog, geo | Strings only |
| Persistence | RDB snapshots + AOF | None |
| Replication | Async primary/replica; Redis Cluster shards | None (client-side sharding) |
| Threading | Single-threaded command loop (+ I/O threads) | Multi-threaded |
| Max item size | 512 MiB | 1 MiB default |
| Eviction | 8 policies (`allkeys-lru`, `volatile-ttl`, …) | LRU per slab class |
| Cluster mode | Native, 16 384 hash slots | Client-side consistent hashing |
| Scripting / transactions | Lua, `MULTI`/`EXEC`, functions | No |
| Pub/Sub, streams, locks | Yes | No |
| Memory efficiency for tiny values | Lower (richer structures) | Higher (slab allocator) |
| Right for | Almost everything: cache, queue, rate limiter, leaderboard, session store | Pure, huge, simple LRU cache with multi-core throughput needs |

Redis is the default choice in 2026; Memcached remains genuinely better only for very large, very simple caches where multi-threaded throughput per node dominates and no data structure beyond `GET`/`SET` is needed.

### 6.2 Caching patterns and their failure modes

| Pattern | Write path | Read path | Failure mode |
|---|---|---|---|
| Cache-aside (lazy) | App writes DB, invalidates key | Miss → DB → populate | Stampede on a hot key expiry; stale window between write and invalidate |
| Read-through | Same | Cache library loads from DB | Same stampede; hides DB errors behind cache errors |
| Write-through | App writes cache, cache writes DB synchronously | Always hit | Write latency = cache + DB; cache becomes critical path |
| Write-behind | App writes cache, async flush to DB | Always hit | **Data loss on cache failure** — only for tolerable data |
| Refresh-ahead | Background refresh before TTL | Always hit | Wasted work on cold keys |

**Cache stampede** (thundering herd) is the incident you should be able to describe from memory: one very popular key expires, ten thousand concurrent requests miss simultaneously, all ten thousand query the database, the database saturates, latency climbs, more requests pile up. Three mitigations, applied together:

1. **Jittered TTL** — `ttl = base + rand(0, base * 0.1)` so keys never expire in lockstep.
2. **Per-key mutex / single-flight** — the first miss takes a short lock (`SET key:lock 1 NX PX 5000`) and refills; the rest wait briefly or serve stale.
3. **Serve-stale-while-revalidate** — keep a soft TTL inside the value; past soft TTL serve the stale value and refresh in the background.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  namespace: data
data:
  redis.conf: |
    bind 0.0.0.0
    protected-mode yes
    port 6379
    maxmemory 6gb
    maxmemory-policy allkeys-lru
    maxmemory-samples 10
    save ""
    appendonly no
    tcp-keepalive 60
    timeout 0
    lazyfree-lazy-eviction yes
    lazyfree-lazy-expire yes
    latency-monitor-threshold 100
    slowlog-log-slower-than 10000
    slowlog-max-len 256
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis-cache
  namespace: data
spec:
  serviceName: redis-cache
  replicas: 1
  selector:
    matchLabels:
      app: redis-cache
  template:
    metadata:
      labels:
        app: redis-cache
    spec:
      securityContext:
        fsGroup: 999
        runAsUser: 999
        runAsNonRoot: true
      containers:
        - name: redis
          image: redis:7.4-alpine
          args:
            - /etc/redis/redis.conf
          ports:
            - name: redis
              containerPort: 6379
          resources:
            requests:
              cpu: "1"
              memory: 7Gi
            limits:
              cpu: "2"
              memory: 7Gi
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - "redis-cli ping | grep -q PONG"
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - "redis-cli ping | grep -q PONG"
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/redis
      volumes:
        - name: config
          configMap:
            name: redis-config
```

`maxmemory 6gb` against a 7 GiB container limit is deliberate: Redis accounts for its dataset, not for copy-on-write during `BGSAVE`, replica buffers or fragmentation. Setting `maxmemory` equal to the cgroup limit is how you get an OOM-kill instead of an eviction.

Diagnosis session:

```
$ kubectl exec -n data redis-cache-0 -- redis-cli info stats | head -20
# Stats
total_connections_received:184023
total_commands_processed:2914773219
instantaneous_ops_per_sec:41208
total_net_input_bytes:418273401923
total_net_output_bytes:1209374012883
rejected_connections:0
sync_full:0
expired_keys:18402711
evicted_keys:9127334
keyspace_hits:2610338211
keyspace_misses:203114882

$ kubectl exec -n data redis-cache-0 -- redis-cli info memory | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
used_memory_human:5.94G
maxmemory_human:6.00G
mem_fragmentation_ratio:1.31

$ kubectl exec -n data redis-cache-0 -- redis-cli --bigkeys --memkeys -i 0.01
[00.00%] Biggest string found so far '"session:d41d8cd98f00"' with 1284 bytes
[12.41%] Biggest hash   found so far '"cart:9928374"' with 214 fields
[63.02%] Biggest zset   found so far '"leaderboard:global"' with 1840223 members

-------- summary -------
Sampled 8241093 keys in the keyspace!
```

Hit ratio here is 2610338211 / (2610338211 + 203114882) = **92.8 %**. `evicted_keys` growing steadily while `used_memory` sits at `maxmemory` means the working set no longer fits — either scale memory or shorten TTLs. `mem_fragmentation_ratio` above ~1.5 justifies `activedefrag yes`; below 1.0 means Redis is swapping, which is an emergency.

---

## 7. Message queues and brokers

### 7.1 The comparison that matters

| | Apache Kafka | RabbitMQ | NATS JetStream | ActiveMQ Artemis | Redis Streams | AWS SQS | ZeroMQ |
|---|---|---|---|---|---|---|---|
| Model | Distributed **commit log** | **Broker** with exchanges + queues | Subject-based messaging + stream store | JMS broker | Log in memory/AOF | Managed queue | **Library**, no broker |
| Consumption | Pull, consumer group owns partitions | Push (prefetch), competing consumers | Pull or push | Push | Pull (`XREADGROUP`) | Pull (long poll) | Direct socket |
| Message retained after read | **Yes** (time/size based) | No (ack removes) | Yes (configurable) | No | Yes (until `XTRIM`) | No | n/a |
| Replay | Native (seek to offset) | Requires re-publish | Native | No | Native | No | No |
| Ordering | Per partition | Per queue (single consumer) | Per subject/stream | Per queue | Per stream | FIFO queues only | n/a |
| Delivery semantics | At-least-once; exactly-once within Kafka via idempotent producer + transactions | At-least-once (manual ack) | At-least-once, exactly-once window | At-least-once | At-least-once | At-least-once (standard) / exactly-once (FIFO) | At-most-once by default |
| Routing intelligence | **Dumb broker, smart consumer** | **Smart broker** (direct/topic/fanout/headers) | Subject wildcards | JMS selectors | None | None | n/a |
| Throughput/node | Very high (100 k–1 M msg/s) | Moderate (20–50 k msg/s) | Very high | Moderate | High | Managed | Highest (no broker) |
| Latency | ms (batching tunable) | sub-ms possible | **µs–ms** | ms | sub-ms | 10–100 ms | µs |
| Protocol | Custom binary | AMQP 0-9-1, MQTT, STOMP | NATS protocol | AMQP 1.0, MQTT, STOMP, OpenWire | RESP | HTTPS API | Raw TCP/IPC |
| Operational weight | High (KRaft/ZK, rebalances, partitions) | Medium | Low (single binary) | Medium | Low | **Zero** | Zero (but you build everything) |
| Right for | Event streaming, log aggregation, CDC, replayable pipelines | Task queues with complex routing, RPC, priorities | Edge/IoT, microservice RPC, low latency | Java/JMS estates | Already-have-Redis, modest volume | AWS-native decoupling | In-process/intra-DC patterns with no durability need |

**The single most important distinction on this table** is *smart broker / dumb consumer* (RabbitMQ) versus *dumb broker / smart consumer* (Kafka). RabbitMQ decides where a message goes, tracks per-message acknowledgement, and forgets it once acked — excellent for work distribution. Kafka appends to a partitioned log, remembers nothing about individual consumers except a committed offset, and keeps the data for days — excellent for many independent consumers reading the same events at their own pace, and for replaying history after a bug.

**ZeroMQ is not a broker.** It is a socket library that gives you PUB/SUB, REQ/REP, PUSH/PULL and DEALER/ROUTER patterns with no server, no persistence and no delivery guarantee. Knowing that it belongs in a different category from the other six is exactly the kind of distinction this objective tests.

### 7.2 A complete Kafka deployment (Strimzi, KRaft mode)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  replicas: 3
  roles:
    - controller
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 20Gi
        class: fast-ssd
        deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 1000Gi
        class: fast-ssd
        deleteClaim: false
  resources:
    requests:
      cpu: "2"
      memory: 16Gi
    limits:
      cpu: "4"
      memory: 16Gi
  jvmOptions:
    -Xms: 6g
    -Xmx: 6g
  template:
    pod:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              strimzi.io/cluster: platform-events
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: platform-events
  namespace: messaging
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.9.0
    metadataVersion: "3.9-IV0"
    listeners:
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
      - name: external
        port: 9094
        type: loadbalancer
        tls: true
        authentication:
          type: scram-sha-512
        configuration:
          bootstrap:
            annotations:
              external-dns.alpha.kubernetes.io/hostname: kafka.example.com
    authorization:
      type: simple
      superUsers:
        - CN=platform-admin
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      auto.create.topics.enable: false
      unclean.leader.election.enable: false
      log.retention.hours: 168
      log.segment.bytes: 1073741824
      num.replica.fetchers: 4
      replica.lag.time.max.ms: 30000
      compression.type: producer
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics
          key: kafka-metrics-config.yml
  entityOperator:
    topicOperator: {}
    userOperator: {}
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders.created.v1
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  partitions: 12
  replicas: 3
  config:
    retention.ms: "604800000"
    segment.bytes: "1073741824"
    min.insync.replicas: "2"
    cleanup.policy: delete
    max.message.bytes: "1048576"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: customers.state.v1
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  partitions: 12
  replicas: 3
  config:
    cleanup.policy: compact
    min.cleanable.dirty.ratio: "0.1"
    delete.retention.ms: "86400000"
    min.insync.replicas: "2"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: orders-service
  namespace: messaging
  labels:
    strimzi.io/cluster: platform-events
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: orders.created.v1
          patternType: literal
        operations:
          - Describe
          - Write
        host: "*"
      - resource:
          type: group
          name: orders-consumer
          patternType: prefix
        operations:
          - Read
        host: "*"
```

Note `host: "*"` — quoted, because an unquoted `*` is a YAML alias token and the document would fail to parse.

The two `cleanup.policy` values encode a real architectural distinction: `delete` for **event streams** (facts that happened, retained for a window), `compact` for **state topics** (the latest value per key, retained forever). A compacted topic is a distributed, replayable key-value store — the foundation of the "database inside out" pattern and of Kafka Streams' state stores.

Verification and lag diagnosis:

```
$ kubectl -n messaging exec -it platform-events-broker-0 -- bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --describe --topic orders.created.v1
Topic: orders.created.v1  TopicId: 8Kx2mQ1nTx-PqW0dRf7ZxA  PartitionCount: 12  ReplicationFactor: 3  Configs: min.insync.replicas=2,segment.bytes=1073741824,retention.ms=604800000,cleanup.policy=delete
    Topic: orders.created.v1  Partition: 0  Leader: 3  Replicas: 3,4,5  Isr: 3,4,5  Elr:   LastKnownElr:
    Topic: orders.created.v1  Partition: 1  Leader: 4  Replicas: 4,5,3  Isr: 4,5,3  Elr:   LastKnownElr:
    Topic: orders.created.v1  Partition: 2  Leader: 5  Replicas: 5,3,4  Isr: 5,3      Elr:   LastKnownElr:
    ...

$ kubectl -n messaging exec -it platform-events-broker-0 -- bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 --describe --group orders-consumer

GROUP            TOPIC              PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG      CONSUMER-ID                                     HOST           CLIENT-ID
orders-consumer  orders.created.v1  0          48210394        48210401        7        consumer-orders-1-9a1c...-0  /10.42.2.31    consumer-orders-1
orders-consumer  orders.created.v1  1          48198221        48198230        9        consumer-orders-2-4f70...-0  /10.42.3.19    consumer-orders-2
orders-consumer  orders.created.v1  2          47110882        48203994        1093112  consumer-orders-3-1b2e...-0  /10.42.1.44    consumer-orders-3
orders-consumer  orders.created.v1  3          48204118        48204118        0        consumer-orders-4-7c93...-0  /10.42.2.88    consumer-orders-4
...
```

Two findings in one screen:

- **Partition 2 has `Isr: 5,3` while `Replicas: 5,3,4`** — broker 4 has fallen out of the in-sync replica set. With `min.insync.replicas=2` the partition still accepts `acks=all` writes, but it is now one failure away from rejecting all writes. This is the state to alert on, *before* it becomes an outage.
- **Partition 2 has 1 093 112 messages of lag while its siblings have single digits** — lag concentrated on one partition is never "the consumers are slow". It is a **hot partition** caused by a skewed partition key (for example, one large tenant's ID hashing to partition 2), or one poisoned message the consumer keeps failing on and re-reading. Even lag across all partitions is a capacity problem; skewed lag is a keying problem, and adding consumers will not fix it — a consumer group cannot have more active consumers than partitions.

### 7.3 RabbitMQ: quorum queues, DLX, and the operational view

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: tasks
  namespace: messaging
spec:
  replicas: 3
  image: rabbitmq:4.0-management
  resources:
    requests:
      cpu: "1"
      memory: 4Gi
    limits:
      cpu: "2"
      memory: 4Gi
  persistence:
    storageClassName: fast-ssd
    storage: 100Gi
  rabbitmq:
    additionalConfig: |
      cluster_partition_handling = pause_minority
      vm_memory_high_watermark.relative = 0.6
      disk_free_limit.absolute = 10GB
      channel_max = 512
      management.rates_mode = basic
    additionalPlugins:
      - rabbitmq_prometheus
      - rabbitmq_shovel
  override:
    statefulSet:
      spec:
        template:
          spec:
            topologySpreadConstraints:
              - maxSkew: 1
                topologyKey: topology.kubernetes.io/zone
                whenUnsatisfiable: DoNotSchedule
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: invoices-work
  namespace: messaging
spec:
  name: invoices.work
  vhost: "/"
  type: quorum
  durable: true
  rabbitmqClusterReference:
    name: tasks
  arguments:
    x-queue-type: quorum
    x-delivery-limit: 5
    x-dead-letter-exchange: invoices.dlx
    x-dead-letter-routing-key: invoices.failed
---
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: invoices-dead
  namespace: messaging
spec:
  name: invoices.dead
  vhost: "/"
  type: quorum
  durable: true
  rabbitmqClusterReference:
    name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Exchange
metadata:
  name: invoices-dlx
  namespace: messaging
spec:
  name: invoices.dlx
  vhost: "/"
  type: direct
  durable: true
  rabbitmqClusterReference:
    name: tasks
---
apiVersion: rabbitmq.com/v1beta1
kind: Binding
metadata:
  name: invoices-dead-binding
  namespace: messaging
spec:
  vhost: "/"
  source: invoices.dlx
  destination: invoices.dead
  destinationType: queue
  routingKey: invoices.failed
  rabbitmqClusterReference:
    name: tasks
```

`x-delivery-limit: 5` plus a dead-letter exchange is the **poison-message circuit breaker**. Without it, one message the consumer cannot process is redelivered forever, burning CPU and blocking the queue — a genuine production outage caused by a single malformed payload.

```
$ kubectl exec -n messaging tasks-server-0 -- rabbitmqctl list_queues \
    name type messages messages_ready messages_unacknowledged consumers memory
Timeout: 60.0 seconds ...
Listing queues for vhost / ...
name             type    messages  messages_ready  messages_unacknowledged  consumers  memory
invoices.work    quorum  18432     18420           12                       6          78123456
invoices.dead    quorum  41        41              0                        0          212992
notifications    quorum  0         0               0                        12         98304

$ kubectl exec -n messaging tasks-server-0 -- rabbitmqctl cluster_status
Cluster status of node rabbit@tasks-server-0.tasks-nodes.messaging ...
Basics
Cluster name: tasks

Disk Nodes
rabbit@tasks-server-0.tasks-nodes.messaging
rabbit@tasks-server-1.tasks-nodes.messaging
rabbit@tasks-server-2.tasks-nodes.messaging

Running Nodes
rabbit@tasks-server-0.tasks-nodes.messaging
rabbit@tasks-server-1.tasks-nodes.messaging
rabbit@tasks-server-2.tasks-nodes.messaging

Feature flags
Flag: quorum_queue, state: enabled
Flag: stream_queue, state: enabled
Flag: message_containers, state: enabled
```

`messages_ready` climbing with `consumers` non-zero means consumers are too slow or `prefetch` is too low. `messages_unacknowledged` large and static means consumers took messages and stopped acking — check for a deadlock or a blocked I/O call in the handler. A growing `invoices.dead` is your poison-message signal and should be alerted on: it is silent by construction.

### 7.4 Choosing delivery semantics deliberately

| Guarantee | How it is achieved | Cost | When it is right |
|---|---|---|---|
| At-most-once | Auto-ack / fire-and-forget | Cheapest, lowest latency | Metrics, telemetry samples, anything where loss is invisible |
| At-least-once | Manual ack after processing; producer retries | Duplicates **will** happen | The default for almost all business events |
| Effectively-once | At-least-once + idempotent consumer (dedup key, upsert, idempotency table) | One extra store lookup per message | Payments, orders, anything with a money-shaped side effect |
| Exactly-once (broker-native) | Kafka idempotent producer + transactions, read-committed isolation | ~10–20 % throughput, broker coupling | Kafka-to-Kafka stream processing only |

The practical rule: **assume at-least-once and make the consumer idempotent.** "Exactly-once" across a broker and an external system (a database, a payment gateway, an email provider) does not exist without a distributed transaction the external system almost certainly does not offer. An idempotency key stored alongside the business write is the design that actually holds.

---

## 8. Big data and analytics platforms

| Engine | Paradigm | Latency class | Storage it reads | Scaling unit | Right for | Failure mode |
|---|---|---|---|---|---|---|
| Hadoop MapReduce | Batch, disk-bound | Minutes–hours | HDFS | Node | Legacy ETL; largely superseded | Small-files problem on HDFS NameNode |
| Apache Spark | Batch + micro-batch, in-memory DAG | Seconds–hours | HDFS, S3, JDBC, Delta/Iceberg | Executor | General ETL, ML pipelines, large joins | Executor OOM from data skew; shuffle spill |
| Apache Flink | True streaming, event time, stateful | Milliseconds | Kafka, S3 | Task slot | Continuous processing, windowed aggregation, CEP | Checkpoint/state backend growth |
| Trino / Presto | Distributed MPP SQL, federated | Seconds | S3, Hive, Iceberg, RDBMS | Worker | Interactive ad-hoc SQL across sources | Coordinator memory; unbounded queries |
| Elasticsearch / OpenSearch | Inverted index, near real time | Milliseconds | Own shards | Data node | Full-text, log search, observability | Shard explosion; field-mapping explosion; **not a system of record** |
| ClickHouse | Columnar OLAP, vectorised | Milliseconds–seconds | Own MergeTree, S3 | Shard/replica | High-cardinality analytics, product metrics | Too many small `INSERT`s → merge storm |
| Apache Druid | Real-time columnar OLAP | Sub-second | Deep storage + segments | Historical/MiddleManager | Time-sliced dashboards | Operational complexity |

### 8.1 Batch versus streaming, architecturally

| | Lambda architecture | Kappa architecture |
|---|---|---|
| Paths | Two: batch (accurate) + speed (fast) | One: stream only |
| Reprocessing | Rerun the batch job | Replay the log from offset 0 |
| Code duplication | **Yes** — two implementations of the same logic | No |
| Correctness reconciliation | Batch layer overwrites speed layer | Single source of truth |
| Prerequisite | None | A durable, replayable log (Kafka with long retention) |
| Operational burden | High | Moderate |

Kappa is the modern default precisely because a Kafka topic with 30-day retention makes "reprocess everything with the fixed code" a replay rather than a second codebase.

### 8.2 Spark on Kubernetes

```
$ spark-submit \
    --master k8s://https://k8s-api.internal.example.com:6443 \
    --deploy-mode cluster \
    --name orders-daily-rollup \
    --class com.example.analytics.OrdersRollup \
    --conf spark.kubernetes.namespace=analytics \
    --conf spark.kubernetes.container.image=registry.internal.example.com/analytics/spark:3.5.4 \
    --conf spark.kubernetes.authenticate.driver.serviceAccountName=spark \
    --conf spark.executor.instances=20 \
    --conf spark.executor.cores=4 \
    --conf spark.executor.memory=12g \
    --conf spark.executor.memoryOverhead=2g \
    --conf spark.driver.memory=4g \
    --conf spark.sql.shuffle.partitions=400 \
    --conf spark.sql.adaptive.enabled=true \
    --conf spark.sql.adaptive.skewJoin.enabled=true \
    --conf spark.hadoop.fs.s3a.endpoint=s3.eu-central-1.amazonaws.com \
    --conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.WebIdentityTokenCredentialsProvider \
    --conf spark.kubernetes.executor.deleteOnTermination=true \
    s3a://platform-artifacts/analytics/orders-rollup-2.1.0.jar \
    --date 2026-09-17

26/09/18 09:41:02 INFO SparkKubernetesClientFactory: Auto-configuring K8S client using current context
26/09/18 09:41:04 INFO KubernetesClientUtils: Spark configuration files loaded from Some(/opt/spark/conf)
26/09/18 09:41:06 INFO LoggingPodStatusWatcherImpl: State changed, new state:
     pod name: orders-daily-rollup-b41f7c93f2a10d84-driver
     namespace: analytics
     phase: Pending
26/09/18 09:41:19 INFO LoggingPodStatusWatcherImpl: State changed, new state:
     phase: Running
26/09/18 09:48:37 INFO LoggingPodStatusWatcherImpl: Container final statuses:
     container name: spark-kubernetes-driver
     exit code: 0
26/09/18 09:48:37 INFO LoggingPodStatusWatcherImpl: Application orders-daily-rollup finished.
```

`spark.sql.adaptive.skewJoin.enabled=true` is the setting that turns most "one executor runs for three hours while nineteen idle" incidents into a normal run. Data skew is the dominant Spark failure mode, and AQE splits oversized partitions at runtime.

---

## 9. Application runtimes and Platform as a Service

### 9.1 PaaS comparison

| | Cloud Foundry | OpenShift | Heroku | Knative | Dokku |
|---|---|---|---|---|---|
| Deploy unit | Source or droplet (`cf push`) | Source (S2I), Dockerfile, image | Source (git push) | Container image | Source (git push) |
| Build mechanism | Buildpacks | S2I / Dockerfile / Cloud Native Buildpacks | Buildpacks | External (you build) | Buildpacks |
| Underlying orchestrator | Diego, or Kubernetes (Korifi) | Kubernetes | Dyno manager | Kubernetes | Docker on one host |
| Backing services | Service broker (OSB API) | Operators / Service Binding | Add-ons marketplace | Bring your own | Plugins |
| Routing | Gorouter | Router (HAProxy) / Gateway API | Router | Kourier / Istio / Contour | nginx |
| Scale to zero | No | No (Serverless add-on: yes) | Eco dynos sleep | **Yes** | No |
| Multi-tenancy | Orgs / spaces | Projects + SCC | Teams | Namespaces | None |
| Self-hostable | Yes | Yes | No | Yes | Yes |
| Right for | Large enterprises with a 12-factor mandate | Enterprises already on Kubernetes needing developer self-service | Small teams, fastest path to production | Event-driven workloads on existing Kubernetes | A single host, personal projects |

### 9.2 Cloud Foundry: the canonical PaaS interaction

```yaml
---
applications:
  - name: orders-api
    memory: 1G
    disk_quota: 1G
    instances: 4
    stack: cflinuxfs4
    buildpacks:
      - java_buildpack_offline
    path: build/libs/orders-api-2.4.1.jar
    health-check-type: http
    health-check-http-endpoint: /actuator/health/readiness
    health-check-invocation-timeout: 5
    timeout: 120
    routes:
      - route: orders.apps.example.com
      - route: orders-internal.apps.internal
    services:
      - orders-postgres
      - orders-redis
      - orders-kafka
    env:
      SPRING_PROFILES_ACTIVE: production
      JAVA_OPTS: "-XX:MaxRAMPercentage=75"
      JBP_CONFIG_OPEN_JDK_JRE: "{ jre: { version: 21.+ } }"
      OTEL_SERVICE_NAME: orders-api
```

`JBP_CONFIG_OPEN_JDK_JRE` must be quoted: an unquoted value starting with `{` is parsed by YAML as a flow mapping, and the buildpack would receive a rendered map instead of the literal string it expects.

```
$ cf push -f manifest.yml
Pushing app orders-api to org platform / space production as ci@example.com...
Applying manifest file /workspace/manifest.yml...
Uploading files...
 3.41 MiB / 3.41 MiB [=========================================] 100.00% 2s

Staging app and tracing logs...
   Downloading java_buildpack_offline...
   Downloaded java_buildpack_offline (242.1M)
   Cell 6b8a2f1c creating container for instance 0f3a...
   Downloading build artifacts cache...
   -----> Java Buildpack v4.68 | https://github.com/cloudfoundry/java-buildpack.git
   -----> Downloading Jvmkill Agent 1.17.0 from https://java-buildpack.cloudfoundry.org/...
   -----> Downloading Open Jdk JRE 21.0.5_11 from https://java-buildpack.cloudfoundry.org/...
          Expanding Open Jdk JRE to .java-buildpack/open_jdk_jre (1.4s)
   -----> Downloading Spring Auto Reconfiguration 2.15.0 ...
          Uploading droplet (118.2M)

Waiting for app orders-api to start...

name:              orders-api
requested state:   started
routes:            orders.apps.example.com, orders-internal.apps.internal
last uploaded:     Thu 18 Sep 09:52:14 UTC 2026
stack:             cflinuxfs4
buildpacks:        java_buildpack_offline

type:            web
sidecars:
instances:       4/4
memory usage:    1024M
     state     since                  cpu    memory         disk           logging
#0   running   2026-09-18T09:53:02Z   3.1%   412.9M of 1G   198.4M of 1G   0/s of unlimited
#1   running   2026-09-18T09:53:04Z   2.8%   408.1M of 1G   198.4M of 1G   0/s of unlimited
#2   running   2026-09-18T09:53:07Z   3.4%   417.2M of 1G   198.4M of 1G   0/s of unlimited
#3   running   2026-09-18T09:53:09Z   2.9%   404.6M of 1G   198.4M of 1G   0/s of unlimited

$ cf env orders-api | head -30
Getting env variables for app orders-api in org platform / space production...

System-Provided:
VCAP_SERVICES
{
  "postgresql": [
    {
      "label": "postgresql",
      "name": "orders-postgres",
      "plan": "ha-200",
      "credentials": {
        "host": "pg-7841.service.internal",
        "port": 5432,
        "database": "orders",
        "username": "u_a91f",
        "uri": "postgresql://u_a91f:REDACTED@pg-7841.service.internal:5432/orders"
      }
    }
  ]
}
```

`VCAP_SERVICES` is the concrete implementation of **twelve-factor factor III (config in the environment) and factor IV (backing services as attached resources)**. The application never hard-codes a database host; it reads the binding the platform injected. The Kubernetes equivalent is a `Secret` projected as environment variables or a file, produced by a Service Binding or an operator — same contract, different mechanism.

### 9.3 Buildpacks versus Dockerfiles

| | Cloud Native Buildpacks | Dockerfile |
|---|---|---|
| Input | Source code | Explicit instructions |
| Base image updates | **Rebase without rebuilding** (`pack rebase`) | Full rebuild required |
| Security patching at scale | One builder update rebases thousands of apps | Every repo must be touched |
| Reproducibility | High (fixed builder, SBOM emitted) | Depends entirely on discipline |
| Flexibility | Limited to detected languages | Total |
| Layer optimisation | Automatic (deps vs app code) | Manual |
| Right for | Many similar services, central platform team | Unusual runtimes, system packages, precise control |

```
$ pack build registry.internal.example.com/billing/orders-api:2.4.1 \
    --builder paketobuildpacks/builder-jammy-base \
    --env BP_JVM_VERSION=21 \
    --publish
jammy-base: Pulling from paketobuildpacks/builder-jammy-base
Digest: sha256:fd1e9a2c8b4737f0e51c2a9d8c4e71b03fa62d5c9e1a7b48d0a3f2c65e91b774
===> DETECTING
5 of 18 buildpacks participating
paketo-buildpacks/ca-certificates   3.8.5
paketo-buildpacks/bellsoft-liberica 10.7.2
paketo-buildpacks/syft              1.45.0
paketo-buildpacks/gradle            7.6.1
paketo-buildpacks/spring-boot       5.29.1
===> BUILDING
Paketo Buildpack for BellSoft Liberica 10.7.2
  https://github.com/paketo-buildpacks/bellsoft-liberica
  Build Configuration:
    $BP_JVM_VERSION 21  the Java version
  Launch Configuration:
    $BPL_JVM_HEAD_ROOM  0   the headroom in memory calculation
===> EXPORTING
Adding layer 'paketo-buildpacks/ca-certificates:helper'
Adding layer 'paketo-buildpacks/bellsoft-liberica:helper'
Adding 1/1 app layer(s)
Adding layer 'launcher'
Adding layer 'config'
Adding label 'io.buildpacks.lifecycle.metadata'
Adding label 'io.buildpacks.project.metadata'
Setting default process type 'web'
Saving registry.internal.example.com/billing/orders-api:2.4.1...
*** Images (sha256:3b7f0d91ac):
      registry.internal.example.com/billing/orders-api:2.4.1
Successfully built image registry.internal.example.com/billing/orders-api:2.4.1

$ pack rebase registry.internal.example.com/billing/orders-api:2.4.1 --publish
Rebasing registry.internal.example.com/billing/orders-api:2.4.1 on run image paketobuildpacks/run-jammy-base
Saving registry.internal.example.com/billing/orders-api:2.4.1...
*** Images (sha256:91c4e7fa02):
      registry.internal.example.com/billing/orders-api:2.4.1
Rebased Image: sha256:91c4e7fa02...
```

`pack rebase` completed in about two seconds and did not re-run the build: it swapped the OS layers beneath the unchanged application layers. Patching a base-image CVE across 400 services becomes a loop over 400 rebases rather than 400 CI pipelines — the strongest single argument for buildpacks at platform scale.

---

## 10. OpenStack: the reference open-source IaaS

OpenStack matters for this objective because it is the canonical decomposition of "a cloud" into named services with documented APIs. Learn the component map and you can reason about any cloud, because every provider has the same pieces under different brand names.

| Project | Role | Analogous AWS service | Key concept to know |
|---|---|---|---|
| **Keystone** | Identity, authN/authZ, service catalog | IAM + STS | Every other service looks up endpoints here; issues scoped tokens |
| **Nova** | Compute — VM lifecycle | EC2 | Scheduler places instances onto compute nodes by flavor + filters |
| **Neutron** | Networking — SDN, L2/L3, security groups, FIPs | VPC | Pluggable ML2 drivers (OVS, OVN, Linux bridge) |
| **Glance** | Image registry | AMI catalog | Images are the immutable input to Nova |
| **Cinder** | Block storage | EBS | Volumes attach to one instance; snapshots |
| **Swift** | Object storage | S3 | Eventually consistent, ring-based, own API (+ S3 middleware) |
| **Placement** | Resource inventory and allocation | — | Nova asks it which host has free VCPU/MEMORY_MB/DISK_GB |
| **Heat** | Orchestration — declarative stacks | CloudFormation | HOT templates; the IaC entry point |
| **Horizon** | Web dashboard | Console | Thin client over the same APIs |
| **Ironic** | Bare-metal provisioning | Bare Metal instances | Nova can schedule onto physical hosts |
| **Octavia** | Load balancing as a service | ELB/NLB | Amphora VMs running HAProxy |
| **Designate** | DNS as a service | Route 53 | Records created alongside instances |
| **Barbican** | Key and secret management | KMS / Secrets Manager | Backs Cinder/Octavia encryption |
| **Magnum** | Container orchestration engine provisioning | EKS | Creates Kubernetes clusters on Nova/Heat |
| **Manila** | Shared filesystems | EFS | NFS/CIFS shares |
| **Ceilometer / Gnocchi / Aodh** | Telemetry, metric storage, alarms | CloudWatch | Feeds autoscaling |

### 10.1 A complete Heat Orchestration Template

```yaml
heat_template_version: 2021-04-16

description: >
  Two-tier reference stack for the orders platform: a private tenant network
  routed to the external provider network, a security group per tier, an
  autoscaled application tier behind an Octavia load balancer, and a Cinder
  volume for the application's local cache.

parameters:
  image:
    type: string
    label: Glance image
    default: ubuntu-24.04-server-cloudimg-amd64
    constraints:
      - custom_constraint: glance.image
  flavor:
    type: string
    label: Nova flavor
    default: m1.large
    constraints:
      - custom_constraint: nova.flavor
  key_name:
    type: string
    label: SSH keypair name
    default: platform-ops
  external_network:
    type: string
    label: Provider network for floating IPs
    default: public
  app_image_ref:
    type: string
    label: OCI image reference deployed on each instance
    default: "registry.example.com/billing/orders-api:2.4.1"
  min_instances:
    type: number
    default: 2
  max_instances:
    type: number
    default: 8

resources:

  app_network:
    type: OS::Neutron::Net
    properties:
      name: orders-app-net

  app_subnet:
    type: OS::Neutron::Subnet
    properties:
      name: orders-app-subnet
      network:
        get_resource: app_network
      cidr: 10.30.10.0/24
      gateway_ip: 10.30.10.1
      enable_dhcp: true
      dns_nameservers:
        - 10.30.0.10
        - 10.30.0.11
      allocation_pools:
        - start: 10.30.10.50
          end: 10.30.10.250

  app_router:
    type: OS::Neutron::Router
    properties:
      name: orders-app-router
      external_gateway_info:
        network:
          get_param: external_network

  app_router_interface:
    type: OS::Neutron::RouterInterface
    properties:
      router:
        get_resource: app_router
      subnet:
        get_resource: app_subnet

  app_security_group:
    type: OS::Neutron::SecurityGroup
    properties:
      name: orders-app-sg
      description: Application tier - HTTP from the load balancer, SSH from bastion
      rules:
        - protocol: tcp
          port_range_min: 8080
          port_range_max: 8080
          remote_ip_prefix: 10.30.10.0/24
        - protocol: tcp
          port_range_min: 22
          port_range_max: 22
          remote_ip_prefix: 10.30.0.0/24
        - protocol: icmp
          remote_ip_prefix: 10.30.0.0/16

  app_cache_volume:
    type: OS::Cinder::Volume
    properties:
      name: orders-app-cache
      size: 50
      volume_type: ssd

  app_server:
    type: OS::Nova::Server
    properties:
      name: orders-app-01
      image:
        get_param: image
      flavor:
        get_param: flavor
      key_name:
        get_param: key_name
      security_groups:
        - get_resource: app_security_group
      networks:
        - subnet:
            get_resource: app_subnet
      metadata:
        stack_id:
          get_param: "OS::stack_id"
        tier: application
      user_data_format: RAW
      user_data:
        str_replace:
          template: |
            #!/bin/bash
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y podman
            mkdir -p /var/cache/orders
            systemctl enable --now podman.socket
            podman run -d --name orders-api --restart=always \
              --publish 8080:8080 \
              --volume /var/cache/orders:/cache:Z \
              --env SPRING_PROFILES_ACTIVE=production \
              $APP_IMAGE
          params:
            $APP_IMAGE:
              get_param: app_image_ref

  app_volume_attachment:
    type: OS::Cinder::VolumeAttachment
    properties:
      volume_id:
        get_resource: app_cache_volume
      instance_uuid:
        get_resource: app_server
      mountpoint: /dev/vdb

  app_floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network:
        get_param: external_network

  app_floating_ip_association:
    type: OS::Nova::FloatingIPAssociation
    properties:
      floating_ip:
        get_resource: app_floating_ip
      server_id:
        get_resource: app_server

  app_loadbalancer:
    type: OS::Octavia::LoadBalancer
    properties:
      name: orders-lb
      vip_subnet:
        get_resource: app_subnet

  app_listener:
    type: OS::Octavia::Listener
    properties:
      name: orders-lb-http
      loadbalancer:
        get_resource: app_loadbalancer
      protocol: HTTP
      protocol_port: 80

  app_pool:
    type: OS::Octavia::Pool
    properties:
      name: orders-lb-pool
      listener:
        get_resource: app_listener
      protocol: HTTP
      lb_algorithm: LEAST_CONNECTIONS
      session_persistence:
        type: APP_COOKIE
        cookie_name: ORDERSSESSION

  app_health_monitor:
    type: OS::Octavia::HealthMonitor
    properties:
      pool:
        get_resource: app_pool
      type: HTTP
      url_path: /healthz
      expected_codes: "200"
      delay: 5
      timeout: 3
      max_retries: 3

outputs:
  load_balancer_vip:
    description: VIP address of the Octavia load balancer
    value:
      get_attr:
        - app_loadbalancer
        - vip_address
  app_public_ip:
    description: Floating IP attached to the first application instance
    value:
      get_attr:
        - app_floating_ip
        - floating_ip_address
  app_private_ip:
    description: Fixed IP of the first application instance
    value:
      get_attr:
        - app_server
        - first_address
```

Deploy and inspect:

```
$ openstack stack create -t orders-stack.yaml \
    --parameter flavor=m1.xlarge \
    --parameter app_image_ref=registry.example.com/billing/orders-api:2.4.1 \
    --wait orders-production
2026-09-18 10:04:11Z [orders-production]: CREATE_IN_PROGRESS  Stack CREATE started
2026-09-18 10:04:13Z [orders-production.app_network]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:16Z [orders-production.app_network]: CREATE_COMPLETE  state changed
2026-09-18 10:04:17Z [orders-production.app_subnet]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:21Z [orders-production.app_subnet]: CREATE_COMPLETE  state changed
2026-09-18 10:04:22Z [orders-production.app_router]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:04:39Z [orders-production.app_router]: CREATE_COMPLETE  state changed
2026-09-18 10:05:02Z [orders-production.app_server]: CREATE_IN_PROGRESS  state changed
2026-09-18 10:06:48Z [orders-production.app_server]: CREATE_COMPLETE  state changed
2026-09-18 10:08:31Z [orders-production.app_loadbalancer]: CREATE_COMPLETE  state changed
2026-09-18 10:08:55Z [orders-production]: CREATE_COMPLETE  Stack CREATE completed successfully

+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| id                  | 4d81b2f0-5a1e-49c7-9f2b-7a3e1c084b62 |
| stack_name          | orders-production                    |
| stack_status        | CREATE_COMPLETE                      |
| creation_time       | 2026-09-18T10:04:11Z                 |
+---------------------+--------------------------------------+

$ openstack stack output show orders-production --all
+---------------------+------------------------------------------------------------+
| Field               | Value                                                      |
+---------------------+------------------------------------------------------------+
| load_balancer_vip   | 10.30.10.72                                                |
| app_public_ip       | 203.0.113.184                                              |
| app_private_ip      | 10.30.10.113                                               |
+---------------------+------------------------------------------------------------+

$ openstack service list
+----------------------------------+------------+----------------+
| ID                               | Name       | Type           |
+----------------------------------+------------+----------------+
| 0a1f3c5e7b9d2f4a6c8e0b2d4f6a8c0e | keystone   | identity       |
| 1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e | nova       | compute        |
| 2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f | neutron    | network        |
| 3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f80 | glance     | image          |
| 4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091 | cinderv3   | block-storage  |
| 5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2 | swift      | object-store   |
| 6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3 | heat       | orchestration  |
| 7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4 | placement  | placement      |
| 8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5 | octavia    | load-balancer  |
| 9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6 | barbican   | key-manager    |
+----------------------------------+------------+----------------+

$ openstack server show orders-app-01 -f value -c status -c OS-EXT-SRV-ATTR:host -c addresses
ACTIVE
compute-node-07.dc1.example.com
orders-app-net=10.30.10.113, 203.0.113.184
```

### 10.2 Diagnosing a stuck OpenStack instance

```
$ openstack server list --status ERROR
+--------------------------------------+---------------+--------+----------+
| ID                                   | Name          | Status | Networks |
+--------------------------------------+---------------+--------+----------+
| 9f2a1c84-73b1-4e20-9d5c-08a2f61b4e37 | orders-app-04 | ERROR  |          |
+--------------------------------------+---------------+--------+----------+

$ openstack server show orders-app-04 -f value -c fault
{'code': 500, 'created': '2026-09-18T10:22:04Z', 'message': 'No valid host was found. There are not enough hosts available.', 'details': 'Traceback (most recent call last):\n  File "/usr/lib/python3/dist-packages/nova/conductor/manager.py", line 1548, in schedule_and_build_instances\n    host_lists = self._schedule_instances(context, request_specs[0], ...'}

$ openstack hypervisor list --long
+----+----------------------------------+-----------------+---------------+-------+------------+---------+
| ID | Hypervisor Hostname              | Hypervisor Type | Host IP       | State | vCPUs Used | vCPUs   |
+----+----------------------------------+-----------------+---------------+-------+------------+---------+
|  1 | compute-node-07.dc1.example.com  | QEMU            | 10.30.0.107   | up    |         62 |      64 |
|  2 | compute-node-08.dc1.example.com  | QEMU            | 10.30.0.108   | up    |         64 |      64 |
|  3 | compute-node-09.dc1.example.com  | QEMU            | 10.30.0.109   | down  |          0 |      64 |
+----+----------------------------------+-----------------+---------------+-------+------------+---------+

$ openstack quota show --detail $(openstack project show platform -f value -c id) | grep -E 'cores|ram|instances'
| cores     | {'in_use': 126, 'limit': 128, 'reserved': 0} |
| instances | {'in_use': 31, 'limit': 64, 'reserved': 0}   |
| ram       | {'in_use': 507904, 'limit': 524288, 'reserved': 0} |
```

**"No valid host was found" has exactly three causes**, and the three commands above distinguish them: (1) genuine capacity exhaustion — visible in `hypervisor list`; (2) project quota exhaustion — visible in `quota show`, and here `cores` is at 126/128, which is the real cause; (3) a scheduler filter no host satisfies (aggregate, availability zone, PCI passthrough, NUMA topology) — visible only in `nova-scheduler` logs. Check quota before capacity: it is the more common answer and the cheaper query.

---

## 11. Managed equivalents as code (Terraform)

The same component set, procured rather than operated. This is the artefact that makes the build-versus-buy decision reviewable.

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

resource "aws_db_instance" "orders" {
  identifier     = "orders-production"
  engine         = "postgres"
  engine_version = "17.2"
  instance_class = "db.r7g.2xlarge"

  allocated_storage     = 200
  max_allocated_storage = 1000
  storage_type          = "gp3"
  iops                  = 12000
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.data.arn

  multi_az                     = true
  backup_retention_period      = 35
  backup_window                = "02:30-03:30"
  maintenance_window           = "sun:04:00-sun:05:00"
  performance_insights_enabled = true
  monitoring_interval          = 30
  deletion_protection          = true
  auto_minor_version_upgrade   = true

  db_subnet_group_name   = aws_db_subnet_group.data.name
  vpc_security_group_ids = [aws_security_group.orders_db.id]

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    Service     = "orders"
    Tier        = "data"
    Environment = "production"
  }
}

resource "aws_elasticache_replication_group" "orders_cache" {
  replication_group_id = "orders-cache"
  description          = "Session and read-through cache for the orders service"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.r7g.large"

  num_node_groups         = 2
  replicas_per_node_group = 1

  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  parameter_group_name = aws_elasticache_parameter_group.lru.name
  subnet_group_name    = aws_elasticache_subnet_group.data.name
  security_group_ids   = [aws_security_group.orders_cache.id]

  snapshot_retention_limit = 0
}

resource "aws_elasticache_parameter_group" "lru" {
  name   = "orders-cache-lru"
  family = "valkey8"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_msk_cluster" "events" {
  cluster_name           = "platform-events"
  kafka_version          = "3.9.0"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.m7g.large"
    client_subnets  = aws_subnet.data[*].id
    security_groups = [aws_security_group.kafka.id]

    storage_info {
      ebs_storage_info {
        volume_size = 1000
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
    encryption_at_rest_kms_key_arn = aws_kms_key.data.arn
  }

  configuration_info {
    arn      = aws_msk_configuration.events.arn
    revision = aws_msk_configuration.events.latest_revision
  }
}

resource "aws_msk_configuration" "events" {
  name           = "platform-events-config"
  kafka_versions = ["3.9.0"]

  server_properties = <<-PROPERTIES
    auto.create.topics.enable=false
    default.replication.factor=3
    min.insync.replicas=2
    unclean.leader.election.enable=false
    log.retention.hours=168
  PROPERTIES
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "platform-artifacts-eu-central-1"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Two settings deserve naming because they are the difference between an HA design and an HA-shaped one: `unclean.leader.election.enable=false` (Kafka will refuse to elect an out-of-sync replica as leader, choosing unavailability over silent data loss) and `deletion_protection = true` on the database (a `terraform destroy` against the wrong workspace is a routine human error). `snapshot_retention_limit = 0` on the cache is deliberate the other way: a cache is not a system of record, and paying to back it up is paying to restore stale data.

---

## 12. Verification and failure diagnosis

### 12.1 The generic method

When a component-backed service degrades, work **outside in** along the request path and ask one question at each hop: *is this hop adding latency, adding errors, or queueing?*

```
client → DNS → CDN/edge → LB → ingress → app pod → pool → { DB | cache | broker } → downstream
```

The three symptom families and their signature:

| Symptom | Signature | Most likely component | First command |
|---|---|---|---|
| Latency up, error rate flat | p99 climbs before p50 | Queueing: pool exhaustion, GC, disk | `pg_stat_activity` / `redis-cli --latency` |
| Error rate up, latency down | Fast failures | Circuit breaker, connection refused, auth | `kubectl logs`, `ss -s` |
| Latency up **and** errors up | Saturation | CPU/memory/IOPS limit reached | `kubectl top`, `iostat -x 1` |
| Throughput flat under more load | Hard ceiling | Connection limit, single partition, single thread | `kafka-consumer-groups.sh`, `SHOW max_connections` |
| Everything fine, data wrong | No signal at all | Delivery semantics, replication lag, cache staleness | Compare source and sink counts |

### 12.2 A concrete triage runbook

**Symptom: the orders API is returning HTTP 503 at 12 % of requests.**

```
$ kubectl get pods -n orders -l app=orders-api
NAME                          READY   STATUS      RESTARTS      AGE
orders-api-6f9d4c7b8d-2k4xq   1/1     Running     0             3h
orders-api-6f9d4c7b8d-7vnzl   0/1     CrashLoopBackOff  6 (42s ago)   3h
orders-api-6f9d4c7b8d-9wqrt   1/1     Running     0             3h
orders-api-6f9d4c7b8d-pm8zc   1/1     Running     2 (11m ago)   3h

$ kubectl logs -n orders orders-api-6f9d4c7b8d-7vnzl --previous --tail=20
2026-09-18T11:02:14.882Z ERROR [HikariPool-1] Connection is not available, request timed out after 30001ms
2026-09-18T11:02:14.884Z ERROR o.s.b.w.s.ErrorPageFilter  org.springframework.jdbc.CannotGetJdbcConnectionException
2026-09-18T11:02:44.901Z ERROR [HikariPool-1] Connection is not available, request timed out after 30002ms

$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT state, wait_event_type, count(*)
    FROM pg_stat_activity
    WHERE datname = 'orders'
    GROUP BY 1, 2 ORDER BY 3 DESC;"
      state       | wait_event_type | count
------------------+-----------------+-------
 idle in transaction | Client        |   147
 active           | Lock            |    31
 idle             | Client          |    14
 active           |                 |     6
(4 rows)

$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT pid, now() - xact_start AS xact_age, left(query, 60) AS query
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
    ORDER BY xact_start LIMIT 5;"
  pid  |    xact_age     |                    query
-------+-----------------+----------------------------------------------
 28471 | 00:41:12.882713 | SELECT * FROM orders WHERE customer_id = $1
 28492 | 00:40:57.114029 | SELECT * FROM orders WHERE customer_id = $1
 28503 | 00:40:44.900112 | UPDATE inventory SET reserved = reserved + $1
```

**Diagnosis.** 147 sessions are `idle in transaction` with transaction ages over forty minutes. The application opened transactions and never committed or rolled back — almost always an exception path that skips the `close()`, or a transaction that spans an outbound HTTP call. Those sessions hold locks (the 31 `Lock` waiters), and they consume `max_connections`, so the pool cannot hand out connections and the readiness probe fails, taking pods out of the endpoint list → 503.

**Immediate mitigation, then the real fix:**

```
$ kubectl exec -n data orders-db-1 -- psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'orders'
      AND state = 'idle in transaction'
      AND now() - xact_start > interval '5 minutes';"
 pg_terminate_backend
----------------------
 t
 t
... (147 rows)
```

The durable fixes, in order of value: set `idle_in_transaction_session_timeout = '60s'` on the database so this can never again exhaust connections; put PgBouncer in transaction-pooling mode between the app and the database so 1 500 app-side connections map to 40 server-side ones; and remove the network call from inside the transaction in the application.

### 12.3 Per-component verification checklist

| Component | Liveness | Correctness | Saturation | Command |
|---|---|---|---|---|
| Relational DB | Accepts connections | Replica LSN == primary LSN | `pg_stat_activity` count vs `max_connections`; `pg_stat_bgwriter` checkpoints | `kubectl cnpg status`, `pg_isready` |
| Cache | `PING` → `PONG` | Hit ratio stable | `evicted_keys` rate; `used_memory` vs `maxmemory` | `redis-cli info`, `--bigkeys` |
| Kafka | Broker in ISR for all partitions | `Isr` size == `Replicas` size | Consumer lag rate of change, disk % | `kafka-topics.sh --describe --under-replicated-partitions` |
| RabbitMQ | All nodes in `cluster_status` | DLQ depth == 0 | `messages_ready` trend, memory alarm | `rabbitmqctl list_queues`, `status` |
| Object storage | `HEAD` bucket | Checksum on restore | Request rate vs prefix limits | `aws s3api head-bucket` |
| Knative/FaaS | Revision `Ready` | Traffic split matches intent | `queue-proxy` queueing time, throttling | `kn revision list` |
| CDN | 200 on a known asset | `x-cache: HIT` ratio | Origin request rate | `curl -I`, provider analytics |
| OpenStack | `openstack service list` all present | Stack `CREATE_COMPLETE` | Quota vs in-use, hypervisor vCPUs | `openstack quota show --detail` |

### 12.4 Alert rules that encode the above

```yaml
groups:
  - name: platform-standard-components
    interval: 30s
    rules:
      - alert: KafkaUnderReplicatedPartitions
        expr: |
          sum by (cluster) (kafka_server_replicamanager_underreplicatedpartitions) > 0
        for: 5m
        labels:
          severity: critical
          component: kafka
        annotations:
          summary: "Under-replicated partitions on {{ $labels.cluster }}"
          description: "min.insync.replicas is at risk; one more broker loss stops writes."
          runbook_url: "https://runbooks.example.com/kafka/under-replicated"

      - alert: KafkaConsumerLagGrowing
        expr: |
          sum by (consumergroup, topic) (kafka_consumergroup_lag) > 100000
          and
          deriv(sum by (consumergroup, topic) (kafka_consumergroup_lag)[15m:1m]) > 0
        for: 15m
        labels:
          severity: warning
          component: kafka
        annotations:
          summary: "Lag above 100k and still growing for {{ $labels.consumergroup }}"

      - alert: PostgresReplicationLagHigh
        expr: |
          max by (cluster) (cnpg_pg_replication_lag) > 30
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Replica more than 30s behind on {{ $labels.cluster }}"

      - alert: PostgresConnectionsNearLimit
        expr: |
          sum by (cluster) (cnpg_backends_total)
          /
          max by (cluster) (cnpg_pg_settings_setting{name="max_connections"})
          > 0.85
        for: 10m
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "Connection usage above 85% of max_connections"

      - alert: RedisCacheHitRatioDegraded
        expr: |
          sum(rate(redis_keyspace_hits_total[10m]))
          /
          (sum(rate(redis_keyspace_hits_total[10m])) + sum(rate(redis_keyspace_misses_total[10m])))
          < 0.80
        for: 20m
        labels:
          severity: warning
          component: redis
        annotations:
          summary: "Cache hit ratio below 80% - working set may exceed maxmemory"

      - alert: RabbitDeadLetterQueueNotEmpty
        expr: |
          rabbitmq_queue_messages{queue=~".*\\.dead"} > 0
        for: 5m
        labels:
          severity: warning
          component: rabbitmq
        annotations:
          summary: "Messages in {{ $labels.queue }} - poison messages are being discarded"

      - alert: ObjectStorageBackupStale
        expr: |
          time() - cnpg_collector_last_available_backup_timestamp > 90000
        for: 30m
        labels:
          severity: critical
          component: backup
        annotations:
          summary: "No successful backup in over 25 hours"
```

Every `expr` above is a block scalar whose lines carry identical indentation, including the standalone `/` and `and` operators — a single dedented line silently terminates the scalar and Prometheus refuses to load the whole rule file.

---

## 13. Decision summary

| If the requirement is… | Choose | Because |
|---|---|---|
| Invariants across entities, money | Relational (PostgreSQL) | ACID across rows is not emulable cheaply |
| Latest value per key, replayable | Kafka compacted topic | Log is the state, replay is free |
| Work distribution with routing and priorities | RabbitMQ quorum queues | Smart broker, per-message ack, DLX |
| Event streaming with many independent readers | Kafka | Retention decoupled from consumption |
| Sub-millisecond, no durability needed | Redis / NATS | In-memory, single-hop |
| Very high write volume, time-ordered | Cassandra / ClickHouse | Write-optimised storage engine |
| Full-text search | OpenSearch, **with a system of record behind it** | Index is a derived, rebuildable projection |
| Spiky, short, stateless work | FaaS / Knative | Scale to zero, per-ms billing |
| 24/7 steady service | Container on reserved capacity | Fixed cost beats per-request at high duty cycle |
| Immutable, read-many artefacts | Object storage + CDN | Cheapest per GiB, unbounded, cacheable |
| Developer self-service without Kubernetes literacy | PaaS (Cloud Foundry / OpenShift) | Buildpacks and service brokers remove the platform surface |
| An on-premises cloud with an API | OpenStack | The reference decomposition, all pieces addressable |

**And the four questions to ask of every component before it enters a design:**

1. **What does it guarantee?** Consistency model, delivery semantics, durability on `fsync` or not.
2. **Who operates it?** Draw the responsibility line explicitly, including backups, patching and restore drills.
3. **How does it scale, and what is the hard ceiling?** Partitions, connections, memory, IOPS — every component has one.
4. **What does the rest of the platform do when it fails?** If the answer is "everything stops", you have not designed a dependency; you have designed a single point of failure with extra steps.

---

## Referencias

**Exam objectives**
- LPI DevOps Tools Engineer, exam 701 objectives — https://www.lpi.org/our-certifications/exam-701-objectives/

**Cloud platforms and service models**
- OpenStack documentation (component index) — https://docs.openstack.org/
- OpenStack Heat Orchestration Template specification — https://docs.openstack.org/heat/latest/template_guide/hot_spec.html
- OpenStack Nova (compute) — https://docs.openstack.org/nova/latest/
- OpenStack Neutron (networking) — https://docs.openstack.org/neutron/latest/
- OpenStack Cinder (block storage) — https://docs.openstack.org/cinder/latest/
- OpenStack Swift (object storage) — https://docs.openstack.org/swift/latest/
- OpenStack Keystone (identity) — https://docs.openstack.org/keystone/latest/
- OpenStack Octavia (load balancing) — https://docs.openstack.org/octavia/latest/
- NIST SP 800-145, The NIST Definition of Cloud Computing — https://csrc.nist.gov/publications/detail/sp/800-145/final

**Compute and containers**
- Kubernetes documentation — https://kubernetes.io/docs/home/
- Kubernetes Storage Classes — https://kubernetes.io/docs/concepts/storage/storage-classes/
- Knative Serving — https://knative.dev/docs/serving/
- Knative autoscaling reference — https://knative.dev/docs/serving/autoscaling/
- Firecracker microVM — https://firecracker-microvm.github.io/
- gVisor — https://gvisor.dev/docs/
- Open Container Initiative specifications — https://opencontainers.org/

**PaaS and build systems**
- Cloud Foundry documentation — https://docs.cloudfoundry.org/
- Cloud Foundry application manifest reference — https://docs.cloudfoundry.org/devguide/deploy-apps/manifest-attributes.html
- Open Service Broker API — https://www.openservicebrokerapi.org/
- Cloud Native Buildpacks — https://buildpacks.io/docs/
- Paketo Buildpacks — https://paketo.io/docs/
- Red Hat OpenShift documentation — https://docs.openshift.com/
- The Twelve-Factor App — https://12factor.net/

**Databases**
- PostgreSQL documentation — https://www.postgresql.org/docs/current/
- PostgreSQL high availability and replication — https://www.postgresql.org/docs/current/high-availability.html
- MySQL reference manual — https://dev.mysql.com/doc/refman/8.4/en/
- MariaDB knowledge base — https://mariadb.com/kb/en/documentation/
- MongoDB manual — https://www.mongodb.com/docs/manual/
- Apache Cassandra documentation — https://cassandra.apache.org/doc/latest/
- CloudNativePG documentation — https://cloudnative-pg.io/documentation/current/
- Amazon RDS user guide — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html

**Caching**
- Redis documentation — https://redis.io/docs/latest/
- Redis eviction policies — https://redis.io/docs/latest/develop/reference/eviction/
- Valkey documentation — https://valkey.io/docs/
- Memcached wiki — https://github.com/memcached/memcached/wiki

**Messaging**
- Apache Kafka documentation — https://kafka.apache.org/documentation/
- Kafka design and delivery semantics — https://kafka.apache.org/documentation/#semantics
- Strimzi documentation — https://strimzi.io/docs/operators/latest/overview
- RabbitMQ documentation — https://www.rabbitmq.com/docs
- RabbitMQ quorum queues — https://www.rabbitmq.com/docs/quorum-queues
- AMQP 0-9-1 protocol specification — https://www.rabbitmq.com/tutorials/amqp-concepts
- OASIS AMQP 1.0 specification — https://www.amqp.org/resources/specifications
- Apache ActiveMQ Artemis — https://activemq.apache.org/components/artemis/documentation/
- NATS documentation — https://docs.nats.io/
- ZeroMQ guide — https://zguide.zeromq.org/
- Amazon SQS developer guide — https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html

**Big data and analytics**
- Apache Hadoop documentation — https://hadoop.apache.org/docs/stable/
- Apache Spark documentation — https://spark.apache.org/docs/latest/
- Running Spark on Kubernetes — https://spark.apache.org/docs/latest/running-on-kubernetes.html
- Apache Flink documentation — https://nightlies.apache.org/flink/flink-docs-stable/
- OpenSearch documentation — https://opensearch.org/docs/latest/
- Elasticsearch reference — https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html
- ClickHouse documentation — https://clickhouse.com/docs
- Trino documentation — https://trino.io/docs/current/

**Storage, delivery and observability**
- Amazon S3 user guide — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- Amazon S3 consistency model — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel
- MinIO documentation — https://min.io/docs/minio/linux/index.html
- Ceph documentation — https://docs.ceph.com/en/latest/
- Kubernetes CSI developer documentation — https://kubernetes-csi.github.io/docs/
- RFC 9111, HTTP Caching — https://www.rfc-editor.org/rfc/rfc9111.html
- Prometheus documentation — https://prometheus.io/docs/introduction/overview/
- Prometheus alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/

**Infrastructure as code**
- Terraform documentation — https://developer.hashicorp.com/terraform/docs
- Terraform AWS provider — https://registry.terraform.io/providers/hashicorp/aws/latest/docs