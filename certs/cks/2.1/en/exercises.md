# Guided Exercises — CKS 2.1: Use appropriate pod security standards

> **Exam weight:** 5 · **Kubernetes version:** v1.34
> Every step is executable. Run the block, observe the output, then answer the questions before moving on. Answers are collapsed at the end.

---

## Reference table (keep this open while you work)

| Level | What it does |
|---|---|
| `privileged` | Unrestricted. No checks at all. |
| `baseline` | Blocks known privilege escalations: `privileged`, `hostNetwork/hostPID/hostIPC`, host ports, `hostPath`, added capabilities (except `NET_BIND_SERVICE`), `seccompProfile: Unconfined`, unsafe sysctls, `/proc` mount overrides. |
| `restricted` | Baseline **plus**: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault\|Localhost`, and an allow-list of volume types. |

| Mode label | Effect |
|---|---|
| `pod-security.kubernetes.io/enforce` | Rejects the Pod at admission. |
| `pod-security.kubernetes.io/audit` | Allows it, writes an annotation to the audit log. |
| `pod-security.kubernetes.io/warn` | Allows it, returns a warning to the client. |

Each mode has a matching `-version` label (`latest` or `v1.34`).

---

## Exercise 0 — Prepare the environment

```bash
# 0.1 Confirm the server version (PSA is GA since v1.25 and enabled by default)
kubectl version

# 0.2 Working directory
mkdir -p ~/cks-2.1 && cd ~/cks-2.1

# 0.3 See which namespaces already carry PSA labels
kubectl get ns -L pod-security.kubernetes.io/enforce \
               -L pod-security.kubernetes.io/warn \
               -L pod-security.kubernetes.io/audit
```

**Check your understanding**

1. **Q1.** In step 0.3, most (or all) namespaces show empty columns. What policy level effectively applies to a namespace with no PSA labels at all on a default cluster?
2. **Q2.** `kube-system` is normally labelled `pod-security.kubernetes.io/enforce=privileged` by kubeadm, or left unlabelled. Why is it a bad idea to enforce `restricted` there?

---

## Exercise 1 — Prove the admission plugin is active

```bash
# 1.1 Create a scratch namespace
kubectl create namespace psa-lab

# 1.2 Turn on warn-only mode at the strictest level (nothing is blocked yet)
kubectl label namespace psa-lab \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest

# 1.3 Write a deliberately sloppy Pod
cat > sloppy-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: sloppy
spec:
  containers:
  - name: app
    image: nginx:1.27
EOF

# 1.4 Create it and read the client output carefully
kubectl -n psa-lab apply -f sloppy-pod.yaml

# 1.5 Confirm the Pod actually exists
kubectl -n psa-lab get pod sloppy
```

Expected shape of the output in 1.4:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false
(container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted
capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to
"RuntimeDefault" or "Localhost")
pod/sloppy created
```

**Check your understanding**

3. **Q3.** The Pod was created despite four violations. Which of the three modes produced that message, and which one would have stopped the creation?
4. **Q4.** A plain `nginx:1.27` Pod with no `securityContext` — does it violate `baseline`? Justify using the violation list above.
5. **Q5.** Where does the `audit` mode write its findings, and why is that mode useless on a cluster whose API server has no audit policy configured?

---

## Exercise 2 — Enforce `baseline` and watch a rejection

```bash
# 2.1 Add enforcement at baseline, pinned to the cluster version
kubectl label namespace psa-lab --overwrite \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=v1.34

# 2.2 A Pod that baseline must reject
cat > privileged-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: breaker
spec:
  hostNetwork: true
  containers:
  - name: app
    image: nginx:1.27
    securityContext:
      privileged: true
      capabilities:
        add: ["SYS_ADMIN"]
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
EOF

kubectl -n psa-lab apply -f privileged-pod.yaml

# 2.3 The already-running "sloppy" Pod is still there
kubectl -n psa-lab get pods
```

**Check your understanding**

6. **Q6.** List every distinct `baseline` control that the `breaker` Pod violates.
7. **Q7.** The `sloppy` Pod from Exercise 1 stays `Running` even though enforcement is now on. Explain the mechanism, and say what would happen if the node it runs on were drained.
8. **Q8.** You still see a `Warning:` line about `restricted` when you create compliant Pods. Why?

---

## Exercise 3 — Make a Pod `restricted`-compliant

```bash
# 3.1 Raise enforcement to restricted
kubectl label namespace psa-lab --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.34

# 3.2 Delete the legacy Pod so the namespace is consistent
kubectl -n psa-lab delete pod sloppy

# 3.3 Recreate it — now it must fail
kubectl -n psa-lab apply -f sloppy-pod.yaml

# 3.4 Fix it, field by field
cat > hardened-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hardened
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: scratch
      mountPath: /tmp
  volumes:
  - name: scratch
    emptyDir: {}
EOF

kubectl -n psa-lab apply -f hardened-pod.yaml
kubectl -n psa-lab get pod hardened
```

```bash
# 3.5 Prove the runtime posture from inside the container
kubectl -n psa-lab exec hardened -- id
kubectl -n psa-lab exec hardened -- cat /proc/1/status | grep -i cap
```

**Check your understanding**

9. **Q9.** In 3.4, four security fields live at Pod level and two at container level. Which of them **must** be set per container and cannot be inherited from the Pod?
10. **Q10.** You removed `runAsUser: 10001` but kept `runAsNonRoot: true`. Does the Pod still pass `restricted` admission? Does it still start?
11. **Q11.** `restricted` does **not** require `readOnlyRootFilesystem: true`. Is that field part of any Pod Security Standard? Should you set it anyway?
12. **Q12.** The `emptyDir` volume was accepted. Name three volume types that `restricted` (v1.25+) rejects but that `baseline` allows.

---

## Exercise 4 — Where the error hides when you use a Deployment

```bash
# 4.1 Deploy a non-compliant workload through a controller
kubectl -n psa-lab create deployment web --image=nginx:1.27

# 4.2 Look at the objects
kubectl -n psa-lab get deploy,rs,pods

# 4.3 Find the real error
kubectl -n psa-lab describe rs -l app=web | tail -20
kubectl -n psa-lab get events --sort-by=.lastTimestamp | tail -10
```

**Check your understanding**

13. **Q13.** The Deployment was created successfully but reports `0/1` ready. Which controller hit the admission denial, and under which ServiceAccount identity was the Pod request made?
14. **Q14.** `kubectl create deployment` printed a `Warning:` line. Which PSA mode generated it, and why does `enforce` **not** reject the Deployment object itself?
15. **Q15.** In an exam task you are told "the app does not start after hardening the namespace." Write the two commands you would run first.

---

## Exercise 5 — Evaluate before you enforce (server-side dry run)

```bash
# 5.1 Build a namespace with pre-existing, non-compliant workloads
kubectl create namespace legacy
kubectl -n legacy run nginx --image=nginx:1.27
kubectl -n legacy run tools --image=busybox:1.36 --command -- sleep 3600
kubectl -n legacy get pods

# 5.2 Ask the API server what WOULD break, without changing anything
kubectl label --dry-run=server --overwrite namespace legacy \
  pod-security.kubernetes.io/enforce=restricted

# 5.3 Confirm nothing changed
kubectl get namespace legacy -o jsonpath='{.metadata.labels}' ; echo

# 5.4 The safe rollout order
kubectl label namespace legacy --overwrite \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

Expected shape of 5.2:

```
Warning: existing pods in namespace "legacy" violate the new PodSecurity enforce level "restricted:latest"
Warning: nginx: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
Warning: tools: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/legacy labeled (server dry run)
```

**Check your understanding**

16. **Q16.** Why does `--dry-run=server` surface these warnings while `--dry-run=client` cannot?
17. **Q17.** Describe the four-step migration sequence you would use to move a busy production namespace from unlabelled to `enforce=restricted` with zero outage.
18. **Q18.** Write a one-liner that lists every namespace in the cluster **without** an `enforce` label.

---

## Exercise 6 — Pin the version, and see why it matters

```bash
# 6.1 Namespace pinned to an older policy revision
kubectl create namespace pinned
kubectl label namespace pinned \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.24

# 6.2 Same thing, unpinned
kubectl create namespace unpinned
kubectl label namespace unpinned \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

# 6.3 A compliant Pod that also mounts an NFS volume
cat > nfs-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nfs-user
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: share
      mountPath: /data
  volumes:
  - name: share
    nfs:
      server: 10.0.0.99
      path: /exports
EOF

kubectl -n pinned   apply -f nfs-pod.yaml
kubectl -n unpinned apply -f nfs-pod.yaml
```

Record the exact result of each of the two `apply` commands.

**Check your understanding**

19. **Q19.** The two namespaces both say `restricted`, yet the admission outcome differs. Which control accounts for the difference, and in which Kubernetes version was it added?
20. **Q20.** What is the operational argument **for** pinning `enforce-version` to `v1.34`, and what is the argument **against**?
21. **Q21.** What happens if you set `enforce-version` to a version newer than the API server, e.g. `v1.99`?

---

## Exercise 7 — Cluster-wide defaults with `AdmissionConfiguration`

> Run this on a kubeadm control-plane node. A typo here stops the API server — read step 7.5 before you start.

```bash
# 7.1 Create the PodSecurity plugin configuration
sudo mkdir -p /etc/kubernetes/admission
sudo tee /etc/kubernetes/admission/pod-security.yaml >/dev/null <<'EOF'
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "baseline"
  enforce-version: "v1.34"
  audit: "restricted"
  audit-version: "v1.34"
  warn: "restricted"
  warn-version: "v1.34"
exemptions:
  usernames: []
  runtimeClasses: []
  namespaces: ["kube-system"]
EOF

# 7.2 Point the AdmissionConfiguration at it
sudo tee /etc/kubernetes/admission/admission-config.yaml >/dev/null <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  path: /etc/kubernetes/admission/pod-security.yaml
EOF
```

```bash
# 7.3 Back up the static Pod manifest FIRST
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak

# 7.4 Edit the manifest
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Add to `spec.containers[0].command`:

```yaml
    - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
```

Add to `spec.containers[0].volumeMounts`:

```yaml
    - name: admission-config
      mountPath: /etc/kubernetes/admission
      readOnly: true
```

Add to `spec.volumes`:

```yaml
  - name: admission-config
    hostPath:
      path: /etc/kubernetes/admission
      type: DirectoryOrCreate
```

```bash
# 7.5 Watch the API server come back (this takes 30-90 seconds)
sudo crictl ps | grep kube-apiserver
kubectl get --raw='/healthz' ; echo
# If it never returns: sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)
# Recovery: sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml

# 7.6 Test the new cluster-wide default on a brand-new, unlabelled namespace
kubectl create namespace defaults-test
kubectl -n defaults-test apply -f privileged-pod.yaml     # expect: rejected
kubectl -n defaults-test apply -f sloppy-pod.yaml         # expect: warning, then created
```

**Check your understanding**

22. **Q22.** Namespace `psa-lab` carries `enforce=restricted`; the cluster default is now `enforce=baseline`. Which one wins for a Pod created in `psa-lab`?
23. **Q23.** Why is `--admission-control-config-file` mounted `readOnly: true`, and why must the volume be a `hostPath` rather than a ConfigMap?
24. **Q24.** The API server enters a crash loop after your edit. Which log do you read, and how do you roll back without a working `kubectl`?
25. **Q25.** What is the practical difference between the `defaults:` block here and simply labelling every namespace?

---

## Exercise 8 — Exemptions, and the hole they open

```bash
# 8.1 A namespace for a workload that genuinely needs host access
kubectl create namespace node-agents
kubectl label namespace node-agents \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=baseline

# 8.2 The privileged Pod is now accepted here
kubectl -n node-agents apply -f privileged-pod.yaml
kubectl -n node-agents get pod breaker
```

```bash
# 8.3 Close the hole with RBAC — nobody but the agent's SA may create Pods here
kubectl -n node-agents create serviceaccount node-agent

cat > agent-rbac.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: node-agents
  name: pod-creator
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["create", "get", "list", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: node-agents
  name: pod-creator
subjects:
- kind: ServiceAccount
  name: node-agent
  namespace: node-agents
roleRef:
  kind: Role
  name: pod-creator
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f agent-rbac.yaml

# 8.4 Verify with auth can-i
kubectl auth can-i create pods -n node-agents \
  --as=system:serviceaccount:node-agents:node-agent
kubectl auth can-i create pods -n node-agents \
  --as=system:serviceaccount:default:default
```

**Check your understanding**

26. **Q26.** `exemptions.usernames: ["system:serviceaccount:ci:deployer"]` in the API server config — in which namespaces does that exemption apply?
27. **Q27.** Why is a `privileged` **namespace** (Exercise 8.1) generally safer than a `usernames` or `runtimeClasses` exemption in the admission config?
28. **Q28.** PSA is namespace-scoped and level-based. Name two concrete requirements it **cannot** express, and the class of tool you would reach for instead.
29. **Q29.** Pod Security Policy was removed in v1.25. Name two capabilities PSP had that PSA deliberately dropped.

---

## Exercise 9 — Cleanup

```bash
kubectl delete namespace psa-lab legacy pinned unpinned defaults-test node-agents
# Optional: revert the API server change
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl get --raw='/healthz' ; echo
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A1.** `privileged` — the absence of labels means no policy is applied. PSA is fail-open by design: an unlabelled namespace is completely unrestricted. This is why "the cluster has PSA enabled" says nothing about whether it is actually protecting anything. On a hardened cluster you either label every namespace or set a cluster-wide default via `AdmissionConfiguration` (Exercise 7).

**A2.** The control-plane and node components running in `kube-system` legitimately need host access: `kube-proxy` needs `hostNetwork` and `NET_ADMIN`, CNI agents need `hostPath` mounts and `privileged`, CSI drivers need bidirectional mount propagation. Enforcing `restricted` there would block their Pods from being recreated, and you would lose cluster networking on the next node reboot or DaemonSet rollout. `kube-system` is the canonical exemption.

---

### Exercise 1

**A3.** `warn` produced it — the wording `would violate` is the giveaway. `enforce` would have rejected the request with `Error from server (Forbidden)`. `warn` and `audit` never block.

**A4.** No. A bare `nginx:1.27` Pod satisfies `baseline` — it is not privileged, adds no capabilities, uses no host namespaces, no host ports, no `hostPath`. All four violations reported are `restricted`-only controls (`allowPrivilegeEscalation`, `capabilities.drop`, `runAsNonRoot`, `seccompProfile`). Note that `baseline` allows running as UID 0 inside the container — that is precisely the gap `restricted` closes.

**A5.** `audit` adds an `pod-security.kubernetes.io/audit-violations` annotation to the **API server audit event** for that request. If no `--audit-policy-file` / `--audit-log-path` is configured, the event is never written anywhere and the mode is silently a no-op. `warn` is the mode that gives immediate, visible feedback to the person running `kubectl`.

---

### Exercise 2

**A6.** Four:
- `hostNetwork: true` → Host Namespaces control
- `securityContext.privileged: true` → Privileged Containers control
- `capabilities.add: ["SYS_ADMIN"]` → Capabilities control (only `NET_BIND_SERVICE` may be added)
- `hostPath` volume → HostPath Volumes control

**A7.** PSA is a **validating admission** controller: it only runs on `CREATE` and `UPDATE` requests for Pods. It has no reconciliation loop and never evicts anything, so already-admitted Pods survive a label change untouched. If the node were drained, the Pod would be deleted and — if owned by a controller — recreated, and *that* creation request would be evaluated and rejected. This is the classic "it worked until the node rebooted" failure.

**A8.** Because the namespace now carries two independent labels: `enforce=baseline` and `warn=restricted` (set in step 1.2). The modes are evaluated independently, so you get blocking at `baseline` and advisory feedback at `restricted`. This combination — enforce one level down, warn one level up — is the recommended production pattern.

---

### Exercise 3

**A9.** `allowPrivilegeEscalation: false` and `capabilities.drop: ["ALL"]` are **container-level only**; there is no Pod-level equivalent, so they must be repeated on every container, including `initContainers` and `ephemeralContainers`. `runAsNonRoot`, `runAsUser`, `runAsGroup`, `fsGroup` and `seccompProfile` exist at Pod level and are inherited by containers that do not override them.

**A10.** Admission still passes — `restricted` requires `runAsNonRoot: true` to be set (or `runAsUser` to be non-zero); it does not require `runAsUser` to be present. Whether it *starts* depends on the image: the kubelet resolves the image's `USER` directive at container start and fails the Pod with `CreateContainerConfigError: container has runAsNonRoot and image will run as root` if it resolves to UID 0. `busybox:1.36` runs as root, so it would fail at runtime. This is the key distinction: **PSA validates the manifest, the kubelet validates the running identity.**

**A11.** No — `readOnlyRootFilesystem` is not part of `baseline` or `restricted` at any version. It is a widely recommended hardening measure that PSA simply does not cover, which is a good illustration of the ceiling of level-based policy. Set it wherever the workload tolerates it, backed by `emptyDir` mounts for `/tmp` and any writable paths, but expect to enforce it with a policy engine rather than PSA.

**A12.** `restricted` (v1.25+) allows only: `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret`. So `nfs`, `iscsi`, `cephfs`, `fc`, `rbd`, and `glusterfs` are all accepted by `baseline` and rejected by `restricted`. Note the intent: in-tree network volumes are replaced by `persistentVolumeClaim`, which routes the same storage through a PV the cluster admin controls.

---

### Exercise 4

**A13.** The **ReplicaSet controller** hit it. The Pod creation request was made by `system:serviceaccount:kube-system:replicaset-controller`, not by your user. This matters for `exemptions.usernames`: exempting *your* username would not help here, because you are not the identity creating the Pod.

**A14.** `warn` generated it. `warn` and `audit` evaluate **Pod templates** embedded in workload resources (Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet, ReplicationController, PodTemplate), which is why you get feedback at `kubectl apply` time. `enforce` deliberately evaluates **Pods only** — enforcing on templates would create version-skew problems and would double-report the same violation. The practical consequence is that a `warn` label is what makes `enforce` usable with controllers.

**A15.**
```bash
kubectl -n <ns> describe rs -l app=<app>          # FailedCreate event with the violation text
kubectl get ns <ns> -o jsonpath='{.metadata.labels}'   # which level is enforced
```
Then reconcile the Pod template's `securityContext` against the reported violations.

---

### Exercise 5

**A16.** `--dry-run=server` sends the request to the API server with `dryRun=All`; the request goes through the full admission chain, so the PodSecurity plugin runs its namespace-label-change hook, which enumerates the **existing Pods** in that namespace and evaluates them against the proposed level. Nothing is persisted to etcd. `--dry-run=client` never contacts the API server for validation, so it has no access to the running Pods and no admission plugin executes.

**A17.**
1. `kubectl label --dry-run=server ... enforce=restricted` to get the impact list.
2. Apply `warn=restricted` and `audit=restricted` only; leave `enforce` off. Collect violations over a full deployment cycle.
3. Fix the Pod templates (`securityContext` on every container plus the Pod), redeploy, confirm the warnings stop.
4. Apply `enforce=restricted` with a pinned `enforce-version`. Optionally step through `enforce=baseline` first for a large legacy namespace.

**A18.**
```bash
kubectl get ns -o json | jq -r '.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"] == null) | .metadata.name'
```
Without `jq`, the readable equivalent is `kubectl get ns -L pod-security.kubernetes.io/enforce` and scan for blank cells.

---

### Exercise 6

**A19.** The **Volume Types** control. `restricted` gained its explicit volume allow-list in **v1.25**. Pinned to `restricted:v1.24` the `nfs` volume is evaluated only against `baseline`'s rules (which forbid `hostPath` but permit `nfs`), so the Pod is admitted. At `restricted:latest` (= v1.34) `nfs` is not on the allow-list and the Pod is rejected. Everything else in the manifest already satisfies both revisions.

**A20.** **For pinning:** the policy definitions themselves evolve between minor releases. Pinning guarantees that upgrading the cluster from v1.34 to v1.35 cannot suddenly reject workloads that were compliant yesterday — you decide when to adopt the new rules by bumping the label. It also keeps behaviour identical across a control plane mid-upgrade. **Against pinning:** you silently miss new protections, and pinned versions rot; `latest` means you always get the current hardening. The usual compromise is to pin `enforce-version` and leave `warn`/`audit` at `latest`, so new rules show up as warnings before they can ever block.

**A21.** The label is accepted (namespace labels are not rejected for this), but the API server emits a warning that the version is unknown and **falls back to `latest`** for evaluation. It fails closed, not open — you get the current, strictest interpretation rather than no policy. Check with `kubectl describe ns <name>` and by watching for the warning on the `kubectl label` call.

---

### Exercise 7

**A22.** The **namespace labels win**. The `defaults:` block in `PodSecurityConfiguration` only supplies values for modes that the namespace does not specify. `psa-lab` sets `enforce=restricted`, so `restricted` applies for enforcement there; its `audit`/`warn` values would still come from the namespace labels you set earlier, and any mode left unset on the namespace falls back to the cluster default. Precedence order: exemption > namespace label > cluster default.

**A23.** `readOnly: true` because the API server only needs to parse the file at startup; a writable mount would let anything that compromises the API server container weaken its own admission policy. It must be a `hostPath` because `kube-apiserver` is a **static Pod** managed directly by the kubelet — it starts before (and independently of) the API server, so no ConfigMap can be resolved at that point. Same reason `--audit-policy-file` and the encryption-at-rest config are host files.

**A24.**
```bash
sudo crictl ps -a --name kube-apiserver          # find the exited container
sudo crictl logs <container-id>
# or, if the container never starts:
sudo journalctl -u kubelet -f
```
Typical causes: YAML indentation error in the manifest, a path in `--admission-control-config-file` that is not inside the mounted directory, or a wrong `apiVersion` in `pod-security.yaml`. Roll back with the backup — the kubelet watches `/etc/kubernetes/manifests` and restarts the static Pod automatically, no `kubectl` required:
```bash
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

**A25.** The cluster default is **fail-closed for new namespaces**. Any namespace created afterwards — by a user, by a CI pipeline, by an operator — is protected from the moment it exists. Labelling namespaces individually is fail-open: every new namespace is `privileged` until somebody remembers to label it, which is exactly the gap an attacker with namespace-create permission uses. Best practice is both: a cluster-wide `baseline` (or `restricted`) default, plus explicit per-namespace labels where a different level is needed.

---

### Exercise 8

**A26.** In **all** namespaces, unconditionally. Username exemptions are evaluated before namespace labels, so that ServiceAccount can create a `privileged` Pod in a namespace labelled `enforce=restricted` and PSA will not object. This is why username exemptions are the most dangerous of the three — combined with an over-permissive CI ServiceAccount, they nullify PSA cluster-wide.

**A27.** Because a `privileged` namespace is still a **PSA-evaluated** boundary that you can scope with the tools you already have: RBAC controls who may create Pods in it, ResourceQuota limits how many, NetworkPolicy limits what they reach, and its name shows up in `kubectl get ns -L pod-security.kubernetes.io/enforce` during any audit. A `usernames` or `runtimeClasses` exemption is invisible from the cluster API — it lives only in a file on the control-plane node — and it applies everywhere. Keep the exemption list empty except for `kube-system`, and express "this workload needs host access" as a dedicated, RBAC-locked namespace.

**A28.** Examples PSA cannot express: require `readOnlyRootFilesystem: true`; restrict images to a specific registry; require a `runAsUser` within a given UID range; forbid `latest` image tags; require resource limits; require specific labels or annotations. PSA has exactly three fixed levels and no way to add, remove, or parameterise a rule. For any of these you need a general-purpose policy engine — **Kyverno** or **OPA Gatekeeper** — running as a `ValidatingAdmissionWebhook`, or Kubernetes-native **ValidatingAdmissionPolicy** (CEL-based, GA since v1.30) for rules you can express without an external controller.

**A29.** PSP could **mutate** requests — it would inject defaults such as `runAsUser`, `fsGroup`, or drop capabilities into Pods that omitted them. PSA is purely validating: it rejects or allows, never rewrites. PSP was also bound **per-user via RBAC** (`use` verb on a `podsecuritypolicy` resource), which allowed different policies for different identities in the same namespace; PSA's scope is the namespace, not the requester. PSP's ordering behaviour when multiple policies matched was the main source of its unpredictability, and dropping mutation is what makes PSA's outcome deterministic.

</details>

---

## Sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes documentation, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes documentation, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes documentation, *Enforce Pod Security Standards with Namespace Labels* — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Kubernetes documentation, *Enforce Pod Security Standards by Configuring the Built-in Admission Controller* — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Kubernetes documentation, *Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller* — https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/
- Kubernetes documentation, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes documentation, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/