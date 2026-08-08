# 3.3 Definición de políticas de tráfico con Destination Rules

> **Dominio de examen 3 — Traffic Management. Peso del tema: 5.**
> Este es el objeto que convierte a Istio de "un DNS inteligente con reintentos" en una capa de resiliencia L7 genuina. Un `VirtualService` decide *hacia dónde* va una petición; un `DestinationRule` decide *cómo se comporta la conexión hacia ese lugar*: algoritmo de balanceo de carga, límites del connection-pool, health-checking pasivo (circuit breaking), afinidad de sesión y TLS/mTLS del lado del cliente. Entender la división entre los dos objetos —y la maquinaria de Envoy que cada uno programa— es el núcleo de este tema.

---

## 1. El problema arquitectónico

Considerá un servicio `reviews` con tres deployments (`v1`, `v2`, `v3`) detrás de un único `Service` de Kubernetes. Kubernetes te da exactamente una palanca: balanceo de carga de `kube-proxy` mediante iptables/IPVS sobre todos los endpoints Ready, round-robin, a nivel de conexión, sin conciencia de L7. Ese modelo se rompe en producción de cuatro maneras concretas:

1. **Sin segmentación de sub-servicios.** Las tres versiones comparten la ClusterIP. No podés enviar el 1 % del tráfico a `v3` para un canary, porque `kube-proxy` no puede distinguir los pods `v3` de los `v1` —todos son endpoints del mismo Service. El enrutamiento necesita *subsets nombrados*.
2. **Sin descarga de carga ante fallos parciales.** Si el heap de un pod `reviews-v1` está saturado y cada petición tarda 30 s, `kube-proxy` le sigue enviando su parte. La latencia se propaga hacia arriba: los hilos de `productpage` se bloquean en el pod lento, el thread pool se agota y una única réplica enferma tira abajo la página entera. Esto es el clásico *cascading failure* / *thundering herd*. Necesitás **passive health checking** que expulse el endpoint defectuoso automáticamente.
3. **Sin contrapresión (back-pressure).** Un pico de tráfico abre conexiones sin límite y encola peticiones pendientes sin límite contra un downstream que solo puede manejar N concurrentes. Sin un techo de **connection pool**, el downstream se cae en vez de descartar el exceso con un `503` rápido.
4. **Sin control del transporte del lado del cliente.** No podés forzar mTLS por destino, originar TLS hacia una API HTTPS externa, ni fijar afinidad de sesión a una réplica concreta para una caché con estado.

Un `DestinationRule` aborda las cuatro. Se aplica **después** de la decisión de enrutamiento, en el punto donde el sidecar del cliente (Envoy) está por abrir una conexión hacia un cluster upstream concreto. Todo lo que configura se mapea sobre un **Envoy Cluster**: `lb_policy`, `circuit_breakers`, `outlier_detection` y el `transport_socket` (TLS).

---

## 2. Dónde encaja el DestinationRule: el modelo de dos objetos

Istio separa deliberadamente el *enrutamiento* de la *política posterior al enrutamiento*. Este es el punto conceptual más evaluado del dominio 3.

| Cuestión | `VirtualService` | `DestinationRule` |
|---|---|---|
| Pregunta que responde | *¿Cuál* host/subset recibe esta petición? | *¿Cómo* hablo con ese host/subset? |
| Objeto de Envoy programado | `RouteConfiguration` / `route` (RDS) | `Cluster` (CDS) |
| Coincide sobre | headers, path, weight, port, sourceLabels | nada — se aplica a *todo* el tráfico hacia `host` |
| Define | HTTP match/rewrite/redirect, **pesos de traffic split**, retries, timeouts, fault injection, mirroring | **subsets**, loadBalancer, connectionPool, outlierDetection, tls |
| Es dueño del **nombre** del subset | lo *referencia* (`destination.subset`) | lo *define* (`subsets[].name` + `labels`) |
| Se aplica antes o después del enrutamiento | realiza el enrutamiento | se aplica después del enrutamiento, por cluster upstream |

**Dependencia crítica:** un subset referenciado en una ruta de `VirtualService` (`destination.subset: v3`) debe estar **definido** en un `DestinationRule` para el mismo `host`. Si no lo está, Envoy no tiene tal cluster y toda petición hacia él devuelve `503 NR`/no cluster. `istioctl analyze` lo señala antes de que llegue a producción.

### Cómo un DestinationRule se expande en clusters de Envoy

Para un host `reviews.default.svc.cluster.local:9080` con subsets `v1/v2/v3`, Pilot emite **cuatro** clusters de Envoy —el cluster base más uno por subset:

```
outbound|9080||reviews.default.svc.cluster.local     # base (no subset)
outbound|9080|v1|reviews.default.svc.cluster.local   # subset v1 → its own CB/LB/outlier config
outbound|9080|v2|reviews.default.svc.cluster.local
outbound|9080|v3|reviews.default.svc.cluster.local
```

Cada cluster de subset lleva sus **propios** circuit breakers y outlier detection. Por eso el circuit breaking es por subset, no por servicio: expulsar un endpoint `v3` defectuoso nunca toca el pool de `v1`.

---

## 3. Subsets: definición de sub-servicios basada en labels

Los subsets son el vocabulario que el `VirtualService` usa para hablar de versiones. Son puros selectores de labels evaluados contra los labels de los pods (normalmente el label `version`, pero cualquier label sirve).

```yaml
apiVersion: networking.istio.io/v1beta1   # v1 is GA since Istio 1.22; v1beta1 is the widely-compatible form
kind: DestinationRule
metadata:
  name: reviews
  namespace: default
spec:
  host: reviews.default.svc.cluster.local   # prefer the FQDN; short names resolve against this DR's namespace
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
  - name: v3
    labels:
      version: v3
```

El `VirtualService` correspondiente entonces enruta por nombre de subset:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
  namespace: default
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v1        # <-- must exist in the DestinationRule above
      weight: 90
    - destination:
        host: reviews
        subset: v3
      weight: 10
```

**Herencia del trafficPolicy del subset.** Un subset hereda el `trafficPolicy` a nivel de host y puede sobrescribirlo campo por campo:

```yaml
spec:
  host: reviews.default.svc.cluster.local
  trafficPolicy:                       # host-level default for all subsets
    connectionPool:
      tcp: { maxConnections: 100 }
    loadBalancer:
      simple: LEAST_REQUEST
  subsets:
  - name: v3
    labels: { version: v3 }
    trafficPolicy:                     # v3 overrides ONLY loadBalancer; inherits the connectionPool
      loadBalancer:
        consistentHash:
          httpCookie: { name: user, ttl: 0s }
```

**Trampa — alcance de `host` y `exportTo`.** Un `host: reviews` corto en un DR en el namespace `default` resuelve a `reviews.default`. Si tu DR vive en un namespace compartido y el servicio vive en otro lado, escribí siempre el FQDN. Usá `exportTo: ["."]` para mantener un DR privado a su propio namespace, o `["*"]` (por defecto) para hacerlo visible en toda la mesh. Dos DR exportando hacia el mismo host desde namespaces distintos son una fuente real de conflictos silenciosos —`istioctl analyze` reporta `DestinationRuleConflict` (solo gana el más antiguo).

---

## 4. Balanceo de carga

`trafficPolicy.loadBalancer` selecciona el `lb_policy` de Envoy para el cluster.

| Algoritmo (`simple:`) | Política de Envoy | Comportamiento | Usar cuando | Costo / trampa |
|---|---|---|---|---|
| `ROUND_ROBIN` | `ROUND_ROBIN` | Rotación estricta entre endpoints sanos | Réplicas uniformes, sin estado, homogéneas | Ignora la carga en vuelo; un pod lento igual recibe su turno |
| `LEAST_REQUEST` | `LEAST_REQUEST` (P2C) | Elige el endpoint con menos peticiones activas, usando power-of-two-choices | Latencia heterogénea, tamaños de pod mixtos — **el default moderno** | Un poco más de estado; necesita conteos precisos de peticiones activas |
| `RANDOM` | `RANDOM` | Elección aleatoria uniforme | Alto número de endpoints, sin necesidades de localidad | Sin conciencia de carga |
| `PASSTHROUGH` | `CLUSTER_PROVIDED` | Reenvía a la IP de destino original; sin LB | Headless services, el cliente ya eligió la IP | Evita por completo el LB de subset/endpoint |
| `consistentHash` | `RING_HASH` / `MAGLEV` | Hash determinista → la misma clave cae en el mismo endpoint | **Afinidad de sesión**, cachés sticky, estado shardeado | Rebalancea ante rotación de endpoints; las claves calientes crean pods calientes |

> **Nota de versión:** el algoritmo de balanceo de carga por defecto de Istio cambió de `ROUND_ROBIN` a `LEAST_REQUEST` en **Istio 1.21**. En control planes más viejos el default es `ROUND_ROBIN`. Nunca dependas del default implícito en producción —declaralo.

### Afinidad de sesión con consistent-hash

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: cart
  namespace: shop
spec:
  host: cart.shop.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:               # sticky by cookie; Istio injects it if absent
          name: SESSION
          ttl: 3600s
        minimumRingSize: 1024     # ringHash granularity; larger = smoother distribution, more memory
```

Opciones de clave de hash (elegí exactamente una): `httpHeaderName`, `httpCookie`, `httpQueryParameterName`, `useSourceIp: true`, o el ajuste de `maglev`/`ringHash`. `useSourceIp` es común para gRPC donde no existen las cookies; pero detrás de un load balancer que hace SNAT, toda petición parece venir de una sola IP y la afinidad colapsa a un único pod —verificá primero el manejo de `x-forwarded-for`.

### Balanceo de carga con conciencia de localidad

Para clusters multizona, ponderá el tráfico hacia endpoints de la misma zona y hacé failover entre zonas:

```yaml
  trafficPolicy:
    loadBalancer:
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
        failover:                 # if local zone is unhealthy, spill to the named region
        - from: us-east-1
          to: us-east-2
    outlierDetection:             # REQUIRED — locality failover only triggers when outlier detection ejects the local zone
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
```

**Trampa:** el failover de `localityLbSetting` es un no-op salvo que `outlierDetection` esté configurado. Envoy solo se desplaza hacia la localidad de failover una vez que los endpoints locales quedan marcados como no sanos, y solo la outlier detection (o los active health checks, que Istio no expone aquí) los marca así.

---

## 5. Connection pool — circuit breaking *activo*

`connectionPool` fija techos duros. Cuando el tráfico los excede, Envoy falla rápido con `503 UO` (**U**pstream **O**verflow) en vez de encolar o abrir sockets sin límite. Esta es la mitad *activa* del circuit breaking —actúa sobre el volumen, antes de que ocurra cualquier error.

| Campo | Capa | Significado | Default de Envoy | Default de Istio |
|---|---|---|---|---|
| `tcp.maxConnections` | L4 | Máximo de conexiones TCP concurrentes al cluster upstream | 1024 | efectivamente sin límite (2³²-1) |
| `tcp.connectTimeout` | L4 | Timeout de connect TCP | 10s | 10s |
| `tcp.tcpKeepalive.{time,interval,probes}` | L4 | Ajuste de SO_KEEPALIVE | off | off |
| `http.http1MaxPendingRequests` | L7 | Máximo de peticiones encoladas esperando una conexión (HTTP/1.1) | 1024 | efectivamente sin límite |
| `http.http2MaxRequests` | L7 | Máximo de peticiones concurrentes en todas las conexiones | 1024 | efectivamente sin límite |
| `http.maxRequestsPerConnection` | L7 | Peticiones antes de reciclar una conexión (`1` = desactiva keep-alive) | 0 (ilimitado) | 0 |
| `http.maxRetries` | L7 | Máximo de reintentos concurrentes (presupuesto a nivel de cluster) | 3 | efectivamente sin límite |
| `http.idleTimeout` | L7 | Tiempo inactivo antes de cerrar una conexión upstream | 1h | 1h |
| `http.h2UpgradePolicy` | L7 | Auto-upgrade HTTP/1.1 → HTTP/2 | DEFAULT | DEFAULT |

> **El hecho no obvio más importante de este tema:** Istio **no** hereda los pequeños defaults `1024`/`3` de Envoy. Salvo que configures `connectionPool`, los límites son efectivamente *ilimitados* y la outlier detection está *apagada*. Un cluster sin DestinationRule **no tiene circuit breaking en absoluto**. "Es Istio, así que está protegido" es falso.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: ratings-cb
  namespace: default
spec:
  host: ratings.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100        # cap L4 fan-out
        connectTimeout: 250ms
        tcpKeepalive:
          time: 7200s
          interval: 75s
          probes: 9
      http:
        http1MaxPendingRequests: 10   # tiny pending queue → shed the spike fast
        http2MaxRequests: 100
        maxRequestsPerConnection: 10  # recycle connections, avoids stale LB state
        maxRetries: 3
        idleTimeout: 30s
```

Cuando se supera `http1MaxPendingRequests: 10`, los llamadores ven `503` con response flag `UO` y Envoy incrementa `upstream_rq_pending_overflow`. Eso es el pool haciendo su trabajo —el rechazo rápido es la característica, no un bug.

---

## 6. Outlier detection — circuit breaking *pasivo*

`outlierDetection` expulsa endpoints individuales que se portan mal. Es *pasivo*: observa los resultados reales de las peticiones (5xx, fallos de conexión) y quita el host ofensor del pool de LB por un período de enfriamiento. Esto es lo que impide que un pod enfermo envenene el servicio.

| Campo | Significado | Default de Istio |
|---|---|---|
| `consecutive5xxErrors` | Expulsar tras N `5xx` consecutivos (incluye los 503 generados localmente salvo que se separen) | 5 (cuando el bloque está presente) |
| `consecutiveGatewayErrors` | Expulsar tras N `502/503/504` consecutivos únicamente | — |
| `consecutiveLocalOriginFailures` | Expulsar tras N fallos/resets de conexión (necesita `splitExternalLocalOriginErrors: true`) | — |
| `interval` | Cada cuánto corre el barrido de expulsión | 10s |
| `baseEjectionTime` | Duración mínima de expulsión; multiplicada por el conteo de expulsiones (back-off) | 30s |
| `maxEjectionPercent` | Techo del % de endpoints que pueden expulsarse a la vez | 10% |
| `minHealthPercent` | Por debajo de este % sano, la outlier detection se desactiva para no expulsar a los últimos sobrevivientes | 0 (off) |
| `splitExternalLocalOriginErrors` | Separa los fallos a nivel de conexión (local) de los 5xx upstream (external) | false |

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews-resilient
  namespace: default
spec:
  host: reviews.default.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 50        # allow up to half the pool to be ejected
      minHealthPercent: 20          # ...but stop ejecting once <20% remain healthy
      splitExternalLocalOriginErrors: true
      consecutiveLocalOriginFailures: 3
  subsets:
  - name: v1
    labels: { version: v1 }
  - name: v2
    labels: { version: v2 }
  - name: v3
    labels: { version: v3 }
```

### La trampa del panic-threshold

Envoy tiene un `healthy_panic_threshold` separado, **default 50 %**. Si la outlier detection expulsa tantos endpoints que quedan menos del 50 % sanos, Envoy entra en *modo pánico* y **balancea la carga sobre TODOS los endpoints, incluidos los expulsados** —bajo la teoría de que "todo está roto, así que expulsar no tiene sentido". El síntoma visible es: configuraste circuit breaking, la mayoría de los pods se ponen mal, y el tráfico *igual* fluye hacia pods malos. Dos palancas interactúan:

- `maxEjectionPercent` limita cuántos *podés* expulsar (default de solo 10 % —a menudo demasiado bajo; expulsás un pod y parás).
- El modo pánico anula la expulsión cuando la fracción *sana* es demasiado baja.

Para un servicio de 3 réplicas, `maxEjectionPercent: 10` significa que nunca podés expulsar ni un pod (el 10 % de 3 redondea a 0). Fijalo explícitamente. Ajustalo contra tu conteo de réplicas.

---

## 7. TLS y mTLS — el lado cliente de la conexión

`trafficPolicy.tls` controla lo que hace el sidecar del **cliente** al originar la conexión. Esta es la contraparte de `PeerAuthentication`, que controla lo que acepta el sidecar del **servidor**. Equivocarse en la interacción es la causa número uno de `503 UF` en una mesh recién asegurada.

| `tls.mode` | Qué hace el sidecar del cliente | Certificados |
|---|---|---|
| `DISABLE` | Texto plano | ninguno |
| `SIMPLE` | Origina TLS unidireccional (valida el servidor, sin cert de cliente) — **TLS origination** hacia HTTPS externo | opcional `caCertificates` / `credentialName` |
| `MUTUAL` | Mutual TLS con certs **provistos por el operador** | `clientCertificate` + `privateKey` + `caCertificates` |
| `ISTIO_MUTUAL` | Mutual TLS usando los certs de workload **auto-provistos** por Istio (SPIFFE) | gestionado por Istio |

### Interacción con auto-mTLS y PeerAuthentication

Desde Istio 1.5, **auto-mTLS** configura los sidecars del cliente para usar `ISTIO_MUTUAL` automáticamente siempre que el destino tenga un sidecar —no necesitás un DR para que funcione mTLS. La sutileza:

- Un DestinationRule desactiva auto-mTLS **solo cuando fija explícitamente `tls.mode`**. Un DR que fija `loadBalancer`/`connectionPool` pero ningún bloque `tls` deja auto-mTLS intacto.
- `tls.mode: DISABLE` contra un servidor cuyo `PeerAuthentication` es `STRICT` → el servidor rechaza el texto plano → **reset de conexión → `503 UF`**. Este es el clásico corte autoinfligido: alguien agrega un DR para balanceo de carga, copia un snippet `tls: DISABLE` de un blog y silenciosamente descarta el mTLS de la mesh en esa ruta.

| `PeerAuthentication` del servidor | `tls.mode` del DR del cliente | Resultado |
|---|---|---|
| STRICT | (ninguno / auto-mTLS) | ✅ mTLS |
| STRICT | ISTIO_MUTUAL | ✅ mTLS (explícito) |
| STRICT | DISABLE | ❌ `503 UF` — el servidor rechaza texto plano |
| PERMISSIVE | DISABLE | ✅ texto plano (el servidor acepta ambos) |
| DISABLE | ISTIO_MUTUAL | ❌ el handshake falla — el servidor solo habla texto plano |

### TLS origination hacia un servicio externo

Dejá que el sidecar termine/origine TLS para que la app hable HTTP plano internamente mientras el cable es HTTPS:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-payments
  namespace: default
spec:
  hosts:
  - api.payments.example.com
  ports:
  - number: 443
    name: https
    protocol: TLS
  - number: 80
    name: http
    protocol: HTTP           # app calls port 80 in plaintext
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: external-payments-tls
  namespace: default
spec:
  host: api.payments.example.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 80
      tls:
        mode: SIMPLE          # sidecar upgrades the plaintext :80 call to real TLS :443 upstream
        sni: api.payments.example.com
```

### Overrides a nivel de puerto

`portLevelSettings` permite que un servicio exponga, por ejemplo, un puerto de métricas en texto plano y un puerto de datos con mTLS bajo un solo DestinationRule:

```yaml
  trafficPolicy:
    tls: { mode: ISTIO_MUTUAL }        # default for all ports
    portLevelSettings:
    - port: { number: 9090 }           # metrics port opts out
      tls: { mode: DISABLE }
```

---

## 8. Manifiesto de producción completo — todo compuesto

Un único `DestinationRule` sintácticamente completo que combina subsets, LB, circuit breaking activo + pasivo, mTLS y un override por subset:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews-prod
  namespace: default
spec:
  host: reviews.default.svc.cluster.local
  exportTo:
  - "."                                     # keep this DR private to the default namespace
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL                     # mesh mTLS, explicit
    loadBalancer:
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
    connectionPool:
      tcp:
        maxConnections: 200
        connectTimeout: 250ms
        tcpKeepalive:
          time: 7200s
          interval: 75s
      http:
        http1MaxPendingRequests: 32
        http2MaxRequests: 200
        maxRequestsPerConnection: 100
        maxRetries: 3
        idleTimeout: 30s
        h2UpgradePolicy: UPGRADE
    outlierDetection:
      consecutive5xxErrors: 5
      consecutiveGatewayErrors: 5
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
      minHealthPercent: 20
      splitExternalLocalOriginErrors: true
      consecutiveLocalOriginFailures: 3
  subsets:
  - name: v1
    labels: { version: v1 }
  - name: v2
    labels: { version: v2 }
  - name: v3
    labels: { version: v3 }
    trafficPolicy:                           # v3 is a sticky, cookie-affine canary
      loadBalancer:
        consistentHash:
          httpCookie:
            name: reviews-session
            ttl: 0s
      connectionPool:
        http:
          http1MaxPendingRequests: 8         # tighter pool for the unproven version
```

Aplicá y confirmá la aceptación:

```console
$ kubectl apply -f reviews-prod.yaml
destinationrule.networking.istio.io/reviews-prod created

$ istioctl analyze -n default
✔ No validation issues found when analyzing namespace: default.
```

---

## 9. Verificación y diagnóstico de fallos

Una configuración que hace `kubectl apply` limpiamente igual puede estar mal. La prueba está en la config de Envoy que Pilot realmente empujó, no en el YAML.

### Paso 1 — Confirmar que los clusters y su política existen

```console
$ istioctl proxy-config cluster deploy/productpage-v1 -n default \
    --fqdn reviews.default.svc.cluster.local
SERVICE FQDN                          PORT  SUBSET  DIRECTION   TYPE  DESTINATION RULE
reviews.default.svc.cluster.local     9080  -       outbound    EDS   reviews-prod.default
reviews.default.svc.cluster.local     9080  v1      outbound    EDS   reviews-prod.default
reviews.default.svc.cluster.local     9080  v2      outbound    EDS   reviews-prod.default
reviews.default.svc.cluster.local     9080  v3      outbound    EDS   reviews-prod.default
```

Una columna `DESTINATION RULE` vacía, o filas de subset faltantes, significa que el DR no está enlazando (`host` incorrecto, namespace incorrecto o alcance de `exportTo`). Inspeccioná la config efectiva de circuit-breaker y LB:

```console
$ istioctl proxy-config cluster deploy/productpage-v1 -n default \
    --fqdn reviews.default.svc.cluster.local --subset v3 -o json \
  | jq '{lb: .lbPolicy, cb: .circuitBreakers.thresholds[0], od: .outlierDetection}'
{
  "lb": "RING_HASH",
  "cb": {
    "maxConnections": 200,
    "maxPendingRequests": 8,
    "maxRequests": 200,
    "maxRetries": 3
  },
  "od": {
    "consecutive5xx": 5,
    "interval": "5s",
    "baseEjectionTime": "30s",
    "maxEjectionPercent": 50
  }
}
```

Esto prueba que el override del subset tuvo efecto (`RING_HASH` y `maxPendingRequests: 8`, no el `LEAST_REQUEST`/`32` a nivel de host).

### Paso 2 — Observar la outlier detection expulsando un endpoint

```console
$ istioctl proxy-config endpoint deploy/productpage-v1 -n default \
    --cluster "outbound|9080|v1|reviews.default.svc.cluster.local"
ENDPOINT             STATUS       OUTLIER CHECK   CLUSTER
10.244.1.21:9080     HEALTHY      OK              outbound|9080|v1|reviews.default.svc.cluster.local
10.244.2.34:9080     UNHEALTHY    FAILED          outbound|9080|v1|reviews.default.svc.cluster.local
```

`OUTLIER CHECK: FAILED` = expulsado. Confirmá con el flag de salud de `/clusters` del admin de Envoy y el contador de aplicación:

```console
$ kubectl exec deploy/productpage-v1 -n default -c istio-proxy -- \
    curl -s localhost:15000/clusters | grep 'v1|reviews' | grep health_flags
outbound|9080|v1|reviews.default.svc.cluster.local::10.244.2.34:9080::health_flags::/failed_outlier_check

$ kubectl exec deploy/productpage-v1 -n default -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=v1.reviews.*outlier'
cluster.outbound|9080|v1|reviews.default.svc.cluster.local.outlier_detection.ejections_active: 1
cluster.outbound|9080|v1|reviews.default.svc.cluster.local.outlier_detection.ejections_enforced_total: 4
```

### Paso 3 — Confirmar que el connection pool está descargando

```console
$ kubectl exec deploy/productpage-v1 -n default -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=v3.reviews.*(overflow|pending)'
cluster.outbound|9080|v3|reviews.default.svc.cluster.local.upstream_rq_pending_overflow: 57
cluster.outbound|9080|v3|reviews.default.svc.cluster.local.upstream_cx_overflow: 12
cluster.outbound|9080|v3|reviews.default.svc.cluster.local.upstream_rq_pending_active: 8
```

`upstream_rq_pending_overflow: 57` = 57 peticiones rechazadas rápido con `503 UO`. Ese es el circuit breaker funcionando según diseño.

### Referencia de modos de fallo

| Síntoma | `response_flags` | Causa probable | Solución |
|---|---|---|---|
| `503 no healthy upstream` | `UH` | Todos los endpoints expulsados, o los labels del subset no coinciden con ningún pod | Revisá `proxy-config endpoint`; verificá el label `version` en los pods |
| `503 upstream connect error … reset before headers` | `UF` | Desajuste de mTLS — DR `DISABLE` vs `PeerAuthentication STRICT` | Quitá `tls: DISABLE` o poné `ISTIO_MUTUAL` |
| `503` bajo carga, `upstream_rq_pending_overflow` en aumento | `UO` | Techo del connection pool alcanzado (funcionando según diseño, o fijado demasiado bajo) | Subí `http1MaxPendingRequests` / `maxConnections` |
| `503 NR` / no cluster | `NR` | El VirtualService referencia un subset no definido en ningún DR | Agregá el subset; corré `istioctl analyze` |
| El tráfico sigue golpeando un pod conocido-malo | — | Modo pánico (<50 % sano) o `maxEjectionPercent` demasiado bajo (default 10 %) | Subí `maxEjectionPercent`; revisá el conteo de réplicas vs el umbral |
| Dos DR, uno ignorado silenciosamente | — | `DestinationRuleConflict` — mismo host desde dos namespaces | Consolidá; gana el DR más antiguo |
| La afinidad de sesión no se pega | — | `useSourceIp` detrás de un LB con SNAT, o el cliente descartó la cookie | Cambiá a `httpCookie`/`httpHeaderName`; revisá `x-forwarded-for` |

Terminá siempre con el analizador estático, que atrapa errores de subset/host/conflicto que Envoy solo mostraría en tiempo de petición:

```console
$ istioctl analyze -A
Error [IST0101] (VirtualService reviews.default) Referenced host+subset in "destination"
  not found: "reviews+v4"
Warning [IST0134] (DestinationRule reviews-prod.default) maxEjectionPercent (10) with 3
  replicas ejects 0 hosts; outlier detection is effectively disabled.
```

---

## 10. Referencias

- Istio — *Destination Rule* (API reference): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — *Traffic Management* concepts (VirtualService vs DestinationRule): https://istio.io/latest/docs/concepts/traffic-management/
- Istio — *Circuit Breaking* task (connectionPool + outlierDetection): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — *Locality Load Balancing*: https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/
- Istio — *Mutual TLS Migration* and auto-mTLS: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — *Egress TLS Origination*: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Istio — *Debugging Envoy and Istiod* (`istioctl proxy-config`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio 1.21 release notes — default load-balancer change to `LEAST_REQUEST`: https://istio.io/latest/news/releases/1.21.x/announcing-1.21/change-notes/
- Envoy — *Outlier detection* (panic threshold, ejection semantics): https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier
- Envoy — *Circuit breaking* (thresholds, `UO` overflow): https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking
- CNCF — *ICA Curriculum* (Traffic Management domain): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf