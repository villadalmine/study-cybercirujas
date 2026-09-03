# 703.1 Kubernetes Architecture and Usage — Guided Exercises

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, objectives v2.0.0
**Topic 703.1:** Kubernetes Architecture and Usage — exam weight **6.67**

These exercises are hands-on. You build a real multi-node cluster, then take it apart from the inside: static Pods, the API server's HTTP surface, etcd's key space, the reconciliation loops, the scheduler's decision record, the kubelet's node contract, and the dataplane that turns a `Service` IP into a packet on the wire. Every block ends with verification questions; all answers are collapsed at the end of the document.

> **Safety.** Several steps deliberately break the control plane (moving a static Pod manifest, tainting nodes, reading etcd directly). Run them **only** against the disposable `kind` cluster built in Exercise 0. Never against a shared or production cluster.

**Conventions used below**

* Outputs were captured on a `kind` cluster running Kubernetes **v1.33**. Your patch version, UIDs, IPs, hashes and ages **will differ** — compare the *shape* of the output, not the literal characters.
* `$` = your workstation. `#` inside a `docker exec` = a shell inside a node container.
* Anything in `<angle brackets>` is a value you must substitute from your own output.

---

## Exercise 0 — Build the lab and establish a baseline

**Prerequisites:** Docker (or Podman with `KIND_EXPERIMENTAL_PROVIDER=podman`), `kind` ≥ 0.29, `kubectl` matching the cluster within one minor version, `jq`.

### Steps

1. Write the cluster definition. A single control-plane node plus two workers is the smallest topology that makes scheduling, taints and the dataplane observable.

```bash
cat > kind-lpi703.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lpi703
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
```

2. Create the cluster, pinning the node image so the lab is reproducible.

```bash
kind create cluster --config kind-lpi703.yaml --image kindest/node:v1.33.1
```

3. Confirm which cluster and identity `kubectl` is actually using. This is the single most common source of "it worked on my machine" incidents.

```bash
kubectl config current-context
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
kubectl cluster-info
```

Expected:

```
kind-lpi703
https://127.0.0.1:39217
Kubernetes control plane is running at https://127.0.0.1:39217
CoreDNS is running at https://127.0.0.1:39217/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

4. Inventory the nodes and the runtime beneath them.

```bash
kubectl get nodes -o wide
```

```
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION        CONTAINER-RUNTIME
lpi703-control-plane    Ready    control-plane   96s   v1.33.1   172.18.0.4    <none>        Debian GNU/Linux 12 (bookworm)   6.16.3-200.fc42.x86_64   containerd://2.1.1
lpi703-worker           Ready    <none>          84s   v1.33.1   172.18.0.2    <none>        Debian GNU/Linux 12 (bookworm)   6.16.3-200.fc42.x86_64   containerd://2.1.1
lpi703-worker2          Ready    <none>          84s   v1.33.1   172.18.0.3    <none>        Debian GNU/Linux 12 (bookworm)   6.16.3-200.fc42.x86_64   containerd://2.1.1
```

5. Discover what the API server actually serves. `api-resources` is the authoritative list for *this* cluster — it includes CRDs and aggregated APIs, so it is never the same twice.

```bash
kubectl api-resources --sort-by=name | head -20
kubectl api-resources | wc -l
kubectl api-versions | wc -l
```

6. Read the object schema from the server, not from a blog post. `kubectl explain` is served from the cluster's own OpenAPI document.

```bash
kubectl explain pod.spec.containers.resources
kubectl explain deployment.spec.strategy.rollingUpdate --recursive
```

### Check your understanding

* **Q0.1** — The kernel version reported for every node is identical and matches your workstation's kernel. What does that tell you about what a `kind` node actually is, and which part of "node isolation" this lab therefore cannot demonstrate faithfully?
* **Q0.2** — `kubectl api-resources` shows a `SHORTNAMES`, `APIVERSION`, `NAMESPACED` and `KIND` column. Why can two different clusters running the identical Kubernetes version return different rows here?
* **Q0.3** — `CONTAINER-RUNTIME` reads `containerd://2.1.1`, never `docker://`. Which architectural component was removed in Kubernetes v1.24 to make that so, and what interface does the kubelet speak to containerd today?
* **Q0.4** — Where does `kubectl explain` get its field documentation from, and why does that matter when you work with CustomResourceDefinitions?

---

## Exercise 1 — The control plane is just Pods (that nothing schedules)

The kubeadm-style control plane used by `kind` runs `etcd`, `kube-apiserver`, `kube-controller-manager` and `kube-scheduler` as **static Pods**: the kubelet reads manifests off local disk and starts them itself, with no API server and no scheduler in the loop. This is the bootstrap trick that resolves the chicken-and-egg problem of a control plane that would otherwise need itself in order to start.

### Steps

1. List the control-plane workloads and note the naming pattern.

```bash
kubectl -n kube-system get pods -o wide --sort-by=.spec.nodeName
```

```
NAME                                           READY   STATUS    RESTARTS   AGE     IP           NODE
coredns-668d6bf9bc-4kt2m                       1/1     Running   0          4m12s   10.244.0.3   lpi703-control-plane
coredns-668d6bf9bc-x9lq7                       1/1     Running   0          4m12s   10.244.0.2   lpi703-control-plane
etcd-lpi703-control-plane                      1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kindnet-2xq7v                                  1/1     Running   0          4m12s   172.18.0.4   lpi703-control-plane
kube-apiserver-lpi703-control-plane            1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kube-controller-manager-lpi703-control-plane   1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kube-proxy-9cqd2                               1/1     Running   0          4m12s   172.18.0.4   lpi703-control-plane
kube-scheduler-lpi703-control-plane            1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kube-proxy-hs4bk                               1/1     Running   0          4m05s   172.18.0.2   lpi703-worker
kindnet-8vlgc                                  1/1     Running   0          4m05s   172.18.0.2   lpi703-worker
...
```

2. Prove they are static, by looking for the mirror-Pod annotation and the missing controller owner.

```bash
kubectl -n kube-system get pod kube-scheduler-lpi703-control-plane \
  -o jsonpath='{.metadata.annotations.kubernetes\.io/config\.source}{"\n"}{.metadata.ownerReferences}{"\n"}'
```

```
file
[{"apiVersion":"v1","controller":true,"kind":"Node","name":"lpi703-control-plane","uid":"6c0a..."}]
```

3. Read the manifests on disk and the kubelet setting that points at them.

```bash
docker exec lpi703-control-plane ls -l /etc/kubernetes/manifests/
docker exec lpi703-control-plane grep -i staticPodPath /var/lib/kubelet/config.yaml
```

```
-rw------- 1 root root 2405 Sep  3 09:12 etcd.yaml
-rw------- 1 root root 3896 Sep  3 09:12 kube-apiserver.yaml
-rw------- 1 root root 3428 Sep  3 09:12 kube-controller-manager.yaml
-rw------- 1 root root 1656 Sep  3 09:12 kube-scheduler.yaml
staticPodPath: /etc/kubernetes/manifests
```

4. Inspect how the API server was configured. Every architectural decision of this cluster is an argument on this command line.

```bash
docker exec lpi703-control-plane \
  grep -E 'etcd-servers|service-cluster-ip-range|admission|authorization-mode|client-ca|advertise-address' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
    - --advertise-address=172.18.0.4
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --etcd-servers=https://127.0.0.1:2379
    - --service-cluster-ip-range=10.96.0.0/16
```

5. Now break it on purpose. Move the scheduler manifest away and watch the kubelet act as the reconciler.

```bash
docker exec lpi703-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
sleep 20
kubectl -n kube-system get pod -l component=kube-scheduler
```

```
No resources found in kube-system namespace.
```

6. With no scheduler running, create a Deployment and observe exactly what stops working — and what does not.

```bash
kubectl create deployment probe --image=registry.k8s.io/pause:3.10 --replicas=2
kubectl get pods -l app=probe -o wide
```

```
NAME                     READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE
probe-7d4f8b9c65-fs2vp   0/1     Pending   0          12s   <none>   <none>   <none>
probe-7d4f8b9c65-nk8zq   0/1     Pending   0          12s   <none>   <none>   <none>
```

7. Restore the scheduler and confirm self-healing.

```bash
docker exec lpi703-control-plane mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sleep 20
kubectl get pods -l app=probe -o wide
kubectl -n kube-system get lease | grep -E 'scheduler|controller'
```

```
NAME                                   HOLDER                                        AGE
kube-controller-manager                lpi703-control-plane_4e1b...                  9m
kube-scheduler                          lpi703-control-plane_a77c...                 22s
```

8. Clean up.

```bash
kubectl delete deployment probe
```

### Check your understanding

* **Q1.1** — Static Pods have an `ownerReference` pointing at a **Node**, not at a ReplicaSet or DaemonSet. What is the object in the API called, who creates it, and what happens if you run `kubectl delete pod kube-scheduler-lpi703-control-plane`?
* **Q1.2** — With the scheduler gone, the ReplicaSet still created two Pod objects. Which component created them, and what precise field distinguishes a Pod the scheduler has not yet handled?
* **Q1.3** — `--etcd-servers=https://127.0.0.1:2379` on the API server. Why is that loopback address architecturally significant, and what does it tell you about who is allowed to talk to etcd?
* **Q1.4** — `kube-scheduler` and `kube-controller-manager` hold a **Lease** object; `kube-apiserver` does not. Explain the difference in concurrency model between these components and why only some of them need leader election.
* **Q1.5** — The `--enable-admission-plugins=NodeRestriction` flag adds one plugin to a default list. In the request pipeline, at which stage does admission run relative to authentication, authorization and etcd persistence?

---

## Exercise 2 — kubectl is an HTTP client; the API server is the only door

Everything in Kubernetes is a REST resource behind one endpoint. Internalising this converts most "kubectl is doing something weird" problems into "read the request".

### Steps

1. Watch the actual HTTP traffic for a trivial command.

```bash
kubectl get pods -n kube-system -v=6 2>&1 | head -5
```

```
I0903 09:31:02.114  round_trippers.go:553] GET https://127.0.0.1:39217/api/v1/namespaces/kube-system/pods?limit=500 200 OK in 18 milliseconds
```

Raise verbosity to see headers, body and the content negotiation:

```bash
kubectl get pod -n kube-system etcd-lpi703-control-plane -v=8 2>&1 | grep -E 'Request Headers|Accept:|Response Status'
```

```
I0903 09:31:44.220  round_trippers.go:470] Request Headers:
I0903 09:31:44.220  round_trippers.go:474]     Accept: application/json;as=Table;v=v1;g=meta.k8s.io,application/json
I0903 09:31:44.240  round_trippers.go:577] Response Status: 200 OK in 19 milliseconds
```

2. Call the API without `kubectl`'s formatting, using its credentials.

```bash
kubectl get --raw /api/v1/namespaces/kube-system/pods?limit=1 | jq '.items[0].metadata.name, .metadata.resourceVersion'
```

3. Query the health endpoints the load balancer and your monitoring should be using.

```bash
kubectl get --raw '/livez?verbose' | head -8
kubectl get --raw '/readyz?verbose' | tail -5
```

```
[+]ping ok
[+]log ok
[+]etcd ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
...
readyz check passed
```

4. Compare with the deprecated way of asking the same question.

```bash
kubectl get componentstatuses
```

```
Warning: v1 ComponentStatus is deprecated in v1.19+
NAME                 STATUS      MESSAGE                         ERROR
scheduler            Healthy     ok
controller-manager   Healthy     ok
etcd-0               Healthy     ok
```

5. Establish what your identity is allowed to do. This is how you check RBAC without reading a single Role.

```bash
kubectl auth whoami
kubectl auth can-i --list --namespace kube-system | head
kubectl auth can-i delete pods --all-namespaces
kubectl auth can-i create pods --as=system:serviceaccount:default:default
```

```
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubernetes-admin system:masters system:authenticated]
...
yes
no
```

6. Use a `watch` to see the event stream that every controller consumes. Leave it running in one terminal:

```bash
kubectl get pods -w --output-watch-events
```

In a second terminal:

```bash
kubectl run watched --image=registry.k8s.io/pause:3.10
```

The first terminal shows the ADDED/MODIFIED sequence:

```
EVENT      NAME      READY   STATUS              RESTARTS   AGE
ADDED      watched   0/1     Pending             0          0s
MODIFIED   watched   0/1     Pending             0          0s
MODIFIED   watched   0/1     ContainerCreating   0          0s
MODIFIED   watched   1/1     Running             0          2s
```

7. Stop the watch and delete the Pod.

```bash
kubectl delete pod watched
```

### Check your understanding

* **Q2.1** — At `-v=8` the `Accept` header requests `application/json;as=Table;v=v1;g=meta.k8s.io` before plain JSON. What is server-side printing, and what breaks in your tooling if you assume the columns of `kubectl get` are stable?
* **Q2.2** — Distinguish `/healthz`, `/livez` and `/readyz`. Which one belongs in a load balancer's backend check for a multi-master control plane, and what would go wrong if you used the wrong one during a rolling upgrade?
* **Q2.3** — `kubectl auth can-i --list` returned answers instantly, without your client parsing any Role or RoleBinding. Which API is being called, and why is asking the server strictly more correct than reading the RBAC objects yourself?
* **Q2.4** — Your credentials place you in the group `system:masters`. What does RBAC do when it sees that group, and why is this the single most dangerous line in a kubeconfig file?
* **Q2.5** — In the watch stream you saw `MODIFIED` twice before the container was created. Explain the role of `resourceVersion` in a watch and what a client must do when the server returns `410 Gone`.

---

## Exercise 3 — etcd: the only stateful thing in the cluster

Every object you have created lives as a serialised value under a hierarchical key in etcd. Reading it directly demystifies "where does state live", and shows you exactly what a backup must capture.

### Steps

1. Open a shell against etcd using the client certificates kubeadm generated.

```bash
docker exec -it lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table'
```

```
+------------------------+------------------+---------+---------+-----------+------------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM  |
+------------------------+------------------+---------+---------+-----------+------------+
| https://127.0.0.1:2379 | 9d1e5f2a3c4b6d78 |  3.5.21 |  3.1 MB | true      |          2 |
+------------------------+------------------+---------+---------+-----------+------------+
```

2. Define a shorthand and list the top of the key space.

```bash
docker exec -it lpi703-control-plane sh -c '
alias e="ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
 --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key";
e get /registry --prefix --keys-only | sed "/^$/d" | cut -d/ -f1-3 | sort -u | head -25'
```

```
/registry/apiextensions.k8s.io
/registry/apiregistration.k8s.io
/registry/clusterrolebindings
/registry/clusterroles
/registry/configmaps
/registry/controllerrevisions
/registry/daemonsets
/registry/deployments
/registry/leases
/registry/masterleases
/registry/namespaces
/registry/pods
/registry/priorityclasses
/registry/replicasets
/registry/secrets
/registry/serviceaccounts
/registry/services
```

3. Create an object and find its exact key.

```bash
kubectl create configmap etcd-demo --from-literal=lesson=703.1
docker exec -it lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key \
 get /registry/configmaps/default/etcd-demo'
```

```
/registry/configmaps/default/etcd-demo
k8s

v1 ConfigMap

etcd-demo default"*$3f9a1c02-7b41-4d1e-9c0b-1f2a6c8d40e12
lesson703.1
```

4. Compare with a Secret, and draw the security conclusion.

```bash
kubectl create secret generic etcd-demo-secret --from-literal=token=s3cr3t-value
docker exec -it lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key \
 get /registry/secrets/default/etcd-demo-secret' | strings | grep s3cr3t
```

```
s3cr3t-value
```

5. Take a snapshot — the operation that defines your cluster's RPO.

```bash
docker exec lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key \
 snapshot save /tmp/etcd-snapshot.db && ls -lh /tmp/etcd-snapshot.db'
```

```
{"level":"info","msg":"saved","path":"/tmp/etcd-snapshot.db"}
Snapshot saved at /tmp/etcd-snapshot.db
-rw------- 1 root root 3.2M Sep  3 09:44 /tmp/etcd-snapshot.db
```

6. Clean up.

```bash
kubectl delete configmap etcd-demo
kubectl delete secret etcd-demo-secret
```

### Check your understanding

* **Q3.1** — The Secret's value came back as readable plaintext. Given that `kubectl get secret -o yaml` shows base64, state precisely what base64 provides here and name the two mechanisms that actually protect Secrets at rest and in transit.
* **Q3.2** — Keys follow `/registry/<resource>/<namespace>/<name>`, but `/registry/clusterroles/` has only two segments after `registry`. What does that structural difference encode, and how does it relate to the `NAMESPACED` column from Exercise 0?
* **Q3.3** — An etcd snapshot captures cluster state but not the PersistentVolume data or the container images. After restoring a snapshot taken 30 minutes ago onto a running cluster, name three categories of divergence you must expect to reconcile.
* **Q3.4** — Production etcd runs 3 or 5 members, never 4. Explain the quorum arithmetic and why an even member count buys you nothing.
* **Q3.5** — Why is `--etcd-servers` pointed at `https://` with client certificates rather than plain HTTP on a private network? Frame the answer in terms of what an etcd write actually authorises.

---

## Exercise 4 — Controllers, ownership, and the reconciliation loop

A Deployment does not create Pods. It creates a ReplicaSet, which creates Pods. Understanding that chain — and the `ownerReferences` that encode it — is what lets you predict the effect of a `kubectl delete`.

### Steps

1. Apply a complete, production-shaped Deployment manifest.

```yaml
# web-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: web
        version: "1"
    spec:
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080"]
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
```

```bash
kubectl apply -f web-deployment.yaml
kubectl rollout status deployment/web --timeout=90s
```

```
deployment.apps/web created
Waiting for deployment "web" rollout to finish: 0 of 3 updated replicas are available...
deployment "web" successfully rolled out
```

2. Walk the ownership chain from Pod to Deployment.

```bash
POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
RS=$(kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].name}')
kubectl get rs "$RS" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

```
ReplicaSet/web-6c9f47d5b8
Deployment/web
```

3. Watch the reconciliation loop close. Delete a Pod and time the replacement.

```bash
kubectl delete pod "$POD" --wait=false
kubectl get pods -l app=web --watch-only --output-watch-events &
sleep 8; kill %1
kubectl get pods -l app=web
```

4. Prove the ReplicaSet owns by **selector**, not by name. Relabel a Pod out of the set.

```bash
VICTIM=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl label pod "$VICTIM" app=orphaned --overwrite
kubectl get pods -L app
```

```
NAME                   READY   STATUS    RESTARTS   AGE   APP
web-6c9f47d5b8-4nqz9   1/1     Running   0          19s   web
web-6c9f47d5b8-8dktp   1/1     Running   0          3m1s  web
web-6c9f47d5b8-p2rvc   1/1     Running   0          3s    web
web-6c9f47d5b8-x7mlk   1/1     Running   0          3m1s  orphaned
```

```bash
kubectl get pod "$VICTIM" -o jsonpath='{.metadata.ownerReferences}{"\n"}'
kubectl delete pod "$VICTIM"
```

5. Trigger a rollout and read the revision history.

```bash
kubectl set image deployment/web web=registry.k8s.io/e2e-test-images/agnhost:2.52
kubectl rollout status deployment/web
kubectl get rs -l app=web
kubectl rollout history deployment/web
```

```
NAME              DESIRED   CURRENT   READY   AGE
web-6c9f47d5b8    0         0         0       5m
web-7f8b5c6d94    3         3         3       31s
```

6. Roll back and confirm the ReplicaSet is reused rather than recreated.

```bash
kubectl rollout undo deployment/web
kubectl get rs -l app=web
```

7. Explore cascading deletion. `orphan` detaches children instead of removing them.

```bash
kubectl delete deployment web --cascade=orphan
kubectl get rs,pods -l app=web
```

```
NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-6c9f47d5b8   3         3         3       7m

NAME                       READY   STATUS    RESTARTS   AGE
pod/web-6c9f47d5b8-4nqz9   1/1     Running   0          4m
...
```

```bash
kubectl delete rs -l app=web        # foreground/background cascade removes the Pods too
kubectl get pods -l app=web
```

### Check your understanding

* **Q4.1** — Name the three objects in the ownership chain and state which controller reconciles each edge. Which of them is responsible for the `maxSurge`/`maxUnavailable` arithmetic?
* **Q4.2** — Relabelling the Pod to `app=orphaned` made the ReplicaSet create a fourth Pod. What happened to the relabelled Pod's `ownerReferences`, and what is the operational use of this trick when debugging a crashing Pod in production?
* **Q4.3** — After `kubectl rollout undo`, the old ReplicaSet's replica count went back up instead of a new ReplicaSet appearing. Explain how the Deployment controller identifies "the same" pod template across revisions, and what `revisionHistoryLimit: 3` actually bounds.
* **Q4.4** — Contrast `--cascade=background` (the default), `--cascade=foreground` and `--cascade=orphan`. Which one blocks the parent's deletion until all children are gone, and which finalizer implements that?
* **Q4.5** — `spec.selector` on a Deployment is immutable after creation. Why did the API designers make it so, given what you just observed about label-based ownership?

---

## Exercise 5 — The scheduler: filtering, scoring and the evidence it leaves

The scheduler's only output is a single write: it sets `spec.nodeName` on a Pod by creating a Binding. Everything else is a decision you can reconstruct from Events.

### Steps

1. Recreate the workload, this time large enough to expose resource pressure.

```bash
kubectl apply -f web-deployment.yaml
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
```

2. Read a node's capacity ledger — the numbers the scheduler filters on.

```bash
kubectl describe node lpi703-worker | sed -n '/Capacity:/,/Events:/p'
```

```
Capacity:
  cpu:                8
  ephemeral-storage:  1055762868Ki
  memory:             16117884Ki
  pods:               110
Allocatable:
  cpu:                8
  ephemeral-storage:  972991057649
  memory:             16015484Ki
  pods:               110
...
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                250m (3%)    400m (5%)
  memory             182Mi (1%)   428Mi (2%)
```

3. Bypass the scheduler entirely to prove where the decision lives.

```yaml
# pinned.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pinned
spec:
  nodeName: lpi703-worker2
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
```

```bash
kubectl apply -f pinned.yaml
kubectl get pod pinned -o wide
kubectl get events --field-selector involvedObject.name=pinned
```

```
LAST SEEN   TYPE     REASON      OBJECT        MESSAGE
9s          Normal   Pulled      pod/pinned    Container image "registry.k8s.io/pause:3.10" already present on machine
9s          Normal   Created     pod/pinned    Created container: pause
9s          Normal   Started     pod/pinned    Started container pause
```

Note what is **absent** from that list.

4. Make scheduling fail, and read the failure message as a structured report.

```bash
kubectl create deployment greedy --image=registry.k8s.io/pause:3.10 --replicas=1 -- \
  2>/dev/null || true
kubectl set resources deployment/greedy --requests=cpu=40 2>/dev/null || \
kubectl patch deployment greedy --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"40"}}}]'
sleep 5
kubectl describe pod -l app=greedy | sed -n '/Events:/,$p'
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  14s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint
  {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu. preemption: 0/3 nodes are available:
  1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
```

5. Inspect the taint that excluded the control-plane node, then remove it and re-read the message.

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl taint node lpi703-control-plane node-role.kubernetes.io/control-plane:NoSchedule-
sleep 10
kubectl describe pod -l app=greedy | grep -A3 'FailedScheduling' | tail -3
```

```
0/3 nodes are available: 3 Insufficient cpu.
```

6. Restore the taint and study `NoExecute` versus `NoSchedule`.

```bash
kubectl taint node lpi703-control-plane node-role.kubernetes.io/control-plane=:NoSchedule
kubectl taint node lpi703-worker2 maintenance=true:NoExecute
sleep 10
kubectl get pods -o wide
kubectl describe pod pinned 2>/dev/null | grep -i -A2 'Status\|Reason' | head
```

7. Undo the maintenance taint and clean up.

```bash
kubectl taint node lpi703-worker2 maintenance-
kubectl delete deployment greedy --ignore-not-found
kubectl delete pod pinned --ignore-not-found
```

8. Compare with the correct production tool for the same intent — draining.

```bash
kubectl drain lpi703-worker2 --ignore-daemonsets --delete-emptydir-data --dry-run=server
kubectl uncordon lpi703-worker2
```

### Check your understanding

* **Q5.1** — The `pinned` Pod produced `Pulled`/`Created`/`Started` Events but no `Scheduled` Event. Which component emits `Scheduled`, and what does its absence prove about how `spec.nodeName` is honoured?
* **Q5.2** — Setting `spec.nodeName` directly still results in a running Pod, yet it is considered an anti-pattern. Name three guarantees you lose by bypassing the scheduler.
* **Q5.3** — Decompose `0/3 nodes are available: 1 node(s) had untolerated taint..., 2 Insufficient cpu`. Which scheduler phase produced each clause, and what does the trailing `preemption:` sentence tell you about PriorityClasses in this cluster?
* **Q5.4** — Your Pod requests `cpu: 40` on nodes with 8 allocatable CPUs. Explain what a CPU *request* means to the scheduler versus what a CPU *limit* means to the kubelet and the kernel — and which of the two the scheduler ignores.
* **Q5.5** — `NoSchedule` versus `NoExecute` versus `PreferNoSchedule`: which one affects already-running Pods, and how does `kubectl drain` achieve the same operational outcome with a mechanism that respects PodDisruptionBudgets?

---

## Exercise 6 — The kubelet's contract with the node

The kubelet is the only agent that touches the container runtime. It reports node status, enforces the resource contract, runs probes and evicts under pressure.

### Steps

1. Look at the kubelet from the outside — as a systemd unit inside the node container.

```bash
docker exec lpi703-worker systemctl is-active kubelet
docker exec lpi703-worker journalctl -u kubelet --no-pager -n 8 -o cat
```

2. Read the kubelet's own configuration. Since v1.11 nearly all of it lives in a config file, not on the command line.

```bash
docker exec lpi703-worker grep -E 'cgroupDriver|containerRuntimeEndpoint|evictionHard|imagefs|nodefs|maxPods|clusterDNS|clusterDomain' -A3 \
  /var/lib/kubelet/config.yaml
```

```
cgroupDriver: systemd
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
evictionHard:
  imagefs.available: 0%
  nodefs.available: 0%
  nodefs.inodesFree: 0%
```

3. Talk to the container runtime the way the kubelet does, via CRI.

```bash
docker exec lpi703-worker crictl ps --output table | head -6
docker exec lpi703-worker crictl pods --output table | head -4
docker exec lpi703-worker crictl images | head -5
```

```
CONTAINER      IMAGE          CREATED         STATE     NAME         ATTEMPT   POD ID         POD
a4f2c1b8e0d13  9c1a8b7f...    3 minutes ago   Running   web          0         7e21d0f4a9c11  web-6c9f47d5b8-4nqz9
1b93de77c2a05  0f7e4a2c...    9 minutes ago   Running   kube-proxy   0         c8d5e1a3b7f92  kube-proxy-hs4bk
```

4. Observe the node heartbeat mechanism — Leases, not full status updates.

```bash
kubectl -n kube-node-lease get lease lpi703-worker -o yaml | grep -E 'holderIdentity|renewTime|leaseDurationSeconds'
kubectl get node lpi703-worker -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
```

```
DiskPressure     False   KubeletHasNoDiskPressure
MemoryPressure   False   KubeletHasSufficientMemory
PIDPressure      False   KubeletHasSufficientPID
Ready            True    KubeletReady
```

5. Watch the kubelet enforce a memory limit. This Pod requests more than it is allowed.

```yaml
# oom.yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom
spec:
  restartPolicy: Never
  containers:
    - name: hog
      image: registry.k8s.io/e2e-test-images/agnhost:2.53
      command: ["sh","-c","dd if=/dev/zero of=/dev/shm/fill bs=1M count=200; sleep 300"]
      resources:
        requests:
          memory: 32Mi
        limits:
          memory: 64Mi
```

```bash
kubectl apply -f oom.yaml
sleep 15
kubectl get pod oom -o jsonpath='{.status.containerStatuses[0].state}{"\n"}{.status.containerStatuses[0].lastState}{"\n"}'
kubectl describe pod oom | grep -iE 'reason|exit code'
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

6. Classify Quality of Service — the ranking the kubelet uses when it must evict.

```bash
kubectl get pod oom -o jsonpath='{.status.qosClass}{"\n"}'
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
```

7. Clean up.

```bash
kubectl delete pod oom
```

### Check your understanding

* **Q6.1** — `cgroupDriver: systemd` must match the container runtime's setting. Describe the failure mode when kubelet and containerd disagree, and why it is intermittent rather than an immediate startup error.
* **Q6.2** — Node heartbeats write to a **Lease** in `kube-node-lease` every few seconds, while `node.status` is updated far less often. What scalability problem does that split solve, and which object does the node-lifecycle controller watch to decide a node is `NotReady`?
* **Q6.3** — Exit code 137 with reason `OOMKilled`. Which component actually killed the process — kubelet, containerd, or the Linux kernel — and how does 137 decompose?
* **Q6.4** — Give the exact rule that assigns `Guaranteed`, `Burstable` and `BestEffort`, and state the eviction order under node memory pressure.
* **Q6.5** — `crictl ps` shows containers the API server never mentions individually (the `pause` sandbox). What is that container's job, and what would break in a Pod without it?

---

## Exercise 7 — Services, EndpointSlices, kube-proxy and DNS

A `Service` is not a process. It is a stable name and a virtual IP that three independent mechanisms cooperate to make work: the endpoints controller populates membership, kube-proxy programs the dataplane, and CoreDNS answers the name.

### Steps

1. Expose the Deployment and inspect the allocated ClusterIP.

```bash
kubectl expose deployment web --name=web --port=80 --target-port=http
kubectl get svc web -o wide
```

```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE   SELECTOR
web    ClusterIP   10.96.115.24   <none>        80/TCP    5s    app=web
```

2. Look at membership. `EndpointSlice` is the modern object; the legacy `Endpoints` API is deprecated as of v1.33.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.conditions.ready}{"\t"}{.nodeName}{"\n"}{end}'
```

```
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
web-9dk2n   IPv4          8080    10.244.1.5,10.244.2.4,10.244.1.6   12s

10.244.1.5   true   lpi703-worker
10.244.2.4   true   lpi703-worker2
10.244.1.6   true   lpi703-worker
```

3. Determine which dataplane mode kube-proxy is running before you look for rules.

```bash
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode:|^    mode:'
```

An empty value (`mode: ""`) means the platform default — `iptables` on Linux.

4. **If mode is `iptables` (or empty):** find the rule chain for your ClusterIP.

```bash
SVCIP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
docker exec lpi703-worker iptables-save -t nat | grep "$SVCIP"
```

```
-A KUBE-SERVICES -d 10.96.115.24/32 -p tcp -m comment --comment "default/web cluster IP" -m tcp --dport 80 -j KUBE-SVC-LOLE4ISW44XBNF3G
-A KUBE-SVC-LOLE4ISW44XBNF3G ! -s 10.244.0.0/16 -d 10.96.115.24/32 -p tcp -m comment --comment "default/web cluster IP" -j KUBE-MARK-MASQ
```

```bash
docker exec lpi703-worker iptables-save -t nat | grep 'KUBE-SVC-LOLE4ISW44XBNF3G'
```

```
-A KUBE-SVC-LOLE4ISW44XBNF3G -m comment --comment "default/web -> 10.244.1.5:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-BSQ3E4L7QO2X
-A KUBE-SVC-LOLE4ISW44XBNF3G -m comment --comment "default/web -> 10.244.1.6:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-VN2ATRJKM6YZ
-A KUBE-SVC-LOLE4ISW44XBNF3G -m comment --comment "default/web -> 10.244.2.4:8080" -j KUBE-SEP-XR7Q1WFHDA9C
```

**If mode is `nftables`:** the equivalent is

```bash
docker exec lpi703-worker nft list table ip kube-proxy | grep -A6 "$SVCIP"
```

5. Resolve the Service by name from inside the cluster.

```bash
kubectl run dns --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 -- \
  sh -c 'cat /etc/resolv.conf; echo ---; nslookup web; echo ---; nslookup web.default.svc.cluster.local'
```

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
---
Name:   web.default.svc.cluster.local
Address: 10.96.115.24
```

6. Contrast with a **headless** Service, which returns Pod IPs instead of a VIP.

```bash
kubectl create service clusterip web-headless --clusterip=None --tcp=80:8080
kubectl patch service web-headless -p '{"spec":{"selector":{"app":"web"}}}'
kubectl run dns --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 -- \
  nslookup web-headless.default.svc.cluster.local
```

```
Name:   web-headless.default.svc.cluster.local
Address: 10.244.1.5
Name:   web-headless.default.svc.cluster.local
Address: 10.244.1.6
Name:   web-headless.default.svc.cluster.local
Address: 10.244.2.4
```

7. Break readiness and watch the endpoint disappear from the load-balancing set within seconds.

```bash
POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- curl -s "http://localhost:8080/readyz?ok=false" >/dev/null 2>&1 || true
kubectl label pod "$POD" app=quarantine --overwrite
sleep 5
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
kubectl delete pod "$POD"
```

8. Clean up the extra Service.

```bash
kubectl delete svc web-headless
```

### Check your understanding

* **Q7.1** — Nothing listens on `10.96.115.24`. Explain end-to-end what happens to a TCP SYN sent to that address from a Pod on `lpi703-worker`, naming the netfilter hook and the kernel subsystem that keeps the connection pinned to one backend.
* **Q7.2** — The probabilities in the `KUBE-SVC-*` chain read `0.3333`, `0.5`, then none. Why is that sequence uniform rather than biased toward the last endpoint, and what load-balancing property does iptables mode therefore *not* offer?
* **Q7.3** — `/etc/resolv.conf` sets `ndots:5` and a three-entry search list. Trace how many DNS queries `nslookup web` generates versus `nslookup web.default.svc.cluster.local.`, and explain the production latency problem this causes for external hostnames.
* **Q7.4** — Relabelling a Pod removed it from the EndpointSlice. Which controller performed that removal, and what other Pod-level condition produces the same effect without touching labels?
* **Q7.5** — A headless Service has `clusterIP: None`. Name two workload patterns that require this, and explain what kube-proxy programs for such a Service.

---

## Exercise 8 — Declarative usage, field ownership and safe change

The exam objective is *architecture **and usage***. Production usage means declarative manifests under version control, applied with a mechanism that detects concurrent writers.

### Steps

1. Namespaces, quotas and limits — the multi-tenancy primitives.

```yaml
# tenant.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute
  namespace: tenant-a
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: tenant-a
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 128Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
```

```bash
kubectl apply -f tenant.yaml
kubectl -n tenant-a describe quota compute
```

2. Show that the LimitRange mutates a Pod that specifies nothing.

```bash
kubectl -n tenant-a run bare --image=registry.k8s.io/pause:3.10
kubectl -n tenant-a get pod bare -o jsonpath='{.spec.containers[0].resources}{"\n"}'
```

```
{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

3. Prove the quota is enforced at admission, not at scheduling.

```bash
kubectl -n tenant-a create deployment big --image=registry.k8s.io/pause:3.10 --replicas=1
kubectl -n tenant-a patch deployment big --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"900m"},"limits":{"cpu":"1800m"}}}]'
sleep 5
kubectl -n tenant-a get deployment big -o jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")].message}{"\n"}'
```

```
pods "big-..." is forbidden: exceeded quota: compute, requested: limits.cpu=1800m, used: limits.cpu=200m, limited: limits.cpu=2
```

4. Preview a change before applying it — the habit that prevents most outages.

```bash
sed -i 's/replicas: 3/replicas: 5/' web-deployment.yaml
kubectl diff -f web-deployment.yaml
kubectl apply -f web-deployment.yaml --dry-run=server -o yaml | grep -E '^\s+replicas:'
```

5. Adopt server-side apply and inspect field ownership.

```bash
kubectl apply -f web-deployment.yaml --server-side --field-manager=gitops
kubectl get deployment web -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'
```

```
gitops                   Apply
kube-controller-manager  Update
```

6. Create a conflict on purpose — the exact scenario of an HPA fighting your manifest.

```bash
kubectl scale deployment web --replicas=2
kubectl apply -f web-deployment.yaml --server-side --field-manager=gitops
```

```
error: Apply failed with 1 conflict: conflict with "kubectl-scale" using apps/v1: .spec.replicas
Please review the fields above--they were changed at the same time by another
actor. ... use the --force-conflicts flag.
```

```bash
kubectl apply -f web-deployment.yaml --server-side --field-manager=gitops --force-conflicts
```

7. Practise the read-only diagnostic vocabulary you will need under exam time pressure.

```bash
kubectl get pods -A --field-selector=status.phase!=Running
kubectl get events -A --sort-by=.lastTimestamp | tail -10
kubectl top nodes 2>/dev/null || echo "metrics-server not installed — expected in kind"
kubectl logs deployment/web --all-containers --tail=5 --prefix
kubectl describe deployment web | sed -n '/Conditions:/,/Events:/p'
```

8. Tear the lab down.

```bash
kubectl delete namespace tenant-a
kind delete cluster --name lpi703
```

### Check your understanding

* **Q8.1** — The `bare` Pod acquired requests and limits it never declared. Which admission stage did that, and how does it interact with the ResourceQuota that would otherwise have rejected the Pod?
* **Q8.2** — The quota violation surfaced as a `ReplicaFailure` condition on the Deployment rather than a `Pending` Pod. Explain why, and where the operator must look for the message.
* **Q8.3** — Contrast `--dry-run=client` and `--dry-run=server`. Which one would have caught the quota rejection in step 3, and why?
* **Q8.4** — Server-side apply reported a conflict on `.spec.replicas` with manager `kubectl-scale`. Describe what `managedFields` stores, and state the correct GitOps resolution when an HPA legitimately owns `replicas`.
* **Q8.5** — Client-side `kubectl apply` stored intent in the `kubectl.kubernetes.io/last-applied-configuration` annotation. Name two concrete failure modes of that design that server-side apply eliminates.

---

## Answers

<details>
<summary><strong>Click to reveal all answers</strong></summary>

### Exercise 0

**A0.1** — A `kind` "node" is a Docker/Podman **container**, not a virtual machine. It shares the host kernel, so every node reports the host's kernel version and all nodes are identical by construction. Consequently the lab cannot faithfully demonstrate anything that depends on kernel-level or hardware-level isolation between nodes: per-node kernel tuning (`sysctl` differences, cgroup v1 vs v2 divergence), real hardware failure, node-local storage topology, or the security boundary between nodes. It also means a kernel panic or a global `sysctl` change affects all "nodes" at once. Everything *above* the kernel — the kubelet, CRI, cgroup accounting, netfilter rules per network namespace — behaves faithfully, which is why the rest of the exercises are valid.

**A0.2** — `api-resources` is generated from the cluster's live **discovery document**, which reflects: (a) which built-in API groups are enabled on this API server (`--runtime-config` can switch groups and versions on and off); (b) every installed **CustomResourceDefinition**, which adds rows dynamically; and (c) every **APIService** registered by an aggregated API server (metrics-server publishes `metrics.k8s.io`, for example). Two clusters on identical Kubernetes versions differ as soon as one has an operator, a service mesh or metrics-server installed. This is why hard-coding a resource list in tooling is a bug: always discover.

**A0.3** — **dockershim**, the in-tree adapter that let the kubelet drive Docker Engine, was removed in v1.24. The kubelet now speaks the **Container Runtime Interface (CRI)** — a gRPC API with a `RuntimeService` and an `ImageService` — over a Unix socket, to containerd, CRI-O or any other CRI-conformant runtime. Docker Engine can still *build* images; it is simply no longer what runs them on a node. The `containerd://` prefix in `CONTAINER-RUNTIME` is the runtime endpoint the kubelet reported to the API server.

**A0.4** — From the **OpenAPI schema published by the API server itself** (`/openapi/v3`), not from a compiled-in copy. That is why `kubectl explain` documents CRDs: when a CRD carries an OpenAPI v3 `schema` in its `spec.versions[].schema.openAPIV3Schema`, the API server merges it into the published document and `kubectl explain mycrd.spec.foo` works with the descriptions the CRD author wrote. It also means `explain` output tracks the cluster's version, so it never disagrees with what the server will actually accept.

### Exercise 1

**A1.1** — The API object is a **mirror Pod**. The kubelet creates it *on behalf of* a static Pod so the static Pod is visible through the API; ownership is attributed to the Node because no controller manages it. Deleting the mirror Pod deletes only the API object — the real container keeps running, and the kubelet recreates the mirror Pod within a sync period. To actually stop a static Pod you must move or edit its manifest in `staticPodPath` (which is what step 5 did). This asymmetry is a classic incident: "I deleted the apiserver Pod and nothing happened."

**A1.2** — The **ReplicaSet controller**, running inside `kube-controller-manager`, which was unaffected by the missing scheduler. The distinguishing field is **`spec.nodeName`**: it is empty on an unscheduled Pod. `status.phase` is `Pending` and the `PodScheduled` condition is `False` with reason `Unschedulable`, but `spec.nodeName == ""` is the authoritative marker. This cleanly separates the two responsibilities: controllers decide *how many* Pods should exist; the scheduler decides *where* each one goes.

**A1.3** — The API server reaches etcd over the node's loopback interface because both run on the same host, and — more importantly — because **etcd should never be reachable from the cluster network**. There is no authorization layer in front of etcd's key space: a client with a valid etcd client certificate can read every Secret and write any object, bypassing RBAC, admission control and validation entirely. Therefore etcd's threat model is "the API server is the only client", enforced by network placement plus mutual TLS. Exposing etcd is equivalent to handing out `cluster-admin` plus the ability to forge state.

**A1.4** — `kube-apiserver` is **stateless and horizontally scalable**: N replicas can serve requests simultaneously because all shared state lives in etcd and concurrent writes are resolved by optimistic concurrency on `resourceVersion`. `kube-scheduler` and `kube-controller-manager` are **active/passive**: they run reconciliation loops that make decisions (bind this Pod, create that ReplicaSet). Two active schedulers would race to bind the same Pod to different nodes; two controller-managers would double-create replicas. They therefore contend for a `Lease` object in `kube-system`, and only the holder runs its loops — the others sit hot-standby, watching the lease expire.

**A1.5** — The pipeline is: **authentication → authorization → mutating admission → schema validation → validating admission → persistence in etcd**. Admission therefore runs *after* the request is authenticated and authorized, and *before* anything is written. Mutating plugins can change the object (LimitRange defaults, ServiceAccount token projection, sidecar injection by a webhook); validating plugins can only accept or reject (ResourceQuota, NodeRestriction, Pod Security admission). `NodeRestriction` specifically limits what a kubelet's own credentials may modify — it may not edit other nodes or Pods not bound to it, which contains the blast radius of a stolen node certificate.

### Exercise 2

**A2.1** — Server-side printing means the **API server renders the table** — column names, ordering and cell contents — and returns a `meta.k8s.io/v1 Table` object; `kubectl` merely aligns the text. It exists so that CRDs can define their own columns (`additionalPrinterColumns`) and so the client does not need type-specific knowledge. The consequence: **columns are a presentation contract owned by the server and may change between versions or with a CRD update**. Any script doing `kubectl get pods | awk '{print $3}'` is parsing an unstable interface. Use `-o jsonpath`, `-o json | jq`, or `--output=custom-columns`, all of which read the real object fields.

**A2.2** — `/livez` answers "is this process healthy, or should it be restarted?" `/readyz` answers "is this instance ready to *serve traffic*?" — it additionally waits for informers to sync, for the API to finish startup hooks, and it reports failure during graceful shutdown. `/healthz` is the legacy endpoint that conflated both and is deprecated. A load balancer must use **`/readyz`**: with `/livez` the LB would send traffic to an API server that is up but has not finished initialising its caches, and during a rolling upgrade it would keep sending requests to an instance that has entered shutdown and is draining — producing connection resets exactly when you are least able to tolerate them. Add `?exclude=etcd` only when you deliberately want the instance to stay in rotation while etcd is degraded.

**A2.3** — `SelfSubjectRulesReview` (and `SelfSubjectAccessReview` / `SubjectAccessReview` for single checks) in the `authorization.k8s.io/v1` group. Asking the server is strictly more correct because the server evaluates the *whole* authorization chain in its configured order: `Node`, `RBAC`, possibly `ABAC` or a `Webhook` authorizer, plus every ClusterRoleBinding and RoleBinding that matches your user **and all of your groups**, including groups injected by an OIDC provider or a certificate's `O=` fields. Reading RBAC objects by hand reproduces none of that, and silently misses non-RBAC authorizers.

**A2.4** — `system:masters` is **short-circuited**: the RBAC authorizer grants it unconditionally through a hard-coded binding to `cluster-admin`, and it is evaluated before any Role lookup. It cannot be revoked by editing RBAC, it is not subject to admission-time restrictions you might expect, and — critically — **client certificates cannot be revoked** in Kubernetes (there is no CRL/OCSP support in the standard authenticator). A leaked kubeconfig containing an `O=system:masters` certificate is permanent, cluster-wide root until you rotate the entire cluster CA. Human access should come from OIDC or short-lived credentials, never from the kubeadm-generated admin certificate.

**A2.5** — Every object carries a `metadata.resourceVersion`, an opaque token derived from etcd's revision counter. A watch is started with `resourceVersion=<N>` and the server streams every change *after* N, so a client can disconnect and resume without missing or replaying events — this is the foundation of every controller's informer cache. **`410 Gone`** means the requested resourceVersion has fallen out of the server's watch cache window (etcd compaction, or a long client outage). The client must then **re-LIST** to obtain a fresh full state and a new resourceVersion, then restart the watch from there. Treating resourceVersion as a number to increment or compare across resource types is a bug: it is opaque.

### Exercise 3

**A3.1** — base64 is a **transport encoding**, not encryption; it exists so arbitrary binary data can live in a JSON/YAML string field. It provides zero confidentiality. The two mechanisms that do: (1) **encryption at rest** via the API server's `--encryption-provider-config`, which encrypts resources (typically `secrets`) with AES-GCM or, better, a KMS provider that keeps the key material in an external HSM/KMS so an etcd disk image is useless alone; and (2) **TLS everywhere** — etcd peer and client TLS, and the API server's serving certificate — for confidentiality in transit. Beyond that, RBAC must restrict who can `get` Secrets, and you should prefer short-lived projected ServiceAccount tokens or an external secret store over long-lived Secret objects.

**A3.2** — The number of segments encodes **scope**. Namespaced resources are keyed `/registry/<resource>/<namespace>/<name>`, so the namespace is a real prefix in the key space; a namespace deletion is a prefix operation, and a LIST scoped to a namespace is a prefix range read — which is why namespaced LISTs are cheaper than cluster-wide ones. Cluster-scoped resources (`clusterroles`, `nodes`, `persistentvolumes`, `namespaces` themselves) have no namespace segment. This is exactly the `NAMESPACED` boolean column from `kubectl api-resources`, and it is why `kubectl get clusterrole -n foo` silently ignores the namespace flag.

**A3.3** — (1) **Storage**: PersistentVolume objects will be restored pointing at volumes whose actual data has moved on 30 minutes; a database restored to a stale PV binding can come back with a split-brain or a corrupted replica set. (2) **Workload identity and external state**: Pods recorded in the snapshot no longer exist on nodes (the kubelets will report the real state and the controllers will recreate/adopt), while anything the cluster did in the outside world during those 30 minutes — cloud load balancers created by the cloud-controller-manager, DNS records, provisioned volumes, external webhooks registered — is now orphaned or duplicated. (3) **Tokens, leases and certificates**: ServiceAccount token bindings, Leases, and any certificate issued through the CSR API in that window vanish from the restored state, so agents may need to re-register; conversely bootstrap tokens you rotated come back alive. This is why the correct restore procedure stops the whole control plane, restores every etcd member from the *same* snapshot, and treats the cluster as needing a reconciliation audit afterwards.

**A3.4** — etcd uses **Raft**, which requires a strict majority (quorum) of `(N/2)+1` members to commit a write. N=3 → quorum 2 → tolerates **1** failure. N=4 → quorum 3 → still tolerates only **1** failure, while adding a fourth machine to fail and increasing write latency (every commit must reach one more member). N=5 → quorum 3 → tolerates **2**. So even counts add cost and failure surface without adding fault tolerance. Beyond 5, write latency grows faster than the availability benefit; 7 is used only for very large multi-AZ deployments, and read scaling is better addressed with the API server's watch cache.

**A3.5** — Because an etcd write is **unmediated authority over the cluster**. There is no RBAC, no admission control and no validation between an etcd client and the key space: whoever can write `/registry/clusterrolebindings/...` grants themselves `cluster-admin`; whoever can read `/registry/secrets/...` has every credential in the cluster. Client certificates are the only authentication etcd has, and TLS is the only confidentiality. "It is a private network" is not a control — it is an assumption that fails the moment a Pod with `hostNetwork: true`, a compromised node, or a misrouted CNI reaches port 2379.

### Exercise 4

**A4.1** — **Deployment → ReplicaSet → Pod.** The **Deployment controller** reconciles the Deployment→ReplicaSet edge: it creates a new ReplicaSet per pod-template revision and orchestrates the rollout by scaling old and new ReplicaSets up and down. The **ReplicaSet controller** reconciles the ReplicaSet→Pod edge: it counts Pods matching its selector and creates or deletes to reach `spec.replicas`. Both live inside `kube-controller-manager`. **`maxSurge`/`maxUnavailable` arithmetic belongs to the Deployment controller** — the ReplicaSet controller knows nothing about rollouts; it only ever converges a count.

**A4.2** — The `ownerReference` was **removed** from the Pod by the ReplicaSet controller. When a Pod stops matching a ReplicaSet's selector, the controller *releases* it (drops the ownerReference), and because the ReplicaSet now sees only 2 matching Pods, it creates a third. The released Pod becomes unowned and survives — no controller will delete it, and no controller will restart it if it dies. Operationally this is the **quarantine pattern**: when one replica misbehaves, relabel it out of the Service selector and the ReplicaSet selector, and you get a live, isolated, no-longer-serving copy to `exec` into, take a heap dump from, or run `tcpdump` against, while the Deployment immediately restores full capacity. Remember to delete it afterwards — nothing else will.

**A4.3** — The Deployment controller computes a **hash of the pod template** (`pod-template-hash`), stamps it as a label on the ReplicaSet and on the Pods, and adds it to the ReplicaSet's selector. Two revisions with byte-identical templates hash the same, so `rollout undo` simply **finds the existing ReplicaSet with that hash and scales it back up** rather than creating a new one — which is why the rollback is fast and why image layers are already present on the nodes. `revisionHistoryLimit: 3` bounds the number of **old, scaled-to-zero ReplicaSets** retained; those empty ReplicaSets *are* the rollback history, so setting it to 0 makes `rollout undo` impossible.

**A4.4** — **`background`** (default): the parent is deleted immediately and the garbage collector removes children asynchronously afterwards. **`foreground`**: the API server adds the `foregroundDeletion` finalizer to the parent, sets `deletionTimestamp`, and keeps the parent object alive — visible, marked for deletion — until every dependent with `blockOwnerDeletion: true` is gone; only then is the parent removed. **`orphan`**: dependents' `ownerReferences` are stripped and they survive independently. So `foreground` is the one that blocks, and it is implemented by the **`foregroundDeletion` finalizer** processed by the garbage collector in `kube-controller-manager`.

**A4.5** — Because ownership is established purely by **label selector matching**, a mutable selector would let a Deployment silently adopt or abandon Pods and ReplicaSets that belong to another controller — including another Deployment. Two Deployments whose selectors were edited to overlap would fight, each trying to converge the shared Pods to its own count and template, in an endless loop. Making `spec.selector` immutable after creation (enforced in `apps/v1`) removes the entire class of ambiguity: the ownership graph can only be changed by deleting and recreating the object. When you must change a selector, you create a new Deployment and migrate traffic.

### Exercise 5

**A5.1** — `Scheduled` is emitted by the **`default-scheduler`**, and only when the scheduler itself performs the binding. Its absence proves the scheduler was never involved: `spec.nodeName` was already set at creation time, so the Pod was never in the scheduler's queue. The **kubelet on the named node** watches for Pods whose `spec.nodeName` equals its own node name and runs them directly — the field, not the scheduler, is what the kubelet acts on. The scheduler is therefore best understood as "the component that fills in an empty field", not as a gatekeeper.

**A5.2** — (1) **Resource feasibility.** The kubelet will admit the Pod even if the node's remaining allocatable capacity cannot satisfy the requests — you can overcommit a node into eviction, or the kubelet rejects it with `OutOfcpu` and, because nothing reschedules it, the Pod is simply stuck. (2) **Policy enforcement.** Taints/tolerations, node affinity/anti-affinity, pod (anti-)affinity, topology spread constraints and PriorityClass preemption are all evaluated by the scheduler and are silently skipped. (3) **Reschedulability.** A Pod pinned by name cannot move: if the node dies, the Pod object is not re-placed anywhere — with a bare Pod it is simply lost, and even under a controller the replacement inherits the same hard-coded node. Additionally you lose scheduler-observability (no `FailedScheduling` diagnostics) and any scheduler-plugin behaviour such as dynamic resource allocation.

**A5.3** — The scheduler runs **filter** (predicates) then **score** (priorities). The clause `1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }` is the **TaintToleration filter** rejecting the control-plane node; `2 Insufficient cpu` is the **NodeResourcesFit filter** rejecting both workers because `requests.cpu` exceeds allocatable minus already-requested. Scoring never ran, because zero nodes survived filtering. The trailing `preemption: ... Preemption is not helpful ... No preemption victims found` means the scheduler then attempted **preemption**: it looked for lower-priority Pods it could evict to make room. "Not helpful" for the tainted node (evicting Pods would not fix a taint), and "no victims" on the workers means either no Pod there has a lower PriorityClass than the pending Pod, or evicting all eligible ones still would not free 40 CPUs. Practically, this cluster has no meaningful PriorityClass hierarchy configured.

**A5.4** — A **request** is a *scheduling* claim: the scheduler sums `requests.cpu` over all non-terminated Pods on a node and refuses to place a Pod if the sum would exceed `allocatable.cpu`. It is bookkeeping — it is not enforced at runtime except as a cgroup **`cpu.weight`/`cpu.shares`** floor that only matters under contention. A **limit** is a *runtime* cap enforced by the kubelet through the cgroup: for CPU it becomes `cpu.max` (CFS quota), so the process is **throttled**, never killed; for memory it becomes `memory.max`, and exceeding it gets the process **OOM-killed**. **The scheduler ignores limits entirely** — which is exactly why a node can be scheduled to 100% of requests while its limits sum to 400% of capacity. That gap is the overcommit you saw annotated in `describe node` as "Total limits may be over 100 percent".

**A5.5** — **`NoSchedule`** prevents *new* Pods without a matching toleration from being placed; already-running Pods are untouched. **`PreferNoSchedule`** is the soft version — a scoring penalty, not a filter. **`NoExecute`** is the one that affects running Pods: Pods without a matching toleration are **evicted**, immediately or after `tolerationSeconds`. `kubectl drain` achieves the same outcome correctly because it (a) **cordons** the node first (sets `spec.unschedulable`, equivalent to a `NoSchedule` taint) so nothing new lands, and (b) evicts each Pod through the **Eviction API** (`policy/v1`), which is checked against **PodDisruptionBudgets** — so an eviction that would drop a Deployment below its `minAvailable` is refused with `429 Too Many Requests` and drain waits instead of causing an outage. A `NoExecute` taint bypasses PDBs entirely; drain respects them. Also note drain needs `--ignore-daemonsets`, because DaemonSet Pods are immediately recreated by design.

### Exercise 6

**A6.1** — If kubelet and containerd use different cgroup drivers, **two separate cgroup hierarchies** are created for the same containers: containerd places the container in its own tree while the kubelet accounts and enforces in another. The result is not a startup error — both processes start fine and Pods run — but resource enforcement and accounting become unreliable: limits may not be applied, `kubectl top` and eviction signals report wrong values, and under memory pressure the node behaves erratically or the kubelet evicts based on figures that do not match reality. It manifests intermittently, only under load, which is why it is notoriously hard to diagnose. On a systemd host, both must be `systemd` — this is the single most common kubeadm misconfiguration.

**A6.2** — Writing the full `node.status` object (dozens of fields, including images and allocatable) every few seconds from thousands of nodes generated an enormous, mostly redundant **write load on etcd**, because every heartbeat was a full object update that had to be persisted and pushed to every watcher. The Lease split it: the kubelet renews a tiny `Lease` object in the `kube-node-lease` namespace every `nodeLeaseDurationSeconds/4` (default heartbeat 10s), while `node.status` is only written when something actually changes or every `nodeStatusReportFrequency` (default 5m). The **node-lifecycle controller** watches the **Lease** to decide liveness; if it is not renewed within the monitor grace period (default 40s) the node's `Ready` condition is set to `Unknown` and, after `--pod-eviction-timeout`/the `node.kubernetes.io/unreachable:NoExecute` taint's `tolerationSeconds` (default 300s), its Pods are evicted.

**A6.3** — The **Linux kernel OOM killer** killed it. When the container's cgroup hits `memory.max`, the kernel's memory cgroup subsystem selects and kills a process inside that cgroup — the kubelet is not in the path and cannot prevent it. What the kubelet does is *observe* the outcome: containerd reports the exit status, the kubelet reads the cgroup's OOM event and sets `reason: OOMKilled` in the container status. **137 = 128 + 9**: by POSIX shell convention an exit code above 128 means "terminated by signal N", and 9 is `SIGKILL`, which OOM kill always uses (it is not catchable). Contrast with 143 = 128 + 15 (`SIGTERM`), which is a normal graceful stop.

**A6.4** — **`Guaranteed`**: *every* container in the Pod (including init containers) specifies both requests and limits for **both** CPU and memory, and requests equal limits for each. **`BestEffort`**: *no* container specifies any request or limit at all. **`Burstable`**: everything else — at least one request or limit is set, but the Guaranteed condition is not met. Under node memory pressure the kubelet evicts in the order **BestEffort → Burstable → Guaranteed**, and within a class it ranks by how far the Pod's memory usage exceeds its request (and by Pod priority). Guaranteed Pods are evicted only if they exceed their own limits or the node is in a state that requires it — this is why latency-critical or stateful workloads are given `requests == limits`.

**A6.5** — It is the **sandbox / "pause" container**. It is the first container started in a Pod and it does essentially nothing: it allocates and **holds open the Pod's shared namespaces** — chiefly the network namespace (hence the Pod IP), plus IPC and, when configured, the PID namespace — and reaps orphaned zombie processes. All application containers in the Pod then *join* those namespaces, which is precisely why they share `localhost` and a single IP. Without it there would be nothing to keep the network namespace alive between restarts of the application container: the Pod IP would change every time your app crashed, and the CNI plugin would have to re-run on each restart. It does not appear as a container in the Pod spec because it is an implementation detail of the CRI runtime, which is why you only see it with `crictl`.

### Exercise 7

**A7.1** — The SYN leaves the Pod's network namespace destined for `10.96.115.24:80` — an address that belongs to no interface and answers no ARP. It is routed to the node's root namespace, where kube-proxy's rules in the **`nat` table** intercept it. Specifically, the `KUBE-SERVICES` chain is reached from **`PREROUTING`** (for traffic entering from a Pod veth) and from **`OUTPUT`** (for host-originated traffic); a match on destination IP and port jumps to the service chain, which picks one endpoint and performs **DNAT** to that Pod IP and target port (`10.244.1.5:8080`). The **conntrack** subsystem records the translation, so every subsequent packet of that flow — and the reply path, un-DNATed automatically — follows the same backend. `KUBE-MARK-MASQ` marks packets that need SNAT on egress (traffic that did not originate inside the Pod CIDR) so replies come back through the node. The client therefore never learns the real backend IP; the ClusterIP exists only as netfilter state.

**A7.2** — iptables evaluates the chain **sequentially**, and `-m statistic --mode random --probability p` is a per-rule coin flip that only sees the packets which reached that rule. The first rule takes 1/3 of all packets; the second sees the remaining 2/3 and takes half of them = 1/3 of the total; the third is unconditional and catches the last 1/3. The probabilities are computed as `1/(n-i)` precisely to make the outcome uniform. What this design does **not** provide is any awareness of backend state: it is stateless random selection, so there is **no least-connections, no latency- or load-aware balancing, no retry on a failed backend, and no connection draining** — a connection DNAT'ed to a Pod that dies mid-flow is simply reset, and conntrack keeps it pinned there until the entry expires. Real load-aware balancing requires IPVS mode (which offers `rr`, `lc`, `sh` and others), or an L7 proxy / service mesh.

**A7.3** — `ndots:5` means: if the queried name contains **fewer than 5 dots** and is not fully qualified with a trailing dot, the resolver tries each entry of the `search` list **first**, before the name as given. `nslookup web` (0 dots) therefore issues, in order: `web.default.svc.cluster.local` → hit on the first try (so 1 successful query, though A and AAAA are separate queries). `nslookup web.default.svc.cluster.local` (4 dots — still < 5!) also walks the search list first: `web.default.svc.cluster.local.default.svc.cluster.local` (NXDOMAIN), `...svc.cluster.local` (NXDOMAIN), `...cluster.local` (NXDOMAIN), and only then the absolute name — **4 lookups instead of 1**. The production consequence is severe for external names: `api.stripe.com` (2 dots) generates three in-cluster NXDOMAINs before the real query, multiplying CoreDNS load and adding latency to every outbound call. Mitigations: append a **trailing dot** to make names fully qualified (`api.stripe.com.`), lower `ndots` per-Pod via `spec.dnsConfig.options`, or deploy **NodeLocal DNSCache**.

**A7.4** — The **EndpointSlice controller** (in `kube-controller-manager`), which watches Services and Pods and maintains the EndpointSlice objects whose `kubernetes.io/service-name` label matches. It removed the Pod because it no longer matched `spec.selector: app=web`. The condition that produces the same effect without touching labels is **readiness**: when a Pod's `Ready` condition goes `False` — a failing `readinessProbe`, or the Pod entering `Terminating` — the controller sets that endpoint's `conditions.ready: false`, and kube-proxy stops programming it as a destination. (With `publishNotReadyAddresses: true` on the Service, or in `conditions.serving`/`terminating` for graceful shutdown handling, the entry remains visible but is treated differently.) This is precisely the mechanism that makes a `readinessProbe` your traffic-admission control.

**A7.5** — (1) **StatefulSets and clustered software** — databases, Kafka, Elasticsearch, etcd itself — where a client must address a *specific* member, not a random one. A headless Service combined with a StatefulSet gives every Pod a stable DNS name, `<pod>.<service>.<namespace>.svc.cluster.local`, which is how peers discover each other and how replication targets are configured. (2) **Client-side load balancing / service discovery**, where a gRPC or application-level balancer wants the full endpoint list so it can maintain persistent connections to every backend and do its own least-request balancing — impossible through a single VIP, which pins each connection to one backend. For a headless Service, **kube-proxy programs nothing at all**: there is no ClusterIP to DNAT, so no iptables/nftables/IPVS rules are created. The entire mechanism is CoreDNS returning multiple A/AAAA records read from the EndpointSlice.

### Exercise 8

**A8.1** — The **LimitRange admission plugin**, which runs during the **mutating admission** phase, injected `defaultRequest` as requests and `default` as limits into every container that omitted them. Ordering is what makes this work: mutation happens **before** validating admission, so by the time the **ResourceQuota** plugin (a validating plugin) evaluates the Pod, the resource fields exist and can be counted against the quota. This ordering is not incidental — it is required, because a ResourceQuota that constrains `requests.cpu` **rejects any Pod with an unset request**. Without a LimitRange supplying defaults, every `kubectl run` in a quota'd namespace would fail with "must specify requests.cpu". LimitRange also enforces `min`/`max` bounds and can reject Pods outright.

**A8.2** — Because the rejection happens when the **ReplicaSet controller** tries to create the Pod — the Pod object is never admitted, so there is no Pending Pod to describe and no Pod-level Event. The controller records the failure by setting the ReplicaSet's `ReplicaFailure` condition, which the Deployment controller surfaces on the Deployment. The operator must look at **`kubectl describe replicaset`** / the Deployment's `status.conditions`, or at Events on the **ReplicaSet** object (`kubectl get events --field-selector involvedObject.kind=ReplicaSet`). This is a classic diagnostic trap: `kubectl get pods` shows nothing wrong because there is nothing there, and the Deployment merely reports fewer ready replicas than desired. Any admission rejection — quota, Pod Security admission, a validating webhook — behaves this way for controller-created Pods.

**A8.3** — `--dry-run=client` renders the object locally and prints it; it never contacts the API server, so it validates nothing beyond basic client-side schema parsing. `--dry-run=server` sends the request with `dryRun=All`, so the API server runs the **complete pipeline — authentication, authorization, mutating admission (including webhooks), schema validation, validating admission — and then discards the object instead of persisting it**. Only server-side dry-run would have caught the quota rejection, because ResourceQuota is a validating admission plugin evaluated by the server. It is also the only variant that shows you the object *after* defaulting and mutation, which is what `kubectl diff` uses under the hood and why `kubectl diff` is trustworthy for change review.

**A8.4** — `metadata.managedFields` records, for each **field manager** (an identity string, defaulting to the binary name), which **specific fields** it owns, with which operation (`Apply` or `Update`) and at which API version. A server-side apply that tries to set a field owned by another manager to a *different* value produces a **conflict**, rather than silently clobbering it. Here `kubectl scale` took ownership of `.spec.replicas`, so the `gitops` manager's apply was refused. `--force-conflicts` steals ownership — correct when the imperative change was the mistake. But when an **HPA legitimately owns `replicas`**, forcing is exactly wrong: it starts a fight where the manifest resets the count and the HPA scales it back, every reconcile. The correct resolution is to **remove `spec.replicas` from the manifest entirely**, so the GitOps manager never claims that field and the HPA is its sole owner. (Argo CD and Flux both document this as the canonical case.)

**A8.5** — (1) **Deletion of unmanaged fields.** Client-side apply computes a three-way merge from the last-applied annotation; if a field was added to the live object by another actor (an HPA, a mutating webhook, an operator) and is absent from your manifest, the diff logic can decide to delete it — or, worse, the semantics differ depending on whether the field was ever in your last-applied. Server-side apply never touches fields you do not own. (2) **The annotation itself.** It stores a full copy of your manifest inside the object's metadata, which doubles the object's size in etcd and, for large resources such as CRDs with big schemas or ConfigMaps, can **exceed the 262144-byte annotation limit and make apply fail outright** (the well-known `metadata.annotations: Too long` error on `kubectl apply` of large CRDs). Server-side apply keeps ownership as structured `managedFields` instead of a serialised blob. A third benefit worth naming: conflicts become **explicit errors** instead of silent last-writer-wins, so two controllers fighting over a field is detectable rather than an intermittent flapping mystery.

</details>

---

## Source references

* LPI — Exam 701 Objectives (DevOps Tools Engineer v2.0): <https://www.lpi.org/our-certifications/exam-701-objectives/>
* Kubernetes Components: <https://kubernetes.io/docs/concepts/overview/components/>
* Control Plane–Node Communication: <https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/>
* Nodes: <https://kubernetes.io/docs/concepts/architecture/nodes/>
* Static Pods: <https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/>
* Kubernetes API Concepts (resourceVersion, watch, Table printing): <https://kubernetes.io/docs/reference/using-api/api-concepts/>
* API Server health endpoints: <https://kubernetes.io/docs/reference/using-api/health-checks/>
* Admission Controllers Reference: <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>
* RBAC Authorization: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
* Encrypting Confidential Data at Rest: <https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>
* Operating etcd clusters for Kubernetes: <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
* etcd documentation (Raft, quorum, snapshots): <https://etcd.io/docs/v3.5/op-guide/>
* Deployments: <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
* ReplicaSet: <https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/>
* Owners and Dependents / Garbage Collection: <https://kubernetes.io/docs/concepts/architecture/garbage-collection/>
* kube-scheduler: <https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/>
* Taints and Tolerations: <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/>
* Safely Drain a Node: <https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/>
* Container Runtime Interface / CRI: <https://kubernetes.io/docs/concepts/architecture/cri/>
* Configuring a cgroup driver: <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/>
* Node-pressure Eviction: <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/>
* Pod Quality of Service Classes: <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/>
* Service: <https://kubernetes.io/docs/concepts/services-networking/service/>
* EndpointSlices: <https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/>
* Virtual IPs and Service Proxies (proxy modes): <https://kubernetes.io/docs/reference/networking/virtual-ips/>
* DNS for Services and Pods: <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/>
* Resource Quotas: <https://kubernetes.io/docs/concepts/policy/resource-quotas/>
* Limit Ranges: <https://kubernetes.io/docs/concepts/policy/limit-range/>
* Server-Side Apply: <https://kubernetes.io/docs/reference/using-api/server-side-apply/>
* kind — Quick Start: <https://kind.sigs.k8s.io/docs/user/quick-start/>