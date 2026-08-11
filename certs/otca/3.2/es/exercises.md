# Tema 3.2 — Desplegando el OpenTelemetry Collector

> Dominio 3, *The OpenTelemetry Collector* · peso en el examen 5.2
> Los ejercicios de abajo asumen una instalación de Docker funcionando, un cluster local de Kubernetes (`kind`, `minikube` o `k3d`), `kubectl`, y acceso de red para descargar el binario del Collector. Cada manifiesto y comando está pensado para ejecutarse tal cual está escrito. Las cadenas de versión que aparecen en las salidas (`0.119.0`) son ilustrativas — tu Collector puede imprimir una más nueva.

Estos labs te guían a través de los cuatro patrones canónicos de despliegue que el syllabus de OTCA espera que distingas — **No-Collector**, **Agent**, **Gateway** y **Sidecar** — y luego a través del **escalado** de una capa de gateway con estado. Hacelos en orden; cada uno se construye sobre el pipeline que configuraste antes.

---

## Ejercicio 1 — El Collector como un único binario (baseline)

Antes de poder razonar sobre *dónde* ejecutar un Collector, necesitás ver un proceso ingerir, procesar y exportar datos. Esta es la forma que todo modo de despliegue reutiliza.

### Pasos

1. Descargá el binario de la distribución **contrib** para tu plataforma desde la página de release y hacelo ejecutable:

   ```bash
   VERSION=0.119.0
   OS=linux ARCH=amd64
   curl -sSLo otelcol-contrib.tar.gz \
     "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${VERSION}/otelcol-contrib_${VERSION}_${OS}_${ARCH}.tar.gz"
   tar -xzf otelcol-contrib.tar.gz otelcol-contrib
   ./otelcol-contrib --version
   ```

   Esperado:

   ```
   otelcol-contrib version 0.119.0
   ```

2. Escribí una config mínima pero con forma de producción en `config.yaml`. Notá el orden de los processors y las tres extensions de diagnóstico:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     memory_limiter:
       check_interval: 1s
       limit_percentage: 80
       spike_limit_percentage: 25
     batch:
       send_batch_size: 8192
       timeout: 5s

   exporters:
     debug:
       verbosity: detailed

   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     pprof:
       endpoint: 0.0.0.0:1777
     zpages:
       endpoint: 0.0.0.0:55679

   service:
     extensions: [health_check, pprof, zpages]
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [debug]
     telemetry:
       metrics:
         level: detailed
         address: 0.0.0.0:8888
   ```

3. Iniciá el Collector y leé los logs de arranque:

   ```bash
   ./otelcol-contrib --config=config.yaml
   ```

   Esperado (recortado):

   ```
   info    service@v0.119.0/service.go:...  Setting up own telemetry...
   info    otlpreceiver@.../otlp.go:...     Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
   info    otlpreceiver@.../otlp.go:...     Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
   info    service@v0.119.0/service.go:...  Everything is ready. Begin running and processing data.
   ```

4. En una segunda terminal, generá cinco spans de prueba con `telemetrygen` (parte de la misma organización del release) y observá la primera terminal:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 5
   ```

   El exporter `debug` del Collector imprime:

   ```
   info    Traces  {"resource spans": 1, "spans": 5}
   info    ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   Span #0
       Trace ID       : 6a...  Span ID: 1f...  Name: okey-dokey-0  Kind: Server
   ...
   ```

5. Confirmá que las superficies operativas están activas:

   ```bash
   curl -s localhost:13133          # health_check → HTTP 200
   curl -s localhost:8888/metrics | grep otelcol_receiver_accepted_spans
   ```

   Línea de métrica esperada:

   ```
   otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc",...} 5
   ```

**Preguntas de comprensión (Bloque 1)**

- **1a.** ¿Por qué aparece `memory_limiter` *primero* en la lista de `processors` del pipeline, antes que `batch`?
- **1b.** Los puertos `4317` y `4318` transportan telemetría *hacia adentro*. ¿Para qué sirven los puertos `13133`, `8888`, `1777` y `55679`, y por qué nunca los expondrías al tráfico de las aplicaciones?
- **1c.** Ejecutaste la distribución `contrib`. ¿Cuándo sería la distribución más chica `otelcol` (core) la elección correcta en su lugar, y cuál es el riesgo de estandarizar en `contrib` en todos lados?

---

## Ejercicio 2 — Agent vs Gateway: encadenando dos capas de Collector

El Agent se ejecuta *cerca del workload* (uno por nodo, o por pod) y descarga rápido. El Gateway es un *servicio standalone, escalado horizontalmente* que hace el trabajo más pesado y centralizado. Los pipelines de producción usualmente ejecutan **ambos**: los agents hacen fan-in hacia un gateway. Vas a construir exactamente eso.

### Pasos

1. Instalá el OpenTelemetry Operator (requiere cert-manager). Esperá a que ambos estén listos:

   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
   kubectl wait --for=condition=Available deploy --all -n cert-manager --timeout=180s

   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   kubectl wait --for=condition=Available deploy/opentelemetry-operator-controller-manager \
     -n opentelemetry-operator-system --timeout=180s

   kubectl create namespace observability
   ```

2. Desplegá la capa **Gateway** como un `Deployment` con tres replicas. Por ahora termina el pipeline en `debug`:

   ```yaml
   # gateway.yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: gateway
     namespace: observability
   spec:
     mode: deployment
     replicas: 3
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317
             http:
               endpoint: 0.0.0.0:4318
       processors:
         memory_limiter:
           check_interval: 1s
           limit_percentage: 80
           spike_limit_percentage: 25
         batch: {}
       exporters:
         debug:
           verbosity: normal
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, batch]
             exporters: [debug]
   ```

   ```bash
   kubectl apply -f gateway.yaml
   kubectl -n observability get otelcol,deploy,svc
   ```

   El operator materializa un Deployment más Services estables. Esperado (recortado):

   ```
   NAME                             MODE         REPLICAS
   opentelemetrycollector/gateway   deployment   3

   NAME                          READY
   deployment.apps/gateway-collector   3/3

   NAME                                     TYPE        PORT(S)
   service/gateway-collector               ClusterIP   4317/TCP,4318/TCP
   service/gateway-collector-headless      ClusterIP   4317/TCP,4318/TCP
   service/gateway-collector-monitoring    ClusterIP   8888/TCP
   ```

3. Desplegá la capa **Agent** como un `DaemonSet` (un pod por nodo). Recibe OTLP localmente, lo enriquece, hace batch, y lo reenvía al `Service` del gateway por OTLP:

   ```yaml
   # agent.yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: agent
     namespace: observability
   spec:
     mode: daemonset
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317
             http:
               endpoint: 0.0.0.0:4318
       processors:
         memory_limiter:
           check_interval: 1s
           limit_percentage: 80
           spike_limit_percentage: 25
         resourcedetection:
           detectors: [env, system]
         batch: {}
       exporters:
         otlp:
           endpoint: gateway-collector.observability.svc.cluster.local:4317
           tls:
             insecure: true
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, resourcedetection, batch]
             exporters: [otlp]
   ```

   ```bash
   kubectl apply -f agent.yaml
   kubectl -n observability get ds/agent-collector
   ```

4. Enviá tráfico *a un pod del agent* y probá que llega al gateway. Hacé port-forward al agent, dispará spans, y luego leé los logs del gateway:

   ```bash
   kubectl -n observability port-forward ds/agent-collector 4317:4317 &
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 3

   kubectl -n observability logs deploy/gateway-collector --all-pods=true --tail=20 | grep -i "spans"
   ```

   Esperado — el gateway (no el agent) es la capa que imprime los spans exportados:

   ```
   info    Traces  {"resource spans": 1, "spans": 3}
   ```

**Preguntas de comprensión (Bloque 2)**

- **2a.** El agent usa `mode: daemonset` y el gateway `mode: deployment`. Explicá *por qué cada patrón mapea a ese tipo de workload* — qué propiedad de la topología de nodos fuerza el DaemonSet, y por qué el gateway es un Deployment en lugar de un DaemonSet.
- **2b.** El pipeline del agent incluye `resourcedetection` pero el del gateway no. ¿Por qué el enriquecimiento de recursos (metadata de host, k8s, cloud) es un trabajo para la capa *más cercana al workload* y no para el gateway central?
- **2c.** El agent exporta a `gateway-collector` (el Service ClusterIP regular), no a `gateway-collector-headless`. ¿Qué te da el Service regular acá, y en qué escenario posterior (Ejercicio 4) esa elección se vuelve *incorrecta*?
- **2d.** Dá dos responsabilidades concretas que empujarías *hacia arriba* al gateway en lugar de ejecutarlas en cada agent, y explicá la razón de recursos/consistencia de cada una.

---

## Ejercicio 3 — Despliegue Sidecar con el Operator

El Sidecar es un Agent que comparte un **pod** con exactamente una instancia de la aplicación. El Operator lo inyecta como un container extra cuando un pod está anotado. Usá esto cuando necesites aislamiento por pod, ciclo de vida por pod, o un endpoint OTLP solo-localhost que nunca deja el pod sin batchear.

### Pasos

1. Definí un Collector en `mode: sidecar`. En modo sidecar *no* debés fijar el receiver a `0.0.0.0` en un puerto compartido que podría colisionar — bindeá localhost y reenviá al gateway:

   ```yaml
   # sidecar.yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: sidecar
     namespace: observability
   spec:
     mode: sidecar
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 127.0.0.1:4317
             http:
               endpoint: 127.0.0.1:4318
       processors:
         batch: {}
       exporters:
         otlp:
           endpoint: gateway-collector.observability.svc.cluster.local:4317
           tls:
             insecure: true
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [batch]
             exporters: [otlp]
   ```

   ```bash
   kubectl apply -f sidecar.yaml
   ```

2. Desplegá un workload y solicitá la inyección con la anotación del pod. El valor de la anotación `sidecar` debe coincidir con el nombre del CR en ese namespace:

   ```yaml
   # app.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: demo-app
     namespace: observability
   spec:
     replicas: 1
     selector: { matchLabels: { app: demo-app } }
     template:
       metadata:
         labels: { app: demo-app }
         annotations:
           sidecar.opentelemetry.io/inject: "sidecar"
       spec:
         containers:
           - name: app
             image: ghcr.io/open-telemetry/opentelemetry-collector-releases/telemetrygen:latest
             args:
               - traces
               - --otlp-insecure
               - --otlp-endpoint=localhost:4317
               - --duration=10m
               - --rate=1
   ```

   ```bash
   kubectl apply -f app.yaml
   ```

3. Verificá que el pod ahora ejecuta **dos** containers — tu app más `otc-container`:

   ```bash
   kubectl -n observability get pod -l app=demo-app \
     -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   ```

   Esperado:

   ```
   app otc-container
   ```

4. Confirmá que la telemetría de la app, enviada a `localhost:4317`, transita el sidecar inyectado y aterriza en el gateway:

   ```bash
   kubectl -n observability logs deploy/gateway-collector --all-pods=true --tail=5 | grep -i spans
   ```

**Preguntas de comprensión (Bloque 3)**

- **3a.** El receiver OTLP del sidecar bindea `127.0.0.1`, pero el agent DaemonSet del Ejercicio 2 bindeaba `0.0.0.0`. ¿Por qué el bind a localhost es correcto — incluso requerido para el aislamiento — en el caso del sidecar, y qué se rompería si la app apuntara a la IP del nodo en lugar de `localhost`?
- **3b.** Un cluster con 400 pods de aplicación distribuidos en 10 nodos: ¿cuántos procesos Collector existen bajo el patrón Sidecar versus el patrón Agent (DaemonSet), y cuál es la contrapartida operativa que ese número representa?
- **3c.** La anotación de inyección vive en el **pod template**, no en el Deployment. ¿Qué te dice eso sobre *cuándo* se agrega el sidecar, y por qué cambiar la anotación requiere un reinicio del pod para que tenga efecto?

---

## Ejercicio 4 — Escalando el gateway para procesamiento con estado

Un gateway sin estado escala trivialmente: agregá replicas detrás del Service. Deja de ser trivial en el momento en que un processor necesita **todos los spans de un trace en la misma instancia** — el tail-based sampling y span-to-metrics son los casos canónicos. Este ejercicio soluciona el problema de consistencia con un gateway de dos capas y el exporter `loadbalancing`.

### Pasos

1. Observá primero el modo de falla. `tail_sampling` en un gateway de 3 replicas que está balanceado *por conexión* verá fragmentos de cada trace en distintas replicas, por lo que las decisiones de sampling se toman sobre traces incompletos. Confirmá el riesgo conceptualmente inspeccionando cómo se distribuyen las conexiones OTLP/gRPC entre las replicas:

   ```bash
   kubectl -n observability get endpoints gateway-collector -o wide
   ```

   Tres IPs de endpoint → tres tomadores de decisiones independientes, sin estado de trace compartido.

2. Introducí un **gateway de ruteo de capa 1** cuyo único trabajo es hashear por trace ID y fijar cada span de un trace a un collector de **capa 2**. La config de capa 1 usa el exporter `loadbalancing` con un resolver de Kubernetes contra el servicio headless:

   ```yaml
   # gateway-lb.yaml  (layer 1 — routing)
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: gw-router
     namespace: observability
   spec:
     mode: deployment
     replicas: 2
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317
       exporters:
         loadbalancing:
           routing_key: traceID
           protocol:
             otlp:
               tls:
                 insecure: true
           resolver:
             k8s:
               service: gw-sampler-collector-headless.observability
               ports: [4317]
       service:
         pipelines:
           traces:
             receivers: [otlp]
             exporters: [loadbalancing]
   ```

3. Desplegá el **gateway de sampling de capa 2** que realmente ejecuta `tail_sampling`. Como la capa 1 garantiza afinidad de trace, cada replica de capa 2 ve traces completos:

   ```yaml
   # gateway-sampler.yaml  (layer 2 — stateful decision)
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: gw-sampler
     namespace: observability
   spec:
     mode: deployment
     replicas: 3
     config:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317
       processors:
         tail_sampling:
           decision_wait: 10s
           policies:
             - name: keep-errors
               type: status_code
               status_code: { status_codes: [ERROR] }
             - name: sample-rest
               type: probabilistic
               probabilistic: { sampling_percentage: 10 }
       exporters:
         debug: { verbosity: normal }
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [tail_sampling]
             exporters: [debug]
   ```

   ```bash
   kubectl apply -f gateway-sampler.yaml   # create the target first
   kubectl apply -f gateway-lb.yaml        # then the router that resolves it
   ```

4. Apuntá los agents del Ejercicio 2 al **router** (`gw-router-collector:4317`) en lugar del gateway viejo, reaplicá, y agregá autoescalado horizontal a la capa *sampler*:

   ```yaml
   # in agent.yaml, change the exporter endpoint:
   #   endpoint: gw-router-collector.observability.svc.cluster.local:4317
   ```

   ```yaml
   # hpa.yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: gw-sampler
     namespace: observability
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: gw-sampler-collector
     minReplicas: 3
     maxReplicas: 10
     metrics:
       - type: Resource
         resource:
           name: cpu
           target: { type: Utilization, averageUtilization: 70 }
   ```

   ```bash
   kubectl apply -f hpa.yaml
   kubectl -n observability get hpa gw-sampler
   ```

5. Observá cómo el exporter `loadbalancing` reacciona cuando la capa sampler escala. El resolver de k8s re-lee los endpoints y rebalancea el hash ring:

   ```bash
   kubectl -n observability logs deploy/gw-router-collector --all-pods=true | grep -i "resolver\|endpoints"
   ```

   Esperado en un evento de escalado:

   ```
   info    loadbalancingexporter  Resolving backends  {"backends": ["10.244.1.7:4317","10.244.2.9:4317", ...]}
   ```

**Preguntas de comprensión (Bloque 4)**

- **4a.** ¿Por qué un gateway con solo `batch` puede escalarse con un Service round-robin simple, mientras que un gateway con `tail_sampling` no puede? Nombrá la propiedad exacta que `loadbalancing` con `routing_key: traceID` restaura.
- **4b.** El router en la capa 1 resuelve `gw-sampler-collector-headless`, no el Service regular `gw-sampler-collector`. ¿Por qué debe apuntar específicamente al servicio **headless** para que el resolver funcione?
- **4c.** El HPA está adjunto a la capa **sampler**, no a la capa router. Dado cómo cada capa hace su trabajo, ¿por qué esa es la capa correcta para autoescalar, y qué hace que la capa sampler sea la que consume más memoria?
- **4d.** Cuando el sampler escala de 3 → 4 pods, el hash ring cambia y una fracción de los traces en vuelo tienen sus spans divididos entre un owner viejo y uno nuevo durante la duración de `decision_wait`. ¿Es esto un bug de correctitud o una contrapartida aceptada? Justificá en una o dos oraciones.

---

<details>
<summary><strong>Clave de respuestas — clic para expandir</strong></summary>

### Bloque 1

**1a.** El pipeline ejecuta los processors **en el orden de la lista**. `memory_limiter` debe ejecutarse primero para poder rechazar o ralentizar los datos entrantes *antes* de que se comprometa memoria al batching. Si `batch` se ejecutara primero, el Collector ya habría asignado grandes batches en memoria para cuando el limiter notara la presión, frustrando su propósito y arriesgando un OOM-kill. La regla general: `memory_limiter` primero, `batch` último (justo antes de los exporters). *Fuente: https://opentelemetry.io/docs/collector/configuration/#processors y el README del processor memory_limiter.*

**1b.** Esas son las **superficies operativas / de diagnóstico** del Collector, no planos de datos:
- `13133` — extension `health_check` (objetivo de probes de liveness/readiness).
- `8888` — la telemetría interna **propia** del Collector (métricas `otelcol_*` en formato Prometheus).
- `1777` — extension `pprof` (profiling de CPU/heap de Go).
- `55679` — extension `zpages` (páginas de debug de trace/pipeline en proceso en vivo, ej. `/debug/tracez`).
Las mantenés fuera del plano de datos y fuera de redes no confiables porque exponen internos (perfiles, datos en vuelo, salud) y no responden ningún tráfico de aplicación; exponerlas amplía la superficie de ataque sin ningún beneficio de telemetría. *Fuente: https://opentelemetry.io/docs/collector/internal-telemetry/*

**1c.** `otelcol` (**core**) trae solo los componentes estables y de uso amplio; `otelcol-contrib` empaqueta el gran conjunto de la comunidad (receivers/processors/exporters extra como `loadbalancing`, `tail_sampling`, `resourcedetection`, exporters de vendors). Elegí **core** cuando tu pipeline solo necesita componentes estables — obtenés una imagen más chica, menor superficie de ataque, y menos partes móviles. Estandarizar en **contrib** en todos lados significa distribuir y asegurar decenas de componentes que nunca usás (imagen más grande, más exposición a CVEs, más trampas de configuración). Los equipos de producción a menudo construyen una **distribución personalizada** con el OpenTelemetry Collector Builder (`ocb`) que contiene exactamente los componentes que usan. *Fuente: https://opentelemetry.io/docs/collector/distributions/ y https://opentelemetry.io/docs/collector/custom-collector/*

### Bloque 2

**2a.** Un **DaemonSet** garantiza *exactamente un pod por nodo*, que es la definición de "un agent local a cada host de workload" — la telemetría de cualquier app nunca tiene que cruzar un límite de nodo para llegar a su agent. Un **Gateway** no tiene afinidad por nodo: es un pool de workers intercambiables dimensionado según el *throughput*, por lo que un **Deployment** (una cantidad arbitraria de replicas que escalás hacia arriba y abajo, agendado en cualquier lado) es el tipo correcto. Ejecutar el gateway como un DaemonSet acoplaría de forma desperdiciada su cantidad de replicas al número de nodos y fijaría la capacidad a la topología en lugar de a la carga. *Fuente: https://opentelemetry.io/docs/collector/deployment/agent/ y .../gateway/*

**2b.** El enriquecimiento de recursos necesita **verdad de terreno local** — el nombre de host, nodo, pod, container, región de cloud — que solo está disponible de forma inequívoca *donde el workload se ejecuta*. El agent (DaemonSet/sidecar) está ahí y puede adjuntar los atributos correctos `host.*`, `k8s.*`, `cloud.*`. Para cuando los datos llegan a un gateway central ya se mezclaron desde muchos nodos; el gateway ya no puede saber de qué host vino un span dado, así que la detección ahí sería incorrecta o imposible.

**2c.** El Service ClusterIP regular `gateway-collector` te da **balanceo de carga por kube-proxy** entre las tres replicas del gateway — está bien cuando el gateway es sin estado (solo `batch`), porque cualquier replica puede manejar cualquier span. Se vuelve **incorrecto** en el Ejercicio 4: una vez que el gateway hace `tail_sampling`, el round-robin por conexión dispersa los spans de un único trace entre las replicas, y las decisiones de sampling se toman sobre traces parciales. Eso es exactamente lo que el exporter `loadbalancing` + el servicio headless soluciona.

**2d.** Dos cualesquiera de: **tail-based sampling** (necesita el trace completo en un solo lugar → centralizar en el gateway, no por nodo); **agregación entre servicios / span-metrics** (un nodo solo ve una porción del tráfico, así que los agregados deben ser centrales); **auth de egreso y fan-out a backends** (mantené las credenciales de vendors y los buffers de retry/cola en una capa gestionada chica, no en cientos de agents); **transforms pesados / redacción de PII** (caro en CPU, más barato hacerlo una vez de forma central que en cada nodo). Las razones comunes son *consistencia* (necesita una vista global) y *economía de recursos* (hacer el trabajo caro en unos pocos pods bien dimensionados, no en N agents).

### Bloque 3

**3a.** En un sidecar el Collector comparte el **network namespace del pod** con la app, así que `localhost:4317` alcanza al sidecar y nada más — el endpoint es privado a ese único pod, que es todo el punto del aislamiento por pod. Bindear `127.0.0.1` garantiza que ningún otro pod pueda enviarle y que ningún puerto colisione en el nodo. Si en cambio la app apuntara a la **IP del nodo**, evitaría su propio sidecar y golpearía el agent DaemonSet (o nada), perdiendo el aislamiento por pod y el batching con alcance de pod para el que existe el sidecar. *Fuente: https://opentelemetry.io/docs/collector/deployment/#sidecar (patrones de despliegue).*

**3b.** Sidecar: **un Collector por pod de aplicación = 400 Collectors**. Agent/DaemonSet: **un Collector por nodo = 10 Collectors**. La contrapartida: el sidecar da el aislamiento más fuerte y ciclo de vida por pod (un pod ruidoso no puede afectar al Collector de un vecino) a costa de 40× la cantidad de procesos, overhead de memoria y rotación de configuración; el DaemonSet es mucho más barato y simple pero comparte la suerte y los recursos de un agent entre todos los pods del nodo.

**3c.** La anotación en el **pod template** significa que la inyección es una **mutación en tiempo de admisión**: el mutating webhook del Operator agrega el `otc-container` cuando el pod se *crea*. Los pods existentes nunca se mutan en el lugar, así que cambiar la anotación solo afecta a los pods nacidos después — debés disparar un rollout (reinicio) para que los pods en ejecución se recreen con (o sin) el sidecar. *Fuente: https://github.com/open-telemetry/opentelemetry-operator#sidecar-injection*

### Bloque 4

**4a.** Un gateway con solo `batch` es **sin estado**: cada span es independiente, así que cualquier replica puede procesar cualquier span y el round-robin está bien. `tail_sampling` es **con estado por trace** — la decisión requiere que *cada span de un trace* esté co-ubicado para que el processor pueda evaluar las políticas contra el trace completo. `loadbalancing` con `routing_key: traceID` restaura la **afinidad de trace**: hashea por el trace ID de modo que todos los spans de un trace dado aterrizan de forma determinista en la misma replica downstream. *Fuente: https://opentelemetry.io/docs/collector/scaling/ y el README del loadbalancingexporter.*

**4b.** El resolver `k8s` debe enumerar las **IPs de pod individuales (endpoints)** de la capa objetivo para construir y mantener su hash ring. Un Service ClusterIP regular esconde los pods detrás de una única IP virtual (kube-proxy balancea de forma opaca), así que el exporter vería un único backend y no podría fijar traces a pods específicos. Un Service **headless** (`clusterIP: None`) publica las IPs de pod directamente vía DNS/Endpoints, que es exactamente lo que el resolver lee. *Fuente: https://opentelemetry.io/docs/collector/scaling/*

**4c.** `tail_sampling` **buffea cada span de cada trace en vuelo durante `decision_wait`** antes de decidir, así que la memoria y CPU de la capa sampler crecen con el volumen de traces — es la capa con estado y hambrienta de recursos y por lo tanto la única cuya carga realmente varía con el tráfico. La capa router solo hashea y reenvía (barato, costo por span aproximadamente constante), así que autoescalarla aporta poco. Escalá donde viven el trabajo y el estado bufferizado: el sampler.

**4d.** Es una **contrapartida aceptada**, no un bug de correctitud. La completitud de trace en un sampler distribuido y escalado elásticamente es *best-effort*: durante un rebalanceo una pequeña fracción de traces que abarcan el evento de escalado puede dividirse, causando en el peor caso una decisión de sampling ligeramente desviada (un trace conservado o descartado que no debería) — nunca corrupción de datos. Las técnicas que lo reducen — `decision_wait` más largo, resolvers de hashing consistente, escalar durante tráfico bajo — mitigan pero no eliminan el problema, y el costo de observabilidad es insignificante frente al beneficio del escalado elástico. *Fuente: https://opentelemetry.io/docs/collector/scaling/*

</details>

---

**Fuentes de referencia**
- Currículo de OTCA: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- Patrones de despliegue del Collector: https://opentelemetry.io/docs/collector/deployment/
- Agent: https://opentelemetry.io/docs/collector/deployment/agent/ · Gateway: https://opentelemetry.io/docs/collector/deployment/gateway/
- Escalando el Collector: https://opentelemetry.io/docs/collector/scaling/
- Kubernetes / Operator: https://opentelemetry.io/docs/platforms/kubernetes/operator/ · https://github.com/open-telemetry/opentelemetry-operator
- Distribuciones y builder: https://opentelemetry.io/docs/collector/distributions/ · https://opentelemetry.io/docs/collector/custom-collector/
- Releases (binarios): https://github.com/open-telemetry/opentelemetry-collector-releases