# 4.2 Understanding authentication, authorization and admission control

## El request flow del API server

Toda petición al `kube-apiserver` atraviesa tres etapas secuenciales, en este orden:

```
Cliente (kubectl, Pod, controller) 
    │
    ▼
1. Authentication  → ¿quién sos?
    │
    ▼
2. Authorization   → ¿tenés permiso para esta acción?
    │
    ▼
3. Admission Control → ¿el objeto que enviás cumple las políticas del cluster?
    │
    ▼
Persistencia en etcd
```

Si falla authentication → `401 Unauthorized`. Si falla authorization → `403 Forbidden`. Si falla un admission controller → el objeto es rechazado (o modificado, según el caso) con el código correspondiente. Este orden es clave para el examen: primero se resuelve la identidad, después el permiso, y recién al final se valida/modifica el manifiesto en sí.

---

## 1. Authentication

Kubernetes no tiene un objeto `User` nativo. Distingue dos tipos de identidades:

- **Users normales**: gestionados fuera del cluster (certificados, OIDC, tokens externos). No existe un API object para crearlos.
- **ServiceAccounts**: sí son objetos de Kubernetes (`kubectl get sa`), pensados para procesos dentro del cluster (Pods hablando con el API server).

### Métodos de authentication soportados

| Método | Uso típico |
|---|---|
| Client certificates (x509) | `kubectl` de administradores, componentes del control plane |
| Bearer tokens (ServiceAccount tokens) | Pods que llaman al API server |
| Bootstrap tokens | Unir nodos al cluster |
| OIDC tokens | Integración con proveedores de identidad externos (Google, Azure AD, etc.) |
| Webhook token authentication | Delegar la validación a un servicio externo |

### kubeconfig

`kubectl` no "sabe" quién sos; lee la identidad del `kubeconfig` (normalmente `~/.kube/config`), que define **clusters**, **users** y **contexts**:

```bash
kubectl config view --minify
```

```yaml
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: DATA+OMITTED
    server: https://192.168.49.2:8443
  name: minikube
contexts:
- context:
    cluster: minikube
    namespace: dev
    user: minikube
  name: minikube
current-context: minikube
users:
- name: minikube
  user:
    client-certificate: /home/user/.minikube/profiles/minikube/client.crt
    client-key: /home/user/.minikube/profiles/minikube/client.key
```

Cambiar de usuario/namespace sin editar el archivo a mano:

```bash
kubectl config set-context --current --namespace=dev
kubectl config use-context otro-cluster
```

### ServiceAccounts

Cada namespace tiene una ServiceAccount `default`. Cualquier Pod que no especifique `serviceAccountName` la usa automáticamente.

```bash
kubectl create serviceaccount ci-bot -n dev
kubectl get sa ci-bot -n dev -o yaml
```

Asignarla a un Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  serviceAccountName: ci-bot
  containers:
  - name: app
    image: nginx
```

Desde Kubernetes 1.24, los tokens de ServiceAccount **ya no se crean automáticamente como Secrets**. El kubelet los inyecta como tokens de corta duración vía **projected volume** (`TokenRequest API`), montados en `/var/run/secrets/kubernetes.io/serviceaccount/token`. Si se necesita un token de larga duración explícito, hay que pedirlo:

```bash
kubectl create token ci-bot -n dev --duration=1h
```

O declararlo como Secret manualmente (legacy, solo si se requiere un token estático):

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: ci-bot-token
  annotations:
    kubernetes.io/service-account.name: ci-bot
```

Verificar la identidad activa desde dentro de un contenedor:

```bash
kubectl exec -it app -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

---

## 2. Authorization

Una vez autenticado, el API server decide si esa identidad puede ejecutar la acción pedida (verb + resource + namespace). Los modos posibles se configuran con `--authorization-mode` en el `kube-apiserver`:

- **Node**: autoriza requests de los kubelets sobre recursos relacionados a su propio nodo.
- **ABAC** (Attribute-Based Access Control): políticas en un archivo estático, poco usado hoy.
- **RBAC** (Role-Based Access Control): el modo estándar y el que evalúa el examen.
- **Webhook**: delega la decisión a un servicio HTTP externo.

En un cluster real suele estar `--authorization-mode=Node,RBAC`.

### RBAC: los cuatro objetos

| Objeto | Alcance | Define |
|---|---|---|
| `Role` | Namespace | Reglas (verbs sobre resources) |
| `ClusterRole` | Cluster-wide | Reglas, incluso sobre recursos no-namespaced (nodes, PVs) |
| `RoleBinding` | Namespace | Asocia un `Role` (o `ClusterRole`) a subjects |
| `ClusterRoleBinding` | Cluster-wide | Asocia un `ClusterRole` a subjects en todo el cluster |

Un `ClusterRole` referenciado desde un `RoleBinding` otorga esos permisos **solo en el namespace del binding** — es el patrón habitual para reusar roles genéricos (`view`, `edit`, `admin`) sin duplicarlos.

**Ejemplo — Role de solo lectura sobre Pods en `dev`:**

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
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-bot-pod-reader
  namespace: dev
subjects:
- kind: ServiceAccount
  name: ci-bot
  namespace: dev
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Forma imperativa equivalente:

```bash
kubectl create role pod-reader --verb=get,list,watch --resource=pods -n dev
kubectl create rolebinding ci-bot-pod-reader \
  --role=pod-reader --serviceaccount=dev:ci-bot -n dev
```

**Ejemplo — ClusterRole + ClusterRoleBinding para ver Nodes (recurso no-namespaced):**

```bash
kubectl create clusterrole node-viewer --verb=get,list --resource=nodes
kubectl create clusterrolebinding ci-bot-node-viewer \
  --clusterrole=node-viewer --serviceaccount=dev:ci-bot
```

### Verificar permisos: `kubectl auth can-i`

Herramienta central del examen para depurar RBAC sin adivinar:

```bash
kubectl auth can-i list pods --namespace dev \
  --as=system:serviceaccount:dev:ci-bot
# yes

kubectl auth can-i delete deployments --namespace dev \
  --as=system:serviceaccount:dev:ci-bot
# no

kubectl auth can-i '*' '*' --as=system:serviceaccount:dev:ci-bot
# no  (verifica si tiene permisos de cluster-admin)
```

Listar todos los permisos efectivos de un subject:

```bash
kubectl auth can-i --list --as=system:serviceaccount:dev:ci-bot -n dev
```

```
Resources                                       Non-Resource URLs  Resource Names  Verbs
pods                                             []                 []              [get list watch]
```

---

## 3. Admission Control

Los **admission controllers** son el último filtro antes de persistir el objeto en etcd. Se ejecutan en dos fases, en orden:

1. **Mutating admission controllers**: pueden modificar el objeto (ej. inyectar un sidecar, poner defaults).
2. **Validating admission controllers**: solo aceptan o rechazan, no modifican.

```
Authorization OK
    │
    ▼
Mutating admission (built-in) → Mutating webhooks
    │
    ▼
Object schema validation (OpenAPI)
    │
    ▼
Validating admission (built-in) → Validating webhooks
    │
    ▼
Persist en etcd
```

### Admission controllers built-in relevantes

Se habilitan/deshabilitan con flags en el `kube-apiserver`:

```bash
kube-apiserver --enable-admission-plugins=NamespaceLifecycle,LimitRanger,ResourceQuota,PodSecurity
```

| Controller | Función |
|---|---|
| `NamespaceLifecycle` | Impide crear objetos en namespaces que están terminando o no existen |
| `LimitRanger` | Aplica los defaults/límites definidos en un `LimitRange` |
| `ResourceQuota` | Rechaza objetos que excedan la `ResourceQuota` del namespace |
| `PodSecurity` | Reemplazo de PodSecurityPolicy; aplica Pod Security Standards por namespace |
| `DefaultStorageClass` | Asigna la StorageClass por defecto a PVCs sin `storageClassName` |
| `ServiceAccount` | Asigna la ServiceAccount `default` a Pods que no la especifican |
| `MutatingAdmissionWebhook` / `ValidatingAdmissionWebhook` | Delegan a webhooks externos (ver abajo) |

Ver qué plugins están activos en un cluster gestionado (managed) suele no ser posible directamente; sí se puede inferir el comportamiento probando (ej. crear un Pod en un namespace con `ResourceQuota` agotada y observar el rechazo).

### PodSecurity admission

Reemplaza a PodSecurityPolicy (removido en 1.25). Se configura con **labels en el namespace**, no con un objeto separado:

```bash
kubectl label namespace dev \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=baseline
```

Niveles: `privileged`, `baseline`, `restricted`. Modos: `enforce` (rechaza), `warn` (permite, con warning), `audit` (permite, queda en el audit log).

Ejemplo de rechazo al crear un Pod privilegiado en un namespace `restricted`:

```bash
kubectl run privileged-pod --image=nginx \
  --overrides='{"spec":{"containers":[{"name":"privileged-pod","image":"nginx","securityContext":{"privileged":true}}]}}' \
  -n dev
```

```
Error from server (Forbidden): pods "privileged-pod" is forbidden: violates PodSecurity "restricted:latest": 
privileged (container "privileged-pod" must not set securityContext.privileged=true)
```

### Dynamic admission control: webhooks

Cuando la lógica no puede resolverse con un built-in controller, se registra un `ValidatingWebhookConfiguration` o `MutatingWebhookConfiguration` que apunta a un servicio HTTP (típicamente corriendo dentro del cluster):

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: require-labels
webhooks:
- name: require-labels.example.com
  clientConfig:
    service:
      name: label-validator
      namespace: policy-system
      path: "/validate"
    caBundle: <base64-ca-cert>
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Fail
```

`failurePolicy: Fail` significa que si el webhook no responde, la petición se rechaza (fail-closed); `Ignore` la deja pasar (fail-open). Es un detalle que suele aparecer en preguntas de examen sobre comportamiento ante caída del webhook.

---

## Referencias

- Controlling Access to the Kubernetes API — https://kubernetes.io/docs/concepts/security/controlling-access/
- Authenticating — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Dynamic Admission Control — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf