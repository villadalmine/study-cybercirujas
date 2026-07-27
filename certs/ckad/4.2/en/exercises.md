# Exercises: 4.2 Understand authentication, authorization and admission control (CKAD)

> Reference Source: [CKAD Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

These exercises assume an accessible Kubernetes cluster via `kubectl` with administrator permissions (`cluster-admin`), working within namespace `ckad-auth`. Create namespace before starting:

```bash
kubectl create namespace ckad-auth
kubectl config set-context --current --namespace=ckad-auth
```

---

## Exercise 1 — ServiceAccounts

1. List ServiceAccounts currently existing in `ckad-auth` namespace.

   ```bash
   kubectl get serviceaccounts
   ```

2. Create a new ServiceAccount named `app-sa`.

   ```bash
   kubectl create serviceaccount app-sa
   ```

3. Inspect the newly created ServiceAccount in YAML format.

   ```bash
   kubectl get serviceaccount app-sa -o yaml
   ```

4. Create a Pod explicitly using this ServiceAccount instead of `default`.

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sa-demo
   spec:
     serviceAccountName: app-sa
     containers:
       - name: main
         image: nginx:1.27
   ```

   ```bash
   kubectl apply -f sa-demo.yaml
   ```

5. Confirm which ServiceAccount the Pod ultimately used.

   ```bash
   kubectl get pod sa-demo -o jsonpath='{.spec.serviceAccountName}'
   ```

6. Exec into container and verify ServiceAccount token is mounted automatically.

   ```bash
   kubectl exec -it sa-demo -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

**Comprehension Questions**

- If `serviceAccountName` were omitted from Pod manifest, which ServiceAccount would have been assigned and why?
- Which three files do you expect mounted at `/var/run/secrets/kubernetes.io/serviceaccount/` and what is each file's purpose?

---

## Exercise 2 — Namespaced RBAC: Role and RoleBinding

1. Create a `Role` permitting `get`, `list`, and `watch` actions on Pods inside `ckad-auth`.

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: ckad-auth
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f pod-reader-role.yaml
   ```

2. Create a `RoleBinding` binding `pod-reader` `Role` to ServiceAccount `app-sa` created in Exercise 1.

   ```bash
   kubectl create rolebinding app-sa-pod-reader \
     --role=pod-reader \
     --serviceaccount=ckad-auth:app-sa
   ```

3. Verify created binding.

   ```bash
   kubectl get rolebinding app-sa-pod-reader -o yaml
   ```

4. Verify with `kubectl auth can-i`, impersonating the ServiceAccount, whether it can list Pods and delete Pods.

   ```bash
   kubectl auth can-i list pods \
     --as=system:serviceaccount:ckad-auth:app-sa

   kubectl auth can-i delete pods \
     --as=system:serviceaccount:ckad-auth:app-sa
   ```

**Comprehension Questions**

- Why should the second `can-i` evaluation return `no`? Which rule in `Role` determines this behavior?
- A `Role` and its `RoleBinding` are both scoped to a single namespace. If `app-sa` required reading Pods in namespace `default` as well, would the current `RoleBinding` suffice? What would you change?

---

## Exercise 3 — Cluster-Wide RBAC: ClusterRole and ClusterRoleBinding

1. Create a `ClusterRole` allowing `get` and `list` verbs on `nodes` (cluster-scoped resource).

   ```bash
   kubectl create clusterrole node-viewer \
     --verb=get,list \
     --resource=nodes
   ```

2. Bind that `ClusterRole` to ServiceAccount `app-sa` using a `ClusterRoleBinding`.

   ```bash
   kubectl create clusterrolebinding app-sa-node-viewer \
     --clusterrole=node-viewer \
     --serviceaccount=ckad-auth:app-sa
   ```

3. Verify resulting permission.

   ```bash
   kubectl auth can-i list nodes \
     --as=system:serviceaccount:ckad-auth:app-sa
   ```

4. Now create a second `RoleBinding` (namespaced) referencing the same `ClusterRole` `node-viewer`, but scoped strictly to namespace `ckad-auth`, and assigned to another ServiceAccount `app-sa-2`.

   ```bash
   kubectl create serviceaccount app-sa-2

   kubectl create rolebinding app-sa-2-node-viewer \
     --clusterrole=node-viewer \
     --serviceaccount=ckad-auth:app-sa-2
   ```

5. Compare output of `can-i list nodes` for `app-sa-2` against `app-sa`.

   ```bash
   kubectl auth can-i list nodes \
     --as=system:serviceaccount:ckad-auth:app-sa-2
   ```

**Comprehension Questions**

- `nodes` is a cluster-scoped resource. Why does `RoleBinding` in step 4, despite referencing a valid `ClusterRole` with rules for `nodes`, fail to grant `app-sa-2` permission to list nodes?
- What is the practical difference between reusing a `ClusterRole` via `RoleBinding` versus via `ClusterRoleBinding`?

---

## Exercise 4 — Permission Audit with `kubectl auth can-i`

1. List all effective permissions for your own current user/kubeconfig context in namespace `ckad-auth`.

   ```bash
   kubectl auth can-i --list -n ckad-auth
   ```

2. Repeat query impersonating ServiceAccount `app-sa`.

   ```bash
   kubectl auth can-i --list \
     --as=system:serviceaccount:ckad-auth:app-sa \
     -n ckad-auth
   ```

3. Use `--as-group` to simulate membership in an arbitrary group and verify if additional permissions open up (should return no, unless a binding for that group exists).

   ```bash
   kubectl auth can-i list secrets \
     --as=someuser \
     --as-group=system:authenticated \
     -n ckad-auth
   ```

**Comprehension Questions**

- `kubectl auth can-i` queries API server via `SelfSubjectAccessReview` (or `SubjectAccessReview` when using `--as`). Against which control plane component is this decision ultimately evaluated?
- If `can-i --list` displays no rows for `secrets`, does that guarantee no `ClusterRole`/`Role` exists in the cluster with permissions on `secrets`, or only that the queried subject lacks that permission?

---

## Exercise 5 — Admission Control

Admission controllers operate *after* request passes authentication and authorization (RBAC), but *before* object is persisted to etcd. Built-in admission controllers such as `ResourceQuota` and `LimitRange` are enabled by default and configured via API objects.

1. Create a `LimitRange` enforcing a default container CPU limit in namespace `ckad-auth`.

   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: cpu-limit-range
   spec:
     limits:
       - default:
           cpu: 500m
         defaultRequest:
           cpu: 250m
         type: Container
   ```

   ```bash
   kubectl apply -f cpu-limit-range.yaml
   ```

2. Create a Pod omitting `resources` specification, and verify admission controller injected default values.

   ```bash
   kubectl run limit-demo --image=nginx:1.27
   kubectl get pod limit-demo -o jsonpath='{.spec.containers[0].resources}'
   ```

3. Create a `ResourceQuota` capping Pod count at 2 in namespace.

   ```yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: pod-quota
   spec:
     hard:
       pods: "2"
   ```

   ```bash
   kubectl apply -f pod-quota.yaml
   ```

4. Attempt to create a third Pod in namespace and observe error message.

   ```bash
   kubectl run extra-pod --image=nginx:1.27
   ```

**Comprehension Questions**

- Error in step 4 mentions `exceeded quota`. Did this rejection occur during authentication, authorization, or admission control? Justify with request pipeline phase where `ResourceQuota` intervenes.
- What is the difference between a built-in admission controller (`LimitRange`/`ResourceQuota`) vs `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` regarding where decision logic lives?

---

<details>
<summary>View Answers</summary>

**Exercise 1**

- If `serviceAccountName` is omitted, Pod uses namespace `default` ServiceAccount, created automatically by Kubernetes in every new namespace.
- Mounted files: `token` (JWT used to authenticate against API server), `ca.crt` (cluster CA certificate verifying API server identity), and `namespace` (Pod namespace string).

**Exercise 2**

- Second `can-i` returns `no` because `pod-reader` `Role` includes only `get`, `list`, `watch` verbs on `pods`; `delete` is omitted, and Kubernetes RBAC defaults to deny-all unless explicitly allowed.
- Would not suffice. `RoleBinding` grants `Role` strictly inside namespace where `RoleBinding` lives (`ckad-auth`). To grant access in `default`, another `Role` (or shared `ClusterRole`) and `RoleBinding` must be created in `default` namespace.

**Exercise 3**

- A `RoleBinding`, even when referencing a `ClusterRole`, grants permissions strictly inside the namespace where `RoleBinding` lives. Because `nodes` is cluster-scoped and non-namespaced, a namespaced binding can never grant effective permissions over cluster-scoped resources.
- `ClusterRoleBinding` grants `ClusterRole` permissions cluster-wide (across all namespaces and non-namespaced resources). `RoleBinding` referencing a `ClusterRole` reuses the same rule definitions but limits effective scope to the binding's namespace for namespaced resources.

**Exercise 4**

- Evaluated against API server, which queries configured authorizers (such as RBAC authorizer) to decide `allowed: true/false` on `SubjectAccessReview`.
- Guarantees only that queried subject (user/group/ServiceAccount passed with `--as`) lacks permission. Other `Role`/`ClusterRole` definitions granting access to `secrets` may exist for other subjects; `can-i --list` displays evaluated subject's effective permissions, not a global RBAC inventory.

**Exercise 5**

- Occurred during admission control phase. Request pipeline order: authentication → authorization (RBAC) → admission controllers (mutating then validating) → etcd persistence. `ResourceQuota` is a validating admission controller rejecting request before persistence, even after RBAC authorization passed.
- Built-in admission controllers (`LimitRange`, `ResourceQuota`, etc.) have logic compiled inside `kube-apiserver` binary and are configured declaratively via API objects. Webhooks (`ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration`) delegate decisions to external HTTP services (inside or outside cluster) receiving `AdmissionReview` requests to accept, reject, or mutate objects.

</details>
