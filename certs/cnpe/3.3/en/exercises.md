# CNPE Study Module: Theme 3.3 – Generating Audit Trails and Enforcing Policy Compliance

**Target Certification:** Certified Cloud Native Platform Engineer (CNPE)  
**Domain 3:** Security, Governance, and Compliance  
**Topic 3.3:** Generating Audit Trails and Enforcing Policy Compliance (SBOM, Compliance Reports, etc.)  
**Weight:** 3%  
**Official Reference:** [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

---

## 1. Deep Technical Architecture & Mechanics

### 1.1 Software Bill of Materials (SBOM) Ecosystem & Ingestion Mechanics
An SBOM is a structured, machine-readable inventory of software components, dependencies, and metadata. In cloud-native platform architecture, SBOM generation occurs at two primary lifecycle stages:
1. **Build-Time Generation (CI/CD Pipeline):** Tools like [`syft`](https://github.com/anchore/syft) or [`trivy`](https://github.com/aquasecurity/trivy) inspect container image layers, package manager databases (e.g., `dpkg`, `rpm`, `apk`, `pip`, `npm`), and language binaries (e.g., Go buildinfo) to output standard formats:
   - **Software Package Data Exchange (SPDX - ISO/IEC 5962:2021):** Standardized by Linux Foundation; focuses on license governance, package relationships, and compliance.
   - **CycloneDX (OWASP):** Optimized for security risk reduction, supply chain risk management (SCRM), and vulnerability tracking (VEX - Vulnerability Exploitability eXchange).
2. **Admission & Attestation Verification:** Using [Cosign / Sigstore](https://www.sigstore.dev/), SBOMs are attached to container images in an OCI Registry as in-toto attestations (`application/vnd.in-toto+json`). Admission controllers verify that image digests have attached, cryptographically signed SBOM attestations before pod scheduling.

```
+---------------------------------------------------------------------------------------------------+
|                                 BUILD-TIME & SUPPLY CHAIN LIFECYCLE                                |
+---------------------------------------------------------------------------------------------------+
|  [Source Code] ---> [CI Pipeline: Syft / Trivy] ---> [OCI Image + Signed CycloneDX SBOM]          |
|                                                              |                                    |
|                                                              v                                    |
|                                                     [Container Registry]                          |
+-------------------------------------------------------------+-------------------------------------+
                                                              |
                                                              v
+---------------------------------------------------------------------------------------------------+
|                                 RUNTIME & ADMISSION CONTROL LIFECYCLE                             |
+---------------------------------------------------------------------------------------------------+
| [Kube-APIServer] ---> [Validating Webhook] ---> [Kyverno / Gatekeeper] (Verify Attestation/SBOM)   |
|         |                                                   |                                     |
|         v                                                   v                                     |
| [Kube Audit Log Stream]                           [Trivy Operator / Security Profiles]             |
|         |                                                   |                                     |
|         v                                                   v                                     |
| [Falco eBPF Engine] -----------------------------> [ComplianceReport CRD]                         |
+---------------------------------------------------------------------------------------------------+
```

---

### 1.2 Policy Enforcement & Compliance Reporting Mechanics

#### Admission Controllers vs. Continuous Scanning
- **Kubernetes Dynamic Admission Webhooks (`ValidatingWebhookConfiguration`, `MutatingWebhookConfiguration`):** Intercept API server requests during `CREATE`, `UPDATE`, or `DELETE` operations after authentication and authorization.
  - *Trade-off:* High assurance (prevents invalid workloads from entering the cluster), but introduces API latency and potential control-plane availability risks if the policy engine timeouts.
- **Continuous In-Cluster Compliance Scanners (e.g., Trivy Operator, Kyverno Background Controller):** Continuously evaluate existing workloads against CIS Kubernetes Benchmarks, NSA/CISA Hardening Guidance, and policy rules.
  - *Trade-off:* Zero impact on API request latency, but workloads are evaluated asynchronously (remediation happens after scheduling).

#### Kubernetes Audit Logging Mechanics
The API server writes audit events matching the configured Audit Policy rule hierarchy to a backend (`log` or `webhook`).
- **Audit Stages:**
  1. `RequestReceived`: Logged immediately upon receiving the API request.
  2. `ResponseStarted`: Logged when HTTP response headers are sent (for streaming endpoints).
  3. `ResponseComplete`: Logged when the HTTP response body is fully returned.
  4. `Panic`: Logged when an unhandled panic occurs in the API server.
- **Audit Levels:** `None` (do not log), `Metadata` (log user, timestamp, resource, namespace), `Request` (log metadata + request body), `RequestResponse` (log metadata + request + response body).

---

## 2. Production-Grade Manifests

### 2.1 Complete Kubernetes Advanced Audit Policy Manifest (`audit-policy.yaml`)

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Do not log noisy system read-only events
  - level: None
    users:
      - "system:kube-proxy"
      - "system:apiserver"
      - "system:nodes"
    verbs: ["get", "list", "watch"]

  # 2. Log authentication & secret access at Metadata level for security compliance
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # 3. Log RBAC and Workload modifications at RequestResponse level for audit trails
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods", "namespaces", "serviceaccounts"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "clusterroles", "rolebindings", "clusterrolebindings"]

  # 4. Fallback default rule for remaining resources
  - level: Metadata
    verbs: ["create", "update", "patch", "delete"]
```

---

### 2.2 Complete Kyverno ClusterPolicy Enforcing SBOM Attestations (`check-sbom-policy.yaml`)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-sbom
  annotations:
    policies.kyverno.io/title: Require Signed SBOM Attestation
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: High
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce
  background: true
  webhookTimeoutSeconds: 15
  rules:
    - name: verify-image-sbom-attestation
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "ghcr.io/myorg/*"
            - "docker.io/myorg/*"
          key: |
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7v1SjU1nQ... [SIGSTORE_PUBLIC_KEY] ...
            -----END PUBLIC KEY-----
          attestations:
            - predicateType: https://cyclonedx.org/bom
              attestors:
                - entries:
                    - keys:
                        publicKeys: |
                          -----BEGIN PUBLIC KEY-----
                          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7v1SjU1nQ...
                          -----END PUBLIC KEY-----
```

---

### 2.3 Complete OPA Gatekeeper ConstraintTemplate & Constraint for Compliance (`disallow-privileged.yaml`)

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sdisallowprivileged
  annotations:
    description: "Requires pod containers to not run as privileged."
spec:
  crd:
    spec:
      names:
        kind: K8sDisallowPrivileged
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sdisallowprivileged

        violation[{"msg": msg}] {
          c := input.review.object.spec.containers[_]
          c.securityContext.privileged == true
          msg := sprintf("Container %v in Pod %v is running as privileged, which violates policy.", [c.name, input.review.object.metadata.name])
        }
        violation[{"msg": msg}] {
          c := input.review.object.spec.initContainers[_]
          c.securityContext.privileged == true
          msg := sprintf("InitContainer %v in Pod %v is running as privileged, which violates policy.", [c.name, input.review.object.metadata.name])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sDisallowPrivileged
metadata:
  name: psp-disallow-privileged
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
      - "staging"
```

---

## 3. Real CLI Commands & Expected Outputs

### 3.1 Generating and Validating SBOMs using Syft & Trivy

#### Command: Generate a CycloneDX SBOM in JSON format using Syft
```bash
syft packages docker.io/library/nginx:1.25.3 -o cyclonedx-json=nginx-1.25.3.sbom.json
```
**Expected Output:**
```json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:7b43a992-0b1a-4d2b-a81d-847e099ab31f",
  "version": 1,
  "metadata": {
    "timestamp": "2026-08-07T18:00:00Z",
    "tools": [
      {
        "vendor": "anchore",
        "name": "syft",
        "version": "1.1.0"
      }
    ],
    "component": {
      "type": "container",
      "name": "docker.io/library/nginx:1.25.3",
      "version": "sha256:a6e2e00d07...[digest]"
    }
  },
  "components": [
    {
      "type": "library",
      "name": "openssl",
      "version": "3.0.11-1~deb12u1",
      "purl": "pkg:deb/debian/openssl@3.0.11-1~deb12u1?arch=amd64"
    }
  ]
}
```

#### Command: Scan the generated SBOM for vulnerabilities with Trivy
```bash
trivy sbom nginx-1.25.3.sbom.json --severity HIGH,CRITICAL --format table
```
**Expected Output:**
```
nginx-1.25.3.sbom.json (cyclonedx)

Total: 2 (HIGH: 1, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬───────────────────────────────────────────┐
│   Library    │ Vulnerability  │ Severity │ Installed    │   Fixed Version   │                   Title                   │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼───────────────────────────────────────────┤
│ libssl3      │ CVE-2024-0727  │ HIGH     │ 3.0.11-1     │ 3.0.11-1~deb12u2  │ openssl: PKCS12 Processing crash...       │
│ zlib1g       │ CVE-2023-45853 │ CRITICAL │ 1.2.13.dfsg  │ 1.3.dfsg-1        │ zlib: integer overflow in minizip...      │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴───────────────────────────────────────────┘
```

---

### 3.2 Querying Kubernetes Audit Logs for Unauthorized Secret Access

#### Command: Search API Server Audit Log for Secret Read Operations
```bash
jq -r 'select(.resources[0].resource=="secrets" and (.verb=="get" or .verb=="list")) | [.stage, .user.username, .verb, .objectRef.namespace, .objectRef.name, .responseStatus.code] | @tsv' /var/log/kubernetes/audit.log
```
**Expected Output:**
```
ResponseComplete	system:serviceaccount:default:compromised-sa	get	prod-data	database-credentials	403
ResponseComplete	system:node:worker-node-01	list	kube-system	NULL	200
ResponseComplete	admin-user@company.com	get	production	api-signing-key	200
```

---

## 4. Advanced Diagnostic & Troubleshooting Techniques

### 4.1 Debugging Admission Webhook Latency & Failures
When Kyverno or OPA Gatekeeper block API requests or cause timeouts (`500 Internal Server Error` or timeout during webhook call):

1. **Check API Server Webhook Metrics:**
   ```bash
   kubectl get --raw /metrics | grep apiserver_admission_webhook_rejection_count
   kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration_seconds_bucket
   ```
2. **Inspect Webhook Timeout Configuration:**
   If `failurePolicy: Fail` is set and `timeoutSeconds` is reached (default 10s), API server rejects pod creations.
   ```bash
   kubectl get validatingwebhookconfigurations -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.webhooks[*].failurePolicy}{"\t"}{.webhooks[*].timeoutSeconds}{"\n"}{end}'
   ```
3. **Trace Failed Admission Reviews in Audit Logs:**
   Filter audit entries by status code `422 Unprocessable Entity` or `500` associated with webhooks:
   ```bash
   jq 'select(.responseStatus.code == 422 and .annotations["scheduling.k8s.io/reason"] != null)' /var/log/kubernetes/audit.log
   ```

---

## 5. Guided Hands-On Exercises

### Exercise 1: Configuring Audit Policies and Analyzing Security Violations

#### Steps:
1. Create a directory named `/tmp/cnpe-audit-lab`.
2. Save the Audit Policy file below to `/tmp/cnpe-audit-lab/audit-policy.yaml`:
   ```yaml
   apiVersion: audit.k8s.io/v1
   kind: Policy
   rules:
     - level: RequestResponse
       verbs: ["create", "update", "delete"]
       resources:
         - group: ""
           resources: ["configmaps"]
   ```
3. Simulate an audit event generation by executing an imperatively formatted `ConfigMap` creation:
   ```bash
   kubectl create configmap test-audit-cm --from-literal=key1=value1 -n default
   ```
4. Query the API audit stream for the resource `test-audit-cm`.

#### Verification Questions (Exercise 1):
- **Q1.1:** Which audit level will record both the payload sent in `kubectl create configmap` and the API server's returned object?
- **Q1.2:** If a `ConfigMap` is updated via `kubectl patch`, will the audit log contain the patch payload under the `RequestResponse` level?

---

### Exercise 2: Enforcing In-Cluster Security Policies via OPA Gatekeeper

#### Steps:
1. Deploy a Gatekeeper `ConstraintTemplate` that prohibits containers without read-only root filesystems (`readOnlyRootFilesystem: true`).
2. Save the manifest to `/tmp/cnpe-audit-lab/template-readonlyroot.yaml`:
   ```yaml
   apiVersion: templates.gatekeeper.sh/v1
   kind: ConstraintTemplate
   metadata:
     name: k8sreadonlyrootfilesystem
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
             c := input.review.object.spec.containers[_]
             not c.securityContext.readOnlyRootFilesystem == true
             msg := sprintf("Container %v must have readOnlyRootFilesystem set to true", [c.name])
           }
   ```
3. Apply the template:
   ```bash
   kubectl apply -f /tmp/cnpe-audit-lab/template-readonlyroot.yaml
   ```
4. Instantiate the constraint targeting namespace `default`:
   ```yaml
   apiVersion: constraints.gatekeeper.sh/v1beta1
   kind: K8sReadOnlyRootFilesystem
   metadata:
     name: enforce-readonly-root
   spec:
     match:
       kinds:
         - apiGroups: [""]
           kinds: ["Pod"]
       namespaces:
         - "default"
   ```
   Apply it:
   ```bash
   kubectl apply -f /tmp/cnpe-audit-lab/constraint-readonlyroot.yaml
   ```
5. Test admission rejection by creating a Pod with a writable root filesystem:
   ```bash
   kubectl run test-writable-pod --image=nginx:alpine --restart=Never -n default
   ```

#### Verification Questions (Exercise 2):
- **Q2.1:** What HTTP status code and error message structure does the Kubernetes API Server return when Gatekeeper rejects `test-writable-pod`?
- **Q2.2:** What is the operational impact if `failurePolicy` in Gatekeeper's `ValidatingWebhookConfiguration` is set to `Fail` during a Gatekeeper pod crash?

---

### Exercise 3: Generating and Verifying Container SBOMs with Attestation Workflows

#### Steps:
1. Install/use `syft` to generate a CycloneDX SBOM for `alpine:3.19`.
2. Save the output to `/tmp/cnpe-audit-lab/alpine-3.19.cdx.json`:
   ```bash
   syft alpine:3.19 -o cyclonedx-json > /tmp/cnpe-audit-lab/alpine-3.19.cdx.json
   ```
3. Validate that the generated file adheres to the CycloneDX JSON schema by checking its `bomFormat` and `components` arrays using `jq`:
   ```bash
   jq '{bomFormat: .bomFormat, specVersion: .specVersion, totalComponents: (.components | length)}' /tmp/cnpe-audit-lab/alpine-3.19.cdx.json
   ```
4. Generate a vulnerability report specifically matching components inside the SBOM using `trivy`:
   ```bash
   trivy sbom /tmp/cnpe-audit-lab/alpine-3.19.cdx.json
   ```

#### Verification Questions (Exercise 3):
- **Q3.1:** What distinct architectural advantage does scanning an SBOM file have compared to directly scanning a running container image in production nodes?
- **Q3.2:** How does Sigstore/Cosign link an SBOM file stored in an OCI registry to an exact container image digest?

---

## 6. Verification Answers & Solutions

<details>
<summary>Click to expand Solutions & Detailed Explanations</summary>

### Exercise 1 Answers
- **A1.1:** The `RequestResponse` audit level logs event metadata, the full request body (sent by `kubectl`), and the complete response body (returned by `kube-apiserver`).
- **A1.2:** Yes. At the `RequestResponse` level, `kubectl patch` requests are audited with the JSON/Strategic Merge Patch payload in the `requestObject` field and the resulting updated `ConfigMap` state in the `responseObject` field.

---

### Exercise 2 Answers
- **A2.1:** The API server returns **HTTP 422 Unprocessable Entity** (or **HTTP 400 Bad Request** depending on client version), with a `Status` object containing `reason: Invalid` or `Forbidden`, and the exact message string generated by the OPA Rego policy: `[enforce-readonly-root] Container test-writable-pod must have readOnlyRootFilesystem set to true`.
- **A2.2:** If `failurePolicy` is set to `Fail` and the Gatekeeper admission controller webhook pod is unreachable or failing, all API `CREATE`/`UPDATE` requests matching the webhook criteria will be completely rejected by the `kube-apiserver`. This blocks all new deployment/pod rollouts across the cluster.

---

### Exercise 3 Answers
- **A3.1:** 
  1. **Zero Runtime Overhead:** SBOM scanning runs statelessly off-cluster without executing code, invoking container runtimes, or placing CPU/Memory pressure on production Kubernetes nodes.
  2. **Deterministic Reproducibility:** Scanning an authenticated SBOM immutable artifact guarantees consistent vulnerability detection regardless of node OS changes, package manager cache drift, or ephemeral runtime modifications.
- **A3.2:** Cosign uploads the SBOM as an in-toto attestation spec stored at a specific OCI tag or artifact reference named after the target image digest: `<repo>@sha256:<digest>.att` (or inside an OCI v1.1 Referrers API index). The attestation envelope cryptographically binds the SHA-256 digest of the container image to the payload hash of the CycloneDX/SPDX SBOM file using a digital signature.

</details>

---

## 7. Official References & Citation Links

- **CNCF Curriculum:** [CNPE Curriculum PDF](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
- **Kubernetes Documentation:** [Kubernetes Audit Logging Architecture](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- **Kyverno Documentation:** [Kyverno Image Verification & SBOM Attestations](https://kyverno.io/docs/writing-policies/verify-images/)
- **OPA Gatekeeper:** [Gatekeeper Constraint Framework & Policy Enforcement](https://open-policy-agent.github.io/gatekeeper/website/docs/howto/)
- **CycloneDX Specification:** [OWASP CycloneDX SBOM Standard](https://cyclonedx.org/specification/overview/)
- **Anchore Syft:** [Syft SBOM Generator CLI](https://github.com/anchore/syft)
- **Aqua Security Trivy:** [Trivy Vulnerability & SBOM Scanner](https://aquasecurity.github.io/trivy/)
- **Sigstore Cosign:** [Cosign Supply Chain Attestations](https://docs.sigstore.dev/cosign/overview/)