# KCA 2.3 — Controller Configuration with Flags

**Guided exercises · Exam weight 3.0**

The `kube-controller-manager` is a single binary that runs the built-in control loops (node lifecycle, deployment, job, service account, garbage collection, CSR signing, and ~30 more). On a `kubeadm` cluster it runs as a **static Pod** whose entire configuration is a flat list of command-line flags in `/etc/kubernetes/manifests/kube-controller-manager.yaml`. There is no separate config file: the flags *are* the API. This lab teaches you to read, change, verify, tune and troubleshoot those flags safely.

> **Prerequisites**
> - A cluster you may break — ideally single control-plane `kubeadm`, Kubernetes ≥ 1.29.
> - `root`/`sudo` on the control-plane node, plus `crictl` and `kubectl`.
> - Every edit to the static manifest is applied by the kubelet automatically — **there is no `kubectl apply`** and no `systemctl restart` for this Pod.
>
> Reference: <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/>

---

## Exercise 1 — Read the running configuration and its sources

The first skill is separating *what is configured* (the manifest) from *what is running* (the container process) from *what the defaults are* (the reference).

1. Look at the authoritative source of the configuration — the static Pod manifest:

   ```bash
   sudo grep -nE 'kube-controller-manager|--' /etc/kubernetes/manifests/kube-controller-manager.yaml
   ```

   Expected (abridged):

   ```
    10:    - command:
    11:    - kube-controller-manager
    12:    - --allocate-node-cidrs=true
    13:    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    14:    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    15:    - --bind-address=127.0.0.1
    16:    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    17:    - --cluster-cidr=10.244.0.0/16
    18:    - --cluster-name=kubernetes
    19:    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    20:    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    21:    - --controllers=*,bootstrapsigner,tokencleaner
    22:    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    23:    - --leader-elect=true
    24:    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    25:    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    26:    - --service-cluster-ip-range=10.96.0.0/12
    27:    - --use-service-account-credentials=true
   ```

2. Now look at what is actually running as a mirror Pod in the API. The node name is a suffix of the Pod name:

   ```bash
   kubectl -n kube-system get pod -l component=kube-controller-manager -o wide
   ```

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE    IP              NODE
   kube-controller-manager-controlplane   1/1     Running   0          3d2h   192.168.1.10    controlplane
   ```

3. Confirm the flags the *process* was started with (not just the manifest on disk):

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane \
     -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep controllers
   ```

   ```
   "--controllers=*
   bootstrapsigner
   tokencleaner"
   ```

4. Cross-check a flag's **default** so you know what you are overriding. Anything not present in the manifest runs at its documented default:

   ```bash
   kube-controller-manager --help 2>/dev/null | grep -A2 -- '--node-monitor-grace-period'
   ```

   ```
       --node-monitor-grace-period duration     Default: 40s
         Amount of time which we allow running Node to be unresponsive before
         marking it unhealthy. ...
   ```

   > If the binary is not on `$PATH`, read the reference page instead: <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/>

**Q1.** Why is the mirror Pod in step 2 a faithful representation of the process but still *not* the authoritative configuration you should edit?

**Q2.** The manifest in step 1 contains no `--node-monitor-grace-period`. Is the flag therefore *unset* on the running controller? What value is in effect?

**Q3.** Which two `kubeconfig`-family flags in the manifest tell the controller-manager how to *authenticate delegated requests to itself* (its own serving endpoint), versus how to *talk to the API server*?

---

## Exercise 2 — Change a flag and prove the kubelet reloaded the static Pod

Editing the manifest is a live change. You must be able to prove the reload happened and that the new flag is active — a silent parse failure looks identical to "nothing happened" until you check.

1. Capture the current container ID and start time so you can prove a restart later:

   ```bash
   sudo crictl ps --name kube-controller-manager -o table
   ```

   ```
   CONTAINER      IMAGE          CREATED       STATE     NAME                      ATTEMPT   POD ID
   9f3a1c2b4d5e   1d2a3b4c5d6e   3 days ago    Running   kube-controller-manager   0         7a8b9c0d1e2f
   ```

2. Edit the manifest. Add an explicit, harmless tuning flag — increase how many Deployments reconcile in parallel from the default of 5:

   ```bash
   sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml
   ```

   Add one line inside the `command:` list, keeping YAML list indentation identical to its neighbours:

   ```yaml
       - --concurrent-deployment-syncs=10
   ```

3. Watch the kubelet detect the file change and recreate the Pod (this usually takes 15–30 seconds):

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane -w
   ```

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE
   kube-controller-manager-controlplane   1/1     Running   0          3d2h
   kube-controller-manager-controlplane   0/1     Pending   0          0s
   kube-controller-manager-controlplane   0/1     Running   0          2s
   kube-controller-manager-controlplane   1/1     Running   0          12s
   ```

   Press `Ctrl-C` once it is `1/1 Running`.

4. Prove a **new container** was created (different ID / `CREATED`):

   ```bash
   sudo crictl ps --name kube-controller-manager -o table
   ```

   ```
   CONTAINER      IMAGE          CREATED         STATE     NAME                      ATTEMPT
   0a1b2c3d4e5f   1d2a3b4c5d6e   30 seconds ago  Running   kube-controller-manager   0
   ```

5. Prove the flag is actually in effect by reading it from the live process arguments:

   ```bash
   sudo crictl inspect $(sudo crictl ps -q --name kube-controller-manager) \
     | grep -o 'concurrent-deployment-syncs=[0-9]*'
   ```

   ```
   concurrent-deployment-syncs=10
   ```

**Q4.** The kubelet recreated the Pod, yet `RESTARTS` stayed `0`. Explain the difference between a *container restart* and what happened here, and why the old `POD ID` changed.

**Q5.** You edited the manifest but `kubectl -n kube-system get pod ...` still shows the *old* `AGE` after two minutes. Name the two most likely mistakes, and the single command that would reveal a YAML/flag parse error.

---

## Exercise 3 — Enable and disable individual controllers with `--controllers`

`--controllers` is a list-with-wildcards: `*` means "all controllers that are on by default", a bare name force-enables an off-by-default controller, and a `-` prefix disables one. This is the flag examiners love because its effect is directly observable.

1. See the effective list and confirm `cronjob` is currently active (it is included by `*`):

   ```bash
   kubectl -n kube-system logs kube-controller-manager-controlplane \
     | grep -i 'Started controller' | grep -iE 'cronjob|garbagecollector' | head
   ```

   ```
   I0813 10:02:14.331 1 controllermanager.go:... "Started controller" controller="cronjob-controller"
   I0813 10:02:14.402 1 controllermanager.go:... "Started controller" controller="garbage-collector-controller"
   ```

2. Create a CronJob that fires every minute so you have something observable:

   ```bash
   kubectl create cronjob heartbeat --image=busybox --schedule='* * * * *' -- date
   sleep 75
   kubectl get jobs -l job-name --no-headers | grep heartbeat
   ```

   ```
   heartbeat-29280612   Complete   1/1   3s   61s
   ```

   A Job appeared — the controller is working.

3. Now **disable only** the `cronjob` controller. Edit the manifest and change the `--controllers` line so it keeps every default but subtracts `cronjob`:

   ```yaml
       - --controllers=*,bootstrapsigner,tokencleaner,-cronjob
   ```

   Wait for the reload (Exercise 2, step 3), then confirm it did **not** start:

   ```bash
   kubectl -n kube-system logs kube-controller-manager-controlplane \
     | grep -iE 'cronjob' | tail -2
   ```

   ```
   I0813 10:35:01.118 1 controllermanager.go:... "Controller is disabled by a flag..." controller="cronjob"
   ```

4. Prove the effect at the workload level — no new Jobs are created while the controller is off:

   ```bash
   kubectl get jobs --no-headers | wc -l   # note the number
   sleep 130
   kubectl get jobs --no-headers | wc -l   # unchanged
   ```

5. Re-enable it by restoring the original line, wait for reload, and confirm Jobs resume within a minute.

   ```yaml
       - --controllers=*,bootstrapsigner,tokencleaner
   ```

**Q6.** Why must you write `*,bootstrapsigner,tokencleaner,-cronjob` rather than simply `-cronjob`? What would `--controllers=-cronjob` alone do to the rest of the cluster?

**Q7.** With the `cronjob` controller disabled, the CronJob object still exists and shows a valid `SCHEDULE`. Which architectural principle explains why the *desired state* is intact but *nothing acts on it*?

**Q8.** Give one production reason an operator would deliberately disable a specific built-in controller (e.g. `nodeipam` or `service`) rather than run the full set.

---

## Exercise 4 — Node-lifecycle flags and the taint-based eviction path

`--node-monitor-period`, `--node-monitor-grace-period` and the (deprecated) `--pod-eviction-timeout` govern how fast a dead node is noticed and how fast its Pods are evicted. Getting the mental model right matters because one of these flags no longer does what its name suggests.

1. Read the three flags and their defaults:

   ```bash
   kube-controller-manager --help 2>/dev/null \
     | grep -EA1 -- '--node-monitor-period|--node-monitor-grace-period|--pod-eviction-timeout'
   ```

   ```
       --node-monitor-period duration            Default: 5s
       --node-monitor-grace-period duration      Default: 40s
       --pod-eviction-timeout duration           Default: 5m0s   (DEPRECATED: no effect when
                                                 taint-based eviction is enabled — the default)
   ```

2. Tighten detection for a lab: mark a node unhealthy after 20s instead of 40s. Edit the manifest:

   ```yaml
       - --node-monitor-period=2s
       - --node-monitor-grace-period=20s
   ```

   Wait for the reload, then confirm the flags are live (Exercise 2, step 5).

3. Simulate a node failure. On a *worker* node, stop the kubelet:

   ```bash
   sudo systemctl stop kubelet     # run on the worker, NOT the control plane
   ```

4. From the control plane, time how long until the node is `NotReady` and watch the taint appear:

   ```bash
   kubectl get nodes -w
   ```

   ```
   NAME     STATUS     ROLES    AGE   VERSION
   worker   Ready      <none>   3d    v1.31.0
   worker   NotReady   <none>   3d    v1.31.0     # ~20s after kubelet stopped
   ```

   ```bash
   kubectl describe node worker | grep -A2 Taints
   ```

   ```
   Taints: node.kubernetes.io/not-ready:NoExecute
           node.kubernetes.io/not-ready:NoSchedule
   ```

5. Observe *when* Pods on that node are actually evicted:

   ```bash
   kubectl get pods -o wide --field-selector spec.nodeName=worker -w
   ```

   The Pods are not evicted at the 20s mark — they linger until their `NoExecute` toleration expires (default `tolerationSeconds: 300`).

6. Restore the node and the defaults:

   ```bash
   sudo systemctl start kubelet    # on the worker
   ```

   Remove your two flags (or set them back to `5s`/`40s`) and let the manifest reload.

**Q9.** After `--node-monitor-grace-period`, the node was tainted almost immediately but the Pods survived ~5 more minutes. Which component adds the `tolerationSeconds` that produces that 5-minute delay, and which flag would you tune to shorten it — a controller-manager flag, or something else?

**Q10.** A colleague sets `--pod-eviction-timeout=30s` to "evict faster" and reports it did nothing. Why is the flag inert on a modern cluster, and what is the correct lever?

**Q11.** Lowering `--node-monitor-grace-period` to `10s` makes failure detection faster. State one concrete failure mode this creates on a busy or high-latency cluster.

---

## Exercise 5 — Signing, ServiceAccount and trust flags

The controller-manager is a certificate authority and a token minter. Four flags wire that trust: `--cluster-signing-cert-file`/`--cluster-signing-key-file` (approves & signs CSRs), `--service-account-private-key-file` (signs SA tokens), `--root-ca-file` (the CA bundle it injects), and `--use-service-account-credentials`.

1. Confirm the signing controllers are running and see who they trust:

   ```bash
   kubectl -n kube-system logs kube-controller-manager-controlplane \
     | grep -iE 'csrsigning|serviceaccount-token|root-ca-cert-publisher' | grep -i started
   ```

   ```
   ... "Started controller" controller="certificate-csrsigning-kubelet-serving-controller"
   ... "Started controller" controller="serviceaccount-token-controller"
   ... "Started controller" controller="root-ca-cert-publisher-controller"
   ```

2. Prove the `root-ca-cert-publisher` is doing its job — every namespace gets a `kube-root-ca.crt` ConfigMap seeded from `--root-ca-file`:

   ```bash
   kubectl create ns trust-demo
   kubectl -n trust-demo get configmap kube-root-ca.crt
   ```

   ```
   NAME               DATA   AGE
   kube-root-ca.crt   1      2s
   ```

3. Prove the CSR signing path end-to-end. Generate a key + CSR, submit it, approve it, and watch the `csrsigning` controller sign it using `--cluster-signing-cert-file`:

   ```bash
   openssl genrsa -out demo.key 2048
   openssl req -new -key demo.key -out demo.csr -subj "/CN=demo-user/O=dev"
   cat <<EOF | kubectl apply -f -
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: demo-user
   spec:
     request: $(base64 -w0 demo.csr)
     signerName: kubernetes.io/kube-apiserver-client
     usages: ["client auth"]
   EOF
   kubectl certificate approve demo-user
   kubectl get csr demo-user
   ```

   ```
   NAME        AGE   SIGNERNAME                            REQUESTOR          CONDITION
   demo-user   8s    kubernetes.io/kube-apiserver-client   kubernetes-admin   Approved,Issued
   ```

   `Issued` means the controller-manager signed it — no other component did.

4. Clean up:

   ```bash
   kubectl delete csr demo-user; kubectl delete ns trust-demo; rm -f demo.key demo.csr
   ```

Reference: <https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/>

**Q12.** If `--service-account-private-key-file` and the API server's `--service-account-key-file` are inconsistent (different keys), what breaks — token *minting*, token *verification*, or both? Which component holds each flag?

**Q13.** A CSR sits forever in `Approved` but never reaches `Issued`. The API server is healthy and the CSR is valid. Which controller-manager flag or controller is the prime suspect?

**Q14.** What does `--use-service-account-credentials=true` change about *how the controllers themselves authenticate*, and why is that better for auditing than one shared identity?

---

## Exercise 6 — Troubleshoot a controller-manager that will not start

Because the whole config is CLI flags with no schema validation before launch, a single typo produces a `CrashLoopBackOff` that `kubectl` can barely see (the mirror Pod disappears when the container is down). You must debug at the container-runtime layer.

1. Break it on purpose — introduce an invalid flag value:

   ```yaml
       - --leader-elect=maybe
   ```

   (`--leader-elect` is a boolean; `maybe` is not parseable.) Save and let the kubelet try to reload.

2. Observe the symptom. `kubectl` may show the Pod flapping or absent:

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane
   ```

   ```
   NAME                                   READY   STATUS             RESTARTS      AGE
   kube-controller-manager-controlplane   0/1     CrashLoopBackOff   4 (20s ago)   90s
   ```

3. When the mirror Pod is gone, drop to `crictl` to find the failing container and read its logs — this is the key diagnostic move:

   ```bash
   sudo crictl ps -a --name kube-controller-manager --state exited -o table
   sudo crictl logs $(sudo crictl ps -a -q --name kube-controller-manager | head -1)
   ```

   ```
   invalid argument "maybe" for "--leader-elect" flag: strconv.ParseBool: parsing "maybe": invalid syntax
   ```

4. If even `crictl` shows nothing, check the kubelet's own view of why it rejected the static Pod:

   ```bash
   sudo journalctl -u kubelet --since "-3 min" | grep -i 'controller-manager\|static' | tail
   ```

5. Fix the flag (`--leader-elect=true`), save, and confirm recovery:

   ```bash
   kubectl -n kube-system get pod kube-controller-manager-controlplane
   ```

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE
   kube-controller-manager-controlplane   1/1     Running   0          15s
   ```

**Q15.** Why can `kubectl -n kube-system logs` fail to show the crash reason for this Pod, while `crictl logs` succeeds? Tie your answer to how mirror Pods work.

**Q16.** You save a manifest with a YAML indentation error (not a flag error). The old container keeps running and no new one appears. Where do you look, and why did the kubelet *not* kill the healthy old container?

**Q17.** During the crash loop, workloads kept running and Services kept routing, but a newly-scaled Deployment did not create Pods. Explain, using the controller-manager's role, why the *data plane* was fine but *reconciliation* stalled.

---

## Answers

<details>
<summary>Show answers (Q1–Q17)</summary>

**Q1.** The mirror Pod is a *read-only reflection* the kubelet publishes to the API for a static Pod; you cannot edit it (`kubectl edit`/`delete` on it is reverted or recreated by the kubelet). The authoritative configuration is the file `/etc/kubernetes/manifests/kube-controller-manager.yaml` on the node — that file is the only thing you change, and the kubelet re-derives both the container and the mirror Pod from it.

**Q2.** No — a flag absent from the manifest is not "unset"; it runs at its documented default. `--node-monitor-grace-period` is therefore in effect at **40s**. The manifest only lists *overrides*; everything else is the binary's built-in default (verify with `--help`, not by assuming absence means disabled).

**Q3.** `--authentication-kubeconfig` and `--authorization-kubeconfig` tell the controller-manager how to authenticate and authorize *incoming* delegated requests to its own serving port (e.g. metrics scrapers), by delegating to the API server. `--kubeconfig` (and the `--client-ca-file`/`--root-ca-file` pair) is how it acts as a *client talking to* the API server. Direction is the distinction: serving-side auth vs. client-side identity.

**Q4.** `RESTARTS` counts restarts of a container *within the same Pod sandbox*. Here the kubelet deleted the whole Pod (old `POD ID`/sandbox) and created a brand-new one because the Pod spec derived from the manifest changed — so a new sandbox and container start at `RESTARTS=0`. A container *restart* would keep the same Pod/sandbox and increment the counter (as seen in Exercise 6's CrashLoop). The `POD ID` changed precisely because it is a new sandbox, not a re-run of the old one.

**Q5.** Most likely: (a) you edited a copy or wrong path (the kubelet only watches `--pod-manifest-path`, normally `/etc/kubernetes/manifests/`), or (b) the manifest has a YAML/flag error so the kubelet refuses to create the new Pod and keeps the old one. The single revealing command: `sudo journalctl -u kubelet --since "-3 min" | grep -i static` (for parse/admission rejections) or `sudo crictl logs <exited-container>` (for a flag that parsed as YAML but the binary rejected).

**Q6.** `*` expands to "all default-on controllers"; `bootstrapsigner,tokencleaner` add the two off-by-default ones kubeadm needs; `-cronjob` subtracts one. Writing `--controllers=-cronjob` alone makes the list *exactly* `{disable cronjob}` with **no `*`**, so every other controller is off — deployments, replicasets, endpoints, garbage collection, node lifecycle, etc. all stop reconciling. The wildcard must be present to keep the rest enabled.

**Q7.** The controller/reconciliation (level-triggered control loop) principle: the object store holds *desired state* independently of any controller. With the `cronjob` controller disabled, the desired state (the CronJob) is untouched, but there is no active control loop watching CronJobs to drive *current state* toward it — so no Jobs are created. Re-enabling the controller resumes reconciliation from the existing desired state.

**Q8.** Common reasons: on a managed/cloud or externally-provisioned cluster you disable `nodeipam`/`route`/`service`/`cloud-node-lifecycle` because an external controller (CCM, CNI, cloud load-balancer controller) owns that responsibility, and running both causes conflicting writes/thrash. Disabling the redundant built-in controller prevents duplicated or fighting reconciliation.

**Q9.** The `DefaultTolerationSeconds` admission controller (in the API server) injects `tolerationSeconds: 300` for the `node.kubernetes.io/not-ready` and `unreachable` `NoExecute` taints on every Pod that lacks its own. That 300s toleration — not a controller-manager flag — is what keeps Pods alive for ~5 minutes after the taint. To shorten it you set the API server flags `--default-not-ready-toleration-seconds` / `--default-unreachable-toleration-seconds`, or set explicit `tolerations` on the Pod. `--node-monitor-grace-period` only controls *how fast the taint appears*, not how long Pods tolerate it.

**Q10.** `--pod-eviction-timeout` is deprecated and has **no effect** because taint-based eviction (the `NoExecute` taint + per-Pod `tolerationSeconds` path) is the default and the only active eviction mechanism on modern clusters. The correct levers are: `--node-monitor-grace-period` (how fast the node is tainted) plus the API server's default-toleration-seconds flags or per-Pod `tolerations` (how fast tainted-node Pods are evicted).

**Q11.** A short grace period makes the controller declare a node dead on transient blips — a slow kubelet heartbeat under load, a brief network partition, or API-server latency. That triggers unnecessary `NoExecute` taints and, once tolerations expire, mass Pod rescheduling ("eviction storms") that move healthy workloads and add more load, potentially cascading. It trades faster detection for false positives.

**Q12.** The controller-manager *mints/signs* ServiceAccount tokens with `--service-account-private-key-file` (private key); the API server *verifies* them with `--service-account-key-file` (the corresponding public key, and it accepts a list). If they are inconsistent, verification breaks: tokens are still minted but the API server rejects them (401), so Pods can't authenticate as their ServiceAccount. Fix is to include the signing key's public counterpart in the API server's key set (rotation is why it accepts multiple).

**Q13.** The `csrsigning` controller and its `--cluster-signing-cert-file`/`--cluster-signing-key-file` (or the newer per-signer variants). `Approved` is an authorization decision (RBAC/`kubectl certificate approve`); `Issued` requires the controller-manager to actually sign. If the signing cert/key files are missing, unreadable, or the CSR's `signerName` isn't handled by the controller-manager's configured signers, it stays `Approved` but never `Issued`.

**Q14.** With `--use-service-account-credentials=true`, each built-in controller authenticates to the API server as its *own* dedicated ServiceAccount (e.g. `system:serviceaccount:kube-system:deployment-controller`) instead of all sharing the controller-manager's single identity. That enables least-privilege RBAC per controller and makes audit logs attribute each write to the specific controller that made it, rather than to one opaque shared account.

**Q15.** `kubectl logs` reads through the API server, which needs the *mirror Pod* object to exist and the container to have produced retrievable logs. In `CrashLoopBackOff` the container may be exited/absent and the mirror Pod stale or gone, so the API-server path returns nothing or an error. `crictl` talks directly to the node's container runtime (CRI), so it can read the *exited* container's logs regardless of the API/mirror-Pod state — it's below the abstraction that broke.

**Q16.** Look at the kubelet's own journal: `sudo journalctl -u kubelet | grep -i static` (it logs YAML parse/admission rejections for the manifest). The kubelet did not kill the running container because it *rejected the new manifest before acting on it* — an invalid file is treated as "no valid new spec," so it leaves the last-known-good Pod running rather than tearing down a healthy control-plane component over a bad edit. Fail-safe behaviour.

**Q17.** The data plane (kube-proxy/CNI routing, running Pods, kubelet) does not depend on the controller-manager, so existing traffic and Pods keep working. But the controller-manager runs the *reconciliation* loops — Deployment→ReplicaSet→Pod creation, endpoints, GC, etc. While it crash-loops, no loop advances desired state, so scaling a Deployment records the new `replicas` in etcd but nothing creates the Pods. Control plane (reconciliation) was down; data plane (packet forwarding) was independent and fine.

</details>

---

**Sources**
- `kube-controller-manager` flag reference — <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/>
- Controllers (architecture) — <https://kubernetes.io/docs/concepts/architecture/controller/>
- Node controller & taint-based eviction — <https://kubernetes.io/docs/concepts/architecture/nodes/#node-controller> and <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/#taint-based-evictions>
- Static Pods — <https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/>
- CertificateSigningRequests — <https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/>
- KCA curriculum — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>