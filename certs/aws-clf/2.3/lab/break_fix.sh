"

  head1 "Objective 2 - the pipeline can publish again"
  check     "the role uploads to builds/" upload_builds
  check     "the role can list the artifact bucket" \
            aws_lab --profile deploy s3 ls "s3://$BUCKET"

  head1 "Objective 3 - the guardrails you were not asked to remove"
  check_not "the role STILL cannot write to releases/ (boundary preserved)" \
            upload_releases
  check_not "the role STILL cannot call iam:CreateUser" \
            simulate_allows "iam:CreateUser" "arn:aws:iam::${ACCOUNT_ID}:user/newbie"
  check_not "the role STILL cannot delete the artifact bucket" \
            simulate_allows "s3:DeleteBucket" "arn:aws:s3:::$BUCKET"
  check_not "the trust policy was not opened to every principal" \
            grep -qE '"Principal"[[:space:]]*:[[:space:]]*"\*"' \
                 "$LAB_ROOT/iam/trust/LabDeployRole.json"

  head1 "Objective 4 - the audit finding"
  check     "no long-lived root credentials remain on this host" no_root_credentials

  printf '\n'
  if [ "$FAILED" -eq 0 ]; then
    printf '%sALL %d CHECKS PASSED.%s The pipeline is repaired and every guardrail survived.\n' \
           "$C_GREEN$C_BOLD" "$PASS" "$C_RESET"
    say "Read the commented solution at the bottom of this script and compare it with"
    say "what you actually did - the reasoning matters more than the diff."
    return 0
  fi
  printf '%s%d passed, %d still failing.%s  Try:  %s hint 1\n' \
         "$C_YELLOW$C_BOLD" "$PASS" "$FAILED" "$C_RESET" "$0"
  return 1
}

cmd_reset() {
  [ -f "$LAB_ROOT/$MARKER" ] || { fail "lab: nothing to reset at $LAB_ROOT"; exit 1; }
  rm -rf "$LAB_ROOT/aws" "$LAB_ROOT/iam" "$LAB_ROOT/org" "$LAB_ROOT/s3" "$LAB_ROOT/state"
  build_lab
  say "lab: sandbox reset - all four faults are back in place."
}

cmd_clean() {
  if [ -f "$LAB_ROOT/$MARKER" ]; then
    rm -rf "$LAB_ROOT"
    say "lab: removed $LAB_ROOT"
  else
    warn "lab: $LAB_ROOT is not a lab sandbox (no $MARKER marker) - refusing to delete."
    exit 1
  fi
}

case "${1:-start}" in
  start)  shift || true; cmd_start "${1:-}" ;;
  shell)  cmd_shell ;;
  verify) cmd_verify ;;
  hint)   shift || true; cmd_hint "${1:-1}" ;;
  reset)  cmd_reset ;;
  clean)  cmd_clean ;;
  brief)  cat "$LAB_ROOT/BRIEF.txt" ;;
  *)      say "usage: $0 {start|shell|verify|hint N|reset|clean|brief}"; exit 1 ;;
esac

# ==============================================================================
#  SOLUTION - do not read this until 'verify' has beaten you at least twice.
# ==============================================================================
#
#  The four faults map to four different access-management primitives. That is
#  the point of the exercise: "AccessDenied" is not one problem, it is a family
#  of problems, and each member is diagnosed with a different tool.
#
#  ---------------------------------------------------------------------------
#  STEP 0 - enter the lab and reproduce
#  ---------------------------------------------------------------------------
#      source ~/aws-clf-lab-2.3/env.sh
#      aws --profile deploy sts get-caller-identity
#
#      The config profile (ci-runner) could not be found
#
#  Read it literally. This is a CLIENT-side error (exit 255), not a service
#  error. Nothing was ever sent to AWS. The CLI could not build a credential
#  chain, so IAM never got a chance to say yes or no. Always separate "the call
#  never happened" from "the call happened and was denied".
#
#  ---------------------------------------------------------------------------
#  FAULT 1 - the profile chain is broken (source_profile)
#  ---------------------------------------------------------------------------
#  Diagnose:
#      aws configure list-profiles
#          auditor
#          ci
#          default
#          deploy
#      grep -A6 'profile deploy' "$AWS_CONFIG_FILE"
#
#  "deploy" declares role_arn + source_profile = ci-runner, and there is no
#  ci-runner profile. A role-assuming profile is a two-link chain:
#      source_profile  -> the long-lived identity that CALLS sts:AssumeRole
#      role_arn        -> the identity you END UP as, with temporary credentials
#
#  Fix - edit $AWS_CONFIG_FILE, section [profile deploy]:
#      -source_profile = ci-runner
#      +source_profile = ci
#
#  ---------------------------------------------------------------------------
#  FAULT 2 - the trust policy names a principal that no longer exists
#  ---------------------------------------------------------------------------
#  Re-run and the error changes shape - which is progress:
#      aws --profile deploy sts get-caller-identity
#      An error occurred (AccessDenied) when calling the AssumeRole operation:
#      User: arn:aws:iam::123456789012:user/ci is not authorized to perform:
#      sts:AssumeRole on resource: arn:aws:iam::123456789012:role/LabDeployRole
#
#  Now the call really was evaluated, and it was refused. Two policies decide an
#  AssumeRole and you must inspect both:
#      the caller's identity policy   -> "may ci call sts:AssumeRole?"
#      the role's TRUST policy        -> "does the role accept ci?"
#  In the same account, the trust policy alone is sufficient to grant it; the
#  identity policy is required for the cross-account case. Here the identity
#  policy (CiBaselinePolicy, Sid AssumeTheDeploymentRole) is fine, so look at
#  the role:
#
#      aws --profile ci iam get-role --role-name LabDeployRole
#
#      "Principal": { "AWS": "arn:aws:iam::123456789012:user/ci-runner-legacy" }
#
#  That user was deleted. Note a real-world detail this simulator does not
#  reproduce: when you delete a principal that a trust policy names, AWS
#  rewrites the Principal to an opaque unique ID such as "AIDAJQABLZS4A3QDU576Q"
#  because ARNs are re-usable and a recreated user must not silently inherit the
#  old trust. Seeing that string in a trust policy means exactly this fault.
#
#  Fix - edit iam/trust/LabDeployRole.json:
#      -"AWS": "arn:aws:iam::123456789012:user/ci-runner-legacy"
#      +"AWS": "arn:aws:iam::123456789012:user/ci"
#
#  In production this is:
#      aws iam update-assume-role-policy \
#          --role-name LabDeployRole \
#          --policy-document file://trust-policy.json
#
#  ---------------------------------------------------------------------------
#  FAULT 3 - the trust policy demands MFA that the profile cannot supply
#  ---------------------------------------------------------------------------
#  Same AccessDenied again. This is where people start deleting things. Do not.
#  The trust policy carries a second clause:
#
#      "Condition": {
#        "Bool":         { "aws:MultiFactorAuthPresent": "true" },
#        "NumericLessThan": { "aws:MultiFactorAuthAge": "3600" }
#      }
#
#  A condition key with no value never matches. The ci user HAS an MFA device:
#      aws --profile ci iam list-mfa-devices --user-name ci
#          "SerialNumber": "arn:aws:iam::123456789012:mfa/ci"
#  ...but the deploy profile never asks for a token code, so the STS session
#  carries aws:MultiFactorAuthPresent = false. Prove it in isolation by
#  simulating with and without the context key:
#
#      aws --profile ci iam simulate-principal-policy \
#          --policy-source-arn arn:aws:iam::123456789012:role/LabDeployRole \
#          --action-names s3:PutObject \
#          --resource-arns arn:aws:s3:::lab-artifacts-123456789012/builds/x \
#          --context-entries ContextKeyName=aws:MultiFactorAuthPresent,ContextKeyValues=true,ContextKeyType=boolean
#
#  Fix - add the MFA serial to [profile deploy] in $AWS_CONFIG_FILE:
#      +mfa_serial = arn:aws:iam::123456789012:mfa/ci
#
#  The CLI now prompts "Enter MFA code for arn:aws:iam::123456789012:mfa/ci:"
#  and passes it to sts:AssumeRole. Any six digits work here; export
#  AWS_LAB_MFA_CODE=123456 to run it unattended.
#
#      aws --profile deploy sts get-caller-identity
#      {
#          "UserId": "AROAJ2EXAMPLEROLEID1:ci-pipeline",
#          "Account": "123456789012",
#          "Arn": "arn:aws:sts::123456789012:assumed-role/LabDeployRole/ci-pipeline"
#      }
#
#  The ARN changed identity class: you are no longer user/ci, you are an
#  assumed-role session with TEMPORARY credentials. That is the whole point of
#  a role, and it is the CLF-level answer to "how should an application get
#  permissions in AWS" - a role, never an embedded access key.
#
#  ---------------------------------------------------------------------------
#  FAULT 4 - an explicit Deny in the permissions boundary
#  ---------------------------------------------------------------------------
#      echo "build $(date +%s)" > /tmp/artifact.txt
#      aws --profile deploy s3 cp /tmp/artifact.txt s3://lab-artifacts-123456789012/builds/artifact.txt
#
#      upload failed: ... An error occurred (AccessDenied) when calling the
#      PutObject operation: Access Denied
#
#  S3 gives you nothing. Four policies could be responsible - the SCP, the
#  bucket policy, the boundary, the identity policy - so ask IAM which one:
#
#      aws --profile ci iam simulate-principal-policy \
#          --policy-source-arn arn:aws:iam::123456789012:role/LabDeployRole \
#          --action-names s3:PutObject \
#          --resource-arns arn:aws:s3:::lab-artifacts-123456789012/builds/artifact.txt
#
#      "EvalDecision": "explicitDeny",
#      "MatchedStatements": [
#          { "SourcePolicyId": "DeployBoundary",
#            "SourcePolicyType": "Permissions Boundary",
#            "Sid": "ProtectImmutableArtifacts" } ],
#      "PermissionsBoundaryDecisionDetail": { "AllowedByPermissionsBoundary": false },
#      "OrganizationsDecisionDetail": { "AllowedByOrganizations": true }
#
#  Note that you ran the simulation as the ci USER, about the ROLE. The role
#  itself cannot run it - its boundary denies iam:* - which is correct design:
#  the principal that debugs permissions is not the principal that deploys.
#
#  Read the offending statement:
#      { "Sid": "ProtectImmutableArtifacts", "Effect": "Deny",
#        "Action": "s3:*", "Resource": "arn:aws:s3:::lab-artifacts-123456789012/*" }
#
#  It was meant to freeze published releases. As written it freezes the entire
#  bucket. Explicit Deny beats every Allow, everywhere, always - the identity
#  policy's WriteBuildArtifacts Allow and the bucket policy's AllowDeploymentRole
#  Allow are both irrelevant once this matches.
#
#  Fix - edit iam/boundaries/DeployBoundary.json, narrow the Resource:
#      -"Resource": "arn:aws:s3:::lab-artifacts-123456789012/*"
#      +"Resource": "arn:aws:s3:::lab-artifacts-123456789012/releases/*"
#
#  WRONG FIXES the grader catches, and why they are wrong:
#    * deleting the ProtectImmutableArtifacts statement -> releases/ becomes
#      writable; you turned an outage into a supply-chain problem.
#    * adding "s3:*" on "*" to DeployArtifactsPolicy -> the boundary still
#      denies, so it does not even work, and now the role is over-permissioned
#      the moment someone loosens the ceiling.
#    * "Principal": "*" in the trust policy -> anyone in any account may assume
#      your deployment role. Never write this in a trust policy.
#
#  Verify:
#      aws --profile deploy s3 cp /tmp/artifact.txt s3://lab-artifacts-123456789012/builds/artifact.txt
#      upload: /tmp/artifact.txt to s3://lab-artifacts-123456789012/builds/artifact.txt
#
#      aws --profile deploy s3 cp /tmp/artifact.txt s3://lab-artifacts-123456789012/releases/x.txt
#      upload failed: ... Access Denied          <- correct, the guardrail holds
#
#  ---------------------------------------------------------------------------
#  FAULT 5 - the finding that is not an outage: root credentials on the host
#  ---------------------------------------------------------------------------
#  Nothing is broken here, which is precisely why it survives. Find it the way
#  an auditor does:
#
#      aws --profile auditor iam generate-credential-report
#      aws --profile auditor iam get-credential-report --output text \
#          --query Content | base64 --decode
#
#      <root_account>,arn:aws:iam::123456789012:root,...,mfa_active=false,
#      access_key_1_active=true
#
#  Two findings in one row: the root user has an ACTIVE access key, and it has
#  no MFA. And someone copied that key onto this build host:
#
#      grep -n '\[root\]' "$AWS_SHARED_CREDENTIALS_FILE"
#
#  Fix here - remove the [root] profile block (all three lines) from
#  $AWS_SHARED_CREDENTIALS_FILE. Getting the credential off the host is the
#  first move, but it is not the remediation; the key still exists in AWS.
#
#  The real remediation, in order:
#    1. Sign in as the root user (or use centralized root access management in
#       AWS Organizations) and DELETE the root access keys. There is no IAM API
#       that manages root's keys for you - by design.
#    2. Enable MFA on the root user; prefer a hardware or passkey device.
#    3. Rotate anything that key could have touched and search CloudTrail for
#       its use.
#    4. Stop the recurrence: root is for the handful of tasks that require it
#       (closing the account, changing the account name or email, some support
#       plan changes). Day-to-day access should be human identities in IAM
#       Identity Center with short-lived credentials, and workloads should use
#       roles - the same lesson Fault 3 taught, one level up.
#       https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html
#       https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
#
#  Bonus finding, ungraded: the account password policy in this lab allows
#  6-character lowercase passwords with no expiry
#  (aws --profile auditor iam get-account-password-policy). Tightening it is
#  another CLF 2.3 capability - account-level password policy, distinct from
#  per-user permissions.
#
#  ---------------------------------------------------------------------------
#  WHAT TO CARRY INTO THE EXAM, AND INTO PRODUCTION
#  ---------------------------------------------------------------------------
#  * The evaluation order is not trivia, it is the debugging algorithm:
#      explicit Deny anywhere  ->  SCP must allow  ->  resource policy /
#      permissions boundary must allow  ->  identity policy must allow  ->
#      otherwise implicit Deny. Default is always deny.
#  * A permissions boundary and an SCP GRANT NOTHING. They are ceilings. The
#    effective permission is the intersection of every applicable policy.
#  * Roles + temporary credentials beat long-lived access keys, every time. An
#    access key in a file is a credential with no expiry and no accountability.
#  * MFA is enforceable as a CONDITION, not just as a login preference:
#    aws:MultiFactorAuthPresent / aws:MultiFactorAuthAge in a trust policy is
#    how "you may deploy, but only from an MFA-authenticated session" is written.
#  * The data plane will not explain a denial. iam:SimulatePrincipalPolicy,
#    CloudTrail and the policy documents will.
#  * Least privilege is a repair constraint, not a nice-to-have: a fix that
#    makes the error disappear by widening a policy is a regression that no
#    alarm will ever fire on.
# ==============================================================================