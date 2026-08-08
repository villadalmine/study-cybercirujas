# 3.3 Generating Audit Trails and Enforcing Policy Compliance

> CNPE Domain 3 — *Platform Security & Compliance*. Exam weight: 3.

---

## 1. The production problem: turning "we trust the cluster" into "prove it"

A platform team that runs multi-tenant Kubernetes for regulated workloads is eventually asked three questions by an auditor, an incident responder, or a customer's security team — and each maps to a **different control plane of evidence**:

| Question | Evidence plane | Primary artifact |
|---|---|---|
| *Who changed what, when, and was it allowed?* | **Change audit** | API server audit log + GitOps history |
| *What is actually running, and where did it come from?* | **Supply-chain audit** | SBOM + signed attestations + Rekor transparency log |
| *Does the running configuration meet policy?* | **Compliance state** | Admission enforcement + continuous scanning + PolicyReports |

The architectural failure mode is treating all three as **bolt-on, sampled, and non-tamper-evident**: a nightly image scan, a screenshot of a dashboard, a policy that only runs at `kubectl apply` time. This breaks in two predictable ways in production:

1. **Point-in-time scans lie about steady state.** An image scanned clean at build time accumulates CVEs as new advisories land; an object that passed admission is later `kubectl edit`-ed or mutated by another controller. Evidence gathered once, at create time, does not describe the cluster an hour later.
2. **Enforcement without a durable trail is unfalsifiable.** If a policy blocks a bad Pod but writes nothing you can query six months later, you cannot prove to an auditor that the control was *active and effective* during the audit window — the absence of a breach is not evidence of a working control.

The mature design makes evidence a **property of the pipeline and the running system**, not an afterthought, and separates the two enforcement timings that a control must span:

- **Admission (gate / prevent):** synchronous, blocks the write. Fast, but blind to pre-existing objects and to anything that mutates state after admission.
- **Background audit (detect):** asynchronous, scans steady state continuously. Catches drift and legacy debt, but does not stop the initial write.

You need **both**, wired to a **tamper-evident sink** (WORM storage, an append-only transparency log, or a SIEM you don't control from the cluster). The rest of this topic is the concrete machinery: API audit policy, SBOM generation and attestation, policy engines, and the compliance scanners that turn all of it into reports.

---

## 2. Technical comparatives and trade-offs

### 2.1 SBOM format: SPDX vs CycloneDX

| Dimension | SPDX | CycloneDX |
|---|---|---|
| Steward | Linux Foundation | OWASP |
| Standardization | ISO/IEC 5962:2021 | ECMA-424 |
| Primary design bias | License compliance, provenance, legal | Application security, vuln + exploitability |
| Encodings | tag-value, JSON, YAML, RDF | JSON, XML, Protobuf |
| VEX support | External (separate doc) | **Native** (embedded) |
| in-toto predicate type | `spdxjson` / `https://spdx.dev/Document` | `cyclonedx` / `https://cyclonedx.org/bom` |
| Best when | OSS-license reporting, gov/NTIA minimum-elements mandates | vuln-scanning pipelines, exploitability triage |

**Rule of thumb:** generate **both** at build time (cheap — Syft/Trivy emit either from the same catalog) and attest both. Downstream tools consume whichever they prefer; you lose nothing.

### 2.2 Admission policy engine: Gatekeeper vs Kyverno vs ValidatingAdmissionPolicy

| Dimension | Gatekeeper (OPA) | Kyverno | ValidatingAdmissionPolicy (VAP) |
|---|---|---|---|
| Policy language | Rego | YAML (declarative) | CEL |
| Where it runs | in-cluster webhook | in-cluster webhook | **inside kube-apiserver** (no webhook) |
| Failure blast radius | webhook down → `failurePolicy` decides | webhook down → `failurePolicy` decides | none (in-process, no network hop) |
| Mutation | limited (`Assign`) | yes (`mutate` / `generate`) | no (separate `MutatingAdmissionPolicy`, alpha) |
| Image signature / SBOM attestation | via external data / not native | **native** `verifyImages` + `attestations` | no |
| Continuous background audit | yes (audit controller) | yes (Reports controller) | `Audit` action → API audit log |
| Machine-readable report | constraint `status` / `gator` | **PolicyReport CRD** | audit annotations only |
| Learning curve | high (Rego) | low–medium | medium (CEL), zero infra |
| Best fit | complex logic, multi-source data joins | k8s-native, supply-chain, resource generation | latency-critical core invariants, no operator to run |

**Guidance:** push the small set of **non-negotiable invariants** (runAsNonRoot, no host namespaces) into **VAP** — it survives a total webhook outage because it lives in the apiserver. Use **Kyverno** for supply-chain gates (signature/SBOM verification) and anything needing `generate`. Reserve **Gatekeeper** for policies whose logic genuinely needs Rego's expressiveness or external data.

### 2.3 Compliance scanner: coverage matrix

| Tool | Scope | Frameworks | Delivery | Continuous |
|---|---|---|---|---|
| **kube-bench** | control-plane + node config files | CIS Kubernetes Benchmark | one-shot Job / binary | via CronJob |
| **kubescape** | manifests + live cluster + images | NSA-CISA, CIS, MITRE ATT&CK, SOC2 | CLI / operator | operator yes |
| **Trivy (+ Operator)** | images, IaC, cluster, SBOM, secrets | NSA, CIS, PSS-baseline/restricted, k8s-cis | CLI / operator CRDs | operator yes |
| **Compliance Operator** | node + platform (OpenShift) | OSCAL/SCAP: CIS, PCI-DSS, NIST 800-53 moderate | operator (`ScanSettingBinding`) | scheduled |

### 2.4 Audit-trail source: what each one can and cannot prove

| Source | Answers | Tamper-evidence (default) | Retention owner |
|---|---|---|---|
| API server audit log | who/what/when on every API call | **none** — you must ship to WORM/SIEM | you |
| GitOps history (Argo CD / Flux) | desired-state change + approver | git commit signatures + protected branches | git host |
| Admission decision logs (Kyverno/OPA) | what was allowed/blocked and *why* | none | you |
| Rekor transparency log | which artifacts were signed/attested | **Merkle tree, append-only** | public or self-hosted |
| Falco events | runtime, syscall-level behavior | none | you |

---

## 3. Manifests and infrastructure (complete, unabridged)

### 3.1 Kubernetes API server audit policy

Rules are evaluated **top-down; the first match wins.** A broad `level: None` placed too high silently blackholes everything below it — the single most common cause of "auditing is on but there are no events."

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# Drop the highest-volume, lowest-value stage globally.
omitStages:
  - "RequestReceived"
rules:
  # 1. Read-only, high-frequency, no-value endpoints: never record.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/metrics"
      - "/swagger*"

  # 2. Silence the scheduler/controller-manager/kubelet watch-list storm.
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager"]
    verbs: ["watch", "list", "get"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["watch", "list", "get"]

  # 3. Secrets / ConfigMaps / tokens: METADATA ONLY — never persist payloads.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # 4. RBAC + workload writes: full request AND response body.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods", "services", "namespaces", "serviceaccounts"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]
      - group: "policy"
        resources: ["*"]

  # 5. exec / attach / port-forward: always full — this is lateral movement.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 6. Catch-all LAST: metadata, so nothing is ever silently invisible.
  - level: Metadata
```

kube-apiserver static-pod wiring (kubeadm clusters — edit `/etc/kubernetes/manifests/kube-apiserver.yaml`; the kubelet restarts the pod on file change):

```yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        # ... existing flags ...
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-format=json
        - --audit-log-maxage=30          # days retained on disk
        - --audit-log-maxbackup=10       # rotated files kept
        - --audit-log-maxsize=100        # MB per file before rotation
        # Optional: stream to an external SIEM in addition to disk.
        - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
        - --audit-webhook-mode=batch
        - --audit-webhook-batch-max-size=100
      volumeMounts:
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        - name: audit-log
          mountPath: /var/log/kubernetes/audit
          readOnly: false
  volumes:
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-log
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

Webhook backend (a kubeconfig-shaped file pointing at your log forwarder / SIEM):

```yaml
# /etc/kubernetes/audit/webhook.yaml
apiVersion: v1
kind: Config
clusters:
  - name: audit-sink
    cluster:
      server: https://audit-forwarder.observability.svc:8443/audit
      certificate-authority: /etc/kubernetes/audit/ca.crt
contexts:
  - name: audit-sink
    context:
      cluster: audit-sink
      user: apiserver
current-context: audit-sink
users:
  - name: apiserver
    user:
      client-certificate: /etc/kubernetes/audit/apiserver.crt
      client-key: /etc/kubernetes/audit/apiserver.key
```

A single emitted event (this is the atom an auditor reads):

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "auditID": "a1f6c2b0-9d3e-4b21-8f2a-11c2d3e4f5a6",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/prod/pods",
  "verb": "create",
  "user": {
    "username": "alice@corp.example",
    "groups": ["platform-admins", "system:authenticated"]
  },
  "sourceIPs": ["10.0.4.12"],
  "userAgent": "kubectl/v1.30.2 (linux/amd64)",
  "objectRef": { "resource": "pods", "namespace": "prod", "name": "payments-7c9" },
  "responseStatus": { "code": 201 },
  "requestReceivedTimestamp": "2026-08-07T14:03:11.101Z",
  "stageTimestamp": "2026-08-07T14:03:11.148Z",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RoleBinding \"platform-admins\" of ClusterRole \"admin\"",
    "pod-security.kubernetes.io/enforce-policy": "restricted:latest"
  }
}
```

> **Managed clusters** (EKS/GKE/AKS) do not let you edit apiserver flags. You enable the equivalent through the provider: EKS *control-plane logging → `audit`* → CloudWatch; GKE *Cloud Audit Logs*; AKS *diagnostic settings → `kube-audit`*. The policy is fixed by the provider, but the events are the same schema.

### 3.2 ValidatingAdmissionPolicy — enforce *and* feed the audit trail

VAP runs inside the apiserver (no webhook to fail) and its `Audit` action emits an annotation straight into the audit log above — enforcement and evidence in one object.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-runasnonroot
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: >-
        has(object.spec.securityContext) &&
        has(object.spec.securityContext.runAsNonRoot) &&
        object.spec.securityContext.runAsNonRoot == true
      message: "Pod .spec.securityContext.runAsNonRoot must be true"
      reason: Forbidden
  auditAnnotations:
    - key: runasnonroot-check
      valueExpression: >-
        "runAsNonRoot=" + string(
          has(object.spec.securityContext) &&
          has(object.spec.securityContext.runAsNonRoot) &&
          object.spec.securityContext.runAsNonRoot)
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-runasnonroot-binding
spec:
  policyName: require-runasnonroot
  # Deny blocks the write; Audit records the evaluation into the API audit log.
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: environment
          operator: In
          values: ["prod", "staging"]
```

### 3.3 Kyverno — supply-chain gate: verify signature **and** SBOM attestation

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: supply-chain-gate
  annotations:
    policies.kyverno.io/title: Verify cosign signature and SPDX SBOM attestation
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  background: false          # image verification cannot run in background scans
  rules:
    - name: verify-keyless-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "ghcr.io/myorg/*"
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/myorg/*/.github/workflows/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: "https://rekor.sigstore.dev"

    - name: require-spdx-sbom-attestation
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "ghcr.io/myorg/*"
          attestations:
            - type: "https://spdx.dev/Document"
              attestors:
                - entries:
                    - keyless:
                        subject: "https://github.com/myorg/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ spdxVersion }}"
                      operator: Equals
                      value: "SPDX-2.3"
```

Sigstore **policy-controller** is the lighter-weight alternative when signatures are all you need (no PolicyReports, no generation):

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-keyless-signature
spec:
  images:
    - glob: "ghcr.io/myorg/**"
  authorities:
    - keyless:
        identities:
          - issuer: "https://token.actions.githubusercontent.com"
            subjectRegExp: "https://github.com/myorg/.*"
      ctlog:
        url: https://rekor.sigstore.dev
```

### 3.4 Gatekeeper — ConstraintTemplate + Constraint (required labels)

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels
        violation[{"msg": msg}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: require-owner-label
spec:
  enforcementAction: deny        # or "dryrun"/"warn" — audit controller still records violations
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Namespace"]
  parameters:
    labels: ["owner"]
```

### 3.5 kube-bench as a Job (CIS control-plane scan)

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-master
  namespace: security
spec:
  template:
    spec:
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:v0.7.3
          command: ["kube-bench", "run", "--targets", "master", "--json"]
          volumeMounts:
            - { name: var-lib-etcd,  mountPath: /var/lib/etcd,  readOnly: true }
            - { name: etc-kubernetes, mountPath: /etc/kubernetes, readOnly: true }
            - { name: etc-systemd,    mountPath: /etc/systemd,    readOnly: true }
            - { name: usr-bin,        mountPath: /usr/local/mount-from-host/bin, readOnly: true }
      volumes:
        - { name: var-lib-etcd,  hostPath: { path: /var/lib/etcd } }
        - { name: etc-kubernetes, hostPath: { path: /etc/kubernetes } }
        - { name: etc-systemd,    hostPath: { path: /etc/systemd } }
        - { name: usr-bin,        hostPath: { path: /usr/bin } }
```

### 3.6 Falco rule — runtime audit signal for interactive shells

```yaml
- rule: Terminal shell in container
  desc: A shell was spawned in a container with an attached TTY (interactive access).
  condition: >
    spawned_process and container
    and shell_procs and proc.tty != 0
    and container_entrypoint
  output: >
    Interactive shell in container
    (user=%user.name container=%container.name image=%container.image.repository
     proc=%proc.cmdline parent=%proc.pname)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]
```

---

## 4. CLI commands and real terminal output

### 4.1 Generate SBOMs (SPDX + CycloneDX) with Syft

```console
$ syft ghcr.io/myorg/payments:1.8.3 \
    -o spdx-json=sbom.spdx.json \
    -o cyclonedx-json=sbom.cdx.json
 ✔ Parsed image                    sha256:9b2c4f...e01
 ✔ Cataloged contents              1f0e7a...c9
   ├── ✔ Packages                        [214 packages]
   ├── ✔ File digests                    [1,204 files]
   └── ✔ Executables                     [88 executables]
$ jq '.packages | length' sbom.spdx.json
215
$ jq -r '.spdxVersion, .creationInfo.creators[]' sbom.spdx.json
SPDX-2.3
Tool: syft-1.14.0
Organization: myorg
```

### 4.2 Sign the image and attach the SBOM as a keyless attestation

```console
$ cosign attest --yes \
    --predicate sbom.spdx.json \
    --type spdxjson \
    ghcr.io/myorg/payments:1.8.3
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
Successfully verified SCT...
tlog entry created with index: 78412093
```

### 4.3 Verify signature + attestation at (or before) deploy time

```console
$ cosign verify-attestation \
    --type spdxjson \
    --certificate-identity-regexp "https://github.com/myorg/.*" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    ghcr.io/myorg/payments:1.8.3 \
  | jq '.payload |= @base64d | .payload | fromjson | .predicateType'

Verification for ghcr.io/myorg/payments:1.8.3 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
"https://spdx.dev/Document"

$ cosign tree ghcr.io/myorg/payments:1.8.3
📦 Supply Chain Security Related artifacts for an image: ghcr.io/myorg/payments:1.8.3
└── 💾 Attestations for an image tag: ghcr.io/myorg/payments:sha256-9b2c...e01.att
   └── 🍒 sha256:4a7f...  (predicateType: https://spdx.dev/Document)
└── 🔐 Signatures for an image tag: ghcr.io/myorg/payments:sha256-9b2c...e01.sig
   └── 🍒 sha256:2c19...
```

### 4.4 Scan the SBOM (not the image) for CVEs with Trivy

```console
$ trivy sbom sbom.cdx.json --severity HIGH,CRITICAL
sbom.cdx.json (cyclonedx)
Total: 3 (HIGH: 2, CRITICAL: 1)
┌───────────┬────────────────┬──────────┬───────────────┬─────────────┐
│  Library  │ Vulnerability  │ Severity │ Installed Ver │  Fixed Ver  │
├───────────┼────────────────┼──────────┼───────────────┼─────────────┤
│ libssl3   │ CVE-2024-6119  │ CRITICAL │ 3.0.11-r0     │ 3.0.12-r0   │
│ libcrypto3│ CVE-2024-4741  │ HIGH     │ 3.0.11-r0     │ 3.0.12-r0   │
│ curl      │ CVE-2024-2398  │ HIGH     │ 8.5.0-r0      │ 8.7.1-r0    │
└───────────┴────────────────┴──────────┴───────────────┴─────────────┘
```

### 4.5 Inspect the Rekor transparency-log entry (the immutable audit record)

```console
$ rekor-cli search --sha sha256:9b2c4f...e01
Found matching entries (listed by UUID):
24296fb24b8ad77a3c9f...e2

$ rekor-cli get --uuid 24296fb24b8ad77a3c9f...e2 --format json \
  | jq '{logIndex: .LogIndex, kind: .Attestation | length > 0}'
{
  "logIndex": 78412093,
  "kind": true
}
```

### 4.6 Query Kyverno PolicyReports (continuous compliance state)

```console
$ kubectl get policyreports -A
NAMESPACE   NAME                       KIND   PASS   FAIL   WARN   ERROR   AGE
prod        3f9a2c...-b1               Pod    6      1      0      0       6d
prod        7c1e88...-4d               Pod    7      0      0      0       6d
staging     a02f11...-9e               Pod    5      2      0      0       6d

$ kubectl get policyreport -n prod 3f9a2c...-b1 \
    -o jsonpath='{.results[?(@.result=="fail")].message}{"\n"}'
image ghcr.io/myorg/legacy:latest is not signed
```

### 4.7 CIS benchmark with kube-bench

```console
$ kubectl logs job/kube-bench-master -n security | grep -E '\[FAIL\]|== Summary'
[FAIL] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 1.2.16 Ensure that the --audit-log-path argument is set (Automated)
[FAIL] 1.3.2  Ensure that the controller-manager --profiling is false (Automated)
== Summary master ==
44 checks PASS
5 checks FAIL
12 checks WARN
0 checks INFO
```

### 4.8 Framework compliance with kubescape and Trivy

```console
$ kubescape scan framework nsa --format pretty-printer
[info] Kubescape scanner initializing
[success] Score: 78.42% (compliance)
┌────────────────────────────────────────────┬────────┬──────────┐
│ Control name                               │ Score  │ Status   │
├────────────────────────────────────────────┼────────┼──────────┤
│ Allow privilege escalation                 │ 12%    │ failed   │
│ Immutable container filesystem             │ 40%    │ failed   │
│ Non-root containers                        │ 88%    │ passed   │
└────────────────────────────────────────────┴────────┴──────────┘

$ trivy k8s --compliance k8s-nsa-1.0 --report summary cluster
NSA, CISA Kubernetes Hardening Guidance v1.0
┌──────┬───────────────────────────────────┬──────┬──────┐
│  ID  │              Name                 │ Fail │ Pass │
├──────┼───────────────────────────────────┼──────┼──────┤
│ 1.0  │ Non-root containers               │  4   │  38  │
│ 2.0  │ Immutable container file systems  │  6   │  36  │
│ 4.0  │ Restrict SELinux / seccomp        │  9   │  33  │
└──────┴───────────────────────────────────┴──────┴──────┘
```

### 4.9 GitOps history as change audit

```console
$ argocd app history payments
ID  DATE                           REVISION
3   2026-08-05 09:11:02 +0000 UTC  main (7d4c1a)
4   2026-08-06 16:42:55 +0000 UTC  main (b90ef2)
5   2026-08-07 14:03:11 +0000 UTC  main (a1f6c2)

$ git log --show-signature -1 a1f6c2
commit a1f6c2... 
gpg: Good signature from "Alice <alice@corp.example>" [ultimate]
    Bump payments to 1.8.3 (signed SBOM verified in CI)
```

---

## 5. Verification and failure diagnosis

### 5.1 Auditing is enabled but no events appear

```console
# 1. Is the flag actually on the running apiserver?
$ ps -ef | grep -o -- '--audit-policy-file=[^ ]*'
--audit-policy-file=/etc/kubernetes/audit/policy.yaml

# 2. Did the static pod restart cleanly, or is it CrashLooping on a bad mount?
$ crictl ps -a --name kube-apiserver
CONTAINER    STATE       NAME             ATTEMPT
9f2c...      Running     kube-apiserver   0

# 3. Is the file growing?
$ tail -n1 /var/log/kubernetes/audit/audit.log | jq .verb
"create"
```

- **Empty log, apiserver healthy** → a `level: None` rule sits *above* what you meant to capture. Rules are first-match-wins; move the `None` filters below the writes you care about, or scope them tightly with `verbs`/`users`.
- **apiserver CrashLoops after edit** → the `hostPath` for the log directory is missing or the mount is `readOnly: true`. `crictl logs <id>` / `journalctl -u kubelet` shows the mount error.
- **`RequestReceived` duplicates everything** → you forgot `omitStages: ["RequestReceived"]`; each request otherwise emits at every stage.

### 5.2 `verifyImages` blocks legitimate deploys

- **`no signatures found`** → the image is genuinely unsigned, or `imageReferences` doesn't match the pushed registry path (a floating tag vs the digest). Verify by digest: attestations attach to the **digest**, not a mutable tag.
- **`no matching signatures: certificate identity ...`** → the Fulcio cert SAN doesn't match your `subject`/`issuer` regex. Run `cosign verify` manually and read back the identity it prints, then align the regex.
- **Rekor unreachable / air-gapped** → the tlog check times out. Point `rekor.url` at your internal Rekor, or set `--insecure-ignore-tlog` **only** with a documented compensating control — it removes the transparency guarantee.
- **Whole cluster can't create Pods** → `failurePolicy: Fail` + an unhealthy Kyverno webhook. Confirm with `kubectl get validatingwebhookconfigurations` and `kubectl -n kyverno get pods`; scope the policy with a `namespaceSelector` so a Kyverno outage cannot take out `kube-system`.

### 5.3 PolicyReports are empty or stale

- **No report for pre-existing objects** → the policy has `background: false` (mandatory for `verifyImages`), so it only fires at admission. Existing violations require a `background: true` policy or an out-of-band scan (Trivy Operator / kubescape).
- **Reports not refreshing** → the Kyverno reports controller / reports-server is unhealthy: `kubectl -n kyverno logs deploy/kyverno-reports-controller`.

### 5.4 SBOM attestation "not found"

```console
$ cosign verify-attestation --type spdxjson ... ghcr.io/myorg/payments:1.8.3
Error: no matching attestations
```

- **`--type` mismatch** — you attested `cyclonedx` but are verifying `spdxjson` (or a custom predicate URI). The predicate type must match exactly.
- **Registry lacks OCI 1.1 referrers** — cosign falls back to a `sha256-<digest>.att` tag; some registries garbage-collect or block it. Confirm the artifact exists with `cosign tree <image>` or `oras discover <image> --format tree`.
- **Verifying a tag that moved** — the attestation is bound to the digest present at sign time; re-verify against the specific digest.

### 5.5 kube-bench floods FAIL on managed clusters

- On EKS/GKE/AKS you don't own the control-plane files, so `master` checks report `FAIL`/`WARN` spuriously. Run `--targets node,policies` only, and select the benchmark that matches the platform (`--benchmark eks-1.5.0`, `gke-1.6.0`, `aks-1.7`) — the wrong benchmark version tests the wrong control set entirely.

---

## 6. References

- Kubernetes — Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — Validating Admission Policy (CEL): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- CNPE Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kyverno — Verify Images: https://kyverno.io/docs/writing-policies/verify-images/
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Sigstore cosign: https://docs.sigstore.dev/cosign/overview/
- Sigstore policy-controller: https://docs.sigstore.dev/policy-controller/overview/
- Rekor transparency log: https://docs.sigstore.dev/logging/overview/
- SPDX (ISO/IEC 5962:2021): https://spdx.dev/
- CycloneDX (OWASP / ECMA-424): https://cyclonedx.org/
- Anchore Syft: https://github.com/anchore/syft
- Trivy: https://trivy.dev/ — Trivy Operator: https://aquasecurity.github.io/trivy-operator/
- kube-bench: https://github.com/aquasecurity/kube-bench
- Kubescape: https://kubescape.io/
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- NSA/CISA Kubernetes Hardening Guidance: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- SLSA (Supply-chain Levels for Software Artifacts): https://slsa.dev/
- in-toto attestation framework: https://in-toto.io/
- Policy Report CRD (kubernetes-sigs wg-policy): https://github.com/kubernetes-sigs/wg-policy-prototypes
- OpenVEX: https://github.com/openvex
- Kubernetes SBOM tool `bom`: https://github.com/kubernetes-sigs/bom
- NIST SP 800-190 (Application Container Security Guide): https://csrc.nist.gov/publications/detail/sp/800-190/final