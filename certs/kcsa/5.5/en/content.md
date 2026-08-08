# KCSA Exam Preparation Series: Module 5.5 — Public Key Infrastructure (PKI) in Kubernetes

## 1. Production Architectural Motivation & Internal Mechanics

Public Key Infrastructure (PKI) constitutes the foundational trust layer of a Kubernetes cluster. Every control plane component, worker node agent (`kubelet`), webhook conversion controller, and user entity relies on X.509 digital certificates and mutual TLS (mTLS) to achieve identity authentication, transport layer encryption, and authorization context propagation.

```
                      +------------------------------------------+
                      |         Root Certificate Authority       |
                      |            (Offline / HSM / Vault)       |
                      +--------------------+---------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
        +-----------v-----------+                     +-----------v-----------+
        |  Kubernetes Control   |                     |     etcd Cluster      |
        |       Plane CA        |                     |        Peer CA        |
        +-----------+-----------+                     +-----------+-----------+
                    |                                             |
       +------------+------------+                   +------------+------------+
       |                         |                   |                         |
+------v------+           +------v------+     +------v------+           +------v------+
| API Server  |           |   Kubelet   |     | etcd Peer 1 |           | etcd Peer 2 |
| Server Cert |           | Client Cert |     | Client/Svr  |           | Client/Svr  |
+-------------+           +-------------+     +-------------+           +-------------+
```

### 1.1 The Kubernetes Control Plane Trust Boundaries
Kubernetes PKI is not monolithic; a hardened production deployment enforces distinct trust domains managed by independent CA chains:

1. **Kubernetes Core CA**: Signs server certificates for `kube-apiserver` and client certificates for cluster administrators, `kube-controller-manager`, `kube-scheduler`, and `kubelet` control interfaces.
2. **etcd Peer & Client CAs**: Encrypts etcd raft replication traffic (Peer CA) and authenticates `kube-apiserver` read/write access to etcd (Client CA). Isolating the etcd CA prevents an compromised control plane component from forging etcd client credentials.
3. **Front-Proxy Aggregation CA**: Signs client certificates presented by `kube-apiserver` to extension API servers (e.g., Metrics Server). Enables user impersonation headers (`X-Remote-User`, `X-Remote-Group`) securely.
4. **Service Account Key Pair**: RSA/ECDSA keypair used strictly for signing and validating JWT tokens presented by pod workloads (not an X.509 CA chain).

### 1.2 X.509 Attribute Mapping & Identity Extraction
When an entity presents an X.509 client certificate to the `kube-apiserver`, the server authenticates the connection against the configured `--client-ca-file` and extracts identity attributes directly from the certificate's **Subject Distinguished Name (DN)**:

* **Subject Common Name (`CN`)**: Mapped to the Kubernetes **User** identity (e.g., `CN=system:node:worker-01` or `CN=jane.doe@company.com`).
* **Subject Organization (`O`)**: Mapped to Kubernetes **Groups** (e.g., `O=system:nodes` or `O=devops-engineering`). A certificate can contain multiple `O` fields, placing the identity into multiple RBAC groups simultaneously.
* **Subject Alternative Names (`SAN`)**: Mandatory for server certificates. Defines IP addresses (`IP:10.96.0.1`) and DNS names (`DNS:kubernetes`, `DNS:kubernetes.default.svc.cluster.local`) under which the service is reachable.

### 1.3 Key Usage (KU) & Extended Key Usage (EKU) Constraints
X.509 v3 extensions enforce intended usage limits. The `kube-apiserver` strictly verifies EKUs during TLS handshakes:

* `serverAuth` (`id-kp-serverAuth`): Required for endpoints accepting incoming TLS connections (API Server, Kubelet HTTPS endpoint, Admission Webhooks).
* `clientAuth` (`id-kp-clientAuth`): Required for clients establishing outgoing mTLS connections (Kubelet client, Controller Manager client, kubectl user certificates).

### 1.4 API-Driven Certificate Management (`certificates.k8s.io/v1`)
Kubernetes provides an automated certificate issuance engine through the `CertificateSigningRequest` (CSR) API:
1. **CSR Submission**: A client generates a local private key and submits an encoded PEM CSR to the API server.
2. **Authorization & Validation**: The `kube-controller-manager` enforces RBAC policies checking if the requester has permissions on `certificatesigningrequests/approval` for specific signers (`kubernetes.io/kube-apiserver-client`, `kubernetes.io/kubelet-serving`, `kubernetes.io/legacy-unknown`).
3. **Approval Engine**: An administrator or automated controller signs off on the CSR using `kubectl certificate approve`.
4. **Issuance**: The `csrsigning` controller signs the CSR using the stored CA key pair and updates `.status.certificate`.

---

## 2. Technical Comparison & Architecture Trade-offs

### Table 2.1: Cryptographic Key Algorithms in Kubernetes PKI

| Metric / Dimension | RSA (3072-bit / 4096-bit) | ECDSA (P-256 / P-384) | Ed25519 |
| :--- | :--- | :--- | :--- |
| **Security Level Equivalent** | ~128-bit / ~152-bit | 128-bit / 192-bit | ~128-bit |
| **Handshake Latency & CPU Overhead** | High verification CPU usage; slow key generation | Extremely fast signatures; lower CPU overhead | High speed, minimal CPU overhead |
| **Key Size (Storage Footprint)** | Large (~2.5 KB to 3.3 KB PEM) | Compact (~400 Bytes PEM) | Ultra-compact (~250 Bytes PEM) |
| **Kubernetes / Ecosystem Compatibility** | Universal across all legacy tools and TLS stacks | Fully supported in Go TLS & standard K8s components | Partial; unsupported by older TLS implementations |
| **Production Recommendation** | Recommended for Root/Intermediate CAs (legacy compatibility) | **Recommended for all Cluster Components & Workloads** | Experimental / Internal microservices only |

### Table 2.2: Certificate Issuance Architectural Patterns

| Architecture | Operational Complexity | Blast Radius / Security Risk | Certificate Lifecycle Automation | Vault / External HSM Integration |
| :--- | :--- | :--- | :--- | :--- |
| **Static File-based CA (kubeadm default)** | Low operational overhead; manual scripts needed | High: CA private key resides on control plane nodes | Poor: Requires manual renewal or kubeadm cert renew commands | Difficult; requires custom tooling |
| **Native K8s CSR API (`certificates.k8s.io`)** | Low: Built directly into Kubernetes API server | Medium: Limited to Kubernetes cluster scope; simple authorization | High for Kubelet client certs; low for ingress/webhooks | Indirect via custom CSR signer controllers |
| **`cert-manager` + HashiCorp Vault / External Issuer** | Medium to High: Requires maintaining operator in-cluster | Minimal: CA key remains inside Vault HSM; fine-grained audit | **Optimal: Automated issuance, renewal, and ACME validation** | Enterprise Native: Full integration via AppRole / K8s Auth |

### Table 2.3: Revocation & Short-Lived Certificate Strategies

| Strategy | Mechanical Execution | Network Overhead | Kubernetes Support | Production Assessment |
| :--- | :--- | :--- | :--- | :--- |
| **Certificate Revocation Lists (CRL)** | Static list of serial numbers checked via HTTP | High: Download size scales with revoked certificates | **No native support in `kube-apiserver` mTLS** | Unsuitable for dynamic cloud-native clusters |
| **Online Certificate Status Protocol (OCSP)** | Real-time query to CA validation responder | Medium: Adds network hop during every TLS handshake | Unsupported by standard Golang TLS listeners | Impractical for high-throughput API Server calls |
| **Short-Lived Certificates (TTL <= 24h)** | Certificates expire automatically before exploit window | None: Eliminates out-of-band validation requirements | Native via `cert-manager` / SPIFFE-SPIRE auto-rotation | **Gold Standard: Zero-trust compliance paradigm** |

---

## 3. Complete Production Manifests & Configuration Infrastructure

### 3.1 Kubernetes Native CertificateSigningRequest (`certificates.k8s.io/v1`)
The following manifest submits a CSR for an internal SRE monitoring client component requiring client authentication to the API server:

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-monitoring-client-csr
  labels:
    tier: infrastructure
    environment: production
spec:
  request: MIIBvTCCASQCAQAwJDEiMCAGA1UEAwwZc3JlLW1vbml0b3Jpbmctc2VydmljZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPZ+8T1vF5bQJ3X8/g1+g0hY6a5W+R1S+4Xv0vF1k+zN7uW7sP0N+Z9y6X1n9W2y8Z3S5v8T0vF1k+zN7uW7sP6gXjBcBgkqhkiG9w0BCQ4headerXDBAMBgNVHSMEIDAAeAAYBokwCwYDVR0PBAQDAgWgMB0GA1UdJQQWMBQGCCsGAQUFBwMCBggrBgEFBQcDADAKBggqhkjOPQQDAgNIADBFAiEA/x+Y8+5K1X9z8+4Xv0vF1k+zN7uW7sP0N+Z9y6X1n9UCICX/f8T1vF5bQJ3X8/g1+g0hY6a5W+R1S+4Xv0vF1k+z
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
    - digital signature
    - key encipherment
    - client auth
```

### 3.2 cert-manager Production HashiCorp Vault ClusterIssuer
This manifest configures a cluster-wide certificate authority backed by HashiCorp Vault using Kubernetes ServiceAccount token authentication:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki-issuer
spec:
  vault:
    server: https://vault.internal.infrastructure.net:8200
    path: pki_k8s/sign/production-intermediate
    caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWx1Z0F3SUJBZ0lVTnZZNVZ4c0Z0YXZXOWdCSWdYRW1qS0J2S0x3d0RRWUpLb1pJaHZjTkFRRUwKQlFBd1JERUxNQWtHQTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ3BOdmFXNWtZVEVNTUFvR0ExVUVDd3dEVEVsawpNQjRYRFRJeE1ERXlNVEE1TURRMU1sb1hEVE14TURFeU1EQTVNRFExTWxvdyZERVNNQUdHQTFVRUF3d0ZRVmRPCnQyRnlMVk5ZTWNCWENEVXlNQTRHQTFVREVRd0hRMlY1SUZkNUlFMTVJRkpQVDEwV01CNEdBMVVkRHdXRQpCUUF3SUZvb01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQkFRQzF2NGZkR3ZyT3lCSHJ3UzU5Q1p0L2tTTVkKS0g0eEZwUUpHUTlhMWJ0MDFYMHZZcE45c3Jld3FvTk1ZVkVnVWgxbEFlZEJ1dkp0S1E1NmJHZmlzYjBQCnR6K3Yrd1ZwMkxYZ2p2SktSazhKMWFvNThUcXlGVW5aK0U1ZUtHUlVkMWp6c2RXZnVkRjU2N3UzaExSVApvMm0rcVZtbVdtS3hVUGt4UUpnLzMyeTV4VkpqM0d1dDFiTFVzSzhIdUlycmkyOHlCVi9MZFhhSndlTHQKY0s3RktnTkpYTFhrcmFsY3c3a0k2WjkyU3Boc0s1L0pmTG5iSElhbHpmMSt3cTF4eWZqZ1p2Y29RSmFtdgp4cTF5c2F4N2VpdGpyRndPdkR6ZldHdmRzZnlYOHl1SGpxUGk4aVpMbEZlS1ZqL2sreS9QWmhLSgppc3Nvd3JhUk96T0c0N1BMTnNDS016TGsvSzd6Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0=
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager-pki-signer
        secretRef:
          name: cert-manager-vault-token
          key: token
```

### 3.3 cert-manager Production Certificate Request
A complete `Certificate` resource enforcing ECDSA encryption, strict 90-day lifetime, 30-day auto-renewal, and SAN definitions:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-gateway-tls
  namespace: ingress-gateways
spec:
  secretName: api-gateway-tls-secret
  duration: 2160h0m0s # 90 Days
  renewBefore: 720h0m0s # 30 Days
  subject:
    organizations:
      - Infrastructure Engineering
    organizationalUnits:
      - Security Operations
  commonName: api.production.domain.net
  dnsNames:
    - api.production.domain.net
    - internal-api.production.domain.net
  ipAddresses:
    - 10.100.50.25
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - key encipherment
    - server auth
    - client auth
  issuerRef:
    name: vault-pki-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

### 3.4 Hardened API Server Static Pod PKI Configuration Snippet
Fragment of `/etc/kubernetes/manifests/kube-apiserver.yaml` configuring strict mTLS verification and dedicated CAs:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
```

---

## 4. Real CLI Commands & Terminal Output Execution Stream

### 4.1 Step 1: Generate Private Key and CSR Using OpenSSL
Generate an ECDSA P-256 private key and a CSR containing custom Subject and SAN extensions:

```bash
$ openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -keyout cluster-admin-sre.key \
    -out cluster-admin-sre.csr \
    -subj "/CN=sre-admin/O=system:masters" \
    -addext "subjectAltName=DNS:sre-admin.local,email:sre-oncall@company.com"
```

```text
Generating a ECDSA private key
writing new private key to 'cluster-admin-sre.key'
-----
```

### 4.2 Step 2: Encode and Submit the CSR to Kubernetes API Server
Encode the CSR using base64 and wrap it inside a `CertificateSigningRequest` object:

```bash
$ CSR_BASE64=$(cat cluster-admin-sre.csr | base64 | tr -d '\n')
$ cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-admin-access
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 28800
  usages:
  - client auth
  - digital signature
  - key encipherment
EOF
```

```text
certificatesigningrequest.certificates.k8s.io/sre-admin-access created
```

### 4.3 Step 3: Inspect Pending CSR Status
Verify that the CSR exists and is waiting for manual administrator approval:

```bash
$ kubectl get csr sre-admin-access -o wide
```

```text
NAME               AGE   SIGNERNAME                            REQUESTOR                 REQUESTEDDURATION   CONDITION
sre-admin-access   12s   kubernetes.io/kube-apiserver-client   kubernetes-admin          8h                  Pending
```

### 4.4 Step 4: Approve CSR and Extract Signed Certificate
Approve the request using `kubectl certificate approve` and extract the resulting signed X.509 certificate:

```bash
$ kubectl certificate approve sre-admin-access
```

```text
certificatesigningrequest.certificates.k8s.io/sre-admin-access approved
```

```bash
$ kubectl get csr sre-admin-access -o jsonpath='{.status.certificate}' | base64 --decode > cluster-admin-sre.crt
$ ls -lh cluster-admin-sre.crt
```

```text
-rw-r--r-- 1 root root 1.1K Aug 7 20:24 cluster-admin-sre.crt
```

### 4.5 Step 5: Validate X.509 Certificate Extensions & Identity Attributes
Inspect the issued certificate to verify that `CN`, `O`, `SAN`, and `EKU` attributes match the desired specifications:

```bash
$ openssl x509 -in cluster-admin-sre.crt -text -noout | grep -E "Subject:|Issuer:|Not After|ASN1 OID|DNS:" -A 1
```

```text
        Issuer: CN = kubernetes
        Validity
            Not Before: Aug  7 20:20:00 2026 GMT
            Not After : Aug  8 04:24:00 2026 GMT
        Subject: CN = sre-admin, O = system:masters
        X509v3 Extended Key Usage: 
            TLS Web Client Authentication
        X509v3 Subject Alternative Name: 
            DNS:sre-admin.local, email:sre-oncall@company.com
```

### 4.6 Step 6: Verify Certificate Chain Against Cluster CA
Confirm cryptographic trust against the control plane CA bundle:

```bash
$ openssl verify -CAfile /etc/kubernetes/pki/ca.crt cluster-admin-sre.crt
```

```text
cluster-admin-sre.crt: OK
```

---

## 5. Verification & Troubleshooting Guide

### 5.1 Production Troubleshooting Matrix

```
                        +--------------------------------+
                        |  Kubernetes TLS Failure Event  |
                        +---------------+----------------+
                                        |
                 +----------------------+----------------------+
                 |                                             |
    +------------v------------+                   +------------v------------+
    |   Handshake Error       |                   |  Authorization Failure  |
    |  "unknown authority"    |                   |   "user unauthorized"   |
    +------------+------------+                   +------------+------------+
                 |                                             |
    +------------v------------+                   +------------v------------+
    | Check CA Bundle Match   |                   | Validate CN & O Fields  |
    | & Intermediate Chains   |                   | Against RBAC Bindings   |
    +-------------------------+                   +-------------------------+
```

| Symptom / Log Output | Root Cause | Remediation Workflow |
| :--- | :--- | :--- |
| `x509: certificate signed by unknown authority` | The client trusts a CA bundle that does not include the signing CA of the target server certificate. | 1. Extract remote cert: `openssl s_client -connect <host>:443 -showcerts`<br>2. Compare Issuer Hash with `/etc/kubernetes/pki/ca.crt`<br>3. Mount correct CA bundle into client pod. |
| `x509: certificate relies on legacy Common Name field` | Go 1.15+ enforces strict SAN validation. The certificate lacks the DNS SAN extension matching the requested endpoint. | Re-issue certificate using OpenSSL/cert-manager with explicit `subjectAltName=DNS:<hostname>` fields. |
| `tls: failed to verify certificate: x509: certificate has expired or is not yet valid` | System clock drift or certificate lifetime exceeded without auto-rotation. | 1. Check system time: `chronyc tracking`<br>2. Check certificate validity: `openssl x509 -enddate -noout -in <cert.crt>`<br>3. Rotate credentials via `kubeadm certs renew` or cert-manager. |
| `cert-manager` Certificate stuck in `Ready: False` | Issuer failure (Auth error to Vault, failed ACME challenge, or invalid RBAC). | Run `kubectl describe certificate <name>` followed by `kubectl describe certificaterequest <name-csr>` and check `.status.conditions`. |

### 5.2 Deep-Dive Diagnostic Scenarios

#### Scenario A: Webhook Call Failure (`x509: certificate signed by unknown authority`)
**Context:** An admission webhook (`ValidatingWebhookConfiguration`) blocks pod deployments due to a TLS handshake failure between `kube-apiserver` and the webhook endpoint.

1. **Query API Server Logs:**
```bash
$ kubectl logs -n kube-system kube-apiserver-master-01 --tail=100 | grep -i "webhook"
```
```text
E0807 20:24:20.104512 1 dispatcher.go:205] Failed calling webhook "validate.security.domain": Post "https://webhook-service.monitoring.svc:443/validate": x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "custom-ca")
```

2. **Inspect the `caBundle` field of the Webhook Configuration:**
```bash
$ kubectl get validatingwebhookconfiguration security-webhook-config -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 --decode | openssl x509 -text -noout | grep -E "Subject:|Issuer:"
```
```text
        Issuer: CN = old-cluster-ca
        Subject: CN = old-cluster-ca
```

3. **Resolution:** Update the `caBundle` in the `ValidatingWebhookConfiguration` with the active Base64-encoded root/intermediate CA certificate matching the webhook service server cert.

#### Scenario B: cert-manager Certificate Issuance Blocked
**Context:** A critical ingress TLS secret is not updating.

1. **Trace the cert-manager Resource Hierarchy:**
```bash
$ kubectl get certificate -n ingress-gateways
```
```text
NAME               READY   SECRET             AGE
api-gateway-tls    False   api-gateway-tls    15m
```

2. **Inspect the Underlying CertificateRequest:**
```bash
$ kubectl get certificaterequest -n ingress-gateways
```
```text
NAME                    APPROVED   DENIED   READY   ISSUER             REQUESTOR                               AGE
api-gateway-tls-12345   True       False    False   vault-pki-issuer   cert-manager-cert-manager-controller   14m
```

3. **Check Detailed Event Logs on Order/CertificateRequest:**
```bash
$ kubectl describe certificaterequest api-gateway-tls-12345 -n ingress-gateways
```
```text
Status:
  Conditions:
    Type:   Ready
    Status: False
    Reason: VaultError
    Message: Failed to sign certificate: Vault request failed: Error making API request.
             URL: POST https://vault.internal.infrastructure.net:8200/v1/pki_k8s/sign/production-intermediate
             Code: 403. Errors: * permission denied
```

4. **Resolution:** Fix HashiCorp Vault RBAC settings: The Kubernetes ServiceAccount role `cert-manager-pki-signer` lacks authorization policies to write to `pki_k8s/sign/production-intermediate`. Update the Vault ACL policy to include `capabilities = ["update"]` for that path.

---

## 6. References

* **Kubernetes PKI Certificates & Requirements Documentation**:  
  https://kubernetes.io/docs/setup/best-practices/certificates/
* **Kubernetes Certificate Signing Requests (`certificates.k8s.io`) Reference**:  
  https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
* **CNCF KCSA Official Curriculum Repository**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **cert-manager Vault Issuer Configuration Guide**:  
  https://cert-manager.io/docs/configuration/vault/
* **RFC 5280: Internet X.509 Public Key Infrastructure Certificate Profile**:  
  https://datatracker.ietf.org/doc/html/rfc5280