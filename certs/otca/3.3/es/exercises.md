# OTCA — Domain 3: The OpenTelemetry Collector
## Topic 3.3 — Scaling (Ejercicios guiados)

> **Alcance.** Estos ejercicios entrenan el razonamiento de producción que la OTCA espera para escalar el OpenTelemetry Collector: distinguir pipelines **stateless** de **stateful**, escalar pipelines stateless horizontalmente, resolver el problema de **afinidad de trazas** con el **load-balancing exporter**, fragmentar (shard) el scrapeo de métricas con el **Target Allocator**, y proteger una flota escalada con **backpressure** y **autoscaling**. Cada config es completa y válida para un build reciente de `otelcol-contrib`.
>
> **Prerrequisitos.** Docker (o Podman) para los Ejercicios 1–3 y 5; un cluster `kind`/`minikube` más `kubectl` y el **OpenTelemetry Operator** para el Ejercicio 4. Un generador de tráfico: `telemetrygen` (`go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest`). Usamos la distribución `contrib` porque `loadbalancing`, `tail_sampling` y el receiver `prometheus` viven ahí.
>
> **El modelo mental.** Un pipeline del Collector escala *horizontalmente y sin restricciones* **solo si cada componente es stateless** — una decisión sobre un elemento nunca depende de otro elemento. En el momento en que un componente debe *ver un grupo de elementos juntos* (todos los spans de una traza, todos los puntos delta de una serie), el balanceo round-robin ingenuo lo rompe, y necesitás **enrutamiento por afinidad** o **sharding**.

---

## Exercise 1 — Baseline: un Collector y su telemetría interna

No podés escalar lo que no podés medir. Primero, aprendé a leer las propias métricas del Collector, que son la fuente de verdad para toda decisión de escalado que sigue.

**Pasos**

1. Creá `collector.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch:
       send_batch_size: 8192
       timeout: 5s

   exporters:
     debug:
       verbosity: basic

   service:
     telemetry:
       metrics:
         # Prometheus scrape endpoint for the Collector's own metrics
         readers:
           - pull:
               exporter:
                 prometheus:
                   host: 0.0.0.0
                   port: 8888
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug]
   ```

2. Ejecutalo:

   ```bash
   docker run --rm -p 4317:4317 -p 4318:4318 -p 8888:8888 \
     -v "$(pwd)/collector.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:latest \
     --config /etc/otelcol/config.yaml
   ```

3. En una segunda terminal, enviá una carga acotada y limitada por tasa:

   ```bash
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure \
     --traces 5000 --rate 200 --child-spans 3
   ```

4. Scrapeá las métricas internas del Collector y extraé las señales que importan para escalar:

   ```bash
   curl -s localhost:8888/metrics | grep -E \
     'otelcol_receiver_(accepted|refused)_spans|otelcol_exporter_(sent|send_failed)_spans|otelcol_exporter_queue_(size|capacity)|otelcol_process_memory_rss'
   ```

   Esperado (los valores diferirán):

   ```text
   otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 20000
   otelcol_receiver_refused_spans_total{receiver="otlp",transport="grpc"} 0
   otelcol_exporter_sent_spans_total{exporter="debug"} 20000
   otelcol_exporter_send_failed_spans_total{exporter="debug"} 0
   otelcol_exporter_queue_size{exporter="debug"} 0
   otelcol_exporter_queue_capacity{exporter="debug"} 1000
   otelcol_process_memory_rss_bytes 8.5e+07
   ```

**Comprobá tu comprensión**

- **1a.** ¿Qué dos counters, comparados como un ratio, te dicen si el lado de *recepción* está saturado, y qué dos te dicen que el lado de *exportación* está fallando?
- **1b.** Observás que `otelcol_exporter_queue_size` sube de forma sostenida hacia `otelcol_exporter_queue_capacity`. ¿El cuello de botella está aguas arriba (receiver) o aguas abajo (backend/exporter)? Justificá.
- **1c.** ¿Por qué “cantidad de spans por segundo que el proceso maneja” es un mal objetivo de escalado por sí solo, comparado con observar `refused` + `send_failed` + `queue_size` juntos?

---

## Exercise 2 — Escalar un pipeline *stateless* horizontalmente

Un pipeline de `otlp → batch → otlp/debug` no mantiene **ningún estado entre elementos**: cualquier span puede ser procesado por cualquier réplica. Ese es el caso fácil — poné N réplicas detrás de un load balancer L4/L7 y listo.

**Pasos**

1. Confirmá que el pipeline es stateless: listá sus componentes (`otlp` receiver, `batch`, `memory_limiter`, `resource`, `filter`, `transform`, la mayoría de los exporters). Ninguno de ellos toma una decisión sobre el elemento A que dependa del elemento B.

2. Simulá tres réplicas detrás de DNS round-robin con Docker Compose. Creá `compose.yaml`:

   ```yaml
   services:
     collector:
       image: otel/opentelemetry-collector-contrib:latest
       command: ["--config", "/etc/otelcol/config.yaml"]
       volumes:
         - ./collector.yaml:/etc/otelcol/config.yaml
       deploy:
         replicas: 3
       expose:
         - "4317"
     lb:
       image: nginx:latest
       ports:
         - "4317:4317"
       volumes:
         - ./nginx.conf:/etc/nginx/nginx.conf:ro
       depends_on:
         - collector
   ```

   `nginx.conf` (balanceo de stream gRPC L4 entre los tres backends):

   ```nginx
   events {}
   stream {
     upstream collectors {
       server collector:4317;   # Docker DNS returns all 3 replica IPs
     }
     server {
       listen 4317;
       proxy_pass collectors;
     }
   }
   ```

3. Lanzá y generá carga:

   ```bash
   docker compose up -d
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 9000 --rate 300
   ```

4. Verificá que la carga se repartió entre las réplicas sumando `accepted_spans` de cada una:

   ```bash
   for id in $(docker compose ps -q collector); do
     ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")
     echo -n "$ip: "
     docker exec "$id" wget -qO- "http://localhost:8888/metrics" \
       | grep '^otelcol_receiver_accepted_spans_total' | awk '{print $2}'
   done
   ```

   Esperado — el total se conserva y está aproximadamente balanceado:

   ```text
   172.20.0.3: 12040
   172.20.0.4: 11980
   172.20.0.5: 11980
   ```

**Comprobá tu comprensión**

- **2a.** ¿Por qué el balanceo round-robin es *correcto* para este pipeline pero sería *incorrecto* en el momento en que agregás un processor `tail_sampling`?
- **2b.** Nombrá tres componentes del Collector seguros de escalar de esta forma y una categoría de componente que no lo sea.
- **2c.** Un cliente gRPC abre una conexión HTTP/2 de larga duración y multiplexa todos los streams sobre ella. ¿Qué implica eso respecto al balanceo en L4 (TCP) versus L7 (por request), y cuál realmente reparte la carga OTLP de forma pareja?

---

## Exercise 3 — El problema de afinidad de trazas y el load-balancing exporter (dos tiers)

`tail_sampling` es **stateful**: para decidir si conservar una traza, debe hacer buffer de *todos los spans de esa traza* durante `decision_wait`, y luego aplicar policies. Si los spans de una traza quedan dispersos entre las réplicas por round-robin, cada réplica ve una traza *parcial* y toma una decisión errónea o duplicada. La solución es un **deployment de dos tiers (por capas)**: un **gateway tier** stateless que enruta por trace ID, alimentando un **sampling tier** donde cada backend es dueño de trazas completas.

**Pasos**

1. **Sampling tier** — `sampling.yaml` (esto es lo que escala para la decisión real):

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     tail_sampling:
       decision_wait: 10s
       num_traces: 100000
       expected_new_traces_per_sec: 1000
       policies:
         - name: keep-errors
           type: status_code
           status_code:
             status_codes: [ERROR]
         - name: keep-slow
           type: latency
           latency:
             threshold_ms: 500
         - name: baseline-sample
           type: probabilistic
           probabilistic:
             sampling_percentage: 10

   exporters:
     debug:
       verbosity: basic

   service:
     telemetry:
       metrics:
         readers:
           - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
     pipelines:
       traces:
         receivers: [otlp]
         processors: [tail_sampling]
         exporters: [debug]
   ```

2. **Gateway tier** — `gateway.yaml`. El exporter `loadbalancing` hashea sobre `routing_key: traceID`, de modo que cada span que comparte un trace ID se envía al *mismo* backend:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   exporters:
     loadbalancing:
       routing_key: traceID          # affinity by trace; use "service" for spanmetrics
       protocol:
         otlp:
           tls:
             insecure: true
       resolver:
         # In Docker, Compose DNS returns all sampler replica IPs for this name.
         dns:
           hostname: sampling
           port: 4317
         # In Kubernetes, prefer the k8s resolver against a headless Service:
         # k8s:
         #   service: otel-sampling-collector-headless.observability
         #   ports: [4317]

   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [loadbalancing]
   ```

3. `compose.yaml`:

   ```yaml
   services:
     sampling:
       image: otel/opentelemetry-collector-contrib:latest
       command: ["--config", "/etc/otelcol/config.yaml"]
       volumes: [./sampling.yaml:/etc/otelcol/config.yaml]
       deploy: { replicas: 3 }
       expose: ["4317", "8888"]
     gateway:
       image: otel/opentelemetry-collector-contrib:latest
       command: ["--config", "/etc/otelcol/config.yaml"]
       volumes: [./gateway.yaml:/etc/otelcol/config.yaml]
       ports: ["4317:4317"]
       depends_on: [sampling]
   ```

4. Enviá trazas a través del gateway, luego confirmá la afinidad — cada sampler debería reportar un conteo de decisiones de `tail_sampling`, y **ninguna traza debería quedar dividida**:

   ```bash
   docker compose up -d
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 6000 --rate 200 --child-spans 4

   for id in $(docker compose ps -q sampling); do
     echo -n "sampler $id sampled/dropped: "
     docker exec "$id" wget -qO- localhost:8888/metrics \
       | grep -E 'otelcol_processor_tail_sampling_(count_traces_sampled|global_count_traces_sampled)' | tr '\n' ' '
     echo
   done
   ```

   Esperado — aproximadamente un tercio de las *trazas* (no de los spans) cae en cada sampler, y cada sampler decidió sobre trazas completas:

   ```text
   sampler ...a sampled/dropped: otelcol_processor_tail_sampling_global_count_traces_sampled{...sampled="true"} 210 ...sampled="false"} 1790
   sampler ...b sampled/dropped: ... true 205 ... false 1795
   sampler ...c sampled/dropped: ... true 208 ... false 1792
   ```

5. Reiniciá un sampler y reenviá. Observá que solo las trazas hasheadas a esa instancia se ven afectadas durante la reconvergencia del DNS/resolver — las otras dos continúan sin verse afectadas.

**Comprobá tu comprensión**

- **3a.** ¿Por qué *exactamente* poner tres collectors `tail_sampling` detrás del balanceo round-robin del Ejercicio 2 produce un sampling incorrecto?
- **3b.** ¿Qué tier es stateless y cuál es stateful en este diseño? ¿Qué tier autoescalás con un HPA de CPU simple, y cuál requiere cuidado?
- **3c.** ¿Cuándo pondrías `routing_key: service` en lugar de `traceID`? (Pista: ¿qué connector necesita *todos los spans de un servicio*, no de una traza, en una instancia?)
- **3d.** En Kubernetes, ¿por qué el exporter `loadbalancing` debe resolver un Service **headless**, y qué saldría mal si apuntaras su resolver `dns` a un Service ClusterIP normal?
- **3e.** Escalás el sampling tier de 3 → 6 réplicas. Con `routing_key: traceID`, ¿qué fracción de las asignaciones traza-a-backend se reacomoda, y por qué eso importa *solo para las trazas en vuelo durante el cambio*?

---

## Exercise 4 — Fragmentar (sharding) el scrapeo de métricas con el Target Allocator

El receiver `prometheus` también es *stateful en un sentido de escalado*: si corrés N réplicas del collector cada una con los mismos `scrape_configs`, **cada réplica scrapea cada target**, produciendo series duplicadas N veces. No podés salir de esto con round-robin — debés **fragmentar (shard) la lista de targets**. El **Target Allocator (TA)** del OTel Operator hace exactamente eso: descubre targets y asigna subconjuntos disjuntos a cada réplica del collector.

**Pasos**

1. Instalá el OpenTelemetry Operator (trae cert-manager si es necesario):

   ```bash
   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   kubectl -n opentelemetry-operator-system rollout status deploy/opentelemetry-operator-controller-manager
   ```

2. Creá un collector fragmentado, en modo StatefulSet, con TA habilitado — `otel-metrics.yaml`:

   ```yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: otel-metrics
     namespace: observability
   spec:
     mode: statefulset            # stable pod identity is required for stable sharding
     replicas: 3
     targetAllocator:
       enabled: true
       allocationStrategy: consistent-hashing   # or per-node / least-weighted
       prometheusCR:
         enabled: true            # also honor ServiceMonitor / PodMonitor CRs
     config:
       receivers:
         prometheus:
           config:
             scrape_configs:
               - job_name: 'kubelet-cadvisor'
                 scheme: https
                 kubernetes_sd_configs:
                   - role: node
                 tls_config:
                   insecure_skip_verify: true
                 authorization:
                   credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
       processors:
         batch: {}
       exporters:
         debug:
           verbosity: basic
       service:
         pipelines:
           metrics:
             receivers: [prometheus]
             processors: [batch]
             exporters: [debug]
   ```

   ```bash
   kubectl create namespace observability
   kubectl apply -f otel-metrics.yaml
   ```

3. Observá lo que el Operator **inyectó**. El TA reescribe el receiver `prometheus` de cada collector para que *tome su asignación desde el allocator* en lugar de hacer service discovery por sí mismo:

   ```bash
   kubectl -n observability get cm otel-metrics-collector -o yaml | sed -n '/prometheus:/,/service:/p'
   ```

   Esperado (abreviado) — notá el bloque `target_allocator` inyectado y que `scrape_configs` ahora es gestionado por el TA:

   ```yaml
   receivers:
     prometheus:
       config:
         global: {}
       target_allocator:
         endpoint: http://otel-metrics-targetallocator:80
         interval: 30s
         collector_id: ${POD_NAME}
   ```

4. Preguntale al allocator cómo fragmentó los targets entre los tres pods:

   ```bash
   kubectl -n observability port-forward svc/otel-metrics-targetallocator 8080:80 &
   curl -s localhost:8080/jobs/kubelet-cadvisor/targets | jq 'keys, (.. | .collector? // empty) ' | head
   # Per-collector view:
   curl -s 'localhost:8080/jobs/kubelet-cadvisor/targets?collector_id=otel-metrics-collector-0' | jq '.[].targets'
   ```

   Esperado — los targets de nodo están particionados, no duplicados: collector-0, -1, -2 poseen cada uno una porción disjunta de los nodos.

**Comprobá tu comprensión**

- **4a.** Sin el Target Allocator, ¿qué está mal exactamente con las métricas producidas por 3 réplicas idénticas del receiver prometheus?
- **4b.** ¿Por qué el sharding del TA requiere `mode: statefulset` en lugar de `deployment`? ¿En qué propiedad de los pods de StatefulSet se apoya `consistent-hashing`?
- **4c.** Se agrega un nodo al cluster. Recorré cómo el endpoint cadvisor del nuevo nodo termina asignado a exactamente una réplica del collector.
- **4d.** Contrastá los dos mecanismos de escalado que ya viste para datos stateful: **enrutamiento por afinidad** (Ejercicio 3) vs **sharding de targets** (Ejercicio 4). ¿Qué garantiza cada uno, y por qué no podés intercambiar uno por el otro?

---

## Exercise 5 — Backpressure, `memory_limiter`, y autoscaling

Escalar horizontalmente no es gratis: un backend aguas abajo puede seguir siendo el verdadero cuello de botella, y un Collector sobrealimentado se OOM-killea en vez de degradarse con gracia. El escalado de producción siempre empareja el conteo de réplicas con **backpressure** (queue + retry, limitación de memoria) y una **policy de autoscaling** guiada por la señal correcta.

**Pasos**

1. Endurecé un pipeline — `hardened.yaml`. El orden importa: `memory_limiter` **primero**, `batch` **después**:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     memory_limiter:
       check_interval: 1s
       limit_percentage: 80
       spike_limit_percentage: 25
     batch:
       send_batch_size: 8192
       timeout: 5s

   exporters:
     otlp:
       endpoint: backend:4317
       tls:
         insecure: true
       sending_queue:
         enabled: true
         num_consumers: 10
         queue_size: 5000
       retry_on_failure:
         enabled: true
         initial_interval: 5s
         max_interval: 30s
         max_elapsed_time: 300s

   service:
     telemetry:
       metrics:
         readers:
           - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [otlp]
   ```

2. Ejecutalo con **ningún backend escuchando** para que el exporter falle, forzando a la queue a llenarse y a que el backpressure se propague:

   ```bash
   docker run --rm -p 4317:4317 -p 8888:8888 \
     -v "$(pwd)/hardened.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:latest --config /etc/otelcol/config.yaml
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 200000 --rate 5000
   ```

3. Observá cómo suben las señales de backpressure. Cuando la queue está llena, el exporter deja de aceptar, el receiver devuelve `RESOURCE_EXHAUSTED` aguas arriba, y `refused` sube — el Collector descarta carga (sheds load) en vez de morir:

   ```bash
   watch -n1 "curl -s localhost:8888/metrics | grep -E \
     'otelcol_exporter_queue_size|otelcol_exporter_send_failed_spans|otelcol_receiver_refused_spans|otelcol_processor_refused_spans'"
   ```

   Trayectoria esperada:

   ```text
   otelcol_exporter_queue_size{exporter="otlp"} 5000          # pinned at queue_size
   otelcol_exporter_send_failed_spans_total{exporter="otlp"} 41000   # rising
   otelcol_receiver_refused_spans_total{receiver="otlp",...} 8600    # backpressure reaching the client
   otelcol_processor_refused_spans_total{processor="memory_limiter"} 0   # >0 only if memory ceiling is hit
   ```

4. Definí una policy de autoscaling. En el OTel Operator la declarás directamente en el CR:

   ```yaml
   spec:
     autoscaler:
       minReplicas: 2
       maxReplicas: 10
       targetCPUUtilization: 70
       # For queue-driven scaling, feed exporter queue metrics to a
       # custom-metrics adapter and target them here instead of CPU.
   ```

   El HPA plano equivalente (para un gateway en modo `Deployment`):

   ```yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: otel-gateway
     namespace: observability
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: otel-gateway
     minReplicas: 2
     maxReplicas: 10
     metrics:
       - type: Resource
         resource:
           name: cpu
           target:
             type: Utilization
             averageUtilization: 70
   ```

**Comprobá tu comprensión**

- **5a.** ¿Por qué `memory_limiter` debe ser el **primer** processor y `batch` venir **después**? ¿Qué se rompe si los invertís?
- **5b.** Rastreá la cadena de backpressure cuando el backend está caído: exporter → queue → receiver → client. ¿Qué dos métricas prueban que el backpressure está funcionando *como fue diseñado* en vez de descartar datos silenciosamente?
- **5c.** Autoescalás el gateway por CPU al 70%, pero el verdadero cuello de botella es un backend lento (`send_failed` del exporter subiendo, queue clavada en su capacidad, CPU baja). ¿Agregar réplicas ayudará? ¿Cuál es la señal de escalado correcta acá?
- **5d.** Para el **sampling tier** del Ejercicio 3, ¿por qué un HPA basado en CPU es riesgoso, y qué debés tener en cuenta antes de agregar réplicas a una flota `tail_sampling` en funcionamiento?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Exercise 1**

- **1a.** *Saturación de recepción:* `otelcol_receiver_refused_spans_total` subiendo en relación a `otelcol_receiver_accepted_spans_total` — el Collector está rechazando datos entrantes. *Falla de exportación:* `otelcol_exporter_send_failed_spans_total` subiendo en relación a `otelcol_exporter_sent_spans_total` — el backend/exporter no logra entregar.
- **1b.** **Aguas abajo.** La queue es el buffer *que está delante del exporter*. Crece solo cuando el exporter consume más lento de lo que el receiver produce — es decir, el backend (o la red hacia él) no da abasto. Escalar el Collector horizontalmente no ayudará; el backend o la concurrencia del exporter es la restricción.
- **1c.** Los spans/seg crudos miden throughput pero ocultan la *salud*. Un Collector puede empujar muchos spans/seg mientras silenciosamente rechaza (pérdida de datos en el lado de recepción) o falla exportaciones (pérdida de datos en el lado de envío) o bufferiza hacia el OOM (queue cerca de la capacidad). La tríada `refused + send_failed + queue_size` distingue “sano y rápido” de “rápido pero perdiendo datos”, que es la distinción de la que las decisiones de escalado realmente dependen. Fuente: https://opentelemetry.io/docs/collector/internal-telemetry/

**Exercise 2**

- **2a.** Porque `batch`/`otlp` no toman ninguna decisión sobre el span A que dependa del span B, así que dispersar los spans entre réplicas es inofensivo. `tail_sampling` decide sobre una *traza* inspeccionando *todos sus spans juntos*; dispersarlos significa que ninguna réplica ve nunca la traza completa, así que su decisión se basa en datos parciales.
- **2b.** Seguros: receiver `otlp`, `batch`, `memory_limiter`, `resource`, `filter`, `transform`, `attributes`, la mayoría de los exporters. No seguros (stateful / necesitan agrupamiento): `tail_sampling`, los connectors `spanmetrics`/`servicegraph`, `groupbytrace`, la conversión cumulative↔delta que mantiene estado por serie, y la propiedad de scrapeo del receiver `prometheus`.
- **2c.** Una única conexión gRPC/HTTP2 multiplexa todos los requests, así que **el balanceo L4 (TCP) fija toda la conexión a un backend** — un cliente ruidoso puede machacar una sola réplica. **El balanceo L7 (por request / gRPC-aware)** reparte los streams individuales y realmente distribuye la carga OTLP. Por eso el propio exporter `loadbalancing` del Collector (o un mesh/proxy L7) es preferible sobre L4 crudo para una distribución pareja. Fuente: https://opentelemetry.io/docs/collector/scaling/

**Exercise 3**

- **3a.** Con round-robin, los ~15 spans de una traza caen en distintas réplicas. Cada instancia de `tail_sampling` bufferiza solo *su* fragmento durante `decision_wait` y aplica policies a una traza parcial: puede perderse el span hijo que dio error (así una policy como `keep-errors` no se dispara), o dos instancias pueden cada una decidir independientemente conservar su fragmento, produciendo una traza sampleada incompleta o duplicada. El tail sampling correcto requiere *localidad de la traza completa*.
- **3b.** El **gateway tier es stateless** (solo enruta) y se autoescala por CPU con seguridad. El **sampling tier es stateful**; podés escalarlo, pero cada evento de escalado **rehashea las asignaciones traza→backend** y las trazas en vuelo durante la reconvergencia pueden quedar divididas, así que escalalo deliberadamente (no por picos nerviosos de CPU) y dejá que drenen las ventanas de `decision_wait`.
- **3c.** Usá `routing_key: service` cuando el downstream necesita *todos los spans de un servicio dado* en una instancia — por ejemplo, los connectors `spanmetrics`/`servicegraph` agregando métricas por servicio. `traceID` es para tail sampling; `service` es para agregación por servicio.
- **3d.** El exporter `loadbalancing` necesita ver **cada pod IP del backend individualmente** para poder hashear las trazas entre ellos. Un Service **headless** (`clusterIP: None`) hace que el DNS devuelva *todos* los A-records de los pods; un ClusterIP normal devuelve una única IP virtual que kube-proxy balancea de forma opaca — el exporter vería entonces *un* endpoint y perdería todo control de afinidad, colapsando de nuevo al caso round-robin roto. Fuente: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- **3e.** Con el balanceo simple por módulo/hash-por-conteo, ir de 3→6 podría remapear la mayoría de las asignaciones. El exporter `loadbalancing` usa un **anillo de consistent-hashing**, así que solo se reacomoda ~ la fracción del keyspace poseída por los *nuevos* nodos (aproximadamente la porción de la capacidad agregada), y eso importa **solo para las trazas que todavía están dentro de su ventana `decision_wait`** durante el cambio — las trazas ya decididas no se ven afectadas, y las trazas nuevas simplemente hashean a la nueva topología.

**Exercise 4**

- **4a.** Las tres réplicas corren `scrape_configs` idénticos, así que cada una scrapea **cada** target. Obtenés **series temporales duplicadas 3×** (mismas labels, tres fuentes), inflando el costo y corrompiendo rates/agregaciones. El round-robin no puede arreglarlo porque la duplicación está en *qué se scrapea*, no en *a dónde se enrutan los datos*.
- **4b.** `consistent-hashing` necesita una **identidad estable por collector** para que el mismo target mapee a la misma réplica entre reinicios y reconciliaciones. Los pods de StatefulSet tienen nombres ordinales estables (`...-0`, `...-1`) e identidad de red estable; los pods de Deployment obtienen nombres aleatorios que cambian en cada rollout, lo que reacomodaría todo el sharding en cualquier reinicio. Fuente: https://opentelemetry.io/docs/kubernetes/operator/target-allocator/
- **4c.** El service discovery del TA (rol node / PodMonitor / ServiceMonitor) observa el nuevo nodo → el allocator hashea el nuevo target sobre su anillo → lo asigna a exactamente un `collector_id` → ese collector, que consulta `GET /jobs/<job>/targets?collector_id=...` cada `interval`, lo recoge en su próximo refresco y comienza a scrapearlo. Ninguna otra réplica lo scrapea.
- **4d.** El **enrutamiento por afinidad** (Ejercicio 3) garantiza que *todos los elementos de un grupo lleguen a la misma instancia de procesamiento* — necesario cuando una decisión requiere ver el grupo completo (una traza). El **sharding de targets** (Ejercicio 4) garantiza que *cada fuente sea propiedad de exactamente una instancia* — necesario cuando el riesgo es la *duplicación* de pulls independientes. No son intercambiables: fragmentar los targets de scrapeo no mantendría los spans de una traza juntos (las trazas llegan basadas en push, no como targets de scrapeo), y el enrutamiento por afinidad de métricas no evitaría que cada réplica scrapee cada endpoint.

**Exercise 5**

- **5a.** `memory_limiter` debe correr **primero** para poder rechazar/refusar datos entrantes en el instante en que se detecta presión de memoria, *antes* de que ocurra cualquier procesamiento costoso o buffering; ponerlo después de `batch` significa que los batches ya están acumulados en memoria antes de que el limiter pueda actuar, anulando su propósito y arriesgando el OOM. `batch` va después para que solo los datos admitidos se batcheen. Fuente: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- **5b.** El exporter falla → su `sending_queue` se llena hasta `queue_size` → la queue llena aplica backpressure al pipeline → el receiver devuelve `RESOURCE_EXHAUSTED`/refusa → el cliente OTLP ve el error y (idealmente) reintenta/desacelera. La prueba de que está funcionando *como fue diseñado*: `otelcol_exporter_queue_size` clavada en su capacidad **y** `otelcol_receiver_refused_spans_total` subiendo — el Collector está descartando carga en el borde en vez de dropear silenciosamente a mitad del pipeline o hacer OOM-kill.
- **5c.** **No — agregar réplicas no ayudará.** La CPU está baja y la restricción es la tasa de ingesta del backend; más réplicas del Collector solo crean más queues ociosas todas bloqueadas por el mismo backend lento. La señal de escalado correcta es la **utilización de la queue del exporter / tasa de `send_failed`**, que apunta al backend — la solución es escalar/optimizar el *backend* (o subir `num_consumers`/la concurrencia del backend), no el Collector. El HPA basado en CPU es ciego a esta clase de cuello de botella.
- **5d.** `tail_sampling` mantiene hasta `num_traces` en memoria durante `decision_wait`, así que su carga es **acotada por memoria y buffer, no por CPU** — la CPU puede verse ociosa mientras la memoria está cerca del límite, de modo que un HPA de CPU escala tarde y, peor, **cada evento de escalado rehashea las asignaciones traza→backend** (vía el hash consistente del gateway), dividiendo trazas que están a mitad de `decision_wait`. Antes de agregar réplicas: dimensioná por memoria, esperá una breve ventana de precisión de sampling degradada durante la reconvergencia, y preferí un escalado deliberado/por pasos sobre umbrales reactivos de CPU.

</details>

---

**Sources**

- OpenTelemetry Collector — *Scaling*: https://opentelemetry.io/docs/collector/scaling/
- OpenTelemetry Collector — *Deployment patterns (agent vs gateway)*: https://opentelemetry.io/docs/collector/deployment/
- Load-balancing exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- Tail sampling processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- Target Allocator: https://opentelemetry.io/docs/kubernetes/operator/target-allocator/
- Memory limiter processor: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- Collector internal telemetry: https://opentelemetry.io/docs/collector/internal-telemetry/
- OTCA curriculum: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf