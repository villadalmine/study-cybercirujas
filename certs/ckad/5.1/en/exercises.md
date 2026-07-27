# Guided Exercises — 5.1 NetworkPolicies (CKAD v1.35)

> **Prerequisites:** A cluster with a CNI plugin supporting NetworkPolicies (Calico, Cilium, etc.). On minikube, start with `minikube start --cni=calico`. If your CNI lacks NetworkPolicy support, NetworkPolicy objects will be created in etcd but **have no runtime effect** — keep this in mind when verifying results.

---

## Exercise 1 — Default Behavior: All Traffic Allowed

Before restricting traffic, confirm connectivity when **no NetworkPolicies exist**.

1. Create a working namespace:

   ```bash
   kubectl create namespace netpol-lab
   ```

2. Deploy a `backend` Pod serving HTTP on port 80, labeled `app=backend`:

   ```bash
   kubectl run backend --image=nginx --labels=app=backend -n netpol-lab
   ```

3. Expose it via a Service:

   ```bash
   kubectl expose pod backend --port=80 -n netpol-lab
   ```

4. Deploy a client Pod `frontend` labeled `app=frontend`:

   ```bash
   kubectl run frontend --image=busybox --labels=app=frontend -n netpol-lab -- sleep 3600
   ```

5. Verify both Pods reach `Running` state:

   ```bash
   kubectl get pods -n netpol-lab -o wide --show-labels
   ```

6. Test connectivity from `frontend` to `backend`:

   ```bash
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

   You should see Nginx default HTML output.

**Question 1.1** — If no NetworkPolicy selects a Pod, what incoming (ingress) and outgoing (egress) traffic is permitted?

**Question 1.2** — Are NetworkPolicies *namespaced* or *cluster-scoped* resources? How would you verify using `kubectl`?

---

## Exercise 2 — Default Deny: Blocking All Ingress Traffic

Now apply the standard baseline policy: denying all incoming traffic across the namespace.

1. Create `deny-all-ingress.yaml`:

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

2. Apply manifest:

   ```bash
   kubectl apply -f deny-all-ingress.yaml
   ```

3. Re-test connectivity:

   ```bash
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

   Command should now **fail with a timeout**.

4. Inspect policy and affected Pods:

   ```bash
   kubectl describe networkpolicy default-deny-ingress -n netpol-lab
   ```

**Question 2.1** — What does `podSelector: {}` (empty selector) mean in policy `spec`?

**Question 2.2** — The policy specifies `policyTypes: [Ingress]` while omitting `ingress:` rules. Why does this result in "deny all ingress" rather than "allow all"?

**Question 2.3** — With this policy applied, can `frontend` Pod still **initiate** outgoing connections outside the namespace? Why?

---

## Exercise 3 — Selective Allow via `podSelector`

NetworkPolicies are **additive**: on top of default deny, add a policy permitting traffic exclusively from `frontend` to `backend`.

1. Create `allow-frontend.yaml`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-backend
     namespace: netpol-lab
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
             port: 80
   ```

2. Apply and verify `frontend` connects to `backend`:

   ```bash
   kubectl apply -f allow-frontend.yaml
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

3. Create a third Pod `intruso` **without** label `app=frontend` and verify it remains blocked:

   ```bash
   kubectl run intruso --image=busybox --labels=app=intruso -n netpol-lab -- sleep 3600
   kubectl exec -n netpol-lab intruso -- wget -qO- --timeout=2 http://backend
   ```

   Command should fail with timeout.

4. Exam shortcut test: imperatively relabel `intruso` and re-test connectivity:

   ```bash
   kubectl label pod intruso app=frontend --overwrite -n netpol-lab
   kubectl exec -n netpol-lab intruso -- wget -qO- --timeout=2 http://backend
   ```

   Connection should now succeed.

**Question 3.1** — Two separate `podSelector` fields exist in this policy. What role does each play?

**Question 3.2** — Step 4 demonstrated access changing immediately upon relabeling. What does this reveal regarding how NetworkPolicies evaluate Pod identity?

**Question 3.3** — If `backend` also listened on port 8080, could `frontend` reach port 8080 under this policy?

---

## Exercise 4 — `namespaceSelector` and the AND vs. OR Trap

This tests key conceptual understanding: distinguishing **two elements in `from` array** (OR logic) vs **two selectors within the same array element** (AND logic).

1. Create a second labeled namespace with a client Pod:

   ```bash
   kubectl create namespace externo
   kubectl label namespace externo team=qa
   kubectl run cliente-qa --image=busybox --labels=app=frontend -n externo -- sleep 3600
   ```

2. Test access from that namespace to backend (using FQDN Service DNS):

   ```bash
   kubectl exec -n externo cliente-qa -- wget -qO- --timeout=2 http://backend.netpol-lab
   ```

   Fails: Exercise 3 policy uses standalone `podSelector`, matching **only Pods inside the policy's own namespace**.

3. Replace policy with variant placing `namespaceSelector` and `podSelector` within a **single** list item (single `-`):

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-backend
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: backend
     policyTypes:
       - Ingress
     ingress:
       - from:
           - namespaceSelector:
               matchLabels:
                 team: qa
             podSelector:
               matchLabels:
                 app: frontend
         ports:
           - protocol: TCP
             port: 80
   ```

   ```bash
   kubectl apply -f allow-frontend.yaml
   ```

4. Verify both origins:

   ```bash
   # From external namespace (team=qa, app=frontend): SUCCEEDS
   kubectl exec -n externo cliente-qa -- wget -qO- --timeout=2 http://backend.netpol-lab

   # From netpol-lab namespace (app=frontend, but namespace lacks team=qa): FAILS
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   ```

**Question 4.1** — In step 3 YAML, what conditions must an incoming connection satisfy to be allowed?

**Question 4.2** — If `podSelector` were moved to a separate list element (adding a `-`), how would rule evaluation change? Who would be permitted access?

**Question 4.3** — Why did step 2 access fail from `externo` namespace when `cliente-qa` carried label `app=frontend` matching Exercise 3 policy?

---

## Exercise 5 — Egress: Controlling Outbound Traffic

Now constrain outbound traffic initiated by `frontend`.

1. Apply default deny egress policy affecting only Pods labeled `app=frontend`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-frontend-egress
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: frontend
     policyTypes:
       - Egress
   ```

2. Attempt resolving DNS from `frontend`:

   ```bash
   kubectl exec -n netpol-lab frontend -- nslookup backend.netpol-lab.svc.cluster.local
   ```

   Fails: blocked egress includes CoreDNS queries.

3. Replace policy to allow DNS egress alongside backend access:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-frontend-egress
     namespace: netpol-lab
   spec:
     podSelector:
       matchLabels:
         app: frontend
     policyTypes:
       - Egress
   egress:
     - to:
         - podSelector:
             matchLabels:
               app: backend
       ports:
         - protocol: TCP
           port: 80
     - ports:
         - protocol: UDP
           port: 53
         - protocol: TCP
           port: 53
   ```

4. Verify DNS and backend access succeed while external Internet egress remains blocked:

   ```bash
   kubectl exec -n netpol-lab frontend -- nslookup backend.netpol-lab.svc.cluster.local
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://backend
   kubectl exec -n netpol-lab frontend -- wget -qO- --timeout=2 http://example.com
   ```

   First two commands succeed; third command fails.

5. Teardown:

   ```bash
   kubectl delete namespace netpol-lab externo
   ```

**Question 5.1** — Why did blocking egress break DNS resolution when intent was restricting HTTP egress?

**Question 5.2** — In step 3 DNS egress rule, element contains `ports` but omits `to`. Which destinations are permitted?

**Question 5.3** — Pod `A` has an egress policy permitting connection to `B`, but `B` has a default deny ingress policy with no exceptions. Does connection succeed? What rule applies when policies exist on both sides?

---

<details>
<summary><strong>Answers</strong></summary>

**1.1** — All traffic permitted bi-directionally. Pods default to *non-isolated*; isolation triggers only when selected by at least one NetworkPolicy for specified direction (`Ingress`/`Egress`).

**1.2** — *Namespaced* resource: defined within a namespace and `podSelector` targets Pods inside that namespace (unless `namespaceSelector` is specified). Verified via `kubectl api-resources | grep networkpolic` (`NAMESPACED` column displays `true`).

**2.1** — `podSelector: {}` selects **all Pods in the policy namespace**, isolating all namespace Pods for specified `policyTypes`.

**2.2** — Declaring `Ingress` under `policyTypes` isolates selected Pods for ingress. Without explicit `ingress:` allow rules, zero incoming traffic paths qualify, resulting in total ingress denial.

**2.3** — Yes. Policy specifies `policyTypes: [Ingress]`, leaving egress unconstrained. (Response packets for allowed incoming connections pass through stateful connection tracking).

**3.1** — `spec.podSelector` defines **target Pods protected** by policy (`app=backend`). `ingress.from.podSelector` defines **allowed source Pods** (`app=frontend` in same namespace).

**3.2** — Policies evaluate dynamically against **live Pod labels**, not static names or creation state. Relabeling Pods immediately updates access permissions.

**3.3** — No. Rule explicitly specifies `port: 80/TCP`. Port 8080 remains blocked by default deny. Omitting `ports` section permits all ports.

**4.1** — **AND logic**: incoming connection must originate from a Pod labeled `app=frontend` **AND** reside inside a namespace labeled `team=qa`.

**4.2** — Adding a `-` splits rules into **two independent list elements (OR logic)**: allows traffic from (a) any Pod in namespaces labeled `team=qa` regardless of Pod labels, **OR** (b) any Pod labeled `app=frontend` in `netpol-lab`.

**4.3** — Standalone `podSelector` inside `from` matches Pods **exclusively inside policy's own namespace** (`netpol-lab`). `cliente-qa` carried correct Pod labels but resided in wrong namespace.

**4.4** — Blocking egress drops **all** outbound traffic including UDP/TCP port 53 DNS queries to CoreDNS. Without DNS, domain name resolution fails. Egress isolation rules must explicitly permit port 53.

**5.2** — `egress` element omitting `to` permits traffic to **any destination IP/Pod/namespace**, restricted strictly to listed ports (53 UDP/TCP).

**5.3** — Fails. Connections require explicit permission from **both ends**: origin egress policy AND target ingress policy. `B`'s ingress isolation blocks connection despite `A`'s egress allow rule.

</details>
