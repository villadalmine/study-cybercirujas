# Guided Exercises — 3.6 Manage Role-Based Access Control (RBAC)

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

RBAC objects (`Role`, `ClusterRole`, `RoleBinding`, `ClusterRoleBinding`) regulate authorization across the Kubernetes API.

---

## Exercise 1 — ServiceAccounts and Default Permission Inspections

1. Create a workspace namespace:

```bash
kubectl create namespace rbac-lab
```

2. Manifest a `ServiceAccount` named `dev-reader`:

```bash
kubectl create serviceaccount dev-reader -n rbac-lab
```

3. Test permissions using `kubectl auth can-i` with `--as`:

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:rbac-lab:dev-reader \
  -n rbac-lab
```

4. Re-run testing `delete` actions instead of `list`.

### Questions

1. What response does `kubectl auth can-i list pods` return for unassigned ServiceAccounts?
2. What format represents a ServiceAccount identity in `--as` arguments?

---

## Exercise 2 — Namespaced `Role` and `RoleBinding`

1. Manifest file `pod-reader-role.yaml` defining a `Role`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: rbac-lab
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

2. Apply role manifest:

```bash
kubectl apply -f pod-reader-role.yaml
```

3. Create a `RoleBinding` assigning the `Role` to ServiceAccount `dev-reader`:

```bash
kubectl create rolebinding dev-reader-binding \
  --role=pod-reader \
  --serviceaccount=rbac-lab:dev-reader \
  -n rbac-lab
```

4. Re-verify permission checks using `kubectl auth can-i`.

### Questions

3. Why is `apiGroups` set to `[""]` (empty string) for Pod resources?
4. Can `roleRef` fields be updated post-creation?

---

## Exercise 3 — `ClusterRole` and `ClusterRoleBinding`

1. Manifest a `ClusterRole` granting `get` and `list` access on `nodes`:

```bash
kubectl create clusterrole node-viewer \
  --verb=get,list \
  --resource=nodes
```

2. Bind the `ClusterRole` to ServiceAccount `ops-viewer` via a `ClusterRoleBinding`:

```bash
kubectl create serviceaccount ops-viewer -n rbac-lab
kubectl create clusterrolebinding ops-viewer-binding \
  --clusterrole=node-viewer \
  --serviceaccount=rbac-lab:ops-viewer
```

3. Verify cluster-level node access:

```bash
kubectl auth can-i list nodes \
  --as=system:serviceaccount:rbac-lab:ops-viewer
```

### Questions

5. Why can cluster-scoped resources like `nodes` not be authorized via namespaced `Roles`?

---

## Exercise 4 — `resourceNames` Restrictions

1. Create target ConfigMap resources:

```bash
kubectl create configmap app-config -n rbac-lab --from-literal=env=dev
kubectl create configmap other-config -n rbac-lab --from-literal=env=prod
```

2. Manifest a `Role` restricting access exclusively to `app-config`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: rbac-lab
  name: single-configmap-reader
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config"]
  verbs: ["get"]
```

3. Apply role and bind to `dev-reader`:

```bash
kubectl apply -f single-configmap-role.yaml
kubectl create rolebinding cm-reader-binding \
  --role=single-configmap-reader \
  --serviceaccount=rbac-lab:dev-reader \
  -n rbac-lab
```

4. Verify resource-specific permissions:

```bash
kubectl auth can-i get configmap/app-config \
  --as=system:serviceaccount:rbac-lab:dev-reader -n rbac-lab
kubectl auth can-i get configmap/other-config \
  --as=system:serviceaccount:rbac-lab:dev-reader -n rbac-lab
```

### Questions

6. Why does `app-config` return `yes` while `other-config` returns `no`?
7. Can `resourceNames` restrict `list` or `create` verbs?

---

## Exercise 5 — Scoping Built-In `ClusterRoles` via `RoleBinding`

1. Confirm built-in `view` ClusterRole exists:

```bash
kubectl get clusterrole view
```

2. Manifest a `RoleBinding` in `rbac-lab` binding `ClusterRole` `view` to `ops-viewer`:

```bash
kubectl create rolebinding ops-viewer-view-binding \
  --clusterrole=view \
  --serviceaccount=rbac-lab:ops-viewer \
  -n rbac-lab
```

3. Test permissions in namespace `rbac-lab` vs namespace `default`:

```bash
kubectl auth can-i list deployments \
  --as=system:serviceaccount:rbac-lab:ops-viewer -n rbac-lab
kubectl auth can-i list deployments \
  --as=system:serviceaccount:rbac-lab:ops-viewer -n default
```

### Questions

8. Why are permissions granted via `RoleBindings` referencing `ClusterRoles` restricted to target namespaces?

---

## Exercise 6 — Permission Auditing via `kubectl auth can-i --list`

1. Audit effective permissions for `dev-reader`:

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:rbac-lab:dev-reader -n rbac-lab
```

---

## Teardown

```bash
kubectl delete namespace rbac-lab
kubectl delete clusterrole node-viewer
kubectl delete clusterrolebinding ops-viewer-binding
```

---

<details>
<summary>View Answers</summary>

1. Returns `no` due to Kubernetes default-deny authorization rules.
2. `system:serviceaccount:<namespace>:<sa-name>`.
3. An empty string `""` designates core API group resources.
4. No. `roleRef` fields are immutable post-creation.
5. `nodes` are cluster-scoped resources outside namespace boundaries.
6. `resourceNames` restricts permissions exclusively to matching object instance names.
7. No. `list` and `create` operations target collection endpoints prior to object name evaluation.
8. `RoleBindings` scope all permissions strictly to their parent namespace context.

</details>
