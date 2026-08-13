# KCA — Topic 3.2: `kyverno test`

**Domain 3 — Kyverno CLI · Exam weight: 3.0%**

Guided exercises. Every step is executed on your workstation; **no Kubernetes cluster and no kubeconfig are required at any point**. That is the defining property of `kyverno test`: it is an offline, deterministic, exit-code-driven assertion runner for Kyverno policies — the same class of tool as `go test` or `helm unittest`, not a cluster operation.

> **Version drift.** These exercises target Kyverno CLI **1.13.x** (`Test` manifests in `cli.kyverno.io/v1alpha1`). Column headers and log wording in CLI output changed slightly across 1.10 → 1.14; treat the printed blocks below as representative shapes, and confirm flags for *your* binary with `kyverno test --help`. Where a field or apiVersion changed between releases, it is called out inline.

---

## Exercise 0 — Prepare the offline lab

1. Install the CLI (pick one):

```bash
# Option A — krew
kubectl krew install kyverno

# Option B — release tarball (pin the version you intend to certify against)
VERSION=$(curl -s https://api.github.com/repos/kyverno/kyverno/releases/latest | grep -oP '"tag_name": "\K[^"]+')
curl -sLO "https://github.com/kyverno/kyverno/releases/download/${VERSION}/kyverno-cli_${VERSION}_linux_x86_64.tar.gz"
tar -xzf "kyverno-cli_${VERSION}_linux_x86_64.tar.gz" kyverno
sudo install -m 0755 kyverno /usr/local/bin/kyverno

# Option C — Homebrew
brew install kyverno
```

2. Confirm the binary and record the version — the exam environment pins one:

```bash
kyverno version
```

```
Version: 1.13.4
Time: 2025-02-19T10:41:22Z
Git commit ID: 9f2a1c3b...
```

3. Prove the subcommand is cluster-independent by breaking your kubeconfig for the shell:

```bash
export KUBECONFIG=/nonexistent
kyverno test --help
```

```
Usage:
  kyverno test [local folder or git repository]... [flags]

Flags:
      --detailed-results          If passed, display detailed results
      --fail-only                 If set, display all resources of failed policies only
  -f, --file-name string          Test filename (default "kyverno-test.yaml")
  -b, --git-branch string         test git repository branch
  -h, --help                      help for test
      --registry                  If set to true, access the image registry using local docker credentials
      --remove-color              Remove any color from output
  -t, --test-case-selector string run some specific test cases (default "policy=*,rule=*,resource=*")
```

4. Create the lab tree:

```bash
mkdir -p ~/kca-3.2-lab/require-labels && cd ~/kca-3.2-lab/require-labels
```

**Questions**

- **Q1.** `kyverno test --help` printed normally with `KUBECONFIG=/nonexistent`. What does that tell you about where the policy engine runs, and what practical consequence does it have for CI pipelines?
- **Q2.** Which single flag in the help output introduces an external network dependency, and why does that matter for a hermetic pipeline?
- **Q3.** The usage line accepts *"local folder or git repository"*. What file does the CLI look for when you hand it a folder?

---

## Exercise 1 — Anatomy of a `Test` manifest: the first green run

1. Write the policy under test, `policy.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce   # 1.12+ also supports per-rule spec.rules[].validate.failureAction
  background: true
  rules:
    - name: check-for-labels
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "The label `app.kubernetes.io/name` is required."
        pattern:
          metadata:
            labels:
              app.kubernetes.io/name: "?*"
```

2. Write the fixtures, `resources.yaml` — one compliant, one not:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-label
  namespace: default
  labels:
    app.kubernetes.io/name: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27.4
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-without-label
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.4
```

3. Write the test declaration, `kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-labels
policies:
  - policy.yaml
resources:
  - resources.yaml
results:
  - policy: require-labels
    rule: check-for-labels
    kind: Pod
    resources:
      - pod-with-label
    result: pass
  - policy: require-labels
    rule: check-for-labels
    kind: Pod
    resources:
      - pod-without-label
    result: fail
```

4. Run it and inspect the exit code:

```bash
kyverno test .
echo "exit=$?"
```

```
Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ ID │ POLICY         │ RULE             │ RESOURCE                         │ RESULT │
│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ 1  │ require-labels │ check-for-labels │ v1/Pod/default/pod-with-label    │ Pass   │
│ 2  │ require-labels │ check-for-labels │ v1/Pod/default/pod-without-label │ Pass   │
│────│────────────────│──────────────────│──────────────────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed

exit=0
```

**Questions**

- **Q4.** Row 2 asserts `result: fail`, yet the `RESULT` column prints `Pass`. Explain precisely what the `RESULT` column measures. Why is confusing these two the single most common misreading of `kyverno test` output?
- **Q5.** `policies:` and `resources:` contain `policy.yaml` and `resources.yaml`. Relative to which directory are those paths resolved — your shell's CWD, or something else? Prove it by running `kyverno test ~/kca-3.2-lab/require-labels` from `/tmp`.
- **Q6.** `results[].resources` is a list. What does that let you express that one entry per resource cannot, and what is the older, now-deprecated singular field it replaced?
- **Q7.** You deleted `rule: check-for-labels` from both result entries. Would the test still be a valid assertion? What is the risk of omitting it in a multi-rule policy?

---

## Exercise 2 — Reading a real failure, and the flags that shorten the read

1. Break the expectation deliberately — flip the second entry to `pass`:

```bash
sed -i '0,/result: fail/! s/result: fail/result: pass/' kyverno-test.yaml
grep -n "result:" kyverno-test.yaml
```

2. Re-run and capture the exit code:

```bash
kyverno test . ; echo "exit=$?"
```

```
│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ ID │ POLICY         │ RULE             │ RESOURCE                         │ RESULT │
│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ 1  │ require-labels │ check-for-labels │ v1/Pod/default/pod-with-label    │ Pass   │
│ 2  │ require-labels │ check-for-labels │ v1/Pod/default/pod-without-label │ Fail   │
│────│────────────────│──────────────────│──────────────────────────────────│────────│

Test Summary: 1 tests passed and 1 tests failed

exit=1
```

3. Ask for the reason and for failures only:

```bash
kyverno test . --detailed-results
kyverno test . --fail-only
```

The detailed table adds a `REASON` column carrying the expectation mismatch (`Want pass, got fail`) and the rule's validation message.

4. Produce output safe for a log collector:

```bash
kyverno test . --remove-color --detailed-results 2>&1 | tee /tmp/kca-test.log
echo "exit=${PIPESTATUS[0]}"
```

5. Restore the correct expectation before continuing:

```bash
sed -i '0,/result: pass/! s/result: pass/result: fail/' kyverno-test.yaml
kyverno test . && echo "green"
```

**Questions**

- **Q8.** Step 4 reads `${PIPESTATUS[0]}` instead of `$?`. What failure mode of CI pipelines does that avoid?
- **Q9.** Your pipeline runs `kyverno test ./policies/` over 200 policies and one assertion regresses. Which two flags do you add to make the CI log actionable, and what does each contribute?
- **Q10.** A colleague proposes gating the pipeline on `grep -q "0 tests failed"` instead of the exit code. Give two reasons that is a worse gate.

---

## Exercise 3 — The result vocabulary: `pass`, `fail`, `skip`, `error`

The `result` field is not free text. It is a policy-report outcome, and choosing the wrong one is a test bug even when the policy is correct.

1. Add a second, precondition-gated rule to `policy.yaml`:

```yaml
    - name: backend-needs-owner
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.tier || '' }}"
            operator: Equals
            value: backend
      validate:
        message: "Backend Pods must carry the annotation corp.io/owner."
        pattern:
          metadata:
            annotations:
              corp.io/owner: "?*"
```

2. Add a third rule that references a variable with **no** fallback:

```yaml
    - name: owner-must-be-a-team
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "corp.io/owner must end in -team."
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.annotations.\"corp.io/owner\" }}"
                operator: NotEquals
                value: "*-team"
```

3. Extend `kyverno-test.yaml` with expectations for both new rules against `pod-with-label` (which has neither `tier: backend` nor the annotation):

```yaml
  - policy: require-labels
    rule: backend-needs-owner
    kind: Pod
    resources:
      - pod-with-label
    result: skip
  - policy: require-labels
    rule: owner-must-be-a-team
    kind: Pod
    resources:
      - pod-with-label
    result: error
```

4. Run and confirm both rows print `Pass`:

```bash
kyverno test . --detailed-results
```

5. Now give `pod-with-label` the label `tier: backend` in `resources.yaml`, leave the annotation absent, re-run, and observe how the `backend-needs-owner` expectation must change.

**Questions**

- **Q11.** Distinguish `skip` from `fail` in one sentence each, in terms of what the engine actually did.
- **Q12.** Rule `owner-must-be-a-team` yields `error`, not `fail`, for a Pod without that annotation. What happened inside the engine, and what one edit to the rule turns the `error` into a deterministic `pass`/`fail`?
- **Q13.** Why is a rule that produces `error` in the CLI a production incident waiting to happen, given a policy with `validationFailureAction: Enforce`? Consider Kyverno's `failurePolicy` on the admission webhook.
- **Q14.** After step 5, what is the correct expectation for `backend-needs-owner` against `pod-with-label`, and why?
- **Q15.** Does changing `validationFailureAction` from `Enforce` to `Audit` change the `result` value you must write in the test? Justify.

---

## Exercise 4 — Auto-generated rules: the autogen trap

Kyverno auto-generates Pod-controller variants of Pod rules. Those variants have **different rule names**, and the test must reference the generated name.

1. Append a Deployment fixture to `resources.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-without-label
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27.4
```

2. Add the *naive* expectation and watch it fail:

```yaml
  - policy: require-labels
    rule: check-for-labels
    kind: Deployment
    resources:
      - deploy-without-label
    result: fail
```

```bash
kyverno test . --detailed-results
```

```
│ 5  │ require-labels │ check-for-labels │ apps/v1/Deployment/default/deploy-without-label │ Fail │ Not found │
Test Summary: 4 tests passed and 1 tests failed
```

3. Fix it by naming the auto-generated rule:

```yaml
    rule: autogen-check-for-labels
```

4. Re-run; the row now passes. Inspect what Kyverno actually generated:

```bash
kyverno apply policy.yaml --resource resources.yaml --policy-report | head -40
```

**Questions**

- **Q16.** For a rule named `check-for-labels` matching `Pod`, what rule names does autogen produce for a `Deployment` and for a `CronJob`?
- **Q17.** The failure reason was `Not found` rather than a result mismatch. What does that reason mean, and name the three most common causes.
- **Q18.** Which annotation on the policy controls autogen behaviour, and what value disables it entirely? What would that do to the expectations you just wrote?
- **Q19.** Your policy matches `Pod` only, yet a `Deployment` fixture is exercised. Why is testing the controller variant — not only the bare Pod — non-negotiable for a production policy?

---

## Exercise 5 — Variables, `globalValues`, and user info

Policies that reference `request.operation`, `request.userInfo`, namespace labels, or external context cannot be evaluated from the resource manifest alone. The `variables:` file supplies them.

1. Create `values.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
spec:
  globalValues:
    request.operation: CREATE
  namespaceSelector:
    - name: default
      labels:
        env: sandbox
  policies:
    - name: require-labels
      resources:
        - name: pod-with-label
          values:
            corp.io/costcenter: "cc-4471"
```

2. Reference it from the test manifest:

```yaml
variables: values.yaml
```

3. Create `userinfo.yaml` for rules that gate on the requesting identity:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: UserInfo
metadata:
  name: user-info
clusterRoles:
  - cluster-admin
userInfo:
  username: sre@corp.io
  groups:
    - system:authenticated
    - platform-sre
```

4. Reference it too, and re-run:

```yaml
userinfo: userinfo.yaml
```

```bash
kyverno test . --detailed-results
```

5. Flip `request.operation` to `UPDATE` in `globalValues` and re-run. Note which rows change.

**Questions**

- **Q20.** What is the default value of `request.operation` when no variables file is supplied, and why does that default make some rules silently untested?
- **Q21.** Distinguish `spec.globalValues` from `spec.policies[].resources[].values`. When is the per-resource form mandatory rather than merely tidy?
- **Q22.** Your policy uses `preconditions` on `{{ request.userInfo.groups }}`. You run the test without a `userinfo:` file. Which of `pass`/`fail`/`skip`/`error` do you expect, and why?
- **Q23.** `namespaceSelector` in the values file supplies labels for a namespace that does not exist in `resources:`. Why does the CLI need this, and what runtime Kyverno behaviour is it emulating?
- **Q24.** A rule calls an APICall context entry against the live cluster. Can `kyverno test` evaluate it faithfully? What is the supported way to test such a rule offline?

---

## Exercise 6 — Mutate rules: `patchedResource`, generated not hand-written

1. New directory and policy, `~/kca-3.2-lab/add-owner/policy.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-owner-annotation
spec:
  rules:
    - name: add-annotation
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              corp.io/owner: platform-team
```

2. Fixture `resource.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-unowned
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.4
```

3. **Generate** the expected output instead of typing it:

```bash
mkdir -p patched
kyverno apply policy.yaml --resource resource.yaml -o patched/
cat patched/*.yaml
```

4. Wire it into `kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: add-owner-annotation
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: add-owner-annotation
    rule: add-annotation
    kind: Pod
    resources:
      - pod-unowned
    patchedResource: patched/pod-unowned.yaml
    result: pass
```

5. Run it, then corrupt the expectation (change `platform-team` to `platform-teams` inside the patched file) and run again to see the diff the CLI prints:

```bash
kyverno test .
sed -i 's/platform-team$/platform-teams/' patched/pod-unowned.yaml
kyverno test . --detailed-results
```

**Questions**

- **Q25.** Why is `result: pass` correct here even though nothing was "validated"? What does `pass` mean for a mutate rule?
- **Q26.** You hand-write `patchedResource` and the test fails despite the annotation being present and correct. List three invisible differences that commonly cause this.
- **Q27.** What is the expected result — and what goes in `patchedResource` — for a Pod the mutate rule does **not** match?
- **Q28.** Which field replaces `patchedResource` when the policy is a `mutate` on **existing** resources (`mutate.targets`), and what must the test also declare?

---

## Exercise 7 — Generate rules and clone sources

1. `~/kca-3.2-lab/gen-netpol/policy.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-networkpolicy
spec:
  rules:
    - name: default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

2. Trigger fixture `resource.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
```

3. Expected downstream object `expected-netpol.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: team-alpha
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

4. Test manifest:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: add-networkpolicy
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: add-networkpolicy
    rule: default-deny
    kind: Namespace
    resources:
      - team-alpha
    generatedResource: expected-netpol.yaml
    result: pass
```

5. Run it:

```bash
kyverno test . --detailed-results
```

**Questions**

- **Q29.** The trigger is a `Namespace` but the asserted object is a `NetworkPolicy`. Which one goes in `results[].kind` and `results[].resources`, and which one goes in `generatedResource`?
- **Q30.** Rewrite the rule to use `generate.clone` from a source Secret in namespace `platform`. Which extra field must the test declare, and what must appear in `resources:`?
- **Q31.** `synchronize: true` is set. Is that behaviour exercised by `kyverno test`? What class of generate bug can this subcommand therefore never catch?

---

## Exercise 8 — PolicyException produces `skip`

1. Return to the `require-labels` directory and add `exception.yaml`:

```yaml
apiVersion: kyverno.io/v2        # kyverno.io/v2beta1 on Kyverno < 1.13
kind: PolicyException
metadata:
  name: allow-legacy-pod
  namespace: kyverno
spec:
  exceptions:
    - policyName: require-labels
      ruleNames:
        - check-for-labels
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - default
          names:
            - pod-without-label
```

2. Register it in the test manifest and change the affected expectation:

```yaml
exceptions:
  - exception.yaml
```

```yaml
  - policy: require-labels
    rule: check-for-labels
    kind: Pod
    resources:
      - pod-without-label
    result: skip     # was: fail
```

3. Run:

```bash
kyverno test . --detailed-results
```

4. Delete the `names:` constraint from the exception, re-run, and observe the blast radius.

**Questions**

- **Q32.** Why is the excluded resource reported as `skip` rather than `pass`? What would be lost operationally if it reported `pass`?
- **Q33.** An exception is merged into the repo. Which *two* tests should the reviewer demand in the same pull request?
- **Q34.** After step 4, the exception matches every Pod in `default`. Which assertion in your suite fails, and why is that failure the exception mechanism's most important safety property?

---

## Exercise 9 — Selecting cases, remote repositories, and CI wiring

1. Move the test into the conventional location and fix the relative paths:

```bash
cd ~/kca-3.2-lab/require-labels
mkdir -p .kyverno-test
git mv kyverno-test.yaml .kyverno-test/ 2>/dev/null || mv kyverno-test.yaml .kyverno-test/
sed -i 's|- policy.yaml|- ../policy.yaml|; s|- resources.yaml|- ../resources.yaml|; s|- exception.yaml|- ../exception.yaml|; s|variables: values.yaml|variables: ../values.yaml|; s|userinfo: userinfo.yaml|userinfo: ../userinfo.yaml|' .kyverno-test/kyverno-test.yaml
```

2. Run the whole lab recursively from the root:

```bash
cd ~/kca-3.2-lab && kyverno test .
```

3. Run one case only:

```bash
kyverno test . -t "policy=require-labels,rule=check-for-labels,resource=pod-without-label"
kyverno test . -t "policy=add-owner-annotation"
```

4. Run a differently named file:

```bash
cp .kyverno-test/kyverno-test.yaml /tmp/smoke.yaml 2>/dev/null || true
kyverno test require-labels/.kyverno-test -f kyverno-test.yaml
```

5. Run the upstream corpus straight from GitHub:

```bash
kyverno test https://github.com/kyverno/policies/pod-security --git-branch main
```

6. Wire the gate:

```makefile
.PHONY: policy-test
policy-test:
	kyverno test ./policies --remove-color --detailed-results
```

```yaml
# .github/workflows/policy.yaml
name: policy
on: [pull_request]
jobs:
  kyverno-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: kyverno/action-install-cli@v0.2.0
      - run: kyverno test ./policies --remove-color --detailed-results
```

**Questions**

- **Q35.** Why did step 1's `sed` on the paths matter? State the path-resolution rule in one sentence.
- **Q36.** `kyverno test .` walked the tree and found three suites. What is the exact filename it searched for, and what happens to a suite named `tests.yaml`?
- **Q37.** The selector `-t "policy=add-owner-annotation"` ran a subset. What is the danger of leaving a selector in a CI invocation?
- **Q38.** The CI job pins the CLI via an action but the cluster runs Kyverno 1.11. What silent class of false-green does that mismatch create?
- **Q39.** Where in the CNCF/Kyverno release process does the git-repository target become useful? Give one concrete workflow.

---

## Exercise 10 — Troubleshooting drill

Break each item, run `kyverno test . --detailed-results`, record the symptom, then repair it.

1. Change `apiVersion` in `kyverno-test.yaml` to `cli.kyverno.io/v1`.
2. Change `kind: Pod` to `kind: pod` in one result entry.
3. Rename a fixture in `resources.yaml` but not in the test's `resources:` list.
4. Point `policies:` at a file that does not exist.
5. Put two policies in `policy.yaml` with the same `metadata.name`.
6. Remove `result:` from one entry entirely.
7. Add a result entry for a rule name that the policy does not define.

**Questions**

- **Q40.** Which of the seven break the *loader* (nothing is evaluated at all) and which produce a per-row `Fail`? Why does the distinction matter when triaging a red pipeline?
- **Q41.** Cases 2, 3 and 7 all surface as the same reason string. What is it, and what is the fastest command to find out which of the three you are looking at?
- **Q42.** What is the exit code in the loader-failure cases, and what does that imply about a CI gate that only checks the exit code?

---

## Field and flag reference

| Test manifest field | Purpose |
|---|---|
| `policies` | Policy manifests to load (paths relative to the test file) |
| `resources` | Candidate resources the policies are applied to |
| `variables` | `kind: Value` file — `globalValues`, per-resource values, `namespaceSelector`, `subresources` |
| `userinfo` | `kind: UserInfo` file — `userInfo`, `roles`, `clusterRoles` |
| `exceptions` | `PolicyException` manifests to load |
| `results[].policy` / `.rule` / `.kind` / `.resources` | Selects the report entry being asserted |
| `results[].result` | Expected outcome: `pass`, `fail`, `skip`, `error`, `warn` |
| `results[].patchedResource` | Expected post-mutation object |
| `results[].generatedResource` | Expected downstream object of a generate rule |
| `results[].cloneSourceResource` | Source object for `generate.clone` |
| `results[].isValidatingAdmissionPolicy` | Assert against a Kyverno-generated ValidatingAdmissionPolicy |

| Flag | Use |
|---|---|
| `-f, --file-name` | Non-default test filename |
| `-t, --test-case-selector` | Run a subset by policy/rule/resource |
| `--fail-only` | Print only failing rows |
| `--detailed-results` | Add the `REASON` column |
| `--remove-color` | ANSI-free output for logs |
| `-b, --git-branch` | Branch when the target is a git URL |
| `--registry` | Allow registry access using local Docker credentials |

---

## Answer key

<details>
<summary><strong>Show answers (Q1–Q42)</strong></summary>

**Q1.** The Kyverno engine is vendored *into the CLI binary*: policies are evaluated in-process against YAML on disk, with no API server, no admission webhook and no Kyverno controller involved. Consequences for CI: no cluster to provision, no credentials to inject, no flakiness from cluster state, and the job can run on a pull request before anything is deployed. It also means the test proves only what the engine computes locally — not that the webhook is registered, reachable, or configured with the same `failurePolicy`.

**Q2.** `--registry`. It makes the CLI reach out to image registries using local Docker credentials to populate image data (used by `verifyImages` rules and `imageData` context entries). That turns a hermetic, deterministic test into one that depends on network reachability, registry availability, rate limits and credential expiry. Keep it off by default; isolate registry-dependent suites into a separate, clearly-labelled job.

**Q3.** `kyverno-test.yaml` (a `kyverno-test.yml` variant is also accepted). Directory targets are walked **recursively**, and every file with that name is loaded as a suite. Any other filename requires `-f/--file-name`.

**Q4.** `RESULT` is the **assertion** outcome, not the policy outcome: `Pass` means *the actual engine result equalled the expected result you declared*. Row 2 declared `result: fail` (the Pod is genuinely non-compliant) and the engine indeed produced `fail`, so the assertion passed. The misreading is common because the same two words — pass/fail — name two different layers; a suite full of `Pass` rows can be asserting that every policy fails.

**Q5.** Paths are resolved **relative to the test manifest's own directory**, never relative to your shell's CWD. Running `kyverno test ~/kca-3.2-lab/require-labels` from `/tmp` produces identical output, which is exactly why suites can live in a `.kyverno-test/` subdirectory and reference `../policy.yaml`.

**Q6.** It lets one entry assert the same `policy`/`rule`/`kind`/`result` tuple across many resources — the natural shape for "these eight Pods all violate the rule". The deprecated singular field is `resource:`; it still parses in current releases but should not be used in new material.

**Q7.** It would still run, but the assertion becomes ambiguous: with several rules in one policy the CLI cannot tell which rule's report entry you meant, so you can get a false green when the *wrong* rule produced the expected outcome, or spurious mismatches. Always pin `rule:`.

**Q8.** `$?` after a pipeline returns the exit status of the **last** command in the pipeline — `tee`, which practically always exits 0. Piping a test run through `tee` therefore converts a failing suite into a green job. `${PIPESTATUS[0]}` recovers the real status of `kyverno test`. (Equivalently: `set -o pipefail`.)

**Q9.** `--fail-only` collapses 200 policies' worth of green rows down to the regression, and `--detailed-results` adds the `REASON` column that states *what* diverged (`Want pass, got fail`, `Not found`, the validation message). Together they turn a thousand-line log into a handful of actionable lines. `--remove-color` is a third, cosmetic-but-important addition for log collectors.

**Q10.** (1) It is coupled to a human-readable summary string that has changed wording across CLI releases — a rename silently makes the gate always-green. (2) It cannot distinguish "0 tests failed" from "the suite never loaded and 0 tests ran", nor from a loader error that printed nothing. The exit code covers both cases; the grep covers neither.

**Q11.** `skip` — the rule was selected by `match`/`exclude` but its `preconditions` evaluated false, so the engine never assessed compliance. `fail` — the rule was fully evaluated and the resource violated it.

**Q12.** Variable substitution failed: `{{ request.object.metadata.annotations."corp.io/owner" }}` resolves to nothing for a Pod with no such annotation, and Kyverno treats an unresolvable variable as a rule execution error rather than an empty string. The fix is a JMESPath default: `{{ request.object.metadata.annotations."corp.io/owner" || '' }}` — after which the rule deterministically evaluates for every Pod.

**Q13.** An `error` is not a decision. With the webhook's `failurePolicy: Fail` (Kyverno's default for enforcing rules), an engine error at admission time rejects the request — so a rule that errors on a common resource shape becomes a cluster-wide outage for that resource kind. With `failurePolicy: Ignore` the opposite happens: the request is admitted un-policed, and the control silently stops enforcing. Either way, `error` in a CLI test is a defect to fix, never an expectation to enshrine.

**Q14.** `fail`. Once `tier: backend` is present the precondition is satisfied, the rule is evaluated, and the Pod has no `corp.io/owner` annotation, so the pattern does not match. This is precisely the pair of cases a good suite carries: one resource that skips the rule and one that reaches it.

**Q15.** No. `validationFailureAction` controls *enforcement* at admission (reject vs. report only); the rule's evaluation outcome — and therefore the policy-report result the CLI asserts — is `fail` either way. This is a frequent exam distractor. (In the newer CEL-based `ValidatingPolicy` type, `validationActions` may include `Warn`, which is where the `warn` result value comes from; classic `ClusterPolicy` audit-mode violations are still reported as `fail`.)

**Q16.** `autogen-check-for-labels` for Pod controllers (Deployment, StatefulSet, DaemonSet, Job, ReplicaSet, ReplicationController), and `autogen-cronjob-check-for-labels` for CronJob — the extra `jobTemplate` nesting level gets its own generated rule.

**Q17.** `Not found` means the CLI found **no report entry** matching the `policy`+`rule`+`kind`+`resource` tuple you asserted, so there was nothing to compare a result against. Common causes: (1) the rule name is the un-prefixed one for an autogen'd controller resource; (2) the resource name or namespace in `results[].resources` does not match `metadata.name`/`metadata.namespace` in the fixture; (3) the `kind` is wrong or wrongly cased, so the rule never matched the resource at all.

**Q18.** `pod-policies.kyverno.io/autogen-controllers`. Setting it to `none` disables generation entirely — after which `autogen-check-for-labels` no longer exists, the Deployment expectation reverts to `Not found`, and the Deployment is no longer policed at all. The annotation can also be narrowed to a list, e.g. `Deployment,StatefulSet`.

**Q19.** Because in a real cluster almost nothing creates bare Pods — Deployments, StatefulSets, Jobs and CronJobs do. If autogen is misconfigured or disabled, the policy looks green against Pod fixtures while every workload actually deployed sails through unpoliced. The controller fixture is the one that tests what production will send.

**Q20.** `CREATE`. Rules gated on `request.operation` being `UPDATE` or `DELETE` are therefore skipped by default, and a suite that never sets `globalValues` will report `skip` for them — a green suite that has tested nothing. Assert both operations explicitly.

**Q21.** `globalValues` applies to every policy and every resource in the suite (the ambient request context: operation, cluster-wide values). `spec.policies[].resources[].values` scopes a value to one resource under one policy. The per-resource form is mandatory whenever two fixtures must see *different* values for the same variable — the standard case being one resource that satisfies a context-driven condition and one that does not, within a single run.

**Q22.** `error`. `request.userInfo.groups` is unresolvable without a `userinfo:` file, and an unresolved variable is a rule execution error, not an empty list. This is why identity-gated rules require the `UserInfo` fixture even to produce a meaningful negative test.

**Q23.** Rules that match on namespace labels (or reference `request.namespace` metadata) need the namespace's labels, which are not present in the resource manifests. At runtime Kyverno fetches them from the API server or its namespace cache; offline, `namespaceSelector` in the values file substitutes for that lookup.

**Q24.** Not faithfully — there is no API server to call. Supply the value the APICall would have returned through the variables file (per-rule/per-resource `values` keyed to the context entry name), which pins the test to a known response. That makes the test deterministic but also means it validates your *logic*, not the live API shape; the shape has to be verified separately against a real cluster.

**Q25.** For a mutate rule, `pass` means the rule matched and applied its patch successfully, and the resulting object equals `patchedResource`. The assertion lives in the patched-resource comparison; `result: pass` asserts the rule fired at all.

**Q26.** (1) Key ordering and indentation differences are irrelevant, but *added* fields are not — Kyverno's output carries defaulted/normalized fields your hand-written copy lacks. (2) Provenance annotations the engine attaches to mutated objects. (3) Type coercion: `"false"` vs `false`, `8080` vs `"8080"`, and trailing-newline/quoting differences in multiline strings. Generating the file with `kyverno apply -o` eliminates all three; regenerate it whenever the policy or the CLI version changes, and review the diff in code review.

**Q27.** The expected result is `skip` (the rule was not applicable), and `patchedResource` is omitted entirely — there is no patched object to compare. Declaring an unchanged `patchedResource` for a non-matching resource is a common way to write a test that passes for the wrong reason.

**Q28.** For mutate-existing policies the target objects go in `results[].patchedResources` (the mutated *targets*, not the trigger), and the test must also declare the target objects themselves so the engine has something to mutate — typically via a `targetResources:` list alongside `resources:`. The trigger resource still identifies the row.

**Q29.** `kind: Namespace` and `resources: [team-alpha]` identify the **trigger** — the report entry is attached to the object that caused the rule to fire. `generatedResource` points at a file containing the expected **downstream** object (the NetworkPolicy).

**Q30.** Replace `generate.data` with `generate.clone: {namespace: platform, name: <secret-name>}`. The test must then declare `cloneSourceResource: <path to the source Secret manifest>` on the result entry, and the source Secret must be loadable — the CLI cannot read it from a cluster. The trigger Namespace remains the entry in `resources:`.

**Q31.** No. `synchronize: true` is a *controller* behaviour — the generate controller watches the source and the generated object and reconciles drift over time. `kyverno test` evaluates a single admission-time decision, so it can never catch synchronization bugs, deletion-propagation bugs, or `orphanDownstreamOnPolicyDelete` behaviour. Those require an integration test against a real cluster.

**Q32.** Because the rule was *not evaluated* for that resource — the exception removed it from scope. Reporting `pass` would be a lie in the policy report: dashboards and compliance evidence would count an exempted workload as compliant. `skip` keeps exemptions visible and countable, which is what lets a platform team audit how much of the estate is running under exceptions.

**Q33.** (1) A test asserting the exempted resource now yields `skip` — proof the exception works. (2) A test asserting that a *neighbouring* resource, which the exception must not cover, still yields `fail` — proof the exception is scoped. Without the second test, an over-broad `match` disables the policy fleet-wide and every remaining assertion still looks reasonable.

**Q34.** The assertion for `pod-with-label` (or any other Pod in `default` expected to be evaluated) breaks, because it now reports `skip` instead of `pass`. That is the safety property: an exception whose scope silently widens cannot pass a suite that pins the negative case, so the blast radius is caught in code review rather than in production.

**Q35.** Because path resolution is anchored to the test manifest's directory: moving the manifest into `.kyverno-test/` moved the anchor down one level, so `policy.yaml` had to become `../policy.yaml`. Rule: *every path inside a `Test` manifest is relative to that manifest's own directory.*

**Q36.** `kyverno-test.yaml`. A suite named `tests.yaml` is invisible to a recursive run — it is silently not executed, and the summary happily reports on whatever else it found. Either rename it or pass `-f tests.yaml`, and be aware that `-f` applies to the whole invocation.

**Q37.** A selector narrows the run to a subset while still exiting 0 on success, so the pipeline reports green having executed a fraction of the suite. Selectors are a local debugging tool; a committed CI invocation must run the full corpus.

**Q38.** The CLI's embedded engine is 1.13 while the cluster enforces 1.11. Behaviour that changed between those versions — new operators, autogen coverage, `failureAction` placement, exception apiVersion handling, defaulting — is evaluated by the *newer* engine, so tests can be green against semantics the cluster does not implement. Pin the CLI version to the deployed Kyverno version and bump both together.

**Q39.** Regression-testing a Kyverno upgrade: point the *new* CLI at the upstream policy corpus (`kyverno test https://github.com/kyverno/policies/... -b main`) or at your own policy repository's tag before rolling the controller. Same technique validates a curated policy library consumed from a remote repo without vendoring it first.

**Q40.** Loader failures: 1 (unknown `apiVersion` for the `Test` kind), 4 (missing policy file), 5 (duplicate policy names) — nothing is evaluated and no result table is printed. Per-row `Fail`: 2, 3, 7 (`Not found`) and 6 (invalid/incomplete result entry, which may also be rejected at parse time depending on version). The distinction is the first triage question: a loader failure means *the suite did not run*, so "0 failures" carries no information — treat it as more severe than a genuine assertion mismatch.

**Q41.** `Not found` — no report entry matched the asserted tuple. Fastest discriminator: run `kyverno apply policy.yaml --resource resources.yaml --policy-report` and read the actual report — it lists the real policy names, rule names (including `autogen-` prefixes), kinds and resource names, so you can diff your `results[]` entries against ground truth instead of guessing.

**Q42.** Non-zero (1), the same as an assertion failure — the CLI does not distinguish them by code. So an exit-code gate does correctly fail the build, but it cannot tell you *whether anything ran*. Pair the gate with `--detailed-results` in the log, and for high-stakes pipelines assert a minimum expected test count so an accidentally empty run cannot pass.

</details>

---

### Sources

- Kyverno CLI — `test` command reference: https://kyverno.io/docs/kyverno-cli/usage/test/
- Kyverno CLI — `apply` command (used to generate `patchedResource`): https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno CLI — installation and overview: https://kyverno.io/docs/kyverno-cli/
- Kyverno documentation root (policy types, autogen, exceptions, variables): https://kyverno.io/docs/
- Kyverno CLI source of truth for flags and manifest schemas: https://github.com/kyverno/kyverno/tree/main/cmd/cli/kubectl-kyverno
- Real-world test corpus (`.kyverno-test/kyverno-test.yaml` per policy): https://github.com/kyverno/policies
- KCA curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf