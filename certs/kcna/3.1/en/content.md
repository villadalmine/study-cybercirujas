# 3.1 Administration

In Kubernetes, "administration" encompasses the set of tools, objects, and practices you use to operate a cluster day‑to‑day: interacting with the API via `kubectl`, controlling who can do what (RBAC), injecting configuration and sensitive data into applications (ConfigMaps/Secrets), organizing resources (Namespaces, Resource Quotas), and maintaining nodes (cordon/drain/taint). The KCNA does not require deep operational mastery (that’s for CKA), but it does expect you to recognize these tools, their purpose, and their basic syntax.

## kubectl: the quintessential administration tool

`kubectl` is the command‑line client that talks to the `kube-apiserver` via REST/JSON. It is the most common way to create, inspect, and modify cluster objects.

General syntax:

```
kubectl [comando] [tipo] [nombre] [flags]
```

Imperative vs. declarative commands:

```bash
# Imperative: you create the resource directly with a command
kubectl create deployment nginx --image=nginx:1.25

# Declarative: you apply a YAML manifest (recommended for production/GitOps)
kubectl apply -f deployment.yaml
```

Frequent administration commands:

```bash
kubectl get nodes -o wide
kubectl describe pod mi-pod
kubectl logs mi-pod -c mi-contenedor
kubectl exec -it mi-pod -- /bin/sh
kubectl config get-contexts
kubectl config use-context produccion
```

`kubectl config` manages the **kubeconfig** (`~/.kube/config`), which defines clusters, users, and contexts available to the client.

## kubeadm: cluster bootstrap

`kubeadm` is the official tool for initializing and joining nodes to a "self‑managed" Kubernetes cluster (not managed by a cloud provider). It does not configure the container runtime or the CNI plugin, but it does set up the control plane.

```bash
# On the control-plane node
kubeadm init --pod-network-cidr=10.244.0.0/16

# Generates the command (with token) to join workers
kubeadm token create --print-join-command

# On each worker
kubeadm join 10.0.0.1:6443 --token abc123.xyz \
  --discovery-token-ca-cert-hash sha256:...
```

It is useful to distinguish it from "managed" options (EKS, GKE, AKS), where the cloud provider manages the control plane and `kubeadm` is not used.

## Helm and Kustomize: manifest management

Both are tools for managing Kubernetes configuration at a larger scale than loose YAML files.

**Helm** is the Kubernetes package manager. It packages manifests as **charts**, parameterizable with `values.yaml`.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install mi-release bitnami/nginx --set replicaCount=3
helm upgrade mi-release bitnami/nginx --set replicaCount=5
helm rollback mi-release 1
helm list
```

**Kustomize** (integrated into `kubectl` since v1.14) allows you to customize base YAML without templates, using declarative overlays defined in a `kustomization.yaml`.

```yaml
# kustomization.yaml
resources:
  - deployment.yaml
  - service.yaml
patches:
  - path: patch-replicas.yaml
```

```bash
kubectl apply -k ./overlays/produccion
```

The key difference: Helm uses templating + a package runtime (releases, versioning), Kustomize uses pure YAML composition without templating.

## RBAC: access control

**Role‑Based Access Control** defines which actions a user or ServiceAccount can perform on which resources. It consists of four objects:

- `Role` / `ClusterRole`: define permissions (verbs on resources), with or without namespace scope.
- `RoleBinding` / `ClusterRoleBinding`: associate that Role with a user, group, or ServiceAccount.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev
  name: pod-reader
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: leer-pods
  namespace: dev
subjects:
  - kind: User
    name: ana
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl auth can-i list pods --as=ana -n dev
# yes
```

## ConfigMaps and Secrets

Both decouple configuration from the container image. `Secret` stores the value base64‑encoded (not encrypted by default — requires encryption at rest at the etcd level for real protection).

```bash
kubectl create configmap app-config --from-literal=LOG_LEVEL=debug
kubectl create secret generic db-creds --from-literal=password=s3cr3t
```

```yaml
env:
  - name: LOG_LEVEL
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: LOG_LEVEL
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-creds
        key: password
```

## Namespaces and Resource Quotas

**Namespaces** partition a physical cluster into virtual clusters, useful for separating teams or environments (`dev`, `staging`, `prod`).

```bash
kubectl create namespace dev
kubectl get pods -n dev
kubectl get pods --all-namespaces
```

A **ResourceQuota** limits the aggregate resource consumption within a namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-dev
  namespace: dev
spec:
  hard:
    pods: "10"
    requests.cpu: "4"
    requests.memory: 8Gi
```

## Node maintenance

For planned interventions (kernel updates, hardware replacement), a three‑command flow is used:

```bash
# Mark the node as unschedulable (new Pods will not be scheduled there)
kubectl cordon nodo-1

# Evacuate existing Pods to other nodes, respecting PodDisruptionBudgets
kubectl drain nodo-1 --ignore-daemonsets --delete-emptydir-data

# ... node maintenance ...

# Re‑enable it for the scheduler
kubectl uncordon nodo-1
```

**Taints** on nodes and **tolerations** on Pods are another control mechanism: a taint repels Pods unless they have the corresponding toleration, useful for reserving nodes (e.g., with GPU) for specific workloads.

```bash
kubectl taint nodes nodo-gpu tipo=gpu:NoSchedule
```

## References

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes docs, kubectl: https://kubernetes.io/docs/reference/kubectl/
- Kubernetes docs, kubeadm: https://kubernetes.io/docs/reference/setup-tools/kubeadm/
- Kubernetes docs, RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes docs, ConfigMaps: https://kubernetes.io/docs/concepts/configuration/configmap/
- Kubernetes docs, Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes docs, Namespaces: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes docs, Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes docs, Safely Drain a Node: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Kubernetes docs, Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Helm docs: https://helm.sh/docs/
- Kustomize docs: https://kubectl.docs.kubernetes.io/references/kustomize/