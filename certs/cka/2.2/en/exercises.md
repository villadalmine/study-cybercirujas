# Guided Exercises: Troubleshoot cluster components (CKA 2.2)

> Reference Source: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

These exercises assume a kubeadm cluster with at least one control-plane node and one worker node, SSH access to both, and configured `kubectl` (cluster-admin).

---

## Exercise 1 — Diagnosing a Node in `NotReady` State (Kubelet)

1. Verify cluster node status:
   ```bash
   kubectl get nodes -o wide
   ```
2. SSH into a worker node and check if the `kubelet` process is active:
   ```bash
   systemctl status kubelet
   ```
3. If status displays `inactive` or `failed`, inspect recent service logs:
   ```bash
   journalctl -u kubelet -n 100 --no-pager
   ```
4. Confirm systemd `kubelet` configuration files exist and point to valid API server configurations:
   ```bash
   cat /var/lib/kubelet/config.yaml
   cat /etc/kubernetes/kubelet.conf
   ```
5. Simulate a failure cause: temporarily rename `kubelet.conf` and restart the service:
   ```bash
   sudo mv /etc/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf.bak
   sudo systemctl restart kubelet
   journalctl -u kubelet -n 20 --no-pager
   ```
6. Restore configuration file and confirm recovery:
   ```bash
   sudo mv /etc/kubernetes/kubelet.conf.bak /etc/kubernetes/kubelet.conf
   sudo systemctl restart kubelet
   systemctl status kubelet
   ```
7. Confirm node transitions back to `Ready` status from control-plane terminal:
   ```bash
   kubectl get node <node-name> -w
   ```

**Comprehension Questions**

- Why does a `kubelet` running without a valid `kubeconfig` fail to transition the node into `Ready` status even if the process remains active?
- Which log or condition sources should be inspected if disk space or PID limits cause node degradation?

---

## Exercise 2 — Control Plane Component Failures (Static Pods)

1. SSH into the control-plane node and list static pod manifests:
   ```bash
   ls -l /etc/kubernetes/manifests/
   ```
2. Confirm `kubelet` watches this directory as `staticPodPath`:
   ```bash
   grep -A2 staticPodPath /var/lib/kubelet/config.yaml
   ```
3. List control plane pods in `kube-system` namespace via `kubectl`:
   ```bash
   kubectl get pods -n kube-system -o wide | grep -E "kube-apiserver|kube-scheduler|kube-controller-manager|etcd"
   ```
4. Induce controlled failure: edit `kube-scheduler` manifest introducing an invalid flag (`- --this-flag-no-existe=true`):
   ```bash
   sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml
   ```
5. Observe `kubelet` attempting static pod recreation:
   ```bash
   kubectl get pods -n kube-system -w
   ```
6. When the pod enters `CrashLoopBackOff` or `Error`, inspect container runtime logs via `crictl`:
   ```bash
   kubectl describe pod -n kube-system <pod-kube-scheduler>
   sudo crictl ps -a | grep scheduler
   sudo crictl logs <container-id>
   ```
7. Revert manifest modifications and verify recovery:
   ```bash
   sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml
   kubectl get pods -n kube-system -w
   ```

**Comprehension Questions**

- Why does modifying files inside `/etc/kubernetes/manifests/` trigger automatic reloads without issuing `kubectl apply`?
- If `kube-apiserver` crashes, why is `kubectl logs` unreliable, and what container runtime tool replaces it?

---

## Exercise 3 — `etcd` Health Verification

1. Inspect static pod manifest for `etcd` to identify TLS certificates and endpoints:
   ```bash
   cat /etc/kubernetes/manifests/etcd.yaml | grep -E "cert-file|key-file|trusted-ca-file|listen-client-urls"
   ```
2. Run health checks using `etcdctl` referencing identified PKI certificates:
   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     endpoint health
   ```
3. List cluster members to rule out quorum loss:
   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     member list
   ```
4. Verify disk space utilization for `etcd` data directories:
   ```bash
   du -sh /var/lib/etcd
   df -h /var/lib/etcd
   ```
5. Review `etcd` container logs for disk latency warnings:
   ```bash
   sudo crictl ps -a | grep etcd
   sudo crictl logs <container-id-etcd> 2>&1 | grep -i "slow\|wal"
   ```

**Comprehension Questions**

- Why might `endpoint health` report `healthy` on an individual etcd member while the complete cluster loses quorum?
- How does high disk latency correlate with `apply request took too long` log warnings in etcd?

---

## Exercise 4 — `kube-proxy` and Node-Level Networking

1. Confirm `kube-proxy` runs as a DaemonSet across all nodes:
   ```bash
   kubectl get daemonset -n kube-system kube-proxy
   kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
   ```
2. Inspect worker node `kube-proxy` pod logs:
   ```bash
   kubectl logs -n kube-system <pod-kube-proxy-worker>
   ```
3. SSH into worker node to inspect proxy modes (`iptables` / `ipvs`) and generated rules:
   ```bash
   sudo cat /var/lib/kube-proxy/config.conf | grep mode
   sudo iptables -t nat -L KUBE-SERVICES -n | head -20
   ```
4. Deploy test Deployment and `ClusterIP` Service to test network resolution:
   ```bash
   kubectl create deployment web-test --image=nginx --replicas=1
   kubectl expose deployment web-test --port=80
   kubectl run test-client --rm -it --image=busybox --restart=Never -- wget -qO- web-test.default.svc.cluster.local
   ```
5. If DNS fails, test direct IP routing to isolate CoreDNS vs `kube-proxy` failures:
   ```bash
   kubectl get svc web-test -o jsonpath='{.spec.clusterIP}'
   kubectl run test-client2 --rm -it --image=busybox --restart=Never -- wget -qO- <clusterIP>:80
   ```

**Comprehension Questions**

- If `wget` to `ClusterIP` succeeds but DNS name resolution fails, which component requires investigation?
- Why might restarting a `kube-proxy` pod temporarily resolve iptables rule desynchronization without fixing root causes?

---

## Exercise 5 — Control Plane Certificate Renewals

1. Inspect expiration dates for `kubeadm` certificates:
   ```bash
   sudo kubeadm certs check-expiration
   ```
2. Inspect `kube-apiserver` certificate validity dates directly:
   ```bash
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -issuer -dates
   ```
3. Renew certificates via `kubeadm`:
   ```bash
   sudo kubeadm certs renew apiserver
   ```
4. Force static pod reloads by temporarily moving manifest files:
   ```bash
   sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
   sleep 5
   sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
   ```
5. Confirm API server health following certificate renewal:
   ```bash
   kubectl get --raw='/readyz?verbose'
   ```

**Comprehension Questions**

- Why does toggling manifest location in `/etc/kubernetes/manifests/` force `kubelet` to recreate static pods with updated certificate mounts?
- What distinguishes `x509: certificate has expired` from `x509: certificate signed by unknown authority` during troubleshooting?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- Without a valid `kubeconfig`, kubelet cannot authenticate to API servers to report node heartbeats, causing API servers to list nodes as `NotReady`.
- Inspect `/var/log/syslog`, `dmesg`, and `kubectl describe node` to evaluate `DiskPressure`, `MemoryPressure`, and `PIDPressure`.

**Exercise 2**
- `kubelet` filesystem watchers monitor `staticPodPath` (`/etc/kubernetes/manifests/`), triggering pod recreation immediately upon file updates.
- If `kube-apiserver` fails, API proxies collapse. Direct container runtime tools (`crictl ps`, `crictl logs`) replace `kubectl logs`.

**Exercise 3**
- `endpoint health` evaluates single member status (local WAL writes), whereas cluster quorum requires active majority agreement (`N/2 + 1`).
- High disk I/O latency delays WAL disk commits, triggering `apply request took too long` warnings in etcd logs.

**Exercise 4**
- Focus shifts to CoreDNS. Successful `ClusterIP` connectivity confirms `kube-proxy` routing rules function properly, isolating failure to DNS name resolution.
- Restarting `kube-proxy` forces full iptables/IPVS rule resynchronization against API server states, but fails to fix underlying network drop causes.

**Exercise 5**
- Removing manifests signals kubelet to terminate static pods; restoring manifests forces kubelet to mount newly renewed PKI certificate assets from disk.
- `certificate has expired` requires renewing certificate validity windows via `kubeadm certs renew`. `signed by unknown authority` indicates trust chain mismatches requiring CA configuration updates.

</details>
