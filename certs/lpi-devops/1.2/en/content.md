# Study Guide: LPI DevOps Tools Engineer (Exam 701-100) — Topic 1.2: Standard Components and Platforms for Software

---

## 1. Architectural Motivation and Production Problem

### Production Scenario & Architectural Failure Modes
In traditional monolithic infrastructure, software applications rely heavily on localized POSIX filesystem storage (e.g., local block devices, mounted NFS exports) and tightly coupled co-located database instances. In modern distributed cloud platforms, this legacy topology introduces severe operational failure modes:

1. **Stateful Compute Scaling Bottlenecks**: When compute instances hold persistent state on local disks (`/var/data` or ephemeral instance storage), scaling horizontally via automated mechanisms (such as AWS Auto Scaling Groups or OpenStack Heat) becomes impossible without costly synchronization phases or data corruption.
2. **POSIX Lock Contention & I/O Operations Limits**: Traditional shared filesystems (NFSv3/v4) suffer from locking overhead and network latency when hundreds of microservice instances attempt concurrent write operations against centralized file nodes.
3. **Coupled Failures in Database Co-location**: Running database daemons directly on application host nodes creates resource contention (CPU/Memory starvation) and prevents independent failure domain isolation, leading to cascaded outages during high-load traffic spikes.

### Platform Services Architecture & OpenStack Reference Implementation
Modern cloud platforms decouple execution logic from persistence mechanisms by providing standard infrastructure services:

```
+-----------------------------------------------------------------------------------+
|                                 APPLICATION LAYER                                 |
|               (Stateless Microservices / Ephemeral Worker Nodes)                  |
+-----------------------------------------------------------------------------------+
          |                                  |                                  |
          | REST / S3 API                    | SQL / Protocol                   | Redis Protocol
          v                                  v                                  v
+-----------------------+  +---------------------------------+  +-----------------------+
|    OBJECT STORAGE     |  |       RELATIONAL DB (DBaaS)     |  |   NOSQL / IN-MEMORY   |
| (OpenStack Swift /    |  |  (OpenStack Trove / Patroni HA  |  |  (Redis Cluster /     |
|    Ceph RGW / S3)     |  |       PostgreSQL / MySQL)       |  |      Cassandra)       |
+-----------------------+  +---------------------------------+  +-----------------------+
          |                                  |                                  |
          +----------------------------------+----------------------------------+
                                             | Managed via Identity Engine
                                             v
                                 +-----------------------+
                                 |  IDENTITY & AUTH      |
                                 |  (OpenStack Keystone) |
                                 +-----------------------+
```

1. **Object Storage (OpenStack Swift / AWS S3 / Ceph RGW)**: Offers RESTful HTTP-based interfaces (`GET`, `PUT`, `DELETE`), consistent hashing rings, WORM (Write Once, Read Many) durability, metadata tagging, and arbitrary scaling without POSIX filesystem constraints.
2. **Block Storage (OpenStack Cinder / AWS EBS)**: Delivers raw, persistent block volumes attached over storage networks (iSCSI, Fibre Channel, Ceph RBD) directly to compute nodes for high-IOPS transactional workloads.
3. **Database as a Service (DBaaS) (OpenStack Trove / Managed RDS)**: Provides automated provisioning, automated point-in-time recovery (PITR), read-replica management, and failover orchestration for Relational (RDBMS) and NoSQL stores.
4. **Identity & Catalog Service (OpenStack Keystone)**: Serves as the central API gateway for authentication, RBAC, service token validation, and dynamic endpoint resolution across cloud components.

---

## 2. Technical Comparisons and Trade-off Tables

### Storage Paradigms: Object Storage vs Block Storage vs Shared File Systems

| Metric / Feature | Object Storage (OpenStack Swift / AWS S3) | Block Storage (OpenStack Cinder / EBS) | Shared File System (OpenStack Manila / NFS) |
| :--- | :--- | :--- | :--- |
| **Primary Interface** | HTTP REST APIs (Swift API, S3 API) | Raw Block Device (`/dev/vdb`, iSCSI, RBD) | POSIX Network Protocol (NFSv4, SMB) |
| **Consistency Model** | Eventual Consistency / Strong Read-After-Write | Strict Immediate Consistency (Sector Level) | Immediate Strong Consistency (POSIX Locking) |
| **Scalability Limit** | Exabyte-scale; flat namespace via ring hashing | Fixed per-volume size; requires filesystem expansion | Multi-Terabyte; constrained by head-node locks |
| **Latency & Throughput** | High TTFB latency (50–200ms), massive throughput | Sub-millisecond IOPS latency (<1–5ms) | Low-to-medium latency (5–20ms network delay) |
| **Client Access Pattern** | Concurrent multi-client read/write over HTTP | Single-instance attach (RWO) or Cluster FS (RWX) | Concurrent multi-node shared read/write (RWX) |
| **Metadata Metadata Storage** | User-defined Key-Value HTTP headers | Standard partition table / local FS metadata | Inode structures, directory tree hierarchy locks |

### Database Architectures: Relational vs In-Memory Key-Value vs Document vs Wide-Column

| Engine Type | Reference Implementations | Consistency Model | Horizontal Scaling Mechanism | Ideal Production Use Case | Architectural Trade-offs |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Relational (RDBMS)** | PostgreSQL, MySQL, OpenStack Trove | Strict ACID (Atomicity, Consistency, Isolation, Durability) | Streaming Replication (WAL), Read Replicas, Sharding (Citus) | Financial transactions, relational domain models | Vertical scaling ceiling; complex schema migrations at scale |
| **In-Memory Key-Value** | Redis Cluster, KeyDB, Memcached | Single-node ACID; Eventual cluster consistency | Hash Slot partitioning (16,384 slots allocated across nodes) | Real-time session caching, rate limiting, pub/sub messaging | RAM-bounded storage costs; data persistence delays under high write throughput |
| **Document NoSQL** | MongoDB, Couchbase | Configurable (Tunable Read/Write Concern) | Distributed Sharding via Router Query Controllers | Dynamic schemas, JSON catalogs, content management | Storage overhead from field replication; heavy RAM consumption for indexes |
| **Wide-Column NoSQL** | Apache Cassandra, ScyllaDB | Tunable Consistency ($R + W > N$) | Masterless P2P ring topology with Consistent Hashing (Vnodes) | High-throughput time-series metrics, IoT telemetry ingestion | No SQL `JOIN` support; data access patterns must be predetermined at table design |

---

## 3. Production-Grade Complete Infrastructure Manifests

### 3.1 OpenStack Swift Object Storage Container Provisioning via Terraform (`main.tf`)
This HCL code provisions an OpenStack Swift object storage container featuring access control lists (ACLs), user-defined metadata, and versioning.

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    openstack = {
      source  = "openstack/openstack"
      version = "~> 1.53.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5.0"
    }
  }
}

provider "openstack" {
  auth_url    = "https://openstack.internal.net:5000/v3/"
  region      = "RegionOne"
  user_name   = "sre_deployer"
  password    = "ProductionVaultSecret2026!"
  tenant_name = "production-platform"
  domain_name = "Default"
}

resource "random_string" "container_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Primary Swift Container for Production Artifacts
resource "openstack_objectstorage_container_v1" "app_artifacts_storage" {
  name = "prod-app-artifacts-${random_string.container_suffix.result}"

  metadata = {
    "Environment"  = "Production"
    "CostCenter"   = "PlatformSRE-1042"
    "StorageClass" = "Standard-Hot"
    "Auto-Archive" = "true"
  }

  # Container ACLs: Read accessible publicly; Write restricted to project deployer
  read_acl  = ".r:*,.rlistings"
  write_acl = "production-platform:sre_deployer"

  # Object Versioning Target Container
  history_container = openstack_objectstorage_container_v1.app_artifacts_versions.name

  content_type = "application/json"
}

# Dedicated Container for Storing Object Versions
resource "openstack_objectstorage_container_v1" "app_artifacts_versions" {
  name = "prod-app-artifacts-versions"

  metadata = {
    "Environment" = "Production"
    "Purpose"     = "Swift-Object-Versioning-Archive"
  }

  read_acl  = "production-platform:sre_deployer"
  write_acl = "production-platform:sre_deployer"
}
```

### 3.2 High-Availability PostgreSQL Patroni Cluster Configuration (`patroni-postgresql.yaml`)
This complete configuration file sets up Patroni to orchestrate PostgreSQL HA using `etcd3` for distributed consensus and automatic failover.

```yaml
scope: postgres-prod-cluster
namespace: /service
name: pg-node-01

etcd3:
  hosts:
    - 10.240.10.11:2379
    - 10.240.10.12:2379
    - 10.240.10.13:2379

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.240.10.21:8008

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 500
        shared_buffers: 8GB
        effective_cache_size: 24GB
        maintenance_work_mem: 2GB
        checkpoint_completion_target: 0.9
        wal_buffers: 16MB
        default_statistics_target: 100
        random_page_cost: 1.1
        effective_io_concurrency: 200
        work_mem: 16MB
        min_wal_size: 2GB
        max_wal_size: 16GB
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby: "on"
        hot_standby_feedback: "on"

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host replication replicator 10.240.10.0/24 md5
    - host all all 10.240.10.0/24 md5
    - host all all 127.0.0.1/32 md5

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.240.10.21:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/15/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    replication:
      username: replicator
      password: "StrongReplicationPassword2026!"
    superuser:
      username: postgres
      password: "SuperuserAdminPassword2026!"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

### 3.3 Kubernetes Microservice Integrating Object Storage and DBaaS (`app-production.yaml`)
This Kubernetes manifest configures an application workload referencing platform secrets to communicate with an OpenStack Swift bucket and a PostgreSQL DBaaS cluster.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloud-platform-credentials
  namespace: production
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "SWIFT_S3_KEY_PROD_1042"
  AWS_SECRET_ACCESS_KEY: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  DATABASE_URL: "postgresql://app_user:DBPasswordProd2026!@10.240.10.21:5432/app_production?sslmode=verify-full&sslrootcert=/etc/ssl/certs/db-ca.crt"
  REDIS_URL: "redis://:RedisClusterAuth2026!@10.240.20.50:6379/0"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-api-service
  namespace: production
  labels:
    app.kubernetes.io/name: platform-api
    app.kubernetes.io/tier: backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: platform-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: platform-api
    spec:
      containers:
        - name: api-engine
          image: internal-registry.net/platform/api-engine:v2.4.1
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: cloud-platform-credentials
          env:
            - name: OBJECT_STORAGE_ENDPOINT
              value: "https://swift.internal.net:8080/v1/AUTH_production-platform"
            - name: OBJECT_STORAGE_BUCKET
              value: "prod-app-artifacts-a1b2c3d4"
            - name: S3_COMPATIBLE_HOST
              value: "swift.internal.net"
          ports:
            - containerPort: 8080
              name: http-api
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2000m"
              memory: "4Gi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
```

---

## 4. Real CLI Commands and Actual Terminal Outputs ($)

### 4.1 Authenticating with OpenStack Keystone & Operating Swift CLI

```bash
$ export OS_AUTH_URL="https://openstack.internal.net:5000/v3/"
$ export OS_PROJECT_NAME="production-platform"
$ export OS_USERNAME="sre_deployer"
$ export OS_PASSWORD="ProductionVaultSecret2026!"
$ export OS_IDENTITY_API_VERSION=3
$ export OS_USER_DOMAIN_NAME="Default"

$ openstack token issue
+-----------+------------------------------------------------------------------+
| Field     | Value                                                            |
+-----------+------------------------------------------------------------------+
| expires   | 2026-08-07T12:00:00+0000                                         |
| id        | gAAAAABmpX8zN_8yK0...TRuncatedTokenString...9XzQ                 |
| project_id| 4a79df89b9104c86b2e7c3e59041b3a1                                 |
| user_id   | e90c5f21bd724e5aa9a288e404b901a2                                 |
+-----------+------------------------------------------------------------------+

$ openstack container create prod-app-artifacts-a1b2c3d4
+------------------------------+------------------------------+------------------------------------+
| account                      | container                    | x-trans-id                         |
+------------------------------+------------------------------+------------------------------------+
| AUTH_4a79df89b9104c86b2e7... | prod-app-artifacts-a1b2c3d4  | tx5b6f7e8a9d0c4b2a8e1f0-0066b2a4c1 |
+------------------------------+------------------------------+------------------------------------+

$ swift upload prod-app-artifacts-a1b2c3d4 --header "X-Object-Meta-Checksum: sha256" release-v2.4.1.tar.gz
release-v2.4.1.tar.gz

$ swift stat prod-app-artifacts-a1b2c3d4 release-v2.4.1.tar.gz
       Account: AUTH_4a79df89b9104c86b2e7c3e59041b3a1
     Container: prod-app-artifacts-a1b2c3d4
        Object: release-v2.4.1.tar.gz
  Content Type: application/x-gzip
Content Length: 52428800
 Last Modified: Fri, 07 Aug 2026 04:30:00 GMT
          ETag: 7c222fb2927d828af22f592134e89324
 Meta Checksum: sha256
 Accept-Ranges: bytes
   X-Trans-Id: txd8a1e2f3c4b5a67890-0066b2a5ef
```

### 4.2 Querying PostgreSQL Patroni Cluster State

```bash
$ patronictl -c /etc/patroni/patroni.yaml list postgres-prod-cluster
+ Cluster: postgres-prod-cluster (7259104820194830192) ---+----+-----------+
| Member     | Host         | Role    | State   | TL | Lag in MB |
+------------+--------------+---------+---------+----+-----------+
| pg-node-01 | 10.240.10.21 | Leader  | running |  4 |           |
| pg-node-02 | 10.240.10.22 | Sync    | running |  4 |         0 |
| pg-node-03 | 10.240.10.23 | Replica | running |  4 |         0 |
+------------+--------------+---------+---------+----+-----------+

$ psql "postgresql://postgres@10.240.10.21:5432/app_production" -c "SELECT client_addr, state, sync_state, sync_priority FROM pg_stat_replication;"
  client_addr  |   state   | sync_state | sync_priority 
---------------+-----------+------------+---------------
 10.240.10.22  | streaming | sync       |             1
 10.240.10.23  | streaming | potential  |             2
(2 rows)
```

### 4.3 Redis Cluster Hash Slot and Node Topology Inspection

```bash
$ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" cluster info
# Cluster
cluster_state:ok
cluster_slots_assigned:16384
cluster_slots_ok:16384
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:6
cluster_size:3
cluster_current_epoch:6
cluster_my_epoch:1
cluster_stats_messages_sent:1849204
cluster_stats_messages_received:1849190

$ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" cluster nodes
e1a2b3c4d5e6... 10.240.20.50:6379@16379 master - 0 1691382600000 1 connected 0-5460
f7g8h9i0j1k2... 10.240.20.51:6379@16379 master - 0 1691382601000 2 connected 5461-10922
l3m4n5o6p7q8... 10.240.20.52:6379@16379 master - 0 1691382600500 3 connected 10923-16383
a9b8c7d6e5f4... 10.240.20.53:6379@16379 slave e1a2b3c4d5e6... 0 1691382601200 1 connected
b1c2d3e4f5g6... 10.240.20.54:6379@16379 slave f7g8h9i0j1k2... 0 1691382600800 2 connected
c7d8e9f0g1h2... 10.240.20.55:6379@16379 slave l3m4n5o6p7q8... 0 1691382601000 3 connected
```

---

## 5. Verification, Failure Diagnostics, and Troubleshooting Guide

### 5.1 Diagnostic Decision Tree Flowchart

```
                      [ Production Incident / Service Degradation ]
                                           |
                   +-----------------------+-----------------------+
                   |                                               |
        [ Storage / Asset API Error ]                   [ Database Failure / Timeout ]
                   |                                               |
       +-----------+-----------+                       +-----------+-----------+
       |                       |                       |                       |
[HTTP 403 Forbidden]    [HTTP 503 Service      [Connection Refused     [High Replication
 / ACL Mismatch]         Unavailable]           / Pool Exhausted]       Lag / Disk Full]
       |                       |                       |                       |
 Verify Keystone Token  Inspect Swift Storage   Verify Patroni DCS      Check PG WAL Disk Usage
 & S3 Secret Access Key Ring & Account Audit   etcd Health & max_conn  & Network Bandwidth
       |                       |                       |                       |
 `openstack token       `swift-recon -g         `patronictl list`       `SELECT pg_wal_lsn_diff`
   issue`                 --all`                `pg_stat_activity`
```

### 5.2 Failure Scenarios and Resolution Runbooks

#### Failure Scenario 1: OpenStack Swift HTTP 503 Service Unavailable / Ring Desynchronization
- **Symptom**: Microservices log `HTTP 503 Service Unavailable` or `Container ring checksum mismatch` when attempting object reads or writes.
- **Root Cause**: Desynchronization between `object.ring.gz` or `container.ring.gz` files across Swift proxy and storage nodes following a failed node replacement.
- **Diagnostic Procedure**:
  ```bash
  # Check Swift ring consistency across storage nodes
  $ swift-recon -g /etc/swift/object.builder --md5

  # Inspect Swift proxy error logs for ring lookup failures
  $ grep -i "503" /var/log/swift/swift-proxy-server.log | tail -n 20
  ```
- **Remediation Plan**:
  1. Re-balance the Swift builder rings on the storage controller: `swift-ring-builder /etc/swift/object.builder rebalance`.
  2. Sync updated `.ring.gz` artifacts to all nodes across `/etc/swift/`.
  3. Reload Swift proxy processes: `systemctl reload openstack-swift-proxy.service`.

#### Failure Scenario 2: PostgreSQL Connection Exhaustion & Patroni Split-Brain Protection
- **Symptom**: Applications log `FATAL: remaining connection slots are reserved for non-replication superuser connections`, leading to HTTP 500 errors across API endpoints.
- **Root Cause**: Microservices opening unpooled direct connections to PostgreSQL, coupled with transient network partitions causing Patroni to lose quorum with `etcd`.
- **Diagnostic Procedure**:
  ```bash
  # Inspect active database backend states and running connections
  $ psql "postgresql://postgres@10.240.10.21:5432/app_production" -c "
  SELECT pid, age(clock_timestamp(), query_start), usename, query, state 
  FROM pg_stat_activity 
  WHERE state != 'idle' 
  ORDER BY age(clock_timestamp(), query_start) DESC LIMIT 10;"

  # Verify health of etcd consensus cluster
  $ etcdctl --endpoints=10.240.10.11:2379,10.240.10.12:2379,10.240.10.13:2379 endpoint health
  ```
- **Remediation Plan**:
  1. Cancel runaway queries: `SELECT pg_cancel_backend(pid);`.
  2. Deploy or re-configure connection pooling middleware (PgBouncer) between the application deployment and Patroni endpoints.

#### Failure Scenario 3: Redis Cluster Hash Slot Eviction & Out of Memory Panic
- **Symptom**: Redis writes fail with `OOM command not allowed when used memory > 'maxmemory'` or `CLUSTERDOWN The cluster is down`.
- **Root Cause**: Invalidation of Hash Slot allocations due to unhandled master node crash without replica promotion, or memory pool exhaustion.
- **Diagnostic Procedure**:
  ```bash
  # Inspect memory consumption and eviction stats
  $ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" info memory

  # Check slot state across cluster master nodes
  $ redis-cli -h 10.240.20.50 -p 6379 -a "RedisClusterAuth2026!" cluster check 10.240.20.50:6379
  ```
- **Remediation Plan**:
  1. Set active key eviction policies: `CONFIG SET maxmemory-policy allkeys-lru`.
  2. Force replica failover takeover if a master node becomes unassigned: `CLUSTER FAILOVER TAKEOVER`.

---

## 6. References

- [Linux Professional Institute (LPI) DevOps Tools Engineer Overview & Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- [OpenStack Swift Object Storage Architectural Guide](https://docs.openstack.org/swift/latest/)
- [OpenStack Trove Database-as-a-Service Documentation](https://docs.openstack.org/trove/latest/)
- [Patroni High-Availability PostgreSQL Documentation](https://patroni.readthedocs.io/en/latest/)
- [Redis Cluster Specification & Hash Slot Architecture](https://redis.io/docs/reference/cluster-spec/)
- [Kubernetes Persistent Storage & Volume Architectural Concepts](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)