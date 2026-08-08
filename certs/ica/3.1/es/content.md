# 3.1 Configuración del tráfico de Ingress y Egress

> **Certificación:** Istio Certified Associate (ICA) · **Dominio:** Traffic Management · **Peso en el examen:** 5%
> **Alcance:** Control del tráfico norte–sur en el límite del mesh — admisión de clientes externos (ingress) y gobierno de las llamadas a servicios fuera del registro del mesh (egress), usando las APIs `Gateway`/`VirtualService`/`ServiceEntry`/`Sidecar` de Istio y la Kubernetes Gateway API.

---

## 1. Motivación: el problema arquitectónico en el límite del mesh

Un service mesh te da mTLS uniforme, retries y observabilidad *entre* workloads que llevan un sidecar Envoy. Pero hay dos clases de tráfico que cruzan el límite del mesh y quedan, por defecto, **fuera** de las garantías de ese control plane:

- **Ingress (norte → sur):** un cliente en la Internet pública — un navegador, una API de un partner, un runner de CI — no tiene sidecar ni identidad de Istio. Si golpea directamente tu `Service` de `type: LoadBalancer`, no se aplica nada del motor de políticas del mesh (autorización, rate limiting, mTLS, telemetría). La conexión termina en un pod que confía en lo que sea que le haya llegado.
- **Egress (sur → norte/afuera):** un pod dentro del mesh llamando a `api.stripe.com`, a un endpoint de RDS o a un mainframe legacy interno. Por defecto el `outboundTrafficPolicy` de Istio es `ALLOW_ANY`, así que el sidecar pasa *cualquier* destino desconocido directamente. Eso es cómodo y también es un **agujero de exfiltración de datos y una falla de compliance**: un pod comprometido puede alcanzar cualquier cosa que el enrutamiento del nodo permita, y tu SIEM ve un egress plano sin atribución por workload.

El dolor de producción que motiva este tema:

1. **Un único punto de entrada auditable.** No querés N servicios exponiendo cada uno un LoadBalancer. Querés un único borde endurecido (`istio-ingressgateway`) donde TLS termina, los certificados rotan, se asienta el WAF/authz, y cada request queda registrado con un trace ID.
2. **Ciclo de vida de los certificados desacoplado de las apps.** El material TLS debe vivir como Kubernetes secrets consumidos por el gateway (vía SDS), rotados por cert-manager, nunca embebidos en las imágenes de las aplicaciones.
3. **Una salida controlada, con allow-list y monitorizable.** Los entornos regulados (PCI-DSS, SOC 2) exigen que el egress hacia terceros salga desde **IPs conocidas y fijas** y esté **en allow-list por hostname**. Eso implica forzar el egress a través de un **egress gateway** dedicado para que el firewall externo pueda fijar un conjunto pequeño de IPs, y cambiar el mesh a `REGISTRY_ONLY` para que un destino no declarado sea *denegado*, no reenviado silenciosamente.
4. **Offload de originación de TLS.** Las apps legacy que hablan HTTP plano no deberían reescribirse para agregar HTTPS; el mesh origina TLS hacia el endpoint externo en su nombre, y el bundle de CA se gestiona de forma centralizada.

El resto de este módulo construye ambos bordes: el camino de ingress (`Gateway` + `VirtualService` + secret TLS vía SDS), y el camino de egress (`ServiceEntry` + scoping con `Sidecar` + `Gateway` de egress + originación de TLS con `DestinationRule`), junto con el flujo de diagnóstico de fallas que separa "config aplicada" de "config funcionando".

---

## 2. Comparación técnica y compromisos

### 2.1 Formas de admitir tráfico norte–sur

| Dimensión | Kubernetes `Ingress` | **Istio `Gateway` + `VirtualService`** | **Kubernetes Gateway API** (`Gateway`+`HTTPRoute`) |
|---|---|---|---|
| Grupo de API | `networking.k8s.io/v1` | `networking.istio.io/v1` | `gateway.networking.k8s.io/v1` |
| Data plane | Cualquier ingress controller | Envoy (`istio-ingressgateway`) | Envoy (implementación de Istio) |
| Alcance de protocolos | Solo HTTP(S) | HTTP, HTTPS, gRPC, TCP, TLS/SNI, mongo/mysql etc. | HTTP, TLS, TCP, gRPC (kind por Route) |
| Potencia de routing L7 | Path/host, annotations específicas del controller | Completa: weighted, match por header/regex, mirror, fault, retry, timeout, rewrite | matchers y filters de HTTPRoute; para casos avanzados del mesh todavía hace falta VirtualService |
| Terminación de TLS | Ref a Secret, dependiente del controller | `credentialName` → SDS; SIMPLE/MUTUAL/PASSTHROUGH | `certificateRefs` → SDS |
| Separación de roles | Ninguna (un objeto) | Débil (Gateway vs VS por convención) | **Fuerte, incorporada** (el equipo de infra es dueño del `Gateway`, el equipo de la app del `HTTPRoute`, `ReferenceGrant` controla el cruce entre namespaces) |
| Portabilidad | Alta (pero las annotations no lo son) | Específica de Istio | **Neutral respecto del proveedor** — la dirección estratégica de Istio |
| Postura de Istio | Soportado, desaconsejado | Clásico, con todas las funciones | **Recomendado de aquí en más** |

**Regla práctica:** para cualquier cosa más rica que host/path — canary con pesos, routing por header, passthrough de mTLS, TCP — usá el par `Gateway`/`VirtualService` de Istio o la Gateway API. Un `Ingress` plano no puede expresar routing con pesos o basado en headers de forma portable. La Gateway API es donde Istio está invirtiendo; conocé ambas para el examen.

### 2.2 `Server.tls.mode` — qué hace el gateway con el handshake

| `tls.mode` | ¿Termina TLS? | ¿Verifica cert del cliente? | Clave de routing | Uso típico |
|---|---|---|---|---|
| `SIMPLE` | Sí | No | host/path HTTP (post-descifrado) | Sitio HTTPS público estándar |
| `MUTUAL` | Sí | Sí (contra `caCertificates`) | host/path HTTP | mTLS B2B / de partner en el borde |
| `OPTIONAL_MUTUAL` | Sí | Si se presenta | host/path HTTP | mTLS opcional, p. ej. migración |
| `PASSTHROUGH` | **No** | No | **Solo SNI** (`spec.tls.match.sniHosts` en el VS) | TLS extremo a extremo hacia el backend; el gateway nunca ve texto plano |
| `ISTIO_MUTUAL` | Sí | Sí (certs de Istio) | host/path HTTP | Gateway ↔ dentro del mesh, certs gestionados por Istio |
| `AUTO_PASSTHROUGH` | No | No | SNI | Gateway este-oeste multi-cluster |

Consecuencia clave: con `PASSTHROUGH` enrutás por `sniHosts` en un bloque **`tls:`** del `VirtualService`, no en `http:` — el gateway es ciego a L7. Con `SIMPLE`/`MUTUAL` enrutás por `http:` porque el payload está descifrado.

### 2.3 Postura de egress: `meshConfig.outboundTrafficPolicy.mode`

| Modo | Comportamiento ante un host **no declarado** | Postura de seguridad | Costo operativo |
|---|---|---|---|
| `ALLOW_ANY` (por defecto) | Passthrough del sidecar — conecta a ciegas | Débil: camino de exfiltración, sin política | Bajo — nada que declarar |
| `REGISTRY_ONLY` | **Bloqueado** salvo que exista un `ServiceEntry` | Fuerte: egress default-deny, atribución completa | Mayor — cada dependencia externa debe declararse |

`REGISTRY_ONLY` es la elección de nivel producción, pero es un **cambio disruptivo**: cualquier llamada externa que no esté respaldada por un `ServiceEntry` empieza a fallar (`502`/`503`). Desplegalo detrás de un inventario de objetos `ServiceEntry` y un canary monitorizado.

### 2.4 Caminos de routing de egress

| Camino | Cómo | ¿IP de salida fija? | ¿Política/telemetría en la salida? | Complejidad |
|---|---|---|---|---|
| Passthrough del sidecar (`ALLOW_ANY`) | Nada | No | No | Ninguna |
| Solo `ServiceEntry` | Registrar el host | No (por nodo) | Solo por sidecar | Baja |
| **Egress gateway** | `ServiceEntry` + `Gateway` de egress + `VirtualService` + `DestinationRule` | **Sí** (pods del gateway) | Sí (chokepoint central) | Alta |

Usá el egress gateway cuando un firewall externo deba poner en allow-list tus IPs de origen, cuando necesites offload de originación de TLS, o cuando quieras un único lugar para hacer cumplir y observar todo el tráfico saliente hacia terceros.

---

## 3. Manifiestos completos, sin abreviar

Asumí una instalación por defecto de Istio con los deployments `istio-ingressgateway` e `istio-egressgateway` en `istio-system`, y un namespace de app `prod` etiquetado para inyección de sidecar.

```bash
$ kubectl create namespace prod
$ kubectl label namespace prod istio-injection=enabled
```

### 3.1 Ingress — terminación de TLS con SDS (`SIMPLE`)

**(a) Secret TLS** — debe vivir en el **mismo namespace que el ingress gateway** (`istio-system`) para el lookup de `credentialName`, salvo que habilites refs de secrets entre namespaces.

```bash
$ kubectl create -n istio-system secret tls shop-tls-cert \
    --key=shop.example.com.key \
    --cert=shop.example.com.crt
secret/shop-tls-cert created
```

**(b) Gateway** — se enlaza al Envoy de ingress, abre 443, redirige el 80.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: shop-gateway
  namespace: prod
spec:
  selector:
    istio: ingressgateway            # matches the istio-ingressgateway pod label
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: shop-tls-cert  # Kubernetes secret in istio-system, delivered via SDS
    hosts:
    - "shop.example.com"
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "shop.example.com"
    tls:
      httpsRedirect: true            # 301 all cleartext to https
```

**(c) VirtualService** — enlaza el gateway a un backend con un canary 90/10 y retry/timeout endurecidos.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: shop
  namespace: prod
spec:
  hosts:
  - "shop.example.com"
  gateways:
  - shop-gateway                     # only traffic entering via this gateway
  http:
  - match:
    - uri:
        prefix: /api
    route:
    - destination:
        host: shop-api.prod.svc.cluster.local
        subset: v1
        port:
          number: 8080
      weight: 90
    - destination:
        host: shop-api.prod.svc.cluster.local
        subset: v2
        port:
          number: 8080
      weight: 10
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx,connect-failure,refused-stream
    timeout: 10s
  - route:                           # default: everything else to the web frontend
    - destination:
        host: shop-web.prod.svc.cluster.local
        port:
          number: 80
```

**(d) DestinationRule** — define los subsets `v1`/`v2` y fuerza mTLS dentro del mesh hacia el backend.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: shop-api
  namespace: prod
spec:
  host: shop-api.prod.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL             # gateway→backend uses Istio certs
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

#### El mismo borde, en forma de Kubernetes Gateway API

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shop-gateway
  namespace: prod
spec:
  gatewayClassName: istio
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    hostname: "shop.example.com"
    tls:
      mode: Terminate
      certificateRefs:
      - name: shop-tls-cert
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: prod
spec:
  parentRefs:
  - name: shop-gateway
  hostnames:
  - "shop.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: shop-api
      port: 8080
      weight: 90
    - name: shop-api-v2
      port: 8080
      weight: 10
  - backendRefs:
    - name: shop-web
      port: 80
```

### 3.2 Ingress — TLS extremo a extremo con `PASSTHROUGH`

Cuando el backend debe terminar su propio TLS (compliance, o la app es dueña del cert), el gateway enruta solo por SNI:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: passthrough-gateway
  namespace: prod
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH
    hosts:
    - "secure.example.com"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: passthrough
  namespace: prod
spec:
  hosts:
  - "secure.example.com"
  gateways:
  - passthrough-gateway
  tls:                               # NOTE: tls block, not http — no L7 visibility
  - match:
    - port: 443
      sniHosts:
      - secure.example.com
    route:
    - destination:
        host: secure-backend.prod.svc.cluster.local
        port:
          number: 8443
```

### 3.3 Egress — pasar el mesh a default-deny

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |-
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
```

> En la práctica configurá esto vía `IstioOperator`/Helm (`meshConfig.outboundTrafficPolicy.mode: REGISTRY_ONLY`) para que sobreviva a los upgrades; el ConfigMap mostrado es lo que renderiza.

### 3.4 Egress — declarar una dependencia externa con un `ServiceEntry`

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: stripe-api
  namespace: prod
spec:
  hosts:
  - api.stripe.com
  ports:
  - number: 443
    name: https
    protocol: TLS                    # keep app-originated TLS opaque; route on SNI
  resolution: DNS
  location: MESH_EXTERNAL
```

Con `REGISTRY_ONLY`, este único objeto es la diferencia entre que la llamada tenga éxito y un `502`.

### 3.5 Egress — acotar el conjunto alcanzable de un workload con un `Sidecar`

Más allá de la seguridad, los recursos `Sidecar` recortan la config que sostiene cada proxy (memoria/CPU a escala) al empujar solo los hosts listados.

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: prod
spec:
  egress:
  - hosts:
    - "prod/*"                       # every service in prod
    - "istio-system/*"              # control plane + gateways
    - "prod/api.stripe.com"         # the declared external host
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY              # per-namespace default-deny, overrides mesh default
```

### 3.6 Egress — egress gateway completo con originación de TLS (patrón canónico)

Forzá el tráfico HTTP plano de la app hacia `edition.cnn.com` a salir a través de `istio-egressgateway`, donde Istio **origina TLS** hacia el puerto 443. La app envía HTTP/80; el firewall del tercero ve solo las IPs del egress gateway.

**(a) ServiceEntry** — registrar ambos puertos:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: cnn
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  - number: 443
    name: https-port
    protocol: HTTPS
  resolution: DNS
```

**(b) Egress Gateway** — un server en el puerto 80, mTLS interno del gateway:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
  namespace: prod
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: https-port-for-tls-origination
      protocol: HTTPS
    hosts:
    - edition.cnn.com
    tls:
      mode: ISTIO_MUTUAL             # sidecar → egress gateway is Istio mTLS
```

**(c) DestinationRule para el subset del egress gateway** — fija el mTLS/SNI hacia el gateway:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-cnn
  namespace: prod
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: cnn
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
      portLevelSettings:
      - port:
          number: 80
        tls:
          mode: ISTIO_MUTUAL
          sni: edition.cnn.com
```

**(d) VirtualService** — dos saltos: mesh → egress gateway, egress gateway → externo:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  gateways:
  - istio-egressgateway
  - mesh                             # the reserved keyword for all sidecars
  http:
  - match:
    - gateways:
      - mesh                         # traffic leaving the app sidecars
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        subset: cnn
        port:
          number: 80
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway          # traffic now at the egress gateway
      port: 80
    route:
    - destination:
        host: edition.cnn.com
        port:
          number: 443               # forward to the real HTTPS port
      weight: 100
```

**(e) DestinationRule para la originación de TLS** — el gateway envuelve la request HTTP en TLS hacia el 443:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-cnn-com
  namespace: prod
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE                 # originate one-way TLS (use MUTUAL + client certs for mTLS)
```

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Confirmar que los gateways están sanos y obtener la IP externa

```bash
$ kubectl -n istio-system get pods -l istio=ingressgateway
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-7d6f8c9b4c-nq2xw   1/1     Running   0          6d

$ export INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
$ export SECURE_PORT=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
$ echo "$INGRESS_HOST:$SECURE_PORT"
203.0.113.42:443
```

### 4.2 Aplicar y hacer lint antes de confiar en nada

```bash
$ kubectl apply -f shop-ingress.yaml
gateway.networking.istio.io/shop-gateway created
virtualservice.networking.istio.io/shop created
destinationrule.networking.istio.io/shop-api created

$ istioctl analyze -n prod
✔ No validation issues found when analyzing namespace: prod.
```

Una falla representativa que `analyze` detecta temprano:

```bash
$ istioctl analyze -n prod
Error [IST0101] (VirtualService prod/shop) Referenced host+subset in destinationrule not found:
  "shop-api.prod.svc.cluster.local+v3"
Error: Analyzers found issues when analyzing namespace: prod.
```

### 4.3 Probar el camino de ingress de extremo a extremo

```bash
$ curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result}\n" \
    --resolve shop.example.com:443:$INGRESS_HOST \
    https://shop.example.com/api/products
200 0

# cleartext must 301 to https
$ curl -sI --resolve shop.example.com:80:$INGRESS_HOST http://shop.example.com/ | head -1
HTTP/1.1 301 Moved Permanently
```

### 4.4 Inspeccionar lo que el Envoy de ingress realmente programó

```bash
$ istioctl proxy-config listeners deploy/istio-ingressgateway -n istio-system
ADDRESSES PORT  MATCH                        DESTINATION
0.0.0.0   443   SNI: shop.example.com        Route: https.443.https.shop-gateway.prod
0.0.0.0   80    ALL                          Route: http.80.http.shop-gateway.prod
0.0.0.0   15021 ALL                          Inline Route: /healthz/ready*

$ istioctl proxy-config routes deploy/istio-ingressgateway -n istio-system \
    --name https.443.https.shop-gateway.prod -o json | \
    jq '.[0].virtualHosts[0].routes[] | {prefix:.match.prefix, cluster:.route.cluster, weight:.route.weightedClusters}'
{
  "prefix": "/api",
  "cluster": null,
  "weight": {
    "clusters": [
      { "name": "outbound|8080|v1|shop-api.prod.svc.cluster.local", "weight": 90 },
      { "name": "outbound|8080|v2|shop-api.prod.svc.cluster.local", "weight": 10 }
    ]
  }
}
```

Confirmá que el secret TLS llegó al gateway por SDS (la falla de ingress #1):

```bash
$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system
RESOURCE NAME    TYPE           STATUS     VALID CERT   SERIAL NUMBER      NOT AFTER
shop-tls-cert    Cert Chain     ACTIVE     true         3a:9f:...:c1       2026-11-04T09:12:00Z
default          Cert Chain     ACTIVE     true         6b:22:...:0e       2026-08-09T00:00:00Z
```

Si `shop-tls-cert` está ausente o `VALID CERT` es `false`, el nombre/namespace del secret está mal o el PEM está malformado — el navegador va a recibir un reset del handshake, no un 4xx.

### 4.5 Egress: probar el default-deny y luego probar el camino del gateway

```bash
# a pod in prod, with REGISTRY_ONLY and no ServiceEntry yet:
$ kubectl -n prod exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
502

# after applying the ServiceEntry + egress-gateway manifests:
$ kubectl apply -f cnn-egress.yaml
serviceentry.networking.istio.io/cnn created
gateway.networking.istio.io/istio-egressgateway created
destinationrule.networking.istio.io/egressgateway-for-cnn created
virtualservice.networking.istio.io/direct-cnn-through-egress-gateway created
destinationrule.networking.istio.io/originate-tls-for-edition-cnn-com created

$ kubectl -n prod exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
200
```

Confirmá que la request salió a través del egress gateway (no directamente del sidecar):

```bash
$ kubectl -n istio-system logs deploy/istio-egressgateway | tail -1
[2026-08-08T14:07:31.402Z] "GET /politics HTTP/2" 200 - via_upstream -
  "-" 0 1088342 214 213 "10.244.2.15"
  "curl/8.5.0" "b3f1e2..." "edition.cnn.com" "151.101.65.67:443"
  outbound|443||edition.cnn.com ...
```

La presencia de esta línea en el log del **egress gateway** — con upstream `edition.cnn.com:443` — prueba tanto el routing de dos saltos como la originación de TLS.

---

## 5. Guía de verificación y diagnóstico de fallas

Trabajá el límite como un pipeline. Cada etapa tiene su propia herramienta y su propia firma de falla.

| Síntoma | Causa más probable | Comando de diagnóstico | Solución |
|---|---|---|---|
| `curl` al ingress se cuelga / conn refused | Sin IP externa; puerto equivocado; pod del gateway caído | `kubectl -n istio-system get svc,pods -l istio=ingressgateway` | Provisionar LB / chequear que el `selector` matchea las labels del pod |
| Reset del handshake TLS en el 443 | Secret ausente/ns equivocado/malformado, o typo en `credentialName` | `istioctl pc secret deploy/istio-ingressgateway -n istio-system` | Recrear `kubectl create secret tls` en `istio-system` |
| `404` desde el gateway (`server: istio-envoy`) | Desajuste de `hosts` o `gateways` del VS; SNI ≠ host del VS | `istioctl pc routes deploy/istio-ingressgateway -n istio-system` | Alinear `hosts`/`gateways` del VS; chequear `--resolve`/SNI |
| `503 UH` (sin upstream sano) | Las labels del subset no matchean los pods; puerto equivocado; sin endpoints | `istioctl pc endpoints deploy/istio-ingressgateway -n istio-system \| grep shop-api` | Arreglar las labels del subset del `DestinationRule` / el puerto del Service |
| El backend PASSTHROUGH da 404 | Enrutando en `http:` en lugar de `tls.match.sniHosts` | `istioctl pc listeners ...` (esperar un match de SNI) | Mover las reglas al bloque `tls:`, matchear `sniHosts` |
| La llamada externa devuelve `502` | `REGISTRY_ONLY` + `ServiceEntry` ausente/con typo en el host | `kubectl -n prod get serviceentry`; `istioctl analyze -n prod` | Agregar/corregir el `ServiceEntry` |
| El egress funciona pero **se saltea** el egress gateway | Falta el salto `mesh`→gateway del VS; `Sidecar` con egress demasiado estrecho | `istioctl pc routes deploy/sleep.prod` para el host externo | Agregar la ruta con match `mesh`; ampliar `Sidecar.egress.hosts` |
| `503` en el egress gateway al originar TLS | Doble TLS (la app ya hace HTTPS + originación), o SNI equivocado | logs del egress gateway; chequear `tls.mode`/`sni` del `DestinationRule` | Enviar HTTP desde la app; matchear el SNI con el host real |
| Cert vencido en pleno vuelo | Sin rotación / cert-manager no renueva | `istioctl pc secret ...` → `NOT AFTER` | Cablear cert-manager; SDS recarga sin reiniciar el pod |

**La escalera de diagnóstico canónica para un bug en el límite del mesh:**

```bash
# 1. Is the config even valid and self-consistent?
$ istioctl analyze -n prod

# 2. Did the config reach the right proxy? (control-plane sync)
$ istioctl proxy-status
NAME                                   CLUSTER   CDS   LDS   EDS   RDS   ECDS   ISTIOD          VERSION
istio-ingressgateway-...   Kubernetes  SYNCED SYNCED SYNCED SYNCED  IGNORED istiod-...   1.24.1
sleep-...prod              Kubernetes  SYNCED SYNCED SYNCED SYNCED  IGNORED istiod-...   1.24.1
#   ^ any STALE/NOT SENT here = push problem, stop and fix istiod before debugging routes.

# 3. What did Envoy actually program? (listeners → routes → clusters → endpoints)
$ istioctl proxy-config listeners <proxy>
$ istioctl proxy-config routes    <proxy>
$ istioctl proxy-config clusters  <proxy>
$ istioctl proxy-config endpoints <proxy>

# 4. Read the response flags from the access log — they name the failure.
#    UH = no healthy upstream, NR = no route, UF = upstream conn fail,
#    URX = retry limit, RBAC = authz deny.
$ kubectl -n istio-system logs deploy/istio-ingressgateway | tail -5
```

La disciplina que premia el examen: **"aplicado" ≠ "sincronizado" ≠ "programado" ≠ "alcanzable".** `kubectl apply` prueba solo que etcd aceptó el objeto. `istioctl proxy-status` prueba que istiod lo empujó. `istioctl proxy-config` prueba que Envoy lo compiló. Solo `curl` + las response flags del access-log prueban que la request se completa. Diagnosticá en ese orden y cada clase de falla queda aislada en exactamente un peldaño.

---

## 6. Referencias

- Istio — Ingress Gateways: https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
- Istio — Securing Gateways with TLS (SDS `credentialName`): https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
- Istio — Accessing External Services / `outboundTrafficPolicy`: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
- Istio — Egress Gateways: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
- Istio — Egress Gateway TLS Origination: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/
- Istio — TLS Origination for Egress Traffic: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Istio API — `Gateway`: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio API — `VirtualService`: https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio API — `ServiceEntry`: https://istio.io/latest/docs/reference/config/networking/service-entry/
- Istio API — `DestinationRule` (incl. `ClientTLSSettings`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio API — `Sidecar`: https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio — Kubernetes Gateway API support: https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/
- Istio — `istioctl proxy-config` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config
- Istio — Envoy access-log response flags (debugging): https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Kubernetes — Gateway API (`Gateway`, `HTTPRoute`, `ReferenceGrant`): https://gateway-api.sigs.k8s.io/
- CNCF — ICA Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf