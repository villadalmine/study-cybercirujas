# Cloud Provider and Infrastructure Security (KCSA — Topic 1.2)

> **Domain:** Overview of Cloud Native Security · **Exam weight:** 2.33
> **Format:** Guided, hands-on labs. Execute each numbered step, then answer the checkpoint questions before moving on. Consolidated answers are in the collapsible section at the end.

This topic sits in the **Cloud** and **Cluster** rings of the *4C* model (**C**loud → **C**luster → **C**ontainer → **C**ode). The guiding principle is defense-in-depth: each outer ring is the trust boundary for the ring inside it. A hardened Pod on a node whose cloud IAM role is over-privileged, or whose Instance Metadata Service is reachable from workloads, is not secure — the outer ring leaks.

Official references used throughout:
- CNCF KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Kubernetes — Overview of Cloud Native Security (4C) — https://kubernetes.io/docs/concepts/security/overview/
- Kubernetes — Securing a Cluster — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/

**Lab prerequisites:** a cluster you own (kubeadm on a VM, `kind`, or a throwaway EKS/GKE cluster), `kubectl` with cluster-admin, and — for Exercises 3 and 4 — SSH/root on a control-plane node. Never run the offensive steps against infrastructure you do not own.

---

## Exercise 1 — The Instance Metadata Service (IMDS) as a credential-theft vector

The single most common cloud-native infrastructure compromise is a Server-Side Request Forgery (SSRF) or a compromised Pod reaching the node's **link-local metadata endpoint** `169.254.169.254` and stealing the node's cloud IAM credentials. Those credentials often carry the node's *instance profile* — frequently far broader than any workload should have.

### Steps

1. Inspect what the metadata endpoint exposes from *inside* a workload. On AWS (IMDSv1, the insecure single-request mode):

   ```bash
   kubectl run imds-probe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/'
   ```

   Expected output — the name of the instance-profile role attached to the node:

   ```
   eks-node-instance-role
   ```

2. Now retrieve the actual credentials for that role:

   ```bash
   kubectl run imds-probe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eks-node-instance-role'
   ```

   Expected output (temporary STS credentials the attacker can now export and use):

   ```json
   {
     "Code": "Success",
     "AccessKeyId": "ASIA...EXAMPLE",
     "SecretAccessKey": "wJalr...EXAMPLE",
     "Token": "IQoJb3...EXAMPLE",
     "Expiration": "2026-08-06T18:44:12Z"
   }
   ```

3. Contrast with **IMDSv2**, which requires a session-oriented PUT to obtain a token before any GET, and enforces a TTL. A pure SSRF (which can usually only issue a GET) is defeated:

   ```bash
   # This fails on IMDSv2 — GET without a token is rejected with 401
   curl -s http://169.254.169.254/latest/meta-data/   # -> 401 Unauthorized

   # IMDSv2 flow: PUT to mint a token, then GET with the token header
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/
   ```

**Checkpoint**
- **Q1.** Why does an over-privileged *node* instance profile turn a single compromised Pod into a whole-account compromise?
- **Q2.** IMDSv2 requires a `PUT` before any `GET`. Why does that requirement neutralize most SSRF exploits but *not* a fully compromised Pod with shell access?

### Steps (mitigation)

4. On AWS, enforce IMDSv2 **and** set the response hop limit to `1`. Packets from a Pod cross an extra network hop (the node's bridge/veth), so a hop limit of 1 makes the metadata endpoint unreachable from Pod network namespaces while the node itself (hop 0) still works:

   ```bash
   aws ec2 modify-instance-metadata-options \
     --instance-id i-0abc123def456 \
     --http-tokens required \
     --http-put-response-hop-limit 1 \
     --http-endpoint enabled
   ```

5. Add a belt-and-suspenders `NetworkPolicy` that blocks egress to the link-local range from application namespaces. **This only takes effect with a policy-enforcing CNI (Calico, Cilium); the default `kubenet`/AWS-VPC-CNI without policy add-on will silently ignore it.**

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-imds-egress
     namespace: apps
   spec:
     podSelector: {}          # every Pod in the namespace
     policyTypes:
       - Egress
     egress:
       - to:
           - ipBlock:
               cidr: 0.0.0.0/0
               except:
                 - 169.254.169.254/32   # AWS/GCP/Azure IMDS
                 - 169.254.170.2/32     # AWS ECS task-metadata / IRSA agent
   ```

   Apply and verify the block:

   ```bash
   kubectl apply -f deny-imds-egress.yaml
   kubectl run imds-probe -n apps --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s --max-time 5 http://169.254.169.254/latest/meta-data/ || echo BLOCKED'
   ```

   Expected output once enforcement is active:

   ```
   BLOCKED
   ```

**Checkpoint**
- **Q3.** Why is a hop limit of `1` an infrastructure-layer control that works *even for a CNI that does not enforce NetworkPolicy*?
- **Q4.** The NetworkPolicy above uses `ipBlock` with an `except`. Name one reason this control alone is insufficient and must be paired with the cloud-side setting from step 4.

Reference — AWS IMDS hardening: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html · Kubernetes NetworkPolicy: https://kubernetes.io/docs/concepts/services-networking/network-policies/

---

## Exercise 2 — Workload Identity: give the Pod its own scoped cloud identity, not the node's

The correct fix for Exercise 1 is not only to block IMDS but to stop workloads from *needing* the node role at all. Federated workload identity (**IRSA** on EKS, **Workload Identity** on GKE, **Workload Identity Federation** on AKS) issues each ServiceAccount a short-lived, OIDC-signed projected token that the cloud IAM exchanges for narrowly-scoped credentials — no static keys, per-workload least privilege.

### Steps

1. Inspect the projected ServiceAccount token that Kubernetes already mounts. It is a signed JWT with an audience and an expiry — the raw material of workload identity federation:

   ```bash
   kubectl run tokdump --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'cat /var/run/secrets/kubernetes.io/serviceaccount/token' | \
     cut -d. -f2 | base64 -d 2>/dev/null
   ```

   Expected decoded claims (note the short `exp` and the audience):

   ```json
   {
     "aud": ["https://kubernetes.default.svc"],
     "exp": 1785000000,
     "iss": "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B",
     "kubernetes.io": { "namespace": "apps", "serviceaccount": { "name": "checkout" } },
     "sub": "system:serviceaccount:apps:checkout"
   }
   ```

2. Bind a ServiceAccount to a cloud role. On EKS, annotate the SA with the IAM role ARN; the mutating admission webhook then injects the correct token audience and `AWS_ROLE_ARN`/`AWS_WEB_IDENTITY_TOKEN_FILE` env vars:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: checkout
     namespace: apps
     annotations:
       eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/checkout-s3-readonly
   ```

3. The IAM role's **trust policy** is the boundary that pins the credential to exactly this SA — note the `sub` condition scoping it to `apps:checkout`, not the whole cluster:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::111122223333:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B:sub": "system:serviceaccount:apps:checkout",
           "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B:aud": "sts.amazonaws.com"
         }
       }
     }]
   }
   ```

4. Verify the Pod now assumes the *role*, not the node profile:

   ```bash
   kubectl run whoami -n apps --serviceaccount=checkout \
     --image=amazon/aws-cli --rm -it --restart=Never -- sts get-caller-identity
   ```

   Expected output — the assumed-role ARN, scoped to `checkout`:

   ```json
   {
     "UserId": "AROA...:botocore-session-1785000000",
     "Account": "111122223333",
     "Arn": "arn:aws:sts::111122223333:assumed-role/checkout-s3-readonly/botocore-session-1785000000"
   }
   ```

**Checkpoint**
- **Q5.** Workload Identity relies on the cluster acting as an **OIDC provider**. Which two token claims does the cloud IAM trust policy pin on, and why are *both* required to prevent a different SA from assuming the role?
- **Q6.** Why is a projected token with `exp` a few thousand seconds out materially safer than a long-lived cloud access key stored in a Kubernetes Secret?

Reference — IRSA: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html · GKE Workload Identity: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity

---

## Exercise 3 — Infrastructure at rest: encrypting etcd

etcd holds every Secret, ConfigMap, and object in the cluster. By default kube-apiserver writes Secrets to etcd **unencrypted** — anyone with a disk snapshot, an etcd backup, or filesystem access to a control-plane node reads them in cleartext. This exercise proves it, then fixes it.

### Steps

1. Create a Secret and read it straight out of etcd to prove it is plaintext (run on a control-plane node with the etcd client certs):

   ```bash
   kubectl create secret generic canary -n default --from-literal=password=Sup3rS3cret

   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/default/canary | hexdump -C | grep -a Sup3r
   ```

   Expected output — your secret value, in the clear:

   ```
   ...  53 75 70 33 72 53 33 63  72 65 74            |Sup3rS3cret|
   ```

2. Author an `EncryptionConfiguration`. Generate a 32-byte key first:

   ```bash
   head -c 32 /dev/urandom | base64
   # -> e.g. k7Gg...=  (use YOUR output below)
   ```

   ```yaml
   # /etc/kubernetes/enc/enc.yaml
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources:
         - secrets
       providers:
         - aescbc:                     # or aesgcm (faster, KMS-recommended)
             keys:
               - name: key1
                 secret: k7Gg...=      # your 32-byte base64 key
         - identity: {}                # fallback so existing plaintext still reads
   ```

   > **Order matters.** The *first* provider listed is used to **write**; all listed providers are tried in order to **read**. Placing `identity: {}` first would silently keep writing plaintext.

3. Wire it into the API server. On kubeadm, edit the static Pod manifest — kubelet restarts the API server automatically when the manifest changes:

   ```yaml
   # /etc/kubernetes/manifests/kube-apiserver.yaml (spec.containers[0])
   command:
     - kube-apiserver
     - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
   # ...plus a hostPath volume+mount for /etc/kubernetes/enc
   ```

4. Re-encrypt the object at rest — encryption is lazy; only *writes* are encrypted, so force a rewrite of every Secret:

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

5. Re-run the etcd read from step 1. Expected output now shows the encryption envelope prefix instead of the value:

   ```
   00000000  2f 72 65 67 ... 6b 38 73 3a 65 6e 63 3a 61 65 73  |...k8s:enc:aes|
   00000010  63 62 63 3a 76 31 3a 6b 65 79 31 3a ...           |cbc:v1:key1:..|
   ```

   `grep -a Sup3r` should now return nothing.

**Checkpoint**
- **Q7.** After step 3 but *before* step 4, are your existing Secrets protected on disk? Explain precisely what "encryption at rest is lazy" means for an operator doing a compliance audit.
- **Q8.** What is the operational risk of the `aescbc`/`aesgcm` provider with a locally-stored `secret:` key, and what does moving to a **KMS provider** (envelope encryption) change about the threat model?

Reference — Encrypting confidential data at rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/

---

## Exercise 4 — Node and control-plane surface: kubelet, ports, and CIS benchmarking

The kubelet is the node's most sensitive daemon: its API can exec into any Pod on the node. A misconfigured kubelet (anonymous auth on, `AlwaysAllow` authz, read-only port open) hands an attacker the node. This exercise audits and hardens that surface and then automates the audit with the CIS Benchmark.

### Steps

1. Probe the kubelet **read-only port** (`10255`, unauthenticated by design) and the authenticated API port (`10250`) from a Pod:

   ```bash
   # Read-only port — if this returns data, it is a finding
   kubectl run kprobe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -s --max-time 5 http://$NODE_IP:10255/pods | head -c 200'

   # Authenticated port with anonymous auth — should be 401/403 on a hardened node
   kubectl run kprobe --image=curlimages/curl --rm -it --restart=Never -- \
     sh -c 'curl -sk --max-time 5 https://$NODE_IP:10250/pods -o /dev/null -w "%{http_code}\n"'
   ```

   Expected output on a **hardened** node:

   ```
   # 10255: connection refused (port disabled)
   # 10250: 401
   ```

2. Inspect the running kubelet configuration and confirm the three critical settings:

   ```bash
   # On the node
   sudo cat /var/lib/kubelet/config.yaml | grep -E 'anonymous|authorization|readOnlyPort' -A2
   ```

   Hardened target values:

   ```yaml
   authentication:
     anonymous:
       enabled: false          # no unauthenticated API access
   authorization:
     mode: Webhook             # delegate authz to the API server (RBAC), never AlwaysAllow
   readOnlyPort: 0             # disable the unauthenticated 10255 port
   ```

3. Verify from the control plane that the API server itself does not accept anonymous requests to privileged paths:

   ```bash
   curl -sk https://<apiserver>:6443/api/v1/namespaces/kube-system/secrets \
     -o /dev/null -w "%{http_code}\n"
   ```

   Expected on a hardened API server (`--anonymous-auth=false` or RBAC-denied `system:anonymous`):

   ```
   403
   ```

4. Automate the whole node/control-plane audit with **kube-bench**, which maps checks directly to the CIS Kubernetes Benchmark:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
   kubectl logs -l app=kube-bench --tail=-1 | grep -E '\[FAIL\]|\[WARN\]' | head
   ```

   Example expected findings to remediate:

   ```
   [FAIL] 4.2.1 Ensure that the --anonymous-auth argument is set to false
   [FAIL] 4.2.4 Ensure that the --read-only-port argument is set to 0
   [WARN] 1.2.6 Ensure that the --kubelet-certificate-authority argument is set as appropriate
   ```

**Checkpoint**
- **Q9.** Explain the practical difference between the kubelet read-only port `10255` and the authenticated port `10250`, and why `readOnlyPort: 0` is a hard requirement rather than a nice-to-have.
- **Q10.** kube-bench reports against the CIS Benchmark. On a **managed** control plane (EKS/GKE/AKS), why do the `1.x` (control-plane/master) checks mostly not apply to you, and which check group *does* remain your responsibility? Tie this back to the shared-responsibility model.

Reference — Kubelet authn/authz: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/ · kube-bench / CIS: https://github.com/aquasecurity/kube-bench

---

## Answers

<details>
<summary><strong>Show answers (Q1–Q10)</strong></summary>

**Q1.** The node's instance profile is attached at the VM level and shared by *every* Pod scheduled there, because they all traverse the same host network namespace to reach `169.254.169.254`. Node roles are typically broad (pull from ECR, write CloudWatch logs, attach EBS volumes, describe/modify EC2, sometimes `iam:PassRole`). A single compromised Pod that reads those credentials inherits all of it — lateral movement, privilege escalation, and often the ability to reach unrelated cloud resources — so one Pod escape becomes an account-wide incident. The defense is least-privilege *per workload* (Exercise 2), not per node.

**Q2.** IMDSv2 makes credential retrieval a two-step, stateful flow: a `PUT /latest/api/token` (which also must carry the TTL header) to mint a session token, then a `GET` carrying `X-aws-ec2-metadata-token`. Classic SSRF primitives (a vulnerable URL fetcher, an image-processing library, a redirect) can usually only coerce a `GET` with attacker-controlled URL — they cannot issue the required `PUT` with custom headers, so the flow breaks. A **fully compromised Pod with shell access**, however, can run arbitrary `curl` and perform the full PUT→GET handshake; IMDSv2 does not stop it. That is why IMDSv2 must be combined with the hop-limit of 1 and/or a NetworkPolicy egress block, and ultimately with workload identity so the credentials are worthless.

**Q3.** The hop limit is applied by the metadata service to the IP TTL/hop count of its responses at the *infrastructure* layer — it is enforced by the cloud's virtualization/networking stack, not by Kubernetes or the CNI. A Pod's packets leave the Pod network namespace and cross an extra hop (veth → node bridge → host stack) before reaching the metadata endpoint, so replies limited to a single hop expire before returning to the Pod. The node's own processes (hop 0) are unaffected. Because it lives below Kubernetes, it works regardless of whether the CNI enforces NetworkPolicy — which is exactly why it is the more robust of the two controls.

**Q4.** NetworkPolicy egress is only enforced if the installed CNI implements policy (Calico, Cilium, etc.); with a non-enforcing CNI the object is accepted by the API server but silently does nothing — a dangerous false sense of security. It also only governs Pod-network traffic, can be undone by a namespace without the policy, and does not protect the node itself or `hostNetwork: true` Pods (which share the node's namespace and bypass Pod-level egress rules). The cloud-side hop-limit/IMDSv2 setting from step 4 is enforced beneath Kubernetes and covers those gaps, so the two together are defense-in-depth rather than a single point of failure.

**Q5.** The trust policy pins on the OIDC **`sub`** claim (`system:serviceaccount:<namespace>:<name>`) and the **`aud`** claim (`sts.amazonaws.com` for IRSA). `sub` scopes the assumable role to exactly one ServiceAccount in one namespace, so a different SA — even one that can also mint a projected token from the same cluster OIDC issuer — fails the `StringEquals` condition. `aud` ensures the token was minted *for STS specifically* (via the injected `--audience`) and not, say, the default `kubernetes.default.svc` API-server token being replayed at the cloud. Pinning only `sub` would let a token intended for another audience be reused; pinning only `aud` would let any SA in the cluster assume the role. Both together give per-workload least privilege.

**Q6.** A projected token is short-lived (kubelet auto-rotates it, `exp` typically ~1 hour or less), audience-bound, and never stored — it lives on a `tmpfs` mount and is exchanged on demand for equally short-lived STS credentials. A long-lived cloud access key in a Secret is static, valid until manually rotated, readable by anyone with `get secrets` RBAC (or an etcd snapshot if encryption at rest is off — see Exercise 3), and frequently leaks into logs, env dumps, or Git. If a projected token leaks it is useless within minutes and only for one audience; if a static key leaks it is a durable, high-value credential. Short-lived, narrowly-scoped, non-persisted credentials collapse the exploitation window.

**Q7.** No — existing Secrets are *not* protected immediately. Enabling `--encryption-provider-config` only causes the API server to encrypt on the next **write** of each object; anything already in etcd stays in whatever form it was last written (plaintext). "Encryption at rest is lazy" means you must actively force a rewrite of every affected resource (`kubectl get secrets -A -o json | kubectl replace -f -`) before you can claim they are encrypted. For a compliance audit this is critical: turning the feature on and seeing new Secrets encrypted does *not* prove the historical corpus is encrypted — you must verify by reading representative old objects directly out of etcd and confirming the `k8s:enc:...` envelope prefix.

**Q8.** With `aescbc`/`aesgcm` the data-encryption key sits in cleartext inside the `EncryptionConfiguration` file on the control-plane node's filesystem, right next to etcd. Anyone who can read that node (root, a control-plane compromise, an unprotected backup of `/etc/kubernetes`) obtains both the ciphertext and the key, so the encryption only defends against *stolen etcd data alone* (a lone disk snapshot or etcd backup), not a node compromise. A **KMS provider** implements envelope encryption: the API server encrypts each object with a data key, and that data key is itself wrapped by a key held in an external KMS/HSM that never touches the node. Now compromising the node's filesystem is insufficient — the attacker must also be authorized to call `Decrypt` on the KMS, which is separately logged and revocable. It moves the root of trust off the host and gives you auditable, rotatable key custody.

**Q9.** Port `10255` is the kubelet **read-only** HTTP port: no TLS, no authentication, no authorization. It exposes `/pods`, `/metrics`, `/spec`, and more — enough for an attacker to enumerate every Pod, container, node label, and often environment metadata on the node without any credential. Port `10250` is the kubelet's full HTTPS API and, when hardened, requires TLS client-cert or bearer-token authentication plus Webhook authorization delegated to the API server's RBAC; it is what legitimately serves `exec`, `logs`, and `attach`. Because `10255` gives unauthenticated reconnaissance (and historically leaked tokens/env), leaving it open is a standing information-disclosure and attack-planning vector with zero legitimate need in modern clusters — hence `readOnlyPort: 0` is mandatory, not optional. Metrics that used to justify it are served authenticated via `10250/metrics` instead.

**Q10.** kube-bench's `1.x` group audits master/control-plane component flags (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`) and their config files on disk. On a managed offering the provider operates the control plane — you have no access to those manifests or hosts — so the shared-responsibility model puts `1.x` (and the etcd/control-plane hardening) on the *provider's* side of the line; kube-bench will report them as not-applicable or skipped. What remains yours is the **`4.x` worker-node / kubelet** group (kubelet flags, file permissions, `readOnlyPort`, anonymous auth) plus the policy groups (`5.x` — RBAC, Pod Security, network policies), because you own the nodes and the workloads. This is the essence of shared responsibility: the provider secures the managed control plane; you secure the nodes, the workload configuration, and everything in the Container and Code rings.

</details>