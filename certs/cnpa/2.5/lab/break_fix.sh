#!/usr/bin/env bash
#
# ==============================================================================
#  CNPA — Cloud Native Platform Engineering Associate (exam version 2025-04-01)
#  Domain 2 · Topic 2.5 — Security Integration in CI/CD Pipelines  (weight 4.0)
#
#  BREAK & FIX LAB  ·  run ONLY on a disposable, throwaway lab VM
# ------------------------------------------------------------------------------
#  What this lab teaches
#  ---------------------
#  A CI/CD security gate that can never fail is worse than having no gate at
#  all: it manufactures false assurance. This lab plants a hardcoded cloud
#  credential in a mock application and ships a CI pipeline whose secret-scanning
#  gate has been silently turned "fail-open" (a `|| true` bypass, the shell
#  equivalent of a CI `continue-on-error: true`). The pipeline reports GREEN and
#  promotes the artifact to deploy even though a live-looking secret is sitting
#  in the source tree. Your job is to detect the false-green, restore the gate to
#  fail-closed, and then remediate the actual finding.
#
#  This is a self-contained simulation: the "scanners" are plain grep/sed so the
#  lab runs on any box with bash, no cluster, no network, no credentials. Each
#  stage is annotated with the real production tool it stands in for (gitleaks,
#  Trivy, cosign, Kyverno) so you can map the concept to a real platform.
#
#  Official references
#  -------------------
#   - CNPA curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   - OWASP Top 10 CI/CD Security Risks: https://owasp.org/www-project-top-10-ci-cd-security-risks/
#       (CICD-SEC-1 Insufficient Flow Control, CICD-SEC-6 Insufficient Credential Hygiene)
#   - Sigstore / cosign (sign & verify): https://docs.sigstore.dev/cosign/signing/signing_with_containers/
#   - Trivy (SCA / image scanning):      https://trivy.dev/latest/docs/
#   - gitleaks (secret scanning):        https://github.com/gitleaks/gitleaks
#   - Kyverno (admission-time policy):   https://kyverno.io/policies/
#   - SLSA supply-chain framework:       https://slsa.dev/spec/v1.0/
#
#  NOTE: the planted "secret" is AWS's own public documentation placeholder
#  (AKIAIOSFODNN7EXAMPLE). It is NOT a live credential — it exists only to make
#  the secret-detector fire deterministically.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Preconditions and a safe, isolated lab directory
# ------------------------------------------------------------------------------
LAB_DIR="${CNPA_LAB_DIR:-$HOME/cnpa-lab/2.5}"

case "$LAB_DIR" in
  ""|"/"|"$HOME"|/usr|/etc|/var|/bin|/boot)
    echo "FATAL: refusing to use an unsafe CNPA_LAB_DIR ('$LAB_DIR')." >&2
    exit 1 ;;
esac

for bin in bash grep sed; do
  command -v "$bin" >/dev/null 2>&1 || { echo "FATAL: '$bin' not found in PATH." >&2; exit 1; }
done

echo "============================================================================"
echo " CNPA 2.5 — Security Integration in CI/CD Pipelines — BREAK & FIX"
echo " Lab directory : $LAB_DIR"
echo " Reset anytime : rm -rf \"$LAB_DIR\""
echo "============================================================================"

if [[ "${CNPA_LAB_ASSUME_YES:-0}" != "1" ]]; then
  read -r -p "This will (re)create the lab and break one CI security gate. Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted. Nothing changed."; exit 0; }
fi

# Idempotent: wipe and rebuild only our own isolated tree.
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/src/app" "$LAB_DIR/src/config"

# ------------------------------------------------------------------------------
# 1. Materialize the mock application repository
#    Everything here is CLEAN and policy-compliant EXCEPT the planted secret,
#    so the ONLY reason the pipeline can be green-but-wrong is the broken gate.
# ------------------------------------------------------------------------------

cat > "$LAB_DIR/src/app/main.py" <<'PYEOF'
from flask import Flask, jsonify
from config.settings import client_for_reports

app = Flask(__name__)

@app.get("/healthz")
def healthz():
    return jsonify(status="ok")

@app.get("/reports")
def reports():
    # Uses whatever credential provider config.settings hands back.
    return jsonify(items=client_for_reports().list())
PYEOF

# --- THE PLANTED FINDING: a hardcoded, long-lived cloud credential ------------
# This is exactly the anti-pattern CICD-SEC-6 (credential hygiene) warns about.
cat > "$LAB_DIR/src/config/settings.py" <<'PYEOF'
# TODO(TICKET-1147): move these to the platform secret store / OIDC before GA.
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
AWS_REGION = "us-east-1"


def client_for_reports():
    # Pretend this builds an SDK client from the module-level constants above.
    class _Stub:
        def list(self):
            return ["q1", "q2", "q3"]
    return _Stub()
PYEOF

# Clean, pinned dependencies (none on the SCA blocklist -> gate_sca passes).
cat > "$LAB_DIR/src/requirements.txt" <<'REQEOF'
flask==3.0.3
gunicorn==22.0.0
REQEOF

# Hardened Dockerfile: tagged (not :latest) and runs as a non-root USER
# (dockerfile-policy + image-scan gates pass). Production should pin by digest.
cat > "$LAB_DIR/src/Dockerfile" <<'DOCKEREOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN adduser --system --no-create-home appuser
USER appuser
EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", "app.main:app"]
DOCKEREOF

# ------------------------------------------------------------------------------
# 2. Materialize the CI security pipeline — WITH the injected defect
#    Written with a quoted heredoc so nothing is expanded: the file is literal.
#    Look for the line marked "INJECTED DEFECT" — that is what you must fix.
# ------------------------------------------------------------------------------
cat > "$LAB_DIR/ci-pipeline.sh" <<'CIEOF'
#!/usr/bin/env bash
#
# Minimal "shift-left" CI security pipeline for the CNPA 2.5 lab.
# Fail-closed by design: `set -e` means any gate that returns non-zero aborts
# the job and blocks promotion. Each gate stands in for a real tool.
#
# Usage: ci-pipeline.sh <source-dir>
set -euo pipefail

SRC="${1:?usage: ci-pipeline.sh <source-dir>}"

# --- Gate 1: secret scanning (stands in for: gitleaks / trufflehog) -----------
gate_secret_scan() {
  local src="$1" hits
  echo "▶ gate: secret-scan            (gitleaks-equivalent)"
  # Detect AWS access-key IDs, PEM private keys, and obvious inline secrets.
  hits="$(grep -REn \
    -e 'AKIA[0-9A-Z]{16}' \
    -e '-----BEGIN[ A-Z]*PRIVATE KEY-----' \
    -e '(password|passwd|secret|token)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{6,}' \
    "$src" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    echo "  ✖ hardcoded credential(s) detected:"
    echo "$hits" | sed 's/^/        /'
    return 1
  fi
  echo "  ✔ no secrets found"
}

# --- Gate 2: software composition analysis (stands in for: trivy fs / grype) --
gate_sca() {
  local src="$1" reqs="$1/requirements.txt"
  echo "▶ gate: sca / dependency-scan  (trivy-fs-equivalent)"
  local vuln='(requests==2\.19\.|flask==0\.12\.|pyyaml==(3\.|4\.|5\.[0-3])|urllib3==1\.2[0-5]\.)'
  if [[ -f "$reqs" ]] && grep -Eq "$vuln" "$reqs"; then
    echo "  ✖ known-vulnerable dependency pin:"
    grep -En "$vuln" "$reqs" | sed 's/^/        /'
    return 1
  fi
  echo "  ✔ no known-vulnerable pins"
}

# --- Gate 3: Dockerfile policy (stands in for: hadolint / conftest / OPA) ------
gate_dockerfile_policy() {
  local df="$1/Dockerfile"
  echo "▶ gate: dockerfile-policy      (conftest/OPA-equivalent)"
  if grep -Eiq '^[[:space:]]*FROM[[:space:]]+\S+:latest' "$df"; then
    echo "  ✖ base image pinned to :latest (non-reproducible)"; return 1
  fi
  if ! grep -Eq '^[[:space:]]*USER[[:space:]]+[^[:space:]]+' "$df" \
     || grep -Eiq '^[[:space:]]*USER[[:space:]]+(root|0)[[:space:]]*$' "$df"; then
    echo "  ✖ container would run as root (no non-root USER)"; return 1
  fi
  echo "  ✔ base image tagged, runs as non-root"
}

# --- Gate 4: image / build-recipe scan (stands in for: trivy image --exit-code 1)
gate_image_scan() {
  local df="$1/Dockerfile"
  echo "▶ gate: image-scan             (trivy-image-equivalent)"
  if grep -Eiq 'curl[^|]*\|[[:space:]]*(ba)?sh|--allow-unauthenticated|http://' "$df"; then
    echo "  ✖ unsafe fetch/install in build recipe"; return 1
  fi
  echo "  ✔ no unsafe fetch/install patterns"
  # Production would also require: cosign verify --key <key> <image@digest>
  # and a Kyverno/Gatekeeper admission policy verifying the signature at deploy.
}

echo "================= CI SECURITY PIPELINE ================="

# Under `set -e`, each bare call below aborts the job if the gate returns 1.
gate_secret_scan "$SRC" || true   # <== INJECTED DEFECT (fail-open bypass)
gate_sca "$SRC"
gate_dockerfile_policy "$SRC"
gate_image_scan "$SRC"

echo "======================================================="
echo "✅ ALL GATES PASSED — promoting artifact to deploy"
echo "======================================================="
CIEOF
chmod +x "$LAB_DIR/ci-pipeline.sh"

# ------------------------------------------------------------------------------
# 3. Run the pipeline once so the student sees the SYMPTOM (a false green)
# ------------------------------------------------------------------------------
echo
echo "---- Running the pipeline once to show the current behavior ----"
set +e
bash "$LAB_DIR/ci-pipeline.sh" "$LAB_DIR/src"
rc=$?
set -e
echo "---- pipeline exit code: $rc ----"

# ------------------------------------------------------------------------------
# 4. The challenge briefing
# ------------------------------------------------------------------------------
cat <<EOF

============================================================================
 SYMPTOM YOU JUST SAW
----------------------------------------------------------------------------
 The pipeline printed "ALL GATES PASSED — promoting artifact to deploy" and
 exited 0 (success) — even though the source tree contains a hardcoded AWS
 credential in src/config/settings.py. Prove the secret is really there:

     grep -RnE 'AKIA[0-9A-Z]{16}' "$LAB_DIR/src"

 A green pipeline shipping a live-looking credential is a FALSE GREEN. One of
 the security gates has been silently neutralized (fail-open), so it can report
 a finding but can no longer BLOCK the build.

 YOUR OBJECTIVE
----------------------------------------------------------------------------
   1. Diagnose WHY the pipeline is green despite the secret.
   2. Restore the pipeline to FAIL-CLOSED so the planted secret BLOCKS it:
          bash "$LAB_DIR/ci-pipeline.sh" "$LAB_DIR/src"; echo "exit=\$?"
      Success = the secret-scan gate reports the finding AND exit != 0.
   3. Remediate the actual finding so the pipeline passes for the RIGHT reason
      (no secret in source), returning exit 0 again.

 HINTS
----------------------------------------------------------------------------
   * The scanners themselves are correct. Read how each gate is *invoked* in
     $LAB_DIR/ci-pipeline.sh, near the "CI SECURITY PIPELINE" banner.
   * In a fail-closed job (\`set -e\`), what does appending \`|| true\` to a
     command do to a non-zero exit status? (cf. a CI \`continue-on-error: true\`.)
   * Map to OWASP CICD-SEC-1 (Insufficient Flow Control) and CICD-SEC-6
     (Insufficient Credential Hygiene).

 Reset the lab at any time with:  rm -rf "$LAB_DIR"
============================================================================
EOF

exit 0

# ##############################################################################
# #                                                                            #
# #                    SOLUTION — do not read until you have tried             #
# #             (step-by-step, with the exact commands and outputs)            #
# #                                                                            #
# ##############################################################################
#
# ---------------------------------------------------------------------------
# STEP 1 — Reproduce and confirm the false green
# ---------------------------------------------------------------------------
#   $ bash "$LAB_DIR/ci-pipeline.sh" "$LAB_DIR/src"; echo "exit=$?"
#   ▶ gate: secret-scan            (gitleaks-equivalent)
#     ✖ hardcoded credential(s) detected:
#           .../config/settings.py:2:AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
#   ▶ gate: sca / dependency-scan  (trivy-fs-equivalent)
#     ✔ no known-vulnerable pins
#   ▶ gate: dockerfile-policy      (conftest/OPA-equivalent)
#     ✔ base image tagged, runs as non-root
#   ▶ gate: image-scan             (trivy-image-equivalent)
#     ✔ no unsafe fetch/install patterns
#   ✅ ALL GATES PASSED — promoting artifact to deploy
#   exit=0
#
#   Key observation: the secret-scan gate DID detect and print the finding,
#   yet the job still exited 0 and "promoted to deploy". The gate can see, but
#   it can no longer stop the line. Detection without enforcement = false green.
#
#   Confirm the secret is genuinely in the tree (not a scanner artifact):
#   $ grep -RnE 'AKIA[0-9A-Z]{16}' "$LAB_DIR/src"
#   .../config/settings.py:2:AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
#
# ---------------------------------------------------------------------------
# STEP 2 — Diagnose the root cause
# ---------------------------------------------------------------------------
#   Inspect how the gates are invoked:
#   $ grep -n 'gate_' "$LAB_DIR/ci-pipeline.sh" | grep -v '()'
#   ... gate_secret_scan "$SRC" || true   # <== INJECTED DEFECT (fail-open bypass)
#   ... gate_sca "$SRC"
#   ... gate_dockerfile_policy "$SRC"
#   ... gate_image_scan "$SRC"
#
#   The pipeline runs under `set -e`, so a gate returning non-zero should abort
#   the whole job (fail-closed). But `gate_secret_scan "$SRC" || true` makes the
#   compound command ALWAYS succeed: `|| true` swallows the gate's exit code, so
#   `set -e` never trips. This is the shell equivalent of a CI/CD
#   `continue-on-error: true` bolted onto a security step — usually added as a
#   "temporary" unblock and then forgotten. It converts a blocking control into a
#   decorative one. (OWASP CICD-SEC-1: Insufficient Flow Control.)
#
# ---------------------------------------------------------------------------
# STEP 3 — Fix: restore the gate to fail-closed
# ---------------------------------------------------------------------------
#   Remove the bypass so the secret-scan gate can abort the job again:
#   $ sed -i 's/^gate_secret_scan "\$SRC" || true.*/gate_secret_scan "$SRC"/' \
#         "$LAB_DIR/ci-pipeline.sh"
#
#   Verify the line is now clean:
#   $ grep -n 'gate_secret_scan "\$SRC"' "$LAB_DIR/ci-pipeline.sh"
#   ...:gate_secret_scan "$SRC"
#
# ---------------------------------------------------------------------------
# STEP 4 — Verify the gate now BLOCKS (objective #2 met)
# ---------------------------------------------------------------------------
#   $ bash "$LAB_DIR/ci-pipeline.sh" "$LAB_DIR/src"; echo "exit=$?"
#   ▶ gate: secret-scan            (gitleaks-equivalent)
#     ✖ hardcoded credential(s) detected:
#           .../config/settings.py:2:AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
#   exit=1
#
#   The job now stops at secret-scan; the "promoting artifact to deploy" line is
#   never printed. Fail-closed behavior restored.
#
# ---------------------------------------------------------------------------
# STEP 5 — Remediate the real finding (objective #3: green for the right reason)
# ---------------------------------------------------------------------------
#   A blocking gate is only half the job — the credential must actually leave the
#   source. Replace the hardcoded constants with a runtime lookup (env var today,
#   platform secret store / OIDC-federated short-lived credentials in production):
#
#   $ cat > "$LAB_DIR/src/config/settings.py" <<'PYEOF'
#   import os
#
#   # Credentials are injected at runtime by the platform secret store / OIDC.
#   # Nothing sensitive is committed to source. See CICD-SEC-6.
#   AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID")
#   AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY")
#   AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
#
#
#   def client_for_reports():
#       class _Stub:
#           def list(self):
#               return ["q1", "q2", "q3"]
#       return _Stub()
#   PYEOF
#
#   Re-run — now it passes because there is genuinely nothing to find:
#   $ bash "$LAB_DIR/ci-pipeline.sh" "$LAB_DIR/src"; echo "exit=$?"
#   ▶ gate: secret-scan            (gitleaks-equivalent)
#     ✔ no secrets found
#   ▶ gate: sca / dependency-scan  (trivy-fs-equivalent)
#     ✔ no known-vulnerable pins
#   ▶ gate: dockerfile-policy      (conftest/OPA-equivalent)
#     ✔ base image tagged, runs as non-root
#   ▶ gate: image-scan             (trivy-image-equivalent)
#     ✔ no unsafe fetch/install patterns
#   ✅ ALL GATES PASSED — promoting artifact to deploy
#   exit=0
#
#   (If a leaked key had been real, remediation would also include REVOKING and
#   ROTATING it — a scanner finding means assume-compromised, not just delete.)
#
# ---------------------------------------------------------------------------
# STEP 6 — Why it broke, and how to keep it from recurring (production takeaways)
# ---------------------------------------------------------------------------
#   * Never attach continue-on-error / `|| true` / `--exit-code 0` to a security
#     gate. A control that cannot fail the build is telemetry, not a control.
#   * Make security gates required status checks on the protected branch so a
#     bypassed or removed gate cannot merge. Codify the pipeline itself in policy
#     (e.g. OPA/conftest over the workflow YAML) to detect `continue-on-error`
#     on security steps. (OWASP CICD-SEC-1: Insufficient Flow Control.)
#   * Defense in depth for credential hygiene: pre-commit gitleaks (catch before
#     push) + CI gitleaks/trufflehog (catch before merge) + push-protection on
#     the forge. Keep secrets out of source entirely via a secret store or
#     OIDC-federated, short-lived credentials. (CICD-SEC-6.)
#   * Extend the same fail-closed discipline across the supply chain: Trivy image
#     scan with `--exit-code 1 --severity HIGH,CRITICAL`; sign artifacts with
#     `cosign sign`, verify with `cosign verify`; generate SBOM/provenance
#     (SLSA); and enforce signature/policy at ADMISSION with Kyverno or Gatekeeper
#     so an unsigned or non-compliant image is rejected at deploy even if a
#     pipeline gate was skipped.
#
#   References:
#     OWASP Top 10 CI/CD: https://owasp.org/www-project-top-10-ci-cd-security-risks/
#     Trivy:    https://trivy.dev/latest/docs/
#     cosign:   https://docs.sigstore.dev/cosign/signing/signing_with_containers/
#     gitleaks: https://github.com/gitleaks/gitleaks
#     Kyverno:  https://kyverno.io/policies/
#     SLSA:     https://slsa.dev/spec/v1.0/
# ##############################################################################