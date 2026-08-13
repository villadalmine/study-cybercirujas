# Topic 1.3 — Admission Controllers · Guided Exercises

> **Where this sits in the request path.** Every write to the Kubernetes API travels: **Authentication → Authorization → Mutating admission → Object schema validation → Validating admission → persist to etcd**. Admission controllers are the *last* gate before an object is stored, and the *only* gate that can both **reject** a request and **change the object** on its way through. They run in two phases: mutating controllers/webhooks first (they may rewrite the object), then — after the mutated object is re-validated against the OpenAPI schema — validating controllers/webhooks (they may only accept or reject). Reads (`GET`, `LIST`, `WATCH`) never pass through admission.
>
> **Reference:** <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>

**Prerequisites**

- A cluster you administer, **v1.30 or newer** (`ValidatingAdmissionPolicy` is GA from 1.30). `kind create cluster` or `minikube start` is ideal — you get a real static-pod `kube-apiserver`.
- `kubectl` configured with `cluster-admin`.
- The examples assume a `kind` cluster named `kind` (control-plane container `kind-control-plane`). Adjust node/container names for your environment.

---

## Exercise 1 — Map the admission chain on a live cluster

**Goal:** see which controllers are compiled-in and enabled by default, and how `kubeadm` layers extra ones on top.

1. Confirm the API server runs as a static pod and find its name:

   ```bash
   kubectl -n kube-system get pod -l component=kube-apiserver
   ```

   ```
   NAME                                READY   STATUS    RESTARTS   AGE
   kube-apiserver-kind-control-plane   1/1     Running   0          42m
   ```

2. Read the admission flag the cluster was booted with:

   ```bash
   kubectl -n kube-system get pod kube-apiserver-kind-control-plane -o yaml \
     | grep -- '--enable-admission-plugins'
   ```

   ```
     - --enable-admission-plugins=NodeRestriction
   ```

3. That flag only lists what is enabled **in addition** to the defaults. Ask the binary itself for the full default set:

   ```bash
   docker exec kind-control-plane kube-apiserver -h 2>/dev/null \
     | grep -A4 -- '--enable-admission-plugins'
   ```

   ```
       --enable-admission-plugins strings
           admission plugins that should be enabled in addition to default
           enabled ones (CertificateApproval, CertificateSigning,
           CertificateSubjectRestriction, DefaultIngressClass,
           DefaultStorageClass, DefaultTolerationSeconds, LimitRanger,
           MutatingAdmissionWebhook, NamespaceLifecycle,
           PersistentVolumeClaimResize, PodSecurity, Priority, ResourceQuota,
           RuntimeClass, ServiceAccount, StorageObjectInUseProtection,
           TaintNodesByCondition, ValidatingAdmissionPolicy,
           ValidatingAdmissionWebhook, ...).
   ```

4. Notice the two webhook plugins in that list — `MutatingAdmissionWebhook` and `ValidatingAdmissionWebhook`. These are the **dispatchers** for *dynamic* admission: without them, `MutatingWebhookConfiguration` / `ValidatingWebhookConfiguration` objects would be inert.

> **Comprehension check 1**
> 1. `--enable-admission-plugins=NodeRestriction` lists only one plugin, yet `LimitRanger`, `PodSecurity` and `ResourceQuota` are all active. Why?
> 2. The flag documentation says "*The order of plugins in this flag does not matter.*" If the flag order is irrelevant, what actually determines the order in which controllers run — and why does `MutatingAdmissionWebhook` always execute near the **end** of the mutating phase?
> 3. Why does `kubeadm` bother to add `NodeRestriction` explicitly if the built-in defaults are already considered safe?

---

## Exercise 2 — A built-in mutating controller vs. a built-in validating controller

**Goal:** watch `LimitRanger` *rewrite* a Pod (mutation) and `ResourceQuota` *reject* one (validation), and reason about which phase each belongs to.

1. Create a sandbox namespace and a `LimitRange` that injects defaults:

   ```bash
   kubectl create namespace adm-lab
   ```

   ```yaml
   # limitrange.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: defaults
     namespace: adm-lab
   spec:
     limits:
       - type: Container
         default:            # becomes spec.containers[].resources.limits
           cpu: "500m"
           memory: "256Mi"
         defaultRequest:     # becomes spec.containers[].resources.requests
           cpu: "100m"
           memory: "128Mi"
   ```

   ```bash
   kubectl apply -f limitrange.yaml
   ```

2. Create a Pod that specifies **no** resources at all:

   ```bash
   kubectl -n adm-lab run web --image=nginx:1.27 --restart=Never
   ```

3. Inspect what was actually stored — you never wrote these fields:

   ```bash
   kubectl -n adm-lab get pod web \
     -o jsonpath='{.spec.containers[0].resources}{"\n"}'
   ```

   ```
   {"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
   ```

4. Now add a hard cap with `ResourceQuota`:

   ```yaml
   # quota.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tight
     namespace: adm-lab
   spec:
     hard:
       requests.cpu: "150m"     # only 50m left after the running pod's 100m
       requests.memory: "256Mi"
   ```

   ```bash
   kubectl apply -f quota.yaml
   ```

5. Try to schedule a second pod that would breach the CPU request budget:

   ```bash
   kubectl -n adm-lab run web2 --image=nginx:1.27 --restart=Never \
     --requests='cpu=200m'
   ```

   ```
   Error from server (Forbidden): pods "web2" is forbidden: exceeded quota: tight,
   requested: requests.cpu=200m, used: requests.cpu=100m, limited: requests.cpu=150m
   ```

> **Comprehension check 2**
> 1. `LimitRanger` and `ResourceQuota` are both single admission plugins, yet one *changed* the object and one *blocked* it. Which admission phase does each act in, and why can't `ResourceQuota` run **before** `LimitRanger`?
> 2. In step 5 the quota says `used: requests.cpu=100m`. Where did that 100m come from, given the first pod was created **without** any resource requests?
> 3. If you deleted the `LimitRange` and recreated `web`, would the `ResourceQuota` still admit it? Explain the interaction.

---

## Exercise 3 — Pod Security Admission (the built-in replacement for PodSecurityPolicy)

**Goal:** enforce a Pod Security Standard at the namespace boundary using the `PodSecurity` controller, and use its non-blocking modes to migrate safely.

1. Create a namespace and turn on all three PSA modes at the `restricted` level. Pin the **version** so a cluster upgrade can't silently tighten the rules under you:

   ```bash
   kubectl create namespace psa-demo

   kubectl label namespace psa-demo \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.31 \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted
   ```

2. Attempt a deliberately non-compliant (privileged) Pod:

   ```yaml
   # privileged.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: privileged
     namespace: psa-demo
   spec:
     containers:
       - name: app
         image: nginx:1.27
         securityContext:
           privileged: true
   ```

   ```bash
   kubectl apply -f privileged.yaml
   ```

   ```
   Error from server (Forbidden): error when creating "privileged.yaml": pods "privileged" is
   forbidden: violates PodSecurity "restricted:v1.31": privileged (container "app" must not set
   securityContext.privileged=true), allowPrivilegeEscalation != false (container "app" must set
   securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app"
   must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container
   "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must
   set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   ```

3. Fix the Pod so it satisfies `restricted`:

   ```yaml
   # compliant.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: compliant
     namespace: psa-demo
   spec:
     securityContext:
       runAsNonRoot: true
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginx:1.27
         securityContext:
           allowPrivilegeEscalation: false
           capabilities:
             drop: ["ALL"]
   ```

   ```bash
   kubectl apply -f compliant.yaml    # pod/compliant created
   ```

4. Preview the impact of a stricter policy on **existing** workloads *without changing anything*, using a server-side dry-run label evaluation:

   ```bash
   kubectl label --dry-run=server ns kube-system \
     pod-security.kubernetes.io/enforce=restricted
   ```

   ```
   Warning: existing pods in namespace "kube-system" violate the new PodSecurity enforce level
   "restricted:latest": kube-apiserver-... (host namespaces, hostPath volumes, ...)
   namespace/kube-system labeled (server dry run)
   ```

> **Comprehension check 3**
> 1. PSA rejected the pod at admission time. What is the fundamental architectural difference between this and enforcing the same rules with a `ValidatingWebhook` running a policy engine like OPA/Gatekeeper or Kyverno?
> 2. What is the practical migration purpose of running `warn` and `audit` at `restricted` while `enforce` stays at `baseline` (or unset)?
> 3. Why is `enforce-version=v1.31` a production-critical label, and where do the `warn`/`audit` messages actually surface for the two respective modes?

---

## Exercise 4 — In-tree policy with CEL: `ValidatingAdmissionPolicy`

**Goal:** enforce a custom rule **without deploying a webhook server**, using compiled-in CEL evaluation (GA since v1.30). We'll cap Deployment replicas.

1. Define the policy — *what* to check:

   ```yaml
   # vap.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: "replica-limit.example.com"
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
         message: "Deployment replicas must be 5 or fewer."
         reason: Invalid
   ```

2. Define the binding — *where* the policy applies. Scope it to namespaces labelled `team=payments`:

   ```yaml
   # vapb.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: "replica-limit-binding"
   spec:
     policyName: "replica-limit.example.com"
     validationActions: ["Deny"]
     matchResources:
       namespaceSelector:
         matchLabels:
           team: payments
   ```

3. Apply both and label a target namespace:

   ```bash
   kubectl apply -f vap.yaml -f vapb.yaml
   kubectl create namespace payments
   kubectl label namespace payments team=payments
   ```

4. A compliant Deployment is admitted:

   ```bash
   kubectl -n payments create deployment ok --image=nginx:1.27 --replicas=3
   ```

   ```
   deployment.apps/ok created
   ```

5. A violating Deployment is rejected — by the API server itself, no network hop:

   ```bash
   kubectl -n payments create deployment toobig --image=nginx:1.27 --replicas=8
   ```

   ```
   error: failed to create deployment: deployments.apps "toobig" is forbidden:
   ValidatingAdmissionPolicy 'replica-limit.example.com' with binding
   'replica-limit-binding' denied request: Deployment replicas must be 5 or fewer.
   ```

6. Confirm the scope really is the label, not the cluster: the same over-sized Deployment in `default` succeeds because that namespace lacks `team=payments`.

   ```bash
   kubectl -n default create deployment toobig --image=nginx:1.27 --replicas=8
   ```

   ```
   deployment.apps/toobig created
   ```

> **Comprehension check 4**
> 1. Name two operational advantages of a `ValidatingAdmissionPolicy` over an equivalent `ValidatingWebhookConfiguration`, and one thing a webhook can do that a VAP fundamentally cannot.
> 2. In the CEL expression, why is `object.spec.replicas <= 5` risky if the field can be omitted, and how would you make it null-safe? (Hint: `object.spec.replicas` when unset.)
> 3. The policy and the binding are two separate objects. What real-world workflow does that split between `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding` enable?

---

## Exercise 5 — Dynamic admission and the `failurePolicy` trade-off

**Goal:** understand the availability risk of external webhooks by making one **fail closed**, then **fail open**, *without ever running a webhook server*. An unreachable webhook is the whole demonstration.

1. Register a validating webhook that points at a service which does **not exist**, scoped by label so it can't touch the rest of the cluster:

   ```yaml
   # webhook.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingWebhookConfiguration
   metadata:
     name: deny-when-down.example.com
   webhooks:
     - name: deny-when-down.example.com
       admissionReviewVersions: ["v1"]
       sideEffects: None
       failurePolicy: Fail          # fail CLOSED
       timeoutSeconds: 5
       namespaceSelector:
         matchLabels:
           webhook-demo: "true"
       clientConfig:
         service:
           name: nonexistent-webhook
           namespace: default
           path: /validate
           port: 443
       rules:
         - apiGroups:   [""]
           apiVersions: ["v1"]
           operations:  ["CREATE"]
           resources:   ["pods"]
           scope: "Namespaced"
   ```

   ```bash
   kubectl apply -f webhook.yaml
   kubectl create namespace webhook-demo
   kubectl label namespace webhook-demo webhook-demo=true
   ```

2. Try to create a Pod in the scoped namespace. The API server tries to call the webhook, can't reach it, and — because `failurePolicy: Fail` — denies the request:

   ```bash
   kubectl -n webhook-demo run p --image=nginx:1.27 --restart=Never
   ```

   ```
   Error from server (InternalError): Internal error occurred: failed calling webhook
   "deny-when-down.example.com": failed to call webhook: Post
   "https://nonexistent-webhook.default.svc:443/validate?timeout=5s": service
   "nonexistent-webhook" not found
   ```

3. Prove the blast radius is contained by the `namespaceSelector` — the *same* Pod in `default` (no `webhook-demo=true` label) is created normally:

   ```bash
   kubectl -n default run p --image=nginx:1.27 --restart=Never   # pod/p created
   ```

4. Now flip the policy to **fail open** and retry in the scoped namespace:

   ```bash
   kubectl patch validatingwebhookconfiguration deny-when-down.example.com \
     --type='json' \
     -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'

   kubectl -n webhook-demo run p --image=nginx:1.27 --restart=Never
   ```

   ```
   pod/p created
   ```

   The webhook is still unreachable — but `failurePolicy: Ignore` tells the API server to admit the request when the call fails.

5. **Clean up everything from all five exercises:**

   ```bash
   kubectl delete validatingwebhookconfiguration deny-when-down.example.com
   kubectl delete validatingadmissionpolicybinding replica-limit-binding
   kubectl delete validatingadmissionpolicy replica-limit.example.com
   kubectl delete namespace adm-lab psa-demo payments webhook-demo
   kubectl -n default delete pod p toobig --ignore-not-found
   kubectl -n default delete deployment toobig --ignore-not-found
   ```

> **Comprehension check 5**
> 1. State the safety trade-off in one sentence: what does `failurePolicy: Fail` protect, and what does it endanger?
> 2. Why is it dangerous to write a webhook whose `rules` match `pods` **and** whose `namespaceSelector` also matches `kube-system` with `failurePolicy: Fail`? What is the standard mitigation?
> 3. This webhook declares `sideEffects: None`. What does that field mean, and why does the API server need to know it for `kubectl ... --dry-run=server` to behave correctly?
> 4. Ordering: if this namespace *also* had a `LimitRange`, a `ResourceQuota`, PSA enforcement **and** this webhook, in what order do they evaluate — and can this validating webhook ever see fields injected by `LimitRanger`?

---

## Answers

<details>
<summary><strong>Show answers to all comprehension checks</strong></summary>

### Exercise 1
1. **The default-enabled set is compiled into the `kube-apiserver` binary and is on unless explicitly disabled.** `--enable-admission-plugins` adds *extra* plugins on top of that default set; it does not replace it. So `LimitRanger`, `PodSecurity`, `ResourceQuota`, etc. are active because they're in the built-in defaults, while `NodeRestriction` is the one non-default plugin `kubeadm` opts into. To turn a default off you'd use `--disable-admission-plugins`.
2. Order is fixed by the **compiled-in plugin registration order in the API server source**, not by CLI flag order. Within each phase controllers run in that fixed sequence. `MutatingAdmissionWebhook` is placed near the end of the mutating phase deliberately: built-in mutators (defaults, ServiceAccount token injection, etc.) run first so that external webhooks observe an object that already has the in-tree defaults applied, and can override them last. (`ValidatingAdmissionWebhook` is likewise last in the validating phase.)
3. `NodeRestriction` limits what the **kubelet's own credentials** can modify — a kubelet may only edit its *own* Node object and only Pods bound to it. It is *not* in the default set, so `kubeadm` adds it explicitly to blunt a compromised-node → cluster-wide escalation path. It pairs with the `Node` authorization mode.

### Exercise 2
1. `LimitRanger` acts in the **mutating** phase (it injects `default`/`defaultRequest` into containers that omit resources). `ResourceQuota` acts in the **validating** phase (it only accepts or rejects; it never edits). `ResourceQuota` *must* run after `LimitRanger` because it needs to account for the **final** resource requests — including the ones `LimitRanger` just injected. Reversing them would let a pod that ends up requesting 100m sneak past a quota that saw 0m.
2. The 100m came from `LimitRanger`. The first pod `web` was created with no resources, but `LimitRanger` mutated it to `requests.cpu=100m` (from `defaultRequest`). `ResourceQuota` then counted that injected value — which is exactly why the two controllers must run in that order.
3. Without the `LimitRange`, `web` would be stored with **no** CPU request. Note that once a `ResourceQuota` constrains `requests.cpu`, the quota controller *requires* every pod in the namespace to declare that resource — a pod with no request would itself be rejected ("must specify requests.cpu"). So removing the `LimitRange` doesn't just change accounting; it can make previously-valid pods fail admission, because `LimitRanger` was silently supplying the mandatory value.

### Exercise 3
1. PSA is an **in-process, built-in** controller: the checks are compiled into the API server, keyed off namespace labels, with no external network call and no extra component to keep highly-available. OPA/Gatekeeper and Kyverno are **dynamic** `ValidatingWebhook` deployments: arbitrary policy logic, cross-object lookups, and mutation — but at the cost of running (and securing, and keeping up) an external webhook server that sits in the critical path of every matching request. PSA is fixed to the three Pod Security Standards; the webhook engines are general-purpose.
2. `warn` shows a message to the interactive client (e.g. `kubectl`) and `audit` writes an annotation to the audit log — **neither blocks the request.** Running them at `restricted` while `enforce` stays permissive lets you discover *which existing workloads would break* before you flip `enforce`, turning a risky big-bang change into an observable, staged migration.
3. `enforce-version` pins the ruleset to a specific Kubernetes minor version. Without it (`latest`), a cluster upgrade can silently add new restrictions to the `restricted` profile and start rejecting workloads that used to pass — a change you did not author. Pinning makes policy drift an explicit, reviewed act. Surfacing: `warn` messages appear as `Warning:` lines in the client (the user creating the object); `audit` messages appear only as annotations in the API server **audit log**.

### Exercise 4
1. **Advantages of VAP:** (a) no extra component to deploy, secure, certificate-rotate, or keep highly-available — the logic runs in-process; (b) far lower latency and no availability risk, so no `failurePolicy`/timeout footgun. **What only a webhook can do:** run arbitrary code, perform I/O / external lookups, and (as a *mutating* webhook) modify the object — CEL policies are pure, side-effect-free, and validating-only (mutating admission policies existed only as alpha as of v1.32).
2. If `spec.replicas` is omitted, `object.spec.replicas` is unset; evaluating `<= 5` against an absent field raises a CEL runtime error, and with `failurePolicy: Fail` that error *denies* the request — possibly rejecting valid Deployments. Make it null-safe, e.g. `!has(object.spec.replicas) || object.spec.replicas <= 5` (treat "unset" — which defaults to 1 — as compliant).
3. The split separates **policy definition** from **policy application/scope**. A platform team authors one `ValidatingAdmissionPolicy` (the rule + CEL); many `ValidatingAdmissionPolicyBinding`s then bind it to different namespaces/label-selectors, each with its own `validationActions` (`Deny`, `Warn`, `Audit`) and optional `params`. That lets you dry-run a policy in `Warn`/`Audit` mode via a binding, or apply one rule to different tenants with different parameters, without touching the policy itself.

### Exercise 5
1. `failurePolicy: Fail` **protects the invariant** the webhook enforces (nothing gets through unchecked when the webhook is down) at the cost of **endangering availability** (an unreachable webhook halts all matching writes cluster-wide). `Ignore` inverts the trade-off: writes keep flowing, but the policy is silently skipped while the webhook is down.
2. Many control-plane and add-on components live in `kube-system`. A fail-closed webhook that matches their Pods will, the moment the webhook server is unavailable, block the API server from (re)creating those system Pods — a self-inflicted, self-sustaining outage that can prevent the webhook itself from recovering. Standard mitigations: **exclude control-plane namespaces** with a `namespaceSelector` (e.g. `NotIn` a `control-plane` / `kubernetes.io/metadata.name` label), scope `rules` as narrowly as possible, keep `timeoutSeconds` low, and reserve `failurePolicy: Fail` for tightly-scoped, business-critical checks.
3. `sideEffects` declares whether calling the webhook mutates any state **outside** the admission request (e.g. writing to an external system). `None` means it's side-effect-free. The API server needs this because during `--dry-run=server` it must guarantee nothing is actually changed: it will **only call** webhooks declared `None` (or `NoneOnDryRun`) during a dry run, and skips those declaring `Some`.
4. Evaluation order in the matching namespace: **mutating phase** — built-in mutators including `LimitRanger` (inject defaults), then `MutatingAdmissionWebhook`; then **schema validation**; then **validating phase** — built-in validators including `PodSecurity` and `ResourceQuota`, then `ValidatingAdmissionPolicy`, then `ValidatingAdmissionWebhook` (this webhook) last. Yes — because this validating webhook runs *after* the entire mutating phase, it sees the object with `LimitRanger`'s injected `requests`/`limits` already present.

</details>

---

**Sources**

- Admission Controllers Reference — <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>
- Dynamic Admission Control (webhooks) — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Validating Admission Policy (CEL) — <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Pod Security Admission — <https://kubernetes.io/docs/concepts/security/pod-security-admission/>
- Pod Security Standards — <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Resource Quotas — <https://kubernetes.io/docs/concepts/policy/resource-quotas/> · Limit Ranges — <https://kubernetes.io/docs/concepts/policy/limit-range/>