# Tema 5.2 — Using least-privilege identity and access management

## Objetivo

Este tema evalúa la capacidad de diseñar y auditar el modelo de identidad y autorización de Kubernetes (principalmente **RBAC**) aplicando el principio de **least privilege**: cada humano, `ServiceAccount` o componente debe tener exactamente los permisos que necesita para su función, ni uno más. En el examen esto se traduce en tareas concretas: crear `Role`/`ClusterRole` acotados, detectar bindings peligrosos (ej. `cluster-admin` atado a un SA de aplicación), y restringir el uso de `ServiceAccount tokens`.

## 1. Modelo de autorización en Kubernetes

Cada request al API server pasa por tres etapas: **Authentication** (¿quién sos?) → **Authorization** (¿qué te dejamos hacer?) → **Admission Control** (¿esta acción específica se permite/mutila?). Este tema se enfoca en la etapa de **Authorization**, y el modo relevante es **RBAC** (Role-Based Access Control), el más usado en clusters modernos frente a ABAC, Webhook o Node authorization.

```bash
kubectl api-versions | grep rbac
# rbac.authorization.k8s.io/v1
```

RBAC se puede confirmar como modo activo mirando los flags del `kube-apiserver`:

```bash
ps -ef | grep kube-apiserver | grep authorization-mode
# --authorization-mode=Node,RBAC
```

## 2. Building blocks de RBAC

RBAC define permisos mediante 4 objetos:

| Objeto | Alcance | Une... |
|---|---|---|
| `Role` | Namespaced | reglas de permisos dentro de un namespace |
| `ClusterRole` | Cluster-wide | reglas (namespaced o cluster-scoped, incl. recursos no-namespaced como `nodes`) |
| `RoleBinding` | Namespaced | un `subject` (User/Group/SA) con un `Role` o `ClusterRole` (acotado al namespace del binding) |
| `ClusterRoleBinding` | Cluster-wide | un `subject` con un `ClusterRole`, aplicado a todo el cluster |

### Ejemplo: Role con permisos mínimos

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
  name: read-pods
  namespace: dev
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: dev
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

También se pueden generar imperativamente (útil para el examen por velocidad):

```bash
kubectl create role pod-reader --verb=get,list,watch --resource=pods -n dev
kubectl create rolebinding read-pods --role=pod-reader --serviceaccount=dev:app-sa -n dev
```

## 3. Antipatrones que rompen least privilege

El examen suele pedir **identificar y corregir** estos casos:

- **Wildcards excesivos**: `verbs: ["*"]`, `resources: ["*"]`, `apiGroups: ["*"]` en un Role de aplicación.
- **`cluster-admin` mal atado**: usar el `ClusterRoleBinding` built-in `cluster-admin` para un `ServiceAccount` de un Deployment (no debería tener más que lo que su código necesita).
- **Verbos de escalación**: `escalate`, `bind`, `impersonate` sobre `roles`/`clusterroles`/`rolebindings` permiten a un subject otorgarse permisos adicionales o actuar como otro usuario — deben restringirse a operadores administrativos.
- **`ClusterRoleBinding` en vez de `RoleBinding`**: otorgar acceso cluster-wide cuando el permiso solo se necesita en un namespace.
- **Secrets sin acotar**: `get`/`list` sobre `secrets` a nivel cluster expone credenciales de todos los namespaces; hay que acotar por namespace y, si es posible, por `resourceNames`.

```yaml
# MAL: permiso total sobre secrets en todo el cluster
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["*"]
```

```yaml
# BIEN: solo lectura de un secret puntual, en su namespace
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["db-credentials"]
  verbs: ["get"]
```

### Detectar bindings riesgosos

```bash
# ¿quién tiene cluster-admin?
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .subjects'
```

```bash
# auditar todas las reglas con wildcard
kubectl get clusterroles -o json \
  | jq '.items[] | select(.rules[]?.resources[]? == "*" or .rules[]?.verbs[]? == "*") | .metadata.name'
```

## 4. `kubectl auth can-i` — verificar permisos efectivos

Herramienta central para auditar y para probar cambios de RBAC durante el examen:

```bash
kubectl auth can-i delete pods --namespace dev \
  --as=system:serviceaccount:dev:app-sa
# no

kubectl auth can-i list secrets --all-namespaces \
  --as=system:serviceaccount:dev:app-sa
# no
```

```bash
# lista TODOS los permisos que un subject tiene en un namespace
kubectl auth can-i --list --namespace dev \
  --as=system:serviceaccount:dev:app-sa
```

## 5. `ServiceAccount`s con least privilege

Por defecto, cada namespace tiene un SA `default`, y **todo Pod que no especifique `serviceAccountName` lo monta automáticamente**, junto a su token, en `/var/run/secrets/kubernetes.io/serviceaccount`. Buenas prácticas:

1. **Crear un SA dedicado por workload**, nunca reutilizar `default`:

```bash
kubectl create serviceaccount app-sa -n dev
```

2. **Deshabilitar el automount del token** cuando el Pod no necesita hablar con el API server:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: dev
automountServiceAccountToken: false
```

O a nivel Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: worker
spec:
  serviceAccountName: app-sa
  automountServiceAccountToken: false
  containers:
  - name: worker
    image: myapp:1.0
```

3. **Verificar que el `default` SA de cada namespace no tenga bindings**:

```bash
kubectl get rolebindings,clusterrolebindings -A -o json \
  | jq -r '.items[] | select(.subjects[]?.name=="default") | .metadata.name'
```

4. Desde Kubernetes v1.24+, los tokens de SA ya no se crean automáticamente como `Secret` de larga vida — se usan **tokens efímeros con TTL** vía `TokenRequest API`, montados por el kubelet. Esto reduce el blast radius si un token se filtra, pero no reemplaza la necesidad de acotar permisos con RBAC.

```bash
# generar manualmente un token de corta duración para pruebas
kubectl create token app-sa -n dev --duration=10m
```

## 6. Aggregated ClusterRoles

Para escalar permisos de forma modular sin editar `ClusterRole`s existentes (ej. sumar acceso a un CRD a los roles built-in `view`/`edit`/`admin`):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: crd-reader
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["widgets"]
  verbs: ["get", "list", "watch"]
```

Este mecanismo también es un vector a revisar: un label de agregación mal puesto puede escalar permisos involuntariamente a todos los usuarios con rol `view`.

## 7. Herramientas de auditoría RBAC

No son parte del binario `kubectl` pero aparecen en el curriculum y en la práctica real:

- **`kubectl-who-can`**: responde "¿quién puede hacer `X` sobre `Y`?"
  ```bash
  kubectl who-can delete secrets -n dev
  ```
- **`rakkess`** (Review Access): matriz de acceso por recurso para el usuario actual.
  ```bash
  rakkess --namespace dev
  ```
- **`audit2rbac`**: genera un `Role`/`ClusterRoleBinding` mínimo a partir de logs de audit, útil para pasar de "permiso amplio" a "permiso justo" reconstruyendo lo que realmente se usó.

## 8. Checklist mental para el examen

- ¿El subject (User/Group/SA) tiene el `Role` más chico posible, en el namespace correcto?
- ¿Hay `verbs`/`resources`/`apiGroups` con `"*"` que se puedan reemplazar por una lista explícita?
- ¿Algún `ServiceAccount` de aplicación está atado a `cluster-admin`, `edit` o `admin` sin necesidad?
- ¿Los Pods que no llaman al API server tienen `automountServiceAccountToken: false`?
- ¿Se usó `RoleBinding` (namespaced) en vez de `ClusterRoleBinding` cuando el alcance real era un solo namespace?
- ¿`kubectl auth can-i --as=...` confirma el resultado esperado después del fix?

## Referencias

- CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Using RBAC Good Practices: https://kubernetes.io/docs/concepts/security/rbac-good-practices/
- Authorization Overview: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Service Account Tokens (Admin guide): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Managing Service Accounts: https://kubernetes.io/docs/concepts/security/service-accounts/
- kubectl-who-can: https://github.com/aquasecurity/kubectl-who-can
- rakkess: https://github.com/corneliusweig/rakkess
- audit2rbac: https://github.com/liggitt/audit2rbac