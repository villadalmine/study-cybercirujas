# 1.1 The 4Cs of Cloud Native Security

**Certification:** KCSA — Kubernetes and Cloud Native Security Associate
**Domain:** Overview of Cloud Native Security
**Exam weight:** 2.33%

---

## 1. Motivation: the architectural problem this model solves

Every production incident post-mortem in a Kubernetes platform eventually collapses into the same question: **at which layer should this control have existed?** The 4Cs model exists because that question has a deterministic answer, and because engineering teams systematically answer it wrong — they attempt to compensate for a weak outer layer with a stronger inner one, which is architecturally impossible.

The canonical formulation from the upstream documentation is blunt:

> Each layer of the Cloud Native security model builds upon the next outermost layer. The Code layer benefits from strong base (Cloud, Cluster, Container) security layers. **You cannot safeguard against poor security standards in the base layers by addressing security at the Code level.**

### 1.1 The production failure this prevents

Consider a real, recurring kill chain that platform teams observe in managed Kubernetes on any hyperscaler. It is worth walking through in full, because it is the single most instructive example of why the layers are ordered the way they are.

```
[1] Code layer     A checkout microservice accepts a user-supplied `imageUrl`
                   and fetches it server-side to generate a thumbnail.
                   No allowlist. Classic SSRF (CWE-918).

[2] Container      The image is FROM ubuntu:22.04, runs as UID 0, has a
    layer          writable root filesystem, and ships curl, python3, bash
                   and the full apt toolchain. The attacker now has an
                   interactive foothold, not just a single HTTP GET.

[3] Cluster        The pod has no NetworkPolicy. Egress to the link-local
    layer          range 169.254.0.0/16 is permitted. The ServiceAccount
                   token is auto-mounted at
                   /var/run/secrets/kubernetes.io/serviceaccount/token.

[4] Cloud          The node's instance metadata service accepts unauthenticated
    layer          GET requests (IMDSv1). The node's instance role holds
                   ec2:*, s3:*, and — because someone wired the cluster
                   autoscaler onto the node role instead of a dedicated
                   identity — eks:DescribeCluster and sts:AssumeRole on a
                   role that maps to system:masters in aws-auth.
```

The attacker's actual command sequence is four lines:

```
$ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
eksctl-prod-nodegroup-ng-1-NodeInstanceRole-1QK3XZ

$ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eksctl-prod-nodegroup-ng-1-NodeInstanceRole-1QK3XZ
{
  "Code" : "Success",
  "LastUpdated" : "2026-08-06T09:14:22Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIA4EXAMPLEKEY0001",
  "SecretAccessKey" : "wJalr...EXAMPLE...KEY",
  "Token" : "IQoJb3JpZ2luX2VjE...",
  "Expiration" : "2026-08-06T15:14:22Z"
}
```

Cluster-admin follows within minutes. **The bug was at the Code layer. The breach was at the Cloud layer.** Every intermediate layer had exactly one control that would have terminated the chain, and none of them were configured. This asymmetry — one bug, four missed controls — is the entire thesis of the 4Cs.

### 1.2 What the model actually asserts

The 4Cs is not a checklist. It is three architectural claims:

1. **Containment is directional.** A compromise at layer *N* grants, at minimum, all the privileges available to layer *N+1* (inner). It does not automatically grant layer *N−1* (outer) privileges — *unless* the outer layer is misconfigured to hand them over. The security value of the model is entirely in the strength of those outward transitions.
2. **Control placement is not free choice.** Some controls are only *expressible* at a given layer. You cannot prevent instance-credential theft from inside the application process; you can only prevent it at the node/cloud boundary. Attempting the control at the wrong layer produces a control that is bypassable by definition.
3. **Ownership follows layers, and ownership gaps are where breaches live.** The Cloud layer is typically owned by a cloud/network team, Cluster by platform engineering, Container by a build/supply-chain team, Code by product teams. The 4Cs is as much an RACI diagram as a security model.

### 1.3 Relationship to the CNCF Cloud Native Security Whitepaper

KCSA draws on two overlapping mental models, and the exam expects you to know both and how they relate:

| Model | Axis | Layers / phases | Primary use |
|---|---|---|---|
| **4Cs** (Kubernetes docs) | **Spatial** — nesting / blast radius | Cloud → Cluster → Container → Code | Where does a control belong? What is the containment boundary? |
| **CNCF Cloud Native Security Whitepaper v2** (TAG Security) | **Temporal** — software lifecycle | Develop → Distribute → Deploy → Runtime | When in the lifecycle is a control applied? Who owns the gate? |

They are orthogonal and compose into a matrix. A single control has coordinates in both:

| Control | 4C layer | Lifecycle phase |
|---|---|---|
| SAST on the checkout service | Code | Develop |
| Signing images with Sigstore/cosign | Container | Distribute |
| Kyverno rejecting unsigned images at admission | Cluster | Deploy |
| Falco alerting on `/etc/shadow` reads in a pod | Container | Runtime |
| IMDSv2 enforcement + hop limit 1 | Cloud | Deploy (infra) |
| etcd encryption-at-rest with an external KMS | Cluster | Runtime |

A mature platform has coverage in **every cell**. Gaps in a column mean a lifecycle stage is ungated; gaps in a row mean a containment boundary is porous.

---

## 2. The four layers: comparative anatomy

### 2.1 Master trade-off table

| | **Cloud / Datacenter** | **Cluster** | **Container** | **Code** |
|---|---|---|---|---|
| **Scope of compromise** | All clusters, all accounts, all data | Every workload + every Secret in the cluster | One pod, then lateral movement | One process, one request path |
| **Typical owner** | Cloud platform / netops | Platform engineering / SRE | Supply chain / build platform | Product engineering |
| **Primary trust boundary** | Account/project/tenant, VPC, IAM | API server authn/authz, etcd, kubelet | Kernel namespaces, cgroups, seccomp, LSM | Process memory, TLS session |
| **Enforcement mechanism** | IAM policy, SG/NSG, VPC routing, KMS, org guardrails | RBAC, admission control, NetworkPolicy, PSA, audit | securityContext, capabilities, seccomp/AppArmor, image provenance | Type systems, input validation, mTLS, dependency pinning |
| **Change velocity** | Weeks (change control) | Days | Hours (per build) | Minutes (per commit) |
| **Detectability of misconfig** | High — declarative IaC, drift-scannable | High — cluster is a queryable API | Medium — needs registry + admission introspection | Low — requires SAST/DAST/manual review |
| **Cost of a mistake** | Catastrophic, often silent for months | Cluster-wide, usually noisy in audit log | Contained if outer layers are sound | Contained if outer layers are sound |
| **Reversibility** | Low (credentials leak permanently) | Medium (rotate SA tokens, re-encrypt etcd) | High (rebuild, redeploy) | High (patch, redeploy) |
| **Can compensate for a weak inner layer?** | **Yes** — this is the whole point | Yes, for Container and Code | Yes, for Code | **No** |
| **Can compensate for a weak outer layer?** | — | **No** | **No** | **No** |

The last two rows are the load-bearing ones. Read them again: **compensation only flows inward.** A `readOnlyRootFilesystem: true` does not save you from an over-permissive node IAM role. A perfectly memory-safe Rust service does not save you from an unencrypted etcd.

### 2.2 Blast-radius arithmetic

Quantifying the layers makes prioritization non-negotiable in a planning meeting:

| Layer breached | Workloads exposed | Secrets exposed | Time to detect (median, well-instrumented) | Recovery |
|---|---|---|---|---|
| Cloud (account credentials) | All clusters × all namespaces | All, plus cloud-native secret stores | Days–months (CloudTrail volume) | Full credential rotation, forensic account review |
| Cluster (cluster-admin) | All namespaces in that cluster | Every Secret object in etcd | Minutes–hours (audit log) | Rebuild cluster; rotate every Secret; re-issue SA tokens |
| Container (single pod RCE) | 1 pod + whatever NetworkPolicy allows | Mounted Secrets + SA token | Seconds–minutes (Falco/eBPF) | Delete pod, patch image |
| Code (app-level bug) | 1 request path | Whatever the process holds in memory | Hours–days (WAF/APM anomalies) | Patch + redeploy |

Investment should be inversely proportional to detectability and directly proportional to blast radius — which is precisely why the outermost layer, despite being the least "Kubernetes-y", earns the largest security budget.

---

## 3. Layer 1 — Cloud (or Corporate Datacenter)

The Cloud layer is the substrate. Kubernetes has **no** ability to constrain it, because Kubernetes runs on it. Everything here is expressed in infrastructure-as-code, not in the Kubernetes API.

### 3.1 Non-negotiable controls

| Control | Failure it prevents | Kubernetes-side symptom if absent |
|---|---|---|
| IMDSv2 required + hop limit 1 | Pod → node credential theft (§1.1) | Nothing. The cluster looks perfectly healthy. |
| Workload identity (IRSA / GKE WI / Azure Workload Identity) | Sharing one node role across all pods | Every pod inherits the union of all workloads' permissions |
| Private API server endpoint / allowlisted CIDRs | Internet-facing control plane brute force / CVE exposure | `kubectl` works from a coffee shop, which is the tell |
| etcd disk encryption + KMS-backed envelope encryption | Snapshot/EBS exfiltration reveals all Secrets | Secrets readable in raw etcd pages |
| Node-to-node network segmentation | Cross-cluster lateral movement | Pods in cluster A reach kubelets in cluster B |
| Control-plane + node audit log shipping to an immutable sink | Attacker deletes evidence | Post-mortem with no timeline |
| SSH disabled on nodes; SSM/OS Login only | Persistent, unlogged node access | Unattributable node changes |

### 3.2 Complete infrastructure: enforcing IMDSv2 and killing the pod→node path

The following Terraform is the single highest-leverage change in the entire model. It is presented in full.

```hcl
# ---------------------------------------------------------------------------
# infra/eks/nodegroup.tf
# Hardened launch template for EKS managed node groups.
# Enforces IMDSv2 and sets the hop limit to 1, which makes the metadata
# endpoint unreachable from inside a pod network namespace (the packet
# traverses one extra hop, so the TTL expires before reaching the IMDS).
# ---------------------------------------------------------------------------

resource "aws_launch_template" "workers" {
  name_prefix   = "prod-workers-"
  image_id      = data.aws_ssm_parameter.eks_ami.value
  instance_type = "m6i.xlarge"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only. Rejects IMDSv1 GETs.
    http_put_response_hop_limit = 1          # Node-local only. Pods cannot reach it.
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.node_ebs.arn
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                    = "prod-worker"
      "kubernetes.io/cluster/prod"            = "owned"
      "k8s.io/cluster-autoscaler/enabled"     = "true"
    }
  }

  lifecycle { create_before_destroy = true }
}

# ---------------------------------------------------------------------------
# Node role: deliberately minimal. Anything a *workload* needs goes through
# IRSA, never through this role. This is the difference between "one pod is
# compromised" and "the account is compromised".
# ---------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "prod-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_minimal" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# Per-workload identity (IRSA). Scope is a single ServiceAccount in a single
# namespace, bound by the OIDC provider's `sub` claim. A different namespace
# cannot assume this role even with a valid projected token.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "checkout_service" {
  name = "prod-checkout-service"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "system:serviceaccount:payments:checkout"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "checkout_service" {
  role = aws_iam_role.checkout_service.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "${aws_s3_bucket.receipts.arn}/*"
    }]
  })
}

# ---------------------------------------------------------------------------
# Control plane: private endpoint, allowlisted public access, full audit logs,
# and envelope encryption of Secrets with a customer-managed KMS key.
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "prod" {
  name     = "prod"
  role_arn = aws_iam_role.cluster.arn
  version  = "1.33"

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["203.0.113.0/24"] # corporate egress only
  }

  encryption_config {
    provider { key_arn = aws_kms_key.eks_secrets.arn }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler",
  ]
}
```

The GCP equivalent of the hop-limit control is different in kind — GKE does not expose a hop limit, it exposes **Workload Identity**, which replaces the legacy metadata endpoint with a shielded one:

```yaml
# gcloud container clusters create --config=... (equivalent declarative form)
# The relevant flags, in full:
#
#   --workload-pool=PROJECT_ID.svc.id.goog        # enables Workload Identity
#   --workload-metadata=GKE_METADATA              # node pool level; blocks
#                                                 # legacy metadata endpoints
#   --enable-private-nodes
#   --enable-private-endpoint
#   --master-authorized-networks=203.0.113.0/24
#   --enable-shielded-nodes
#   --shielded-secure-boot
#   --shielded-integrity-monitoring
#   --database-encryption-key=projects/P/locations/L/keyRings/K/cryptoKeys/etcd
#   --enable-intranode-visibility
#   --no-enable-legacy-authorization
#   --no-enable-basic-auth
#   --no-issue-client-certificate
```

### 3.3 Verifying the Cloud layer from inside a pod

The only trustworthy verification is adversarial: run the attacker's command yourself.

```
$ kubectl run imds-probe --rm -it --restart=Never \
    --image=curlimages/curl:8.11.1 -- sh
If you don't see a command prompt, try pressing enter.

~ $ curl -s --max-time 5 http://169.254.169.254/latest/meta-data/
command terminated with exit code 28
~ $ curl -s --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 60"
command terminated with exit code 28
```

Exit code 28 is `CURLE_OPERATION_TIMEDOUT` — the TTL expired in transit. **This is the correct output.** Any JSON body is a finding, and it is a Sev-1.

Confirm the setting declaratively as well, because a single non-conforming node group defeats the control:

```
$ aws ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/prod,Values=owned" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Tokens:MetadataOptions.HttpTokens,Hop:MetadataOptions.HttpPutResponseHopLimit}' \
    --output table
------------------------------------------------------
|                  DescribeInstances                 |
+-----+----------------------+-----------+-----------+
| Hop |          Id          |  Tokens   |           |
+-----+----------------------+-----------+-----------+
|  1  |  i-0a1b2c3d4e5f60001 |  required |           |
|  1  |  i-0a1b2c3d4e5f60002 |  required |           |
|  2  |  i-0a1b2c3d4e5f60003 |  optional |  <-- FAIL |
+-----+----------------------+-----------+-----------+
```

Instance `...0003` predates the launch template rollout. It is a live path to account compromise until it is cycled.

---

## 4. Layer 2 — Cluster

The Cluster layer splits into two distinct problems that are frequently conflated:

1. **Securing the configurable cluster components** — API server, etcd, kubelet, controller-manager, scheduler, and the network plugin.
2. **Securing the workloads running in the cluster** — RBAC, admission control, network policy, resource limits, Secret handling.

### 4.1 Component-level: etcd encryption at rest

Without an `EncryptionConfiguration`, every Secret in the cluster is base64 in a file on the control-plane disk. Base64 is not encryption.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
# Mounted into kube-apiserver and referenced with:
#   --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
#   --encryption-provider-config-automatic-reload=true
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
      - tokenreviews.authentication.k8s.io
    providers:
      # Order matters. The FIRST provider is used for writes; ALL providers
      # are tried for reads. To rotate, prepend the new provider, then
      # rewrite every object with:  kubectl get secrets -A -o json | kubectl replace -f -
      - kms:
          apiVersion: v2
          name: vault-kms
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - aescbc:
          keys:
            - name: key-2026-08
              secret: c2VjcmV0LWlzLXNlY3VyZS1yb3RhdGUtbWUtcXVhcnRlcmx5
      - identity: {}   # MUST be last. If first, everything is written in plaintext.
```

> **Trap, and a favourite exam distractor:** `identity: {}` is the *no-encryption* provider. Placing it first silently disables encryption while the config file still "looks" secure. Placing it last is required so that pre-existing plaintext objects remain readable during migration.

Verification requires reading etcd directly — the API server will happily decrypt for you and hide the truth:

```
$ kubectl -n default create secret generic probe --from-literal=canary=hunter2
secret/probe created

$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/default/probe | hexdump -C | head -5
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 64 65 66 61 75 6c  74 2f 70 72 6f 62 65 0a  |s/default/probe.|
00000020  6b 38 73 3a 65 6e 63 3a  6b 6d 73 3a 76 32 3a 76  |k8s:enc:kms:v2:v|
00000030  61 75 6c 74 2d 6b 6d 73  3a 0a 24 34 61 31 66 39  |ault-kms:.$4a1f9|
00000040  62 32 63 2d 33 64 34 65  2d 35 66 36 61 2d 37 62  |b2c-3d4e-5f6a-7b|
```

The `k8s:enc:kms:v2:vault-kms:` prefix is the pass condition. If you instead see `k8s:enc:aescbc:v1:` you are on a local key (acceptable, weaker). If you see readable `hunter2`, encryption is off.

```
# The FAILING output, for recognition:
00000020  6b 38 73 00 0a 0c 0a 02  76 31 12 06 53 65 63 72  |k8s.....v1..Secr|
...
000000c0  63 61 6e 61 72 79 12 07  68 75 6e 74 65 72 32 1a  |canary..hunter2.|
```

### 4.2 Workload-level: Pod Security Admission

PSA is the built-in, non-configurable, non-extensible baseline. It is applied per namespace via labels and evaluates pods against the three Pod Security Standards.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    # Hard gate: reject anything not meeting `restricted`.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.33
    # Warn/audit on the SAME level so operators see identical signals; pin the
    # version so a cluster upgrade cannot silently tighten enforcement and
    # break a deploy at 03:00.
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.33
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.33
```

| Standard | `privileged` | `baseline` | `restricted` |
|---|---|---|---|
| hostNetwork / hostPID / hostIPC | allowed | denied | denied |
| Privileged containers | allowed | denied | denied |
| `allowPrivilegeEscalation` | any | any | must be `false` |
| Capabilities | any | drop-list of known-dangerous | must `drop: ["ALL"]`, may add only `NET_BIND_SERVICE` |
| `runAsNonRoot` | any | any | must be `true` |
| seccomp | any | `Unconfined` allowed | `RuntimeDefault` or `Localhost` |
| Volume types | all | restricted set | `configMap`, `secret`, `emptyDir`, `downwardAPI`, `projected`, `csi`, `ephemeral`, PVC |
| hostPath | allowed | denied | denied |
| Intended for | Infrastructure DaemonSets (CNI, CSI, node agents) | Legacy apps mid-migration | Everything else |

**PSA's structural limits**, and why every production cluster runs something in addition:

| Requirement | PSA | ValidatingAdmissionPolicy (CEL) | Kyverno | OPA Gatekeeper |
|---|---|---|---|---|
| Built into the API server | ✅ | ✅ (GA in 1.30) | ❌ webhook | ❌ webhook |
| Availability risk (webhook down = deploys blocked or bypassed) | none | none | real, needs HA + `failurePolicy` tuning | real, same |
| Enforce registry allowlist | ❌ | ✅ | ✅ | ✅ |
| Verify image signatures | ❌ | ❌ (no network calls in CEL) | ✅ | partial (external data) |
| Mutate resources (inject sidecars, defaults) | ❌ | ✅ (MutatingAdmissionPolicy, 1.32+ alpha/beta) | ✅ | ✅ (assign) |
| Generate resources (auto-create NetworkPolicy per ns) | ❌ | ❌ | ✅ | ❌ |
| Policy language | none (fixed) | CEL | YAML/JMESPath | Rego |
| Learning curve | trivial | moderate | low | high |
| **Recommended role** | **Always on, as the floor** | Cheap cluster-wide invariants | Supply chain + generation | Existing Rego investment |

The correct production posture is **PSA `restricted` as the floor, plus one policy engine for what PSA structurally cannot express.** They are not alternatives.

A CEL policy for a rule PSA cannot express — registry allowlisting — with no webhook and therefore no availability risk:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-registries
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allowed
      expression: "['registry.internal.example.com/', '123456789012.dkr.ecr.eu-west-1.amazonaws.com/']"
    - name: images
      expression: >-
        object.spec.containers.map(c, c.image) +
        (has(object.spec.initContainers) ? object.spec.initContainers.map(c, c.image) : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(c, c.image) : [])
  validations:
    - expression: "variables.images.all(i, variables.allowed.exists(p, i.startsWith(p)))"
      messageExpression: >-
        'images must come from an approved registry; got: ' + variables.images.join(', ')
      reason: Forbidden
    - expression: "variables.images.all(i, i.contains('@sha256:'))"
      message: "images must be pinned by digest, not by tag"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-registries-binding
spec:
  policyName: allowed-registries
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
```

Observed behaviour:

```
$ kubectl -n payments run rogue --image=docker.io/library/nginx:latest
error: failed to create pod: admission webhook denied the request:
ValidatingAdmissionPolicy 'allowed-registries' with binding
'allowed-registries-binding' denied request: images must come from an
approved registry; got: docker.io/library/nginx:latest
```

### 4.3 Workload-level: default-deny network policy

A cluster without NetworkPolicy is a flat L3 network in which every pod can reach every other pod, every kubelet on :10250, and the link-local metadata range. The following pair is the minimum viable baseline for every namespace.

```yaml
# 1) Deny everything, both directions. Applies to all pods in the namespace.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
# 2) Re-open only what is required. DNS is always required; forgetting it is
#    the #1 cause of "my policy broke everything" incidents.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
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
---
# 3) Application-specific: checkout may receive traffic only from the gateway,
#    and may egress only to the payments database and to the public internet
#    EXCEPT link-local, RFC1918 and the cluster CIDRs. This is the layer-2
#    control that would have broken the §1.1 kill chain even with IMDSv1.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
          podSelector:
            matchLabels:
              app.kubernetes.io/name: envoy-gateway
      ports:
        - protocol: TCP
          port: 8443
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: postgres
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16   # link-local: IMDS, kube-dns node-local cache
              - 10.0.0.0/8       # VPC + pod CIDR
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

> **Critical semantics, tested on the exam:** NetworkPolicy is *additive allow-list*. Rules from all policies selecting a pod are **unioned**; there is no deny rule and no ordering. `except` inside an `ipBlock` is the only subtractive construct, and it can only subtract from the CIDR in the same block. A pod selected by **no** policy is unrestricted; a pod selected by **any** policy is restricted to the union of matching rules.

---

## 5. Layer 3 — Container

### 5.1 Image provenance and content

```dockerfile
# ---------------------------------------------------------------------------
# Multi-stage build. The build stage carries the toolchain; the runtime stage
# carries only the binary and its CA bundle. Result: no shell, no package
# manager, no curl — the §1.1 attacker gets an SSRF and nothing else.
# ---------------------------------------------------------------------------
FROM golang:1.24-bookworm@sha256:9d4a...e21f AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN CGO_ENABLED=0 GOFLAGS=-trimpath go build \
      -ldflags="-s -w -buildid=" -o /out/checkout ./cmd/checkout

FROM gcr.io/distroless/static-debian12:nonroot@sha256:3f2b...77ac
# distroless/static:nonroot ships UID/GID 65532 and a CA bundle. Nothing else.
COPY --from=build /out/checkout /usr/local/bin/checkout
USER 65532:65532
EXPOSE 8443
ENTRYPOINT ["/usr/local/bin/checkout"]
```

| Base image | Size | Shell | Package manager | CVE surface (typical) | Debuggability | Use when |
|---|---|---|---|---|---|---|
| `ubuntu:24.04` | ~78 MB | ✅ | ✅ apt | 40–150 | trivial | never, for production services |
| `debian:12-slim` | ~30 MB | ✅ | ✅ apt | 20–60 | trivial | needs glibc + system libs |
| `alpine:3.21` | ~8 MB | ✅ ash | ✅ apk | 0–10 | easy | musl-compatible workloads |
| `chainguard/static` / `distroless/static` | ~2 MB | ❌ | ❌ | ~0 | `kubectl debug` only | static binaries (Go, Rust) |
| `scratch` | 0 MB | ❌ | ❌ | 0 | `kubectl debug` only | fully static, own CA bundle |

Debuggability is a real cost, not a rhetorical one. The mitigation is ephemeral containers, which give you a shell *next to* the workload without putting one *inside* the image:

```
$ kubectl -n payments debug -it checkout-7d9f4b6c8-x2klm \
    --image=busybox:1.37 --target=checkout -- sh
Defaulting debug container name to debugger-9x4kp.
/ # ls /proc/1/root/usr/local/bin
checkout
```

### 5.2 Signing and admission-time verification

Building a trusted image is worthless if the cluster will run an untrusted one.

```
$ COSIGN_EXPERIMENTAL=1 cosign sign \
    --yes 123456789012.dkr.ecr.eu-west-1.amazonaws.com/checkout@sha256:8e12...b9c3
Generating ephemeral keys...
Retrieving signed certificate...
Successfully verified SCT...
tlog entry created with index: 148392017
Pushing signature to: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/checkout

$ cosign verify \
    --certificate-identity-regexp='^https://github\.com/acme/checkout/\.github/workflows/.+@refs/heads/main$' \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    123456789012.dkr.ecr.eu-west-1.amazonaws.com/checkout@sha256:8e12...b9c3

Verification for 123456789012.dkr.ecr.eu-west-1.amazonaws.com/checkout@sha256:8e12...b9c3 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

Enforced at admission — this is the control that binds the Container layer to the Cluster layer:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  background: false
  rules:
    - name: verify-cosign-keyless
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments", "orders", "shipping"]
      verifyImages:
        - imageReferences:
            - "123456789012.dkr.ecr.eu-west-1.amazonaws.com/*"
          mutateDigest: true       # rewrite tag -> digest, pinning what was verified
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/acme/*/.github/workflows/*@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

### 5.3 Runtime confinement: a complete, `restricted`-compliant Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: payments
  labels:
    app.kubernetes.io/name: checkout
    app.kubernetes.io/component: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
    spec:
      serviceAccountName: checkout
      automountServiceAccountToken: false   # this pod never calls the API server
      hostNetwork: false
      hostPID: false
      hostIPC: false
      securityContext:                       # pod-level
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault               # ~44 syscalls blocked, incl. keyctl,
                                             # ptrace, userfaultfd, unshare
        supplementalGroups: []
      containers:
        - name: checkout
          image: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/checkout@sha256:8e12...b9c3
          imagePullPolicy: IfNotPresent
          ports:
            - name: https
              containerPort: 8443
              protocol: TCP
          securityContext:                   # container-level; overrides pod-level
            allowPrivilegeEscalation: false  # sets no_new_privs; neuters setuid binaries
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
          resources:                         # a missing limit is a DoS primitive
            requests:
              cpu: 200m
              memory: 256Mi
              ephemeral-storage: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
              ephemeral-storage: 512Mi
          env:
            - name: TLS_CERT_FILE
              value: /etc/tls/tls.crt
            - name: TLS_KEY_FILE
              value: /etc/tls/tls.key
          envFrom: []                        # never put secrets in env: they leak
                                             # into `kubectl describe`, crash dumps
                                             # and child-process environments
          volumeMounts:
            - name: tls
              mountPath: /etc/tls
              readOnly: true
            - name: db-credentials
              mountPath: /etc/db
              readOnly: true
            - name: tmp
              mountPath: /tmp
          livenessProbe:
            httpGet: { path: /healthz, port: https, scheme: HTTPS }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: https, scheme: HTTPS }
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: tls
          secret:
            secretName: checkout-tls
            defaultMode: 0400
        - name: db-credentials
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: checkout-db
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout
```

### 5.4 Isolation strength trade-offs

`securityContext` hardens a **shared-kernel** container. When the threat model includes untrusted code or hostile multi-tenancy, the shared kernel itself is the boundary you must replace.

| Runtime | Isolation boundary | Kernel attack surface | Startup overhead | Syscall performance | Use when |
|---|---|---|---|---|---|
| `runc` (default) | namespaces + cgroups + seccomp + LSM | full host kernel (~350 syscalls, reduced to ~300 by RuntimeDefault) | ~50 ms | native | trusted first-party workloads |
| `runc` + strict seccomp/AppArmor | same, narrowed | ~60–100 syscalls | ~50 ms | native | hardened first-party |
| **gVisor** (`runsc`) | userspace kernel (Sentry) intercepts syscalls | ~55 host syscalls | ~150–300 ms | 2–10× slower on syscall-heavy I/O | untrusted code, CI runners, FaaS |
| **Kata Containers** | dedicated VM per pod (QEMU/CH) | hypervisor interface only | ~500–1200 ms | near-native CPU; I/O penalty via virtio | hard multi-tenancy, compliance |
| **Firecracker** (via Kata/CH) | microVM | minimal device model | ~125 ms | near-native | large-scale untrusted tenancy |

Selection is per-workload, via `RuntimeClass`:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    node.kubernetes.io/runtime: gvisor
  tolerations:
    - key: sandboxed
      operator: Equal
      value: "true"
      effect: NoSchedule
overhead:
  podFixed:
    cpu: 90m
    memory: 120Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-plugin-runner
  namespace: tenant-workloads
spec:
  runtimeClassName: gvisor
  containers:
    - name: runner
      image: registry.internal.example.com/plugin-runner@sha256:1a2b...cc90
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 65532
        capabilities: { drop: ["ALL"] }
```

Confirm the sandbox is actually active — a missing RuntimeClass silently falls back to `runc` on some misconfigurations:

```
$ kubectl exec -n tenant-workloads untrusted-plugin-runner -- dmesg | head -3
[    0.000000] Starting gVisor...
[    0.318402] Creating cloned children...
[    0.512871] Setting up VFS2...

$ kubectl exec -n tenant-workloads untrusted-plugin-runner -- cat /proc/version
Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016
```

gVisor reports a synthetic kernel version. If you see the real host kernel (`6.1.x-aws`), the sandbox is not in effect.

---

## 6. Layer 4 — Code

The innermost layer. It has the highest change velocity, the lowest blast radius **when the outer layers are sound**, and the smallest set of controls that Kubernetes can help with at all.

| Control | Rationale | Where it fails in practice |
|---|---|---|
| TLS everywhere, including intra-cluster | A NetworkPolicy restricts *who* can connect, not *who* can sniff. A compromised CNI or node sees plaintext. | Teams treat the cluster network as trusted |
| Limit exposed ports to the strict minimum | Every listening port is an entry point; debug/admin/metrics ports are the classic forgotten ones | `:6060` pprof bound to `0.0.0.0` |
| Third-party dependency scanning + SBOM | The majority of exploitable CVEs are transitive | Scanning at build time only, never re-scanning deployed digests |
| Static analysis (SAST) in CI, blocking | Catches the §1.1 SSRF before it ships | Advisory-only mode, warnings ignored for years |
| Dynamic probing (DAST) against a staging deploy | Catches what SAST cannot model | No staging environment with production-shaped data |
| No secrets in code, images, or env vars | Images are pullable artifacts; env vars leak everywhere | `.env` files `COPY`'d into the image |

Kubernetes contributes to this layer through **short-lived, audience-scoped identity** rather than static credentials — a projected ServiceAccount token replaces a long-lived API key:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: checkout-with-projected-identity
  namespace: payments
spec:
  serviceAccountName: checkout
  automountServiceAccountToken: false
  containers:
    - name: checkout
      image: registry.internal.example.com/checkout@sha256:8e12...b9c3
      volumeMounts:
        - name: vault-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities: { drop: ["ALL"] }
  volumes:
    - name: vault-token
      projected:
        sources:
          - serviceAccountToken:
              path: vault-token
              # Audience-bound: this token is rejected by the Kubernetes API
              # server and by every service that is not "vault". Stealing it
              # buys the attacker nothing outside that one relationship.
              audience: vault
              expirationSeconds: 3600
```

Secret-delivery mechanisms, compared:

| Mechanism | Rotation | Visible in `kubectl describe`/`get pod -o yaml` | Leaks to child processes | Survives image exfiltration | Notes |
|---|---|---|---|---|---|
| Hard-coded in image | none | n/a | yes | ❌ leaked | never |
| `env` from Secret | pod restart | key name only, value hidden — but visible via `/proc/PID/environ` | **yes** | ✅ | avoid |
| Secret volume mount | kubelet refresh (~60 s) | no | no | ✅ | good default |
| CSI Secrets Store driver | provider-driven, live | no | no | ✅ | secret never enters etcd |
| Projected SA token (audience-scoped) | automatic, ≤1 h | no | no | ✅ | best; no long-lived material exists |
| SPIFFE/SPIRE X.509-SVID | automatic, ~1 h | no | no | ✅ | identity, not secret; enables mTLS |

---

## 7. Verification and failure diagnosis

### 7.1 A single verification pass, top to bottom

```
# --- Cloud ---------------------------------------------------------------
$ kubectl run imds-probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 \
    -- curl -s --max-time 5 http://169.254.169.254/latest/meta-data/
pod "imds-probe" deleted
pod default/imds-probe terminated (Error)
# ^ non-zero exit / empty body = PASS

# --- Cluster: is anything cluster-admin that should not be? ---------------
$ kubectl get clusterrolebindings -o json | jq -r '
    .items[]
    | select(.roleRef.name == "cluster-admin")
    | "\(.metadata.name)\t\(.subjects // [] | map(.kind + ":" + (.namespace // "-") + "/" + .name) | join(","))"'
cluster-admin	Group:-/system:masters
platform-oncall	Group:-/platform-sre
argocd-application-controller	ServiceAccount:argocd/argocd-application-controller

# --- Cluster: can a workload SA escalate? --------------------------------
$ kubectl auth can-i --list \
    --as=system:serviceaccount:payments:checkout -n payments
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/api/*]            []               [get]
                                                [/healthz]          []               [get]
                                                [/version]          []               [get]
# ^ no secrets, no pods/exec, no create — PASS

$ kubectl auth can-i create pods/exec \
    --as=system:serviceaccount:payments:checkout -n payments
no

$ kubectl auth can-i get secrets \
    --as=system:serviceaccount:payments:checkout -n payments
no

# --- Cluster: PSA actually enforcing? ------------------------------------
$ kubectl get ns -o custom-columns=\
'NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'
NAME              ENFORCE
default           <none>        <-- FINDING
ingress           restricted
kube-node-lease   <none>
kube-public       <none>
kube-system       privileged
payments          restricted
tenant-workloads  restricted

$ kubectl -n payments run bad --image=nginx --privileged
Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity
"restricted:v1.33": privileged (container "bad" must not set
securityContext.privileged=true), allowPrivilegeEscalation != false (container
"bad" must set securityContext.allowPrivilegeEscalation=false), unrestricted
capabilities (container "bad" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "bad" must set
securityContext.runAsNonRoot=true), seccompProfile (pod or container "bad" must
set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")

# --- Cluster: NetworkPolicy coverage -------------------------------------
$ for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    n=$(kubectl -n "$ns" get netpol --no-headers 2>/dev/null | wc -l)
    printf '%-18s %s\n' "$ns" "$n"
  done
default            0
ingress            3
kube-node-lease    0
kube-public        0
kube-system        1
payments           3
tenant-workloads   2

# --- Container: is the running pod actually confined? --------------------
$ kubectl -n payments get pod checkout-7d9f4b6c8-x2klm -o jsonpath=\
'{range .spec.containers[*]}{.name}{"\t"}{.securityContext}{"\n"}{end}'
checkout	{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":65532}

$ kubectl -n payments exec checkout-7d9f4b6c8-x2klm -- cat /proc/1/status \
    | grep -E 'NoNewPrivs|CapEff|Seccomp'
NoNewPrivs:	1
CapEff:	0000000000000000
Seccomp:	2
Seccomp_filters:	1
```

`NoNewPrivs: 1`, `CapEff: 0000000000000000`, `Seccomp: 2` (SECCOMP_MODE_FILTER) is the three-value fingerprint of a correctly confined container. Memorize it; it is the fastest possible runtime verification.

### 7.2 Benchmark sweep

```
$ kube-bench run --targets master,node,policies --version 1.33
[INFO] 1 Control Plane Security Configuration
[PASS] 1.2.16 Ensure that the --secure-port argument is not set to 0
[PASS] 1.2.19 Ensure that the --audit-log-path argument is set
[FAIL] 1.2.31 Ensure that encryption providers are appropriately configured
[WARN] 1.2.32 Ensure that the API Server only makes use of Strong Cryptographic Ciphers

[INFO] 4 Worker Node Security Configuration
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow
[FAIL] 4.2.6 Ensure that the --make-iptables-util-chains argument is set to true

== Summary total ==
62 checks PASS
2 checks FAIL
9 checks WARN
0 checks INFO
```

### 7.3 Failure diagnosis matrix

| Symptom | Layer | Likely cause | Diagnostic command | Fix |
|---|---|---|---|---|
| Pod stuck `ContainerCreating`, event `failed to sync secret cache` | Cluster | Secret missing / SA lacks read access to it | `kubectl describe pod` → Events | create Secret; check the SA's RBAC |
| Pod rejected with `violates PodSecurity "restricted:v1.33"` | Cluster | Manifest not restricted-compliant | error message enumerates every field | add the fields listed; do **not** relax the namespace label |
| `CreateContainerConfigError`: `container has runAsNonRoot and image will run as root` | Container | Image `USER` is 0 and no numeric `runAsUser` given | `docker inspect <img> --format '{{.Config.User}}'` | set `runAsUser: 65532` and fix the Dockerfile |
| App logs `read-only file system` at startup | Container | `readOnlyRootFilesystem: true` with no writable path | `kubectl logs` | mount `emptyDir` at the write path |
| Every DNS lookup fails right after applying a policy | Cluster | default-deny with no egress to kube-dns | `kubectl exec -- nslookup kubernetes.default` | add the `allow-dns` policy (§4.2) |
| NetworkPolicy applied but has no effect | Cluster | CNI does not implement NetworkPolicy (e.g. plain flannel, or AWS VPC CNI without the network-policy agent) | `kubectl -n kube-system get ds` | switch to Cilium/Calico or enable the policy agent |
| Pod can still reach `169.254.169.254` despite hop limit 1 | Cloud | Pod runs `hostNetwork: true`, so it *is* the node | `kubectl get pod -o jsonpath='{.spec.hostNetwork}'` | forbid hostNetwork via PSA `baseline`+ / VAP |
| Secrets readable in an etcd snapshot | Cluster | `identity: {}` first in the provider list, or config never wired to the apiserver | hexdump etcd key (§4.1) | reorder providers, restart apiserver, rewrite all Secrets |
| Signed-image policy passes for an unsigned image | Cluster | Kyverno webhook `failurePolicy: Ignore` and the controller was down | `kubectl get validatingwebhookconfigurations -o yaml \| grep failurePolicy` | `failurePolicy: Fail` + HA replicas + PDB |
| `cosign verify` fails with `no matching signatures` on an image that was signed | Container | Verifying by tag while the tag moved | `crane digest <ref>` | verify and deploy by digest only |
| Audit log has no `system:anonymous` entries but the API is internet-reachable | Cluster | `--anonymous-auth=true` with `--audit-policy-file` at `None` for that stage | check apiserver flags / managed-cluster log config | raise the audit policy to `Metadata` minimum for all requests |
| gVisor pod shows the host kernel version | Container | `runtimeClassName` typo, or `handler` not registered in containerd | `kubectl get runtimeclass`; `grep runsc /etc/containerd/config.toml` | register the handler; recreate the pod |

### 7.4 The audit trail that ties the layers together

An audit policy that captures the cross-layer signals:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  # Never log the contents of Secrets — the audit log becomes the exfil target.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # Full body for anything that grants privilege.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
      - group: "admissionregistration.k8s.io"
        resources: ["*"]
      - group: "policy"
        resources: ["*"]

  # Exec/attach/port-forward: the interactive-access signal.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]

  # Anonymous and unauthenticated traffic, always.
  - level: RequestResponse
    userGroups: ["system:unauthenticated", "system:anonymous"]

  # Drop the noise floor.
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager"]
    verbs: ["get", "list", "watch"]
  - level: None
    nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/version", "/metrics"]

  - level: Metadata
```

Querying it for the §1.1 chain:

```
$ kubectl -n payments logs -l app=audit-forwarder --tail=0 -f | \
    jq -r 'select(.objectRef.subresource == "exec")
           | [.requestReceivedTimestamp, .user.username,
              .objectRef.namespace + "/" + .objectRef.name] | @tsv'
2026-08-06T11:42:07.118Z	system:serviceaccount:payments:checkout	payments/postgres-0
```

A **ServiceAccount** issuing `pods/exec` is never legitimate application behaviour. This single query catches the transition from Container-layer foothold to Cluster-layer compromise, and it is the highest signal-to-noise detection in the entire model.

---

## 8. Exam-relevant invariants

- The order is **Cloud → Cluster → Container → Code**, outermost to innermost. Security flows inward; compensation does **not** flow outward.
- The Cluster layer has **two** distinct concerns: securing the *configurable cluster components*, and securing the *applications running in the cluster*.
- Container-layer priorities named upstream: **container vulnerability scanning + OS dependency security**, **image signing and enforcement**, and **disallow privileged users** (build images with a non-root `USER` and enforce `runAsNonRoot` at runtime).
- Code-layer priorities named upstream: **access over TLS only**, **limiting communication port ranges**, **third-party dependency security**, and **static + dynamic code analysis**.
- The Code layer is the only layer with **no** ability to compensate for weakness beneath it — this negative claim is the model's central, most-tested assertion.
- The 4Cs (spatial) and the CNCF whitepaper lifecycle phases Develop → Distribute → Deploy → Runtime (temporal) are **complementary**, not competing.

---

## 9. Referencias

- Kubernetes Documentation — *Overview of Cloud Native Security* (the 4Cs): https://kubernetes.io/docs/concepts/security/overview/
- Kubernetes Documentation — *Cloud Native Security and Kubernetes*: https://kubernetes.io/docs/concepts/security/cloud-native-security/
- Kubernetes Documentation — *Pod Security Standards*: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes Documentation — *Pod Security Admission*: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes Documentation — *Encrypting Confidential Data at Rest*: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes Documentation — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Documentation — *Configure a Security Context for a Pod or Container*: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes Documentation — *Validating Admission Policy*: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes Documentation — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes Documentation — *Runtime Class*: https://kubernetes.io/docs/concepts/containers/runtime-class/
- Kubernetes Documentation — *Managing Service Accounts / Bound Service Account Tokens*: https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes Documentation — *Securing a Cluster*: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- CNCF TAG Security — *Cloud Native Security Whitepaper*: https://github.com/cncf/tag-security/tree/main/community/resources/security-whitepaper
- CNCF — *KCSA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- Aqua Security — *kube-bench*: https://github.com/aquasecurity/kube-bench
- NIST SP 800-190 — *Application Container Security Guide*: https://csrc.nist.gov/publications/detail/sp/800-190/final
- Sigstore — *cosign* documentation: https://docs.sigstore.dev/cosign/signing/overview/
- Kyverno — *Verify Images*: https://kyverno.io/docs/writing-policies/verify-images/
- gVisor — *What is gVisor?*: https://gvisor.dev/docs/
- Kata Containers — Documentation: https://katacontainers.io/docs/
- AWS — *Use IMDSv2*: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS — *EKS Best Practices Guide, Security*: https://aws.github.io/aws-eks-best-practices/security/docs/
- Google Cloud — *GKE Workload Identity Federation*: https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
- Google Cloud — *Harden your GKE cluster's security*: https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster
- MITRE ATT&CK — *Containers Matrix*: https://attack.mitre.org/matrices/enterprise/containers/
- OWASP — *Kubernetes Top Ten*: https://owasp.org/www-project-kubernetes-top-ten/