# KCA 5.5 — Generation Rules: Guided Exercises

> **Scope.** These exercises cover Kyverno `generate` rules in `ClusterPolicy` / `Policy` (`kyverno.io/v1`): `data` vs `clone` vs `cloneList`, synchronization semantics, `generateExisting`, `foreach`, the `UpdateRequest` control loop, the RBAC model of the background controller, and the diagnostic path when nothing appears.
>
> **Version note.** Outputs below are *representative*. Column sets and default values shift slightly across Kyverno minor releases — record what **your** cluster prints, and confirm every field with `kubectl explain` before trusting it. Recent Kyverno releases also ship newer CEL-based policy types under the `policies.kyverno.io` API group; check `kubectl api-resources --api-group=policies.kyverno.io` on your cluster. The KCA curriculum and every exercise here target the stable `kyverno.io/v1` generate rule.
>
> **Working directory.** Create one: `mkdir -p ~/kca-5.5 && cd ~/kca-5.5`. Every file referenced is created inside it.

---

## Exercise 0 — Build the lab and identify the executing component

### Steps

1. Create a disposable cluster:

```bash
kind create cluster --name kca-generate --image kindest/node:v1.32.0
kubectl cluster-info --context kind-kca-generate
```

2. Install Kyverno with the full controller set (do **not** use `--set` profiles that disable the background controller):

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace --wait
```

3. Enumerate what was actually deployed:

```bash
kubectl -n kyverno get deploy
```

Representative output:

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller   1/1     1            1           94s
kyverno-background-controller  1/1     1            1           94s
kyverno-cleanup-controller     1/1     1            1           94s
kyverno-reports-controller     1/1     1            1           94s
```

4. Enumerate the service accounts and the CRD that carries generation work:

```bash
kubectl -n kyverno get sa
kubectl get crd | grep kyverno.io
kubectl api-resources --api-group=kyverno.io | grep -i updaterequest
```

Representative output for the last command:

```
updaterequests    ur    kyverno.io/v2    true    UpdateRequest
```

5. Record the version you are testing against — you will need it when a field does not exist:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Check your understanding

- **Q0.1** Four deployments are running. Which one *evaluates* the generate rule at admission time, and which one *creates the downstream resource*?
- **Q0.2** `UpdateRequest` is namespaced. In which namespace do generate `UpdateRequest` objects live, and why does that matter for a multi-tenant cluster where tenants have namespace-scoped RBAC?
- **Q0.3** Predict: if you scale `kyverno-background-controller` to 0 replicas and then create a matching trigger, what will you see, and what will you *not* see?

---

## Exercise 1 — A `data` generate rule: default-deny NetworkPolicy per namespace

The canonical production use case: every new namespace gets a default-deny `NetworkPolicy` so that workloads start closed and must be explicitly opened.

### Steps

1. Write `01-default-deny.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-deny
  annotations:
    policies.kyverno.io/title: Add Default Deny NetworkPolicy
    policies.kyverno.io/category: Multi-Tenancy
    policies.kyverno.io/subject: Namespace, NetworkPolicy
spec:
  background: true
  rules:
    - name: generate-default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          metadata:
            labels:
              kca.io/baseline: "true"
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

2. Apply it and confirm the policy is admitted and ready:

```bash
kubectl apply -f 01-default-deny.yaml
kubectl get clusterpolicy add-default-deny
```

Representative output:

```
NAME               ADMISSION   BACKGROUND   READY   AGE   MESSAGE
add-default-deny   true        true         True    6s    Ready
```

3. Create a trigger and watch the downstream appear:

```bash
kubectl create namespace team-alpha
sleep 3
kubectl -n team-alpha get networkpolicy
```

Representative output:

```
NAME           POD-SELECTOR   AGE
default-deny   <none>         2s
```

4. Inspect the control object Kyverno created to do the work:

```bash
kubectl -n kyverno get updaterequests
kubectl -n kyverno get ur -o yaml | grep -E 'policy:|requestType:|state:' 
```

Representative output:

```
NAME       POLICY             RULETYPE   RESOURCEKIND   RESOURCENAME   RESOURCENAMESPACE   STATUS      AGE
ur-9dxk7   add-default-deny   generate   Namespace      team-alpha                         Completed   8s
```

5. Inspect how Kyverno tracks the downstream:

```bash
kubectl -n team-alpha get netpol default-deny -o jsonpath='{.metadata.labels}' | tr ',' '\n'
kubectl -n team-alpha get netpol default-deny -o jsonpath='{.metadata.ownerReferences}'
```

You should see `app.kubernetes.io/managed-by: kyverno` plus a family of `generate.kyverno.io/*` labels naming the policy, the rule, and the trigger (kind, name, namespace, UID). The `ownerReferences` query should print nothing. Write down the exact label keys your version emits.

### Check your understanding

- **Q1.1** Two Kyverno components touched this request. Describe the exact sequence from `kubectl create namespace` to the `NetworkPolicy` existing, naming the intermediate object.
- **Q1.2** The `NetworkPolicy` has **no** `ownerReference` pointing at the `Namespace`, even though Kubernetes would permit a namespaced object to be owned by a cluster-scoped one. How does Kyverno track the trigger→downstream relationship instead, and name one capability that labels give you which `ownerReferences` could not?
- **Q1.3** What would happen if you deleted the `namespace:` field from the `generate` block while keeping `kind: NetworkPolicy`?
- **Q1.4** `spec.background` is `true` here. What would change functionally if you set it to `false`?

---

## Exercise 2 — `synchronize`: the difference between "created once" and "continuously reconciled"

Here the trigger is *not* the namespace, so you can delete the trigger without destroying the downstream's namespace — which is what makes the deletion semantics observable.

### Steps

1. Write `02-tenant-quota.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-quota
spec:
  background: true
  rules:
    - name: generate-quota
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              selector:
                matchLabels:
                  kca.io/tenant: "true"
      generate:
        apiVersion: v1
        kind: ResourceQuota
        name: tenant-quota
        namespace: "{{request.object.metadata.namespace}}"
        synchronize: true
        data:
          spec:
            hard:
              requests.cpu: "{{request.object.data.cpu}}"
              requests.memory: "{{request.object.data.memory}}"
              pods: "{{request.object.data.pods}}"
```

2. Apply the policy and create the trigger:

```bash
kubectl apply -f 02-tenant-quota.yaml

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: tenant-config
  namespace: team-alpha
  labels:
    kca.io/tenant: "true"
data:
  cpu: "4"
  memory: "8Gi"
  pods: "20"
EOF

sleep 3
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.spec.hard}{"\n"}'
```

Expected:

```
{"pods":"20","requests.cpu":"4","requests.memory":"8Gi"}
```

3. **Drift test A — mutate the downstream directly:**

```bash
kubectl -n team-alpha patch resourcequota tenant-quota --type merge \
  -p '{"spec":{"hard":{"pods":"999"}}}'
sleep 5
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.spec.hard.pods}{"\n"}'
```

4. **Drift test B — delete the downstream:**

```bash
kubectl -n team-alpha delete resourcequota tenant-quota
sleep 5
kubectl -n team-alpha get resourcequota
```

5. **Source-of-truth test — change the trigger:**

```bash
kubectl -n team-alpha patch configmap tenant-config --type merge \
  -p '{"data":{"cpu":"8"}}'
sleep 5
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.spec.hard}{"\n"}'
```

6. **Trigger deletion under `synchronize: true`:**

```bash
kubectl -n team-alpha delete configmap tenant-config
sleep 5
kubectl -n team-alpha get resourcequota
```

7. Now flip the semantics. Change `synchronize: true` to `synchronize: false` in `02-tenant-quota.yaml`, re-apply, recreate the trigger ConfigMap from step 2, then repeat steps 3, 4 and 6. Record each result in a table.

```bash
sed -i 's/synchronize: true/synchronize: false/' 02-tenant-quota.yaml
kubectl apply -f 02-tenant-quota.yaml
```

### Check your understanding

- **Q2.1** Fill in this table from your own observations:

  | Action | `synchronize: true` | `synchronize: false` |
  |---|---|---|
  | Patch the downstream | | |
  | Delete the downstream | | |
  | Change the trigger's data | | |
  | Delete the trigger | | |

- **Q2.2** `synchronize: true` costs something. Name two concrete operational costs on a cluster with 2,000 namespaces.
- **Q2.3** A platform team wants a *seed* object: created by policy, then owned and freely edited by the tenant. Which setting do they need, and what capability do they permanently give up?
- **Q2.4** Which setting would you use if you want continuous sync while the policy exists, but want the downstream objects to **survive** deletion of the policy itself?

---

## Exercise 3 — `clone`: propagating a registry credential from a single source of truth

### Steps

1. Create the source namespace and the source Secret:

```bash
kubectl create namespace platform-secrets

kubectl -n platform-secrets create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=robot \
  --docker-password=s3cr3t-v1 \
  --docker-email=robot@example.com
```

2. Write `03-clone-regcred.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sync-image-pull-secret
spec:
  background: true
  rules:
    - name: clone-regcred
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
                - platform-secrets
      generate:
        apiVersion: v1
        kind: Secret
        name: regcred
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        clone:
          namespace: platform-secrets
          name: regcred
```

3. Apply and trigger:

```bash
kubectl apply -f 03-clone-regcred.yaml
kubectl create namespace team-beta
sleep 3
kubectl -n team-beta get secret regcred
kubectl -n team-beta get secret regcred \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

You should see the credential for `s3cr3t-v1`.

4. **Rotate the source** and observe propagation:

```bash
kubectl -n platform-secrets create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=robot \
  --docker-password=r0tat3d-v2 \
  --docker-email=robot@example.com \
  --dry-run=client -o yaml | kubectl apply -f -

sleep 5
kubectl -n team-beta get secret regcred \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

5. Verify who is allowed to read the source:

```bash
kubectl auth can-i get secrets \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  -n platform-secrets
```

### Check your understanding

- **Q3.1** Which service account had to read `platform-secrets/regcred`, and what is the blast radius of the permission that makes cloning Secrets work at all?
- **Q3.2** Why is `platform-secrets` in the `exclude` block? Describe precisely what the rule would attempt without it.
- **Q3.3** `data` vs `clone`: state the trade-off in one sentence each, with an explicit reason why `data` is the wrong tool for a registry credential.
- **Q3.4** With `synchronize: true`, a tenant with `edit` in `team-beta` patches `regcred`. Does that grant them a persistent way to point image pulls at a registry they control? Justify.

---

## Exercise 4 — `cloneList`: propagating a *set* selected by labels

### Steps

1. Populate the source namespace with several objects, only some of which are marked for propagation:

```bash
kubectl -n platform-secrets create configmap ca-bundle \
  --from-literal=ca.crt=PLACEHOLDER
kubectl -n platform-secrets label configmap ca-bundle kca.io/propagate=true

kubectl -n platform-secrets create configmap internal-notes \
  --from-literal=note=do-not-propagate

kubectl -n platform-secrets label secret regcred kca.io/propagate=true
```

2. Write `04-clonelist.yaml`. Note the shape: no `apiVersion`/`kind`/`name` at the `generate` level.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sync-platform-bundle
spec:
  background: true
  rules:
    - name: clone-bundle
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
                - platform-secrets
      generate:
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        cloneList:
          namespace: platform-secrets
          kinds:
            - v1/Secret
            - v1/ConfigMap
          selector:
            matchLabels:
              kca.io/propagate: "true"
```

3. Apply and trigger with a fresh namespace:

```bash
kubectl apply -f 04-clonelist.yaml
kubectl create namespace team-gamma
sleep 5
kubectl -n team-gamma get configmap,secret
```

`ca-bundle` and `regcred` should be present; `internal-notes` should not (`kube-root-ca.crt` is created by Kubernetes itself, not by Kyverno — confirm by checking its labels).

4. **Extend the set after the fact:**

```bash
kubectl -n platform-secrets create configmap extra-trust --from-literal=x=y
kubectl -n platform-secrets label configmap extra-trust kca.io/propagate=true
sleep 5
kubectl -n team-gamma get configmap
```

5. **Retract from the set:**

```bash
kubectl -n platform-secrets label configmap extra-trust kca.io/propagate-
sleep 5
kubectl -n team-gamma get configmap
```

Record the result of steps 4 and 5 exactly.

### Check your understanding

- **Q4.1** Why does `cloneList` have no `name` field in the `generate` block, and what determines the downstream names?
- **Q4.2** Note the `kinds` syntax: `v1/Secret`, not `Secret`. Write the entry you would use to clone a `cert-manager.io/v1` `Certificate`.
- **Q4.3** From steps 4 and 5: with `synchronize: true`, is the label selector evaluated once at generation time or continuously? What does that imply about the label as a security boundary?
- **Q4.4** You need the same three ConfigMaps in every namespace, but with a per-namespace value substituted into one of them. Is `cloneList` the right tool? Why or why not?

---

## Exercise 5 — RBAC: the background controller can only create what it is allowed to create

This is the single most common generate-rule failure in production. You will reproduce it deliberately against a custom kind so the result does not depend on Kyverno's default role set.

### Steps

1. Install a small CRD:

```yaml
# 05-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: tenantprofiles.kca.io
spec:
  group: kca.io
  scope: Namespaced
  names:
    kind: TenantProfile
    listKind: TenantProfileList
    plural: tenantprofiles
    singular: tenantprofile
    shortNames:
      - tp
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                tier:
                  type: string
                owner:
                  type: string
                teams:
                  type: array
                  items:
                    type: object
                    properties:
                      name:
                        type: string
                      owner:
                        type: string
```

```bash
kubectl apply -f 05-crd.yaml
kubectl get crd tenantprofiles.kca.io
```

2. Prove Kyverno currently cannot touch it:

```bash
kubectl auth can-i create tenantprofiles.kca.io \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  -n team-alpha
```

Expected: `no`.

3. Write `05-seed-profile.yaml` — note `synchronize: false`, because this object is a *seed* the platform team then owns:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: seed-tenant-profile
spec:
  background: true
  rules:
    - name: create-profile
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
                - platform-secrets
      generate:
        apiVersion: kca.io/v1alpha1
        kind: TenantProfile
        name: profile
        namespace: "{{request.object.metadata.name}}"
        synchronize: false
        data:
          spec:
            tier: bronze
            owner: platform
            teams:
              - name: core
                owner: platform@example.com
```

4. Apply it and observe the failure. **Two outcomes are possible depending on your Kyverno version** — record which one you get:

```bash
kubectl apply -f 05-seed-profile.yaml
```

Outcome A — rejected at admission, with a message naming the missing permission. Outcome B — accepted, and the failure surfaces later:

```bash
kubectl create namespace team-delta
sleep 5
kubectl -n team-delta get tenantprofile
kubectl -n kyverno get ur
kubectl -n kyverno get ur -o yaml | grep -iE 'state|message' | head -20
kubectl -n kyverno logs deploy/kyverno-background-controller --tail=40 | grep -i forbidden
```

5. Fix it the upgrade-safe way, with an **aggregated** ClusterRole:

```yaml
# 05-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:generate-tenantprofiles
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups:
      - kca.io
    resources:
      - tenantprofiles
    verbs:
      - create
      - get
      - list
      - watch
      - update
      - patch
      - delete
```

```bash
kubectl apply -f 05-rbac.yaml
sleep 5
kubectl get clusterrole kyverno:background-controller -o yaml | grep -A4 tenantprofiles
kubectl auth can-i create tenantprofiles.kca.io \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  -n team-alpha
```

Expected: `yes`.

6. Re-drive the rule. If the policy was rejected in step 4, apply it now. If an `UpdateRequest` failed, delete it or re-create the trigger:

```bash
kubectl apply -f 05-seed-profile.yaml
kubectl delete namespace team-delta --wait
kubectl create namespace team-delta
sleep 5
kubectl -n team-delta get tenantprofile profile -o yaml | grep -A8 'spec:'
```

### Check your understanding

- **Q5.1** Why does the **admission** controller's service account not need `create` on `tenantprofiles`, even though the policy is evaluated during admission?
- **Q5.2** Why attach a label to a *new* ClusterRole rather than `kubectl edit clusterrole kyverno:background-controller`?
- **Q5.3** The role grants seven verbs. `create` is obvious. Justify each of `get`, `list`, `watch`, `update`, `patch`, `delete` in terms of a specific generate-rule behaviour.
- **Q5.4** Kyverno has no permission to create the target kind. Which failure mode is safer for a platform team — rejection at policy admission, or a failed `UpdateRequest` — and why?
- **Q5.5** For a `clone`-based rule, which *additional* permission is required beyond those on the downstream kind?

---

## Exercise 6 — `generateExisting`: backfilling resources that predate the policy

### Steps

1. Confirm the field and its default in your version:

```bash
kubectl explain clusterpolicy.spec.generateExisting
kubectl explain clusterpolicy.spec.rules.generate.generateExisting
```

2. Confirm that the namespaces created *before* Exercise 1 have no `default-deny`:

```bash
kubectl create namespace legacy-one
kubectl create namespace legacy-two
kubectl -n legacy-one get netpol
```

(These will already have been generated by the still-active policy from Exercise 1 — so first remove that policy to create a genuine "pre-existing" population.)

```bash
kubectl delete clusterpolicy add-default-deny
kubectl create namespace legacy-three
kubectl create namespace legacy-four
kubectl -n legacy-three get netpol
```

Expected: `No resources found in legacy-three namespace.`

3. Re-apply the policy **without** backfill and confirm nothing happens to the existing namespaces:

```bash
kubectl apply -f 01-default-deny.yaml
sleep 5
kubectl -n legacy-three get netpol
kubectl -n kyverno get ur --no-headers | wc -l
```

4. Now enable backfill:

```bash
kubectl patch clusterpolicy add-default-deny --type merge \
  -p '{"spec":{"generateExisting":true}}'
sleep 10
kubectl -n legacy-three get netpol
kubectl -n legacy-four get netpol
kubectl -n kyverno get ur --no-headers | wc -l
```

5. Watch the control-plane cost directly:

```bash
kubectl -n kyverno get ur -w
# Ctrl-C after ~15s
```

### Check your understanding

- **Q6.1** When you flipped `generateExisting` to `true`, how many `UpdateRequest` objects were produced relative to the number of matching triggers?
- **Q6.2** You are about to enable `generateExisting: true` on a policy matching `Namespace` in a cluster with 4,000 namespaces. Name two things that could go wrong and one rollout technique that reduces the risk.
- **Q6.3** `generateExisting` can be set at `spec` level and at rule level. Which wins, and why does a rule-level field exist at all?
- **Q6.4** A colleague argues that `generateExisting: true` makes `synchronize: true` unnecessary. Rebut this in one sentence.

---

## Exercise 7 — `foreach`, preconditions, and chained generation

The `TenantProfile` from Exercise 5 was itself *generated*. Now use it as a *trigger*.

### Steps

1. Confirm `foreach` exists in your version:

```bash
kubectl explain clusterpolicy.spec.rules.generate.foreach
```

If this errors, your Kyverno predates generate-`foreach` and you should skip to the questions.

2. Write `07-team-configmaps.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-team-configmaps
spec:
  background: true
  rules:
    - name: per-team-configmap
      match:
        any:
          - resources:
              kinds:
                - kca.io/v1alpha1/TenantProfile
      preconditions:
        all:
          - key: "{{ request.object.spec.tier || '' }}"
            operator: AnyIn
            value:
              - gold
              - platinum
      generate:
        synchronize: true
        foreach:
          - list: "request.object.spec.teams"
            apiVersion: v1
            kind: ConfigMap
            name: "team-{{ element.name }}"
            namespace: "{{ request.object.metadata.namespace }}"
            data:
              metadata:
                labels:
                  kca.io/team: "{{ element.name }}"
              data:
                owner: "{{ element.owner }}"
                tier: "{{ request.object.spec.tier }}"
                index: "{{ elementIndex }}"
```

3. Apply and confirm the precondition blocks the `bronze` profile:

```bash
kubectl apply -f 07-team-configmaps.yaml
sleep 5
kubectl -n team-delta get configmap
```

Expected: only `kube-root-ca.crt`.

4. Promote the tenant. This works only because Exercise 5's rule used `synchronize: false`:

```bash
kubectl -n team-delta patch tenantprofile profile --type merge \
  -p '{"spec":{"tier":"gold","teams":[{"name":"core","owner":"core@example.com"},{"name":"data","owner":"data@example.com"}]}}'
sleep 5
kubectl -n team-delta get configmap
kubectl -n team-delta get configmap team-data -o jsonpath='{.data}{"\n"}'
```

5. Remove an element and observe the reconciled set:

```bash
kubectl -n team-delta patch tenantprofile profile --type merge \
  -p '{"spec":{"teams":[{"name":"core","owner":"core@example.com"}]}}'
sleep 5
kubectl -n team-delta get configmap
```

6. Test the interaction between background mode and admission-only variables. Add this to a scratch copy of the policy and try to apply it:

```yaml
            data:
              data:
                createdBy: "{{ request.userInfo.username }}"
```

### Check your understanding

- **Q7.1** In a generate `foreach`, what is `element` bound to, what is `elementIndex`, and in which fields can you reference them?
- **Q7.2** From step 5: with `synchronize: true`, what happened to `team-data` when its element left the list? State the general rule this demonstrates.
- **Q7.3** The `TenantProfile` that triggered this rule was created by Kyverno itself in Exercise 5. Explain why a Kyverno-generated resource is able to trigger another Kyverno rule, and describe the failure mode this makes possible.
- **Q7.4** From step 6: why does `{{ request.userInfo.username }}` fail in a generate rule, and what would setting `background: false` actually buy you?
- **Q7.5** The precondition uses `{{ request.object.spec.tier || '' }}` rather than `{{ request.object.spec.tier }}`. Why does the `|| ''` matter given the CRD schema?

---

## Exercise 8 — Lifecycle: what happens when the *policy* goes away

### Steps

1. Establish a clean, synchronized downstream:

```bash
sed -i 's/synchronize: false/synchronize: true/' 02-tenant-quota.yaml
kubectl apply -f 02-tenant-quota.yaml

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: tenant-config
  namespace: team-alpha
  labels:
    kca.io/tenant: "true"
data:
  cpu: "4"
  memory: "8Gi"
  pods: "20"
EOF

sleep 5
kubectl -n team-alpha get resourcequota
```

2. Delete the policy and observe:

```bash
kubectl delete clusterpolicy tenant-quota
sleep 5
kubectl -n team-alpha get resourcequota
```

3. Confirm the field name in your version, then re-apply with orphaning enabled:

```bash
kubectl explain clusterpolicy.spec.rules.generate.orphanDownstreamOnPolicyDelete
```

Add to the `generate` block of `02-tenant-quota.yaml`:

```yaml
        orphanDownstreamOnPolicyDelete: true
```

```bash
kubectl apply -f 02-tenant-quota.yaml
sleep 5
kubectl -n team-alpha get resourcequota
kubectl delete clusterpolicy tenant-quota
sleep 5
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.metadata.labels}' | tr ',' '\n'
```

4. Delete only the *rule* (not the whole policy) from a multi-rule policy and predict the outcome before running it.

### Check your understanding

- **Q8.1** Enumerate the four independent lifecycle events that can remove a downstream resource, and state which setting governs each.
- **Q8.2** After orphaning, the downstream still carries `generate.kyverno.io/*` labels. Why is that a hazard, and what would you do about it in a real cluster?
- **Q8.3** A GitOps controller manages your `ClusterPolicy` objects. Someone renames a policy in Git. Trace what happens to every downstream resource, and state which setting prevents an outage.
- **Q8.4** Is `orphanDownstreamOnPolicyDelete: true` meaningful when `synchronize: false`? Explain.

---

## Exercise 9 — Diagnostic drill: nothing was generated

Work this drill *without* looking at the answer key first. For each break, write down the single command that identified the cause.

### Steps

1. **Break 1 — the worker is gone.**

```bash
kubectl apply -f 01-default-deny.yaml
kubectl -n kyverno scale deploy kyverno-background-controller --replicas=0
kubectl -n kyverno rollout status deploy kyverno-background-controller --timeout=60s || true

kubectl create namespace break-one
sleep 10
kubectl -n break-one get netpol
kubectl -n kyverno get ur
```

Then repair and confirm self-healing:

```bash
kubectl -n kyverno scale deploy kyverno-background-controller --replicas=1
kubectl -n kyverno rollout status deploy kyverno-background-controller
sleep 10
kubectl -n break-one get netpol
kubectl -n kyverno get ur
```

2. **Break 2 — the clone source does not exist.**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-clone
spec:
  background: true
  rules:
    - name: clone-missing
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: v1
        kind: Secret
        name: does-not-exist
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        clone:
          namespace: platform-secrets
          name: no-such-secret
EOF

kubectl create namespace break-two
sleep 10
kubectl -n kyverno get ur
kubectl -n kyverno get ur -o custom-columns='NAME:.metadata.name,POLICY:.spec.policy,STATE:.status.state,MSG:.status.message'
kubectl -n kyverno logs deploy/kyverno-background-controller --tail=60 | grep -iE 'no-such-secret|not found'
```

3. **Break 3 — the trigger never matched.** Create a namespace whose name is excluded and confirm the *absence* of any `UpdateRequest`:

```bash
kubectl create namespace kube-decoy 2>/dev/null || true
kubectl -n kyverno get ur | grep kube-decoy || echo "no UR created — the rule never matched"
```

4. **Confirm what reports do and do not tell you:**

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl get events -A --field-selector involvedObject.kind=ClusterPolicy --sort-by=.lastTimestamp | tail -20
```

5. Clean up the broken policy:

```bash
kubectl delete clusterpolicy broken-clone
kubectl delete namespace break-one break-two --wait=false
```

### Check your understanding

- **Q9.1** Distinguish the diagnostic meaning of an `UpdateRequest` in `Pending` versus `Failed` versus *no `UpdateRequest` at all*. Map each to a distinct class of root cause.
- **Q9.2** In Break 1, the `NetworkPolicy` appeared after you scaled the deployment back up, with no re-trigger. What guarantees that, and what would have been lost if the `UpdateRequest` object had been deleted while the controller was down?
- **Q9.3** Step 4 produced no `PolicyReport` entries for any of these rules. Why, and what is the correct object to watch instead?
- **Q9.4** Write the ordered five-step checklist you would hand a junior SRE for "the generated resource is missing", cheapest check first.
- **Q9.5** The downstream resource appears and then vanishes a few seconds later, repeatedly. Give two plausible causes and the command that distinguishes them.

---

## Exercise 10 — Testing generate rules offline with the Kyverno CLI

Generate rules are the hardest rule type to shift left, because the downstream lands in a live cluster. The CLI closes most of that gap.

### Steps

1. Install and verify:

```bash
kyverno version
```

2. Create a trigger fixture `resource-ns.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-epsilon
```

3. Run the `data`-based policy offline and print the generated resource:

```bash
kyverno apply 01-default-deny.yaml --resource resource-ns.yaml
```

4. Try the same with the `clone`-based policy and observe why it behaves differently:

```bash
kyverno apply 03-clone-regcred.yaml --resource resource-ns.yaml
kyverno apply 03-clone-regcred.yaml --resource resource-ns.yaml --cluster
```

5. Write a declarative test. Confirm the current schema first with `kyverno test --help` and the CLI documentation, then create `kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: default-deny-generation
policies:
  - 01-default-deny.yaml
resources:
  - resource-ns.yaml
results:
  - policy: add-default-deny
    rule: generate-default-deny
    kind: Namespace
    resources:
      - team-epsilon
    result: pass
    generatedResource: expected-netpol.yaml
```

`expected-netpol.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: team-epsilon
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```bash
kyverno test .
```

### Check your understanding

- **Q10.1** Why does `kyverno apply` need `--cluster` for the `clone` policy but not for the `data` policy?
- **Q10.2** Name two classes of generate-rule defect that `kyverno test` **cannot** catch, and say which exercise above exposed each.
- **Q10.3** Where in a CI pipeline does `kyverno test` belong relative to the RBAC check from Exercise 5, and why can't one substitute for the other?

---

## Cleanup

```bash
kubectl delete clusterpolicy --all
kubectl delete crd tenantprofiles.kca.io
kubectl delete namespace team-alpha team-beta team-gamma team-delta \
  platform-secrets legacy-one legacy-two legacy-three legacy-four --wait=false
helm uninstall kyverno -n kyverno
kind delete cluster --name kca-generate
```

---

<details>
<summary><strong>Answer key</strong></summary>

### Exercise 0

**A0.1** The **admission controller** intercepts the trigger's admission request, evaluates the `match`/`exclude`/`preconditions` of the generate rule, and — if it matches — creates an `UpdateRequest`. It does **not** create the downstream. The **background controller** watches `UpdateRequest` objects, resolves variables, and issues the actual `create`/`update` call for the downstream resource against the API server. This split is why generate rules fail with `Forbidden` even when the admission controller has ample permissions: the two components use different service accounts.

**A0.2** `UpdateRequest` objects live in the Kyverno installation namespace (`kyverno` in this lab). Consequences: a tenant with RBAC only inside their own namespace **cannot** see why a generation failed — every diagnostic in Exercise 9 requires read access to the `kyverno` namespace. Platform teams therefore need either a cluster-scoped read role for tenants, or a support workflow. It also means UR volume is a single-namespace scaling concern, not spread across the cluster.

**A0.3** You will see the `UpdateRequest` created (the admission controller is still running and still evaluates the rule) and it will sit in `Pending`. You will **not** see the downstream resource. This is the single most diagnostic signal in generate troubleshooting: UR present + downstream absent isolates the fault to the background controller or its RBAC, and rules out matching/precondition problems entirely.

---

### Exercise 1

**A1.1** `kubectl create namespace team-alpha` → API server admission → Kyverno's `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` routes the `CREATE Namespace` request to the **admission controller** → the rule's `match` (kind `Namespace`) and `exclude` (name not in the excluded set) both pass → the admission controller creates an **`UpdateRequest`** in the `kyverno` namespace recording policy, rule, and trigger identity → the request is admitted and the namespace is created → the **background controller** observes the new `UpdateRequest`, substitutes `{{request.object.metadata.name}}` → `team-alpha`, and `create`s the `NetworkPolicy` → the UR transitions to `Completed`.

Critically, the downstream is created **after** the trigger is admitted, asynchronously. There is a real (usually sub-second) window in which the namespace exists without its default-deny policy — which is why generate rules are a *baseline* mechanism, not an enforcement mechanism. Enforcement is a `validate` rule's job.

**A1.2** Kyverno records the relationship in **labels** on the downstream: `app.kubernetes.io/managed-by: kyverno` plus the `generate.kyverno.io/*` family identifying the policy name, policy namespace, rule name, and the trigger's kind, name, namespace and UID. The background controller uses a label selector to find every resource it owns.

What labels give you that `ownerReferences` cannot:
- **Cross-namespace and cross-scope relationships.** Kubernetes forbids a namespaced dependent from naming an owner in a *different* namespace; garbage collection treats such a reference as invalid. A trigger `ConfigMap` in `team-alpha` generating into `team-beta` is impossible to express with ownership.
- **Policy-driven, reversible deletion.** With `ownerReferences`, deletion is unconditional and handled by the Kubernetes garbage collector. Kyverno needs deletion to be *conditional* on `synchronize` and `orphanDownstreamOnPolicyDelete` — semantics the GC has no concept of.
- **Multi-dimensional lookup.** Kyverno queries "everything from policy X", "everything from rule Y", and "everything from trigger Z" independently. An `ownerReference` supports only one of those.

**A1.3** `NetworkPolicy` is a namespaced kind. Without a `namespace`, Kyverno has no target namespace to create into. Modern Kyverno versions reject the policy at admission with a validation error stating that a namespace is required for a namespaced generate target. Older versions may accept it and produce a failing `UpdateRequest`. The inverse also holds: supplying `namespace` for a **cluster-scoped** target kind is likewise invalid.

**A1.4** `spec.background: false` restricts the rule to admission-time events only. Two things change: (a) the rule can never be applied to pre-existing resources — `generateExisting` becomes meaningless; (b) the periodic background reconciliation that repairs drift stops, so `synchronize: true` loses most of its power. It is set to `false` only when a rule genuinely requires admission-only context such as `request.userInfo` (see A7.4), and for generate rules that combination is rarely useful.

---

### Exercise 2

**A2.1**

| Action | `synchronize: true` | `synchronize: false` |
|---|---|---|
| Patch the downstream | Reverted; `pods` returns to `20` | Patch persists; `999` stays |
| Delete the downstream | Recreated | Stays deleted permanently |
| Change the trigger's data | Downstream updated to `requests.cpu: 8` | Downstream unchanged; still `4` |
| Delete the trigger | Downstream deleted | Downstream survives, now unmanaged |

The unifying model: `synchronize: true` makes the policy+trigger the **continuously enforced desired state** of the downstream, and the downstream a pure projection with no independent identity. `synchronize: false` makes the policy a **one-shot creator** — a bootstrap step, not a controller.

**A2.2**
1. **Watch and reconcile load.** The background controller maintains informers on every managed downstream kind and re-reconciles on every change. 2,000 namespaces × several managed kinds is a substantial cache footprint in the controller and sustained watch traffic against the API server.
2. **Retained `UpdateRequest` state.** Each synchronized relationship needs durable tracking, which is etcd objects and list/watch cost in the `kyverno` namespace.
3. (Also creditable) **Fight loops with other controllers.** If a mutating webhook, an operator, or a GitOps agent also writes the downstream, the two controllers overwrite each other indefinitely, generating continuous API writes and audit noise.

**A2.3** `synchronize: false`. What they permanently give up: **drift correction and lifecycle coupling**. If a tenant deletes the seed object it is never restored; if the policy's `data` block is later corrected, existing downstreams keep the old content forever. In practice this means `synchronize: false` policies need a separate audit mechanism — typically a companion `validate` rule that reports namespaces missing the object.

**A2.4** `generate.orphanDownstreamOnPolicyDelete: true`. It decouples *policy* deletion from *downstream* deletion while leaving `synchronize: true` sync behaviour intact for as long as the policy exists. See Exercise 8.

---

### Exercise 3

**A3.1** The **background controller's** service account (`kyverno-background-controller`) reads the source. Blast radius: for cloning Secrets to work at all, that SA needs `get` on `Secret` — and Kyverno's default installation grants that broadly enough to cover arbitrary source namespaces. That means **the Kyverno background controller is a cluster-wide Secret reader**. Anyone who can author a `ClusterPolicy` with a `clone` block can therefore exfiltrate any Secret in the cluster into a namespace they control. Consequently: `ClusterPolicy` create/update is a **cluster-admin-equivalent privilege** and must be restricted accordingly, and the Kyverno namespace deserves the same protection as `kube-system`.

**A3.2** Without the exclusion, `platform-secrets` itself matches `kinds: [Namespace]` whenever it is created or re-reconciled, and the rule would resolve to: create `Secret/regcred` in namespace `platform-secrets`, cloned from `platform-secrets/regcred` — the source and the downstream are the same object. Kyverno rejects a generate rule whose downstream is identical to its source; and even if it did not, you would have created a self-managing object whose sync loop has no meaning. The general rule: **always exclude the source namespace from a `clone` rule's match.**

**A3.3**
- **`data`**: the policy manifest *is* the desired content. Best when the content is non-sensitive, uniform, and belongs in Git alongside the policy — resource quotas, network policies, limit ranges. Fully declarative and reviewable in a PR.
- **`clone`**: a live cluster object is the source of truth. Best when the content is sensitive, externally rotated, or too large/binary to inline — registry credentials, CA bundles, licence keys.

`data` is wrong for a registry credential because the credential would be written in plaintext into the `ClusterPolicy` manifest, and that manifest lives in Git, in `kubectl get cpol -o yaml` output readable by anyone with policy read access, and in every backup of etcd. `clone` keeps the secret material in exactly one object with normal Secret RBAC around it.

**A3.4** No — not persistently. With `synchronize: true` the background controller reverts the downstream to match the source, so the tenant's patch is undone on the next reconcile. But "not persistently" is not "not at all": there is a window between the tenant's write and the revert during which a pod could pull from the attacker's registry. Treat generate-sync as **drift correction, not admission control**. If tenants must never modify these Secrets, pair the generate rule with a `validate` rule (or an RBAC restriction) that blocks writes to `regcred` outright.

---

### Exercise 4

**A4.1** `cloneList` clones a *set* of objects whose membership is determined at reconcile time by the label `selector` — the rule author does not know the names in advance. Downstream names are inherited verbatim from the source objects, and the downstream kind is inherited from each source object. This is also why `apiVersion`, `kind` and `name` must be **absent** from the `generate` block when `cloneList` is used: supplying them contradicts the set semantics, and Kyverno rejects the policy.

**A4.2** `cert-manager.io/v1/Certificate` — the format is `group/version/Kind`, with the group omitted for core resources (`v1/Secret`, `v1/ConfigMap`). Note this differs from the `kinds:` list in a `match` block, where a bare `Kind` is accepted.

**A4.3** Continuously. Adding the label to `extra-trust` caused it to be cloned into `team-gamma` without any change to the namespace or the policy; removing the label caused the downstream copy to be deleted. The background controller re-evaluates the selector and reconciles the downstream set to match.

The security implication: **the label is a distribution decision, so label-write permission on the source namespace is equivalent to permission to broadcast that object to every namespace in the cluster.** Anyone with `patch` on objects in `platform-secrets` can propagate arbitrary content cluster-wide, and (by removing a label) can silently revoke a credential everywhere. Source namespaces for `cloneList` need tight RBAC and change auditing.

**A4.4** No. `cloneList` copies source objects verbatim; there is no per-downstream templating hook. The correct decomposition is two rules: `cloneList` for the two objects that are identical everywhere, and a separate `data` rule (with `{{request.object.metadata.name}}` or similar interpolation) for the one that varies. Trying to force a single rule leads people to `data`-inline everything, which reintroduces the secret-in-Git problem from A3.3.

---

### Exercise 5

**A5.1** Because the admission controller never creates the downstream. Its entire output is an `UpdateRequest` — a `kyverno.io` object it already has permission to write. The privileged action, `create tenantprofiles`, is performed later and by a different identity. This separation is deliberate: the admission controller sits in the request path of every API call and is therefore the most security-sensitive component, so it is given the *fewest* resource permissions. The background controller is off the request path and holds the write permissions.

**A5.2** Because the Helm chart owns `kyverno:background-controller`. Any direct edit is silently reverted on the next `helm upgrade` — a failure mode that surfaces weeks later as "generation stopped working after we patched Kyverno", with no correlated change in your policy repo. Kyverno's aggregation labels (`rbac.kyverno.io/aggregate-to-background-controller`, and the parallel labels for the admission, reports and cleanup controllers) exist precisely so that extensions live in objects you own, in your own Git repo, and survive upgrades. Kubernetes' ClusterRole aggregation controller merges the rules automatically.

**A5.3**
- `create` — produce the downstream initially.
- `get` — read the current downstream to compute whether it has drifted (and, for `clone`, read the source).
- `list` / `watch` — maintain the informer over managed downstreams so drift is detected without polling; also required to enumerate downstreams for a policy or trigger during deletion.
- `update` / `patch` — reconcile a drifted downstream back to desired state under `synchronize: true`.
- `delete` — remove the downstream when the trigger is deleted, when the policy is deleted without `orphanDownstreamOnPolicyDelete`, or when a `foreach` element or `cloneList` member leaves the set.

With `synchronize: false` you could get away with `create` and `get`, but the narrower role becomes a landmine the moment someone flips `synchronize` to `true`. Grant the full set.

**A5.4** Rejection at policy admission. It fails **at the moment of the change**, in the CI/CD pipeline or the `kubectl apply` that introduced it, with a message naming the missing permission — attributable to a specific commit and a specific author. A failed `UpdateRequest` fails **asynchronously**, in the `kyverno` namespace, visible only to someone who thinks to look there, and typically discovered when a tenant reports a missing resource days later. The general principle: for policy-as-code, push failures as far left and as loud as possible.

**A5.5** `get` on the source kind **in the source namespace** (`get secrets` in `platform-secrets` for Exercise 3), and for `cloneList`, additionally `list` and `watch` on the source kinds so the selector can be re-evaluated. A rule can therefore fail on either side: permitted to write the downstream but not to read the source, or vice versa. Check both when diagnosing.

---

### Exercise 6

**A6.1** One `UpdateRequest` per matching pre-existing trigger, created in a burst. With four legacy namespaces you should have seen the UR count jump by four. There is no batching — the unit of work is the trigger.

**A6.2** Risks:
1. **API server and etcd pressure.** 4,000 URs created near-simultaneously, then 4,000 downstream creates, plus the resulting watch events fanned out to every controller in the cluster. On a busy control plane this shows up as request latency and can trip client-side throttling.
2. **Unmasking a bad policy at scale.** If the `data` block or a variable is wrong, `generateExisting` propagates the error to every namespace at once rather than to the next one created. With `synchronize: true` it will also overwrite any pre-existing object of the same name — a genuinely destructive outcome if a team already hand-managed a `default-deny` with different rules.

Risk-reducing rollout: apply the policy first with a **narrow `match`** — a namespace label selector such as `kca.io/backfill: "true"` — enable `generateExisting`, backfill a handful of namespaces by labelling them, verify the downstream content, then progressively widen the selector. This gives you a per-batch abort point, and `kyverno apply --cluster` against real namespace manifests beforehand gives you a dry run.

**A6.3** The rule-level `generate.generateExisting` takes precedence over `spec.generateExisting` for that rule. The rule-level field exists because a single policy commonly contains several rules with different risk profiles — backfilling a missing `NetworkPolicy` across 4,000 namespaces is cheap and safe, while backfilling a `ResourceQuota` could immediately start evicting or blocking workloads in namespaces that were previously unconstrained. Per-rule control lets you stage those independently without splitting the policy.

**A6.4** They solve orthogonal problems: `generateExisting` is a **one-time backfill** that answers "what about resources that existed before this policy?", while `synchronize` is **ongoing reconciliation** that answers "what if the downstream is changed or deleted after it is created?". Backfill without sync means the object is created once and then drifts freely; sync without backfill means only newly created triggers are ever served.

---

### Exercise 7

**A7.1** `element` is bound to the current item of the `list` JMESPath expression, evaluated against the trigger — here each object in `request.object.spec.teams`. `elementIndex` is its zero-based position. Both are usable in every templated field of that `foreach` entry: `name`, `namespace`, and anywhere inside the `data` block, including nested `metadata.labels` and `data` values. `foreach` is a list, so one generate rule can contain several entries producing different kinds from different source lists.

**A7.2** `team-data` was deleted. General rule: under `synchronize: true`, the `foreach` list defines the **complete desired set** of downstreams for that entry, and the background controller reconciles the actual set toward it — creating for new elements, updating for changed ones, and **deleting for elements that disappear**. This makes generate-`foreach` a genuine declarative fan-out rather than an append-only creation loop. Under `synchronize: false` the removed element's ConfigMap would have been left behind as an orphan.

**A7.3** Kyverno creates the downstream through a **normal API server request**. It passes through the full admission chain — including Kyverno's own webhooks — exactly like any other write, so it is an ordinary admission event for every other rule in the cluster. This is a feature (it enables layered platform abstractions like Namespace → TenantProfile → per-team ConfigMaps) and a hazard: **generation loops**. If rule A generates a kind that triggers rule B, and rule B generates a kind that triggers rule A, the two rules produce work for each other indefinitely, filling the `kyverno` namespace with `UpdateRequest` objects and hammering the API server. Guard against this with precise `match` selectors, `preconditions` that exclude Kyverno-generated resources (the `generate.kyverno.io/policy-name` label is the marker), and by drawing the trigger→downstream graph before shipping a chained policy set. `resourceFilters` in the Kyverno ConfigMap is the cluster-wide backstop.

**A7.4** `request.userInfo` is populated only from an `AdmissionReview`. Generate rules are executed by the background controller from an `UpdateRequest`, which carries the trigger object but no admission identity — during background reconciliation there is no user, and any value would be a fabrication. Kyverno's policy validation therefore rejects a background-enabled policy that references `userInfo`, with a message along the lines of *variable `{{request.userInfo...}}` is not allowed in background mode*, and directs you to set `background: false`.

Setting `background: false` buys you almost nothing here: the rule would then fire only on live admission events, never on existing resources and never during reconciliation, so `generateExisting` stops working and `synchronize` loses its drift-correction pass. If you need to record who created a namespace, the durable pattern is a **`mutate` rule** that stamps `{{request.userInfo.username}}` onto the *trigger* as an annotation at admission time, and a generate rule that reads that annotation off `request.object` — which is available in both modes.

**A7.5** The CRD schema makes `spec.tier` optional, so a `TenantProfile` created without it has no `tier` field at all. Evaluating `{{ request.object.spec.tier }}` against a missing path produces a variable-resolution failure, and depending on Kyverno's failure policy that turns into a rule error rather than a clean skip. The `|| ''` default converts "absent" into the empty string, which then simply fails the `AnyIn` check and skips the rule. **Always supply a default for any variable that reads an optional field** — this is the single most common source of intermittent generate-rule errors.

---

### Exercise 8

**A8.1**
1. **The trigger is deleted** → downstream deleted, governed by `synchronize: true`. With `synchronize: false`, the downstream survives.
2. **The policy (or the rule) is deleted** → downstream deleted, governed by `generate.orphanDownstreamOnPolicyDelete`. Default `false` means delete; `true` means leave it behind. Deleting a single rule from a multi-rule policy behaves like deleting the policy *for that rule's downstreams only*.
3. **The rule stops matching** — the trigger's labels change, the `match` block is narrowed, or a `precondition` starts evaluating false → the downstream is deleted under `synchronize: true`, because it is no longer part of the desired set.
4. **An element leaves the set** — a `foreach` list item or a `cloneList` selector match disappears → that specific downstream is deleted under `synchronize: true` (A7.2, A4.3).

Note what is *not* on this list: normal Kubernetes garbage collection. There are no `ownerReferences` (A1.2), so every deletion above is an explicit act by the background controller — which is exactly why it needs `delete` in its RBAC (A5.3).

**A8.2** The labels advertise a relationship that no longer exists. Concrete hazards: an operator re-creating a policy with the same name may adopt the orphan and overwrite it with different content; cleanup tooling or a runbook that selects on `app.kubernetes.io/managed-by=kyverno` will delete an object nothing is managing; and inventory queries misreport the object as policy-governed, so it never gets picked up by whatever process handles unmanaged resources. In a real cluster, strip or rewrite the labels as part of the decommissioning procedure — e.g. `kubectl label <res> generate.kyverno.io/policy-name- app.kubernetes.io/managed-by-` — and record the orphan in your inventory.

**A8.3** A rename in Git is a **delete plus create** to the GitOps controller. Sequence: the old `ClusterPolicy` is deleted → Kyverno deletes every downstream it owned (default `orphanDownstreamOnPolicyDelete: false`) → the new `ClusterPolicy` is created → new `UpdateRequest`s are generated → the downstreams are recreated. Between the two, every namespace in the cluster is briefly without its `NetworkPolicy` / `ResourceQuota` / registry credential. For a default-deny NetworkPolicy that window is a cluster-wide open-network interval; for a registry credential it is a wave of `ImagePullBackOff` on any pod that restarts.

`orphanDownstreamOnPolicyDelete: true` prevents the outage: the downstreams survive the delete, and the recreated policy re-adopts and reconciles them. For any policy generating a security- or availability-critical downstream, this should be the default posture, and policy renames should still be treated as a change-controlled operation.

**A8.4** No — it is a no-op. With `synchronize: false` Kyverno does not track the downstream for lifecycle purposes; policy deletion already leaves it in place. `orphanDownstreamOnPolicyDelete` only alters behaviour that exists solely under `synchronize: true`. Setting both is harmless but signals a misunderstanding in review.

---

### Exercise 9

**A9.1**
- **`Pending`** — the rule matched and the work was correctly enqueued, but nothing consumed it. Root cause class: **the background controller is unavailable** (scaled to zero, crash-looping, OOMKilled, leader-election stuck, or so far behind that the queue has backed up). The policy itself is fine.
- **`Failed`** — the background controller picked up the work and the API call it attempted was rejected. Root cause class: **execution error** — missing RBAC (`Forbidden`), missing clone source (`NotFound`), unresolvable variable, or a downstream manifest the API server rejects as invalid. `status.message` names it.
- **No UR at all** — the admission controller never decided the rule applied. Root cause class: **matching** — `match`/`exclude` did not select the trigger, a `precondition` evaluated false, the webhook did not fire for that resource kind (check the `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` rules), the trigger's namespace is in the Kyverno ConfigMap's `resourceFilters`, or the policy is not `READY`.

Checking which of these three states you are in is the first diagnostic branch, and it costs one command.

**A9.2** The `UpdateRequest` is a **durable, declarative work item in etcd**, not an in-memory queue entry. It survived the outage, and the background controller reconciled it on startup — the same at-least-once delivery model any Kubernetes controller relies on. Had the UR been deleted while the controller was down, the work would have been lost permanently: nothing re-derives it, because the admission event that produced it is long gone. Recovery would require re-triggering — touching the trigger resource, or enabling `generateExisting` to force a backfill sweep. **Never bulk-delete `UpdateRequest` objects as a "cleanup" step while the background controller is unhealthy.**

**A9.3** `PolicyReport` and `ClusterPolicyReport` are produced by the **reports controller** and record the outcomes of `validate` and `verifyImages` rules — rule types that make a pass/fail judgement about a resource. A generate rule makes no judgement about its trigger; it performs an action elsewhere, so there is nothing to report against the trigger. The correct object to watch is the **`UpdateRequest`** (`kubectl -n kyverno get ur`), supplemented by background-controller logs and Kubernetes events on the policy. This trips people up constantly: an empty `PolicyReport` is not evidence that a generate rule is healthy.

**A9.4**
1. `kubectl get cpol <name>` — is the policy `READY: True`? A policy that failed its own validation generates nothing.
2. `kubectl -n kyverno get ur | grep <trigger>` — does an `UpdateRequest` exist? This is the matching-vs-execution branch of A9.1.
3. If none: re-read `match`/`exclude`/`preconditions` against the trigger's actual labels and namespace (`kubectl get <trigger> --show-labels`), and check `resourceFilters` in the Kyverno ConfigMap.
4. If `Pending`: `kubectl -n kyverno get pods` and `kubectl -n kyverno logs deploy/kyverno-background-controller` — is the controller running and healthy?
5. If `Failed`: read `status.message` on the UR, then `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:kyverno:kyverno-background-controller -n <target-ns>` for the downstream **and**, if cloning, for the source.

Steps 1–2 cost two commands and localise the fault to one of three subsystems; everything after is targeted.

**A9.5**
1. **A competing controller or a second Kyverno rule.** Something else deletes or overwrites the object, Kyverno's `synchronize: true` loop restores it, and the two oscillate. Distinguish with `kubectl get events -n <ns> --field-selector involvedObject.name=<downstream> --sort-by=.lastTimestamp` and by checking whether the object's `metadata.managedFields` lists more than one manager — a second manager name is the smoking gun.
2. **The trigger is itself flapping**, or a `precondition`/`match` is intermittently false — e.g. a controller toggles a label the `match` selector depends on, so the downstream alternates between "in the desired set" and "not in it". Distinguish by watching the trigger rather than the downstream: `kubectl get <trigger> --show-labels -w`, and by watching UR churn with `kubectl -n kyverno get ur -w` — a stream of *new* URs points at trigger flapping, whereas one stable UR reconciling repeatedly points at cause 1.

A third possibility worth ruling out cheaply: the downstream namespace is terminating, so every create succeeds and is immediately reaped.

---

### Exercise 10

**A10.1** `data` generation is **self-contained**: the desired downstream is fully specified by the policy manifest plus the trigger fixture, both of which the CLI has on disk. `clone` generation is **cluster-dependent**: the content of the downstream is whatever `platform-secrets/regcred` currently holds, and that object exists only in the cluster. Without `--cluster` the CLI cannot resolve the source and reports that it is unavailable; with `--cluster` it uses your kubeconfig to fetch it. The same dependency applies to any rule using an API-call `context` entry — offline testing is possible exactly to the extent the rule is a pure function of the policy and the trigger.

**A10.2**
1. **RBAC failures.** `kyverno test` never issues the downstream `create` against a real API server, so a rule that will fail with `Forbidden` in production passes cleanly in CI. Exposed by **Exercise 5**.
2. **Lifecycle and synchronization behaviour.** Drift correction, trigger-deletion cascades, `foreach` set reconciliation, `orphanDownstreamOnPolicyDelete` — all require a live controller observing changes over time. The CLI evaluates a single point-in-time trigger. Exposed by **Exercises 2, 7 and 8**.

Also creditable: chained-generation loops (Exercise 7), which only manifest when downstreams re-enter the admission path; and clone-source drift (Exercise 3), since a `--cluster` run captures one snapshot of the source.

**A10.3** They are different gates and neither substitutes for the other. `kyverno test` belongs **early**, on every pull request against the policy repository — it is fast, hermetic for `data` rules, and catches variable-resolution errors, precondition logic bugs, and wrong downstream content. The RBAC check belongs **at deploy time against the target cluster**, because the answer depends on that cluster's aggregated ClusterRoles, which are not in the policy repo and differ between staging and production.

A rule can be perfectly correct and still be unable to run (missing RBAC); it can also have flawless RBAC and generate exactly the wrong content. A practical pipeline runs `kyverno test` in CI, then in the deploy job runs `kubectl auth can-i` for every kind referenced in a `generate` block — downstream kinds and clone sources both — before applying the policies.

</details>

---

## Sources

- Kyverno — Generate Rules: <https://kyverno.io/docs/writing-policies/generate/> (reorganised in recent releases to <https://kyverno.io/docs/policy-types/cluster-policy/generate/>)
- Kyverno — Policy definition, `match`/`exclude`, `preconditions`, variables: <https://kyverno.io/docs/writing-policies/>
- Kyverno — Installation customization and RBAC aggregation labels: <https://kyverno.io/docs/installation/customization/>
- Kyverno — Troubleshooting: <https://kyverno.io/docs/troubleshooting/>
- Kyverno — CLI (`apply`, `test`): <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno policy library (production examples of `data`, `clone` and `cloneList` rules): <https://kyverno.io/policies/> and <https://github.com/kyverno/policies>
- Kubernetes — Owner references and garbage collection (why generate uses labels instead): <https://kubernetes.io/docs/concepts/architecture/garbage-collection/>
- Kubernetes — ClusterRole aggregation: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles>
- Kubernetes — NetworkPolicy, ResourceQuota: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>, <https://kubernetes.io/docs/concepts/policy/resource-quotas/>
- CNCF — KCA curriculum: <https://github.com/cncf/curriculum>