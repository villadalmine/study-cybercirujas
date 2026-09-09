#!/usr/bin/env bash
#
# ==============================================================================
#  break-and-fix-3.1.sh
#
#  Certification : Google Cloud Digital Leader (CDL)  -- exam version 2026-08-12
#  Domain 3      : Understanding Google Cloud's AI/ML solutions
#  Topic  3.1    : Describe fundamental AI and ML concepts and how they
#                  create business value                (exam weight: 9.0%)
#
#  Reference     : https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#
#  WHAT THIS SCRIPT IS
#  -------------------
#  Topic 3.1 is a *conceptual* objective, but the concepts it names -- training
#  data quality, the training/serving skew, model drift, bias and fairness,
#  responsible AI, the difference between AI, ML, deep learning and generative
#  AI, and the business value of each -- are not abstractions. They are the
#  exact failure modes that take an ML product down in production.
#
#  This lab therefore does NOT ask you to memorise definitions. It builds a
#  tiny, self-contained, *local* ML system (pure Python 3 standard library, no
#  network, no GCP billing, no accelerators) that predicts customer churn for a
#  fictional telco. Then it BREAKS it in a controlled, reversible way, in a
#  manner that mirrors a real Google Cloud incident. Your job is to diagnose the
#  break using the same reasoning a Cloud Digital Leader is expected to apply
#  when a business stakeholder says "the model used to work and now it doesn't".
#
#  SAFETY / SCOPE
#  --------------
#    * Runs ONLY inside a disposable lab VM. It refuses to run otherwise unless
#      you pass --i-know-what-im-doing.
#    * Touches ONLY files under ${LAB_ROOT} (default: /opt/cdl-lab-3.1).
#    * Installs nothing, contacts no network endpoint, calls no paid API.
#    * Every mutation is backed up to ${LAB_ROOT}/.backup before it happens.
#    * `--restore` puts everything back byte-for-byte; `--cleanup` deletes the
#      whole lab tree and nothing else.
#
#  USAGE
#  -----
#    sudo ./break-and-fix-3.1.sh setup      # build the healthy baseline
#    sudo ./break-and-fix-3.1.sh break      # inject the fault (random scenario)
#    sudo ./break-and-fix-3.1.sh break 2    # inject a specific scenario (1..4)
#    ./break-and-fix-3.1.sh verify          # did you fix it?
#    ./break-and-fix-3.1.sh hint            # graduated hints
#    sudo ./break-and-fix-3.1.sh restore    # undo the break
#    sudo ./break-and-fix-3.1.sh cleanup    # remove the lab entirely
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
LAB_ROOT="${LAB_ROOT:-/opt/cdl-lab-3.1}"
BACKUP_DIR="${LAB_ROOT}/.backup"
STATE_FILE="${LAB_ROOT}/.state"
DATA_DIR="${LAB_ROOT}/data"
MODEL_DIR="${LAB_ROOT}/model"
SRC_DIR="${LAB_ROOT}/src"
LOG_DIR="${LAB_ROOT}/logs"
PY="${PY:-python3}"

readonly LAB_ROOT BACKUP_DIR STATE_FILE DATA_DIR MODEL_DIR SRC_DIR LOG_DIR

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
C_GRN=$'\033[32m';  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_CYN=$'\033[36m'

log()  { printf '%s[ lab ]%s %s\n' "${C_BLU}"  "${C_RESET}" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n' "${C_GRN}"  "${C_RESET}" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "${C_YEL}"  "${C_RESET}" "$*"; }
err()  { printf '%s[fail ]%s %s\n' "${C_RED}"  "${C_RESET}" "$*" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

trap 'err "aborted at line ${LINENO} (exit $?)"' ERR

# ------------------------------------------------------------------------------
# Guard rails: refuse to run outside a disposable lab VM
# ------------------------------------------------------------------------------
assert_disposable_vm() {
  if [[ "${1:-}" == "--i-know-what-im-doing" ]]; then
    warn "guard rail bypassed by explicit flag"
    return 0
  fi

  local looks_disposable=0

  # A GCE VM answers the metadata server. We do NOT contact it over the network;
  # we look for the local marker files instead, so the check stays offline.
  [[ -e /sys/class/dmi/id/product_name ]] &&
    grep -qiE 'google|virtual|kvm|qemu|vmware|bochs|innotek' \
      /sys/class/dmi/id/product_name 2>/dev/null && looks_disposable=1

  [[ -f /etc/cdl-lab-vm ]]            && looks_disposable=1
  [[ -n "${CDL_LAB_VM:-}" ]]          && looks_disposable=1
  [[ -f /.dockerenv ]]                && looks_disposable=1
  grep -qa 'container=' /proc/1/environ 2>/dev/null && looks_disposable=1

  if (( looks_disposable == 0 )); then
    err "This does not look like a disposable lab VM."
    err "Refusing to run. Options:"
    err "  * run it on a throwaway GCE instance / container, or"
    err "  * 'sudo touch /etc/cdl-lab-vm' to mark this host as disposable, or"
    err "  * re-run with --i-know-what-im-doing"
    exit 78   # EX_CONFIG
  fi
}

require_python() {
  command -v "${PY}" >/dev/null 2>&1 || {
    err "python3 not found. This lab needs Python 3.8+ (standard library only)."
    exit 69   # EX_UNAVAILABLE
  }
}

backup_file() {
  # backup_file <path>  -- idempotent, never overwrites an existing backup
  local src="$1" rel dst
  rel="${src#"${LAB_ROOT}"/}"
  dst="${BACKUP_DIR}/${rel}"
  mkdir -p "$(dirname "${dst}")"
  [[ -e "${dst}" ]] || cp -a "${src}" "${dst}"
}

# ==============================================================================
#  SETUP -- build the healthy baseline
# ==============================================================================
cmd_setup() {
  assert_disposable_vm "${GUARD_FLAG:-}"
  require_python

  log "building the baseline ML system under ${LAB_ROOT}"
  mkdir -p "${DATA_DIR}" "${MODEL_DIR}" "${SRC_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"

  # ---------------------------------------------------------------------------
  # 1. The training dataset.
  #
  #    Vocabulary check (exam-relevant, Topic 3.1):
  #      * A *feature* is an input column the model learns from.
  #      * The *label* is the answer column we are trying to predict.
  #      * Data that carries the label is *structured, labelled* data, which is
  #        what *supervised learning* requires. Unsupervised learning has no
  #        label column and finds structure (clustering) instead.
  #      * Here: features = tenure_months, monthly_charges, support_tickets,
  #        has_contract; label = churned (1 = the customer left).
  #
  #    Business framing: churn prediction is a classic ML business case. The
  #    value is not the prediction, it is the *action* it enables -- a retention
  #    offer sent to the ~15% of customers most likely to leave, instead of a
  #    discount blasted at 100% of the base.
  # ---------------------------------------------------------------------------
  log "generating labelled training data (deterministic, seeded)"
  "${PY}" - "${DATA_DIR}/train.csv" <<'PYEOF'
import csv, random, sys

random.seed(20260812)  # deterministic: the lab must be reproducible

path = sys.argv[1]
rows = []
for _ in range(4000):
    tenure   = random.randint(1, 72)          # months with the company
    charges  = round(random.uniform(20, 120), 2)
    tickets  = random.randint(0, 9)           # support tickets last quarter
    contract = random.choice([0, 1])          # 1 = on a term contract

    # Ground-truth generating process. Short tenure, high bill, many tickets
    # and no contract all push the customer toward leaving.
    score = (
        2.2
        - 0.055 * tenure
        + 0.021 * charges
        + 0.34  * tickets
        - 1.30  * contract
    )
    p = 1.0 / (1.0 + pow(2.718281828, -score))
    churned = 1 if random.random() < p else 0
    rows.append([tenure, charges, tickets, contract, churned])

with open(path, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["tenure_months", "monthly_charges", "support_tickets",
                "has_contract", "churned"])
    w.writerows(rows)

pos = sum(r[-1] for r in rows)
print(f"wrote {len(rows)} labelled rows to {path} "
      f"(churn rate {pos/len(rows):.1%})")
PYEOF

  # A held-out evaluation split. It must come from the SAME distribution as
  # training but must NEVER be seen during training -- that is the whole point
  # of a test set. Evaluating on training data is the "it scored 99% in the
  # notebook and 60% in production" trap.
  log "generating the held-out evaluation split"
  "${PY}" - "${DATA_DIR}/eval.csv" <<'PYEOF'
import csv, random, sys

random.seed(777)  # different seed => different samples, same distribution

path = sys.argv[1]
rows = []
for _ in range(1000):
    tenure   = random.randint(1, 72)
    charges  = round(random.uniform(20, 120), 2)
    tickets  = random.randint(0, 9)
    contract = random.choice([0, 1])
    score = (2.2 - 0.055*tenure + 0.021*charges + 0.34*tickets - 1.30*contract)
    p = 1.0 / (1.0 + pow(2.718281828, -score))
    rows.append([tenure, charges, tickets, contract,
                 1 if random.random() < p else 0])

with open(path, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["tenure_months", "monthly_charges", "support_tickets",
                "has_contract", "churned"])
    w.writerows(rows)
print(f"wrote {len(rows)} held-out rows to {path}")
PYEOF

  # ---------------------------------------------------------------------------
  # 2. The trainer.
  #
  #    A hand-rolled logistic regression trained by gradient descent. No
  #    third-party libraries, so the lab runs on a bare VM. The important part
  #    is not the maths -- it is the CONTRACT it writes out:
  #
  #      model/model.json  holds the learned weights AND the feature schema:
  #        the ordered list of feature names, plus the mean/std used to
  #        normalise each one.
  #
  #    That schema is the training/serving contract. Vertex AI Feature Store
  #    and the Vertex AI Model Registry exist precisely so this contract is
  #    stored once and shared by the trainer and the server. When the two sides
  #    disagree, you get *training/serving skew* -- and the model degrades
  #    silently, with no error, no stack trace, no alert.
  # ---------------------------------------------------------------------------
  log "writing the trainer (src/train.py)"
  cat > "${SRC_DIR}/train.py" <<'PYEOF'
#!/usr/bin/env python3
"""Train a logistic-regression churn model. Standard library only.

Writes model/model.json containing weights AND the feature schema
(names + normalisation statistics). The schema is the training/serving
contract: whatever preprocessing happened here must happen identically
at serving time, or the model sees inputs it was never trained on.
"""
import csv, json, math, os, sys

ROOT     = os.environ.get("LAB_ROOT", "/opt/cdl-lab-3.1")
TRAIN    = os.path.join(ROOT, "data", "train.csv")
MODEL    = os.path.join(ROOT, "model", "model.json")
FEATURES = ["tenure_months", "monthly_charges", "support_tickets", "has_contract"]
LABEL    = "churned"


def load(path):
    with open(path) as fh:
        rows = list(csv.DictReader(fh))
    X = [[float(r[f]) for f in FEATURES] for r in rows]
    y = [float(r[LABEL]) for r in rows]
    return X, y


def standardise(X):
    """Per-feature z-score. Returns (X_scaled, means, stds)."""
    n, d = len(X), len(X[0])
    means, stds = [], []
    for j in range(d):
        col = [row[j] for row in X]
        mu = sum(col) / n
        var = sum((v - mu) ** 2 for v in col) / n
        sd = math.sqrt(var) or 1.0     # guard against a constant column
        means.append(mu)
        stds.append(sd)
    Xs = [[(row[j] - means[j]) / stds[j] for j in range(d)] for row in X]
    return Xs, means, stds


def sigmoid(z):
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    e = math.exp(z)                    # numerically stable branch
    return e / (1.0 + e)


def train(X, y, epochs=400, lr=0.35):
    d = len(X[0])
    w, b = [0.0] * d, 0.0
    n = len(X)
    for epoch in range(epochs):
        gw, gb, loss = [0.0] * d, 0.0, 0.0
        for xi, yi in zip(X, y):
            p = sigmoid(sum(w[j] * xi[j] for j in range(d)) + b)
            p = min(max(p, 1e-12), 1 - 1e-12)
            loss += -(yi * math.log(p) + (1 - yi) * math.log(1 - p))
            e = p - yi
            for j in range(d):
                gw[j] += e * xi[j]
            gb += e
        for j in range(d):
            w[j] -= lr * gw[j] / n
        b -= lr * gb / n
        if epoch % 100 == 0:
            print(f"  epoch {epoch:>4}  log-loss {loss / n:.5f}")
    return w, b


def main():
    if not os.path.exists(TRAIN):
        print(f"FATAL: training data not found: {TRAIN}", file=sys.stderr)
        return 66
    X, y = load(TRAIN)
    if not X:
        print("FATAL: training set is empty", file=sys.stderr)
        return 65

    pos_rate = sum(y) / len(y)
    print(f"  {len(X)} rows, {len(FEATURES)} features, "
          f"positive-class rate {pos_rate:.1%}")

    Xs, means, stds = standardise(X)
    w, b = train(Xs, y)

    os.makedirs(os.path.dirname(MODEL), exist_ok=True)
    with open(MODEL, "w") as fh:
        json.dump({
            "schema_version": 1,
            "features": FEATURES,          # ORDER IS PART OF THE CONTRACT
            "means": means,
            "stds": stds,
            "weights": w,
            "bias": b,
            "train_rows": len(X),
            "train_positive_rate": pos_rate,
        }, fh, indent=2)
    print(f"  wrote {MODEL}")
    for f, wt in zip(FEATURES, w):
        print(f"    weight[{f:<17}] = {wt:+.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

  # ---------------------------------------------------------------------------
  # 3. The prediction server (batch scorer).
  #
  #    Deliberately written the way real serving code drifts: it re-declares its
  #    own idea of the feature order and its own normalisation constants,
  #    instead of reading them from the model artifact. That is the seam every
  #    training/serving-skew incident opens along.
  # ---------------------------------------------------------------------------
  log "writing the prediction server (src/predict.py)"
  cat > "${SRC_DIR}/predict.py" <<'PYEOF'
#!/usr/bin/env python3
"""Batch-score customers with the trained churn model.

Reads model/model.json and scores every row of data/incoming.csv, writing
logs/predictions.csv. Also prints a production-style summary: how many
customers were flagged, and what fraction of the base that is.
"""
import csv, json, math, os, sys

ROOT     = os.environ.get("LAB_ROOT", "/opt/cdl-lab-3.1")
MODEL    = os.path.join(ROOT, "model", "model.json")
INCOMING = os.path.join(ROOT, "data", "incoming.csv")
OUT      = os.path.join(ROOT, "logs", "predictions.csv")

# Decision threshold. Above this probability we send a retention offer.
# Choosing it is a BUSINESS decision, not a technical one: it trades false
# positives (a discount wasted on a loyal customer) against false negatives
# (a customer lost). Precision vs recall, priced in currency.
THRESHOLD = float(os.environ.get("CHURN_THRESHOLD", "0.5"))


def sigmoid(z):
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    e = math.exp(z)
    return e / (1.0 + e)


def main():
    if not os.path.exists(MODEL):
        print(f"FATAL: no model artifact at {MODEL}. Train first.",
              file=sys.stderr)
        return 66
    with open(MODEL) as fh:
        m = json.load(fh)

    feats, means, stds = m["features"], m["means"], m["stds"]
    w, b = m["weights"], m["bias"]

    with open(INCOMING) as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        print("FATAL: incoming.csv has no rows", file=sys.stderr)
        return 65

    missing = [f for f in feats if f not in rows[0]]
    if missing:
        print(f"FATAL: incoming data is missing required features: {missing}",
              file=sys.stderr)
        return 65

    flagged, out_rows, probs = 0, [], []
    for r in rows:
        x = [(float(r[f]) - means[i]) / stds[i] for i, f in enumerate(feats)]
        p = sigmoid(sum(w[i] * x[i] for i in range(len(w))) + b)
        probs.append(p)
        hit = 1 if p >= THRESHOLD else 0
        flagged += hit
        out_rows.append([r.get("customer_id", ""), round(p, 4), hit])

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", newline="") as fh:
        wtr = csv.writer(fh)
        wtr.writerow(["customer_id", "churn_probability", "flagged"])
        wtr.writerows(out_rows)

    mean_p = sum(probs) / len(probs)
    print(f"  scored {len(rows)} customers")
    print(f"  mean predicted churn probability : {mean_p:.3f}")
    print(f"  flagged for retention offer      : {flagged} "
          f"({flagged / len(rows):.1%} of the base)")
    print(f"  predictions written to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

  # ---------------------------------------------------------------------------
  # 4. The evaluator -- the monitoring job.
  #
  #    In a real deployment this is what Vertex AI Model Monitoring does for
  #    you: it watches accuracy against labelled ground truth and watches the
  #    *distribution* of incoming features for drift. Without it, a degraded
  #    model keeps returning HTTP 200 with confident, wrong answers, and nobody
  #    notices until revenue does.
  # ---------------------------------------------------------------------------
  log "writing the evaluator (src/evaluate.py)"
  cat > "${SRC_DIR}/evaluate.py" <<'PYEOF'
#!/usr/bin/env python3
"""Evaluate the model on the held-out split and print a confusion matrix.

Emits the metrics a business stakeholder actually asks about:
  accuracy  -- share of predictions that were right (misleading on imbalanced
               data: predicting 'nobody churns' scores 85% on a 15% churn base)
  precision -- of the customers we flagged, how many really would have left
               (this is the cost of wasted retention discounts)
  recall    -- of the customers who really left, how many did we catch
               (this is the revenue we failed to save)
  F1        -- the harmonic mean; one number when you must have one number
"""
import csv, json, math, os, sys

ROOT  = os.environ.get("LAB_ROOT", "/opt/cdl-lab-3.1")
MODEL = os.path.join(ROOT, "model", "model.json")
EVAL  = os.path.join(ROOT, "data", "eval.csv")
LABEL = "churned"
THRESHOLD = float(os.environ.get("CHURN_THRESHOLD", "0.5"))


def sigmoid(z):
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    e = math.exp(z)
    return e / (1.0 + e)


def main():
    if not os.path.exists(MODEL):
        print(f"FATAL: no model artifact at {MODEL}", file=sys.stderr)
        return 66
    with open(MODEL) as fh:
        m = json.load(fh)
    feats, means, stds = m["features"], m["means"], m["stds"]
    w, b = m["weights"], m["bias"]

    with open(EVAL) as fh:
        rows = list(csv.DictReader(fh))

    tp = fp = tn = fn = 0
    for r in rows:
        x = [(float(r[f]) - means[i]) / stds[i] for i, f in enumerate(feats)]
        p = sigmoid(sum(w[i] * x[i] for i in range(len(w))) + b)
        pred = 1 if p >= THRESHOLD else 0
        act = int(float(r[LABEL]))
        if pred == 1 and act == 1: tp += 1
        elif pred == 1 and act == 0: fp += 1
        elif pred == 0 and act == 0: tn += 1
        else: fn += 1

    n = tp + fp + tn + fn
    acc  = (tp + tn) / n if n else 0.0
    prec = tp / (tp + fp) if (tp + fp) else 0.0
    rec  = tp / (tp + fn) if (tp + fn) else 0.0
    f1   = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0

    print("  confusion matrix (rows = actual, cols = predicted)")
    print("                 pred:stay   pred:churn")
    print(f"    act:stay     {tn:>9}   {fp:>10}")
    print(f"    act:churn    {fn:>9}   {tp:>10}")
    print()
    print(f"  accuracy   {acc:.3f}")
    print(f"  precision  {prec:.3f}")
    print(f"  recall     {rec:.3f}")
    print(f"  F1         {f1:.3f}")

    with open(os.path.join(ROOT, "logs", "metrics.json"), "w") as fh:
        json.dump({"accuracy": acc, "precision": prec,
                   "recall": rec, "f1": f1, "n": n}, fh, indent=2)

    # The lab's health gate. A correctly trained model on this data lands
    # around F1 0.80. Anything under 0.60 means the pipeline is broken.
    if f1 < 0.60:
        print()
        print(f"  *** MODEL HEALTH CHECK FAILED: F1 {f1:.3f} < 0.60 ***")
        return 1
    print()
    print(f"  model health check PASSED (F1 {f1:.3f} >= 0.60)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

  # ---------------------------------------------------------------------------
  # 5. Live traffic to score.
  # ---------------------------------------------------------------------------
  log "generating today's incoming scoring batch"
  "${PY}" - "${DATA_DIR}/incoming.csv" <<'PYEOF'
import csv, random, sys

random.seed(31337)
path = sys.argv[1]
rows = []
for i in range(600):
    rows.append([
        f"CUST-{i:05d}",
        random.randint(1, 72),
        round(random.uniform(20, 120), 2),
        random.randint(0, 9),
        random.choice([0, 1]),
    ])
with open(path, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["customer_id", "tenure_months", "monthly_charges",
                "support_tickets", "has_contract"])
    w.writerows(rows)
print(f"wrote {len(rows)} unlabelled rows to {path}")
PYEOF

  chmod +x "${SRC_DIR}"/*.py

  hr
  log "training the baseline model"
  LAB_ROOT="${LAB_ROOT}" "${PY}" "${SRC_DIR}/train.py"
  hr
  log "evaluating the baseline model"
  LAB_ROOT="${LAB_ROOT}" "${PY}" "${SRC_DIR}/evaluate.py"
  hr
  log "scoring today's batch"
  LAB_ROOT="${LAB_ROOT}" "${PY}" "${SRC_DIR}/predict.py"
  hr

  # Freeze the healthy state so 'verify' has a reference and 'restore' works.
  cp -a "${DATA_DIR}"  "${BACKUP_DIR}/data"  2>/dev/null || true
  cp -a "${SRC_DIR}"   "${BACKUP_DIR}/src"   2>/dev/null || true
  cp -a "${MODEL_DIR}" "${BACKUP_DIR}/model" 2>/dev/null || true
  cp -a "${LOG_DIR}/metrics.json" "${BACKUP_DIR}/baseline_metrics.json"
  echo "state=healthy" > "${STATE_FILE}"

  ok "baseline is healthy and frozen in ${BACKUP_DIR}"
  echo
  printf '%sBaseline established.%s Now run: %ssudo %s break%s\n' \
    "${C_BOLD}" "${C_RESET}" "${C_CYN}" "$0" "${C_RESET}"
}

# ==============================================================================
#  BREAK -- inject one controlled fault
# ==============================================================================

# ------------------------------------------------------------------------------
# Scenario 1: TRAINING/SERVING SKEW
#
#   Someone "cleaned up" the serving path and reordered the feature list so it
#   matches the column order of the new upstream export. The model artifact
#   still lists the original order. Every value is now multiplied by the wrong
#   weight and normalised by the wrong mean/std.
#
#   Real-world analogue: a BigQuery view is rebuilt with columns in a different
#   order, or an engineer edits the serving container without touching the
#   training job. Vertex AI Feature Store exists to make this impossible.
# ------------------------------------------------------------------------------
break_skew() {
  backup_file "${SRC_DIR}/predict.py"
  "${PY}" - "${SRC_DIR}/predict.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()

# The serving path stops trusting the model's schema and hardcodes its own.
old = '    feats, means, stds = m["features"], m["means"], m["stds"]\n'
new = (
    '    # 2026-08-30 -- realigned to the new upstream export column order\n'
    '    feats = ["monthly_charges", "tenure_months", "has_contract",\n'
    '             "support_tickets"]\n'
    '    means, stds = m["means"], m["stds"]\n'
)
assert old in s, "anchor not found -- lab source drifted"
open(p, "w").write(s.replace(old, new))
print("serving feature order overridden")
PYEOF
  echo "state=broken" > "${STATE_FILE}"
  echo "scenario=1"  >> "${STATE_FILE}"
}

# ------------------------------------------------------------------------------
# Scenario 2: DATA QUALITY / GARBAGE IN, GARBAGE OUT
#
#   An upstream ETL change starts emitting the churn label as the strings
#   "yes"/"no" instead of 1/0, and a "helpful" coercion turns everything into
#   0. The model trains on data where nobody ever churns, learns the only thing
#   that data supports -- "nobody churns" -- and serves it with total
#   confidence.
#
#   This is the single most common cause of a failed ML project, and Topic 3.1
#   states it directly: the quality of the model is bounded by the quality of
#   the training data.
# ------------------------------------------------------------------------------
break_data() {
  backup_file "${DATA_DIR}/train.csv"
  "${PY}" - "${DATA_DIR}/train.csv" <<'PYEOF'
import csv, sys
p = sys.argv[1]
rows = list(csv.reader(open(p)))
header, body = rows[0], rows[1:]
li = header.index("churned")
for r in body:
    r[li] = "0"          # upstream regression: every label collapses to 0
with open(p, "w", newline="") as fh:
    w = csv.writer(fh); w.writerow(header); w.writerows(body)
print(f"corrupted the label column of {len(body)} training rows")
PYEOF
  log "retraining on the corrupted data (this is what the nightly job would do)"
  LAB_ROOT="${LAB_ROOT}" "${PY}" "${SRC_DIR}/train.py" \
    > "${LOG_DIR}/last_train.log" 2>&1 || true
  echo "state=broken" > "${STATE_FILE}"
  echo "scenario=2"  >> "${STATE_FILE}"
}

# ------------------------------------------------------------------------------
# Scenario 3: MODEL / DATA DRIFT
#
#   The world moved. A competitor launched, the customer base shifted toward
#   short-tenure high-bill accounts, and the incoming traffic no longer looks
#   like the training data. The model is unchanged and every metric computed on
#   the OLD eval set still looks fine -- which is exactly why drift is so
#   dangerous. Only the input distribution tells you.
# ------------------------------------------------------------------------------
break_drift() {
  backup_file "${DATA_DIR}/incoming.csv"
  "${PY}" - "${DATA_DIR}/incoming.csv" <<'PYEOF'
import csv, random, sys
random.seed(4242)
p = sys.argv[1]
rows = list(csv.DictReader(open(p)))
fields = list(rows[0].keys())
for r in rows:
    # Post-launch population: everyone is new, bills are high, contracts gone.
    r["tenure_months"]   = str(random.randint(1, 4))
    r["monthly_charges"] = str(round(random.uniform(150, 260), 2))
    r["support_tickets"] = str(random.randint(6, 14))
    r["has_contract"]    = "0"
with open(p, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields)
    w.writeheader(); w.writerows(rows)
print(f"shifted the distribution of {len(rows)} incoming rows")
PYEOF
  echo "state=broken" > "${STATE_FILE}"
  echo "scenario=3"  >> "${STATE_FILE}"
}

# ------------------------------------------------------------------------------
# Scenario 4: SILENT ARTIFACT CORRUPTION / NO MODEL GOVERNANCE
#
#   A deploy script wrote a partially-populated model.json: the weights array
#   is truncated to two elements while the schema still declares four features.
#   Nothing validated the artifact before it was promoted to production.
#
#   Real-world analogue: promoting a model to an endpoint without the Vertex AI
#   Model Registry's versioning and evaluation gate in front of it.
# ------------------------------------------------------------------------------
break_artifact() {
  backup_file "${MODEL_DIR}/model.json"
  "${PY}" - "${MODEL_DIR}/model.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m["weights"] = m["weights"][:2]       # truncated during an interrupted upload
m["schema_version"] = 1               # nothing bumped, nothing noticed
json.dump(m, open(p, "w"), indent=2)
print("model artifact truncated: 4 features declared, 2 weights present")
PYEOF
  echo "state=broken" > "${STATE_FILE}"
  echo "scenario=4"  >> "${STATE_FILE}"
}

cmd_break() {
  assert_disposable_vm "${GUARD_FLAG:-}"
  require_python
  [[ -f "${STATE_FILE}" ]] || { err "run 'setup' first"; exit 69; }

  local scenario="${1:-}"
  if [[ -z "${scenario}" ]]; then
    scenario=$(( (RANDOM % 4) + 1 ))
  fi
  [[ "${scenario}" =~ ^[1-4]$ ]] || { err "scenario must be 1..4"; exit 64; }

  log "injecting fault (scenario hidden until you diagnose it)"
  case "${scenario}" in
    1) break_skew     ;;
    2) break_data     ;;
    3) break_drift    ;;
    4) break_artifact ;;
  esac

  hr
  cat <<'BRIEF'

  ============================================================================
   INCIDENT BRIEF -- you are the on-call for the churn prediction service
  ============================================================================

  09:14  The retention team files a ticket:

           "The churn model is wrong. Yesterday it flagged about 15% of the
            base, which matched what we always saw. This morning the number
            is completely different and the campaign owner refuses to send
            the offers. Nothing was deployed by us. Is the model down?"

  The service is NOT down. Every process exits 0 or throws exactly one
  traceback, the API would return HTTP 200, and no alert fired. That is the
  lesson: an ML system fails by being CONFIDENTLY WRONG, not by crashing.

  ----------------------------------------------------------------------------
  SYMPTOMS YOU WILL SEE
  ----------------------------------------------------------------------------

  Run the three jobs and read the output:

      export LAB_ROOT=/opt/cdl-lab-3.1
      python3 $LAB_ROOT/src/evaluate.py     # offline quality gate
      python3 $LAB_ROOT/src/predict.py      # today's batch scoring
      cat     $LAB_ROOT/logs/metrics.json

  Depending on which fault you drew, ONE of these is what you will observe:

   (a) evaluate.py prints "MODEL HEALTH CHECK FAILED", F1 collapses toward
       0.3-0.5, and the confusion matrix shows the predictions are close to
       random. predict.py still runs fine and still prints a percentage.

   (b) evaluate.py reports a suspiciously HIGH accuracy (around 0.85) with
       precision 0.000 and recall 0.000, and the confusion matrix has an
       entirely empty "pred:churn" column. predict.py flags 0 customers --
       0.0% of the base. The model has learned to say "no" to everything.

   (c) evaluate.py PASSES cleanly -- F1 unchanged, health check green -- but
       predict.py flags a wildly different share of the base (near 100%) and
       the mean predicted probability is pinned near 1.0. The offline metrics
       and the online behaviour disagree.

   (d) predict.py dies with an IndexError inside the scoring loop, or scores
       every customer identically. The artifact itself is malformed.

  ----------------------------------------------------------------------------
  WHAT YOU MUST ACHIEVE
  ----------------------------------------------------------------------------

  1. Name the failure mode in the vocabulary of Topic 3.1. Exactly one of:

        * training/serving skew
        * poor training-data quality (garbage in, garbage out)
        * data / model drift
        * a corrupted model artifact promoted without governance

  2. Prove it with evidence from the lab, not from a hunch. Useful moves:

        # Does the serving path agree with the artifact's schema?
        python3 -c "import json;print(json.load(open('$LAB_ROOT/model/model.json'))['features'])"
        grep -n 'feats' $LAB_ROOT/src/predict.py

        # Is the label column still a label?
        cut -d, -f5 $LAB_ROOT/data/train.csv | sort | uniq -c

        # Do training and serving inputs still look alike?
        #   compare column means between train.csv and incoming.csv
        awk -F, 'NR>1{t+=$1;c+=$2;n++} END{printf "train  tenure %.1f charges %.1f\n",t/n,c/n}' $LAB_ROOT/data/train.csv
        awk -F, 'NR>1{t+=$2;c+=$3;n++} END{printf "incoming tenure %.1f charges %.1f\n",t/n,c/n}' $LAB_ROOT/data/incoming.csv

        # Is the artifact internally consistent?
        python3 -c "import json;m=json.load(open('$LAB_ROOT/model/model.json'));print(len(m['features']),len(m['weights']),len(m['means']))"

  3. Repair the system so that:

        * evaluate.py exits 0 with F1 >= 0.60
        * predict.py exits 0 and flags a plausible share of the base
        * the model artifact declares as many weights/means/stds as features
        * the fix removes the CAUSE, not the symptom -- lowering the health
          threshold or hardcoding an output is a failed exercise

  4. Answer the business question the ticket actually asked, in two sentences
     a non-engineer can act on: what broke, what it cost, and what control
     would have caught it before the campaign owner did.

  5. Then run:   ./break-and-fix-3.1.sh verify

  ----------------------------------------------------------------------------
  A NOTE ON WHY THIS IS TOPIC 3.1 AND NOT AN OPS EXERCISE
  ----------------------------------------------------------------------------

  The Cloud Digital Leader exam asks you to "describe fundamental AI and ML
  concepts and how they create business value". Business value in ML is not
  created by the model; it is created by the DECISION the model changes, and
  it is destroyed the moment the model's inputs stop matching reality. Every
  one of these four faults leaves the infrastructure perfectly healthy and
  the business outcome perfectly wrong. Recognising that gap -- and naming the
  Google Cloud control that closes it (Vertex AI Feature Store for skew,
  data validation for quality, Vertex AI Model Monitoring for drift, the
  Vertex AI Model Registry for governance) -- is the whole objective.

BRIEF
  hr
  warn "system is now in the BROKEN state. Diagnose before you read hints."
}

# ==============================================================================
#  VERIFY -- grade the student's repair
# ==============================================================================
cmd_verify() {
  require_python
  [[ -f "${STATE_FILE}" ]] || { err "run 'setup' first"; exit 69; }

  local pass=0 fail=0

  hr
  log "checking artifact consistency"
  if LAB_ROOT="${LAB_ROOT}" "${PY}" - "${MODEL_DIR}/model.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
n = len(m["features"])
bad = [k for k in ("weights", "means", "stds") if len(m[k]) != n]
if bad:
    print(f"    {n} features declared but {bad} disagree in length")
    sys.exit(1)
sys.exit(0)
PYEOF
  then ok "artifact schema is internally consistent"; pass=$((pass+1))
  else err "artifact schema is inconsistent"; fail=$((fail+1)); fi

  log "checking that serving reads the schema from the artifact"
  if grep -qE 'feats[, ].*=.*m\["features"\]' "${SRC_DIR}/predict.py"; then
    ok "predict.py takes its feature order from the model artifact"
    pass=$((pass+1))
  else
    err "predict.py still hardcodes its own feature order (skew risk)"
    fail=$((fail+1))
  fi

  log "checking training-label integrity"
  if LAB_ROOT="${LAB_ROOT}" "${PY}" - "${DATA_DIR}/train.csv" <<'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
vals = {r["churned"] for r in rows}
rate = sum(int(float(r["churned"])) for r in rows) / len(rows)
if vals - {"0", "1"}:
    print(f"    label column holds non-binary values: {sorted(vals)[:5]}")
    sys.exit(1)
if not (0.05 < rate < 0.95):
    print(f"    degenerate label distribution: positive rate {rate:.1%}")
    sys.exit(1)
print(f"    positive-class rate {rate:.1%}")
sys.exit(0)
PYEOF
  then ok "training labels are binary and non-degenerate"; pass=$((pass+1))
  else err "training labels are unusable"; fail=$((fail+1)); fi

  log "running the offline quality gate"
  if LAB_ROOT="${LAB_ROOT}" "${PY}" "${SRC_DIR}/evaluate.py"; then
    ok "evaluate.py passes the F1 >= 0.60 health gate"; pass=$((pass+1))
  else
    err "evaluate.py fails the health gate"; fail=$((fail+1))
  fi

  log "running online batch scoring"
  if LAB_ROOT="${LAB_ROOT}" "${PY}" "${SRC_DIR}/predict.py"; then
    ok "predict.py completes"; pass=$((pass+1))
  else
    err "predict.py fails"; fail=$((fail+1))
  fi

  log "checking online/offline agreement (drift gate)"
  if LAB_ROOT="${LAB_ROOT}" "${PY}" - "${LOG_DIR}/predictions.csv" <<'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
rate = sum(int(r["flagged"]) for r in rows) / len(rows)
print(f"    flagged share of the base: {rate:.1%}")
# A healthy population on this model lands roughly 10%-45%. Pinned at ~0% or
# ~100% means the serving inputs no longer resemble the training population.
if not (0.05 < rate < 0.60):
    print("    the served population does not resemble the training population")
    sys.exit(1)
sys.exit(0)
PYEOF
  then ok "serving population is consistent with training"; pass=$((pass+1))
  else err "distribution mismatch between training and serving"; fail=$((fail+1)); fi

  hr
  if (( fail == 0 )); then
    echo "state=healthy" > "${STATE_FILE}"
    ok "ALL ${pass} CHECKS PASSED -- the churn service is healthy again."
    echo
    printf '%sNow answer the business question in your own words:%s\n' \
      "${C_BOLD}" "${C_RESET}"
    printf '  1. Which of the four failure modes was it?\n'
    printf '  2. Which Google Cloud control would have caught it first?\n'
    printf '  3. What did it cost the retention campaign while it was broken?\n'
    return 0
  fi
  err "${fail} check(s) still failing, ${pass} passing. Keep going."
  printf '  need a nudge?  %s hint\n' "$0"
  return 1
}

# ==============================================================================
#  HINT / RESTORE / CLEANUP
# ==============================================================================
cmd_hint() {
  local sc; sc="$(sed -n 's/^scenario=//p' "${STATE_FILE}" 2>/dev/null || true)"
  hr
  cat <<'HINT'
  HINT 1 (free): a healthy ML system has three contracts. Check each in turn.
     (i)   data -> trainer   : are the labels still labels?
     (ii)  trainer -> artifact: does the artifact declare as many weights as
                                features?
     (iii) artifact -> server : does the server use the artifact's feature
                                order, or its own?
     A fault in (i) shows up in evaluate.py. A fault in (iii) shows up only
     when you compare evaluate.py's verdict with predict.py's behaviour.

  HINT 2: if evaluate.py is GREEN and predict.py still looks wrong, the model
     is fine and the INPUTS changed. That is drift, and no amount of retraining
     the old data will fix it -- you retrain on the NEW population.

  HINT 3: if evaluate.py reports high accuracy with precision 0 and recall 0,
     accuracy is lying to you. On an imbalanced base, "always predict no" is
     85% accurate and worth nothing. Look at the label column itself.
HINT
  [[ -n "${sc}" ]] && printf '\n  (this run injected scenario %s of 4)\n' "${sc}"
  hr
}

cmd_restore() {
  assert_disposable_vm "${GUARD_FLAG:-}"
  [[ -d "${BACKUP_DIR}" ]] || { err "no backup found; run 'setup'"; exit 69; }
  log "restoring the healthy baseline from ${BACKUP_DIR}"
  for d in data src model; do
    [[ -d "${BACKUP_DIR}/${d}" ]] && { rm -rf "${LAB_ROOT:?}/${d}"; cp -a "${BACKUP_DIR}/${d}" "${LAB_ROOT}/"; }
  done
  echo "state=healthy" > "${STATE_FILE}"
  ok "baseline restored"
}

cmd_cleanup() {
  assert_disposable_vm "${GUARD_FLAG:-}"
  [[ "${LAB_ROOT}" == "/" || -z "${LAB_ROOT}" ]] && { err "refusing"; exit 1; }
  [[ -d "${LAB_ROOT}" ]] || { warn "nothing to clean"; exit 0; }
  log "removing ${LAB_ROOT}"
  rm -rf "${LAB_ROOT:?}"
  ok "lab removed. Nothing outside ${LAB_ROOT} was touched."
}

usage() {
  cat <<USAGE
Usage: $0 {setup|break [1-4]|verify|hint|restore|cleanup} [--i-know-what-im-doing]

  setup     build the healthy churn-prediction baseline in ${LAB_ROOT}
  break     inject one controlled fault and print the incident brief
  verify    grade your repair against six independent checks
  hint      graduated hints
  restore   put the healthy baseline back
  cleanup   delete ${LAB_ROOT} entirely
USAGE
}

# ------------------------------------------------------------------------------
main() {
  GUARD_FLAG=""
  local args=()
  for a in "$@"; do
    [[ "${a}" == "--i-know-what-im-doing" ]] && { GUARD_FLAG="${a}"; continue; }
    args+=("${a}")
  done
  set -- ${args[@]+"${args[@]}"}

  case "${1:-}" in
    setup)   cmd_setup ;;
    break)   cmd_break "${2:-}" ;;
    verify)  cmd_verify ;;
    hint)    cmd_hint ;;
    restore) cmd_restore ;;
    cleanup) cmd_cleanup ;;
    *)       usage; exit 64 ;;
  esac
}

main "$@"

# ==============================================================================
# ==============================================================================
#
#   S O L U T I O N   --   read only after you have attempted the repair
#
# ==============================================================================
# ==============================================================================
#
# ------------------------------------------------------------------------------
# STEP 0 -- TRIAGE COMMON TO ALL FOUR SCENARIOS
# ------------------------------------------------------------------------------
#
#   export LAB_ROOT=/opt/cdl-lab-3.1
#
#   Establish which side is broken before touching anything. There are exactly
#   two questions, and their four combinations map one-to-one onto the four
#   faults:
#
#     Q1. Does evaluate.py pass?   (is the MODEL good on known-good data?)
#     Q2. Does predict.py behave?  (do the INPUTS match what the model expects?)
#
#       Q1 fail + Q2 runs        -> the model is bad     -> scenario 1 or 2
#       Q1 pass + Q2 misbehaves  -> the inputs are bad   -> scenario 3
#       Q2 raises IndexError     -> the artifact is bad  -> scenario 4
#
#   Distinguish 1 from 2 with the confusion matrix:
#     - precision 0.000 AND recall 0.000 with an empty pred:churn column means
#       the model never predicts the positive class -> the LABELS are dead
#       -> scenario 2.
#     - a matrix that looks roughly random across all four cells means the
#       weights are being applied to the wrong columns -> scenario 1.
#
#   Baseline numbers to compare against are frozen in:
#     cat $LAB_ROOT/.backup/baseline_metrics.json
#     # {"accuracy": ~0.79, "precision": ~0.75, "recall": ~0.86, "f1": ~0.80}
#
# ------------------------------------------------------------------------------
# SCENARIO 1 -- TRAINING/SERVING SKEW
# ------------------------------------------------------------------------------
#
#   DIAGNOSIS
#
#     $ python3 -c "import json;print(json.load(open('$LAB_ROOT/model/model.json'))['features'])"
#     ['tenure_months', 'monthly_charges', 'support_tickets', 'has_contract']
#
#     $ grep -n -A3 'feats' $LAB_ROOT/src/predict.py
#     34:    feats = ["monthly_charges", "tenure_months", "has_contract",
#     35:             "support_tickets"]
#
#     The two lists differ. means[0]/stds[0]/weights[0] were learned for
#     tenure_months (range 1-72) but are now being applied to monthly_charges
#     (range 20-120). Every feature is normalised by the wrong statistics and
#     multiplied by the wrong coefficient. Nothing raises: all four columns are
#     numeric, so the arithmetic succeeds and produces garbage.
#
#     Confirm it is serving-only by noting that evaluate.py -- which DOES read
#     m["features"] -- still passes. Offline green, online wrong. That
#     asymmetry is the signature of skew.
#
#   FIX
#
#     Delete the hardcoded list. The artifact is the single source of truth:
#
#       $ sudo sed -i \
#           -e '/realigned to the new upstream export/d' \
#           -e '/feats = \["monthly_charges"/,/"support_tickets"\]/d' \
#           $LAB_ROOT/src/predict.py
#
#     then restore the contract line immediately above the means/stds line:
#
#       $ sudo sed -i \
#           's|^    means, stds = m\["means"\], m\["stds"\]$|    feats, means, stds = m["features"], m["means"], m["stds"]|' \
#           $LAB_ROOT/src/predict.py
#
#     Verify and re-score:
#
#       $ python3 $LAB_ROOT/src/predict.py
#         scored 600 customers
#         mean predicted churn probability : 0.4xx
#         flagged for retention offer      : ~2xx (3x.x% of the base)
#
#   ROOT CAUSE AND THE CONTROL THAT PREVENTS IT
#
#     The serving code owned a second, independent copy of the feature schema.
#     Two copies of a contract always drift. On Google Cloud the control is
#     Vertex AI Feature Store: training and serving read feature definitions
#     and values from the same store, so a column reorder upstream cannot
#     desynchronise them. Vertex AI Model Monitoring additionally reports
#     training/serving skew by comparing serving inputs against the training
#     baseline.
#     https://cloud.google.com/vertex-ai/docs/featurestore/overview
#     https://cloud.google.com/vertex-ai/docs/model-monitoring/overview
#
# ------------------------------------------------------------------------------
# SCENARIO 2 -- POOR TRAINING-DATA QUALITY (GARBAGE IN, GARBAGE OUT)
# ------------------------------------------------------------------------------
#
#   DIAGNOSIS
#
#     $ python3 $LAB_ROOT/src/evaluate.py
#         confusion matrix (rows = actual, cols = predicted)
#                        pred:stay   pred:churn
#           act:stay           4xx            0
#           act:churn          5xx            0
#         accuracy   0.4xx      <- or ~0.85 on a more imbalanced draw
#         precision  0.000
#         recall     0.000
#
#     An entirely empty pred:churn column means the model has never once
#     predicted the positive class. That is not a tuning problem. Look at what
#     it was trained on:
#
#     $ cut -d, -f5 $LAB_ROOT/data/train.csv | sort | uniq -c
#        4000 0
#           1 churned
#
#     Every label is 0. The training set contains zero examples of the event
#     we are trying to predict. The model learned the only rule that data
#     supports -- "nobody ever churns" -- and it learned it perfectly.
#
#     Note the trap: on a base with 15% churn, "nobody churns" scores 85%
#     ACCURACY. Accuracy alone would have shipped this. Precision and recall
#     are the metrics that expose it.
#
#   FIX
#
#     You cannot repair labels that were destroyed; you restore them from the
#     source of truth and retrain. In the lab the frozen copy is the source:
#
#       $ sudo cp $LAB_ROOT/.backup/data/train.csv $LAB_ROOT/data/train.csv
#       $ cut -d, -f5 $LAB_ROOT/data/train.csv | sort | uniq -c
#          33xx 0
#           6xx 1
#          (a real churn rate again)
#
#       $ python3 $LAB_ROOT/src/train.py
#         4000 rows, 4 features, positive-class rate 1x.x%
#         epoch    0  log-loss 0.69315
#         ...
#         weight[tenure_months     ] = -0.9xxx
#         weight[monthly_charges   ] = +0.6xxx
#         weight[support_tickets   ] = +0.9xxx
#         weight[has_contract      ] = -0.6xxx
#
#     The signs are the sanity check a domain expert should perform: longer
#     tenure and having a contract REDUCE churn (negative weights); higher
#     bills and more support tickets INCREASE it (positive). A weight whose
#     sign contradicts the business understanding is itself a data bug.
#
#       $ python3 $LAB_ROOT/src/evaluate.py    # F1 back to ~0.80, exits 0
#
#   ROOT CAUSE AND THE CONTROL THAT PREVENTS IT
#
#     An upstream schema change was allowed to reach the trainer unvalidated,
#     and the training job had no gate that would refuse a degenerate label
#     distribution. The controls: schema and distribution validation on the
#     data before training (TensorFlow Data Validation inside Vertex AI
#     Pipelines), plus a training job that hard-fails when the positive-class
#     rate leaves an expected band. This is the concrete meaning of the exam's
#     statement that a model is only as good as its training data.
#     https://cloud.google.com/vertex-ai/docs/pipelines/introduction
#
# ------------------------------------------------------------------------------
# SCENARIO 3 -- DATA / MODEL DRIFT
# ------------------------------------------------------------------------------
#
#   DIAGNOSIS
#
#     $ python3 $LAB_ROOT/src/evaluate.py
#         ... F1 0.80 ... model health check PASSED
#
#     $ python3 $LAB_ROOT/src/predict.py
#         mean predicted churn probability : 0.99x
#         flagged for retention offer      : 600 (100.0% of the base)
#
#     The model is provably fine on the data it was validated against, and
#     provably useless on today's traffic. Therefore the model did not change
#     -- the WORLD changed. Prove it by comparing distributions:
#
#     $ awk -F, 'NR>1{t+=$1;c+=$2;k+=$3;n++} END{printf "train    tenure %.1f charges %.1f tickets %.1f\n",t/n,c/n,k/n}' $LAB_ROOT/data/train.csv
#       train    tenure 36.5 charges 70.1 tickets 4.5
#     $ awk -F, 'NR>1{t+=$2;c+=$3;k+=$4;n++} END{printf "incoming tenure %.1f charges %.1f tickets %.1f\n",t/n,c/n,k/n}' $LAB_ROOT/data/incoming.csv
#       incoming tenure  2.5 charges 205.3 tickets 10.0
#
#     Mean tenure fell from 36 months to 2.5; the average bill nearly tripled;
#     monthly_charges values now sit far outside the training range entirely.
#     The model is extrapolating beyond anything it ever saw, and a logistic
#     model asked to extrapolate saturates -- hence probabilities pinned at
#     ~1.0. It is not "wrong", it is being asked a question outside its domain.
#
#   FIX
#
#     Drift is fixed by making the training data represent the current world,
#     not by editing the model. Two legitimate paths:
#
#     (a) The lab's population genuinely changed and the incoming batch is the
#         new normal -- then retrain on data drawn from the new distribution
#         and re-baseline the eval split.
#
#     (b) The incoming batch is itself the anomaly -- an ETL bug, a unit change
#         (charges suddenly in cents, tenure in weeks) -- then the correct fix
#         is upstream, not in the model. ALWAYS rule this out first: a tripled
#         bill and a 14x drop in tenure across an entire batch is far more
#         often a broken pipeline than a real market shift.
#
#     In this lab it is (b) -- the batch was replaced wholesale, which no real
#     customer base does overnight. Restore the legitimate batch and re-score:
#
#       $ sudo cp $LAB_ROOT/.backup/data/incoming.csv $LAB_ROOT/data/incoming.csv
#       $ python3 $LAB_ROOT/src/predict.py
#         mean predicted churn probability : 0.4xx
#         flagged for retention offer      : ~2xx (3x.x% of the base)
#
#     If you want to practise path (a) instead, append the drifted rows to
#     train.csv WITH correct labels and retrain -- the point being that new
#     labels, not new code, are what a drifted model needs.
#
#   ROOT CAUSE AND THE CONTROL THAT PREVENTS IT
#
#     Nothing was watching the input distribution. Offline metrics computed on
#     a frozen eval set cannot detect drift by construction, because the eval
#     set never drifts. The control is Vertex AI Model Monitoring, which
#     compares the statistical distribution of live prediction requests against
#     the training baseline and alerts when the divergence crosses a threshold
#     -- feature-attribution drift and prediction drift, on a schedule, with no
#     ground-truth labels required.
#     https://cloud.google.com/vertex-ai/docs/model-monitoring/overview
#
# ------------------------------------------------------------------------------
# SCENARIO 4 -- CORRUPTED ARTIFACT PROMOTED WITHOUT GOVERNANCE
# ------------------------------------------------------------------------------
#
#   DIAGNOSIS
#
#     $ python3 $LAB_ROOT/src/predict.py
#       Traceback (most recent call last):
#         ...
#         p = sigmoid(sum(w[i] * x[i] for i in range(len(w))) + b)
#       IndexError: list index out of range
#
#     (or, if the loop bounds happen to hide it, every prediction is identical
#     because two of the four features contribute nothing at all.)
#
#     $ python3 -c "import json;m=json.load(open('$LAB_ROOT/model/model.json'));print(len(m['features']),len(m['weights']),len(m['means']),len(m['stds']))"
#     4 2 4 4
#
#     The artifact declares four features but carries two weights. It is
#     internally inconsistent and was never validated before promotion.
#
#   FIX
#
#     Do not hand-patch weights -- a fabricated weight is a fabricated model.
#     Re-produce the artifact from the training data, which is exactly why the
#     training data and the training code are the real assets:
#
#       $ python3 $LAB_ROOT/src/train.py
#       $ python3 -c "import json;m=json.load(open('$LAB_ROOT/model/model.json'));print(len(m['features']),len(m['weights']))"
#       4 4
#       $ python3 $LAB_ROOT/src/evaluate.py   # exits 0
#       $ python3 $LAB_ROOT/src/predict.py    # exits 0
#
#     If the training data were also gone, you would roll back to the previous
#     model VERSION -- which requires that previous versions were kept.
#
#   ROOT CAUSE AND THE CONTROL THAT PREVENTS IT
#
#     A model artifact was written to the serving location directly, with no
#     integrity check and no versioned predecessor to fall back to. The control
#     is the Vertex AI Model Registry: models are versioned, aliases point at
#     the version currently serving, promotion is a deliberate act, and
#     rollback is repointing an alias rather than rebuilding from source.
#     https://cloud.google.com/vertex-ai/docs/model-registry/introduction
#
# ------------------------------------------------------------------------------
# THE ANSWER TO THE BUSINESS QUESTION (all scenarios)
# ------------------------------------------------------------------------------
#
#   Two sentences, no jargon, for the retention team:
#
#     "The model itself never crashed -- it kept answering, but the data
#      reaching it stopped matching the data it learned from, so its answers
#      stopped meaning anything. We restored the correct data, retrained, and
#      re-scored today's batch; the flagged share is back to the usual range,
#      and we are adding an automatic check that compares live data against
#      the training data so the system tells us next time instead of the
#      campaign owner."
#
#   Cost framing the exam expects you to be able to produce:
#     * scenario 2 flags nobody -> every at-risk customer this cycle is lost
#       unwarned. The cost is churned revenue that a cheap offer would have
#       saved.
#     * scenario 3 flags everybody -> a retention discount goes to the entire
#       base, including customers who were never going to leave. The cost is
#       margin given away for nothing.
#     Both are invisible in an uptime dashboard. This is why ML systems need
#     quality monitoring in addition to availability monitoring, and it is the
#     core of what Topic 3.1 means by "how AI and ML create business value" --
#     value that appears only when the model's inputs, its metrics and the
#     decision it drives all stay aligned.
#
# ------------------------------------------------------------------------------
# CONCEPT RECAP MAPPED TO THE EXAM GUIDE (Topic 3.1)
# ------------------------------------------------------------------------------
#
#   AI vs ML vs deep learning vs generative AI
#     AI is the broad field of systems performing tasks that need human-like
#     intelligence. ML is the subset that LEARNS the rules from data instead of
#     being programmed with them -- this lab's logistic regression is ML. Deep
#     learning is the subset of ML using multi-layer neural networks. Generative
#     AI is the subset of deep learning that produces new content from a
#     foundation model. All four failure modes in this lab apply to all four
#     categories: a generative model with a drifted prompt distribution or an
#     unvalidated fine-tuning corpus fails in exactly the same way.
#
#   Supervised vs unsupervised
#     This lab is supervised: it required a LABEL column (`churned`). Scenario 2
#     is what supervised learning looks like when the labels die. An
#     unsupervised approach -- clustering the customer base -- would have
#     survived that particular fault, because it never needed the label, and
#     is the right tool when labels do not exist yet.
#
#   Data quality as the binding constraint
#     Scenarios 1, 2 and 3 are all data problems wearing different masks:
#     wrong order, wrong values, wrong distribution. Only scenario 4 is a
#     software problem. That ratio is representative of real ML operations.
#
#   Where the business value actually lives
#     Not in the F1 score. In the retention offer that reaches the right 15% of
#     customers instead of 0% or 100%. Every check in `verify` is ultimately
#     testing that one business outcome.
#
#   Source: Google Cloud Digital Leader exam guide, Section 3.1
#   https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#
# ==============================================================================