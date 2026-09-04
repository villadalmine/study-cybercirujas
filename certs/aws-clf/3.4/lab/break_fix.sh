#!/usr/bin/env bash
# =============================================================================
#  AWS Certified Cloud Practitioner — CLF-C02 (syllabus version 1.0)
#  Domain 3: Cloud Technology and Services
#  Task statement 3.4 — Identify AWS database services   (exam weight: 4.25%)
#
#  LAB: "ShopFast" — break & fix on a disposable lab VM
#  Level: production-grade diagnosis, foundational-exam scope
#
#  Reference sources (official):
#    - CLF-C02 Exam Guide
#      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#    - Amazon RDS read replicas (read-only by design)
#      https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html
#    - Aurora writer vs reader endpoints
#      https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html
#    - DynamoDB core components / primary key
#      https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.CoreComponents.html
#    - DynamoDB local (containerized, no AWS account, no cost)
#      https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.DownloadingAndRunning.html
#    - ElastiCache parameter groups / maxmemory-policy
#      https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/ParameterGroups.Redis.html
#    - ElastiCache memory management (reserved-memory-percent)
#      https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/redis-memory-management.html
#
# -----------------------------------------------------------------------------
#  WHY A LOCAL LAB, AND WHAT IS BEING SIMULATED
# -----------------------------------------------------------------------------
#  This lab spends ZERO dollars and never touches a real AWS account. Every AWS
#  managed database service is represented by the same engine AWS runs under the
#  hood, in a throwaway container:
#
#     Amazon RDS for PostgreSQL / Aurora  ->  postgres:16-alpine   (2 instances:
#                                             a "writer" and a read-only
#                                             "reader" endpoint)
#     Amazon DynamoDB                     ->  amazon/dynamodb-local (real
#                                             DynamoDB API, real ValidationException
#                                             semantics, driven by the real aws CLI)
#     Amazon ElastiCache (Valkey/Redis OSS) -> redis:7-alpine
#
#  Fidelity caveats — say these out loud, they are exam-relevant:
#    * The "reader" here is a stand-alone instance forced read-only. On a REAL
#      RDS read replica or Aurora reader endpoint, pg_is_in_recovery() returns
#      true; here it returns false. The client-visible symptom (writes rejected,
#      reads fine) is identical, and that symptom is the lesson.
#    * ElastiCache does NOT let you set `maxmemory` (AWS manages it from the node
#      class and reserved-memory-percent). It DOES let you set `maxmemory-policy`
#      through a custom parameter group. Here we set both, to make the failure
#      reproducible in seconds.
#    * DynamoDB Local implements the control/data plane API but not IAM, not
#      capacity throttling, and not multi-AZ durability.
#
# -----------------------------------------------------------------------------
#  THE AWS DATABASE SERVICE MAP YOU ARE BEING EXAMINED ON (task 3.4)
# -----------------------------------------------------------------------------
#   Relational (SQL, joins, ACID, fixed schema, vertical-first scaling):
#     Amazon RDS         - managed MySQL/PostgreSQL/MariaDB/Oracle/SQL Server/Db2
#     Amazon Aurora      - AWS-built MySQL/PostgreSQL-compatible engine; storage
#                          layer spans 3 AZs with 6 copies; Aurora Serverless v2
#                          scales capacity in fine-grained ACUs
#   Key-value / document (NoSQL, single-digit ms, horizontal scaling):
#     Amazon DynamoDB    - serverless key-value; partition key chosen at CREATE
#                          time and IMMUTABLE; on-demand or provisioned capacity;
#                          DAX = microsecond in-memory cache in front of it
#     Amazon DocumentDB  - MongoDB-compatible document database
#   In-memory:
#     Amazon ElastiCache - cache aside/lazy loading; data is disposable
#     Amazon MemoryDB    - durable, multi-AZ transaction log; a PRIMARY database,
#                          not a cache — this is the distinction the exam probes
#   Purpose-built:
#     Amazon Neptune     - graph               Amazon Timestream - time series
#     Amazon Keyspaces   - Cassandra-compatible  Amazon Redshift - data warehouse
#                                                                  (OLAP, not OLTP)
#   Migration:
#     AWS DMS            - homogeneous & heterogeneous migrations (with SCT)
#   Retired: AWS announced end of support for Amazon QLDB on 2025-07-31. Do not
#            design new workloads on it; it may still appear in stale question banks.
#
# -----------------------------------------------------------------------------
#  SAFETY CONTRACT
# -----------------------------------------------------------------------------
#   * Run this ONLY on a disposable lab VM. It creates containers, a container
#     network, and files under /opt/shopfast. It removes exactly those, by name.
#   * It NEVER calls a real AWS endpoint: every aws CLI invocation is pinned with
#     --endpoint-url to the local DynamoDB, credentials are dummy strings, and
#     the EC2 instance-metadata credential path is disabled.
#   * Nothing in your $HOME, /etc, or any other container is modified.
#
#  PREREQUISITES
#     docker (or podman), ~1.5 GB free disk, internet access for the first pull,
#     TCP ports 55432 / 55433 / 56379 / 58000 free on the host.
#
#  USAGE
#     ./break-fix-3-4-databases.sh              # provision, prove healthy, break
#     ./break-fix-3-4-databases.sh run          # run the app, see the symptoms
#     ./break-fix-3-4-databases.sh verify       # grade your fix (3 objectives)
#     ./break-fix-3-4-databases.sh hint 1|2|3   # graduated hints, no spoilers
#     ./break-fix-3-4-databases.sh cleanup      # remove every lab artifact
#
#  The step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until you have burned at least 30 minutes on your own.
# =============================================================================

set -euo pipefail

readonly LAB_HOME="${LAB_HOME:-/opt/shopfast}"
readonly NET="shopfast-vpc"
readonly RDS_WRITER="shopfast-rds-writer"
readonly RDS_READER="shopfast-rds-reader"
readonly CACHE="shopfast-elasticache"
readonly DDB="shopfast-dynamodb"
readonly PG_IMAGE="postgres:16-alpine"
readonly REDIS_IMAGE="redis:7-alpine"
readonly DDB_IMAGE="amazon/dynamodb-local:latest"
readonly AWSCLI_IMAGE="amazon/aws-cli:latest"
readonly DB_USER="shopfast"
readonly DB_PASS="LabOnly-NotASecret"
readonly DB_NAME="shopfast"
readonly DDB_TABLE="ShopFast-Sessions"

# Every container this script is ever allowed to touch. cleanup() iterates this
# list and nothing else, so an unrelated container can never be destroyed.
readonly LAB_CONTAINERS=("$RDS_WRITER" "$RDS_READER" "$CACHE" "$DDB")

# Hard guard: the aws CLI in this lab must be unable to reach a real account.
export AWS_ACCESS_KEY_ID="labaccesskey"
export AWS_SECRET_ACCESS_KEY="labsecretkey"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_EC2_METADATA_DISABLED="true"
unset AWS_PROFILE AWS_SESSION_TOKEN 2>/dev/null || true

CTR=""

c_red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_yell()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
rule()    { printf '%s\n' "-----------------------------------------------------------------------"; }
die()     { c_red "FATAL: $*"; exit 1; }

detect_runtime() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CTR="docker"
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    CTR="podman"
  else
    die "No usable container runtime. Install docker or podman, and make sure your user can talk to it."
  fi
  c_blue "[i] container runtime: $CTR"
}

confirm_disposable_vm() {
  if [ "${SHOPFAST_LAB_CONFIRM:-}" = "yes" ]; then return 0; fi
  rule
  c_yell "This script provisions containers and then DELIBERATELY BREAKS them."
  c_yell "Host: $(hostname)   Lab dir: $LAB_HOME"
  c_yell "Run it only on a disposable lab VM."
  rule
  printf 'Type BREAK-MY-LAB to continue: '
  read -r answer
  [ "$answer" = "BREAK-MY-LAB" ] || die "Not confirmed. Nothing was changed."
}

pull_images() {
  c_blue "[i] pulling lab images (first run only)"
  for img in "$PG_IMAGE" "$REDIS_IMAGE" "$DDB_IMAGE" "$AWSCLI_IMAGE"; do
    $CTR image inspect "$img" >/dev/null 2>&1 || $CTR pull "$img"
  done
}

# --- thin clients: everything runs INSIDE the lab network, so the endpoints the
# --- application uses are DNS names, exactly like an RDS/ElastiCache endpoint.
psql_q() { # psql_q <endpoint-host> <sql>
  $CTR run --rm --network "$NET" -e PGPASSWORD="$DB_PASS" "$PG_IMAGE" \
    psql -h "$1" -p 5432 -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tAc "$2" 2>&1
}
redis_q() { # redis_q <args...>
  $CTR run --rm --network "$NET" "$REDIS_IMAGE" redis-cli -h "$CACHE" -p 6379 "$@" 2>&1
}
awsddb() { # awsddb <aws dynamodb args...>
  $CTR run --rm --network "$NET" \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    "$AWSCLI_IMAGE" dynamodb "$@" --endpoint-url "http://${DDB}:8000" 2>&1
}

wait_for() { # wait_for <description> <max-seconds> <command...>
  local desc="$1" max="$2"; shift 2
  local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge "$max" ] && die "timed out waiting for $desc"
    sleep 1
  done
  c_blue "[i] $desc is ready"
}

# =============================================================================
#  PROVISION
# =============================================================================
setup() {
  pull_images
  c_blue "[i] tearing down any previous run (idempotent)"
  remove_containers

  $CTR network inspect "$NET" >/dev/null 2>&1 || $CTR network create "$NET" >/dev/null
  c_blue "[i] network '$NET' ready (this is your simulated VPC)"

  # --- Amazon RDS / Aurora simulation: two endpoints, writer and reader --------
  $CTR run -d --name "$RDS_WRITER" --network "$NET" -p 55432:5432 \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB="$DB_NAME" \
    "$PG_IMAGE" >/dev/null
  $CTR run -d --name "$RDS_READER" --network "$NET" -p 55433:5432 \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB="$DB_NAME" \
    "$PG_IMAGE" >/dev/null

  # --- Amazon ElastiCache simulation ------------------------------------------
  $CTR run -d --name "$CACHE" --network "$NET" -p 56379:6379 "$REDIS_IMAGE" >/dev/null

  # --- Amazon DynamoDB simulation ---------------------------------------------
  # -sharedDb keeps every credential/region pair pointed at the same table set;
  # without it, a different fake access key silently gives you an empty namespace.
  $CTR run -d --name "$DDB" --network "$NET" -p 58000:8000 \
    "$DDB_IMAGE" -jar DynamoDBLocal.jar -inMemory -sharedDb >/dev/null

  wait_for "$RDS_WRITER" 60 $CTR exec "$RDS_WRITER" pg_isready -U "$DB_USER" -d "$DB_NAME"
  wait_for "$RDS_READER" 60 $CTR exec "$RDS_READER" pg_isready -U "$DB_USER" -d "$DB_NAME"
  wait_for "$CACHE"      60 $CTR exec "$CACHE" redis-cli ping
  sleep 2
  wait_for "$DDB"        60 bash -c "$CTR run --rm --network $NET -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION $AWSCLI_IMAGE dynamodb list-tables --endpoint-url http://${DDB}:8000"

  # --- schema + seed on BOTH instances (the reader is seeded before it is
  # --- flipped read-only; a real replica would receive this through replication)
  local ddl="CREATE SCHEMA IF NOT EXISTS catalog;
             CREATE TABLE IF NOT EXISTS catalog.orders (
               order_id    bigserial PRIMARY KEY,
               customer_id integer      NOT NULL,
               sku         text         NOT NULL,
               amount_usd  numeric(9,2) NOT NULL,
               created_at  timestamptz  NOT NULL DEFAULT now());
             INSERT INTO catalog.orders (customer_id, sku, amount_usd)
               SELECT g, 'SKU-' || lpad(g::text, 5, '0'), (g * 3.25)
               FROM generate_series(1, 25) g
               WHERE NOT EXISTS (SELECT 1 FROM catalog.orders);"
  psql_q "$RDS_WRITER" "$ddl" >/dev/null
  psql_q "$RDS_READER" "$ddl" >/dev/null

  # The reader endpoint is read-only, exactly like an RDS read replica or the
  # Aurora reader endpoint. Set AFTER seeding, then reloaded without a restart.
  psql_q "$RDS_READER" "ALTER SYSTEM SET default_transaction_read_only = on;" >/dev/null
  psql_q "$RDS_READER" "SELECT pg_reload_conf();" >/dev/null

  # --- DynamoDB table, correct key schema (the healthy baseline) --------------
  awsddb delete-table --table-name "$DDB_TABLE" >/dev/null 2>&1 || true
  awsddb create-table --table-name "$DDB_TABLE" \
    --attribute-definitions AttributeName=SessionId,AttributeType=S \
    --key-schema AttributeName=SessionId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null

  write_app
  write_env "$RDS_WRITER"

  rule
  c_blue "[i] baseline health check — the platform BEFORE anything is broken"
  rule
  if bash "$LAB_HOME/app.sh"; then
    c_green "[OK] baseline is healthy. This is the state you must restore."
  else
    die "baseline did not come up clean; run cleanup and try again"
  fi
}

write_env() { # write_env <rds-endpoint-host>
  mkdir -p "$LAB_HOME"
  cat > "$LAB_HOME/app.env" <<ENVEOF
# ShopFast runtime configuration.
# These are the service ENDPOINTS the application connects to, the same way an
# application reads an RDS endpoint, an ElastiCache configuration endpoint and a
# DynamoDB table name from its environment / Parameter Store.
#
# You MAY edit this file. You may NOT edit app.sh — treat it as vendor code
# under change control.
CONTAINER_CLI=$CTR
NET=$NET

RDS_ENDPOINT_HOST=$1
RDS_ENDPOINT_PORT=5432
RDS_DB_NAME=$DB_NAME
RDS_DB_USER=$DB_USER
RDS_DB_PASS=$DB_PASS

CACHE_ENDPOINT_HOST=$CACHE
CACHE_ENDPOINT_PORT=6379
CACHE_WARM_PAGES=200

DDB_ENDPOINT=http://${DDB}:8000
DDB_TABLE=$DDB_TABLE

PG_IMAGE=$PG_IMAGE
REDIS_IMAGE=$REDIS_IMAGE
AWSCLI_IMAGE=$AWSCLI_IMAGE
ENVEOF
}

write_app() {
  mkdir -p "$LAB_HOME"
  cat > "$LAB_HOME/app.sh" <<'APPEOF'
#!/usr/bin/env bash
# ShopFast catalog service - synthetic transaction.
# VENDOR CODE. Do not modify. If it fails, the platform is wrong, not the app.
set -uo pipefail
# shellcheck disable=SC1091
source /opt/shopfast/app.env

export AWS_ACCESS_KEY_ID="labaccesskey"
export AWS_SECRET_ACCESS_KEY="labsecretkey"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_EC2_METADATA_DISABLED="true"

CTR="$CONTAINER_CLI"
RC=0
ok()   { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; RC=1; }
head_() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- phase 1: RDS
head_ "PHASE 1 - Amazon RDS for PostgreSQL (relational, OLTP)"
READ_OUT=$($CTR run --rm --network "$NET" -e PGPASSWORD="$RDS_DB_PASS" "$PG_IMAGE" \
  psql -h "$RDS_ENDPOINT_HOST" -p "$RDS_ENDPOINT_PORT" -U "$RDS_DB_USER" -d "$RDS_DB_NAME" \
  -v ON_ERROR_STOP=1 -tAc "SELECT count(*) FROM catalog.orders;" 2>&1)
if printf '%s' "$READ_OUT" | grep -Eq '^[0-9]+$'; then
  ok "read path: SELECT count(*) FROM catalog.orders -> $READ_OUT rows"
else
  bad "read path: $READ_OUT"
fi

WRITE_OUT=$($CTR run --rm --network "$NET" -e PGPASSWORD="$RDS_DB_PASS" "$PG_IMAGE" \
  psql -h "$RDS_ENDPOINT_HOST" -p "$RDS_ENDPOINT_PORT" -U "$RDS_DB_USER" -d "$RDS_DB_NAME" \
  -v ON_ERROR_STOP=1 -tAc \
  "INSERT INTO catalog.orders (customer_id, sku, amount_usd)
   VALUES (9001, 'SKU-CHECKOUT', 42.00) RETURNING order_id;" 2>&1)
if printf '%s' "$WRITE_OUT" | grep -Eq '^[0-9]+$'; then
  ok "write path: checkout INSERT committed, order_id=$WRITE_OUT"
else
  bad "write path: $(printf '%s' "$WRITE_OUT" | tr '\n' ' ')"
fi

# ----------------------------------------------------------- phase 2: DynamoDB
head_ "PHASE 2 - Amazon DynamoDB (key-value, session state)"
SID="sess-$$-$(date +%s)"
PUT_OUT=$($CTR run --rm --network "$NET" \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION -e AWS_EC2_METADATA_DISABLED \
  "$AWSCLI_IMAGE" dynamodb put-item --table-name "$DDB_TABLE" \
  --item "{\"SessionId\":{\"S\":\"$SID\"},\"UserId\":{\"N\":\"9001\"},\"CartItems\":{\"N\":\"3\"}}" \
  --endpoint-url "$DDB_ENDPOINT" 2>&1)
if [ -z "$PUT_OUT" ]; then
  ok "PutItem SessionId=$SID"
  GET_OUT=$($CTR run --rm --network "$NET" \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION -e AWS_EC2_METADATA_DISABLED \
    "$AWSCLI_IMAGE" dynamodb get-item --table-name "$DDB_TABLE" \
    --key "{\"SessionId\":{\"S\":\"$SID\"}}" --consistent-read \
    --endpoint-url "$DDB_ENDPOINT" 2>&1)
  if printf '%s' "$GET_OUT" | grep -q '"CartItems"'; then
    ok "GetItem (strongly consistent) returned the session item"
  else
    bad "GetItem: $(printf '%s' "$GET_OUT" | tr '\n' ' ')"
  fi
else
  bad "PutItem: $(printf '%s' "$PUT_OUT" | tr '\n' ' ')"
fi

# -------------------------------------------------------- phase 3: ElastiCache
head_ "PHASE 3 - Amazon ElastiCache (in-memory cache warm-up)"
CACHE_OUT=$($CTR run --rm --network "$NET" "$REDIS_IMAGE" sh -c "
  V=\$(head -c 32768 /dev/zero | tr '\0' 'x')
  redis-cli -h $CACHE_ENDPOINT_HOST -p $CACHE_ENDPOINT_PORT flushall >/dev/null 2>&1
  i=1
  while [ \$i -le $CACHE_WARM_PAGES ]; do
    R=\$(redis-cli -h $CACHE_ENDPOINT_HOST -p $CACHE_ENDPOINT_PORT \
        set shopfast:catalog:page:\$i \"\$V\" 2>&1)
    if [ \"\$R\" != \"OK\" ]; then
      echo \"cache write failed at page \$i: \$R\"; exit 1
    fi
    i=\$((i + 1))
  done
  echo WARMED
" 2>&1)
if printf '%s' "$CACHE_OUT" | grep -q 'WARMED'; then
  ok "warmed $CACHE_WARM_PAGES catalog pages (32 KiB each) into the cache"
else
  bad "$(printf '%s' "$CACHE_OUT" | tr '\n' ' ')"
fi

printf '\n'
if [ "$RC" -eq 0 ]; then
  printf '\033[1;32mShopFast synthetic transaction: HEALTHY\033[0m\n'
else
  printf '\033[1;31mShopFast synthetic transaction: DEGRADED\033[0m\n'
fi
exit "$RC"
APPEOF
  chmod +x "$LAB_HOME/app.sh"
}

remove_containers() {
  for c in "${LAB_CONTAINERS[@]}"; do
    $CTR rm -f "$c" >/dev/null 2>&1 || true
  done
}

# =============================================================================
#  BREAK — three faults, three different diagnostic techniques
# =============================================================================
break_it() {
  c_blue "[i] injecting faults..."

  # FAULT 1 — endpoint mix-up. The deploy pipeline wrote the READ-ONLY endpoint
  # into the app config. Reads keep working; only writes are rejected. This is
  # the classic Aurora reader-endpoint-in-production incident.
  write_env "$RDS_READER"

  # FAULT 2 — DynamoDB table re-created by a "hotfix" with the wrong partition
  # key casing. The key schema of a DynamoDB table is immutable, so this is not
  # something you patch in place.
  awsddb delete-table --table-name "$DDB_TABLE" >/dev/null 2>&1 || true
  sleep 1
  awsddb create-table --table-name "$DDB_TABLE" \
    --attribute-definitions AttributeName=sessionId,AttributeType=S \
    --key-schema AttributeName=sessionId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null

  # FAULT 3 — cache node configured with a tiny memory ceiling and an eviction
  # policy that refuses to evict. A cache that cannot evict stops accepting
  # writes the moment it fills.
  redis_q flushall >/dev/null
  redis_q config set maxmemory 3mb >/dev/null
  redis_q config set maxmemory-policy noeviction >/dev/null

  print_ticket
}

print_ticket() {
  cat <<'TICKET'

=======================================================================
 INCIDENT SEV-2 / OPS-4471 — "ShopFast checkout is half-broken"
=======================================================================
 Reported by: on-call SRE, 03:12 UTC
 Blast radius: checkout, session persistence, catalog page latency

 WHAT THE BUSINESS SEES
   * The storefront still renders. Product listings load. Nothing is "down".
   * Customers can browse, but the checkout button fails for everyone.
   * Users get logged out at random; the cart empties itself.
   * Page latency climbed and stayed high after the last deploy.

 WHAT YOU WILL SEE WHEN YOU RUN THE SYNTHETIC TRANSACTION
   $ bash /opt/shopfast/app.sh

   PHASE 1 - Amazon RDS
     [PASS] read path: SELECT count(*) FROM catalog.orders -> 25 rows
     [FAIL] write path: ERROR:  cannot execute INSERT in a read-only transaction
            ^ reads fine, writes refused. The database is up. Think about WHICH
              endpoint of a relational service accepts writes, and which one
              never will, by design.

   PHASE 2 - Amazon DynamoDB
     [FAIL] PutItem: An error occurred (ValidationException) ...
            One or more parameter values were invalid: Missing the key
            sessionId in the item
            ^ the application sends the attribute it has always sent. Read the
              error slowly: which name does the TABLE expect, and which does the
              APP send? Then ask yourself the exam question — can a DynamoDB
              table's partition key be altered after creation?

   PHASE 3 - Amazon ElastiCache
     [FAIL] cache write failed at page ~96: OOM command not allowed when used
            memory > 'maxmemory'.
            ^ a CACHE returning out-of-memory is a configuration statement, not
              a capacity accident. What is a cache supposed to do when it is
              full? Which parameter decides that?

 YOUR OBJECTIVE (definition of done)
   All three phases PASS, and:
     bash /opt/shopfast/app.sh   -> exit 0, "HEALTHY"
     ./break-fix-3-4-databases.sh verify -> 3/3 objectives met

 RULES OF ENGAGEMENT
   * /opt/shopfast/app.sh is vendor code. Do NOT edit it. Fix the platform.
   * /opt/shopfast/app.env is your configuration. You may edit it.
   * Do not destroy and re-provision the whole lab; diagnose it.
   * No data loss is acceptable in catalog.orders. Check the row count before
     and after: the 25 seeded rows must still be there when you are done.

 STARTING POINTS
   ./break-fix-3-4-databases.sh hint 1     (RDS)
   ./break-fix-3-4-databases.sh hint 2     (DynamoDB)
   ./break-fix-3-4-databases.sh hint 3     (ElastiCache)

 Host-published ports, if you prefer your own psql/redis-cli/aws CLI:
   RDS writer 127.0.0.1:55432   RDS reader 127.0.0.1:55433
   ElastiCache 127.0.0.1:56379  DynamoDB  http://127.0.0.1:58000
=======================================================================

TICKET
}

# =============================================================================
#  HINTS
# =============================================================================
hint() {
  case "${1:-0}" in
    1) cat <<'H1'
HINT 1 - Amazon RDS / Aurora
  a) An RDS read replica and the Aurora *reader* endpoint accept SELECT and
     reject every INSERT/UPDATE/DELETE. That is not a bug, it is the product.
  b) Ask the server what it thinks it is:
       psql ... -c "SHOW default_transaction_read_only;"
       psql ... -c "SELECT inet_server_addr(), current_setting('port');"
  c) Now compare the two instances the lab provisioned, and compare both against
     what /opt/shopfast/app.env tells the application to connect to.
  d) In real AWS the equivalent recon is:
       aws rds describe-db-instances --query \
         'DBInstances[].[DBInstanceIdentifier,ReadReplicaSourceDBInstanceIdentifier,Endpoint.Address]'
       aws rds describe-db-clusters --query \
         'DBClusters[].[DBClusterIdentifier,Endpoint,ReaderEndpoint]'
H1
       ;;
    2) cat <<'H2'
HINT 2 - Amazon DynamoDB
  a) Describe the table and read its KeySchema and AttributeDefinitions:
       aws dynamodb describe-table --table-name ShopFast-Sessions \
         --endpoint-url http://127.0.0.1:58000
  b) Compare the attribute name in KeySchema with the attribute name in the
     PutItem call inside app.sh (you may READ app.sh; you may not edit it).
  c) DynamoDB has no ALTER TABLE for the primary key. Partition key and sort key
     are fixed at creation. Secondary indexes can be added later; the primary
     key cannot be changed. So what is the only corrective action available?
  d) The table holds no production data yet (sessions are ephemeral), so the
     destructive path is acceptable here. On a table with real data it would not
     be: you would create the new table and migrate the items.
H2
       ;;
    3) cat <<'H3'
HINT 3 - Amazon ElastiCache
  a) Ask the node about itself:
       redis-cli -h 127.0.0.1 -p 56379 info memory | grep -E 'used_memory_human|maxmemory'
       redis-cli -h 127.0.0.1 -p 56379 config get maxmemory-policy
  b) 'noeviction' means: when full, refuse writes. That is correct for a durable
     store (Amazon MemoryDB), and wrong for a cache. A cache-aside workload wants
     the least recently used keys thrown away instead.
  c) Eviction policies worth knowing: noeviction, allkeys-lru, volatile-lru,
     allkeys-lfu, volatile-ttl. ElastiCache's default parameter group ships
     volatile-lru, which only evicts keys that carry a TTL — if your application
     writes keys without a TTL, volatile-lru behaves exactly like noeviction.
     That subtlety is a real production outage, not a trick question.
  d) In real ElastiCache you cannot set maxmemory (AWS derives it from the node
     type and reserved-memory-percent). You change maxmemory-policy through a
     custom parameter group applied to the cluster.
H3
       ;;
    *) die "usage: $0 hint 1|2|3" ;;
  esac
}

# =============================================================================
#  VERIFY / GRADE
# =============================================================================
verify() {
  [ -f "$LAB_HOME/app.sh" ] || die "lab not provisioned; run: $0 setup"
  rule
  c_blue "GRADING — running the synthetic transaction"
  rule
  local app_rc=0
  bash "$LAB_HOME/app.sh" || app_rc=$?

  rule
  local score=0

  local ro
  ro=$(psql_q "$(grep -E '^RDS_ENDPOINT_HOST=' "$LAB_HOME/app.env" | cut -d= -f2)" \
        "SHOW default_transaction_read_only;" || true)
  if [ "$(printf '%s' "$ro" | tr -d '[:space:]')" = "off" ]; then
    c_green "[1/3] RDS   : the application is pointed at a WRITABLE endpoint"
    score=$((score + 1))
  else
    c_red   "[1/3] RDS   : the application is still pointed at a read-only endpoint"
  fi

  local ks
  ks=$(awsddb describe-table --table-name "$DDB_TABLE" || true)
  if printf '%s' "$ks" | grep -q '"AttributeName": "SessionId"'; then
    c_green "[2/3] DynamoDB: partition key is SessionId, matching the application"
    score=$((score + 1))
  else
    c_red   "[2/3] DynamoDB: partition key still does not match the application"
  fi

  local pol
  pol=$(redis_q config get maxmemory-policy | tr -d '\r' | tail -n1)
  if [ "$pol" != "noeviction" ]; then
    c_green "[3/3] ElastiCache: eviction policy is '$pol' — the cache can evict"
    score=$((score + 1))
  else
    c_red   "[3/3] ElastiCache: policy is still 'noeviction' — a cache that cannot evict"
  fi

  local rows
  rows=$(psql_q "$RDS_WRITER" "SELECT count(*) FROM catalog.orders;" | tr -d '[:space:]')
  rule
  if [ "$app_rc" -eq 0 ] && [ "$score" -eq 3 ]; then
    c_green "RESULT: 3/3 objectives met, synthetic transaction HEALTHY."
    c_green "catalog.orders row count: $rows (>= 25 required: data preserved)."
    c_green "Task 3.4 lab complete."
  else
    c_red "RESULT: $score/3 objectives met, app exit code $app_rc. Keep digging."
    c_yell "Hints: $0 hint 1 | 2 | 3"
  fi
  rule
}

# =============================================================================
#  CLEANUP
# =============================================================================
cleanup() {
  c_yell "Removing lab containers ${LAB_CONTAINERS[*]}, network '$NET', and $LAB_HOME"
  remove_containers
  $CTR network rm "$NET" >/dev/null 2>&1 || true
  case "$LAB_HOME" in
    /opt/shopfast) rm -rf "$LAB_HOME" ;;
    *) c_yell "LAB_HOME is not the default path; leaving $LAB_HOME on disk." ;;
  esac
  c_green "Lab removed. Container images were kept so the next run is fast."
  c_blue  "Remove them too with: $CTR rmi $PG_IMAGE $REDIS_IMAGE $DDB_IMAGE $AWSCLI_IMAGE"
}

usage() {
  sed -n '1,60p' "$0"
}

main() {
  case "${1:-all}" in
    all)
      detect_runtime; confirm_disposable_vm; setup; break_it ;;
    setup)
      detect_runtime; confirm_disposable_vm; setup ;;
    break)
      detect_runtime; break_it ;;
    run)
      detect_runtime; bash "$LAB_HOME/app.sh" ;;
    verify)
      detect_runtime; verify ;;
    hint)
      hint "${2:-0}" ;;
    cleanup)
      detect_runtime; cleanup ;;
    help|-h|--help)
      usage ;;
    *)
      die "unknown command '${1}'. Try: $0 help" ;;
  esac
}

main "$@"

# =============================================================================
# =============================================================================
#  S O L U T I O N  —  do not read until you have tried
# =============================================================================
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Recon before touching anything. Never fix what you have not measured.
# ---------------------------------------------------------------------------
#   $ docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
#   NAMES                  IMAGE                     PORTS
#   shopfast-dynamodb      amazon/dynamodb-local     0.0.0.0:58000->8000/tcp
#   shopfast-elasticache   redis:7-alpine            0.0.0.0:56379->6379/tcp
#   shopfast-rds-reader    postgres:16-alpine        0.0.0.0:55433->5432/tcp
#   shopfast-rds-writer    postgres:16-alpine        0.0.0.0:55432->5432/tcp
#
#   $ cat /opt/shopfast/app.env | grep -E 'RDS_ENDPOINT|CACHE_ENDPOINT|DDB_'
#   RDS_ENDPOINT_HOST=shopfast-rds-reader     <-- first thing that should smell wrong
#   ...
#
#   Everything is RUNNING. Nothing crashed. That is the whole point: at CLF level
#   the exam wants you to recognise WHICH database service is involved and what
#   its contract is. Three services, three broken contracts.
#
# ---------------------------------------------------------------------------
# FAULT 1 — Amazon RDS: the app is writing to a read-only endpoint
# ---------------------------------------------------------------------------
# DIAGNOSIS
#   $ docker run --rm --network shopfast-vpc -e PGPASSWORD=LabOnly-NotASecret \
#       postgres:16-alpine psql -h shopfast-rds-reader -U shopfast -d shopfast \
#       -tAc "SHOW default_transaction_read_only;"
#   on
#
#   $ docker run --rm --network shopfast-vpc -e PGPASSWORD=LabOnly-NotASecret \
#       postgres:16-alpine psql -h shopfast-rds-writer -U shopfast -d shopfast \
#       -tAc "SHOW default_transaction_read_only;"
#   off
#
#   The application config points at the instance that answers "on". Reads work,
#   writes raise:  ERROR:  cannot execute INSERT in a read-only transaction
#
# FIX (one line of configuration, no data movement, no downtime)
#   $ sudo sed -i 's/^RDS_ENDPOINT_HOST=.*/RDS_ENDPOINT_HOST=shopfast-rds-writer/' \
#       /opt/shopfast/app.env
#   $ grep RDS_ENDPOINT_HOST /opt/shopfast/app.env
#   RDS_ENDPOINT_HOST=shopfast-rds-writer
#
# WHY THIS IS THE RIGHT FIX, AND WHAT THE EXAM WANTS
#   * An RDS read replica is read-only by design: it exists to offload SELECT
#     traffic and to be promoted for regional recovery. You never fix a write
#     failure by making a replica writable.
#   * Aurora publishes two DNS names per cluster: the CLUSTER (writer) endpoint,
#     which always tracks the current primary through a failover, and the READER
#     endpoint, which load-balances across replicas and never accepts writes.
#     Applications must hold both and use them deliberately.
#   * Real-AWS equivalent of the fix: repoint the application at
#     mycluster.cluster-xxxx.us-east-1.rds.amazonaws.com  (writer)
#     instead of
#     mycluster.cluster-ro-xxxx.us-east-1.rds.amazonaws.com  (reader).
#   * Anti-pattern to name out loud: hardcoding the *instance* endpoint of the
#     current primary. After a failover that instance becomes a replica and your
#     writes start failing with exactly this error.
#   Docs: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Overview.Endpoints.html
#
# ---------------------------------------------------------------------------
# FAULT 2 — Amazon DynamoDB: partition key does not match the item
# ---------------------------------------------------------------------------
# DIAGNOSIS
#   $ aws dynamodb describe-table --table-name ShopFast-Sessions \
#       --endpoint-url http://127.0.0.1:58000 \
#       --query 'Table.[KeySchema,AttributeDefinitions,TableStatus]'
#   [
#       [ { "AttributeName": "sessionId", "KeyType": "HASH" } ],
#       [ { "AttributeName": "sessionId", "AttributeType": "S" } ],
#       "ACTIVE"
#   ]
#
#   The table expects "sessionId". The application sends "SessionId". DynamoDB
#   attribute names are case sensitive, so PutItem fails with:
#     An error occurred (ValidationException) when calling the PutItem operation:
#     One or more parameter values were invalid: Missing the key sessionId in the item
#
# FIX (the key schema is immutable — recreate, do not alter)
#   $ aws dynamodb delete-table --table-name ShopFast-Sessions \
#       --endpoint-url http://127.0.0.1:58000
#   $ aws dynamodb wait table-not-exists --table-name ShopFast-Sessions \
#       --endpoint-url http://127.0.0.1:58000
#   $ aws dynamodb create-table --table-name ShopFast-Sessions \
#       --attribute-definitions AttributeName=SessionId,AttributeType=S \
#       --key-schema AttributeName=SessionId,KeyType=HASH \
#       --billing-mode PAY_PER_REQUEST \
#       --endpoint-url http://127.0.0.1:58000
#   $ aws dynamodb wait table-exists --table-name ShopFast-Sessions \
#       --endpoint-url http://127.0.0.1:58000
#
#   (Use --endpoint-url http://shopfast-dynamodb:8000 if you run the aws CLI from
#    a container attached to the shopfast-vpc network instead of from the host.)
#
# WHY THIS IS THE RIGHT FIX, AND WHAT THE EXAM WANTS
#   * DynamoDB is schemaless EXCEPT for the primary key. Every item must carry
#     the partition key (and the sort key, if the table has one); every other
#     attribute is free-form per item.
#   * The primary key is chosen at CreateTable and can never be changed. You can
#     add a Global Secondary Index later to query by another attribute, but that
#     does not change the table's key. Deleting and recreating is the only path.
#   * Deleting was acceptable here ONLY because session data is ephemeral and the
#     table was empty. With real data the correct procedure is: create the new
#     table, backfill (DynamoDB export to S3 / a Glue or DMS job / a scan-and-put
#     migration), dual-write, cut over, then retire the old table.
#   * PAY_PER_REQUEST (on-demand) is the right default for spiky, unknown traffic
#     such as sessions; provisioned capacity with auto scaling is cheaper for
#     steady, predictable throughput. Knowing which to pick is a task 3.4 / 4.x
#     favourite.
#   Docs: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.CoreComponents.html
#
# ---------------------------------------------------------------------------
# FAULT 3 — Amazon ElastiCache: a cache that is not allowed to evict
# ---------------------------------------------------------------------------
# DIAGNOSIS
#   $ redis-cli -h 127.0.0.1 -p 56379 config get maxmemory-policy
#   1) "maxmemory-policy"
#   2) "noeviction"
#   $ redis-cli -h 127.0.0.1 -p 56379 info memory | grep -E 'used_memory_human|maxmemory_human'
#   used_memory_human:3.00M
#   maxmemory_human:3.00M
#
#   The node is at its ceiling and the policy forbids evicting anything, so every
#   further SET is rejected:
#     OOM command not allowed when used memory > 'maxmemory'.
#
# FIX
#   $ redis-cli -h 127.0.0.1 -p 56379 config set maxmemory-policy allkeys-lru
#   OK
#   $ redis-cli -h 127.0.0.1 -p 56379 config get maxmemory-policy
#   1) "maxmemory-policy"
#   2) "allkeys-lru"
#
#   Optionally give the node room back (in this lab only — see below):
#   $ redis-cli -h 127.0.0.1 -p 56379 config set maxmemory 64mb
#
# WHY THIS IS THE RIGHT FIX, AND WHAT THE EXAM WANTS
#   * A cache is a lossy accelerator. If evicting a cold key is unacceptable,
#     you do not want ElastiCache — you want Amazon MemoryDB, which is durable
#     and multi-AZ and is a primary database, not a cache. That distinction is
#     exactly what task 3.4 tests.
#   * allkeys-lru evicts the least recently used key regardless of TTL, which is
#     what a cache-aside catalog wants. volatile-lru — the ElastiCache default —
#     only evicts keys that HAVE a TTL, so an application that writes keys with
#     no expiry gets noeviction behaviour and this same outage.
#   * On real ElastiCache: `maxmemory` is managed by AWS from the node type and
#     `reserved-memory-percent`; you change `maxmemory-policy` by creating a
#     custom parameter group and applying it to the cluster:
#       aws elasticache create-cache-parameter-group \
#         --cache-parameter-group-name shopfast-redis7 \
#         --cache-parameter-group-family redis7 --description "ShopFast cache"
#       aws elasticache modify-cache-parameter-group \
#         --cache-parameter-group-name shopfast-redis7 \
#         --parameter-name-values ParameterName=maxmemory-policy,ParameterValue=allkeys-lru
#       aws elasticache modify-replication-group \
#         --replication-group-id shopfast --cache-parameter-group-name shopfast-redis7 \
#         --apply-immediately
#   * CONFIG SET is runtime-only: restart the node and it reverts. In this lab
#     that is fine; in production the parameter group IS the durable fix. Same
#     lesson as `ALTER SYSTEM` vs an RDS parameter group.
#   Docs: https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/redis-memory-management.html
#
# ---------------------------------------------------------------------------
# STEP 4 — Prove it, do not assume it
# ---------------------------------------------------------------------------
#   $ bash /opt/shopfast/app.sh
#
#   == PHASE 1 - Amazon RDS for PostgreSQL (relational, OLTP)
#     [PASS] read path: SELECT count(*) FROM catalog.orders -> 25 rows
#     [PASS] write path: checkout INSERT committed, order_id=26
#   == PHASE 2 - Amazon DynamoDB (key-value, session state)
#     [PASS] PutItem SessionId=sess-1234-1757030400
#     [PASS] GetItem (strongly consistent) returned the session item
#   == PHASE 3 - Amazon ElastiCache (in-memory cache warm-up)
#     [PASS] warmed 200 catalog pages (32 KiB each) into the cache
#
#   ShopFast synthetic transaction: HEALTHY
#
#   $ ./break-fix-3-4-databases.sh verify
#   [1/3] RDS   : the application is pointed at a WRITABLE endpoint
#   [2/3] DynamoDB: partition key is SessionId, matching the application
#   [3/3] ElastiCache: eviction policy is 'allkeys-lru' — the cache can evict
#   RESULT: 3/3 objectives met, synthetic transaction HEALTHY.
#   catalog.orders row count: 26 (>= 25 required: data preserved).
#
#   $ ./break-fix-3-4-databases.sh cleanup
#
# ---------------------------------------------------------------------------
# THE TRANSFERABLE LESSON (this is what the exam is really asking)
# ---------------------------------------------------------------------------
#   Each failure was the service behaving EXACTLY as documented, used against
#   its contract:
#     - a read replica refused a write            -> pick the writer endpoint
#     - a key-value store refused a keyless item  -> the partition key is the schema
#     - a cache refused to forget                 -> a cache must be allowed to evict
#   "Identify AWS database services" is not flashcard recall. It is knowing which
#   service owns which guarantee, so that when the symptom appears at 03:12 UTC
#   you already know which of the three it can be — before you open a console.
# =============================================================================