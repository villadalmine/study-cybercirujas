# 3.6 Manage Role Based Access Control (RBAC)

## Qué es RBAC

RBAC (Role-Based Access Control) es el mecanismo de autorización que usa Kubernetes para decidir qué acciones puede ejecutar un `subject` (un usuario, un grupo o un `ServiceAccount`) sobre qué `resources` del clúster. RBAC actúa **después** de la autenticación: primero el API server identifica quién hace la request (autenticación), y luego RBAC decide si esa identidad tiene permiso para hacer lo que está pidiendo (autorización).

RBAC se implementa mediante el `apiserver` como un plugin de autorización (`--authorization-mode=RBAC`). En la mayoría de las distribuciones modernas (kubeadm, EKS, GKE, AKS) viene habilitado por defecto. Podés verificarlo así:

```bash
kubectl api-versions | grep rbac.authorization.k8s.io
```

```
rbac.authorization.k8s.io/v1
```

Todos los objetos de RBAC son **declarativos**: se definen como recursos de Kubernetes (`Role`, `ClusterRole`, `RoleBinding`, `ClusterRoleBinding`) y viven dentro del `apiGroup` `rbac.authorization.k8s.io/v1`.

## Los cuatro objetos de RBAC

RBAC se construye combinando dos conceptos: **qué se puede hacer** (definido en un `Role` o `ClusterRole`) y **quién puede hacerlo** (asignado con un `RoleBinding` o `ClusterRoleBinding`).

| Objeto | Alcance | Define |
|---|---|---|
| `Role` | Namespaced | Un conjunto de permisos (`rules`) dentro de un namespace específico |
| `ClusterRole` | Cluster-wide | Un conjunto de permisos que puede aplicarse a todo el clúster, a recursos cluster-scoped (nodes, PVs), o a recursos non-resource URLs (`/healthz`) |
| `RoleBinding` | Namespaced | Asocia un `Role` (o un `ClusterRole`) a uno o más `subjects`, con efecto limitado a un namespace |
| `ClusterRoleBinding` | Cluster-wide | Asocia un `ClusterRole` a `subjects`, con efecto en todo el clúster |

Un detalle que suele aparecer en el examen: un `RoleBinding` **puede** referenciar un `ClusterRole`. Esto es útil cuando querés reutilizar un mismo `ClusterRole` (por ejemplo uno genérico de "solo lectura de pods") en varios namespaces distintos, pero limitando su efecto a cada namespace mediante el `RoleBinding` correspondiente. Lo que **no** es posible es lo inverso: un `ClusterRoleBinding` no puede referenciar un `Role` namespaced.

## Anatomía de una regla (`rules`)

Cada `Role`/`ClusterRole` contiene una lista de `rules`. Cada regla combina tres campos principales:

```yaml
rules:
- apiGroups: [""]              # "" es el core API group (pods, services, configmaps...)
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

- **apiGroups**: el grupo de API del recurso. El core group se representa como cadena vacía `""`. Otros ejemplos: `apps` (Deployments), `batch` (Jobs/CronJobs), `rbac.authorization.k8s.io`.
- **resources**: el tipo de recurso, en plural (`pods`, `deployments`, `configmaps`). También se pueden referenciar subresources con `/`, por ejemplo `pods/log` o `pods/exec`.
- **verbs**: la acción permitida. Los más comunes son `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`. El wildcard `*` habilita todos los verbs sobre ese recurso.
- **resourceNames** (opcional): restringe la regla a instancias específicas por nombre, por ejemplo permitir `get` solo sobre el ConfigMap `app-config`. No se puede combinar con `create` (porque el nombre del objeto nuevo aún no existe al momento de evaluar la request).

Ejemplo de regla con `resourceNames`:

```yaml
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config"]
  verbs: ["get", "watch"]
```

## Creando Role y RoleBinding

### Forma imperativa

```bash
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods \
  --namespace=dev
```

```bash
kubectl create rolebinding read-pods-binding \
  --role=pod-reader \
  --serviceaccount=dev:app-sa \
  --namespace=dev
```

`--serviceaccount=dev:app-sa` toma la forma `namespace:nombre` y asigna el rol al `ServiceAccount` `app-sa` del namespace `dev`. Si el subject fuera un usuario o un grupo, se usaría `--user=` o `--group=` en su lugar.

### Forma declarativa (equivalente)

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
  name: read-pods-binding
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

`roleRef.apiGroup` siempre es `rbac.authorization.k8s.io`, sin importar el `apiGroup` de los recursos sobre los que aplica el rol. Un dato clave del examen: **`roleRef` es inmutable** una vez creado el `Binding`. Si necesitás cambiar a qué rol apunta un binding, hay que borrarlo y recrearlo (no se puede editar con `kubectl edit`).

## ClusterRole y ClusterRoleBinding

Un `ClusterRole` se usa en tres escenarios típicos:

1. Otorgar permisos sobre recursos **cluster-scoped** (`nodes`, `persistentvolumes`, `namespaces`, `clusterroles`), que no pertenecen a ningún namespace.
2. Otorgar permisos sobre **non-resource endpoints** como `/healthz` o `/metrics`.
3. Definir un conjunto de permisos reutilizable que luego se aplica en distintos namespaces vía `RoleBinding`.

```bash
kubectl create clusterrole node-reader \
  --verb=get,list,watch \
  --resource=nodes
```

```bash
kubectl create clusterrolebinding node-reader-binding \
  --clusterrole=node-reader \
  --user=jane
```

Non-resource URLs solo pueden definirse en `ClusterRole` (nunca en `Role`), usando el campo `nonResourceURLs` en vez de `resources`:

```yaml
rules:
- nonResourceURLs: ["/healthz", "/healthz/*"]
  verbs: ["get"]
```

## Roles predefinidos (default ClusterRoles)

Kubernetes trae `ClusterRoles` listas para usar, pensadas para cubrir los casos de uso más comunes sin tener que escribir reglas desde cero:

| ClusterRole | Uso típico |
|---|---|
| `view` | Solo lectura de la mayoría de los recursos de un namespace (no ve `Secrets` completos) |
| `edit` | Lectura/escritura de recursos, sin poder modificar Roles/RoleBindings |
| `admin` | Control total dentro de un namespace, incluyendo gestión de Roles/RoleBindings locales |
| `cluster-admin` | Control total sobre todo el clúster (superusuario) |

```bash
kubectl create rolebinding dev-team-edit \
  --clusterrole=edit \
  --user=carlos \
  --namespace=staging
```

Este patrón —usar un `ClusterRole` predefinido combinado con un `RoleBinding` namespaced— es el enfoque recomendado para dar acceso de equipo por namespace sin tener que redefinir permisos.

## ServiceAccounts y RBAC

Todo Pod se ejecuta con un `ServiceAccount` (por defecto, `default` del namespace). Ese `ServiceAccount` es el `subject` más común en `RoleBindings` cuando el objetivo es dar permisos a una aplicación que necesita hablar con la API de Kubernetes (por ejemplo, un controller o un operator).

```bash
kubectl create serviceaccount app-sa -n dev
```

```yaml
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: dev
```

Buenas prácticas relevantes para el examen:
- Nunca asignar `cluster-admin` a un `ServiceAccount` de aplicación salvo necesidad real (por ejemplo, un controller que gestiona CRDs en todo el clúster).
- Usar `automountServiceAccountToken: false` en el Pod o el `ServiceAccount` cuando la aplicación no necesita hablar con la API.
- Si un `ServiceAccount` no tiene ningún `RoleBinding`/`ClusterRoleBinding` asociado, solo tiene los permisos que el clúster otorgue a `system:authenticated` (normalmente ninguno relevante).

## Verificando permisos: `kubectl auth can-i`

Esta es la herramienta central para debug y verificación de RBAC en el examen.

```bash
kubectl auth can-i create deployments --namespace=dev
```

```
yes
```

```bash
kubectl auth can-i delete pods --namespace=dev --as=system:serviceaccount:dev:app-sa
```

```
no
```

`--as` simula la identidad de otro usuario o `ServiceAccount` (requiere permiso de `impersonate` sobre ese subject). También existe `--as-group` para simular pertenencia a un grupo.

Para ver todo lo que un subject puede hacer en un namespace:

```bash
kubectl auth can-i --list --namespace=dev --as=system:serviceaccount:dev:app-sa
```

```
Resources                                       Non-Resource URLs   Resource Names   Verbs
pods                                             []                  []               [get list watch]
```

## Aggregated ClusterRoles

Un `ClusterRole` puede agregar automáticamente las reglas de otros `ClusterRoles` que coincidan con un `label selector`, usando `aggregationRule`. Esto es lo que usan internamente `view`, `edit` y `admin`: permite que un CRD o addon extienda esos roles agregando su propio `ClusterRole` con la label correspondiente, sin tener que editar el rol agregador.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-edit
  labels:
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules:
- apiGroups: ["monitoring.coreos.com"]
  resources: ["prometheusrules", "servicemonitors"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

Con esta label, las reglas de `monitoring-edit` quedan automáticamente incluidas dentro del `ClusterRole` `edit` sin tocar su definición original. El campo `rules` de un `ClusterRole` agregador se recalcula por el controller de agregación; editarlo manualmente no tiene efecto persistente.

## Troubleshooting típico en el examen

1. **"Forbidden" al ejecutar una acción**: confirmar el `subject` exacto (usuario, group o `system:serviceaccount:<ns>:<name>`), y usar `kubectl auth can-i ... --as=...` para reproducir el error sin tener que loguearse como esa identidad.
2. **RoleBinding en el namespace incorrecto**: un `RoleBinding` solo aplica en el namespace donde vive (`metadata.namespace`), aunque el `subject` sea un `ServiceAccount` de otro namespace.
3. **Confundir `Role` con `ClusterRole` en `roleRef.kind`**: si el YAML dice `kind: Role` pero el nombre corresponde a un `ClusterRole` (o viceversa), el binding falla silenciosamente en dar los permisos esperados — revisar con `kubectl describe rolebinding <name>`.
4. **Ver reglas efectivas de un rol**:
   ```bash
   kubectl describe clusterrole edit
   ```
5. **Listar bindings de un subject** (no hay comando directo; conviene filtrar por `-o yaml` o usar `kubectl get rolebindings,clusterrolebindings -A -o json` combinado con `jq`).

## Referencias

- Documentación oficial de RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Using RBAC Authorization (kubectl create role/rolebinding): https://kubernetes.io/docs/reference/access-authn-authz/rbac/#role-and-clusterrole
- Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- kubectl reference — `kubectl auth can-i`: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#auth
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf