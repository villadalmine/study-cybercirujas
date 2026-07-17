# CKS 3.3 — Restrict access to Kubernetes API

**Dominio:** Cluster Hardening
**Peso en el examen:** 3.75%

## 1. Por qué importa

El `kube-apiserver` es el único punto de entrada al plano de control: todo objeto de Kubernetes (Pods, Secrets, RBAC, NetworkPolicies) se crea, lee o modifica a través de él. Si un atacante logra hablar con la API sin restricciones, puede escalar privilegios, leer Secrets, o desplegar cargas maliciosas sin tocar ningún nodo. Este tema se enfoca en **quién puede llegar a la API y cómo se autentica**, dejando el detalle fino de "qué puede hacer una vez autenticado" al tema de RBAC (3.2, tratado aparte).

La superficie de ataque de la API server tiene tres capas que hay que restringir:

1. **Red**: quién puede alcanzar el puerto TCP del API server.
2. **Autenticación (authN)**: cómo se identifica un cliente ante la API.
3. **Autorización (authZ)**: una vez identificado, qué se le permite (RBAC, Node authorizer, Webhook).

## 2. Restricción a nivel de red

### 2.1 `--bind-address` y firewall

El API server escucha por defecto en `0.0.0.0:6443`. En producción se debe:

- Limitar el `--bind-address` a la interfaz correcta (no siempre posible si se necesita acceso desde varios segmentos).
- Usar **firewall rules** / security groups del proveedor cloud para que el puerto 6443 solo sea alcanzable desde:
  - Los nodos worker (kubelets necesitan hablar con la API).
  - Rangos de IP de administradores / bastion hosts.
  - Nunca abierto a `0.0.0.0/0`.

```bash
# Verificar qué IPs/puertos escucha el apiserver en el nodo control-plane
ss -tlnp | grep 6443
```

```
LISTEN 0  4096  0.0.0.0:6443  0.0.0.0:*  users:(("kube-apiserver",pid=1234,fd=7))
```

### 2.2 Puerto inseguro deshabilitado

Versiones antiguas exponían un puerto HTTP sin TLS ni autenticación (`--insecure-port`, `--insecure-bind-address`). Desde Kubernetes 1.20 estas flags fueron **eliminadas**; si aparecen en un manifest de un cluster viejo o en un examen legacy, la corrección es quitarlas o dejarlas en `0`.

```bash
# Chequear el manifest estático del apiserver (kubeadm)
grep -i insecure /etc/kubernetes/manifests/kube-apiserver.yaml
# no debería devolver nada en un cluster moderno
```

### 2.3 NetworkPolicy para restringir el acceso desde Pods

Si la API server corre como parte del clúster (no siempre, en managed K8s suele ser externa), se puede limitar qué Pods pueden alcanzarla vía `NetworkPolicy` apuntando al `Service` `kubernetes` en `default`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-api-access
  namespace: apps
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.1/32   # IP del apiserver, permitir solo si es necesario
```

En managed clusters (EKS, GKE, AKS) suele existir la opción de **private API endpoint**, que remueve por completo el acceso público a la API.

## 3. Autenticación (Authentication)

El flag clave es `--authentication-token-webhook-config-file` / los distintos módulos de autenticación que Kubernetes evalúa en cadena hasta que uno confirma la identidad.

### 3.1 Deshabilitar acceso anónimo

Por defecto, requests que no pasan ningún método de autenticación se tratan como usuario `system:anonymous`, grupo `system:unauthenticated`. Si además el authorizer permite algo a ese grupo, cualquiera puede hacer requests sin credenciales.

```bash
# Verificar la flag en el manifest estático
grep anonymous-auth /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
- --anonymous-auth=false
```

Si no aparece o está en `true`, se corrige editando el manifest (kubeadm reinicia automáticamente el static pod al detectar el cambio):

```yaml
spec:
  containers:
    - command:
        - kube-apiserver
        - --anonymous-auth=false
        ...
```

Prueba de verificación (sin certificados ni token, debe fallar):

```bash
curl -k https://<API_SERVER_IP>:6443/api/v1/namespaces
```

```
{
  "kind": "Status",
  "status": "Failure",
  "message": "Unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

### 3.2 Métodos de autenticación soportados

| Método | Uso típico | Notas de hardening |
|---|---|---|
| **X.509 client certificates** | admins, componentes del control plane (kube-scheduler, kube-controller-manager, kubelet) | Rotar certificados, usar CA dedicada, revisar `CN`/`O` (el `O` mapea a grupo RBAC) |
| **Service Account tokens** (JWT, `BoundServiceAccountTokenVolume`) | Pods que hablan con la API | Preferir tokens *bound* (con expiración y audiencia) sobre Secrets legacy de larga vida |
| **Static Token File** (`--token-auth-file`) | legado | **Deprecado**, evitar: tokens en texto plano sin expiración ni rotación |
| **Static Password File** (`--basic-auth-file`) | legado | **Eliminado en 1.19+**, nunca usar |
| **OIDC (OpenID Connect)** | SSO corporativo (Azure AD, Google, Okta) | Recomendado para usuarios humanos: MFA, expiración, revocación centralizada |
| **Webhook Token Authentication** | integración con sistemas externos de identidad | delega la validación del token a un servicio externo vía HTTPS |
| **Bootstrap tokens** | unir nodos al clúster (`kubeadm join`) | de un solo uso / corta duración, no reusar para auth de usuarios |

Flags relevantes en el manifest del apiserver:

```yaml
- --client-ca-file=/etc/kubernetes/pki/ca.crt
- --oidc-issuer-url=https://accounts.google.com
- --oidc-client-id=kubernetes
- --oidc-username-claim=email
- --oidc-groups-claim=groups
- --service-account-key-file=/etc/kubernetes/pki/sa.pub
- --service-account-issuer=https://kubernetes.default.svc
```

### 3.3 Certificados de usuario (X.509) — ejemplo end-to-end

```bash
# 1. Generar clave privada y CSR para un usuario "dev-jose"
openssl genrsa -out jose.key 2048
openssl req -new -key jose.key -out jose.csr -subj "/CN=dev-jose/O=developers"

# 2. Crear un CertificateSigningRequest en el clúster
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jose-csr
spec:
  request: $(cat jose.csr | base64 | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  usages:
    - client auth
EOF

# 3. Aprobar y extraer el certificado firmado
kubectl certificate approve jose-csr
kubectl get csr jose-csr -o jsonpath='{.status.certificate}' | base64 -d > jose.crt
```

```
certificatesigningrequest.certificates.k8s.io/jose-csr approved
```

El grupo `O=developers` del CSR se usa luego en un `RoleBinding`/`ClusterRoleBinding` (tema 3.2) para autorizar acciones — la autenticación por sí sola solo identifica, no otorga permisos.

## 4. Autorización (Authorization) — visión general

El flag `--authorization-mode` define la cadena de authorizers evaluados en orden. Configuración recomendada en producción:

```yaml
- --authorization-mode=Node,RBAC
```

| Modo | Función |
|---|---|
| `AlwaysAllow` | permite todo — **nunca usar en producción** |
| `AlwaysDeny` | niega todo — solo testing |
| `ABAC` | políticas basadas en atributos en archivo estático — legado, difícil de auditar |
| `Node` | autoriza requests de kubelets solo sobre objetos relacionados a su propio nodo (Pods asignados, Services, etc.) |
| `RBAC` | Role-Based Access Control — mecanismo estándar actual (detalle en tema 3.2) |
| `Webhook` | delega la decisión a un servicio HTTP externo |

Verificar el modo activo:

```bash
kubectl exec -n kube-system kube-apiserver-controlplane -- kube-apiserver --help 2>/dev/null | grep authorization-mode
# o directamente en el manifest:
grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
- --authorization-mode=Node,RBAC
```

Si aparece `AlwaysAllow` en cualquier posición de la lista, es un hallazgo crítico de hardening.

## 5. Restringir el acceso desde herramientas cliente

### 5.1 `kubectl proxy` y `kubectl port-forward`

`kubectl proxy` expone la API localmente **sin volver a pedir autenticación** (usa las credenciales del kubeconfig activo). Si se corre con `--address=0.0.0.0 --accept-hosts='.*'` en un host mal configurado, cualquiera en la red puede acceder a la API con los privilegios del usuario que lanzó el proxy.

```bash
# Mal: expone la API completa sin restricciones de origen
kubectl proxy --address=0.0.0.0 --accept-hosts='.*'

# Bien: solo localhost (default)
kubectl proxy
```

### 5.2 kubeconfig — minimizar exposición de credenciales

- No commitear kubeconfigs con certs/tokens de admin en repos.
- Usar contexts separados por rol/clúster (`kubectl config use-context`).
- Preferir `exec` plugins (OIDC, cloud IAM) sobre certificados de larga vida embebidos en el kubeconfig.

```bash
kubectl config view --minify -o jsonpath='{.users[0].user}'
```

## 6. Auditoría rápida con `kubectl auth can-i`

Aunque la decisión de autorización final es RBAC (tema 3.2), verificar el efecto de la restricción de acceso a la API es parte de este tema:

```bash
# ¿Puede el usuario anónimo listar pods?
kubectl auth can-i list pods --as=system:anonymous

# ¿Puede system:unauthenticated hacer algo en todo el clúster?
kubectl auth can-i '*' '*' --as-group=system:unauthenticated -A
```

```
no
no
```

Si alguna de estas respuestas es `yes`, hay una brecha de acceso anónimo que corregir (bindings a `system:anonymous` o `system:unauthenticated` deben auditarse y, salvo el caso legítimo de `system:discovery`/health checks, eliminarse):

```bash
kubectl get clusterrolebindings -o json \
  | jq '.items[] | select(.subjects[]?.name=="system:anonymous" or .subjects[]?.name=="system:unauthenticated") | .metadata.name'
```

## 7. Buenas prácticas resumidas (checklist de hardening)

- [ ] `--anonymous-auth=false` en el apiserver.
- [ ] `--authorization-mode=Node,RBAC` (sin `AlwaysAllow`).
- [ ] Sin flags de puerto inseguro (`--insecure-port`, eliminadas desde 1.20 pero verificar en clusters legacy).
- [ ] Firewall/security groups restringen 6443 a IPs necesarias; API server privado si el proveedor lo soporta.
- [ ] Métodos de auth legacy (`basic-auth-file`, `token-auth-file`) deshabilitados.
- [ ] OIDC/certificados con expiración y rotación para usuarios humanos.
- [ ] `kubectl proxy` nunca expuesto a `0.0.0.0` sin `--accept-hosts` restringido.
- [ ] Sin `ClusterRoleBinding` que otorgue permisos amplios a `system:anonymous` / `system:unauthenticated`.
- [ ] Certificados de componentes del control plane (`etcd`, `kube-scheduler`, `kube-controller-manager`) firmados por CA dedicada y con TLS mutuo hacia el apiserver.

## Referencias

- CNCF, *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs — Controlling Access to the Kubernetes API: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes docs — Authenticating: https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes docs — Authorization Overview: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes docs — Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes docs — Node Authorization: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes docs — Webhook Token Authentication: https://kubernetes.io/docs/reference/access-authn-authz/webhook/
- Kubernetes docs — kube-apiserver reference (flags): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes docs — Managing Service Accounts / BoundServiceAccountTokenVolume: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes docs — Certificate Signing Requests: https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Kubernetes docs — kubectl proxy: https://kubernetes.io/docs/tasks/access-application-cluster/access-cluster/#using-kubectl-proxy