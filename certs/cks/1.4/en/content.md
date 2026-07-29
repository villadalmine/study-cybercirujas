# 1.4 Protect node metadata and endpoints

## Why this matters

Every worker node exposes two classes of privileged surface that are reachable *from inside a Pod* by default:

1. **Cloud instance metadata** — the link-local service at `169.254.169.254`, which hands out the node's identity, its `user-data` (often containing bootstrap tokens or kubeconfigs) and, most dangerously, **short-lived cloud credentials for the node's IAM role / service account**.
2. **Node and control-plane endpoints** — the kubelet API on `10250`, the legacy read-only port `10255`, etcd on `2379`, the API server on `6443`, and the controller-manager / scheduler health ports.

A container escape is not required to abuse either one. A plain `curl` from an unprivileged Pod is enough. The classic attack chain is:

```
compromised app Pod → curl 169.254.169.254 → node IAM credentials
                    → read cluster secrets from cloud storage / attach new nodes
```

or

```
compromised app Pod → curl -k https://NODE_IP:10250/pods → anonymous kubelet
                    → POST /run/<ns>/<pod>/<container> → RCE on any container on that node
```

Both are network-level problems, so both are fixed with network-level and authn/authz-level controls — not with Pod Security Standards.

---

## Part 1 — Cloud instance metadata

### What the endpoint exposes

The address `169.254.169.254` is identical on AWS, GCP, Azure and most OpenStack-based clouds. Only the paths and the required headers differ.

**GCP / GKE**

```bash
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
```

```json
{"access_token":"ya29.c.b0Aa...","expires_in":3599,"token_type":"Bearer"}
```

Legacy `v1beta1` paths did not require the `Metadata-Flavor` header, which made them trivially exploitable via SSRF. They are disabled on modern instances.

**AWS / EKS**

IMDSv1 (unauthenticated, single GET):

```bash
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
# eks-node-role
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eks-node-role
```

```json
{"Code":"Success","AccessKeyId":"ASIA...","SecretAccessKey":"...","Token":"...","Expiration":"2026-07-29T18:04:11Z"}
```

IMDSv2 requires a session token first:

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/
```

**Azure / AKS**

```bash
curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/instance?api-version=2021-02-01"
```

### Quick test from a Pod

```bash
kubectl run imds-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s --connect-timeout 3 http://169.254.169.254/latest/meta-data/
```

If you get a listing back, every workload in that namespace can steal node credentials. If the policy is in place you get a timeout:

```
curl: (28) Connection timed out after 3001 milliseconds
pod "imds-test" deleted
pod default/imds-test terminated (Error)
```

### Mitigation 1 — NetworkPolicy (the exam answer)

NetworkPolicies are allow-lists, so "block one IP" is expressed as *allow everything except that IP*. Apply it per namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: default
spec:
  podSelector: {}          # every Pod in the namespace
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32
  # keep cluster DNS working explicitly
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
```

```bash
kubectl apply -f deny-cloud-metadata.yaml
kubectl describe netpol deny-cloud-metadata
```

```
Allowing egress traffic:
  To Port: <any> (traffic allowed to all ports)
  To:
    IPBlock:
      CIDR: 0.0.0.0/0
      Except: 169.254.169.254/32
```

Three caveats that are regularly tested:

- The policy is **namespaced**. One per namespace, or a cluster-wide equivalent (`CiliumClusterwideNetworkPolicy`, Calico `GlobalNetworkPolicy`).
- Pods with `hostNetwork: true` share the node's netns and are **not** subject to NetworkPolicy. Block `hostNetwork` with Pod Security Admission (`baseline`/`restricted`) or a ValidatingAdmissionPolicy.
- You need a CNI that enforces NetworkPolicy (Calico, Cilium, Weave…). On a plain flannel cluster the object is accepted and silently ignored.

### Mitigation 2 — Cloud-native controls

| Platform | Control |
|---|---|
| AWS/EKS | `--http-tokens required` (force IMDSv2) **and** `--http-put-response-hop-limit 1`, so the response TTL dies before reaching a Pod netns. Use IRSA / EKS Pod Identity for workload credentials. |
| GKE | Enable **Workload Identity** (`--workload-metadata-config=GKE_METADATA`); the GKE metadata server only serves the Pod's own identity and blocks the node's. |
| AKS | Restrict IMDS with a network policy and use **Workload Identity** (OIDC federation) instead of the kubelet identity. |

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id i-0abc123 --http-tokens required --http-put-response-hop-limit 1
```

### Mitigation 3 — Node-level firewall (fallback)

Only when no policy-capable CNI exists:

```bash
iptables -I FORWARD -d 169.254.169.254/32 -j DROP
```

This drops metadata traffic that is *forwarded* from Pods while leaving the node's own access intact. It is not idempotent across reboots — persist it with your node bootstrap tooling.

---

## Part 2 — Node endpoints

### The kubelet API (10250) and read-only port (10255)

The kubelet serves `/pods`, `/runningpods/`, `/metrics`, `/logs/`, `/exec/`, `/run/` and `/attach/`. With anonymous auth enabled, `/run/` is unauthenticated remote code execution on any container scheduled on that node.

Check the current posture:

```bash
curl -sk https://NODE_IP:10250/pods | head -c 120
```

Hardened node:

```
Unauthorized
```

Vulnerable node:

```json
{"kind":"PodList","apiVersion":"v1","metadata":{},"items":[{"metadata":{"name":"etcd-controlplane",...
```

Also probe the read-only port, which needs no TLS and no credentials:

```bash
curl -s http://NODE_IP:10255/pods            # should refuse the connection
```

Fix in `/var/lib/kubelet/config.yaml`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false          # no anonymous requests
  webhook:
    enabled: true           # bearer tokens validated via TokenReview
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook             # NOT AlwaysAllow — delegate to the API server
readOnlyPort: 0             # disable 10255
```

```bash
systemctl restart kubelet
systemctl status kubelet --no-pager | head -5
```

Verify the effective flags if the kubelet is still started with CLI arguments:

```bash
ps -ef | grep [k]ubelet | tr ' ' '\n' | grep -E 'anonymous|authorization-mode|read-only-port|config'
```

```
--config=/var/lib/kubelet/config.yaml
```

(Flags override the config file; on kubeadm clusters the settings live in the YAML.)

### Restrict who can reach the kubelet through the API server

Even a locked-down kubelet can be reached via the API server proxy:

```bash
kubectl get --raw /api/v1/nodes/node01/proxy/pods
```

This requires the `nodes/proxy` subresource. Audit and remove it from non-admin roles:

```bash
kubectl get clusterroles -o json | jq -r '
  .items[] | select(.rules[]?.resources[]? | test("nodes/proxy")) | .metadata.name'
```

### Control-plane endpoints on the node

| Component | Port | Expected binding |
|---|---|---|
| kube-apiserver | 6443 | TLS + authn/authz; the legacy insecure port `8080` no longer exists |
| kubelet | 10250 | TLS, `Webhook` authz |
| kubelet read-only | 10255 | disabled (`readOnlyPort: 0`) |
| kube-scheduler | 10259 | `--bind-address=127.0.0.1` |
| kube-controller-manager | 10257 | `--bind-address=127.0.0.1` |
| etcd | 2379 / 2380 | client + peer cert auth, `127.0.0.1`/node IP only |

```bash
ss -tlnp | grep -E ':(2379|2380|6443|10250|10255|10257|10259)'
```

```
LISTEN 0 4096 127.0.0.1:10257  0.0.0.0:*  users:(("kube-controller",pid=1421,fd=3))
LISTEN 0 4096 127.0.0.1:10259  0.0.0.0:*  users:(("kube-scheduler",pid=1388,fd=3))
LISTEN 0 4096         *:10250  *:*        users:(("kubelet",pid=902,fd=21))
```

Anything bound to `0.0.0.0` that should be loopback-only is a finding. Complement this with host firewall rules or cloud security groups so `10250`, `2379-2380` and `6443` are only reachable from cluster members and admin networks.

### Node authorization and NodeRestriction

Make sure a compromised kubelet cannot read secrets belonging to Pods it does not run, and cannot relabel itself into a privileged node:

```bash
kubectl -n kube-system get pod kube-apiserver-controlplane -o yaml \
  | grep -E 'authorization-mode|enable-admission-plugins'
```

```
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
```

`Node` authorization scopes kubelet reads to objects bound to that node; `NodeRestriction` prevents a kubelet from modifying other nodes or setting `node-restriction.kubernetes.io/*` labels on itself.

---

## Hardening checklist

- [ ] Default-deny egress to `169.254.169.254/32` in every workload namespace.
- [ ] `hostNetwork: true` blocked by admission (it bypasses NetworkPolicy).
- [ ] Cloud-native workload identity in use; node IAM role holds the minimum permissions.
- [ ] IMDSv2 required with hop limit 1 (AWS) or Workload Identity metadata server (GKE/AKS).
- [ ] `anonymous.enabled: false`, `authorization.mode: Webhook`, `readOnlyPort: 0`.
- [ ] `--authorization-mode=Node,RBAC` and `NodeRestriction` enabled.
- [ ] scheduler/controller-manager bound to `127.0.0.1`; etcd requires client certs.
- [ ] `nodes/proxy` not granted outside break-glass roles.
- [ ] Verified from a throwaway Pod, not just by reading manifests.

---

## References

- CKS Curriculum v1.34 — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
- Network Policies — <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- Kubelet authentication and authorization — <https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/>
- Kubelet configuration (v1beta1) reference — <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/>
- Using Node Authorization — <https://kubernetes.io/docs/reference/access-authn-authz/node/>
- Admission controllers (NodeRestriction) — <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction>
- Ports and Protocols — <https://kubernetes.io/docs/reference/networking/ports-and-protocols/>
- Securing a Cluster — <https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/>
- Pod Security Standards — <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- AWS — Use IMDSv2 — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-new-instances.html>
- AWS — Restrict access to the instance profile assigned to the worker node (EKS Best Practices) — <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html>
- GKE — Workload Identity Federation — <https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity>
- GCP — VM metadata server — <https://cloud.google.com/compute/docs/metadata/overview>
- Azure — Instance Metadata Service — <https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service>
- CIS Kubernetes Benchmark (kubelet section 4.2) — <https://www.cisecurity.org/benchmark/kubernetes>