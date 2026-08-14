# 5.9 Autogen Rules

**Domain 5 — Writing and Operating Policies · Exam weight: 2.91**

---

## 1. Motivation: the architectural problem autogen solves

### 1.1 The Pod is the enforcement point, but nobody creates Pods

In a real cluster, the Pod is an *output*, not an *input*. The object a human or a CI pipeline submits is a `Deployment`, a `StatefulSet`, a `CronJob`, an Argo `Rollout`, a Helm release. The Pod materialises several controller hops later:

```
user ──apply──> Deployment ──deployment-controller──> ReplicaSet ──replicaset-controller──> Pod
user ──apply──> CronJob    ──cronjob-controller────> Job        ──job-controller────────> Pod
```

Every one of those hops is a separate `CREATE` request to the API server, and therefore a separate admission review. This produces three distinct failure modes that any policy author has to reason about explicitly.

**Failure mode A — you write the rule against `Pod` only.**
The `Deployment` is admitted. `kubectl apply` returns success. CI goes green. The ReplicaSet is created. Then the *ReplicaSet controller* tries to create the Pod, Kyverno denies it, and the failure is buried in `ReplicaSet.status.conditions` and a `FailedCreate` event. Three consequences, all bad in production:

- **Silent partial failure.** The declared state is accepted; the running state never converges. GitOps tools report `Synced/Healthy` on the Deployment while zero Pods exist, or — worse — the previous ReplicaSet keeps serving traffic and nobody notices for days.
- **Wrong attribution.** The denied request is made by `system:serviceaccount:kube-system:replicaset-controller`. Your audit log, your `PolicyReport`, and your alerting all point at a system controller, not at the engineer who pushed the change.
- **Retry amplification.** The ReplicaSet controller retries with backoff, indefinitely. A single bad Deployment becomes a permanent stream of admission reviews, events, and reconcile churn.

**Failure mode B — you write the rule against the controllers only.**
Bare Pods bypass the policy entirely — and bare Pods are exactly what an attacker with `create pods` RBAC will use, and exactly what `kubectl run`, `kubectl debug`, and many operators produce. You also have to hand-write the same logic against three different nesting depths (`spec.containers`, `spec.template.spec.containers`, `spec.jobTemplate.spec.template.spec.containers`), duplicated across six or seven kinds. That is N× the rules, N× the drift, and N× the chance that the `Job` variant quietly diverges from the `Deployment` variant after a refactor.

**Failure mode C — you write both by hand.**
Correct, and unmaintainable. A "require `runAsNonRoot`" policy becomes ~180 lines of near-duplicate YAML. Reviewers stop reading it.

### 1.2 What autogen actually does

Kyverno's **auto-generation** subsystem resolves this at the controller level rather than at the authoring level. You write **one** rule that matches `Pod`. Kyverno's policy controller then synthesises derived rules for pod controllers, performing two mechanical transformations:

1. **Match rewriting** — `kinds: [Pod]` becomes `kinds: [DaemonSet, Deployment, Job, StatefulSet, ...]` in one derived rule, and `kinds: [CronJob]` in a second one (CronJob needs its own rule because of the extra `jobTemplate` nesting level).
2. **Path rewriting** — every pod-spec-relative path in the `validate` pattern, `mutate` patch, `verifyImages` block, preconditions and context entries is re-rooted under `spec.template` (or `spec.jobTemplate.spec.template`).

The derived rules are **real, evaluated rules**. They are not documentation. They appear in `status.autogen.rules`, they appear by name in `PolicyReport` results and in deny messages, and — critically — they drive the contents of Kyverno's dynamically-managed `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`. **Autogen therefore determines your webhook blast radius**, which makes it a latency and availability concern, not just an ergonomics one.

### 1.3 The second-order consequence: mutation and rollouts

For `mutate` rules the choice is not merely cosmetic, and this is the part most engineers get wrong:

- A mutation applied to the **controller** modifies `spec.template.spec`, which changes the pod-template hash, which **triggers a rolling update** and is **visible in `kubectl get deploy -o yaml`**. Your GitOps tool will see the drift and may fight you unless you configure `ignoreDifferences`.
- A mutation applied to the **Pod only** causes no rollout and no drift, but it is invisible in the declared object and is silently re-applied on every Pod recreate. If Kyverno is ever unavailable or the policy is deleted, replacement Pods come up *without* the mutation — a slow, silent security regression.

Neither is universally right. Autogen makes the choice explicit and controllable; the annotation is where you express it.

---

## 2. Technical comparison and trade-offs

### 2.1 Where to enforce

| Strategy | Bare Pods covered | Controllers covered | Failure surfaced to the user | Rule count | Webhook load | Typical use |
|---|---|---|---|---|---|---|
| Match `Pod` only, autogen **disabled** | Yes | No (deny happens late, at Pod create) | No — buried in `FailedCreate` events | 1 | Pods only (lowest) | Rules that are *intrinsically* Pod-level (`nodeName`, `ephemeralContainers`, scheduler-injected fields) |
| Match controllers only, hand-written | **No** | Yes | Yes | 6–7 | Controllers only | Rules about controller-specific fields (`replicas`, `updateStrategy`, `podManagementPolicy`) |
| Match `Pod` + controllers, hand-written | Yes | Yes | Yes | 7–8, duplicated | Highest | Never, if autogen can do it |
| Match `Pod`, **autogen default** | Yes | Yes | Yes | 1 authored, 2 generated | Pods + all pod controllers | **Default choice** for any pod-spec-level rule |
| Match `Pod`, autogen **restricted list** | Yes | Only listed kinds | Yes, for listed kinds | 1 authored, 1–2 generated | Reduced | Clusters that ban some workload kinds outright, or where webhook latency on a hot kind is unacceptable |

### 2.2 The `pod-policies.kyverno.io/autogen-controllers` annotation

The control surface for `ClusterPolicy` / `Policy` (Kyverno v1 API) is a single annotation on the **policy metadata** — not on the rule.

| Annotation value | Effect | When to use |
|---|---|---|
| *(absent)* | Kyverno applies its built-in default controller set | Almost always |
| `Deployment,StatefulSet` | Generates rules **only** for the listed kinds | You genuinely forbid `DaemonSet`/`CronJob` via separate RBAC or policy, and want a smaller webhook footprint |
| `none` | Autogen fully disabled for the **entire policy** (all rules) | Pod-only semantics, or you hand-wrote the controller rules |
| Kind not in Kyverno's known list | Ignored — Kyverno only knows the built-in pod controllers | Custom CRDs (`Rollout`, `CloneSet`) are **not** autogen targets; write those rules explicitly |

> **Do not memorise the default controller set.** It has changed across Kyverno minor releases (in particular whether `ReplicaSet` and `ReplicationController` are in the default set). The set your cluster uses is discoverable — read `status.autogen.rules` on an applied policy, as shown in §4.2. Treating the default as a fixed constant is the single most common source of "the policy passed in staging and let the workload through in prod".

### 2.3 Rule-type support

| Rule type | Autogen behaviour | Notes for production |
|---|---|---|
| `validate.pattern` / `anyPattern` | Fully supported | The most reliable case; pattern is re-rooted under `spec.template` |
| `validate.deny` with `conditions` | Supported, but JMESPath/CEL you wrote by hand against `request.object.spec.*` **must** be checked — rewriting of hand-authored expressions is the fragile part |
| `validate.podSecurity` | Supported | Preferred over hand-rolled PSS patterns precisely because autogen + the subrule are maintained together |
| `validate.cel` | Supported on recent versions | Verify the generated CEL in `status.autogen.rules`, not the docs |
| `mutate.patchStrategicMerge` | Supported | Remember the rollout side-effect (§1.3) |
| `mutate.patchesJson6902` | **Fragile** — JSON pointers are absolute, and re-rooting them is not always sound | Prefer strategic merge, or set `autogen-controllers: none` and write the controller rules explicitly |
| `verifyImages` | Supported | Autogen is what makes signature verification cover Deployments, not just Pods |
| `generate` | **Not applicable** — generate rules create resources, they do not inspect pod specs | Never expect autogen output here |

### 2.4 Path rewriting map

This table is the mental model you need to read a deny message and know which generated rule fired.

| Path in your `Pod` rule | Deployment / DaemonSet / StatefulSet / Job / ReplicaSet / ReplicationController | CronJob |
|---|---|---|
| `metadata.labels` | `spec.template.metadata.labels` | `spec.jobTemplate.spec.template.metadata.labels` |
| `metadata.annotations` | `spec.template.metadata.annotations` | `spec.jobTemplate.spec.template.metadata.annotations` |
| `spec.containers[]` | `spec.template.spec.containers[]` | `spec.jobTemplate.spec.template.spec.containers[]` |
| `spec.initContainers[]` | `spec.template.spec.initContainers[]` | `spec.jobTemplate.spec.template.spec.initContainers[]` |
| `spec.ephemeralContainers[]` | `spec.template.spec.ephemeralContainers[]` | `spec.jobTemplate.spec.template.spec.ephemeralContainers[]` |
| `spec.volumes[]` | `spec.template.spec.volumes[]` | `spec.jobTemplate.spec.template.spec.volumes[]` |
| `spec.securityContext` | `spec.template.spec.securityContext` | `spec.jobTemplate.spec.template.spec.securityContext` |
| `spec.serviceAccountName` | `spec.template.spec.serviceAccountName` | `spec.jobTemplate.spec.template.spec.serviceAccountName` |

### 2.5 Generated rule naming — memorise this, it is exam-relevant and diagnostics-relevant

| Authored rule name | Generated for standard controllers | Generated for CronJob |
|---|---|---|
| `validate-image-tag` | `autogen-validate-image-tag` | `autogen-cronjob-validate-image-tag` |

The `autogen-` and `autogen-cronjob-` prefixes appear verbatim in:

- admission deny messages,
- `PolicyReport` / `ClusterPolicyReport` `results[].rule`,
- the `results:` block of a Kyverno CLI `Test` manifest,
- `kyverno apply` output.

A `kyverno test` that asserts `rule: validate-image-tag` against a `Deployment` resource **will fail**, because the rule that actually fired is `autogen-validate-image-tag`. This is the number-one cause of red CI on an otherwise correct policy.

---

## 3. Complete manifests

### 3.1 Baseline policy relying on default autogen

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-pinned-image-tags
  annotations:
    policies.kyverno.io/title: Require pinned image tags
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Mutable tags such as ':latest' make a rollout non-reproducible and defeat
      admission-time image verification. This policy is authored once against
      Pod; Kyverno auto-generates the equivalent rules for pod controllers.
    # No pod-policies.kyverno.io/autogen-controllers annotation:
    # the built-in default controller set applies. Read status.autogen.rules
    # after applying to confirm which kinds your Kyverno version covers.
spec:
  validationFailureAction: Enforce   # Kyverno >=1.12 also supports the
                                     # per-rule spec.rules[].validate.failureAction
  background: true
  rules:
    - name: validate-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          The mutable tag ':latest' is not allowed. Pin an immutable tag or,
          preferably, a digest (image@sha256:...).
        pattern:
          spec:
            containers:
              - image: "!*:latest"

    - name: require-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          An explicit image tag or digest is required; untagged images resolve
          to ':latest' implicitly.
        pattern:
          spec:
            containers:
              - image: "*:*"
```

This authors 2 rules and yields 4 generated rules: `autogen-validate-image-tag`, `autogen-cronjob-validate-image-tag`, `autogen-require-image-tag`, `autogen-cronjob-require-image-tag`.

### 3.2 Restricting the generated controller set

Use this when the cluster's workload contract genuinely excludes some kinds, and you want a narrower webhook `rules[].resources` list.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-nonroot-runtime
  annotations:
    policies.kyverno.io/title: Require non-root runtime
    # Explicit, reviewable, and reduces the webhook match set.
    # DaemonSet is deliberately excluded: node-level agents in this cluster
    # are exempted through a dedicated policy with a namespaceSelector.
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,Job,CronJob
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-runasnonroot
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          Containers must run as a non-root user. Set
          securityContext.runAsNonRoot=true at the pod or container level.
        anyPattern:
          - spec:
              securityContext:
                runAsNonRoot: true
              containers:
                - securityContext:
                    runAsNonRoot: "true | *"
          - spec:
              containers:
                - securityContext:
                    runAsNonRoot: true
```

### 3.3 Disabling autogen deliberately (`none`)

A Pod-level field that has **no meaning** on a controller template, combined with a precondition so the rule only judges Pods the user created directly:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-direct-node-binding
  annotations:
    policies.kyverno.io/title: Forbid explicit spec.nodeName
    policies.kyverno.io/description: >-
      spec.nodeName bypasses the scheduler entirely, defeating taints,
      topology spread and every scheduling guardrail. It is set legitimately
      only by the scheduler itself, on an already-created Pod.
    # Autogen is disabled: a controller template that sets nodeName is a
    # separate, rarer problem handled by its own rule, and generating
    # Deployment/CronJob variants here would only widen the webhook for no gain.
    pod-policies.kyverno.io/autogen-controllers: none
spec:
  validationFailureAction: Enforce
  background: false        # nodeName is always set on running Pods; a
                           # background scan would flag every Pod in the cluster
  rules:
    - name: deny-nodename-on-create
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - CREATE
      preconditions:
        all:
          # Only judge Pods that a user submitted directly. Controller-created
          # Pods are covered by the controller-level policies.
          - key: "{{ request.object.metadata.ownerReferences[0].kind || '' }}"
            operator: Equals
            value: ""
      validate:
        message: >-
          Setting spec.nodeName directly bypasses the scheduler and is not
          permitted. Use nodeSelector, affinity or tolerations.
        deny:
          conditions:
            all:
              - key: "{{ request.object.spec.nodeName || '' }}"
                operator: NotEquals
                value: ""
```

### 3.4 A mutate rule, and its rollout consequence

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-seccomp-runtimedefault
  annotations:
    policies.kyverno.io/title: Default seccompProfile to RuntimeDefault
    # Autogen ON (default). The mutation lands in spec.template.spec on
    # controllers, which is durable across Pod recreation but CHANGES the
    # pod-template hash and therefore triggers one rolling update per workload
    # the first time this policy is applied. Roll it out in a maintenance window.
spec:
  rules:
    - name: set-runtimedefault-seccomp
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          spec:
            +(securityContext):
              +(seccompProfile):
                type: RuntimeDefault
```

The `+()` add-if-not-present anchor is essential here: without it, the patch would overwrite an intentionally-set `Localhost` profile.

### 3.5 Anti-pattern: matching `Pod` **and** a controller in the same rule

```yaml
# ANTI-PATTERN — do not copy.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-mixed-match
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-labels
      match:
        any:
          - resources:
              kinds:
                - Pod
                - Deployment     # <-- this is what breaks it
      validate:
        message: "app.kubernetes.io/name label is required"
        pattern:
          metadata:
            labels:
              app.kubernetes.io/name: "?*"
```

Two things go wrong. First, autogen is suppressed for a rule that matches kinds beyond `Pod` — Kyverno will not synthesise variants, so `StatefulSet`, `DaemonSet`, `Job` and `CronJob` are **uncovered**. Second, the single `metadata.labels` pattern is now evaluated against the *Deployment's own* labels rather than the pod template's, which is a different assertion than the one you meant. The correct form is §3.1: match `Pod` only, and let autogen produce the correctly-rooted variants.

### 3.6 `verifyImages` with autogen

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-internal-registry-signatures
  annotations:
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet,Job,CronJob
spec:
  validationFailureAction: Enforce
  background: false          # signature verification is an admission-time concern
  webhookTimeoutSeconds: 30  # cosign verification is network-bound; the default 10s
                             # is not enough when the registry is remote
  rules:
    - name: verify-signed-images
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "registry.internal.example.com/*"
          failureAction: Enforce
          verifyDigest: true
          required: true
          mutateDigest: true    # rewrites tag -> digest in the admitted object
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEXAMPLEPUBLICKEYDATAGOESHERE
                      REPLACEWITHYOURREALCOSIGNPUBLICKEYBASE64ENCODEDVALUEXXXXXXXX==
                      -----END PUBLIC KEY-----
                    rekor:
                      url: https://rekor.sigstore.dev
```

Note `mutateDigest: true` interacting with autogen: on a `Deployment`, the digest is written into `spec.template.spec.containers[].image`, which — again — changes the pod-template hash. That is desirable (the pinned digest is now in the declared object) but must be reconciled with your GitOps tool.

### 3.7 Kyverno CLI test asserting the generated rule names

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-pinned-image-tags
policies:
  - policy.yaml
resources:
  - resources.yaml
results:
  # Authored rule — fires on a bare Pod.
  - policy: require-pinned-image-tags
    rule: validate-image-tag
    kind: Pod
    resources:
      - bad-pod
    result: fail

  # Generated rule for standard controllers.
  - policy: require-pinned-image-tags
    rule: autogen-validate-image-tag
    kind: Deployment
    resources:
      - bad-deployment
    result: fail

  - policy: require-pinned-image-tags
    rule: autogen-validate-image-tag
    kind: StatefulSet
    resources:
      - good-statefulset
    result: pass

  # Generated rule for CronJob — different prefix, different path depth.
  - policy: require-pinned-image-tags
    rule: autogen-cronjob-validate-image-tag
    kind: CronJob
    resources:
      - bad-cronjob
    result: fail
```

---

## 4. CLI walkthrough with real terminal output

> Outputs below are from Kyverno 1.13.x on Kubernetes v1.31. Message formatting and the default controller set vary between releases — reproduce them on your own cluster rather than trusting the transcript.

### 4.1 Apply the policy

```console
$ kubectl apply -f require-pinned-image-tags.yaml
clusterpolicy.kyverno.io/require-pinned-image-tags created

$ kubectl get clusterpolicy require-pinned-image-tags
NAME                        ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
require-pinned-image-tags   true        true         Enforce           True    8s    Ready
```

`READY=True` means the policy controller has finished computing autogen rules **and** the API server's webhook configuration has converged. A policy that never becomes Ready is not enforcing anything.

### 4.2 Read the generated rules — the ground truth

```console
$ kubectl get clusterpolicy require-pinned-image-tags \
    -o jsonpath='{range .status.autogen.rules[*]}{.name}{"\n"}{end}'
autogen-validate-image-tag
autogen-cronjob-validate-image-tag
autogen-require-image-tag
autogen-cronjob-require-image-tag
```

And the kinds each one actually covers — **this is how you discover your version's default controller set**:

```console
$ kubectl get clusterpolicy require-pinned-image-tags -o yaml \
    | yq '.status.autogen.rules[] | {"rule": .name, "kinds": .match.any[0].resources.kinds}'
rule: autogen-validate-image-tag
kinds:
  - DaemonSet
  - Deployment
  - Job
  - StatefulSet
  - ReplicaSet
  - ReplicationController
rule: autogen-cronjob-validate-image-tag
kinds:
  - CronJob
...
```

Inspect the rewritten pattern to confirm the path depth:

```console
$ kubectl get clusterpolicy require-pinned-image-tags -o yaml \
    | yq '.status.autogen.rules[1].validate.pattern'
spec:
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - image: '!*:latest'
```

### 4.3 Confirm the webhook was widened

```console
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules[*].resources}{"\n"}{end}'
validate.kyverno.svc-ignore	[]
validate.kyverno.svc-fail	["cronjobs","daemonsets","deployments","jobs","pods","replicasets","replicationcontrollers","statefulsets"]
```

If `deployments` is missing from that list, autogen did not happen — no amount of policy debugging will help until that is fixed.

### 4.4 Enforcement at the controller level (autogen working)

```console
$ kubectl create deployment web --image=nginx:latest
error: failed to create deployment: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Deployment/default/web was blocked due to the following policies

require-pinned-image-tags:
  autogen-validate-image-tag: 'validation error: The mutable tag '':latest'' is not
    allowed. Pin an immutable tag or, preferably, a digest (image@sha256:...). rule
    autogen-validate-image-tag failed at path /spec/template/spec/containers/0/image/'
```

The user gets an immediate, attributable, actionable error at `kubectl` time. Compare the CronJob path:

```console
$ kubectl create cronjob backup --image=busybox --schedule="0 3 * * *" -- /bin/true
error: failed to create cronjob: admission webhook "validate.kyverno.svc-fail" denied the request:

resource CronJob/default/backup was blocked due to the following policies

require-pinned-image-tags:
  autogen-cronjob-require-image-tag: 'validation error: An explicit image tag or digest
    is required; untagged images resolve to '':latest'' implicitly. rule autogen-cronjob-require-image-tag
    failed at path /spec/jobTemplate/spec/template/spec/containers/0/image/'
```

Different rule name, different path depth — both derived from the same eight-line authored rule.

### 4.5 The counterfactual: autogen disabled

```console
$ kubectl annotate clusterpolicy require-pinned-image-tags \
    pod-policies.kyverno.io/autogen-controllers=none --overwrite
clusterpolicy.kyverno.io/require-pinned-image-tags annotated

$ kubectl create deployment web --image=nginx:latest
deployment.apps/web created                        # <-- admitted!

$ kubectl get deploy,rs,pod -l app=web
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   0/1     0            0           18s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-6f9c7d8b7d   1         0         0       18s

$ kubectl describe rs web-6f9c7d8b7d | tail -12
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  4s (x5 over 18s)   replicaset-controller  Error creating: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/web-6f9c7d8b7d- was blocked due to the following policies

require-pinned-image-tags:
  validate-image-tag: 'validation error: The mutable tag '':latest'' is not allowed.
    Pin an immutable tag or, preferably, a digest (image@sha256:...). rule validate-image-tag
    failed at path /spec/containers/0/image/'
```

This transcript **is** the motivation for the whole feature. `kubectl` reported success, the Deployment exists, `READY 0/1`, and the real error is three `kubectl describe` calls away, attributed to `replicaset-controller`, retrying forever. Restore the annotation:

```console
$ kubectl annotate clusterpolicy require-pinned-image-tags \
    pod-policies.kyverno.io/autogen-controllers- --overwrite
clusterpolicy.kyverno.io/require-pinned-image-tags annotated
```

### 4.6 Offline evaluation with the CLI

```console
$ kyverno version
Version: 1.13.2
Time: 2025-02-11T09:41:03Z
Git commit ID: main/9d1f0a7

$ kyverno apply require-pinned-image-tags.yaml --resource bad-deployment.yaml

Applying 2 policy rule(s) to 1 resource(s)...

policy require-pinned-image-tags -> resource default/Deployment/web failed:
1. autogen-validate-image-tag: validation error: The mutable tag ':latest' is not allowed.
Pin an immutable tag or, preferably, a digest (image@sha256:...). rule autogen-validate-image-tag
failed at path /spec/template/spec/containers/0/image/

pass: 0, fail: 1, warn: 0, error: 0, skip: 3
```

```console
$ kyverno test .

Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 2 policy rule(s) to 4 resource(s) ...
  Checking results ...

│────│───────────────────────────│───────────────────────────────────│─────────────────────────│────────│
│ ID │ POLICY                    │ RULE                              │ RESOURCE                │ RESULT │
│────│───────────────────────────│───────────────────────────────────│─────────────────────────│────────│
│ 1  │ require-pinned-image-tags │ validate-image-tag                │ v1/Pod/bad-pod          │ Pass   │
│ 2  │ require-pinned-image-tags │ autogen-validate-image-tag        │ apps/v1/Deployment/...  │ Pass   │
│ 3  │ require-pinned-image-tags │ autogen-validate-image-tag        │ apps/v1/StatefulSet/... │ Pass   │
│ 4  │ require-pinned-image-tags │ autogen-cronjob-validate-image-tag│ batch/v1/CronJob/...    │ Pass   │
│────│───────────────────────────│───────────────────────────────────│─────────────────────────│────────│

Test Summary: 4 tests passed and 0 tests failed
```

(`RESULT: Pass` here means "the observed outcome matched the `result:` you asserted" — including the asserted `fail`s.)

### 4.7 Background scan reports carry the generated names too

```console
$ kubectl get policyreport -n production -o yaml \
    | yq '.items[].results[] | select(.policy=="require-pinned-image-tags") | {"rule": .rule, "kind": .resources[0].kind, "name": .resources[0].name, "result": .result}'
rule: autogen-validate-image-tag
kind: Deployment
name: legacy-api
result: fail
rule: validate-image-tag
kind: Pod
name: legacy-api-7c8d9f4b6c-x2knp
result: fail
```

Note the **duplicate finding**: the Deployment fails via the generated rule and its Pod fails via the authored rule. That is expected and correct — both objects are non-compliant — but any dashboard that counts raw `fail` results will over-report. Deduplicate by owner reference, or count violations per top-level workload.

---

## 5. Verification and failure diagnosis

### 5.1 Verification ladder

Run these in order; each rung is cheap and each rules out a distinct class of bug.

| # | Question | Command | Expected |
|---|---|---|---|
| 1 | Is the policy accepted and converged? | `kubectl get cpol <name>` | `READY True` |
| 2 | Were rules generated at all? | `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[*].name}'` | Non-empty, `autogen-*` names present |
| 3 | Which kinds are covered? | `yq '.status.autogen.rules[].match.any[0].resources.kinds'` | Your intended set |
| 4 | Is the path depth right? | `yq '.status.autogen.rules[].validate.pattern'` | `spec.template.spec...` / `spec.jobTemplate.spec.template.spec...` |
| 5 | Did the webhook widen? | `kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg -o yaml` | Target resources listed |
| 6 | Does it actually deny? | `kubectl create deployment ... --dry-run=server` | Denied, with an `autogen-*` rule name |
| 7 | Does it regress? | `kyverno test .` in CI | All assertions pass |

### 5.2 Symptom → cause → fix

**Deployment is admitted, Pods never appear, `FailedCreate` in the ReplicaSet events.**
Autogen is off for that policy or for that kind. Check step 2/3 above. Causes: `pod-policies.kyverno.io/autogen-controllers: none`, a restricted list that omits the kind, or the rule matching extra kinds alongside `Pod` (§3.5). Fix the annotation or split the rule.

**`kyverno test` fails with `Not found` on the rule name.**
You asserted the authored rule name against a controller resource. Change to `autogen-<rule>` for standard controllers and `autogen-cronjob-<rule>` for CronJob. This is the single most common CI failure with autogen.

**Policy blocks Deployments but a bare Pod slips through (or vice versa).**
Almost always a hand-written JMESPath/CEL expression referencing `request.object.spec.*`. The autogen rewriter is reliable for declarative `pattern` blocks and fragile for expressions you wrote yourself. Diff the two rule bodies:

```console
$ kubectl get cpol <name> -o yaml | yq '.spec.rules[] | select(.name=="<rule>")' > /tmp/authored.yaml
$ kubectl get cpol <name> -o yaml | yq '.status.autogen.rules[] | select(.name=="autogen-<rule>")' > /tmp/generated.yaml
$ diff -u /tmp/authored.yaml /tmp/generated.yaml
```

Any `request.object.spec.` reference that was **not** rewritten to `request.object.spec.template.spec.` is your bug. Fix by restructuring into a declarative pattern, or by setting `autogen-controllers: none` and authoring the controller rules explicitly.

**A label-selector-based policy matches Pods but not their Deployments.**
`match.any[].resources.selector.matchLabels` is evaluated against the matched object's **own** `metadata.labels`. On a Deployment those are the Deployment's labels, which frequently differ from `spec.template.metadata.labels`. Verify with:

```console
$ kubectl get deploy <name> -o jsonpath='{.metadata.labels}{"\n"}{.spec.template.metadata.labels}{"\n"}'
```

If they differ, either enforce a convention that controllers carry their pod-template labels, or switch to a `namespaceSelector` / `preconditions` on a field that exists at both levels.

**Applying a `mutate` policy triggered a cluster-wide rolling restart.**
Expected and documented behaviour (§1.3, §3.4). The mutation landed in `spec.template.spec`, changing the pod-template hash. Prevention: apply mutate policies with `validationFailureAction`-equivalent staging — deploy in `Audit`/report-only first, review the `PolicyReport`, then enforce in a maintenance window. If a rollout is genuinely unacceptable, set `autogen-controllers: none` and accept Pod-only mutation, understanding that it is not durable in the declared object.

**Webhook latency or timeouts appeared after adding a policy.**
Autogen expanded the webhook to `deployments`, `replicasets`, `jobs`, etc. In a busy cluster, `replicasets` in particular is a high-churn resource. Mitigate by restricting `autogen-controllers` to the kinds users actually submit (typically `Deployment,StatefulSet,DaemonSet,Job,CronJob` — dropping `ReplicaSet`/`ReplicationController`, whose Pods are still covered by the authored Pod rule), and by raising `webhookTimeoutSeconds` only after confirming Kyverno is not resource-starved:

```console
$ kubectl top pods -n kyverno
NAME                                            CPU(cores)   MEMORY(bytes)
kyverno-admission-controller-6d4f8b7c9d-9v2ql   142m         421Mi
kyverno-background-controller-7b6c5d84f-tzq4x   38m          186Mi
kyverno-reports-controller-59f7d6c4b8-hj8wn     91m          512Mi
```

**A custom workload CRD (`Rollout`, `CloneSet`, `SparkApplication`) is not covered.**
Autogen only knows the built-in pod controllers. There is no annotation value that adds a CRD. Write an explicit rule matching that kind with the correct pod-template path — and add a CLI test for it, because nothing will generate or maintain it for you.

**You upgraded Kyverno and coverage changed.**
The default controller set is not a stable API. Pin the behaviour you depend on by writing the list explicitly in the annotation, and assert coverage in CI:

```console
$ kubectl get cpol -o json \
  | jq -r '.items[] | select(.status.autogen.rules != null)
           | .metadata.name as $p
           | .status.autogen.rules[]
           | "\($p)\t\(.name)\t\(.match.any[0].resources.kinds | join(","))"' \
  | column -t
require-pinned-image-tags  autogen-validate-image-tag          DaemonSet,Deployment,Job,StatefulSet,ReplicaSet,ReplicationController
require-pinned-image-tags  autogen-cronjob-validate-image-tag  CronJob
require-nonroot-runtime    autogen-check-runasnonroot          Deployment,StatefulSet,Job
require-nonroot-runtime    autogen-cronjob-check-runasnonroot  CronJob
```

Snapshot that output and diff it on every Kyverno upgrade. It is the cheapest possible regression test for policy coverage.

### 5.3 A note on the CEL-based policy types

Recent Kyverno releases introduce CEL-native policy kinds (`ValidatingPolicy`, `ImageValidatingPolicy`, `MutatingPolicy`, …) aligned with upstream `ValidatingAdmissionPolicy`. These do **not** use the `pod-policies.kyverno.io/autogen-controllers` annotation; autogen is a first-class field in the spec, roughly:

```yaml
spec:
  autogen:
    podControllers:
      controllers:
        - deployments
        - cronjobs
```

The API group and field layout for these types are still evolving. Do not author against them from memory — confirm on your cluster before relying on it:

```console
$ kubectl api-resources | grep -i policies.kyverno.io
$ kubectl explain validatingpolicy.spec.autogen --recursive
```

For the KCA exam, the `kyverno.io/v1` `ClusterPolicy` annotation-driven model described above is the primary subject matter.

---

## Referencias

- Kyverno — Auto-Gen Rules for Pod Controllers: https://kyverno.io/docs/writing-policies/autogen/
- Kyverno — Documentation index (the autogen page moves between the *Writing Policies* and *Policy Types → ClusterPolicy* sections across releases; use the version selector): https://kyverno.io/docs/
- Kyverno — Policy definition and rule structure: https://kyverno.io/docs/writing-policies/
- Kyverno — Validate rules: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Mutate rules: https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — Verify Images: https://kyverno.io/docs/writing-policies/verify-images/
- Kyverno CLI — `apply`: https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno CLI — `test`: https://kyverno.io/docs/kyverno-cli/usage/test/
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno — Sample policy library (every pod-level policy there relies on autogen): https://kyverno.io/policies/
- Kyverno — autogen implementation, source of truth for the default controller set and rewriting logic: https://github.com/kyverno/kyverno/tree/main/pkg/autogen
- Kyverno — release notes (autogen defaults have changed across minors): https://github.com/kyverno/kyverno/releases
- Kubernetes — Deployments and the Deployment → ReplicaSet → Pod chain: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — CronJob and the `jobTemplate` nesting: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes — Dynamic Admission Control (webhook rules, failure policy, timeouts): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- CNCF — Kyverno Certified Associate (KCA) curriculum: https://github.com/cncf/curriculum