# KCSA Study Guide: Domain 1.6 – Workload and Application Code Security

## 1. Motivation & Production Architectural Problem

In cloud-native production environments, the container runtime boundary is the final line of defense against infrastructure compromise. Applications deployed to Kubernetes clusters continuously ingest untrusted input across public and internal networks. If an application contains vulnerabilities (such as Remote Code Execution, SQL Injection, or arbitrary file writes), an attacker can exploit the process to gain execution capabilities inside the container.

### The Production Threat Landscape

Without rigorous workload security controls, a compromised container process can translate directly into a cluster-wide breach:

1. **Privilege Escalation via Default Root Execution**: Containers by default often run as `root` (UID 0). If an application vulnerability allows arbitrary code execution, the attacker inherits root access inside the container filesystem. Combined with un-dropped Linux capabilities (e.g., `CAP_SYS_ADMIN`, `CAP_NET_RAW`), the attacker can break out of container namespaces or alter system states.
2. **Writable Root Filesystem Staging Grounds**: A writable root filesystem permits malicious actors to download binary payloads, inject dynamic shared libraries (`.so`), modify application binaries, or write persistent reverse shell scripts into system directories like `/tmp`, `/var/tmp`, or `/usr/local/bin`.
3. **Supply Chain Poisoning and Unsigned Artifacts**: Deploying container images sourced from public registries or unvalidated build pipelines introduces non-deterministic runtime behaviors. Attackers targeting upstream dependencies (via typosquatting, dependency confusion, or compromised build agents) can inject backdoor code. If images are identified only by mutable tags (e.g., `:latest` or `:v1.2.0`), container engines can pull modified, malicious layers without detection.
4. **Host Namespace & Device Exposure**: Configuration misconfigurations such as setting `hostNetwork: true`, `hostPID: true`, `hostIPC: true`, or mounting host paths (`hostPath`) expose the underlying node's network interfaces, process trees, and kernel interfaces directly to the container workload.

### Architectural Strategy: Defense-in-Depth

```
  +-----------------------------------------------------------------------+
  |                    Build & Supply Chain Layer                         |
  |  - Minimal Base Images (Distroless / Scratch)                         |
  |  - Static Vulnerability Scanning & SBOM Generation (Trivy/Syft)        |
  |  - Cryptographic Artifact Signing (Cosign / Sigstore)                |
  +-----------------------------------------------------------------------+
                                      |
                                      v
  +-----------------------------------------------------------------------+
  |                    Admission & Policy Control Layer                   |
  |  - Immutable Digest Enforcement (sha256 validation)                    |
  |  - In-Cluster Signature Verification (Kyverno / OPA Gatekeeper)       |
  |  - Pod Security Admission (Restricted PSS Enforcement)                |
  +-----------------------------------------------------------------------+
                                      |
                                      v
  +-----------------------------------------------------------------------+
  |                   Workload Runtime Isolation Layer                    |
  |  - Non-Root Execution (runAsNonRoot: true, runAsUser > 10000)         |
  |  - Immutable Filesystem (readOnlyRootFilesystem: true)                |
  |  - Privilege Restrictions (allowPrivilegeEscalation: false)            |
  |  - Capability Stripping (capabilities: drop: ["ALL"])                |
  |  - System Call Filtering (seccompProfile: RuntimeDefault)             |
  +-----------------------------------------------------------------------+
```

To eliminate these attack vectors, Platform Architects enforce a Zero-Trust Container Architecture centered on three core tenets:
* **Build Integrity**: Verification of container image provenance, SBOM generation, and cryptographic signatures before execution.
* **Declarative Admission Control**: Automated rejection of non-compliant manifests via Kubernetes Pod Security Admission (PSA) and Policy-as-Code engines (Kyverno / OPA Gatekeeper).
* **Least-Privilege Runtime Constraints**: Immutable, non-root execution environments configured strictly via Kubernetes `securityContext` attributes backed by Linux kernel primitives (Namespaces, cgroups v2, Capabilities, Seccomp, and LSMs).

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Base Image Architecture Strategy

| Feature / Metric | Standard OS (Debian / Ubuntu) | Minimal Linux (Alpine) | Distroless (gcr.io/distroless) | Scratch (`scratch`) |
| :--- | :--- | :--- | :--- | :--- |
| **Base Image Size** | ~70MB - 200MB | ~5MB - 8MB | ~2MB - 20MB | 0 B |
| **C Standard Library** | `glibc` | `musl` | `glibc` (minimal) or none | None |
| **Shell Availability** | `/bin/bash`, `/bin/sh` | `/bin/ash`, `/bin/sh` | None | None |
| **Package Manager** | `apt`, `dpkg` | `apk` | None | None |
| **CVE Attack Surface** | High (Includes utility binaries) | Low (Occasional `musl`/`apk` CVEs) | Very Low (Runtime runtime-only libs) | Zero (Only application binary) |
| **Production Observability**| High (`exec` shell debugging) | Medium (Basic tools available) | Low (Requires Ephemeral Containers) | Low (Requires Ephemeral Containers) |
| **Build Complexity** | Low | Low to Medium | Medium (Multi-stage build) | High (Static compilation) |

---

### 2.2 Pod Security Standards (PSS) Admission Levels

| Metric / Parameter | Privileged | Baseline | Restricted |
| :--- | :--- | :--- | :--- |
| **Intended Target** | Infrastructure agents (CNI, CSI, System components) | Default workloads, internal microservices | Hardened production services, multi-tenant workloads |
| **Host Namespace Access** | Allowed (`hostNetwork`, `hostPID`, `hostIPC`) | Denied | Denied |
| **Privileged Containers** | Allowed (`privileged: true`) | Denied | Denied |
| **Capabilities** | Unrestricted | Prevents adding dangerous caps (`CAP_SYS_ADMIN`) | Drops **ALL** capabilities; permits adding back specific ones (`NET_BIND_SERVICE`) |
| **Host Ports** | Unrestricted | Unrestricted | Denied (`hostPort` must be empty/unset) |
| **Volume Types** | All volume types allowed | Restricted (Blocks raw `hostPath`) | Restricted (Blocks raw `hostPath`) |
| **`runAsNonRoot`** | Not enforced | Not enforced | Enforced (`true` required) |
| **`allowPrivilegeEscalation`**| Allowed | Allowed | Denied (`false` required) |
| **`seccompProfile`** | Unrestricted | Unrestricted | Enforced (`RuntimeDefault` or `Localhost` required) |

---

### 2.3 Container Image Identification & Verification Mechanisms

| Mechanism | Example Specifier | Cryptographic Guarantee | Tag Mutation Risk | Admission Performance |
| :--- | :--- | :--- | :--- | :--- |
| **Mutable Semantic Tag** | `myapp:v1.2.0` | None | **High** (Tag can be overwritten in registry) | Fast (Manifest lookup only) |
| **Floating Environment Tag**| `myapp:production` | None | **Critical** (Continuous tag mutation) | Fast (Manifest lookup only) |
| **Immutable Image Digest** | `myapp@sha256:4f8a...` | High (Content-addressable hash mismatch fails pull) | **Zero** (Cryptographically locked content) | Fast (Direct hash check) |
| **Cosign Signature Verification**| `myapp@sha256:4f8a...` + Key/Keyless Sig | High (Attests image build provenance & identity) | **Zero** (Signature validation required at admission) | Medium (External key/rekey validation call) |

---

## 3. Syntactically Valid Complete YAML Manifests & Infrastructure Configurations

### 3.1 Cluster-Wide Pod Security Admission Configuration (`/etc/kubernetes/admission/pod-security-config.yaml`)

This manifest configures the Kubernetes API server built-in Pod Security Admission plugin with cluster-level default standards and explicit exemption rules.

```yaml
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "restricted"
  enforce-version: "latest"
  audit: "restricted"
  audit-version: "latest"
  warn: "restricted"
  warn-version: "latest"
exemptions:
  usernames: []
  runtimeClasses: []
  namespaces:
    - kube-system
    - cert-manager
    - ingress-nginx
```

---

### 3.2 Kubernetes API Server Admission Control Configuration (`/etc/kubernetes/admission/admission-config.yaml`)

Referenced by the API server flag `--admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml`.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "restricted"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces:
          - kube-system
          - cert-manager
```

---

### 3.3 Target Production Namespace Manifest (`namespace-restricted.yaml`)

Defines namespace-level Pod Security Standard overrides via declarative metadata labels.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-processing
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
```

---

### 3.4 Production-Grade Hardened Deployment Manifest (`deployment-hardened.yaml`)

A fully compliant manifest adhering strictly to the PSS `Restricted` profile, featuring non-root execution, dropped capabilities, read-only root filesystem, seccomp enforcement, and `tmpfs` volume mounts.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway
  namespace: payment-processing
  labels:
    app.kubernetes.io/name: payment-gateway
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: payment-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-gateway
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        fsGroupChangePolicy: Always
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: payment-api
          image: registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
          imagePullPolicy: IfNotPresent
          command:
            - "/app/payment-api-binary"
          args:
            - "--config=/etc/payment/config.json"
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
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          ports:
            - name: http-api
              containerPort: 8443
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8443
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 2
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: config-volume
              mountPath: /etc/payment
              readOnly: true
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: config-volume
          configMap:
            name: payment-api-config
```

---

### 3.5 Kyverno Image Verification & Digest Pinning Policy (`kyverno-image-verification.yaml`)

This policy mandates that all images deployed into non-exempt namespaces must be explicitly pinned by a SHA256 digest and signed by the organization's internal Cosign public key.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature-and-digest
  annotations:
    policies.kyverno.io/title: Verify Image Signatures and Force Immutable Digest
    policies.kyverno.io/subject: Pod, Deployment
    policies.kyverno.io/description: >-
      Requires all container images to use explicit digest SHA256 references
      and verifies Cosign cryptographic signatures against an internal trusted public key.
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-image-digest-format
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Container image must use an immutable digest (e.g., repo/image@sha256:hash)."
        pattern:
          spec:
            containers:
              - image: "*@sha256:*"
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "registry.enterprise.internal/*"
          key: |-
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N2sNfUj3k7R6vW+v8g0zK1oR1zN
            Y4vD8mQ0Z8V1V9mP2W6K5l2N0b3V4c5d6e7f8g9h0i1j2k3l4m5n6o==
            -----END PUBLIC KEY-----
          attestations: []
```

---

## 4. Real CLI Commands ($) with Expected Terminal Outputs

### 4.1 Vulnerability Scanning and SBOM Generation

#### Scan an image for HIGH and CRITICAL vulnerabilities using Trivy

```bash
$ trivy image --severity HIGH,CRITICAL --exit-code 1 registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
```

```text
2026-08-07T14:22:01.102-0400	INFO	Vulnerability scanning is enabled
2026-08-07T14:22:01.102-0400	INFO	Identified OS: alpine (3.19.1)
2026-08-07T14:22:01.103-0400	INFO	Detecting Alpine vulnerabilities...
2026-08-07T14:22:01.115-0400	INFO	Number of language-specific files: 1
2026-08-07T14:22:01.115-0400	INFO	Detecting gobinary vulnerabilities...

registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788 (alpine 3.19.1)
===================================================================================================================================
Total: 0 (HIGH: 0, CRITICAL: 0)

$ echo $?
0
```

#### Generate a CycloneDX Software Bill of Materials (SBOM) using Syft

```bash
$ syft registry.enterprise.internal/finance/payment-api:v1.2.0 -o cyclonedx-json --file sbom.cdx.json
```

```text
 ✔ Cataloged packages      [24 packages]
 ✔ Created BOM             [cyclonedx-json format] -> sbom.cdx.json
$ head -n 25 sbom.cdx.json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:7f3b89b4-11e2-419b-a621-392019a8bc43",
  "version": 1,
  "metadata": {
    "timestamp": "2026-08-07T14:24:12Z",
    "tools": [
      {
        "vendor": "anchore",
        "name": "syft",
        "version": "1.3.0"
      }
    ],
    "component": {
      "bom-ref": "8c3e809b431e5f12",
      "type": "container",
      "name": "registry.enterprise.internal/finance/payment-api",
      "version": "v1.2.0"
    }
  }
}
```

---

### 4.2 Image Signing and Verification with Cosign

#### Sign the container image using Cosign and a local private key

```bash
$ cosign sign --key cosign.key registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
```

```text
Enter password for private key: 
Pushing signature to: registry.enterprise.internal/finance/payment-api:sha256-a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788.sig
```

#### Verify the signature using the corresponding public key

```bash
$ cosign verify --key cosign.pub registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
```

```text
Verification for registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"registry.enterprise.internal/finance/payment-api"},"image":{"docker-manifest-digest":"sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788"},"type":"cosign container image signature"},"optional":null}]
```

---

### 4.3 Testing Pod Security Admission (PSA) Enforcement

#### Attempting to apply a non-compliant pod manifest into a Restricted namespace

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test-pod
  namespace: payment-processing
spec:
  containers:
    - name: nginx
      image: nginx:latest
EOF
```

```text
Error from server (Forbidden): error when creating "STDIN": pods "privileged-test-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "nginx" must not set runAsUser=0), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### 4.4 In-Pod Runtime Security Verification

#### Verifying User ID and Privileges inside the hardened running pod

```bash
$ kubectl exec -n payment-processing deployment/payment-gateway -- id
```

```text
uid=10001(payment) gid=10001(payment) groups=10001(payment)
```

#### Confirming Read-Only Root Filesystem enforcement

```bash
$ kubectl exec -n payment-processing deployment/payment-gateway -- touch /root_test.txt
```

```text
touch: /root_test.txt: Read-only file system
command terminated with exit code 1
```

#### Confirming Writable `/tmp` on Memory-backed `tmpfs`

```bash
$ kubectl exec -n payment-processing deployment/payment-gateway -- sh -c "echo 'temp_data' > /tmp/test.txt && cat /tmp/test.txt"
```

```text
temp_data
```

---

### 4.5 CRI-level Inspection via `crictl` on a Kubernetes Worker Node

#### Locating the container ID and inspecting low-level Linux security runtime state

```bash
$ sudo crictl ps --name payment-api
```

```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID              DEFAULT
e7b1a29f4c5d        a3c8e434f9a0c       10 minutes ago      Running             payment-api         0                   c9f8e7d6c5b4        (default)
```

```bash
$ sudo crictl inspect e7b1a29f4c5d | jq '.info.runtimeSpec.linux.securityContext'
```

```json
{
  "seccomp": {
    "profileType": "RuntimeDefault"
  },
  "capabilities": {
    "bounding": [],
    "effective": [],
    "inheritable": [],
    "permitted": []
  },
  "readonlyPaths": [
    "/proc/sys",
    "/proc/sysrq-trigger",
    "/proc/irq",
    "/proc/bus"
  ],
  "maskedPaths": [
    "/proc/asound",
    "/proc/acpi",
    "/proc/kcore",
    "/proc/keys"
  ]
}
```

---

## 5. Verification, Diagnostic & Failure Troubleshooting Guide

```
                         Workload Security Diagnostic Flowchart
                         
                        [ Deployment Attempt / Pod Creation ]
                                         |
                                         v
                            Is Pod Accepted by API Server?
                                /                 \
                             (No)                 (Yes)
                              /                     \
                             v                       v
               Check Admission Webhook          Is Pod Running?
            & Pod Security Standard (PSA)          /        \
                          |                     (No)        (Yes)
                          v                      /            \
                Review PSA Rejection          v                v
                   (Section 5.1)         Check Container     Verify Runtime
                                        Security Violations   Constraints
                                           (Section 5.2)      (Section 5.3)
```

### 5.1 Admission Rejection Diagnostics (`Forbidden` / `PodSecurity` Errors)

#### Symptom
CI/CD pipeline fails during `kubectl apply` with HTTP 403 Forbidden errors stating `violates PodSecurity "restricted:latest"`.

#### Root Cause Analysis Workflow
1. **Identify Missing Security Attributes**: Parse the rejection text returned by the API server. Look for specific security context parameters missing in either `.spec.securityContext` (Pod level) or `.spec.containers[*].securityContext` (Container level).
2. **Validate Mandatory Restricted Requirements**:
   - `allowPrivilegeEscalation: false` must be explicitly declared on **all** containers.
   - `capabilities: drop: ["ALL"]` must be declared on **all** containers.
   - `runAsNonRoot: true` must be set at Pod or Container level.
   - `seccompProfile: type: "RuntimeDefault"` (or `Localhost`) must be set.
3. **Inspect Namespace Audit Warnings**:
   ```bash
   kubectl label namespace payment-processing pod-security.kubernetes.io/warn=restricted --overwrite
   kubectl apply --dry-run=server -f deployment-legacy.yaml
   ```

---

### 5.2 Container Runtime Crash Diagnostics (`CrashLoopBackOff`, `CreateContainerError`)

#### Symptom A: `CreateContainerConfigError` due to missing non-root UID
- **Indication**: Pod status is `CreateContainerConfigError`.
- **Diagnostic Command**:
  ```bash
  kubectl describe pod <pod-name> -n <namespace>
  ```
- **Error Pattern**: `container has runAsNonRoot and image will run as root (UID 0)`
- **Remediation**: The base container image specifies `USER root` or lacks a `USER` instruction, and `.spec.containers[*].securityContext.runAsUser` was omitted in the pod spec. Update the manifest to explicitly define `runAsUser: 10001`.

#### Symptom B: Application Crash on Startup (`Permission Denied` / Read-Only Filesystem)
- **Indication**: Pod enters `CrashLoopBackOff` with exit code 1 or 126.
- **Diagnostic Command**:
  ```bash
  kubectl logs <pod-name> -n <namespace> --previous
  ```
- **Error Pattern**: `open /app/logs/app.log: read-only file system` or `mkdir /tmp/cache: permission denied`
- **Remediation**:
  1. If the application writes state to `/tmp` or cache directories, mount an in-memory `emptyDir` volume at that path.
  2. Modify the application configuration to direct logging outputs to standard output (`/dev/stdout`) rather than local files.

---

### 5.3 Kyverno & Policy Engine Enforcement Failures

#### Symptom
Images fail to deploy with `admission webhook "validate.kyverno.svc" denied the request`.

#### Diagnostic Workflow
1. Check Kyverno policy execution logs:
   ```bash
   kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=100 | grep -i "deny"
   ```
2. Verify policy report status for existing workloads:
   ```bash
   kubectl get clusterpolicyreport -o wide
   ```
3. Common Root Causes:
   - **Image Digest Omission**: Image was specified as `image: myapp:v1.2` instead of `image: myapp@sha256:<digest>`.
   - **Cosign Key Mismatch**: Public key configured in `ClusterPolicy` does not match the private key used by the CI pipeline to sign the image artifact.

---

### 5.4 Diagnostic Command Reference Matrix

| Diagnostic Goal | Target Object | Exact Command Line |
| :--- | :--- | :--- |
| **Inspect Pod Security Admission Events** | Events | `kubectl get events -n <ns> --field-selector reason=FailedCreate` |
| **View Audit Logs for Security Violations**| K8s API Server | `grep -i "pod-security" /var/log/kubernetes/audit/audit.log` |
| **Verify Effective Seccomp Profile** | Container Runtime | `crictl inspect <container-id> \| jq '.info.runtimeSpec.linux.securityContext.seccomp'` |
| **Verify Applied Linux Capabilities** | Container Runtime | `crictl inspect <container-id> \| jq '.info.runtimeSpec.linux.capabilities'` |
| **Audit Image Signatures in Cluster** | Kyverno Engine | `kubectl get policyreport -n <ns> -o yaml` |

---

## 6. References

* **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Official Documentation – Pod Security Standards**: [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **Kubernetes Official Documentation – Pod Security Admission**: [https://kubernetes.io/docs/concepts/security/pod-security-admission/](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
* **Kubernetes Official Documentation – Configure a Security Context for a Pod or Container**: [https://kubernetes.io/docs/tasks/configure-pod-container/security-context/](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
* **Sigstore Cosign Documentation**: [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
* **Kyverno Policy Engine – Image Verification**: [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)
* **NIST SP 800-190 (Application Container Security Guide)**: [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **Trivy Vulnerability Scanner Documentation**: [https://aquasecurity.github.io/trivy/latest/](https://aquasecurity.github.io/trivy/latest/)