# 2.1 Troubleshoot clusters and nodes

## Introduction

Troubleshooting clusters and nodes is a core competency on the CKA exam: it requires diagnosing why a node is in a `NotReady` state, why control plane components fail to start, or why the overall cluster becomes unresponsive — using only tools directly available on the node (`systemd`, `journalctl`, `crictl`) and `kubectl`. Unlike application (workload) troubleshooting, the focus here is strictly on cluster infrastructure: `kubelet`, container runtimes, control plane static pods, and `etcd`.

## General Cluster Diagnosis

The first step is retrieving a top-level view of cluster health:

```bash
kubectl get nodes -o wide
kubectl cluster-info
kubectl get pods -n kube-system -o wide
kubectl get events -A --sort-by=.metadata.creationTimestamp
```

Typical output showing an unhealthy node:

```
NAME       STATUS     ROLES           AGE   VERSION
master1    Ready      control-plane   40d   v1.35.0
worker1    NotReady   <none>          40d   v1.35.0
worker2    Ready      <none>          40d   v1.35.0
```

`kubectl describe node <node>` is the most critical diagnostic command for analyzing node status: it displays `Conditions`, `Taints`, `Allocatable` resources, `Events`, and `kubelet`/container runtime versions.

```bash
kubectl describe node worker1
```

```
Conditions:
  Type             Status  Reason
  ----             ------  ------
  MemoryPressure   False   KubeletHasSufficientMemory
  DiskPressure     False   KubeletHasNoDiskPressure
  PIDPressure      False   KubeletHasSufficientPID
  Ready            False   KubeletNotReady
Taints:            node.kubernetes.io/not-ready:NoSchedule
```

## Node Conditions and Automatic Taints

Kubernetes reports five standard conditions per node: `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure`, and `NetworkUnavailable`. When a pressure condition becomes `True` (or `Ready` transitions to `False` or `Unknown`), the node controller automatically applies matching taints (`node.kubernetes.io/not-ready`, `node.kubernetes.io/memory-pressure`, `node.kubernetes.io/disk-pressure`, etc.), preventing new Pods from scheduling unless explicit tolerations exist.

If a node enters `Unknown` state (kubelet stops sending heartbeats), after `--node-monitor-grace-period` (default 40s) the node controller marks it unhealthy. Following `pod-eviction-timeout` (default 5m), it initiates pod evictions.

## Kubelet Troubleshooting

`kubelet` runs as a systemd service directly on each node (not inside a Pod). It is the first component to inspect when a node transitions to `NotReady`:

```bash
systemctl status kubelet
journalctl -u kubelet -f
journalctl -u kubelet --since "10 min ago" | grep -i error
```

Frequent failure causes:

- **Expired certificates**: Client certificates stored in `/var/lib/kubelet/pki/kubelet-client-current.pem`.
- **Stopped or misconfigured container runtime**: `/var/lib/kubelet/config.yaml` specifying an invalid `containerRuntimeEndpoint`.
- **cgroup driver mismatch**: Divergence between kubelet and container runtime configuration (`cgroupfs` vs `systemd`). Typical log entry: `misconfiguration: kubelet cgroup driver ... is different from docker cgroup driver`.
- **Active swap space**: System swap enabled without setting `failSwapOn: false` in kubelet configuration.
- **Disk space exhaustion**: `DiskPressure` triggered by full filesystems (`df -h`, `du -sh /var/lib/kubelet`).

Inspect and modify kubelet configuration:

```bash
cat /var/lib/kubelet/config.yaml
systemctl daemon-reload
systemctl restart kubelet
```

## Container Runtime Troubleshooting with `crictl`

`crictl` is the standard CLI tool for inspecting container runtime engines at low level (compatible with containerd and CRI-O). Configured via `/etc/crictl.yaml`:

```yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
```

Essential commands:

```bash
crictl ps -a
crictl pods
crictl logs <container-id>
crictl inspect <container-id>
systemctl status containerd
```

## Control Plane Troubleshooting (Static Pods)

Control plane components deployed via `kubeadm` run as **static pods**, managed via manifest files monitored directly by kubelet inside `/etc/kubernetes/manifests/` (bypassing API server processing). If `kube-apiserver` fails, `kubectl` stops functioning; diagnosis must occur directly on the control plane node.

```bash
ls /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

If static pods fail to launch, inspect kubelet logs and runtime engine status via `crictl`:

```bash
crictl ps -a | grep kube-apiserver
crictl logs <container-id>
journalctl -u kubelet | grep apiserver
```

Common static pod manifest errors:

- Misconfigured argument flags or invalid certificate file paths (`--etcd-certfile`, `--tls-cert-file`).
- Invalid YAML syntax or indentation errors (causing kubelet to ignore manifest files silently).
- Port binding conflicts.

Once `kube-apiserver` responds, inspect control plane Pods via `kubectl`:

```bash
kubectl get pods -n kube-system
kubectl logs -n kube-system kube-apiserver-master1
kubectl logs -n kube-system kube-scheduler-master1
kubectl logs -n kube-system kube-controller-manager-master1
```

## etcd Troubleshooting

`etcd` stores complete cluster state; failures in etcd crash cluster control operations. Verify cluster health using `etcdctl` referencing local PKI certificates:

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

ETCDCTL_API=3 etcdctl ... member list
ETCDCTL_API=3 etcdctl ... endpoint status --write-out=table
```

Expected healthy output:

```
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 12.345ms
```

On multi-member etcd clusters suffering quorum loss, review `journalctl` output for the etcd static pod and verify inter-node network connectivity (`member list` must show all members in `started` state).

## Network and DNS Troubleshooting

Cluster networking issues present as Pods stuck in `Pending` or `ContainerCreating` states, or Pods in `Running` state lacking inter-pod communication.

**CNI Plugin:**

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|flannel|cilium'
cat /etc/cni/net.d/*.conf
journalctl -u kubelet | grep -i cni
```

Common CNI error: `NetworkPlugin cni failed to set up pod ... network: open /etc/cni/net.d: no such file or directory`, indicating CNI plugin daemonsets failed or were omitted during cluster initialization.

**kube-proxy:**

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system kube-proxy-xxxxx
iptables -L -t nat | grep KUBE-SVC   # iptables mode
ipvsadm -Ln                          # IPVS mode
```

**CoreDNS:**

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --rm -it -- \
  nslookup kubernetes.default
```

If DNS resolution fails for Pods while node networking operates normally, inspect `kube-system/kube-dns` Service endpoints, the `coredns` ConfigMap, and confirm container `/etc/resolv.conf` targets `clusterDNS` addresses configured in kubelet.

## Cluster Certificates

Certificates generated via `kubeadm` expire after 1 year by default. Expiration causes sudden control plane communication failure:

```bash
kubeadm certs check-expiration
kubeadm certs renew all
systemctl restart kubelet
```

Following renewal, restart static pods (kubelet automatically recreates static pods when mounted certificate files change). If API server certificates are renewed, update `~/.kube/config` and `/etc/kubernetes/admin.conf`.

## Cordoning and Draining Nodes for Maintenance

Before performing node maintenance or troubleshooting interventions, isolate the node from scheduler placement:

```bash
kubectl cordon worker1
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
# ... perform maintenance / node reboot ...
kubectl uncordon worker1
```

`cordon` marks the node `SchedulingDisabled` without altering existing workloads; `drain` evicts workloads (honoring PodDisruptionBudgets) and prevents new pod placements.

## In-Situ Inspection with `kubectl debug`

When direct SSH access is restricted, `kubectl debug` launches interactive containers attached to node host namespaces:

```bash
kubectl debug node/worker1 -it --image=busybox:1.36
# Inside debug container, host filesystem is mounted at /host
chroot /host
```

## Practical Scenario: Node NotReady Due to Expired Kubelet Certificate

```bash
$ kubectl get nodes
NAME      STATUS     ROLES    AGE   VERSION
worker1   NotReady   <none>   400d  v1.35.0

$ journalctl -u kubelet --since "5 min ago" | tail
... "Failed to connect to apiserver" err="x509: certificate has expired or is not yet valid"

$ ls -la /var/lib/kubelet/pki/
-rw------- 1 root root 1273 Jan 10  2025 kubelet-client-2025-01-10.pem

$ kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME
kubelet.conf                Jan 10, 2026 10:00 UTC   EXPIRED

# Resolution: renew certificates and restart kubelet
$ kubeadm certs renew all
$ systemctl restart kubelet
$ kubectl get nodes
NAME      STATUS   ROLES    AGE   VERSION
worker1   Ready    <none>   400d  v1.35.0
```

## References

- Troubleshooting Clusters: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Troubleshooting kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/
- Debug Pods and ReplicationControllers: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods-replication-controller/
- Node conditions: https://kubernetes.io/docs/concepts/architecture/nodes/#condition
- Static Pods: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- etcd operations guide: https://etcd.io/docs/v3.5/op-guide/
- crictl reference: https://kubernetes.io/docs/reference/tools/map-crictl-dockercli/
- kubectl debug reference: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Certificate Management with kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
