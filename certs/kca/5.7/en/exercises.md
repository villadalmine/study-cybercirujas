# KCA 5.7 — Variables & API Calls in Policies

## Guided Exercises

> **Scope.** Kyverno's variable system (`{{ ... }}` JMESPath expressions over the AdmissionReview), the `context` block (`configMap`, `apiCall`, `variable`, `globalReference`, `imageRegistry`), evaluation order, failure semantics, and the RBAC that decides whether an `apiCall` succeeds at all. Every step below is executed against a live cluster; nothing is theoretical.

---

## Lab 0 — Environment

You need a throwaway cluster (kind, k3d, minikube) with cluster-admin, `kubectl`, `helm`, and the `kyverno` CLI.

1. Create the cluster and install Kyverno:

```bash
kind create cluster --name kca-vars

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace --wait
```

2. Record **exactly** which version you are testing against — variable and context features moved between releases, and the answers below depend on it:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected output (yours may differ):

```
ghcr.io/kyverno/kyverno:v1.13.2
```

3. Confirm the four controllers and their ServiceAccounts. Only the **admission** controller serves admission requests; the **background** controller re-evaluates policies for existing resources; the **reports** controller writes PolicyReports:

```bash
kubectl -n kyverno get deploy
kubectl -n kyverno get sa
```

```
NAME                           READY   UP-TO-DATE   AVAILABLE
kyverno-admission-controller   1/1     1            1
kyverno-background-controller  1/1     1            1
kyverno-cleanup-controller     1/1     1            1
kyverno-reports-controller     1/1     1            1
```

4. Install the CLI (same minor version as the cluster component whenever possible) and verify:

```bash
kyverno version
```

5. Create the lab namespace:

```bash
kubectl create namespace vars-lab
kubectl label namespace vars-lab cost-center=eng-platform
```

**Questions — Lab 0**

- **0.1** Why does it matter *which* of the four ServiceAccounts is used when a policy performs an `apiCall`?
- **0.2** A rule that reads `{{ request.userInfo.username }}` cannot be evaluated by one of those controllers. Which one, and why?

---

## Exercise 1 — Where variables come from: the AdmissionReview

Kyverno's variables are not magic globals. Almost all of them are JMESPath paths into the `AdmissionReview` object the API server sends to the webhook, plus a handful of convenience aliases Kyverno derives from it.

1. Write a policy that denies everything and prints the request context back at you. This is the single most useful debugging trick for this topic:

```yaml
# 01-var-anatomy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: var-anatomy
  annotations:
    policies.kyverno.io/title: Print the request context
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: echo-request-context
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      validate:
        message: >-
          op={{ request.operation }}
          kind={{ request.object.kind }}
          user={{ request.userInfo.username }}
          groups={{ request.userInfo.groups | join(',', @) }}
          sa={{ serviceAccountName || 'none' }}
          sans={{ serviceAccountNamespace || 'none' }}
          ns={{ request.namespace }}
          name={{ request.object.metadata.name || 'none' }}
          images={{ request.object.spec.containers[].image | join(',', @) }}
        deny:
          conditions:
            all:
              - key: "{{ request.operation }}"
                operator: AnyIn
                value:
                  - CREATE
                  - UPDATE
```

```bash
kubectl apply -f 01-var-anatomy.yaml
kubectl get clusterpolicy var-anatomy
```

```
NAME          ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
var-anatomy   true        false        Enforce           True    8s
```

2. Trigger it as yourself:

```bash
kubectl -n vars-lab run demo --image=nginx:1.27.1 --dry-run=server
```

Expected output (abridged — the username depends on your kubeconfig):

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/demo was blocked due to the following policies

var-anatomy:
  echo-request-context: 'op=CREATE kind=Pod user=kubernetes-admin
    groups=system:masters,system:authenticated sa=none sans=none ns=vars-lab
    name=demo images=nginx:1.27.1'
```

3. Now trigger it as a ServiceAccount, so the `serviceAccountName` alias is populated:

```bash
kubectl -n vars-lab create serviceaccount deployer
kubectl -n vars-lab create rolebinding deployer-edit \
  --clusterrole=edit --serviceaccount=vars-lab:deployer

kubectl -n vars-lab run demo --image=nginx:1.27.1 --dry-run=server \
  --as=system:serviceaccount:vars-lab:deployer
```

```
...
  echo-request-context: 'op=CREATE kind=Pod
    user=system:serviceaccount:vars-lab:deployer
    groups=system:serviceaccounts,system:serviceaccounts:vars-lab,system:authenticated
    sa=deployer sans=vars-lab ns=vars-lab name=demo images=nginx:1.27.1'
```

4. Prove that `background: false` is not optional here. Flip it to `true` and re-apply:

```bash
sed 's/background: false/background: true/' 01-var-anatomy.yaml | kubectl apply -f -
```

```
The ClusterPolicy "var-anatomy" is invalid: spec.rules[0]: Invalid value: ...:
 variables {{ request.userInfo.username }} are not allowed in background mode.
 Set spec.background=false
```

Restore the file (`kubectl apply -f 01-var-anatomy.yaml`) before continuing.

5. Explore the same paths offline with the CLI, which evaluates JMESPath against any YAML/JSON document:

```bash
cat > pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: demo
  namespace: vars-lab
  labels:
    tier: web
spec:
  containers:
    - name: web
      image: ghcr.io/nginxinc/nginx-unprivileged:1.27
      securityContext:
        runAsNonRoot: true
    - name: sidecar
      image: registry.k8s.io/pause:3.10
EOF

kyverno jp query -i pod.yaml 'spec.containers[].image'
kyverno jp query -i pod.yaml 'spec.containers[?securityContext.runAsNonRoot != `true`].name'
kyverno jp query -i pod.yaml 'metadata.labels."tier"'
```

```
# spec.containers[].image
[
  "ghcr.io/nginxinc/nginx-unprivileged:1.27",
  "registry.k8s.io/pause:3.10"
]
```

6. List the non-standard functions Kyverno adds on top of the JMESPath specification:

```bash
kyverno jp function | grep -E 'semver_compare|regex_match|time_now_utc|parse_json|x509_decode'
kyverno jp function semver_compare
```

**Questions — Exercise 1**

- **1.1** In step 2 `name=demo`, but if you create a Pod from a Deployment the same expression often returns `none`. Why, and which field should you read instead?
- **1.2** `serviceAccountName` returned `deployer`, not `system:serviceaccount:vars-lab:deployer`. What is that alias derived from, and what happens to it when a human user submits the request?
- **1.3** Step 4 failed policy validation. State the rule in one sentence, and explain the design reason behind it.
- **1.4** `request.object` is `null` for one operation. Which one, and what do you use in its place?
- **1.5** Is `kyverno jp query` talking to the cluster in step 5? What does that imply about what it can and cannot reproduce?

---

## Exercise 2 — Derived variables: `{{ images }}`, `foreach`, `{{ element }}`

Kyverno pre-parses every container image in the resource into an `images` structure. Doing this yourself with string splitting is a classic production bug.

1. Print the parsed structure for a **bare** image reference:

```yaml
# 02-image-vars.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: image-vars
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: show-image-parts
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      validate:
        message: >-
          registry={{ images.containers.web.registry }}
          path={{ images.containers.web.path }}
          name={{ images.containers.web.name }}
          tag={{ images.containers.web.tag || 'none' }}
          digest={{ images.containers.web.digest || 'none' }}
          reference={{ images.containers.web.reference }}
          raw-split={{ request.object.spec.containers[0].image | split(@, '/') | [0] }}
        deny: {}
```

```bash
kubectl apply -f 02-image-vars.yaml

kubectl -n vars-lab run demo --image=nginx:1.27.1 --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"web","image":"nginx:1.27.1"}]}}'
```

2. Compare with a fully qualified reference:

```bash
kubectl -n vars-lab run demo --dry-run=server \
  --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --overrides='{"spec":{"containers":[{"name":"web","image":"ghcr.io/nginxinc/nginx-unprivileged:1.27"}]}}'
```

Read both `registry=` and `raw-split=` values carefully — they disagree in the first case.

3. Inspect where the normalization comes from:

```bash
kubectl -n kyverno get configmap kyverno -o yaml | grep -iE 'defaultRegistry|enableDefaultRegistryMutation'
```

4. Replace the hardcoded container name `web` with an iteration that works for any Pod, including init and ephemeral containers. `foreach` introduces two more variables, `{{ element }}` and `{{ elementIndex }}`:

```yaml
# 03-registry-allowlist.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: registry-allowlist
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: only-approved-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      validate:
        message: "Container images must come from an approved registry."
        foreach:
          - list: "request.object.spec.[containers, initContainers, ephemeralContainers][]"
            deny:
              conditions:
                all:
                  - key: "{{ images.containers.\"{{ element.name }}\".registry || images.initContainers.\"{{ element.name }}\".registry }}"
                    operator: AnyNotIn
                    value:
                      - ghcr.io
                      - registry.k8s.io
```

```bash
kubectl apply -f 03-registry-allowlist.yaml
kubectl delete clusterpolicy image-vars

kubectl -n vars-lab run bad --image=nginx:1.27.1 --dry-run=server
kubectl -n vars-lab run good --image=registry.k8s.io/pause:3.10 --dry-run=server
```

Expected:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/bad was blocked due to the following policies

registry-allowlist:
  only-approved-registries: Container images must come from an approved registry.
```

```
pod/good created (server dry run)
```

**Questions — Exercise 2**

- **2.1** For `image: nginx:1.27.1`, what did `registry=` report and what did `raw-split=` report? Explain the difference and name the two ConfigMap keys that govern it.
- **2.2** An allowlist policy written as `split(image, '/') | [0]` is bypassable. Give a concrete image string that defeats it but is caught by `images.containers.<name>.registry`.
- **2.3** In step 4, `request.object.spec.[containers, initContainers, ephemeralContainers][]` is a multiselect list followed by a flatten. What would break if you wrote `request.object.spec.containers[]` only, and what would break if you omitted the trailing `[]`?
- **2.4** Inside `foreach`, `{{ element }}` is available but `{{ images }}` is still the whole-Pod map. Why does the policy above have to nest `{{ element.name }}` inside another `{{ }}`?
- **2.5** This policy sets `background: true` while Exercise 1 required `false`. What makes the difference?

---

## Exercise 3 — External data: `configMap` context

The `context` block is evaluated **per rule**, after `match`/`exclude` selection and before `preconditions` and the `validate`/`mutate` body.

1. Create the data source:

```yaml
# 04-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-allowlist
  namespace: vars-lab
data:
  allowed: "ghcr.io,registry.k8s.io,quay.io"
  team-limits: |
    {
      "eng-platform": { "maxReplicas": 20 },
      "eng-data":     { "maxReplicas": 5  }
    }
```

```bash
kubectl apply -f 04-cm.yaml
```

2. Consume it, including the JSON-in-a-key case that `parse_json` exists for:

```yaml
# 05-cm-context.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: registry-allowlist-cm
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: allowlist-from-configmap
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      context:
        - name: allowlist
          configMap:
            name: registry-allowlist
            namespace: vars-lab
        - name: limits
          variable:
            jmesPath: "parse_json(allowlist.data.\"team-limits\")"
            default: {}
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      validate:
        message: >-
          Registry not allowed. Permitted: {{ allowlist.data.allowed }}.
          (eng-platform cap is {{ limits."eng-platform".maxReplicas || 'unset' }})
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ images.containers.\"{{ element.name }}\".registry }}"
                    operator: AnyNotIn
                    value: "{{ allowlist.data.allowed | split(@, ',') }}"
```

```bash
kubectl delete clusterpolicy registry-allowlist
kubectl apply -f 05-cm-context.yaml

kubectl -n vars-lab run q --image=quay.io/prometheus/busybox:latest --dry-run=server
kubectl -n vars-lab run d --image=docker.io/library/nginx:1.27.1 --dry-run=server
```

The `quay.io` Pod is admitted; the `docker.io` one is denied with the message listing the current allowlist.

3. Change the data **without touching the policy** and observe that behaviour follows:

```bash
kubectl -n vars-lab patch configmap registry-allowlist \
  --type=merge -p '{"data":{"allowed":"ghcr.io,registry.k8s.io"}}'

sleep 5
kubectl -n vars-lab run q2 --image=quay.io/prometheus/busybox:latest --dry-run=server
```

4. Break it deliberately — point the context at a ConfigMap that does not exist:

```bash
kubectl -n vars-lab delete configmap registry-allowlist
kubectl -n vars-lab run q3 --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 --dry-run=server
```

Observe whether the Pod is admitted or rejected, then inspect the controller:

```bash
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=40 | grep -i context
```

Recreate the ConfigMap (`kubectl apply -f 04-cm.yaml`) before continuing.

**Questions — Exercise 3**

- **3.1** The key is `team-limits`, and the expression is `allowlist.data."team-limits"`. Why are the inner double quotes mandatory, and what would `allowlist.data.team-limits` evaluate to in JMESPath?
- **3.2** A ConfigMap value is always a string. What does `parse_json` change about how you can index it, and what happens to the rule if the value is not valid JSON and no `default` is set?
- **3.3** In step 3 you changed cluster state and the decision changed within seconds without re-applying the policy. What mechanism makes that work, and what is the operational risk of policy behaviour living in a ConfigMap that ordinary namespace users can edit?
- **3.4** In step 4, was the Pod admitted or denied? Which policy-level setting decides that outcome, and how would you make a missing ConfigMap fail *open* for this rule specifically?
- **3.5** Where in the evaluation order does `context` run relative to `match` and `preconditions`, and why does that ordering matter for API-server load?

---

## Exercise 4 — `apiCall`: reading live cluster state

`context[].apiCall.urlPath` issues a **GET** against the Kubernetes API using Kyverno's own ServiceAccount, with variables substituted into the path.

1. Deny Pods in namespaces that lack a `cost-center` label, and — in the same policy — copy that label onto the Pod:

```yaml
# 06-apicall-ns.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: namespace-cost-center
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: copy-cost-center-to-pod
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      context:
        - name: costCenter
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}"
            jmesPath: >-
              metadata.labels."cost-center" || 'unassigned'
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              cost-center: "{{ costCenter }}"

    - name: require-cost-center
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      context:
        - name: costCenter
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}"
            jmesPath: >-
              metadata.labels."cost-center" || 'unassigned'
      validate:
        message: >-
          Namespace {{ request.namespace }} has no cost-center label
          (resolved: {{ costCenter }}). Ask platform-eng to label it.
        deny:
          conditions:
            all:
              - key: "{{ costCenter }}"
                operator: Equals
                value: unassigned
```

```bash
kubectl apply -f 06-apicall-ns.yaml
kubectl -n vars-lab run labeled --image=registry.k8s.io/pause:3.10
kubectl -n vars-lab get pod labeled --show-labels
```

```
NAME      READY   STATUS    RESTARTS   AGE   LABELS
labeled   1/1     Running   0          4s    cost-center=eng-platform,run=labeled
```

2. Prove the negative case:

```bash
kubectl create namespace no-cc
kubectl label namespace no-cc kubernetes.io/metadata.name- --overwrite 2>/dev/null

# widen the policy to the new namespace
kubectl patch clusterpolicy namespace-cost-center --type=json \
  -p '[{"op":"add","path":"/spec/rules/1/match/any/0/resources/namespaces/-","value":"no-cc"}]'

kubectl -n no-cc run orphan --image=registry.k8s.io/pause:3.10 --dry-run=server
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/no-cc/orphan was blocked due to the following policies

namespace-cost-center:
  require-cost-center: 'Namespace no-cc has no cost-center label (resolved:
    unassigned). Ask platform-eng to label it.'
```

3. Verify the same GET by hand, as the API server sees it:

```bash
kubectl get --raw "/api/v1/namespaces/vars-lab" | jq '.metadata.labels'
```

4. Exercise the URL query-string form, which is how you avoid pulling entire collections:

```bash
kubectl get --raw "/api/v1/namespaces/vars-lab/pods?labelSelector=run%3Dlabeled" \
  | jq '.items | length'
```

**Questions — Exercise 4**

- **4.1** Both rules declare an identical `context`. Is the API call made once or twice for a single Pod CREATE? Explain why, in terms of what a context entry is scoped to.
- **4.2** Rule 1 mutates and rule 2 validates. Which one is evaluated first, and is that ordering guaranteed by the rule order in this file, by the webhook types, or by neither?
- **4.3** `jmesPath: metadata.labels."cost-center" || 'unassigned'` is doing two jobs. What are they, and what would the rule do differently if you dropped the `|| 'unassigned'` and the label were missing?
- **4.4** In step 4 the selector is written `labelSelector=run%3Dlabeled`. Why the `%3D`, and what is the practical consequence of asking for `/api/v1/pods` with no selector in a 5,000-Pod cluster?
- **4.5** Which identity performed the GET in step 1 — the user who ran `kubectl`, or something else? Why does that distinction matter for security review?

---

## Exercise 5 — `apiCall` and RBAC: the failure mode you will actually hit

1. Check, before writing anything, whether Kyverno may read Secrets:

```bash
kubectl auth can-i list secrets \
  --as=system:serviceaccount:kyverno:kyverno-admission-controller -n vars-lab
```

```
no
```

2. Write a policy that needs exactly that permission — the referenced `imagePullSecret` must carry a label marking it as safe to mount:

```yaml
# 07-pullsecret.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: approved-pull-secrets
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: pull-secret-must-be-approved
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      preconditions:
        all:
          - key: "{{ request.object.spec.imagePullSecrets || `[]` | length(@) }}"
            operator: GreaterThan
            value: 0
      context:
        - name: approved
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}/secrets/{{ request.object.spec.imagePullSecrets[0].name }}"
            jmesPath: >-
              metadata.labels."kyverno.io/pull-secret" || 'false'
      validate:
        message: >-
          imagePullSecret {{ request.object.spec.imagePullSecrets[0].name }} is not
          approved (label kyverno.io/pull-secret=true is missing).
        deny:
          conditions:
            all:
              - key: "{{ approved }}"
                operator: NotEquals
                value: "true"
```

```bash
kubectl apply -f 07-pullsecret.yaml

kubectl -n vars-lab create secret docker-registry regcred \
  --docker-server=ghcr.io --docker-username=bot --docker-password=notreal

kubectl -n vars-lab run puller --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}'
```

Expected — note this is **not** a policy violation, it is a context load failure:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/puller was blocked due to the following policies

approved-pull-secrets:
  pull-secret-must-be-approved: 'failed to load context: failed to fetch data for
    APICall: secrets "regcred" is forbidden: User
    "system:serviceaccount:kyverno:kyverno-admission-controller" cannot get
    resource "secrets" in API group "" in the namespace "vars-lab"'
```

3. Grant the permission the supported way — an aggregated ClusterRole, never by editing Kyverno's own roles (Helm upgrades overwrite those):

```yaml
# 08-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:vars-lab-extra
  labels:
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["subjectaccessreviews"]
    verbs: ["create"]
```

```bash
kubectl apply -f 08-rbac.yaml
sleep 10
kubectl auth can-i get secrets \
  --as=system:serviceaccount:kyverno:kyverno-admission-controller -n vars-lab
```

```
yes
```

4. Retry, then approve the Secret and retry again:

```bash
kubectl -n vars-lab run puller --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}'
# -> denied by the policy, with the intended message

kubectl -n vars-lab label secret regcred kyverno.io/pull-secret=true

kubectl -n vars-lab run puller --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}'
# -> pod/puller created (server dry run)
```

5. Now reference a Secret that does not exist:

```bash
kubectl -n vars-lab run ghost --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"does-not-exist"}]}}'
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/ghost was blocked due to the following policies

approved-pull-secrets:
  pull-secret-must-be-approved: 'failed to load context: failed to fetch data for
    APICall: secrets "does-not-exist" not found'
```

**Questions — Exercise 5**

- **5.1** In step 2 the request was rejected, yet the policy's own `deny` conditions never ran. Which setting turned an internal error into a rejection, and what would `failurePolicy: Ignore` have done instead?
- **5.2** Why is the aggregation label approach preferred over `kubectl edit clusterrole kyverno:admission-controller`?
- **5.3** The manifest in step 3 adds the label for the background and reports controllers too. When is that necessary, and when is it needless privilege?
- **5.4** In step 5 the missing Secret produced the same class of failure as a 403. If you wanted "no such Secret ⇒ deny with a clear message" instead of "context load failed", how would you restructure the context entry?
- **5.5** Kyverno reading Secrets cluster-wide is a real escalation surface. Describe concretely what an attacker who can author a ClusterPolicy could do with the RBAC granted above, and one control that limits it.

---

## Exercise 6 — POST `apiCall`: delegating authorization to the API server

`apiCall` is not GET-only. With `method: POST` plus `data`, Kyverno builds a JSON body — the canonical use is `SubjectAccessReview`, which asks the API server's own authorizer chain "may this user do X?".

1. Gate privileged containers on a real RBAC permission:

```yaml
# 09-sar.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: privileged-requires-ns-admin
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: sar-gate
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      preconditions:
        all:
          - key: "{{ request.object.spec.containers[?securityContext.privileged == `true`] | length(@) }}"
            operator: GreaterThan
            value: 0
      context:
        - name: sar
          apiCall:
            urlPath: "/apis/authorization.k8s.io/v1/subjectaccessreviews"
            method: POST
            data:
              - key: kind
                value: SubjectAccessReview
              - key: apiVersion
                value: authorization.k8s.io/v1
              - key: spec
                value:
                  user: "{{ request.userInfo.username }}"
                  groups: "{{ request.userInfo.groups }}"
                  resourceAttributes:
                    verb: update
                    group: ""
                    resource: namespaces
                    name: "{{ request.namespace }}"
            jmesPath: "status"
      validate:
        message: >-
          Privileged containers require permission to update namespace
          {{ request.namespace }}. Decision for {{ request.userInfo.username }}:
          allowed={{ sar.allowed }} reason={{ sar.reason || 'n/a' }}
        deny:
          conditions:
            all:
              - key: "{{ sar.allowed }}"
                operator: Equals
                value: false
```

```bash
kubectl apply -f 09-sar.yaml
```

2. As cluster-admin (who *can* update namespaces), the privileged Pod is allowed:

```bash
kubectl -n vars-lab run priv --image=registry.k8s.io/pause:3.10 --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"priv","image":"registry.k8s.io/pause:3.10","securityContext":{"privileged":true}}]}}'
```

```
pod/priv created (server dry run)
```

3. As the `deployer` ServiceAccount (bound only to `edit`), it is refused:

```bash
kubectl -n vars-lab run priv --image=registry.k8s.io/pause:3.10 --dry-run=server \
  --as=system:serviceaccount:vars-lab:deployer \
  --overrides='{"spec":{"containers":[{"name":"priv","image":"registry.k8s.io/pause:3.10","securityContext":{"privileged":true}}]}}'
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/priv was blocked due to the following policies

privileged-requires-ns-admin:
  sar-gate: 'Privileged containers require permission to update namespace vars-lab.
    Decision for system:serviceaccount:vars-lab:deployer: allowed=false reason='
```

4. Reproduce the exact API interaction by hand so you can see the body Kyverno assembles:

```bash
cat <<'EOF' | kubectl create -f - -o jsonpath='{.status}{"\n"}'
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:vars-lab:deployer
  groups: ["system:serviceaccounts", "system:authenticated"]
  resourceAttributes:
    verb: update
    group: ""
    resource: namespaces
    name: vars-lab
EOF
```

```
{"allowed":false,"denied":false,"reason":""}
```

5. Contrast with the declarative alternative Kyverno offers in `match`:

```yaml
      match:
        any:
          - resources:
              kinds:
                - Pod
            clusterRoles:
              - cluster-admin
```

**Questions — Exercise 6**

- **6.1** Each `data[]` entry has `key` and `value`. What does the assembled request body look like, and why must `kind` and `apiVersion` be supplied explicitly?
- **6.2** Why is `preconditions` placed *before* the `context` in importance here, even though it appears after it in the YAML? What does it save on a cluster creating hundreds of Pods per minute?
- **6.3** `jmesPath: "status"` trims the response before it is stored. Name two independent reasons to trim an `apiCall` response rather than store the whole object.
- **6.4** Compare `match.clusterRoles` with the SubjectAccessReview approach. Give one scenario where `clusterRoles` returns the wrong answer and SAR returns the right one.
- **6.5** `status.allowed` can be `false` while `status.denied` is also `false`. What does that combination mean, and does the policy above treat it correctly?
- **6.6** This policy must set `background: false`. What does that cost you in terms of reporting on Pods that already exist?

---

## Exercise 7 — `globalReference`: caching an API call

A per-request `apiCall` runs on **every** matching admission request. For data that is large or slow-moving, `GlobalContextEntry` fetches once on an interval and shares the result.

1. Discover the served API version in your cluster — this resource has moved between alpha and beta:

```bash
kubectl api-resources | grep -i globalcontext
```

```
globalcontextentries   gctxentries   kyverno.io/v2alpha1   false   GlobalContextEntry
```

2. Create the entry (adjust `apiVersion` to whatever step 1 reported):

```yaml
# 10-gctx.yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: ingress-hosts
spec:
  apiCall:
    urlPath: "/apis/networking.k8s.io/v1/ingresses"
    refreshInterval: 30s
```

```bash
kubectl apply -f 10-gctx.yaml
kubectl get globalcontextentry ingress-hosts
```

```
NAME            READY   AGE
ingress-hosts   True    12s
```

3. Reference it from a policy that forbids duplicate Ingress hostnames:

```yaml
# 11-unique-host.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: unique-ingress-host
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: no-duplicate-hosts
      match:
        any:
          - resources:
              kinds:
                - Ingress
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: CREATE
      context:
        - name: existingHosts
          globalReference:
            name: ingress-hosts
            jmesPath: "items[].spec.rules[].host"
      validate:
        message: >-
          Host {{ request.object.spec.rules[0].host }} is already served by another
          Ingress. Known hosts: {{ existingHosts | join(',', @) }}
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.rules[].host }}"
                operator: AnyIn
                value: "{{ existingHosts || `[]` }}"
```

```bash
kubectl apply -f 11-unique-host.yaml

cat <<'EOF' | kubectl -n vars-lab apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: first
spec:
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
EOF
```

4. Wait for the refresh window, then attempt a collision:

```bash
sleep 35
cat <<'EOF' | kubectl -n vars-lab apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: second
spec:
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /checkout
            pathType: Prefix
            backend:
              service:
                name: checkout
                port:
                  number: 80
EOF
```

```
Error from server: error when creating "STDIN": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Ingress/vars-lab/second was blocked due to the following policies

unique-ingress-host:
  no-duplicate-hosts: 'Host shop.example.com is already served by another Ingress.
    Known hosts: shop.example.com'
```

5. Now create `second` **immediately** after `first`, without the sleep, in a fresh pair of names — and observe that the collision may slip through.

**Questions — Exercise 7**

- **7.1** Rewrite the trade-off in one sentence: what does `refreshInterval: 30s` buy, and what does it cost in correctness?
- **7.2** Step 5 demonstrates a race. Name it precisely, and explain why *no* admission-webhook-based uniqueness check is fully sound, even with `refreshInterval: 0s`.
- **7.3** `GlobalContextEntry` is cluster-scoped and holds whatever the URL returns. What must you check before pointing one at `/api/v1/secrets`?
- **7.4** Which controller populates the global cache, and which ServiceAccount's RBAC therefore governs the fetch?
- **7.5** The rule uses `{{ existingHosts || `[]` }}` as the `value`. What failure does that guard against on a cluster with zero Ingresses?

---

## Exercise 8 — Testing variables offline, and debugging them live

Live-testing every variable by creating Pods is slow and unrepeatable. The CLI resolves policies against files, with mocked values for anything it cannot compute.

1. Build a resource and a values file that injects the variables the CLI cannot know:

```yaml
# resource.yaml
apiVersion: v1
kind: Pod
metadata:
  name: priv
  namespace: vars-lab
spec:
  containers:
    - name: priv
      image: registry.k8s.io/pause:3.10
      securityContext:
        privileged: true
```

```yaml
# values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
spec:
  globalValues:
    request.operation: CREATE
    request.namespace: vars-lab
    request.userInfo.username: system:serviceaccount:vars-lab:deployer
  policies:
    - name: privileged-requires-ns-admin
      rules:
        - name: sar-gate
          values:
            sar.allowed: false
```

> If your CLI rejects this document, drop the `spec:` level — older CLI releases used a flat `policies:` / `globalValues:` layout at the root.

2. Run it:

```bash
kyverno apply 09-sar.yaml --resource resource.yaml --values-file values.yaml --detailed-results
```

```
Applying 1 policy rule(s) to 1 resource(s)...

policy privileged-requires-ns-admin -> resource vars-lab/Pod/priv failed:
1. sar-gate: Privileged containers require permission to update namespace vars-lab...

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

3. Flip the mocked decision to `true` and re-run — the result must become `pass: 1`. This is the whole point: the SubjectAccessReview never happened.

4. Run the same policy against the **real** cluster so contexts resolve for real:

```bash
kyverno apply 09-sar.yaml --resource resource.yaml --cluster
```

5. Convert it into a regression test for CI:

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: sar-gate-test
policies:
  - 09-sar.yaml
resources:
  - resource.yaml
variables: values.yaml
results:
  - policy: privileged-requires-ns-admin
    rule: sar-gate
    resource: priv
    kind: Pod
    result: fail
```

```bash
kyverno test .
```

6. Debug a live cluster when a variable misbehaves. These three commands cover almost every case:

```bash
# 1. the controller's own account of the failure
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 \
  | grep -iE 'failed to load context|variable substitution|jmespath'

# 2. what the policy engine recorded for existing resources
kubectl -n vars-lab get policyreport -o wide

# 3. events attached to the offending resource
kubectl -n vars-lab get events --field-selector reason=PolicyViolation
```

**Questions — Exercise 8**

- **8.1** Why can the CLI not resolve `sar.allowed` on its own in step 2, and which flag changes that?
- **8.2** `globalValues` versus a per-rule `values` block: when do you need the per-rule form?
- **8.3** `kyverno test` gives you a pass/fail contract in CI. What class of bug does it *not* catch, no matter how many cases you write?
- **8.4** A rule silently produces no violations in production but passes in CI. List the three most likely variable-related causes, in the order you would check them.
- **8.5** A policy rule with a `configMap` context reports `skip` in a PolicyReport rather than `fail`. What does `skip` mean here, and which block usually produces it?

---

## Cleanup

```bash
kubectl delete clusterpolicy var-anatomy registry-allowlist-cm namespace-cost-center \
  approved-pull-secrets privileged-requires-ns-admin unique-ingress-host --ignore-not-found
kubectl delete globalcontextentry ingress-hosts --ignore-not-found
kubectl delete clusterrole kyverno:vars-lab-extra --ignore-not-found
kubectl delete namespace vars-lab no-cc --ignore-not-found
kind delete cluster --name kca-vars
```

---

## Reference sources

- Kyverno — Variables: https://kyverno.io/docs/writing-policies/variables/
- Kyverno — External Data Sources (`configMap`, `apiCall`, `imageRegistry`, Global Context): https://kyverno.io/docs/writing-policies/external-data-sources/
- Kyverno — JMESPath and custom filters: https://kyverno.io/docs/writing-policies/jmespath/
- Kyverno — Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — Installation & RBAC customization (role aggregation labels): https://kyverno.io/docs/installation/customization/
- Kyverno CLI (`apply`, `test`, `jp`): https://kyverno.io/docs/kyverno-cli/
- JMESPath specification (operators, precedence, literals): https://jmespath.org/specification.html
- Kubernetes — Authorization / SubjectAccessReview: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — Dynamic Admission Control (`failurePolicy`, webhook ordering): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- CNCF — KCA curriculum: https://github.com/cncf/curriculum

---

<details>
<summary><strong>Answers</strong></summary>

### Lab 0

**0.1** An `apiCall` is executed by whichever controller is evaluating the rule, using that controller's ServiceAccount — `kyverno-admission-controller` during admission, `kyverno-background-controller` during background mutation/generation, `kyverno-reports-controller` when producing reports. They have different RBAC. A policy can therefore work perfectly at admission time and fail in background scans with a 403, which is why extra permissions are usually granted to all three via aggregation labels.

**0.2** The background controller (and the reports controller). `request.userInfo`, `request.operation` and the `serviceAccountName`/`serviceAccountNamespace` aliases exist only inside an AdmissionReview. A background scan re-evaluates a resource that already exists; there is no requester and no operation, so those variables have no value. Kyverno rejects such a policy at admission unless `spec.background: false`.

### Exercise 1

**1.1** `kubectl run` sets `metadata.name`. A Pod created by a ReplicaSet is submitted with `metadata.generateName` (e.g. `web-7c9f8d-`) and an empty `metadata.name` — the API server assigns the final name *after* admission. Read `request.object.metadata.generateName` as a fallback, or match on the controller resource (Deployment) instead of the Pod. Never build policy logic that assumes a Pod name exists at admission time.

**1.2** `serviceAccountName` and `serviceAccountNamespace` are convenience aliases Kyverno derives by parsing `request.userInfo.username` when it has the form `system:serviceaccount:<namespace>:<name>`. For a human user (`kubernetes-admin`) the parse does not apply and the variables are empty — which is why the policy wrote `{{ serviceAccountName || 'none' }}`. Using them unguarded is a common cause of substitution failures.

**1.3** Rules that reference AdmissionReview-only variables (`request.userInfo.*`, `request.operation`, `serviceAccountName`, `serviceAccountNamespace`) require `spec.background: false`. The reason is soundness: background scanning re-evaluates stored resources where no requester exists, so the rule could not be evaluated consistently. Kyverno enforces this at policy admission rather than producing silently wrong reports.

**1.4** `DELETE`. On a delete the API server sends the resource being removed in `oldObject`, and `object` is null. `UPDATE` populates both — `oldObject` is the previous state, which is what you compare against to detect *changes* (e.g. "this label may be set at creation but never modified").

**1.5** No. `kyverno jp query` is a pure JMESPath evaluator over a local file. It reproduces expression semantics — projections, filters, `||`, pipes, Kyverno's custom functions — but it knows nothing about `request.*`, `images`, or any `context` entry. Use it to debug the *expression*, and `kyverno apply`/a real cluster to debug the *data*.

### Exercise 2

**2.1** `registry=docker.io` while `raw-split=nginx:1.27.1`. Kyverno normalizes every image reference into `registry`/`path`/`name`/`tag`/`digest`/`reference` before the rule runs, filling in the default registry for bare references; the raw string split just returns the first path segment, which for a bare image is the repository, not a registry. The behaviour is governed by `defaultRegistry` and `enableDefaultRegistryMutation` in the `kyverno` ConfigMap in the `kyverno` namespace.

**2.2** Any bare Docker Hub image defeats it: `nginx:1.27.1` splits to `nginx`, which is not in the allowlist, so it is *caught* — but `ghcr.io.evil.example.com/nginx:1` splits to `ghcr.io.evil.example.com` (caught), while `busybox` splits to `busybox`. The reliable bypass is the other direction: an allowlist check written as "does the string *start with* `ghcr.io`" passes `ghcr.io.attacker.net/x`. Parsed `registry` is exact and unambiguous; string handling of image references is not. Digest-pinned and port-qualified references (`localhost:5000/x`) break naive splitting too.

**2.3** `spec.containers[]` alone ignores `initContainers` and `ephemeralContainers` — a privileged init container or a debug ephemeral container walks straight past the policy. Omitting the trailing `[]` leaves you with a list *of lists* (`[[c1,c2],[i1],null]`), so `element` would be an array and `element.name` would be null on every iteration.

**2.4** `images` is keyed by container name, and the key is only known per-iteration. `images.containers."{{ element.name }}".registry` is nested substitution: Kyverno resolves the inner `{{ element.name }}` first, producing a concrete key, then evaluates the outer expression. Without the nesting you would be looking up a literal key named `element.name`.

**2.5** Rule 3 uses only `request.object` and the derived `images`, both of which Kyverno can reconstruct from a stored resource during a background scan. No `userInfo` and no `operation` means background evaluation is legal — and desirable, because you then get PolicyReports for Pods that already exist.

### Exercise 3

**3.1** JMESPath identifiers may not contain `-`; unquoted, `team-limits` parses as a subtraction-style token and fails or returns null. Quoted identifiers (`."team-limits"`) are the specification's escape hatch for keys with hyphens, dots, slashes or leading digits — which covers most real Kubernetes annotation and ConfigMap keys.

**3.2** ConfigMap values are strings, so `allowlist.data."team-limits"` is one long string you can only pattern-match on. `parse_json` turns it into a structure you can index (`limits."eng-platform".maxReplicas`). If the string is not valid JSON, the expression errors, the context entry fails to load, and — with the default `failurePolicy: Fail` — the request is rejected. `default: {}` on the `variable` entry converts that hard failure into an empty object, after which `|| 'unset'` in the message keeps the output readable.

**3.3** Kyverno watches ConfigMaps through an informer and resolves the entry at request time from the cache, so edits take effect within seconds without touching the policy. The risk is the flip side of the same property: the ConfigMap is now part of your security control, and anyone with `edit` on that namespace can widen the allowlist without a policy change and without a policy audit trail. Keep policy data ConfigMaps in a namespace only platform owners can write to, and protect that ConfigMap with another Kyverno policy.

**3.4** Denied. The default `spec.failurePolicy: Fail` means an internal error — including a context that cannot be loaded — is surfaced as a rejection, so a deleted ConfigMap becomes a namespace-wide Pod outage. To fail open for one rule, set `spec.failurePolicy: Ignore` on that policy (it is policy-scoped, not rule-scoped, so isolate the rule into its own ClusterPolicy). The safer alternative is to keep `Fail` and make the *data* optional with a `variable` context entry carrying a `default`.

**3.5** Order is: `match`/`exclude` selection → `context` resolution → `preconditions` → rule body (`validate`/`mutate`/`generate`). Context resolves before preconditions, so a precondition cannot save you from the cost or the failure of a context entry. To skip expensive `apiCall`s for irrelevant requests you must narrow `match` (kinds, namespaces, selectors) — that is the only filter that runs earlier.

### Exercise 4

**4.1** Twice. A `context` entry is scoped to the rule that declares it; there is no cross-rule sharing inside a policy, and no de-duplication of identical URLs. Two rules that need the same lookup mean two GETs per admission request. If the cost matters, merge the rules or move the data into a `GlobalContextEntry`.

**4.2** The mutate rule runs first, but not because of file order — Kubernetes runs *all* mutating webhooks before *any* validating webhook, and Kyverno registers separately for each. Within a single Kyverno webhook invocation the applicable rules of that type are processed in order, but the mutate/validate ordering is a property of the admission chain. The practical consequence: validating rules always see the fully mutated object, including mutations from other policies and other admission controllers.

**4.3** It extracts one field from the Namespace object (keeping only what the rule needs in memory) and supplies a fallback so a missing label produces the sentinel `'unassigned'` instead of null. Without the fallback, `costCenter` would be null: the `deny` comparison against `unassigned` would never be true, the validate rule would silently pass, and the mutate rule would attempt to set a label to a null value — a substitution failure that, with `failurePolicy: Fail`, blocks the Pod for an unrelated-looking reason.

**4.4** `%3D` is the percent-encoding of `=`; the value goes into a URL query string, so the separator must be escaped or the selector is malformed. Fetching `/api/v1/pods` unfiltered makes the API server serialize every Pod in the cluster on **every matching admission request** — megabytes of JSON, per request, competing with the API server's own work. That pattern is the single most common way a Kyverno policy degrades a control plane; always use a `labelSelector`/`fieldSelector`, a namespaced path, or a `GlobalContextEntry`.

**4.5** The GET was performed by `system:serviceaccount:kyverno:kyverno-admission-controller`, not by the requesting user. This is a confused-deputy surface: the policy author chooses the URL, and Kyverno's identity — not the requester's — authorizes it. Anyone able to create or modify a ClusterPolicy can read anything Kyverno can read and exfiltrate it through a `deny.message`. Treat ClusterPolicy write access as equivalent to Kyverno's own RBAC.

### Exercise 5

**5.1** `spec.failurePolicy`, which defaults to `Fail`. A context load error is a webhook error, and `Fail` tells the API server to reject the request when the webhook cannot produce a verdict. With `failurePolicy: Ignore`, the API server would log the error and admit the Pod — the pull-secret check would silently not exist, which for a security control is usually worse than the outage.

**5.2** Kyverno's own ClusterRoles (`kyverno:admission-controller`, etc.) are managed objects: a `helm upgrade` or a re-apply of the install manifests reverts hand edits, and your policy starts failing at the least convenient moment. Kyverno declares those roles as aggregated, so any ClusterRole labelled `rbac.kyverno.io/aggregate-to-<controller>: "true"` has its rules merged in automatically and survives upgrades. It is also auditable: your extra grants live in one object you own.

**5.3** Necessary when the same rule is also evaluated outside admission — `background: true` rules (background controller) and rules that appear in PolicyReports (reports controller) perform their own context loads. Needless when the rule is `background: false` and admission-only, as in this exercise: granting Secret read to all three controllers widens the blast radius for no functional gain. Grant per controller, per need.

**5.4** Do not put the volatile lookup in the path of a mandatory entry. Fetch the *collection* with a selector and reduce it yourself, supplying a default:

```yaml
- name: secrets
  apiCall:
    urlPath: "/api/v1/namespaces/{{ request.namespace }}/secrets"
    jmesPath: "items[].metadata.name"
- name: approved
  variable:
    jmesPath: "contains(secrets, '{{ request.object.spec.imagePullSecrets[0].name }}')"
    default: false
```

Then `deny` when `approved == false` with a message naming the Secret. A `variable` entry with `default` is the general mechanism for turning "could not resolve" into "resolved to a known value".

**5.5** Anyone who can create a ClusterPolicy can write a rule matching any resource, add a context `apiCall` to `/api/v1/namespaces/kube-system/secrets`, and emit the contents in a `deny.message` or a `mutate` annotation — Kyverno reads with its own credentials and hands the result back to the requester. Controls: (a) treat `clusterpolicies` write as cluster-admin-equivalent in RBAC review; (b) grant the extra ClusterRole narrowly with `resourceNames` on specific Secrets rather than `list` on all of them; (c) require policies to arrive through GitOps with review, and block direct ClusterPolicy writes.

### Exercise 6

**6.1** Each `data[]` entry becomes a top-level field of the JSON body, so the three entries assemble to `{"kind":"SubjectAccessReview","apiVersion":"authorization.k8s.io/v1","spec":{...}}`. Kyverno POSTs an opaque body to the URL you named; it does not infer the resource type from the path, so the TypeMeta fields must be provided explicitly or the API server rejects the request as an unrecognized object.

**6.2** Because context loading happens for every request that survives `match`, and a POST SubjectAccessReview is a write-path round trip to the API server plus a full authorizer evaluation. `match` cannot express "has a privileged container", so on a busy cluster this policy pays that cost on every Pod. The mitigation is to keep `match` as narrow as the API allows (kinds, namespaces, `selector`) and accept that `preconditions` filters the *body*, not the *context*. If the cost is unacceptable, split into two policies where the cheap one annotates and the expensive one matches on the annotation.

**6.3** First, memory and payload: the whole response is held per in-flight request, and unbounded responses are a controller OOM risk (Kyverno also caps response sizes). Second, blast radius and clarity: storing only `status` means a `deny.message` cannot accidentally leak the full object, and the rule's data dependency is explicit and reviewable. A third reason in practice: trimming turns a schema change upstream into an obvious null instead of a subtly different structure deep in a comparison.

**6.4** `match.clusterRoles` relies on Kyverno resolving the requester's bindings itself, from RBAC objects, using the groups in the AdmissionReview. SubjectAccessReview asks the API server, which consults the **entire** configured authorizer chain in order — Node, RBAC, ABAC, and any webhook authorizer. On a managed cluster where permissions are granted by an external authorization webhook (a cloud IAM integration), `match.clusterRoles` sees no matching ClusterRole and treats a fully authorized platform admin as unprivileged; SAR returns `allowed: true`. SAR also correctly handles impersonation and aggregated roles without you re-implementing resolution.

**6.5** `allowed: false, denied: false` means *no authorizer explicitly allowed the action, and none explicitly denied it* — the default no-opinion outcome, which the API server treats as a denial. `denied: true` is stronger: an authorizer actively refused, and later authorizers cannot override it. The policy is correct for its purpose, because it gates on `allowed == false`, which covers both "not permitted" and "explicitly denied". Gating on `denied == true` instead would be the classic bug: it would let every un-permitted user through.

**6.6** No PolicyReport coverage for existing Pods and no background re-evaluation. If a privileged Pod already exists — created before the policy, or by a controller whose SA does have namespace-update rights — this rule will never flag it. Pair the SAR rule with a second, `background: true` rule that reports on privileged containers without the RBAC dimension, so you retain visibility over the installed base.

### Exercise 7

**7.1** It buys a bounded, predictable load on the API server (one LIST per interval regardless of admission volume, plus a fast in-memory read per request) at the cost of decisions made against data up to 30 seconds stale.

**7.2** A time-of-check-to-time-of-use (TOCTOU) race. Even at zero staleness it is unsound, because two colliding Ingresses can be admitted concurrently: each request is validated against a cluster state that does not yet contain the other, and neither webhook sees the other's not-yet-persisted object. Admission control is per-request and has no transactional view of the store. Genuine uniqueness must be enforced where serialization exists — a unique key in the resource name, a controller that reconciles and reports conflict, or the API server's own name uniqueness.

**7.3** Whether the background/reports controller is authorized to read them, and — more importantly — whether you accept that every Secret in the cluster is now resident in Kyverno's memory continuously, not just during the requests that need it, and reachable by any subsequently authored policy via `globalReference`. Restrict the URL to the smallest namespace and selector that satisfies the requirement, or do not use Secrets as policy data at all.

**7.4** Kyverno's controller responsible for global context maintenance performs the periodic fetch — not the admission webhook path — so the fetch is authorized by that controller's ServiceAccount (in the default Helm layout, the background controller's). This is exactly why the ClusterRole in Exercise 5 carries the `aggregate-to-background-controller` label as well: `kubectl get globalcontextentry` showing `READY: False` is almost always an RBAC failure there, and `kubectl describe` on the entry states it.

**7.5** If the LIST returns `items: []`, the projection `items[].spec.rules[].host` yields null rather than an empty list. Comparing against null in an `AnyIn` operator is a substitution/evaluation failure, so the very first Ingress in an empty cluster would be rejected with an opaque error. `|| \`[]\`` coerces it to an empty list, and `AnyIn []` is correctly false.

### Exercise 8

**8.1** `sar.allowed` comes from a live POST to a running API server; with no cluster connection the CLI cannot make it, so the value must be supplied by the values file. `--cluster` makes the CLI resolve contexts against your current kubeconfig context — real `apiCall`s, real ConfigMaps, real registry lookups — using *your* credentials rather than Kyverno's ServiceAccount, which is itself a difference worth remembering when results diverge from the cluster's.

**8.2** When the same variable name must hold different values in different rules or for different policies within one test run — for example two rules both reading a context entry called `data`, or testing the allow and deny branches of one variable in a single file. `globalValues` is a flat map applied everywhere; per-rule `values` are scoped and override it.

**8.3** Anything that depends on data the test file mocks. `kyverno test` proves your *expressions and rule logic* are right given assumed inputs; it cannot prove the assumed inputs match reality — that the ConfigMap key still exists, that the API path still returns that shape, that Kyverno's ServiceAccount is still authorized, or that the upstream CRD did not rename a field. Those failures appear only against a real cluster, which is what `kyverno apply --cluster` in a staging environment is for.

**8.4** (1) `match` is narrower than you think — wrong `kinds`, a namespace list that omits production, or a `selector` that no longer matches; the rule never runs, so there is nothing to report. (2) A context entry resolving to null in production — a ConfigMap key renamed, a label absent — making a `deny` condition unsatisfiable, particularly where a `default` silently substitutes a benign value. (3) `background: false` on a rule you expected to appear in reports, or `validationFailureAction: Audit` where you assumed `Enforce`. Check in that order: selection, then data, then mode — it is the cheapest-to-most-expensive diagnostic path.

**8.5** `skip` means the rule matched the resource but was not evaluated to a verdict — overwhelmingly because `preconditions` evaluated to false. It is a healthy, expected state, not an error; `error` is the status for a context that failed to load. Distinguishing them in reports matters: a wall of `skip` usually means a precondition is wrong, while a wall of `error` means RBAC or a missing data source.

</details>