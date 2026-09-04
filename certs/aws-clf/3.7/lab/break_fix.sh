#!/usr/bin/env bash
#
# =============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) - Domain 3, Task 3.7
#  "Identify AWS artificial intelligence and machine learning (AI/ML) services
#   and analytics services"                              (exam weight: 4.25 %)
#
#  BREAK & FIX LAB - clickstream analytics pipeline + review sentiment step
#
#  Exam guide:
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It builds a self-contained, OFFLINE emulation of a small AWS analytics stack
#  on a disposable lab VM, and then breaks it in four places that map 1:1 to
#  real production incidents:
#
#      Amazon Data Firehose  ->  Amazon S3 (data lake)
#                                     |
#                            AWS Glue Data Catalog (schema + partitions)
#                                     |
#                            Amazon Athena (serverless SQL over S3)
#                                     |
#                            Amazon Comprehend (NLP on customer reviews)
#
#  NOTHING outside $LAB_ROOT is touched. No network calls, no AWS account, no
#  credentials, no cost. Every command the student types is the real AWS CLI v2
#  syntax; only the transport is emulated, so muscle memory transfers 1:1.
#
#  Requirements: bash >= 4, python3 (JSON handling), coreutils.
#  Usage:
#      ./clf37-break-and-fix.sh            # build + break the lab
#      ./clf37-break-and-fix.sh --reset    # re-break an already fixed lab
#      ./clf37-break-and-fix.sh --brief    # reprint the mission brief
#      ./clf37-break-and-fix.sh --clean    # delete the lab directory
#
#  The full, step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not read it until clf37-verify has beaten you at least twice.
# =============================================================================

set -euo pipefail
umask 022

LAB_ROOT="${CLF_LAB_ROOT:-$HOME/aws-clf-lab/topic-3.7}"
LAB_MARKER="$LAB_ROOT/.clf37-lab"
ASSUME_YES=0
ACTION="build"

# -----------------------------------------------------------------------------
# 0. Argument parsing and safety guards
# -----------------------------------------------------------------------------
for a in "$@"; do
  case "$a" in
    --yes|-y)  ASSUME_YES=1 ;;
    --reset)   ACTION="reset" ;;
    --brief)   ACTION="brief" ;;
    --clean)   ACTION="clean" ;;
    --help|-h) ACTION="help" ;;
    *) printf 'unknown option: %s (try --help)\n' "$a" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
head1() { printf '\n=== %s ===\n' "$*"; }

confirm() {
  # The lab is harmless (everything lives under $LAB_ROOT), but a break & fix
  # exercise should still make you state out loud that this is a throwaway VM.
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ ! -t 0 ]; then
    say "Non-interactive shell: re-run with --yes to confirm this is a disposable lab VM." >&2
    exit 1
  fi
  printf 'This will create/overwrite the lab under: %s\nProceed? [y/N] ' "$LAB_ROOT"
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) say "aborted."; exit 1 ;; esac
}

if [ "$ACTION" = "help" ]; then
  sed -n '2,40p' "$0"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { say "python3 is required for this lab." >&2; exit 1; }

if [ "$ACTION" = "clean" ]; then
  case "$LAB_ROOT" in
    */aws-clf-lab/topic-3.7) : ;;
    *) say "refusing to delete an unexpected LAB_ROOT: $LAB_ROOT" >&2; exit 1 ;;
  esac
  [ -f "$LAB_MARKER" ] || { say "no lab marker at $LAB_MARKER - refusing to delete." >&2; exit 1; }
  rm -rf -- "$LAB_ROOT"
  say "removed $LAB_ROOT"
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. Directory layout
#    .cloud/  = "the AWS side". Reachable only through the CLI, like a real
#               managed service. Peeking is allowed, but the exercise is to
#               diagnose it with the CLI.
#    work/    = "your workstation". Scripts and policy documents you own.
# -----------------------------------------------------------------------------
build_tree() {
  mkdir -p "$LAB_ROOT"/bin
  mkdir -p "$LAB_ROOT"/.cloud/{s3,glue/analytics_db,glue/crawlers,iam,firehose,state/queries}
  mkdir -p "$LAB_ROOT"/work/out
  : > "$LAB_MARKER"
}

# -----------------------------------------------------------------------------
# 2. Seed the "S3 data lake" - 512 Hive-partitioned clickstream events
#    Amazon S3 is the storage layer of every AWS data lake; Athena, Glue, EMR,
#    Redshift Spectrum and QuickSight all read from it.
#    https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
# -----------------------------------------------------------------------------
seed_s3() {
  python3 - "$LAB_ROOT" <<'PY'
import json, os, sys
root = sys.argv[1]
bucket = os.path.join(root, ".cloud", "s3", "clf-lab-datalake")
dates = ["2026-09-02", "2026-09-03", "2026-09-04"]
skus = ["SKU-1001", "SKU-1002", "SKU-1003", "SKU-1004"]
types = {1: "purchase", 2: "page_view", 3: "add_to_cart", 0: "checkout_start"}
part = {d: [] for d in dates}
total, purchases = 512, 0
for i in range(1, total + 1):
    et = types[i % 4]
    if et == "purchase":
        purchases += 1
    d = dates[i % 3]
    rec = {
        "event_id":   "evt-%06d" % i,
        "user_id":    "u-%04d" % (i % 97 + 1),
        "event_type": et,
        "item_sku":   skus[i % 4],
        "amount_usd": round(19.99 + (i % 37) * 3.5, 2) if et == "purchase" else 0.0,
        "event_time": d + "T%02d:%02d:%02dZ" % (i % 24, i % 60, (i * 7) % 60),
    }
    part[d].append(json.dumps(rec))
for d in dates:
    p = os.path.join(bucket, "raw", "clickstream", "dt=" + d)
    os.makedirs(p, exist_ok=True)
    with open(os.path.join(p, "part-00000.json"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(part[d]) + "\n")
os.makedirs(os.path.join(bucket, "athena-results"), exist_ok=True)
with open(os.path.join(root, ".cloud", "state", "expected.json"), "w", encoding="utf-8") as fh:
    json.dump({"total_events": total, "purchase_events": purchases,
               "partitions": dates, "delivery_prefix": "raw/clickstream/"}, fh, indent=2)
PY
}

# -----------------------------------------------------------------------------
# 3. Cloud-side control plane objects
# -----------------------------------------------------------------------------
seed_cloud_objects() {

  # --- Amazon Data Firehose (formerly Kinesis Data Firehose): the managed
  #     streaming delivery stream that lands raw events in S3. Its destination
  #     prefix is the ground truth of where the data really is.
  #     https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html
  cat > "$LAB_ROOT/.cloud/firehose/clf-lab-clickstream.json" <<'JSON'
{
  "DeliveryStreamDescription": {
    "DeliveryStreamName": "clf-lab-clickstream",
    "DeliveryStreamARN": "arn:aws:firehose:us-east-1:123456789012:deliverystream/clf-lab-clickstream",
    "DeliveryStreamStatus": "ACTIVE",
    "DeliveryStreamType": "DirectPut",
    "Destinations": [
      {
        "DestinationId": "destinationId-000000000001",
        "ExtendedS3DestinationDescription": {
          "RoleARN": "arn:aws:iam::123456789012:role/service-role/KinesisFirehoseServiceRole-clf-lab",
          "BucketARN": "arn:aws:s3:::clf-lab-datalake",
          "Prefix": "raw/clickstream/dt=!{timestamp:yyyy-MM-dd}/",
          "ErrorOutputPrefix": "errors/clickstream/",
          "CompressionFormat": "UNCOMPRESSED",
          "BufferingHints": { "SizeInMBs": 5, "IntervalInSeconds": 60 }
        }
      }
    ]
  }
}
JSON

  # --- AWS Glue Data Catalog table  <<< BREAK #1, #2 and #3 LIVE HERE >>>
  #     The catalog is the Hive-compatible metastore Athena, EMR, Redshift
  #     Spectrum and QuickSight all read schema from.
  #     https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html
  #
  #     Fault A: Location points at a decommissioned prefix (clickstream-v1).
  #     Fault B: no partitions are registered for a partitioned table.
  #     Fault C: the SerDe says CSV (LazySimpleSerDe) but the objects are JSON.
  cat > "$LAB_ROOT/.cloud/glue/analytics_db/clickstream.json" <<'JSON'
{
  "Table": {
    "Name": "clickstream",
    "DatabaseName": "analytics_db",
    "Owner": "hadoop",
    "CreateTime": "2026-08-29T11:04:12+00:00",
    "CreatedBy": "arn:aws:iam::123456789012:user/clf-lab-analyst",
    "TableType": "EXTERNAL_TABLE",
    "Parameters": {
      "classification": "csv",
      "EXTERNAL": "TRUE",
      "comment": "migrated from the v1 delivery stream on 2026-08-29"
    },
    "PartitionKeys": [
      { "Name": "dt", "Type": "string" }
    ],
    "StorageDescriptor": {
      "Columns": [
        { "Name": "event_id",   "Type": "string" },
        { "Name": "user_id",    "Type": "string" },
        { "Name": "event_type", "Type": "string" },
        { "Name": "item_sku",   "Type": "string" },
        { "Name": "amount_usd", "Type": "double" },
        { "Name": "event_time", "Type": "string" }
      ],
      "Location": "s3://clf-lab-datalake/raw/clickstream-v1/",
      "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
      "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
      "Compressed": false,
      "SerdeInfo": {
        "SerializationLibrary": "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe",
        "Parameters": { "field.delim": "," }
      }
    }
  }
}
JSON

  printf '{ "Partitions": [] }\n' > "$LAB_ROOT/.cloud/glue/analytics_db/clickstream.partitions.json"

  # --- AWS Glue crawler, correctly configured against the REAL prefix.
  #     Running it is the "one shot" repair path: a crawler infers schema,
  #     classification and partitions from the objects themselves.
  cat > "$LAB_ROOT/.cloud/glue/crawlers/clf-lab-clickstream-crawler.json" <<'JSON'
{
  "Crawler": {
    "Name": "clf-lab-clickstream-crawler",
    "Role": "service-role/AWSGlueServiceRole-clf-lab",
    "DatabaseName": "analytics_db",
    "Targets": { "S3Targets": [ { "Path": "s3://clf-lab-datalake/raw/clickstream/" } ] },
    "State": "READY",
    "SchemaChangePolicy": { "UpdateBehavior": "UPDATE_IN_DATABASE", "DeleteBehavior": "LOG" },
    "LastCrawl": { "Status": "NEVER_RUN" }
  }
}
JSON

  # --- IAM inline policy  <<< BREAK #4 (part 1) LIVE HERE >>>
  #     Copied from the old image-moderation pipeline, so it grants
  #     rekognition:DetectLabels (useless here) and NOT comprehend:DetectSentiment.
  cat > "$LAB_ROOT/.cloud/iam/clf-lab-analyst.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LakeRead",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::clf-lab-datalake",
        "arn:aws:s3:::clf-lab-datalake/*"
      ]
    },
    {
      "Sid": "CatalogAndQuery",
      "Effect": "Allow",
      "Action": [
        "glue:GetTable",
        "glue:UpdateTable",
        "glue:GetPartitions",
        "glue:BatchCreatePartition",
        "glue:GetCrawler",
        "glue:StartCrawler",
        "athena:StartQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "firehose:DescribeDeliveryStream"
      ],
      "Resource": "*"
    },
    {
      "Sid": "InheritedFromImageModerationPipeline",
      "Effect": "Allow",
      "Action": [
        "rekognition:DetectLabels",
        "rekognition:DetectModerationLabels"
      ],
      "Resource": "*"
    }
  ]
}
JSON

  # The student's editable working copy (uploaded later with put-user-policy).
  cp "$LAB_ROOT/.cloud/iam/clf-lab-analyst.json" "$LAB_ROOT/work/analyst-policy.json"
}

# -----------------------------------------------------------------------------
# 4. Workstation-side files
# -----------------------------------------------------------------------------
seed_workstation() {

  cat > "$LAB_ROOT/work/reviews.txt" <<'TXT'
The checkout was fast and the tracking updates were perfect, I would recommend this store.
Package arrived broke in two places and support never answered my refund request.
It works, nothing else to say about it.
Great build quality, though the shipping was terrible and slow.
Worst experience of the year, the item fails after ten minutes of use.
I love it, setup was smooth and the app is excellent.
The invoice was issued on the third of September.
Disappointed with the battery, but the screen is great.
TXT

  # --- The nightly enrichment step  <<< BREAK #4 (part 2) LIVE HERE >>>
  #     It calls the wrong AI service for the modality: Amazon Rekognition
  #     analyses images and video, not free-form text.
  cat > "$LAB_ROOT/work/enrich.sh" <<'SH'
#!/usr/bin/env bash
# Nightly customer-review enrichment step.
# Reads work/reviews.txt and writes one JSON object per review to
# work/out/sentiment.jsonl, to be loaded into the BI dataset.
set -euo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$LAB_ROOT/bin:$PATH"

IN="$LAB_ROOT/work/reviews.txt"
OUT="$LAB_ROOT/work/out/sentiment.jsonl"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

n=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  aws rekognition detect-labels --image "Bytes=$line" --max-labels 5 >> "$OUT"
  n=$((n + 1))
done < "$IN"

echo "enriched $n reviews -> $OUT"
SH
  chmod +x "$LAB_ROOT/work/enrich.sh"
}

# -----------------------------------------------------------------------------
# 5. The offline AWS CLI emulator ($LAB_ROOT/bin/aws)
#    Supported: sts, s3, glue, athena, firehose, comprehend, rekognition, iam.
#    Syntax, output shapes and error codes follow AWS CLI v2 (service errors
#    exit 254, argument errors exit 252).
# -----------------------------------------------------------------------------
install_cli() {
  cat > "$LAB_ROOT/bin/aws" <<'SHIM'
#!/usr/bin/env bash
# Offline emulator of a subset of AWS CLI v2 for the CLF-C02 3.7 lab.
# On a real VM with credentials, the very same command lines hit the real APIs.
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUD="$LAB_ROOT/.cloud"
S3_ROOT="$CLOUD/s3"
GLUE_DB="$CLOUD/glue/analytics_db"
CRAWLERS="$CLOUD/glue/crawlers"
LIVE_POLICY="$CLOUD/iam/clf-lab-analyst.json"
QSTATE="$CLOUD/state/queries"
ACCOUNT_ID="123456789012"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PRINCIPAL="arn:aws:iam::$ACCOUNT_ID:user/clf-lab-analyst"
mkdir -p "$QSTATE"

svc_error() { printf 'An error occurred (%s) when calling the %s operation: %s\n' "$1" "$2" "$3" >&2; exit 254; }
arg_error() { printf 'aws: error: %s\n' "$1" >&2; exit 252; }

arg() { # arg --flag "$@"
  local want="$1"; shift
  while [ $# -gt 0 ]; do
    [ "$1" = "$want" ] && { printf '%s' "${2:-}"; return 0; }
    case "$1" in "$want"=*) printf '%s' "${1#*=}"; return 0 ;; esac
    shift
  done
  return 1
}

allowed() { # allowed <iam:Action>
  python3 - "$LIVE_POLICY" "$1" <<'PY'
import json, sys
pol = json.load(open(sys.argv[1])); want = sys.argv[2]; ok = False
for st in pol.get("Statement", []):
    if st.get("Effect") != "Allow":
        continue
    acts = st.get("Action", [])
    acts = [acts] if isinstance(acts, str) else acts
    for a in acts:
        if a == want or a == "*" or (a.endswith(":*") and want.startswith(a[:-1])):
            ok = True
print("yes" if ok else "no")
PY
}

deny() { # deny <iam:Action> <ApiName>
  if [ "$(allowed "$1")" != "yes" ]; then
    svc_error "AccessDeniedException" "$2" \
      "User: $PRINCIPAL is not authorized to perform: $1 because no identity-based policy allows the $1 action"
  fi
}

s3_path() { # s3://bucket/key -> filesystem path
  local u="${1#s3://}"
  printf '%s' "$S3_ROOT/${u%/}"
}

SERVICE="${1:-}"; OP="${2:-}"
[ -n "$SERVICE" ] && [ -n "$OP" ] || arg_error "usage: aws <service> <operation> [parameters]"
shift 2
OUTFMT="$(arg --output "$@" || printf 'json')"

case "$SERVICE:$OP" in

  sts:get-caller-identity)
    printf '{\n    "UserId": "AIDACKCEVSQ6C2EXAMPLE",\n    "Account": "%s",\n    "Arn": "%s"\n}\n' "$ACCOUNT_ID" "$PRINCIPAL"
    ;;

  s3:ls)
    deny "s3:ListBucket" "ListObjectsV2"
    target="${1:-}"; [ -n "$target" ] || arg_error "the following arguments are required: paths"
    base="$(s3_path "$target")"
    if [ ! -e "$base" ]; then exit 0; fi
    if printf '%s\n' "$@" | grep -q -- '--recursive'; then
      find "$base" -type f | sort | while read -r f; do
        printf '%s %10s %s\n' "$(date -u -r "$f" '+%Y-%m-%d %H:%M:%S')" "$(stat -c %s "$f")" \
          "s3://${target#s3://}"
      done | sed 's| s3://.*||' > /dev/null
      find "$base" -type f | sort | while read -r f; do
        rel="${f#$S3_ROOT/}"
        printf '%s %10s %s\n' "$(date -u -r "$f" '+%Y-%m-%d %H:%M:%S')" "$(stat -c %s "$f")" "$rel"
      done
    else
      [ -d "$base" ] && ls -1 "$base" | sort | while read -r e; do
        if [ -d "$base/$e" ]; then printf '                           PRE %s/\n' "$e"
        else printf '%s %10s %s\n' "$(date -u -r "$base/$e" '+%Y-%m-%d %H:%M:%S')" "$(stat -c %s "$base/$e")" "$e"; fi
      done
    fi
    ;;

  s3:cp)
    deny "s3:GetObject" "GetObject"
    src="${1:-}"; dst="${2:-}"
    f="$(s3_path "$src")"
    [ -f "$f" ] || svc_error "NoSuchKey" "GetObject" "The specified key does not exist."
    if [ "$dst" = "-" ]; then cat "$f"; else cp "$f" "$dst"; printf 'download: %s to %s\n' "$src" "$dst"; fi
    ;;

  glue:get-table)
    deny "glue:GetTable" "GetTable"
    db="$(arg --database-name "$@" || printf '')"; name="$(arg --name "$@" || printf '')"
    [ "$db" = "analytics_db" ] || svc_error "EntityNotFoundException" "GetTable" "Database $db not found."
    [ -f "$GLUE_DB/$name.json" ] || svc_error "EntityNotFoundException" "GetTable" "Table $name not found."
    cat "$GLUE_DB/$name.json"
    ;;

  glue:update-table)
    deny "glue:UpdateTable" "UpdateTable"
    db="$(arg --database-name "$@" || printf '')"
    ti="$(arg --table-input "$@" || printf '')"
    [ -n "$ti" ] || arg_error "the following arguments are required: --table-input"
    case "$ti" in file://*) doc="${ti#file://}" ;; *) doc="" ;; esac
    [ -n "$doc" ] && [ -f "$doc" ] || arg_error "--table-input must be file://<path> pointing to a readable JSON document"
    python3 - "$doc" "$GLUE_DB" "$db" <<'PY'
import json, os, sys
doc, gluedb, db = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(doc))
wrapped = "Table" in d
t = d["Table"] if wrapped else d
readonly = ("CreateTime", "UpdateTime", "CreatedBy", "DatabaseName", "CatalogId",
            "VersionId", "IsRegisteredWithLakeFormation")
for k in readonly:
    t.pop(k, None)
t["DatabaseName"] = db
json.dump({"Table": t}, open(os.path.join(gluedb, t["Name"] + ".json"), "w"), indent=2)
if wrapped:
    sys.stderr.write("lab note: your document was a get-table response; read-only fields were stripped. "
                     "The real API expects only the TableInput structure - see "
                     "https://docs.aws.amazon.com/glue/latest/webapi/API_UpdateTable.html\n")
PY
    ;;

  glue:get-partitions)
    deny "glue:GetPartitions" "GetPartitions"
    name="$(arg --table-name "$@" || printf '')"
    cat "$GLUE_DB/$name.partitions.json"
    ;;

  glue:get-crawler)
    deny "glue:GetCrawler" "GetCrawler"
    name="$(arg --name "$@" || printf '')"
    [ -f "$CRAWLERS/$name.json" ] || svc_error "EntityNotFoundException" "GetCrawler" "Crawler $name not found."
    cat "$CRAWLERS/$name.json"
    ;;

  glue:start-crawler)
    deny "glue:StartCrawler" "StartCrawler"
    name="$(arg --name "$@" || printf '')"
    [ -f "$CRAWLERS/$name.json" ] || svc_error "EntityNotFoundException" "StartCrawler" "Crawler $name not found."
    python3 - "$CRAWLERS/$name.json" "$GLUE_DB" "$S3_ROOT" <<'PY'
import glob, json, os, sys
crawler_file, gluedb, s3root = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(crawler_file))["Crawler"]
path = c["Targets"]["S3Targets"][0]["Path"]
fs = os.path.join(s3root, path[5:].rstrip("/"))
table = os.path.basename(fs)
files = sorted(f for f in glob.glob(os.path.join(fs, "**", "*"), recursive=True) if os.path.isfile(f))
if not files:
    c["LastCrawl"] = {"Status": "SUCCEEDED", "MessagePrefix": "no objects found at target"}
    json.dump({"Crawler": c}, open(crawler_file, "w"), indent=2)
    sys.exit(0)
first = open(files[0], encoding="utf-8").readline()
obj = json.loads(first)
types = {str: "string", int: "bigint", float: "double", bool: "boolean"}
cols = [{"Name": k, "Type": types.get(type(v), "string")} for k, v in obj.items()]
pkeys, parts = [], []
for f in files:
    rel = os.path.relpath(os.path.dirname(f), fs)
    if rel == ".":
        continue
    kvs = [seg.split("=", 1) for seg in rel.split(os.sep) if "=" in seg]
    if not kvs:
        continue
    if not pkeys:
        pkeys = [{"Name": k, "Type": "string"} for k, _ in kvs]
    spec = {"Values": [v for _, v in kvs],
            "StorageDescriptor": {"Location": path.rstrip("/") + "/" + rel.replace(os.sep, "/") + "/"}}
    if spec not in parts:
        parts.append(spec)
tbl = {"Table": {
    "Name": table, "DatabaseName": c["DatabaseName"], "Owner": "hadoop",
    "TableType": "EXTERNAL_TABLE",
    "Parameters": {"classification": "json", "EXTERNAL": "TRUE",
                   "comment": "rebuilt by crawler " + c["Name"]},
    "PartitionKeys": pkeys,
    "StorageDescriptor": {
        "Columns": cols, "Location": path,
        "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
        "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
        "Compressed": False,
        "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe",
                      "Parameters": {"paths": ",".join(k["Name"] for k in cols)}}}}}
json.dump(tbl, open(os.path.join(gluedb, table + ".json"), "w"), indent=2)
json.dump({"Partitions": parts}, open(os.path.join(gluedb, table + ".partitions.json"), "w"), indent=2)
c["State"] = "READY"
c["LastCrawl"] = {"Status": "SUCCEEDED", "TablesCreated": 0, "TablesUpdated": 1,
                  "PartitionsCreated": len(parts)}
json.dump({"Crawler": c}, open(crawler_file, "w"), indent=2)
sys.stderr.write("lab note: the crawler ran synchronously here; in AWS it is asynchronous - "
                 "poll it with 'aws glue get-crawler --name %s'.\n" % c["Name"])
PY
    ;;

  athena:start-query-execution)
    deny "athena:StartQueryExecution" "StartQueryExecution"
    q="$(arg --query-string "$@" || printf '')"
    [ -n "$q" ] || arg_error "the following arguments are required: --query-string"
    ctx="$(arg --query-execution-context "$@" || printf 'Database=analytics_db')"
    db="$(printf '%s' "$ctx" | sed -n 's/.*Database=\([A-Za-z0-9_]*\).*/\1/p')"
    [ -n "$db" ] || db="analytics_db"
    rc="$(arg --result-configuration "$@" || printf '')"
    out="$(printf '%s' "$rc" | sed -n 's/.*OutputLocation=\([^, ]*\).*/\1/p')"
    case "$q" in *[Mm][Ss][Cc][Kk]*) deny "glue:BatchCreatePartition" "BatchCreatePartition" ;; esac
    qid="$(printf '%s-%s-%s' "$(date -u +%Y%m%d%H%M%S)" "$$" "$RANDOM" | md5sum | cut -c1-8)"
    qid="4b1c$qid-9f2a-4c3d-8e7f-$(printf '%012d' $((RANDOM * RANDOM % 1000000000)))"
    python3 - "$GLUE_DB" "$S3_ROOT" "$QSTATE/$qid.json" "$db" "$q" <<'PY'
import glob, json, os, re, sys
gluedb, s3root, statefile, db, q = sys.argv[1:6]

def fail(reason, etype="USER_ERROR"):
    json.dump({"State": "FAILED", "StateChangeReason": reason, "ErrorType": etype,
               "Columns": [], "Rows": [], "DataScannedInBytes": 0, "Query": q,
               "Database": db}, open(statefile, "w"), indent=2)
    sys.exit(0)

qq = " ".join(q.split()).rstrip(";")
def clean(name):
    return name.strip('`"').split(".")[-1]

m_msck = re.match(r"(?i)^msck\s+repair\s+table\s+([\w.`\"]+)$", qq)
m_show = re.match(r"(?i)^show\s+partitions\s+([\w.`\"]+)$", qq)
m_sel  = re.match(r"(?i)^select\s+(.+?)\s+from\s+([\w.`\"]+)"
                  r"(?:\s+where\s+(.+?))?(?:\s+limit\s+(\d+))?$", qq)
tname = clean(m_msck.group(1)) if m_msck else clean(m_show.group(1)) if m_show \
        else clean(m_sel.group(2)) if m_sel else None
if tname is None:
    fail("SYNTAX_ERROR: line 1:1: this lab engine supports SELECT / SHOW PARTITIONS / MSCK REPAIR TABLE only")

tpath = os.path.join(gluedb, tname + ".json")
if not os.path.exists(tpath):
    fail("TABLE_NOT_FOUND: line 1:1: Table 'awsdatacatalog.%s.%s' does not exist" % (db, tname))
t = json.load(open(tpath))["Table"]
sd = t["StorageDescriptor"]
loc = sd["Location"]
serde = sd["SerdeInfo"]["SerializationLibrary"]
delim = sd["SerdeInfo"].get("Parameters", {}).get("field.delim", ",")
cols = [c["Name"] for c in sd["Columns"]]
pkeys = [c["Name"] for c in t.get("PartitionKeys", [])]
ppath = os.path.join(gluedb, tname + ".partitions.json")
parts = json.load(open(ppath))["Partitions"] if os.path.exists(ppath) else []

def fs(uri):
    return os.path.join(s3root, uri[5:].rstrip("/"))

if m_msck:
    base = fs(loc)
    found, added = [], []
    if os.path.isdir(base) and pkeys:
        for d in sorted(glob.glob(os.path.join(base, *[k + "=*" for k in pkeys]))):
            rel = os.path.relpath(d, base).replace(os.sep, "/")
            vals = [seg.split("=", 1)[1] for seg in rel.split("/")]
            spec = {"Values": vals,
                    "StorageDescriptor": {"Location": loc.rstrip("/") + "/" + rel + "/"}}
            found.append(rel)
            if spec not in parts:
                parts.append(spec); added.append(rel)
    json.dump({"Partitions": parts}, open(ppath, "w"), indent=2)
    rows = [["Partitions not in metastore: %s:%s" % (tname, p)] for p in added] or \
           [["Partitions are already in sync (%d registered)" % len(parts)]]
    json.dump({"State": "SUCCEEDED", "StateChangeReason": "", "Columns": ["repair"],
               "Rows": rows, "DataScannedInBytes": 0, "Query": q, "Database": db},
              open(statefile, "w"), indent=2)
    sys.exit(0)

if m_show:
    rows = [["/".join("%s=%s" % (k, v) for k, v in zip(pkeys, p["Values"]))] for p in parts]
    json.dump({"State": "SUCCEEDED", "StateChangeReason": "", "Columns": ["partition"],
               "Rows": rows, "DataScannedInBytes": 0, "Query": q, "Database": db},
              open(statefile, "w"), indent=2)
    sys.exit(0)

files = []
if pkeys:
    for p in parts:
        d = fs(p["StorageDescriptor"]["Location"])
        files += glob.glob(os.path.join(d, "**", "*"), recursive=True)
else:
    files = glob.glob(os.path.join(fs(loc), "**", "*"), recursive=True)
files = sorted(f for f in files if os.path.isfile(f))

rows, scanned = [], 0
is_json = "json" in serde.lower()
for f in files:
    scanned += os.path.getsize(f)
    part_vals = {}
    rel = os.path.relpath(os.path.dirname(f), fs(loc))
    for seg in rel.split(os.sep):
        if "=" in seg:
            k, v = seg.split("=", 1); part_vals[k] = v
    for line in open(f, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        if is_json:
            try:
                o = json.loads(line)
            except Exception:
                o = {}
            r = {c: o.get(c) for c in cols}
        else:
            v = line.split(delim)
            r = {c: (v[i] if i < len(v) else None) for i, c in enumerate(cols)}
        r.update(part_vals)
        rows.append(r)

def matches(r, pred):
    for clause in re.split(r"(?i)\s+and\s+", pred.strip()):
        mm = re.match(r"^\s*([\w]+)\s*(=|!=|<>|>=|<=|>|<)\s*'?([^']*?)'?\s*$", clause)
        if not mm:
            return False
        col, op, val = mm.group(1), mm.group(2), mm.group(3)
        cur = r.get(col)
        try:
            a, b = float(cur), float(val); num = True
        except (TypeError, ValueError):
            a, b = ("" if cur is None else str(cur)), val; num = False
        if op == "=" and not (a == b): return False
        if op in ("!=", "<>") and not (a != b): return False
        if op in (">", "<", ">=", "<=") and not num: return False
        if op == ">" and not (a > b): return False
        if op == "<" and not (a < b): return False
        if op == ">=" and not (a >= b): return False
        if op == "<=" and not (a <= b): return False
    return True

sel, where, limit = m_sel.group(1).strip(), m_sel.group(3), m_sel.group(4)
if where:
    rows = [r for r in rows if matches(r, where)]
if re.match(r"(?i)^count\s*\(\s*\*\s*\)$", sel):
    out_cols, out_rows = ["_col0"], [[str(len(rows))]]
else:
    out_cols = cols + pkeys if sel == "*" else [c.strip() for c in sel.split(",")]
    n = int(limit) if limit else 1000
    out_rows = [[("" if r.get(c) is None else str(r.get(c))) for c in out_cols] for r in rows[:n]]
json.dump({"State": "SUCCEEDED", "StateChangeReason": "", "Columns": out_cols,
           "Rows": out_rows, "DataScannedInBytes": scanned, "Query": q, "Database": db},
          open(statefile, "w"), indent=2)
PY
    if [ -n "$out" ]; then
      rf="$(s3_path "${out%/}")/$qid.csv"
      mkdir -p "$(dirname "$rf")"
      python3 - "$QSTATE/$qid.json" "$rf" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(",".join('"%s"' % c for c in d["Columns"]) + "\n")
    for r in d["Rows"]:
        fh.write(",".join('"%s"' % c for c in r) + "\n")
PY
    fi
    printf '{\n    "QueryExecutionId": "%s"\n}\n' "$qid"
    ;;

  athena:get-query-execution)
    deny "athena:GetQueryExecution" "GetQueryExecution"
    qid="$(arg --query-execution-id "$@" || printf '')"
    [ -f "$QSTATE/$qid.json" ] || svc_error "InvalidRequestException" "GetQueryExecution" "QueryExecution $qid was not found"
    python3 - "$QSTATE/$qid.json" "$qid" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
st = {"State": d["State"]}
if d.get("StateChangeReason"):
    st["StateChangeReason"] = d["StateChangeReason"]
print(json.dumps({"QueryExecution": {
    "QueryExecutionId": sys.argv[2], "Query": d["Query"], "StatementType": "DML",
    "QueryExecutionContext": {"Database": d["Database"], "Catalog": "awsdatacatalog"},
    "Status": st,
    "Statistics": {"EngineExecutionTimeInMillis": 412,
                   "DataScannedInBytes": d["DataScannedInBytes"],
                   "TotalExecutionTimeInMillis": 640},
    "WorkGroup": "primary"}}, indent=4))
PY
    ;;

  athena:get-query-results)
    deny "athena:GetQueryResults" "GetQueryResults"
    qid="$(arg --query-execution-id "$@" || printf '')"
    [ -f "$QSTATE/$qid.json" ] || svc_error "InvalidRequestException" "GetQueryResults" "QueryExecution $qid was not found"
    python3 - "$QSTATE/$qid.json" "$OUTFMT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if d["State"] != "SUCCEEDED":
    sys.stderr.write("An error occurred (InvalidRequestException) when calling the GetQueryResults "
                     "operation: Query did not finish successfully. Final query state: %s. "
                     "Reason: %s\n" % (d["State"], d.get("StateChangeReason", "")))
    sys.exit(254)
if sys.argv[2] == "text":
    print("\t".join(d["Columns"]))
    for r in d["Rows"]:
        print("\t".join(r))
else:
    rows = [{"Data": [{"VarCharValue": c} for c in d["Columns"]]}]
    rows += [{"Data": [{"VarCharValue": c} for c in r]} for r in d["Rows"]]
    print(json.dumps({"ResultSet": {
        "Rows": rows,
        "ResultSetMetadata": {"ColumnInfo": [
            {"Name": c, "Type": "varchar", "Nullable": "UNKNOWN"} for c in d["Columns"]]}}}, indent=4))
PY
    ;;

  firehose:describe-delivery-stream)
    deny "firehose:DescribeDeliveryStream" "DescribeDeliveryStream"
    name="$(arg --delivery-stream-name "$@" || printf '')"
    f="$CLOUD/firehose/$name.json"
    [ -f "$f" ] || svc_error "ResourceNotFoundException" "DescribeDeliveryStream" "Firehose $name not found under account $ACCOUNT_ID."
    cat "$f"
    ;;

  comprehend:detect-sentiment)
    deny "comprehend:DetectSentiment" "DetectSentiment"
    text="$(arg --text "$@" || printf '')"
    lang="$(arg --language-code "$@" || printf '')"
    [ -n "$text" ] || arg_error "the following arguments are required: --text"
    [ -n "$lang" ] || arg_error "the following arguments are required: --language-code"
    case "$lang" in en|es|fr|de|it|pt|ar|hi|ja|ko|zh|zh-TW) : ;;
      *) svc_error "UnsupportedLanguageException" "DetectSentiment" "Unsupported language code: $lang" ;;
    esac
    python3 - "$text" <<'PY'
import json, re, sys
t = sys.argv[1].lower()
pos = {"love", "great", "excellent", "fast", "perfect", "recommend", "smooth", "works", "quality"}
neg = {"broke", "terrible", "slow", "refund", "disappointed", "never", "fails", "worst"}
w = set(re.findall(r"[a-z]+", t))
p, n = len(w & pos), len(w & neg)
if p and n:   s = "MIXED"
elif p > n:   s = "POSITIVE"
elif n > p:   s = "NEGATIVE"
else:         s = "NEUTRAL"
tot = max(p + n, 1)
sc = {"Positive": round(p / tot * 0.94, 4), "Negative": round(n / tot * 0.94, 4),
      "Neutral": round(0.94 if s == "NEUTRAL" else 0.03, 4),
      "Mixed": round(0.9 if s == "MIXED" else 0.02, 4)}
print(json.dumps({"Sentiment": s, "SentimentScore": sc}, separators=(",", ":")))
PY
    ;;

  rekognition:detect-labels)
    deny "rekognition:DetectLabels" "DetectLabels"
    svc_error "InvalidImageFormatException" "DetectLabels" \
      "Request has invalid image format. Amazon Rekognition accepts PNG or JPEG image bytes, or an S3 object"
    ;;

  iam:get-user-policy)
    python3 - "$LIVE_POLICY" "$(arg --user-name "$@" || printf 'clf-lab-analyst')" \
                             "$(arg --policy-name "$@" || printf 'clf-lab-analytics')" <<'PY'
import json, sys
print(json.dumps({"UserName": sys.argv[2], "PolicyName": sys.argv[3],
                  "PolicyDocument": json.load(open(sys.argv[1]))}, indent=4))
PY
    ;;

  iam:put-user-policy)
    pd="$(arg --policy-document "$@" || printf '')"
    case "$pd" in file://*) doc="${pd#file://}" ;; *) doc="" ;; esac
    [ -n "$doc" ] && [ -f "$doc" ] || arg_error "--policy-document must be file://<path> pointing to a readable JSON document"
    python3 - "$doc" "$LIVE_POLICY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))          # MalformedPolicyDocument if this throws
assert "Statement" in d, "policy must contain a Statement element"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
    ;;

  *)
    printf 'aws: this lab emulator implements a subset of AWS CLI v2:\n' >&2
    printf '  sts get-caller-identity\n  s3 ls | cp\n' >&2
    printf '  glue get-table | update-table | get-partitions | get-crawler | start-crawler\n' >&2
    printf '  athena start-query-execution | get-query-execution | get-query-results\n' >&2
    printf '  firehose describe-delivery-stream\n  comprehend detect-sentiment\n' >&2
    printf '  rekognition detect-labels\n  iam get-user-policy | put-user-policy\n' >&2
    exit 252
    ;;
esac
SHIM
  chmod +x "$LAB_ROOT/bin/aws"
}

# -----------------------------------------------------------------------------
# 6. The grader
# -----------------------------------------------------------------------------
install_verifier() {
  cat > "$LAB_ROOT/bin/clf37-verify" <<'VERIFY'
#!/usr/bin/env bash
# Acceptance test for CLF-C02 topic 3.7 break & fix. Exit 0 == lab solved.
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS="$LAB_ROOT/bin/aws"
EXP="$LAB_ROOT/.cloud/state/expected.json"
fails=0

jget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d[sys.argv[2]])' "$1" "$2"; }
pass() { printf '  [ PASS ] %s\n' "$1"; }
fail() { printf '  [ FAIL ] %s\n' "$1"; printf '           %s\n' "${2:-}"; fails=$((fails+1)); }

run_query() { # run_query "<sql>" -> prints first data cell, or QUERY_FAILED:<reason>
  local qid state
  qid="$("$AWS" athena start-query-execution \
          --query-string "$1" \
          --query-execution-context Database=analytics_db \
          --result-configuration OutputLocation=s3://clf-lab-datalake/athena-results/ 2>/dev/null \
        | sed -n 's/.*"QueryExecutionId": "\(.*\)".*/\1/p')"
  [ -n "$qid" ] && [ "$qid" != "null" ] || { printf 'QUERY_DENIED'; return; }
  state="$("$AWS" athena get-query-execution --query-execution-id "$qid" \
           | sed -n 's/.*"State": "\(.*\)".*/\1/p' | head -n1)"
  if [ "$state" != "SUCCEEDED" ]; then printf 'QUERY_FAILED:%s' "$state"; return; fi
  "$AWS" athena get-query-results --query-execution-id "$qid" --output text 2>/dev/null \
    | tail -n +2 | head -n1 | tr -d '[:space:]'
}

printf '\n--- CLF-C02 3.7 acceptance test -------------------------------------\n'

want_prefix="$(jget "$EXP" delivery_prefix)"
loc="$("$AWS" glue get-table --database-name analytics_db --name clickstream 2>/dev/null \
      | sed -n 's/.*"Location": "\(.*\)".*/\1/p')"
case "$loc" in
  *"$want_prefix") pass "Glue table Location matches the Firehose delivery prefix ($loc)" ;;
  *) fail "Glue table Location does not match the Firehose delivery prefix" "got: ${loc:-<none>}" ;;
esac

nparts="$(grep -c '"Values"' "$LAB_ROOT/.cloud/glue/analytics_db/clickstream.partitions.json" || true)"
want_parts="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["partitions"]))' "$EXP")"
if [ "$nparts" -ge "$want_parts" ]; then pass "$nparts partitions registered in the Data Catalog"
else fail "only $nparts of $want_parts partitions are registered" "a partitioned table shows zero rows until its partitions exist"; fi

want_total="$(jget "$EXP" total_events)"
got_total="$(run_query 'SELECT count(*) FROM clickstream')"
if [ "$got_total" = "$want_total" ]; then pass "SELECT count(*) = $want_total"
else fail "SELECT count(*) returned '$got_total', expected $want_total" "the table is not reading the delivered objects"; fi

want_pur="$(jget "$EXP" purchase_events)"
got_pur="$(run_query "SELECT count(*) FROM clickstream WHERE event_type = 'purchase'")"
if [ "$got_pur" = "$want_pur" ]; then pass "purchase events = $want_pur (columns deserialize correctly)"
else fail "purchase filter returned '$got_pur', expected $want_pur" "rows are being read but the SerDe is not parsing the columns"; fi

if grep -qi 'rekognition' "$LAB_ROOT/work/enrich.sh"; then
  fail "work/enrich.sh still calls Amazon Rekognition" "Rekognition analyses images and video, not text"
else
  pass "work/enrich.sh no longer calls an image service on text input"
fi

OUTF="$LAB_ROOT/work/out/sentiment.jsonl"
if [ -s "$OUTF" ]; then
  lines="$(grep -c '"Sentiment"' "$OUTF" || true)"
  reviews="$(grep -cve '^[[:space:]]*$' "$LAB_ROOT/work/reviews.txt")"
  if [ "$lines" -eq "$reviews" ] && grep -q 'POSITIVE' "$OUTF" && grep -q 'NEGATIVE' "$OUTF"; then
    pass "$lines/$reviews reviews enriched with a Sentiment label"
  else
    fail "sentiment output is incomplete ($lines/$reviews labelled)" "re-run work/enrich.sh after fixing it"
  fi
else
  fail "work/out/sentiment.jsonl is missing or empty" "run work/enrich.sh once it calls the right service"
fi

if python3 - "$LAB_ROOT/.cloud/iam/clf-lab-analyst.json" <<'PY'
import json, sys
pol = json.load(open(sys.argv[1]))
acts = []
for st in pol.get("Statement", []):
    a = st.get("Action", [])
    acts += [a] if isinstance(a, str) else a
sys.exit(0 if ("comprehend:DetectSentiment" in acts and "*" not in acts) else 1)
PY
then pass "IAM policy grants comprehend:DetectSentiment without a bare \"*\" action"
else fail "IAM policy is wrong" "grant exactly comprehend:DetectSentiment - least privilege, never \"Action\": \"*\""; fi

printf -- '----------------------------------------------------------------------\n'
if [ "$fails" -eq 0 ]; then
  printf 'ALL CHECKS PASSED - pipeline restored. Cost note: check DataScannedInBytes\n'
  printf 'in get-query-execution; Athena bills per TB scanned, which is why the\n'
  printf 'table is partitioned by dt and why Parquet beats raw JSON in production.\n\n'
  exit 0
fi
printf '%d check(s) still failing.\n\n' "$fails"
exit 1
VERIFY
  chmod +x "$LAB_ROOT/bin/clf37-verify"
}

# -----------------------------------------------------------------------------
# 7. Re-break (used by --reset and by the initial build)
# -----------------------------------------------------------------------------
break_it() {
  seed_cloud_objects
  seed_workstation
  rm -f "$LAB_ROOT"/work/out/*.jsonl "$LAB_ROOT"/.cloud/state/queries/*.json 2>/dev/null || true
  rm -f "$LAB_ROOT"/.cloud/s3/clf-lab-datalake/athena-results/*.csv 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 8. Mission brief
# -----------------------------------------------------------------------------
brief() {
  cat <<'BRIEF' | sed "s|__LAB_ROOT__|$LAB_ROOT|g"

======================================================================
 CLF-C02 - Task 3.7 - BREAK & FIX: "the dashboard went blank last night"
======================================================================

SCENARIO
  You own the retail analytics pipeline:

    Amazon Data Firehose --> Amazon S3 (data lake, raw JSON, partitioned by dt)
                                  |
                          AWS Glue Data Catalog  (schema, partitions, SerDe)
                                  |
                          Amazon Athena          (serverless SQL, pay per TB scanned)
                                  |
                          Amazon QuickSight      (BI dashboard - out of scope here)

  A colleague migrated the delivery stream last week and "cleaned up" an IAM
  policy. Since then the daily revenue dashboard shows nothing, and the nightly
  review-enrichment job exits non-zero.

FIRST, PUT THE LAB CLI ON YOUR PATH
    export PATH="__LAB_ROOT__/bin:$PATH"
    aws sts get-caller-identity

SYMPTOMS YOU WILL SEE
  1. Athena queries SUCCEED and return zero rows. No error, no warning - the
     single most common Athena support case. "Success with 0 rows" always means
     the engine looked somewhere, and there was nothing there.
  2. Once rows appear, `SELECT count(*)` is right but any WHERE on a column
     returns 0. The engine is reading bytes it cannot turn into columns.
  3. __LAB_ROOT__/work/enrich.sh dies on its first record with
     InvalidImageFormatException, and after that with AccessDeniedException.
     Two different failures, two different lessons.

YOUR MISSION
  Make this print ALL CHECKS PASSED:

      __LAB_ROOT__/bin/clf37-verify

  Acceptance criteria:
    [ ] The Glue table points at the prefix Firehose actually writes to.
    [ ] Its partitions are registered in the Data Catalog.
    [ ] SELECT count(*) FROM clickstream                       -> 512
    [ ] SELECT count(*) ... WHERE event_type = 'purchase'      -> 128
    [ ] work/enrich.sh uses the AI service that matches the modality (text),
        and work/out/sentiment.jsonl has one Sentiment per review.
    [ ] The IAM policy grants exactly the missing action - not "Action": "*".

TOOLS AVAILABLE (real AWS CLI v2 syntax, offline transport)
    aws sts get-caller-identity
    aws s3 ls s3://clf-lab-datalake/raw/ --recursive
    aws s3 cp s3://<bucket>/<key> -
    aws firehose describe-delivery-stream --delivery-stream-name clf-lab-clickstream
    aws glue get-table   --database-name analytics_db --name clickstream
    aws glue update-table --database-name analytics_db --table-input file:///tmp/t.json
    aws glue get-partitions --database-name analytics_db --table-name clickstream
    aws glue get-crawler  --name clf-lab-clickstream-crawler
    aws glue start-crawler --name clf-lab-clickstream-crawler
    aws athena start-query-execution --query-string "<sql>" \
        --query-execution-context Database=analytics_db \
        --result-configuration OutputLocation=s3://clf-lab-datalake/athena-results/
    aws athena get-query-execution --query-execution-id <id>
    aws athena get-query-results   --query-execution-id <id> --output text
    aws comprehend detect-sentiment --text "<text>" --language-code en
    aws iam get-user-policy --user-name clf-lab-analyst --policy-name clf-lab-analytics
    aws iam put-user-policy --user-name clf-lab-analyst --policy-name clf-lab-analytics \
        --policy-document file://__LAB_ROOT__/work/analyst-policy.json

  SQL supported: SELECT [count(*)|*|cols] FROM t [WHERE col = 'v' [AND ...]] [LIMIT n],
                 SHOW PARTITIONS t, MSCK REPAIR TABLE t

EXAM ANCHOR - the service map this incident walks through
  ANALYTICS
    Amazon S3            object storage; the data lake itself
    Amazon Data Firehose near-real-time delivery of streams to S3/Redshift/OpenSearch
    Amazon Kinesis Data Streams  raw stream ingestion with custom consumers
    AWS Glue             serverless ETL + the Data Catalog (Hive-compatible metastore)
    Amazon Athena        serverless SQL directly on S3, billed per TB scanned
    Amazon Redshift      petabyte-scale cloud data warehouse (provisioned or serverless)
    Amazon EMR           managed Spark / Hive / Presto clusters
    Amazon OpenSearch Service  search + log analytics
    Amazon QuickSight    serverless BI dashboards
    AWS Lake Formation   permissions and governance over the lake
    AWS Data Exchange    third-party data subscriptions
  AI/ML - pick by MODALITY, that is the whole exam question
    Amazon Comprehend    text/NLP: sentiment, entities, key phrases, PII, language
    Amazon Rekognition   images and video: labels, faces, moderation
    Amazon Textract      documents: extract text, forms and tables from scans
    Amazon Transcribe    speech -> text        Amazon Polly    text -> speech
    Amazon Translate     language translation  Amazon Lex      conversational bots
    Amazon Kendra        intelligent enterprise search
    Amazon Personalize   real-time recommendations
    Amazon Bedrock       managed foundation models / generative AI
    Amazon Q             generative AI assistant for business and builders
    Amazon SageMaker AI  build, train and deploy your own models
  Rule of thumb: use the pre-trained API when the task is generic (sentiment,
  OCR, transcription); reach for SageMaker only when the task is specific to
  your data. Cost, latency and time-to-value all favour the managed API.

OFFICIAL DOCS
  Exam guide   https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
  Athena       https://docs.aws.amazon.com/athena/latest/ug/what-is.html
  Athena SerDe https://docs.aws.amazon.com/athena/latest/ug/serde-reference.html
  MSCK REPAIR  https://docs.aws.amazon.com/athena/latest/ug/msck-repair-table.html
  Glue catalog https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html
  Firehose     https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html
  Comprehend   https://docs.aws.amazon.com/comprehend/latest/dg/what-is.html
  Rekognition  https://docs.aws.amazon.com/rekognition/latest/dg/what-is.html
  Textract     https://docs.aws.amazon.com/textract/latest/dg/what-is.html
  SageMaker    https://docs.aws.amazon.com/sagemaker/latest/dg/whatis.html
  Bedrock      https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html
  QuickSight   https://docs.aws.amazon.com/quicksight/latest/user/welcome.html
  Redshift     https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html
  EMR          https://docs.aws.amazon.com/emr/latest/ManagementGuide/emr-what-is-emr.html
  OpenSearch   https://docs.aws.amazon.com/opensearch-service/latest/developerguide/what-is.html

  The worked solution is at the bottom of this script, commented out.
  Re-break at any time with:  $0 --reset --yes
======================================================================

BRIEF
}

# -----------------------------------------------------------------------------
# 9. Main
# -----------------------------------------------------------------------------
case "$ACTION" in
  brief)
    [ -f "$LAB_MARKER" ] || { say "lab not built yet - run this script with no arguments." >&2; exit 1; }
    brief
    ;;
  reset)
    [ -f "$LAB_MARKER" ] || { say "lab not built yet - run this script with no arguments." >&2; exit 1; }
    confirm
    break_it
    install_cli
    install_verifier
    head1 "lab re-broken"
    brief
    ;;
  build)
    confirm
    build_tree
    seed_s3
    break_it
    install_cli
    install_verifier
    brief
    ;;
esac

exit 0

# =============================================================================
#  S O L U T I O N  -  do not read before you have tried clf37-verify
# =============================================================================
#
#  export PATH="$HOME/aws-clf-lab/topic-3.7/bin:$PATH"
#  LAB="$HOME/aws-clf-lab/topic-3.7"
#
# -----------------------------------------------------------------------------
# STEP 0 - Confirm who you are and reproduce the symptom
# -----------------------------------------------------------------------------
#  aws sts get-caller-identity
#
#  QID=$(aws athena start-query-execution \
#          --query-string "SELECT count(*) FROM clickstream" \
#          --query-execution-context Database=analytics_db \
#          --result-configuration OutputLocation=s3://clf-lab-datalake/athena-results/ \
#        | sed -n 's/.*"QueryExecutionId": "\(.*\)".*/\1/p')
#  aws athena get-query-execution --query-execution-id "$QID"     # State: SUCCEEDED
#  aws athena get-query-results   --query-execution-id "$QID" --output text
#      _col0
#      0
#
#  SUCCEEDED with 0 rows and DataScannedInBytes 0 => Athena read no objects.
#  Athena never invents data: either the Location is wrong, or the partitions
#  are not registered. Both are Glue Data Catalog problems, not Athena problems.
#
# -----------------------------------------------------------------------------
# STEP 1 - Fault A: the table points at a decommissioned prefix
# -----------------------------------------------------------------------------
#  aws glue get-table --database-name analytics_db --name clickstream
#      ... "Location": "s3://clf-lab-datalake/raw/clickstream-v1/"
#      ... "SerializationLibrary": "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
#      ... "classification": "csv"
#
#  Ground truth = where the producer actually writes:
#  aws firehose describe-delivery-stream --delivery-stream-name clf-lab-clickstream
#      ... "Prefix": "raw/clickstream/dt=!{timestamp:yyyy-MM-dd}/"
#
#  And the objects themselves:
#  aws s3 ls s3://clf-lab-datalake/raw/ --recursive
#      clf-lab-datalake/raw/clickstream/dt=2026-09-02/part-00000.json
#      clf-lab-datalake/raw/clickstream/dt=2026-09-03/part-00000.json
#      clf-lab-datalake/raw/clickstream/dt=2026-09-04/part-00000.json
#  aws s3 cp s3://clf-lab-datalake/raw/clickstream/dt=2026-09-02/part-00000.json - | head -1
#      {"event_id": "evt-000003", ...}          <- JSON, not CSV. Note that.
#
#  Catalog says .../clickstream-v1/ ; producer writes .../clickstream/ .
#
# -----------------------------------------------------------------------------
# STEP 2 - Fix Location and the SerDe in one UpdateTable (fixes A and C)
# -----------------------------------------------------------------------------
#  aws glue get-table --database-name analytics_db --name clickstream > /tmp/t.json
#
#  python3 - <<'PY'
#  import json
#  d = json.load(open("/tmp/t.json"))
#  sd = d["Table"]["StorageDescriptor"]
#  sd["Location"] = "s3://clf-lab-datalake/raw/clickstream/"
#  sd["SerdeInfo"] = {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe",
#                     "Parameters": {"paths": "event_id,user_id,event_type,item_sku,amount_usd,event_time"}}
#  d["Table"]["Parameters"]["classification"] = "json"
#  json.dump(d, open("/tmp/t.json", "w"), indent=2)
#  PY
#
#  aws glue update-table --database-name analytics_db --table-input file:///tmp/t.json
#
#  Why the SerDe matters: LazySimpleSerDe splits each line on "," and maps the
#  pieces onto the columns positionally, so a JSON line becomes six fragments of
#  text. count(*) still returns 512 - one row per line - but event_type holds
#  ' "event_type": "purchase"' and never equals 'purchase'. Rows without columns.
#  https://docs.aws.amazon.com/athena/latest/ug/serde-reference.html
#
# -----------------------------------------------------------------------------
# STEP 3 - Fault B: a partitioned table with no partitions is an empty table
# -----------------------------------------------------------------------------
#  aws glue get-partitions --database-name analytics_db --table-name clickstream
#      { "Partitions": [] }
#
#  QID=$(aws athena start-query-execution \
#          --query-string "MSCK REPAIR TABLE clickstream" \
#          --query-execution-context Database=analytics_db \
#          --result-configuration OutputLocation=s3://clf-lab-datalake/athena-results/ \
#        | sed -n 's/.*"QueryExecutionId": "\(.*\)".*/\1/p')
#  aws athena get-query-results --query-execution-id "$QID" --output text
#      Partitions not in metastore: clickstream:dt=2026-09-02  ...
#
#  MSCK REPAIR TABLE works because the layout is Hive-style (dt=YYYY-MM-DD/).
#  For non-Hive layouts use ALTER TABLE ... ADD PARTITION, or partition
#  projection, which removes the metastore round-trip entirely.
#  https://docs.aws.amazon.com/athena/latest/ug/msck-repair-table.html
#  https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html
#
#  In production you do not run MSCK by hand every day: a scheduled Glue crawler,
#  ALTER TABLE ADD PARTITION from the ingest job, or partition projection keeps
#  the catalog current. MSCK also rescans the whole prefix and gets slower every
#  day the table grows.
#
# -----------------------------------------------------------------------------
# STEP 2+3 ALTERNATIVE (path B) - let the crawler do all of it
# -----------------------------------------------------------------------------
#  aws glue get-crawler   --name clf-lab-clickstream-crawler     # target = the real prefix
#  aws glue start-crawler --name clf-lab-clickstream-crawler
#  aws glue get-crawler   --name clf-lab-clickstream-crawler     # LastCrawl: SUCCEEDED
#
#  A crawler infers columns, classification, SerDe and partitions from the
#  objects themselves - which is exactly the three faults above at once. Prefer
#  it when the schema is discovered; prefer explicit DDL when the schema is a
#  contract you control.  https://docs.aws.amazon.com/glue/latest/dg/add-crawler.html
#
# -----------------------------------------------------------------------------
# STEP 4 - Verify the analytics half
# -----------------------------------------------------------------------------
#  q() { aws athena start-query-execution --query-string "$1" \
#          --query-execution-context Database=analytics_db \
#          --result-configuration OutputLocation=s3://clf-lab-datalake/athena-results/ \
#        | sed -n 's/.*"QueryExecutionId": "\(.*\)".*/\1/p'; }
#  aws athena get-query-results --query-execution-id "$(q 'SELECT count(*) FROM clickstream')" --output text
#      _col0
#      512
#  aws athena get-query-results --query-execution-id \
#      "$(q "SELECT count(*) FROM clickstream WHERE event_type = 'purchase'")" --output text
#      _col0
#      128
#  aws athena get-query-execution --query-execution-id "$QID"   # read DataScannedInBytes:
#      that number times the per-TB price is the invoice. Partition pruning and
#      columnar Parquet are the two levers that move it.
#
# -----------------------------------------------------------------------------
# STEP 5 - Fault D part 1: the wrong AI service for the modality
# -----------------------------------------------------------------------------
#  $LAB/work/enrich.sh
#      An error occurred (InvalidImageFormatException) when calling the DetectLabels
#      operation: Request has invalid image format...
#
#  Amazon Rekognition analyses IMAGES and VIDEO. The input here is free-form
#  English text, so the service is Amazon Comprehend (NLP): sentiment, entities,
#  key phrases, dominant language, PII. Had the input been scanned PDFs it would
#  be Textract; audio, Transcribe; a translation, Translate.
#
#  Rewrite work/enrich.sh:
#
#      #!/usr/bin/env bash
#      set -euo pipefail
#      LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#      export PATH="$LAB_ROOT/bin:$PATH"
#      IN="$LAB_ROOT/work/reviews.txt"
#      OUT="$LAB_ROOT/work/out/sentiment.jsonl"
#      mkdir -p "$(dirname "$OUT")"
#      : > "$OUT"
#      n=0
#      while IFS= read -r line; do
#        [ -z "$line" ] && continue
#        aws comprehend detect-sentiment --text "$line" --language-code en >> "$OUT"
#        n=$((n + 1))
#      done < "$IN"
#      echo "enriched $n reviews -> $OUT"
#
#  (In production you would use detect-sentiment's batch form, BatchDetectSentiment,
#   up to 25 documents per call, instead of one API call per line.)
#
# -----------------------------------------------------------------------------
# STEP 6 - Fault D part 2: the missing IAM action
# -----------------------------------------------------------------------------
#  $LAB/work/enrich.sh
#      An error occurred (AccessDeniedException) when calling the DetectSentiment
#      operation: User: arn:aws:iam::123456789012:user/clf-lab-analyst is not
#      authorized to perform: comprehend:DetectSentiment ...
#
#  aws iam get-user-policy --user-name clf-lab-analyst --policy-name clf-lab-analytics
#      -> the statement inherited from the image-moderation pipeline grants
#         rekognition:*, which is why nobody noticed.
#
#  Edit $LAB/work/analyst-policy.json and add a least-privilege statement:
#
#      {
#        "Sid": "ReviewNlp",
#        "Effect": "Allow",
#        "Action": [ "comprehend:DetectSentiment" ],
#        "Resource": "*"
#      }
#
#  aws iam put-user-policy --user-name clf-lab-analyst \
#      --policy-name clf-lab-analytics \
#      --policy-document file://$LAB/work/analyst-policy.json
#
#  Do NOT "fix" it with "Action": "*" - the grader fails that on purpose. AWS
#  Identity and Access Management denies by default; the repair is the one
#  action the workload needs, and the stale rekognition statement should be
#  removed in the same change.
#  https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
#
#  $LAB/work/enrich.sh
#      enriched 8 reviews -> .../work/out/sentiment.jsonl
#
# -----------------------------------------------------------------------------
# STEP 7 - Grade it
# -----------------------------------------------------------------------------
#  clf37-verify        # expect: ALL CHECKS PASSED
#
# -----------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM (and into an incident channel)
# -----------------------------------------------------------------------------
#  * Athena is a QUERY ENGINE, not a store. Data lives in S3; schema lives in the
#    Glue Data Catalog. "Zero rows, no error" is a catalog problem in almost
#    every case: wrong Location, or unregistered partitions.
#  * count(*) right and WHERE wrong = the SerDe/classification does not match the
#    file format. Rows are being read; columns are not being parsed.
#  * Firehose (managed, near-real-time, no consumer code, delivers to S3 /
#    Redshift / OpenSearch / Splunk) vs Kinesis Data Streams (raw stream, you
#    write and scale the consumer). Firehose is the "just land it" answer.
#  * A Glue crawler exists precisely to keep schema, classification and
#    partitions in sync with the objects. Scheduling one is the durable fix.
#  * Pick the AI service by input modality, not by vibe:
#      text -> Comprehend | image/video -> Rekognition | scanned document ->
#      Textract | audio -> Transcribe | speech out -> Polly | translation ->
#      Translate | chatbot -> Lex | enterprise search -> Kendra |
#      recommendations -> Personalize | foundation models -> Bedrock |
#      assistant -> Amazon Q | your own model -> SageMaker AI.
#  * Athena bills per TB scanned; partitioning and columnar formats (Parquet,
#    ORC) are cost controls, not micro-optimisations. Compare the
#    DataScannedInBytes of the same query before and after partition pruning.
# =============================================================================