# KCA 4.2 — Resource Selection — Guided Exercises

> **Domain 4 · Topic 4.2 · Exam weight 3.33%**
> Selecting Kubernetes objects and nodes with **labels**, **label selectors** (equality- and set-based), and **field selectors** — and understanding how those same selectors *bind* objects at runtime (Service → Pods, controller → Pods, Pod → Node). By the end you should be able to explain *why* a Service has zero endpoints, *why* a Deployment refuses `kubectl apply`, and *why* a Pod stays `Pending`.
>
> **Sources**
> - Labels and Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
> - Field Selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/
> - `kubectl get` reference — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_get/
> - Service (selector → EndpointSlice) — https://kubernetes.io/docs/concepts/services-networking/service/
> - Assigning Pods to Nodes — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
> - Deployment `.spec.selector` — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#selector

---

## Prerequisites

Any single-node cluster works (`kind`, `minikube`, or a lab cluster). Verify:

```console
$ kubectl version --output=json | grep -m1 gitVersion
    "gitVersion": "v1.31.0",
$ kubectl get nodes
NAME                 STATUS   ROLES           AGE   VERSION
kind-control-plane   Ready    control-plane   9m    v1.31.0
```

Work in a throwaway namespace so cleanup is trivial:

```console
$ kubectl create namespace rs-lab
namespace/rs-lab created
$ kubectl config set-context --current --namespace=rs-lab
Context "kind-kind" modified.
```

---

## Exercise 1 — Labels and equality-based selectors

Labels are the **only** first-class query dimension the API server indexes for arbitrary user metadata. A selector is a filter *ANDed* across its terms; it never ORs.

1. Create three Pods with overlapping label sets:

   ```console
   $ kubectl run web-a  --image=nginx:1.27 --labels="app=web,tier=frontend,env=prod"
   $ kubectl run web-b  --image=nginx:1.27 --labels="app=web,tier=frontend,env=qa"
   $ kubectl run api-a  --image=nginx:1.27 --labels="app=api,tier=backend,env=prod"
   ```

2. List labels as columns:

   ```console
   $ kubectl get pods --show-labels
   NAME    READY   STATUS    RESTARTS   AGE   LABELS
   api-a   1/1     Running   0          20s   app=api,env=prod,tier=backend
   web-a   1/1     Running   0          25s   app=web,env=prod,tier=frontend
   web-b   1/1     Running   0          22s   app=web,env=qa,tier=frontend
   ```

3. Filter with an equality-based selector (`-l` / `--selector`). Note the comma is a logical **AND**:

   ```console
   $ kubectl get pods -l app=web,env=prod
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          40s
   ```

4. Use inequality (`!=`) and promote a label to a column with `-L`:

   ```console
   $ kubectl get pods -l 'env!=qa' -L tier
   NAME    READY   STATUS    RESTARTS   AGE   TIER
   api-a   1/1     Running   0          55s   backend
   web-a   1/1     Running   0          60s   frontend
   ```

5. Mutate a label in place and re-query. `--overwrite` is required to change an existing key:

   ```console
   $ kubectl label pod web-b env=prod --overwrite
   pod/web-b labeled
   $ kubectl get pods -l app=web,env=prod
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          75s
   web-b   1/1     Running   0          72s
   ```

**Comprehension check 1**
- **1a.** In step 3, why does `-l app=web,env=prod` return only `web-a` and not `web-b`, even though both are `app=web`?
- **1b.** What happens if you run `kubectl label pod web-b env=stage` *without* `--overwrite`, given `env` already exists?
- **1c.** You want "all Pods that are `app=web` **or** `app=api`". Can a single equality-based selector express that? Why or why not?

---

## Exercise 2 — Set-based selectors

Set-based selectors add the operators `in`, `notin`, `exists` (`key`), and `does-not-exist` (`!key`). They are strictly more expressive than equality-based ones and are what controllers use under the hood (`matchExpressions`).

1. `in` matches a **set** of values (this is the closest thing to an OR):

   ```console
   $ kubectl get pods -l 'app in (web,api),env in (prod)'
   NAME    READY   STATUS    RESTARTS   AGE
   api-a   1/1     Running   0          2m
   web-a   1/1     Running   0          2m
   web-b   1/1     Running   0          2m
   ```

2. `notin` excludes a set:

   ```console
   $ kubectl get pods -l 'tier notin (backend)'
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          2m
   web-b   1/1     Running   0          2m
   ```

3. Existence (`key`) and non-existence (`!key`). Add a Pod that lacks `tier`, then select on the *presence* of the key regardless of value:

   ```console
   $ kubectl run cache-a --image=redis:7 --labels="app=cache,env=prod"
   $ kubectl get pods -l 'tier'          # key exists, any value
   NAME    READY   STATUS    RESTARTS   AGE
   api-a   1/1     Running   0          3m
   web-a   1/1     Running   0          3m
   web-b   1/1     Running   0          3m
   $ kubectl get pods -l '!tier'         # key absent
   NAME      READY   STATUS    RESTARTS   AGE
   cache-a   1/1     Running   0          20s
   ```

4. Combine set-based and equality-based terms in one expression (still ANDed):

   ```console
   $ kubectl get pods -l 'app in (web,cache),env=prod,tier'
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          3m
   web-b   1/1     Running   0          3m
   ```

**Comprehension check 2**
- **2a.** `cache-a` has `env=prod` and `app=cache`. Why is it excluded by the selector in step 4 even though it satisfies two of the three terms?
- **2b.** Rewrite `-l 'env!=qa'` (equality-based) as an equivalent set-based selector. Are they semantically identical for a Pod that has **no** `env` label at all?
- **2c.** Which operators from this exercise can appear inside a `matchExpressions` block of a Deployment selector, and what is the JSON keyword for each?

---

## Exercise 3 — Field selectors

Label selectors query *user-assigned metadata*. **Field selectors** query the object's *own structural fields* (`status.phase`, `spec.nodeName`, `metadata.namespace`, …). The set of selectable fields is fixed per resource type — it is not arbitrary JSONPath.

1. Filter Pods by lifecycle phase (a `status` field):

   ```console
   $ kubectl get pods --field-selector status.phase=Running
   NAME      READY   STATUS    RESTARTS   AGE
   api-a     1/1     Running   0          4m
   cache-a   1/1     Running   0          1m
   web-a     1/1     Running   0          4m
   web-b     1/1     Running   0          4m
   ```

2. Filter by scheduling target (`spec.nodeName`) and combine terms with a comma (AND):

   ```console
   $ kubectl get pods --field-selector spec.nodeName=kind-control-plane,status.phase=Running -o name
   pod/api-a
   pod/cache-a
   pod/web-a
   pod/web-b
   ```

3. Field selectors are the idiomatic way to slice **Events**, which have no useful labels:

   ```console
   $ kubectl get events --field-selector type=Warning,involvedObject.kind=Pod
   LAST SEEN   TYPE      REASON      OBJECT        MESSAGE
   30s         Warning   BackOff     pod/broken    Back-off restarting failed container
   ```

4. Ask for an unsupported field and read the error — this teaches you the allowed set is enforced server-side:

   ```console
   $ kubectl get pods --field-selector spec.containers[0].image=nginx:1.27
   Error from server (BadRequest): Unable to find "/v1, Resource=pods" that match label selector "", field selector "spec.containers[0].image=nginx:1.27": field label not supported: spec.containers[0].image
   ```

5. Field and label selectors compose — both are sent to the API server and ANDed there:

   ```console
   $ kubectl get pods -l app=web --field-selector status.phase=Running
   NAME    READY   STATUS    RESTARTS   AGE
   web-a   1/1     Running   0          5m
   web-b   1/1     Running   0          5m
   ```

**Comprehension check 3**
- **3a.** Why can you filter on `status.phase` but *not* on `spec.containers[0].image` (step 4)? Where is that allow-list defined?
- **3b.** A field selector and a label selector on the same `kubectl get` — are they evaluated as AND or OR? Does the filtering happen in `kubectl` or in the API server?
- **3c.** Why are field selectors the recommended tool for querying Events, whereas labels are recommended for Pods?

---

## Exercise 4 — Selectors that *bind*: Service → Pods

A Service's `.spec.selector` is a **plain label map** (implicit equality, all keys ANDed). The EndpointSlice controller continuously resolves it to a set of ready Pod IPs. If the selector matches nothing, the Service has no backends — a silent, extremely common outage.

1. Apply a Service whose selector matches the frontend Pods:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: rs-lab
   spec:
     selector:
       app: web
       tier: frontend
     ports:
       - name: http
         port: 80
         targetPort: 80
   ```

   ```console
   $ kubectl apply -f web-svc.yaml
   service/web created
   ```

2. Confirm the selector resolved to endpoints. Prefer EndpointSlices (the modern data plane):

   ```console
   $ kubectl get endpointslices -l kubernetes.io/service-name=web
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS               AGE
   web-abcde   IPv4          80      10.244.0.7,10.244.0.8   10s
   ```

3. Now **break** the selector — introduce a typo that no Pod satisfies:

   ```console
   $ kubectl patch svc web --type=merge -p '{"spec":{"selector":{"app":"web","tier":"front-end"}}}'
   service/web patched
   $ kubectl get endpointslices -l kubernetes.io/service-name=web
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
   web-abcde   IPv4          80      <unset>     40s
   ```

4. Diagnose the empty backend set the way you would in production. `kubectl describe` shows the resolved endpoints and the selector side by side:

   ```console
   $ kubectl describe svc web | egrep 'Selector|Endpoints'
   Selector:          app=web,tier=front-end
   Endpoints:
   ```

5. Restore the correct selector and confirm endpoints return:

   ```console
   $ kubectl patch svc web --type=merge -p '{"spec":{"selector":{"app":"web","tier":"frontend"}}}'
   service/web patched
   $ kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{.items[0].endpoints[*].addresses[0]}'
   10.244.0.7 10.244.0.8
   ```

**Comprehension check 4**
- **4a.** A Service `.spec.selector` cannot express `matchExpressions` — only a flat map. What operator is every key/value pair in that map implicitly using, and how are multiple pairs combined?
- **4b.** In step 3 the Service still exists and has a stable ClusterIP, but traffic to it fails. What is the exact runtime symptom, and which object would you inspect first to confirm the cause?
- **4c.** Two of your three `app=web` Pods were `frontend`; a third Pod is `app=web,tier=backend`. Would the original Service in step 1 send traffic to it? Justify using the ANDing rule.

---

## Exercise 5 — Controller selectors: `matchLabels`, `matchExpressions`, immutability

Deployments/ReplicaSets/etc. use a **`LabelSelector`** object (`matchLabels` + `matchExpressions`), which is far more expressive than a Service's flat map — and, in `apps/v1`, **immutable after creation**. The selector is how the controller *claims ownership* of Pods; changing it would orphan the current ReplicaSet.

1. Apply a Deployment whose selector uses both `matchLabels` and `matchExpressions`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: shop
     namespace: rs-lab
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: shop
       matchExpressions:
         - key: tier
           operator: In
           values: ["frontend", "backend"]
     template:
       metadata:
         labels:
           app: shop
           tier: frontend
       spec:
         containers:
           - name: nginx
             image: nginx:1.27
             ports:
               - containerPort: 80
   ```

   ```console
   $ kubectl apply -f shop-deploy.yaml
   deployment.apps/shop created
   $ kubectl get rs -l app=shop
   NAME              DESIRED   CURRENT   READY   AGE
   shop-7d9f6c8b5c   2         2         2       12s
   ```

2. Confirm the ReplicaSet inherited the same selector and is claiming the Pods:

   ```console
   $ kubectl get pods -l 'app=shop,tier in (frontend,backend)' -o name
   pod/shop-7d9f6c8b5c-4nq2p
   pod/shop-7d9f6c8b5c-9xk7w
   ```

3. Attempt to change the selector — this **must fail** in `apps/v1`:

   ```console
   $ kubectl patch deployment shop --type=merge \
       -p '{"spec":{"selector":{"matchLabels":{"app":"store"}}}}'
   The Deployment "shop" is invalid: spec.selector: Invalid value: ...: field is immutable
   ```

4. Verify the guard rail that protects you: the template labels **must** satisfy the selector. Try to apply a Deployment whose template does not match its own selector:

   ```console
   $ kubectl apply -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: bad, namespace: rs-lab }
   spec:
     replicas: 1
     selector: { matchLabels: { app: bad } }
     template:
       metadata: { labels: { app: WRONG } }
       spec: { containers: [ { name: c, image: nginx:1.27 } ] }
   EOF
   The Deployment "bad" is invalid: spec.template.metadata.labels: Invalid value: map[string]string{"app":"WRONG"}: `selector` does not match template `labels`
   ```

5. Observe **orphaning** — the mechanism selector immutability protects against. Delete the Deployment but keep its Pods, then see them survive because nothing re-selects them:

   ```console
   $ kubectl delete deployment shop --cascade=orphan
   deployment.apps "shop" deleted
   $ kubectl get pods -l app=shop
   NAME                    READY   STATUS    RESTARTS   AGE
   shop-7d9f6c8b5c-4nq2p   1/1     Running   0          3m
   shop-7d9f6c8b5c-9xk7w   1/1     Running   0          3m
   ```

**Comprehension check 5**
- **5a.** Why does Kubernetes make `.spec.selector` immutable in `apps/v1`? Describe the ownership problem a mutable selector would cause using the term "orphan."
- **5b.** In step 4, the API server rejected the object *before* any Pod was created. Which invariant between `.spec.selector` and `.spec.template.metadata.labels` is being enforced, and why is it required for the controller to function?
- **5c.** A Service selector is a flat map but a Deployment selector is a `LabelSelector`. Give one concrete selection a Deployment can express that a Service cannot.

---

## Exercise 6 — Node selection: `nodeSelector` and node affinity

The same selector machinery decides *where* a Pod runs. `nodeSelector` is the simplest form: a flat map of labels that a node **must** carry. Node affinity is the expressive, set-based superset (`In`, `NotIn`, `Exists`, …) with `required` vs `preferred` variants.

1. Inspect a node's built-in labels (these exist without you setting anything):

   ```console
   $ kubectl get node kind-control-plane -o jsonpath='{.metadata.labels}' | tr ',' '\n' | egrep 'os|hostname'
   "kubernetes.io/hostname":"kind-control-plane"
   "kubernetes.io/os":"linux"
   ```

2. Add a custom node label representing a hardware class:

   ```console
   $ kubectl label node kind-control-plane disktype=ssd
   node/kind-control-plane labeled
   ```

3. Schedule a Pod that *requires* that label via `nodeSelector`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: ssd-pod
     namespace: rs-lab
   spec:
     nodeSelector:
       disktype: ssd
       kubernetes.io/os: linux
     containers:
       - name: nginx
         image: nginx:1.27
   ```

   ```console
   $ kubectl apply -f ssd-pod.yaml
   pod/ssd-pod created
   $ kubectl get pod ssd-pod -o wide
   NAME      READY   STATUS    RESTARTS   AGE   IP            NODE
   ssd-pod   1/1     Running   0          8s    10.244.0.9    kind-control-plane
   ```

4. Now demand a label **no node has**, and read the scheduler's verdict — this is the canonical `Pending`-forever diagnosis:

   ```console
   $ kubectl run gpu-pod --image=nginx:1.27 --overrides='{"spec":{"nodeSelector":{"disktype":"nvme"}}}'
   $ kubectl get pod gpu-pod
   NAME      READY   STATUS    RESTARTS   AGE
   gpu-pod   0/1     Pending   0          15s
   $ kubectl describe pod gpu-pod | sed -n '/Events/,$p'
   Events:
     Type     Reason            Age   From               Message
     ----     ------            ----  ----               -------
     Warning  FailedScheduling  20s   default-scheduler  0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector.
   ```

5. Express the same intent with **node affinity**, which — unlike `nodeSelector` — supports set-based operators:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: affinity-pod
     namespace: rs-lab
   spec:
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
             - matchExpressions:
                 - key: disktype
                   operator: In
                   values: ["ssd", "nvme"]
     containers:
       - name: nginx
         image: nginx:1.27
   ```

   ```console
   $ kubectl apply -f affinity-pod.yaml
   pod/affinity-pod created
   $ kubectl get pod affinity-pod -o wide
   NAME           READY   STATUS    RESTARTS   AGE   NODE
   affinity-pod   1/1     Running   0          6s    kind-control-plane
   ```

**Comprehension check 6**
- **6a.** In step 4 the Pod is `Pending`, not `Failed`. What does that status tell you about *when* selection happens and what the scheduler does when no node matches?
- **6b.** `IgnoredDuringExecution` appears in the affinity field name. If you *removed* the `disktype=ssd` label from the node *after* `ssd-pod` was already running, would the Pod be evicted? Why?
- **6c.** Name two things node affinity can express that `nodeSelector` cannot.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **1a.** A comma-separated equality selector is a logical **AND** across all terms. `app=web,env=prod` requires *both* `app=web` **and** `env=prod`. At that point in the lab `web-b` was `env=qa`, so it failed the second term. (After step 5's relabel it would also match.)
- **1b.** It is rejected. `kubectl label` refuses to change a key that already exists unless you pass `--overwrite`:
  `error: 'env' already has a value (prod), and --overwrite is false`. This prevents accidental clobbering of labels that controllers may be selecting on.
- **1c.** No. A single equality-based selector can only AND terms; it has no OR. "`app=web` **or** `app=api`" requires a *set-based* selector: `-l 'app in (web,api)'`. (See Exercise 2.)

### Exercise 2
- **2a.** All terms in a selector are ANDed regardless of style. `'app in (web,cache),env=prod,tier'` requires the `tier` key to **exist**. `cache-a` was created with only `app` and `env`, so it fails the `tier` (Exists) term and is excluded despite matching the other two.
- **2b.** `-l 'env!=qa'` ⇔ `-l 'env notin (qa)'`. **However they differ for a Pod with no `env` label at all.** Per the docs, the equality `!=` and set-based `notin` operators match objects that have the key with a different value **and** objects that do *not* have the key — i.e. both include label-less objects. (Contrast with `=`/`in`, which require the key to be present.) So in this specific case they are equivalent, including for the label-less Pod. The trap to remember: `key!=value` does **not** mean "has the key with a different value" — an object missing the key still matches.
- **2c.** `matchExpressions` supports `In`, `NotIn`, `Exists`, `DoesNotExist` (the JSON `operator` keywords). `in`→`In`, `notin`→`NotIn`, `key` (exists)→`Exists`, `!key`→`DoesNotExist`. Equality `=`/`==` maps to `In` with a single value.

### Exercise 3
- **3a.** The API server only supports field selectors on a **fixed, per-resource allow-list** of fields (registered in each type's registry strategy on the server), not arbitrary JSONPath into the object. `metadata.name`, `metadata.namespace`, and a curated few like `status.phase`, `spec.nodeName` are registered for Pods; `spec.containers[0].image` is not, so the server returns `field label not supported`.
- **3b.** **AND**, and the filtering happens **server-side**. Both selectors are encoded into the `LIST`/`WATCH` request query string and evaluated by the API server; `kubectl` does not post-filter. This is why selectors scale — the server returns only matching objects.
- **3c.** Events carry almost no user labels but have rich structural fields (`involvedObject.kind`, `involvedObject.name`, `type`, `reason`), so field selectors are the natural filter. Pods, conversely, are meant to be organized and queried by user-assigned labels (`app`, `tier`, `env`), which is what controllers and Services also select on.

### Exercise 4
- **4a.** Every key/value pair in a Service `.spec.selector` is an **implicit equality** (`key=value`), and multiple pairs are combined with **AND**. There is no set-based syntax and no OR; a Service selector is strictly a flat `map[string]string`.
- **4b.** The Service keeps its ClusterIP and DNS name, but its EndpointSlice has **zero ready addresses**, so kube-proxy has nowhere to forward — connections time out or are refused with no backend. Inspect the **EndpointSlice** (`kubectl get endpointslices -l kubernetes.io/service-name=<svc>`) or `kubectl describe svc` and confirm `Endpoints:` is empty; then compare the Service selector to the actual Pod labels.
- **4c.** No. The step-1 selector is `app=web` **AND** `tier=frontend`. A Pod labelled `app=web,tier=backend` satisfies the first term but fails the second, and because the terms are ANDed it is excluded. It would only be selected if the Service selector dropped the `tier` term or the Pod were relabelled `tier=frontend`.

### Exercise 5
- **5a.** A Deployment claims and manages Pods *by selector* (through its ReplicaSet). If the selector could change, the controller would stop matching its existing ReplicaSet/Pods — those become **orphans** (running but unmanaged), while the controller spins up a brand-new set to satisfy the new selector, silently doubling the workload and leaking the old Pods. `apps/v1` makes `.spec.selector` immutable to make this class of accident impossible; the supported path is to create a new Deployment.
- **5b.** The invariant is that `.spec.template.metadata.labels` **must be a superset that satisfies `.spec.selector`**. If the Pods a controller stamps out did not carry labels matching its own selector, the controller would create Pods it cannot then select/own — it would loop forever, never counting them toward `replicas`. The API server rejects the object up front to prevent that.
- **5c.** A Service can only AND equality pairs. A Deployment `LabelSelector` can use `matchExpressions` with set-based operators — e.g. `tier In (frontend, backend)`, or `Exists`/`DoesNotExist` on a key — which no Service selector can express.

### Exercise 6
- **6a.** `Pending` means the Pod is a valid, persisted API object that has **not yet been bound to a node**. Node selection happens at **schedule time**: the scheduler filters nodes by the Pod's `nodeSelector`/affinity, finds none feasible, emits a `FailedScheduling` event, and requeues the Pod. It never "fails" — it waits indefinitely for a node that satisfies the selector to appear (e.g. via labelling a node or cluster autoscaling).
- **6b.** No, it keeps running. `requiredDuringSchedulingIgnoredDuringExecution` enforces the rule **only at scheduling time**; the `IgnoredDuringExecution` half means label changes on the node afterward are ignored for already-running Pods. Removing `disktype=ssd` would block *future* scheduling of such Pods but never evict the current one. (An eviction-on-change variant — `RequiredDuringExecution` — is not implemented.)
- **6c.** Any two of: (1) set-based operators (`In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`) rather than only equality; (2) **soft/preferred** rules (`preferredDuringScheduling…`) with weights, whereas `nodeSelector` is strictly hard/required; (3) multiple `nodeSelectorTerms` ORed together (terms are OR, the `matchExpressions` inside a term are AND), giving disjunctions `nodeSelector` cannot express.

</details>

---

## Cleanup

```console
$ kubectl delete namespace rs-lab
$ kubectl label node kind-control-plane disktype-
$ kubectl config set-context --current --namespace=default