# KCA 5.3 — Background Scans: Guided Exercises

> **Scope.** These exercises drill the mechanics of Kyverno's *background scanning* subsystem: which controller performs it, what it produces, what it refuses to evaluate, how it is scheduled and bounded, and how it fails silently in production. Every step is executable against a throwaway cluster.
>
> **Version anchor.** Written against **Kyverno 1.13.x (Helm chart 3.3.x)** on Kubernetes 1.29+. Where a field or CRD moved between releases, the step says so and asks you to *discover* the served version rather than trust the text. Verify your own build before blaming a command:
>
> ```bash
> kubectl -n kyverno get deploy kyverno-reports-controller \
>   -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
> ```
>
> **Output convention.** Blocks marked `# (abridged)` are trimmed for readability; report names are resource UIDs and will never match yours literally. Never hard-code a report name.

---

## Lab environment

```bash
kind create cluster --name kca-53

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version '>=3.3.0 <3.4.0' \
  --set features.backgroundScan.backgroundScanInterval=2m \
  --wait
```

A 2-minute interval is a lab setting. The production default is `1h`; Exercise 7 explains why shortening it is not free.

If your chart repo does not carry 3.3.x, drop `--version` and record whatever resolves:

```bash
helm -n kyverno list
```

```
NAME     NAMESPACE  REVISION  STATUS    CHART           APP VERSION
kyverno  kyverno    1         deployed  kyverno-3.3.4   v1.13.2
```

---

## Exercise 1 — Map the reporting plane before you touch a policy

Background scanning is **not** performed by the admission webhook, and it is **not** performed by the controller whose name contains the word "background". Prove that to yourself before anything else.

1. List the Kyverno deployments:

   ```bash
   kubectl -n kyverno get deploy
   ```

   ```
   NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller    1/1     1            1           95s
   kyverno-background-controller   1/1     1            1           95s
   kyverno-cleanup-controller      1/1     1            1           95s
   kyverno-reports-controller      1/1     1            1           95s
   ```

2. Dump the flags of the reports controller:

   ```bash
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | tr -d '[]"'
   ```

   ```
   --caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca
   --tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair
   --backgroundScan=true
   --admissionReports=true
   --aggregateReports=true
   --policyReports=true
   --backgroundScanWorkers=2
   --backgroundScanInterval=2m
   --skipResourceFilters=true
   --enableConfigMapCaching=true
   --loggingFormat=text
   --v=2
   ```

3. Do the same for `kyverno-background-controller` and compare — note that `--backgroundScanInterval` does **not** appear there.

4. Enumerate every reporting API the cluster serves:

   ```bash
   kubectl api-resources --api-group=wgpolicyk8s.io
   kubectl api-resources --api-group=reports.kyverno.io
   ```

   ```
   NAME                   SHORTNAMES   APIVERSION                NAMESPACED   KIND
   clusterpolicyreports   cpolr        wgpolicyk8s.io/v1alpha2   false        ClusterPolicyReport
   policyreports          polr         wgpolicyk8s.io/v1alpha2   true         PolicyReport

   NAME                      SHORTNAMES   APIVERSION              NAMESPACED   KIND
   clusterephemeralreports   cephr        reports.kyverno.io/v1   false        ClusterEphemeralReport
   ephemeralreports          ephr         reports.kyverno.io/v1   true         EphemeralReport
   ```

   > On Kyverno 1.12 and earlier the second group does not exist; you will instead find `admissionreports`, `clusteradmissionreports`, `backgroundscanreports` and `clusterbackgroundscanreports` in the `kyverno.io` group. Run the command, don't assume.

5. Confirm the reporting CRD group is not Kyverno's own invention:

   ```bash
   kubectl get crd policyreports.wgpolicyk8s.io \
     -o jsonpath='{.spec.group}{"\n"}{.metadata.annotations}{"\n"}'
   ```

**Questions**

- **Q1.** Which deployment executes the periodic background scan, and what does `kyverno-background-controller` actually do instead?
- **Q2.** `PolicyReport` lives in the `wgpolicyk8s.io` group, not `kyverno.io`. What is the practical consequence of that for a platform team running more than one policy engine?
- **Q3.** From the flag dump alone: if you set `--backgroundScan=false`, does admission-time validation stop working?

---

## Exercise 2 — Produce your first background scan and dissect a report

The whole point of background scanning is resources that already existed when the policy did not.

1. Create non-compliant workloads **first**:

   ```bash
   kubectl create ns billing
   kubectl -n billing run legacy-api --image=nginx:1.27
   kubectl -n billing create deployment legacy-web --image=nginx:1.27
   ```

2. Confirm the reporting surface is empty — no policies, no reports:

   ```bash
   kubectl get polr,cpolr -A
   ```

   ```
   No resources found
   ```

3. Apply an **Audit** policy:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
     annotations:
       policies.kyverno.io/title: Require team label
       policies.kyverno.io/category: Governance
       policies.kyverno.io/severity: medium
   spec:
     background: true
     admission: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Audit
           message: "The label `team` is required on every Pod."
           pattern:
             metadata:
               labels:
                 team: "?*"
   EOF
   ```

   > **Version note.** `validate.failureAction` is the 1.13+ rule-level field. On 1.12 and earlier use `spec.validationFailureAction: Audit` at policy level instead. Never set both — they conflict.

4. Watch reports appear. Do **not** wait two minutes:

   ```bash
   kubectl get polr -A
   ```

   ```
   # (abridged)
   NAMESPACE     NAME                                   KIND         NAME                          PASS  FAIL  WARN  ERROR  SKIP  AGE
   billing       0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11   Pod          legacy-api                    0     1     0     0      0     6s
   billing       6a1b0f2e-0d2e-4a11-b7e2-9a1d2c3e4f55   Deployment   legacy-web                    0     1     0     0      0     6s
   billing       b3c9a1d7-77aa-4b91-9e21-2f6d7c1a0b34   ReplicaSet   legacy-web-7c9f8b6d5c         0     1     0     0      0     6s
   billing       c81e2a90-1d44-4c0e-8b2a-5f7e9c0d3a12   Pod          legacy-web-7c9f8b6d5c-2xk9n   0     1     0     0      0     6s
   kube-system   1a2b3c4d-...                           Pod          coredns-76f75df574-abcde      0     1     0     0      0     6s
   ...
   ```

5. Read one report in full:

   ```bash
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | select(.scope.name=="legacy-api")' 
   ```

   ```yaml
   # (abridged, rendered as YAML for readability)
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: PolicyReport
   metadata:
     name: 0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11
     namespace: billing
     labels:
       app.kubernetes.io/managed-by: kyverno
     ownerReferences:
       - apiVersion: v1
         kind: Pod
         name: legacy-api
         uid: 0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11
   scope:
     apiVersion: v1
     kind: Pod
     name: legacy-api
     namespace: billing
     uid: 0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11
   results:
     - source: kyverno
       policy: require-team-label
       rule: check-team-label
       result: fail
       scored: true
       category: Governance
       severity: medium
       message: >-
         validation error: The label `team` is required on every Pod.
         rule check-team-label failed at path /metadata/labels/team/
       timestamp:
         seconds: 1770000000
         nanos: 0
   summary:
     pass: 0
     fail: 1
     warn: 0
     error: 0
     skip: 0
   ```

6. Compare the rule names across scopes:

   ```bash
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | "\(.scope.kind)/\(.scope.name)\t\(.results[].rule)"' | sort
   ```

   ```
   Deployment/legacy-web              autogen-check-team-label
   Pod/legacy-api                     check-team-label
   Pod/legacy-web-7c9f8b6d5c-2xk9n    check-team-label
   ReplicaSet/legacy-web-7c9f8b6d5c   autogen-check-team-label
   ```

7. Delete the standalone Pod and re-list reports:

   ```bash
   kubectl -n billing delete pod legacy-api
   kubectl -n billing get polr
   ```

**Questions**

- **Q4.** The scan interval is 2 minutes, yet reports appeared within seconds of `kubectl apply`. What triggered the evaluation, and what is the interval actually for?
- **Q5.** The report for `legacy-api` disappeared the moment the Pod was deleted, and no controller ran a cleanup pass. Which single field in the report's metadata explains that, and why is it a deliberate design choice at cluster scale?
- **Q6.** Why does the Deployment's report cite `autogen-check-team-label` while the Pod's cites `check-team-label`? You authored only one rule.
- **Q7.** `kube-system` is listed in Kyverno's default `resourceFilters`, which excludes it from admission processing. Why are there `fail` results for `kube-system` Pods anyway? (Name the exact flag.)
- **Q8.** The report name is a UID, not a human-readable string. Write the `kubectl` command you would give an SRE to answer "does Pod `X` in namespace `Y` violate anything?" without knowing the report name.

---

## Exercise 3 — The two switches: `background` and `admission`

1. Disable background processing on the existing policy and observe:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"background":false}}'
   sleep 5
   kubectl get polr -A
   ```

   ```
   No resources found
   ```

2. Prove that admission enforcement is untouched — create a violating Pod and inspect its *admission* result:

   ```bash
   kubectl -n billing run probe-a --image=nginx:1.27
   kubectl -n billing get polr -o json | jq -r '.items[] | "\(.scope.name): \(.results[].rule)=\(.results[].result)"'
   ```

   ```
   probe-a: check-team-label=fail
   ```

3. Re-enable background processing and confirm the historical resources come back:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"background":true}}'
   sleep 10
   kubectl get polr -A | wc -l
   ```

4. Now flip the other switch — a **scan-only** policy with no webhook footprint:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"admission":false}}'
   kubectl get validatingwebhookconfigurations | grep kyverno
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules}{"\n"}{end}'
   ```

5. Create another violating Pod and note that it is admitted without a webhook evaluation, yet still appears in reports after the reconcile:

   ```bash
   kubectl -n billing run probe-b --image=nginx:1.27
   sleep 10
   kubectl -n billing get polr -o json | jq -r '.items[] | select(.scope.name=="probe-b") | .results[].result'
   ```

6. Restore the policy:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"admission":true}}'
   ```

**Questions**

- **Q9.** State precisely what `spec.background: false` does and does not do.
- **Q10.** `admission: false, background: true` is the configuration a platform team uses when onboarding a policy to a live cluster. Why is that safer than shipping the same rule with `failureAction: Audit` and `admission: true`?
- **Q11.** With `admission: false`, the Pod rule vanished from the ValidatingWebhookConfiguration. What operational property of Kyverno does that demonstrate, and why does it matter for API-server latency?
- **Q12.** A resource created while the admission controller was unavailable (webhook `failurePolicy: Ignore`) slips into the cluster non-compliant. Which mechanism eventually surfaces it, and what is the worst-case delay?

---

## Exercise 4 — Rules that *cannot* be evaluated in the background

Background scanning has no `AdmissionReview`. There is no user, no operation, no service account. Kyverno refuses such a policy at creation time instead of silently under-reporting.

1. Try to create a policy that depends on the requesting identity while leaving background processing on:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-configmap-authors
   spec:
     background: true
     rules:
       - name: deny-non-platform-authors
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         validate:
           failureAction: Enforce
           message: "{{ request.userInfo.username }} is not allowed to create ConfigMaps here."
           deny:
             conditions:
               all:
                 - key: "{{ request.userInfo.groups }}"
                   operator: AnyNotIn
                   value:
                     - "platform-admins"
   EOF
   ```

   ```
   # (abridged; exact wording varies by release)
   Error from server: error when creating "STDIN": admission webhook "validate-policy.kyverno.svc"
   denied the request: spec.rules[0]: variable {{ request.userInfo.groups }} is not allowed in
   background mode. Set spec.background=false to disable background mode for this policy rule.
   ```

2. Apply the documented fix and confirm acceptance:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-configmap-authors
   spec:
     background: false
     rules:
       - name: deny-non-platform-authors
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         validate:
           failureAction: Enforce
           message: "{{ request.userInfo.username }} is not allowed to create ConfigMaps here."
           deny:
             conditions:
               all:
                 - key: "{{ request.userInfo.groups }}"
                   operator: AnyNotIn
                   value:
                     - "platform-admins"
   EOF
   ```

3. Verify no report scope was ever created for ConfigMaps by this policy:

   ```bash
   kubectl get polr -A -o json | jq -r '[.items[].results[] | select(.policy=="restrict-configmap-authors")] | length'
   ```

   ```
   0
   ```

4. Now confirm the *opposite* case — `request.object` **is** available in background mode. Rewrite the same intent using only resource content and observe that Kyverno accepts `background: true`:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-owner-annotation
   spec:
     background: true
     rules:
       - name: check-owner
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         preconditions:
           all:
             - key: "{{ request.object.metadata.namespace }}"
               operator: Equals
               value: billing
         validate:
           failureAction: Audit
           message: "ConfigMaps in billing must carry annotation owner."
           pattern:
             metadata:
               annotations:
                 owner: "?*"
   EOF

   kubectl -n billing create configmap rates --from-literal=eur=1.0
   sleep 10
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | select(.scope.kind=="ConfigMap") | "\(.scope.name): \(.results[].policy)=\(.results[].result)"'
   ```

**Questions**

- **Q13.** List the variable families that make a rule ineligible for background scanning, and explain the one-line reason all of them share.
- **Q14.** Kyverno rejects the policy at `kubectl apply` time rather than accepting it and skipping it during scans. Argue why that is the correct engineering choice for a policy engine.
- **Q15.** A security team requires that *every* ConfigMap in the cluster be audited for an `owner` annotation, and *also* that only `platform-admins` may create them. How many ClusterPolicies does that take, and why?
- **Q16.** Your policy needs `request.operation`. Is it usable in background mode? What does the scan have to assume about an object that already exists?

---

## Exercise 5 — Enforce, Audit, and `skip` in reports

A common misconception is that `Enforce` policies produce nothing in reports. Disprove it.

1. Switch the label policy to `Enforce` while leaving background on:

   ```bash
   kubectl patch cpol require-team-label --type json \
     -p '[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
   ```

   *(On 1.12 and earlier: `kubectl patch cpol require-team-label --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'`.)*

2. Confirm new violating Pods are now blocked:

   ```bash
   kubectl -n billing run probe-c --image=nginx:1.27
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   policy Pod/billing/probe-c for resource violation:

   require-team-label:
     check-team-label: 'validation error: The label `team` is required on every Pod. ...'
   ```

3. Now check what happened to the *pre-existing* violators:

   ```bash
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | "\(.scope.kind)/\(.scope.name): \(.results[].result)"' | sort | uniq -c
   ```

4. Grant an exception and watch the result class change from `fail` to `skip`. First make sure exceptions are enabled:

   ```bash
   helm show values kyverno/kyverno | grep -A6 'policyExceptions'
   helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
     --set features.policyExceptions.enabled=true --wait
   kubectl api-resources | grep -i policyexception
   ```

   ```
   policyexceptions   polex   kyverno.io/v2   true   PolicyException
   ```

5. Apply the exception (use the API version your cluster reported):

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v2
   kind: PolicyException
   metadata:
     name: legacy-web-exemption
     namespace: billing
   spec:
     exceptions:
       - policyName: require-team-label
         ruleNames:
           - check-team-label
           - autogen-check-team-label
     match:
       any:
         - resources:
             namespaces:
               - billing
             names:
               - "legacy-web*"
   EOF

   sleep 10
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | "\(.scope.kind)/\(.scope.name): \(.results[].result)"' | sort
   ```

**Questions**

- **Q17.** An `Enforce` policy blocks *new* violations. What does it do to the 400 non-compliant Deployments that already exist, and which artifact is the only evidence of them?
- **Q18.** Why did the exception have to name `autogen-check-team-label` in addition to `check-team-label`?
- **Q19.** In the PolicyReport summary, what is the semantic difference between `skip`, `warn` and `error`? Which of the three indicates a broken policy rather than a non-compliant resource?
- **Q20.** A compliance dashboard counts `fail` results to compute a score. What does an unnoticed `skip` do to that number, and how would you detect exception abuse?

---

## Exercise 6 — Intermediate reports and aggregation

`PolicyReport` is the *output*. It is assembled from short-lived intermediate objects; understanding them is what lets you debug a scan that "produces nothing".

1. Watch the ephemeral layer in one terminal:

   ```bash
   kubectl get ephr -A -w
   ```

   *(Kyverno ≤1.12: `kubectl get backgroundscanreports,admissionreports -A -w`.)*

2. In a second terminal, force a full re-evaluation by touching the policy:

   ```bash
   kubectl annotate cpol require-team-label kca.local/rescan="$(date +%s)" --overwrite
   ```

3. Observe objects being created and then consumed within seconds:

   ```
   # (abridged)
   NAMESPACE   NAME                                   AGE
   billing     6a1b0f2e-0d2e-4a11-b7e2-9a1d2c3e4f55   0s
   billing     c81e2a90-1d44-4c0e-8b2a-5f7e9c0d3a12   0s
   billing     6a1b0f2e-0d2e-4a11-b7e2-9a1d2c3e4f55   2s   # deleted after aggregation
   ```

4. Inspect one before it disappears, and note the labels that carry the policy hash:

   ```bash
   kubectl -n billing get ephr -o json \
     | jq -r '.items[0].metadata.labels' 
   ```

5. Check the aggregation toggle and the chunking flag:

   ```bash
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'aggregate|chunk|reports'
   ```

**Questions**

- **Q21.** Describe the data flow from "policy changed" to "PolicyReport updated", naming every object in between.
- **Q22.** The intermediate reports carry a hash of the policy set in their labels. What optimisation does that enable, and what happens to that optimisation when you edit a policy every few minutes in a CI loop?
- **Q23.** If you see `ephemeralreports` accumulating in a namespace and never being deleted, which controller do you investigate, and what are the two most likely causes?

---

## Exercise 7 — What the scan costs: interval, workers, and resource filters

1. Read the current exclusion list used by admission:

   ```bash
   kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | head -20
   ```

   ```
   # (abridged)
   [Event,*,*]
   [*/*,kube-system,*]
   [*/*,kube-public,*]
   [*/*,kube-node-lease,*]
   [Node,*,*]
   [APIService,*,*]
   [TokenReview,*,*]
   ...
   ```

2. Confirm the contradiction you observed in Exercise 2 — `kube-system` is filtered, yet reported:

   ```bash
   kubectl -n kube-system get polr --no-headers | wc -l
   ```

3. Make the background scan honour the filters. Discover the value name first, then set it:

   ```bash
   helm show values kyverno/kyverno | grep -A8 'backgroundScan:'
   helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
     --set features.backgroundScan.skipResourceFilters=false --wait
   ```

   Without Helm, patch the flag directly (last occurrence wins, and the change is reverted by the next `helm upgrade`):

   ```bash
   kubectl -n kyverno patch deploy kyverno-reports-controller --type json \
     -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--skipResourceFilters=false"}]'
   ```

4. Re-check after the rollout:

   ```bash
   kubectl -n kyverno rollout status deploy/kyverno-reports-controller
   sleep 20
   kubectl -n kube-system get polr --no-headers | wc -l
   kubectl -n billing get polr --no-headers | wc -l
   ```

5. Exclude a namespace you own and watch its reports drain:

   ```bash
   FILTERS=$(kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}')
   kubectl -n kyverno patch cm kyverno --type merge \
     -p "{\"data\":{\"resourceFilters\":\"${FILTERS}[Pod,billing,*]\"}}"
   sleep 30
   kubectl -n billing get polr -o json | jq -r '[.items[] | select(.scope.kind=="Pod")] | length'
   ```

6. Size the workload. Count what a full scan has to evaluate in this cluster:

   ```bash
   kubectl get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -A --no-headers | wc -l
   ```

7. Restore defaults before continuing:

   ```bash
   kubectl -n kyverno patch cm kyverno --type merge -p "{\"data\":{\"resourceFilters\":\"${FILTERS}\"}}"
   helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
     --set features.backgroundScan.skipResourceFilters=true --wait
   ```

**Questions**

- **Q24.** Explain `--skipResourceFilters=true` in one sentence, and why the default is `true` even though it produces results for namespaces the admission controller ignores.
- **Q25.** A cluster holds 60,000 Pods matched by 40 policies. You set `--backgroundScanInterval=1m` to "get fresher dashboards". Enumerate the three resource pressures that creates and where the first failure will appear.
- **Q26.** `--backgroundScanWorkers` defaults to `2`. Raising it shortens a scan cycle — what is the constraint that stops you from raising it to 64?
- **Q27.** Editing the `kyverno` ConfigMap changed behaviour without a pod restart. Which flag in Exercise 1's dump tells you the ConfigMap is watched rather than read once, and what is the risk if it were not?
- **Q28.** Your organisation must not have any reporting object for a regulated namespace, not even a `pass` result. Which of the two mechanisms in this exercise achieves that, and which one does not?

---

## Exercise 8 — The silent failure: RBAC and custom resources

Kyverno 1.10+ ships least-privilege RBAC. It cannot scan a CRD it was never granted access to, and the scan does not fail loudly.

1. Create a CRD and two instances, one compliant, one not:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: widgets.example.io
   spec:
     group: example.io
     scope: Namespaced
     names:
       kind: Widget
       listKind: WidgetList
       plural: widgets
       singular: widget
     versions:
       - name: v1
         served: true
         storage: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 properties:
                   size:
                     type: string
   EOF

   kubectl -n billing apply -f - <<'EOF'
   apiVersion: example.io/v1
   kind: Widget
   metadata:
     name: good-widget
   spec:
     size: large
   ---
   apiVersion: example.io/v1
   kind: Widget
   metadata:
     name: bad-widget
   spec: {}
   EOF
   ```

2. Apply a policy that matches them:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-widget-size
   spec:
     background: true
     rules:
       - name: check-size
         match:
           any:
             - resources:
                 kinds:
                   - example.io/v1/Widget
         validate:
           failureAction: Audit
           message: "Widgets must declare spec.size."
           pattern:
             spec:
               size: "?*"
   EOF
   ```

3. Wait past one interval and look for results — there are none:

   ```bash
   sleep 130
   kubectl get polr -A -o json | jq -r '[.items[].results[] | select(.policy=="require-widget-size")] | length'
   ```

   ```
   0
   ```

4. Diagnose from the controller logs and by asking the API server directly:

   ```bash
   kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=50 | grep -i -E 'widget|forbidden|permission'
   kubectl auth can-i list widgets.example.io \
     --as=system:serviceaccount:kyverno:kyverno-reports-controller
   ```

   ```
   no
   ```

5. Grant access through the aggregation label — never by editing Kyverno's own ClusterRoles:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:reports-controller:widgets
     labels:
       rbac.kyverno.io/aggregate-to-reports-controller: "true"
   rules:
     - apiGroups: ["example.io"]
       resources: ["widgets"]
       verbs: ["get", "list", "watch"]
   EOF

   kubectl auth can-i list widgets.example.io \
     --as=system:serviceaccount:kyverno:kyverno-reports-controller
   ```

6. Confirm the results now materialise:

   ```bash
   kubectl annotate cpol require-widget-size kca.local/rescan="$(date +%s)" --overwrite
   sleep 20
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | select(.scope.kind=="Widget") | "\(.scope.name): \(.results[].result)"'
   ```

   ```
   bad-widget: fail
   good-widget: pass
   ```

**Questions**

- **Q29.** Why did this failure produce *zero* results rather than an `error` result in a report? Which reporting assumption does that break for an auditor?
- **Q30.** You granted the permission with a new ClusterRole carrying `rbac.kyverno.io/aggregate-to-reports-controller: "true"` instead of editing `kyverno:reports-controller`. Give two concrete reasons.
- **Q31.** The same CRD is also matched by an `Enforce` policy at admission. Does the missing RBAC break admission-time validation too? Explain the difference in how the object reaches Kyverno in each path.
- **Q32.** Write the one-line check you would put in a platform CI pipeline to catch this class of bug for every kind referenced by any ClusterPolicy.

---

## Exercise 9 — Observability, and an offline cross-check

1. Scrape the reports controller's metrics:

   ```bash
   kubectl -n kyverno port-forward deploy/kyverno-reports-controller 8000:8000 >/dev/null 2>&1 &
   sleep 2
   curl -s localhost:8000/metrics | grep -i 'kyverno_policy_results_total' | grep -i background | head
   ```

   ```
   # (abridged; label casing varies by release — grep case-insensitively)
   kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_namespace="billing",rule_execution_cause="background_scan",rule_name="check-team-label",rule_result="fail",rule_type="validate"} 3
   ```

2. Compare the two execution causes side by side:

   ```bash
   curl -s localhost:8000/metrics | grep -o 'rule_execution_cause="[^"]*"' | sort | uniq -c
   curl -s localhost:8000/metrics | grep -i 'kyverno_policy_execution_duration_seconds_sum' | head -3
   ```

3. Raise log verbosity temporarily and read one scan cycle:

   ```bash
   kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=100 | grep -iE 'background|resync|scan'
   ```

4. Cross-check the cluster's own answer with the Kyverno CLI, which evaluates the same rules outside the cluster:

   ```bash
   kyverno version
   kubectl get cpol require-team-label -o yaml > /tmp/require-team-label.yaml
   kyverno apply /tmp/require-team-label.yaml --cluster --namespace billing --policy-report
   ```

   ```
   # (abridged)
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: ClusterPolicyReport
   metadata:
     name: clusterpolicyreport
   results:
     - policy: require-team-label
       rule: autogen-check-team-label
       result: fail
       resources:
         - apiVersion: apps/v1
           kind: Deployment
           name: legacy-web
           namespace: billing
   summary:
     pass: 0
     fail: 2
     skip: 0
     warn: 0
     error: 0
   ```

5. Kill the port-forward:

   ```bash
   kill %1
   ```

**Questions**

- **Q33.** Which metric label lets you build a dashboard panel that shows *only* drift found by scans, excluding anything caught at admission time?
- **Q34.** `kyverno apply --cluster --policy-report` produced a report resembling the in-cluster one. Name two things it cannot reproduce, and one situation where the CLI is nevertheless the right tool.
- **Q35.** You alert on `kyverno_policy_results_total{rule_result="fail"}` increasing. A team deletes 300 non-compliant Pods, and the counter goes flat while the PolicyReports empty out. Why is a counter the wrong signal here, and what should the alert read instead?

---

## Cleanup

```bash
kubectl delete cpol require-team-label require-widget-size restrict-configmap-authors require-owner-annotation --ignore-not-found
kubectl -n billing delete polex legacy-web-exemption --ignore-not-found
kubectl delete crd widgets.example.io --ignore-not-found
kubectl delete clusterrole kyverno:reports-controller:widgets --ignore-not-found
kubectl delete ns billing --ignore-not-found
kubectl get polr,cpolr -A
kind delete cluster --name kca-53
```

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** `kyverno-reports-controller` performs background scanning: it periodically and event-drivenly re-evaluates existing resources against policies and writes `PolicyReport`/`ClusterPolicyReport`. `kyverno-background-controller` is unrelated to scanning — it processes `generate` rules and `mutate` rules targeting existing resources (mutate-existing), i.e. it *changes* cluster state asynchronously. The naming collision is the single most common confusion in this domain: reports never mutate anything, and the background controller never writes a policy report.

**Q2.** `wgpolicyk8s.io` is the Kubernetes Policy WG's common reporting API, not a Kyverno-proprietary type. Any consumer — Policy Reporter UI, a Grafana pipeline, an OPA/Gatekeeper exporter, a compliance job — reads one schema, and the `results[].source` field (`kyverno`) distinguishes producers. A dashboard written against `PolicyReport` keeps working if a second engine is added or Kyverno is swapped out.

**Q3.** No. `--backgroundScan` only governs the periodic scanning of existing resources by the reports controller. Admission-time validation is performed by `kyverno-admission-controller` through the webhook and is entirely independent. You can have enforcement with no reporting, or reporting with no enforcement.

**Q4.** The reports controller watches policies and resources through informers. Any policy create/update/delete, and any change to a matched resource, triggers immediate re-evaluation of the affected scope. `--backgroundScanInterval` is a *full resync*: it re-evaluates everything even when nothing in etcd changed. That matters because a rule's verdict can depend on inputs outside the cluster — image signatures and attestations (`verifyImages`), `apiCall` and external service context, registry state — and because it is the safety net for events missed while the controller was down or overloaded.

**Q5.** `metadata.ownerReferences` points at the scanned resource with its UID. The report is garbage-collected by Kubernetes itself when the owner is deleted — no Kyverno code runs, no reconcile loop leaks. At cluster scale this is what keeps report count bounded by resource count instead of growing monotonically, and it makes a stale report structurally impossible for deleted objects.

**Q6.** Auto-gen. When a policy matches `Pod`, Kyverno automatically synthesises equivalent rules against Pod controllers (`Deployment`, `DaemonSet`, `StatefulSet`, `Job`, `CronJob`, and here `ReplicaSet`), prefixed `autogen-` (`autogen-cronjob-` for CronJob), rewriting the path to `spec.template`. Background scan evaluates those generated rules too, so one authored rule yields results at every level of the ownership chain. Consequence: violation counts are inflated relative to distinct workloads — deduplicate by top-level owner before reporting a compliance figure. Auto-gen behaviour is controlled with the `pod-policies.kyverno.io/autogen-controllers` annotation.

**Q7.** `--skipResourceFilters=true` (the default). `resourceFilters` in the `kyverno` ConfigMap excludes resources from *admission* processing; the background scan deliberately ignores that exclusion list so that visibility is not silently reduced by a performance tuning knob. Exercise 7 flips it.

**Q8.** Select by scope rather than name:
```bash
kubectl -n Y get polr -o json | jq -r '.items[] | select(.scope.name=="X") | .results[] | "\(.policy)/\(.rule)=\(.result)"'
```
Report names are the target resource's UID and must be treated as opaque.

**Q9.** It excludes the policy from background scanning: no results for existing resources, and existing results contributed by that policy are removed from reports. It does **not** disable the policy — admission-time evaluation (block or audit-on-admission) continues unchanged. It is required for any rule using AdmissionReview-only data, and it is also a legitimate performance lever for expensive rules on huge resource sets.

**Q10.** `admission: false, background: true` removes the rule from the webhook entirely, so a policy bug cannot add latency to, or fail, an API request — including during a Kyverno outage. `Audit` with `admission: true` still routes every matching request through the webhook: the policy cannot block, but a slow rule or a `failurePolicy: Fail` webhook can still degrade or break the API path. Scan-only onboarding gives you the violation inventory with zero blast radius on the request path.

**Q11.** Kyverno manages its webhook configurations dynamically, deriving the `rules` (resources, operations, scope) from the set of installed policies. Fewer matched kinds means fewer intercepted API requests, so the API server pays no network round-trip for objects no policy cares about. A cluster with only `admission: false` policies has an effectively empty resource webhook.

**Q12.** Background scanning. Worst case is one full `--backgroundScanInterval` (default `1h`) after the controller becomes healthy — unless the resource is subsequently modified or a policy changes, either of which triggers an immediate re-evaluation. This is exactly why an `Ignore` failure policy is tolerable in production: the webhook is best-effort, the scan is the backstop.

**Q13.** Anything sourced from the `AdmissionReview` rather than from the stored object: `request.userInfo.*` (username, groups, uid), `request.roles`, `request.clusterRoles`, `serviceAccountName`, `serviceAccountNamespace`, and the request-shaped `request.oldObject`. Shared reason: a background scan reads objects from the API server / informer cache; there is no requester, no request, and no prior object version to compare against. `request.object` *is* populated — with the resource as it currently exists.

**Q14.** A policy engine's value is that its report is complete. If Kyverno accepted the policy and silently skipped it during scans, the resulting `PolicyReport` would show no violations for a rule that was never evaluated — indistinguishable from full compliance. Failing at admission converts a silent coverage gap into a loud authoring error at the moment the human can fix it, and forces the author to state the trade-off explicitly with `background: false`.

**Q15.** Two. The identity check needs `request.userInfo`, which forces `background: false`; the annotation audit must run in background to cover pre-existing ConfigMaps. They cannot coexist in one policy because `background` is a policy-level (not rule-level) switch — setting it false to satisfy the first rule would strip background coverage from the second.

**Q16.** `request.operation` is an AdmissionReview field and is not meaningful during a scan; rules that branch on it belong in `background: false` policies. Conceptually a background scan can only ask "is this object, as it exists now, compliant?" — it has no notion of CREATE vs UPDATE vs DELETE, and no `oldObject` to diff against, so any transition-based rule (immutability checks, "field may not change") is admission-only by construction.

**Q17.** Nothing — `Enforce` is evaluated at admission and only affects requests arriving after the policy exists. The 400 existing Deployments keep running unchanged. Their `fail` results in `PolicyReport` objects, produced by the background scan, are the only evidence they violate the policy; remediation is a separate act (mutate-existing rules, or a human/GitOps change). This is the reason background scanning exists at all.

**Q18.** Because the Deployment and ReplicaSet results are produced by auto-generated rules, whose names differ from the authored rule. A `PolicyException` matches on `policyName` + `ruleNames`, so exempting only `check-team-label` would clear the Pod result while leaving the Deployment's `autogen-check-team-label` failing. (Some releases accept a wildcard such as `autogen-*`; verify against your version rather than assuming.)

**Q19.** `skip` — the rule was not applied to this resource (a matching `PolicyException`, or preconditions/`exclude` that did not match): compliance was not evaluated. `warn` — the rule failed but is non-scored/audit-severity, so it does not count against the score. `error` — Kyverno could not evaluate the rule: variable substitution failed, an `apiCall`/external context timed out, a JMESPath expression was invalid. Only `error` indicates a broken policy rather than a non-compliant resource, and it is the class that must page someone.

**Q20.** A `skip` silently improves the score: the resource disappears from `fail` without becoming compliant. Detect it by trending `skip` counts alongside `fail`, and by inventorying `PolicyException` objects (`kubectl get polex -A`) with an expiry/review process — exceptions are the ordinary way a compliance metric gets quietly falsified.

**Q21.** Policy change → reports controller's policy informer fires → it enumerates matching resources (metadata informers) and evaluates each → per-resource intermediate objects are written (`EphemeralReport`/`ClusterEphemeralReport` on 1.13+, `BackgroundScanReport`/`AdmissionReport` and their cluster variants earlier) → the aggregation controller merges each resource's admission-sourced and scan-sourced results into the final `PolicyReport`/`ClusterPolicyReport` owned by that resource → the intermediate object is deleted. The split exists so that producers (webhook, scanner) can write independently and cheaply while a single consumer owns the final object.

**Q22.** The hash identifies the exact policy set a resource was last evaluated against. If the hash is unchanged, the resource does not need re-evaluation, which is what makes a resync over 60,000 objects cheap. Editing policies in a tight loop invalidates the hash for every matched resource on every edit, forcing a full re-evaluation each time — a CI job that reapplies all ClusterPolicies every few minutes can keep the reports controller permanently saturated even though nothing changed semantically.

**Q23.** The reports controller (aggregation is its job). Most likely: (a) it is crash-looping, OOMKilled, or wedged — check `kubectl -n kyverno get pods` and its memory limit; (b) aggregation is disabled or misconfigured (`--aggregateReports=false`, `--policyReports=false`), or its RBAC to create/update `policyreports` was removed. A distant third: the API server is rejecting oversized reports, in which case `--reportsChunkSize` and the log will say so.

**Q24.** It tells the background scanner to ignore the `resourceFilters` exclusion list. The default is `true` so that a knob added to protect the *admission* hot path (skipping `Event`, `Node`, `kube-system`, etc. to cut webhook traffic) does not silently blind your *compliance reporting* — visibility and enforcement are tuned independently, and a filtered namespace is usually one you still want audited.

**Q25.** (1) API server / etcd read pressure — a full resync lists and re-evaluates every matched object every minute; (2) reports controller CPU, since 40 policies × 60,000 resources is 2.4M rule evaluations per cycle, which will not finish in 60 s with 2 workers, so cycles overlap and the work queue grows without bound; (3) write amplification — every changed result rewrites a `PolicyReport` through the API server, and etcd write throughput plus watch fan-out to every report consumer becomes the bottleneck. First visible failure is normally the reports controller being OOMKilled (it holds the informer cache and in-flight reports), followed by API server latency SLO alerts.

**Q26.** Each worker holds decoded resources and evaluation context in memory, and every worker競 competes for the same API server read/write budget. Raising workers raises the reports controller's memory footprint roughly linearly and pushes request rate at the API server; past a point you trade a shorter scan cycle for OOMKills and API-server throttling that lengthen it again. Scale workers together with the memory limit, and prefer a longer interval over more workers when the cluster is large.

**Q27.** `--enableConfigMapCaching=true` — Kyverno watches and caches the ConfigMap rather than reading it once at startup, so edits take effect within seconds. Without a watch you would need a rollout of every controller to change filters, which during an incident (e.g. excluding a runaway kind to shed load) is exactly the wrong time to restart the policy engine.

**Q28.** `resourceFilters` **combined with** `--skipResourceFilters=false` achieves it: the scanner then honours the exclusion and writes no report objects for that namespace. `resourceFilters` alone does not — with the default `skipResourceFilters=true` you keep getting a full report set for the "excluded" namespace. Note the trade-off: turning the flag off also means genuine violations there become invisible.

**Q29.** The scan could not list the kind at all, so no resource ever entered the evaluation loop — there was nothing to attach an `error` result to. An `error` result requires a resource to report against; a missing *list* permission removes the resource set itself. The broken assumption is the auditor's: "no failing results" was read as "compliant", when it actually meant "never looked". Absence of results is not evidence of compliance — always cross-check that the expected scopes exist (`kubectl get polr -A -o json | jq -r '.items[].scope.kind' | sort | uniq -c`).

**Q30.** (1) Kyverno's own ClusterRoles are managed by the Helm chart, so direct edits are reverted on the next `helm upgrade` — the fix would evaporate at the worst possible moment. (2) Aggregation is the documented extension point: `rbac.kyverno.io/aggregate-to-reports-controller: "true"` (and `...-to-background-controller`, `...-to-admission-controller`) composes your grant into the built-in role via Kubernetes ClusterRole aggregation, keeps the added permission auditable as a separate, reviewable object, and scopes it to exactly one controller instead of widening all of them.

**Q31.** No — admission still works. At admission the API server *pushes* the object to Kyverno inside the AdmissionReview; Kyverno needs no read permission on the kind to evaluate it. The background scan must *pull* the objects itself with the reports controller's ServiceAccount, which is why it needs `get`/`list`/`watch`. This asymmetry is why a policy can enforce correctly on new Widgets while reporting nothing about existing ones.

**Q32.** Extract every matched kind from the policies and assert the reports controller can list it:
```bash
kubectl get cpol -o json | jq -r '.items[].spec.rules[].match.any[].resources.kinds[]' | sort -u | \
  while read -r k; do echo -n "$k: "; kubectl auth can-i list "${k,,}s" \
    --as=system:serviceaccount:kyverno:kyverno-reports-controller; done
```
(Adjust the plural derivation with `kubectl api-resources` for irregular kinds; the point is the assertion, not the string munging.)

**Q33.** `rule_execution_cause` — filter to the background-scan value (`background_scan`; casing has varied across releases, so grep case-insensitively before pinning a PromQL matcher) and exclude the admission-request value. `policy_background_mode` tells you whether the policy is *eligible* for scanning, which is a different question and a useful second panel: it surfaces policies excluded from scans by `background: false`.

**Q34.** The CLI cannot reproduce (a) the report lifecycle — owner references, garbage collection, aggregation of admission plus scan results into a per-resource object; and (b) cluster-side context that only the controller has, such as its ServiceAccount's RBAC, `PolicyException` handling and the ConfigMap-driven `resourceFilters` — so its verdict can differ from the cluster's. It is nevertheless the right tool in CI: it evaluates a policy against manifests or a live cluster *before* the policy is admitted, catching regressions without installing anything.

**Q35.** `kyverno_policy_results_total` is a monotonically increasing counter of rule *evaluations*, not a gauge of current violations — deleting the offending Pods stops incrementing it but never decrements it, and it keeps climbing on every rescan of resources that are still failing. Alert instead on the current state derived from the reports, e.g. the summed `fail` field of `PolicyReport`/`ClusterPolicyReport` summaries (exported by Policy Reporter or a small exporter), which drops to zero when the violations are actually remediated. Use the counter for rate-of-change and for `error`-result alerting, never for a compliance level.

</details>

---

## References

- KCA curriculum (CNCF): <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Kyverno — Background Processing: <https://kyverno.io/docs/writing-policies/background/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno — Installation / customization (container flags, RBAC aggregation): <https://kyverno.io/docs/installation/customization/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — Troubleshooting: <https://kyverno.io/docs/troubleshooting/>
- Kyverno — Monitoring and metrics: <https://kyverno.io/docs/monitoring/>
- Kyverno Helm chart values (`features.backgroundScan.*`): <https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml>
- Kubernetes Policy WG — PolicyReport API: <https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report>
- Kyverno source: <https://github.com/kyverno/kyverno>