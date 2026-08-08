# 3.2 — Configurando el enrutamiento dentro de un Service Mesh

> **Dominio del examen:** Traffic Management · **Peso:** 5 · **Plataforma:** Istio (data planes sidecar y ambient; este tema está escrito contra el modelo sidecar/Envoy, que es lo que evalúa el examen ICA) · **Grupo de API bajo evaluación:** `networking.istio.io/v1` (retrocompatible con `v1beta1`).

---

## 1. El problema de producción: por qué el mesh es dueño del enrutamiento L7

Kubernetes te da exactamente una primitiva de enrutamiento en la capa de servicio: `kube-proxy` (iptables/IPVS) balancea la carga entre los endpoints listos de un `Service` usando round-robin (o aleatorio), en **L4**, sin conciencia alguna de la semántica HTTP. Eso alcanza para llegar a un workload; no alcanza para *operarlo*. En el momento en que necesitás cualquiera de las siguientes cosas, `kube-proxy` no te puede ayudar, y quedás empujado hacia el código de la aplicación o hacia un mesh:

- **Entrega progresiva (progressive delivery)** — enrutá el 1% del tráfico a `v2`, observá las señales doradas (golden signals), subí al 100%. `kube-proxy` reparte por *cantidad de endpoints*, así que "1%" significa "correr 99 pods v1 y 1 pod v2", acoplando el peso del tráfico a la cantidad de réplicas.
- **Enrutamiento con alcance por request (request-scoped)** — enviá a un canary a los usuarios cuyo header `x-tier: premium` esté seteado; espejá (mirror) el tráfico de producción hacia un deployment sombra para pruebas de carga, sin una respuesta visible para el usuario.
- **Política de resiliencia desacoplada del código** — timeouts, reintentos con presupuestos (budgets) y circuit breaking por endpoint, aplicados de manera uniforme y modificados sin un redeploy.
- **Inyección de fallos como control de primera clase** — inyectá 5xx o latencia para validar que el comportamiento de retry/timeout aguas arriba efectivamente se sostiene bajo fallo parcial.

Istio mueve todo esto al **data plane**: un sidecar Envoy (o el ambient `ztunnel` + `waypoint`) intercepta cada request y hace cumplir las reglas de enrutamiento que declarás. El control plane (`istiod`) compila tus CRDs a configuración xDS de Envoy (LDS/RDS/CDS/EDS) y la empuja a cada proxy. **El objetivo del examen es la capa de CRDs**: cómo `VirtualService`, `DestinationRule`, `Gateway`, `ServiceEntry` y `Sidecar` se componen para expresar el enrutamiento.

### La división arquitectónica que tenés que internalizar

Istio separa deliberadamente **"¿a dónde va este request?"** de **"¿cómo hablo con lo que sea que alcancé?"**. Este es el punto conceptual más evaluado de 3.2.

| Preocupación | Objeto | Mapeo a xDS de Envoy | Responde |
|---|---|---|---|
| **Enrutamiento** — matchear un request y elegir un destino (host + subset + peso) | `VirtualService` | Configuración de rutas (RDS), virtual hosts, reglas de ruta | "¿Qué servicio/subset, con qué peso, bajo qué match, timeout, retry, fault?" |
| **Política de destino** — qué pasa *después* de que se eligió un destino | `DestinationRule` | Cluster (CDS): load balancer, definiciones de subsets, connection pool, outlier detection, TLS | "¿Cómo balanceo hacia él, qué define sus subsets, cuándo expulso un endpoint malo?" |
| **Entrada al mesh** — exponer un host en el borde | `Gateway` | Listener (LDS) en el proxy del gateway | "¿Qué puerto/protocolo/host acepta el ingress?" |
| **Extensión del registro del mesh** — hacer enrutable un host externo | `ServiceEntry` | Agrega un cluster + endpoints al registro | "¿Puede el mesh enrutar hacia `api.stripe.com`?" |
| **Alcance del proxy / egress** | `Sidecar` | Restringe el LDS/CDS/RDS importado | "¿Qué hosts conoce siquiera el proxy de este workload?" |

Un `VirtualService` **enruta**; no puede definir un subset. Un `DestinationRule` **define subsets y política**; no puede matchear un request. Un canary necesita *ambos*, y olvidar esto es el 503 autoinfligido más común.

---

## 2. VirtualService vs DestinationRule vs Gateway — la matriz de compromisos

| Capacidad | VirtualService | DestinationRule | Gateway |
|---|---|---|---|
| Matchear por URI / header / método / query | ✅ | ❌ | ❌ (solo host/puerto/TLS) |
| Split ponderado (canary / blue-green) | ✅ (`route[].weight`) | ❌ | ❌ |
| Definir subsets (`v1`, `v2`) | ❌ (solo los *referencia*) | ✅ (`subsets[]` por label) | ❌ |
| Algoritmo de balanceo de carga | ❌ | ✅ (`trafficPolicy.loadBalancer`) | ❌ |
| Límites de connection pool | ❌ | ✅ | ❌ |
| Outlier detection (circuit breaking) | ❌ | ✅ | ❌ |
| Timeouts / reintentos | ✅ | ❌ | ❌ |
| Inyección de fallos (delay/abort) | ✅ | ❌ | ❌ |
| Espejado de tráfico (mirroring) | ✅ | ❌ | ❌ |
| Redirección HTTP→HTTPS / reescritura de URI | ✅ | ❌ | ❌ (redirección vía VS) |
| Vincularse a un listener de ingress | ✅ (`gateways:`) | ❌ | ✅ (define el listener) |
| Modo mTLS hacia el upstream | ❌ | ✅ (`trafficPolicy.tls`) | ✅ (terminación TLS del servidor) |

**Regla práctica para el examen:** si el verbo es *matchear, dividir, reintentar, hacer timeout, inyectar, espejar, redirigir, reescribir* → `VirtualService`. Si el verbo es *balancear, agrupar en pool, expulsar, definir-subset, cifrar-upstream* → `DestinationRule`. Si el verbo es *aceptar en el borde* → `Gateway`.

### Orden de evaluación de rutas — gana el primer match

Dentro de un `VirtualService`, las reglas `http[]` se evalúan **de arriba hacia abajo, gana el primer match**. No hay un puntaje de "más específico" como en el matcheo de paths del Ingress. Esto tiene una consecuencia operativa dura:

> **Colocá siempre el match más específico (header/URI) *por encima* de la ruta por defecto catch-all.** Si tu split ponderado por defecto va primero, la regla de canary basada en header que está debajo es código muerto.

Precedencia entre recursos para el mismo host: Istio fusiona (merge) los `VirtualService` que apuntan al mismo host, pero el orden entre múltiples objetos VS **no está garantizado** — la práctica de producción es **un VirtualService por host** para mantener el orden de evaluación determinista.

---

## 3. Manifiestos completos, de calidad de producción

El ejemplo en curso es un servicio `reviews` en el namespace `bookinfo` con tres versiones (`v1`, `v2`, `v3`), fronteado por un ingress gateway en `bookinfo.example.com`.

### 3.0 Prerrequisito: el DestinationRule que nombra los subsets

Nada de lo de abajo funciona hasta que existan los subsets. Un subset es un **selector de labels con nombre sobre los pods del servicio** — Envoy convierte cada uno en un cluster distinto.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local   # FQDN is safest; short name resolves relative to the DR's namespace
  trafficPolicy:                             # default policy for ALL subsets unless overridden
    loadBalancer:
      simple: LEAST_REQUEST                  # ROUND_ROBIN | LEAST_REQUEST | RANDOM | PASSTHROUGH
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 3s
      http:
        http1MaxPendingRequests: 64
        http2MaxRequests: 1000
        maxRequestsPerConnection: 0          # 0 = unlimited (no forced connection recycling)
        idleTimeout: 30s
    outlierDetection:                        # circuit breaking: eject unhealthy endpoints
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50                 # never eject more than half the pool at once
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
    trafficPolicy:                           # per-subset override: v2 gets a stricter LB
      loadBalancer:
        simple: ROUND_ROBIN
  - name: v3
    labels:
      version: v3
```

> **Trampa de resolución de `host`:** un `host: reviews` pelado se resuelve contra el namespace *propio* del DestinationRule y los search domains por defecto del proxy. Bajo configuraciones multi-tenant estrictas esto apunta silenciosamente al servicio equivocado. Usá el FQDN en producción.

### 3.1 Enrutamiento ponderado por defecto — la primitiva del canary

Los pesos son enteros proporcionales sobre el flujo de requests, **completamente independientes de la cantidad de réplicas**. Por convención deberían sumar 100 (Istio normaliza si no lo hacen, pero confiar en eso es mala higiene).

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - name: canary-90-10
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 90
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v2
      weight: 10
```

### 3.2 Enrutamiento con alcance por request — matcheo por header, URI, método y query

Las condiciones de match se **combinan con AND dentro de una misma entrada `match`** y se **combinan con OR entre entradas de la lista `match[]`**. Las reglas específicas van primero.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  # 1) Internal QA: header end-user=jason AND path prefix /api/v2 → v2
  - name: qa-header-route
    match:
    - headers:
        end-user:
          exact: jason
      uri:
        prefix: /api/v2
      method:
        exact: GET
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v2

  # 2) Beta cohort: query param ?beta=true OR header x-tier=premium → v3
  - name: beta-cohort
    match:
    - queryParams:
        beta:
          exact: "true"
    - headers:
        x-tier:
          exact: premium
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v3

  # 3) Catch-all default MUST be last
  - name: default
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
```

Tipos de match de cadena soportados en `uri`, `headers`, `queryParams`, `authority`, `scheme`, `method`: `exact`, `prefix`, `regex` (sintaxis RE2). Los nombres de header se matchean sin distinguir mayúsculas/minúsculas según la semántica HTTP; los **valores** de header distinguen mayúsculas/minúsculas.

### 3.3 Timeouts, reintentos e inyección de fallos — resiliencia sin código

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
  namespace: bookinfo
spec:
  hosts:
  - ratings.bookinfo.svc.cluster.local
  http:
  - name: resilient-default
    route:
    - destination:
        host: ratings.bookinfo.svc.cluster.local
        subset: v1
    timeout: 2s                       # end-to-end request timeout (includes retries)
    retries:
      attempts: 3                     # up to 3 retries → 4 total tries
      perTryTimeout: 500ms            # per-attempt cap; attempts*perTryTimeout can exceed `timeout`,
                                      # in which case `timeout` wins and truncates the budget
      retryOn: 5xx,reset,connect-failure,retriable-4xx
      retryRemoteLocalities: true     # allow retries to spill to another locality
    fault:                            # chaos engineering, declared
      delay:
        percentage:
          value: 10.0                 # 10% of requests
        fixedDelay: 3s
      abort:
        percentage:
          value: 5.0                  # 5% of requests
        httpStatus: 503
```

> **Semántica de reintentos que hace tropezar a la gente:** el `timeout` total es la pared dura. Con `attempts: 3` y `perTryTimeout: 500ms` pero `timeout: 2s`, obtenés como mucho `2s / 500ms = 4` intentos en tiempo de reloj — el `timeout` trunca el presupuesto de reintentos. Solo las condiciones **idempotentes** pertenecen a `retryOn`; reintentar POSTs no idempotentes con `retriable-4xx` va a duplicar efectos secundarios.

### 3.4 Espejado de tráfico (shadowing) — probar con tráfico de producción, descartar la respuesta

Los requests espejados son **fire-and-forget** (dispará y olvidá): el sidecar envía una copia al destino espejo, pero la respuesta del espejo se **descarta** y nunca afecta al usuario. El header `Host`/`Authority` del request espejado se etiqueta con `-shadow` para que el workload sombra pueda distinguirlo.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - name: mirror-to-v2
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 100
    mirror:
      host: reviews.bookinfo.svc.cluster.local
      subset: v2
    mirrorPercentage:
      value: 100.0     # mirror 100% of live traffic to v2; v2 sees prod load, users only ever see v1
```

### 3.5 Redirección y reescritura

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: legacy-redirect
  namespace: bookinfo
spec:
  hosts:
  - bookinfo.example.com
  gateways:
  - bookinfo-gateway
  http:
  # Permanent redirect of an old path
  - match:
    - uri:
        prefix: /old-reviews
    redirect:
      uri: /reviews
      redirectCode: 301
  # Rewrite: external /api/reviews → internal /reviews on the reviews service
  - match:
    - uri:
        prefix: /api/reviews
    rewrite:
      uri: /reviews
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
```

### 3.6 Enrutamiento en el borde — Gateway + VirtualService vinculado a él

Un `Gateway` define el **listener** (puerto/protocolo/host/TLS) en el proxy de ingress. Por sí solo **no** hace ningún enrutamiento — vinculás un `VirtualService` a él vía `gateways:` y referenciás el gateway por `<namespace>/<name>` (o por nombre pelado si está en el mismo namespace).

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: bookinfo-gateway
  namespace: bookinfo
spec:
  selector:
    istio: ingressgateway          # matches the istio-ingressgateway Deployment's pod labels
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - "bookinfo.example.com"
    tls:
      mode: SIMPLE                 # terminate TLS at the gateway
      credentialName: bookinfo-tls # references a Kubernetes secret in the gateway's namespace
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "bookinfo.example.com"
    tls:
      httpsRedirect: true          # 301 all :80 traffic to :443
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: bookinfo
  namespace: bookinfo
spec:
  hosts:
  - "bookinfo.example.com"
  gateways:
  - bookinfo-gateway              # bind to the edge listener above
  - mesh                          # ALSO apply to in-mesh sidecar traffic (reserved keyword)
  http:
  - match:
    - uri:
        prefix: /productpage
    route:
    - destination:
        host: productpage.bookinfo.svc.cluster.local
        port:
          number: 9080
```

> **El gateway reservado `mesh`:** omitir `gateways:` toma por defecto `["mesh"]` — la regla aplica solo al tráfico sidecar-a-sidecar. Si listás el nombre de un gateway, **debés** agregar también `mesh` explícitamente para conservar el enrutamiento este-oeste. Olvidar esto es la razón de "mi canary funciona desde afuera pero no de servicio a servicio".

### 3.7 ServiceEntry — hacer enrutable (y divisible) un host externo

Los hosts externos no están en el registro del mesh, así que no podés escribir un `VirtualService` para ellos hasta que un `ServiceEntry` los agregue. Esto te permite aplicar timeouts/reintentos/splits a APIs de terceros.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-payments
  namespace: bookinfo
spec:
  hosts:
  - api.payments.example.com
  location: MESH_EXTERNAL
  resolution: DNS
  ports:
  - number: 443
    name: https
    protocol: TLS
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: external-payments-timeout
  namespace: bookinfo
spec:
  hosts:
  - api.payments.example.com
  http: []                          # (for TLS/TCP passthrough use tls:/tcp:; shown here for shape)
  tls:
  - match:
    - port: 443
      sniHosts:
      - api.payments.example.com
    route:
    - destination:
        host: api.payments.example.com
```

### 3.8 Sidecar — acotando lo que un proxy conoce (rendimiento de enrutamiento + radio de impacto)

Por defecto cada sidecar recibe configuración para **cada** servicio del mesh. A escala esto infla la memoria de Envoy y ralentiza los pushes. Un recurso `Sidecar` restringe el conjunto de importación — y hace doble función como control de egress.

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: bookinfo
spec:
  egress:
  - hosts:
    - "./*"                          # this namespace
    - "istio-system/*"               # the control-plane namespace
    - "bookinfo/*"
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY              # block egress to anything not in the registry (deny-by-default)
```

---

## 4. CLI y E/S de terminal

Aplicá e inspeccioná los objetos. Las salidas de abajo son representativas de Istio 1.2x.

```console
$ kubectl apply -f reviews-destinationrule.yaml -f reviews-virtualservice.yaml
destinationrule.networking.istio.io/reviews created
virtualservice.networking.istio.io/reviews created

$ kubectl get virtualservice,destinationrule -n bookinfo
NAME                                          GATEWAYS               HOSTS                                    AGE
virtualservice.networking.istio.io/reviews                          ["reviews.bookinfo.svc.cluster.local"]   12s
virtualservice.networking.istio.io/bookinfo   ["bookinfo-gateway"]   ["bookinfo.example.com"]                 12s

NAME                                          HOST                                     AGE
destinationrule.networking.istio.io/reviews   reviews.bookinfo.svc.cluster.local       12s
```

**Analizá antes de confiar** — `istioctl analyze` atrapa el bug de enrutamiento más común (un VirtualService que referencia un subset que ningún DestinationRule define):

```console
$ istioctl analyze -n bookinfo
✔ No validation issues found when analyzing namespace: bookinfo.
```

Un caso deliberadamente roto — el VirtualService apunta a `subset: v4`, que ningún DestinationRule define:

```console
$ istioctl analyze -n bookinfo
Error [IST0101] (VirtualService reviews.bookinfo) Referenced host+subset in destinationrule not found: "reviews.bookinfo.svc.cluster.local+v4"
Error: Analyzers found issues when analyzing namespace: bookinfo.
See https://istio.io/v1.24/docs/reference/config/analysis for more information about causes and resolutions.
```

**Confirmá el split empíricamente** — martillá el endpoint y contá la versión que golpeó cada request:

```console
$ for i in $(seq 1 100); do
    kubectl exec deploy/productpage -n bookinfo -c productpage -- \
      curl -s reviews:9080/reviews/0 | grep -o '"podname": "reviews-v[0-9]'
  done | sort | uniq -c
     91 "podname": "reviews-v1
      9 "podname": "reviews-v2
```

91/9 sobre 100 muestras es exactamente el ponderado 90/10 dentro del ruido de muestreo — prueba de que los pesos, y no la cantidad de réplicas, impulsaron el split.

**Verificá la configuración compilada de Envoy** — rutas, clusters y sus endpoints:

```console
$ istioctl proxy-config routes deploy/productpage -n bookinfo --name 9080 -o json | \
    jq '.[].virtualHosts[].routes[].route.weightedClusters // empty'
{
  "clusters": [
    { "name": "outbound|9080|v1|reviews.bookinfo.svc.cluster.local", "weight": 90 },
    { "name": "outbound|9080|v2|reviews.bookinfo.svc.cluster.local", "weight": 10 }
  ],
  "totalWeight": 100
}

$ istioctl proxy-config cluster deploy/productpage -n bookinfo --fqdn reviews.bookinfo.svc.cluster.local
SERVICE FQDN                            PORT  SUBSET  DIRECTION   TYPE     DESTINATION RULE
reviews.bookinfo.svc.cluster.local      9080  -       outbound    EDS      reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080  v1      outbound    EDS      reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080  v2      outbound    EDS      reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080  v3      outbound    EDS      reviews.bookinfo

$ istioctl proxy-config endpoints deploy/productpage -n bookinfo --cluster \
    "outbound|9080|v2|reviews.bookinfo.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
10.244.2.15:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
```

---

## 5. Verificación y diagnóstico de fallos

### La escalera de diagnóstico — subila en orden

1. **¿Los CRDs validan entre sí?** → `istioctl analyze -n <ns>`. Atrapa subsets faltantes (IST0101), VSes en conflicto y errores de tipeo en hosts gratis, antes de cualquier tráfico.
2. **¿La configuración realmente llegó al proxy?** → `istioctl proxy-status` (alias `ps`). Cada proxy debe mostrar `SYNCED` para CDS/LDS/EDS/RDS. `STALE` significa que `istiod` hizo push pero el proxy no hizo ACK; `NOT SENT` significa que la configuración nunca se compiló para ese proxy.
3. **¿La ruta está presente en Envoy?** → `istioctl proxy-config routes <pod> --name <port>`. Si tu ruta no está acá, el VS no está vinculando — normalmente un desajuste del FQDN en `hosts:` o un gateway `mesh` faltante.
4. **¿El cluster existe y tiene endpoints?** → `istioctl proxy-config cluster` y luego `... endpoints`. **Sin endpoints = 503 UH (no hay upstream saludable).** Casi siempre es un label de subset que no matchea ningún pod.
5. **¿Qué decidió realmente Envoy, por request?** → el access log del sidecar, con `response_flags`.

```console
$ istioctl proxy-status
NAME                                     CLUSTER      CDS        LDS        EDS        RDS        ISTIOD          VERSION
productpage-xxxx.bookinfo                Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     istiod-abc123   1.24.0
reviews-v2-yyyy.bookinfo                 Kubernetes   SYNCED     SYNCED     SYNCED     STALE      istiod-abc123   1.24.0
```

### La única herramienta de depuración que resuelve la mayoría de los tickets: `response_flags` de Envoy

Leé el access log del sidecar y decodificá la columna de flags. Este único campo te dice *qué capa* descartó el request.

```console
$ kubectl logs deploy/productpage -n bookinfo -c istio-proxy --tail=3
[2026-08-08T14:22:31.005Z] "GET /reviews/0 HTTP/1.1" 503 UH ... "outbound|9080|v4|reviews.bookinfo.svc.cluster.local" -
[2026-08-08T14:22:33.410Z] "GET /reviews/0 HTTP/1.1" 200 -  ... "outbound|9080|v1|reviews.bookinfo.svc.cluster.local" 10.244.1.9:9080
[2026-08-08T14:22:35.887Z] "GET /reviews/0 HTTP/1.1" 504 UT ... "outbound|9080|v1|reviews.bookinfo.svc.cluster.local" 10.244.1.9:9080
```

| Flag | Significado | Causa de enrutamiento más probable |
|---|---|---|
| `UH` | No hay upstream saludable | El subset matchea **cero** pods (`labels` malos), o todos los endpoints fueron expulsados por outlier detection |
| `UF` | Fallo de conexión al upstream | `connectTimeout` excedido, o desajuste de modo mTLS (PERMISSIVE vs STRICT vs DISABLE) |
| `UT` | Timeout de request al upstream | Tu `timeout`/`perTryTimeout` se disparó — el upstream fue demasiado lento |
| `NR` | No hay ruta configurada | `hosts`/`match` del VS no matchearon; el request se cayó sin ruta por defecto |
| `URX` | Límite de retry/redirect excedido | Reintentos agotados según `retries.attempts` |
| `DI` | Delay inyectado | Tu `fault.delay` se disparó (esperado durante pruebas de caos) |
| `FI` | Fault (abort) inyectado | Tu `fault.abort` se disparó |

### Los fallos clásicos de canary y sus arreglos

| Síntoma | Causa raíz | Arreglo |
|---|---|---|
| `503 UH` solo en la versión canary | El `VirtualService` referencia `subset: vX` pero el `DestinationRule` no tiene ese subset, o sus `labels` no matchean ningún pod | Corré `istioctl analyze`; confirmá que `kubectl get pods -l version=vX` devuelve pods; agregá/repará el subset |
| El split funciona externamente, pero no de servicio a servicio | El VS lista un nombre de gateway pero descartó el gateway `mesh` implícito | Agregá `- mesh` a `spec.gateways` |
| La ruta por header nunca se dispara | La ruta por defecto catch-all colocada **por encima** del match específico | Reordená: reglas `match` específicas primero, la por defecto al final |
| Los pesos se ignoran, el tráfico sigue la cantidad de réplicas | No hay ningún `DestinationRule` / subsets, así que Envoy cae de nuevo al cluster de servicio plano (round-robin L4) | Creá el DestinationRule con subsets |
| Los reintentos duplican un pago | `retryOn` incluye condiciones reintentables sobre un POST no idempotente | Acotá los reintentos solo a rutas idempotentes |
| `503 UF` intermitente después de habilitar mTLS STRICT | `DestinationRule.trafficPolicy.tls.mode` no es `ISTIO_MUTUAL` mientras `PeerAuthentication` es STRICT | Seteá `tls.mode: ISTIO_MUTUAL` en el upstream o alineá el modo de PeerAuthentication |

---

## 6. Referencias

- Istio — Traffic Management (concepts): https://istio.io/latest/docs/concepts/traffic-management/
- Istio — VirtualService API reference: https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — DestinationRule API reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — Gateway API reference: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio — ServiceEntry API reference: https://istio.io/latest/docs/reference/config/networking/service-entry/
- Istio — Sidecar API reference: https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio task — Request routing: https://istio.io/latest/docs/tasks/traffic-management/request-routing/
- Istio task — Traffic shifting (weighted): https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Istio task — Traffic mirroring: https://istio.io/latest/docs/tasks/traffic-management/mirroring/
- Istio task — Fault injection: https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
- Istio task — Setting request timeouts: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio task — Circuit breaking (outlier detection): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — Configuration analysis messages (IST0101 etc.): https://istio.io/latest/docs/reference/config/analysis/
- Istio — Debugging Envoy and istiod (proxy-config / proxy-status): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Envoy — Response flags reference: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#config-access-log-format-response-flags
- CNCF — Istio Certified Associate (ICA) curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf