# Topic 2.2 — Kyverno Custom Resource Definitions (CRDs)

> **Domain 2 · Exam weight: 3.0 · Level: production**
>
> Kyverno is a policy engine that runs *entirely as a set of Kubernetes Custom Resources*. There is no DSL, no sidecar language, no external policy language to learn: every policy, every exception, every result and every internal work item is a Kubernetes object served by the API server through a CRD that Kyverno installs. Mastering the CRD surface — which kinds exist, their scope, their API groups/versions, and how they relate to one another — is the backbone of everything else on the exam.
>
> **Prerequisites:** a working cluster (`kind`, `k3d`, or minikube ≥ 3 nodes recommended), `kubectl ≥ 1.27`, and Helm 3. All manifests below are syntactically complete and idempotent — re-applying them is safe.

---

## Exercise 0 — Install Kyverno and expose its CRD surface

Kyverno ships its CRDs as part of the Helm chart. Installing the chart is the only way the API server learns about `ClusterPolicy`, `PolicyReport`, etc.

**Steps**

1. Add the repository and install into its own namespace:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno \
     --namespace kyverno --create-namespace \
     --set admissionController.replicas=1 \
     --wait
   ```

2. Confirm every controller Deployment is Ready (Kyverno 1.10+ splits into four controllers):

   ```bash
   kubectl -n kyverno get deploy
   ```

   Expected:

   ```
   NAME                                 READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller         1/1     1            1           95s
   kyverno-background-controller        1/1     1            1           95s
   kyverno-cleanup-controller           1/1     1            1           95s
   kyverno-reports-controller           1/1     1            1           95s
   ```

3. List every CRD Kyverno registered:

   ```bash
   kubectl get crd | grep -E 'kyverno\.io|wgpolicyk8s\.io'
   ```

   Expected (abridged):

   ```
   admissionreports.reports.kyverno.io                2026-08-13T09:14:22Z
   backgroundscanreports.reports.kyverno.io           2026-08-13T09:14:22Z
   cleanuppolicies.kyverno.io                         2026-08-13T09:14:21Z
   clusteradmissionreports.reports.kyverno.io         2026-08-13T09:14:22Z
   clusterbackgroundscanreports.reports.kyverno.io    2026-08-13T09:14:22Z
   clustercleanuppolicies.kyverno.io                  2026-08-13T09:14:21Z
   clusterpolicies.kyverno.io                         2026-08-13T09:14:21Z
   clusterpolicyreports.wgpolicyk8s.io                2026-08-13T09:14:22Z
   globalcontextentries.kyverno.io                    2026-08-13T09:14:21Z
   policies.kyverno.io                                2026-08-13T09:14:21Z
   policyexceptions.kyverno.io                        2026-08-13T09:14:21Z
   policyreports.wgpolicyk8s.io                       2026-08-13T09:14:22Z
   updaterequests.kyverno.io                          2026-08-13T09:14:21Z
   ```

**Comprehension**

- **Q1.** Two of the CRDs above do **not** live in the `kyverno.io` API group. Which two, and which group do they belong to? Why do you think Kyverno adopted an external group for them instead of `kyverno.io`?
- **Q2.** Which of the four controller Deployments would you expect to be the *authoring* consumer of the `reports.kyverno.io` CRDs, and which produces the `wgpolicyk8s.io` reports?

---

## Exercise 1 — Enumerate scope, short names, and API versions

CRDs carry three properties the exam repeatedly tests: **scope** (Namespaced vs Cluster), **short name**, and **served/storage versions**.

**Steps**

1. Print the machine-readable resource table for both groups:

   ```bash
   kubectl api-resources --api-group=kyverno.io
   kubectl api-resources --api-group=reports.kyverno.io
   kubectl api-resources --api-group=wgpolicyk8s.io
   ```

   Combined expected output:

   ```
   NAME                           SHORTNAMES   APIVERSION                NAMESPACED   KIND
   cleanuppolicies                cleanpol     kyverno.io/v2beta1        true         CleanupPolicy
   clustercleanuppolicies         ccleanpol    kyverno.io/v2beta1        false        ClusterCleanupPolicy
   clusterpolicies                cpol         kyverno.io/v1             false        ClusterPolicy
   globalcontextentries           gctxentry    kyverno.io/v2alpha1       false        GlobalContextEntry
   policies                       pol          kyverno.io/v1             true         Policy
   policyexceptions               polex        kyverno.io/v2beta1        true         PolicyException
   updaterequests                 ur           kyverno.io/v2             true         UpdateRequest
   admissionreports               admr         reports.kyverno.io/v1     true         AdmissionReport
   backgroundscanreports          bgscanr      reports.kyverno.io/v1     true         BackgroundScanReport
   clusteradmissionreports        cadmr        reports.kyverno.io/v1     false        ClusterAdmissionReport
   clusterbackgroundscanreports   cbgscanr     reports.kyverno.io/v1     false        ClusterBackgroundScanReport
   clusterpolicyreports           cpolr        wgpolicyk8s.io/v1alpha2   false        ClusterPolicyReport
   policyreports                  polr         wgpolicyk8s.io/v1alpha2   true         PolicyReport
   ```

2. See which API versions the *policy* CRD serves, and which is the **storage** version:

   ```bash
   kubectl api-versions | grep kyverno
   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{range .spec.versions[*]}{.name}{"  served="}{.served}{"  storage="}{.storage}{"\n"}{end}'
   ```

   Expected:

   ```
   kyverno.io/v1
   kyverno.io/v2
   kyverno.io/v2beta1
   ```
   ```
   v1        served=true   storage=false
   v2beta1   served=true   storage=false
   v2        served=true   storage=true
   ```

3. Confirm the scope directly from the CRD (not just `api-resources`):

   ```bash
   kubectl get crd policies.kyverno.io        -o jsonpath='{.spec.scope}{"\n"}'
   kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.spec.scope}{"\n"}'
   ```

   Expected:

   ```
   Namespaced
   Cluster
   ```

**Comprehension**

- **Q3.** A `Policy` and a `ClusterPolicy` have *byte-for-byte identical* `spec` schemas. What single field of the CRD is the only thing that differs, and what practical guarantee does choosing `Policy` over `ClusterPolicy` give a namespace tenant?
- **Q4.** You wrote a manifest with `apiVersion: kyverno.io/v1`. The CRD reports `v2` as the storage version. When you `kubectl get cpol <name> -o yaml`, which `apiVersion` comes back, and why is your original `v1` request still valid?
- **Q5.** Give the correct short name for `ClusterPolicy`, `PolicyReport`, `PolicyException`, and `UpdateRequest`.

---

## Exercise 2 — `ClusterPolicy` vs `Policy`: schema, scope, and reach

Now instantiate the two policy CRDs and observe how scope constrains what each can match.

**Steps**

1. Inspect the top-level schema of the policy CRD without leaving the terminal:

   ```bash
   kubectl explain clusterpolicy.spec --recursive=false
   ```

   Expected (abridged):

   ```
   FIELDS:
     admission                 <boolean>
     background                <boolean>
     failurePolicy             <string>
     rules                     <[]Object>
     validationFailureAction   <string>
     ...
   ```

2. Create a **cluster-scoped** validating policy that requires a `team` label on every Pod:

   ```yaml
   # require-labels-cpol.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Enforce   # Audit | Enforce (PascalCase since 1.10)
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "The label 'team' is required on every Pod."
           pattern:
             metadata:
               labels:
                 team: "?*"          # ?* = at least one character
   ```

   ```bash
   kubectl apply -f require-labels-cpol.yaml
   ```

3. Create a **namespaced** policy that only governs the `payments` namespace:

   ```yaml
   # require-cost-center-pol.yaml
   apiVersion: kyverno.io/v1
   kind: Policy
   metadata:
     name: require-cost-center
     namespace: payments
   spec:
     validationFailureAction: Audit
     background: true
     rules:
       - name: check-cost-center
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "Pods in payments must carry a cost-center label."
           pattern:
             metadata:
               labels:
                 cost-center: "?*"
   ```

   ```bash
   kubectl create namespace payments
   kubectl apply -f require-cost-center-pol.yaml
   ```

4. Try to violate the cluster policy and watch admission reject it:

   ```bash
   kubectl run nginx --image=nginx --namespace=default
   ```

   Expected:

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/default/nginx was blocked due to the following policies

   require-team-label:
     check-team-label: 'validation error: The label ''team'' is required on every Pod.
       rule check-team-label failed at path /metadata/labels/team/'
   ```

5. Confirm the namespaced Policy cannot reach outside its namespace:

   ```bash
   kubectl get pol -A
   ```

   Expected:

   ```
   NAMESPACE   NAME                  BACKGROUND   VALIDATE ACTION   READY   AGE
   payments    require-cost-center   true         Audit             True    30s
   ```

**Comprehension**

- **Q6.** In step 2 the policy is `Enforce`; in step 3 it is `Audit`. When a resource violates each, what is the difference in observable behaviour at `kubectl apply` time?
- **Q7.** A Pod is created in `default`. Does `require-cost-center` (a `Policy` in `payments`) evaluate it? Justify from the CRD scope, not from the `match` block.
- **Q8.** The `spec.background` field is `true`. What does that flag switch on, and which CRD group is the *output* of that background activity?

---

## Exercise 3 — The result CRDs: PolicyReport, ClusterPolicyReport, and the intermediate reports

Kyverno never mutates your policy object to store results. Every evaluation outcome lands in a **report** CRD. There are two *layers*: the internal `reports.kyverno.io` CRDs (raw per-resource results, an implementation detail) and the aggregated, user-facing `wgpolicyk8s.io` CRDs.

**Steps**

1. Create a Pod that *passes* the cluster policy but *fails* the namespaced audit policy:

   ```bash
   kubectl -n payments run app --image=nginx \
     --labels=team=core          # satisfies require-team-label, but no cost-center
   ```

2. Read the aggregated namespaced report:

   ```bash
   kubectl -n payments get policyreport
   kubectl -n payments get polr -o wide
   ```

   Expected:

   ```
   NAME                          KIND   NAME   PASS   FAIL   WARN   ERROR   SKIP   AGE
   <hash>                        Pod    app    1      1      0      0      0      20s
   ```

3. Drill into a single result entry:

   ```bash
   kubectl -n payments get polr -o jsonpath='{.items[0].results[?(@.result=="fail")].message}{"\n"}'
   ```

   Expected:

   ```
   Pods in payments must carry a cost-center label.
   ```

4. Look at the cluster-scoped aggregate for cluster-scoped resources:

   ```bash
   kubectl get clusterpolicyreport
   kubectl get cpolr
   ```

5. Reveal the *intermediate* CRDs that the reports-controller consumes and rolls up:

   ```bash
   kubectl -n payments get admissionreports,backgroundscanreports
   kubectl get clusteradmissionreports,clusterbackgroundscanreports
   ```

   Expected (namespaced):

   ```
   NAME                                        GVR         REF    AGGREGATE   READY
   admissionreport.reports.kyverno.io/<uid>    v1/pods     app                true
   NAME                                             KIND   SUBJECT   PASS   FAIL   AGE
   backgroundscanreport.reports.kyverno.io/<uid>    Pod    app       1      1      20s
   ```

**Comprehension**

- **Q9.** A student claims "results are stored inside the ClusterPolicy `status`." Correct them: name the two CRD *groups* that actually hold results and state which one you should query for a stable, documented API.
- **Q10.** What is the difference in *trigger* between an `AdmissionReport` and a `BackgroundScanReport`? Tie each to a specific event.
- **Q11.** You deleted the Pod `app`. What happens to its entry in the `PolicyReport`, and what mechanism (hint: a metadata field on the report) keeps the report in sync with live resources?

---

## Exercise 4 — `PolicyException`: scoped opt-outs as first-class objects

Rather than editing a policy to carve out an exception, Kyverno models the exception itself as a CRD (`PolicyException`, `polex`). This keeps the policy immutable and the exception auditable.

**Steps**

1. Confirm exceptions are enabled (default in current charts; older releases required flags):

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i exception
   ```

   Expected (may be empty on defaults, or):

   ```
   "--enablePolicyException=true"
   ```

2. Create a namespace that must be exempt from the team-label rule:

   ```bash
   kubectl create namespace sandbox
   ```

3. Declare the exception. Note it targets the policy **and** the specific rule name, including the auto-generated pod-controller variants:

   ```yaml
   # sandbox-exception.yaml
   apiVersion: kyverno.io/v2beta1
   kind: PolicyException
   metadata:
     name: exempt-sandbox-team-label
     namespace: sandbox
   spec:
     exceptions:
       - policyName: require-team-label
         ruleNames:
           - check-team-label
           - autogen-check-team-label      # Deployments/ReplicaSets/etc.
     match:
       any:
         - resources:
             kinds:
               - Pod
             namespaces:
               - sandbox
   ```

   ```bash
   kubectl apply -f sandbox-exception.yaml
   ```

4. Prove the previously-blocked action now succeeds *only* in `sandbox`:

   ```bash
   kubectl -n sandbox run nginx --image=nginx      # no team label — succeeds
   kubectl -n default run nginx --image=nginx      # still blocked
   ```

   Expected:

   ```
   pod/nginx created
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: ...
   ```

**Comprehension**

- **Q12.** Why must the `PolicyException` list `autogen-check-team-label` in addition to `check-team-label`? What Kyverno feature generates that second rule name?
- **Q13.** A `PolicyException` is a Namespaced CRD. What is the security significance of that scope in a multi-tenant cluster, and how would a platform team prevent tenants from writing their own exceptions?
- **Q14.** After the exception is applied, does the exempted Pod appear as `pass`, `fail`, or `skip` in the `PolicyReport`? What is the intended semantics of that result value?

---

## Exercise 5 — `UpdateRequest`: the async engine behind `generate` and `mutateExisting`

When a rule *generates* a resource or mutates existing resources, admission cannot do the work synchronously (it may span many objects). Kyverno instead enqueues an internal `UpdateRequest` (`ur`) that the **background-controller** reconciles.

**Steps**

1. Grant the background controller permission to create the target kind (generate targets often need explicit RBAC via an aggregated ClusterRole):

   ```yaml
   # bg-networkpolicy-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:generate-networkpolicies
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
     - apiGroups: ["networking.k8s.io"]
       resources: ["networkpolicies"]
       verbs: ["create", "update", "delete", "get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f bg-networkpolicy-rbac.yaml
   ```

2. Apply a `generate` policy that provisions a default-deny NetworkPolicy into every namespace and keeps it synced:

   ```yaml
   # generate-default-deny.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-deny
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
           namespace: "{{request.object.metadata.name}}"
           synchronize: true
           data:
             spec:
               podSelector: {}
               policyTypes:
                 - Ingress
                 - Egress
   ```

   ```bash
   kubectl apply -f generate-default-deny.yaml
   kubectl create namespace tenant-a
   ```

3. Observe the `UpdateRequest` created to carry out the generation, then the generated object:

   ```bash
   kubectl -n kyverno get updaterequests
   kubectl -n tenant-a get networkpolicy default-deny
   ```

   Expected:

   ```
   NAME       POLICY             RULETYPE   RESOURCEKIND   RESOURCENAME   RESOURCENAMESPACE   STATUS
   ur-abc12   add-default-deny   generate   Namespace      tenant-a                           Completed
   ```
   ```
   NAME           POD-SELECTOR   AGE
   default-deny   <none>         6s
   ```

4. Test `synchronize: true` — delete the generated resource and watch Kyverno recreate it via a new `UpdateRequest`:

   ```bash
   kubectl -n tenant-a delete networkpolicy default-deny
   sleep 5
   kubectl -n tenant-a get networkpolicy default-deny   # back again
   ```

**Comprehension**

- **Q15.** Why does `generate` use an `UpdateRequest` CRD instead of doing the work inside the admission webhook response? Give the architectural reason.
- **Q16.** The `UpdateRequest` lives in the **kyverno** namespace, not the target namespace. What does that tell you about which controller owns and reconciles it?
- **Q17.** With `synchronize: true`, what two distinct classes of drift does the background controller reconcile away, and what would `synchronize: false` change?

---

## Exercise 6 — `CleanupPolicy` / `ClusterCleanupPolicy`: TTL as a scheduled CRD

Cleanup policies delete resources on a cron schedule when conditions match — implemented by the **cleanup-controller** and modeled as its own CRD pair.

**Steps**

1. Grant the cleanup controller delete rights on the target kind (aggregated role, mirroring Exercise 5):

   ```yaml
   # cleanup-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:cleanup-completed-jobs
     labels:
       rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
   rules:
     - apiGroups: ["batch"]
       resources: ["jobs"]
       verbs: ["get", "list", "watch", "delete"]
   ```

   ```bash
   kubectl apply -f cleanup-rbac.yaml
   ```

2. Create a `ClusterCleanupPolicy` that removes completed Jobs every 5 minutes:

   ```yaml
   # cleanup-completed-jobs.yaml
   apiVersion: kyverno.io/v2beta1
   kind: ClusterCleanupPolicy
   metadata:
     name: cleanup-completed-jobs
   spec:
     match:
       any:
         - resources:
             kinds:
               - Job
     conditions:
       all:
         - key: "{{ target.status.succeeded || `0` }}"
           operator: GreaterThanOrEquals
           value: 1
     schedule: "*/5 * * * *"
   ```

   ```bash
   kubectl apply -f cleanup-completed-jobs.yaml
   ```

3. Validate and inspect:

   ```bash
   kubectl get ccleanpol
   kubectl describe ccleanpol cleanup-completed-jobs | sed -n '/Events/,$p'
   ```

   Expected:

   ```
   NAME                     SCHEDULE      AGE
   cleanup-completed-jobs   */5 * * * *   12s
   ```

**Comprehension**

- **Q18.** A `CleanupPolicy` has no `rules:` block, unlike `ClusterPolicy`. Which two fields replace the validate/mutate/generate machinery, and what does each contribute?
- **Q19.** In the condition, the variable is `target.*`, not `request.object.*`. Why is `target` the correct context for a cleanup policy?
- **Q20.** The cleanup controller is a *separate* Deployment with a *separate* aggregated RBAC label. What failure would you see if you forgot the ClusterRole in step 1, and where would it surface?

---

## Exercise 7 — Inspect the CRD contract itself (versions, conversion, printer columns)

The exam expects you to read a CRD as a Kubernetes object, not only to apply CRs.

**Steps**

1. Dump the served/storage versions and the conversion strategy of the policy CRD:

   ```bash
   kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.spec.conversion.strategy}{"\n"}'
   ```

   Expected:

   ```
   Webhook
   ```

2. See the additional printer columns that make `kubectl get cpol` human-readable:

   ```bash
   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{range .spec.versions[?(@.storage==true)].additionalPrinterColumns[*]}{.name}{"\t"}{.jsonPath}{"\n"}{end}'
   ```

   Expected (abridged):

   ```
   Admission    .spec.admission
   Background   .spec.background
   Ready        .status.conditions[?(@.type=="Ready")].status
   Age          .metadata.creationTimestamp
   ```

3. Read one field's documentation straight from the OpenAPI schema baked into the CRD:

   ```bash
   kubectl explain clusterpolicy.spec.validationFailureAction
   ```

   Expected:

   ```
   FIELD: validationFailureAction <string>
   DESCRIPTION:
       ValidationFailureAction defines if a validation policy rule violation
       should block the admission review request (Enforce) or allow (Audit) the
       admission review request and report an error in a policy report...
   ```

4. Cross-check that a manifest written against an *older* served version is transparently converted to storage:

   ```bash
   kubectl get cpol require-team-label -o jsonpath='{.apiVersion}{"\n"}'
   ```

   Expected:

   ```
   kyverno.io/v2
   ```

**Comprehension**

- **Q21.** The CRD's `conversion.strategy` is `Webhook`. What does that mean for a cluster that has `ClusterPolicy` objects stored at `v1` when the operator bumps the storage version to `v2`? Which component performs the translation?
- **Q22.** `kubectl explain` returned real field documentation. Where does that text physically live, and why does it work even offline against the API server?

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

**Q1.** `policyreports` and `clusterpolicyreports` belong to the **`wgpolicyk8s.io/v1alpha2`** group — the Kubernetes **Policy WG (Working Group) Policy Report** API, a *vendor-neutral* standard. Kyverno adopted it deliberately so that any consumer (Policy Reporter UI, Falco, kube-bench, Trivy, etc.) can read a single, common report format regardless of which engine produced it. `kyverno.io`-group CRDs are Kyverno-specific; the report schema is intentionally not.

**Q2.** The **reports-controller** authors/reconciles the internal `reports.kyverno.io` CRDs (AdmissionReport, BackgroundScanReport and their cluster variants) and *aggregates* them into the user-facing **`wgpolicyk8s.io`** `PolicyReport`/`ClusterPolicyReport`. So the reports-controller both consumes the intermediate CRDs and produces the wg-standard ones.

**Q3.** The only differing field is the CRD's **`spec.scope`** (`Namespaced` for `Policy`, `Cluster` for `ClusterPolicy`). Choosing `Policy` guarantees the object — and thus its enforcement authority — is confined to its own namespace: a namespace tenant with RBAC only in their namespace can create/read/delete their `Policy` objects but cannot author cluster-wide rules.

**Q4.** `kubectl get` returns **`kyverno.io/v2`** — the *storage* version — because the API server persists every object at the storage version and serves it back converted. Your `v1` request is valid because `v1` is still a **served** version; the API server converts your `v1` submission to `v2` for storage (via the conversion webhook) and back to whatever version you request on read.

**Q5.** `ClusterPolicy → cpol`; `PolicyReport → polr`; `PolicyException → polex`; `UpdateRequest → ur`.

**Q6.** `Enforce` makes the admission webhook **reject** the request — `kubectl apply` fails with a `denied the request` error, and the object is never created. `Audit` **allows** the object to be created and instead records a `fail` result in a `PolicyReport`; the user sees success at apply time.

**Q7.** No. `require-cost-center` is a **`Policy`** (Namespaced CRD) in `payments`; a namespaced policy can only evaluate resources in its *own* namespace. A Pod in `default` is out of scope regardless of what the `match` block says — scope is enforced by the CRD/engine boundary before `match` is even considered.

**Q8.** `background: true` enables **background scanning**: Kyverno periodically re-evaluates *already-existing* resources against the policy (not just at admission time), so policies added after resources exist still get results. Its output is the report layer — the internal `reports.kyverno.io` `BackgroundScanReport` objects, aggregated into `wgpolicyk8s.io` `PolicyReport`/`ClusterPolicyReport`.

**Q9.** Results are **not** in the policy's `status`. They live in (a) the internal **`reports.kyverno.io`** group (AdmissionReport/BackgroundScanReport, an implementation detail) and (b) the aggregated, standardized **`wgpolicyk8s.io`** group (PolicyReport/ClusterPolicyReport). Query the **`wgpolicyk8s.io`** `polr`/`cpolr` for a stable, documented API.

**Q10.** An **AdmissionReport** is produced by an *admission event* — a real create/update request passing through the webhook. A **BackgroundScanReport** is produced by the *background scan* — a periodic re-evaluation of existing resources with no user request involved.

**Q11.** The entry is **removed**: reports are kept in sync with live resources. Each report carries **`ownerReferences`** pointing at the underlying resource (and per-result resource identifiers); when the Pod is deleted, Kubernetes garbage-collects/reconciles the owned report entry so stale results don't linger.

**Q12.** Kyverno **auto-generates** rule variants for Pod controllers (Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet…) by prefixing the original rule name with `autogen-` (and `autogen-cronjob-` for CronJobs). A single Pod-matching rule therefore also runs against the Pod template inside controllers, so an exception must name those generated rules too, or the controller path stays enforced.

**Q13.** Because `PolicyException` is Namespaced, whoever can `create` it in a namespace can weaken policy **for that namespace** — a privilege-escalation vector in multi-tenancy. A platform team prevents tenant-authored exceptions by (a) RBAC that denies tenants `create` on `policyexceptions`, and/or (b) restricting exceptions to a controlled namespace via the controller flag (e.g. `--exceptionNamespace=<trusted-ns>`) so only exceptions in that namespace are honored.

**Q14.** The exempted resource is reported as **`skip`**. `skip` means the rule *matched selection but was intentionally not evaluated* (here, because a `PolicyException` applied) — distinct from `pass` (evaluated and satisfied) and `fail` (evaluated and violated).

**Q15.** Generation can fan out across many resources/namespaces and must be **retried and reconciled over time**; the admission webhook must return within its timeout and only governs the single request in flight. Modeling the work as an `UpdateRequest` CRD hands it to an asynchronous, level-triggered controller (the background-controller) that can retry, track status, and keep targets in sync — none of which fits a synchronous webhook response.

**Q16.** It tells you the **background-controller** (running in the kyverno namespace) owns and reconciles `UpdateRequest`s. They are internal work items of that controller, not tenant-facing objects, so they live centrally in the install namespace rather than scattered across target namespaces.

**Q17.** With `synchronize: true` the controller reconciles away (1) **deletion/mutation of the generated target** (delete the NetworkPolicy → it's recreated; edit it → reverted to the policy's data) and (2) **drift from changes to the source policy** (edit the `generate.data` → all generated copies are updated). `synchronize: false` makes generation **fire-and-forget**: the target is created once and thereafter never re-synced or restored.

**Q18.** `CleanupPolicy` replaces `rules:` with **`schedule:`** (a cron expression defining *when* the controller evaluates) and **`conditions:`** (a JMESPath/CEL predicate over the candidate resource defining *which* matched objects get deleted). Together with `match:`, they select targets and time the deletion.

**Q19.** A cleanup policy acts on **existing** resources it is examining for deletion, not on an incoming admission request — there is no `request.object`. `target` is the context Kyverno binds to each candidate resource under evaluation, so conditions must read from `target.*` (e.g. `target.status.succeeded`).

**Q20.** Deletion would **fail with a forbidden/RBAC error**: the cleanup-controller's ServiceAccount lacks `delete` on the target kind. It surfaces in the **cleanup-controller pod logs** and typically as **Warning Events** on the `ClusterCleanupPolicy` object (visible via `kubectl describe ccleanpol`). The controller has its own aggregation label (`rbac.kyverno.io/aggregate-to-cleanup-controller`) distinct from the background controller's.

**Q21.** Objects stored at `v1` are **read as-is and converted on demand** by the **conversion webhook** (Kyverno's own service, since `strategy: Webhook`). Bumping the storage version to `v2` does not rewrite existing objects immediately; each is converted to `v2` the next time it is written (or via a storage-version migration). The conversion webhook translates between served versions in both directions, so clients on `v1` keep working.

**Q22.** The documentation lives in the CRD's **OpenAPI v3 schema** (`spec.versions[].schema.openAPIV3Validation`), embedded in the CRD object stored in the cluster. `kubectl explain` reads it from the **API server's discovery/OpenAPI endpoint**, which is served from that in-cluster schema — no internet access needed, only reachability to the API server.

</details>

---

### Sources (official)

- Kyverno — Introduction & architecture: <https://kyverno.io/docs/introduction/>
- Kyverno — Installation (Helm, controllers): <https://kyverno.io/docs/installation/>
- Kyverno — Writing policies · Validate: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Writing policies · Generate (UpdateRequest, synchronize): <https://kyverno.io/docs/writing-policies/generate/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — Cleanup Policies: <https://kyverno.io/docs/writing-policies/cleanup/>
- Kyverno — Policy Reports (`wgpolicyk8s.io`): <https://kyverno.io/docs/policy-reports/>
- Kubernetes Policy WG — Policy Report API: <https://github.com/kubernetes-sigs/wg-policy-prototypes>
- Kubernetes — CustomResourceDefinition versioning & conversion: <https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/>
- CNCF Kyverno Certified Associate (KCA) curriculum: <https://github.com/cncf/curriculum>