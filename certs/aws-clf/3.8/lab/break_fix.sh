#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) - Domain 3: Cloud Technology and
#  Services.  Topic 3.8 - "Identify services from other in-scope AWS service
#  categories" (exam weight 4.25).
#
#  BREAK & FIX LAB - build a disposable "service category router" on this VM,
#  break it in six controlled ways, and hand the student a failing test suite.
#
#  Why a router?  Task 3.8 is not memorisation of marketing names: the exam
#  gives you a workload sentence ("we must extract tables from scanned
#  invoices") and expects you to land on the one service, in the one category,
#  that AWS itself files it under.  Platform teams encode exactly that mapping
#  in routing tables, tagging policies and service-control policies, and those
#  tables rot the same way this lab's does: a service is filed under the wrong
#  category, a category key is renamed, an entry is deleted, an entry is
#  duplicated, a JSON file gets a trailing comma, and a CLI profile drifts.
#
#  Reference (authoritative, and the only source used for scope):
#    AWS Certified Cloud Practitioner (CLF-C02) Exam Guide, Task Statement 3.8
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
#  SAFETY CONTRACT
#    * Everything is created, broken and repaired inside $LAB_ROOT
#      (default: $HOME/aws-clf-lab/topic-3.8).  Nothing outside it is touched.
#    * No AWS account, no credentials, no network calls, no cost.  The AWS CLI
#      is used only for local profile inspection through a lab-scoped
#      AWS_CONFIG_FILE; ~/.aws is never read or written.
#    * A pristine snapshot is stored OUTSIDE the lab directory as the escape
#      hatch (--reset).  Diffing it is cheating; use it only to start over.
#    * Run this on a throwaway VM or container.  It refuses obviously unsafe
#      lab roots and refuses to overwrite a directory it did not create.
#
#  Usage:
#    ./break-fix-3.8.sh [--yes] [--root DIR]     build + break + brief
#    ./break-fix-3.8.sh --reset [--root DIR]     restore the pristine lab
# ==============================================================================

set -euo pipefail

LAB_ROOT="${LAB_ROOT:-$HOME/aws-clf-lab/topic-3.8}"
ASSUME_YES="${LAB_ASSUME_YES:-0}"
DO_RESET=0
MARKER=".aws-clf-lab"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y)   ASSUME_YES=1 ;;
        --reset)    DO_RESET=1 ;;
        --root)     shift; LAB_ROOT="${1:?--root needs a directory}" ;;
        --root=*)   LAB_ROOT="${1#--root=}" ;;
        -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
        *)          printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

SNAP_DIR="$(dirname "$LAB_ROOT")/.snapshots"
SNAP_TGZ="$SNAP_DIR/$(basename "$LAB_ROOT").pristine.tar.gz"

die() { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# ------------------------------------------------------------------ guards ---
guard_environment() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required (JSON tooling)."
    command -v tar     >/dev/null 2>&1 || die "tar is required (snapshot)."

    case "$LAB_ROOT" in
        ""|"/"|/usr*|/etc*|/bin*|/sbin*|/lib*|/boot*|/proc*|/sys*|/dev*|/var/lib*)
            die "refusing to use '$LAB_ROOT' as a lab root." ;;
    esac
    [ "$LAB_ROOT" = "$HOME" ] && die "refusing to use \$HOME itself as a lab root."
    [ -e "$LAB_ROOT/.git" ]   && die "'$LAB_ROOT' looks like a git work tree."

    if [ -d "$LAB_ROOT" ] && [ ! -f "$LAB_ROOT/$MARKER" ]; then
        die "'$LAB_ROOT' exists and was not created by this lab. Pick another --root."
    fi

    if [ "$ASSUME_YES" != "1" ] && [ "$DO_RESET" != "1" ]; then
        if [ -t 0 ]; then
            printf 'This VM should be DISPOSABLE. Build and break the lab in\n  %s\n[y/N]: ' "$LAB_ROOT"
            read -r reply
            case "$reply" in y|Y|yes|YES) ;; *) die "aborted by the operator." ;; esac
        else
            die "non-interactive run: pass --yes (or LAB_ASSUME_YES=1) to confirm."
        fi
    fi
}

# ------------------------------------------------------------------- reset ---
do_reset() {
    [ -f "$SNAP_TGZ" ] || die "no pristine snapshot at $SNAP_TGZ"
    [ -f "$LAB_ROOT/$MARKER" ] || die "'$LAB_ROOT' has no lab marker; refusing to delete it."
    rm -rf -- "$LAB_ROOT"
    mkdir -p -- "$(dirname "$LAB_ROOT")"
    tar -xzf "$SNAP_TGZ" -C "$(dirname "$LAB_ROOT")"
    say "Lab restored from $SNAP_TGZ (pristine, unbroken)."
    say "Re-run this script without --reset to break it again."
    exit 0
}

# ------------------------------------------------------------------- build ---
build_catalog() {
    cat > "$LAB_ROOT/catalog.json" <<'JSON'
{
  "schema_version": 1,
  "source": "AWS Certified Cloud Practitioner (CLF-C02) Exam Guide, Task Statement 3.8",
  "source_url": "https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf",
  "categories": {
    "analytics": [
      {"service": "Amazon Athena", "cli": "athena", "probe": "aws athena list-work-groups",
       "role": "Serverless SQL (Trino/Presto engine) directly over objects in Amazon S3. No cluster to size; billed per TB scanned, so partitioning and columnar formats (Parquet/ORC) are the cost lever."},
      {"service": "Amazon EMR", "cli": "emr", "probe": "aws emr list-clusters",
       "role": "Managed Apache Spark, Hadoop, Hive and Presto. You still own cluster shape and tuning; runs on EC2, on EKS, or as EMR Serverless."},
      {"service": "Amazon Kinesis Data Streams", "cli": "kinesis", "probe": "aws kinesis list-streams",
       "role": "Shard-based real-time ingestion. Records are ordered per partition key and replayable inside the retention window - that replay is what separates it from a queue."},
      {"service": "Amazon Data Firehose", "cli": "firehose", "probe": "aws firehose list-delivery-streams",
       "role": "Buffered, no-code delivery of a stream into S3, Redshift, OpenSearch or a partner sink, with optional format conversion. No consumer code, no replay."},
      {"service": "AWS Glue", "cli": "glue", "probe": "aws glue get-databases",
       "role": "Serverless ETL plus the Glue Data Catalog - the metastore Athena, EMR and Redshift Spectrum read table schemas from."},
      {"service": "Amazon QuickSight", "cli": "quicksight", "probe": "aws quicksight list-dashboards --aws-account-id 111122223333",
       "role": "Business intelligence dashboards, per-session pricing, SPICE in-memory engine for interactive queries."},
      {"service": "Amazon OpenSearch Service", "cli": "opensearch", "probe": "aws opensearch list-domain-names",
       "role": "Managed OpenSearch/Elasticsearch for log analytics and full-text search over operational data."},
      {"service": "AWS Data Exchange", "cli": "dataexchange", "probe": "aws dataexchange list-data-sets",
       "role": "Find and subscribe to third-party data sets, delivered into your own S3 buckets or APIs."}
    ],
    "application_integration": [
      {"service": "Amazon EventBridge", "cli": "events", "probe": "aws events list-event-buses",
       "role": "Event bus with content-based rules, schema registry and SaaS partner sources; the default glue for event-driven architectures."},
      {"service": "Amazon SNS", "cli": "sns", "probe": "aws sns list-topics",
       "role": "Pub/sub push fan-out to many subscribers (SQS, Lambda, HTTPS, email, SMS)."},
      {"service": "Amazon SQS", "cli": "sqs", "probe": "aws sqs list-queues",
       "role": "Pull-based decoupling queue, Standard (at-least-once) or FIFO (exactly-once processing, ordered)."},
      {"service": "AWS Step Functions", "cli": "stepfunctions", "probe": "aws stepfunctions list-state-machines",
       "role": "State machine orchestration with retries, catch and human-approval steps; keeps workflow logic out of function code."},
      {"service": "Amazon AppFlow", "cli": "appflow", "probe": "aws appflow list-flows",
       "role": "No-code bidirectional data flows between SaaS applications and AWS services."},
      {"service": "Amazon MQ", "cli": "mq", "probe": "aws mq list-brokers",
       "role": "Managed ActiveMQ/RabbitMQ - the lift-and-shift target when the application already speaks JMS, AMQP or MQTT to a broker."}
    ],
    "business_applications": [
      {"service": "Amazon Connect", "cli": "connect", "probe": "aws connect list-instances",
       "role": "Omnichannel cloud contact center: telephony, chat, IVR flows, per-minute pricing, integrates with Lex bots and Transcribe."},
      {"service": "Amazon Simple Email Service", "cli": "sesv2", "probe": "aws sesv2 list-email-identities",
       "role": "Transactional and bulk email with deliverability tooling (DKIM, SPF, dedicated IPs, reputation dashboard)."}
    ],
    "containers": [
      {"service": "Amazon ECS", "cli": "ecs", "probe": "aws ecs list-clusters",
       "role": "AWS-native container orchestrator built on task definitions and services; deepest IAM and VPC integration, no control-plane fee."},
      {"service": "Amazon EKS", "cli": "eks", "probe": "aws eks list-clusters",
       "role": "Upstream-conformant Kubernetes control plane, managed and patched by AWS; portable manifests, hourly control-plane charge."},
      {"service": "AWS Fargate", "cli": "ecs", "probe": "aws ecs list-task-definitions",
       "role": "Serverless capacity type for ECS and EKS, not a standalone API: you declare vCPU/memory per task and AWS owns the host."},
      {"service": "Amazon ECR", "cli": "ecr", "probe": "aws ecr describe-repositories",
       "role": "Private OCI registry with lifecycle policies and image scanning; IAM is the authentication path, not a registry password."}
    ],
    "customer_engagement": [
      {"service": "AWS Support", "cli": "support", "probe": "aws support describe-severity-levels",
       "role": "Tiered plans (Developer, Business, Enterprise On-Ramp, Enterprise); the Support API itself requires Business or above."},
      {"service": "AWS IQ", "cli": "-", "probe": "-",
       "role": "Marketplace for short engagements with AWS-certified third-party experts, billed through your AWS account."},
      {"service": "AWS Managed Services", "cli": "-", "probe": "-",
       "role": "AMS - AWS operates your infrastructure for you (patching, incident management, change requests) on top of your workloads."},
      {"service": "AWS Activate for Startups", "cli": "-", "probe": "-",
       "role": "Credits, technical support and training for eligible startups."}
    ],
    "developer_tools": [
      {"service": "AWS CLI", "cli": "-", "probe": "aws --version",
       "role": "Command-line access to every service API; the same credential chain and region resolution as the SDKs."},
      {"service": "AWS Cloud9", "cli": "cloud9", "probe": "aws cloud9 list-environments",
       "role": "Browser-based IDE backed by an EC2 instance or an SSH host, with shared editing sessions."},
      {"service": "AWS CloudShell", "cli": "cloudshell", "probe": "-",
       "role": "Browser shell pre-authenticated with your console identity - useful when you need a CLI and have no local install."},
      {"service": "AWS CodeBuild", "cli": "codebuild", "probe": "aws codebuild list-projects",
       "role": "Managed build service driven by buildspec.yml; per-minute billing, no build fleet to keep warm."},
      {"service": "AWS CodePipeline", "cli": "codepipeline", "probe": "aws codepipeline list-pipelines",
       "role": "Continuous delivery pipelines wiring source, build, test and deploy stages together."},
      {"service": "AWS CodeDeploy", "cli": "deploy", "probe": "aws deploy list-applications",
       "role": "Deployment automation to EC2, on-premises servers, Lambda and ECS, with blue/green and canary strategies plus automatic rollback."},
      {"service": "AWS CodeArtifact", "cli": "codeartifact", "probe": "aws codeartifact list-domains",
       "role": "Managed artifact repository for npm, PyPI, Maven and NuGet packages, with upstream proxying to public registries."},
      {"service": "AWS X-Ray", "cli": "xray", "probe": "aws xray get-service-graph --start-time 1700000000 --end-time 1700003600",
       "role": "Distributed tracing: segments and subsegments across services produce a service graph that shows where the latency actually is."}
    ],
    "end_user_computing": [
      {"service": "Amazon WorkSpaces", "cli": "workspaces", "probe": "aws workspaces describe-workspaces",
       "role": "Persistent managed virtual desktops (Windows or Linux), monthly or hourly, with user volumes that survive reboots."},
      {"service": "Amazon AppStream 2.0", "cli": "appstream", "probe": "aws appstream describe-fleets",
       "role": "Streams a single application (not a whole desktop) to a browser; the app runs on a fleet instance, only pixels reach the client."},
      {"service": "Amazon WorkSpaces Secure Browser", "cli": "workspaces-web", "probe": "aws workspaces-web list-portals",
       "role": "Managed, isolated browser sessions for accessing internal web applications without shipping a device or a VPN client."}
    ],
    "frontend_web_mobile": [
      {"service": "AWS Amplify", "cli": "amplify", "probe": "aws amplify list-apps",
       "role": "Build and host full-stack web/mobile front ends with git-based CI/CD and managed backend resources."},
      {"service": "AWS AppSync", "cli": "appsync", "probe": "aws appsync list-graphql-apis",
       "role": "Managed GraphQL (and Pub/Sub) APIs with resolvers to DynamoDB, Lambda and HTTP sources, plus real-time subscriptions and offline sync."},
      {"service": "AWS Device Farm", "cli": "devicefarm", "probe": "aws devicefarm list-projects",
       "role": "Runs your tests on real physical phones and tablets in the AWS cloud, with video and logs per device."}
    ],
    "iot": [
      {"service": "AWS IoT Core", "cli": "iot", "probe": "aws iot describe-endpoint --endpoint-type iot:Data-ATS",
       "role": "Managed MQTT/HTTPS broker with per-device X.509 identities, a rules engine and Device Shadows for offline state."},
      {"service": "AWS IoT Greengrass", "cli": "greengrassv2", "probe": "aws greengrassv2 list-core-devices",
       "role": "Runs Lambda functions, containers and ML inference at the edge, buffering to the cloud when the link comes back."}
    ],
    "machine_learning": [
      {"service": "Amazon SageMaker AI", "cli": "sagemaker", "probe": "aws sagemaker list-notebook-instances",
       "role": "End-to-end platform to build, train and host your own models - the answer whenever the workload needs a custom model."},
      {"service": "Amazon Bedrock", "cli": "bedrock", "probe": "aws bedrock list-foundation-models",
       "role": "Serverless access to third-party and Amazon foundation models through one API, with guardrails and knowledge bases."},
      {"service": "Amazon Comprehend", "cli": "comprehend", "probe": "aws comprehend list-entities-detection-jobs",
       "role": "NLP: entities, key phrases, sentiment, PII detection over text."},
      {"service": "Amazon Kendra", "cli": "kendra", "probe": "aws kendra list-indices",
       "role": "Intelligent enterprise search over internal repositories, returning answers rather than keyword hits."},
      {"service": "Amazon Lex", "cli": "lexv2-models", "probe": "aws lexv2-models list-bots",
       "role": "Conversational bots (intents, slots, ASR + NLU) - the engine behind Alexa, commonly fronted by Amazon Connect."},
      {"service": "Amazon Polly", "cli": "polly", "probe": "aws polly describe-voices --language-code en-US",
       "role": "Text to lifelike speech, with SSML control and neural voices; output is MP3/OGG/PCM."},
      {"service": "Amazon Rekognition", "cli": "rekognition", "probe": "aws rekognition list-collections",
       "role": "Image and video analysis: objects, faces, moderation labels, text in images."},
      {"service": "Amazon Textract", "cli": "textract", "probe": "aws textract list-adapters",
       "role": "Document analysis beyond OCR - preserves forms (key/value pairs) and table structure from scans and PDFs."},
      {"service": "Amazon Transcribe", "cli": "transcribe", "probe": "aws transcribe list-transcription-jobs",
       "role": "Speech to text, batch or streaming, with speaker diarisation and custom vocabularies."},
      {"service": "Amazon Translate", "cli": "translate", "probe": "aws translate list-languages",
       "role": "Neural machine translation between languages, with custom terminology."}
    ],
    "migration_transfer": [
      {"service": "AWS Database Migration Service", "cli": "dms", "probe": "aws dms describe-replication-instances",
       "role": "Migrates and continuously replicates databases with the source online; homogeneous, or heterogeneous when paired with the Schema Conversion Tool."},
      {"service": "AWS DataSync", "cli": "datasync", "probe": "aws datasync list-tasks",
       "role": "Accelerated online transfer of file/object data (NFS, SMB, HDFS, S3) with verification and scheduling - the choice when you DO have bandwidth."},
      {"service": "AWS Snow Family", "cli": "snowball", "probe": "aws snowball list-jobs",
       "role": "Physical devices (Snowcone, Snowball Edge) shipped to your site for offline, petabyte-scale transfer and edge compute."},
      {"service": "AWS Transfer Family", "cli": "transfer", "probe": "aws transfer list-servers",
       "role": "Managed SFTP/FTPS/FTP/AS2 endpoints in front of S3 or EFS, so partners keep their existing clients."},
      {"service": "AWS Migration Hub", "cli": "mgh", "probe": "aws mgh list-migration-tasks",
       "role": "Single pane tracking migration progress across tools and regions."},
      {"service": "AWS Application Discovery Service", "cli": "discovery", "probe": "aws discovery describe-agents",
       "role": "Inventories on-premises servers and their dependencies to build the migration plan."},
      {"service": "AWS Application Migration Service", "cli": "mgn", "probe": "aws mgn describe-source-servers",
       "role": "Block-level rehost (lift-and-shift) of servers into EC2 with continuous replication and short cutover windows."}
    ]
  }
}
JSON

    mkdir -p "$LAB_ROOT/catalog.d"
    cat > "$LAB_ROOT/catalog.d/aliases.json" <<'JSON'
{
  "serverless sql queries over data in amazon s3": "Amazon Athena",
  "extract text and tables from scanned invoices": "Amazon Textract",
  "cloud contact center with omnichannel routing": "Amazon Connect",
  "persistent virtual desktops for remote staff": "Amazon WorkSpaces",
  "stream a single windows application to a browser": "Amazon AppStream 2.0",
  "managed spark and hadoop clusters": "Amazon EMR",
  "ship 80 tb to aws from a site with no bandwidth": "AWS Snow Family",
  "replicate an on-premises oracle database into rds": "AWS Database Migration Service",
  "trace one request across microservices": "AWS X-Ray",
  "run containers without managing ec2 instances": "AWS Fargate",
  "ingest mqtt telemetry from field sensors": "AWS IoT Core",
  "managed graphql api for a mobile app": "AWS AppSync",
  "convert text into lifelike speech": "Amazon Polly",
  "browser based ide for the team": "AWS Cloud9",
  "test a build on real physical phones": "AWS Device Farm",
  "subscribe to a third party dataset": "AWS Data Exchange",
  "buffered delivery of a stream into s3": "Amazon Data Firehose",
  "decouple two services with a queue": "Amazon SQS",
  "managed kubernetes control plane": "Amazon EKS",
  "certified experts for a short engagement": "AWS IQ"
}
JSON

    cat > "$LAB_ROOT/cases.tsv" <<'TSV'
# query<TAB>expected_service<TAB>expected_category   (CLF-C02 task 3.8 style prompts)
serverless sql queries over data in amazon s3	Amazon Athena	analytics
extract text and tables from scanned invoices	Amazon Textract	machine_learning
cloud contact center with omnichannel routing	Amazon Connect	business_applications
persistent virtual desktops for remote staff	Amazon WorkSpaces	end_user_computing
stream a single windows application to a browser	Amazon AppStream 2.0	end_user_computing
managed spark and hadoop clusters	Amazon EMR	analytics
ship 80 tb to aws from a site with no bandwidth	AWS Snow Family	migration_transfer
replicate an on-premises oracle database into rds	AWS Database Migration Service	migration_transfer
trace one request across microservices	AWS X-Ray	developer_tools
run containers without managing ec2 instances	AWS Fargate	containers
ingest mqtt telemetry from field sensors	AWS IoT Core	iot
managed graphql api for a mobile app	AWS AppSync	frontend_web_mobile
convert text into lifelike speech	Amazon Polly	machine_learning
browser based ide for the team	AWS Cloud9	developer_tools
test a build on real physical phones	AWS Device Farm	frontend_web_mobile
TSV
}

build_resolver() {
    cat > "$LAB_ROOT/resolver.py" <<'PY'
#!/usr/bin/env python3
"""Service category router for CLF-C02 task 3.8.

Exit codes:
  0  resolved / selftest clean
  2  UNRESOLVED, ORPHAN or AMBIGUOUS resolution
  3  a catalog file is not valid JSON
  4  a catalog file is unreadable
  5  catalog schema problem (missing/unexpected category, duplicate, dead alias)
"""
import json
import os
import sys

LAB = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(LAB, "catalog.json")
ALIASES = os.path.join(LAB, "catalog.d", "aliases.json")

# Categories named by the CLF-C02 exam guide, task statement 3.8.
REQUIRED = [
    "analytics",
    "application_integration",
    "business_applications",
    "containers",
    "customer_engagement",
    "developer_tools",
    "end_user_computing",
    "frontend_web_mobile",
    "iot",
    "machine_learning",
    "migration_transfer",
]


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except json.JSONDecodeError as exc:
        print("FATAL: %s: invalid JSON at line %d column %d: %s"
              % (path, exc.lineno, exc.colno, exc.msg), file=sys.stderr)
        sys.exit(3)
    except OSError as exc:
        print("FATAL: %s: %s" % (path, exc.strerror), file=sys.stderr)
        sys.exit(4)


def categories_of(catalog, service):
    hits = []
    for name, entries in catalog["categories"].items():
        for entry in entries:
            if entry.get("service", "").lower() == service.lower():
                hits.append(name)
    return sorted(set(hits))


def entry_of(catalog, service):
    for entries in catalog["categories"].values():
        for entry in entries:
            if entry.get("service", "").lower() == service.lower():
                return entry
    return {}


def selftest():
    catalog = load(CATALOG)
    aliases = load(ALIASES)
    cats = catalog.get("categories", {})

    missing = [c for c in REQUIRED if c not in cats]
    unexpected = [c for c in cats if c not in REQUIRED]

    seen, dupes = {}, []
    for name, entries in cats.items():
        for entry in entries:
            svc = entry.get("service", "")
            seen.setdefault(svc, []).append(name)
    for svc, where in sorted(seen.items()):
        if len(set(where)) > 1:
            dupes.append((svc, sorted(set(where))))

    dead = sorted(t for t in set(aliases.values()) if t not in seen)
    total = sum(len(e) for e in cats.values())

    print("catalog schema  : %s" % ("OK" if not missing and not unexpected else "PROBLEM"))
    if missing:
        print("  missing category    : %s" % ", ".join(missing))
    if unexpected:
        print("  unexpected category : %s" % ", ".join(unexpected))
    print("duplicate entries: %s" % ("none" if not dupes else ""))
    for svc, where in dupes:
        print("  %-38s appears in %s" % (svc, " + ".join(where)))
    print("dead aliases     : %s" % ("none" if not dead else ", ".join(dead)))
    print("inventory        : %d services across %d categories, %d aliases"
          % (total, len(cats), len(aliases)))

    return 5 if (missing or unexpected or dupes or dead) else 0


def list_category(name):
    catalog = load(CATALOG)
    entries = catalog["categories"].get(name)
    if entries is None:
        print("no such category: %s" % name, file=sys.stderr)
        print("known: %s" % ", ".join(sorted(catalog["categories"])), file=sys.stderr)
        return 5
    for entry in entries:
        print("%-40s %-16s %s" % (entry.get("service", "?"),
                                  entry.get("cli", "-"),
                                  entry.get("role", "")))
    return 0


def resolve(query, fmt):
    catalog = load(CATALOG)
    aliases = load(ALIASES)
    q = " ".join(query.strip().lower().split())

    service = aliases.get(q)
    if service is None:
        near = sorted({v for k, v in aliases.items() if q and (q in k or k in q)})
        if len(near) == 1:
            service = near[0]

    if service is None:
        status, cats, entry = "UNRESOLVED", [], {}
    else:
        cats = categories_of(catalog, service)
        entry = entry_of(catalog, service)
        if not cats:
            status = "ORPHAN"
        elif len(cats) > 1:
            status = "AMBIGUOUS"
        else:
            status = "OK"

    category = ",".join(cats)
    if fmt == "kv":
        print("query=%s" % q)
        print("service=%s" % (service or ""))
        print("category=%s" % category)
        print("probe=%s" % entry.get("probe", ""))
        print("status=%s" % status)
    else:
        print("query    : %s" % q)
        print("service  : %s" % (service or "<none>"))
        print("category : %s" % (category or "<none>"))
        print("role     : %s" % entry.get("role", "-"))
        print("probe    : %s" % entry.get("probe", "-"))
        print("status   : %s" % status)
    return 0 if status == "OK" else 2


def main(argv):
    if not argv:
        print(__doc__.splitlines()[0], file=sys.stderr)
        print("usage: resolver.py [--selftest | --list CATEGORY | [--format kv] QUERY]",
              file=sys.stderr)
        return 64
    if argv[0] == "--selftest":
        return selftest()
    if argv[0] == "--list":
        return list_category(argv[1]) if len(argv) > 1 else 64
    fmt = "human"
    if argv[0] == "--format":
        fmt, argv = argv[1], argv[2:]
    return resolve(" ".join(argv), fmt)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
    chmod +x "$LAB_ROOT/resolver.py"
}

build_verify() {
    cat > "$LAB_ROOT/verify.sh" <<'SH'
#!/usr/bin/env bash
# Grader for CLF-C02 task 3.8. Exits 0 only when every use case resolves to the
# service AND the category the exam guide files it under, and the lab-scoped
# AWS CLI profile lints clean.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$LAB/awscli/config"
pass=0; fail=0; lintfail=0

printf '== preflight ==\n'
"$LAB/resolver.py" --selftest
rc=$?
if [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; then
    printf '\npreflight ABORTED: a catalog file cannot even be parsed.\n'
    printf 'Fix that first - nothing downstream can be trusted until it loads.\n'
    exit 1
fi
[ "$rc" -eq 5 ] && printf '(schema problems above are real failures, continuing to the use cases)\n'

printf '\n== use cases ==\n'
n=0
while IFS=$'\t' read -r query want_svc want_cat; do
    case "$query" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    out="$("$LAB/resolver.py" --format kv "$query" 2>&1)"
    got_svc="$(printf '%s\n' "$out" | sed -n 's/^service=//p')"
    got_cat="$(printf '%s\n' "$out" | sed -n 's/^category=//p')"
    got_st="$(printf '%s\n'  "$out" | sed -n 's/^status=//p')"
    if [ "$got_svc" = "$want_svc" ] && [ "$got_cat" = "$want_cat" ] && [ "$got_st" = "OK" ]; then
        pass=$((pass + 1))
        printf '[%02d] PASS  %s / %s\n' "$n" "$got_svc" "$got_cat"
    else
        fail=$((fail + 1))
        printf '[%02d] FAIL  "%s"\n' "$n" "$query"
        printf '          want %s / %s\n' "$want_svc" "$want_cat"
        printf '          got  %s / %s (status=%s)\n' "${got_svc:-<none>}" "${got_cat:-<none>}" "${got_st:-ERROR}"
    fi
done < "$LAB/cases.tsv"

printf '\n== aws cli profile lint (profile clf-lab, %s) ==\n' "$CFG"
cfg_get() {
    if command -v aws >/dev/null 2>&1; then
        AWS_CONFIG_FILE="$CFG" aws configure get "$1" --profile clf-lab 2>/dev/null || true
    else
        awk -F= -v k="$1" '
            /^\[/ { inp = ($0 == "[profile clf-lab]") }
            inp && $1 ~ "^[ \t]*"k"[ \t]*$" { sub(/^[ \t]+/, "", $2); sub(/[ \t]+$/, "", $2); print $2; exit }
        ' "$CFG"
    fi
}
region="$(cfg_get region)"
output="$(cfg_get output)"
if printf '%s' "$region" | grep -Eq '^[a-z]{2}(-gov|-iso[a-z]?)?-(central|east|north|northeast|northwest|south|southeast|southwest|west)-[0-9]$'; then
    printf 'region : %-12s PASS\n' "$region"
else
    lintfail=$((lintfail + 1))
    printf 'region : %-12s FAIL (not a syntactically valid AWS region id)\n' "${region:-<unset>}"
fi
case "$output" in
    json|yaml|yaml-stream|text|table)
        printf 'output : %-12s PASS\n' "$output" ;;
    *)
        lintfail=$((lintfail + 1))
        printf 'output : %-12s FAIL (must be json|yaml|yaml-stream|text|table)\n' "${output:-<unset>}" ;;
esac
command -v aws >/dev/null 2>&1 || printf '(aws CLI not installed - config parsed with awk instead)\n'

printf '\n== summary ==\n'
printf 'use cases : %d PASS / %d FAIL (of %d)\n' "$pass" "$fail" "$n"
printf 'schema    : %s\n' "$([ "$rc" -eq 0 ] && echo OK || echo PROBLEM)"
printf 'cli lint  : %d FAIL\n' "$lintfail"
if [ "$fail" -eq 0 ] && [ "$lintfail" -eq 0 ] && [ "$rc" -eq 0 ]; then
    printf 'RESULT    : PASS\n'
    exit 0
fi
printf 'RESULT    : FAIL\n'
exit 1
SH
    chmod +x "$LAB_ROOT/verify.sh"
}

build_awscli_profile() {
    mkdir -p "$LAB_ROOT/awscli"
    cat > "$LAB_ROOT/awscli/config" <<'INI'
# Lab-scoped AWS CLI configuration. Used ONLY through AWS_CONFIG_FILE; your real
# ~/.aws is never read by this lab. No credentials here, no API calls are made.
[profile clf-lab]
region = us-east-1
output = json
cli_pager =
INI
    cat > "$LAB_ROOT/awscli/credentials" <<'INI'
# Intentionally empty: this lab performs no authenticated calls.
INI
    chmod 600 "$LAB_ROOT/awscli/credentials"
}

build_lab() {
    mkdir -p "$LAB_ROOT"
    printf 'aws-clf / CLF-C02 / topic 3.8 break-and-fix lab\n' > "$LAB_ROOT/$MARKER"
    build_catalog
    build_resolver
    build_verify
    build_awscli_profile
}

snapshot_pristine() {
    mkdir -p "$SNAP_DIR"
    tar -czf "$SNAP_TGZ" -C "$(dirname "$LAB_ROOT")" "$(basename "$LAB_ROOT")"
}

# ------------------------------------------------------------------- break ---
break_it() {
    python3 - "$LAB_ROOT" <<'PY'
import json
import os
import sys

lab = sys.argv[1]
catalog_path = os.path.join(lab, "catalog.json")
aliases_path = os.path.join(lab, "catalog.d", "aliases.json")

with open(catalog_path, encoding="utf-8") as fh:
    catalog = json.load(fh)
cats = catalog["categories"]


def take(category, service):
    for i, entry in enumerate(cats[category]):
        if entry["service"] == service:
            return cats[category].pop(i)
    raise SystemExit("break aborted: %s not found in %s" % (service, category))


# Vector 1 - a category key is renamed. Every service under it now reports a
# category name that does not exist in the exam guide, and the schema check
# reports one missing + one unexpected key.
cats["end_user_compute"] = cats.pop("end_user_computing")

# Vector 2 - two services swap categories. Structurally perfect, semantically
# wrong: this one is invisible to any schema check and can only be caught by
# knowing how AWS actually files Athena and Textract.
textract = take("machine_learning", "Amazon Textract")
athena = take("analytics", "Amazon Athena")
cats["analytics"].append(textract)
cats["machine_learning"].append(athena)

# Vector 3 - an entry is deleted outright. The alias still points at it, so the
# resolver reports ORPHAN rather than a wrong answer.
cats["business_applications"] = [
    e for e in cats["business_applications"] if e["service"] != "Amazon Connect"
]

# Vector 4 - an entry is duplicated into a second category. Both copies are
# valid JSON; resolution becomes AMBIGUOUS.
emr = next(e for e in cats["analytics"] if e["service"] == "Amazon EMR")
cats["migration_transfer"].append(dict(emr))

with open(catalog_path, "w", encoding="utf-8") as fh:
    json.dump(catalog, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

# Vector 5 - a trailing comma in aliases.json. The file is one byte away from
# valid and json.load refuses it; every lookup dies before any logic runs.
with open(aliases_path, encoding="utf-8") as fh:
    raw = fh.read().rstrip()
assert raw.endswith("}")
with open(aliases_path, "w", encoding="utf-8") as fh:
    fh.write(raw[:-1].rstrip() + ",\n}\n")
PY

    # Vector 6 - CLI profile drift: an impossible region id and an output format
    # the CLI does not implement. Nothing here touches ~/.aws.
    sed -i \
        -e 's/^region = .*/region = us-east-99/' \
        -e 's/^output = .*/output = tabular/' \
        "$LAB_ROOT/awscli/config"
}

# ----------------------------------------------------------------- briefing ---
brief() {
    cat > "$LAB_ROOT/BRIEFING.md" <<'MD'
# Break & Fix - CLF-C02 task 3.8: identify services from other in-scope categories

## Scenario

You have inherited the platform team's **service category router**: the table a
request intake bot uses to turn a workload description ("we need to extract
tables from scanned invoices") into the AWS service that does it and the service
category AWS files it under. Categories drive the tagging policy, the cost
allocation report and which team gets paged, so a service in the wrong category
is not a cosmetic bug.

Somebody edited the catalog by hand and the pipeline has been red since.

## Files

    catalog.json            categories -> [ {service, cli, probe, role}, ... ]
    catalog.d/aliases.json  workload phrase -> canonical service name
    cases.tsv               the 15 graded use cases (query, expected service, expected category)
    resolver.py             the router: --selftest | --list CATEGORY | [--format kv] "query"
    verify.sh               the grader - this is the thing that must exit 0
    awscli/config           lab-scoped AWS CLI profile (used via AWS_CONFIG_FILE only)

## Symptom you will see

Run the grader:

    cd LAB_ROOT_PLACEHOLDER
    ./verify.sh ; echo "exit=$?"

It aborts at preflight, before grading anything:

    == preflight ==
    FATAL: .../catalog.d/aliases.json: invalid JSON at line 21 column 1: Expecting property name enclosed in double quotes

    preflight ABORTED: a catalog file cannot even be parsed.
    Fix that first - nothing downstream can be trusted until it loads.
    exit=1

Once the file parses again, the preflight completes and the grader gets to the
use cases - where you will see a mix of these statuses:

  * `status=OK` but the **category is wrong**  - the service exists, filed under
    the wrong heading.
  * `status=ORPHAN`    - the alias resolves to a service that is in no category
    at all, i.e. somebody deleted the entry.
  * `status=AMBIGUOUS` - one service is listed under two categories, so the
    router cannot pick one.

and the CLI lint at the bottom will reject the profile:

    region : us-east-99   FAIL (not a syntactically valid AWS region id)
    output : tabular      FAIL (must be json|yaml|yaml-stream|text|table)

## What you must achieve

`./verify.sh` exits **0** with:

    use cases : 15 PASS / 0 FAIL (of 15)
    schema    : OK
    cli lint  : 0 FAIL
    RESULT    : PASS

Rules:

1. Do **not** restore the snapshot (`break-fix-3.8.sh --reset`) except to start
   over from scratch. Diffing it is not a diagnosis.
2. Do **not** edit `verify.sh`, `cases.tsv` or `resolver.py`. The grader and the
   expectations are the specification; the catalog and the CLI profile are the
   things that are wrong.
3. Every fix must be defensible against the exam guide's own category list, not
   against your intuition.

## Diagnostic toolkit

    python3 -m json.tool catalog.d/aliases.json      # exact line/column of a parse error
    ./resolver.py --selftest                         # missing/unexpected categories, duplicates, dead aliases
    ./resolver.py --list machine_learning            # what is currently filed under a category
    ./resolver.py "convert text into lifelike speech"
    AWS_CONFIG_FILE=$PWD/awscli/config aws configure get region --profile clf-lab
    AWS_CONFIG_FILE=$PWD/awscli/config aws configure list --profile clf-lab

## The 11 categories in scope for task 3.8

analytics, application_integration, business_applications, containers,
customer_engagement, developer_tools, end_user_computing, frontend_web_mobile,
iot, machine_learning, migration_transfer

Source: AWS Certified Cloud Practitioner (CLF-C02) Exam Guide, task statement 3.8
https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf

## Working order that actually converges

1. Make the data **load** (parse errors first - they mask everything else).
2. Make the schema **structurally** valid (`--selftest`: keys, duplicates, dead aliases).
3. Make it **semantically** correct (the remaining FAILs, one category call at a time).
4. Fix the **environment** (the CLI profile lint).
5. Re-run the grader; only a green run counts.
MD
    sed -i "s#LAB_ROOT_PLACEHOLDER#$LAB_ROOT#" "$LAB_ROOT/BRIEFING.md"

    say ""
    say "=============================================================================="
    say " Lab ready and broken:  $LAB_ROOT"
    say " Briefing:              $LAB_ROOT/BRIEFING.md"
    say " Pristine snapshot:     $SNAP_TGZ   (restore with --reset)"
    say "=============================================================================="
    say ""
    say " Start here:"
    say "   cd $LAB_ROOT"
    say "   cat BRIEFING.md"
    say "   ./verify.sh ; echo \"exit=\$?\""
    say ""
    say " SYMPTOM  the grader aborts at preflight with a JSON parse error; once the"
    say "          file loads, several of the 15 use cases fail with WRONG CATEGORY,"
    say "          ORPHAN or AMBIGUOUS, and the AWS CLI profile lint rejects both the"
    say "          region and the output format."
    say " GOAL     ./verify.sh exits 0: 15/15 PASS, schema OK, 0 lint failures,"
    say "          without restoring the snapshot and without editing verify.sh,"
    say "          cases.tsv or resolver.py."
    say ""
}

# -------------------------------------------------------------------- main ---
guard_environment
[ "$DO_RESET" = "1" ] && do_reset

say "[1/4] building the lab in $LAB_ROOT ..."
build_lab
say "[2/4] snapshotting the pristine state ..."
snapshot_pristine
say "[3/4] breaking it (6 controlled vectors, all inside the lab directory) ..."
break_it
say "[4/4] writing the briefing ..."
brief

exit 0

# ==============================================================================
#  SOLUTION - do not read until you have made verify.sh green on your own.
# ==============================================================================
#
#  Six defects were injected. Fix them in dependency order: nothing that follows
#  can be trusted while the data does not parse.
#
#  ---------------------------------------------------------------------------
#  STEP 0 - reproduce and classify
#  ---------------------------------------------------------------------------
#    cd "$HOME/aws-clf-lab/topic-3.8"
#    ./verify.sh ; echo "exit=$?"
#
#  Expected:
#    == preflight ==
#    FATAL: .../catalog.d/aliases.json: invalid JSON at line 21 column 1: Expecting property name enclosed in double quotes
#    preflight ABORTED: a catalog file cannot even be parsed.
#    exit=1
#
#  Note the discipline: the grader refuses to grade on unparseable input instead
#  of reporting 15 spurious failures. Same reason a CI job should fail fast on a
#  malformed config rather than "helpfully" running with defaults.
#
#  ---------------------------------------------------------------------------
#  STEP 1 - defect #5: trailing comma in catalog.d/aliases.json
#  ---------------------------------------------------------------------------
#  Confirm with the stdlib parser, which prints line and column:
#
#    python3 -m json.tool catalog.d/aliases.json
#    # Expecting property name enclosed in double quotes: line 21 column 1 (char 1418)
#
#  Line 21 is the closing brace, so the offending byte is the comma that ends
#  line 20. JSON, unlike YAML or Python, forbids trailing commas.
#
#    tail -3 catalog.d/aliases.json
#    #   "certified experts for a short engagement": "AWS IQ",
#    # }
#
#  Fix (either edit line 20 by hand and delete the comma, or):
#
#    python3 - <<'EOF'
#    import pathlib, re
#    p = pathlib.Path("catalog.d/aliases.json")
#    p.write_text(re.sub(r",(\s*})", r"\1", p.read_text()))
#    EOF
#
#  Verify:
#    python3 -m json.tool catalog.d/aliases.json >/dev/null && echo "aliases parse OK"
#
#  ---------------------------------------------------------------------------
#  STEP 2 - see the structural damage
#  ---------------------------------------------------------------------------
#    ./resolver.py --selftest ; echo "exit=$?"
#
#  Expected:
#    catalog schema  : PROBLEM
#      missing category    : end_user_computing
#      unexpected category : end_user_compute
#    duplicate entries:
#      Amazon EMR                             appears in analytics + migration_transfer
#    dead aliases     : Amazon Connect
#    inventory        : 52 services across 11 categories, 20 aliases
#    exit=5
#
#  That single command names three of the remaining five defects. It cannot name
#  the fourth (the Athena/Textract swap) because a swap is structurally perfect -
#  only domain knowledge catches it. That asymmetry is the lesson of this lab.
#
#  ---------------------------------------------------------------------------
#  STEP 3 - defect #1: renamed category key
#  ---------------------------------------------------------------------------
#  The exam guide's category is "End-user computing" (Amazon WorkSpaces,
#  Amazon AppStream 2.0, Amazon WorkSpaces Secure Browser). The key must be
#  end_user_computing; end_user_compute is invented.
#
#    python3 - <<'EOF'
#    import json, pathlib
#    p = pathlib.Path("catalog.json"); d = json.loads(p.read_text())
#    d["categories"]["end_user_computing"] = d["categories"].pop("end_user_compute")
#    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
#    EOF
#
#  ---------------------------------------------------------------------------
#  STEP 4 - defect #2: Athena and Textract swapped categories
#  ---------------------------------------------------------------------------
#  Nothing flags this; you have to look:
#
#    ./resolver.py --list analytics        | cut -c1-60
#    ./resolver.py --list machine_learning | cut -c1-60
#
#  You will find Amazon Textract listed under analytics and Amazon Athena under
#  machine_learning. Both are wrong, and the reasoning is what the exam tests:
#
#    * Amazon Athena is ANALYTICS. It is a query engine - serverless SQL over S3
#      via Trino/Presto, priced per TB scanned. It contains no model. The fact
#      that it is "smart about data" does not make it machine learning.
#    * Amazon Textract is MACHINE LEARNING. It is a pre-trained AI service that
#      extracts text, form key/value pairs and table structure from documents.
#      Its output often lands in an analytics pipeline, but the service itself is
#      an ML inference API. Classify by what the service DOES, not by what its
#      output is later used for - the single most common trap in task 3.8.
#
#    python3 - <<'EOF'
#    import json, pathlib
#    p = pathlib.Path("catalog.json"); d = json.loads(p.read_text()); c = d["categories"]
#    def move(svc, src, dst):
#        for i, e in enumerate(c[src]):
#            if e["service"] == svc:
#                c[dst].append(c[src].pop(i)); return
#        raise SystemExit("%s not found in %s" % (svc, src))
#    move("Amazon Textract", "analytics", "machine_learning")
#    move("Amazon Athena", "machine_learning", "analytics")
#    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
#    EOF
#
#  ---------------------------------------------------------------------------
#  STEP 5 - defect #3: Amazon Connect was deleted
#  ---------------------------------------------------------------------------
#  "dead aliases: Amazon Connect" means the alias resolves to a service that
#  exists in no category. Amazon Connect belongs to BUSINESS APPLICATIONS - it is
#  the omnichannel cloud contact center (telephony, chat, IVR, per-minute
#  pricing). Do not confuse it with AWS Direct Connect (networking) or with
#  Amazon Chime; the exam deliberately places those names close together.
#
#    python3 - <<'EOF'
#    import json, pathlib
#    p = pathlib.Path("catalog.json"); d = json.loads(p.read_text())
#    d["categories"]["business_applications"].insert(0, {
#        "service": "Amazon Connect",
#        "cli": "connect",
#        "probe": "aws connect list-instances",
#        "role": "Omnichannel cloud contact center: telephony, chat, IVR flows, "
#                "per-minute pricing, integrates with Lex bots and Transcribe.",
#    })
#    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
#    EOF
#
#  ---------------------------------------------------------------------------
#  STEP 6 - defect #4: Amazon EMR duplicated into migration_transfer
#  ---------------------------------------------------------------------------
#  EMR is ANALYTICS (managed Spark/Hadoop/Hive/Presto). It appears in
#  migration_transfer because somebody pasted it there - possibly reasoning that
#  "we use EMR during the data migration". A workload that uses a service does
#  not move that service's category. Remove the copy in migration_transfer and
#  keep the one in analytics.
#
#    python3 - <<'EOF'
#    import json, pathlib
#    p = pathlib.Path("catalog.json"); d = json.loads(p.read_text())
#    mt = d["categories"]["migration_transfer"]
#    d["categories"]["migration_transfer"] = [e for e in mt if e["service"] != "Amazon EMR"]
#    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
#    EOF
#
#  Now the structural check must be clean:
#
#    ./resolver.py --selftest ; echo "exit=$?"
#    # catalog schema  : OK
#    # duplicate entries: none
#    # dead aliases     : none
#    # inventory        : 52 services across 11 categories, 20 aliases
#    # exit=0
#
#  ---------------------------------------------------------------------------
#  STEP 7 - defect #6: the lab-scoped AWS CLI profile
#  ---------------------------------------------------------------------------
#    export AWS_CONFIG_FILE="$PWD/awscli/config"
#    aws configure list --profile clf-lab
#
#          Name                    Value             Type    Location
#          ----                    -----             ----    --------
#       profile                  clf-lab           manual    --profile
#        region                us-east-99      config-file    ~/.aws/config
#
#  "us-east-99" is syntactically impossible: AWS region ids are
#  <geo>-<direction>-<single digit>, e.g. us-east-1, eu-west-3, sa-east-1,
#  ap-southeast-2. A bad region does not fail at config time - it fails later at
#  endpoint resolution, which is why config linting belongs in CI. "tabular" is
#  likewise not an output format; the CLI accepts json, yaml, yaml-stream, text
#  and table only.
#
#    aws configure set region us-east-1 --profile clf-lab
#    aws configure set output json      --profile clf-lab
#
#  Without the AWS CLI installed, edit awscli/config directly:
#
#    sed -i -e 's/^region = .*/region = us-east-1/' \
#           -e 's/^output = .*/output = json/' awscli/config
#
#  ---------------------------------------------------------------------------
#  STEP 8 - final verification
#  ---------------------------------------------------------------------------
#    ./verify.sh ; echo "exit=$?"
#
#    == preflight ==
#    catalog schema  : OK
#    duplicate entries: none
#    dead aliases     : none
#    inventory        : 52 services across 11 categories, 20 aliases
#
#    == use cases ==
#    [01] PASS  Amazon Athena / analytics
#    [02] PASS  Amazon Textract / machine_learning
#    ...
#    [15] PASS  AWS Device Farm / frontend_web_mobile
#
#    == aws cli profile lint (profile clf-lab, .../awscli/config) ==
#    region : us-east-1    PASS
#    output : json         PASS
#
#    == summary ==
#    use cases : 15 PASS / 0 FAIL (of 15)
#    schema    : OK
#    cli lint  : 0 FAIL
#    RESULT    : PASS
#    exit=0
#
#  ---------------------------------------------------------------------------
#  EXAM NOTES - the discriminations this lab was built around
#  ---------------------------------------------------------------------------
#  * Athena vs EMR                : serverless query engine, per-TB-scanned, no
#                                   cluster  vs  managed Spark/Hadoop clusters you
#                                   size and tune. Both analytics.
#  * Kinesis Data Streams vs Data Firehose : shards, ordering, replayable
#                                   retention, you write the consumer  vs  buffered
#                                   no-code delivery to S3/Redshift/OpenSearch, no
#                                   replay. Both analytics.
#  * Textract vs Rekognition vs Comprehend : documents (forms and tables)  vs
#                                   images and video  vs  raw text (entities,
#                                   sentiment, PII). All machine learning.
#  * Polly vs Transcribe vs Translate      : text to speech  vs  speech to text  vs
#                                   language to language. All machine learning.
#  * WorkSpaces vs AppStream 2.0  : a persistent full desktop  vs  one streamed
#                                   application. Both end-user computing.
#  * Snow Family vs DataSync      : offline, physical, no usable bandwidth  vs
#                                   online, accelerated, bandwidth exists. Both
#                                   migration and transfer.
#  * DMS vs Application Migration Service  : database replication with the source
#                                   online (add the Schema Conversion Tool for a
#                                   heterogeneous engine change)  vs  block-level
#                                   server rehost into EC2.
#  * ECS vs EKS vs Fargate vs ECR : AWS-native orchestrator  vs  managed Kubernetes
#                                   vs  serverless capacity type for either (not a
#                                   standalone orchestrator)  vs  the registry.
#  * Amazon Connect vs AWS Direct Connect  : contact center (business
#                                   applications)  vs  dedicated private network
#                                   link (networking, task 3.3). Name collision,
#                                   deliberately.
#  * AppSync vs API Gateway       : managed GraphQL with subscriptions and offline
#                                   sync (front-end web and mobile)  vs  REST/HTTP
#                                   and WebSocket APIs (application integration /
#                                   compute front door).
#  * X-Ray vs CloudWatch          : per-request distributed traces and a service
#                                   graph (developer tools)  vs  metrics, logs and
#                                   alarms (management and governance, task 3.9).
#
#  Source of the category list and the in-scope service names, throughout:
#  AWS Certified Cloud Practitioner (CLF-C02) Exam Guide, task statement 3.8
#  https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
# ==============================================================================