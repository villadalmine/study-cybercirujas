# Guided Exercises: Troubleshoot clusters and nodes (CKA 2.1)

> Reference Source: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

These exercises assume a kubeadm cluster with at least one control-plane node and one worker node, SSH access to both, and configured `kubectl`.

---

## Exercise 1: Diagnose a Node in `NotReady` State

1. List cluster nodes and observe statuses:
   ```bash
   kubectl get nodes -o wide
   ```
2. Select a target node (or simulate failure by stopping kubelet in step 4) and describe its `Conditions`:
   ```bash
   kubectl describe node <node-name>
   ```
3. Under `Conditions`, evaluate `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure`, and `NetworkUnavailable` statuses, then review `Events` at the end of the output.
4. To simulate a real `NotReady` failure, SSH into the worker node and stop `kubelet`:
   ```bash
   sudo systemctl stop kubelet
   ```
5. From the control-plane node, run `kubectl get nodes` every 10–15 seconds and measure how long until the node enters `NotReady` status (control plane waits `--node-monitor-grace-period`, ~40s, before marking unready).

**Comprehension Questions:**
- Which control plane component updates node status when heartbeats stop arriving?
- If `Ready` displays `Unknown` instead of `False`, what does that reveal regarding failure causes?

---

## Exercise 2: Investigate Kubelet with `systemctl` and `journalctl`

1. On the worker where kubelet was stopped (Exercise 1), inspect service status:
   ```bash
   sudo systemctl status kubelet
   ```
2. Review recent kubelet service logs:
   ```bash
   sudo journalctl -u kubelet -n 100 --no-pager
   ```
3. Stream logs in real time while restarting the service:
   ```bash
   sudo journalctl -u kubelet -f &
   sudo systemctl start kubelet
   ```
4. Filter for error priority log entries to pinpoint failures quickly:
   ```bash
   sudo journalctl -u kubelet -p err --no-pager
   ```
5. Confirm node returns to `Ready` status from the control-plane node:
   ```bash
   kubectl get nodes
   ```

**Comprehension Questions:**
- Why is `journalctl -u kubelet` the primary diagnostic tool (over `kubectl logs`) when nodes enter `NotReady`?
- Where is the kubelet configuration file located that `systemctl` uses during startup, and which command displays active startup flags?

---

## Exercise 3: Container Runtime Troubleshooting with `crictl`

1. On the worker node, verify the container runtime engine (containerd) is active:
   ```bash
   sudo systemctl status containerd
   ```
2. Use `crictl` to list pods known to the runtime engine directly (bypassing Kubernetes API):
   ```bash
   sudo crictl pods
   ```
3. List container instances and statuses:
   ```bash
   sudo crictl ps -a
   ```
4. If containers display `Exited` or `Error` states, inspect details and runtime logs:
   ```bash
   sudo crictl inspect <container-id>
   sudo crictl logs <container-id>
   ```
5. Confirm `crictl` socket endpoint matches kubelet configuration (`--container-runtime-endpoint`):
   ```bash
   cat /var/lib/kubelet/config.yaml | grep -i containerRuntimeEndpoint
   ```

**Comprehension Questions:**
- Under what conditions does `crictl ps` reveal details unexposed by `kubectl get pods`?
- What error message appears in kubelet logs if container runtime socket (`/run/containerd/containerd.sock`) is missing or unresponsive?

---

## Exercise 4: Troubleshooting Control Plane Components (Static Pods)

1. On the control-plane node, list static pod manifest files:
   ```bash
   ls -la /etc/kubernetes/manifests/
   ```
2. Confirm `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, and `etcd` run inside `kube-system` namespace:
   ```bash
   kubectl get pods -n kube-system -o wide
   ```
3. Induce intentional failure: edit `kube-scheduler` manifest and introduce an invalid container image tag typo:
   ```bash
   sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/kube-scheduler.yaml.bak
   sudo sed -i 's|image: .*kube-scheduler.*|image: registry.k8s.io/kube-scheduler:vX.Y.Z-typo|' /etc/kubernetes/manifests/kube-scheduler.yaml
   ```
4. Observe local kubelet detecting manifest changes and attempting static pod recreation:
   ```bash
   watch crictl ps -a
   ```
5. Diagnose failure using `kubectl describe` and container logs:
   ```bash
   kubectl describe pod -n kube-system kube-scheduler-<node-name>
   crictl logs $(sudo crictl ps -a --name kube-scheduler -q | head -1)
   ```
6. Restore original manifest and confirm recovery:
   ```bash
   sudo cp /tmp/kube-scheduler.yaml.bak /etc/kubernetes/manifests/kube-scheduler.yaml
   kubectl get pods -n kube-system -l component=kube-scheduler
   ```

**Comprehension Questions:**
- Why can you continue using `kubectl` to inspect the broken `kube-scheduler` pod when scheduler operations are halted?
- Which system process monitors `/etc/kubernetes/manifests/` and recreates static pods, and what is the object mirrored into the API called?

---

## Exercise 5: Node Resource Pressure (`DiskPressure` / `MemoryPressure`)

1. Inspect eviction threshold settings configured in worker node kubelet settings:
   ```bash
   cat /var/lib/kubelet/config.yaml | grep -A5 evictionHard
   ```
2. Simulate disk pressure artificially on the worker node:
   ```bash
   sudo fallocate -l 5G /tmp/fill-disk.img
   ```
3. From control-plane node, observe `DiskPressure` condition activation:
   ```bash
   kubectl describe node <worker-name> | grep -A10 Conditions
   ```
4. Inspect node events and evicted pod statuses:
   ```bash
   kubectl get events --field-selector involvedObject.kind=Node -A
   kubectl get pods -A --field-selector status.phase=Failed
   ```
5. Remove file asset and confirm condition returns to `False`:
   ```bash
   sudo rm /tmp/fill-disk.img
   kubectl describe node <worker-name> | grep -A10 Conditions
   ```

**Comprehension Questions:**
- How does kubelet prioritize pod evictions for `BestEffort` vs `Guaranteed` Quality of Service (QoS) classes under `DiskPressure` or `MemoryPressure`?
- What distinguishes node resource eviction from container `OOMKilled` terminations?

---

## Exercise 6: Verifying Cluster Certificate Health and Expiration

1. On control-plane node, check expiration dates across kubeadm-managed certificates:
   ```bash
   sudo kubeadm certs check-expiration
   ```
2. Verify API server certificate directly via `openssl`:
   ```bash
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
   ```
3. If `kubectl` returns `x509: certificate has expired`, test direct API endpoint connectivity:
   ```bash
   curl -k https://localhost:6443/healthz
   ```
4. Renew cluster certificates via kubeadm:
   ```bash
   sudo kubeadm certs renew all
   ```
5. Restart control plane static pods by temporarily toggling manifest locations:
   ```bash
   sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
   sleep 5
   sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
   ```

**Comprehension Questions:**
- Why does `x509: certificate has expired` break `kubectl` operations while application pods continue running uninterrupted?
- What distinguishes `kubeadm certs renew` from regenerating certificates via `kubeadm init phase certs`?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- `node-controller` inside `kube-controller-manager` updates node conditions when `NodeStatus` heartbeats fail to arrive.
- `Unknown` indicates API server connectivity loss to kubelet (missing heartbeats), whereas `False` indicates active reporting of failing conditions.

**Exercise 2**
- `kubectl logs` requires active API server to kubelet communication; when kubelet is stopped, API channels fail. `journalctl` accesses local systemd service logs directly.
- Configuration resides in `/var/lib/kubelet/config.yaml` (startup flags reside in systemd units `/etc/systemd/system/kubelet.service.d/`). Active flags display via `ps aux | grep kubelet` or `systemctl cat kubelet`.

**Exercise 3**
- When API servers are unreachable or nodes are isolated, `crictl ps` interacts directly with local container runtime sockets displaying real-time container states.
- Kubelet logs report `RunPodSandbox` errors or `rpc error: code = Unavailable desc = connection error` when runtime endpoints fail.

**Exercise 4**
- API servers remain healthy reading state from etcd; scheduler outages halt new pod placements without disrupting API operations.
- Local `kubelet` monitors `staticPodPath` (`/etc/kubernetes/manifests/`). API representations are called **mirror pods**, suffixed with `-<node-name>`.

**Exercise 5**
- Kubelet evicts `BestEffort` pods first, followed by `Burstable` pods exceeding resource requests. `Guaranteed` pods are evicted last.
- Node eviction is a pod-level decision enforced by kubelet eviction managers during resource pressure; `OOMKilled` is a Linux kernel cgroup action terminating single containers exceeding memory limits.

**Exercise 6**
- `kubectl` relies on TLS handshakes with API servers. Certificate expiration fails TLS handshakes before requests process, whereas container workloads operate independently of API TLS certs.
- `kubeadm certs renew` extends validity of existing certs under current CA keys; `kubeadm init phase certs` generates new keys and certificates from scratch.

</details>
