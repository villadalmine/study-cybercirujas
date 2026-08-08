# CNCF KCSA Study Guide: Topic 5.5 - Public Key Infrastructure (PKI)

**Exam Domain:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Topic:** 5.5 Public Key Infrastructure (PKI)  
**Weight:** 2.29%  

---

## Official Reference Sources

- [CNCF KCSA Curriculum (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Documentation: PKI Certificates and Requirements](https://kubernetes.io/docs/setup/best-practices/certificates/)
- [Kubernetes Documentation: Certificate Signing Requests (CSR)](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
- [Kubernetes Documentation: Managing TLS Certificates in a Cluster](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/)
- [cert-manager Architecture & Concepts](https://cert-manager.io/docs/concepts/)

---

## Deep Technical Architecture & Mechanics

Kubernetes relies heavily on X.509 Public Key Infrastructure (PKI) for Mutual TLS (mTLS) authentication across all control plane components, worker nodes, user clients, and extension API servers.

```
                         +-----------------------------------+
                         |    Kubernetes Root CA             |
                         |    (/etc/kubernetes/pki/ca.crt)   |
                         +-----------------+-----------------+
                                           |
       +-----------------------+-----------+-----------+-----------------------+
       |                       |                       |                       |
+------v------+         +------v------+         +------v------+         +------v------+
| kube-apiserver|       | kubelet     |         | admin.conf  |         | controller  |
| Server Cert |         | Client Cert |         | Client Cert |         | manager Cert|
+-------------+         +-------------+         +-------------+         +-------------+

                         +-----------------------------------+
                         |    etcd Root CA                   |
                         |    (/etc/kubernetes/pki/etcd/ca)|
                         +-----------------+-----------------+
                                           |
                       +-------------------+-------------------+
                       |                                       |
                +------v------+                         +------v------+
                | etcd Server |                         | apiserver   |
                | Peer Certs  |                         | etcd-client |
                +-------------+                         +-------------+

                         +-----------------------------------+
                         |    Front-Proxy Root CA            |
                         |    (/etc/kubernetes/pki/front-proxy)|
                         +-----------------+-----------------+
                                           |
                                    +------v------+
                                    | Front Proxy |
                                    | Client Cert |
                                    +-------------+
```

### 1. Distinct Certificate Authority (CA) Boundaries
A secure production Kubernetes cluster isolates CA trust domains to prevent cross-component impersonation:
* **Kubernetes Root CA (`ca.crt` / `ca.key`)**: Signs certificates for `kube-apiserver`, `kubelet` clients/servers, `kube-controller-manager`, `kube-scheduler`, and administrative user access.
* **etcd Root CA (`etcd/ca.crt` / `etcd/ca.key`)**: Isolates etcd cluster mTLS communications (peer-to-peer and client-to-server). Prevents compromised control plane components from directly querying storage unless presented with an explicitly signed etcd client certificate.
* **Front-Proxy Root CA (`front-proxy-ca.crt` / `front-proxy-ca.key`)**: Authenticates proxy requests when using API Aggregation (`extension-apiserver-authentication`), such as Metrics Server or Custom Resource Aggregators.
* **Service Account Key Pair (`sa.pub` / `sa.key`)**: Not an X.509 CA, but an RSA/ECDSA keypair used strictly for signing and verifying Service Account JSON Web Tokens (JWTs) via the `--service-account-issuer` and `--service-account-key-file` flags.

### 2. X.509 Field Mappings in Kubernetes Authentication
* **Common Name (`CN`)**: Interpreted by `kube-apiserver` as the **User identity**. (e.g., `CN=system:node:worker-01` or `CN=jane-admin`).
* **Organization (`O`)**: Interpreted as the **Group membership**. (e.g., `O=system:nodes` or `O=system:masters`).
  > **SECURITY WARNING:** The group `system:masters` is hardcoded in `kube-apiserver` source code to bypass RBAC evaluation completely (`cluster-admin` equivalence). Any certificate with `O=system:masters` grants absolute superuser power regardless of active RBAC `ClusterRoleBindings`.
* **Subject Alternative Names (SANs)**: Defines valid IP addresses and DNS domain names for server certificates. If an API request connects to an IP or hostname not present in the certificate's SAN extension, TLS negotiation fails with `x509: certificate relies on legacy CommonName field` or `x509: certificate is valid for X, not Y`.

---

## Guided Practical Exercises

---

### Exercise 1: Control Plane PKI Deep Inspection and Security Audit

#### Objective
Audit the active certificate bundle on a control plane node using standard OpenSSL utilities and `kubeadm`. Identify security risks regarding certificate expiration, SAN coverage, and privilege escalation vectors in the X.509 Subject fields.

#### Execution Steps

1. Execute `kubeadm` to inspect the expiration status of all managed control plane certificates:
   ```bash
   sudo kubeadm certs check-expiration
   ```
   *Expected Output:*
   ```text
   CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
   admin.conf                 Aug 07, 2027 18:30 UTC   364d            ca                      no
   apiserver                  Aug 07, 2027 18:30 UTC   364d            ca                      no
   apiserver-etcd-client      Aug 07, 2027 18:30 UTC   364d            etcd-ca                 no
   apiserver-kubelet-client   Aug 07, 2027 18:30 UTC   364d            ca                      no
   front-proxy-client         Aug 07, 2027 18:30 UTC   364d            front-proxy-ca          no
   healthcheck-etcd-client    Aug 07, 2027 18:30 UTC   364d            etcd-ca                 no
   apiserver-etcd-client      Aug 07, 2027 18:30 UTC   364d            etcd-ca                 no
   
   CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
   ca                      Aug 05, 2036 18:30 UTC   9y              no
   etcd-ca                 Aug 05, 2036 18:30 UTC   9y              no
   front-proxy-ca          Aug 05, 2036 18:30 UTC   9y              no
   ```

2. Inspect the X.509 Subject fields and SAN extensions of the main API Server certificate (`apiserver.crt`):
   ```bash
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A 2 "Subject:"
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A 1 "Subject Alternative Name"
   ```
   *Expected Output:*
   ```text
        Subject: CN = kube-apiserver
   --
            X509v3 Subject Alternative Name: 
                DNS:control-plane-01, DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:192.168.1.50
   ```

3. Extract the Subject line from `admin.conf` client certificate to detect superuser group bindings:
   ```bash
   kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -text -noout | grep "Subject:"
   ```
   *Expected Output:*
   ```text
        Subject: O = system:masters, CN = kubernetes-admin
   ```

#### Verification Questions (Exercise 1)
1. **Question 1.1:** Why does the `apiserver.crt` certificate explicitly include both `IP Address:10.96.0.1` and `DNS:kubernetes.default.svc.cluster.local` in its Subject Alternative Names (SANs)?
2. **Question 1.2:** If an attacker extracts `/etc/kubernetes/pki/ca.key`, how can they bypass all RBAC policies configured in the cluster?

---

### Exercise 2: Manual CertificateSigningRequest (CSR) Lifecycle & RBAC Privilege Escalation Vulnerability

#### Objective
Generate a private key and PKCS#10 Certificate Signing Request manually, submit it to the Kubernetes `certificates.k8s.io` API, evaluate signer validation policies, and execute approval workflows via `kubectl`.

#### Execution Steps

1. Create a dedicated directory and generate a 2048-bit RSA Private Key and a CSR requesting membership in the developer group:
   ```bash
   mkdir -p /tmp/pki-lab && cd /tmp/pki-lab
   openssl req -new -newkey rsa:2048 -nodes \
     -keyout dev-user.key \
     -out dev-user.csr \
     -subj "/CN=security-auditor/O=dev-team"
   ```

2. Base64 encode the CSR content without line breaks:
   ```bash
   CSR_BASE64=$(cat dev-user.csr | base64 | tr -d '\n')
   ```

3. Apply the full, syntactically valid Kubernetes `CertificateSigningRequest` manifest:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: security-auditor-csr
   spec:
     request: ${CSR_BASE64}
     signerName: kubernetes.io/kube-apiserver-client
     expirationSeconds: 86400
     usages:
     - client auth
     - digital signature
     - key encipherment
   EOF
   ```
   *Expected Output:*
   ```text
   certificatesigningrequest.certificates.k8s.io/security-auditor-csr created
   ```

4. List and inspect the state of the newly created CSR:
   ```bash
   kubectl get csr security-auditor-csr
   ```
   *Expected Output:*
   ```text
   NAME                   AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
   security-auditor-csr   5s    kubernetes.io/kube-apiserver-client   kubernetes-admin   24h                 Pending
   ```

5. Approve the Certificate Signing Request using administrative credentials:
   ```bash
   kubectl certificate approve security-auditor-csr
   ```
   *Expected Output:*
   ```text
   certificatesigningrequest.certificates.k8s.io/security-auditor-csr approved
   ```

6. Fetch the issued X.509 certificate from the status field of the CSR object and verify its Subject attributes:
   ```bash
   kubectl get csr security-auditor-csr -o jsonpath='{.status.certificate}' | base64 -d | openssl x509 -text -noout | grep -E "Subject:|Issuer:"
   ```
   *Expected Output:*
   ```text
        Issuer: CN = kubernetes
        Subject: CN = security-auditor, O = dev-team
   ```

#### Verification Questions (Exercise 2)
1. **Question 2.1:** What happens if a user submits a CSR with `signerName: kubernetes.io/kube-apiserver-client` where the Subject contains `O=system:masters`? Does Kubernetes automatically block this CSR?
2. **Question 2.2:** What API permissions are required in RBAC to approve a CSR, and why is granting `update` on `certificatesigningrequests/approval` equivalent to full cluster administrator access?

---

### Exercise 3: Automated Ingress & Workload PKI using cert-manager and Internal CAs

#### Objective
Configure `cert-manager` using custom Custom Resource Definitions (CRDs), establish an in-cluster `ClusterIssuer` backed by a CA `Secret`, and issue automated, self-renewing mTLS certificates for production application workloads.

```
 +-------------------------------------------------------------------------+
 | cert-manager Namespace                                                  |
 |                                                                         |
 |  +--------------------+      +--------------------+                     |
 |  | secret/ca-key-pair | ---> | ClusterIssuer/ca-  |                     |
 |  | (tls.crt, tls.key) |      | issuer             |                     |
 |  +--------------------+      +---------+----------+                     |
 +----------------------------------------|--------------------------------+
                                          | Watches & Issues
 +----------------------------------------v--------------------------------+
 | Production Namespace (default)                                          |
 |                                                                         |
 |  +------------------------+      +------------------------------------+ |
 |  | Certificate/app-mtls-  | ---> | secret/app-mtls-tls                | |
 |  | cert                   |      | (tls.crt, tls.key, ca.crt)         | |
 |  +------------------------+      +------------------------------------+ |
 +-------------------------------------------------------------------------+
```

#### Execution Steps

1. Create a dedicated CA keypair inside the cluster to serve as an internal issuer for application mTLS:
   ```bash
   openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
     -keyout internal-ca.key \
     -out internal-ca.crt \
     -subj "/CN=Internal Workload CA/O=Enterprise Security"

   kubectl create secret tls internal-ca-secret \
     --cert=internal-ca.crt \
     --key=internal-ca.key \
     -n cert-manager
   ```
   *Expected Output:*
   ```text
   secret/internal-ca-secret created
   ```

2. Apply the production `ClusterIssuer` manifest referencing the newly created secret:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: internal-app-issuer
   spec:
     ca:
       secretName: internal-ca-secret
   EOF
   ```
   *Expected Output:*
   ```text
   clusterissuer.cert-manager.io/internal-app-issuer created
   ```

3. Declare a production `Certificate` resource to automate certificate provisioning with aggressive renewal triggers:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: payment-service-tls
     namespace: default
   spec:
     secretName: payment-service-tls-ingress
     duration: 2160h # 90 days
     renewBefore: 360h # 15 days before expiration
     subject:
       organizations:
         - Financial-Services
     commonName: payment-service.default.svc
     dnsNames:
       - payment-service
       - payment-service.default
       - payment-service.default.svc
       - payment-service.default.svc.cluster.local
     isCA: false
     privateKey:
       algorithm: ECDSA
       size: 256
     issuerRef:
       name: internal-app-issuer
       kind: ClusterIssuer
       group: cert-manager.io
   EOF
   ```
   *Expected Output:*
   ```text
   certificate.cert-manager.io/payment-service-tls created
   ```

4. Verify that cert-manager reconciled the request and populated the target TLS secret:
   ```bash
   kubectl get certificate payment-service-tls
   kubectl get secret payment-service-tls-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 1 "Signature Algorithm"
   ```
   *Expected Output:*
   ```text
   NAME                  READY   AGE
   payment-service-tls   True    10s

       Signature Algorithm: ecdsa-with-SHA256
           Public Key Algorithm: id-ecPublicKey
   ```

#### Verification Questions (Exercise 3)
1. **Question 3.1:** What is the technical difference between an `Issuer` and a `ClusterIssuer` in cert-manager architecture?
2. **Question 3.2:** Why is using ECDSA (e.g., `P-256`) preferred over traditional RSA 2048/4096 in high-throughput internal microservice mTLS environments?

---

### Exercise 4: Advanced Diagnostics of Certificate Failures and SAN Mismatches

#### Objective
Simulate, diagnose, and resolve a common production outage scenario: a service failing mTLS authentication due to missing SAN extensions and invalid Client CA trust configurations.

#### Execution Steps

1. Inspect a failing TLS handshake using `openssl s_client` against a TLS-enabled cluster service endpoint (or local mock wrapper):
   ```bash
   openssl s_client -connect 10.96.0.1:443 -servername unknown-host.default.svc /dev/null 2>&1 | grep -i -E "verify return|certificate verify failed|CN ="
   ```
   *Expected Output:*
   ```text
   depth=0 CN = kube-apiserver
   verify error:num=20:unable to get local issuer certificate
   verify return:1
   ```

2. Test verification explicitly by passing the cluster root CA:
   ```bash
   openssl s_client -connect 10.96.0.1:443 -CAfile /etc/kubernetes/pki/ca.crt -servername kubernetes.default.svc < /dev/null | grep -E "Verify return code"
   ```
   *Expected Output:*
   ```text
       Verify return code: 0 (ok)
   ```

3. Intentionally query using an IP or hostname absent from the SAN list to trigger a SAN mismatch error:
   ```bash
   openssl s_client -connect 10.96.0.1:443 -CAfile /etc/kubernetes/pki/ca.crt -servername invalid-apiserver-name.domain.com < /dev/null 2>&1 | grep -i "hostname"
   ```
   *Expected Output (or validation tool failure):*
   ```text
   curl: (60) SSL: certificate subject name 'kube-apiserver' does not match target host name 'invalid-apiserver-name.domain.com'
   ```

#### Verification Questions (Exercise 4)
1. **Question 4.1:** How do you update the `kube-apiserver` flags to add a new SAN (e.g., a load balancer DNS name) to the API Server certificate in a `kubeadm`-managed control plane?
2. **Question 4.2:** In a scenario where pod-to-pod communication fails with `x509: certificate signed by unknown authority`, what are the two primary root causes?

---

## Solutions & Architectural Explanations

<details>
<summary>Click to expand Solutions & Detailed Answers</summary>

### Exercise 1 Solutions

* **Question 1.1 Answer:**  
  The Kubernetes API server can be reached internally via the ClusterIP service (`10.96.0.1`), through internal DNS resolution (`kubernetes`, `kubernetes.default`, `kubernetes.default.svc.cluster.local`), and directly via the control plane node's physical/virtual IP address (`192.168.1.50`). X.509 TLS clients strictly validate that the host address used in the connection string matches at least one entry in the Subject Alternative Name (SAN) extension. If any of these DNS names or IP addresses were missing from the SAN extension, `kubectl` or internal cluster components connecting via that address would abort the TLS handshake with a certificate verification error.

* **Question 1.2 Answer:**  
  The `ca.key` file is the private key of the Kubernetes Root Certificate Authority. Anyone possessing this key can forge arbitrary X.509 client certificates. By setting the Subject field of a forged certificate to `O=system:masters, CN=attacker`, the bearer can present this certificate to the API server during an mTLS handshake. Because `kube-apiserver` trusts `ca.crt` and hardcodes `system:masters` to bypass all RBAC checks, the attacker gains immediate, unrevokable administrative access over the entire cluster. (Note: X.509 client certificates cannot be easily revoked in Kubernetes because `kube-apiserver` does not natively check CRLs or OCSP endpoints).

---

### Exercise 2 Solutions

* **Question 2.1 Answer:**  
  Kubernetes does **not** automatically block CSRs containing `O=system:masters` at the API schema level. However, the default built-in signer `kubernetes.io/kube-apiserver-client` implemented in `kube-controller-manager` enforces strict validation rules. If a CSR containing `O=system:masters` is approved, the built-in controller will refuse to sign it and will emit an event indicating that signing requests for `system:masters` is forbidden to prevent self-service privilege escalation.

* **Question 2.2 Answer:**  
  To approve a CSR, a user or ServiceAccount must have RBAC permissions to perform the `update` verb on the subresource `certificatesigningrequests/approval` for the specific `signerName` (e.g., `authorization.k8s.io/synthetic-authorization-reason` rules for `certificatesigningrequests/approval`).  
  Granting `update` on `certificatesigningrequests/approval` is functionally equivalent to full `cluster-admin` because an attacker with this permission can approve a custom CSR requesting arbitrary identities (such as node identities or custom groups with high privileges), obtain a signed client certificate from the API server, and escalate privileges.

---

### Exercise 3 Solutions

* **Question 3.1 Answer:**  
  * **`Issuer`**: A namespaced Custom Resource. It can only issue X.509 certificates to `Certificate` resources located within the exact same Kubernetes namespace.  
  * **`ClusterIssuer`**: A cluster-scoped Custom Resource. It can issue certificates to `Certificate` resources across **all** namespaces in the cluster. It is typically used for shared ingress controllers, cluster-wide internal CAs, or global ACME/Let's Encrypt configurations.

* **Question 3.2 Answer:**  
  ECDSA (Elliptic Curve Digital Signature Algorithm) keys (such as `P-256` or `P-384`) offer equivalent or superior cryptographic security compared to RSA 2048/4096 while using significantly smaller key sizes. This results in:
  1. **Lower CPU consumption**: Faster TLS handshakes during high-frequency mTLS connections between microservices.
  2. **Reduced Network Overhead**: Smaller X.509 certificate payload sizes transferred during handshake negotiations.
  3. **Lower Memory Footprint**: Less memory usage per active TLS connection context in proxies like Envoy, Linkerd, or NGINX.

---

### Exercise 4 Solutions

* **Question 4.1 Answer:**  
  To add a new SAN to a `kubeadm` control plane API server certificate:
  1. Modify `/etc/kubernetes/kubeadm-config.yaml` (or create a patch config) to append the IP/DNS to `apiServer.certSANs`:
     ```yaml
     apiServer:
       certSANs:
         - "10.96.0.1"
         - "lb.internal.example.com"
         - "192.168.1.100"
     ```
  2. Backup existing certificates:
     ```bash
     sudo mv /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.crt.bak
     sudo mv /etc/kubernetes/pki/apiserver.key /etc/kubernetes/pki/apiserver.key.bak
     ```
  3. Regenerate the API server certificate:
     ```bash
     sudo kubeadm certs generate-id --config /etc/kubernetes/kubeadm-config.yaml
     # Or: sudo kubeadm init phase certs apiserver --config /etc/kubernetes/kubeadm-config.yaml
     ```
  4. Restart the `kube-apiserver` static pod container:
     ```bash
     sudo crictl stop $(sudo crictl ps --name kube-apiserver -q)
     ```

* **Question 4.2 Answer:**  
  1. **Missing or Mismatched CA Bundle**: The client pod does not mount or trust the specific Root/Intermediate CA that signed the server's certificate (e.g., the application container image lacks the system CA trust bundle or `ca.crt` was not mounted via a ConfigMap/Secret).
  2. **Untrusted Self-Signed / Custom Issuer**: The server pod is presenting a certificate signed by an internal custom issuer (such as an internal cert-manager `Issuer`), but the client pod is validating against the default Kubernetes cluster CA (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`) instead of the custom application CA bundle.

</details>