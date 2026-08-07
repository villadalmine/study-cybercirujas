# Advanced Production Study Guide: LPI Security Essentials (020-100) — Topic 1.1: Security Concepts

**Target Certification:** LPI Security Essentials (Exam 020-100, Version 1.0)  
**Topic Code:** 1.1 Security Concepts (Goals, Roles, Actors, Risk Assessment & Ethical Behavior)  
**Exam Weight:** 20  
**Target Audience:** Senior SREs, Security Engineers, and Principal Platform Architects  

---

## 1. Motivation and Production Architectural Problem

### 1.1 The Production Security Crisis in Cloud-Native Infrastructure
In modern enterprise platforms, security is no longer an isolated perimeter defense mechanism managed by a dedicated compliance team. Cloud-native architectures introduce massive dynamic surface areas: hundreds of ephemeral Kubernetes pods, automated CI/CD pipelines deploying tens of times per day, microservice-to-microservice mutual TLS connections, and sprawling third-party software supply chains.

Under this operational paradigm, classic security concepts must be refactored from abstract compliance definitions into hard engineering primitives. A single unvetted container image or permissive service account token can compromise an entire cluster. Platform engineers and Site Reliability Engineers (SREs) must enforce security without degrading release velocity, application throughput, or site reliability.

```
+-----------------------------------------------------------------------------------+
|                            PRODUCTION ATTACK SURFACE                              |
|                                                                                   |
|   +------------------+         +------------------+         +-----------------+   |
|   |  External Edge   | ------> | Kubernetes Ingress| ------> | Microservices   |   |
|   | (DDoS / Scanners)|         |  (TLS Termination) |         | (App Runtime)   |   |
|   +------------------+         +------------------+         +-----------------+   |
|                                                                      |            |
|                                                                      v            |
|   +------------------+         +------------------+         +-----------------+   |
|   | Insider Threat / | <------ |  CI/CD Pipeline  | <------ | Node OS Kernel  |   |
|   | Supply Chain     |         |  (Poisoned Image)|         | (eBPF / Audit)  |   |
|   +------------------+         +------------------+         +-----------------+   |
+-----------------------------------------------------------------------------------+
```

### 1.2 Core Security Objectives & Structural Mechanics

Security engineering rests upon four foundational guarantees known collectively in production systems as the extended **CIA+N** framework:

1. **Confidentiality:** Ensuring data in-transit, in-rest, and in-use is inaccessible to unauthorized actors.
   - *Production implementation:* Envelope encryption (AWS KMS / HashiCorp Vault), TLS 1.3 with Perfect Forward Secrecy (PFS), ephemeral in-memory processing.
2. **Integrity:** Ensuring that telemetry, application state, data stores, and binaries have not been altered in an unauthorized or undetected manner.
   - *Production implementation:* Cryptographic signatures (Sigstore/Cosign), immutable container file systems (`readOnlyRootFilesystem: true`), cryptographic checksum verification (SHA-256 digest pinning).
3. **Availability:** Ensuring computing systems, network pathways, and datastores remain responsive to legitimate traffic despite node failures, volumetric attacks, or application crashes.
   - *Production implementation:* DDoS mitigation (Anycast, rate-limiting), fault-tolerant topology spreads, horizontal auto-scaling (HPA), circuit breaking, gracefully degraded service modes.
4. **Non-repudiation:** Providing undeniable proof of an action's origin and integrity so that actors cannot deny authoring an API request, code commit, or infrastructure change.
   - *Production implementation:* Cryptographically signed Git commits (GPG/SSH keys), append-only immutable audit logs (AWS CloudTrail, Kubernetes Audit logs stored in WORM storage).

### 1.3 Threat Vectors, Actors, and Risk Calculus

Risk assessment in production SRE environments relies on quantitative scoring. The classical risk formula utilized across SRE risk management models is defined as:

$$\text{Risk} = \text{Threat} \times \text{Vulnerability} \times \text{Impact}$$

Where:
- **Threat (T):** The probability of a threat actor exercising a given vulnerability (ranging from 0.0 to 1.0).
- **Vulnerability (V):** The severity and accessibility of a security flaw (e.g., CVSS Base Score scaled from 0.0 to 1.0).
- **Impact (I):** The quantitative monetary or operational damage incurred by a breach (measured in downtime cost, SLA penalties, data exposure liability).

#### Threat Actor Classifications in Enterprise Environments
- **Script Kiddies / Automated Botnets:** High-frequency, low-sophistication scans seeking known CVEs (e.g., Log4Shell, unauthenticated Redis/Memcached endpoints).
- **Malicious Insiders:** High-privilege access holders executing privilege escalation or unauthorized data exfiltration. Mitigated by Least Privilege, Separation of Duties (SoD), and Just-In-Time (JIT) access policies.
- **Advanced Persistent Threats (APTs):** State-sponsored or high-capability organized syndicates executing zero-day exploits, supply-chain contamination, and silent lateral movement.
- **Automated Supply Chain Attackers:** Typosquatting dependencies in npm/PyPI, exploiting unpinned GitHub Actions, or compromising base container images.

---

## 2. Technical Comparisons and Architectural Trade-offs

Selecting security controls requires managing explicit engineering trade-offs. Hardening an application endpoint often introduces latency or developer friction; failing to harden introduces catastrophic blast radiuses.

### 2.1 Perimeter Defense vs. Zero-Trust Architecture (ZTA)

| Metric / Parameter | Traditional Perimeter Security (Castle & Moat) | Cloud-Native Zero-Trust Architecture (ZTA) |
| :--- | :--- | :--- |
| **Trust Model** | Implicit trust for all traffic within internal network (VPC/LAN). | Explicit verification for every request regardless of location. |
| **Authentication/Authorization** | Handled at the edge VPN / Reverse Proxy once. | Continuous mTLS + fine-grained SPIFFE/SPIRE identity tokens per service call. |
| **Blast Radius** | Extreme. Network compromise exposes all internal services. | Minimal. Micro-segmented network policies isolate compromised containers. |
| **Operational Complexity** | Low to Moderate (centralized firewalls/VPC peering). | High (requires service mesh, PKI rotation engine, policy engines). |
| **Latency Impact** | Near zero within the internal network. | Microsecond-level overhead per hop due to mTLS handshakes and policy evaluation. |

### 2.2 Access Control Paradigms: RBAC vs. ABAC

| Feature | Role-Based Access Control (RBAC) | Attribute-Based Access Control (ABAC) |
| :--- | :--- | :--- |
| **Decision Factors** | Statically assigned user roles (e.g., `developer`, `admin`). | Dynamic context (user role, IP address, device posture, time of day, classification label). |
| **Policy Granularity** | Coarse-grained / Static. | Fine-grained / Hyper-dynamic. |
| **Management at Scale** | Suffers from "Role Explosion" as rules scale. | Complex policy evaluation language (e.g., Rego, Cedar). |
| **Kubernetes Native Support**| Native (`rbac.authorization.k8s.io/v1`). | External Webhook required (OPA Gatekeeper / Kyverno / Custom Webhook). |

### 2.3 Vulnerability Management Scoring: CVSS v3.1 vs. Production Exploitability (EPSS)

```
        CVSS Base Score (Theoretical Severity: 0-10)
                            VS
        EPSS Probability (Real-world Exploit Likelihood: 0-100%)
```

- **CVSS (Common Vulnerability Scoring System):** Measures *intrinsic technical severity* (e.g., Attack Vector, Complexity, Privileges Required, Impact metrics).
- **EPSS (Exploit Prediction Scoring System):** Predicts the *probability* that a vulnerability will actually be exploited in the wild within 30 days based on real-time threat intelligence.
- **Production Trade-off:** Patching solely by CVSS $\ge 9.0$ creates operational burnout ("alert fatigue"). SRE policy prioritizes vulnerabilities where $\text{CVSS} \ge 7.0$ **AND** $\text{EPSS} > 0.10$ (10% exploit probability in the wild).

---

## 3. Complete Syntactically Valid Manifests and Configurations

The following manifests demonstrate production-grade implementation of security controls supporting Confidentiality, Integrity, Non-repudiation, and Availability.

### 3.1 Strict Network Micro-segmentation: Kubernetes NetworkPolicy
This manifest enforces Zero-Trust network isolation for a production backend application. It denies all default ingress/egress traffic and explicitly allows only authenticated ingress from the API Gateway on port 8080 and egress to DNS (port 53) and Postgres (port 5432).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: enforce-strict-backend-isolation
  namespace: production
  labels:
    tier: backend
    app.kubernetes.io/sec-zone: restricted
spec:
  podSelector:
    matchLabels:
      app: payment-processor
      tier: backend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow ingress strictly from pods labeled role=api-gateway on port 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: production
          podSelector:
            matchLabels:
              role: api-gateway
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # Allow egress strictly to CoreDNS for name resolution
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow egress strictly to managed PostgreSQL database instances
    - to:
        - ipBlock:
            cidr: 10.240.16.0/24
      ports:
        - protocol: TCP
          port: 5432
```

### 3.2 Immutability and Runtime Security: PodSecurity Admission Standards
This manifest enforces absolute runtime container immutability, prohibiting privilege escalation, blocking root execution, dropping all Linux capabilities, and making the root filesystem read-only.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened-payment-service
  namespace: production
  labels:
    app: payment-processor
    sec.tier: critical
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
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: payment-app
          image: internal-registry.enterprise.io/finance/payment-processor:v2.4.1@sha256:d8e9f2a24c52b477bc2b9e69315d18d45e0d4dfef17bc9ef4a8ef7be12185c7f
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
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
          ports:
            - containerPort: 8080
              name: http
          volumeMounts:
            - mountPath: /tmp
              name: ephemeral-tmp
      volumes:
        - name: ephemeral-tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
```

### 3.3 Linux System Audit Rules: `/etc/audit/rules.d/audit.rules`
To guarantee non-repudiation and forensic traceability on Linux host infrastructure, this system configuration monitors privilege escalation (`sudoers`), execution of binary files, unauthorized modification of security configurations, and user authentication events.

```ini
# Delete all existing audit rules
-D

# Set buffer size to handle high-throughput event spikes
-b 8192

# Set failure mode to silent panic (1 = printk, 2 = panic)
-f 1

# Monitor changes to system time and date
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S clock_settime -k time-change

# Monitor identity and user/group modifications
-w /etc/group -p wa -k identity-modification
-w /etc/passwd -p wa -k identity-modification
-w /etc/gshadow -p wa -k identity-modification
-w /etc/shadow -p wa -k identity-modification
-w /etc/security/opasswd -p wa -k identity-modification

# Monitor changes to network configuration
-w /etc/issue -p wa -k network-config
-w /etc/issue.net -p wa -k network-config
-w /etc/hosts -p wa -k network-config
-w /etc/sysconfig/network -p wa -k network-config

# Monitor privilege escalation mechanisms (Sudoers)
-w /etc/sudoers -p wa -k privilege-escalation
-w /etc/sudoers.d/ -p wa -k privilege-escalation

# Audit execution of privileged binaries (setuid / setgid)
-a always,exit -F arch=b64 -F euid=0 -F auid>=1000 -F auid!=4294967295 -S execve -k privilege-execution

# Lock the audit configuration to prevent runtime modification (requires reboot to change)
-e 2
```

---

## 4. Real CLI Commands and Expected Terminal Outputs

The following workflows execute real security validation commands, image scans, audit log searches, and forensic evidence gathering.

### 4.1 Vulnerability Scanning and Risk Classification with Trivy

Run an automated static vulnerability scan against a container image to assess CVE severity and EPSS ratings prior to deployment.

```bash
$ trivy image --severity HIGH,CRITICAL --format table internal-registry.enterprise.io/finance/payment-processor:v2.4.1
```

```text
2026-08-07T00:41:12.102Z	INFO	Vulnerability database is up to date
2026-08-07T00:41:13.489Z	INFO	Detected OS: alpine 3.18.2
2026-08-07T00:41:13.490Z	INFO	Detecting Alpine vulnerabilities...
2026-08-07T00:41:13.512Z	INFO	Number of language-specific files: 1
2026-08-07T00:41:13.512Z	INFO	Detecting Go vulnerabilities...

internal-registry.enterprise.io/finance/payment-processor:v2.4.1 (alpine 3.18.2)
=================================================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬─────────────────────────┐
│   LIBRARY    │ VULNERABILITY  │ SEVERITY │ INSTALLED    │ FIXED VERSION     │          TITLE          │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼─────────────────────────┤
│ libcrypto3   │ CVE-2023-3817  │ HIGH     │ 3.1.1-r1     │ 3.1.1-r3          │ OpenSSL: excess time    │
│              │                │          │              │                   │ checking DH keys        │
│ openssl      │ CVE-2023-5363  │ CRITICAL │ 3.1.1-r1     │ 3.1.1-r3          │ OpenSSL: Incorrect key  │
│              │                │          │              │                   │ length processing       │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴─────────────────────────┘
```

### 4.2 Verifying Non-Repudiation with Linux `ausearch` and `auparse`

Query the Linux kernel audit subsystem to track unauthorized modifications to `/etc/sudoers` or execution of privileged commands by user accounts.

```bash
$ sudo ausearch -k privilege-escalation --start recent -i
```

```text
----
time->Fri Aug  7 00:32:10 2026
type=PROCTITLE msg=audit(1786081930.412:9481): proctitle=56492F6574632F7375646F657273
type=PATH msg=audit(1786081930.412:9481): item=1 name="/etc/sudoers" inode=131089 dev=08:01 mode=0100440 ouid=0 ogid=0 rdev=00:00 nametype=NORMAL cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0
type=PATH msg=audit(1786081930.412:9481): item=0 name="/etc/" inode=131073 dev=08:01 mode=040755 ouid=0 ogid=0 rdev=00:00 nametype=PARENT cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0
type=SYSCALL msg=audit(1786081930.412:9481): arch=x86_64 syscall=openat success=yes exit=3 a0=ffffff9c a1=7ffd281a8b90 a2=241 a3=1b6 items=2 ppid=1420 pid=2819 auid=sysadmin uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts1 ses=4 comm="vim" exe="/usr/bin/vim" key="privilege-escalation"
```

### 4.3 Auditing Active Network Exposure via `nmap` and `ss`

Audit a running host to discover open sockets, unexpected listening services, and active network connections violating perimeter boundaries.

```bash
$ sudo ss -tulpn
```

```text
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process                                                                         
tcp    LISTEN  0       4096             0.0.0.0:22             0.0.0.0:*      users:(("sshd",pid=892,fd=3))                                                   
tcp    LISTEN  0       511              0.0.0.0:8080           0.0.0.0:*      users:(("payment-app",pid=4102,fd=7))                                           
tcp    LISTEN  0       4096       127.0.0.53%lo:53             0.0.0.0:*      users:(("systemd-resolve",pid=621,fd=13))                                       
tcp    LISTEN  0       128            127.0.0.1:6379           0.0.0.0:*      users:(("redis-server",pid=1120,fd=6))                                          
```

Perform an authenticated TCP SYN stealth scan against a target node to locate rogue ports:

```bash
$ nmap -sS -p 1-10000 -T4 -n 10.240.0.45
```

```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-07 00:43 UTC
Nmap scan report for 10.240.0.45
Host is up (0.00042s latency).
Not shown: 9997 closed tcp ports (reset)
PORT     STATE SERVICE
22/tcp   open  ssh
8080/tcp open  http-proxy
6379/tcp open  redis

Nmap done: 1 IP address (1 host up) scanned in 0.84 seconds
```

---

## 5. Verification and Failure Diagnostics Guide

When security controls fail or trigger incidents, SREs must follow a systematic diagnostic methodology to trace root causes without destroying forensic evidence.

### 5.1 SRE Security Incident Diagnostic Flowchart

```
                 +--------------------------------------+
                 |      Security Alert / Incident       |
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  1. Containment & Pod Isolation      |
                 |     (Apply Isolation NetworkPolicy)  |
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  2. Memory & Volatile State Capture  |
                 |     (Dump process tree & open files) |
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  3. Log & Telemetry Forensic Audit   |
                 |     (Inspect auditd / k8s audit logs)|
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  4. Root Cause Analysis & Mitigation |
                 |     (Revoke creds, patch CVE, redeploy)|
                 +--------------------------------------+
```

### 5.2 SRE Troubleshooting Matrix: Common Failure Modes

| Symptom / Alert | Root Cause Hypothesis | Verification Command | Remediation Action |
| :--- | :--- | :--- | :--- |
| **`ErrImagePull` or `ImagePullBackOff`** | Container image failed cryptographic signature verification or vulnerability threshold gate. | `cosign verify --key cosign.pub $IMAGE` | Re-sign trusted pipeline artifacts or patch failing dependencies. |
| **Pod crashing with `OOMKilled` or `CrashLoopBackOff`** | Memory limit reached due to `readOnlyRootFilesystem: true` writing to forbidden directory. | `kubectl logs $POD -p \| grep "Read-only file system"` | Mount temporary ephemeral `emptyDir` volumes to specific writable paths (e.g., `/tmp`). |
| **`403 Forbidden` API call from ServiceAccount** | RBAC permission drift or missing `ClusterRoleBinding`. | `kubectl auth can-i create pods --as=system:serviceaccount:prod:my-sa` | Apply corrected RBAC manifest using principle of least privilege. |
| **Volumetric traffic spike on backend pod** | Ingress NetworkPolicy missing; direct node-to-node traffic bypassed perimeter control. | `kubectl get netpol -n production` | Deploy strict namespace-wide default-deny `NetworkPolicy`. |

### 5.3 Step-by-Step Incident Forensics: Investigating Rogue Process Execution

If a runtime alert (e.g., Falco) flags an unexpected binary execution (`/tmp/malware`) inside a running container, execute the following steps:

#### Step 1: Immediately Isolate the Pod Network
Apply an emergency quarantine network policy targeting the compromised pod:

```bash
$ kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine-compromised-pod
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: payment-processor
      status: compromised
  policyTypes:
    - Ingress
    - Egress
EOF
```

#### Step 2: Extract Process Memory and Network Sockets
Do not terminate the pod immediately; terminating the pod deletes volatile forensic evidence stored in Linux pseudo-filesystems (`/proc`).

```bash
# Obtain the container ID and process ID (PID) on the host node
$ CONTAINER_ID=$(docker ps --filter "label=io.kubernetes.pod.name=hardened-payment-service-75b5b9c564-x9q8z" -q)
$ HOST_PID=$(docker inspect --format '{{ .State.Pid }}' $CONTAINER_ID)

# Inspect open file descriptors and active sockets of the suspect process
$ sudo ls -la /proc/$HOST_PID/fd
$ sudo cat /proc/$HOST_PID/cmdline
```

#### Step 3: Inspect Kernel Audit Logs for Binary Execution
Retrieve the exact audit payload to identify the real user identity (`auid`) and parent process ID (`ppid`).

```bash
$ sudo ausearch -p $HOST_PID --format raw | auparse -i
```

```text
type=SYSCALL msg=audit(08/07/2026 00:44:12.891:10421) : arch=x86_64 syscall=execve success=yes exit=0 a0=0x55d8f1e20a10 a1=0x55d8f1e20aa8 a2=0x55d8f1e20b18 items=2 ppid=4102 pid=4892 auid=sysadmin uid=10001 gid=10001 euid=10001 exe=/tmp/miner key=privilege-execution
```

#### Step 4: Remediate and Evict
Revoke exposed service account tokens, update base images, rotate database credentials stored in HashiCorp Vault, and redeploy the deployment revision.

---

## 6. References

- **Linux Professional Institute (LPI) Security Essentials Overview:**  
  [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)
- **LPI Security Essentials Objectives 020-100:**  
  [https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0](https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0)
- **NIST SP 800-53 Rev. 5 — Security and Privacy Controls for Information Systems:**  
  [https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- **CNCF Financial & Security SIG — Cloud Native Security Paper:**  
  [https://github.com/cncf/tag-security/blob/main/security-whitepaper/v2/cloud-native-security-whitepaper-v2.md](https://github.com/cncf/tag-security/blob/main/security-whitepaper/v2/cloud-native-security-whitepaper-v2.md)
- **FIRST Common Vulnerability Scoring System (CVSS) v3.1 Specification:**  
  [https://www.first.org/cvss/v3.1/specification-document](https://www.first.org/cvss/v3.1/specification-document)
- **FIRST Exploit Prediction Scoring System (EPSS):**  
  [https://www.first.org/epss/](https://www.first.org/epss/)
- **Kubernetes Documentation — Pod Security Standards & Network Policies:**  
  [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)  
  [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)