# KCSA Study Guide — Topic 6.2: Threat Modeling Frameworks

## 1. Motivation and Production Architectural Problem

### 1.1 Architectural Problem Statement
Cloud-native workloads deployed on Kubernetes increase the attack surface dramatically compared to legacy monolithic or traditional virtual machine environments. In a Kubernetes environment, compute, network, and storage boundaries are soft, software-defined, and highly dynamic. 

Architectural vulnerabilities frequently manifest when threat modeling is treated as a static documentation requirement rather than an active control loop integrated into continuous integration/continuous deployment (CI/CD) pipelines and cluster architecture design. Without structured threat modeling, organizations experience predictable production failures:

* **Host & Cluster Compromise via Container Escape**: Misconfigured container runtimes, excessive Linux capabilities (`CAP_SYS_ADMIN`), or shared host namespaces (`hostPID`, `hostIPC`, `hostNetwork`) allow unprivileged container workloads to escape to the underlying node.
* **API Server and Control Plane Exposure**: Unauthenticated Kubelet read-only ports (`10255`), misconfigured API server endpoints, over-privileged ServiceAccounts bound to cluster-admin clusterroles, and unencrypted `etcd` datastores expose cluster state to lateral movement.
* **Unrestricted Lateral Movement**: Flat container networks without default-deny `NetworkPolicy` resources allow a compromised front-end microservice to query sensitive internal databases, cloud provider Instance Metadata Services (IMDSv1 at `169.254.169.254`), or administrative endpoints.
* **Non-Repudiation Breakdown**: Absence of granular API Server audit logging, or failure to forward audit streams to immutable centralized logging platforms, prevents forensic reconstruction during active incident response.

### 1.2 The 4Ks Security Model
Threat modeling in Kubernetes operates across the four distinct layers of the **4Ks of Cloud Native Security**:

```
                  +-----------------------------------+
                  |              Cloud                |
                  |  (IAM, KMS, Network ACLs, IMDS)   |
                  +-----------------------------------+
                                    |
                  +-----------------------------------+
                  |             Cluster               |
                  |  (API Server, RBAC, etcd, Kubelet)|
                  +-----------------------------------+
                                    |
                  +-----------------------------------+
                  |            Container              |
                  | (Images, Runtimes, Capabilities)  |
                  +-----------------------------------+
                                    |
                  +-----------------------------------+
                  |              Code                 |
                  | (Dependencies, Static Analysis)   |
                  +-----------------------------------+
```

Each layer relies on the security of the layer above it. Threat modeling frameworks provide the formal methodology required to evaluate threats at each layer, identify security boundaries, map vulnerabilities to known attack tactics, and systematically apply architectural mitigations.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Threat Modeling Framework Comparison

| Framework | Core Focus | Methodology Type | Risk Quantification | Best Use Case in Kubernetes | Limitations / Trade-offs |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **STRIDE** | Developer/Architectural component threat decomposition | Software/Architectural-centric (Categorical) | Qualitative (High/Medium/Low when paired with DREAD/CVSS) | Mapping threats to specific Kubernetes API objects, control plane boundaries, and worker node components | Can be overly granular; does not inherently account for attacker motivation or business impact |
| **PASTA** | Risk-centric process tailored to align security with business goals | Attacker-centric & Business-centric (7-stage pipeline) | Quantitative & Risk-Weighted | Architectural planning of critical financial/production platform control planes | High overhead; requires cross-functional business, compliance, and engineering participation |
| **DREAD** | Risk scoring formula for prioritizing identified threats | Quantitative Risk Rating Algorithm | Numerical Score $$(D+R+E+A+D)/5$$ (Scale 1–10) | Prioritizing remediation backlog of vulnerabilities flagged by Trivy, Falco, or Kube-bench | Highly subjective; individual ratings depend heavily on reviewer bias (deprecated by Microsoft in favor of CVSS, but still tested in foundational security exams) |
| **MITRE ATT&CK for Containers** | Empirical mapping of adversary Tactics, Techniques, and Procedures (TTPs) | Empirical / Adversary-centric Matrix | Mapped to real-world threat actors and historical incidents | SIEM/Falco detection engineering, SOC alert mapping, and penetration testing validation | Focused on post-exploitation and execution techniques rather than preventive architectural design |

### 2.2 STRIDE Threat Mapping to Kubernetes Architecture

```
                       STRIDE Threat Vector Mapping in Kubernetes
+---------------------+---------------------------------------+----------------------------------+
| STRIDE Category     | Kubernetes Vulnerability Example      | Architectural Mitigation         |
+---------------------+---------------------------------------+----------------------------------+
| Spoofing            | Kubelet / API Server impersonation    | Strict mTLS, x509 NodeRestriction|
| Tampering           | Unauthorized image mutation in registry| Image Digest pinning, Cosign     |
| Repudiation         | Actions taken without audit trace     | API Audit Policies, Immutable Logs|
| Info Disclosure     | Unencrypted Secrets in etcd           | KMS Provider (Envelope Encryption)|
| Denial of Service   | Resource exhaustion via rogue pod     | ResourceQuotas & LimitRanges     |
| Elevation of Priv.  | Container escape via hostPath / CAPs  | Pod Security Admission (Restricted)|
+---------------------+---------------------------------------+----------------------------------+
```

---

## 3. Production Manifests and Infrastructure Configurations

To mitigate threats identified via **STRIDE** and **MITRE ATT&CK for Containers**, we deploy production-grade, syntactically complete Kubernetes security manifests.

### 3.1 Anti-Repudiation Mitigation: Production `AuditPolicy` Manifest
This API Server Audit Policy mitigates **STRIDE Repudiation** and addresses **MITRE ATT&CK Technique T1613 (Container and Resource Discovery)** and **T1078 (Valid Accounts)** by capturing full request/response bodies for critical administrative mutations and metadata-level tracking for operational workloads.

```yaml
apiVersion: audit.k8s.io/v1
kind: AuditPolicy
rules:
  # Stage 1: Do not log noisy, high-volume read-only system checks
  - level: None
    users:
      - "system:kube-proxy"
      - "system:nodes"
      - "system:apiserver"
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "pods", "configmaps"]

  # Stage 2: Log RequestResponse for Secret and ConfigMap modifications (Detect Information Disclosure / Tampering)
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
    verbs: ["create", "update", "patch", "delete"]

  # Stage 3: Log RequestResponse for RBAC modifications (Detect Elevation of Privilege)
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]

  # Stage 4: Log RequestBody for workloads creating pods/executing into containers (Detect T1609 Container Exec)
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]
    verbs: ["create", "get"]

  # Stage 5: Log Metadata for all pod and workload updates across namespaces
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]
    verbs: ["create", "update", "patch", "delete"]

  # Stage 6: Fallback rule - log metadata for everything else at ResponseStarted
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

### 3.2 Elevation of Privilege Mitigation: Fully Hardened `Deployment`
This manifest enforces the **Pod Security Admission (PSA) `restricted` profile**, mitigating **STRIDE Elevation of Privilege** and **MITRE ATT&CK T1611 (Escape to Host)** by disabling root execution, dropping all Linux capabilities, enforcing read-only root filesystems, blocking privilege escalation, and restricting seccomp profiles.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway-api
  namespace: production-payments
  labels:
    app.kubernetes.io/name: payment-gateway-api
    app.kubernetes.io/part-of: payment-system
    app.kubernetes.io/managed-by: argocd
    security.cncf.io/stride-mitigation: elevation-of-privilege
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-gateway-api
  template:
    metadata:
      labels:
        app: payment-gateway-api
    spec:
      serviceAccountName: payment-gateway-sa
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
          image: internal-registry.enterprise.io/finance/payment-api:v2.4.1@sha256:8f2a1a892015383f982a7bb84f50125439c3e921d7b322a33f4a08c0250df7b0
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
          ports:
            - containerPort: 8443
              name: https
              protocol: TCP
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: tls-certs
              mountPath: /etc/tls/certs
              readOnly: true
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: tls-certs
          secret:
            secretName: payment-api-tls
```

### 3.3 Information Disclosure Mitigation: Default-Deny & Zero-Trust `NetworkPolicy`
This policy mitigates **STRIDE Information Disclosure** and **MITRE ATT&CK T1210 (Exploitation of Remote Services)** by blocking all unapproved lateral movement and preventing access to cloud provider IMDS endpoints (`169.254.169.254`).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-api-isolation-policy
  namespace: production-payments
spec:
  podSelector:
    matchLabels:
      app: payment-gateway-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow ingress strictly from API Gateway instances in the ingress-nginx namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8443
  egress:
    # Allow egress strictly to CoreDNS instances for service resolution
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow egress strictly to the dedicated database namespace on port 5432
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: production-database
          podSelector:
            matchLabels:
              role: primary-db
      ports:
        - protocol: TCP
          port: 5432
```

### 3.4 Denial of Service Mitigation: Namespace `ResourceQuota` & `LimitRange`
These resources mitigate **STRIDE Denial of Service** and **MITRE ATT&CK T1496 (Resource Hijacking)** by placing hard ceilings on compute resource consumption.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota-strict
  namespace: production-payments
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services: "5"
    persistentvolumeclaims: "2"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-container-limits
  namespace: production-payments
spec:
  limits:
    - type: Container
      default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      max:
        cpu: "2"
        memory: "4Gi"
      min:
        cpu: "50m"
        memory: "64Mi"
```

---

## 4. Real CLI Commands and Expected Terminal Outputs

### 4.1 RBAC Threat Assessment: Identifying Elevation of Privilege Risks
We inspect the cluster for wildcard permissions and dangerous RBAC verbs (`bind`, `impersonate`, `escalate`, `*`) using native `kubectl` queries.

```bash
$ kubectl get clusterrolebindings -o json | jq -r '
  .items[] | 
  select(.roleRef.name | test("admin|cluster-admin|root")) | 
  "Binding: " + .metadata.name + " -> Subject: " + (.subjects[]? | .kind + "/" + .name + " (ns: " + (.namespace//"N/A") + ")")
'
```

**Expected Terminal Output:**
```text
Binding: cluster-admin -> Subject: Group/system:masters (ns: N/A)
Binding: kube-state-metrics -> Subject: ServiceAccount/kube-state-metrics (ns: monitoring)
Binding: privileged-ci-cd-sa-binding -> Subject: ServiceAccount/gitlab-runner-sa (ns: ci-cd)
```

We evaluate whether a specific ServiceAccount can exec into pods (mapping to **MITRE ATT&CK T1609**):

```bash
$ kubectl auth can-i create pods/exec --as=system:serviceaccount:production-payments:payment-gateway-sa -n production-payments
```

**Expected Terminal Output:**
```text
no
```

### 4.2 Verifying Pod Security Admission (PSA) Enforcement
We attempt to deploy a non-compliant workload with elevated privileges (`privileged: true`, `hostNetwork: true`) to verify PSA blocking behavior (**STRIDE Elevation of Privilege** mitigation).

```bash
$ kubectl run malicious-test-pod \
  --image=busybox:1.36 \
  --namespace=production-payments \
  --overrides='{
    "spec": {
      "hostNetwork": true,
      "containers": [{
        "name": "test",
        "image": "busybox:1.36",
        "command": ["sleep", "3600"],
        "securityContext": {
          "privileged": true
        }
      }]
    }
  }'
```

**Expected Terminal Output:**
```text
Error from server (Forbidden): pods "malicious-test-pod" is forbidden: violates PodSecurity "restricted:latest": hostNetwork (hostNetwork=true), privileged (container "test" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "test" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "test" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "test" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "test" must not set runAsUser=0), seccompProfile (pod or container "test" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 4.3 Analyzing Audit Logs for Unauthorized Execution Attempts
We query the Kubernetes API Server audit logs using `rg` (ripgrep) and `jq` to detect unauthorized pod exec attempts (**MITRE ATT&CK T1609**).

```bash
$ tail -n 5000 /var/log/kubernetes/audit/audit.log | rg '"resources":\["pods"\].*"subresource":"exec"' | jq -r '
  [.stageTimestamp, .user.username, .userAgent, .objectRef.namespace, .objectRef.name, .responseStatus.code] | 
  @tsv
'
```

**Expected Terminal Output:**
```text
2026-08-07T19:42:11Z    system:serviceaccount:ci-cd:deployer    kubectl/v1.30.0 (linux/amd64)    production-payments    payment-gateway-api-7b8f9c-x2z1a    403
2026-08-07T19:45:02Z    admin-user@enterprise.io               kubectl/v1.30.0 (linux/amd64)    default                debug-pod-99b82                       200
```

### 4.4 Automated Vulnerability and Threat Scanning via Trivy
We scan our production namespace configuration to detect architectural threat violations against the CIS Benchmark and NSA Pod Security standards.

```bash
$ trivy k8s --namespace production-payments --severity HIGH,CRITICAL --report summary
```

**Expected Terminal Output:**
```text
Summary Report for production-payments

Workload Summary:
+---------------------+-------------------+-------------------+----------+-------------------+
|      NAMESPACE      |     RESOURCE      |       NAME        | SEVERITY |   VULNERABILITY   |
+---------------------+-------------------+-------------------+----------+-------------------+
| production-payments | Deployment        | payment-gateway   | OK       | 0 Critical, 0 High|
| production-payments | NetworkPolicy     | default-deny-all  | OK       | Pass              |
+---------------------+-------------------+-------------------+----------+-------------------+

Misconfiguration Summary:
+---------------------+---------------------+---------------+------------------------------------------------+
|      NAMESPACE      |      RESOURCE       |     ID        |                  TITLE                         |
+---------------------+---------------------+---------------+------------------------------------------------+
| production-payments | ServiceAccount/default| KSV036      | Service account tokens automatically mounted   |
+---------------------+---------------------+---------------+------------------------------------------------+
```

---

## 5. Troubleshooting, Diagnostic Guide, and Failure Modes

### 5.1 Troubleshooting Matrix for Threat Mitigations

```
                      Threat Mitigation Troubleshooting Flow
                       +----------------------------------+
                       |  Security Control Deployment     |
                       +----------------------------------+
                                        |
                   Does workload fail to start/communicate?
                                        |
                +-----------------------+-----------------------+
                |                                               |
         [ Workload Blocked ]                            [ Network Failed ]
                |                                               |
  Check PodSecurityAdmission logs                 Inspect CNI & NetworkPolicy
  (`kubectl get events`)                          (`cilium monitor` / `iptables`)
                |                                               |
  Fix: Adjust SecurityContext                     Fix: Add strict egress rules
  (Drop ALL caps, non-root)                       (Allow DNS on port 53)
```

| Symptoms / Failure Mode | Root Cause | Diagnostic Command | Remediation Steps |
| :--- | :--- | :--- | :--- |
| Pod remains in `CreateContainerConfigError` | Read-only root filesystem prevents application write operations (e.g., logging or temporary file generation) | `kubectl describe pod <pod-name> -n <namespace>` (Look for `Failed to create container: read-only root filesystem`) | Mount an `emptyDir` in-memory volume to `/tmp` or specific required application data directories. |
| Pod crashes with `CrashLoopBackOff` or `permission denied` | Application attempts to execute as root or bind to privileged ports ($< 1024$) while `runAsNonRoot: true` is set | `kubectl logs <pod-name> -n <namespace> --previous` | Reconfigure the application image to use a high port (e.g., `8080` instead of `80`), set `runAsUser: 10001`, and ensure directory permissions match `fsGroup`. |
| Outbound API or Database requests time out | Strict egress `NetworkPolicy` blocking traffic (e.g., missing CoreDNS egress rule on UDP 53) | `kubectl exec -it <pod-name> -n <namespace> -- nc -zv -w 3 <target-service> <port>` | Update `NetworkPolicy` to include egress rules allowing DNS resolution (`kube-system/kube-dns` on port 53) and destination database namespaces. |
| API Server rejects manifest submission with `forbidden: violates PodSecurity` | Namespace is labeled with `pod-security.kubernetes.io/enforce: restricted` but workload missing required `securityContext` settings | `kubectl get ns <namespace> --show-labels` | Update workload spec to explicitly include `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `seccompProfile: {type: RuntimeDefault}`, and `capabilities: {drop: ["ALL"]}`. |

### 5.2 Step-by-Step Diagnostic Procedure for Security Policy Failures

#### Step 1: Diagnose PodSecurityAdmission (PSA) Rejections
When a Pod manifest is rejected by the API Server admission pipeline:

```bash
$ kubectl get events -n production-payments --sort-by='.metadata.creationTimestamp' | rg 'FailedCreate'
```

If the event output indicates a PSA policy violation:
1. Verify namespace enforcement levels:
   ```bash
   $ kubectl get ns production-payments -o jsonpath='{.metadata.labels}' | jq .
   ```
2. Identify missing fields specified in the error message. Ensure both `pod.spec.securityContext` and `pod.spec.containers[*].securityContext` are populated according to Section 3.2.

#### Step 2: Debug NetworkPolicy Traffic Blockage
If pods deploy successfully but fail cross-service communication:
1. Verify if `NetworkPolicy` is active in the namespace:
   ```bash
   $ kubectl get netpol -n production-payments
   ```
2. Check egress DNS resolution from inside the pod:
   ```bash
   $ kubectl exec -it payment-gateway-api-7b8f9c-x2z1a -n production-payments -- nslookup production-db.production-database.svc.cluster.local
   ```
3. If DNS lookup fails, confirm that the `NetworkPolicy` allows egress to port `53` in namespace `kube-system`.

---

## 6. References

* **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Documentation — Threat Model**: [https://kubernetes.io/docs/concepts/security/threat-model/](https://kubernetes.io/docs/concepts/security/threat-model/)
* **Kubernetes Documentation — The 4Ks of Cloud Native Security**: [https://kubernetes.io/docs/concepts/security/overview/](https://kubernetes.io/docs/concepts/security/overview/)
* **MITRE ATT&CK Matrix for Containers**: [https://attack.mitre.org/matrices/enterprise/containers/](https://attack.mitre.org/matrices/enterprise/containers/)
* **OWASP Threat Modeling Cheat Sheet**: [https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html)
* **Kubernetes Documentation — Pod Security Standards**: [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **Kubernetes Documentation — Auditing**: [https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)