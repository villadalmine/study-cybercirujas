# Guided Exercises — 4.6 Understand extension interfaces (CNI, CSI, CRI, etc.)

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster running `containerd` with `crictl` installed on node hosts.

---

## Exercise 1 — Container Runtime Interface (CRI)

1. Inspect `kubelet` process arguments for socket paths:
   ```bash
   ps -ef | grep kubelet | grep -o 'container-runtime-endpoint=[^ ]*'
   ```
2. Verify `crictl` endpoint configuration:
   ```bash
   cat /etc/crictl.yaml
   ```
3. List active containers at the runtime level:
   ```bash
   sudo crictl ps
   sudo crictl ps -a
   ```
4. List active Pod sandboxes:
   ```bash
   sudo crictl pods
   ```
5. Inspect container runtime metadata:
   ```bash
   sudo crictl inspect <container-id>
   ```

---

## Exercise 2 — Container Network Interface (CNI)

1. Inspect active node CNI configurations:
   ```bash
   ls /etc/cni/net.d/
   cat /etc/cni/net.d/*.conflist
   ```
2. List available CNI plugin binaries:
   ```bash
   ls /opt/cni/bin/
   ```
3. Inspect CNI DaemonSet status:
   ```bash
   kubectl get daemonset -n kube-system
   ```

---

## Exercise 3 — Container Storage Interface (CSI)

1. List registered CSI drivers:
   ```bash
   kubectl get csidrivers
   kubectl get csinodes
   ```
2. Inspect volume attachment objects:
   ```bash
   kubectl get volumeattachments
   ```

---

<details>
<summary>View Answers</summary>

1. `dockershim` was removed in v1.24, requiring all container runtimes to natively implement CRI.
2. CNI configuration files use JSON format, specifying executable binary names under `plugins[].type`.
3. CSI node plugins run as DaemonSets to manage local host node volume mounts.

</details>
