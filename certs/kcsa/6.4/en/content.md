# KCSA Certification Study Material — Topic 6.4: Automation and Tooling

---

## 1. Production Architectural Problem & Motivation

### The Scale and Velocity Problem in Cloud-Native Security
In modern cloud-native environments running hundreds of microservices across multiple Kubernetes clusters, manual security gatekeeping fails. Continuous Integration and Continuous Deployment (CI/CD) pipelines push updates continuously. Human-driven code reviews, manual vulnerability triage, and periodic security audits create severe operational bottlenecks and introduce human error.

Without automated security tooling, production systems suffer from:
1. **Configuration Drift**: Clusters gradually diverge from security baselines due to ad-hoc `kubectl apply` commands, emergency hotfixes, or untracked operational changes.
2. **Supply Chain Vulnerabilities**: Unsigned, unverified container images containing known Common Vulnerabilities and Exposures (CVEs) reach production registries and nodes.
3. **Delayed Threat Detection**: Malicious post-exploitation activities (such as reverse shells, container escapes, or privilege escalations) go undetected because log analysis occurs retroactively rather than in real time at the Linux kernel level.
4. **Compliance Fatigue**: Manual collection of evidence for regulatory frameworks (PCI-DSS, SOC 2, ISO 27001, NIST SP 800-190) requires hundreds of engineering hours per audit cycle.

```
 +----------------------------------------------------------------------------------------------------+
 |                                   SHIFT-LEFT TO RUNTIME PIPELINE                                   |
 +----------------------------------------------------------------------------------------------------+
 |                                                                                                    |
 |   [ Developer Commit ] ---> [ CI Pipeline: Static Analysis & Image Sign ]                          |
 |                                    |                                                               |
 |                                    v                                                               |
 |   [ Registry Push ]   ---> [ Vulnerability & SBOM Attestation Scan ]                               |
 |                                    |                                                               |
 |                                    v                                                               |
 |   [ Kubectl Apply ]   ---> [ K8s API Server: Admission Control (OPA/Kyverno) ]                     |
 |                                    |                                                               |
 |                                    v                                                               |
 |   [ Container Run ]   ---> [ Runtime Observability: eBPF Kernel Probe (Falco) ]                   |
 |                                                                                                    |
 +----------------------------------------------------------------------------------------------------+
```

### Shift-Left vs. Shift-Right Automation Paradigm
Security automation must span the entire lifecycle of a workload:

*   **Shift-Left (Pre-Deployment Automation)**: Integrates security controls into code repositories and CI pipelines. Tools perform static application security testing (SAST), infrastructure-as-code (IaC) scanning, container image vulnerability scanning, Software Bill of Materials (SBOM) generation, and cryptographic image signing (Cosign/Sigstore).
*   **In-Flight (Admission Control Automation)**: Intercepts requests to the Kubernetes API server before object persistence in `etcd`. Dynamic Admission Webhooks (Validating and Mutating) reject non-compliant workloads or automatically inject mandatory security contexts.
*   **Shift-Right (Runtime & Continuous Audit Automation)**: Monitors active processes, file system modifications, network sockets, and system calls inside active containers using eBPF or kernel modules. Simultaneously, automated auditors continuously compare cluster state against CIS (Center for Internet Security) benchmarks.

### Operational Trade-Offs & Architectural Friction
Integrating automated security tooling introduces specific engineering trade-offs:

1. **Webhook Availability vs. Cluster Availability**: If a Validating Admission Webhook configured with `failurePolicy: Fail` becomes unreachable or suffers from high latency, the Kubernetes Control Plane rejects all resource creation and update requests, turning a security tool failure into an outage.
2. **Scan Latency vs. Deployment Velocity**: Deep layer vulnerability scans and attestation verification in CI/CD add latency to pipeline execution. Organizations must tune scan depth and implement aggressive caching layer mechanisms.
3. **eBPF Kernel Overhead vs. Detection Visibility**: Deep kernel syscall tracing captures detailed forensic data but consumes host CPU and memory. Improperly tuned ring buffers can drop events during high system load.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Policy-as-Code Engines: Kyverno vs. OPA Gatekeeper vs. ValidatingAdmissionPolicies

| Feature / Criteria | Kyverno | OPA Gatekeeper | Native ValidatingAdmissionPolicies (K8s 1.30+) |
| :--- | :--- | :--- | :--- |
| **DSL / Language** | Native Kubernetes YAML | Rego (Datalog variant) | CEL (Common Expression Language) |
| **Execution Architecture** | In-cluster Controller & Webhook | In-cluster Controller & OPA Engine | Native API Server Process (No external Webhook) |
| **Mutation Support** | Native (YAML overlays, JSON Patches) | Limited (via Gatekeeper Mutation Manager) | Not supported (Validation only) |
| **Generation Support** | Native (Generates defaults, network policies) | Not supported | Not supported |
| **Image Verification** | Native Sigstore/Cosign integration | Requires external helper / custom Rego | Requires external integration |
| **Learning Curve** | Low (Kubernetes-native syntax) | High (Requires learning Rego) | Low/Medium (Standard CEL expressions) |
| **Latency Impact** | Webhook network roundtrip (~15-50ms) | Webhook network roundtrip (~20-60ms) | In-process execution (<1-3ms) |
| **Fail-Closed Risk** | High (External webhook dependency) | High (External webhook dependency) | Low (Runs directly inside `kube-apiserver`) |

### 2.2 Security Scanners: Trivy vs. Kubescape vs. Kube-bench

| Metric / Dimension | Trivy (Aqua Security) | Kubescape (ARMO) | Kube-bench (Aqua Security) |
| :--- | :--- | :--- | :--- |
| **Primary Domain** | Vulnerability, License, IaC, & SBOM Scanning | Kubernetes Misconfiguration & Compliance | CIS Kubernetes Benchmark Testing |
| **Target Scope** | Images, Filesystems, Git Repos, K8s Clusters | Clusters, Manifests, Helm Charts, Worker Nodes | Control Plane & Worker Node OS/Kubelet Configs |
| **Execution Mode** | CLI, Operator, CI/CD Plugin | CLI, Operator, CI/CD Plugin | Standalone CLI, Container Job, DaemonSet |
| **Framework Mapping** | CVE, NSA-CISA, MITRE ATT&CK | NSA-CISA, MITRE, CIS, SOC 2, PCI-DSS | CIS Benchmarks strictly |
| **Remediation Output** | Fix version per package | Direct code diffs & remediation suggestions | Specific CLI commands & file edits |
| **Resource Overhead** | Low (Single static binary, ephemeral db) | Medium (In-cluster storage, cluster scans) | Extremely Low (Short-lived shell/go execution) |

### 2.3 Runtime Threat Detection Engines: Falco vs. KubeArmor vs. Tracee

| Dimension | Falco (Sysdig / CNCF) | KubeArmor (Accuknox / CNCF) | Tracee (Aqua Security) |
| :--- | :--- | :--- | :--- |
| **Primary Technology** | eBPF / Legacy Kernel Module syscall capture | eBPF + Linux Security Modules (AppArmor, SELinux) | eBPF syscall & kernel function tracing |
| **Enforcement Mode** | Detection & Alerting (Requires Falcosidekick/Response Engine for action) | Inline Prevention & Blocking via LSM | Detection & Event Streaming |
| **Rule Engine** | YAML-based rules matching system calls | YAML-based security policies | Go-based / Rego-based signatures |
| **K8s Metadata Context**| Rich (Enriches raw syscalls with Pod, Namespace, Container ID) | Rich (Native K8s Custom Resource Definition interface) | Rich (Container ID, Process Namespace enrichment) |
| **Kernel Version Requirement** | >= 4.14 (Kernel Module) or >= 5.8 (Modern eBPF) | >= 4.17 (LSM Hooks required for blocking) | >= 4.18 (eBPF CO-RE enabled) |

---

## 3. Complete, Syntactically Valid Production Manifests

### Manifest 1: CIS Benchmark Automated Audit CronJob (`kube-bench`)
This manifest configures a scheduled audit of control plane and node security configs using `kube-bench`. It mounts critical host directories read-only to evaluate file permissions, ownership, and process flags against CIS standards.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-bench-node-audit
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/component: security-audit
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/name: kube-bench
        spec:
          hostPID: true
          serviceAccountName: default
          restartPolicy: Never
          containers:
          - name: kube-bench
            image: aquasec/kube-bench:v0.7.3
            command: ["kube-bench", "node", "--json"]
            securityContext:
              privileged: false
              readOnlyRootFilesystem: true
              allowPrivilegeEscalation: false
              capabilities:
                drop:
                - ALL
            volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/bin
              readOnly: true
          volumes:
          - name: var-lib-kubelet
            hostPath:
              path: /var/lib/kubelet
          - name: etc-systemd
            hostPath:
              path: /etc/systemd
          - name: etc-kubernetes
            hostPath:
              path: /etc/kubernetes
          - name: usr-bin
            hostPath:
              path: /usr/bin
```

### Manifest 2: Kyverno Policy for Image Signature Verification and Root Restriction
This production-grade Kyverno `ClusterPolicy` forces image verification via Cosign (using a public key) and blocks workloads configured to run as root or with privilege escalation capabilities.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-signature-and-non-root
  annotations:
    policies.kyverno.io/title: Enforce Cosign Signature and Non-Root Execution
    policies.kyverno.io/category: Pod Security Standards & Supply Chain
    policies.kyverno.io/severity: critical
    policies.kyverno.io/description: >-
      Verifies that container images are cryptographically signed by the corporate PKI
      using Cosign, and enforces non-root execution constraints on all workloads.
spec:
  validationFailureAction: Enforce
  background: true
  webhookTimeoutSeconds: 15
  rules:
  - name: verify-image-signature
    match:
      any:
      - resources:
          kinds:
          - Pod
    verifyImages:
    - imageReferences:
      - "ghcr.io/corporate-org/*"
      key: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7p+qL8hQZp6Yd2kZ4+L7M+N9HkY1
        rV6U3W4Z8qK9tL2xN5M6P8Q1R7S4T9U2V5W8X1Y4Z7A0B3C6D9E2F5==
        -----END PUBLIC KEY-----
  - name: enforce-non-root-user
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Pods must run as non-root user, disallow privilege escalation, and drop ALL capabilities."
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true
          containers:
          - name: "*"
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities:
                drop:
                - ALL
```

### Manifest 3: OPA Gatekeeper ConstraintTemplate & Constraint for Read-Only Root Filesystem
This manifests defines an OPA Gatekeeper `ConstraintTemplate` in Rego that checks if all containers in a Pod enforce a read-only root file system, followed by the instantiated `Constraint`.

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sreadonlyrootfilesystem
  annotations:
    metadata.gatekeeper.sh/title: Read-Only Root Filesystem
    description: >-
      Requires container root filesystems to be read-only.
spec:
  crd:
    spec:
      names:
        kind: K8sReadOnlyRootFilesystem
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sreadonlyrootfilesystem

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not is_readonly(container)
          msg := sprintf("Container '%v' must set securityContext.readOnlyRootFilesystem to true", [container.name])
        }

        is_readonly(container) {
          container.securityContext.readOnlyRootFilesystem == true
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sReadOnlyRootFilesystem
metadata:
  name: enforce-readonly-root-fs
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
      - "staging"
    excludedNamespaces:
      - "kube-system"
```

### Manifest 4: Production Falco Custom Rule for Runtime Threat Detection
This configuration defines a custom Falco rule designed to trigger an alert if a shell process (such as `bash` or `sh`) is spawned inside a running pod within sensitive namespaces, or if a binary attempts to alter system execution binaries.

```yaml
- rule: Terminal Shell Spawned in Sensitive Pod
  desc: Detects terminal shell execution inside production pods which may indicate unauthorized interactive access or post-exploitation activity.
  condition: >
    container.id != "" and
    evt.type = execve and
    evt.dir = < and
    proc.name in (bash, sh, zsh, ksh, ash) and
    k8s.ns.name in (production, payment-processing, core-infrastructure) and
    not user.name in (monitoring-agent)
  output: >
    CRITICAL: Interactive shell spawned in production container 
    (user=%user.name user_loginuid=%user.loginuid pod=%k8s.pod.name ns=%k8s.ns.name 
    container=%container.name image=%container.image.repository:%container.image.tag 
    cmdline=%proc.cmdline parent=%proc.pname pid=%proc.pid)
  priority: CRITICAL
  tags: [k8s, runtime, execution, pci-dss, mitre_execution]
```

---

## 4. Real CLI Commands and Actual Terminal Outputs ($)

### 4.1 Auditing Nodes with `kube-bench`
Run `kube-bench` directly on a target worker node to evaluate compliance against CIS benchmarks.

```bash
$ kube-bench node --benchmark cis-1.8 --check 4.1.1,4.1.2 --json | jq .
```
```json
{
  "Controls": [
    {
      "id": "4",
      "text": "Worker Node Security Configuration",
      "tests": [
        {
          "section": "4.1",
          "desc": "Worker Node Configuration Files",
          "results": [
            {
              "test_number": "4.1.1",
              "test_desc": "Ensure that the kubelet service file permissions are set to 600 or more restrictive",
              "status": "PASS",
              "actual_value": "permissions are 600",
              "expected_result": "permissions are 600 or more restrictive"
            },
            {
              "test_number": "4.1.2",
              "test_desc": "Ensure that the kubelet service file ownership is set to root:root",
              "status": "FAIL",
              "actual_value": "ownership is 1000:1000",
              "expected_result": "ownership is root:root",
              "remediation": "Run 'chown root:root /etc/systemd/system/kubelet.service.d/10-kubeadm.conf' to fix ownership."
            }
          ]
        }
      ]
    }
  ],
  "Totals": {
    "total_pass": 1,
    "total_fail": 1,
    "total_warn": 0,
    "total_info": 0
  }
}
```

### 4.2 Image Vulnerability Scanning & Attestation with `trivy`
Scan a remote image in a registry for critical security vulnerabilities, ignoring unfixed CVEs to focus actionable engineering effort.

```bash
$ trivy image --severity CRITICAL,HIGH --ignore-unfixed --format table ghcr.io/corporate-org/payment-service:v2.1.0
```
```text
2026-08-07T14:22:01.102Z	INFO	Vulnerability database is up to date
2026-08-07T14:22:02.441Z	INFO	Detected OS: alpine 3.18.2
2026-08-07T14:22:02.442Z	INFO	Detecting Alpine vulnerabilities...

ghcr.io/corporate-org/payment-service:v2.1.0 (alpine 3.18.2)
=============================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬────────────────────────────────────────────────────────┐
│   Library    │ Vulnerability  │ Severity │ InstalledVer │     FixedVer      │                         Title                          │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼────────────────────────────────────────────────────────┤
│ libcrypto3   │ CVE-2023-3817  │ HIGH     │ 3.1.1-r1     │ 3.1.1-r3          │ openssl: excessive time checking DH keys               │
│ openssl      │ CVE-2023-5363  │ CRITICAL │ 3.1.1-r1     │ 3.1.1-r3          │ openssl: incorrect key length checking in ciphers      │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴────────────────────────────────────────────────────────┘
```

### 4.3 Container Image Signing and Verification with `cosign`
Generate a keypair, sign an image artifact, and verify its cryptographic signature.

```bash
$ cosign generate-key-pair
```
```text
Enter password for private key: 
Confirm password for private key: 
Private key written to cosign.key
Public key written to cosign.pub
```

```bash
$ cosign sign --key cosign.key ghcr.io/corporate-org/payment-service:v2.1.0
```
```text
Enter password for private key: 
Pushing signature to: ghcr.io/corporate-org/payment-service:sha256-a1b2c3d4e5f6...sig
```

```bash
$ cosign verify --key cosign.pub ghcr.io/corporate-org/payment-service:v2.1.0
```
```text
Verification for ghcr.io/corporate-org/payment-service:v2.1.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"ghcr.io/corporate-org/payment-service"},"image":{"docker-manifest-digest":"sha256:8f4c2e617a99b2e7d3f10111213141516171819202122232425262728293031a"},"type":"cosign container image signature"},"optional":null}]
```

### 4.4 Admission Webhook Enforcement Testing
Attempt to deploy a non-compliant container manifest to verify that Kyverno blocks the request at admission time.

```bash
$ kubectl apply -f insecure-pod.yaml
```
```text
Error from server (Forbidden): error when creating "insecure-pod.yaml": admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request:

resource Pod/production/insecure-nginx was blocked due to the following policies:

enforce-signature-and-non-root:
  verify-image-signature:
    failed to verify signature for ghcr.io/untrusted/nginx:latest: no matching signatures found
  enforce-non-root-user:
    autogen-enforce-non-root-user: 'validation error: Pods must run as non-root user, disallow privilege escalation, and drop ALL capabilities. Rule autogen-enforce-non-root-user failed at path /spec/template/spec/securityContext/runAsNonRoot/'
```

---

## 5. Verification & Failure Diagnostics Guide

```
 +----------------------------------------------------------------------------------------------------+
 |                                ADMISSION WEBHOOK DIAGNOSTIC WORKFLOW                               |
 +----------------------------------------------------------------------------------------------------+
 |                                                                                                    |
 |  [ Pod Creation Fails ]                                                                            |
 |          |                                                                                         |
 |          v                                                                                         |
 |  Is kube-apiserver throwing API server timeout (504)?                                              |
 |          |-- YES --> Check Webhook Pod status, TLS secret expiration, and Cluster Network CNI.     |
 |          |                                                                                         |
 |          +-- NO  --> Is failure caused by Policy violation?                                        |
 |                       |-- YES --> Inspect policy rule definitions & pod SecurityContext.           |
 |                       |-- NO  --> Check webhook failurePolicy (Fail vs Ignore).                     |
 |                                                                                                    |
 +----------------------------------------------------------------------------------------------------+
```

### Diagnostic Procedure 1: Troubleshooting Admission Webhook Failure Loops
When `kube-apiserver` cannot reach an admission webhook (e.g., Kyverno or Gatekeeper), API requests block or time out.

1.  **Inspect Webhook Configurations**:
    ```bash
    kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o wide
    ```
2.  **Verify Webhook Service Endpoints**:
    Check if the endpoints backed by the admission controller service are active and healthy:
    ```bash
    kubectl get endpoints -n kyverno kyverno-svc
    ```
3.  **Validate Webhook TLS Certificate Expiration**:
    Admission webhooks require valid TLS certificates trusted by `kube-apiserver` CA bundle. Check certificate validity:
    ```bash
    kubectl get secret -n kyverno kyverno-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
    ```
4.  **Execute Emergency Break-Glass Procedure**:
    If the control plane is locked out due to a broken webhook configured with `failurePolicy: Fail`, temporarily patch the webhook configuration to `Ignore`:
    ```bash
    kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
      --type='json' -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"}]'
    ```

### Diagnostic Procedure 2: Debugging Falco eBPF Event Drops & Performance Issues
If runtime threat detection misses events or crashes during traffic spikes, inspect kernel event buffer health.

1.  **Check Falco Pod Logs for Buffer Drops**:
    ```bash
    kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -E "drop|buffer|overload"
    ```
    *Expected Warning Output*:
    `14:35:12.102341000: Warning: eBPF ring buffer full. Dropped 4512 events.`

2.  **Tune eBPF Ring Buffer Capacities**:
    Edit the Falco configuration (`falco.yaml`) to increase the eBPF buffer size:
    ```yaml
    sysctls:
      ebpf:
        buf_size_preset: 4 # Increases buffer memory allocation (1=small, 4=max)
    ```

3.  **Verify Kernel Driver Status**:
    Confirm whether Falco is operating via modern eBPF, legacy eBPF, or kernel module:
    ```bash
    kubectl exec -ti -n falco daemonset/falco -- falco-driver-loader status
    ```
    *Expected Output*:
    `[*] eBPF probe is loaded and active in the kernel.`

### Diagnostic Procedure 3: Resolving Image Signature Verification Failures
When valid images are rejected by Kyverno or Cosign admission controllers:

1.  **Inspect Raw Image Manifest Digest**:
    Signatures map to exact image digests, not mutable tags. Verify the image digest:
    ```bash
    crane digest ghcr.io/corporate-org/payment-service:v2.1.0
    ```
2.  **Fetch Signatures Manually**:
    Determine if the signature artifact exists in the OCI registry:
    ```bash
    cosign tree ghcr.io/corporate-org/payment-service:v2.1.0
    ```
3.  **Check Cosign Key Mismatch**:
    Verify that the public key configured inside the Kyverno `ClusterPolicy` matches the key used during the CI `cosign sign` execution:
    ```bash
    cosign verify --key /tmp/cluster-public-key.pub ghcr.io/corporate-org/payment-service:v2.1.0
    ```

---

## 6. References

*   **CNCF KCSA Official Curriculum**:  
    [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

*   **Kubernetes Dynamic Admission Control Documentation**:  
    [https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

*   **Kubernetes Validating Admission Policy (CEL)**:  
    [https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)

*   **Kyverno Documentation & Security Policies**:  
    [https://kyverno.io/docs/](https://kyverno.io/docs/)

*   **OPA Gatekeeper Documentation**:  
    [https://open-policy-agent.github.io/gatekeeper/website/docs/](https://open-policy-agent.github.io/gatekeeper/website/docs/)

*   **Aqua Security Trivy Documentation**:  
    [https://aquasecurity.github.io/trivy/latest/](https://aquasecurity.github.io/trivy/latest/)

*   **Sigstore Cosign Documentation**:  
    [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)

*   **Falco Runtime Security Documentation**:  
    [https://falco.org/docs/](https://falco.org/docs/)

*   **CIS Kubernetes Benchmarks**:  
    [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)