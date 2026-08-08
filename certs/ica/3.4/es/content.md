# ICA 3.4 — Configuración del desvío de tráfico (Traffic Shifting)

> Dominio: Traffic Management · Peso en el examen: 5
> Data plane asumido: modo sidecar de Istio (Envoy). Las notas para el modo ambient se señalan donde la mecánica difiere.
> Versión de API usada más abajo: `networking.istio.io/v1` (GA desde Istio 1.22). El esquema es idéntico byte por byte a `networking.istio.io/v1beta1`, que se sigue sirviendo — cambiá la cadena `apiVersion` si tu cluster corre una versión anterior.

---

## 1. Motivación y el problema arquitectónico de producción

Desplegar una nueva versión de un servicio en un mesh compartido no es un evento binario de "vieja → nueva". En el momento en que `Deployment/reviews-v2` alcanza `Ready`, el balanceo de carga nativo del `Service` de Kubernetes (kube-proxy / iptables / IPVS) le envía una porción de tráfico proporcional a su cantidad de endpoints. Ese acoplamiento es el problema de raíz:

- **El radio de impacto (blast radius) está atado a la cantidad de réplicas, no al riesgo.** Si v2 tiene 1 réplica y v1 tiene 9, v2 recibe ~10% — pero solo por la aritmética de réplicas, no porque hayas decidido que el 10% era un canary seguro. Escalá v2 por capacidad y silenciosamente escalás su exposición.
- **No hay desacople entre "desplegado" y "recibiendo tráfico de producción".** No podés hornear una versión, calentar sus cachés, correr smoke tests contra tráfico real y *después* promoverla.
- **El rollback es un `kubectl rollout undo`** — un redeploy completo con su propio retardo de propagación, durante el cual la versión mala sigue sirviendo.
- **No hay control a nivel de request.** No podés decir "los usuarios de la beta interna con el header `x-canary: true` van a v2, todos los demás a v1" con Services simples.

Istio mueve la decisión de ruteo **hacia arriba, a L7, dentro del sidecar de Envoy del *que llama (caller)***. Un `VirtualService` declara *cómo* se dividen los requests hacia un host lógico; un `DestinationRule` declara *qué* pods constituyen cada subset. istiod (Pilot) compila estos CRDs en objetos `RouteConfiguration` de Envoy que contienen **weighted clusters**, enviados a cada sidecar vía xDS. Envoy entonces realiza una selección aleatoria ponderada por request a través de los clusters. Las consecuencias:

- El peso es **independiente de la cantidad de réplicas** — 1% a v2 con 20 réplicas detrás es perfectamente válido.
- Los cambios surten efecto en **segundos** (un push de configuración), **sin reinicios de pods** y **sin drenaje de conexiones de la versión vieja**.
- El ruteo puede basarse en **headers, cookies, workload de origen, SNI, URI** — habilitando A/B testing, dark launches y entrega progresiva.
- El mesh emite **telemetría por versión** (`istio_requests_total{destination_version=...}`), que es la materia prima para el análisis *automatizado* de canary (Flagger, Argo Rollouts).

La recompensa arquitectónica es **separar el deployment del release**: `kubectl apply` pone código en el cluster; un cambio de peso en un `VirtualService` *libera (releases)* ese código a los usuarios, de forma gradual y reversible.

---

## 2. Análisis comparativo de las estrategias de traffic-shifting

Todas las siguientes se expresan con los *mismos dos CRDs*; solo difieren en cómo configurás el bloque `http`.

| Estrategia | Cómo se expresa en Istio | Unidad de selección | Rollback | Mejor para | Riesgo clave |
|---|---|---|---|---|---|
| **Weighted canary** | división de `route[].weight` entre subsets, escalada 0→5→25→50→100 | Por request (aleatorio) | Volver el peso a 0 | Validación gradual en producción con métricas en vivo | Un mismo usuario puede pegarle a ambas versiones en requests consecutivos (sin stickiness por defecto) |
| **Blue-green** | un solo `route.destination.subset`, volteado atómicamente v1→v2 | Todo-o-nada | Volver a voltear el subset | Cutover rápido, migraciones de DB que no pueden correr mezcladas | Radio de impacto total al voltear; sin validación parcial |
| **A/B por header/cookie** | regla de ruteo `match[].headers` *antes* del catch-all ponderado | Por request (determinístico por atributo) | Quitar la regla de match | Testeo de features en usuarios internos / cohortes | Bugs de orden de match ruteando silenciosamente a todos al catch-all |
| **Traffic mirroring (shadowing)** | `route.mirror` + `mirrorPercentage` | Por request, copia fire-and-forget | Quitar `mirror` | Testear v2 con tráfico real, impacto cero al usuario | Efectos secundarios del mirror (dobles escrituras, emails duplicados) si no es idempotente |
| **Sticky canary** | división ponderada + `DestinationRule.trafficPolicy.loadBalancer.consistentHash` | Por sesión (hash de cookie/header) | Igual que weighted | A/B donde un usuario debe quedarse en una versión | División despareja si la clave de hash está sesgada |
| **Entrega progresiva automatizada** | Flagger/Argo maneja `route[].weight` a partir de métricas de SLO | Por request, pesos controlados por máquina | Automático ante violación de métrica | Sin intervención, promoción con puertas de métricas | Métricas malas/ausentes → falsa promoción o rollout trabado |

### Dónde se aplica la decisión

| | Nativo de Kubernetes | Traffic shifting con sidecar de Istio | Istio ambient (waypoint) |
|---|---|---|---|
| Granularidad de la división | Proporcional a la cantidad de réplicas | % arbitrario / basado en atributos | % arbitrario / basado en atributos |
| Punto de aplicación | kube-proxy (L4) | Sidecar de Envoy del caller (L7) | L4 en ztunnel; **las reglas L7 requieren un waypoint proxy** |
| Reinicio para cambiar | Sí (escalar/redeployar) | No | No |
| Métricas por versión | No | Sí | Sí (vía waypoint) |

> **Salvedad de ambient para el examen:** el ruteo ponderado del `VirtualService` es una feature L7. En modo ambient solo surte efecto si hay un **waypoint proxy** desplegado para el destino (`istioctl waypoint apply`). ztunnel solo es L4 y no va a respetar los pesos HTTP.

---

## 3. Infraestructura completa y manifiestos

El ejemplo que corre a lo largo del texto es el servicio canónico `reviews` (`v1`, `v2`, `v3`) en el namespace `bookinfo`. El namespace debe tener la inyección habilitada.

### 3.0 Namespace y workloads

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio-injection: enabled          # sidecar auto-injection
---
apiVersion: v1
kind: Service
metadata:
  name: reviews
  namespace: bookinfo
  labels:
    app: reviews
    service: reviews
spec:
  selector:
    app: reviews                      # NOTE: selects on app only, NOT version —
                                      # every version is an endpoint of this one Service
  ports:
    - name: http                      # port name MUST start with http/http2/grpc
      port: 9080                      # for Istio to apply L7 routing
      targetPort: 9080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v1
  namespace: bookinfo
  labels:
    app: reviews
    version: v1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: reviews
      version: v1
  template:
    metadata:
      labels:
        app: reviews
        version: v1                   # <-- the label DestinationRule subsets match on
    spec:
      serviceAccountName: bookinfo-reviews
      containers:
        - name: reviews
          image: docker.io/istio/examples-bookinfo-reviews-v1:1.20.2
          ports:
            - containerPort: 9080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v2
  namespace: bookinfo
  labels:
    app: reviews
    version: v2
spec:
  replicas: 3
  selector:
    matchLabels:
      app: reviews
      version: v2
  template:
    metadata:
      labels:
        app: reviews
        version: v2
    spec:
      serviceAccountName: bookinfo-reviews
      containers:
        - name: reviews
          image: docker.io/istio/examples-bookinfo-reviews-v2:1.20.2
          ports:
            - containerPort: 9080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
```

> Dos reglas que rompen silenciosamente el traffic shifting si se violan:
> 1. **El `Service` selecciona solo por `app`.** Si agregás `version` al selector, cada versión se vuelve un Service *distinto* y el ruteo por subset no tiene nada entre qué dividir.
> 2. **El puerto debe llamarse `http`, `http2` o `grpc`** (o usar `appProtocol`). Un puerto sin nombre o nombrado `tcp` hace que Istio trate el tráfico como L4 opaco — las reglas de `VirtualService.http` se ignoran entonces y todo cae al round-robin simple.

### 3.1 DestinationRule — definir los subsets

El `VirtualService` solo puede referenciar un subset que un `DestinationRule` defina. Creá esto **primero**.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
spec:
  host: reviews                       # short name resolves to reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        http2MaxRequests: 1000
        maxRequestsPerConnection: 10
    outlierDetection:                 # eject unhealthy endpoints so a bad canary
      consecutive5xxErrors: 5         # sheds itself rather than serving errors
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
    - name: v3
      labels: { version: v3 }
```

### 3.2 VirtualService — weighted canary (interno al mesh)

Empezá en 100/0, después editá los pesos.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
    - reviews                         # logical host callers use
  # gateways omitted => defaults to ["mesh"] => applies to in-mesh sidecar traffic
  http:
    - name: canary-split
      route:
        - destination:
            host: reviews
            subset: v1
          weight: 90
        - destination:
            host: reviews
            subset: v2
          weight: 10                  # weights across a single route MUST sum to 100
```

**Secuencia de escalada (ramp)** — aplicá el mismo objeto con pesos crecientes:

| Paso | v1 | v2 | Puerta antes de avanzar |
|---|---|---|---|
| 0 | 100 | 0 | pods de v2 `Ready`, subset visible en los clusters de Envoy |
| 1 | 95 | 5 | tasa de éxito ≥ 99.5%, latencia p99 dentro del SLO por 10 min |
| 2 | 75 | 25 | sin nuevas clases de 5xx, saturación nominal |
| 3 | 50 | 50 | tasa de quema del error budget < 1× |
| 4 | 0 | 100 | soak, después eliminar el Deployment de v1 |

### 3.3 Ruteo A/B basado en header (cohorte determinística) + fallback ponderado

Las reglas de match se evalúan **de arriba hacia abajo, gana el primer match**. Poné la regla de cohorte determinística *arriba* del catch-all ponderado.

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
    - name: internal-beta
      match:
        - headers:
            x-canary:
              exact: "true"           # internal beta cohort -> always v2
        - headers:
            end-user:
              exact: "jason"
      route:
        - destination:
            host: reviews
            subset: v2
    - name: everyone-else              # catch-all: no match => weighted split
      route:
        - destination:
            host: reviews
            subset: v1
          weight: 90
        - destination:
            host: reviews
            subset: v2
          weight: 10
```

### 3.4 Traffic mirroring (shadow / dark launch)

Los requests reales de producción se *copian* a v2; las respuestas de v2 se **descartan** y nunca afectan al usuario. El host reflejado (mirrored) recibe un sufijo `-shadow` en su header `Host`/`Authority` para que sea distinguible en los logs.

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
            subset: v1                # 100% of live traffic still served by v1
          weight: 100
      mirror:
        host: reviews
        subset: v2                    # a fire-and-forget copy goes to v2
      mirrorPercentage:
        value: 100.0                  # mirror 100% of requests (double for 50%, etc.)
```

> **Advertencia de idempotencia:** los requests reflejados son requests *reales* a v2. Si v2 escribe en una base de datos, envía emails o cobra tarjetas, el mirroring duplica esos efectos secundarios. Reflejá solo caminos de lectura, o apuntá v2 a un datastore de shadow.

### 3.5 Blue-green (cutover atómico)

```yaml
# Green live:
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: reviews, namespace: bookinfo }
spec:
  hosts: [reviews]
  http:
    - route:
        - destination: { host: reviews, subset: v1 }   # 100% by omission of weight
# Flip to blue: change subset to v2 and re-apply. Single-object atomic switch.
```

### 3.6 Sticky canary (afinidad de sesión)

Agregá consistent hashing al DestinationRule para que un usuario dado siempre caiga en la misma versión a través de los requests.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
spec:
  host: reviews
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: canary-session
          ttl: 3600s               # sticks the user to one hashed endpoint for 1h
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
```

### 3.7 Desviar tráfico en el borde de ingreso (ingress edge)

Para el tráfico externo, vinculá el `VirtualService` a un `Gateway`. La división de pesos entonces ocurre en el Envoy del ingress gateway.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: bookinfo-gw
  namespace: bookinfo
spec:
  selector:
    istio: ingressgateway            # the istio-ingressgateway Deployment's label
  servers:
    - port: { number: 80, name: http, protocol: HTTP }
      hosts: ["bookinfo.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: bookinfo-edge
  namespace: bookinfo
spec:
  hosts:
    - "bookinfo.example.com"         # must match the Gateway host (FQDN, not short name)
  gateways:
    - bookinfo-gw                    # binds this VS to the ingress gateway
  http:
    - route:
        - destination:
            host: productpage.bookinfo.svc.cluster.local
            port: { number: 9080 }
            subset: v1
          weight: 80
        - destination:
            host: productpage.bookinfo.svc.cluster.local
            port: { number: 9080 }
            subset: v2
          weight: 20
```

> En el borde, usá siempre el **FQDN** para `destination.host`; los short names resuelven contra el namespace *del gateway*, que suele ser `istio-system`, no el namespace de tu app.

### 3.8 Entrega progresiva automatizada (Flagger)

Editar pesos a mano no escala y es propenso a errores. Flagger observa las métricas de SLO y maneja los pesos del `VirtualService` por vos, promoviendo o haciendo rollback automáticamente.

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: reviews
  namespace: bookinfo
spec:
  provider: istio
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: reviews                     # Flagger creates reviews-primary + reviews-canary
  progressDeadlineSeconds: 600
  service:
    port: 9080
    targetPort: 9080
    gateways: ["mesh"]
    hosts: ["reviews"]
  analysis:
    interval: 1m                      # evaluate metrics every minute
    threshold: 5                      # abort after 5 failed checks
    maxWeight: 50                     # ramp canary up to 50% before promoting
    stepWeight: 10                    # +10% each successful interval
    metrics:
      - name: request-success-rate
        thresholdRange: { min: 99 }   # abort if success rate < 99%
        interval: 1m
      - name: request-duration
        thresholdRange: { max: 500 }  # abort if p99 latency > 500ms
        interval: 1m
    webhooks:
      - name: load-test
        url: http://flagger-loadtester.bookinfo/
        timeout: 5s
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://reviews-canary.bookinfo:9080/"
```

Flagger genera Deployments `reviews-primary`/`reviews-canary` y es dueño del `VirtualService` — **no edites los pesos a mano cuando Flagger está manejando el objeto**; va a revertir tu cambio en la próxima reconciliación.

---

## 4. Flujo de trabajo por CLI con salida de terminal real

```console
$ istioctl version --short
client version: 1.24.1
control plane version: 1.24.1
data plane version: 1.24.1 (18 proxies)
```

Aplicar y confirmar los CRDs:

```console
$ kubectl apply -f reviews-destinationrule.yaml -f reviews-virtualservice.yaml
destinationrule.networking.istio.io/reviews created
virtualservice.networking.istio.io/reviews created

$ kubectl -n bookinfo get virtualservice reviews -o jsonpath='{.spec.http[0].route[*].weight}{"\n"}'
90 10
```

Validación estática de la configuración *antes* de confiar en la división:

```console
$ istioctl analyze -n bookinfo
✔ No validation issues found when analyzing namespace: bookinfo.
```

Un VS roto a propósito (el subset `v2` no está en el DestinationRule) se captura acá:

```console
$ istioctl analyze -n bookinfo
Error [IST0101] (VirtualService reviews.bookinfo) Referenced host+subset in destinationrule not found:
  "reviews+v2"
Error: Analyzers found issues when analyzing namespace: bookinfo.
```

### Confirmar que istiod realmente compiló los pesos en el Envoy del caller

Elegí el pod *caller* (por ejemplo, `productpage`, que llama a `reviews`), no el destino:

```console
$ POD=$(kubectl -n bookinfo get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')

$ istioctl proxy-config routes "$POD.bookinfo" --name 9080 -o json | \
    jq '.[].virtualHosts[] | select(.name|test("reviews")) | .routes[].route.weightedClusters'
{
  "clusters": [
    {
      "name": "outbound|9080|v1|reviews.bookinfo.svc.cluster.local",
      "weight": 90
    },
    {
      "name": "outbound|9080|v2|reviews.bookinfo.svc.cluster.local",
      "weight": 10
    }
  ],
  "totalWeight": 100
}
```

Los dos **clusters** de subset deben existir y cada uno debe tener endpoints:

```console
$ istioctl proxy-config clusters "$POD.bookinfo" --fqdn reviews.bookinfo.svc.cluster.local
SERVICE FQDN                            PORT   SUBSET  DIRECTION  TYPE  DESTINATION RULE
reviews.bookinfo.svc.cluster.local      9080   -       outbound   EDS   reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080   v1      outbound   EDS   reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080   v2      outbound   EDS   reviews.bookinfo

$ istioctl proxy-config endpoints "$POD.bookinfo" --cluster \
    "outbound|9080|v2|reviews.bookinfo.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
10.244.1.37:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
10.244.2.19:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
10.244.3.44:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
```

### Medir empíricamente la división

Disparar N requests desde un cliente dentro del mesh y contabilizar qué versión respondió (el pod reviews de Bookinfo devuelve su versión; sustituí por tu propia señal):

```console
$ for i in $(seq 1 100); do
    kubectl -n bookinfo exec deploy/ratings -c ratings -- \
      curl -s reviews:9080/reviews/0 | jq -r '.podname' ;
  done | sed 's/-[a-z0-9]*-[a-z0-9]*$//' | sort | uniq -c
     91 reviews-v1
      9 reviews-v2
```

91/9 contra un 90/10 configurado — dentro de la varianza esperada para n=100. Cambio en vivo a 50/50:

```console
$ kubectl -n bookinfo patch virtualservice reviews --type merge -p \
  '{"spec":{"http":[{"route":[
     {"destination":{"host":"reviews","subset":"v1"},"weight":50},
     {"destination":{"host":"reviews","subset":"v2"},"weight":50}]}]}}'
virtualservice.networking.istio.io/reviews patched
```

Ningún pod se reinició; los nuevos `weightedClusters` llegan a cada sidecar en un par de segundos.

### Observar a Flagger manejar un canary

```console
$ kubectl -n bookinfo describe canary reviews | sed -n '/Events/,$p'
Events:
  Type     Reason  Age    From     Message
  ----     ------  ----   ----     -------
  Normal   Synced  6m     flagger  New revision detected! Scaling up reviews.bookinfo
  Normal   Synced  5m     flagger  Starting canary analysis for reviews.bookinfo
  Normal   Synced  5m     flagger  Advance reviews.bookinfo canary weight 10
  Normal   Synced  4m     flagger  Advance reviews.bookinfo canary weight 20
  Normal   Synced  3m     flagger  Advance reviews.bookinfo canary weight 30
  Normal   Synced  2m     flagger  Advance reviews.bookinfo canary weight 40
  Normal   Synced  1m     flagger  Advance reviews.bookinfo canary weight 50
  Normal   Synced  30s    flagger  Copying reviews.bookinfo template spec to reviews-primary
  Normal   Synced  10s    flagger  Promotion completed! Scaling down reviews.bookinfo
```

Un rollout abortado se ve así en cambio:

```console
  Warning  Synced  2m     flagger  Halt reviews.bookinfo advancement success rate 87.34% < 99%
  Warning  Synced  1m     flagger  Rolling back reviews.bookinfo failed checks threshold reached 5
  Warning  Synced  30s    flagger  Canary failed! Scaling down reviews.bookinfo
```

---

## 5. Verificación y diagnóstico de fallas

### La escalera de verificación

1. **La config parsea y las referencias resuelven** → `istioctl analyze` (captura subsets faltantes, typos de host, errores en el nombre del puerto — gratis, estático).
2. **istiod lo compiló** → `istioctl proxy-config routes` muestra `weightedClusters` con tus pesos.
3. **Los clusters de subset tienen endpoints** → `istioctl proxy-config clusters` + `endpoints` muestran `HEALTHY`.
4. **El tráfico realmente se divide** → conteo del bucle de curl *y* tasa por versión de Prometheus.
5. **La división es segura** → SLIs de tasa de éxito / latencia por versión.

### Verificación con Prometheus (fuente de la verdad para la automatización)

Tasa de requests por versión:

```promql
sum(rate(istio_requests_total{
  destination_service="reviews.bookinfo.svc.cluster.local"
}[1m])) by (destination_version)
```

Tasa de éxito por versión (la métrica que Flagger usa como puerta):

```promql
sum(rate(istio_requests_total{
  destination_service="reviews.bookinfo.svc.cluster.local",
  response_code!~"5.."}[1m])) by (destination_version)
/
sum(rate(istio_requests_total{
  destination_service="reviews.bookinfo.svc.cluster.local"}[1m])) by (destination_version)
```

Latencia p99 por versión:

```promql
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket{
    destination_service="reviews.bookinfo.svc.cluster.local"}[1m]))
  by (le, destination_version))
```

Kiali renderiza los mismos datos como un grafo en vivo con las etiquetas de peso en cada arista — la confirmación visual más rápida de que el tráfico está fluyendo a ambos subsets en la proporción configurada.

### Catálogo de fallas

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| **Todo el tráfico va a una versión sin importar los pesos** | Puerto no nombrado `http`/`http2`/`grpc` → tratado como L4, las reglas `http` se ignoran | `istioctl proxy-config listeners` muestra un TCP proxy, no un HTTP conn manager, en 9080 | Renombrar el puerto del Service (o poner `appProtocol: http`) y volver a aplicar |
| **`503 UC` / `503 NR`** (no route / no cluster) | El VS referencia un subset sin subset coincidente en el `DestinationRule` o sin pods `Ready` | `istioctl analyze` → IST0101; `proxy-config endpoints` muestra el cluster del subset vacío | Agregar el subset al DR, o asegurar que los pods lleven el label `version` y estén `Ready` |
| **`503 UH`** (no healthy upstream) | La outlier detection expulsó todos los endpoints de un canary malo | `proxy-config endpoints` muestra `OUTLIER CHECK: FAILED` | Poner el peso del canary en 0; investigar la fuente de los 5xx |
| **Los pesos se ignoran, el VS parece ausente** | El VS está en el namespace equivocado, o `hosts`/`gateways` no coinciden con el tráfico | `proxy-config routes` no muestra `weightedClusters` para el host | Poner el VS en el namespace alcanzable por el cliente; para tráfico de borde vincular `gateways:` y usar FQDN + `hosts` coincidentes |
| **El match de A/B nunca se dispara** | La regla de match está ordenada *después* del catch-all ponderado (gana el primer match) | Inspeccionar el orden de `http[]`; el catch-all sin `match` se traga todo lo de arriba | Mover la regla de `match` arriba del catch-all |
| **La proporción de la división está muy lejos del % configurado** | LB de consistent-hash con una clave sesgada, o muy pocos requests | `DestinationRule.trafficPolicy.loadBalancer.consistentHash` presente; tamaño de muestra bajo | Usar una clave de hash de mayor cardinalidad, o aumentar el tamaño de muestra antes de juzgar |
| **La versión reflejada causa corrupción de datos / duplicados** | Se está reflejando un camino de escritura no idempotente | Buscar `Host` con sufijo `-shadow` en los logs de v2 | Reflejar solo caminos de lectura, o rutear el mirror a un datastore de sandbox |
| **Los pesos se revierten solos** | Flagger/Argo es dueño del VirtualService y reconcilió tu edición manual | `kubectl get canary`; ownerReferences en el VS | Cambiar el rollout vía el CR `Canary`/`Rollout`, no el VS |
| **Ambient: los pesos L7 no tienen efecto** | No hay waypoint proxy para el destino; ztunnel es solo L4 | `istioctl waypoint list` no muestra ninguno para el namespace/servicio | `istioctl waypoint apply` y etiquetar el servicio para que lo use |

### Script de triage rápido

```console
$ CALLER=$(kubectl -n bookinfo get pod -l app=productpage -o name | head -1 | cut -d/ -f2)
$ echo "== analyze ==" && istioctl analyze -n bookinfo
$ echo "== routes ==" && istioctl pc routes "$CALLER.bookinfo" --name 9080 -o json \
    | jq '.[].virtualHosts[].routes[].route.weightedClusters'
$ echo "== endpoints v2 ==" && istioctl pc endpoints "$CALLER.bookinfo" \
    --cluster "outbound|9080|v2|reviews.bookinfo.svc.cluster.local"
```

Si los tres están en verde y el tráfico *igual* se comporta mal, la falla está en la capa de aplicación/datos del canary, no en el ruteo del mesh — pivotá a la consulta de tasa de éxito por versión.

---

## 6. Referencias

- Istio — Traffic Management (conceptos, VirtualService, DestinationRule): https://istio.io/latest/docs/concepts/traffic-management/
- Istio — Traffic Shifting task (recorrido del weighted canary): https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Istio — Request Routing (subsets, reglas de match): https://istio.io/latest/docs/tasks/traffic-management/request-routing/
- Istio — Mirroring / shadow traffic task: https://istio.io/latest/docs/tasks/traffic-management/mirroring/
- Istio — VirtualService API reference (`http`, `route`, `weight`, `mirror`, `mirrorPercentage`): https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — DestinationRule API reference (`subsets`, `trafficPolicy`, `loadBalancer`, `outlierDetection`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — Gateway API reference: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio — `istioctl proxy-config` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config
- Istio — `istioctl analyze` y mensajes de análisis de configuración (IST0101): https://istio.io/latest/docs/reference/config/analysis/
- Istio — Standard metrics (`istio_requests_total`, `istio_request_duration_milliseconds`): https://istio.io/latest/docs/reference/config/metrics/
- Istio — Ambient mesh, waypoint proxies y política L7: https://istio.io/latest/docs/ambient/usage/waypoint/
- Flagger — Istio Canary Deployments (entrega progresiva): https://docs.flagger.app/tutorials/istio-progressive-delivery
- Flagger — Canary custom resource reference: https://docs.flagger.app/usage/how-it-works
- Argo Rollouts — Traffic management con Istio: https://argoproj.github.io/argo-rollouts/features/traffic-management/istio/
- CNCF — ICA curriculum (dominio Traffic Management): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf