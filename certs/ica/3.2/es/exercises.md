# Ejercicios — Tema 3.2: Configuración de enrutamiento dentro de un Service Mesh

> **Certificación:** Istio Certified Associate (ICA) · **Dominio:** Traffic Management · **Peso en el examen:** 5
> **Lo que vas a practicar:** aplicar `VirtualService` + `DestinationRule` para controlar el enrutamiento L7 dentro del mesh — enrutamiento por subset, desvío de tráfico ponderado (canary), enrutamiento basado en match, inyección de fallos, timeouts, retries, mirroring de peticiones, enrutamiento de ingress a través de un `Gateway`, y diagnóstico de rutas con `istioctl`.
>
> Todos los manifiestos de abajo usan el grupo de API estable `networking.istio.io/v1` (GA desde Istio 1.22). En meshes más viejos sustituí por `v1beta1`; el esquema es idéntico para los campos usados acá.

---

## Ejercicio 0 — Preparar el mesh y la aplicación de ejemplo

Necesitás un mesh en ejecución con inyección de sidecar y la demo Bookinfo, cuyo servicio `reviews` incluye tres versiones (`v1` = sin estrellas, `v2` = estrellas negras, `v3` = estrellas rojas). Esto hace que los cambios de enrutamiento sean *visibles* en la página del producto.

1. Confirmá que el control plane esté sano y anotá la versión:

   ```bash
   istioctl version
   ```

   ```
   client version: 1.24.1
   control plane version: 1.24.1
   data plane version: 1.24.1 (8 proxies)
   ```

2. Habilitá la inyección automática de sidecar en el namespace objetivo y desplegá Bookinfo:

   ```bash
   kubectl label namespace default istio-injection=enabled --overwrite
   kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
   ```

3. Esperá hasta que cada pod esté `2/2` (el contenedor de la app **más** el sidecar `istio-proxy`):

   ```bash
   kubectl get pods
   ```

   ```
   NAME                              READY   STATUS    RESTARTS   AGE
   details-v1-5f4d584748-8xk2z       2/2     Running   0          61s
   productpage-v1-564d4686f-2rl7q    2/2     Running   0          60s
   ratings-v1-686ccfb5d8-9nq4p       2/2     Running   0          61s
   reviews-v1-86896b7648-7t2sd       2/2     Running   0          60s
   reviews-v2-b7dcd98fb-4kd6l        2/2     Running   0          60s
   reviews-v3-5b9bd44f4-plj9m        2/2     Running   0          60s
   ```

4. Generá tráfico desde dentro del mesh y observá que, **sin** reglas de enrutamiento, las peticiones se balancean entre las tres versiones de `reviews` en round-robin:

   ```bash
   for i in $(seq 1 6); do
     kubectl exec deploy/ratings-v1 -c ratings -- \
       curl -s http://productpage:9080/productpage | grep -o 'reviews-v[0-9]*' | head -1
   done
   ```

   ```
   reviews-v1
   reviews-v2
   reviews-v3
   reviews-v1
   reviews-v2
   reviews-v3
   ```

**Comprobá tu comprensión — 0**

- **0.1** Los pods muestran `2/2` en vez de `1/1`. ¿Cuál es el segundo contenedor, y *cómo* llega a interceptar el tráfico del pod sin ningún cambio en el código de la aplicación?
- **0.2** Sin ningún objeto `VirtualService`/`DestinationRule` aplicado, ¿por qué el tráfico sigue llegando a las tres versiones de `reviews`, y qué componente decide la distribución?

---

## Ejercicio 1 — Fijar el tráfico con subsets (`DestinationRule` + `VirtualService`)

Un `VirtualService` solo puede enrutar a un **subset** si un `DestinationRule` *definió* ese subset a partir de las labels de los pods. Vas a fijar todo el tráfico de `reviews` a `v1`.

1. Definí los subsets para cada servicio de Bookinfo. Los subsets son grupos con nombre de endpoints seleccionados por label:

   ```yaml
   # destination-rules-all.yaml
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
   ---
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: ratings
   spec:
     host: ratings
     subsets:
       - name: v1
         labels:
           version: v1
   ```

   ```bash
   kubectl apply -f destination-rules-all.yaml
   ```

2. Enrutá el 100% de `reviews` al subset `v1`:

   ```yaml
   # vs-reviews-v1.yaml
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
               subset: v1
   ```

   ```bash
   kubectl apply -f vs-reviews-v1.yaml
   ```

3. Validá la configuración con el analizador estático *antes* de confiar en el runtime:

   ```bash
   istioctl analyze
   ```

   ```
   ✔ No validation issues found when analyzing namespace: default.
   ```

4. Volvé a correr el bucle de tráfico del Ejercicio 0.4. Ahora cada petición debe llegar a `reviews-v1` (la versión sin estrellas).

   ```
   reviews-v1
   reviews-v1
   reviews-v1
   reviews-v1
   reviews-v1
   reviews-v1
   ```

5. Demostrá *por qué* un subset faltante rompe el enrutamiento: aplicá temporalmente un `VirtualService` que apunte a `subset: v2` **sin** que el DestinationRule esté presente y observá cómo `istioctl analyze` lo marca (después revertí):

   ```
   Error [IST0101] (VirtualService reviews) Referenced host+subset in destinationrule not found: "reviews+v2"
   ```

**Comprobá tu comprensión — 1**

- **1.1** ¿Cuál es la división precisa de responsabilidades entre el `DestinationRule` y el `VirtualService` acá? ¿Qué objeto *nombra* un subset y qué objeto lo *selecciona* como destino de ruta?
- **1.2** En `spec.host: reviews`, el valor es un nombre corto. ¿A qué lo expande Istio, y por qué un nombre corto pelado es un riesgo de portabilidad entre namespaces?
- **1.3** Si aplicás el `VirtualService` que apunta a `subset: v2` pero te olvidás del `DestinationRule`, ¿qué recibe una petición de un cliente en runtime, y qué check gratuito lo detecta antes de que lo haga un usuario?

---

## Ejercicio 2 — Enrutamiento basado en match sobre una cabecera HTTP

Enrutá a los usuarios identificados por la cabecera `end-user: jason` a `reviews v2`, y a todos los demás a `v1`. El orden importa: Istio evalúa las reglas `http[]` **de arriba hacia abajo** y toma el primer match.

1. Aplicá el enrutamiento condicional:

   ```yaml
   # vs-reviews-header.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews
   spec:
     hosts:
       - reviews
     http:
       - match:
           - headers:
               end-user:
                 exact: jason
         route:
           - destination:
               host: reviews
               subset: v2
       - route:                     # default / fallthrough — no match block
           - destination:
               host: reviews
               subset: v1
   ```

   ```bash
   kubectl apply -f vs-reviews-header.yaml
   ```

2. En la página de producto de Bookinfo, iniciá sesión como el usuario **jason** (cualquier contraseña). El panel de reviews ahora muestra **estrellas negras** (`v2`). Iniciá sesión como cualquier otro usuario, o navegá de forma anónima — no vas a ver estrellas (`v1`).

3. Confirmá el origen de la cabecera: el servicio `productpage` es el que reenvía la cabecera `end-user` aguas abajo hacia `reviews`. Inspeccioná la ruta efectiva que compiló el sidecar:

   ```bash
   istioctl proxy-config routes deploy/productpage-v1 --name 9080 -o json | \
     jq '.[0].virtualHosts[].routes[] | {match, route: .route.cluster}'
   ```

   ```json
   {
     "match": { "headers": [ { "name": "end-user", "exactMatch": "jason" } ], "prefix": "/" },
     "route": "outbound|9080|v2|reviews.default.svc.cluster.local"
   }
   {
     "match": { "prefix": "/" },
     "route": "outbound|9080|v1|reviews.default.svc.cluster.local"
   }
   ```

**Comprobá tu comprensión — 2**

- **2.1** Si invertís el orden de las dos entradas `http[]` (la regla por defecto primero), ¿qué le pasa al tráfico de jason, y por qué?
- **2.2** Aparecen una entrada de ruta con un bloque `match` **y** una entrada de ruta sin él. ¿Cuál es el rol de la entrada sin match, y qué recibiría una petición que no coincide con *ninguna* regla si se la eliminara?
- **2.3** El nombre del cluster de Envoy es `outbound|9080|v2|reviews.default.svc.cluster.local`. Decodificá cada uno de los cuatro campos separados por `|`.

---

## Ejercicio 3 — Desvío de tráfico ponderado (lanzamiento canary)

Migrá `reviews` de `v1` hacia `v3` (estrellas rojas) por etapas usando `weight`. Este es el mecanismo detrás de canary y blue/green.

1. Enviá el 90% a `v1`, el 10% a `v3`:

   ```yaml
   # vs-reviews-canary.yaml
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
               subset: v1
             weight: 90
           - destination:
               host: reviews
               subset: v3
             weight: 10
   ```

   ```bash
   kubectl apply -f vs-reviews-canary.yaml
   ```

2. Lanzá 100 peticiones y contá la división de forma empírica:

   ```bash
   for i in $(seq 1 100); do
     kubectl exec deploy/ratings-v1 -c ratings -- \
       curl -s http://productpage:9080/productpage | grep -o 'reviews-v[0-9]*' | head -1
   done | sort | uniq -c
   ```

   ```
      91 reviews-v1
       9 reviews-v3
   ```

3. Promové a 50/50, luego a 100% `v3`, reaplicando el mismo objeto cada vez (el desvío es atómico — sin conexiones perdidas):

   ```bash
   kubectl patch virtualservice reviews --type=merge -p \
     '{"spec":{"http":[{"route":[{"destination":{"host":"reviews","subset":"v1"},"weight":50},{"destination":{"host":"reviews","subset":"v3"},"weight":50}]}]}}'
   ```

**Comprobá tu comprensión — 3**

- **3.1** El enrutamiento ponderado divide el tráfico por *porcentaje de peticiones*, no por cantidad de pods. ¿Por qué es fundamentalmente distinto de un `Service` común de Kubernetes que tiene por delante una mezcla de pods `v1` y `v3`, y qué le pasa a la proporción si `v3` se escala de 1 a 5 réplicas bajo cada modelo?
- **3.2** Los dos valores de `weight` son `90` y `10`. ¿Cuál es la restricción requerida sobre la suma de los weights dentro de una sola ruta, y qué hace Istio si suman menos de 100?
- **3.3** El enrutamiento basado en cabecera (Ejercicio 2) y el enrutamiento ponderado (este ejercicio) se expresan ambos como entradas `http[]`. ¿Pueden coexistir en un solo `VirtualService`, y si es así cómo harías un canary de *solo* el tráfico de jason?

---

## Ejercicio 4 — Inyección de fallos: delay y abort

La inyección de fallos prueba la resiliencia haciendo que el mesh *mismo* inyecte errores, sin ningún cambio en ningún servicio. Usá el servicio `ratings`.

1. Inyectá un **delay de 7 segundos** en el 100% de las llamadas a `ratings` de jason:

   ```yaml
   # vs-ratings-delay.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: ratings
   spec:
     hosts:
       - ratings
     http:
       - match:
           - headers:
               end-user:
                 exact: jason
         fault:
           delay:
             percentage:
               value: 100
             fixedDelay: 7s
         route:
           - destination:
               host: ratings
               subset: v1
       - route:
           - destination:
               host: ratings
               subset: v1
   ```

   ```bash
   kubectl apply -f vs-ratings-delay.yaml
   ```

2. Iniciá sesión como **jason** y cargá la página de producto. Como `reviews:v2` llama a `ratings` con un timeout **10s** codificado a mano pero reintenta una vez (~2×3.5s ≈ 7s de presupuesto), la página muestra un error mucho antes de que transcurran los 7s:

   ```
   Error fetching product reviews!
   Sorry, product reviews are currently unavailable for this book.
   ```

   Esto es un **bug latente que el mesh saca a la luz**: el delay (7s) está por debajo del propio timeout de 10s del servicio, y sin embargo la página igual falla — revelando una inconsistencia entre el cálculo de retries del cliente y el timeout declarado.

3. Reemplazá el delay por un **abort HTTP 500** en el 100% del tráfico de jason:

   ```yaml
       fault:
         abort:
           percentage:
             value: 100
           httpStatus: 500
   ```

   ```bash
   kubectl apply -f vs-ratings-abort.yaml
   ```

   Recargar como jason ahora falla **de inmediato** (`Ratings service is currently unavailable`) en vez de quedarse colgado.

**Comprobá tu comprensión — 4**

- **4.1** La inyección de fallos se acota con el mismo bloque `match` que el enrutamiento normal. ¿Qué garantiza que solo las peticiones *de jason* sufran el delay mientras que el tráfico de todos los demás usuarios hacia `ratings` queda intacto?
- **4.2** Contrastá la firma de fallo que percibe un usuario con `delay` versus `abort`. ¿Cuál es la herramienta correcta para probar una configuración de *timeout/retry*, y cuál prueba la lógica de *manejo de errores*?
- **4.3** El delay inyectado lo aplica el sidecar proxy, no la aplicación `ratings`. ¿En el lado del *cliente* o del *servidor* de la conexión retiene Envoy la petición, y por qué importa esa distinción para lo que muestran los propios logs de la app `ratings`?

---

## Ejercicio 5 — Timeouts y retries

Los timeouts y los retries se declaran en la ruta, sobrescribiendo el valor por defecto de Envoy (sin timeout de petición; retries automáticos apagados salvo que se configuren).

1. Agregá un timeout de medio segundo a la ruta `reviews` para que un upstream lento falle rápido:

   ```yaml
   # vs-reviews-timeout.yaml
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
         timeout: 0.5s
   ```

   ```bash
   kubectl apply -f vs-reviews-timeout.yaml
   ```

2. Mantené el delay de 2 segundos de `ratings` del Ejercicio 4. Como `reviews:v2` llama a `ratings`, el timeout de 0.5s de `reviews` ahora se dispara primero. La página de producto responde en ~0.5s con un error de reviews en vez de esperar a `ratings`:

   ```
   Error fetching product reviews!
   ```

3. Agregá una política de retry a `ratings` para que los fallos transitorios del upstream se reintenten antes de que el llamador los vea:

   ```yaml
   # vs-ratings-retry.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: ratings
   spec:
     hosts:
       - ratings
     http:
       - route:
           - destination:
               host: ratings
               subset: v1
         retries:
           attempts: 3
           perTryTimeout: 2s
           retryOn: gateway-error,connect-failure,refused-stream
   ```

   ```bash
   kubectl apply -f vs-ratings-retry.yaml
   ```

4. Confirmá que la política de retry se compiló en la configuración del proxy:

   ```bash
   istioctl proxy-config routes deploy/reviews-v2 --name 9080 -o json | \
     jq '.[0].virtualHosts[].routes[].route.retryPolicy | {numRetries, perTryTimeout, retryOn}'
   ```

   ```json
   {
     "numRetries": 3,
     "perTryTimeout": "2s",
     "retryOn": "gateway-error,connect-failure,refused-stream"
   }
   ```

**Comprobá tu comprensión — 5**

- **5.1** Con `attempts: 3` y `perTryTimeout: 2s`, ¿cuál es el tiempo *máximo* de reloj de pared que pueden consumir los retries de `ratings`, y cómo interactúa (y limita) un `timeout` general de ruta con ese presupuesto?
- **5.2** Se configura `retryOn: gateway-error,connect-failure,refused-stream`. ¿Por qué es deliberado *no* reintentar ante, por ejemplo, un HTTP `400`, y qué clase de fallos cubre `gateway-error`?
- **5.3** Un timeout de ruta de `0.5s` está por encima de un servicio que a su vez tiene `perTryTimeout: 2s` aguas abajo. Explicá cómo un timeout externo demasiado ajustado puede anular por completo una política de retry interna.

---

## Ejercicio 6 — Mirroring de peticiones (shadowing de tráfico)

El mirroring envía una *copia* del tráfico en vivo a una segunda versión y **descarta la respuesta** — una forma de probar `v2` contra carga de producción con cero impacto en el usuario. Desplegá `httpbin` en dos versiones para esto.

1. Desplegá `httpbin-v1` y `httpbin-v2` (ambos con la label `app: httpbin`, `version` distinto) y un `Service`, luego definí los subsets:

   ```yaml
   # dr-httpbin.yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     subsets:
       - name: v1
         labels:
           version: v1
       - name: v2
         labels:
           version: v2
   ```

2. Enviá todo el tráfico en vivo a `v1` y espejá el 100% hacia `v2`:

   ```yaml
   # vs-httpbin-mirror.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
   spec:
     hosts:
       - httpbin
     http:
       - route:
           - destination:
               host: httpbin
               subset: v1
             weight: 100
         mirror:
           host: httpbin
           subset: v2
         mirrorPercentage:
           value: 100.0
   ```

   > En la API `v1` esto también puede escribirse como una lista `mirrors:` de `HTTPMirrorPolicy` (cada uno con `destination` + `percentage`); `mirror`/`mirrorPercentage` siguen siendo válidos y se muestran acá por claridad.

   ```bash
   kubectl apply -f vs-httpbin-mirror.yaml
   ```

3. Enviá una petición desde un pod cliente y después mirá los logs de *ambas* versiones:

   ```bash
   kubectl exec deploy/sleep -c sleep -- curl -s http://httpbin:8000/headers >/dev/null

   kubectl logs deploy/httpbin-v1 -c httpbin | tail -1
   kubectl logs deploy/httpbin-v2 -c httpbin | tail -1
   ```

   ```
   # v1 (primary):
   GET /headers HTTP/1.1" 200 ... host: httpbin
   # v2 (mirrored):
   GET /headers HTTP/1.1" 200 ... host: httpbin-shadow
   ```

   Notá que la petición espejada llega a `v2` con la cabecera `Host`/`Authority` con el sufijo **`-shadow`** — el marcador del mesh de que esto es tráfico shadowed, del tipo fire-and-forget.

**Comprobá tu comprensión — 6**

- **6.1** La ruta primaria tiene `weight: 100` a `v1` y espeja hacia `v2`. ¿Qué recibe el *cliente* — la respuesta de `v1`, la de `v2`, o ambas — y qué pasa con la respuesta de `v2`?
- **6.2** ¿Por qué reescribe Istio la cabecera `Host` de la petición espejada a `httpbin-shadow`? ¿Contra qué peligro del mundo real protege eso cuando `v2` escribe en una base de datos?
- **6.3** Configuraste `mirrorPercentage.value: 100.0`. Da una razón de producción por la que espejarías solo, digamos, el 5% en vez del 100%.

---

## Ejercicio 7 — Enrutamiento de ingress a través de un `Gateway`

Todo hasta ahora enrutó *east-west* (interno al mesh). Para enrutar tráfico *north-south* desde fuera del cluster, un `VirtualService` debe estar **vinculado a un `Gateway`** y usar el host externo del gateway.

1. Creá el gateway de ingress y vinculá un `VirtualService` que exponga solo las rutas de la página de producto de Bookinfo:

   ```yaml
   # bookinfo-gateway.yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: bookinfo-gateway
   spec:
     selector:
       istio: ingressgateway          # matches the istio-ingressgateway pods
     servers:
       - port:
           number: 80
           name: http
           protocol: HTTP
         hosts:
           - "*"
   ---
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: bookinfo
   spec:
     hosts:
       - "*"
     gateways:
       - bookinfo-gateway             # binds this VS to the gateway
     http:
       - match:
           - uri:
               exact: /productpage
           - uri:
               prefix: /static
           - uri:
               exact: /login
           - uri:
               exact: /logout
           - uri:
               prefix: /api/v1/products
         route:
           - destination:
               host: productpage
               port:
                 number: 9080
   ```

   ```bash
   kubectl apply -f bookinfo-gateway.yaml
   istioctl analyze
   ```

2. Resolvé la dirección externa y hacé curl a través del gateway:

   ```bash
   export INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   export INGRESS_PORT=$(kubectl -n istio-system get svc istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')

   curl -sSI "http://$INGRESS_HOST:$INGRESS_PORT/productpage" | head -1
   ```

   ```
   HTTP/1.1 200 OK
   ```

3. Confirmá que una ruta *no expuesta* es rechazada en el gateway (solo se enrutan las URIs en la whitelist):

   ```bash
   curl -sSI "http://$INGRESS_HOST:$INGRESS_PORT/etc/passwd" | head -1
   ```

   ```
   HTTP/1.1 404 Not Found
   ```

**Comprobá tu comprensión — 7**

- **7.1** El `Gateway` y el `VirtualService` son dos objetos separados. ¿Qué define cada uno — y qué específicamente los vincula para que las reglas del VS efectivamente se apliquen al tráfico entrante del gateway?
- **7.2** En el `Gateway` aparece `spec.selector: istio: ingressgateway`. ¿Qué selecciona esa label, y qué pasaría si ningún pod la llevara?
- **7.3** Un `VirtualService` interno al mesh (por ejemplo `reviews`) **no** tiene campo `gateways:`. ¿Cuál es el valor por defecto implícito de `gateways`, y por qué eso evita que las reglas de enrutamiento internas y de ingress se filtren entre sí?

---

## Ejercicio 8 — Diagnosticar el enrutamiento con `istioctl`

Cuando el enrutamiento "no funciona", la respuesta casi siempre está en la configuración compilada de Envoy, no en el YAML. Practicá los comandos de diagnóstico principales.

1. Obtené un único resumen legible por humanos de todo lo que afecta al tráfico de un pod — la herramienta de triage más rápida:

   ```bash
   istioctl experimental describe pod "$(kubectl get pod -l app=reviews,version=v2 -o jsonpath='{.items[0].metadata.name}')"
   ```

   ```
   Pod: reviews-v2-b7dcd98fb-4kd6l
      Pod Revision: default
      Pod Ports: 9080 (reviews), 15090 (istio-proxy)
   --------------------
   Service: reviews
      Port: http 9080/HTTP targets pod port 9080
   DestinationRule: reviews for "reviews"
      Matching subsets: v2
         (Non-matching subsets v1,v3)
   VirtualService: reviews
      WeightedRoute to reviews.default.svc.cluster.local subset v2 weight 50
   ```

2. Listá las rutas que el sidecar de un llamador conoce para el puerto 9080, y volcá una a JSON para ver el orden de match y los clusters:

   ```bash
   istioctl proxy-config routes deploy/productpage-v1 --name 9080
   ```

   ```
   NAME     VHOST NAME                      DOMAINS     MATCH                  VIRTUAL SERVICE
   9080     reviews.default.svc.cluster...  reviews     /* (end-user=jason)    reviews.default
   9080     reviews.default.svc.cluster...  reviews     /*                     reviews.default
   ```

3. Confirmá que el sidecar del llamador realmente *recibió* la última configuración del control plane (la causa #1 de "mi regla no surte efecto"):

   ```bash
   istioctl proxy-status
   ```

   ```
   NAME                             CDS      LDS      EDS      RDS      ISTIOD                  VERSION
   productpage-v1.default           SYNCED   SYNCED   SYNCED   SYNCED   istiod-6b8...           1.24.1
   reviews-v2.default               SYNCED   SYNCED   SYNCED   SYNCED   istiod-6b8...           1.24.1
   ```

**Comprobá tu comprensión — 8**

- **8.1** `istioctl proxy-config routes` se corre contra `deploy/productpage-v1`, **no** contra `reviews`. ¿Por qué tenés que inspeccionar las rutas en el sidecar del *llamador* para depurar cómo el tráfico llega a `reviews`?
- **8.2** En `istioctl proxy-status`, una fila muestra `RDS STALE` en vez de `SYNCED`. ¿Qué te dice específicamente eso sobre tu `VirtualService` recién aplicado, y dónde está la falla — el YAML, `istiod`, o el data plane?
- **8.3** `istioctl experimental describe pod` reporta `Matching subsets: v2 (Non-matching subsets v1,v3)`. En una oración, ¿qué te permite verificar de un vistazo esa línea sobre tu `DestinationRule`?

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas de todos los ejercicios</summary>

**Ejercicio 0**

- **0.1** El segundo contenedor es el sidecar `istio-proxy` (Envoy), inyectado automáticamente porque el namespace lleva `istio-injection=enabled` (un mutating admission webhook reescribe el spec del pod en el momento de su creación). Un init container (`istio-init`, o el plugin CNI) instala reglas de `iptables` que redirigen el TCP entrante y saliente del pod a través de los puertos del sidecar (15006 entrante / 15001 saliente). La aplicación no se entera; sigue haciendo bind y dial normalmente, pero cada paquete transita por Envoy.
- **0.2** El tráfico llega a las tres versiones porque el `Service reviews` común de Kubernetes selecciona todos los pods con la label `app: reviews` sin importar la `version`, y su lista de `Endpoints` contiene v1/v2/v3. Sin ninguna regla de enrutamiento de Istio, el sidecar simplemente balancea la carga entre todos los endpoints sanos de ese servicio (round-robin / least-request por defecto). El **sidecar Envoy del llamador** realiza el balanceo de carga del lado del cliente — no kube-proxy.

**Ejercicio 1**

- **1.1** El `DestinationRule` *nombra y define* los subsets — mapea el nombre de un subset (`v1`) a un selector de labels (`version: v1`) aplicado después de resolver los endpoints del servicio. El `VirtualService` *selecciona* un subset como destino de ruta (`destination.host + subset`). Un `VirtualService` no puede inventar un subset; el subset ya debe existir en un `DestinationRule` para el mismo host.
- **1.2** Istio expande el nombre corto `reviews` al FQDN del propio namespace del llamador: `reviews.default.svc.cluster.local`. Un nombre corto pelado se resuelve relativo al namespace del *cliente*, así que la misma regla aplicada en otro namespace apunta silenciosamente a un servicio distinto. En configuraciones compartidas/multi-namespace, usá siempre el FQDN.
- **1.3** En runtime el cliente obtiene **HTTP 503** con `NR` (No Route / sin upstream sano) porque el cluster referenciado `outbound|9080|v2|...` no tiene endpoints definidos. Los equivalentes de `scripts/check` / `istioctl analyze` lo detectan estáticamente como **IST0101** ("Referenced host+subset in destinationrule not found") antes de que llegue a un usuario.

**Ejercicio 2**

- **2.1** jason sería enrutado a `v1`, nunca a `v2`. Istio evalúa `http[]` con primer-match-gana de arriba hacia abajo; una regla por defecto sin match arriba matchea *todo*, así que corta el circuito y la regla de cabecera de abajo queda como código muerto. Las reglas específicas deben preceder a la catch-all.
- **2.2** La entrada sin match es la ruta **por defecto / fallthrough**: no tiene bloque `match` así que matchea cualquier petición que haya caído a través de las reglas condicionales anteriores. Si se la elimina, una petición que no matchee ninguna regla no tiene ruta y recibe **HTTP 404** (`NR`) — el `VirtualService` "captura" el host pero no le ofrece ningún destino.
- **2.3** `outbound` = dirección del tráfico (lado del cliente, saliendo del pod) · `9080` = el puerto del servicio destino · `v2` = el subset del DestinationRule · `reviews.default.svc.cluster.local` = el FQDN del servicio destino. Esta cuádrupla es el nombre del cluster de Envoy.

**Ejercicio 3**

- **3.1** El ponderado de Istio es **proporcional a las peticiones en L7**: 90/10 significa que el 90% de las *peticiones* van a `v1` sin importar la cantidad de réplicas. Un `Service` común balancea la carga entre *endpoints*, así que la división sigue la proporción de pods. Bajo Istio, escalar `v3` de 1→5 réplicas mantiene la cuota del 10% (el tráfico se reparte entonces entre los 5 pods de v3). Bajo un `Service` común, escalar `v3` a 5 pods (contra 1 pod v1) desvía ~83% del tráfico a v3 — la proporción es un accidente de la cantidad de réplicas, que es exactamente por qué existe el enrutamiento ponderado de VirtualService.
- **3.2** Los weights dentro de una ruta **deben sumar 100**. Si suman menos de 100 la configuración es rechazada/marcada (`istioctl analyze` advierte), y una ruta de destino único puede omitir `weight` por completo (implícitamente 100). No podés confiar en que "el resto va a algún lado" — cada porcentaje debe estar contabilizado.
- **3.3** Sí. Poné un bloque `match` (por ejemplo `end-user: jason`) cuya `route` lleve la división ponderada (digamos v1:90/v3:10) **primero**, y una ruta por defecto sin match (todo → v1) segundo. Solo el tráfico de jason recibe el canary; todos los demás quedan en la versión estable. Las reglas de match y las rutas ponderadas se componen porque una sola entrada `http[]` puede contener a la vez un `match` y una `route` ponderada de múltiples destinos.

**Ejercicio 4**

- **4.1** El bloque `fault` vive *dentro* de la misma entrada `http[]` que su `match: end-user=jason`. La inyección de fallos se aplica solo a las peticiones que satisfacen ese match; la segunda entrada de ruta, sin match, no lleva `fault`, así que todos los demás usuarios pasan intactos. Alcance del fault = alcance del match.
- **4.2** `delay` hace que la petición *se cuelgue* y luego (usualmente) tenga éxito tarde — el usuario percibe lentitud/timeouts; es la herramienta correcta para probar el comportamiento de **timeout y retry** y los presupuestos de latencia en cascada. `abort` devuelve un código de error inmediato (por ejemplo 500) — el usuario percibe un fallo duro; es la herramienta correcta para probar la lógica de **manejo de errores / circuit-breaking / fallback**. `delay` prueba "demasiado lento"; `abort` prueba "se rompió".
- **4.3** El delay lo aplica el **sidecar del lado del cliente** (el Envoy del llamador, por ejemplo el proxy de `reviews-v2` retiene la petición saliente antes de despacharla). Importa porque la aplicación `ratings` misma nunca ve la latencia agregada — sus propios logs de acceso muestran respuestas normales y rápidas — así que un desarrollador que busque la lentitud en los logs de `ratings` no encuentra nada; la latencia existe solo en el mesh, entre los servicios.

**Ejercicio 5**

- **5.1** En el peor caso ≈ `attempts × perTryTimeout` = `3 × 2s = 6s` de presupuesto de retry. Sin embargo, un `timeout` general de ruta es un tope duro sobre la petición *entera* incluyendo todos los retries: si `timeout: 5s`, los retries se detienen en el momento en que transcurren 5s aunque el intento 3 no haya corrido. El timeout de ruta siempre gana sobre el presupuesto de retry.
- **5.2** Un `400` es un error del *cliente* — la petición está malformada; reintentarla envía la misma petición mala y va a fallar idénticamente mientras agrega carga, así que no debe reintentarse. `gateway-error` cubre 502/503/504 (upstream inalcanzable/sobrecargado/con timeout) — condiciones genuinamente transitorias donde un nuevo intento a un endpoint distinto puede tener éxito. Reintentá solo fallos idempotentes y transitorios del lado del servidor.
- **5.3** Si el `timeout` de ruta externo (0.5s) es más corto que incluso un solo `perTryTimeout` (2s), la petición es abortada por el timeout externo antes de que el primer intento pueda completarse, así que los intentos 2 y 3 nunca corren — la política de retry queda efectivamente muerta. El timeout general debe exceder `attempts × perTryTimeout` (más jitter) para que los retries tengan margen para funcionar.

**Ejercicio 6**

- **6.1** El cliente recibe **solo la respuesta de `v1`**. El mirror a `v2` es *fire-and-forget*: Envoy envía una copia completa de la petición a `v2` pero **descarta por completo la respuesta de `v2`** (el éxito, el error, o la latencia en `v2` nunca llegan al cliente). El mirroring es solo de observación.
- **6.2** El sufijo `-shadow` en la cabecera `Host`/`Authority` marca la petición como shadowed para que el código aguas abajo pueda detectarla y *no ejecutar efectos secundarios (no-op)*. El peligro contra el que protege: si `v2` comparte una base de datos con `v1` y procesa ciegamente la petición espejada, realizaría **escrituras dobles** (pedidos duplicados, pagos cobrados dos veces) a partir de una única acción real del usuario. El tráfico shadow debe tratarse como de solo lectura.
- **6.3** El mirroring duplica la carga sobre tus dependencias (DB, servicios aguas abajo, el deployment `v2`). Al 100% probás en carga completa a `v2` pero también duplicás la presión de lectura en la DB y te arriesgás a saturar un canary sub-aprovisionado; un porcentaje pequeño (5%) da una muestra representativa de las formas reales de tráfico mientras mantiene acotada la carga extra — y el radio de impacto de cualquier bug de `v2`.

**Ejercicio 7**

- **7.1** El `Gateway` define el *listener de borde* — qué puertos/protocolos/hosts acepta el proxy de ingress (L4–L6: puerto 80, HTTP, host `*`). El `VirtualService` define las *reglas de enrutamiento* — qué rutas mapean a qué servicio interno. Se vinculan por el campo `spec.gateways: [bookinfo-gateway]` del VS (y los `hosts` coincidentes); sin esa vinculación el VS aplica solo al tráfico interno del mesh y el gateway acepta conexiones pero no tiene a dónde enrutarlas.
- **7.2** `selector: istio: ingressgateway` selecciona los **pods** de ingress-gateway en ejecución que llevan esa label (el deployment `istio-ingressgateway` en `istio-system`). La configuración del listener del Gateway se empuja a esos pods. Si ningún pod lleva la label, el recurso Gateway es válido pero *nada* lo implementa — el listener nunca se abre y las peticiones externas son rechazadas/no enrutadas.
- **7.3** El valor por defecto implícito es `gateways: ["mesh"]` — la palabra reservada que significa "todos los sidecars del mesh". Así que un `VirtualService` interno aplica solo al tráfico sidecar-a-sidecar. Como las reglas ligadas a ingress deben listar *explícitamente* un gateway con nombre, y las reglas internas usan `mesh` por defecto, los dos conjuntos no se solapan — el enrutamiento de ingress y el east-west quedan aislados salvo que deliberadamente listes ambos (`["mesh", "bookinfo-gateway"]`).

**Ejercicio 8**

- **8.1** En Istio, las decisiones de enrutamiento las toma el **sidecar del lado del cliente del llamador** en el momento en que despacha una petición saliente. Los sidecars de `reviews` solo ven tráfico *entrante* ya destinado a ellos; no deciden subset/weight. Así que para depurar cómo `productpage` llega a `reviews`, inspeccionás las rutas compiladas en el Envoy de `productpage` — ahí es donde el `VirtualService`/`DestinationRule` de `reviews` realmente surte efecto.
- **8.2** `RDS STALE` significa que la configuración de descubrimiento de rutas (**R**oute **D**iscovery) para ese proxy fue computada/empujada por `istiod` pero el Envoy del data-plane todavía no ACKeó su aplicación (o los dos difieren). Te dice que tu cambio de `VirtualService` *sí* llegó a `istiod` y se está distribuyendo, pero el proxy todavía no convergió — la falla está en la propagación/convergencia (transitoria, o un proxy bajo presión), no en el YAML (que aparecería como un error de analyze) ni en una falla total de `istiod` (que mostraría todas las filas stale). Esperá/reintentá; si persiste, inspeccioná el proxy de ese pod.
- **8.3** Confirma de un vistazo que los selectores de labels de los subsets de tu `DestinationRule` matchean correctamente a este pod — `v2` matcheó, así que las labels del subset coinciden con la label `version: v2` del pod (un desajuste mostraría el subset como no-matcheado o faltante, explicando un `503 NR`).

</details>

---

### Fuentes

- Istio — Request Routing task: https://istio.io/latest/docs/tasks/traffic-management/request-routing/
- Istio — Traffic Shifting task: https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Istio — Fault Injection task: https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
- Istio — Setting Request Timeouts: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio — Mirroring task: https://istio.io/latest/docs/tasks/traffic-management/mirroring/
- Istio — Ingress Gateways task: https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
- Istio — `VirtualService` reference: https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — `DestinationRule` reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — `Gateway` reference: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio — Debugging Envoy and Istiod / `istioctl proxy-config`, `proxy-status`, `describe`: https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — Bookinfo sample application: https://istio.io/latest/docs/examples/bookinfo/
- CNCF ICA curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf