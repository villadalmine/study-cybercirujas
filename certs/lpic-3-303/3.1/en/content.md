# LPIC-3 Exam 303-300 (v3.0) — Topic 3.1: Application Security

---

## 1. Production Architectural Motivation and Problem Statement

Modern cloud-native and Linux enterprise workloads execute within complex multi-tenant environments where the application layer represents the largest attack surface. Vulnerabilities operating at the application layer—ranging from binary memory corruptions (buffer overflows, Return-Oriented Programming [ROP] chains) to web application vectors (SQL Injection, Remote Code Execution [RCE], Server-Side Request Forgery [SSRF])—can lead to unauthorized remote execution, data exfiltration, and lateral privilege escalation into host kernel space.

```
                     [ PUBLIC UNTRUSTED TRAFFIC ]
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  REVERSE PROXY & WAF LAYER (ModSecurity v3 + OWASP CRS v4)       │
│  - Inspects HTTP Request Payload / Headers                       │
│  - Terminates TLS 1.3 / Enforces HSTS & CSP                      │
│  - Blocks Injection, XSS, SSRF, & Malformed Requests             │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ Sanitized L7 Traffic
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  RUNTIME CONTAINER ISOLATION (Namespaces, cgroups v2, UserNS)   │
│  - Unprivileged UID Mapping (UID 10001:10001)                    │
│  - Read-Only Root Filesystem (`/` mounted ro)                    │
│  - Capabilities Dropped (`CapDrop: ALL`)                         │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ Syscall Execution
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  KERNEL SYSCALL FILTERING (Seccomp-BPF + ASLR + DEP/NX)          │
│  - ASLR: `/proc/sys/kernel/randomize_va_space = 2`               │
│  - Seccomp Profile: Filters 300+ dangerous syscalls to minimal   │
│  - Traps unauthorized `ptrace`, `kexec_load`, or `unshare`       │
└──────────────────────────────────────────────────────────────────┘
```

A robust application security architecture enforces **Defense-in-Depth** across three fundamental boundaries:

1. **Kernel Space & Memory Protection**: Hardening the Linux kernel memory layout via Address Space Layout Randomization (ASLR), Data Execution Prevention (DEP/NX), Position Independent Executables (PIE), and Relocation Read-Only (RELRO) to negate exploit payloads even if code bugs exist.
2. **Process Runtime Isolation**: Restricting process capabilities through Linux Namespaces (PID, MNT, NET, IPC, UTS, USER, CGROUP), cgroups v2 resource ceilings, POSIX Capabilities drop (`CAP_SYS_ADMIN`, `CAP_NET_RAW`), and syscall surface reduction via Seccomp-BPF filters.
3. **Application & Boundary Filtering**: Deploying Layer 7 Web Application Firewalls (WAF) integrated into high-performance reverse proxies (NGINX + ModSecurity v3) to parse, sanitize, and block malicious L7 application payloads prior to hitting execution runtimes.

Failure to harden any single layer invalidates the entire trust model, enabling compromised application processes to breakout into host namespaces or execute arbitrary shellcode.

---

## 2. Technical Comparison & Trade-off Tables

### Table 1: Binary & Kernel Memory Protection Mechanisms

| Mechanism | Operating Layer | Primary Threat Mitigated | Performance Overhead | Operational Trade-off / Failure Mode |
| :--- | :--- | :--- | :--- | :--- |
| **ASLR** (`randomize_va_space=2`) | Kernel / MMU | Memory location prediction, Buffer Overflows, ROP | Negligible (<0.1%) | Requires binaries compiled with `-fPIE -pie`. Incompatible with legacy non-PIE static pointers. |
| **DEP / NX** | CPU Hardware / MMU | Executing code from Stack/Heap regions | Zero (Hardware enforced) | Prevents JIT compilers or dynamic execution engines unless explicit executable memory pages (`PROT_EXEC`) are allocated. |
| **Full RELRO** | Linker / Binary | GOT (Global Offset Table) overwrite attacks | Slight increase in process initialization time | All dynamic symbols resolved at load time (`LD_BIND_NOW=1`). Prevents lazy binding optimization. |
| **Stack Canaries** (`-fstack-protector-strong`) | Compiler / Runtime | Stack buffer overflow return address overwrite | ~1% CPU overhead | Triggers immediate process termination (`SIGABRT`) upon guard check failure, resulting in application crash (DoS over RCE). |
| **Seccomp-BPF** | Kernel / Syscall Entry | Unintended kernel interface exploitation (`sys_ptrace`, `kexec`) | ~1-3% per syscall evaluation | False positive syscall blocks result in immediate `SIGSYS` killing of the process. Requires rigorous syscall profiling. |

---

### Table 2: Process & Runtime Isolation Paradigms

| Isolation Mechanism | Security Boundary | Kernel Surface Area Exposed | Maintenance Complexity | Deployment Fit |
| :--- | :--- | :--- | :--- | :--- |
| **Chroot Jail** | File Path Virtualization | Full kernel syscall interface | Low | Legacy monolithic daemons. Easily escaped if running as `root` (UID 0) via `chdir()` + `chroot()`. |
| **Linux Namespaces + Capabilities** | Process View Isolation | Broad shared kernel interface | Medium | Standard OCI Containers (Docker/CRI-O). Requires explicit stripping of Linux capabilities (`CAP_SYS_ADMIN`). |
| **Seccomp-BPF Filtering** | System Call Interface | Restricted subset of system calls | High (Requires auditing) | High-security microservices. Restricts kernel vulnerability exposure by denying unnecessary syscalls. |
| **AppArmor / SELinux (MAC)** | Path / Label Security | Object Access Control layer | Very High | Enterprise OS host hardening. Mandatory for regulatory compliance (PCI-DSS, NIST SP 800-53). |

---

### Table 3: Application L7 Security & WAF Integration Strategies

| Strategy | Architecture Position | Latency Impact | Inspection Capability | False Positive Risk |
| :--- | :--- | :--- | :--- | :--- |
| **ModSecurity v3 + OWASP CRS** | Reverse Proxy (NGINX/Envoy Module) | +2ms to +15ms per request | Deep L7 (HTTP Body, Headers, URI, Cookies) | Medium-High (Requires rule tuning and anomaly threshold adjustments). |
| **eBPF L7 Filtering** | Kernel Socket Layer (tc/cgroup bpf) | <0.5ms | L4/L7 Protocol Headers, Socket State | Low for L4, High implementation complexity for deep HTTP body inspection. |
| **API Gateway In-Line Verification** | Application Edge | +5ms to +20ms | JWT validation, Schema Validation, Rate Limiting | Low (Schema-driven validation against OpenAPI spec). |

---

## 3. Complete Production Manifests and Infrastructure Configurations

### 3.1 Hardened NGINX Web Application Firewall (`/etc/nginx/nginx.conf`)

This production configuration integrates **ModSecurity v3** with the **OWASP Core Rule Set (CRS)**, enforces **TLS 1.3**, strict HTTP response security headers (HSTS, CSP, X-Frame-Options), and hardened rate-limiting zones.

```nginx
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format security_audit '$remote_addr - $remote_user [$time_local] "$request" '
                              '$status $body_bytes_sent "$http_referer" '
                              '"$http_user_agent" "$http_x_forwarded_for" '
                              'ModSecStatus=$modsecurity_status ModSecRuleID=$modsecurity_rule_id';

    access_log /var/log/nginx/access_log.log security_audit;
    error_log  /var/log/nginx/error_log.log warn;

    # Information Disclosure Hardening
    server_tokens off;
    more_clear_headers Server;

    # Buffer Limits against Buffer Overflow & Slowloris DoS
    client_body_buffer_size 128k;
    client_max_body_size 10m;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 8k;
    client_body_timeout 10s;
    client_header_timeout 10s;
    keepalive_timeout 30s;
    send_timeout 10s;

    # Rate Limiting Zones
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    # ModSecurity v3 WAF Global Engine Initialization
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsec/main.conf;

    # Optimized I/O
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # TLS Security Policy
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name app.production.internal;

        ssl_certificate /etc/ssl/certs/app_production.crt;
        ssl_certificate_key /etc/ssl/private/app_production.key;
        ssl_dhparam /etc/ssl/certs/dhparam.pem;

        # Mandatory HTTP Security Response Headers
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "0" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none';" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

        location / {
            limit_req zone=api_limit burst=20 nodelay;
            limit_conn conn_limit 10;

            proxy_pass http://127.0.0.1:8080;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Proxy Buffer Protections
            proxy_buffering on;
            proxy_buffer_size 4k;
            proxy_buffers 8 8k;
        }

        # Block direct access to hidden files
        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }
    }
}
```

---

### 3.2 ModSecurity Core Configuration Configuration (`/etc/nginx/modsec/main.conf`)

This configuration includes base engine parameters and loads the **OWASP Core Rule Set (CRS v3.3/v4.0)** operating in **Anomaly Scoring Mode**.

```apache
# Include Base ModSecurity Configuration
Include /etc/nginx/modsec/modsecurity.conf

# OWASP CRS Engine Setup Configuration
Include /etc/nginx/modsec/coreruleset/crs-setup.conf

# OWASP CRS Rules inclusion
Include /etc/nginx/modsec/coreruleset/rules/*.conf
```

Where `/etc/nginx/modsec/modsecurity.conf` defines key operational overrides:

```apache
# Enable Rule Engine
SecRuleEngine On
SecRequestBodyAccess On

# Request Body Limits
SecRequestBodyLimit 10485760
SecRequestBodyNoFilesLimit 131072
SecRequestBodyLimitAction Reject

# Audit Logging Configuration
SecAuditEngine RelevanceOnly
SecAuditLogRelevantStatus "^(?:5|(?:4(?!(?:04|03))))"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/nginx/modsec_audit.log

# Argument Separator & UTF-8 Validation
SecArgumentSeparator &
SecCookieFormat 0
```

---

### 3.3 Production Custom Seccomp BPF Profile (`/var/lib/kubelet/seccomp/profiles/restricted-microservice.json`)

This JSON document specifies a whitelist seccomp filter denying all dangerous system calls (such as `ptrace`, `sys_kexec_load`, `process_vm_writev`, `unshare`, `init_module`) while explicitly allowing required calls for microservice runtimes.

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept",
        "accept4",
        "access",
        "arch_prctl",
        "bind",
        "brk",
        "clock_gettime",
        "clone",
        "close",
        "connect",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "epoll_wait",
        "execve",
        "exit",
        "exit_group",
        "fcntl",
        "fstat",
        "futex",
        "getcwd",
        "getdents64",
        "getegid",
        "geteuid",
        "getgid",
        "getpeername",
        "getpid",
        "getppid",
        "getsockname",
        "getsockopt",
        "getuid",
        "listen",
        "lseek",
        "madvise",
        "mmap",
        "mprotect",
        "munmap",
        "nanosleep",
        "pipe2",
        "poll",
        "read",
        "readlink",
        "recvfrom",
        "recvmmsg",
        "recvmsg",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "sched_yield",
        "sendmmsg",
        "sendmsg",
        "sendto",
        "set_robust_list",
        "set_tid_address",
        "setsockopt",
        "shutdown",
        "socket",
        "stat",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

---

### 3.4 Production Hardened Kubernetes Deployment Manifest (`deployment-hardened.yaml`)

This complete deployment enforces **Pod Security Standards (Restricted profile)**, including read-only root filesystems, dropping all POSIX capabilities, running as non-root, and attaching the custom Seccomp profile.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production-finance
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: financial-platform
    app.kubernetes.io/managed-by: gitops
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      serviceAccountName: payment-processor-sa
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/restricted-microservice.json
      containers:
        - name: payment-api
          image: internal-registry.enterprise.io/finance/payment-api:v2.4.1@sha256:a5b4c3d2e1f0123456789abcdef0123456789abcdef0123456789abcdef01234
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          ports:
            - containerPort: 8080
              name: http-api
              protocol: TCP
          resources:
            limits:
              cpu: "1"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "128Mi"
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: cache-volume
              mountPath: /var/cache/app
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /livez
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 15
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache-volume
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
```

---

## 4. Real CLI Commands and Expected Terminal Outputs ($)

### 4.1 Verifying Host & Kernel Memory Hardening (ASLR & Binary Flags)

**Check Kernel ASLR Parameter via `sysctl`:**

```bash
$ sysctl kernel.randomize_va_space
kernel.randomize_va_space = 2
```

**Verify Binary Compilation Security Flags using `checksec`:**

```bash
$ checksec --file=/usr/bin/nginx
[*] '/usr/bin/nginx'
    RELRO:    Full RELRO
    Stack:    Canary found
    NX:       NX enabled
    PIE:      PIE enabled
    Fortify:  Enabled
```

**Inspect Process Memory Mapping to Confirm ASLR Execution (Execute twice to confirm dynamic base addresses):**

```bash
$ grep -E "heap|stack" /proc/$(pgrep -n nginx)/maps
55e4b1a23000-55e4b1a45000 rw-p 00000000 00:00 0                          [heap]
7ffca9f52000-7ffca9f73000 rw-p 00000000 00:00 0                          [stack]

$ grep -E "heap|stack" /proc/$(pgrep -n nginx)/maps
5612f8e12000-5612f8e34000 rw-p 00000000 00:00 0                          [heap]
7ffe3b121000-7ffe3b142000 rw-p 00000000 00:00 0                          [stack]
```
*(Note: Addresses `55e4b...` vs `5612f...` differ across invocations, confirming active ASLR).*

---

### 4.2 Simulating Web Application Attacks & Verifying WAF Interception

**Simulate SQL Injection (SQLi) Attempt via `curl`:**

```bash
$ curl -i -s -k -X GET "https://app.production.internal/api/v1/users?id=1%27%20OR%20%271%27%3D%271"
HTTP/2 403 
server: nginx
date: Thu, 06 Aug 2026 17:30:00 GMT
content-type: text/html
content-length: 153
x-frame-options: DENY
x-content-type-options: nosniff

<html>
<head><title>403 Forbidden</title></head>
<body>
<center><h1>403 Forbidden</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

**Inspect ModSecurity Audit Log Entry for Intercepted Attack:**

```bash
$ tail -n 25 /var/log/nginx/modsec_audit.log
---0a3f8c12-A--
[06/Aug/2026:17:30:00 +0000] 192.168.1.50 49210 10.0.0.10 443
---0a3f8c12-B--
GET /api/v1/users?id=1%27%20OR%20%271%27%3D%271 HTTP/2.0
Host: app.production.internal
User-Agent: curl/7.88.1
Accept: */*

---0a3f8c12-F--
HTTP/2 403
Content-Length: 153
Content-Type: text/html

---0a3f8c12-H--
ModSecurity: Warning. Detected SQL Injection (SQLi) attack [file "/etc/nginx/modsec/coreruleset/rules/REQUEST-942-APPLICATION-ATTACK-SQLI.conf"] [line "124"] [id "942100"] [msg "SQL Injection Attack Detected via libinjection"] [data "Matched Data: 1' OR '1'='1 found within ARGS:id"] [severity "CRITICAL"] [tag "application-multi"] [tag "language-multi"] [tag "platform-multi"] [tag "attack-sqli"]
ModSecurity: Access denied with code 403 (phase 2). Primary Anomaly Score: 15, Threshold: 5.
---0a3f8c12-Z--
```

---

### 4.3 Auditing Container Runtime Process Capabilities and Seccomp States

**Inspect Running Kubernetes Pod Security Context State:**

```bash
$ kubectl get pod -n production-finance -l app=payment-processor -o jsonpath='{.items[0].spec.containers[0].securityContext}' | jq .
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

**Verify Active Seccomp Mode and Effective Capabilities of Container Process via Host OS:**

```bash
$ PID=$(pgrep -f "payment-api")
$ cat /proc/$PID/status | grep -E "Uid|Gid|CapInh|CapPrm|CapEff|CapBnd|Seccomp"
Uid:	10001	10001	10001	10001
Gid:	10001	10001	10001	10001
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
Seccomp:	2
```
*(Key Indicator: `Seccomp: 2` represents `SECCOMP_MODE_FILTER` [Seccomp-BPF active]. `CapEff: 0000000000000000` confirms zero elevated capabilities present).*

---

## 5. Verification and Fault Diagnostics Guide

```
                         [ TROUBLESHOOTING FLOW ]
                                    │
          ┌─────────────────────────┴─────────────────────────┐
          ▼                                                   ▼
[ ISSUE A: SYSCALL BLOCK ]                         [ ISSUE B: READ-ONLY FS ]
   Process killed by `SIGSYS`                         Container CrashLoopBackOff
          │                                                   │
          ▼                                                   ▼
1. Query `dmesg | grep audit`                       1. Run `kubectl logs <pod>`
2. Extract syscall number                           2. Check for `EROFS` error
3. Resolve via `ausyscall <nr>`                     3. Identify write directory
4. Update `seccomp.json` whitelist                  4. Add `emptyDir` mount
```

### 5.1 Diagnosing Seccomp Syscall Violations (`SIGSYS` Crashes)

When an application attempts an unallowed syscall under a strict Seccomp BPF whitelist profile, the kernel immediately terminates the process via `SIGSYS` (Signal 31).

#### Step 1: Monitor Kernel Audit Logs for Blocked Syscalls
Execute `dmesg` or monitor `journalctl` filtered by audit records:

```bash
$ journalctl -k -g "type=1326" --no-pager -n 5
Aug 06 17:42:10 node-01.prod kernel: audit: type=1326 audit(1722966130.412:981): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84102 comm="payment-api" exe="/app/payment-api" sig=31 arch=c000003e syscall=203 compat=0 ip=7f8b91012a41 code=0x00000000
```

#### Step 2: Map the Syscall Number to Name
Use `ausyscall` to resolve the architecture syscall number (e.g., `syscall=203` on `arch=c000003e` [x86_64]):

```bash
$ ausyscall x86_64 203
sched_setaffinity
```

#### Step 3: Resolution
If `sched_setaffinity` is required by the process runtime (e.g., Go or Java thread scheduling), append `"sched_setaffinity"` to the allowed syscall array inside `/var/lib/kubelet/seccomp/profiles/restricted-microservice.json` and reload the deployment.

---

### 5.2 Debugging WAF False Positives (ModSecurity Rule Exclusion)

If legitimate user traffic receives HTTP `403 Forbidden` due to overly strict WAF anomaly scoring, perform granular rule exclusion without disabling the WAF engine completely.

#### Step 1: Parse the Audit Log for the Triggering Rule ID
Search `/var/log/nginx/modsec_audit.log` for the specific request ID and locate the failing rule ID:

```bash
$ grep -E "Access denied|id " /var/log/nginx/modsec_audit.log | tail -n 6
[tag "attack-sqli"] ModSecurity: Access denied with code 403 (phase 2). Match of "regex (?:union\s+select)" against "ARGS:query" required. [id "942190"]
```

#### Step 2: Add Rule Exclusion in ModSecurity Configuration
Navigate to `/etc/nginx/modsec/main.conf` and inject a targeted `SecRuleRemoveById` or variable exclusion rule:

```apache
# Disable Rule 942190 exclusively for the specific endpoint path
SecRule REQUEST_URI "@beginsWith /api/v1/analytics/custom-query" \
    "id:100001,phase:1,nolog,pass,ctl:ruleRemoveById=942190"
```

#### Step 3: Test Configuration and Reload NGINX

```bash
$ nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

$ systemctl reload nginx
```

---

### 5.3 Diagnosing Read-Only Root Filesystem Failures (`EROFS`)

When setting `readOnlyRootFilesystem: true` in container security contexts, applications that attempt to write to temporary log directories, pid files, or dynamic caches will fail with `EROFS (Read-only file system)`.

#### Step 1: Capture Container Crash Logs

```bash
$ kubectl logs payment-processor-6d4b65559-x2b8n -n production-finance
2026/08/06 17:45:01 [CRITICAL] Failed to initialize application cache: open /app/cache/session.db: read-only file system
```

#### Step 2: Resolution via Ephemeral Volumes (`emptyDir`)
Identify the missing write locations and declare explicitly scoped ephemeral `emptyDir` mounts in the Pod manifest:

```yaml
volumeMounts:
  - name: app-cache
    mountPath: /app/cache
volumes:
  - name: app-cache
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

---

## 6. References

* **Linux Professional Institute (LPI) Official Objectives**:  
  [https://www.lpi.org/our-certifications/lpic-3-303-overview/](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
* **LPI Wiki — LPIC-3 Security (303-300) Detailed Objectives**:  
  [https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0](https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0)
* **OWASP Core Rule Set (CRS) Official Documentation**:  
  [https://coreruleset.org/docs/](https://coreruleset.org/docs/)
* **ModSecurity v3 NGINX Connector Repository & Reference**:  
  [https://github.com/SpiderLabs/ModSecurity-nginx](https://github.com/SpiderLabs/ModSecurity-nginx)
* **Linux Kernel Documentation — Seccomp BPF Syscall Filtering**:  
  [https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)
* **Kubernetes Documentation — Pod Security Standards (Restricted Profile)**:  
  [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **NIST SP 800-190 — Application Container Security Guide**:  
  [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)