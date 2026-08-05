# CKS 5.4 — Appropriately use kernel hardening tools such as AppArmor and seccomp

**Certification:** Certified Kubernetes Security Specialist (CKS), curriculum **v1.34**
**Domain:** 5. Microservice Vulnerability Minimization — **exam weight of this topic: 2.5 %**
**Format:** guided exercises. Execute every numbered step, then answer the questions in the block before moving on. All answers are collapsed at the end.

---

## What you will be able to do when you finish

1. Explain, at the kernel level, **what seccomp-bpf mediates and what it cannot mediate**, and why AppArmor is the complement rather than the alternative.
2. Distinguish `Unconfined`, `RuntimeDefault` and `Localhost` for **both** `seccompProfile` and `appArmorProfile`, using the GA API fields (not the deprecated annotations).
3. Build a seccomp profile empirically: run in **audit mode**, harvest the syscalls from the kernel audit log, and turn that into an enforcing allowlist.
4. Author, load and iterate an AppArmor profile on a node (`complain` → `enforce`), and attach it to a Pod.
5. Diagnose the four failure modes that actually cost people points in the exam: profile not on the node, wrong `localhostProfile` syntax, container-level override, and Pod Security Admission rejection.

---

## Lab topology and prerequisites

You need a cluster where **you have root on the nodes**. Two options:

| Part | Environment that works | Why |
|---|---|---|
| Blocks 1–5 (seccomp) | `kind` ≥ 0.23, or any kubeadm cluster | Profiles are files; `kind` can bind-mount them into the kubelet seccomp root. |
| Blocks 6–9 (AppArmor) | kubeadm/VM node on **Ubuntu/Debian/SUSE** with AppArmor enabled | AppArmor profiles are loaded into the **host kernel**. Inside `kind`, the node is itself a container and `apparmor_parser` normally cannot load profiles from it. |

> **Reality check for the exam.** The CKS environment gives you SSH to `controlplane` and `node01`, and both are Ubuntu with AppArmor enabled and containerd as the runtime. Everything below matches that shape.

### Step 0.1 — Bootstrap a `kind` cluster with a seccomp profile directory

```bash
mkdir -p ~/cks-54/profiles && cd ~/cks-54

cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: ./profiles
    containerPath: /var/lib/kubelet/seccomp/profiles
- role: worker
  extraMounts:
  - hostPath: ./profiles
    containerPath: /var/lib/kubelet/seccomp/profiles
EOF

kind create cluster --name cks54 --config kind-config.yaml
```

### Step 0.2 — Create the working namespace

```bash
kubectl create namespace cks-54
kubectl config set-context --current --namespace=cks-54
```

Expected:

```
namespace/cks-54 created
Context "kind-cks54" modified.
```

---

## Block 1 — Verify the kernel substrate before you trust any manifest

A `securityContext` field is a *request*. If the kernel or the runtime cannot honour it, you get either a hard failure or — worse — a silent no-op. Always establish the substrate first.

### Step 1.1 — Confirm the kernel was built with seccomp filtering

On a node (`docker exec -it cks54-worker bash`, or SSH):

```bash
grep -E 'CONFIG_SECCOMP=|CONFIG_SECCOMP_FILTER=' /boot/config-$(uname -r) 2>/dev/null \
  || zgrep -E 'CONFIG_SECCOMP=|CONFIG_SECCOMP_FILTER=' /proc/config.gz
```

Expected:

```
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
```

### Step 1.2 — Confirm which LSMs are active, and in what order

```bash
cat /sys/kernel/security/lsm
```

Expected on Ubuntu 22.04/24.04:

```
lockdown,capability,landlock,yama,apparmor,bpf
```

If `apparmor` is absent from that list, AppArmor is compiled but **not enabled**; you would need `apparmor=1 security=apparmor` on the kernel command line. On RHEL-family nodes you will see `selinux` here instead — AppArmor is simply not available.

### Step 1.3 — Confirm the AppArmor userspace and the currently loaded profiles

```bash
sudo aa-status | head -20
```

Expected (abridged):

```
apparmor module is loaded.
apparmor filesystem is mounted.
44 profiles are loaded.
41 profiles are in enforce mode.
   /usr/bin/man
   /usr/lib/snapd/snap-confine
   cri-containerd.apparmor.d
   ...
3 profiles are in complain mode.
17 processes have profiles defined.
```

The authoritative kernel-side view — and the exact file the **kubelet** reads to decide whether it can admit a Pod — is:

```bash
sudo cat /sys/kernel/security/apparmor/profiles | sort | head
```

```
cri-containerd.apparmor.d (enforce)
/usr/bin/man (enforce)
/usr/sbin/chronyd (enforce)
...
```

### Step 1.4 — Check whether the kubelet defaults workloads to `RuntimeDefault`

```bash
ps -o args= -C kubelet | tr ' ' '\n' | grep -i seccomp
grep -i seccomp /var/lib/kubelet/config.yaml
```

If neither prints anything, `seccompDefault` is off and **a Pod with no `seccompProfile` runs with seccomp completely disabled**.

### Step 1.5 — Check which seccomp actions the kernel is willing to log

```bash
cat /proc/sys/kernel/seccomp/actions_avail
cat /proc/sys/kernel/seccomp/actions_logged
```

Expected:

```
kill_process kill_thread trap errno user_notif trace log allow
kill_process kill_thread trap errno user_notif trace log
```

> **Questions — Block 1**
> **Q1.** `CONFIG_SECCOMP_FILTER=y` is present but `CONFIG_SECCOMP=y` is not (hypothetically). What capability would you lose, and which of the two is the one Kubernetes actually depends on?
> **Q2.** Your node shows `selinux` in `/sys/kernel/security/lsm` and no `apparmor`. A Pod manifest carries `appArmorProfile: {type: RuntimeDefault}`. What happens at admission time, and what is the correct remediation in a mixed-OS cluster?
> **Q3.** `actions_logged` does **not** contain `log`. You then deploy a profile whose `defaultAction` is `SCMP_ACT_LOG`. Will the container's syscalls be blocked? Will you see anything in the audit log? Why does this make `actions_logged` a prerequisite check rather than a curiosity?

---

## Block 2 — The three seccomp profile types, observed from inside the container

### Step 2.1 — Deploy a Pod with **no** seccomp configuration

```yaml
# 01-seccomp-none.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-none
  namespace: cks-54
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 01-seccomp-none.yaml
kubectl wait --for=condition=Ready pod/seccomp-none --timeout=60s
kubectl exec seccomp-none -- grep -E '^(Seccomp|Seccomp_filters|NoNewPrivs):' /proc/1/status
```

Expected (assuming `seccompDefault` is off, as in Step 1.4):

```
Seccomp:	0
Seccomp_filters:	0
NoNewPrivs:	0
```

### Step 2.2 — Deploy the same Pod with `RuntimeDefault`

```yaml
# 02-seccomp-runtimedefault.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-rtd
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 02-seccomp-runtimedefault.yaml
kubectl wait --for=condition=Ready pod/seccomp-rtd --timeout=60s
kubectl exec seccomp-rtd -- grep -E '^(Seccomp|Seccomp_filters|NoNewPrivs):' /proc/1/status
```

Expected:

```
Seccomp:	2
Seccomp_filters:	1
NoNewPrivs:	1
```

### Step 2.3 — Prove that `RuntimeDefault` really is blocking something

```bash
kubectl exec seccomp-none -- sh -c 'unshare -U true; echo "exit=$?"'
kubectl exec seccomp-rtd  -- sh -c 'unshare -U true; echo "exit=$?"'
```

Expected (exact errno text varies by runtime version):

```
exit=0
```
```
unshare: unshare(0x10000000): Operation not permitted
exit=1
```

### Step 2.4 — Read the actual filter the runtime installed

On the node:

```bash
CID=$(sudo crictl ps --name app --label io.kubernetes.pod.name=seccomp-rtd -q)
sudo crictl inspect "$CID" | jq '.info.runtimeSpec.linux.seccomp | {defaultAction, defaultErrnoRet, architectures, rules: (.syscalls | length)}'
```

Expected (abridged, containerd):

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 38,
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "rules": 60
}
```

`38` is `ENOSYS`, not `EPERM`. That choice is deliberate and it is one of the most important production lessons in this whole topic — see Q7.

> **Questions — Block 2**
> **Q4.** `/proc/1/status` shows `Seccomp: 2`. What do `0`, `1` and `2` mean, and which one can a container realistically be in other than 0 or 2?
> **Q5.** `NoNewPrivs` flipped from `0` to `1` at the same time the seccomp filter appeared. Why is that not a coincidence? Quote the kernel rule that forces it, and name the one capability that exempts a process from it.
> **Q6.** A colleague argues that `RuntimeDefault` is "the Kubernetes default profile" and therefore identical on every cluster. Correct that statement precisely: who owns the profile, where does it live, and what does that imply for a manifest that must behave identically on containerd and CRI-O?
> **Q7.** The containerd default profile returns `ENOSYS` (38) for syscalls it does not know about, but `EPERM` (1) for syscalls it explicitly denies. Explain the failure mode that `ENOSYS` prevents when a container built against a new glibc runs on a node with an older profile.

---

## Block 3 — Discovering the syscalls a workload really needs (audit mode)

You never author an allowlist from imagination. You author it from evidence.

### Step 3.1 — Write an audit-only profile onto the node

On your workstation (the directory is bind-mounted into both nodes):

```bash
cat > ~/cks-54/profiles/audit.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_LOG"
}
EOF
```

On a kubeadm cluster instead, copy it to **every node** at `/var/lib/kubelet/seccomp/profiles/audit.json`.

### Step 3.2 — Run the workload under the audit profile

```yaml
# 03-seccomp-audit.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-audit
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/audit.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 03-seccomp-audit.yaml
kubectl wait --for=condition=Ready pod/seccomp-audit --timeout=60s

# Generate a small, known set of syscalls
kubectl exec seccomp-audit -- sh -c 'mkdir -p /tmp/demo && touch /tmp/demo/f && chmod 600 /tmp/demo/f && ls -l /tmp/demo'
```

Expected:

```
-rw-------    1 root     root             0 Aug  4 10:12 /tmp/demo/f
```

Nothing was blocked — `SCMP_ACT_LOG` **allows and records**.

### Step 3.3 — Harvest the evidence from the node's kernel log

```bash
sudo journalctl -k --since "-5 min" | grep -i 'seccomp\|audit(' | tail -20
# or, where journald is not collecting kernel audit records:
sudo dmesg | grep -i seccomp | tail -20
# or, with auditd installed:
sudo ausearch -m SECCOMP -ts recent -i | tail -40
```

Expected (one line per distinct syscall, wrapped here for readability):

```
audit: type=1326 audit(1785838352.114:277): auid=4294967295 uid=0 gid=0 ses=4294967295
  pid=31465 comm="chmod" exe="/bin/busybox" sig=0 arch=c000003e syscall=268 compat=0
  ip=0x7f1c9d2a4b27 code=0x7ffc0000
```

### Step 3.4 — Translate the numbers into names

```bash
ausyscall x86_64 268        # from the auditd package
scmp_sys_resolver -a x86_64 268   # from libseccomp-tools
```

```
fchmodat
```

Decode the rest of the record:

| Field | Value | Meaning |
|---|---|---|
| `type=1326` | — | `AUDIT_SECCOMP` |
| `arch=c000003e` | — | `AUDIT_ARCH_X86_64` (`0xc000003e`) |
| `syscall=268` | `fchmodat` | The syscall number **for that arch** |
| `code=0x7ffc0000` | — | `SECCOMP_RET_LOG` |
| `comm` / `exe` | `chmod` | The offending binary — your fastest lead |

Other `code` values you must recognise on sight:

| `code` | Constant | Effect |
|---|---|---|
| `0x00000000` | `SECCOMP_RET_KILL_THREAD` | Thread killed with `SIGSYS` |
| `0x80000000` | `SECCOMP_RET_KILL_PROCESS` | Whole thread group killed |
| `0x00030000` | `SECCOMP_RET_TRAP` | `SIGSYS` delivered to the process |
| `0x00050001` | `SECCOMP_RET_ERRNO` \| `EPERM` | Syscall returns `-EPERM` |
| `0x7ffc0000` | `SECCOMP_RET_LOG` | Allowed, logged |
| `0x7fff0000` | `SECCOMP_RET_ALLOW` | Allowed, never logged |

### Step 3.5 — Turn the harvest into a candidate allowlist

```bash
sudo journalctl -k --since "-10 min" \
  | grep -oP 'syscall=\K[0-9]+' | sort -un \
  | while read -r n; do scmp_sys_resolver -a x86_64 "$n"; done \
  | sort -u | paste -sd'", "' - | sed 's/^/"/; s/$/"/'
```

Expected shape:

```
"brk", "chmod", "close", "execve", "fchmodat", "mkdirat", "openat", "write", ...
```

> **Questions — Block 3**
> **Q8.** `localhostProfile` is `profiles/audit.json`, yet the file on disk is `/var/lib/kubelet/seccomp/profiles/audit.json`. State the rule the kubelet applies, and say exactly what happens if you write `/var/lib/kubelet/seccomp/profiles/audit.json` or `../../etc/audit.json` instead.
> **Q9.** The audit run produced 41 distinct syscalls. Why is shipping exactly those 41 as your enforcing allowlist a *dangerous* practice, and what two categories of syscall will your run almost certainly have missed?
> **Q10.** You see `arch=c000003e` on every record. A 32-bit-compiled helper binary inside the same image would produce a different `arch`. Explain how an attacker can exploit a profile whose `architectures` list contains only `SCMP_ARCH_X86_64`.

---

## Block 4 — An enforcing profile, and the denylist trap

### Step 4.1 — The naïve denylist (this is the trap)

```bash
cat > ~/cks-54/profiles/deny-chmod-naive.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["chmod"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
EOF
```

```yaml
# 04-seccomp-deny-naive.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-deny-naive
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-chmod-naive.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 04-seccomp-deny-naive.yaml
kubectl wait --for=condition=Ready pod/seccomp-deny-naive --timeout=60s
kubectl exec seccomp-deny-naive -- sh -c 'touch /tmp/f && chmod 777 /tmp/f && echo "CHMOD SUCCEEDED"'
```

Expected — the "block" did nothing:

```
CHMOD SUCCEEDED
```

The `chmod(2)` syscall was never issued. musl (and glibc) implement `chmod()` as `fchmodat(AT_FDCWD, ...)`, syscall **268** — exactly what the audit log told you in Step 3.4.

### Step 4.2 — Fix it by covering the whole syscall family

```bash
cat > ~/cks-54/profiles/deny-chmod.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["chmod", "fchmod", "fchmodat", "fchmodat2"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
EOF
```

```yaml
# 05-seccomp-deny.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-deny
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-chmod.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 05-seccomp-deny.yaml
kubectl wait --for=condition=Ready pod/seccomp-deny --timeout=60s
kubectl exec seccomp-deny -- sh -c 'touch /tmp/f; chmod 777 /tmp/f; echo "exit=$?"'
```

Expected:

```
chmod: /tmp/f: Operation not permitted
exit=1
```

> `fchmodat2` was added in Linux 6.6 (x86_64 nr 452). On an older `libseccomp` the runtime may reject the unknown name. If container creation fails with `failed to load seccomp filter: unknown syscall "fchmodat2"`, drop that entry — and note that you have just discovered that your denylist has a hole on newer kernels.

### Step 4.3 — Deliberately break a workload with an allowlist

```bash
cat > ~/cks-54/profiles/too-strict.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["execve", "exit", "exit_group", "read", "write", "close"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF
```

```yaml
# 06-seccomp-too-strict.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-too-strict
  namespace: cks-54
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/too-strict.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 06-seccomp-too-strict.yaml
sleep 5
kubectl get pod seccomp-too-strict
kubectl describe pod seccomp-too-strict | sed -n '/Events:/,$p'
```

Expected:

```
NAME                 READY   STATUS             RESTARTS   AGE
seccomp-too-strict   0/1     ContainerCannotRun 0          5s
```

```
Events:
  Type     Reason     Age   From     Message
  ----     ------     ----  ----     -------
  Normal   Pulled     6s    kubelet  Container image "busybox:1.36" already present on machine
  Normal   Created    6s    kubelet  Created container: app
  Warning  Failed     5s    kubelet  Error: failed to start container "app": ...
```

Now find *why* on the node:

```bash
sudo journalctl -k --since "-2 min" | grep 'comm="sh"\|comm="runc"' | tail -5
```

```
audit: type=1326 audit(...): pid=31980 comm="sh" exe="/bin/busybox" sig=0
  arch=c000003e syscall=12 compat=0 ip=0x... code=0x00050001
```

`syscall=12` is `brk` — the very first thing the C runtime does. `code=0x00050001` is `SECCOMP_RET_ERRNO | EPERM`.

> **Questions — Block 4**
> **Q11.** Restate the general lesson of Step 4.1 in one sentence, and name the class of syscall (beyond aliases) that makes denylists structurally unfixable on Linux.
> **Q12.** In Step 4.3, the audit log was still populated even though the `defaultAction` was `SCMP_ACT_ERRNO`, not `SCMP_ACT_LOG`. Which kernel knob makes that possible, and why is that knob a *node-level* decision rather than a Pod-level one?
> **Q13.** You need "this container must never write to `/etc/shadow`". Can seccomp express that? Answer with the concrete structural reason, referring to what a seccomp cBPF program receives as input.
> **Q14.** Compare `SCMP_ACT_ERRNO` and `SCMP_ACT_KILL_PROCESS` as the `defaultAction` for a production profile. Which one would you ship first during a rollout, and which one is the better long-term end state? Justify both halves.

---

## Block 5 — `RuntimeDefault` at scale: kubelet default and Pod Security Admission

### Step 5.1 — Confirm the container-level override beats the Pod level

```yaml
# 07-seccomp-override.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-override
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: hardened
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
  - name: escaped
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      seccompProfile:
        type: Unconfined
```

```bash
kubectl apply -f 07-seccomp-override.yaml
kubectl wait --for=condition=Ready pod/seccomp-override --timeout=60s
kubectl exec seccomp-override -c hardened -- grep ^Seccomp: /proc/1/status
kubectl exec seccomp-override -c escaped  -- grep ^Seccomp: /proc/1/status
```

Expected:

```
Seccomp:	2
```
```
Seccomp:	0
```

This is a real audit finding pattern: the Pod looks hardened at a glance, one sidecar is not. `kubectl get pod -o jsonpath` is how you catch it at scale:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.securityContext.seccompProfile.type}{"\t"}{range .spec.containers[*]}{.name}{"="}{.securityContext.seccompProfile.type}{" "}{end}{"\n"}{end}' | column -t
```

### Step 5.2 — Enforce it declaratively with Pod Security Admission

```bash
kubectl label namespace cks-54 \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest --overwrite

kubectl delete pod seccomp-override --ignore-not-found
kubectl apply -f 07-seccomp-override.yaml
```

Expected:

```
Error from server (Forbidden): error when creating "07-seccomp-override.yaml": pods "seccomp-override" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (containers "hardened", "escaped" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (containers "hardened", "escaped" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or containers "hardened", "escaped" must set securityContext.runAsNonRoot=true), seccompProfile (container "escaped" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### Step 5.3 — A fully `restricted`-compliant Pod

```yaml
# 08-restricted.yaml
apiVersion: v1
kind: Pod
metadata:
  name: restricted-ok
  namespace: cks-54
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
```

```bash
kubectl apply -f 08-restricted.yaml
kubectl wait --for=condition=Ready pod/restricted-ok --timeout=60s
kubectl exec restricted-ok -- grep -E '^(Seccomp|NoNewPrivs):' /proc/1/status
```

```
Seccomp:	2
NoNewPrivs:	1
```

### Step 5.4 — Cluster-wide default via the kubelet (read-only exercise)

The node-level equivalent, set in `/var/lib/kubelet/config.yaml`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
seccompDefault: true
```

followed by `sudo systemctl restart kubelet`. Every container that does not specify a `seccompProfile` then gets `RuntimeDefault` instead of `Unconfined`.

Remove the label again so later blocks are not blocked by PSA:

```bash
kubectl label namespace cks-54 pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/enforce-version-
```

> **Questions — Block 5**
> **Q15.** `seccompDefault: true` on the kubelet and `enforce=restricted` on the namespace both push workloads toward `RuntimeDefault`. Describe the difference in *where* and *when* each takes effect, and give one scenario each catches that the other does not.
> **Q16.** Under the `baseline` PSA level (not `restricted`), which values of `spec.securityContext.seccompProfile.type` are accepted, and which single value is rejected? Do the same for `appArmorProfile.type`.
> **Q17.** You turned on `seccompDefault: true` and a legacy Java workload immediately started crash-looping. Give the exact three-command sequence you would run to identify the offending syscall, and say what your remediation options are ranked from best to worst.

---

## Block 6 — AppArmor: authoring, loading, iterating

> From here on, use a **real node** (kubeadm/VM). All `apparmor_parser` work happens over SSH on the node, not through `kubectl`.

### Step 6.1 — Author a deliberately blunt profile

On `node01`:

```bash
sudo tee /etc/apparmor.d/k8s-deny-write > /dev/null <<'EOF'
abi <abi/3.0>,

#include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected) {
  #include <abstractions/base>

  file,
  network,
  capability,

  # An explicit deny always wins over any allow rule, regardless of order.
  deny /** w,
}
EOF
```

> If your parser errors on the `abi` line, your AppArmor is 2.x — delete that line. On Ubuntu 24.04 use `abi <abi/4.0>,`.

### Step 6.2 — Load it in **complain** mode first, never straight to enforce

```bash
sudo apparmor_parser -q -C -r -W /etc/apparmor.d/k8s-deny-write
sudo aa-status | grep -A2 'complain mode'
```

Expected:

```
1 profiles are in complain mode.
   k8s-deny-write
```

Flag meanings you must know cold:

| Flag | Effect |
|---|---|
| `-r` | Replace an already-loaded profile (idempotent; this is the one you want) |
| `-a` | Add — **fails** if the profile is already loaded |
| `-R` | Remove the profile from the kernel |
| `-C` | Load in **complain** mode (log, do not block) |
| `-W` | Write the compiled policy to the cache |
| `-q` | Quiet |

### Step 6.3 — Attach the profile to a Pod using the **GA field**

```yaml
# 09-apparmor-deny-write.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-deny-write
  namespace: cks-54
spec:
  nodeName: node01          # the profile is only loaded here — see Block 7
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-write
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 09-apparmor-deny-write.yaml
kubectl wait --for=condition=Ready pod/aa-deny-write --timeout=60s
kubectl exec aa-deny-write -- cat /proc/1/attr/current
```

Expected:

```
k8s-deny-write (complain)
```

### Step 6.4 — Observe complain-mode behaviour: allowed, but recorded

```bash
kubectl exec aa-deny-write -- sh -c 'touch /tmp/probe; echo "exit=$?"'
```

```
exit=0
```

On `node01`:

```bash
sudo dmesg | grep -i apparmor | tail -3
```

```
[ 4127.882134] audit: type=1400 audit(1785840112.441:412): apparmor="ALLOWED"
  operation="mknod" class="file" profile="k8s-deny-write" name="/tmp/probe"
  pid=8842 comm="touch" requested_mask="c" denied_mask="c" fsuid=0 ouid=0
```

`apparmor="ALLOWED"` **with a non-empty `denied_mask`** is the signature of complain mode: "I would have blocked this."

### Step 6.5 — Promote to enforce and re-test

```bash
sudo apparmor_parser -q -r -W /etc/apparmor.d/k8s-deny-write   # note: no -C
sudo aa-status | grep k8s-deny-write
```

```
   k8s-deny-write
```

The profile change applies to **already-running** processes — no Pod restart needed:

```bash
kubectl exec aa-deny-write -- cat /proc/1/attr/current
kubectl exec aa-deny-write -- sh -c 'touch /tmp/probe2; echo "exit=$?"'
kubectl exec aa-deny-write -- sh -c 'cat /etc/hostname; echo "read exit=$?"'
```

Expected:

```
k8s-deny-write (enforce)
```
```
touch: /tmp/probe2: Permission denied
exit=1
```
```
aa-deny-write
read exit=0
```

And the corresponding kernel record:

```bash
sudo dmesg | grep 'apparmor="DENIED"' | tail -2
```

```
[ 4230.114872] audit: type=1400 audit(1785840215.673:418): apparmor="DENIED"
  operation="mknod" class="file" profile="k8s-deny-write" name="/tmp/probe2"
  pid=9013 comm="touch" requested_mask="c" denied_mask="c" fsuid=0 ouid=0
```

### Step 6.6 — Author a realistic, production-shaped profile

```bash
sudo tee /etc/apparmor.d/k8s-nginx > /dev/null <<'EOF'
abi <abi/3.0>,

#include <tunables/global>

profile k8s-nginx flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  capability chown,
  capability dac_override,
  capability setgid,
  capability setuid,
  capability net_bind_service,

  network inet  stream,
  network inet6 stream,

  /usr/sbin/nginx            mr,
  /etc/nginx/**              r,
  /usr/share/nginx/**        r,
  /var/log/nginx/*.log       w,
  /var/cache/nginx/**        rw,
  /run/nginx.pid             rw,
  /proc/sys/kernel/ngroups_max r,

  # High-value denials: this app has no business reading any of these,
  # even though the kubelet mounts the ServiceAccount token into it.
  deny /var/run/secrets/kubernetes.io/serviceaccount/** rwklx,
  deny /etc/shadow  rwklx,
  deny /root/**     rwklx,
  deny /proc/*/mem  rwklx,
}
EOF

sudo apparmor_parser -q -r -W /etc/apparmor.d/k8s-nginx
```

```yaml
# 10-apparmor-nginx.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-nginx
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-nginx
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: web
    image: nginx:1.27-alpine
    ports:
    - containerPort: 80
```

```bash
kubectl apply -f 10-apparmor-nginx.yaml
kubectl wait --for=condition=Ready pod/aa-nginx --timeout=90s

kubectl exec aa-nginx -- cat /proc/1/attr/current
kubectl exec aa-nginx -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

Expected:

```
k8s-nginx (enforce)
```
```
cat: can't open '/var/run/secrets/kubernetes.io/serviceaccount/token': Permission denied
command terminated with exit code 1
```

That is the headline result: **the token is mounted and still unreadable by the application.** A capability drop cannot do that; a NetworkPolicy cannot do that; seccomp cannot do that.

### Step 6.7 — Use `aa-logprof` to grow a profile from denials

```bash
sudo aa-logprof -f /var/log/syslog
```

`aa-logprof` replays `DENIED`/`ALLOWED`-with-denied-mask records and proposes rules interactively (`A`llow / `D`eny / `I`nherit / `S`ave). This is the sanctioned workflow: run in complain, exercise every code path (including error paths, log rotation and shutdown), then let `aa-logprof` write the rules.

> **Questions — Block 6**
> **Q18.** In Step 6.1 the profile contains both `file,` (allow all file access) and `deny /** w,`. Reads still worked and writes did not. State AppArmor's precedence rule between `allow` and `deny`, and say whether reordering the two lines would change anything.
> **Q19.** In Step 6.5 the running container's confinement changed from `complain` to `enforce` without restarting the Pod. Explain the mechanism — where does the confinement live, and what exactly did `apparmor_parser -r` mutate?
> **Q20.** Contrast the exam-relevant syntax difference: the **seccomp** `localhostProfile` value versus the **AppArmor** `localhostProfile` value. Give the value each takes and the reason for the difference.
> **Q21.** `flags=(attach_disconnected)` appears in essentially every container AppArmor profile. What problem does it solve, and why is it specifically a *container* problem?

---

## Block 7 — The four failure modes you must diagnose in under two minutes

### Step 7.1 — Failure mode A: profile not loaded on the scheduled node

The profile from Block 6 exists only on `node01`. Force the Pod onto the control plane:

```yaml
# 11-apparmor-wrong-node.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-wrong-node
  namespace: cks-54
spec:
  nodeName: controlplane
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-write
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 11-apparmor-wrong-node.yaml
sleep 5
kubectl get pod aa-wrong-node
kubectl get pod aa-wrong-node -o jsonpath='{.status.phase}{"\t"}{.status.reason}{"\t"}{.status.message}{"\n"}'
```

Expected (wording varies slightly by kubelet version):

```
NAME            READY   STATUS     RESTARTS   AGE
aa-wrong-node   0/1     AppArmor   0          5s
```
```
Failed	AppArmor	Cannot enforce AppArmor: profile "k8s-deny-write" is not loaded
```

The kubelet rejects the Pod **at admission**, by reading `/sys/kernel/security/apparmor/profiles` on its own node. On some runtime/kubelet combinations you instead land in `CreateContainerError` with a containerd message. Either way the diagnostic is identical:

```bash
ssh controlplane -- 'sudo aa-status | grep k8s-deny-write || echo "NOT LOADED HERE"'
```

**Note the asymmetry against seccomp:** a missing `localhostProfile` **file** produces a container-creation error from the runtime, not an admission rejection:

```bash
kubectl run bad-seccomp --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"securityContext":{"seccompProfile":{"type":"Localhost","localhostProfile":"profiles/nope.json"}}}}' \
  -- sleep 3600
kubectl describe pod bad-seccomp | grep -A3 'Warning'
```

```
  Warning  Failed  3s  kubelet  Error: failed to generate spec: cannot load seccomp profile
  "/var/lib/kubelet/seccomp/profiles/nope.json": open /var/lib/kubelet/seccomp/profiles/nope.json:
  no such file or directory
```

### Step 7.2 — Distribute profiles to every node with a DaemonSet

```yaml
# 12-apparmor-loader.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apparmor-profiles
  namespace: cks-54
data:
  k8s-deny-write: |
    #include <tunables/global>

    profile k8s-deny-write flags=(attach_disconnected) {
      #include <abstractions/base>
      file,
      network,
      capability,
      deny /** w,
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: cks-54
spec:
  selector:
    matchLabels:
      app: apparmor-loader
  template:
    metadata:
      labels:
        app: apparmor-loader
    spec:
      hostPID: true
      tolerations:
      - operator: Exists
      initContainers:
      - name: load
        image: ubuntu:24.04
        command:
        - sh
        - -c
        - |
          set -euo pipefail
          apt-get update -qq && apt-get install -y -qq apparmor-utils >/dev/null
          for f in /profiles/*; do
            apparmor_parser -q -r -W "$f"
            echo "loaded: $f"
          done
        securityContext:
          privileged: true
        volumeMounts:
        - name: profiles
          mountPath: /profiles
          readOnly: true
        - name: apparmorfs
          mountPath: /sys/kernel/security
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.10
      volumes:
      - name: profiles
        configMap:
          name: apparmor-profiles
      - name: apparmorfs
        hostPath:
          path: /sys/kernel/security
          type: Directory
```

```bash
kubectl apply -f 12-apparmor-loader.yaml
kubectl rollout status ds/apparmor-loader --timeout=180s
kubectl delete pod aa-wrong-node --ignore-not-found
kubectl apply -f 11-apparmor-wrong-node.yaml
kubectl wait --for=condition=Ready pod/aa-wrong-node --timeout=60s
kubectl exec aa-wrong-node -- cat /proc/1/attr/current
```

```
k8s-deny-write (enforce)
```

> This DaemonSet is **privileged and mounts securityfs** — that is inherent to loading kernel policy from a Pod, and it is exactly why the upstream recommendation is to bake profiles into the node image or push them with your configuration-management tool. If you do run a loader, treat it as a control-plane-tier component: its own namespace, its own RBAC, no user write access to the ConfigMap.

### Step 7.3 — Failure mode B: container-level override silently unconfines a sidecar

```yaml
# 13-apparmor-override.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-override
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-write
  containers:
  - name: confined
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
  - name: unconfined
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      appArmorProfile:
        type: Unconfined
```

```bash
kubectl apply -f 13-apparmor-override.yaml
kubectl wait --for=condition=Ready pod/aa-override --timeout=60s
kubectl exec aa-override -c confined   -- cat /proc/1/attr/current
kubectl exec aa-override -c unconfined -- cat /proc/1/attr/current
kubectl exec aa-override -c unconfined -- sh -c 'touch /tmp/x && echo WROTE'
```

```
k8s-deny-write (enforce)
```
```
unconfined
```
```
WROTE
```

### Step 7.4 — Failure mode C: the deprecated annotation

```yaml
# 14-apparmor-annotation.yaml  -- LEGACY, do not use in new work
apiVersion: v1
kind: Pod
metadata:
  name: aa-annotation
  namespace: cks-54
  annotations:
    container.apparmor.security.beta.kubernetes.io/app: localhost/k8s-deny-write
spec:
  nodeName: node01
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 14-apparmor-annotation.yaml
kubectl wait --for=condition=Ready pod/aa-annotation --timeout=60s
kubectl get pod aa-annotation -o jsonpath='{.spec.containers[0].securityContext.appArmorProfile}{"\n"}'
```

Expected — the API server has back-filled the field from the annotation:

```json
{"localhostProfile":"k8s-deny-write","type":"Localhost"}
```

The annotation form has been **deprecated since Kubernetes v1.30**, when the `appArmorProfile` field went GA. Note the `localhost/` prefix that the annotation requires and the field forbids — mixing them up is the single most common syntax error on this topic.

### Step 7.5 — Failure mode D: audit the whole cluster in one command

```bash
kubectl get pods -A -o json | jq -r '
  .items[] |
  . as $p |
  ($p.spec.securityContext.appArmorProfile.type // "-") as $paa |
  ($p.spec.securityContext.seccompProfile.type // "-") as $psc |
  $p.spec.containers[] |
  [$p.metadata.namespace, $p.metadata.name, .name,
   (.securityContext.appArmorProfile.type // $paa),
   (.securityContext.seccompProfile.type  // $psc)] | @tsv
' | awk '$4=="-" || $5=="-" || $4=="Unconfined" || $5=="Unconfined"' | column -t
```

Every row this prints is either unconfined or explicitly opted out.

> **Questions — Block 7**
> **Q22.** Compare the failure signature of a missing **AppArmor** profile against a missing **seccomp** profile file. Where in the lifecycle does each fail, which component produces the message, and what does that tell you about where the kubelet does and does not pre-validate?
> **Q23.** The `apparmor-loader` DaemonSet is privileged and mounts `/sys/kernel/security` from the host. Name the concrete privilege escalation an attacker gains with write access to the `apparmor-profiles` ConfigMap, and give two mitigations.
> **Q24.** A Pod in an `enforce=baseline` namespace carries `appArmorProfile: {type: Unconfined}` on one container. What happens, and what is the exact reason `baseline` — not just `restricted` — cares about this?

---

## Block 8 — Layering: why you need both, plus the tooling that automates it

### Step 8.1 — Prove seccomp cannot see paths and AppArmor cannot see syscall arguments

```yaml
# 15-layered.yaml
apiVersion: v1
kind: Pod
metadata:
  name: layered
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-chmod.json
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-nginx
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

```bash
kubectl apply -f 15-layered.yaml
kubectl wait --for=condition=Ready pod/layered --timeout=60s

kubectl exec layered -- cat /proc/1/attr/current
kubectl exec layered -- grep -E '^(Seccomp|NoNewPrivs):' /proc/1/status
```

```
k8s-nginx (enforce)
```
```
Seccomp:	2
NoNewPrivs:	1
```

Fill in this table from your own experiments before reading the answers:

| Control objective | seccomp | AppArmor | capabilities |
|---|---|---|---|
| Block `chmod` on **any** file | ? | ? | ? |
| Block writes to **`/etc/shadow` only** | ? | ? | ? |
| Block `mount(2)` entirely | ? | ? | ? |
| Block raw sockets | ? | ? | ? |
| Block `bpf(2)` / `perf_event_open(2)` | ? | ? | ? |
| Block reading the ServiceAccount token file | ? | ? | ? |

### Step 8.2 — Know that the recording problem is solved (Security Profiles Operator)

Hand-harvesting audit logs, as you did in Block 3, does not scale past a handful of workloads. The CNCF project for this is the **Security Profiles Operator**, which provides `SeccompProfile` and `AppArmorProfile` CRDs, a `ProfileRecording` CRD that records a running workload (via eBPF or the audit log enricher) and emits a profile, and a DaemonSet that distributes profiles to nodes and reconciles them.

```yaml
# Illustrative only — requires the operator to be installed.
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: ProfileRecording
metadata:
  name: record-nginx
  namespace: cks-54
spec:
  kind: SeccompProfile
  recorder: bpf
  podSelector:
    matchLabels:
      app: nginx
```

You are **not** required to operate SPO for the exam, but you are expected to know it exists and what problem it solves.

> **Questions — Block 8**
> **Q25.** Complete the table in Step 8.1 and, for each row where two mechanisms both work, say which you would choose and why.
> **Q26.** Give the one-sentence architectural statement of why seccomp and AppArmor are complementary rather than redundant, in terms of *what each one is allowed to inspect*.
> **Q27.** A `ProfileRecording` with `recorder: bpf` observed a workload for one hour under normal load and produced a 74-syscall profile. Name three failure modes of shipping that profile to production unmodified.

---

## Troubleshooting matrix — memorise this shape

| Symptom | Most likely cause | First command |
|---|---|---|
| `STATUS: AppArmor`, message `profile "X" is not loaded` | Profile absent on the **scheduled** node | `ssh <node> sudo aa-status \| grep X` |
| `cannot load seccomp profile ...: no such file` | Wrong `localhostProfile` path, or file only on one node | `ssh <node> ls -l /var/lib/kubelet/seccomp/profiles/` |
| Pod runs but `/proc/1/status` shows `Seccomp: 0` | Container-level `Unconfined` override, or no profile set and `seccompDefault` off | `kubectl get pod X -o jsonpath='{.spec.containers[*].securityContext}'` |
| `/proc/1/attr/current` shows `unconfined` | Container-level `appArmorProfile: Unconfined`, or the runtime does not support AppArmor | `kubectl get pod X -o yaml \| grep -A3 appArmorProfile` |
| Container exits immediately, no useful log | Allowlist missing a startup syscall | `sudo journalctl -k \| grep 'type=1326' \| tail` then `scmp_sys_resolver -a x86_64 <n>` |
| App fails on one code path only | AppArmor denial on a rarely-hit path | `sudo dmesg \| grep 'apparmor="DENIED"'` |
| `Forbidden ... violates PodSecurity` | PSA, not the kernel — nothing reached the node | read the message; it names the field and container |
| `unknown syscall "..."` at container creation | `libseccomp`/runtime older than the syscall name | `crictl version`; drop or guard the entry |

**The two-file reflex.** Whenever a hardening question is in front of you:

```bash
kubectl exec <pod> [-c <ctr>] -- cat /proc/1/attr/current               # AppArmor: profile + mode
kubectl exec <pod> [-c <ctr>] -- grep -E '^(Seccomp|NoNewPrivs):' /proc/1/status   # seccomp
```

---

## Exam drill — 8 minutes, no documentation except kubernetes.io

1. On `node01`, create and load in **enforce** mode a profile named `k8s-audit-block` that denies all writes under `/data/` but allows everything else.
2. Create Pod `drill` in namespace `cks-54` on `node01`, image `busybox:1.36`, command `sleep 3600`, confined by `k8s-audit-block` **and** using the runtime's default seccomp profile.
3. Prove both are active with a single `kubectl exec` per mechanism.
4. Add a second container `sidecar` that is explicitly seccomp-`Unconfined`, apply, and then label the namespace `enforce=baseline`. Predict the outcome **before** you run it, then verify.

Model solution:

```bash
sudo tee /etc/apparmor.d/k8s-audit-block > /dev/null <<'EOF'
#include <tunables/global>
profile k8s-audit-block flags=(attach_disconnected) {
  #include <abstractions/base>
  file,
  network,
  capability,
  deny /data/** w,
}
EOF
sudo apparmor_parser -q -r -W /etc/apparmor.d/k8s-audit-block
sudo aa-status | grep k8s-audit-block
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: drill
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-audit-block
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl exec drill -- cat /proc/1/attr/current      # k8s-audit-block (enforce)
kubectl exec drill -- grep ^Seccomp: /proc/1/status # Seccomp: 2
kubectl exec drill -- sh -c 'mkdir -p /data && touch /data/x'   # Permission denied
```

For step 4: `baseline` **rejects** `seccompProfile.type: Unconfined` — the whole Pod is refused at admission, including the compliant container.

---

## Cleanup

```bash
kubectl delete namespace cks-54
# On each node:
sudo apparmor_parser -R /etc/apparmor.d/k8s-deny-write
sudo apparmor_parser -R /etc/apparmor.d/k8s-nginx
sudo apparmor_parser -R /etc/apparmor.d/k8s-audit-block
sudo rm -f /etc/apparmor.d/k8s-deny-write /etc/apparmor.d/k8s-nginx /etc/apparmor.d/k8s-audit-block
sudo rm -f /var/lib/kubelet/seccomp/profiles/{audit,deny-chmod,deny-chmod-naive,too-strict}.json
# kind:
kind delete cluster --name cks54
```

---

## Sources

- CNCF, *CKS Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Restrict a Container's Syscalls with seccomp* — https://kubernetes.io/docs/tutorials/security/seccomp/
- Kubernetes, *Restrict a Container's Access to Resources with AppArmor* — https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes, *Pod API reference — SecurityContext* — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context
- Kubernetes, *kubelet configuration (`seccompDefault`)* — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Linux kernel, *Seccomp BPF (SECure COMPuting with filters)* — https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html
- `seccomp(2)` — https://man7.org/linux/man-pages/man2/seccomp.2.html
- `prctl(2)` (`PR_SET_NO_NEW_PRIVS`) — https://man7.org/linux/man-pages/man2/prctl.2.html
- OCI Runtime Specification, *Linux — Seccomp* — https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#seccomp
- Moby, default seccomp profile — https://github.com/moby/moby/blob/master/profiles/seccomp/default.json
- AppArmor project documentation and policy language — https://gitlab.com/apparmor/apparmor/-/wikis/Documentation
- `apparmor.d(5)` — https://manpages.ubuntu.com/manpages/noble/man5/apparmor.d.5.html
- Kubernetes SIG Security, *Security Profiles Operator* — https://github.com/kubernetes-sigs/security-profiles-operator

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1

**Q1.** `CONFIG_SECCOMP` provides seccomp *strict* mode (`SECCOMP_MODE_STRICT`: only `read`, `write`, `_exit`, `sigreturn`); `CONFIG_SECCOMP_FILTER` provides *filter* mode (`SECCOMP_MODE_FILTER`), the cBPF-programmable mode. Kubernetes and every OCI runtime depend exclusively on `CONFIG_SECCOMP_FILTER` — strict mode is unusable for a real container. On modern kernels `CONFIG_SECCOMP` is effectively always on and the interesting check is `CONFIG_SECCOMP_FILTER=y`.

**Q2.** The kubelet on that node cannot enforce AppArmor, so it rejects the Pod at admission (status reason `AppArmor`, message that AppArmor is not enabled/supported on the host). The remediation in a mixed-OS cluster is **not** to drop the field: constrain scheduling so AppArmor-confined workloads only land on AppArmor nodes (`nodeSelector`/`nodeAffinity` on a label such as `security.example.com/lsm=apparmor`), and provide an equivalent SELinux policy (`seLinuxOptions`) for the RHEL-family nodes. Seccomp, by contrast, is LSM-independent and portable across both.

**Q3.** The syscalls are **not** blocked — `SCMP_ACT_LOG` allows unconditionally, that is its entire purpose, and it is unaffected by `actions_logged`. But you will see **nothing** in the audit log, because `actions_logged` is the kernel's allowlist of which seccomp return actions are permitted to emit audit records. So an audit-mode run on such a node produces the illusion of a clean workload while silently gathering zero evidence. That is why it is a prerequisite check: the entire discovery method in Block 3 depends on it.

### Block 2

**Q4.** `0` = `SECCOMP_MODE_DISABLED`, `1` = `SECCOMP_MODE_STRICT`, `2` = `SECCOMP_MODE_FILTER`. In practice a container is either `0` (Unconfined) or `2` (any profile at all — `RuntimeDefault` or `Localhost`). `1` is a curiosity you will not see from Kubernetes. Note that `2` tells you a filter exists, not *which* filter — pair it with `Seccomp_filters` (count of stacked filters) and `crictl inspect` for the content.

**Q5.** Not a coincidence: `seccomp(2)` with `SECCOMP_SET_MODE_FILTER` **requires** that the caller either hold `CAP_SYS_ADMIN` in its own user namespace or have already set `PR_SET_NO_NEW_PRIVS` (`prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`). The rule exists to close an attack where a confined process `execve`s a setuid-root binary and the filter causes that binary to misbehave in a privileged context. The runtime therefore sets `no_new_privs` before installing the filter. `CAP_SYS_ADMIN` is the exemption — which is also why `allowPrivilegeEscalation: true` plus `CAP_SYS_ADMIN` is such a potent combination to look for during an audit.

**Q6.** `RuntimeDefault` means "whatever profile the **container runtime on this node** ships as its default" — Kubernetes defines the *indirection*, not the *content*. containerd's default lives in the containerd source tree; CRI-O ships its own; both are historically derived from Moby's `profiles/seccomp/default.json` but they are not byte-identical and they drift across versions. Implication: a manifest that must behave identically across runtimes, or that must be auditable, has to use `type: Localhost` with a profile **you** version-control and distribute. `RuntimeDefault` is the right *baseline* everywhere; it is not a *specification*.

**Q7.** With `EPERM` as the default for unknown syscalls, a container built against a newer glibc that probes for a new syscall (say `clone3`, `faccessat2`, `openat2`) sees "permission denied" and concludes the syscall exists but is forbidden — so it does **not** fall back to the older equivalent and the call fails hard. With `ENOSYS` it sees "this kernel does not have that syscall", takes its legacy code path, and works. This is exactly the `clone3`/glibc 2.34 breakage that hit every distro in 2021. Rule: unknown/future syscalls → `ENOSYS`; deliberately forbidden syscalls → `EPERM`.

### Block 3

**Q8.** `localhostProfile` is interpreted **relative to the kubelet's seccomp root**, which is `<kubelet-root-dir>/seccomp` (default `/var/lib/kubelet/seccomp`). It must be a relative path that stays inside that root. An absolute path (`/var/lib/kubelet/...`) or one containing `..` is rejected by API validation with `must be a relative path` / `must not contain '..'` — this is a defence against path traversal that would otherwise let a Pod author make the kubelet read arbitrary node files as a profile.

**Q9.** The audit run only observes the code paths you actually exercised. Shipping exactly those 41 syscalls means the first unexercised path fails in production, possibly weeks later, possibly only under failure conditions. The two categories you almost certainly missed are: **(a) error and shutdown paths** — signal handling, `sigaltstack`, core dumping, log rotation, graceful drain, panic/backtrace collection; and **(b) rare-but-critical runtime behaviour** — GC or JIT (`mprotect`, `madvise`, `membarrier`), thread-pool growth (`clone`/`clone3`, `futex` variants), DNS re-resolution and TLS re-handshake (`socket`, `getrandom`), memory pressure paths, and anything triggered only when a dependency is unreachable.

**Q10.** The seccomp filter is selected by the `arch` field of `struct seccomp_data`. If the profile only lists `SCMP_ARCH_X86_64`, then a process making a syscall in 32-bit compat mode (`int 0x80` / `SCMP_ARCH_X86`, or the x32 ABI) arrives with a different `arch` value and different syscall **numbers** for the same names — so the rules simply do not match, and the filter's `defaultAction` decides. If the default is permissive, the attacker gets the syscall for free; if the default is `ERRNO`, they get a hard-to-diagnose outage. Always list `SCMP_ARCH_X86_64`, `SCMP_ARCH_X86` and `SCMP_ARCH_X32` (or the equivalent `aarch64`/`arm` pair), which is exactly what the runtime defaults do.

### Block 4

**Q11.** *Never build a seccomp policy as a denylist: you must enumerate every syscall that reaches the same kernel functionality, and libc will pick a name you did not think of.* The structurally unfixable class is the **multiplexed / catch-all syscalls** — `socketcall` and `ipc` on 32-bit, `prctl`, `ioctl`, `fcntl`, `keyctl`, `arch_prctl`, `io_uring_enter` — where one syscall number reaches dozens of distinct operations selected by an argument. Because seccomp can only inspect scalar arguments (and cannot dereference pointers), some of those sub-operations are undistinguishable at the filter level. Denylists cannot be made complete; allowlists can.

**Q12.** `/proc/sys/kernel/seccomp/actions_logged`. Any action listed there produces an audit record when it fires, so `SCMP_ACT_ERRNO` denials are logged as well as `SCMP_ACT_LOG` allowances. It is node-level because it is a kernel sysctl that governs the audit subsystem for the whole machine — there is no per-Pod or per-container equivalent. Practical consequences: (a) you must configure it as part of node provisioning, alongside auditd/journald log shipping, or you are blind; (b) enabling logging for high-frequency actions on a busy node has a real cost, so it is an operational trade-off, not a free switch.

**Q13.** No. A seccomp filter is a cBPF program whose only input is `struct seccomp_data`: the syscall number, the architecture, the instruction pointer, and the six syscall arguments **as raw 64-bit scalars**. The program runs in a context where it must not dereference user pointers — the path argument to `openat(2)` is a pointer, so the filter cannot read the string, and even if it could, the value can be mutated by another thread between the check and the kernel's own copy (a TOCTOU race). This is a deliberate design constraint, not an oversight. Path-based mediation is the job of an LSM — AppArmor (path-based) or SELinux (label-based).

**Q14.** Ship `SCMP_ACT_ERRNO` first. Denials surface as ordinary errno failures the application can log, retry or degrade around, and the container keeps running long enough for you to collect audit records and correlate them with application logs. `SCMP_ACT_KILL_PROCESS` is the better *end state* for a mature, well-characterised profile: it converts a policy violation into an unambiguous, unrecoverable event rather than letting a compromised process observe the denial and adapt — an attacker who learns that `bpf(2)` returns `EPERM` simply tries the next technique, whereas a kill terminates the exploit chain and generates a loud signal (`SIGSYS`, a restart, an alert). The progression `LOG` → `ERRNO` → `KILL_PROCESS` is the standard rollout ladder.

### Block 5

**Q15.** `seccompDefault: true` is a **kubelet** setting: it acts at container-creation time, on that node only, and it *mutates* the effective configuration by substituting `RuntimeDefault` when the Pod spec says nothing. PSA `enforce=restricted` is an **API server admission** setting: it acts at Pod-creation time, cluster-wide for that namespace, and it *rejects* rather than mutates. Each catches something the other misses: the kubelet setting protects Pods created before the namespace was labelled, Pods in namespaces nobody labelled, and static Pods — but it is invisible in the manifest and evaporates if the Pod moves to a node without the flag. PSA guarantees the manifest itself is explicit and auditable in Git, and it also blocks `Unconfined` — which `seccompDefault` cannot, because an explicit `Unconfined` is exactly the case where the kubelet default does not apply.

**Q16.** For **seccomp** under `baseline`: `RuntimeDefault`, `Localhost`, and *unset* are all accepted; only an explicit `Unconfined` is rejected. (`restricted` additionally rejects *unset* — the type must be explicitly `RuntimeDefault` or `Localhost` on the Pod or on every container.) For **AppArmor**: `baseline` accepts `RuntimeDefault`, `Localhost` and unset, and rejects `Unconfined`; `restricted` inherits that rule unchanged — it does not add an "must be explicitly set" requirement for AppArmor, because AppArmor is not available on every node OS.

**Q17.**
```bash
kubectl describe pod <pod> | sed -n '/Events:/,$p'                       # 1. is it even the profile?
ssh <node> "sudo journalctl -k --since '-5 min' | grep 'type=1326' | tail"  # 2. which syscall number
ssh <node> "scmp_sys_resolver -a x86_64 <n>"                              # 3. what is its name
```
Remediation ranked: **(1)** fix the workload — the JVM syscall it needs is usually `membarrier`, `perf_event_open`, `sched_setattr` or `clone3`, and the correct fix is often a JVM flag or a newer base image; **(2)** attach a `Localhost` profile to *that workload only*, derived from `RuntimeDefault` plus the specific additions, version-controlled and distributed by DaemonSet or node image; **(3)** set `seccompProfile: {type: Unconfined}` on that single container with an expiry date and a tracking issue; **(4)** turn `seccompDefault` off cluster-wide — which sacrifices every other workload's baseline for one application and is almost never the right call.

### Block 6

**Q18.** In AppArmor, an explicit `deny` rule takes precedence over any allow rule for the same access, **regardless of the order in which they appear in the profile**. The parser compiles the profile into a DFA in which denials are subtracted from the allow set, so reordering the lines changes nothing. This is what makes the "broad allow + surgical deny" idiom safe to write, and it also means a `deny` you inherit from an `#include` cannot be re-allowed later in your profile — you must edit or avoid the include.

**Q19.** The confinement lives on the **task** in the kernel: each process has an AppArmor label pointing at a loaded profile (visible at `/proc/<pid>/attr/current`), and the profile itself is a kernel object in the AppArmor policy namespace. `apparmor_parser -r` performs an atomic *replacement* of that kernel object — same name, new compiled DFA and new mode flag — so every task already labelled with `k8s-deny-write` immediately begins being mediated by the new policy. Nothing about the container, the process tree, or the CRI state changed. Two consequences: you can tighten policy on a running fleet without restarts (excellent), and a careless `apparmor_parser -r` can instantly break every running workload bound to that profile (dangerous — which is why complain mode and staged rollout matter).

**Q20.** **seccomp:** `localhostProfile` is a **relative filesystem path** under the kubelet's seccomp root, e.g. `profiles/audit.json` → `/var/lib/kubelet/seccomp/profiles/audit.json`. It is a file the runtime reads and compiles into a BPF filter. **AppArmor:** `localhostProfile` is the **profile name** as loaded into the kernel, e.g. `k8s-deny-write` — no path, no `.json`, and crucially **no `localhost/` prefix** (that prefix belonged to the deprecated annotation form). The difference is architectural: a seccomp profile is data the runtime consumes per container, whereas an AppArmor profile is kernel state that must already exist on the node and is referenced by name.

**Q21.** `attach_disconnected` tells AppArmor how to name a file object whose path cannot be resolved back to the profile's view of the filesystem root — a "disconnected" path. In a container the mount namespace, `pivot_root`, bind mounts, overlayfs layers and deleted-but-open files routinely produce objects whose path the kernel cannot fully reconstruct. Without the flag, such accesses are denied and logged with a bare `name=` that gives you nothing to write a rule against; with it, AppArmor attaches the disconnected path to the profile's root and mediates it normally. It is specifically a container problem because uncontained processes almost always live in the init mount namespace where every path resolves cleanly.

### Block 7

**Q22.** **AppArmor** fails at **kubelet admission**, *before* the runtime is ever contacted: the kubelet reads `/sys/kernel/security/apparmor/profiles` on its own node, finds the name missing, and rejects the Pod with reason `AppArmor` and the message `Cannot enforce AppArmor: profile "X" is not loaded`. **seccomp** fails **later**, inside the container runtime, when it tries to open the profile file to build the OCI spec — the error comes from containerd/CRI-O and surfaces as a `Failed` event with `cannot load seccomp profile ...: no such file or directory`. The lesson: the kubelet pre-validates AppArmor (because it can cheaply enumerate kernel policy) but does **not** pre-validate seccomp file existence, so a missing seccomp profile costs you a scheduling round-trip and a runtime error rather than a clean admission failure — check the node filesystem, not just `kubectl describe`.

**Q23.** Write access to the ConfigMap means the attacker chooses the *content* of policy that a privileged DaemonSet loads into the host kernel. They can (a) replace a strict profile with a permissive one — including redefining a profile that other, unrelated Pods rely on, silently unconfining them on the next reconcile; or (b) load a profile that grants `capability sys_admin`, `mount`, `ptrace` and `/** rwklx` under a name a workload they control already references. Combined, that is node compromise via a namespaced write permission. Mitigations: **(1)** do not run a profile loader at all — bake profiles into the node image or push them with your configuration-management tooling, so profile content is governed by the same review path as the OS; **(2)** if you must, isolate the loader in a dedicated namespace whose ConfigMaps are writable only by cluster-admin, gate it with an admission policy (ValidatingAdmissionPolicy/OPA) that pins allowed profile names, and audit `update` on that ConfigMap. A third, complementary control: run the loader from an immutable source (a signed image containing the profiles) rather than from a mutable ConfigMap.

**Q24.** The Pod is **rejected at admission** by Pod Security Admission with a message of the form `violates PodSecurity "baseline:latest": appArmorProfile (container "X" must not set securityContext.appArmorProfile.type to "Unconfined")`. `baseline` cares — rather than leaving it to `restricted` — because on distributions that support AppArmor the runtime applies its default profile automatically, and that default is part of what "an ordinary, non-exotic container" means. Setting `Unconfined` is an *explicit opt-out of a protection you would otherwise have had for free*, which is precisely the category `baseline` exists to forbid: it does not demand extra hardening, it forbids removing the hardening that is already the default.

### Block 8

**Q25.**

| Control objective | seccomp | AppArmor | capabilities |
|---|---|---|---|
| Block `chmod` on **any** file | **Yes** (deny `chmod`/`fchmod`/`fchmodat`/`fchmodat2`) | Partially — via `deny <path> w` semantics, but AppArmor mediates file permission changes per path, not the syscall as such | No |
| Block writes to **`/etc/shadow` only** | **No** — cannot dereference the path pointer | **Yes** — `deny /etc/shadow rwklx,` | No (dropping `CAP_DAC_OVERRIDE` only helps for non-owner access) |
| Block `mount(2)` entirely | **Yes** | Yes (`deny mount,`) | Mostly — drop `CAP_SYS_ADMIN` |
| Block raw sockets | Yes (deny `socket` with `SOCK_RAW`, an arg check) | Yes (`deny network raw,`) | **Yes and simplest** — drop `CAP_NET_RAW` |
| Block `bpf(2)` / `perf_event_open(2)` | **Yes and simplest** | Partially (`deny capability bpf,`) | Partially — `CAP_BPF`/`CAP_PERFMON`, but root-in-container may retain paths |
| Block reading the ServiceAccount token file | **No** — path-blind | **Yes** — `deny /var/run/secrets/kubernetes.io/serviceaccount/** rwklx,` | No |

Where two work: prefer **capabilities** for coarse, well-named privileges (`CAP_NET_RAW`, `CAP_SYS_ADMIN`) because they are portable, declarative and reviewable in the manifest; prefer **seccomp** for syscall-shaped controls that no capability names (`bpf`, `perf_event_open`, `keyctl`, `userfaultfd`) because it is LSM-independent and works on every node OS; prefer **AppArmor** wherever the answer depends on *which object* is being touched, because that is the only one of the three that can see the object.

**Q26.** seccomp mediates the **syscall interface** — it sees the syscall number, the architecture and the scalar arguments, and nothing else — while AppArmor mediates the **objects** those syscalls act upon — files by path, capabilities, network address families, mounts, signals, ptrace targets — and never sees the syscall number. Neither can express what the other expresses, so the correct posture is both plus a capability drop, not a choice among them.

**Q27.** **(1) Coverage gaps** — one hour of "normal load" does not exercise error handling, shutdown, log rotation, TLS certificate renewal, dependency-failure paths, GC compaction under memory pressure, or the annual leap-second/DST code; every one of those can need a syscall that never appeared. **(2) Recorder blind spots and over-fitting** — a BPF recorder observes what ran, so it captures the syscalls of the *specific* library versions, kernel and hardware present during the recording; a base-image bump, a glibc change, a different CPU feature or a kernel upgrade can shift `clone` → `clone3`, `access` → `faccessat2`, or introduce `membarrier`, and the profile now blocks startup. **(3) Recording a compromised or misconfigured baseline** — the profile encodes whatever the workload *did*, not what it *should* do; if the recorded Pod was already doing something undesirable (or was already compromised), the recording faithfully allows it forever. The correct use of a recording is as a *draft* that a human diffs against `RuntimeDefault`, then ships through `SCMP_ACT_LOG` → `SCMP_ACT_ERRNO` in a staging environment before production.

</details>