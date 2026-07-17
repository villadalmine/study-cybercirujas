# CKS 3.2 — Exercise Caution in Using Service Accounts

## Contexto

Todo Pod en Kubernetes se ejecuta bajo la identidad de una `ServiceAccount` (SA), que es la forma en que un proceso dentro del clúster se autentica ante el API server. Por defecto, cada namespace tiene una SA llamada `default`, y cualquier Pod que no especifique `serviceAccountName` la usa automáticamente. Este comportamiento por defecto es una de las superficies de ataque más comunes en clústeres mal configurados: si un atacante compromete un contenedor, el token de la SA montado en el Pod puede darle acceso directo al API server con los permisos que esa SA tenga asignados (vía RBAC).

El objetivo de este dominio es minimizar esa superficie: no confiar en las SAs por defecto, no automontar tokens quesqcion no se necesitan, y aplicar least privilege cuando se crean SAs nuevas.

## 1. El problema de la `default` ServiceAccount

Al crear un namespace, Kubernetes crea automáticamente la SA `default`:

```bash
$ kubectl get sa -n dev
NAME      SECRETS   AGE
default   0         3m
```

Si un Pod no define `serviceAccountName`, usa `default`, y (en clústeres sin ajustes) monta su token automáticamente en `/var/run/secrets/kubernetes.io/serviceaccount/`:

```bash
$ kubectl run test --image=nginx -n dev
$ kubectl exec test -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/
ca.crt
namespace
token
```

Ese token puede usarse desde dentro del contenedor para hablar con el API server:

```bash
$ kubectl exec test -n dev -- sh -c '
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/dev/pods'
```

Si `default` tiene algún `RoleBinding`/`ClusterRoleBinding` asociado (algo que ocurre más de lo que debería, por ejemplo por herencia de un `ClusterRoleBinding` amplio), un contenedor comprometido puede escalar horizontalmente dentro del clúster sin que el atacante haya necesitado robar ninguna credencial adicional.

**Regla práctica:** la SA `default` nunca debería tener permisos RBAC asignados, y en general no debería usarse para workloads reales.

## 2. Deshabilitar el automount de tokens

Desde Kubernetes 1.24, la SA por defecto ya no genera automáticamente un `Secret` de larga duración (ver punto 4), pero el token sigue montándose vía `TokenRequest` a menos que se deshabilite explícitamente.

Hay dos niveles donde se controla `automountServiceAccountToken`:

### A nivel de ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: dev
automountServiceAccountToken: false
```

```bash
$ kubectl patch sa default -n dev -p '{"automountServiceAccountToken": false}'
serviceaccount/default patched
```

### A nivel de Pod (tiene precedencia sobre la SA)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: dev
spec:
  serviceAccountName: default
  automountServiceAccountToken: false
  containers:
  - name: nginx
    image: nginx
```

Verificación:

```bash
$ kubectl exec nginx -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

La mayoría de las workloads (sitios web estáticos, procesadores batch que no llaman al API server, etc.) no necesitan hablar con la API de Kubernetes en absoluto. Para esos casos, `automountServiceAccountToken: false` elimina por completo esa vía de ataque, incluso si la SA tuviese permisos.

**Nota de examen:** si el Pod especifica `automountServiceAccountToken: true` explícitamente, esto **sobreescribe** un `false` puesto a nivel de SA. El valor del Pod siempre gana sobre el de la SA.

## 3. Crear ServiceAccounts dedicadas con permisos mínimos

En vez de reutilizar `default`, cada workload que realmente necesite hablar con el API server debe tener su propia SA, con un `Role`/`ClusterRole` acotado exactamente a lo que necesita (least privilege).

Ejemplo: una app que solo necesita leer `ConfigMaps` en su propio namespace.

```bash
$ kubectl create serviceaccount cm-reader -n dev
serviceaccount/cm-reader created
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-reader
  namespace: dev
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cm-reader-binding
  namespace: dev
subjects:
- kind: ServiceAccount
  name: cm-reader
  namespace: dev
roleRef:
  kind: Role
  name: configmap-reader
  apiGroup: rbac.authorization.k8s.io
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: dev
spec:
  serviceAccountName: cm-reader
  containers:
  - name: app
    image: myapp:1.0
```

Errores comunes que hay que evitar (y que aparecen en el examen):

- Usar `ClusterRole` + `ClusterRoleBinding` cuando el acceso solo se necesita en un namespace (usar `Role`/`RoleBinding` en su lugar).
- Otorgar verbos amplios (`*`, o `create`/`delete`/`patch` sobre `secrets`/`pods/exec`) cuando la app solo necesita `get`/`list`.
- Vincular una SA a `cluster-admin` "para que funcione" en vez de acotar los `rules` — un patrón que un examinador de CKS penaliza directamente.

## 4. Auditar permisos existentes

Para verificar qué puede hacer una SA antes o después de aplicar cambios, se usa `kubectl auth can-i` con `--as`:

```bash
$ kubectl auth can-i list secrets \
  --as=system:serviceaccount:dev:cm-reader -n dev
no

$ kubectl auth can-i list configmaps \
  --as=system:serviceaccount:dev:cm-reader -n dev
yes
```

Para ver todos los `RoleBinding`/`ClusterRoleBinding` que referencian una SA concreta (no hay un comando nativo directo; se filtra sobre `get -o json`):

```bash
$ kubectl get rolebindings,clusterrolebindings -A -o json \
  | jq -r '.items[] | select(.subjects[]?.name=="cm-reader") | .metadata.name'
```

Herramientas externas mencionadas en la documentación y ecosistema de auditoría RBAC (útiles en CTFs/labs, no requieren instalación en el examen real salvo que se indique):

- `kubectl-who-can` (plugin de krew) — lista qué subjects (users/SAs) pueden ejecutar un verbo sobre un recurso.
- `rbac-lookup` (Aqua Security) — similar, orientado a auditoría masiva.

## 5. Tokens de ServiceAccount: legacy vs. bound tokens

Antes de Kubernetes 1.24, crear una SA generaba automáticamente un `Secret` tipo `kubernetes.io/service-account-token` con un token de **larga duración, sin expiración**. Desde 1.24 esto ya no ocurre por defecto: los Pods reciben tokens **bound** (ligados al Pod, con audiencia y expiración) vía la `TokenRequest API`, montados como `projected volume`.

Comparación clave para el examen:

| | Legacy (Secret) | Bound token (TokenRequest) |
|---|---|---|
| Expiración | No expira | Expira (default 1h, renovado automáticamente) |
| Audiencia | Genérica | Ligada a audiencia específica (`kube-apiserver` por defecto) |
| Ligado al Pod | No — sobrevive aunque el Pod muera | Sí — se invalida si el Pod es eliminado |
| Creación | Automática al crear la SA | Bajo demanda al crear el Pod |

Si aún existen `Secrets` de tipo `kubernetes.io/service-account-token` legacy en el clúster (por ejemplo, migrados desde una versión vieja), conviene identificarlos y eliminarlos si no están en uso, porque son credenciales de larga vida que no rotan:

```bash
$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token
```

Para generar manualmente un token de corta duración con audiencia y expiración explícitas (por ejemplo, para uso fuera del clúster):

```bash
$ kubectl create token cm-reader -n dev --duration=10m
eyJhbGciOiJSUzI1NiIsImtpZCI6...
```

## 6. Buenas prácticas — checklist

- No usar la SA `default` para workloads; crear una SA dedicada por aplicación.
- `automountServiceAccountToken: false` en toda SA/Pod que no necesite hablar con el API server.
- RBAC de mínimo privilegio: `Role`/`RoleBinding` acotados a namespace, evitar `ClusterRole`/`ClusterRoleBinding` salvo necesidad real de alcance cluster-wide.
- Nunca vincular `cluster-admin` (ni roles equivalentes de amplio alcance) a una SA de aplicación.
- Auditar periódicamente con `kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>`.
- Preferir tokens bound (comportamiento por defecto desde 1.24) sobre `Secrets` legacy sin expiración; eliminar los legacy que encuentres.
- Considerar `enable-admission-plugins=... ,PodSecurity` o políticas OPA/Gatekeeper/Kyverno que rechacen Pods sin `automountServiceAccountToken: false` explícito cuando no se necesita, como control preventivo adicional (fuera del alcance directo de RBAC, pero relacionado a defense-in-depth).

## Referencias

- CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Managing Service Accounts (admin guide): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Service Accounts (concepts): https://kubernetes.io/docs/concepts/security/service-accounts/
- RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- TokenRequest API / Bound Service Account Tokens (KEP): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#bound-service-account-token-volume