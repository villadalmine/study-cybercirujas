# Topic 6.2 — PolicyExceptions

## Guided Exercises

> **Scope.** These exercises cover the `PolicyException` resource in Kyverno: enabling the feature, authoring exceptions, scoping them, exempting individual Pod Security Standard controls, governing exceptions with policy, testing them in CI with the Kyverno CLI, and diagnosing the cases where an exception silently does nothing.
>
> **Discipline.** Every step that asserts a version-dependent fact is written as a command you run, not as a claim you trust. Kyverno's exception surface has changed across 1.9 → 1.11 → 1.13, so *verify on your cluster* is part of the exercise, not a disclaimer.

---

## Lab prerequisites

| Component | Version used here | Notes |
|---|---|---|
| Kubernetes | 1.29+ | `kind` is fine; no cloud provider needed |
| Kyverno | 1.11+ (1.13+ recommended) | installed via Helm chart `kyverno/kyverno` 3.x |
| `kubectl` | matching the cluster | |
| Kyverno CLI | same minor as the cluster | used in Exercise 7 |

You need cluster-admin on a throwaway cluster. Do not run Exercise 6 against a shared cluster: it installs an `Enforce` policy over the `PolicyException` kind itself.

---

## Exercise 1 — Create the cluster and prove whether the feature is on

PolicyExceptions are gated behind a controller flag. On some versions it defaults off; on others on. Never assume — read the running Deployment.

1. Create the cluster and the namespaces you will use:

```bash
kind create cluster --name kca-62

kubectl create namespace legacy-monitoring
kubectl create namespace team-a
kubectl create namespace kyverno-exceptions
```

2. Inspect the chart values *before* installing, so you know the exact key names your chart version exposes:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm show values kyverno/kyverno | grep -A 8 'policyExceptions'
```

Representative output:

```yaml
  policyExceptions:
    # -- Enables the feature
    enabled: false
    # -- Restrict PolicyExceptions to a single namespace
    namespace: ''
```

3. Install Kyverno with the feature explicitly enabled and **unrestricted for now** (you will restrict it in Exercise 5):

```bash
helm install kyverno kyverno/kyverno \
  -n kyverno --create-namespace \
  --set features.policyExceptions.enabled=true

kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

4. Prove the flag reached the container. This is the single most useful check when an exception "does not work":

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | tr ',' '\n' | grep -i exception
```

```
"--enablePolicyException=true"
```

5. Confirm the CRD is served, and note the API version and short name:

```bash
kubectl api-resources | grep -i policyexception
```

```
policyexceptions   polex   kyverno.io/v2   true   PolicyException
```

6. Read the schema from the cluster rather than from memory:

```bash
kubectl explain policyexception.spec
kubectl explain policyexception.spec.exceptions
```

### Check your understanding

- **Q1.** The `enablePolicyException` flag is passed to more than one Kyverno controller. Which controllers need it, and what breaks if you set it on the admission controller only?
- **Q2.** `kubectl api-resources` shows `NAMESPACED = true` for `PolicyException`. Why is a namespaced kind a deliberate design choice for an exception mechanism, given that `ClusterPolicy` is cluster-scoped?
- **Q3.** You run `kubectl get polex -A` and get `No resources found`, yet a teammate insists they applied one. Name two distinct causes that produce exactly this output.

---

## Exercise 2 — Install an enforcing policy and observe the block

You need something to be exempted *from*. Build the baseline first and confirm it actually denies.

1. Write the policy:

```yaml
# disallow-host-path.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-path
  annotations:
    policies.kyverno.io/title: Disallow hostPath
    policies.kyverno.io/category: Pod Security Standards (Baseline)
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      HostPath volumes let a Pod read and write the node filesystem, which
      collapses the container boundary. This rule forbids them cluster-wide;
      exemptions are granted only through a PolicyException.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: host-path
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          HostPath volumes are forbidden. The field spec.volumes[*].hostPath
          must be unset.
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "null"
```

> **Version note.** Kyverno 1.13 deprecates the spec-level `validationFailureAction` in favour of the per-rule `spec.rules[].validate.failureAction`. Check which one your cluster serves before copying this into production:
> ```bash
> kubectl explain clusterpolicy.spec.rules.validate.failureAction
> ```

2. Apply it and confirm it is ready:

```bash
kubectl apply -f disallow-host-path.yaml
kubectl get clusterpolicy disallow-host-path
```

```
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-host-path   true        true         True    8s    Ready
```

3. List the rules Kyverno actually compiled, including the ones you did not write:

```bash
kubectl get clusterpolicy disallow-host-path -o jsonpath='{.status.autogen.rules[*].name}' ; echo
```

```
autogen-host-path autogen-cronjob-host-path
```

4. Try to create a Pod that violates it:

```yaml
# node-exporter.yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-exporter
  namespace: legacy-monitoring
  labels:
    app: node-exporter
spec:
  containers:
    - name: node-exporter
      image: quay.io/prometheus/node-exporter:v1.8.2
      args: ["--path.rootfs=/host"]
      volumeMounts:
        - name: rootfs
          mountPath: /host
          readOnly: true
  volumes:
    - name: rootfs
      hostPath:
        path: /
        type: Directory
```

```bash
kubectl apply -f node-exporter.yaml
```

```
Error from server: error when creating "node-exporter.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/legacy-monitoring/node-exporter was blocked due to the following policies

disallow-host-path:
  host-path: 'validation error: HostPath volumes are forbidden. The field
    spec.volumes[*].hostPath must be unset. rule host-path failed at path
    /spec/volumes/0/hostPath/'
```

5. Record the exact rule name from the denial message — `host-path`. You will need it verbatim.

### Check your understanding

- **Q4.** The policy matches only `kind: Pod`, yet `status.autogen.rules` lists two extra rules. What generates them, and what problem does that create for the exception you are about to write?
- **Q5.** The webhook in the error is named `validate.kyverno.svc-fail`. What does the `-fail` suffix tell you about the webhook's `failurePolicy`, and what would happen to Pod creation cluster-wide if the Kyverno admission controller became unreachable?
- **Q6.** Why does this exercise insist you copy the rule name from the *denial message* rather than from the YAML you wrote?

---

## Exercise 3 — Author your first PolicyException

1. Write an exception scoped as narrowly as you can make it — one policy, one rule, one namespace, one name pattern:

```yaml
# polex-node-exporter.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-node-exporter-hostpath
  namespace: kyverno-exceptions
  annotations:
    exceptions.corp.io/owner: platform-observability
    exceptions.corp.io/ticket: PLAT-4471
    exceptions.corp.io/justification: >-
      node-exporter must read /proc, /sys and the root filesystem from the node.
      Compensating control: the mount is readOnly and the DaemonSet runs with a
      dedicated ServiceAccount with no API permissions.
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames:
        - host-path
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - legacy-monitoring
          names:
            - node-exporter*
```

> If your cluster serves `kyverno.io/v2beta1` instead of `kyverno.io/v2`, change `apiVersion` accordingly — the `spec` shown here is identical in both.

2. Apply it and re-try the Pod:

```bash
kubectl apply -f polex-node-exporter.yaml
kubectl apply -f node-exporter.yaml
```

```
policyexception.kyverno.io/exempt-node-exporter-hostpath created
pod/node-exporter created
```

3. Verify the *blast radius* — the exception must not have opened a hole for anything else. Create a second violating Pod in the same namespace with a different name:

```bash
kubectl run rogue --image=busybox -n legacy-monitoring --restart=Never --dry-run=client -o yaml \
  | kubectl patch --local -f - -o yaml --type=json \
    -p='[{"op":"add","path":"/spec/volumes","value":[{"name":"h","hostPath":{"path":"/etc"}}]},
         {"op":"add","path":"/spec/containers/0/volumeMounts","value":[{"name":"h","mountPath":"/mnt"}]}]' \
  | kubectl apply -f -
```

Expected: still denied. If it is not, your `names` selector is wrong.

4. Now observe how the exception is *recorded*, not just how it behaves. Kyverno reports an exempted resource as `skip`, never as `pass`:

```bash
kubectl get policyreport -n legacy-monitoring -o wide
```

```
NAME                                   KIND   NAME            PASS  FAIL  WARN  ERROR  SKIP  AGE
b3f1e0a2-7c4e-4a41-9f0d-8a2c5e1d9b77   Pod    node-exporter   0     0     0     0      1     22s
```

5. Read the message Kyverno attaches to the skipped result:

```bash
kubectl get policyreport -n legacy-monitoring -o jsonpath='{.items[0].results[0]}' | python3 -m json.tool
```

```json
{
    "policy": "disallow-host-path",
    "rule": "host-path",
    "result": "skip",
    "message": "rule skipped due to policy exception kyverno-exceptions/exempt-node-exporter-hostpath",
    "source": "kyverno",
    "scored": true
}
```

*(Exact message wording varies by version; the `result: skip` and the exception reference are the invariants.)*

### Check your understanding

- **Q7.** The exception lives in namespace `kyverno-exceptions` but exempts a Pod in `legacy-monitoring`. Which namespace determines whether the exception applies — the exception's own, or the one in `spec.match`?
- **Q8.** Why is `skip` a materially different audit signal from `pass`? Describe what a compliance dashboard loses if it collapses the two.
- **Q9.** You wrote `ruleNames: [host-path]`. Predict what happens if the team switches `node-exporter` from a bare Pod to a DaemonSet, and state the exact fix.
- **Q10.** What is the security argument for putting the justification in an annotation rather than a YAML comment?

---

## Exercise 4 — Autogen rules, wildcards, and pod controllers

This is the single most common reason a correct-looking exception fails.

1. Convert the workload to a DaemonSet:

```yaml
# node-exporter-ds.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: legacy-monitoring
spec:
  selector:
    matchLabels: { app: node-exporter }
  template:
    metadata:
      labels: { app: node-exporter }
    spec:
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.8.2
          volumeMounts:
            - { name: rootfs, mountPath: /host, readOnly: true }
      volumes:
        - name: rootfs
          hostPath: { path: /, type: Directory }
```

```bash
kubectl apply -f node-exporter-ds.yaml
```

Expected denial:

```
Error from server: error when creating "node-exporter-ds.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource DaemonSet/legacy-monitoring/node-exporter was blocked due to the following policies

disallow-host-path:
  autogen-host-path: 'validation error: HostPath volumes are forbidden. ...'
```

2. Note that the failing rule is now `autogen-host-path`, which is not in your exception. Patch the exception to cover both the resource kinds and the generated rule names:

```yaml
# polex-node-exporter.yaml  (revised)
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-node-exporter-hostpath
  namespace: kyverno-exceptions
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames:
        - host-path
        - autogen-host-path
  match:
    any:
      - resources:
          kinds:
            - Pod
            - DaemonSet
          namespaces:
            - legacy-monitoring
          names:
            - node-exporter*
```

```bash
kubectl apply -f polex-node-exporter.yaml
kubectl apply -f node-exporter-ds.yaml
kubectl -n legacy-monitoring rollout status ds/node-exporter
```

3. Consider the wildcard form. `ruleNames` accepts `*`:

```yaml
      ruleNames:
        - "*"
```

Apply it, confirm it works, then **revert to the explicit list**:

```bash
kubectl apply -f polex-node-exporter.yaml   # explicit list version
```

4. Add a data-driven guard so the exception applies only to workloads that carry the right label, not merely the right name. `spec.conditions` uses the same operators as rule preconditions:

```yaml
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames: [host-path, autogen-host-path]
  match:
    any:
      - resources:
          kinds: [Pod, DaemonSet]
          namespaces: [legacy-monitoring]
  conditions:
    all:
      - key: "{{ request.object.metadata.labels.app || '' }}"
        operator: Equals
        value: node-exporter
```

> `spec.conditions` was added in Kyverno 1.12. Confirm with `kubectl explain policyexception.spec.conditions`; if it returns an error, stay with `match.names`.

### Check your understanding

- **Q11.** Explain precisely why `ruleNames: ["*"]` is discouraged in a production exception, given that the exception is already pinned to one `policyName`.
- **Q12.** Your exception matches `kinds: [Pod, DaemonSet]`. The DaemonSet controller creates a Pod on each node. Which of the two admission requests does the `autogen-host-path` rule evaluate, and which does `host-path` evaluate?
- **Q13.** `spec.conditions` reads `request.object`. What does that imply about whether such an exception can be honoured during a background scan?

---

## Exercise 5 — Scoping: `exceptionNamespace` and the RBAC escalation path

An unrestricted PolicyException API is a privilege-escalation primitive: anyone who can create a `PolicyException` in *any* namespace can exempt resources in *every* namespace.

1. Demonstrate the problem. Grant a low-privilege team the ability to manage exceptions in their own namespace:

```yaml
# team-a-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: exception-author
  namespace: team-a
rules:
  - apiGroups: ["kyverno.io"]
    resources: ["policyexceptions"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: exception-author
  namespace: team-a
subjects:
  - kind: ServiceAccount
    name: default
    namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: exception-author
```

```bash
kubectl apply -f team-a-rbac.yaml
```

2. From `team-a`, author an exception whose `match` targets a namespace `team-a` does not own:

```yaml
# escalation.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: totally-normal-exception
  namespace: team-a
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames: ["*"]
  match:
    any:
      - resources:
          kinds: ["*"]
          namespaces: ["*"]
```

```bash
kubectl --as=system:serviceaccount:team-a:default apply -f escalation.yaml
```

3. Observe that the create succeeds and the cluster-wide policy is now effectively disabled. Confirm with the rogue Pod from Exercise 3 — it should now be admitted. Then delete the exception immediately:

```bash
kubectl -n team-a delete polex totally-normal-exception
```

4. Close the hole. Restrict Kyverno to honour exceptions from exactly one namespace:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno \
  --reuse-values \
  --set features.policyExceptions.enabled=true \
  --set features.policyExceptions.namespace=kyverno-exceptions

kubectl -n kyverno rollout status deploy/kyverno-admission-controller

kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i exception
```

```
"--enablePolicyException=true"
"--exceptionNamespace=kyverno-exceptions"
```

5. Re-run the escalation attempt. The object is still *created* — but it is no longer *honoured*:

```bash
kubectl --as=system:serviceaccount:team-a:default apply -f escalation.yaml
kubectl apply -f node-exporter.yaml   # exception in kyverno-exceptions still works
# rogue Pod from Exercise 3 → still denied
kubectl -n team-a delete polex totally-normal-exception
```

6. Now remove the API surface entirely from tenants, keeping only the central namespace:

```bash
kubectl -n team-a delete rolebinding exception-author
kubectl -n team-a delete role exception-author
```

### Check your understanding

- **Q14.** In step 5 the escalation object was still admitted by the API server. Explain the difference between *creating* a PolicyException and it being *effective*, and why `--exceptionNamespace` does not produce an admission error.
- **Q15.** With `--exceptionNamespace=kyverno-exceptions` set, describe the minimum RBAC you would grant a platform team so they can approve exceptions without gaining the ability to edit the underlying `ClusterPolicy` objects.
- **Q16.** A colleague proposes skipping `--exceptionNamespace` and instead relying on a GitOps controller as the only writer of exceptions. Give one advantage and one residual risk of that approach.

---

## Exercise 6 — Exempting a single Pod Security Standard control

When the underlying rule is `validate.podSecurity`, an all-or-nothing exception is far too blunt: it would waive every control in the profile. The `spec.podSecurity` block exempts one control, for one image, for one field, for one value.

1. Install a Baseline PSS policy:

```yaml
# psa-baseline.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psa-baseline
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: baseline
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        podSecurity:
          level: baseline
          version: latest
```

```bash
kubectl apply -f psa-baseline.yaml
```

2. Create a Pod that violates exactly one Baseline control (`Capabilities`):

```yaml
# legacy-agent.yaml
apiVersion: v1
kind: Pod
metadata:
  name: legacy-agent
  namespace: legacy-monitoring
spec:
  containers:
    - name: agent
      image: docker.io/library/nginx:1.27
      securityContext:
        capabilities:
          add: ["NET_ADMIN"]
```

```bash
kubectl apply -f legacy-agent.yaml
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/legacy-monitoring/legacy-agent was blocked due to the following policies

psa-baseline:
  baseline: 'Validation rule ''baseline'' failed. It violates PodSecurity
    "baseline:latest": ({Allowed:false ForbiddenReason:non-default capabilities
    ForbiddenDetail:container "agent" must not include "NET_ADMIN" in
    securityContext.capabilities.add ...})'
```

3. Write a surgical exception. Note it names the *control*, the *image*, the *restricted field* and the *permitted value*:

```yaml
# polex-psa-capabilities.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-legacy-agent-net-admin
  namespace: kyverno-exceptions
  annotations:
    exceptions.corp.io/owner: platform-networking
    exceptions.corp.io/ticket: PLAT-4488
spec:
  exceptions:
    - policyName: psa-baseline
      ruleNames:
        - baseline
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - legacy-monitoring
          names:
            - legacy-agent
  podSecurity:
    - controlName: Capabilities
      images:
        - "docker.io/library/nginx*"
      restrictedField: spec.containers[*].securityContext.capabilities.add
      values:
        - NET_ADMIN
```

```bash
kubectl apply -f polex-psa-capabilities.yaml
kubectl apply -f legacy-agent.yaml
```

```
pod/legacy-monitoring/legacy-agent created
```

4. Prove the exemption is genuinely narrow. Add a second capability the exception does not list:

```bash
kubectl delete pod legacy-agent -n legacy-monitoring
# edit legacy-agent.yaml: add: ["NET_ADMIN", "SYS_ADMIN"]
kubectl apply -f legacy-agent.yaml
```

Expected: denied, citing `SYS_ADMIN` only. Then prove the *other* Baseline controls are still live:

```bash
kubectl run hostpid --image=nginx -n legacy-monitoring \
  --overrides='{"spec":{"hostPID":true}}' --restart=Never
```

Expected: denied on the `Host Namespaces` control.

5. Add lifecycle. An exception with no end date becomes permanent policy. Label it for TTL cleanup:

```bash
kubectl -n kyverno-exceptions label polex exempt-legacy-agent-net-admin \
  cleanup.kyverno.io/ttl=720h
```

Confirm the cleanup controller is running and that the TTL label is the form your version accepts:

```bash
kubectl -n kyverno get deploy | grep cleanup
kubectl -n kyverno-exceptions get polex --show-labels
```

### Check your understanding

- **Q17.** Compare two ways to unblock `legacy-agent`: (a) the `spec.podSecurity` exception above, and (b) an exception with no `podSecurity` block that simply lists `ruleNames: [baseline]`. What exactly does (b) waive?
- **Q18.** The `images` field uses a wildcard `docker.io/library/nginx*`. What class of bypass does that wildcard permit, and how would you tighten it?
- **Q19.** Why does an exception without an expiry mechanism degrade a policy programme over time, even when every individual exception was justified when granted?

---

## Exercise 7 — Shift left: testing exceptions with the Kyverno CLI

Exceptions belong in the same pull request as the workload that needs them, and they must be tested before they reach a cluster.

1. Discover the flag name your CLI version uses — it has differed across releases:

```bash
kyverno version
kyverno apply --help | grep -i exception
```

2. Assemble the files and evaluate the policy against the resource *without* the exception:

```bash
kyverno apply disallow-host-path.yaml --resource node-exporter.yaml
```

```
Applying 1 policy rule(s) to 1 resource(s)...

policy disallow-host-path -> resource legacy-monitoring/Pod/node-exporter failed:
1. host-path: validation error: HostPath volumes are forbidden. ...

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

3. Now include the exception, using the flag name you found in step 1:

```bash
kyverno apply disallow-host-path.yaml \
  --resource node-exporter.yaml \
  --exception polex-node-exporter.yaml
```

```
pass: 0, fail: 0, warn: 0, error: 0, skip: 1
```

4. Turn that into a declarative, CI-runnable assertion:

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: hostpath-exception-test
policies:
  - disallow-host-path.yaml
resources:
  - node-exporter.yaml
  - rogue.yaml
exceptions:
  - polex-node-exporter.yaml
results:
  - policy: disallow-host-path
    rule: host-path
    resource: node-exporter
    kind: Pod
    result: skip
  - policy: disallow-host-path
    rule: host-path
    resource: rogue
    kind: Pod
    result: fail
```

```bash
kyverno test .
```

```
Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Loading exceptions ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│ ID │ POLICY             │ RULE      │ RESOURCE                          │ RESULT │
│ 1  │ disallow-host-path │ host-path │ Pod/legacy-monitoring/node-exporter│ Pass   │
│ 2  │ disallow-host-path │ host-path │ Pod/legacy-monitoring/rogue        │ Pass   │

Test Summary: 2 tests passed and 0 tests failed
```

5. Note the second assertion. A test suite that only proves the exception *works* is half a test; the `result: fail` row proves it did not over-reach.

### Check your understanding

- **Q20.** In the `kyverno test` output, row 2 reads `RESULT: Pass` while the declared expectation was `result: fail`. Explain the two different meanings of "pass" at work here.
- **Q21.** Your CI runs `kyverno test` on every PR. A developer submits an exception with `ruleNames: ["*"]` and `namespaces: ["*"]`, plus a test asserting `result: skip`. The suite goes green. What class of defect does `kyverno test` structurally fail to catch, and which exercise in this document addresses it?

---

## Exercise 8 — Governing the exceptions themselves, and diagnosing silence

An exception is a Kubernetes resource, so it is subject to policy like any other. Close the loop by validating exceptions with Kyverno.

1. Write a meta-policy. It requires provenance metadata and forbids wildcard namespace targeting:

```yaml
# govern-policy-exceptions.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: govern-policy-exceptions
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: require-provenance
      match:
        any:
          - resources:
              kinds:
                - kyverno.io/v2/PolicyException
      validate:
        message: >-
          Every PolicyException must declare an owner, a ticket and a TTL.
        pattern:
          metadata:
            labels:
              cleanup.kyverno.io/ttl: "?*"
            annotations:
              exceptions.corp.io/owner: "?*"
              exceptions.corp.io/ticket: "?*"

    - name: forbid-wildcard-namespaces
      match:
        any:
          - resources:
              kinds:
                - kyverno.io/v2/PolicyException
      validate:
        message: >-
          A PolicyException must not target all namespaces. List them explicitly.
        deny:
          conditions:
            any:
              - key: "*"
                operator: AnyIn
                value: "{{ request.object.spec.match.any[].resources.namespaces[] || `[]` }}"
```

```bash
kubectl apply -f govern-policy-exceptions.yaml
```

2. Test it against the escalation manifest from Exercise 5:

```bash
kubectl apply -f escalation.yaml
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource PolicyException/team-a/totally-normal-exception was blocked due to the following policies

govern-policy-exceptions:
  require-provenance: 'validation error: Every PolicyException must declare an
    owner, a ticket and a TTL. rule require-provenance failed at path
    /metadata/labels/'
```

3. **Critical gotcha.** Kyverno ships a `resourceFilters` list in its ConfigMap that excludes certain namespaces and kinds from *all* policy evaluation — the Kyverno namespace among them. Inspect it and confirm your exception namespace is not on the list:

```bash
kubectl -n kyverno get configmap kyverno -o jsonpath='{.data.resourceFilters}' \
  | tr ']' ']\n' | grep -iE 'kyverno|kube-system'
```

If you had named the central namespace `kyverno` rather than `kyverno-exceptions`, this meta-policy would never fire.

4. Build the diagnostic checklist. When an exception "does nothing", walk these in order:

```bash
# 1. Is the feature on, and is the namespace restriction what you think?
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i exception

# 2. Does the exception exist where Kyverno is looking?
kubectl get polex -A

# 3. Does policyName match exactly? (typos here fail silently)
kubectl get clusterpolicy -o name
kubectl get polex -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.exceptions[*].policyName}{"\n"}{end}'

# 4. Does ruleNames include the autogen variants?
kubectl get clusterpolicy disallow-host-path -o jsonpath='{.status.autogen.rules[*].name}'; echo

# 5. What did the controller actually decide?
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 | grep -i exception

# 6. What does the report say — skip, or fail?
kubectl get polr -A -o wide
```

5. Trigger a fresh background scan to confirm reports converge, then read the result for the whole cluster:

```bash
kubectl get clusterpolicyreport,policyreport -A -o wide
```

### Check your understanding

- **Q22.** In the meta-policy, `background: false` is set. Why is that not merely an optimisation but a correctness requirement for the `forbid-wildcard-namespaces` rule?
- **Q23.** Rank the six diagnostic commands in step 4 by how often you would expect each to be the actual root cause, and justify your top choice.
- **Q24.** A PolicyException references `policyName: disallow-hostpath` (no hyphen before `path`) while the policy is `disallow-host-path`. Describe the observable symptom, and explain why Kyverno does not reject the exception at admission time.
- **Q25.** Design question: your organisation wants exceptions to be self-expiring, reviewable and auditable. Sketch the three controls you would combine, naming the concrete mechanism for each.

---

## Cleanup

```bash
kubectl delete -f govern-policy-exceptions.yaml --ignore-not-found
kubectl delete polex --all -A
kubectl delete clusterpolicy --all
kind delete cluster --name kca-62
```

---

## Sources

- Kyverno documentation — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno documentation index: <https://kyverno.io/docs/>
- Kyverno installation and container flag customization: <https://kyverno.io/docs/installation/customization/>
- Kyverno CLI (`apply`, `test`): <https://kyverno.io/docs/kyverno-cli/>
- Kyverno Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno cleanup / TTL-based deletion: <https://kyverno.io/docs/writing-policies/cleanup/>
- Kyverno source and release notes: <https://github.com/kyverno/kyverno>
- Kubernetes Pod Security Standards: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Kubernetes RBAC reference: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
- Kubernetes admission webhook reference (`failurePolicy`): <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- KCA curriculum: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** The flag must be set on both the **admission controller** (which evaluates exceptions at request time) and the **background/reports controller** (which evaluates them during periodic scans and when producing PolicyReports). If only the admission controller has it, workloads are admitted correctly but background scans keep emitting `fail` for the exempted resources — your dashboards show violations for Pods the cluster deliberately allows. The Helm value sets it on all relevant controllers; a hand-patched Deployment usually does not.

**Q2.** Namespacing gives you an RBAC handle. A cluster-scoped exception kind would be governable only by ClusterRole, an all-or-nothing grant. Because it is namespaced, you can (a) delegate exception authorship per team via Role/RoleBinding, or (b) centralise it in one namespace and restrict Kyverno to that namespace with `--exceptionNamespace`. Note the asymmetry is intentional: the *policy* is cluster-wide because it is a cluster-wide guarantee; the *exception* is namespaced because it is a scoped, delegated, revocable waiver.

**Q3.** (1) The feature is disabled, so the CRD was never installed — `kubectl get polex` would actually error rather than print `No resources found`, so more precisely: the CRD exists but the teammate applied to a different cluster/context. (2) The teammate applied a `v2alpha1`/`v2beta1` manifest that was rejected, or applied it and a TTL/cleanup policy already deleted it. A third real cause: they applied it to a namespace excluded by Kyverno's `resourceFilters`, or their `kubectl` context points at a different cluster. The command shown is `-A`, so a namespace mistake alone would not explain it.

**Q4.** Kyverno's **auto-gen** feature. When a rule matches `Pod`, Kyverno synthesises equivalent rules against the Pod controllers (`Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`), naming them `autogen-<rule>` and `autogen-cronjob-<rule>`. The consequence for exceptions: an exception listing only `host-path` covers bare Pods but **not** the controller path — the DaemonSet's own admission request is evaluated by `autogen-host-path`, which is not exempted, so the workload is still blocked.

**Q5.** The `-fail` suffix identifies the webhook configured with `failurePolicy: Fail`. If the Kyverno admission controller becomes unreachable, the API server treats the webhook call error as a denial, so matched resource creations and updates are rejected cluster-wide. This is the correct default for a security control (fail closed), but it makes Kyverno availability a hard dependency for workload admission — which is why production installs run multiple replicas with a PodDisruptionBudget, and why `kyverno` and `kube-system` are in `resourceFilters` so Kyverno cannot deadlock itself.

**Q6.** Because the failing rule name is not always the rule name you authored. Auto-gen rewrites it (`autogen-host-path`), and `ruleNames` matching is exact-string plus wildcard — a mismatch produces **no error at all**, just an exception that never fires. The denial message is the ground truth of what Kyverno evaluated.

**Q7.** `spec.match` determines applicability. The exception's own namespace does **not** need to equal the target's namespace, and by default an exception in any namespace can target any namespace. The exception's own namespace matters for exactly two things: RBAC (who may create it) and `--exceptionNamespace` (whether Kyverno honours it at all).

**Q8.** `pass` means the rule ran and the resource satisfied it. `skip` means the rule did not run — the guarantee was waived. Collapsing them destroys the ability to answer "how many hostPath waivers are live, and who owns them?" A dashboard that reports 100% pass while 40 resources are skipped is reporting compliance theatre. `skip` is the metric that should have an owner, a ticket and a burn-down.

**Q9.** The DaemonSet's admission request is evaluated by the auto-generated rule `autogen-host-path`, which the exception does not list, so the DaemonSet is denied. Fix: add both `autogen-host-path` to `ruleNames` **and** `DaemonSet` to `match.any[].resources.kinds`. Both are required — the rule-name list and the kind list are independent filters.

**Q10.** Annotations are part of the API object, so they are queryable (`kubectl get polex -A -o custom-columns=...`), preserved through GitOps sync and `kubectl get -o yaml`, visible to admission policy (Exercise 8 enforces their presence), and exportable to an audit system. A YAML comment exists only in the source file and is discarded by the API server — the cluster has no record of why the waiver exists.

**Q11.** Pinning `policyName` limits the exception to one policy today, but policies grow rules. `ruleNames: ["*"]` silently extends the waiver to every rule added to that policy in the future — including rules written after the exception was reviewed and approved. It converts a reviewed, bounded decision into an open-ended one. The explicit list forces a new review when scope changes.

**Q12.** `autogen-host-path` evaluates the **DaemonSet** admission request (the controller object, whose `spec.template.spec` carries the volumes). `host-path` evaluates the **Pod** admission requests created by the DaemonSet controller. Both paths must be exempted, which is why the exception lists both kinds and both rule names — and it is also why Kyverno generates the autogen rules at all: blocking only the Pod would produce a DaemonSet stuck in a permanent create-fail loop with no clear signal.

**Q13.** Background scans have no `AdmissionRequest`. Variables under `request.*` — including `request.object`, `request.operation` and `request.userInfo` — are unavailable, so a condition referencing them cannot be evaluated during a scan. Practically: the exception may apply at admission but not during background scanning, producing `fail` in reports for a resource that was legitimately admitted. Prefer `match` selectors (namespaces, names, label selectors) over `conditions` when the policy has `background: true`.

**Q14.** Creating a PolicyException is an ordinary API write governed by RBAC and any admission policy over that kind. Being *effective* is a Kyverno runtime decision: at evaluation time, Kyverno reads exceptions only from the namespace named by `--exceptionNamespace`. The flag is a controller-side filter, not a webhook, so there is nothing to produce an admission error — the object is stored and simply ignored. This is a real operational hazard: the exception looks applied, `kubectl get polex` shows it, and it does nothing. Pair the flag with the Exercise 8 meta-policy (or an RBAC restriction) so the ignored case cannot be created in the first place.

**Q15.** Grant a `Role` in `kyverno-exceptions` with `apiGroups: ["kyverno.io"]`, `resources: ["policyexceptions"]`, verbs `get,list,watch,create,update,patch,delete`, bound to the platform team's group. Grant **no** ClusterRole over `clusterpolicies` or `policies` — those stay with a separate policy-owner group, ideally write-only through GitOps. The separation matters: the exception authors can waive a control for a specific workload but cannot weaken or delete the control itself, so the audit trail of "what the rule is" stays independent of "who was let off".

**Q16.** *Advantage:* every exception carries a reviewed commit, an author identity and a diff — provenance the cluster API cannot give you, plus trivial rollback. *Residual risk:* it is a process control, not a technical one. Any principal with direct API write access (break-glass admin, a compromised controller ServiceAccount, `kubectl apply` in an incident) bypasses Git entirely, and the drift is invisible unless the GitOps controller is configured to prune and self-heal. Defence in depth: GitOps as the only *intended* path, plus `--exceptionNamespace` and RBAC so the unintended path is also closed.

**Q17.** (a) waives exactly one control (`Capabilities`), for one image pattern, for one field, for one value — `NET_ADMIN`. Every other Baseline control, and every other capability, remains enforced. (b) waives the **entire `baseline` rule** for the matched resources: hostPID, hostNetwork, privileged containers, hostPath volumes, unsafe sysctls — the whole profile. (b) is the difference between a waiver and a hole.

**Q18.** The trailing `*` matches any tag *and* any longer repository path that shares the prefix — `docker.io/library/nginx-evil`, `docker.io/library/nginxproxy:latest`, and every future tag of nginx including ones not yet built. Tighten by pinning the full reference, ideally by digest: `docker.io/library/nginx@sha256:...`, or at minimum an exact tag `docker.io/library/nginx:1.27`. Pair it with an image-verification policy so the digest is attested, otherwise the tag is mutable and the pin is cosmetic.

**Q19.** Exceptions accumulate monotonically because the cost of granting one is paid immediately and the cost of keeping one is paid by nobody. The workload that needed the waiver gets deleted, refactored or fixed, but the exception outlives it, still matching by wildcard. Over a year the exception set becomes a shadow policy nobody reviewed as a whole. TTL labels, mandatory ticket references and a periodic report of live `skip` results convert the default from "permanent unless someone notices" to "expires unless someone renews".

**Q20.** They are different layers. The `RESULT` column reports whether the **test assertion** held, not whether the policy allowed the resource. Row 2 asserts `result: fail` (the rogue Pod must be blocked); the CLI observed a policy failure, the assertion matched, so the *test* passes. Confusing the two leads people to "fix" a green suite that is correctly asserting a denial.

**Q21.** `kyverno test` verifies behaviour against the resources you chose to include; it cannot verify **scope** — it has no notion of the resources you did *not* list, so an over-broad exception that also waives ten other namespaces produces an identical green run. That is a governance property, not a behavioural one, and it is caught by Exercise 8's meta-policy (`forbid-wildcard-namespaces`, `require-provenance`) enforced at admission, plus the `--exceptionNamespace` restriction from Exercise 5. The general lesson: unit tests prove the exception does what you meant; admission policy proves it does *only* that.

**Q22.** `forbid-wildcard-namespaces` reads `{{ request.object.spec.match... }}`. During a background scan there is no `AdmissionRequest`, so `request.object` is undefined and the rule would either error or evaluate against an empty value and produce meaningless report entries. Setting `background: false` declares the rule admission-only, which is both accurate and prevents a stream of `error` results in the ClusterPolicyReport.

**Q23.** Expected frequency, most to least: (4) missing `autogen-*` rule names — the most common by a wide margin, because it looks correct and fails silently; (3) `policyName` typo — same silent-failure class; (1) the feature flag missing on the background controller, which produces the "works at admission, fails in reports" split; (2) exception in the wrong namespace once `--exceptionNamespace` is set; (6) report staleness mistaken for a broken exception; (5) logs, which are where you go once the first four are ruled out. Top choice is (4) because auto-gen is invisible in the manifest you wrote — nothing in your YAML hints that `autogen-host-path` exists.

**Q24.** Symptom: the exception is created successfully, appears in `kubectl get polex`, and the workload is still denied — with no error, warning or event pointing at the exception. Kyverno does not reject it because `policyName` is a free-form string reference, not an object reference validated by the API server; the policy it names may legitimately not exist yet (GitOps ordering, policy applied after the exception). Rejecting unresolved names would break ordering-independent apply. Mitigation: assert the pairing in CI with `kyverno test` (Exercise 7), or add a meta-policy rule using a context lookup to confirm the referenced ClusterPolicy exists.

**Q25.** Three complementary controls:
1. **Self-expiring** — a `cleanup.kyverno.io/ttl` label on every PolicyException, enforced as mandatory by the meta-policy of Exercise 8, with the Kyverno cleanup controller deleting expired ones. Renewal requires a new commit, so silence revokes rather than extends.
2. **Reviewable** — exceptions live in Git alongside the workload manifest, `--exceptionNamespace` plus RBAC makes GitOps the only write path, and `kyverno test` in CI asserts both the intended `skip` and at least one neighbouring `fail` to bound the scope.
3. **Auditable** — mandatory `owner`/`ticket` annotations enforced at admission, plus a scheduled report over `PolicyReport` results filtered to `result: skip`, joined to those annotations. That report — not the count of live exception objects — is the number the security review reads, because it measures waived guarantees on real resources rather than YAML that may match nothing.

</details>