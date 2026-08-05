# CKS 6.3 — Investigate and Identify Phases of Attack and Bad Actors Within the Environment

> **Domain:** Monitoring, Logging and Runtime Security · **Exam weight:** 4
> **Goal of these exercises:** given a *live* incident, reconstruct **what happened, in what order, and who did it** by correlating three independent evidence sources — the **runtime layer** (Falco/syscalls), the **control-plane layer** (Kubernetes audit log), and **on-host forensics** (`/proc`, `crictl`, `nsenter`) — and then map each observation onto a phase of the **MITRE ATT&CK for Containers** matrix.
>
> Reference material used throughout:
> - MITRE ATT&CK for Containers matrix — https://attack.mitre.org/matrices/enterprise/containers/
> - Falco rules & fields reference — https://falco.org/docs/reference/rules/ and default ruleset https://github.com/falcosecurity/rules
> - Kubernetes Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
> - Kubernetes Audit Policy reference — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/

**Lab assumptions.** A kubeadm cluster (v1.34) where you have `root` on the control-plane node and on at least one worker. Falco ≥ 0.38 is installed on the workers with its default ruleset (`journalctl -u falco -f` shows events). Where a step must run on a node, it is marked `# on node`. Treat the `victim` workload below as an application an attacker has already gained a foothold in — you are the responder.

---

## Exercise 1 — Reconstruct an intrusion from Falco events and map it to ATT&CK phases

You will *play the attacker* in a throwaway pod to generate a realistic event trail, then switch hats and read that trail the way an SRE on call would.

### Steps

1. Start a tail of Falco output on the worker in a second terminal so you watch events land in real time:
   ```bash
   # on node
   journalctl -u falco -f -o cat
   ```

2. Deploy the target workload and confirm it is scheduled to the worker you are tailing:
   ```bash
   kubectl run victim --image=nginx:1.27 --restart=Never
   kubectl get pod victim -o wide
   ```

3. Simulate **initial hands-on-keyboard access** by exec-ing an interactive shell — this is the single most important primitive an attacker abuses:
   ```bash
   kubectl exec -it victim -- bash
   ```
   Expected Falco event:
   ```
   Notice A shell was spawned in a container with an attached terminal
   (evt_type=execve user=root user_uid=0 user_loginuid=-1 process=bash
   proc_exepath=/usr/bin/bash parent=runc command=bash terminal=34816
   container_id=8f3c... container_image=docker.io/library/nginx
   container_name=victim k8s_ns=default k8s_pod_name=victim)
   Rule: Terminal shell in container
   ```

4. Inside the shell, run this sequence (each command is chosen to trip a *different* default rule):
   ```bash
   # (a) local discovery + credential access
   cat /etc/shadow
   cat /run/secrets/kubernetes.io/serviceaccount/token

   # (b) reach the API server from inside the workload
   apt-get update && apt-get install -y curl 2>/dev/null
   curl -sk https://kubernetes.default.svc/api --header \
     "Authorization: Bearer $(cat /run/secrets/kubernetes.io/serviceaccount/token)"

   # (c) drop and run a new binary (second-stage payload stand-in)
   cp /bin/sleep /tmp/kworker && /tmp/kworker 3 &

   # (d) tamper with an on-disk config to persist
   echo 'evil' > /etc/cron.d/backdoor
   exit
   ```

5. Back on the node, capture the events emitted during that window into a file so you can work with them as a dataset:
   ```bash
   # on node
   journalctl -u falco --since "-5min" -o cat | grep -Eo 'Rule: .*' | sort | uniq -c
   ```
   Representative output:
   ```
      1 Rule: Contact K8S API Server From Container
      1 Rule: Drop and execute new binary in container
      1 Rule: Launch Package Management Process in Container
      1 Rule: Read sensitive file untrusted
      1 Rule: Terminal shell in container
      1 Rule: Write below etc
   ```

**Comprehension check — block 1**

- **Q1.1** Falco reported `user=root user_uid=0` for the shell, yet you launched it with `kubectl exec` as your own kubeconfig identity. Why does Falco show `root`/`uid=0` and not your username, and which log would you consult to recover the *human* who ran the exec?
- **Q1.2** Map each of the six rules above to a single **MITRE ATT&CK for Containers** tactic (Execution, Discovery, Credential Access, Persistence, etc.). Which one rule is the strongest single indicator that this is *interactive* compromise rather than the app misbehaving?
- **Q1.3** Falco enriched the event with `k8s_ns`, `k8s_pod_name`, and `container_image`. Where does that metadata come from, and what breaks in your triage if it shows up empty (`k8s_pod_name=<NA>`)?
- **Q1.4** `Drop and execute new binary in container` fired for `/tmp/kworker`. Explain the syscall-level behaviour that rule keys on, and why simply *copying* a binary without executing it would not trip it.

---

## Exercise 2 — Attribute the attack to a bad actor using the Kubernetes audit log

Falco tells you *what happened on the host*. It cannot tell you *which API identity* created the privileged pod, stole the Secret over the API, or granted itself `cluster-admin`. That attribution lives only in the **kube-apiserver audit log**.

### Steps

1. Author an audit policy that captures the high-signal verbs without leaking Secret *contents*:
   ```bash
   # on control-plane node
   mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
   cat >/etc/kubernetes/audit/policy.yaml <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages: ["RequestReceived"]
   rules:
     # exec/attach/portforward: full request+response, these are hands-on-keyboard
     - level: RequestResponse
       resources:
         - group: ""
           resources: ["pods/exec", "pods/attach", "pods/portforward"]
     # RBAC changes: capture the granted role so we see privilege escalation
     - level: RequestResponse
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["clusterrolebindings", "rolebindings", "clusterroles", "roles"]
     # Secrets: Metadata ONLY — record the access, never the payload
     - level: Metadata
       resources:
         - group: ""
           resources: ["secrets"]
     # Pod lifecycle
     - level: Request
       verbs: ["create", "delete"]
       resources:
         - group: ""
           resources: ["pods"]
     # Everything else, minimally
     - level: Metadata
   EOF
   ```

2. Wire the policy into the API server static pod and restart it (kubelet re-creates the pod when the manifest changes):
   ```bash
   # on control-plane node, edit /etc/kubernetes/manifests/kube-apiserver.yaml
   # under spec.containers[0].command, add:
   #   - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
   #   - --audit-log-path=/var/log/kubernetes/audit/audit.log
   #   - --audit-log-maxage=30
   #   - --audit-log-maxbackup=10
   #   - --audit-log-maxsize=100
   #
   # and mount the two host paths into the container:
   #   volumeMounts:
   #     - name: audit-policy
   #       mountPath: /etc/kubernetes/audit/policy.yaml
   #       readOnly: true
   #     - name: audit-log
   #       mountPath: /var/log/kubernetes/audit
   #   volumes:
   #     - name: audit-policy
   #       hostPath: { path: /etc/kubernetes/audit/policy.yaml, type: File }
   #     - name: audit-log
   #       hostPath: { path: /var/log/kubernetes/audit, type: DirectoryOrCreate }
   ```
   Confirm the API server came back and is writing events:
   ```bash
   crictl ps | grep kube-apiserver
   tail -n1 /var/log/kubernetes/audit/audit.log | jq .verb
   ```

3. Generate a realistic "bad actor" trail from a *service account token* (the credential the attacker stole in Exercise 1), not your admin kubeconfig — this is what real lateral movement looks like:
   ```bash
   # attacker escalates: privileged pod + a self-granted cluster-admin binding + secret theft
   kubectl create clusterrolebinding pwn --clusterrole=cluster-admin \
     --serviceaccount=default:default
   kubectl run rootpod --image=alpine --restart=Never --privileged \
     --overrides='{"spec":{"hostPID":true,"containers":[{"name":"c","image":"alpine","command":["sleep","3600"],"securityContext":{"privileged":true}}]}}'
   kubectl get secret -A
   kubectl exec -it victim -- id
   ```

4. Now investigate. **Who exec-ed into pods, from which source IP, and when?**
   ```bash
   jq -r 'select(.objectRef.subresource=="exec")
     | [.requestReceivedTimestamp, .user.username, .sourceIPs[0],
        (.objectRef.namespace+"/"+.objectRef.name)] | @tsv' \
     /var/log/kubernetes/audit/audit.log
   ```
   ```
   2026-08-05T14:22:31Z   kubernetes-admin   10.0.7.14    default/victim
   ```

5. **Who granted cluster-admin, and to whom?** (the single most important escalation query)
   ```bash
   jq -r 'select(.objectRef.resource=="clusterrolebindings" and .verb=="create")
     | {when:.requestReceivedTimestamp, who:.user.username, from:.sourceIPs,
        binding:.objectRef.name,
        role:.requestObject.roleRef.name,
        subjects:[.requestObject.subjects[]?.name]}' \
     /var/log/kubernetes/audit/audit.log
   ```
   ```json
   {
     "when": "2026-08-05T14:22:05Z",
     "who": "kubernetes-admin",
     "from": ["10.0.7.14"],
     "binding": "pwn",
     "role": "cluster-admin",
     "subjects": ["default"]
   }
   ```

6. **Which identities touched Secrets, and how broadly?**
   ```bash
   jq -r 'select(.objectRef.resource=="secrets" and (.verb=="get" or .verb=="list" or .verb=="watch"))
     | [.requestReceivedTimestamp, .user.username, .verb,
        (.objectRef.namespace // "ALL")] | @tsv' \
     /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head
   ```

7. **Sweep for unauthenticated / anonymous access** — a classic initial-access foothold on misconfigured clusters:
   ```bash
   jq -r 'select(.user.username=="system:anonymous")
     | [.requestReceivedTimestamp, .sourceIPs[0], .verb, .requestURI,
        .responseStatus.code] | @tsv' \
     /var/log/kubernetes/audit/audit.log
   ```

**Comprehension check — block 2**

- **Q2.1** In the policy, Secrets are logged at `level: Metadata` while `pods/exec` is at `RequestResponse`. State the concrete risk that the Secret rule is defending against, and what investigative capability you *give up* by choosing `Metadata` there.
- **Q2.2** Your `clusterrolebindings` query read `.requestObject.roleRef.name` to learn the granted role. Which audit `level` is the *minimum* required for `.requestObject` to be populated, and what would that field contain at `level: Metadata`?
- **Q2.3** The exec query attributed the action to `kubernetes-admin` from `10.0.7.14`. In a real incident the attacker would appear as `system:serviceaccount:default:default`. Write the `jq` selector that isolates *all* actions performed by a specific compromised service account, and explain why `sourceIPs` is still valuable even when the username is a service account.
- **Q2.4** `omitStages: ["RequestReceived"]` is set. Why is dropping the `RequestReceived` stage safe and desirable, and which stage would you *keep* to prove an action actually took effect versus was merely attempted?
- **Q2.5** You committed the audit-policy change directly into `kube-apiserver.yaml` on a live control plane. If the API server does **not** restart after your edit, name the two most likely mistakes (one in the flags, one in the volumes) and how you would diagnose them from the node.

---

## Exercise 3 — On-host forensics: pin down the process, its sockets, and its persistence

The audit log gives you API-level attribution; Falco gives you the syscall event. To *scope the blast radius* you must inspect the live container from the node: its process tree, open network connections, dropped files, and environment (often full of leaked credentials).

### Steps

1. From the audit/Falco evidence you know the pod is `victim` on this worker. Find its runtime container and PID **without** trusting anything inside the container:
   ```bash
   # on node
   CID=$(crictl ps --name victim -q)
   PID=$(crictl inspect --output go-template --template '{{.info.pid}}' "$CID")
   echo "container=$CID host-pid=$PID"
   ```

2. Reconstruct the **process tree** as the host sees it (an attacker can't hide from the host PID namespace):
   ```bash
   ps -o pid,ppid,user,stat,etime,cmd --ppid "$PID" --pid "$PID" -H
   # or, broader, the whole subtree:
   ps -e -o pid,ppid,cmd --forest | grep -A20 -w "$PID"
   ```
   You are looking for the tell-tale of a live intrusion: a long-lived `bash`/`sh` with no controlling service, or an unexpected binary such as `/tmp/kworker`.

3. Enumerate the container's **live network connections** by entering only its network namespace (not its filesystem, which may be tampered):
   ```bash
   nsenter -t "$PID" -n ss -tunap
   ```
   ```
   Netid State  Local Address:Port   Peer Address:Port    Process
   tcp   ESTAB  10.244.1.23:44170    185.220.101.7:4444   users:(("bash",pid=...))
   ```
   An **ESTABLISHED egress connection owned by a shell** to an external host/port is a reverse shell until proven otherwise.

4. Inspect what the attacker **dropped and where they persisted**, viewing the container's root filesystem from the host via `/proc/<pid>/root` (bypasses any in-container tampering of `ls`/`cat`):
   ```bash
   ls -la --time-style=full-iso /proc/$PID/root/tmp/
   cat /proc/$PID/root/etc/cron.d/backdoor
   # recently modified files across the container rootfs (last 15 min):
   find /proc/$PID/root -xdev -type f -mmin -15 2>/dev/null | grep -vE '/proc|/sys'
   ```

5. Dump the process **environment** — frequently where cloud/API credentials leak:
   ```bash
   tr '\0' '\n' < /proc/$PID/environ
   ```

6. Preserve evidence *before* you kill anything (order matters — a hard delete destroys volatile state):
   ```bash
   crictl inspect "$CID"  > /root/ir/victim-inspect.json
   nsenter -t "$PID" -n ss -tunap > /root/ir/victim-sockets.txt
   cp -a /proc/$PID/root/tmp/kworker /root/ir/ 2>/dev/null
   # only now contain:
   kubectl label pod victim quarantine=true
   kubectl cordon <this-node>   # if node-level compromise is suspected
   ```

**Comprehension check — block 3**

- **Q3.1** Every filesystem and socket inspection above went through `crictl`/`nsenter`/`/proc/$PID/root` **from the node**, never `kubectl exec`. Give the two independent reasons this matters during an active incident.
- **Q3.2** `ss` showed a connection *owned by `bash`*. Why is the owning process, rather than the destination IP alone, the decisive piece of evidence for calling this a reverse shell?
- **Q3.3** In step 6 you captured sockets and the dropped binary *before* deleting the pod. Rank these three actions by "volatility" (most-perishable first): open network connections, the `/etc/cron.d/backdoor` file, the pod's audit-log entries — and justify the order.
- **Q3.4** The attacker had `hostPID: true` on `rootpod` (Exercise 2, step 3). Explain how that single field turns a container compromise into a *node* compromise, and what you would additionally inspect from the host once you see it.

---

## Exercise 4 — Close the visibility gap: author a custom Falco rule for the phase you missed

Reading the trail shows that the default ruleset flagged the shell and the dropped binary, but the **reverse shell egress** from Exercise 3 (a shell opening an outbound socket) was *not* covered by a dedicated rule. Detection engineering closes that gap.

### Steps

1. Create a rules file that reuses the default ruleset's macros/lists (`outbound`, `shell_binaries`) and adds an allow-list you control:
   ```yaml
   # /etc/falco/rules.d/reverse-shell.yaml
   - list: allowed_outbound_destinations
     items: []   # e.g. internal proxy IPs the app is *supposed* to reach

   - rule: Outbound Connection From Shell In Container
     desc: >
       A shell process inside a container opened an outbound network connection to
       a destination not on the allow-list. Interactive shells do not normally
       initiate egress; this pattern matches reverse shells and second-stage
       payload pulls (MITRE Command and Control / Execution).
     condition: >
       outbound and container
       and proc.name in (shell_binaries)
       and not fd.sip in (allowed_outbound_destinations)
     output: >
       Outbound connection from shell in container
       (user=%user.name process=%proc.name cmdline=%proc.cmdline
        connection=%fd.name server=%fd.sip:%fd.sport
        container=%container.name image=%container.image.repository
        pod=%k8s.pod.name ns=%k8s.ns.name)
     priority: CRITICAL
     tags: [container, network, mitre_command_and_control, T1071]
   ```

2. Validate syntax *before* reloading — a broken rules file can crash the engine or, worse, silently disable rule loading:
   ```bash
   # on node
   falco --validate /etc/falco/rules.d/reverse-shell.yaml
   ```
   ```
   Ok
   ```

3. Ensure the file is in Falco's `rules_files` load path (default packaging loads `/etc/falco/rules.d/`), then reload the engine without a full restart:
   ```bash
   kill -1 "$(pidof falco)"      # SIGHUP triggers a hot reload
   journalctl -u falco --since "-30s" -o cat | grep -i 'rules file'
   ```

4. Test it end-to-end (true positive) and then confirm it does **not** fire for a legitimate app making egress (true negative):
   ```bash
   # true positive: shell opens a socket
   kubectl exec -it victim -- sh -c 'exec 3<>/dev/tcp/example.com/80; echo done >&3'
   # true negative: the nginx worker serving traffic should NOT match
   curl -s http://$(kubectl get pod victim -o jsonpath='{.status.podIP}') >/dev/null
   ```

**Comprehension check — block 4**

- **Q4.1** The rule condition is `outbound and container and proc.name in (shell_binaries) and not fd.sip in (allowed_outbound_destinations)`. Explain what each of the four clauses contributes, and predict the failure mode if you dropped the `and container` clause on a busy worker node.
- **Q4.2** `/dev/tcp` is a **bash builtin**, so no separate process is `execve`'d for the connection itself. Explain why keying this rule on the `outbound` (network) event rather than on `spawned_process` is what makes it fire at all for a `/dev/tcp` reverse shell.
- **Q4.3** You set `priority: CRITICAL` and tagged `mitre_command_and_control`. Why do the `tags` matter operationally beyond documentation, and how would an alert pipeline use `priority` differently from `tags`?
- **Q4.4** A teammate proposes instead detecting reverse shells by alerting on *any* connection to port 4444. Give two reasons the behaviour-based rule (shell + egress) is more robust than the port-based one, and one situation where the port rule still adds value.

---

## Exercise 5 — Synthesis: assemble the kill-chain timeline

You now hold three evidence streams. Correlate them into one narrative — this is exactly the deliverable an incident review expects.

### Steps

1. Extract a unified, timestamp-sorted view by pulling the key fields from each source into a common `TSV`:
   ```bash
   # control-plane events (audit)
   jq -r '[.requestReceivedTimestamp, "AUDIT", .user.username,
           (.verb+" "+(.objectRef.resource // "")+"/"+(.objectRef.subresource // "")),
           .sourceIPs[0]] | @tsv' /var/log/kubernetes/audit/audit.log > /tmp/tl-audit.tsv

   # runtime events (falco) — Falco can emit JSON if json_output=true in falco.yaml
   journalctl -u falco --since "-1h" -o cat \
     | sed -E 's/^([0-9:.]+): (\w+) (.*)Rule: (.*)$/\1\tFALCO\t\4\t\3/' > /tmp/tl-falco.tsv

   sort -k1,1 /tmp/tl-audit.tsv /tmp/tl-falco.tsv | column -t -s$'\t' | less
   ```

2. Walk the sorted timeline and label each row with its ATT&CK phase, producing a table like:

   | Time (UTC) | Source | Phase (ATT&CK for Containers) | Evidence |
   |---|---|---|---|
   | 14:21:58 | AUDIT | Initial Access — Valid Accounts | first API call from `10.0.7.14` |
   | 14:22:02 | FALCO | Execution (T1609) | `Terminal shell in container` on `victim` |
   | 14:22:03 | FALCO | Credential Access (T1552) | `Read sensitive file untrusted` `/run/secrets/.../token` |
   | 14:22:04 | FALCO | Discovery (T1613) | `Contact K8S API Server From Container` |
   | 14:22:05 | AUDIT | Privilege Escalation (T1078) | `create clusterrolebindings/ pwn → cluster-admin` |
   | 14:22:09 | AUDIT | Persistence (T1610) | `create pods/ rootpod` (`privileged`, `hostPID`) |
   | 14:22:31 | FALCO | Command & Control (T1071) | `Outbound Connection From Shell In Container` |
   | 14:22:40 | FALCO | Persistence (T1053) | `Write below etc` `/etc/cron.d/backdoor` |

**Comprehension check — block 5**

- **Q5.1** Two of your rows share the same second-granularity timestamp but the *causal* order matters (the token read must precede the API contact). When Falco and audit timestamps disagree by a few seconds, what clock/skew issue must you account for before asserting ordering, and how do you make the two sources comparable?
- **Q5.2** The timeline shows Credential Access (token read) *before* the API contact. Explain why that ordering is the pivot that proves *lateral movement via the workload's own service account*, rather than the admin simply administering the cluster.
- **Q5.3** Exactly one phase in the table is provable **only** from the audit log and would be invisible to Falco, and exactly one is provable **only** from Falco and invisible to the audit log. Name both and explain the boundary between the two telescopes.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Q1.1** Falco reports the identity *inside the container's namespaces as the kernel sees it*. `kubectl exec` runs `runc`/`crictl exec` on the node, which spawns your shell as the container's process user — here `root` (uid 0), because the nginx image runs as root. Falco reads syscalls, not the Kubernetes API, so it has no notion of your kubeconfig identity (`user_loginuid=-1` confirms no login/audit uid was set). To recover the *human*, you must consult the **kube-apiserver audit log** — the `pods/exec` event carries `.user.username` and `.sourceIPs`. Runtime and control-plane logs are complementary: neither alone attributes an interactive exec to a person on a node.

**Q1.2** Mapping:
- `Terminal shell in container` → **Execution** (T1609 Container Administration Command).
- `Read sensitive file untrusted` (`/etc/shadow`) → **Credential Access** / Discovery.
- `Contact K8S API Server From Container` → **Discovery** (T1613 Container and Resource Discovery).
- `Launch Package Management Process in Container` → **Defense Evasion / Execution** (installing tooling at runtime).
- `Drop and execute new binary in container` → **Execution / Persistence** (second-stage payload).
- `Write below etc` (`/etc/cron.d/backdoor`) → **Persistence** (T1053 Scheduled Task/Job).

The strongest single indicator of *interactive* compromise is **`Terminal shell in container` with an attached terminal** — production containers almost never have an interactive TTY shell; an application process misbehaving does not allocate a PTY.

**Q1.3** The `k8s_ns`/`k8s_pod_name`/`container_image` fields come from Falco's **container/Kubernetes metadata enrichment**: it resolves the container ID (from the cgroup/`clone` event) against the container runtime (containerd/CRI-O) and, when configured, the API server, to attach pod identity. If it shows `<NA>`, you lose the ability to pivot from a host syscall event to *which workload* it belongs to — you would be left with only a container ID and would have to resolve it manually via `crictl ps`/`crictl inspect`. Common causes: the metadata plugin/`-k` API connection is down, or the event fired before enrichment completed.

**Q1.4** `Drop and execute new binary in container` keys on an **`execve` of a file whose inode was created/modified *after* the container started** (i.e. not part of the read-only image layer). The rule combines a write/create of an executable with a subsequent exec of that same path. Merely `cp`-ing the binary produces only a write event; without the `execve`, the "execute new binary" condition is not satisfied — which is exactly why the `&& /tmp/kworker` matters.

---

### Exercise 2

**Q2.1** Logging Secrets at `RequestResponse` (or even `Request`) would write the **Secret's `data` payload — the plaintext credential — into the audit log**, turning your audit log into a high-value credential store an attacker (or an over-broad log shipper) can loot. `Metadata` records *that* identity X did `get secret/foo in ns bar at time T`, which is all you need for detection and attribution. What you give up: you cannot prove *which specific fields/values* were returned, only that the object was accessed.

**Q2.2** `.requestObject` is populated starting at **`level: Request`** (Request logs the incoming object; RequestResponse adds the API server's response object). At `level: Metadata`, `.requestObject` is **absent entirely** — you would see the binding was created and by whom, but not that it referenced `cluster-admin`. That is why the RBAC rule is set to `RequestResponse`.

**Q2.3** Selector:
```bash
jq -r 'select(.user.username=="system:serviceaccount:default:default")
  | [.requestReceivedTimestamp, .verb, .objectRef.resource,
     (.objectRef.namespace // "-"), .sourceIPs[0]] | @tsv' audit.log
```
`sourceIPs` remains valuable because a service-account token is *portable*: the same identity legitimately used by a pod on-cluster suddenly appearing from an **unexpected source IP** (a new node, an external egress IP, a developer laptop) is strong evidence the token was exfiltrated and is being replayed from off-cluster. Username tells you *which* credential; `sourceIPs` tells you *whether its use is anomalous*.

**Q2.4** `RequestReceived` is emitted the instant the API server *receives* the request, before authn/authz/admission — it doubles event volume and contains no outcome, so dropping it is pure noise reduction with no loss. You keep the **`ResponseComplete`** stage (and `Panic`), because only a completed response with `.responseStatus.code` proves the action *succeeded* (`201`/`200`) versus was *attempted and denied* (`403`). Distinguishing "tried to grab the Secret" from "grabbed the Secret" is central to scoping impact.

**Q2.5** Most likely failures: (1) **flag typo / wrong path** — `--audit-policy-file` points at a path that isn't mounted into the container, so the kubelet's API server crashloops on start; (2) **missing/incorrect `hostPath` volume + `volumeMount`** for the policy file or the log directory, so the file is invisible inside the container. Diagnose from the node with `crictl ps -a | grep apiserver` (see it crashlooping), then `crictl logs <apiserver-container-id>` for the exact "no such file" / flag-parse error. Because it is a static pod, also check `journalctl -u kubelet` for manifest errors. Keep a backup of the manifest before editing.

---

### Exercise 3

**Q3.1** (1) **Integrity of tools:** an attacker with a foothold may have replaced `ls`, `cat`, `ps`, or the shell itself inside the container; `kubectl exec` runs *their* binaries and returns *their* lies. `crictl`/`nsenter`/`/proc/$PID/root` use the **host's** trusted binaries and the kernel's own view. (2) **Evidence preservation / non-perturbation:** `kubectl exec` spawns a new process inside the container, mutating volatile state (new PIDs, new events, possibly tripping the attacker's own tripwires or triggering anti-forensic logic). Host-side inspection is far closer to read-only.

**Q3.2** The destination IP/port alone is ambiguous — plenty of workloads legitimately talk to `:443`, and even `:4444` could be a benign service. What makes it a reverse shell is that the **owning process is an interactive shell** (`bash`/`sh`) rather than the application's own binary. A shell holding an ESTABLISHED egress socket has no legitimate purpose in a container; that ownership is the signal, the address is merely the indicator to pivot on.

**Q3.3** Most→least volatile: **(1) open network connections** — they vanish the instant the process or pod dies and are never recoverable; **(2) the `/etc/cron.d/backdoor` file** — persists on the container's writable layer until the pod/container is deleted, but is lost when you `kubectl delete pod`; **(3) the audit-log entries** — already durably written to disk on the control plane and independent of the pod's lifecycle. Order of Volatility dictates you capture live sockets/memory first, then on-disk artifacts, then rely on the already-persisted logs — which is exactly why step 6 snapshots sockets and copies the binary *before* any `delete`.

**Q3.4** `hostPID: true` places the container in the **host's PID namespace**, so its processes can see and (with sufficient capabilities/privileged) signal or `nsenter`/`/proc`-inspect *every process on the node*, including the kubelet and other pods — enabling reading other containers' memory/`/proc/<pid>/environ`, injecting into host processes, or `nsenter -t 1` to break out to the host mount namespace. Once you see it, additionally inspect from the host: `ps -ef` for cross-container access by that container's processes, `/proc/<hostpid>/root` breakouts, host cron/systemd units, `~/.ssh/authorized_keys`, and any node-level credential (kubelet kubeconfig, cloud IMDS access).

---

### Exercise 4

**Q4.1** Clauses: `outbound` (a network *connect* event — the trigger), `container` (scope to containerized workloads, not host daemons), `proc.name in (shell_binaries)` (only shells — the behavioural discriminator), `not fd.sip in (allowed_outbound_destinations)` (suppress sanctioned egress to cut false positives). Drop `and container` and the rule now matches **every shell on the node that opens a socket** — including your own `journalctl`/admin sessions and system scripts running on the host — producing an alert flood that will get the rule muted, defeating its purpose.

**Q4.2** A `/dev/tcp/host/port` redirection is handled *inside* the running bash process as a builtin; the kernel sees a `connect()` syscall but **no new `execve`**. A rule keyed on `spawned_process` would therefore never fire — there is no child process to match. Keying on the `outbound` (network connect) event catches the `connect()` regardless of whether a separate binary (`nc`, `curl`) or a shell builtin performed it, which is what makes it robust against fileless/builtin reverse shells.

**Q4.3** `priority` is a *severity* signal the alert pipeline uses to **route and page** (e.g. CRITICAL → PagerDuty now, NOTICE → dashboard only) and to threshold/rate-limit. `tags` are *classification/metadata* used to **filter, group, and correlate** — e.g. build an ATT&CK coverage heatmap, route all `mitre_command_and_control` events to the threat-intel channel, or suppress a noisy tag in one namespace. Priority answers "how loud?"; tags answer "what kind, and how does it fit the kill chain?".

**Q4.4** Behaviour-based (shell + egress) is more robust because: (1) it is **port-agnostic** — attackers trivially move C2 off 4444 to 443/53, defeating a static-port rule; (2) it captures *intent* (a shell speaking to the network) rather than a coincidental number, so it survives infrastructure changes. The port rule still adds value as a **cheap, high-confidence complement** when you have threat intel on a *specific* known-bad C2 endpoint/port — a targeted IOC match that fires even when the process is not a shell (e.g. an injected library beaconing).

---

### Exercise 5

**Q5.1** Falco timestamps come from the **worker node's clock** (syscall event time); audit timestamps come from the **control-plane's clock** (`requestReceivedTimestamp`). If the nodes' clocks drift, sub-second ordering across the two sources is unreliable. Before asserting causal order you must confirm **NTP/chrony is synchronised** on both nodes (and ideally bound the skew), and normalise both streams to **UTC** (audit is already UTC/RFC3339; ensure Falco's output is too). Within a *single* source, ordering is trustworthy; across sources, treat close timestamps as concurrent unless skew is known-small.

**Q5.2** If the workload's own service-account **token is read on the node (Falco Credential Access) and *then* the API server is contacted with that bearer token**, the sequence proves the API activity originates *from inside the compromised pod using its mounted identity* — i.e. lateral movement leveraging the workload's RBAC. Had the admin simply been administering the cluster, there would be **no token-read syscall inside the pod** preceding the API call; the API call would come from the admin's kubeconfig off a workstation IP. The read-then-call ordering is what distinguishes "the pod's identity is being abused" from "an operator is working."

**Q5.3** **Audit-only:** the `create clusterrolebindings pwn → cluster-admin` (Privilege Escalation via RBAC) — it is a pure API-object mutation with no host syscall footprint, so Falco cannot see it. **Falco-only:** the `Read sensitive file untrusted` on `/run/secrets/.../token` (and the reverse-shell egress) — reading a file or opening a socket *inside* a container never reaches the API server, so the audit log is blind to it. The boundary is the **API server**: audit sees everything that crosses the control-plane API and nothing that doesn't; Falco sees everything that hits the *kernel* on a node and nothing that is purely an API-object change. Full incident reconstruction requires both telescopes.

</details>