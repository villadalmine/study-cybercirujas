# 5.2 Define and enforce Network Policies

## Overview

By default in Kubernetes clusters, **all Pods communicate with all other Pods** without network restrictions, regardless of Namespace placement. This default behavior stems from the flat network model where every Pod receives its own IP address.

A **NetworkPolicy** is an API resource (`networking.k8s.io/v1`) that defines Layer 3 (IP) and Layer 4 (TCP/UDP/SCTP) ingress and egress traffic filtering rules targeting specific sets of Pods. NetworkPolicies do not process Layer 7 application protocols (HTTP paths or headers) — Layer 7 filtering requires Service Meshes or specialized CNI extensions.

### Core Requirement: CNI Enforcement Support

**NetworkPolicy objects are declarative specifications**. Kubernetes does not contain a native network packet filtering engine; rules are enforced (or ignored) by the installed **CNI plugin**.

- If an installed CNI driver **lacks NetworkPolicy support** (e.g. basic Flannel), `NetworkPolicy` resources create without errors but **exert zero traffic control**.
- CNIs supporting NetworkPolicy enforcement: **Calico**, **Cilium**, **Weave Net**, **Antrea**, and related drivers.

On the CKA exam, clusters feature pre-configured, NetworkPolicy-compliant CNI plugins (typically Calico).

---

## Default Isolation Behavior

- Pods **unselected by any NetworkPolicy** accept and transmit all ingress and egress traffic by default.
- Once **at least one** NetworkPolicy selects a Pod (via `podSelector`) for a specified traffic type (`Ingress` or `Egress`), that Pod enters an **implicit default-deny** isolation mode for that traffic type. Only traffic explicitly listed under allowed rules is permitted.
- **Policies are additive (union)**: When multiple NetworkPolicies target the same Pod, allowed traffic equals the **union** of all allow rules. Explicit `deny` rules do not exist in standard NetworkPolicy specifications — unallowed traffic is denied implicitly.

---

## Structure of a NetworkPolicy Manifest

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ejemplo
  namespace: produccion
spec:
  podSelector:        # Target Pods selected within the same Namespace
    matchLabels:
      app: backend
  policyTypes:         # Traffic directions: Ingress, Egress, or both
  - Ingress
  - Egress
  ingress:              # Ingress allow rules
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:                # Egress allow rules
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5432
```

Key fields:

- **`podSelector`**: Selects target Pods within the policy's Namespace. An empty `podSelector: {}` selects **all Pods within the Namespace**.
- **`policyTypes`**: Specifies whether rules apply to `Ingress`, `Egress`, or both. If omitted, fields are inferred based on rule block presence. Best practice: Declare `policyTypes` explicitly, particularly for default-deny policies.
- **`ingress[].from`** / **`egress[].to`**: List of allowed peers:
  - `podSelector`: Pods within the same Namespace (or matching namespaces when combined with `namespaceSelector`).
  - `namespaceSelector`: All Pods within matching namespaces.
  - `ipBlock`: External IP CIDR ranges, supporting `except` sub-blocks.
- **`ports`**: Allowed ports and protocols. Omitting `ports` allows **all ports**.

### Combining Selectors: AND vs OR Logical Conditions

```yaml
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
      namespaceSelector:
        matchLabels:
          env: prod
```

When `podSelector` and `namespaceSelector` are declared **inside a single list element** (sharing one `-` block), they combine using **AND** logic: Traffic is allowed strictly from Pods carrying `role: frontend` **that reside inside** namespaces labeled `env: prod`.

```yaml
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    - namespaceSelector:
        matchLabels:
          env: prod
```

When declared in **separate list elements** (distinct `-` blocks), they combine using **OR** logic: Traffic is allowed from Pods with `role: frontend` (in any namespace) **OR** any Pod in namespaces labeled `env: prod`.

> In Kubernetes 1.21+, every Namespace automatically exposes label `kubernetes.io/metadata.name: <namespace-name>`, enabling `namespaceSelector` matching by namespace name without manual labeling.

---

## Common Policy Patterns

### 1. Default Deny All Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

Selects all Pods in the namespace and defines no ingress allow rules → blocks all inbound traffic.

### 2. Default Deny All Egress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Egress
```

### 3. Allow All Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - {}
```

An empty `ingress: - {}` block allows traffic from **any source** across all ports.

### 4. Allow Traffic from Specific Labels on Target Ports

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: produccion
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
```

### 5. Allow DNS Resolution (Crucial for Default-Deny Egress)

When applying `default-deny-egress`, explicitly allow outbound DNS queries targeting CoreDNS (`kube-system` namespace, port 53 UDP/TCP) to prevent resolution failures:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

---

## Verification & Troubleshooting

Verify policy definitions:

```bash
kubectl get networkpolicy -n produccion
kubectl describe networkpolicy allow-frontend-to-backend -n produccion
```

Test traffic filtering using temporary Pods:

```bash
kubectl run test-pod --image=busybox:1.36 --rm -it --restart=Never \
  --labels="app=frontend" -n produccion -- wget -qO- --timeout=2 http://backend-svc:8080
```

If labels omit required matches, network attempts return connection timeouts, confirming policy enforcement.

---

## References

- Network Policies Overview: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Declare Network Policy Task Guide: https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- NetworkPolicy API Reference: https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
