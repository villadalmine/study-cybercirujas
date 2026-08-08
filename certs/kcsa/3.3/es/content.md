# Tema 3.3: Authentication

> **KCSA — Domain 3: Kubernetes Cluster Component Security**
> Peso en el examen: **3.14** · Idioma de estudio: ES (términos técnicos en EN)

---

## 1. Motivación y el problema arquitectónico de producción

Toda petición que modifica el estado de un cluster de Kubernetes —crear un `Pod`, leer un `Secret`, escalar un `Deployment`— llega como una **request HTTP al `kube-apiserver`**. El API server es el único punto de entrada al `etcd` y, por diseño, el único componente que decide *quién sos*. Ese es el trabajo de la fase de **authentication (authN)**: convertir una request anónima en una **identidad verificada** (un `username`, un `UID`, un conjunto de `groups` y `extra` fields) que las fases posteriores puedan autorizar.

El pipeline de admisión de cada request es estrictamente secuencial:

```
                    ┌─────────────────────────────────────────────────────┐
   HTTPS request ──▶│  TLS termination (server cert)                       │
                    └───────────────┬─────────────────────────────────────┘
                                    ▼
                    ┌─────────────────────────────────────────────────────┐
                    │  1. AUTHENTICATION   ← estás acá                     │
                    │     ¿Quién sos? → userInfo{name, uid, groups, extra} │
                    │     Falla ⇒ 401 Unauthorized                        │
                    └───────────────┬─────────────────────────────────────┘
                                    ▼
                    ┌─────────────────────────────────────────────────────┐
                    │  2. AUTHORIZATION (RBAC/ABAC/Webhook/Node)          │
                    │     ¿Podés hacer esto? Falla ⇒ 403 Forbidden        │
                    └───────────────┬─────────────────────────────────────┘
                                    ▼
                    ┌─────────────────────────────────────────────────────┐
                    │  3. ADMISSION CONTROL (mutating + validating)        │
                    └─────────────────────────────────────────────────────┘
```

**El problema arquitectónico central es que Kubernetes no tiene un objeto `User`.** No existe un CRUD de usuarios humanos en `etcd`. El diseño (deliberado) delega la identidad de las **personas** a un sistema externo (una CA de X.509, un proveedor OIDC como Keycloak/Okta/Google/Dex, un LDAP detrás de un webhook) y sólo gestiona internamente las identidades de **carga de trabajo**: los `ServiceAccount`.

Esto parte el universo de identidades en dos, y confundirlos es la causa raíz de la mayoría de los incidentes de seguridad de authN en producción:

| Dimensión | Normal users (humanos) | Service Accounts (workloads) |
|---|---|---|
| ¿Es un objeto en `etcd`? | **No.** No hay `kind: User` | **Sí.** `kind: ServiceAccount`, namespaced |
| ¿Quién lo crea/gestiona? | Sistema externo (CA, IdP, LDAP) | El propio cluster (`kubectl create sa`) |
| Credencial típica | Certificado X.509 / OIDC ID token | JWT firmado por el API server |
| Prefijo de `username` | Arbitrario (`jane`, `jane@corp.io`) | `system:serviceaccount:<ns>:<name>` |
| Group automático | El que diga `O=` o el claim de groups | `system:serviceaccounts`, `system:serviceaccounts:<ns>` |
| Rotación / revocación | Responsabilidad del IdP externo | `TokenRequest` API, TTL corto |
| Caso de uso | `kubectl` de un SRE, CI humano | Pod que habla con el API, controllers |

**La consecuencia de producción:** un token de `ServiceAccount` filtrado *es* una credencial de cluster tan válida como la de un humano. Si además es un token **legacy** (larga duración, sin `exp`, sin `audience`), no expira nunca y no se puede revocar sin borrar el `Secret` y reiniciar los consumidores. Ese es exactamente el escenario que las **bound service account tokens** vinieron a cerrar.

### El API server es el único árbitro

Todo esto vive en flags del `kube-apiserver`. No hay authentication distribuida: cada authenticator es un módulo dentro del proceso del API server, y se ejecutan como una **cadena**.

```bash
$ ps -ef | grep kube-apiserver | tr ' ' '\n' | grep -E 'auth|client-ca|oidc|token|sa-'
--client-ca-file=/etc/kubernetes/pki/ca.crt
--enable-bootstrap-token-auth=true
--service-account-key-file=/etc/kubernetes/pki/sa.pub
--service-account-signing-key-file=/etc/kubernetes/pki/sa.key
--service-account-issuer=https://kubernetes.default.svc.cluster.local
--oidc-issuer-url=https://keycloak.corp.internal/realms/k8s
--oidc-client-id=kubernetes
--oidc-username-claim=email
--oidc-groups-claim=groups
--authorization-mode=Node,RBAC
```

**Regla de la cadena:** las requests se prueban contra cada authenticator habilitado. El **primero que tiene éxito gana** y su `userInfo` se usa; el resto no se evalúa. Si **todos** fallan (o no hay credencial), la request es **anónima** y recibe el `username` `system:anonymous` con el group `system:unauthenticated` —o un `401` si el authenticator explícitamente rechaza la credencial presentada.

---

## 2. Estrategias de authentication: comparativa técnica y trade-offs

Kubernetes soporta múltiples **authenticator plugins**. Estos son los que importan en producción y en el examen KCSA:

| Estrategia | Tipo de credencial | Expira | Revocable individualmente | Externo requerido | Uso recomendado |
|---|---|---|---|---|---|
| **X.509 client certs** | Certificado firmado por la cluster CA | Sí (`notAfter`) | **No** (sin CRL/OCSP) | No (una CA) | Bootstrap, componentes del control plane, break-glass |
| **Static token file** | Token en CSV plano en disco | **No** | No (editar archivo + restart) | No | ❌ Prohibido en prod (deprecado de facto) |
| **Bootstrap tokens** | Token `[a-z0-9]{6}.[a-z0-9]{16}` | Sí (TTL) | Sí (borrar Secret) | No | Sólo `kubeadm join` |
| **ServiceAccount tokens (legacy)** | JWT sin `exp`/`aud` en un Secret | **No** | Sólo borrando el Secret | No | ❌ Evitar; legado |
| **Bound SA tokens** | JWT proyectado, con `aud`+`exp`+bindings | **Sí** (TTL corto) | Sí (kill pod / TokenRequest) | No | ✅ Default de workloads |
| **OIDC** | ID token (JWT) de un IdP | Sí | Sí (en el IdP) | Sí (IdP + refresh) | ✅ **Humanos** en prod |
| **Webhook token** | Token opaco validado por `TokenReview` remoto | Depende del webhook | Depende del webhook | Sí (servicio) | Integración con IAM cloud, LDAP |
| **Authenticating proxy** | Headers `X-Remote-User/Group` de un proxy TLS | N/A | En el proxy | Sí (reverse proxy) | SSO empresarial pre-existente |

### 2.1 X.509 client certificates — la trampa de la no-revocación

Un certificado cliente firmado por la CA cuyo `ca.crt` está en `--client-ca-file` es aceptado. Kubernetes mapea:

- **`CN` (Common Name)** → `username`
- **`O` (Organization)**, uno por cada valor → `groups`

```
Subject: CN=jane, O=platform-team, O=oncall
        │        │              │
        │        │              └──▶ group: oncall
        │        └─────────────────▶ group: platform-team
        └──────────────────────────▶ username: jane
```

**El trade-off crítico:** X.509 no tiene revocación en Kubernetes. **El API server ignora las CRLs y no consulta OCSP.** Un certificado válido lo es hasta su `notAfter`. Si el laptop de `jane` con un cert `cluster-admin` a 1 año se pierde en la semana 1, tus únicas opciones son:

1. Esperar 51 semanas a que expire (inaceptable).
2. Rotar la **CA entera** del cluster (reemitir *todos* los certs, catastrófico).
3. Neutralizarlo en la capa de **authorization** con RBAC deny — pero eso es un parche, no una revocación.

Por eso los certs X.509 se reservan para **credenciales de emergencia (break-glass) de vida corta** y para la comunicación entre componentes, **no** para el acceso rutinario de humanos.

### 2.2 ServiceAccount tokens: legacy vs. bound

Este es el eje técnico más examinado del tema.

| Propiedad | Legacy SA token (≤1.23 default) | Bound SA token (Projected, GA 1.22) |
|---|---|---|
| Origen | Auto-creado en un `Secret` tipo `kubernetes.io/service-account-token` | Emitido on-demand por la **TokenRequest API** |
| Almacenado en `etcd`? | **Sí** (en el Secret, legible por quien tenga `get secrets`) | **No** persistido; vive en un `emptyDir`/tmpfs del pod |
| Claim `exp` (expiración) | **Ausente** → token eterno | Presente, TTL configurable (default 1h, mín 10min) |
| Claim `aud` (audience) | **Ausente** → válido para cualquier verificador | Explícito → sólo válido para el `audience` pedido |
| Binding a Pod/Secret | No (válido aunque el pod ya no exista) | Sí (`kubernetes.io/pod`, `.../serviceaccount` con UID) |
| Rotación | Manual | Automática por el kubelet antes de `exp` |
| Invalidación | Borrar el Secret | El token muere con el pod; deja de rotar |

Desde **Kubernetes 1.24** (`LegacyServiceAccountTokenNoAutoGeneration`), crear un `ServiceAccount` **ya no genera automáticamente un Secret con token**. El default del ecosistema es el **projected token** montado por el admission controller. Los tokens legacy sólo existen si los pedís explícitamente, y desde 1.29–1.31 hay controllers que **limpian y avisan** de tokens legacy sin usar.

**Anatomía de un bound token (JWT decodificado):**

```json
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1754621400,
  "iat": 1754617800,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "b1e2c3d4-...",
  "kubernetes.io": {
    "namespace": "payments",
    "pod":            { "name": "checkout-7c9f-abcde", "uid": "9d1c-..." },
    "serviceaccount": { "name": "checkout-sa",         "uid": "44af-..." }
  },
  "nbf": 1754617800,
  "sub": "system:serviceaccount:payments:checkout-sa"
}
```

El `sub` es el `username` (`system:serviceaccount:<ns>:<name>`); los bindings en `kubernetes.io` hacen que el token deje de ser válido si el pod se borra (el UID no coincide). El API server verifica la firma con la **clave pública** de `--service-account-key-file`.

### 2.3 OIDC — el mecanismo correcto para humanos

Con OIDC, los humanos se autentican contra un IdP (Keycloak, Dex, Okta, Azure AD, Google) y presentan un **ID token** (JWT). El API server **no** habla con el IdP en cada request: valida la firma del JWT contra las claves públicas del `jwks_uri` del issuer (que descubre vía `/.well-known/openid-configuration`), y mapea claims a `username`/`groups`.

Ventaja sobre X.509: **revocación real** (revocás en el IdP, los tokens tienen `exp` corto), **MFA**, **SSO**, y ninguna credencial de larga vida en el laptop. El `kubectl` usa un `refresh_token` para renovar el ID token sin re-login.

Desde **Kubernetes 1.30 (beta)**, la **Structured Authentication Configuration** reemplaza los flags `--oidc-*` sueltos por un archivo declarativo que soporta **múltiples issuers** y **expresiones CEL** para validar y mapear claims (ver §3.4).

---

## 3. Manifiestos e infraestructura completos

### 3.1 Crear una identidad humana con X.509 (break-glass)

Flujo completo con la **CertificateSigningRequest API**, sin tocar la CA a mano:

```bash
# 1) Generar clave privada y CSR con CN=username, O=group
$ openssl genrsa -out jane.key 4096
$ openssl req -new -key jane.key -out jane.csr \
    -subj "/CN=jane/O=platform-team"
```

```yaml
# 2) csr.yaml — enviar la CSR al cluster para que la firme la cluster CA
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jane-csr
spec:
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0t...   # base64 de jane.csr
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400          # 24h — credencial corta, break-glass
  usages:
    - client auth
```

```bash
$ cat jane.csr | base64 | tr -d '\n'   # pegar el resultado en spec.request
$ kubectl apply -f csr.yaml
certificatesigningrequest.certificates.k8s.io/jane-csr created

$ kubectl certificate approve jane-csr
certificatesigningrequest.certificates.k8s.io/jane-csr approved

$ kubectl get csr jane-csr -o jsonpath='{.status.certificate}' \
    | base64 -d > jane.crt
```

```yaml
# 3) Darle permisos (authN sin authZ no sirve de nada)
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-view
  namespace: payments
subjects:
  - kind: User            # ← NO existe objeto User; se referencia por nombre
    name: jane            # ← debe coincidir con el CN del certificado
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

### 3.2 Projected (bound) ServiceAccount token — el patrón de workload

El `ServiceAccountAdmission` monta esto automáticamente, pero conviene entender el `volumeProjection` explícito, porque es como pedís un token con un **audience** distinto (p. ej. para Vault o para un servicio externo):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-sa
  namespace: payments
automountServiceAccountToken: false   # apagá el automount por defecto...
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: payments
spec:
  replicas: 2
  selector: { matchLabels: { app: checkout } }
  template:
    metadata:
      labels: { app: checkout }
    spec:
      serviceAccountName: checkout-sa
      automountServiceAccountToken: false
      containers:
        - name: app
          image: registry.corp.internal/checkout:1.9.2
          volumeMounts:
            - name: kube-api-token
              mountPath: /var/run/secrets/tokens
              readOnly: true
      volumes:
        - name: kube-api-token          # ...y proyectá uno explícito y acotado
          projected:
            sources:
              - serviceAccountToken:
                  path: token
                  audience: vault.corp.internal   # token SÓLO válido para Vault
                  expirationSeconds: 3600          # TTL 1h; el kubelet rota solo
```

**Por qué importa:** el token del `mountPath` estándar (`.../serviceaccount/token`) tiene `aud: [kube-apiserver]`. Si tu app lo reenvía a un servicio externo, ese servicio **no debe** aceptarlo como propio. Pedir un token con `audience: vault.corp.internal` produce un JWT que Vault valida contra el JWKS del cluster y que **no sirve** para hablar con el API server — aislamiento por audience.

### 3.3 Pedir un token a mano con la TokenRequest API

```bash
# Emitir un bound token de 10 minutos para checkout-sa, audience por defecto
$ kubectl create token checkout-sa -n payments --duration=10m
eyJhbGciOiJSUzI1NiIsImtpZCI6Il9...   # JWT

# Con audience explícito (para un verificador externo)
$ kubectl create token checkout-sa -n payments \
    --audience vault.corp.internal --duration=15m
eyJhbGciOiJSUzI1NiIsImtpZCI6Il9...

# Vía API cruda (lo que hace kubectl por debajo)
$ kubectl create -f - -o jsonpath='{.status.token}' <<'EOF'
apiVersion: authentication.k8s.io/v1
kind: TokenRequest
metadata:
  name: checkout-sa
  namespace: payments
spec:
  audiences: ["https://kubernetes.default.svc.cluster.local"]
  expirationSeconds: 600
EOF
```

### 3.4 OIDC vía Structured Authentication Configuration (1.30+ beta)

Archivo pasado al API server con `--authentication-config=/etc/kubernetes/auth/auth-config.yaml`. Reemplaza los flags `--oidc-*` y soporta CEL:

```yaml
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: https://keycloak.corp.internal/realms/k8s
      audiences: ["kubernetes"]
      audienceMatchPolicy: MatchAny
    claimMappings:
      username:
        # prefijo namespaced: evita colisiones con SA y con otros IdP
        claim: email
        prefix: "oidc:"
      groups:
        claim: groups
        prefix: "oidc:"
      uid:
        claim: sub
    claimValidationRules:
      # rechazar tokens de cuentas no verificadas usando CEL
      - expression: 'claims.email_verified == true'
        message: "el email del usuario no está verificado en el IdP"
    userValidationRules:
      - expression: "!user.username.startsWith('system:')"
        message: "los usernames no pueden suplantar identidades del sistema"
```

Flags equivalentes (estilo clásico, aún soportado) para un cluster `kubeadm`:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml  (static pod, extracto)
    - --oidc-issuer-url=https://keycloak.corp.internal/realms/k8s
    - --oidc-client-id=kubernetes
    - --oidc-username-claim=email
    - --oidc-username-prefix=oidc:
    - --oidc-groups-claim=groups
    - --oidc-groups-prefix=oidc:
    - --oidc-ca-file=/etc/kubernetes/pki/keycloak-ca.crt
```

Config del cliente `kubectl` con OIDC (usa el plugin de auth incorporado):

```yaml
# ~/.kube/config (extracto)
users:
  - name: jane-oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://keycloak.corp.internal/realms/k8s
          - --oidc-client-id=kubernetes
          - --oidc-client-secret=REDACTED
```

### 3.5 Webhook token authentication (integración con IAM externo)

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml (flags)
    - --authentication-token-webhook-config-file=/etc/kubernetes/webhook/kubeconfig.yaml
    - --authentication-token-webhook-cache-ttl=2m
```

```yaml
# /etc/kubernetes/webhook/kubeconfig.yaml — a quién le preguntamos "¿este token es válido?"
apiVersion: v1
kind: Config
clusters:
  - name: token-authn
    cluster:
      certificate-authority: /etc/kubernetes/webhook/ca.crt
      server: https://authn.corp.internal/authenticate
users:
  - name: apiserver
    user:
      client-certificate: /etc/kubernetes/webhook/apiserver.crt
      client-key: /etc/kubernetes/webhook/apiserver.key
current-context: webhook
contexts:
  - name: webhook
    context: { cluster: token-authn, user: apiserver }
```

El API server hace un `POST` con un `TokenReview` y el servicio responde con `status.authenticated: true` y el `userInfo`. Ese es el mismo objeto que usás para diagnosticar (§5).

---

## 4. Comandos CLI y salidas reales

```bash
# ── ¿Quién soy YO, según el API server? (SelfSubjectReview, GA en 1.28) ──
$ kubectl auth whoami
ATTRIBUTE   VALUE
Username    oidc:jane@corp.io
Groups      [oidc:platform-team system:authenticated]

$ kubectl auth whoami -o yaml
apiVersion: authentication.k8s.io/v1
kind: SelfSubjectReview
status:
  userInfo:
    username: oidc:jane@corp.io
    groups:
      - oidc:platform-team
      - system:authenticated
```

```bash
# ── Verificar la identidad de un ServiceAccount token ──
$ TOKEN=$(kubectl create token checkout-sa -n payments)
$ kubectl auth whoami --token="$TOKEN"
ATTRIBUTE   VALUE
Username    system:serviceaccount:payments:checkout-sa
UID         44af0c9e-1b2c-4d5e-8f90-1a2b3c4d5e6f
Groups      [system:serviceaccounts system:serviceaccounts:payments system:authenticated]
```

```bash
# ── Decodificar el JWT de un pod para inspeccionar sus claims ──
$ kubectl exec -n payments checkout-7c9f-abcde -- \
    cat /var/run/secrets/kubernetes.io/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub,aud,exp,iss}'
{
  "sub": "system:serviceaccount:payments:checkout-sa",
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1754621400,
  "iss": "https://kubernetes.default.svc.cluster.local"
}
```

```bash
# ── Probar acceso ANÓNIMO: ¿el cluster deja pasar requests sin credencial? ──
$ curl -sk https://10.0.0.10:6443/api/v1/namespaces/kube-system/secrets \
    | jq '{kind,status,code,message}'
{
  "kind": "Status",
  "status": "Failure",
  "code": 403,
  "message": "secrets is forbidden: User \"system:anonymous\" cannot list resource \"secrets\" ..."
}
# 403 (no 401) confirma: authN anónima OCURRE (system:anonymous), authZ lo frena.
# Un 401 significaría que la request ni siquiera obtuvo identidad.
```

```bash
# ── kubeadm: rotación de certs de componentes (X.509 no se revoca, se rota) ──
$ kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Aug 07, 2027 12:00 UTC   364d            no
apiserver                  Aug 07, 2027 12:00 UTC   364d            no
apiserver-kubelet-client   Aug 07, 2027 12:00 UTC   364d            no
front-proxy-client         Aug 07, 2027 12:00 UTC   364d            no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Aug 05, 2035 12:00 UTC   9y              no
```

```bash
# ── Bootstrap tokens: los que usa 'kubeadm join', con TTL ──
$ kubeadm token create --ttl 1h --print-join-command
kubeadm join 10.0.0.10:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1a2b3c...

$ kubeadm token list
TOKEN                     TTL   EXPIRES                 USAGES                   DESCRIPTION
abcdef.0123456789abcdef   59m   2026-08-07T13:00:00Z    authentication,signing   ...
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Interpretar el código de estado — el primer diagnóstico

| Síntoma | Código | Significado real | Dónde mirar |
|---|---|---|---|
| `Unauthorized` | **401** | authN falló: credencial ausente, inválida, expirada o firma no verificable | Certificado/token, `--client-ca-file`, `exp`, reloj (clock skew) |
| `Forbidden` | **403** | authN OK, authZ falló: identidad válida sin permiso | RBAC (`RoleBinding`), nombre exacto del `User`/SA |
| `system:anonymous` en el 403 | 403 | La credencial no fue reconocida por *ningún* authenticator → cayó a anónimo | ¿El cert lo firmó la CA correcta? ¿El token está bien formado? |

**Heurística de oro:** `401` = problema de *authentication*; `403` = problema de *authorization*. Si ves `system:anonymous` donde esperabas a un usuario, la credencial nunca autenticó — no es un problema de RBAC.

### 5.2 Batería de diagnóstico

```bash
# ¿Mi kubeconfig apunta al cluster y usuario correctos?
$ kubectl config view --minify --flatten -o jsonpath='{.users[0].name}{"\n"}'

# ¿El certificado cliente está vigente y con el CN/O esperados?
$ openssl x509 -in jane.crt -noout -subject -dates
subject=CN=jane, O=platform-team
notBefore=Aug  7 12:00:00 2026 GMT
notAfter=Aug  8 12:00:00 2026 GMT       # ← ¿ya expiró? → 401

# ¿El API server confía en la CA que firmó este cert?
$ openssl verify -CAfile /etc/kubernetes/pki/ca.crt jane.crt
jane.crt: OK

# ¿Puedo hacer una acción concreta? (resuelve authN+authZ de un tiro)
$ kubectl auth can-i list secrets -n payments --as=oidc:jane@corp.io
no

# Impersonar para reproducir el problema de otro usuario (requiere permiso 'impersonate')
$ kubectl get pods -n payments --as=system:serviceaccount:payments:checkout-sa
```

### 5.3 Fallas típicas de producción y su causa raíz

**A. Token expirado / clock skew.** Un bound token con `exp` vencido devuelve `401`. Si un nodo tiene el reloj corrido >5 min respecto del API server, el claim `nbf`/`exp` se evalúa mal → `401` intermitente. Diagnóstico: comparar `date -u` entre nodo y control plane; verificar `chronyd/ntpd`.

**B. OIDC issuer no descubrible / JWKS inaccesible.** El API server loguea `oidc authenticator: initializing plugin ... error` si no alcanza el `/.well-known/openid-configuration`. Los ID tokens caen a anónimo. Diagnóstico:

```bash
$ curl -s https://keycloak.corp.internal/realms/k8s/.well-known/openid-configuration | jq .jwks_uri
$ kubectl -n kube-system logs kube-apiserver-cp01 | grep -i oidc
```

**C. `automountServiceAccountToken` no deseado.** Un pod que no necesita hablar con el API igual recibe un token montado; si es comprometido, el atacante tiene una credencial de cluster. Verificar y apagar:

```bash
$ kubectl get sa,deploy -A -o json | jq -r '
  .items[] | select(.spec.automountServiceAccountToken != false)
  | "\(.kind)/\(.metadata.namespace)/\(.metadata.name): automount ACTIVO"'
```

**D. Token legacy de larga vida en un Secret.** Buscar la deuda técnica de authN:

```bash
$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token
# Cada resultado es un token SIN exp/aud: revísalo, migra a projected, y bórralo.
```

**E. Firma no verificable en SA tokens.** Si rotaste la `sa.key`/`sa.pub` sin incluir la clave pública vieja en `--service-account-key-file`, todos los tokens en vuelo firmados con la clave anterior devuelven `401`. Regla: durante la rotación, el flag debe listar **ambas** claves públicas hasta que expiren los tokens viejos.

### 5.4 Auditoría de eventos de authentication

Con audit logging habilitado, cada request lleva su `user` resuelto. Para cazar accesos anónimos o de identidades inesperadas:

```bash
$ jq -r 'select(.user.username=="system:anonymous")
         | [.requestReceivedTimestamp, .verb, .requestURI] | @tsv' \
    /var/log/kubernetes/audit.log | head
2026-08-07T11:03:22Z   get    /api/v1/namespaces/kube-system/secrets
```

---

## 6. Referencias

- **Authenticating** (documentación oficial, estrategias y cadena de authenticators): https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- **Managing Service Accounts** y **bound service account tokens**: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- **Configure Service Accounts for Pods** (projected tokens, `automountServiceAccountToken`): https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- **TokenRequest / TokenReview API**: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-request-v1/
- **Certificate Signing Requests** (X.509 client certs, `signerName`): https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- **Structured Authentication Configuration** (multi-issuer OIDC + CEL, beta 1.30): https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration
- **`kubectl auth whoami` / SelfSubjectReview** (GA 1.28): https://kubernetes.io/docs/reference/access-authn-authz/authentication/#self-subject-review
- **Controlling Access to the Kubernetes API** (pipeline authN → authZ → admission): https://kubernetes.io/docs/concepts/security/controlling-access/
- **PKI certificates and requirements** (`kubeadm`, rotación de CA): https://kubernetes.io/docs/setup/best-practices/certificates/
- **KCSA Curriculum** (CNCF, dominio *Kubernetes Cluster Component Security*): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf