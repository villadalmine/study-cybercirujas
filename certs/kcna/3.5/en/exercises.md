# Topic 3.5: Security — Guided Exercises (KCNA)

> Reference source: [KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf) (CNCF). The content of this material is original and developed from that source, not a transcription of it.

These exercises assume you have access to a Kubernetes cluster (`kind`, `minikube`, or similar) with `kubectl` configured against that cluster.

---

## Exercise 1 — The 4C's model of cloud native security

The 4C's model organizes security into concentric layers: **Cloud** (infrastructure), **Cluster** (Kubernetes), **Container** (image and runtime), and **Code** (your application). Each layer depends on the layers surrounding it being secured.

1. Write down on a sheet the four layers of the 4C's model, from outermost to innermost.
2. For each of the following practices, indicate which layer it primarily belongs to:
   - Enabling RBAC on the API server.
   - Scanning an image for CVEs before publishing it to the registry.
   - Restricting network access to the cloud provider (security groups / firewall).
   - Validating and sanitizing inputs of an HTTP endpoint in your application.
   - Using `NetworkPolicy` to isolate traffic between namespaces.
3. Write a sentence explaining why securing only the Code without securing the Cluster is not enough (think about what would happen if someone gains direct access to the API server).

**Verification questions:**
- In what order, from outside to inside, are the four layers of the 4C's model placed?
- Why is it said that the security of each layer "inherits" the responsibility of the outer layers?

---

## Exercise 2 — RBAC: creating a user with limited permissions

You will create a `ServiceAccount` that can only read Pods in a namespace, and verify its permissions with `kubectl auth can-i`.

1. Create a test namespace:
   ```
   kubectl create namespace security-lab
   ```
2. Create a `ServiceAccount` named `pod-reader-sa`:
   ```
   kubectl create serviceaccount pod-reader-sa -n security-lab
   ```
3. Create a file `role.yaml` with a `Role` that only allows `get` and `list` on `pods`:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: security-lab
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list"]
   ```
   Apply it:
   ```
   kubectl apply -f role.yaml
   ```
4. Create the `RoleBinding` that binds the `ServiceAccount` to the `Role`:
   ```
   kubectl create rolebinding pod-reader-binding \
     --role=pod-reader \
     --serviceaccount=security-lab:pod-reader-sa \
     -n security-lab
   ```
5. Verify permissions using `kubectl auth can-i` impersonating the `ServiceAccount`:
   ```
   kubectl auth can-i list pods \
     --as=system:serviceaccount:security-lab:pod-reader-sa \
     -n security-lab

   kubectl auth can-i delete pods \
     --as=system:serviceaccount:security-lab:pod-reader-sa \
     -n security-lab
   ```

**Verification questions:**
- What did each of the two `kubectl auth can-i` commands in step 5 return, and why do they differ?
- What is the difference between a `Role` and a `ClusterRole`? Which one would you use if you needed to give permissions on `nodes` (a non-namespaced resource)?
- If instead of a `RoleBinding` you had created a `ClusterRoleBinding` pointing to the same `Role`, what would change?

---

## Exercise 3 — Pod Security Admission (Pod Security Standards)

Kubernetes defines three Pod Security Standard levels: `privileged`, `baseline`, and `restricted`. Pod Security Admission applies them via labels on the namespace.

1. Label the `security-lab` namespace to enforce the `restricted` level:
   ```
   kubectl label namespace security-lab \
     pod-security.kubernetes.io/enforce=restricted
   ```
2. Attempt to create a privileged Pod (`privileged.yaml`):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: privileged-pod
     namespace: security-lab
   spec:
     containers:
     - name: app
       image: nginx
       securityContext:
         privileged: true
   ```
   ```
   kubectl apply -f privileged.yaml
   ```
3. Observe the rejection message from the admission controller.
4. Correct the manifest to comply with the `restricted` level (`compliant.yaml`):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: compliant-pod
     namespace: security-lab
   spec:
     containers:
     - name: app
       image: nginx
       securityContext:
         runAsNonRoot: true
         allowPrivilegeEscalation: false
         capabilities:
           drop: ["ALL"]
         seccompProfile:
           type: RuntimeDefault
   ```
   ```
   kubectl apply -f compliant.yaml
   ```

**Verification questions:**
- Which specific field in `privileged.yaml` caused the rejection in step 3?
- Name at least three requirements a Pod must meet to pass the `restricted` level (look at the fields used in `compliant.yaml`).
- What is the difference between the `enforce`, `audit`, and `warn` modes of Pod Security Admission?

---

## Exercise 4 — Isolating traffic between Pods with NetworkPolicy

By default, in Kubernetes all Pods can communicate with each other without restrictions. You will create a `NetworkPolicy` that changes this behavior.

1. Create two test Pods in `security-lab`:
   ```
   kubectl run frontend --image=busybox -n security-lab --labels=role=frontend -- sleep 3600
   kubectl run backend --image=busybox -n security-lab --labels=role=backend -- sleep 3600
   ```
2. Verify that `frontend` can reach `backend` (you should see a timeout or response, not an immediate rejection):
   ```
   kubectl exec -n security-lab frontend -- wget -qO- --timeout=2 backend
   ```
3. Apply a `NetworkPolicy` (`deny-backend.yaml`) that only allows incoming traffic to `backend` from Pods with label `role=frontend`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-only
     namespace: security-lab
   spec:
     podSelector:
       matchLabels:
         role: backend
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             role: frontend
   ```
   ```
   kubectl apply -f deny-backend.yaml
   ```
4. Create a third Pod without the `frontend` label and attempt the same access:
   ```
   kubectl run intruder --image=busybox -n security-lab -- sleep 3600
   kubectl exec -n security-lab intruder -- wget -qO- --timeout=2 backend
   ```

**Verification questions:**
- Why does step 4 behave differently from step 2, if both are requests to the same `backend` Pod?
- A `NetworkPolicy` with `podSelector: {}` and no `ingress` rules — what effect does it have on incoming traffic to the namespace?
- What does the cluster need to have installed for `NetworkPolicy` to actually take effect?

---

## Exercise 5 — Secrets: what they protect and what they don't

Kubernetes `Secret` objects are not encrypted by default: they are only base64-encoded.

1. Create a Secret with a fake credential:
   ```
   kubectl create secret generic db-creds \
     --from-literal=username=admin \
     --from-literal=password=SuperSecreto123 \
     -n security-lab
   ```
2. Retrieve the Secret in YAML format and observe the `data` field:
   ```
   kubectl get secret db-creds -n security-lab -o yaml
   ```
3. Manually decode the `password` value to confirm it is reversible:
   ```
   echo "<value-copied-from-data.password>" | base64 -d
   ```
4. Mount the Secret as environment variables in a Pod (`secret-pod.yaml`):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: secret-consumer
     namespace: security-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sleep", "3600"]
       envFrom:
       - secretRef:
           name: db-creds
   ```
   ```
   kubectl apply -f secret-pod.yaml
   kubectl exec -n security-lab secret-consumer -- env | grep -i password
   ```

**Verification questions:**
- Why does step 3 demonstrate that a Secret is **not** equivalent to "encrypted"?
- Mention at least one additional measure (outside the `Secret` object itself) to protect sensitive credentials in a cluster (think about encryption at rest, an external secrets manager, or RBAC restrictions on the `secrets` resource).
- What risk does exposing a Secret as an environment variable have compared to mounting it as a volume?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- Order from outside to inside: **Cloud → Cluster → Container → Code**.
- Classification:
  - RBAC on the API server → **Cluster**.
  - Image scanning for CVEs → **Container**.
  - Cloud provider firewall/security groups → **Cloud**.
  - Validating inputs of an HTTP endpoint → **Code**.
  - `NetworkPolicy` between namespaces → **Cluster**.
- If the Cluster is not secured (for example, the API server is accessible without authentication), an attacker can create, modify, or delete any resource — including your application — regardless of Code security. Each layer protects the perimeter of the layer it wraps; a breach in an outer layer nullifies the protections of the inner layers.

**Exercise 2**
- `kubectl auth can-i list pods ...` returns `yes` (the `Role` explicitly allows it). `kubectl auth can-i delete pods ...` returns `no`, because the `Role` only grants the verbs `get` and `list`, and RBAC denies everything not explicitly allowed (deny by default model).
- A `Role` applies only within a namespace and can only grant permissions on resources in that namespace. A `ClusterRole` applies at the cluster level and is mandatory for non-namespaced resources, such as `nodes`, `persistentvolumes`, or `namespaces` themselves.
- A `ClusterRoleBinding` would have granted those same permissions (`get`/`list` of pods) in **all** namespaces of the cluster, not just `security-lab` — a much broader scope than intended.

**Exercise 3**
- The field `securityContext.privileged: true` is what causes the rejection: the `restricted` level explicitly forbids privileged containers.
- Requirements visible in `compliant.yaml` (any three of these, among others): `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` (and also a `seccompProfile` must be defined).
- `enforce` rejects creation/update of Pods that violate the standard; `audit` allows the operation but records an entry in the audit log; `warn` allows the operation but returns a warning visible to the user. All three modes can be combined and applied at different levels simultaneously.

**Exercise 4**
- In step 2 there is no `NetworkPolicy` in the namespace, so the default Kubernetes behavior (all traffic allowed) applies and `frontend` reaches `backend`. In step 4 a `NetworkPolicy` already exists that selects `backend` and only allows ingress from Pods with label `role=frontend`; since `intruder` does not have that label, its traffic is blocked.
- A `podSelector: {}` selects **all** Pods in the namespace. If no `ingress` rules are listed, the effect is "deny all ingress" for those Pods — it becomes a total deny policy.
- The cluster needs a **CNI plugin that supports NetworkPolicy** (e.g., Calico, Cilium, or Weave Net). If the CNI does not support it (like the default `kindnet` in `kind` without additional configuration), the `NetworkPolicy` object is created but has no real effect.

**Exercise 5**
- Because `base64` is a reversible encoding without any secret key: anyone with read access to the `Secret` object (or the underlying etcd without encryption at rest) can recover the original plaintext value with a simple `base64 -d`. No cryptographic encryption is involved.
- Additional measures: enable **encryption at rest** for Secrets in etcd, use an **external secrets manager** (Vault, AWS Secrets Manager, etc.) integrated via External Secrets Operator, and restrict with RBAC who can `get`/`list` the `secrets` resource.
- Environment variables are more easily exposed: they appear in `kubectl exec ... env`, in crash dump logs, and can be inherited by child processes of the container. Mounting the Secret as a volume (file) reduces that surface, since the value is only accessible by reading the specific file, and some mechanisms allow rotating it without restarting the Pod.

</details>