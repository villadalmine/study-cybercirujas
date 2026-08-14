# Topic 4.3 — Common Policy Settings for Kyverno Rules

## Guided Exercises

> **Exam context (KCA).** "Common policy settings" are the fields under a policy's `spec` that govern *how* a rule is evaluated and enforced, independent of whether the rule is `validate`, `mutate`, `generate`, or `verifyImages`. These settings decide whether a violation blocks a request or only reports it, whether the policy runs on pre-existing resources, and how the admission webhook behaves when Kyverno itself is unreachable. Getting them wrong is the difference between a policy that quietly does nothing and one that locks the whole cluster out of scheduling Pods.

### Prerequisites

You need a working cluster and a Kyverno installation (admission + background + reports controllers). The exercises below are self-contained; every manifest is complete and applies as-is.

```bash
# 1. Confirm Kyverno is installed and all controllers are Ready.
kubectl get pods -n kyverno
```

Expected (component names may carry a release suffix):

```
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d9f8c6b4-abcde     1/1     Running   0          3m
kyverno-background-controller-6c5b7f9d8-fghij    1/1     Running   0          3m
kyverno-cleanup-controller-5f6d8b7c9-klmno       1/1     Running   0          3m
kyverno-reports-controller-8b7c6d5f4-pqrst       1/1     Running   0          3m
```

If any controller is missing, background scanning and Policy Reports will not work and several exercises below will fail silently — that is itself a lesson in why you verify the control plane before trusting policy output.

```bash
# 2. Create a scratch namespace and export the Kyverno version for reference.
kubectl create namespace policy-lab
kubectl get deploy -n kyverno kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

---

### Exercise 1 — `validationFailureAction`: Audit vs Enforce

**Objective:** Prove to yourself that the *same* rule either blocks or merely reports, controlled by a single field, and locate where a non-blocking violation is recorded.

1. Create a policy in **Audit** mode that requires a `team` label on every Pod.

```yaml
# require-team-audit.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Every Pod must carry a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f require-team-audit.yaml
kubectl get cpol require-team-label
```

Expected (columns vary slightly by version):

```
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
require-team-label   true        true         True    8s    Ready
```

2. Create a Pod that **violates** the rule and observe that it is admitted anyway.

```yaml
# nginx-nolabel.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-nolabel
  namespace: policy-lab
spec:
  containers:
    - name: nginx
      image: nginx:1.27
```

```bash
kubectl apply -f nginx-nolabel.yaml
# pod/nginx-nolabel created
```

3. Find where the violation was recorded — it did not block, but it was *not* ignored.

```bash
kubectl get policyreports -n policy-lab
kubectl describe polr -n policy-lab <report-name-from-above>
```

Expected (report names are auto-generated and version-dependent; read the columns, not the name):

```
NAMESPACE    NAME                              PASS   FAIL   WARN   ERROR   SKIP   AGE
policy-lab   6a9c1f7e-2b3d-4e5f-report         0      1      0      0       0      12s
```

The `describe` output shows `result: fail`, the policy/rule, and the offending resource.

4. Now switch the policy to **Enforce** and retry with a fresh violating Pod.

```bash
kubectl patch cpol require-team-label --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'

kubectl run nginx-blocked --image=nginx:1.27 -n policy-lab
```

Expected:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/policy-lab/nginx-blocked was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: Every Pod must carry a ''team'' label.
    rule check-team-label failed at path /metadata/labels/team/'
```

**Check your understanding**

1. Under `Audit`, the violating Pod was created. Where did the violation go, and which Kyverno controller produced that record?
2. You changed `validationFailureAction` from `Audit` to `Enforce`. Did the *already-created* `nginx-nolabel` Pod get deleted or blocked retroactively? Why or why not?
3. In the Enforce error message, what does the webhook suffix `-fail` in `validate.kyverno.svc-fail` tell you about a *different* common policy setting?
4. Why is `Audit` the recommended first step when rolling out a new policy to an existing cluster?

---

### Exercise 2 — `validationFailureActionOverrides`: mixing enforcement per namespace

**Objective:** Enforce globally while exempting specific namespaces (e.g. dev/sandbox) without maintaining two copies of the same policy.

1. Replace the policy with one that enforces everywhere **except** namespaces matching `dev-*` and the literal `sandbox`, where it only audits.

```yaml
# require-team-overrides.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Enforce
  validationFailureActionOverrides:
    - action: Audit
      namespaces:
        - "dev-*"
        - "sandbox"
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Every Pod must carry a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f require-team-overrides.yaml
kubectl create namespace dev-alice
```

2. Show the two behaviors side by side.

```bash
# Blocked in policy-lab (Enforce applies):
kubectl run t1 --image=nginx:1.27 -n policy-lab
# Error from server: ... was blocked due to the following policies ...

# Admitted in dev-alice (Audit override applies):
kubectl run t2 --image=nginx:1.27 -n dev-alice
# pod/t2 created
```

**Check your understanding**

1. Why does `validationFailureActionOverrides` only make sense on a `ClusterPolicy` and not on a namespaced `Policy`?
2. The override list matched `dev-alice` against `dev-*`. What matching mechanism does the `namespaces` field use — regex, glob/wildcard, or exact string?
3. If a namespace matched *two* override entries with conflicting actions, which one wins? (Hint: think about list ordering.)
4. Your team wants "Enforce in prod, Audit everywhere else." Is it cleaner to list the audited namespaces, or to invert the logic? What operational risk does the "list the exceptions" approach carry as new namespaces appear?

---

### Exercise 3 — `background` and the admission-only variable constraint

**Objective:** Understand what background scanning is, what it cannot see, and why Kyverno *rejects* certain policies unless you turn it off.

1. Confirm background scanning is populating reports for a **pre-existing** resource. The `nginx-nolabel` Pod from Exercise 1 already exists and violates the current Enforce policy — background scan reports it without any new admission request.

```bash
kubectl get polr -n policy-lab
# The FAIL column reflects the standing violation of nginx-nolabel,
# produced by the background/reports controller, not by an admission event.
```

2. Now attempt to create a policy that uses an **admission-only** context variable while leaving `background: true` (the default).

```yaml
# block-self-approval.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-self-updates
spec:
  # background left at its default (true) on purpose — this should FAIL.
  rules:
    - name: deny-kube-system-user
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
      validate:
        message: "system:masters may not edit ConfigMaps directly."
        deny:
          conditions:
            any:
              - key: "{{ request.userInfo.groups }}"
                operator: AnyIn
                value:
                  - "system:masters"
```

```bash
kubectl apply -f block-self-approval.yaml
```

Expected — the policy is rejected at admission:

```
Error from server: admission webhook "validate-policy.kyverno.svc-fail" denied the request:
spec.rules[0]: policy uses variables that are only available during admission
(request.userInfo). Set spec.background to false.
```

3. Fix it by disabling background for this policy, then re-apply.

```bash
# Add `background: false` under spec, then:
kubectl apply -f block-self-approval.yaml
kubectl get cpol block-self-updates
```

Expected:

```
NAME                  ADMISSION   BACKGROUND   READY   AGE   MESSAGE
block-self-updates    true        false        True    5s    Ready
```

**Check your understanding**

1. Name three pieces of data that exist *only* during an AdmissionReview and therefore cannot be evaluated during a background scan.
2. A policy with `background: false` is created. Does it still block violating requests at admission time? What does it stop doing?
3. Why does Kyverno reject the policy at creation time instead of silently skipping the affected rule during background scans?
4. You have an Audit policy and you want its violations to appear in Policy Reports for resources that already exist. Which setting must be `true`, and which controller does the actual work?

---

### Exercise 4 — `failurePolicy`: fail-closed vs fail-open

**Objective:** See how a single setting decides whether the cluster keeps admitting resources when Kyverno is *down*, and inspect the webhook it generates.

1. Inspect the auto-generated webhook configuration and correlate its `failurePolicy` with your policy's default.

```bash
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\n"}{end}'
```

Expected (note the `-fail` / `-ignore` suffixes — Kyverno splits Fail and Ignore policies into separate webhook entries):

```
validate.kyverno.svc-fail       Fail
validate.kyverno.svc-ignore     Ignore
```

2. Create a fail-open policy explicitly and confirm which webhook entry it lands in.

```yaml
# require-team-failopen.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-failopen
spec:
  validationFailureAction: Enforce
  failurePolicy: Ignore
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Every Pod must carry a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f require-team-failopen.yaml
```

3. Simulate Kyverno being unavailable and observe the difference. Scale the admission controller to zero, then create Pods governed by a `Fail` policy and by an `Ignore` policy.

```bash
kubectl scale deploy -n kyverno kyverno-admission-controller --replicas=0
sleep 15

# Governed by require-team-label (failurePolicy: Fail, the default):
kubectl run fp-test --image=nginx:1.27 -n policy-lab
# Error from server: Internal error occurred: failed calling webhook
# "validate.kyverno.svc-fail": ... connection refused
```

4. Restore the controller.

```bash
kubectl scale deploy -n kyverno kyverno-admission-controller --replicas=1
```

**Check your understanding**

1. State the exact behavior of `failurePolicy: Fail` and `failurePolicy: Ignore` when the Kyverno webhook endpoint is unreachable.
2. Which value is the secure ("fail-closed") default, and what is the concrete operational danger of running it during a Kyverno outage?
3. You saw two webhook entries, `...svc-fail` and `...svc-ignore`. Why does Kyverno split policies across two webhook configurations instead of one?
4. For a policy that *mutates* Pods to inject a required security context, would you prefer `Fail` or `Ignore`? Justify the trade-off between security and availability for that specific case.

---

### Exercise 5 — `applyRules`: All vs One

**Objective:** Control whether every matching rule in a policy fires, or only the first one — critical for ordered mutate rules.

1. Create a policy with two mutate rules and the default `applyRules: All`.

```yaml
# tier-labels-all.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-tier-labels
spec:
  applyRules: All          # default; both rules will apply
  background: false
  rules:
    - name: add-tier-backend
      match:
        any:
          - resources:
              kinds:
                - Pod
              selector:
                matchLabels:
                  app: api
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              tier: backend
    - name: add-tier-general
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              tier: general
```

```bash
kubectl apply -f tier-labels-all.yaml
kubectl run api-pod --image=nginx:1.27 -n policy-lab -l app=api --dry-run=server -o yaml \
  | grep -A3 'labels:'
```

With `applyRules: All`, the second rule runs after the first and the last write wins → `tier: general`.

2. Change to `applyRules: One` so evaluation stops at the first matching rule.

```bash
kubectl patch cpol add-tier-labels --type merge -p '{"spec":{"applyRules":"One"}}'
kubectl run api-pod2 --image=nginx:1.27 -n policy-lab -l app=api --dry-run=server -o yaml \
  | grep -A3 'labels:'
```

Now only `add-tier-backend` fires → `tier: backend`, and evaluation stops.

**Check your understanding**

1. With `applyRules: All`, both mutate rules matched the `app: api` Pod. Which value ended up on the `tier` label, and why?
2. What is the single most common reason to set `applyRules: One`?
3. Does `applyRules: One` change *which* rule is considered "first"? What determines rule ordering within a policy?
4. Would `applyRules: One` be appropriate for a policy containing multiple independent `validate` rules that each check a different requirement? Explain the risk.

---

### Exercise 6 — `webhookTimeoutSeconds` and reading the generated webhook

**Objective:** Tune how long the API server waits for Kyverno before applying the `failurePolicy`, and see the setting propagate into the live webhook configuration.

1. Set an explicit timeout on a policy.

```yaml
# timeout-demo.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: timeout-demo
spec:
  validationFailureAction: Audit
  webhookTimeoutSeconds: 15
  background: true
  rules:
    - name: require-runasnonroot
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Containers must set securityContext.runAsNonRoot: true."
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
```

```bash
kubectl apply -f timeout-demo.yaml
```

2. Read the timeout back out of the webhook configuration Kyverno maintains.

```bash
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.timeoutSeconds}{"\n"}{end}'
```

Expected:

```
validate.kyverno.svc-fail       15
validate.kyverno.svc-ignore     15
```

**Check your understanding**

1. What is the allowed range for `webhookTimeoutSeconds`, and what is the default if you omit it?
2. When the timeout is exceeded, what happens next depends on *another* common setting — which one, and what are the two possible outcomes?
3. Why is a very high webhook timeout on a `Fail` policy operationally dangerous for the whole API server, not just for Kyverno?
4. Kyverno registers webhooks *only* for resource kinds that at least one policy targets. Why is that scoping important for API-server latency and blast radius?

---

### Cleanup

```bash
kubectl delete cpol require-team-label require-team-failopen block-self-updates \
  add-tier-labels timeout-demo --ignore-not-found
kubectl delete namespace policy-lab dev-alice sandbox --ignore-not-found
```

---

## Answers

<details>
<summary>Click to reveal answers and rationale</summary>

### Exercise 1 — `validationFailureAction`

1. The violation was written to a **Policy Report** (`PolicyReport`/`polr` in the resource's namespace) with `result: fail`. The **reports controller** aggregates the admission-time evaluation (and background-scan results) into these `wgpolicyk8s.io/v1alpha2` report objects. Under `Audit`, the admission controller allows the request but still emits the evaluation result.
2. Neither. `Enforce` only affects **new or updated** admission requests. Kyverno's validating webhook intercepts `CREATE`/`UPDATE`/`CONNECT`, not resources at rest, so an already-admitted Pod is never retroactively blocked or deleted. Its standing violation will, however, appear in Policy Reports via background scanning.
3. The suffix `-fail` is the webhook entry name for policies whose `failurePolicy` is `Fail` (the default). Kyverno groups `Fail` and `Ignore` policies into separate webhook configurations (`...svc-fail` / `...svc-ignore`) — so the message already reveals the effective `failurePolicy` (Exercise 4).
4. `Audit` lets you measure real-world impact — how many existing and incoming resources would be blocked — without breaking any workloads or CI/CD pipelines. You promote to `Enforce` only after the report count for legitimate resources reaches zero. Going straight to `Enforce` on a populated cluster risks blocking deployments cluster-wide.

### Exercise 2 — `validationFailureActionOverrides`

1. The overrides key resources by `namespaces`, and a namespaced `Policy` already lives in — and only applies to — a single namespace, so there is nothing to override across namespaces. The field is meaningful only for cluster-scoped `ClusterPolicy`.
2. It uses **glob/wildcard** matching (e.g. `dev-*`), not full regular expressions and not exact-only strings. `dev-alice` matches `dev-*`.
3. The **first matching entry in list order** wins. Order your overrides from most-specific to least-specific to get deterministic behavior.
4. Listing the audited exceptions (`Enforce` globally, override specific namespaces to `Audit`) is common but carries a **fail-open drift risk**: any *new* namespace you forget to add inherits `Enforce`, which is the safe direction — but if you instead invert it (Audit globally, Enforce only listed prod namespaces), a new prod namespace silently gets only `Audit`. Prefer the arrangement where "forgot to update the list" fails toward *more* enforcement, not less.

### Exercise 3 — `background`

1. Any AdmissionReview-only data: `request.userInfo` (user/groups), `request.roles` / `request.clusterRoles`, the operation (`request.operation`), the requesting object's `oldObject` on updates, and admission-time-only image/registry data. None of these exist when the reports controller re-scans a resource at rest.
2. Yes — `background: false` disables only **background scanning** (periodic re-evaluation of existing resources and report generation for them). The policy still runs at **admission** and still blocks/mutates live requests normally.
3. Silently skipping would make the policy's coverage invisible and non-deterministic — a security control that "sometimes doesn't apply" is worse than one that fails loudly. Kyverno rejects the policy at creation so the author explicitly acknowledges the trade-off by setting `background: false`.
4. `background` must be `true` (the default). The **background controller** re-evaluates existing resources on the background scan interval, and the **reports controller** aggregates the results into Policy Reports.

### Exercise 4 — `failurePolicy`

1. `Fail` (fail-closed): if the webhook is unreachable or errors, the API server **rejects** the request. `Ignore` (fail-open): the API server **allows** the request to proceed as if no policy existed.
2. `Fail` is the secure default. Its danger: if the Kyverno admission controller is down (crash, upgrade, network partition), *every* `CREATE`/`UPDATE` for the resource kinds it governs is blocked — which can stall Deployments, prevent Pod rescheduling during a node failure, and, in the worst case, prevent you from fixing Kyverno itself.
3. The API server's `ValidatingWebhookConfiguration` sets `failurePolicy` per webhook entry, not per policy. Kyverno therefore places all `Fail` policies under one webhook entry (`...svc-fail`) and all `Ignore` policies under another (`...svc-ignore`) so each group gets the correct fail behavior from the API server.
4. For a *mutating* security-context injection, many teams still choose `Fail`: if the mutation can't run, you don't want an unhardened Pod admitted. But that must be weighed against availability — a mutation webhook that is fail-closed and slow/down blocks all Pod creation. The defensible answer states the trade-off explicitly: `Fail` for a strong security guarantee at the cost of availability during Kyverno outages; `Ignore` for availability at the cost of a hardening gap. There is no universally correct answer — it depends on whether the control is a compliance requirement or a best-effort default.

### Exercise 5 — `applyRules`

1. `tier: general`. With `applyRules: All`, both mutate rules fired in order; the later rule (`add-tier-general`) patched the label last, so its value won (last-write-wins for strategic merge on the same key).
2. To make **ordered mutation** deterministic — apply only the first rule whose `match` succeeds and stop, so more-specific rules listed earlier take precedence over general fallbacks and later rules can't overwrite them.
3. No — it does not reorder anything. "First" means the first rule in the policy's `rules` list (document order) whose `match`/`exclude` selects the resource. Ordering is the author's responsibility.
4. No. For independent `validate` rules, `applyRules: One` would stop after the first matching rule, so the remaining requirements would **never be checked** — a resource could pass validation while violating rules 2..N. `One` is intended for mutate precedence, not for short-circuiting independent validations.

### Exercise 6 — `webhookTimeoutSeconds`

1. Range **1–30 seconds**; the default is **10**.
2. `failurePolicy`. On timeout the API server treats the webhook call as failed, so `Fail` → the request is rejected, `Ignore` → the request is admitted without the policy.
3. A high timeout on a `Fail` policy means every governed request can hang up to that many seconds waiting on Kyverno before the API server gives up. If Kyverno is slow or overloaded, this multiplies latency across all matching admissions and can degrade the API server's request throughput cluster-wide — the timeout is a ceiling on how long the *entire admission chain* can stall.
4. Scoping the webhooks to only the resource kinds under policy means the API server doesn't call Kyverno for unrelated objects. That reduces added admission latency and shrinks the blast radius: a Kyverno outage with `Fail` only affects the specific kinds you actually govern, not every write to the cluster.

</details>

---

## Sources

- Kyverno — Policy Settings (applyRules, admission, background, failurePolicy, generateExisting, mutateExistingOnPolicyUpdate, schemaValidation, validationFailureAction, validationFailureActionOverrides, webhookTimeoutSeconds): https://kyverno.io/docs/writing-policies/policy-settings/
- Kyverno — Validate rules and `validationFailureAction`: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Policy Reports (background scanning, `polr`/`cpolr`): https://kyverno.io/docs/policy-reports/
- Kyverno — Mutate rules and `applyRules` ordering: https://kyverno.io/docs/writing-policies/mutate/
- Kubernetes — Dynamic Admission Control (`failurePolicy`, `timeoutSeconds`, matchConditions): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/