# 3.1 Administration

En Kubernetes, "administration" abarca el conjunto de herramientas, objetos y prácticas que usás para operar un clúster día a día: interactuar con la API vía `kubectl`, controlar quién puede hacer qué (RBAC), inyectar configuración y datos sensibles en las aplicaciones (ConfigMaps/Secrets), organizar recursos (Namespaces, Resource Quotas) y mantener los nodos (cordon/drain/taint). El KCNA no pide dominio operativo profundo (eso es CKA), pero sí que reconozcas estas herramientas, su propósito y su sintaxis básica.

## kubectl: la herramienta de administración por excelencia

`kubectl` es el cliente de línea de comandos que habla con el `kube-apiserver` vía REST/JSON. Es la forma más común de crear, inspeccionar y modificar objetos del clúster.

Sintaxis general:

```
kubectl [comando] [tipo] [nombre] [flags]
```

Comandos imperativos vs. declarativos:

```bash
# Imperativo: creás el recurso directamente con un comando
kubectl create deployment nginx --image=nginx:1.25

# Declarativo: aplicás un manifiesto YAML (recomendado para producción/GitOps)
kubectl apply -f deployment.yaml
```

Comandos de administración frecuentes:

```bash
kubectl get nodes -o wide
kubectl describe pod mi-pod
kubectl logs mi-pod -c mi-contenedor
kubectl exec -it mi-pod -- /bin/sh
kubectl config get-contexts
kubectl config use-context produccion
```

`kubectl config` administra el **kubeconfig** (`~/.kube/config`), que define clústeres, usuarios y contextos disponibles para el cliente.

## kubeadm: bootstrap de clústeres

`kubeadm` es la herramienta oficial para inicializar y unir nodos a un clúster Kubernetes "self-managed" (no administrado por un cloud provider). No configura el container runtime ni el CNI plugin, pero sí levanta el control plane.

```bash
# En el nodo control-plane
kubeadm init --pod-network-cidr=10.244.0.0/16

# Genera el comando (con token) para unir workers
kubeadm token create --print-join-command

# En cada worker
kubeadm join 10.0.0.1:6443 --token abc123.xyz \
  --discovery-token-ca-cert-hash sha256:...
```

Es útil distinguirlo de las opciones "managed" (EKS, GKE, AKS), donde el control plane lo administra el cloud provider y `kubeadm` no se usa.

## Helm y Kustomize: administración de manifiestos

Ambas son herramientas para gestionar configuración de Kubernetes a mayor escala que archivos YAML sueltos.

**Helm** es el gestor de paquetes de Kubernetes. Empaqueta manifiestos como **charts**, parametrizables con `values.yaml`.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install mi-release bitnami/nginx --set replicaCount=3
helm upgrade mi-release bitnami/nginx --set replicaCount=5
helm rollback mi-release 1
helm list
```

**Kustomize** (integrado en `kubectl` desde la v1.14) permite personalizar YAML base sin templates, mediante overlays declarativos definidos en un `kustomization.yaml`.

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

La diferencia clave: Helm usa templating + un runtime de paquetes (releases, versionado), Kustomize usa composición de YAML puro sin templating.

## RBAC: control de acceso

**Role-Based Access Control** define qué acciones puede ejecutar un usuario o ServiceAccount sobre qué recursos. Se compone de cuatro objetos:

- `Role` / `ClusterRole`: definen permisos (verbs sobre resources), con o sin scope de namespace.
- `RoleBinding` / `ClusterRoleBinding`: asocian ese Role a un usuario, grupo o ServiceAccount.

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

## ConfigMaps y Secrets

Ambos desacoplan configuración de la imagen del contenedor. Los `Secret` almacenan el valor codificado en base64 (no encriptado por defecto — requiere encryption at rest a nivel etcd para protección real).

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

## Namespaces y Resource Quotas

Los **Namespaces** particionan un clúster físico en clústeres virtuales, útiles para separar equipos o entornos (`dev`, `staging`, `prod`).

```bash
kubectl create namespace dev
kubectl get pods -n dev
kubectl get pods --all-namespaces
```

Una **ResourceQuota** limita el consumo agregado de recursos dentro de un namespace:

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

## Mantenimiento de nodos

Para intervenciones planificadas (actualizar el kernel, reemplazar hardware), se usa un flujo de tres comandos:

```bash
# Marca el nodo como no-schedulable (nuevos pods no se agendan ahí)
kubectl cordon nodo-1

# Evacúa los pods existentes hacia otros nodos, respetando PodDisruptionBudgets
kubectl drain nodo-1 --ignore-daemonsets --delete-emptydir-data

# ... mantenimiento del nodo ...

# Vuelve a habilitarlo para el scheduler
kubectl uncordon nodo-1
```

Los **taints** en nodos y las **tolerations** en pods son otro mecanismo de control: un taint repele pods a menos que tengan la toleration correspondiente, útil para reservar nodos (por ejemplo, con GPU) a cargas específicas.

```bash
kubectl taint nodes nodo-gpu tipo=gpu:NoSchedule
```

## Referencias

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