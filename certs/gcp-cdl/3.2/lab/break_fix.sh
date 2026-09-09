#!/usr/bin/env bash
#
# =============================================================================
#  BREAK & FIX LAB — Google Cloud Digital Leader (gcp-cdl)
#  Exam version : 2026-08-12
#  Section 3.2  : Explain how Google Cloud's AI offerings can create business value
#  Exam weight  : 9.0
#
#  Primary source (objectives):
#    https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#
#  WHAT THIS LAB IS
#  ----------------
#  A self-contained, OFFLINE simulation of an internal "AI advisor" service: a
#  tiny HTTP API that answers the only question section 3.2 really asks —
#  "given this business problem, which Google Cloud AI offering creates value,
#  and why?".
#
#  The installer builds the service, proves it healthy, then injects five
#  controlled faults. Four are operational (identity, configuration, data
#  integrity, governance flag); the fifth is the one that carries the exam
#  content: the scenario-to-offering mapping is wrong, and you cannot repair it
#  by reading logs — only by knowing what each Google Cloud AI product is for.
#
#  SAFETY / BLAST RADIUS
#  ---------------------
#  * It calls NO Google API, authenticates against NOTHING, and sends no traffic
#    off the box. The "service account key" it reads is fake JSON this script
#    writes itself; it exists so the lab can reproduce, safely, the failure mode
#    of a workload that cannot read its Application Default Credentials (ADC).
#  * It binds only to 127.0.0.1.
#  * It writes ONLY to the paths listed by `--dry-run`, and `uninstall` removes
#    every one of them plus the service user.
#  * Run it on a DISPOSABLE lab VM. It creates a system user and a systemd unit;
#    that is not something to do on a workstation you care about.
#
#  USAGE
#  -----
#    sudo ./cdl-3.2-break-fix.sh --dry-run        # show exactly what it touches
#    sudo ./cdl-3.2-break-fix.sh install --confirm
#    sudo ./cdl-3.2-break-fix.sh verify           # your scoreboard — run it often
#    sudo ./cdl-3.2-break-fix.sh hint [1..5]      # progressive hints, no answers
#    sudo ./cdl-3.2-break-fix.sh status
#    sudo ./cdl-3.2-break-fix.sh restore --confirm  # INSTRUCTOR ESCAPE HATCH
#    sudo ./cdl-3.2-break-fix.sh uninstall --confirm
#
#  The full worked solution is at the BOTTOM of this file, commented out.
#  Read it after you have tried, not before — the diagnosis is the lesson.
# =============================================================================

set -Eeuo pipefail

# ------------------------------- constants ----------------------------------
readonly LAB_ID="cdl-3.2"
readonly LAB_ROOT="/opt/cdl-lab/3.2"
readonly ETC_DIR="/etc/cdl-lab"
readonly ENV_FILE="${ETC_DIR}/3.2.env"
readonly CLIENT_ENV="${ETC_DIR}/3.2.client.env"
readonly KEY_DIR="${ETC_DIR}/keys"
readonly KEY_FILE="${KEY_DIR}/lab-sa.json"
readonly STATE_DIR="/var/lib/cdl-lab/3.2"
readonly ANSWER_KEY="${STATE_DIR}/answer.key.b64"
readonly CATALOG_FILE="${LAB_ROOT}/catalog/ai_offerings.json"
readonly MAP_FILE="${LAB_ROOT}/catalog/scenario_map.json"
readonly SERVER_BIN="${LAB_ROOT}/bin/advisor_server.py"
readonly VERIFY_BIN="${LAB_ROOT}/bin/verify.sh"
readonly RUNBOOK="${LAB_ROOT}/RUNBOOK.md"
readonly CLIENT_BIN="/usr/local/bin/aiadvisor"
readonly SVC_USER="cdlai"
readonly SVC_NAME="cdl-ai-advisor.service"
readonly UNIT_FILE="/etc/systemd/system/${SVC_NAME}"
readonly CONTRACT_PORT="8080"   # the documented service contract — do not change
readonly WRONG_PORT="8090"      # injected by FAULT 2

# --------------------------------- output -----------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RST="$(tput sgr0)"; C_B="$(tput bold)"; C_R="$(tput setaf 1)"
    C_G="$(tput setaf 2)"; C_Y="$(tput setaf 3)"; C_C="$(tput setaf 6)"
else
    C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

log()   { printf '%s[ %s ]%s %s\n' "$C_C" "$LAB_ID" "$C_RST" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_Y" "$C_RST" "$*" >&2; }
die()   { printf '%s[FAIL]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }
rule()  { printf '%s%s%s\n' "$C_B" "--------------------------------------------------------------------------" "$C_RST"; }
head1() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_RST"; rule; }

trap 'rc=$?; [[ $rc -ne 0 ]] && printf "%s[FAIL]%s aborted at line %s (exit %s)\n" "$C_R" "$C_RST" "$LINENO" "$rc" >&2; exit $rc' ERR

# ------------------------------- guardrails ---------------------------------
CONFIRMED=0

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "run as root (sudo $0 $*) — it installs a systemd unit and a system user."
}

require_tooling() {
    local missing=()
    for t in python3 systemctl curl base64 install useradd; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "missing required tools: ${missing[*]}"
    [[ -d /run/systemd/system ]] || die "this host is not running systemd; the lab needs it for the service-failure exercise."
    python3 - <<'PY' >/dev/null 2>&1 || die "python3 >= 3.7 required (ThreadingHTTPServer)."
import sys
sys.exit(0 if sys.version_info >= (3, 7) else 1)
PY
}

show_footprint() {
    head1 "Everything this lab creates or modifies"
    cat <<EOF
  ${LAB_ROOT}/                 lab tree (server, catalog, verifier, runbook)
  ${ETC_DIR}/                  env files and the FAKE credential file
  ${STATE_DIR}/                lab state + the answer key (root-only, 0600)
  ${UNIT_FILE}
  ${CLIENT_BIN}                thin curl wrapper named 'aiadvisor'
  system user/group '${SVC_USER}'  (--system, nologin, no home)
  TCP 127.0.0.1:${CONTRACT_PORT} and 127.0.0.1:${WRONG_PORT} (loopback only)

  No outbound network. No Google API call. No gcloud invocation. No change to
  any file outside the list above. 'uninstall' removes all of it.
EOF
}

confirm_disposable() {
    if [[ "$CONFIRMED" -eq 1 || "${CDL_LAB_CONFIRM:-}" == "yes" ]]; then
        return 0
    fi
    show_footprint
    cat >&2 <<EOF

${C_Y}This is destructive-by-design and belongs on a THROWAWAY VM.${C_RST}
Re-run with --confirm (or CDL_LAB_CONFIRM=yes) to proceed.
EOF
    exit 2
}

port_is_free() {
    python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

relabel_selinux() {
    if command -v restorecon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]]; then
        restorecon -RF "$LAB_ROOT" "$ETC_DIR" "$STATE_DIR" "$UNIT_FILE" "$CLIENT_BIN" >/dev/null 2>&1 || true
    fi
}

# ============================ generated artifacts ============================

write_layout() {
    install -d -m 0755 "${LAB_ROOT}/bin" "${LAB_ROOT}/catalog" "$ETC_DIR"
    install -d -m 0750 "$KEY_DIR"
    install -d -m 0700 "$STATE_DIR"
    if ! getent group "$SVC_USER" >/dev/null; then groupadd --system "$SVC_USER"; fi
    if ! getent passwd "$SVC_USER" >/dev/null; then
        local nologin; nologin="$(command -v nologin || echo /sbin/nologin)"
        useradd --system --gid "$SVC_USER" --no-create-home --home-dir /nonexistent \
                --shell "$nologin" --comment "CDL 3.2 lab AI advisor" "$SVC_USER"
    fi
}

# --- the AI offerings catalog: the study payload of this topic ---------------
write_catalog() {
    cat > "$CATALOG_FILE" <<'JSON'
{
  "schema": "cdl-lab/ai-offerings/v1",
  "note": "Original summaries written for this lab. Each entry cites the official Google Cloud documentation page for that product.",
  "offerings": {
    "document-ai": {
      "product": "Document AI",
      "family": "Pre-trained / task-specific API",
      "what_it_is": "Managed parsers that turn unstructured documents (invoices, contracts, IDs, forms) into structured fields with confidence scores and a human-in-the-loop review path.",
      "business_value": "Removes manual keying from a document-heavy back office. The unit of value is cost per document and days of processing latency, not model accuracy in the abstract.",
      "when_to_choose": "The input is documents, the output is fields, and the shape of the problem is already solved by a specialised parser.",
      "docs": "https://cloud.google.com/document-ai/docs/overview"
    },
    "vision-api": {
      "product": "Cloud Vision API",
      "family": "Pre-trained / task-specific API",
      "what_it_is": "Pre-trained image understanding: label detection, OCR text extraction, logo and landmark detection, explicit-content safety signals.",
      "business_value": "Image intelligence with zero training data and zero ML staff — an API call, priced per image.",
      "when_to_choose": "Generic image labels or raw OCR are enough. If you need business fields out of a structured document, that is Document AI, not raw OCR.",
      "docs": "https://cloud.google.com/vision/docs"
    },
    "speech-to-text": {
      "product": "Speech-to-Text",
      "family": "Pre-trained / task-specific API",
      "what_it_is": "Streaming and batch transcription across many languages, with speaker diarization, punctuation, and domain adaptation via model classes.",
      "business_value": "Turns an unsearchable audio archive into text that analytics and QA can actually query — the precondition for measuring anything about a call centre.",
      "when_to_choose": "The raw asset is audio and the first blocker is that nobody can read it.",
      "docs": "https://cloud.google.com/speech-to-text/docs"
    },
    "natural-language-ai": {
      "product": "Cloud Natural Language API",
      "family": "Pre-trained / task-specific API",
      "what_it_is": "Entity extraction, sentiment scoring, syntax and content classification over free text.",
      "business_value": "Quantifies opinion at a volume no human review panel can reach: survey verbatims, reviews, tickets.",
      "when_to_choose": "You already have text and you need structured signals (who, what, how they feel) out of it.",
      "docs": "https://cloud.google.com/natural-language/docs"
    },
    "translation-ai": {
      "product": "Translation AI",
      "family": "Pre-trained / task-specific API",
      "what_it_is": "Machine translation across a large language set, with glossaries and AutoML custom models for domain vocabulary.",
      "business_value": "Opens a market or a support channel without hiring per language.",
      "when_to_choose": "The gap is strictly language, not dialogue design.",
      "docs": "https://cloud.google.com/translate/docs"
    },
    "bigquery-ml": {
      "product": "BigQuery ML",
      "family": "SQL-native ML on the warehouse",
      "what_it_is": "Create, train, evaluate and predict with models using SQL DDL inside BigQuery, over data that never leaves the warehouse.",
      "business_value": "Collapses the classic export/train/re-import loop. The people who already write the SQL become the people who ship the model, so time-to-first-model is days, not a hiring cycle.",
      "when_to_choose": "Data is already in BigQuery, the team is analysts rather than ML engineers, and the problem is tabular (churn, forecast, propensity, segmentation).",
      "docs": "https://cloud.google.com/bigquery/docs/bqml-introduction"
    },
    "vertex-ai-automl": {
      "product": "Vertex AI — AutoML",
      "family": "Low-code custom model training",
      "what_it_is": "Trains a custom model on YOUR labelled data (image, tabular, text, video) with the architecture search and tuning handled by the platform.",
      "business_value": "Buys a genuinely custom model without a research team. The company supplies labelled examples and domain knowledge; Google supplies the ML.",
      "when_to_choose": "A pre-trained API cannot know your categories (your defects, your SKUs, your document classes) but you have labelled examples and no data scientists.",
      "docs": "https://cloud.google.com/vertex-ai/docs/training-overview"
    },
    "vertex-ai-platform": {
      "product": "Vertex AI (platform, custom training and MLOps)",
      "family": "Full ML platform",
      "what_it_is": "One managed platform across the ML lifecycle: Workbench, custom training, Feature Store, Model Registry, Pipelines, online and batch prediction, Model Monitoring and evaluation.",
      "business_value": "Turns models into governed, versioned, retrainable production assets — lineage, approvals, drift alerts, reproducible pipelines. This is the answer when the risk is operational, not algorithmic.",
      "when_to_choose": "You have models in production (from anywhere) and the problem is governance, drift, reproducibility or scale — or you genuinely need custom training with your own framework and code.",
      "docs": "https://cloud.google.com/vertex-ai/docs/start/introduction-unified-platform"
    },
    "model-garden": {
      "product": "Vertex AI Model Garden",
      "family": "Generative AI — model access",
      "what_it_is": "A single catalogue for Google first-party models (Gemini, Imagen, Veo), selected third-party models, and open models, with one deployment and tuning path.",
      "business_value": "Model choice becomes a configuration decision instead of a re-platforming project; you can benchmark cost against quality per use case and switch.",
      "when_to_choose": "You are choosing or comparing foundation models rather than building one.",
      "docs": "https://cloud.google.com/vertex-ai/generative-ai/docs/model-garden/explore-models"
    },
    "vertex-ai-search": {
      "product": "Vertex AI Search (Agent Builder)",
      "family": "Generative AI — grounded retrieval",
      "what_it_is": "Google-quality enterprise search and grounded answer generation over your own corpora (documents, sites, structured data), with citations and ACL-aware results.",
      "business_value": "Cuts the time employees or customers spend hunting through a corpus nobody can index by hand, and grounds answers in your sources so they can be checked.",
      "when_to_choose": "The corpus is large, the answers already exist somewhere inside it, and the requirement is retrieval with citations — not scripted dialogue.",
      "docs": "https://cloud.google.com/generative-ai-app-builder/docs/introduction"
    },
    "conversational-agents": {
      "product": "Conversational Agents / Dialogflow CX (Customer Engagement Suite)",
      "family": "Generative AI — conversational front end",
      "what_it_is": "Virtual agents combining deterministic flows with generative answers, across voice and chat, with live-agent handoff and per-turn analytics.",
      "business_value": "Deflects tier-1 contact volume 24/7 and shortens handle time on what does reach a human. Measured in containment rate and cost per contact.",
      "when_to_choose": "The deliverable is a conversation with a customer — routing, transactions, escalation — not a search box.",
      "docs": "https://cloud.google.com/dialogflow/cx/docs/basics"
    },
    "recommendations": {
      "product": "Vertex AI Search for commerce (Recommendations AI)",
      "family": "Applied AI — commerce",
      "what_it_is": "Managed retail recommendation and search models trained on your catalogue and behavioural events, with optimisation objectives such as CTR, revenue per session or conversion.",
      "business_value": "Personalisation tied directly to a revenue objective, without building and retraining a recommender in-house.",
      "when_to_choose": "E-commerce catalogue plus user event stream, and the goal is basket size or conversion.",
      "docs": "https://cloud.google.com/solutions/retail-product-discovery"
    },
    "gemini-for-google-cloud": {
      "product": "Gemini for Google Cloud",
      "family": "Generative AI — assistance in the platform",
      "what_it_is": "AI assistance embedded in Google Cloud itself: code and IaC generation and explanation in the IDE and Console, log and error investigation, query and security assistance.",
      "business_value": "Productivity of the builders, not of a product feature. It shortens the loop for developers, operators and analysts who already work in the platform.",
      "when_to_choose": "The stated pain is 'our engineers are slow / our new hires cannot navigate our stack', not 'our customers need a feature'.",
      "docs": "https://cloud.google.com/gemini/docs/overview"
    },
    "cloud-tpu": {
      "product": "Cloud TPU",
      "family": "AI infrastructure",
      "what_it_is": "Google-designed accelerators built for large-scale neural network training and serving, deployed in pods with high-bandwidth interconnect.",
      "business_value": "Makes frontier-scale training and high-volume inference tractable in time and cost per token; the differentiator is scale and price-performance, not ease of use.",
      "when_to_choose": "Training or serving very large models is the actual workload. It is the wrong answer for anything a pre-trained API or AutoML already solves.",
      "docs": "https://cloud.google.com/tpu/docs/intro-to-tpu"
    },
    "vertex-ai-workbench": {
      "product": "Vertex AI Workbench",
      "family": "ML platform — development surface",
      "what_it_is": "Managed JupyterLab instances wired into BigQuery, Cloud Storage and Vertex AI training and pipelines.",
      "business_value": "Gives data scientists a governed, reproducible environment instead of laptops with private dependencies.",
      "when_to_choose": "The gap is where humans explore data, not how models run in production.",
      "docs": "https://cloud.google.com/vertex-ai/docs/workbench/introduction"
    }
  }
}
JSON
    chmod 0644 "$CATALOG_FILE"
}

# --- the mapping the student must repair (CORRECT version) ------------------
write_scenario_map_correct() {
    cat > "$MAP_FILE" <<'JSON'
{
  "schema": "cdl-lab/scenario-map/v1",
  "scenarios": {
    "invoice-backlog": {
      "title": "Supplier invoice backlog",
      "brief": "A shared-services centre keys 40,000 supplier invoices a month by hand across 30 layouts. Errors force re-work, and closing the month takes nine days.",
      "offering": "document-ai"
    },
    "churn-in-bigquery": {
      "title": "Subscriber churn prediction",
      "brief": "Two years of subscription and usage history already sit in BigQuery. The team is four SQL analysts. There are no ML engineers and no budget to hire any this year.",
      "offering": "bigquery-ml"
    },
    "defect-photos": {
      "title": "Visual defect detection on the line",
      "brief": "A manufacturer has 900 labelled photographs of its own six defect classes. Nobody on staff can write a training loop, and generic image labels are useless for these categories.",
      "offering": "vertex-ai-automl"
    },
    "support-bot": {
      "title": "Tier-1 contact deflection",
      "brief": "A utility wants 24/7 self-service by voice and chat for outage reports, payments and appointment changes, with a clean handoff to a human agent when the customer asks.",
      "offering": "conversational-agents"
    },
    "policy-search": {
      "title": "Internal knowledge retrieval",
      "brief": "Two million internal policy and engineering documents. Employees cannot find current answers, and compliance requires every answer to cite the source document.",
      "offering": "vertex-ai-search"
    },
    "frontier-training": {
      "title": "Large-model training capacity",
      "brief": "A research subsidiary trains a 70-billion-parameter foundation model from scratch. The bottleneck is accelerator throughput and interconnect bandwidth at pod scale.",
      "offering": "cloud-tpu"
    },
    "dev-velocity": {
      "title": "Engineering productivity in the platform",
      "brief": "Platform engineers spend their days writing Terraform and gcloud, and reading unfamiliar stack traces. Leadership wants shorter onboarding and faster incident triage, not a new customer feature.",
      "offering": "gemini-for-google-cloud"
    },
    "product-recs": {
      "title": "Storefront personalisation",
      "brief": "An online retailer with 200,000 SKUs and a large clickstream wants larger baskets. Success is measured as revenue per session, and there is no recommender team.",
      "offering": "recommendations"
    }
  }
}
JSON
    chmod 0644 "$MAP_FILE"
}

# --- FAULT 5: the same file with six business-value errors -------------------
write_scenario_map_broken() {
    python3 - "$MAP_FILE" <<'PY'
import json, sys

path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))

# Each substitution is a real-world mis-selection, not a random shuffle:
#   OCR mistaken for document understanding; over-engineering a SQL problem;
#   confusing infrastructure with a model; confusing language with dialogue;
#   confusing text analytics with retrieval; confusing a dev tool with a platform.
wrong = {
    "invoice-backlog":   "vision-api",
    "churn-in-bigquery": "vertex-ai-platform",
    "defect-photos":     "cloud-tpu",
    "support-bot":       "translation-ai",
    "policy-search":     "natural-language-ai",
    "frontier-training": "vertex-ai-workbench",
}
for key, offering in wrong.items():
    doc["scenarios"][key]["offering"] = offering

json.dump(doc, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
    chmod 0644 "$MAP_FILE"
}

write_answer_key() {
    python3 - "$MAP_FILE" <<'PY' | base64 -w0 > "$ANSWER_KEY"
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sorted(doc["scenarios"]):
    print(key, doc["scenarios"][key]["offering"])
PY
    chmod 0600 "$ANSWER_KEY"
}

write_fake_credentials() {
    cat > "$KEY_FILE" <<'JSON'
{
  "type": "service_account",
  "project_id": "cdl-lab-3-2",
  "private_key_id": "0000000000000000000000000000000000000000",
  "private_key": "-----BEGIN PRIVATE KEY-----\nTHIS-IS-NOT-A-KEY-LAB-PLACEHOLDER-ONLY\n-----END PRIVATE KEY-----\n",
  "client_email": "lab-advisor@cdl-lab-3-2.iam.gserviceaccount.com",
  "client_id": "000000000000000000000",
  "token_uri": "https://oauth2.googleapis.com/token",
  "_lab_note": "Fake. No key material, no Google identity, never sent anywhere. It only exists so the service has a file it must be able to READ."
}
JSON
    chown root:"$SVC_USER" "$KEY_FILE"
    chmod 0640 "$KEY_FILE"
    chown root:"$SVC_USER" "$KEY_DIR"
    chmod 0750 "$KEY_DIR"
}

write_env_healthy() {
    cat > "$ENV_FILE" <<EOF
# cdl-ai-advisor service environment — see ${RUNBOOK} for the contract.
ADVISOR_BIND=127.0.0.1
ADVISOR_PORT=${CONTRACT_PORT}
GOOGLE_APPLICATION_CREDENTIALS=${KEY_FILE}
RESPONSIBLE_AI_CHECKS=on
EOF
    chmod 0644 "$ENV_FILE"
    cat > "$CLIENT_ENV" <<EOF
# Client contract. Consumers reach the advisor here. Do not "fix" the client.
ADVISOR_URL=http://127.0.0.1:${CONTRACT_PORT}
EOF
    chmod 0644 "$CLIENT_ENV"
}

write_env_broken() {
    cat > "$ENV_FILE" <<EOF
# cdl-ai-advisor service environment — see ${RUNBOOK} for the contract.
ADVISOR_BIND=127.0.0.1
ADVISOR_PORT=${WRONG_PORT}
GOOGLE_APPLICATION_CREDENTIALS=${KEY_FILE}
RESPONSIBLE_AI_CHECKS=off
EOF
    chmod 0644 "$ENV_FILE"
}

write_server() {
    cat > "$SERVER_BIN" <<'PY'
#!/usr/bin/env python3
"""cdl-ai-advisor — offline mock of a "which Google Cloud AI offering?" service.

LAB ONLY. It never contacts a Google API and never leaves the VM. The credential
file it loads is fake JSON written by the lab installer; it is read at startup so
the exercise can reproduce the failure mode of a workload that cannot read its
Application Default Credentials.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LAB_ROOT = "/opt/cdl-lab/3.2"
CATALOG_FILE = os.path.join(LAB_ROOT, "catalog", "ai_offerings.json")
MAP_FILE = os.path.join(LAB_ROOT, "catalog", "scenario_map.json")

BIND = os.environ.get("ADVISOR_BIND", "127.0.0.1")
PORT = int(os.environ.get("ADVISOR_PORT", "8080"))
CRED_PATH = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
RAI_ENABLED = os.environ.get("RESPONSIBLE_AI_CHECKS", "on").strip().lower() in ("on", "true", "1", "yes")

GOVERNANCE = {
    "responsible_ai_checks": "enabled",
    "customer_data_used_to_train_foundation_models": False,
    "data_residency_honoured": True,
    "human_review_available": True,
    "references": [
        "https://cloud.google.com/responsible-ai",
        "https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance",
    ],
}

PRINCIPAL = {"email": None, "project": None}


def fatal(msg, code=3):
    print("FATAL: %s" % msg, file=sys.stderr, flush=True)
    sys.exit(code)


def load_adc():
    """Mimic ADC bootstrap: the process must be able to READ the key file."""
    if not CRED_PATH:
        fatal("GOOGLE_APPLICATION_CREDENTIALS is not set: no Application Default Credentials")
    try:
        with open(CRED_PATH, "r", encoding="utf-8") as handle:
            cred = json.load(handle)
    except PermissionError as exc:
        fatal("cannot read the service account key: %s "
              "(the service runs unprivileged; check owner/group/mode on the key file)" % exc)
    except FileNotFoundError as exc:
        fatal("service account key not found: %s" % exc)
    except json.JSONDecodeError as exc:
        fatal("service account key is not valid JSON: %s" % exc)
    for field in ("client_email", "project_id"):
        if field not in cred:
            fatal("malformed credential file: missing '%s'" % field)
    PRINCIPAL["email"] = cred["client_email"]
    PRINCIPAL["project"] = cred["project_id"]
    print("startup: authenticated as %s (project %s)" % (PRINCIPAL["email"], PRINCIPAL["project"]), flush=True)


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


class Advisor(BaseHTTPRequestHandler):
    server_version = "cdl-ai-advisor/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, payload):
        body = json.dumps(payload, indent=2, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        route = parsed.path.rstrip("/") or "/"

        if route == "/healthz":
            return self._send(200, {"status": "serving", "principal": PRINCIPAL["email"], "port": PORT})

        if route in ("/", "/v1"):
            return self._send(200, {"routes": ["/healthz", "/v1/offerings", "/v1/scenarios",
                                               "/v1/recommend?scenario=<id>"]})

        try:
            catalog = read_json(CATALOG_FILE)
        except json.JSONDecodeError as exc:
            return self._send(500, {"error": "catalog_unreadable",
                                    "detail": "%s is not valid JSON: %s" % (CATALOG_FILE, exc)})
        except OSError as exc:
            return self._send(500, {"error": "catalog_unreadable", "detail": str(exc)})

        try:
            mapping = read_json(MAP_FILE)
        except json.JSONDecodeError as exc:
            return self._send(500, {"error": "scenario_map_unreadable",
                                    "detail": "%s is not valid JSON: %s" % (MAP_FILE, exc)})
        except OSError as exc:
            return self._send(500, {"error": "scenario_map_unreadable", "detail": str(exc)})

        offerings = catalog.get("offerings", {})
        scenarios = mapping.get("scenarios", {})

        if route == "/v1/offerings":
            return self._send(200, {"count": len(offerings), "offerings": offerings})

        if route == "/v1/scenarios":
            listing = {key: {"title": val.get("title"), "brief": val.get("brief")}
                       for key, val in scenarios.items()}
            return self._send(200, {"count": len(listing), "scenarios": listing})

        if route == "/v1/recommend":
            sid = (query.get("scenario") or [""])[0]
            if sid not in scenarios:
                return self._send(404, {"error": "unknown_scenario", "scenario": sid,
                                        "known": sorted(scenarios)})
            entry = scenarios[sid]
            oid = entry.get("offering", "")
            if oid not in offerings:
                return self._send(422, {"error": "unknown_offering",
                                        "detail": "scenario '%s' maps to '%s', which is not in the catalog"
                                                  % (sid, oid),
                                        "valid_offerings": sorted(offerings)})
            payload = {
                "scenario": sid,
                "title": entry.get("title"),
                "brief": entry.get("brief"),
                "recommended_offering_id": oid,
                "recommended_offering": offerings[oid],
                "principal": PRINCIPAL["email"],
            }
            if RAI_ENABLED:
                payload["governance"] = GOVERNANCE
            else:
                payload["governance_warning"] = (
                    "RESPONSIBLE_AI_CHECKS is disabled: recommendations are served without the "
                    "data-governance and responsible-AI attestation block")
            return self._send(200, payload)

        return self._send(404, {"error": "not_found", "path": route})


def main():
    load_adc()
    server = ThreadingHTTPServer((BIND, PORT), Advisor)
    print("listening on http://%s:%d" % (BIND, PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
PY
    chmod 0755 "$SERVER_BIN"
}

write_client() {
    cat > "$CLIENT_BIN" <<'SH'
#!/usr/bin/env bash
# aiadvisor — thin client for the CDL 3.2 lab service. Reads the client contract
# from /etc/cdl-lab/3.2.client.env. This file is CORRECT: do not edit it to make
# a test pass; fix the server to honour the contract instead.
set -Eeuo pipefail

# shellcheck source=/dev/null
[[ -r /etc/cdl-lab/3.2.client.env ]] && . /etc/cdl-lab/3.2.client.env
: "${ADVISOR_URL:=http://127.0.0.1:8080}"

usage() {
    cat <<USAGE
usage: aiadvisor <command> [arg]
  health                 GET /healthz
  offerings              GET /v1/offerings      (the AI product catalog)
  scenarios              GET /v1/scenarios      (the business cases to solve)
  recommend <scenario>   GET /v1/recommend?scenario=<id>
  raw <path>             GET <path>
endpoint: ${ADVISOR_URL}
USAGE
}

call() {
    local path="$1" body code
    body="$(mktemp)"; trap 'rm -f "$body"' RETURN
    code="$(curl -sS --max-time 5 -o "$body" -w '%{http_code}' "${ADVISOR_URL}${path}" 2>/tmp/aiadvisor.err || true)"
    if [[ -z "$code" || "$code" == "000" ]]; then
        printf 'HTTP 000 (no response)\n' >&2
        sed 's/^/curl: /' /tmp/aiadvisor.err >&2 || true
        return 7
    fi
    printf 'HTTP %s\n' "$code"
    python3 -m json.tool < "$body" 2>/dev/null || cat "$body"
    [[ "$code" == 2* ]]
}

cmd="${1:-}"
case "$cmd" in
    health)     call /healthz ;;
    offerings)  call /v1/offerings ;;
    scenarios)  call /v1/scenarios ;;
    recommend)  [[ $# -ge 2 ]] || { usage; exit 2; }; call "/v1/recommend?scenario=$2" ;;
    raw)        [[ $# -ge 2 ]] || { usage; exit 2; }; call "$2" ;;
    *)          usage; exit 2 ;;
esac
SH
    chmod 0755 "$CLIENT_BIN"
}

write_unit() {
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=CDL 3.2 lab — Google Cloud AI advisor (offline mock)
Documentation=file://${RUNBOOK}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/env python3 ${SERVER_BIN}
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$UNIT_FILE"
    systemctl daemon-reload
}

write_runbook() {
    cat > "$RUNBOOK" <<EOF
# RUNBOOK — cdl-ai-advisor (lab 3.2)

This is the service contract. It is the source of truth for the fix; every value
below was true when the service last worked, and the client depends on all of it.

| Item | Contract value |
|---|---|
| Unit | \`${SVC_NAME}\` |
| Runs as | \`${SVC_USER}:${SVC_USER}\` (unprivileged, nologin) |
| Listens on | \`127.0.0.1:${CONTRACT_PORT}\` (loopback only) |
| Environment | \`${ENV_FILE}\` |
| Client contract | \`${CLIENT_ENV}\` — **correct, do not edit** |
| ADC key | \`${KEY_FILE}\`, owner \`root:${SVC_USER}\`, mode \`0640\` |
| Responsible AI checks | \`RESPONSIBLE_AI_CHECKS=on\` — required by the platform policy |
| Product catalog | \`${CATALOG_FILE}\` (valid JSON, 15 offerings) |
| Business scenario map | \`${MAP_FILE}\` (8 scenarios, each mapped to one offering id) |

## Endpoints
    GET /healthz
    GET /v1/offerings
    GET /v1/scenarios
    GET /v1/recommend?scenario=<id>

## Standard checks
    systemctl status ${SVC_NAME}
    journalctl -u ${SVC_NAME} -n 50 --no-pager
    ss -lntp | grep -E '${CONTRACT_PORT}|${WRONG_PORT}'
    aiadvisor health
    aiadvisor scenarios
    sudo ${VERIFY_BIN}

## Policy notes
* Every recommendation must be served with the \`governance\` block. Serving
  advice without the responsible-AI and data-governance attestation is a policy
  violation, not a cosmetic difference.
* The scenario map must recommend the offering that solves the stated **business**
  problem at the lowest justified cost and effort. Over-provisioning (custom
  training or accelerators for a problem a pre-trained API or AutoML solves) is a
  wrong answer here, exactly as it is on the exam.

Reference for the underlying products: each catalog entry carries its official
\`docs\` URL. Objective source:
https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
EOF
    chmod 0644 "$RUNBOOK"
}

write_verify() {
    cat > "$VERIFY_BIN" <<'SH'
#!/usr/bin/env bash
# verify.sh — the scoreboard for CDL lab 3.2. Run it as root, run it often.
set -Eeuo pipefail

SVC_NAME="cdl-ai-advisor.service"
ANSWER_KEY="/var/lib/cdl-lab/3.2/answer.key.b64"
# shellcheck source=/dev/null
[[ -r /etc/cdl-lab/3.2.client.env ]] && . /etc/cdl-lab/3.2.client.env
: "${ADVISOR_URL:=http://127.0.0.1:8080}"

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=""; R=""; B=""; Z=""; fi

PASS=0; FAIL=0
result() { # result <PASS|FAIL> <id> <text>
    if [[ "$1" == PASS ]]; then PASS=$((PASS+1)); printf '%s  PASS%s  %-22s %s\n' "$G" "$Z" "$2" "$3"
    else FAIL=$((FAIL+1)); printf '%s  FAIL%s  %-22s %s\n' "$R" "$Z" "$2" "$3"; fi
}

http_get() { # http_get <path> -> body on stdout, http code in $HTTP_CODE
    local out; out="$(mktemp)"
    HTTP_CODE="$(curl -sS --max-time 5 -o "$out" -w '%{http_code}' "${ADVISOR_URL}${1}" 2>/dev/null || echo 000)"
    cat "$out"; rm -f "$out"
}

json_get() { python3 -c '
import json,sys
try: doc=json.load(sys.stdin)
except Exception: sys.exit(1)
cur=doc
for key in sys.argv[1].split("."):
    if isinstance(cur,dict) and key in cur: cur=cur[key]
    else: sys.exit(1)
print(cur if not isinstance(cur,(dict,list)) else json.dumps(cur))
' "$1"; }

printf '\n%sCDL 3.2 — break & fix scoreboard%s\n' "$B" "$Z"
printf 'endpoint: %s\n\n' "$ADVISOR_URL"

# T01 — service up
if systemctl is-active --quiet "$SVC_NAME"; then
    result PASS T01-service "${SVC_NAME} is active"
else
    result FAIL T01-service "${SVC_NAME} is $(systemctl is-active "$SVC_NAME" 2>/dev/null || echo unknown)"
fi

# T02 — reachable on the contracted endpoint
BODY="$(http_get /healthz)"
if [[ "$HTTP_CODE" == "200" ]]; then
    result PASS T02-endpoint "healthz 200 on the contracted port"
else
    result FAIL T02-endpoint "healthz returned HTTP ${HTTP_CODE} (contract is ${ADVISOR_URL})"
fi

# T03 — catalog parses and is complete
BODY="$(http_get /v1/offerings)"
COUNT="$(printf '%s' "$BODY" | json_get count 2>/dev/null || echo 0)"
if [[ "$HTTP_CODE" == "200" && "${COUNT:-0}" -ge 15 ]]; then
    result PASS T03-catalog "catalog parses, ${COUNT} offerings"
else
    result FAIL T03-catalog "offerings returned HTTP ${HTTP_CODE}, count=${COUNT:-0} (expected 200 / >=15)"
fi

# T04..T11 — the business-value mapping
if [[ -r "$ANSWER_KEY" ]]; then
    idx=4
    while read -r sid expected; do
        [[ -n "${sid:-}" ]] || continue
        tid="$(printf 'T%02d-%s' "$idx" "$sid")"
        BODY="$(http_get "/v1/recommend?scenario=${sid}")"
        got="$(printf '%s' "$BODY" | json_get recommended_offering_id 2>/dev/null || echo '<none>')"
        if [[ "$HTTP_CODE" == "200" && "$got" == "$expected" ]]; then
            result PASS "$tid" "correct offering"
        else
            result FAIL "$tid" "HTTP ${HTTP_CODE}, recommends '${got}' — wrong offering for this business case"
        fi
        idx=$((idx+1))
    done < <(base64 -d "$ANSWER_KEY")
else
    result FAIL T04-mapping "answer key missing at ${ANSWER_KEY} — reinstall the lab"
fi

# T12 — responsible AI / data governance attestation
BODY="$(http_get "/v1/recommend?scenario=invoice-backlog")"
GOV="$(printf '%s' "$BODY" | json_get governance.responsible_ai_checks 2>/dev/null || echo '')"
if [[ "$GOV" == "enabled" ]]; then
    result PASS T12-governance "responses carry the responsible-AI / data-governance block"
else
    result FAIL T12-governance "no governance block in the response (policy violation)"
fi

printf '\n%s%d passed, %d failed%s\n\n' "$B" "$PASS" "$FAIL" "$Z"
if [[ "$FAIL" -eq 0 ]]; then
    printf '%sLAB COMPLETE.%s The service is healthy AND every business case now maps to the\n' "$G" "$Z"
    printf 'offering that actually creates the value described. Read the reasoning in the\n'
    printf 'solution block at the bottom of the lab script before you move on.\n\n'
fi
exit $(( FAIL > 0 ))
SH
    chmod 0755 "$VERIFY_BIN"
}

# ============================== lab lifecycle ================================

svc_restart() { systemctl restart "$SVC_NAME" 2>/dev/null || true; sleep 2; }

healthy_build() {
    write_layout
    write_catalog
    write_scenario_map_correct
    write_answer_key
    write_fake_credentials
    write_env_healthy
    write_server
    write_client
    write_verify
    write_runbook
    write_unit
    relabel_selinux
    systemctl enable --now "$SVC_NAME" >/dev/null 2>&1 || true
    sleep 2
}

prove_healthy() {
    local code
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${CONTRACT_PORT}/healthz" || echo 000)"
    [[ "$code" == "200" ]] || die "the lab did not come up clean (healthz=${code}); check: journalctl -u ${SVC_NAME} -n 50"
    ok "baseline is healthy — service answered 200 on 127.0.0.1:${CONTRACT_PORT} before any fault was injected"
}

break_it() {
    log "injecting faults..."

    # FAULT 1 — identity: the unprivileged service loses read access to its ADC key.
    chown root:root "$KEY_FILE"
    chmod 0000 "$KEY_FILE"

    # FAULT 2 + 4 — configuration drift: wrong port, governance switched off.
    write_env_broken

    # FAULT 3 — data integrity: one character makes the product catalog invalid JSON.
    python3 - "$CATALOG_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace('"family":', '"family";', 1))
PY

    # FAULT 5 — business value: six scenarios mapped to the wrong AI offering.
    write_scenario_map_broken

    systemctl daemon-reload
    systemctl restart "$SVC_NAME" >/dev/null 2>&1 || true
    sleep 4
    ok "faults injected"
}

briefing() {
    head1 "LAB 3.2 — the advisor service is down, and its advice is wrong"
    cat <<EOF
${C_B}The story${C_RST}
  Your company runs an internal API that answers "which Google Cloud AI product
  should we use for this business problem?". Sales engineers and solution leads
  call it before every customer conversation. This morning it stopped answering,
  and the pre-sales lead adds: "even before it broke, some of its answers looked
  expensive and wrong."

${C_B}Symptoms you will see${C_RST}
  1. ${C_R}aiadvisor health${C_RST} → HTTP 000, curl "Connection refused".
  2. ${C_R}systemctl status ${SVC_NAME}${C_RST} → failed, Result: exit-code,
     status=3, restarted until the start limit was hit.
  3. Once it starts, it still refuses connections — ${C_Y}active but unreachable${C_RST}.
  4. Once it is reachable, ${C_C}/healthz${C_RST} returns 200 while
     ${C_C}/v1/recommend${C_RST} returns ${C_R}HTTP 500 catalog_unreadable${C_RST}.
     Healthy is not the same as working.
  5. Once it serves, the responses arrive ${C_Y}without the governance block${C_RST},
     carrying a governance_warning instead.
  6. And the recommendations themselves are wrong: OCR proposed for structured
     invoice extraction, custom training proposed for a SQL-analyst team,
     accelerators proposed for a 900-image classification problem.

${C_B}What you must achieve${C_RST}
  ${C_G}sudo ${VERIFY_BIN}${C_RST}  →  ${C_G}12 passed, 0 failed${C_RST}

  That means: the unit is active; it answers on the endpoint the client contract
  names; the product catalog parses; every recommendation carries the
  responsible-AI / data-governance attestation; and all eight business scenarios
  map to the Google Cloud AI offering that actually creates the value described,
  at the lowest justified cost and effort.

${C_B}Ground rules${C_RST}
  * ${C_RUNBOOK:-}${RUNBOOK} is the contract. Fix the SERVER to meet it.
  * Do not edit ${CLIENT_ENV}, ${CLIENT_BIN} or ${VERIFY_BIN}. Moving the
    goalposts is not a fix, in the lab or in production.
  * Faults 1–4 are found with logs, ports and file modes. Fault 5 is not in any
    log: the mapping is syntactically perfect and semantically wrong. It is the
    exam objective, and the only source of truth is what each product is for —
    every catalog entry carries its official docs URL, so read them:
    ${C_C}aiadvisor offerings | less${C_RST}   ${C_C}aiadvisor scenarios${C_RST}
  * Stuck? ${C_C}sudo $0 hint 1${C_RST} … ${C_C}hint 5${C_RST} (hints, not answers).

${C_B}Where to start${C_RST}
  systemctl status ${SVC_NAME}
  journalctl -u ${SVC_NAME} -n 40 --no-pager
EOF
    rule
}

do_install() {
    require_tooling
    confirm_disposable
    if [[ ! -f "$UNIT_FILE" ]]; then
        port_is_free "$CONTRACT_PORT" || die "TCP 127.0.0.1:${CONTRACT_PORT} is already in use. This looks like a real host, not a scratch VM. Aborting."
        port_is_free "$WRONG_PORT"    || die "TCP 127.0.0.1:${WRONG_PORT} is already in use. Aborting."
    fi
    log "building the lab under ${LAB_ROOT} ..."
    healthy_build
    prove_healthy
    break_it
    briefing
}

do_restore() {
    require_tooling
    confirm_disposable
    warn "INSTRUCTOR ESCAPE HATCH: this repairs all five faults for you."
    write_catalog
    write_scenario_map_correct
    write_answer_key
    write_fake_credentials
    write_env_healthy
    write_unit
    relabel_selinux
    svc_restart
    "$VERIFY_BIN" || true
}

do_status() {
    head1 "Service"
    systemctl --no-pager --full status "$SVC_NAME" 2>&1 | sed -n '1,12p' || true
    head1 "Listening sockets (loopback)"
    if command -v ss >/dev/null 2>&1; then ss -lntp 2>/dev/null | grep -E ":(${CONTRACT_PORT}|${WRONG_PORT})\b" || echo "  nothing on ${CONTRACT_PORT} or ${WRONG_PORT}"; else echo "  (ss not installed)"; fi
    head1 "Key file"
    ls -l "$KEY_FILE" 2>/dev/null || echo "  missing"
    head1 "Environment"
    cat "$ENV_FILE" 2>/dev/null || echo "  missing"
    head1 "JSON validity"
    for f in "$CATALOG_FILE" "$MAP_FILE"; do
        if python3 -m json.tool "$f" >/dev/null 2>&1; then ok "$f parses"; else warn "$f is NOT valid JSON"; fi
    done
    head1 "Last log lines"
    journalctl -u "$SVC_NAME" -n 15 --no-pager 2>/dev/null || true
}

do_hint() {
    case "${1:-0}" in
        1) cat <<'EOF'
HINT 1 — the service will not start at all.
  A unit that exits 3 on every start told you why on the way out. Read the
  journal, not the status header: journalctl -u cdl-ai-advisor.service -n 40.
  Then ask who the process is (User= in the unit) and whether that identity can
  read the file the error names. `ls -l` on the key file. Compare with the
  RUNBOOK: owner root, group cdlai, mode 0640.
  Exam parallel: this is least privilege failing closed. The workload's identity
  is the thing that has access, not you.
EOF
;;
        2) cat <<'EOF'
HINT 2 — "active (running)" and still refusing connections.
  Active means the process lives, not that it is where clients look. Ask where
  it actually listens:  ss -lntp | grep python
  Then compare that to the contract in /etc/cdl-lab/3.2.client.env and the
  RUNBOOK. Exactly one side is wrong, and the client is declared correct.
EOF
;;
        3) cat <<'EOF'
HINT 3 — /healthz is 200 but /v1/recommend is 500.
  A health check that only proves the process is alive is a health check that
  lies. Read the 500 body: it names the file and the parse position.
    python3 -m json.tool /opt/cdl-lab/3.2/catalog/ai_offerings.json
  It will point at the exact line and column. One character is wrong.
EOF
;;
        4) cat <<'EOF'
HINT 4 — responses carry governance_warning instead of governance.
  Nothing is broken in code: a policy switch is off. Look through the service
  environment file for a flag whose name is a policy, not a setting, and set it
  to what the RUNBOOK requires. Restart, then re-check with:
    aiadvisor recommend invoice-backlog | grep -A6 governance
  Exam parallel: responsible AI and data governance are product properties you
  are expected to assert, including that customer data is not used to train
  foundation models. See https://cloud.google.com/responsible-ai
EOF
;;
        5) cat <<'EOF'
HINT 5 — the recommendations are wrong, and no log will tell you.
  Read every scenario and every catalog entry, then sort each case by the
  cheapest offering that actually solves it:

    * Is the problem ALREADY SOLVED generically?      -> pre-trained API
      (Document AI, Vision, Speech-to-Text, Natural Language, Translation)
    * Is the data already in the warehouse and the team SQL-fluent?
                                                       -> BigQuery ML
    * Do you need YOUR categories, have labels, no ML staff?
                                                       -> Vertex AI AutoML
    * Is the problem governance / lifecycle / genuinely custom code?
                                                       -> Vertex AI platform
    * Is the deliverable a CONVERSATION?               -> Conversational Agents
      Is it RETRIEVAL WITH CITATIONS over your corpus? -> Vertex AI Search
    * Is the customer literally training a frontier model? -> Cloud TPU
    * Is the pain your own engineers' velocity?  -> Gemini for Google Cloud

  Two distinctions decide four of the six errors: OCR (Vision) is not document
  understanding (Document AI); and language translation is not dialogue design
  (Conversational Agents). Over-provisioning is a wrong answer.
  Edit /opt/cdl-lab/3.2/catalog/scenario_map.json, keep it valid JSON, then
  re-run the verifier. No restart needed: the map is read per request.
EOF
;;
        *) echo "usage: $0 hint <1..5>"; exit 2 ;;
    esac
}

do_uninstall() {
    confirm_disposable
    systemctl disable --now "$SVC_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"; systemctl daemon-reload
    rm -rf "$LAB_ROOT" "$ETC_DIR" "$STATE_DIR" "$CLIENT_BIN"
    rmdir /opt/cdl-lab 2>/dev/null || true
    rmdir /var/lib/cdl-lab 2>/dev/null || true
    userdel "$SVC_USER" >/dev/null 2>&1 || true
    groupdel "$SVC_USER" >/dev/null 2>&1 || true
    ok "lab removed: files, unit, client and the ${SVC_USER} account are gone."
}

# --------------------------------- dispatch ---------------------------------
main() {
    local cmd="" args=()
    for a in "$@"; do
        case "$a" in
            --confirm) CONFIRMED=1 ;;
            --dry-run) show_footprint; exit 0 ;;
            -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
            *) args+=("$a") ;;
        esac
    done
    cmd="${args[0]:-install}"
    case "$cmd" in
        install)   require_root "$@"; do_install ;;
        break)     require_root "$@"; confirm_disposable; break_it; briefing ;;
        verify)    require_root "$@"; [[ -x "$VERIFY_BIN" ]] || die "lab not installed"; "$VERIFY_BIN" ;;
        status)    require_root "$@"; do_status ;;
        hint)      do_hint "${args[1]:-0}" ;;
        restore)   require_root "$@"; do_restore ;;
        uninstall) require_root "$@"; do_uninstall ;;
        *)         die "unknown command '${cmd}' (install|verify|status|hint|break|restore|uninstall)" ;;
    esac
}

main "$@"

# =============================================================================
#  S O L U T I O N   —   do not read until you have tried
# =============================================================================
#
#  Work the faults in dependency order. Each one hides the next, which is the
#  real lesson: you cannot evaluate the QUALITY of an AI recommendation service
#  until the service runs, and you cannot evaluate its BUSINESS VALUE until you
#  can read what it recommends.
#
# -----------------------------------------------------------------------------
#  FAULT 1 — the service cannot read its Application Default Credentials
# -----------------------------------------------------------------------------
#  Diagnose:
#      systemctl status cdl-ai-advisor.service
#        Active: failed (Result: exit-code) since ...; Process: ... status=3
#      journalctl -u cdl-ai-advisor.service -n 20 --no-pager
#        FATAL: cannot read the service account key:
#          [Errno 13] Permission denied: '/etc/cdl-lab/keys/lab-sa.json'
#          (the service runs unprivileged; check owner/group/mode on the key file)
#      ls -l /etc/cdl-lab/keys/lab-sa.json
#        ---------- 1 root root 512 ... lab-sa.json
#
#  Fix (restore what the RUNBOOK declares: root:cdlai, 0640):
#      sudo chown root:cdlai /etc/cdl-lab/keys/lab-sa.json
#      sudo chmod 0640      /etc/cdl-lab/keys/lab-sa.json
#      sudo systemctl reset-failed cdl-ai-advisor.service
#      sudo systemctl restart      cdl-ai-advisor.service
#
#  Expect:
#      journalctl -u cdl-ai-advisor.service -n 5 --no-pager
#        startup: authenticated as lab-advisor@cdl-lab-3-2.iam.gserviceaccount.com
#                 (project cdl-lab-3-2)
#        listening on http://127.0.0.1:8090
#
#  Note `reset-failed`: three failures inside 60 s hit StartLimitBurst, and until
#  the limit is cleared systemd refuses to start the unit even after you fixed it.
#  Concept: the workload's own identity is what holds access. On real Google Cloud
#  you would prefer attached service accounts / Workload Identity over key files —
#  https://cloud.google.com/iam/docs/service-account-overview
#
# -----------------------------------------------------------------------------
#  FAULT 2 — active, but listening on the wrong port
# -----------------------------------------------------------------------------
#  Diagnose:
#      systemctl is-active cdl-ai-advisor.service      -> active
#      aiadvisor health                                -> HTTP 000, connection refused
#      ss -lntp | grep python
#        LISTEN 0 5 127.0.0.1:8090 ... users:(("python3",pid=...))
#      grep -n PORT /etc/cdl-lab/3.2.env
#        ADVISOR_PORT=8090         <- contract says 8080
#
#  Fix:
#      sudo sed -i 's/^ADVISOR_PORT=.*/ADVISOR_PORT=8080/' /etc/cdl-lab/3.2.env
#      sudo systemctl restart cdl-ai-advisor.service
#      aiadvisor health
#        HTTP 200
#        { "status": "serving", "principal": "lab-advisor@...", "port": 8080 }
#
#  The client contract was declared correct. Editing the client to chase the
#  server would have made the test pass and left every other consumer broken.
#
# -----------------------------------------------------------------------------
#  FAULT 3 — healthy process, unreadable catalog
# -----------------------------------------------------------------------------
#  Diagnose:
#      aiadvisor recommend invoice-backlog
#        HTTP 500
#        { "error": "catalog_unreadable",
#          "detail": ".../ai_offerings.json is not valid JSON: Expecting ':'
#                     delimiter: line 12 column 17 (char ...)" }
#      python3 -m json.tool /opt/cdl-lab/3.2/catalog/ai_offerings.json
#        (same line/column)
#
#  Fix — one character; the key separator was turned into a semicolon:
#      sudo sed -i '0,/"family";/s//"family":/' \
#           /opt/cdl-lab/3.2/catalog/ai_offerings.json
#      python3 -m json.tool /opt/cdl-lab/3.2/catalog/ai_offerings.json >/dev/null \
#        && echo "catalog OK"
#      aiadvisor offerings | head -5
#        HTTP 200
#        { "count": 15, ...
#
#  No restart needed — the catalog is read per request. That is also why /healthz
#  stayed green: a liveness probe that never touches the dependency will happily
#  report success while every real request fails.
#
# -----------------------------------------------------------------------------
#  FAULT 4 — responsible AI / data governance attestation disabled
# -----------------------------------------------------------------------------
#  Diagnose:
#      aiadvisor recommend invoice-backlog | grep -i governance
#        "governance_warning": "RESPONSIBLE_AI_CHECKS is disabled: ..."
#      grep RESPONSIBLE /etc/cdl-lab/3.2.env
#        RESPONSIBLE_AI_CHECKS=off
#
#  Fix:
#      sudo sed -i 's/^RESPONSIBLE_AI_CHECKS=.*/RESPONSIBLE_AI_CHECKS=on/' \
#           /etc/cdl-lab/3.2.env
#      sudo systemctl restart cdl-ai-advisor.service
#      aiadvisor recommend invoice-backlog | grep -A7 '"governance"'
#        "governance": {
#          "responsible_ai_checks": "enabled",
#          "customer_data_used_to_train_foundation_models": false,
#          "data_residency_honoured": true,
#          "human_review_available": true, ...
#
#  Why it matters for the exam: "AI creates business value" is inseparable from
#  the governance claims that let a regulated buyer adopt it — that enterprise
#  data is not used to train foundation models, that residency is honoured, that
#  a human can review a decision. Those are commitments you cite, not opinions.
#      https://cloud.google.com/responsible-ai
#      https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance
#
# -----------------------------------------------------------------------------
#  FAULT 5 — the recommendations themselves (this is the exam objective)
# -----------------------------------------------------------------------------
#  No log reports this. The file is valid JSON and the service is perfectly
#  healthy; it is simply giving expensive, wrong advice. Six of the eight
#  business cases point at the wrong Google Cloud AI offering.
#
#  Edit /opt/cdl-lab/3.2/catalog/scenario_map.json so that:
#
#   scenario           broken value           CORRECT value
#   -----------------  ---------------------  --------------------------
#   invoice-backlog    vision-api          -> document-ai
#   churn-in-bigquery  vertex-ai-platform  -> bigquery-ml
#   defect-photos      cloud-tpu           -> vertex-ai-automl
#   support-bot        translation-ai      -> conversational-agents
#   policy-search      natural-language-ai -> vertex-ai-search
#   frontier-training  vertex-ai-workbench -> cloud-tpu
#   dev-velocity       (already correct)      gemini-for-google-cloud
#   product-recs       (already correct)      recommendations
#
#  Apply with a JSON-safe edit rather than sed:
#      sudo python3 - <<'PY'
#      import json
#      p = "/opt/cdl-lab/3.2/catalog/scenario_map.json"
#      doc = json.load(open(p, encoding="utf-8"))
#      fix = {"invoice-backlog": "document-ai",
#             "churn-in-bigquery": "bigquery-ml",
#             "defect-photos": "vertex-ai-automl",
#             "support-bot": "conversational-agents",
#             "policy-search": "vertex-ai-search",
#             "frontier-training": "cloud-tpu",
#             "dev-velocity": "gemini-for-google-cloud",
#             "product-recs": "recommendations"}
#      for k, v in fix.items():
#          doc["scenarios"][k]["offering"] = v
#      json.dump(doc, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
#      PY
#      sudo /opt/cdl-lab/3.2/bin/verify.sh
#        ... 12 passed, 0 failed
#
#  THE REASONING — memorise the reasoning, not the table:
#
#  1. invoice-backlog -> Document AI, not Vision API.
#     Vision OCR returns text and coordinates; someone still has to decide which
#     string is the tax ID. Document AI returns the FIELDS with confidence scores
#     and a human-review path, across layouts. The business value is the removal
#     of manual keying and the days off the monthly close — not "we can read the
#     pixels". https://cloud.google.com/document-ai/docs/overview
#
#  2. churn-in-bigquery -> BigQuery ML, not the Vertex AI platform.
#     The data is already in the warehouse and the team writes SQL. BigQuery ML
#     lets those same analysts train and predict in place, with no export, no
#     pipeline and no hire. Choosing custom training is technically defensible
#     and commercially wrong: it converts a two-week win into a hiring plan.
#     https://cloud.google.com/bigquery/docs/bqml-introduction
#
#  3. defect-photos -> Vertex AI AutoML, not Cloud TPU.
#     A pre-trained API cannot know six proprietary defect classes, so some
#     custom training is required — but 900 labelled images is not an accelerator
#     problem, it is a "we have labels and no data scientists" problem, which is
#     exactly AutoML's market. TPUs answer a question nobody asked.
#     https://cloud.google.com/vertex-ai/docs/training-overview
#
#  4. support-bot -> Conversational Agents (Dialogflow CX), not Translation AI.
#     Multilingual is a property of the solution, not the solution. The
#     deliverable is a conversation: intents, transactions, escalation to a live
#     agent, containment measured per contact. Translation alone leaves you with
#     no agent at all. https://cloud.google.com/dialogflow/cx/docs/basics
#
#  5. policy-search -> Vertex AI Search, not Natural Language API.
#     Natural Language scores sentiment and pulls entities out of text you have
#     already found. The stated problem is that nobody can FIND the text, and
#     that every answer must cite its source: that is grounded enterprise
#     retrieval. https://cloud.google.com/generative-ai-app-builder/docs/introduction
#
#  6. frontier-training -> Cloud TPU, not Vertex AI Workbench.
#     Here the customer really is training a 70B model and the bottleneck really
#     is accelerator throughput and interconnect. Workbench is where humans
#     explore data; it does not move the constraint.
#     https://cloud.google.com/tpu/docs/intro-to-tpu
#
#  7. dev-velocity -> Gemini for Google Cloud (already correct).
#     The pain is the builders' own speed — IaC, gcloud, log triage, onboarding —
#     not a customer-facing feature. https://cloud.google.com/gemini/docs/overview
#
#  8. product-recs -> Vertex AI Search for commerce (already correct).
#     Catalogue plus event stream plus a revenue objective, with no recommender
#     team: a managed model optimised against the business metric directly.
#     https://cloud.google.com/solutions/retail-product-discovery
#
#  THE DECISION RULE the exam keeps testing, in one line each:
#     Pre-trained API   — someone already solved this generically; call it.
#     BigQuery ML       — the data and the SQL skills are already in the warehouse.
#     AutoML            — your categories, your labels, no ML staff.
#     Vertex AI platform— custom code, or the risk is lifecycle and governance.
#     Model Garden      — you are choosing among foundation models.
#     Vertex AI Search  — retrieval with citations over your own corpus.
#     Conversational Agents — the deliverable is a dialogue with a customer.
#     Gemini for Google Cloud — the beneficiary is your own engineering team.
#     Cloud TPU / GPU   — training or serving at a scale that is itself the problem.
#  Cost and effort rise as you go down that list. Picking a lower row than the
#  problem requires is over-provisioning, and on this exam it is simply the wrong
#  answer — the same way it was wrong in this lab.
#
# -----------------------------------------------------------------------------
#  Tear down when finished:
#      sudo ./cdl-3.2-break-fix.sh uninstall --confirm
# =============================================================================