# Guía de Estudio KCSA: Tema 5.4 – Service Mesh Security

## 1. Motivación y problema arquitectónico en producción

### 1.1 El dilema de seguridad de los microservicios a escala
En las arquitecturas monolíticas tradicionales, los límites de seguridad se definen en el perímetro (firewalls, WAFs perimetrales, gateways de ingress). Las comunicaciones internas ocurren a través de llamadas a funciones locales o memoria compartida. En las arquitecturas de microservicios nativas de la nube que se ejecutan en Kubernetes, los componentes de la aplicación se desacoplan en cientos o miles de pods efímeros que se comunican a través de una red plana definida por software (SDN).

Esta evolución arquitectónica introduce desafíos de seguridad críticos:
- **Confianza implícita dentro del clúster:** Los plugins de CNI estándar de Kubernetes establecen conectividad plana L3/L4 entre todos los pods de forma predeterminada. Si un atacante compromete un solo pod (a través de Ejecución remota de código o ataques a la cadena de suministro de dependencias), hereda una alcanzabilidad de red lateral completa a través del clúster.
- **Deterioro de la identidad y volatilidad de IP:** Las reglas de firewall tradicionales basadas en IP (`iptables`, grupos de seguridad) se desmoronan cuando las cargas de trabajo se reprograman continuamente en nodos dinámicos. Las direcciones IP de los pods son efímeras, no atestiguadas y propensas a la reutilización.
- **Falta de cifrado en cable:** El tráfico entre pods que atraviesa límites de nodos, switches entre racks o subredes de VPC en la nube pública a menudo fluye en texto plano (HTTP/1.1 o gRPC no cifrado), violando los estándares de cumplimiento (PCI-DSS 4.0, HIPAA, SOC 2 Type II, FedRAMP High).
- **Ceguera L7 en Network Policies:** La `NetworkPolicy` estándar de Kubernetes opera estrictamente en la Capa 3 (IP) y la Capa 4 (TCP/UDP). No puede aplicar políticas de acceso granulares basadas en métodos HTTP (por ejemplo, permitir `GET /public`, denegar `POST /admin`), cabeceras HTTP, claims de JWT o métodos gRPC.

```
[ Traditional Flat Kubernetes CNI ]
Pod A (Compromised) ════════ Plaintext HTTP/L4 ════════> Pod B (Database/API)
                      (No Wire Encryption, No L7 Authz)

[ Service Mesh Zero-Trust Architecture ]
Pod A (Identity: SA-A) ───> Local Proxy ══ mTLS (SPIFFE X.509) ══> Remote Proxy ───> Pod B (Identity: SA-B)
                                 │                                    │
                                 └─── L7 Authz Policy: Deny POST ─────┘
```

### 1.2 La solución de Service Mesh: Capa superpuesta de seguridad Zero-Trust
Un Service Mesh desacopla los mecanismos de seguridad operacional—tales como el cifrado mTLS (TLS mutuo), la emisión de identidad criptográfica, la autorización de tráfico y el registro de auditoría—del código fuente de la aplicación. Intercepta el tráfico de red en el límite de la carga de trabajo utilizando proxies sidecar por pod (por ejemplo, Envoy) o daemons ambient a nivel de nodo (por ejemplo, `ztunnel` de Istio).

Objetivos clave de seguridad satisfechos por un Service Mesh en producción:
1. **Identidad criptográfica de carga de trabajo:** Asigna a cada pod una identidad criptográfica verificable basada en el estándar SPIFFE (Secure Production Identity Framework for Everyone), vinculada al `ServiceAccount` de Kubernetes.
2. **Mutual TLS (mTLS) automatizado:** Aplica la autenticación de pares (peer authentication) y el cifrado de red TLS sin necesidad de modificar el código de la aplicación. Gestiona la emisión, distribución y rotación transparente de certificados X.509 de corta duración.
3. **Autorización en Capa 7 (AuthZ):** Aplica políticas de control de acceso de grano fino basadas en identidades SPIFFE autenticadas, rutas HTTP, verbos, cabeceras de solicitud y claims de OAuth2/JWT.
4. **Defensa en profundidad:** Complementa las políticas de red L3/L4 con la aplicación en L7, estableciendo límites strictly definidos incluso si los firewalls a nivel de red fallan.

### 1.3 Paradigmas arquitectónicos: Mesh Sidecar vs. Ambient (Sidecarless)

```
+-----------------------------------------------------------------------------------+
| SIDECAR ARCHITECTURE                                                             |
| Pod Boundary                                                                      |
|  +-----------------------+    +-----------------------------------------------+  |
|  | Application Container |    | Sidecar Container (Envoy)                     |  |
|  | (App Logic)           |<==>| - L4 mTLS (SPIFFE)                            |  |
|  |                       |    | - L7 Policy, Tracing, Metrics                 |  |
|  +-----------------------+    +-----------------------------------------------+  |
+-----------------------------------------------------------------------------------+

+-----------------------------------------------------------------------------------+
| AMBIENT ARCHITECTURE                                                              |
| Node Boundary                                                                     |
|  +-----------------------+    +-----------------------+                           |
|  | Pod A (App Container) |    | Pod B (App Container) |                           |
|  +-----------┬-----------+    +-----------┬-----------+                           |
|              │ (Unix Domain Socket / eBPF)│                                       |
|              ▼                            ▼                                       |
|  +-----------------------------------------------------------------------------+  |
|  | Node Daemon (ztunnel): L4 mTLS Encapsulation (HBONE)                         |  |
|  +--------------------------------------+--------------------------------------+  |
|                                         │                                         |
|                                         ▼ (Optional)                              |
|  +-----------------------------------------------------------------------------+  |
|  | Dedicated Waypoint Proxy (Envoy): L7 Deep Packet Inspection & AuthZ          |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

#### Modelo Sidecar (Inyección estándar de Envoy)
- **Mecánica:** Se inyecta un contenedor proxy Envoy en cada pod de aplicación. El tráfico se redirige hacia Envoy utilizando reglas de `iptables` (cadenas `PREROUTING`/`OUTPUT`) o programas eBPF (hooks `tc` / `cgroup`).
- **Límite de seguridad:** Co-ubicado dentro del límite de memoria/namespace del pod. El proxy comparte el namespace de red del pod, la interfaz de loopback y el ciclo de vida.
- **Compromisos (Trade-offs):** Alto aislamiento de seguridad (el compromiso del proxy se limita a un solo pod), pero incurre en una alta sobrecarga de recursos (CPU/RAM por pod) y requiere el reinicio de los pods para las actualizaciones del proxy.

#### Modelo Ambient / Sidecarless (ej., Istio Ambient Mesh)
- **Mecánica:** División de la funcionalidad del mesh en dos capas distintas:
  1. **Túnel Zero-Trust (`ztunnel`):** Un daemon por nodo que opera en L4. Aplica mTLS utilizando HBONE (HTTP-Based Overlay Network Environment: tunelización HTTP/2 CONNECT sobre el puerto 15008).
  2. **Waypoint Proxies:** Despliegues dedicados de Envoy por namespace o por serviceaccount que se ejecutan fuera de los pods de la aplicación para gestionar el procesamiento L7 (enrutamiento HTTP, RBAC, validación de JWT).
- **Límite de seguridad:** El transporte de identidad L4 está aislado a nivel de nodo; el procesamiento L7 se delega a pods de despliegue dedicados.
- **Compromisos (Trade-offs):** Huella de CPU/RAM reducida y cero reinicios de pods de aplicaciones durante las actualizaciones de la mesh. Sin embargo, el daemon de nodo (`ztunnel`) conserva material de claves para todos los pods co-ubicados en ese nodo, creando un radio de impacto entre pods más amplio si el kernel del host del nodo resulta comprometido.

---

## 2. Comparaciones técnicas y matrices de trade-offs

### 2.1 Comparación de la superficie de control de seguridad

| Característica de seguridad | Kubernetes NetworkPolicy (L3/L4) | Service Mesh Sidecar (Istio Envoy) | Service Mesh Ambient (ztunnel + Waypoint) | Seguridad eBPF (Cilium NetworkPolicy) |
| :--- | :--- | :--- | :--- | :--- |
| **Capa de aplicación principal** | L3 (IP) y L4 (TCP/UDP) | L4 (mTLS) y L7 (HTTP/gRPC/JWT) | L4 (`ztunnel`) / L7 (`Waypoint`) | L3, L4 y L7 limitado (a través de integración con Envoy) |
| **Origen de identidad de la carga de trabajo** | Pod IP / Label Selectors | SPIFFE X.509 SVID Criptográfico | SPIFFE X.509 SVID Criptográfico | Identidad criptográfica (SPIFFE) o mapeo IP-a-ID |
| **Cifrado en cable** | Ninguno (Requiere IPsec/WireGuard en CNI) | mTLS transparente (TLS 1.3 / ALPN) | mTLS transparente vía HBONE (puerto 15008) | WireGuard / IPsec o Cilium mTLS |
| **Capacidades de autorización L7** | Ninguna | Completa (Ruta HTTP, Verbo, Cabeceras, JWT) | Completa (solo cuando se configura Waypoint Proxy) | Parcial (a través del parser proxy Envoy integrado) |
| **Radio de impacto de CVE** | Nivel de Daemon Kernel/CNI | Aislado estrictamente a un solo Pod | Nivel de nodo (`ztunnel` afecta a todos los pods locales) | Nivel de mapa Kernel / eBPF |
| **Sobrecarga de recursos** | Mínima (netfilter de Kernel/eBPF) | Alta (15MB-50MB RAM + CPU por pod) | Baja (Un solo daemon por nodo + Waypoint scale-to-zero) | Mínima (Procesamiento eBPF dentro del kernel) |
| **Rotación de certificados** | N/A | Automatizada (SDS en memoria a través de `istiod`) | Automatizada (SDS en memoria a través de `istiod` a `ztunnel`) | Automatizada |

### 2.2 Matriz de trade-offs de la arquitectura de seguridad: Sidecar vs. Ambient

```
+---------------------------------------------------------------------------------------------------+
| SECURITY DIMENSION       | SIDECAR PARADIGM                   | AMBIENT PARADIGM                  |
+--------------------------+------------------------------------+-----------------------------------+
| Key Material Blast       | Isolated: Private keys exist only  | Shared: Node `ztunnel` manages    |
| Radius                   | inside individual Pod memory space | keys for ALL co-located Pods      |
+--------------------------+------------------------------------+-----------------------------------+
| L7 Attack Surface        | High: Full L7 Envoy code compiled  | Minimal at L4: `ztunnel` is a     |
| Exposure                 | into every pod deployment          | slim Rust binary; L7 isolated     |
+--------------------------+------------------------------------+-----------------------------------+
| Vulnerability to Pod RCE | If App pod is popped, attacker can | If App pod is popped, attacker    |
|                          | access Envoy admin API (127.0.0.1) | cannot access `ztunnel` keys      |
+--------------------------+------------------------------------+-----------------------------------+
| Audit/Compliance         | Highly audited, mature production  | Emerging standard; requires       |
| Readiness                | pattern (PCI-DSS compliant)        | threat model review for multi-tenant|
+---------------------------------------------------------------------------------------------------+
```

---

## 3. Manifiestos completos sintácticamente válidos

Los siguientes manifiestos proporcionan una configuración de seguridad completa y de nivel de producción para un namespace de aplicación de microservicios (`production-payment`). Aplican mTLS estricto, emiten autenticación de solicitudes JWT validadas por SPIFFE y definen políticas de autorización L7 Zero-Trust.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-payment
  labels:
    istio-injection: enabled
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-processor-sa
  namespace: production-payment
  labels:
    app.kubernetes.io/name: payment-processor
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-frontend-sa
  namespace: production-payment
  labels:
    app.kubernetes.io/name: checkout-frontend
---
# Enforce Mesh-Wide Strict Mutual TLS for the Namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: production-payment
spec:
  mtls:
    mode: STRICT
---
# Authenticate Inbound Request End-User JWT Credentials
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-ingress-authenticator
  namespace: production-payment
spec:
  selector:
    matchLabels:
      app: payment-processor
  jwtRules:
  - issuer: "https://auth.production.internal/auth/realms/master"
    jwksUri: "https://auth.production.internal/auth/realms/master/protocol/openid-connect/certs"
    forwardOriginalToken: true
    outputPayloadToHeader: "x-jwt-claims"
---
# Layer 7 Authorization Policy: Default Deny All Unmatched Traffic
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: default-deny-all
  namespace: production-payment
spec:
  {}
---
# Layer 7 Authorization Policy: Explicit Allow for Payment Operations
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-checkout-to-payment
  namespace: production-payment
spec:
  selector:
    matchLabels:
      app: payment-processor
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["spiffe://cluster.local/ns/production-payment/sa/checkout-frontend-sa"]
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/v1/charge", "/api/v1/refund"]
    when:
    - key: request.auth.claims[role]
      values: ["payment-admin", "checkout-service"]
---
# Application Workload Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production-payment
  labels:
    app: payment-processor
    tier: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
        tier: api
    spec:
      serviceAccountName: payment-processor-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: payment-api
        image: registry.internal/finance/payment-api:v2.4.1
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        ports:
        - containerPort: 8080
          name: http-api
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
---
# Kubernetes Service Definition
apiVersion: v1
kind: Service
metadata:
  name: payment-processor
  namespace: production-payment
  labels:
    app: payment-processor
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
    name: http
    protocol: TCP
  selector:
    app: payment-processor
```

---

## 4. Comandos CLI reales y salida de terminal ($)

### 4.1 Verificación del análisis de seguridad de la mesh
Ejecute `istioctl analyze` para validar que las políticas de seguridad sean estructuralmente sólidas y estén libres de configuraciones conflictivas en todo el clúster.

```bash
$ istioctl analyze -n production-payment
```
```text
✔ No validation issues found when analyzing namespace: production-payment.
```

### 4.2 Inspección del estado de Peer Authentication y mTLS
Consulte el plano de control para verificar el estado de mTLS en tiempo de ejecución entre las cargas de trabajo `checkout-frontend` y `payment-processor`.

```bash
$ istioctl authn tls-check checkout-frontend-6b45d55485-x2l9b.production-payment payment-processor.production-payment.svc.cluster.local
```
```text
HOST:PORT                                                 STATUS     SERVER     CLIENT     AUTHN POLICY          AUTHENTICATION
payment-processor.production-payment.svc.cluster.local:8080 OK         STRICT     STRICT     default-strict-mtls/production-payment mTLS
```

### 4.3 Inspección de certificados X.509 activos de SPIFFE/SDSA
Extraiga el certificado X.509 activo servido por Envoy para verificar la emisión del SAN (Subject Alternative Name) de SPIFFE y su tiempo de vida.

```bash
$ istioctl proxy-config secret payment-processor-789456c98-rst4w.production-payment --output json | jq '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' -r | base64 -d | openssl x509 -noout -text | grep -A 2 "Subject Alternative Name"
```
```text
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/production-payment/sa/payment-processor-sa
    Signature Algorithm: sha256WithRSAEncryption
```

### 4.4 Verificación de la aplicación de autorización L7 mediante solicitudes dinámicas

#### Caso de prueba 1: Identidad de origen no autorizada (Acceso denegado)
Simule una solicitud originada desde un ServiceAccount no aprobado (`unauthorized-pod` con SA `default-sa`).

```bash
$ kubectl exec -n production-payment deploy/unauthorized-pod -- curl -i -s -X POST http://payment-processor:8080/api/v1/charge
```
```text
HTTP/1.1 403 Forbidden
content-length: 19
content-type: text/plain
date: Fri, 07 Aug 2026 20:23:15 GMT
server: envoy

RBAC: access denied
```

#### Caso de prueba 2: Identidad de origen autorizada sin claims JWT válidos (Acceso denegado)
Ejecute una solicitud desde la carga de trabajo `checkout-frontend` autorizada, pero omita la cabecera de autenticación JWT requerida.

```bash
$ kubectl exec -n production-payment deploy/checkout-frontend -- curl -i -s -X POST http://payment-processor:8080/api/v1/charge
```
```text
HTTP/1.1 403 Forbidden
content-length: 19
content-type: text/plain
date: Fri, 07 Aug 2026 20:23:15 GMT
server: envoy

RBAC: access denied
```

#### Caso de prueba 3: Identidad de origen autorizada con claims JWT válidos (Acceso concedido)
Ejecute una solicitud pasando tanto la verificación de identidad SPIFFE como el claim de autorización JWT obligatorio.

```bash
$ VALID_JWT=$(curl -s -d "grant_type=client_credentials&client_id=checkout&client_secret=secret" https://auth.production.internal/auth/realms/master/protocol/openid-connect/token | jq -r .access_token)
$ kubectl exec -n production-payment deploy/checkout-frontend -- curl -i -s -H "Authorization: Bearer $VALID_JWT" -X POST http://payment-processor:8080/api/v1/charge
```
```text
HTTP/1.1 200 OK
content-type: application/json
date: Fri, 07 Aug 2026 20:23:15 GMT
x-envoy-upstream-service-time: 4
server: envoy

{"status":"success","transaction_id":"tx_99281741"}
```

---

## 5. Diagnóstico de fallos y guía de solución de problemas (Troubleshooting)

### 5.1 Árbol de decisión para solución de problemas (Troubleshooting)

```
                      [ Service Mesh Connection Failure ]
                                      │
                         Is HTTP Status returned?
                                ┌─────┴─────┐
                               YES          NO
                                │           │
                    ┌───────────┴──┐     ┌──┴────────────────────────┐
                 403 Forbidden   503 UC  TCP Reset / Handshake Failure
                    │              │     │
                    ▼              ▼     ▼
               Check L7       Check mTLS Check SPIFFE Trust Domain &
            Authorization    Config & Port Name SAN Certificate Expiration
               Policy        (http- vs tcp-)
```

### 5.2 Flags de respuesta en los logs de acceso de Envoy (Piedra de Rosetta diagnóstica)

Cuando el tráfico falla dentro de un service mesh, inspeccione los logs de Envoy usando `kubectl logs <pod-name> -c istio-proxy`. Envoy adjunta códigos de respuesta de dos letras críticos que indican la causa raíz:

| Flag de respuesta | Significado | Causa raíz / Resolución |
| :--- | :--- | :--- |
| **`UC`** | Upstream Connection Termination | El extremo remoto reinició la conexión. Frecuentemente causado por una desalineación de mTLS (por ejemplo, el cliente enviando texto plano a un servidor que requiere mTLS `STRICT`). |
| **`NR`** | No Route Configured | El listener de Envoy no tiene una ruta de destino que coincida con el host/cabecera solicitado. Verifique que los puertos del `Service` de Kubernetes estén nombrados correctamente (por ejemplo, `http-api` vs `raw-port`). |
| **`UO`** | Upstream Overflow | El circuit breaker se activó debido a un exceso de conexiones concurrentes o solicitudes pendientes. |
| **`FI`** | Fault Injected | Tráfico abortado o retrasado por una regla activa de inyección de fallos en `VirtualService`. |
| **`UF`** | Upstream Connection Failure | El establecimiento de la conexión TCP falló hacia el host remoto (pod caído, bloqueo por network policy). |

### 5.3 Escenarios diagnósticos y remediación

#### Escenario 1: `503 Service Unavailable` con `UC` (Upstream Connection Termination)
- **Síntoma:** El cliente recibe `503 Service Unavailable`. El log de Envoy muestra `503 UC`.
- **Causa raíz:** Un servicio fuera de la mesh (o en un namespace con modo `PeerAuthentication` en `DISABLE`) intenta comunicarse directamente con un pod que aplica mTLS `STRICT`.
- **Comando de diagnóstico:**
  ```bash
  $ istioctl ztunnel-config workload  # For ambient mesh
  # OR for sidecar mesh:
  $ istioctl proxy-config cluster deploy/checkout-frontend --fqdn payment-processor.production-payment.svc.cluster.local
  ```
- **Remediación:** Incorpore el servicio cliente a la mesh (inyecte el sidecar) o ajuste `PeerAuthentication` a `PERMISSIVE` temporalmente durante la migración:
  ```yaml
  spec:
    mtls:
      mode: PERMISSIVE
  ```

#### Escenario 2: Fallo en el handshake del certificado TLS (`CERTIFICATE_VERIFY_FAILED`)
- **Síntoma:** Conexión cerrada inmediatamente en la capa TCP. Los logs de Envoy muestran:
  `TLS error: 268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED`.
- **Causa raíz:** Desalineación en los dominios de confianza (por ejemplo, en un despliegue multi-clúster donde el Clúster A tiene `trustDomain: cluster.local` y el Clúster B tiene `trustDomain: mesh.internal`), o expiración del bundle de CA raíz.
- **Comando de diagnóstico:**
  Compare las huellas digitales (fingerprints) de la CA raíz entre los proxies:
  ```bash
  $ istioctl proxy-config secret deploy/payment-processor -o json | jq '.dynamicActiveSecrets[1].secret.validationContext.customValidatorConfig.defaultCvConfig.trustedCa.inlineBytes' -r | base64 -d | openssl x509 -noout -fingerprint
  ```
- **Remediación:** Sincronice el parámetro `meshConfig.trustDomain` entre los planos de control y rote los certificados de la CA raíz utilizando SPIRE o las cadenas de certificados de la CA de Istio.

#### Escenario 3: `403 Forbidden` inesperado (`RBAC: access denied`)
- **Síntoma:** La aplicación devuelve `403` generado por `server: envoy`.
- **Causa raíz:** Una `AuthorizationPolicy` con `action: ALLOW` está activa en la carga de trabajo, pero la identidad SPIFFE autenticada del cliente no coincide con el array de cadenas `principals`.
- **Comando de diagnóstico:**
  Extraiga la identidad principal exacta del cliente analizada por el proxy Envoy receptor:
  ```bash
  $ kubectl exec -it deploy/payment-processor -c istio-proxy -- pilot-agent request GET logging?level=rbac:debug
  $ kubectl logs deploy/payment-processor -c istio-proxy --tail=50 | grep "enforce allowed"
  ```
  *Salida esperada:*
  `[debug][rbac] shadow policy: enforcement allowed, matching policy none`
- **Remediación:** Asegúrese de que el formato de la URI de identidad SPIFFE coincida con precisión: `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account-name>`.

---

## 6. Referencias

- **CNCF KCSA Curriculum Specification:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Istio Security Architecture & Concepts:**  
  [https://istio.io/latest/docs/concepts/security/](https://istio.io/latest/docs/concepts/security/)
- **SPIFFE Architecture & Workload Identity Standard:**  
  [https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)
- **Envoy Proxy Security Architecture Overview:**  
  [https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/security/security](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/security/security)
- **Istio Ambient Mesh Architecture & Threat Model:**  
  [https://istio.io/latest/docs/ops/ambient/architecture/](https://istio.io/latest/docs/ops/ambient/architecture/)