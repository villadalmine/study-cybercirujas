# Ejercicios Guiados — Tema 3.3: Definición de Políticas de Tráfico con Destination Rules

> **Certificación:** Istio Certified Associate (ICA) · **Dominio 3 — Gestión de Tráfico** · Peso del tema: 5
>
> **De qué trata realmente este tema.** Un `VirtualService` decide *hacia dónde* va una petición (enrutamiento). Un `DestinationRule` decide *qué le pasa una vez elegido el destino* (la **política** de tráfico aplicada al upstream cluster resultante) y *cómo se subdivide el destino en `subsets` con nombre*. En términos de Envoy, un `DestinationRule` configura el **upstream cluster**: su algoritmo de load-balancing, los topes del connection pool, el health checking pasivo (outlier detection) y el TLS que el sidecar origina hacia él. El enrutamiento (VirtualService) corre primero; la política (DestinationRule) se aplica al endpoint donde caés. Equivocá ese orden y tu circuit breaker o tu configuración de mTLS silenciosamente nunca se dispara.
>
> **Entorno asumido.** Una malla de Istio en ejecución (`istioctl version` tiene éxito), el namespace `default` etiquetado para inyección de sidecar (`kubectl label namespace default istio-injection=enabled`), y `kubectl`/`istioctl` en tu PATH. Donde un ejercicio necesita un generador de carga o un target, despliega `fortio`, `httpbin` y `sleep` desde los samples de Istio. Los manifiestos usan `apiVersion: networking.istio.io/v1` (la API estable actual; `v1beta1` sigue aceptándose y es byte por byte equivalente para estos campos).

---

## Ejercicio 1 — Subsets: nombrar versiones y conectarlas a un VirtualService

**Objetivo:** Definir `subsets` en un `DestinationRule` y demostrar que un `VirtualService` solo puede enrutar a un subset que un `DestinationRule` haya declarado. Vas a ver cómo cada subset se convierte en un *cluster de Envoy distinto*.

### Pasos

1. Desplegá el sample Bookinfo (trae tres versiones de `reviews` detrás de un único Service):

   ```bash
   kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
   kubectl rollout status deploy/reviews-v1 deploy/reviews-v2 deploy/reviews-v3
   ```

2. Confirmá que las tres versiones comparten un Service pero difieren por la etiqueta `version`:

   ```bash
   kubectl get pods -l app=reviews --show-labels
   ```

   Esperado (abreviado):

   ```
   NAME                          READY   STATUS    LABELS
   reviews-v1-6b7f...            2/2     Running   app=reviews,version=v1,...
   reviews-v2-79c8...            2/2     Running   app=reviews,version=v2,...
   reviews-v3-5b4d...            2/2     Running   app=reviews,version=v3,...
   ```

3. Creá un `DestinationRule` que talle el host `reviews` en tres subsets con nombre, indexados por esa etiqueta:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
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

   ```bash
   kubectl apply -f reviews-destinationrule.yaml
   ```

4. Inspeccioná los upstream clusters que Envoy ahora programa dentro del sidecar de `productpage`. Cada subset aparece como su propio cluster:

   ```bash
   PP=$(kubectl get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config cluster "$PP" --fqdn reviews.default.svc.cluster.local
   ```

   Esperado:

   ```
   SERVICE FQDN                              PORT   SUBSET   DIRECTION   TYPE
   reviews.default.svc.cluster.local         9080   -        outbound    EDS
   reviews.default.svc.cluster.local         9080   v1       outbound    EDS
   reviews.default.svc.cluster.local         9080   v2       outbound    EDS
   reviews.default.svc.cluster.local         9080   v3       outbound    EDS
   ```

   El subset queda codificado en el nombre del cluster de Envoy como `outbound|9080|v2|reviews.default.svc.cluster.local`.

5. Fijá todo el tráfico a `v2` con un `VirtualService` que referencie el subset **por nombre**:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews
   spec:
     hosts:
     - reviews
     http:
     - route:
       - destination:
           host: reviews
           subset: v2
   ```

   ```bash
   kubectl apply -f reviews-vs-v2.yaml
   ```

6. Ahora rompelo a propósito. Editá el `VirtualService` para que enrute a `subset: v4` (un nombre que ningún `DestinationRule` define), volvé a aplicarlo y generá tráfico:

   ```bash
   kubectl exec "$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')" \
     -c sleep -- curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/productpage
   ```

   Esperado: la sección de reviews falla y la productpage renderiza el fallback "reviews service unavailable"; el log del sidecar de `productpage` muestra `503 UH` (no healthy upstream — el cluster no existe porque ningún subset define `v4`).

7. Restaurá la ruta funcional `subset: v2` antes de continuar.

> **Comprobá lo que entendiste — Ejercicio 1**
> 1. ¿Cuál es la diferencia funcional entre el campo `spec.host` de un `DestinationRule` y el bloque `labels` de un subset?
> 2. En el paso 4 viste un cluster sin subset *y* tres clusters con subset para el mismo FQDN. ¿Cuándo se usa el cluster sin subset (`SUBSET -`)?
> 3. En el paso 6, ¿por qué enrutar a un subset no definido produce un `503`, y qué componente (VirtualService o DestinationRule) es la verdadera fuente de verdad sobre si un subset "existe"?
> 4. ¿Podrías lograr el mismo enrutamiento solo-a-v2 con un `VirtualService` únicamente, sin `DestinationRule`? ¿Por qué sí o por qué no?

---

## Ejercicio 2 — Política de load balancing y afinidad de sesión (consistent hashing)

**Objetivo:** Configurar el algoritmo de load-balancing a nivel de `DestinationRule`, verificar que quede programado en Envoy, y pasar a **consistent hashing** para obtener sesiones pegajosas sin un backend con estado.

### Pasos

1. Configurá un simple load balancer explícito en todo el host `reviews` y volvé a aplicar el DestinationRule del Ejercicio 1 con un `trafficPolicy` agregado en el nivel superior:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
     trafficPolicy:
       loadBalancer:
         simple: LEAST_REQUEST
     subsets:
     - name: v1
       labels:
         version: v1
     - name: v2
       labels:
         version: v2
       trafficPolicy:
         loadBalancer:
           simple: ROUND_ROBIN     # subset override
     - name: v3
       labels:
         version: v3
   ```

   ```bash
   kubectl apply -f reviews-lb.yaml
   ```

2. Confirmá el algoritmo *efectivo* por cluster. La política de nivel superior aplica a `v1`/`v3`, mientras que `v2` lleva la suya propia:

   ```bash
   istioctl proxy-config cluster "$PP" \
     --fqdn reviews.default.svc.cluster.local --subset v2 -o json \
     | grep -i lbPolicy
   ```

   Esperado:

   ```json
   "lbPolicy": "ROUND_ROBIN",
   ```

   Repetí con `--subset v1` y observá `"lbPolicy": "LEAST_REQUEST"`.

3. Ahora pasá `reviews` a **consistent hashing** sobre un header HTTP, de modo que cada petición que lleve el mismo valor de `x-user` caiga siempre en el mismo endpoint (afinidad de sesión):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
     trafficPolicy:
       loadBalancer:
         consistentHash:
           httpHeaderName: x-user
     subsets:
     - name: v1
       labels: { version: v1 }
     - name: v2
       labels: { version: v2 }
     - name: v3
       labels: { version: v3 }
   ```

   ```bash
   kubectl apply -f reviews-hash.yaml
   ```

4. Verificá que Envoy ahora use una política basada en ring-hash:

   ```bash
   istioctl proxy-config cluster "$PP" \
     --fqdn reviews.default.svc.cluster.local --subset v1 -o json \
     | grep -iE 'lbPolicy|ringHash|maglev'
   ```

   Esperado (ring hash es la implementación de consistent-hash por defecto):

   ```json
   "lbPolicy": "RING_HASH",
   ```

5. Revisá las otras claves de consistent-hash que podrías haber usado en lugar de un header — `httpCookie` (Istio puede *generar* la cookie si está ausente), `useSourceIp: true`, o `httpQueryParameterName`:

   ```yaml
   consistentHash:
     httpCookie:
       name: session-id
       ttl: 3600s
   ```

> **Comprobá lo que entendiste — Ejercicio 2**
> 1. Ordená estos valores `simple` según qué problema resuelve cada uno: `ROUND_ROBIN`, `LEAST_REQUEST`, `RANDOM`, `PASSTHROUGH`. ¿Cuál le dice a Envoy que *no* haga load-balancing y entregue la conexión directo a la IP de destino original?
> 2. En el paso 2, ¿por qué `v2` reportó `ROUND_ROBIN` mientras `v1` reportó `LEAST_REQUEST` desde el *mismo* DestinationRule?
> 3. El consistent hashing te da sesiones pegajosas — pero pegajosas ¿a *qué*, exactamente? ¿Qué le pasa a la afinidad de un cliente existente cuando se agrega o se quita un pod del backend, y por qué es una disrupción menor que un esquema ingenuo de `hash(key) % N`?
> 4. En el paso 3 configuraste `consistentHash` en el nivel superior, pero el campo vive bajo `loadBalancer`, que es mutuamente excluyente con `simple`. ¿Qué haría aplicar ambos en el mismo bloque `loadBalancer`?

---

## Ejercicio 3 — Límites del connection pool: circuit breaking ante sobrecarga

**Objetivo:** Usar `connectionPool` para topear las conexiones concurrentes y las peticiones pendientes, luego llevar la carga más allá de esos límites y ver a Envoy descartar el excedente con `503`s (el "circuit breaker disparándose"). Confirmar el disparo en las stats crudas de Envoy.

### Pasos

1. Desplegá `httpbin` (la víctima) y `fortio` (el generador de carga):

   ```bash
   kubectl apply -f samples/httpbin/httpbin.yaml
   kubectl apply -f samples/httpbin/sample-client/fortio-deploy.yaml
   kubectl rollout status deploy/httpbin deploy/fortio-deploy
   ```

2. Aplicá un connection pool deliberadamente diminuto para que sea fácil desbordarlo:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       connectionPool:
         tcp:
           maxConnections: 1
         http:
           http1MaxPendingRequests: 1
           maxRequestsPerConnection: 1
   ```

   ```bash
   kubectl apply -f httpbin-cb.yaml
   ```

3. Enviá primero una **única** petición (1 conexión, bien dentro del límite — esto debe tener éxito):

   ```bash
   FORTIO=$(kubectl get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$FORTIO" -c fortio -- /usr/bin/fortio load \
     -c 1 -qps 0 -n 1 -loglevel Warning http://httpbin:8000/get
   ```

   Esperado: `Code 200 : 1 (100.0 %)`.

4. Ahora disparalo: **dos conexiones concurrentes**, veinte peticiones, contra un pool dimensionado para una:

   ```bash
   kubectl exec "$FORTIO" -c fortio -- /usr/bin/fortio load \
     -c 2 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
   ```

   Esperado (las proporciones varían de corrida en corrida — el punto es que una porción es rechazada):

   ```
   Code 200 : 15 (75.0 %)
   Code 503 : 5 (25.0 %)
   ```

5. Probá *por qué* ocurrieron esos `503`s — Envoy incrementa un contador de overflow de pendientes, no un error de backend:

   ```bash
   kubectl exec "$FORTIO" -c istio-proxy -- \
     pilot-agent request GET stats | grep httpbin | grep -E 'pending|cx_overflow'
   ```

   Esperado (un overflow distinto de cero es la evidencia contundente):

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_overflow: 5
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_cx_overflow: 0
   ```

6. Correlacioná con la telemetría de peticiones: las peticiones desbordadas llevan el response flag de Envoy `UO` (upstream overflow). En el access log del sidecar o en la métrica `istio_requests_total` aparecen como `response_flags="UO"`.

7. Subí los topes (`maxConnections: 10`, `http1MaxPendingRequests: 10`), volvé a aplicar, volvé a correr el paso 4 y confirmá que la proporción de `503` cae hacia cero.

> **Comprobá lo que entendiste — Ejercicio 3**
> 1. Distinguí `tcp.maxConnections`, `http.http1MaxPendingRequests` y `http.maxRequestsPerConnection`. ¿Cuál gobierna las peticiones *encoladas* esperando una conexión libre?
> 2. Una petición rechazada por el connection pool devuelve `503` con el response flag `UO`. ¿En qué se diferencia fundamentalmente, para la *interpretación del cliente*, de un `503` devuelto por el backend real de httpbin?
> 3. En el paso 3 una única conexión tuvo éxito, pero el paso 4 con `-c 2` falló un cuarto de las peticiones. Explicá el mecanismo en términos del pool de tamaño 1.
> 4. ¿Por qué se considera que topear el connection pool es un mecanismo de *load-shedding / fail-fast* en vez de un mecanismo de resiliencia? ¿Qué necesita hacer el llamante para beneficiarse realmente de él?

---

## Ejercicio 4 — Outlier detection: health checking pasivo que expulsa endpoints defectuosos

**Objetivo:** Agregar `outlierDetection` para que Envoy vigile *pasivamente* las respuestas del upstream y expulse temporalmente un endpoint que sigue devolviendo errores — un circuit breaker por endpoint superpuesto sobre el del connection-pool.

### Pasos

1. Escalá `httpbin` a tres réplicas para que haya algo *de dónde* expulsar:

   ```bash
   kubectl scale deploy/httpbin --replicas=3
   kubectl rollout status deploy/httpbin
   ```

2. Agregá outlier detection al DestinationRule (manteniendo esta vez un connection pool generoso para que no sea el pool lo que se dispare):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       connectionPool:
         http:
           http1MaxPendingRequests: 100
         tcp:
           maxConnections: 100
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 5s
         baseEjectionTime: 30s
         maxEjectionPercent: 66
         minHealthPercent: 34
   ```

   ```bash
   kubectl apply -f httpbin-outlier.yaml
   ```

3. Hacé que un endpoint falle de forma confiable. `httpbin` tiene un endpoint `/status/{code}`; dirigí `500`s repetidos al service para que al menos un endpoint acumule tres fallos consecutivos:

   ```bash
   kubectl exec "$FORTIO" -c fortio -- /usr/bin/fortio load \
     -c 3 -qps 0 -n 60 -loglevel Warning http://httpbin:8000/status/500
   ```

4. Mirá cómo trepan los contadores de expulsión:

   ```bash
   kubectl exec "$FORTIO" -c istio-proxy -- \
     pilot-agent request GET stats | grep httpbin | grep outlier_detection
   ```

   Esperado (un `ejections_active` distinto de cero mientras un endpoint está penalizado):

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_enforced_consecutive_5xx: 2
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_active: 1
   ```

5. Confirmá la válvula de seguridad: con `maxEjectionPercent: 66` y tres endpoints, Envoy expulsará como máximo dos — nunca los tres — incluso ante fallo total, porque `minHealthPercent`/`maxEjectionPercent` impiden un pool vacío. Verificá que la cuenta de endpoints sanos en el cluster no caiga a cero:

   ```bash
   istioctl proxy-config endpoint "$FORTIO" --cluster \
     "outbound|8000||httpbin.default.svc.cluster.local"
   ```

6. Detené la carga fallida y esperá `baseEjectionTime` (30s). El endpoint es readmitido; un reincidente es expulsado por `2 × baseEjectionTime`, luego `3 ×`, y así sucesivamente (la penalización crece con la cuenta de expulsiones).

> **Comprobá lo que entendiste — Ejercicio 4**
> 1. Al outlier detection se lo llama health checking *pasivo*. ¿Qué está observando, y en qué difiere de una sonda de salud *activa* (como una readiness probe de Kubernetes)?
> 2. ¿Qué controla cada uno de `consecutive5xxErrors`, `interval` y `baseEjectionTime`? ¿Cuál determina cada cuánto Envoy *evalúa* la expulsión, y cuál determina cuánto *dura* la primera expulsión?
> 3. Con tres endpoints, `maxEjectionPercent: 66`, y los tres fallando, ¿cuántos puede expulsar Envoy — y por qué negarse a expulsar el último es el comportamiento correcto?
> 4. `outlierDetection` y `connectionPool` pueden ambos producir `503`s. ¿Cuál te protege de un *único pod enfermo*, y cuál protege al *upstream entero* de ser desbordado?

---

## Ejercicio 5 — Política de tráfico TLS, más overrides a nivel de puerto y de subset

**Objetivo:** Usar el bloque `tls` de un `trafficPolicy` para controlar el TLS que el sidecar *origina* hacia el upstream — tanto interno a la malla (`ISTIO_MUTUAL`) como origination de TLS hacia un servicio externo — y ver cómo `portLevelSettings` y la política por subset sobrescriben la política de nivel superior.

### Pasos

1. Configurá mTLS de malla explícitamente para un host del lado cliente. `ISTIO_MUTUAL` le dice al sidecar que origine mutual TLS usando los certificados de workload gestionados por Istio (no hacen falta rutas de key/cert):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin-mtls
   spec:
     host: httpbin
     trafficPolicy:
       tls:
         mode: ISTIO_MUTUAL
   ```

   ```bash
   kubectl apply -f httpbin-mtls.yaml
   ```

   > **Gotcha para internalizar:** si el `PeerAuthentication` del lado servidor es `STRICT` pero un `DestinationRule` configura `tls.mode: DISABLE` para ese mismo host, el cliente envía texto plano a un puerto que solo acepta mTLS y toda petición falla con `503`. `DestinationRule.tls` (origination del cliente) y `PeerAuthentication` (aceptación del servidor) deben coincidir.

2. Demostrá **TLS origination** hacia un sitio HTTPS externo. Registrá el host externo, luego hacé que el DestinationRule eleve el texto-plano-a-`edition.cnn.com:80` del sidecar a TLS real en el puerto 443:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: ServiceEntry
   metadata:
     name: edition-cnn-com
   spec:
     hosts:
     - edition.cnn.com
     ports:
     - number: 80
       name: http-port
       protocol: HTTP
       targetPort: 443
     resolution: DNS
   ---
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: originate-tls-cnn
   spec:
     host: edition.cnn.com
     trafficPolicy:
       portLevelSettings:
       - port:
           number: 80
         tls:
           mode: SIMPLE       # sidecar originates one-way TLS
           sni: edition.cnn.com
   ```

   ```bash
   kubectl apply -f cnn-tls-origination.yaml
   SLEEP=$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP" -c sleep -- \
     curl -sIL http://edition.cnn.com/politics | head -n1
   ```

   Esperado: `HTTP/1.1 200 OK` — la app habló *HTTP plano al puerto 80*, y el sidecar lo envolvió transparentemente en TLS.

3. Combiná todo en un único DestinationRule que muestre la **jerarquía de overrides** — un default de nivel superior, un override por puerto y un override por subset:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews-layered
   spec:
     host: reviews
     trafficPolicy:                 # (A) applies to every subset & port unless overridden
       loadBalancer:
         simple: LEAST_REQUEST
       connectionPool:
         tcp:
           maxConnections: 100
     subsets:
     - name: v1
       labels: { version: v1 }
     - name: v2
       labels: { version: v2 }
       trafficPolicy:               # (B) subset override — replaces (A) for v2
         loadBalancer:
           simple: ROUND_ROBIN
         portLevelSettings:
         - port:
             number: 9080
           loadBalancer:            # (C) port override — most specific, wins for v2:9080
             consistentHash:
               useSourceIp: true
     - name: v3
       labels: { version: v3 }
   ```

   ```bash
   kubectl apply -f reviews-layered.yaml
   ```

4. Verificá la política efectiva en cada nivel:

   ```bash
   # v1 → inherits (A)
   istioctl proxy-config cluster "$PP" --fqdn reviews.default.svc.cluster.local \
     --subset v1 -o json | grep -i lbPolicy      # LEAST_REQUEST
   # v2:9080 → (C) wins
   istioctl proxy-config cluster "$PP" --fqdn reviews.default.svc.cluster.local \
     --subset v2 -o json | grep -iE 'lbPolicy|ringHash'   # RING_HASH (from useSourceIp)
   ```

> **Comprobá lo que entendiste — Ejercicio 5**
> 1. ¿Qué significan `DISABLE`, `SIMPLE`, `MUTUAL` e `ISTIO_MUTUAL` cada uno para el TLS que el sidecar *origina*? ¿Cuál requiere que aportes tu propio cert/key de cliente, y cuál usa los certs de workload automáticos de Istio?
> 2. En el paso 2 la aplicación emitió una petición `http://` plana, pero la conexión hacia CNN estaba cifrada. ¿Dónde ocurrió el handshake de TLS, y qué le da eso a una aplicación que no tiene código de TLS?
> 3. Enunciá el orden de precedencia entre el `trafficPolicy` de nivel superior, el `trafficPolicy` por subset y `portLevelSettings`. En el paso 3, ¿qué política de load-balancer está realmente en efecto para `v2` en el puerto `9080`, y para `v3` en el puerto `9080`?
> 4. Un subset define un `trafficPolicy` con *solo* `loadBalancer`. ¿Sigue heredando el `connectionPool` de nivel superior, o declarar un `trafficPolicy` de subset borra todo lo que no se reafirme? (Razonalo a partir de lo que viste, después chequeá la respuesta.)

---

## Limpieza

```bash
kubectl delete destinationrule reviews reviews-layered httpbin httpbin-mtls originate-tls-cnn --ignore-not-found
kubectl delete virtualservice reviews --ignore-not-found
kubectl delete serviceentry edition-cnn-com --ignore-not-found
kubectl delete -f samples/httpbin/sample-client/fortio-deploy.yaml --ignore-not-found
kubectl delete -f samples/httpbin/httpbin.yaml --ignore-not-found
kubectl delete -f samples/bookinfo/platform/kube/bookinfo.yaml --ignore-not-found
```

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Ejercicio 1

1. **`spec.host`** selecciona *qué* servicio (por nombre corto o FQDN) gobierna la regla — es el destino al que se adjuntan la política y los subsets. El bloque **`labels`** de un subset es un *filtro* de endpoints: entre los pods detrás de ese host, un subset es exactamente aquellos cuyas etiquetas de pod coinciden con cada clave/valor listado. `host` elige el servicio; `labels` recorta ese servicio en grupos direccionables.
2. El cluster sin subset (`SUBSET -`) es el upstream por defecto usado cada vez que una ruta apunta al host **sin** nombrar un subset — p. ej. una ruta de `VirtualService` con solo `host: reviews` y sin `subset:`, o tráfico de servicio directo que no queda matcheado por ninguna ruta específica de subset. Balancea la carga entre *todos* los endpoints del servicio.
3. Enrutar a `subset: v4` falla porque Istio programa un cluster de Envoy **por subset declarado**; `v4` no está declarado en ningún lado, así que no existe ningún cluster, y Envoy responde `503 UH` (no healthy upstream). El **DestinationRule es la fuente de verdad** para qué subsets existen — un `VirtualService` solo puede *referenciar* nombres que el DestinationRule creó. Un nombre de subset en un VirtualService es un puntero colgante hasta que un DestinationRule lo define.
4. **No.** El campo `subset` de una ruta de `VirtualService` solo tiene sentido si un `DestinationRule` definió ese subset. Sin un DestinationRule podés enrutar al *host* `reviews`, pero no podés expresar "solo los endpoints `v2`" — el VirtualService no tiene capacidad de selección por etiquetas propia; la definición de subsets es competencia exclusiva del DestinationRule.

### Ejercicio 2

1. `ROUND_ROBIN` — repartir peticiones de forma pareja, basado en orden (simple, predecible). `LEAST_REQUEST` — enviar al endpoint con menos peticiones activas (mejor default para costos de petición dispares; la elección de propósito general recomendada por Istio). `RANDOM` — elegir de manera uniformemente aleatoria, sin coordinación (bueno cuando no podés confiar en las señales de conteo de peticiones). `PASSTHROUGH` — **no hacer load-balancing**; reenviar la conexión a la IP de destino original que pidió el llamante (se usa en escenarios pass-through/opacos). `PASSTHROUGH` es el que deshabilita el balanceo.
2. Porque un **`trafficPolicy` por subset sobrescribe el `trafficPolicy` de nivel superior** solo para ese subset. El `loadBalancer: LEAST_REQUEST` de nivel superior del DestinationRule aplica a `v1` y `v3`, pero `v2` reafirmó `loadBalancer: ROUND_ROBIN`, así que el cluster de `v2` queda programado con round-robin.
3. La pegajosidad es hacia un **endpoint (pod) específico del upstream**, indexado por el atributo elegido (header, cookie, source IP o query param) — cada petición con el mismo valor de clave hashea al mismo endpoint. Cuando se agrega/quita un endpoint, el consistent hashing (ring/Maglev) remapea solo la fracción de claves que caían cerca del nodo cambiado en el ring de hash — aproximadamente `1/N` de las claves se mueven — mientras que `hash(key) % N` cambia el divisor y **rebaraja casi todas las claves**. Esa disrupción acotada es todo el propósito del consistent hashing.
4. `simple` y `consistentHash` son **mutuamente excluyentes dentro de un mismo `loadBalancer`**; configurás uno *o* el otro. Aportar ambos es configuración inválida — Istio la rechazará (o uno es ignorado). El consistent hashing *es* el algoritmo de load-balancing en ese caso, así que no hay nada que `simple` pueda también especificar.

### Ejercicio 3

1. `tcp.maxConnections` topea la cantidad de conexiones TCP concurrentes que el sidecar abre hacia el upstream. `http.http1MaxPendingRequests` topea las peticiones **encoladas** esperando que una conexión/stream se libere — esta es la cola de "pending". `http.maxRequestsPerConnection` limita cuántas peticiones reutilizan una única conexión antes de cerrarla (1 = sin reutilización keep-alive). El límite de **pending** gobierna las peticiones encoladas.
2. Un `503 UO` significa que la petición **nunca llegó a httpbin** — el sidecar local la rechazó para proteger el pool; el backend probablemente está sano. Un `503` de backend significa que httpbin mismo falló al servir. Para el llamante, `UO` dice "aflojá / reintentá más tarde, el camino está saturado", mientras que un `503` de backend dice "el servicio erró". Confundirlos lleva a culpar a un backend sano por una sobrecarga del lado cliente.
3. El pool permite una conexión y una petición pendiente. Con `-c 1` siempre hay una conexión disponible, así que la petición tiene éxito. Con `-c 2`, dos conexiones compiten por un pool de tamaño 1: una avanza, la segunda solo puede quedar *encolada*, y una vez que el único slot de pending también está tomado, cualquier petición concurrente adicional desborda y es rechazada con `503 UO`. De ahí que una fracción falle.
4. Porque **rechaza el exceso de carga de inmediato** en vez de dejarlo encolarse sin límite y arrastrar latencia/memoria por todo el servicio — falla *rápido* en vez de degradar a todos. Solo es *resiliencia* si el llamante coopera: el cliente (o una política de retry de `VirtualService`) debe **reintentar con backoff**, idealmente contra otro endpoint. Sin lógica de retry, el fail-fast simplemente le muestra el `503` al usuario.

### Ejercicio 4

1. El health checking pasivo **observa respuestas reales de producción** (conteos de 5xx, fallos de conexión, timeouts) que fluyen a través de Envoy y expulsa endpoints que se portan mal — sin tráfico sintético. Una sonda activa (readiness probe de Kubernetes) *genera* peticiones de salud dedicadas según un cronograma. La detección pasiva reacciona a lo que los usuarios realmente experimentan y no necesita ningún endpoint extra, pero solo "ve" un pod defectuoso una vez que peticiones reales ya lo golpearon.
2. `consecutive5xxErrors` — cuántos 5xx consecutivos (errores de origen servidor) disparan la expulsión. `interval` — cada cuánto Envoy barre el pool para evaluar/aplicar la expulsión. `baseEjectionTime` — cuánto dura la *primera* expulsión (las expulsiones subsiguientes se multiplican por la cuenta de expulsiones). Así que `interval` = cadencia de evaluación, `baseEjectionTime` = duración de la primera penalización.
3. Como máximo **dos** (66% de tres, redondeado hacia abajo). Envoy se niega a expulsar el tercero aunque también esté fallando, porque `maxEjectionPercent`/`minHealthPercent` garantizan un pool no vacío — expulsar el último endpoint dejaría *ningún lugar* a dónde enrutar, convirtiendo una interrupción parcial en una total. Mantener un endpoint (incluso uno enfermo) preserva una chance de éxito y permite observar la recuperación.
4. `outlierDetection` te protege de un **único pod enfermo** al sacarlo de rotación mientras los demás siguen sirviendo. `connectionPool` protege al **upstream entero** (y al llamante) de ser desbordado al topear la concurrencia y descartar el excedente. Uno es cuarentena por endpoint; el otro es limitación agregada de tasa/concurrencia.

### Ejercicio 5

1. `DISABLE` — enviar texto plano, sin TLS. `SIMPLE` — originar TLS estándar de una vía (con servidor autenticado), como un cliente HTTPS normal. `MUTUAL` — originar mutual TLS usando **tu propio** `clientCertificate`/`privateKey`/`caCertificates` aportado. `ISTIO_MUTUAL` — originar mutual TLS usando los **certificados de workload provisionados automáticamente por Istio** (identidades SPIFFE), sin rutas requeridas. `MUTUAL` necesita tu propio cert/key; `ISTIO_MUTUAL` usa los de Istio.
2. El **sidecar (Envoy) originó el handshake de TLS** en el camino de salida: la app habló HTTP plano al puerto 80, el `ServiceEntry` + `DestinationRule` (`tls.mode: SIMPLE`, puerto `80→443`) le dijo al sidecar que estableciera TLS con `edition.cnn.com` en 443. Esto le da a una aplicación sin conocimiento de TLS **cifrado en tránsito, SNI y manejo de certificados gratis** — descargado a la malla, gestionado y auditable centralmente, sin ningún cambio de código de la aplicación.
3. Precedencia, gana el más específico: **`portLevelSettings` (por puerto) > `trafficPolicy` por subset > `trafficPolicy` de nivel superior.** Para `v2` en el puerto `9080`, gana el `consistentHash.useSourceIp` de nivel de puerto (C) → **RING_HASH**. Para `v3` en el puerto `9080`, `v3` no declaró política de subset, así que hereda el **`LEAST_REQUEST` de nivel superior** (A).
4. **Sigue heredando** el `connectionPool` de nivel superior. Un `trafficPolicy` de subset sobrescribe el nivel superior **campo por campo**, no en bloque — reafirmar solo `loadBalancer` reemplaza únicamente la configuración de load-balancer; `connectionPool`, `outlierDetection`, `tls`, etc. que el subset *no* reafirma siguen viniendo de la política de nivel superior. (Por eso `v2` en el Ejercicio 5 igual disfrutó del `maxConnections: 100` de nivel superior aunque solo reafirmó el load balancer.)

</details>

---

### Fuentes

- Referencia de Istio — DestinationRule (campos: `host`, `subsets`, `trafficPolicy`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Conceptos de Istio — Destination rules y subsets: https://istio.io/latest/docs/concepts/traffic-management/#destination-rules
- LoadBalancerSettings (`simple`, `consistentHash`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#LoadBalancerSettings
- ConnectionPoolSettings (`tcp`, `http`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ConnectionPoolSettings
- OutlierDetection (health checking pasivo): https://istio.io/latest/docs/reference/config/networking/destination-rule/#OutlierDetection
- ClientTLSSettings (`DISABLE`/`SIMPLE`/`MUTUAL`/`ISTIO_MUTUAL`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Task — Circuit Breaking (connection pool + outlier detection con fortio): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Task — TLS origination para un servicio externo: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Task — Traffic shifting / subsets con VirtualService: https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Currículum de ICA (CNCF): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf