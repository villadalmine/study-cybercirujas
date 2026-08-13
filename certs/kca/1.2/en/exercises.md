# Topic 1.2 — YAML Manifests: Guided Exercises

> **What you will build**: the muscle memory to read, author, validate and debug Kubernetes object manifests *before* they ever reach the API server. YAML is the contract surface of Kubernetes — every `kubectl apply`, every GitOps commit, every Helm template ultimately renders to the manifests you practise here. Getting the mechanics wrong fails silently or, worse, applies something subtly different from what you meant.
>
> **Environment assumed**: any single-node cluster (`kind`, `minikube`, or k3s) with `kubectl` configured. Nothing you do here writes to a shared cluster; every object lives in a throwaway namespace you create in Exercise 0. Where a command's output matters, the *expected* output is shown — compare yours against it.

---

## Exercise 0 — Scratch namespace and tooling check

**Steps**

1. Confirm your client and server versions agree on the API you will target:

   ```bash
   kubectl version --output=yaml | grep gitVersion
   ```

   Expected (versions will differ):

   ```
     gitVersion: v1.31.0
       gitVersion: v1.31.0
   ```

2. Create an isolated namespace so nothing you apply collides with real workloads:

   ```bash
   kubectl create namespace kca-yaml
   ```

   Expected:

   ```
   namespace/kca-yaml created
   ```

3. Make it the default for this shell so you can drop `-n kca-yaml` from every command:

   ```bash
   kubectl config set-context --current --namespace=kca-yaml
   ```

   Expected:

   ```
   Context "kind-kind" modified.
   ```

**Check your understanding**

- **Q0.1** Why does the *server* `gitVersion` matter more than the client version when you are deciding which `apiVersion` to write in a manifest?
- **Q0.2** `kubectl create namespace kca-yaml` is an *imperative* command. What is the exact declarative manifest it is equivalent to?

---

## Exercise 1 — YAML syntax that Kubernetes actually cares about

YAML is a superset of JSON, but the failure modes that bite in Kubernetes are almost always about **indentation**, **scalar typing**, and **null vs. empty**. This exercise isolates each one.

**Steps**

1. Create `types.yaml` and let the YAML parser — not Kubernetes — tell you how it typed each value. We use a `ConfigMap` because its `data` values must all be strings, which makes mistyping visible:

   ```yaml
   # types.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: type-demo
   data:
     plain_string: hello
     looks_like_int: 8080
     looks_like_bool: true
     norway_problem: no
     quoted_bool: "true"
     multiline: |
       line one
       line two
   ```

2. Ask the server to validate and *return what it would store*, without persisting anything, using a client-side dry run rendered back as YAML:

   ```bash
   kubectl apply -f types.yaml --dry-run=client -o yaml
   ```

3. Read the `data:` block in the output carefully. Then apply for real and confirm it was rejected or coerced:

   ```bash
   kubectl apply -f types.yaml
   ```

   Expected:

   ```
   Error from server (BadRequest): error when creating "types.yaml": ConfigMap in version "v1" cannot be handled as a ConfigMap: json: cannot unmarshal number into Go struct field ConfigMap.data of type string
   ```

4. Fix the manifest by quoting every non-string scalar, re-apply, and inspect the stored result:

   ```yaml
   # types.yaml (fixed)
   data:
     plain_string: hello
     looks_like_int: "8080"
     looks_like_bool: "true"
     norway_problem: "no"
     quoted_bool: "true"
     multiline: |
       line one
       line two
   ```

   ```bash
   kubectl apply -f types.yaml
   kubectl get configmap type-demo -o jsonpath='{.data.norway_problem}{"\n"}'
   ```

   Expected:

   ```
   configmap/type-demo created
   no
   ```

**Check your understanding**

- **Q1.1** In step 3 the ConfigMap failed but a Pod with `env` value `8080` would *also* fail for the same reason. State the general rule: which YAML scalars must you quote in a Kubernetes manifest, and why does the parser's default typing cause the failure?
- **Q1.2** The "Norway problem": unquoted `no`, `off`, `yes`, `on`, `y`, `n` are parsed as booleans by YAML 1.1 parsers. Which Kubernetes field families does this most dangerously affect, and what is the one-character habit that prevents it?
- **Q1.3** The `multiline` value uses `|`. What is the difference in the *stored string* between `|`, `|-`, `>`, and `>-`? Predict whether `line one\nline two\n` or `line one line two` is stored for `|`.

---

## Exercise 2 — Anatomy of every Kubernetes object: the four required top-level fields

Every object manifest — Pod, Service, Deployment, CRD instance — has the same skeleton: `apiVersion`, `kind`, `metadata`, and (almost always) `spec`. `status` exists but is **owned by the control plane**, not you.

**Steps**

1. Write a minimal but complete Pod. Note there is exactly one container, and every required field is present:

   ```yaml
   # pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
     labels:
       app: web
       tier: frontend
   spec:
     containers:
       - name: nginx
         image: nginx:1.27-alpine
         ports:
           - containerPort: 80
   ```

2. Apply it and immediately dump the *full* object the server built from your four fields:

   ```bash
   kubectl apply -f pod.yaml
   kubectl get pod web -o yaml
   ```

3. In that output, locate three blocks you did **not** write: `metadata.uid`, `metadata.creationTimestamp` / `resourceVersion`, and the entire `status:` tree. These are server-managed.

4. Use `kubectl explain` to interrogate the schema of a field *without leaving the terminal* — this is the single most useful manifest-authoring tool in the exam:

   ```bash
   kubectl explain pod.spec.containers.ports --recursive
   ```

   Expected (excerpt):

   ```
   KIND:       Pod
   VERSION:    v1
   FIELD: ports <[]ContainerPort>
   ...
      containerPort <integer> -required-
      hostPort      <integer>
      name          <string>
      protocol      <string>
   ```

**Check your understanding**

- **Q2.1** You edit `pod.yaml`, add a bogus `metadata.uid: 12345`, and re-apply. What happens, and what does that tell you about which fields are *writable*?
- **Q2.2** `kubectl explain pod.spec.containers.ports` marks `containerPort` as `-required-` but `protocol` is not. What default does the server fill in for `protocol`, and how would you confirm the default *without reading the docs*?
- **Q2.3** Explain the difference between `apiVersion: v1` (for a Pod) and `apiVersion: apps/v1` (for a Deployment). What does the empty group in `v1` signify, and where does the group name come from?

---

## Exercise 3 — Labels, selectors, and the manifest coupling that must match

The single most common manifest bug in real clusters is a **selector that does not match the pod template labels**. A Deployment whose `spec.selector` disagrees with `spec.template.metadata.labels` is rejected outright; a Service whose selector is merely *wrong* is accepted and silently routes to nothing.

**Steps**

1. Write a Deployment with an *intentionally* mismatched selector:

   ```yaml
   # deploy-bad.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: webserver   # <-- does NOT match the selector above
       spec:
         containers:
           - name: nginx
             image: nginx:1.27-alpine
   ```

2. Apply it and read the error precisely:

   ```bash
   kubectl apply -f deploy-bad.yaml
   ```

   Expected:

   ```
   The Deployment "web" is invalid: spec.template.metadata.labels: Invalid value: map[string]string{"app":"webserver"}: `selector` does not match template `labels`
   ```

3. Fix `app: webserver` → `app: web`, apply, and confirm the ReplicaSet adopted the pods:

   ```bash
   kubectl apply -f deploy-bad.yaml
   kubectl get deploy,rs,pods -l app=web
   ```

   Expected (names hashed differently for you):

   ```
   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/web   2/2     2            2           10s

   NAME                             DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-6c9f8b7d5f   2         2         2       10s

   NAME                       READY   STATUS    RESTARTS   AGE
   pod/web-6c9f8b7d5f-abcde   1/1     Running   0          10s
   pod/web-6c9f8b7d5f-fghij   1/1     Running   0          10s
   ```

4. Now add a Service whose selector is *syntactically valid but semantically wrong*, so it is accepted yet routes nowhere:

   ```yaml
   # svc.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector:
       app: web   # typo — no pod carries this label
     ports:
       - port: 80
         targetPort: 80
   ```

   ```bash
   kubectl apply -f svc.yaml
   kubectl get endpoints web
   ```

   Expected:

   ```
   NAME   ENDPOINTS   AGE
   web    <none>      5s
   ```

**Check your understanding**

- **Q3.1** Why does the Deployment in step 2 *fail validation* while the Service in step 4 is *accepted* despite both having a selector mismatch? What does this reveal about which relationships the API server structurally enforces vs. leaves to runtime?
- **Q3.2** `kubectl get endpoints web` shows `<none>`. Which controller is responsible for populating that Endpoints (or EndpointSlice) object, and why is an empty endpoint list the fastest diagnostic for a mis-selectored Service?
- **Q3.3** A Deployment's `spec.selector` is **immutable** after creation. Given that, what is the correct manifest-level procedure to change the label scheme of a running Deployment?

---

## Exercise 4 — Multi-document manifests and apply ordering

A single `.yaml` file can hold many objects separated by `---`. `kubectl apply -f` processes them in file order, which matters when one object references another.

**Steps**

1. Put a ConfigMap and a Pod that consumes it in one file, ConfigMap first:

   ```yaml
   # app.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: app-config
   data:
     GREETING: "hello from configmap"
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: consumer
   spec:
     restartPolicy: Never
     containers:
       - name: shell
         image: busybox:1.36
         command: ["sh", "-c", "echo $GREETING && sleep 3600"]
         env:
           - name: GREETING
             valueFrom:
               configMapKeyRef:
                 name: app-config
                 key: GREETING
   ```

2. Apply the whole file in one shot:

   ```bash
   kubectl apply -f app.yaml
   ```

   Expected:

   ```
   configmap/app-config created
   pod/consumer created
   ```

3. Confirm the value was injected:

   ```bash
   kubectl logs consumer
   ```

   Expected:

   ```
   hello from configmap
   ```

4. Test what happens when the reference is dangling. Delete the ConfigMap but leave the Pod spec referencing it, then force a fresh pod:

   ```bash
   kubectl delete configmap app-config
   kubectl delete pod consumer
   kubectl apply -f app.yaml    # re-creates both — reverse this to test the failure
   ```

   To actually observe the failure mode, apply *only* the Pod document against a cluster with no ConfigMap:

   ```bash
   kubectl delete pod consumer
   kubectl delete configmap app-config
   kubectl apply -f app.yaml    # applies both again; now delete just the CM and recreate the pod:
   kubectl delete configmap app-config
   kubectl delete pod consumer --ignore-not-found
   kubectl run consumer --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"shell","image":"busybox:1.36","command":["sh","-c","echo $GREETING"],"env":[{"name":"GREETING","valueFrom":{"configMapKeyRef":{"name":"app-config","key":"GREETING"}}}]}]}}'
   kubectl get pod consumer
   ```

   Expected:

   ```
   NAME       READY   STATUS                       RESTARTS   AGE
   consumer   0/1     CreateContainerConfigError   0          8s
   ```

**Check your understanding**

- **Q4.1** `kubectl apply -f app.yaml` created the ConfigMap *before* the Pod. Is this ordering guaranteed by document order in the file, and would the Pod have failed if the order were reversed? Explain what the kubelet does when a referenced ConfigMap is missing at pod start.
- **Q4.2** The failing pod shows `CreateContainerConfigError`, not `ImagePullBackOff` or `CrashLoopBackOff`. Map each of those three statuses to *which stage* of pod startup produced it.
- **Q4.3** You have a directory `manifests/` with 12 files. What is the difference between `kubectl apply -f manifests/` and `kubectl apply -f manifests/ --recursive`, and how does apply decide the *order* across separate files?

---

## Exercise 5 — Validating before you apply: dry-run, server-side validation, and diff

Applying to find out if a manifest is correct is the beginner reflex. Production practice validates *first*. There are three tiers, each catching a different class of error.

**Steps**

1. **Client dry-run** — catches YAML syntax and local schema shape only, never touches the server for admission:

   ```bash
   kubectl apply -f pod.yaml --dry-run=client
   ```

   Expected:

   ```
   pod/web configured (dry run)
   ```

2. **Server dry-run** — runs the full admission chain (defaulting, validation, mutating/validating webhooks, quota) and rolls back, persisting nothing:

   ```bash
   kubectl apply -f pod.yaml --dry-run=server
   ```

3. Introduce an *unknown field* — a typo'd key that client validation misses but server-side strict validation catches:

   ```yaml
   # pod-typo.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: typo
   spec:
     containers:
       - name: nginx
         image: nginx:1.27-alpine
         portz:            # <-- misspelled 'ports'
           - containerPort: 80
   ```

   ```bash
   kubectl apply -f pod-typo.yaml --dry-run=server
   ```

   Expected:

   ```
   error: error validating "pod-typo.yaml": error validating data: ValidationError(Pod.spec.containers[0]): unknown field "portz" in io.k8s.api.core.v1.Container; if you choose to ignore these errors, turn validation off with --validate=false
   ```

4. **Diff** — show exactly what would change against the *live* object before you commit:

   ```bash
   kubectl diff -f pod.yaml
   ```

   Expected (no changes on an already-applied pod):

   ```
   (no output, exit code 0)
   ```

   Now bump the image in `pod.yaml` to `nginx:1.27` and re-run:

   ```bash
   kubectl diff -f pod.yaml
   ```

   Expected (excerpt):

   ```diff
   -    image: nginx:1.27-alpine
   +    image: nginx:1.27
   ```

**Check your understanding**

- **Q5.1** State one class of error that `--dry-run=client` will *never* catch but `--dry-run=server` will. Give a concrete example involving an admission webhook or a ResourceQuota.
- **Q5.2** Since Kubernetes 1.25, server-side field validation is the default for `kubectl apply`. What are the three values of `--validate` (`strict`, `warn`, `ignore`), and what does each do with the `portz` typo?
- **Q5.3** `kubectl diff` returns exit code `1` when there is a difference and `0` when there is none. How would you use that in a CI gate that *fails the build if the cluster has drifted* from the manifests in git?

---

## Exercise 6 — Declarative apply internals: the last-applied annotation and 3-way merge

`kubectl apply` is not "overwrite the object with my file." It computes a **three-way merge** between (a) your new manifest, (b) the object's last-applied configuration, and (c) the live object. Understanding this explains why fields you delete from your file actually get removed, while fields other controllers add are preserved.

**Steps**

1. Apply a clean Deployment and inspect the annotation apply uses as its bookkeeping:

   ```bash
   kubectl apply -f deploy-bad.yaml   # the fixed version from Ex.3
   kubectl get deploy web -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | head -c 200
   echo
   ```

   Expected (truncated JSON of your last applied manifest):

   ```
   {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"annotations":{},"name":"web","namespace":"kca-yaml"},"spec":{"replicas":2,...
   ```

2. Scale the Deployment *imperatively* to simulate an out-of-band change (as an HPA or an operator might):

   ```bash
   kubectl scale deploy web --replicas=5
   kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   Expected: `5`

3. Now re-apply your file, which still says `replicas: 2`. Because `replicas` *is* in your last-applied set, the 3-way merge resets it:

   ```bash
   kubectl apply -f deploy-bad.yaml
   kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   Expected: `2`

4. Delete `replicas` entirely from your file, apply, and observe apply *remove ownership* of that field (it drops to the schema default of 1, or is left to an HPA):

   ```yaml
   # deploy-bad.yaml — remove the 'replicas: 2' line, keep everything else
   ```

   ```bash
   kubectl apply -f deploy-bad.yaml
   kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   Expected: `1`

**Check your understanding**

- **Q6.1** In step 3 apply reset `replicas` from 5 to 2, but in step 4 removing the field let it fall to 1. Walk through the three-way merge (last-applied, live, new manifest) that produces each outcome.
- **Q6.2** Why is mixing `kubectl apply` with `kubectl edit`/`kubectl scale` on the *same field* considered an anti-pattern? Relate your answer to the last-applied annotation.
- **Q6.3** **Server-Side Apply** (`kubectl apply --server-side`) replaces this client-side annotation mechanism with `metadata.managedFields`. What problem with the client-side 3-way merge does field ownership tracking solve, and what does a conflict error look like when two managers fight over one field?

---

## Exercise 7 — DRY YAML: anchors, aliases, and merge keys (and their limits)

YAML has native reuse via `&anchor`, `*alias`, and the `<<:` merge key. These are resolved by the **YAML parser before Kubernetes ever sees the document**, which is both their power and their trap.

**Steps**

1. Use an anchor to share resource limits across two containers:

   ```yaml
   # anchors.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: anchored
   spec:
     containers:
       - name: app
         image: nginx:1.27-alpine
         resources: &std-resources
           requests:
             cpu: "100m"
             memory: "64Mi"
           limits:
             cpu: "250m"
             memory: "128Mi"
       - name: sidecar
         image: busybox:1.36
         command: ["sleep", "3600"]
         resources: *std-resources
   ```

2. Prove the alias expanded *before* apply by rendering it client-side:

   ```bash
   kubectl apply -f anchors.yaml --dry-run=client -o yaml | grep -A6 'name: sidecar'
   ```

   Expected (the sidecar carries a full copy, not a reference):

   ```
       name: sidecar
       resources:
         limits:
           cpu: 250m
           memory: 128Mi
         requests:
           cpu: 100m
           memory: 64Mi
   ```

3. Now try to reuse an anchor *across two documents* in the same file — and watch it fail, because anchor scope is a single document:

   ```yaml
   # cross-doc.yaml
   metadata: &common
     labels:
       team: platform
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     <<: *common          # alias from the previous document — out of scope
     name: broken
   spec:
     containers:
       - name: c
         image: nginx:1.27-alpine
   ```

   ```bash
   kubectl apply -f cross-doc.yaml --dry-run=client
   ```

   Expected:

   ```
   error: error parsing cross-doc.yaml: error converting YAML to JSON: yaml: unknown anchor 'common' referenced
   ```

**Check your understanding**

- **Q7.1** In step 2 the sidecar's rendered YAML contains a *full copy* of the resource block, not a pointer. Why does this mean anchors give you authoring-time DRY but zero runtime coupling — and what happens if you later `kubectl edit` only one container's limits?
- **Q7.2** Anchors are scoped to a single YAML document. Given the failure in step 3, what tool would you reach for instead to share configuration across *many* manifests — and why do teams generally prefer Kustomize/Helm over YAML anchors for anything beyond a single file?
- **Q7.3** The merge key `<<:` merges maps but has a specific override rule. If both the anchored map and the local map define `labels.team`, which one wins?

---

## Exercise 8 — Reading a manifest failure top-down: a diagnostic drill

You are handed a failing manifest and must find the fault using only `kubectl` and reasoning — no editing until you have named the bug.

**Steps**

1. Apply this deliberately broken manifest:

   ```yaml
   # mystery.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: mystery
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: mystery
     template:
       metadata:
         labels:
           app: mystery
       spec:
         containers:
           - name: app
             image: nginx:1.27-alpine
             resources:
               requests:
                 memory: 64Mi        # <-- unquoted, and no unit ambiguity here, but watch the next line
               limits:
                 memory: 32Mi        # <-- limit is LOWER than request
   ```

2. Apply and observe the admission-time rejection:

   ```bash
   kubectl apply -f mystery.yaml
   ```

   Expected:

   ```
   The Deployment "mystery" is invalid: spec.template.spec.containers[0].resources.requests: Invalid value: "64Mi": must be less than or equal to memory limit of 32Mi
   ```

3. Fix the limit (`memory: 128Mi`), re-apply, and walk the object graph the way you would in an exam or incident:

   ```bash
   kubectl apply -f mystery.yaml
   kubectl get deploy mystery
   kubectl describe deploy mystery | sed -n '/Conditions/,/Events/p'
   kubectl get rs -l app=mystery
   kubectl get pods -l app=mystery
   ```

4. If a pod were still not Running, the ordered diagnostic path is: `kubectl describe pod <p>` → read **Events** bottom section → then `kubectl logs <p> [-c container] [--previous]`. Practise it:

   ```bash
   POD=$(kubectl get pod -l app=mystery -o jsonpath='{.items[0].metadata.name}')
   kubectl describe pod "$POD" | tail -n 15
   ```

**Check your understanding**

- **Q8.1** The error in step 2 was caught at *admission time* (synchronous, on `apply`). Contrast that with a `memory` limit set *too low but still ≥ request* — where and when would that failure surface instead, and what would the pod status be?
- **Q8.2** Put these five diagnostic commands in the correct top-down order for a Deployment whose pods are not Ready, and say what each one rules in or out: `kubectl logs`, `kubectl get deploy`, `kubectl describe pod`, `kubectl get rs`, `kubectl get events --sort-by=.lastTimestamp`.
- **Q8.3** Why is `kubectl describe` often more useful than `kubectl get -o yaml` when triaging a failing object, even though the YAML contains strictly more data?

---

## Exercise 9 — Cleanup

**Steps**

1. Delete everything by namespace — the cleanest teardown, since every object you made lives in `kca-yaml`:

   ```bash
   kubectl delete namespace kca-yaml
   ```

   Expected:

   ```
   namespace "kca-yaml" deleted
   ```

2. Restore your context's default namespace:

   ```bash
   kubectl config set-context --current --namespace=default
   ```

**Check your understanding**

- **Q9.1** Deleting the namespace removed the Deployments, ReplicaSets and Pods without you naming any of them. What Kubernetes mechanism guarantees the ReplicaSets and Pods are garbage-collected when their owning Deployment (and namespace) disappears?

---

## Answers

<details>
<summary>Click to reveal answers</summary>

**Q0.1** The server decides which API groups/versions exist and which are served, deprecated, or removed. A manifest's `apiVersion` must be a version the *server* still serves — writing `apps/v1beta1` against a v1.31 server fails regardless of client version. The client version only affects `kubectl`'s own behaviour and built-in schema; the authority on "does this `apiVersion` work" is the API server. Confirm with `kubectl api-resources` and `kubectl api-versions`.

**Q0.2**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kca-yaml
```
Generate it exactly with `kubectl create namespace kca-yaml --dry-run=client -o yaml`.

**Q1.1** Quote any scalar whose *intended type is string* but whose bare form YAML would read as a number, boolean, null, or timestamp — e.g. `"8080"`, `"true"`, `"no"`, `"1.10"`, `"2026-01-01"`. Fields like `ConfigMap.data.*`, container `env[].value`, and annotation values are typed as `string` in the schema; when the parser hands Kubernetes an `int`/`bool`, the strict JSON unmarshaller into a Go `string` field fails with `cannot unmarshal number/bool into Go struct field ... of type string`. The rule: **the schema field type, not the value's appearance, decides — quote to force string.**

**Q1.2** Most dangerously: version-like and identifier-like values that are string fields — container image tags/registries, `env` values, node/label values, and especially country codes / two-letter values (`no` = Norway → `false`). It also silently corrupts `data` in ConfigMaps. The habit: **quote every scalar that isn't self-evidently a number or a genuine boolean field**, and specifically always quote `no/yes/on/off/y/n/true/false` when you mean the literal text.

**Q1.3** The four block scalar styles differ on the *trailing* newline and internal folding:
- `|` (literal, clip): preserves internal newlines, keeps a single trailing `\n` → stores `line one\nline two\n`.
- `|-` (literal, strip): preserves internal newlines, removes the trailing newline → `line one\nline two`.
- `>` (folded, clip): folds single newlines into spaces, keeps one trailing `\n` → `line one line two\n`.
- `>-` (folded, strip): folds to spaces, no trailing newline → `line one line two`.
For `|` the stored value is `line one\nline two\n`.

**Q2.1** The apply is accepted but the bogus `uid` is *ignored/rejected silently* for immutable identity fields — the server owns `metadata.uid`, `metadata.creationTimestamp`, `resourceVersion`, `generation`, and all of `status`. This demonstrates the writable surface is essentially `metadata` (name, namespace, labels, annotations, finalizers, ownerReferences within rules) plus `spec`; the rest is control-plane-managed.

**Q2.2** The server defaults `protocol` to `TCP`. Confirm without docs by applying the pod without `protocol` and reading it back: `kubectl get pod web -o jsonpath='{.spec.containers[0].ports[0].protocol}'` → `TCP`. (Server dry-run + `-o yaml` shows all defaulted fields too.)

**Q2.3** `apiVersion` is `group/version`. The Pod's `v1` has an *empty* group — the **core** (legacy) group, whose objects (Pod, Service, ConfigMap, Namespace, Node) predate API grouping and live at `/api/v1`. `apps/v1` is the `apps` group at `/apis/apps/v1`, holding Deployment, ReplicaSet, StatefulSet, DaemonSet. The group name is defined by the API machinery / the resource's `GroupVersionKind`; discover it with `kubectl api-resources` (the `APIVERSION` column).

**Q3.1** The Deployment controller *requires* `spec.selector` to match `spec.template.metadata.labels`, because the ReplicaSet it creates must be able to adopt exactly the pods it templates — so the API server validates this structurally and rejects mismatches synchronously. A Service selector, by contrast, is a *runtime query* evaluated continuously by the endpoints controller; there is no object it must own, so any syntactically valid selector is accepted and simply matches zero pods if wrong. Lesson: Kubernetes structurally enforces *ownership* relationships, but treats *routing* selectors as best-effort queries.

**Q3.2** The **endpoints controller** (and the EndpointSlice controller) in kube-controller-manager watches Services and Pods and writes the matching pod IPs into the Endpoints / EndpointSlice object. `ENDPOINTS: <none>` means "the selector matched no ready pods," which instantly distinguishes a *routing/selector* problem from a *pod health* problem — before you ever look at the pods.

**Q3.3** Because `spec.selector` is immutable, you cannot edit it in place. The correct procedure is a **blue/green swap at the manifest level**: create a *new* Deployment (new name) with the new labels and selector, shift traffic (e.g. by re-pointing the Service selector or via a rollout), verify, then delete the old Deployment. Alternatively delete and recreate the Deployment, accepting downtime.

**Q4.1** Document order in the file does *not* strictly guarantee creation order for correctness — `kubectl apply` sends them in order, but even if the Pod were created first, it would not *fail permanently*: the kubelet retries. When a referenced ConfigMap is missing at start, the kubelet cannot construct the container's env/volume and reports `CreateContainerConfigError`, retrying until the ConfigMap appears. So ordering affects how quickly the pod becomes Ready, not final correctness — the pod self-heals once the dependency exists.

**Q4.2** 
- `ImagePullBackOff` — the **image pull** stage: registry unreachable, wrong tag, or missing pull secret.
- `CreateContainerConfigError` — the **container config assembly** stage (before the process starts): a referenced ConfigMap/Secret key is missing.
- `CrashLoopBackOff` — the **running** stage: the container process started and then exited non-zero repeatedly.

**Q4.3** `-f manifests/` applies every file in the *top level* of the directory; `--recursive` (`-R`) also descends into subdirectories. Within a run, apply sorts files alphabetically by filename and processes documents in order — so teams often prefix files with numbers (`01-namespace.yaml`, `02-configmap.yaml`) to control apply order for dependencies.

**Q5.1** Client dry-run never invokes the server's admission chain, so it cannot catch: **admission webhook rejections** (e.g. an OPA/Gatekeeper policy denying a container running as root), **ResourceQuota** violations (e.g. the namespace has no remaining CPU quota), **defaulting from mutating webhooks**, or **RBAC**. Example: a manifest that would be denied by a validating webhook requiring `runAsNonRoot: true` passes `--dry-run=client` and is rejected only by `--dry-run=server`.

**Q5.2** `--validate=strict` (default) rejects unknown/duplicate fields — the `portz` typo errors out. `--validate=warn` accepts the object but prints a warning about the unknown field. `--validate=ignore` disables field validation entirely and silently applies, dropping `portz`.

**Q5.3** In CI, run `kubectl diff -f manifests/ ; echo $?`. Treat exit code `1` (drift detected) as a build failure and `0` as pass — e.g. `kubectl diff -f manifests/ || exit 1`. (Note: `kubectl diff` uses exit `1` for "differences found" and `>1` for actual errors, so distinguish them if you need to fail only on genuine drift.)

**Q6.1** Three-way merge inputs are: **last-applied** (the annotation), **live** (current object), **new manifest**.
- Step 3: `replicas` is present in both last-applied (2) and new (2); live is 5. Because the field is *managed by apply* and unchanged between last-applied and new, apply sets it to the new value → **2**, overriding the out-of-band scale.
- Step 4: `replicas` was in last-applied but is *absent* from the new manifest. Apply interprets "present before, absent now" as **delete this field from my management**, so it is removed; the schema default (1) applies → **1**.

**Q6.2** Because apply only "owns" fields present in its last-applied annotation, mixing it with `edit`/`scale` on the same field creates a tug-of-war: apply will *revert* imperative changes to fields it manages (as in step 3), and imperative edits to fields apply *doesn't* manage won't be tracked, causing drift. The last-applied annotation is apply's only memory of "what I set," so out-of-band changes to those fields are invisible to it and get clobbered on the next apply.

**Q6.3** Client-side 3-way merge stores intent in a single opaque annotation, so multiple controllers/tools cannot cleanly co-own different fields of one object, and the annotation can grow large and go stale. **Server-Side Apply** records per-field ownership in `metadata.managedFields`, letting an HPA own `replicas` while your GitOps tool owns the pod template — the server tracks each manager. A conflict looks like:
```
error: Apply failed with 1 conflict: conflict with "kubectl-scale": .spec.replicas
```
resolved by either yielding the field or forcing ownership with `--force-conflicts`.

**Q7.1** The YAML parser expands `*alias` into a full literal copy *before* serialization to JSON, so Kubernetes stores two independent copies with no linkage. Anchors therefore reduce typing at author time but create no runtime coupling — if you later `kubectl edit` one container's limits, the other is unaffected, because on the server they were never related. Anchors are a *text* feature, not a Kubernetes one.

**Q7.2** Reach for **Kustomize** (overlays/patches, built into `kubectl -k`) or **Helm** (templating) for cross-file reuse. Teams prefer them because anchors are per-document, invisible after rendering, and unmaintainable across many files, whereas Kustomize/Helm operate over whole sets of manifests, support environment overlays, and produce reviewable rendered output.

**Q7.3** With the merge key `<<:`, keys defined *directly in the local map* take precedence over keys pulled in from the merged/anchored map. So the local `labels.team` wins over the anchored one; the merge only supplies keys the local map does not already define.

**Q8.1** A limit that is *too low but ≥ request* passes admission (the request≤limit invariant holds), so it is accepted at apply time. The failure surfaces at **runtime**: the container is OOM-killed by the kernel when it exceeds the memory limit, and the pod status becomes `CrashLoopBackOff` with the container's last state showing `Reason: OOMKilled` (`kubectl describe pod` → *Last State: Terminated, Reason: OOMKilled*). Admission-time errors are synchronous on `apply`; resource-exhaustion errors are asynchronous at run time.

**Q8.2** Top-down order:
1. `kubectl get deploy` — is the Deployment reporting desired vs. available replicas? Rules in/out whether it's a controller-level problem.
2. `kubectl get rs` — did a ReplicaSet get created and is it scaling? Rules out selector/immutability issues and reveals stuck rollouts.
3. `kubectl describe pod` — read the **Events**: scheduling, image pull, config errors. The richest single source.
4. `kubectl logs` (`--previous` if it restarted) — application-level errors once the container actually ran.
5. `kubectl get events --sort-by=.lastTimestamp` — namespace-wide timeline to correlate across objects when the above is inconclusive.

**Q8.3** `kubectl describe` aggregates the object's **Events** (scheduling, pull, probe failures, OOM) and human-readable conditions inline — the *causal narrative* — which raw `-o yaml` scatters or omits (events are separate objects). For triage you want "what happened and why," which describe assembles; `-o yaml` is better when you need exact field values or to diff spec.

**Q9.1** **Owner references and cascading garbage collection.** The Deployment owns its ReplicaSets and each ReplicaSet owns its Pods via `metadata.ownerReferences`. Deleting the namespace deletes the Deployment; the garbage collector then removes objects whose owners are gone (default *background* cascading deletion), cleaning up ReplicaSets and Pods without you naming them.

</details>

---

### Sources

- Kubernetes — *Objects In Kubernetes* (required fields, spec/status): https://kubernetes.io/docs/concepts/overview/working-with-objects/
- Kubernetes — *Managing Kubernetes Objects Using Declarative Config* (3-way merge, last-applied): https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — *Server-Side Apply* (managedFields, conflicts): https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — *Field Validation* (`--validate`, strict/warn/ignore): https://kubernetes.io/docs/reference/using-api/api-concepts/#field-validation
- Kubernetes — *kubectl* reference (`apply`, `diff`, `explain`, `--dry-run`): https://kubernetes.io/docs/reference/kubectl/
- Kubernetes — *Labels and Selectors*: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes — *Owners and Dependents* / *Garbage Collection*: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- YAML 1.2 Specification (block scalars, anchors, merge key): https://yaml.org/spec/1.2.2/
- CNCF Curriculum repository: https://github.com/cncf/curriculum