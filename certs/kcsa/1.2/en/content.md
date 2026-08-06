# KCSA 1.2 — Cloud Provider and Infrastructure Security

**Domain:** Overview of Cloud Native Security · **Exam weight:** 2.33% · **Level:** Advanced (SRE / Platform Architect)

---

## 1. The architectural problem

In the 4Cs model (Cloud → Cluster → Container → Code), the **Cloud** layer is the only one whose compromise is unrecoverable from inside Kubernetes. Every Kubernetes control you will study later — RBAC, NetworkPolicy, Pod Security Standards, admission control — is enforced by processes that run *on* infrastructure you did not build and, in a managed cluster, cannot even see. If an attacker owns the node's IAM role, the etcd disk, or the VPC route table, none of those controls apply to them.

The production failure mode is not exotic. It is almost always the same three-step chain:

```
RCE / SSRF in an application pod
        ↓
reach the link-local metadata endpoint 169.254.169.254
        ↓
mint cloud credentials for the NODE's instance profile / service account
        ↓
that role can read S3/GCS, describe the whole VPC, and frequently
call eks:DescribeCluster + sts:AssumeRole on other roles
        ↓
cluster-admin, or lateral movement out of Kubernetes entirely
```

This is why "Cloud Provider and Infrastructure Security" is a distinct exam objective rather than an appendix to cluster hardening. Concretely, the platform architect owns five decisions at this layer:

| # | Decision | What it prevents | Failure if skipped |
|---|---|---|---|
| 1 | Metadata service posture (IMDSv2 + hop limit / metadata concealment) | Pod → node credential theft | One SSRF = cloud account compromise |
| 2 | Workload identity federation instead of node roles | Over-broad, long-lived credentials | Every pod inherits the node's IAM power |
| 3 | Control-plane network exposure (private endpoint, authorized networks) | Internet-facing `6443` and `2379` | Credential stuffing / etcd data theft |
| 4 | Encryption at rest with an external KMS (envelope encryption) | Secrets readable from an etcd snapshot or disk image | Backup theft = plaintext Secrets |
| 5 | Node image and boot integrity (minimal OS, Secure Boot, vTPM) | Persistent node-level implants | Rootkit survives reboots and patching |

Everything below is the mechanics of those five.

---

## 2. The shared responsibility model, stated precisely

"Shared responsibility" is a marketing phrase until you turn it into a boundary that names *specific* components. For Kubernetes the boundary moves depending on how you consume it.

| Component | Self-managed (kubeadm on IaaS) | Managed control plane (EKS / GKE Standard / AKS) | Fully managed nodes (GKE Autopilot, EKS Fargate) |
|---|---|---|---|
| Hypervisor / firmware | Provider | Provider | Provider |
| Physical + network fabric | Provider | Provider | Provider |
| etcd process, backups, encryption keys | **You** | Provider (you choose the KMS key) | Provider (you choose the KMS key) |
| `kube-apiserver` flags (`--audit-policy-file`, `--encryption-provider-config`) | **You** | Provider — exposed only as a narrow API surface | Provider |
| Control-plane patching | **You** | Provider (you choose the window/version) | Provider |
| Node OS + kernel CVEs | **You** | **You** (provider publishes images) | Provider |
| kubelet configuration | **You** | **You** (via launch template / node config) | Provider |
| CNI, CSI, ingress | **You** | **You** (unless using provider add-ons) | Partially provider |
| RBAC, NetworkPolicy, admission | **You** | **You** | **You** |
| Workload identity bindings | **You** | **You** | **You** |
| Container images and code | **You** | **You** | **You** |

**The trap for architects and for the exam:** on a managed control plane you cannot run `ps aux` on the API server, so you cannot verify a CIS control such as "`--anonymous-auth=false`" by reading the process line. You verify it through provider documentation, the provider's API, and *behavioural* probes (Section 10). A control you cannot observe is a control you are trusting, not enforcing — document that trust explicitly in your threat model.

---

## 3. The instance metadata service: the primary escalation path

### 3.1 Why `169.254.169.254` is dangerous

Every major cloud exposes an unauthenticated HTTP endpoint on the link-local address `169.254.169.254`. It is reachable from any process on the instance — including any container, because by default containers share the node's routing path to link-local space. It serves, among other things, **short-lived credentials for the instance's identity**.

| Provider | Endpoint | Required header | Credential path |
|---|---|---|---|
| AWS | `http://169.254.169.254/latest/meta-data/` | IMDSv2: `X-aws-ec2-metadata-token` | `/latest/meta-data/iam/security-credentials/<role>` |
| GCP | `http://metadata.google.internal/computeMetadata/v1/` | `Metadata-Flavor: Google` | `/instance/service-accounts/default/token` |
| Azure | `http://169.254.169.254/metadata/instance?api-version=2021-02-01` | `Metadata: true` | `/metadata/identity/oauth2/token?resource=...` |

GCP and Azure have always required a non-forwardable header, which incidentally defeats plain SSRF (a browser or naive HTTP client will not add it). **AWS IMDSv1 required no header at all** — a single `GET` from a vulnerable URL fetcher was enough. IMDSv2 fixes this by requiring a `PUT` to obtain a session token first, which most SSRF primitives cannot perform.

### 3.2 Demonstrating the attack, then the fix

On a cluster where the node group still allows IMDSv1 (`http_tokens = optional`):

```console
$ kubectl run imds-probe --rm -it --restart=Never \
    --image=curlimages/curl:8.8.0 -- sh
If you don't see a command prompt, try pressing enter.
/ $ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
eksctl-prod-euw1-nodegroup-ng-sys-NodeInstanceRole-1F8H2J3K4L5M6
/ $ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eksctl-prod-euw1-nodegroup-ng-sys-NodeInstanceRole-1F8H2J3K4L5M6
{
  "Code" : "Success",
  "LastUpdated" : "2026-08-06T09:12:44Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIA2XQ7EXAMPLE4KZ9",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjEJr//////////wEaCWV1LXdlc3QtMSJH...",
  "Expiration" : "2026-08-06T15:38:11Z"
}
```

Those credentials carry `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`, and — in most real clusters — whatever the platform team bolted on for the cluster-autoscaler, external-dns, or the EBS CSI driver. The CNI policy alone grants `ec2:CreateNetworkInterface`, `ec2:AttachNetworkInterface` and `ec2:ModifyNetworkInterfaceAttribute`, which is enough to move laterally inside the VPC.

**The fix has two independent parts, and you need both.**

`http_tokens = required` stops SSRF-style access. `http_put_response_hop_limit = 1` stops *pod* access: a pod in its own network namespace reaches link-local space via the host acting as a router, which decrements the IP TTL. With a hop limit of 1 the response never comes back.

```hcl
# terraform/eks-nodegroup.tf
data "aws_ssm_parameter" "bottlerocket_ami" {
  name = "/aws/service/bottlerocket/aws-k8s-1.31/x86_64/latest/image_id"
}

resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "prod-euw1-ng-sys-"
  image_id      = data.aws_ssm_parameter.bottlerocket_ami.value
  instance_type = "m6i.xlarge"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only — kills SSRF
    http_put_response_hop_limit = 1          # kills pod access (extra hop)
    instance_metadata_tags      = "disabled"
  }

  # Bottlerocket uses two volumes: xvda = immutable OS, xvdb = container data
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 4
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      throughput            = 250
      iops                  = 3000
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                        = "prod-euw1-ng-sys"
      "kubernetes.io/cluster/prod-euw1"           = "owned"
      "k8s.io/cluster-autoscaler/enabled"         = "true"
    }
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.prod.name
  node_group_name = "ng-sys"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids   # private subnets only

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 6
  }

  update_config { max_unavailable_percentage = 33 }

  labels = {
    "node-restriction.kubernetes.io/pool" = "system"
  }

  taint {
    key    = "dedicated"
    value  = "system"
    effect = "NO_SCHEDULE"
  }
}
```

Verification after the node group rolls:

```console
$ aws ec2 describe-instances \
    --filters "Name=tag:eks:nodegroup-name,Values=ng-sys" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Tokens:MetadataOptions.HttpTokens,Hops:MetadataOptions.HttpPutResponseHopLimit}' \
    --output table
-------------------------------------------------
|               DescribeInstances               |
+------+----------------------+-----------------+
| Hops |          Id          |     Tokens      |
+------+----------------------+-----------------+
|  1   |  i-0a4b8c1d2e3f4a5b6 |  required       |
|  1   |  i-0c7d9e2f3a4b5c6d7 |  required       |
|  1   |  i-0e1f2a3b4c5d6e7f8 |  required       |
+------+----------------------+-----------------+

$ kubectl run imds-probe --rm -it --restart=Never \
    --image=curlimages/curl:8.8.0 -- \
    sh -c 'curl -s --connect-timeout 4 -X PUT \
      "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"; echo "curl_exit=$?"'
curl_exit=28
pod "imds-probe" deleted
```

`curl_exit=28` is `CURLE_OPERATION_TIMEDOUT` — the pod cannot reach IMDS at all. That is the state you want.

> **Caveat you must know:** `hostNetwork: true` pods share the node's network namespace, so there is no extra hop and they *can* still reach IMDS. This is intentional (the AWS VPC CNI and kube-proxy need it) and it is exactly why hostNetwork must be gated by Pod Security Admission `restricted`/`baseline` and by admission policy.

### 3.3 GKE: metadata concealment via Workload Identity

GKE does not use a hop limit. Enabling Workload Identity on a node pool deploys the `gke-metadata-server` DaemonSet, which intercepts pod traffic to `169.254.169.254` and serves a *filtered* view: node-scoped attributes such as `kube-env` (which historically contained node bootstrap credentials) are refused, and token requests are answered only with the Google service account federated to that pod's Kubernetes ServiceAccount.

```console
$ gcloud container clusters create prod-euw1 \
    --region europe-west1 \
    --workload-pool=my-project-1234.svc.id.goog \
    --enable-private-nodes \
    --enable-private-endpoint \
    --master-ipv4-cidr 172.16.0.32/28 \
    --enable-master-authorized-networks \
    --master-authorized-networks 10.20.0.0/24 \
    --enable-shielded-nodes \
    --shielded-secure-boot \
    --shielded-integrity-monitoring \
    --image-type COS_CONTAINERD \
    --enable-network-policy \
    --metadata disable-legacy-endpoints=true \
    --release-channel regular

$ kubectl -n kube-system get ds gke-metadata-server
NAME                  DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
gke-metadata-server   3         3         3       3            3           6m14s

$ kubectl run md-probe --rm -it --restart=Never --image=curlimages/curl:8.8.0 -- \
    sh -c 'curl -s -w "\nhttp=%{http_code}\n" -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/instance/attributes/kube-env'
This metadata endpoint is concealed.
http=403
pod "md-probe" deleted
```

Without a Workload Identity binding, the token endpoint fails closed:

```console
/ $ curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
{"error":"unable to generate token","error_description":"Unable to generate access token; IAM returned 403 Forbidden: The caller does not have permission"}
```

### 3.4 Trade-offs of the available blocking mechanisms

| Mechanism | Layer | Blocks hostNetwork pods? | Survives node replacement? | Operational cost | Verdict |
|---|---|---|---|---|---|
| IMDSv2 `http_tokens=required` | Cloud API | No (not its job) | Yes (launch template) | Very low; some old SDKs break | **Mandatory baseline** |
| `http_put_response_hop_limit = 1` | IP TTL | No | Yes (launch template) | Low; breaks hostNetwork tooling that expects IMDS | **Mandatory on AWS** |
| GKE Workload Identity metadata server | Node agent | Yes (concealed for all pods on the pool) | Yes (node pool property) | Low | **Mandatory on GKE** |
| `NetworkPolicy` egress deny to `169.254.169.254/32` | CNI | Depends on CNI | Yes | Medium — needs a default-deny egress baseline | Defence in depth only |
| Node `iptables -I FORWARD -d 169.254.169.254 -j DROP` | Host firewall | No (hostNetwork uses `OUTPUT`) | **No** — lost on new nodes unless in user-data | High, fragile | Legacy fallback |
| `AWS_EC2_METADATA_DISABLED=true` env var | SDK client | No | n/a | n/a | **Not a security control** — attacker-controlled |

A NetworkPolicy version, for the defence-in-depth layer:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-except-metadata
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # DNS to CoreDNS only
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
    # Everything else on the internet, with link-local and RFC1918 carved out
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16     # all link-local: IMDS, EKS Pod Identity agent
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

> Note the `except` covers `169.254.0.0/16`, not just `.169.254`. AWS also serves EKS Pod Identity credentials on `169.254.170.23` and ECS task credentials on `169.254.170.2`; GCP publishes `metadata.google.internal` as `169.254.169.254`. If your workloads legitimately use EKS Pod Identity, you must re-allow `169.254.170.23/32` explicitly.

---

## 4. Workload identity: removing the node role from the blast radius

Even with IMDS locked down, the question remains: how does a pod that legitimately needs S3 get credentials? The wrong answers are (a) inherit the node role, (b) mount a static access key in a Secret. Both are long-lived and shared.

The right answer everywhere is the same primitive: **the cluster acts as an OIDC identity provider, the pod gets a short-lived projected ServiceAccount token, and the cloud IAM system exchanges that token for cloud credentials scoped to that specific KSA.**

```
ServiceAccountTokenVolumeProjection
  → JWT signed by the cluster's OIDC signing key
    (aud=sts.amazonaws.com, sub=system:serviceaccount:payments:ledger, exp=1h)
      → provider STS validates via the cluster's public JWKS
        → returns credentials for exactly one IAM role
```

| Feature | EKS IRSA | EKS Pod Identity | GKE Workload Identity | Azure Workload Identity |
|---|---|---|---|---|
| Mechanism | OIDC federation + `sts:AssumeRoleWithWebIdentity` | Agent DaemonSet on `169.254.170.23` | GKE metadata server + `iam.gke.io` | OIDC federation + MSAL |
| Per-cluster IdP setup | Yes — one OIDC provider per cluster | No | No (workload pool per project) | Yes — OIDC issuer per cluster |
| Trust policy scaling | Poor: role trust policy names each cluster's OIDC ARN | Good: association API, cluster-agnostic role | Good | Medium |
| Cross-account roles | Yes, awkward | Yes, native | n/a | n/a |
| Wiring | Pod annotation on the **ServiceAccount** | `aws eks create-pod-identity-association` | Annotation on KSA + IAM policy binding | Annotation + label on pod |
| SDK support | Universal (all modern AWS SDKs) | Requires recent SDK versions | Universal (ADC) | Requires Azure Identity SDK |
| Works on Fargate | Yes | No | n/a | n/a |
| Token lifetime | 1 h default, `expirationSeconds` tunable | ~15 min, auto-rotated | 1 h | 1 h |
| Choose when | Fargate, cross-account, older SDKs | New EC2-based clusters, many clusters share roles | Any GKE | Any AKS |

### 4.1 EKS IRSA, end to end

```console
$ aws eks describe-cluster --name prod-euw1 \
    --query 'cluster.identity.oidc.issuer' --output text
https://oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D

$ eksctl utils associate-iam-oidc-provider --cluster prod-euw1 --approve
2026-08-06 09:31:02 [ℹ]  will create IAM Open ID Connect provider for cluster "prod-euw1"
2026-08-06 09:31:03 [✔]  created IAM Open ID Connect provider for cluster "prod-euw1"
```

The IAM role's trust policy is the security boundary — note the `sub` condition, which is what pins the credential to one namespace *and* one ServiceAccount:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLedgerKSAOnly",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D:aud": "sts.amazonaws.com",
          "oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D:sub": "system:serviceaccount:payments:ledger"
        }
      }
    }
  ]
}
```

> **Critical review point:** using `StringLike` with `...:sub": "system:serviceaccount:*"` — a real and common mistake — lets *any* ServiceAccount in *any* namespace of that cluster assume the role. Always `StringEquals`, always fully qualified. Equally, omitting the `:aud` condition allows a token minted for a different audience to be replayed.

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger
  namespace: payments
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/prod-euw1-payments-ledger
    eks.amazonaws.com/sts-regional-endpoints: "true"
    eks.amazonaws.com/token-expiration: "3600"
automountServiceAccountToken: false      # opt in per pod, not per SA
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: payments
  labels:
    app.kubernetes.io/name: ledger
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: ledger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ledger
    spec:
      serviceAccountName: ledger
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: ledger
          image: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/ledger@sha256:5f4d3c2b1a0998877665544332211ffeeddccbbaa99887766554433221100ffee
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            privileged: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
      nodeSelector:
        kubernetes.io/os: linux
```

The `eks-pod-identity-webhook` mutates the pod at admission time. Confirm it landed:

```console
$ kubectl -n payments get pod -l app.kubernetes.io/name=ledger \
    -o jsonpath='{.items[0].spec.containers[0].env}' | jq
[
  {
    "name": "AWS_STS_REGIONAL_ENDPOINTS",
    "value": "regional"
  },
  {
    "name": "AWS_DEFAULT_REGION",
    "value": "eu-west-1"
  },
  {
    "name": "AWS_REGION",
    "value": "eu-west-1"
  },
  {
    "name": "AWS_ROLE_ARN",
    "value": "arn:aws:iam::123456789012:role/prod-euw1-payments-ledger"
  },
  {
    "name": "AWS_WEB_IDENTITY_TOKEN_FILE",
    "value": "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
  }
]

$ kubectl -n payments exec deploy/ledger -- \
    aws sts get-caller-identity
{
    "UserId": "AROA2XQ7EXAMPLE9J3K:botocore-session-1785312904",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/prod-euw1-payments-ledger/botocore-session-1785312904"
}
```

The assumed-role ARN — not the node instance role — is the proof the wiring works.

### 4.2 GKE Workload Identity

```console
$ gcloud iam service-accounts create ledger-gsa --project my-project-1234

$ gcloud projects add-iam-policy-binding my-project-1234 \
    --member "serviceAccount:ledger-gsa@my-project-1234.iam.gserviceaccount.com" \
    --role "roles/storage.objectViewer" \
    --condition='expression=resource.name.startsWith("projects/_/buckets/ledger-prod"),title=ledger-bucket-only'

$ gcloud iam service-accounts add-iam-policy-binding \
    ledger-gsa@my-project-1234.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:my-project-1234.svc.id.goog[payments/ledger]"
Updated IAM policy for serviceAccount [ledger-gsa@my-project-1234.iam.gserviceaccount.com].
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger
  namespace: payments
  annotations:
    iam.gke.io/gcp-service-account: ledger-gsa@my-project-1234.iam.gserviceaccount.com
```

```console
$ kubectl -n payments exec deploy/ledger -- \
    curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
ledger-gsa@my-project-1234.iam.gserviceaccount.com
```

### 4.3 Azure Workload Identity

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger
  namespace: payments
  annotations:
    azure.workload.identity/client-id: 3f9c1a2b-4d5e-6f70-8192-a3b4c5d6e7f8
    azure.workload.identity/tenant-id: 7a8b9c0d-1e2f-3a4b-5c6d-7e8f9a0b1c2d
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: payments
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: ledger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ledger
        azure.workload.identity/use: "true"   # REQUIRED: triggers the mutating webhook
    spec:
      serviceAccountName: ledger
      containers:
        - name: ledger
          image: myacr.azurecr.io/ledger@sha256:5f4d3c2b1a0998877665544332211ffeeddccbbaa99887766554433221100ffee
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

The federated credential is created on the Azure side and pins the same `sub`:

```console
$ az identity federated-credential create \
    --name ledger-federated \
    --identity-name ledger-mi \
    --resource-group rg-prod \
    --issuer "$(az aks show -g rg-prod -n prod-euw1 --query oidcIssuerProfile.issuerUrl -o tsv)" \
    --subject "system:serviceaccount:payments:ledger" \
    --audience api://AzureADTokenExchange
```

**In all three clouds the node role should be reduced to the bare minimum required to join the cluster and pull images.** Any node-role permission beyond that is a permission you have granted to every workload that reaches IMDS.

---

## 5. Control plane network exposure

### 5.1 The port inventory you are expected to know

| Component | Port | Protocol | Direction | Who must reach it |
|---|---|---|---|---|
| `kube-apiserver` | 6443 (443 on managed) | TCP/TLS | Inbound to CP | Admins, nodes, in-cluster clients |
| `etcd` client | 2379 | TCP/mTLS | CP-internal | API server only |
| `etcd` peer | 2380 | TCP/mTLS | CP-internal | Other etcd members only |
| `kube-scheduler` | 10259 | HTTPS | localhost | Metrics/health (10251 insecure port removed in v1.23) |
| `kube-controller-manager` | 10257 | HTTPS | localhost | Metrics/health (10252 removed in v1.23) |
| `kubelet` API | 10250 | HTTPS | Inbound to node | API server, metrics-server |
| `kubelet` read-only | 10255 | **HTTP, unauthenticated** | — | **Nobody. Must be 0.** |
| `kube-proxy` healthz | 10256 | HTTP | node-local | Load balancers |
| NodePort range | 30000–32767 | TCP/UDP | Inbound to node | Only if NodePort Services are used |

`etcd/2379` reachable from anywhere except the API server is a full cluster compromise: etcd has no RBAC and no per-key authorization. Whoever holds a valid client certificate reads and writes every object, including every Secret.

### 5.2 Private clusters: the three exposure models

| Model | Control-plane endpoint | Node egress | Admin access path | Trade-offs |
|---|---|---|---|---|
| Public endpoint, open | Internet, `0.0.0.0/0` | NAT gateway | Direct `kubectl` | Simplest. Auth is the *only* control. Brute-forceable, scannable. Do not use in production. |
| Public endpoint + authorized networks | Internet, CIDR-restricted | NAT gateway | `kubectl` from office/VPN CIDRs | Good balance. Breaks on dynamic CI runner IPs; requires an allow-list lifecycle. |
| Private endpoint only | VPC-internal only | NAT or fully private (VPC endpoints) | Bastion, VPN, or provider-managed proxy | Strongest. CI/CD must run inside the VPC; provider console features may degrade; break-glass is harder. |

```console
$ aws eks update-cluster-config --name prod-euw1 \
    --resources-vpc-config \
      endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs="203.0.113.0/24,198.51.100.7/32"
{
    "update": {
        "id": "b91f4e7a-2c3d-4e5f-6a7b-8c9d0e1f2a3b",
        "status": "InProgress",
        "type": "EndpointAccessUpdate",
        "params": [
            {"type": "EndpointPublicAccess",  "value": "true"},
            {"type": "EndpointPrivateAccess", "value": "true"},
            {"type": "PublicAccessCidrs",     "value": "[\"203.0.113.0/24\",\"198.51.100.7/32\"]"}
        ],
        "createdAt": "2026-08-06T10:02:11.442000+02:00"
    }
}

$ aws eks describe-cluster --name prod-euw1 \
    --query 'cluster.resourcesVpcConfig.{Pub:endpointPublicAccess,Priv:endpointPrivateAccess,Cidrs:publicAccessCidrs}'
{
    "Pub": true,
    "Priv": true,
    "Cidrs": [
        "198.51.100.7/32",
        "203.0.113.0/24"
    ]
}
```

Behavioural verification from outside the allow-list — this is the test that actually proves the control:

```console
$ curl -sk --connect-timeout 5 https://9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D.gr7.eu-west-1.eks.amazonaws.com/version
curl: (28) Failed to connect to 9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D.gr7.eu-west-1.eks.amazonaws.com port 443 after 5001 ms: Timeout was reached
```

And from an allowed address, confirm anonymous access is still refused:

```console
$ curl -sk https://9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D.gr7.eu-west-1.eks.amazonaws.com/api/v1/namespaces/kube-system/secrets | jq
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "secrets is forbidden: User \"system:anonymous\" cannot list resource \"secrets\" in API group \"\" in the namespace \"kube-system\"",
  "reason": "Forbidden",
  "details": {"kind": "secrets"},
  "code": 403
}
```

A `200` here would mean anonymous RBAC bindings exist — an immediate P1.

### 5.3 Node-level firewalling (self-managed clusters)

For a kubeadm cluster on IaaS, the security group / firewall rules are yours. Minimum viable set:

```hcl
resource "aws_security_group_rule" "cp_api_from_nodes" {
  security_group_id        = aws_security_group.control_plane.id
  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nodes.id
  description              = "kubelet/kube-proxy -> kube-apiserver"
}

resource "aws_security_group_rule" "etcd_peer" {
  security_group_id        = aws_security_group.control_plane.id
  type                     = "ingress"
  from_port                = 2379
  to_port                  = 2380
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id  # CP members only
  description              = "etcd client+peer, control plane only"
}

resource "aws_security_group_rule" "kubelet_from_cp" {
  security_group_id        = aws_security_group.nodes.id
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id
  description              = "kube-apiserver -> kubelet (exec, logs, port-forward)"
}
```

Note there is **no rule for 10255**. That port must simply not be listening.

---

## 6. Node infrastructure hardening

### 6.1 Choosing a node OS

| OS | Package manager | Shell on node | Root FS | Integrity | Update model | Best for |
|---|---|---|---|---|---|---|
| Amazon Linux 2023 | `dnf` | Yes | Read-write | — | AMI replacement or in-place | Compatibility with agents/DaemonSets |
| Bottlerocket | **None** | **No** (only via `admin` container) | **Read-only, dm-verity** | dm-verity + optional Secure Boot | Atomic A/B image swap, rollback | Highest-security EKS/ECS nodes |
| Container-Optimized OS (COS) | None | Limited | **Read-only** | Verified boot + integrity monitoring | Auto-upgrade with node pool | GKE default |
| Flatcar Container Linux | None | Yes | Read-only `/usr` | — | Atomic A/B | Self-managed, cloud-agnostic |
| Ubuntu (GKE/AKS/EKS variants) | `apt` | Yes | Read-write | — | In-place | Needs custom kernel modules, GPU drivers |
| Azure Linux (Mariner) | `tdnf` | Yes | Read-write | — | In-place | AKS-native, small surface |

Bottlerocket is the strongest default on AWS for one structural reason: the node has no shell, no package manager and no writable root, so the standard post-exploitation toolkit (`curl | sh`, install a persistence unit, drop a binary in `/usr/local/bin`) does not function. Administrative access requires deliberately enabling the `admin` host container, which is itself an auditable API call.

```console
$ kubectl get nodes -o custom-columns=\
NAME:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KUBELET:.status.nodeInfo.kubeletVersion
NAME                                        OS                          KERNEL           RUNTIME                  KUBELET
ip-10-40-12-31.eu-west-1.compute.internal   Bottlerocket OS 1.29.0      6.1.115          containerd://1.7.24+bottlerocket   v1.31.4-eks-2d5f260
ip-10-40-13-88.eu-west-1.compute.internal   Bottlerocket OS 1.29.0      6.1.115          containerd://1.7.24+bottlerocket   v1.31.4-eks-2d5f260
ip-10-40-14-19.eu-west-1.compute.internal   Bottlerocket OS 1.29.0      6.1.115          containerd://1.7.24+bottlerocket   v1.31.4-eks-2d5f260
```

### 6.2 Hardened kubelet configuration

The kubelet is infrastructure, not workload, and it is the single most attacked component on the node. A kubelet with `anonymous.enabled: true` and `authorization.mode: AlwaysAllow` gives anyone who reaches port 10250 the ability to `exec` into every container on that node — no Kubernetes RBAC involved.

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

authentication:
  anonymous:
    enabled: false                 # CIS 4.2.1
  webhook:
    enabled: true                  # delegate authn to the API server
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # CIS 4.2.3

authorization:
  mode: Webhook                    # CIS 4.2.2 — never AlwaysAllow
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s

readOnlyPort: 0                    # CIS 4.2.4 — disable 10255 entirely
protectKernelDefaults: true        # CIS 4.2.6 — refuse to start if sysctls are wrong
makeIPTablesUtilChains: true       # CIS 4.2.7
streamingConnectionIdleTimeout: 5m # CIS 4.2.5
eventRecordQPS: 5
seccompDefault: true               # RuntimeDefault seccomp for every pod

# Serving certificate: bootstrap + rotate, never a static self-signed cert
serverTLSBootstrap: true           # CIS 4.2.10 — CSR must be approved
rotateCertificates: true           # CIS 4.2.11 — client cert auto-rotation

tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256

clusterDNS:
  - 172.20.0.10
clusterDomain: cluster.local

# Resource isolation so a workload cannot starve the kubelet or the OS
systemReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 2Gi
kubeReserved:
  cpu: 200m
  memory: 1Gi
  ephemeral-storage: 2Gi
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"

cgroupDriver: systemd
containerLogMaxSize: 50Mi
containerLogMaxFiles: 3
```

`serverTLSBootstrap: true` means kubelet serving certificates come from a CSR that someone must approve. Left unapproved, `kubectl logs` and `kubectl top` fail:

```console
$ kubectl get csr
NAME        AGE   SIGNERNAME                                    REQUESTOR                                        REQUESTEDDURATION   CONDITION
csr-7k2pq   4m    kubernetes.io/kubelet-serving                 system:node:ip-10-40-12-31.eu-west-1.compute.internal   <none>        Pending
csr-9m4tv   4m    kubernetes.io/kubelet-serving                 system:node:ip-10-40-13-88.eu-west-1.compute.internal   <none>        Pending

$ kubectl top nodes
Error from server (ServiceUnavailable): the server is currently unable to handle the request (get nodes.metrics.k8s.io)
```

Kubernetes deliberately does not auto-approve `kubelet-serving` CSRs (the built-in signer cannot validate the requested IPs/DNS names). In production use `kubelet-csr-approver` or an equivalent controller with a hostname regex, never blanket approval.

### 6.3 Node authorization and the NodeRestriction plugin

Two server-side controls limit what a compromised kubelet can do:

- **Node authorizer** (`--authorization-mode=Node,RBAC`): a kubelet in group `system:nodes` may only read Secrets, ConfigMaps, PVs and PVCs that are referenced by pods **scheduled on its own node**.
- **NodeRestriction admission plugin** (`--enable-admission-plugins=NodeRestriction`): a kubelet may only modify its own `Node` object and only the `Pod` objects bound to it, and cannot self-assign labels in the `node-restriction.kubernetes.io/` prefix.

That second prefix is the point: if you schedule sensitive workloads with `nodeSelector: {node-restriction.kubernetes.io/pool: pci}`, a compromised kubelet on a general node cannot relabel itself to attract those pods. A plain `pool: pci` label offers no such protection.

```console
$ kubectl auth can-i --list \
    --as=system:node:ip-10-40-12-31.eu-west-1.compute.internal \
    --as-group=system:nodes | head -12
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/healthz]          []               [get]
                                                [/livez]            []               [get]
                                                [/readyz]           []               [get]
                                                [/version]          []               [get]
```

Note that the Node authorizer's per-node scoping does not appear in `can-i --list` — it is evaluated per-request against the actual pod-to-node graph.

### 6.4 Boot integrity and confidential computing

| Control | AWS | GCP | Azure | Threat addressed |
|---|---|---|---|---|
| Secure Boot | Nitro UEFI Secure Boot | Shielded VM `--shielded-secure-boot` | Trusted Launch | Unsigned bootloader/kernel/rootkit |
| vTPM / measured boot | NitroTPM | Shielded VM vTPM | vTPM | Detect boot-chain tampering |
| Integrity monitoring | — (via NitroTPM attestation) | `--shielded-integrity-monitoring` | Guest attestation | Alert on measurement drift |
| Memory encryption | AMD SEV-SNP / Nitro Enclaves | Confidential Nodes (SEV/SEV-SNP/TDX) | Confidential VMs | Hypervisor / host operator reading RAM |
| Disk encryption | EBS + KMS | PD + CMEK | Managed Disk + CMK | Stolen or snapshotted volumes |

Confidential computing is the control that moves the *cloud provider itself* out of your trust boundary. It costs a measurable performance premium and constrains instance-type choice, so reserve it for workloads with a regulatory or adversarial-host requirement; Secure Boot + vTPM + integrity monitoring is the sensible default everywhere else because it is effectively free.

---

## 7. Encryption at rest: etcd and envelope encryption

### 7.1 Why "Secrets are base64" matters at the infrastructure layer

A Kubernetes Secret is stored in etcd. By default it is stored **unencrypted** — base64 is an encoding, not a cipher. Anyone who obtains an etcd snapshot, a disk image, or a backup bucket object reads every Secret in the cluster in plaintext:

```console
# On a self-managed control-plane node, WITHOUT encryption at rest:
$ sudo ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/payments/db-creds | hexdump -C | head -6
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 61 79 6d 65 6e  74 73 2f 64 62 2d 63 72  |s/payments/db-cr|
00000020  65 64 73 0a 6b 38 73 00  0a 0c 0a 02 76 31 12 06  |eds.k8s.....v1..|
00000030  53 65 63 72 65 74 12 b8  01 0a 8e 01 0a 08 64 62  |Secret........db|
00000040  2d 63 72 65 64 73 12 00  1a 08 70 61 79 6d 65 6e  |-creds....paymen|
00000050  74 73 22 00 2a 24 39 62  31 34 63 32 65 30 2d ...  |ts".*$9b14c2e0-|
```

Notice the `k8s\x00` magic and the readable protobuf. With encryption enabled the same key yields `k8s:enc:kms:v2:aws-kms-primary:` followed by ciphertext.

### 7.2 EncryptionConfiguration — provider trade-offs

| Provider | Key location | Strength | Rotation | Notes |
|---|---|---|---|---|
| `identity` | — | **None** (plaintext) | n/a | The default. Must be *last* in the list to allow reading legacy data. |
| `secretbox` | On disk, in the config file | XSalsa20-Poly1305 | Manual, config edit + rewrite | Fast; key sits next to the data it protects. |
| `aescbc` | On disk | AES-CBC + PKCS#7 | Manual | **Legacy — vulnerable to padding-oracle style issues; not recommended for new clusters.** |
| `aesgcm` | On disk | AES-GCM | **Must rotate every ~200k writes** | Nonce-reuse risk if rotation is neglected; only for automated rotation setups. |
| `kms` v1 | External KMS | Envelope, DEK per resource | Rotate the KEK in the KMS | **Deprecated since v1.28.** Every write is a KMS call — expensive and a hard dependency. |
| `kms` v2 | External KMS | Envelope, DEK derived per write via KDF | Rotate the KEK; no key-count limits | **GA in v1.29. The correct choice.** Caches the KEK, ~1 KMS call per key rotation, health-checked. |

Full production configuration (`/etc/kubernetes/enc/encryption-config.yaml`, referenced by `kube-apiserver --encryption-provider-config=...`):

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  # Highest-value resources first, with the strongest provider
  - resources:
      - secrets
    providers:
      - kms:
          apiVersion: v2
          name: aws-kms-primary
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - secretbox:
          keys:
            - name: break-glass-2026-08
              secret: c2VjcmV0aXNzZWNyZXQxMjM0NTY3ODkwYWJjZGVmZ2g=
      - identity: {}

  # Tokens and bindings also carry credentials
  - resources:
      - serviceaccounts
      - configmaps
    providers:
      - kms:
          apiVersion: v2
          name: aws-kms-primary
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}

  # CRDs that store credentials (e.g. cert-manager, external-secrets)
  - resources:
      - certificaterequests.cert-manager.io
      - externalsecrets.external-secrets.io
    providers:
      - kms:
          apiVersion: v2
          name: aws-kms-primary
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}
```

**Rules that decide whether this works:**

1. **The first provider in a list encrypts; every listed provider can decrypt.** To *enable* encryption, put `kms` first and keep `identity` last. To *disable* it, put `identity` first — and only then rewrite the data.
2. Changing the config encrypts nothing that already exists. Objects are only re-encrypted when rewritten:
   ```console
   $ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   secret/db-creds replaced
   secret/tls-ingress replaced
   ...
   ```
3. Since v1.27 you can use wildcards (`*.` for a core-group wildcard, `*.*` for everything), but wildcards plus an explicit entry for the same resource is a config error and the API server will refuse to start.
4. Since v1.29, KMS v2 supports **automatic config reload** (`--encryption-provider-config-automatic-reload=true`) — but that flag makes all health checks collapse into a single `/healthz/kms-providers` endpoint.

Verify the ciphertext prefix:

```console
$ kubectl -n payments create secret generic canary --from-literal=probe=itworks
secret/canary created

$ sudo ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/payments/canary | hexdump -C | head -4
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 61 79 6d 65 6e  74 73 2f 63 61 6e 61 72  |s/payments/canar|
00000020  79 0a 6b 38 73 3a 65 6e  63 3a 6b 6d 73 3a 76 32  |y.k8s:enc:kms:v2|
00000030  3a 61 77 73 2d 6b 6d 73  2d 70 72 69 6d 61 72 79  |:aws-kms-primary|

$ kubectl get --raw='/healthz/kms-provider-0'
ok
```

`k8s:enc:kms:v2:aws-kms-primary` is the proof. If you still see `k8s\x00\n\x0c\n\x02v1`, the object predates the config change and needs the rewrite from step 2.

### 7.3 Managed clusters: the same control, a smaller surface

You do not edit `EncryptionConfiguration` on EKS/GKE/AKS. You supply a key:

```console
$ aws eks associate-encryption-config \
    --cluster-name prod-euw1 \
    --encryption-config '[{"provider":{"keyArn":"arn:aws:kms:eu-west-1:123456789012:key/8f7e6d5c-4b3a-2918-0765-4a3b2c1d0e9f"},"resources":["secrets"]}]'
{
    "update": {
        "id": "c8d9e0f1-a2b3-4c5d-6e7f-8a9b0c1d2e3f",
        "status": "InProgress",
        "type": "AssociateEncryptionConfig",
        "createdAt": "2026-08-06T10:44:07.913000+02:00"
    }
}
```

> **Irreversible.** On EKS, envelope encryption cannot be removed once associated, and deleting or disabling the KMS key permanently bricks the cluster's Secrets. Put a deletion-protection policy and a `kms:ScheduleKeyDeletion` deny on that key, and alert on `DisableKey`. The GKE equivalent is `--database-encryption-key`; on AKS, `--enable-encryption-at-host` plus KMS etcd encryption.

### 7.4 Node and volume encryption

Etcd encryption protects the control plane's data. Workload data on PersistentVolumes needs its own key:

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "250"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:eu-west-1:123456789012:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809
  csi.storage.k8s.io/fstype: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ledger-data
  namespace: payments
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3-encrypted
  resources:
    requests:
      storage: 50Gi
```

`WaitForFirstConsumer` is not only a scheduling optimisation — it prevents a volume being provisioned in an availability zone where no eligible (correctly tainted, correctly labelled) node exists, which in multi-tenant clusters is how workloads end up on the wrong node pool.

---

## 8. Infrastructure audit and telemetry

Kubernetes audit logging tells you what happened *in* the cluster. Cloud audit logging tells you what happened *to* it. You need both, and they must land somewhere the cluster's own identities cannot delete.

| Signal | Source | Answers |
|---|---|---|
| Kubernetes audit log | `kube-apiserver --audit-policy-file` / provider control-plane logging | "Who read that Secret? Who created that ClusterRoleBinding?" |
| CloudTrail / Cloud Audit Logs / Azure Activity Log | Cloud API | "Who changed the node group's IMDS settings? Who disabled the KMS key?" |
| VPC Flow Logs | Network | "Did a pod's node egress to an unexpected AS?" |
| GuardDuty EKS Protection / Container Threat Detection | Provider runtime detection | "Did a process read `/var/run/secrets/...` and then call IMDS?" |

A minimum audit policy that catches the credential-theft chain without drowning you in noise:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Never log the token review chatter or the health endpoints
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]
  - level: None
    nonResourceURLs:
      - /healthz*
      - /livez*
      - /readyz*
      - /version
      - /metrics

  # Secrets: metadata only — never write Secret bodies into the audit log
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # Privilege changes: full request AND response
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
      - group: ""
        resources: ["serviceaccounts"]

  # Node-level access: exec/attach/portforward are lateral-movement primitives
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "nodes/proxy"]

  # Workload mutations: request body, so we see hostNetwork/privileged/hostPath
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]

  # Everything else
  - level: Metadata
```

On managed clusters you enable the equivalent through the provider:

```console
$ aws eks update-cluster-config --name prod-euw1 \
    --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

`authenticator` is the EKS-specific one that logs IAM-to-Kubernetes identity mapping — the log you need when investigating "how did this IAM principal become `system:masters`?".

---

## 9. Verification and failure diagnosis

### 9.1 Baseline scan with kube-bench

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-node
  namespace: security
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      hostPID: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:v0.9.3
          args: ["node", "--benchmark", "eks-1.5.0", "--json"]
          securityContext:
            privileged: false
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
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
```

```console
$ kubectl -n security logs job/kube-bench-node | sed -n '1,24p'
[INFO] 3 Worker Node Security Configuration
[INFO] 3.1 Worker Node Configuration Files
[PASS] 3.1.1 Ensure that the kubeconfig file permissions are set to 644 or more restrictive
[PASS] 3.1.2 Ensure that the kubelet kubeconfig file ownership is set to root:root
[PASS] 3.1.3 Ensure that the kubelet configuration file has permissions set to 644
[PASS] 3.1.4 Ensure that the kubelet configuration file ownership is set to root:root
[INFO] 3.2 Kubelet
[PASS] 3.2.1 Ensure that the Anonymous Auth is Not Enabled
[PASS] 3.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow
[PASS] 3.2.3 Ensure that a Client CA File is Configured
[PASS] 3.2.4 Ensure that the --read-only-port is disabled
[PASS] 3.2.5 Ensure that the --streaming-connection-idle-timeout is not set to 0
[PASS] 3.2.6 Ensure that the --make-iptables-util-chains argument is set to true
[WARN] 3.2.7 Ensure that the --hostname-override argument is not set
[PASS] 3.2.8 Ensure that the eventRecordQPS argument is set to a level which ensures appropriate event capture
[PASS] 3.2.9 Ensure that the --rotate-certificates argument is not present or is set to true
[PASS] 3.2.10 Ensure that the RotateKubeletServerCertificate argument is set to true

== Summary node ==
16 checks PASS
0 checks FAIL
1 checks WARN
0 checks INFO
```

`kube-bench` reads config files and process arguments. On managed control planes the `master` checks are not applicable — run `node`, `policies` and `managedservices` and treat the control-plane items as provider-attested.

### 9.2 A verification checklist you can run in ten minutes

```console
# 1. Is IMDS reachable from a normal pod?  (expect timeout/403)
$ kubectl run imds --rm -it --restart=Never --image=curlimages/curl:8.8.0 -- \
    sh -c 'curl -s -m 4 -o /dev/null -w "%{http_code}\n" \
      http://169.254.169.254/latest/meta-data/ || echo BLOCKED'
BLOCKED

# 2. Is the kubelet read-only port open?  (expect connection refused)
$ kubectl debug node/ip-10-40-12-31.eu-west-1.compute.internal -it \
    --image=busybox:1.36 -- sh -c 'wget -q -T 3 -O- http://localhost:10255/pods'
wget: can't connect to remote host (127.0.0.1): Connection refused

# 3. Can an anonymous caller do anything?  (expect 403 / no)
$ kubectl auth can-i --list --as=system:anonymous 2>/dev/null | wc -l
5      # only selfsubject* and the health endpoints

# 4. Are Secrets encrypted at rest?
$ kubectl get --raw='/healthz/kms-provider-0'
ok

# 5. Which ServiceAccounts still automount tokens they do not need?
$ kubectl get sa -A -o json | jq -r '
    .items[] | select(.automountServiceAccountToken != false)
    | "\(.metadata.namespace)/\(.metadata.name)"' | head
default/default
kube-system/coredns
payments/ledger

# 6. Which pods run with hostNetwork (i.e. can still reach IMDS)?
$ kubectl get pods -A -o json | jq -r '
    .items[] | select(.spec.hostNetwork == true)
    | "\(.metadata.namespace)/\(.metadata.name)"'
kube-system/aws-node-4f8kq
kube-system/aws-node-9x2mv
kube-system/kube-proxy-b7n3l
kube-system/kube-proxy-c1q8w

# 7. Which pods mount the container runtime socket (full node takeover)?
$ kubectl get pods -A -o json | jq -r '
    .items[] as $p | $p.spec.volumes[]? | select(.hostPath.path
      | tostring | test("docker.sock|containerd.sock|crio.sock"))
    | "\($p.metadata.namespace)/\($p.metadata.name) -> \(.hostPath.path)"'
observability/node-agent-7k2pq -> /run/containerd/containerd.sock
```

Item 7 deserves emphasis: a pod with the containerd socket mounted can start a privileged container with the host root filesystem mounted, and is therefore *equivalent to root on the node* regardless of its own `securityContext`.

### 9.3 Failure-diagnosis table

| Symptom | Likely infrastructure cause | Diagnostic command | Fix |
|---|---|---|---|
| `Unable to locate credentials` in a pod using IRSA | Missing/typo'd `eks.amazonaws.com/role-arn` annotation, or `automountServiceAccountToken: false` | `kubectl get sa ledger -n payments -o yaml`; check for `AWS_WEB_IDENTITY_TOKEN_FILE` in the pod env | Fix annotation, then **delete the pod** — the webhook only mutates at creation |
| `AccessDenied ... not authorized to perform: sts:AssumeRoleWithWebIdentity` | Trust policy `sub` does not match `system:serviceaccount:<ns>:<sa>` | `aws iam get-role --role-name ... --query 'Role.AssumeRolePolicyDocument'` | Correct the `sub`/`aud` conditions; verify OIDC provider thumbprint |
| Pod worked before, now `credential not found` after node replacement | Application was silently using the **node role** via IMDS; hop limit is now 1 | Compare `aws sts get-caller-identity` before/after | Wire proper workload identity — do not revert the hop limit |
| `Unable to connect to the server: dial tcp ... i/o timeout` from CI | Private endpoint, or the runner's egress IP left the authorized-networks list | `aws eks describe-cluster --query 'cluster.resourcesVpcConfig'` | Run CI inside the VPC, or add the NAT gateway EIP to the allow-list |
| API server returns `500` on Secret reads after a KMS change | KMS plugin unhealthy, key disabled, or IAM lost `kms:Decrypt` | `kubectl get --raw='/healthz/kms-provider-0'`; API server logs for `failed to decrypt` | Re-enable the key / restore the grant; **never** delete the key |
| Secrets still plaintext in etcd after enabling encryption | Existing objects were never rewritten | `etcdctl get /registry/secrets/... \| hexdump -C` | `kubectl get secrets -A -o json \| kubectl replace -f -` |
| `kubectl logs` / `top` fail with `x509: cannot validate certificate` | `serverTLSBootstrap: true` with unapproved kubelet-serving CSRs | `kubectl get csr` | Approve via a CSR-approver controller with a hostname allow-list |
| Kubelet refuses to start after config change | `protectKernelDefaults: true` and node sysctls do not match | `journalctl -u kubelet -n 50` | Set the sysctls in the node image/user-data, not by relaxing the flag |
| Nodes stuck `NotReady`, `NetworkUnavailable` | CNI pod cannot reach IMDS/cloud API after tightening egress | `kubectl -n kube-system logs ds/aws-node` | CNI runs `hostNetwork` — re-check host-level firewall rules, not NetworkPolicy |
| A pod in namespace A reads Secrets belonging to namespace B | Node authorizer disabled (`--authorization-mode=RBAC` only) | Check API server flags / provider config | Enable `Node,RBAC` and `NodeRestriction` |

---

## 10. Exam-focused summary

- The **cloud layer is the base of the 4Cs**; a compromise there invalidates every control above it.
- **Shared responsibility shifts with the consumption model.** Managed control plane ⇒ the provider owns etcd and the API server flags; you still own kubelet config, node OS, RBAC and workload identity.
- **`169.254.169.254` is the canonical escalation path.** Mitigations: IMDSv2 (`http_tokens=required`) + `http_put_response_hop_limit=1` on AWS; Workload Identity metadata concealment on GKE; the mandatory `Metadata:`/`Metadata-Flavor:` headers on Azure/GCP.
- **Workload identity replaces node roles.** IRSA, EKS Pod Identity, GKE Workload Identity and Azure Workload Identity are all OIDC federation of a projected ServiceAccount token. Always pin the trust policy to a fully-qualified `system:serviceaccount:<ns>:<sa>` and to the correct audience.
- **Ports:** 6443 API, 2379/2380 etcd, 10250 kubelet, **10255 must be 0**, 10257/10259 controller-manager/scheduler, 30000–32767 NodePort.
- **Private endpoints and authorized networks** shrink the reachable attack surface; authentication alone is not a network control.
- **etcd is plaintext by default.** `EncryptionConfiguration` with a **KMS v2** provider (GA in v1.29) is the production answer; the first provider encrypts, `identity` goes last, and existing objects need an explicit rewrite.
- **Node OS choice is a security control.** Minimal, immutable, shell-less images (Bottlerocket, COS) remove most post-exploitation tooling. Secure Boot + vTPM + integrity monitoring should be the default; confidential computing when the host itself is untrusted.
- **Node authorizer + NodeRestriction** confine a compromised kubelet to its own node's objects and block self-labelling under `node-restriction.kubernetes.io/`.
- **Audit both planes.** Kubernetes audit logs plus cloud audit logs, shipped to a destination the cluster's own identities cannot modify.

---

## Referencias

**CNCF / exam**
- KCSA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- CNCF curriculum repository: https://github.com/cncf/curriculum
- KCSA certification page: https://training.linuxfoundation.org/certification/kubernetes-and-cloud-native-security-associate-kcsa/

**Kubernetes upstream**
- Cloud Native Security overview (4Cs): https://kubernetes.io/docs/concepts/security/cloud-native-security/
- Securing a cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Encrypting confidential data at rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Using a KMS provider for data encryption: https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Ports and protocols: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Using Node Authorization: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Admission controllers (NodeRestriction): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Kubelet configuration (v1beta1) reference: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubelet authentication/authorization: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- TLS bootstrapping: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/
- Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Service account token volume projection: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/

**AWS**
- Configuring the instance metadata service (IMDSv2): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- IAM roles for service accounts (IRSA): https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- EKS Pod Identity: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- EKS cluster endpoint access control: https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html
- EKS envelope encryption of Secrets: https://docs.aws.amazon.com/eks/latest/userguide/enable-kms.html
- EKS Best Practices Guide — Security: https://aws.github.io/aws-eks-best-practices/security/docs/
- Bottlerocket OS: https://bottlerocket.dev/en/os/

**Google Cloud**
- GKE Workload Identity Federation: https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
- Protecting cluster metadata: https://cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata
- Private clusters: https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept
- Shielded GKE Nodes: https://cloud.google.com/kubernetes-engine/docs/how-to/shielded-gke-nodes
- Confidential GKE Nodes: https://cloud.google.com/kubernetes-engine/docs/how-to/confidential-gke-nodes
- GKE hardening guide: https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster

**Microsoft Azure**
- Azure Instance Metadata Service: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service
- Azure Workload Identity for AKS: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
- AKS private clusters: https://learn.microsoft.com/en-us/azure/aks/private-clusters
- AKS security concepts: https://learn.microsoft.com/en-us/azure/aks/concepts-security
- KMS etcd encryption on AKS: https://learn.microsoft.com/en-us/azure/aks/use-kms-etcd-encryption

**Benchmarks and tooling**
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- kube-bench: https://github.com/aquasecurity/kube-bench
- kubelet-csr-approver: https://github.com/postfinance/kubelet-csr-approver
- NSA/CISA Kubernetes Hardening Guide: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- MITRE ATT&CK for Containers: https://attack.mitre.org/matrices/enterprise/containers/