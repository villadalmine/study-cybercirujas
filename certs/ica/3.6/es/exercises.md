# Ejercicios — Tema 3.6: Uso de Funciones de Resiliencia

> Entorno asumido para cada ejercicio de abajo: un cluster de Kubernetes con Istio habilitado, con inyección automática de sidecar en el namespace de trabajo, `istioctl` y `kubectl` en tu PATH, e Istio 1.20+ (todos los manifiestos usan la API `networking.istio.io/v1`, que es GA y retrocompatible con `v1beta1`). Ejecutá todo desde un único namespace — los ejemplos usan `default`. La resiliencia en Istio la aplica el sidecar Envoy del lado del cliente, así que cada perilla que ajustás acá vive en el proxy del emisor, no en el del servidor.

---

## Ejercicio 0 — Armá el banco de pruebas

Vas a generar tráfico con **Fortio** (un generador de carga que reporta histogramas por código) contra **httpbin** (un servidor cuyos endpoints `/delay`, `/status` y `/get` te permiten fabricar latencia y errores a demanda).

**Pasos**

1. Confirmá que la inyección está activada para el namespace que vas a usar:

   ```bash
   kubectl label namespace default istio-injection=enabled --overwrite
   kubectl get namespace default --show-labels
   ```

2. Desplegá el servidor y el cliente:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/sample-client/fortio-deploy.yaml
   ```

3. Verificá que ambos pods corran **2/2** (contenedor de la app + `istio-proxy`):

   ```bash
   kubectl get pods -l app=httpbin
   kubectl get pods -l app=fortio
   ```

   Esperado:

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7d6bf9b4c5-abcde   2/2     Running   0          25s
   fortio-deploy-9c8b7-xyz    2/2     Running   0          20s
   ```

4. Capturá el nombre del pod de Fortio en una variable de shell y dispará una petición de sanidad:

   ```bash
   export FORTIO_POD=$(kubectl get pods -l app=fortio -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/get
   ```

   Esperado: un HTTP `200` con un cuerpo JSON que hace eco de las cabeceras de la petición — fijate en las cabeceras `X-Envoy-*`, que prueban que la petición atravesó el sidecar.

**Verificá tu comprensión**

- **Q0.1** — ¿Por qué el comando `fortio` debe ejecutarse dentro del contenedor `-c fortio` y no del contenedor `-c istio-proxy`?
- **Q0.2** — Las políticas de resiliencia que estás por configurar las aplica el Envoy de *cuál* pod — el de httpbin o el de fortio? ¿Por qué importa esa distinción para cómo vas a leer las métricas?

---

## Ejercicio 1 — Timeouts de petición

Un timeout acota cuánto esperará el Envoy del cliente por una respuesta upstream completa antes de rendirse con `504 Gateway Timeout`. Sin uno, un backend lento puede inmovilizar recursos del cliente indefinidamente.

**Pasos**

1. Tomá una línea base de la latencia de un endpoint deliberadamente lento. `httpbin/delay/N` espera `N` segundos antes de responder:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/delay/5
   ```

   Esperado: un `200` después de ~5 s. Todavía no hay ningún timeout en vigor.

2. Enrutá `httpbin` a través de un `VirtualService` que limite la espera a 3 segundos:

   ```yaml
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
         timeout: 3s
   ```

   ```bash
   kubectl apply -f httpbin-timeout.yaml
   ```

3. Golpeá de nuevo el endpoint de 5 segundos y cronometralo:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/delay/5
   ```

   Esperado: la llamada retorna en ~3 s con:

   ```
   HTTP/1.1 504 Gateway Timeout
   upstream request timeout
   ```

4. Confirmá que el endpoint que entra *dentro* del presupuesto sigue teniendo éxito:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/delay/1
   ```

   Esperado: `200` después de ~1 s.

5. Leé el log de acceso del sidecar del cliente para ver el veredicto del propio Envoy:

   ```bash
   kubectl logs "$FORTIO_POD" -c istio-proxy --tail=5 | grep delay
   ```

   Esperado: una línea de log cuyo campo de response-flags contiene **`UT`** (Upstream request Timeout) para la llamada a `/delay/5`.

**Verificá tu comprensión**

- **Q1.1** — El `timeout` se configuró en el `VirtualService` (un objeto de enrutamiento), pero lo aplica el Envoy de fortio. Reconciliá esos dos hechos.
- **Q1.2** — ¿Cuál es el response flag de Envoy para una petición matada por el timeout de ruta, y qué estado HTTP recibe el cliente?
- **Q1.3** — Más adelante agregás una política de retries con `perTryTimeout: 2s` manteniendo el `timeout: 3s` global. Si cada intento es lento, ¿aproximadamente cuántos intentos pueden caber físicamente antes de que dispare el timeout global, y qué presupuesto gana?

---

## Ejercicio 2 — Retries

Los retries permiten que el Envoy del cliente reemita de forma transparente una petición fallida hacia (potencialmente) otro endpoint sano. Enmascaran fallos *transitorios* — una única réplica inestable, una conexión caída — pero no pueden arreglar una petición que está determinísticamente rota.

**Pasos**

1. Inspeccioná la política de retries que Istio aplica **por defecto**, incluso sin configuración. Volcá la configuración de ruta efectiva desde el proxy de fortio:

   ```bash
   istioctl proxy-config route "$FORTIO_POD" --name 8000 -o json \
     | grep -A6 retryPolicy
   ```

   Esperado (defaults): `numRetries: 2`, `retryOn: "connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes"`.

2. Reemplazá el `VirtualService` con una política de retries explícita sobre un endpoint que siempre falla. `httpbin/status/503` retorna `503` cada vez:

   ```yaml
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
         retries:
           attempts: 3
           perTryTimeout: 2s
           retryOn: 5xx,reset,connect-failure
   ```

   ```bash
   kubectl apply -f httpbin-retries.yaml
   ```

3. Reseteá los contadores del sidecar para medir solo esta corrida, luego enviá **una** petición lógica:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request POST reset_counters
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/status/503
   ```

   Esperado: el cliente sigue recibiendo `503` — el endpoint está determinísticamente roto, así que los retries no pueden salvarlo.

4. Comprobá que los retries efectivamente ocurrieron leyendo las estadísticas de cluster del Envoy del cliente:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*upstream_rq_retry'
   ```

   Esperado (una petición lógica → el intento original más 3 retries):

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_retry: 3
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_retry_limit_exceeded: 1
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_retry_success: 0
   ```

5. Contrastá con un código *no reintentable*. `httpbin/status/400` retorna un error de cliente, que `retryOn: 5xx` no matchea:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request POST reset_counters
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/status/400
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*upstream_rq_retry:'
   ```

   Esperado: `upstream_rq_retry: 0` — un `400` no se reintenta.

**Verificá tu comprensión**

- **Q2.1** — Con `attempts: 3`, ¿cuántas peticiones totales pueden golpear el upstream por una llamada del cliente, y por qué `/status/503` igual retornó un error al que llama?
- **Q2.2** — `retryOn: 5xx` matcheó `503` pero no `400`. Enunciá el principio general sobre qué fallos vale la pena reintentar y cuáles no.
- **Q2.3** — Un colega quiere estar "seguro" y pone `attempts: 10` en un endpoint de escritura (`POST`) que está fallando bajo carga. Nombrá dos peligros distintos que esto crea.
- **Q2.4** — Los retries y el timeout del Ejercicio 1 interactúan. Si `perTryTimeout: 2s` y `attempts: 3` pero el `timeout` de ruta es `3s`, ¿por qué podrías observar solo *un* intento en lugar de tres?

---

## Ejercicio 3 — Circuit breaking (límites del pool de conexiones)

Circuit breaking acá significa descargar carga: cuando las conexiones concurrentes o las peticiones pendientes hacia un servicio exceden un techo, el Envoy del cliente retorna inmediatamente `503` en lugar de encolar, protegiendo a un backend que está sufriendo de ser sobrecargado. Esto se configura en el **`DestinationRule`**, no en el VirtualService.

**Pasos**

1. Quitá el VirtualService de retries para que no enmascare los errores de desborde, luego aplicá un circuit breaker agresivo:

   ```bash
   kubectl delete virtualservice httpbin --ignore-not-found
   ```

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
   kubectl apply -f httpbin-circuit-breaker.yaml
   ```

2. Con **una** conexión por vez (`-c 1`) el breaker no debería dispararse:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 1 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
   ```

   Esperado: `Code 200 : 20 (100.0 %)`.

3. Ahora empujá **dos** conexiones concurrentes (`-c 2`), excediendo `maxConnections: 1` + `http1MaxPendingRequests: 1`:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 2 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
   ```

   Esperado: una mezcla — algunas peticiones dispararon el breaker:

   ```
   Code 200 : 15 (75.0 %)
   Code 503 : 5 (25.0 %)
   ```

4. Cuantificá cuántas peticiones descargó el breaker leyendo el contador de desborde:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*pending'
   ```

   Esperado:

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_active: 0
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_overflow: 5
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_total: 39
   ```

   El conteo de `upstream_rq_pending_overflow` coincide con los `503` que reportó Fortio.

5. (Opcional) Subí la presión a `-c 3` y observá cómo trepa la proporción de `503`, luego confirmá que cada petición descargada lleva el response flag `UO` (Upstream Overflow / circuit-breaking) en el log de acceso de fortio:

   ```bash
   kubectl logs "$FORTIO_POD" -c istio-proxy --tail=20 | grep -o 'response_flags[":= ]*[A-Z]*' | sort | uniq -c
   ```

**Verificá tu comprensión**

- **Q3.1** — ¿En qué recurso (`VirtualService` o `DestinationRule`) viven los circuit breakers del pool de conexiones, y por qué es ese el hogar semánticamente correcto?
- **Q3.2** — Los límites son `maxConnections: 1` y `http1MaxPendingRequests: 1`. Explicá, en términos de esos dos números, por qué `-c 1` dio 100% de éxito pero `-c 2` descartó aproximadamente un cuarto de las peticiones.
- **Q3.3** — `upstream_rq_pending_overflow` fue `5` y fortio reportó `5` × `503`. ¿Qué **response flag** de Envoy corresponde a esto, y en qué difiere del flag `UT` que viste en el Ejercicio 1?
- **Q3.4** — Estos límites se aplican *por instancia de Envoy del cliente*. Si escalás fortio a 3 réplicas, ¿la concurrencia *efectiva* que el backend httpbin puede ver se mantiene en 1? Explicá.

---

## Ejercicio 4 — Outlier detection (health checking pasivo → expulsión)

Outlier detection es el health check pasivo de Envoy: observa las respuestas por endpoint y temporalmente **expulsa** un endpoint del pool de balanceo de carga después de que emite errores consecutivos, y luego lo sondea de vuelta más tarde. Combinado con un Deployment multi-réplica, enruta alrededor de un único pod enfermo sin ninguna sonda de health-check externa.

**Pasos**

1. Escalá httpbin a 3 réplicas para que haya un pool del que expulsar:

   ```bash
   kubectl scale deployment httpbin --replicas=3
   kubectl rollout status deployment/httpbin
   ```

2. Extendé el `DestinationRule` con un bloque `outlierDetection` (mantené o descartá el pool de conexiones — mostrado acá de forma independiente para mayor claridad):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 5s
         baseEjectionTime: 30s
         maxEjectionPercent: 100
         minHealthPercent: 0
   ```

   ```bash
   kubectl apply -f httpbin-outlier.yaml
   ```

3. Inspeccioná los endpoints y su salud tal como los ve actualmente el Envoy de fortio:

   ```bash
   istioctl proxy-config endpoints "$FORTIO_POD" \
     --cluster "outbound|8000||httpbin.default.svc.cluster.local"
   ```

   Esperado: tres endpoints, todos `HEALTHY`.

4. Hacé que una réplica específica falle en cada petición. Elegí un pod, entrá a su contenedor **app**, y (httpbin no tiene interruptor de apagado, así que simulá deteniendo el proceso del servidor) crasheálo para que sus conexiones se reseteen:

   ```bash
   VICTIM=$(kubectl get pods -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$VICTIM" -c httpbin -- pkill gunicorn || true
   ```

   > Esto hace que el endpoint víctima rechace/resetee conexiones, lo que outlier detection cuenta en su contra (los fallos de conexión se tratan como `5xx` a menos que se configure `splitExternalLocalOriginErrors`).

5. Generá tráfico sostenido para que el detector acumule errores consecutivos dentro de un `interval`:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 3 -qps 20 -t 30s -loglevel Warning http://httpbin:8000/get
   ```

6. Mientras eso corre (o justo después), reinspeccioná la salud de los endpoints y los contadores de expulsión:

   ```bash
   istioctl proxy-config endpoints "$FORTIO_POD" \
     --cluster "outbound|8000||httpbin.default.svc.cluster.local"

   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*outlier'
   ```

   Esperado: el endpoint víctima ahora muestra `UNHEALTHY`, y las estadísticas muestran una expulsión distinta de cero, p. ej.:

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_active: 1
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_enforced_consecutive_5xx: 1
   ```

   La tasa de éxito de Fortio debería mantenerse alta (~cerca del 100% después de los primeros errores) porque el tráfico ahora se dirige a las dos réplicas sanas.

7. Esperá más allá de `baseEjectionTime` (30 s) después de que el pod se recupere (`kubectl rollout restart deployment/httpbin` para traer la víctima de vuelta) y confirmá que el endpoint vuelve a `HEALTHY` y que `ejections_active` cae a `0`.

**Verificá tu comprensión**

- **Q4.1** — Distinguí outlier detection de una **readinessProbe** de Kubernetes. Ambas quitan backends malos — ¿qué atrapa el check pasivo de Envoy que la sonda del kubelet puede pasar por alto, y viceversa?
- **Q4.2** — `consecutive5xxErrors: 3`, `interval: 5s`, `baseEjectionTime: 30s`. En lenguaje simple, describí la secuencia exacta de eventos que lleva a que un endpoint sea expulsado y luego readmitido.
- **Q4.3** — ¿Por qué importa `maxEjectionPercent: 100` acá, y qué comportamiento peligroso (panic routing) puede ocurrir si outlier detection se deja en su default conservador mientras una mayoría de los endpoints están realmente insalubres?
- **Q4.4** — Outlier detection es además el *prerrequisito* de una de las otras funciones de resiliencia de este tema. ¿Cuál, y por qué esa función no puede funcionar sin ella?

---

## Ejercicio 5 — Failover (balanceo de carga con conciencia de localidad)

El failover por localidad mantiene el tráfico en la propia zona/región de quien llama mientras todo va bien, y lo desplaza a una localidad de respaldo solo cuando los endpoints locales se vuelven insalubres. Se construye directamente sobre outlier detection: Envoy agrupa los endpoints en **niveles de prioridad** por localidad, y solo degrada a una localidad de menor prioridad cuando la superior es expulsada.

> Un failover cross-zone *en vivo* necesita un cluster genuinamente multi-zona (nodos con etiquetas `topology.kubernetes.io/region`/`zone` distintas). Este ejercicio configura la política y lee la topología de prioridad resultante desde Envoy, que es lo que te van a pedir razonar en el examen incluso en un lab de una sola zona.

**Pasos**

1. Configurá el failover en el `DestinationRule`. El failover **requiere** que outlier detection esté presente (mantenido del Ejercicio 4):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       loadBalancer:
         localityLbSetting:
           enabled: true
           failover:
             - from: us-east
               to: us-west
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 5s
         baseEjectionTime: 30s
         maxEjectionPercent: 100
   ```

   ```bash
   kubectl apply -f httpbin-failover.yaml
   ```

2. Inspeccioná cómo Envoy agrupó los endpoints en **prioridades** por localidad:

   ```bash
   istioctl proxy-config endpoints "$FORTIO_POD" \
     --cluster "outbound|8000||httpbin.default.svc.cluster.local" -o json \
     | grep -E '"priority"|region|zone|"address"'
   ```

   Esperado en un cluster multi-zona: los endpoints en la propia región de quien llama llevan `priority: 0`; el objetivo de failover `us-west` aparece en `priority: 1`. (En un lab de una sola zona cada endpoint es `priority 0` — anotá eso y seguí.)

3. Razoná sobre el disparador del failover: con todos los endpoints locales (`priority 0`) sanos, el `100%` del tráfico se queda local. Solo cuando outlier detection expulsa suficientes de `priority 0`, Envoy promueve `priority 1`. Verificá los pesos de balanceo de carga conceptualmente chequeando las prioridades del `load_assignment` del cluster:

   ```bash
   istioctl proxy-config cluster "$FORTIO_POD" \
     --fqdn httpbin.default.svc.cluster.local -o json \
     | grep -A3 localityLbSetting
   ```

4. (Solo multi-zona) Expulsá toda la localidad local matando todas las réplicas locales de httpbin y confirmá que el tráfico se desplaza a `us-west` mientras la tasa de éxito de Fortio se mantiene alta; luego restaurá y confirmá que el tráfico vuelve de golpe a local.

**Verificá tu comprensión**

- **Q5.1** — El failover comparte una dependencia dura con el Ejercicio 4. ¿Cuál es, y qué pasaría (funcionalmente) si configuraras `localityLbSetting.failover` pero *omitieras* `outlierDetection`?
- **Q5.2** — Distinguí `localityLbSetting.failover` de `localityLbSetting.distribute`. ¿Cuándo elegirías cada uno?
- **Q5.3** — Bajo condiciones normales (todo sano), ¿qué fracción del tráfico envía una política de `failover` a la localidad de respaldo, y por qué es ese el default correcto en cuanto a costo y latencia?
- **Q5.4** — La localidad se deriva de las etiquetas de nodo. Nombrá las dos etiquetas `topology.kubernetes.io/*` que Istio lee, y explicá cómo se trata para el enrutamiento por localidad a un pod programado en un nodo sin etiquetas.

---

## Ejercicio 6 — Componé el stack completo de resiliencia (capstone)

Los servicios reales apilan estas funciones. Acá combinás timeout + retries (VirtualService) con circuit breaking + outlier detection (DestinationRule) sobre un mismo host y razonás sobre su orden de interacción.

**Pasos**

1. Aplicá ambos objetos juntos:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
   spec:
     hosts: [httpbin]
     http:
       - route:
           - destination:
               host: httpbin
         timeout: 5s
         retries:
           attempts: 3
           perTryTimeout: 1s
           retryOn: 5xx,reset,connect-failure,retriable-status-codes
   ---
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       connectionPool:
         tcp: { maxConnections: 10 }
         http: { http1MaxPendingRequests: 10, maxRequestsPerConnection: 10 }
       outlierDetection:
         consecutive5xxErrors: 5
         interval: 10s
         baseEjectionTime: 30s
         maxEjectionPercent: 50
   ```

   ```bash
   kubectl apply -f httpbin-resilience-stack.yaml
   ```

2. Verificá la configuración efectiva fusionada que Envoy realmente corre:

   ```bash
   istioctl proxy-config route "$FORTIO_POD" --name 8000 -o yaml | grep -A8 retryPolicy
   istioctl proxy-config cluster "$FORTIO_POD" --fqdn httpbin.default.svc.cluster.local -o yaml \
     | grep -A15 -E 'outlierDetection|circuitBreakers'
   ```

3. Generá carga mixta y observá cómo retries, desborde y expulsiones se mueven juntos:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request POST reset_counters
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 15 -qps 0 -t 20s -loglevel Warning http://httpbin:8000/get
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep -E 'httpbin.*(pending_overflow|rq_retry:|outlier_detection.ejections_active)'
   ```

**Verificá tu comprensión**

- **Q6.1** — Ordená las funciones por *cuándo* actúan sobre una única petición condenada: límite del pool de conexiones, per-try timeout, retry, timeout de ruta global, expulsión por outlier. ¿Cuáles de estas pueden ocurrir *antes de que la petición siquiera se envíe al cable*?
- **Q6.2** — ¿Por qué apilar un valor grande de `attempts` sobre un circuit breaker agresivo es potencialmente contraproducente durante una sobrecarga?
- **Q6.3** — `maxEjectionPercent: 50` con `consecutive5xxErrors: 5`: dá un escenario donde esta combinación *mantiene un servicio parcialmente degradado sirviendo* en lugar de agujerearlo (blackholing).

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**Q0.1** — `fortio` es la aplicación cliente; vive en el contenedor de la app. El contenedor `istio-proxy` corre Envoy, cuyo trabajo es *interceptar* el tráfico de fortio de forma transparente, no originar peticiones de aplicación. Ejecutar `fortio` en el contenedor del proxy pasaría por alto la interceptación por iptables del sidecar (Envoy hablaría consigo mismo) y medirías la ruta equivocada.

**Q0.2** — Las políticas de resiliencia de Istio (timeouts, retries, circuit breaking, outlier detection, failover) las aplica el Envoy del **lado del cliente** — acá, el sidecar de **fortio**. Por eso cada métrica en estos ejercicios se lee desde `$FORTIO_POD -c istio-proxy`, no desde httpbin. El `DestinationRule`/`VirtualService` están indexados por el *host de destino*, pero programan el proxy de *quien llama* para las llamadas a ese host.

### Ejercicio 1

**Q1.1** — El `VirtualService` es una intención declarativa de enrutamiento para el host `httpbin`. El plano de control (istiod) compila esa intención en configuración de ruta de Envoy y la empuja a cada sidecar que pudiera llamar a `httpbin` — incluido el de fortio. El timeout, por lo tanto, se *declara* en la ruta pero lo *aplica* el Envoy que llama en cada petición. El lado del servidor no tiene ninguna parte en esto.

**Q1.2** — Response flag **`UT`** (Upstream request Timeout); el cliente recibe **`504 Gateway Timeout`** con el cuerpo `upstream request timeout`.

**Q1.3** — Con `perTryTimeout: 2s` y un `timeout` global de `3s`, solo el primer intento (2 s) entra completo; un segundo intento arrancaría en t≈2 s y sería cortado por el presupuesto global de 3 s después de ~1 s. Así que aproximadamente **un intento completo más un segundo truncado**. El **`timeout` de ruta global siempre gana** — es el techo duro de reloj de pared a través de *todos* los intentos; `perTryTimeout` solo acota cada intento individual.

### Ejercicio 2

**Q2.1** — `attempts: 3` significa hasta **1 original + 3 retries = 4 peticiones upstream** por una llamada del cliente. Igual falló porque `/status/503` está *determinísticamente* roto — cada réplica retorna `503` — así que reintentar solo vuelve a encontrar el mismo error. Los retries enmascaran fallos *transitorios*, no *sistemáticos*.

**Q2.2** — Reintentá solo fallos que sean **idempotentes para reintentar y plausiblemente transitorios**: reseteos de conexión, `503`/`unavailable`, `connect-failure`, streams rechazados. **No** reintentes errores de cliente determinísticos (`4xx` como `400`, `404`, `401`) — la petición en sí está malformada o no autorizada, así que un retry no puede cambiar el resultado y solo malgasta capacidad.

**Q2.3** — (1) **Amplificación de retries / tormentas de retries**: 10× el tráfico martillando un backend ya sobrecargado empeora la caída. (2) **Efectos secundarios no idempotentes**: reintentar un `POST` que tuvo éxito parcial (p. ej., la escritura se aplicó pero la respuesta se perdió) puede duplicar la escritura — cargos dobles, registros duplicados. Solo reintentá escrituras cuando el endpoint sea idempotente o esté protegido por una clave de idempotencia.

**Q2.4** — El `timeout` de ruta global de `3s` es el techo duro a través de todos los intentos. Con `perTryTimeout: 2s`, el primer intento puede consumir hasta 2 s; después de un backoff de retry el presupuesto restante puede quedar por debajo de 1 s, así que los intentos subsiguientes se cortan o nunca arrancan. Si el primerísimo intento se come los 3 s enteros, observás un único intento y luego un `504`. Presupuestá el timeout global ≥ `attempts × perTryTimeout` (más el backoff) si realmente querés que todos los retries tengan una oportunidad.

### Ejercicio 3

**Q3.1** — En el **`DestinationRule`** (`trafficPolicy.connectionPool`). El circuit breaking es una propiedad de *cómo el cliente se conecta a un workload de destino* — techos de concurrencia de conexiones y peticiones — que es exactamente lo que gobierna el `DestinationRule`. El `VirtualService` gobierna *enrutamiento/matching* (adónde va una petición), una preocupación distinta.

**Q3.2** — `maxConnections: 1` permite una conexión upstream activa; `http1MaxPendingRequests: 1` permite que una petición adicional se encole mientras esa conexión está ocupada. Así que la profundidad de pipeline es efectivamente 2 en vuelo. Con `-c 1` nunca hay más de una petición pendiente → nada se desborda → 100% `200`. Con `-c 2`, la segunda petición concurrente frecuentemente encuentra tanto la única conexión *como* el único slot pendiente ocupados, así que Envoy dispara el breaker y retorna `503` para el excedente — ~25% acá.

**Q3.3** — Response flag **`UO`** (Upstream Overflow — circuit breaking). Difiere de **`UT`** (timeout): `UO` significa que Envoy **nunca envió** la petición upstream porque un techo de concurrencia ya estaba saturado (fallo rápido / descarga de carga); `UT` significa que la petición *sí* se envió pero el upstream no respondió dentro del presupuesto.

**Q3.4** — No. Los límites del pool de conexiones se aplican **por instancia de Envoy del cliente**, de forma independiente. Con 3 réplicas de fortio cada una permitiendo `maxConnections: 1`, el backend httpbin puede ver hasta **3** conexiones concurrentes en agregado. Los límites del circuit-breaker son *locales* a cada proxy, no una cuota global a nivel de cluster.

### Ejercicio 4

**Q4.1** — Una **readinessProbe** de Kubernetes es un check *activo* que el kubelet realiza sobre un endpoint/intervalo fijo; quita un pod de los endpoints del *Service* cuando la sonda falla. **Outlier detection** es *pasivo* — juzga los endpoints según las respuestas *reales* de producción que Envoy ya está recibiendo, así que atrapa fallos parciales/intermitentes que una readiness probe gruesa deja pasar (p. ej., el endpoint de salud está bien pero una dependencia que el tráfico real golpea está en timeout). A la inversa, la readiness atrapa un pod que está *arrancando* o que *todavía no tiene tráfico en vivo*, lo que la detección pasiva no puede ver porque no hay respuestas que juzgar. Son complementarias.

**Q4.2** — Secuencia de expulsión: Envoy contabiliza respuestas por endpoint. Cuando un endpoint retorna **3 `5xx` consecutivos** (los reseteos de conexión cuentan como `5xx` por defecto), entonces en el siguiente **`interval` de análisis (cada 5 s)** Envoy lo expulsa — lo quita del pool de LB — durante **`baseEjectionTime` (30 s)**. Readmisión: después de 30 s vuelve al pool y se sondea con tráfico real; si vuelve a fallar, la duración de la expulsión crece (multiplicada por el conteo de expulsiones), retrocediendo (backoff) sobre los reincidentes.

**Q4.3** — `maxEjectionPercent` limita cuánto del pool se le *permite* a Envoy expulsar. El default es conservador (10%), así que con un pool chico Envoy puede **negarse a expulsar** endpoints malos adicionales aunque estén fallando. Peor, Envoy tiene un **umbral de pánico**: si la fracción de endpoints *sanos* cae por debajo de ~50%, decide que su visión de salud es poco confiable y **enruta a todos los endpoints sin importar la salud** (panic routing) — enviando tráfico de vuelta a los enfermos. Poner `maxEjectionPercent: 100` (y/o ajustar `minHealthPercent`) deja que Envoy expulse tantos como estén genuinamente mal; pero tenés que sopesar eso contra el panic routing cuando *la mayoría* de los endpoints están caídos.

**Q4.4** — **Failover por localidad** (Ejercicio 5). Envoy solo degrada tráfico de la localidad local (priority 0) a una localidad de respaldo (priority 1) una vez que los endpoints locales están marcados como insalubres — y el *único* mecanismo que los marca como insalubres sin health checks activos es **outlier detection**. Sin él, ningún endpoint jamás se vuelve "insalubre", así que el failover nunca se dispara.

### Ejercicio 5

**Q5.1** — Dependencia dura: **outlier detection debe estar configurado.** El failover promueve una localidad de menor prioridad solo cuando los endpoints de mayor prioridad están *insalubres*, y outlier detection es lo que produce esa señal de insalubridad. Omitilo y el failover queda inerte — todas las localidades efectivamente se mantienen en plena salud, así que el tráfico nunca se desplaza aunque la zona local esté fallando.

**Q5.2** — `failover` = **basado en prioridad**: el tráfico se queda 100% en la localidad local hasta que está insalubre, luego se derrama al respaldo nombrado — por *disponibilidad* (tolerancia a desastres/caída de zona). `distribute` = **división ponderada**: enviás explícitamente porcentajes fijos a localidades nombradas (p. ej., 70/30) sin importar la salud — por *modelado deliberado de tráfico cross-zone*. Elegí `failover` para mantenerlo-local-hasta-que-se-rompa; elegí `distribute` cuando querés una distribución cross-zone permanente específica.

**Q5.3** — Bajo condiciones de todo-sano una política de `failover` envía **0%** al respaldo — el 100% se queda local. Eso es correcto porque el tráfico de la misma zona tiene la **menor latencia y evita el costo de transferencia de datos cross-zone**; el respaldo es un standby en frío que solo toma carga durante un fallo.

**Q5.4** — `topology.kubernetes.io/region` y `topology.kubernetes.io/zone` (Istio además honra una sub-zona vía la etiqueta `topology.istio.io/subzone`). Un pod en un nodo al que le faltan estas etiquetas tiene una **localidad vacía/desconocida**; se trata como una localidad distinta que no matchea ninguna regla de failover `from`/`to`, así que participa como un endpoint sin agrupar y no se beneficia del enrutamiento por prioridad con conciencia de localidad.

### Ejercicio 6

**Q6.1** — Orden de acción sobre una única petición condenada:
1. **Límite del pool de conexiones (circuit breaking)** — evaluado *antes de que la petición salga del Envoy del cliente*; si está saturado, `503 UO`, nada golpea el cable.
2. **Per-try timeout** — acota cada intento individual una vez enviado.
3. **Retry** — dispara después de un intento fallido/en timeout, sujeto a `retryOn`.
4. **Timeout de ruta global** — el techo de reloj de pared que abarca todos los intentos+backoffs.
5. **Expulsión por outlier** — una consecuencia *en segundo plano*: los errores del endpoint que falla se acumulan y es expulsado en el siguiente intervalo, afectando peticiones *futuras*, no esta.
Las que pueden actuar **antes del cable**: el **circuit breaker del pool de conexiones** (e, indirectamente, la expulsión por outlier habiendo ya quitado un endpoint del pool).

**Q6.2** — Durante una sobrecarga el circuit breaker está *descargando* carga precisamente porque el backend está saturado. Un `attempts` grande reinyecta cada petición descargada/fallida varias veces, multiplicando la carga ofrecida contra un servicio que ya está en su límite — una **tormenta de retries** que profundiza la sobrecarga y puede disparar el breaker para todos. Los retries ayudan con fallos transitorios aislados; son contraproducentes como respuesta a una saturación sistémica. Mantené `attempts` chico y combinalo con presupuestos de retry (retry budgets)/backoff.

**Q6.3** — Con 3+ réplicas, `consecutive5xxErrors: 5` expulsa solo endpoints que están *claramente* fallando, y `maxEjectionPercent: 50` garantiza que a lo sumo la mitad del pool pueda quitarse a la vez. Así que si dos de cuatro réplicas se ponen malas, Envoy las expulsa y concentra el tráfico en las dos sanas — el servicio **se mantiene arriba a capacidad reducida** en lugar de que Envoy expulse todo (lo que dispararía panic routing o dejaría sin endpoints) y agujeree (blackhole) el servicio. Cambia algo de exposición a un endpoint malo por una garantía de que una caída mayoritaria nunca borre todo el pool.

</details>

---

### Fuentes

- Istio — tarea *Circuit Breaking*: https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — tarea *Request Timeouts*: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio — *Network resilience and testing* (conceptos de retries, timeouts, circuit breaking): https://istio.io/latest/docs/concepts/traffic-management/#network-resilience-and-testing
- Istio — referencia de `HTTPRetry`: https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRetry
- Istio — referencia de `ConnectionPoolSettings`: https://istio.io/latest/docs/reference/config/networking/destination-rule/#ConnectionPoolSettings
- Istio — referencia de `OutlierDetection`: https://istio.io/latest/docs/reference/config/networking/destination-rule/#OutlierDetection
- Istio — referencia de `LocalityLoadBalancerSetting`: https://istio.io/latest/docs/reference/config/networking/destination-rule/#LocalityLoadBalancerSetting
- Istio — tarea *Locality Load Balancing: Failover*: https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/failover/
- Envoy — arquitectura de *Outlier detection* y *Circuit breaking*: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier y https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking
- CNCF ICA curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf