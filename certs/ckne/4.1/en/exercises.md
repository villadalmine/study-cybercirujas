# Guided Exercises — 4.1 Securing Traffic with Network Policies (CKNE)

> **Exam weight:** 6.25%
> **Official sources:**
> - CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
> - Kubernetes concepts — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
> - Kubernetes task — Declare Network Policy: https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
> - NetworkPolicy API reference: https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
> - Cilium — Network Policy: https://docs.cilium.io/en/stable/security/policy/
> - Cilium — Hubble observability: https://docs.cilium.io/en/stable/observability/hubble/
> - SIG Network Policy API (cluster-scoped policies): https://network-policy-api.sigs.k8s.io/

These exercises build one scenario step by step. A three-tier application (`frontend` → `backend` → `db`) and a monitoring namespace start with fully open networking. You then move them to a zero-trust posture one policy at a time, and test the connectivity matrix after every change. Do the exercises in order, because each one depends on the state the previous one leaves behind.

**What you need:** `kind` ≥ 0.23, `kubectl`, the `cilium` CLI, and the `hubble` CLI (https://docs.cilium.io/en/stable/observability/hubble/setup/#install-the-hubble-client). Any CNI that enforces NetworkPolicy (Calico, Antrea, Cilium) will work for Exercises 1–6 and 8. Exercise 7 uses Cilium's Hubble.

---

## Exercise 0 — Build a cluster whose CNI actually enforces policy

1. Create a kind configuration that disables the default CNI:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: iptables
nodes:
- role: control-plane
- role: worker
- role: worker
```

Save it as `kind-netpol.yaml`, then create the cluster:

```bash
kind create cluster --name ckne-netpol --config kind-netpol.yaml
kubectl get nodes
```

Expected output (the nodes are `NotReady` because there is no CNI yet):

```
NAME                        STATUS     ROLES           AGE   VERSION
ckne-netpol-control-plane   NotReady   control-plane   45s   v1.33.1
ckne-netpol-worker          NotReady   <none>          25s   v1.33.1
ckne-netpol-worker2         NotReady   <none>          25s   v1.33.1
```

2. Install Cilium and turn on Hubble:

```bash
cilium install
cilium status --wait
cilium hubble enable
cilium status --wait
kubectl get nodes
```

`cilium status` should now report `Cilium: OK`, `Operator: OK` and `Hubble Relay: OK`, and all nodes should be `Ready`.

3. Check that the NetworkPolicy API exists and that nothing is applied yet:

```bash
kubectl api-resources --api-group=networking.k8s.io
kubectl get networkpolicies -A
```

```
NAME              SHORTNAMES   APIVERSION             NAMESPACED   KIND
ingressclasses                 networking.k8s.io/v1   false        IngressClass
ingresses         ing          networking.k8s.io/v1   true         Ingress
networkpolicies   netpol       networking.k8s.io/v1   true         NetworkPolicy
No resources found
```

**Questions**

- **Q0.1** Suppose you ran the same exercises on a cluster whose CNI does **not** implement NetworkPolicy (for example, flannel on its own). What would `kubectl apply` return for a policy, and what would happen to the traffic?
- **Q0.2** Which component turns a `NetworkPolicy` object into packet filtering, and which component stores it?

---

## Exercise 1 — Deploy the workloads and record the baseline

1. Create the namespaces:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
```

```bash
kubectl apply -f namespaces.yaml
kubectl get ns app monitoring --show-labels
```

```
NAME         STATUS   AGE   LABELS
app          Active   3s    kubernetes.io/metadata.name=app
monitoring   Active   3s    kubernetes.io/metadata.name=monitoring
```

2. Deploy the application tier. `backend` and `db` run `agnhost netexec`, a small HTTP server from the Kubernetes e2e test images. `frontend` is a curl client.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: client
        image: curlimages/curl:8.10.1
        command: ["sh", "-c", "while true; do sleep 3600; done"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: api
    spec:
      containers:
      - name: netexec
        image: registry.k8s.io/e2e-test-images/agnhost:2.53
        args: ["netexec", "--http-port=8080"]
        ports:
        - name: http
          containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: app
spec:
  selector:
    app: backend
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: netexec
        image: registry.k8s.io/e2e-test-images/agnhost:2.53
        args: ["netexec", "--http-port=5432"]
        ports:
        - name: sql
          containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: app
spec:
  selector:
    app: db
  ports:
  - name: sql
    port: 5432
    targetPort: sql
```

3. Deploy two clients in `monitoring`: a legitimate `scraper` and a `debug` pod that should **not** get access later.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scraper
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: scraper
  template:
    metadata:
      labels:
        app: scraper
    spec:
      containers:
      - name: client
        image: curlimages/curl:8.10.1
        command: ["sh", "-c", "while true; do sleep 3600; done"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: debug
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: debug
  template:
    metadata:
      labels:
        app: debug
    spec:
      containers:
      - name: client
        image: curlimages/curl:8.10.1
        command: ["sh", "-c", "while true; do sleep 3600; done"]
```

```bash
kubectl apply -f app.yaml -f monitoring.yaml
kubectl -n app rollout status deploy/frontend deploy/backend deploy/db
kubectl -n monitoring rollout status deploy/scraper deploy/debug
```

4. Define a probe helper and a connectivity matrix. You will reuse both for the rest of the lab.

```bash
probe() {  # usage: probe <namespace> <deployment> <url>
  kubectl -n "$1" exec deploy/"$2" -- \
    curl -sS -o /dev/null --max-time 3 -w "$1/$2 -> $3 : HTTP %{http_code}\n" "$3" 2>&1 \
    | grep -v '^command terminated'
}

matrix() {
  probe app        frontend http://backend.app/hostname
  probe app        frontend http://db.app:5432/hostname
  probe monitoring scraper  http://backend.app/hostname
  probe monitoring debug    http://backend.app/hostname
  probe app        frontend https://kubernetes.io
}

matrix
```

Expected baseline (everything allowed):

```
app/frontend -> http://backend.app/hostname : HTTP 200
app/frontend -> http://db.app:5432/hostname : HTTP 200
monitoring/scraper -> http://backend.app/hostname : HTTP 200
monitoring/debug -> http://backend.app/hostname : HTTP 200
app/frontend -> https://kubernetes.io : HTTP 200
```

If the kind nodes have no internet access, the last line fails from the start. Ignore it until Exercise 6.

5. Record the pod IPs. You will need them later:

```bash
kubectl get pods -A -o wide -l 'app in (frontend,backend,db,scraper,debug)'
```

**Questions**

- **Q1.1** Why is `frontend` allowed to reach `db` right now, even though nobody asked for that?
- **Q1.2** Which label does every namespace carry without anyone adding it, and why is it the safest label to use in a `namespaceSelector`?

---

## Exercise 2 — Default-deny ingress for the namespace

1. Apply a policy that selects every pod in `app` and allows no ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: app
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

```bash
kubectl apply -f default-deny-ingress.yaml
kubectl -n app describe networkpolicy default-deny-ingress
```

```
Name:         default-deny-ingress
Namespace:    app
...
Spec:
  PodSelector:     <none> (Allowing the specific traffic to all pods in this namespace)
  Allowing ingress traffic:
    <none> (Selected pods are isolated for ingress connectivity)
  Not affecting egress traffic
  Policy Types: Ingress
```

2. Run the matrix again:

```bash
matrix
```

```
app/frontend -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
app/frontend -> http://db.app:5432/hostname : HTTP 000
curl: (28) Connection timed out after 3001 milliseconds
monitoring/scraper -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
monitoring/debug -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3001 milliseconds
app/frontend -> https://kubernetes.io : HTTP 200
```

The exact milliseconds and the order of the two lines may differ. What matters is the `(28)` and the `000`.

**Questions**

- **Q2.1** DNS resolution of `backend.app` worked (the error is a *connection* timeout, not a *resolving* timeout), and so did the connection to `kubernetes.io`. Why?
- **Q2.2** Blocked traffic shows up as a **timeout**, not a `Connection refused`. What does that tell you about how the dataplane handles a denied packet? Why does that matter when you troubleshoot?
- **Q2.3** Does `podSelector: {}` in namespace `app` isolate the pods in `monitoring`?

---

## Exercise 3 — Allow frontend → backend, and the Service-port trap

1. Apply a policy written by someone who thinks in terms of the Service. It uses port **80**:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-frontend
  namespace: app
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

```bash
kubectl apply -f backend-allow-frontend.yaml
probe app frontend http://backend.app/hostname
```

```
app/frontend -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
```

2. Check what the backend pods actually listen on:

```bash
kubectl -n app get svc backend -o jsonpath='{.spec.ports[0].port} -> {.spec.ports[0].targetPort}{"\n"}'
kubectl -n app get endpointslices -l kubernetes.io/service-name=backend \
  -o jsonpath='{range .items[*].ports[*]}{.name}={.port}{"\n"}{end}'
```

```
80 -> http
http=8080
```

3. Fix the policy with the **named port** from the pod spec:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-frontend
  namespace: app
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
      port: http
```

```bash
kubectl apply -f backend-allow-frontend.yaml
matrix
```

```
app/frontend -> http://backend.app/hostname : HTTP 200
app/frontend -> http://db.app:5432/hostname : HTTP 000
curl: (28) Connection timed out after 3001 milliseconds
monitoring/scraper -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
monitoring/debug -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
app/frontend -> https://kubernetes.io : HTTP 200
```

4. Two policies now select the backend pods: `default-deny-ingress` and `backend-allow-frontend`. List them:

```bash
kubectl -n app get netpol
```

```
NAME                     POD-SELECTOR   AGE
backend-allow-frontend   app=backend    40s
default-deny-ingress     <none>         4m
```

**Questions**

- **Q3.1** Why does a policy on port 80 fail when the client connects to the Service on port 80?
- **Q3.2** One policy says "deny everything" and the other says "allow frontend". Why doesn't the deny win? How does Kubernetes combine several policies that select the same pod?
- **Q3.3** What is the advantage of `port: http` over `port: 8080` when the development team later moves the container to port 9090?
- **Q3.4** The backend's HTTP responses go back to `frontend`, which is also isolated for ingress by `default-deny-ingress`. Why aren't the responses dropped?

---

## Exercise 4 — Default-deny egress without breaking DNS

1. Deny all egress in `app`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: app
spec:
  podSelector: {}
  policyTypes:
  - Egress
```

```bash
kubectl apply -f default-deny-egress.yaml
probe app frontend http://backend.app/hostname
probe app frontend https://kubernetes.io
```

```
app/frontend -> http://backend.app/hostname : HTTP 000
curl: (28) Resolving timed out after 3000 milliseconds
app/frontend -> https://kubernetes.io : HTTP 000
curl: (28) Resolving timed out after 3000 milliseconds
```

2. Confirm that DNS is the problem by skipping it. Connect straight to a backend pod IP:

```bash
BACKEND_IP=$(kubectl -n app get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')
probe app frontend "http://${BACKEND_IP}:8080/hostname"
```

```
app/frontend -> http://10.244.1.37:8080/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
```

3. Allow DNS for every pod in the namespace, to CoreDNS only:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: app
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
kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels
kubectl apply -f allow-dns-egress.yaml
probe app frontend http://backend.app/hostname
```

```
app/frontend -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
```

The name resolves now (the message changed from *Resolving* to *Connection*), but the connection is still blocked.

4. Allow the frontend's egress to the backend:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress-backend
  namespace: app
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
      port: 8080
```

```bash
kubectl apply -f frontend-egress-backend.yaml
matrix
```

```
app/frontend -> http://backend.app/hostname : HTTP 200
app/frontend -> http://db.app:5432/hostname : HTTP 000
curl: (28) Connection timed out after 3001 milliseconds
monitoring/scraper -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
monitoring/debug -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3001 milliseconds
app/frontend -> https://kubernetes.io : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
```

**Questions**

- **Q4.1** Why does the DNS policy allow both UDP **and** TCP on port 53?
- **Q4.2** In the DNS rule, `namespaceSelector` and `podSelector` sit in the **same** list element. What would change if each had its own `-`?
- **Q4.3** For a pod in `app` to reach a pod in `app`, how many policies must allow the flow, and on which sides?
- **Q4.4** Your production cluster runs NodeLocal DNSCache on `169.254.20.10`. Why would `allow-dns-egress` stop being enough, and what would you add?

---

## Exercise 5 — Cross-namespace access: AND versus OR

The goal is to let **only** `monitoring/scraper` reach the backend on 8080. `monitoring/debug` must stay blocked.

1. Apply the **OR** version first. It looks right, but it isn't:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-scraper
  namespace: app
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
          kubernetes.io/metadata.name: monitoring
    - podSelector:
        matchLabels:
          app: scraper
    ports:
    - protocol: TCP
      port: 8080
```

```bash
kubectl apply -f backend-allow-scraper.yaml
probe monitoring scraper http://backend.app/hostname
probe monitoring debug   http://backend.app/hostname
```

```
monitoring/scraper -> http://backend.app/hostname : HTTP 200
monitoring/debug -> http://backend.app/hostname : HTTP 200
```

2. Look at how `kubectl` shows it:

```bash
kubectl -n app describe netpol backend-allow-scraper
```

```
  Allowing ingress traffic:
    To Port: 8080/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=monitoring
    From:
      PodSelector: app=scraper
```

There are two separate `From:` entries, so the peers are OR-ed.

3. Fix it with the **AND** version. `podSelector` moves into the same element as `namespaceSelector`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-scraper
  namespace: app
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
          kubernetes.io/metadata.name: monitoring
      podSelector:
        matchLabels:
          app: scraper
    ports:
    - protocol: TCP
      port: 8080
```

```bash
kubectl apply -f backend-allow-scraper.yaml
kubectl -n app describe netpol backend-allow-scraper | sed -n '/Allowing ingress/,/Not affecting\|Policy Types/p'
probe monitoring scraper http://backend.app/hostname
probe monitoring debug   http://backend.app/hostname
```

```
  Allowing ingress traffic:
    To Port: 8080/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=monitoring
      PodSelector: app=scraper
monitoring/scraper -> http://backend.app/hostname : HTTP 200
monitoring/debug -> http://backend.app/hostname : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
```

**Questions**

- **Q5.1** With the OR version, list **every** set of pods that was allowed in. Include one set you could not see in the test.
- **Q5.2** `monitoring` has no NetworkPolicies. Which side needed a policy for the scraper flow to work, and why was one side enough here when Exercise 4 needed two?
- **Q5.3** Why is `kubernetes.io/metadata.name` better for this selector than a label such as `team: observability` that a namespace admin can edit? And when would a custom label be the better choice?

---

## Exercise 6 — Lock down the database and control internet egress

1. Allow only `backend` → `db` on 5432. This needs a policy on each side, because egress in `app` is denied by default:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-backend
  namespace: app
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
          app: backend
    ports:
    - protocol: TCP
      port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-egress-db
  namespace: app
spec:
  podSelector:
    matchLabels:
      app: backend
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
```

2. Test from the backend. It has no curl, so use `agnhost connect`, which opens a TCP connection and exits non-zero on failure:

```bash
kubectl -n app exec deploy/backend -- /agnhost connect db.app:5432 --timeout=3s && echo "backend -> db OK"
kubectl apply -f db-lockdown.yaml
kubectl -n app exec deploy/backend -- /agnhost connect db.app:5432 --timeout=3s && echo "backend -> db OK"
probe app frontend http://db.app:5432/hostname
```

Expected: the first `connect` prints `TIMEOUT` and exits non-zero, because Exercise 4 already denied the backend's egress. After the apply, it prints `backend -> db OK`. The frontend is still blocked.

3. Let the frontend reach public HTTPS endpoints, but not private address space or the cloud metadata endpoint:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress-internet
  namespace: app
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
        - 169.254.169.254/32
    ports:
    - protocol: TCP
      port: 443
```

```bash
kubectl apply -f frontend-egress-internet.yaml
probe app frontend https://kubernetes.io
probe app frontend https://kubernetes.default.svc
probe app frontend http://backend.app/hostname
```

```
app/frontend -> https://kubernetes.io : HTTP 200
app/frontend -> https://kubernetes.default.svc : HTTP 000
curl: (28) Connection timed out after 3002 milliseconds
app/frontend -> http://backend.app/hostname : HTTP 200
```

4. Opening a range of ports takes `endPort` (GA since Kubernetes 1.25). Read this fragment, but don't apply it:

```yaml
ports:
- protocol: TCP
  port: 30000
  endPort: 30100
```

**Questions**

- **Q6.1** Give **two** independent reasons why `https://kubernetes.default.svc` is blocked for the frontend on this kind cluster.
- **Q6.2** Why is `ipBlock` a poor way to allow or deny traffic to *other pods*? What does the Kubernetes documentation say about source/destination NAT and `ipBlock`?
- **Q6.3** The frontend now has three egress policies (`allow-dns-egress`, `frontend-egress-backend`, `frontend-egress-internet`). Can a fourth policy take away something the first three allow?
- **Q6.4** What does NetworkPolicy **not** let you express here that a team might want, such as "allow only `api.github.com`"? Where would you look for it?

---

## Exercise 7 — Observe verdicts with Hubble

1. Open the Hubble Relay tunnel and check it:

```bash
cilium hubble port-forward &
hubble status
```

```
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 12,285/12,285 (100.00%)
Flows/s: 41.7
Connected Nodes: 3/3
```

2. In a second terminal, follow the dropped flows in `app`:

```bash
hubble observe --namespace app --verdict DROPPED --follow
```

3. In the first terminal, generate a denied flow and an allowed flow:

```bash
probe app frontend http://db.app:5432/hostname
probe monitoring debug http://backend.app/hostname
```

Hubble output will look similar to this:

```
Sep 30 10:15:42.118: app/frontend-7c9d8b6f5-x2kqp:51724 (ID:31245) <> app/db-5d9c8b7f6-lm4tq:5432 (ID:18762) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
Sep 30 10:15:42.118: app/frontend-7c9d8b6f5-x2kqp:51724 (ID:31245) <> app/db-5d9c8b7f6-lm4tq:5432 (ID:18762) Policy denied DROPPED (TCP Flags: SYN)
Sep 30 10:15:47.502: monitoring/debug-6f4b9c7d8-q8wzn:40118 (ID:9981) <> app/backend-84c6d5f7b9-7hn2m:8080 (ID:22410) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep 30 10:15:47.502: monitoring/debug-6f4b9c7d8-q8wzn:40118 (ID:9981) <> app/backend-84c6d5f7b9-7hn2m:8080 (ID:22410) Policy denied DROPPED (TCP Flags: SYN)
```

4. Look at the allowed verdicts too:

```bash
hubble observe --namespace app --type policy-verdict --verdict FORWARDED --last 10
```

**Questions**

- **Q7.1** The frontend → db drop says `EGRESS DENIED`, but the debug → backend drop says `INGRESS DENIED`. Explain each from the policies you applied.
- **Q7.2** The destination port in the Hubble line is `5432` / `8080`, not the Service port. Which exercise does that confirm?
- **Q7.3** On Calico or another CNI without Hubble, what would you use to answer "which rule dropped this packet?"

---

## Exercise 8 — Troubleshooting challenge

A second team deployed a small app to namespace `shop` along with its policies, and they report that "`web` cannot reach `api`". Deploy their manifests **as they are**, find the defects, and fix them. Do not add any policy that allows everything.

1. Deploy:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: shop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: client
        image: curlimages/curl:8.10.1
        command: ["sh", "-c", "while true; do sleep 3600; done"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: shop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-server
  template:
    metadata:
      labels:
        app: api-server
    spec:
      containers:
      - name: netexec
        image: registry.k8s.io/e2e-test-images/agnhost:2.53
        args: ["netexec", "--http-port=8080"]
        ports:
        - name: http
          containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: shop
spec:
  selector:
    app: api-server
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: shop
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-web
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: web
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-egress-api
  namespace: shop
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
          app: api-server
    ports:
    - protocol: TCP
      port: 80
```

```bash
kubectl apply -f shop.yaml
kubectl -n shop rollout status deploy/web deploy/api
probe shop web http://api.shop/hostname
```

2. Investigate methodically:

```bash
kubectl -n shop get pods --show-labels
kubectl -n shop get netpol
kubectl -n shop describe netpol api-allow-web web-egress-api
kubectl -n shop get endpointslices -l kubernetes.io/service-name=api -o wide
hubble observe --namespace shop --verdict DROPPED --last 20
```

3. Fix the defects one at a time, and rerun `probe shop web http://api.shop/hostname` after each fix. Write down how the error message changes (`Resolving timed out` vs `Connection timed out`) and what the Hubble verdict says (`EGRESS` vs `INGRESS`).

**Questions**

- **Q8.1** How many defects are there? List each one with its symptom.
- **Q8.2** Why does the fix order matter for what you *see*, even though the final state is the same?
- **Q8.3** Write the corrected policies.

---

## Exercise 9 — Limits of the model (discussion)

No commands in this one. Answer from what you now know and from the "What you can't do with network policies" section of the Kubernetes documentation.

- **Q9.1** A platform team wants a rule that **no** namespace owner can override, such as "every namespace must allow ingress from `monitoring`" or "no pod may reach `169.254.169.254`". Why can't the namespaced `NetworkPolicy` API guarantee this, and which API effort addresses it?
- **Q9.2** A pod runs with `hostNetwork: true`. What does the specification say about how NetworkPolicy applies to it?
- **Q9.3** Can NetworkPolicy enforce "only HTTP `GET /metrics`"? If not, which layer would you use?
- **Q9.4** You apply a policy and a test passes a second later. Why is that not proof that the policy is enforced on every node, and how would you make the test trustworthy?

---

## Cleanup

```bash
kill %1 2>/dev/null
kind delete cluster --name ckne-netpol
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**Q0.1** `kubectl apply` succeeds. The API server validates and stores the object, and returns `networkpolicy.networking.k8s.io/<name> created`. Nothing enforces it, so all traffic keeps flowing. This silent failure is the most dangerous NetworkPolicy misconfiguration. Always test enforcement with a real denied probe. Never read "the object exists" as "the traffic is blocked".

**Q0.2** The API server stores the object in etcd. The **network plugin (CNI)** enforces it: its agent on each node watches NetworkPolicy, Pod and Namespace objects and programs the dataplane. Cilium uses eBPF programs, Calico uses iptables/nftables/eBPF, and Antrea uses OVS flows. kube-proxy plays no part in NetworkPolicy.

### Exercise 1

**Q1.1** A pod is **non-isolated** until at least one NetworkPolicy selects it for a given direction. With no policies at all, every pod accepts all ingress and sends all egress. Kubernetes networking is flat and allow-all by default.

**Q1.2** `kubernetes.io/metadata.name=<namespace name>`. The control plane sets it automatically (GA since v1.22) and keeps it equal to the namespace name, so it cannot be spoofed by relabeling one namespace to look like another. It identifies exactly one namespace.

### Exercise 2

**Q2.1** The policy has `policyTypes: [Ingress]`, so it isolates only **ingress** to pods in `app`. Egress from `frontend` is unaffected: DNS queries to CoreDNS in `kube-system` and HTTPS to the internet still go out. Replies are allowed because enforcement is stateful (see Q3.4).

**Q2.2** The dataplane **silently drops** the SYN. It does not send a TCP RST or ICMP unreachable, so the client retries until it times out. When you troubleshoot, a timeout points to a policy drop (or a routing black hole), while `Connection refused` means the packet reached the pod and nothing was listening on that port. The two symptoms send you to different layers.

**Q2.3** No. NetworkPolicy is namespaced, and `spec.podSelector` only selects pods in the policy's own namespace. `podSelector: {}` means "all pods **in `app`**".

### Exercise 3

**Q3.1** A connection to the Service ClusterIP on port 80 is DNATed (by kube-proxy or the CNI's service load balancer) to `podIP:8080` **before** the policy is evaluated at the destination pod. NetworkPolicy works on pod IPs and pod ports and has no concept of Services. The rule must name the **container port** (8080) or its name (`http`).

**Q3.2** NetworkPolicy has no deny rules and no ordering. Every policy is a list of *allows*, and policies are **additive**. A pod selected by any policy for a direction becomes isolated in that direction, and the traffic allowed is the **union** of all rules from all policies that select it for that direction. `default-deny-ingress` contributes "isolate, allow nothing" and `backend-allow-frontend` contributes "allow frontend on http". The union is "allow frontend on http".

**Q3.3** A named port is resolved against the **destination pod's** `containerPort` names at enforcement time. If the container moves to 9090 but keeps the name `http`, the policy still matches without an edit. A hard-coded `8080` would silently start blocking. Named ports also make policies easier to read.

**Q3.4** Enforcement is **stateful** (connection tracking). Once a connection is allowed in its initiating direction, its reply packets are allowed automatically. The docs say: "the reply traffic for those connections will also be implicitly allowed." You write policies for the direction in which connections are *opened*.

### Exercise 4

**Q4.1** DNS normally uses UDP, but it falls back to **TCP** when a response is truncated (large answers, many records, DNSSEC) and some resolvers use TCP by default. Allowing only UDP produces failures that come and go, depending on the size of the answer, which are hard to diagnose.

**Q4.2** In **one** element, the two selectors are **AND**-ed: "pods labeled `k8s-app=kube-dns` in namespace `kube-system`". As **two** elements, they are **OR**-ed: "any pod in `kube-system`" **or** "any pod labeled `k8s-app=kube-dns` in the policy's own namespace (`app`)". That is broader on the first branch and useless on the second.

**Q4.3** Two, when both sides are isolated. There must be an **egress** allow on the source pod (`frontend-egress-backend`) **and** an **ingress** allow on the destination pod (`backend-allow-frontend`). A connection succeeds only if every isolated end allows it.

**Q4.4** With NodeLocal DNSCache, pods send queries to a link-local IP on the node (`169.254.20.10`) that is served by a hostNetwork DaemonSet. The traffic never reaches a CoreDNS *pod* selected by `k8s-app: kube-dns`, so the peer does not match. You would add an `ipBlock` peer, `cidr: 169.254.20.10/32`, on UDP and TCP 53. Keep the kube-dns peer as a fallback, because the node-local cache forwards cache misses and pods fall back to kube-dns in some configurations.

### Exercise 5

**Q5.1**
1. Every pod in namespace `monitoring`, whatever its labels. That includes `debug`.
2. Every pod labeled `app=scraper` in namespace **`app`**. A lone `podSelector` in a peer means "in the policy's namespace". None existed, so the test could not show this, but anyone who can create pods in `app` could create one and get access.

**Q5.2** Only the **destination** (`backend`, ingress) needed a policy. `monitoring` has no policies, so its pods are not isolated for egress and send freely. In Exercise 4, both ends were isolated (`app` has default-deny egress **and** ingress), so both had to allow.

**Q5.3** A namespace admin (or anyone with `patch` on namespaces) can add `team: observability` to **their own** namespace and gain access, which is label spoofing. `kubernetes.io/metadata.name` is set by the control plane and always equals the name. Custom labels are the better choice when you mean a *group* of namespaces (for example, every tenant namespace in a tier). Control who can set them with RBAC or admission policy (ValidatingAdmissionPolicy, Kyverno, Gatekeeper).

### Exercise 6

**Q6.1**
1. **Port:** the Service `kubernetes.default` is port 443, but it is DNATed to the API server at `<control-plane-node-IP>:6443`. The policy only allows TCP **443** at the post-DNAT destination.
2. **Address:** the kind node network is `172.18.0.0/16`, which falls inside the `except: 172.16.0.0/12` range.

(On Cilium there is a third factor: the API server is a special `kube-apiserver` entity that CIDR rules may not match. Either of the first two reasons is enough.)

**Q6.2** Pod IPs are ephemeral and reassigned constantly. An `ipBlock` for a pod goes stale the next time the pod is rescheduled. The docs say `ipBlock` is intended for cluster-external IPs, and that because ingress/egress mechanisms often rewrite source or destination IPs (SNAT for egress gateways and LoadBalancers, DNAT for Services), it is **undefined whether that rewrite happens before or after policy evaluation**. Behaviour depends on the implementation. Cilium, for example, does not apply CIDR rules to endpoints it manages; it identifies those by label identity. Use `podSelector`/`namespaceSelector` for in-cluster peers.

**Q6.3** No. Policies only add allowed traffic (a union). There is no deny primitive in `networking.k8s.io/v1`, so a fourth policy can only widen what is allowed. To remove access, you edit or delete the policy that grants it.

**Q6.4** NetworkPolicy works at L3/L4 only: IPs, CIDRs, ports and protocols. It has no FQDN rules (`api.github.com` resolves to changing IPs) and no L7 awareness. Implementation-specific CRDs cover this: Cilium's `CiliumNetworkPolicy` with `toFQDNs` and L7 HTTP rules, Calico's `NetworkPolicy`/`GlobalNetworkPolicy` with domain names (Calico Enterprise/Cloud), an egress gateway or proxy, or a service mesh (for example, Istio `AuthorizationPolicy`).

### Exercise 7

**Q7.1** **frontend → db:** the frontend is isolated for egress by `default-deny-egress`, and none of its egress policies (DNS, backend:8080, internet:443 excluding private ranges) allows `db:5432`. The packet is dropped at the **source** on egress and never reaches db.
**debug → backend:** `monitoring` has no policies, so the debug pod's egress is allowed. At the backend, ingress is isolated, and `backend-allow-scraper` (AND version) matches only `app=scraper` in `monitoring`. The packet is dropped at the **destination** on ingress.

**Q7.2** Exercise 3. Policy is evaluated on the pod IP and the container port after the Service DNAT. Hubble shows the post-translation destination (`db` pod `:5432`, `backend` pod `:8080`).

**Q7.3** For Calico: enable policy flow logs (Calico Enterprise/Cloud), or use `calicoctl`/`kubectl` to list the policies that select the endpoint and check the dataplane: `iptables-save | grep cali` / `nft list ruleset`, or the Calico eBPF tooling (`calico-node -bpf`). Generic options: `tcpdump` on the pod's host-side veth (you will see a SYN leave but no SYN-ACK come back), conntrack tables, and the CNI agent's logs. The structured approach is the same: list every policy that selects the source (egress) and the destination (ingress), then check the peer, port and protocol of each.

### Exercise 8

**Q8.1** There are three defects:
1. **No DNS egress.** `default-deny-all` isolates egress for every pod in `shop` and nothing allows port 53. Symptom: `curl: (28) Resolving timed out`.
2. **`web-egress-api` uses the Service port (80)**, but after DNAT the destination is `api-pod:8080`. Symptom (once DNS is fixed): `Connection timed out`, with Hubble showing **EGRESS DENIED** on `web` to `:8080`.
3. **`api-allow-web` selects `app: api`**, but the pods are labeled `app: api-server`. The policy selects no pods, so `api` stays isolated by `default-deny-all` with no allow. Symptom (after fixes 1 and 2): `Connection timed out`, with Hubble showing **INGRESS DENIED** at the api pod. A quick tell is `kubectl get netpol`: the POD-SELECTOR shows `app=api`, which matches nothing in `kubectl get pods --show-labels`.

**Q8.2** Each defect hides the ones behind it. DNS fails first, so you never reach the TCP connection. Then egress drops at the source, so the packet never reaches the destination's ingress check. The symptom (`Resolving` → `Connection` timeout, then `EGRESS` → `INGRESS` verdict) moves one hop down the path with each fix. This is why you fix and re-probe one change at a time instead of changing everything at once.

**Q8.3**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: shop
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
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-web
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: api-server
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: web
    ports:
    - protocol: TCP
      port: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-egress-api
  namespace: shop
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
          app: api-server
    ports:
    - protocol: TCP
      port: 8080
```

After applying these, `probe shop web http://api.shop/hostname` returns `HTTP 200`.

### Exercise 9

**Q9.1** A `NetworkPolicy` lives inside a namespace, and anyone with RBAC to create policies there can add allows. Since policies are additive and have no deny, a namespace owner can always open traffic that a platform policy meant to block. The standard API has no cluster scope, no priority, and no explicit deny. SIG Network's Network Policy API project (https://network-policy-api.sigs.k8s.io/) defines cluster-scoped, prioritized policies with `Allow`/`Deny`/`Pass` actions, which were first published as `AdminNetworkPolicy`/`BaselineAdminNetworkPolicy` and are evolving under that project. CNIs also ship their own cluster-wide CRDs: Cilium `CiliumClusterwideNetworkPolicy`, Calico `GlobalNetworkPolicy`, Antrea `ClusterNetworkPolicy`. Check what your CNI version supports before relying on any of them.

**Q9.2** The behaviour is **undefined** by the specification. Most implementations cannot tell a hostNetwork pod's traffic apart from the node's own traffic. Such pods are usually neither isolated by `podSelector` nor matched by it as peers, so they are treated as the node IP. Do not rely on NetworkPolicy to protect or restrict hostNetwork workloads.

**Q9.3** No. NetworkPolicy stops at L4 (IP, port, protocol). To restrict HTTP methods or paths, use an L7-aware layer: Cilium L7 rules in `CiliumNetworkPolicy` (`rules.http` with `method`/`path`), a service mesh authorization policy, or the application's own gateway or proxy.

**Q9.4** Policy enforcement is **eventually consistent**. Each node's agent programs its own dataplane after it sees the object, and the docs note that a new policy may take some time to be handled. A single probe hits one source/destination pair on specific nodes. A trustworthy test:
- probes from sources on **different nodes** to replicas on **different nodes**;
- includes **negative** cases (flows that must be denied) as well as positive ones;
- retries with a short timeout until the expected state converges;
- checks verdicts (Hubble, or flow logs), not just exit codes.

Run the connectivity matrix as an automated check after every policy change, the way `matrix` was used in this lab.

</details>