# CKS 1.1 — Use Network Security Policies to Restrict Cluster Level Access

## Guided Exercises

**Exam domain:** Cluster Setup (weight of this topic: 3)
**Estimated lab time:** 90–120 minutes

---

## Before You Start

### What you need

- A Kubernetes cluster **whose CNI plugin enforces `NetworkPolicy`**. This is the single most common reason a lab "doesn't work": the API server happily accepts a `NetworkPolicy` object even when nothing in the cluster enforces it.
- `kubectl` v1.34 matching the cluster version.
- Optionally `jq` for the audit exercise.

### Mental model you are building

`NetworkPolicy` is an **allow-list, namespaced, L3/L4** firewall applied to **pods**, not to Services:

1. A pod is *unselected* by any policy → all traffic allowed (default-allow).
2. As soon as **any** policy selects a pod for a direction (`Ingress` / `Egress`), that direction becomes **default-deny** for that pod, and only the union of all matching rules is allowed.
3. Policies are purely **additive**. There is no `deny` action, no priority, and no ordering in `networking.k8s.io/v1`.

Keep those three sentences in your head for every exercise below.

---

## Exercise 0 — Build a lab cluster that actually enforces policies

### Steps

1. Write a `kind` config that **disables the default CNI**, so you can install a policy-capable one:

```yaml
# kind-cks-netpol.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. Create the cluster:

```bash
kind create cluster --name cks-netpol --config kind-cks-netpol.yaml
kubectl get nodes
```

The nodes will report `NotReady` — expected, there is no CNI yet.

3. Install Calico. Replace `<version>` with the current release tag shown on the Calico install page (for example `v3.30.0`):

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/<version>/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=180s
kubectl get nodes
```

> Alternative: any policy-enforcing CNI works — Cilium (`cilium install`), Antrea, Weave, or a managed cluster with Calico/Cilium enabled. Every YAML in this lab is vendor-neutral upstream `networking.k8s.io/v1`.

4. Create the namespaces you will use, and inspect the labels Kubernetes puts on them automatically:

```bash
kubectl create namespace prod
kubectl create namespace dev
kubectl create namespace monitoring
kubectl get ns --show-labels
```

5. Deploy the target workload in `prod` and a second one in `dev`:

```bash
kubectl -n prod run web --image=nginx:1.27-alpine --labels="app=web,tier=frontend" --port=80
kubectl -n prod expose pod web --port=80 --name=web

kubectl -n prod run db --image=nginx:1.27-alpine --labels="app=db,tier=backend" --port=80
kubectl -n prod expose pod db --port=80 --name=db

kubectl -n dev run scanner --image=nginx:1.27-alpine --labels="app=scanner" --port=80

kubectl -n prod wait --for=condition=Ready pod --all --timeout=120s
kubectl get pods -A -o wide
```

6. Prove the CNI enforces policy before trusting any later result. Apply a throwaway deny-all and confirm traffic actually breaks:

```bash
kubectl -n prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: smoke-test-deny
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF

kubectl -n prod run probe --rm -it --restart=Never \
  --image=busybox:1.36 --labels="app=probe" \
  -- wget -q -O- -T 3 http://web
```

7. Delete the smoke test policy:

```bash
kubectl -n prod delete netpol smoke-test-deny
```

### Checkpoint questions

- **Q1.** In step 4 you never applied a label to the namespaces, yet `--show-labels` printed one on each. Which label is it, who sets it, and why does it matter enormously for `NetworkPolicy`?
- **Q2.** In step 6, what output tells you the CNI *is* enforcing policy, and what output would tell you it is *not*? Why is "the object was created successfully" not evidence of enforcement?
- **Q3.** The `smoke-test-deny` policy has no `ingress:` key at all. Is that a syntax error? What traffic does it permit?
- **Q4.** You applied the policy in `prod`. Did it affect the `scanner` pod in `dev`? Justify your answer from the API object itself.

---

## Exercise 1 — Establish a baseline connectivity map

You cannot verify a restriction if you never measured the "before" state.

### Steps

1. Create a small reusable probe function in your shell:

```bash
probe() {   # usage: probe <client-ns> <client-label> <url>
  kubectl -n "$1" run "probe-$RANDOM" --rm -i --restart=Never \
    --image=busybox:1.36 --labels="$2" \
    -- wget -q -O- -T 3 "$3" >/dev/null 2>&1 \
    && echo "ALLOWED  $1/$2 -> $3" \
    || echo "BLOCKED  $1/$2 -> $3"
}
```

2. Record the baseline in every direction you care about:

```bash
probe prod  app=client  http://web
probe prod  app=client  http://db
probe dev   app=scanner http://web.prod.svc.cluster.local
probe dev   app=scanner http://db.prod.svc.cluster.local
```

3. Capture the pod IP of `web` and probe it directly, bypassing the Service:

```bash
WEB_IP=$(kubectl -n prod get pod web -o jsonpath='{.status.podIP}')
echo "$WEB_IP"
probe dev app=scanner "http://$WEB_IP"
```

4. Confirm name resolution works from an unrestricted pod:

```bash
kubectl -n prod run dns --rm -i --restart=Never --image=busybox:1.36 \
  -- nslookup web.prod.svc.cluster.local
```

### Checkpoint questions

- **Q5.** All four probes in step 2 returned `ALLOWED`. What is the default network posture of a fresh Kubernetes namespace, and is that a Kubernetes bug or a design decision?
- **Q6.** Step 3 hit the pod IP directly and got the same result as hitting the Service name. What does that tell you about the layer at which `NetworkPolicy` operates? Can you write a policy that allows traffic to a **Service** but denies traffic to the **pod IP** behind it?
- **Q7.** Why is it worth running step 4 *now*, before you write any egress policy?

---

## Exercise 2 — Default-deny ingress as a namespace baseline

### Steps

1. Write the baseline policy:

```yaml
# 01-default-deny-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f 01-default-deny-ingress.yaml
```

2. Confirm which pods the policy selects — this is exactly how you debug a policy that "doesn't apply":

```bash
kubectl -n prod get pods --show-labels
kubectl -n prod get pods -l ''      # empty selector == every pod
```

3. Re-run the baseline probes:

```bash
probe prod app=client  http://web
probe dev  app=scanner http://web.prod.svc.cluster.local
probe prod app=client  http://db
```

4. Verify that egress out of `prod` is still wide open:

```bash
kubectl -n prod run egresstest --rm -i --restart=Never \
  --image=busybox:1.36 \
  -- wget -q -O- -T 3 http://scanner.dev.svc.cluster.local >/dev/null 2>&1 \
  && echo "prod -> dev egress ALLOWED" || echo "prod -> dev egress BLOCKED"
```

5. Inspect what the API server actually stored, including defaulted fields:

```bash
kubectl -n prod get netpol default-deny-ingress -o yaml
kubectl -n prod describe netpol default-deny-ingress
```

### Checkpoint questions

- **Q8.** Step 4 shows `prod` pods can still *initiate* connections to `dev`. Explain why a default-deny **ingress** policy does not stop data exfiltration, and what an attacker with RCE in a `prod` pod could still do.
- **Q9.** Remove the `policyTypes` field entirely from `01-default-deny-ingress.yaml` and re-apply. What value does the API server default it to, and does the policy's behaviour change? Now add an `egress:` rule but still omit `policyTypes` — what gets defaulted then?
- **Q10.** `podSelector: {}` selects all pods. What would `podSelector:` with no value at all (i.e. `null`) do? What about `podSelector: {matchLabels: {}}`?
- **Q11.** Does this policy block traffic from the kubelet, e.g. an HTTP readiness probe against `web:80`? Test it by adding a probe to the pod and reason about the source IP.

---

## Exercise 3 — Open exactly one path: podSelector plus ports

### Steps

1. Allow only `app=client` pods inside `prod` to reach `web` on TCP/80:

```yaml
# 02-allow-client-to-web.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-web
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: client
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 02-allow-client-to-web.yaml
```

2. Test the allowed path, a wrong-label path, and the still-closed `db`:

```bash
probe prod app=client  http://web     # expect ALLOWED
probe prod app=scanner http://web     # expect BLOCKED (label mismatch)
probe prod app=client  http://db      # expect BLOCKED
probe dev  app=scanner http://web.prod.svc.cluster.local   # expect BLOCKED
```

3. Now test the port dimension. Add a second container port to the picture by targeting a port you did not allow:

```bash
kubectl -n prod run web8080 --image=nginx:1.27-alpine --labels="app=web" --port=80 \
  --overrides='{"spec":{"containers":[{"name":"web8080","image":"nginx:1.27-alpine","command":["sh","-c","sed -i s/80/8080/ /etc/nginx/conf.d/default.conf && nginx -g \"daemon off;\""],"ports":[{"containerPort":8080}]}]}}'
kubectl -n prod wait --for=condition=Ready pod/web8080 --timeout=60s

W8=$(kubectl -n prod get pod web8080 -o jsonpath='{.status.podIP}')
probe prod app=client "http://$W8:8080"
```

4. Extend the policy to a **port range** using `endPort`:

```yaml
# 03-allow-client-portrange.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-portrange
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: client
      ports:
        - protocol: TCP
          port: 8000
          endPort: 8090
```

```bash
kubectl apply -f 03-allow-client-portrange.yaml
probe prod app=client "http://$W8:8080"
```

5. Delete the extra pod and the range policy when done:

```bash
kubectl -n prod delete pod web8080
kubectl -n prod delete netpol allow-client-portrange
```

### Checkpoint questions

- **Q12.** Two policies now select the `web` pod: `default-deny-ingress` and `allow-client-to-web`. Which one "wins"? State the combination rule precisely.
- **Q13.** In step 3 the `web8080` pod carries `app=web`, so `allow-client-to-web` selects it. Why was port 8080 still blocked before step 4? Which field caused the block — the `from` or the `ports`?
- **Q14.** In step 4 you replaced the port with a range. What are the two hard constraints on `endPort` (relative to `port`, and regarding named ports)?
- **Q15.** An attacker compromises the `scanner` pod in `prod` and can run `kubectl`. They have `patch` on pods. Describe the one-command attack that defeats `allow-client-to-web`, and name the RBAC verb you must deny to prevent it.
- **Q16.** If you delete `default-deny-ingress` and keep only `allow-client-to-web`, what changes for `web`? What changes for `db`?

---

## Exercise 4 — Cross-namespace rules and the AND/OR trap

This is the highest-yield concept in the whole topic, and the most frequently failed exam item.

### Steps

1. Label the namespaces you want to reference:

```bash
kubectl label namespace monitoring purpose=monitoring
kubectl label namespace dev tier=untrusted
kubectl get ns --show-labels
```

2. Deploy a scraper in `monitoring`:

```bash
kubectl -n monitoring run scraper --image=busybox:1.36 --labels="app=scraper" \
  --command -- sleep 86400
kubectl -n monitoring wait --for=condition=Ready pod/scraper --timeout=60s
```

3. Apply **Variant A** — a single `from` element containing *both* selectors:

```yaml
# 04a-and-variant.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-scraper
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              purpose: monitoring
          podSelector:
            matchLabels:
              app: scraper
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 04a-and-variant.yaml
```

4. Test Variant A from three different sources:

```bash
probe monitoring app=scraper http://web.prod.svc.cluster.local   # expect ALLOWED
probe monitoring app=other   http://web.prod.svc.cluster.local   # expect ?
probe prod       app=scraper http://web                          # expect ?
```

5. Now apply **Variant B** — the same two selectors as *two separate list items*. Note the extra `-`:

```yaml
# 04b-or-variant.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-scraper
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              purpose: monitoring
        - podSelector:
            matchLabels:
              app: scraper
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 04b-or-variant.yaml
```

6. Re-run the same three probes:

```bash
probe monitoring app=scraper http://web.prod.svc.cluster.local
probe monitoring app=other   http://web.prod.svc.cluster.local
probe prod       app=scraper http://web
```

7. Try to reference a namespace with no custom labels, using only the automatic one:

```yaml
# 04c-metadata-name.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dev-namespace
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: dev
```

```bash
kubectl apply -f 04c-metadata-name.yaml
probe dev app=scanner http://db.prod.svc.cluster.local
```

8. Restore Variant A (the secure one) and clean up the `dev` rule:

```bash
kubectl apply -f 04a-and-variant.yaml
kubectl -n prod delete netpol allow-dev-namespace
```

### Checkpoint questions

- **Q17.** Write out, in one sentence each, exactly what Variant A and Variant B allow. What single YAML character is the difference?
- **Q18.** In Variant B, `podSelector: {matchLabels: {app: scraper}}` appears without a `namespaceSelector`. Which namespace does a bare `podSelector` inside a `from` block refer to?
- **Q19.** Variant B is a real security incident waiting to happen. Describe a concrete escalation path an attacker gets from Variant B that Variant A denies.
- **Q20.** Step 7 selected the `dev` namespace without ever labelling it. Why did that work? Is relying on `kubernetes.io/metadata.name` a good or a bad idea from a security standpoint, given that it cannot be changed to a value other than the namespace name?
- **Q21.** How would you allow **every pod in every namespace** to reach `web:80`? Write the `from` block. Now write the `from` block that allows **every pod in the policy's own namespace only**.

---

## Exercise 5 — Default-deny egress, and the DNS trap

### Steps

1. Apply an egress lockdown for the whole `prod` namespace:

```yaml
# 05-default-deny-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

```bash
kubectl apply -f 05-default-deny-egress.yaml
```

2. Observe how the failure presents itself. Run these two probes and compare the error text carefully:

```bash
kubectl -n prod run t1 --rm -i --restart=Never --image=busybox:1.36 \
  -- nslookup db.prod.svc.cluster.local

DB_IP=$(kubectl -n prod get pod db -o jsonpath='{.status.podIP}')
kubectl -n prod run t2 --rm -i --restart=Never --image=busybox:1.36 \
  -- wget -q -O- -T 3 "http://$DB_IP"
```

3. Find the CoreDNS pods and their labels — you need them for a precise rule:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels
kubectl -n kube-system get svc kube-dns
```

4. Add a DNS egress allowance scoped to CoreDNS only:

```yaml
# 06-allow-dns-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
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

```bash
kubectl apply -f 06-allow-dns-egress.yaml

kubectl -n prod run t3 --rm -i --restart=Never --image=busybox:1.36 \
  -- nslookup db.prod.svc.cluster.local
```

5. Confirm that name resolution now works but the actual connection still does not:

```bash
kubectl -n prod run t4 --rm -i --restart=Never --image=busybox:1.36 \
  -- wget -q -O- -T 3 http://db
```

6. Allow the intended east-west path — `app=web` to `app=db` on TCP/80 — writing **both** halves of the path:

```yaml
# 07-web-to-db.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-egress-to-db
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: db
      ports:
        - protocol: TCP
          port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-ingress-from-web
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
              app: web
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 07-web-to-db.yaml
kubectl -n prod exec web -- sh -c 'apk add --no-cache curl >/dev/null 2>&1; curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://db'
```

### Checkpoint questions

- **Q22.** In step 2, `nslookup` failed even though you never wrote a rule about DNS. Explain the mechanism. Why is this the number-one cause of outages when teams roll out egress policies?
- **Q23.** Why did step 4 need a `namespaceSelector` *and* a `podSelector` inside the same `from`/`to` element, rather than just `podSelector: {k8s-app: kube-dns}`?
- **Q24.** Your rule allows UDP/53 **and** TCP/53. Under what circumstances does a resolver fall back to TCP, and what breaks if you allow only UDP?
- **Q25.** In step 6 you wrote two policies for one logical connection. Explain why one policy is not enough, and identify precisely which pods are being selected by each of the two.
- **Q26.** Does the return traffic (the HTTP response from `db` back to `web`) require its own rule? What property of the enforcement engine makes the answer what it is?
- **Q27.** A teammate proposes replacing the DNS rule with `- to: - ipBlock: {cidr: 10.96.0.10/32}` plus ports 53. Name two ways this is more brittle than the selector-based rule.

---

## Exercise 6 — ipBlock, `except`, and blocking the cloud metadata endpoint

Restricting egress to link-local metadata (`169.254.169.254`) is a classic CKS scenario: that endpoint hands out node IAM credentials to anything that can reach it.

### Steps

1. Deploy a workload that represents an internet-facing, untrusted service:

```bash
kubectl -n prod run dmz --image=nicolaka/netshoot --labels="app=dmz" \
  --command -- sleep 86400
kubectl -n prod wait --for=condition=Ready pod/dmz --timeout=120s
```

2. Note that `default-deny-egress` currently blocks it. Write a policy that allows broad egress but carves out the metadata endpoint:

```yaml
# 08-dmz-egress-no-metadata.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dmz-egress-block-metadata
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16
              - 10.96.0.0/12
              - 192.168.0.0/16
```

```bash
kubectl apply -f 08-dmz-egress-no-metadata.yaml
```

3. Verify the carve-out:

```bash
kubectl -n prod exec dmz -- nc -z -w 2 169.254.169.254 80 \
  && echo "metadata REACHABLE" || echo "metadata BLOCKED"

kubectl -n prod exec dmz -- nc -z -w 2 1.1.1.1 443 \
  && echo "internet REACHABLE" || echo "internet BLOCKED"
```

4. Now test DNS from the `dmz` pod and observe what your `except` blocks broke:

```bash
kubectl -n prod exec dmz -- dig +short +time=2 +tries=1 kubernetes.default.svc.cluster.local
```

5. Try applying an `except` entry that is *outside* the `cidr` and read the API server's response:

```bash
kubectl -n prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bad-except
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.0/8
            except:
              - 192.168.5.0/24
EOF
```

6. Try mixing `ipBlock` with a selector in the same peer element:

```bash
kubectl -n prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bad-mixed-peer
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
          podSelector:
            matchLabels:
              app: db
EOF
```

7. Allow egress to the Kubernetes API server. Find both addresses involved:

```bash
kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}{"\n"}'
```

```yaml
# 09-allow-apiserver-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-apiserver-egress
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.96.0.1/32      # kubernetes Service ClusterIP
        - ipBlock:
            cidr: 172.18.0.0/16     # control-plane node IPs — adjust to your cluster
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443
```

```bash
kubectl apply -f 09-allow-apiserver-egress.yaml
kubectl -n prod exec dmz -- curl -sk -m 3 -o /dev/null -w "%{http_code}\n" https://kubernetes.default.svc
```

### Checkpoint questions

- **Q28.** Step 5 and step 6 both failed. Quote the *category* of each failure and state the two structural rules of `NetworkPolicyPeer` they demonstrate.
- **Q29.** In step 4, DNS broke. Which `except` entry caused it, and what are two different correct ways to fix the policy while still blocking metadata?
- **Q30.** Why did the API-server rule need *both* the Service ClusterIP and the node IP range? Which component rewrites the destination address, and at what point relative to policy evaluation does that happen?
- **Q31.** `ipBlock` on an **ingress** rule matches the packet's source IP. Explain why a `NodePort` Service can make that rule useless, and what Service field restores the real client IP.
- **Q32.** Blocking `169.254.169.254` with a `NetworkPolicy` is a *namespace-scoped* control. Name two gaps that leave the metadata endpoint reachable despite this policy, and the pod-spec / admission control you would use to close them.

---

## Exercise 7 — Cluster-level posture: audit and rollout

"Cluster level access" in the exam objective means you must think beyond one namespace. `NetworkPolicy` has no cluster-scoped object, so a cluster-wide baseline is *n* identical objects plus a control that keeps them there.

### Steps

1. Inventory every policy in the cluster:

```bash
kubectl get networkpolicies --all-namespaces
kubectl get netpol -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.podSelector,TYPES:.spec.policyTypes'
```

2. Find namespaces that lack a default-deny **ingress** baseline:

```bash
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  count=$(kubectl get netpol -n "$ns" -o json 2>/dev/null | jq '
    [ .items[]
      | select(.spec.podSelector == {})
      | select((.spec.policyTypes // ["Ingress"]) | index("Ingress"))
    ] | length')
  [ "${count:-0}" -eq 0 ] && echo "MISSING default-deny-ingress: $ns"
done
```

3. Repeat for egress by swapping `"Ingress"` for `"Egress"` in the `index()` call, and note which system namespaces show up.

4. Determine which pods a given policy actually protects, using its own selector:

```bash
kubectl -n prod get netpol allow-client-to-web -o jsonpath='{.spec.podSelector.matchLabels}{"\n"}'
kubectl -n prod get pods -l app=web -o name
```

5. Find pods that **no** policy selects in a namespace that has a default-deny — a mismatch here means a pod is silently unprotected because its labels changed:

```bash
kubectl -n prod get pods -o custom-columns='POD:.metadata.name,LABELS:.metadata.labels'
```

6. Apply the deny-all baseline (both directions) to a new namespace and verify the pattern is reusable:

```bash
kubectl create namespace payments
kubectl -n payments apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF
kubectl -n payments get netpol default-deny-all -o yaml
```

7. Confirm you did not accidentally lock out the control plane. Check that pods in `kube-system` are untouched and the cluster is healthy:

```bash
kubectl get netpol -n kube-system
kubectl -n kube-system get pods
kubectl get --raw='/readyz?verbose' | tail -5
```

### Checkpoint questions

- **Q33.** In step 6 you omitted `namespace:` from `metadata` and relied on `-n payments`. Is a `NetworkPolicy` cluster-scoped or namespaced? What is the consequence for enforcing a *cluster-wide* baseline?
- **Q34.** A developer creates a brand-new namespace. Is it protected by your baseline? Name two mechanisms that could enforce the baseline automatically on namespace creation.
- **Q35.** In step 5 you looked for pods no policy selects. Describe the failure mode where a policy exists, looks correct in review, and protects nothing.
- **Q36.** Why would applying `default-deny-all` to `kube-system` be dangerous? Name two specific things that would break.
- **Q37.** `NetworkPolicy` v1 has no `deny` action and no priority. Given only v1, how do you express "namespace `dev` must never reach namespace `prod`, no matter what policy the `prod` team writes"? Is it actually possible?

---

## Exercise 8 — (Optional, beyond core v1) Cluster-scoped policy with AdminNetworkPolicy

The `policy.networking.k8s.io` API adds cluster-scoped, ordered, explicitly-denying policy. It is **not** part of core Kubernetes: it ships as CRDs from the SIG-Network `network-policy-api` project and requires CNI support (Calico, Cilium, OVN-Kubernetes). Treat this as context for *why* v1 alone cannot express a cluster guardrail — do not expect it as an exam task unless the cluster clearly has it installed.

### Steps

1. Check whether the API is present:

```bash
kubectl api-resources | grep -i adminnetworkpolicy || echo "ANP not installed"
```

2. If present, inspect an example that a namespace owner cannot override:

```yaml
apiVersion: policy.networking.k8s.io/v1alpha1
kind: AdminNetworkPolicy
metadata:
  name: deny-untrusted-to-prod
spec:
  priority: 10
  subject:
    namespaces:
      matchLabels:
        kubernetes.io/metadata.name: prod
  ingress:
    - name: "deny-from-untrusted"
      action: Deny
      from:
        - namespaces:
            matchLabels:
              tier: untrusted
```

3. Contrast the field names against `networking.k8s.io/v1` and note the differences: `priority`, `action`, `subject`, and cluster scope.

### Checkpoint questions

- **Q38.** Which three capabilities does `AdminNetworkPolicy` provide that `networking.k8s.io/v1` structurally cannot?
- **Q39.** What does the `Pass` action do, and why is it the key to "cluster admin sets a floor, namespace owners decide above it"?
- **Q40.** `kubectl api-resources` returned nothing for ANP but `kubectl apply` of the manifest above still failed with an error. Given ANP is a CRD, what error do you expect, and what does that tell you about validating an exam cluster's capabilities before writing YAML?

---

## Cleanup

```bash
kubectl delete namespace prod dev monitoring payments
kind delete cluster --name cks-netpol
```

---

## Reference patterns worth memorising

| Goal | Key fields |
|---|---|
| Deny all ingress in a namespace | `podSelector: {}` + `policyTypes: [Ingress]`, no `ingress:` |
| Deny all egress in a namespace | `podSelector: {}` + `policyTypes: [Egress]`, no `egress:` |
| Deny everything | `podSelector: {}` + `policyTypes: [Ingress, Egress]` |
| Allow all ingress | `ingress: [{}]` |
| Allow from one namespace, any pod | `from: [{namespaceSelector: {matchLabels: {...}}}]` |
| Allow from one pod in one namespace (**AND**) | one `from` item with both `namespaceSelector` and `podSelector` |
| Allow from any namespace | `from: [{namespaceSelector: {}}]` |
| Allow DNS | egress to `kube-system` / `k8s-app=kube-dns`, UDP **and** TCP 53 |
| Allow CIDR minus a hole | `ipBlock: {cidr: ..., except: [...]}` — `except` must be inside `cidr` |

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** The label is `kubernetes.io/metadata.name: <namespace-name>`. The API server sets it automatically on every namespace (the `NamespaceDefaultLabelName` feature, GA since Kubernetes 1.21) and the value is immutable — it always equals the namespace name. It matters because `namespaceSelector` matches on **namespace labels only**; there is no way to reference a namespace by name in the `NetworkPolicy` schema. Without this automatic label you would have to manually label every namespace before you could write a cross-namespace rule, and a forgotten label would silently make a rule match nothing.

**Q2.** Enforcement is proven by the probe **failing**: `wget` hangs for the 3-second timeout and the pod exits non-zero, so `kubectl run` reports `pod "probe" deleted` with an error / non-zero exit. If the CNI does **not** enforce policy, the probe still returns the nginx welcome HTML instantly. Successful creation of the object proves only that the API server accepted a well-formed `networking.k8s.io/v1` resource — the API server stores `NetworkPolicy` objects unconditionally and never checks whether any component reads them. Enforcement is entirely the CNI's job, so "created" and "enforced" are independent facts.

**Q3.** Not a syntax error. `ingress` is an optional field; omitting it means "the list of allow-rules is empty". Combined with `policyTypes: [Ingress]` and `podSelector: {}`, it selects every pod in `prod` for ingress and allows nothing, i.e. default-deny ingress. It permits **zero** inbound traffic to any pod in the namespace. (Note the difference from `ingress: [{}]`, which is a single empty rule that allows *all* inbound traffic.)

**Q4.** No. `NetworkPolicy` is a namespaced resource, and `spec.podSelector` is evaluated **only within the policy's own namespace**. `metadata.namespace: prod` therefore scopes the entire object to `prod`; no field in the object can select pods elsewhere. Nothing in `dev` is affected. This is the structural reason a "cluster-wide default deny" requires one object per namespace.

**Q5.** A fresh namespace is fully open — any pod can reach any other pod in any namespace, and any external address. This is a deliberate design decision, not a bug: Kubernetes' flat network model guarantees every pod can reach every pod without NAT, and `NetworkPolicy` is opt-in restriction layered on top. The security consequence is that isolation must be *added*; the safe default has to be created by an operator.

**Q6.** `NetworkPolicy` operates at L3/L4 on **pod IPs** (and CIDRs), not on Services. Traffic to a ClusterIP is DNAT'd by kube-proxy (or the CNI's replacement) to a backend pod IP, and the policy is evaluated against that final pod IP. Therefore you **cannot** write a policy that allows Service access but denies direct pod-IP access — from the enforcement engine's point of view they are the same packet. Anything relying on "only reachable via the Service" is not a security control.

**Q7.** Because once you apply a default-deny **egress** policy, DNS breaks first and every other symptom becomes ambiguous. Confirming that resolution works beforehand means that when `nslookup` later fails you know the policy caused it, rather than a broken CoreDNS deployment or a bad `resolv.conf`. More generally: never introduce a restriction without a known-good "before" measurement.

**Q8.** The policy sets `policyTypes: [Ingress]` only, so the egress direction of every `prod` pod remains unselected and therefore default-allow. An attacker with code execution in a `prod` pod can still open outbound connections: exfiltrate data to an external C2 host, pull second-stage tooling, scan and connect to other namespaces' pods (including `db`, whose *ingress* is denied only for inbound — but the attacker's own pod initiating outbound to `db` is inbound *to db*, so that specific hop is blocked; hops to any pod in `dev`, `monitoring`, or the internet are not), and reach the cloud metadata endpoint. Ingress-only policies contain lateral movement *toward* protected pods but do nothing about exfiltration.

**Q9.** With `ingress` and `egress` both absent, `policyTypes` defaults to `["Ingress"]` — behaviour is unchanged, still default-deny ingress. The defaulting rule is: `Ingress` is always included; `Egress` is included only if the policy has at least one `egress` rule. So if you add an `egress:` block and still omit `policyTypes`, the API server defaults it to `["Ingress", "Egress"]` — meaning you have silently also turned on ingress default-deny for those pods. This is why the safe habit is to write `policyTypes` explicitly, always.

**Q10.** `podSelector: {}` is an empty `LabelSelector`, which by Kubernetes convention matches **all** pods in the namespace. `podSelector:` with a null value is invalid here — `podSelector` is a required field of `NetworkPolicySpec`, so the API server rejects the object. `podSelector: {matchLabels: {}}` is an empty match-labels map inside the selector, which also evaluates to "match everything" — semantically identical to `{}`. (The dangerous cousin is a `namespaceSelector: {}` inside a `from` block, which means "all namespaces" — not "no namespaces".)

**Q11.** In practice the readiness probe keeps working, but not because of anything in the policy: the kubelet probes the pod from the **node's** network namespace, and most CNIs (Calico, Cilium) explicitly allow host-to-local-pod traffic so that probes and node-local health checks are never broken by policy. The source IP is the node IP, not a pod IP, so no `podSelector` could ever match it; if you needed to allow it explicitly you would use an `ipBlock` with the node CIDR. The lesson: `NetworkPolicy` governs pod-to-pod and pod-to-external traffic; host-originated traffic to local pods is a CNI-specific carve-out you must verify rather than assume.

**Q12.** Neither "wins" — policies are strictly **additive (OR)**. The effective rule for a pod is: if any policy selects it for a direction, that direction is deny-by-default, and the permitted set is the *union* of every matching rule across every policy. So `web` has ingress denied by default (from `default-deny-ingress`) and one hole punched in it (from `allow-client-to-web`). There is no precedence, no ordering, and no way for a later policy to subtract from an earlier one.

**Q13.** The `ports` field caused the block. `allow-client-to-web` does select `web8080` (it carries `app=web`), and the source `app=client` matched the `from` clause — but the rule permits only `protocol: TCP, port: 80`. A rule's `ports` list restricts the destination port on the *selected* (target) pod; anything not listed stays denied. Omitting `ports` entirely would have allowed all ports.

**Q14.** (1) `endPort` must be **greater than or equal to** `port`, and both must be within 1–65535; the API server rejects `endPort < port`. (2) `endPort` may only be used when `port` is a **numeric** value — you cannot combine `endPort` with a named port (`port: http`), because a name resolves per-pod to a single number and a range is meaningless. Also note the CNI must support port ranges; the field is stable in the API since v1.25 but an old plugin may ignore it.

**Q15.** The attacker runs `kubectl -n prod label pod scanner app=client --overwrite` (or `kubectl patch`), giving their pod the label the policy trusts, and immediately gains access to `web`. `NetworkPolicy` identity is **labels**, and labels are mutable via the normal pod-update path. The verb to deny is `patch` (and `update`) on `pods` — a workload service account should not be able to modify pod metadata. This is the general lesson: network policy is only as strong as the RBAC that protects the labels it trusts.

**Q16.** For `web`: nothing changes. `allow-client-to-web` selects `web` for `Ingress`, which by itself already makes `web` default-deny inbound; the explicit deny-all was redundant *for that pod*. For `db`: everything changes — no policy selects `db` any more, so it reverts to default-allow and becomes reachable from every pod in the cluster. This is exactly why the namespace-wide `podSelector: {}` baseline matters: targeted policies protect only what they select.

**Q17.** Variant A allows: *pods labelled `app=scraper` **that are in** a namespace labelled `purpose=monitoring`*. Variant B allows: *any pod in any namespace labelled `purpose=monitoring`,* **OR** *any pod labelled `app=scraper` in the policy's own namespace (`prod`)*. The difference is one `-`: whether `podSelector` is a key of the same list element as `namespaceSelector` (AND) or the start of a new list element (OR).

**Q18.** The policy's **own** namespace — here, `prod`. A `podSelector` inside a `from`/`to` element with no accompanying `namespaceSelector` is implicitly scoped to the namespace the `NetworkPolicy` lives in. To select pods in a different namespace you must pair it with a `namespaceSelector` in the *same* element.

**Q19.** Under Variant B, any pod that manages to carry the label `app=scraper` in `prod` gets access to `web` — so an attacker who can create or relabel a pod inside `prod` (or a legitimate but unrelated `prod` workload that happens to use that label) reaches `web:80` without ever touching the `monitoring` namespace. Additionally, *every* pod in `monitoring` gets access, not just the scraper, so compromising any monitoring sidecar or exporter grants the same reach. Variant A requires both conditions simultaneously, which an attacker confined to one namespace cannot satisfy.

**Q20.** It worked because `kubernetes.io/metadata.name` is applied automatically to every namespace by the API server, so `dev` already had it. From a security standpoint it is **good**: the value is enforced by the API server to equal the namespace name and cannot be forged or set to another namespace's name, so it is a trustworthy identifier. Custom labels like `tier: untrusted` are the weaker option — anyone with `update` on namespaces can add or remove them, so a rule keyed on a custom label is only as strong as namespace RBAC. Use `kubernetes.io/metadata.name` when you mean one specific namespace; use custom labels for group semantics, and lock down who can set them.

**Q21.** All pods in all namespaces:
```yaml
from:
  - namespaceSelector: {}
```
All pods in the policy's own namespace only:
```yaml
from:
  - podSelector: {}
```
The trap is that `namespaceSelector: {}` means "every namespace", not "no namespace" — an empty selector always matches everything.

**Q22.** Applying `policyTypes: [Egress]` with no `egress` rules selected every pod in `prod` for egress and denied all outbound traffic — including the pod's UDP/53 packets to the CoreDNS Service. Without DNS, every hostname lookup fails, so applications fail before they ever open a connection. It is the top cause of outages because the failure is indirect: the app logs a name-resolution error, not a connection-refused, so operators look at CoreDNS or `resolv.conf` instead of at the policy they just applied. Any default-deny-egress rollout must ship together with a DNS allowance.

**Q23.** Because a bare `podSelector` inside a `to` element is scoped to the policy's own namespace (`prod`), and CoreDNS runs in `kube-system`. `podSelector: {k8s-app: kube-dns}` alone would try to match a pod with that label *in `prod`*, find none, and allow nothing. Pairing it with `namespaceSelector: {kubernetes.io/metadata.name: kube-system}` in the **same list element** ANDs the two conditions and correctly targets the CoreDNS pods.

**Q24.** A resolver falls back to TCP when a UDP response exceeds the advertised buffer size and comes back truncated (the TC bit set) — common with large DNSSEC responses, records with many answers, or `AXFR`-style queries. If you allow only UDP/53, those lookups hang or fail intermittently: most names resolve fine and a few do not, which produces confusing, load-dependent bugs. Always allow both.

**Q25.** Egress and ingress are evaluated **independently on each end** of a connection. `web-egress-to-db` selects the pods labelled `app=web` and governs their outbound direction; `db-ingress-from-web` selects the pods labelled `app=db` and governs their inbound direction. Because `prod` has both a default-deny-egress and a default-deny-ingress baseline, both ends are locked down, so both holes must be punched or the packet dies at whichever end is still closed. Forgetting one half is the most common reason a "correct-looking" policy pair still blocks traffic.

**Q26.** No separate rule is needed. `NetworkPolicy` enforcement is **stateful/connection-tracked**: once a connection is allowed in one direction, the reply packets of that established connection are permitted automatically. Rules describe *connection initiation*, not individual packets. (This is why you never write "allow ephemeral ports 32768–60999 back" the way you would in a stateless ACL.)

**Q27.** (1) The ClusterIP of `kube-dns` is cluster-specific and can differ per cluster or change if the Service is recreated — the manifest stops being portable and silently fails. (2) `ipBlock` matches the address *after* kube-proxy's DNAT in many data paths, so the packet the engine sees may carry the CoreDNS **pod** IP, not the ClusterIP, and the rule never matches; pod IPs are also ephemeral, so no static CIDR is reliable. The selector-based rule follows CoreDNS wherever it is rescheduled and works regardless of Service CIDR.

**Q28.** Step 5 fails **validation**: the API server rejects the object because every CIDR in `except` must be a subset of the enclosing `cidr` (`192.168.5.0/24` is not inside `10.0.0.0/8`). Step 6 fails **validation** too: a `NetworkPolicyPeer` may set `ipBlock` **or** the selector pair (`podSelector` / `namespaceSelector`), never both in the same element. The two structural rules: (1) `except` entries must be contained within their `cidr`; (2) `ipBlock` is mutually exclusive with selectors inside one peer — to allow both, use two separate list elements.

**Q29.** `10.96.0.0/12` broke it — that range contains the `kube-dns` ClusterIP (typically `10.96.0.10`), so DNS queries to the Service address were excluded. Two correct fixes: (a) add a **separate** egress rule using the `namespaceSelector` + `podSelector` form for CoreDNS on UDP/TCP 53 (rules are additive, so the selector rule re-opens DNS without weakening the metadata block); or (b) narrow the `except` from `169.254.0.0/16` + broad internal ranges down to just `169.254.169.254/32` plus whatever internal ranges you genuinely need blocked, keeping the DNS ClusterIP outside the excepted set. Option (a) is preferable — it keeps the "block internal + metadata" intent intact and expresses DNS by identity rather than address.

**Q30.** Because kube-proxy (or the CNI's kube-proxy replacement) DNATs the `kubernetes` ClusterIP to a real endpoint — the control-plane node IP on port 6443 — and depending on the data path, egress policy may be evaluated **after** that translation. Allowing only the ClusterIP works on some CNIs and fails on others; allowing only the node IP fails where policy is evaluated pre-DNAT. Allowing both addresses and both ports (443 for the ClusterIP, 6443 for the endpoint) is the portable answer. The general lesson: for any `ipBlock` rule aimed at a Service, determine whether your CNI sees pre- or post-DNAT addresses and cover both.

**Q31.** When traffic enters through a `NodePort` (or a `LoadBalancer` with the default `externalTrafficPolicy: Cluster`), kube-proxy may forward the packet to a pod on a *different* node and SNAT it, so the source IP the policy engine sees is the **node's** IP, not the original client's. An ingress `ipBlock` written against real client CIDRs then matches nothing — or, worse, an `except` meant to block a client is bypassed because every packet appears to come from a node. Setting `spec.externalTrafficPolicy: Local` on the Service preserves the client source IP (at the cost of only routing to pods on the receiving node).

**Q32.** Gaps: (1) Pods running with `hostNetwork: true` share the node's network namespace, and most CNIs do not apply pod `NetworkPolicy` to host-network traffic — such a pod reaches the metadata endpoint freely. (2) The policy covers only namespaces where you applied it; any new or unlabelled namespace, or a pod whose labels do not match the policy's `podSelector`, is unprotected. (3) A pod that can escalate to the node (privileged container, hostPID, writable host mount) reaches metadata from the host. Close them by forbidding `hostNetwork`, `privileged`, and host mounts via Pod Security Admission (`restricted`) or a policy engine (Kyverno/OPA Gatekeeper), and by enforcing the namespace baseline automatically rather than by hand. On cloud providers, also enforce IMDSv2 / disable the legacy metadata endpoint at the instance level — a control outside Kubernetes entirely.

**Q33.** Namespaced. `kubectl -n payments` simply populated `metadata.namespace` for you; the object is inert outside that namespace. The consequence is that a "cluster-wide baseline" in core Kubernetes is not one object — it is N identical objects, one per namespace, plus something that guarantees the N+1st namespace also gets one. There is no cluster-scoped `NetworkPolicy` kind.

**Q34.** No — a new namespace has no policies and is fully open. Two mechanisms: (1) an admission/policy controller such as **Kyverno** with a `generate` rule (or OPA Gatekeeper with a mutation/expansion pattern) that creates the default-deny objects automatically whenever a `Namespace` is created; (2) a GitOps controller (Argo CD / Flux) reconciling a repo where every namespace ships with its baseline policy, so drift or a manually-created namespace is flagged and corrected. A third option where the CNI supports it is a cluster-scoped `AdminNetworkPolicy` / Calico `GlobalNetworkPolicy`, which applies without per-namespace objects.

**Q35.** The policy's `spec.podSelector` matches no pods — because a label was typo'd, because a Deployment's pod template labels were changed later, or because the workload was moved to a namespace where the policy does not exist. The object appears in `kubectl get netpol`, passes YAML review, and enforces nothing. Worse, if it was the *only* policy selecting a pod, that pod silently reverts to default-allow. Always verify by resolving the selector against live pods (`kubectl get pods -l <selector>`) and by running an actual connectivity probe, never by reading the YAML alone.

**Q36.** A blanket deny-all in `kube-system` breaks the control plane's own plumbing. Two concrete examples: (1) **CoreDNS** would lose egress to the API server (it watches Services and EndpointSlices) and lose ingress from every namespace, so cluster-wide DNS dies immediately; (2) the **metrics-server** would be unable to scrape kubelets and would stop serving `kubectl top` and HPA metrics — and equally, any controller in `kube-system` that dials the API server or webhooks loses that path. Add to that admission webhooks and CNI/CSI components that need node and API connectivity. If you must restrict `kube-system`, do it with targeted per-workload policies and thorough testing, never with a namespace-wide deny-all.

**Q37.** With core `networking.k8s.io/v1` alone, it is **not** possible to guarantee. The API has no `deny` action and no priority: policies only ever *add* permissions, and any policy the `prod` team writes that permits `namespaceSelector: {tier: untrusted}` (or `namespaceSelector: {}`) instantly re-opens the path. The closest you can do is apply a default-deny in `prod` plus a default-deny-egress in `dev`, and then enforce the guardrail *administratively* — RBAC that prevents the `prod` team from creating `NetworkPolicy` objects at all, or an admission policy (Kyverno/Gatekeeper) that rejects any `NetworkPolicy` whose `from` would admit `tier: untrusted`. A true in-network guarantee requires a cluster-scoped API with a deny action: `AdminNetworkPolicy`, or a vendor equivalent such as Calico's `GlobalNetworkPolicy` or Cilium's `CiliumClusterwideNetworkPolicy`.

**Q38.** (1) **Cluster scope** — one object covering many namespaces, including namespaces that do not exist yet, instead of N per-namespace copies. (2) **Explicit `Deny`** — a real deny action, so a guardrail cannot be undone by a namespace owner adding an allow rule. (3) **Priority / ordering** — a numeric `priority` field that makes rule evaluation deterministic, which v1's purely additive union model cannot express. (A fourth: the `Pass` action, which has no v1 analogue at all.)

**Q39.** `Pass` stops evaluation of `AdminNetworkPolicy` rules for that traffic and **delegates the decision to the namespace-level `NetworkPolicy`** (and then to `BaselineAdminNetworkPolicy` if nothing matches). That is what makes the layered model work: the cluster admin writes high-priority `Deny` rules for traffic that must never be allowed, `Pass` rules for traffic that teams are trusted to govern themselves, and a `BaselineAdminNetworkPolicy` that sets the fallback when a namespace has written no policy at all. The admin sets the floor and the ceiling; the namespace owner decides in between.

**Q40.** You would get an error from the API server along the lines of `error: resource mapping not found for ... "policy.networking.k8s.io/v1alpha1, Kind=AdminNetworkPolicy": no matches for kind "AdminNetworkPolicy" in version "policy.networking.k8s.io/v1alpha1" — ensure CRDs are installed first`. Since ANP is delivered as CustomResourceDefinitions, the kind simply does not exist until the CRDs (and a CNI that reconciles them) are installed. The takeaway for the exam: run `kubectl api-resources` / `kubectl api-versions` *before* writing YAML that depends on an optional API, and default to core `networking.k8s.io/v1` unless the task or cluster demonstrably provides something else.

</details>

---

## References

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes documentation, *Network Policies* — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes API reference, *NetworkPolicy v1* — https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Kubernetes documentation, *Declare Network Policy* — https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- Kubernetes documentation, *Automatic labelling of namespaces* — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes documentation, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes documentation, *Service `externalTrafficPolicy` and source IP* — https://kubernetes.io/docs/tutorials/services/source-ip/
- SIG-Network, *Network Policy API (AdminNetworkPolicy)* — https://network-policy-api.sigs.k8s.io/
- kind, *Cluster configuration and CNI* — https://kind.sigs.k8s.io/docs/user/configuration/
- Project Calico, *Install Calico on a kind cluster* — https://docs.tigera.io/calico/latest/getting-started/kubernetes/kind
- Cilium, *Network Policy documentation* — https://docs.cilium.io/en/stable/security/policy/
- Ahmet Alp Balkan, *Kubernetes Network Policy Recipes* — https://github.com/ahmetb/kubernetes-network-policy-recipes