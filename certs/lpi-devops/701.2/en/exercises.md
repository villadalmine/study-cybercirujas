# LPI DevOps Tools Engineer (Exam 701-100) — Topic 1.2: Standard Components and Platforms for Software

**Exam Weight:** 3.33  
**Target Certification:** LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)  
**Objective 101.2:** Standard Components and Platforms for Software  
**Official Reference:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

---

## Architectural Overview & Production Fundamentals

Modern cloud-native and DevOps architectures rely on standardized infrastructure components to handle data persistence, state caching, asynchronous messaging, and blob storage. As a DevOps Engineer or Platform Architect, mastering these building blocks requires an understanding of their internal mechanics, communication protocols, failure modes, and trade-offs.

```
                    +-------------------------------------------------+
                    |                API Gateway / Edge               |
                    +-------------------------------------------------+
                                             |
                                             v
                    +-------------------------------------------------+
                    |           Application Microservices             |
                    +-------------------------------------------------+
                      /                      |                      \
                     /                       v                       \
                    v              +-------------------+              v
  +-------------------+            |  Message Queue    |            +-------------------+
  |  In-Memory Cache  |            |    (RabbitMQ)     |            |  Object Storage   |
  |     (Redis)       |            +-------------------+            |  (MinIO / S3)     |
  +-------------------+                      |                      +-------------------+
            ^                                v                                ^
            |                      +-------------------+                      |
            +----------------------|  Worker Service   |----------------------+
                                   +-------------------+
                                             |
                                             v
                                   +-------------------+
                                   | Relational RDBMS  |
                                   |   (PostgreSQL)    |
                                   +-------------------+
```

### Key Components Architecture Matrix

| Component Type | Primary Technology | Protocol / API | Primary Use Case | State Persistence Model | Consensus / Replication |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Relational DB** | PostgreSQL | PostgreSQL Wire Protocol (TCP 5432) | Transactional data, ACID compliance | WAL (Write-Ahead Logging) + Page files | Streaming Replication (Sync/Async), Patroni (Raft/etcd) |
| **In-Memory Store** | Redis | RESP (Redis Serialization Protocol, TCP 6379) | Caching, session store, rate limiting | RDB Snapshots & AOF (Append-Only File) | Redis Sentinel (Asynchronous), Redis Cluster (Gossip) |
| **Message Broker** | RabbitMQ | AMQP 0-9-1 (TCP 5672) / MQTT | Asynchronous task distribution, decoupling | Disk-backed queues, Mnesia DB | Quorum Queues (Raft Consensus), Mirrored Queues (Classic) |
| **Object Storage** | MinIO / OpenStack Swift | S3 REST API (HTTP 9000) / Swift API | Unstructured assets, backups, artifacts | Erasure Coding & Bitrot Protection | Hash Ring (Swift), Distributed Erasure Sets (MinIO) |

---

## Hands-On Exercise Block 1: Relational & NoSQL Data Persistence Layers (PostgreSQL & Redis)

### Deep-Dive Architecture & Production Trade-offs
1. **PostgreSQL ACID & WAL Mechanics**: PostgreSQL ensures Durability via the Write-Ahead Log (WAL). Before any data modification (INSERT/UPDATE/DELETE) is written to the heap storage files, it is sequentially recorded in the WAL. Connection poolers like `PgBouncer` mitigate the process-per-connection overhead of PostgreSQL by maintaining a reusable pool of backend connections.
2. **Redis In-Memory Persistence & Eviction**: Redis processes commands in a single-threaded event loop. When memory limits (`maxmemory`) are reached, Redis enforces eviction policies such as `volatile-lru` (Least Recently Used with TTL) or `allkeys-lru`. Persistence options include **RDB** (point-in-time binary snapshots) and **AOF** (append-only logs of write operations).

---

### Step-by-Step Guided Lab Execution

#### Step 1: Provisioning the Persistence Infrastructure Manifest
Create a working directory named `lpi-block1` and create a production-grade `docker-compose.yml` manifest implementing PostgreSQL with custom WAL settings and Redis configured with an AOF persistence strategy and LRU eviction policy.

```bash
mkdir -p lpi-block1 && cd lpi-block1
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: lpi-postgres
    environment:
      POSTGRES_DB: devops_db
      POSTGRES_USER: lpi_admin
      POSTGRES_PASSWORD: SecurePassword123!
    command:
      - "postgres"
      - "-c"
      - "max_connections=100"
      - "-c"
      - "shared_buffers=128MB"
      - "-c"
      - "wal_level=replica"
      - "-c"
      - "max_wal_size=1GB"
      - "-c"
      - "archive_mode=on"
      - "-c"
      - "archive_command=cd ."
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U lpi_admin -d devops_db"]
      interval: 5s
      timeout: 3s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: lpi-redis
    command: >
      redis-server 
      --requirepass RedisAuthPass123! 
      --maxmemory 256mb 
      --maxmemory-policy allkeys-lru 
      --appendonly yes 
      --appendfsync everysec
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "RedisAuthPass123!", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
EOF
```

#### Step 2: Starting Services & Verifying Runtime Status
Boot up the stack and verify that both containers achieve healthy statuses.

```bash
docker compose up -d
docker compose ps
```

*Expected Output:*
```text
NAME           IMAGE                COMMAND                  SERVICE    CREATED          STATUS                    PORTS
lpi-postgres   postgres:15-alpine   "docker-entrypoint.s…"   postgres   5 seconds ago    Up 4 seconds (healthy)    0.0.0.0:5432->5432/tcp
lpi-redis      redis:7-alpine       "docker-entrypoint.s…"   redis      5 seconds ago    Up 4 seconds (healthy)    0.0.0.0:6379->6379/tcp
```

#### Step 3: PostgreSQL Transaction Diagnostics & WAL Inspection
Connect to the PostgreSQL instance via `psql` to inspect active connections, database sizing, and WAL configuration state.

```bash
docker exec -it lpi-postgres psql -U lpi_admin -d devops_db -c "SHOW wal_level;"
docker exec -it lpi-postgres psql -U lpi_admin -d devops_db -c "SELECT name, setting, unit FROM pg_settings WHERE name IN ('shared_buffers', 'max_connections');"
docker exec -it lpi-postgres psql -U lpi_admin -d devops_db -c "SELECT pid, usename, client_addr, state, query FROM pg_stat_activity;"
```

*Expected Output:*
```text
 wal_level 
-----------
 replica
(1 row)

     name      | setting | unit 
---------------+---------+------
 max_connections| 100     | 
 shared_buffers| 16384   | 8kB
(2 rows)

 pid |  usename  | client_addr | state  |                        query                         
-----+-----------+-------------+--------+------------------------------------------------------
  42 | lpi_admin |             | active | SELECT pid, usename, client_addr, state, query FROM pg_stat_activity;
(1 row)
```

#### Step 4: Redis Engine Metrics & Eviction Inspection
Execute administrative commands on the Redis cluster to analyze memory allocation and eviction rules.

```bash
docker exec -it lpi-redis redis-cli -a RedisAuthPass123! INFO memory
docker exec -it lpi-redis redis-cli -a RedisAuthPass123! CONFIG GET maxmemory-policy
```

*Expected Output:*
```text
# Memory
used_memory:872344
used_memory_human:851.90K
used_memory_rss:9842688
used_memory_peak:872344
maxmemory:268435456
maxmemory_human:256.00M
1) "maxmemory-policy"
2) "allkeys-lru"
```

---

### Verification Questions — Block 1

1. **Question 1.1**: In PostgreSQL, what is the precise operational impact of selecting `wal_level = replica` compared to `wal_level = minimal`?
2. **Question 1.2**: If Redis is configured with `--maxmemory-policy allkeys-lru` and memory limits are exceeded, how does its behaviour differ from `noeviction`?

---

## Hands-On Exercise Block 2: Enterprise Object Storage Architecture (MinIO & OpenStack Swift Alignment)

### Deep-Dive Architecture & Production Trade-offs
1. **Object Storage Principles**: Unlike POSIX file systems or block storage (EBS/SAN), Object Storage is flat, metadata-driven, and accessible exclusively via HTTP REST APIs (S3/Swift). Objects are immutable; updating an object requires replacing it entirely.
2. **Erasure Coding & Bitrot Protection**: MinIO and OpenStack Swift partition object payloads into data and parity blocks across multiple drives/nodes (e.g., $N/2$ data + $N/2$ parity). This enables data retrieval even during multi-drive failures and automatically heals silent data corruption (bitrot).
3. **OpenStack Swift Reference Architecture**: OpenStack Swift manages object distribution using **Rings**. A Ring maps logical virtual paths (`/account/container/object`) to physical storage endpoints using consistent hashing algorithms.

```
Logical Request Path: GET /v1/AUTH_tenant/container/object.jpg
                           |
                           v
              +---------------------------+
              |     Swift Proxy Node      |
              +---------------------------+
                           |
            Lookup Partition in Hash Ring
                           |
        +------------------+------------------+
        |                  |                  |
        v                  v                  v
+---------------+  +---------------+  +---------------+
| Storage Node 1|  | Storage Node 2|  | Storage Node 3|
|  (Account)    |  |  (Container)  |  |   (Object)    |
+---------------+  +---------------+  +---------------+
```

---

### Step-by-Step Guided Lab Execution

#### Step 1: Deploying MinIO S3-Compliant Distributed Emulator
Create directory `lpi-block2` and write a `docker-compose.yml` to provision MinIO along with the `mc` (MinIO Client) CLI tool.

```bash
mkdir -p lpi-block2 && cd lpi-block2
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  minio:
    image: minio/minio:RELEASE.2023-09-20T22-40-07Z
    container_name: lpi-minio
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: MinioAdminPassword123!
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 5s
      timeout: 3s
      retries: 5

  mc:
    image: minio/mc:RELEASE.2023-09-18T19-50-47Z
    container_name: lpi-mc
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set myminio http://minio:9000 minioadmin MinioAdminPassword123!;
      mc mb myminio/production-artifacts;
      mc anonymous set download myminio/production-artifacts;
      tail -f /dev/null
      "
EOF
```

#### Step 2: Executing Object Storage Deployment
Bring up the stack to create the S3 bucket automatically.

```bash
docker compose up -d
docker compose ps
```

*Expected Output:*
```text
NAME        IMAGE                                        COMMAND                  SERVICE   CREATED          STATUS                    PORTS
lpi-mc      minio/mc:RELEASE.2023-09-18T19-50-47Z        "/bin/sh -c '/bin/sh…"   mc        6 seconds ago    Up 4 seconds              
lpi-minio   minio/minio:RELEASE.2023-09-20T22-40-07Z   "/usr/bin/docker-ent…"   minio     6 seconds ago    Up 5 seconds (healthy)    0.0.0.0:9000-9001->9000-9001/tcp
```

#### Step 3: Provisioning Objects and Validating S3 Headers via CLI
Upload a sample asset into the bucket using `mc` and inspect the returned HTTP headers using `curl`.

```bash
echo "BUILD_COMMIT_HASH=a1b2c3d4e5f6" > build.env
docker cp build.env lpi-mc:/tmp/build.env
docker exec -it lpi-mc mc cp /tmp/build.env myminio/production-artifacts/build.env
docker exec -it lpi-mc mc ls myminio/production-artifacts/
curl -I http://localhost:9000/production-artifacts/build.env
```

*Expected Output:*
```text
[2026-08-07 04:40:00 UTC]  30B STANDARD build.env

HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 30
Content-Type: text/plain; charset=utf-8
ETag: "8b9e6c4bf97b1029c3d4a8e2f1123456"
Last-Modified: Fri, 07 Aug 2026 04:40:00 GMT
Server: MinIO
Strict-Transport-Security: max-age=31536000; includeSubDomains
Vary: Origin
X-Amz-Request-Id: 177B7C8419A9B480
X-Content-Type-Options: nosniff
X-Xss-Protection: 1; mode=block
```

---

### Verification Questions — Block 2

1. **Question 2.1**: In OpenStack Swift, what three distinct roles do the Account, Container, and Object services perform within the architecture?
2. **Question 2.2**: Why are HTTP `ETag` headers critical during multi-part S3 object uploads in production CI/CD pipelines?

---

## Hands-On Exercise Block 3: Decoupled Messaging, Event Streaming, and Queueing Architectures (RabbitMQ)

### Deep-Dive Architecture & Production Trade-offs
1. **AMQP 0-9-1 Messaging Architecture**: RabbitMQ operates on the Advanced Message Queuing Protocol (AMQP 0-9-1). Applications publish messages to an **Exchange**, which routes them to one or more **Queues** based on **Bindings** and **Routing Keys**. Consumers subscribe to queues to process tasks asynchronously.
2. **Exchange Topology Types**:
   - **Direct**: Exact match between message routing key and queue binding key.
   - **Fanout**: Broadcasts messages to all bound queues, ignoring routing keys.
   - **Topic**: Pattern match using wildcards (`*` for one word, `#` for zero or more words).
   - **Headers**: Routes based on message header attributes.
3. **Reliability Primitives**: To prevent message loss during broker failures:
   - **Publisher Confirms**: Broker acknowledges receipt of message from publisher.
   - **Message & Queue Durability**: Queues marked `durable=true` persist metadata; messages set to `delivery_mode=2` persist payload to disk.
   - **Dead Letter Exchanges (DLX)**: Failed, unacknowledged, or expired messages are automatically routed to a fallback DLX queue for analysis.

```
                     +---------------------------------------+
                     |          Direct Exchange              |
                     |         (orders.exchange)             |
                     +---------------------------------------+
                                   /           \
                 Routing Key:     /             \ Routing Key:
               "order.created"   /               \ "order.created"
                                v                 v
          +-----------------------+     +-----------------------+
          | Queue: inventory-proc |     | Queue: billing-proc   |
          |  (durable=true)       |     |  (durable=true)       |
          +-----------------------+     +-----------------------+
                                                   |
                                            On Max-Retries / NACK
                                                   v
                                        +-----------------------+
                                        | Dead Letter Exchange  |
                                        |      (dlx.orders)     |
                                        +-----------------------+
```

---

### Step-by-Step Guided Lab Execution

#### Step 1: Provisioning RabbitMQ Broker with Management Infrastructure
Create directory `lpi-block3` and define a manifest deploying RabbitMQ with management plugins enabled.

```bash
mkdir -p lpi-block3 && cd lpi-block3
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.12-management-alpine
    container_name: lpi-rabbitmq
    environment:
      RABBITMQ_DEFAULT_USER: mqadmin
      RABBITMQ_DEFAULT_PASS: RabbitMqPassword123!
    ports:
      - "5672:5672"   # AMQP Protocol
      - "15672:15672" # Management UI / API
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
EOF
```

#### Step 2: Bootstrapping RabbitMQ and Verifying Operational Node Health
Bring up the container and verify operational readiness using `rabbitmq-diagnostics`.

```bash
docker compose up -d
docker exec -it lpi-rabbitmq rabbitmq-diagnostics check_running
```

*Expected Output:*
```text
Successfully connected to the RabbitMQ management plugin API.
Node 'rabbit@lpi-rabbitmq' is running.
```

#### Step 3: Configuring AMQP Topology via CLI (`rabbitmqadmin`)
Declare a Dead Letter Exchange (DLX), a primary exchange, a DLX queue, and a main queue configured with dead-lettering capabilities.

```bash
# Declare DLX and DLX Queue
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare exchange name=dlx.exchange type=direct
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare queue name=orders.dlq durable=true
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare binding source=dlx.exchange destination=orders.dlq routing_key=order.dead

# Declare Main Exchange and Queue bound to DLX
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare exchange name=orders.exchange type=direct
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare queue name=orders.main durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange", "x-dead-letter-routing-key":"order.dead"}'
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! declare binding source=orders.exchange destination=orders.main routing_key=order.created
```

*Expected Output:*
```text
exchange declared
queue declared
binding declared
exchange declared
queue declared
binding declared
```

#### Step 4: Testing Persistent Message Publishing and Queue Inspection
Publish a persistent message to the exchange and inspect queue depth via `rabbitmqctl`.

```bash
docker exec -it lpi-rabbitmq rabbitmqadmin -u mqadmin -p RabbitMqPassword123! publish exchange=orders.exchange routing_key=order.created payload="{'order_id': 9942, 'status': 'PENDING'}" delivery_mode=2
docker exec -it lpi-rabbitmq rabbitmqctl list_queues name messages messages_ready messages_unacknowledged
```

*Expected Output:*
```text
Message published
Timeout: 60 seconds ...
Listing queues ...
name	messages	messages_ready	messages_unacknowledged
orders.dlq	0	0	0
orders.main	1	1	0
```

---

### Verification Questions — Block 3

1. **Question 3.1**: What specific condition triggers a message to be automatically routed from a main queue to its configured Dead Letter Exchange (`x-dead-letter-exchange`)?
2. **Question 3.2**: In high-availability RabbitMQ clusters, how do **Quorum Queues** differ from legacy **Mirrored Queues** regarding consensus and data safety?

---

## Hands-On Exercise Block 4: Cloud Platform Service Abstractions & Service Discovery (OpenStack Alignment)

### Deep-Dive Architecture & Production Trade-offs
1. **OpenStack Component Reference Implementation**:
   - **Keystone**: Identity, authentication, and service catalog management (Issues Fernet tokens).
   - **Nova**: Compute instance lifecycle orchestration.
   - **Neutron**: Software-Defined Networking (SDN), routers, floating IPs, security groups.
   - **Glance**: Virtual machine image registry.
   - **Cinder**: Block storage provider.
   - **Swift**: Object storage provider.
2. **Service Discovery Architecture**: Microservices require dynamic endpoint resolution. Systems use either **Client-Side Discovery** (client queries registry like Consul/Eureka directly) or **Server-Side Discovery** (client hits a load balancer/DNS that queries the registry).
3. **Database per Service vs Shared Database**: Microservices should isolate data stores to enforce loose coupling and independent scaling. Sharing a single monolithic database creates tight coupling and single points of failure.

```
                    +----------------------------------+
                    |  Keystone / Auth Service API     |
                    +----------------------------------+
                                     |
                          Validates Fernet Token
                                     v
+------------------------+  REST   +------------------------+  SDN   +------------------------+
| Nova (Compute Service) |-------> | Neutron (Network Svc)  |------->| Floating IP / Router   |
+------------------------+         +------------------------+        +------------------------+
            |                                  |                                  |
   Attaches Volume                     Attaches Subnet                     Attaches Port
            v                                  v                                  v
+------------------------+         +------------------------+        +------------------------+
| Cinder (Block Storage) |         |  Glance (Image Svc)    |        | Target Compute Node    |
+------------------------+         +------------------------+        +------------------------+
```

---

### Step-by-Step Guided Lab Execution

#### Step 1: Provisioning Unified Polyglot Platform Infrastructure
Create directory `lpi-block4` and construct a full platform stack simulating an integrated microservices ecosystem with explicit service dependency checks and network isolation.

```bash
mkdir -p lpi-block4 && cd lpi-block4
cat << 'EOF' > docker-compose.yml
version: '3.8'

networks:
  frontend-net:
    driver: bridge
  backend-net:
    driver: bridge

services:
  app-db:
    image: postgres:15-alpine
    container_name: platform-db
    networks:
      - backend-net
    environment:
      POSTGRES_DB: app_production
      POSTGRES_USER: app_user
      POSTGRES_PASSWORD: AppPassword456!
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app_user -d app_production"]
      interval: 5s
      timeout: 3s
      retries: 5

  app-cache:
    image: redis:7-alpine
    container_name: platform-cache
    networks:
      - backend-net
    command: redis-server --requirepass CachePassword456!
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "CachePassword456!", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  api-gateway:
    image: nginx:1.25-alpine
    container_name: platform-gateway
    networks:
      - frontend-net
      - backend-net
    ports:
      - "8080:80"
    volumes:
      - ./gateway.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      app-db:
        condition: service_healthy
      app-cache:
        condition: service_healthy
EOF
```

#### Step 2: Defining NGINX Gateway Proxy Configuration
Create the gateway reverse proxy configuration simulating dynamic service routing.

```bash
cat << 'EOF' > gateway.conf
server {
    listen 80;
    server_name localhost;

    location /health {
        add_header Content-Type text/plain;
        return 200 'GATEWAY_OK';
    }

    location /db-status {
        proxy_pass http://platform-db:5432;
    }
}
EOF
```

#### Step 3: Initializing Platform Topology & Diagnostic Auditing
Launch the full platform and run network diagnostics to verify inter-container connectivity across isolated bridges.

```bash
docker compose up -d
docker compose ps
docker exec -it platform-gateway ping -c 2 platform-db
docker exec -it platform-gateway ping -c 2 platform-cache
curl -i http://localhost:8080/health
```

*Expected Output:*
```text
NAME               IMAGE                COMMAND                  SERVICE       CREATED          STATUS                    PORTS
platform-cache     redis:7-alpine       "docker-entrypoint.s…"   app-cache     8 seconds ago    Up 7 seconds (healthy)    6379/tcp
platform-db        postgres:15-alpine   "docker-entrypoint.s…"   app-db        8 seconds ago    Up 7 seconds (healthy)    5432/tcp
platform-gateway   nginx:1.25-alpine    "/docker-entrypoint.s…"   api-gateway   8 seconds ago    Up 7 seconds              0.0.0.0:8080->80/tcp

PING platform-db (172.28.0.2): 56 data bytes
64 bytes from 172.28.0.2: seq=0 ttl=64 time=0.081 ms
64 bytes from 172.28.0.2: seq=1 ttl=64 time=0.095 ms

PING platform-cache (172.28.0.3): 56 data bytes
64 bytes from 172.28.0.3: seq=0 ttl=64 time=0.075 ms
64 bytes from 172.28.0.3: seq=1 ttl=64 time=0.088 ms

HTTP/1.1 200 OK
Server: nginx/1.25.3
Date: Fri, 07 Aug 2026 04:42:00 GMT
Content-Type: text/plain
Content-Length: 10
Connection: keep-alive

GATEWAY_OK
```

---

### Verification Questions — Block 4

1. **Question 4.1**: In OpenStack, which service acts as the central authentication authority issuing tokens required by Nova, Neutron, and Glance to execute operations?
2. **Question 4.2**: Why is using a single, shared relational database across multiple microservices considered an architectural anti-pattern in cloud-native platforms?

---

<details>
<summary>Answers and Detailed Explanations</summary>

### Block 1 Answers

1. **Answer 1.1**: Setting `wal_level = replica` instructs PostgreSQL to log sufficient information in the Write-Ahead Log (WAL) to support write-ahead logging, point-in-time recovery (PITR), and read-only standby replicas. In contrast, `wal_level = minimal` strips out logging details required for replication (such as WAL entries for bulk loads), making standby server replication impossible.

2. **Answer 1.2**: Under `allkeys-lru`, when memory reaches `maxmemory`, Redis attempts to reclaim space by removing the least recently used (LRU) keys across the entire dataset, regardless of whether they have a set expiration (TTL). Under `noeviction`, Redis refuses all write commands (returning out-of-memory errors like `OOM command not allowed when used memory > 'maxmemory'`), while allowing read-only operations.

---

### Block 2 Answers

1. **Answer 2.1**:
   - **Account Service**: Manages accounts (tenants), listings of containers within the account, and account-level metadata stored in SQLite databases.
   - **Container Service**: Manages containers (analogous to S3 buckets), listings of objects within a specific container, and container-level metadata stored in SQLite databases.
   - **Object Service**: Manages actual raw binary object payloads and their associated HTTP metadata stored directly on local filesystem block devices using extended file attributes (xattrs).

2. **Answer 2.2**: The `ETag` header in S3/Swift stores the MD5 hash (or payload checksum) of the object payload. During multi-part CI/CD artifact uploads, verifying the returned `ETag` against the locally calculated payload hash ensures end-to-end data integrity, confirming that network corruption or truncated streams did not contaminate the storage bucket.

---

### Block 3 Answers

1. **Answer 3.1**: A message is delivered to a Dead Letter Exchange (DLX) under three specific operational conditions:
   - The message is explicitly rejected or non-acknowledged (`basic.reject` or `basic.nack`) by a consumer with `requeue=false`.
   - The message expires due to Per-Message or Per-Queue TTL (Time-To-Live).
   - The message is dropped because the target queue exceeded its maximum length limit (`x-max-length`).

2. **Answer 3.2**: **Quorum Queues** are built on the **Raft Consensus Algorithm**, providing deterministic data safety, predictable leader elections, and higher throughput under network partitions. **Mirrored Queues** (legacy classic queues) rely on custom asynchronous synchronization protocols that can suffer from message loss, sync-blocking behavior during node rejoins, and split-brain failures.

---

### Block 4 Answers

1. **Answer 4.1**: **Keystone** (OpenStack Identity Service). It provides authentication, token issuance (e.g., Fernet tokens), and maintains the unified Service Catalog. Every request sent to Nova, Neutron, Cinder, or Glance must present a valid Keystone auth token.

2. **Answer 4.2**: A shared database couples microservices at the physical data layer. It creates single points of database failure, invalidates independent schema migrations, leads to shared resource contention (lock escalation, connection exhaustion), and prevents individual microservices from choosing data engines suited to their workload (e.g., Document vs Relational vs In-Memory).

</details>

---

## Official Documentation References

- **Linux Professional Institute (LPI)**: [DevOps Tools Engineer 701-100 Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **OpenStack Documentation**: [OpenStack Architecture & Component Guides](https://docs.openstack.org/)
- **PostgreSQL Documentation**: [WAL Configuration & Architecture](https://www.postgresql.org/docs/current/wal-configuration.html)
- **Redis Documentation**: [Redis Persistence & Memory Management](https://redis.io/docs/management/optimizations/memory-optimization/)
- **RabbitMQ Documentation**: [AMQP 0-9-1 Concepts & Quorum Queues](https://www.rabbitmq.com/documentation.html)
- **MinIO Documentation**: [MinIO Erasure Coding & S3 Architecture](https://min.io/docs/minio/linux/index.html)