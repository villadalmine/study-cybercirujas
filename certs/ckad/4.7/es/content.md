# 4.7 Understand ServiceAccounts

**Examen:** CKAD (versión 1.35) · **Peso:** 3

---

## 1. Qué es y por qué existe

Un **ServiceAccount** es una identidad de Kubernetes para **procesos que corren dentro de Pods**, distinta de las cuentas de **User** que usan las personas (vía certificados, OIDC, etc.) para hablar con `kubectl`. Cuando un Pod necesita llamar a la API server —para leer un `ConfigMap` propio, listar otros Pods, crear un Job, o hablar con un Operator— necesita autenticarse, y esa autenticación se hace con la identidad del ServiceAccount asignado al Pod, no con la del usuario que lo creó.

`ServiceAccount` es un resource nativo, namespaced, de la API core (`v1`):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: default
```

Por sí solo, un ServiceAccount **no otorga ningún permiso**. Es solo una identidad (un "quién sos"); qué puede hacer esa identidad lo define RBAC (`Role`/`RoleBinding`, tema 4.2). Este tema se enfoca en la mecánica de la identidad: cómo se crea, cómo se asigna a un Pod, cómo obtiene y usa su token, y cómo inspeccionarla — no en escribir las reglas de autorización en sí.

## 2. El ServiceAccount por defecto

Todo namespace tiene, desde su creación, un ServiceAccount llamado `default`:

```bash
$ kubectl get serviceaccounts
NAME      SECRETS   AGE
default   0         3h
```

Todo Pod que **no** especifica `spec.serviceAccountName` queda automáticamente asociado al `default` de su namespace. Esto es cómodo pero riesgoso: si el `default` tiene permisos RBAC amplios (por ejemplo, por un `RoleBinding` mal alcanzado), **cualquier** Pod del namespace hereda esos permisos sin que nadie lo haya pedido explícitamente. Una buena práctica — mencionada más abajo — es no dejar workloads corriendo con `default` cuando necesitan hablar con la API, y en general no otorgarle RBAC al `default` en absoluto.

```bash
$ kubectl get pod web -o jsonpath='{.spec.serviceAccountName}{"\n"}'
default
```

## 3. Crear y asignar un ServiceAccount propio

Imperativo:

```bash
$ kubectl create serviceaccount app-sa
serviceaccount/app-sa created
```

Declarativo — el YAML de la sección 1. Para asignarlo a un Pod (o al `template` de un Deployment/Job/CronJob) se usa `spec.serviceAccountName`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  serviceAccountName: app-sa
  containers:
  - name: app
    image: nginx:1.27
```

```bash
$ kubectl apply -f pod.yaml
pod/web created

$ kubectl get pod web -o jsonpath='{.spec.serviceAccountName}{"\n"}'
app-sa
```

`serviceAccountName` **es inmutable** una vez creado el Pod (como toda buena parte de `spec` en un Pod ya corriendo) — cambiarlo requiere recrear el Pod, lo cual en un Deployment ocurre naturalmente al editar `spec.template.spec.serviceAccountName` y disparar un rollout (mismo mecanismo que en 2.2).

Existe también un campo legacy `serviceAccount` (sin `Name`), mantenido solo por compatibilidad hacia atrás — `kubectl` y los manifests actuales deben usar `serviceAccountName`.

## 4. El token: mecanismo moderno vs. legacy

Cuando un Pod usa un ServiceAccount, el kubelet le monta automáticamente un **token** que sirve como credencial ante la API server, además de la CA del cluster y el namespace. Esto vale tanto para el `default` como para cualquier ServiceAccount custom.

```bash
$ kubectl exec web -- ls /var/run/secrets/kubernetes.io/serviceaccount/
ca.crt
namespace
token

$ kubectl exec web -- cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
default
```

Cómo se genera ese token cambió de forma importante:

| | **Legacy (pre-1.24)** | **Moderno (BoundServiceAccountTokenVolume, GA desde 1.22, único comportamiento desde 1.24)** |
|---|---|---|
| Mecanismo | Un `Secret` de tipo `kubernetes.io/service-account-token` se creaba automáticamente por cada ServiceAccount y quedaba listado en `serviceAccountName.secrets[]` | **Projected volume** con fuente `serviceAccountToken`, generado en runtime vía la **TokenRequest API** |
| Expiración | Sin expiración (válido hasta borrar el Secret) | Expira (default 1h de vida, **auto-renovado** por el kubelet antes de vencer mientras el Pod exista) |
| Audience | Ninguna (válido contra cualquier consumidor que confíe en el cluster) | **Audience-bound** — por defecto solo válido contra el API server del propio cluster |
| Ligado al Pod | No — el token vive independiente del Pod que lo usa | Sí — incluye claims del Pod (`kubernetes.io/pod-name`, UID), se invalida si el Pod se borra |
| Creación de Secret al crear el SA | Automática | **No** — `kubectl get sa` moderno muestra `SECRETS: 0` salvo que se cree uno a mano |

En clusters actuales (1.24+), `kubectl create serviceaccount` **ya no** crea un Secret asociado automáticamente. Si hace falta un token de larga duración de forma explícita (por ejemplo para un sistema externo al cluster que no puede recibir tokens renovados), hay que crearlo a mano:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-sa-token
  annotations:
    kubernetes.io/service-account.name: app-sa
type: kubernetes.io/service-account-token
```

El controller de tokens rellena automáticamente los campos `data.token`, `data.ca.crt` y `data.namespace` de ese Secret al aplicarlo. Esta vía sigue existiendo pero es la excepción, no el default — el examen espera que reconozcas el mecanismo de **projected token** como el comportamiento normal.

También se puede pedir un token puntual sin crear ningún objeto persistente, útil para debug o para pasárselo a una herramienta externa:

```bash
$ kubectl create token app-sa --duration=10m
eyJhbGciOiJSUzI1NiIsImtpZCI6Ii1QYnRZ...   # JWT, expira en 10 minutos
```

## 5. Cómo el Pod usa su token para hablar con la API

Dentro de un container, el token montado más la CA permiten autenticarse contra la API server sin credenciales adicionales — es el patrón que usan los propios controllers y Operators (ver tema 4.1) para gestionar resources desde dentro del cluster:

```bash
$ kubectl exec web -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -sS --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/default/pods
'
{
  "kind": "Status",
  "status": "Failure",
  "message": "pods is forbidden: User \"system:serviceaccount:default:app-sa\" cannot list resource \"pods\" in API group \"\" in the namespace \"default\"",
  "reason": "Forbidden",
  ...
}
```

Este `Forbidden` es exactamente el punto donde termina este tema y empieza RBAC (4.2): la autenticación funcionó (el API server reconoció al ServiceAccount, `system:serviceaccount:<namespace>:<name>` es el username resultante), pero no hay ninguna `Role`/`RoleBinding` que le dé permiso de `list` sobre `pods`. `kubernetes.default.svc` es el nombre DNS interno del propio API server, siempre disponible dentro del cluster sin configuración extra.

Para simular rápido si un ServiceAccount tendría permiso, sin necesidad de exec-earse dentro de un Pod:

```bash
$ kubectl auth can-i list pods --as=system:serviceaccount:default:app-sa
no

$ kubectl auth can-i list pods --as=system:serviceaccount:default:app-sa -n kube-system
no
```

## 6. `automountServiceAccountToken`

Montar el token es el comportamiento por defecto, pero no todo Pod necesita hablar con la API — un servidor web estático, por ejemplo, no tiene ninguna razón para tener credenciales del cluster dentro del container. Exponer un token innecesariamente es superficie de ataque de más: si el container es comprometido, el atacante hereda esa identidad. `automountServiceAccountToken: false` desactiva el montaje, y puede definirse en dos niveles:

```yaml
# A nivel ServiceAccount: aplica a todo Pod que lo use, salvo que el Pod lo pise
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
automountServiceAccountToken: false
```

```yaml
# A nivel Pod: gana sobre lo que diga el ServiceAccount
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  serviceAccountName: app-sa
  automountServiceAccountToken: false
  containers:
  - name: app
    image: nginx:1.27
```

`spec.automountServiceAccountToken` del **Pod** tiene prioridad sobre el del ServiceAccount cuando ambos están definidos; si el Pod no lo define, hereda el valor del ServiceAccount; si ninguno lo define, el default es `true` (se monta).

```bash
$ kubectl get pod web -o yaml | grep -A1 serviceaccount/token
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: kube-api-access-x7z2p

$ kubectl exec web -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

(El segundo bloque corresponde a un Pod con `automountServiceAccountToken: false`: el volumen ni siquiera se monta.)

## 7. ServiceAccount + RBAC

El tema 4.2 cubre `Role`/`ClusterRole` y `RoleBinding`/`ClusterRoleBinding` en profundidad; acá vale repasar solo cómo un ServiceAccount entra como `subject` de un binding, porque es la forma más común en que un Pod termina con permisos concretos:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-sa-pod-reader
  namespace: default
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: default        # obligatorio: el binding no asume el mismo namespace que el subject
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
$ kubectl apply -f rolebinding.yaml
rolebinding.rbac.authorization.k8s.io/app-sa-pod-reader created

$ kubectl auth can-i list pods --as=system:serviceaccount:default:app-sa
yes
```

Un `ClusterRoleBinding` con un ServiceAccount como subject le da esos permisos **en todo el cluster**, aunque el ServiceAccount en sí siga siendo un objeto namespaced — es una de las formas más comunes (y más peligrosas si se usa de más) de escalar privilegios de un Pod más allá de su propio namespace. El patrón inverso — un `RoleBinding` namespaced que referencia un `ClusterRole` — es la forma habitual de reusar un mismo set de permisos (por ejemplo `view`, `edit`, `admin`, los `ClusterRole` predefinidos de Kubernetes) limitado a un namespace puntual.

## 8. `imagePullSecrets` en el ServiceAccount

Además del token, un ServiceAccount puede cargar `imagePullSecrets` (Secrets tipo `kubernetes.io/dockerconfigjson`, ver 4.6) que se aplican **automáticamente a todo Pod** que lo use, sin tener que declarar `imagePullSecrets` en cada Pod/Deployment:

```bash
$ kubectl patch serviceaccount app-sa \
  -p '{"imagePullSecrets": [{"name": "regcred"}]}'
serviceaccount/app-sa patched

$ kubectl get sa app-sa -o yaml | grep -A1 imagePullSecrets
imagePullSecrets:
- name: regcred
```

Cualquier Pod que use `app-sa` a partir de ahí puede tirar imágenes del registro privado sin repetir la configuración por Pod. **Ojo:** esto no es un merge — el admission controller solo copia los `imagePullSecrets` del ServiceAccount cuando el Pod no declara ninguno propio (`len(pod.Spec.ImagePullSecrets) == 0`). Si un Pod define su **propio** `imagePullSecrets`, el del ServiceAccount se ignora por completo; un Pod que necesite ambos tiene que listarlos los dos explícitamente.

## 9. Inspección y comandos útiles

```bash
$ kubectl get serviceaccounts -A
NAMESPACE   NAME      SECRETS   AGE
default     app-sa    0         5m
default     default   0         3h
kube-system default   0         3h
...

$ kubectl describe serviceaccount app-sa
Name:                app-sa
Namespace:           default
Labels:              <none>
Annotations:         <none>
Image pull secrets:  regcred
Mountable secrets:   <none>
Tokens:              <none>
Events:               <none>

$ kubectl get rolebinding,clusterrolebinding -A \
  -o jsonpath='{range .items[?(@.subjects[0].name=="app-sa")]}{.metadata.name}{"\n"}{end}'
app-sa-pod-reader

$ kubectl delete serviceaccount app-sa
serviceaccount "app-sa" deleted
```

Borrar un ServiceAccount **no borra** los `RoleBinding`/`ClusterRoleBinding` que lo referencian — quedan apuntando a un subject inexistente (efecto nulo, no error), algo para tener presente al hacer limpieza de RBAC.

## 10. Buenas prácticas y errores frecuentes

- **No usar `default` para workloads que hablan con la API.** Crear un ServiceAccount dedicado por aplicación (o por función) hace que el RBAC sea auditable: se sabe exactamente qué Pod tiene qué permiso.
- **`automountServiceAccountToken: false` cuando el Pod no necesita hablar con la API.** Reduce superficie de ataque sin costo funcional.
- **No asumir que crear un ServiceAccount da Secrets automáticamente.** Desde 1.24, `SECRETS: 0` en `kubectl get sa` es lo normal, no un bug — el token vive como projected volume, no como Secret persistente.
- **El namespace del `subject` en un binding debe ser explícito.** Olvidar `namespace:` en el `subject` de un `RoleBinding`/`ClusterRoleBinding` es un error común que hace que el binding apunte a un ServiceAccount de otro namespace (o a ninguno).
- **`kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>` para depurar RBAC sin tener que exec-earse dentro del Pod.** Mucho más rápido para verificar en el examen si un permiso quedó bien configurado.
- **Token expirado ≠ Secret revocado.** Con el mecanismo moderno, un token vencido simplemente deja de servir (`401 Unauthorized`) y el kubelet lo renueva solo mientras el Pod siga vivo — no hace falta (ni sirve) "rotar" nada a mano en el flujo normal.

## Referencias

- Configure Service Accounts for Pods — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Service Account Tokens (TokenRequest API, BoundServiceAccountTokenVolume) — https://kubernetes.io/docs/concepts/security/service-accounts/
- Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Pull an Image from a Private Registry — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- kubectl create token — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create-token
- kubectl auth can-i — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#auth
- CNCF CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf