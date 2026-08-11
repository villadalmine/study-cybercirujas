# OTCA 2.7 — Agents: Ejercicios guiados

> **Primero la terminología.** En OpenTelemetry la palabra *agent* está sobrecargada, y el examen espera que la desambigües:
> 1. **Collector en modo Agent** — un proceso Collector que corre *junto* a la carga de trabajo (DaemonSet por nodo o sidecar por pod), en contraposición a un **Gateway** (servicio compartido, independiente). Este es el significado dominante.
> 2. **Agent de instrumentación zero-code** — un adjunto al runtime del lenguaje (p. ej. el `-javaagent` de Java) que instrumenta una aplicación *sin cambios de código*.
> 3. **Un agent gestionado bajo OpAMP** — cualquier Collector cuya configuración y ciclo de vida son controlados de forma remota por un servidor OpAMP a través de un Supervisor.
>
> Estos ejercicios recorren los tres. Cada manifiesto es sintácticamente completo; cada comando muestra una salida representativa (las versiones y timestamps diferirán en tu máquina).

**Requisitos previos**

- Un cluster de Kubernetes local (`kind create cluster` o `minikube start`) y `kubectl`.
- El binario `otelcol-contrib` (la distribución *contrib* — la distribución *core* carece de `hostmetrics`, `filelog`, `k8sattributes` y `opampsupervisor`). Descargalo desde los [releases del Collector](https://github.com/open-telemetry/opentelemetry-collector-releases/releases).
- Docker, y `curl`/`jq`.
- Referencias de fuentes: [Despliegue del Collector — Agent](https://opentelemetry.io/docs/collector/deployment/agent/), [Gateway](https://opentelemetry.io/docs/collector/deployment/gateway/), [Configuración](https://opentelemetry.io/docs/collector/configuration/).

---

## Ejercicio 1 — Ejecutar un Collector como Agent (DaemonSet)

**Objetivo:** desplegar un Collector por nodo que reciba OTLP desde los pods locales, recolecte host metrics, siga los logs de contenedores, enriquezca todo con atributos de recurso de Kubernetes y del host, y lo reenvíe a un gateway.

### Pasos

1. Creá el namespace y el RBAC. El processor `k8sattributes` y los detectores `k8snode`/`k8sattributes` necesitan acceso de lectura a pods, namespaces y nodes.

   ```yaml
   # 01-rbac.yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: observability
   ---
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: otel-agent
     namespace: observability
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: otel-agent
   rules:
     - apiGroups: [""]
       resources: ["pods", "namespaces", "nodes"]
       verbs: ["get", "list", "watch"]
     - apiGroups: ["apps"]
       resources: ["replicasets"]
       verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: otel-agent
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: otel-agent
   subjects:
     - kind: ServiceAccount
       name: otel-agent
       namespace: observability
   ```

   ```bash
   kubectl apply -f 01-rbac.yaml
   ```

2. Escribí la configuración del agente como un ConfigMap. Fijate en el **orden de los processors** en el pipeline: `memory_limiter` primero, `batch` último.

   ```yaml
   # 02-agent-config.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: otel-agent-config
     namespace: observability
   data:
     config.yaml: |
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317
             http:
               endpoint: 0.0.0.0:4318
         hostmetrics:
           collection_interval: 30s
           root_path: /hostfs
           scrapers:
             cpu:
             memory:
             load:
             disk:
             filesystem:
             network:
         filelog:
           include: [ /var/log/pods/*/*/*.log ]
           include_file_path: true
           operators:
             - type: container            # parses the CRI/containerd log envelope
       processors:
         memory_limiter:
           check_interval: 1s
           limit_percentage: 80
           spike_limit_percentage: 25
         k8sattributes:
           auth_type: serviceAccount
           passthrough: false
           extract:
             metadata: [k8s.pod.name, k8s.namespace.name, k8s.node.name, k8s.pod.uid]
         resourcedetection:
           detectors: [env, system, k8snode]
           system:
             hostname_sources: [os]
         batch:
           send_batch_size: 8192
           timeout: 5s
       exporters:
         otlp:
           endpoint: otel-gateway.observability.svc.cluster.local:4317
           tls:
             insecure: true            # demo only — use real TLS in production
       extensions:
         health_check:
           endpoint: 0.0.0.0:13133
       service:
         extensions: [health_check]
         telemetry:
           metrics:
             address: 0.0.0.0:8888
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, k8sattributes, resourcedetection, batch]
             exporters: [otlp]
           metrics:
             receivers: [otlp, hostmetrics]
             processors: [memory_limiter, k8sattributes, resourcedetection, batch]
             exporters: [otlp]
           logs:
             receivers: [otlp, filelog]
             processors: [memory_limiter, k8sattributes, resourcedetection, batch]
             exporters: [otlp]
   ```

   ```bash
   kubectl apply -f 02-agent-config.yaml
   ```

3. Desplegá el DaemonSet. Monta el filesystem del host en solo-lectura para `hostmetrics`, monta los logs de los pods para `filelog`, e inyecta la IP del nodo vía la Downward API para que las aplicaciones puedan apuntar al agente de *su propio nodo*.

   ```yaml
   # 03-agent-daemonset.yaml
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: otel-agent
     namespace: observability
   spec:
     selector:
       matchLabels: { app: otel-agent }
     template:
       metadata:
         labels: { app: otel-agent }
       spec:
         serviceAccountName: otel-agent
         containers:
           - name: otel-agent
             image: otel/opentelemetry-collector-contrib:0.106.1
             args: ["--config=/conf/config.yaml"]
             env:
               - name: K8S_NODE_NAME
                 valueFrom:
                   fieldRef: { fieldPath: spec.nodeName }
               - name: OTEL_RESOURCE_ATTRIBUTES
                 value: "k8s.node.name=$(K8S_NODE_NAME)"
             ports:
               - { containerPort: 4317, hostPort: 4317, protocol: TCP }   # OTLP gRPC on the node IP
               - { containerPort: 13133 }
             resources:
               limits: { memory: 400Mi }
               requests: { cpu: 100m, memory: 200Mi }
             livenessProbe:
               httpGet: { path: /, port: 13133 }
             volumeMounts:
               - { name: config, mountPath: /conf }
               - { name: hostfs, mountPath: /hostfs, readOnly: true, mountPropagation: HostToContainer }
               - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
         volumes:
           - name: config
             configMap: { name: otel-agent-config }
           - name: hostfs
             hostPath: { path: / }
           - name: varlogpods
             hostPath: { path: /var/log/pods }
   ```

   ```bash
   kubectl apply -f 03-agent-daemonset.yaml
   kubectl -n observability rollout status ds/otel-agent
   ```

4. Confirmá que el agente arrancó sin problemas. Seguí los logs de un pod:

   ```bash
   kubectl -n observability logs ds/otel-agent | head -n 12
   ```

   Salida esperada (abreviada, el formato varía según la versión):

   ```
   info    service@v0.106.1/service.go:225   Starting otelcol-contrib...  {"Version": "0.106.1", "NumCPU": 8}
   info    extensions/extensions.go:34       Starting extensions...
   info    healthcheckextension@v0.106.1     Starting health_check extension {"endpoint": "0.0.0.0:13133"}
   info    otlpreceiver@v0.106.1/otlp.go:102 Starting GRPC server {"endpoint": "0.0.0.0:4317"}
   info    otlpreceiver@v0.106.1/otlp.go:152 Starting HTTP server {"endpoint": "0.0.0.0:4318"}
   info    hostmetricsreceiver@v0.106.1      started scraper {"kind": "receiver", "scrapers": 6}
   info    service@v0.106.1/service.go:251   Everything is ready. Begin running and processing data.
   ```

5. Apuntá una aplicación al agente de *su nodo*. Un pod de aplicación usa la IP del host, no un Service:

   ```yaml
   env:
     - name: HOST_IP
       valueFrom:
         fieldRef: { fieldPath: status.hostIP }
     - name: OTEL_EXPORTER_OTLP_ENDPOINT
       value: "http://$(HOST_IP):4317"
     - name: OTEL_EXPORTER_OTLP_PROTOCOL
       value: "grpc"
   ```

> **Chequeo de comprensión**
>
> **Q1.** ¿Por qué se coloca `memory_limiter` *primero* y `batch` *último* en cada pipeline? ¿Qué se rompe si los intercambiás?
>
> **Q2.** Las aplicaciones apuntan a `http://$(HOST_IP):4317` en lugar de a un nombre DNS de `Service` de Kubernetes. ¿Por qué es esa la elección correcta para un agente por nodo, y qué habilita la línea `hostPort: 4317`?
>
> **Q3.** El DaemonSet monta el `/` del host en `/hostfs` y la configuración establece `root_path: /hostfs`. ¿Qué receiver necesita esto, y qué reportaría `hostmetrics` sin ello?
>
> **Q4.** Nombrá dos pasos de enriquecimiento que realiza el agente y que un SDK de aplicación, por sí solo, generalmente no puede hacer de forma confiable — y explicá por qué el *agente* es el lugar correcto para ellos.

---

## Ejercicio 2 — Topología Agent → Gateway y el trade-off del tail-sampling

**Objetivo:** entender por qué los agentes reenvían a los gateways, y demostrar la única cosa que un agente *no puede* hacer correctamente por sí solo: el tail-based sampling.

### Pasos

1. Desplegá un gateway mínimo (un `Deployment` detrás de un `Service`, escalable independientemente de los nodos) que hace tail-based sampling antes de exportar a un backend.

   ```yaml
   # 04-gateway.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: otel-gateway-config, namespace: observability }
   data:
     config.yaml: |
       receivers:
         otlp:
           protocols:
             grpc: { endpoint: 0.0.0.0:4317 }
       processors:
         memory_limiter:
           check_interval: 1s
           limit_percentage: 80
           spike_limit_percentage: 25
         tail_sampling:
           decision_wait: 10s
           policies:
             - name: keep-errors
               type: status_code
               status_code: { status_codes: [ERROR] }
             - name: keep-slow
               type: latency
               latency: { threshold_ms: 500 }
             - name: sample-the-rest
               type: probabilistic
               probabilistic: { sampling_percentage: 5 }
         batch: {}
       exporters:
         debug: { verbosity: normal }      # replaces the old "logging" exporter
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, tail_sampling, batch]
             exporters: [debug]
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: otel-gateway, namespace: observability }
   spec:
     replicas: 2
     selector: { matchLabels: { app: otel-gateway } }
     template:
       metadata: { labels: { app: otel-gateway } }
       spec:
         containers:
           - name: otel-gateway
             image: otel/opentelemetry-collector-contrib:0.106.1
             args: ["--config=/conf/config.yaml"]
             volumeMounts: [ { name: config, mountPath: /conf } ]
         volumes:
           - name: config
             configMap: { name: otel-gateway-config }
   ---
   apiVersion: v1
   kind: Service
   metadata: { name: otel-gateway, namespace: observability }
   spec:
     selector: { app: otel-gateway }
     ports: [ { name: otlp-grpc, port: 4317, targetPort: 4317 } ]
   ```

   ```bash
   kubectl apply -f 04-gateway.yaml
   ```

2. Fijate en la topología que tenés ahora: **app → agente de nodo (DaemonSet) → Service del gateway (2 réplicas) → backend**. La configuración del agente del Ejercicio 1 ya exporta a `otel-gateway.observability.svc.cluster.local:4317`.

3. Ahora razoná sobre una falla. Supongamos que intentaras mover `tail_sampling` *a los agentes* en lugar del gateway. Escalá el gateway a cero e imaginá dos agentes viendo cada uno solo *parte* de una traza distribuida:

   ```bash
   kubectl -n observability scale deploy/otel-gateway --replicas=0
   ```

   Una sola request que cruza pods en el Nodo A y el Nodo B produce spans que aterrizan en **dos agentes diferentes**. El `tail_sampling` de cada agente ve una traza incompleta y toma su propia decisión.

4. Restaurá el gateway y confirmá la ubicación correcta:

   ```bash
   kubectl -n observability scale deploy/otel-gateway --replicas=2
   ```

   Para que el tail sampling funcione, todos los spans de una traza deben llegar a la *misma* instancia de Collector. Por eso los gateways de producción se ubican detrás de un **load balancer consciente del trace-ID** (el exporter `loadbalancing`, enrutando por `traceID`), para que cada span de una traza aterrice en una única réplica del gateway.

> **Chequeo de comprensión**
>
> **Q5.** Nombrá tres responsabilidades que corresponden al **gateway**, no al agente, y explicá la razón común que todas comparten.
>
> **Q6.** ¿Por qué el tail-based sampling se rompe cuando se realiza en agentes por nodo, pero el sampling head-based (probabilístico, `parentbased_traceidratio`) no?
>
> **Q7.** Un gateway se despliega con `replicas: 3` detrás de un `Service` round-robin común, ejecutando `tail_sampling`. Incluso con el gateway "en el nivel correcto", el sampling sigue comportándose mal. ¿Qué falta, y qué exporter lo arregla?
>
> **Q8.** Enunciá una ventaja de disponibilidad y una desventaja de costo de recursos del nivel de agentes en comparación con enviar telemetría directamente desde las apps a un gateway central.

---

## Ejercicio 3 — Gestionar una flota de agentes con OpAMP

**Objetivo:** ejecutar un Collector bajo el **Supervisor de OpAMP** para que su configuración y salud sean controladas por un servidor OpAMP remoto. Ver [especificación de OpAMP](https://opentelemetry.io/docs/specs/opamp/) y el [`opampsupervisor`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/opampsupervisor).

### Pasos

1. Escribí una configuración de Supervisor. El Supervisor es un proceso liviano que *envuelve* el binario del Collector, se conecta al servidor OpAMP por WebSocket, aplica la configuración remota, y reinicia el Collector según sea necesario.

   ```yaml
   # supervisor.yaml
   server:
     endpoint: wss://opamp.example.com/v1/opamp
     headers:
       Authorization: "Bearer ${env:OPAMP_TOKEN}"
   capabilities:
     accepts_remote_config: true
     reports_effective_config: true
     reports_own_metrics: true
     reports_health: true
     reports_remote_config: true
   agent:
     executable: /usr/bin/otelcol-contrib
   storage:
     directory: /var/lib/otelcol/supervisor
   ```

2. Iniciá el Supervisor (lanza el Collector como un proceso hijo):

   ```bash
   OPAMP_TOKEN=... opampsupervisor --config supervisor.yaml
   ```

   Inicio esperado:

   ```
   info  Supervisor starting     {"id": "01J...ULID", "version": "0.106.1"}
   info  Connected to the OpAMP server
   info  Received remote config from server {"hash": "b3d1..."}
   info  Starting agent           {"agent": "/usr/bin/otelcol-contrib"}
   info  Agent process started    {"pid": 4711}
   info  Reporting health         {"healthy": true}
   ```

3. Del lado del servidor, un operador envía un nuevo pipeline (p. ej. baja la tasa de sampling) a *miles* de agentes a la vez. Cada Supervisor:
   - recibe el nuevo `AgentConfigMap`,
   - lo escribe en `storage.directory`,
   - reinicia el Collector con la configuración fusionada,
   - reporta de vuelta `reports_effective_config` (lo que realmente se cargó) y `reports_remote_config` (aceptada/fallida + hash).

4. Si una configuración enviada es inválida, el Supervisor reporta la falla y mantiene corriendo la última configuración válida conocida — la flota no se queda a oscuras. Observá ese comportamiento mirando la salud/estado que reporta el Supervisor (`RemoteConfigStatus = FAILED`, `health.healthy = true` en la configuración previa).

> **Chequeo de comprensión**
>
> **Q9.** ¿Cuál es la división de tareas entre el **Supervisor** y el **Collector**? ¿Por qué no incorporar OpAMP directamente en el binario del Collector?
>
> **Q10.** Distinguí `reports_effective_config` de `reports_remote_config`. ¿Por qué un operador necesita *ambos* para confiar en un despliegue de flota?
>
> **Q11.** OpAMP corre sobre una conexión persistente (típicamente WebSocket) y soporta capacidades como `AcceptsRemoteConfig` y `ReportsHealth`. Nombrá dos problemas operativos a escala de flota que OpAMP resuelve y que editar ConfigMaps por nodo a mano no.

---

## Ejercicio 4 — Agentes de instrumentación zero-code (y auto-inyección del Operator)

**Objetivo:** producir telemetría desde una aplicación *sin modificar* con un agente de lenguaje, y luego hacer que el Operator de OpenTelemetry inyecte ese agente automáticamente. Ver [Instrumentación zero-code](https://opentelemetry.io/docs/zero-code/), el [agente de Java](https://opentelemetry.io/docs/zero-code/java/agent/), y [variables de entorno del SDK](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/).

### Pasos

1. Adjuntá el agente de Java a un JAR común — sin cambios de código. La configuración es enteramente a través de variables de entorno / system properties:

   ```bash
   java -javaagent:./opentelemetry-javaagent.jar \
        -Dotel.service.name=checkout \
        -Dotel.exporter.otlp.endpoint=http://localhost:4317 \
        -Dotel.exporter.otlp.protocol=grpc \
        -Dotel.traces.sampler=parentbased_traceidratio \
        -Dotel.traces.sampler.arg=0.25 \
        -Dotel.propagators=tracecontext,baggage \
        -jar checkout.jar
   ```

   Banner esperado del agente:

   ```
   [otel.javaagent 2026-08-10 14:20:03:112 +0000] [main] INFO io.opentelemetry.javaagent.tooling.VersionLogger - opentelemetry-javaagent - version: 2.6.0
   ```

2. Hacé lo mismo para Python, que usa un paso de bootstrap más un wrapper de lanzamiento:

   ```bash
   pip install opentelemetry-distro opentelemetry-exporter-otlp
   opentelemetry-bootstrap -a install          # detects libraries, installs matching instrumentations
   OTEL_SERVICE_NAME=cart \
   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
   opentelemetry-instrument python app.py
   ```

3. En Kubernetes, dejá de editar specs de pods a mano. Instalá el [Operator](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/), y luego declará un recurso `Instrumentation` que apunte a *tu agente de nodo*:

   ```yaml
   # 05-instrumentation.yaml
   apiVersion: opentelemetry.io/v1alpha1
   kind: Instrumentation
   metadata:
     name: default-instr
     namespace: shop
   spec:
     exporter:
       endpoint: http://otel-agent.observability:4317   # or the node agent via HOST_IP
     propagators: [tracecontext, baggage]
     sampler:
       type: parentbased_traceidratio
       argument: "0.25"
     java:
       image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest
   ```

   ```bash
   kubectl apply -f 05-instrumentation.yaml
   ```

4. Habilitá una carga de trabajo con una sola anotación — el mutating webhook del Operator inyecta un init container que copia el agente y establece el `JAVA_TOOL_OPTIONS`/env por vos:

   ```yaml
   # in the Deployment's pod template:
   metadata:
     annotations:
       instrumentation.opentelemetry.io/inject-java: "true"
   ```

   Verificá la inyección:

   ```bash
   kubectl -n shop get pod checkout-xxxx -o jsonpath='{.spec.initContainers[*].name}'
   # -> opentelemetry-auto-instrumentation-java
   kubectl -n shop exec checkout-xxxx -- printenv JAVA_TOOL_OPTIONS
   # -> -javaagent:/otel-auto-instrumentation-java/javaagent.jar
   ```

> **Chequeo de comprensión**
>
> **Q12.** En una oración cada uno, contrastá los *dos* "agentes" que ahora coexisten en este pod: el **agente de Java** inyectado y el **agente Collector de nodo**. ¿Qué fluye entre ellos?
>
> **Q13.** Los agentes zero-code se configuran solo a través de variables de entorno / system properties siguiendo la spec de OTel. Escribí las cuatro variables de entorno que establecen: nombre del servicio, endpoint OTLP, sampler, y ratio del sampler — usando los nombres estándar `OTEL_*`.
>
> **Q14.** El CRD `Instrumentation` del Operator usa un *mutating admission webhook* más un *init container*. ¿Qué aporta cada uno de esos dos mecanismos para meter el agente en el proceso en ejecución?
>
> **Q15.** Un compañero establece `OTEL_TRACES_SAMPLER=traceidratio` (no `parentbased_traceidratio`) en un servicio downstream. ¿Por qué esto puede fragmentar las trazas, y qué valor mantiene una traza distribuida como todo-o-nada?

---

## Ejercicio 5 — Diagnosticar un agente silencioso

**Objetivo:** un agente está "Running" pero ningún dato llega al backend. Localizá la falla usando la propia telemetría del Collector, las extensiones health/zpages, y un exporter debug.

### Pasos

1. Agregá extensiones de diagnóstico y un exporter debug local a la configuración del agente (temporalmente), y luego recargá:

   ```yaml
   extensions:
     health_check: { endpoint: 0.0.0.0:13133 }
     zpages:       { endpoint: 0.0.0.0:55679 }
     pprof:        { endpoint: 0.0.0.0:1777 }
   exporters:
     debug: { verbosity: detailed }
   service:
     extensions: [health_check, zpages, pprof]
   # add `debug` alongside `otlp` in each pipeline's exporters list
   ```

2. Hacé port-forward y leé las **propias** métricas Prometheus del agente (por defecto `:8888/metrics`):

   ```bash
   kubectl -n observability port-forward ds/otel-agent 8888:8888 &
   curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)'
   ```

   Un patrón de ingesta sana / egreso fallido se ve así:

   ```
   otelcol_receiver_accepted_spans{...}       124301
   otelcol_receiver_refused_spans{...}        0
   otelcol_exporter_sent_spans{exporter="otlp",...}         0
   otelcol_exporter_send_failed_spans{exporter="otlp",...}  124301
   otelcol_exporter_queue_size{exporter="otlp",...}         5000
   ```

3. Interpretá: el dato es *aceptado* por el receiver pero cada span *falla al exportar*. Eso apunta downstream — el gateway es inalcanzable o está rechazando el TLS. Confirmá la conectividad desde el pod del agente:

   ```bash
   kubectl -n observability exec ds/otel-agent -- \
     nc -zv otel-gateway.observability.svc.cluster.local 4317
   ```

4. Verificá de forma cruzada con `zpages`:

   ```bash
   kubectl -n observability port-forward ds/otel-agent 55679:55679 &
   curl -s localhost:55679/debug/pipelinez     # pipelines, per-signal
   curl -s localhost:55679/debug/tracez        # sampled recent spans + errors
   ```

5. Ahora invertí el síntoma: `otelcol_receiver_refused_spans` está subiendo y los logs muestran `data refused due to high memory usage`. Eso es `memory_limiter` aplicando **backpressure** — la solución es más memoria / un `limit_percentage` más bajo, o reducir el volumen entrante, no un cambio de red.

> **Chequeo de comprensión**
>
> **Q16.** `accepted_spans` está alto, `sent_spans` es cero, `send_failed_spans` sigue a `accepted_spans`, y `queue_size` está clavado en su máximo. ¿En qué nivel está la falla, y cuáles son dos causas raíz probables?
>
> **Q17.** Un agente distinto muestra `otelcol_receiver_refused_spans` en aumento y líneas de log de `memory_limiter`. ¿Por qué *rechazar en el receiver* es el comportamiento buscado y no un bug, y qué protege al nodo si lo ignorás?
>
> **Q18.** ¿Qué endpoints exponen `health_check`, `zpages` y la dirección de telemetría `:8888`, y cuál de los tres te dice si *spans individuales* están dando error versus si el *proceso* está vivo?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** `memory_limiter` debe correr primero para poder inspeccionar y, bajo presión, *rechazar* los datos entrantes antes de que cualquier processor downstream haya asignado memoria para ellos — aplica backpressure al receiver. `batch` corre último (justo antes del exporter) para que los batches se ensamblen a partir de datos que ya sobrevivieron al limiting y al enriquecimiento, maximizando la eficiencia de exportación. Intercambiarlos significa que `batch` acumula grandes batches en memoria que `memory_limiter` ya no puede prevenir, anulando la protección de memoria e invitando a OOM kills; además estarías gastando CPU enriqueciendo/agrupando datos que luego se descartan.

**Q2.** Un agente por nodo es alcanzable en la IP de su nodo; enviar a un `Service` de cluster haría round-robin entre los agentes de *todos* los nodos, agregando un salto de red, rompiendo la localidad node-local (correlación de host metrics/logs, la menor latencia) y anulando el diseño del DaemonSet. `status.hostIP` le da a cada pod la IP del nodo en el que corre, y `hostPort: 4317` enlaza el puerto OTLP del agente en el nodo para que `HOST_IP:4317` alcance al agente local. Resultado: cada pod habla con el agente de su propio nodo.

**Q3.** El receiver `hostmetrics`. Dentro de un contenedor, de lo contrario leería la vista del *contenedor* de `/proc` y `/sys`, reportando el CPU/memoria/filesystem limitado por el cgroup del contenedor en lugar del del nodo. Montar el `/` del host en `/hostfs` con `root_path: /hostfs` hace que lea las métricas reales del host.

**Q4.** Dos cualesquiera de: (a) **atributos de Kubernetes** (`k8s.pod.name`, `k8s.namespace.name`, `k8s.node.name`) vía `k8sattributes` — la app no conoce de forma confiable su propia metadata de pod, y centralizarlo evita RBAC por app; (b) **detección de recursos del host/nodo** (`resourcedetection`) — la identidad de infraestructura pertenece a la plataforma, no a la app; (c) **recolección de logs de contenedores** (`filelog`) — la app no puede seguir los logs de contenedores hermanos; (d) **host metrics** — señales de infraestructura que ninguna app individual posee. El agente es el lugar correcto porque corre con acceso a nivel de nodo y una sola configuración gobierna cada carga de trabajo, de modo que el enriquecimiento es uniforme y las apps se mantienen livianas.

**Q5.** Ejemplos: **tail-based sampling**, **agregación/deduplicación entre fuentes**, **load balancing / fan-in consciente del trace-ID**, **depuración de datos sensibles en un punto de estrangulamiento de egreso**, **exportación y reintento específicos del backend con colas grandes**. Razón compartida: necesitan una **vista global o agregada** de la telemetría (o un punto de estrangulamiento central estable), que un agente por nodo — que ve solo la porción de su nodo — estructuralmente no puede proveer.

**Q6.** El tail-based sampling decide *después* de ver la traza completa (p. ej. "conservar si algún span dio error o es lento"), por lo que requiere **todos los spans de una traza en un solo lugar**. Con agentes por nodo, los spans de una request distribuida se reparten entre los nodos donde corre cada servicio, así que ningún agente individual ve la traza completa y las decisiones son inconsistentes/incorrectas. El sampling head-based (`parentbased_traceidratio`) decide al inicio de la traza a partir del trace ID y **propaga esa decisión** vía el contexto a cada servicio, de modo que cada nodo toma de forma independiente la *misma* decisión de conservar/descartar — sin necesidad de una vista global.

**Q7.** Los spans de una traza se siguen repartiendo entre las tres réplicas del gateway por round-robin, así que cada réplica ve una traza parcial — el mismo problema, un nivel más arriba. Solución: poner adelante una **capa consciente del trace-ID** usando el **exporter `loadbalancing`** con `routing_key: traceID` (un primer nivel de gateways enruta por trace ID hacia un segundo nivel que hace `tail_sampling`), garantizando que todos los spans de una traza lleguen a una única instancia de sampling.

**Q8.** Ventaja: el agente **desacopla la app del backend** — las apps hacen una entrega local rápida, y el agente hace buffering/reintentos durante caídas del backend o de la red, de modo que un backend lento no traba la app ni pierde datos. Desventaja: cuesta un Collector **en cada nodo** (footprint de CPU/memoria × cantidad de nodos) incluso cuando los nodos están poco cargados, mientras que app-directo-al-gateway no necesita un proceso por nodo.

**Q9.** El **Collector** hace el trabajo de telemetría (recibir/procesar/exportar); el **Supervisor** es un administrador liviano que mantiene la conexión OpAMP, aplica la configuración remota a disco, (re)inicia y chequea la salud del Collector, y reporta el estado. Mantener OpAMP en el Supervisor significa que el canal de gestión sobrevive a los reinicios/crashes del Collector y a los cambios de configuración, la configuración puede validarse y revertirse alrededor del proceso del Collector, y el binario del Collector se mantiene enfocado — podés gestionar un Collector en el que no incorporaste OpAMP.

**Q10.** `reports_remote_config` le dice al servidor si la configuración enviada fue **aceptada o rechazada** (con un hash y un error), es decir, el *resultado de la entrega*. `reports_effective_config` reporta la configuración que el Collector **realmente está ejecutando** después de las fusiones/valores por defecto, es decir, la *realidad*. Necesitás ambos porque una configuración puede entregarse/aceptarse y aun así no ser la que está efectivamente cargada (orden de fusión, overrides locales, fallback a la última válida conocida) — solo comparar "lo que envié / lo que se aceptó" contra "lo que realmente está corriendo" prueba que la flota convergió.

**Q11.** Dos cualesquiera: (a) **despliegues a nivel de toda la flota atómicos y auditables con estado y hashes reportados** en lugar de esperar que N ediciones de ConfigMap se hayan aplicado todas; (b) **manejo seguro de fallas** — una configuración mala se reporta como `FAILED` y el agente mantiene corriendo la última válida conocida, frente a una edición a mano que puede romper un agente en silencio; (c) **reporte en vivo de salud, configuración efectiva y métricas propias** desde miles de agentes por un solo canal; (d) **actualizaciones coordinadas** del binario del agente. La edición manual de ConfigMaps no da estado de despliegue, ni rollback automático, ni salud/inventario a nivel de toda la flota.

**Q12.** El **agente de Java** es una librería de instrumentación zero-code adjuntada a la *JVM de la aplicación* que genera spans/métricas/logs desde ese único proceso. El **agente Collector de nodo** es un proceso separado que *recibe* telemetría de muchos pods locales y la procesa/reenvía. Flujo: el agente de Java exporta OTLP al agente Collector de nodo (`OTEL_EXPORTER_OTLP_ENDPOINT` → `HOST_IP:4317`), que enriquece y reenvía al gateway.

**Q13.**
```
OTEL_SERVICE_NAME=checkout
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
```

**Q14.** El **mutating admission webhook** intercepta el pod en su creación y reescribe su spec — agregando el init container, un volumen compartido, y el env (`JAVA_TOOL_OPTIONS=-javaagent:...`) — para que nadie edite los deployments a mano. El **init container** trae el binario/jar del agente y lo copia al volumen compartido antes de que la app arranque, de modo que los archivos del agente están presentes en el filesystem del contenedor de la app para que la JVM los cargue al inicio.

**Q15.** `traceidratio` toma una decisión **independiente** de conservar/descartar en cada servicio usando solo el hash local del trace-ID, ignorando la decisión del padre; así un padre puede conservar una traza mientras un hijo la descarta (o viceversa), produciendo trazas rotas y parciales. `parentbased_traceidratio` **respeta la decisión de sampling propagada en el contexto** y solo aplica el ratio en la raíz, de modo que toda la traza distribuida se samplea como todo-o-nada.

**Q16.** La falla está **downstream de este agente — en la exportación / el gateway**: el receiver acepta los datos (`accepted_spans` alto) pero el exporter no puede entregarlos (`send_failed_spans` ≈ `accepted_spans`, `sent_spans` = 0) y la cola de envío está saturada. Dos causas probables: el endpoint del gateway es **inalcanzable** (DNS/Service incorrecto, gateway caído, NetworkPolicy) o la conexión es **rechazada** (mala configuración de TLS/discrepancia de certificado, o el gateway está rechazando/sobrecargado).

**Q17.** Que `memory_limiter` rechace en el receiver es **backpressure** deliberado: en lugar de bufferear datos sin límite y ser OOM-killed (perdiendo *todo* y reiniciando), devuelve errores a los emisores para que reintenten/bajen el ritmo, manteniendo vivo al Collector y descartando el exceso de carga de forma elegante. Ignorarlo arriesga que el agente supere el límite de memoria de su contenedor y sea OOM-killed por el kubelet, tirando abajo la telemetría de todo el nodo.

**Q18.** `health_check` (`:13133`) expone la **liveness/readiness del proceso** (usada por la probe de k8s). `zpages` (`:55679`, p. ej. `/debug/tracez`, `/debug/pipelinez`) expone **trazas in-process de spans recientes y el estado del pipeline**, incluyendo errores por span. La dirección de telemetría `:8888/metrics` expone los **propios contadores Prometheus del Collector** (`otelcol_receiver_*`, `otelcol_exporter_*`, etc.). Para ver si *spans individuales* están dando error, usá **`zpages` (`/debug/tracez`)** junto con los contadores de fallo de `:8888`; `health_check` solo te dice que el *proceso* está vivo.

</details>

---

**Fuentes**

- OpenTelemetry Collector — Despliegue Agent: https://opentelemetry.io/docs/collector/deployment/agent/
- OpenTelemetry Collector — Despliegue Gateway: https://opentelemetry.io/docs/collector/deployment/gateway/
- Configuración del Collector y processors: https://opentelemetry.io/docs/collector/configuration/
- Escalado del Collector (agent/gateway, load balancing por trace-ID): https://opentelemetry.io/docs/collector/scaling/
- Especificación de OpAMP: https://opentelemetry.io/docs/specs/opamp/ · Supervisor: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/opampsupervisor
- Instrumentación zero-code: https://opentelemetry.io/docs/zero-code/ · Agente de Java: https://opentelemetry.io/docs/zero-code/java/agent/
- Variables de entorno del SDK: https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- Operator de Kubernetes — instrumentación automática: https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/