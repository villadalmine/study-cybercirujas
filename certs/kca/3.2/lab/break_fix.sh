#!/usr/bin/env bash
#
# =============================================================================
#  KCA — Kyverno Certified Associate
#  Domain 3, Topic 3.2: `test` (Kyverno CLI offline policy testing)
#  Exam weight: 3.0
#
#  BREAK & FIX LAB — "the test suite that lies"
#
#  WHAT THIS EXERCISES
#    * Anatomy of a Test manifest (apiVersion cli.kyverno.io/v1alpha1, kind Test)
#    * How `policies:`, `resources:` and `variables:` are wired to files on disk
#    * Result semantics: pass / fail / skip / error, and why "fail" is often the
#      CORRECT expectation for a test case
#    * Feeding external data (ConfigMap context) to an offline run via a Value file
#    * Exit codes — the reason `kyverno test` belongs in CI, not in your terminal only
#
#  SAFETY
#    * 100% offline. This lab NEVER contacts a Kubernetes cluster, never runs
#      kubectl, never applies or deletes any cluster object. `kyverno test` is a
#      local, in-memory policy engine run.
#    * Every file written or destroyed lives under a single scratch directory
#      ($HOME/kca-lab-3.2-test by default, override with KCA_LAB_DIR).
#    * Still: run it on a disposable lab VM, as an unprivileged user. No sudo needed.
#
#  REQUIREMENTS
#    * Kyverno CLI v1.11.0 or newer (v1.12+ recommended) in $PATH.
#      https://kyverno.io/docs/kyverno-cli/install/
#      https://github.com/kyverno/kyverno/releases
#
#  USAGE
#    ./kca-3.2-break-fix.sh            # build the lab, prove it green, then break it
#    ./kca-3.2-break-fix.sh --reset    # wipe and rebuild the broken lab from scratch
#    ./kca-3.2-break-fix.sh --check    # grade your fix (integrity + exit code)
#    ./kca-3.2-break-fix.sh --brief    # reprint the briefing
#
#  SOURCES
#    * KCA curriculum ......... https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    * kyverno test ........... https://kyverno.io/docs/kyverno-cli/usage/test/
#    * CLI install ............ https://kyverno.io/docs/kyverno-cli/install/
#    * validate patterns ...... https://kyverno.io/docs/writing-policies/validate/
#    * variables .............. https://kyverno.io/docs/writing-policies/variables/
#    * external data sources .. https://kyverno.io/docs/writing-policies/external-data-sources/
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until you have burned at least 20 minutes on it.
# =============================================================================

set -euo pipefail

LAB_DIR="${KCA_LAB_DIR:-$HOME/kca-lab-3.2-test}"
STATE_DIR="$LAB_DIR/.lab"
MIN_CLI_HINT="v1.11.0"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; Z=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; Z=""
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s==> %s%s\n' "$B" "$*" "$Z"; }
ok()   { printf '%s[ ok ]%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '%s[fail]%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  head1 "Preflight"

  command -v kyverno >/dev/null 2>&1 || die \
"Kyverno CLI not found in \$PATH.
       Install it (${MIN_CLI_HINT} or newer), then re-run:
         curl -sSL https://github.com/kyverno/kyverno/releases/latest/download/kyverno-cli_linux_x86_64.tar.gz \\
           | tar -xz -C /tmp kyverno && install -m 0755 /tmp/kyverno ~/.local/bin/kyverno
       Docs: https://kyverno.io/docs/kyverno-cli/install/"

  ok "kyverno CLI: $(kyverno version 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"

  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required for grading."

  # This lab is offline by design; a live cluster is neither needed nor touched.
  if [[ -n "${KUBECONFIG:-}" || -f "$HOME/.kube/config" ]]; then
    warn "A kubeconfig is present. It will NOT be used: 'kyverno test' runs entirely offline."
  fi
}

confirm_disposable() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  say ""
  say "${Y}This script creates, overwrites and deletes files under:${Z}"
  say "    $LAB_DIR"
  say "${Y}Nothing outside that directory is modified, and no cluster is contacted.${Z}"
  read -r -p "Proceed on this disposable lab VM? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# -----------------------------------------------------------------------------
# Baseline: a CORRECT, green policy test suite
# -----------------------------------------------------------------------------
build_baseline() {
  head1 "Building the baseline suite in $LAB_DIR"
  rm -rf "$LAB_DIR"
  mkdir -p "$LAB_DIR/policies" "$LAB_DIR/resources" "$STATE_DIR"

  cat > "$LAB_DIR/policies/deployment-standards.yaml" <<'YAML'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: deployment-standards
  annotations:
    policies.kyverno.io/title: Deployment platform standards
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/description: >-
      Every Deployment must carry an owning `team` label, and every container
      image must be pulled from the registry declared in the platform ConfigMap.
spec:
  # NOTE: on Kyverno 1.13+ this moves to spec.rules[].validate.failureAction.
  # The spec-level field is still honoured and is what most exam material shows.
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
      validate:
        message: "Every Deployment must carry a `team` label."
        pattern:
          metadata:
            labels:
              team: "?*"

    - name: check-image-registry
      match:
        any:
          - resources:
              kinds:
                - Deployment
      context:
        # External data: in a live cluster this ConfigMap is read at admission
        # time. Offline, `kyverno test` has no API server, so the value must be
        # supplied by the Value file referenced from the Test manifest.
        - name: registryConfig
          configMap:
            name: platform-registry
            namespace: platform-system
      validate:
        message: "Images must come from the platform registry."
        pattern:
          spec:
            template:
              spec:
                containers:
                  - image: "{{ registryConfig.data.allowed }}/*"
YAML

  cat > "$LAB_DIR/resources/deployments.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: good-deployment
  namespace: default
  labels:
    team: platform
spec:
  replicas: 2
  selector:
    matchLabels:
      app: good
  template:
    metadata:
      labels:
        app: good
    spec:
      containers:
        - name: web
          image: registry.internal.example.com/nginx:1.27
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-label-deployment
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nolabel
  template:
    metadata:
      labels:
        app: nolabel
    spec:
      containers:
        - name: web
          image: registry.internal.example.com/nginx:1.27
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad-registry-deployment
  namespace: default
  labels:
    team: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: badreg
  template:
    metadata:
      labels:
        app: badreg
    spec:
      containers:
        - name: web
          image: docker.io/library/nginx:1.27
YAML

  cat > "$LAB_DIR/values.yaml" <<'YAML'
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
policies:
  - name: deployment-standards
    rules:
      - name: check-image-registry
        values:
          # Dotted key = the exact variable path the rule dereferences.
          registryConfig.data.allowed: registry.internal.example.com
YAML

  # The CORRECT Test manifest. It is written, proven green, and only then broken.
  cat > "$LAB_DIR/kyverno-test.yaml" <<'YAML'
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: deployment-standards-test
policies:
  - policies/deployment-standards.yaml
resources:
  - resources/deployments.yaml
variables: values.yaml
results:
  - policy: deployment-standards
    rule: check-team-label
    kind: Deployment
    resources:
      - good-deployment
      - bad-registry-deployment
    result: pass
  - policy: deployment-standards
    rule: check-team-label
    kind: Deployment
    resources:
      - no-label-deployment
    result: fail
  - policy: deployment-standards
    rule: check-image-registry
    kind: Deployment
    resources:
      - good-deployment
      - no-label-deployment
    result: pass
  - policy: deployment-standards
    rule: check-image-registry
    kind: Deployment
    resources:
      - bad-registry-deployment
    result: fail
YAML

  ok "policies/deployment-standards.yaml, resources/deployments.yaml, values.yaml, kyverno-test.yaml"
}

verify_baseline() {
  head1 "Proving the baseline is green BEFORE breaking anything"
  local out rc=0
  out="$(cd "$LAB_DIR" && kyverno test . 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    say "$out"
    die "The baseline suite does not pass on this CLI build (exit $rc).
       This lab targets Kyverno CLI ${MIN_CLI_HINT}+. Upgrade the CLI and re-run;
       do not start the exercise from a red baseline."
  fi
  printf '%s\n' "$out" | tail -n 12
  ok "Baseline green — 4 test cases, exit code 0. This is the state you must restore."

  # Integrity fingerprints, so the fix cannot be faked by deleting evidence.
  sha256sum "$LAB_DIR/resources/deployments.yaml" | awk '{print $1}' > "$STATE_DIR/resources.sha256"
  sha256sum "$LAB_DIR/policies/deployment-standards.yaml" | awk '{print $1}' > "$STATE_DIR/policy.sha256"
}

# -----------------------------------------------------------------------------
# The controlled breakage — four defects, delivered as three waves of symptoms
# -----------------------------------------------------------------------------
apply_breaks() {
  head1 "Applying the controlled breakage"
  cat > "$LAB_DIR/kyverno-test.yaml" <<'YAML'
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: deployment-standards-test
policies:
  - policy.yaml
resources:
  - resources/deployments.yaml
results:
  - policy: deployment-standards
    rule: check-team-label
    kind: Deployment
    resources:
      - good-deployment
      - bad-registry-deployment
    result: pass
  - policy: deployment-standards
    rule: check-team-label
    kind: Deployment
    resources:
      - no-label-deployment
    result: pass
  - policy: deployment-standards
    rule: check-image-registries
    kind: Deployment
    resources:
      - good-deployment
      - no-label-deployment
    result: pass
  - policy: deployment-standards
    rule: check-image-registry
    kind: Deployment
    resources:
      - bad-registry-deployment
    result: fail
YAML
  ok "Damage applied. Only kyverno-test.yaml was touched."
}

# -----------------------------------------------------------------------------
# Briefing
# -----------------------------------------------------------------------------
briefing() {
  cat <<BRIEF

${B}=============================================================================${Z}
${B} KCA 3.2 — BREAK & FIX BRIEFING${Z}
${B}=============================================================================${Z}

${B}Scenario.${Z} A teammate hand-edited the policy test suite before pushing. CI is
red. Nobody touched the policy or the fixtures — the suite itself is wrong, and
one of its expectations is a live lie: it asserts that a Deployment which
violates the policy is compliant. If you "fix" CI by trusting that assertion,
you ship a policy nobody is testing.

${B}Your working directory.${Z}
    cd $LAB_DIR

${B}The command under test.${Z}
    kyverno test .
    kyverno test . --detailed-results     # per-rule reasons — you will need this
    echo \$?                               # the exit code is the CI contract

${B}Symptoms, in the order you will meet them.${Z}

  ${C}Wave 1 — nothing runs at all.${Z} The CLI aborts before evaluating a single
  resource, with an error about loading the policies for this test (a path that
  does not resolve / "no policies found"). No results table is printed. Exit
  code is non-zero.

  ${C}Wave 2 — half the suite errors out.${Z} Once the run starts, the rows for the
  registry rule do not report a clean Pass or Fail: you get an error or a Fail
  whose reason mentions a variable that could not be substituted or resolved
  (a path like registryConfig.data.allowed). The label rule is unaffected.
  Ask yourself where an offline engine, with no API server, is supposed to get
  the contents of a ConfigMap.

  ${C}Wave 3 — the results table disagrees with reality.${Z} Everything evaluates,
  but the summary still reports failed test cases. Two kinds of mismatch are
  hiding here:
     * one expectation names something that does not exist in the policy, so the
       engine has no result to compare against;
     * one expectation claims a resource is compliant when the policy says it is
       not. Read resources/deployments.yaml and decide which of the three
       Deployments legitimately violates which rule.

${B}Definition of done.${Z}
    * ${G}kyverno test .${Z} prints all test cases as Pass and exits 0.
    * The suite still contains ${G}4 result entries${Z} covering all three fixtures.
    * ${R}resources/deployments.yaml is unmodified${Z} — you do not get to fix a test
      by rewriting the evidence.
    * ${R}policies/deployment-standards.yaml is unmodified${Z} — in particular the
      rule must keep dereferencing {{ registryConfig.data.allowed }}. Hardcoding
      the registry string into the policy is not a fix, it deletes the lesson.

${B}Grade yourself.${Z}
    $0 --check

${B}Start over.${Z}
    $0 --reset

${B}Reference.${Z} https://kyverno.io/docs/kyverno-cli/usage/test/

BRIEF
}

# -----------------------------------------------------------------------------
# Grading
# -----------------------------------------------------------------------------
do_check() {
  [[ -d "$LAB_DIR" ]] || die "Lab directory $LAB_DIR does not exist. Run: $0 --reset"
  [[ -f "$STATE_DIR/resources.sha256" ]] || die "Lab state missing. Run: $0 --reset"

  head1 "Grading"
  local failures=0

  # 1. Fixtures untouched.
  if [[ "$(sha256sum "$LAB_DIR/resources/deployments.yaml" | awk '{print $1}')" \
        == "$(cat "$STATE_DIR/resources.sha256")" ]]; then
    ok "resources/deployments.yaml is unmodified"
  else
    printf '%s[fail]%s resources/deployments.yaml was modified — fix the suite, not the fixtures\n' "$R" "$Z"
    failures=$((failures + 1))
  fi

  # 2. Policy untouched (no hardcoding the registry away).
  if [[ "$(sha256sum "$LAB_DIR/policies/deployment-standards.yaml" | awk '{print $1}')" \
        == "$(cat "$STATE_DIR/policy.sha256")" ]]; then
    ok "policies/deployment-standards.yaml is unmodified"
  else
    printf '%s[fail]%s the policy was modified — the ConfigMap context must stay in place\n' "$R" "$Z"
    failures=$((failures + 1))
  fi

  # 3. Coverage not amputated.
  local entries
  entries="$(grep -cE '^[[:space:]]*-[[:space:]]+policy:' "$LAB_DIR/kyverno-test.yaml" || true)"
  if [[ "$entries" -eq 4 ]]; then
    ok "4 result entries still present"
  else
    printf '%s[fail]%s expected 4 result entries, found %s — coverage was deleted, not repaired\n' "$R" "$Z" "$entries"
    failures=$((failures + 1))
  fi

  local fixture
  for fixture in good-deployment no-label-deployment bad-registry-deployment; do
    if grep -q -- "$fixture" "$LAB_DIR/kyverno-test.yaml"; then
      ok "fixture $fixture still asserted"
    else
      printf '%s[fail]%s fixture %s is no longer asserted anywhere\n' "$R" "$Z" "$fixture"
      failures=$((failures + 1))
    fi
  done

  # 4. The actual run.
  local out rc=0
  out="$(cd "$LAB_DIR" && kyverno test . 2>&1)" || rc=$?
  printf '\n%s\n\n' "$out"
  if [[ $rc -eq 0 ]]; then
    ok "kyverno test . exited 0"
  else
    printf '%s[fail]%s kyverno test . exited %s\n' "$R" "$Z" "$rc"
    failures=$((failures + 1))
  fi

  if [[ $failures -eq 0 ]]; then
    printf '\n%s*** LAB PASSED ***%s Suite restored, coverage intact, evidence untouched.\n' "$G" "$Z"
    say "Now make it real: run it in CI. A non-zero exit is the whole point —"
    say "'kyverno test' is the only KCA-scope tool that proves a policy behaves"
    say "as documented WITHOUT an API server. See --fail-only and --detailed-results."
    return 0
  fi

  printf '\n%s*** LAB NOT PASSED ***%s %s check(s) failed. Keep going.\n' "$R" "$Z" "$failures"
  return 1
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main() {
  local mode="setup"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)  mode="check" ;;
      --brief)  mode="brief" ;;
      --reset)  mode="setup" ;;
      --yes|-y) ASSUME_YES=1 ;;
      -h|--help)
        sed -n '1,45p' "$0"
        exit 0 ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  case "$mode" in
    check) preflight; do_check ;;
    brief) briefing ;;
    setup)
      preflight
      confirm_disposable
      build_baseline
      verify_baseline
      apply_breaks
      briefing
      ;;
  esac
}

main "$@"
exit 0

# =============================================================================
#  SOLUTION — do not read before attempting the lab
# =============================================================================
#
#  There are FOUR defects, all of them inside kyverno-test.yaml. The policy and
#  the fixtures are correct throughout; that asymmetry is the lesson. A Kyverno
#  test suite is code, and a broken suite fails in exactly three ways: it cannot
#  load its inputs, it cannot resolve its variables, or its expectations do not
#  describe reality.
#
#  -----------------------------------------------------------------------------
#  STEP 0 — reproduce, and read the failure instead of guessing
#  -----------------------------------------------------------------------------
#    cd ~/kca-lab-3.2-test
#    kyverno test . ; echo "exit=$?"
#
#  Expected (wording varies by CLI build):
#    Loading test  ( ./kyverno-test.yaml ) ...
#      Loading policies ...
#    Error: failed to load policies ... policy.yaml: no such file or directory
#    exit=1
#
#  The engine never reached the resources. Fix loading first; every later symptom
#  is invisible until the inputs resolve.
#
#  -----------------------------------------------------------------------------
#  DEFECT 1 — `policies:` points at a file that does not exist
#  -----------------------------------------------------------------------------
#  Paths in a Test manifest are resolved RELATIVE TO THE TEST FILE, not to your
#  shell's $PWD. Confirm what is actually on disk:
#
#    ls -R . | sed -n '1,40p'
#    # ./policies/deployment-standards.yaml exists; ./policy.yaml does not.
#
#  Fix — in kyverno-test.yaml:
#
#    policies:
#    -   - policy.yaml
#    +   - policies/deployment-standards.yaml
#
#  Re-run. The suite now loads and evaluates:
#    kyverno test .
#
#  -----------------------------------------------------------------------------
#  DEFECT 2 — the Value file is never referenced, so the ConfigMap variable
#             cannot be resolved
#  -----------------------------------------------------------------------------
#  Symptom, best seen with reasons expanded:
#
#    kyverno test . --detailed-results
#    # rows for rule `check-image-registry` report an error / Fail whose reason
#    # mentions variable substitution: registryConfig.data.allowed is not resolved.
#
#  Why: the rule declares
#
#      context:
#        - name: registryConfig
#          configMap:
#            name: platform-registry
#            namespace: platform-system
#
#  In a live cluster Kyverno reads that ConfigMap through the API server. The CLI
#  runs OFFLINE — there is no API server, so any context variable must be injected
#  from a Value file (kind: Value, apiVersion: cli.kyverno.io/v1alpha1). The file
#  is already sitting in the lab, unused: values.yaml. The Test manifest simply
#  never points at it.
#
#    cat values.yaml     # dotted key = the exact variable path the rule dereferences
#
#  Fix — add the `variables` key to kyverno-test.yaml (top level, next to
#  `policies:` and `resources:`):
#
#      resources:
#        - resources/deployments.yaml
#    + variables: values.yaml
#
#  Equivalent one-off from the command line, useful when debugging:
#      kyverno test . --values-file values.yaml     # (flag name varies: also seen
#                                                   #  as --values / -f in older CLIs)
#
#  Re-run: every rule now produces a clean Pass or Fail. What remains is a
#  disagreement between the suite and the engine.
#
#  -----------------------------------------------------------------------------
#  DEFECT 3 — an expectation names a rule that does not exist
#  -----------------------------------------------------------------------------
#  Symptom: a result row cannot be matched to any engine response ("not found" /
#  the test case is reported failed with no corresponding rule result).
#
#  Cross-check the names — never retype them from memory:
#
#    grep -nE '^\s+- name:' policies/deployment-standards.yaml
#    #   check-team-label
#    #   check-image-registry
#    grep -n 'rule:' kyverno-test.yaml
#    #   ... rule: check-image-registries   <-- plural; no such rule
#
#  Fix:
#    -     rule: check-image-registries
#    +     rule: check-image-registry
#
#  -----------------------------------------------------------------------------
#  DEFECT 4 — the expectation that lies: `pass` asserted for a real violation
#  -----------------------------------------------------------------------------
#  Symptom: one test case is reported failed even though the engine's verdict is
#  correct. The suite, not the policy, is wrong.
#
#  Derive the truth table from the fixtures rather than from the suite:
#
#    resource                   team label?   image registry              expected
#    -------------------------  ------------  --------------------------  ------------------------
#    good-deployment            yes           registry.internal.example…  label pass / image pass
#    no-label-deployment        NO            registry.internal.example…  label FAIL / image pass
#    bad-registry-deployment    yes           docker.io/library/nginx     label pass / image FAIL
#
#  So `no-label-deployment` MUST be expected to fail `check-team-label`. `result:
#  fail` is not a red test — it is the assertion that the policy actually blocks
#  what it claims to block. Turning it into `pass` to silence CI is how a policy
#  quietly stops enforcing anything.
#
#  Fix:
#      - policy: deployment-standards
#        rule: check-team-label
#        kind: Deployment
#        resources:
#          - no-label-deployment
#    -   result: pass
#    +   result: fail
#
#  -----------------------------------------------------------------------------
#  STEP 5 — verify
#  -----------------------------------------------------------------------------
#    kyverno test . ; echo "exit=$?"
#
#  Expected shape (formatting differs across CLI versions):
#
#    │ ID │ POLICY               │ RULE                 │ RESOURCE                                  │ RESULT │
#    │ 1  │ deployment-standards │ check-team-label     │ apps/v1/Deployment/good-deployment        │ Pass   │
#    │ 2  │ deployment-standards │ check-team-label     │ apps/v1/Deployment/bad-registry-deployment│ Pass   │
#    │ 3  │ deployment-standards │ check-team-label     │ apps/v1/Deployment/no-label-deployment     │ Pass   │
#    │ 4  │ deployment-standards │ check-image-registry │ apps/v1/Deployment/good-deployment        │ Pass   │
#    │ 5  │ deployment-standards │ check-image-registry │ apps/v1/Deployment/no-label-deployment     │ Pass   │
#    │ 6  │ deployment-standards │ check-image-registry │ apps/v1/Deployment/bad-registry-deployment│ Pass   │
#
#    Test Summary: 6 tests passed and 0 tests failed
#    exit=0
#
#  Read the RESULT column carefully: "Pass" means THE EXPECTATION HELD. Rows 3 and
#  6 show Pass because the policy correctly rejected those resources and the suite
#  said it would. The engine's verdict and the test's verdict are two different
#  columns of meaning collapsed into one word — that distinction is exam material.
#
#  Then grade:
#    ./kca-3.2-break-fix.sh --check
#
#  -----------------------------------------------------------------------------
#  TAKEAWAYS FOR THE EXAM AND FOR PRODUCTION
#  -----------------------------------------------------------------------------
#   1. `kyverno test <dir>` walks the directory recursively looking for
#      kyverno-test.yaml. Use `--file-name` to change the filename it hunts for.
#   2. Paths inside a Test manifest are relative to the manifest itself.
#   3. Any rule with a `context` (ConfigMap, APICall, ImageRegistry) needs its data
#      injected offline via a `kind: Value` file wired in with `variables:`.
#      Dotted keys map to the exact variable path the rule dereferences.
#   4. `result: fail` is a first-class, desirable expectation. A suite made only of
#      `pass` rows proves nothing about enforcement.
#   5. `--detailed-results` gives per-rule reasons; `--fail-only` trims the table in
#      CI; `--remove-color` keeps CI logs readable.
#   6. The exit code is the contract: non-zero on any failed test case. That is what
#      makes this the CI gate for policy changes, with no cluster required.
#
#  Docs: https://kyverno.io/docs/kyverno-cli/usage/test/
#        https://kyverno.io/docs/writing-policies/external-data-sources/
#        https://kyverno.io/docs/writing-policies/variables/
# =============================================================================