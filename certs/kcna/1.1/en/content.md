# Kubernetes Core Concepts

## 1. What is Kubernetes?

Kubernetes (K8s) is an open source **container orchestration** platform that automates the deployment, scaling, and management of containerized applications. It originated at Google (based on the internal Borg system) and is now a graduated project of the **CNCF** (Cloud Native Computing Foundation).

The problem it solves: when an application consists of dozens or hundreds of containers running across multiple hosts, you need something that decides *where* each container runs, *what to do* if a container or an entire node fails, *how* to expose those containers to the network, and *how* to update the application without downtime. Doing this manually does not scale.

Kubernetes works with a **declarative** model: you describe the **desired state** (how many replicas of an app you want, which image to use, what resources to assign) in YAML manifests, and Kubernetes continuously runs a **reconciliation loop** (control loop) that compares the current state of the cluster against the desired state and takes actions to converge towards it. This gives it **self-healing**: if a Pod dies, the control loop automatically creates a new one.

## 2. Cluster Architecture

A Kubernetes cluster has two types of nodes: the **Control Plane** (formerly called "master") and the **Worker Nodes**.

```
┌─────────────────────────────────────────┐
│              CONTROL PLANE                │
│  kube-apiserver   etcd                     │
│  kube-scheduler   kube-controller-manager  │
│  cloud-controller-manager (optional)       │
└─────────────────────────────────────────┘
              │
   ┌──────────┼──────────┐
   ▼          ▼          ▼
┌───────┐ ┌───────┐ ┌───────┐
│ Node 1 │ │ Node 2 │ │ Node 3 │
│kubelet │ │kubelet │ │kubelet │
│kube-   │ │kube-   │ │kube-   │
│proxy   │ │proxy   │ │proxy   │
│runtime │ │runtime │ │runtime │
└───────┘ └───────┘ └───────┘
```

### 2.1 Control Plane Components

- **kube-apiserver**: the front-end of the control plane. Exposes the Kubernetes REST API; everything (kubectl, controllers, kubelet) interacts with the cluster through it. Validates and persists objects in etcd.
- **etcd**: a distributed, consistent key-value database that stores all cluster state (the "source of truth"). Backing up etcd is critical.
- **kube-scheduler**: decides on which node each newly created Pod runs, evaluating resource requirements, affinity/anti-affinity, taints/tolerations, etc.
- **kube-controller-manager**: runs the **controllers** that implement the reconciliation loops (Node controller, ReplicaSet controller, Deployment controller, etc.). Each controller observes state via the API server and acts to bring it closer to the desired state.
- **cloud-controller-manager**: integrates Kubernetes with the API of a specific cloud provider (AWS, GCP, Azure) for things like LoadBalancers or nodes.

### 2.2 Worker Node Components

- **kubelet**: the agent that runs on each node. Receives **PodSpecs** from the API server and ensures that the containers described there are running and healthy. Reports node and Pod status back to the control plane.
- **kube-proxy**: maintains network rules on each node (via iptables or IPVS) that allow communication to Services.
- **Container runtime**: the software that actually runs the containers (containerd, CRI-O). Kubernetes communicates with the runtime via the **CRI** (Container Runtime Interface), allowing runtimes to be swapped without changing Kubernetes code.

Example, viewing nodes in a cluster:

```bash
$ kubectl get nodes -o wide
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP   CONTAINER-RUNTIME
node-control   Ready    control-plane   30d   v1.29.2   10.0.0.10     containerd://1.7.11
node-worker-1  Ready    <none>          30d   v1.29.2   10.0.0.11     containerd://1.7.11
node-worker-2  Ready    <none>          30d   v1.29.2   10.0.0.12     containerd://1.7.11
```

## 3. The Pod: the smallest deployable unit

A **Pod** is the smallest unit that Kubernetes can create and manage. It represents one or more containers that share a **network namespace** (same IP, same port space, communicate via `localhost`) and optionally **storage** (volumes). "Naked" Pods are almost never used in production — they are managed by higher-level controllers (Deployment, StatefulSet, etc.) that guarantee the desired number of replicas exists.

Minimum Pod manifest:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.25
      ports:
        - containerPort: 80
```

```bash
$ kubectl apply -f nginx-pod.yaml
pod/nginx-pod created

$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          5s

$ kubectl describe pod nginx-pod
Name:         nginx-pod
Status:       Running
IP:           10.244.1.5
Containers:
  nginx:
    Image:          nginx:1.25
    State:          Running
    Ready:          True
```

**Multi-container Pods** are common with the **sidecar** pattern (an auxiliary container that complements the main one, e.g., a logging proxy or a service mesh sidecar like Envoy).

## 4. Controllers for Pod Management

### 4.1 ReplicaSet

Ensures that a specific number of identical Pod replicas are running at all times. Uses **labels and selectors** to know which Pods it manages. Rarely created directly: normally managed by a Deployment.

### 4.2 Deployment

The most used object for **stateless** applications. Manages ReplicaSets and provides:
- **Rolling updates**: gradually updates Pods without downtime.
- **Rollback**: revert to a previous revision if something fails.
- **Declarative scaling**.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports:
            - containerPort: 80
```

```bash
$ kubectl apply -f nginx-deployment.yaml
deployment.apps/nginx-deployment created

$ kubectl get deployments
NAME               READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deployment   3/3     3            3           10s

$ kubectl get replicasets
NAME                          DESIRED   CURRENT   READY   AGE
nginx-deployment-6d4b7d9f9c   3         3         3       10s

$ kubectl scale deployment nginx-deployment --replicas=5
deployment.apps/nginx-deployment scaled

$ kubectl set image deployment/nginx-deployment nginx=nginx:1.26
deployment.apps/nginx-deployment image updated

$ kubectl rollout status deployment/nginx-deployment
deployment "nginx-deployment" successfully rolled out

$ kubectl rollout undo deployment/nginx-deployment
deployment.apps/nginx-deployment rolled back
```

### 4.3 StatefulSet

For **stateful** applications (databases, e.g., etcd, Kafka, Cassandra) that require:
- **Stable and unique** network identity per replica (`pod-0`, `pod-1`, `pod-2`, ...).
- Guaranteed order of creation and deletion.
- Persistent storage associated with each replica that survives rescheduling (via `volumeClaimTemplates`).

### 4.4 DaemonSet

Ensures that **one copy of a Pod runs on each node** of the cluster (or a subset). Typically used for node-level agents: log collectors (Fluentd), monitoring agents (node-exporter), or network components (CNI plugins).

### 4.5 Job and CronJob

- **Job**: creates one or more Pods and ensures they terminate successfully (used for batch tasks, not long-running processes).
- **CronJob**: creates Jobs on a recurring schedule, using standard cron syntax.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-job
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: my-backup-tool:1.0
          restartPolicy: OnFailure
```

## 5. Service: exposing Pods on the network

Pods are ephemeral and their IP changes each time they are recreated. A **Service** provides a stable endpoint (virtual IP + DNS name) that load-balances traffic to the set of Pods matching a **selector**, regardless of individual Pod changes.

Main types:
- **ClusterIP** (default): exposes the Service on an internal IP, only accessible inside the cluster.
- **NodePort**: exposes the Service on a static port on each node (`<NodeIP>:<NodePort>`).
- **LoadBalancer**: provisions an external load balancer (requires cloud provider support).
- **ExternalName**: maps the Service to an external DNS name, without proxying.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

```bash
$ kubectl apply -f nginx-service.yaml
service/nginx-service created

$ kubectl get svc nginx-service
NAME            TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
nginx-service   ClusterIP   10.96.45.12    <none>        80/TCP    8s

$ kubectl get endpoints nginx-service
NAME            ENDPOINTS                                AGE
nginx-service   10.244.1.5:80,10.244.2.3:80,10.244.3.9:80   8s
```

Each Service also receives an internal DNS name (via CoreDNS) in the format `<service-name>.<namespace>.svc.cluster.local`.

## 6. Namespaces

A **Namespace** is a way to divide a physical cluster into multiple virtual clusters, useful for separating environments or teams (e.g., `dev`, `staging`, `prod`) within the same cluster. Most objects (Pods, Services, Deployments) are namespaced; some are cluster-wide (Nodes, PersistentVolumes, Namespaces themselves).

```bash
$ kubectl create namespace staging
namespace/staging created

$ kubectl get namespaces
NAME              STATUS   AGE
default           Active   30d
kube-system       Active   30d
kube-public       Active   30d
staging           Active   5s

$ kubectl get pods -n staging
$ kubectl get pods --all-namespaces
```

## 7. ConfigMap and Secret

Allow decoupling configuration from the container image code.

- **ConfigMap**: key-value pairs with non-sensitive data (URLs, feature flags, configuration files).
- **Secret**: similar, but for sensitive data (passwords, tokens, certificates). Stored **base64-encoded** (not encrypted by default — requires encryption at rest configured in etcd for real security).

```bash
$ kubectl create configmap app-config --from-literal=LOG_LEVEL=debug
configmap/app-config created

$ kubectl create secret generic db-secret --from-literal=password=s3cr3t
secret/db-secret created
```

They are consumed as environment variables or mounted as volumes inside a Pod:

```yaml
spec:
  containers:
    - name: app
      image: my-app:1.0
      envFrom:
        - configMapRef:
            name: app-config
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: password
```

## 8. Labels, Selectors, and Annotations

- **Labels**: key-value pairs attached to objects (`app: nginx`, `env: prod`, `tier: frontend`) used to identify and group resources. Services and controllers (Deployment, ReplicaSet) use **selectors** on labels to know which Pods belong to them.
- **Annotations**: also key-value pairs, but for non-identifying metadata (used by tools, not for selection) — e.g., ingress controller annotations or build metadata.

```bash
$ kubectl label pod nginx-pod tier=frontend
pod/nginx-pod labeled

$ kubectl get pods --selector=app=nginx
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          2m
```

## 9. kubectl: interacting with the cluster

`kubectl` is the official CLI for interacting with the API server. It supports **imperative** commands (`kubectl run`, `kubectl create`, `kubectl expose`) and the recommended **declarative** workflow (`kubectl apply -f manifest.yaml`), which is idempotent and versionable (GitOps).

```bash
$ kubectl get pods -o yaml          # view the complete manifest returned by the API server
$ kubectl explain pod.spec.containers  # inline schema documentation
$ kubectl logs nginx-pod             # container logs
$ kubectl exec -it nginx-pod -- sh   # interactive shell inside the Pod
$ kubectl delete -f nginx-pod.yaml
```

## References

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Documentation — Concepts: https://kubernetes.io/docs/concepts/
- Kubernetes Documentation — Pods: https://kubernetes.io/docs/concepts/workloads/pods/
- Kubernetes Documentation — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes Documentation — StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- Kubernetes Documentation — DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Kubernetes Documentation — Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- Kubernetes Documentation — Services: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes Documentation — Namespaces: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes Documentation — ConfigMaps: https://kubernetes.io/docs/concepts/configuration/configmap/
- Kubernetes Documentation — Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes Documentation — Kubernetes Components: https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes Documentation — kubectl Reference: https://kubernetes.io/docs/reference/kubectl/