# 3.6 — Uso de funciones de resiliencia

*Circuit breaking · failover · outlier detection · timeouts · retries*

> **Peso en el examen: 5.** Este objetivo es donde Istio deja de ser "enrutamiento de tráfico" y se convierte en un **sustrato de gestión de fallos**. Cada palanca aquí es una perilla sobre el proxy Envoy embebido en el sidecar. Entender *a qué primitiva de Envoy* compila cada campo de Istio es la diferencia entre aprobar el examen y enviar una tormenta de retries a producción.

---

## 1. El problema de producción: una malla amplifica los fallos por defecto

Una service mesh inyecta un proxy en **cada** salto. Ese proxy reenviará alegremente una petición a un host que se está muriendo en silencio, reintentará una petición que estaba condenada desde la primera vez, y mantendrá una conexión abierta hacia un backend que nunca responderá. Sin configuración de resiliencia, la uniformidad de la malla trabaja *en tu contra* — un único pod degradado puede amplificarse hasta un brownout a nivel de toda la malla mediante tres mecanismos clásicos:

| Modo de fallo | Mecanismo | Síntoma |
|---|---|---|
| **Cascading failure** | Los hilos del llamador se bloquean sobre una dependencia lenta → el thread pool se agota → el llamador se vuelve lento → *sus* llamadores se agotan → frente de onda hacia arriba en el grafo de llamadas | Pico de latencia en toda la cadena de llamadas, sin un único pod "causa" |
| **Retry storm / metastable failure** | Un backend tiene un hipo; cada cliente reintenta N×; la carga efectiva se vuelve `(1+N)×` justo en el momento en que el backend está más débil → nunca se recupera aun después de que el gatillo desaparece | La carga se queda clavada alta después de que el fallo original ya se fue |
| **Gray failure** | Un pod pasa su liveness/readiness probe de Kubernetes (control plane) pero devuelve 503s al tráfico *real* (data plane) | k8s lo mantiene en la lista de Endpoints; el tráfico sigue golpeando un host roto |

Las cinco funciones de este objetivo mapean uno a uno sobre estos problemas:

- **Timeouts** acotan cuánto espera un llamador → rompen el *frente de onda de la cascada*.
- **Retries** enmascaran fallos transitorios → pero *deben estar acotados* o *son* la tormenta.
- **Circuit breaking** (límites del connection-pool) descarga carga antes de que un backend se vea sobrepasado → rompe el *bucle metastable*.
- **Outlier detection** es un chequeo de salud pasivo, del data-plane → atrapa el *gray failure* que la readiness probe se perdió.
- **Failover** (locality load balancing) redirige lejos de una zona/región no saludable → sobrevivir a una interrupción de infraestructura *parcial*.

Dos objetos de API contienen todo:

| Recurso | Posee | Config de Envoy a la que compila |
|---|---|---|
| **`VirtualService`** (`http.timeout`, `http.retries`) | Comportamiento de petición *por ruta* | **route** de Envoy (`route.timeout`, `route.retry_policy`) |
| **`DestinationRule`** (`trafficPolicy.connectionPool`, `.outlierDetection`, `.loadBalancer.localityLbSetting`) | Comportamiento *por cluster* (por host/subset upstream) | **cluster** de Envoy (`circuit_breakers`, `outlier_detection`, `lb_policy` + priorities) |

> **Modelo mental que el examen premia:** *Los retries y timeouts son propiedades de una petición (route). El circuit breaking, la outlier detection y el failover son propiedades de un destino (cluster).* Si no podés cambiar algo con un VirtualService, pertenece a un DestinationRule, y viceversa.

---

## 2. Timeouts

Por defecto **Istio no aplica ningún timeout de petición HTTP** (`0s` = deshabilitado). Este es el default más peligroso de la malla: un llamador esperará para siempre a un backend que se colgó a mitad de respuesta. Casi siempre querés configurar uno.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
    - reviews
  http:
    - route:
        - destination:
            host: reviews
            subset: v2
      timeout: 2s          # wall-clock budget for the ENTIRE request, retries included
```

**Mecánica:** el timeout es el presupuesto total observado por el sidecar del *llamador*. Cuando se dispara, Envoy resetea el stream upstream y devuelve `504 Gateway Timeout` downstream, estampando el flag de respuesta del access-log **`UT`** (Upstream Timeout). De forma crítica, `timeout` es el sobre para *todos* los intentos de retry — ver §3 para la interacción.

El override por petición mediante el header `x-envoy-upstream-rq-timeout-ms` está **deshabilitado por defecto** en Istio (`mesh.defaultConfig` no lo expone); no te apoyes en él en las respuestas del examen.

---

## 3. Retries

Istio instala una **política de retry por defecto aun si no configurás nada**: `attempts: 2` sobre el conjunto de condiciones `connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes`. Por eso "nunca configuré retries pero veo 3 peticiones golpear mi backend" es normal. Sobreescribila explícitamente por ruta:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
  namespace: bookinfo
spec:
  hosts:
    - ratings
  http:
    - route:
        - destination:
            host: ratings
            subset: v1
      timeout: 3s
      retries:
        attempts: 3                       # up to 3 RE-tries (4 total attempts)
        perTryTimeout: 800ms              # budget per individual attempt
        retryOn: >-
          connect-failure,refused-stream,unavailable,gateway-error,retriable-4xx,5xx
        retryRemoteLocalities: true       # allow retries to cross into another locality
```

### La aritmética de presupuesto que hace tropezar a los ingenieros

`attempts × perTryTimeout` debe caber dentro del `timeout` global, o los retries posteriores nunca se disparan — el sobre de wall-clock se cierra primero.

| `timeout` global | `attempts` | `perTryTimeout` | Comportamiento efectivo |
|---|---|---|---|
| `3s` | 3 | `800ms` | ✅ Hasta ~3.2s de intentos caben dentro de 3s → los retries 1–2 se disparan, el 3ro puede ser cortado por el sobre |
| `1s` | 3 | `800ms` | ⚠️ Solo ~1 intento + una astilla → el 2do/3er retry silenciosamente nunca ocurren |
| `10s` | 3 | *(sin definir)* | 🔥 Cada intento hereda el timeout global de 10s → 3 intentos colgados = 30s de carga amplificada; **nunca dejes `perTryTimeout` sin definir con retries** |

### Condiciones de `retryOn` (valores de `retry_on` de Envoy)

| Valor | Reintenta cuando… | Riesgo de idempotencia |
|---|---|---|
| `connect-failure` | El connect TCP al upstream falló (nunca llegó a la app) | **Seguro** |
| `refused-stream` | El upstream envió HTTP/2 `REFUSED_STREAM` (no procesado) | **Seguro** |
| `reset` | El upstream reseteó el stream antes/sin respuesta | Más o menos seguro |
| `unavailable` | Estado gRPC `UNAVAILABLE` (14) | Depende |
| `gateway-error` | 502, 503, 504 | **Peligroso** — la petición puede haber sido procesada |
| `retriable-4xx` | 409 (configurable) | Depende |
| `5xx` | cualquier 5xx | **El más peligroso** — incluye 500 de una petición que mutó estado |
| `retriable-status-codes` | códigos en `x-envoy-retriable-status-codes` | Explícito |
| `retriable-headers` | el upstream seteó `x-envoy-retriable-header-names` | Opt-in del servidor |

> **Regla SRE:** reintentá **solo sobre fallos que demostrablemente nunca llegaron a la lógica de aplicación** (`connect-failure`, `refused-stream`, `reset`) para endpoints no idempotentes. Reservá `5xx`/`gateway-error` para lecturas (`GET`). Un retry general sobre `5xx` en un `POST /charge` cobra doble a los clientes.

---

## 4. Circuit breaking — el connection pool

El "circuit breaking" en Istio es la estrofa **`connectionPool`** de un DestinationRule. Compila a los **`circuit_breakers`** de Envoy sobre el cluster. Estos son topes duros; cuando una petición excedería un límite, Envoy **inmediatamente** devuelve `503` con el flag de respuesta **`UO`** (Upstream Overflow) y el header `x-envoy-overloaded: true` — falla *rápido* en vez de encolar. Ese fast-fail es el punto entero: descargar carga protege al backend del bucle metastable de retries.

Por defecto Istio setea estos topes en `2^32-1` (`4294967295`) — **efectivamente ilimitado, es decir, el circuit breaking está APAGADO hasta que lo configurás.**

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-cb
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100          # max concurrent TCP conns to the whole cluster
        connectTimeout: 250ms        # TCP connect budget (compiles to cluster connect_timeout)
        tcpKeepalive:
          time: 7200s
          interval: 75s
          probes: 9
      http:
        http1MaxPendingRequests: 100 # queued (not yet dispatched) HTTP/1.1 requests
        http2MaxRequests: 1000       # max concurrent requests (HTTP/2 AND the effective HTTP/1 request cap)
        maxRequestsPerConnection: 10 # >1; forces conn recycling (defeats broken keep-alive / helps rebalancing). 1 = disable keep-alive
        maxRetries: 3                # max concurrent retries across the cluster (retry budget, NOT per-request attempts)
        idleTimeout: 30s             # close upstream conn after idle
        h2UpgradePolicy: UPGRADE
```

### Semántica de campos que no debés confundir

| Campo | Primitiva de Envoy | Qué limita | Flag de overflow |
|---|---|---|---|
| `tcp.maxConnections` | `max_connections` | Conexiones L4 concurrentes | `upstream_cx_overflow` |
| `http.http1MaxPendingRequests` | `max_pending_requests` | Peticiones **esperando una conexión** | `upstream_rq_pending_overflow` → 503 `UO` |
| `http.http2MaxRequests` | `max_requests` | Peticiones **en vuelo** concurrentes (también topa HTTP/1) | `upstream_rq_overflow` → 503 `UO` |
| `http.maxRetries` | `max_retries` | Retries concurrentes a nivel de malla hacia este cluster | `upstream_rq_retry_overflow` |
| `http.maxRequestsPerConnection` | `max_requests_per_connection` | Peticiones antes de que una conexión se recicle | — |

> **Trampa de examen:** `maxRetries` (DestinationRule, *presupuesto* de retry a nivel de cluster) **no** es `retries.attempts` (VirtualService, *cantidad* de retry por petición). Uno topa cuántos retries pueden estar *en vuelo simultáneamente* a través de todos los llamadores; el otro topa cuántas veces se reintenta una *única* petición.

### Disparando el breaker — lab reproducible

Desplegá `httpbin` con un breaker agresivo, luego sobrecargalo con `fortio`.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin-cb
  namespace: default
spec:
  host: httpbin
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1
      http:
        http1MaxPendingRequests: 1
        maxRequestsPerConnection: 1
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 3m
      maxEjectionPercent: 100
```

```console
$ kubectl apply -f httpbin-cb.yaml
destinationrule.networking.istio.io/httpbin-cb created

$ export FORTIO=$(kubectl get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')

# 2 concurrent connections, 20 requests — exceeds maxConnections=1 + pending=1
$ kubectl exec "$FORTIO" -c fortio -- \
    /usr/bin/fortio load -c 2 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
07:41:12 I httprunner.go:82> Starting http test for http://httpbin:8000/get with 2 threads at -1.0 qps
Code 200 : 12 (60.0 %)
Code 503 : 8 (40.0 %)
Response Header Sizes : count 20 avg 138.6 ...
All done 20 calls (plus 0 warmup) 3.２ ms avg, 501.2 qps
```

El 40% de `503`s es el breaker disparándose. Confirmalo en el origen — las stats de Envoy del *llamador*, no las del servidor:

```console
$ kubectl exec "$FORTIO" -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=httpbin.*(overflow|pending)' 
cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_cx_overflow: 5
cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_overflow: 8
cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_total: 20
```

`upstream_rq_pending_overflow: 8` es la verdad de fondo — 8 peticiones fueron rechazadas porque la cola de pendientes (profundidad 1) estaba llena. **Este contador es tu SLI de circuit-breaker.** Alertá sobre su tasa de cambio.

---

## 5. Outlier detection — chequeo de salud pasivo

La outlier detection es la respuesta de la malla al **gray failure**: un host que Kubernetes todavía lista como Ready pero que devuelve errores al tráfico real. Envoy observa los resultados de peticiones en vivo y **expulsa** (temporalmente lo remueve del pool de load-balancing) cualquier host que se comporte mal. Es *pasivo* — sin probes sintéticos; lee el tráfico que ya está fluyendo.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-od
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 5          # eject after 5 consecutive 5xx (or gRPC-mapped) errors
      consecutiveGatewayErrors: 3      # subset of 5xx: 502/503/504 + connect failures
      interval: 10s                    # sweep period: how often ejection is evaluated
      baseEjectionTime: 30s            # first ejection = 30s; multiplies each re-ejection (30s,60s,90s…)
      maxEjectionPercent: 50           # NEVER eject more than 50% of the pool (availability floor)
      minHealthPercent: 40             # below 40% healthy → PANIC MODE: LB to ALL hosts (see below)
      splitExternalLocalOriginErrors: false
```

### Cómo funciona realmente la expulsión (internals de Envoy)

1. En cada `interval`, el motor de outlier-detection de Envoy barre los hosts del cluster.
2. Un host que alcanzó `consecutive5xxErrors` seguidos es **expulsado** por `baseEjectionTime`.
3. La duración de la expulsión es `baseEjectionTime × (número de veces que este host fue expulsado)` — los reincidentes se quedan afuera **más tiempo** (backoff).
4. Después de que el temporizador expira el host vuelve al pool; si vuelve a fallar es expulsado por un intervalo más largo.
5. **`maxEjectionPercent` es una barandilla dura.** Aun si cada host está fallando, Envoy se niega a expulsar más que esta fracción — de lo contrario la outlier detection tumbaría un servicio que está *globalmente* degradado (p. ej. una mala config downstream causando 500s por todos lados), convirtiendo una interrupción parcial en una total.

### Umbral de pánico — la válvula de seguridad contraintuitiva

`minHealthPercent` (el *healthy panic threshold* de Envoy, default 50%). Si las expulsiones dejan caer el pool saludable **por debajo** de esta fracción, Envoy entra en **modo pánico** y **balancea la carga a través de *todos* los hosts, incluyendo los expulsados.** La lógica: si la mayor parte de la flota parece no saludable, el problema es más probablemente tu *señal de salud* que la flota — mejor rociar tráfico por todos lados que martillar los últimos uno o dos hosts "saludables" hasta el suelo. Vigilá el stat `cluster.<name>.lb_healthy_panic`.

### `consecutive5xxErrors` vs `consecutiveGatewayErrors` vs local-origin

| Configuración | Cuenta como un "error" |
|---|---|
| `consecutiveGatewayErrors` | Solo errores **Gateway**: `502`, `503`, `504`, más connect failures/timeouts |
| `consecutive5xxErrors` | **Todos** los anteriores **más** `500`, `501`, `505` de aplicación, y códigos de error gRPC |
| `consecutiveLocalOriginFailures` | Solo fallos *originados localmente* (connect timeout, reset) — nunca un 5xx a nivel de app. Requiere `splitExternalLocalOriginErrors: true` |

`splitExternalLocalOriginErrors: true` separa **"la red/conexión al host falló"** (local origin) de **"el host respondió, pero con un 5xx"** (external origin). Activalo cuando querés expulsar un host solo por problemas de *conectividad* y no culparlo por 500s legítimos de aplicación que meramente retransmitió.

### Verificando una expulsión — el chequeo definitivo

`istioctl proxy-config endpoint` muestra la membresía EDS pero **no** el estado de outlier en vivo. La vista autoritativa es la página de admin `/clusters` de Envoy, donde un host expulsado lleva `health_flags::/failed_outlier_check`:

```console
$ kubectl exec "$FORTIO" -c istio-proxy -- \
    pilot-agent request GET clusters | grep 'httpbin.*health_flags'
outbound|8000||httpbin.default.svc.cluster.local::10.244.1.37:80::health_flags::/failed_outlier_check
outbound|8000||httpbin.default.svc.cluster.local::10.244.2.19:80::health_flags::healthy

# Ejection counters
$ kubectl exec "$FORTIO" -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=httpbin.*outlier'
cluster.outbound|8000||httpbin...outlier_detection.ejections_active: 1
cluster.outbound|8000||httpbin...outlier_detection.ejections_enforced_consecutive_5xx: 1
cluster.outbound|8000||httpbin...outlier_detection.ejections_detected_consecutive_5xx: 1
cluster.outbound|8000||httpbin...outlier_detection.ejections_overflow: 0
```

`ejections_active: 1` = un host está actualmente afuera. `ejections_overflow` se incrementa cuando `maxEjectionPercent` bloqueó una expulsión que *de otro modo* habría ocurrido — una señal de que tu backend entero está no saludable, no un solo host.

---

## 6. Failover — load balancing consciente de la localidad

El failover es **outlier detection aplicada a través de la topología**. Cuando la outlier detection expulsa los hosts en la *propia* zona de un llamador, Istio usa los **priority levels** de Envoy para derramar tráfico hacia la siguiente localidad más cercana — misma región otra zona, luego otra región — en vez de fallar. **El failover requiere que `outlierDetection` esté configurada; sin ella no hay señal de salud que dispare el derrame.**

La localidad se deriva de labels estándar de nodos, propagados a cada endpoint:

| Nivel de localidad | Label del nodo |
|---|---|
| Region | `topology.kubernetes.io/region` |
| Zone | `topology.kubernetes.io/zone` |
| Sub-zone | `topology.istio.io/subzone` |

### 6a. Failover región-a-región

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-failover
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    outlierDetection:                 # MANDATORY for failover to activate
      consecutive5xxErrors: 5
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
    loadBalancer:
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
        failover:
          - from: us-west-1
            to: us-east-1             # if us-west-1 is unhealthy, fail over to us-east-1
          - from: us-east-1
            to: us-west-1
```

### 6b. Distribución ponderada (split, no failover)

Usá `distribute` para *deliberadamente* repartir tráfico (p. ej. 80% zona local / 20% zona par para capacidad caliente), independiente de la salud:

```yaml
    loadBalancer:
      localityLbSetting:
        enabled: true
        distribute:
          - from: us-west-1/us-west-1a/*
            to:
              "us-west-1/us-west-1a/*": 80
              "us-west-1/us-west-1b/*": 20
```

### 6c. `failoverPriority` — ordenar por coincidencia de labels

`failoverPriority` construye priority levels de Envoy contando labels coincidentes — los endpoints que comparten más labels con el llamador obtienen mayor prioridad:

```yaml
    loadBalancer:
      localityLbSetting:
        enabled: true
        failoverPriority:
          - "topology.kubernetes.io/region"
          - "topology.kubernetes.io/zone"
          - "topology.istio.io/subzone"
```

Un endpoint que coincide region+zone+subzone es priority 0; region+zone es priority 1; solo region es priority 2; el resto priority 3. Envoy envía tráfico a priority 0 hasta que su fracción saludable cae, luego sangra hacia priority 1, y así sucesivamente. Este es el failover suave y gradual que querés.

| Perilla | Comportamiento | ¿Guiado por salud? |
|---|---|---|
| `failover` | Mapa explícito de fallback región→región | ✅ disparado por outlier detection |
| `failoverPriority` | Ordenar localidades por profundidad de coincidencia de labels | ✅ derrame gradual por prioridad |
| `distribute` | Reparto ponderado fijo a través de localidades | ❌ estático, siempre aplicado |

Confirmá que las prioridades y la ponderación por salud llegaron al sidecar:

```console
$ istioctl proxy-config endpoint "$FORTIO" \
    --cluster "outbound|9080||reviews.bookinfo.svc.cluster.local" -o json \
  | jq -r '.[].hostStatuses[] | "\(.address.socketAddress.address)  weight=\(.weight)  \(.healthStatus.edsHealthStatus)"'
10.0.1.12  weight=1  HEALTHY
10.0.1.13  weight=1  HEALTHY
10.0.2.44  weight=1  HEALTHY   # priority-1 (peer zone) endpoint, dormant until local ejected
```

---

## 7. Poniéndolo todo junto — un destino totalmente resiliente

Un par DestinationRule + VirtualService de producción combinando las cinco palancas. Esta es la forma a reproducir de memoria para el examen.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payments
  namespace: shop
spec:
  host: payments.shop.svc.cluster.local
  trafficPolicy:
    connectionPool:                 # 4 & circuit breaking
      tcp:
        maxConnections: 200
        connectTimeout: 200ms
      http:
        http1MaxPendingRequests: 64
        http2MaxRequests: 512
        maxRequestsPerConnection: 20
        maxRetries: 16
        idleTimeout: 30s
    outlierDetection:               # 5 & passive health + 6 failover trigger
      consecutiveGatewayErrors: 5
      consecutive5xxErrors: 10
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
      minHealthPercent: 30
      splitExternalLocalOriginErrors: true
      consecutiveLocalOriginFailures: 3
    loadBalancer:                   # 6 failover
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
        failoverPriority:
          - "topology.kubernetes.io/region"
          - "topology.kubernetes.io/zone"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payments
  namespace: shop
spec:
  hosts:
    - payments.shop.svc.cluster.local
  http:
    - route:
        - destination:
            host: payments.shop.svc.cluster.local
      timeout: 2s                    # 2 timeout — total envelope
      retries:                       # 3 retries — SAFE conditions only (payments = non-idempotent)
        attempts: 2
        perTryTimeout: 750ms
        retryOn: connect-failure,refused-stream,reset
        retryRemoteLocalities: false # do NOT cross localities on retry for a write path
```

Notá las decisiones deliberadas: las **lecturas** usarían `retryOn: 5xx,gateway-error` y `retryRemoteLocalities: true`; esta ruta de **escritura** reintenta solo sobre fallos que nunca llegaron a la lógica de aplicación y nunca cruza una región en el retry.

---

## 8. Verificación y diagnóstico de fallos

### 8.1 Anillo decodificador de flags de respuesta

Habilitá los access logs (`meshConfig.accessLogFile: /dev/stdout`) y leé el flag en `%RESPONSE_FLAGS%`. Este es el camino más rápido del síntoma a la causa raíz.

| Flag | Significado | Qué función de resiliencia |
|---|---|---|
| `UO` | Upstream **O**verflow | **Circuit breaker** (connection pool) se disparó |
| `UH` | Sin upstream saludable — todos los hosts expulsados o ausentes | **Outlier detection** expulsó todo (o Endpoints vacío) |
| `UT` | Upstream **T**imeout | **Timeout** (global o per-try) se disparó |
| `URX` | Upstream **R**etry limit e**X**ceeded | **Retries** agotados (presupuesto `attempts` o `maxRetries`) |
| `UF` | Upstream connection **F**ailure | Connect falló (→ reintentable con `connect-failure`) |
| `UC` | Upstream **C**onnection termination | El backend reseteó la conexión a mitad de respuesta |
| `NR` | **N**o **R**oute | Hueco de VirtualService/enrutamiento — *no* es un problema de resiliencia; un bug de config |

```console
$ kubectl logs "$FORTIO" -c istio-proxy | tail -3
[2026-08-08T07:52:01.442Z] "GET /get HTTP/1.1" 503 UO ... "-" "fortio.org/fortio" ... upstream_reset_before_response_started{overflow}
[2026-08-08T07:52:01.501Z] "GET /get HTTP/1.1" 200 -  ...
[2026-08-08T07:52:02.010Z] "GET /get HTTP/1.1" 504 UT ... upstream_response_timeout
```

`503 UO` → circuit breaker. `504 UT` → timeout. Nunca adivines; leé el flag.

### 8.2 ¿Qué compiló a Envoy? (`istioctl`)

```console
# Is the DestinationRule/VirtualService valid & consistent?
$ istioctl analyze -n shop
✔ No validation issues found when analyzing namespace: shop.

# Did the circuit breaker + outlier config actually reach the cluster?
$ istioctl proxy-config cluster "$FORTIO" --fqdn payments.shop.svc.cluster.local -o json \
  | jq '.[0] | {maxConnections:.circuitBreakers.thresholds[0].maxConnections,
                maxPending:.circuitBreakers.thresholds[0].maxPendingRequests,
                outlier:.outlierDetection}'
{
  "maxConnections": 200,
  "maxPending": 64,
  "outlier": {
    "consecutive5xx": 10,
    "interval": "10s",
    "baseEjectionTime": "30s",
    "maxEjectionPercent": 50,
    "enforcingConsecutiveGatewayErrors": 100
  }
}

# Did the route timeout & retry policy reach the route?
$ istioctl proxy-config route "$FORTIO" --name 9080 -o json \
  | jq '.[].virtualHosts[].routes[].route | {timeout, retry:.retryPolicy}'
{
  "timeout": "2s",
  "retry": { "retryOn": "connect-failure,refused-stream,reset",
             "numRetries": 2, "perTryTimeout": "0.750s" }
}
```

Si `istioctl proxy-config` muestra los valores pero el comportamiento está mal, la config *llegó* a Envoy — mirá la carga y las stats. Si **no** los muestra, el FQDN del host o el namespace del DestinationRule está mal, o un DR competidor está ganando (`istioctl analyze` advierte sobre DRs en conflicto para el mismo host).

### 8.3 Los cuatro SLIs a graficar y alertar

| Síntoma | Stat de Envoy (prefijo `cluster.outbound|<port>||<fqdn>.`) | Qué significa un valor en aumento |
|---|---|---|
| El breaker descarga carga | `upstream_rq_pending_overflow`, `upstream_cx_overflow` | Pool demasiado chico **o** backend demasiado lento — subí los límites o escalá el backend |
| Hosts siendo expulsados | `outlier_detection.ejections_active` / `..._enforced_total` | Un pod (o toda la flota) está fallando |
| Piso de disponibilidad alcanzado | `outlier_detection.ejections_overflow` | `maxEjectionPercent` bloqueó expulsiones → degradación *global* |
| Retries amplificando carga | `upstream_rq_retry`, `upstream_rq_retry_overflow` | Presupuesto de retry saturado — se está formando una tormenta |

### 8.4 Firmas de fallo comunes y arreglos

| Lo que observás | Causa raíz | Arreglo |
|---|---|---|
| La latencia P99 colapsa al valor del `timeout`, `UT` por todos lados | El `timeout` global es más corto que el P99 legítimo | Subí `timeout`, o arreglá el backend lento — no simplemente reintentes por encima |
| `UO` bajo carga normal | Connection pool dimensionado para *idle*, no para *pico* | Dimensioná `maxConnections`/`http2MaxRequests` a la concurrencia pico, no al promedio |
| `503 UH`, ningún host saludable, todo el servicio caído tras un mal deploy | La outlier detection expulsó *cada* pod porque *todos* devuelven 500 (mala release) | Esto es protección por diseño; el modo pánico de `maxEjectionPercent`/`minHealthPercent` mantuvo *algo* de tráfico fluyendo. Rollback del deploy |
| El backend nunca se recupera tras un blip | Retries agresivos sobre `5xx` crearon una retry storm | Restringí `retryOn` a condiciones seguras; agregá un presupuesto `maxRetries`; agregá un circuit breaker |
| El failover nunca se dispara | `localityLbSetting` presente pero **sin** `outlierDetection` | Agregá outlier detection — es la señal de salud de la que depende el failover |
| Dos DestinationRules, config silenciosamente ignorada | DRs en conflicto para el mismo host | `istioctl analyze` (advierte `IST0110`); fusioná en un solo DR |

---

## 9. Trade-offs, defaults y anti-patrones

| Decisión | Barato / agresivo | Caro / conservador | Guía |
|---|---|---|---|
| **Largo del timeout** | Corto → falla rápido, pero `504`s falsos positivos bajo latencia de cola normal | Largo → tolerante, pero ata hilos durante cuelgues reales | Setealo justo por encima del P99 legítimo, no de la media |
| **`attempts` de retry** | Alto → oculta más fallos transitorios | Alto → multiplica la carga, arriesga tormenta | 2 es el default sensato; combinalo con presupuesto `maxRetries` + circuit breaker |
| **Amplitud de `retryOn`** | `5xx` → cobertura máxima | Estrecho → seguro para escrituras | Amplio para lecturas idempotentes, `connect-failure,refused-stream,reset` para escrituras |
| **`maxEjectionPercent`** | 100 → expulsar cualquier cosa | Bajo → mantener piso de disponibilidad | 50 para HTTP sin estado; más bajo para pools chicos |
| **Límites del circuit breaker** | Ajustados → protegen el backend, descargan temprano | Sueltos → toleran ráfagas, arriesgan sobrepaso | Dimensionalos a la concurrencia pico medida; hacé load-test hasta el acantilado `UO` |

**Anti-patrones que tanto el examen como producción castigan:**

1. **Retries sin `perTryTimeout`** — cada intento hereda el timeout global (posiblemente infinito); un backend colgado recibe `attempts×` la carga por `attempts×` la duración.
2. **Reintentar escrituras no idempotentes sobre `5xx`** — efectos secundarios duplicados silenciosos (cobros dobles, emails dobles).
3. **Failover configurado sin outlier detection** — el mapa de failover es inerte; nada dispara el derrame.
4. **Circuit breaker dimensionado a la carga promedio** — se dispara bajo picos normales (`UO` falsos positivos).
5. **Leer `istioctl proxy-config endpoint` para chequear la expulsión** — muestra la membresía EDS, no el estado de outlier en vivo; usá `/clusters` `health_flags::/failed_outlier_check`.
6. **Dos DestinationRules para un host** — Istio los fusiona de forma no determinista; uno gana silenciosamente.

---

## Referencias

- Istio — *Traffic Management → Circuit Breaking* (task): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — *Traffic Management concepts (timeouts, retries, circuit breakers, fault injection)*: https://istio.io/latest/docs/concepts/traffic-management/
- Istio — *Setting request timeouts* (task): https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio API — `DestinationRule` (`ConnectionPoolSettings`, `OutlierDetection`, `LoadBalancerSettings.localityLbSetting`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio API — `VirtualService` (`HTTPRoute.timeout`, `HTTPRetry`): https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRetry
- Istio — *Locality Load Balancing* (failover, distribute, failoverPriority): https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/
- Envoy — *Circuit breaking* architecture: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking
- Envoy — *Outlier detection* (ejection algorithm, panic threshold, stats): https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier
- Envoy — *Automatic retries* (`retry_on` values, budgets): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter#config-http-filters-router-x-envoy-retry-on
- Envoy — *Access log response flags* (`%RESPONSE_FLAGS%`: UO, UH, UT, URX, UF, UC): https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#command-operators
- `istioctl proxy-config` reference (cluster / route / endpoint): https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config
- CNCF — *Istio Certified Associate (ICA) Curriculum*: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf