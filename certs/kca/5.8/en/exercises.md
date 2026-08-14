# 5.8 JSON Patches — Guided Exercises

> **Domain 5 — Writing Policies · Objective 5.8 (≈2.91% of the KCA exam)**
> Reference syllabus: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>

JSON Patch (RFC 6902) is the *surgical* mutation mechanism in Kyverno: an ordered, atomic list of operations addressed by JSON Pointer (RFC 6901). It is the tool you reach for when strategic merge cannot express the change — deleting a field, appending to a list, moving a value, or making the whole mutation conditional on a value that is already in the object.

These exercises are run in order. Everything is executed against a real cluster and then re-verified offline with the Kyverno CLI, because that is exactly the loop you use in production and in the exam.

**Conventions used below**

- Command outputs are shown as they typically appear. Strings produced by the embedded `evanphx/json-patch` library (used by both the API server and Kyverno) and by the `kyverno` CLI renderer vary slightly between releases — record what *your* version prints rather than memorising a string.
- `$` prefixes a shell command. Everything else in an output block is output.

---

## Exercise 0 — Lab environment

### Steps

1. Create a disposable cluster:

```bash
$ kind create cluster --name kca-58 --image kindest/node:v1.31.0
$ kubectl cluster-info --context kind-kca-58
```

2. Install Kyverno:

```bash
$ helm repo add kyverno https://kyverno.github.io/kyverno/
$ helm repo update
$ helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
```

3. Confirm the control plane came up. Since Kyverno 1.10 the controller is split into four deployments:

```bash
$ kubectl -n kyverno get deploy
```

```
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    1/1     1            1           78s
kyverno-background-controller   1/1     1            1           78s
kyverno-cleanup-controller      1/1     1            1           78s
kyverno-reports-controller      1/1     1            1           78s
```

4. Look at the webhook Kyverno registered for mutation:

```bash
$ kubectl get mutatingwebhookconfigurations
```

```
NAME                                 WEBHOOKS   AGE
kyverno-policy-mutating-webhook-cfg   1          80s
kyverno-resource-mutating-webhook-cfg 1          80s
kyverno-verify-mutating-webhook-cfg   1          80s
```

5. Install the Kyverno CLI (you will need it from Exercise 9 onwards):

```bash
$ kubectl krew install kyverno      # or download the release tarball from GitHub
$ kubectl kyverno version
```

6. Create the working namespace:

```bash
$ kubectl create ns json-lab
```

### Questions

- **Q0.1** — Which of the four Kyverno deployments actually rewrites an incoming `Pod` at admission time, and which one is responsible for `mutateExisting` policies?
- **Q0.2** — `kyverno-resource-mutating-webhook-cfg` is initially registered with an empty rule set on a fresh install and gets populated once policies exist. Why does Kyverno manage its own webhook rules dynamically instead of shipping a static "match everything" webhook?
- **Q0.3** — In the API server request pipeline, does a mutating admission webhook see the object *before* or *after* API defaulting is applied? Why does the answer matter for a JSON Patch `test` operation?

---

## Exercise 1 — RFC 6902 without Kyverno

Before writing a single policy, drive the same machinery by hand through `kubectl patch --type='json'`. This is the fastest way to build intuition about the six operations, and it removes Kyverno from the equation while you learn.

### Steps

1. Create a workload to operate on:

```bash
$ kubectl -n json-lab create deployment web --image=nginx:1.27 --replicas=2
deployment.apps/web created
```

2. `replace` — the target location **must already exist**:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/spec/replicas","value":3}]'
deployment.apps/web patched
```

3. `add` on an object member that already exists. Read RFC 6902 §4.1 carefully before you predict the outcome:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"add","path":"/spec/replicas","value":4}]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web -o jsonpath='{.spec.replicas}'; echo
4
```

4. `add` on a member that does not exist — this *creates* it, provided the parent exists:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
deployment.apps/web patched
```

5. Now try to `remove` a path that is not in the document:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
```

```
Error from server: jsonpatch remove operation does not apply: doc is missing path: "/spec/template/spec/nodeSelector": missing value
```

6. Array handling. First create the parent array, then append with the end-of-array token `-`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env","value":[]},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"LOG_LEVEL","value":"info"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"TIER","value":"frontend"}}
]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL TIER
```

7. Insert *before* an existing element by using a numeric index instead of `-`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/0","value":{"name":"REGION","value":"eu-west"}}]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
REGION LOG_LEVEL TIER
```

8. `test` guards the whole patch. Run the succeeding case first:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"test","path":"/spec/replicas","value":4},
  {"op":"replace","path":"/spec/replicas","value":6}
]'
deployment.apps/web patched
```

9. Now the failing case — note that the `replace` in the same list is *not* applied:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"test","path":"/spec/replicas","value":99},
  {"op":"replace","path":"/spec/replicas","value":1}
]'
```

```
Error from server: testing value /spec/replicas failed: test failed
```

```bash
$ kubectl -n json-lab get deploy web -o jsonpath='{.spec.replicas}'; echo
6
```

10. `copy` and `move`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"copy","from":"/metadata/labels/app","path":"/spec/template/metadata/labels/component"},
  {"op":"move","from":"/spec/template/spec/containers/0/env/0","path":"/spec/template/spec/containers/0/env/-"}
]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL TIER REGION
```

### Questions

- **Q1.1** — In step 3, `add` was applied to `/spec/replicas`, which already had a value. What does RFC 6902 say happens, and what is the practical consequence when you `add` an empty object to `/metadata/labels` on a resource that already carries labels?
- **Q1.2** — Step 5 failed. Name two different ways to make a "remove this field if it is present" policy safe in Kyverno.
- **Q1.3** — What is the difference between `path: /…/env/-` and `path: /…/env/0`? Which operations accept the `-` token, and which reject it?
- **Q1.4** — Step 9 proves a property of RFC 6902 patches. State that property in one sentence, and explain why it makes `test` the only *intrinsic* conditional in the specification.
- **Q1.5** — `move` and `copy` both take a `from` pointer. What is the one thing `move` must additionally validate that `copy` does not?

---

## Exercise 2 — JSON Pointer escaping (RFC 6901)

Kubernetes keys are full of `/` — every domain-prefixed label and annotation has one. This is the single most common reason a hand-written Kyverno JSON patch silently targets the wrong location.

### Steps

1. Put a domain-prefixed annotation on the deployment:

```bash
$ kubectl -n json-lab annotate deployment web kca.example.com/owner=platform
deployment.apps/web annotated
```

2. Try to patch it with the literal key — observe the failure:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/metadata/annotations/kca.example.com/owner","value":"sre"}]'
```

```
Error from server: jsonpatch replace operation does not apply: doc is missing path: "/metadata/annotations/kca.example.com/owner": missing value
```

3. Escape the `/` in the key as `~1`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/metadata/annotations/kca.example.com~1owner","value":"sre"}]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.metadata.annotations.kca\.example\.com/owner}'; echo
sre
```

4. Now a key containing a literal tilde. Add it, then address it:

```bash
$ kubectl -n json-lab annotate deployment web 'weird~key=value1'
deployment.apps/web annotated

$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/metadata/annotations/weird~0key","value":"value2"}]'
deployment.apps/web patched
```

5. Reason about the pathological case — a key literally named `a~1b`. Its JSON Pointer token is `a~01b`. Decode it by hand: apply `~1 → /` first, then `~0 → ~`, and confirm you get back `a~1b` rather than `a/b`.

### Questions

- **Q2.1** — Write the JSON Pointer path that targets the label `app.kubernetes.io/managed-by` on a Pod.
- **Q2.2** — RFC 6901 mandates a decoding order for the two escapes. Which one is applied first, and what breaks if you invert it?
- **Q2.3** — Step 2 did not raise a syntax error; it raised a *missing path* error. Explain why an unescaped `/` produces a semantically valid but wrong pointer, and why that makes this class of bug so easy to ship.

---

## Exercise 3 — Your first Kyverno `patchesJson6902` rule

### Steps

1. Write the policy. Note that `patchesJson6902` is a **string** field containing a YAML (or JSON) sequence of operations — hence the `|-` block scalar:

```yaml
# 01-add-team-label.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
    - name: add-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels/team"
            value: platform
```

2. Apply it and confirm Kyverno accepted it:

```bash
$ kubectl apply -f 01-add-team-label.yaml
clusterpolicy.kyverno.io/add-team-label created

$ kubectl get clusterpolicy add-team-label
NAME             ADMISSION   BACKGROUND   READY   AGE   MESSAGE
add-team-label   true        true         True    6s    Ready
```

3. Create a Pod that **already has labels** (`kubectl run` always sets `run=<name>`):

```bash
$ kubectl -n json-lab run labeled --image=nginx:1.27
pod/labeled created

$ kubectl -n json-lab get pod labeled -o jsonpath='{.metadata.labels}'; echo
{"run":"labeled","team":"platform"}
```

4. Inspect the breadcrumb Kyverno leaves on every mutated object:

```bash
$ kubectl -n json-lab get pod labeled \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo
add-team-label.add-team-label.kyverno.io: added /metadata/labels/team
```

5. Now create a Pod with **no labels at all**:

```yaml
# 02-unlabeled-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: unlabeled
  namespace: json-lab
spec:
  containers:
    - name: app
      image: nginx:1.27
```

```bash
$ kubectl apply -f 02-unlabeled-pod.yaml
```

6. Record exactly what happened — this is the point of the exercise:

```bash
$ kubectl -n json-lab get pod unlabeled -o jsonpath='{.metadata.labels}'; echo
$ kubectl -n json-lab get events --field-selector involvedObject.name=unlabeled
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50 | grep -i patch
```

7. Write down three facts: (a) was the Pod created, (b) does it carry `team=platform`, (c) did Kyverno log an error.

### Questions

- **Q3.1** — Why must `patchesJson6902` be a block scalar (`|-`) rather than a native YAML list under the `mutate` key?
- **Q3.2** — Based on what you observed in steps 5–7, is `add` guaranteed to create the missing parent object `/metadata/labels`? What does RFC 6902 §4.1 require, and why can a given Kyverno build behave more permissively than the RFC?
- **Q3.3** — Rewrite this rule so it works on *any* Pod, labelled or not, without a chance of destroying pre-existing labels. Which mutation mechanism is the correct tool here?
- **Q3.4** — What is the `policies.kyverno.io/last-applied-patches` annotation for, and why is it the first thing to check when a student reports "my mutation didn't run"?

---

## Exercise 4 — The destructive-parent trap

A very common "fix" for Exercise 3 is to create the parent first. Prove to yourself why that fix is worse than the bug.

### Steps

1. Replace the policy with the naive two-operation form:

```yaml
# 03-add-team-label-naive.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
    - name: add-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels"
            value: {}
          - op: add
            path: "/metadata/labels/team"
            value: platform
```

```bash
$ kubectl apply -f 03-add-team-label-naive.yaml
clusterpolicy.kyverno.io/add-team-label configured
```

2. Create a Pod carrying labels you care about:

```bash
$ kubectl -n json-lab run important --image=nginx:1.27 \
  --labels='app=checkout,tier=frontend,owner=payments'
pod/important created
```

3. Inspect the result:

```bash
$ kubectl -n json-lab get pod important -o jsonpath='{.metadata.labels}'; echo
{"team":"platform"}
```

4. The Pod's selectors, NetworkPolicies and Service endpoints are now broken. Clean up and restore a safe policy:

```bash
$ kubectl -n json-lab delete pod important --now
$ kubectl delete clusterpolicy add-team-label
```

5. Write the correct version using strategic merge, which merges maps instead of replacing them:

```yaml
# 04-add-team-label-safe.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
    - name: add-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              team: platform
```

```bash
$ kubectl apply -f 04-add-team-label-safe.yaml
$ kubectl -n json-lab run important --image=nginx:1.27 \
  --labels='app=checkout,tier=frontend,owner=payments'
$ kubectl -n json-lab get pod important -o jsonpath='{.metadata.labels}'; echo
{"app":"checkout","owner":"payments","team":"platform","tier":"frontend"}
```

6. If you are *required* to use JSON Patch (for example, the field is a list and you need positional control), scope the destructive branch with a precondition instead:

```yaml
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels || '' }}"
            operator: Equals
            value: ""
```

### Questions

- **Q4.1** — Precisely which RFC 6902 rule made step 3 destroy three labels?
- **Q4.2** — Pure RFC 6902 has no "create only if absent" operation. Given that `test` compares a value at a pointer, can `test` be used to assert that `/metadata/labels` is *absent*? Justify your answer.
- **Q4.3** — State the decision rule you will use for the rest of your career: when do you choose `patchStrategicMerge` and when `patchesJson6902`?
- **Q4.4** — In step 6, why is the `|| ''` fallback necessary, and what happens to the rule if a variable in a Kyverno patch fails to resolve?

---

## Exercise 5 — Arrays, UPDATE, and the idempotency bug

This is the highest-value exercise in the objective. JSON Patch `add …/-` is *not* idempotent, and Kyverno's admission webhook fires on both CREATE and UPDATE.

### Steps

1. Deploy a workload whose container already has an `env` list:

```yaml
# 05-api-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: json-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27
          env:
            - name: LOG_LEVEL
              value: info
```

```bash
$ kubectl apply -f 05-api-deployment.yaml
deployment.apps/api created
```

2. Write an appending policy:

```yaml
# 06-append-env.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: append-cluster-tier
spec:
  rules:
    - name: append-env
      match:
        any:
          - resources:
              kinds:
                - Deployment
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/template/spec/containers/0/env/-"
            value:
              name: CLUSTER_TIER
              value: gold
```

```bash
$ kubectl apply -f 06-append-env.yaml
clusterpolicy.kyverno.io/append-cluster-tier created
```

3. Re-create the deployment so the rule fires on CREATE:

```bash
$ kubectl delete -f 05-api-deployment.yaml
$ kubectl apply -f 05-api-deployment.yaml

$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER
```

4. Trigger an ordinary UPDATE — anything at all, such as a GitOps controller re-applying an annotation:

```bash
$ kubectl -n json-lab annotate deploy api bump=1 --overwrite
deployment.apps/api annotated

$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER CLUSTER_TIER
```

5. Do it three more times and watch the list grow without bound:

```bash
$ for i in 2 3 4; do kubectl -n json-lab annotate deploy api bump=$i --overwrite >/dev/null; done
$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER CLUSTER_TIER CLUSTER_TIER CLUSTER_TIER CLUSTER_TIER
```

6. **Fix A — restrict the admission operations** (Kyverno 1.11+, `match.any[].resources.operations`):

```yaml
# 07-append-env-create-only.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: append-cluster-tier
spec:
  rules:
    - name: append-env
      match:
        any:
          - resources:
              kinds:
                - Deployment
              namespaces:
                - json-lab
              operations:
                - CREATE
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/template/spec/containers/0/env/-"
            value:
              name: CLUSTER_TIER
              value: gold
```

```bash
$ kubectl apply -f 07-append-env-create-only.yaml
$ kubectl delete -f 05-api-deployment.yaml && kubectl apply -f 05-api-deployment.yaml
$ for i in 1 2 3; do kubectl -n json-lab annotate deploy api bump=$i --overwrite >/dev/null; done
$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER
```

7. **Fix B — a precondition on the admission verb**, equivalent in effect and usable on older versions:

```yaml
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: CREATE
```

8. **Fix C — the structurally idempotent option.** `env` carries `patchMergeKey: name` in the Kubernetes API, so strategic merge de-duplicates by name:

```yaml
# 08-append-env-smp.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: append-cluster-tier
spec:
  rules:
    - name: append-env
      match:
        any:
          - resources:
              kinds:
                - Deployment
              namespaces:
                - json-lab
      mutate:
        patchStrategicMerge:
          spec:
            template:
              spec:
                containers:
                  - (name): "*"
                    env:
                      - name: CLUSTER_TIER
                        value: gold
```

```bash
$ kubectl apply -f 08-append-env-smp.yaml
$ kubectl delete -f 05-api-deployment.yaml && kubectl apply -f 05-api-deployment.yaml
$ for i in 1 2 3; do kubectl -n json-lab annotate deploy api bump=$i --overwrite >/dev/null; done
$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER
```

### Questions

- **Q5.1** — Explain, in terms of admission-webhook lifecycle, why the duplicate appeared in step 4 even though nothing about the Pod template changed.
- **Q5.2** — The API server accepts duplicate `env` names. Which component resolves the conflict at runtime, and why is "it still works" a dangerous conclusion?
- **Q5.3** — Fix A and Fix B produce the same outcome for this policy. Name one situation where scoping via `match.any[].resources.operations` is materially better than a precondition, and one where the precondition is the only option.
- **Q5.4** — Fix C is idempotent *for this field*. Why is that a property of `env` specifically and not of every list in `PodSpec`? How do you determine, for an arbitrary field, whether strategic merge will merge or replace?
- **Q5.5** — The policy hardcodes container index `0`. Describe the failure mode on a Pod with a sidecar, and state the correct Kyverno construct to fix it.

---

## Exercise 6 — `test` as a conditional inside the patch

`test` lets the patch itself decide whether to apply, using only data that is already in the object. Because a failed operation aborts the entire patch, the guard is atomic.

### Steps

1. Write a policy that downgrades `imagePullPolicy` **only if** it is currently `Always`:

```yaml
# 09-test-guard.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: relax-image-pull-policy
spec:
  rules:
    - name: only-if-always
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: test
            path: "/spec/containers/0/imagePullPolicy"
            value: Always
          - op: replace
            path: "/spec/containers/0/imagePullPolicy"
            value: IfNotPresent
```

```bash
$ kubectl apply -f 09-test-guard.yaml
$ kubectl delete clusterpolicy append-cluster-tier
```

2. Create a Pod whose image tag is `latest` — the API server defaults `imagePullPolicy` to `Always` for it:

```bash
$ kubectl -n json-lab run pinned-latest --image=nginx:latest
pod/pinned-latest created

$ kubectl -n json-lab get pod pinned-latest \
  -o jsonpath='{.spec.containers[0].imagePullPolicy}'; echo
IfNotPresent
```

3. Create a Pod with an explicit tag, which defaults to `IfNotPresent` — the `test` now fails:

```bash
$ kubectl -n json-lab run pinned-1-27 --image=nginx:1.27
pod/pinned-1-27 created

$ kubectl -n json-lab get pod pinned-1-27 \
  -o jsonpath='{.spec.containers[0].imagePullPolicy}'; echo
IfNotPresent
```

4. Verify the *second* Pod was never patched, rather than patched to the same value:

```bash
$ kubectl -n json-lab get pod pinned-1-27 \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo

$ kubectl -n json-lab get pod pinned-latest \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo
only-if-always.relax-image-pull-policy.kyverno.io: replaced /spec/containers/0/imagePullPolicy
```

5. Prove the atomicity claim. Add a second, unconditional operation *after* the guard and confirm it is also suppressed when the `test` fails:

```yaml
        patchesJson6902: |-
          - op: test
            path: "/spec/containers/0/imagePullPolicy"
            value: Always
          - op: replace
            path: "/spec/containers/0/imagePullPolicy"
            value: IfNotPresent
          - op: add
            path: "/metadata/annotations/kca.example.com~1relaxed"
            value: "true"
```

```bash
$ kubectl apply -f 09-test-guard.yaml
$ kubectl -n json-lab run tagged2 --image=nginx:1.27
$ kubectl -n json-lab get pod tagged2 \
  -o jsonpath='{.metadata.annotations}'; echo
```

### Questions

- **Q6.1** — In step 2, your manifest never mentioned `imagePullPolicy`, yet the `test` operation found `Always`. Which stage of the API server pipeline put it there, and what general lesson does this teach about writing JSON Pointers against Kubernetes objects?
- **Q6.2** — `test` compares by value. What does RFC 6902 say about comparing objects and arrays — is `{"a":1,"b":2}` equal to `{"b":2,"a":1}`, and is `[1,2]` equal to `[2,1]`?
- **Q6.3** — In step 5, the annotation operation is unrelated to the guard yet did not apply. Restate the atomicity rule, and describe how you would split this policy into two rules if you wanted the annotation applied unconditionally.
- **Q6.4** — When would you prefer a Kyverno `precondition` over an RFC 6902 `test`, and vice versa? Give one capability each has that the other lacks.

---

## Exercise 7 — Variables and JMESPath inside a JSON Patch

### Steps

1. Kyverno substitutes `{{ … }}` variables **before** the patch string is parsed as JSON Patch. Write a policy that stamps provenance onto a Pod:

```yaml
# 10-provenance.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: stamp-provenance
spec:
  rules:
    - name: stamp
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/annotations/kca.example.com~1created-by"
            value: "{{ request.userInfo.username }}"
          - op: add
            path: "/metadata/annotations/kca.example.com~1namespace"
            value: "{{ request.namespace }}"
          - op: add
            path: "/metadata/annotations/kca.example.com~1app-upper"
            value: "{{ to_upper(request.object.metadata.labels.app || 'UNSET') }}"
```

2. The patch writes into `/metadata/annotations/…`, so the target Pod must already have that map. Create one that does:

```yaml
# 11-annotated-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: stamped
  namespace: json-lab
  labels:
    app: checkout
  annotations:
    kca.example.com/seed: "present"
spec:
  containers:
    - name: app
      image: nginx:1.27
```

```bash
$ kubectl apply -f 10-provenance.yaml
$ kubectl delete clusterpolicy relax-image-pull-policy
$ kubectl apply -f 11-annotated-pod.yaml
pod/stamped created

$ kubectl -n json-lab get pod stamped -o jsonpath='{.metadata.annotations}' | tr ',' '\n'
```

```
{"kca.example.com/app-upper":"CHECKOUT"
"kca.example.com/created-by":"kubernetes-admin"
"kca.example.com/namespace":"json-lab"
"kca.example.com/seed":"present"
...}
```

3. Now remove the `|| 'UNSET'` fallback from the third operation, re-apply, and create a Pod **without** the `app` label. Record whether the rule errors, skips, or applies partially.

4. Restore the fallback.

### Questions

- **Q7.1** — Variable substitution happens before the patch is parsed. What does that imply if a variable resolves to a string containing a `/` and you interpolate it into a `path`?
- **Q7.2** — In step 3, what did Kyverno do when the variable had no value? Why is `|| 'default'` considered mandatory hygiene in production policies?
- **Q7.3** — `{{ request.userInfo.username }}` is available at admission. Is it available to a `mutateExisting` rule running in the background controller? Explain.
- **Q7.4** — Why did every annotation path in this policy need `~1`, and what would have happened had you written `kca.example.com/created-by` unescaped?

---

## Exercise 8 — `foreach` + `patchesJson6902`: eliminating hardcoded indices

### Steps

1. Deploy a multi-container Pod:

```yaml
# 12-multi-container.yaml
apiVersion: v1
kind: Pod
metadata:
  name: multi
  namespace: json-lab
spec:
  containers:
    - name: app
      image: nginx:latest
    - name: sidecar
      image: busybox:latest
      command: ["sleep", "3600"]
    - name: exporter
      image: prom/node-exporter:latest
```

2. Write a `foreach` mutation. Inside the loop, `{{elementIndex}}` is the zero-based position and `{{element}}` is the item itself:

```yaml
# 13-foreach-pullpolicy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: set-image-pull-policy
spec:
  rules:
    - name: set-ifnotpresent
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            patchesJson6902: |-
              - op: add
                path: "/spec/containers/{{elementIndex}}/imagePullPolicy"
                value: IfNotPresent
```

```bash
$ kubectl delete clusterpolicy stamp-provenance
$ kubectl apply -f 13-foreach-pullpolicy.yaml
$ kubectl apply -f 12-multi-container.yaml
pod/multi created

$ kubectl -n json-lab get pod multi \
  -o jsonpath='{range .spec.containers[*]}{.name}{"="}{.imagePullPolicy}{"\n"}{end}'
app=IfNotPresent
sidecar=IfNotPresent
exporter=IfNotPresent
```

3. Confirm that `add` on a scalar path is safe regardless of whether the field was present — it creates or replaces, never fails on a missing sibling.

4. Add a `foreach` filter so only images from a specific registry are touched:

```yaml
        foreach:
          - list: "request.object.spec.containers"
            preconditions:
              all:
                - key: "{{ element.image }}"
                  operator: NotEquals
                  value: "busybox:*"
            patchesJson6902: |-
              - op: add
                path: "/spec/containers/{{elementIndex}}/imagePullPolicy"
                value: IfNotPresent
```

```bash
$ kubectl apply -f 13-foreach-pullpolicy.yaml
$ kubectl -n json-lab delete pod multi --now && kubectl apply -f 12-multi-container.yaml
$ kubectl -n json-lab get pod multi \
  -o jsonpath='{range .spec.containers[*]}{.name}{"="}{.imagePullPolicy}{"\n"}{end}'
app=IfNotPresent
sidecar=Always
exporter=IfNotPresent
```

### Questions

- **Q8.1** — Compare `/spec/containers/{{elementIndex}}/imagePullPolicy` with `/spec/containers/0/imagePullPolicy`. What class of bug does the former eliminate, and what does it cost you in readability?
- **Q8.2** — Inside a `foreach` that appends with `/-`, the array grows as the loop runs. Why can this make `{{elementIndex}}` unreliable, and what mutation style avoids the problem entirely?
- **Q8.3** — Would this policy also cover `initContainers` and `ephemeralContainers`? What change is required?
- **Q8.4** — What is the difference between a rule-level `preconditions` block and the `preconditions` block nested inside a `foreach` entry?

---

## Exercise 9 — Iterating offline with the Kyverno CLI

Never debug a JSON patch by re-creating Pods in a cluster. The CLI gives a deterministic, reviewable loop and is directly examinable under Domain 3.

### Steps

1. Put the policy and a candidate resource side by side:

```bash
$ mkdir -p ~/kca58/tests && cd ~/kca58/tests
$ cp ../13-foreach-pullpolicy.yaml policy.yaml
$ cp ../12-multi-container.yaml resource.yaml
```

2. Apply the policy to the resource without touching the cluster:

```bash
$ kubectl kyverno apply policy.yaml --resource resource.yaml
```

```
Applying 1 policy rule(s) to 1 resource(s)...

mutate policy set-image-pull-policy applied to json-lab/Pod/multi:

apiVersion: v1
kind: Pod
metadata:
  name: multi
  namespace: json-lab
spec:
  containers:
  - image: nginx:latest
    imagePullPolicy: IfNotPresent
    name: app
...
---

pass: 1, fail: 0, warn: 0, error: 0, skip: 0
```

3. Freeze the expected output as a golden file and turn the whole thing into a regression test:

```bash
$ kubectl kyverno apply policy.yaml --resource resource.yaml > /tmp/out.yaml
# extract the mutated Pod into patched.yaml, then:
```

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: json-patch-tests
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: set-image-pull-policy
    rule: set-ifnotpresent
    kind: Pod
    resources:
      - multi
    patchedResources: patched.yaml
    result: pass
```

4. Run it:

```bash
$ kubectl kyverno test .
```

```
Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 1 resource ...
  Checking results ...

│───│───────────────────────│──────────────────│──────────────────│────────│
│ ID│ POLICY                │ RULE             │ RESOURCE         │ RESULT │
│───│───────────────────────│──────────────────│──────────────────│────────│
│ 1 │ set-image-pull-policy │ set-ifnotpresent │ v1/Pod/multi     │ Pass   │
│───│───────────────────────│──────────────────│──────────────────│────────│

Test Summary: 1 tests passed and 0 tests failed
```

5. Break the policy deliberately — change `IfNotPresent` to `Never` in `policy.yaml` — and re-run `kubectl kyverno test .` to see a `Fail` with a diff.

6. Restore the policy and confirm the test passes again.

> **Version note.** The `apiVersion: cli.kyverno.io/v1alpha1` Test manifest and the `patchedResources` field are the modern form (Kyverno 1.11+). Older CLIs used an unversioned manifest and a singular `patchedResource`. Run `kubectl kyverno test --help` on your build rather than trusting a memorised schema.

### Questions

- **Q9.1** — Why does `patchedResources` in a `Test` catch a whole class of JSON patch bugs that a `result: pass` assertion alone cannot?
- **Q9.2** — `kyverno apply` runs the policy engine without an API server. Name two things it therefore *cannot* evaluate, and how you supply them.
- **Q9.3** — In a CI pipeline gating a policy repository, where does `kyverno test` sit relative to `kyverno apply`, and which one belongs in a pre-commit hook?

---

## Exercise 10 — JSON Patches against existing resources

`mutateExisting` runs in the background controller, not at admission. Everything you know about JSON Patch still applies — but the failure modes are RBAC-shaped.

### Steps

1. Create ConfigMaps that already carry a labels map:

```bash
$ kubectl -n json-lab create configmap app-config --from-literal=key=value
$ kubectl -n json-lab label configmap app-config app=checkout
$ kubectl -n json-lab create configmap other-config --from-literal=key=value
$ kubectl -n json-lab label configmap other-config app=search
```

2. Grant the background controller permission to update ConfigMaps. Kyverno aggregates ClusterRoles by label — confirm the selector on your install first:

```bash
$ kubectl get clusterrole kyverno:background-controller -o jsonpath='{.aggregationRule}' | jq
```

```yaml
# 14-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:mutate-configmaps
  labels:
    app.kubernetes.io/part-of: kyverno
    app.kubernetes.io/instance: kyverno
    app.kubernetes.io/component: background-controller
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
```

```bash
$ kubectl apply -f 14-rbac.yaml
```

3. Write the `mutateExisting` policy. `match` selects the **trigger**; `targets` selects what gets patched:

```yaml
# 15-mutate-existing.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: label-existing-configmaps
spec:
  mutateExistingOnPolicyUpdate: true
  rules:
    - name: add-managed-label
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              namespaces:
                - json-lab
      mutate:
        targets:
          - apiVersion: v1
            kind: ConfigMap
            namespace: json-lab
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels/managed-by"
            value: kyverno
```

```bash
$ kubectl apply -f 15-mutate-existing.yaml
clusterpolicy.kyverno.io/label-existing-configmaps created
```

4. Wait a few seconds and verify:

```bash
$ kubectl -n json-lab get cm --show-labels
NAME           DATA   AGE   LABELS
app-config     1      2m    app=checkout,managed-by=kyverno
other-config   1      2m    app=search,managed-by=kyverno
```

5. Now remove the RBAC and repeat with a fresh ConfigMap to see the characteristic failure:

```bash
$ kubectl delete -f 14-rbac.yaml
$ kubectl -n json-lab create configmap third-config --from-literal=k=v
$ kubectl -n json-lab label configmap third-config app=cart
$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=30 | grep -i forbidden
```

6. Re-apply the RBAC, then clean up.

### Questions

- **Q10.1** — What is the semantic difference between `match` and `mutate.targets` in a `mutateExisting` rule, and what happens if you omit `targets` entirely?
- **Q10.2** — `mutateExistingOnPolicyUpdate: true` changes when the rule runs. Describe both trigger paths, and explain why leaving it `false` is the safer default on a large cluster.
- **Q10.3** — Admission mutations need no extra RBAC; `mutateExisting` does. Why?
- **Q10.4** — The `/metadata/labels/managed-by` path assumes the labels map exists — as it did here, because you labelled each ConfigMap first. What is the production-safe rewrite?

---

## Exercise 11 — Diagnosing a patch that did not apply

### Steps

1. Deploy a policy with a deliberately wrong pointer (`container` instead of `containers`):

```yaml
# 16-broken.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-pointer
spec:
  rules:
    - name: bad-path
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: replace
            path: "/spec/container/0/imagePullPolicy"
            value: IfNotPresent
```

```bash
$ kubectl apply -f 16-broken.yaml
$ kubectl -n json-lab run diag --image=nginx:1.27
```

2. Walk the diagnostic ladder, cheapest first:

```bash
# 1. Did the object change at all?
$ kubectl -n json-lab get pod diag \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo

# 2. Did the policy even match? Check events on the policy and the resource.
$ kubectl -n json-lab get events --sort-by=.lastTimestamp | tail -20
$ kubectl describe clusterpolicy broken-pointer

# 3. What did the engine actually do?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 | grep -i -e patch -e broken-pointer

# 4. Reproduce offline, deterministically.
$ kubectl kyverno apply 16-broken.yaml --resource <(kubectl -n json-lab get pod diag -o yaml)
```

3. Fix the pointer, re-apply, re-create the Pod, and confirm `last-applied-patches` now appears.

4. Clean up the whole lab:

```bash
$ kubectl delete clusterpolicy --all
$ kubectl delete ns json-lab
$ kind delete cluster --name kca-58
```

### Questions

- **Q11.1** — Order these four signals by how early they should appear in your diagnosis, and say what each one rules in or out: the mutated object, `last-applied-patches`, controller logs, `kyverno apply`.
- **Q11.2** — Kyverno PolicyReports are the canonical source for validate and verifyImages outcomes. Why are they a poor primary signal for a mutate rule, and what *is* the ground truth for mutation?
- **Q11.3** — A rule that never matched and a rule that matched but whose patch failed look similar from the outside. Which single command distinguishes them fastest?

---

## Quick reference

**The six RFC 6902 operations**

| op | Required members | Target must exist? | Notes |
|---|---|---|---|
| `add` | `path`, `value` | parent must exist | on an existing object member, **replaces**; on an array index, **inserts before**; `-` appends |
| `remove` | `path` | yes | errors if missing; on an array, shifts subsequent elements down |
| `replace` | `path`, `value` | yes | equivalent to `remove` + `add`, but atomic and stricter |
| `move` | `from`, `path` | `from` must exist | `path` must not be a location inside `from` |
| `copy` | `from`, `path` | `from` must exist | deep copy of the value |
| `test` | `path`, `value` | yes | failure aborts the **entire** patch |

**JSON Pointer (RFC 6901) escapes** — decode `~1` → `/` first, then `~0` → `~`.

| Literal key | Pointer token |
|---|---|
| `app.kubernetes.io/name` | `app.kubernetes.io~1name` |
| `weird~key` | `weird~0key` |
| `a~1b` | `a~01b` |

**Exam traps, condensed**

1. `patchesJson6902` is a **string** — always `|-`.
2. Unescaped `/` in a label or annotation key silently targets the wrong path.
3. `add` on an existing map **replaces** it — `add /metadata/labels {}` destroys labels.
4. `add …/-` is not idempotent; the webhook fires on UPDATE too.
5. A failed `test` (or any failed op) discards the whole patch list.
6. Hardcoded container indices break on sidecars — use `foreach` + `{{elementIndex}}`.
7. Patches operate on the **defaulted** object, not on your YAML.
8. `mutateExisting` needs explicit RBAC for the background controller.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1** — The **admission controller** deployment hosts the mutating webhook endpoint and rewrites resources in-flight during `CREATE`/`UPDATE`. The **background controller** executes `mutateExisting` rules (and `generate` rules) against objects already stored in etcd; it acts as an ordinary API client, which is why it needs its own RBAC. The reports controller builds PolicyReports; the cleanup controller runs `CleanupPolicy`/TTL deletion.

**A0.2** — A static catch-all webhook would put Kyverno in the request path of *every* API call, including core control-plane traffic, turning a Kyverno outage into a cluster outage and adding latency to operations no policy cares about. By deriving the webhook `rules` from the installed policies, Kyverno intercepts only the group/version/kind/operation combinations that at least one rule actually matches. This is also why a freshly installed Kyverno with no policies is effectively inert, and why applying your first Pod policy causes a short reconciliation delay before it takes effect.

**A0.3** — **After** defaulting. The API server decodes the request body, converts it to internal version and applies API defaults, and *then* runs the mutating admission chain. Consequently the object your JSON Pointer addresses already contains server-populated fields such as `imagePullPolicy`, `restartPolicy`, `dnsPolicy`, `terminationMessagePath` and `serviceAccountName`. This is what makes Exercise 6 work: a `test` on `/spec/containers/0/imagePullPolicy` finds a value even though the submitted YAML never set one. The corollary is that you should write pointers against `kubectl get -o yaml` output, not against the manifest you authored.

### Exercise 1

**A1.1** — RFC 6902 §4.1: *"If the target location specifies an object member that does exist, that member's value is replaced."* `add` is therefore an upsert, not an insert, for object members. The practical consequence is severe: `{"op":"add","path":"/metadata/labels","value":{}}` replaces the entire labels map with an empty object, silently deleting every existing label. Exercise 4 demonstrates this destroying `app`, `tier` and `owner`.

**A1.2** — (a) Guard the rule with a Kyverno `precondition` that checks the field is present, so the patch only runs when `remove` can succeed. (b) Use `patchStrategicMerge` with the `null` directive (`nodeSelector: null` under strategic merge deletes the key and is a no-op when absent). A third option is to place a `test` before the `remove` — but `test` can only assert a *known value*, so it works for "remove it if it equals X", not for "remove it if present".

**A1.3** — `-` is the end-of-array token: `add` at `…/env/-` appends a new element. A numeric index `0` inserts the new element *before* the current element 0, shifting the rest. `-` is only meaningful for `add` (and as the `path` of a `move`/`copy` targeting an array). `remove`, `replace` and `test` require a concrete existing index; using `-` with them is an error, because there is no element at the end-of-array position.

**A1.4** — **An RFC 6902 patch is atomic: if any operation fails, none of the operations are applied and the document is left unchanged.** Because the document is all-or-nothing, `test` becomes a conditional — placing it first makes the success of every following operation contingent on the tested value. It is the only conditional in the specification precisely because there is no branching construct; the abort semantics provide the branch.

**A1.5** — `move` must validate that `path` is **not** a location within `from` (RFC 6902 §4.4). Moving a node into its own subtree is undefined — you would be relocating a value inside the very object you removed. `copy` has no such restriction, since the source remains in place.

### Exercise 2

**A2.1** — `/metadata/labels/app.kubernetes.io~1managed-by`. Only the `/` inside the *key* is escaped; the `/` characters that separate pointer tokens are structural and stay literal.

**A2.2** — `~1` → `/` is decoded **first**, then `~0` → `~`. Inverting the order breaks any key containing the literal sequence `~1`: the key `a~1b` is encoded `a~01b`; decoding `~0` first yields `a~1b` and then the `~1` rule would turn it into `a/b` — a different, wrong key. The mandated order is unambiguous in both directions.

**A2.3** — `/metadata/annotations/kca.example.com/owner` is a perfectly well-formed pointer; it just addresses a *different* location — the member `owner` inside an object named `kca.example.com` inside `annotations`. Nothing in the syntax is invalid, so no parser complains. You only find out at apply time, and only if the operation happens to be one that requires the path to exist. An `add` with the same unescaped path would *succeed*, creating a nested object `{"kca.example.com": {"owner": "sre"}}` — which is not even a valid annotation map. That silent-success case is why this bug reaches production.

### Exercise 3

**A3.1** — Because Kyverno's CRD schema declares `patchesJson6902` as a `string`, not as an array of objects. The block scalar hands Kyverno the raw text, which Kyverno parses as a JSON Patch document after variable substitution. Writing it as a native YAML list fails CRD validation. The two-stage handling is also what allows `{{ }}` variables to be interpolated into the text before it is parsed.

**A3.2** — RFC 6902 §4.1 requires that the *parent* of the target location exist; `add` creates the final member only. It does **not** create intermediate objects. However, the `evanphx/json-patch` library used by Kyverno offers an `EnsurePathExistsOnAdd` option that auto-creates missing intermediate paths, and whether Kyverno enables it has varied across releases. That is exactly why step 7 asked you to record the observed behaviour rather than be told it. **The portable rule: never depend on it.** Either target a parent you know exists, or use `patchStrategicMerge`.

**A3.3** — Use `patchStrategicMerge`, which merges maps rather than replacing them and creates missing parents naturally:

```yaml
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              team: platform
```

This is idempotent, non-destructive, and readable. JSON Patch is the wrong tool for adding a key to a map.

**A3.4** — Kyverno stamps `policies.kyverno.io/last-applied-patches` on every resource it mutates, recording `<rule>.<policy>.kyverno.io: <action> <path>` for each applied operation. It is the cheapest possible signal: its presence proves the rule matched *and* the patch applied; its absence means the rule did not match, was skipped by a precondition or `test`, or errored — and you then move to events and controller logs to distinguish those. (It can be disabled via Kyverno configuration, so verify it is enabled on your install before treating absence as proof.)

### Exercise 4

**A4.1** — RFC 6902 §4.1's replace-on-existing-member rule. `{"op":"add","path":"/metadata/labels","value":{}}` found `/metadata/labels` present and replaced its entire value with `{}`. The second operation then added `team: platform` to that now-empty map, leaving exactly one label.

**A4.2** — **No.** `test` requires the target location to exist; if `/metadata/labels` is absent, the `test` itself fails and aborts the patch — which is the same outcome as a failed assertion, so you cannot distinguish "absent" from "present but different". RFC 6902 provides no "exists" or "not exists" predicate. This is a genuine expressiveness gap in the specification, and it is why Kyverno layers `preconditions` (JMESPath, evaluated outside the patch) on top of it.

**A4.3** — **Use `patchStrategicMerge` by default.** It understands the Kubernetes schema, merges maps, honours `patchMergeKey` on lists, is idempotent, and supports Kyverno's conditional anchors. **Reach for `patchesJson6902` only when strategic merge cannot express the change**: deleting a field the schema does not let you null out, positional list operations (insert at index, reorder, append to an atomic list), `move`/`copy`, or value-conditional mutation via `test`.

**A4.4** — Kyverno resolves `{{ … }}` before parsing the patch. If `request.object.metadata.labels` is absent, the expression resolves to nothing and the rule **errors** rather than evaluating to a false condition — an unresolved variable is a rule failure, not an empty value. `|| ''` supplies a JMESPath fallback so the expression always yields a comparable value, letting the precondition evaluate cleanly to `true`.

### Exercise 5

**A5.1** — Kyverno registers a mutating webhook for `CREATE` and `UPDATE` by default. `kubectl annotate` issues a `PATCH`/`UPDATE` on the Deployment; the API server sends the *entire post-modification object* through the mutating chain again. Kyverno re-evaluates the rule against that object, which already contains `CLUSTER_TIER` from the CREATE, and `add …/env/-` dutifully appends a second copy. The rule has no memory and the operation has no notion of "already there" — every admission review appends once more.

**A5.2** — The kubelet builds the container environment by iterating the list in order, so a later duplicate overwrites an earlier one — effectively last-wins. "It still works" is dangerous for three reasons: the list grows unbounded across updates and will eventually hit the etcd object size limit (~1.5 MiB) and start failing writes; the semantics are kubelet implementation detail, not API contract; and it makes the object unreviewable, masking a genuine drift between what the manifest says and what runs. The same bug applied to `tolerations`, `volumes` or `imagePullSecrets` produces a resource that no longer round-trips through GitOps.

**A5.3** — `match.any[].resources.operations` (Kyverno 1.11+) is materially better when you want the *webhook itself* narrowed: Kyverno derives the `MutatingWebhookConfiguration` rules from the match block, so restricting to `CREATE` means the API server never calls Kyverno for updates at all — less latency, less blast radius, fewer moving parts. A precondition is the only option when the condition is not expressible as a match field: for example gating on `{{ request.userInfo.groups }}`, on a value inside the object, or on a lookup against a ConfigMap or the API server via a `context`. Preconditions run inside the engine, so the webhook still fires.

**A5.4** — `EnvVar` in the Kubernetes API carries `patchStrategy:"merge"` with `patchMergeKey:"name"`, so strategic merge treats the list as a keyed set and merges entries by `name`. Lists without a declared merge strategy are **atomic**: strategic merge replaces the whole list. To determine this for an arbitrary field, inspect the API type's struct tags in `k8s.io/api` (`patchStrategy` / `patchMergeKey`), or read the published schema — `kubectl explain --recursive` and the OpenAPI document expose `x-kubernetes-patch-strategy` and `x-kubernetes-patch-merge-key`. Never assume; `containers`, `env`, `volumeMounts` and `imagePullSecrets` merge, many other lists do not.

**A5.5** — With a sidecar, index `0` is whichever container happens to be listed first — determined by manifest authoring order, which is not a contract. The policy would set `CLUSTER_TIER` on the application container in one Deployment and on the log shipper in the next, and would silently do the wrong thing forever. The correct construct is `mutate.foreach` over `request.object.spec.containers`, using `{{elementIndex}}` in the pointer (Exercise 8) — or `patchStrategicMerge` with the `(name): "*"` anchor, which applies to every container by schema.

### Exercise 6

**A6.1** — API defaulting, which runs during decoding/conversion *before* the mutating admission chain. `nginx:latest` defaults `imagePullPolicy` to `Always`; any other tag or a digest defaults it to `IfNotPresent`. The general lesson: **write JSON Pointers against the object as the API server presents it to the webhook, not against your source YAML.** Always confirm the real shape with `kubectl get <obj> -o yaml`, or by dumping the AdmissionReview, before assuming a path exists.

**A6.2** — RFC 6902 §4.6 defines value equality structurally, not textually. Objects are equal if they have the same set of members and each member's value is equal — **member order is irrelevant**, so `{"a":1,"b":2}` equals `{"b":2,"a":1}`. Arrays are equal only if they have the same number of elements *and* each element is equal to the element at the same position — **order matters**, so `[1,2]` does **not** equal `[2,1]`. This asymmetry is why `test` against a list is fragile in Kubernetes, where the API server may reorder or default list entries.

**A6.3** — Atomicity: a JSON Patch is applied as a unit; if any operation fails, the document is left entirely unchanged. The `test` guard therefore protects every operation in the list, related or not. To apply the annotation unconditionally, split into two rules within the same policy — one rule containing only the guarded `test` + `replace`, a second rule containing only the `add` for the annotation. Kyverno evaluates rules independently, so a failure in one does not suppress the other.

**A6.4** — Prefer a **`precondition`** when the condition involves data outside the patched document (`request.operation`, `request.userInfo`, a `context` lookup against a ConfigMap or the API server, an image registry), when you need boolean composition (`any`/`all`), when you need a JMESPath expression rather than a value comparison, or when you want the rule to *skip* cleanly rather than error. Prefer **`test`** when the condition is a simple equality against a value already inside the object *and* you want the guarantee that a mid-patch surprise aborts everything atomically — `test` is evaluated against the document at the moment the patch runs, closing the gap between "checked" and "applied" that a precondition technically leaves open.

### Exercise 7

**A7.1** — The variable's value is spliced into the patch text before parsing, so a `/` in the value becomes a **structural pointer separator**, not a literal character. Interpolating `{{ request.object.metadata.labels.app }}` into a `path` when the label value is `team/checkout` produces `/metadata/annotations/team/checkout` — an entirely different location. This is a policy-injection hazard as well as a bug: never interpolate untrusted values into a `path`. Interpolate into `value`; keep `path` static, or restrict it to values you control such as `{{elementIndex}}`.

**A7.2** — The rule **errors**. In Kyverno an unresolved variable is a hard failure, not an implicit empty string, and the rule result becomes `error` rather than `skip`. `|| 'default'` is mandatory hygiene because the difference between "field absent" and "field empty" is not visible in the policy text, and a policy that errors on a subset of workloads is worse than one that behaves predictably — with `failurePolicy: Fail` on the webhook, a mutation error can block legitimate workloads from being admitted.

**A7.3** — **No.** `request.userInfo`, `request.operation` and the rest of the `request` context come from the AdmissionReview, which only exists at admission time. A `mutateExisting` rule runs later, in the background controller, against an object read from the API server — there is no AdmissionReview and no requesting user. In a `mutateExisting` rule the object under mutation is addressed via `target` (and the triggering object via `request.object`, when a trigger fired it); design accordingly.

**A7.4** — Every key was domain-prefixed (`kca.example.com/created-by`), and RFC 6901 requires the `/` inside a key to be escaped as `~1`. Unescaped, `add` would have succeeded but created a nested object `{"kca.example.com": {"created-by": "..."}}` under `annotations` — which the API server would reject, since annotation values must be strings, producing a confusing validation error far from the real cause.

### Exercise 8

**A8.1** — It eliminates position-dependence: the rule applies to every container regardless of how many there are or the order the author wrote them in, so adding a sidecar cannot silently redirect the mutation to the wrong container. The cost is readability and debuggability — the pointer is no longer a literal you can paste into `kubectl get -o jsonpath`, and reasoning about which iteration produced which patch requires reading the `foreach` list expression too. It also means an empty list produces zero operations, so a mistyped `list:` expression fails silently rather than loudly.

**A8.2** — When the loop appends with `/-`, each iteration lengthens the array, so `{{elementIndex}}` — computed from the *original* list — no longer corresponds to the position in the document being patched. The indices drift, and operations that assumed element *n* end up addressing element *n+k*. Avoid it by never combining `foreach` iteration with array-growing operations on the same array: use `add` on a scalar sub-path (as in this exercise), or switch to `patchStrategicMerge` with the `(name): "*"` anchor, which is schema-aware and index-free.

**A8.3** — No. `list: "request.object.spec.containers"` iterates only the main containers, and the pointer prefix `/spec/containers/` only addresses them. Add a second `foreach` entry with `list: "request.object.spec.initContainers"` and path prefix `/spec/initContainers/`, and a third for `ephemeralContainers` if in scope. Note that `initContainers` may be absent entirely — guard with a fallback (`request.object.spec.initContainers || \`[]\``) so the loop degrades to zero iterations instead of erroring.

**A8.4** — A rule-level `preconditions` block decides whether the **entire rule** runs, and is evaluated once against the admission request. A `preconditions` block nested inside a `foreach` entry is evaluated **per element**, with `{{element}}` and `{{elementIndex}}` in scope, and decides whether that element's patch is applied. Step 4 uses the nested form so `busybox` is skipped while the other two containers are still mutated — a rule-level precondition could only have skipped all three.

### Exercise 9

**A9.1** — `result: pass` only asserts that the rule executed successfully; it says nothing about *what* the patch produced. A pointer typo that lands on the wrong field, a `value` with the wrong type, an off-by-one array index, or a `~1` escape mistake can all yield `pass` while producing a wrong object. `patchedResources` compares the engine's actual output against a golden manifest, turning the mutation into a byte-level regression test. For JSON Patch specifically — where the whole risk is *where* the change lands — this is the assertion that matters.

**A9.2** — Without an API server it cannot evaluate (a) `context` entries that perform API or ConfigMap lookups, and (b) AdmissionReview-derived values such as `request.userInfo`, `request.operation` and `request.roles`. You supply both through a **values file** (`--values-file` / the `variables` section of a `Test` manifest), which lets you pin variable values and simulate different users, operations and namespace labels. It also cannot see other cluster objects, so `mutateExisting` targets must be provided as resources.

**A9.3** — `kyverno apply` is the *exploratory* command — fast, prints the mutated object, ideal in a pre-commit hook or while iterating on a pointer. `kyverno test` is the *assertive* command — it compares against golden `patchedResources` and exits non-zero on mismatch, so it belongs in CI as the merge gate. A healthy repo uses `apply` while authoring and `test` to prevent regressions; only `test` has a meaningful exit code contract to gate on.

### Exercise 10

**A10.1** — `match` defines the **trigger**: the resource whose admission (or the policy update itself) causes the rule to fire. `mutate.targets` defines **what actually gets patched** — resources looked up in the cluster, potentially of a different kind and in a different namespace from the trigger. If you omit `targets`, the rule is no longer a `mutateExisting` rule at all: it becomes an ordinary admission mutation that patches the matched resource in-flight.

**A10.2** — With `mutateExistingOnPolicyUpdate: true`, the rule fires both (a) when the policy is created or updated — sweeping every existing target — and (b) whenever a matching trigger resource is admitted. With `false` (the default), only the trigger path applies; existing resources are left alone until something triggers the rule. `false` is safer on a large cluster because a single `kubectl apply` of the policy would otherwise issue an update against every matching object at once, potentially thousands of API writes, mass-restarting workloads if the patch touches a Pod template, and doing so before you have observed the patch's effect on even one object.

**A10.3** — At admission Kyverno never touches the API server: it receives an AdmissionReview, returns a JSON Patch in the response, and the **API server** applies it under the *original requester's* authority. Nothing is written by Kyverno, so no RBAC is needed. `mutateExisting` is the opposite — the background controller reads and `update`s objects as itself, an ordinary authenticated client, and Kubernetes authorises it like any other. Hence the aggregated ClusterRole in step 2 and the `forbidden` errors in step 5.

**A10.4** — Use `patchStrategicMerge` (`metadata: {labels: {managed-by: kyverno}}`), which creates the map if absent and merges into it if present. If JSON Patch is required for other reasons, guard the rule with a precondition on `{{ target.metadata.labels || '' }}` and provide a separate rule for the map-absent case — but for adding a single label, strategic merge is unambiguously the right tool.

### Exercise 11

**A11.1** — (1) **`last-applied-patches`** — cheapest, one field read; present means matched *and* applied, so you are done. (2) **The mutated object itself** — confirms the patch landed where you intended, catching the "applied but wrong path" case that the annotation alone does not reveal. (3) **Controller logs** — distinguishes "did not match" from "matched but the patch errored", and gives the underlying `evanphx` error text (`doc is missing path`, `test failed`). (4) **`kyverno apply`** — the most expensive but the most conclusive: a deterministic offline reproduction you can iterate on in seconds without disturbing the cluster, and the artefact you attach to a bug report.

**A11.2** — PolicyReports record pass/fail/skip/error per rule, and are generated primarily for `validate` and `verifyImages` results, where the outcome *is* a verdict. A mutation's outcome is not a verdict — it is a transformed object. A mutate rule can report `pass` while having written to a path you did not intend. The ground truth for mutation is the stored object (`kubectl get -o yaml`), corroborated by `last-applied-patches` and, for offline verification, `patchedResources` in a `kyverno test`.

**A11.3** — `kubectl kyverno apply <policy> --resource <the object as stored>`. It re-runs the engine offline and prints the per-rule outcome explicitly — a non-matching rule reports `skip`, whereas a matching rule with a bad pointer reports `error` along with the JSON Patch failure message. One command, no cluster state, unambiguous answer. (In-cluster, `kubectl describe clusterpolicy <name>` plus the admission controller log gives the same distinction, but with more noise.)

</details>

---

## Sources

- CNCF KCA curriculum — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- RFC 6902, *JavaScript Object Notation (JSON) Patch* — <https://datatracker.ietf.org/doc/html/rfc6902>
- RFC 6901, *JavaScript Object Notation (JSON) Pointer* — <https://datatracker.ietf.org/doc/html/rfc6901>
- Kyverno documentation, mutation rules and `patchesJson6902` — <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno documentation, preconditions — <https://kyverno.io/docs/writing-policies/preconditions/>
- Kyverno CLI documentation — <https://kyverno.io/docs/kyverno-cli/>
- Kyverno source and release notes — <https://github.com/kyverno/kyverno>
- `evanphx/json-patch`, the RFC 6902 implementation used by both the Kubernetes API server and Kyverno — <https://github.com/evanphx/json-patch>
- Kubernetes documentation, *Update API Objects in Place Using kubectl patch* — <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/>
- Kubernetes documentation, *Dynamic Admission Control* — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>