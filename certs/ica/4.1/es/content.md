# 4.1 Configurando la autorización

> Dominio 4 — Asegurando cargas de trabajo · Peso en el examen: 9
> Alcance: Istio `AuthorizationPolicy` (RBAC HTTP L7 y RBAC de red L4), su interacción con `PeerAuthentication` / `RequestAuthentication`, autorización externa `CUSTOM`, y aplicación tanto en el plano de datos sidecar como ambient.

---

## 1. El problema de producción: control de acceso consciente de la identidad dentro del mesh

En un cluster de Kubernetes, la primitiva clásica de control de acceso es la `NetworkPolicy`: filtra por selectores de pod/namespace y CIDRs de IP en L3/L4. Ese modelo se rompe por tres razones que importan en producción:

1. **Las IPs de los Pods son efímeras y no identifican.** Una `NetworkPolicy` que "permite el servicio `payments`" en realidad permite *cualquier pod que en ese momento tenga una etiqueta e IP coincidentes*. Un pod comprometido, una reutilización de IP, o una fuente falsificada la vencen. No hay prueba criptográfica de *quién* es el llamante.
2. **La política interesante está en L7.** "`checkout` puede llamar a `POST /charge` pero no a `DELETE /accounts/*`" no se puede expresar con reglas de IP/puerto. Necesitás conocimiento de método, path, host, header y claim de JWT.
3. **La aplicación debería ser local y distribuida.** Un punto central de decisión de políticas (PDP) que toda petición deba atravesar es un impuesto de latencia y un punto único de fallo.

Istio resuelve esto con **identidad de carga de trabajo + aplicación local**:

- Cada carga de trabajo recibe una **identidad SPIFFE** codificada en un SVID X.509, emitido por istiod y rotado automáticamente. La cadena de identidad es `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>` (p. ej. `spiffe://cluster.local/ns/foo/sa/sleep`). Este es el *principal*.
- **Mutual TLS** (vía `PeerAuthentication`) prueba esa identidad en cada conexión. Sin mTLS, el principal del peer está vacío y las reglas basadas en identidad no pueden coincidir.
- **La autorización la aplica el sidecar de Envoy (o ztunnel/waypoint en ambient), en el camino de entrada del destino**, usando el filtro RBAC de Envoy. istiod compila cada `AuthorizationPolicy` en configuración RBAC de Envoy y la envía vía xDS. **No hay un PDP central en el camino de la petición** — cada proxy decide localmente en microsegundos.

```
                         istiod (control plane)
                 compiles AuthorizationPolicy -> Envoy RBAC/ext_authz config
                                     │ xDS
        ┌────────────────────────────┼────────────────────────────┐
        ▼                                                           ▼
  ┌───────────┐   mTLS (SPIFFE SVID)          inbound RBAC   ┌───────────┐
  │  sleep    │ ────────────────────────────────────────▶   │  httpbin  │
  │  sidecar  │   principal:                                 │  sidecar  │  ── enforce ──▶ app
  └───────────┘   cluster.local/ns/foo/sa/sleep              └───────────┘   (allow/deny)
```

Esta es la postura de zero-trust que evalúa el examen ICA: **autenticar el peer (mTLS), autenticar al usuario final (JWT), luego autorizar la petición (AuthorizationPolicy) — lo más cerca posible de la carga de trabajo.**

---

## 2. El modelo de `AuthorizationPolicy`

### 2.1 Anatomía del CRD

```yaml
apiVersion: security.istio.io/v1        # v1beta1 still accepted, v1 is current
kind: AuthorizationPolicy
metadata:
  name: <name>
  namespace: <ns>                       # placement defines default scope (see 2.3)
spec:
  # WHERE it applies (pick at most one binding style):
  selector:                             # sidecar/ztunnel workloads, by label
    matchLabels:
      app: httpbin
  # targetRefs:                         # Gateway API / waypoint binding (ambient, gateways)
  #   - group: gateway.networking.k8s.io
  #     kind: Gateway
  #     name: my-waypoint

  action: ALLOW                         # ALLOW (default) | DENY | AUDIT | CUSTOM
  # provider:                           # required only for action: CUSTOM
  #   name: <extensionProvider-name>

  rules:                                # list; a request matches the policy if ANY rule matches
    - from:                             # SOURCE identity (matched with OR across list, AND within)
        - source:
            principals: ["cluster.local/ns/foo/sa/sleep"]   # mTLS peer identity (SPIFFE, no "spiffe://")
            requestPrincipals: ["<iss>/<sub>"]              # end-user identity from a validated JWT
            namespaces: ["foo"]                              # peer namespace (requires mTLS)
            ipBlocks: ["10.0.0.0/8"]                         # directly-connected source IP
            remoteIpBlocks: ["203.0.113.0/24"]               # original client IP from XFF (trusted proxies)
            # not* variants exist for every field above
      to:                               # OPERATION (L7)
        - operation:
            hosts: ["httpbin.foo.svc.cluster.local"]
            ports: ["8000"]
            methods: ["GET", "POST"]
            paths: ["/api/*", "/status/*"]
            # notHosts / notPorts / notMethods / notPaths
      when:                             # CONDITIONS on request attributes
        - key: request.auth.claims[groups]
          values: ["admin", "sre"]
        - key: request.headers[x-internal]
          values: ["true"]
```

**Semántica de coincidencia (memorizá esto):**

- Dentro de un mismo bloque `source`/`operation`/`when`, los campos se combinan con **AND**.
- Los valores dentro de la lista de un mismo campo se combinan con **OR**.
- Múltiples entradas `from`/`to`/`when` en una regla se combinan con **AND** entre categorías pero con **OR** dentro de la lista de una categoría.
- Múltiples `rules` se combinan con **OR**: la política coincide si *cualquier* regla coincide.
- Una **regla vacía `{}` coincide con toda petición**; un **`spec: {}` vacío tiene cero reglas y no coincide con nada.**

### 2.2 Acciones y el orden de evaluación

Istio evalúa las acciones en un **orden por capas fijo**, y la primera capa que llega a una decisión gana:

```
   request
     │
     ▼
 ┌─────────┐  deny         ┌────────┐ deny      ┌────────┐  no ALLOW policy exists?
 │ CUSTOM  │──────────────▶│  DENY  │──────────▶│ ALLOW  │───── yes ──▶ ALLOW (default open)
 │(ext_authz)│  allow ──┐  │        │  allow ──┐│        │      no  ──▶ match? yes→ALLOW / no→DENY
 └─────────┘          └───▶└────────┘        └──▶└────────┘
```

1. Las políticas **CUSTOM** se comprueban primero (delegadas a un autorizador externo). Un `deny` acá es final.
2. Las políticas **DENY** a continuación. Si alguna coincide → petición denegada.
3. Las políticas **ALLOW** al final. Si existen políticas ALLOW para la carga de trabajo y *ninguna* coincide → denegada. Si una coincide → permitida.
4. Si **ninguna** política **ALLOW/DENY/CUSTOM** aplica a la carga de trabajo → **permitida por defecto** (mesh abierto).

Los casos límite críticos, favoritos del examen:

| Intención | `spec` | Comportamiento |
|---|---|---|
| **Denegar todo** (baseline) | `spec: {}` (action por defecto ALLOW, 0 reglas) | Nada coincide con un ALLOW → **todas las peticiones denegadas** |
| deny-all explícito | `action: DENY`, `rules: [{}]` | Regla vacía coincide con todo → **todo denegado** |
| allow-all | `action: ALLOW`, `rules: [{}]` | Regla vacía coincide con todo → **todo permitido** |
| Requerir JWT válido (cualquier usuario) | `action: ALLOW`, `from.source.requestPrincipals: ["*"]` | Solo pasan las peticiones que portan un token validado |

> **Trampa:** colocar `spec: {}` en el namespace raíz (`istio-system`) crea un **deny-all a nivel de todo el mesh**. Este es el baseline de zero-trust recomendado, pero aplicado sin cuidado hará un black-hole de todo el mesh, incluyendo probes y caminos de telemetría que atraviesan el proxy.

### 2.3 Alcance (precedencia por ubicación)

| Ubicación | `selector`/`targetRefs`? | Alcance |
|---|---|---|
| Namespace raíz (`istio-system`) | ninguno | **Todo el mesh** |
| Namespace raíz | presente | Cargas de trabajo seleccionadas en todo el mesh |
| Namespace de la carga de trabajo | ninguno | **Todas las cargas de trabajo en ese namespace** |
| Namespace de la carga de trabajo | `selector` presente | **Solo las cargas de trabajo coincidentes** |

DENY y ALLOW en distintos alcances se componen según §2.2 (DENY sigue ganando sobre ALLOW sin importar el alcance).

### 2.4 Tablas de compromisos

**Acciones**

| Acción | Precedencia | Aplicación | Uso típico | Modo de fallo a vigilar |
|---|---|---|---|---|
| `ALLOW` | 3ra | RBAC local | Poner en allowlist un conjunto de llamantes/operaciones | La presencia de *cualquier* ALLOW hace que la carga de trabajo sea deny-by-default para ese alcance — un allowlist incompleto bloquea tráfico válido |
| `DENY` | 2da | RBAC local | Blocklist (p. ej. bloquear `DELETE`) | Los campos negativos (`notPaths`) invierten la lógica y es fácil escribirlos de forma insegura |
| `AUDIT` | canal lateral | Marca la petición para auditoría; **sin efecto de allow/deny** | Probar en seco una regla antes de aplicarla | Requiere un proveedor con capacidad de auditoría; de lo contrario es silenciosamente inerte |
| `CUSTOM` | 1ra | Delega en un servicio ext_authz | OPA, oauth2-proxy, OIDC, PDP corporativo | Agrega un salto de red y una decisión `failOpen`/`failClosed` en el sidecar |

**Capa de aplicación**

| Dimensión | RBAC de red L4 (`envoy.filters.network.rbac`) | RBAC HTTP L7 (`envoy.filters.http.rbac`) |
|---|---|---|
| Campos soportados | principals, namespaces, ipBlocks, ports, SNI | + methods, paths, hosts, headers, claims de JWT, `request.auth.*` |
| Requiere detección de protocolo | No (TCP/mTLS) | Sí (HTTP/HTTPS con parsing L7) |
| Modo sidecar | ✅ | ✅ |
| Ambient — **ztunnel** | ✅ (solo L4) | ❌ |
| Ambient — **waypoint** | ✅ | ✅ (waypoint requerido para reglas L7) |

**Fuente de identidad en `from.source`**

| Campo | Origen | Prerrequisito | Frontera de confianza |
|---|---|---|---|
| `principals` | SVID del peer mTLS (SPIFFE) | `PeerAuthentication` STRICT/PERMISSIVE con mTLS presente | Fuerte (criptográfica) |
| `namespaces` | SVID del peer mTLS | mTLS | Fuerte |
| `requestPrincipals` | JWT validado (`<iss>/<sub>`) | `RequestAuthentication` presente | Fuerte (token firmado) |
| `ipBlocks` | IP de origen del paquete L3 | ninguno | Débil (falsificable; en un gateway es la IP del LB/nodo) |
| `remoteIpBlocks` | IP original del cliente desde `X-Forwarded-For` | Gateway configurado con `numTrustedProxies`/`externalTrafficPolicy: Local` | Tan fuerte como tu cadena de proxies |

**Dónde encaja la autz de Istio frente a sus vecinos**

| Control | Capa | Identidad | Granularidad |
|---|---|---|---|
| Kubernetes `NetworkPolicy` | L3/L4 | Etiquetas de Pod / IP | Namespace/pod, puerto |
| Istio `AuthorizationPolicy` (L4) | L4 | Identidad SPIFFE del peer | Service account, namespace, puerto |
| Istio `AuthorizationPolicy` (L7) | L7 | Peer + usuario final (JWT) | Método, path, host, claim |
| API-gateway/ext_authz (`CUSTOM`) | L7 | Delegada | Arbitraria (política OPA, sesión) |

Usalos juntos (defensa en profundidad): `NetworkPolicy` como una valla gruesa en L3, Istio L4 para identidad, Istio L7 para reglas a nivel de operación, `CUSTOM` cuando necesitás lógica de negocio que el CRD no puede expresar.

---

## 3. Manifiestos completos

Los ejemplos apuntan a un namespace `foo` que ejecuta los samples estándar `httpbin` (servidor) y `sleep` (cliente), con mTLS STRICT a nivel de todo el mesh. Todos los manifiestos están completos y son sintácticamente válidos.

### 3.1 Prerrequisito de mTLS y baseline de zero-trust

```yaml
# 00-peer-strict.yaml — require mTLS everywhere (principals depend on this)
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system          # root namespace => mesh-wide
spec:
  mtls:
    mode: STRICT
---
# 01-deny-all.yaml — mesh-wide default-deny (zero trust baseline)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: istio-system
spec: {}                            # 0 rules => nothing satisfies ALLOW => deny everything
```

### 3.2 ALLOW de mínimo privilegio (identidad del peer + operación + condición)

```yaml
# 02-allow-sleep-get.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow-sleep
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/foo/sa/sleep"]   # only the sleep SA
      to:
        - operation:
            methods: ["GET"]
            paths: ["/get", "/status/*"]
      when:
        - key: request.headers[x-tier]
          values: ["internal"]
```

### 3.3 DENY (poner en blocklist una operación peligrosa)

```yaml
# 03-deny-mutations.yaml — nobody may mutate, regardless of ALLOW policies
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-deny-mutations
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: DENY
  rules:
    - to:
        - operation:
            methods: ["DELETE", "PUT", "PATCH"]
```

DENY gana sobre cualquier ALLOW, así que esto es una barrera de protección absoluta.

### 3.4 Autenticación + autorización del usuario final (JWT)

`RequestAuthentication` solo *valida* tokens — una petición **sin** token igual la pasa. Debés agregar un `AuthorizationPolicy` que requiera `requestPrincipals` para efectivamente **exigir** un token.

```yaml
# 04-jwt.yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-on-httpbin
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  jwtRules:
    - issuer: "https://accounts.example.com"
      jwksUri: "https://accounts.example.com/.well-known/jwks.json"
      audiences:
        - "httpbin.foo.svc.cluster.local"
      forwardOriginalToken: true
      fromHeaders:
        - name: Authorization
          prefix: "Bearer "
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-require-jwt
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["https://accounts.example.com/*"]  # <iss>/<sub>; * = any subject
      when:
        - key: request.auth.claims[groups]
          values: ["sre"]                                          # claim-based RBAC
```

> **El error clásico:** desplegar solo el `RequestAuthentication` y esperar que bloquee tráfico anónimo. No lo hace. Las peticiones anónimas (sin header `Authorization`) *no son rechazadas* por `RequestAuthentication`; solo lo son las peticiones con un token **inválido** (401). El `AuthorizationPolicy` de arriba cierra esa brecha.

### 3.5 `CUSTOM` — delegar en un autorizador externo (OPA / oauth2-proxy)

Primero registrá el proveedor ext_authz en la configuración del mesh (`istiod` lee `extensionProviders`):

```yaml
# 05-meshconfig-extauthz.yaml (IstioOperator overlay)
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    extensionProviders:
      - name: "opa-ext-authz-grpc"
        envoyExtAuthzGrpc:
          service: "opa.opa-system.svc.cluster.local"
          port: 9191
          timeout: 0.5s
          failOpen: false                # fail CLOSED: deny if OPA is unreachable
      - name: "oauth2-proxy"
        envoyExtAuthzHttp:
          service: "oauth2-proxy.auth.svc.cluster.local"
          port: 4180
          includeRequestHeadersInCheck: ["authorization", "cookie"]
          headersToUpstreamOnAllow: ["authorization", "x-auth-request-user"]
          headersToDownstreamOnDeny: ["set-cookie", "content-type"]
```

Luego referencialo desde una política `CUSTOM` (evaluada *primero*, antes de DENY/ALLOW):

```yaml
# 06-custom-authz.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-ext-authz
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: CUSTOM
  provider:
    name: "opa-ext-authz-grpc"          # must match an extensionProviders entry
  rules:
    - to:
        - operation:
            paths: ["/admin/*"]         # only send /admin/* to OPA; rest handled by ALLOW/DENY
```

`failOpen: false` es el valor por defecto seguro para producción — un autorizador inalcanzable **no** debe autorizar silenciosamente `/admin/*`.

### 3.6 `AUDIT` — probar en seco una regla antes de aplicarla

```yaml
# 07-audit.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-audit-deletes
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: AUDIT
  rules:
    - to:
        - operation:
            methods: ["DELETE"]
```

`AUDIT` marca las peticiones coincidentes para auditoría (reglas RBAC "shadow" de Envoy) pero nunca permite ni deniega. **Solo produce salida cuando hay un proveedor de logging con capacidad de auditoría configurado en tu plataforma** — de lo contrario es inerte. Usalo para medir el radio de impacto antes de cambiar una regla a `DENY`.

### 3.7 Allowlisting por IP de origen en el ingress gateway

`ipBlocks` en un gateway coincide con la IP *conectada directamente* (normalmente el LB/nodo), no con el cliente real. Para coincidir con el cliente verdadero necesitás `remoteIpBlocks` **y** una configuración de proxy de confianza para que Envoy confíe en `X-Forwarded-For`:

```yaml
# 08-gateway-topology.yaml (tell Envoy how many proxies to trust for XFF)
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    defaultConfig:
      gatewayTopology:
        numTrustedProxies: 1            # e.g. one external LB in front of the gateway
---
# 09-ingress-ip-allowlist.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ingress-ip-allowlist
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks: ["203.0.113.0/24"]   # real client CIDR
```

### 3.8 Endurecimiento: aplicar normalización de paths

Las reglas de path L7 pueden evadirse con trucos de codificación de path (`/admin/../foo`, dobles barras, `%2f`) si Envoy y tu aplicación normalizan de forma distinta. Habilitá la normalización a nivel de todo el mesh:

```yaml
# 10-path-normalization.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    pathNormalization:
      normalization: MERGE_SLASHES     # NONE | BASE | MERGE_SLASHES | DECODE_AND_MERGE_SLASHES
```

---

## 4. Comandos CLI y salida real de terminal

### 4.1 Aplicar y verificar el baseline

```console
$ kubectl apply -f 00-peer-strict.yaml -f 01-deny-all.yaml
peerauthentication.security.istio.io/default created
authorizationpolicy.security.istio.io/deny-all created

$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.foo:8000/get
403

$ kubectl -n foo exec deploy/sleep -c sleep -- curl -sS http://httpbin.foo:8000/get
RBAC: access denied
```

El cuerpo literal `RBAC: access denied` con HTTP **403** es la firma del RBAC L7. (En L4, una conexión TCP denegada simplemente se resetea — `curl: (56) Recv failure: Connection reset by peer`.)

### 4.2 Otorgar mínimo privilegio, volver a probar

```console
$ kubectl apply -f 02-allow-sleep-get.yaml
authorizationpolicy.security.istio.io/httpbin-allow-sleep created

# missing the required header -> still denied
$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.foo:8000/get
403

# with the header the ALLOW rule matches -> 200
$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" -H "x-tier: internal" http://httpbin.foo:8000/get
200

# a POST is not in the allowlist -> denied
$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" -X POST -H "x-tier: internal" http://httpbin.foo:8000/post
403
```

### 4.3 Inspeccionar la configuración RBAC compilada en el proxy

El listener de entrada en un sidecar es el inbound virtual `0.0.0.0:15006`; el filtro RBAC L7 vive dentro de su cadena de filtros HTTP y sus políticas se nombran `ns[<ns>]-policy[<name>]-rule[<index>]`:

```console
$ POD=$(kubectl -n foo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')

$ istioctl proxy-config listener "$POD.foo" --port 15006 -o json \
    | jq -r '.. | objects
             | select(.name? == "envoy.filters.http.rbac")
             | .typed_config.rules.policies | keys[]'
ns[foo]-policy[httpbin-allow-sleep]-rule[0]
```

Resumen de más alto nivel de cada política de autz asociada a una carga de trabajo (las columnas varían levemente según la versión de `istioctl`):

```console
$ istioctl experimental authz check "$POD.foo"
ACTION   AuthorizationPolicy                            RULES
ALLOW    ns[foo]-policy[httpbin-allow-sleep]-rule[0]    1
DENY     ns[foo]-policy[httpbin-deny-mutations]-rule[0] 1
```

### 4.4 Confirmar mTLS y la política efectiva para un pod

```console
$ istioctl experimental describe pod "$POD.foo"
Pod: httpbin-7b7c4d5f8-abcde.foo
   Pod Revision: default
--------------------
Service: httpbin.foo
   Port: http 8000/HTTP targets pod port 80
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
--------------------
RBAC policies: ns[foo]-policy[httpbin-allow-sleep]-rule[0], ns[foo]-policy[httpbin-deny-mutations]-rule[0]
```

`Workload mTLS mode: STRICT` confirma que las reglas `principals`/`namespaces` son aplicables; si dijera `DISABLE`, cada regla basada en identidad nunca coincidiría silenciosamente.

### 4.5 Activar el logging de debug de RBAC para ver *por qué* se tomó una decisión

```console
$ istioctl proxy-config log "$POD.foo" --level rbac:debug
active loggers:
  rbac: debug

$ kubectl -n foo logs "$POD" -c istio-proxy --tail=50 | grep -i rbac
2026-08-08T12:03:41.882Z  debug  envoy rbac  checking request:
    requestedServerName: outbound_.8000_._.httpbin.foo.svc.cluster.local,
    sourceIP: 10.244.0.31:41922, directRemoteIP: 10.244.0.31:41922,
    ssl.uriSanPeerCertificate: spiffe://cluster.local/ns/foo/sa/sleep,
    headers: ':method','POST'  ':path','/post'
2026-08-08T12:03:41.882Z  debug  envoy rbac  enforced denied,
    matched policy ns[foo]-policy[httpbin-deny-mutations]-rule[0]
```

El log nombra la *regla exacta* que decidió la petición y muestra la identidad SPIFFE del peer que presentó mTLS — este es el diagnóstico de producción más útil para autz.

### 4.6 Validación estática antes del despliegue

```console
$ istioctl analyze -n foo
✔ No validation issues found when analyzing namespace: foo.
```

`istioctl analyze` avisará, por ejemplo, cuando una política referencia `requestPrincipals` pero no hay ningún `RequestAuthentication` asociado a la carga de trabajo (el campo silenciosamente no tendría efecto), o cuando un `selector` no coincide con ningún pod.

---

## 5. Guía de verificación y diagnóstico de fallos

### 5.1 Árbol de decisión para "403 inesperado / RBAC: access denied"

```
403 "RBAC: access denied"
 ├─ Is there a DENY policy matching this request?
 │     istioctl x authz check <pod>  → look for a matching DENY rule
 │     kubectl logs -c istio-proxy | grep rbac → "enforced denied, matched policy ..."
 │        └─ yes → that DENY (or the mesh/ns deny-all) is intended precedence; DENY beats ALLOW.
 ├─ Is there an ALLOW policy on the workload but none matching?
 │     Remember: presence of ANY ALLOW makes the scope default-deny.
 │        └─ widen/complete the allowlist (method? path? header? principal?).
 ├─ Is the caller's identity what you think?
 │     Debug log ssl.uriSanPeerCertificate == spiffe://.../sa/<expected>?
 │        └─ empty → mTLS not established → principals/namespaces cannot match.
 │           Check PeerAuthentication (STRICT?) and that BOTH ends are meshed.
 └─ CUSTOM provider path? failOpen:false + unreachable ext_authz → deny.
       Check the ext_authz service endpoints and the sidecar's ext_authz debug log.
```

### 5.2 Diagnóstico para "permitido inesperadamente"

```
Request that should be blocked succeeds (200)
 ├─ No ALLOW/DENY policy on the workload → default OPEN. Add a deny-all baseline.
 ├─ Policy has L7 fields but traffic is plain TCP / port not app-protocol-detected
 │     → L7 rules require HTTP; declare the port protocol (name it http-*/use appProtocol).
 ├─ Ambient mode: L7 rule with no waypoint → ztunnel enforces L4 only, L7 silently ignored.
 │     → attach a waypoint and bind the policy via targetRefs.
 ├─ Path bypass (/admin/../x, //admin, %2f) → enable meshConfig.pathNormalization.
 └─ requestPrincipals rule but only RequestAuthentication deployed → anonymous requests pass
       (RequestAuthentication does not reject missing tokens). Require requestPrincipals: ["*"].
```

### 5.3 Modos de fallo comunes

| Síntoma | Causa raíz | Solución |
|---|---|---|
| Todo da 403 tras la primera política ALLOW | Cualquier ALLOW hace que el alcance sea default-deny | Completá el allowlist o acotá la política con `selector` |
| `principals`/`namespaces` nunca coinciden | mTLS no establecido → identidad del peer vacía | `PeerAuthentication` STRICT; asegurá que ambos extremos estén en el mesh |
| El tráfico anónimo igual llega a la app | `RequestAuthentication` por sí solo no exige un token | Agregá un ALLOW con `requestPrincipals: ["*"]` |
| `ipBlocks` en el gateway coincide con la IP del LB, no del cliente | La fuente L3 es el último salto | Usá `remoteIpBlocks` + `numTrustedProxies` / `externalTrafficPolicy: Local` |
| Reglas L7 ignoradas (paths/methods) | Tráfico TCP, o ambient sin waypoint | Poné el protocolo del puerto en HTTP; asociá un waypoint |
| Allowlist de paths evadido | Normalización de path divergente | `meshConfig.pathNormalization: MERGE_SLASHES` (o más estricta) |
| La política `CUSTOM` autoriza durante una caída | `failOpen: true` en el proveedor | Poné `failOpen: false` para paths sensibles |
| `AUDIT` no produce nada | Ningún proveedor de auditoría configurado | Conectá un proveedor de logging con capacidad de auditoría, o usalo solo como marcador de prueba en seco |
| DENY con `notPaths` bloquea de más/de menos | La coincidencia negativa invierte la intención | Preferí la coincidencia positiva; probá con `AUDIT` primero |

### 5.4 Checklist de verificación antes de declarar una política como "aplicando"

1. `istioctl analyze` está limpio para el namespace.
2. `istioctl x describe pod` muestra el `Workload mTLS mode` esperado y la política bajo `RBAC policies:`.
3. `istioctl proxy-config listener … | jq …` muestra las claves de política compiladas `envoy.filters.http.rbac` (o `network.rbac`).
4. Un `curl` **positivo** y uno **negativo** desde un cliente de identidad conocida devuelven ambos los códigos esperados (200 / 403).
5. Con `rbac:debug`, la línea de log de deny/allow nombra la regla exacta que pretendías.
6. Para JWT, probá tres casos: **sin token → 403**, **token inválido → 401**, **token válido con claim incorrecto → 403**, **token válido con claim correcto → 200**.

---

## 6. Referencias

- Istio — Conceptos de autorización: https://istio.io/latest/docs/concepts/security/#authorization
- Istio — Referencia de `AuthorizationPolicy` (campos, acciones, coincidencia): https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Condiciones de política de autorización (claves `when` soportadas): https://istio.io/latest/docs/reference/config/security/conditions/
- Istio — Tareas de autorización (HTTP/TCP, deny-all, patrones de allow): https://istio.io/latest/docs/tasks/security/authorization/
- Istio — Autorización con JWT: https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/
- Istio — Autorización personalizada (externa): https://istio.io/latest/docs/tasks/security/authorization/authz-custom/
- Istio — Referencia de `RequestAuthentication`: https://istio.io/latest/docs/reference/config/security/request_authentication/
- Istio — Referencia de `PeerAuthentication` (prerrequisito de mTLS): https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — Buenas prácticas de seguridad (normalización de paths, coincidencia positiva, deny-all): https://istio.io/latest/docs/ops/best-practices/security/
- Istio — Autorización L4/L7 en ambient y waypoints: https://istio.io/latest/docs/ambient/usage/l7-features/
- Envoy — Filtro RBAC HTTP: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter
- Envoy — Filtro de autorización externa (`ext_authz`): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter
- SPIFFE — Modelo de identidad (principals de carga de trabajo): https://spiffe.io/docs/latest/spiffe-about/overview/
- CNCF — Currículum de Istio Certified Associate (ICA): https://github.com/cncf/curriculum