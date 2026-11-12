#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 1.3: Differentiate the concepts of AI, machine learning,
#                       and deep learning
# BREAK & FIX LAB
# -----------------------------------------------------------------------------
# Runs on a DISPOSABLE lab VM. It only writes inside $LAB_DIR (default
# ~/aiio-lab-1.3). No root, no packages, no network, no GPU required:
# only bash + python3 (standard library).
#
# The lab builds one prediction problem (a noisy XOR, the textbook
# "not linearly separable" dataset) and solves it three ways:
#
#   1. Symbolic AI      -> humans write the IF/THEN rules (rules.txt).
#                          Nothing is learned from data.
#   2. Machine learning -> logistic regression LEARNS weights from data, but a
#                          human chooses the features (lab.ini [ml] features).
#   3. Deep learning    -> a multi-layer neural network LEARNS its own
#                          features in hidden layers through a non-linear
#                          activation (lab.ini [dl]).
#
# It also includes an infrastructure-sizing catalog (workloads.ini). Each
# workload there is labeled AI-symbolic / ML / DL and mapped to CPU or GPU.
# An AI infrastructure operator makes exactly this decision.
#
# Usage:
#   ./lab-1.3-break-fix.sh            # setup + break + briefing
#   ./lab-1.3-break-fix.sh verify     # check your fix
#   ./lab-1.3-break-fix.sh brief      # show the briefing again
#   ./lab-1.3-break-fix.sh reset      # rebuild the healthy lab (nothing broken)
#   ./lab-1.3-break-fix.sh clean      # delete the lab directory
#
# References:
#   https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   https://developer.nvidia.com/topics/ai/ai-inference
#   https://developer.nvidia.com/tensorrt
#   https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
#   https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
# =============================================================================
set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/aiio-lab-1.3}"
MARKER=".aiio-lab-1.3"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

preflight() {
  if [[ "${EUID}" -eq 0 ]]; then
    red "Do not run this lab as root. It only needs your normal user."
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    red "python3 is required (standard library only). Install it in the VM first."
    exit 1
  fi
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
    red "python3 >= 3.8 is required."
    exit 1
  fi
  case "$LAB_DIR" in
    ""|"/"|"$HOME"|"$HOME/") red "Refusing unsafe LAB_DIR='$LAB_DIR'"; exit 1 ;;
  esac
}

safe_remove() {
  if [[ -d "$LAB_DIR" ]]; then
    if [[ ! -f "$LAB_DIR/$MARKER" ]]; then
      red "$LAB_DIR exists but was not created by this lab (no $MARKER). Not touching it."
      exit 1
    fi
    rm -rf -- "$LAB_DIR"
  fi
}

write_lab() {
  mkdir -p "$LAB_DIR"
  touch "$LAB_DIR/$MARKER"

  # ---------------------------------------------------------------- lab.py --
  cat > "$LAB_DIR/lab.py" <<'PYEOF'
#!/usr/bin/env python3
"""AI vs ML vs DL on the same problem. Standard library only."""
import configparser
import math
import os
import random
import sys

LAB = os.path.dirname(os.path.abspath(__file__))
TARGET = 0.95


def die(msg):
    print(f"CONFIG ERROR: {msg}")
    sys.exit(2)


def load_ini(name):
    cfg = configparser.ConfigParser()
    path = os.path.join(LAB, name)
    if not cfg.read(path):
        die(f"cannot read {path}")
    return cfg


def dataset(n, seed):
    """Noisy XOR: label 1 when x1 and x2 have the same sign."""
    rng = random.Random(seed)
    centers = [(1, 1), (-1, -1), (1, -1), (-1, 1)]
    pts = []
    for i in range(n):
        cx, cy = centers[i % 4]
        x1 = cx + rng.gauss(0, 0.3)
        x2 = cy + rng.gauss(0, 0.3)
        pts.append((x1, x2, 1 if x1 * x2 > 0 else 0))
    return pts


TRAIN = dataset(200, 1)
TEST = dataset(200, 2)


def accuracy(predict, data):
    return sum(1 for x1, x2, y in data if predict(x1, x2) == y) / len(data)


def sigmoid(z):
    if z < -60:
        return 0.0
    if z > 60:
        return 1.0
    return 1.0 / (1.0 + math.exp(-z))


# ---------------------------------------------------------- 1. symbolic AI --
def load_rules():
    rules, default = [], None
    path = os.path.join(LAB, "rules.txt")
    with open(path) as fh:
        for ln, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            tok = line.split()
            if tok[0] == "DEFAULT" and len(tok) == 2:
                default = int(tok[1])
                continue
            if tok[0] != "IF" or "THEN" not in tok or tok.index("THEN") + 1 >= len(tok):
                die(f"rules.txt:{ln}: expected 'IF <cond> [AND <cond>] THEN <0|1>'")
            ti = tok.index("THEN")
            out = int(tok[ti + 1])
            conds = []
            for part in " ".join(tok[1:ti]).split(" AND "):
                p = part.split()
                if len(p) != 3 or p[0] not in ("x1", "x2") or p[1] not in (">", "<"):
                    die(f"rules.txt:{ln}: bad condition '{part}'")
                conds.append((p[0], p[1], float(p[2])))
            rules.append((conds, out))
    if default is None:
        die("rules.txt: missing 'DEFAULT <0|1>' line")
    return rules, default


def run_symbolic():
    rules, default = load_rules()

    def predict(x1, x2):
        env = {"x1": x1, "x2": x2}
        for conds, out in rules:
            if all(env[v] > n if op == ">" else env[v] < n for v, op, n in conds):
                return out
        return default

    acc = accuracy(predict, TEST)
    print("[symbolic AI] knowledge source : human-written rules (rules.txt)")
    print(f"[symbolic AI] rules loaded     : {len(rules)} (+ DEFAULT {default})")
    print("[symbolic AI] learned params   : 0 (nothing is trained)")
    print(f"[symbolic AI] test accuracy    : {acc:.3f}")
    return acc


# ------------------------------------------------------- 2. machine learning --
FEATURES = {
    "x1": lambda a, b: a,
    "x2": lambda a, b: b,
    "x1*x2": lambda a, b: a * b,
    "x1^2": lambda a, b: a * a,
    "x2^2": lambda a, b: b * b,
}


def run_ml():
    cfg = load_ini("lab.ini")["ml"]
    names = [f.strip() for f in cfg.get("features", "").split(",") if f.strip()]
    if not names:
        die("[ml] features is empty")
    for n in names:
        if n not in FEATURES:
            die(f"[ml] unknown feature '{n}'. Valid: {', '.join(FEATURES)}")
    lr = cfg.getfloat("learning_rate")
    epochs = cfg.getint("epochs")

    def feats(a, b):
        return [FEATURES[n](a, b) for n in names]

    rng = random.Random(3)
    w = [0.0] * len(names)
    bias = 0.0
    data = list(TRAIN)
    for _ in range(epochs):
        rng.shuffle(data)
        for a, b, y in data:
            f = feats(a, b)
            p = sigmoid(sum(wi * fi for wi, fi in zip(w, f)) + bias)
            g = p - y
            w = [wi - lr * g * fi for wi, fi in zip(w, f)]
            bias -= lr * g

    def predict(a, b):
        z = sum(wi * fi for wi, fi in zip(w, feats(a, b))) + bias
        return 1 if sigmoid(z) >= 0.5 else 0

    acc = accuracy(predict, TEST)
    print("[ml]          knowledge source : weights learned from data, features chosen by a human")
    print(f"[ml]          features         : {', '.join(names)}")
    print("[ml]          learned weights  : "
          + ", ".join(f"{n}={wi:+.2f}" for n, wi in zip(names, w)) + f", bias={bias:+.2f}")
    print(f"[ml]          learned params   : {len(w) + 1}")
    print(f"[ml]          test accuracy    : {acc:.3f}")
    return acc


# ---------------------------------------------------------- 3. deep learning --
ACTS = {
    "tanh": (math.tanh, lambda z, h: 1.0 - h * h),
    "relu": (lambda z: z if z > 0 else 0.0, lambda z, h: 1.0 if z > 0 else 0.0),
    "linear": (lambda z: z, lambda z, h: 1.0),
}


def run_dl():
    cfg = load_ini("lab.ini")["dl"]
    hidden = cfg.getint("hidden_units")
    act_name = cfg.get("activation").strip()
    lr = cfg.getfloat("learning_rate")
    epochs = cfg.getint("epochs")
    if act_name not in ACTS:
        die(f"[dl] unknown activation '{act_name}'. Valid: {', '.join(ACTS)}")
    if hidden < 1:
        die("[dl] hidden_units must be >= 1 (0 hidden units is just logistic regression)")
    act, dact = ACTS[act_name]

    rng = random.Random(7)
    w1 = [[rng.gauss(0, 1 / math.sqrt(2)) for _ in range(2)] for _ in range(hidden)]
    b1 = [0.0] * hidden
    w2 = [rng.gauss(0, 1 / math.sqrt(hidden)) for _ in range(hidden)]
    b2 = 0.0

    def forward(x):
        pre = [w1[j][0] * x[0] + w1[j][1] * x[1] + b1[j] for j in range(hidden)]
        h = [act(z) for z in pre]
        p = sigmoid(sum(w2[j] * h[j] for j in range(hidden)) + b2)
        return pre, h, p

    data = list(TRAIN)
    for _ in range(epochs):
        rng.shuffle(data)
        for a, b, y in data:
            x = (a, b)
            pre, h, p = forward(x)
            g = p - y
            for j in range(hidden):
                gh = g * w2[j] * dact(pre[j], h[j])
                w2[j] -= lr * g * h[j]
                w1[j][0] -= lr * gh * x[0]
                w1[j][1] -= lr * gh * x[1]
                b1[j] -= lr * gh
            b2 -= lr * g

    def predict(a, b):
        return 1 if forward((a, b))[2] >= 0.5 else 0

    acc = accuracy(predict, TEST)
    params = hidden * 2 + hidden + hidden + 1
    print("[dl]          knowledge source : features learned in the hidden layer from raw x1, x2")
    print(f"[dl]          architecture     : 2 -> {hidden} ({act_name}) -> 1 (sigmoid)")
    print(f"[dl]          learned params   : {params}")
    print(f"[dl]          test accuracy    : {acc:.3f}")
    return acc


# ------------------------------------------------------- 4. infra taxonomy --
VALID_CAT = {"ai_symbolic", "ml", "dl"}
VALID_ACC = {"cpu", "gpu", "gpu_optional"}
EXPECTED = {
    "fraud_rules_engine": ("ai_symbolic", {"cpu"}),
    "churn_gradient_boosting": ("ml", {"cpu", "gpu_optional"}),
    "llm_finetune": ("dl", {"gpu"}),
    "defect_detection_cnn": ("dl", {"gpu"}),
}


def run_taxonomy():
    cfg = load_ini("workloads.ini")
    ok = True
    for name, (cat, accs) in EXPECTED.items():
        if name not in cfg:
            print(f"[taxonomy]    {name:<24} MISSING section")
            ok = False
            continue
        s = cfg[name]
        c = s.get("category", "").strip()
        a = s.get("accelerator", "").strip()
        if c not in VALID_CAT or a not in VALID_ACC:
            print(f"[taxonomy]    {name:<24} INVALID value (category in {sorted(VALID_CAT)},"
                  f" accelerator in {sorted(VALID_ACC)})")
            ok = False
            continue
        good = c == cat and a in accs
        ok = ok and good
        print(f"[taxonomy]    {name:<24} category={c:<12} accelerator={a:<13} "
              + ("OK" if good else "WRONG - reread its description"))
    return ok


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    runners = {"symbolic": run_symbolic, "ml": run_ml, "dl": run_dl}
    if cmd in runners:
        sys.exit(0 if runners[cmd]() >= TARGET else 1)
    if cmd == "taxonomy":
        sys.exit(0 if run_taxonomy() else 1)
    if cmd != "all":
        print("usage: lab.py [all|symbolic|ml|dl|taxonomy]")
        sys.exit(2)
    results = {}
    for k, fn in runners.items():
        results[k] = fn() >= TARGET
        print()
    results["taxonomy"] = run_taxonomy()
    print()
    for k, v in results.items():
        suffix = "" if k == "taxonomy" else f" (target >= {TARGET})"
        print(f"{k:<10} {'PASS' if v else 'FAIL'}{suffix}")
    sys.exit(0 if all(results.values()) else 1)


if __name__ == "__main__":
    main()
PYEOF
  chmod +x "$LAB_DIR/lab.py"

  # ------------------------------------------------------------- rules.txt --
  cat > "$LAB_DIR/rules.txt" <<'EOF'
# Symbolic AI knowledge base, written by a domain expert.
# Evaluated top to bottom; first matching rule wins.
# Grammar: IF <var> <op> <number> [AND <var> <op> <number>] THEN <0|1>
#          var in {x1, x2}, op in {>, <}
IF x1 > 0 AND x2 > 0 THEN 1
IF x1 < 0 AND x2 < 0 THEN 1
DEFAULT 0
EOF

  # --------------------------------------------------------------- lab.ini --
  cat > "$LAB_DIR/lab.ini" <<'EOF'
[ml]
# Logistic regression: a LINEAR model over the features you list here.
# Available: x1, x2, x1*x2, x1^2, x2^2
features = x1, x2, x1*x2
learning_rate = 0.1
epochs = 100

[dl]
# Multi-layer perceptron: 2 inputs -> hidden layer -> 1 output.
# activation: tanh | relu | linear
hidden_units = 8
activation = tanh
learning_rate = 0.05
epochs = 150
EOF

  # --------------------------------------------------------- workloads.ini --
  cat > "$LAB_DIR/workloads.ini" <<'EOF'
# Capacity-planning catalog for the AI platform team.
# category    : ai_symbolic | ml | dl
# accelerator : cpu | gpu | gpu_optional

[fraud_rules_engine]
description = Compliance analysts maintain 300 IF/THEN rules that flag transactions. No training step.
category = ai_symbolic
accelerator = cpu

[churn_gradient_boosting]
description = Gradient-boosted trees trained on 40 hand-engineered tabular features (tenure, plan, ticket count).
category = ml
accelerator = gpu_optional

[llm_finetune]
description = Fine-tune a 7B-parameter transformer on support transcripts. Features are learned from raw tokens.
category = dl
accelerator = gpu

[defect_detection_cnn]
description = Convolutional network that learns visual features directly from raw camera pixels.
category = dl
accelerator = gpu
EOF
}

break_lab() {
  # 1) Symbolic AI: the expert's second rule disappears from the knowledge base.
  sed -i '/^IF x1 < 0 AND x2 < 0 THEN 1$/d' "$LAB_DIR/rules.txt"
  # 2) ML: someone "simplified" the feature list and dropped the engineered feature.
  sed -i 's/^features = .*/features = x1, x2/' "$LAB_DIR/lab.ini"
  # 3) DL: the activation was switched to linear "because it trains faster".
  sed -i 's/^activation = tanh$/activation = linear/' "$LAB_DIR/lab.ini"
  # 4) Infra: two catalog entries were mislabeled during a migration.
  sed -i '/^\[fraud_rules_engine\]/,/^accelerator/{s/^category = .*/category = dl/;s/^accelerator = .*/accelerator = gpu/}' \
    "$LAB_DIR/workloads.ini"
  sed -i '/^\[llm_finetune\]/,/^accelerator/{s/^category = .*/category = ml/;s/^accelerator = .*/accelerator = cpu/}' \
    "$LAB_DIR/workloads.ini"
}

briefing() {
  bold "================================================================"
  bold " NCA-AIIO 1.3 BREAK & FIX - AI vs ML vs DL"
  bold "================================================================"
  cat <<EOF

Lab directory: $LAB_DIR

Three systems solve the same problem (noisy XOR: label 1 when x1 and x2
have the same sign). All three used to score >= 0.95 on the test set.
The nightly check started failing after last night's "cleanup" commit.

Run it yourself:
  cd $LAB_DIR && python3 lab.py

SYMPTOMS YOU WILL SEE
  symbolic  FAIL  accuracy around 0.75 - one quadrant is now mispredicted
  ml        FAIL  accuracy around 0.50 - no better than a coin flip
  dl        FAIL  accuracy around 0.50 - even though it has hidden units
  taxonomy  FAIL  two workloads in workloads.ini are mislabeled

YOUR GOAL
  Make 'python3 lab.py' print PASS on all four lines, then run:
    $0 verify

  Fix each layer IN ITS OWN TERMS. That is the point of the lab:
   - Symbolic AI : the knowledge lives in rules a human wrote. You cannot
                   retrain it. Which piece of knowledge is missing?
   - ML          : the model is linear in whatever features you give it.
                   Which feature makes XOR linearly separable?
   - DL          : a deep network must learn the features itself. Which
                   property of the hidden layer makes that possible?
   - Taxonomy    : read each description. Who supplies the knowledge or
                   the features? What does that imply for CPU vs GPU?

RULES
  - Do not edit lab.py. Only edit rules.txt, lab.ini and workloads.ini.
  - Do not lower the TARGET threshold and do not hard-code answers.
  - Run '$0 reset' to restore a healthy lab if you get lost.

EOF
}

verify() {
  if [[ ! -f "$LAB_DIR/$MARKER" ]]; then
    red "Lab not found in $LAB_DIR. Run '$0' first."
    exit 1
  fi
  bold "Verifying..."
  local rc=0
  ( cd "$LAB_DIR" && python3 lab.py ) || rc=$?
  echo
  if [[ $rc -ne 0 ]]; then
    red "Still failing (exit $rc). Re-read the briefing: '$0 brief'"
    exit "$rc"
  fi
  # Anti-shortcut checks: the fix must be the conceptually right one.
  local act
  act=$(sed -n 's/^activation = //p' "$LAB_DIR/lab.ini")
  if [[ "$act" == "linear" ]]; then
    red "activation is still linear. A stack of linear layers collapses to one linear model."
    exit 1
  fi
  if ! grep -Eq '^features = .*x1\*x2' "$LAB_DIR/lab.ini"; then
    red "[ml] passes without the x1*x2 feature? Check that you did not change epochs or the dataset."
    exit 1
  fi
  green "ALL CHECKS PASSED. Symbolic AI, ML and DL were each fixed in their own terms."
}

main() {
  preflight
  case "${1:-run}" in
    run)
      safe_remove
      write_lab
      break_lab
      briefing
      ;;
    reset)
      safe_remove
      write_lab
      green "Healthy lab restored in $LAB_DIR (nothing broken). Run '$0' to break it again."
      ;;
    verify) verify ;;
    brief)  briefing ;;
    clean)  safe_remove; green "Removed $LAB_DIR" ;;
    *) echo "usage: $0 [run|verify|reset|brief|clean]"; exit 2 ;;
  esac
}

main "$@"

# =============================================================================
# SOLUTION (step by step) - try for real before reading this
# =============================================================================
#
# STEP 0 - Observe and isolate
#   cd ~/aiio-lab-1.3
#   python3 lab.py            # all four checks
#   python3 lab.py symbolic   # one system at a time, exit code 0 = PASS
#   python3 lab.py ml
#   python3 lab.py dl
#   python3 lab.py taxonomy
#
#   Diagnose the way you would in production: identify which system failed
#   and where its "knowledge" lives. Read the "knowledge source" line of
#   each block:
#     symbolic AI -> rules.txt        (a human encodes the knowledge)
#     ml          -> learned weights + human-chosen features
#     dl          -> learned weights + learned features (hidden layer)
#
# STEP 1 - Symbolic AI (accuracy ~0.75)
#   Look at the output: "rules loaded : 1 (+ DEFAULT 0)". The knowledge base
#   only knows the (+,+) quadrant. Points in (-,-) fall through to DEFAULT 0
#   and are mispredicted, which is 1/4 of the test set -> 0.75.
#   No amount of data or training helps here: symbolic AI does not learn.
#   A human must restore the missing knowledge:
#
#     sed -i '/^IF x1 > 0 AND x2 > 0 THEN 1$/a IF x1 < 0 AND x2 < 0 THEN 1' rules.txt
#     python3 lab.py symbolic     # expect: test accuracy 1.000, rules loaded 2
#
#   Lesson: AI is the umbrella term. Rule-based/expert systems ARE AI but
#   NOT machine learning. They are cheap to run (CPU, microseconds), fully
#   explainable, and brittle: every new case needs a human to write a rule.
#
# STEP 2 - Machine learning (accuracy ~0.50)
#   Output shows "features : x1, x2". Logistic regression draws ONE straight
#   line (a hyperplane) in feature space. XOR cannot be split by a straight
#   line in (x1, x2), so the best it can do is roughly a coin flip. The
#   learned weights stay close to zero: the optimizer found nothing to learn.
#   Feature engineering, a human decision, makes the problem linearly
#   separable: x1*x2 is positive exactly when the label is 1.
#
#     sed -i 's/^features = .*/features = x1, x2, x1*x2/' lab.ini
#     python3 lab.py ml           # expect: accuracy ~1.000, large positive
#                                 # weight on x1*x2, small weights on x1, x2
#
#   Lesson: ML learns parameters FROM DATA (the step symbolic AI lacks), but
#   classical ML depends on humans designing good features. This is typical
#   for tabular data (gradient boosting, linear models). It often runs well
#   on CPU. GPUs can accelerate it (for example, RAPIDS/XGBoost on GPU), but
#   they are optional. That is why churn_gradient_boosting is gpu_optional.
#
# STEP 3 - Deep learning (accuracy ~0.50 even with 8 hidden units)
#   Output shows "architecture : 2 -> 8 (linear) -> 1". With a linear
#   activation, W2*(W1*x + b1) + b2 is still ONE linear function of x. Any
#   stack of linear layers collapses to a single linear layer, which equals
#   the broken ML model from step 2. "Deep" without non-linearity is not deep.
#   Restore a non-linear activation so the hidden layer can learn the
#   x1*x2-like feature on its own:
#
#     sed -i 's/^activation = linear$/activation = tanh/' lab.ini
#     python3 lab.py dl           # expect: accuracy ~1.000 (relu also works)
#
#   Note that NOBODY gave the network the x1*x2 feature. This is the defining
#   difference: deep learning is the subset of ML that uses multi-layer neural
#   networks to learn representations from raw input (pixels, tokens, audio).
#   The cost: more parameters (33 here vs 4 in the ML model; billions in an
#   LLM), and training/inference dominated by dense matrix multiplications.
#   That is exactly the workload GPUs (and inference optimizers like
#   TensorRT) are built for.
#
# STEP 4 - Infrastructure taxonomy
#   Read each description and ask two questions: "who supplies the
#   knowledge/features?" and "how much dense linear algebra does it need?"
#
#     fraud_rules_engine : 300 IF/THEN rules, no training step
#                          -> ai_symbolic, cpu   (a GPU here is wasted money)
#     llm_finetune       : 7B-parameter transformer, features from raw tokens
#                          -> dl, gpu            (impractical on CPU)
#
#     sed -i '/^\[fraud_rules_engine\]/,/^accelerator/{s/^category = .*/category = ai_symbolic/;s/^accelerator = .*/accelerator = cpu/}' workloads.ini
#     sed -i '/^\[llm_finetune\]/,/^accelerator/{s/^category = .*/category = dl/;s/^accelerator = .*/accelerator = gpu/}' workloads.ini
#     python3 lab.py taxonomy     # expect: four lines ending in OK
#
#   Production translation: in Kubernetes, only the DL workloads should
#   request nvidia.com/gpu (exposed by the NVIDIA device plugin, which the
#   GPU Operator deploys). Putting a rules engine on a GPU node wastes the
#   most expensive resource in the cluster. Putting LLM fine-tuning on CPU
#   nodes turns hours into weeks.
#
# STEP 5 - Verify
#   ~/lab-1.3-break-fix.sh verify
#   Expected tail of the output:
#     symbolic   PASS (target >= 0.95)
#     ml         PASS (target >= 0.95)
#     dl         PASS (target >= 0.95)
#     taxonomy   PASS
#     ALL CHECKS PASSED. Symbolic AI, ML and DL were each fixed in their own terms.
#
# EXAM TAKEAWAY (NCA-AIIO 1.3)
#   AI  ⊃  ML  ⊃  DL
#   - AI: any technique that makes machines perform tasks that need
#     "intelligence"; includes rule-based systems with no learning at all.
#   - ML: systems that learn patterns from data instead of explicit rules;
#     classical ML relies on human feature engineering.
#   - DL: ML with multi-layer (deep) neural networks with non-linear
#     activations that learn features automatically from large amounts of
#     raw data. It is compute-hungry, and that drives GPU-accelerated
#     infrastructure for both training and inference.
# =============================================================================