# 2.2 Troubleshoot cluster components

**Certification:** CKA v1.35 · **Exam Weight:** 6%

## Introduction

Cluster components comprise the processes forming the control plane (`kube-apiserver`, `kube-scheduler`, `kube-controller-manager`, `etcd`) and worker nodes (`kubelet`, `kube-proxy`, container runtime). In clusters deployed via `kubeadm` — the primary setup tested on the exam — control plane components run as **static Pods** managed directly by the local `kubelet` on each control plane node rather than through the API server. Understanding this architecture is crucial for troubleshooting: if the API server crashes, `kubectl` fails, requiring operating system level tools (`systemctl`, `journalctl`, `crictl`, and manual manifest editing) to restore services.

## Architecture: Control Plane Static Pods

In `kubeadm` clusters, control plane static pod manifests reside in:

```bash
ls /etc/kubernetes/manifests/
# etcd.yaml
# kube-apiserver.yaml
# kube-controller-manager.yaml
# kube-scheduler.yaml
```

The kubelet watches this directory (`staticPodPath` in `/var/lib/kubelet/config.yaml`) and automatically launches or restarts Pods whenever files change. Key implications:

- Editing a manifest file triggers instant component reloads without executing `kubectl apply`.
- Components stuck in crash loops usually indicate manifest issues (typos in CLI flags, non-existent container image tags, or missing/invalid certificate paths).
- Static Pods appear in `kubectl get pods -n kube-system` suffixed by node names (e.g. `kube-apiserver-controlplane`), and **cannot be deleted via `kubectl delete`** (kubelet instantly recreates them). Removing static Pods requires moving the manifest file out of `/etc/kubernetes/manifests/`.

## Verifying Overall Cluster Health

```bash
kubectl get nodes
kubectl get pods -n kube-system -o wide
kubectl cluster-info
```

Expected output for healthy clusters:

```
NAME             STATUS   ROLES           AGE   VERSION
controlplane     Ready    control-plane   10d   v1.35.0
node01           Ready    <none>          10d   v1.35.0
```

When a control plane component fails:

```
NAME                                READY   STATUS             RESTARTS   AGE
kube-apiserver-controlplane         0/1     CrashLoopBackOff   5          3m
etcd-controlplane                  1/1     Running            0          10d
kube-scheduler-controlplane         1/1     Running            0          10d
kube-controller-manager-controlplane 1/1   Running            0          10d
```

`kubectl get componentstatuses` (`kubectl get cs`) is **deprecated** since 1.19 and frequently returns stale or empty responses; avoid using it during the exam.

## Troubleshooting Unresponsive `kubectl`

If `kubectl get nodes` hangs or returns `connection refused`, `kube-apiserver` is unreachable. Since `kubectl` is unusable, access the control plane node directly:

```bash
# Verify kubelet service status
systemctl status kubelet

# Inspect kubelet logs (managing static pods)
journalctl -u kubelet -f
journalctl -u kubelet --since "10 min ago" | grep -i error

# Inspect running containers via container runtime (containerd)
crictl ps -a
crictl logs <container-id>
```

Typical error in `crictl ps -a` when a static manifest includes an invalid argument:

```
CONTAINER ID   IMAGE                        CREATED         STATE      NAME             ATTEMPT
a1b2c3d4e5f6   registry.k8s.io/kube-apiserver   10s ago     Exited     kube-apiserver   6
```

```bash
crictl logs a1b2c3d4e5f6
# Error: unknown flag: --secure-port-typo
```

To resolve, edit `/etc/kubernetes/manifests/kube-apiserver.yaml`, correct the flag, and save the file. Kubelet automatically detects changes and recreates the Pod without service restarts.

## Common Component Failure Causes

### kube-apiserver
- Invalid or misspelled CLI flags in manifest files.
- Expired certificates or invalid paths (`--tls-cert-file`, `--client-ca-file`, `--etcd-cafile`, etc.) — check expiration via:
  ```bash
  openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
  ```
- etcd connectivity failures (etcd offline or `--etcd-servers` misconfigured).
- Port 6443 conflicts.

### etcd
```bash
kubectl exec -n kube-system etcd-controlplane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```
Healthy response:
```
127.0.0.1:2379 is healthy: successfully committed proposal: took = 12ms
```
If etcd fails to start, check host disk space (`df -h /var/lib/etcd`), data corruption, or verify manifest `--data-dir` matches mounted host volumes.

### kube-scheduler / kube-controller-manager
Failures break workload scheduling or controller reconciliation (e.g. Deployments failing to create Pods or nodes remaining in Ready status after timeouts). Diagnostic steps:
```bash
kubectl logs -n kube-system kube-scheduler-controlplane
kubectl logs -n kube-system kube-controller-manager-controlplane
```
Look for failed leader election logs or API server connection drops.

### kubelet (All Nodes)
When a node transitions to `NotReady`:
```bash
kubectl describe node node01
# Conditions: Ready=False, KubeletNotReady, PLEG is not healthy
```
On the affected node:
```bash
systemctl status kubelet
journalctl -u kubelet -n 100 --no-pager
```
Typical causes:
- Inactive kubelet service (`systemctl start kubelet`) or startup failures due to invalid `/var/lib/kubelet/config.yaml`.
- Container runtime outage — verify `containerd`/`crio` with `systemctl status containerd`.
- Expired kubelet client certificates (`/var/lib/kubelet/pki/kubelet-client-current.pem`).
- Missing or invalid CNI plugin configuration inside `/etc/cni/net.d/`.

### kube-proxy
If Services fail to route traffic to Pods while Pods report `Running` status:
```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system kube-proxy-xxxxx
```
Verify iptables/IPVS rule synchronization:
```bash
iptables -t nat -L KUBE-SERVICES -n | head
```
If rules are missing, restart the kube-proxy DaemonSet Pod (`kubectl delete pod` forces recreation since it runs as a standard DaemonSet rather than a static Pod).

## Exam Diagnostic Workflow

1. Run `kubectl get nodes` and `kubectl get pods -n kube-system` first to isolate failing components.
2. If `kubectl` is completely unresponsive → SSH to control plane node, utilizing `systemctl`/`journalctl`/`crictl`.
3. Execute `kubectl describe pod <component>-<node> -n kube-system` to inspect events and exit codes (`Last State: Terminated, Reason: Error`).
4. Execute `kubectl logs <component>-<node> -n kube-system` or `crictl logs` to inspect runtime stdout/stderr.
5. Errors typically stem from static manifests (`/etc/kubernetes/manifests/*.yaml`) or certificate paths (`/etc/kubernetes/pki/`).
6. After editing static manifests, wait briefly for kubelet automatic reloads without issuing `kubectl apply` or restarting system services.

## References

- Troubleshoot Clusters: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Static Pods: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Troubleshooting kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/
- etcd maintenance guide: https://etcd.io/docs/v3.5/op-guide/maintenance/
- kubelet reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
