# 5.4 Mutation Rules — Guided Exercises

> **Domain 5 — Writing Policies · Topic 5.4 · Exam weight 2.91%**
> KCA curriculum: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>

These exercises are meant to be *executed*, not read. Every block ends with verification questions; all answers are collapsed at the bottom. Several steps deliberately produce a **wrong or surprising result** — that is the point. Mutation is the Kyverno rule type where the gap between "the YAML looks right" and "the cluster did what I meant" is widest, and the exam tests exactly that gap.

**Estimated time:** 90–120 minutes.

---

## Lab prerequisites

| Requirement | Verification |
|---|---|
| A cluster you can install cluster-scoped CRDs into (kind/k3d/minikube are fine) | `kubectl auth can-i create customresourcedefinitions` → `yes` |
| Kyverno 1.11 or newer, installed cluster-wide | `kubectl -n kyverno get deploy` |
| The Kyverno CLI (`kyverno`, also usable as `kubectl kyverno`) | `kyverno version` |
| `jq` for reading admission results | `jq --version` |

Install Kyverno if you do not have it:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace
```

> The exam is pinned to a specific Kyverno minor release, stated on the exam page. Field names such as `mutateExistingOnPolicyUpdate` and the CLI's test schema have moved between releases. Where behaviour is version-sensitive, the exercises say so — **verify against the version in front of you rather than trusting memory.**

---

## Exercise 0 — Map the mutation path before you write a policy

**Goal:** know which component performs a mutation, and where in the admission chain it happens, before you debug anything.

1. List the Kyverno control plane:

   ```bash
   kubectl -n kyverno get deploy
   ```

   ```
   NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller    1/1     1            1           3m
   kyverno-background-controller   1/1     1            1           3m
   kyverno-cleanup-controller      1/1     1            1           3m
   kyverno-reports-controller      1/1     1            1           3m
   ```

2. List the mutating webhook configurations Kyverno owns, and record the webhook count for each:

   ```bash
   kubectl get mutatingwebhookconfigurations \
     -o custom-columns='NAME:.metadata.name,WEBHOOKS:.webhooks[*].name'
   ```

   ```
   NAME                                    WEBHOOKS
   kyverno-policy-mutating-webhook-cfg     mutate-policy.kyverno.svc
   kyverno-resource-mutating-webhook-cfg   <none>
   kyverno-verify-mutating-webhook-cfg     monitor-webhooks.kyverno.svc
   ```

3. Look at the rules registered on the resource webhook — the one that will mutate *your* workloads:

   ```bash
   kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
     -o jsonpath='{.webhooks[*].rules}' | jq .
   ```

4. Create the lab namespace:

   ```bash
   kubectl create namespace mutation-lab
   ```

5. Read the exclusion list Kyverno ships with, and note which namespaces are filtered out:

   ```bash
   kubectl -n kyverno get configmap kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n'
   ```

**Check your understanding**

- **Q1.** In step 2, `kyverno-resource-mutating-webhook-cfg` exists but has no webhooks (or no rules). Why is it empty on a fresh install, and what will change it?
- **Q2.** Kubernetes runs mutating admission webhooks, then object schema validation, then validating admission webhooks. Which of Kyverno's four Deployments serves each of the two webhook phases, and which one is *not* in the admission path at all?
- **Q3.** A colleague reports "Kyverno ignores my policy for pods in `kube-system`." Which configuration key from step 5 explains this, and what is the format of each entry?
- **Q4.** If the `kyverno-admission-controller` Pods are all down, what happens to a `kubectl apply` of a Pod matched by a mutate policy? Which field on the policy decides?

---

## Exercise 1 — `patchStrategicMerge`, variables, and the background-mode trap

**Goal:** write the simplest possible mutation, and hit the first validation wall Kyverno puts in front of you.

1. Write `01-owner.yaml`. Note that `background` is left at its default:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-owner-metadata
     annotations:
       policies.kyverno.io/title: Add owner metadata
       policies.kyverno.io/category: Governance
       policies.kyverno.io/subject: Pod
   spec:
     rules:
       - name: add-team-and-creator
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - mutation-lab
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 team: platform
               annotations:
                 owner.example.com/created-by: "{{ request.userInfo.username }}"
   ```

2. Apply it and read the rejection carefully:

   ```bash
   kubectl apply -f 01-owner.yaml
   ```

   ```
   Error from server: error when creating "01-owner.yaml": admission webhook
   "validate-policy.kyverno.svc" denied the request: spec.rules[0].mutate.patchStrategicMerge:
   rule "add-team-and-creator" should not have variables that are not allowed in background mode:
   variable {{request.userInfo.username}} is not allowed in background mode
   ```

   *(Wording varies by release; the substance does not.)*

3. Add `background: false` immediately under `spec:`, above `rules:`, and re-apply:

   ```yaml
   spec:
     background: false
     rules:
   ```

   ```bash
   kubectl apply -f 01-owner.yaml
   ```

   ```
   clusterpolicy.kyverno.io/add-owner-metadata created
   ```

4. Confirm the policy is admitted and ready:

   ```bash
   kubectl get clusterpolicy add-owner-metadata
   ```

   ```
   NAME                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
   add-owner-metadata   true        false        Audit             True    5s
   ```

5. Re-run step 3 of Exercise 0 and compare the webhook rules to what you recorded then.

6. Create a Pod that sets neither label nor annotation:

   ```bash
   kubectl -n mutation-lab run web --image=nginx:1.27 --restart=Never
   ```

7. Inspect what actually landed in etcd:

   ```bash
   kubectl -n mutation-lab get pod web \
     -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}' | jq -s .
   ```

   ```json
   [
     { "run": "web", "team": "platform" },
     { "owner.example.com/created-by": "kubernetes-admin" }
   ]
   ```

8. Confirm your local manifest was never touched, and that the mutation is recorded as an event:

   ```bash
   kubectl -n mutation-lab get events --field-selector reason=PolicyApplied
   ```

**Check your understanding**

- **Q5.** Why does Kyverno refuse a policy that uses `{{ request.userInfo.username }}` unless `background: false`? What does `background: true` actually enable?
- **Q6.** The username was written to an **annotation**, not a label. Give the concrete failure that occurs if you move it to `metadata.labels` and a Deployment controller creates the Pod.
- **Q7.** Step 5 shows the webhook rules changed. What is Kyverno doing, and what is the operational consequence of applying the very first mutate policy for a new resource kind?
- **Q8.** The Pod in the cluster has a label your `kubectl run` never asked for. Name two ways this surfaces as a problem in a GitOps pipeline, and one way to avoid it.
- **Q9.** `patchStrategicMerge` created `metadata.annotations`, which did not exist on the incoming Pod. Is that guaranteed behaviour for all patch types Kyverno supports? (You will prove the answer in Exercise 3.)

---

## Exercise 2 — Anchors: `+()`, `()`, and why "add if not present" sometimes never fires

**Goal:** distinguish the *conditional* anchor from the *add-if-not-present* anchor empirically, and discover that API-server defaulting runs **before** your webhook.

1. Write `02-anchors.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: anchor-semantics
   spec:
     rules:
       - name: default-tier-label-if-absent
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 +(tier): backend

       - name: default-pull-policy-if-absent
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             spec:
               containers:
                 - (name): "*"
                   +(imagePullPolicy): Never

       - name: force-always-for-latest
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             spec:
               containers:
                 - (image): "*:latest"
                   imagePullPolicy: Always
   ```

   `Never` is chosen deliberately: it is a value the Kubernetes API server would never pick on its own, so its presence or absence is a clean signal.

2. Apply it:

   ```bash
   kubectl apply -f 02-anchors.yaml
   ```

3. Create three Pods with different starting states:

   ```bash
   kubectl -n mutation-lab run a-plain    --image=nginx:1.27 --restart=Never
   kubectl -n mutation-lab run b-labelled --image=nginx:1.27 --restart=Never --labels=tier=frontend
   kubectl -n mutation-lab run c-latest   --image=nginx:latest --restart=Never
   ```

4. Compare all three in one shot:

   ```bash
   kubectl -n mutation-lab get pod a-plain b-labelled c-latest \
     -o custom-columns='POD:.metadata.name,TIER:.metadata.labels.tier,IMAGE:.spec.containers[0].image,PULL:.spec.containers[0].imagePullPolicy'
   ```

   ```
   POD          TIER       IMAGE          PULL
   a-plain      backend    nginx:1.27     IfNotPresent
   b-labelled   frontend   nginx:1.27     IfNotPresent
   c-latest     backend    nginx:latest   Always
   ```

5. Prove the third rule did more than agree with the default. Temporarily set an explicit non-default policy on an untagged image:

   ```bash
   kubectl -n mutation-lab run d-untagged --image=nginx --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"d-untagged","image":"nginx","imagePullPolicy":"IfNotPresent"}]}}'
   kubectl -n mutation-lab get pod d-untagged -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
   ```

   ```
   IfNotPresent
   ```

6. Check the policy report to see which rules Kyverno believes it applied:

   ```bash
   kubectl -n mutation-lab get policyreport -o wide 2>/dev/null | head
   kubectl -n mutation-lab get events --field-selector reason=PolicyApplied \
     -o custom-columns='OBJ:.involvedObject.name,MSG:.message' | head
   ```

**Check your understanding**

- **Q10.** Rule `default-tier-label-if-absent` worked: `a-plain` got `tier=backend`, `b-labelled` kept `frontend`. State the rule for `+()` in one sentence.
- **Q11.** Rule `default-pull-policy-if-absent` set `Never` on **nothing**, yet Kyverno reports no error. Why did `+(imagePullPolicy)` never fire? (This is the most important answer in this exercise.)
- **Q12.** In `(name): "*"`, what is the anchor doing, and what would the patch mean if you wrote `name: "*"` without parentheses?
- **Q13.** `d-untagged` uses image `nginx` with no tag. Kubernetes treats an untagged image as `:latest`, yet rule `force-always-for-latest` did not match it. Why, and how would you write the match so it covers both forms?
- **Q14.** Rule 2 sets `imagePullPolicy` and rule 3 overwrites it for `:latest`. Is the ordering between those two rules guaranteed? What about ordering between two *separate* ClusterPolicies that touch the same field?
- **Q15.** Name the anchors that are valid **only** in `validate` rules, and the one that is evaluated against the entire resource rather than the node it sits on.

---

## Exercise 3 — `patchesJson6902`: precision, and the parent-must-exist rule

**Goal:** learn when RFC 6902 is the only correct tool, and why it fails where strategic merge silently succeeds.

1. First, prove why strategic merge is the wrong tool here. Write `03-toleration-smp.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: batch-toleration-smp
   spec:
     rules:
       - name: add-batch-toleration
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
                 selector:
                   matchLabels:
                     workload-type: batch
         mutate:
           patchStrategicMerge:
             spec:
               tolerations:
                 - key: workload
                   operator: Equal
                   value: batch
                   effect: NoSchedule
   ```

2. Apply it and create a Pod that **already** carries an unrelated toleration:

   ```bash
   kubectl apply -f 03-toleration-smp.yaml
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: batch-one
     namespace: mutation-lab
     labels:
       workload-type: batch
   spec:
     tolerations:
       - key: node.example.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: worker
         image: busybox:1.36
         command: ["sleep", "3600"]
   EOF
   ```

3. Count the tolerations that survived:

   ```bash
   kubectl -n mutation-lab get pod batch-one -o jsonpath='{.spec.tolerations}' | jq 'length, .[].key'
   ```

   ```
   1
   "workload"
   ```

   The GPU toleration is gone.

4. Delete that policy and the Pod, and rebuild the rule with JSON Patch. Write `03-toleration-6902.yaml` — note that it takes **two rules**:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: batch-toleration
   spec:
     rules:
       - name: create-toleration-list
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
                 selector:
                   matchLabels:
                     workload-type: batch
         preconditions:
           all:
             - key: "{{ request.object.spec | keys(@) | contains(@, 'tolerations') }}"
               operator: Equals
               value: false
         mutate:
           patchesJson6902: |-
             - op: add
               path: "/spec/tolerations"
               value:
                 - key: workload
                   operator: Equal
                   value: batch
                   effect: NoSchedule

       - name: append-to-existing-list
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
                 selector:
                   matchLabels:
                     workload-type: batch
         preconditions:
           all:
             - key: "{{ request.object.spec | keys(@) | contains(@, 'tolerations') }}"
               operator: Equals
               value: true
         mutate:
           patchesJson6902: |-
             - op: add
               path: "/spec/tolerations/-"
               value:
                 key: workload
                 operator: Equal
                 value: batch
                 effect: NoSchedule
   ```

5. Apply and re-test both starting states:

   ```bash
   kubectl delete clusterpolicy batch-toleration-smp --ignore-not-found
   kubectl -n mutation-lab delete pod batch-one --ignore-not-found
   kubectl apply -f 03-toleration-6902.yaml

   kubectl -n mutation-lab run batch-plain --image=busybox:1.36 --restart=Never \
     --labels=workload-type=batch -- sleep 3600

   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: batch-gpu
     namespace: mutation-lab
     labels:
       workload-type: batch
   spec:
     tolerations:
       - key: node.example.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: worker
         image: busybox:1.36
         command: ["sleep", "3600"]
   EOF
   ```

6. Verify:

   ```bash
   for p in batch-plain batch-gpu; do
     echo "== $p"
     kubectl -n mutation-lab get pod $p -o jsonpath='{.spec.tolerations[*].key}{"\n"}'
   done
   ```

   ```
   == batch-plain
   workload
   == batch-gpu
   node.example.com/gpu workload
   ```

7. Now break it on purpose. Add a third rule to the same policy that removes a path which may not exist:

   ```yaml
       - name: strip-debug-annotation
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchesJson6902: |-
             - op: remove
               path: "/metadata/annotations/debug.example.com~1enabled"
   ```

   Apply it, create a Pod **without** that annotation, and read the events and controller log:

   ```bash
   kubectl -n mutation-lab run no-anno --image=busybox:1.36 --restart=Never -- sleep 3600
   kubectl -n mutation-lab get events --field-selector reason=PolicyError -o wide | tail -5
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=40 | grep -i -E 'remove|patch'
   ```

**Check your understanding**

- **Q16.** In step 3, strategic merge **replaced** the toleration list instead of merging into it. What property of the `tolerations` field in the Kubernetes PodSpec causes that, and how would you have predicted it from `kubectl explain`?
- **Q17.** Why does step 4 need two rules with mirrored preconditions instead of a single `op: add` to `/spec/tolerations/-`?
- **Q18.** What does `~1` mean in `/metadata/annotations/debug.example.com~1enabled`, and what does `~0` mean? What breaks if you omit the escape?
- **Q19.** In step 7, what happened to the Pod — was it created, rejected, or created unmutated? Explain the interaction with the rule's `failurePolicy`, and write the precondition that makes the `remove` safe.
- **Q20.** RFC 6902 `add` on an object key that already exists behaves like `replace`. Describe the production incident this causes if the value is a **list** rather than a scalar.
- **Q21.** A JSON Patch appends a toleration with `/-`. The policy matches on `CREATE` **and** `UPDATE`. What does the Deployment's pod template look like after ten `kubectl edit` cycles, and what is the general principle being violated?

---

## Exercise 4 — `foreach`: per-element mutation with `element` and `elementIndex`

**Goal:** rewrite every container image in a Pod, skipping ones already rewritten, and build annotation keys per container.

1. Write `04-mirror.yaml`. Rule order matters — rule 1 guarantees the parent object that rule 2's JSON Pointer needs:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: mirror-registry
   spec:
     rules:
       - name: ensure-annotations-exist
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             metadata:
               annotations:
                 +(mirror.example.com/policy): mirror-registry

       - name: rewrite-container-images
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           foreach:
             - list: "request.object.spec.containers"
               preconditions:
                 all:
                   - key: "{{ starts_with(element.image, 'mirror.example.com/') }}"
                     operator: Equals
                     value: false
               patchStrategicMerge:
                 spec:
                   containers:
                     - name: "{{ element.name }}"
                       image: "mirror.example.com/{{ element.image }}"

       - name: record-rewritten-containers
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           foreach:
             - list: "request.object.spec.containers"
               patchesJson6902: |-
                 - op: add
                   path: "/metadata/annotations/mirror.example.com~1{{ element.name }}"
                   value: "index-{{ elementIndex }}"
   ```

2. Apply it and create a multi-container Pod where one image is already mirrored:

   ```bash
   kubectl apply -f 04-mirror.yaml
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: multi
     namespace: mutation-lab
   spec:
     containers:
       - name: app
         image: nginx:1.27
       - name: sidecar
         image: mirror.example.com/fluent/fluent-bit:3.0
       - name: helper
         image: busybox:1.36
         command: ["sleep", "3600"]
   EOF
   ```

3. Read the result:

   ```bash
   kubectl -n mutation-lab get pod multi \
     -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
   echo '---'
   kubectl -n mutation-lab get pod multi -o jsonpath='{.metadata.annotations}' | jq .
   ```

   ```
   app	mirror.example.com/nginx:1.27
   sidecar	mirror.example.com/fluent/fluent-bit:3.0
   helper	mirror.example.com/busybox:1.36
   ---
   {
     "mirror.example.com/app": "index-0",
     "mirror.example.com/helper": "index-2",
     "mirror.example.com/policy": "mirror-registry",
     "mirror.example.com/sidecar": "index-1"
   }
   ```

4. Check the Pod's runtime state:

   ```bash
   kubectl -n mutation-lab get pod multi
   ```

   ```
   NAME    READY   STATUS             RESTARTS   AGE
   multi   0/3     ErrImagePull       0          15s
   ```

5. Now test the list that is usually absent. Create a Pod **with** an initContainer and one **without**, after adding a fourth rule:

   ```yaml
       - name: rewrite-init-images
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           foreach:
             - list: "request.object.spec.initContainers"
               patchStrategicMerge:
                 spec:
                   initContainers:
                     - name: "{{ element.name }}"
                       image: "mirror.example.com/{{ element.image }}"
   ```

   ```bash
   kubectl apply -f 04-mirror.yaml
   kubectl -n mutation-lab run plain-again --image=nginx:1.27 --restart=Never
   kubectl -n mutation-lab get events --field-selector reason=PolicyError -o wide | tail -3
   ```

**Check your understanding**

- **Q22.** The `sidecar` container was left alone. Which construct did that, and why is it *not* achievable with a `patchStrategicMerge` conditional anchor on `image` in this case?
- **Q23.** Rule 3 uses `/metadata/annotations/...` as a JSON Pointer. What would happen to a Pod with **no** annotations if rule 1 were deleted? Name the two ways to fix it.
- **Q24.** The Pod is in `ErrImagePull`. Did the mutation fail? What does this tell you about the scope of what a mutate rule can and cannot verify?
- **Q25.** In step 5, `request.object.spec.initContainers` is absent on `plain-again`. What did Kyverno do, and how do you make the behaviour explicit rather than incidental?
- **Q26.** `foreach` supports an `order` field (`Ascending` / `Descending`). Give a concrete mutation where `Descending` is mandatory for correctness.
- **Q27.** Rewrite rule 2 so it strips any existing registry prefix instead of prepending to it (for example `quay.io/jetstack/cert-manager-controller:v1.14` → `mirror.example.com/jetstack/cert-manager-controller:v1.14`). Which Kyverno JMESPath function do you need?

---

## Exercise 5 — Mutating **existing** resources: `targets`, the background controller, and RBAC

**Goal:** mutate objects that already exist, discover that it silently does nothing until you grant RBAC, and fix it.

1. Create the trigger and the target:

   ```bash
   kubectl -n mutation-lab create configmap app-config --from-literal=level=info
   kubectl -n mutation-lab create deployment web --image=nginx:1.27
   kubectl -n mutation-lab rollout status deploy/web
   ```

2. Write `05-mutate-existing.yaml`. The `match` block selects the **trigger**; `targets` selects what is actually modified:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: roll-deployment-on-config-change
   spec:
     mutateExistingOnPolicyUpdate: false
     rules:
       - name: stamp-config-revision
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
                 namespaces:
                   - mutation-lab
                 names:
                   - app-config
         mutate:
           targets:
             - apiVersion: apps/v1
               kind: Deployment
               name: web
               namespace: "{{ request.object.metadata.namespace }}"
           patchStrategicMerge:
             spec:
               template:
                 metadata:
                   annotations:
                     config.example.com/revision: "{{ request.object.metadata.resourceVersion }}"
   ```

3. Apply it, then trigger it by updating the ConfigMap:

   ```bash
   kubectl apply -f 05-mutate-existing.yaml
   kubectl -n mutation-lab create configmap app-config --from-literal=level=debug \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. Wait a few seconds and check the target. **It has not changed:**

   ```bash
   kubectl -n mutation-lab get deploy web \
     -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
   ```

   ```
   
   ```

5. Find out why. Three places to look, in this order:

   ```bash
   kubectl get updaterequests -A
   kubectl -n kyverno logs deploy/kyverno-background-controller --tail=50 | grep -i -E 'forbidden|denied|mutate'
   kubectl auth can-i update deployments \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n mutation-lab
   ```

   ```
   no
   ```

6. Grant the permission the way Kyverno expects — an **aggregated** ClusterRole, not an edit of Kyverno's own roles:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:mutate-deployments
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
     - apiGroups: ["apps"]
       resources: ["deployments"]
       verbs: ["get", "list", "watch", "update", "patch"]
   ```

   ```bash
   kubectl apply -f 05-rbac.yaml
   kubectl auth can-i update deployments \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n mutation-lab
   ```

   ```
   yes
   ```

7. Trigger again and verify the rollout:

   ```bash
   kubectl -n mutation-lab create configmap app-config --from-literal=level=warn \
     --dry-run=client -o yaml | kubectl apply -f -
   sleep 5
   kubectl -n mutation-lab get deploy web \
     -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
   kubectl -n mutation-lab rollout history deploy/web
   ```

   ```
   {"config.example.com/revision":"41283"}
   REVISION  CHANGE-CAUSE
   1         <none>
   2         <none>
   ```

8. Trigger a *no-op* update and confirm nothing rolls:

   ```bash
   kubectl -n mutation-lab annotate configmap app-config touched=1 --overwrite
   sleep 5
   kubectl -n mutation-lab rollout history deploy/web | tail -3
   ```

**Check your understanding**

- **Q28.** Which Kyverno component executed this mutation, and why is it *not* the admission controller? What does that imply for `failurePolicy` and for the latency between trigger and effect?
- **Q29.** Step 5 showed `can-i update deployments` → `no`, yet the ConfigMap update itself succeeded with no warning. Explain the failure mode and why it is dangerous in production.
- **Q30.** Why is the ClusterRole labelled `rbac.kyverno.io/aggregate-to-background-controller` instead of being added to Kyverno's shipped ClusterRole directly?
- **Q31.** `spec.mutateExistingOnPolicyUpdate` is `false` here. What changes if you set it to `true`, and what is the blast radius the first time the policy is applied to a cluster with 4 000 Deployments?
- **Q32.** In step 8 the annotation was touched but no new rollout appeared — or did it? Predict the result and explain it in terms of `resourceVersion`, then reconcile your prediction with what you actually observed.
- **Q33.** Inside a mutate-existing rule, `{{ request.object.* }}` and `{{ target.* }}` refer to different objects. Which is which, and write the patch that copies the trigger ConfigMap's `metadata.labels.env` onto the target Deployment only when the target does not already have that label.
- **Q34.** Can a mutate-existing rule use `{{ request.userInfo.username }}`? Justify your answer using Exercise 1.

---

## Exercise 6 — Auto-gen: what happens to Pod-matching mutate rules on controllers

**Goal:** see the rules Kyverno writes for you, and understand where the mutation lands.

1. Inspect the generated rules for the policy from Exercise 1:

   ```bash
   kubectl get clusterpolicy add-owner-metadata -o jsonpath='{.status.autogen.rules[*].name}{"\n"}'
   ```

   ```
   autogen-add-team-and-creator autogen-cronjob-add-team-and-creator
   ```

2. Look at how the patch path was rewritten:

   ```bash
   kubectl get clusterpolicy add-owner-metadata -o yaml \
     | sed -n '/autogen/,$p' | head -40
   ```

3. Create a Deployment and inspect **both** levels:

   ```bash
   kubectl -n mutation-lab create deployment auto --image=nginx:1.27
   sleep 3
   echo "== Deployment pod template labels"
   kubectl -n mutation-lab get deploy auto -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
   echo "== Pod labels"
   kubectl -n mutation-lab get pods -l app=auto -o jsonpath='{.items[0].metadata.labels}{"\n"}'
   ```

4. Disable autogen and repeat:

   ```bash
   kubectl annotate clusterpolicy add-owner-metadata \
     pod-policies.kyverno.io/autogen-controllers=none --overwrite
   kubectl -n mutation-lab create deployment auto2 --image=nginx:1.27
   sleep 3
   kubectl -n mutation-lab get deploy auto2 -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
   kubectl -n mutation-lab get pods -l app=auto2 -o jsonpath='{.items[0].metadata.labels}{"\n"}'
   ```

5. Restore autogen:

   ```bash
   kubectl annotate clusterpolicy add-owner-metadata \
     pod-policies.kyverno.io/autogen-controllers- 
   ```

**Check your understanding**

- **Q35.** With autogen **off**, the Pod still received `team=platform` but the Deployment's pod template did not. Explain why, and describe the Argo CD / Flux symptom this creates.
- **Q36.** What path does autogen wrap a Pod-level `patchStrategicMerge` into for a `Deployment`? And for a `CronJob`?
- **Q37.** Give a mutation that is **wrong** to autogen — one where applying it at the controller level changes the meaning — and how you would restrict it.
- **Q38.** Exercise 1's policy has `background: false`. Does autogen still apply to it? Which Kyverno behaviours does `background: false` actually switch off?

---

## Exercise 7 — Verify mutations without a cluster: `kyverno apply` and `kyverno test`

**Goal:** put mutations under CI, which is how they are maintained in real platforms.

1. Create a resource fixture `resources/pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
     namespace: mutation-lab
   spec:
     containers:
       - name: app
         image: nginx:1.27
   ```

2. Run the policy from Exercise 2 against it, offline:

   ```bash
   kyverno apply 02-anchors.yaml --resource resources/pod.yaml
   ```

   ```
   Applying 3 policy rule(s) to 1 resource(s)...

   mutate policy anchor-semantics applied to mutation-lab/Pod/web:
   apiVersion: v1
   kind: Pod
   metadata:
     labels:
       tier: backend
     name: web
     namespace: mutation-lab
   spec:
     containers:
     - image: nginx:1.27
       imagePullPolicy: Never
       name: app
   ---

   pass: 1, fail: 0, warn: 0, error: 0, skip: 2
   ```

3. Compare that output with what the cluster produced in Exercise 2, step 4, and account for the difference.

4. Write the expected artefact `resources/pod-patched.yaml` from the CLI output, then a test manifest `kyverno-test.yaml`:

   ```yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: anchor-semantics-test
   policies:
     - 02-anchors.yaml
   resources:
     - resources/pod.yaml
   results:
     - policy: anchor-semantics
       rule: default-tier-label-if-absent
       resources:
         - mutation-lab/web
       kind: Pod
       result: pass
       patchedResources: resources/pod-patched.yaml
   ```

5. Run it:

   ```bash
   kyverno test .
   ```

   ```
   Loading test  ( ./kyverno-test.yaml ) ...
     Loading values/variables ...
     Loading policies ...
     Loading resources ...
     Applying 3 policy rule(s) to 1 resource(s) ...
     Checking results ...

   │ ID │ POLICY            │ RULE                          │ RESOURCE             │ RESULT │
   │ 1  │ anchor-semantics  │ default-tier-label-if-absent  │ Pod/mutation-lab/web │ Pass   │

   Test Summary: 1 tests passed and 0 tests failed
   ```

6. Break the fixture — change `tier: backend` to `tier: frontend` in `pod-patched.yaml` — and re-run to see the diff the CLI prints.

**Check your understanding**

- **Q39.** The CLI produced `imagePullPolicy: Never`; the live cluster produced `IfNotPresent`. Which one is "right", and what does the discrepancy teach you about what `kyverno apply` does *not* simulate?
- **Q40.** Why is `patchedResources` the single most valuable field in a mutation test, compared with just asserting `result: pass`?
- **Q41.** Your policy uses `{{ request.userInfo.username }}`. How do you make `kyverno test` deterministic for it?
- **Q42.** Which exit code does `kyverno test` return on failure, and what is the minimal CI gate you would build from Exercises 2–4?

---

## Exercise 8 — Diagnose a mutation that never fires

**Goal:** a repeatable triage order. Work top to bottom; each step eliminates a class of cause.

1. Reproduce a failure. Create a Pod in an excluded namespace:

   ```bash
   kubectl -n kube-system run probe --image=nginx:1.27 --restart=Never
   kubectl -n kube-system get pod probe -o jsonpath='{.metadata.labels}{"\n"}'
   kubectl -n kube-system delete pod probe
   ```

2. **Is the policy admitted and ready?**

   ```bash
   kubectl get cpol -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MSG:.status.conditions[?(@.type=="Ready")].message'
   ```

3. **Is the webhook registered for that kind?**

   ```bash
   kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
     -o jsonpath='{.webhooks[*].rules}' | jq '.[].resources'
   ```

4. **Is the resource filtered out?**

   ```bash
   kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | grep -i -E 'kube-system|kyverno'
   ```

5. **Did the rule match but skip?** Preconditions and anchors produce `skip`, not `fail`:

   ```bash
   kubectl -n mutation-lab get events \
     --field-selector 'reason=PolicySkipped' -o custom-columns='OBJ:.involvedObject.name,MSG:.message'
   ```

6. **Did the rule error?**

   ```bash
   kubectl -n mutation-lab get events --field-selector 'reason=PolicyError' -o wide
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 | grep -i -E 'error|failed'
   ```

7. **Replay it offline** with the exact object from the cluster:

   ```bash
   kubectl -n mutation-lab get pod multi -o yaml > /tmp/live.yaml
   kyverno apply 04-mirror.yaml --resource /tmp/live.yaml
   ```

**Check your understanding**

- **Q43.** Order these four causes from cheapest to most expensive to rule out: `resourceFilters` exclusion; `failurePolicy: Ignore` swallowing a webhook error; a JMESPath precondition evaluating false; a webhook not registered for the kind.
- **Q44.** In step 7, feeding a **live** object back into `kyverno apply` can produce a different result than admission did. Give two reasons.
- **Q45.** A mutate rule works for `kubectl apply` but not for objects created by a controller. List three distinct explanations and the command that distinguishes each.
- **Q46.** `failurePolicy: Fail` on a mutate rule makes errors loud. Why is that dangerous for a rule matching `Pod` cluster-wide, and what is the standard mitigation?

---

## Exercise 9 — Ordering: mutate feeds validate

**Goal:** confirm the phase boundary that makes "mutate to fix, validate to enforce" a viable platform pattern.

1. Add a validating policy that requires the label Exercise 1 injects:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
       - name: check-team
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         validate:
           message: "Pods must carry a 'team' label."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   *(On Kyverno 1.10 and earlier the field is `spec.validationFailureAction`; newer releases place it under `spec.rules[].validate.failureAction` — check `kubectl explain clusterpolicy.spec`.)*

2. Apply it and create a Pod with **no** `team` label:

   ```bash
   kubectl apply -f 09-validate.yaml
   kubectl -n mutation-lab run ordering-a --image=nginx:1.27 --restart=Never
   ```

   ```
   pod/ordering-a created
   ```

3. Now narrow the *mutate* policy so it no longer matches this Pod, and retry:

   ```bash
   kubectl patch clusterpolicy add-owner-metadata --type=json \
     -p='[{"op":"add","path":"/spec/rules/0/match/any/0/resources/selector","value":{"matchLabels":{"mutate":"yes"}}}]'
   kubectl -n mutation-lab run ordering-b --image=nginx:1.27 --restart=Never
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/mutation-lab/ordering-b was blocked due to the following policies

   require-team-label:
     check-team: 'validation error: Pods must carry a ''team'' label. rule check-team
       failed at path /metadata/labels/team/'
   ```

4. Revert:

   ```bash
   kubectl patch clusterpolicy add-owner-metadata --type=json \
     -p='[{"op":"remove","path":"/spec/rules/0/match/any/0/resources/selector"}]'
   ```

**Check your understanding**

- **Q47.** `ordering-a` was created even though the user never supplied a `team` label. Which two webhook configurations were involved, and in what order did the API server call them?
- **Q48.** Would the result change if the mutate rule and the validate rule lived in the **same** ClusterPolicy? What if they lived in two policies whose names sort in the opposite order?
- **Q49.** A platform team wants "default it if missing, reject it if wrong." Sketch the two-rule design and state which rule must **not** use `+()`.
- **Q50.** Kyverno mutations are invisible to whoever wrote the original manifest. Name the two mechanisms that make an applied mutation auditable after the fact.

---

## Cleanup

```bash
kubectl delete clusterpolicy add-owner-metadata anchor-semantics batch-toleration \
  mirror-registry roll-deployment-on-config-change require-team-label --ignore-not-found
kubectl delete clusterrole kyverno:mutate-deployments --ignore-not-found
kubectl delete namespace mutation-lab
kubectl get updaterequests -A
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A1.** Kyverno configures its resource webhooks **dynamically** from the set of installed policies (`autoUpdateWebhooks`, on by default). With no mutate policy present, there is nothing to intercept, so the resource mutating webhook carries no rules — Kyverno deliberately avoids sitting in the admission path for traffic it has no work for. Applying the first mutate policy for a kind causes Kyverno to add a rule for that kind, typically within a few seconds. The static `kyverno-policy-mutating-webhook-cfg` is different: it always intercepts `ClusterPolicy`/`Policy` objects themselves (that is what defaults and validates your policies, and what rejected the policy in Exercise 1).

**A2.** The **admission controller** serves both the mutating and the validating resource webhooks. The **background controller** performs mutate-existing and generate work asynchronously and is not in the admission path. The **reports controller** builds `PolicyReport`/`ClusterPolicyReport` objects; the **cleanup controller** serves `CleanupPolicy`. Only the admission controller can block or alter a request in-flight.

**A3.** `resourceFilters` in the `kyverno` ConfigMap in the `kyverno` namespace. Each entry is `[kind,namespace,name]`, wildcards allowed, entries concatenated: `[Event,*,*][*,kube-system,*][*,kyverno,*]…`. Anything matching is excluded from **all** processing before any policy is evaluated — so no event, no report, no log line. The default set excludes `kube-system`, `kube-public`, `kube-node-lease`, Kyverno's own namespace and high-churn kinds such as `Event`, `Node`, `Lease`, `TokenReview`. This is the single most common "my policy is ignored" cause and it is invisible from the policy side.

**A4.** It depends on `spec.rules[].failurePolicy` (default `Fail`). With `Fail`, the API server cannot reach the webhook and **rejects the request** — a Kyverno outage becomes a cluster-wide workload-creation outage. With `Ignore`, the request proceeds unmutated, which is available but silently unenforced. This is why production installs run the admission controller with ≥3 replicas, a PodDisruptionBudget, and `kube-system` excluded.

### Exercise 1

**A5.** `background: true` (the default) lets Kyverno evaluate the policy during periodic **background scans** of existing resources, where there is no AdmissionRequest. `request.userInfo`, `request.operation`, `request.roles` and friends exist only in an admission context, so a policy that references them cannot be evaluated in background mode. Kyverno's own policy-validating webhook rejects that combination at apply time rather than letting it fail silently at scan time. Setting `background: false` disables background scans and policy reports for the policy — it then applies only at admission.

**A6.** Kubernetes label **values** are restricted to alphanumerics, `-`, `_`, `.`, max 63 characters. A ServiceAccount username is `system:serviceaccount:<ns>:<name>` — the colons are illegal. A Pod created by a ReplicaSet controller would be mutated into an invalid object and rejected by API validation *after* the mutating phase, so the Deployment stops producing Pods with a message that points at the label, not at Kyverno. **Annotation** values have no such character restriction, which is why identity/provenance data belongs there.

**A7.** Kyverno rewrote `kyverno-resource-mutating-webhook-cfg` to intercept Pods. Operationally: the first mutate policy for a kind puts Kyverno into the critical path for **every** create/update of that kind cluster-wide, subject to `failurePolicy` and the namespace exclusions. Adding a narrowly scoped policy is therefore not a narrowly scoped change — scope it further with `namespaceSelector`/`objectSelector` on the policy so Kyverno also narrows the webhook.

**A8.** (1) A GitOps controller diffs the desired manifest against the live object and reports permanent drift / `OutOfSync`; (2) an aggressive self-heal loop can fight the webhook, re-applying and being re-mutated in a hot loop. Avoidance: mutate the **controller** object too (autogen, Exercise 6) so the stored spec matches, or configure the GitOps tool to ignore the mutated fields (Argo CD `ignoreDifferences`, Flux `spec.patches`/drift-detection exclusions). The general principle: mutate as high in the ownership chain as you can.

**A9.** No. `patchStrategicMerge` creates missing parent maps as it merges. `patchesJson6902` follows RFC 6902 strictly: `add` requires the parent container to exist, and `remove`/`replace` require the target itself to exist. That asymmetry is Exercise 3.

### Exercise 2

**A10.** `+(key): value` sets `key` to `value` **only if `key` is absent**; if present, the existing value is left untouched and the rest of the patch continues. It is "default it," not "enforce it."

**A11.** Because the Kubernetes API server applies **defaulting during decoding, before admission webhooks run**. `SetDefaults_Container` fills `imagePullPolicy` with `Always` for `:latest`/untagged images and `IfNotPresent` otherwise. By the time Kyverno's webhook sees the object, the field is already populated, so `+()` correctly finds it present and does nothing. The general lesson: a mutating webhook can never distinguish "the user omitted this" from "the API server defaulted it," so `+()` is only meaningful on fields the API has **no default for** — labels, annotations, custom-resource fields, `nodeSelector`, `tolerations`, `securityContext` sub-fields that are genuinely nil-able. Always confirm anchors empirically with a sentinel value the API server would never choose, exactly as this exercise did with `Never`.

**A12.** `(name): "*"` is a **conditional anchor**: "for each list element, if `name` matches the pattern `*`, apply the sibling keys of this map to that element; otherwise skip the element." It is a selector, not data — it is never written to the object. Without parentheses, `name: "*"` is data: strategic merge would try to match/create a container literally named `*`, producing a bogus extra container.

**A13.** The conditional anchor matches the **literal string** of `spec.containers[].image`, and `nginx` does not end in `:latest`. Kubernetes' *semantic* equivalence of `nginx` and `nginx:latest` is applied by the kubelet/defaulting logic, not by string matching. To cover both, either use two rules (`"*:latest"` and a `foreach` with a precondition `contains(element.image, ':') == false`), or move to `foreach` + JMESPath so you can express "no tag OR tag == latest" in one precondition. Note that `*:latest` also matches `myrepo/latest-thing:latest` correctly but would *not* match a digest-pinned reference — which is the desired behaviour, since digests are immutable.

**A14.** Within one policy, rules execute **in declaration order**, and a later rule sees the object as mutated by earlier rules — that ordering is guaranteed and is exactly what rules 2 and 3 rely on. Across **separate policies**, do not rely on ordering: multiple policies are applied in one webhook invocation, but the sequence is an implementation detail and can change between releases. Design cross-policy mutations to be commutative and idempotent, or consolidate conflicting mutations of the same field into a single policy where you control the order explicitly.

**A15.** Validate-only anchors: **equality** `=()` (if the key exists, its value must match), **existence** `^()` (at least one array element must match), and **negation** `X()` (the key must not exist). The **global anchor** `<()` is evaluated against the resource as a whole rather than the node it is written at: if its condition is not satisfied, the entire rule is skipped. Conditional `()` and add-if-not-present `+()` are the two that matter for mutation, and `+()` is mutate-only.

### Exercise 3

**A16.** `tolerations` is an **atomic list** in the PodSpec — it carries no `patchMergeKey`, so strategic merge has no way to identify "the same" element and replaces the whole list. You can see it in `kubectl explain pod.spec.tolerations` / the OpenAPI schema (`x-kubernetes-list-type: atomic`, and the absence of `x-kubernetes-patch-merge-key`). Contrast `spec.containers`, which has `patchMergeKey: name` and therefore merges per container — which is why every container patch in these exercises specifies `name`. **Rule of thumb: before writing a strategic merge patch against a list, check whether that list has a merge key. If it does not, strategic merge means "replace".**

**A17.** RFC 6902 `add` with the `-` token appends to an **existing** array. If `/spec/tolerations` is absent, the path's parent does not exist and the patch is invalid — the rule errors instead of creating the list. The two-rule form with mirrored preconditions is the standard Kyverno idiom: one rule creates the list, the other appends to it, and the preconditions guarantee exactly one of them runs.

**A18.** JSON Pointer (RFC 6901) uses `/` as the segment separator, so a literal `/` inside a key is escaped as `~1`, and a literal `~` as `~0` (decode `~1` first, then `~0`). Omit the escape and `debug.example.com/enabled` is parsed as two segments — `debug.example.com` then `enabled` — which do not exist, so the operation fails or, worse, silently targets the wrong node. Every annotation and label key with a domain prefix needs this.

**A19.** The Pod is **created**, and the rule reports an error rather than a mutation: `remove` on a non-existent path is invalid per RFC 6902, so Kyverno cannot produce a patch. With `failurePolicy: Fail` this class of error surfaces as a rejected request in the versions that propagate it; with `Ignore` it is swallowed and you only see it in the `PolicyError` event and controller log. Either way the correct fix is not to rely on the failure mode but to guard the operation:

```yaml
preconditions:
  all:
    - key: "{{ request.object.metadata.annotations || '{}' | keys(@) | contains(@, 'debug.example.com/enabled') }}"
      operator: Equals
      value: true
```

Confirm the exact behaviour on your Kyverno version — this is precisely the kind of edge semantics that has changed across releases, which is why the precondition, not the error handling, is the answer.

**A20.** `add` to an existing key overwrites it wholesale. If the value is a list — `tolerations`, `imagePullSecrets`, `env`, `volumes` — the patch destroys entries the workload owner deliberately set, and it does so silently, at admission, with no diff shown to the user. That is exactly the incident reproduced in step 3: a GPU toleration vanished, the Pod became unschedulable on the tainted nodes it was written for, and nothing in the Pod's own manifest explains why.

**A21.** Ten extra identical tolerations, one per update. `add … /-` is **not idempotent**, and mutate rules run on `UPDATE` as well as `CREATE` by default. The principle: *a mutation must converge to a fixed point*. Enforce it either by restricting the rule with `match.any[].resources.operations: [CREATE]` — remembering that this leaves updates unenforced — or, better, by making the patch self-checking with a precondition that the desired element is not already present. Strategic merge on a merge-keyed list is naturally idempotent; JSON Patch append never is.

### Exercise 4

**A22.** The `foreach` entry's **`preconditions`**, evaluated per element against `{{ element }}`. A `patchStrategicMerge` conditional anchor can only express "matches this glob"; here the requirement is the **negation** of a prefix test, plus reuse of the element's own value to build the new one. Preconditions give you the full JMESPath expression language per element, and `{{ element.image }}` gives you the old value to transform — neither is available to a bare anchor.

**A23.** With rule 1 removed, `/metadata/annotations` does not exist on a Pod that has none, so `op: add` to `/metadata/annotations/<key>` fails with a missing-parent error. Fixes: (a) keep a preceding `patchStrategicMerge` rule that creates the map — strategic merge creates missing parents, which is why rule 1 is first; or (b) express the whole thing as `patchStrategicMerge` with `"{{ element.name }}"` interpolated into the annotation key. Rule ordering inside a policy is what makes (a) reliable.

**A24.** The mutation succeeded completely — the API server accepted a syntactically valid Pod spec. `ErrImagePull` happens later, at the kubelet, because `mirror.example.com` does not exist. A mutate rule changes the desired state; it does not and cannot verify that the resulting state is *runnable*. Registry rewrite policies must therefore be paired with an environment where the mirror actually resolves, and rolled out behind a namespace selector — a bad rewrite policy applied cluster-wide breaks every image pull in the cluster at once, including Kyverno's own if it ever restarts.

**A25.** `request.object.spec.initContainers` resolves to null, the `foreach` iterates over nothing, and the rule is a no-op — no error, no event. Relying on that is fragile: make it explicit with `list: "request.object.spec.initContainers || []"`, or add a rule-level precondition asserting the key exists (`keys(@) | contains(@, 'initContainers')`). Explicit is better because a *typo* in the list expression also silently resolves to null — an unguarded `foreach` cannot distinguish "empty" from "wrong path".

**A26.** Any mutation that **removes** elements from a list by index, e.g. `patchesJson6902` with `op: remove, path: /spec/containers/{{ elementIndex }}` to strip sidecars. Removing ascending shifts every later index down by one, so the second removal hits the wrong element. `order: Descending` removes from the tail first, keeping the indices of not-yet-processed elements stable.

**A27.** Use `regex_replace_all_literal` to replace the registry component:

```yaml
image: "{{ regex_replace_all_literal('^[^/]+\\.[^/]+/', '{{ element.image }}', 'mirror.example.com/') }}"
```

The literal variant does no capture-group expansion in the replacement, which is what you want here. The regex requires a dot in the first segment so that Docker Hub short names (`nginx:1.27`, `library/nginx`) are not mistaken for registries — handle those with a second rule or a precondition, since they need a prefix added rather than replaced. Verify the expression with `kyverno jp query` before shipping it.

### Exercise 5

**A28.** The **background controller**. Mutate-existing is not an admission operation: the trigger is observed, an `UpdateRequest` is created, and the controller reconciles it by issuing an `UPDATE` against the target through the API server as its own ServiceAccount. Consequences: `failurePolicy` is irrelevant (there is no in-flight request to fail), the effect is **eventually** consistent with a lag of seconds or more, and failures surface only as events, `UpdateRequest` status and controller logs. It also means the rule needs `background` enabled and cannot use admission-only variables.

**A29.** The trigger succeeded because the trigger is not the thing being mutated — the ConfigMap write was never in doubt. The target update failed later, in a different controller, with `403 Forbidden`. The danger is that this is a **silent policy failure**: from the user's perspective, everything worked; the security or operational control the policy encodes simply did not happen. Any mutate-existing policy must be paired with an alert on the background controller's error rate or on `UpdateRequest` objects stuck in a failed state.

**A30.** Because Kyverno's shipped ClusterRoles are managed by its Helm chart / install manifest and are overwritten on upgrade — any direct edit is lost at the next `helm upgrade`. Kyverno's roles are **aggregated** roles; adding a ClusterRole labelled `rbac.kyverno.io/aggregate-to-background-controller: "true"` grafts your rules in through the aggregation controller and survives upgrades. Sibling labels exist for the admission, reports and cleanup controllers. This is also the correct place to apply least privilege: grant `update`/`patch` on exactly the kinds your policies target, never `*`.

**A31.** With `mutateExistingOnPolicyUpdate: true`, the rule also fires whenever the **policy itself** is created or updated, so Kyverno backfills every matching target instead of waiting for a trigger. On 4 000 Deployments that means 4 000 `UPDATE` calls queued through the background controller — API server load, an audit-log flood, and, since this particular patch touches `spec.template`, **4 000 simultaneous rolling restarts**. Roll such policies out with the flag `false` first, verify on one trigger, and only then decide whether backfill is safe; if it is, stage it by namespace.

**A32.** The annotation `touched=1` changes the ConfigMap's `resourceVersion`, so the rule fires and writes a *new* revision value into the pod template — which **does** trigger a rollout. That is the failure mode of using `resourceVersion` as the revision key: it changes on every write to the ConfigMap, including writes that do not alter the data your workload consumes. The production-grade key is a hash of the **data** only:

```yaml
config.example.com/revision: "{{ request.object.data | to_string(@) | sha256(@) }}"
```

Now a metadata-only edit produces the same hash, the patch is a no-op, and no rollout occurs. If your observation differed from your prediction, that difference is the lesson — mutate-existing rules that touch `spec.template` are rollout triggers, and their idempotency must be designed, not assumed.

**A33.** `{{ request.object.* }}` is the **trigger** (the ConfigMap that changed); `{{ target.* }}` is the **object being mutated** (the Deployment). Copy conditionally with an add-if-not-present anchor:

```yaml
patchStrategicMerge:
  metadata:
    labels:
      +(env): "{{ request.object.metadata.labels.env }}"
```

`+()` makes the rule converge: once the target has an `env` label, subsequent triggers are no-ops.

**A34.** No. Mutate-existing runs in the background controller, which requires `background: true`, and `background: true` forbids `request.userInfo` — the same validation that rejected the policy in Exercise 1, step 2. There is no admission request behind a background mutation, so there is no user to attribute it to; the actor in the audit log is Kyverno's own ServiceAccount.

### Exercise 6

**A35.** Autogen only rewrites the policy; the original Pod-level rule always remains, and it fires when the ReplicaSet controller submits the Pod. So the Pod is mutated either way — but with autogen off, the Deployment's stored `spec.template` never gains the label. The GitOps symptom is the *inverse* of Q8: with autogen **on**, the live Deployment differs from Git and the tool reports drift; with autogen **off**, the Deployment matches Git but the running Pods carry fields no manifest declares, so `kubectl get deploy -o yaml` gives you no way to explain what the Pods look like. Pick deliberately, and if you choose autogen, exclude the mutated paths in your GitOps tool.

**A36.** For `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `ReplicationController` and `Job`, the Pod-level patch is wrapped under `spec.template` (so `metadata.labels` becomes `spec.template.metadata.labels`). For `CronJob` it is wrapped under `spec.jobTemplate.spec.template`. You can read the generated result verbatim in `status.autogen.rules`, which is the authoritative answer for your version — never guess at it.

**A37.** Anything whose meaning is positional rather than declarative — for example a rule that injects an ephemeral, per-Pod value such as a boot token, a scheduling hint derived from `request.object.metadata.name`, or an annotation that must differ per replica. Written into `spec.template`, every replica gets the identical value and every template change triggers a rollout. Restrict with the annotation `pod-policies.kyverno.io/autogen-controllers: none` (Pod-only) or a subset such as `Deployment,StatefulSet`.

**A38.** Yes, autogen is independent of `background` — it is a policy-rewriting step, not a scan. `background: false` disables periodic background scanning of existing resources and the resulting policy reports for that policy; it does **not** affect admission-time evaluation, autogen, or webhook registration.

### Exercise 7

**A39.** Both are "right" for what they measure. `kyverno apply` evaluates policies against the YAML you hand it, with **no API server in the loop**: no defaulting, no admission chain, no other webhooks, no live cluster context. The cluster's `IfNotPresent` came from API-server defaulting (A11), which the CLI does not simulate. Consequences to internalise: the CLI cannot tell you whether a `+()` anchor will actually fire on a defaulted field, cannot resolve `context` entries that hit the live API unless you supply values, and cannot show interaction with other mutating webhooks. It is a policy unit test, not an integration test.

**A40.** `result: pass` only asserts that the rule *ran*; a mutation that produced the wrong value still passes. `patchedResources` asserts the **exact resulting object**, so it catches a changed anchor, a broken JMESPath expression, an off-by-one JSON Pointer, or a regression introduced by reordering rules. For mutate rules it is the assertion that actually has teeth.

**A41.** Supply a values file (`--values values.yaml` / the `variables:` key in the Test manifest) that pins `request.userInfo`, `request.operation` and any `context` lookups to fixed values, and commit it alongside the fixtures. Without it the variable is unresolved and the test result depends on the CLI's fallback behaviour rather than on your policy.

**A42.** Non-zero on failure — which is what makes it a usable gate. The minimal CI gate: run `kyverno test ./policies/...` on every PR touching a policy, with one fixture pair (`resource.yaml` + `patched.yaml`) per branch of every rule — including the *negative* cases (`result: skip` when a precondition excludes the resource). Add `kyverno apply --resource` against a directory of real, exported cluster objects as a smoke test before promoting a policy from staging.

### Exercise 8

**A43.** Cheapest first: (1) **webhook not registered for the kind** — one `kubectl get mutatingwebhookconfiguration`, unambiguous; (2) **`resourceFilters` exclusion** — one ConfigMap read, unambiguous; (3) **precondition false** — visible as a `PolicySkipped` event or reproducible offline with `kyverno apply` on the live object; (4) **`failurePolicy: Ignore` swallowing an error** — the most expensive, because by construction it leaves the least evidence in the request path; you need the controller logs, correlated by timestamp, and possibly `--dumpPayload`.

**A44.** (1) The live object has been through defaulting, other mutating webhooks and the API server's own strategy, so it is not the object Kyverno saw at admission — notably, it may already contain the mutation, making an idempotent rule appear to be a no-op. (2) The CLI has no `AdmissionRequest`, so `request.operation`, `request.userInfo` and any `context` API calls resolve differently or not at all. Export the object, strip `status`, `metadata.managedFields`, `metadata.uid`, `metadata.resourceVersion` and `metadata.creationTimestamp`, and supply variables explicitly before drawing conclusions.

**A45.** (1) **The controller's namespace is excluded** by `resourceFilters` — check the ConfigMap. (2) **The rule matches only `Pod` and you are inspecting the controller object**; the Pod *is* mutated — check `kubectl get pod -o yaml`, not the Deployment. (3) **The match block uses `objectSelector` on labels the controller does not propagate**, or an `operations: [CREATE]` restriction while the controller path performs an update — check `kubectl get cpol <name> -o yaml` and the `status.autogen.rules`. A fourth to keep in mind: the controller's ServiceAccount is in an `exclude` block.

**A46.** Because a cluster-wide `Pod` mutate rule with `failurePolicy: Fail` means every Kyverno unavailability — upgrade, node drain, OOM, certificate rotation — becomes a cluster-wide inability to schedule new Pods, including the Pods that would restore Kyverno itself. Mitigations, applied together: run ≥3 admission-controller replicas with anti-affinity and a PDB; keep `kube-system` and Kyverno's own namespace in `resourceFilters`; scope the webhook with `namespaceSelector` so critical namespaces are never intercepted; and introduce new rules with `failurePolicy: Ignore` plus report-based monitoring before tightening them.

### Exercise 9

**A47.** `kyverno-resource-mutating-webhook-cfg` ran first, in the **mutating admission** phase, adding `team=platform`. The API server then performed schema validation, then called `kyverno-resource-validating-webhook-cfg` in the **validating admission** phase, which saw the already-mutated object and passed it. That ordering is guaranteed by Kubernetes, not by Kyverno, and it is what makes "mutate to remediate, validate to enforce" a sound pattern.

**A48.** Same policy: no change — the phase boundary is enforced by the API server across all webhooks, so the mutate rule still runs in the earlier phase regardless of co-location. Two policies with different names: also no change, for the same reason. Policy ordering is only a concern between two **mutate** rules contending for the same field (A14), never between a mutate and a validate rule.

**A49.** Two rules: a mutate rule using `+(key): <default>` so it fills the field only when absent and never overrides a deliberate choice, followed by a validate rule with `pattern`/`deny` that rejects any value outside the allowed set. The **validate** rule must not use `+()` — the anchor is mutate-only, and the semantics you want there are "the value must be one of these," not "default it." Ship the validate rule in `Audit` first, read the policy reports, then switch to `Enforce`.

**A50.** (1) **Events** — Kyverno emits `PolicyApplied` on the resource (and `PolicySkipped`/`PolicyError` on the alternatives), which is the per-request record; enable `generateSuccessEvents` if you want them for successful mutations too. (2) The **Kubernetes audit log**, where the `patch` sub-stage records the webhook's response and attributes it to `kyverno-svc`, and the resulting object's `metadata.managedFields` shows the mutation under Kyverno's field manager rather than the user's. Policy reports cover validate results, not mutations, so they are not a substitute for either.

</details>

---

## Sources

- Kyverno — Mutate rules (patchStrategicMerge, patchesJson6902, foreach, mutate existing, targets): <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno — Anchors and pattern matching: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — JMESPath and Kyverno's custom functions: <https://kyverno.io/docs/writing-policies/jmespath/>
- Kyverno — Preconditions: <https://kyverno.io/docs/writing-policies/preconditions/>
- Kyverno — Auto-gen rules for Pod controllers: <https://kyverno.io/docs/writing-policies/autogen/>
- Kyverno — Installation and customization (`resourceFilters`, aggregated RBAC, webhook configuration): <https://kyverno.io/docs/installation/customization/>
- Kyverno — CLI (`apply`, `test`, `jp`): <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Policy library (production examples of registry rewrite, sidecar injection, mutate existing): <https://kyverno.io/policies/>
- Kubernetes — Dynamic admission control and webhook ordering: <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Kubernetes — Update API objects in place using `kubectl patch` (strategic merge patch, merge keys): <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/>
- Kubernetes — Container images and `imagePullPolicy` defaulting: <https://kubernetes.io/docs/concepts/containers/images/>
- Kubernetes — Labels and selectors (syntax and value constraints): <https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/>
- IETF RFC 6902 — JavaScript Object Notation (JSON) Patch: <https://datatracker.ietf.org/doc/html/rfc6902>
- IETF RFC 6901 — JavaScript Object Notation (JSON) Pointer (`~0` / `~1` escaping): <https://datatracker.ietf.org/doc/html/rfc6901>
- CNCF — KCA curriculum: <https://github.com/cncf/curriculum>