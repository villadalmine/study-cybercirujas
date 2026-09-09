#!/usr/bin/env bash
#
# =============================================================================
#  teach-plat · gcp-cdl (Cloud Digital Leader, exam version 2026-08-12)
#  Topic 2.2 — Determine which Google Cloud data management products are
#              applicable to different business use cases   (exam weight 6.0)
#
#  BREAK & FIX LAB — "Meridian Retail data platform review"
# =============================================================================
#
#  WHAT THIS SCRIPT DOES
#    It builds a small, self-contained simulation of a retail company's data
#    platform on this VM, then BREAKS it: a previous architect re-assigned
#    several production workloads to the wrong Google Cloud data product. The
#    products are modelled by their real capabilities and real limits, so the
#    failures you will see are the failures those mis-assignments actually
#    produce (streaming-buffer mutation errors, a Cloud SQL instance that runs
#    out of storage and flips read-only, a cache used as a system of record,
#    an Archive-class bucket serving hot traffic, a batch transfer tool asked
#    to do change data capture, a dashboard tool with no governed metric).
#
#  SAFETY CONTRACT (read it — this is the part that lets you run it)
#    * Everything is created under $LAB_ROOT, which defaults to
#      $HOME/labs/gcp-cdl/topic-2.2-data-management
#    * No sudo. No package installation. No network calls. No systemd units.
#      No writes, moves or deletes outside $LAB_ROOT. Nothing is masked,
#      truncated or reconfigured on the host.
#    * The only "destructive" act is `reset`, which removes $LAB_ROOT after a
#      path sanity check.
#    * The one real service it stresses is a local SQLite database that stands
#      in for a Cloud SQL instance; its storage ceiling is enforced with
#      PRAGMA max_page_count, so the disk-full error you get is genuine
#      SQLITE_FULL, not a printf.
#    Still: run this on a DISPOSABLE lab VM. That is what the confirmation
#    flag is for.
#
#  USAGE
#    ./break-fix-2.2.sh setup --i-am-on-a-disposable-lab-vm   # build + break
#    ./break-fix-2.2.sh run          # simulate one business day, see incidents
#    ./break-fix-2.2.sh verify       # the architecture review gate (exit 0 = fixed)
#    ./break-fix-2.2.sh ingest       # replay the IoT batch through the catalog
#    ./break-fix-2.2.sh describe <workload|product>
#    ./break-fix-2.2.sh catalog      # workloads + their requirement tags
#    ./break-fix-2.2.sh hint [1-3]
#    ./break-fix-2.2.sh status
#    ./break-fix-2.2.sh reset
#
#  Official sources used for the product limits encoded below:
#    Exam guide  https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#    Cloud SQL   https://cloud.google.com/sql/docs
#    AlloyDB     https://cloud.google.com/alloydb/docs
#    Spanner     https://cloud.google.com/spanner/docs
#    Bigtable    https://cloud.google.com/bigtable/docs
#    Firestore   https://cloud.google.com/firestore/docs
#    BigQuery    https://cloud.google.com/bigquery/docs
#    Memorystore https://cloud.google.com/memorystore/docs
#    Storage     https://cloud.google.com/storage/docs/storage-classes
#    Pub/Sub     https://cloud.google.com/pubsub/docs
#    Datastream  https://cloud.google.com/datastream/docs
#    Transfer    https://cloud.google.com/storage-transfer/docs
#    Looker      https://cloud.google.com/looker/docs
#
set -Eeuo pipefail

if ((BASH_VERSINFO[0] < 4)); then
    echo "This lab needs bash 4+ (associative arrays). Found: $BASH_VERSION" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Paths and constants
# -----------------------------------------------------------------------------
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SELF
readonly LAB_ROOT="${LAB_ROOT:-$HOME/labs/gcp-cdl/topic-2.2-data-management}"
readonly PLATFORM="$LAB_ROOT/platform"
readonly CATALOG_FILE="$PLATFORM/catalog.yaml"
readonly STATE_DIR="$LAB_ROOT/state"
readonly BIN_DIR="$LAB_ROOT/bin"
readonly SQL_DB="$LAB_ROOT/data/cloudsql/meridian-telemetry.db"
readonly BT_TABLE="$LAB_ROOT/data/bigtable/meridian.telemetry.rows"
readonly STORAGE_PAGES_FILE="$STATE_DIR/cloudsql_storage_pages"
readonly INGEST_MARKER="$STATE_DIR/ingest.ok"
readonly BATCH_ROWS=25000          # one hour of shelf-sensor telemetry
readonly MONTHLY_BUDGET=1000       # illustrative platform budget, cost units
readonly LAB_TAG="teach-plat-gcp-cdl-2.2"

# Colours, disabled when not a terminal or when NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; B=''; D=''; N=''
fi

die()  { printf '%s[lab]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
rule() { printf '%s%s%s\n' "$D" "-------------------------------------------------------------------------------" "$N"; }
head2() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }

# -----------------------------------------------------------------------------
# The product model: capability tags, illustrative unit prices, docs
#
# A workload is servable by a product only if the product's capability set is a
# superset of the workload's requirement set. This is exactly the reasoning the
# exam asks for: read the business requirement, map it to the product whose
# properties satisfy it — not to the product you happen to like.
# -----------------------------------------------------------------------------
declare -A CAPS=(
  [cloud-sql]="relational sql acid-multi-row mysql-wire postgres-wire sqlserver-wire regional-ha read-replicas pitr managed-backups vertical-scale durable oltp-low-latency"
  [alloydb]="relational sql acid-multi-row postgres-wire regional-ha read-replicas pitr managed-backups vertical-scale durable oltp-low-latency columnar-accel htap"
  [spanner]="relational sql acid-multi-row postgres-wire horizontal-scale global-strong-consistency multi-region-99999 durable oltp-low-latency online-schema-change petabyte-scale"
  [bigtable]="nosql wide-column horizontal-scale petabyte-scale sub-10ms-p99 high-write-throughput time-series-scan durable hbase-api single-row-atomicity"
  [firestore]="nosql document mobile-sdk offline-sync realtime-listeners acid-multi-row durable horizontal-scale serverless security-rules"
  [bigquery]="sql columnar analytics petabyte-scale serverless federated-queries in-database-ml bi-integration durable streaming-ingest time-travel"
  [memorystore]="key-value in-memory sub-ms-cache redis-api memcached-api"
  [cloud-storage:standard]="object-store durable hot-read no-retrieval-fee no-min-duration versioning lifecycle long-term-retention"
  [cloud-storage:nearline]="object-store durable lifecycle versioning long-term-retention min-duration-30d retrieval-fee"
  [cloud-storage:coldline]="object-store durable lifecycle versioning long-term-retention min-duration-90d retrieval-fee"
  [cloud-storage:archive]="object-store durable lifecycle versioning long-term-retention min-duration-365d retrieval-fee"
  [filestore]="nfs posix-filesystem durable shared-mount"
  [pub-sub]="streaming-ingest global-messaging decoupling push-pull ordering-keys durable serverless"
  [datastream]="cdc log-based-replication oracle-source mysql-source postgres-source bigquery-sink serverless durable"
  [storage-transfer]="bulk-object-transfer scheduled-transfer s3-source on-prem-source durable serverless"
  [dataflow]="stream-batch-unified apache-beam autoscaling exactly-once transform serverless"
  [dataproc]="hadoop spark managed-cluster ephemeral-cluster"
  [looker]="semantic-model governed-metrics lookml embedded-analytics row-level-security bi-integration api-driven"
  [looker-studio]="self-serve-dashboards free-connectors bi-integration"
)

declare -A PRICE=(
  [cloud-sql]=0.30 [alloydb]=0.55 [spanner]=2.10 [bigtable]=0.95 [firestore]=0.55
  [bigquery]=0.18 [memorystore]=1.40 [filestore]=0.45
  [cloud-storage:standard]=0.020 [cloud-storage:nearline]=0.010
  [cloud-storage:coldline]=0.004 [cloud-storage:archive]=0.0012
  [pub-sub]=0.06 [datastream]=0.35 [storage-transfer]=0.02 [dataflow]=0.25
  [dataproc]=0.30 [looker]=1.00 [looker-studio]=0.00
)

# Charged per unit actually READ back. This is the whole point of the storage
# classes: the colder the class, the cheaper at rest and the dearer to read.
declare -A RETRIEVAL=(
  [cloud-storage:standard]=0.000 [cloud-storage:nearline]=0.010
  [cloud-storage:coldline]=0.020 [cloud-storage:archive]=0.050
)

declare -A DOCS=(
  [cloud-sql]="https://cloud.google.com/sql/docs"
  [alloydb]="https://cloud.google.com/alloydb/docs"
  [spanner]="https://cloud.google.com/spanner/docs"
  [bigtable]="https://cloud.google.com/bigtable/docs"
  [firestore]="https://cloud.google.com/firestore/docs"
  [bigquery]="https://cloud.google.com/bigquery/docs"
  [memorystore]="https://cloud.google.com/memorystore/docs"
  [cloud-storage:standard]="https://cloud.google.com/storage/docs/storage-classes"
  [cloud-storage:nearline]="https://cloud.google.com/storage/docs/storage-classes"
  [cloud-storage:coldline]="https://cloud.google.com/storage/docs/storage-classes"
  [cloud-storage:archive]="https://cloud.google.com/storage/docs/storage-classes"
  [filestore]="https://cloud.google.com/filestore/docs"
  [pub-sub]="https://cloud.google.com/pubsub/docs"
  [datastream]="https://cloud.google.com/datastream/docs"
  [storage-transfer]="https://cloud.google.com/storage-transfer/docs"
  [dataflow]="https://cloud.google.com/dataflow/docs"
  [dataproc]="https://cloud.google.com/dataproc/docs"
  [looker]="https://cloud.google.com/looker/docs"
  [looker-studio]="https://cloud.google.com/looker/docs/studio"
)

declare -A FACTS=(
  [cloud-sql]="Managed MySQL / PostgreSQL / SQL Server. Lift-and-shift for existing relational apps. Regional HA, read replicas, PITR. Scales vertically; one primary accepts writes."
  [alloydb]="PostgreSQL-compatible, HTAP: a columnar engine accelerates analytical queries on the transactional data. Choose over Cloud SQL when Postgres workloads need more throughput or in-place analytics."
  [spanner]="Relational AND horizontally scalable, with external consistency across regions (TrueTime) and a 99.999% multi-region SLA. The answer when 'global', 'strongly consistent' and 'SQL transactions' appear in the same sentence."
  [bigtable]="Wide-column NoSQL. Petabyte scale, single-digit-millisecond p99, enormous write throughput, key-range scans. Atomicity is per row only. Row key design decides whether you scale or hotspot."
  [firestore]="Document NoSQL with mobile/web SDKs, offline sync and realtime listeners. The answer for app/user state on phones, not for warehouse-scale aggregation."
  [bigquery]="Serverless columnar analytics warehouse: storage and compute separated, petabyte scans, BI Engine, BigQuery ML, federated queries, time travel. Not an OLTP store — recent streamed rows sit in a buffer that cannot be mutated."
  [memorystore]="Managed Redis / Memcached. Sub-millisecond cache in front of a system of record. Treat it as volatile: eviction policy and failover can drop keys."
  [cloud-storage:standard]="Object storage, hot class. No minimum storage duration, no retrieval fee. For content served to users and for data read frequently."
  [cloud-storage:nearline]="Object storage, 30-day minimum storage duration plus retrieval fees. Roughly monthly access."
  [cloud-storage:coldline]="Object storage, 90-day minimum storage duration plus retrieval fees. Roughly quarterly access."
  [cloud-storage:archive]="Object storage, 365-day minimum storage duration and the highest retrieval fee. Compliance retention you hope never to read. Milliseconds to first byte, but you pay per read and pay early-delete charges."
  [filestore]="Managed NFS. For applications that need a POSIX shared filesystem."
  [pub-sub]="Global, serverless messaging. Decouples producers from consumers, buffers spikes, fans out. Ingestion front door, not storage."
  [datastream]="Serverless change data capture. Reads the source database's transaction log (Oracle, MySQL, PostgreSQL, SQL Server) and streams changes, typically into BigQuery, with minimal source load."
  [storage-transfer]="Bulk, scheduled movement of OBJECTS and files between buckets, S3, Azure and on-prem. It is a copier, not a CDC reader."
  [dataflow]="Managed Apache Beam. One programming model for streaming and batch transformation, autoscaled, exactly-once."
  [dataproc]="Managed Hadoop/Spark, best used as ephemeral job-scoped clusters."
  [looker]="Governed BI: LookML defines metrics once, centrally, with row-level security and an embedding API. One definition of 'net revenue' for the whole company."
  [looker-studio]="Free, self-serve dashboards and connectors. Fast and useful — but each report defines its own metrics, so it is not a governance layer."
)

declare -A CAP_MEANING=(
  [relational]="tables, schema, joins, SQL constraints"
  [sql]="queried with SQL rather than a proprietary API"
  [acid-multi-row]="one atomic commit spanning more than one row / entity"
  [single-row-atomicity]="atomic writes, but only within a single row"
  [global-strong-consistency]="every region reads the latest committed write, no read-your-writes exceptions"
  [multi-region-99999]="99.999% availability SLA across regions"
  [horizontal-scale]="capacity grows by adding nodes, not by resizing one machine"
  [vertical-scale]="capacity grows by resizing one machine"
  [petabyte-scale]="a single dataset in the hundreds of TB to PB range"
  [oltp-low-latency]="millisecond point reads/writes on the transactional path"
  [sub-10ms-p99]="single-digit-millisecond p99, sustained"
  [sub-ms-cache]="sub-millisecond in-memory lookups"
  [high-write-throughput]="hundreds of thousands to millions of writes per second"
  [time-series-scan]="efficient scans over a contiguous key range (device, time)"
  [durable]="the system of record: survives node loss without another store behind it"
  [mysql-wire]="speaks the MySQL wire protocol, so an existing MySQL driver connects unchanged"
  [postgres-wire]="speaks the PostgreSQL wire protocol"
  [regional-ha]="synchronous standby in a second zone with automatic failover"
  [pitr]="point-in-time recovery from continuous backups"
  [nosql]="non-relational data model"
  [document]="document model with nested fields"
  [mobile-sdk]="first-party mobile/web client SDK talking to the database directly"
  [offline-sync]="clients keep working offline and reconcile on reconnect"
  [realtime-listeners]="clients are pushed changes as they happen"
  [analytics]="scan-and-aggregate over the whole dataset"
  [columnar]="column-oriented storage, so wide scans read only the columns used"
  [in-database-ml]="model training and inference in SQL, in place"
  [bi-integration]="native connectors for BI tooling"
  [serverless]="no instance to size, patch or scale"
  [key-value]="opaque values addressed by key"
  [in-memory]="the working set lives in RAM"
  [object-store]="immutable objects addressed by name in a bucket"
  [hot-read]="designed to be read constantly"
  [no-retrieval-fee]="reads are not charged per byte retrieved"
  [no-min-duration]="objects can be deleted any time without an early-delete charge"
  [long-term-retention]="cheap to keep for years"
  [min-duration-30d]="30-day minimum storage duration"
  [min-duration-90d]="90-day minimum storage duration"
  [min-duration-365d]="365-day minimum storage duration"
  [retrieval-fee]="charged per byte read back"
  [streaming-ingest]="accepts a continuous event stream"
  [global-messaging]="one global endpoint, publishers and subscribers anywhere"
  [decoupling]="producers do not block on consumers"
  [push-pull]="both push and pull subscriptions"
  [cdc]="change data capture: row-level changes as they are committed"
  [log-based-replication]="reads the source transaction/redo log instead of polling tables"
  [oracle-source]="supports Oracle as a source"
  [bigquery-sink]="lands changes directly in BigQuery"
  [semantic-model]="metrics defined once, centrally, and reused"
  [governed-metrics]="a single authoritative definition per metric"
  [embedded-analytics]="dashboards embedded in another product with a supported API"
  [row-level-security]="each viewer sees only their permitted rows"
)

# -----------------------------------------------------------------------------
# The business: Meridian Retail. Requirements come from the business need,
# never from the technology preference.
# -----------------------------------------------------------------------------
readonly WORKLOADS=(
  pos-ledger store-catalog iot-telemetry mobile-app-state sales-analytics
  session-cache product-images receipt-archive clickstream-ingest
  oracle-cdc exec-dashboards
)

declare -A DESC=(
  [pos-ledger]="Point-of-sale ledger. 2,300 stores on three continents post payments; a card must never be double-charged, inventory decrements and payment rows commit together, and a store in Frankfurt must read what Sao Paulo committed one second ago. Target 99.999%."
  [store-catalog]="Store product catalog. An existing 4 TB application built on MySQL 8, moving to the cloud unchanged, in one region, with a standby and point-in-time recovery."
  [iot-telemetry]="Cold-chain shelf sensors. 1.2 M writes/s, 400 TB retained, queries are always 'this device, this time range', p99 must stay under 10 ms."
  [mobile-app-state]="Loyalty app state on phones. Works in a basement aisle with no signal, syncs when the signal returns, and the basket updates live across the user's devices."
  [sales-analytics]="Enterprise sales warehouse. 900 TB, ad-hoc SQL over years of history, forecasting models trained where the data already is, connected to BI tools."
  [session-cache]="Web session and price-lookup cache in front of the catalog. Sub-millisecond, rebuildable from the system of record at any time."
  [product-images]="Product images served to the storefront. Every object is read many times a day, and seasonal assets are deleted after a few weeks."
  [receipt-archive]="Digital receipts kept 7 years for tax audits. Written once, read essentially never — a handful of objects when an auditor asks."
  [clickstream-ingest]="Storefront clickstream front door. Traffic spikes 40x on promotion days; five downstream consumers must each get every event without the web tier waiting for them."
  [oracle-cdc]="Legacy Oracle ERP replication. Order changes must reach the warehouse within minutes, continuously, without adding load to the ERP with table polling."
  [exec-dashboards]="Executive revenue dashboards, also embedded in the supplier portal. Every team must see the SAME 'net revenue', and each supplier sees only their own rows."
)

declare -A REQS=(
  [pos-ledger]="relational sql acid-multi-row global-strong-consistency horizontal-scale durable oltp-low-latency multi-region-99999"
  [store-catalog]="relational sql acid-multi-row mysql-wire regional-ha pitr durable oltp-low-latency"
  [iot-telemetry]="nosql high-write-throughput sub-10ms-p99 petabyte-scale time-series-scan horizontal-scale durable"
  [mobile-app-state]="document mobile-sdk offline-sync realtime-listeners durable"
  [sales-analytics]="sql analytics columnar petabyte-scale in-database-ml bi-integration serverless durable"
  [session-cache]="key-value in-memory sub-ms-cache"
  [product-images]="object-store durable hot-read no-retrieval-fee no-min-duration"
  [receipt-archive]="object-store durable long-term-retention"
  [clickstream-ingest]="streaming-ingest global-messaging decoupling push-pull durable"
  [oracle-cdc]="cdc log-based-replication oracle-source bigquery-sink serverless durable"
  [exec-dashboards]="semantic-model governed-metrics embedded-analytics row-level-security bi-integration"
)

# Illustrative sizing units, and how much of the stored data is read back each
# month (only used for object storage retrieval charges).
declare -A UNITS=(
  [pos-ledger]=90 [store-catalog]=60 [iot-telemetry]=400 [mobile-app-state]=120
  [sales-analytics]=500 [session-cache]=40 [product-images]=800
  [receipt-archive]=1500 [clickstream-ingest]=200 [oracle-cdc]=30 [exec-dashboards]=20
)
declare -A READS=(
  [product-images]=1.00 [receipt-archive]=0.01
)

# The mis-assignment that this script injects.
declare -A BROKEN_CATALOG=(
  [pos-ledger]="bigquery"
  [store-catalog]="spanner"
  [iot-telemetry]="cloud-sql"
  [mobile-app-state]="memorystore"
  [sales-analytics]="bigquery"
  [session-cache]="memorystore"
  [product-images]="cloud-storage:archive"
  [receipt-archive]="cloud-storage:archive"
  [clickstream-ingest]="pub-sub"
  [oracle-cdc]="storage-transfer"
  [exec-dashboards]="looker-studio"
)

declare -A CATALOG=()

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

load_catalog() {
    [[ -f "$CATALOG_FILE" ]] || die "no catalog at $CATALOG_FILE — run: $SELF setup --i-am-on-a-disposable-lab-vm"
    CATALOG=()
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*([a-z0-9-]+)[[:space:]]*:[[:space:]]*([a-z0-9:._-]+)[[:space:]]*$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        [[ "$key" == "workloads" ]] && continue
        CATALOG["$key"]="$value"
    done < "$CATALOG_FILE"
}

missing_caps() {   # workload product -> space-separated missing capability tags
    local w="$1" p="$2" have_caps=" ${CAPS[$p]-} " miss="" req
    for req in ${REQS[$w]}; do
        [[ "$have_caps" == *" $req "* ]] || miss+="$req "
    done
    printf '%s' "${miss% }"
}

cost_of() {        # workload product -> monthly cost units
    local w="$1" p="$2"
    awk -v u="${UNITS[$w]:-0}" -v pr="${PRICE[$p]:-0}" \
        -v rf="${READS[$w]:-0}" -v rt="${RETRIEVAL[$p]:-0}" \
        'BEGIN { printf "%.2f", u*pr + u*rf*rt }'
}

storage_pages() { cat "$STORAGE_PAGES_FILE" 2>/dev/null || echo 64; }

# -----------------------------------------------------------------------------
# setup: build the platform, then break it
# -----------------------------------------------------------------------------
cmd_setup() {
    [[ "${1:-}" == "--i-am-on-a-disposable-lab-vm" || "${LAB_CONFIRM:-}" == "1" ]] || cat <<EOF && [[ "${1:-}" == "--i-am-on-a-disposable-lab-vm" || "${LAB_CONFIRM:-}" == "1" ]] || exit 2
This lab writes a broken platform simulation under:
    $LAB_ROOT
It touches nothing else, uses no sudo and makes no network calls — but it is
still meant for a THROWAWAY VM. Confirm with:

    $SELF setup --i-am-on-a-disposable-lab-vm

EOF

    mkdir -p "$PLATFORM" "$STATE_DIR" "$BIN_DIR" \
             "$LAB_ROOT/data/cloudsql" "$LAB_ROOT/data/bigtable"
    printf '%s\n' "$LAB_TAG" > "$LAB_ROOT/.lab-marker"

    # Convenience wrapper so the student types `dl-sim` instead of a long path.
    cat > "$BIN_DIR/dl-sim" <<EOF
#!/usr/bin/env bash
exec "$SELF" "\$@"
EOF
    chmod +x "$BIN_DIR/dl-sim"

    # ---- BREAK #1: the service catalog is written with wrong assignments -----
    if [[ -f "$CATALOG_FILE" && "${2:-}" != "--force" ]]; then
        say "${Y}keeping your existing catalog${N} ($CATALOG_FILE) — add --force to re-break it"
    else
        {
            echo "# Meridian Retail — data platform service catalog"
            echo "# One line per workload:   <workload>: <product>"
            echo "# Object storage takes a class:   <workload>: cloud-storage:<standard|nearline|coldline|archive>"
            echo "#"
            echo "# Valid products: ${!CAPS[*]}" | tr ' ' '\n' | sed 's/^cloud/#   cloud/' | head -1
            echo "#   cloud-sql alloydb spanner bigtable firestore bigquery memorystore filestore"
            echo "#   cloud-storage:standard|nearline|coldline|archive"
            echo "#   pub-sub datastream storage-transfer dataflow dataproc looker looker-studio"
            echo "#"
            echo "# Read a workload's requirements with:  dl-sim describe <workload>"
            echo "# Read a product's properties with:     dl-sim describe <product>"
            echo ""
            echo "workloads:"
            for w in "${WORKLOADS[@]}"; do
                printf '  %-20s %s\n' "${w}:" "${BROKEN_CATALOG[$w]}"
            done
        } > "$CATALOG_FILE"
    fi

    # ---- BREAK #2: a genuinely undersized "Cloud SQL" instance ---------------
    # 64 pages x 4 KiB = 256 KiB of usable storage. The IoT batch is ~1.1 MB.
    echo 64 > "$STORAGE_PAGES_FILE"
    rm -f "$INGEST_MARKER" "$BT_TABLE"
    if have sqlite3; then
        rm -f "$SQL_DB"
        sqlite3 "$SQL_DB" <<'SQL'
PRAGMA page_size = 4096;
CREATE TABLE IF NOT EXISTS telemetry (
    id        INTEGER PRIMARY KEY,
    device_id TEXT    NOT NULL,
    ts        INTEGER NOT NULL,
    metric    TEXT    NOT NULL,
    value     REAL    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_telemetry_device_ts ON telemetry(device_id, ts);
SQL
    else
        say "${Y}note:${N} sqlite3 not installed — the storage-full incident will be reported as simulated."
    fi

    print_briefing
}

print_briefing() {
    cat <<EOF

$B===============================================================================$N
$B  gcp-cdl 2.2 — BREAK & FIX: "the Meridian Retail platform review"$N
$B===============================================================================$N

  ${D}Scenario.${N} You inherit Meridian Retail's data platform. Your predecessor
  re-assigned production workloads to different Google Cloud data products over
  one weekend, and left. It is Monday. The platform is on fire in four places,
  quietly wrong in two more, and the monthly bill went DOWN — which is the part
  that should worry you most.

$Y  SYMPTOMS YOU ARE ABOUT TO SEE$N   (run: $BIN_DIR/dl-sim run)

    1. Payments are rejected in bursts with a BigQuery streaming-buffer error,
       and commit p99 is measured in seconds instead of milliseconds.
    2. The catalog application will not start: its MySQL driver cannot open a
       connection to the database it was pointed at.
    3. The telemetry ingest job aborts. The instance backing it has run out of
       storage and has gone read-only. This one is a real error from a real
       database engine on this VM — not a printed message.
    4. Loyalty-app baskets vanish. Phones cannot sync at all when offline.
    5. Product images load slowly and every image read shows up as a retrieval
       charge; deleting last season's assets triggers early-delete charges.
    6. The warehouse's Oracle order data is 26 hours stale.
    7. Three teams report three different values for "net revenue".

$G  WHAT YOU MUST ACHIEVE$N

    Make the architecture review pass:

        $BIN_DIR/dl-sim verify        # must exit 0

    That gate requires all three of the following:

      (a) Every workload is assigned to a product whose capabilities satisfy
          that workload's stated requirements. The requirements come from the
          BUSINESS description, not from what is cheapest.
      (b) The one-hour telemetry batch actually lands, through whatever product
          the catalog assigns it to:   $BIN_DIR/dl-sim ingest
      (c) The illustrative monthly platform cost stays under $MONTHLY_BUDGET units.

    You may edit exactly one file:

        $CATALOG_FILE

    Two commands are your documentation:

        $BIN_DIR/dl-sim describe <workload>   # the requirement tags, explained
        $BIN_DIR/dl-sim describe <product>    # what that product actually is

    Stuck? $BIN_DIR/dl-sim hint 1   (then 2, then 3 — 3 is nearly the answer)

$D  Nothing outside $LAB_ROOT was touched.
  Undo everything with: $SELF reset$N

EOF
}

# -----------------------------------------------------------------------------
# run: simulate one business day against the current catalog
# -----------------------------------------------------------------------------
symptom_for() {
    local w="$1" p="$2"
    case "$w|$p" in
      "pos-ledger|bigquery")
        cat <<'EOF'
    07:14:02  store=DE-0417 tx=8f21c9 commit -> bigquery:meridian.pos_ledger
      ERROR 400: UPDATE or DELETE statement over table meridian.pos_ledger would
      affect rows in the streaming buffer, which is not supported
      commit p99 1,840 ms (SLO 50 ms) · 12,904 transactions rejected in 1 h
      inventory decrement and payment row committed independently -> 37 orphans
EOF
        ;;
      "store-catalog|spanner")
        cat <<'EOF'
    07:00:11  catalog-api boot: mysql_real_connect(catalog-prod:3306)
      ERROR 2002 (HY000): the application speaks the MySQL wire protocol;
      Spanner exposes GoogleSQL and PostgreSQL dialect interfaces only
      lift-and-shift blocked: 0 of 41 pods reached readiness
EOF
        ;;
      "mobile-app-state|memorystore")
        cat <<'EOF'
    09:41:55  loyalty-app sync: 41,220 keys evicted (maxmemory-policy allkeys-lru)
      basket state lost for 6,180 users after a routine failover
      no mobile SDK: phones cannot read/write the store directly, and there is
      no offline queue — in-aisle users see an empty cart until they get signal
EOF
        ;;
      "product-images|cloud-storage:archive")
        cat <<'EOF'
    all day   storefront image reads: 800 units retrieved from ARCHIVE class
      every single read is billed as a retrieval; storage at rest is nearly free
      and irrelevant at this access pattern
      early delete: seasonal objects removed before the 365-day minimum storage
      duration are still charged for the full 365 days
EOF
        ;;
      "oracle-cdc|storage-transfer")
        cat <<'EOF'
    02:00:00  nightly transfer job: 0 objects copied
      Storage Transfer Service moves OBJECTS between buckets, S3, Azure and
      on-prem filers. It cannot read Oracle redo logs, so no row-level change
      ever reaches the warehouse.
      warehouse order table is 26 h stale · SLA is 15 min
EOF
        ;;
      "exec-dashboards|looker-studio")
        cat <<'EOF'
    11:30:00  board pack assembled from 3 self-serve reports
      "net revenue" = 41.2M (finance) / 43.8M (sales) / 39.9M (ops)
      each report defines the metric in its own copy of the logic; there is no
      central definition and no row-level security for the supplier portal
EOF
        ;;
      *)
        return 1 ;;
    esac
}

healthy_for() {
    local w="$1" p="$2"
    case "$p" in
      spanner)                 echo "    external consistency across 3 regions · commit p99 11 ms · 0 aborted · 99.999%" ;;
      cloud-sql)               echo "    regional HA standby healthy · replica lag 42 ms · PITR window 7 d" ;;
      bigtable)                echo "    1.24 M writes/s sustained · read p99 6 ms · 412 TB stored · no hot tablet" ;;
      firestore)               echo "    realtime listeners: 88k · offline mutations replayed: 1,204 · 0 conflicts" ;;
      bigquery)                echo "    912 TB scanned this month · slot utilisation 61% · BQML forecast refreshed" ;;
      memorystore)             echo "    hit ratio 96.4% · p99 0.4 ms · cold start rebuilt from the catalog in 90 s" ;;
      cloud-storage:standard)  echo "    served from the hot class · no retrieval charge · objects deletable any time" ;;
      cloud-storage:archive)   echo "    7-year retention · 3 objects retrieved this month · cheapest class at rest" ;;
      pub-sub)                 echo "    peak 640k msg/s absorbed · 5 subscriptions · oldest unacked age 2 s" ;;
      datastream)              echo "    log-based CDC from Oracle · end-to-end lag 48 s · source CPU impact <2%" ;;
      looker)                  echo "    one LookML definition of net_revenue · row-level security on supplier_id" ;;
      *)                       echo "    requirements satisfied" ;;
    esac
}

cmd_run() {
    load_catalog
    head2 "Meridian Retail — one business day, current catalog"
    local w p miss incidents=0
    for w in "${WORKLOADS[@]}"; do
        p="${CATALOG[$w]-}"
        if [[ -z "$p" ]]; then
            printf '%s[FAIL]%s %-20s %s\n' "$R" "$N" "$w" "no product assigned in the catalog"
            incidents=$((incidents + 1)); continue
        fi
        if [[ -z "${CAPS[$p]-}" ]]; then
            printf '%s[FAIL]%s %-20s unknown product %q\n' "$R" "$N" "$w" "$p"
            incidents=$((incidents + 1)); continue
        fi
        miss="$(missing_caps "$w" "$p")"
        if [[ -z "$miss" ]]; then
            printf '%s[ ok ]%s %-20s %s\n' "$G" "$N" "$w" "$p"
            healthy_for "$w" "$p"
        else
            incidents=$((incidents + 1))
            printf '%s[FAIL]%s %-20s %s\n' "$R" "$N" "$w" "$p"
            if ! symptom_for "$w" "$p"; then
                local tag
                for tag in $miss; do
                    printf '      missing: %-24s %s\n' "$tag" "${CAP_MEANING[$tag]-}"
                done
            fi
        fi
    done

    # The telemetry batch is the incident you can actually reproduce.
    head2 "Hourly telemetry batch"
    cmd_ingest || true

    rule
    if ((incidents == 0)); then
        say "${G}no incidents${N} — now confirm with: $BIN_DIR/dl-sim verify"
    else
        say "${R}$incidents workload(s) mis-assigned${N} — fix $CATALOG_FILE, then: $BIN_DIR/dl-sim verify"
    fi
}

# -----------------------------------------------------------------------------
# ingest: route the batch through whatever the catalog says
# -----------------------------------------------------------------------------
ingest_cloud_sql() {
    local pages err rc=0
    pages="$(storage_pages)"
    printf '  routing 1 h of shelf telemetry (%s rows) to cloud-sql\n' "$BATCH_ROWS"
    printf '  instance storage ceiling: %s pages x 4 KiB = %s KiB\n' "$pages" "$((pages * 4))"
    if ! have sqlite3; then
        printf '%s  ERROR (simulated, sqlite3 not installed):%s could not extend file: No space left on device\n' "$R" "$N"
        return 1
    fi
    set +e
    err="$(sqlite3 "$SQL_DB" <<SQL 2>&1
PRAGMA max_page_count = $pages;
BEGIN IMMEDIATE;
WITH RECURSIVE seq(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < $BATCH_ROWS)
INSERT INTO telemetry (device_id, ts, metric, value)
SELECT 'sensor-' || (i % 4000), 1757116800 + i, 'shelf_temp_c', 2.5 + (i % 70) / 10.0 FROM seq;
COMMIT;
SQL
)"
    rc=$?
    set -e
    if ((rc != 0)); then
        printf '%s  %s%s\n' "$R" "$err" "$N"
        cat <<'EOF'
  This is what a Cloud SQL instance out of storage looks like to the app:
      PostgreSQL: could not extend file "base/16384/24576": No space left on device
      MySQL:      ERROR 1114 (HY000): The table 'telemetry' is full
  The instance is flagged read-only until storage grows. Cloud SQL can raise it
  automatically ("automatic storage increase") — and note that Cloud SQL storage
  only ever grows: you cannot shrink it back afterwards.
EOF
        return 1
    fi
    printf '%s  batch committed to cloud-sql%s\n' "$G" "$N"
    return 0
}

ingest_bigtable() {
    printf '  routing 1 h of shelf telemetry (%s rows) to bigtable\n' "$BATCH_ROWS"
    awk -v n="$BATCH_ROWS" 'BEGIN {
        for (i = 1; i <= n; i++) {
            dev = sprintf("sensor-%04d", i % 4000);
            ts  = 1757116800 + i;
            printf "%s#%010d\tcf:shelf_temp_c\t%.1f\n", dev, 4102444800 - ts, 2.5 + (i % 70) / 10;
        }
    }' > "$BT_TABLE"
    local bytes; bytes="$(wc -c < "$BT_TABLE")"
    printf '%s  batch committed to bigtable%s (%s rows, %s bytes)\n' "$G" "$N" "$BATCH_ROWS" "$bytes"
    cat <<'EOF'
  row key: <device>#<reverse-timestamp>  — device first, so "this device, this
  time range" is one contiguous scan, and no single tablet takes every write.
  A key starting with the raw timestamp would send 100% of writes to one node:
  that is the classic Bigtable hotspot.
EOF
    return 0
}

cmd_ingest() {
    load_catalog
    local p="${CATALOG[iot-telemetry]-}"
    [[ -n "$p" ]] || die "iot-telemetry has no product assigned in the catalog"
    local rc=0
    case "$p" in
        cloud-sql)  ingest_cloud_sql || rc=$? ;;
        bigtable)   ingest_bigtable  || rc=$? ;;
        *)
            printf '%s  no ingest path for product %q%s\n' "$R" "$p" "$N"
            printf '  %s is not built for 1.2 M writes/s of time-series data.\n' "$p"
            rc=1 ;;
    esac
    if ((rc == 0)); then printf '%s\n' "$p" > "$INGEST_MARKER"; else rm -f "$INGEST_MARKER"; fi
    return "$rc"
}

# -----------------------------------------------------------------------------
# verify: the architecture review gate
# -----------------------------------------------------------------------------
cmd_verify() {
    load_catalog
    head2 "Architecture review"
    printf '%-20s %-24s %-6s %s\n' "WORKLOAD" "ASSIGNED PRODUCT" "COST" "VERDICT"
    rule
    local w p miss cost total=0 failures=0
    for w in "${WORKLOADS[@]}"; do
        p="${CATALOG[$w]-<unassigned>}"
        if [[ -z "${CAPS[$p]-}" ]]; then
            printf '%-20s %-24s %-6s %sunknown or unassigned product%s\n' "$w" "$p" "-" "$R" "$N"
            failures=$((failures + 1)); continue
        fi
        cost="$(cost_of "$w" "$p")"
        total="$(awk -v a="$total" -v b="$cost" 'BEGIN { printf "%.2f", a + b }')"
        miss="$(missing_caps "$w" "$p")"
        if [[ -z "$miss" ]]; then
            printf '%-20s %-24s %-6s %sPASS%s\n' "$w" "$p" "$cost" "$G" "$N"
        else
            failures=$((failures + 1))
            printf '%-20s %-24s %-6s %sFAIL%s\n' "$w" "$p" "$cost" "$R" "$N"
            local tag
            for tag in $miss; do
                printf '    %-26s %s\n' "requires $tag:" "${CAP_MEANING[$tag]-}"
            done
        fi
    done
    rule
    printf 'illustrative monthly cost: %s units (budget %s)\n' "$total" "$MONTHLY_BUDGET"
    local over; over="$(awk -v t="$total" -v b="$MONTHLY_BUDGET" 'BEGIN { print (t > b) ? "1" : "0" }')"
    if [[ "$over" == "1" ]]; then
        printf '%sover budget%s\n' "$R" "$N"; failures=$((failures + 1))
    fi

    local marker_product=""
    [[ -f "$INGEST_MARKER" ]] && marker_product="$(cat "$INGEST_MARKER")"
    if [[ -n "$marker_product" && "$marker_product" == "${CATALOG[iot-telemetry]-}" ]]; then
        printf '%stelemetry batch landed on %s%s\n' "$G" "$marker_product" "$N"
    else
        printf '%stelemetry batch has not landed on the currently assigned product%s — run: %s ingest\n' \
               "$R" "$N" "$BIN_DIR/dl-sim"
        failures=$((failures + 1))
    fi

    rule
    if ((failures == 0)); then
        printf '%sREVIEW PASSED.%s Every workload sits on a product that satisfies its\n' "$G" "$N"
        printf 'business requirements, the batch lands, and the platform is within budget.\n'
        return 0
    fi
    printf '%sREVIEW FAILED%s — %d finding(s). Edit %s\n' "$R" "$N" "$failures" "$CATALOG_FILE"
    return 1
}

# -----------------------------------------------------------------------------
# describe / catalog / hint / status / reset
# -----------------------------------------------------------------------------
cmd_describe() {
    local key="${1:-}"
    [[ -n "$key" ]] || die "usage: dl-sim describe <workload|product>"
    if [[ -n "${REQS[$key]-}" ]]; then
        head2 "workload: $key"
        printf '%s\n\n' "${DESC[$key]}"
        say "required capabilities:"
        local tag
        for tag in ${REQS[$key]}; do
            printf '  %-26s %s\n' "$tag" "${CAP_MEANING[$tag]-}"
        done
        printf '\n%scurrently assigned:%s ' "$D" "$N"
        load_catalog; printf '%s\n' "${CATALOG[$key]-<unassigned>}"
        return 0
    fi
    if [[ -n "${CAPS[$key]-}" ]]; then
        head2 "product: $key"
        printf '%s\n\n' "${FACTS[$key]-}"
        say "capabilities: ${CAPS[$key]}"
        printf 'unit price:   %s%s\n' "${PRICE[$key]-0}" \
            "$( [[ -n "${RETRIEVAL[$key]-}" ]] && printf ' + %s per unit retrieved' "${RETRIEVAL[$key]}" )"
        printf 'docs:         %s\n' "${DOCS[$key]-}"
        return 0
    fi
    die "unknown workload or product: $key   (try: dl-sim catalog)"
}

cmd_catalog() {
    load_catalog
    head2 "Workloads, their business need and their requirement tags"
    local w
    for w in "${WORKLOADS[@]}"; do
        printf '\n%s%s%s  ->  %s\n' "$B" "$w" "$N" "${CATALOG[$w]-<unassigned>}"
        printf '  %s\n' "${DESC[$w]}"
        printf '  requires: %s\n' "${REQS[$w]}"
    done
    printf '\n%savailable products:%s cloud-sql alloydb spanner bigtable firestore bigquery\n' "$D" "$N"
    printf '  memorystore filestore cloud-storage:{standard,nearline,coldline,archive}\n'
    printf '  pub-sub datastream storage-transfer dataflow dataproc looker looker-studio\n'
}

cmd_hint() {
    case "${1:-1}" in
      1) cat <<'EOF'

HINT 1 — read the requirement, not the product name.
  For each failing workload, run `dl-sim describe <workload>` and look at the
  ONE tag that no current product provides. Four of them are decided by a
  single word in the business description:
    * "a store in Frankfurt must read what Sao Paulo committed"  -> consistency
      model across regions, with SQL transactions.
    * "existing application built on MySQL 8, moving unchanged"  -> wire protocol
      compatibility, not merely 'relational'.
    * "1.2 M writes/s, 400 TB, this device this time range, p99 < 10 ms" -> that
      is a wide-column NoSQL access pattern, not a relational one.
    * "works with no signal, syncs later, updates live on the phone" -> a database
      with a mobile SDK, offline persistence and realtime listeners.
EOF
        ;;
      2) cat <<'EOF'

HINT 2 — the two quiet ones and the one that looks free.
  * Storage classes are chosen by ACCESS FREQUENCY, not by size. Standard has no
    retrieval fee and no minimum storage duration; Archive has a 365-day minimum
    and the highest retrieval fee. Hot images and 7-year receipts therefore do
    NOT belong in the same class — one of the two is currently wrong.
  * Copying objects on a schedule is not change data capture. For continuous,
    low-impact replication out of Oracle into BigQuery there is a product that
    reads the source's transaction log.
  * Self-serve dashboards are not governance. When "everyone must see the same
    net revenue" and "each supplier sees only their rows" are requirements, you
    need a semantic model with row-level security.
  * Note the trap: the broken platform is CHEAPER than the correct one. Cheap and
    wrong is still wrong; cost is a constraint, never the requirement.
EOF
        ;;
      *) cat <<'EOF'

HINT 3 — nearly the answer.
  Products that satisfy each failing workload:
    pos-ledger        relational + horizontal + globally strongly consistent  -> Spanner
    store-catalog     managed MySQL, regional HA, PITR                        -> Cloud SQL
    iot-telemetry     wide-column, petabyte, <10 ms p99, key-range scans      -> Bigtable
    mobile-app-state  document + mobile SDK + offline sync + listeners        -> Firestore
    product-images    hot reads, no retrieval fee, no minimum duration        -> cloud-storage:standard
    oracle-cdc        log-based CDC, Oracle source, BigQuery sink             -> Datastream
    exec-dashboards   governed semantic model + row-level security            -> Looker
  Leave sales-analytics, session-cache, receipt-archive and clickstream-ingest
  alone: they were already right. Then re-run `dl-sim ingest` so the telemetry
  batch lands on its NEW home, and `dl-sim verify`.
EOF
        ;;
    esac
}

cmd_status() {
    load_catalog
    head2 "Lab status"
    printf 'lab root:            %s\n' "$LAB_ROOT"
    printf 'catalog:             %s\n' "$CATALOG_FILE"
    printf 'cloud-sql storage:   %s pages (%s KiB)\n' "$(storage_pages)" "$(( $(storage_pages) * 4 ))"
    printf 'sqlite3 available:   %s\n' "$(have sqlite3 && echo yes || echo no)"
    printf 'last ingest landed:  %s\n' "$( [[ -f "$INGEST_MARKER" ]] && cat "$INGEST_MARKER" || echo none )"
    printf 'disk used by lab:    %s\n' "$(du -sh "$LAB_ROOT" 2>/dev/null | cut -f1)"
}

cmd_reset() {
    [[ -d "$LAB_ROOT" ]] || { say "nothing to remove at $LAB_ROOT"; return 0; }
    [[ -f "$LAB_ROOT/.lab-marker" ]] || die "refusing to delete $LAB_ROOT: no lab marker file there"
    [[ "$(cat "$LAB_ROOT/.lab-marker")" == "$LAB_TAG" ]] || die "refusing: marker mismatch in $LAB_ROOT"
    case "$LAB_ROOT" in
        /|"$HOME"|"") die "refusing to delete $LAB_ROOT" ;;
    esac
    rm -rf -- "$LAB_ROOT"
    say "removed $LAB_ROOT — the host is exactly as it was."
}

usage() {
    sed -n '2,60p' "$SELF" | sed 's/^#\{1,2\} \{0,1\}//;s/^#$//'
}

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        setup|install)  cmd_setup "$@" ;;
        run|simulate)   cmd_run ;;
        verify|review)  cmd_verify ;;
        ingest)         cmd_ingest ;;
        describe|show)  cmd_describe "$@" ;;
        catalog|ls)     cmd_catalog ;;
        hint)           cmd_hint "$@" ;;
        status)         cmd_status ;;
        reset|clean)    cmd_reset ;;
        help|-h|--help) usage ;;
        *)              die "unknown command: $cmd (try: help)" ;;
    esac
}

main "$@"

# =============================================================================
#  SOLUTION — do not read until you have made `dl-sim verify` fail on your own
# =============================================================================
#
#  STEP 0 — see the failures and read the requirements, not the product names.
#
#      $LAB_ROOT/bin/dl-sim run
#      $LAB_ROOT/bin/dl-sim catalog
#      $LAB_ROOT/bin/dl-sim describe pos-ledger
#      $LAB_ROOT/bin/dl-sim describe spanner
#
#  STEP 1 — repair the incident you can reproduce (the stopgap, not the fix).
#
#  The telemetry ingest fails with a genuine SQLITE_FULL, which is the local
#  stand-in for a Cloud SQL instance that ran out of storage and went read-only.
#  The operational stopgap is to grow the disk:
#
#      echo 8192 > $STATE_DIR/cloudsql_storage_pages    # 32 MiB "instance"
#      $LAB_ROOT/bin/dl-sim ingest                      # now it commits
#
#  In Cloud SQL this is "increase storage" / "enable automatic storage increase"
#  (https://cloud.google.com/sql/docs/mysql/instance-settings). Two things to
#  internalise: the increase is one-way — Cloud SQL storage never shrinks — and
#  it buys hours, not a design. 400 TB of time-series at 1.2 M writes/s is not a
#  Cloud SQL workload at any disk size. Growing the disk closed the ticket and
#  left the architecture wrong, which is precisely how the platform got here.
#
#  STEP 2 — fix the catalog. Edit $CATALOG_FILE so the workloads block reads:
#
#      workloads:
#        pos-ledger:          spanner
#        store-catalog:       cloud-sql
#        iot-telemetry:       bigtable
#        mobile-app-state:    firestore
#        sales-analytics:     bigquery
#        session-cache:       memorystore
#        product-images:      cloud-storage:standard
#        receipt-archive:     cloud-storage:archive
#        clickstream-ingest:  pub-sub
#        oracle-cdc:          datastream
#        exec-dashboards:     looker
#
#  Or non-interactively:
#
#      cd "$LAB_ROOT/platform"
#      cp catalog.yaml catalog.yaml.bak
#      sed -i -e 's/^\(  pos-ledger: *\).*/\1spanner/' \
#             -e 's/^\(  store-catalog: *\).*/\1cloud-sql/' \
#             -e 's/^\(  iot-telemetry: *\).*/\1bigtable/' \
#             -e 's/^\(  mobile-app-state: *\).*/\1firestore/' \
#             -e 's/^\(  product-images: *\).*/\1cloud-storage:standard/' \
#             -e 's/^\(  oracle-cdc: *\).*/\1datastream/' \
#             -e 's/^\(  exec-dashboards: *\).*/\1looker/' catalog.yaml
#
#  STEP 3 — replay the batch through its NEW home and re-run the review.
#
#      $LAB_ROOT/bin/dl-sim ingest     # now routed to Bigtable; writes the rows
#      $LAB_ROOT/bin/dl-sim run        # a clean business day
#      $LAB_ROOT/bin/dl-sim verify     # REVIEW PASSED, exit 0
#
#  STEP 4 — the reasoning, which is the only thing the exam actually tests.
#  For each workload, the single deciding requirement:
#
#   pos-ledger -> Spanner
#     Relational + ACID across more than one row + strongly consistent across
#     regions + horizontal scale + 99.999%. Cloud SQL gives you the first two
#     but scales vertically in one region; BigQuery is an analytics warehouse
#     whose recently streamed rows cannot be mutated at all. Only Spanner has
#     external consistency (TrueTime) with a relational, transactional API.
#     https://cloud.google.com/spanner/docs
#
#   store-catalog -> Cloud SQL
#     "Existing MySQL 8 application, moving unchanged" is a wire-protocol
#     requirement, not merely a relational one. Spanner offers GoogleSQL and a
#     PostgreSQL dialect — the MySQL driver never connects. It is also ~7x the
#     cost here for 4 TB in one region. AlloyDB would be the answer if the
#     source were PostgreSQL and needed more throughput or in-place analytics.
#     https://cloud.google.com/sql/docs
#
#   iot-telemetry -> Bigtable
#     1.2 M writes/s, 400 TB, single-digit-ms p99, and every query is "this
#     device, this time range" — a contiguous key-range scan over a wide-column
#     store. Design the row key <device>#<reverse-timestamp>: device first so
#     scans are contiguous, and never a bare timestamp prefix, which would send
#     every write to one tablet (the classic hotspot).
#     https://cloud.google.com/bigtable/docs
#
#   mobile-app-state -> Firestore
#     Offline persistence, background sync and realtime listeners come from the
#     mobile SDK talking to the database directly, with Security Rules instead
#     of a bespoke API tier. Memorystore is a cache: no SDK, no durability, and
#     an eviction policy that is allowed to drop your users' baskets.
#     https://cloud.google.com/firestore/docs
#
#   sales-analytics -> BigQuery (already correct — resist changing it)
#     900 TB of ad-hoc SQL, models trained where the data already is (BigQuery
#     ML), BI connectors, no cluster to size. https://cloud.google.com/bigquery/docs
#
#   session-cache -> Memorystore (already correct)
#     Sub-millisecond, rebuildable from the system of record. Volatility is an
#     accepted property here, not a defect.
#
#   product-images -> Cloud Storage STANDARD
#     Storage class follows ACCESS FREQUENCY. Archive is the cheapest per byte
#     at rest and the most expensive to read, with a 365-day minimum storage
#     duration: hot storefront images pay a retrieval charge on every view and
#     an early-delete charge on every seasonal cleanup. If the access pattern is
#     genuinely unknown or changes over time, enable Autoclass and let the bucket
#     move objects between classes for you.
#     https://cloud.google.com/storage/docs/storage-classes
#     https://cloud.google.com/storage/docs/autoclass
#
#   receipt-archive -> Cloud Storage ARCHIVE (already correct)
#     Written once, read almost never, kept 7 years. This is the access pattern
#     Archive exists for — the same class, correct here and wrong for images.
#     Pair it with a retention policy / Object Lock for the audit requirement.
#
#   clickstream-ingest -> Pub/Sub (already correct)
#     A 40x spike absorbed by a global, serverless buffer, five independent
#     subscriptions, producers never blocked on consumers. Pub/Sub is the front
#     door; Dataflow transforms the stream; BigQuery stores it for analysis.
#     https://cloud.google.com/pubsub/docs
#
#   oracle-cdc -> Datastream
#     "Continuously, within minutes, without polling the ERP" = log-based change
#     data capture. Storage Transfer Service copies objects and files on a
#     schedule; it has no reader for Oracle redo logs. Datastream is serverless
#     CDC with a native BigQuery destination.
#     https://cloud.google.com/datastream/docs
#
#   exec-dashboards -> Looker
#     "Every team sees the same net revenue" is a governance requirement: one
#     LookML semantic model, one metric definition, row-level security by
#     supplier, and an embedding API for the portal. Looker Studio is excellent
#     for fast self-serve reporting and is exactly why the three numbers
#     disagreed — every report carried its own definition.
#     https://cloud.google.com/looker/docs
#
#  STEP 5 — the lesson the bill teaches.
#  The broken platform costs ~632 illustrative units; the correct one ~860. The
#  wrong architecture was CHEAPER, passed a naive budget check, and still lost
#  payments, blocked a migration, dropped user data and shipped three different
#  revenue figures to the board. Cost is a constraint you satisfy after the
#  requirements are met, never the criterion you select on. The mirror-image
#  error is just as expensive: Spanner for a 4 TB single-region MySQL app is
#  seven times the price of the product that actually fits.
#
#  STEP 6 — leave the VM as you found it.
#
#      $LAB_ROOT/bin/dl-sim reset
#
#  Source for the objective and its wording:
#  https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
# =============================================================================