# Topic 2.3 — Policy Engines for Platform Governance — Guided Exercises

> **Domain 2 · Weight 4.0** · Certification: **CNPA** (exam version 2025‑04‑01)
> Source syllabus: [CNCF CNPA Curriculum](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)
>
> **Prerequisites for these labs**
> - A cluster running **Kubernetes ≥ 1.30** (so `ValidatingAdmissionPolicy` is GA). `kind`, `minikube`, or a throwaway cloud cluster are all fine — **do not run these against a shared production cluster**, because you will install cluster‑wide admission webhooks that intercept *every* create/update.
> - `kubectl` configured with `cluster-admin`.
> - `helm` v3 for the engine installs.
>
> Verify the baseline before starting:
> ```bash
> kubectl version -o json | grep -E 'gitVersion'
> ```
> Expected (yours will differ in the patch level):
> ```
>   "gitVersion": "v1.31.2",
>   "gitVersion": "v1.31.2",
> ```
> A `serverVersion` below `v1.30` means Exercise 3 will fail — upgrade or use a newer `kind` node image (`kindest/node:v1.31.2`).

---

## Exercise 1 — Map the admission control chain

A **policy engine** is not magic: it is an ordinary HTTP service that the API server calls through an **admission webhook**. Before you install any engine, you must know *where in the request lifecycle* the decision happens, because that ordering explains every behaviour you will see later (why a mutation is visible to a validation, why validation can never change the object, why a `Deny` is final).

1. Look at the admission plugins the API server compiles in and enables. On a `kind`/`kubeadm` cluster:
   ```bash
   kubectl -n kube-system get pod -l component=kube-apiserver \
     -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep admission
   ```
   Expected (order and exact list vary by distro):
   ```
   "--enable-admission-plugins=NodeRestriction"
   ```
   Note that `MutatingAdmissionWebhook` and `ValidatingAdmissionWebhook` are **enabled by default** and usually do *not* appear in this flag — they are on unless explicitly disabled.

2. List the dynamic webhook configurations currently registered. On a fresh cluster this is nearly empty:
   ```bash
   kubectl get validatingwebhookconfigurations
   kubectl get mutatingwebhookconfigurations
   ```
   Expected on a clean cluster:
   ```
   No resources found
   No resources found
   ```
   Keep this window open. After Exercises 2 and 3 you will re‑run these and watch the engines register themselves here — **that is the seam through which every policy engine plugs into Kubernetes.**

3. Fix the request path in your head. A `kubectl apply` travels:
   ```
   authn → authz → Mutating admission (webhooks + MutatingAdmissionPolicy)
        → object schema validation / defaulting
        → Validating admission (webhooks + ValidatingAdmissionPolicy)
        → persisted to etcd
   ```

**Comprehension questions — Block 1**

1.1 A Kyverno *mutate* rule adds a `team` label, and a Gatekeeper *validate* constraint requires that same label to be present. Given the chain above, can the two coexist so that a Pod with **no** `team` label is admitted? Why?

1.2 You disabled `ValidatingAdmissionWebhook` in the API server flags. What happens to a Gatekeeper `Deny` constraint — does it still block objects? What does this tell you about the **trust boundary** of a policy engine?

1.3 Why can a *validating* webhook never be used to "fix" a non‑compliant object (e.g. inject a missing resource limit), while a *mutating* webhook can?

---

## Exercise 2 — OPA Gatekeeper: ConstraintTemplates and Constraints

Gatekeeper packages **Open Policy Agent** as a Kubernetes admission controller. Policy logic is written in **Rego** and shipped in two layers: a `ConstraintTemplate` (the reusable *rule*, which generates a new CRD) and one or more `Constraint` objects (the *parameters* + *scope* of that rule).

1. Install Gatekeeper with Helm:
   ```bash
   helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
   helm repo update
   helm install gatekeeper gatekeeper/gatekeeper \
     --namespace gatekeeper-system --create-namespace
   ```

2. Wait for the control plane to be ready:
   ```bash
   kubectl -n gatekeeper-system get pods
   ```
   Expected:
   ```
   NAME                                             READY   STATUS    RESTARTS   AGE
   gatekeeper-audit-5b96bd7f4-xr8kq                 1/1     Running   0          65s
   gatekeeper-controller-manager-6f9d6c8b7d-abc12   1/1     Running   0          65s
   gatekeeper-controller-manager-6f9d6c8b7d-def34   1/1     Running   0          65s
   gatekeeper-controller-manager-6f9d6c8b7d-ghi56   1/1     Running   0          65s
   ```

3. Confirm Gatekeeper registered itself as a webhook (compare with Block 1, step 2):
   ```bash
   kubectl get validatingwebhookconfigurations
   ```
   Expected:
   ```
   NAME                                          WEBHOOKS   AGE
   gatekeeper-validating-webhook-configuration   2          70s
   ```

4. Create the **ConstraintTemplate** — a reusable "objects must carry these labels" rule. Save as `template-required-labels.yaml`:
   ```yaml
   apiVersion: templates.gatekeeper.sh/v1
   kind: ConstraintTemplate
   metadata:
     name: k8srequiredlabels
   spec:
     crd:
       spec:
         names:
           kind: K8sRequiredLabels        # this becomes a new CRD kind
         validation:
           openAPIV3Schema:
             type: object
             properties:
               labels:
                 type: array
                 items:
                   type: string
     targets:
       - target: admission.k8s.gatekeeper.sh
         rego: |
           package k8srequiredlabels

           violation[{"msg": msg, "details": {"missing_labels": missing}}] {
             provided := {label | input.review.object.metadata.labels[label]}
             required := {label | label := input.parameters.labels[_]}
             missing := required - provided
             count(missing) > 0
             msg := sprintf("you must provide labels: %v", [missing])
           }
   ```
   ```bash
   kubectl apply -f template-required-labels.yaml
   ```
   Expected:
   ```
   constrainttemplate.templates.gatekeeper.sh/k8srequiredlabels created
   ```

5. Confirm the template minted a **new CRD**:
   ```bash
   kubectl get crd | grep k8srequiredlabels
   ```
   Expected:
   ```
   k8srequiredlabels.constraints.gatekeeper.sh   2026-08-06T12:00:00Z
   ```

6. Create a **Constraint** that instantiates the template — every `Namespace` must carry an `owner` label. Save as `constraint-ns-owner.yaml`:
   ```yaml
   apiVersion: constraints.gatekeeper.sh/v1beta1
   kind: K8sRequiredLabels            # the CRD kind created in step 5
   metadata:
     name: ns-must-have-owner
   spec:
     enforcementAction: deny          # deny | warn | dryrun
     match:
       kinds:
         - apiGroups: [""]
           kinds: ["Namespace"]
     parameters:
       labels: ["owner"]
   ```
   ```bash
   kubectl apply -f constraint-ns-owner.yaml
   ```

7. Test the **deny path**:
   ```bash
   kubectl create ns dev-team
   ```
   Expected:
   ```
   Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [ns-must-have-owner] you must provide labels: {"owner"}
   ```

8. Test the **allow path**:
   ```bash
   kubectl create ns dev-team --dry-run=client -o yaml | \
     kubectl label --local -f - owner=payments -o yaml | kubectl apply -f -
   ```
   Expected:
   ```
   namespace/dev-team created
   ```

9. Inspect **audit** results. Gatekeeper's audit pod re‑evaluates *already‑existing* objects every 60 s and records violations on the constraint's `status`:
   ```bash
   kubectl get k8srequiredlabels ns-must-have-owner \
     -o jsonpath='{.status.totalViolations}{"\n"}'
   kubectl get k8srequiredlabels ns-must-have-owner \
     -o jsonpath='{range .status.violations[*]}{.name}{": "}{.message}{"\n"}{end}'
   ```
   Expected (pre‑existing namespaces such as `default`, `kube-system` lack the label):
   ```
   4
   default: you must provide labels: {"owner"}
   kube-system: you must provide labels: {"owner"}
   kube-public: you must provide labels: {"owner"}
   kube-node-lease: you must provide labels: {"owner"}
   ```

**Comprehension questions — Block 2**

2.1 Why does Gatekeeper split policy into `ConstraintTemplate` *and* `Constraint` instead of one object? Give one concrete governance benefit of that separation.

2.2 In step 9, the `default` namespace already existed and is non‑compliant, yet it was never blocked. Explain, using the difference between the **admission** path and the **audit** path, why enforcement did not delete or block it — and what audit is *for*.

2.3 A teammate sets `spec.enforcementAction: dryrun` on the constraint. Predict what happens on `kubectl create ns test` and where (if anywhere) the violation shows up.

2.4 The Rego uses set difference `required - provided`. If `input.parameters.labels` is `["owner","cost-center"]` and the namespace has only `owner`, what is `missing`, and how many `violation` results are produced?

---

## Exercise 3 — Kyverno: validate and mutate without writing code

Kyverno expresses policy as **Kubernetes‑native YAML** (no Rego). A `ClusterPolicy` bundles rules that `validate`, `mutate`, `generate`, or `verifyImages`. This is the second major approach on the exam: *policy‑as‑configuration* versus Gatekeeper's *policy‑as‑code*.

1. Install Kyverno:
   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace
   ```
   Confirm:
   ```bash
   kubectl -n kyverno get pods
   ```
   Expected:
   ```
   NAME                                             READY   STATUS    RESTARTS   AGE
   kyverno-admission-controller-7d9c8c9f5b-abcde    1/1     Running   0          80s
   kyverno-background-controller-6b7c8d9e0f-fghij   1/1     Running   0          80s
   kyverno-cleanup-controller-5a6b7c8d9e-klmno      1/1     Running   0          80s
   kyverno-reports-controller-4z5y6x7w8v-pqrst      1/1     Running   0          80s
   ```

2. Apply a **validate** policy that blocks the mutable `:latest` tag (and any untagged image). Save as `policy-disallow-latest.yaml`:
   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: disallow-latest-tag
   spec:
     background: true
     rules:
       - name: require-image-tag
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         validate:
           failureAction: Enforce        # Enforce | Audit (per-rule; replaces the
           allowExistingViolations: true # deprecated spec.validationFailureAction)
           message: "An explicit image tag is required."
           pattern:
             spec:
               containers:
                 - image: "*:*"
       - name: forbid-latest-tag
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         validate:
           failureAction: Enforce
           message: "Using the ':latest' tag is not allowed."
           pattern:
             spec:
               containers:
                 - image: "!*:latest"
   ```
   ```bash
   kubectl apply -f policy-disallow-latest.yaml
   ```

3. Trigger the **deny path**:
   ```bash
   kubectl run web --image=nginx:latest
   ```
   Expected:
   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/default/web was blocked due to the following policies

   disallow-latest-tag:
     forbid-latest-tag: 'validation error: Using the '':latest'' tag is not allowed.
       rule forbid-latest-tag failed at path /spec/containers/0/image/'
   ```

4. Trigger the **allow path**:
   ```bash
   kubectl run web --image=nginx:1.27.3
   ```
   Expected:
   ```
   pod/web created
   ```

5. Now a **mutate** policy that injects a default label *only if it is absent* (the `+()` add‑if‑not‑present anchor). Save as `policy-default-team.yaml`:
   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-team-label
   spec:
     rules:
       - name: add-team-unassigned
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 +(team): "unassigned"
   ```
   ```bash
   kubectl apply -f policy-default-team.yaml
   kubectl run mutated --image=nginx:1.27.3
   kubectl get pod mutated -o jsonpath='{.metadata.labels}{"\n"}'
   ```
   Expected:
   ```
   pod/mutated created
   {"run":"mutated","team":"unassigned"}
   ```
   Now prove the anchor is *conditional* — an explicit label is preserved:
   ```bash
   kubectl run keeps --image=nginx:1.27.3 --labels=team=payments
   kubectl get pod keeps -o jsonpath='{.metadata.labels}{"\n"}'
   ```
   Expected:
   ```
   pod/keeps created
   {"run":"keeps","team":"payments"}
   ```

6. Read the governance signal. Kyverno emits **PolicyReport** objects that aggregate pass/fail per namespace — the raw material of a compliance dashboard:
   ```bash
   kubectl get policyreport -A
   ```
   Expected:
   ```
   NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   SKIP   AGE
   default     ...cpol-disallow-latest-tag...         2      0      0      0       0      3m
   ```

**Comprehension questions — Block 3**

3.1 The deny message came from a webhook named `validate.kyverno.svc-fail`, not `...svc-ignore`. Kyverno registers **both**. What does the `-fail` vs `-ignore` suffix correspond to in the webhook configuration, and why does a policy engine deliberately route different rules to each?

3.2 In step 5, `keeps` kept `team=payments`. Which single character in the patch made the mutation conditional, and what would the label have become if you had written `team:` instead of `+(team):`?

3.3 Contrast Gatekeeper (Exercise 2) and Kyverno (this one) on the axis **"who can author a policy"**. For a platform team onboarding application developers who do not know Rego, which model lowers the barrier, and what do you give up?

3.4 You changed both rules to `failureAction: Audit`. A developer deploys `nginx:latest`. Does the Pod get created? Where do you go to find out it was non‑compliant?

---

## Exercise 4 — Native ValidatingAdmissionPolicy (CEL, no add‑on)

Since Kubernetes **1.30**, the API server can enforce policy **in‑process** using **CEL** (Common Expression Language) — no external webhook, no add‑on pod, no network hop. This is the third pillar of the topic and the one growing fastest: `ValidatingAdmissionPolicy` (VAP). Understand *when* it replaces an engine and when it does not.

1. Confirm the feature is available (GA ⇒ on by default on ≥ 1.30):
   ```bash
   kubectl api-resources | grep -i validatingadmissionpolicy
   ```
   Expected:
   ```
   validatingadmissionpolicies         admissionregistration.k8s.io/v1   false   ValidatingAdmissionPolicy
   validatingadmissionpolicybindings   admissionregistration.k8s.io/v1   false   ValidatingAdmissionPolicyBinding
   ```

2. Create the **policy** — cap Deployment replicas at 5. Save as `vap-replica-limit.yaml`:
   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: deployment-replica-limit
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups:   ["apps"]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["deployments"]
     validations:
       - expression: "object.spec.replicas <= 5"
         messageExpression: >-
           'Deployment ' + object.metadata.name + ' requests ' +
           string(object.spec.replicas) + ' replicas; the platform limit is 5.'
   ```

3. Create the **binding** — a policy does nothing until a `ValidatingAdmissionPolicyBinding` scopes it and sets the action. Save as `vap-binding.yaml`:
   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: deployment-replica-limit-binding
   spec:
     policyName: deployment-replica-limit
     validationActions: ["Deny"]        # Deny | Warn | Audit (combinable)
     matchResources:
       namespaceSelector:
         matchLabels:
           environment: test
   ```
   ```bash
   kubectl apply -f vap-replica-limit.yaml -f vap-binding.yaml
   ```

4. Create a target namespace **in scope** and test the deny path:
   ```bash
   kubectl create ns app-test
   kubectl label ns app-test environment=test
   kubectl -n app-test create deployment big --image=nginx:1.27.3 --replicas=10
   ```
   Expected:
   ```
   error: failed to create deployment: deployments.apps "big" is forbidden:
   ValidatingAdmissionPolicy 'deployment-replica-limit' with binding
   'deployment-replica-limit-binding' denied request: Deployment big requests
   10 replicas; the platform limit is 5.
   ```

5. Test the allow path, and prove the binding's **scope** — an out‑of‑scope namespace is untouched:
   ```bash
   kubectl -n app-test create deployment small --image=nginx:1.27.3 --replicas=3
   kubectl create ns app-prod                        # no environment=test label
   kubectl -n app-prod create deployment huge --image=nginx:1.27.3 --replicas=20
   ```
   Expected:
   ```
   deployment.apps/small created
   deployment.apps/huge created
   ```

**Comprehension questions — Block 4**

4.1 The 20‑replica Deployment in `app-prod` was admitted. Name the exact field in the *binding* (not the policy) that let it through, and state the design principle this "policy vs binding" split is an instance of.

4.2 Give two concrete advantages of a native VAP over an external webhook engine, and two capabilities you *lose* by choosing VAP over Kyverno/Gatekeeper (hint: think mutate/generate, and cross‑object lookups).

4.3 The policy sets `failurePolicy: Fail`. A CEL expression references `object.spec.replicas`, but someone submits a Deployment where `spec.replicas` is unset (omitted). Reason about what `object.spec.replicas` evaluates to and whether the request is denied — and how you would make the rule robust to the omitted field.

4.4 `validationActions` is a list, and you set it to `["Deny"]`. What is the operational purpose of being able to set `["Deny","Audit"]` together, and how does `["Warn"]` alone change the developer's experience versus `["Deny"]`?

---

## Exercise 5 — Governance at scale: rollout, exemptions, and precedence

Real platform governance is never "deny everything on day one." You stage enforcement, carve out the system namespaces you must not break, and reason about how *several* engines interact on one object.

1. **Stage the rollout.** Flip the Gatekeeper constraint from Exercise 2 into observe‑only mode, then read the same audit surface you'd wire to a dashboard:
   ```bash
   kubectl patch k8srequiredlabels ns-must-have-owner \
     --type=merge -p '{"spec":{"enforcementAction":"dryrun"}}'
   kubectl create ns quick-test          # previously blocked
   ```
   Expected:
   ```
   namespace/quick-test created
   ```
   The violation is now *recorded, not enforced*:
   ```bash
   kubectl get k8srequiredlabels ns-must-have-owner \
     -o jsonpath='{.status.totalViolations}{"\n"}'
   ```
   Expected (count rises; nothing was blocked):
   ```
   5
   ```

2. **Protect the control plane from your own policy.** Exclude system namespaces so a strict rule can never wedge the cluster. For Kyverno, exclude at the rule level:
   ```yaml
   # add under a rule's match/exclude in policy-disallow-latest.yaml
       exclude:
         any:
           - resources:
               namespaces: ["kube-system", "kyverno", "gatekeeper-system"]
   ```
   For Gatekeeper, the cluster‑scoped exemption is centralized in the `Config` resource:
   ```yaml
   apiVersion: config.gatekeeper.sh/v1alpha1
   kind: Config
   metadata:
     name: config
     namespace: gatekeeper-system
   spec:
     match:
       - excludedNamespaces: ["kube-system", "gatekeeper-system"]
         processes: ["*"]
   ```
   ```bash
   kubectl apply -f gatekeeper-config.yaml
   ```

3. **Reason about precedence.** With Kyverno *and* Gatekeeper *and* a native VAP all installed, submit one object and predict the order of effects:
   ```bash
   kubectl -n app-test create deployment demo --image=nginx:latest --replicas=9
   ```
   Trace it against the chain from Exercise 1 (mutation → schema → validation) before you read the answer.

**Comprehension questions — Block 5**

5.1 Why is excluding `kube-system` from a "no `:latest`, must‑have‑labels" policy a *safety* requirement and not just convenience? Describe one concrete failure mode of a strict, un‑exempted policy at cluster bootstrap.

5.2 For the object in step 3: list the sequence of engines/phases that touch it, say which one (if any) admits or rejects it and **why the others never get to decide**, given `nginx:latest` + 9 replicas in a namespace labelled `environment=test`.

5.3 You have Kyverno mutate rules *and* a native `MutatingAdmissionPolicy` both adding labels. Kubernetes does not guarantee a fixed ordering *between* mutating webhooks. What is the practical governance risk of two mutators writing the same field, and what property must each mutation therefore have?

5.4 A auditor asks: "Prove that no workload in `prod` runs `:latest`." Which of the three engines gives you that evidence *for objects that already exist* (not just newly admitted ones), and which specific resource or command do you hand the auditor?

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — the admission chain

**1.1** Yes, they can coexist, and the Pod is admitted. Mutation runs *before* validation in the chain, so Kyverno injects the `team` label first; by the time the Gatekeeper validating constraint evaluates the object, the label is already present. This ordering is the whole reason "mutate a sane default, then validate the invariant" is a standard governance pattern — the validator sees the *post‑mutation* object, never the original.

**1.2** The Gatekeeper `Deny` stops working entirely — objects are admitted regardless of the constraint. A policy engine that plugs in via `ValidatingAdmissionWebhook` is only as strong as that admission plugin being enabled. The trust boundary is the **API server configuration**: anyone who can edit the API server flags (or delete the `ValidatingWebhookConfiguration`) can silently disable all policy. Governance therefore also depends on RBAC over `admissionregistration.k8s.io` objects and over the API server manifest, not just on the policies themselves.

**1.3** By the time the *validating* phase runs, defaulting and schema validation are done and the object is about to be persisted; validating admission is allowed only to return allow/deny (it cannot patch). *Mutating* admission runs earlier and returns a JSON patch that the API server applies to the object before it continues down the chain. So "fixing" (injecting a default limit) is structurally a mutation‑phase capability; validation can only *reject* what is already wrong.

### Block 2 — Gatekeeper

**2.1** The `ConstraintTemplate` is the *rule authored once* (Rego + a schema), and it generates a CRD; each `Constraint` is a *parameterised, scoped instance* of that rule authored by whoever owns a given policy. Concrete benefit: a platform team writes and reviews the Rego once (hard, security‑sensitive), and many teams then declare simple `Constraint` objects (`labels: ["owner"]`, `labels: ["cost-center"]`, different `match` scopes) **without touching or re‑reviewing Rego** — separation of the dangerous logic from its safe reuse.

**2.2** *Admission* only evaluates objects at the moment they are created or updated; `default` was created long before the constraint existed, so admission never saw it. *Audit* is a periodic background sweep (default every 60 s) that re‑evaluates objects *already in etcd* and records violations on the constraint's `status`. Audit deliberately does **not** delete or block — mass‑deleting pre‑existing non‑compliant objects would be catastrophic. Its purpose is *visibility*: telling you the size and location of your existing debt so you can remediate deliberately.

**2.3** With `dryrun`, `kubectl create ns test` **succeeds** — nothing is blocked. The violation is still evaluated and surfaces in the constraint's `status.violations` / `totalViolations` (and in Gatekeeper metrics/logs). `dryrun` is the canonical way to measure blast radius before flipping a constraint to `deny`.

**2.4** `missing = {"cost-center"}` (set difference: required `{"owner","cost-center"}` minus provided `{"owner"}`). `count(missing) = 1 > 0`, so exactly **one** `violation` result is produced, with the message `you must provide labels: {"cost-center"}`.

### Block 3 — Kyverno

**3.1** The suffix maps to the webhook's `failurePolicy`. `...svc-fail` = `failurePolicy: Fail` (if the Kyverno webhook is unreachable, the request is **rejected** — fail‑closed); `...svc-ignore` = `failurePolicy: Ignore` (request is allowed through if the webhook can't be reached — fail‑open). Kyverno routes rules that must always hold to the fail‑closed webhook and less‑critical ones to fail‑open, so a Kyverno outage doesn't freeze the entire cluster while still guaranteeing the hard invariants.

**3.2** The `+` in `+(team)` — the **add‑if‑not‑present anchor**. It applies the value only when the key is absent. Written as a plain `team: "unassigned"` (strategic‑merge default), it would have **overwritten** the existing value, so `keeps` would have become `team: unassigned`, silently destroying the developer's `payments` value.

**3.3** Kyverno lowers the barrier: policies are plain Kubernetes YAML with `pattern`/`match`, so a developer who knows manifests can read and even write them; Gatekeeper requires Rego, a separate language. What you give up with the YAML‑pattern model is expressive power for complex logic — arbitrary set math, joins across parameters, and rich conditionals are natural in Rego but awkward or impossible in pattern matching (Kyverno's escape hatch for that is CEL/JMESPath `deny` rules, which reintroduce a learning curve).

**3.4** With `failureAction: Audit`, the Pod **is created** — audit never blocks admission. You find the non‑compliance in the **PolicyReport** objects (`kubectl get policyreport -A`, and the per‑resource report shows `FAIL` for `disallow-latest-tag`) and in Kyverno's events/metrics. Audit is the "report but don't enforce" stage of a rollout.

### Block 4 — ValidatingAdmissionPolicy

**4.1** `spec.matchResources.namespaceSelector.matchLabels: {environment: test}` in the **binding**. `app-prod` lacked the `environment=test` label, so the binding didn't select it and the policy never ran there. The principle is **separation of policy definition from policy scope/action** (the same author‑once/scope‑many idea as Gatekeeper's template/constraint): one immutable, reviewed policy; many bindings that decide *where* and *how hard* it applies.

**4.2** *Gains*: (a) no external webhook — the check runs in‑process in the API server, so there's no extra pod to run/scale/secure and no network hop or TLS cert to manage; (b) it cannot cause a cluster‑wide outage from an unreachable webhook, and it's lower latency. *Losses*: (a) VAP is **validate‑only** — it cannot mutate/inject defaults or `generate` companion objects the way Kyverno/Gatekeeper‑mutation can; (b) it evaluates essentially the single incoming object via CEL and has **no general cross‑object lookups** (you can't, in plain VAP, say "deny unless a matching NetworkPolicy exists"), whereas Gatekeeper can sync and reference other cluster state.

**4.3** If `spec.replicas` is omitted at admission time, `object.spec.replicas` is not yet defaulted for the CEL evaluation and referencing it can make the expression error; with `failurePolicy: Fail` a *runtime error in the expression* is treated as a failure and the request is **denied** — a strict but blunt outcome. Make it robust by guarding for presence, e.g. `!has(object.spec.replicas) || object.spec.replicas <= 5`, so an omitted field (which Kubernetes will default to 1) is not treated as a violation.

**4.4** `["Deny","Audit"]` both blocks the offending request *and* records it to the audit annotation/log, so you enforce **and** keep a compliance trail in one place. `["Warn"]` alone does not block: the object is admitted and the developer sees a `Warning:` line on their `kubectl` output — ideal for a soft‑launch where you want to nudge behaviour without breaking pipelines, versus `["Deny"]` which hard‑fails the request.

### Block 5 — governance at scale

**5.1** System namespaces host the components that make the cluster work (CNI, CoreDNS, kube‑proxy, the CSI drivers, and the policy engine itself). A strict rule with no exemption can deadlock bootstrap: e.g. a "must have `owner` label / no `:latest`" rule applied to `kube-system` can block a system DaemonSet from being (re)created, and — worst case — a Gatekeeper/Kyverno policy that blocks its *own* namespace can prevent its controllers from restarting, leaving you unable to fix the policy. Excluding system namespaces is a safety invariant, not convenience.

**5.2** Order for `nginx:latest` + 9 replicas in `environment=test`: (1) **Mutating** phase — Kyverno's `add-default-team-label` injects `team: unassigned`; (2) schema validation/defaulting; (3) **Validating** phase, where three checks apply to the *mutated* object — Kyverno's `disallow-latest-tag` (fails on `:latest`), Gatekeeper (its constraint targets Namespaces, so it's a no‑op here), and the native VAP `deployment-replica-limit` (fails on 9 > 5). The request is **rejected**. Any one failing validator is sufficient to deny; the API server returns the failures, and the object is never persisted, so "which validator wins" is moot — validation is an AND of all of them, and it takes only one `Deny`.

**5.3** If two mutators write the same field with no guaranteed ordering, the final value is non‑deterministic — a race that produces inconsistent results across otherwise identical requests, and Kubernetes may re‑invoke mutators (reinvocation) which can flip the result again. Each mutation must therefore be **idempotent** and, ideally, conditional (add‑if‑absent / converge to the same value) so that order and repetition don't change the outcome. Never have two mutators unconditionally set the same key to different values.

**5.4** You need evidence about **existing** objects, which is the *audit* surface, not the admission surface. Two engines qualify: **Kyverno** via `PolicyReport`/`ClusterPolicyReport` (`kubectl get policyreport -n prod -o yaml`, showing per‑resource `PASS/FAIL` for the `disallow-latest-tag` policy), and **Gatekeeper** via a constraint's `status.violations`. A native VAP with `validationActions: ["Audit"]` only annotates/logs *requests* it saw, so it does not, by itself, retroactively certify pre‑existing workloads. Hand the auditor the Kyverno `ClusterPolicyReport` (or `kubectl get cpolr,polr -A`) filtered to `prod`.

</details>

---

### Cited official sources

- Kubernetes — **Admission Controllers Reference**: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — **Dynamic Admission Control** (webhook ordering, `failurePolicy`, reinvocation): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — **Validating Admission Policy** (CEL, policy/binding, `validationActions`): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — **CEL in Kubernetes**: https://kubernetes.io/docs/reference/using-api/cel/
- OPA Gatekeeper — **How to use / ConstraintTemplates, Constraints, audit, enforcementAction**: https://open-policy-agent.github.io/gatekeeper/website/docs/
- OPA Gatekeeper — **Exempting namespaces (Config)**: https://open-policy-agent.github.io/gatekeeper/website/docs/exempt-namespaces
- Open Policy Agent — **Rego language**: https://www.openpolicyagent.org/docs/latest/policy-language/
- Kyverno — **Documentation home**: https://kyverno.io/docs/
- Kyverno — **Validate rules & `failureAction`**: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — **Mutate rules & anchors** (`+()` add‑if‑absent): https://kyverno.io/docs/writing-policies/mutate/
- Kyverno — **Policy Reports**: https://kyverno.io/docs/policy-reports/

---

One practical note, outside the material: this environment gave me no file‑write access, so I could not save the above to `certs/cnpa/2.3/en/exercises.md` (the untracked directory in your working tree). If you want it committed through the normal pipeline, run it via `make generate CERT=cnpa TOPIC=2.3 LANG=en` — or paste this into that file and run the audit/status steps per `WORKFLOW.md`.