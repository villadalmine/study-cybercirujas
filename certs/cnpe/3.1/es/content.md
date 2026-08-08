# Tema 3.1 — Configuring Secure Service-to-Service Communication

## 1. Motivación y el problema arquitectónico de producción

Durante décadas el modelo de seguridad de red se basó en el perímetro: un firewall separaba "adentro" (confiable) de "afuera" (hostil). Ese modelo colapsa en una plataforma cloud-native por tres razones estructurales:

1. **La red interna dejó de ser un límite de confianza.** En un cluster de Kubernetes, cualquier Pod comprometido tiene, por defecto, conectividad IP hacia cualquier otro Pod y Service (`east-west traffic`). Un atacante que consigue RCE en un frontend puede hablar directamente con la base de datos, el service de facturación y el metadata endpoint del cloud provider. La CNI, por defecto, es una red plana.
2. **Las IPs no son identidad.** Un Pod recibe una IP efímera del rango del CNI; esa IP se recicla en segundos. Basar autorización en IP de origen (el modelo de las `NetworkPolicy` L3/L4) es frágil: la identidad real del workload —"soy el `payments` del namespace `prod` corriendo con la ServiceAccount `payments-sa`"— no viaja en el paquete.
3. **El tráfico interno viaja en claro.** Sin mTLS, el tráfico entre servicios es HTTP plano sobre la red del CNI. Cualquiera con acceso al host (un DaemonSet de logging comprometido, un `tcpdump` en el nodo, un sniffer en el overlay) lee credenciales, tokens y PII en tránsito.

El paradigma que resuelve esto es **Zero Trust** (NIST SP 800-207): *never trust, always verify*. Cada conexión service-to-service debe cumplir, en cada request, tres propiedades:

- **Authentication (¿quién sos?)** — identidad criptográfica del workload, no su IP.
- **Encryption (¿alguien puede leer esto?)** — confidencialidad e integridad en tránsito (mTLS).
- **Authorization (¿podés hacer esto?)** — política explícita de qué identidad puede llamar a qué servicio, en qué verbo/path.

El problema de plataforma —el que le compete al Platform Engineer, no al desarrollador de la aplicación— es entregar estas tres propiedades **de forma transparente al código de aplicación, con rotación de credenciales automática, sin claves de larga duración y con revocación efectiva**. Pedirle a cada equipo que implemente TLS mutuo, distribuya CAs, rote certificados y escriba lógica de autorización en su servicio no escala: se hace mal, se hace distinto en cada lenguaje, y las claves de larga vida terminan hardcodeadas en un Secret que nadie rota.

La solución de plataforma tiene dos capas conceptuales que hay que dominar:

- **Workload identity + PKI corta** — un sistema que emite identidades criptográficas verificables y de vida corta a cada workload. El estándar es **SPIFFE** (Secure Production Identity Framework For Everyone) y su implementación de referencia **SPIRE**.
- **Data plane que aplica mTLS + authz** — típicamente un **service mesh** (Istio, Linkerd, Cilium) que intercepta el tráfico y aplica cifrado e identidad sin tocar la aplicación.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 El espectro de mecanismos

| Mecanismo | Capa | Identidad | Cifra tráfico | Authz L7 | Costo operativo | Cuándo usarlo |
|---|---|---|---|---|---|---|
| `NetworkPolicy` (CNI) | L3/L4 | IP / label selector | No | No | Bajo | Segmentación base, *siempre*, como defensa en profundidad |
| mTLS en la app (librería) | L7 | Cert por servicio | Sí | En código | Muy alto | Casi nunca; no escala entre lenguajes |
| Service mesh con sidecar (Istio, Linkerd) | L4-L7 | SPIFFE / cert por SA | Sí (auto) | Sí | Medio-alto | Microservicios heterogéneos, authz L7 rica |
| Service mesh sidecarless / eBPF (Cilium, Istio Ambient) | L3-L7 | SPIFFE / identidad Cilium | Sí | Sí | Medio | Escala grande, sensibilidad a latencia/RAM |
| SPIFFE/SPIRE directo (SDK) | L7 | X.509/JWT SVID | La app usa el cert | En código | Alto | Cargas fuera de mesh, multi-cluster/multi-cloud, VMs |

**Punto clave para el examen:** estas capas no son excluyentes. Una plataforma de producción combina `NetworkPolicy` (segmentación por defecto, *deny-all*) **con** un mesh que aporta mTLS e identidad. La `NetworkPolicy` limita el *blast radius* a nivel de red; el mesh aporta identidad criptográfica y authz L7. Confiar solo en el mesh deja la puerta L3 abierta a workloads sin sidecar; confiar solo en `NetworkPolicy` deja el tráfico en claro y la autorización atada a IPs.

### 2.2 Sidecar vs sidecarless (ambient / eBPF)

| Dimensión | Sidecar (Istio clásico, Linkerd) | Ambient / eBPF (Istio Ambient, Cilium) |
|---|---|---|
| Inyección | Un contenedor proxy por Pod | Sin proxy en el Pod; ztunnel por nodo (L4) + waypoint por servicio (L7) |
| Overhead de RAM | ~40–100 MB × cada Pod | Amortizado por nodo |
| Latencia añadida | 2 saltos de proxy (in+out) por hop | 1 componente L4 por nodo; L7 solo si hay waypoint |
| Radio de actualización | Redeploy del Pod para actualizar proxy | Actualización del componente de nodo, sin tocar Pods |
| Granularidad de identidad | Por Pod/ServiceAccount | Por identidad de workload (Cilium) o SPIFFE (ztunnel) |
| Madurez | Muy alta | Creciente (Ambient GA en Istio 1.24+; Cilium maduro en L3/L4) |

### 2.3 Istio vs Linkerd vs Cilium (mesh)

| Criterio | Istio | Linkerd | Cilium |
|---|---|---|---|
| Data plane | Envoy (C++) | linkerd2-proxy (Rust, micro-proxy) | eBPF + Envoy (para L7) |
| Identidad | SPIFFE (`spiffe://<trust-domain>/ns/<ns>/sa/<sa>`) | SPIFFE-like por ServiceAccount | Identidad Cilium (labels) + SPIFFE opcional |
| mTLS | Auto, configurable STRICT/PERMISSIVE | Auto por defecto, opt-out | mTLS por WireGuard/IPsec o via Envoy |
| Authz | `AuthorizationPolicy` (L7 rica: path, method, JWT claims) | `Server` + `AuthorizationPolicy`/`MeshTLSAuthentication` | `CiliumNetworkPolicy` (L3-L7) |
| Complejidad | Alta (muchos CRDs, Envoy) | Baja (opinado, pocos CRDs) | Media (requiere entender eBPF) |
| Multi-cluster | Maduro | Soportado | Cluster Mesh maduro |
| Overhead de latencia | Mayor (Envoy full) | Menor (proxy minimalista) | Menor en L3/L4 (kernel) |

**Regla de decisión:** si el requisito es *authz L7 rica* (por path HTTP, método, claims de JWT, egress con SNI) y multi-tenant complejo → **Istio**. Si el requisito es *mTLS simple, bajo overhead, poca superficie operativa* → **Linkerd**. Si ya usás Cilium como CNI y querés política L3-L7 en el kernel con menos proxies → **Cilium**.

---

## 3. Manifiestos e infraestructura completos

A continuación se muestran implementaciones completas y sintácticamente válidas para los tres pilares: (A) segmentación base con `NetworkPolicy`, (B) mTLS + authz con **Istio**, (C) identidad de workload con **SPIRE**, y (D) emisión de certificados con **cert-manager**.

### 3.A — Segmentación base: default-deny + allow explícito

La higiene mínima de cualquier namespace de producción: negar todo y abrir solo lo necesario. Esto vale con o sin mesh.

```yaml
# 00-default-deny.yaml — niega TODO ingress y egress en el namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}          # selecciona todos los Pods del namespace
  policyTypes:
    - Ingress
    - Egress
```

```yaml
# 01-allow-dns.yaml — sin esto, ninguna resolución DNS funciona (falla silenciosa clásica)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```yaml
# 02-allow-frontend-to-payments.yaml — solo el frontend puede hablar con payments:8443
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-payments
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: payments
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8443
```

> **Gotcha de producción:** olvidar `allow-egress-dns` con un `default-deny` de egress rompe *toda* la resolución de nombres. El síntoma es engañoso: `curl` a una IP funciona, a un hostname falla con timeout. Es la falla número uno al introducir default-deny.

### 3.B — Istio: mTLS STRICT + AuthorizationPolicy L7

**Paso 1 — habilitar el mesh en el namespace.** Istio inyecta el sidecar Envoy en Pods de namespaces etiquetados.

```yaml
# istio-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    istio-injection: enabled     # inyección automática de sidecar
```

**Paso 2 — forzar mTLS STRICT en todo el mesh** con un `PeerAuthentication` en el namespace raíz de Istio (aplica a todo el mesh) y afinado por namespace.

```yaml
# peerauth-strict-mesh.yaml — mTLS obligatorio en TODO el mesh
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system          # namespace raíz => alcance de todo el mesh
spec:
  mtls:
    mode: STRICT                    # rechaza cualquier tráfico no-mTLS (plaintext)
```

```yaml
# peerauth-payments.yaml — override fino: payments exige mTLS salvo puerto 15020 (health)
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: payments-mtls
  namespace: prod
spec:
  selector:
    matchLabels:
      app: payments
  mtls:
    mode: STRICT
  portLevelMtls:
    15020:
      mode: PERMISSIVE              # el health/probe del agente puede ir en claro
```

**Paso 3 — DestinationRule** para asegurar que el cliente origine mTLS hacia el destino (en modo mesh gestionado suele ser `ISTIO_MUTUAL` por defecto, pero se explicita para claridad y para servicios externos).

```yaml
# destinationrule-payments.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payments-mtls
  namespace: prod
spec:
  host: payments.prod.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL           # usa los certs SPIFFE gestionados por Istio
```

**Paso 4 — AuthorizationPolicy con default-deny + allow por identidad SPIFFE y por L7.** Este es el corazón del control: solo la ServiceAccount `frontend-sa` puede hacer `POST /charge` sobre `payments`.

```yaml
# authz-deny-all.yaml — deny-all explícito en el namespace (regla vacía = deny)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: prod
spec:
  {}                               # sin rules => niega todo el tráfico en prod
```

```yaml
# authz-payments.yaml — allow fino por identidad + método + path
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend-to-payments
  namespace: prod
spec:
  selector:
    matchLabels:
      app: payments
  action: ALLOW
  rules:
    - from:
        - source:
            # identidad SPIFFE de la ServiceAccount llamante
            principals:
              - "cluster.local/ns/prod/sa/frontend-sa"
      to:
        - operation:
            methods: ["POST"]
            paths: ["/charge"]
      when:
        - key: request.auth.claims[iss]
          values: ["https://accounts.example.com"]   # exige JWT válido de este issuer
```

**Paso 5 (opcional) — RequestAuthentication** para validar JWT de usuario final (end-user auth), combinable con lo anterior.

```yaml
# requestauth-jwt.yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: payments-jwt
  namespace: prod
spec:
  selector:
    matchLabels:
      app: payments
  jwtRules:
    - issuer: "https://accounts.example.com"
      jwksUri: "https://accounts.example.com/.well-known/jwks.json"
      forwardOriginalToken: true
```

### 3.C — SPIRE: identidad de workload SPIFFE

Cuando hay cargas fuera del mesh (VMs, multi-cloud, funciones), o se quiere una raíz de identidad independiente del mesh, se despliega **SPIRE**. Arquitectura: `spire-server` (autoridad, emite SVIDs), `spire-agent` (DaemonSet, atesta el nodo y los workloads locales), y el **Workload API** (socket UNIX) por donde el workload pide su SVID sin manejar claves.

```yaml
# spire-server.yaml — StatefulSet + config de node attestation por k8s PSAT
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: spire
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port = "8081"
      trust_domain = "example.org"
      data_dir = "/run/spire/data"
      log_level = "INFO"
      ca_ttl = "24h"
      default_x509_svid_ttl = "1h"    # SVIDs de vida corta: rotación cada hora
    }
    plugins {
      DataStore "sql" {
        plugin_data {
          database_type = "sqlite3"
          connection_string = "/run/spire/data/datastore.sqlite3"
        }
      }
      NodeAttestor "k8s_psat" {
        plugin_data {
          clusters = {
            "prod-cluster" = {
              service_account_allow_list = ["spire:spire-agent"]
            }
          }
        }
      }
      KeyManager "disk" {
        plugin_data { keys_path = "/run/spire/data/keys.json" }
      }
    }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: spire
spec:
  serviceName: spire-server
  replicas: 1
  selector:
    matchLabels: { app: spire-server }
  template:
    metadata:
      labels: { app: spire-server }
    spec:
      serviceAccountName: spire-server
      containers:
        - name: spire-server
          image: ghcr.io/spiffe/spire-server:1.9.0
          args: ["-config", "/run/spire/config/server.conf"]
          ports:
            - containerPort: 8081
          volumeMounts:
            - name: spire-config
              mountPath: /run/spire/config
              readOnly: true
            - name: spire-data
              mountPath: /run/spire/data
      volumes:
        - name: spire-config
          configMap: { name: spire-server }
  volumeClaimTemplates:
    - metadata: { name: spire-data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 1Gi } }
```

```yaml
# spire-agent.yaml — DaemonSet con Workload API expuesto por socket
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-agent
  namespace: spire
data:
  agent.conf: |
    agent {
      data_dir = "/run/spire"
      log_level = "INFO"
      server_address = "spire-server"
      server_port = "8081"
      socket_path = "/run/spire/sockets/agent.sock"
      trust_domain = "example.org"
    }
    plugins {
      NodeAttestor "k8s_psat" {
        plugin_data { cluster = "prod-cluster" }
      }
      KeyManager "memory" {}
      WorkloadAttestor "k8s" {
        plugin_data { skip_kubelet_verification = false }
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-agent
  namespace: spire
spec:
  selector:
    matchLabels: { app: spire-agent }
  template:
    metadata:
      labels: { app: spire-agent }
    spec:
      serviceAccountName: spire-agent
      hostPID: true
      hostNetwork: true
      containers:
        - name: spire-agent
          image: ghcr.io/spiffe/spire-agent:1.9.0
          args: ["-config", "/run/spire/config/agent.conf"]
          volumeMounts:
            - name: spire-config
              mountPath: /run/spire/config
              readOnly: true
            - name: spire-sockets
              mountPath: /run/spire/sockets
      volumes:
        - name: spire-config
          configMap: { name: spire-agent }
        - name: spire-sockets
          hostPath:
            path: /run/spire/sockets
            type: DirectoryOrCreate
```

**Registro de una identidad de workload** (registration entry): mapea un selector de atestación (ns + SA) a un SPIFFE ID.

```bash
$ kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://example.org/ns/prod/sa/payments-sa \
    -parentID spiffe://example.org/ns/spire/sa/spire-agent \
    -selector k8s:ns:prod \
    -selector k8s:sa:payments-sa
Entry ID         : 8f3c...c21
SPIFFE ID        : spiffe://example.org/ns/prod/sa/payments-sa
Parent ID        : spiffe://example.org/ns/spire/sa/spire-agent
Revision         : 0
X509-SVID TTL    : default
Selector         : k8s:ns:prod
Selector         : k8s:sa:payments-sa
```

### 3.D — cert-manager: PKI interna para mTLS sin mesh

Si no se adopta mesh completo, `cert-manager` emite y rota certificados X.509 desde una CA interna, montados como Secret en el Pod. Útil para pares de servicios acotados.

```yaml
# selfsigned-issuer.yaml — bootstrap de una CA raíz interna
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-root
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: internal-ca
  secretName: internal-ca-secret
  duration: 87600h     # 10 años para la raíz
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-root
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca-issuer
spec:
  ca:
    secretName: internal-ca-secret
```

```yaml
# payments-cert.yaml — cert de servidor con SAN SPIFFE, rotación automática
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: payments-tls
  namespace: prod
spec:
  secretName: payments-tls
  duration: 24h          # vida corta
  renewBefore: 8h        # cert-manager renueva 8h antes de expirar
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  commonName: payments.prod.svc.cluster.local
  dnsNames:
    - payments.prod.svc.cluster.local
    - payments
  uris:
    - spiffe://example.org/ns/prod/sa/payments-sa   # identidad SPIFFE en el SAN URI
  issuerRef:
    name: internal-ca-issuer
    kind: ClusterIssuer
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Verificar inyección de sidecar y estado del mesh (Istio)

```bash
$ istioctl version
client version: 1.24.1
control plane version: 1.24.1
data plane version: 1.24.1 (12 proxies)

$ kubectl get pods -n prod
NAME                        READY   STATUS    RESTARTS   AGE
frontend-6d4b9c8f7-2xk9p    2/2     Running   0          5m
payments-7f9c6b5d4-lm8qz    2/2     Running   0          5m
#            READY 2/2 => app + istio-proxy inyectado. Si ves 1/1, NO hay sidecar.

$ istioctl proxy-status
NAME                              CLUSTER  CDS   LDS   EDS   RDS   ISTIOD                    VERSION
frontend-6d4b9c8f7-2xk9p.prod     Kube     SYNCED SYNCED SYNCED SYNCED istiod-5c9f... 1.24.1
payments-7f9c6b5d4-lm8qz.prod     Kube     SYNCED SYNCED SYNCED SYNCED istiod-5c9f... 1.24.1
# SYNCED en todas las columnas = el proxy tiene la config vigente de istiod.
```

### 4.2 Confirmar que el tráfico va cifrado con mTLS

```bash
$ istioctl x describe pod payments-7f9c6b5d4-lm8qz.prod
Pod: payments-7f9c6b5d4-lm8qz
   Pod Revision: default
   Pod Ports: 8443 (payments), 15090 (istio-proxy)
--------------------
Service: payments
   Port: https 8443/HTTP targets pod port 8443
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied AuthorizationPolicy:
   prod/allow-frontend-to-payments
   prod/deny-all
```

Verificación de bajo nivel: el certificado que presenta Envoy debe ser el SVID SPIFFE, no un cert de app.

```bash
$ istioctl proxy-config secret payments-7f9c6b5d4-lm8qz.prod -o json | \
    jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
    base64 -d | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/prod/sa/payments-sa
```

### 4.3 Probar que default-deny funciona (la prueba negativa)

```bash
# Desde un pod SIN permiso (namespace/SA no autorizada):
$ kubectl exec -n prod deploy/reporting -c reporting -- \
    curl -s -o /dev/null -w "%{http_code}\n" https://payments:8443/charge
403
# RBAC: access denied  => la AuthorizationPolicy rechazó la identidad. Correcto.

# Desde el frontend autorizado:
$ kubectl exec -n prod deploy/frontend -c frontend -- \
    curl -s -o /dev/null -w "%{http_code}\n" -X POST https://payments:8443/charge
200
```

### 4.4 Linkerd (comparación operativa)

```bash
$ linkerd check
kubernetes-api
--------------
√ can initialize the client
√ can query the Kubernetes API

linkerd-identity
----------------
√ certificate config is valid
√ trust anchors are within their validity period
√ issuer cert is within its validity period
√ issuer cert is valid for at least 60 days

Status check results are √

$ linkerd viz edges deployment -n prod
SRC        DST        SRC_NS   DST_NS   SECURED
frontend   payments   prod     prod     √        # √ = conexión mTLS verificada
```

### 4.5 SPIRE — pedir el SVID desde el Workload API

```bash
$ kubectl exec -n prod deploy/payments -c payments -- \
    /opt/spire/bin/spire-agent api fetch x509 \
    -socketPath /run/spire/sockets/agent.sock
Received 1 svid after 8.14ms

SPIFFE ID:        spiffe://example.org/ns/prod/sa/payments-sa
SVID Valid After: 2026-08-07 14:02:11 +0000 UTC
SVID Valid Until: 2026-08-07 15:02:11 +0000 UTC   # TTL 1h => rotación automática
CA #1 Valid After: 2026-08-07 13:00:00 +0000 UTC
CA #1 Valid Until: 2026-08-08 13:00:00 +0000 UTC
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Ladder de diagnóstico

Diagnosticá siempre de abajo hacia arriba: conectividad L3 → mTLS/identidad L4 → autorización L7. Saltarse un peldaño hace perder horas.

| Síntoma | Causa probable | Comando de confirmación | Fix |
|---|---|---|---|
| `curl` a hostname da timeout, a IP funciona | `default-deny` egress sin allow-DNS | `kubectl exec ... nslookup payments` falla | Aplicar `allow-egress-dns` |
| `connection reset` entre dos pods con mesh | Un lado sin sidecar + `PeerAuthentication STRICT` | `kubectl get pod` muestra `1/1` en un extremo | Etiquetar ns `istio-injection=enabled` y recrear el Pod |
| `503 UC`/`upstream connect error` | mTLS mode disparejo (STRICT vs plaintext) | `istioctl x describe pod` muestra el modo efectivo | Alinear `PeerAuthentication`/`DestinationRule` |
| `403 RBAC: access denied` | `AuthorizationPolicy` niega la identidad | Ver logs de Envoy con `rbac` | Corregir `principals`/`paths`/`methods` |
| Todo devuelve 403 tras aplicar una policy | `AuthorizationPolicy` vacía = deny-all sin allow | `kubectl get authorizationpolicy -n prod` | Añadir la regla ALLOW correspondiente |
| SVID no rota / cert expirado | `spire-agent` no atesta, o entry sin selector correcto | `spire-server entry show` | Corregir registration entry / node attestation |

### 5.2 Leer el log RBAC de Envoy (por qué un 403)

```bash
$ kubectl logs -n prod payments-7f9c6b5d4-lm8qz -c istio-proxy | grep rbac
[2026-08-07T14:22:03.918Z] "POST /charge HTTP/2" 403 - rbac_access_denied_matched_policy[none]
  "-" 0 19 0 - "-" "curl/8.5.0"
  downstream_peer="spiffe://cluster.local/ns/prod/sa/reporting-sa"
# La identidad que llegó (reporting-sa) no está en 'principals'. Diagnóstico inequívoco.
```

`rbac_access_denied_matched_policy[none]` significa: ninguna regla ALLOW matcheó, y hay al menos un `AuthorizationPolicy` de acción ALLOW en el selector → default deny. El campo `downstream_peer` te dice exactamente qué identidad SPIFFE llegó — comparala contra tus `principals`.

### 5.3 Verificar mTLS en el cable (prueba de humo)

```bash
# Confirmar en el nodo que NO viaja texto plano entre pods del mesh.
$ kubectl debug node/worker-2 -it --image=nicolaka/netshoot -- \
    tcpdump -A -n -i any 'tcp port 8443' -c 20
...
16:04:11.882 IP 10.244.2.7.51234 > 10.244.3.9.8443: Flags [P.]
....E....(...TLS 1.3 handshake...   # bytes cifrados, no HTTP legible
# Si vieras "POST /charge HTTP/2\r\nHost: payments" en claro => mTLS NO está activo.
```

### 5.4 Analizar la política efectiva antes de romper prod

```bash
# Simular el efecto de una AuthorizationPolicy sin aplicarla:
$ istioctl analyze -n prod
✔ No validation issues found when analyzing namespace: prod.

# Ver la config RBAC que Envoy realmente cargó:
$ istioctl proxy-config rbac payments-7f9c6b5d4-lm8qz.prod -o json | \
    jq '.[].active.policies | keys'
[
  "ns[prod]-policy[allow-frontend-to-payments]-rule[0]"
]
```

### 5.5 Checklist de producción

- [ ] `NetworkPolicy` **default-deny** ingress+egress en cada namespace de app, con allow-DNS explícito.
- [ ] `PeerAuthentication` en modo **STRICT** a nivel mesh (`istio-system`); `PERMISSIVE` solo transitorio durante la migración, nunca como estado final.
- [ ] `AuthorizationPolicy` **deny-all** por namespace + allow por identidad SPIFFE (nunca por IP).
- [ ] SVID/cert **TTL corto** (≤ 24h, idealmente 1h) con rotación automática verificada — sin claves de larga vida en Secrets.
- [ ] Health/readiness probes exentos del STRICT (port-level `PERMISSIVE`) para no romper el probe del kubelet.
- [ ] `istioctl proxy-status` = `SYNCED` en toda la flota; alertar sobre `STALE`.
- [ ] Prueba negativa automatizada en CI: una identidad no autorizada **debe** recibir 403.
- [ ] Trust anchors / CA con expiración monitoreada (`linkerd check` / alerta sobre expiry de la CA raíz).

---

## 6. Referencias

- CNCF Curriculum (CNPE) — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- NIST SP 800-207, *Zero Trust Architecture* — https://csrc.nist.gov/publications/detail/sp/800-207/final
- Kubernetes — *Network Policies* — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- SPIFFE — *SPIFFE Concepts / SVID / Workload API* — https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
- SPIRE — *Deploying SPIRE on Kubernetes* — https://spiffe.io/docs/latest/deploying/spire_agent/
- Istio — *Mutual TLS / PeerAuthentication* — https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — *Authorization Policy* — https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — *Security concepts (identity, SPIFFE)* — https://istio.io/latest/docs/concepts/security/
- Istio — *Ambient mesh* — https://istio.io/latest/docs/ambient/
- Linkerd — *Automatic mTLS* — https://linkerd.io/2/features/automatic-mtls/
- Linkerd — *Authorization Policy* — https://linkerd.io/2/features/server-policy/
- Cilium — *Mutual Authentication / Network Policy* — https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/
- cert-manager — *Certificate resources / CA Issuer* — https://cert-manager.io/docs/configuration/ca/
- Envoy — *RBAC filter* — https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter