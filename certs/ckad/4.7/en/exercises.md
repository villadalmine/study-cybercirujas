# 4.7 Understand ServiceAccounts — Guided Exercises

**Exam:** CKAD (v1.35) · **Weight:** 3

All exercises run in a dedicated namespace to avoid interference with other cluster resources.

```bash
kubectl create namespace ckad-4-7
kubectl config set-context --current --namespace=ckad-4-7
```

---

## Exercise 1 — Default ServiceAccount vs. Custom ServiceAccount

1. List existing ServiceAccounts in the newly created namespace.

   ```bash
   kubectl get serviceaccounts
   ```

2. Create a Pod **without** specifying `serviceAccountName`.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-default
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-default --timeout=60s
   ```

3. Confirm assigned ServiceAccount name.

   ```bash
   kubectl get pod pod-default -o jsonpath='{.spec.serviceAccountName}{"\n"}'
   ```

4. Create a custom ServiceAccount and a second Pod explicitly using it.

   ```bash
   kubectl create serviceaccount app-sa
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-app-sa
   spec:
     serviceAccountName: app-sa
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-app-sa --timeout=60s
   kubectl get pod pod-app-sa -o jsonpath='{.spec.serviceAccountName}{"\n"}'
   ```

5. Attempt changing `pod-default` ServiceAccount **after** creation.

   ```bash
   kubectl patch pod pod-default -p '{"spec":{"serviceAccountName":"app-sa"}}'
   ```

<details>
<summary>Questions — Exercise 1</summary>

1. Which ServiceAccount appears in step 3, and where does it originate since step 2 manifest omits it?
2. What does `patch` command return in step 5, and why?
3. If `app-sa` grants no RBAC permissions initially, how do `pod-app-sa` and `pod-default` differ practically?

**Answers**

1. Displays `default`. Every namespace creates a ServiceAccount named `default` automatically, and Pods omitting `spec.serviceAccountName` bind to it automatically.
2. Returns error stating field is immutable (`Forbidden: pod updates may not change fields other than...`). `spec.serviceAccountName` can only be set at Pod creation; changing it requires deleting and recreating Pod (or updating Deployment template triggering rolling update).
3. Practically identical: while neither ServiceAccount carries RBAC bindings, both Pods possess zero API permissions. Creating dedicated ServiceAccounts enables clear RBAC auditing and isolation per workload.

</details>

---

## Exercise 2 — Token Mechanics: Authentication (401) vs. Authorization (403)

1. Create a Pod with `curl` using `app-sa` to query API server endpoints internally.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-curl
   spec:
     serviceAccountName: app-sa
     containers:
     - name: curl
       image: curlimages/curl:8.11.0
       command: ["sleep", "3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-curl --timeout=60s
   ```

2. Confirm mounted ServiceAccount identity files inside container.

   ```bash
   kubectl exec pod-curl -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

3. Request a short-lived token via `kubectl create token`, using it immediately from inside Pod.

   ```bash
   TOKEN=$(kubectl create token app-sa --duration=30s)
   kubectl exec pod-curl -- curl -sS -o /dev/null -w "%{http_code}\n" \
     --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   ```

4. Wait for token expiration, then re-execute exact query with expired `$TOKEN`.

   ```bash
   sleep 40
   kubectl exec pod-curl -- curl -sS -o /dev/null -w "%{http_code}\n" \
     --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   ```

5. Repeat request using auto-mounted token mounted in Pod filesystem (from step 2).

   ```bash
   kubectl exec pod-curl -- sh -c '
     curl -sS -o /dev/null -w "%{http_code}\n" \
       --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
       -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
       https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   '
   ```

<details>
<summary>Questions — Exercise 2</summary>

1. Which HTTP status code returns in steps 3 and 5, and why (considering `app-sa` has no RBAC bindings yet)?
2. Which HTTP status code returns in step 4, and how does it conceptually differ from steps 3 and 5?
3. Why does auto-mounted token in step 5 continue working when short-lived token in step 3 expired?

**Answers**

1. Returns **403 Forbidden**. API server authenticates token successfully (identifying subject `system:serviceaccount:ckad-4-7:app-sa`), but RBAC lacks rules permitting `list` on `pods` — request fails authorization, not authentication.
2. Returns **401 Unauthorized**. Unlike 403, API server fails request at authentication stage: token expired after 30 seconds (`--duration=30s`). 401 = unauthenticated; 403 = authenticated but unauthorized.
3. Short-lived token requested with explicit 30s expiration. Kubelet auto-mounted token (`/var/run/secrets/kubernetes.io/serviceaccount/token`) defaults to 1-hour validity, auto-renewed periodically by kubelet while Pod runs.

</details>

---

## Exercise 3 — RBAC: From `Forbidden` to `Allowed`

1. Simulate permission check confirming `app-sa` cannot list Pods.

   ```bash
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa
   ```

2. Create a `Role` permitting Pod reading and a `RoleBinding` binding it to `app-sa`.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: app-sa-pod-reader
   subjects:
   - kind: ServiceAccount
     name: app-sa
     namespace: ckad-4-7
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   EOF
   ```

3. Re-run simulation check from step 1.

   ```bash
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa
   ```

4. Confirm actual API call from `pod-curl` (from exercise 2) using auto-mounted token.

   ```bash
   kubectl exec pod-curl -- sh -c '
     curl -sS -o /dev/null -w "%{http_code}\n" \
       --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
       -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
       https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   '
   ```

5. Test if permission applies across another namespace.

   ```bash
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa -n kube-system
   ```

<details>
<summary>Questions — Exercise 3</summary>

1. Why does step 3 return `yes` immediately without modifying Pod or token?
2. Why does `RoleBinding` subject in step 2 explicitly declare `namespace: ckad-4-7`?
3. What returns in step 5, and why is `Role`/`RoleBinding` insufficient for cross-namespace access?

**Answers**

1. RBAC evaluates live against current `Role` and `RoleBinding` states per API request. The authenticated identity (`system:serviceaccount:ckad-4-7:app-sa`) evaluates against newly created binding rules immediately.
2. `RoleBinding` subjects can reference ServiceAccounts across different namespaces. Explicit `namespace` fields prevent misbinding to non-target subjects.
3. Returns `no`. `pod-reader` is a namespaced `Role` bound via namespaced `RoleBinding` scoped strictly to `ckad-4-7`. Cross-namespace access requires `ClusterRoleBinding` or individual namespaced `RoleBindings`.

</details>

---

## Exercise 4 — `automountServiceAccountToken`: Precedence Mechanics

1. Create a ServiceAccount with automount disabled.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: quiet-sa
   automountServiceAccountToken: false
   EOF
   ```

2. Create a Pod using `quiet-sa` omitting Pod-level automount configuration.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-quiet
   spec:
     serviceAccountName: quiet-sa
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-quiet --timeout=60s
   kubectl exec pod-quiet -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ```

3. Create a second Pod using `quiet-sa` but **overriding** automount to `true` at Pod level.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-quiet-override
   spec:
     serviceAccountName: quiet-sa
     automountServiceAccountToken: true
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-quiet-override --timeout=60s
   kubectl exec pod-quiet-override -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

4. Create a third Pod using `app-sa` (default automount `true`) but overriding to `false` at Pod level.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-app-sa-no-token
   spec:
     serviceAccountName: app-sa
     automountServiceAccountToken: false
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-app-sa-no-token --timeout=60s
   kubectl exec pod-app-sa-no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ```

<details>
<summary>Questions — Exercise 4</summary>

1. What displays in step 2, and why does this behavior occur?
2. Comparing steps 3 and 4, what precedence rule governs `spec.automountServiceAccountToken` between Pod and ServiceAccount?
3. When should automounting be disabled, and what security benefit is achieved?

**Answers**

1. Displays `No such file or directory`. Pod inherits `automountServiceAccountToken: false` from `quiet-sa` ServiceAccount because Pod spec omitted explicit setting.
2. **Pod-level settings always override ServiceAccount settings**. Explicit Pod `true` overrides SA `false` (step 3); explicit Pod `false` overrides SA `true` (step 4).
3. Disable automounting on workloads not communicating with API server (e.g. web servers, database consumers). Eliminates credential exposure if container is compromised.

</details>

---

## Exercise 5 — `imagePullSecrets` Inheritance in ServiceAccount

1. Create a dummy `docker-registry` Secret.

   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=registry.example.com \
     --docker-username=demo \
     --docker-password=demo-pass \
     --docker-email=demo@example.com
   ```

2. Associate Secret to `app-sa` as `imagePullSecrets`.

   ```bash
   kubectl patch serviceaccount app-sa \
     -p '{"imagePullSecrets": [{"name": "regcred"}]}'
   ```

3. Create a Pod using `app-sa` omitting `imagePullSecrets` in Pod spec, inspecting resulting spec.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-inherits
   spec:
     serviceAccountName: app-sa
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl get pod pod-inherits -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
   ```

4. Create a second dummy Secret and a Pod specifying its **own** `imagePullSecrets`.

   ```bash
   kubectl create secret docker-registry regcred2 \
     --docker-server=registry2.example.com \
     --docker-username=demo2 \
     --docker-password=demo-pass2 \
     --docker-email=demo2@example.com

   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-own-secret
   spec:
     serviceAccountName: app-sa
     imagePullSecrets:
     - name: regcred2
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl get pod pod-own-secret -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
   ```

<details>
<summary>Questions — Exercise 5</summary>

1. What appears in `spec.imagePullSecrets` for `pod-inherits` in step 3?
2. What appears in `spec.imagePullSecrets` for `pod-own-secret` in step 4: `regcred2` only, `regcred` only, or combined list?
3. If a Pod requires both ServiceAccount (`regcred`) and Pod-specific (`regcred2`) pull secrets, how must Pod spec be declared?

**Answers**

1. Displays `[{"name":"regcred"}]`. Admission controller copies ServiceAccount `imagePullSecrets` into Pod spec at creation when Pod `imagePullSecrets` is empty.
2. Displays **only** `regcred2` — SA `regcred` is **not** appended. Automatic copying occurs ONLY when Pod `imagePullSecrets` field is empty.
3. List **both** secrets explicitly under Pod `imagePullSecrets` (`- name: regcred` and `- name: regcred2`).

</details>

---

## Exercise 6 — Troubleshooting: Missing ServiceAccount & Orphaned RoleBindings

1. Attempt creating a Pod referencing a non-existent ServiceAccount.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-bad-sa
   spec:
     serviceAccountName: no-existe
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   ```

2. Confirm Pod object creation was rejected.

   ```bash
   kubectl get pod pod-bad-sa
   ```

3. Delete ServiceAccount `app-sa` while `RoleBinding` `app-sa-pod-reader` still targets it.

   ```bash
   kubectl delete serviceaccount app-sa
   kubectl get serviceaccount app-sa 2>&1
   ```

4. Re-run permission simulation for deleted ServiceAccount identity.

   ```bash
   kubectl describe rolebinding app-sa-pod-reader
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa
   ```

<details>
<summary>Questions — Exercise 6</summary>

1. What error message returns in step 1, and when is Pod rejected?
2. Is there an `optional: true` equivalent for `serviceAccountName`?
3. What does step 4 return, and what security implication exists regarding orphaned `RoleBindings`?

**Answers**

1. Returns error `pods "pod-bad-sa" is forbidden: error looking up service account ckad-4-7/no-existe: serviceaccount "no-existe" not found`. Creation fails at admission validation before Pod object persistence in etcd.
2. No. No `optional` flag exists for `serviceAccountName`. A valid existing ServiceAccount is mandatory for Pod admission.
3. Returns `yes`: `RoleBinding` remains active. RBAC evaluates subject strings (`system:serviceaccount:ckad-4-7:app-sa`) without verifying object existence on every request. Recreating a ServiceAccount named `app-sa` automatically inherits orphaned binding permissions.

</details>

---

## Teardown

```bash
kubectl delete rolebinding app-sa-pod-reader --ignore-not-found
kubectl delete role pod-reader --ignore-not-found
kubectl config set-context --current --namespace=default
kubectl delete namespace ckad-4-7
```
