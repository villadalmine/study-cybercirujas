# Topic 5.9 — Autogen Rules

**Guided exercises — Kyverno Certified Associate (KCA), Domain 5**

> Autogen is the mechanism by which Kyverno takes a rule you wrote for `Pod` and silently derives equivalent rules for the workload controllers that *produce* Pods. It is the single feature that decides whether a policy violation surfaces at `kubectl apply -f deployment.yaml` (good) or three levels down in a ReplicaSet event loop nobody is watching (bad). These exercises make the derivation visible, then make you control it.
>
> All CLI output below is **representative**: names, hashes and the exact controller list vary by Kyverno version. Where a version difference matters, the exercise asks you to read the value out of *your* cluster instead of trusting the page.

---

## Block 0 — Lab setup

**Target:** a cluster with Kyverno installed in admission-control mode, plus the `kyverno` CLI.

1. Create a disposable cluster.

   ```bash
   kind create cluster --name autogen-lab
   kubectl config use-context kind-autogen-lab
   ```

2. Install Kyverno (Helm, admission controller + background controller + reports controller).

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno
   helm repo update
   helm install kyverno kyverno/kyverno \
     --namespace kyverno --create-namespace \
     --wait
   ```

3. Record the exact version you are running. Every claim in this topic is version-sensitive.

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   ghcr.io/kyverno/kyverno:v1.13.4
   ```

4. Install the CLI and confirm it matches the cluster minor version.

   ```bash
   kyverno version
   ```

   ```
   Version: 1.13.4
   Time: 2025-01-28T10:14:22Z
   Git commit ID: 0e9a2f1
   ```

5. Create the working namespace.

   ```bash
   kubectl create namespace autogen-lab
   ```

6. Confirm the API surface Kyverno registered *before* you add any policy. You will compare against this later.

   ```bash
   kubectl get validatingwebhookconfiguration | grep kyverno
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules}{"\n"}{end}'
   ```

   On a fresh install with no policies, the resource webhook has **no rules** — Kyverno builds the match surface dynamically from the policies you install.

**Questions — Block 0**

- **Q0.1** Kyverno's resource webhook starts with an empty rule list. What operational property does that give you that a statically-defined `ValidatingWebhookConfiguration` (the classic OPA Gatekeeper `*` catch-all) does not?
- **Q0.2** Why does the CLI version matter for a topic about autogen specifically? Name the concrete artifact that would differ.

---

## Block 1 — Make autogen visible

**Target:** prove that Kyverno stores derived rules separately from the rules you authored.

1. Write a Pod-scoped validation policy. Note that `kinds` contains **only** `Pod`.

   ```yaml
   # 01-require-nonroot.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-run-as-nonroot
   spec:
     validationFailureAction: Enforce   # Kyverno >= 1.13: prefer per-rule validate.failureAction
     background: true
     rules:
       - name: check-runasnonroot
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         validate:
           message: >-
             Every container must set securityContext.runAsNonRoot=true.
           pattern:
             spec:
               containers:
                 - securityContext:
                     runAsNonRoot: true
   ```

2. Apply it and wait for it to become ready.

   ```bash
   kubectl apply -f 01-require-nonroot.yaml
   kubectl get cpol require-run-as-nonroot
   ```

   ```
   NAME                     ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
   require-run-as-nonroot   true        true         Enforce           True    4s
   ```

3. Confirm your authored spec is **unchanged** — Kyverno did not rewrite what you wrote.

   ```bash
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.spec.rules[*].name}{"\n"}'
   ```

   ```
   check-runasnonroot
   ```

4. Now read the derived rules out of `status`.

   ```bash
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}' \
     | tr ' ' '\n'
   ```

   ```
   autogen-check-runasnonroot
   autogen-cronjob-check-runasnonroot
   ```

5. Read the annotation Kyverno attached to the policy.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.metadata.annotations}{"\n"}' | jq .
   ```

   ```json
   {
     "pod-policies.kyverno.io/autogen-controllers": "DaemonSet,Deployment,Job,StatefulSet,ReplicaSet,ReplicationController,CronJob"
   }
   ```

6. Read the *kinds* each derived rule matches, in your cluster.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[0].match.any[0].resources.kinds}{"\n"}'
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[1].match.any[0].resources.kinds}{"\n"}'
   ```

**Questions — Block 1**

- **Q1.1** You wrote one rule. Kyverno derived **two**, not six or seven — one per pod controller. What structural property of the Kubernetes API groups the controllers into exactly two buckets?
- **Q1.2** The derived rules live under `.status`, not `.spec`. State two concrete operational consequences of that design choice — one for GitOps, one for policy authoring.
- **Q1.3** Write down the exact kind list your cluster produced in step 6. Does it include `ReplicaSet` and `ReplicationController`? Why would a Kyverno release deliberately drop those two from the default set?
- **Q1.4** Your rule is named `check-runasnonroot` (18 characters). Kyverno enforces a 63-character limit on rule names. What is the practical maximum length for an author-written rule name in a policy that will be autogenned, and why?

---

## Block 2 — Read the path rewriting

**Target:** understand *what* autogen actually transforms. It is not "copy the rule and change the kind" — it is a JSON-path relocation of the whole rule body.

1. Dump the first derived rule in full.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[0]}' | yq -P
   ```

   ```yaml
   name: autogen-check-runasnonroot
   match:
     any:
       - resources:
           kinds:
             - DaemonSet
             - Deployment
             - Job
             - StatefulSet
             - ReplicaSet
             - ReplicationController
           namespaces:
             - autogen-lab
   validate:
     message: Every container must set securityContext.runAsNonRoot=true.
     pattern:
       spec:
         template:
           spec:
             containers:
               - securityContext:
                   runAsNonRoot: true
   ```

2. Dump the CronJob rule.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[1]}' | yq -P
   ```

   ```yaml
   name: autogen-cronjob-check-runasnonroot
   match:
     any:
       - resources:
           kinds:
             - CronJob
           namespaces:
             - autogen-lab
   validate:
     message: Every container must set securityContext.runAsNonRoot=true.
     pattern:
       spec:
         jobTemplate:
           spec:
             template:
               spec:
                 containers:
                   - securityContext:
                       runAsNonRoot: true
   ```

3. Diff the two `pattern` blocks mentally, then confirm the prefix each one inserted:

   ```bash
   diff \
     <(kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[0].validate.pattern}' | yq -P) \
     <(kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[1].validate.pattern}' | yq -P)
   ```

4. Note what was **not** rewritten: the `message`, the `namespaces` selector, and the rule's `match` scope semantics.

**Questions — Block 2**

- **Q2.1** State the exact path prefix autogen inserts for (a) the standard controller rule and (b) the CronJob rule.
- **Q2.2** The `message` string is copied verbatim. A student writes `message: "Pod must set runAsNonRoot"`. What will a platform engineer see when their Deployment is rejected, and why is that message now actively misleading? Rewrite it correctly.
- **Q2.3** A rule body contains the variable `{{ request.object.spec.containers[0].image }}`. What must autogen do to that expression in the derived Deployment rule for the policy to remain correct?
- **Q2.4** `namespaces: [autogen-lab]` was copied unchanged into both derived rules. Explain why copying it unchanged is correct here, and name a `match` field where a naive verbatim copy *would* be wrong.

---

## Block 3 — Prove where enforcement happens

**Target:** observe the difference between a cluster with autogen and one without, at the point of user experience.

1. Create a violating Deployment.

   ```yaml
   # 02-bad-deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: autogen-lab
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: nginx
             image: nginx:1.27-alpine
             ports:
               - containerPort: 8080
   ```

   ```bash
   kubectl apply -f 02-bad-deploy.yaml
   ```

   ```
   Error from server: error when creating "02-bad-deploy.yaml": admission webhook
   "validate.kyverno.svc-fail" denied the request:

   resource Deployment/autogen-lab/web was blocked due to the following policies

   require-run-as-nonroot:
     autogen-check-runasnonroot: 'validation error: Every container must set
       securityContext.runAsNonRoot=true. rule autogen-check-runasnonroot failed at
       path /spec/template/spec/containers/0/securityContext/'
   ```

2. Read the rule name in the rejection message. Note that it is the **derived** name, and note the failure path.

3. Now disable autogen for this policy and repeat, to see the counterfactual.

   ```bash
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers=none --overwrite
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen}{"\n"}'
   ```

   ```
   {}
   ```

4. Apply the same Deployment again.

   ```bash
   kubectl apply -f 02-bad-deploy.yaml
   kubectl -n autogen-lab get deploy,rs,pod
   ```

   ```
   deployment.apps/web created

   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/web   0/1     0            0           12s

   NAME                             DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-6d4c8f7b9    1         0         0       12s
   ```

5. Find where the failure actually surfaced.

   ```bash
   kubectl -n autogen-lab describe rs web-6d4c8f7b9 | tail -n 8
   ```

   ```
   Events:
     Type     Reason        Age                From                   Message
     ----     ------        ----               ----                   -------
     Warning  FailedCreate  8s (x4 over 12s)   replicaset-controller  Error creating: admission
       webhook "validate.kyverno.svc-fail" denied the request: resource Pod/autogen-lab/web-6d4c8f7b9-xk2vp
       was blocked due to the following policies

       require-run-as-nonroot:
         check-runasnonroot: 'validation error: Every container must set
           securityContext.runAsNonRoot=true.'
   ```

6. Clean up and restore autogen.

   ```bash
   kubectl -n autogen-lab delete deploy web
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers- --overwrite
   ```

**Questions — Block 3**

- **Q3.1** In step 4, `kubectl apply` returned exit code 0 and printed `deployment.apps/web created`. Is the policy being enforced? Justify precisely.
- **Q3.2** The ReplicaSet controller retried (`x4 over 12s`). Describe what this loop costs you over hours in a cluster with dozens of such Deployments, in terms of API server load and controller-manager backoff.
- **Q3.3** Which of the two behaviours is safer from a *security* standpoint, and which is safer from an *operability* standpoint? Are they the same answer?
- **Q3.4** A CI pipeline runs `kubectl apply --dry-run=server -f deployment.yaml` as a gate. Explain what that gate detects with autogen on, and what it detects with autogen off.

---

## Block 4 — Control the controller set

**Target:** narrow autogen deliberately, and see the second-order effect on the admission webhook.

1. Restrict the policy to two controllers.

   ```bash
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers=Deployment,StatefulSet --overwrite
   ```

2. Re-read the derived rules.

   ```bash
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[0].match.any[0].resources.kinds}'; echo
   ```

   ```
   autogen-check-runasnonroot
   ["Deployment","StatefulSet"]
   ```

3. Observe that the CronJob rule disappeared.

4. Inspect the webhook match surface now that policies exist.

   ```bash
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\n"}{range .rules[*]}  {.apiGroups}{" "}{.resources}{"\n"}{end}{end}'
   ```

   ```
   validate.kyverno.svc-fail
     ["apps"] ["deployments","statefulsets"]
     [""] ["pods"]
   ```

5. Apply a violating CronJob and confirm it is now accepted at the CronJob level.

   ```yaml
   # 03-bad-cronjob.yaml
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: report
     namespace: autogen-lab
   spec:
     schedule: "*/5 * * * *"
     jobTemplate:
       spec:
         template:
           spec:
             restartPolicy: OnFailure
             containers:
               - name: report
                 image: busybox:1.36
                 command: ["sh", "-c", "echo run"]
   ```

   ```bash
   kubectl apply -f 03-bad-cronjob.yaml
   ```

   ```
   cronjob.batch/report created
   ```

6. Restore the default and re-check that the CronJob rule returns.

   ```bash
   kubectl delete -f 03-bad-cronjob.yaml
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers- --overwrite
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
   ```

**Questions — Block 4**

- **Q4.1** In step 4 the webhook intercepts `deployments` and `statefulsets` but not `jobs` or `cronjobs`. Trace the causal chain from the annotation to that webhook rule list. Which Kyverno setting makes this dynamic?
- **Q4.2** You run a cluster where Argo CD creates thousands of Jobs per hour. Argue both sides of removing `Job` from the autogen controller set for a high-traffic policy. What do you lose?
- **Q4.3** The CronJob in step 5 was accepted. Will its Pods run five minutes later? Where exactly would the rejection appear?
- **Q4.4** Setting the annotation to `none` and setting it to an empty string are not the same thing to a YAML parser. What would you actually write in Git to disable autogen, and how would you assert in CI that it is still disabled?

---

## Block 5 — The metadata trap

**Target:** the highest-frequency autogen bug in production policy suites.

1. Write a label-requirement policy against Pods.

   ```yaml
   # 04-require-team-label.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Enforce
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         validate:
           message: "The label 'team' is required."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f 04-require-team-label.yaml
   ```

2. Predict the derived pattern before you look. Write your prediction down, then check.

   ```bash
   kubectl get cpol require-team-label \
     -o jsonpath='{.status.autogen.rules[0].validate.pattern}' | yq -P
   ```

   ```yaml
   spec:
     template:
       metadata:
         labels:
           team: "?*"
   ```

3. Apply a Deployment that carries the label on the **Deployment object** but not on the pod template.

   ```yaml
   # 05-label-on-wrong-object.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: api
     namespace: autogen-lab
     labels:
       team: platform
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: api
     template:
       metadata:
         labels:
           app: api
       spec:
         containers:
           - name: api
             image: nginx:1.27-alpine
             securityContext:
               runAsNonRoot: true
   ```

   ```bash
   kubectl apply -f 05-label-on-wrong-object.yaml
   ```

   ```
   Error from server: error when creating "05-label-on-wrong-object.yaml": admission webhook
   "validate.kyverno.svc-fail" denied the request:

   resource Deployment/autogen-lab/api was blocked due to the following policies

   require-team-label:
     autogen-check-team-label: 'validation error: The label ''team'' is required.
       rule autogen-check-team-label failed at path /spec/template/metadata/labels/team/'
   ```

4. Fix it by moving the label into `spec.template.metadata.labels` and re-apply.

5. Now write the policy the platform team actually wanted — labels on **both** the controller and the Pod — as two separate rules.

   ```yaml
   # 06-require-team-label-both.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label-both
     annotations:
       pod-policies.kyverno.io/autogen-controllers: none
   spec:
     validationFailureAction: Enforce
     background: true
     rules:
       - name: pod-template-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         validate:
           message: "Pods must carry the label 'team'."
           pattern:
             metadata:
               labels:
                 team: "?*"
       - name: controller-object-label
         match:
           any:
             - resources:
                 kinds:
                   - Deployment
                   - StatefulSet
                   - DaemonSet
                 namespaces:
                   - autogen-lab
         validate:
           message: "Workload controllers must carry the label 'team' on the object itself."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

**Questions — Block 5**

- **Q5.1** Autogen rewrote `metadata.labels` to `spec.template.metadata.labels`. Argue why that is the *correct* transformation even though it surprises authors.
- **Q5.2** In `06-require-team-label-both.yaml` the annotation is set to `none`. What would go wrong if it were left at the default while rule 2 exists as written? Be specific about which object gets checked twice and against which path.
- **Q5.3** Rule 2 matches controllers explicitly. What does that do to Kyverno's autogen decision for *that rule*, independently of the annotation?
- **Q5.4** A policy validates `metadata.ownerReferences` on Pods. Reason about whether the autogenned Deployment rule can be equivalent. What does this tell you about which Pod fields are safely autogennable?

---

## Block 6 — Rule types: what autogens and what does not

**Target:** build the mental table. Autogen is not universal across rule types.

1. Create a mutate policy using `patchStrategicMerge`.

   ```yaml
   # 07-mutate-safe-to-evict.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-safe-to-evict
   spec:
     rules:
       - name: annotate-workload
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         mutate:
           patchStrategicMerge:
             metadata:
               annotations:
                 +(cluster-autoscaler.kubernetes.io/safe-to-evict): "true"
   ```

   ```bash
   kubectl apply -f 07-mutate-safe-to-evict.yaml
   kubectl get cpol add-safe-to-evict -o jsonpath='{.status.autogen.rules[*].name}'; echo
   ```

2. Apply a compliant Deployment and inspect where the mutation landed.

   ```yaml
   # 08-good-deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: cache
     namespace: autogen-lab
     labels:
       team: platform
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: cache
     template:
       metadata:
         labels:
           app: cache
           team: platform
       spec:
         containers:
           - name: redis
             image: redis:7-alpine
             securityContext:
               runAsNonRoot: true
   ```

   ```bash
   kubectl apply -f 08-good-deploy.yaml
   kubectl -n autogen-lab get deploy cache \
     -o jsonpath='{.spec.template.metadata.annotations}'; echo
   kubectl -n autogen-lab get deploy cache \
     -o jsonpath='{.metadata.annotations}'; echo
   ```

   ```
   {"cluster-autoscaler.kubernetes.io/safe-to-evict":"true"}
   {"deployment.kubernetes.io/revision":"1", ...}
   ```

3. Now create a `generate` rule and check its autogen status.

   ```yaml
   # 09-generate-netpol.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: default-deny-netpol
   spec:
     rules:
       - name: create-default-deny
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
   kubectl apply -f 09-generate-netpol.yaml
   kubectl get cpol default-deny-netpol -o jsonpath='{.status.autogen}'; echo
   ```

4. Create a mutate rule that uses `patchesJson6902` instead, and compare.

   ```yaml
   # 10-mutate-json6902.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: json-patch-demo
   spec:
     rules:
       - name: patch-container
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         mutate:
           patchesJson6902: |-
             - op: add
               path: "/metadata/annotations/patched-by"
               value: "kyverno"
   ```

   ```bash
   kubectl apply -f 10-mutate-json6902.yaml
   kubectl get cpol json-patch-demo -o jsonpath='{.status.autogen}'; echo
   ```

5. Record your findings in a table:

   | Rule construct | Autogen produced? | Evidence (command + output) |
   |---|---|---|
   | `validate.pattern` | | |
   | `validate.deny` | | |
   | `validate.podSecurity` | | |
   | `mutate.patchStrategicMerge` | | |
   | `mutate.patchesJson6902` | | |
   | `verifyImages` | | |
   | `generate` | | |

   Fill the empty rows by writing one minimal policy per construct and reading `.status.autogen`.

**Questions — Block 6**

- **Q6.1** In step 2 the annotation landed on `spec.template.metadata.annotations`, not on the Deployment's own `metadata.annotations`. Why is that the *only* useful place for it, given what `cluster-autoscaler.kubernetes.io/safe-to-evict` does?
- **Q6.2** Compare mutating at the Deployment level versus mutating only the Pod at Pod-admission. Which one causes GitOps drift, and which one is visible in `kubectl get deploy -o yaml`? Which do you want, and when do you want the other?
- **Q6.3** `generate` rules produce no autogen entries. Explain why the transformation is not merely unimplemented but *semantically undefined* for `generate`.
- **Q6.4** From step 4, state the rule for JSON patches and explain the mechanical reason (think about what a JSON pointer like `/spec/containers/0/image` means once the object is a Deployment).
- **Q6.5** Your cluster runs the `pod-security-standards` policy set from the Kyverno policy library, applied to Pods only. Explain in one sentence why Deployments are nonetheless blocked.

---

## Block 7 — When Kyverno refuses to autogen

**Target:** recognise the conditions that silently suppress autogen.

1. Write a rule whose `match` names both a Pod and a controller.

   ```yaml
   # 11-mixed-match.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: mixed-match
   spec:
     validationFailureAction: Audit
     rules:
       - name: check-mixed
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                   - Deployment
                 namespaces:
                   - autogen-lab
         validate:
           message: "demo"
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f 11-mixed-match.yaml
   kubectl get cpol mixed-match -o jsonpath='{.status.autogen}'; echo
   ```

2. Write a rule that matches no Pod at all.

   ```yaml
   # 12-service-only.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: service-only
   spec:
     validationFailureAction: Audit
     rules:
       - name: check-service
         match:
           any:
             - resources:
                 kinds:
                   - Service
         validate:
           message: "demo"
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f 12-service-only.yaml
   kubectl get cpol service-only -o jsonpath='{.status.autogen}'; echo
   ```

3. Write a two-rule policy where only one rule is Pod-scoped, and count the derived rules.

   ```bash
   kubectl get cpol <your-policy> \
     -o jsonpath='{range .status.autogen.rules[*]}{.name}{"\n"}{end}'
   ```

4. For each of the three cases, record: did autogen run, and — critically — did Kyverno *warn* you?

**Questions — Block 7**

- **Q7.1** In step 1, `mixed-match` produced no derived rules. Reason out why suppressing autogen here is the correct default rather than a bug. What would happen to a Deployment if Kyverno had autogenned anyway?
- **Q7.2** Case 1 is dangerous in review: the policy *looks* like it covers Deployments, and it does — but with the Pod-shaped pattern applied to the Deployment object. Against which path is a Deployment's `metadata.labels` checked in `mixed-match`? Is that what the author meant?
- **Q7.3** None of these cases produced a warning event or a non-ready policy status. Design a CI check — one command plus an assertion — that catches "this policy should have autogenned and did not".
- **Q7.4** A rule matches `Pod` but with `exclude` naming `Deployment`. Predict the autogen outcome and then verify it in your cluster.

---

## Block 8 — Autogen through the Kyverno CLI

**Target:** test derived rules offline, in CI, without a cluster. This is where the rule *name* matters most.

1. Save a policy and a resource to disk.

   ```bash
   mkdir -p cli-lab && cd cli-lab
   cp ../01-require-nonroot.yaml policy.yaml
   cp ../02-bad-deploy.yaml resource.yaml
   ```

2. Run `kyverno apply` against the Deployment.

   ```bash
   kyverno apply policy.yaml --resource resource.yaml
   ```

   ```
   Loading policies ...
   Loading resources ...
   Applying 1 policy rule(s) to 1 resource(s)...

   policy require-run-as-nonroot -> resource autogen-lab/Deployment/web failed:
   1. autogen-check-runasnonroot: validation error: Every container must set
      securityContext.runAsNonRoot=true. rule autogen-check-runasnonroot failed at path
      /spec/template/spec/containers/0/securityContext/

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```

3. Note the rule name in the CLI output. Now write a `Test` manifest — deliberately using the **authored** rule name first, so you see the failure mode.

   ```yaml
   # kyverno-test.yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: autogen-check
   policies:
     - policy.yaml
   resources:
     - resource.yaml
   results:
     - policy: require-run-as-nonroot
       rule: check-runasnonroot        # <-- deliberately wrong for a Deployment
       kind: Deployment
       resources:
         - web
       result: fail
   ```

   ```bash
   kyverno test .
   ```

   ```
   Loading test  ( kyverno-test.yaml ) ...
     Loading values/variables ...
     Loading policies ...
     Loading resources ...
     Applying 1 policy to 1 resource ...
     Checking results ...

   │────│───────────────────────│──────────────────│─────────────────────────│────────│────────│
   │ ID │ POLICY                │ RULE             │ RESOURCE                │ RESULT │ REASON │
   │────│───────────────────────│──────────────────│─────────────────────────│────────│────────│
   │ 1  │ require-run-as-nonroot│ check-runasnonroot│ apps/v1/Deployment/web │ Fail   │ Not found │
   │────│───────────────────────│──────────────────│─────────────────────────│────────│────────│

   Test Summary: 0 tests passed and 1 tests failed
   ```

4. Correct the rule name to `autogen-check-runasnonroot` and re-run until green.

   ```bash
   kyverno test .
   ```

   ```
   Test Summary: 1 tests passed and 0 tests failed
   ```

5. Add a second resource — a CronJob — and a second expected result, and get both passing.

   ```yaml
   results:
     - policy: require-run-as-nonroot
       rule: autogen-check-runasnonroot
       kind: Deployment
       resources: [web]
       result: fail
     - policy: require-run-as-nonroot
       rule: autogen-cronjob-check-runasnonroot
       kind: CronJob
       resources: [report]
       result: fail
   ```

**Questions — Block 8**

- **Q8.1** The `kyverno` CLI has no cluster connection in step 2. Where did the derived rule come from? What does this tell you about whether autogen is a controller-side or a library-side transformation?
- **Q8.2** Why does `kyverno test` require the derived rule name rather than accepting the authored one? Frame the answer in terms of what a policy report row identifies.
- **Q8.3** You bump Kyverno from 1.12 to 1.14 and your `kyverno test` suite goes red with `Not found` on several rows, with no policy change in Git. Give the most likely cause and the first command you would run.
- **Q8.4** Write the two-line addition to a CI job that would have caught the Block 7 `mixed-match` problem before merge, using only the CLI.

---

## Block 9 — Debug drill

**Target:** diagnose from symptoms, under time pressure, the way the exam and an incident both present it.

**Symptom.** A platform engineer reports: *"I applied my Deployment, kubectl said `created`, but the app never comes up and there are no Pods. The policy team says the policy is `Enforce`."*

1. Reproduce the state.

   ```bash
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers=none --overwrite
   kubectl apply -f 02-bad-deploy.yaml
   ```

2. Work the ladder. Run each and record what it rules in or out.

   ```bash
   # a. Is the workload object healthy?
   kubectl -n autogen-lab get deploy web -o wide

   # b. Does a ReplicaSet exist, and is it creating?
   kubectl -n autogen-lab get rs -l app=web

   # c. What is the controller telling you?
   kubectl -n autogen-lab describe rs -l app=web | sed -n '/Events/,$p'

   # d. Which policies are in play, and in what mode?
   kubectl get cpol

   # e. Did the policy derive controller rules?
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen}'; echo

   # f. Why not?
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.metadata.annotations}'; echo

   # g. What is the webhook actually intercepting?
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{range .rules[*]}{.resources}{"\n"}{end}{end}'

   # h. What does Kyverno itself say?
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50 | grep -i autogen
   ```

3. Apply the fix, and prove it with a failing-then-passing apply.

4. Write a two-sentence postmortem statement: root cause and the guardrail that prevents recurrence.

**Questions — Block 9**

- **Q9.1** Which single command in the ladder — (a) through (h) — is the fastest path from symptom to root cause? Justify.
- **Q9.2** Command (d) shows `VALIDATE ACTION: Enforce` and `READY: True`. Explain how a policy can be simultaneously ready, enforcing, and not enforcing on the object the user submitted.
- **Q9.3** The webhook in (g) lists `pods` but not `deployments`. State the invariant that connects the annotation, `.status.autogen`, and the webhook rules — as a single sentence you could put in a runbook.
- **Q9.4** Propose a policy-repo lint rule, expressible as one `kubectl`/`jq` pipeline or one `kyverno test` case, that would fail CI whenever a Pod-matching Enforce policy has autogen disabled without a documented exception.

---

## Block 10 — Advanced: autogen under the CEL policy types (Kyverno ≥ 1.14)

**Target:** recognise that autogen exists in the newer `ValidatingPolicy` / `ImageValidatingPolicy` CRDs with a different, *declarative* surface. Skip this block if `kubectl api-resources | grep validatingpolic` returns nothing.

1. Check whether your cluster serves the CRD, and inspect the schema instead of trusting any document.

   ```bash
   kubectl api-resources | grep -i validatingpolic
   kubectl explain validatingpolicies.spec.autogen
   kubectl explain validatingpolicies.status.autogen
   ```

2. Write a CEL policy with an explicit autogen configuration.

   ```yaml
   # 13-vpol-nonroot.yaml
   apiVersion: policies.kyverno.io/v1alpha1
   kind: ValidatingPolicy
   metadata:
     name: vpol-require-nonroot
   spec:
     validationActions:
       - Deny
     autogen:
       podControllers:
         controllers:
           - deployments
           - statefulsets
     matchConstraints:
       resourceRules:
         - apiGroups:   [""]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["pods"]
     validations:
       - expression: >-
           object.spec.containers.all(c,
             has(c.securityContext) &&
             has(c.securityContext.runAsNonRoot) &&
             c.securityContext.runAsNonRoot == true)
         message: "Every container must set securityContext.runAsNonRoot=true."
   ```

   ```bash
   kubectl apply -f 13-vpol-nonroot.yaml
   kubectl get validatingpolicy vpol-require-nonroot -o yaml | yq '.status.autogen'
   ```

3. Compare the generated artifact against Block 1's `status.autogen.rules`. Note the differences in shape, in the CEL expression that was rewritten, and in how the controller list is declared.

4. Note which surface is **declarative in `spec`** versus **annotation-driven in `metadata`**.

**Questions — Block 10**

- **Q10.1** In the CEL policy, `object.spec.containers` must become something else in the derived Deployment check. Write the expression you expect, and then compare it to what your cluster actually produced.
- **Q10.2** The controller list moved from an annotation on `metadata` to a typed field under `spec.autogen.podControllers`. Name two concrete advantages of the typed field for a platform team managing hundreds of policies.
- **Q10.3** The controller names in the new API are lowercase plurals (`deployments`) rather than Kinds (`Deployment`). What does that naming choice tell you about which layer the match is now expressed at?
- **Q10.4** You are migrating a `ClusterPolicy` with `pod-policies.kyverno.io/autogen-controllers: none` to a `ValidatingPolicy`. What is the equivalent configuration, and how would you verify equivalence rather than assume it?

---

## Cleanup

```bash
kubectl delete cpol require-run-as-nonroot require-team-label require-team-label-both \
  add-safe-to-evict default-deny-netpol json-patch-demo mixed-match service-only \
  --ignore-not-found
kubectl delete validatingpolicy vpol-require-nonroot --ignore-not-found
kubectl delete namespace autogen-lab
kind delete cluster --name autogen-lab
```

---

<details>
<summary><strong>Answers</strong></summary>

### Block 0

**Q0.1** Kyverno computes the webhook `rules` from the installed policy set (dynamic webhook configuration, on by default). The cost of admission control is therefore proportional to what you actually govern: an API object with no matching policy never leaves the API server for a webhook round-trip. A static `*`-scoped webhook routes every mutation of every resource through the policy engine, which turns the policy controller into a hard dependency of the entire control plane and a single point of latency and failure. The trade-off is that your webhook surface changes whenever a policy changes — which is exactly what Block 4 exploits and what Block 9 debugs.

**Q0.2** The autogen transformation is implemented in the Kyverno engine library, which is compiled into *both* the controller and the CLI. If the CLI is a different minor version from the cluster, the derived rule names, the derived controller set, or the path rewriting can differ — so `kyverno test` can go green against rules the cluster would never generate. The concrete artifact that differs is the derived rule (its name and its `match.resources.kinds`), and therefore every `results[].rule` entry in your `Test` manifests.

### Block 1

**Q1.1** Every workload controller in Kubernetes embeds a `PodTemplateSpec`, but at one of two depths. `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `ReplicaSet` and `ReplicationController` all expose it at `spec.template`. `CronJob` is the outlier: it embeds a `JobTemplateSpec` at `spec.jobTemplate`, which itself contains the `PodTemplateSpec` at `spec.jobTemplate.spec.template`. Autogen therefore needs exactly two path prefixes, so it emits exactly two rules — one whose `match` lists all the `spec.template` controllers, and one dedicated to `CronJob`, distinguished by the `autogen-cronjob-` prefix.

**Q1.2** *GitOps:* `.status` is a server-owned subresource. Because Kyverno writes derived rules there rather than mutating `.spec`, the object in the cluster still matches the object in Git — no drift, no reconciliation fight with Argo CD or Flux, no `kubectl diff` noise. (This was not always true: older Kyverno releases injected derived rules directly into `spec.rules`, which produced exactly that fight.) *Policy authoring:* `.spec` remains the single source of authored intent, so a code review shows only what a human wrote. The derived rules are an implementation detail you can inspect but never need to maintain — and never need to keep in sync when you edit the original.

**Q1.3** Whatever your cluster printed is the authoritative answer for your version; both `["DaemonSet","Deployment","Job","StatefulSet","ReplicaSet","ReplicationController"]` and a shorter list without the last two are plausible depending on release. The reason to drop `ReplicaSet` and `ReplicationController` from the default: they are intermediate objects created by the Deployment controller, not by users. Validating them adds a second, redundant admission check on every Deployment rollout (one on the Deployment, one on each new ReplicaSet), inflates the webhook surface with high-churn resources, and — worst — a rejection at the ReplicaSet layer produces exactly the invisible failure mode of Block 3, since no human submitted that object. Governing the Deployment is sufficient, because the ReplicaSet's pod template is copied from it.

**Q1.4** 63 minus the length of the longest prefix. `autogen-cronjob-` is 16 characters, so an author-written rule name must be **47 characters or fewer** to survive the CronJob derivation. A 50-character rule name will validate fine on its own and then fail — or be silently skipped — when autogen tries to derive the CronJob variant. Keep rule names short and semantic; this is a real cause of "the policy works for Deployments but not CronJobs".

### Block 2

**Q2.1** (a) `spec.template` — the rule body is relocated under `spec.template`, so a Pod-level `spec.containers` becomes `spec.template.spec.containers` and a Pod-level `metadata.labels` becomes `spec.template.metadata.labels`. (b) `spec.jobTemplate.spec.template` — so the same two become `spec.jobTemplate.spec.template.spec.containers` and `spec.jobTemplate.spec.template.metadata.labels`.

**Q2.2** The engineer sees `Pod must set runAsNonRoot` while trying to create a **Deployment**, and the failure path points at `/spec/template/spec/containers/0/securityContext/`. The message names an object they did not submit, so the natural reaction is "I'm not creating a Pod, this policy is misfiring" — and the actual fix location (the pod template inside the Deployment) is never stated. Write messages that name the *field*, not the *kind*: `message: "Every container must set securityContext.runAsNonRoot=true."` — true whether the object is a Pod, a Deployment or a CronJob. As a rule: never name a Kind in the message of a rule that will be autogenned.

**Q2.3** It must rewrite the JMESPath/variable expression the same way it rewrites the pattern, to `{{ request.object.spec.template.spec.containers[0].image }}` (and to `{{ request.object.spec.jobTemplate.spec.template.spec.containers[0].image }}` in the CronJob variant). Autogen is a transformation of the *whole rule body* — pattern, `deny` conditions, preconditions and variable references — not just the pattern. If a variable reference is left un-rewritten it resolves against the wrong object shape and evaluates to null, which typically makes the rule silently pass rather than fail. This is why hand-rolled "I'll just write the Deployment rule myself" copies are more fragile than autogen: humans forget the variables.

**Q2.4** `namespaces` is a `match` selector against the *submitted object's* namespace, and a Deployment lives in the same namespace as the Pods it produces — so the scope is preserved verbatim. A field where verbatim copying would be wrong is anything that selects on the object's own identity or shape rather than its location: `match.resources.names` (a Deployment named `web` produces Pods named `web-<rs>-<pod>`, so a Pod-level name filter does not carry over), and `match.resources.selector` on labels (the Deployment's own labels are not the pod template's labels — see Block 5). Selectors and name filters are the places to be suspicious; namespace and operations carry over cleanly.

### Block 3

**Q3.1** Yes, it is being enforced — but only at the Pod admission boundary, which no user ever crosses directly. The Deployment object itself violates no rule Kyverno is watching, so the API server admits it. The violation is caught later, when the ReplicaSet controller (a system component, using its own service account) submits a Pod. Enforcement is real; *feedback* is what was lost. Exit code 0 from `kubectl apply` is not evidence of compliance in a cluster without autogen.

**Q3.2** The ReplicaSet controller retries Pod creation with exponential backoff, but it never gives up on a `FailedCreate` from admission — the desired replica count stays unsatisfied forever. Each attempt is a full API server write path plus a webhook round-trip to Kyverno plus an event write. Dozens of such Deployments produce a permanent background load of rejected `CREATE pods` requests and event churn, all of it invisible on the Deployment object itself. The backoff caps the rate but never terminates it; you are paying for a policy decision to be re-litigated indefinitely. Worse, the events age out of etcd (default TTL 1h), so a Deployment that has been stuck for a day shows `describe rs` with an empty Events section — the only evidence of the root cause has expired.

**Q3.3** They are the same answer here, which is unusual and worth noting: autogen on is better on both axes. Security-wise the two are equivalent at the enforcement boundary (no non-compliant Pod runs in either case), but autogen on is strictly better for *policy legibility* — the rejection is attributable to a human action, which is what an audit trail needs. Operability-wise autogen on is dramatically better: fail fast, at submission, with the offending path in the error. The genuine trade-off is elsewhere — autogen on means a larger webhook surface and admission latency on more resource kinds (Block 4), and it means a Kyverno outage with `failurePolicy: Fail` blocks Deployment writes, not just Pod writes.

**Q3.4** With autogen **on**, the server-side dry run submits the Deployment through the admission chain, hits the derived rule, and the gate fails — the pipeline catches the violation before merge. With autogen **off**, the dry run submits only the Deployment, which passes, and the gate is green; the violation surfaces in production as a Deployment that never scales up. A server-side dry run can only ever test the object you submit, so its coverage is exactly the set of kinds your policies intercept. This is the strongest practical argument for autogen: it is what makes shift-left admission testing meaningful for workloads.

### Block 4

**Q4.1** The annotation constrains which controller kinds autogen derives rules for. Kyverno's policy controller re-derives `.status.autogen.rules` from `.spec.rules` plus the annotation. A separate reconciler then computes the union of every installed policy's match constraints — authored *and* derived — and writes that union into the `ValidatingWebhookConfiguration` `rules`. Because the CronJob rule no longer exists, `cronjobs` is no longer in the union, so the API server stops forwarding CronJob admission requests to Kyverno at all. The setting that makes this dynamic is `autoUpdateWebhooks` (Helm value / controller flag, enabled by default); disable it and you must maintain the webhook rules by hand, at which point narrowing the annotation stops narrowing the webhook.

**Q4.2** *For removing `Job`:* every Job creation currently costs a webhook round-trip on the critical path of the Argo CD sync, adding latency to thousands of objects per hour and coupling Job creation to Kyverno's availability — with `failurePolicy: Fail`, a Kyverno restart stalls the whole Job pipeline. Removing `Job` from the annotation deletes that entire traffic class from the admission path. *Against:* you lose fail-fast feedback on Jobs — a non-compliant Job is admitted and then fails at Pod creation, in the invisible way of Block 3, which for a Job means it never runs and the sync reports success. You also lose the CI dry-run gate for Jobs. What you do *not* lose is enforcement: the Pod rule still blocks the Pod. The decision is "where do I want the error to appear", not "do I want the error". In practice, keep `Job` if Jobs are user-authored artifacts in Git; drop it if they are machine-generated fan-out.

**Q4.3** No. Five minutes later the CronJob controller creates a Job, the Job controller creates a Pod, and the Pod is rejected by the still-active Pod rule. The rejection appears as a `FailedCreate` warning event on the **Job** object (`kubectl -n autogen-lab describe job report-<timestamp>`), and the Job records failed pod creation attempts. Nothing appears on the CronJob itself beyond `LAST SCHEDULE`, and after the event TTL expires there is no trace at all — a scheduled task that silently stopped producing output.

**Q4.4** Write `pod-policies.kyverno.io/autogen-controllers: "none"` — quoted, as an explicit string. Unquoted `none` is fine in YAML 1.2 but the quoting removes any ambiguity with `~`/null conventions and survives templating through Helm, where an unquoted bare word can be coerced. An empty string is *not* equivalent: it is not the sentinel Kyverno looks for, and the behaviour on an unrecognised value is version-dependent — do not rely on it. CI assertion: `kubectl get cpol <name> -o jsonpath='{.status.autogen}'` must return `{}` or empty; assert on `.status`, not on the annotation, because status is what the engine actually derived. Asserting on the annotation only proves what you asked for, not what happened.

### Block 5

**Q5.1** Because the rule's *subject* is the Pod, and the Pod's labels are declared in the controller's pod template. A Deployment's own `metadata.labels` describe the Deployment; the Pods it creates inherit their labels from `spec.template.metadata.labels` and nothing else. If autogen mapped Pod `metadata.labels` to Deployment `metadata.labels`, the derived rule would enforce a property that has no effect on any Pod — the policy would pass while every Pod in the cluster remained unlabelled. The transformation preserves the *semantics* of the authored rule (which Pods are compliant), which is the only correct invariant; the surprise is a symptom of authors thinking in objects rather than in the Pod the object produces.

**Q5.2** With autogen at its default, rule 1 (Pod-scoped) would derive `autogen-pod-template-label`, matching Deployment/StatefulSet/DaemonSet and checking `spec.template.metadata.labels.team`. Rule 2 explicitly checks the same Deployment's `metadata.labels.team`. The Deployment is now evaluated **twice by the same policy** against two different paths — which is arguably what the author wanted, but it is achieved by accident and is fragile: the derived rule's coverage silently follows the annotation default, so a Kyverno upgrade that changes the default controller set changes rule 1's blast radius without any Git change. Setting `none` makes both rules' scopes explicit and reviewable. (Note the design tension: with `none`, rule 1 no longer catches a Deployment whose pod template lacks the label until Pod admission. If you want both checks fail-fast, keep autogen on and drop rule 2's overlap, or make rule 2 explicit and accept the duplication knowingly.)

**Q5.3** Autogen is suppressed for that rule regardless of the annotation, because the rule already matches pod controllers directly. Kyverno will not derive controller rules from a rule that names controllers — deriving would produce a rule matching the same kinds as the original, with a different path, which is the double-evaluation trap in a form nobody asked for. This is the same suppression you observe in Block 7. The annotation is therefore belt-and-braces here: it documents intent for the reader and protects rule 1, while rule 2 is self-suppressing.

**Q5.4** It cannot be equivalent, and the derived rule would be actively wrong. `metadata.ownerReferences` on a Pod is set by the ReplicaSet controller *after* admission of the Deployment; the Deployment's `spec.template.metadata` has no `ownerReferences` field populated at any point, so the derived check evaluates against a path that is always absent. The general principle: **autogen is only sound for fields the controller's pod template actually carries** — `spec.*` and the template's `metadata.labels` / `metadata.annotations`. Fields populated by the API server or by controllers at Pod-creation time (`ownerReferences`, `metadata.name`, `metadata.uid`, `status.*`, defaulted `spec.nodeName`, injected service-account tokens) have no template equivalent. A policy over those fields must be Pod-only, with `autogen-controllers: none` set explicitly and a comment explaining why — otherwise a later reader "fixes" the missing annotation and introduces a rule that can never match.

### Block 6

**Q6.1** `cluster-autoscaler.kubernetes.io/safe-to-evict` is read by the cluster autoscaler off the **Pod** object when deciding whether a node can be drained and removed. An annotation on the Deployment object is never consulted by the autoscaler and would have no effect whatsoever. The only way for the annotation to reach the Pod is to be present in the pod template, which is precisely where autogen put it — and because it is in the template, every future Pod created by that Deployment inherits it, including Pods created after a rollout or a node failure. Mutating only the Pod at Pod-admission would also work, but would have to happen on every Pod creation forever, and would leave no record on the Deployment.

**Q6.2** Mutating the **Deployment** (autogen path) writes the change into the persisted Deployment spec, so `kubectl get deploy -o yaml` shows it — and that is exactly the GitOps drift: Argo CD or Flux compares live state against Git, sees an annotation Git does not have, marks the app `OutOfSync`, and may revert it, triggering a mutation/reversion loop. Mutating only the **Pod** leaves the Deployment byte-identical to Git, so no drift, but the change is invisible in the Deployment spec and reapplied on every Pod creation. Which you want depends on the reconciler: for GitOps-managed workloads, prefer Pod-level mutation (`autogen-controllers: none` on the mutate policy) plus an Argo CD `ignoreDifferences` entry if you must mutate the controller; for imperatively managed or human-applied workloads, controller-level mutation is better because the change is durable, auditable and visible to anyone reading the object. The failure mode to avoid is controller-level mutation *plus* a strict GitOps reconciler with no ignore rule.

**Q6.3** A `validate` or `mutate` rule makes a statement about the object under admission, so relocating it to a nested path preserves meaning. A `generate` rule creates a *different, unrelated* object as a side effect of a trigger. There is no path to relocate, and the question "what is the Deployment-equivalent of 'when a Pod appears, create a NetworkPolicy'?" has no single answer — should the NetworkPolicy be created once per Deployment or once per Pod? What is the owner reference? What happens on scale-up? The transformation has no meaning-preserving definition, so autogen correctly declines. If you want a controller-triggered generate rule, write it explicitly with the controller in `match`.

**Q6.4** JSON patches (`patchesJson6902`) are **not** autogenned; `.status.autogen` is absent for `json-patch-demo`. The mechanical reason is that RFC 6902 patches address the object through opaque JSON pointers — `/spec/containers/0/image` is a string, not a structured field path Kyverno can reliably rewrite. Prefixing it to `/spec/template/spec/containers/0/image` would be a naive string edit that breaks on any pointer that does not begin at a relocatable root (`/metadata/name`, escaped `~1` segments, `-` append markers on arrays whose length differs between the Pod and the template context, or `test`/`move`/`copy` ops referencing two paths). Rather than guess, Kyverno declines. Practical consequence: **use `patchStrategicMerge` (or `mutate.patchesJson6902` only with `autogen-controllers: none` and an explicit controller rule) whenever you need the mutation to apply to workloads.** A `patchesJson6902` rule matching Pods is a Pod-only rule, silently.

**Q6.5** Because those policies match `Pod`, and Kyverno autogen derives the equivalent `spec.template.spec` rules for Deployments, StatefulSets, DaemonSets, Jobs and CronJobs automatically — the library ships one Pod-scoped rule per control and relies on autogen for the entire workload surface. This is why the Kyverno PSS policy set is a few dozen rules rather than a few hundred, and why disabling autogen globally would quietly reduce it to a Pod-admission-only control set.

### Block 7

**Q7.1** Because the author already declared how Deployments should be handled. If Kyverno autogenned anyway, a submitted Deployment would be evaluated twice by the same rule name lineage: once by the authored rule against `metadata.labels` (the Deployment's own labels) and once by the derived rule against `spec.template.metadata.labels`. The Deployment would have to satisfy both, which is stricter than anything the author wrote and impossible to infer from reading the policy. Suppression makes explicit intent win over inference — the correct default for a policy engine, where surprising strictness is as dangerous as surprising laxity.

**Q7.2** A Deployment's own `metadata.labels`. The pattern `metadata.labels.team: "?*"` is applied verbatim to whatever object matches, and `Deployment` matches, so Kyverno checks the Deployment object's top-level labels. Almost certainly not what the author meant: they wrote `Pod, Deployment` intending "cover both Pods and the Deployments that create them", and got "Pods must be labelled, and separately, Deployment objects must be labelled" — while the Pods created by a labelled Deployment with an unlabelled template pass through this policy untouched at the Deployment layer and are caught only at Pod admission. The `kinds: [Pod, Deployment]` idiom is a reliable review smell: it means the author did not know autogen existed.

**Q7.3**
```bash
kubectl get cpol -o json | jq -e '
  [ .items[]
    | select(any(.spec.rules[]?; (.match.any[]?.resources.kinds[]? // empty) == "Pod"))
    | select((.status.autogen.rules // []) | length == 0)
    | .metadata.name
  ] | if length == 0 then true
      else ("policies match Pod but derived no autogen rules: " + (.|tostring) | halt_error(1)) end'
```
The assertion is: *any policy with a Pod-matching rule must have a non-empty `.status.autogen.rules`*. Allow documented exceptions by skipping policies carrying an explicit `pod-policies.kyverno.io/autogen-controllers: "none"` annotation **plus** a `policy.example.com/autogen-exempt-reason` annotation — the reason string is what makes the exception reviewable rather than a rubber stamp. Run it against a `--dry-run=server` apply of the policy directory in CI, so it gates the merge rather than reporting after rollout.

**Q7.4** Autogen still runs. `exclude` narrows which objects a rule applies to; it does not change the fact that the rule's `match` targets `Pod`, which is the trigger condition for derivation. The `exclude` block is copied into the derived rules along with everything else — so you end up with a derived rule that matches `Deployment` in `match` and excludes `Deployment` in `exclude`, which matches nothing. The rule is effectively dead for Deployments while looking active in `.status`. Verify with `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[0]}' | yq -P` and read the `exclude` block. Excluding a controller kind is not how you scope autogen — the annotation is.

### Block 8

**Q8.1** From the Kyverno engine library, which the CLI links in directly. Autogen is a **library-side** transformation applied whenever a policy is loaded and prepared for evaluation, not a controller-side mutation of stored state — the controller merely persists the result into `.status` for observability. This is what makes offline testing of derived rules possible at all, and it is also why CLI/cluster version skew (Q0.2) produces divergent results: two copies of the same transformation at different versions.

**Q8.2** A policy report entry — and every `results[]` row in a `Test` — is keyed by the triple (policy, rule, resource). The rule that actually evaluated a Deployment is `autogen-check-runasnonroot`; that is the name that appears in the `PolicyReport`, in the admission rejection message, and in `kyverno apply` output. Asserting on `check-runasnonroot` for a Deployment asserts on a row that does not exist, hence `Not found`. The rule name is the identity of the evaluated rule, not of the authored one — and the derived rule is a genuinely different rule with a different match and a different path.

**Q8.3** The most likely cause is a change in the autogen controller defaults or in the derived rule naming/shape between versions — e.g. `ReplicaSet` and `ReplicationController` dropped from the default set, so a `Test` row asserting a result on a ReplicaSet resource now finds no matching rule. First command: `kyverno apply policy.yaml --resource resource.yaml` and read the rule names in the output; equivalently `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[*].name}'` on the upgraded cluster. Compare against the `rule:` values in your `Test` manifests. Fix by updating the test expectations, and — if the coverage change was unintended — by pinning the controller set explicitly in the annotation rather than relying on the default, which is what let an upgrade change your policy's blast radius silently.

**Q8.4**
```bash
kyverno apply policies/ --resource testdata/deployment.yaml --policy-report -o report.yaml
grep -q 'rule: autogen-check-mixed' report.yaml || { echo "no autogen rule fired on Deployment"; exit 1; }
```
More robustly, encode it as a `Test` case that asserts a `fail` result on a Deployment resource for the derived rule name — if autogen was suppressed, the row will not exist and `kyverno test` reports `Not found`, failing the build. The general pattern: **for every Pod-scoped policy, keep one controller-shaped fixture in `testdata/` and one expected result naming the derived rule.** That single fixture is what turns silent autogen suppression into a red build.

### Block 9

**Q9.1** Command **(e)** — `kubectl get cpol <name> -o jsonpath='{.status.autogen}'` returning `{}`. It goes directly to the invariant that explains the symptom: the policy exists and enforces, but derived no controller rules, therefore nothing intercepted the Deployment. (c) is the more natural first instinct and does reveal the rejected Pod, but it tells you *that* the Pod was blocked, not *why the Deployment was not* — you still have to reason back to autogen. (f) then gives you the cause of (e) in one more command. In an incident, run (c) and (e) together: (c) confirms the policy is the culprit, (e) explains the missing feedback.

**Q9.2** `READY: True` means the policy compiled, its webhook is configured and its rules are loaded — a statement about the policy's own health, not its coverage. `Enforce` means *when a rule matches, deny*. Neither says anything about *which kinds* match. With autogen suppressed the policy matches only `Pod`, so a submitted Deployment matches nothing and is admitted; the Pod that the ReplicaSet controller later submits matches and is denied, in Enforce mode, correctly. The policy is fully healthy and fully enforcing — on a resource the user never touches. `READY` and `VALIDATE ACTION` are not coverage indicators; `.status.autogen` and the webhook rules are.

**Q9.3** *If a policy's rule matches `Pod` and `.status.autogen.rules` is empty, Kyverno intercepts only `pods` — so workload objects are admitted unchecked and the violation will surface as a `FailedCreate` event on the ReplicaSet or Job, not at `kubectl apply`.* The chain runs annotation → `.status.autogen.rules` → webhook `rules`, each derived from the one before, so reading any link tells you the state of the next. In a runbook, pair it with the check command: `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[*].name}'`.

**Q9.4** Use the `jq` pipeline from Q7.3, tightened to Enforce policies and to the documented-exception carve-out:

```bash
kubectl get cpol -o json | jq -e '
  [ .items[]
    | select(.spec.validationFailureAction == "Enforce"
             or any(.spec.rules[]?.validate?; .failureAction == "Enforce"))
    | select(any(.spec.rules[]?; (.match.any[]?.resources.kinds[]? // empty) == "Pod"))
    | select((.status.autogen.rules // []) | length == 0)
    | select((.metadata.annotations["policy.example.com/autogen-exempt-reason"] // "") == "")
    | .metadata.name
  ] | if length == 0 then true
      else ("Enforce policies match Pod, derived no autogen rules, and have no exemption reason: "
             + (.|tostring) | halt_error(1)) end'
```

Run it against a server-side dry-run apply of the policy directory so it gates the PR. The exemption annotation is deliberately a free-text *reason*, not a boolean: a boolean gets set to `true` without thought, a reason string has to be written and reviewed.

### Block 10

**Q10.1** `object.spec.template.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)` — the same `spec.template` relocation as in the v1 API, applied to the CEL expression's root accessor rather than to a YAML pattern. Compare against `kubectl get vpol vpol-require-nonroot -o yaml | yq '.status.autogen'`; the generated expression is the ground truth for your version, and reading it is the point of the exercise. Note that CEL autogen has to rewrite the accessor inside an arbitrary expression, which is a harder transformation than relocating a pattern tree — inspect what it does with `oldObject`, with `variables`, and with any `matchConditions` you add.

**Q10.2** (1) **Schema validation and discoverability.** A typed field under `spec` is validated by the API server against the CRD's OpenAPI schema: a typo like `deployment` (singular) or `Deployments` is rejected at apply time. An annotation is an opaque string — a typo is accepted silently and produces the Block 7 failure mode, where the policy looks configured and covers nothing. (2) **Tooling and review.** `kubectl explain` documents it, IDE schema completion offers it, admission policies and conftest rules can assert on it structurally, and a `kubectl diff` shows a semantic field change rather than an annotation string edit. A third: annotations are a shared namespace routinely rewritten by controllers, GitOps tools and mutating policies, so an annotation-encoded control is at risk of being clobbered by something with no idea it is load-bearing.

**Q10.3** It signals the match is expressed at the **API resource** layer rather than the Kind layer — lowercase plurals are the REST resource names that appear in `ValidatingWebhookConfiguration` rules, in RBAC `resources:` lists, and in the API discovery document. The new CEL policy types align with upstream Kubernetes `ValidatingAdmissionPolicy`, whose `matchConstraints.resourceRules` also use `apiGroups`/`apiVersions`/`resources` in resource form. So the derived match plugs straight into the same structure the API server itself uses for admission, with no Kind-to-resource translation step in between — one less place for a mismatch.

**Q10.4** The equivalent is to **omit the `spec.autogen` block entirely**, or set it to the empty controller list the schema defines for "no autogeneration" — check `kubectl explain validatingpolicies.spec.autogen.podControllers` for your version rather than assuming, since the empty-vs-absent distinction is exactly the kind of thing that differs. Do not assume equivalence: verify by (1) confirming `.status.autogen` is empty on the new policy, (2) running `kyverno apply` against the same controller fixtures used for the old policy and checking that no rule fires on the controller and the Pod rule still fires on the Pod, and (3) diffing the webhook `rules` before and after the migration — `kubectl get validatingwebhookconfiguration -o jsonpath=...` — since the resource list is the observable end effect of the whole chain. Migrating policy types is a change of engine, not just of syntax; assert on the end effect, not on the config that is supposed to produce it.

</details>

---

## Sources

- KCA Curriculum, CNCF — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Kyverno documentation, "Auto-Gen Rules for Pod Controllers" — <https://kyverno.io/docs/writing-policies/autogen/> (use the version selector to match your cluster; the page moved under the policy-type sections in the 1.14 docs reorganisation)
- Kyverno documentation, mutation rules and anchors — <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno CLI, `test` command reference — <https://kyverno.io/docs/kyverno-cli/usage/test/>
- Kyverno CLI, `apply` command reference — <https://kyverno.io/docs/kyverno-cli/usage/apply/>
- Kyverno source and release notes — <https://github.com/kyverno/kyverno>
- Kubernetes API reference, `PodTemplateSpec` in workload controllers — <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/>
- Kubernetes documentation, Dynamic Admission Control — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>