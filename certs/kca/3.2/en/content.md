# KCA 3.2 — `kyverno test`

**Domain 3 — Kyverno CLI · Exam weight 3.0 %**

> **Scope.** This topic covers the `kyverno test` subcommand: the declarative, cluster‑less unit‑test harness that executes policies against fixture resources and asserts an expected outcome per (policy, rule, resource) triple. It does *not* cover `kyverno apply` (ad‑hoc evaluation, no assertions — topic 3.1) nor end‑to‑end cluster testing with Chainsaw.

---

## 1. The production problem

A Kyverno `ClusterPolicy` in `Enforce` mode is a **cluster‑wide, synchronous admission gate**. Its blast radius is the entire API surface it matches. The two failure modes are asymmetric and both are expensive:

| Failure mode | Mechanism | Production symptom |
|---|---|---|
| **False positive** (over‑matching) | `match` block too broad, missing `exclude`, forgotten `autogen` interaction | Every `Deployment` rollout fails admission. `kubectl apply` returns `admission webhook "validate.kyverno.svc-fail.kyverno.svc" denied the request`. Node autoscaling stalls because DaemonSet pods are rejected. Full outage. |
| **False negative** (under‑matching) | Typo in a JMESPath expression, wrong `apiVersion` in `match.resources.kinds`, a `precondition` that silently evaluates to `false` | The control reports "0 violations" forever. The auditor sees a green PolicyReport. Nothing is actually enforced. Silent, and only discovered at audit time. |

The second is worse. A policy that never matches anything produces *no signal at all* — `kubectl get polr -A` shows nothing, and an empty report is indistinguishable from full compliance. This is the single most common defect in policy‑as‑code repositories.

The architectural response is a **policy test pyramid**, and `kyverno test` is its base layer:

```
                 ┌───────────────────────────┐
                 │  Chainsaw / real cluster  │  e2e: webhook wiring, background scans,
                 │  (minutes, needs a cluster)│  generate lifecycle, RBAC, reports
                 ├───────────────────────────┤
                 │  kyverno apply --cluster  │  integration: policy vs. live resources
                 │  (seconds, needs kubeconfig)│
                 ├───────────────────────────┤
                 │      kyverno test         │  UNIT: policy vs. fixture, asserted,
                 │  (milliseconds, no cluster)│  hermetic, runs in a PR check
                 └───────────────────────────┘
```

`kyverno test` links the **same engine library** (`pkg/engine`) that the admission controller runs. It is not a re‑implementation or a linter — the evaluation semantics are the production semantics, minus the API server. That fidelity is what makes it worth gating merges on, and §10 documents exactly where the "minus the API server" part leaks.

---

## 2. Where `test` sits — comparative trade‑offs

| Tool | Cluster required | Assertions | Engine fidelity | Typical wall clock | Right job |
|---|---|---|---|---|---|
| `kyverno apply` | No (optional `--cluster`) | None — prints a report, you read it | Full engine | ~100 ms | Exploration, "what does this policy do to this YAML?" |
| **`kyverno test`** | **No** | **Declarative, per‑rule, per‑resource** | **Full engine, mocked context** | **~200 ms–2 s** | **PR gate, regression suite, refactor safety net** |
| `kyverno apply --cluster` | Yes (read‑only kubeconfig) | None | Full engine + live `apiCall`/ConfigMap context | Seconds | Pre‑flight against a real cluster's inventory |
| Chainsaw (`kyverno/chainsaw`) | Yes (kind/k3d) | Yes, on cluster state | Real webhook, real API server | Minutes | Webhook config, `generate` + `synchronize`, background scans, upgrade tests |
| Conftest / OPA `rego` tests | No | Yes | **Different engine** — proves nothing about Kyverno | ~50 ms | Not applicable; a separate policy stack |
| `kubectl apply --dry-run=server` | Yes | None | Real, full chain | Seconds | Final sanity check before merge |

**The decision rule.** If the assertion is about *the engine's verdict on a manifest*, it belongs in `kyverno test`. If it is about *cluster state changing over time* — a generated resource appearing, a report being written, `synchronize: true` propagating an edit — it belongs in Chainsaw. Do not try to force the second into the first; you will write tests that pass while the policy is broken in production.

---

## 3. Anatomy of the `Test` manifest

Since Kyverno 1.11 the test file is a typed object under `cli.kyverno.io/v1alpha1`. Legacy unversioned files (bare `name:`/`policies:`/`results:` with no `apiVersion`) are deprecated — migrate them (§8.3).

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label          # test suite name, surfaced in output
policies:                           # paths, relative to THIS file
  - policy.yaml
resources:                          # fixture manifests (may be multi-doc)
  - resources.yaml
variables: values.yaml              # OPTIONAL: mocked context (kind: Value)
userinfo: user-info.yaml            # OPTIONAL: mocked AdmissionReview.userInfo
results:                            # the assertions
  - policy: require-team-label      # metadata.name of the policy
    rule: check-team-label          # spec.rules[].name — see §7 for autogen
    kind: Pod                       # resource kind under test
    namespace: default              # OPTIONAL: disambiguates same-named fixtures
    resources:                      # metadata.name of one or more fixtures
      - good-pod
    result: pass                    # the EXPECTED engine verdict
```

### 3.1 The `result` vocabulary

This is the highest‑yield table in the topic. The exam tests the distinction between `fail` and `skip` relentlessly, and so does production.

| `result` | Engine meaning | What it proves | Common cause when unexpected |
|---|---|---|---|
| `pass` | Rule **was applied**; resource **complied** | The happy path is not accidentally blocked | — |
| `fail` | Rule **was applied**; resource **violated** | The control actually catches the bad input | — |
| `skip` | Rule **was not applied** — `match`/`exclude` did not select it, or a `precondition` evaluated false | Scoping is correct (exclusions work) | **Getting `skip` where you expected `fail` is the false‑negative bug.** Wrong `kinds`, wrong `apiVersion`, unresolved precondition variable |
| `warn` | A failure surfaced as a warning rather than a denial — the `Audit` semantics (`kyverno apply --audit-warn`) | An advisory policy is advisory | Asserting `fail` on a policy you moved to `Audit` |
| `error` | The engine could not evaluate: malformed pattern, variable substitution failure, bad JMESPath | Nothing — this is a broken policy | Missing entry in `variables`; `apiCall` with no cluster |

> **`skip` ≠ `pass`.** A `skip` means the rule had no opinion. If your suite only asserts `pass`, a policy whose `match` block you broke will still be green — every resource silently skips. **Every validate rule needs at least one asserted `fail`.** Treat that as a review checklist item.

### 3.2 Mutation and generation fields

| Field | Applies to | Value |
|---|---|---|
| `patchedResources` | `mutate` rules | Path to a YAML file holding the **exact expected post‑mutation resource** |
| `generatedResource` | `generate` rules | Path to a YAML file holding the expected generated object |
| `cloneSourceResource` | `generate` with `clone` | Path to the source object being cloned |
| `isValidatingAdmissionPolicy: true` | Kyverno‑generated / native VAP | Marks the row as a ValidatingAdmissionPolicy assertion |

---

## 4. Repository layout convention

The upstream `kyverno/policies` repository uses this layout, and the exam fixtures follow it. Keep tests adjacent to the policy — a test that lives three directories away rots.

```
policies/
└── governance/
    └── require-team-label/
        ├── require-team-label.yaml          # the ClusterPolicy
        ├── artifacthub-pkg.yml              # catalogue metadata
        └── .kyverno-test/
            ├── kyverno-test.yaml            # the Test object
            ├── resources.yaml               # fixtures
            └── values.yaml                  # optional mocked context
```

`kyverno test <dir>` walks `<dir>` **recursively** and executes every file named `kyverno-test.yaml` (or `.yml`). One invocation at the repo root runs the whole suite.

---

## 5. Worked example 1 — validate: `pass`, `fail`, and the mandatory `skip`

### 5.1 `require-team-label.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/category: Governance
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Every workload Pod must carry a non-empty `team` label so that cost
      allocation and incident routing can attribute it to an owning group.
      Platform namespaces are exempt.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - kyverno
      validate:
        message: "The label `team` is required and must be non-empty on all Pods."
        pattern:
          metadata:
            labels:
              team: "?*"
```

> **Version note.** `spec.validationFailureAction` is the 1.10–1.12 location; Kyverno 1.13 moves it to per‑rule `spec.rules[].validate.failureAction` and deprecates the spec‑level field. Both are accepted during the deprecation window. Confirm which your exam image uses with `kyverno version`, and keep the CLI on the **same minor version as the cluster** — the CLI carries its own copy of the engine and its own schema validation.

### 5.2 `resources.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
  namespace: default
  labels:
    team: payments
spec:
  containers:
    - name: app
      image: ghcr.io/example/app:1.4.2
---
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: default
  labels:
    app: checkout
spec:
  containers:
    - name: app
      image: ghcr.io/example/app:1.4.2
---
apiVersion: v1
kind: Pod
metadata:
  name: empty-label-pod
  namespace: default
  labels:
    team: ""
spec:
  containers:
    - name: app
      image: ghcr.io/example/app:1.4.2
---
apiVersion: v1
kind: Pod
metadata:
  name: system-pod
  namespace: kube-system
  labels:
    component: etcd
spec:
  containers:
    - name: etcd
      image: registry.k8s.io/etcd:3.5.15-0
```

`empty-label-pod` is deliberate: `"?*"` in a Kyverno pattern means "one character followed by any number of characters", i.e. **non‑empty**. A `team: ""` label satisfies "the key exists" but must still fail. Without this fixture, swapping `?*` for `*` — which *does* match empty — is an undetectable regression.

### 5.3 `.kyverno-test/kyverno-test.yaml`

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label
policies:
  - ../require-team-label.yaml
resources:
  - resources.yaml
results:
  - policy: require-team-label
    rule: check-team-label
    kind: Pod
    resources:
      - good-pod
    result: pass

  - policy: require-team-label
    rule: check-team-label
    kind: Pod
    resources:
      - bad-pod
      - empty-label-pod
    result: fail

  - policy: require-team-label
    rule: check-team-label
    kind: Pod
    namespace: kube-system
    resources:
      - system-pod
    result: skip
```

### 5.4 Execution

```console
$ kyverno version
Version: 1.13.2
Time: 2025-01-14T09:12:44Z
Git commit ID: 8e3f4b1c0d2a5e9f7b1c3d4e5f6a7b8c9d0e1f2a

$ kyverno test .
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 4 resources ...
  Checking results ...

│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ ID │ POLICY               │ RULE              │ RESOURCE                        │ RESULT │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ 1  │ require-team-label   │ check-team-label  │ default/Pod/good-pod            │ Pass   │
│ 2  │ require-team-label   │ check-team-label  │ default/Pod/bad-pod             │ Pass   │
│ 3  │ require-team-label   │ check-team-label  │ default/Pod/empty-label-pod     │ Pass   │
│ 4  │ require-team-label   │ check-team-label  │ kube-system/Pod/system-pod      │ Pass   │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│

Test Summary: 4 tests passed and 0 tests failed

$ echo $?
0
```

> **Read the `RESULT` column correctly.** It is the **test verdict**, not the policy verdict. Row 2 says `Pass` because the engine returned `fail` for `bad-pod` **and the test expected `fail`**. A `Fail` in that column means *the assertion did not hold* — the engine's outcome differed from what you declared. Candidates lose marks by reading row 2 as "the bad pod was allowed".

### 5.5 A failing run

Now break the policy: change `exclude` to omit `kube-system`.

```console
$ kyverno test .
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 4 resources ...
  Checking results ...

│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ ID │ POLICY               │ RULE              │ RESOURCE                        │ RESULT │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ 1  │ require-team-label   │ check-team-label  │ default/Pod/good-pod            │ Pass   │
│ 2  │ require-team-label   │ check-team-label  │ default/Pod/bad-pod             │ Pass   │
│ 3  │ require-team-label   │ check-team-label  │ default/Pod/empty-label-pod     │ Pass   │
│ 4  │ require-team-label   │ check-team-label  │ kube-system/Pod/system-pod      │ Fail   │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│

Aggregated Failed Test Cases :
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ ID │ POLICY               │ RULE              │ RESOURCE                        │ RESULT │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│
│ 1  │ require-team-label   │ check-team-label  │ kube-system/Pod/system-pod      │ Fail   │
│────│──────────────────────│───────────────────│─────────────────────────────────│────────│

Test Summary: 3 tests passed and 1 tests failed

$ echo $?
1
```

The non‑zero exit code is the whole point: it is what makes the command usable as a merge gate. `--fail-only` suppresses the passing rows but does **not** change the exit code.

---

## 6. Worked example 2 — mutation and `patchedResources`

Mutation tests assert on the *output document*, byte‑for‑byte after YAML normalisation. This is stricter than a validate assertion and catches merge‑key mistakes that a `pass`/`fail` never would.

### 6.1 `add-default-requests.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-requests
  annotations:
    policies.kyverno.io/title: Add default resource requests
    policies.kyverno.io/category: Scheduling
    policies.kyverno.io/subject: Pod
spec:
  background: false
  rules:
    - name: add-default-requests
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        any:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                resources:
                  requests:
                    +(memory): "128Mi"
                    +(cpu): "100m"
```

Two Kyverno anchors are load‑bearing here and both are exam material:

| Anchor | Syntax | Semantics |
|---|---|---|
| Conditional | `(name): "*"` | Select every list element whose `name` matches; used as the merge key so the patch applies per container |
| Add‑if‑absent | `+(memory): "128Mi"` | Add the field **only when it is not already set**; never overwrite an explicit request |

### 6.2 `resources.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.3
    - name: sidecar
      image: ghcr.io/example/agent:2.1.0
      resources:
        requests:
          cpu: "500m"
```

### 6.3 `patched.yaml` — the expected output

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.3
      resources:
        requests:
          memory: 128Mi
          cpu: 100m
    - name: sidecar
      image: ghcr.io/example/agent:2.1.0
      resources:
        requests:
          cpu: "500m"
          memory: 128Mi
```

Note the `sidecar` container: `cpu` is **preserved at `500m`** because of `+(cpu)`, while `memory` is added. If your patched file shows `cpu: 100m` there, the anchor is wrong — and only the mutation test catches it.

### 6.4 `values.yaml` — mocking the admission context

`request.operation` is an AdmissionReview field. There is no API server, so it must be supplied. The `|| 'BACKGROUND'` fallback in the policy prevents an `error` verdict, but you should still mock the real value so the test exercises the `CREATE` branch.

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
globalValues:
  request.operation: CREATE
policies:
  - name: add-default-requests
    resources:
      - name: nginx
        values:
          request.object.metadata.namespace: default
namespaceSelector:
  - name: default
    labels:
      kubernetes.io/metadata.name: default
```

| `Value` field | Purpose |
|---|---|
| `globalValues` | Key/value pairs visible to **every** policy and resource |
| `policies[].rules[].values` | Scoped to one rule — use for per‑rule `apiCall`/ConfigMap mocks |
| `policies[].resources[].values` | Scoped to one fixture — lets one resource take a different context |
| `namespaceSelector` | Supplies namespace **labels**, which the CLI cannot look up; required whenever a policy uses `match.any.resources.namespaceSelector` |

### 6.5 The test and its run

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: add-default-requests
policies:
  - ../add-default-requests.yaml
resources:
  - resources.yaml
variables: values.yaml
results:
  - policy: add-default-requests
    rule: add-default-requests
    kind: Pod
    resources:
      - nginx
    patchedResources: patched.yaml
    result: pass
```

```console
$ kyverno test . --detailed-results
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 1 resource ...
  Checking results ...

│────│───────────────────────│─────────────────────────│───────────────────────│────────│
│ ID │ POLICY                │ RULE                    │ RESOURCE              │ RESULT │
│────│───────────────────────│─────────────────────────│───────────────────────│────────│
│ 1  │ add-default-requests  │ add-default-requests    │ default/Pod/nginx     │ Pass   │
│────│───────────────────────│─────────────────────────│───────────────────────│────────│

Test Summary: 1 tests passed and 0 tests failed
```

When the patch does not match, the CLI prints a structured diff of expected vs. actual — this is the payoff for `--detailed-results`:

```console
$ kyverno test . --detailed-results
...
│ 1  │ add-default-requests  │ add-default-requests    │ default/Pod/nginx     │ Fail   │

Aggregated Failed Test Cases :
patched resource mismatch for default/Pod/nginx:
  spec.containers[1].resources.requests.cpu:
    expected: 500m
    actual:   100m

Test Summary: 0 tests passed and 1 tests failed
```

> **The API‑server defaulting trap.** `patched.yaml` must contain **only the raw manifest plus Kyverno's patch**. Do *not* paste the output of `kubectl get pod -o yaml`: the API server injects `terminationMessagePath`, `imagePullPolicy`, `dnsPolicy`, `restartPolicy`, `serviceAccountName`, `status`, `metadata.uid`, and `creationTimestamp`. None of those exist in the CLI's evaluation, and every one of them makes the comparison fail. The reliable way to produce `patched.yaml` is to run `kyverno apply` and copy its emitted patched resource — never the cluster's.

---

## 7. Auto‑generated rules — the most common test failure

When a policy matches `Pod` and `spec.background` is `true` (or the `pod-policies.kyverno.io/autogen-controllers` annotation is set), Kyverno **synthesises additional rules** for pod controllers so that a bad `Deployment` is rejected at the Deployment level, with a comprehensible error, instead of silently producing zero ready replicas.

The generated rules are visible in the stored policy:

```console
$ kubectl get clusterpolicy require-team-label -o jsonpath='{.spec.rules[*].name}{"\n"}'
check-team-label

$ kubectl get clusterpolicy require-team-label -o jsonpath='{.status.autogen.rules[*].name}{"\n"}'
autogen-check-team-label autogen-cronjob-check-team-label
```

| Matched resource kind | Rule name to assert in `results` |
|---|---|
| `Pod` | `check-team-label` |
| `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `Job`, `ReplicationController` | `autogen-check-team-label` |
| `CronJob` | `autogen-cronjob-check-team-label` |

Asserting the bare rule name against a `Deployment` fixture is the classic error:

```console
$ kyverno test .
...
Error: test case has invalid rule: rule "check-team-label" not found in policy "require-team-label"
```

Correct form:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label-autogen
policies:
  - ../require-team-label.yaml
resources:
  - controllers.yaml
results:
  - policy: require-team-label
    rule: autogen-check-team-label
    kind: Deployment
    resources:
      - bad-deployment
    result: fail

  - policy: require-team-label
    rule: autogen-cronjob-check-team-label
    kind: CronJob
    resources:
      - bad-cronjob
    result: fail
```

Autogen coverage is not optional in a serious suite. A policy can be perfectly correct for `Pod` and completely wrong for `CronJob`, because the CronJob autogen rule rewrites the path to `spec.jobTemplate.spec.template.metadata.labels` — a pattern that assumed `spec.template.metadata` will not survive the rewrite.

---

## 8. CLI surface

### 8.1 Flags

```console
$ kyverno test --help
Run tests from a local filesystem or a git repository.
...
```

| Flag | Effect | Production use |
|---|---|---|
| `-f, --file-name` | Test filename to discover (default `kyverno-test.yaml`) | Only when you must deviate from convention |
| `-t, --test-case-selector` | Run a subset: `"policy=require-team-label, rule=check-team-label, resource=bad-pod"` | Iterating on one failure in a 400‑test suite |
| `--fail-only` | Print only failing rows (exit code unchanged) | CI logs — collapses a wall of green |
| `--detailed-results` | Expand per‑check detail and patch diffs | Diagnosing a mutation mismatch |
| `--remove-color` | Strip ANSI escapes | **Always set in CI**; otherwise logs are unreadable |
| `--registry` | Permit network access to OCI registries | `imageVerify` / `imageData` rules only |
| `-b, --git-branch` | Branch to use when the path is a Git URL | Testing an upstream library |

### 8.2 Running against a Git repository

The path argument accepts a Git URL, so you can regression‑test a policy library you consume without vendoring it:

```console
$ kyverno test https://github.com/kyverno/policies/pod-security --git-branch main
Loading test  ( .kyverno-test/kyverno-test.yaml ) ...
...
Test Summary: 62 tests passed and 0 tests failed
```

### 8.3 Scaffolding and migration

```console
# Generate a Test manifest skeleton instead of writing YAML from memory
$ kyverno create test --help

# Migrate legacy (unversioned) test files to cli.kyverno.io/v1alpha1 in place
$ KYVERNO_EXPERIMENTAL=true kyverno fix test . --save
Processing file ( .kyverno-test/kyverno-test.yaml )...
  WARNING: test file is not in the expected format
  OK
Done.
```

`kyverno fix test` also normalises the deprecated singular fields (`resource:` → `resources:`, `patchedResource:` → `patchedResources:`). Run it once, commit the result, and stop hand‑maintaining the old shape.

### 8.4 Assertion trees (`checks`) — Kyverno 1.12+

For assertions richer than a single verdict — "the report entry must carry this severity", "the message must mention the label name" — newer CLIs accept a `checks` block backed by kyverno‑json assertion trees:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label-checks
policies:
  - ../require-team-label.yaml
resources:
  - resources.yaml
checks:
  - match:
      resource:
        metadata:
          name: bad-pod
    assert:
      result: fail
      message: "(contains(@, 'team'))": true
```

Treat this as additive: `results` remains the primary, exam‑relevant mechanism, and `checks` availability varies by CLI minor version. Verify with `kyverno test --help` on the image in front of you before relying on it.

---

## 9. CI integration

### 9.1 GitHub Actions

```yaml
name: kyverno-policy-tests

on:
  pull_request:
    paths:
      - 'policies/**'
      - '.github/workflows/kyverno-policy-tests.yaml'
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install Kyverno CLI
        uses: kyverno/action-install-cli@v0.2.0
        with:
          release: v1.13.2          # pin: must match the cluster's minor version

      - name: Report CLI version
        run: kyverno version

      - name: Validate policy syntax
        run: |
          find policies -name '*.yaml' -not -path '*/.kyverno-test/*' \
            -exec kyverno apply {} --resource /dev/null \; > /dev/null

      - name: Run policy unit tests
        run: kyverno test ./policies --remove-color --detailed-results
```

The job fails on a non‑zero exit from `kyverno test`. No cluster, no kubeconfig, no secrets — which is exactly why this belongs on `pull_request` from forks.

### 9.2 Makefile target

```makefile
KYVERNO_VERSION ?= 1.13.2
POLICY_DIR      ?= ./policies

.PHONY: test-policies
test-policies:
	@kyverno version | grep -q "Version: $(KYVERNO_VERSION)" \
		|| { echo "ERROR: expected Kyverno CLI $(KYVERNO_VERSION)"; exit 1; }
	kyverno test $(POLICY_DIR) --remove-color

.PHONY: test-policies-failed
test-policies-failed:
	kyverno test $(POLICY_DIR) --remove-color --fail-only --detailed-results
```

The version assertion is not paranoia. The CLI embeds its own engine build; running tests with a CLI two minors ahead of the cluster produces green tests for semantics the cluster does not implement.

---

## 10. Verification and failure diagnosis

### 10.1 Symptom → cause → fix

| Symptom | Root cause | Fix |
|---|---|---|
| `Test Summary: 0 tests passed and 0 tests failed` | No `kyverno-test.yaml` found under the path | Check the filename exactly, or pass `-f`. Confirm with `find . -name 'kyverno-test.y*ml'` |
| `Error: failed to load test file: ... unknown field` | Legacy unversioned schema, or a deprecated singular field | `KYVERNO_EXPERIMENTAL=true kyverno fix test . --save` |
| `Error: test case has invalid rule: rule "X" not found` | Asserting a Pod rule against a controller fixture | Use `autogen-X` / `autogen-cronjob-X` (§7) |
| Expected `fail`, got `skip` | `match` did not select the resource: wrong `kinds`, wrong group/version, or an `exclude` that is too wide | `kyverno apply policy.yaml --resource resources.yaml` and read the per‑rule output |
| Expected `pass`, got `error` | Unresolved variable — `request.*`, `serviceAccountName`, a ConfigMap or `apiCall` context | Add it to `variables: values.yaml`, or give the policy a `\|\| 'default'` fallback |
| `variable substitution failed: ... variable ... not resolved` | Same as above, made explicit | `globalValues:` for cluster‑wide facts, `policies[].resources[].values` for per‑fixture facts |
| Expected `fail`, got `skip`, and the policy uses `namespaceSelector` | The CLI cannot read namespace labels | Add a `namespaceSelector:` entry to the `Value` object |
| `patched resource mismatch` on fields you never wrote | `patched.yaml` was copied from a live cluster | Regenerate from `kyverno apply`, not from `kubectl get -o yaml` |
| Passes locally, fails in CI | CLI version drift | Pin `release:` in the install action; assert the version in the Makefile |
| `imageVerify` rule returns `error` | No registry access | Add `--registry`, or move the assertion to Chainsaw |

### 10.2 The diagnostic escalation ladder

When a row is red and the table alone does not explain it, escalate in this order — each step costs more and reveals more:

```console
# 1. Narrow to the single failing case
$ kyverno test . -t "policy=require-team-label, resource=bad-pod"

# 2. Expand the assertion detail and the patch diff
$ kyverno test . -t "policy=require-team-label, resource=bad-pod" --detailed-results

# 3. Drop the assertions entirely — see what the engine actually returns
$ kyverno apply ../require-team-label.yaml --resource resources.yaml --policy-report
apiVersion: policy.kyverno.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: merged
results:
- message: 'validation error: The label `team` is required and must be non-empty on
    all Pods. rule check-team-label failed at path /metadata/labels/team/'
  policy: require-team-label
  resources:
  - apiVersion: v1
    kind: Pod
    name: bad-pod
    namespace: default
  result: fail
  rule: check-team-label
  scored: true
  source: kyverno
summary:
  error: 0
  fail: 1
  pass: 1
  skip: 1
  warn: 0

# 4. Turn on engine tracing
$ kyverno test . --v=4 2>&1 | grep -i 'match\|precondition'

# 5. Compare against a real API server
$ kubectl apply -f resources.yaml --dry-run=server
```

Step 3 is the one that resolves most `skip`‑vs‑`fail` confusion: `--policy-report` prints the engine's own verdict with the failing JSON path (`failed at path /metadata/labels/team/`), which tells you precisely which pattern element rejected the document.

---

## 11. What `kyverno test` cannot prove

Knowing the boundary is a senior‑level competency, and the exam probes it as "which tool would you use to verify X?".

| Concern | Why the CLI cannot cover it | Where it belongs |
|---|---|---|
| Webhook is registered for the right resources | No API server, no `ValidatingWebhookConfiguration` | Chainsaw; `kubectl get validatingwebhookconfigurations` |
| `failurePolicy: Fail` behaviour when Kyverno is down | Requires a running control plane to take down | Chainsaw / chaos test |
| `generate` with `synchronize: true` propagating edits | Asserts state over time, not a single evaluation | Chainsaw |
| Background scan results and PolicyReport lifecycle | The reports controller is a cluster component | Chainsaw; `kubectl get polr -A` |
| Live `apiCall` / ConfigMap context lookups | Mocked via `variables`, so you test your mock | `kyverno apply --cluster`, then Chainsaw |
| Cosign signature verification | Needs registry + key material | `--registry`, and Chainsaw for the real path |
| Interaction with other admission webhooks (ordering, mutation chains) | Single‑engine evaluation | `--dry-run=server` on a real cluster |
| API‑server defaulting applied before Kyverno sees the object | The CLI evaluates the raw manifest | `--dry-run=server` |
| RBAC for `generate` rules (the background controller's permissions) | No RBAC subsystem in the CLI | Chainsaw |

The mitigation is not to distrust `kyverno test` — it is to be explicit about the layer. Unit‑test every rule's verdict logic here, where it costs 200 ms, and reserve the cluster for the handful of behaviours that genuinely require one.

---

## 12. Exam and operational checklist

- [ ] Test file is named `kyverno-test.yaml`, lives under `.kyverno-test/`, and paths inside it are **relative to the test file**.
- [ ] Manifest carries `apiVersion: cli.kyverno.io/v1alpha1` and `kind: Test`.
- [ ] Every validate rule has at least one asserted `pass` **and** one asserted `fail`.
- [ ] Every `exclude` block has a fixture asserting `skip`.
- [ ] Controller fixtures assert `autogen-<rule>`; CronJob fixtures assert `autogen-cronjob-<rule>`.
- [ ] Mutation rules assert `patchedResources`, built from `kyverno apply` output — never from a live cluster.
- [ ] Every variable the policy references appears in `variables: values.yaml`, or the policy carries a `||` fallback.
- [ ] Policies using `namespaceSelector` have a matching `namespaceSelector:` entry in the `Value` object.
- [ ] CI pins the CLI release and passes `--remove-color`; the job gates on the exit code.
- [ ] `kyverno test <repo-root>` is green before any policy is promoted from `Audit` to `Enforce`.

---

## References

- Kyverno CLI — `test` command: https://kyverno.io/docs/kyverno-cli/usage/test/
- Kyverno CLI — overview and installation: https://kyverno.io/docs/kyverno-cli/
- Kyverno CLI — `apply` command: https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno — auto‑generation of pod controller rules: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — variables and context: https://kyverno.io/docs/writing-policies/variables/
- Kyverno — external data sources (`apiCall`, ConfigMap): https://kyverno.io/docs/writing-policies/external-data-sources/
- Kyverno — mutate rules and anchors: https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — generate rules: https://kyverno.io/docs/writing-policies/generate/
- Kyverno — policy reports: https://kyverno.io/docs/policy-reports/
- Kyverno — source repository: https://github.com/kyverno/kyverno
- Kyverno — official policy library (canonical test layout): https://github.com/kyverno/policies
- Kyverno — CLI install GitHub Action: https://github.com/kyverno/action-install-cli
- Chainsaw — end‑to‑end testing for Kyverno: https://github.com/kyverno/chainsaw
- CNCF — certification curricula (KCA): https://github.com/cncf/curriculum
- Linux Foundation — Kyverno Certified Associate (KCA): https://training.linuxfoundation.org/certification/kyverno-certified-associate-kca/