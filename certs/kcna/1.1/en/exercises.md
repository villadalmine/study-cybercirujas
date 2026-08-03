# Guided Exercises — Kubernetes Core Concepts (KCNA)

> Reference source: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)
> Requirements: access to a Kubernetes cluster (`minikube`, `kind` or `k3d`) and `kubectl` configured against that cluster.

---

## Exercise 1 — Cluster Architecture: Control Plane and Worker Nodes

1. Verify that `kubectl` is connected to a cluster and display the basic information:
   ```bash
   kubectl cluster-info
   ```
2. List the cluster nodes along with their roles:
   ```bash
   kubectl get nodes -o wide
   ```
3. Inspect one of the nodes in detail (replace `<node-name>` with one from the list above):
   ```bash
   kubectl describe node <node-name>
   ```
   Pay attention to the `Conditions`, `Capacity` and `Allocatable` sections.
4. List the Pods in the `kube-system` namespace, where control plane components run when the cluster exposes them as Pods:
   ```bash
   kubectl get pods -n kube-system
   ```
5. Identify in the previous output Pods corresponding to `kube-apiserver`, `etcd`, `kube-scheduler` and `kube-controller-manager` (in managed clusters such as GKE/EKS/AKS, these components are not always visible as Pods because the provider manages them outside the cluster).

**Comprehension questions**
- Which control plane component is the single entry point for all operations on the cluster (including communication among the other components)?
- What is the difference between a control plane node and a worker node in terms of which user workloads can run on them by default?
- Which control plane component is responsible for deciding on which node a newly created Pod will run?

---

## Exercise 2 — Pods: The Smallest Deployable Unit

1. Create a Pod imperatively from an image:
   ```bash
   kubectl run nginx-pod --image=nginx:1.25 --restart=Never
   ```
2. Check its status until it transitions to `Running`:
   ```bash
   kubectl get pod nginx-pod --watch
   ```
   (Exit with `Ctrl+C` once you see `Running`.)
3. Generate the equivalent YAML manifest without creating it, to see how Kubernetes represents it internally:
   ```bash
   kubectl run nginx-pod-2 --image=nginx:1.25 --restart=Never --dry-run=client -o yaml
   ```
4. Save that YAML to a file `pod-multi.yaml` and manually add a second container inside `spec.containers`, for example a `busybox` with `command: ["sleep", "3600"]`. Apply it:
   ```bash
   kubectl apply -f pod-multi.yaml
   ```
5. Confirm the Pod has 2/2 containers ready:
   ```bash
   kubectl get pod nginx-pod-2
   ```
6. Check the logs of a specific container inside the multi-container Pod:
   ```bash
   kubectl logs nginx-pod-2 -c nginx
   ```

**Comprehension questions**
- Why is the Pod, not the container, said to be the smallest unit that Kubernetes schedules on a node?
- If a Pod has two containers, what network and storage resources do they share with each other?
- What happens to a Pod created directly (as in step 1) if the node where it runs fails? Why is this different from the behavior of a Pod managed by a Deployment?

---

## Exercise 3 — Labels and Selectors

1. Label the Pod created in the previous exercise:
   ```bash
   kubectl label pod nginx-pod-2 app=web env=dev
   ```
2. List the Pods showing their labels:
   ```bash
   kubectl get pods --show-labels
   ```
3. Filter Pods using a label selector:
   ```bash
   kubectl get pods -l app=web
   ```
4. Try a more restrictive selector combining two conditions:
   ```bash
   kubectl get pods -l app=web,env=dev
   ```
5. Try a negative selector:
   ```bash
   kubectl get pods -l env!=prod
   ```

**Comprehension questions**
- What is the conceptual difference between a label and an annotation in Kubernetes?
- Why do Services and Deployments rely on label selectors instead of referencing Pods by name?

---

## Exercise 4 — Deployments and ReplicaSets

1. Create a Deployment:
   ```bash
   kubectl create deployment webapp --image=nginx:1.25 --replicas=3
   ```
2. Observe the objects that the Deployment automatically created:
   ```bash
   kubectl get deployments,replicasets,pods -l app=webapp
   ```
3. Scale the Deployment to 5 replicas:
   ```bash
   kubectl scale deployment webapp --replicas=5
   ```
   List the Pods again and confirm there are now 5.
4. Simulate a rolling update by changing the image:
   ```bash
   kubectl set image deployment/webapp nginx=nginx:1.27
   ```
5. Watch the rollout progress:
   ```bash
   kubectl rollout status deployment/webapp
   ```
6. Review the revision history:
   ```bash
   kubectl rollout history deployment/webapp
   ```
7. Roll back to the previous revision:
   ```bash
   kubectl rollout undo deployment/webapp
   ```

**Comprehension questions**
- Which object directly creates and manages the Pods when you use a Deployment: the Deployment or the ReplicaSet?
- During a rolling update, why is a new ReplicaSet created instead of modifying the Pods of the existing ReplicaSet?
- If you manually delete one of the Pods created by the Deployment, what happens and why?

---

## Exercise 5 — Services: Exposing Pods Inside and Outside the Cluster

1. Expose the `webapp` Deployment with a Service of type `ClusterIP`:
   ```bash
   kubectl expose deployment webapp --port=80 --target-port=80 --name=webapp-svc
   ```
2. Inspect the created Service:
   ```bash
   kubectl describe service webapp-svc
   ```
   Note the `Endpoints` it shows: they should match the IPs of the Pods with label `app=webapp`.
3. From a temporary Pod inside the cluster, test resolving the Service by its DNS name:
   ```bash
   kubectl run curl-test --image=curlimages/curl --restart=Never -it --rm -- curl http://webapp-svc
   ```
4. Change the Service type to `NodePort` to expose it outside the cluster:
   ```bash
   kubectl patch service webapp-svc -p '{"spec": {"type": "NodePort"}}'
   ```
5. Obtain the assigned port:
   ```bash
   kubectl get service webapp-svc
   ```

**Comprehension questions**
- How does a `ClusterIP` Service know which Pods to send traffic to?
- What is the difference between `ClusterIP`, `NodePort`, and `LoadBalancer` types in terms of where the Service can be accessed from?
- If you scale the Deployment to more replicas, do you need to reconfigure the Service to include the new Pods? Why?

---

## Exercise 6 — Namespaces: Logical Isolation of Resources

1. List the existing namespaces:
   ```bash
   kubectl get namespaces
   ```
2. Create a new namespace:
   ```bash
   kubectl create namespace training
   ```
3. Create a Deployment inside that namespace:
   ```bash
   kubectl create deployment webapp --image=nginx:1.25 --namespace=training
   ```
4. Confirm the resource does not appear in the `default` namespace:
   ```bash
   kubectl get deployments
   kubectl get deployments -n training
   ```
5. Change the default namespace of your current context so you don't have to write `-n training` every time:
   ```bash
   kubectl config set-context --current --namespace=training
   ```
6. Verify the change:
   ```bash
   kubectl get deployments
   ```

**Comprehension questions**
- Which Kubernetes resources are "namespaced" (live inside a namespace) and which are "cluster-scoped" (global to the cluster)? Give an example of each.
- Can a Pod in the `training` namespace communicate via short DNS (just the Service name) with a Service in the `default` namespace? What would it have to use instead?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- The `kube-apiserver` is the only entry point: it exposes the Kubernetes REST API and is the only component that reads and writes directly to `etcd`. All other components (scheduler, controller-manager, kubelet, kubectl) interact with the cluster through it.
- By default, control plane nodes have a `taint` that prevents user workload Pods from being scheduled on them, reserving their resources for the control plane components themselves. Worker nodes are available for running those workloads.
- The `kube-scheduler` is the component responsible for assigning each newly created Pod (which does not yet have a node assigned) to a specific node, based on available resources, constraints, and scheduling policies.

**Exercise 2**
- Because all containers within the same Pod share the same Network Namespace (same IP) and can share volumes; Kubernetes schedules and scales based on complete Pods, not individual containers.
- They share the same IP address and port space (they can communicate with each other via `localhost`), and they can share the same Volumes defined at the Pod level.
- If the node fails, a Pod created directly (without a controller like Deployment) is not recreated on another node: it is lost. A Pod managed by a Deployment is recreated because the underlying ReplicaSet detects that the number of replicas is below the desired state and creates a new Pod.

**Exercise 3**
- Labels are key-value pairs intended for identifying and selecting objects (used in selectors); annotations are arbitrary metadata (not used for selection) to store additional information such as descriptions, external IDs, or tool configuration.
- Because Pods are ephemeral: they are constantly destroyed and recreated (e.g., during rolling updates or restarts). A selector based on labels automatically finds the correct Pods regardless of their specific names, whereas a name reference would break as soon as the Pod is replaced.

**Exercise 4**
- The ReplicaSet directly manages the Pods (creates them, counts them, and replaces missing ones). The Deployment manages ReplicaSets, adding versioning and rolling update functionality on top.
- Because this allows Kubernetes to perform a gradual rollout: it keeps the old ReplicaSet with Pods of the previous version while scaling up the new ReplicaSet with the new version, enabling updates without downtime and instant rollback by simply scaling the old ReplicaSet back up.
- The ReplicaSet detects that the current number of replicas (now one less) does not match the desired number specified in its `spec.replicas`, and automatically creates a new Pod to restore the desired state.

**Exercise 5**
- Through a label selector defined in the Service's `spec.selector`: any Pod whose labels match that selector is automatically added to the Service's `Endpoints`.
- `ClusterIP` is only accessible inside the cluster (a virtual internal IP); `NodePort` additionally exposes a fixed port on the IP of each node, accessible from outside the cluster; `LoadBalancer` provisions an external load balancer (typically from the cloud provider) that routes external traffic to the Service, usually on top of a `NodePort`.
- No reconfiguration is needed: the Service uses the label selector to dynamically discover Pods, so any new Pod that matches the selector's labels is automatically added to the Endpoints.

**Exercise 6**
- Namespaced: for example Pods, Deployments, Services, ConfigMaps, Secrets. Cluster-scoped: for example Nodes, PersistentVolumes, Namespaces themselves, ClusterRoles.
- Not directly by the short Service name (e.g., `webapp-svc` only resolves within the same namespace). To communicate across namespaces, you must use the full DNS name, which includes the namespace: `webapp-svc.default.svc.cluster.local` (or the shorter form `webapp-svc.default`).

</details>