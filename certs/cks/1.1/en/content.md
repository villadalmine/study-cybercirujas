# 1.1 Use Network Security Policies to Restrict Cluster Level Access

## Why this matters

By default, Kubernetes networking is **flat and fully permissive**: every Pod can reach every other Pod in every namespace, plus any external endpoint the node can route to. There is no built-in segmentation. A single compromised frontend Pod can therefore reach your database, the internal admin service in another namespace, the cloud provider metadata endpoint, or the kube-apiserver.

`NetworkPolicy` is the Kubernetes-native answer: an L3/L4 firewall expressed as a namespaced API object, selected by labels rather than IPs. In CKS scenarios it is the primary tool for implementing **least-privilege east-west traffic** and for blocking egress paths used in credential-theft attacks.

## Prerequisite: the CNI plugin must enforce policies

`NetworkPolicy` objects are stored by the API server whether or not anything enforces them. If your CNI plugin does not implement the feature, `kubectl apply` succeeds and **nothing is blocked** — a dangerous false sense of security.

| CNI plugin | NetworkPolicy support |
|---|---|
| Calico | Yes (plus its own CRDs) |
| Cilium | Yes (plus `CiliumNetworkPolicy`) |
| Weave Net | Yes |
| Antrea, Kube-router, OVN-Kubernetes | Yes |
| Flannel (alone) | **No** |

Quick check of what is installed:

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|weave|antrea|flannel'
```

```
calico-kube-controllers-7d4b8c9f5-2xq7m   1/1     Running   0     4d
calico-node-8fkzp                          1/1     Running   0     4d
calico-node-lm2vd                          1/1     Running   0     4d
```

## Anatomy of a NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-frontend
  namespace: prod
spec:
  podSelector:                 # WHICH pods this policy protects (in this namespace)
    matchLabels:
      app: api
  policyTypes:                 # WHICH directions this policy governs
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
```

Four rules govern the semantics, and every exam mistake comes from forgetting one of them:

1. **Namespaced and label-driven.** A policy only protects Pods in its own namespace, chosen by `spec.podSelector`. An empty selector (`podSelector: {}`) means *all Pods in this namespace*.
2. **Selecting a Pod switches it to deny-by-default** for the listed `policyTypes`. A Pod not selected by any policy remains fully open.
3. **Policies are purely additive (allow-list only).** There is no `deny` rule. If two policies select the same Pod, the union of their allowances applies. You cannot "subtract" access with a second policy.
4. **`policyTypes` is inferred if omitted:** `Ingress` is always included; `Egress` only if an `egress` block exists. Always write `policyTypes` explicitly — a policy with only `ingress` rules does **not** restrict egress.

### The selector trap: AND vs OR

This is the single most common error. Compare the YAML indentation:

```yaml
# OR — pods labelled app=frontend in ANY namespace,
#      OR any pod in a namespace labelled env=trusted
ingress:
  - from:
      - podSelector:
          matchLabels:
            app: frontend
      - namespaceSelector:
          matchLabels:
            env: trusted
```

```yaml
# AND — ONLY pods labelled app=frontend that live
#       in a namespace labelled env=trusted
ingress:
  - from:
      - podSelector:
          matchLabels:
            app: frontend
        namespaceSelector:
          matchLabels:
            env: trusted
```

Two list items (`-`) = OR. Two keys inside one list item = AND. Also note: a bare `podSelector` inside `from`/`to` means *the policy's own namespace*; to allow a Pod from another namespace you **must** add a `namespaceSelector`.

Kubernetes automatically labels every namespace with `kubernetes.io/metadata.name: <namespace>`, so you can target a namespace by name without editing it:

```yaml
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: monitoring
```

## Default-deny baselines

Start every hardened namespace from a deny-all posture, then punch precise holes.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}              # every pod in the namespace
  policyTypes:
    - Ingress
    - Egress
  # no ingress/egress blocks at all => deny everything both ways
```

Variants you should be able to write from memory:

```yaml
# Deny all ingress only
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

```yaml
# Allow all egress (explicit permit — useful to override a broad deny in a legacy setup)
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - {}
```

### Always re-allow DNS

A default-deny-egress policy breaks name resolution, and the symptom looks like a total network failure. Every service that must resolve names needs egress to CoreDNS on port 53 (both UDP and TCP — TCP is used for large responses):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Egress]
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
```

## Restricting cluster-level access

### Isolate a namespace from all others

Allow intra-namespace traffic while rejecting everything from outside:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace-only
  namespace: payments
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}      # every pod in namespace "payments"
```

### Block the cloud metadata endpoint

`169.254.169.254` serves instance credentials on AWS/GCP/Azure. Reaching it from a compromised Pod is a classic privilege-escalation path (SSRF → node IAM role). Deny it with an `except` clause while keeping general internet egress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

`ipBlock` is meant for **cluster-external** CIDRs. Because of SNAT/masquerading behaviour in most CNIs, matching Pod IPs with `ipBlock` is unreliable — use `podSelector`/`namespaceSelector` for in-cluster traffic.

### Restrict egress to the kube-apiserver

To stop workloads from talking to the control plane directly, deny egress to the API server endpoint. Find the real address first — the `kubernetes` Service in `default` is a ClusterIP that DNATs to the node/VIP address:

```bash
kubectl get endpoints kubernetes -n default
```

```
NAME         ENDPOINTS            AGE
kubernetes   192.168.56.10:6443   12d
```

Then either omit that CIDR from your allow-list, or exclude it explicitly:

```yaml
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 192.168.56.10/32
              - 169.254.169.254/32
```

Because policy evaluation happens on the **post-DNAT destination Pod/host IP**, never write rules against Service ClusterIPs — always target the backing Pods or the endpoint address.

### Port ranges

For a contiguous range, use `endPort` (stable since v1.25) instead of listing each port:

```yaml
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: gateway
      ports:
        - protocol: TCP
          port: 8000
          endPort: 8100
```

`port` may also be a **named port** from the target container's `containerPort.name`, which survives port renumbering.

## Verifying enforcement

Writing the policy is half the task; the exam expects you to prove it works.

```bash
# Inspect what is actually applied
kubectl get netpol -n prod
kubectl describe netpol default-deny-all -n prod
```

```
Name:         default-deny-all
Namespace:    prod
Created on:   2026-07-28 10:14:02 +0000 UTC
Spec:
  PodSelector:     <none> (Allowing the specific traffic to all pods in this namespace)
  Allowing ingress traffic:
    <none> (Selected pods are isolated for ingress connectivity)
  Allowing egress traffic:
    <none> (Selected pods are isolated for egress connectivity)
  Policy Types: Ingress, Egress
```

Test connectivity from a throwaway Pod:

```bash
kubectl run probe -n prod --rm -it --restart=Never \
  --image=busybox:1.36 -- wget -qO- --timeout=2 http://api:8080/healthz
```

Blocked traffic times out rather than being refused (packets are dropped, not rejected):

```
wget: download timed out
pod "probe" deleted
pod prod/probe terminated (Error)
```

Allowed traffic returns immediately:

```
ok
pod "probe" deleted
```

Test from a *labelled* Pod to validate selector matching, and from another namespace to validate isolation:

```bash
kubectl run probe -n prod --labels=app=frontend --rm -it --restart=Never \
  --image=busybox:1.36 -- nc -zv -w 2 api 8080
kubectl run probe -n staging --rm -it --restart=Never \
  --image=busybox:1.36 -- nc -zv -w 2 api.prod.svc.cluster.local 8080
```

## Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| Policy applied, nothing blocked | CNI does not enforce NetworkPolicy |
| Everything breaks after default-deny | Missing DNS egress rule (port 53 UDP **and** TCP) |
| Cross-namespace traffic still denied | Only `podSelector` used — needs `namespaceSelector` too |
| Unexpected traffic allowed | Another policy selects the same Pods; effects are additive |
| Egress rule to a Service does not work | Rule targets ClusterIP; must target backing Pods post-DNAT |
| Ingress from a Pod not restricted | Source Pod uses `hostNetwork: true`, or traffic originates from the node (health probes) |
| Policy ignored entirely | Wrong namespace, or `policyTypes` omitted the direction you meant |

## Exam tips

- Always create the **default-deny** policy plus an explicit **DNS allow** as your baseline pair.
- Check namespace labels (`kubectl get ns --show-labels`) before writing a `namespaceSelector`; add one with `kubectl label ns staging env=trusted` if needed.
- Never memorise YAML from scratch under time pressure — copy the canonical example from the Kubernetes docs (Network Policies page) and edit it.
- Confirm your work with a probe Pod; a policy that silently matches nothing scores zero.
- Be aware that the newer cluster-scoped `AdminNetworkPolicy` / `BaselineAdminNetworkPolicy` APIs (group `policy.networking.k8s.io`, implemented by Calico, Cilium and OVN-Kubernetes) add true `Deny` and `Pass` actions and evaluate *before* namespaced `NetworkPolicy`. They are an out-of-tree extension, so standard `networking.k8s.io/v1` remains the exam target.

## References

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes API Reference — NetworkPolicy v1 — https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Kubernetes — Cluster Networking — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes — Automatic labelling of namespaces — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/#automatic-labelling
- Kubernetes — Network Policy targeting a range of ports — https://kubernetes.io/docs/concepts/services-networking/network-policies/#targeting-a-range-of-ports
- Kubernetes — Admin Network Policy (SIG Network Policy API) — https://network-policy-api.sigs.k8s.io/
- Calico — Network Policy — https://docs.tigera.io/calico/latest/network-policy/
- Cilium — Network Policy — https://docs.cilium.io/en/stable/security/policy/