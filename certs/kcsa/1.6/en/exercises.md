# KCSA Study Guide: Topic 1.6 – Workload and Application Code Security

**Exam:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 1:** Cloud Native Security Basics  
**Subtopic 1.6:** Workload and Application Code Security  
**Weight:** ~2.33%  

---

## 1. Official Reference Links

- **CNCF KCSA Curriculum:** [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Pod Security Standards:** [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- **Kubernetes Security Context:** [https://kubernetes.io/docs/tasks/configure-pod-container/security-context/](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- **Kubernetes RuntimeClass:** [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- **Sigstore Cosign Documentation:** [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
- **SLSA Security Framework:** [https://slsa.dev/spec/v1.0/about](https://slsa.dev/spec/v1.0/about)
- **CNCF Software Supply Chain Best Practices:** [https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsp.md](https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsp.md)

---

## 2. Technical Architecture & Internal Mechanics

### 2.1 The Workload Security Lifecycle Architecture
Securing workloads in a cloud-native architecture requires defense-in-depth across three main lifecycle phases: **Build**, **Deploy**, and **Runtime**.

```
[ BUILD PHASE ]                 [ DEPLOY PHASE ]               [ RUNTIME PHASE ]
+-------------------+           +---------------------+        +--------------------+
|  Source Code      |           | Kubernetes API      |        | Kernel / Container |
|  & Dependencies   |           | Server (Admission)  |        | Runtime Engine     |
+---------+---------+           +----------+----------+        +---------+----------+
          |                                |                             |
  (Static Scanning)               (Policy Enforcement)           (System Call Intercept)
          |                                |                             |
          v                                v                             v
+-------------------+           +---------------------+        +--------------------+
| SAST / Secret     |           | Pod Security        |        | Seccomp, AppArmor, |
| Detection         |           | Admission (PSA)     |        | Linux Capabilities |
+---------+---------+           +----------+----------+        +---------+----------+
          |                                |                             |
  (Container Build)                       |                             |
          |                                |                             |
          v                                |                             v
+-------------------+                      |                   +--------------------+
| Distroless Image  |                      |                   | MicroVM Isolation  |
| + Syft SBOM       |                      |                   | (gVisor / Kata)    |
+---------+---------+                      |                   +--------------------+
          |                                |
  (Signing & Provenance)                   |
          |                                |
          v                                |
+-------------------+                      |
| Cosign Signatures |                      |
| + SLSA Attestation|----------------------+
+-------------------+
```

### 2.2 Core Security Components Mechanics

#### Base Image Footprint Reduction
Standard base images (e.g., `ubuntu`, `debian`) contain shell interpreters (`/bin/sh`, `/bin/bash`), package managers (`apt`), and standard C utilities (`curl`, `wget`, `nc`). An attacker gaining remote code execution (RCE) inside such a container can easily perform post-exploitation lateral movement. 

Using **Distroless** (e.g., `gcr.io/distroless/static-debian12`) or `scratch` eliminates shells, package managers, and standard Linux utilities. Without `/bin/sh`, malicious command injection primitives fail immediately due to `execve` failures (`ENOENT`).

#### Supply Chain Verification (Sigstore Cosign & SLSA)
Container images stored in OCI registries can be tampered with or suffer man-in-the-middle vector swaps. **Cosign** implements cryptographic signing of OCI artifacts. In keyless mode, it leverages OIDC tokens (e.g., GitHub Actions, GCP Workload Identity) issued to **Fulcio** (a Certificate Authority), which issues a short-lived x509 certificate. The signature is recorded in **Rekor**, an immutable, append-only transparency log. The admission controller verifies signatures against Rekor public keys before permitting pod scheduling.

#### Software Bill of Materials (SBOM)
An SBOM is a structured inventory of all software components, direct and transitive dependencies, versions, and licenses embedded in an artifact. Standards like **SPDX** (System Package Data Exchange) and **CycloneDX** allow automated vulnerability matching against CVE databases even after images are deployed to production.

#### Linux Kernel Security Primitives in Containers
- **Linux Capabilities (`capget`/`capset`):** Unbundles the all-powerful `root` UID 0 into 41 distinct privileges (e.g., `CAP_NET_RAW`, `CAP_SYS_ADMIN`, `CAP_CHOWN`). Dropping all capabilities (`drop: ["ALL"]`) prevents root inside the container from modifying kernel networking, mounting filesystems, or executing raw socket attacks.
- **Seccomp (Secure Computing Mode):** Filters system calls made by a process to the Linux kernel using Berkeley Packet Filters (BPF). Standard glibc applications require fewer than 70 system calls out of ~350+. Enforcing `RuntimeDefault` or a custom seccomp profile blocks dangerous syscalls like `ptrace`, `kexec_load`, or `reboot`.
- **Read-Only Root Filesystem:** Mounting `/` as read-only (`readOnlyRootFilesystem: true`) forces all persistent or dynamic state into explicitly declared `tmpfs` or `volumeMounts`. This neutralizes payload persistence, rootkit installations, and binary modification attacks.

#### MicroVM Workload Isolation (RuntimeClass)
Standard containers share the host Linux kernel via cgroups and namespaces. A kernel zero-day vulnerability allows container escape directly to host kernel space. **RuntimeClass** routes pods to alternative OCI runtimes:
- **gVisor (`runsc`):** Intercepts syscalls in a user-space kernel written in Go, exposing a restricted surface to the host kernel.
- **Kata Containers:** Launches each Kubernetes Pod inside its own dedicated lightweight QEMU/Firecracker microVM with a dedicated Linux kernel.

---

## 3. Guided Exercises

### Exercise 1: Hardened Container Image Construction, Static Analysis, and SBOM Generation

In this exercise, you will create a multi-stage Dockerfile utilizing Google Distroless, run static security analysis, perform secret scanning, and generate a standardized SBOM.

#### Step 1.1: Multi-Stage Build with Minimal Footprint
Create an application directory and write a secure, multi-stage `Dockerfile` for a Go service.

Execute in your terminal:
```bash
mkdir -p ~/kcsa-workload-lab && cd ~/kcsa-workload-lab

cat << 'EOF' > main.go
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "OK")
	})
	fmt.Println("Server running on port 8080...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		panic(err)
	}
}
EOF

cat << 'EOF' > Dockerfile
# Stage 1: Build stage with full toolchain
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o server main.go

# Stage 2: Minimal Distroless runtime
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=builder /app/server /server
USER 65532:65532
ENTRYPOINT ["/server"]
EOF

docker build -t localapp:v1.0.0 .
```

Expected output snippet:
```text
[+] Building 4.2s (10/10) FINISHED
 => [stage-1 1/3] FROM gcr.io/distroless/static-debian12:nonroot
 => [stage-0 4/4] RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o server main.go
 => EXPORTING image docker.io/library/localapp:v1.0.0
```

#### Step 1.2: Vulnerability and Secret Scanning using Trivy
Scan the compiled image for vulnerabilities, misconfigurations, and hardcoded credentials.

Execute:
```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 localapp:v1.0.0
```

Expected output snippet:
```text
localapp:v1.0.0 (debian 12.5)

Total: 0 (HIGH: 0, CRITICAL: 0)
```

Now perform secret scanning on the local directory to verify static code analysis controls:

Execute:
```bash
cat << 'EOF' > test_secret.py
# Hardcoded AWS secret key for demonstration
AWS_SECRET_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLEkey"
EOF

trivy fs --security-checks secret .
```

Expected output snippet:
```text
Target: test_secret.py
Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 1, CRITICAL: 0)

CRITICAL: AWS Secret Access Key identified
Line 2: AWS_SECRET_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLEkey"
```

Clean up the test secret file:
```bash
rm test_secret.py
```

#### Step 1.3: Software Bill of Materials (SBOM) Generation with Syft
Generate an SBOM in SPDX JSON format for supply chain tracking.

Execute:
```bash
syft localapp:v1.0.0 -o spdx-json=sbom.spdx.json
head -n 25 sbom.spdx.json
```

Expected output snippet:
```json
{
 "SPDXID": "SPDXRef-DOCUMENT",
 "spdxVersion": "SPDX-2.3",
 "creationInfo": {
  "created": "2026-08-07T19:30:00Z",
  "creators": [
   "Organization: Anchore, Inc.",
   "Tool: syft-1.0.0"
  ]
 },
 "name": "localapp:v1.0.0",
 "dataLicense": "CC0-1.0",
 "documentNamespace": "https://anchore.com/syft/image/localapp-v1.0.0"
}
```

---

#### Comprehension Check 1

**Question 1.1:** Why does using `gcr.io/distroless/static-debian12:nonroot` as a base image significantly reduce the application's attack surface compared to `alpine` or `ubuntu`?  
A) It automatically encrypts container memory at rest.  
B) It removes shells (`sh`, `bash`), utility binaries (`curl`, `apt`), and runs by default as non-root UID 65532, preventing post-exploitation shell execution.  
C) It embeds an automatic eBPF kernel agent to block unauthorized system calls.  
D) It converts Go bytecode directly into kernel module drivers.  

**Question 1.2:** In a CI/CD pipeline security policy, what is the effect of running `trivy image --exit-code 1 --severity CRITICAL <image>`?  
A) Trivy automatically patches the vulnerabilities in the OCI registry.  
B) Trivy logs the critical vulnerabilities and allows the build pipeline to continue successfully.  
C) Trivy returns a non-zero exit code (`1`), instructing the CI runner to fail the pipeline step and block deployment if any CRITICAL vulnerability is detected.  
D) Trivy terminates the Docker daemon process on the host.  

---

### Exercise 2: Supply Chain Security with Cosign Signing and Attestations

In this exercise, you will create a cryptographic key pair using Sigstore Cosign, sign an OCI container image artifact, attach an in-toto attestation, and verify the signature integrity.

#### Step 2.1: Key Generation and Image Signing
Generate a key pair using Cosign. (For automated CI pipelines, Cosign keyless mode with OIDC via Fulcio/Rekor is preferred; here we generate explicit keys for deterministic local execution).

Execute:
```bash
# Set password variable for non-interactive key generation
export COSIGN_PASSWORD="KcsaExamPassWord123!"

cosign generate-key-pair
```

Expected output snippet:
```text
Private key written to cosign.key
Public key written to cosign.pub
```

Now sign your container image (Note: ensure image is pushed to an accessible registry or local registry instance; for demonstration we tag for a local registry):

Execute:
```bash
# Start a local OCI registry container
docker run -d -p 5000:5000 --name registry registry:2

# Tag and push container image to local registry
docker tag localapp:v1.0.0 localhost:5000/localapp:v1.0.0
docker push localhost:5000/localapp:v1.0.0

# Sign the OCI artifact with Cosign
cosign sign --key cosign.key --tlog-upload=false localhost:5000/localapp:v1.0.0
```

Expected output snippet:
```text
Enter password for private key: 
Pushing signature to: localhost:5000/localapp
```

#### Step 2.2: Signature Verification
Verify that the image published in the registry matches the cryptographic public key.

Execute:
```bash
cosign verify --key cosign.pub localhost:5000/localapp:v1.0.0
```

Expected output snippet:
```json
Verification for localhost:5000/localapp:v1.0.0 --
The following checks were performed on each of these signatures:
  - The checks were verified against the specified public key
  - The signatures were verified against the specified code signing claims

[{"critical":{"identity":{"docker-reference":"localhost:5000/localapp"},"image":{"docker-manifest-digest":"sha256:a1b2c3..."},"type":"cosign container image signature"}}]
```

---

#### Comprehension Check 2

**Question 2.1:** What role does Rekor play in the keyless Sigstore / Cosign architecture?  
A) It acts as the primary OCI image registry storing raw container layers.  
B) It is an immutable, append-only transparency log that records signature metadata, providing public proof of when and by whom an image was signed.  
C) It generates short-lived x509 certificates based on identity provider OIDC tokens.  
D) It dynamically injects Linux kernel capabilities into running pods upon verification.  

**Question 2.2:** If an attacker tampers with a single layer of a signed container image inside the container registry, what happens during `cosign verify`?  
A) Cosign re-compiles the container layer to match the signature.  
B) Cosign verification succeeds but prints a warning log message.  
C) Cosign verification fails because the container image manifest digest (`sha256`) no longer matches the signed digest claim payload.  
D) Cosign requests a new x509 certificate from Fulcio to overwrite the tampered image.  

---

### Exercise 3: Kubernetes Pod Security Standards (PSS) & Admission Enforcement

Kubernetes implements three Pod Security Standards levels: **Privileged**, **Baseline**, and **Restricted**. Pod Security Admission (PSA) enforces these standards at the namespace boundary via labels.

#### Step 3.1: Enforcing Restricted Namespace Policy
Create a secure namespace and configure Pod Security Admission labels to enforce the `restricted` profile strictly.

Execute:
```bash
cat << 'EOF' > namespace-restricted.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: secure-workloads
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
EOF

kubectl apply -f namespace-restricted.yaml
```

Expected output:
```text
namespace/secure-workloads created
```

#### Step 3.2: Testing Admission Denial with a Non-Compliant Pod
Attempt to deploy an insecure pod definition into the `secure-workloads` namespace.

Execute:
```bash
cat << 'EOF' > insecure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-workload
  namespace: secure-workloads
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF

kubectl apply -f insecure-pod.yaml
```

Expected output snippet:
```text
Error from server (Forbidden): error when creating "insecure-pod.yaml": pods "insecure-workload" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

#### Step 3.3: Creating a Production-Grade Hardened Pod Manifest
Create a syntactically valid, production-ready Pod manifest that strictly complies with the `restricted` Pod Security Standard.

Execute:
```bash
cat << 'EOF' > secure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  namespace: secure-workloads
  labels:
    app.kubernetes.io/name: secure-app
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: localhost:5000/localapp:v1.0.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    resources:
      limits:
        cpu: "250m"
        memory: "128Mi"
      requests:
        cpu: "100m"
        memory: "64Mi"
EOF

kubectl apply -f secure-pod.yaml
```

Expected output:
```text
pod/secure-workload created
```

Verify pod execution and security context parameters:
```bash
kubectl get pod secure-workload -n secure-workloads -o jsonpath='{.spec.securityContext}'
```

Expected output snippet:
```json
{"fsGroup":10001,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}
```

---

#### Comprehension Check 3

**Question 3.1:** What is the primary purpose of setting `allowPrivilegeEscalation: false` in a container's `securityContext`?  
A) It prevents the container process from binding to network ports below 1024.  
B) It sets the `no_new_privs` bit on the process via `prctl(PR_SET_NO_NEW_PRIVS)`, preventing binaries with SUID/SGID flags (e.g., `sudo`, `passwd`) from gaining elevated privileges during execution.  
C) It blocks the container from issuing HTTP GET requests to the cloud provider metadata service (169.254.169.254).  
D) It unmounts the `/proc` directory inside the container runtime environment.  

**Question 3.2:** Under the `restricted` Pod Security Standard, which configuration is mandatory regarding Linux Capabilities?  
A) Containers must explicitly add `CAP_SYS_ADMIN`.  
B) Containers must explicitly drop `ALL` capabilities (`capabilities.drop: ["ALL"]`) and may only selectively add back minimal required capabilities like `NET_BIND_SERVICE` if justified.  
C) Containers inherit all capabilities from the host worker node kernel by default.  
D) Capability dropping is handled entirely by the CNI plugin and cannot be configured in the Pod YAML.  

---

### Exercise 4: Advanced Workload Isolation with Custom Seccomp Profiles and RuntimeClasses

In this exercise, you will create a custom seccomp profile to restrict Linux syscalls and configure a `RuntimeClass` for hypervisor-level workload isolation.

#### Step 4.1: Deploying a Custom Seccomp Profile
Worker nodes evaluate seccomp profiles located in the kubelet root directory (typically `/var/lib/kubelet/seccomp/`). Create a restrictive custom profile that blocks the `mkdir` system call.

Execute (simulated profile definition):
```bash
cat << 'EOF' > fine-grained-seccomp.json
{
  "defaultAction": "SCMP_ACT_LOG",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "clone",
        "execve",
        "exit",
        "exit_group",
        "futex",
        "write",
        "read",
        "epoll_wait"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": [
        "mkdir",
        "rmdir"
      ],
      "action": "SCMP_ACT_ERRNO"
    }
  ]
}
EOF
```

To reference this custom profile in a Kubernetes Pod, specify `type: Localhost` in the `seccompProfile` configuration:

```yaml
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/fine-grained-seccomp.json
```

#### Step 4.2: Configuring a MicroVM RuntimeClass (gVisor / Kata)
Define a Kubernetes `RuntimeClass` object that maps workloads to a sandboxed OCI runtime handler (`gvisor` or `kata`).

Execute:
```bash
cat << 'EOF' > runtime-class.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor-sandbox
handler: runsc
scheduling:
  nodeSelector:
    sandbox.k8s.io/enabled: "true"
  tolerations:
  - key: "sandbox.k8s.io/untrusted"
    operator: "Exists"
    effect: "NoSchedule"
EOF

kubectl apply -f runtime-class.yaml
```

Expected output:
```text
runtimeclass.node.k8s.io/gvisor-sandbox created
```

Deploy a Pod utilizing the `RuntimeClass`:

Execute:
```bash
cat << 'EOF' > sandboxed-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: sandboxed-workload
  namespace: default
spec:
  runtimeClassName: gvisor-sandbox
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: worker
    image: localhost:5000/localapp:v1.0.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
EOF

kubectl apply -f sandboxed-pod.yaml
```

Expected output:
```text
pod/sandboxed-workload created
```

---

#### Comprehension Check 4

**Question 4.1:** What is the technical mechanism by which `gVisor` (`runsc`) isolates a container workload from the host operating system?  
A) It isolates workloads by injecting iptables rules that drop all incoming TCP connections.  
B) It runs a user-space kernel (written in Go) that intercepts application system calls, re-implementing kernel mechanics and preventing direct application contact with the host Linux kernel.  
C) It executes the container entirely inside a remote AWS S3 bucket.  
D) It re-compiles application source code into WebAssembly (Wasm) binaries at startup.  

**Question 4.2:** What is the difference between setting seccomp action to `SCMP_ACT_ERRNO` versus `SCMP_ACT_KILL` in a custom seccomp profile?  
A) `SCMP_ACT_ERRNO` causes the kernel to return an error code (`EPERM`) to the calling process without terminating it, while `SCMP_ACT_KILL` immediately terminates the thread/process making the forbidden system call.  
B) `SCMP_ACT_ERRNO` deletes the pod manifest from `etcd`.  
C) `SCMP_ACT_KILL` reboots the worker node host OS.  
D) There is no functional difference; both actions write a message to `/var/log/syslog` and allow the system call to proceed.  

---

## 4. Diagnostic & Troubleshooting Techniques

### 4.1 Diagnosing Pod Security Admission (PSA) Denials
When a Pod or Deployment fails to deploy due to PSA enforcement, inspect the API server response or describe the parent resource (e.g., ReplicaSet/Deployment):

```bash
kubectl get events -n secure-workloads --field-selector reason=FailedCreate
```

Common error pattern:
```text
packs/ReplicaSet failed to create pods: pods "app-674b889796-" is forbidden: violates PodSecurity "restricted:latest": ...
```

**Resolution Checklist:**
1. Check root status: Ensure `spec.securityContext.runAsNonRoot: true` is set.
2. Check capabilities: Ensure `spec.containers[*].securityContext.capabilities.drop` includes `"ALL"`.
3. Check escalation: Ensure `spec.containers[*].securityContext.allowPrivilegeEscalation: false`.
4. Check seccomp: Ensure `spec.securityContext.seccompProfile.type` is set to `RuntimeDefault` or `Localhost`.

### 4.2 Verifying Container Runtime Engine Handler
To verify whether a running Pod is correctly executing inside a sandbox runtime (e.g., `gVisor`), check the kernel name or process tree inside the container:

```bash
kubectl exec -it sandboxed-workload -- uname -a
```

- **Standard Container Output:** `Linux node-01 6.5.0-28-generic #29-Ubuntu SMP ... x86_64 GNU/Linux`
- **gVisor Sandboxed Output:** `Linux gVisor 2.6.35-gVisor #1 SMP Sun Jan 1 00:00:00 2017 x86_64 GNU/Linux`

---

<details>
<summary><b>5. Answer Key & Detailed Technical Explanations</b></summary>

### Exercise 1 Answers

- **Question 1.1: Correct Answer = B**  
  *Explanation:* Distroless images contain only the application binary and minimal runtime dependencies (such as SSL certificates and glibc/musl). Shell interpreters like `/bin/sh` or `/bin/bash` and package managers like `apt` are completely absent. If an attacker discovers an application vulnerability (e.g., remote command execution), attempts to spawn a shell process fail with `ENOENT` (file not found). Furthermore, the default `nonroot` tag sets the user to UID `65532`, adhering to least privilege.

- **Question 1.2: Correct Answer = C**  
  *Explanation:* Setting `--exit-code 1` forces Trivy to return exit code `1` whenever vulnerabilities matching the specified filter (`--severity HIGH,CRITICAL`) are encountered. Continuous Integration (CI) engines evaluate exit codes; a non-zero code halts the pipeline, preventing vulnerable artifacts from being pushed to registries or deployed to production clusters.

---

### Exercise 2 Answers

- **Question 2.1: Correct Answer = B**  
  *Explanation:* Rekor is Sigstore's immutable, transparency log based on a Merkle tree architecture. In keyless signing, Rekor stores signed metadata attestations along with cryptographic timestamps. Anyone verifying the image can audit Rekor to confirm that the image signature was generated within the precise validity window of the short-lived OIDC-issued x509 certificate.

- **Question 2.2: Correct Answer = C**  
  *Explanation:* Cosign signs the OCI image manifest digest (`sha256:hash`). The manifest digest represents a cryptographic hash of all component layer diff IDs. If a layer is modified or tampered with, the resulting OCI manifest SHA256 digest changes. During `cosign verify`, the computed hash of the registry image fails to match the signed payload claim digest, resulting in verification failure.

---

### Exercise 3 Answers

- **Question 3.1: Correct Answer = B**  
  *Explanation:* In Linux, setuid binaries (like `passwd` or `su`) allow processes to temporarily assume the file owner's privileges (often root). Setting `allowPrivilegeEscalation: false` translates to the kernel `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` system call. Once set, child processes created via `execve` cannot gain privileges higher than their parent process, neutralizing privilege escalation attacks via setuid binaries.

- **Question 3.2: Correct Answer = B**  
  *Explanation:* The Kubernetes `restricted` Pod Security Standard requires pods to drop all default Linux capabilities via `capabilities.drop: ["ALL"]`. If the workload requires specific functionality (such as binding to low network ports), only minimal necessary capabilities (e.g., `NET_BIND_SERVICE`) may be explicitly added back under `capabilities.add`.

---

### Exercise 4 Answers

- **Question 4.1: Correct Answer = B**  
  *Explanation:* Standard containers execute system calls directly on the shared host Linux kernel. `gVisor` introduces `runsc`, an OCI runtime that runs a dedicated user-space kernel (called the Sentry) written in memory-safe Go. System calls emitted by the container application are intercepted and handled by the Sentry, significantly reducing direct exposure to the host OS kernel.

- **Question 4.2: Correct Answer = A**  
  *Explanation:* Seccomp BPF filters execute actions when a system call matches a rule filter. `SCMP_ACT_ERRNO` causes the Linux kernel to reject the system call and immediately return an error code (such as `EPERM` / Operation not permitted) to the calling process, allowing graceful application error handling. `SCMP_ACT_KILL` (or `SCMP_ACT_KILL_PROCESS`) sends a `SIGSYS` signal, terminating the calling thread/process immediately.

</details>