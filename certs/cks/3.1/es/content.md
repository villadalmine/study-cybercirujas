# CKS 3.1 — Use Role Based Access Controls to minimize exposure

## Por qué importa en el contexto de CKS

RBAC (**Role Based Access Control**) es el mecanismo nativo de Kubernetes para controlar *quién* puede hacer *qué* sobre *qué recursos*. Desde la perspectiva de seguridad (Cluster Hardening), un cluster con RBAC mal configurado es la puerta de entrada más común a un compromiso: un Pod con un `ServiceAccount` sobre-privilegiado, o un `ClusterRoleBinding` a `cluster-admin` otorgado "para que funcione", son los hallazgos más frecuentes en auditorías reales y en el examen CKS.

El objetivo del examen en este tema no es solo saber crear un `Role`, sino **identificar y corregir permisos excesivos**: dado un manifiesto o un binding existente, reducirlo al mínimo necesario (*least privilege*).

## Modelo de autorización RBAC

Kubernetes evalúa las requests a la API en varias fases: **Authentication → Authorization (RBAC u otros) → Admission Control**. RBAC es un modo de autorización aditivo — no hay reglas de "deny" explícitas; el acceso se otorga solo si existe al menos una regla que lo permita.

Cuatro objetos componen RBAC:

| Objeto | Alcance | Une |
|---|---|---|
| `Role` | Namespaced | Reglas sobre recursos de un namespace |
| `ClusterRole` | Cluster-wide | Reglas sobre recursos cluster-wide, o namespaced en todos los namespaces |
| `RoleBinding` | Namespaced | Sujetos (users/groups/SA) ↔ Role o ClusterRole (dentro del namespace) |
| `ClusterRoleBinding` | Cluster-wide | Sujetos ↔ ClusterRole (en todo el cluster) |

Un `ClusterRole` referenciado desde un `RoleBinding` es útil para reutilizar reglas comunes (por ejemplo `view`) sin duplicar YAML, pero el efecto queda acotado al namespace del binding.

### Anatomía de una regla

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: payments
  name: pod-reader
rules:
- apiGroups: [""]          # "" = core API group
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

Campos clave a minimizar en el examen:
- `apiGroups`: nunca `["*"]` salvo que realmente se necesite.
- `resources`: listar explícitamente (`pods`, `secrets`, `deployments`), evitar `["*"]`.
- `verbs`: los peligrosos son `create`, `update`, `patch`, `delete`, `deletecollection`, y especialmente `escalate`, `bind`, `impersonate` (permiten escalar privilegios).
- `resourceNames`: permite acotar a objetos puntuales, ej. `resourceNames: ["my-configmap"]`.

## Subjects: quién recibe el binding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: payments
subjects:
- kind: ServiceAccount
  name: payments-api
  namespace: payments
- kind: User
  name: "jane@example.com"
  apiGroup: rbac.authorization.k8s.io
- kind: Group
  name: "payments-team"
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Kubernetes no tiene un objeto `User`/`Group` propio: llegan desde el certificado del cliente (CN/O), un OIDC token, o son `ServiceAccount`. En producción los `ServiceAccount` son el sujeto más relevante para CKS porque cada Pod usa uno.

## Comandos imperativos (rápidos para el examen)

```bash
kubectl create role pod-reader --verb=get,list,watch --resource=pods -n payments
kubectl create rolebinding read-pods-binding \
  --role=pod-reader --serviceaccount=payments:payments-api -n payments

kubectl create clusterrole node-viewer --verb=get,list --resource=nodes
kubectl create clusterrolebinding node-viewer-binding \
  --clusterrole=node-viewer --user=jane@example.com
```

## Verificar permisos: `kubectl auth can-i`

Herramienta central para auditar exposición:

```bash
$ kubectl auth can-i delete secrets --namespace payments \
    --as=system:serviceaccount:payments:payments-api
no

$ kubectl auth can-i '*' '*' --as=system:serviceaccount:payments:payments-api
no

$ kubectl auth can-i --list --as=system:serviceaccount:payments:payments-api -n payments
Resources    Non-Resource URLs   Resource Names   Verbs
pods         []                  []               [get list watch]
```

`--list` es lo que se usa en el examen para revisar rápidamente el "blast radius" real de un `ServiceAccount` o usuario antes de decidir qué recortar.

## Roles por defecto peligrosos

Kubernetes trae `ClusterRole`s predefinidos: `cluster-admin`, `admin`, `edit`, `view`. El error más común (y el hallazgo más buscado en el examen) es un `ClusterRoleBinding` que otorga `cluster-admin` a un `ServiceAccount` de una aplicación:

```bash
$ kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'
cluster-admin
app-sa-admin-binding      # <- hallazgo: hay que investigar y corregir
```

Remediación típica: eliminar el binding excesivo y reemplazarlo por un `Role`/`RoleBinding` acotado al namespace y a los verbs realmente usados por la app (identificados con `kubectl auth can-i --list`, logs del `kube-apiserver`, o auditando el código/manifiestos de la app).

```bash
kubectl delete clusterrolebinding app-sa-admin-binding
kubectl apply -f least-privilege-role.yaml
kubectl apply -f least-privilege-rolebinding.yaml
```

## ServiceAccounts: reducir exposición por defecto

- Todo namespace tiene un `ServiceAccount` llamado `default`. Si un Pod no especifica `serviceAccountName`, usa `default` — que normalmente no debería tener ningún `RoleBinding` asociado (sin permisos = comportamiento correcto).
- Crear un `ServiceAccount` dedicado por aplicación, nunca reusar `default` para cargas con acceso a la API.
- Deshabilitar el montaje automático del token cuando el Pod no necesita hablar con la API:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
automountServiceAccountToken: false
```

o a nivel Pod:

```yaml
spec:
  serviceAccountName: payments-api
  automountServiceAccountToken: false
```

Esto evita que, si el contenedor es comprometido (ej. RCE en la app), el atacante encuentre un token válido montado en `/var/run/secrets/kubernetes.io/serviceaccount/token` y lo use para hablar con la API con los permisos del SA.

## Escalación de privilegios a evitar

Tres verbs merecen atención especial porque permiten a un sujeto otorgarse a sí mismo más permisos de los que tiene explícitamente:

- **`bind`**: permite crear un `RoleBinding`/`ClusterRoleBinding` que referencia un rol con más permisos, sin tener esos permisos directamente (si el flag `--enable-admission-plugins` incluye `RBAC`/`escalate` de forma default está bloqueado, pero conviene no otorgar `bind` salvo necesidad).
- **`escalate`**: permite modificar un `Role`/`ClusterRole` para agregarse permisos.
- **`impersonate`**: permite actuar como otro user/group/SA (`--as`), efectivamente heredando sus permisos.

Auditar estos verbs sobre `roles`, `clusterroles`, `rolebindings`, `clusterrolebindings`, `users`, `groups`, `serviceaccounts` es un chequeo recurrente:

```bash
kubectl get clusterroles -o json | \
  jq -r '.items[] | select(.rules[]?.verbs[]? == "escalate" or .rules[]?.verbs[]? == "impersonate") | .metadata.name'
```

## Herramientas de auditoría (mencionadas en el curriculum)

- **`rbac-lookup`** (Fairwinds): resuelve qué roles tiene asignado un usuario/SA en todo el cluster.
  ```bash
  rbac-lookup payments-api
  ```
- **`kubectl-who-can`** (aquasecurity): responde "quién puede hacer X sobre Y".
  ```bash
  kubectl who-can delete secrets -n payments
  ```
- **`rakkess`** (access matrix): imprime una matriz de verbs por recurso para el usuario actual (`--as` para simular otro).

Estas herramientas no siempre están preinstaladas en el examen, pero `kubectl auth can-i --list` y consultas con `jq` sobre `kubectl get rolebindings,clusterrolebindings -A -o json` cubren el mismo objetivo sin dependencias externas.

## Checklist de minimización de exposición

1. Namespace `default` ServiceAccount sin bindings.
2. Un `ServiceAccount` por aplicación, `automountServiceAccountToken: false` salvo necesidad real.
3. Ningún `ClusterRoleBinding` a `cluster-admin` fuera de operadores de infraestructura/cluster-admins humanos.
4. Reglas con `resources`/`verbs` explícitos, sin `["*"]`.
5. Auditar y remover `bind`, `escalate`, `impersonate` de roles de aplicación.
6. Revisar bindings a `Group: system:authenticated` o `system:unauthenticated` (acceso anónimo/amplio no intencional).
7. Usar `kubectl auth can-i --list --as=<subject>` como verificación final tras cada cambio.

## Referencias

- Curriculum oficial CKS v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Managing Service Accounts: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- `kubectl auth` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#auth
- Privilege Escalation Prevention and Bootstrapping: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping
- rbac-lookup: https://github.com/FairwindsOps/rbac-lookup
- kubectl-who-can: https://github.com/aquasecurity/kubectl-who-can
- rakkess: https://github.com/corneliusweig/rakkess