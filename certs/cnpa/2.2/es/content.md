# Tema 2.2 — Secure Service-to-Service Communication

> CNPA · Dominio 2 (Cloud Native Security & Observability) · Peso 4.0
> Perfil: Platform Architect / SRE Senior · Nivel producción

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El modelo de perímetro se rompe adentro del cluster

El diseño de red clásico asume un perímetro: un firewall en el borde, TLS de cara al usuario en el ingress, y **confianza implícita** para todo lo que ya está "dentro". En un cluster de Kubernetes ese modelo colapsa por tres motivos estructurales:

1. **La red del cluster es plana por defecto.** El modelo de red de Kubernetes exige que *todo pod pueda hablar con todo pod sin NAT* (documentado en el propio modelo de red). Sin políticas, un pod comprometido en `namespace: marketing` puede abrir un socket a la base de datos de `namespace: payments`.
2. **El tráfico east-west domina.** En una arquitectura de microservicios, por cada request north-south (usuario → ingress) hay decenas de saltos service-to-service internos. Ese tráfico históricamente viajaba **en texto plano** (`http://orders.payments.svc.cluster.local:8080`), porque "está dentro del cluster".
3. **La identidad se degrada a la topología.** Cuando la autorización se basa en IP de origen, la identidad del servicio queda atada a un `endpoint` efímero. Los pods se reprograman, las IPs se reciclan en segundos, y un `NetworkPolicy` basado sólo en CIDR se vuelve una mentira: la IP `10.244.3.12` es hoy el `frontend` y en 40 segundos es un `cronjob` cualquiera.

### 1.2 El objetivo: Zero Trust para tráfico east-west

El principio operativo (NIST SP 800-207) es **"never trust, always verify"**: ninguna red es confiable, la posición topológica no otorga permisos, y cada conexión se autentica y autoriza según la **identidad criptográfica del workload**, no su dirección IP.

Esto se descompone en tres capacidades independientes que un Platform Architect debe proveer como plataforma, no como esfuerzo por equipo:

| Capacidad | Pregunta que responde | Mecanismo canónico |
|---|---|---|
| **Workload Identity** | ¿Quién es este servicio, criptográficamente? | SPIFFE ID + SVID (X.509/JWT) |
| **Encryption in transit** | ¿Alguien puede leer/modificar el tráfico? | mTLS (mutual TLS) |
| **AuthN + AuthZ L7** | ¿Este servicio puede llamar a *ese endpoint*? | AuthorizationPolicy / RBAC de mesh |

El error clásico es tratar esto como "poné un service mesh". El service mesh es *una* implementación; la decisión arquitectónica real es **dónde vive el plano de identidad y a qué costo operativo**.

### 1.3 El caso de fallo que justifica el peso 4.0

Escenario de producción real: un service `analytics` con una dependencia vulnerable (SSRF) permite a un atacante hacer que el pod emita requests arbitrarios. En una red plana sin identidad:

```
analytics (comprometido)  ──HTTP──▶  payments-db:5432   ✗ debería ser imposible
                          ──HTTP──▶  vault:8200         ✗ debería ser imposible
```

Con **default-deny + mTLS + AuthorizationPolicy**, el mismo SSRF falla en el handshake: `analytics` no posee un certificado que lo autorice a hablar con `payments-db`, y la política L7 sólo admite el spiffe ID de `billing`. La superficie de movimiento lateral se reduce de "todo el cluster" a "los peers explícitamente permitidos".

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Dónde terminar el mTLS: sidecar vs ambient vs eBPF vs library

Es la decisión de mayor impacto. Cada modelo mueve el punto de terminación de TLS a un lugar distinto de la pila.

| Dimensión | Sidecar proxy (Istio classic, Linkerd) | Ambient / per-node (Istio ztunnel) | eBPF datapath (Cilium) | In-process library (gRPC + SPIRE) |
|---|---|---|---|---|
| Punto de terminación | Envoy/linkerd2-proxy **por pod** | ztunnel **por nodo** (L4) + waypoint (L7 opcional) | Kernel/eBPF por nodo | Dentro del proceso de la app |
| Overhead de memoria | ~50–150 MB × pod | ~1 proxy por nodo | Mínimo (kernel) | Nulo extra |
| Latencia añadida (p99) | +2 saltos de proxy | +1 salto L4 (o +2 con waypoint) | Casi nula | Nula |
| L7 (HTTP routing, retries) | Sí, completo | Sólo con waypoint | Limitado (L3/L4 fuerte, L7 vía Envoy) | Depende de la lib |
| Cambios en la app | Cero (inyección) | Cero | Cero | **Requiere reescribir la app** |
| Rotación de certs | Automática (mesh CA) | Automática | Automática (SPIFFE) | Manual/SDK |
| Blast radius de un bug del proxy | 1 pod | 1 nodo | 1 nodo (kernel) | 1 proceso |
| Madurez (2025) | Alta | GA reciente | Alta (L4), L7 en evolución | Alta pero de nicho |

**Regla de decisión para el arquitecto:**
- Necesitás **L7 rico** (traffic shifting, fault injection, per-route authz) en toda la flota → sidecar o ambient+waypoint.
- Priorizás **costo/densidad** y sólo necesitás mTLS + L3/L4 authz → ambient o eBPF.
- Tenés pods con requests/limits ajustados donde 100 MB × sidecar es inviable → ambient/eBPF.
- No podés tocar las apps y querés cifrado + identidad → cualquiera menos library.

### 2.2 NetworkPolicy (L3/L4) vs política de mesh (L7): son complementarias, no alternativas

Un error frecuente en el examen y en producción es creer que el service mesh reemplaza a `NetworkPolicy`. **No lo hace.** Operan en capas distintas y se defienden mutuamente.

| | `NetworkPolicy` (Kubernetes) | AuthorizationPolicy (mesh L7) |
|---|---|---|
| Capa | L3/L4 (IP, puerto, protocolo) | L7 (identidad SPIFFE, path HTTP, método, JWT claims) |
| Ejecutor | CNI (Cilium, Calico) | Sidecar/waypoint Envoy |
| Basado en | Selectores de pod/namespace, CIDR | Identidad criptográfica (mTLS peer) |
| Se puede evadir si… | El CNI no la implementa (¡verificá!) | El atacante llega por un puerto sin proxy |
| Fail mode | Fail-closed si default-deny | Fail-open si no hay `PeerAuthentication STRICT` |

**Defensa en profundidad:** `NetworkPolicy` default-deny corta el datapath aunque el mesh esté mal configurado; la AuthorizationPolicy L7 corta requests que atraviesan un puerto permitido pero con identidad incorrecta. Se despliegan **las dos**.

### 2.3 mTLS mode: PERMISSIVE vs STRICT

| Modo | Acepta texto plano | Acepta mTLS | Uso |
|---|---|---|---|
| `PERMISSIVE` | Sí | Sí | **Migración** — onboarding incremental, sin romper clientes legacy |
| `STRICT` | No (rechaza) | Sí | **Estado objetivo** — zero-trust real |
| `DISABLE` | Sí | No | Excepción explícita (p. ej. scraping de un exporter externo) |

El anti-patrón es quedarse en `PERMISSIVE` "por las dudas": deja abierta la puerta de texto plano indefinidamente. `PERMISSIVE` es un **estado de transición con fecha de vencimiento**, no un destino.

---

## 3. Manifiestos completos (sin recortar)

Los ejemplos usan Istio como plano de control de referencia (el más pedido en CNPA), con equivalentes en Linkerd/Cilium donde aporta. Todos son sintácticamente válidos y aplicables.

### 3.1 Base: default-deny a nivel de red (CNI) — la primera línea

```yaml
# 00-default-deny.yaml
# Deniega TODO ingress/egress en el namespace, salvo lo explícitamente permitido.
# Se aplica ANTES de cualquier política de mesh: si esto falla, nada entra ni sale.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}          # todos los pods del namespace
  policyTypes:
    - Ingress
    - Egress
  # sin reglas ingress/egress => deniega todo
---
# Permitir DNS de salida (imprescindible: sin esto ningún pod resuelve nombres)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### 3.2 Permitir un flujo específico L3/L4: `billing` → `payments-db`

```yaml
# 01-allow-billing-to-db.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-billing-to-payments-db
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: billing
      ports:
        - protocol: TCP
          port: 5432
```

### 3.3 mTLS STRICT en todo el mesh

```yaml
# 02-mtls-strict.yaml
# PeerAuthentication a nivel mesh-wide (namespace istio-system = raíz del mesh).
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

Para migración incremental, se puede sobreescribir por namespace o por puerto:

```yaml
# 02b-mtls-permissive-legacy.yaml
# Excepción temporal: el namespace 'legacy' aún tiene clientes sin sidecar.
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: legacy-permissive
  namespace: legacy
spec:
  mtls:
    mode: PERMISSIVE
  portLevelMtls:
    9090:
      mode: DISABLE      # el exporter de Prometheus se scrapea en claro, temporalmente
```

### 3.4 AuthorizationPolicy L7 basada en identidad SPIFFE

```yaml
# 03-authz-payments-db.yaml
# Sólo el service account 'billing' del namespace 'payments' puede hacer
# POST/GET al path /txn del servicio payments-api. Todo lo demás => 403.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: payments-api-allow-billing
  namespace: payments
spec:
  selector:
    matchLabels:
      app: payments-api
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/payments/sa/billing"   # SPIFFE ID
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/txn", "/txn/*"]
```

Un default-deny explícito a nivel de mesh (recomendado para no depender del "deny implícito"):

```yaml
# 04-authz-default-deny.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: istio-system   # aplica a todo el mesh
spec:
  {}                        # sin rules + action ALLOW por defecto ausente => deny-all
```

> Nota de exactitud: en Istio una `AuthorizationPolicy` con `spec: {}` y sin `action` equivale a **DENY-ALL** para los workloads seleccionados. Con `action: ALLOW` y `rules: []` el efecto es el mismo (nada matchea → denegado). Verificalo siempre con un test de tráfico (§5), no de memoria.

### 3.5 SPIFFE/SPIRE explícito (cuando el mesh no alcanza)

Cuando hay workloads fuera del mesh (VMs, funciones, otro cluster) que igual necesitan identidad federada, SPIRE emite los SVID. Registro de un workload:

```yaml
# 05-spire-registration.yaml  (aplicado vía `spire-server entry create`, mostrado como CRD-like)
# SPIFFE ID: spiffe://prod.acme/ns/payments/sa/billing
# Selector: el proceso corre como uid 1000 en un nodo con label agent 'node-a'
```

```bash
$ kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://prod.acme/ns/payments/sa/billing \
    -parentID spiffe://prod.acme/ns/spire/sa/spire-agent \
    -selector k8s:ns:payments \
    -selector k8s:sa:billing
Entry ID         : 8f2a...c41
SPIFFE ID        : spiffe://prod.acme/ns/payments/sa/billing
Parent ID        : spiffe://prod.acme/ns/spire/sa/spire-agent
TTL              : 3600
Selector         : k8s:ns:payments
Selector         : k8s:sa:billing
```

### 3.6 cert-manager para el trust bundle raíz del mesh

En producción, la CA del mesh no debe ser la self-signed de Istio. Se usa un issuer intermedio firmado por la PKI corporativa:

```yaml
# 06-mesh-ca-issuer.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  isCA: true
  duration: 8760h        # 1 año para la CA intermedia
  secretName: cacerts    # Istio lee este secret exacto
  commonName: istio-ca.prod.acme
  subject:
    organizations: ["acme-cluster"]
  issuerRef:
    name: corporate-root-ca     # ClusterIssuer respaldado por Vault/PKI
    kind: ClusterIssuer
    group: cert-manager.io
  privateKey:
    algorithm: ECDSA
    size: 256
```

### 3.7 Linkerd (equivalente idiomático)

Linkerd hace mTLS **on-by-default** entre pods inyectados; la política se expresa con `Server` + `AuthorizationPolicy`/`MeshTLSAuthentication`:

```yaml
# 07-linkerd-authz.yaml
apiVersion: policy.linkerd.io/v1beta3
kind: Server
metadata:
  name: payments-api
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  port: 8080
  proxyProtocol: HTTP/2
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: billing-id
  namespace: payments
spec:
  identities:
    - "billing.payments.serviceaccount.identity.linkerd.cluster.local"
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: payments-api-allow-billing
  namespace: payments
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: payments-api
  requiredAuthenticationRefs:
    - group: policy.linkerd.io
      kind: MeshTLSAuthentication
      name: billing-id
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Verificar que la inyección del sidecar ocurrió

```bash
$ kubectl label namespace payments istio-injection=enabled
namespace/payments labeled

$ kubectl -n payments get pod billing-7d9f6c8b5-xk2mn \
    -o jsonpath='{.spec.containers[*].name}{"\n"}'
billing istio-proxy

# 2 contenedores: el sidecar 'istio-proxy' se inyectó correctamente.
```

### 4.2 Confirmar que el tráfico va cifrado (mTLS efectivo)

```bash
$ istioctl authn tls-check billing.payments.svc.cluster.local
HOST:PORT                                     STATUS     SERVER     CLIENT     AUTHN POLICY        DESTINATION RULE
payments-api.payments.svc.cluster.local:8080  OK         STRICT     ISTIO_MUTUAL  default/istio-system  -
```

`STATUS: OK`, `SERVER: STRICT`, `CLIENT: ISTIO_MUTUAL` → el canal está en mTLS mutuo. Si viera `CLIENT: DISABLE` o `SERVER: PERMISSIVE`, habría un flanco en claro.

### 4.3 Inspeccionar el certificado que presenta el sidecar

```bash
$ istioctl proxy-config secret billing-7d9f6c8b5-xk2mn.payments \
    -o json | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d | openssl x509 -noout -text | grep -A2 'Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/payments/sa/billing
```

El SAN es un **URI SPIFFE**, no un DNS name: la identidad viaja en el certificado. Verificá también la vigencia:

```bash
$ istioctl proxy-config secret billing-7d9f6c8b5-xk2mn.payments -o json \
  | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -dates
notBefore=Aug  6 09:14:22 2025 GMT
notAfter=Aug  7 09:14:52 2025 GMT
```

TTL de ~24 h con rotación automática: certificados de vida corta, sin CRL ni OCSP necesarios.

### 4.4 Probar una política de autorización (el test que importa)

```bash
# Desde un pod NO autorizado (analytics) hacia payments-api:
$ kubectl -n payments exec deploy/analytics -c analytics -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payments-api:8080/txn
403

# Desde el pod autorizado (billing):
$ kubectl -n payments exec deploy/billing -c billing -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payments-api:8080/txn
200
```

`403` para el peer no autorizado, `200` para el autorizado: la AuthorizationPolicy discrimina por identidad, no por red.

### 4.5 Verificar el CNI realmente aplica NetworkPolicy

```bash
# Cilium: comprobar el veredicto en el datapath.
$ kubectl -n payments exec ds/cilium -- \
    cilium-dbg policy get | grep -A3 'payments-db'
Endpoint 3241 (payments-db):
  Ingress allowed: billing (L4: TCP/5432)
  Ingress denied:  * (default-deny)

# Cilium Hubble: observar drops en vivo.
$ hubble observe --namespace payments --verdict DROPPED --last 5
Aug  6 09:31:12  analytics-5c7 -> payments-db:5432  TCP  DROPPED  (Policy denied)
```

### 4.6 Linkerd: verificación equivalente

```bash
$ linkerd viz edges deployment -n payments
SRC       DST           SRC_NS    DST_NS    SECURED
billing   payments-api  payments  payments  √
web       payments-api  payments  payments  √

$ linkerd viz stat deploy -n payments
NAME          MESHED   SUCCESS   RPS   LATENCY_P99   TLS
billing        1/1     100.00%   4.2   12ms          100%
payments-api   1/1      99.83%   9.1   28ms          100%
```

`SECURED √` y `TLS 100%`: todo el tráfico observado está cifrado y mutuamente autenticado.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Checklist de aceptación (lo que "hecho" significa)

1. **Encryption:** `istioctl authn tls-check` → `STRICT`/`ISTIO_MUTUAL` en todos los pares, o `linkerd viz edges` → `√`.
2. **Identity:** el SAN del cert es un URI SPIFFE, no un DNS name.
3. **AuthZ negativa:** un peer no listado recibe `403` (L7) o `connection refused`/`DROPPED` (L3/L4).
4. **Default-deny de red confirmado:** un pod nuevo sin política no puede abrir conexiones no permitidas.
5. **Rotación:** `notAfter - notBefore` corto (horas), y los certs se renuevan solos sin reinicio.

### 5.2 Fallas típicas y su diagnóstico

| Síntoma | Causa raíz probable | Cómo confirmarlo | Fix |
|---|---|---|---|
| `503 UC`/`upstream connect error` tras habilitar STRICT | Un cliente sin sidecar sigue hablando en claro | `istioctl authn tls-check` muestra `CLIENT: DISABLE` | Inyectar sidecar o `PERMISSIVE` temporal en ese puerto |
| Todo devuelve `403 RBAC: access denied` | Se aplicó `deny-all` sin las reglas `ALLOW` correspondientes | `istioctl proxy-config listener ... ` + logs Envoy `rbac_access_denied` | Añadir la `AuthorizationPolicy` ALLOW con el `principal` correcto |
| La política L7 "no hace nada" | Falta `PeerAuthentication STRICT`: sin mTLS no hay identidad para autorizar | `tls-check` → `PERMISSIVE`; el `principal` llega vacío | Poner mTLS en STRICT primero |
| `NetworkPolicy` ignorada | El CNI no implementa NetworkPolicy (p. ej. Flannel puro) | El pod alcanza destinos que deberían estar denegados | Migrar a Cilium/Calico |
| DNS roto tras default-deny | Se olvidó permitir egress UDP/TCP 53 a kube-system | `nslookup` timeout dentro del pod | Aplicar `allow-dns-egress` (§3.1) |
| Cert expirado, tráfico cae de golpe | `istio-agent` no pudo renovar (CA caída / reloj desincronizado) | `istioctl proxy-config secret` → `notAfter` en el pasado | Revisar istiod/CA y NTP del nodo |

### 5.3 Comandos de diagnóstico profundo

```bash
# Logs de RBAC del sidecar destino (por qué se rechazó):
$ kubectl -n payments logs deploy/payments-api -c istio-proxy | grep rbac
[... rbac_access_denied_matched_policy ns[payments]-policy[deny-all]-rule[0]]

# Ver toda la config efectiva de Envoy (clusters, listeners, secrets):
$ istioctl proxy-config all payments-api-6b8f9-abc.payments

# Validar la sintaxis y semántica de las políticas antes de aplicar:
$ istioctl analyze -n payments
✔ No validation issues found when analyzing namespace: payments.

# Comprobar qué políticas afectan a un workload concreto:
$ istioctl x authz check payments-api-6b8f9-abc.payments
ACTION   AuthorizationPolicy                    RULES
ALLOW    payments.payments-api-allow-billing    1
DENY     istio-system.deny-all                  1
```

### 5.4 El orden de habilitación importa (secuencia segura)

Aplicar en este orden evita cortes de producción:

1. Inyectar sidecars con mTLS en **`PERMISSIVE`** (nada se rompe, empieza a haber identidad).
2. Verificar con `tls-check` que los clientes ya negocian `ISTIO_MUTUAL`.
3. Aplicar `AuthorizationPolicy` **ALLOW** para todos los flujos legítimos.
4. Recién entonces pasar a mTLS **`STRICT`** y `deny-all`.
5. En paralelo, aplicar `NetworkPolicy` default-deny + allows L3/L4.

Invertir el orden (STRICT/deny-all primero) garantiza un incidente.

---

## 6. Referencias

- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Cluster Networking (modelo de red): https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Istio — Mutual TLS / PeerAuthentication: https://istio.io/latest/docs/concepts/security/#mutual-tls-authentication
- Istio — Authorization Policy: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Authorization (concepts): https://istio.io/latest/docs/concepts/security/#authorization
- Istio — Ambient mesh: https://istio.io/latest/docs/ambient/overview/
- Linkerd — Automatic mTLS: https://linkerd.io/2/features/automatic-mtls/
- Linkerd — Authorization policy: https://linkerd.io/2/features/server-policy/
- SPIFFE — Concepts (SVID, Trust Domain): https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
- SPIRE — Documentation: https://spiffe.io/docs/latest/spire-about/
- Cilium — Network Policy: https://docs.cilium.io/en/stable/security/policy/
- Cilium — Transparent Encryption / mTLS: https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium Hubble — Observability: https://docs.cilium.io/en/stable/observability/hubble/
- cert-manager — Istio CA integration: https://cert-manager.io/docs/usage/istio/
- NIST SP 800-207 — Zero Trust Architecture: https://csrc.nist.gov/publications/detail/sp/800-207/final
- CNPA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf