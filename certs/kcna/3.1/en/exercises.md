# 3.1 Administration

> Reference source: [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

These exercises assume you already have access to a Kubernetes cluster (e.g. `kind` or `minikube`) and `kubectl` configured.

## Exercise 1: kubeconfig and contexts

Cluster administration begins with understanding how `kubectl` knows which cluster to connect to and with which identity.

1. Show the active `kubectl` configuration:
   ```bash
   kubectl config view
   ```
2. List the available contexts:
   ```bash
   kubectl config get-contexts
   ```
3. Identify the current context:
   ```bash
   kubectl config current-context
   ```
4. Create a test namespace and a context that points to it by default:
   ```bash
   kubectl create namespace admin-demo
   kubectl config set-context admin-demo-ctx \
     --cluster=$(kubectl config view -o jsonpath='{.clusters[0].name}') \
     --user=$(kubectl config view -o jsonpath='{.users[0].name}') \
     --namespace=admin-demo
   ```
5. Switch to the new context:
   ```bash
   kubectl config use-context admin-demo-ctx
   ```
6. Confirm that commands now operate on `admin-demo` without needing `-n`:
   ```bash
   kubectl run nginx --image=nginx
   kubectl get pods
   ```

**Question 1.1:** What file does `kubectl` read by default to obtain clusters, users, and contexts, and what environment variable can override its location?

**Question 1.2:** What is the difference between a *cluster*, a *user*, and a *context* within a kubeconfig?

## Exercise 2: Namespaces as an administrative boundary

1. List all namespaces in the cluster:
   ```bash
   kubectl get namespaces
   ```
2. Switch back to the original context (without a fixed namespace):
   ```bash
   kubectl config use-context <your-original-context>
   ```
3. Create a second namespace:
   ```bash
   kubectl create namespace equipo-b
   ```
4. Deploy the same resource name in both namespaces to verify they do not collide:
   ```bash
   kubectl -n admin-demo create deployment web --image=nginx
   kubectl -n equipo-b create deployment web --image=nginx
   ```
5. List Deployments across all namespaces at once:
   ```bash
   kubectl get deployments --all-namespaces
   ```
6. Try to access a resource from `equipo-b` without specifying a namespace while in the default context:
   ```bash
   kubectl get deployment web
   ```

**Question 2.1:** Why is there no conflict between the two Deployments named `web`?

**Question 2.2:** Name two Kubernetes resources that are **not** namespaced (they live at the cluster level).

## Exercise 3: ConfigMaps and Secrets

1. Create a ConfigMap from literals:
   ```bash
   kubectl -n admin-demo create configmap app-config \
     --from-literal=LOG_LEVEL=debug \
     --from-literal=ENV=staging
   ```
2. Inspect its contents:
   ```bash
   kubectl -n admin-demo get configmap app-config -o yaml
   ```
3. Create a generic Secret:
   ```bash
   kubectl -n admin-demo create secret generic app-secret \
     --from-literal=DB_PASSWORD=s3cr3t
   ```
4. Confirm the value is Base64-encoded, not encrypted:
   ```bash
   kubectl -n admin-demo get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
   ```
5. Mount both as environment variables in a new Pod:
   ```yaml
   # pod-config.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: app-with-config
     namespace: admin-demo
   spec:
     containers:
       - name: app
         image: nginx
         envFrom:
           - configMapRef:
               name: app-config
           - secretRef:
               name: app-secret
   ```
   ```bash
   kubectl apply -f pod-config.yaml
   ```
6. Verify the variables inside the container:
   ```bash
   kubectl -n admin-demo exec app-with-config -- env | grep -E "LOG_LEVEL|DB_PASSWORD"
   ```

**Question 3.1:** Why should a Secret not be considered an encryption mechanism by itself?

**Question 3.2:** What administrative advantage does separating configuration (ConfigMap/Secret) from the container image provide?

## Exercise 4: Basic RBAC

1. Create a dedicated ServiceAccount:
   ```bash
   kubectl -n admin-demo create serviceaccount viewer-sa
   ```
2. Define a Role with read-only permissions on Pods:
   ```yaml
   # role-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: admin-demo
     name: pod-reader
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
   ```
   ```bash
   kubectl apply -f role-pod-reader.yaml
   ```
3. Bind the Role to the ServiceAccount with a RoleBinding:
   ```yaml
   # rolebinding-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: pod-reader-binding
     namespace: admin-demo
   subjects:
     - kind: ServiceAccount
       name: viewer-sa
       namespace: admin-demo
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f rolebinding-pod-reader.yaml
   ```
4. Verify effective permissions with `auth can-i`:
   ```bash
   kubectl auth can-i list pods \
     --namespace=admin-demo \
     --as=system:serviceaccount:admin-demo:viewer-sa

   kubectl auth can-i delete pods \
     --namespace=admin-demo \
     --as=system:serviceaccount:admin-demo:viewer-sa
   ```

**Question 4.1:** What is the difference between a `Role` and a `ClusterRole`?

**Question 4.2:** In step 4, why should the second command return `no`?

## Exercise 5: Resource requests, limits, and ResourceQuota

1. Deploy a Pod with explicit requests and limits:
   ```yaml
   # pod-resources.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: app-with-resources
     namespace: admin-demo
   spec:
     containers:
       - name: app
         image: nginx
         resources:
           requests:
             cpu: "100m"
             memory: "64Mi"
           limits:
             cpu: "250m"
             memory: "128Mi"
   ```
   ```bash
   kubectl apply -f pod-resources.yaml
   ```
2. Confirm the assigned values:
   ```bash
   kubectl -n admin-demo describe pod app-with-resources | grep -A4 Limits
   ```
3. Apply a ResourceQuota to the namespace:
   ```yaml
   # quota-admin-demo.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: cpu-mem-quota
     namespace: admin-demo
   spec:
     hard:
       requests.cpu: "1"
       requests.memory: 1Gi
       limits.cpu: "2"
       limits.memory: 2Gi
   ```
   ```bash
   kubectl apply -f quota-admin-demo.yaml
   ```
4. Check current usage against the quota:
   ```bash
   kubectl -n admin-demo describe resourcequota cpu-mem-quota
   ```
5. Try to create a Pod **without** requests/limits in that namespace and observe what happens:
   ```bash
   kubectl -n admin-demo run sin-limites --image=nginx
   ```

**Question 5.1:** What is the difference between `requests` and `limits`?

**Question 5.2:** If a namespace has a `ResourceQuota` with `requests.cpu` defined, what happens when trying to create a Pod that does not specify `resources.requests`?

<details>
<summary><strong>See answers</strong></summary>

**1.1:** `kubectl` reads `~/.kube/config` by default. The `KUBECONFIG` environment variable can point to one or more alternative files (separated by `:` on Linux/macOS or `;` on Windows), which are merged.

**1.2:** The *cluster* defines the API endpoint and its CA cert; the *user* defines authentication credentials (cert, token, etc.); the *context* combines a cluster + a user + a default namespace into a single named reference.

**2.1:** The name of a namespaced resource only needs to be unique within its namespace, not across the entire cluster. `admin-demo/web` and `equipo-b/web` are distinct objects with the same name key but different namespaces.

**2.2:** Examples of cluster-scoped resources: `Node`, `PersistentVolume`, `ClusterRole`, `ClusterRoleBinding`, `Namespace` itself. (Any of these is valid.)

**3.1:** By default, Secrets are only Base64-encoded, not encrypted — anyone with read access to the object (or to etcd without encryption at rest) can trivially decode the value. True confidentiality requires encryption at rest in etcd and/or strict RBAC on the `secrets` resource.

**3.2:** It allows reusing the same container image across different environments (dev/staging/prod) by changing only the ConfigMap/Secret, without rebuilding the image, and makes it easier to rotate configuration or credentials without touching the Deployment.

**4.1:** A `Role` grants permissions within a specific namespace; a `ClusterRole` grants permissions at the cluster level (or over non-namespaced resources), and can also be used within a namespace via a RoleBinding to reuse common definitions.

**4.2:** Because the `pod-reader` Role only includes the verbs `get`, `list`, and `watch` — it does not include `delete`, so the ServiceAccount `viewer-sa` does not have permission to delete Pods.

**5.1:** `requests` is what the scheduler guarantees to reserve for the container when choosing a Node (minimum guarantee); `limits` is the maximum ceiling the container can consume before being throttled (CPU) or killed by OOM (memory).

**5.2:** If the ResourceQuota defines `requests.cpu` (or `requests.memory`) as a *hard limit*, any Pod created in that namespace must explicitly declare `resources.requests` — otherwise the API server rejects the creation with a quota validation error.

</details>