# 4.2 Configuring Authentication (mTLS, JWT)

## 1. El problema de producción: identidad en una malla zero-trust

En un despliegue clásico de tres capas, la "seguridad" era en gran medida una cuestión de perímetro: un firewall o un load balancer terminaba TLS en el borde, y todo lo que había detrás era red L3/L4 confiable. Ese modelo se derrumba en Kubernetes por tres razones estructurales:

1. **Las IPs de los Pods son efímeras y se reutilizan.** Una regla de `iptables`/`NetworkPolicy` que confía en `10.244.3.17` confía en *cualquier pod que tenga esa IP en este momento*. Después de un rollout, esa IP puede pertenecer a una carga de trabajo distinta, posiblemente de un tenant distinto. La IP no es identidad.
2. **El tráfico este-oeste empequeñece al tráfico norte-sur.** La abrumadora mayoría de las conexiones son de servicio a servicio, dentro del clúster, donde tradicionalmente *no* había autenticación en absoluto. Un único pod comprometido podía hablar en texto plano con todos los demás servicios.
3. **La red no es el límite de confianza.** En clústeres multi-tenant, nodos compartidos y mallas multi-clúster, se asume explícitamente que la capa subyacente es hostil. Esa es la premisa **zero-trust**: autenticar y autorizar *cada* salto, criptográficamente, sobre la base de la *identidad de la carga de trabajo*, no de la ubicación en la red.

Istio responde a esto trasladando la autenticación al plano de datos del sidecar (Envoy) y dándole a cada carga de trabajo una **identidad criptográfica** que es:

- **Independiente de la IP, el nodo y la topología de namespaces.**
- **Anclada en el ServiceAccount de Kubernetes**, de modo que se corresponde con el RBAC que ya administrás.
- **Codificada como una identidad SPIFFE** en un SAN X.509, de modo que es portable entre clústeres e interoperable con el ecosistema SPIFFE más amplio.

Istio divide el "quién está llamando" en dos preguntas ortogonales, y esta división es el modelo mental más importante de este tema:

| Pregunta | Término de Istio | Recurso | Transporte | Objeto de identidad |
|---|---|---|---|---|
| ¿Qué **workload** abrió esta conexión? | Peer authentication | `PeerAuthentication` | mutual TLS (X.509) | SPIFFE ID (`source.principals`) |
| ¿Qué **usuario final / llamante** está detrás de esta solicitud? | Request authentication | `RequestAuthentication` | JWT (bearer token) | `<issuer>/<subject>` (`source.requestPrincipals`) |

Son **aditivas, no alternativas**. Una solicitud del pod `checkout` que porta el JWT de un usuario tiene *ambas*: una identidad de peer (el pod) y una identidad de request (el usuario). Las políticas de producción rutinariamente afirman ambas: "el tráfico debe provenir de una carga de trabajo en el namespace `payments` **y** portar un token válido de Auth0 con audiencia `api.internal`".

> **Distinción crítica que tanto el examen como la producción castigan:** ni `PeerAuthentication` ni `RequestAuthentication` *autorizan* nada. Establecen y *validan* identidad. **La aplicación (enforcement) es siempre trabajo de `AuthorizationPolicy`.** Un `RequestAuthentication` sin un `AuthorizationPolicy` que lo acompañe dejará pasar alegremente solicitudes que no portan *ningún token* — solo rechaza tokens que están *presentes y son inválidos*. Las secciones 4 y 5 lo hacen concreto.

---

## 2. La ruta de datos de la autenticación

### 2.1 Identidad de la carga de trabajo: SPIFFE + la CA de Istio

Toda identidad de carga de trabajo es un **SPIFFE ID** con la forma:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

Para un pod que corre bajo el ServiceAccount `bookinfo-productpage` en el namespace `default` con el trust domain por defecto `cluster.local`:

```
spiffe://cluster.local/ns/default/sa/bookinfo-productpage
```

Esta cadena se incrusta como un **URI Subject Alternative Name (SAN)** en el certificado hoja X.509 de la carga de trabajo. *No* es el Common Name — Istio deliberadamente pone la identidad en el SAN para que sobreviva a la validación TLS moderna (la identidad basada en CN está deprecada en el ecosistema).

`istiod` incrusta una Certificate Authority. Por defecto usa una **raíz autofirmada** generada en el primer arranque (almacenada en el `istio-ca-secret` en `istio-system`). En producción casi siempre reemplazás esto por una CA anclada en tu PKI aportando `cacerts` (ver §7.4).

### 2.2 Aprovisionamiento y rotación de certificados (el flujo SDS)

Entender este flujo es lo que separa "apliqué un PeerAuthentication" de "puedo depurar por qué un pod no hace mTLS". El `istio-agent` (a.k.a. `pilot-agent`) corre dentro de cada contenedor sidecar e intermedia los certificados:

```
        pod: reviews-v3
 ┌───────────────────────────────────────────────┐
 │  ┌───────────┐        ┌────────────────────┐   │
 │  │  Envoy    │◀──SDS──│  istio-agent       │   │        ┌──────────────┐
 │  │ (data     │  UDS   │  (pilot-agent)     │──gRPC/mTLS─▶│   istiod     │
 │  │  plane)   │        │                    │  CSR + SA  │   (Istio CA) │
 │  └───────────┘        └────────────────────┘  JWT       └──────────────┘
 │        ▲                        │                              │
 │        │ key + cert chain       │  1. generate key + CSR       │
 │        └── over Unix socket ◀───┘  2. attach SA JWT token      │
 │            (never touches disk,    3. istiod → TokenReview ────┘
 │             never leaves the pod)  4. istiod signs, returns cert
 └───────────────────────────────────────────────┘
```

Paso a paso:

1. `istio-agent` genera una **clave privada en memoria** y un CSR. La clave privada **nunca sale del pod y nunca se escribe a disco**.
2. Se autentica ante el endpoint gRPC de la CA de `istiod` usando el **token proyectado del ServiceAccount** del pod.
3. `istiod` llama a la API **`TokenReview`** de Kubernetes para probar que el token es genuino y está vinculado a ese SA/pod.
4. `istiod` firma un certificado hoja con el SAN SPIFFE y devuelve la cadena.
5. `istio-agent` empuja la clave+cert a Envoy sobre la API **SDS** en un Unix domain socket (`./etc/istio/proxy/SDS`). Los certs viven solo en la memoria de Envoy.
6. El agente **rota proactivamente** el certificado. La vida útil por defecto del cert de la carga de trabajo es de **24h** (`WorkloadCertTTL`), y el agente lo refresca aproximadamente a la mitad de su vida, de modo que una hoja comprometida tiene un radio de impacto corto. La rotación es sin cortes — Envoy hace hot-swap del secreto sin caídas de conexión.

Por esto una carga de trabajo puede perder mTLS incluso con un `PeerAuthentication` perfecto: si la proyección del token de SA está rota, `istiod` es inalcanzable, o el desfase de reloj invalida el token, el bucle del CSR falla y Envoy nunca recibe un cert.

---

## 3. Peer authentication (mTLS)

### 3.1 Los cuatro modos y dónde aplican

`PeerAuthentication` establece la expectativa del **lado servidor**: qué *aceptará* el sidecar receptor.

| Modo | El servidor acepta | El servidor rechaza | Uso típico |
|---|---|---|---|
| `UNSET` | hereda el alcance padre | — | por defecto; dejar que una política más amplia decida |
| `PERMISSIVE` | mTLS **y** texto plano | nada | **migración** — default de la malla para que clientes legacy/fuera de la malla no se rompan |
| `STRICT` | solo mTLS | todo el texto plano | objetivo de **producción en estado estable** |
| `DISABLE` | solo texto plano | mTLS | excepciones puntuales: un puerto scrapeado por infra fuera de la malla, o una app que ya hace su propio TLS |

**Precedencia de alcance — gana el más estrecho:**

```
workload-level (has selector)  >  namespace-level (no selector, in that ns)  >  mesh-level (no selector, in root ns)
```

- **A nivel malla**: un `PeerAuthentication` *sin* `selector`, aplicado en el **root namespace** (`istio-system` por defecto, fijado por `meshConfig.rootNamespace`).
- **A nivel namespace**: sin `selector`, aplicado *en el namespace objetivo*.
- **Específico de la carga de trabajo**: tiene un `selector.matchLabels`; también puede fijar `portLevelMtls` para overrides por puerto.

Las claves de `portLevelMtls` son el **`targetPort` del contenedor de la carga de trabajo** (el puerto donde Envoy realmente escucha), *no* el puerto del Service de Kubernetes. Equivocarse aquí es una falla silenciosa clásica.

### 3.2 Lado cliente: modos TLS de `DestinationRule`

`PeerAuthentication` gobierna al *receptor*. El comportamiento del *emisor* lo gobierna un `DestinationRule` `trafficPolicy.tls.mode`. Cuando dependés del auto-mTLS (el default desde Istio 1.5), Istio lo infiere por vos: si el destino anuncia mTLS, el sidecar cliente origina mTLS automáticamente. Lo sobreescribís explícitamente cuando lo necesitás.

| `DestinationRule` `tls.mode` | Comportamiento del cliente | Cuándo |
|---|---|---|
| *(unset / auto-mTLS)* | mTLS si el servidor lo ofrece, si no texto plano | por defecto; dejar que Istio negocie |
| `ISTIO_MUTUAL` | mTLS usando certs **emitidos por Istio** (identidad SPIFFE) | forzar mTLS de malla hacia un servidor `STRICT` |
| `MUTUAL` | mTLS con **tu propio** cert/clave de cliente aportados | malla → servicio externo que exige certs de cliente |
| `SIMPLE` | TLS de una vía (el cliente valida al servidor, sin cert de cliente) | malla → endpoint HTTPS externo |
| `DISABLE` | texto plano | hablando con un puerto `DISABLE` |

> **La caída de mTLS #1 en el terreno:** un `PeerAuthentication: STRICT` en el servidor **combinado con** un `DestinationRule: tls.mode: DISABLE` obsoleto (a menudo remanente de una configuración manual de TLS) en el lado cliente. El cliente envía texto plano, el servidor STRICT resetea la conexión, y obtenés `503 UC`/`upstream connect error or disconnect/reset before headers` *sin causa obvia*. La §7.2 muestra cómo detectarlo.

### 3.3 Manifiestos

**(a) STRICT a nivel malla** — el estado final de producción, aplicado en el root namespace:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default            # conventional name for the mesh-wide policy
  namespace: istio-system  # must equal meshConfig.rootNamespace
spec:
  mtls:
    mode: STRICT
```

**(b) El patrón de migración seguro** — malla PERMISSIVE, ajustar un namespace a STRICT una vez que verificaste que no tiene llamantes en texto plano:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE        # whole mesh stays lenient during rollout
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: payments-strict
  namespace: payments       # only this namespace enforces
spec:
  mtls:
    mode: STRICT
```

**(c) Override a nivel carga de trabajo + puerto** — STRICT para la carga de trabajo, pero exponer un puerto de scrape de Prometheus en texto plano porque el scraper está fuera de la malla:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: reviews-mtls
  namespace: default
spec:
  selector:
    matchLabels:
      app: reviews          # only pods with this label
  mtls:
    mode: STRICT
  portLevelMtls:
    9090:                   # container targetPort, NOT the Service port
      mode: DISABLE         # /metrics scraped by non-mesh Prometheus
```

**(d) `DestinationRule` del lado cliente** — forzar mTLS de Istio hacia un host (cinturón y tiradores junto con un servidor STRICT, y requerido si además definís subsets):

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-istio-mtls
  namespace: default
spec:
  host: reviews.default.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

---

## 4. Request authentication (JWT)

`RequestAuthentication` le dice al sidecar **cómo validar un JWT**: dónde encontrarlo, qué emisor lo firmó, y dónde obtener las claves de firma (JWKS).

### 4.1 El manifiesto y cada campo que importa

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth0
  namespace: default
spec:
  selector:
    matchLabels:
      app: productpage
  jwtRules:
    - issuer: "https://your-tenant.eu.auth0.com/"      # MUST equal the token's `iss` claim, byte-for-byte
      audiences:                                        # if set, token `aud` must contain one of these
        - "https://api.internal.example.com"
      jwksUri: "https://your-tenant.eu.auth0.com/.well-known/jwks.json"
      # forwardOriginalToken: keep the Authorization header for upstream services
      forwardOriginalToken: true
      # fromHeaders / fromParams: override where the token is read from.
      # Default is `Authorization: Bearer <token>`. Example for a custom header:
      fromHeaders:
        - name: x-jwt-assertion
          prefix: "Bearer "
      # outputClaimToHeaders: surface a claim to upstream apps as a header
      outputClaimToHeaders:
        - header: x-jwt-email
          claim: email
```

Semántica clave con la que la gente tropieza:

- **`issuer` se compara exactamente** contra el claim `iss` — un desajuste de barra final (`auth0.com` vs `auth0.com/`) es la causa más común de "token válido, igual 401".
- **`jwksUri` vs `jwks` inline.** `jwksUri` permite que `istiod` obtenga y cachee el conjunto de claves (y lo refresque en la rotación); usá `jwks` inline solo para validación air-gapped/offline. El **agente obtiene el JWKS, no Envoy** — si `istiod` (o el agente) no puede alcanzar la URL del JWKS en tiempo de configuración, la validación de esa regla falla abierta/cerrada según la versión, así que *el egreso de red hacia el IdP importa*.
- **`audiences` es opcional pero casi siempre debería fijarse** — sin él, cualquier token correctamente firmado por ese emisor se acepta, sin importar para quién fue acuñado (un riesgo de confused-deputy entre microservicios que comparten un IdP).

### 4.2 La trampa: validación no es enforcement

Aplicá *solo* el `RequestAuthentication` de arriba y probá:

```console
$ curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/api/v1/products
200
```

**Una solicitud sin token devuelve 200.** `RequestAuthentication` rechaza un token *malo* pero nunca *exige* uno. Para exigir un token debés agregar un `AuthorizationPolicy`:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: default
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["*"]   # "*" = ANY authenticated principal → a valid JWT is now mandatory
```

Ahora:

```console
$ curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/api/v1/products
403                                    # RBAC: access denied — no principal

$ curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $BAD" http://productpage:9080/api/v1/products
401                                    # Jwt verification fails — token present but invalid

$ curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $GOOD" http://productpage:9080/api/v1/products
200
```

Notá los **dos códigos de estado diferentes**, que son una señal de diagnóstico precisa:
- **`401`** viene del filtro JWT — había un token presente y falló la validación (firma incorrecta, emisor incorrecto, expirado, audiencia incorrecta).
- **`403`** viene del filtro de RBAC/autorización — a la solicitud le faltaba un principal requerido (ningún token en absoluto, o token válido pero la política lo denegó).

---

## 5. Componiendo identidad de peer + request en una sola política

La política de producción real afirma *ambos* planos. El `requestPrincipals` para una identidad JWT es `"<issuer>/<subject>"`. Abajo: solo las cargas de trabajo del namespace `frontend` (identidad de peer/mTLS) **y** que porten un token de Auth0 para un subject específico (identidad de request/JWT) pueden hacer `POST` a `/api/v1/orders`.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: orders-write
  namespace: payments
spec:
  selector:
    matchLabels:
      app: orders
  action: ALLOW
  rules:
    - from:
        - source:
            principals:            # PEER identity (from mTLS cert SAN)
              - "cluster.local/ns/frontend/sa/checkout"
            requestPrincipals:     # REQUEST identity (from JWT iss/sub)
              - "https://your-tenant.eu.auth0.com/*"
      to:
        - operation:
            methods: ["POST"]
            paths: ["/api/v1/orders"]
      when:
        - key: request.auth.claims[scope]
          values: ["orders:write"]     # claim-based fine-grained authz
```

Dos sutilezas:
- `principals` (peer) **requieren que mTLS** esté establecido; si el namespace no es STRICT y el llamante envía texto plano, `principals` está vacío y esta regla nunca puede coincidir — la solicitud se deniega. Por lo tanto, la authz de identidad de peer *presupone* mTLS.
- El bloque `when` alcanza claims JWT validados (`request.auth.claims[...]`), que solo existen porque el `RequestAuthentication` los validó y los pobló.

**DENY vence a ALLOW.** Si cualquier `AuthorizationPolicy` con `action: DENY` coincide, la solicitud se deniega sin importar las reglas ALLOW. Y en el momento en que *cualquier* política ALLOW selecciona una carga de trabajo, esa carga de trabajo pasa a **default-deny** para todo lo que no esté explícitamente permitido. Este orden (CUSTOM → DENY → ALLOW, default-deny una vez que existe un ALLOW) es el modelo de evaluación que debés internalizar.

---

## 6. Verificación por CLI y terminal

### 6.1 Confirmar que el sidecar efectivamente tiene certs emitidos por Istio

```console
$ istioctl proxy-config secret productpage-v1-6b746f74dc-8xk2p
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           2f8a...c41                           2026-08-09T14:22:11Z     2026-08-08T14:20:11Z
ROOTCA            CA             ACTIVE     true           1b03...9de                           2036-08-05T09:11:44Z     2026-08-05T09:11:44Z
```

- `default` es la **hoja de la carga de trabajo** (notá la ventana de validez de ~24h — ese es el TTL de rotación).
- `ROOTCA` es el ancla de confianza que Envoy usa para verificar a los peers.
- `VALID CERT: true` en `default` significa que SDS entregó un cert vivo; `false`/ausente significa que el bucle del CSR está roto (ver §7).

### 6.2 Leer la identidad SPIFFE del certificado hoja en vivo

```console
$ istioctl proxy-config secret productpage-v1-6b746f74dc-8xk2p -o json \
  | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d \
  | openssl x509 -noout -text \
  | grep -A1 "Subject Alternative Name"
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/default/sa/bookinfo-productpage
```

Ese URI SAN **es** la identidad de la carga de trabajo contra la que se coteja cada cláusula `principals:`. Es la comprobación de verdad de terreno cuando una regla de autorización "debería coincidir pero no lo hace".

### 6.3 Describir la postura de seguridad de malla efectiva de un pod

```console
$ istioctl x describe pod productpage-v1-6b746f74dc-8xk2p
Pod: productpage-v1-6b746f74dc-8xk2p
   Pod Revision: default
   Pod Ports: 9080 (productpage), 15090 (istio-proxy)
--------------------
Service: productpage
   Port: http 9080/HTTP targets pod port 9080
DestinationRule: reviews-istio-mtls for "reviews.default.svc.cluster.local"
   Traffic Policy TLS Mode: ISTIO_MUTUAL
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied PeerAuthentication:
   default.istio-system

RequestAuthentication jwt-auth0/default selects this pod
   Issuer: https://your-tenant.eu.auth0.com/

Checked 1 RBAC policies (AuthorizationPolicy require-jwt/default) for this pod.
```

Este único comando responde "¿es este pod STRICT, qué emisor JWT aplica, y qué políticas de authz lo controlan?" — el triaje más rápido para un incidente de autenticación.

### 6.4 Análisis estático de configuración antes de desplegar

```console
$ istioctl analyze -n default
Info [IST0102] (Namespace default) The namespace is not enabled for Istio injection...
Warning [IST0128] (PeerAuthentication reviews-mtls.default) PeerAuthentication defines port-level
   mTLS for port 9090 but the workload selector matches no ports named or numbered 9090.
Error: Analyzers found issues when analyzing namespace: default.
```

`istioctl analyze` detecta el desajuste a nivel puerto de la §3.1 **antes** de que se convierta en un 503.

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Probar que mTLS realmente está en el cable (no solo configurado)

La config dice STRICT; verificá que los *bytes* estén cifrados. Observá los logs de acceso de Envoy del sidecar servidor buscando el SPIFFE ID del peer:

```console
$ kubectl logs deploy/reviews -c istio-proxy | tail -1 | jq '{code:.response_code, mtls:.connection_termination_details, peer:.downstream_peer_uri_san}'
{
  "code": 200,
  "mtls": null,
  "peer": "spiffe://cluster.local/ns/default/sa/bookinfo-productpage"
}
```

Un `downstream_peer_uri_san` poblado = la conexión fue mTLS y el cliente presentó un cert verificado. Vacío en un puerto STRICT = algo está mal, y la solicitud habría sido reseteada.

### 7.2 Diagnosticar el reset de "STRICT + cliente en texto plano"

Síntoma: `503 upstream connect error or disconnect/reset before headers. reset reason: connection termination`.

```console
# 1. Is the destination STRICT?
$ istioctl x describe pod $(kubectl get pod -l app=reviews -o name | head -1 | cut -d/ -f2) | grep "mTLS mode"
   Workload mTLS mode: STRICT

# 2. Is a stale DestinationRule forcing the CLIENT to plaintext?
$ kubectl get destinationrule -A -o json \
  | jq -r '.items[] | select(.spec.host|test("reviews")) | "\(.metadata.namespace)/\(.metadata.name): \(.spec.trafficPolicy.tls.mode)"'
default/legacy-reviews: DISABLE          # ← the culprit: client sends plaintext to a STRICT server
```

Solución: eliminá/parcheá la regla `DISABLE`, o fijala a `ISTIO_MUTUAL`. Reprobá con la §7.1.

### 7.3 Diagnosticar fallas de JWT

El filtro JWT de Envoy es escueto con los clientes (`401 Jwt verification fails`) pero verboso en los logs de debug:

```console
$ istioctl proxy-config log deploy/productpage --level "jwt:debug,rbac:debug"
$ kubectl logs deploy/productpage -c istio-proxy | grep -iE "jwt|rbac" | tail -3
[jwt_authn] Jwt issuer https://wrong-issuer/ is not configured
[jwt_authn] verification completed with: Jwt issuer is not configured
[rbac] enforced denied, matched policy none
```

Tabla de decisión:

| El cliente ve | Pista del log de Envoy | Causa raíz | Solución |
|---|---|---|---|
| `401 Jwt issuer is not configured` | `issuer ... is not configured` | token `iss` ≠ `jwtRules.issuer` (a menudo una `/` final) | alinear `issuer` exactamente al claim `iss` |
| `401 Jwt verification fails` | `Jwt verification fails: expired` | token expirado / desfase de reloj | revisar `nbf`/`exp`, NTP del nodo |
| `401 Audiences ... not allowed` | `audiences ... not in ...` | claim `aud` ∉ `audiences` | agregar la audiencia o corregir la app del IdP |
| `401` intermitente | `Jwks remote fetch is failed` | el agente no puede alcanzar `jwksUri` | abrir egreso al IdP; revisar el `RequestAuthentication` por una URL de JWKS obsoleta |
| `403 RBAC: access denied` | `rbac ... matched policy none` | token válido/ausente pero la authz deniega | corregir `requestPrincipals` / `principals` en el `AuthorizationPolicy` |

Decodificá el token que realmente estás enviando — la mitad de los tickets de JWT son el token equivocado:

```console
$ echo "$GOOD" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, aud, exp, sub, scope}'
{
  "iss": "https://your-tenant.eu.auth0.com/",
  "aud": "https://api.internal.example.com",
  "exp": 1786312931,
  "sub": "auth0|6a3f...",
  "scope": "orders:write profile"
}
```

### 7.4 Health checks y mTLS STRICT

Bajo STRICT, las solicitudes HTTP de `livenessProbe`/`readinessProbe` del kubelet se originan *fuera de la malla* (el kubelet no tiene cert de Istio) y serían reseteadas. El perfil por defecto de Istio resuelve esto **reescribiendo las probes HTTP de la app** para que el kubelet golpee el puerto `15021` en el sidecar, que hace de proxy hacia la app. Verificá que esté activo:

```console
$ kubectl get pod productpage-v1-6b746f74dc-8xk2p -o jsonpath='{.metadata.annotations.sidecar\.istio\.io/rewriteAppHTTPProbers}'
true
```

Si las probes fallan *solo después* de activar STRICT, esta reescritura está deshabilitada (o usás probes `exec`/`gRPC`, o una probe `tcpSocket` cruda contra un puerto de la app). Reactivá `rewriteAppHTTPProbers`, o exponé el puerto de la probe vía `portLevelMtls: DISABLE`.

### 7.5 Conectar tu propia CA (endurecimiento de producción)

Nunca lleves la raíz autofirmada de istiod a producción. Aprovisioná un intermedio firmado por tu raíz empresarial y cargalo *antes* de instalar Istio:

```console
$ kubectl create secret generic cacerts -n istio-system \
    --from-file=ca-cert.pem \
    --from-file=ca-key.pem \
    --from-file=root-cert.pem \
    --from-file=cert-chain.pem
secret/cacerts created

# istiod picks it up automatically; confirm workloads now chain to YOUR root:
$ istioctl proxy-config secret deploy/productpage -o json \
  | jq -r '.dynamicActiveSecrets[] | select(.name=="ROOTCA").secret.trustedCa.inlineBytes' \
  | base64 -d | openssl x509 -noout -issuer
issuer=O = Example Corp, CN = Example Corp Root CA
```

---

## 8. References

- Istio — Mutual TLS / Authentication (concepts): https://istio.io/latest/docs/concepts/security/#authentication
- Istio — `PeerAuthentication` API reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — `RequestAuthentication` API reference: https://istio.io/latest/docs/reference/config/security/request_authentication/
- Istio — `AuthorizationPolicy` API reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Mutual TLS Migration task: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — Authentication Policy task (mTLS modes): https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Istio — End-user (JWT) authentication task: https://istio.io/latest/docs/tasks/security/authentication/jwt-route/
- Istio — Plug in CA Certificates: https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/
- Istio — Istio Certificate Management / SDS: https://istio.io/latest/docs/tasks/security/cert-management/
- Istio — `DestinationRule` TLS settings (`ClientTLSSettings`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Istio — Security best practices: https://istio.io/latest/docs/ops/best-practices/security/
- SPIFFE — ID and X.509-SVID specifications: https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
- CNCF — ICA (Istio Certified Associate) curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf