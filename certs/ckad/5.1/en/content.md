# 5.1 — NetworkPolicies: Fundamentals

## What is a NetworkPolicy?

A **NetworkPolicy** is a Kubernetes resource that controls network traffic to and from **Pods** at Layer 3/4 (IP address and port). It acts as a declarative firewall within the cluster: defining *which Pods are allowed to communicate with which Pods* (and external targets), instead of configuring network rules manually.

Two core principles to master for the exam:

1. **By default, all traffic is allowed.** If no NetworkPolicy object selects a Pod, that Pod is *non-isolated*: it accepts all incoming traffic and can initiate any outgoing connection.
2. **Policies are additive (allow-list).** As soon as a NetworkPolicy selects a Pod, that Pod becomes *isolated* for the traffic direction specified by the policy (`Ingress`, `Egress`, or both), and **only** traffic explicitly matched by an allow rule is permitted. There are no "deny" rules: blocking traffic is accomplished by omitting it from allow rules.

> **Prerequisite:** NetworkPolicies are enforced by the cluster's network plugin (**CNI**) — for example, Calico or Cilium. If the CNI does not support NetworkPolicies, the object can still be created in etcd but **has no runtime effect**. Exam clusters provide compatible CNIs, but keeping this in mind prevents wasted troubleshooting time.

---

## Resource Anatomy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: example
  namespace: app
spec:
  podSelector:          # TARGET Pods to which this policy applies (same namespace)
    matchLabels:
      app: api
  policyTypes:          # Traffic directions governed: Ingress, Egress, or both
    - Ingress
    - Egress
  ingress:              # Allowed INCOMING traffic rules
    - from: [...]
      ports: [...]
  egress:               # Allowed OUTGOING traffic rules
    - to: [...]
      ports: [...]
```

Key fields:

| Field | Description |
|---|---|
| `spec.podSelector` | Selects Pods **governed by** the policy within the policy's namespace. `podSelector: {}` selects **all** Pods in the namespace. |
| `spec.policyTypes` | Array containing `Ingress`, `Egress`, or both. Specifies which traffic direction becomes isolated. Omitting it infers types from present sections — explicitly declaring types is best practice. |
| `ingress[].from` / `egress[].to` | Allowed *peers*: `podSelector`, `namespaceSelector`, `ipBlock`, or combinations. |
| `ports` | Allowed ports and protocols (`TCP` by default; also `UDP` and `SCTP`; `endPort` allows port ranges). |

**Important:** There is no imperative `kubectl create networkpolicy` command. During the exam, always start from YAML (copy an official documentation template and edit it).

---

## Example 1: Allow Ingress Only From Frontend

Scenario: Pods labeled `app=db` must only accept incoming connections on port 5432 from Pods labeled `app=api` in the same namespace.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-api
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api
      ports:
        - protocol: TCP
          port: 5432
```

Apply and inspect:

```bash
$ kubectl apply -f db-allow-api.yaml
networkpolicy.networking.k8s.io/db-allow-api created

$ kubectl get networkpolicy -n prod
NAME           POD-SELECTOR   AGE
db-allow-api   app=db         10s

$ kubectl describe networkpolicy db-allow-api -n prod
Name:         db-allow-api
Namespace:    prod
Spec:
  PodSelector:     app=db
  Allowing ingress traffic:
    To Port: 5432/TCP
    From:
      PodSelector: app=api
  Not affecting egress traffic
  Policy Types: Ingress
```

Effect: Pods labeled `app=db` become ingress-isolated. Only traffic from `app=api` Pods targeting port 5432/TCP is permitted. Outgoing (**egress**) traffic remains unconstrained, as the policy omits `Egress` from `policyTypes`.

---

## Example 2: Default Deny (Classic Exam Pattern)

Deny **all ingress traffic** for all Pods in a namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  podSelector: {}        # Selects all Pods in namespace
  policyTypes:
    - Ingress            # Empty ingress array => zero allowed ingress
```

Essential variants to memorize:

```yaml
# Deny all egress
spec:
  podSelector: {}
  policyTypes: [Egress]
---
# Deny all traffic (ingress + egress)
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# Allow all ingress (useful for un-isolating after a default-deny)
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - {}                 # Empty rule object = allow from any origin
```

Common production and exam pattern: Apply a `default-deny` policy in the namespace, then create granular policies opening required paths. Because NetworkPolicies are additive, rules merge seamlessly without conflicts.

---

## Peers in `from` / `to`: AND vs. OR Selectors

This represents one of the most frequently tested concepts. Compare:

**Case A — Two list items (OR logic):**

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            team: platform
      - podSelector:
          matchLabels:
            app: api
```

Allows traffic from: any Pod in namespaces labeled `team=platform`, **OR** Pods labeled `app=api` in the policy's namespace. These are two independent peer entries (separate dash elements).

**Case B — Single list item with two fields (AND logic):**

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            team: platform
        podSelector:
          matchLabels:
            app: api
```

Allows traffic **only** from Pods labeled `app=api` that reside inside namespaces labeled `team=platform`. This represents a single peer with dual conditions (single dash element).

The syntax difference hinges on a single `-` character. Read requirements carefully: "from namespace X **or** from pods Y" vs. "from pods Y **in** namespace X".

> To select a namespace by name, leverage the automatic label `kubernetes.io/metadata.name` present on all namespaces:
> ```yaml
> namespaceSelector:
>   matchLabels:
>     kubernetes.io/metadata.name: prod
> ```

---

## `ipBlock`: External Traffic via CIDR

For origins/destinations outside the cluster (or specific IP ranges):

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 10.0.0.0/16
          except:
            - 10.0.5.0/24
    ports:
      - protocol: TCP
        port: 443
```

Allows HTTPS egress to `10.0.0.0/16` excluding range `10.0.5.0/24`. Note: Pod IP addresses are ephemeral — use `ipBlock` for external IP ranges, not for targeting cluster Pods.

---

## Example 3: Egress with DNS (Common Trap)

When isolating egress traffic, Pods lose DNS resolution capability unless explicitly permitted, breaking most application dependencies. Always include DNS allow rules when configuring egress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-egress
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: db
      ports:
        - protocol: TCP
          port: 5432
    - to: []               # DNS egress to any destination
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

---

## Testing NetworkPolicies

Rapidly verify connectivity using temporary Pods:

```bash
# Can an un-labeled pod reach database service?
$ kubectl run test --rm -it --image=busybox -n prod --restart=Never \
    -- wget -qO- --timeout=2 http://db:5432
wget: download timed out          # blocked by policy ✔

# Same test from a pod carrying the allowed label
$ kubectl run test --rm -it --image=busybox -n prod --restart=Never \
    --labels="app=api" -- nc -zv db 5432
db (10.96.14.3:5432) open         # allowed ✔
```

Leveraging `--labels` with `kubectl run` provides the fastest way to simulate a matching peer Pod.

---

## Key Exam Points

- Without a matching policy, Pods accept and emit **all traffic**.
- `podSelector: {}` + `policyTypes` with empty rule arrays = **default deny** for specified traffic directions.
- NetworkPolicies are **additive (allow-only)**; rules combine via union without conflicts.
- A policy affects strictly the directions specified in `policyTypes`: an Ingress-only policy does not restrict Egress.
- AND vs. OR behavior between `namespaceSelector` and `podSelector` depends on whether fields share a **single list item** or occupy separate list items.
- When restricting egress, remember to **allow DNS (port 53 UDP/TCP)**.
- NetworkPolicy is a **namespaced** resource; `podSelector` matches Pods exclusively within its own namespace (use `namespaceSelector` for cross-namespace targeting).
- Imperative generation is unavailable: construct manifests from official YAML examples.

---

## References

- Official Documentation — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- API Reference — NetworkPolicy v1 (networking.k8s.io): https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Official Task — Declare Network Policy: https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- Automatic Namespace Labels (`kubernetes.io/metadata.name`): https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
