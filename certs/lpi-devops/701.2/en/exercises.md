# 701.2 — Standard Components and Platforms for Software

**Exam:** LPI DevOps Tools Engineer, 701-100 (v2.0.0) · **Weight:** 5

These exercises walk through the component families the objective names — object storage, relational and NoSQL databases, message brokers and queues, big-data processing, and OAuth 2.0 / OpenID Connect — by running a real instance of each and observing the behaviour that drives architectural decisions. Every step is executable; after each block there are comprehension questions, and the answers are in the collapsible section at the end.

**Time:** ~4 hours total. Each exercise is self-contained except Exercise 7 (Spark), which reuses the `lab-data` directory.

---

## 0. Lab environment

You need Docker Engine ≥ 24 with the Compose v2 plugin (or Podman with `podman compose`), `curl`, `jq`, `python3`, and roughly 6 GB of free RAM. Nothing here touches a cloud account and nothing costs money.

**Step 0.1** — Create the lab directory and the data directory Spark and `mc` will share:

```bash
mkdir -p ~/lab-701.2/lab-data && cd ~/lab-701.2
```

**Step 0.2** — Write `compose.yaml`:

```yaml
name: devops701

services:
  minio:
    image: quay.io/minio/minio:latest
    command: 'server /data --console-address ":9001"'
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin123
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio-data:/data

  mc:
    image: quay.io/minio/mc:latest
    profiles:
      - tools
    depends_on:
      - minio
    volumes:
      - mc-config:/root/.mc
      - ./lab-data:/data:z

  postgres:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: shop
    ports:
      - "5432:5432"
    volumes:
      - pg-data:/var/lib/postgresql/data

  mongo:
    image: mongo:7
    command: 'mongod --replSet rs0 --bind_ip_all'
    ports:
      - "27017:27017"
    volumes:
      - mongo-data:/data/db

  redis:
    image: redis:7
    command: 'redis-server --maxmemory 32mb --maxmemory-policy allkeys-lru --appendonly no'
    ports:
      - "6379:6379"

  rabbitmq:
    image: rabbitmq:3.13-management
    ports:
      - "5672:5672"
      - "15672:15672"

  kafka:
    image: apache/kafka:3.9.0

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: start-dev
    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
    ports:
      - "8080:8080"

volumes:
  minio-data:
  mc-config:
  pg-data:
  mongo-data:
```

**Step 0.3** — Start the platform and confirm every service is up:

```bash
docker compose up -d
docker compose ps
```

Output similar to:

```
NAME                  IMAGE                          STATUS          PORTS
devops701-kafka-1     apache/kafka:3.9.0             Up 12 seconds
devops701-keycloak-1  quay.io/keycloak/keycloak:26.0 Up 12 seconds   0.0.0.0:8080->8080/tcp
devops701-minio-1     quay.io/minio/minio:latest     Up 12 seconds   0.0.0.0:9000-9001->9000-9001/tcp
devops701-mongo-1     mongo:7                        Up 12 seconds   0.0.0.0:27017->27017/tcp
devops701-postgres-1  postgres:16                    Up 12 seconds   0.0.0.0:5432->5432/tcp
devops701-rabbitmq-1  rabbitmq:3.13-management       Up 12 seconds   0.0.0.0:5672->5672/tcp, 0.0.0.0:15672->15672/tcp
devops701-redis-1     redis:7                        Up 12 seconds   0.0.0.0:6379->6379/tcp
```

> On a SELinux host (Fedora, RHEL, CentOS Stream) the `:z` suffix on the `./lab-data` mount is what lets the container write there. Without it you get `Permission denied` even though the directory is world-writable.

**Questions 0**

1. The `mc` service has `profiles: ["tools"]`. Why did `docker compose up -d` not start it, and how do you run it?
2. Keycloak 25 and earlier used `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`. What happens if you use those names against the 26.0 image, and why does an image tag like `:latest` make this class of failure hard to reproduce?
3. `kafka` publishes no ports at all. What does that tell you about how you are expected to reach it in this lab?

---

## 1. Object storage (MinIO / the S3 API)

Object storage is not a filesystem: there are no directories, no partial writes, no rename, no POSIX locking. There is a flat keyspace inside a bucket, whole-object PUT/GET over HTTP, and per-object metadata. Every design decision in this exercise follows from that.

**Step 1.1** — Register the MinIO endpoint as an `mc` alias (the alias is persisted in the `mc-config` volume, so later `run` invocations reuse it):

```bash
docker compose run --rm mc alias set local http://minio:9000 minioadmin minioadmin123
```

```
Added `local` successfully.
```

**Step 1.2** — Create two buckets: an ordinary one, and one with object locking enabled (which requires versioning and can only be set at creation time):

```bash
docker compose run --rm mc mb local/reports
docker compose run --rm mc mb --with-lock local/audit
docker compose run --rm mc version enable local/reports
docker compose run --rm mc ls local
```

```
Bucket created successfully `local/reports`.
Bucket created successfully `local/audit`.
local/reports versioning is enabled
[2026-09-18 10:12:03 UTC]     0B audit/
[2026-09-18 10:12:01 UTC]     0B reports/
```

**Step 1.3** — Create an object, upload it twice with different content, and list the versions:

```bash
echo "revenue,region
1200,latam" > lab-data/q3.csv
docker compose run --rm mc cp /data/q3.csv local/reports/2026/q3.csv

echo "revenue,region
1450,latam" > lab-data/q3.csv
docker compose run --rm mc cp /data/q3.csv local/reports/2026/q3.csv

docker compose run --rm mc ls --versions local/reports/2026/
```

```
[2026-09-18 10:15:44 UTC]    28B STANDARD 0f2c1b6e-7a41-4a0e-9b1d-3c4a51f0d2aa v2 PUT q3.csv
[2026-09-18 10:15:31 UTC]    28B STANDARD 9d13a8c0-1e55-4f32-8d77-2b0e6a7c9f14 v1 PUT q3.csv
```

**Step 1.4** — Inspect the object's metadata and set a custom header:

```bash
docker compose run --rm mc stat local/reports/2026/q3.csv
docker compose run --rm mc cp --attr "x-amz-meta-owner=finance;x-amz-meta-retention-class=annual" \
  /data/q3.csv local/reports/2026/q3.csv
docker compose run --rm mc stat local/reports/2026/q3.csv
```

```
Name      : q3.csv
Date      : 2026-09-18 10:18:02 UTC
Size      : 28 B
ETag      : 4a9f0c2b19e7d5a83f6b1c0d2e4f7a91
Type      : file
Metadata  :
  Content-Type              : text/csv
  X-Amz-Meta-Owner          : finance
  X-Amz-Meta-Retention-Class: annual
```

**Step 1.5** — Generate a presigned URL and fetch it *from the host*. The MinIO endpoint is `minio:9000` on the Compose network, and the SigV4 signature covers the `Host` header — so you cannot simply rewrite the hostname to `localhost`:

```bash
URL=$(docker compose run --rm mc share download --expire=10m local/reports/2026/q3.csv \
  | awk '/^Share:/ {print $2}')
echo "$URL"

curl --resolve minio:9000:127.0.0.1 -s -D - -o /dev/null "$URL"
```

```
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 28
Content-Type: text/csv
ETag: "4a9f0c2b19e7d5a83f6b1c0d2e4f7a91"
Last-Modified: Fri, 18 Sep 2026 10:18:02 GMT
X-Amz-Meta-Owner: finance
x-amz-request-id: 185F2C4A9B1E7D3C
```

**Step 1.6** — Request only the first 12 bytes, then break the signature deliberately:

```bash
curl --resolve minio:9000:127.0.0.1 -s -D - -r 0-11 "$URL"
curl --resolve minio:9000:127.0.0.1 -s "${URL}&extra=tampered" | head -20
```

```
HTTP/1.1 206 Partial Content
Content-Range: bytes 0-11/28
Content-Length: 12

revenue,regi
```

```
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided.</Message></Error>
```

**Step 1.7** — Make the bucket anonymously readable, verify it, and then undo it:

```bash
docker compose run --rm mc anonymous set download local/reports
curl --resolve minio:9000:127.0.0.1 -s http://minio:9000/reports/2026/q3.csv
docker compose run --rm mc anonymous set none local/reports
```

**Step 1.8** — Apply a default WORM retention on the locked bucket and try to delete a protected object:

```bash
docker compose run --rm mc retention set --default COMPLIANCE 30d local/audit
docker compose run --rm mc cp /data/q3.csv local/audit/2026-q3-audit.csv
docker compose run --rm mc rm local/audit/2026-q3-audit.csv
```

```
mc: <ERROR> Failed to remove `local/audit/2026-q3-audit.csv`. Object, overwrite or version delete is not allowed due to object retention or legal hold.
```

**Questions 1**

1. You uploaded `q3.csv` three times to the same key. How many billable objects exist in `reports`, and what does a plain `mc ls` show? What operational risk does that create over a year?
2. The presigned URL worked with `--resolve` but would fail if you simply replaced `minio` with `localhost` in the URL. Explain why in terms of what SigV4 signs, and name the MinIO setting that fixes this properly for a production deployment behind a load balancer.
3. Step 1.6 returned `206 Partial Content`. Which of these is *not* possible with object storage, and why: reading byte range 5000–6000 of a 1 GB log, appending a line to that log, replacing the whole log?
4. The `ETag` was a plain MD5 here. What does an ETag ending in `-4` tell you about how the object was uploaded, and why does that break naive integrity checks?
5. `COMPLIANCE` retention prevents deletion by *anyone*, including the root credential, for the retention period. Give one case where you want `GOVERNANCE` mode instead.
6. A colleague proposes storing application session state in S3 instead of Redis, "because it's cheaper per GB". Give the two strongest technical objections.

---

## 2. Relational databases (PostgreSQL) — ACID, isolation and plans

**Step 2.1** — Open a psql session and create a schema with real constraints:

```bash
docker compose exec postgres psql -U postgres -d shop
```

```sql
CREATE TABLE accounts (
    id      int PRIMARY KEY,
    owner   text NOT NULL,
    balance numeric(12,2) NOT NULL CHECK (balance >= 0)
);

INSERT INTO accounts VALUES (1, 'ana', 1000.00), (2, 'beto', 500.00);

CREATE TABLE orders (
    id          bigserial PRIMARY KEY,
    account_id  int NOT NULL REFERENCES accounts(id),
    email       text NOT NULL,
    total_cents bigint NOT NULL CHECK (total_cents >= 0),
    status      text NOT NULL DEFAULT 'pending',
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

**Step 2.2** — Prove the constraints are enforced by the engine, not by the application:

```sql
UPDATE accounts SET balance = balance - 5000 WHERE id = 1;
INSERT INTO orders (account_id, email, total_cents) VALUES (99, 'x@example.com', 100);
```

```
ERROR:  new row for relation "accounts" violates check constraint "accounts_balance_check"
DETAIL:  Failing row contains (1, ana, -4000.00).
ERROR:  insert or update on table "orders" violates foreign key constraint "orders_account_id_fkey"
DETAIL:  Key (account_id)=(99) is not present in table "accounts".
```

**Step 2.3** — Reproduce a lost update. Open a **second** terminal with a second psql session; the two sessions are labelled **A** and **B**.

In A:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;   -- 1000.00
```

In B:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1;   -- 1000.00
```

In A:

```sql
UPDATE accounts SET balance = 900.00 WHERE id = 1;
COMMIT;
```

In B:

```sql
UPDATE accounts SET balance = 900.00 WHERE id = 1;
COMMIT;
SELECT balance FROM accounts WHERE id = 1;
```

```
 balance
---------
  900.00
```

Two withdrawals of 100 were applied and the balance dropped by 100. Money disappeared from the ledger.

**Step 2.4** — Repeat the same interleaving under `REPEATABLE READ`. Reset first (`UPDATE accounts SET balance = 1000.00 WHERE id = 1;`), then in both sessions start with:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
```

Run the same sequence. B's `UPDATE` now blocks until A commits, and then:

```
ERROR:  could not serialize access due to concurrent update
```

**Step 2.5** — Write it the way it should have been written in the first place, and observe the lock:

In A:

```sql
BEGIN;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;
```

In B:

```sql
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;   -- blocks
```

In a third session:

```sql
SELECT pid, state, wait_event_type, wait_event, left(query, 60) AS query
FROM pg_stat_activity WHERE datname = 'shop' AND state <> 'idle';
```

```
 pid  |        state        | wait_event_type | wait_event |                   query
------+---------------------+-----------------+------------+--------------------------------------------
  241 | idle in transaction |  Client         | ClientRead | SELECT balance FROM accounts WHERE id = 1 F
  258 | active              |  Lock           | transactionid | UPDATE accounts SET balance = balance - 100
```

Commit in A and watch B complete.

**Step 2.6** — Load 300 000 rows and look at a plan:

```sql
INSERT INTO orders (account_id, email, total_cents, status)
SELECT 1,
       'user' || (random() * 50000)::int || '@example.com',
       (random() * 100000)::bigint,
       (ARRAY['pending','paid','shipped','cancelled'])[1 + floor(random() * 4)::int]
FROM generate_series(1, 300000);

ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE email = 'user4242@example.com';
```

```
 Gather  (cost=1000.00..8792.10 rows=6 width=61) (actual time=0.412..38.907 rows=7 loops=1)
   Workers Planned: 2
   Workers Launched: 2
   ->  Parallel Seq Scan on orders  (cost=0.00..7791.50 rows=3 width=61) (actual time=22.1..31.4 rows=2 loops=3)
         Filter: (email = 'user4242@example.com'::text)
         Rows Removed by Filter: 99998
         Buffers: shared hit=3021
 Planning Time: 0.121 ms
 Execution Time: 38.956 ms
```

**Step 2.7** — Add the index and re-run the identical query:

```sql
CREATE INDEX orders_email_idx ON orders (email);
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE email = 'user4242@example.com';
```

```
 Bitmap Heap Scan on orders  (cost=4.35..28.12 rows=6 width=61) (actual time=0.031..0.041 rows=7 loops=1)
   Recheck Cond: (email = 'user4242@example.com'::text)
   Buffers: shared hit=10
   ->  Bitmap Index Scan on orders_email_idx  (cost=0.00..4.35 rows=6 width=0) (actual time=0.022..0.022 rows=7 loops=1)
         Index Cond: (email = 'user4242@example.com'::text)
 Planning Time: 0.198 ms
 Execution Time: 0.068 ms
```

**Step 2.8** — Add a partial index for the hot queue query, and check the connection ceiling:

```sql
CREATE INDEX orders_pending_idx ON orders (created_at DESC) WHERE status = 'pending';
EXPLAIN SELECT * FROM orders WHERE status = 'pending' ORDER BY created_at DESC LIMIT 20;

SELECT pg_size_pretty(pg_relation_size('orders_email_idx'))   AS full_idx,
       pg_size_pretty(pg_relation_size('orders_pending_idx')) AS partial_idx;

SHOW max_connections;
SELECT count(*) FROM pg_stat_activity;
```

**Questions 2**

1. In step 2.3 both transactions committed successfully and the data ended up wrong. Which ACID letter was not violated by this, and which anomaly is this called?
2. `REPEATABLE READ` turned a silent data loss into error `40001`. What must the *application* do that it did not have to do before, and why is that a design decision and not just a configuration one?
3. `UPDATE accounts SET balance = balance - 100` is safe at `READ COMMITTED` where `SELECT` then `UPDATE balance = 900` was not. Explain precisely why.
4. Session A in step 2.5 was `idle in transaction` while holding a row lock. Why is that state the single most dangerous thing on this list in production, and which two settings bound the damage?
5. The sequential scan read 3021 shared buffers and the index scan read 10. At what selectivity would the planner be *right* to ignore your index, and why is that not a planner bug?
6. `max_connections` is 100. Your Kubernetes deployment scales to 40 pods with a 20-connection pool each. What breaks, and what component do you put in front of PostgreSQL?

---

## 3. NoSQL — document store (MongoDB)

**Step 3.1** — Open `mongosh` and initialise the single-node replica set (a standalone `mongod` supports neither transactions nor change streams):

```bash
docker compose exec mongo mongosh
```

```javascript
rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongo:27017" }] })
rs.status().myState   // 1 = PRIMARY, may take a few seconds
```

**Step 3.2** — Insert documents whose shape differs, which is the whole point of a document store:

```javascript
use shop

db.products.insertMany([
  { sku: "kbd-01", name: "Mechanical keyboard", price: 89.90, tags: ["input", "usb"], stock: 12 },
  { sku: "mon-27", name: "27\" monitor", price: 310.00, tags: ["display"], stock: 3,
    specs: { panel: "IPS", hz: 144, ports: ["hdmi", "dp"] } },
  { sku: "cbl-hd", name: "HDMI cable", price: 7.50, stock: 240 }
])

db.products.find({ price: { $lt: 100 } }, { sku: 1, price: 1, _id: 0 })
db.products.find({ "specs.ports": "dp" }, { sku: 1, _id: 0 })
```

**Step 3.3** — Add a unique index and watch it reject a duplicate:

```javascript
db.products.createIndex({ sku: 1 }, { unique: true })
db.products.insertOne({ sku: "kbd-01", name: "Clone", price: 1.00 })
```

```
MongoServerError: E11000 duplicate key error collection: shop.products index: sku_1 dup key: { sku: "kbd-01" }
```

**Step 3.4** — Compare a collection scan to an index scan:

```javascript
for (let i = 0; i < 100000; i++) {
  db.products.insertOne({ sku: "bulk-" + i, name: "Bulk " + i, price: Math.random() * 500, stock: i % 50 })
}

db.products.find({ sku: "bulk-99999" }).explain("executionStats").executionStats
db.products.find({ stock: 42 }).explain("executionStats").executionStats
```

Compare `totalDocsExamined` and `executionStages.stage` (`IXSCAN` vs `COLLSCAN`) between the two.

**Step 3.5** — Run an aggregation pipeline:

```javascript
db.products.aggregate([
  { $match: { price: { $gte: 100 } } },
  { $group: { _id: { $cond: [{ $gt: ["$stock", 25] }, "healthy", "low"] },
              count: { $sum: 1 }, avgPrice: { $avg: "$price" } } },
  { $sort: { count: -1 } }
])
```

**Step 3.6** — "Schemaless" does not mean "no schema" — move the schema into the database:

```javascript
db.runCommand({
  collMod: "products",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["sku", "name", "price"],
      properties: {
        sku:   { bsonType: "string", pattern: "^[a-z0-9-]+$" },
        price: { bsonType: "number", minimum: 0 }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
})

db.products.insertOne({ sku: "no-price", name: "Broken" })
```

```
MongoServerError: Document failed validation
```

**Step 3.7** — Run a multi-document transaction and a write concern:

```javascript
const s = db.getMongo().startSession()
s.startTransaction({ writeConcern: { w: "majority" } })
const col = s.getDatabase("shop").products
col.updateOne({ sku: "kbd-01" }, { $inc: { stock: -1 } })
col.updateOne({ sku: "cbl-hd" }, { $inc: { stock: -1 } })
s.commitTransaction()
s.endSession()

db.products.insertOne({ sku: "wc-demo", name: "Write concern", price: 1 },
                      { writeConcern: { w: "majority", wtimeout: 5000 } })
```

**Questions 3**

1. Step 3.1 was mandatory before step 3.7. What is the underlying reason a single `mongod` cannot offer multi-document transactions, and what does that tell you about where MongoDB's durability guarantee actually lives?
2. You connected with `docker compose exec`. If you connect from the host with `mongosh mongodb://localhost:27017`, the handshake succeeds and then the driver fails. Why? (The answer is the same reason a Kubernetes StatefulSet needs a headless Service.)
3. Step 3.6 put a JSON Schema in the database after the collection already had documents in it. What does `validationLevel: "strict"` do to the pre-existing documents that violate it, and which value would you choose during a live migration?
4. Both PostgreSQL (Exercise 2) and MongoDB rejected bad data. Name two classes of integrity constraint that PostgreSQL enforces and `$jsonSchema` cannot.
5. `w: "majority"` costs latency on every write. Describe a collection in this shop where `w: 1` is the correct choice and one where it is negligence.
6. Give the concrete data-shape signal — not a vague "flexibility" argument — that says a workload belongs in a document store rather than in PostgreSQL. Then give the counter-signal that says it does not.

---

## 4. NoSQL — key/value cache (Redis)

**Step 4.1** — Open the CLI and build the primitives an application layer actually uses:

```bash
docker compose exec redis redis-cli
```

```
SET session:u42 "{\"user\":42,\"role\":\"editor\"}" EX 30
TTL session:u42
INCR metrics:page:home
INCRBY metrics:page:home 5
HSET cart:u42 sku:kbd-01 2 sku:cbl-hd 1
HGETALL cart:u42
EXPIRE cart:u42 3600
OBJECT ENCODING cart:u42
```

```
OK
(integer) 30
(integer) 1
(integer) 6
(integer) 2
1) "sku:kbd-01"
2) "2"
3) "sku:cbl-hd"
4) "1"
(integer) 1
"listpack"
```

**Step 4.2** — Wait 30 seconds and confirm the session is gone:

```
TTL session:u42
GET session:u42
```

```
(integer) -2
(nil)
```

**Step 4.3** — Implement a correct distributed lock, then break the naive one:

```
SET lock:invoice:2026-09 "worker-a-token-93f1" NX PX 10000
SET lock:invoice:2026-09 "worker-b-token-2ac7" NX PX 10000
PTTL lock:invoice:2026-09
```

```
OK
(nil)
(integer) 8422
```

**Step 4.4** — Trigger eviction. `maxmemory` is 32 MB with `allkeys-lru`:

```
CONFIG GET maxmemory
CONFIG GET maxmemory-policy
DEBUG POPULATE 500000
DBSIZE
INFO stats
INFO memory
```

Look for `evicted_keys` in `INFO stats` and `used_memory_human` in `INFO memory`. `DBSIZE` will be well below 500 000.

```
# Stats
expired_keys:2
evicted_keys:238417
keyspace_misses:0
```

**Step 4.5** — Check the durability posture of this instance:

```
CONFIG GET appendonly
CONFIG GET save
BGSAVE
LASTSAVE
INFO persistence
```

**Step 4.6** — Observe what your application is really sending, in a second terminal:

```bash
docker compose exec redis redis-cli MONITOR
```

Then in the first session run a few commands and watch them appear. Stop `MONITOR` with `Ctrl-C`.

**Questions 4**

1. Step 4.4 destroyed a quarter of a million keys and Redis reported success throughout. Which single configuration value turns this instance from a cache into something that will hand your application stale-free but *incomplete* data, and what is the failure mode if you set it to `noeviction` instead?
2. `SET key value NX PX 10000` is the correct lock acquisition. Why is `SETNX` followed by `EXPIRE` wrong, and why does the *release* also need care — what is the token for?
3. `MONITOR` and `DEBUG POPULATE` are both in this exercise and neither belongs in production. Give the specific cost of each.
4. `OBJECT ENCODING` returned `listpack` for a two-field hash. What happens to memory and to access complexity when that hash grows past `hash-max-listpack-entries`?
5. The compose file sets `--appendonly no`. Describe the exact data loss window after a `kill -9` of this container, and say which of the exercise's data (sessions, cart, page metrics) you are willing to lose that way.
6. Redis and RabbitMQ can both hold a list of pending jobs (`LPUSH`/`BRPOP` vs a queue). Name the two guarantees the broker gives that the Redis list does not.

---

## 5. Message broker — AMQP routing and dead-lettering (RabbitMQ)

**Step 5.1** — Fetch the management CLI from the running broker (it is a Python script served by the management plugin) and confirm it talks to the node:

```bash
curl -fsSL http://localhost:15672/cli/rabbitmqadmin -o rabbitmqadmin
chmod +x rabbitmqadmin
./rabbitmqadmin -u guest -p guest list exchanges name type
```

```
+--------------------+---------+
|        name        |  type   |
+--------------------+---------+
|                    | direct  |
| amq.direct         | direct  |
| amq.fanout         | fanout  |
| amq.topic          | topic   |
+--------------------+---------+
```

**Step 5.2** — Declare a topic exchange and two consumers with different interests:

```bash
./rabbitmqadmin -u guest -p guest declare exchange name=orders type=topic durable=true
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true
./rabbitmqadmin -u guest -p guest declare queue name=audit   durable=true
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=billing routing_key=order.created
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=audit   routing_key='order.#'
./rabbitmqadmin -u guest -p guest list bindings source destination routing_key
```

**Step 5.3** — Publish three messages with different routing keys and count what landed where:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='{"id":1,"total":8990}' properties='{"delivery_mode":2,"content_type":"application/json"}'
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.cancelled \
  payload='{"id":1}' properties='{"delivery_mode":2}'
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=shipment.dispatched \
  payload='{"id":1}' properties='{"delivery_mode":2}'

./rabbitmqadmin -u guest -p guest list queues name messages
```

```
+---------+----------+
|  name   | messages |
+---------+----------+
| audit   | 2        |
| billing | 1        |
+---------+----------+
```

**Step 5.4** — Publish to a routing key nobody is bound to, and to a non-existent exchange:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=nobody.listens payload='lost'
./rabbitmqadmin -u guest -p guest publish exchange=does-not-exist routing_key=x payload='lost'
```

```
Message published but NOT routed
*** Not found: /api/exchanges/%2F/does-not-exist/publish
```

**Step 5.5** — Add a dead-letter path. First try to redeclare `billing` with new arguments, and read the error carefully:

```bash
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true \
  arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"billing.dlq"}'
```

```
*** Error: 400 Bad Request: inequivalent arg 'x-dead-letter-exchange' for queue 'billing' in vhost '/': received the value 'none' of type 'longstr' but current is none
```

Delete and recreate it properly, then re-bind:

```bash
./rabbitmqadmin -u guest -p guest declare queue name=billing.dlq durable=true
./rabbitmqadmin -u guest -p guest delete queue name=billing
./rabbitmqadmin -u guest -p guest declare queue name=billing durable=true \
  arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"billing.dlq","x-max-length":1000}'
./rabbitmqadmin -u guest -p guest declare binding source=orders destination=billing routing_key=order.created
```

**Step 5.6** — Publish, consume with a *reject*, and watch the message move to the DLQ:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='{"id":2,"total":"not-a-number"}' properties='{"delivery_mode":2}'

./rabbitmqadmin -u guest -p guest get queue=billing ackmode=reject_requeue_false count=1
./rabbitmqadmin -u guest -p guest list queues name messages
```

```
+---------+----------+
|  name   | messages |
+---------+----------+
| audit   | 3        |
| billing | 0        |
| billing.dlq | 1    |
+---------+----------+
```

**Step 5.7** — Prove that durability is two separate decisions. Publish one persistent and one transient message, then restart the broker:

```bash
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='persistent' properties='{"delivery_mode":2}'
./rabbitmqadmin -u guest -p guest publish exchange=orders routing_key=order.created \
  payload='transient' properties='{"delivery_mode":1}'

docker compose restart rabbitmq
sleep 20
./rabbitmqadmin -u guest -p guest list queues name messages
```

**Questions 5**

1. `order.cancelled` reached `audit` but not `billing`. Reconstruct the routing decision the broker made, and say what `order.*` would have matched that `order.#` did.
2. Step 5.4 reported "published but NOT routed" and returned success to the publisher. Which two AMQP features would have told the producer that its message went nowhere?
3. Explain the `inequivalent arg` error in one sentence, and then explain why it is a *good* error — what would silently break if RabbitMQ had accepted the redeclaration?
4. The DLQ in step 5.5 used `x-dead-letter-exchange: ""`. What is that exchange, and why does the routing key have to be the exact queue name in that case?
5. Three things must all be true for a message to survive a broker restart. Name them.
6. `x-max-length: 1000` was set on `billing`. When the limit is hit, which message is dropped — the oldest or the newest — and what is the alternative behaviour you can configure?

---

## 6. Message log — partitions, offsets and replay (Apache Kafka)

A broker deletes a message once it is acknowledged. A log keeps it for a retention period and lets every consumer group read it independently. That difference is the whole exercise.

**Step 6.1** — Create a topic with three partitions and describe it:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic orders --partitions 3 --replication-factor 1

docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic orders
```

```
Topic: orders	PartitionCount: 3	ReplicationFactor: 1	Configs:
	Topic: orders	Partition: 0	Leader: 1	Replicas: 1	Isr: 1
	Topic: orders	Partition: 1	Leader: 1	Replicas: 1	Isr: 1
	Topic: orders	Partition: 2	Leader: 1	Replicas: 1	Isr: 1
```

**Step 6.2** — Produce keyed records. The key decides the partition, and the partition is the only ordering guarantee Kafka gives you:

```bash
docker compose exec -T kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic orders \
  --property parse.key=true --property key.separator=: <<'EOF'
cust-1:{"order":101,"state":"created"}
cust-2:{"order":102,"state":"created"}
cust-1:{"order":101,"state":"paid"}
cust-3:{"order":103,"state":"created"}
cust-1:{"order":101,"state":"shipped"}
EOF
```

**Step 6.3** — Read everything from the beginning, showing key and partition:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning \
  --property print.key=true --property print.partition=true --property print.offset=true \
  --timeout-ms 5000
```

```
Partition:1	Offset:0	cust-1	{"order":101,"state":"created"}
Partition:1	Offset:1	cust-1	{"order":101,"state":"paid"}
Partition:1	Offset:2	cust-1	{"order":101,"state":"shipped"}
Partition:0	Offset:0	cust-2	{"order":102,"state":"created"}
Partition:2	Offset:0	cust-3	{"order":103,"state":"created"}
[2026-09-18 11:40:12,004] ERROR Error processing message, terminating consumer process:  (kafka.tools.ConsoleConsumer$)
org.apache.kafka.common.errors.TimeoutException
Processed a total of 5 messages
```

The `TimeoutException` is `--timeout-ms` doing its job; the "Processed a total of 5 messages" line is the result.

**Step 6.4** — Read as a consumer group, then inspect the committed offsets:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning \
  --group billing --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group billing
```

```
GROUP    TOPIC   PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID  HOST  CLIENT-ID
billing  orders  0          1               1               0    -            -     -
billing  orders  1          3               3               0    -            -     -
billing  orders  2          1               1               0    -            -     -
```

**Step 6.5** — Run the same consumer again: it returns nothing. Then rewind the group and run it again — the same five records come back:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --group billing --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --group billing --topic orders \
  --reset-offsets --to-earliest --execute

docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --group billing --timeout-ms 5000
```

**Step 6.6** — Add a second, independent group and confirm it starts from zero without affecting `billing`:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning \
  --group analytics --timeout-ms 5000

docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --list
```

**Step 6.7** — Change retention, and create a compacted topic:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders --alter --add-config retention.ms=60000

docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic customer-state --partitions 3 --replication-factor 1 \
  --config cleanup.policy=compact --config min.cleanable.dirty.ratio=0.01

docker compose exec kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name customer-state --describe
```

**Questions 6**

1. All three `cust-1` records landed on partition 1, in order. State the mechanism, and then state exactly what ordering guarantee you have across `cust-1` and `cust-2`.
2. You run 5 consumer instances in the group `billing` against this 3-partition topic. How many do useful work, and what is the rule that decides?
3. In step 6.5 the second run returned nothing even though the data was still on disk. Where is the "already read" state stored, and why is that architecturally different from RabbitMQ's acknowledgement?
4. Step 6.7 set `retention.ms=60000` on a topic that `analytics` may not have consumed yet. Describe the failure and the exception the lagging consumer will eventually see.
5. `cleanup.policy=compact` keeps the last record per key forever. Give one thing that topic can now be used for that a time-retained topic cannot, and say what a record with a `null` value means there.
6. The `kafka` service publishes no ports. If you map `9092:9092` and connect a client from the host, the metadata request succeeds and then the producer hangs. Name the broker setting responsible and explain the two-step connection Kafka clients make.

---

## 7. Big data processing (Apache Spark)

**Step 7.1** — Start a PySpark shell in local mode, with the Spark UI exposed and the lab directory mounted:

```bash
docker run --rm -it -u root -p 4040:4040 -v "$PWD/lab-data:/data:z" \
  spark:3.5.1-python3 /opt/spark/bin/pyspark
```

> If your registry mirror does not carry that tag, `spark:python3` resolves to the current Python-enabled build.

```
Welcome to
      ____              __
     / __/__  ___ _____/ /__
    _\ \/ _ \/ _ `/ __/  '_/
   /__ / .__/\_,_/_/ /_/\_\   version 3.5.1
      /_/

Using Python version 3.11.x
Spark context Web UI available at http://...:4040
SparkSession available as 'spark'.
```

**Step 7.2** — Generate two million synthetic events and write them as CSV:

```python
from pyspark.sql import functions as F

events = (spark.range(0, 2000000)
    .withColumn("user_id", (F.rand(seed=42) * 10000).cast("int"))
    .withColumn("country", F.element_at(
        F.array(F.lit("ar"), F.lit("br"), F.lit("de"), F.lit("us")),
        (F.rand(seed=7) * 4 + 1).cast("int")))
    .withColumn("amount_cents", (F.rand(seed=13) * 50000).cast("long")))

events.write.mode("overwrite").option("header", True).csv("/data/events_csv")
```

**Step 7.3** — Read it back and run an aggregation:

```python
df = spark.read.option("header", True).option("inferSchema", True).csv("/data/events_csv")
df.count()

(df.groupBy("country")
   .agg(F.count("*").alias("events"), F.sum("amount_cents").alias("total_cents"))
   .orderBy(F.desc("total_cents"))
   .show())
```

```
+-------+------+-----------+
|country|events|total_cents|
+-------+------+-----------+
|     us|500213|12503991284|
|     de|499812|12491020117|
|     br|500104|12498773905|
|     ar|499871|12489330442|
+-------+------+-----------+
```

**Step 7.4** — Look at the physical plan and find the shuffle:

```python
(df.groupBy("country")
   .agg(F.sum("amount_cents"))
   .explain())
```

```
== Physical Plan ==
AdaptiveSparkPlan isFinalPlan=false
+- HashAggregate(keys=[country#23], functions=[sum(amount_cents#24L)])
   +- Exchange hashpartitioning(country#23, 200), ENSURE_REQUIREMENTS
      +- HashAggregate(keys=[country#23], functions=[partial_sum(amount_cents#24L)])
         +- FileScan csv [country#23,amount_cents#24L] Batched: false, ...
```

**Step 7.5** — Write the same data as partitioned Parquet and compare the plans:

```python
df.write.mode("overwrite").partitionBy("country").parquet("/data/events_parquet")

pq = spark.read.parquet("/data/events_parquet")
pq.filter("country = 'ar'").filter("amount_cents > 49000").explain()
```

```
== Physical Plan ==
*(1) Filter (isnotnull(amount_cents#61L) AND (amount_cents#61L > 49000))
+- *(1) ColumnarToRow
   +- FileScan parquet [id#59L,user_id#60,amount_cents#61L,country#62]
        PartitionFilters: [isnotnull(country#62), (country#62 = ar)],
        PushedFilters: [IsNotNull(amount_cents), GreaterThan(amount_cents,49000)],
        ReadSchema: struct<id:bigint,user_id:int,amount_cents:bigint>
```

**Step 7.6** — Leave the shell open, and from the host compare the two layouts on disk:

```bash
du -sh lab-data/events_csv lab-data/events_parquet
ls lab-data/events_parquet
```

```
612M	lab-data/events_csv
 84M	lab-data/events_parquet
_SUCCESS  country=ar  country=br  country=de  country=us
```

**Step 7.7** — Open `http://localhost:4040` in a browser while a job runs. Trigger one and watch the stages:

```python
df.groupBy("user_id").count().orderBy(F.desc("count")).limit(5).collect()
```

In the **SQL / DataFrame** and **Stages** tabs, find the stage boundary and the shuffle read/write sizes. Exit the shell with `Ctrl-D`.

**Questions 7**

1. `spark.range(...).withColumn(...)` returned instantly; `df.count()` took seconds. Name the evaluation model and say which of the calls in step 7.2 and 7.3 were the actions.
2. `Exchange hashpartitioning(country, 200)` appears in the plan. What physically happens at that line, why is it the most expensive thing in most Spark jobs, and where does the number 200 come from?
3. Parquet was 7× smaller *and* produced `PushedFilters` and `PartitionFilters` where CSV produced neither. Explain both benefits from the same underlying property of the format.
4. `partitionBy("country")` created four directories. What goes wrong if you `partitionBy("user_id")` instead, and what is the name of that anti-pattern?
5. `inferSchema` was used in step 7.3. What does it cost, and what do you do instead in a production pipeline?
6. This ran in local mode with no cluster. Name the three roles in a real Spark deployment and say which of them your `/opt/spark/bin/pyspark` process was playing.
7. Spark processed a bounded dataset here. State the one-line difference between this and what Apache Flink is built for, and name the platform component from Exercise 6 that would feed it.

---

## 8. OAuth 2.0 and OpenID Connect (Keycloak)

OAuth 2.0 is **delegated authorization**: an access token says a client may call an API. OpenID Connect is a thin identity layer on top: an ID token says *who the user is*. Confusing the two is the most common production mistake in this area.

**Step 8.1** — Read the discovery document. Everything else in this exercise is a URL from it:

```bash
curl -s http://localhost:8080/realms/master/.well-known/openid-configuration \
  | jq '{issuer, token_endpoint, authorization_endpoint, jwks_uri, grant_types_supported, code_challenge_methods_supported}'
```

```
{
  "issuer": "http://localhost:8080/realms/master",
  "token_endpoint": "http://localhost:8080/realms/master/protocol/openid-connect/token",
  "authorization_endpoint": "http://localhost:8080/realms/master/protocol/openid-connect/auth",
  "jwks_uri": "http://localhost:8080/realms/master/protocol/openid-connect/certs",
  "grant_types_supported": [
    "authorization_code",
    "refresh_token",
    "client_credentials",
    "urn:ietf:params:oauth:grant-type:device_code"
  ],
  "code_challenge_methods_supported": [
    "plain",
    "S256"
  ]
}
```

**Step 8.2** — Create a realm, a confidential service client, and a public browser client that requires PKCE:

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=devops -s enabled=true

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r devops \
  -s clientId=orders-api -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false -s secret=s3cr3t-orders

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r devops \
  -s clientId=portal-ui -s publicClient=true -s standardFlowEnabled=true \
  -s 'redirectUris=["http://localhost:3000/callback"]' \
  -s 'attributes."pkce.code.challenge.method"=S256'

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh create users -r devops \
  -s username=ana -s enabled=true -s email=ana@example.com -s emailVerified=true

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh set-password -r devops \
  --username ana --new-password 'Passw0rd!'
```

> Quote `'Passw0rd!'` in single quotes: in an interactive bash shell, `!` inside double quotes triggers history expansion.

**Step 8.3** — Machine-to-machine: the `client_credentials` grant, which has no user at all:

```bash
AT=$(curl -s -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token \
  -d grant_type=client_credentials \
  -d client_id=orders-api \
  -d client_secret=s3cr3t-orders | jq -r .access_token)

echo "${AT:0:40}..."
```

**Step 8.4** — Decode the token. A JWT is base64url, not base64 — decode it properly:

```bash
decode() {
  python3 -c "import sys,base64,json; p=sys.argv[1].split('.')[int(sys.argv[2])]; \
print(json.dumps(json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4))), indent=2))" "$1" "$2"
}

decode "$AT" 0     # header
decode "$AT" 1     # payload
```

```
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "rF8k2QpVn3YtLc0aHs7xJdWmB1oEuZgN9iKvTr4XyPc"
}
```

```
{
  "exp": 1789740123,
  "iat": 1789739823,
  "jti": "5a0c3b71-90e2-4f1c-8d44-6b2e19a7c0fd",
  "iss": "http://localhost:8080/realms/devops",
  "aud": "account",
  "sub": "c9b1f2a4-7d33-4e58-9ac0-1f7b6d2e8a35",
  "typ": "Bearer",
  "azp": "orders-api",
  "scope": "email profile",
  "clientId": "orders-api",
  "preferred_username": "service-account-orders-api"
}
```

**Step 8.5** — Fetch the signing keys the API would use to verify that token offline, and match the `kid`:

```bash
curl -s http://localhost:8080/realms/devops/protocol/openid-connect/certs \
  | jq '.keys[] | {kid, kty, alg, use}'
```

**Step 8.6** — Verify the token the other way, at the introspection endpoint (RFC 7662):

```bash
curl -s -u orders-api:s3cr3t-orders \
  -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token/introspect \
  -d "token=$AT" | jq '{active, exp, client_id, scope, token_type}'

curl -s -u orders-api:s3cr3t-orders \
  -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token/introspect \
  -d "token=not.a.real.token" | jq .
```

```
{
  "active": true,
  "exp": 1789740123,
  "client_id": "orders-api",
  "scope": "email profile",
  "token_type": "Bearer"
}
```

```
{
  "active": false
}
```

**Step 8.7** — Now the user-facing flow: Authorization Code with PKCE (RFC 7636). Build the verifier and challenge:

```bash
VERIFIER=$(openssl rand -base64 60 | tr -d '\n=' | tr '/+' '_-')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -binary -sha256 | openssl base64 | tr -d '\n=' | tr '/+' '_-')
echo "verifier:  $VERIFIER"
echo "challenge: $CHALLENGE"
```

**Step 8.8** — Start a listener so you can read the redirect, then open the authorization URL in a browser and log in as `ana` / `Passw0rd!`:

```bash
python3 -m http.server 3000 &

echo "http://localhost:8080/realms/devops/protocol/openid-connect/auth?client_id=portal-ui&response_type=code&scope=openid%20profile%20email&redirect_uri=http://localhost:3000/callback&state=xyz123&code_challenge=${CHALLENGE}&code_challenge_method=S256"
```

The listener logs the redirect:

```
127.0.0.1 - - [18/Sep/2026 12:31:09] "GET /callback?state=xyz123&session_state=...&code=8f3c...a1 HTTP/1.1" 404 -
```

**Step 8.9** — Exchange the code for tokens, supplying the verifier:

```bash
CODE='<paste the code value here>'

curl -s -X POST http://localhost:8080/realms/devops/protocol/openid-connect/token \
  -d grant_type=authorization_code \
  -d client_id=portal-ui \
  -d code="$CODE" \
  -d redirect_uri=http://localhost:3000/callback \
  -d code_verifier="$VERIFIER" | jq 'keys'
```

```
[
  "access_token",
  "expires_in",
  "id_token",
  "not-before-policy",
  "refresh_expires_in",
  "refresh_token",
  "scope",
  "session_state",
  "token_type"
]
```

**Step 8.10** — Repeat step 8.9 with a wrong `code_verifier` (change one character), and with the same code twice. Record both errors. Then decode the `id_token` and compare its claims to the `access_token`'s:

```bash
kill %1   # stop the http.server
```

**Questions 8**

1. `orders-api` used `client_credentials`; `portal-ui` used `authorization_code`. State the rule that decides which grant a given component gets, and say why `portal-ui` has no client secret.
2. PKCE protects against one specific attack. Describe it concretely — what does the attacker steal, and what stops them from using it?
3. You decoded the JWT with `base64.urlsafe_b64decode`. What is unsafe about *decoding* a token in order to trust its contents, and what are the four things a resource server must check before accepting it?
4. Step 8.5 (JWKS, offline verification) and step 8.6 (introspection) both validate a token. Give the trade-off in one sentence each, and say which one you pick for a 10 000 rps API and which for a banking transfer endpoint.
5. Both tokens in step 8.10 came from the same response. Which one do you send to `orders-api` in the `Authorization` header, which one must never leave the client, and what is the `aud` claim's role in that distinction?
6. Reusing an authorization code fails. Which OAuth threat does single-use enforcement address, and what should a correct authorization server do to the tokens already issued for that code?
7. The issuer here is `http://localhost:8080/...`. Name three things that are required to change before this configuration is acceptable in production.

---

## 9. Design exercise — placing the components

No commands. Read the scenario and write your answer before opening the key.

> A ticketing platform sells seats for live events. Peak traffic is 40× baseline for the ten minutes a popular event goes on sale. Requirements: (a) a seat may never be sold twice; (b) each purchase must send a confirmation email, update a loyalty balance, and feed a fraud model, and adding a fourth consumer later must not require touching the purchase code; (c) users upload PDF vouchers and ID scans, retained seven years, auditable; (d) the business wants hourly revenue-by-venue dashboards over two years of history; (e) partner box offices call a REST API on behalf of themselves, and end users log in through a web app; (f) the seat map for an event is read thousands of times per second and changes rarely.

**Questions 9**

1. Assign a component family from this objective to each of (a) through (f), and name one concrete implementation for each.
2. For (a), state which technology you would *not* use and why, referring to a specific result from Exercise 2 or 4.
3. For (b), justify the choice between a message broker and a message log using requirement (b)'s last clause.
4. For (d), explain why the dashboard should not query the same store as (a).
5. For (e), name the two OAuth grants involved and which one gets an ID token.
6. For (f), describe the cache invalidation strategy and what happens to correctness if the cache is lost entirely during the on-sale spike.

---

## 10. Cleanup

```bash
cd ~/lab-701.2
docker compose down -v
docker image rm spark:3.5.1-python3 2>/dev/null
rm -f rabbitmqadmin
```

`-v` removes the named volumes; without it, `minio-data`, `pg-data`, `mongo-data` and `mc-config` survive and the next `up` starts with the old state.

---

<details>
<summary><strong>Answers</strong></summary>

#### Answers 0

1. A service with a `profiles` key is excluded from `up` unless the profile is activated. You run it on demand with `docker compose run --rm mc <args>`, which starts its `depends_on` services and then runs the container with `mc` as entrypoint and your arguments appended. This is the standard pattern for one-shot admin/tooling containers in a Compose stack.
2. Keycloak 26 renamed the bootstrap variables to `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`; the old names still work but are deprecated and will be removed. With a floating tag like `:latest` the container that worked yesterday silently stops creating the admin user after an upstream release, and your only symptom is a login failure — nothing in your repository changed, so `git bisect` finds nothing. This is the argument for pinning image digests or at least exact versions in every environment.
3. The default `apache/kafka` image advertises `PLAINTEXT://localhost:9092`, which is only meaningful inside the container. Publishing the port would let you open a TCP connection but the broker would hand the client back an unreachable address. The lab therefore drives Kafka with `docker compose exec`, and question 6.6 makes the trap explicit.

#### Answers 1

1. Three object *versions* exist and all three are billable; `mc ls` shows one entry, because a plain listing returns only the current version of each key. Over a year, a job that rewrites the same key hourly accumulates ~8 800 versions of data you cannot see in the console and are paying for. The fix is a lifecycle rule that expires non-current versions after N days (`mc ilm rule add --noncurrent-expire-days 30`).
2. SigV4 signs a canonical request that includes the `Host` header. Changing the hostname changes the string that was signed, so the computed signature no longer matches and you get `SignatureDoesNotMatch`. The correct production fix is to set `MINIO_SERVER_URL` (and `MINIO_BROWSER_REDIRECT_URL`) to the public hostname that clients actually use, so MinIO signs presigned URLs for that name rather than for its internal one.
3. Reading a byte range is possible — that is the `Range` header and the `206` you saw, and it is why Parquet works well on object storage. Appending is not possible: there is no partial write; the only way to "append" is to read the whole object, modify it, and PUT it back in full. Replacing the whole object is possible and is what the third upload in step 1.3 did.
4. A suffix like `-4` means the object was uploaded as a multipart upload in 4 parts, and the ETag is the MD5 of the concatenated part MD5s, re-hashed — not the MD5 of the file content. Any integrity check that computes `md5sum localfile` and compares it to the ETag will report a false mismatch for every large object. Use checksums (`x-amz-checksum-sha256`) or compare sizes plus your own stored digest.
5. `GOVERNANCE` mode allows a principal holding the `s3:BypassGovernanceRetention` permission to shorten or remove the lock. You want that when the retention is a safety net against accidental deletion and operational mistakes rather than a regulatory requirement — for example a 7-day lock on backup objects that a platform team must occasionally be able to clean up. `COMPLIANCE` is for regulatory retention where "nobody, ever" is the point.
6. First, latency and cost model: object storage charges and is optimised per request, with tens of milliseconds per GET; session lookup happens on every request and needs sub-millisecond reads. Second, there is no TTL-driven expiry in the data path and no atomic read-modify-write, so session mutation is a lost-update race and expiry becomes a lifecycle sweep that runs once a day. Storage price per GB is irrelevant when the objects are 2 KB and the access pattern is 50 000 rps.

#### Answers 2

1. Isolation was violated (specifically the default `READ COMMITTED` level permits it); atomicity, consistency and durability were all honoured — each transaction was atomic, no constraint was broken, and both commits are durable. The anomaly is a **lost update**.
2. The application must now catch SQLSTATE `40001` (`serialization_failure`) and **retry the whole transaction**, from the first statement, because the snapshot it read is gone. That is a design decision because retry must be safe: the transaction body has to be idempotent or the retry has to re-read everything it computes from. You cannot bolt this on by changing a config flag in production and hoping.
3. `balance = balance - 100` re-reads the row's current value *inside the UPDATE*, under a row lock. At `READ COMMITTED`, when a concurrent transaction commits an update to that row, the blocked UPDATE re-evaluates its `WHERE` clause and its expression against the new row version. The value 900 in the broken version was computed by the *client* from a stale read, and the database has no way to know it was derived from data that has since changed.
4. `idle in transaction` holds locks and, worse, holds back the oldest transaction's snapshot: `VACUUM` cannot remove dead tuples newer than it, so table bloat grows across the whole database while that session sits there — a connection leak in one service degrades every other. The two settings are `idle_in_transaction_session_timeout` (kills the session) and `statement_timeout` (bounds any single statement); `log_min_duration_statement` gives you the evidence.
5. Roughly when the query returns more than a few percent of the table. Above that, random I/O through the index plus a heap fetch per row costs more than reading the table sequentially, and the planner correctly chooses the sequential scan. It is not a bug — it is the cost model working. It becomes a bug when the statistics are stale, which is why `ANALYZE` was run before `EXPLAIN`.
6. 40 × 20 = 800 requested connections against a ceiling of 100, so pods fail with `FATAL: sorry, too many clients already` — and raising `max_connections` is the wrong fix, because each PostgreSQL backend is a process with its own memory and the server degrades badly well before 800. Put a connection pooler in front — **PgBouncer** in transaction pooling mode (or `pgpool-II`), which multiplexes hundreds of client connections onto a few dozen server connections.

#### Answers 3

1. MongoDB's transaction and rollback machinery is built on the **oplog** and on majority read/write concerns, which only exist in a replica set; a standalone `mongod` has no oplog, so there is no mechanism to roll a multi-document commit forward or back consistently. The durability guarantee therefore lives in **replication**, not in a single node's write — which is exactly what `w: "majority"` expresses.
2. `rs.initiate()` registered the member as `mongo:27017`. A driver connects to the seed, receives the replica-set topology, and then connects to the members *by the names in that topology* — `mongo` does not resolve on your host. The fix is to use a name resolvable by all clients. It is the same reason a StatefulSet needs a headless Service: each replica must have a stable DNS name that is valid from wherever clients live.
3. `strict` applies the validator to **all inserts and all updates**, including updates of documents that were already invalid — so a legacy document without `price` can no longer be modified at all, even by an update that is unrelated to `price`. During a migration you use `validationLevel: "moderate"`, which applies the rules to inserts and to updates of *already-valid* documents, letting you fix the old ones progressively. `validationAction: "warn"` (log, don't reject) is the even softer first step.
4. Referential integrity across collections (there is no `FOREIGN KEY`, and no cascading behaviour) and cross-document/cross-row constraints such as `UNIQUE` across a combination that spans tables, `EXCLUDE` constraints, or a `CHECK` that compares to an aggregate. `$jsonSchema` validates one document in isolation; it cannot express a relationship between documents.
5. `w: 1` is right for a high-volume, low-value, regenerable collection — a click/telemetry log where losing the last few writes on a primary failover is acceptable and the write rate makes majority acknowledgement expensive. It is negligence on anything that represents money or an irreversible action: an order, a payment, a stock decrement. Losing a stock decrement on failover oversells the product.
6. The signal is **aggregate locality**: the entity is read and written as a whole, its nested structure varies legitimately per instance (the `specs` subdocument differs per product category), and you almost never need to join it to something else or query across instances on a field that not all of them have. The counter-signal is that you find yourself doing `$lookup` regularly, or that two clients disagree about what a field means — at that point you have a relational schema written in a document store, and PostgreSQL (with `jsonb` for the genuinely variable part) will serve you better.

#### Answers 4

1. `maxmemory-policy`. With `allkeys-lru` Redis silently discards keys under pressure, which is correct for a cache and catastrophic for a system of record. With `noeviction`, Redis stops accepting writes and returns `OOM command not allowed when used memory > 'maxmemory'` to every write while continuing to serve reads — your data survives but your application starts erroring, which is the right trade for a queue or a lock store and the wrong one for a cache.
2. `SETNX` then `EXPIRE` is two round trips: if the client crashes between them, the lock exists with no TTL and is held forever — the deadlock you were trying to avoid. `SET ... NX PX` is a single atomic command. The token matters at release time: you must delete the key **only if it still holds your token**, otherwise a worker whose lock expired mid-job will delete the lock that a second worker legitimately acquired. The release must be a Lua script doing compare-and-delete, since `GET` then `DEL` has the same race.
3. `MONITOR` streams every command processed by the server to your client, which can cost a large fraction of throughput on a busy instance (the documentation measures a ~50 % hit) and leaks every key and value, including session tokens, to whoever is watching. `DEBUG POPULATE` writes hundreds of thousands of keys into the live keyspace, which under `allkeys-lru` evicts your real working set and destroys the hit rate until it warms back up.
4. Below the threshold, a hash is stored as a `listpack` — a compact contiguous encoding with O(n) lookup over a handful of entries, which is faster and far smaller than a real hash table at that size. Past `hash-max-listpack-entries` (or `hash-max-listpack-value` for a long value), Redis converts it to a `hashtable`: lookups become O(1) but memory per field jumps several-fold, and the conversion is one-way for that key. Many small hashes are dramatically cheaper than one big one.
5. Everything since the last RDB snapshot is lost — and with `--appendonly no` plus no `save` points configured by the image's command line, potentially *everything* in memory, since `BGSAVE` only ran because you typed it. Sessions and the page-view counter are acceptable losses (users re-authenticate; metrics have gaps). The cart is not: losing it is a visible user-facing bug and a lost sale, so it belongs in a durable store with Redis used only as a read cache.
6. Per-message acknowledgement with redelivery (if a consumer dies mid-job, `BRPOP` has already removed the item and it is gone; AMQP requeues it), and routing/topology — one publish reaching several independent queues by binding, plus dead-lettering for poison messages. Redis Streams close part of this gap with consumer groups and `XACK`, but a plain list gives you neither.

#### Answers 5

1. The publish carried routing key `order.cancelled` to the `orders` topic exchange. The broker compared it to every binding: `order.created` did not match, `order.#` did (`#` matches zero or more dot-separated words). So one copy went to `audit` and none to `billing`. `order.*` matches exactly one word, so it would have matched `order.cancelled` too but **not** a three-word key like `order.payment.failed`, which `order.#` does match.
2. **Publisher confirms** (`confirm.select`), which tell the producer the broker took responsibility for the message, and the **mandatory** flag, which makes the broker return an unroutable message to the producer via `basic.return` instead of dropping it. Confirms alone do not help here: a message that is confirmed but unroutable is confirmed as successfully *discarded*.
3. A queue's arguments are part of its identity, and redeclaring an existing queue with different arguments is an error rather than a mutation. It is a good error because the alternative — silently accepting the new arguments, or silently ignoring them — means two services that declare the same queue with different TTLs or DLX settings would fight, and which one wins would depend on restart order. Loud failure at declare time is far better than a queue whose behaviour depends on who started last.
4. `""` is the **default exchange**, a direct exchange to which every queue is automatically bound using its own name as the routing key. Dead-lettering to it therefore requires `x-dead-letter-routing-key` to be exactly the destination queue's name — there is no other binding to match. Using a named DLX with explicit bindings is the more maintainable pattern once you have more than one DLQ.
5. The exchange must be durable, the queue must be durable, and the message must be published as persistent (`delivery_mode: 2`). Missing any one of the three loses the message on restart — which is why the `transient` message in step 5.7 disappeared and the `persistent` one did not. (Even then, a message can be lost in the window between accept and disk flush unless you use publisher confirms and quorum queues.)
6. By default the **oldest** message at the head of the queue is dropped to make room — `x-overflow: drop-head`. The alternative is `x-overflow: reject-publish`, which refuses new messages and, with publisher confirms, tells the producer with a `basic.nack` so it can apply backpressure instead of losing history silently.

#### Answers 6

1. The producer hashes the record key (murmur2 by default) modulo the partition count, so the same key always lands on the same partition — and Kafka guarantees order **within a partition**. Across `cust-1` and `cust-2` you have **no ordering guarantee at all**: they are on different partitions and are consumed independently and concurrently. Ordering in Kafka is per key, by construction.
2. Three do useful work; two sit idle. A partition is assigned to at most one consumer in a group, so the group's parallelism is capped by the partition count. This is why partition count is a capacity decision made up front — you can increase it later, but doing so changes the key-to-partition mapping and breaks per-key ordering across the change.
3. In the `__consumer_offsets` internal topic, as a committed offset per (group, topic, partition) — it is a bookmark, not a deletion. RabbitMQ's ack removes the message from the queue: the state is in the broker's queue contents and is consumed destructively, so a second reader cannot get it. Kafka's data is immutable and shared; the consumer owns its position, which is exactly what makes replay and multiple independent consumers possible.
4. Once a segment is older than `retention.ms`, the broker deletes it regardless of who has read it. A consumer whose committed offset points into a deleted segment gets `OffsetOutOfRangeException`, and then behaves according to `auto.offset.reset` — silently jumping to `latest` (skipping all the unread data with no error anyone notices) or re-reading from `earliest` (reprocessing everything). Monitoring **consumer lag** against retention is what prevents this.
5. It can be used as a **changelog / state snapshot** that a new service instance replays from offset 0 to rebuild the full current state of every customer — a materialised view, or a Kafka Streams `KTable`. A record with a `null` value is a **tombstone**: it marks the key as deleted, and after `delete.retention.ms` the compactor removes both the tombstone and all prior records for that key.
6. `advertised.listeners`. A client first connects to a bootstrap server and asks for cluster metadata; the broker answers with the *advertised* address of the leader for each partition, and the client then opens a **second** connection to that address to produce or fetch. If the advertised address is `localhost:9092` and the client is on the host, the bootstrap succeeds and the second connection goes to the wrong place. You must advertise an address reachable by the client — typically two listeners, one internal and one external, via `listener.security.protocol.map`.

#### Answers 7

1. Lazy evaluation: transformations build a logical plan and return immediately; only an **action** triggers execution. The actions were `events.write...csv(...)` in 7.2, and `df.count()` and `.show()` in 7.3. `.explain()` compiles the plan without running it, so it is not an action either.
2. At that line every executor writes its partial results to local disk, partitioned by the hash of `country`, and every other executor reads across the network the pieces belonging to it — an all-to-all data movement. It is expensive because it serialises, writes to disk, and crosses the network for potentially the whole dataset, and it is a hard stage boundary, so nothing downstream starts until it completes. 200 is the default of `spark.sql.shuffle.partitions` — a fixed number that is wrong for both small and huge datasets, which is why Adaptive Query Execution (`AdaptiveSparkPlan` in the output) coalesces it at runtime.
3. Parquet is **columnar with per-column-chunk statistics and encoding**. Columnar layout means values of one type sit together, so run-length and dictionary encoding plus compression shrink it dramatically — the size win. The same layout means the reader can skip whole columns it does not need and skip row groups whose min/max statistics exclude the filter — the pushdown win. CSV is row-oriented, untyped text with no statistics, so every query must read and parse every byte.
4. With ~10 000 distinct `user_id` values you would create ~10 000 directories, each holding tiny files — the **small files problem**. Listing the dataset becomes thousands of metadata operations (brutally slow on object storage, where LIST is an HTTP request), each file carries Parquet footer overhead that dwarfs its content, and the scheduler creates a task per file. Partition on a low-cardinality column you actually filter on — `country`, or a date.
5. `inferSchema` reads the data an extra time before the real job just to guess types, doubling the I/O on every run; worse, the guess can change between runs when the data changes, so a column silently becomes a string and downstream arithmetic breaks. In production you declare an explicit `StructType` (or read a format that carries its own schema, like Parquet or Avro with a schema registry).
6. **Driver** (runs your program, builds the plan, schedules tasks), **cluster manager** (YARN, Kubernetes, or Spark standalone — allocates resources), and **executors** (run tasks and hold cached data). In `local[*]` mode your single `pyspark` process is the driver *and* the executors, with threads standing in for the cluster; that is why nothing needed to be deployed and why the results here say nothing about how the job will behave distributed.
7. Spark here processed a **bounded** dataset in batch; Flink is designed for **unbounded** streams with event-time semantics, watermarks for out-of-order events, and continuous stateful operators — latency measured in milliseconds rather than per-batch. The component that feeds it is **Kafka** from Exercise 6: the log is the stream source, and offsets are what lets Flink checkpoint and recover exactly-once.

#### Answers 8

1. The rule: is there a human at the keyboard whose identity and consent matter? If yes, the client acts *on behalf of a user* and uses the authorization code flow; if no, the client acts *as itself* and uses `client_credentials`. `portal-ui` has no secret because it is a public client — its code runs in the browser, where any "secret" is readable by the user and by anyone with the bundle, so the protocol does not pretend otherwise and relies on PKCE plus exact redirect-URI matching instead.
2. **Authorization code interception.** On a mobile or SPA client, the code arrives via a redirect that a malicious app registered for the same custom scheme, or via a leaked log/referrer, can observe. Without PKCE the attacker replays the code at the token endpoint and gets the tokens. With PKCE the code is bound to the SHA-256 of a random `code_verifier` the legitimate client never transmitted until the exchange; the attacker has the code and the challenge but not the verifier, so the exchange fails with `invalid_grant`.
3. Decoding is not verification — the payload is base64url, not encrypted, and anyone can forge one by editing claims and re-encoding, including setting `"alg": "none"`. A resource server must verify: (i) the **signature**, against the key identified by `kid` fetched from JWKS, with the algorithm pinned to what it expects; (ii) the **issuer** `iss` matches the expected authorization server; (iii) the **audience** `aud` includes this API; (iv) the **time** claims `exp` and `nbf`/`iat` are currently valid. Scope/role checks come after all four.
4. JWKS verification is local and stateless: no network call per request, microsecond latency, but the token remains valid until `exp` even if it has been revoked. Introspection asks the authorization server on every request: instant revocation and central policy, at the cost of a network round trip and a hard dependency on the AS's availability. Use local JWT verification with short-lived tokens for the 10 000 rps API; use introspection (or at minimum a revocation check) for the banking transfer endpoint, where a stolen token being valid for the next 5 minutes is not acceptable.
5. Send the **access token** to `orders-api`. The **ID token** must never be sent to an API as a credential — it is proof of authentication issued *to the client*, and its `aud` is the client ID, not the API. That is exactly the `aud` claim's role: it names the intended recipient, and an API that accepts a token whose `aud` is some other party is accepting a credential minted for a different purpose — the classic confused-deputy vulnerability.
6. Code replay / interception (RFC 6749 §10.5 and the Security BCP). Beyond rejecting the second exchange, a correct authorization server must **revoke all tokens already issued for that code**, because a second presentation means either the client or an attacker has replayed it and the server cannot tell which one was legitimate.
7. TLS everywhere with an `https://` issuer (tokens and codes travel in the clear otherwise, and PKCE does not save you from that); real secrets — not `admin/admin` and not a secret hard-coded in a Compose file — sourced from a secret manager, with client secrets rotatable; and a production-mode Keycloak: `start` rather than `start-dev`, backed by an external database with replicas rather than the dev in-memory store, behind a hostname that is configured, resolvable and identical for every client.

#### Answers 9

1. (a) **Relational database with ACID transactions** — PostgreSQL, with the seat row locked `FOR UPDATE` or protected by a unique constraint on `(event_id, seat_id)` in the `sold` table. (b) **Message log** — Apache Kafka, topic `purchases`, one consumer group per consumer. (c) **Object storage** — S3 or MinIO, versioned, with object lock in `COMPLIANCE` mode and a seven-year lifecycle policy. (d) **Big data / analytical platform** — Parquet on object storage processed by Spark, or a columnar warehouse; fed from the same Kafka topic. (e) **OAuth 2.0 / OpenID Connect** — Keycloak: `client_credentials` for box offices, authorization code + PKCE for the web app. (f) **Key/value cache** — Redis, holding the serialised seat map per event.
2. Not Redis, and not MongoDB in a single-node configuration. The lost-update demonstration in Exercise 2 is exactly the double-sell: two requests read "seat free", both write "seat sold", both succeed. Redis can express a correct lock (`SET NX PX`), but the authoritative record of a sale must be in a store with durable, constraint-enforced transactions — and Exercise 4 showed that instance happily evicting a quarter of a million keys under memory pressure, which is precisely what happens during a 40× spike.
3. "Adding a fourth consumer later must not require touching the purchase code" is the deciding clause, and both technologies satisfy it in principle — a topic exchange lets you bind a new queue without changing the producer. The log wins on the rest: each consumer keeps its own offset, so a new fraud model can be added and **replayed over the last two years of purchases** to backfill its state, which a broker cannot do because its messages were consumed destructively. It also gives you (d) for free from the same topic.
4. The transactional store is tuned for many small, latency-critical, highly concurrent writes; an hourly aggregation over two years scans millions of rows, evicts the buffer cache the sale path depends on, and holds long snapshots that block `VACUUM` (Exercise 2, question 4). During the on-sale spike those two workloads are competing for the resource that must not fail. Separate them: stream the purchases into columnar storage and let analysts hit that.
5. `client_credentials` for the partner box offices (a machine acting as itself, no user, no ID token) and authorization code with PKCE for the end-user web app. Only the second gets an **ID token**, because only it authenticated a human.
6. Cache-aside with an explicit invalidation on write: the purchase transaction commits to PostgreSQL, then deletes or updates the `seatmap:<event>` key, plus a short TTL as a safety net against a missed invalidation. If the cache is lost entirely during the spike, **correctness is unaffected** — the seat map is derived data, and every read falls through to PostgreSQL. What is affected is availability: the fallthrough is a thundering herd of thousands of identical queries per second against the database, so the read path needs request coalescing (single-flight) or a stale-while-revalidate policy. That asymmetry — losing a cache costs performance, losing the system of record costs money — is what makes (a) and (f) different components.

</details>

---

## Sources

- LPI, *Exam 701-100 Objectives (DevOps Tools Engineer, v2.0.0)* — https://www.lpi.org/our-certifications/exam-701-objectives/
- MinIO, *MinIO Object Storage Documentation* — https://min.io/docs/minio/linux/index.html
- AWS, *Amazon S3 User Guide* — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- PostgreSQL Global Development Group, *Transaction Isolation* — https://www.postgresql.org/docs/16/transaction-iso.html
- PostgreSQL Global Development Group, *Using EXPLAIN* — https://www.postgresql.org/docs/16/using-explain.html
- MongoDB, *Schema Validation* — https://www.mongodb.com/docs/manual/core/schema-validation/
- MongoDB, *Transactions* — https://www.mongodb.com/docs/manual/core/transactions/
- Redis, *Key eviction* — https://redis.io/docs/latest/develop/reference/eviction/
- Redis, *Distributed Locks with Redis* — https://redis.io/docs/latest/develop/use/patterns/distributed-locks/
- RabbitMQ, *AMQP 0-9-1 Model Explained* — https://www.rabbitmq.com/tutorials/amqp-concepts
- RabbitMQ, *Dead Letter Exchanges* — https://www.rabbitmq.com/docs/dlx
- Apache Kafka, *Design* and *Log Compaction* — https://kafka.apache.org/documentation/#design
- Apache Spark, *Spark SQL, DataFrames and Datasets Guide* — https://spark.apache.org/docs/latest/sql-programming-guide.html
- IETF, *RFC 6749 — The OAuth 2.0 Authorization Framework* — https://datatracker.ietf.org/doc/html/rfc6749
- IETF, *RFC 7636 — Proof Key for Code Exchange* — https://datatracker.ietf.org/doc/html/rfc7636
- IETF, *RFC 7519 — JSON Web Token* — https://datatracker.ietf.org/doc/html/rfc7519
- IETF, *RFC 7662 — OAuth 2.0 Token Introspection* — https://datatracker.ietf.org/doc/html/rfc7662
- OpenID Foundation, *OpenID Connect Core 1.0* — https://openid.net/specs/openid-connect-core-1_0.html
- Keycloak, *Server Administration Guide* — https://www.keycloak.org/documentation