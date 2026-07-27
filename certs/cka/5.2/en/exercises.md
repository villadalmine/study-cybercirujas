# Guided Exercises — 5.2 Define and enforce Network Policies

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with a NetworkPolicy-compliant CNI driver (Calico, Cilium, etc.).

```bash
kubectl create namespace netpol-lab
```

---

## Exercise 1 — Default Isolation and Environment Verification

1. Deploy target backend server Pod with label `role=backend`:
   ```bash
   kubectl run backend --image=nginx --labels="role=backend" --namespace=netpol-lab --port=80
   kubectl expose pod backend --namespace=netpol-lab --port=80 --name=backend-svc
   ```
2. Deploy client Pods:
   ```bash
   kubectl run client-a --image=busybox --labels="role=frontend" --namespace=netpol-lab -- sleep 3600
   kubectl run client-b --image=busybox --labels="role=other" --namespace=netpol-lab -- sleep 3600
   ```
3. Confirm bi-directional connectivity prior to policy application:
   ```bash
   kubectl exec -n netpol-lab client-a -- wget -qO- --timeout=2 backend-svc
   kubectl exec -n netpol-lab client-b -- wget -qO- --timeout=2 backend-svc
   ```

---

## Exercise 2 — Default Deny Ingress

1. Manifest file `default-deny-ingress.yaml`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: netpol-lab
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
   ```
2. Apply policy and verify connectivity timeouts:
   ```bash
   kubectl apply -f default-deny-ingress.yaml
   kubectl exec -n netpol-lab client-a -- wget -qO- --timeout=2 backend-svc
   ```

---

## Exercise 3 — Allow Ingress from Specific Labels

1. Manifest `allow-frontend.yaml` restricting ingress to `role=frontend` Pods:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         role: backend
     policyTypes:
       - Ingress
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 role: frontend
         ports:
           - protocol: TCP
             port: 80
   ```
2. Apply policy and verify `client-a` succeeds while `client-b` fails:
   ```bash
   kubectl apply -f allow-frontend.yaml
   kubectl exec -n netpol-lab client-a -- wget -qO- --timeout=2 backend-svc
   kubectl exec -n netpol-lab client-b -- wget -qO- --timeout=2 backend-svc
   ```

---

## Exercise 4 — Allow Ingress Across Namespaces

1. Create target namespace and partner client:
   ```bash
   kubectl create namespace partner-ns
   kubectl label namespace partner-ns team=partner
   kubectl run client-c --image=busybox --namespace=partner-ns -- sleep 3600
   ```
2. Manifest cross-namespace ingress policy `allow-partner-ns.yaml`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-partner-ns
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         role: backend
     policyTypes:
       - Ingress
     ingress:
       - from:
           - namespaceSelector:
               matchLabels:
                 team: partner
         ports:
           - protocol: TCP
             port: 80
   ```
3. Apply and test cross-namespace connectivity:
   ```bash
   kubectl apply -f allow-partner-ns.yaml
   kubectl exec -n partner-ns client-c -- wget -qO- --timeout=2 backend-svc.netpol-lab.svc.cluster.local
   ```

---

## Teardown

```bash
kubectl delete namespace netpol-lab partner-ns
```

---

<details>
<summary>View Answers</summary>

1. Unselected Pods allow all ingress/egress traffic by default.
2. `podSelector: {}` selects all Pods in the target namespace.
3. Combining `podSelector` and `namespaceSelector` inside a single list element uses AND logic.
4. Multiple matching NetworkPolicies combine rules using OR logic (union).

</details>
