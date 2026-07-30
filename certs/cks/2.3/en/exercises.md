# CKS v1.34 — Topic 2.3: Understand and Implement Isolation Techniques

## Guided Exercises

**Exam weight:** 5%
**Estimated time:** 150–180 minutes
**Difficulty:** intermediate → advanced

---

### Objectives

By the end of these exercises you will be able to:

- Build a reusable "tenant baseline" that combines Namespace, Pod Security Admission, ResourceQuota, LimitRange and ServiceAccount hygiene.
- Scope RBAC so a tenant cannot read or mutate anything outside their Namespace, and prove it with `kubectl auth can-i`.
- Enforce network isolation between tenants with default-deny NetworkPolicies, plus controlled DNS and cloud-metadata egress.
- Pin tenant workloads to dedicated nodes using taints, tolerations and node labels that a compromised kubelet cannot forge.
- Install and use a sandboxed runtime (gVisor / `runsc`) through a RuntimeClass, and verify from inside the Pod that the kernel surface really changed.
- Read and validate a Kata Containers RuntimeClass, including the `overhead` field.
- Reduce shared-kernel exposure with user namespaces (`hostUsers: false`) and by rejecting host-namespace/hostPath Pods.
- Force a sandboxed runtime for an entire Namespace with a ValidatingAdmissionPolicy.
- Audit an existing Namespace and list its isolation gaps under exam time pressure.

---

### Lab prerequisites

| Requirement | Detail |
|---|---|
| Cluster | 2 nodes minimum (`controlplane` + `node01`), Kubernetes v1.33/v1.34 |
| CNI | A policy-enforcing CNI (Cilium, Calico, Antrea). `kubectl get pods -n kube-system` should show one of them |
| Runtime | containerd (v1.7 or v2.x), with root/sudo on `node01` |
| Tools | `kubectl`, `jq`, `openssl`, `wget`/`curl` on the node |
| Optional | Nested virtualisation (`grep -Eqc '(vmx|svm)' /proc/cpuinfo`) for the Kata block |

> If your CNI does **not** enforce NetworkPolicy (e.g. plain Flannel), the policy objects will be created and will look correct, but traffic will not be blocked. Verify support before blaming your YAML — this is a classic exam trap.

Work directory:

```bash
mkdir -p ~/cks/2.3 && cd ~/cks/2.3
kubectl version --short
kubectl get nodes -o wide
```

---

## Exercise 1 — The tenant baseline: Namespace, PSA, quotas, limits

A Namespace by itself is a naming boundary, **not** a security boundary. In this exercise you turn a bare Namespace into a soft-multi-tenancy unit.

### Steps

1. Create two tenant Namespaces and label them so Pod Security Admission enforces the `restricted` profile:

   ```bash
   kubectl create namespace tenant-blue
   kubectl create namespace tenant-green

   for ns in tenant-blue tenant-green; do
     kubectl label namespace $ns \
       pod-security.kubernetes.io/enforce=restricted \
       pod-security.kubernetes.io/enforce-version=v1.34 \
       pod-security.kubernetes.io/audit=restricted \
       pod-security.kubernetes.io/warn=restricted \
       tenant=$ns --overwrite
   done
   ```

2. Confirm the labels landed, including the automatic Namespace name label:

   ```bash
   kubectl get ns tenant-blue -o jsonpath='{.metadata.labels}' | jq
   ```

3. Try to run a Pod that violates the `restricted` profile:

   ```bash
   kubectl -n tenant-blue run bad --image=nginx:1.27 --restart=Never
   ```

   Read the rejection message carefully — it lists every field that failed.

4. Now run a Pod that satisfies `restricted`:

   ```bash
   cat <<'EOF' > 01-good-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: good
     namespace: tenant-blue
     labels:
       app: good
   spec:
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       seccompProfile:
         type: RuntimeDefault
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh","-c","sleep 3600"]
       securityContext:
         allowPrivilegeEscalation: false
         capabilities:
           drop: ["ALL"]
       resources:
         requests: {cpu: "50m", memory: "32Mi"}
         limits:   {cpu: "100m", memory: "64Mi"}
   EOF
   kubectl apply -f 01-good-pod.yaml
   kubectl -n tenant-blue get pod good
   ```

5. Cap what the tenant can consume, so one tenant cannot starve another:

   ```bash
   cat <<'EOF' > 01-quota.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tenant-quota
     namespace: tenant-blue
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 2Gi
       limits.cpu: "4"
       limits.memory: 4Gi
       pods: "10"
       count/services.loadbalancers: "0"
       count/services.nodeports: "0"
       persistentvolumeclaims: "4"
   ---
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: tenant-limits
     namespace: tenant-blue
   spec:
     limits:
     - type: Container
       default:        {cpu: "200m", memory: 128Mi}
       defaultRequest: {cpu: "50m",  memory: 64Mi}
       max:            {cpu: "1",    memory: 1Gi}
   EOF
   kubectl apply -f 01-quota.yaml
   kubectl -n tenant-blue describe quota tenant-quota
   ```

6. Prove the NodePort restriction works:

   ```bash
   kubectl -n tenant-blue expose pod good --type=NodePort --port=80 --name=leak
   ```

7. Check the default ServiceAccount in the Namespace and disable token automounting globally for the tenant:

   ```bash
   kubectl -n tenant-blue get sa default -o yaml | head -20
   kubectl -n tenant-blue patch sa default \
     -p '{"automountServiceAccountToken": false}'
   ```

### Comprehension check

**Q1.** Give two concrete reasons why a Namespace alone is not a security boundary.

**Q2.** In step 1 you set `enforce`, `audit` and `warn`. What is the practical difference between `enforce=restricted` and `audit=restricted` when a violating Pod is submitted?

**Q3.** Why does `pod-security.kubernetes.io/enforce-version=v1.34` matter? What breaks if you omit it and later upgrade the cluster?

**Q4.** Pod Security Admission ignored the Deployment in a hypothetical `restricted` Namespace but blocked its Pods, leaving `ReplicaSet` events full of failures. Why does PSA behave that way, and where do you look for the error?

**Q5.** Which of the two objects in step 5 (`ResourceQuota` or `LimitRange`) prevents a *single* container from requesting 8 CPUs, and which prevents the *sum* of the Namespace from exceeding 2 CPUs?

**Q6.** How does `count/services.nodeports: "0"` contribute to *isolation* rather than just cost control?

**Q7.** `automountServiceAccountToken: false` appears both on the Pod (step 4) and on the ServiceAccount (step 7). If they disagree, which one wins?

---

## Exercise 2 — RBAC scoping: keep the tenant inside their Namespace

### Steps

1. Create a ServiceAccount that represents the tenant's CI robot:

   ```bash
   kubectl -n tenant-blue create serviceaccount blue-ci
   ```

2. Grant it a namespaced Role only — deliberately no ClusterRoleBinding:

   ```bash
   cat <<'EOF' > 02-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: blue-app-manager
     namespace: tenant-blue
   rules:
   - apiGroups: [""]
     resources: ["pods", "services", "configmaps"]
     verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
   - apiGroups: ["apps"]
     resources: ["deployments", "replicasets"]
     verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: blue-app-manager
     namespace: tenant-blue
   subjects:
   - kind: ServiceAccount
     name: blue-ci
     namespace: tenant-blue
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: blue-app-manager
   EOF
   kubectl apply -f 02-rbac.yaml
   ```

3. Test the boundary from both sides using impersonation:

   ```bash
   SA=system:serviceaccount:tenant-blue:blue-ci

   kubectl auth can-i create pods            -n tenant-blue  --as=$SA
   kubectl auth can-i create pods            -n tenant-green --as=$SA
   kubectl auth can-i list   secrets         -n tenant-blue  --as=$SA
   kubectl auth can-i list   nodes           --as=$SA
   kubectl auth can-i get    namespaces      --as=$SA
   kubectl auth can-i '*' '*' --all-namespaces --as=$SA
   ```

4. Dump the full effective permission list — this is the fastest audit command to memorise:

   ```bash
   kubectl auth can-i --list -n tenant-blue --as=$SA
   ```

5. Now introduce a realistic mistake and observe the blast radius:

   ```bash
   kubectl create clusterrolebinding oops \
     --clusterrole=view --serviceaccount=tenant-blue:blue-ci

   kubectl auth can-i list secrets -n tenant-green --as=$SA
   kubectl auth can-i list pods    -n kube-system  --as=$SA
   ```

6. Remove the mistake and re-verify:

   ```bash
   kubectl delete clusterrolebinding oops
   kubectl auth can-i list pods -n kube-system --as=$SA
   ```

7. Find every cluster-wide binding that could break tenant isolation:

   ```bash
   kubectl get clusterrolebindings -o json \
     | jq -r '.items[] | select(.roleRef.name=="cluster-admin" or .roleRef.name=="edit" or .roleRef.name=="view")
              | "\(.metadata.name)\t\(.roleRef.name)\t\([.subjects[]?|"\(.kind):\(.namespace // "-"):\(.name)"]|join(","))"'
   ```

### Comprehension check

**Q8.** Why did the `ClusterRoleBinding` in step 5 grant `view` on `tenant-green` even though the ServiceAccount lives in `tenant-blue`?

**Q9.** What is the difference in scope between binding a **ClusterRole** with a **RoleBinding** versus with a **ClusterRoleBinding**? Which one would you use to reuse the built-in `view` role for a single tenant?

**Q10.** The Role in step 2 grants `create pods`. Explain how that alone can be escalated to node-level compromise if the rest of this topic's controls are missing, and name two controls from Exercise 1 that stop it.

**Q11.** Why is `kubectl auth can-i --list --as=<subject>` more reliable than reading Role YAML by hand during the exam?

**Q12.** The tenant asks to `list secrets` in their own Namespace. Why is granting `get`/`list` on Secrets across the whole Namespace still risky even though it is namespaced, and what is a tighter alternative?

---

## Exercise 3 — Network isolation between tenants

### Steps

1. Deploy a target and a client in each tenant:

   ```bash
   for ns in tenant-blue tenant-green; do
     kubectl -n $ns create deployment web --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
       -- /agnhost netexec --http-port=8080
     kubectl -n $ns expose deployment web --port=8080
   done
   kubectl -n tenant-blue rollout status deploy/web
   kubectl -n tenant-green rollout status deploy/web
   ```

2. Confirm that, by default, **everything can talk to everything**:

   ```bash
   kubectl -n tenant-blue run probe --rm -it --image=busybox:1.36 --restart=Never -- \
     sh -c 'wget -qO- --timeout=3 http://web.tenant-green:8080/hostname; echo; \
            wget -qO- --timeout=3 http://web.tenant-blue:8080/hostname'
   ```

3. Apply a default-deny policy for both directions in `tenant-blue`:

   ```bash
   cat <<'EOF' > 03-default-deny.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: tenant-blue
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
   EOF
   kubectl apply -f 03-default-deny.yaml
   ```

4. Observe that the tenant is now fully cut off — including DNS:

   ```bash
   kubectl -n tenant-blue run probe --rm -it --image=busybox:1.36 --restart=Never -- \
     sh -c 'nslookup web.tenant-blue 2>&1 | tail -3'
   ```

5. Re-open only what the tenant legitimately needs: DNS, and intra-Namespace traffic:

   ```bash
   cat <<'EOF' > 03-allow-baseline.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns
     namespace: tenant-blue
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
     egress:
     - to:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: kube-system
         podSelector:
           matchLabels:
             k8s-app: kube-dns
       ports:
       - {protocol: UDP, port: 53}
       - {protocol: TCP, port: 53}
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-same-namespace
     namespace: tenant-blue
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
     ingress:
     - from:
       - podSelector: {}
     egress:
     - to:
       - podSelector: {}
   EOF
   kubectl apply -f 03-allow-baseline.yaml
   ```

6. Re-run the cross-tenant test and the intra-tenant test:

   ```bash
   kubectl -n tenant-blue run probe --rm -it --image=busybox:1.36 --restart=Never -- \
     sh -c 'echo -n "blue->blue:  "; wget -qO- --timeout=3 http://web.tenant-blue:8080/hostname || echo BLOCKED; \
            echo -n "blue->green: "; wget -qO- --timeout=3 http://web.tenant-green:8080/hostname || echo BLOCKED'
   ```

7. Block the cloud instance-metadata endpoint, a classic node-credential escape path, while allowing general internet egress for one labelled app:

   ```bash
   cat <<'EOF' > 03-egress-external.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-external-except-metadata
     namespace: tenant-blue
   spec:
     podSelector:
       matchLabels:
         egress: internet
     policyTypes: ["Egress"]
     egress:
     - to:
       - ipBlock:
           cidr: 0.0.0.0/0
           except:
           - 169.254.169.254/32
           - 10.0.0.0/8
           - 172.16.0.0/12
           - 192.168.0.0/16
       ports:
       - {protocol: TCP, port: 443}
   EOF
   kubectl apply -f 03-egress-external.yaml
   kubectl -n tenant-blue get netpol
   ```

8. Verify the metadata block:

   ```bash
   kubectl -n tenant-blue run meta --rm -it --labels=egress=internet \
     --image=busybox:1.36 --restart=Never -- \
     sh -c 'wget -qO- --timeout=3 http://169.254.169.254/latest/meta-data/ || echo BLOCKED'
   ```

### Comprehension check

**Q13.** The manifest in step 3 has an empty `spec` apart from `podSelector: {}` and `policyTypes`. Why does that deny traffic instead of allowing it?

**Q14.** After step 3, DNS broke. Explain the exact mechanism — why does an *egress* policy affect name resolution?

**Q15.** In step 5, `allow-dns` and `allow-same-namespace` are separate objects, both selecting all Pods. How does Kubernetes combine multiple NetworkPolicies that select the same Pod — union or intersection?

**Q16.** In `allow-dns`, the `namespaceSelector` and `podSelector` are two keys under a *single* list item. What would change if you put them as two separate list items (each with its own `-`)?

**Q17.** Where does the label `kubernetes.io/metadata.name` come from, and why is it safer to rely on than a hand-applied `name:` label?

**Q18.** Why is `except: 169.254.169.254/32` inside an `ipBlock` not sufficient by itself to guarantee the tenant cannot reach the metadata service? Name two ways the block can be bypassed.

**Q19.** A tenant Pod uses `hostNetwork: true`. What happens to the NetworkPolicies you just wrote, and which control from Exercise 1 prevents this?

---

## Exercise 4 — Node-level isolation with taints, tolerations and trusted labels

### Steps

1. Dedicate `node01` to `tenant-blue`:

   ```bash
   kubectl taint node node01 tenant=blue:NoExecute
   kubectl label node node01 node-restriction.kubernetes.io/tenant=blue
   kubectl describe node node01 | grep -A3 -E 'Taints|Labels'
   ```

2. Show that an untolerating Pod cannot land there:

   ```bash
   kubectl -n tenant-green run stray --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"nodeSelector":{"node-restriction.kubernetes.io/tenant":"blue"}}}' \
     --command -- sleep 3600
   kubectl -n tenant-green describe pod stray | tail -6
   ```

3. Give the blue tenant both a toleration **and** a nodeSelector:

   ```bash
   cat <<'EOF' > 04-pinned.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pinned
     namespace: tenant-blue
   spec:
     nodeSelector:
       node-restriction.kubernetes.io/tenant: blue
     tolerations:
     - key: tenant
       operator: Equal
       value: blue
       effect: NoExecute
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       seccompProfile: {type: RuntimeDefault}
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh","-c","sleep 3600"]
       securityContext:
         allowPrivilegeEscalation: false
         capabilities: {drop: ["ALL"]}
   EOF
   kubectl apply -f 04-pinned.yaml
   kubectl -n tenant-blue get pod pinned -o wide
   ```

4. Verify the NodeRestriction admission plugin is enabled on the API server:

   ```bash
   grep -o 'enable-admission-plugins=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

5. Confirm what a kubelet identity is *not* allowed to do:

   ```bash
   kubectl auth can-i label nodes --as=system:node:node01 --as-group=system:nodes
   kubectl auth can-i get secrets -n tenant-blue --as=system:node:node01 --as-group=system:nodes
   ```

6. Clean up the stray Pod:

   ```bash
   kubectl -n tenant-green delete pod stray --force --grace-period=0
   ```

### Comprehension check

**Q20.** Taints/tolerations and nodeSelector/affinity solve two different halves of node isolation. State which half each one solves, and what goes wrong if you use only tolerations.

**Q21.** Why did we choose the label prefix `node-restriction.kubernetes.io/` rather than a plain `tenant=blue` label on the node?

**Q22.** A tenant can create Pods (Exercise 2 Role) and therefore can write arbitrary `tolerations` into their own Pod spec. Does node taint isolation actually hold against a malicious tenant? What admission-level control would you add?

**Q23.** Distinguish `NoSchedule`, `PreferNoSchedule` and `NoExecute`. Which one evicts Pods that are already running?

**Q24.** Explain in one sentence each: the **Node authorizer** and the **NodeRestriction** admission plugin. Why do you need both?

---

## Exercise 5 — Sandboxed containers with gVisor (`runsc`) via RuntimeClass

This is the core hands-on skill of the topic: swapping the shared host kernel for a user-space kernel.

### Steps

1. On `node01`, install the gVisor binaries:

   ```bash
   # run on node01
   (
     set -e
     ARCH=$(uname -m)
     URL=https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}
     wget ${URL}/runsc ${URL}/runsc.sha512 \
          ${URL}/containerd-shim-runsc-v1 ${URL}/containerd-shim-runsc-v1.sha512
     sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
     rm -f *.sha512
     chmod a+rx runsc containerd-shim-runsc-v1
     sudo mv runsc containerd-shim-runsc-v1 /usr/local/bin
   )
   runsc --version
   ```

2. Register the runtime with containerd and restart it:

   ```bash
   sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
   sudo runsc install
   sudo grep -A3 -i runsc /etc/containerd/config.toml
   sudo systemctl restart containerd
   sudo systemctl is-active containerd
   ```

   If `runsc install` is unavailable for your containerd major version, add the stanza manually.
   containerd 1.7 (`version = 2`):

   ```toml
   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
     runtime_type = "io.containerd.runsc.v1"
   ```

   containerd 2.x (`version = 3`):

   ```toml
   [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
     runtime_type = 'io.containerd.runsc.v1'
   ```

3. Create the RuntimeClass object:

   ```bash
   cat <<'EOF' > 05-runtimeclass.yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: gvisor
   handler: runsc
   scheduling:
     nodeSelector:
       sandbox.example.com/runtime: gvisor
   EOF
   kubectl apply -f 05-runtimeclass.yaml
   kubectl label node node01 sandbox.example.com/runtime=gvisor
   kubectl get runtimeclass
   ```

4. Run the same image twice — once on the default runtime, once sandboxed:

   ```bash
   cat <<'EOF' > 05-compare.yaml
   apiVersion: v1
   kind: Pod
   metadata: {name: plain, namespace: default}
   spec:
     nodeName: node01
     tolerations: [{key: tenant, operator: Equal, value: blue, effect: NoExecute}]
     containers:
     - {name: c, image: busybox:1.36, command: ["sh","-c","sleep 3600"]}
   ---
   apiVersion: v1
   kind: Pod
   metadata: {name: sandboxed, namespace: default}
   spec:
     runtimeClassName: gvisor
     nodeName: node01
     tolerations: [{key: tenant, operator: Equal, value: blue, effect: NoExecute}]
     containers:
     - {name: c, image: busybox:1.36, command: ["sh","-c","sleep 3600"]}
   EOF
   kubectl apply -f 05-compare.yaml
   kubectl get pod plain sandboxed -o wide
   ```

5. Compare the kernel each Pod believes it is running on, and the host's real kernel:

   ```bash
   echo "--- host ---";      uname -r   # run on node01
   echo "--- plain ---";     kubectl exec plain     -- uname -r
   echo "--- sandboxed ---"; kubectl exec sandboxed -- uname -r
   ```

6. Look for the gVisor fingerprint from inside the sandbox:

   ```bash
   kubectl exec sandboxed -- dmesg | head -5
   kubectl exec sandboxed -- cat /proc/version
   kubectl exec plain     -- dmesg | head -3
   ```

7. Compare what the two Pods can see of the host:

   ```bash
   kubectl exec plain     -- sh -c 'nproc; ls /sys/module | wc -l'
   kubectl exec sandboxed -- sh -c 'nproc; ls /sys/module | wc -l'
   ```

8. Confirm the runtime actually used, from the node:

   ```bash
   sudo crictl pods --name sandboxed -q | xargs -I{} sudo crictl inspectp {} \
     | jq -r '.status.runtimeHandler // .info.runtimeHandler'
   sudo ps -ef | grep -c '[r]unsc'
   ```

9. Deliberately break it, to learn the failure signature:

   ```bash
   kubectl run typo --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"runtimeClassName":"gvisorr"}}' --command -- sleep 60
   kubectl get pod typo
   kubectl describe pod typo | tail -5
   ```

### Comprehension check

**Q25.** In one or two sentences, explain *how* gVisor isolates a workload. What plays the role of the kernel, and what happens to a `syscall` the container makes?

**Q26.** In step 5, why does the sandboxed Pod report a different kernel release than both the host and the `plain` Pod?

**Q27.** The RuntimeClass has a `handler: runsc`. What is the relationship between that string and the containerd configuration from step 2? What error do you get if they don't match?

**Q28.** What is the purpose of `scheduling.nodeSelector` inside a RuntimeClass, and why does it matter in a heterogeneous cluster where only some nodes have `runsc` installed?

**Q29.** The Pod in step 9 failed at a specific phase. Was it rejected by admission, by the scheduler, or by the kubelet? How can you tell from the output?

**Q30.** Name three categories of workload that will *not* work (or will work poorly) under gVisor, and say why.

**Q31.** gVisor blocks a kernel exploit that a `seccomp` profile would not, and vice versa. Give one example in each direction and explain why sandboxing and syscall filtering are complementary rather than redundant.

---

## Exercise 6 — Kata Containers: VM-level isolation and RuntimeClass `overhead`

### Steps

1. Check whether your lab can run VM-based sandboxes at all:

   ```bash
   grep -Eoc '(vmx|svm)' /proc/cpuinfo   # 0 means no nested virtualisation
   ls -l /dev/kvm 2>/dev/null || echo "no /dev/kvm"
   ```

2. Inspect the RuntimeClasses that a Kata installation (`kata-deploy`) creates. If Kata is not installed, read and reason about this manifest instead of applying it:

   ```bash
   cat <<'EOF' > 06-kata.yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: kata-qemu
   handler: kata-qemu
   overhead:
     podFixed:
       cpu: "250m"
       memory: "160Mi"
   scheduling:
     nodeSelector:
       katacontainers.io/kata-runtime: "true"
   EOF
   kubectl get runtimeclass -o custom-columns=\
   NAME:.metadata.name,HANDLER:.handler,OVERHEAD_CPU:.overhead.podFixed.cpu,OVERHEAD_MEM:.overhead.podFixed.memory
   ```

3. If `/dev/kvm` exists, deploy Kata and run a workload:

   ```bash
   kubectl apply -k "github.com/kata-containers/kata-containers/tools/packaging/kata-deploy/kata-deploy/overlays/k3s?ref=main"
   kubectl -n kube-system rollout status ds/kata-deploy --timeout=300s
   kubectl get runtimeclass | grep kata

   kubectl run kata-test --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"runtimeClassName":"kata-qemu"}}' --command -- sleep 3600
   kubectl wait --for=condition=Ready pod/kata-test --timeout=180s
   ```

4. Verify VM-level isolation from inside the Pod:

   ```bash
   kubectl exec kata-test -- uname -r          # guest kernel, not host kernel
   kubectl exec kata-test -- sh -c 'nproc; free -m | head -2'
   kubectl exec kata-test -- sh -c 'cat /proc/cmdline'
   kubectl exec kata-test -- sh -c 'ls /dev/vd* 2>/dev/null; echo "---"; dmesg | grep -ic virtio'
   ```

5. Observe how `overhead` changes accounting:

   ```bash
   kubectl get pod kata-test -o jsonpath='{.spec.overhead}{"\n"}'
   kubectl describe node node01 | grep -A6 'Allocated resources'
   ```

6. Prove the quota interaction inside a tenant:

   ```bash
   kubectl -n tenant-blue describe quota tenant-quota | head
   ```

### Comprehension check

**Q32.** Rank these three isolation levels from weakest to strongest and give the boundary each one relies on: (a) two Pods with `runc` in different Namespaces, (b) a Pod with `runtimeClassName: gvisor`, (c) a Pod with `runtimeClassName: kata-qemu`.

**Q33.** What does `overhead.podFixed` do? Which two components consume that value, and what goes wrong on a node if the field is missing for a VM-based runtime?

**Q34.** Both gVisor and Kata are exposed to the user through the *same* Kubernetes API object. Why is that significant for a platform team that wants to change sandbox technology later?

**Q35.** A tenant Pod under `kata-qemu` reports 2 CPUs while the host has 16. Where does that number come from?

**Q36.** Kata gives stronger isolation than gVisor but is not always the right answer. Give two costs of Kata and one workload type where Kata wins clearly over gVisor.

---

## Exercise 7 — Shrinking the shared-kernel surface: user namespaces and host namespaces

### Steps

1. Check whether user namespaces are usable on your cluster:

   ```bash
   kubectl explain pod.spec.hostUsers
   kubectl get --raw='/metrics' | grep -m5 'kubernetes_feature_enabled.*UserNamespaces' || \
     grep -o 'feature-gates=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

2. Run a Pod **with** the host user namespace (the historical default) and inspect its UID map:

   ```bash
   kubectl run hostusers --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"hostUsers":true}}' \
     --command -- sh -c 'sleep 3600'
   kubectl exec hostusers -- cat /proc/self/uid_map
   kubectl exec hostusers -- id
   ```

3. Run the same Pod in its **own** user namespace:

   ```bash
   kubectl run userns --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"hostUsers":false}}' \
     --command -- sh -c 'sleep 3600'
   kubectl get pod userns
   kubectl exec userns -- cat /proc/self/uid_map
   kubectl exec userns -- id
   ```

4. Compare what the container's root maps to on the host:

   ```bash
   # on node01
   sudo ps -eo pid,user,uid,comm | grep -E 'sleep' | head
   ```

5. Try the classic host-namespace escapes against the hardened tenant Namespace:

   ```bash
   for f in hostPID hostNetwork hostIPC; do
     echo "== $f =="
     kubectl -n tenant-blue run esc-$f --image=busybox:1.36 --restart=Never \
       --overrides="{\"spec\":{\"$f\":true}}" --command -- sleep 60 2>&1 | tail -2
   done

   echo "== hostPath =="
   kubectl -n tenant-blue run esc-hp --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"volumes":[{"name":"h","hostPath":{"path":"/"}}],"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","60"],"volumeMounts":[{"name":"h","mountPath":"/host"}]}]}}' 2>&1 | tail -2
   ```

6. Show what the same Pods do in an unlabelled Namespace, to appreciate the difference:

   ```bash
   kubectl create ns danger
   kubectl -n danger run esc --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"hostPID":true,"containers":[{"name":"c","image":"busybox:1.36","command":["sh","-c","ps -ef | head -5; sleep 30"]}]}}'
   kubectl -n danger logs esc
   ```

### Comprehension check

**Q37.** Read the two `/proc/self/uid_map` outputs from steps 2 and 3. Explain what each of the three columns means and what the difference tells you about the container's root user.

**Q38.** A container process runs as UID 0 inside a Pod with `hostUsers: false`. It escapes the container filesystem. What can it do to `/etc/shadow` on the host, and why?

**Q39.** Why does `hostUsers: false` mitigate an entire class of CVEs even when the vulnerable code path is reachable?

**Q40.** Which component (not the API server) must support idmapped mounts / user namespaces for `hostUsers: false` to actually work, and what symptom do you see if it doesn't?

**Q41.** Step 5 blocked `hostPID`, `hostNetwork`, `hostIPC` and `hostPath`. Which mechanism blocked them, and at what point in the request lifecycle?

**Q42.** In step 6 the Pod listed host processes. Name two distinct pieces of sensitive information an attacker gets from `hostPID: true` alone.

---

## Exercise 8 — Force a sandboxed runtime for a whole tenant (ValidatingAdmissionPolicy)

### Steps

1. Label the tenant that must be sandboxed:

   ```bash
   kubectl label namespace tenant-green tenant-isolation=sandboxed --overwrite
   ```

2. Write a policy that rejects any Pod not using the `gvisor` RuntimeClass:

   ```bash
   cat <<'EOF' > 08-vap.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: require-sandboxed-runtime
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
       - apiGroups:   [""]
         apiVersions: ["v1"]
         operations:  ["CREATE", "UPDATE"]
         resources:   ["pods"]
     validations:
     - expression: >-
         has(object.spec.runtimeClassName) &&
         object.spec.runtimeClassName in ['gvisor', 'kata-qemu']
       message: "pods in a sandboxed tenant must set runtimeClassName to gvisor or kata-qemu"
       reason: Forbidden
   ---
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: require-sandboxed-runtime-binding
   spec:
     policyName: require-sandboxed-runtime
     validationActions: ["Deny"]
     matchResources:
       namespaceSelector:
         matchLabels:
           tenant-isolation: sandboxed
   EOF
   kubectl apply -f 08-vap.yaml
   ```

3. Test both directions:

   ```bash
   kubectl -n tenant-green run nosandbox --image=busybox:1.36 --restart=Never --command -- sleep 60
   kubectl -n default      run nosandbox --image=busybox:1.36 --restart=Never --command -- sleep 60
   ```

4. Confirm a compliant Pod is admitted:

   ```bash
   kubectl -n tenant-green run withsandbox --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"runtimeClassName":"gvisor","securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
     --command -- sleep 60
   kubectl -n tenant-green get pod withsandbox -o jsonpath='{.spec.runtimeClassName}{"\n"}'
   ```

5. Switch the binding to audit-only and observe the difference:

   ```bash
   kubectl patch validatingadmissionpolicybinding require-sandboxed-runtime-binding \
     --type=merge -p '{"spec":{"validationActions":["Warn","Audit"]}}'
   kubectl -n tenant-green run nosandbox2 --image=busybox:1.36 --restart=Never --command -- sleep 60
   kubectl -n tenant-green get pod nosandbox2
   ```

6. Restore enforcement:

   ```bash
   kubectl patch validatingadmissionpolicybinding require-sandboxed-runtime-binding \
     --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
   ```

### Comprehension check

**Q43.** Why is a ValidatingAdmissionPolicy needed here at all — can't you just tell the tenant to set `runtimeClassName: gvisor`?

**Q44.** Explain the split between `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding`. Which of the two decides *where* the rule applies?

**Q45.** The CEL expression starts with `has(object.spec.runtimeClassName)`. What happens if you drop that guard and a Pod omits the field?

**Q46.** `failurePolicy: Fail` — what does it mean for a VAP, and how does that compare to the same field on a webhook-based `ValidatingWebhookConfiguration`?

**Q47.** In step 5 the Pod was created despite violating the policy. Which value of `validationActions` caused that, and where would you look for the recorded violation?

**Q48.** Give one advantage of VAP over an admission webhook for this specific rule, and one situation where you would still need a webhook.

---

## Exercise 9 — Isolation audit under exam pressure

### Steps

1. Create a deliberately weak Namespace:

   ```bash
   kubectl create ns legacy
   kubectl -n legacy create deployment app --image=nginx:1.27
   kubectl create clusterrolebinding legacy-admin \
     --clusterrole=cluster-admin --serviceaccount=legacy:default
   ```

2. Run a five-command audit and write down every gap you find:

   ```bash
   NS=legacy
   kubectl get ns $NS --show-labels
   kubectl -n $NS get netpol
   kubectl -n $NS get quota,limitrange
   kubectl get clusterrolebindings,rolebindings -A -o json \
     | jq -r --arg ns "$NS" '.items[] | select(any(.subjects[]?; .namespace==$ns))
              | "\(.kind)/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
   kubectl -n $NS get pods -o json | jq -r '.items[] |
     "\(.metadata.name) runtimeClass=\(.spec.runtimeClassName // "default") hostNet=\(.spec.hostNetwork // false) hostPID=\(.spec.hostPID // false) hostUsers=\(.spec.hostUsers // true) sa=\(.spec.serviceAccountName) automount=\(.spec.automountServiceAccountToken // "unset")"'
   ```

3. Remediate in the correct order and re-run the audit after each fix:

   ```bash
   kubectl delete clusterrolebinding legacy-admin
   kubectl label ns legacy \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=v1.34 \
     pod-security.kubernetes.io/warn=restricted --overwrite
   kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: {name: default-deny-all, namespace: legacy}
   spec:
     podSelector: {}
     policyTypes: ["Ingress","Egress"]
   EOF
   ```

4. Note which existing Pod is still non-compliant and why relabelling did not fix it:

   ```bash
   kubectl -n legacy get pods
   kubectl -n legacy rollout restart deploy/app
   kubectl -n legacy get events --sort-by=.lastTimestamp | tail -5
   ```

### Comprehension check

**Q49.** List, in priority order, the six things you check to decide whether a Namespace is isolated. Justify the first two.

**Q50.** In step 3 you set `enforce=baseline` but `warn=restricted`. Why is that a sensible migration pattern for an existing Namespace?

**Q51.** Why did adding PSA labels not evict the already-running `nginx` Pod, and what does that imply about the order of operations when hardening a live cluster?

**Q52.** You have 4 minutes left in the exam and are told "isolate namespace `X` from all other namespaces". Which single object do you create, and what is the one thing you must remember to also allow?

---

## Cleanup

```bash
kubectl delete ns tenant-blue tenant-green danger legacy --ignore-not-found
kubectl delete pod plain sandboxed typo hostusers userns kata-test --ignore-not-found
kubectl delete validatingadmissionpolicybinding require-sandboxed-runtime-binding --ignore-not-found
kubectl delete validatingadmissionpolicy require-sandboxed-runtime --ignore-not-found
kubectl delete runtimeclass gvisor --ignore-not-found
kubectl delete clusterrolebinding legacy-admin oops --ignore-not-found
kubectl taint node node01 tenant=blue:NoExecute-
kubectl label node node01 node-restriction.kubernetes.io/tenant- sandbox.example.com/runtime-
```

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** (a) The Namespace boundary is only an API-object grouping — Pods in different Namespaces share the same node kernel, the same node filesystem, and by default a flat, fully-routable Pod network. (b) Many resources are cluster-scoped (Nodes, PersistentVolumes, ClusterRoles, CRDs, RuntimeClasses), so a Namespace says nothing about access to them. Isolation only exists once you add RBAC, NetworkPolicy, quotas, PSA and — for kernel-level separation — a sandboxed runtime.

**Q2.** `enforce` rejects the Pod at admission time; the API request fails and no Pod object is created. `audit` lets the Pod through but records an annotation in the audit log entry. `warn` returns a warning to the client (visible in `kubectl` output) but still admits. Setting all three is standard: enforce the level you can commit to today, and audit/warn at the stricter level you are migrating toward.

**Q3.** The PSA profiles evolve between Kubernetes releases — a new field or a new restriction can be added to `restricted`. Pinning `enforce-version` freezes the semantics to the definition shipped in v1.34, so a cluster upgrade cannot silently start rejecting previously-valid Pods. Omitting it means the label defaults to `latest`, which tracks whatever the running control plane implements and can break workloads on upgrade.

**Q4.** PSA is a Pod-level admission controller: it validates Pod objects, not the workload controllers that create them. A Deployment is admitted, its ReplicaSet is admitted, and the failure surfaces only when the ReplicaSet controller tries to create Pods. Look at `kubectl -n <ns> describe replicaset <name>` and `kubectl -n <ns> get events` — the Deployment itself just reports zero available replicas. (PSA does emit a *warning* on the Deployment create, which is why `warn` is worth enabling.)

**Q5.** `LimitRange.spec.limits[].max` caps a single container/Pod, so it blocks the 8-CPU container. `ResourceQuota.spec.hard.requests.cpu` caps the aggregate across the Namespace. They are complementary: quota alone would let one Pod eat the whole allowance; LimitRange alone would let a thousand small Pods do it.

**Q6.** A NodePort Service opens a port on **every** node's network interface, reachable from outside the cluster and bypassing the Pod-level NetworkPolicy view of "who can reach me". It effectively lets a tenant publish itself on shared infrastructure without the platform team's consent. Setting the count to `0` keeps ingress under a controlled, audited path (Ingress/Gateway with its own policy).

**Q7.** The **Pod** spec wins. `automountServiceAccountToken` on the ServiceAccount is the default applied when the Pod does not specify the field; an explicit value on the Pod overrides it. So a tenant who can create Pods can re-enable automounting — which is why token hygiene must be paired with RBAC that makes the token worthless.

**Q8.** A `ClusterRoleBinding` binds the ClusterRole across **all** Namespaces plus cluster-scoped resources. The subject's own Namespace is only part of its identity (`system:serviceaccount:tenant-blue:blue-ci`); it does not limit where the granted permissions apply. This is the single most common way tenant isolation is accidentally destroyed.

**Q9.** Binding a ClusterRole with a **RoleBinding** grants that ClusterRole's rules *only inside the RoleBinding's Namespace* — this is the correct way to reuse `view`, `edit`, or `admin` for one tenant. Binding it with a **ClusterRoleBinding** grants it cluster-wide, including cluster-scoped resources. So: `kubectl create rolebinding blue-view --clusterrole=view --serviceaccount=tenant-blue:blue-ci -n tenant-blue`.

**Q10.** `create pods` lets the tenant submit a Pod with `privileged: true`, `hostPID: true`, or a `hostPath` volume mounting `/`, then read the node's kubelet credentials or `chroot` into the host — full node compromise, and from the node, other tenants' Secrets. From Exercise 1: (a) PSA `enforce=restricted` rejects privileged, host namespaces and hostPath at admission; (b) `automountServiceAccountToken: false` plus tight RBAC limits what the stolen token yields. Node isolation (Exercise 4) and a sandboxed runtime (Exercise 5) further contain the blast radius.

**Q11.** Because effective permissions are the **union** of every Role and ClusterRole bound to the subject — directly, through its groups (`system:serviceaccounts`, `system:authenticated`), and through aggregated ClusterRoles. Reading one Role tells you nothing about the other bindings. `auth can-i --list` asks the authorizer itself, which is the same code path a real request takes.

**Q12.** Namespaced Secrets still include the tenant's own ServiceAccount tokens, TLS keys, image-pull credentials and anything a controller wrote there — reading them can be a privilege-escalation path inside the Namespace (e.g. reading a token for a more privileged SA). Tighter alternative: grant `get` on named resources only (`resourceNames: ["app-config"]`), or don't grant Secret access at all and inject values via the Pod spec / an external secret store with per-workload identity.

**Q13.** NetworkPolicy is allow-list based. As soon as *any* policy selects a Pod for a given `policyType`, that Pod's traffic in that direction becomes deny-by-default and only the union of matching `ingress`/`egress` rules is permitted. With `policyTypes: [Ingress, Egress]` and no rules listed, the allow-list is empty, so nothing is permitted.

**Q14.** DNS resolution is outbound traffic from the Pod to `kube-dns`/CoreDNS on UDP/TCP 53. Once an egress policy selects the Pod with an empty allow-list, that packet is dropped. The symptom is a resolution timeout, which usually gets misdiagnosed as "the Service doesn't exist" — always add the DNS egress rule alongside a default-deny egress.

**Q15.** **Union.** Policies are purely additive; there is no deny rule and no ordering or priority in the core NetworkPolicy API. A Pod's allowed traffic is the union of all rules from all policies selecting it. (Some CNIs offer their own CRDs — CiliumClusterwideNetworkPolicy, Calico `GlobalNetworkPolicy` — that do add deny semantics and precedence.)

**Q16.** Inside a single list item, `namespaceSelector` and `podSelector` are **ANDed**: "Pods matching `k8s-app=kube-dns` *in* Namespaces matching `kubernetes.io/metadata.name=kube-system`". As two separate list items they are **ORed**: "all Pods in kube-system" OR "all Pods named `k8s-app=kube-dns` in *any* Namespace, including every tenant". The second form is dramatically wider and is a favourite exam trap.

**Q17.** The API server's `NamespaceDefaultLabelName` behaviour sets `kubernetes.io/metadata.name` on every Namespace automatically and it is immutable/reconciled by the control plane. A hand-applied `name:` label can be forgotten, mistyped, or removed by whoever can edit the Namespace — which would silently widen or break the policy.

**Q18.** (a) `ipBlock` only matches traffic leaving the cluster overlay; a Pod with `hostNetwork: true` bypasses the Pod-level policy path entirely on most CNIs. (b) The tenant can proxy through another Pod that *is* allowed to reach the metadata IP, or reach the metadata service via an alternate address/hostname (IPv6 link-local, `metadata.google.internal` resolving elsewhere, an IMDS proxy Service). Robust answers: block the IMDS range at the node/host firewall, require IMDSv2, and stop attaching powerful instance roles to nodes.

**Q19.** With `hostNetwork: true` the Pod shares the node's network namespace, so its traffic is node traffic, not Pod traffic — most CNIs do not apply Pod NetworkPolicies to it, and your default-deny is bypassed. PSA `enforce=baseline` or `restricted` (Exercise 1) rejects `hostNetwork: true` at admission, which is why PSA is a prerequisite for trusting NetworkPolicy.

**Q20.** Taints/tolerations are a **repellent**: they keep *other* workloads *off* the dedicated node. nodeSelector/nodeAffinity is an **attractant**: it keeps the tenant's workload *on* the dedicated node. With only tolerations, the tenant's Pods are *allowed* on `node01` but the scheduler may still place them on shared nodes — so the tenant ends up co-resident with everyone else, and the dedicated node sits idle.

**Q21.** The NodeRestriction admission plugin forbids a kubelet from setting or modifying labels under the `node-restriction.kubernetes.io/` prefix (and restricts most other label changes). A compromised node therefore cannot relabel itself as `tenant=blue` to attract another tenant's workloads. A plain `tenant=blue` label could be self-applied by the kubelet, making label-based placement untrustworthy.

**Q22.** No — a tenant who controls their own Pod spec can add any toleration, so taints alone do not confine a *malicious* tenant; they only prevent *accidental* co-location. Add an admission control that pins placement: a ValidatingAdmissionPolicy or mutating policy that forces `nodeSelector` per Namespace, or a policy that rejects tolerations for other tenants' taint keys. (Managed-cluster equivalents: per-tenant node pools with enforced node selectors.)

**Q23.** `NoSchedule` — the scheduler will not place new Pods without a matching toleration; running Pods are untouched. `PreferNoSchedule` — a soft preference; the scheduler avoids the node if it can, but will use it if nothing else fits. `NoExecute` — new Pods need a toleration **and** already-running Pods without one are **evicted** (immediately, or after `tolerationSeconds`).

**Q24.** The **Node authorizer** is an authorization mode that limits what each kubelet identity (`system:node:<name>` in group `system:nodes`) may *read* — essentially only the objects related to Pods scheduled on that node. **NodeRestriction** is an admission plugin that limits what a kubelet may *write* — only its own Node object and the status of its own Pods, and never protected labels/taints. You need both because authorization governs reads/verbs while admission governs the content of writes.

**Q25.** gVisor's `runsc` implements a **user-space kernel** (the Sentry): it intercepts the container's system calls and services them itself, rather than passing them to the host kernel. Only a small, tightly-filtered set of host syscalls is made by the Sentry (via a seccomp-restricted platform layer, with file access brokered by the Gofer). A kernel exploit in the container therefore attacks the Sentry's reimplementation, not the host kernel — dramatically shrinking the attack surface.

**Q26.** Because the sandboxed container is not talking to the host kernel at all. `uname` is a syscall answered by the Sentry, which reports its own synthetic, gVisor-compatible kernel version (historically a `4.4.x`-style string). The `plain` Pod's `uname` reaches the real host kernel through the shared namespace, so it matches the node exactly.

**Q27.** `handler` is the key the kubelet passes to the CRI runtime; containerd looks it up as the runtime name in its config (`...containerd.runtimes.<handler>`). They must match exactly: `handler: runsc` requires a `runtimes.runsc` stanza. On mismatch the Pod stays in `ContainerCreating`/fails to start and the kubelet event reads roughly `failed to create containerd task: ... no runtime for "X" is configured` — a kubelet/runtime error, not an admission error.

**Q28.** `scheduling.nodeSelector` is added to any Pod using the RuntimeClass, restricting it to nodes that actually have the handler installed (there is also `scheduling.tolerations` for tainted sandbox nodes). Without it, the scheduler happily places a `gvisor` Pod on a node with no `runsc` binary, and the Pod hangs in `ContainerCreating` — a failure that looks like a RuntimeClass bug but is really a scheduling bug.

**Q29.** It was rejected at **admission**: RuntimeClass existence is validated by the API server, so `kubectl get pod typo` shows no Pod at all (or, if it was created, the `describe` output shows a `FailedCreatePodSandBox`/RuntimeClass-not-found condition). The distinguishing signal: an admission rejection returns an error immediately from `kubectl create` and no object exists; a scheduler failure shows `Pending` with `FailedScheduling` events; a kubelet failure shows a node assignment plus `ContainerCreating` and runtime events.

**Q30.** (a) Workloads that need direct hardware or kernel-module access — GPU compute, eBPF tooling, `CAP_SYS_ADMIN` agents — because gVisor does not implement or expose those interfaces. (b) Syscall-heavy or I/O-heavy workloads — busy databases, high-throughput proxies — because every syscall crosses the Sentry, adding latency and reducing throughput. (c) Anything relying on unimplemented or partially-implemented syscalls / obscure `/proc` and `/sys` entries; the Sentry covers most of Linux, not all of it, so such workloads fail with `ENOSYS`-style errors.

**Q31.** Sandbox-not-seccomp: an exploit in an *allowed* syscall's kernel implementation (e.g. a memory-corruption bug in a permitted `ioctl` or in the networking stack) passes a seccomp allow-list untouched but hits gVisor's own reimplementation instead of the host kernel. Seccomp-not-sandbox: seccomp can deny a syscall for a Pod running on the **default** runtime, where no sandbox exists at all — and it also protects the sandbox's own supervisor. In practice you apply both: `seccompProfile: RuntimeDefault` on every Pod, plus a sandboxed RuntimeClass for untrusted tenants (defence in depth).

**Q32.** Weakest → strongest: (a) `runc` in different Namespaces — relies on Linux namespaces, cgroups, capabilities and seccomp over a **shared host kernel**; a kernel bug is a full escape. (b) `gvisor` — relies on a **user-space kernel** intercepting syscalls, so a container kernel exploit must first break the Sentry, itself confined by seccomp. (c) `kata-qemu` — relies on a **hardware virtualisation boundary**: each Pod gets its own guest kernel inside a lightweight VM, so escaping requires a hypervisor/VMM vulnerability.

**Q33.** `overhead.podFixed` declares the extra CPU/memory the sandbox infrastructure itself consumes (VMM process, guest kernel, agent). The **scheduler** adds it when computing whether a Pod fits on a node, and the **kubelet**/resource accounting (including ResourceQuota) includes it in the Pod's total. Without it, the node is over-committed: the scheduler believes only the container requests are consumed, and the extra hundreds of MiB per Pod eventually cause node memory pressure and evictions.

**Q34.** Because RuntimeClass is a **pluggable indirection**: the workload author references a name (`gvisor`, `kata-qemu`, `sandboxed`), and the platform team maps that name to a handler and to nodes. Swapping the underlying technology, or routing the same class to different handlers on different node pools, requires no change to tenant manifests — the isolation contract stays in the platform's hands.

**Q35.** From the guest VM's configuration, not the host. Kata sizes the VM's virtual CPUs from the Pod's resource requests/limits and the Kata configuration defaults (`default_vcpus`), so the guest kernel only ever sees the vCPUs it was given. That is also *why* it is stronger isolation: the workload has no visibility into the host's real topology.

**Q36.** Costs: (a) higher per-Pod resource overhead and slower startup (a VM must boot), which is exactly what `overhead.podFixed` encodes; (b) an infrastructure dependency on nested virtualisation / `/dev/kvm`, which many managed and virtualised environments do not provide, plus more moving parts to operate. Kata wins clearly for workloads that need broad, faithful kernel functionality **and** strong isolation — e.g. running untrusted customer code that uses unusual syscalls, kernel modules, or its own container runtime, where gVisor's syscall coverage would break it.

**Q37.** The columns are: *first UID inside the namespace*, *corresponding first UID on the host*, *range length*. With `hostUsers: true` you see `0  0  4294967295` — the container's UID space **is** the host's, so container root is host root. With `hostUsers: false` you see something like `0  <someHighHostUID>  65536` — container UID 0 maps to an unprivileged host UID, and only a 65536-wide slice is available.

**Q38.** Nothing. From the host's point of view the process is an ordinary unprivileged user (the mapped high UID), so it has no write access to `/etc/shadow` and no permission over host files owned by real root. Its UID 0 is only meaningful *inside* its own user namespace; capabilities it holds are namespaced capabilities, powerless against resources owned by the initial user namespace.

**Q39.** Because it decouples "root in the container" from "root on the host" for the whole class of bugs whose impact depends on the attacker having real UID 0 / real capabilities — container escapes via writable host paths, `CAP_*`-gated kernel interfaces, setuid tricks. The vulnerable code may still run, but the privileges it yields are confined to a mapped, unprivileged UID range, so the escape leads nowhere useful.

**Q40.** The **container runtime** (containerd/CRI-O together with the OCI runtime — `runc` ≥1.2 or `crun` — and kernel support for idmapped mounts on the relevant filesystems). If it is missing or too old, the Pod fails to start: it stays in `ContainerCreating` with a kubelet/runtime event about user namespaces or idmap not being supported. The feature gate on the control plane is necessary but not sufficient.

**Q41.** Pod Security Admission with `enforce=restricted` (from Exercise 1) blocked them. It runs as a built-in **validating admission** controller inside the API server, so the request is rejected before the object is persisted — no Pod is created, no scheduler or kubelet involvement, and the error names each offending field.

**Q42.** (a) The full process table of the node, including other tenants' processes, their command lines and therefore any secrets, tokens or connection strings passed as arguments. (b) The ability to inspect other processes' `/proc/<pid>/` — environment variables (`environ`), open file descriptors, and mounted namespaces — which is a direct route to credentials and to `nsenter`-style escapes when combined with privileges.

**Q43.** Because "telling the tenant" is not a control. A tenant who can create Pods (or any controller acting on their behalf) can omit or change `runtimeClassName`, and a single unsandboxed Pod re-establishes the shared-kernel risk for the whole node. The requirement has to be enforced by the API server at admission, evaluated on every CREATE and UPDATE, independent of tenant cooperation.

**Q44.** The **policy** defines *what* is checked — the CEL expressions, the resource kinds it can apply to, the failure policy — and is reusable. The **binding** defines *where and how* it applies — which Namespaces or objects (`matchResources`, `namespaceSelector`, `objectSelector`) and which `validationActions` (Deny/Warn/Audit). The binding decides scope; one policy can have many bindings with different scopes and actions.

**Q45.** CEL evaluation on an absent optional field is an error, not `false`. Combined with `failurePolicy: Fail`, the request is rejected with an evaluation error rather than your intended message — every Pod in the bound Namespaces fails with a confusing internal error. `has()` (or `object.spec.?runtimeClassName.orValue('')`) makes the absence case explicit and produces the proper `message`.

**Q46.** For a VAP, `failurePolicy` governs what happens when the **CEL expression fails to evaluate** (type error, missing field, cost limit): `Fail` rejects the request, `Ignore` admits it. For a `ValidatingWebhookConfiguration` it governs what happens when the **external webhook is unreachable or errors** — a much bigger availability concern, since a down webhook with `Fail` can freeze the cluster. VAP has no network dependency, so `Fail` is far safer to use.

**Q47.** `validationActions: ["Warn","Audit"]` — `Warn` returns the message as a client-visible warning and `Audit` records it in the audit log annotation (`validation.policy.admission.k8s.io/validation_failure`), but neither rejects. Only `Deny` rejects. You find the violation in the `kubectl` warning output and in the API server audit log. This pair is the correct way to dry-run a policy against a live cluster before enforcing.

**Q48.** Advantage: VAP runs **in-process** in the API server — no extra Deployment, Service, TLS certificate rotation or webhook availability risk, and no latency added by a network hop; it cannot take the cluster down when it crashes. You still need a webhook when the decision requires state the API server does not have in the request — calling an external service (image signature verification against a registry, a CVE database, an external policy engine), or performing complex mutation beyond what mutating admission policies express.

**Q49.** In order: (1) **RBAC** — every binding whose subject lives in the Namespace, especially ClusterRoleBindings, because a single `cluster-admin` binding makes every other control cosmetic. (2) **Pod Security Admission labels** — because without them a tenant can create a privileged/hostPath/hostNetwork Pod and bypass network policy, node isolation and user-namespace protections at once. Then: (3) NetworkPolicy default-deny plus explicit allows; (4) ResourceQuota + LimitRange; (5) Pod-spec hygiene (`runtimeClassName`, `hostUsers`, `automountServiceAccountToken`, host namespaces); (6) node placement (taints/tolerations, trusted node labels).

**Q50.** `enforce=baseline` blocks the genuinely dangerous things (privileged, host namespaces, hostPath, most capabilities) without breaking the many workloads that still run as root or lack a `seccompProfile`. `warn=restricted` simultaneously tells every author exactly what they must fix to reach the stricter level, generating the migration backlog without an outage. When the warnings go quiet, you promote `enforce` to `restricted`.

**Q51.** PSA is an **admission** controller: it evaluates Pods on CREATE/UPDATE, not continuously against existing objects. Already-running Pods are never re-validated or evicted, so a relabelled Namespace can keep serving non-compliant Pods indefinitely. Implication: after labelling, you must recreate the workloads (`rollout restart`) — and you should check `warn`/`audit` output *before* enforcing, because the breakage only appears at the next Pod creation, possibly during an unrelated node drain at 3am.

**Q52.** One `NetworkPolicy` in Namespace X with `podSelector: {}` and `policyTypes: [Ingress, Egress]` (default-deny both directions), plus — the thing everyone forgets — an allow rule for **DNS egress to CoreDNS in kube-system on UDP/TCP 53**, and usually intra-Namespace Pod-to-Pod traffic. Without the DNS rule the Namespace is isolated but also non-functional, and the task is marked wrong.

</details>

---

## References

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes documentation, *Multi-tenancy* — https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Kubernetes documentation, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes documentation, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes documentation, *Runtime Class* — https://kubernetes.io/docs/concepts/containers/runtime-class/
- Kubernetes documentation, *Pod Overhead* — https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/
- Kubernetes documentation, *User Namespaces* — https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
- Kubernetes documentation, *Network Policies* — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes documentation, *Taints and Tolerations* — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes documentation, *Using Node Authorization* — https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes documentation, *Admission Control: NodeRestriction* — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Kubernetes documentation, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes documentation, *Resource Quotas* — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes documentation, *Limit Ranges* — https://kubernetes.io/docs/concepts/policy/limit-range/
- gVisor documentation, *Kubernetes / containerd quick start* — https://gvisor.dev/docs/user_guide/containerd/quick_start/
- gVisor documentation, *Architecture Guide* — https://gvisor.dev/docs/architecture_guide/
- Kata Containers documentation, *Kubernetes integration and kata-deploy* — https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy