# Topic 6.1 — Policy Reports · Guided Exercises

> **Exam context (KCA, domain 6, weight 3.33 %).** Policy Reports are how Kyverno tells you *what the cluster looks like right now* with respect to your policies — as first-class Kubernetes objects, not log lines. The exam expects you to find a report, read it, explain where each field came from, and diagnose why a report you expected is missing.

---

## Lab environment

These exercises assume a throwaway cluster. Everything is namespaced or removed in the cleanup section.

```bash
kind create cluster --name kca-reports --image kindest/node:v1.31.0

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm search repo kyverno/kyverno --versions | head -5

# Pick a recent 1.x line; record what you actually installed.
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.3.7 \
  --wait
```

Record your version before anything else — two schema shifts below depend on it:

```bash
kubectl -n kyverno get deploy -o custom-columns=NAME:.metadata.name,IMAGE:'.spec.template.spec.containers[*].image'
```

```text
NAME                          IMAGE
kyverno-admission-controller  reg.kyverno.io/kyverno/kyverno:v1.13.4
kyverno-background-controller reg.kyverno.io/kyverno/kyverno:v1.13.4
kyverno-cleanup-controller    reg.kyverno.io/kyverno/cleanup-controller:v1.13.4
kyverno-reports-controller    reg.kyverno.io/kyverno/reports-controller:v1.13.4
```

Two version-dependent details, called out here once so the exercises stay readable:

| Concern | ≤ 1.12 | 1.13 + |
|---|---|---|
| Audit vs Enforce | `spec.validationFailureAction: Audit` | `spec.rules[].validate.failureAction: Audit` |
| Report API group | `wgpolicyk8s.io/v1alpha2` (`PolicyReport`, `ClusterPolicyReport`) | same, plus newer releases migrating to the OpenReports API (`openreports.io`), whose field layout is deliberately identical |

Whenever an exercise shows a field your cluster rejects, run the corresponding `kubectl explain` and use what *your* API server registers. That habit is worth more than memorising one release's schema.

---

## Exercise 1 — Map the reporting API surface before producing a single result

1. List every kind in the wg-policy group:

   ```bash
   kubectl api-resources --api-group=wgpolicyk8s.io
   ```

   ```text
   NAME                   SHORTNAMES   APIVERSION                    NAMESPACED   KIND
   clusterpolicyreports   cpolr        wgpolicyk8s.io/v1alpha2       false        ClusterPolicyReport
   policyreports          polr         wgpolicyk8s.io/v1alpha2       true         PolicyReport
   ```

2. Check whether your release also registers the OpenReports successor and Kyverno's internal reporting kinds:

   ```bash
   kubectl api-resources | grep -Ei 'openreports|reports\.kyverno\.io'
   ```

   ```text
   clusterephemeralreports   cephr    reports.kyverno.io/v1   false   ClusterEphemeralReport
   ephemeralreports          ephr     reports.kyverno.io/v1   true    EphemeralReport
   ```

3. Read the result schema straight from the API server — this is the exam-safe way to recall field names:

   ```bash
   kubectl explain polr.summary
   kubectl explain polr.results --recursive | head -30
   ```

4. Identify which controller owns each kind:

   ```bash
   kubectl -n kyverno get deploy
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
   ```

**Check your understanding**

- **Q1.1** — `PolicyReport` is namespaced and `ClusterPolicyReport` is not. Which one holds the result for a violating `ClusterRole`, and which for a violating `Pod`?
- **Q1.2** — What is an `EphemeralReport` (`ephr`) for, and why should you never build tooling or alerting on top of it?
- **Q1.3** — Four Kyverno deployments are running. Which one writes `PolicyReport` objects, and which one blocks a request at admission time?

---

## Exercise 2 — Produce your first `fail` result in Audit mode

1. Create the lab namespace:

   ```bash
   kubectl create namespace reports-lab
   ```

2. Write the policy. Note that the metadata annotations are not decoration — they land verbatim in the report.

   ```yaml
   # require-team-label.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
     annotations:
       policies.kyverno.io/title: Require team label
       policies.kyverno.io/category: Governance
       policies.kyverno.io/severity: medium
       policies.kyverno.io/description: >-
         Every Pod must carry a `team` label so that cost and on-call ownership
         can be attributed without consulting a spreadsheet.
   spec:
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - reports-lab
         validate:
           failureAction: Audit      # <=1.12: remove this and set spec.validationFailureAction: Audit
           message: "The label `team` is required."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f require-team-label.yaml
   kubectl get cpol require-team-label
   ```

   ```text
   NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
   require-team-label   true        true         True    5s    Ready
   ```

3. Create a violating workload:

   ```bash
   kubectl -n reports-lab create deployment web --image=nginx:1.27
   kubectl -n reports-lab wait --for=condition=Available deploy/web --timeout=60s
   ```

4. Look at what appeared:

   ```bash
   kubectl -n reports-lab get polr
   ```

   ```text
   NAME                                   KIND         NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
   3f2a6c1e-9d4b-4a77-8f0e-2c5b1a7e91d0   Deployment   web        0      1      0      0       0      12s
   9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11   Pod          web-6f...  0      1      0      0       0      10s
   ```

   (Printer columns vary between CRD versions; the counts are what matter.)

5. Prove where the report *name* comes from:

   ```bash
   kubectl -n reports-lab get pod -l app=web -o jsonpath='{.items[0].metadata.uid}{"\n"}'
   kubectl -n reports-lab get polr -o name
   ```

6. Note how many reports exist — the Deployment created a ReplicaSet too:

   ```bash
   kubectl -n reports-lab get deploy,rs,pod --no-headers | wc -l
   kubectl -n reports-lab get polr --no-headers | wc -l
   ```

**Check your understanding**

- **Q2.1** — The policy `match` block names only `Pod`, yet a report exists for the `Deployment`. What produced that second result, and what will the `rule` field of that result be called?
- **Q2.2** — Three workload objects exist (Deployment, ReplicaSet, Pod) but only two reports. Why is the ReplicaSet not reported on?
- **Q2.3** — What is the relationship between a report's `metadata.name` and the resource it describes, and what practical consequence does that naming scheme have when you want to look up "the report for pod X"?
- **Q2.4** — Kyverno moved from one report per namespace (≤1.9) to one report per resource (1.10+). Name the scaling problem that motivated the change.

---

## Exercise 3 — Anatomy of a result: every field, and where it came from

1. Dump the Pod's report in full:

   ```bash
   POLR=$(kubectl -n reports-lab get polr -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.scope.kind}{"\n"}{end}' | awk '$2=="Pod"{print $1}')
   kubectl -n reports-lab get polr "$POLR" -o yaml
   ```

   ```yaml
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: PolicyReport
   metadata:
     name: 9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11
     namespace: reports-lab
     labels:
       app.kubernetes.io/managed-by: kyverno
     ownerReferences:
       - apiVersion: v1
         kind: Pod
         name: web-6f8c9d7b5c-hq2xn
         uid: 9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11
   scope:
     apiVersion: v1
     kind: Pod
     name: web-6f8c9d7b5c-hq2xn
     namespace: reports-lab
     uid: 9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11
   summary:
     pass: 0
     fail: 1
     warn: 0
     error: 0
     skip: 0
   results:
     - source: kyverno
       policy: require-team-label
       rule: check-team-label
       category: Governance
       severity: medium
       result: fail
       scored: true
       message: >-
         validation error: The label `team` is required.
         rule check-team-label failed at path /metadata/labels/team/
       timestamp:
         seconds: 1786982400
         nanos: 0
   ```

2. Correlate three fields with their origin:

   ```bash
   kubectl get cpol require-team-label -o jsonpath='{.metadata.annotations}' | tr ',' '\n'
   kubectl -n reports-lab get polr "$POLR" -o jsonpath='{.results[0].category}{" / "}{.results[0].severity}{"\n"}'
   ```

3. Inspect the labels and any `properties` map your version writes — this is how you tell an admission-produced result from a background-scan one:

   ```bash
   kubectl -n reports-lab get polr "$POLR" -o jsonpath='{.metadata.labels}' | tr ',' '\n'
   kubectl -n reports-lab get polr "$POLR" -o jsonpath='{.results[0].properties}{"\n"}'
   ```

4. Turn the finding unscored and watch the verdict change class:

   ```bash
   kubectl annotate cpol require-team-label policies.kyverno.io/scored="false" --overwrite
   kubectl -n reports-lab delete pod -l app=web
   sleep 20
   kubectl -n reports-lab get polr
   ```

   ```text
   NAME                                   KIND         NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
   3f2a6c1e-9d4b-4a77-8f0e-2c5b1a7e91d0   Deployment   web        0      0      1      0       0      3m
   c1d5e7f9-2a3b-4c5d-8e9f-0a1b2c3d4e5f   Pod          web-9x...  0      0      1      0       0      18s
   ```

5. Revert it:

   ```bash
   kubectl annotate cpol require-team-label policies.kyverno.io/scored- 
   ```

**Check your understanding**

- **Q3.1** — Map each of `category`, `severity`, `policy`, `rule`, `scope`, `source` to where Kyverno obtained it.
- **Q3.2** — Give the precise meaning of all five result values: `pass`, `fail`, `warn`, `error`, `skip`. Which one indicates a problem with the *policy* rather than with the resource?
- **Q3.3** — What did `policies.kyverno.io/scored: "false"` change, and when would you deliberately ship a policy unscored?
- **Q3.4** — The report carries an `ownerReferences` entry pointing at the Pod. Name two behaviours you get for free because of it.
- **Q3.5** — `summary` duplicates information already derivable from `results`. Why does the CRD carry it anyway?

---

## Exercise 4 — Audit vs Enforce: what Enforce does *not* put in a report

1. Switch the rule to Enforce:

   ```bash
   kubectl patch cpol require-team-label --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
   # <=1.12: kubectl patch cpol require-team-label --type=merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
   ```

2. Try to create a fresh violating Pod:

   ```bash
   kubectl -n reports-lab run blocked --image=nginx:1.27
   ```

   ```text
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/reports-lab/blocked was blocked due to the following policies

   require-team-label:
     check-team-label: 'validation error: The label `team` is required.
       rule check-team-label failed at path /metadata/labels/team/'
   ```

3. Count reports again, then check whether the rejected Pod produced one:

   ```bash
   kubectl -n reports-lab get polr
   kubectl -n reports-lab get polr -o jsonpath='{range .items[*]}{.scope.name}{"\n"}{end}' | grep blocked
   ```

4. Now create a compliant Pod and observe a `pass` result:

   ```bash
   kubectl -n reports-lab run allowed --image=nginx:1.27 --labels=team=platform
   sleep 15
   kubectl -n reports-lab get polr -o custom-columns=\
   SCOPE:.scope.name,PASS:.summary.pass,FAIL:.summary.fail
   ```

5. Return the rule to Audit for the remaining exercises:

   ```bash
   kubectl patch cpol require-team-label --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Audit"}]'
   ```

**Check your understanding**

- **Q4.1** — Why is there no report entry for the Pod named `blocked`?
- **Q4.2** — A platform team says "we run everything in Enforce, so our reports are always empty of failures — we're compliant." Give the two reasons that conclusion is unsound.
- **Q4.3** — You are rolling out a new restrictive policy to a live cluster. Describe the report-driven rollout sequence and the exact query you would run to decide it is safe to flip to Enforce.

---

## Exercise 5 — Background scans: reports for resources that already exist

1. Delete the policy and recreate the workload *first*, so the resources predate the policy:

   ```bash
   kubectl delete cpol require-team-label
   kubectl -n reports-lab get polr
   kubectl -n reports-lab run legacy-a --image=nginx:1.27
   kubectl -n reports-lab run legacy-b --image=nginx:1.27
   ```

2. Shorten the background scan interval so the lab does not take an hour:

   ```bash
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i background

   kubectl -n kyverno patch deploy kyverno-reports-controller --type=json \
     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--backgroundScanInterval=1m"}]'

   kubectl -n kyverno rollout status deploy/kyverno-reports-controller
   ```

3. Re-apply the policy and watch reports appear without anything being admitted:

   ```bash
   kubectl apply -f require-team-label.yaml
   kubectl -n reports-lab get polr -w
   ```

4. Now prove that a policy with `background: false` reports nothing for pre-existing resources:

   ```yaml
   # no-background.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: block-cluster-admin-creators
   spec:
     background: false
     rules:
       - name: check-creator
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [reports-lab]
         validate:
           failureAction: Audit
           message: "Pods must not be created by system:masters."
           deny:
             conditions:
               any:
                 - key: "{{ request.userInfo.groups }}"
                   operator: AnyIn
                   value: ["system:masters"]
   ```

   ```bash
   kubectl apply -f no-background.yaml
   sleep 90
   kubectl -n reports-lab get polr -o jsonpath='{range .items[*]}{.scope.name}{": "}{range .results[*]}{.policy}{" "}{end}{"\n"}{end}'
   ```

**Check your understanding**

- **Q5.1** — Nothing was created or updated in step 3, yet failures appeared. Which controller produced them, and by what mechanism?
- **Q5.2** — Why is `background: false` mandatory for the policy in step 4? What is structurally unavailable during a background scan?
- **Q5.3** — Your production cluster has 40 000 Pods and the default 1 h interval. Describe the trade-off in both directions if you set `--backgroundScanInterval=5m`.
- **Q5.4** — Your `kubectl patch` in step 2 works today. What routine operation silently reverts it, and where should the flag live instead?

---

## Exercise 6 — Querying reports at fleet scale

1. Cluster-wide inventory of failures:

   ```bash
   kubectl get polr -A -o jsonpath=\
   '{range .items[*]}{range .results[?(@.result=="fail")]}{..policy}{"\t"}{end}{end}' 2>/dev/null

   kubectl get polr -A -o json | jq -r '
     .items[]
     | .metadata.namespace as $ns
     | .scope as $s
     | .results[]
     | select(.result=="fail")
     | [$ns, $s.kind, $s.name, .policy, .rule, .severity] | @tsv' | sort | column -t
   ```

   ```text
   reports-lab  Deployment  web       require-team-label  autogen-check-team-label  medium
   reports-lab  Pod         legacy-a  require-team-label  check-team-label          medium
   reports-lab  Pod         legacy-b  require-team-label  check-team-label          medium
   ```

2. Rank policies by number of failing resources — the number a platform team actually reports upward:

   ```bash
   kubectl get polr -A -o json | jq -r '
     [.items[].results[] | select(.result=="fail") | .policy]
     | group_by(.) | map({policy: .[0], failures: length})
     | sort_by(-.failures) | .[] | "\(.failures)\t\(.policy)"'
   ```

3. Cluster-scoped side:

   ```bash
   kubectl get cpolr
   kubectl get cpolr -o custom-columns=NAME:.metadata.name,KIND:.scope.kind,FAIL:.summary.fail
   ```

4. Total objects the reporting layer is storing:

   ```bash
   kubectl get polr -A --no-headers | wc -l
   kubectl get cpolr --no-headers | wc -l
   ```

5. Optional — install the aggregation/UI layer and see the same data as a dashboard:

   ```bash
   helm repo add policy-reporter https://kyverno.github.io/policy-reporter
   helm install policy-reporter policy-reporter/policy-reporter \
     -n policy-reporter --create-namespace --set ui.enabled=true --wait
   kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
   ```

**Check your understanding**

- **Q6.1** — Why must you read `scope` (or `ownerReferences`) rather than `metadata.name` to answer "which resources are failing?"
- **Q6.2** — One report per resource means a 40 000-Pod cluster can hold 40 000+ report objects. Name two consequences for the control plane, and one design property of the per-resource model that keeps each object small.
- **Q6.3** — A `Pod` report shows `fail` for `check-team-label` and the `Deployment` report shows `fail` for `autogen-check-team-label`. If you count raw `fail` results to produce a compliance percentage, what goes wrong?
- **Q6.4** — What does Policy Reporter add that raw `kubectl get polr` cannot give you?

---

## Exercise 7 — Lifecycle: reports are current state, not history

1. Delete one violating Pod and watch its report disappear:

   ```bash
   kubectl -n reports-lab get polr --no-headers | wc -l
   kubectl -n reports-lab delete pod legacy-a
   sleep 5
   kubectl -n reports-lab get polr --no-headers | wc -l
   ```

2. Delete the policy and observe the results being withdrawn:

   ```bash
   kubectl delete cpol require-team-label
   sleep 20
   kubectl -n reports-lab get polr
   ```

3. Ask the cluster what remains of the violation:

   ```bash
   kubectl -n reports-lab get events --field-selector reason=PolicyViolation
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20
   ```

4. Re-apply the policy so later exercises have data:

   ```bash
   kubectl apply -f require-team-label.yaml
   ```

**Check your understanding**

- **Q7.1** — Who deleted the report in step 1: Kyverno, or the Kubernetes control plane? Explain the mechanism precisely.
- **Q7.2** — After step 2, a resource that violated policy for three days leaves no trace in the reporting API. Why, and what should you deploy if you need "was this namespace ever non-compliant in Q3?" to be answerable?
- **Q7.3** — An auditor asks you to prove compliance for a past date using `kubectl get polr`. What is your answer?

---

## Exercise 8 — Reports without a cluster: the Kyverno CLI in CI

1. Install the CLI (or use the container image) and check the version:

   ```bash
   kyverno version
   ```

2. Write a resource file to test against:

   ```yaml
   # candidate.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: candidate
     namespace: reports-lab
   spec:
     containers:
       - name: app
         image: nginx:1.27
   ```

3. Produce a report offline:

   ```bash
   kyverno apply require-team-label.yaml --resource candidate.yaml --policy-report
   echo "exit=$?"
   ```

   ```text
   Applying 1 policy rule(s) to 1 resource(s)...

   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: ClusterPolicyReport
   metadata:
     name: merged
   results:
   - message: 'validation error: The label `team` is required. rule check-team-label
       failed at path /metadata/labels/team/'
     policy: require-team-label
     resources:
     - apiVersion: v1
       kind: Pod
       name: candidate
       namespace: reports-lab
     result: fail
     rule: check-team-label
     scored: true
     source: kyverno
   summary:
     error: 0
     fail: 1
     pass: 0
     skip: 0
     warn: 0
   exit=1
   ```

4. Inspect the exit-code controls you would wire into a pipeline:

   ```bash
   kyverno apply --help | grep -iE 'exit|warn|report|cluster'
   ```

5. Contrast with the in-cluster path:

   ```bash
   kubectl -n reports-lab get polr -o name | head -1
   ```

**Check your understanding**

- **Q8.1** — The CLI emitted a `ClusterPolicyReport` for a namespaced `Pod`, with the resource inside `results[].resources` instead of a top-level `scope`. Why does the offline shape differ from the in-cluster shape?
- **Q8.2** — Nothing was written to the cluster. Which two properties of CI does that make possible?
- **Q8.3** — CI is green, the in-cluster report shows failures for the same manifest. Give three reasons this can legitimately happen.

---

## Exercise 9 — Diagnosing "the report I expected is not there"

1. Create a violating Pod in an excluded namespace and observe nothing happening:

   ```bash
   kubectl -n kube-system run sneaky --image=nginx:1.27
   sleep 90
   kubectl -n kube-system get polr
   ```

   ```text
   No resources found in kube-system namespace.
   ```

2. Find out why:

   ```bash
   kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | head
   ```

   ```text
   [Event,*,*]
   [*,kube-system,*]
   [*,kube-public,*]
   [*,kube-node-lease,*]
   [*,kyverno,*]
   ...
   ```

3. Walk the rest of the checklist on a namespace that *should* be reported:

   ```bash
   # a. Is the reports controller alive and not being OOM-killed?
   kubectl -n kyverno get pods -l app.kubernetes.io/component=reports-controller
   kubectl -n kyverno describe pod -l app.kubernetes.io/component=reports-controller | grep -iE 'restart|oom|last state' 

   # b. Is reporting enabled for this rule type at all?
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'enableReporting|backgroundScan'

   # c. Is the policy background-eligible and Ready?
   kubectl get cpol -o custom-columns=NAME:.metadata.name,BACKGROUND:.spec.background,READY:.status.conditions[0].status

   # d. Is intermediate state being produced but never aggregated?
   kubectl get ephr -A
   kubectl get cephr

   # e. What does the controller itself say?
   kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=50
   ```

4. Confirm the exclusion is the cause by testing the same Pod in a non-excluded namespace:

   ```bash
   kubectl -n reports-lab run sneaky --image=nginx:1.27
   sleep 20
   kubectl -n reports-lab get polr -o custom-columns=SCOPE:.scope.name,FAIL:.summary.fail | grep sneaky
   ```

**Check your understanding**

- **Q9.1** — Why does `resourceFilters` cause a *silent* blind spot rather than an error, and why is that the single most dangerous default for someone who treats "0 failures" as "compliant"?
- **Q9.2** — `kubectl get ephr -A` shows dozens of `EphemeralReport` objects but `kubectl get polr -A` is empty. What is your diagnosis, and which component do you inspect?
- **Q9.3** — Order this checklist from cheapest to most expensive to check when a report is missing: policy `background` flag, `resourceFilters`, reports-controller health, rule `match` block, `--enableReporting` flags.
- **Q9.4** — A `PolicyException` is created that matches a violating Pod. What result value appears in the report, and why is that better than the result simply vanishing?

---

## Cleanup

```bash
kubectl delete ns reports-lab
kubectl -n kube-system delete pod sneaky --ignore-not-found
kubectl delete cpol require-team-label block-cluster-admin-creators --ignore-not-found
helm uninstall policy-reporter -n policy-reporter 2>/dev/null; kubectl delete ns policy-reporter --ignore-not-found
kind delete cluster --name kca-reports
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — A violating `ClusterRole` (a cluster-scoped resource) is reported in a `ClusterPolicyReport`; a violating `Pod` (namespaced) is reported in a `PolicyReport` inside that Pod's namespace. The report's scope follows the *subject's* scope, not the policy's — a `ClusterPolicy` matching Pods still produces namespaced `PolicyReport` objects.

**A1.2** — `EphemeralReport` / `ClusterEphemeralReport` (`reports.kyverno.io`) are Kyverno's *internal intermediate* objects. The admission controller and background controller write raw per-evaluation results there; the reports controller consumes them, aggregates per resource, writes the `PolicyReport`, and deletes the ephemeral object. They are short-lived, unstable in shape, and version-specific — an implementation detail. Tooling and alerting belong on `PolicyReport`/`ClusterPolicyReport`, which is the stable, cross-vendor contract. The one legitimate use is troubleshooting (Exercise 9).

**A1.3** — `kyverno-reports-controller` writes `PolicyReport`/`ClusterPolicyReport`. `kyverno-admission-controller` serves the webhooks and is the only one that can block a request. The other two: `kyverno-background-controller` handles background scanning plus generate/mutate-existing rules, and `kyverno-cleanup-controller` handles `CleanupPolicy` TTL deletion. Splitting them (1.10+) means report generation load cannot starve the admission path.

### Exercise 2

**A2.1** — Kyverno **auto-generation (autogen)**: a rule matching `Pod` is automatically expanded into equivalent rules targeting pod controllers, applied to the controller's `spec.template`. The generated rule is named with an `autogen-` prefix — here `autogen-check-team-label` — and for CronJobs `autogen-cronjob-check-team-label`. This is why one authored rule yields results on both the workload object and the Pod.

**A2.2** — `ReplicaSet` is not in Kyverno's default autogen controller set (`Deployment`, `DaemonSet`, `StatefulSet`, `Job`, `CronJob`). Reporting on it would triple-count the same violation, since the ReplicaSet's template is a copy of the Deployment's. The set is configurable per policy via the `pod-policies.kyverno.io/autogen-controllers` annotation.

**A2.3** — In Kyverno 1.10+ the aggregated report's `metadata.name` is the **UID of the reported resource**, and `scope` / `ownerReferences` point back at it. Consequence: you cannot construct the report name from a resource's *name* — you must first read the resource's UID (`kubectl get pod X -o jsonpath='{.metadata.uid}'`), or query by `scope`. Any script that does `kubectl get polr <pod-name>` is broken by design.

**A2.4** — The per-namespace model concentrated every result for a namespace into one object. In a large namespace that object grows toward etcd's ~1.5 MiB per-object limit and becomes a write hot-spot: every admission event in the namespace rewrites the same object, causing conflicts, retries and large-object churn. One report per resource keeps each object small, makes writes independent, and lets Kubernetes garbage-collect them individually.

### Exercise 3

**A3.1** —
- `category` ← the policy's `policies.kyverno.io/category` annotation.
- `severity` ← the policy's `policies.kyverno.io/severity` annotation.
- `policy` ← the `ClusterPolicy`/`Policy` object's name.
- `rule` ← the `spec.rules[].name` that produced the verdict (with the `autogen-` prefix when generated).
- `scope` ← the evaluated resource's identity (apiVersion, kind, name, namespace, uid).
- `source` ← the producing engine, `kyverno`. The field exists because the CRD is vendor-neutral: Falco, Trivy, kube-bench and others write into the same kinds, and `source` is how you tell them apart in one query.

**A3.2** —
- `pass` — the rule was evaluated and the resource satisfied it.
- `fail` — evaluated, resource violated it. In Audit this is recorded; in Enforce this is what blocks admission.
- `warn` — a violation that is deliberately not counted against compliance, produced by an unscored policy (`policies.kyverno.io/scored: "false"`).
- `error` — the rule could not be evaluated: bad variable substitution, an unreachable API call in `context`, a malformed JMESPath. **This is the policy's fault, not the resource's**, and it is the value people most often forget to alert on — an `error` means the control silently is not running.
- `skip` — the rule did not apply to this resource: preconditions were false, or a matching `PolicyException` exempted it.

**A3.3** — It reclassified the `fail` into a `warn`, moving the count from `summary.fail` to `summary.warn`. Ship a policy unscored when it encodes advice rather than a requirement — a new recommendation during a soak period, or a best practice you want visible in dashboards without it degrading a compliance score or tripping a `summary.fail > 0` alert.

**A3.4** — (1) **Garbage collection**: when the Pod is deleted, Kubernetes cascade-deletes the report automatically — Kyverno does not have to reconcile deletions. (2) **Traceability/adoption**: the owner reference gives an unambiguous, name-collision-free link back to the exact object instance (by UID), so a report can never be misattributed to a recreated resource that merely reuses the name.

**A3.5** — Because it makes cheap queries possible. `summary` is exposed through `additionalPrinterColumns`, so `kubectl get polr -A` shows pass/fail counts without the API server or client parsing every result. Aggregators, alerts and dashboards can watch the counters without deserialising the whole `results` array — which, on a large fleet, is the difference between a usable and an unusable query.

### Exercise 4

**A4.1** — Enforce rejects the request at admission, so the Pod **never exists** in etcd. Policy reports describe resources that exist: there is no UID to name the report after, no object to own it, and no scope to point at. A blocked request leaves an admission-webhook error to the client, a Kyverno log entry and (optionally) an Event — not a report.

**A4.2** — (1) Enforce only guards *new and updated* resources going forward; resources admitted before the policy existed remain in violation and only a background scan surfaces them — and they will show as `fail`, not as nothing. (2) An absence of `fail` may mean the rule never ran: an `error` result, an excluded namespace via `resourceFilters`, a webhook failurePolicy set to Ignore during an outage, or a `PolicyException` producing `skip`. "No failures" and "the control is working" are different claims; only checking `error`/`skip` counts and coverage distinguishes them.

**A4.3** — Deploy in Audit with `background: true`. Let the background scan complete, then query the true blast radius:

```bash
kubectl get polr -A -o json | jq -r '
  .items[] | .metadata.namespace as $ns | .scope as $s | .results[]
  | select(.policy=="require-team-label" and .result=="fail")
  | [$ns,$s.kind,$s.name] | @tsv'
```

Drive that list to zero (remediate, or grant explicit `PolicyException`s), confirm `error` count is also zero — an errored rule is not passing, it is not running — then flip `failureAction` to `Enforce`.

### Exercise 5

**A5.1** — `kyverno-reports-controller`, via the **background scan**: it periodically lists existing resources matching each policy with `background: true`, re-evaluates them through the same policy engine used at admission, and writes results. No admission request is involved, which is exactly why it can report on resources that predate the policy.

**A5.2** — The rule references `request.userInfo.groups`. `userInfo` (and everything else on the `AdmissionRequest`: the requesting user, groups, operation, dry-run flag, old object) exists **only during an admission review**. A background scan has a stored object and nothing else — there is no requester to attribute it to. Kyverno therefore refuses to mark such policies background-eligible; you must set `background: false`, and the price is that pre-existing resources are never scanned by that rule.

**A5.3** — Shorter interval: violations introduced out-of-band (a resource mutated by a controller, a policy just changed, a namespace whose webhook was bypassed) surface within 5 minutes instead of up to an hour — better MTTD. Cost: every cycle LISTs the matching resources across the whole cluster and re-evaluates them, so at 40 000 Pods you multiply API server list load, reports-controller CPU/memory, and report-object write churn by 12. On a large cluster the practical answer is to keep a long interval, scale `--backgroundScanWorkers`, and rely on admission-time results for immediacy.

**A5.4** — `helm upgrade` (and any GitOps reconcile of the Kyverno release) rewrites the Deployment and drops the appended arg. The flag belongs in the Helm values for the reports controller — the chart's extra-args mechanism for that component — so it is versioned with the rest of the install. Confirm the value name for your chart with `helm show values kyverno/kyverno | grep -A15 reportsController`.

### Exercise 6

**A6.1** — `metadata.name` is the resource's UID, which is meaningless to a human and unstable across recreation. `scope` (`kind`, `name`, `namespace`, `apiVersion`, `uid`) is the human- and machine-usable identity of the subject. `ownerReferences` carries the same link. Every report query worth writing joins on `scope`.

**A6.2** — Consequences: (1) etcd object count and total apiserver watch/list traffic grow with cluster size — informers for reports become a real memory cost in the reports controller and in any aggregator watching them; (2) `kubectl get polr -A` returns tens of thousands of items, so ad-hoc queries must be server-side-filtered or aggregated rather than piped through `jq` on a laptop. The saving property: each report covers exactly one resource, so its `results` array is bounded by the number of matching rules — objects stay far below etcd's per-object size limit and writes for different resources never contend.

**A6.3** — You double-count the same violation. The Deployment's `autogen-` result and the Pod's result describe one underlying defect — one missing label in one pod template. A naive `fail` count inflates by the number of autogen-expanded controller kinds involved, and the inflation factor varies by workload type (a CronJob adds another layer). Compliance percentages must be computed over *distinct scopes* — and usually over a chosen level (workload objects, or Pods, not both).

**A6.4** — Aggregation, history and delivery: it watches the report CRDs across the cluster, keeps a queryable store with trends over time (which the CRDs themselves cannot express), and pushes results to external targets — Slack, Teams, Elasticsearch, Loki, S3, webhooks — plus Prometheus metrics and a UI. In other words it converts point-in-time cluster state into notifications and history.

### Exercise 7

**A7.1** — The **Kubernetes garbage collector**, not Kyverno. The report carries an `ownerReference` to the Pod; when the Pod is deleted the GC removes dependents whose owner no longer exists. Kyverno never has to watch for deletions to clean up reports — which is also why report cleanup keeps working even if the reports controller is down.

**A7.2** — Kyverno's reports controller reconciles reports against the current set of policies: when the policy disappears, its results are removed from every report, and a report left with no results is deleted. Reports are a **materialised view of current state**, not an event log. To answer historical questions, ship the results somewhere durable: Policy Reporter with a persistent target (Elasticsearch, S3, an SIEM), or scrape/export the data on a schedule. Kubernetes Events are not a substitute — they expire (default 1 h TTL).

**A7.3** — You cannot answer it from `kubectl get polr`. The reporting API only ever describes *now*: what the current policies say about the currently existing resources. Historical compliance evidence requires an external retention system that was already collecting at the time in question; retroactive proof is impossible.

### Exercise 8

**A8.1** — Offline there is no API server, so nothing has a UID and nothing is namespaced in the cluster sense: the CLI cannot name a report after a UID, own it, or place it in a namespace. It therefore emits a single merged `ClusterPolicyReport` (named `merged` in recent versions) that lists each evaluated resource inside `results[].resources` — the older, pre-1.10 shape, which is the only one expressible without a cluster. The two shapes carry the same information; only the identity mechanism differs.

**A8.2** — (1) **Shift-left**: policy failures are caught in a pull request, before merge, with no cluster to connect to and no credentials in CI. (2) **Determinism and isolation**: the run has no side effects on any environment, so it can execute on every commit, in parallel, for many branches, and its exit code can gate the merge (check `kyverno apply --help` for the exit-code and warning flags).

**A8.3** — (1) **Autogen**: CI evaluated the Deployment manifest; the cluster additionally evaluates the generated Pod, and mutation rules or defaulting may make the live Pod differ. (2) **Mutation and admission chain**: other Kyverno mutate rules, sidecar injectors or defaulting webhooks change the object between the file on disk and the object in etcd. (3) **Context differences**: policies using cluster context (`apiCall`, ConfigMap lookups, `namespaceSelector`, image registry lookups for `verifyImages`) evaluate differently — or error — offline versus in-cluster. Also plain drift: the cluster may run a different policy set or version than the repo CI tested against.

### Exercise 9

**A9.1** — `resourceFilters` in the `kyverno` ConfigMap is an *exclusion* list, applied before evaluation, and by default it excludes `kube-system`, `kube-public`, `kube-node-lease` and Kyverno's own namespace (among others) to avoid deadlocking the control plane. Excluded resources are never evaluated, so there is nothing to report — no error, no warning, no `skip`: the resource is simply invisible to the engine. It is dangerous precisely because the failure mode is indistinguishable from success in every dashboard: "0 failures" over a scope you never scanned reads exactly like "0 failures" over a scope you did. Any compliance claim must state its coverage, not just its counts.

**A9.2** — The producers (admission and background controllers) are working — evaluation is happening and intermediate results are being written — but the **aggregation stage is broken**: `kyverno-reports-controller` is crash-looping, OOM-killed, throttled, lacking RBAC to write `policyreports`, or wedged. Inspect that Deployment: `kubectl -n kyverno describe pod -l app.kubernetes.io/component=reports-controller` for restarts/OOM, then its logs for RBAC or conflict errors. Piling-up `EphemeralReport` objects is itself the symptom, since a healthy controller consumes and deletes them.

**A9.3** — Cheapest to most expensive:
1. Rule `match` block — read the policy you already have, no cluster calls.
2. Policy `background` flag and Ready status — one `kubectl get cpol`.
3. `resourceFilters` — one `kubectl get cm`.
4. Reports-controller flags (`--enableReporting`, `--backgroundScanInterval`) — one `kubectl get deploy`.
5. Reports-controller health — describe + logs + possibly correlating `ephr` state over time.
In practice, checking `match` and `resourceFilters` first resolves the large majority of "no report" cases.

**A9.4** — The result becomes **`skip`**, and `summary.skip` increments. That is materially better than the result disappearing: an exemption stays *visible and auditable*. You can query which resources are exempt from which rule, review whether the exception is still justified, and alert on exceptions growing — whereas a vanished result is indistinguishable from a control that silently stopped running. (Exceptions must be enabled at install time; check `helm show values kyverno/kyverno | grep -i -A5 policyExceptions` for your chart's value name and namespace restriction.)

</details>

---

## Sources

- KCA curriculum — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- Kyverno documentation — https://kyverno.io/docs/
- Kyverno policy reports documentation — https://kyverno.io/docs/policy-reports/
- Kyverno CLI (`kyverno apply`) — https://kyverno.io/docs/kyverno-cli/
- PolicyReport CRD specification (Kubernetes Policy WG) — https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report
- OpenReports API (successor of the wg-policy report CRDs) — https://github.com/openreports
- Policy Reporter — https://github.com/kyverno/policy-reporter
- Kubernetes owner references and garbage collection — https://kubernetes.io/docs/concepts/architecture/garbage-collection/