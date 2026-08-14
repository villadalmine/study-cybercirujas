# 5.2 Preconditions — Guided Exercises

> **Exam weight:** 2.91% · **Certification:** Kyverno Certified Associate (KCA) · **Curriculum:** <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
>
> These exercises are hands-on. Every step is meant to be typed into a real cluster. Do not skip the *predict-before-you-run* prompts — preconditions fail silently by design (a false precondition produces `skip`, not `fail`), so the only way to build reliable intuition is to observe the difference between "my rule passed" and "my rule never ran".

---

## What a precondition actually is

A **precondition** is a gate on a single rule. It is evaluated *after* `match`/`exclude` have selected the resource and *after* the rule's `context` has been resolved, and *before* the rule body (`validate`, `mutate`, `generate`, `verifyImages`) executes.

```
AdmissionRequest
      │
      ▼
[ API server ]  ── webhook rules are built from match/exclude ONLY ──▶ [ Kyverno ]
                                                                          │
                                                            ┌─────────────┴──────────────┐
                                                            │ per rule:                  │
                                                            │  1. match / exclude        │
                                                            │  2. context (ConfigMap,    │
                                                            │     API call, image data)  │
                                                            │  3. variable substitution  │
                                                            │  4. PRECONDITIONS  ────────┼──▶ false ⇒ rule SKIPPED
                                                            │  5. rule body              │
                                                            └────────────────────────────┘
```

Syntax (`spec.rules[].preconditions`):

```yaml
preconditions:
  any:            # logical OR  — at least one entry must be true
    - key: <expression or literal>
      operator: <Operator>
      value: <scalar | list | map>
  all:            # logical AND — every entry must be true
    - key: ...
      operator: ...
      value: ...
```

If **both** `any` and `all` are present, the block is true when `OR(any) AND AND(all)`.

**Operators you must know for the exam**

| Operator | Semantics | Accepts |
|---|---|---|
| `Equals` / `NotEquals` | scalar equality | string, number, bool |
| `AnyIn` | at least one element of `key` is in `value` | scalar or list vs list |
| `AllIn` | every element of `key` is in `value` | scalar or list vs list |
| `AnyNotIn` | at least one element of `key` is **not** in `value` | scalar or list vs list |
| `AllNotIn` | no element of `key` is in `value` | scalar or list vs list |
| `GreaterThan`, `GreaterThanOrEquals`, `LessThan`, `LessThanOrEquals` | ordered comparison | numbers and Kubernetes quantities (`512Mi`, `2Gi`, `500m`) |
| `DurationGreaterThan`, `DurationGreaterThanOrEquals`, `DurationLessThan`, `DurationLessThanOrEquals` | ordered comparison | Go durations (`30m`, `24h`) or seconds as a number |

Reference: <https://kyverno.io/docs/writing-policies/preconditions/> and <https://kyverno.io/docs/writing-policies/jmespath/>

> **Version note.** Every policy below uses the rule-scoped field `validate.failureAction` (Kyverno 1.12+). If you are on 1.11 or older, delete that line and add `validationFailureAction: Enforce` directly under `spec:`. Everything else is unchanged.

---

## Exercise 0 — Build the lab

**Steps**

1. Create a cluster (skip if you already have one you can break):

```bash
kind create cluster --name kca-lab --image kindest/node:v1.32.0
```

2. Install Kyverno:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=300s
```

3. Record the exact version you are running — precondition field names and error strings changed across minors:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

```text
ghcr.io/kyverno/kyverno:v1.13.4
```

4. Install the matching CLI (used from Exercise 7 onwards):

```bash
curl -sSLO https://github.com/kyverno/kyverno/releases/download/v1.13.4/kyverno-cli_v1.13.4_linux_x86_64.tar.gz
tar -xzf kyverno-cli_v1.13.4_linux_x86_64.tar.gz kyverno
sudo install -m 0755 kyverno /usr/local/bin/kyverno
kyverno version
```

```text
Version: v1.13.4
Time: 2025-01-30T12:04:11Z
Git commit ID: 8e9a...
```

5. Confirm which controllers are running, and create the lab namespace:

```bash
kubectl -n kyverno get deploy
kubectl create namespace kca-preconditions
```

```text
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    1/1     1            1           2m
kyverno-background-controller   1/1     1            1           2m
kyverno-cleanup-controller      1/1     1            1           2m
kyverno-reports-controller      1/1     1            1           2m
namespace/kca-preconditions created
```

**Questions**

- **Q0.1** Four controllers were installed. Which one evaluates a precondition when you run `kubectl apply`, and which one evaluates the *same* precondition during a background scan?
- **Q0.2** Why does it matter that the CLI minor version matches the cluster's Kyverno version when you are testing preconditions?

---

## Exercise 1 — Your first precondition: `skip` is not `pass`

You will require a `team` label, **but only** on Pods that carry `tier: backend`.

**Steps**

6. Write the policy:

```yaml
# 01-backend-requires-team.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: backend-requires-team
spec:
  background: false
  rules:
    - name: check-team-on-backend
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-preconditions
              operations:
                - CREATE
                - UPDATE
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.tier || '' }}"
            operator: Equals
            value: backend
      validate:
        failureAction: Enforce
        message: >-
          Pods labelled tier=backend must also carry a non-empty team label.
        pattern:
          metadata:
            labels:
              team: "?*"
```

7. Apply it and wait until it is ready:

```bash
kubectl apply -f 01-backend-requires-team.yaml
kubectl get cpol backend-requires-team
```

```text
clusterpolicy.kyverno.io/backend-requires-team created
NAME                    ADMISSION   BACKGROUND   READY   AGE   MESSAGE
backend-requires-team   true        false        True    5s    Ready
```

8. Create three Pods that exercise the three possible paths:

```yaml
# 01-pods.yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-backend
  namespace: kca-preconditions
  labels:
    tier: backend
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
---
apiVersion: v1
kind: Pod
metadata:
  name: web-frontend
  namespace: kca-preconditions
  labels:
    tier: frontend
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
---
apiVersion: v1
kind: Pod
metadata:
  name: unlabelled
  namespace: kca-preconditions
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
```

9. **Predict first**, then apply:

```bash
kubectl apply -f 01-pods.yaml
```

```text
Error from server: error when creating "01-pods.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/kca-preconditions/api-backend was blocked due to the following policies

backend-requires-team:
  check-team-on-backend: 'validation error: Pods labelled tier=backend must also carry
    a non-empty team label. rule check-team-on-backend failed at path /metadata/labels/team/'
pod/web-frontend created
pod/unlabelled created
```

10. Prove *why* the other two were admitted. `web-frontend` and `unlabelled` did not "pass" the rule — the rule never ran. Ask Kyverno directly, with a server-side dry run so nothing is persisted:

```bash
kubectl -n kca-preconditions run probe --image=registry.k8s.io/pause:3.10 \
  --labels tier=frontend --dry-run=server -o name
```

```text
pod/probe
```

11. Now fix the offending Pod and confirm the rule really is evaluating:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: api-backend
  namespace: kca-preconditions
  labels:
    tier: backend
    team: payments
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
EOF
kubectl -n kca-preconditions get pods --show-labels
```

```text
pod/api-backend created
NAME           READY   STATUS    RESTARTS   AGE   LABELS
api-backend    1/1     Running   0          4s    team=payments,tier=backend
unlabelled     1/1     Running   0          62s   <none>
web-frontend   1/1     Running   0          62s   tier=frontend
```

**Questions**

- **Q1.1** Three Pods went through the same policy. Classify each one as *pass*, *fail*, or *skip*, and state which field of the AdmissionReview decided it.
- **Q1.2** `kubectl apply` returned a non-zero exit status, yet two Pods exist. Explain the mechanism.
- **Q1.3** The precondition key is `{{ request.object.metadata.labels.tier || '' }}`. What does the `|| ''` do, and against which of the three Pods does it matter?
- **Q1.4** Rewrite this rule so it needs **no** precondition at all. What capability do you lose by doing so?

---

## Exercise 2 — The classic outage: an unguarded variable

This is the single most common production incident caused by preconditions. You will reproduce it deliberately.

**Steps**

12. Remove the JMESPath default from the precondition:

```bash
kubectl patch cpol backend-requires-team --type=json -p='[
  {"op":"replace",
   "path":"/spec/rules/0/preconditions/all/0/key",
   "value":"{{ request.object.metadata.labels.tier }}"}
]'
```

```text
clusterpolicy.kyverno.io/backend-requires-team patched
```

13. **Predict first:** what happens to a Pod with *no labels at all*? It has nothing to do with `tier=backend`, so intuitively it should be untouched. Test it:

```bash
kubectl -n kca-preconditions run canary --image=registry.k8s.io/pause:3.10 --dry-run=server
```

```text
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/kca-preconditions/canary was blocked due to the following policies

backend-requires-team:
  check-team-on-backend: 'failed to substitute variables in preconditions: failed to
    resolve request.object.metadata.labels.tier at path /0/key'
```

*(The exact wording varies by minor version; the shape — a substitution/resolution error surfacing as a denial — does not.)*

14. Confirm the blast radius is the whole `match` block, not just backend Pods:

```bash
kubectl -n kca-preconditions run canary2 --image=registry.k8s.io/pause:3.10 \
  --labels app=unrelated --dry-run=server
```

```text
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
...
```

15. Inspect what Kyverno logged while this was happening:

```bash
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=40 \
  | grep -i -E 'precondition|substitut|backend-requires-team'
```

16. Restore the guard:

```bash
kubectl patch cpol backend-requires-team --type=json -p='[
  {"op":"replace",
   "path":"/spec/rules/0/preconditions/all/0/key",
   "value":"{{ request.object.metadata.labels.tier || '"''"' }}"}
]'
kubectl -n kca-preconditions run canary3 --image=registry.k8s.io/pause:3.10 --dry-run=server -o name
```

```text
clusterpolicy.kyverno.io/backend-requires-team patched
pod/canary3
```

17. Now the production-safety lesson. Set the rule to `Audit` and repeat the broken patch — observe how the same defect degrades instead of denying:

```bash
kubectl patch cpol backend-requires-team --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Audit"}
]'
```

Then restore `Enforce` when you are done experimenting.

**Questions**

- **Q2.1** Why does an unresolvable variable *inside a precondition* affect Pods that the precondition was never meant to select?
- **Q2.2** You have a precondition block with two `all` entries. The first is `false`. The second references a path that does not exist on this object. Is it safe to rely on the first entry short-circuiting the second? Justify your answer in terms of when variable substitution happens.
- **Q2.3** Give three distinct ways to make a precondition key safe against a missing path, and say when each is preferable.
- **Q2.4** Your rule is in `Enforce`. What single change makes a substitution defect non-blocking while you debug it in production, and what do you lose?

---

## Exercise 3 — `any`, `all`, and the combined truth table

**Steps**

18. Write a rule that runs only for workloads that are `env=prod` **or** `env=staging`, **and** are `tier=backend`:

```yaml
# 03-cost-center.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-cost-center
spec:
  background: false
  rules:
    - name: cost-center-on-regulated-backends
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-preconditions
              operations:
                - CREATE
                - UPDATE
      preconditions:
        any:
          - key: "{{ request.object.metadata.labels.env || '' }}"
            operator: Equals
            value: prod
          - key: "{{ request.object.metadata.labels.env || '' }}"
            operator: Equals
            value: staging
        all:
          - key: "{{ request.object.metadata.labels.tier || '' }}"
            operator: Equals
            value: backend
      validate:
        failureAction: Enforce
        message: >-
          Backend Pods in prod/staging must carry the annotation cost-center.
        pattern:
          metadata:
            annotations:
              cost-center: "?*"
```

19. Apply, then run the truth table. Use `--dry-run=server` so you can iterate quickly:

```bash
kubectl apply -f 03-cost-center.yaml

for spec in "prod backend" "dev backend" "prod frontend" "staging backend"; do
  set -- $spec
  echo "--- env=$1 tier=$2"
  kubectl -n kca-preconditions run "tt-$1-$2" --image=registry.k8s.io/pause:3.10 \
    --labels "env=$1,tier=$2" --dry-run=server -o name 2>&1 | tail -3
done
```

```text
--- env=prod tier=backend
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
...
  cost-center-on-regulated-backends: 'validation error: Backend Pods in prod/staging
    must carry the annotation cost-center. rule ... failed at path /metadata/annotations/'
--- env=dev tier=backend
pod/tt-dev-backend
--- env=prod tier=frontend
pod/tt-prod-frontend
--- env=staging tier=backend
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
...
```

20. Collapse the two `any` entries into one using `AnyIn`, and confirm the behaviour is identical:

```bash
kubectl patch cpol require-cost-center --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/preconditions/any","value":[
    {"key":"{{ request.object.metadata.labels.env || '"''"' }}",
     "operator":"AnyIn",
     "value":["prod","staging"]}
  ]}
]'
kubectl -n kca-preconditions run tt2 --image=registry.k8s.io/pause:3.10 \
  --labels env=staging,tier=backend --dry-run=server 2>&1 | tail -2
```

**Questions**

- **Q3.1** Write out the boolean expression Kyverno evaluates when both `any` and `all` are present.
- **Q3.2** What does an **empty** `any: []` list evaluate to? And an empty `all: []`? Why is that asymmetry the sane default?
- **Q3.3** In step 20 the key is a *scalar* and the value is a *list*. Under `AnyIn`, what does that mean? How would the answer change if the key resolved to a list of three labels?
- **Q3.4** Give a concrete case where `AnyIn` and `AllIn` produce different results for the same key/value pair.

---

## Exercise 4 — Operators over lists, quantities, and the `images` variable

**Steps**

21. Registry allowlisting through a precondition — note that the *precondition* decides whether the rule fires, and the rule body does the denying:

```yaml
# 04-registry.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: flag-external-registries
spec:
  background: false
  rules:
    - name: external-registry-needs-exception-annotation
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-preconditions
              operations:
                - CREATE
                - UPDATE
      preconditions:
        all:
          - key: "{{ images.containers.*.registry }}"
            operator: AnyNotIn
            value:
              - registry.k8s.io
              - ghcr.io
      validate:
        failureAction: Enforce
        message: >-
          This Pod pulls from a registry outside the allowlist
          ({{ images.containers.*.registry }}). Add the annotation
          registry-exception with a ticket ID.
        pattern:
          metadata:
            annotations:
              registry-exception: "?*"
```

22. Apply and test three Pods:

```bash
kubectl apply -f 04-registry.yaml

kubectl -n kca-preconditions run ok-img --image=registry.k8s.io/pause:3.10 \
  --dry-run=server -o name
kubectl -n kca-preconditions run bad-img --image=docker.io/library/busybox:1.37 \
  --dry-run=server 2>&1 | tail -3
kubectl -n kca-preconditions run short-img --image=busybox:1.37 \
  --dry-run=server 2>&1 | tail -3
```

```text
pod/ok-img
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
...
  external-registry-needs-exception-annotation: 'validation error: This Pod pulls from
    a registry outside the allowlist (["docker.io"]). ...'
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
...
  external-registry-needs-exception-annotation: 'validation error: This Pod pulls from
    a registry outside the allowlist (["docker.io"]). ...'
```

Note that the bare `busybox:1.37` and the fully-qualified `docker.io/library/busybox:1.37` behave identically — that is the whole point of using the `images` context variable rather than the raw string.

23. Quantity comparison. Guard first, compare second:

```yaml
# 04-bigmem.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: large-memory-needs-approval
spec:
  background: false
  rules:
    - name: over-2gi-needs-approval
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-preconditions
              operations:
                - CREATE
                - UPDATE
      preconditions:
        all:
          - key: "{{ request.object.spec.containers[0].resources.limits.memory || '' }}"
            operator: NotEquals
            value: ""
          - key: "{{ request.object.spec.containers[0].resources.limits.memory || '0Mi' }}"
            operator: GreaterThan
            value: 2Gi
      validate:
        failureAction: Enforce
        message: "Memory limits above 2Gi require the annotation capacity-approved."
        pattern:
          metadata:
            annotations:
              capacity-approved: "?*"
```

24. Test the boundary:

```bash
kubectl apply -f 04-bigmem.yaml

kubectl -n kca-preconditions apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: mem-small, namespace: kca-preconditions}
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
      resources: {limits: {memory: 1536Mi}}
EOF

kubectl -n kca-preconditions apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: mem-big, namespace: kca-preconditions}
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
      resources: {limits: {memory: 4Gi}}
EOF
```

```text
pod/mem-small created (server dry run)
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
...
  over-2gi-needs-approval: 'validation error: Memory limits above 2Gi require the
    annotation capacity-approved. ...'
```

**Questions**

- **Q4.1** The key `{{ images.containers.*.registry }}` resolves to a **list**. With `AnyNotIn`, exactly when is the precondition true for a Pod with three containers?
- **Q4.2** Change `AnyNotIn` to `AllNotIn` in step 21. For which Pods does the behaviour change, and what security property does each variant give you?
- **Q4.3** Why does `element.image` / `spec.containers[0].image` give a different answer from `images.containers.*.registry` for `busybox:1.37`?
- **Q4.4** The first `all` entry in step 23 looks redundant next to the `|| '0Mi'` default. It is not. What failure does it prevent?
- **Q4.5** `1536Mi` vs `2Gi`: which is larger, and how is Kyverno comparing them — as strings, floats, or something else?
- **Q4.6** Why is a `GreaterThan` precondition on `resources.limits` a fragile way to express "big Pods need approval" for a Pod with several containers? What would you use instead?

---

## Exercise 5 — Request context: `operation`, `oldObject`, and `deny` conditions

Preconditions can read the *request*, not just the object. This is where they do work `match` cannot.

**Steps**

25. Make the `team` label immutable — but only for Pods that already had one:

```yaml
# 05-immutable-team.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: protect-team-label
spec:
  background: false
  rules:
    - name: no-team-label-change
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-preconditions
              operations:
                - UPDATE
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: UPDATE
          - key: "{{ request.oldObject.metadata.labels.team || '' }}"
            operator: NotEquals
            value: ""
      validate:
        failureAction: Enforce
        message: >-
          The team label is immutable once set
          (was "{{ request.oldObject.metadata.labels.team }}",
          got "{{ request.object.metadata.labels.team || '<removed>' }}").
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.labels.team || '' }}"
                operator: NotEquals
                value: "{{ request.oldObject.metadata.labels.team }}"
```

26. Apply and exercise all four paths against Pods created earlier:

```bash
kubectl apply -f 05-immutable-team.yaml

# a) unrelated change on a Pod that HAS the label -> rule runs, deny false -> allowed
kubectl -n kca-preconditions annotate pod api-backend owner=sre --overwrite

# b) change the value -> rule runs, deny true -> blocked
kubectl -n kca-preconditions label pod api-backend team=platform --overwrite

# c) remove the label -> rule runs, deny true -> blocked
kubectl -n kca-preconditions label pod api-backend team-

# d) Pod that never had the label -> precondition false -> rule skipped
kubectl -n kca-preconditions label pod web-frontend team=platform
```

```text
pod/api-backend annotated
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/kca-preconditions/api-backend was blocked due to the following policies

protect-team-label:
  no-team-label-change: 'The team label is immutable once set (was "payments", got
    "platform").'
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
...
  no-team-label-change: 'The team label is immutable once set (was "payments", got
    "<removed>").'
pod/web-frontend labeled
```

27. Now the subtle one. Delete the Pod and watch what the `operations: [UPDATE]` match buys you:

```bash
kubectl -n kca-preconditions delete pod api-backend
```

```text
pod "api-backend" deleted
```

28. Deliberately break it: widen the match to all operations and observe why the `request.operation` precondition earns its place.

```bash
kubectl patch cpol protect-team-label --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/match/any/0/resources/operations",
   "value":["CREATE","UPDATE","DELETE"]}
]'
kubectl -n kca-preconditions delete pod web-frontend
```

**Questions**

- **Q5.1** State the division of labour between `preconditions` and `validate.deny.conditions` in this rule. Both use identical `any`/`all` syntax — what makes them different?
- **Q5.2** On a `DELETE`, which of `request.object` and `request.oldObject` is populated? What would `{{ request.object.metadata.labels.team }}` do without a default?
- **Q5.3** The rule already restricts `operations: [UPDATE]` in `match`. Is the `request.operation Equals UPDATE` precondition therefore dead code? Argue both sides, then commit to a recommendation.
- **Q5.4** Case (d) allowed a `team` label to be *added* to a Pod that had none. Is that the intended semantics of "immutable"? How would you change the precondition to also forbid adding it after creation?
- **Q5.5** This policy sets `background: false`. What breaks if you set it to `true`?

---

## Exercise 6 — Preconditions inside `foreach`

A `foreach` block gets its **own** precondition scope, evaluated once per element. This is how you exempt sidecars.

**Steps**

29. Write a per-container registry check that skips service-mesh sidecars:

```yaml
# 06-foreach.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: per-container-registry
spec:
  background: false
  rules:
    - name: app-containers-from-allowlist
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-preconditions
              operations:
                - CREATE
                - UPDATE
      validate:
        failureAction: Enforce
        message: >-
          Container "{{ element.name }}" uses image "{{ element.image }}",
          which is not from registry.k8s.io.
        foreach:
          - list: "request.object.spec.containers"
            preconditions:
              all:
                - key: "{{ element.name }}"
                  operator: AllNotIn
                  value:
                    - istio-proxy
                    - linkerd-proxy
            deny:
              conditions:
                all:
                  - key: "{{ starts_with(element.image, 'registry.k8s.io/') }}"
                    operator: Equals
                    value: false
```

30. Apply, then test a Pod whose *sidecar* violates the rule but whose app container does not:

```bash
kubectl apply -f 06-foreach.yaml

kubectl -n kca-preconditions apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: meshed, namespace: kca-preconditions}
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
    - name: istio-proxy          # stand-in image for the lab
      image: docker.io/library/busybox:1.37
      command: ["sleep", "3600"]
EOF
```

```text
pod/meshed created (server dry run)
```

31. Now flip it — the app container violates, the sidecar is clean:

```bash
kubectl -n kca-preconditions apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: meshed-bad, namespace: kca-preconditions}
spec:
  containers:
    - name: app
      image: docker.io/library/busybox:1.37
      command: ["sleep", "3600"]
    - name: istio-proxy
      image: docker.io/library/busybox:1.37
      command: ["sleep", "3600"]
EOF
```

```text
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/kca-preconditions/meshed-bad was blocked due to the following policies

per-container-registry:
  app-containers-from-allowlist: 'Container "app" uses image
    "docker.io/library/busybox:1.37", which is not from registry.k8s.io.'
```

32. Test the empty-list edge. `initContainers` is absent on both Pods above — add a second `foreach` entry over `request.object.spec.initContainers` and re-apply:

```bash
kubectl patch cpol per-container-registry --type=json -p='[
  {"op":"add","path":"/spec/rules/0/validate/foreach/-","value":{
    "list":"request.object.spec.initContainers",
    "deny":{"conditions":{"all":[
      {"key":"{{ starts_with(element.image, '"'"'registry.k8s.io/'"'"') }}",
       "operator":"Equals","value":false}]}}}}
]'
kubectl -n kca-preconditions run noinit --image=registry.k8s.io/pause:3.10 --dry-run=server -o name
```

```text
clusterpolicy.kyverno.io/per-container-registry patched
pod/noinit
```

**Questions**

- **Q6.1** How many times is the `foreach` precondition evaluated for the `meshed` Pod, and what is `{{ element }}` bound to each time?
- **Q6.2** Could you have expressed the sidecar exemption in a *rule-level* precondition instead? What exactly would you lose?
- **Q6.3** The `deny` condition compares a JMESPath function result to the YAML boolean `false`. Rewrite the same check using `AllNotIn` over `images.containers.*.registry` and explain which version you would ship, and why.
- **Q6.4** In step 32 the second `foreach` entry has **no** precondition and iterates a list that does not exist on the Pod. Why is that not an error?
- **Q6.5** A Pod has two containers; the first fails and the second passes. Does Kyverno evaluate the second element? Does the answer change between `validate.foreach` and `mutate.foreach`?

---

## Exercise 7 — Testing preconditions offline with the CLI

The CLI is the fastest feedback loop, and the exam expects fluency with it. Crucially, it is the only place where you can *see* `skip` counted explicitly.

**Steps**

33. Create a working directory with a policy that uses a **duration** precondition — something you cannot easily trigger at admission time, because `creationTimestamp` is not set on a `CREATE`:

```bash
mkdir -p ~/kca-52 && cd ~/kca-52
```

```yaml
# ~/kca-52/policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: stale-pods-need-owner
spec:
  background: true
  rules:
    - name: pods-older-than-24h-need-owner
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ time_since('', '{{ request.object.metadata.creationTimestamp }}', '') }}"
            operator: DurationGreaterThan
            value: 24h
      validate:
        failureAction: Audit
        message: "Pods older than 24h must carry the annotation owner."
        pattern:
          metadata:
            annotations:
              owner: "?*"
```

```yaml
# ~/kca-52/resources.yaml
apiVersion: v1
kind: Pod
metadata:
  name: ancient-no-owner
  namespace: default
  creationTimestamp: "2024-01-01T00:00:00Z"
spec:
  containers: [{name: app, image: registry.k8s.io/pause:3.10}]
---
apiVersion: v1
kind: Pod
metadata:
  name: ancient-with-owner
  namespace: default
  creationTimestamp: "2024-01-01T00:00:00Z"
  annotations: {owner: sre@example.com}
spec:
  containers: [{name: app, image: registry.k8s.io/pause:3.10}]
---
apiVersion: v1
kind: Pod
metadata:
  name: fresh
  namespace: default
  creationTimestamp: "2026-08-13T09:00:00Z"
spec:
  containers: [{name: app, image: registry.k8s.io/pause:3.10}]
```

34. Run it:

```bash
kyverno apply policy.yaml --resource resources.yaml
```

```text
Applying 1 policy rule(s) to 3 resource(s)...

policy stale-pods-need-owner -> resource default/Pod/ancient-no-owner failed:
1. pods-older-than-24h-need-owner: validation error: Pods older than 24h must carry
   the annotation owner. rule pods-older-than-24h-need-owner failed at path
   /metadata/annotations/

pass: 1, fail: 1, warn: 0, error: 0, skip: 1
```

*(Formatting differs slightly across CLI minors; the `pass/fail/warn/error/skip` tally does not.)*

35. Get the machine-readable form — this is what you would assert on in CI:

```bash
kyverno apply policy.yaml --resource resources.yaml --policy-report -o report.yaml
grep -E 'result:|name:' report.yaml | head -20
```

36. Freeze the behaviour in a test suite. Note that the third Pod's expected result is `skip`:

```yaml
# ~/kca-52/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: preconditions-suite
policies:
  - policy.yaml
resources:
  - resources.yaml
results:
  - policy: stale-pods-need-owner
    rule: pods-older-than-24h-need-owner
    kind: Pod
    resources: [ancient-no-owner]
    result: fail
  - policy: stale-pods-need-owner
    rule: pods-older-than-24h-need-owner
    kind: Pod
    resources: [ancient-with-owner]
    result: pass
  - policy: stale-pods-need-owner
    rule: pods-older-than-24h-need-owner
    kind: Pod
    resources: [fresh]
    result: skip
```

```bash
kyverno test .
```

```text
Loading test  ( kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 3 resources ...
  Checking results ...

│───│───────────────────────│──────────────────────────────────│────────────────────────────│────────│
│ # │ POLICY                │ RULE                             │ RESOURCE                   │ RESULT │
│───│───────────────────────│──────────────────────────────────│────────────────────────────│────────│
│ 1 │ stale-pods-need-owner │ pods-older-than-24h-need-owner    │ default/Pod/ancient-no-... │ Pass   │
│ 2 │ stale-pods-need-owner │ pods-older-than-24h-need-owner    │ default/Pod/ancient-wit... │ Pass   │
│ 3 │ stale-pods-need-owner │ pods-older-than-24h-need-owner    │ default/Pod/fresh          │ Pass   │
│───│───────────────────────│──────────────────────────────────│────────────────────────────│────────│

Test Summary: 3 tests passed and 0 tests failed
```

37. Break one assertion on purpose — change `result: skip` to `result: pass` for `fresh` and re-run. Read the failure output carefully.

38. Optional, if your CLI supports it: exercise a `request.userInfo` precondition offline.

```yaml
# ~/kca-52/user-info.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: UserInfo
metadata:
  name: dev-user
clusterRoles:
  - view
userInfo:
  username: dev@example.com
  groups:
    - system:authenticated
```

```bash
kyverno apply policy.yaml --resource resources.yaml --userinfo user-info.yaml
```

**Questions**

- **Q7.1** In step 34, one resource was counted as `skip`. Which one, and which precondition entry produced that outcome?
- **Q7.2** In the `kyverno test` table, row 3 says `Pass` while the expected result in the file is `skip`. What is the `RESULT` column actually reporting?
- **Q7.3** The precondition key nests `{{ }}` inside a JMESPath function call. Explain the two-stage evaluation that makes this work.
- **Q7.4** Why can this policy not be meaningfully tested by creating a Pod in a live cluster with `kubectl apply`?
- **Q7.5** This policy sets `background: true`. Given what the precondition reads, is that correct? What would happen to the `skip`/`fail` distribution during a background scan a week from now?

---

## Exercise 8 — Background mode: the variables preconditions may not use

**Steps**

39. Try to install a policy whose precondition depends on the identity of the requester, leaving `background` at its default (`true`):

```yaml
# 08-sa-guard.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ci-serviceaccount-guard
spec:
  rules:
    - name: only-ci-may-skip-probes
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kca-preconditions
              operations:
                - CREATE
      preconditions:
        all:
          - key: "{{ request.userInfo.username || '' }}"
            operator: AnyNotIn
            value:
              - system:serviceaccount:ci:builder
      validate:
        failureAction: Enforce
        message: "Only the CI service account may create Pods without a readinessProbe."
        pattern:
          spec:
            containers:
              - readinessProbe:
                  "?*": "?*"
```

```bash
kubectl apply -f 08-sa-guard.yaml
```

```text
Error from server: error when creating "08-sa-guard.yaml": admission webhook
"validate-policy.kyverno.svc" denied the request: spec.rules[0]: variable
"request.userInfo.username" is not allowed in background mode. Set spec.background=false
to disable background mode for this policy rule.
```

*(Exact phrasing varies by version; the constraint does not.)*

40. Fix it and re-apply:

```bash
sed -i 's/^spec:/spec:\n  background: false/' 08-sa-guard.yaml
kubectl apply -f 08-sa-guard.yaml
kubectl get cpol ci-serviceaccount-guard
```

```text
clusterpolicy.kyverno.io/ci-serviceaccount-guard created
NAME                      ADMISSION   BACKGROUND   READY   AGE   MESSAGE
ci-serviceaccount-guard   true        false        True    3s    Ready
```

41. Confirm the rule fires for *you* (a human user, not the CI SA):

```bash
kubectl -n kca-preconditions run noprobe --image=registry.k8s.io/pause:3.10 --dry-run=server 2>&1 | tail -3
```

42. Inspect what reports exist, and note which policies contributed:

```bash
kubectl get polr -n kca-preconditions -o json \
  | jq -r '.items[].results[] | [.policy, .rule, .result] | @tsv' | sort | uniq -c
```

```text
      2 backend-requires-team	check-team-on-backend	skip
      1 require-cost-center	cost-center-on-regulated-backends	skip
```

43. Now the autogen interaction. Install a Pod-level precondition policy with background enabled, and read the rules Kyverno generated for controllers:

```yaml
# 08-autogen.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: autogen-demo
spec:
  rules:
    - name: backend-needs-team
      match:
        any:
          - resources:
              kinds: [Pod]
              operations: [CREATE, UPDATE]
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.tier || '' }}"
            operator: Equals
            value: backend
      validate:
        failureAction: Audit
        message: "backend Pods need a team label"
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f 08-autogen.yaml
kubectl get cpol autogen-demo -o jsonpath='{.status.autogen.rules}' | jq -r '.[].preconditions'
```

```text
{
  "all": [
    {
      "key": "{{ request.object.spec.template.metadata.labels.tier || '' }}",
      "operator": "Equals",
      "value": "backend"
    }
  ]
}
```

44. Verify the consequence with a Deployment whose *own* labels say `tier: backend` but whose **pod template** does not:

```bash
kubectl -n kca-preconditions create deployment trap --image=registry.k8s.io/pause:3.10
kubectl -n kca-preconditions label deployment trap tier=backend
kubectl get polr -n kca-preconditions -o json \
  | jq -r '.items[].results[] | select(.policy=="autogen-demo") | [.rule,.result] | @tsv'
```

**Questions**

- **Q8.1** Why does Kyverno reject `request.userInfo` in a background-enabled policy instead of just evaluating it as empty?
- **Q8.2** List the request-scoped variables that force `background: false`. What do they all have in common?
- **Q8.3** After step 40, the policy is admission-only. Name two concrete capabilities you gave up.
- **Q8.4** In step 43, autogen rewrote the precondition path. Explain the rewrite rule it applied, and predict the result for the Deployment in step 44.
- **Q8.5** Your team wants both behaviours: block at admission based on the requester, *and* report on pre-existing violations. Design the policy layout that achieves this.

---

## Exercise 9 — Where preconditions sit in the admission path (and where they cost you)

**Steps**

45. Look at the webhook configuration Kyverno maintains:

```bash
kubectl get validatingwebhookconfiguration | grep kyverno
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules[*].resources}{"\n"}{end}'
```

```text
kyverno-policy-validating-webhook-cfg     ...
kyverno-resource-validating-webhook-cfg   ...
validate.kyverno.svc-fail	["pods","deployments",...]
validate.kyverno.svc-ignore	[...]
```

46. Search that YAML for any trace of your precondition expressions:

```bash
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o yaml \
  | grep -c 'tier' || echo "no precondition content in the webhook config"
```

```text
no precondition content in the webhook config
```

47. Narrow the `match` of one policy to a namespace selector, and re-read the webhook:

```bash
kubectl label namespace kca-preconditions kyverno-lab=true
kubectl patch cpol backend-requires-team --type=json -p='[
  {"op":"add","path":"/spec/rules/0/match/any/0/resources/namespaceSelector",
   "value":{"matchLabels":{"kyverno-lab":"true"}}}
]'
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o yaml \
  | grep -A4 namespaceSelector | head -20
```

48. Measure the latency Kyverno adds, and correlate it with rule count:

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
sleep 2
curl -s localhost:8000/metrics | grep -E '^kyverno_admission_review_duration_seconds_count|^kyverno_policy_results_total' | head
kill %1
```

**Questions**

- **Q9.1** A precondition rejects 99% of the requests your rule sees. Does that reduce API-server → Kyverno network traffic? Explain using what you saw in step 46.
- **Q9.2** Give the decision rule you would teach a colleague: which selection logic belongs in `match`/`exclude`, and which belongs in `preconditions`? Name at least two things `match` cannot express.
- **Q9.3** Kyverno also supports `spec.webhookConfiguration.matchConditions` (CEL, 1.11+). Where is that evaluated, and how does that change the trade-off against a precondition?
- **Q9.4** The webhook name in every denial you saw was `validate.kyverno.svc-fail`. What would `validate.kyverno.svc-ignore` mean for a Pod whose precondition Kyverno never got to evaluate because the pod was unreachable?

---

## Cleanup

```bash
kubectl delete cpol backend-requires-team require-cost-center flag-external-registries \
  large-memory-needs-approval protect-team-label per-container-registry \
  ci-serviceaccount-guard autogen-demo --ignore-not-found
kubectl delete namespace kca-preconditions
# optional
kind delete cluster --name kca-lab
```

---

## Answers

<details>
<summary><strong>Click to reveal all answers</strong></summary>

### Exercise 0

**Q0.1** The **admission controller** evaluates the precondition during `kubectl apply`, inside the webhook call. The **background controller** (and the **reports controller** for the resulting PolicyReport) evaluates the same rule during periodic background scans. They do not see the same inputs: the background controller has no AdmissionRequest, so any precondition referencing `request.userInfo`, `request.operation` or `request.oldObject` has no meaning there — hence the `background: false` requirement in Exercise 8. The cleanup controller is unrelated (it drives `CleanupPolicy` TTL deletion).

**Q0.2** The CLI carries its own copy of the policy engine. If the CLI is older than the cluster it may not recognise newer fields (`validate.failureAction`, newer operators) and will report schema errors or different `skip`/`error` classifications than the cluster. A green `kyverno test` on a stale CLI is not evidence that the cluster will behave the same way — pin both in CI.

### Exercise 1

**Q1.1**
- `api-backend`: **fail** — precondition `tier == backend` was true, the rule ran, the `pattern` did not match. Decided by `request.object.metadata.labels.tier`.
- `web-frontend`: **skip** — precondition was `frontend != backend`. The rule body never executed.
- `unlabelled`: **skip** — `metadata.labels` is absent, JMESPath yields null, `|| ''` substitutes the empty string, `'' != 'backend'`.

The critical point: only the first is a policy decision about compliance. The other two carry *no* statement about whether they satisfy the rule.

**Q1.2** Admission is per-object, not per-`apply`. `kubectl` sends one request per document in the manifest; `api-backend` was denied by the webhook and the other two were admitted independently. `kubectl` aggregates the errors and exits non-zero. This is why a partially-applied manifest is normal under Enforce policies, and why GitOps controllers report drift rather than atomic failure.

**Q1.3** `||` is the JMESPath OR operator: it returns the right-hand side when the left-hand side is a "false-like" value (null, empty string, empty list, empty object, false). It converts a *missing path* into a *known empty value*. It matters for `unlabelled`, which has no `metadata.labels` at all — and, as Exercise 2 shows, its absence turns that Pod into a hard denial.

**Q1.4** Move the selection into `match`:

```yaml
match:
  any:
    - resources:
        kinds: [Pod]
        namespaces: [kca-preconditions]
        operations: [CREATE, UPDATE]
        selector:
          matchLabels:
            tier: backend
```

You lose: (a) the ability to select on anything outside labels/annotations/kinds/names/namespaces — `match` cannot look at `spec`, images, resource quantities, the requester or the old object; (b) the ability to express OR/AND across heterogeneous conditions with comparison operators; (c) per-element logic. You gain a narrower webhook. Prefer `match` when it can express the condition — see Q9.2.

### Exercise 2

**Q2.1** The precondition is evaluated only *after* `match` has already selected the resource, and variable substitution over the precondition block happens before any comparison. A path that cannot be resolved is an engine **error**, not a false condition — and for a `validate` rule in `Enforce`, a rule error is surfaced as a denial. So the blast radius is exactly the `match` block: every Pod in `kca-preconditions`, regardless of labels. A precondition intended to *narrow* a policy became the thing that broadened it.

**Q2.2** No, do not rely on it. The precondition block is not a lazily-evaluated boolean expression in a programming language: Kyverno substitutes variables across the block, then applies the operators. An unresolvable path in the second entry can therefore fail the rule even when the first entry is already false. The safe practice — and the one to state in an exam answer — is that **every** key in a precondition block gets an explicit default, independently of ordering.

**Q2.3**
1. `|| ''` (or `|| '0Mi'`, `` || `[]` ``, `` || `{}` ``) — the default. Cheap, local, and picks the right zero value for the operator you are about to use.
2. Guard the parent object rather than the leaf: `{{ keys(request.object.metadata.labels || `{}`) }}` with `AnyIn`/`AnyNotIn`. Better when you want "does any label exist from this set" rather than "is this label equal to X".
3. Move the existence question into `match`/`exclude` with a `selector`, so the rule is not even reached. Best when the condition is a plain label match — no substitution, and it shrinks the webhook.

Use (1) by default, (2) for set logic and keys containing `/` or `.`, (3) whenever the condition is expressible as a label selector.

**Q2.4** Set `validate.failureAction: Audit` (or `spec.validationFailureAction: Audit` pre-1.12). The rule error is then recorded in the PolicyReport instead of denying the request. You lose enforcement for that rule while you debug — which is the correct trade during an incident. A `PolicyException` scoped to the affected resources is the surgical alternative when you only need to unblock one workload.

### Exercise 3

**Q3.1** `( any[0] OR any[1] OR … ) AND ( all[0] AND all[1] AND … )`. Both blocks must be satisfied; they are combined with AND, not OR.

**Q3.2** An omitted or empty `any` contributes nothing (it is not treated as "OR of nothing = false"), and an omitted or empty `all` likewise contributes nothing — the block as a whole is true when there is nothing to check, so a rule with no preconditions always runs. The asymmetry to internalise is between the *entries*: within `any` a single true entry suffices; within `all` a single false entry is fatal.

**Q3.3** With a scalar key and a list value, `AnyIn` is plain membership: is `env` one of `prod`, `staging`? If the key resolved to a list of three values, `AnyIn` becomes "do the two sets intersect" — true if at least one of the three appears in the value list. `AllIn` would then require all three to appear.

**Q3.4** Key `["prod", "dev"]`, value `["prod", "staging"]`. `AnyIn` → true (`prod` intersects). `AllIn` → false (`dev` is not in the value list). Concretely: "does this Pod pull from *any* untrusted registry" vs "does it pull *only* from trusted registries" are different security questions, and picking the wrong operator inverts your control.

### Exercise 4

**Q4.1** True when **at least one** of the three registries is outside the allowlist. A Pod with two allowed images and one from `docker.io` fires the rule.

**Q4.2** `AllNotIn` is true only when **none** of the registries is in the allowlist — i.e. a Pod mixing one allowed and one disallowed image would be **skipped**, silently passing. `AnyNotIn` gives you "flag the Pod if any container is non-compliant", which is the correct posture for an allowlist. `AllNotIn` answers "is this workload entirely off-allowlist", which is useful for classification, not enforcement. Choosing `AllNotIn` here would be a real, exploitable gap: attach one `registry.k8s.io` container and your malicious image sails through.

**Q4.3** `spec.containers[].image` and `element.image` return the **raw string** exactly as written in the manifest — `busybox:1.37` has no registry component at all, so any string comparison against `docker.io` fails. Kyverno's `images` context variable is **normalised**: it resolves the implicit registry (`docker.io`), path (`library/busybox`), name, tag and digest into separate fields. For any registry/tag/digest logic, use `images`; use the raw string only when you genuinely mean the literal text.

**Q4.4** It prevents a *type* failure. Without it, a Pod with no memory limit falls back to `'0Mi'` and is compared against `2Gi` — which is fine — but the moment you change the default to something that parses as a plain integer (`'0'`) while the value is a quantity (`2Gi`), the comparison branches differ and the operator can fail or return an unintended result. The explicit "does the field exist" guard makes the intent readable and keeps the second condition operating on two values of the same kind. Guard-then-compare is the idiom to memorise.

**Q4.5** `2Gi` = 2 × 1024³ = 2 147 483 648 bytes; `1536Mi` = 1 610 612 736 bytes. `2Gi` is larger, so `mem-small` is correctly skipped. Kyverno parses both sides as Kubernetes **resource quantities** (the same type the API server uses), not as strings and not as naive floats — which is why `1536Mi < 2Gi` comes out right where a lexicographic comparison would say the opposite.

**Q4.6** `containers[0]` inspects only the first container; a 32Gi limit on the second container is invisible. Worse, the index is positional, so adding a sidecar silently changes which container is checked. Use a `foreach` over `request.object.spec.containers` (Exercise 6), or aggregate with JMESPath — e.g. `{{ sum(request.object.spec.containers[].resources.limits.memory) }}` style expressions — so the policy scales with the Pod rather than assuming its shape.

### Exercise 5

**Q5.1** The **precondition** answers "*should this rule run at all for this request?*" — here: only on UPDATE, and only for Pods that already carried a `team` label. The **deny conditions** answer "*given that the rule is running, should the request be rejected?*" — here: the new value differs from the old. Same grammar, different position in the pipeline: a false precondition yields `skip` (no opinion), a false deny condition yields `pass` (explicitly compliant). That distinction is what shows up in your PolicyReport and your compliance evidence.

**Q5.2** On `DELETE`, `request.oldObject` holds the object being removed and `request.object` is null. Without a default, `{{ request.object.metadata.labels.team }}` is an unresolvable path — the same class of failure as Exercise 2, meaning your immutability rule would start blocking deletions. (Symmetrically, on `CREATE`, `oldObject` is null.)

**Q5.3** *Against:* `match` already restricts to UPDATE, so the precondition is redundant at runtime. *For:* (a) the `match` block is one `kubectl patch` away from being widened by someone else — as you did in step 28 — and the precondition is the second layer that keeps the rule from firing on CREATE/DELETE; (b) it documents intent at the point of use; (c) autogen produces controller rules from this one, and being explicit avoids surprises. **Recommendation:** keep both. `match` is your webhook-scoping and performance lever; the precondition is your correctness invariant. Defence in depth costs one condition evaluation.

**Q5.4** No — it is "immutable once set", which is what the precondition literally says. To forbid adding it later, drop the `oldObject` precondition and instead deny whenever the values differ *in either direction*, defaulting both sides:

```yaml
preconditions:
  all:
    - key: "{{ request.operation }}"
      operator: Equals
      value: UPDATE
validate:
  deny:
    conditions:
      all:
        - key: "{{ request.object.metadata.labels.team || '' }}"
          operator: NotEquals
          value: "{{ request.oldObject.metadata.labels.team || '' }}"
```

Now add, change and remove are all denied on UPDATE, while CREATE is untouched.

**Q5.5** Background scans have no AdmissionRequest: there is no `request.operation` and no `request.oldObject` to compare against. A rule of this shape can only be evaluated at admission time. Setting `background: true` would at best produce meaningless results and at worst be rejected by the policy-validation webhook — same family of constraint as Exercise 8.

### Exercise 6

**Q6.1** Twice — once per entry in `request.object.spec.containers`. `{{ element }}` is bound to the **whole container object** each time (`element.name`, `element.image`, `element.resources`, …), and `{{ elementIndex }}` to its 0-based position. On the second iteration the precondition `AllNotIn [istio-proxy, linkerd-proxy]` is false for `istio-proxy`, so that element is skipped and its `deny` block never evaluates.

**Q6.2** Only crudely. A rule-level precondition can ask "does this Pod contain a container named istio-proxy" and skip the **entire Pod** — which means one meshed Pod exempts *all* of its containers, including the application ones. That is a policy bypass: inject a container named `istio-proxy` and nothing is checked. The `foreach` precondition exempts exactly one element and keeps the rest under enforcement. Granularity of the exemption is the whole point.

**Q6.3** Equivalent form:

```yaml
deny:
  conditions:
    all:
      - key: "{{ images.containers.*.registry }}"
        operator: AnyNotIn
        value: [registry.k8s.io]
```

but note this is no longer per-element — it re-aggregates across the Pod, which defeats the `foreach`. The faithful per-element version keeps `element` but reads the normalised registry, e.g. by looking the container up in the `images` map. **Ship the `images`-based version**, because `starts_with(element.image, 'registry.k8s.io/')` compares raw strings and is defeated by any of the equivalent spellings of an image reference (`busybox`, `busybox:latest`, `docker.io/library/busybox`, digest pins). Raw-string image matching is a recurring source of false negatives in real clusters.

**Q6.4** `request.object.spec.initContainers` resolves to null on a Pod with no init containers; a `foreach` over an empty or null list simply performs zero iterations. No element means no condition evaluation and no error — which also means **no enforcement**, so an empty list is silently compliant. If "must have at least one" is part of your requirement, assert it in a separate rule; `foreach` will never do it for you.

**Q6.5** Yes, `validate.foreach` evaluates every element and aggregates the failures — the denial message names the first failing container, but the engine has visited them all, which is why you get complete report data. `mutate.foreach` differs in nature: each iteration applies a patch, and the mutations accumulate onto the object in order, so a later element operates on the result of the earlier ones. Never assume ordering independence in a mutate loop.

### Exercise 7

**Q7.1** `fresh` was skipped. Its `creationTimestamp` is under 24h from the CLI's clock, so `time_since` returned a duration that failed `DurationGreaterThan 24h`. `ancient-with-owner` **passed** (rule ran, pattern matched); `ancient-no-owner` **failed**. Note how the tally distinguishes all three — this is the fastest way to prove a precondition is doing what you think.

**Q7.2** It reports whether the **assertion matched**, not whether the resource complied. Row 3 says `Pass` because the engine produced `skip` and the test file expected `skip`. `kyverno test` is a test runner over the engine's output; `kyverno apply` reports the engine's output directly. Confusing the two is a classic exam trap: a green test suite can encode "this rule is skipped for everything".

**Q7.3** Inner-to-outer. Kyverno first substitutes `{{ request.object.metadata.creationTimestamp }}` into the surrounding string, producing `time_since('', '2024-01-01T00:00:00Z', '')`. The result is then evaluated as a JMESPath expression by the outer `{{ }}`, yielding a duration string such as `14352h0m0s`, which is what `DurationGreaterThan` compares against `24h`. Nested substitution is what lets you feed object data into JMESPath function arguments.

**Q7.4** Because `metadata.creationTimestamp` is assigned by the API server *after* admission; in the AdmissionReview for a `CREATE` it is null (or the zero time). The precondition can therefore only be meaningfully evaluated against objects that already exist — background scans, `kyverno apply` against a manifest that carries a timestamp, or a mutate-existing rule. Any "age of resource" policy lives outside the admission path, and that fact is worth stating explicitly in a design review.

**Q7.5** `background: true` is correct **and required** here — nothing in the precondition reads the admission request, and a background scan is the only context where the timestamp exists. The distribution shifts over time: today `fresh` is skipped; after 24 hours the same Pod moves from `skip` to `fail` with no change to the policy or the Pod. Time-dependent preconditions make PolicyReports non-idempotent, which is exactly what you want here but must be documented for whoever alerts on report deltas.

### Exercise 8

**Q8.1** Evaluating it as empty would silently change the meaning of the policy: an `AnyNotIn` against an empty username would fire (or not) for reasons the author never intended, producing report entries that look authoritative but are fiction. Kyverno chooses to fail loudly at policy-admission time — a validation error you fix once — instead of producing quietly wrong compliance data forever. Fail-closed on configuration, not on data.

**Q8.2** `request.userInfo.*` (username, groups, uid, extra), `request.roles`, `request.clusterRoles`, `serviceAccountName`, `serviceAccountNamespace`. They are all derived from the **AdmissionRequest identity**, which does not exist outside the admission path. The same reasoning extends by design to `request.operation` and `request.oldObject`: a background scan sees a stored object, not a request, so any policy whose logic depends on *who* or *how* should carry `background: false`.

**Q8.3** (a) No PolicyReport entries for resources that already existed before the policy was installed — you cannot answer "how many Pods violate this today". (b) No re-evaluation when the policy changes: with background disabled, editing the rule does not reassess existing workloads, so drift after a policy update is invisible until the next admission event touches the object.

**Q8.4** Autogen rewrites Pod-scoped paths into the controller's pod template: `request.object.spec` → `request.object.spec.template.spec`, and `request.object.metadata` → `request.object.spec.template.metadata`. So the generated Deployment rule reads the **pod template labels**, not the Deployment's own labels. In step 44 the `tier=backend` label was placed on the Deployment object, so the autogenerated precondition sees no `tier` on the template, evaluates to `''`, and the rule is **skipped** — no violation reported, even though a human reading `kubectl get deploy --show-labels` would swear the policy should have fired. This is one of the most common "my policy does nothing" tickets: label the template, not the controller (or explicitly disable autogen with the `pod-policies.kyverno.io/autogen-controllers: none` annotation and write both rules yourself).

**Q8.5** Split into two policies over the same intent:
- Policy A — `background: false`, contains the identity-dependent rules, `failureAction: Enforce`, matched to `CREATE`/`UPDATE`. This is your gate.
- Policy B — `background: true`, same *object* conditions with all request-scoped variables removed, `failureAction: Audit`. This is your inventory.

Name them so the pairing is obvious (`…-admission` / `…-audit`) and keep the shared conditions in one source template so they cannot drift. Do not try to make one policy do both jobs — the variable restriction exists precisely because the two evaluations do not have the same inputs.

### Exercise 9

**Q9.1** No. The `ValidatingWebhookConfiguration` `rules` are derived exclusively from the union of all policies' `match`/`exclude` blocks (kinds, API groups, operations, namespace/object selectors). Preconditions appear nowhere in that object — step 46 confirms it. Every request matching the coarse rules is still serialised, sent over the network, deserialised and evaluated by Kyverno before the precondition can reject it. Preconditions save you *policy logic*, not *admission latency*.

**Q9.2**
- `match`/`exclude`: kinds, API groups/versions, names, namespaces, label selectors on the object or the namespace, operations, and subjects (users/groups/roles/SAs) — anything that shrinks the webhook and can be decided from resource identity.
- `preconditions`: anything requiring the object's `spec` (images, registries, resource quantities, ports, volumes), comparisons rather than equality, cross-field logic, `request.oldObject` diffs, values fetched by `context` (ConfigMap lookups, API calls), and per-element `foreach` logic.

Two things `match` cannot express: (1) a numeric or duration comparison such as "memory limit above 2Gi"; (2) a diff between the old and new object, such as "this label changed value".

**Q9.3** `matchConditions` are CEL expressions evaluated **by the API server** before it dispatches the webhook call. A request filtered there never reaches Kyverno at all, so it costs no network round trip and no engine time — the opposite of a precondition. The trade-off: CEL there has access only to the request/object as the API server sees it (no Kyverno context, no ConfigMap lookups, no `images` normalisation), and a bug there silently drops requests from evaluation. Use `matchConditions` for cheap, stable, high-volume exclusions (system namespaces, specific service accounts) and preconditions for the policy logic itself.

**Q9.4** The `-fail` and `-ignore` webhooks correspond to `failurePolicy: Fail` and `failurePolicy: Ignore`. If Kyverno is unreachable, requests routed to `validate.kyverno.svc-ignore` are **admitted without evaluation** — the precondition, and the whole rule, are simply never run, and nothing in the resource records that fact. Requests routed to `validate.kyverno.svc-fail` are **rejected**, which preserves enforcement at the cost of availability: a Kyverno outage becomes a cluster-wide write outage for the matched kinds. Which webhook a policy lands on is driven by its `failurePolicy`, and choosing it is an availability decision, not a policy-authoring one.

</details>

---

## Sources

- Kyverno — Preconditions: <https://kyverno.io/docs/writing-policies/preconditions/>
- Kyverno — Match and Exclude: <https://kyverno.io/docs/writing-policies/match-exclude/>
- Kyverno — Variables: <https://kyverno.io/docs/writing-policies/variables/>
- Kyverno — JMESPath: <https://kyverno.io/docs/writing-policies/jmespath/>
- Kyverno — Validate rules and `deny` conditions: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Auto-Gen Rules for Pod Controllers: <https://kyverno.io/docs/writing-policies/autogen/>
- Kyverno — CLI `apply` and `test`: <https://kyverno.io/docs/kyverno-cli/usage/apply/> · <https://kyverno.io/docs/kyverno-cli/usage/test/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kubernetes — Dynamic Admission Control (`failurePolicy`, `matchConditions`): <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Kubernetes — Resource quantity semantics: <https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/quantity/>
- CNCF — KCA curriculum: <https://github.com/cncf/curriculum>